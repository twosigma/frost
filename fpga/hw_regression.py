#!/usr/bin/env python3

#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

"""Run board applications and Linux boots, then check DDR ECC state.

Apps rebuild and load through JTAG; UART checks and score gates determine pass.
Debugger-driven apps and apps needing a 10G link partner are excluded.
The ``debug_port`` stage exercises the debug transport through OpenOCD (halt,
read dpc, resume), confirms the hart is running in a separate OpenOCD process,
and runs only when ``FROST_JTAG_SERIAL`` names the JTAG cable; otherwise it is
reported as skipped.
``perf_off_test`` requires a bitstream built without ``--perf-counters``.

Linux preflight reads ``fpga/site.env`` and environment overrides before board
access, unpacks the initramfs with ``unmkinitramfs``, and requires every
``frost_net10g`` module copy inside it to report this tree's version via
``modinfo -F version``. Setup errors report ``ENV_FAIL``. Where the
controller has a JTAG ECC window, the last stage checks it after all
traffic.

Run natively: ``./fpga/hw_regression.py --board x3 [stage ...]``.
See ``fpga/README.md`` and ``docs/debian_nfsroot.md`` for setup and limits.
"""

import argparse
import collections
import fcntl
import ipaddress
import os
import re
import secrets
import select
import shlex
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DEFAULT = SCRIPT_DIR.parent

sys.path.insert(0, str(SCRIPT_DIR))
sys.path.insert(0, str(SCRIPT_DIR / "common"))
sys.path.insert(0, str(SCRIPT_DIR / "load_software"))
sys.path.insert(0, str(REPO_DEFAULT / "sw" / "apps"))
sys.path.insert(0, str(REPO_DEFAULT / "linux"))
from ddr_ecc.ddr_ecc_status import ECC_WINDOW_DESIGNS  # noqa: E402
from debian_kernel import (  # noqa: E402
    INITRAMFS_COUNTER_TOKEN,
    KERNEL_BANNER,
    KERNEL_RELEASE,
    MEMERR,
    build_module,
    kernel_image,
)
from hw_defaults import (  # noqa: E402
    CPU_ECC_READER_BOARDS,
    DEFAULT_SERIALS,
    DEFAULT_TARGETS,
    DEFAULT_TIMEOUTS,
)
from load_software import (  # noqa: E402
    BOARD_CONFIG,
    CPU_CLK_ENV,
    SUPPORTED_VEC_STATE_VLENS,
    VEC_ADVERTISE_APPS,
    VEC_VLEN_APPS,
    VECTOR_UNIT_APPS,
    board_clock_freq,
    board_vector_config,
    valid_apps_for_board,
)
from software_registry import COREMARK_PRO_APP_NAMES  # noqa: E402
from sweep_coremark_pro import (  # noqa: E402
    LOAD_COMPLETE_SENTINEL,
    configure_serial,
    drain,
    read_available,
    serial_holders,
)

# Minimum accepted scores for the standard software builds; ``None`` reports a
# score without checking it. Keep these floors when raising the CPU clock:
# memory-sensitive CoreMark-PRO throughput does not scale linearly with CPU
# frequency.
BASELINE_SCORES: dict[str, dict[str, float | None]] = {
    "x3": {"coremark": 1374.88, "coremark_pro": 91.15},
}

# FROST is cycle-deterministic; only DDR refresh adds sub-percent score jitter.
DEFAULT_SCORE_TOLERANCE_PCT = 1.0

# Non-app stage names; linux_boot also names its loader app.
SWEEP_STAGE = "coremark_pro"
LINUX_STAGE = "linux_boot"
ECC_STAGE = "ddr_ecc"
DEBUG_STAGE = "debug_port"

# The debug transport check runs OpenOCD against the board's JTAG cable and
# needs the cable's serial number (the two FT4232H bridges on the X3 look
# alike), so it runs only when FROST_JTAG_SERIAL is set and is reported as
# skipped otherwise. OpenOCD and Vivado's hw_server cannot share the cable;
# hw_server exits on its own a while after its last client.
JTAG_SERIAL_ENV = "FROST_JTAG_SERIAL"
OPENOCD_ENV = "OPENOCD"
DEBUG_CONFIGS = {"x3": Path("fpga/debug/openocd_x3.cfg")}
DEBUG_SCRIPT = Path("fpga/debug/hw_debug_check.tcl")
DEBUG_TIMEOUT_S = 60.0
DEBUG_RECOVERY_TIMEOUT_S = 30.0
DEBUG_CABLE_WAIT_S = 180.0
DEBUG_LOCK = Path(tempfile.gettempdir()) / "frost_cache_counters.lock"
SKIP_STATUS = "SKIPPED"
# dtmcs: version 1 (spec 0.13/1.0 DTM), 7 address bits, no sticky DMI error.
DTMCS_EXPECTED = (1, 7, 0)
# hartinfo: nscratch 2, dataaccess 0, datasize 1, dataaddr 0x7b4 (debug_module.sv).
HARTINFO_EXPECTED = 0x002017B4

# Read the DDR4 controller over JTAG after all application traffic. A clean
# report means checking is enabled and no ECC errors are recorded. A dirty
# report includes the first captured failing address.
ECC_STAGE_SCRIPT = "./fpga/ddr_ecc/ddr_ecc_status.py"
ECC_STAGE_TIMEOUT_S = 600.0
# ddr_ecc_status.py exits 2 for a dirty report and 1 for a read that failed.
ECC_DIRTY_EXIT = 2

# Two greetings prove boot and the one-second timer; no pass marker is printed.
HELLO_GREETING = "Frost: Hello, world!"
HELLO_MIN_GREETINGS = 2

# A returned probe proves every byte crossed UART RX and TX.
ECHO_PROMPT = "frost> "
ECHO_PROBE = "FROST_HW_REGRESSION_ECHO_PROBE"
ECHO_EXPECTED = f'You typed: "{ECHO_PROBE}" ({len(ECHO_PROBE)} chars)'

# Include building/loading the ROM, DDR preparation, flash reads and CRC checks.
BOOTROM_TIMEOUT_S = 600.0
BOOTROM_START = "FROST Core Boot ROM v1.0 (On-Chip BRAM @ 0x00000000)"
BOOTROM_MILESTONES = (
    (
        "ROM FSBL CRC verification",
        re.compile(
            r"^\[BOOTROM\] FSBL CRC-32 verified \(0x[0-9a-fA-F]{8}\)\. "
            r"Jumping to 0x00004000\.\.\.\n",
            re.MULTILINE,
        ),
    ),
    (
        "FSBL verified boot chain",
        re.compile(
            r"^\[FSBL\] Boot chain ready: OpenSBI @ 0x80000000 -> "
            r"U-Boot @ 0x80200000 \(DTB @ 0x82200000\)\n",
            re.MULTILINE,
        ),
    ),
    (
        "FSBL handoff",
        re.compile(
            r"^\[FSBL\] Handing off to OpenSBI \+ U-Boot Proper in DRAM\.\.\.\n",
            re.MULTILINE,
        ),
    ),
    ("U-Boot banner", re.compile(r"^U-Boot \d{4}\.\d{2}[^\n]*\n", re.MULTILINE)),
    ("U-Boot prompt", re.compile(r"^frost=> \Z", re.MULTILINE)),
)
BOOTROM_FAILURE_RE = re.compile(
    r"(?:\[(?:BOOTROM|FSBL)\] HALT:"
    r"|\[BOOTROM\] (?:No valid FSBL header|Invalid FSBL bounds|FSBL CRC-32 mismatch!)"
    r"|\[FSBL\] (?:DRAM verify failed|Invalid (?:OpenSBI|DeviceTree|U-Boot) header)"
    r"|\[FSBL\] Loading [^\r\n]* FAIL \(exp="
    r"|<<FAIL>>|<<TRAP>>|### ERROR ### Please RESET the board ###"
    r"|\bsbi_trap_error:|Unhandled exception(?: code)?:"
    r"|\binit_coldboot: [^\r\n]* failed \(error "
    r"|\bError -?\d+ getting MISA XLEN)"
    r"[^\r\n]*"
)

# --- Linux stage: Debian 13 on its NFS root over the NIC ---------------------
#
# Hardware regression boots Debian over NFS; CI separately checks the test initramfs.
#
# The site supplies the NFS export and board IP in SITE_ENV_FILE or the
# environment, which takes precedence. Default kernel and initramfs paths use
# the pinned release. Check all settings before running stages; see
# docs/debian_nfsroot.md for root setup.
LINUX_NFSROOT_ENV = "FROST_LINUX_NFSROOT"
LINUX_IP_ENV = "FROST_LINUX_IP"
LINUX_KERNEL_ENV = "FROST_LINUX_KERNEL"
LINUX_INITRD_ENV = "FROST_LINUX_INITRD"
LINUX_DTB_ENV = "FROST_LINUX_DTB"
# Required site settings; kernel, initramfs, and DTB paths have defaults.
LINUX_ROOT_ENV_VARS = (
    LINUX_NFSROOT_ENV,
    LINUX_IP_ENV,
)
LINUX_DERIVED_ENV_VARS = (
    LINUX_KERNEL_ENV,
    LINUX_INITRD_ENV,
    LINUX_DTB_ENV,
)
SITE_ENV_FILE = SCRIPT_DIR / "site.env"


def read_site_env(path: Path | None = None) -> dict[str, str]:
    """Read allowed ``NAME=value`` settings from the optional site file.

    Accept only ``LINUX_ROOT_ENV_VARS`` and ``LINUX_DERIVED_ENV_VARS``.
    Ignore blank lines, comments, malformed lines, and other names.
    """
    # Resolved per call, not bound as a default, so SITE_ENV_FILE can be
    # pointed elsewhere.
    path = SITE_ENV_FILE if path is None else path
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return {}
    wanted = set(LINUX_ROOT_ENV_VARS) | set(LINUX_DERIVED_ENV_VARS)
    values: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, separator, value = line.partition("=")
        name = name.strip()
        if separator and name in wanted:
            values[name] = value.strip().strip('"').strip("'")
    return values


# Report setup failures as ENV_FAIL so they cannot be mistaken for RTL failures.
ENV_NOT_READY = "environment not ready (not a board failure)"
ENV_FAIL_STATUS = "ENV_FAIL"


class LinuxEnvironmentError(RuntimeError):
    """The operator's NFS root cannot be booted from this host.

    Raised by ``linux_root_from_env`` and ``linux_root_preflight``; the message
    starts with ``ENV_NOT_READY`` and names the fix. The message never carries
    the configured JTAG cable serial.
    """

    def __init__(self, message: object = "", *args: object) -> None:
        """Store the message with the cable serial masked."""
        super().__init__(mask_serial(str(message)), *args)


# Strip terminal escapes before matching console output: bracketed-paste
# controls and systemd colours can precede the text an anchored pattern needs.
# Match CSI, OSC, and two-character escapes. Stop OSC at a newline so an
# incomplete escape cannot swallow the next line.
ANSI_ESCAPE_RE = re.compile(
    r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b\n]*(?:\x07|\x1b\\)?|[@-Z\\-_])"
)


def console_text(serial_buf: str) -> str:
    """Return a UART capture with terminal escape sequences removed."""
    return ANSI_ESCAPE_RE.sub("", serial_buf)


# Healthy kernel logs can contain ERROR. Require the pinned kernel banner,
# Debian's name, and a console login instead of the bare-metal word rule.
# The banner's trailing space prevents matching a longer release with the
# same prefix. Match the distribution name alone so ANSI greeting escapes
# do not affect detection; systemd readiness is checked separately.
DEBIAN_OS_NAME = "Debian GNU/Linux"
LINUX_LOGIN_PROMPT = "login: "
LINUX_SUCCESS_MARKERS = (KERNEL_BANNER, DEBIAN_OS_NAME, LINUX_LOGIN_PROMPT)
LINUX_FAILURE_MARKERS = ("<<TRAP>>", "Kernel panic", "Oops", "BUG:", "Kernel BUG")
LINUX_SHELL_PROMPT = "# "

# Quiet modprobe leaves the driver's probe message (frost_net10g.c, netdev_info)
# as the load check before login. It does not identify the kernel release on its
# own, so also check the boot banner.
LINUX_DRIVER_LINE = "FROST net10g, IRQ "
# Authoritative runtime driver check: read /sys/module/frost_net10g/version from
# the booted system after the prompt and before the network test. printf keeps
# ``FROST_DRIVER_VERSION=`` out of the echoed command so terminal wraps never
# match it.
LINUX_DRIVER_VERSION_PATH = "/sys/module/frost_net10g/version"
LINUX_DRIVER_VERSION_TOKEN = "FROST_DRIVER_VERSION"
LINUX_DRIVER_VERSION_MISSING = "MISSING"
LINUX_DRIVER_VERSION_COMMAND = (
    f"v=$(cat {LINUX_DRIVER_VERSION_PATH} 2>/dev/null) && "
    f'printf "%s=%s\\n" {LINUX_DRIVER_VERSION_TOKEN} "$v" || '
    f'printf "%s={LINUX_DRIVER_VERSION_MISSING}\\n" {LINUX_DRIVER_VERSION_TOKEN}'
)
LINUX_DRIVER_VERSION_RE = re.compile(
    r"^\r*" + LINUX_DRIVER_VERSION_TOKEN + r"=([^\r\n]*)\r*\n", re.MULTILINE
)

# The stress payload. Debian's root does not start it, so the stage types it at
# the shell and requires the token after the login prompt. Absolute path: the
# payload's phase 2 re-execs itself with ``execv``, which does not search PATH.
LINUX_TOKEN = "FROST_USERSPACE_STRESS_PASS"
LINUX_TOKEN_FAIL = "FROST_USERSPACE_STRESS_FAIL"
LINUX_ROOT_BIN = "/usr/local/bin"
LINUX_STRESS_COMMAND = f"{LINUX_ROOT_BIN}/frost_stress --boot"

# Require the packed export as / over NFSv3. Parse raw fstype, source, and
# comma-separated options; ``vers=3`` must be a whole option, not ``mountvers=3``.
LINUX_ROOT_MOUNT_COMMAND = "findmnt -rno FSTYPE,SOURCE,OPTIONS /"
# Require a newline; ``$`` would also match an incomplete line at the buffer end.
LINUX_ROOT_MOUNT_RE = re.compile(
    r"^\r*(nfs\d*)[ \t]+(\S+)[ \t]+(\S+)[ \t\r]*\n", re.MULTILINE
)
LINUX_ROOT_MOUNT_VERS = "vers=3"
# Bound systemd startup, then print failed units, their results and the state.
# ``state=`` distinguishes output from the echoed ``state=$(...)`` command,
# even when the terminal wraps it.
LINUX_SYSTEMD_WAIT_S = 300
# ``--no-pager``, because a long enough list of failed units would otherwise
# open a pager on this console, which reads the input the stage has typed ahead.
# The sentinel permits a unit count only after the entire listing is consumed.
LINUX_SYSTEMD_COMMAND = (
    f"timeout {LINUX_SYSTEMD_WAIT_S} systemctl is-system-running --wait "
    ">/dev/null; "
    "echo systemd-check; "
    "failed=$(systemctl --failed --no-legend --plain --no-pager); listed=$?; "
    "printf '%s\\n' \"$failed\"; "
    "printf '%s\\n' \"$failed\" systemd-list-end | { "
    "count=0; while read -r unit rest; do "
    '[ "$unit" = systemd-list-end ] && break; '
    '[ -z "$unit" ] && continue; '
    "count=$((count+1)); "
    'result=$(systemctl show -p Result --value "$unit") || result=unknown; '
    'echo failed_unit="$unit" result="$result"; done; '
    '[ "$unit" = systemd-list-end ] && echo failed_count=$count; }; '
    "echo failed_list_status=$listed; "
    "echo state=$(systemctl is-system-running)"
)
LINUX_SYSTEMD_RUNNING = "running"
# Degraded is accepted only for session scopes whose result is resources.
# Require a newline so a partial ``state=running`` cannot be read as ``state=r``.
LINUX_SYSTEMD_STATE_RE = re.compile(r"^\r*state=(\w+)[ \t\r]*\n", re.MULTILINE)

# frost_stress reads SBI PMU cycle and instret counters through perf_event_open,
# measuring a child from exec to exit without a target ``perf`` binary.
LINUX_COUNTER_EVENTS = ("cycles", "instret")
LINUX_COUNTER_COMMAND = f"{LINUX_ROOT_BIN}/frost_stress --counters"
LINUX_COUNTER_LINE = f"{INITRAMFS_COUNTER_TOKEN}:"
LINUX_COUNTER_RE = re.compile(
    LINUX_COUNTER_LINE + r"((?: \w+=[\w.+-]+)+) verdict=PASS", re.MULTILINE
)
# End capture on counter failure instead of waiting for a pass until timeout.
LINUX_COUNTER_FAIL_RE = re.compile(
    LINUX_COUNTER_LINE + r"(?: \w+=[\w.+-]+)* verdict=FAIL", re.MULTILINE
)

# The memory error unit's driver (linux/frost-memerr). The Debian root does not
# carry it, so the preflight installs the module built for the pinned kernel
# beside the programs. Check the scrub self-test and an accelerated RAM patrol,
# allowing up to LINUX_MEMERR_PATROL_WAITS one-second sleeps for a pass, then
# reload with the daily default.
# Hardware error counts must stay zero. The self-test accounts for 64 scrubbed
# lines and one skipped MMIO request on the pinned kernel's 4 KiB pages.
# Digits after ``active=`` distinguish output from the echoed command.
LINUX_MEMERR_TOKEN = "FROST_MEMERR"
# The batch and time limits stretch an accelerated pass over the X3's 1 GiB to
# about 80 s.
LINUX_MEMERR_PATROL_WAITS = 150
LINUX_MEMERR_SELFTEST_PASS = "FROST_MEMERR_SELFTEST_PASS"
LINUX_MEMERR_SELFTEST_RE = re.compile(
    r"^\r*" + LINUX_MEMERR_SELFTEST_PASS + r"[ \t\r]*\n", re.MULTILINE
)
LINUX_MEMERR_MODULE = f"{LINUX_ROOT_BIN}/{MEMERR.name}.ko"
LINUX_MEMERR_DEVICE = (
    f"/sys/bus/platform/drivers/{MEMERR.name}/40021000.memory-controller"
)
LINUX_MEMERR_COMMAND = (
    f"rmmod {MEMERR.name} 2>/dev/null; "
    f"if insmod {LINUX_MEMERR_MODULE} patrol_seconds=10; then "
    "mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug; "
    f"d={LINUX_MEMERR_DEVICE}; p=$(cat $d/ecc_polls); "
    "l=$(cat $d/patrol_lines); b=$(cat $d/patrol_passes); "
    f"cat /sys/kernel/debug/{MEMERR.name}/selftest; n=0; "
    'while [ "$(cat $d/patrol_passes)" -le "$b" ] && '
    f'[ "$n" -lt {LINUX_MEMERR_PATROL_WAITS} ]; do '
    "sleep 1; n=$((n+1)); done; "
    'm="active=$(cat $d/ecc_active) '
    "polls=$p,$(cat $d/ecc_polls) ce=$(cat $d/ce_count) ue=$(cat $d/ue_count) "
    "rd=$(cat $d/axi_read_errors) wr=$(cat $d/axi_write_errors) "
    "scrubbed=$(cat $d/scrubbed_lines) skipped=$(cat $d/scrub_skipped) "
    'patrol=$l,$(cat $d/patrol_lines) passes=$b,$(cat $d/patrol_passes)"; '
    f"rmmod {MEMERR.name} && insmod {LINUX_MEMERR_MODULE}; r=$?; "
    f"echo {LINUX_MEMERR_TOKEN} $m restore=$r; "
    "else echo FROST_MEMERR_LOAD_FAIL; fi"
)
LINUX_MEMERR_FIELDS = (
    "active",
    "polls_before",
    "polls_after",
    "ce",
    "ue",
    "rd",
    "wr",
    "scrubbed",
    "skipped",
    "patrol_before",
    "patrol_after",
    "passes_before",
    "passes_after",
    "restore",
)
LINUX_MEMERR_RE = re.compile(
    r"^\r*" + LINUX_MEMERR_TOKEN + r" active=(\d+) polls=(\d+),(\d+) ce=(\d+) "
    r"ue=(\d+) rd=(\d+) wr=(\d+) scrubbed=(\d+) skipped=(\d+) "
    r"patrol=(\d+),(\d+) passes=(\d+),(\d+) restore=(\d+)[ \t\r]*\n",
    re.MULTILINE,
)

# frost_nettest checks NIC or PMA loopback. nettest_command restores the link
# afterward because this interface also carries the root filesystem.
LINUX_NET_COMMAND = "frost_nettest"
LINUX_NET_TOKEN = "FROST_NET_LOOPBACK_PASS"
LINUX_NET_TOKEN_FAIL = "FROST_NET_LOOPBACK_FAIL"
LINUX_NET_INTERFACE_RE = re.compile(
    r"^\r*FROST_NET_LOOPBACK: ([^\s:]+): driver frost_net10g,", re.MULTILINE
)
# For diagnosis, FROST_HW_NETTEST_REPEAT=<n> runs the test n times in one
# boot. Every repetition but the last prints its verdict under this marker,
# which ends no capture, so the log keeps every repetition's output.
NETTEST_REPEAT_ENV = "FROST_HW_NETTEST_REPEAT"
NETTEST_REPEAT_MAX = 20
# For diagnosis, FROST_HW_NETTEST_POKE_NFS=<seconds> makes the root's NFS
# client send a request that many seconds into each run of the test, while
# the test holds the link down.
NETTEST_POKE_ENV = "FROST_HW_NETTEST_POKE_NFS"
NETTEST_POKE_MAX_S = 300
# The poke gives up this long after it fires; the request it sent finishes
# once the link is restored, normally long before.
NETTEST_POKE_GRACE_S = 300
LINUX_NET_DIAG_RE = re.compile(
    r"^\r*FROST_NET_DIAG_(PASS|FAIL) rep=(\d+)([^\r\n]*)[\r]*\n", re.MULTILINE
)
# A tmpfs on the root, mounted by systemd before any login.
LINUX_TMPFS = "/dev/shm"
# The interface the initramfs configures when ``ip=`` names none, and the name
# the docs' root keeps by masking udev's predictable naming.
DEFAULT_NIC_INTERFACE = "eth0"
# Create a file after loopback to require a server round trip; sync alone may
# have nothing to flush. Bound the check and follow with a kill for hard-mount
# waits. The numeric status cannot match the echoed command's ``=$?``.
LINUX_ROOT_ALIVE_TOKEN = "FROST_ROOT_ALIVE"
LINUX_ROOT_ALIVE_FILE = "/root/.frost_alive"
LINUX_ROOT_ALIVE_RE = re.compile(
    r"^\r*" + LINUX_ROOT_ALIVE_TOKEN + r"=(\d+)[ \t\r]*\n", re.MULTILINE
)
LINUX_ROOT_SYNC_S = 120
# A failure line arrives in pieces; read up to this long for its end.
LINUX_FAILURE_LINE_GRACE_S = 2.0
# After an ISA probe case FAIL line, keep reading the console for this long
# before ending the session so cleanup, later cases, kernel diagnostics, and
# the exit line are recorded.
LINUX_ISA_FAILURE_WAIT_S = 60.0

# Covers a warm rebuild, the JTAG load of the DDR image (Debian's kernel and
# initramfs, several minutes), boot through the NFS mount to a login, systemd's
# startup, and the commands the stage types, whose waits are all bounded.
DEFAULT_LINUX_TIMEOUT = 1200.0

# The FROST CoreMark port prints "Total 64-bit ticks : N" and the score formula
# iterations * CPU clock / ticks, which coremark_judge applies.
COREMARK_TICKS_RE = re.compile(r"Total 64-bit ticks : (\d+)")


def check_score(
    board: str,
    key: str,
    measured: float,
    tolerance_pct: float,
    *,
    vector: bool | None = None,
) -> tuple[bool, str]:
    """Judge a measured score against BASELINE_SCORES[board][key].

    Returns (ok, note). A clock-override image or a missing (None) baseline
    reports the measured value and passes; a recorded baseline fails the check
    when the measured score is more than tolerance_pct percent below it.
    """
    if board_clock_freq(board, vector=vector)[1]:
        return True, (
            f"{key} score {measured:.2f} at the {CPU_CLK_ENV} clock override; "
            "baseline check skipped for a divided-clock image"
        )
    baseline = BASELINE_SCORES.get(board, {}).get(key)
    if baseline is None:
        return True, (
            f"{key} score {measured:.2f} -- no {board} baseline recorded; "
            "paste it into BASELINE_SCORES to arm the regression check"
        )
    delta_pct = (measured - baseline) / baseline * 100.0
    if measured < baseline * (1.0 - tolerance_pct / 100.0):
        return False, (
            f"{key} score {measured:.2f} regressed vs baseline {baseline:.2f} "
            f"({delta_pct:+.2f}%, tolerance -{tolerance_pct:g}%)"
        )
    return True, (
        f"{key} score {measured:.2f} vs baseline {baseline:.2f} ({delta_pct:+.2f}%)"
    )


def marker_verdict(serial_buf: str) -> tuple[bool, str]:
    """Apply the sweep's strict pass rule to a captured UART buffer.

    Pass = <<PASS>> present, no <<FAIL>>/<<TRAP>>, no standalone ERROR word,
    and every ":fails=N" counter zero.
    """
    problems = []
    if "<<PASS>>" not in serial_buf:
        problems.append("no <<PASS>>")
    if "<<FAIL>>" in serial_buf:
        problems.append("<<FAIL>> present")
    if "<<TRAP>>" in serial_buf:
        problems.append("<<TRAP>> present")
    if re.search(r"\bERROR\b", serial_buf):
        problems.append("ERROR in output")
    if any(int(x) != 0 for x in re.findall(r":fails=(\d+)", serial_buf)):
        problems.append("nonzero :fails counter")
    if problems:
        return False, ", ".join(problems)
    return True, ""


def _default_failure_done(serial_buf: str) -> bool:
    return "<<FAIL>>" in serial_buf or "<<TRAP>>" in serial_buf


@dataclass
class UartStage:
    """UART completion predicates, result checks, and optional stimuli.

    Done predicates end capture; ``judge`` checks all post-sentinel output.
    ``success_quiet_s`` requires UART silence after successful output.
    Send each ``(trigger, text)`` stimulus once, in order, searching after the
    previous trigger's end.
    """

    app: str
    success_done: Callable[[str], bool]
    failure_done: Callable[[str], bool]
    judge: Callable[[str], tuple[bool, str]]
    stimuli: tuple[tuple[str, str], ...] = ()
    success_quiet_s: float = 0.0
    # After a failure ends capture, keep reading this long at most for the
    # rest of the line, so a failure reason is not cut where a read ended.
    failure_line_grace_s: float = 0.0
    # Optional callback returning additional seconds to keep reading and
    # recording console output after ``failure_done`` triggers (0.0 for none).
    failure_post_wait_s: Callable[[str], float] | None = None


def next_stimulus(
    stage: UartStage, serial_buf: str, sent: int, search_from: int
) -> tuple[str, int] | None:
    """Return the next stimulus text to type and the offset to search after.

    ``sent`` stimuli have been typed already; the next trigger is searched in
    ``serial_buf`` from ``search_from``, the end of the previous trigger, so a
    prompt that appeared earlier in the boot log cannot fire it.
    """
    if sent >= len(stage.stimuli):
        return None
    trigger, text = stage.stimuli[sent]
    hit = serial_buf.find(trigger, search_from)
    if hit < 0:
        return None
    return text, hit + len(trigger)


def build_stage(
    app: str,
    board: str,
    tolerance_pct: float,
    *,
    vector: bool | None = None,
) -> UartStage:
    """Build the UART rules for one app stage."""
    if board == "vcu118" and app == "bootrom":

        def bootrom_judge(serial_buf: str) -> tuple[bool, str]:
            """Require verified flash stages and the interactive U-Boot prompt."""
            text = console_text(serial_buf).replace("\r", "")
            failure = BOOTROM_FAILURE_RE.search(text)
            if failure:
                return False, failure.group(0)
            latest_start = text.rfind(BOOTROM_START)
            if latest_start >= 0:
                text = text[latest_start:]
            after = 0
            for name, pattern in BOOTROM_MILESTONES:
                match = pattern.search(text, after)
                if match is None:
                    return False, f"missing {name} in boot order"
                after = match.end()
            return True, "ROM and FSBL verified flash images; U-Boot prompt reached"

        return UartStage(
            app,
            success_done=lambda buf: bootrom_judge(buf)[0],
            failure_done=lambda buf: (
                BOOTROM_FAILURE_RE.search(console_text(buf)) is not None
            ),
            judge=bootrom_judge,
            success_quiet_s=1.0,
        )

    if app == "hello_world":

        def hello_judge(serial_buf: str) -> tuple[bool, str]:
            """Pass when the once-per-second greeting proves boot + timer."""
            greetings = serial_buf.count(HELLO_GREETING)
            if _default_failure_done(serial_buf) or re.search(r"\bERROR\b", serial_buf):
                return False, "failure marker in output"
            if greetings < HELLO_MIN_GREETINGS:
                return False, (
                    f"only {greetings} greeting(s); "
                    f"need {HELLO_MIN_GREETINGS} to prove the timer tick"
                )
            return True, f"{greetings} greetings observed"

        return UartStage(
            app,
            success_done=lambda buf: buf.count(HELLO_GREETING) >= HELLO_MIN_GREETINGS,
            failure_done=_default_failure_done,
            judge=hello_judge,
        )

    if app == "uart_echo":

        def echo_judge(serial_buf: str) -> tuple[bool, str]:
            """Pass when the typed probe line was echoed back verbatim."""
            if _default_failure_done(serial_buf):
                return False, "failure marker in output"
            if ECHO_EXPECTED in serial_buf:
                return True, (
                    f"probe line round-tripped ({len(ECHO_PROBE)} chars echoed)"
                )
            if ECHO_PROMPT not in serial_buf:
                return False, "no 'frost> ' prompt seen -- program never started"
            return False, "prompt seen but probe response missing -- UART RX broken?"

        return UartStage(
            app,
            success_done=lambda buf: ECHO_EXPECTED in buf,
            failure_done=_default_failure_done,
            judge=echo_judge,
            stimuli=((ECHO_PROMPT, ECHO_PROBE + "\r"),),
        )

    if app == "coremark":
        board_config = BOARD_CONFIG[board]

        def coremark_judge(serial_buf: str) -> tuple[bool, str]:
            """Apply the marker rule, then gate on the 64-bit-tick score."""
            ok, note = marker_verdict(serial_buf)
            if not ok:
                return False, note
            ticks_match = COREMARK_TICKS_RE.search(serial_buf)
            if not ticks_match:
                return False, (
                    "<<PASS>> but 'Total 64-bit ticks' missing from the capture"
                )
            score = (
                board_config["coremark_iterations"]
                * board_clock_freq(board, vector=vector)[0]
                / int(ticks_match.group(1))
            )
            return check_score(board, "coremark", score, tolerance_pct, vector=vector)

        return UartStage(
            app,
            success_done=lambda buf: "<<PASS>>" in buf,
            failure_done=_default_failure_done,
            judge=coremark_judge,
        )

    return UartStage(
        app,
        success_done=lambda buf: "<<PASS>>" in buf,
        failure_done=_default_failure_done,
        judge=marker_verdict,
    )


@dataclass(frozen=True)
class LinuxRoot:
    """The operator's NFS root, as the four environment variables describe it.

    ``nfsroot`` is ``<server>:<path>`` exactly as the loader packs it into the
    bootargs, ``export`` that path as a directory on this host, ``ip`` the
    kernel's ``ip=`` parameter, ``interface`` the device it names, and
    ``kernel`` and ``initrd`` the files the packer loads.
    """

    nfsroot: str
    server: str
    export: Path
    ip: str
    interface: str
    kernel: Path
    initrd: Path
    dtb: Path | None = None


def nfs_interface(ip_spec: str) -> str:
    """Return the interface ``ip=`` names, or the default when it names none.

    The kernel's syntax is
    ``<client>:<server>:<gateway>:<netmask>:<hostname>:<device>:<autoconf>``.
    ``dhcp``, and a spec that leaves the device field empty, let the initramfs
    choose, which selects the kernel's first Ethernet interface.
    """
    fields = ip_spec.split(":")
    if len(fields) >= 6 and fields[5]:
        return fields[5]
    return DEFAULT_NIC_INTERFACE


def linux_root_from_env(
    environment: Mapping[str, str] = os.environ,
    site: Mapping[str, str] | None = None,
    *,
    dtb_override: Path | None = None,
) -> LinuxRoot:
    """Resolve the NFS root from environment settings, then site-file values.

    The server/export and board IP must be supplied; guessing could select
    another site's root. ``FROST_LINUX_NFSROOT`` must be ``<server>:/<path>``.
    Default the kernel and export's initramfs to the pinned release; both paths
    can be overridden.
    """
    remember_serial(environment)
    site = read_site_env() if site is None else site
    values = {
        name: (environment.get(name, "") or site.get(name, "")).strip()
        for name in (*LINUX_ROOT_ENV_VARS, *LINUX_DERIVED_ENV_VARS)
    }
    missing = [name for name in LINUX_ROOT_ENV_VARS if not values[name]]
    if missing:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {', '.join(missing)} unset. The {LINUX_STAGE} stage "
            "boots Debian from its NFS root over the NIC, and which host exports "
            "that root and which address the board takes are site facts no "
            f"checkout knows. Set {', '.join(LINUX_ROOT_ENV_VARS)} in "
            f"{SITE_ENV_FILE.name} beside hw_regression.py, or in the "
            'environment, as docs/debian_nfsroot.md ("Hardware regression") '
            "describes."
        )
    nfsroot = values[LINUX_NFSROOT_ENV]
    server, separator, path = nfsroot.partition(":")
    if not separator or not server or not path.startswith("/"):
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {LINUX_NFSROOT_ENV}={nfsroot!r} is not "
            "<server-ip>:/<path>, the form the bootargs and the initramfs's "
            "nfsmount take."
        )
    ip_spec = values[LINUX_IP_ENV]
    export = Path(path)
    # The pinned release's own image, at the path debian_kernel.py computes,
    # and that release's initramfs in the export. The preflight checks both
    # exist and that the kernel carries the pinned banner, so a derivation
    # that is wrong for a site is reported rather than booted.
    kernel = (
        Path(values[LINUX_KERNEL_ENV]) if values[LINUX_KERNEL_ENV] else kernel_image()
    )
    initrd = (
        Path(values[LINUX_INITRD_ENV])
        if values[LINUX_INITRD_ENV]
        else export / "boot" / f"initrd.img-{KERNEL_RELEASE}"
    )
    dtb = (
        dtb_override.resolve()
        if dtb_override is not None
        else (Path(values[LINUX_DTB_ENV]).resolve() if values[LINUX_DTB_ENV] else None)
    )
    return LinuxRoot(
        nfsroot=nfsroot,
        server=server,
        export=export,
        ip=ip_spec,
        interface=nfs_interface(ip_spec),
        kernel=kernel,
        initrd=initrd,
        dtb=dtb,
    )


def linux_loader_env(root: LinuxRoot) -> dict[str, str]:
    """Return the FROST_LINUX_* variables the loader packs this root from."""
    env = {
        LINUX_NFSROOT_ENV: root.nfsroot,
        LINUX_IP_ENV: root.ip,
        LINUX_KERNEL_ENV: str(root.kernel),
        LINUX_INITRD_ENV: str(root.initrd),
    }
    if root.dtb is not None:
        env[LINUX_DTB_ENV] = str(root.dtb)
    return env


# Probe NFSv3 with ONC RPC NULL, without NFS client tools, an export mount,
# or a privileged source port.
NFS_PROGRAM = 100003
NFS_VERSION = 3
NFS_PORT = 2049
RPC_XID = 0x4652_4F53  # "FROS"
RPC_REPLY = 1
RPC_MSG_ACCEPTED = 0
RPC_SUCCESS = 0
RPC_PROG_MISMATCH = 2
# An accepted reply has xid, message type, reply status, verifier flavor and
# length, padded verifier data, and acceptance status. Bound reads and decoding.
RPC_REPLY_HEAD = 24
RPC_REPLY_MAX = 128
RPC_LAST_FRAGMENT = 0x8000_0000
RPC_FRAGMENT_SIZE = 0x7FFF_FFFF


def _recv_exactly(sock: socket.socket, count: int, deadline: float) -> bytes:
    """Read up to ``count`` bytes until the peer closes or ``deadline`` passes.

    Use one deadline for the probe so a trickling peer cannot extend the wait.
    """
    chunks: list[bytes] = []
    have = 0
    while have < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        sock.settimeout(remaining)
        chunk = sock.recv(count - have)
        if not chunk:
            break
        chunks.append(chunk)
        have += len(chunk)
    return b"".join(chunks)


def probe_nfs3_tcp(
    server: str, port: int = NFS_PORT, timeout_s: float = 5.0
) -> str | None:
    """Return None if the server answers an NFSv3 NULL call over TCP.

    Otherwise return an operator-facing reason to distinguish setup failures
    from board failures.
    """
    call = struct.pack(
        ">10I",
        RPC_XID,
        0,  # message type: CALL
        2,  # RPC version
        NFS_PROGRAM,
        NFS_VERSION,
        0,  # procedure: NULL
        0,  # credential: AUTH_NONE ...
        0,  # ... of length 0
        0,  # verifier: AUTH_NONE ...
        0,  # ... of length 0
    )
    try:
        deadline = time.monotonic() + timeout_s
        with socket.create_connection((server, port), timeout_s) as sock:
            sock.settimeout(timeout_s)
            # Record marking: one final fragment holding the whole call.
            sock.sendall(struct.pack(">I", RPC_LAST_FRAGMENT | len(call)) + call)
            header = _recv_exactly(sock, 4, deadline)
            if len(header) < 4:
                return (
                    f"{server}:{port} accepted the connection but answered no "
                    "NFSv3 NULL call -- is nfsd running, or is something else "
                    "on that port?"
                )
            marker = struct.unpack(">I", header)[0]
            wanted = marker & RPC_FRAGMENT_SIZE
            body = _recv_exactly(sock, min(wanted, RPC_REPLY_MAX), deadline)
    except OSError as error:
        return (
            f"{server}:{port} did not answer ({error}). The export must be "
            "served by nfs-kernel-server over TCP, reachable from this host."
        )
    # Accept only a bounded final fragment. Reject short or split records before
    # decoding so they cannot cause a traceback.
    if (
        not marker & RPC_LAST_FRAGMENT
        or not RPC_REPLY_HEAD <= wanted <= RPC_REPLY_MAX
        or len(body) < wanted
    ):
        record = "final" if marker & RPC_LAST_FRAGMENT else "continued"
        return (
            f"{server}:{port} answered {len(body)} bytes of a {wanted}-byte "
            f"{record} record, which is not an NFSv3 NULL reply"
        )
    xid, message_type, reply_stat = struct.unpack(">3I", body[:12])
    if xid != RPC_XID:
        return f"{server}:{port} answered another call (xid {xid:#x})"
    if message_type != RPC_REPLY or reply_stat != RPC_MSG_ACCEPTED:
        return (
            f"{server}:{port} denied the NFSv3 NULL call (RPC reply_stat "
            f"{reply_stat}); check the server's authentication and firewall"
        )
    # XDR pads the opaque verifier to a multiple of four bytes; the acceptance
    # status follows the padded data.
    verifier_length = struct.unpack(">I", body[16:20])[0]
    accept_at = 20 + ((verifier_length + 3) & ~3)
    if len(body) < accept_at + 4:
        return (
            f"{server}:{port} answered a reply whose {verifier_length}-byte "
            "verifier leaves no acceptance status"
        )
    accept_stat = struct.unpack(">I", body[accept_at : accept_at + 4])[0]
    if accept_stat == RPC_SUCCESS:
        return None
    if accept_stat == RPC_PROG_MISMATCH:
        return (
            f"{server}:{port} serves NFS but not version 3, and version 3 is "
            "the only one besides 2 that the initramfs's nfsmount speaks: set "
            "vers3=y under [nfsd] in /etc/nfs.conf and restart nfs-server"
        )
    return f"{server}:{port} refused the NFSv3 NULL call (accept_stat {accept_stat})"


# Build current sources statically for Debian: the Buildroot copies need musl,
# and frost_nettest must run while its NFS root's link is down.
ROOT_PROGRAM_SRC = Path("linux/buildroot-external/package/frost-stress/src")
ROOT_PROGRAMS = (
    "frost_stress",
    "frost_nettest",
    "frost_isa_probe",
    "frost_supm_probe",
)
ROOT_PROGRAM_EXTRA_SOURCES: dict[str, tuple[str, ...]] = {
    "frost_isa_probe": ("frost_isa_probe_asm.S",),
}
ROOT_PROGRAM_EXTRA_CFLAGS: dict[str, tuple[str, ...]] = {
    "frost_isa_probe": (
        "-no-pie",
        "-march=rv64gc",
        "-mabi=lp64d",
        "-fno-tree-vectorize",
        "-fno-builtin",
    ),
    "frost_supm_probe": (
        "-march=rv64gc",
        "-mabi=lp64d",
        "-fno-tree-vectorize",
        "-fno-builtin",
    ),
}
# Explicit named exception for the pre-session scalar binary scan: only
# frost_isa_probe's assembly leaf routines (prefix isa_probe_) may hold
# non-RV64GC encodings; every other function and every other root program
# must remain scalar RV64GC.
ROOT_PROGRAM_EXT_LEAF_PREFIXES: dict[str, tuple[str, ...]] = {
    "frost_isa_probe": ("isa_probe_",),
}
ROOT_PROGRAM_CFLAGS = ("-O2", "-static")
# Match Tag_RISCV_arch attribute strings emitted by readelf -A and symbols/words
# emitted by objdump -d -M no-aliases.
_RISCV_ARCH_TAG_RE = re.compile(r'Tag_RISCV_arch:\s*"([^"]+)"')
_ELF_FUNC_RE = re.compile(r"^[0-9a-fA-F]+ <([^>]+)>:")
_OBJDUMP_INSN_RE = re.compile(r"^\s*([0-9a-fA-F]+):\s+([0-9a-fA-F]{4,16})\s+(\S+)")
_EXT_CSR_NUMS = frozenset((0x008, 0x009, 0x00A, 0x00F, 0xC20, 0xC21, 0xC22))
# Cross prefixes, in order: FROST_LINUX_CROSS_COMPILE (the Docker image sets
# it), the one Buildroot's own build produced (this stage's loader builds it),
# then Debian's cross gcc.
CROSS_COMPILE_ENV = "FROST_LINUX_CROSS_COMPILE"
BUILDROOT_CROSS = Path("linux/build-mmu/host/bin/riscv64-linux-")
DEBIAN_CROSS = "riscv64-linux-gnu-"


def resolve_cross_compile(
    repo: Path, environment: Mapping[str, str] = os.environ
) -> str:
    """Return the riscv64 Linux cross prefix that builds the root's programs."""
    configured = environment.get(CROSS_COMPILE_ENV, "").strip()
    candidates = [*([configured] if configured else []), str(repo / BUILDROOT_CROSS)]
    candidates.append(DEBIAN_CROSS)
    for prefix in candidates:
        if shutil.which(prefix + "gcc"):
            return prefix
    raise LinuxEnvironmentError(
        f"{ENV_NOT_READY}: no riscv64 Linux cross compiler for the root's "
        f"{', '.join(ROOT_PROGRAMS)}. Tried "
        f"{', '.join(prefix + 'gcc' for prefix in candidates)}. Install one "
        f"(Debian: gcc-riscv64-linux-gnu), set {CROSS_COMPILE_ENV} to a prefix, "
        "or build Buildroot once (make -C sw/apps/linux_boot), whose own "
        "toolchain is the second candidate."
    )


def _is_non_scalar_riscv_insn(word_hex: str, mnemonic: str) -> bool:
    """Return True if a disassembled 32-bit instruction is a non-RV64GC vector encoding."""
    if len(word_hex) != 8:
        return False
    word = int(word_hex, 16)
    opcode = word & 0x7F
    funct3 = (word >> 12) & 0x7
    csr = word >> 20
    return (
        mnemonic.startswith("v")
        or opcode in (0x57, 0x77)
        or (opcode in (0x07, 0x27) and funct3 in (0, 5, 6, 7))
        or (opcode == 0x73 and funct3 != 0 and csr in _EXT_CSR_NUMS)
    )


def _check_scalar_static_binary(cross: str, built: Path, name: str) -> None:
    """Verify a static root program carries plain RV64GC attributes and opcodes.

    Fail closed when ``readelf`` or ``objdump`` is missing, exits nonzero, or
    produces no verifiable output. Only programs listed in
    ``ROOT_PROGRAM_EXT_LEAF_PREFIXES`` may carry non-RV64GC encodings, and only
    inside functions matching their declared leaf-routine prefixes.
    """
    readelf = shutil.which(cross + "readelf")
    if readelf is None:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {cross}readelf is not on PATH; cannot verify "
            f"Tag_RISCV_arch for {name}"
        )
    done = subprocess.run([readelf, "-A", str(built)], capture_output=True, text=True)
    if done.returncode != 0:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {readelf} -A failed for {name} (exit "
            f"{done.returncode}): {done.stderr.strip()[-500:]}"
        )
    match = _RISCV_ARCH_TAG_RE.search(done.stdout)
    if match is None:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {readelf} -A reported no Tag_RISCV_arch for {name}"
        )
    arch = match.group(1).lower()
    head, _, rest = arch.partition("_")
    tokens = set(re.findall(r"[a-z]", head.removeprefix("rv64").removeprefix("rv32")))
    for token in rest.split("_"):
        if token:
            tokens.add(re.sub(r"\d+p\d+$", "", token))
    if "v" in tokens or any(tok.startswith("zve") for tok in tokens):
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {cross}gcc linked {name} against a static C library "
            f"whose Tag_RISCV_arch ({match.group(1)}) includes extensions beyond "
            f"RV64GC. Set {CROSS_COMPILE_ENV} to an RV64GC static toolchain (such as "
            "linux/build-mmu/host/bin/riscv64-linux-)."
        )

    objdump = shutil.which(cross + "objdump")
    if objdump is None:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {cross}objdump is not on PATH; cannot scan "
            f"instructions of {name}"
        )
    dis = subprocess.run(
        [objdump, "-d", "-M", "no-aliases", str(built)], capture_output=True, text=True
    )
    if dis.returncode != 0:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {objdump} -d failed for {name} (exit "
            f"{dis.returncode}): {dis.stderr.strip()[-500:]}"
        )
    allowed_prefixes = ROOT_PROGRAM_EXT_LEAF_PREFIXES.get(name, ())
    current_symbol = ""
    instructions = 0
    bad_insns: list[str] = []
    for line in dis.stdout.splitlines():
        fn_match = _ELF_FUNC_RE.match(line)
        if fn_match is not None:
            current_symbol = fn_match.group(1)
            continue
        insn_match = _OBJDUMP_INSN_RE.match(line)
        if insn_match is None:
            continue
        instructions += 1
        if _is_non_scalar_riscv_insn(insn_match.group(2), insn_match.group(3)):
            if any(current_symbol.startswith(prefix) for prefix in allowed_prefixes):
                continue
            if len(bad_insns) < 4:
                bad_insns.append(f"{current_symbol or '<unknown>'}: {line.strip()}")
    if instructions == 0:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {objdump} -d disassembled no instructions for {name}"
        )
    if bad_insns:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {name} contains non-RV64GC encoding(s) outside "
            f"allowed leaf routines: {'; '.join(bad_insns)}"
        )


def install_root_programs(repo: Path, export: Path, cross: str) -> str:
    """Build the programs statically, install them in the export, and return a note.

    The caller must be able to write ``usr/local/bin``. Stage each program
    beside its target and rename atomically so boards cannot see partial files.
    """
    target = export / LINUX_ROOT_BIN.lstrip("/")
    if not target.is_dir():
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {target} is not a directory. The stage installs "
            f"{', '.join(ROOT_PROGRAMS)} there, in root's "
            "PATH on the root filesystem."
        )
    if not os.access(target, os.W_OK):
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {target} is not writable by this user, so the "
            "stage cannot install the programs it types. The export tree "
            "belongs to root; give this user that one directory, for example "
            f"'install -d -m 755 -o {os.environ.get('USER', '<user>')} {target}' "
            "on the server."
        )
    names = []
    with tempfile.TemporaryDirectory() as scratch:
        for name in ROOT_PROGRAMS:
            built = Path(scratch) / name
            sources = [
                str(repo / ROOT_PROGRAM_SRC / f"{name}.c"),
                *(
                    str(repo / ROOT_PROGRAM_SRC / extra)
                    for extra in ROOT_PROGRAM_EXTRA_SOURCES.get(name, ())
                ),
            ]
            command = [
                cross + "gcc",
                *ROOT_PROGRAM_CFLAGS,
                *ROOT_PROGRAM_EXTRA_CFLAGS.get(name, ()),
                "-o",
                str(built),
                *sources,
            ]
            done = subprocess.run(command, capture_output=True, text=True)
            if done.returncode != 0:
                raise LinuxEnvironmentError(
                    f"{ENV_NOT_READY}: {' '.join(command)} exited "
                    f"{done.returncode}:\n{done.stderr.strip()[-1000:]}"
                )
            _check_scalar_static_binary(cross, built, name)
            # A unique name beside the target: the rename is atomic, and two
            # regressions installing at once cannot write each other's file.
            handle, staged_name = tempfile.mkstemp(dir=target, prefix=f".{name}.")
            os.close(handle)
            staged = Path(staged_name)
            try:
                shutil.copyfile(built, staged)
                staged.chmod(0o755)
                staged.replace(target / name)
            except OSError:
                staged.unlink(missing_ok=True)
                raise
            names.append(name)
    return f"installed {', '.join(names)} in {target} ({cross}gcc, static)"


def install_root_module(
    export: Path, cross: str, environment: Mapping[str, str] = os.environ
) -> str:
    """Install the memory error module beside the programs and return a note.

    Build it for the pinned kernel with linux/debian_kernel.py unless the
    environment names a prebuilt one (``FROST_MEMERR_MODULE``). Stage it beside
    its target and rename it, as install_root_programs() does.
    """
    target = export / LINUX_ROOT_BIN.lstrip("/")
    named = environment.get(MEMERR.env)
    try:
        module = Path(named) if named else build_module(None, cross, MEMERR)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as failure:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: building {MEMERR.name}.ko for {KERNEL_RELEASE} "
            f"failed: {failure}"
        ) from failure
    if not module.is_file():
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {MEMERR.env}={module} is not a file"
        )
    handle, staged_name = tempfile.mkstemp(dir=target, prefix=f".{MEMERR.name}.")
    os.close(handle)
    staged = Path(staged_name)
    try:
        shutil.copyfile(module, staged)
        staged.chmod(0o644)
        staged.replace(target / module.name)
    except OSError:
        staged.unlink(missing_ok=True)
        raise
    origin = f"{MEMERR.env}" if named else f"built for {KERNEL_RELEASE}"
    return f"installed {module.name} in {target} ({origin})"


def memerr_values(serial_buf: str) -> dict[str, int] | None:
    """Return the last memory error readback's fields, or None without one."""
    matches = list(LINUX_MEMERR_RE.finditer(serial_buf))
    if not matches:
        return None
    match = matches[-1]
    values = (int(value) for value in match.groups())
    result = dict(zip(LINUX_MEMERR_FIELDS, values, strict=True))
    # A previous command's pass cannot validate a later readback.
    start = matches[-2].end() if len(matches) > 1 else 0
    result["selftest"] = int(
        LINUX_MEMERR_SELFTEST_RE.search(serial_buf, start, match.start()) is not None
    )
    return result


def memerr_problems(
    values: Mapping[str, int], *, has_ecc_reader: bool = True
) -> list[str]:
    """Return what the memory error readback shows wrong."""
    problems = []
    if has_ecc_reader:
        if values["active"] != 1:
            problems.append("the ECC reader is not active")
        if values["polls_after"] <= values["polls_before"]:
            problems.append(
                f"ECC polls did not advance ({values['polls_before']} then "
                f"{values['polls_after']})"
            )
    elif values["active"] or values["polls_before"] or values["polls_after"]:
        problems.append("unexpected CPU-visible ECC reader activity")
    for name, label in (
        ("ce", "corrected errors"),
        ("ue", "uncorrectable errors"),
        ("rd", "DDR read error responses"),
        ("wr", "DDR write error responses"),
    ):
        if values[name]:
            problems.append(f"{values[name]} {label}")
    if not values["selftest"]:
        problems.append(f"no {LINUX_MEMERR_SELFTEST_PASS} line")
    if values["scrubbed"] < 64 or values["skipped"] != 1:
        problems.append("scrub counters do not include the page and MMIO self-test")
    if values["patrol_after"] <= values["patrol_before"]:
        problems.append("RAM patrol lines did not advance")
    if values["passes_after"] <= values["passes_before"]:
        problems.append("RAM patrol did not complete a pass")
    if values["restore"]:
        problems.append("reloading the daily patrol failed")
    return problems


# Match the console's kernel release before loading the flat Image. The trailing
# space prevents a read ending at a chunk boundary from matching half a release.
KERNEL_BANNER_RE = re.compile(rb"Linux version (\d[\w.+~-]*) ")
KERNEL_SCAN_OVERLAP = 256


def kernel_image_release(image: Path, limit: int = 128 << 20) -> str | None:
    """Return the release from the first Linux version banner within the limit.

    Flat Images contain a readable banner; compressed images may hide it.
    Return None if no banner is found. This does not validate the image format.
    """
    window = b""
    with image.open("rb") as handle:
        read = 0
        while read < limit:
            chunk = handle.read(1 << 20)
            if not chunk:
                break
            read += len(chunk)
            window += chunk
            found = KERNEL_BANNER_RE.search(window)
            if found is not None:
                return found.group(1).decode("ascii", errors="replace")
            window = window[-KERNEL_SCAN_OVERLAP:]
    return None


DRIVER_MODULE = "frost_net10g"


def initrd_driver_note(initrd: Path, limit: int = 8 << 20) -> list[str]:
    """Report a NIC module name visible in the initramfs, without failing preflight.

    initramfs-tools can put compressed modules in an uncompressed cpio segment,
    leaving their names readable. Absence here is inconclusive; use the
    ``lsinitramfs`` check in docs/debian_nfsroot.md, step 3.
    """
    with initrd.open("rb") as handle:
        head = handle.read(limit)
    if DRIVER_MODULE.encode() in head:
        return [f"the initramfs names {DRIVER_MODULE}"]
    return []


DRIVER_SOURCE = Path("linux/frost-net10g/frost_net10g.c")
DRIVER_VERSION_RE = re.compile(r'MODULE_VERSION\("([^"]+)"\)')
DRIVER_REBUILD_REMEDY = (
    "rebuild it from this tree: docs/debian_nfsroot.md, step 3 (dkms add, "
    "build and install frost-net10g/<version> for the root's kernel, then "
    "update-initramfs -u -k <kernel>)"
)
DRIVER_MODULE_FILENAMES = frozenset(
    {
        f"{DRIVER_MODULE}.ko",
        f"{DRIVER_MODULE}.ko.xz",
        f"{DRIVER_MODULE}.ko.zst",
        f"{DRIVER_MODULE}.ko.gz",
    }
)
UNMKINITRAMFS_TOOL = "unmkinitramfs"
MODINFO_TOOL = "modinfo"
UNMKINITRAMFS_TIMEOUT_S = 120.0
MODINFO_TIMEOUT_S = 30.0
MAX_REPORTED_VERSION_LEN = 80


def source_driver_version(repo: Path) -> str:
    """Return the ``MODULE_VERSION`` the tree's NIC driver is built with."""
    source = repo / DRIVER_SOURCE
    try:
        text = source.read_text(errors="replace")
    except OSError as error:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: cannot read the driver source {source}: {error}"
        ) from error
    found = DRIVER_VERSION_RE.search(text)
    if found is None:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {source} has no MODULE_VERSION line"
        )
    return found.group(1)


_SEEN_SERIALS: set[str] = set()


def remember_serial(environment: Mapping[str, str] | None) -> None:
    """Note the cable serial of an environment mapping, to be masked everywhere."""
    if environment is not None:
        serial = environment.get(JTAG_SERIAL_ENV, "").strip()
        if serial:
            _SEEN_SERIALS.add(serial)


def mask_serial(text: str, environment: Mapping[str, str] | None = None) -> str:
    """Replace every known JTAG cable serial in text meant for a log.

    Known serials are the process environment's, those of any environment the
    runner was given, and the one passed here. Matching is case-insensitive.
    """
    remember_serial(environment)
    serials = set(_SEEN_SERIALS)
    serials.add(os.environ.get(JTAG_SERIAL_ENV, "").strip())
    for serial in sorted(serials - {""}, key=len, reverse=True):
        text = re.sub(re.escape(serial), "<cable serial>", text, flags=re.IGNORECASE)
    return text


def _remove_tree(path: Path) -> None:
    """Remove a temporary directory tree even if unpacked entries are read-only."""
    if not path.exists():
        return
    try:
        shutil.rmtree(path)
        return
    except PermissionError:
        pass
    for root, dirs, _ in os.walk(path, topdown=True, followlinks=False):
        root_path = Path(root)
        if not root_path.is_symlink():
            try:
                os.chmod(root_path, 0o700)
            except OSError:
                pass
        for name in dirs:
            entry = root_path / name
            if not entry.is_symlink():
                try:
                    os.chmod(entry, 0o700)
                except OSError:
                    pass
    shutil.rmtree(path)


def _raise_oserror(error: OSError) -> None:
    """Fail closed when walking an unpacked initramfs directory fails."""
    raise error


def _format_version_token(version: str, limit: int = MAX_REPORTED_VERSION_LEN) -> str:
    """Return a length-bounded, escaped rendering of a tool-reported version."""
    if len(version) > limit:
        return f"{version[:limit]!r}... ({len(version)} chars)"
    if version != version.strip() or any(ord(c) < 32 or ord(c) >= 127 for c in version):
        return repr(version)
    return version


def _last_nonempty_line(text: str, limit: int = 160) -> str:
    """Return the last non-empty line in text, bounded and escaped if needed."""
    for line in reversed(text.splitlines()):
        cleaned = line.strip()
        if cleaned:
            return _format_version_token(cleaned, limit=limit)
    return ""


def _run_initrd_tool(
    tool: str,
    args: Sequence[str],
    timeout_s: float,
    target: str,
    wanted: str,
    rebuild: str,
) -> str:
    """Run ``unmkinitramfs`` or ``modinfo`` without a shell and return stdout."""
    executable = shutil.which(tool)
    if executable is None:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {tool} is not installed on PATH (needed to check "
            f"{DRIVER_MODULE} in {target}; this tree's driver is version {wanted}); "
            f"install {tool} or {rebuild}."
        )
    try:
        done = subprocess.run(
            [executable, *args],
            capture_output=True,
            check=False,
            timeout=timeout_s,
            stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired as error:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {tool} timed out after {timeout_s:g}s while checking "
            f"{target} (this tree's driver is version {wanted}); {rebuild}."
        ) from error
    except OSError as error:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: cannot run {tool} while checking {target}: {error} "
            f"(this tree's driver is version {wanted}); {rebuild}."
        ) from error
    stdout = (done.stdout or b"").decode("utf-8", errors="replace")
    stderr = (done.stderr or b"").decode("utf-8", errors="replace")
    if done.returncode != 0:
        detail = _last_nonempty_line(stderr) or _last_nonempty_line(stdout)
        suffix = f": {detail}" if detail else ""
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {tool} exited {done.returncode} while checking "
            f"{target}{suffix} (this tree's driver is version {wanted}); {rebuild}."
        )
    return stdout


def _parse_modinfo_version(stdout: str, target: str, wanted: str, rebuild: str) -> str:
    """Return the single newline-ended version line from ``modinfo -F version``."""
    if not stdout or not stdout.strip():
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {MODINFO_TOOL} printed no version for {target} "
            f"(version unknown), and this tree's driver (MODULE_VERSION in "
            f"{DRIVER_SOURCE}) is version {wanted}; {rebuild}."
        )
    if not stdout.endswith("\n"):
        shown = _format_version_token(stdout)
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {MODINFO_TOOL} output for {target} did not end with "
            f"a newline ({shown}), and this tree's driver (MODULE_VERSION in "
            f"{DRIVER_SOURCE}) is version {wanted}; {rebuild}."
        )
    lines = stdout[:-1].split("\n")
    if len(lines) != 1:
        sample = [
            _format_version_token(line) if line else repr("") for line in lines[:3]
        ]
        reported = ", ".join(sample)
        if len(lines) > 3:
            reported += f", ... ({len(lines)} lines total)"
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {MODINFO_TOOL} reported multiple versions "
            f"({reported}) for {target}, and this tree's driver "
            f"(MODULE_VERSION in {DRIVER_SOURCE}) is version {wanted}; {rebuild}."
        )
    return lines[0]


def check_initrd_driver_version(initrd: Path, repo: Path) -> list[str]:
    """Fail unless every unpacked ``frost_net10g`` module matches the tree.

    Unpacks the initramfs into a private temporary directory with
    ``unmkinitramfs`` (which extracts the early section and the first
    compressed archive, the layout produced by ``update-initramfs``), finds
    every regular file named ``frost_net10g.ko`` (or with ``.xz``, ``.zst``,
    or ``.gz``), and reads each copy's version with ``modinfo -F version``.
    Passes only if at least one copy exists and every copy reports the tree's
    exact ``MODULE_VERSION``. The Linux stage also verifies the loaded
    driver's version directly from ``/sys/module/frost_net10g/version`` after
    boot.
    """
    wanted = source_driver_version(repo)
    rebuild = DRIVER_REBUILD_REMEDY
    for tool in (UNMKINITRAMFS_TOOL, MODINFO_TOOL):
        if shutil.which(tool) is None:
            raise LinuxEnvironmentError(
                f"{ENV_NOT_READY}: {tool} is not installed on PATH (needed to check "
                f"{DRIVER_MODULE} in {initrd}; this tree's driver is version "
                f"{wanted}); install {tool} or {rebuild}."
            )
    tmpdir: Path | None = None
    try:
        tmpdir = Path(tempfile.mkdtemp(prefix="frost-initrd-"))
        _run_initrd_tool(
            UNMKINITRAMFS_TOOL,
            [os.path.abspath(initrd), str(tmpdir)],
            UNMKINITRAMFS_TIMEOUT_S,
            str(initrd),
            wanted,
            rebuild,
        )
        modules: list[Path] = []
        for root, dirs, files in os.walk(
            tmpdir, followlinks=False, onerror=_raise_oserror
        ):
            dirs.sort()
            files.sort()
            root_path = Path(root)
            for name in dirs:
                if name in DRIVER_MODULE_FILENAMES and (root_path / name).is_symlink():
                    rel = (root_path / name).relative_to(tmpdir).as_posix()
                    raise LinuxEnvironmentError(
                        f"{ENV_NOT_READY}: {initrd} ({rel}) is a symbolic link, not "
                        f"a regular {DRIVER_MODULE} module; this tree's driver "
                        f"(MODULE_VERSION in {DRIVER_SOURCE}) is version {wanted}; "
                        f"{rebuild}."
                    )
            for name in files:
                if name not in DRIVER_MODULE_FILENAMES:
                    continue
                entry = root_path / name
                if not stat.S_ISREG(entry.lstat().st_mode):
                    rel = entry.relative_to(tmpdir).as_posix()
                    raise LinuxEnvironmentError(
                        f"{ENV_NOT_READY}: {initrd} ({rel}) is not a regular "
                        f"{DRIVER_MODULE} module; this tree's driver "
                        f"(MODULE_VERSION in {DRIVER_SOURCE}) is version {wanted}; "
                        f"{rebuild}."
                    )
                modules.append(entry)
        if not modules:
            raise LinuxEnvironmentError(
                f"{ENV_NOT_READY}: {initrd} carries no {DRIVER_MODULE} module, and "
                f"this tree's driver (MODULE_VERSION in {DRIVER_SOURCE}) is version "
                f"{wanted}; {rebuild}."
            )
        for module_path in modules:
            rel = module_path.relative_to(tmpdir).as_posix()
            target = f"{initrd} ({rel})"
            stdout = _run_initrd_tool(
                MODINFO_TOOL,
                ["-F", "version", str(module_path)],
                MODINFO_TIMEOUT_S,
                target,
                wanted,
                rebuild,
            )
            found_version = _parse_modinfo_version(stdout, target, wanted, rebuild)
            if found_version != wanted:
                shown = _format_version_token(found_version)
                raise LinuxEnvironmentError(
                    f"{ENV_NOT_READY}: {target} has {DRIVER_MODULE} version {shown}, "
                    f"and this tree's driver (MODULE_VERSION in {DRIVER_SOURCE}) is "
                    f"version {wanted}; {rebuild}."
                )
        return [
            f"the initramfs carries {DRIVER_MODULE} version {wanted} "
            "(checked: the early section and the first compressed archive)"
        ]
    except LinuxEnvironmentError:
        raise
    except Exception as error:  # noqa: BLE001 - one boundary for any check failure
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: cannot check the {DRIVER_MODULE} version in "
            f"{initrd}: {type(error).__name__}: {error}. The initramfs has to carry "
            f"version {wanted}; {rebuild}."
        ) from error
    finally:
        if tmpdir is not None:
            _remove_tree(tmpdir)


def subnet_note(root: LinuxRoot) -> list[str]:
    """Report whether the NFS server shares the board's subnet.

    After loopback drops the link, the connected route returns automatically;
    a gateway route may not. ``nettest_command`` checks root access afterward.
    """
    fields = root.ip.split(":")
    if len(fields) < 4:
        return []  # dhcp, or no netmask to compare against
    try:
        board = ipaddress.ip_interface(f"{fields[0]}/{fields[3]}")
        server = ipaddress.ip_address(root.server)
    except ValueError:
        return []
    if server in board.network:
        return [f"the server shares the board's subnet ({board.network})"]
    return [
        f"the server {server} is outside the board's subnet {board.network}: "
        f"{LINUX_NET_COMMAND} takes the root's interface down, and only its "
        "connected route comes back, so the root may not"
    ]


# Debian's root has no usable root password, so the console login the stage
# drives has to be an autologin; without it the stage can only time out at the
# prompt. The drop-in is in docs/debian_nfsroot.md, "2. Configure the tree".
CONSOLE_UNIT = "serial-getty@ttyS0.service"
CONSOLE_AUTOLOGIN = "--autologin"


def console_autologin_files(export: Path) -> list[Path]:
    """Return the export's console overrides that configure an autologin."""
    unit_dir = export / "etc/systemd/system"
    candidates = [
        unit_dir / CONSOLE_UNIT,
        *sorted((unit_dir / f"{CONSOLE_UNIT}.d").glob("*.conf")),
    ]
    found = []
    for candidate in candidates:
        try:
            text = candidate.read_text(errors="replace")
        except OSError:
            continue
        # A commented-out drop-in does not enable autologin.
        live = [
            line
            for line in text.splitlines()
            if not line.lstrip().startswith(("#", ";"))
        ]
        if any(CONSOLE_AUTOLOGIN in line for line in live):
            found.append(candidate)
    return found


def linux_root_preflight(
    root: LinuxRoot, repo: Path, environment: Mapping[str, str] = os.environ
) -> list[str]:
    """Check the NFS root, install test programs, and return diagnostic notes.

    Raise ``LinuxEnvironmentError`` with an ``ENV_NOT_READY`` message for setup
    failures so they are not reported as RTL regressions. This is the one
    boundary of the preflight: any other exception from inside it becomes the
    same error, with its message masked, so no traceback reaches the user.
    """
    remember_serial(environment)
    try:
        return _linux_root_preflight(root, repo, environment)
    except LinuxEnvironmentError:
        raise
    except Exception as error:  # noqa: BLE001
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: the preflight failed unexpectedly "
            f"({type(error).__name__}: {error})"
        ) from None


def _linux_root_preflight(
    root: LinuxRoot, repo: Path, environment: Mapping[str, str]
) -> list[str]:
    """Run the preflight checks; see ``linux_root_preflight``."""
    notes = []
    if not root.export.is_dir():
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: the export {root.export} is not a directory on "
            f"this host. {LINUX_NFSROOT_ENV} names the server's export, and the "
            "stage installs into it and reads the tree's console configuration, "
            "so the loader has to run where that directory is."
        )
    reason = probe_nfs3_tcp(root.server)
    if reason is not None:
        raise LinuxEnvironmentError(f"{ENV_NOT_READY}: {reason}")
    notes.append(f"{root.nfsroot} answers an NFSv3 NULL call over TCP")
    for name, path in (
        (LINUX_KERNEL_ENV, root.kernel),
        (LINUX_INITRD_ENV, root.initrd),
    ):
        if not path.is_file():
            raise LinuxEnvironmentError(
                f"{ENV_NOT_READY}: {name}={path} is not a file on this host. "
                "The loader packs the kernel and the initramfs by path; copy "
                "both to this host if it is not the server."
            )
        if path.stat().st_size == 0:
            raise LinuxEnvironmentError(f"{ENV_NOT_READY}: {name}={path} is empty")
    release = kernel_image_release(root.kernel)
    if release is None:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {LINUX_KERNEL_ENV}={root.kernel} carries no "
            "'Linux version' banner, so it is not an uncompressed flat Image. "
            "Debian installs one as /boot/vmlinux-<release>; vmlinuz-<release> "
            "is the compressed kernel, which the packer cannot use."
        )
    if release != KERNEL_RELEASE:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {LINUX_KERNEL_ENV}={root.kernel} is "
            f"{release}, and this tree pins {KERNEL_RELEASE} "
            "(linux/debian_kernel.py). The stage requires the pinned banner, so "
            "one kernel is under test on either root: install that version on "
            "the root (docs/debian_nfsroot.md) or bump the pin."
        )
    initrd_mib = root.initrd.stat().st_size / (1 << 20)
    notes.append(
        f"kernel {root.kernel} ({release}), initramfs {root.initrd} "
        f"({initrd_mib:.1f} MiB)"
    )
    if root.dtb is not None:
        if not root.dtb.is_file():
            raise LinuxEnvironmentError(
                f"{ENV_NOT_READY}: {LINUX_DTB_ENV}={root.dtb} is not a file on this host"
            )
        dtb_bytes = root.dtb.read_bytes()
        if len(dtb_bytes) < 40:
            raise LinuxEnvironmentError(
                f"{ENV_NOT_READY}: {LINUX_DTB_ENV}={root.dtb} is shorter than an FDT header"
            )
        magic, totalsize = struct.unpack_from(">2I", dtb_bytes, 0)
        if magic != 0xD00DFEED or totalsize != len(dtb_bytes):
            raise LinuxEnvironmentError(
                f"{ENV_NOT_READY}: {LINUX_DTB_ENV}={root.dtb} is not a valid compiled DTB"
            )
        if totalsize + 0x2000 > 0x10000:
            raise LinuxEnvironmentError(
                f"{ENV_NOT_READY}: {LINUX_DTB_ENV}={root.dtb} ({totalsize} B) "
                "exceeds the boot DTB slot"
            )
        notes.append(f"device tree {root.dtb} ({totalsize} B)")
    notes.extend(initrd_driver_note(root.initrd))
    notes.extend(check_initrd_driver_version(root.initrd, repo))
    notes.extend(subnet_note(root))
    consoles = console_autologin_files(root.export)
    if not consoles:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: no {CONSOLE_AUTOLOGIN} in the export's "
            f"{CONSOLE_UNIT} override. The stage logs in on the UART, and "
            "Debian's root has no usable password, so the console getty has to "
            "log root in by itself; add the drop-in from "
            'docs/debian_nfsroot.md, "2. Configure the tree".'
        )
    notes.append(f"console autologin from {consoles[0]}")
    cross = resolve_cross_compile(repo, environment)
    notes.append(install_root_programs(repo, root.export, cross))
    notes.append(install_root_module(root.export, cross, environment))
    return notes


def nettest_repeat(environment: Mapping[str, str] = os.environ) -> int:
    """Return the number of network test repetitions ``NETTEST_REPEAT_ENV`` asks for."""
    text = environment.get(NETTEST_REPEAT_ENV, "").strip()
    if not text:
        return 1
    if not text.isdigit() or not 1 <= int(text) <= NETTEST_REPEAT_MAX:
        raise ValueError(
            f"{NETTEST_REPEAT_ENV}={text!r}: give a whole number from 1 to "
            f"{NETTEST_REPEAT_MAX}"
        )
    return int(text)


def nettest_poke(environment: Mapping[str, str] = os.environ) -> int:
    """Return the seconds into the test ``NETTEST_POKE_ENV`` asks for, or 0."""
    text = environment.get(NETTEST_POKE_ENV, "").strip()
    if not text:
        return 0
    if not text.isdigit() or not 1 <= int(text) <= NETTEST_POKE_MAX_S:
        raise ValueError(
            f"{NETTEST_POKE_ENV}={text!r}: give a whole number of seconds from 1 "
            f"to {NETTEST_POKE_MAX_S}"
        )
    return int(text)


def nettest_poke_command(poke_s: int, tag: str) -> str:
    """Return the shell text that schedules one NFS request ``poke_s`` seconds on.

    A subshell starts ``timeout`` and ``sleep`` while the root is reachable,
    detached so the test starts at once and the interactive shell neither
    waits for it nor reports it; init reaps it. When the sleep ends, the shell
    builtin ``[ -e ]`` looks up a name in the root's ``/root`` that has never
    existed (``tag`` makes it unique), so no dentry, positive or negative, can
    answer it: the client must send a LOOKUP to the server. On the ``hard``
    mount that request waits until the link is back. Its output is discarded
    and the descriptors that restore the link are closed in it.
    """
    probe = LINUX_ROOT_ALIVE_FILE.rsplit("/", 1)[0] + f"/.frost_poke.{tag}"
    return (
        f"( timeout -k 5 {poke_s + NETTEST_POKE_GRACE_S} sh -c "
        f'"sleep {poke_s}; [ -e {probe} ]" > /dev/null 2>&1 3>&- 4>&- 5>&- & ); '
        f"echo FROST_NET_DIAG: nfs poke scheduled at +{poke_s} s; "
    )


def nettest_command(interface: str, repeat: int = 1, poke_s: int = 0) -> str:
    """Return a shell command that runs frost_nettest and restores the root's link.

    Copy the static binary to tmpfs so instruction or library faults cannot
    block on the root while loopback takes the link down. Disable IPv6 during
    the test: autoconfiguration traffic returning through loopback fails idle
    checks. IPv4 ARP requests for the NFS server can still go out while the
    interface is looped; the test captures them and accounts for them.
    Require a successful dentry and inode cache drop before the test.
    The test opens its sysfs descriptors before taking the interface down.
    Hold it down for 65 seconds to expire NFS's default directory attribute
    cache: dropping caches alone allows pathname lookups before interface-down
    to refresh it.
    The test leaves the interface down with loopback off.

    Open restoration files while the link is up. Restore the saved MTU and
    flags using shell built-ins and those descriptors, then enable IPv6.
    Absolute sysfs and proc lookups can revalidate the NFS root. The login
    shell maps the NFS root; reclaim of its pages can block recovery.
    The bounded helper's exec can also block if the link stays down,
    causing a stage TIMEOUT.

    Create a file on the root, sync, and remove it under a timeout. The printed
    status checks that the link, route, server access, and writes recovered.

    With ``repeat`` above 1, run all of that ``repeat`` times in one loop:
    each repetition restores the link and checks the root before the next.
    The test learns its repetition from ``FROST_NETTEST_REPETITION`` and
    prints the verdicts of all but the last under ``FROST_NET_DIAG``. A root
    that does not come back ends the loop.

    With ``poke_s`` above 0, each run of the test is preceded, after the cache
    drop, by ``nettest_poke_command``: an NFS request ``poke_s`` seconds into
    the test, inside its link hold-down.
    """
    sysfs = shlex.quote(f"/sys/class/net/{interface}")
    ipv6 = shlex.quote(f"/proc/sys/net/ipv6/conf/{interface}/disable_ipv6")
    run_nettest = (
        f"FROST_NETTEST_EXPIRE_NFS_CACHE=1 {LINUX_TMPFS}/{LINUX_NET_COMMAND} "
        f"{shlex.quote(interface)}"
    )
    if repeat > 1:
        poke = nettest_poke_command(poke_s, "$$.$r") if poke_s else ""
        return (
            f"r=1; while [ $r -le {repeat} ]; do "
            f'if [ $r -lt {repeat} ]; then t=FROST_NET_DIAG; d=" rep=$r"; '
            "else t=FROST_NET_LOOPBACK; d=; fi; "
            f"m=$(cat {sysfs}/mtu); f=$(cat {sysfs}/flags); echo 1 > {ipv6}; "
            f"cp {LINUX_ROOT_BIN}/{LINUX_NET_COMMAND} {LINUX_TMPFS}/; "
            "{ if echo 2 > /proc/sys/vm/drop_caches; then "
            f"{poke}"
            f"FROST_NETTEST_REPETITION=$r/{repeat} "
            f"{run_nettest}; "
            'else echo "$t"_FAIL"$d" drop_caches; fi; '
            "echo $m >&3; echo $f >&4; echo 0 >&5; "
            f"}} 3> {sysfs}/mtu 4> {sysfs}/flags 5> {ipv6}; "
            f"timeout -k 5 {LINUX_ROOT_SYNC_S} sh -c "
            f'"echo frost > {LINUX_ROOT_ALIVE_FILE} && sync && '
            f'rm -f {LINUX_ROOT_ALIVE_FILE}"; '
            f"s=$?; echo {LINUX_ROOT_ALIVE_TOKEN}=$s; [ $s = 0 ] || break; "
            "r=$((r+1)); done"
        )
    poke = nettest_poke_command(poke_s, "$$") if poke_s else ""
    return (
        f"m=$(cat {sysfs}/mtu); f=$(cat {sysfs}/flags); echo 1 > {ipv6}; "
        f"cp {LINUX_ROOT_BIN}/{LINUX_NET_COMMAND} {LINUX_TMPFS}/; "
        "{ if echo 2 > /proc/sys/vm/drop_caches; then "
        f"{poke}"
        f"{run_nettest}; "
        "else echo FROST_NET_LOOPBACK'_'FAIL drop_caches; fi; "
        "echo $m >&3; echo $f >&4; echo 0 >&5; "
        f"}} 3> {sysfs}/mtu 4> {sysfs}/flags 5> {ipv6}; "
        f"timeout -k 5 {LINUX_ROOT_SYNC_S} sh -c "
        f'"echo frost > {LINUX_ROOT_ALIVE_FILE} && sync && '
        f'rm -f {LINUX_ROOT_ALIVE_FILE}"; '
        f"echo {LINUX_ROOT_ALIVE_TOKEN}=$?"
    )


def counter_values(serial_buf: str) -> dict[str, str]:
    """Return fields from passing ``frost_stress --counters`` lines.

    The format is ``FROST_COUNTERS: scope=exec-child cycles=N instret=N time=N
    ipc_x1000=N verdict=PASS``. ``LINUX_COUNTER_FAIL_RE`` handles unavailable
    counters and other failures.
    """
    counts: dict[str, str] = {}
    for fields in LINUX_COUNTER_RE.findall(serial_buf):
        counts.update(field.split("=", 1) for field in fields.split())
    return counts


def tolerated_systemd_units(serial_buf: str) -> list[str]:
    """Return session scopes when they alone explain the last degraded state.

    A complete successful listing and Result=resources for every failed unit
    are required. Missing results, an empty listing and other failures fail
    the systemd check.
    """
    states = list(LINUX_SYSTEMD_STATE_RE.finditer(serial_buf))
    if not states or states[-1].group(1) != "degraded":
        return []
    checks = list(re.finditer(r"^\r*systemd-check[\r]*\n", serial_buf, re.MULTILINE))
    if not checks or checks[-1].end() > states[-1].start():
        return []
    check = serial_buf[checks[-1].end() : states[-1].start()]
    statuses = re.findall(
        r"^\r*failed_list_status=([^\r\n]*)[\r]*\n", check, re.MULTILINE
    )
    if statuses != ["0"]:
        return []
    units = re.findall(
        r"^\r*failed_unit=(\S+) result=([^\r\n]*)[\r]*\n", check, re.MULTILINE
    )
    counts = re.findall(r"^\r*failed_count=([^\r\n]*)[\r]*\n", check, re.MULTILINE)
    if (
        counts != [str(len(units))]
        or not units
        or any(
            not re.fullmatch(r"session-[0-9]+\.scope", unit) or result != "resources"
            for unit, result in units
        )
    ):
        return []
    return [unit for unit, _ in units]


def systemd_state(serial_buf: str) -> str | None:
    """Return the last state, accepting only logind session resource failures."""
    states = LINUX_SYSTEMD_STATE_RE.findall(serial_buf)
    if tolerated_systemd_units(serial_buf):
        return LINUX_SYSTEMD_RUNNING
    return states[-1] if states else None


def root_alive_status(serial_buf: str) -> int | None:
    """Return the last post-loopback root-access status, or None if absent.

    Zero means the file creation, sync, and removal all succeeded.
    """
    matches = LINUX_ROOT_ALIVE_RE.findall(serial_buf)
    return int(matches[-1]) if matches else None


def root_mount_verdict(serial_buf: str, nfsroot: str) -> tuple[bool, str]:
    """Require ``findmnt`` to report the packed NFS export mounted with ``vers=3``."""
    match = LINUX_ROOT_MOUNT_RE.search(serial_buf)
    if match is None:
        return False, f"{LINUX_ROOT_MOUNT_COMMAND}: no nfs line for '/'"
    fstype, source, options = match.groups()
    want_server, _, want_path = nfsroot.partition(":")
    got_server, _, got_path = source.partition(":")
    if got_path.rstrip("/") != want_path.rstrip("/"):
        return False, (f"/ is {fstype} from {source}, not the packed export {nfsroot}")
    if got_server != want_server:
        # Require an exact server match, including hostname versus address.
        return False, (
            f"/ is {fstype} from {source}, and {LINUX_NFSROOT_ENV} names that "
            f"server {want_server}; give it as the address the mount shows"
        )
    if LINUX_ROOT_MOUNT_VERS not in options.split(","):
        return False, (
            f"/ is {fstype} from {source} without {LINUX_ROOT_MOUNT_VERS}: {options}"
        )
    return True, f"/ on {source} ({fstype},{options})"


def nettest_diag_verdicts(serial_buf: str) -> dict[int, tuple[str, str]]:
    """Return each diagnostic repetition's verdict and reason, by repetition."""
    return {
        int(rep): (verdict, reason.strip())
        for verdict, rep, reason in LINUX_NET_DIAG_RE.findall(serial_buf)
    }


def nettest_diag_problems(serial_buf: str, repeat: int) -> list[str]:
    """Name the diagnostic repetitions that failed or printed no verdict."""
    verdicts = nettest_diag_verdicts(serial_buf)
    problems = []
    for rep in range(1, repeat):
        verdict, reason = verdicts.get(rep, ("", ""))
        if not verdict:
            problems.append(f"repetition {rep}: no verdict")
        elif verdict == "FAIL":
            problems.append(f"repetition {rep}: {reason}")
    return problems


def driver_version_verdict(serial_buf: str, expected: str) -> tuple[bool, str]:
    """Require ``/sys/module/frost_net10g/version`` to equal ``expected``."""
    prompt_at = serial_buf.find(LINUX_LOGIN_PROMPT)
    region = serial_buf[prompt_at:] if prompt_at >= 0 else serial_buf
    matches = LINUX_DRIVER_VERSION_RE.findall(region)
    if not matches:
        return (
            False,
            f"{LINUX_DRIVER_VERSION_PATH}: no {LINUX_DRIVER_VERSION_TOKEN}= line "
            f"after login; expected {DRIVER_MODULE} version {expected}; "
            f"{DRIVER_REBUILD_REMEDY}",
        )
    if len(matches) != 1:
        return (
            False,
            f"{LINUX_DRIVER_VERSION_PATH}: multiple {LINUX_DRIVER_VERSION_TOKEN}= "
            f"lines after login; expected {DRIVER_MODULE} version {expected}; "
            f"{DRIVER_REBUILD_REMEDY}",
        )
    got = matches[0]
    if not got or got == LINUX_DRIVER_VERSION_MISSING:
        return (
            False,
            f"{LINUX_DRIVER_VERSION_PATH} is missing or unreadable on the running "
            f"system; expected {DRIVER_MODULE} version {expected}; "
            f"{DRIVER_REBUILD_REMEDY}",
        )
    if got != expected:
        shown = _format_version_token(got)
        return (
            False,
            f"loaded {DRIVER_MODULE} ({LINUX_DRIVER_VERSION_PATH}) is version "
            f"{shown}, and this tree's driver (MODULE_VERSION in {DRIVER_SOURCE}) "
            f"is version {expected}; {DRIVER_REBUILD_REMEDY}",
        )
    return True, f"NIC driver {expected}"


LINUX_ISA_PROBE_PROGRAM = "frost_isa_probe"
LINUX_ISA_PROBE_TOKEN = "FROST_ISA_PROBE"
LINUX_ISA_PROBE_SUMMARY_TOKEN = "FROST_ISA_PROBE_SUMMARY"
LINUX_ISA_PROBE_EXIT_TOKEN = "FROST_ISA_PROBE_EXIT"
LINUX_ISA_EXPECT_CHOICES = ("absent", "present")
LINUX_ISA_EXPECT_DEFAULT = "absent"
LINUX_ISA_PROBE_MIN_VLENB = 16
LINUX_ISA_PROBE_MAX_VLENB = 256
LINUX_ISA_PROBE_TIMEOUT_S = {"absent": 45, "present": 420}
LINUX_ISA_PROBE_CASES: dict[str, tuple[str, ...]] = {
    "absent": ("discover", "illegal", "signal", "ptrace"),
    "present": (
        "discover",
        "switch",
        "signal",
        "ptrace",
        "core",
        "fork",
        "exec",
        "first-use",
    ),
}
LINUX_ISA_CASE_RE = re.compile(
    r"^\r*"
    + LINUX_ISA_PROBE_TOKEN
    + r" id=([0-9a-fA-F]+) case=([a-z-]+) verdict=(PASS|FAIL)((?: [a-z0-9_]+=\S+)*)[ \t\r]*\n",
    re.MULTILINE,
)
LINUX_ISA_SUMMARY_RE = re.compile(
    r"^\r*"
    + LINUX_ISA_PROBE_SUMMARY_TOKEN
    + r" id=([0-9a-fA-F]+) mode=(present|absent|unknown) passed=(\d+) failed=(\d+) "
    r"verdict=(PASS|FAIL)[ \t\r]*\n",
    re.MULTILINE,
)
LINUX_ISA_EXIT_RE = re.compile(
    r"^\r*" + LINUX_ISA_PROBE_EXIT_TOKEN + r" id=([0-9a-fA-F]+) rc=(\d+)[ \t\r]*\n",
    re.MULTILINE,
)
_ZVL_EXT_RE = re.compile(r"^zvl(\d+)b$")


def _is_supported_vlenb(vlenb: int) -> bool:
    """Return True if ``vlenb`` is a supported power-of-two register byte width."""
    return (
        LINUX_ISA_PROBE_MIN_VLENB <= vlenb <= LINUX_ISA_PROBE_MAX_VLENB
        and (vlenb & (vlenb - 1)) == 0
    )


def _max_zvl_vlenb_from_tokens(tokens: list[str]) -> int | None:
    """Return the byte width of the widest ``zvl<N>b`` token, or None."""
    widest_bits = 0
    for token in tokens:
        match = _ZVL_EXT_RE.match(token.strip().lower())
        if match is None:
            continue
        bits = int(match.group(1))
        if bits >= 128 and (bits & (bits - 1)) == 0 and bits > widest_bits:
            widest_bits = bits
    if widest_bits == 0:
        return None
    vlenb = widest_bits // 8
    return vlenb if _is_supported_vlenb(vlenb) else None


def dtb_isa_vlenb(dtb: Path) -> int | None:
    """Return the ``vlenb`` implied by ``zvl<N>b`` in a DTB's ``/cpus/cpu@0``, or None."""
    try:
        blob = dtb.read_bytes()
    except OSError:
        return None
    if len(blob) < 40:
        return None
    magic, totalsize, off_struct, off_strings, _, _, _, _, size_strings, size_struct = (
        struct.unpack_from(">10I", blob, 0)
    )
    if (
        magic != 0xD00DFEED
        or totalsize != len(blob)
        or off_struct + size_struct > totalsize
        or off_strings + size_strings > totalsize
    ):
        return None
    pos = off_struct
    end = off_struct + size_struct
    stack: list[str] = []
    tokens: list[str] = []
    while pos + 4 <= end:
        (tag,) = struct.unpack_from(">I", blob, pos)
        pos += 4
        if tag == 1:  # FDT_BEGIN_NODE
            nul = blob.find(b"\x00", pos, end)
            if nul < 0:
                break
            stack.append(blob[pos:nul].decode("ascii", errors="ignore"))
            pos = (nul + 4) & ~3
        elif tag == 2:  # FDT_END_NODE
            if stack:
                stack.pop()
        elif tag == 3:  # FDT_PROP
            if pos + 8 > end:
                break
            prop_len, nameoff = struct.unpack_from(">2I", blob, pos)
            pos += 8
            val = blob[pos : pos + prop_len]
            pos = (pos + prop_len + 3) & ~3
            if len(stack) == 3 and stack[1] == "cpus" and stack[2].startswith("cpu"):
                str_end = blob.find(
                    b"\x00", off_strings + nameoff, off_strings + size_strings
                )
                if str_end < 0:
                    continue
                pname = blob[off_strings + nameoff : str_end].decode(
                    "ascii", errors="ignore"
                )
                if pname == "riscv,isa-extensions":
                    tokens.extend(
                        part.decode("ascii", errors="ignore")
                        for part in val.split(b"\x00")
                        if part
                    )
                elif pname == "riscv,isa":
                    isa = val.split(b"\x00", 1)[0].decode("ascii", errors="ignore")
                    tokens.extend(isa.split("_")[1:])
        elif tag == 4:  # FDT_NOP
            continue
        elif tag == 9:  # FDT_END
            break
        else:
            break
    return _max_zvl_vlenb_from_tokens(tokens)


def resolve_isa_vlenb(
    repo: Path, board: str = "x3", dtb: Path | None = None
) -> int | None:
    """Derive expected ``vlenb`` from the supplied DTB or the board's RTL build."""
    if dtb is not None:
        from_dtb = dtb_isa_vlenb(dtb)
        if from_dtb is not None:
            return from_dtb
    for path, pattern in (
        (repo / f"boards/{board}/{board}_frost.sv", r"\.VLEN\(\s*(\d+)\s*\)"),
        (repo / "hw/rtl/frost.sv", r"\bVLEN\s*=\s*(\d+)"),
    ):
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        match = re.search(pattern, text)
        if match is not None:
            bits = int(match.group(1))
            if bits % 8 == 0 and _is_supported_vlenb(bits // 8):
                return bits // 8
    return None


def isa_probe_command(
    run_id: str,
    expect: str = LINUX_ISA_EXPECT_DEFAULT,
    vlenb: int | None = None,
) -> str:
    """Return one shell command that runs frost_isa_probe and prints its exit line."""
    limit = LINUX_ISA_PROBE_TIMEOUT_S[expect]
    vlenb_arg = f"--vlenb {vlenb} " if vlenb is not None else ""
    return (
        f"timeout -k 5 {limit} {LINUX_ROOT_BIN}/{LINUX_ISA_PROBE_PROGRAM} "
        f"suite {vlenb_arg}--run-id {run_id}; "
        f"printf '{LINUX_ISA_PROBE_EXIT_TOKEN} id=%s rc=%s\\n' {run_id} \"$?\""
    )


def _isa_case_problems(
    case: str, fields: Mapping[str, str], expect: str, vlenb: int | None
) -> list[str]:
    """Validate required positive coverage fields for one passing case record."""

    def want_int(key: str) -> int | None:
        raw = fields.get(key)
        return int(raw) if raw is not None and raw.isdigit() else None

    problems: list[str] = []
    if expect == "absent":
        if case == "discover" and fields.get("mode") != "absent":
            problems.append(f"discover mode={fields.get('mode')!r}")
        elif case == "illegal":
            for key in ("sigill", "pc_match", "scalar_pre"):
                if (want_int(key) or 0) < 1:
                    problems.append(f"illegal {key}={fields.get(key)!r}")
        elif case == "signal":
            if (want_int("rounds") or 0) < 1:
                problems.append(f"signal rounds={fields.get('rounds')!r}")
            if want_int("end_magic") != 0 or want_int("end_size") != 0:
                problems.append(
                    f"signal end=({fields.get('end_magic')},{fields.get('end_size')})"
                )
        elif case == "ptrace":
            for key in ("gpr_ok", "einval"):
                if (want_int(key) or 0) < 1:
                    problems.append(f"ptrace {key}={fields.get(key)!r}")
        return problems

    regset_bytes = (40 + 32 * vlenb) if vlenb is not None else None
    if case == "discover":
        if fields.get("mode") != "present":
            problems.append(f"discover mode={fields.get('mode')!r}")
        got_vlenb = want_int("vlenb")
        if vlenb is not None:
            if got_vlenb != vlenb:
                problems.append(f"discover vlenb={fields.get('vlenb')!r}")
        elif got_vlenb is None or not _is_supported_vlenb(got_vlenb):
            problems.append(f"discover vlenb={fields.get('vlenb')!r}")
        if (want_int("smoke") or 0) < 1:
            problems.append(f"discover smoke={fields.get('smoke')!r}")
    elif case == "first-use":
        if want_int("traps_before") != 0:
            problems.append(f"first-use traps_before={fields.get('traps_before')!r}")
        if want_int("traps_phase1") != 1 or want_int("traps_phase2") != 1:
            problems.append(
                f"first-use traps=({fields.get('traps_phase1')},{fields.get('traps_phase2')})"
            )
        if want_int("missed") != 0 or (want_int("init_zero") or 0) < 1:
            problems.append(
                f"first-use missed={fields.get('missed')} init_zero={fields.get('init_zero')}"
            )
    elif case == "switch":
        if (want_int("rounds_a") or 0) < 64 or (want_int("rounds_b") or 0) < 64:
            problems.append(
                f"switch rounds=({fields.get('rounds_a')},{fields.get('rounds_b')})"
            )
    elif case == "signal":
        if (
            (want_int("normal_rounds") or 0) < 8
            or (want_int("alt_rounds") or 0) < 8
            or (want_int("clobbers") or 0) < 16
        ):
            problems.append(
                f"signal rounds=({fields.get('normal_rounds')},{fields.get('alt_rounds')}) "
                f"clobbers={fields.get('clobbers')}"
            )
    elif case == "ptrace":
        if (
            (want_int("inactive_einval") or 0) < 1
            or regset_bytes is None
            or want_int("active_bytes") != regset_bytes
            or (want_int("setregset_ok") or 0) < 1
            or (want_int("resumed_ok") or 0) < 1
        ):
            problems.append(
                f"ptrace inactive={fields.get('inactive_einval')} "
                f"bytes={fields.get('active_bytes')} "
                f"setregset={fields.get('setregset_ok')} "
                f"resumed={fields.get('resumed_ok')}"
            )
    elif case == "core":
        if (
            (want_int("scalar_ok") or 0) < 1
            or regset_bytes is None
            or want_int("note_bytes") != regset_bytes
            or (want_int("restored") or 0) < 1
        ):
            problems.append(
                f"core scalar={fields.get('scalar_ok')} "
                f"bytes={fields.get('note_bytes')} restored={fields.get('restored')}"
            )
    elif case == "fork":
        for key in ("ctrl_ok", "inactive_einval", "init_zero", "isolated"):
            if (want_int(key) or 0) < 1:
                problems.append(f"fork {key}={fields.get(key)!r}")
    elif case == "exec":
        for key in ("on_ok", "off_sigill"):
            if (want_int(key) or 0) < 1:
                problems.append(f"exec {key}={fields.get(key)!r}")
    return problems


def isa_probe_verdict(
    serial_buf: str,
    run_id: str,
    expect: str = LINUX_ISA_EXPECT_DEFAULT,
    vlenb: int | None = None,
) -> tuple[bool, bool, str]:
    """Return ``(terminal_failure, passed, note)`` for ``frost_isa_probe`` output.

    Match only complete anchored lines after login carrying ``run_id``.
    """
    prompt_at = serial_buf.find(LINUX_LOGIN_PROMPT)
    if prompt_at < 0:
        return False, False, f"{LINUX_ISA_PROBE_PROGRAM}: no login prompt"
    region = serial_buf[prompt_at:]

    cases: dict[str, tuple[str, dict[str, str]]] = {}
    duplicates: list[str] = []
    failed_cases: list[str] = []
    for match in LINUX_ISA_CASE_RE.finditer(region):
        rid, case, verdict, raw_fields = match.groups()
        if rid != run_id:
            continue
        fields = dict(field.split("=", 1) for field in raw_fields.split())
        if verdict == "FAIL":
            reason = fields.get("reason", "unknown")
            failed_cases.append(f"{case}: FAIL ({reason})")
            continue
        if case in cases:
            duplicates.append(case)
        cases[case] = (verdict, fields)
    if failed_cases:
        return True, False, f"{LINUX_ISA_PROBE_PROGRAM} " + "; ".join(failed_cases)

    summaries = [
        match.groups()
        for match in LINUX_ISA_SUMMARY_RE.finditer(region)
        if match.group(1) == run_id
    ]
    exits = [
        int(match.group(2))
        for match in LINUX_ISA_EXIT_RE.finditer(region)
        if match.group(1) == run_id
    ]

    if summaries:
        _, obs_mode, passed_s, failed_s, sum_verdict = summaries[-1]
        if sum_verdict != "PASS" or int(failed_s) != 0:
            return (
                True,
                False,
                f"{LINUX_ISA_PROBE_PROGRAM}: summary verdict={sum_verdict} "
                f"mode={obs_mode} passed={passed_s} failed={failed_s}",
            )
        if obs_mode != expect:
            return (
                True,
                False,
                f"{LINUX_ISA_PROBE_PROGRAM}: observed mode {obs_mode!r}, "
                f"expected {expect!r}",
            )

    if exits:
        rc = exits[-1]
        if rc != 0:
            return (
                True,
                False,
                f"{LINUX_ISA_PROBE_PROGRAM}: exited {rc} (id={run_id})",
            )

    if not exits:
        return (
            False,
            False,
            f"{LINUX_ISA_PROBE_PROGRAM}: no {LINUX_ISA_PROBE_EXIT_TOKEN} line",
        )
    if not summaries:
        return (
            True,
            False,
            f"{LINUX_ISA_PROBE_PROGRAM}: exited 0 without {LINUX_ISA_PROBE_SUMMARY_TOKEN}",
        )
    if duplicates:
        return (
            True,
            False,
            f"{LINUX_ISA_PROBE_PROGRAM}: duplicate case record(s): {', '.join(duplicates)}",
        )

    expected_cases = LINUX_ISA_PROBE_CASES[expect]
    _, obs_mode, passed_s, _, _ = summaries[-1]
    if int(passed_s) != len(expected_cases):
        return (
            True,
            False,
            f"{LINUX_ISA_PROBE_PROGRAM}: summary passed={passed_s}, expected {len(expected_cases)}",
        )
    missing = [c for c in expected_cases if c not in cases]
    extra = [c for c in cases if c not in expected_cases]
    if missing or extra:
        parts = []
        if missing:
            parts.append(f"missing {', '.join(missing)}")
        if extra:
            parts.append(f"unexpected {', '.join(extra)}")
        return True, False, f"{LINUX_ISA_PROBE_PROGRAM}: " + "; ".join(parts)

    effective_vlenb = vlenb
    if expect == "present" and effective_vlenb is None:
        raw_vlenb = cases["discover"][1].get("vlenb", "")
        if raw_vlenb.isdigit() and _is_supported_vlenb(int(raw_vlenb)):
            effective_vlenb = int(raw_vlenb)

    bad: list[str] = []
    for case in expected_cases:
        _, fields = cases[case]
        bad.extend(_isa_case_problems(case, fields, expect, effective_vlenb))
    if bad:
        return True, False, f"{LINUX_ISA_PROBE_PROGRAM}: " + "; ".join(bad)

    return (
        False,
        True,
        f"isa probe {obs_mode} ({len(expected_cases)}/{len(expected_cases)} cases)",
    )


LINUX_SUPM_PROBE_PROGRAM = "frost_supm_probe"
LINUX_SUPM_PROBE_TOKEN = "FROST_SUPM_PROBE"
LINUX_SUPM_PROBE_SUMMARY_TOKEN = "FROST_SUPM_PROBE_SUMMARY"
LINUX_SUPM_PROBE_EXIT_TOKEN = "FROST_SUPM_PROBE_EXIT"
LINUX_SUPM_PROBE_TIMEOUT_S = 30
LINUX_SUPM_PROBE_CASES: tuple[str, ...] = (
    "discover",
    "pmlen7",
    "pmlen16",
    "disable-fault",
)
LINUX_SUPM_CASE_RE = re.compile(
    r"^\r*"
    + LINUX_SUPM_PROBE_TOKEN
    + r" id=([0-9a-fA-F]+) case=([a-z0-9-]+) verdict=(PASS|FAIL)((?: [a-z0-9_]+=\S+)*)[ \t\r]*\n",
    re.MULTILINE,
)
LINUX_SUPM_SUMMARY_RE = re.compile(
    r"^\r*"
    + LINUX_SUPM_PROBE_SUMMARY_TOKEN
    + r" id=([0-9a-fA-F]+) passed=(\d+) failed=(\d+) verdict=(PASS|FAIL)[ \t\r]*\n",
    re.MULTILINE,
)
LINUX_SUPM_EXIT_RE = re.compile(
    r"^\r*" + LINUX_SUPM_PROBE_EXIT_TOKEN + r" id=([0-9a-fA-F]+) rc=(\d+)[ \t\r]*\n",
    re.MULTILINE,
)


def supm_probe_command(run_id: str) -> str:
    """Return one shell command that runs frost_supm_probe and prints its exit line."""
    return (
        f"timeout -k 5 {LINUX_SUPM_PROBE_TIMEOUT_S} "
        f"{LINUX_ROOT_BIN}/{LINUX_SUPM_PROBE_PROGRAM} --run-id {run_id}; "
        f"printf '{LINUX_SUPM_PROBE_EXIT_TOKEN} id=%s rc=%s\\n' {run_id} \"$?\""
    )


def _supm_case_problems(case: str, fields: Mapping[str, str]) -> list[str]:
    """Validate required positive coverage fields for one passing Supm case."""

    def want_int(key: str) -> int | None:
        raw = fields.get(key)
        return int(raw) if raw is not None and raw.isdigit() else None

    problems: list[str] = []
    if case == "discover":
        if (
            want_int("hwprobe") != 1
            or want_int("cpuinfo") != 1
            or want_int("init_ctrl") != 0
        ):
            problems.append(
                f"discover hwprobe={fields.get('hwprobe')} "
                f"cpuinfo={fields.get('cpuinfo')} init_ctrl={fields.get('init_ctrl')}"
            )
    elif case == "pmlen7":
        if (
            (want_int("pmlen") or 0) < 7
            or (want_int("loads") or 0) < 1
            or (want_int("stores") or 0) < 1
        ):
            problems.append(
                f"pmlen7 pmlen={fields.get('pmlen')} "
                f"loads={fields.get('loads')} stores={fields.get('stores')}"
            )
    elif case == "pmlen16":
        if (
            want_int("pmlen") != 16
            or want_int("req8_pmlen") != 16
            or (want_int("loads") or 0) < 1
            or (want_int("stores") or 0) < 1
            or want_int("syscall") != 1
            or want_int("reject_pmlen32") != 1
        ):
            problems.append(
                f"pmlen16 pmlen={fields.get('pmlen')} "
                f"req8_pmlen={fields.get('req8_pmlen')} "
                f"loads={fields.get('loads')} stores={fields.get('stores')} "
                f"syscall={fields.get('syscall')} "
                f"reject_pmlen32={fields.get('reject_pmlen32')}"
            )
    elif case == "disable-fault":
        for key in (
            "ctrl_off",
            "untagged_ok",
            "load_sigsegv",
            "store_sigsegv",
            "store_unmodified",
        ):
            if want_int(key) != 1:
                problems.append(f"disable-fault {key}={fields.get(key)!r}")
    return problems


def supm_probe_verdict(serial_buf: str, run_id: str) -> tuple[bool, bool, str]:
    """Return ``(terminal_failure, passed, note)`` for ``frost_supm_probe`` output.

    Match only complete anchored lines after login carrying ``run_id``.
    """
    prompt_at = serial_buf.find(LINUX_LOGIN_PROMPT)
    if prompt_at < 0:
        return False, False, f"{LINUX_SUPM_PROBE_PROGRAM}: no login prompt"
    region = serial_buf[prompt_at:]

    cases: dict[str, tuple[str, dict[str, str]]] = {}
    duplicates: list[str] = []
    failed_cases: list[str] = []
    for match in LINUX_SUPM_CASE_RE.finditer(region):
        rid, case, verdict, raw_fields = match.groups()
        if rid != run_id:
            continue
        fields = dict(field.split("=", 1) for field in raw_fields.split())
        if verdict == "FAIL":
            reason = fields.get("reason", "unknown")
            failed_cases.append(f"{case}: FAIL ({reason})")
            continue
        if case in cases:
            duplicates.append(case)
        cases[case] = (verdict, fields)
    if failed_cases:
        return True, False, f"{LINUX_SUPM_PROBE_PROGRAM} " + "; ".join(failed_cases)

    summaries = [
        match.groups()
        for match in LINUX_SUPM_SUMMARY_RE.finditer(region)
        if match.group(1) == run_id
    ]
    exits = [
        int(match.group(2))
        for match in LINUX_SUPM_EXIT_RE.finditer(region)
        if match.group(1) == run_id
    ]

    if summaries:
        _, passed_s, failed_s, sum_verdict = summaries[-1]
        if sum_verdict != "PASS" or int(failed_s) != 0:
            return (
                True,
                False,
                f"{LINUX_SUPM_PROBE_PROGRAM}: summary verdict={sum_verdict} "
                f"passed={passed_s} failed={failed_s}",
            )

    if exits:
        rc = exits[-1]
        if rc != 0:
            return (
                True,
                False,
                f"{LINUX_SUPM_PROBE_PROGRAM}: exited {rc} (id={run_id})",
            )

    if not exits:
        return (
            False,
            False,
            f"{LINUX_SUPM_PROBE_PROGRAM}: no {LINUX_SUPM_PROBE_EXIT_TOKEN} line",
        )
    if not summaries:
        return (
            True,
            False,
            f"{LINUX_SUPM_PROBE_PROGRAM}: exited 0 without {LINUX_SUPM_PROBE_SUMMARY_TOKEN}",
        )
    if duplicates:
        return (
            True,
            False,
            f"{LINUX_SUPM_PROBE_PROGRAM}: duplicate case record(s): {', '.join(duplicates)}",
        )

    _, passed_s, _, _ = summaries[-1]
    if int(passed_s) != len(LINUX_SUPM_PROBE_CASES):
        return (
            True,
            False,
            f"{LINUX_SUPM_PROBE_PROGRAM}: summary passed={passed_s}, "
            f"expected {len(LINUX_SUPM_PROBE_CASES)}",
        )
    missing = [c for c in LINUX_SUPM_PROBE_CASES if c not in cases]
    extra = [c for c in cases if c not in LINUX_SUPM_PROBE_CASES]
    if missing or extra:
        parts = []
        if missing:
            parts.append(f"missing {', '.join(missing)}")
        if extra:
            parts.append(f"unexpected {', '.join(extra)}")
        return True, False, f"{LINUX_SUPM_PROBE_PROGRAM}: " + "; ".join(parts)

    bad: list[str] = []
    for case in LINUX_SUPM_PROBE_CASES:
        _, fields = cases[case]
        bad.extend(_supm_case_problems(case, fields))
    if bad:
        return True, False, f"{LINUX_SUPM_PROBE_PROGRAM}: " + "; ".join(bad)

    count = len(LINUX_SUPM_PROBE_CASES)
    return False, True, f"supm probe ({count}/{count} cases)"


def linux_stage(
    root: LinuxRoot,
    net_repeat: int = 1,
    net_poke_s: int = 0,
    driver_version: str | None = None,
    *,
    board: str = "x3",
    isa_expect: str = LINUX_ISA_EXPECT_DEFAULT,
    isa_run_id: str | None = None,
    isa_vlenb: int | None = None,
) -> UartStage:
    """Build UART checks for Debian booting from the NFS root.

    Require the pinned kernel and driver before login. After login, check the
    NFSv3 mount, the loaded ``frost_net10g`` module version from
    ``/sys/module/frost_net10g/version``, systemd startup (allowing only
    session scope resource failures), stress result, nonzero counters, the
    selected board's memory error readback, scrub self-test, RAM patrol,
    ISA probe verdicts, and loopback with root access restored. Explicit
    failures end capture immediately.

    ``net_repeat`` above 1 runs the network test that many times (see
    ``nettest_command``); a failed earlier repetition fails the stage too.
    ``net_poke_s`` above 0 schedules an NFS request inside each run's link
    hold-down (see ``nettest_poke_command``).
    """
    expected_driver = (
        source_driver_version(REPO_DEFAULT)
        if driver_version is None
        else driver_version
    )
    if isa_expect not in LINUX_ISA_EXPECT_CHOICES:
        raise ValueError(
            f"isa_expect must be one of {LINUX_ISA_EXPECT_CHOICES}, got {isa_expect!r}"
        )
    run_id = secrets.token_hex(4) if isa_run_id is None else isa_run_id
    failure_markers = LINUX_FAILURE_MARKERS + (
        LINUX_TOKEN_FAIL,
        LINUX_NET_TOKEN_FAIL,
    )
    # Debian's initramfs does not run this tree's init scripts. Require the
    # driver's own probe message before login.
    boot_lines = ((LINUX_DRIVER_LINE, re.compile(re.escape(LINUX_DRIVER_LINE))),)
    has_ecc_reader = board in CPU_ECC_READER_BOARDS

    def lx_login(serial_buf: str) -> bool:
        """Return True once the kernel and login markers have been captured."""
        return all(marker in serial_buf for marker in LINUX_SUCCESS_MARKERS)

    def lx_reasons(serial_buf: str) -> list[str]:
        """Return every terminal failure the output shows, most specific first."""
        hit = [m for m in failure_markers if m in serial_buf]
        counter_fail = LINUX_COUNTER_FAIL_RE.search(serial_buf)
        if counter_fail:
            hit.append(counter_fail.group(0).strip())
        # Anchor these too: the load-failure token is in the typed command.
        for token in ("FROST_MEMERR_SELFTEST_FAIL", "FROST_MEMERR_LOAD_FAIL"):
            if re.search(r"^\r*" + token + r"[ \t\r]*\n", serial_buf, re.MULTILINE):
                hit.append(token)
        prompt_at = serial_buf.find(LINUX_LOGIN_PROMPT)
        if prompt_at >= 0 and LINUX_DRIVER_VERSION_RE.search(serial_buf[prompt_at:]):
            driver_ok, driver_note = driver_version_verdict(serial_buf, expected_driver)
            if not driver_ok:
                hit.append(driver_note)
        state = systemd_state(serial_buf)
        if state is not None and state != LINUX_SYSTEMD_RUNNING:
            hit.append(f"systemd is {state}, not {LINUX_SYSTEMD_RUNNING}")
        alive = root_alive_status(serial_buf)
        if alive is not None and alive != 0:
            hit.append(
                f"the root did not come back after {LINUX_NET_COMMAND}: "
                f"sync exited {alive}"
            )
        isa_fail, _, isa_note = isa_probe_verdict(
            serial_buf, run_id, isa_expect, isa_vlenb
        )
        if isa_fail:
            hit.append(isa_note)
        supm_fail, _, supm_note = supm_probe_verdict(serial_buf, run_id)
        if supm_fail:
            hit.append(supm_note)
        return hit

    def lx_success(raw_buf: str) -> bool:
        """Login, driver version, systemd, counters, ISA and Supm probes, loopback, and root access."""
        serial_buf = console_text(raw_buf)
        if not lx_login(serial_buf):
            return False
        if not driver_version_verdict(serial_buf, expected_driver)[0]:
            return False
        if systemd_state(serial_buf) != LINUX_SYSTEMD_RUNNING:
            return False
        if not set(counter_values(serial_buf)) >= set(LINUX_COUNTER_EVENTS):
            return False
        if not isa_probe_verdict(serial_buf, run_id, isa_expect, isa_vlenb)[1]:
            return False
        if not supm_probe_verdict(serial_buf, run_id)[1]:
            return False
        if LINUX_NET_TOKEN not in serial_buf:
            return False
        # The capture ends after the link is back, not at the pass token: the
        # test leaves the root's interface down, and the line that follows it
        # brings the link back and flushes. Only a status after the token
        # counts: an earlier repetition's does not cover the last one.
        after = serial_buf[serial_buf.rindex(LINUX_NET_TOKEN) :]
        return root_alive_status(after) == 0

    def lx_failure(raw_buf: str) -> bool:
        """Return True once ``lx_reasons`` finds any terminal failure."""
        return bool(lx_reasons(console_text(raw_buf)))

    def lx_failure_post_wait(raw_buf: str) -> float:
        """Keep reading after an ISA probe case FAIL line before ending the stage."""
        serial_buf = console_text(raw_buf)
        prompt_at = serial_buf.find(LINUX_LOGIN_PROMPT)
        if prompt_at < 0:
            return 0.0
        region = serial_buf[prompt_at:]
        for match in LINUX_ISA_CASE_RE.finditer(region):
            rid, _, verdict, _ = match.groups()
            if rid == run_id and verdict == "FAIL":
                return LINUX_ISA_FAILURE_WAIT_S
        return 0.0

    def lx_judge(raw_buf: str) -> tuple[bool, str]:
        """Fail on a failure marker, else require every marker, line and count."""
        serial_buf = console_text(raw_buf)
        hit = lx_reasons(serial_buf)
        if hit:
            note = f"failure marker: {', '.join(hit)}"
            if net_repeat > 1:
                verdicts = nettest_diag_verdicts(serial_buf)
                done = ", ".join(
                    f"{rep} {verdicts[rep][0]}" for rep in sorted(verdicts)
                )
                note += f"; {LINUX_NET_COMMAND} repetitions before the last: "
                note += done or "none finished"
            return False, note
        missing = [m for m in LINUX_SUCCESS_MARKERS if m not in serial_buf]
        if missing:
            return False, f"missing: {', '.join(repr(m) for m in missing)}"
        prompt_at = serial_buf.find(LINUX_LOGIN_PROMPT)
        for line, pattern in boot_lines:
            if not pattern.search(serial_buf[:prompt_at]):
                return False, f"{line!r} not printed before the login prompt"
        mounted, mount_note = root_mount_verdict(serial_buf, root.nfsroot)
        if not mounted:
            return False, mount_note
        driver_ok, driver_note = driver_version_verdict(serial_buf, expected_driver)
        if not driver_ok:
            return False, driver_note
        if systemd_state(serial_buf) != LINUX_SYSTEMD_RUNNING:
            return False, (
                f"systemctl is-system-running: no {LINUX_SYSTEMD_RUNNING!r} line"
            )
        # After the prompt: the initramfs cannot have printed it, so the token
        # is evidence of the payload the stage typed on the real root.
        if LINUX_TOKEN not in serial_buf[prompt_at:]:
            return False, f"{LINUX_STRESS_COMMAND}: no {LINUX_TOKEN!r} after the login"
        counts = counter_values(serial_buf)
        bad = []
        for event in LINUX_COUNTER_EVENTS:
            count = counts.get(event)
            if count is None:
                bad.append(f"{event}: no {LINUX_COUNTER_LINE} count")
            elif not count.isdigit() or int(count) == 0:
                bad.append(f"{event}: {count}")
        if bad:
            return False, f"{LINUX_COUNTER_COMMAND}: " + "; ".join(bad)
        memerr = memerr_values(serial_buf)
        if memerr is None:
            return False, (
                f"no {LINUX_MEMERR_TOKEN} line with counts: {MEMERR.name} did not "
                "load or bind"
            )
        memerr_bad = memerr_problems(memerr, has_ecc_reader=has_ecc_reader)
        if memerr_bad:
            return False, f"{LINUX_MEMERR_TOKEN}: " + "; ".join(memerr_bad)
        _, isa_ok, isa_note = isa_probe_verdict(
            serial_buf, run_id, isa_expect, isa_vlenb
        )
        if not isa_ok:
            return False, isa_note
        _, supm_ok, supm_note = supm_probe_verdict(serial_buf, run_id)
        if not supm_ok:
            return False, supm_note
        if LINUX_NET_TOKEN not in serial_buf:
            return False, f"{LINUX_NET_COMMAND}: no {LINUX_NET_TOKEN!r}"
        if root_alive_status(serial_buf) is None:
            return False, (
                f"{LINUX_NET_COMMAND}: no {LINUX_ROOT_ALIVE_TOKEN}= status, so "
                "nothing says the root came back with its link"
            )
        net_note = LINUX_NET_COMMAND
        if net_repeat > 1:
            problems = nettest_diag_problems(serial_buf, net_repeat)
            if problems:
                return False, (
                    f"{LINUX_NET_COMMAND} passed its last repetition of "
                    f"{net_repeat}, but " + "; ".join(problems)
                )
            net_note = f"{LINUX_NET_COMMAND} {net_repeat} times"
        net_end = serial_buf.rindex(LINUX_NET_TOKEN)
        interfaces = LINUX_NET_INTERFACE_RE.findall(serial_buf, prompt_at, net_end)
        if interfaces != [root.interface] * net_repeat:
            reported = ", ".join(interfaces) or "none"
            return False, (
                f"{LINUX_NET_COMMAND}: expected {net_repeat} run(s) on "
                f"{root.interface}, found {reported}"
            )
        summary = " ".join(f"{event}={counts[event]}" for event in LINUX_COUNTER_EVENTS)
        memory_note = "no DDR AXI error responses"
        if has_ecc_reader:
            polls = memerr["polls_after"] - memerr["polls_before"]
            memory_note = f"no memory errors ({polls} ECC polls)"
        patrol = memerr["patrol_after"] - memerr["patrol_before"]
        tolerated = tolerated_systemd_units(serial_buf)
        systemd_note = LINUX_SYSTEMD_RUNNING
        if tolerated:
            systemd_note += f" (tolerated {', '.join(tolerated)}: resources)"
        return True, (
            f"{KERNEL_RELEASE}, {driver_note}, {mount_note}, systemd "
            f"{systemd_note}, login, stress token, counters "
            f"{summary}, {memory_note}, scrub self-test, "
            f"RAM patrol ({patrol} lines, a full pass), {isa_note}, "
            f"{supm_note}, {net_note}, root alive"
        )

    return UartStage(
        LINUX_STAGE,
        success_done=lx_success,
        failure_done=lx_failure,
        judge=lx_judge,
        stimuli=(
            (LINUX_LOGIN_PROMPT, "root\r"),
            (LINUX_SHELL_PROMPT, LINUX_ROOT_MOUNT_COMMAND + "\r"),
            (LINUX_SHELL_PROMPT, LINUX_DRIVER_VERSION_COMMAND + "\r"),
            (LINUX_SHELL_PROMPT, LINUX_SYSTEMD_COMMAND + "\r"),
            (LINUX_SHELL_PROMPT, LINUX_STRESS_COMMAND + "\r"),
            (LINUX_SHELL_PROMPT, LINUX_COUNTER_COMMAND + "\r"),
            (LINUX_SHELL_PROMPT, LINUX_MEMERR_COMMAND + "\r"),
            (
                LINUX_SHELL_PROMPT,
                isa_probe_command(run_id, isa_expect, isa_vlenb) + "\r",
            ),
            (
                LINUX_SHELL_PROMPT,
                supm_probe_command(run_id) + "\r",
            ),
            (
                LINUX_SHELL_PROMPT,
                nettest_command(root.interface, net_repeat, net_poke_s) + "\r",
            ),
        ),
        failure_line_grace_s=LINUX_FAILURE_LINE_GRACE_S,
        failure_post_wait_s=lx_failure_post_wait,
    )


def send_uart_probe(serial_fd: int, text: str) -> None:
    """Pace bytes so ``uart_echo`` never overfills its RX FIFO."""
    for byte in text.encode():
        os.write(serial_fd, bytes([byte]))
        time.sleep(0.002)


def run_ecc_stage(
    repo: Path, board: str, target: str, timeout_s: float
) -> dict[str, Any]:
    """Read DDR ECC state over JTAG after application traffic.

    Use ddr_ecc_status.py's exit code to decide whether the report is clean.
    """
    started = time.monotonic()
    # ``target`` is a pattern here, the same one the loader stages take, so it
    # is passed as one: an index or a serial substring has to keep working.
    command = [ECC_STAGE_SCRIPT, board, "--target", target, "--non-interactive"]
    try:
        proc = subprocess.run(
            command,
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=timeout_s,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return {
            "stage": ECC_STAGE,
            "status": "TIMEOUT",
            "elapsed": time.monotonic() - started,
            "note": f"{ECC_STAGE_SCRIPT} did not finish in {timeout_s:.0f}s",
        }
    output = (proc.stdout or "") + (proc.stderr or "")
    print(output, end="", flush=True)
    if proc.returncode == 0:
        note = ""
    else:
        prefix = (
            "Not clean:" if proc.returncode == ECC_DIRTY_EXIT else "ECC read failed:"
        )
        note = (
            "; ".join(
                line.strip()
                for line in output.splitlines()
                if line.strip().startswith(prefix)
            )
            or f"{ECC_STAGE_SCRIPT} exited {proc.returncode}"
        )
    return {
        "stage": ECC_STAGE,
        "status": "PASS" if proc.returncode == 0 else "FAIL",
        "elapsed": time.monotonic() - started,
        "note": note,
    }


DEBUG_PREFIX = "FROST_DEBUG"
DEBUG_END = "FROST_DEBUG_DONE"
_HEX8 = r"0x[0-9a-f]{8}"
# The transcript of hw_debug_check.tcl's frost_debug_check, line by line: the
# key and the exact form of its value. Nothing else is accepted.
DEBUG_SEQUENCE: tuple[tuple[str, str], ...] = (
    ("dtmcs", _HEX8),
    ("dmstatus", _HEX8),
    ("hartinfo", _HEX8),
    ("state_before", r"[a-z]+"),
    ("state_halted", r"[a-z]+"),
    ("dmstatus_halted", _HEX8),
    ("dpc", r"0x[0-9a-f]{1,16}"),
    ("state_after_resume", r"[a-z]+"),
    ("dmstatus_running", _HEX8),
    ("dtmcs_after", _HEX8),
    ("hartinfo_after", _HEX8),
    ("state_left", r"[a-z]+"),
)
# The confirmation procedure's transcript: only running is accepted.
RECOVERY_SEQUENCE = (("state_left", "running"),)
RECOVERY_COMMAND = "./fpga/debug/cache_counters.py resume"


def _find_error_marker(text: str) -> str | None:
    """Return the last OpenOCD or script error marker in text, or None."""
    found: str | None = None
    for line in text.split("\n"):
        stripped = line.rstrip("\r")
        if stripped.startswith("Error:"):
            detail = stripped[len("Error:") :].strip()
            found = detail or "Error:"
        elif stripped.startswith("FROST_DEBUG_ERR:"):
            detail = stripped[len("FROST_DEBUG_ERR:") :].strip()
            found = detail or "FROST_DEBUG_ERR:"
    return found


def _quote(line: str) -> str:
    """Return a line shortened and quoted for a message (masked by the caller)."""
    return repr(line[:80])


def parse_transcript(
    output: str, sequence: Sequence[tuple[str, str]] = DEBUG_SEQUENCE
) -> tuple[dict[str, str] | None, str]:
    """Match output against a transcript sequence exactly.

    Return the values by key and an empty string when the whole output is that
    sequence followed by the end marker, each line ending in a newline and
    nothing before, between or after. Otherwise return None and a message
    quoting the first offending line.
    """
    lines = output.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    elif lines:
        return None, f"the output does not end with a newline after {_quote(lines[-1])}"
    patterns = [
        re.compile(rf"{DEBUG_PREFIX} {key}=({pattern})") for key, pattern in sequence
    ]
    values: dict[str, str] = {}
    for index, pattern in enumerate(patterns):
        if index >= len(lines):
            return None, f"the output ends before the {sequence[index][0]} line"
        match = pattern.fullmatch(lines[index])
        if match is None:
            return None, f"unexpected line {_quote(lines[index])}"
        values[sequence[index][0]] = match.group(1)
    if len(lines) == len(patterns):
        return None, f"the output ends before {DEBUG_END}"
    if lines[len(patterns)] != DEBUG_END:
        return None, f"unexpected line {_quote(lines[len(patterns)])}"
    if len(lines) > len(patterns) + 1:
        return None, f"text after {DEBUG_END}: {_quote(lines[len(patterns) + 1])}"
    return values, ""


def debug_values(output: str) -> dict[str, str]:
    """Return the key/value pairs of every well-formed ``FROST_DEBUG`` line."""
    found = {}
    for line in output.split("\n"):
        match = re.fullmatch(rf"{DEBUG_PREFIX} (\w+)=([0-9a-z]+)", line)
        if match:
            found[match.group(1)] = match.group(2)
    return found


def _is_state(dmstatus: int, halted: bool) -> bool:
    """Return whether dmstatus says halted (or running) and nothing else odd.

    This target has one hart, so anyhalted/allhalted (bits 8, 9) and
    anyrunning/allrunning (bits 10, 11) must agree and exclude each other, no
    hart is unavailable or nonexistent (bits 12 to 15), the version is 2, the
    debugger is authenticated, and the reserved bits are zero.
    """
    halted_bits, running_bits = (dmstatus >> 8) & 0x3, (dmstatus >> 10) & 0x3
    if (halted_bits, running_bits) != ((3, 0) if halted else (0, 3)):
        return False
    if (dmstatus >> 12) & 0xF:
        return False
    if dmstatus & 0xF != 2 or not (dmstatus >> 7) & 1:
        return False
    return not (dmstatus & DMSTATUS_RESERVED)


# dmstatus bits 21:20 and 31:25 are reserved (debug spec 1.0, section 3.12.2).
DMSTATUS_RESERVED = 0x00300000 | 0xFE000000
# dmstatus bits that describe the debug module, not the hart's moment: impebreak
# and the low byte.
DMSTATUS_STATIC = 0x004000FF
# dtmcs bits 31:15 read as zero here (dmireset and dmihardreset are write-only).
DTMCS_RESERVED = 0xFFFF8000


def judge_debug_output(output: str) -> tuple[bool, str]:
    """Judge the output of ``frost_debug_check``.

    Return whether the debug transport passed and a one-line note. The first
    transcript never decides whether the hart was left running; a separate
    confirmation process always checks that.
    """
    ok, note = _judge(output)
    return ok, mask_serial(note)


def _judge(output: str) -> tuple[bool, str]:
    values, problem = parse_transcript(output)
    if values is None:
        errors = [
            line[len("FROST_DEBUG_ERR: ") :]
            for line in output.split("\n")
            if line.startswith("FROST_DEBUG_ERR: ")
        ]
        detail = f"; the script reported: {_quote(errors[-1])}" if errors else ""
        if not output.strip():
            return False, "no output from OpenOCD"
        return False, f"{problem}{detail}"

    def number(key: str) -> int:
        return int(values[key], 16)

    dtmcs = number("dtmcs")
    got = (dtmcs & 0xF, (dtmcs >> 4) & 0x3F, (dtmcs >> 10) & 0x3)
    if got != DTMCS_EXPECTED or dtmcs & DTMCS_RESERVED:
        return (
            False,
            f"unexpected dtmcs=0x{dtmcs:08x} (version {got[0]}, abits {got[1]}, "
            f"status {got[2]}; expected {DTMCS_EXPECTED}, reserved bits zero)",
        )
    if number("dtmcs_after") != dtmcs:
        return (
            False,
            f"dtmcs changed from 0x{dtmcs:08x} to 0x{number('dtmcs_after'):08x}",
        )
    hartinfo = number("hartinfo")
    if hartinfo != HARTINFO_EXPECTED:
        return (
            False,
            f"unexpected hartinfo=0x{hartinfo:08x}, expected 0x{HARTINFO_EXPECTED:08x}",
        )
    if number("hartinfo_after") != hartinfo:
        return False, "hartinfo changed during the run"
    before = values["state_before"]
    if before not in ("running", "halted"):
        return False, f"the hart was {before} before the check"
    dmstatus = number("dmstatus")
    if not _is_state(dmstatus, halted=before == "halted"):
        return False, f"dmstatus=0x{dmstatus:08x} does not report the hart {before}"
    if values["state_halted"] != "halted":
        return False, f"halt was refused or timed out (state {values['state_halted']})"
    halted_status = number("dmstatus_halted")
    if not _is_state(halted_status, halted=True):
        return (
            False,
            f"dmstatus=0x{halted_status:08x} does not report the hart halted",
        )
    if values["state_after_resume"] != "running":
        return False, "the hart did not resume"
    running_status = number("dmstatus_running")
    if not _is_state(running_status, halted=False):
        return (
            False,
            f"dmstatus=0x{running_status:08x} does not report the hart running",
        )
    if (
        len({d & DMSTATUS_STATIC for d in (dmstatus, halted_status, running_status)})
        != 1
    ):
        return False, "dmstatus changed in its static bits during the run"
    left = values["state_left"]
    if left != "running":
        return False, f"the hart was left {left}"
    dpc = number("dpc")
    return (
        True,
        f"dtmcs 0x{dtmcs:08x}, dpc 0x{dpc:x}, hart {before} then halted, "
        "resumed and running",
    )


def judge_debug_recovery(
    stdout: str, stderr: str, timed_out: bool, exit_code: int | None
) -> tuple[bool, str]:
    """Judge the separate confirmation run (``frost_debug_recover``).

    Confirmation counts only when the process finished within its time limit,
    exited 0, printed no error marker on stdout or stderr, and printed exactly
    the single running line followed by ``DEBUG_END``.
    """
    if timed_out:
        return (
            False,
            f"confirmation timed out after {DEBUG_RECOVERY_TIMEOUT_S:.0f}s",
        )
    if exit_code != 0:
        err = _find_error_marker(stderr) or _find_error_marker(stdout)
        detail = f": {mask_serial(err)}" if err is not None else ""
        return False, f"confirmation exited {exit_code}{detail}"
    err = _find_error_marker(stderr) or _find_error_marker(stdout)
    if err is not None:
        return False, f"confirmation reported an error: {mask_serial(err)}"
    values, problem = parse_transcript(stdout, RECOVERY_SEQUENCE)
    if values is None:
        return False, f"confirmation output invalid: {mask_serial(problem)}"
    return True, "hart confirmed running"


def hw_server_running() -> bool:
    """Return whether Vivado's hw_server (which owns the JTAG cable) is running."""
    try:
        done = subprocess.run(
            ["pgrep", "-x", "hw_server"], capture_output=True, check=False
        )
    except OSError:
        return False
    return done.returncode == 0


def wait_for_cable(
    timeout_s: float,
    running: Callable[[], bool] | None = None,
    sleep: Callable[[float], None] = time.sleep,
    poll_s: float = 3.0,
) -> bool:
    """Wait for hw_server to exit; it never is stopped here. Return whether it did."""
    running = running or hw_server_running
    waited = 0.0
    while running():
        if waited >= timeout_s:
            return False
        sleep(poll_s)
        waited += poll_s
    return True


def debug_openocd_command(
    openocd: str,
    repo: Path,
    config: Path,
    procedure: str,
    setup: Sequence[str] = (),
) -> list[str]:
    """Return the OpenOCD command line that runs one hw_debug_check.tcl procedure.

    ``setup`` commands run before the configuration (the simulation bench's
    server port, for one).
    """
    command = [openocd, "-s", str(repo)]
    for text in ("gdb_port disabled", "telnet_port disabled", "tcl_port disabled"):
        command += ["-c", text]
    for text in setup:
        command += ["-c", text]
    command += ["-f", str(repo / config), "-f", str(repo / DEBUG_SCRIPT)]
    command += ["-c", "init", "-c", procedure, "-c", "shutdown"]
    return command


def run_openocd_procedure(
    command: list[str], timeout_s: float, environment: Mapping[str, str]
) -> tuple[str, str, bool, int | None]:
    """Run OpenOCD and return its stdout, stderr, timeout flag and exit status.

    The flag says whether the timeout stopped it. The script's transcript is on
    stdout and OpenOCD's own log is on stderr; both are decoded with
    replacement, so no byte can raise. ``OSError`` from starting the program is
    the caller's to report.
    """
    try:
        done = subprocess.run(
            command,
            capture_output=True,
            timeout=timeout_s,
            check=False,
            env=dict(environment),
            stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired as expired:
        return (
            (expired.stdout or b"").decode("utf-8", errors="replace"),
            (expired.stderr or b"").decode("utf-8", errors="replace"),
            True,
            None,
        )
    return (
        (done.stdout or b"").decode("utf-8", errors="replace"),
        (done.stderr or b"").decode("utf-8", errors="replace"),
        False,
        done.returncode,
    )


class _StageTerminated(BaseException):
    """Raised inside ``run_debug_stage`` when SIGTERM arrives."""


def _install_sigterm_handler() -> tuple[bool, Any]:
    """Turn SIGTERM into ``_StageTerminated`` on the main thread."""

    def _handle(signum: int, frame: Any) -> None:
        raise _StageTerminated("terminated by SIGTERM")

    try:
        previous = signal.signal(signal.SIGTERM, _handle)
    except ValueError:
        return False, None
    return True, previous


def run_debug_stage(
    repo: Path,
    board: str,
    environment: Mapping[str, str] = os.environ,
    cable_wait_s: float = DEBUG_CABLE_WAIT_S,
) -> dict[str, Any]:
    """Check the debug transport through OpenOCD and confirm the core runs.

    Read dtmcs and DMI registers, halt, read dpc and resume. Skipped unless
    ``FROST_JTAG_SERIAL`` names the cable.

    Whenever OpenOCD was started, the stage always ends by running a separate
    ``frost_debug_recover`` process under the board lock to resume the hart if
    needed and confirm it is running. The first transcript never decides the
    hart's state. Anything short of a clean confirmation reports ``FAIL`` with
    the hart's state ``UNKNOWN`` and the manual recovery command. Interrupts
    (``SIGINT``/``KeyboardInterrupt``) and ``SIGTERM`` still run the
    confirmation under the lock and re-raise afterwards; if confirmation itself
    is interrupted, a single masked line reports the hart state as ``UNKNOWN``
    with the manual recovery command. Non-signal exceptions become ``FAIL``
    with a masked message.
    """
    started = time.monotonic()
    run_env = {
        **environment,
        JTAG_SERIAL_ENV: environment.get(JTAG_SERIAL_ENV, "").strip(),
    }

    def result(status: str, note: str) -> dict[str, Any]:
        return {
            "stage": DEBUG_STAGE,
            "status": status,
            "elapsed": time.monotonic() - started,
            "note": mask_serial(note, environment),
        }

    def show(text: str) -> None:
        print(mask_serial(text, run_env), end="", flush=True)

    installed_sigterm, previous_sigterm = _install_sigterm_handler()
    try:
        remember_serial(environment)
        return _debug_stage(
            repo, board, environment, run_env, cable_wait_s, result, show
        )
    except Exception as error:  # noqa: BLE001 - the stage's one boundary
        return result("FAIL", f"unexpected {type(error).__name__}: {error}")
    finally:
        if installed_sigterm:
            signal.signal(signal.SIGTERM, previous_sigterm)


def _debug_stage(
    repo: Path,
    board: str,
    environment: Mapping[str, str],
    run_env: Mapping[str, str],
    cable_wait_s: float,
    result: Callable[[str, str], dict[str, Any]],
    show: Callable[[str], None],
) -> dict[str, Any]:
    """Run the stage body that ``run_debug_stage`` guards."""
    if not run_env[JTAG_SERIAL_ENV]:
        return result(
            SKIP_STATUS,
            f"{JTAG_SERIAL_ENV} is not set; it selects the JTAG cable for OpenOCD",
        )
    config = DEBUG_CONFIGS.get(board)
    if config is None:
        return result(SKIP_STATUS, f"no OpenOCD configuration for {board}")
    openocd = environment.get(OPENOCD_ENV, "").strip() or "openocd"
    if shutil.which(openocd) is None:
        return result(
            ENV_FAIL_STATUS,
            f"{ENV_NOT_READY}: {openocd} is not installed ({OPENOCD_ENV} names it)",
        )
    if not wait_for_cable(cable_wait_s):
        return result(
            "FAIL",
            f"hw_server still owns the JTAG cable after {cable_wait_s:.0f}s; "
            "OpenOCD needs the cable to itself",
        )

    def command(procedure: str) -> list[str]:
        return debug_openocd_command(openocd, repo, config, procedure)

    def report_unknown(reason: str) -> None:
        """Print one masked line saying the hart state is UNKNOWN and how to recover."""
        line = (
            f"{DEBUG_STAGE}: hart state UNKNOWN ({reason}); "
            f"recover by hand with: {RECOVERY_COMMAND}"
        )
        print(mask_serial(line, run_env), file=sys.stderr, flush=True)

    def confirm() -> tuple[bool, str]:
        """Run the separate confirmation process and judge its result."""
        try:
            rec_out, rec_err, rec_timed_out, rec_exit = run_openocd_procedure(
                command("frost_debug_recover"), DEBUG_RECOVERY_TIMEOUT_S, run_env
            )
        except Exception as error:  # noqa: BLE001
            return (
                False,
                f"confirmation could not run ({type(error).__name__}: {error})",
            )
        try:
            show(rec_out + rec_err)
        except Exception as error:  # noqa: BLE001
            return (
                False,
                f"confirmation output failed ({type(error).__name__}: {error})",
            )
        try:
            return judge_debug_recovery(rec_out, rec_err, rec_timed_out, rec_exit)
        except Exception as error:  # noqa: BLE001
            return (
                False,
                f"confirmation judge failed ({type(error).__name__}: {error})",
            )

    try:
        lock = DEBUG_LOCK.open("a")
    except OSError as error:
        return result(
            ENV_FAIL_STATUS,
            f"{ENV_NOT_READY}: cannot open the host lock {DEBUG_LOCK}: {error}",
        )
    with lock:
        # Runs on one host take turns, as cache_counters.py's do.
        try:
            fcntl.flock(lock, fcntl.LOCK_EX)
        except OSError as error:
            return result(
                ENV_FAIL_STATUS,
                f"{ENV_NOT_READY}: cannot lock the host lock {DEBUG_LOCK}: {error}",
            )
        started = False
        interrupted = False
        primary_status = "FAIL"
        note = ""
        confirmed = False
        confirm_note = ""
        try:
            started = True
            try:
                stdout, stderr, timed_out, exit_code = run_openocd_procedure(
                    command("frost_debug_check"), DEBUG_TIMEOUT_S, run_env
                )
            except OSError as error:
                started = False
                return result(
                    ENV_FAIL_STATUS,
                    f"{ENV_NOT_READY}: cannot run {openocd} ({OPENOCD_ENV} names "
                    f"it): {error}",
                )
            except Exception as error:  # noqa: BLE001
                primary_status = "FAIL"
                note = f"unexpected {type(error).__name__}: {error}"
            else:
                try:
                    show(stdout + stderr)
                    ok, note = judge_debug_output(stdout)
                    err_marker = _find_error_marker(stderr)
                    if timed_out:
                        primary_status = "TIMEOUT"
                        note = f"OpenOCD did not finish in {DEBUG_TIMEOUT_S:.0f}s"
                    elif exit_code != 0:
                        primary_status = "FAIL"
                        exited = f"OpenOCD exited {exit_code}"
                        if err_marker is not None:
                            exited += f": {err_marker}"
                        note = exited if ok else f"{exited}; {note}"
                    elif err_marker is not None:
                        primary_status = "FAIL"
                        err_note = f"OpenOCD reported an error: {err_marker}"
                        note = err_note if ok else f"{err_note}; {note}"
                    elif ok:
                        primary_status = "PASS"
                    else:
                        primary_status = "FAIL"
                except Exception as error:  # noqa: BLE001
                    primary_status = "FAIL"
                    note = f"unexpected {type(error).__name__}: {error}"
        except BaseException:
            interrupted = True
            raise
        finally:
            # Whenever OpenOCD was started, a separate process always confirms
            # the hart is running while the board lock is still held, including
            # when interrupted by SIGINT or SIGTERM.
            if started:
                try:
                    confirmed, confirm_note = confirm()
                except BaseException:
                    report_unknown("confirmation interrupted")
                    raise
                if interrupted:
                    if confirmed:
                        print(
                            mask_serial(
                                f"{DEBUG_STAGE}: interrupted; {confirm_note}",
                                run_env,
                            ),
                            file=sys.stderr,
                            flush=True,
                        )
                    else:
                        report_unknown(confirm_note)
    if confirmed:
        return result(primary_status, f"{note}; {confirm_note}")
    return result(
        "FAIL",
        f"{note}; hart state UNKNOWN ({confirm_note}); "
        f"recover by hand with: {RECOVERY_COMMAND}",
    )


def finish_line(serial_fd: int, serial_buf: str, grace_s: float) -> str:
    """Read the rest of the buffer's last line, for ``grace_s`` at most.

    Return the text read (echoed like the rest of the capture).
    """
    deadline = time.monotonic() + grace_s
    text = ""
    while not (serial_buf + text).endswith("\n"):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        if not select.select([serial_fd], [], [], min(remaining, 0.1))[0]:
            continue
        data = read_available(serial_fd)
        if data:
            chunk = data.decode("utf-8", errors="replace")
            text += chunk
            sys.stdout.write(chunk)
            sys.stdout.flush()
    return text


def read_for_duration(serial_fd: int, duration_s: float) -> str:
    """Keep reading and echoing UART output for ``duration_s`` seconds.

    Return every chunk read during the window so callers can record and judge it.
    """
    deadline = time.monotonic() + duration_s
    text = ""
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        if not select.select([serial_fd], [], [], min(remaining, 0.1))[0]:
            continue
        data = read_available(serial_fd)
        if not data:
            if hasattr(time, "sleep"):
                time.sleep(min(remaining, 0.05))
            continue
        chunk = data.decode("utf-8", errors="replace")
        text += chunk
        sys.stdout.write(chunk)
        sys.stdout.flush()
    return text


def run_uart_stage(
    repo: Path,
    serial_fd: int,
    board: str,
    stage: UartStage,
    timeout_s: float,
    loader_extra: list[str],
    target: str,
    loader_env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    """Build and load one app, then capture UART to completion or timeout.

    A raw nonblocking loader fd avoids buffering the load sentinel. UART output
    before ``FROST_LOAD_COMPLETE`` belongs to the previous program and is
    discarded. ``loader_env`` is added to this process's environment for the
    loader, which is how the Linux stage names the NFS root it packs.
    """
    drain(serial_fd)
    cmd = [
        "./fpga/load_software/load_software.py",
        board,
        stage.app,
        "--target",
        target,
        *loader_extra,
    ]
    proc = subprocess.Popen(
        cmd,
        cwd=repo,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        env={**os.environ, **loader_env} if loader_env else None,
    )
    loader_fd = proc.stdout.fileno() if proc.stdout is not None else None
    if loader_fd is not None:
        os.set_blocking(loader_fd, False)

    loader_tail: collections.deque[str] = collections.deque(maxlen=80)
    loader_line_buf = ""
    serial_buf = ""
    post_failure_output: str | None = None
    loader_done = False
    program_started = False
    stimuli_sent = 0
    stimulus_from = 0
    start = time.monotonic()
    deadline = start + timeout_s
    last_uart_at = start

    def success_ready() -> bool:
        """Require the stage's success predicate and optional quiet interval."""
        if not stage.success_done(serial_buf):
            return False
        if stage.success_quiet_s:
            if min(time.monotonic(), deadline) - last_uart_at < stage.success_quiet_s:
                return False
            # Console writes can block while UART bytes accumulate.
            return not select.select([serial_fd], [], [], 0)[0]
        return True

    def consume_loader(text: str) -> None:
        """Split loader stdout into lines; reset capture at the load sentinel."""
        nonlocal loader_line_buf, program_started, serial_buf
        loader_line_buf += text
        while "\n" in loader_line_buf:
            line, loader_line_buf = loader_line_buf.split("\n", 1)
            loader_tail.append(line)
            if not program_started and LOAD_COMPLETE_SENTINEL in line:
                # Drop UART output from the previous image.
                program_started = True
                serial_buf = ""

    while time.monotonic() < deadline:
        rlist: list[Any] = [serial_fd]
        if loader_fd is not None and not loader_done:
            rlist.append(loader_fd)
        readable, _, _ = select.select(rlist, [], [], 0.1)
        for item in readable:
            if item == serial_fd:
                data = read_available(serial_fd)
                if data:
                    text = data.decode("utf-8", errors="replace")
                    serial_buf += text
                    if stage.success_quiet_s:
                        last_uart_at = time.monotonic()
                    sys.stdout.write(text)
                    sys.stdout.flush()
            else:
                data = read_available(loader_fd)
                if data:
                    consume_loader(data.decode("utf-8", errors="replace"))

        if program_started:
            pending = next_stimulus(stage, serial_buf, stimuli_sent, stimulus_from)
            if pending is not None:
                text, stimulus_from = pending
                shown = text.rstrip("\r\n")
                print(f"\n[hw_regression] typing UART input: {shown}", flush=True)
                send_uart_probe(serial_fd, text)
                stimuli_sent += 1

        if not loader_done and proc.poll() is not None:
            loader_done = True
            if loader_fd is not None:
                while True:
                    data = read_available(loader_fd)
                    if not data:
                        break
                    consume_loader(data.decode("utf-8", errors="replace"))
                if loader_line_buf:
                    consume_loader("\n")
            if proc.returncode != 0:
                return {
                    "stage": stage.app,
                    "status": "LOAD_FAIL",
                    "elapsed": time.monotonic() - start,
                    "note": f"load_software.py exited {proc.returncode}",
                    "loader_tail": list(loader_tail),
                }

        # Require loader completion and the sentinel before judging the new image.
        if (
            loader_done
            and program_started
            and (success_ready() or stage.failure_done(serial_buf))
        ):
            if not success_ready():
                if stage.failure_line_grace_s:
                    serial_buf += finish_line(
                        serial_fd, serial_buf, stage.failure_line_grace_s
                    )
                post_wait_s = (
                    stage.failure_post_wait_s(serial_buf)
                    if stage.failure_post_wait_s is not None
                    else 0.0
                )
                if post_wait_s > 0.0:
                    print(
                        f"\n[hw_regression] failure detected; reading console for "
                        f"{post_wait_s:.0f}s before ending stage",
                        flush=True,
                    )
                    post_failure_output = read_for_duration(serial_fd, post_wait_s)
                    serial_buf += post_failure_output
            break

    killed_loader = False
    if not loader_done and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        killed_loader = True

    elapsed = time.monotonic() - start
    if not program_started:
        status = "TIMEOUT"
        note = f"loader never reached {LOAD_COMPLETE_SENTINEL} within {timeout_s:.0f}s"
    elif success_ready() or stage.failure_done(serial_buf):
        ok, note = stage.judge(serial_buf)
        status = "PASS" if ok else "FAIL"
        if killed_loader:
            note = (note + "; " if note else "") + "loader hung and was killed"
    else:
        status = "TIMEOUT"
        note = f"no terminal UART output within {timeout_s:.0f}s"

    result: dict[str, Any] = {
        "stage": stage.app,
        "status": status,
        "elapsed": elapsed,
        "note": note,
        "loader_tail": list(loader_tail),
    }
    if post_failure_output is not None:
        result["post_failure_output"] = post_failure_output
    return result


def run_sweep_stage(
    repo: Path,
    board: str,
    serial: str,
    target: str,
    timeout_s: float,
    loader_extra: list[str],
    tolerance_pct: float,
    *,
    vector: bool | None = None,
) -> dict[str, Any]:
    """Run the -v0 CoreMark-PRO sweep and check its status and official mark.

    The sweep holds the UART exclusively. Each workload's registry minimum can
    raise the base timeout; check the printed mark against the board baseline.
    """
    cmd = [
        "./fpga/sweep_coremark_pro.py",
        "--board",
        board,
        "-v0",
        "--serial",
        serial,
        "--target",
        target,
        "--timeout",
        str(timeout_s),
    ]
    for extra in loader_extra:
        cmd.extend(["--loader-extra", extra])
    start = time.monotonic()
    proc = subprocess.Popen(
        cmd,
        cwd=repo,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    captured: list[str] = []
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        captured.append(line)
    returncode = proc.wait()
    elapsed = time.monotonic() - start
    output = "".join(captured)

    if returncode != 0:
        return {
            "stage": SWEEP_STAGE,
            "status": "FAIL",
            "elapsed": elapsed,
            "note": f"sweep exited {returncode}; not all nine workloads passed",
        }
    score_match = re.search(
        r"CoreMark-PRO score \(single context\): ([0-9]+(?:\.[0-9]+)?)", output
    )
    if not score_match:
        return {
            "stage": SWEEP_STAGE,
            "status": "FAIL",
            "elapsed": elapsed,
            "note": "sweep passed but printed no official CoreMark-PRO score",
        }
    ok, note = check_score(
        board,
        "coremark_pro",
        float(score_match.group(1)),
        tolerance_pct,
        vector=vector,
    )
    return {
        "stage": SWEEP_STAGE,
        "status": "PASS" if ok else "FAIL",
        "elapsed": elapsed,
        "note": note,
    }


# debug_target waits for a debugger to write its flag, so UART-only runs time out.
# Keep it loadable through VALID_APPS, but exclude it from regression.
DEBUGGER_DRIVEN_APPS = frozenset({"debug_target"})

# These applications require an external link. Keep them loadable through VALID_APPS;
# use nic_loopback for unattended regression.
EXTERNAL_LINK_APPS = frozenset({"nic_bench", "nic_echo"})

# These applications report observations without an acceptance limit on VCU118.
VCU118_MEASUREMENT_APPS = frozenset(
    {"bpred_probe", "fplat_probe", "mispen_probe", "print_clock_speed", "tomasulo_perf"}
)


def _loader_extra_has_option(
    loader_extra: Sequence[str], option_names: tuple[str, ...]
) -> bool:
    """Return True if any loader-extra token passes one of ``option_names``."""
    return any(
        token in option_names
        or any(token.startswith(f"{name}=") for name in option_names)
        for token in loader_extra
    )


def stage_loader_extra(
    stage_name: str,
    loader_extra: Sequence[str],
    *,
    vlen: int | None = None,
    vec_advertise: bool | None = None,
    board: str | None = None,
    vector: bool | None = None,
) -> list[str]:
    """Return load_software.py extra arguments for one regression stage."""
    extra = list(loader_extra)
    if board == "vcu118" and vector is not None:
        extra.append("--vector" if vector else "--no-vector")
    if vlen is not None and stage_name in VEC_VLEN_APPS:
        extra.extend(["--vlen", str(vlen)])
    if vec_advertise is not None and stage_name in VEC_ADVERTISE_APPS:
        extra.append("--vec-advertise" if vec_advertise else "--no-vec-advertise")
    return extra


def regression_stages(board: str, *, vector: bool = False) -> list[str]:
    """Return the selected board's stages in order.

    Start with hello_world and the debug port where configured.
    Exclude apps for other boards, debugger-driven apps and those needing an
    external link partner. VCU118 omits measurement-only applications.
    Keep ECC last so it covers all earlier traffic.
    """
    phase1 = [
        app
        for app in valid_apps_for_board(board, vector=vector)
        if app != LINUX_STAGE
        and app not in COREMARK_PRO_APP_NAMES
        and app not in DEBUGGER_DRIVEN_APPS
        and app not in EXTERNAL_LINK_APPS
        and (board != "vcu118" or app not in VCU118_MEASUREMENT_APPS)
    ]
    phase1.remove("hello_world")
    phase1.insert(0, "hello_world")
    if board in DEBUG_CONFIGS:
        phase1.insert(1, DEBUG_STAGE)
    stages = [*phase1, SWEEP_STAGE, LINUX_STAGE]
    if board in ECC_WINDOW_DESIGNS:
        stages.append(ECC_STAGE)
    return stages


class _MaskedStream:
    """Write to a text stream with the configured cable serial masked."""

    def __init__(self, stream: Any) -> None:
        self._stream = stream

    def write(self, text: str) -> int:
        return self._stream.write(mask_serial(text))

    def writelines(self, lines: Any) -> None:
        for line in lines:
            self.write(line)

    def __getattr__(self, name: str) -> Any:
        return getattr(self._stream, name)


def main() -> int:
    """Run the selected stages; everything printed or raised masks the serial.

    This is the one place that guarantees it: stdout and stderr are wrapped,
    and an exception that escapes is printed masked instead of as a traceback
    that could carry the serial.
    """
    import traceback

    real_out, real_err = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = _MaskedStream(real_out), _MaskedStream(real_err)
    try:
        return _main()
    except SystemExit:
        raise
    except Exception:  # noqa: BLE001
        print(traceback.format_exc(), file=sys.stderr)
        return 1
    finally:
        sys.stdout, sys.stderr = real_out, real_err


def _main() -> int:
    """Run the selected stages in order and print the final summary."""
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--board",
        required=True,
        choices=list(BOARD_CONFIG),
        help="Target FPGA board",
    )
    parser.add_argument(
        "--repo",
        type=Path,
        default=REPO_DEFAULT,
        help=f"FROST repo root (default: {REPO_DEFAULT})",
    )
    parser.add_argument(
        "--serial",
        default=None,
        help="Board UART device (default: per --board, see shared hardware defaults)",
    )
    parser.add_argument(
        "--target",
        default=None,
        help="JTAG hardware target pattern (default: per --board)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=None,
        help=(
            "Base per-app timeout in seconds, build included; bootrom and the "
            "sweep apply application-specific minimums (default: per --board)"
        ),
    )
    parser.add_argument(
        "--linux-timeout",
        type=float,
        default=DEFAULT_LINUX_TIMEOUT,
        help=(
            "linux_boot timeout in seconds covering rebuild, the JTAG DDR image "
            "load, boot through the NFS mount, systemd's startup and every "
            f"program the stage types (default: {DEFAULT_LINUX_TIMEOUT:.0f}; "
            "raise it for a divided-clock bitstream, or for a first build that "
            "must download the Buildroot toolchain or the kernel)"
        ),
    )
    parser.add_argument(
        "--linux-dtb",
        type=Path,
        default=None,
        help=(
            "Compiled device tree blob (.dtb) to pack for linux_boot instead "
            f"of generating one (overrides {LINUX_DTB_ENV})"
        ),
    )
    parser.add_argument(
        "--linux-isa-expect",
        choices=LINUX_ISA_EXPECT_CHOICES,
        default=LINUX_ISA_EXPECT_DEFAULT,
        help=(
            "Expected ISA extension probe mode during linux_boot "
            f"(default: {LINUX_ISA_EXPECT_DEFAULT})"
        ),
    )
    parser.add_argument(
        "--score-tolerance",
        type=float,
        default=DEFAULT_SCORE_TOLERANCE_PCT,
        metavar="PCT",
        help=(
            "Allowed percent drop below a recorded baseline score before the "
            f"stage fails (default: {DEFAULT_SCORE_TOLERANCE_PCT:g}%%)"
        ),
    )
    parser.add_argument(
        "--keep-going",
        action="store_true",
        help="Run every stage even after a failure (default: stop at the first)",
    )
    parser.add_argument(
        "--loader-extra",
        action="append",
        default=[],
        help=(
            "Extra argument appended to every load_software.py invocation "
            "(also forwarded to the sweep)"
        ),
    )
    parser.add_argument(
        "--vlen",
        type=int,
        choices=SUPPORTED_VEC_STATE_VLENS,
        default=None,
        metavar="BITS",
        help=(
            "Vector length in bits (128, 256, or 512; or 0 for scalar "
            "vec_state_test) forwarded to vector-width application stages "
            "(default: match the selected board's RTL)"
        ),
    )
    parser.add_argument(
        "--vec-advertise",
        action=argparse.BooleanOptionalAction,
        default=None,
        help=(
            "Override whether vec_state_test expects misa.V to be set "
            "(default: match the selected board's RTL, or off when --vlen 0)"
        ),
    )
    parser.add_argument(
        "--vector",
        action=argparse.BooleanOptionalAction,
        default=None,
        help=(
            "Target an opt-in VCU118 vector build (162500000 Hz CPU clock, "
            "vector stages enabled, --vector forwarded to load_software.py; "
            "default: on for x3, off for vcu118)"
        ),
    )
    parser.add_argument(
        "stages",
        nargs="*",
        help=(
            "Optional subset of stages to run, always in regression order (app "
            f"names plus '{DEBUG_STAGE}', '{SWEEP_STAGE}', '{LINUX_STAGE}' and "
            f"'{ECC_STAGE}' where supported. Default: all for the selected board)"
        ),
    )
    args = parser.parse_args()

    board = args.board
    target = args.target if args.target else DEFAULT_TARGETS[board]
    serial = args.serial if args.serial else DEFAULT_SERIALS[board]
    timeout = args.timeout if args.timeout is not None else DEFAULT_TIMEOUTS[board]
    try:
        net_repeat = nettest_repeat()
        net_poke_s = nettest_poke()
    except ValueError as error:
        parser.error(str(error))

    if board == "x3" and args.vector is False:
        parser.error("--no-vector is only supported for vcu118")
    if args.vector is not None and _loader_extra_has_option(
        args.loader_extra, ("--vector", "--no-vector")
    ):
        parser.error(
            "--vector/--no-vector cannot also be passed through --loader-extra"
        )
    vcu118_vector = board == "vcu118" and bool(args.vector)

    if args.vlen == 0 and args.vec_advertise:
        parser.error("--vec-advertise requires a nonzero --vlen")
    if args.vlen is not None and _loader_extra_has_option(
        args.loader_extra, ("--vlen",)
    ):
        parser.error("--vlen cannot also be passed through --loader-extra")
    if args.vec_advertise is not None and _loader_extra_has_option(
        args.loader_extra, ("--vec-advertise", "--no-vec-advertise")
    ):
        parser.error(
            "--vec-advertise/--no-vec-advertise cannot also be passed through "
            "--loader-extra"
        )

    all_stages = regression_stages(board, vector=vcu118_vector)

    if args.stages:
        requested = set(args.stages)
        excluded = sorted(requested & (DEBUGGER_DRIVEN_APPS | EXTERNAL_LINK_APPS))
        if excluded:
            parser.error(
                f"not a regression stage: {', '.join(excluded)} (debug_target needs "
                "a debugger; nic_echo needs a link partner sending the cocotb wire "
                "peer's frames; nic_bench needs an external loopback; "
                "load_software.py can still run them)"
            )
        unknown = sorted(requested - set(all_stages))
        if unknown:
            parser.error(
                f"unknown stage(s): {', '.join(unknown)}\n"
                f"valid stages: {', '.join(all_stages)}"
            )
        selected = [stage for stage in all_stages if stage in requested]
    else:
        selected = all_stages

    if args.vlen == 0:
        vector_only = [stage for stage in selected if stage in VECTOR_UNIT_APPS]
        if vector_only:
            parser.error(
                f"--vlen 0 cannot run vector-unit stages: {', '.join(vector_only)}"
            )
    if args.vec_advertise and args.vlen is None and "vec_state_test" in selected:
        try:
            board_vlen, _ = board_vector_config(
                board, project_root=args.repo, vector=vcu118_vector
            )
        except (OSError, ValueError) as error:
            parser.error(str(error))
        if board_vlen == 0:
            parser.error("--vec-advertise requires a nonzero --vlen")

    # The debug and ECC stages use JTAG only; the UART check matters to the rest.
    uses_uart = any(stage not in (DEBUG_STAGE, ECC_STAGE) for stage in selected)
    holders = serial_holders(serial) if uses_uart else []
    if holders:
        print(
            f"ERROR: {serial} is already open in another process, which would "
            "steal chunks of the UART capture:",
            file=sys.stderr,
        )
        for holder in holders:
            print(f"  {holder}", file=sys.stderr)
        print("Close it (or pass another --serial) and re-run.", file=sys.stderr)
        return 1

    # Check NFS setup before any stage. On failure, --keep-going runs the other
    # stages and reports Linux as ENV_FAIL; otherwise stop here.
    linux_root: LinuxRoot | None = None
    linux_env_error: str | None = None
    if LINUX_STAGE in selected:
        try:
            linux_root = (
                linux_root_from_env(dtb_override=args.linux_dtb)
                if args.linux_dtb is not None
                else linux_root_from_env()
            )
            for note in linux_root_preflight(linux_root, args.repo):
                print(f"[hw_regression] Linux root: {mask_serial(note)}", flush=True)
        except Exception as error:  # noqa: BLE001
            # Host or export I/O errors are setup failures, not tracebacks.
            linux_env_error = mask_serial(
                str(error)
                if isinstance(error, LinuxEnvironmentError)
                else f"{ENV_NOT_READY}: {error}"
            )
            print(f"\nERROR: {LINUX_STAGE}: {linux_env_error}", file=sys.stderr)
            if not args.keep_going:
                return 1

    results: list[dict[str, Any]] = []
    serial_fd: int | None = None
    try:
        for index, stage_name in enumerate(selected, start=1):
            print(
                f"\n===== {board} {stage_name} [{index}/{len(selected)}] =====",
                flush=True,
            )
            if stage_name == LINUX_STAGE and linux_env_error is not None:
                result = {
                    "stage": LINUX_STAGE,
                    "status": ENV_FAIL_STATUS,
                    "elapsed": 0.0,
                    "note": linux_env_error,
                }
            elif stage_name == ECC_STAGE:
                result = run_ecc_stage(args.repo, board, target, ECC_STAGE_TIMEOUT_S)
            elif stage_name == DEBUG_STAGE:
                result = run_debug_stage(args.repo, board)
            elif stage_name == SWEEP_STAGE:
                # Release the UART before the sweep requests exclusive access.
                if serial_fd is not None:
                    os.close(serial_fd)
                    serial_fd = None
                sweep_loader_extra = list(args.loader_extra)
                sweep_kwargs: dict[str, Any] = {}
                if board == "vcu118" and args.vector is not None:
                    sweep_loader_extra.append(
                        "--vector" if args.vector else "--no-vector"
                    )
                    sweep_kwargs["vector"] = args.vector
                result = run_sweep_stage(
                    args.repo,
                    board,
                    serial,
                    target,
                    timeout,
                    sweep_loader_extra,
                    args.score_tolerance,
                    **sweep_kwargs,
                )
            else:
                if serial_fd is None:
                    serial_fd = configure_serial(serial)
                loader_env = None
                if stage_name == LINUX_STAGE:
                    assert linux_root is not None
                    stage = linux_stage(
                        linux_root,
                        net_repeat,
                        net_poke_s,
                        driver_version=source_driver_version(args.repo),
                        board=board,
                        isa_expect=args.linux_isa_expect,
                        isa_vlenb=resolve_isa_vlenb(args.repo, board, linux_root.dtb),
                    )
                    stage_timeout = args.linux_timeout
                    loader_env = linux_loader_env(linux_root)
                else:
                    stage_kwargs: dict[str, Any] = (
                        {"vector": args.vector}
                        if board == "vcu118" and args.vector is not None
                        else {}
                    )
                    stage = build_stage(
                        stage_name,
                        board,
                        args.score_tolerance,
                        **stage_kwargs,
                    )
                    stage_timeout = timeout
                    if board == "vcu118" and stage_name == "bootrom":
                        stage_timeout = max(timeout, BOOTROM_TIMEOUT_S)
                result = run_uart_stage(
                    args.repo,
                    serial_fd,
                    board,
                    stage,
                    stage_timeout,
                    stage_loader_extra(
                        stage_name,
                        args.loader_extra,
                        vlen=args.vlen,
                        vec_advertise=args.vec_advertise,
                        board=board,
                        vector=args.vector,
                    ),
                    target,
                    loader_env,
                )
            results.append(result)

            note = f" -- {result['note']}" if result["note"] else ""
            print(
                f"\nRESULT {board} {result['stage']}: {result['status']} "
                f"time={result['elapsed']:.1f}s{note}",
                flush=True,
            )
            if result["status"] in ("LOAD_FAIL", "TIMEOUT") and result.get(
                "loader_tail"
            ):
                print("loader tail:", flush=True)
                print("\n".join(result["loader_tail"]), flush=True)

            if result["status"] not in ("PASS", SKIP_STATUS) and not args.keep_going:
                break
    finally:
        if serial_fd is not None:
            os.close(serial_fd)

    skipped = selected[len(results) :]
    bad = [r for r in results if r["status"] not in ("PASS", SKIP_STATUS)]
    not_run = [r for r in results if r["status"] == SKIP_STATUS]

    print(f"\nSUMMARY ({board})")
    name_width = max(len(r["stage"]) for r in results) if results else 12
    for r in results:
        note = f"  {r['note']}" if r["note"] else ""
        print(
            f"  {r['stage']:<{name_width}} {r['status']:>9} {r['elapsed']:>8.1f}s{note}"
        )
    if skipped:
        print(f"  skipped after failure: {', '.join(skipped)}")

    passed = len(results) - len(bad) - len(not_run)
    # A skipped stage is neither a pass nor a failure; all-skipped checked nothing.
    verdict = "PASS" if passed and not bad and not skipped else "FAIL"
    tail = f", {len(not_run)} skipped" if not_run else ""
    print(f"\nREGRESSION {verdict}: {passed}/{len(selected)} stages passed{tail}")
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
