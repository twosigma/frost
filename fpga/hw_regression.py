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

r"""Run all hardware apps, CoreMark-PRO, and Linux on a FROST board.

Each bare-metal app is rebuilt, JTAG-loaded, and checked from UART output:
``<<PASS>>`` must appear; ``<<FAIL>>``, ``<<TRAP>>``, ``ERROR``, or nonzero
``:fails=N`` counters fail. ``hello_world`` instead requires two one-second
greetings, and ``uart_echo`` must return a typed probe. CoreMark uses
``ITERATIONS * FPGA_CPU_CLK_FREQ / Total 64-bit ticks`` because its printed
``Iterations/Sec`` uses a 32-bit tick count that overflows after about 14 s at
300 MHz and can hide slowdowns.

Next, ``sweep_coremark_pro.py -v0`` runs all nine workloads with exclusive UART
access; both its status and official mark are checked. The forwarded common
timeout is a base budget; the sweep honors any larger per-workload minimum in
the software registry.

Linux runs last, and it boots the real system: Debian 13 from its NFSv3 root
over the NIC, with Debian's pinned riscv64 kernel (``linux/debian_kernel.py``)
and the initramfs that mounts that export (``docs/debian_nfsroot.md``). The
export, the board's address, the kernel and the initramfs are site-specific, so
``FROST_LINUX_NFSROOT``, ``FROST_LINUX_IP``, ``FROST_LINUX_KERNEL`` and
``FROST_LINUX_INITRD`` come from the environment with nothing defaulted, and a
preflight checks them before any stage runs: the export has to be a directory
on this host, its server has to answer an NFSv3 NULL call over TCP, and the
kernel and initramfs have to exist, with the kernel carrying the pinned
release's banner. A preflight failure is reported as ``ENV_FAIL``, never as a
stage failure. The preflight also cross-compiles ``frost_stress`` and
``frost_nettest`` statically from
``linux/buildroot-external/package/frost-stress`` and installs them in the
export's ``/usr/local/bin``: Buildroot builds them against musl for the test
initramfs, which a glibc root cannot run.

The stage requires the kernel's own version banner, the NIC driver's probe line
before the login prompt, the distribution's name and a console login; traps,
panics,
and kernel ``Oops``, ``BUG:`` and ``Kernel BUG`` reports fail, but the
bare-metal ``ERROR`` rule does not apply to kernel logs. It then logs in as root
and types four programs: ``findmnt``, whose line must show ``/`` mounted from
the packed export over NFSv3; ``systemctl``, which must report ``running`` with
no failed unit; the stress payload, whose pass token must follow the login; and
``frost_stress --counters``, whose cycle and instret counts for a child measured
through an exec must both be nonzero. Last is ``frost_nettest``, which runs the
NIC driver through its loopback feature (the NIC's raw loopback on a shared MAC
clock, the transceiver's PMA loopback otherwise) and must print
``FROST_NET_LOOPBACK_PASS``; the interface it takes down is the one the root is
mounted over, so it runs from a tmpfs copy, and the line around it gives the
link back and then requires a bounded ``sync`` to succeed -- the pass token
alone is printed over a root that is still gone. ``--linux-timeout`` covers build, DDR loading, boot and
every typed program; a cold Buildroot build (for OpenSBI) and Debian kernel
fetch take a few minutes, mostly downloads.

CI keeps booting the Buildroot test initramfs instead: its QEMU job has no
frost,net10g device and cannot mount this export. That image is why this stage
changed -- it loads no module, runs no real userspace and mounts no root, and it
passed 44 of 44 stages on bitstreams that panicked Debian within six minutes.
``amo_irq_torture`` separately guards the former mid-AMO interrupt race that
caused intermittent boot corruption. Two apps are left out: ``debug_target``
waits for a debugger to drive it, and ``nic_echo`` needs a link partner that
sends it the cocotb wire peer's frames, which the regression does not have, so
neither can pass unattended.
``nic_loopback`` is the NIC stage. ``perf_off_test`` checks the production
netlist's absent profiling counters, so it runs only against a rated-clock
bitstream: a ``--cpu-clock-div`` build includes the counters by default and
drops the stage (``netlist_config.json`` in the build work directory records
which way that bitstream was synthesized).

Scores may fall at most ``--score-tolerance`` percent below the board baseline.
A ``None`` baseline reports the measurement without failing. The regression
stops at the first failure unless ``--keep-going`` and exits zero only when all
selected stages pass.

Examples (from the repo root):

    # Full regression on X3
    ./fpga/hw_regression.py --board x3

    # Run everything even past failures, with a looser score gate
    ./fpga/hw_regression.py --board x3 --keep-going --score-tolerance 2

    # Re-run a subset (stage names = app names plus coremark_pro/linux_boot)
    ./fpga/hw_regression.py --board x3 uart_echo coremark_pro linux_boot

    # The Linux stage alone, against this site's NFS root (see the block above)
    K=6.12.107+deb13-riscv64
    FROST_LINUX_NFSROOT=192.0.2.1:/srv/nfs/debian \
    FROST_LINUX_IP=192.0.2.2::192.0.2.1:255.255.255.0:frost:eth0:off \
    FROST_LINUX_KERNEL=/srv/nfs/debian/boot/vmlinux-$K \
    FROST_LINUX_INITRD=/srv/nfs/debian/boot/initrd.img-$K \
      ./fpga/hw_regression.py --board x3 linux_boot
"""

import argparse
import collections
import ipaddress
import os
import re
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Mapping
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
from debian_kernel import (  # noqa: E402
    INITRAMFS_COUNTER_TOKEN,
    KERNEL_BANNER,
    KERNEL_RELEASE,
)
from hw_defaults import (  # noqa: E402
    DEFAULT_SERIALS,
    DEFAULT_TARGETS,
    DEFAULT_TIMEOUTS,
)
from load_software import (  # noqa: E402
    BOARD_CONFIG,
    CPU_CLK_ENV,
    VALID_APPS,
    board_clock_freq,
)
from software_registry import COREMARK_PRO_APP_NAMES  # noqa: E402
from sweep_coremark_pro import (  # noqa: E402
    LOAD_COMPLETE_SENTINEL,
    configure_serial,
    drain,
    read_available,
    serial_holders,
)

# ``None`` leaves a score unarmed. The CoreMark baseline below predates the
# 2026-08-27 CoreMark build retune in sw/apps/coremark/Makefile (C extension
# dropped for that program, GCC auto-inline budget raised, priority RA,
# -fstrict-aliasing). The original -16.2% cycle result was measured before the
# Phase 3 16 KiB low-BRAM predecode overlay, which raised the unchanged tuned
# build to 353,923 mean timed-region cycles. Its 64 KiB replacement recovers
# 304,893 cycles in matched two-run cocotb; neither executable bytes nor
# benchmark settings changed. CoreMark-PRO has its own Makefile and did not
# receive the compiler retune, but benefits from the RTL recovery. Both
# baselines below were re-armed from the 2026-09-05 X3 board sweep of the
# recovered build (the first silicon measurement after the retune and the
# 64 KiB overlay).
# Armed from the 2026-09-20 X3 board sweep at 300 MHz.
BASELINE_SCORES: dict[str, dict[str, float | None]] = {
    "x3": {"coremark": 1014.86, "coremark_pro": 144.65},
}

# FROST is cycle-deterministic; only DDR refresh adds sub-percent score jitter.
DEFAULT_SCORE_TOLERANCE_PCT = 1.0

# Non-app stage names; linux_boot also names its loader app.
SWEEP_STAGE = "coremark_pro"
LINUX_STAGE = "linux_boot"

# Two greetings prove boot and the one-second timer; no pass marker is printed.
HELLO_GREETING = "Frost: Hello, world!"
HELLO_MIN_GREETINGS = 2

# A returned probe proves every byte crossed UART RX and TX.
ECHO_PROMPT = "frost> "
ECHO_PROBE = "FROST_HW_REGRESSION_ECHO_PROBE"
ECHO_EXPECTED = f'You typed: "{ECHO_PROBE}" ({len(ECHO_PROBE)} chars)'

# --- Linux stage: Debian 13 on its NFS root over the NIC ---------------------
#
# The stage boots what FROST ships. It used to boot the Buildroot test
# initramfs, which loads no module, runs no real userspace and mounts no root
# filesystem, so it passed 44 of 44 stages on bitstreams that panicked Debian
# within six minutes: both core bugs found in 2026-09 (a load-queue stale slot
# and a page-table walker that missed the L1D's dirty lines) went straight
# through it. CI keeps that initramfs -- its QEMU job has no frost,net10g
# device and cannot mount this export -- so the small image stays the in-CI
# functional check and this stage boots the real system.
#
# Every value the boot needs is site-specific: the server, the board's address,
# the export and the two files in it. They come from the environment with no
# defaults, and a missing one is an environment failure reported before any
# stage runs (docs/debian_nfsroot.md builds the root and names each variable).
LINUX_NFSROOT_ENV = "FROST_LINUX_NFSROOT"
LINUX_IP_ENV = "FROST_LINUX_IP"
LINUX_KERNEL_ENV = "FROST_LINUX_KERNEL"
LINUX_INITRD_ENV = "FROST_LINUX_INITRD"
LINUX_ROOT_ENV_VARS = (
    LINUX_NFSROOT_ENV,
    LINUX_IP_ENV,
    LINUX_KERNEL_ENV,
    LINUX_INITRD_ENV,
)

# Every preflight message starts with this, and the stage result that carries
# one is not a FAIL: a server that is down, an export that is not prepared or a
# host with no cross compiler must never read as an RTL regression.
ENV_NOT_READY = "environment not ready (not a board failure)"
ENV_FAIL_STATUS = "ENV_FAIL"


class LinuxEnvironmentError(RuntimeError):
    """The operator's NFS root cannot be booted from this host.

    Raised by ``linux_root_from_env`` and ``linux_root_preflight``; the message
    starts with ``ENV_NOT_READY`` and names the fix.
    """


# This console is an interactive terminal, so it carries escape sequences, and
# they land exactly where the stage reads values. Debian's bash drives bracketed
# paste, turning it off as it starts a command and on again with the next
# prompt, so the first line of a command's output arrives as
# ``ESC[?2004l CR <output>``: an anchored pattern then finds the escape where the
# line should start, which is what made a board run whose every check printed
# correctly sit out its whole deadline. systemd colours its greeting and its
# status lines the same way. Every predicate therefore matches against the
# capture with the escapes removed; nothing this stage looks for is one.
# CSI (colours, bracketed paste, cursor moves), OSC (a window title, which the
# prompt sets under some TERMs) and the two-character escapes. The OSC body stops
# at a newline as well as at its terminators, so an escape that never finishes --
# a capture read in the middle of one, or a stray byte from a program -- cannot
# swallow the line after it.
ANSI_ESCAPE_RE = re.compile(
    r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b\n]*(?:\x07|\x1b\\)?|[@-Z\\-_])"
)


def console_text(serial_buf: str) -> str:
    """Return a UART capture with terminal escape sequences removed."""
    return ANSI_ESCAPE_RE.sub("", serial_buf)


# A healthy kernel log can contain ``ERROR``, so Linux is judged by these
# markers instead of the bare-metal word rule. The kernel's own banner is one
# of them: FROST boots Debian's kernel (linux/debian_kernel.py names it, and
# the NFS root installs the same version), and packing any other one must fail
# rather than pass on the userspace markers, which would appear either way. The
# banner ends in a space, so a release this one is a prefix of does not match.
# The other two are the distribution's own name and the console login prompt,
# which stand where the Buildroot banner and ``buildroot login:`` used to: the
# export has to be a Debian root, and the console has to offer a login.
#
# The name, and not systemd's whole greeting: on the board that greeting reads
# ``ESC[0;1;39mWelcome to ESC[0mESC[1mDebian GNU/Linux 13 (trixie)ESC[0m…``, so
# the name is the part that survives whether or not the escapes were stripped,
# and the console getty's /etc/issue carries it too. Either source is the
# evidence wanted here -- that the tree that booted is a Debian system -- while
# the release comes from the kernel banner above and the state of its init from
# the systemd check below.
DEBIAN_OS_NAME = "Debian GNU/Linux"
LINUX_LOGIN_PROMPT = "login: "
LINUX_SUCCESS_MARKERS = (KERNEL_BANNER, DEBIAN_OS_NAME, LINUX_LOGIN_PROMPT)
LINUX_FAILURE_MARKERS = ("<<TRAP>>", "Kernel panic", "Oops", "BUG:", "Kernel BUG")
LINUX_SHELL_PROMPT = "# "

# Debian's initramfs loads the NIC driver with a quiet modprobe, so the line
# that proves the module is in the kernel is the driver's own probe message
# (frost_net10g.c, netdev_info); it prints before the root is mounted, so it
# still precedes the login prompt. It replaces the test initramfs's
# ``FROST_NET10G_MODULE_PASS <release>`` line, which an init script in that
# image printed and no Debian root has. That line also certified the running
# release, because CONFIG_MODVERSIONS lets a module load into any
# ABI-compatible kernel; here the kernel's own banner above certifies it, and
# the module is the DKMS build for the release the banner names.
LINUX_DRIVER_LINE = "FROST net10g, IRQ "

# The stress payload. In the test initramfs an inittab sysinit entry ran it
# before the getty; Debian's root runs no such entry, so the stage types it at
# the shell and requires the token after the login prompt. Absolute path: the
# payload's phase 2 re-execs itself with ``execv``, which does not search PATH.
LINUX_TOKEN = "FROST_USERSPACE_STRESS_PASS"
LINUX_TOKEN_FAIL = "FROST_USERSPACE_STRESS_FAIL"
LINUX_ROOT_BIN = "/usr/local/bin"
LINUX_STRESS_COMMAND = f"{LINUX_ROOT_BIN}/frost_stress --boot"

# Only the real root can show these two. ``findmnt`` names what ``/`` is
# mounted from, which must be the export the loader packed, over NFS, at the
# version the initramfs asks for; ``systemctl`` must report a finished startup
# with no failed unit. The failed units are listed before the state so that a
# degraded system says why in the same capture.
# Three raw fields are parsed: fstype, source, and the comma-separated options,
# in which ``vers=3`` has to be one whole option (``mountvers=3`` is a different
# thing, and an NFSv2 mount can carry it). findmnt has no colour option of its
# own and libsmartcols prints raw output plain, so the fields arrive as they are
# even though this console is a tty.
LINUX_ROOT_MOUNT_COMMAND = "findmnt -rno FSTYPE,SOURCE,OPTIONS /"
# The pattern ends on a newline, not ``$``: this runs on a capture that grows
# byte by byte, and ``$`` also matches at the end of the buffer, so a line still
# arriving would be read as a complete one.
LINUX_ROOT_MOUNT_RE = re.compile(
    r"^\r*(nfs\d*)[ \t]+(\S+)[ \t]+(\S+)[ \t\r]*\n", re.MULTILINE
)
LINUX_ROOT_MOUNT_VERS = "vers=3"
# ``--wait`` returns when the startup finishes, however slow the board is, and
# the outer ``timeout`` bounds it so that a startup which never finishes prints
# ``starting`` -- a terminal state, named in the verdict -- instead of running the
# whole stage out on its deadline. The state is printed through ``state=``, a
# prefix the echoed command line cannot produce because there it reads
# ``state=$(...)``. Matching a bare ``running`` line instead would depend on
# where the terminal wrapped the echo of this command, which carries that word
# inside its own name.
LINUX_SYSTEMD_WAIT_S = 300
# ``--no-pager``, because a long enough list of failed units would otherwise
# open a pager on this console, which reads the input the stage has typed ahead.
LINUX_SYSTEMD_COMMAND = (
    f"timeout {LINUX_SYSTEMD_WAIT_S} systemctl is-system-running --wait "
    ">/dev/null; "
    "systemctl --failed --no-legend --plain --no-pager; "
    "echo state=$(systemctl is-system-running)"
)
LINUX_SYSTEMD_RUNNING = "running"
# Any state but ``running`` is terminal, so a degraded boot ends the capture
# instead of waiting out the stage timeout, and it is reported by name.
# On a newline, like the mount pattern above: a capture that stops inside
# ``state=running`` would otherwise read as the state ``r`` and fail the stage.
LINUX_SYSTEMD_STATE_RE = re.compile(r"^\r*state=(\w+)[ \t\r]*\n", re.MULTILINE)

# ``frost_stress --counters`` reads the SBI PMU's cycle and instret counters
# through perf_event_open and prints them on its own line. This replaced
# ``perf stat``: perf builds only against a kernel tree, and this tree builds no
# kernel, so it is not packed for the target. Like perf stat, the counters cover
# a child measured from its exec to its exit, which ``scope`` names; the stage
# requires that scope, so a narrower measurement is a failure rather than a
# quiet loss of coverage.
LINUX_COUNTER_EVENTS = ("cycles", "instret")
LINUX_COUNTER_SCOPE = "exec-child"
LINUX_COUNTER_COMMAND = f"{LINUX_ROOT_BIN}/frost_stress --counters"
LINUX_COUNTER_LINE = f"{INITRAMFS_COUNTER_TOKEN}:"
LINUX_COUNTER_RE = re.compile(
    LINUX_COUNTER_LINE + r"((?: \w+=[\w.+-]+)+) verdict=PASS", re.MULTILINE
)
# A run that could not read the counters prints its own verdict. Without this
# the stage matched neither success nor failure and ran to the timeout, which
# reported no terminal output at all.
LINUX_COUNTER_FAIL_RE = re.compile(
    LINUX_COUNTER_LINE + r"(?: \w+=[\w.+-]+)* verdict=FAIL", re.MULTILINE
)

# At the next shell prompt the stage types frost_nettest (the frost-stress
# package), which runs the frost,net10g driver through its loopback feature
# (the NIC's raw loopback or the transceiver's PMA loopback) and ends with one
# of these tokens. On this root that interface carries the root filesystem, so
# ``nettest_command`` wraps it; see there.
LINUX_NET_COMMAND = "frost_nettest"
LINUX_NET_TOKEN = "FROST_NET_LOOPBACK_PASS"
LINUX_NET_TOKEN_FAIL = "FROST_NET_LOOPBACK_FAIL"
# A tmpfs on the root, mounted by systemd before any login.
LINUX_TMPFS = "/dev/shm"
# The interface the initramfs configures when ``ip=`` names none, and the name
# the docs' root keeps by masking udev's predictable naming.
DEFAULT_NIC_INTERFACE = "eth0"
# The root has to survive the loopback test, which takes its link down: the link
# comes back, the route with it, the server answers again, and the board's writes
# reach it. Creating a file proves the first three -- an NFS create is a round
# trip to the server, where a bare ``sync`` over a tree with nothing dirty left
# would return without one -- and the ``sync`` then flushes what the boot wrote.
# The status is printed through a ``=<status>`` the echoed command line cannot
# carry, where it reads ``=$?``. The bound keeps a server that never answers from
# becoming a bare stage timeout, and ``-k`` follows it with a kill, because a
# hard mount's wait ignores the first signal.
LINUX_ROOT_ALIVE_TOKEN = "FROST_ROOT_ALIVE"
LINUX_ROOT_ALIVE_FILE = "/root/.frost_alive"
LINUX_ROOT_ALIVE_RE = re.compile(
    r"^\r*" + LINUX_ROOT_ALIVE_TOKEN + r"=(\d+)[ \t\r]*\n", re.MULTILINE
)
LINUX_ROOT_SYNC_S = 120

# Covers a warm rebuild, the JTAG load of a ~78 MB DDR image (Debian's kernel
# plus its 42 MB initramfs, against 5 MB for the test one: about three minutes
# more than that image took), boot through the NFS mount to a login, systemd's
# startup, and the four programs the stage types, whose waits are all bounded.
DEFAULT_LINUX_TIMEOUT = 1200.0

# The FROST coremark port prints "Total 64-bit ticks : N" plus this formula;
# see the module docstring for why Iterations/Sec is not trusted instead.
COREMARK_TICKS_RE = re.compile(r"Total 64-bit ticks : (\d+)")


def check_score(
    board: str, key: str, measured: float, tolerance_pct: float
) -> tuple[bool, str]:
    """Judge a measured score against BASELINE_SCORES[board][key].

    Returns (ok, note). A missing (None) baseline reports the measured value
    and passes; a recorded baseline fails the check when the measured score
    is more than tolerance_pct percent below it.
    """
    if board_clock_freq(board)[1]:
        return True, (
            f"{key} score {measured:.2f} at the {CPU_CLK_ENV} clock override; "
            "baseline check skipped (scores are recorded at the rated clock)"
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
    """UART terminal predicates, verdict, and optional stimuli.

    Done predicates end capture; ``judge`` evaluates all post-sentinel output.
    ``stimuli`` are ``(trigger, text)`` pairs typed in order: each text is sent
    once when its trigger appears in the output captured after the previous
    stimulus was sent.
    """

    app: str
    success_done: Callable[[str], bool]
    failure_done: Callable[[str], bool]
    judge: Callable[[str], tuple[bool, str]]
    stimuli: tuple[tuple[str, str], ...] = ()


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


def build_stage(app: str, board: str, tolerance_pct: float) -> UartStage:
    """Build the UART rules for one phase-1 app."""
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
                * board_clock_freq(board)[0]
                / int(ticks_match.group(1))
            )
            return check_score(board, "coremark", score, tolerance_pct)

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


def nfs_interface(ip_spec: str) -> str:
    """Return the interface ``ip=`` names, or the default when it names none.

    The kernel's syntax is
    ``<client>:<server>:<gateway>:<netmask>:<hostname>:<device>:<autoconf>``.
    ``dhcp``, and a spec that leaves the device field empty, let the initramfs
    choose; the board has one NIC, so that is the kernel's first Ethernet name.
    """
    fields = ip_spec.split(":")
    if len(fields) >= 6 and fields[5]:
        return fields[5]
    return DEFAULT_NIC_INTERFACE


def linux_root_from_env(environment: Mapping[str, str] = os.environ) -> LinuxRoot:
    """Build the LinuxRoot from the four variables, or say which are unset.

    Nothing is defaulted: a wrong guess here boots a board against somebody
    else's export. ``FROST_LINUX_NFSROOT`` must read ``<server>:/<path>``, the
    form the packer and the initramfs both take.
    """
    missing = [name for name in LINUX_ROOT_ENV_VARS if not environment.get(name, "")]
    if missing:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {', '.join(missing)} unset. The {LINUX_STAGE} stage "
            "boots Debian from its NFS root over the NIC, and those values are "
            "site-specific. Set all of "
            f"{', '.join(LINUX_ROOT_ENV_VARS)} as docs/debian_nfsroot.md "
            '("Boot") describes.'
        )
    nfsroot = environment[LINUX_NFSROOT_ENV].strip()
    server, separator, path = nfsroot.partition(":")
    if not separator or not server or not path.startswith("/"):
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {LINUX_NFSROOT_ENV}={nfsroot!r} is not "
            "<server-ip>:/<path>, the form the bootargs and the initramfs's "
            "nfsmount take."
        )
    ip_spec = environment[LINUX_IP_ENV].strip()
    return LinuxRoot(
        nfsroot=nfsroot,
        server=server,
        export=Path(path),
        ip=ip_spec,
        interface=nfs_interface(ip_spec),
        kernel=Path(environment[LINUX_KERNEL_ENV].strip()),
        initrd=Path(environment[LINUX_INITRD_ENV].strip()),
    )


def linux_loader_env(root: LinuxRoot) -> dict[str, str]:
    """Return the FROST_LINUX_* variables the loader packs this root from."""
    return {
        LINUX_NFSROOT_ENV: root.nfsroot,
        LINUX_IP_ENV: root.ip,
        LINUX_KERNEL_ENV: str(root.kernel),
        LINUX_INITRD_ENV: str(root.initrd),
    }


# An ONC RPC NULL call for the NFS program, version 3: the question the
# initramfs's ``vers=3,tcp`` mount asks first. rpcinfo would answer it too, but
# the host that runs the loader is a Vivado host and need not carry the NFS
# client tools, and NULL touches no export, so no mount and no privileged
# source port are involved.
NFS_PROGRAM = 100003
NFS_VERSION = 3
NFS_PORT = 2049
RPC_XID = 0x4652_4F53  # "FROS"
RPC_REPLY = 1
RPC_MSG_ACCEPTED = 0
RPC_SUCCESS = 0
RPC_PROG_MISMATCH = 2
# An accepted reply is xid, message type, reply status, the verifier's flavor
# and length, and the acceptance status. A NULL reply is exactly that, so a
# record claiming to be much longer is not one and is reported rather than read:
# the bound is what keeps both the read and the decoding finite.
RPC_REPLY_HEAD = 24
RPC_REPLY_MAX = 128
RPC_LAST_FRAGMENT = 0x8000_0000
RPC_FRAGMENT_SIZE = 0x7FFF_FFFF


def _recv_exactly(sock: socket.socket, count: int, deadline: float) -> bytes:
    """Read up to ``count`` bytes until the peer closes or ``deadline`` passes.

    The deadline is the whole probe's, not each read's: a peer that answers one
    byte at a time just inside the socket timeout would otherwise keep the
    preflight waiting a byte at a time.
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
    """Return None when the server serves NFSv3 over TCP, else the reason.

    The reason is written for an operator: it says what answered and what to
    check, because a server that is down or NFSv4-only must not be mistaken for
    a board that will not boot.
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
    # One final fragment carrying at least an accepted reply's head is the only
    # shape a NULL reply takes; anything else is reported rather than decoded,
    # so a short or split record cannot become a traceback.
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
    # The verifier is opaque data, which XDR pads to a multiple of four; a
    # server that answers with AUTH_NONE sends none, but the padding is what
    # says where the acceptance status is either way.
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


# The two programs the stage types at the root shell. Buildroot builds them
# against musl and installs them in the test initramfs, so that image's copies
# cannot run on a glibc Debian root; the preflight cross-compiles these sources
# statically instead and installs them in the export. Building rather than
# requiring them keeps what the stage types in step with this checkout -- the
# same reason the linux_boot Makefile names these sources as prerequisites of
# the test initramfs -- and static linking is what lets frost_nettest run with
# the root's link down (see ``nettest_command``).
ROOT_PROGRAM_SRC = Path("linux/buildroot-external/package/frost-stress/src")
ROOT_PROGRAMS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("frost_stress", ("-DFROST_STRESS_MMU=1",)),
    ("frost_nettest", ()),
)
ROOT_PROGRAM_CFLAGS = ("-O2", "-static")
# Cross prefixes, in order: the one the Docker image sets, the one Buildroot's
# own build produced (this stage's loader builds it), then Debian's cross gcc.
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
        f"{', '.join(name for name, _ in ROOT_PROGRAMS)}. Tried "
        f"{', '.join(prefix + 'gcc' for prefix in candidates)}. Install one "
        f"(Debian: gcc-riscv64-linux-gnu), set {CROSS_COMPILE_ENV} to a prefix, "
        "or build Buildroot once (make -C sw/apps/linux_boot), whose own "
        "toolchain is the second candidate."
    )


def install_root_programs(repo: Path, export: Path, cross: str) -> str:
    """Build the two programs statically and install them in the export.

    Returns the note naming what was installed. The export tree belongs to
    root, so its ``usr/local/bin`` has to be writable by whoever runs the
    regression; each program is staged beside its target and renamed into
    place, so a board never sees a half-written one.
    """
    target = export / LINUX_ROOT_BIN.lstrip("/")
    if not target.is_dir():
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: {target} is not a directory. The stage installs "
            f"{' and '.join(name for name, _ in ROOT_PROGRAMS)} there, in root's "
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
        for name, extra in ROOT_PROGRAMS:
            built = Path(scratch) / name
            source = repo / ROOT_PROGRAM_SRC / f"{name}.c"
            command = [
                cross + "gcc",
                *ROOT_PROGRAM_CFLAGS,
                *extra,
                "-o",
                str(built),
                str(source),
            ]
            done = subprocess.run(command, capture_output=True, text=True)
            if done.returncode != 0:
                raise LinuxEnvironmentError(
                    f"{ENV_NOT_READY}: {' '.join(command)} exited "
                    f"{done.returncode}:\n{done.stderr.strip()[-1000:]}"
                )
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


# The kernel's own banner inside a flat Linux ``Image``: the same string the
# stage requires on the console, so the packed file can be checked against the
# pin before the load. The release is the field after ``Linux version``, and the
# trailing space is what ``KERNEL_BANNER`` matches on, so a truncated read at a
# chunk boundary does not match half a release.
KERNEL_BANNER_RE = re.compile(rb"Linux version (\d[\w.+~-]*) ")
KERNEL_SCAN_OVERLAP = 256


def kernel_image_release(image: Path, limit: int = 128 << 20) -> str | None:
    """Return the release in a flat Linux Image's banner, or None if it has none.

    A compressed image (Debian's ``vmlinuz-*``) carries no readable banner and
    returns None, as does anything that is not a kernel.
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
    """Note the NIC driver's module if the initramfs names it in the clear.

    initramfs-tools puts the already-compressed modules in an uncompressed cpio
    segment, so ``usr/lib/modules/<release>/updates/dkms/frost_net10g.ko.xz``
    usually appears as a plain member name; a compressed image hides it. Finding
    it is evidence, not finding it says nothing, so this never fails the
    preflight -- ``lsinitramfs`` in docs/debian_nfsroot.md step 3 is the check
    that can, and an initramfs without the driver mounts no root at all.
    """
    with initrd.open("rb") as handle:
        head = handle.read(limit)
    if DRIVER_MODULE.encode() in head:
        return [f"the initramfs names {DRIVER_MODULE}"]
    return []


def subnet_note(root: LinuxRoot) -> list[str]:
    """Note whether the export's server shares the board's subnet.

    It matters for one reason: frost_nettest takes the root's interface down,
    and the kernel restores that interface's connected route by itself but not a
    route through a gateway. A server on the board's own subnet therefore comes
    back on its own; one reached through the gateway may not, and the stage's
    liveness check is what would report it (``nettest_command``).
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
# prompt. The drop-in is docs/debian_nfsroot.md, "Configure the tree".
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
        # A commented-out drop-in configures nothing, and pasting one is the
        # likeliest way to have the option present but inactive.
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
    """Check the operator's NFS root and install the programs the stage types.

    Returns the notes to print. Every failure raises ``LinuxEnvironmentError``
    with a message that starts by saying the environment is not ready, so that
    a server that is down, an export that is not prepared, a kernel that is not
    the pinned release or a host with no cross compiler can never be read as an
    RTL regression.
    """
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
    notes.extend(initrd_driver_note(root.initrd))
    notes.extend(subnet_note(root))
    consoles = console_autologin_files(root.export)
    if not consoles:
        raise LinuxEnvironmentError(
            f"{ENV_NOT_READY}: no {CONSOLE_AUTOLOGIN} in the export's "
            f"{CONSOLE_UNIT} override. The stage logs in on the UART, and "
            "Debian's root has no usable password, so the console getty has to "
            "log root in by itself; add the drop-in from "
            'docs/debian_nfsroot.md, "Configure the tree".'
        )
    notes.append(f"console autologin from {consoles[0]}")
    notes.append(
        install_root_programs(
            repo, root.export, resolve_cross_compile(repo, environment)
        )
    )
    return notes


def nettest_command(interface: str) -> str:
    """Return the shell line that runs frost_nettest and gives the link back.

    The program takes the interface down, sets MTU 9000, drives the loopback and
    leaves the interface down with loopback off -- and on this root that
    interface carries the root filesystem, a hard mount, so the line around it
    does four things.

    It runs the program from a tmpfs copy: a page fault on its own text while
    the link is down would block until the link came back, and this program is
    what brings it back. It is statically linked, so there is no interpreter or
    library to fault in either.

    It disables IPv6 on the interface first. Debian's kernel builds IPv6 in, and
    the autoconfiguration frames it sends whenever an interface comes up return
    through the loopback and fail the program's idle checks; the packer's own
    bootargs carry ``ipv6.disable=1`` for exactly that reason, and an NFS root's
    do not, because the root is IPv4.

    It restores the MTU and flags it read first, and the IPv6 setting, through
    sysfs with shell built-ins, so nothing has to be read from the root or
    exec'd from it before the link is up again. The shell itself is still the
    login shell mapped from the root, which has run every command before this
    one, so its pages are resident; a reclaim under memory pressure could still
    leave it faulting on a dead mount, as could the bounded helper's own exec if
    the link never comes back, since an NFS open revalidates against the server.
    The stage then times out with the whole transcript rather than reporting
    anything about the RTL, which is the same evidence by a worse route.

    And it writes a file on the root and syncs, bounded, and prints the status:
    that is how the stage learns that the link, the route and the server all came
    back, rather than reporting a pass over a dead root, and it leaves the
    board's writes on the server for the next load.
    """
    sysfs = f"/sys/class/net/{interface}"
    ipv6 = f"/proc/sys/net/ipv6/conf/{interface}/disable_ipv6"
    return (
        f"m=$(cat {sysfs}/mtu); f=$(cat {sysfs}/flags); echo 1 > {ipv6}; "
        f"cp {LINUX_ROOT_BIN}/{LINUX_NET_COMMAND} {LINUX_TMPFS}/; "
        f"{LINUX_TMPFS}/{LINUX_NET_COMMAND}; "
        f"echo $m > {sysfs}/mtu; echo $f > {sysfs}/flags; echo 0 > {ipv6}; "
        f"timeout -k 5 {LINUX_ROOT_SYNC_S} sh -c "
        f'"echo frost > {LINUX_ROOT_ALIVE_FILE} && sync && '
        f'rm -f {LINUX_ROOT_ALIVE_FILE}"; '
        f"echo {LINUX_ROOT_ALIVE_TOKEN}=$?"
    )


def counter_values(serial_buf: str) -> dict[str, str]:
    """Return the fields of a passing ``frost_stress --counters`` line, by name.

    The line reads ``FROST_COUNTERS: scope=exec-child cycles=N instret=N time=N
    ipc_x1000=N verdict=PASS``; a run that could not read the counters prints
    ``counters=unavailable verdict=FAIL`` instead and matches nothing here, so
    ``LINUX_COUNTER_FAIL_RE`` is what ends the capture for it.
    """
    counts: dict[str, str] = {}
    for fields in LINUX_COUNTER_RE.findall(serial_buf):
        counts.update(field.split("=", 1) for field in fields.split())
    return counts


def systemd_state(serial_buf: str) -> str | None:
    """Return the last ``systemctl is-system-running`` state line, if any."""
    states = LINUX_SYSTEMD_STATE_RE.findall(serial_buf)
    return states[-1] if states else None


def root_alive_status(serial_buf: str) -> int | None:
    """Return the status of the bounded ``sync`` after frost_nettest, if printed.

    Zero means the interface came back up, the route and the server with it, and
    the board's writes reached the export; anything else means the root did not
    survive the loopback test, which is the NIC's own recovery path and part of
    what this stage is here to check.
    """
    matches = LINUX_ROOT_ALIVE_RE.findall(serial_buf)
    return int(matches[-1]) if matches else None


def root_mount_verdict(serial_buf: str, nfsroot: str) -> tuple[bool, str]:
    """Judge the ``findmnt`` line for ``/`` against the export that was packed.

    Only the real root can fail this: the initramfs mounted it over the NIC
    before Debian started, so the line proves the driver carried an NFSv3 mount
    of this export and that userspace is running from it.
    """
    match = LINUX_ROOT_MOUNT_RE.search(serial_buf)
    if match is None:
        return False, f"{LINUX_ROOT_MOUNT_COMMAND}: no nfs line for '/'"
    fstype, source, options = match.groups()
    want_server, _, want_path = nfsroot.partition(":")
    got_server, _, got_path = source.partition(":")
    if got_path.rstrip("/") != want_path.rstrip("/"):
        return False, (f"/ is {fstype} from {source}, not the packed export {nfsroot}")
    if got_server != want_server:
        # The path is this export, so the two name one server differently: a
        # hostname against the address the mount actually used, most likely.
        return False, (
            f"/ is {fstype} from {source}, and {LINUX_NFSROOT_ENV} names that "
            f"server {want_server}; give it as the address the mount shows"
        )
    if LINUX_ROOT_MOUNT_VERS not in options.split(","):
        return False, (
            f"/ is {fstype} from {source} without {LINUX_ROOT_MOUNT_VERS}: {options}"
        )
    return True, f"/ on {source} ({fstype},{options})"


def linux_stage(root: LinuxRoot) -> UartStage:
    """Build the linux_boot stage for Debian on ``root``, booted over the NIC.

    Before the login prompt the stage needs the pinned kernel's own banner and
    the NIC driver's probe line, which the initramfs's modprobe produces on the
    way to mounting the root. Then it logs in on the console and types four
    programs: ``findmnt``, whose line must show ``/`` mounted from this export
    over NFSv3; ``systemctl``, which must report a finished startup with no
    failed unit; the stress payload, whose pass token must follow the prompt;
    and ``frost_stress --counters``, which must report the ``exec-child`` scope
    and a nonzero count for every name in ``LINUX_COUNTER_EVENTS``. Last comes
    ``frost_nettest``, which needs its pass token and then the root back: that
    test takes the root's own link down, so the stage requires the bounded
    ``sync`` after it to report success (``nettest_command``). Any program's
    failure verdict, a systemd state other than ``running``, a root that does
    not come back, a trap, panic, ``Oops`` or ``BUG`` fails the stage and ends
    the capture rather than leaving it to the timeout.
    """
    failure_markers = LINUX_FAILURE_MARKERS + (LINUX_TOKEN_FAIL, LINUX_NET_TOKEN_FAIL)
    # Lines that must appear before the getty, each with the pattern that
    # requires it. Only the driver's own probe message remains: Debian's
    # initramfs runs no init script of this tree's, and everything else the
    # stage checks it now types itself.
    boot_lines = ((LINUX_DRIVER_LINE, re.compile(re.escape(LINUX_DRIVER_LINE))),)

    def lx_login(serial_buf: str) -> bool:
        """Return True once the kernel and login markers have been captured."""
        return all(marker in serial_buf for marker in LINUX_SUCCESS_MARKERS)

    def lx_reasons(serial_buf: str) -> list[str]:
        """Return every terminal failure the output shows, most specific first."""
        hit = [m for m in failure_markers if m in serial_buf]
        counter_fail = LINUX_COUNTER_FAIL_RE.search(serial_buf)
        if counter_fail:
            hit.append(counter_fail.group(0).strip())
        state = systemd_state(serial_buf)
        if state is not None and state != LINUX_SYSTEMD_RUNNING:
            hit.append(f"systemd is {state}, not {LINUX_SYSTEMD_RUNNING}")
        alive = root_alive_status(serial_buf)
        if alive is not None and alive != 0:
            hit.append(
                f"the root did not come back after {LINUX_NET_COMMAND}: "
                f"sync exited {alive}"
            )
        return hit

    def lx_success(raw_buf: str) -> bool:
        """Login, a running systemd, both counters, and frost_nettest's token."""
        serial_buf = console_text(raw_buf)
        if not lx_login(serial_buf):
            return False
        if systemd_state(serial_buf) != LINUX_SYSTEMD_RUNNING:
            return False
        if not set(counter_values(serial_buf)) >= set(LINUX_COUNTER_EVENTS):
            return False
        if LINUX_NET_TOKEN not in serial_buf:
            return False
        # The capture ends after the link is back, not at the pass token: the
        # test leaves the root's interface down, and the line that follows it
        # brings the link back and flushes.
        return root_alive_status(serial_buf) == 0

    def lx_failure(raw_buf: str) -> bool:
        """Return True on a crash marker, a failed verdict, or a bad systemd state."""
        return bool(lx_reasons(console_text(raw_buf)))

    def lx_judge(raw_buf: str) -> tuple[bool, str]:
        """Fail on a failure marker, else require every marker, line and count."""
        serial_buf = console_text(raw_buf)
        hit = lx_reasons(serial_buf)
        if hit:
            return False, f"failure marker: {', '.join(hit)}"
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
        if counts.get("scope") != LINUX_COUNTER_SCOPE:
            bad.append(f"scope: {counts.get('scope')} is not {LINUX_COUNTER_SCOPE}")
        for event in LINUX_COUNTER_EVENTS:
            count = counts.get(event)
            if count is None:
                bad.append(f"{event}: no {LINUX_COUNTER_LINE} count")
            elif not count.isdigit() or int(count) == 0:
                bad.append(f"{event}: {count}")
        if bad:
            return False, f"{LINUX_COUNTER_COMMAND}: " + "; ".join(bad)
        if LINUX_NET_TOKEN not in serial_buf:
            return False, f"{LINUX_NET_COMMAND}: no {LINUX_NET_TOKEN!r}"
        if root_alive_status(serial_buf) is None:
            return False, (
                f"{LINUX_NET_COMMAND}: no {LINUX_ROOT_ALIVE_TOKEN}= status, so "
                "nothing says the root came back with its link"
            )
        summary = " ".join(f"{event}={counts[event]}" for event in LINUX_COUNTER_EVENTS)
        return True, (
            f"{KERNEL_RELEASE}, NIC driver, {mount_note}, systemd "
            f"{LINUX_SYSTEMD_RUNNING}, login, stress token, counters "
            f"({LINUX_COUNTER_SCOPE}) {summary}, {LINUX_NET_COMMAND}, root alive"
        )

    return UartStage(
        LINUX_STAGE,
        success_done=lx_success,
        failure_done=lx_failure,
        judge=lx_judge,
        stimuli=(
            (LINUX_LOGIN_PROMPT, "root\r"),
            (LINUX_SHELL_PROMPT, LINUX_ROOT_MOUNT_COMMAND + "\r"),
            (LINUX_SHELL_PROMPT, LINUX_SYSTEMD_COMMAND + "\r"),
            (LINUX_SHELL_PROMPT, LINUX_STRESS_COMMAND + "\r"),
            (LINUX_SHELL_PROMPT, LINUX_COUNTER_COMMAND + "\r"),
            (LINUX_SHELL_PROMPT, nettest_command(root.interface) + "\r"),
        ),
    )


def send_uart_probe(serial_fd: int, text: str) -> None:
    """Pace bytes so ``uart_echo`` never overfills its RX FIFO."""
    for byte in text.encode():
        os.write(serial_fd, bytes([byte]))
        time.sleep(0.002)


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
    loader_done = False
    program_started = False
    stimuli_sent = 0
    stimulus_from = 0
    start = time.monotonic()
    deadline = start + timeout_s

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

        # The sentinel is the loader's final line, so both conditions are needed.
        if (
            loader_done
            and program_started
            and (stage.success_done(serial_buf) or stage.failure_done(serial_buf))
        ):
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
    elif stage.success_done(serial_buf) or stage.failure_done(serial_buf):
        ok, note = stage.judge(serial_buf)
        status = "PASS" if ok else "FAIL"
        if killed_loader:
            note = (note + "; " if note else "") + "loader hung and was killed"
    else:
        status = "TIMEOUT"
        note = f"no terminal UART output within {timeout_s:.0f}s"

    return {
        "stage": stage.app,
        "status": status,
        "elapsed": elapsed,
        "note": note,
        "loader_tail": list(loader_tail),
    }


def run_sweep_stage(
    repo: Path,
    board: str,
    serial: str,
    target: str,
    timeout_s: float,
    loader_extra: list[str],
    tolerance_pct: float,
) -> dict[str, Any]:
    """Run the -v0 CoreMark-PRO sweep and judge its status and mark.

    The sweep owns the UART and times each workload. It can raise this stage's
    base timeout to a workload-specific registry minimum. Its status covers all
    nine workloads; its printed official mark is checked against the board
    baseline.
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
            "note": f"sweep exited {returncode} -- not all nine workloads passed",
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
        board, "coremark_pro", float(score_match.group(1)), tolerance_pct
    )
    return {
        "stage": SWEEP_STAGE,
        "status": "PASS" if ok else "FAIL",
        "elapsed": elapsed,
        "note": note,
    }


# Apps that need a debugger driving them cannot pass unattended: debug_target
# spins until a debugger writes its flag, so a UART-judged run can only time
# out. They stay in VALID_APPS so load_software.py and the VS Code extension
# can load them; the regression leaves them out.
DEBUGGER_DRIVEN_APPS = frozenset({"debug_target"})

# Apps that need a link partner on the 10G port. nic_echo expects the frames
# the cocotb wire peer sends, which no hardware regression setup provides, so
# it cannot pass; nic_loopback is the NIC stage. They stay in VALID_APPS so
# load_software.py can load them; the regression neither runs nor accepts them
# until such a partner exists.
EXTERNAL_LINK_APPS = frozenset({"nic_echo"})

# Apps that assert the production netlist's absent profiling counters
# (PERF_COUNTERS=0, build.py's default at the rated clock). A
# functional-validation bitstream is built with --cpu-clock-div, which turns
# the counters on by default, so these cannot pass against one; main() drops
# them when FROST_CPU_CLK_HZ names such a build.
PERF_COUNTERS_ABSENT_APPS = frozenset({"perf_off_test"})


def regression_stages() -> list[str]:
    """Return every stage in canonical order: apps, the PRO sweep, then Linux.

    hello_world runs first as the bring-up smoke test, the remaining apps in
    VALID_APPS order, then the CoreMark-PRO sweep. linux_boot runs last because
    it is the longest, whole-system stage and should only run once everything
    else has passed. Debugger-driven apps (DEBUGGER_DRIVEN_APPS) and apps that
    need an external link (EXTERNAL_LINK_APPS) are excluded. Counters-absent
    apps (PERF_COUNTERS_ABSENT_APPS) stay in: they hold for the rated-clock
    bitstream, and main() drops them for a clock-override run.
    """
    phase1 = [
        app
        for app in VALID_APPS
        if app != LINUX_STAGE
        and app not in COREMARK_PRO_APP_NAMES
        and app not in DEBUGGER_DRIVEN_APPS
        and app not in EXTERNAL_LINK_APPS
    ]
    phase1.remove("hello_world")
    phase1.insert(0, "hello_world")
    return [*phase1, SWEEP_STAGE, LINUX_STAGE]


def main() -> int:
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
            "Base per-app timeout in seconds, build included; also forwarded "
            "to the sweep, where a workload minimum may raise it (default: "
            "per --board)"
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
            "raise it for a cold Buildroot first build or a cold Debian kernel "
            "fetch, a few minutes of downloads each)"
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
        "stages",
        nargs="*",
        help=(
            "Optional subset of stages to run, in canonical order (app names "
            f"plus '{SWEEP_STAGE}' and '{LINUX_STAGE}'; default: all)"
        ),
    )
    args = parser.parse_args()

    board = args.board
    target = args.target if args.target else DEFAULT_TARGETS[board]
    serial = args.serial if args.serial else DEFAULT_SERIALS[board]
    timeout = args.timeout if args.timeout is not None else DEFAULT_TIMEOUTS[board]

    all_stages = regression_stages()
    divided_clock = board_clock_freq(board)[1]
    if divided_clock:
        # --cpu-clock-div builds include the profiling counters by default.
        all_stages = [
            stage for stage in all_stages if stage not in PERF_COUNTERS_ABSENT_APPS
        ]

    if args.stages:
        requested = set(args.stages)
        excluded = sorted(requested & (DEBUGGER_DRIVEN_APPS | EXTERNAL_LINK_APPS))
        if excluded:
            parser.error(
                f"not a regression stage: {', '.join(excluded)} (debug_target needs "
                "a debugger; nic_echo needs a link partner sending the cocotb wire "
                "peer's frames; load_software.py can still run them)"
            )
        if divided_clock:
            counters_on = sorted(requested & PERF_COUNTERS_ABSENT_APPS)
            if counters_on:
                parser.error(
                    f"not a regression stage under {CPU_CLK_ENV}: "
                    f"{', '.join(counters_on)} requires the rated-clock netlist, "
                    "whose profiling counters are absent; a --cpu-clock-div "
                    "build includes them (see netlist_config.json)"
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

    holders = serial_holders(serial)
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

    # The NFS root the Linux stage boots is the operator's, so it is resolved
    # and checked before any stage runs: a whole regression should not spend an
    # hour on the board to discover that the export is not serving. Without
    # --keep-going nothing runs at all; with it the other stages still do, and
    # the summary carries the linux_boot stage as ENV_FAIL rather than FAIL.
    linux_root: LinuxRoot | None = None
    linux_env_error: str | None = None
    if LINUX_STAGE in selected:
        try:
            linux_root = linux_root_from_env()
            for note in linux_root_preflight(linux_root, args.repo):
                print(f"[hw_regression] Linux root: {note}", flush=True)
        except (LinuxEnvironmentError, OSError) as error:
            # An OSError here is the export or this host refusing a read or a
            # write -- a permission, a full filesystem, a server that went away
            # mid-check -- which is the environment just as much as the checks
            # that raise deliberately, and must not be a traceback.
            linux_env_error = (
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
            elif stage_name == SWEEP_STAGE:
                # Release the UART before the sweep requests exclusive access.
                if serial_fd is not None:
                    os.close(serial_fd)
                    serial_fd = None
                result = run_sweep_stage(
                    args.repo,
                    board,
                    serial,
                    target,
                    timeout,
                    args.loader_extra,
                    args.score_tolerance,
                )
            else:
                if serial_fd is None:
                    serial_fd = configure_serial(serial)
                loader_env = None
                if stage_name == LINUX_STAGE:
                    assert linux_root is not None
                    stage = linux_stage(linux_root)
                    stage_timeout = args.linux_timeout
                    loader_env = linux_loader_env(linux_root)
                else:
                    stage = build_stage(stage_name, board, args.score_tolerance)
                    stage_timeout = timeout
                result = run_uart_stage(
                    args.repo,
                    serial_fd,
                    board,
                    stage,
                    stage_timeout,
                    args.loader_extra,
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

            if result["status"] != "PASS" and not args.keep_going:
                break
    finally:
        if serial_fd is not None:
            os.close(serial_fd)

    skipped = selected[len(results) :]
    bad = [r for r in results if r["status"] != "PASS"]

    print(f"\nSUMMARY ({board})")
    name_width = max(len(r["stage"]) for r in results) if results else 12
    for r in results:
        note = f"  {r['note']}" if r["note"] else ""
        print(
            f"  {r['stage']:<{name_width}} {r['status']:>9} {r['elapsed']:>8.1f}s{note}"
        )
    if skipped:
        print(f"  skipped after failure: {', '.join(skipped)}")

    passed = len(results) - len(bad)
    verdict = "PASS" if not bad and not skipped else "FAIL"
    print(f"\nREGRESSION {verdict}: {passed}/{len(selected)} stages passed")
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
