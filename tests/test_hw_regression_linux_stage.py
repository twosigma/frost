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

"""Test console stages, Linux NFS-root preflight, and commands.

Synthetic Debian 13 transcripts follow docs/debian_nfsroot.md and retain
console CRLF pairs. Counter and findmnt output is constructed; captured board
transcripts live in tests/fixtures.

Preflight tests use temporary export trees, a stub NFSv3 RPC server, and a
stub cross compiler. The initramfs driver-version check uses stand-in
``unmkinitramfs`` and ``modinfo`` executables on PATH (plus one integration
test against the real tools when installed), and the debug_port stage uses
canned OpenOCD transcripts, a stand-in OpenOCD executable, and OpenOCD Jim Tcl
mocks. No board or NFS export is required.
"""

import dataclasses
import gzip
import importlib.util
import json
import os
import random
import re
import shutil
import signal
import socket
import stat
import struct
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
FPGA_DIR = REPO_ROOT / "fpga"
for extra in (
    FPGA_DIR,
    FPGA_DIR / "common",
    FPGA_DIR / "load_software",
    REPO_ROOT / "sw" / "apps",
    REPO_ROOT / "linux",
):
    if str(extra) not in sys.path:
        sys.path.insert(0, str(extra))

load_software = importlib.import_module("load_software")
sweep_coremark_pro = importlib.import_module("sweep_coremark_pro")
ddr_ecc_status = importlib.import_module("ddr_ecc.ddr_ecc_status")


def _load_hw_regression() -> ModuleType:
    """Import fpga/hw_regression.py by path (it is a script, not a package)."""
    spec = importlib.util.spec_from_file_location(
        "hw_regression", FPGA_DIR / "hw_regression.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


hw = _load_hw_regression()

# The site the transcript below comes from, in the docs' example addresses.
NFSROOT = "192.0.2.1:/srv/nfs/debian"
BOARD_IP = "192.0.2.2::192.0.2.1:255.255.255.0:frost:eth0:off"
ROOT = hw.LinuxRoot(
    nfsroot=NFSROOT,
    server="192.0.2.1",
    export=Path("/srv/nfs/debian"),
    ip=BOARD_IP,
    interface="eth0",
    kernel=Path(f"/srv/nfs/debian/boot/vmlinux-{hw.KERNEL_RELEASE}"),
    initrd=Path(f"/srv/nfs/debian/boot/initrd.img-{hw.KERNEL_RELEASE}"),
)

PROMPT = "root@frost:~# "
# systemd's main.c status_welcome inserts /etc/os-release's ANSI color
# between "Welcome to " and the pretty name. Match the name, also in /etc/issue.
SYSTEMD_GREETING = (
    "\r\r\nWelcome to \x1b[0;1;31mDebian GNU/Linux 13 (trixie)\x1b[0m!\r\r\n"
)
# Debian's kernel, its initramfs mounting the export over the NIC, systemd, and
# the console autologin the export configures (docs/debian_nfsroot.md).
BOOT_TO_LOGIN = (
    f"[    0.000000] {hw.KERNEL_BANNER}"
    "(debian-kernel@debian) (riscv64-linux-gnu-gcc-14 (Debian 14.2.0-19) "
    "14.2.0, GNU ld (GNU Binutils for Debian) 2.44) #1 SMP Debian "
    "7.3.4-1~bpo13+1 (2026-11-18)\r\r\n"
    '[    0.000000] Unknown kernel command line parameters "boot=nfs '
    f'nfsroot={NFSROOT},vers=3,tcp,hard ip={BOARD_IP}", will be passed to '
    "user space.\r\r\n"
    "[    9.512001] Freeing initrd memory: 42104K\r\r\n"
    "[   12.031002] Run /init as init process\r\r\n"
    "Loading, please wait...\r\r\n"
    "[   23.114003] frost_net10g: loading out-of-tree module taints kernel.\r\r\n"
    "[   23.114919] frost_net10g: module verification failed: signature and/or "
    "required key missing - tainting kernel\r\r\n"
    "[   23.220041] frost_net10g 40030000.ethernet eth0: "
    f"{hw.LINUX_DRIVER_LINE}4, MAC 02:11:22:33:44:55\r\r\n"
    "IP-Config: eth0 complete:\r\r\n"
    " device=eth0, hwaddr=02:11:22:33:44:55, ipaddr=192.0.2.2, "
    "mask=255.255.255.0, gw=192.0.2.1\r\r\n"
    "Begin: Running /scripts/nfs-bottom ... done.\r\r\n"
    "[   41.882003] VFS: Mounted root (nfs filesystem) on device 0:16.\r\r\n"
    "[   47.004112] systemd[1]: systemd 257.8-1 running in system mode\r\r\n"
    + SYSTEMD_GREETING
    + "[  OK  ] Reached target getty.target - Login Prompts.\r\r\n"
    "[  OK  ] Reached target multi-user.target - Multi-User System.\r\r\n"
    "\r\r\nDebian GNU/Linux 13 frost ttyS0\r\r\n\r\r\n"
    "login: "
)
# agetty --autologin prints its prompt with the user it logs in (util-linux
# agetty.c, "%s%s (automatic login)"), then login and bash run.
LOGIN_TO_SHELL = (
    "root (automatic login)\r\r\n"
    f"Linux frost {hw.KERNEL_RELEASE} #1 SMP Debian 7.3.4-1~bpo13+1 riscv64\r\r\n"
    "The programs included with the Debian GNU/Linux system are free "
    "software.\r\r\n"
    "Last login: Sun Sep 20 09:12:03 UTC 2026 on ttyS0\r\r\n" + PROMPT
)
MOUNT_ECHO = hw.LINUX_ROOT_MOUNT_COMMAND + "\r\r\n"
MOUNT_LINE = (
    f"nfs {NFSROOT} rw,relatime,vers=3,rsize=262144,wsize=262144,namlen=255,"
    "hard,nolock,proto=tcp,timeo=600,retrans=2,sec=sys,"
    f"mountaddr=192.0.2.1,mountvers=3,mountproto=tcp,addr=192.0.2.1\r\r\n{PROMPT}"
)
DRIVER_ECHO = hw.LINUX_DRIVER_VERSION_COMMAND + "\r\r\n"
DRIVER_LINE = (
    f"{hw.LINUX_DRIVER_VERSION_TOKEN}={hw.source_driver_version(REPO_ROOT)}"
    f"\r\r\n{PROMPT}"
)
SYSTEMD_ECHO = hw.LINUX_SYSTEMD_COMMAND + "\r\r\n"
SYSTEMD_RUNNING = f"state=running\r\r\n{PROMPT}"
SYSTEMD_DEGRADED = (
    "  serial-getty@ttyS0.service loaded failed failed Serial Getty on "
    f"ttyS0\r\r\nstate=degraded\r\r\n{PROMPT}"
)
STRESS_ECHO = hw.LINUX_STRESS_COMMAND + "\r\r\n"
STRESS_OUT = (
    "FROST_USERSPACE_STRESS: starting\r\r\n"
    "FROST_USERSPACE_STRESS: forks=2 pages=256 ticks=60 execs=12 futex=64 "
    "atomics=40000 cycles=4764560 instret=3473800 time=7499 ipc_x1000=729 "
    "verdict=PASS\r\r\n"
    f"{hw.LINUX_TOKEN}\r\r\n{PROMPT}"
)
COUNTER_ECHO = hw.LINUX_COUNTER_COMMAND + "\r\r\n"
COUNTER_LINE = (
    "FROST_COUNTERS: scope=exec-child cycles=4433680 instret=3275440 time=42321 "
    f"ipc_x1000=1012 verdict=PASS\r\r\n{PROMPT}"
)
MEMERR_ECHO = hw.LINUX_MEMERR_COMMAND + "\r\r\n"
MEMERR_SELFTEST_LINE = f"{hw.LINUX_MEMERR_SELFTEST_PASS}\r\r\n"
MEMERR_PROGRESS = "scrubbed=64 skipped=1 patrol=20,16760832 passes=0,1 restore=0"
MEMERR_LINE = (
    MEMERR_SELFTEST_LINE
    + f"{hw.LINUX_MEMERR_TOKEN} active=1 polls=4113,5342 ce=0 ue=0 rd=0 wr=0 "
    + f"{MEMERR_PROGRESS}\r\r\n{PROMPT}"
)
ISA_RUN_ID = "a1b2c3d4"
ISA_ABSENT_ECHO = hw.isa_probe_command(ISA_RUN_ID, "absent") + "\r\r\n"
ISA_ABSENT_LINES = (
    f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=discover verdict=PASS mode=absent\r\r\n"
    f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=illegal verdict=PASS sigill=1 pc_match=1 scalar_pre=1\r\r\n"
    f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=signal verdict=PASS rounds=4 end_magic=0 end_size=0\r\r\n"
    f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=ptrace verdict=PASS gpr_ok=1 einval=1\r\r\n"
    f"{hw.LINUX_ISA_PROBE_SUMMARY_TOKEN} id={ISA_RUN_ID} mode=absent passed=4 failed=0 verdict=PASS\r\r\n"
    f"{hw.LINUX_ISA_PROBE_EXIT_TOKEN} id={ISA_RUN_ID} rc=0\r\r\n{PROMPT}"
)
ISA_PRESENT_ECHO = hw.isa_probe_command(ISA_RUN_ID, "present") + "\r\r\n"
ISA_PRESENT_LINES = (
    f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=discover verdict=PASS mode=present vlenb=32 smoke=1\r\r\n"
    f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=switch verdict=PASS rounds_a=64 rounds_b=64 cpu=0\r\r\n"
    f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=signal verdict=PASS normal_rounds=8 alt_rounds=8 clobbers=16\r\r\n"
    f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=ptrace verdict=PASS inactive_einval=1 active_bytes=1064 setregset_ok=1 resumed_ok=1\r\r\n"
    f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=core verdict=PASS scalar_ok=1 note_bytes=1064 restored=1\r\r\n"
    f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=fork verdict=PASS ctrl_ok=1 inactive_einval=1 init_zero=1 isolated=1\r\r\n"
    f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=exec verdict=PASS on_ok=1 off_sigill=1\r\r\n"
    f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=first-use verdict=PASS traps_before=0 traps_phase1=1 traps_phase2=1 missed=0 init_zero=1\r\r\n"
    f"{hw.LINUX_ISA_PROBE_SUMMARY_TOKEN} id={ISA_RUN_ID} mode=present passed=8 failed=0 verdict=PASS\r\r\n"
    f"{hw.LINUX_ISA_PROBE_EXIT_TOKEN} id={ISA_RUN_ID} rc=0\r\r\n{PROMPT}"
)
SUPM_ECHO = hw.supm_probe_command(ISA_RUN_ID) + "\r\r\n"
SUPM_LINES = (
    f"{hw.LINUX_SUPM_PROBE_TOKEN} id={ISA_RUN_ID} case=discover verdict=PASS hwprobe=1 cpuinfo=1 init_ctrl=0\r\r\n"
    f"{hw.LINUX_SUPM_PROBE_TOKEN} id={ISA_RUN_ID} case=pmlen7 verdict=PASS pmlen=7 loads=8 stores=8\r\r\n"
    f"{hw.LINUX_SUPM_PROBE_TOKEN} id={ISA_RUN_ID} case=pmlen16 verdict=PASS pmlen=16 req8_pmlen=16 loads=8 stores=8 syscall=1 reject_pmlen32=1\r\r\n"
    f"{hw.LINUX_SUPM_PROBE_TOKEN} id={ISA_RUN_ID} case=disable-fault verdict=PASS ctrl_off=1 untagged_ok=1 load_sigsegv=1 store_sigsegv=1 store_unmodified=1\r\r\n"
    f"{hw.LINUX_SUPM_PROBE_SUMMARY_TOKEN} id={ISA_RUN_ID} passed=4 failed=0 verdict=PASS\r\r\n"
    "FROST_SUPM_PROBE_PASS\r\r\n"
    f"{hw.LINUX_SUPM_PROBE_EXIT_TOKEN} id={ISA_RUN_ID} rc=0\r\r\n{PROMPT}"
)
# What the program prints when perf_event_open on the child fails.
COUNTER_FAIL_LINE = (
    f"FROST_COUNTERS: scope=exec-child counters=unavailable verdict=FAIL\r\r\n{PROMPT}"
)
# frost_nettest's first and last lines around its result (trimmed). The typed
# line also copies it to tmpfs and restores the link, which print nothing.
NET_ECHO = hw.nettest_command(ROOT.interface) + "\r\r\n"
NET_START = (
    "FROST_NET_LOOPBACK: eth0: driver frost_net10g, address 02:11:22:33:44:55, "
    "loopback feature bit 42, run 5b3f1d07; down\r\r\n"
)
NET_PASS = (
    f"FROST_NET_LOOPBACK: eth0 down, loopback off\r\r\n{hw.LINUX_NET_TOKEN}\r\r\n"
)
# MTU, flags, and IPv6 restoration are silent. The bounded sync's status
# reports whether the root is reachable again.
NET_ALIVE = f"{hw.LINUX_ROOT_ALIVE_TOKEN}=0\r\r\n{PROMPT}"
NET_STRANDED = f"{hw.LINUX_ROOT_ALIVE_TOKEN}=124\r\r\n{PROMPT}"
NET_FAIL = (
    f"{hw.LINUX_NET_TOKEN_FAIL} burst: expected frame 250, received frame 251 "
    f"(lost or reordered)\r\r\n{PROMPT}"
)

TO_SHELL = BOOT_TO_LOGIN + LOGIN_TO_SHELL
TO_MOUNT = TO_SHELL + MOUNT_ECHO + MOUNT_LINE
TO_DRIVER = TO_MOUNT + DRIVER_ECHO + DRIVER_LINE
TO_SYSTEMD = TO_DRIVER + SYSTEMD_ECHO + SYSTEMD_RUNNING
TO_STRESS = TO_SYSTEMD + STRESS_ECHO + STRESS_OUT
COUNTER_TRANSCRIPT = TO_STRESS + COUNTER_ECHO + COUNTER_LINE
MEMERR_TRANSCRIPT = COUNTER_TRANSCRIPT + MEMERR_ECHO + MEMERR_LINE
ISA_TRANSCRIPT = MEMERR_TRANSCRIPT + ISA_ABSENT_ECHO + ISA_ABSENT_LINES
SUPM_TRANSCRIPT = ISA_TRANSCRIPT + SUPM_ECHO + SUPM_LINES
FULL_TRANSCRIPT = SUPM_TRANSCRIPT + NET_ECHO + NET_START + NET_PASS + NET_ALIVE


def stage() -> Any:
    """Build the Linux stage for the transcript's root."""
    return hw.linux_stage(ROOT, isa_run_id=ISA_RUN_ID)


# --- The judge and the capture predicates ------------------------------------


def test_stage_passes_on_the_whole_debian_transcript() -> None:
    """The full transcript passes and the note names every piece of evidence."""
    linux = stage()
    assert linux.success_done(FULL_TRANSCRIPT)
    assert not linux.failure_done(FULL_TRANSCRIPT)
    ok, note = linux.judge(FULL_TRANSCRIPT)
    assert ok, note
    assert hw.KERNEL_RELEASE in note
    assert f"NIC driver {hw.source_driver_version(REPO_ROOT)}" in note
    assert NFSROOT in note and "vers=3" in note
    assert "systemd running" in note
    assert "cycles=4433680" in note and "instret=3275440" in note
    assert "no memory errors (1229 ECC polls)" in note
    assert "supm probe (4/4 cases)" in note
    assert hw.LINUX_NET_COMMAND in note


@pytest.mark.parametrize(
    "transcript,expected",
    [
        (BOOT_TO_LOGIN, "no nfs line"),
        (TO_MOUNT, f"no {hw.LINUX_DRIVER_VERSION_TOKEN}= line"),
        (TO_DRIVER, "no 'running' line"),
        (TO_SYSTEMD, "no 'FROST_USERSPACE_STRESS_PASS' after the login"),
        (TO_STRESS, "no FROST_COUNTERS: count"),
        (COUNTER_TRANSCRIPT, f"no {hw.LINUX_MEMERR_TOKEN} line"),
        (MEMERR_TRANSCRIPT, f"no {hw.LINUX_ISA_PROBE_EXIT_TOKEN} line"),
        (ISA_TRANSCRIPT, f"no {hw.LINUX_SUPM_PROBE_EXIT_TOKEN} line"),
        (SUPM_TRANSCRIPT, "FROST_NET_LOOPBACK_PASS"),
        (
            SUPM_TRANSCRIPT + NET_ECHO + NET_START + NET_PASS,
            f"no {hw.LINUX_ROOT_ALIVE_TOKEN}= status",
        ),
    ],
    ids=[
        "at-login",
        "after-findmnt",
        "after-driver-version",
        "after-systemctl",
        "after-stress",
        "after-counters",
        "after-memerr",
        "after-isa-probe",
        "after-supm-probe",
        "after-nettest",
    ],
)
def test_no_prefix_of_the_run_is_terminal_or_passing(
    transcript: str, expected: str
) -> None:
    """Every step is required: no prefix ends the capture or passes the judge."""
    linux = stage()
    assert not linux.success_done(transcript)
    assert not linux.failure_done(transcript)
    ok, note = linux.judge(transcript)
    assert not ok and expected in note


def test_requires_the_drivers_probe_line_before_the_login_prompt() -> None:
    """Require the driver's probe line before login.

    Debian's initramfs loads the module quietly, so use the driver's message
    before the root mount to identify it.
    """
    linux = stage()
    transcript = FULL_TRANSCRIPT.replace(hw.LINUX_DRIVER_LINE, "FROST net10g, irq ")
    ok, note = linux.judge(transcript)
    assert not ok and "not printed before the login prompt" in note
    # A line after the login prompt does not satisfy it either.
    late = BOOT_TO_LOGIN.replace(hw.LINUX_DRIVER_LINE, "") + LOGIN_TO_SHELL
    late += hw.LINUX_DRIVER_LINE + "4, MAC 02:11:22:33:44:55\r\r\n"
    ok, note = linux.judge(late + MOUNT_ECHO + MOUNT_LINE)
    assert not ok and "not printed before the login prompt" in note


@pytest.mark.parametrize(
    "banner",
    ["Linux version 6.18.7 ", f"Linux version {hw.KERNEL_RELEASE}-debug "],
    ids=["other-kernel", "release-with-a-suffix"],
)
def test_requires_the_pinned_kernel_banner(banner: str) -> None:
    """Require the pinned kernel's exact release before loading and after boot.

    The banner marker's trailing space rejects suffixes such as -debug.
    """
    linux = stage()
    assert hw.KERNEL_BANNER == f"Linux version {hw.KERNEL_RELEASE} "
    transcript = FULL_TRANSCRIPT.replace(hw.KERNEL_BANNER, banner)
    assert not linux.success_done(transcript)
    ok, note = linux.judge(transcript)
    assert not ok and hw.KERNEL_BANNER in note


def test_requires_the_export_to_be_a_debian_root() -> None:
    """A root from another distribution fails, even though it boots this kernel."""
    linux = stage()
    transcript = FULL_TRANSCRIPT.replace(hw.DEBIAN_OS_NAME, "Alpine Linux")
    assert not linux.success_done(transcript)
    ok, note = linux.judge(transcript)
    assert not ok and hw.DEBIAN_OS_NAME in note


def test_the_coloured_systemd_greeting_still_matches() -> None:
    """Match the Debian name despite ANSI color between it and "Welcome to "."""
    assert "\x1b[" in SYSTEMD_GREETING
    assert "Welcome to Debian" not in FULL_TRANSCRIPT
    assert f"Welcome to \x1b[0;1;31m{hw.DEBIAN_OS_NAME}" in FULL_TRANSCRIPT
    assert stage().judge(FULL_TRANSCRIPT)[0]


@pytest.mark.parametrize(
    "line,expected",
    [
        (f"nfs4 {NFSROOT} rw,vers=4.2,hard,proto=tcp", "without vers=3"),
        (
            "nfs 198.51.100.9:/srv/nfs/other rw,vers=3,hard,proto=tcp",
            "not the packed export",
        ),
        ("ext4 /dev/vda1 rw,relatime", "no nfs line"),
    ],
    ids=["v4", "other-export", "not-nfs"],
)
def test_the_root_must_be_the_packed_export_over_nfsv3(
    line: str, expected: str
) -> None:
    """Only the real root can show this: / has to be this export, over NFSv3."""
    linux = stage()
    transcript = FULL_TRANSCRIPT.replace(MOUNT_LINE, f"{line}\r\r\n{PROMPT}")
    assert linux.success_done(transcript)  # the run finished ...
    ok, note = linux.judge(transcript)  # ... and the judge rejects the mount
    assert not ok and expected in note


def test_a_trailing_slash_on_the_export_still_matches() -> None:
    """The findmnt source and the packed export compare without a trailing /."""
    ok, note = hw.root_mount_verdict(MOUNT_LINE, NFSROOT + "/")
    assert ok, note


def test_the_same_export_under_another_server_name_says_so() -> None:
    """Report a server-name mismatch separately from an export-path mismatch.

    findmnt reports the server address used by the initramfs.
    """
    ok, note = hw.root_mount_verdict(MOUNT_LINE, "server.example:/srv/nfs/debian")
    assert not ok
    assert "names that server server.example" in note
    assert "address the mount shows" in note


def test_a_degraded_systemd_with_a_failed_service_is_terminal() -> None:
    """A failed service makes degraded terminal after the failed-unit listing."""
    linux = stage()
    transcript = TO_MOUNT + SYSTEMD_ECHO + SYSTEMD_DEGRADED
    assert linux.failure_done(transcript), "the stage would run to the timeout"
    assert not linux.success_done(transcript)
    ok, note = linux.judge(transcript)
    assert not ok and "systemd is degraded, not running" in note
    assert "serial-getty@ttyS0.service" in transcript


@pytest.mark.parametrize(
    "state,units,accepted",
    [
        ("running", [], True),
        ("degraded", [("session-1.scope", "resources")], True),
        (
            "degraded",
            [("session-1.scope", "resources"), ("session-23.scope", "resources")],
            True,
        ),
        (
            "degraded",
            [("session-1.scope", "resources"), ("dbus.service", "exit-code")],
            False,
        ),
        ("degraded", [("dbus.service", "resources")], False),
        ("degraded", [("session-1.scope", "signal")], False),
        ("degraded", [("session-1.scope", "")], False),
        ("degraded", [("session-other.scope", "resources")], False),
        ("degraded", [], False),
    ],
)
def test_systemd_command_and_stage_accept_only_session_resource_failures(
    state: str,
    units: list[tuple[str, str]],
    accepted: bool,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Exercise the shell queries and verdict with a controlled systemctl."""
    systemctl = tmp_path / "systemctl"
    listing = "\n".join(f"{unit} loaded failed failed Test unit" for unit, _ in units)
    cases = "\n".join(
        f'"show -p Result --value {unit}") echo "{result}" ;;' for unit, result in units
    )
    systemctl.write_text(
        '#!/bin/sh\ncase "$*" in\n'
        f'"--failed --no-legend --plain --no-pager") printf "%s\\n" "{listing}" ;;\n'
        f'"is-system-running"*) echo {state} ;;\n'
        f"{cases}\n*) exit 99 ;;\nesac\n"
    )
    systemctl.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tmp_path}:{os.environ['PATH']}")
    done = hw.subprocess.run(
        ["sh", "-c", hw.LINUX_SYSTEMD_COMMAND],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    for unit, result in units:
        assert f"failed_unit={unit} result={result}\n" in done.stdout
    transcript = FULL_TRANSCRIPT.replace(SYSTEMD_RUNNING, done.stdout + PROMPT)
    linux = stage()
    assert hw.systemd_state(transcript) == ("running" if accepted else state)
    assert linux.failure_done(transcript) is not accepted
    assert linux.success_done(transcript) is accepted
    ok, note = linux.judge(transcript)
    assert ok is accepted, note
    if accepted and units:
        assert "tolerated " in note and "resources" in note
        assert all(unit in note for unit, _ in units)
    else:
        assert "tolerated " not in note


@pytest.mark.parametrize(
    "listing",
    [
        "failed_unit=session-1.scope result=resources\nfailed_count=1\nfailed_list_status=1\n",
        "failed_unit=session-1.scope result=resources\nfailed_count=2\nfailed_list_status=0\n",
        "failed_unit=session-1.scope result=unknown\nfailed_count=1\nfailed_list_status=0\n",
        "failed_unit=session-1.scope result=resources\nfailed_count=1\n"
        "failed_list_status=0\nfailed_list_status=1\n",
        "failed_unit=session-1.scope result=resources\nfailed_count=1\n"
        "failed_list_status=0\nfailed_list_status=unknown\n",
        "failed_unit=session-1.scope result=resources\nfailed_count=1\n"
        "failed_count=unknown\nfailed_list_status=0\n",
        "failed_unit=session-1.scope result=resources\n",
    ],
)
def test_incomplete_systemd_failure_queries_do_not_tolerate_degraded(
    listing: str,
) -> None:
    """An error or incomplete list cannot establish the session-only exception."""
    transcript = f"systemd-check\n{listing}state=degraded\n"
    assert hw.systemd_state(transcript) == "degraded"
    assert hw.tolerated_systemd_units(transcript) == []


def test_truncated_systemd_unit_stream_cannot_hide_other_failures(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Require the producer's final sentinel before accepting its unit count."""
    systemctl = tmp_path / "systemctl"
    systemctl.write_text(
        '#!/bin/sh\ncase "$1" in\n'
        "--failed) echo 'session-1.scope loaded failed failed Test unit' ;;\n"
        "show) echo resources ;;\nis-system-running) echo degraded ;;\nesac\n"
    )
    systemctl.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tmp_path}:{os.environ['PATH']}")
    command = hw.LINUX_SYSTEMD_COMMAND.replace(
        '"$failed" systemd-list-end', '"$failed"'
    )
    assert command != hw.LINUX_SYSTEMD_COMMAND
    done = hw.subprocess.run(
        ["sh", "-c", command], check=True, capture_output=True, text=True, timeout=10
    )
    assert "failed_unit=session-1.scope result=resources\n" in done.stdout
    assert hw.systemd_state(done.stdout) == "degraded"


def test_systemd_session_results_belong_to_the_last_check() -> None:
    """An earlier tolerated scope cannot excuse a later degraded check."""
    transcript = (
        "systemd-check\nfailed_unit=session-1.scope result=resources\n"
        "failed_count=1\nfailed_list_status=0\nstate=degraded\n"
    )
    assert hw.systemd_state(transcript) == "running"
    for length in range(len("degraded") + 1):
        assert (
            hw.systemd_state(transcript[: -len("degraded\n")] + "degraded"[:length])
            is None
        )
    assert (
        hw.systemd_state(transcript + "systemd-check\nstate=degraded\n") == "degraded"
    )


def test_the_systemd_state_is_not_read_out_of_the_typed_command() -> None:
    """Read a state= result line, never the echoed command.

    The command echoes state=$(...), which must not match even when terminal
    wrapping splits it across lines.
    """
    assert "running" in hw.LINUX_SYSTEMD_COMMAND
    assert "state=$(" in hw.LINUX_SYSTEMD_COMMAND
    assert hw.systemd_state(TO_MOUNT + SYSTEMD_ECHO) is None
    for wrap in range(len(hw.LINUX_SYSTEMD_COMMAND)):
        command = hw.LINUX_SYSTEMD_COMMAND
        wrapped = f"{command[:wrap]}\r\r\n{command[wrap:]}\r\r\n"
        assert hw.systemd_state(TO_MOUNT + wrapped) is None, wrap
    assert hw.systemd_state(TO_MOUNT + SYSTEMD_ECHO + SYSTEMD_RUNNING) == "running"
    assert hw.systemd_state(TO_MOUNT + SYSTEMD_ECHO + SYSTEMD_DEGRADED) == "degraded"


@pytest.mark.parametrize(
    "line",
    ["state=running", f"{hw.LINUX_ROOT_ALIVE_TOKEN}=0", "nfs " + NFSROOT + " rw"],
)
def test_a_line_still_arriving_is_not_read_as_a_finished_one(line: str) -> None:
    """Wait for a newline before parsing mount, state, or root-alive results.

    The capture grows byte by byte. A $ regex also matches the buffer end and
    could misread a partial state=running as a failing state=r.
    """
    linux = stage()
    for length in range(1, len(line)):
        partial = TO_MOUNT + line[:length]
        assert hw.systemd_state(partial) is None, line[:length]
        assert hw.root_alive_status(partial) is None, line[:length]
        assert not hw.LINUX_ROOT_MOUNT_RE.search(SYSTEMD_ECHO + line[:length])
        assert not linux.failure_done(partial), line[:length]
    whole = TO_MOUNT + line + "\r\r\n"
    assert (
        hw.systemd_state(whole) is not None
        or hw.root_alive_status(whole) is not None
        or hw.LINUX_ROOT_MOUNT_RE.search(whole) is not None
    )


def test_the_stress_token_must_follow_the_login() -> None:
    """Require the stress token after login because the stage types the command.

    Buildroot's initramfs prints a token from inittab before getty; that token
    must not satisfy this stage.
    """
    linux = stage()
    before_prompt = BOOT_TO_LOGIN[: -len(hw.LINUX_LOGIN_PROMPT)]
    early = (
        f"{before_prompt}{hw.LINUX_TOKEN}\r\r\n{hw.LINUX_LOGIN_PROMPT}"
        + LOGIN_TO_SHELL
        + MOUNT_ECHO
        + MOUNT_LINE
        + DRIVER_ECHO
        + DRIVER_LINE
        + SYSTEMD_ECHO
        + SYSTEMD_RUNNING
        + COUNTER_ECHO
        + COUNTER_LINE
        + NET_ECHO
        + NET_START
        + NET_PASS
    )
    assert hw.LINUX_TOKEN in early
    ok, note = linux.judge(early)
    assert not ok and "after the login" in note


def test_fails_on_the_stress_fail_token() -> None:
    """The stress payload's FAIL token ends capture and fails the stage."""
    linux = stage()
    transcript = FULL_TRANSCRIPT.replace("STRESS_PASS", "STRESS_FAIL")
    assert linux.failure_done(transcript)
    ok, note = linux.judge(transcript)
    assert not ok and hw.LINUX_TOKEN_FAIL in note


def test_rejects_a_zero_count() -> None:
    """A counter line without a positive count fails the stage."""
    linux = stage()
    transcript = FULL_TRANSCRIPT.replace("cycles=4433680", "cycles=0")
    assert linux.success_done(transcript)  # a printed line ends capture ...
    ok, note = linux.judge(transcript)  # ... and the judge rejects it
    assert not ok and "cycles: 0" in note


def test_ends_the_capture_on_an_unavailable_counter_run() -> None:
    """End capture on counter failure, even though no success predicate matches."""
    linux = stage()
    transcript = TO_STRESS + COUNTER_ECHO + COUNTER_FAIL_LINE
    assert not linux.success_done(transcript)
    assert linux.failure_done(transcript), "the stage would run to the timeout"
    ok, note = linux.judge(transcript)
    assert not ok
    assert "counters=unavailable" in note and "verdict=FAIL" in note


def test_counters_are_not_matched_in_the_echo_or_the_stress_summary() -> None:
    """Use the counter command's result, not its echo or the stress summary counts."""
    assert hw.counter_values(TO_STRESS + COUNTER_ECHO) == {}
    assert "cycles=" in STRESS_OUT and "instret=" in STRESS_OUT


def test_nettest_fail_token_fails_the_stage_and_wins_over_pass() -> None:
    """frost_nettest's fail token ends capture and fails the stage, pass or not."""
    linux = stage()
    failed = MEMERR_TRANSCRIPT + NET_ECHO + NET_START + NET_FAIL
    assert linux.failure_done(failed)
    assert not linux.success_done(failed)
    ok, note = linux.judge(failed)
    assert not ok and hw.LINUX_NET_TOKEN_FAIL in note
    both = FULL_TRANSCRIPT + NET_FAIL
    assert linux.success_done(both) and linux.failure_done(both)
    ok, note = linux.judge(both)
    assert not ok and hw.LINUX_NET_TOKEN_FAIL in note


def test_kernel_panic_fails_the_stage() -> None:
    """A kernel panic fails the stage however far the boot got."""
    linux = stage()
    transcript = BOOT_TO_LOGIN + "[    1.0] Kernel panic - not syncing\r\r\n"
    assert linux.failure_done(transcript)
    assert not linux.judge(transcript)[0]


@pytest.mark.parametrize(
    "line,marker",
    [
        ("[   41.2] Oops - illegal instruction [#1]\r\r\n", "Oops"),
        (
            "[   41.2] BUG: scheduling while atomic: frost_nettest/97/0x00000101\r\r\n",
            "BUG:",
        ),
        (
            "[   12.345678] kernel BUG at lib/dynamic_queue_limits.c:99!\r\r\n"
            "[   12.345700] Kernel BUG [#1]\r\r\n",
            "Kernel BUG",
        ),
    ],
    ids=["oops", "bug", "kernel-bug"],
)
def test_kernel_oops_or_bug_fails_an_otherwise_passing_stage(
    line: str, marker: str
) -> None:
    """A kernel Oops, BUG: or Kernel BUG report fails an otherwise passing stage."""
    linux = stage()
    assert linux.judge(FULL_TRANSCRIPT)[0]
    transcript = FULL_TRANSCRIPT.replace(NET_START, NET_START + line)
    assert linux.success_done(transcript)
    assert linux.failure_done(transcript)
    ok, note = linux.judge(transcript)
    assert not ok and note == f"failure marker: {marker}"


@pytest.mark.parametrize(
    "line,expected",
    [
        (
            "active=0 polls=4113,5342 ce=0 ue=0 rd=0 wr=0",
            "the ECC reader is not active",
        ),
        ("active=1 polls=4113,4113 ce=0 ue=0 rd=0 wr=0", "ECC polls did not advance"),
        ("active=1 polls=4113,5342 ce=3 ue=0 rd=0 wr=0", "3 corrected errors"),
        ("active=1 polls=4113,5342 ce=0 ue=1 rd=2 wr=0", "1 uncorrectable errors"),
        ("active=1 polls=4113,5342 ce=0 ue=0 rd=0 wr=4", "4 DDR write error responses"),
    ],
    ids=["inactive", "not-polling", "corrected", "uncorrectable", "write-errors"],
)
def test_the_memory_error_readback_must_be_clean(line: str, expected: str) -> None:
    """An inactive or idle ECC reader, or any reported error, fails the stage."""
    transcript = (
        COUNTER_TRANSCRIPT
        + MEMERR_ECHO
        + MEMERR_SELFTEST_LINE
        + f"{hw.LINUX_MEMERR_TOKEN} {line} {MEMERR_PROGRESS}\r\r\n{PROMPT}"
        + ISA_ABSENT_ECHO
        + ISA_ABSENT_LINES
        + SUPM_ECHO
        + SUPM_LINES
        + NET_ECHO
        + NET_START
        + NET_PASS
        + NET_ALIVE
    )
    ok, note = stage().judge(transcript)
    assert not ok and expected in note


def test_an_unbound_memory_error_driver_prints_no_counts() -> None:
    """Without the driver's sysfs files the echoed line carries no digits."""
    unbound = (
        f"cat: {hw.LINUX_MEMERR_DEVICE}/ecc_polls: No such file or directory\r\r\n"
        f"{hw.LINUX_MEMERR_TOKEN} active= polls=, ce= ue= rd= wr=\r\r\n{PROMPT}"
    )
    transcript = (
        COUNTER_TRANSCRIPT + MEMERR_ECHO + unbound + NET_ECHO + NET_START + NET_PASS
    )
    ok, note = stage().judge(transcript + NET_ALIVE)
    assert not ok and f"no {hw.LINUX_MEMERR_TOKEN} line" in note
    # The echoed command is never mistaken for the output.
    assert hw.memerr_values(COUNTER_TRANSCRIPT + MEMERR_ECHO) is None


@pytest.mark.parametrize(
    "before,after,expected",
    [
        (MEMERR_SELFTEST_LINE, "", "no FROST_MEMERR_SELFTEST_PASS line"),
        (
            MEMERR_SELFTEST_LINE,
            "echo FROST_MEMERR_SELFTEST_PASS\r\n",
            "no FROST_MEMERR_SELFTEST_PASS line",
        ),
        ("scrubbed=64", "scrubbed=63", "scrub counters"),
        ("skipped=1", "skipped=0", "scrub counters"),
        ("skipped=1", "skipped=2", "scrub counters"),
        ("patrol=20,16760832", "patrol=20,20", "patrol lines did not advance"),
        ("patrol=20,16760832", "patrol=20,0", "patrol lines did not advance"),
        ("passes=0,1", "passes=0,0", "patrol did not complete a pass"),
        ("restore=0", "restore=1", "reloading the daily patrol failed"),
        ("rd=0 wr=0 scrubbed", "rd=1 wr=0 scrubbed", "1 DDR read error responses"),
    ],
)
def test_scrub_and_patrol_evidence_is_required(
    before: str, after: str, expected: str
) -> None:
    """Require a scrub pass, its counters, patrol progress, and a daily reload."""
    ok, note = stage().judge(FULL_TRANSCRIPT.replace(before, after))
    assert not ok and expected in note


def test_memerr_readback_parses_progress_and_rejects_an_old_selftest() -> None:
    """Only the self-test associated with the latest readback can validate it."""
    values = hw.memerr_values(MEMERR_ECHO + MEMERR_LINE)
    assert values is not None
    assert values["scrubbed"] == 64 and values["skipped"] == 1
    assert values["patrol_before"] == 20 and values["patrol_after"] == 16760832
    assert values["passes_before"] == 0 and values["passes_after"] == 1
    assert hw.memerr_problems(values) == []
    latest = hw.memerr_values(
        MEMERR_LINE + MEMERR_ECHO + MEMERR_LINE.replace(MEMERR_SELFTEST_LINE, "")
    )
    assert latest is not None
    assert "no FROST_MEMERR_SELFTEST_PASS line" in hw.memerr_problems(latest)


def test_vcu118_linux_checks_memory_errors_without_cpu_ecc_polling(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Require the selected VCU118 memory contract and repository's driver."""
    driver_version = "0.0-integration"
    driver_source = tmp_path / hw.DRIVER_SOURCE
    driver_source.parent.mkdir(parents=True)
    driver_source.write_text(f'MODULE_VERSION("{driver_version}");\n')
    seen = _stub_board(monkeypatch)
    monkeypatch.setattr(hw, "linux_root_from_env", lambda: ROOT)
    monkeypatch.setattr(hw, "linux_root_preflight", lambda *args: [])
    monkeypatch.setattr(
        sys,
        "argv",
        ["runner", "--repo", str(tmp_path), "--board", "vcu118", "linux_boot"],
    )
    assert hw.main() == 0
    linux = seen[hw.LINUX_STAGE]["stage"]
    run_id_match = re.search(r"--run-id ([0-9a-fA-F]+)", linux.stimuli[-2][1])
    assert run_id_match is not None
    stage_run_id = run_id_match.group(1)
    console = FULL_TRANSCRIPT.replace(ISA_RUN_ID, stage_run_id).replace(
        DRIVER_LINE, f"{hw.LINUX_DRIVER_VERSION_TOKEN}={driver_version}\r\r\n{PROMPT}"
    )
    transcript = console.replace("active=1 polls=4113,5342", "active=0 polls=0,0")
    ok, note = linux.judge(transcript)
    assert ok and "no DDR AXI error responses" in note
    assert f"NIC driver {driver_version}" in note
    assert linux.judge(console)[0] is False
    assert (
        hw.linux_stage(
            ROOT, driver_version=driver_version, isa_run_id=stage_run_id
        ).judge(transcript)[0]
        is False
    )
    ok, note = linux.judge(transcript.replace(driver_version, "0.0-stale"))
    assert not ok and "is version 0.0-stale" in note
    for before, after, reason in (
        ("active=0", "active=1", "unexpected CPU-visible ECC reader activity"),
        ("polls=0,0", "polls=1,0", "unexpected CPU-visible ECC reader activity"),
        ("polls=0,0", "polls=0,1", "unexpected CPU-visible ECC reader activity"),
        ("ce=0", "ce=1", "1 corrected errors"),
        ("ue=0", "ue=1", "1 uncorrectable errors"),
        ("rd=0", "rd=1", "1 DDR read error responses"),
        ("wr=0", "wr=1", "1 DDR write error responses"),
        (MEMERR_SELFTEST_LINE, "", "no FROST_MEMERR_SELFTEST_PASS line"),
        ("passes=0,1", "passes=0,0", "RAM patrol did not complete a pass"),
    ):
        ok, note = linux.judge(transcript.replace(before, after))
        assert not ok and reason in note


@pytest.mark.parametrize(
    "token", ["FROST_MEMERR_SELFTEST_FAIL", "FROST_MEMERR_LOAD_FAIL"]
)
def test_memerr_failures_end_capture_without_matching_the_command(token: str) -> None:
    """A load or self-test failure ends capture as soon as its line arrives."""
    assert not stage().failure_done(COUNTER_TRANSCRIPT + MEMERR_ECHO)
    transcript = COUNTER_TRANSCRIPT + MEMERR_ECHO + token + "\r\r\n"
    assert stage().failure_done(transcript)
    assert token in stage().judge(transcript)[1]


def test_the_memory_error_device_is_the_packers_node() -> None:
    """The sysfs path names the device the boot image's device tree describes."""
    packer_text = (
        REPO_ROOT / "linux/buildroot-external/board/frost/frost_boot_image.py"
    ).read_text()
    base = re.search(r"^MEMORY_ERROR_BASE = 0x([0-9A-Fa-f_]+)$", packer_text, re.M)
    assert base is not None
    address = int(base.group(1).replace("_", ""), 16)
    assert hw.LINUX_MEMERR_DEVICE.endswith(f"/{address:08x}.memory-controller")
    assert hw.LINUX_MEMERR_MODULE == f"{hw.LINUX_ROOT_BIN}/{hw.MEMERR.name}.ko"


# --- The typed commands ------------------------------------------------------


def test_stimuli_fire_in_order_after_their_triggers() -> None:
    """Each stimulus fires once, in order, only after the previous trigger."""
    linux = stage()
    assert [text for _, text in linux.stimuli] == [
        "root\r",
        hw.LINUX_ROOT_MOUNT_COMMAND + "\r",
        hw.LINUX_DRIVER_VERSION_COMMAND + "\r",
        hw.LINUX_SYSTEMD_COMMAND + "\r",
        hw.LINUX_STRESS_COMMAND + "\r",
        hw.LINUX_COUNTER_COMMAND + "\r",
        hw.LINUX_MEMERR_COMMAND + "\r",
        hw.isa_probe_command(ISA_RUN_ID, "absent") + "\r",
        hw.supm_probe_command(ISA_RUN_ID) + "\r",
        hw.nettest_command("eth0") + "\r",
    ]
    assert [trigger for trigger, _ in linux.stimuli[1:]] == [hw.LINUX_SHELL_PROMPT] * 9
    # Nothing to type before the prompt, even though "# " could occur in a log.
    assert hw.next_stimulus(linux, "[    0.1] # not a prompt\r\n", 0, 0) is None
    text, after = hw.next_stimulus(linux, BOOT_TO_LOGIN, 0, 0)
    assert text == "root\r"
    assert after == len(BOOT_TO_LOGIN)  # the trigger ends with the prompt's space
    # The shell prompt is only searched after the login trigger.
    assert hw.next_stimulus(linux, BOOT_TO_LOGIN, 1, after) is None
    sent = 1
    for transcript, expected in (
        (TO_SHELL, hw.LINUX_ROOT_MOUNT_COMMAND),
        (TO_MOUNT, hw.LINUX_DRIVER_VERSION_COMMAND),
        (TO_DRIVER, hw.LINUX_SYSTEMD_COMMAND),
        (TO_SYSTEMD, hw.LINUX_STRESS_COMMAND),
        (TO_STRESS, hw.LINUX_COUNTER_COMMAND),
        (COUNTER_TRANSCRIPT, hw.LINUX_MEMERR_COMMAND),
        (MEMERR_TRANSCRIPT, hw.isa_probe_command(ISA_RUN_ID, "absent")),
        (ISA_TRANSCRIPT, hw.supm_probe_command(ISA_RUN_ID)),
        (SUPM_TRANSCRIPT, hw.nettest_command("eth0")),
    ):
        # The prompt that took the previous command cannot fire this one.
        assert hw.next_stimulus(linux, transcript[: -len(PROMPT)], sent, after) is None
        typed, after = hw.next_stimulus(linux, transcript, sent, after)
        assert typed == expected + "\r"
        assert after == len(transcript)
        sent += 1
    assert hw.next_stimulus(linux, FULL_TRANSCRIPT, sent, after) is None


def test_the_autologin_stray_command_does_not_break_the_chain() -> None:
    """Autologin may pass the typed root answer to bash as a stray command.

    Its extra prompt may trigger the next stimulus early, but terminal input
    still queues in order. Every stimulus must fire once, in order.
    """
    linux = stage()
    stray = f"-bash: root: command not found\r\r\n{PROMPT}"
    boot = BOOT_TO_LOGIN + LOGIN_TO_SHELL + stray
    sent, after = 0, 0
    fired = []
    for transcript in (
        BOOT_TO_LOGIN,
        boot,
        boot,  # the stray command's own prompt fires the next stimulus early
        boot + MOUNT_ECHO + MOUNT_LINE,
        boot + MOUNT_ECHO + MOUNT_LINE + DRIVER_ECHO + DRIVER_LINE,
        boot
        + MOUNT_ECHO
        + MOUNT_LINE
        + DRIVER_ECHO
        + DRIVER_LINE
        + SYSTEMD_ECHO
        + SYSTEMD_RUNNING,
        boot
        + MOUNT_ECHO
        + MOUNT_LINE
        + DRIVER_ECHO
        + DRIVER_LINE
        + SYSTEMD_ECHO
        + SYSTEMD_RUNNING
        + STRESS_ECHO
        + STRESS_OUT,
        boot
        + MOUNT_ECHO
        + MOUNT_LINE
        + DRIVER_ECHO
        + DRIVER_LINE
        + SYSTEMD_ECHO
        + SYSTEMD_RUNNING
        + STRESS_ECHO
        + STRESS_OUT
        + COUNTER_ECHO
        + COUNTER_LINE,
        boot
        + MOUNT_ECHO
        + MOUNT_LINE
        + DRIVER_ECHO
        + DRIVER_LINE
        + SYSTEMD_ECHO
        + SYSTEMD_RUNNING
        + STRESS_ECHO
        + STRESS_OUT
        + COUNTER_ECHO
        + COUNTER_LINE
        + MEMERR_ECHO
        + MEMERR_LINE,
        boot
        + MOUNT_ECHO
        + MOUNT_LINE
        + DRIVER_ECHO
        + DRIVER_LINE
        + SYSTEMD_ECHO
        + SYSTEMD_RUNNING
        + STRESS_ECHO
        + STRESS_OUT
        + COUNTER_ECHO
        + COUNTER_LINE
        + MEMERR_ECHO
        + MEMERR_LINE
        + ISA_ABSENT_ECHO
        + ISA_ABSENT_LINES,
    ):
        pending = hw.next_stimulus(linux, transcript, sent, after)
        assert pending is not None, sent
        text, after = pending
        fired.append(text)
        sent += 1
    assert fired == [text for _, text in linux.stimuli]
    assert hw.next_stimulus(linux, boot + FULL_TRANSCRIPT, sent, after) is None


def test_the_typed_programs_are_named_by_absolute_path() -> None:
    """Use installed absolute paths because the payload's execv does not search PATH."""
    assert hw.LINUX_ROOT_BIN == "/usr/local/bin"
    assert hw.LINUX_STRESS_COMMAND.startswith(f"{hw.LINUX_ROOT_BIN}/frost_stress ")
    assert hw.LINUX_COUNTER_COMMAND.startswith(f"{hw.LINUX_ROOT_BIN}/frost_stress ")
    assert f"{hw.LINUX_ROOT_BIN}/{hw.LINUX_NET_COMMAND}" in hw.nettest_command("eth0")


def test_nettest_runs_from_tmpfs_and_gives_the_roots_link_back() -> None:
    """Run frost_nettest from tmpfs while it takes the NFS-root interface down.

    Disable IPv6 so looped-back autoconfiguration traffic cannot fail idle
    checks. Open restoration files before the test and write them through
    descriptors so recovery does not traverse the disconnected NFS root.
    A bounded sync checks that the root is reachable again.
    """
    command = hw.nettest_command("enp1s0")
    sysfs = "/sys/class/net/enp1s0"
    ipv6 = "/proc/sys/net/ipv6/conf/enp1s0/disable_ipv6"
    run_at = command.index(f"{hw.LINUX_TMPFS}/frost_nettest enp1s0;")
    assert f"cp {hw.LINUX_ROOT_BIN}/frost_nettest {hw.LINUX_TMPFS}/" in command
    assert command.index(f"cat {sysfs}/mtu") < run_at
    assert command.index(f"cat {sysfs}/flags") < run_at
    assert command.index(f"echo 1 > {ipv6}") < run_at
    assert "{ if echo 2 > /proc/sys/vm/drop_caches; then " in command[:run_at]
    assert (
        f"FROST_NETTEST_EXPIRE_NFS_CACHE=1 {hw.LINUX_TMPFS}/frost_nettest enp1s0;"
        in command
    )
    assert command.index("echo $m >&3") > run_at
    assert command.index("echo $f >&4") > command.index("echo $m >&3")
    assert command.index("echo 0 >&5") > run_at
    assert f"}} 3> {sysfs}/mtu 4> {sysfs}/flags 5> {ipv6}; " in command
    # The liveness step creates a file, which is a round trip to the server,
    # where a sync over a clean tree would return without one.
    assert command.endswith(f"; echo {hw.LINUX_ROOT_ALIVE_TOKEN}=$?")
    assert f"timeout -k 5 {hw.LINUX_ROOT_SYNC_S} sh -c " in command
    assert f"echo frost > {hw.LINUX_ROOT_ALIVE_FILE} && sync" in command
    assert f"rm -f {hw.LINUX_ROOT_ALIVE_FILE}" in command
    assert command.index("timeout -k 5") > run_at
    # Run every restore step even if the test fails. Only the liveness
    # command uses &&, preserving its first failure status.
    assert " && " not in command[: command.index("timeout -k 5")]


def test_cache_drop_failure_skips_nettest_and_restores_the_interface(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A failed cache drop cannot pass through a stale or passing test binary."""
    sysfs = tmp_path / "sysfs"
    sysfs.mkdir()
    (sysfs / "mtu").write_text("1500\n")
    (sysfs / "flags").write_text("0x1003\n")
    ipv6 = tmp_path / "disable_ipv6"
    ipv6.write_text("0\n")
    drop = tmp_path / "drop_caches"
    drop.mkdir()
    source = tmp_path / "bin"
    target = tmp_path / "shm"
    source.mkdir()
    target.mkdir()
    program = source / "frost_nettest"
    program.write_text(f"#!/bin/sh\necho {hw.LINUX_NET_TOKEN}\n")
    program.chmod(0o755)
    timeout = source / "timeout"
    timeout.write_text("#!/bin/sh\nexit 0\n")
    timeout.chmod(0o755)
    monkeypatch.setenv("PATH", f"{source}:{os.environ['PATH']}")
    monkeypatch.setattr(hw, "LINUX_ROOT_BIN", str(source))
    monkeypatch.setattr(hw, "LINUX_TMPFS", str(target))
    command = (
        hw.nettest_command("eth0")
        .replace("/sys/class/net/eth0", str(sysfs))
        .replace("/proc/sys/net/ipv6/conf/eth0/disable_ipv6", str(ipv6))
        .replace("/proc/sys/vm/drop_caches", str(drop))
    )
    assert hw.LINUX_NET_TOKEN_FAIL not in command
    done = hw.subprocess.run(
        ["sh", "-c", command], check=True, capture_output=True, text=True, timeout=10
    )
    assert hw.LINUX_NET_TOKEN_FAIL + " drop_caches\n" in done.stdout
    assert hw.LINUX_NET_TOKEN not in done.stdout
    assert (sysfs / "mtu").read_text() == "1500\n"
    assert (sysfs / "flags").read_text() == "0x1003\n"
    assert ipv6.read_text() == "0\n"
    assert stage().failure_done(done.stdout)


def test_a_root_that_does_not_come_back_is_a_failure_not_a_pass() -> None:
    """Require root liveness after the nettest pass token.

    The token arrives with the interface down; it cannot confirm link, route,
    or server recovery.
    """
    linux = stage()
    stranded = MEMERR_TRANSCRIPT + NET_ECHO + NET_START + NET_PASS + NET_STRANDED
    assert not linux.success_done(stranded)
    assert linux.failure_done(stranded), "the stage would run to the timeout"
    ok, note = linux.judge(stranded)
    assert not ok and "did not come back" in note and "sync exited 124" in note
    assert hw.root_alive_status(stranded) == 124
    assert hw.root_alive_status(FULL_TRANSCRIPT) == 0


def test_the_liveness_status_is_not_read_out_of_the_typed_command() -> None:
    """The echo carries ``=$?``, so only the shell's own line can satisfy it."""
    assert f"{hw.LINUX_ROOT_ALIVE_TOKEN}=$?" in NET_ECHO
    assert hw.root_alive_status(COUNTER_TRANSCRIPT + NET_ECHO) is None
    for wrap in range(len(NET_ECHO)):
        wrapped = f"{NET_ECHO[:wrap]}\r\r\n{NET_ECHO[wrap:]}"
        assert hw.root_alive_status(COUNTER_TRANSCRIPT + wrapped) is None, wrap


@pytest.mark.parametrize(
    "ip_spec,interface",
    [
        (BOARD_IP, "eth0"),
        ("192.0.2.2::192.0.2.1:255.255.255.0:frost:enp1s0:off", "enp1s0"),
        ("dhcp", "eth0"),
        ("192.0.2.2::192.0.2.1:255.255.255.0:frost::off", "eth0"),
    ],
    ids=["docs-example", "named-device", "dhcp", "empty-device"],
)
def test_the_restored_interface_is_the_one_ip_names(
    ip_spec: str, interface: str
) -> None:
    """The stage restores the device ``ip=`` configures, not a hardcoded name."""
    assert hw.nfs_interface(ip_spec) == interface


# --- The environment and the preflight ---------------------------------------


def _no_site_values(monkeypatch: pytest.MonkeyPatch) -> None:
    """Unset site values and ignore any developer fpga/site.env.

    Missing-environment tests must behave the same on developer machines and CI.
    """
    for name in hw.LINUX_ROOT_ENV_VARS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(hw, "SITE_ENV_FILE", Path("/nonexistent/site.env"))


def test_only_the_site_variables_are_required_and_are_named_when_unset() -> None:
    """Name missing NFS-root and IP settings; never guess another site's export."""
    with pytest.raises(hw.LinuxEnvironmentError) as unset:
        hw.linux_root_from_env({}, site={})
    message = str(unset.value)
    assert message.startswith(hw.ENV_NOT_READY)
    for name in hw.LINUX_ROOT_ENV_VARS:
        assert name in message
    assert hw.SITE_ENV_FILE.name in message
    full = {
        hw.LINUX_NFSROOT_ENV: NFSROOT,
        hw.LINUX_IP_ENV: BOARD_IP,
        hw.LINUX_KERNEL_ENV: str(ROOT.kernel),
        hw.LINUX_INITRD_ENV: str(ROOT.initrd),
    }
    for name in hw.LINUX_ROOT_ENV_VARS:
        one_missing = dict(full)
        del one_missing[name]
        with pytest.raises(hw.LinuxEnvironmentError, match=name):
            hw.linux_root_from_env(one_missing, site={})
    assert hw.linux_root_from_env(full, site={}) == ROOT
    assert hw.linux_loader_env(ROOT) == full


def test_the_kernel_and_initramfs_are_derived_when_unset() -> None:
    """Neither is a site fact: the release is pinned and the export is named."""
    site_only = {hw.LINUX_NFSROOT_ENV: NFSROOT, hw.LINUX_IP_ENV: BOARD_IP}
    derived = hw.linux_root_from_env(site_only, site={})
    # The pinned release's own image, at the path debian_kernel.py computes.
    assert derived.kernel == hw.kernel_image()
    assert hw.KERNEL_RELEASE in str(derived.kernel)
    # That release's initramfs, inside the export just named.
    assert derived.initrd == derived.export / "boot" / f"initrd.img-{hw.KERNEL_RELEASE}"
    # Both stay overridable, which is how a replacement kernel is tested.
    overridden = hw.linux_root_from_env(
        {
            **site_only,
            hw.LINUX_KERNEL_ENV: "/elsewhere/vmlinux",
            hw.LINUX_INITRD_ENV: "/elsewhere/initrd",
        },
        site={},
    )
    assert overridden.kernel == Path("/elsewhere/vmlinux")
    assert overridden.initrd == Path("/elsewhere/initrd")


def test_the_site_file_supplies_what_the_environment_does_not() -> None:
    """A lab states its two values once; the environment still wins."""
    site = {hw.LINUX_NFSROOT_ENV: NFSROOT, hw.LINUX_IP_ENV: BOARD_IP}
    assert hw.linux_root_from_env({}, site=site).nfsroot == NFSROOT
    other = "198.51.100.9:/srv/other"
    overridden = hw.linux_root_from_env({hw.LINUX_NFSROOT_ENV: other}, site=site)
    assert overridden.nfsroot == other
    assert overridden.ip == BOARD_IP


def test_the_site_file_is_parsed_and_ignores_what_it_should(tmp_path: Any) -> None:
    """Comments, blanks and stray names are skipped; quotes are stripped."""
    path = tmp_path / "site.env"
    path.write_text(
        "# a comment\n"
        "\n"
        f'{hw.LINUX_NFSROOT_ENV}="{NFSROOT}"\n'
        f"{hw.LINUX_IP_ENV}={BOARD_IP}\n"
        "PATH=/should/not/be/taken\n"
        "malformed line without an equals\n",
        encoding="utf-8",
    )
    values = hw.read_site_env(path)
    assert values == {hw.LINUX_NFSROOT_ENV: NFSROOT, hw.LINUX_IP_ENV: BOARD_IP}
    # A file that is not there is not an error: most runs do not need one.
    assert hw.read_site_env(tmp_path / "absent.env") == {}


@pytest.mark.parametrize(
    "nfsroot",
    ["/srv/nfs/debian", "192.0.2.1:srv/nfs/debian", "192.0.2.1:", ":/srv/nfs/debian"],
    ids=["no-server", "relative-path", "no-path", "no-address"],
)
def test_the_export_must_be_server_and_absolute_path(nfsroot: str) -> None:
    """The packer and the initramfs both take ``<server-ip>:/<path>``."""
    environment = {
        hw.LINUX_NFSROOT_ENV: nfsroot,
        hw.LINUX_IP_ENV: BOARD_IP,
        hw.LINUX_KERNEL_ENV: str(ROOT.kernel),
        hw.LINUX_INITRD_ENV: str(ROOT.initrd),
    }
    with pytest.raises(hw.LinuxEnvironmentError, match="is not <server-ip>"):
        hw.linux_root_from_env(environment)


def _rpc_reply(xid: bytes, accept_stat: int) -> bytes:
    """Build an accepted ONC RPC reply carrying ``accept_stat``."""
    body = xid + struct.pack(
        ">5I",
        hw.RPC_REPLY,
        hw.RPC_MSG_ACCEPTED,
        0,  # verifier: AUTH_NONE ...
        0,  # ... of length 0
        accept_stat,
    )
    return struct.pack(">I", 0x8000_0000 | len(body)) + body


def _stub_rpc_server(accept_stat: int | None) -> tuple[str, int, threading.Thread]:
    """Serve one RPC reply on localhost; ``None`` closes without answering."""
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    host, port = listener.getsockname()

    def serve() -> None:
        """Answer one connection, then close both sockets."""
        with listener:
            connection, _ = listener.accept()
            with connection:
                request = connection.recv(4096)
                if accept_stat is not None:
                    connection.sendall(_rpc_reply(request[4:8], accept_stat))

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    return host, port, thread


def test_the_nfsv3_probe_accepts_a_server_that_answers() -> None:
    """A NULL reply of SUCCESS for program 100003 version 3 is the whole test."""
    host, port, thread = _stub_rpc_server(hw.RPC_SUCCESS)
    assert hw.probe_nfs3_tcp(host, port, timeout_s=5.0) is None
    thread.join(timeout=5)


@pytest.mark.parametrize(
    "accept_stat,expected",
    [
        (hw.RPC_PROG_MISMATCH, "not version 3"),
        (1, "accept_stat 1"),
        (None, "answered no NFSv3 NULL call"),
    ],
    ids=["v4-only", "refused", "silent"],
)
def test_the_nfsv3_probe_explains_what_the_server_said(
    accept_stat: int | None, expected: str
) -> None:
    """An NFSv4-only or silent server gets an operator-readable reason."""
    host, port, thread = _stub_rpc_server(accept_stat)
    reason = hw.probe_nfs3_tcp(host, port, timeout_s=5.0)
    assert reason is not None and expected in reason
    thread.join(timeout=5)


@pytest.mark.parametrize(
    "reply,expected",
    [
        (struct.pack(">I", 0x8000_0000 | 12) + struct.pack(">3I", 0, 1, 0), "12 bytes"),
        (
            struct.pack(">I", 24) + struct.pack(">6I", hw.RPC_XID, 1, 0, 0, 0, 0),
            "continued record",
        ),
        (
            struct.pack(">I", 0x8000_0000 | 24)
            + struct.pack(">6I", 0xDEADBEEF, 1, 0, 0, 0, 0),
            "another call",
        ),
        (
            struct.pack(">I", 0x8000_0000 | 28)
            + struct.pack(">3I", hw.RPC_XID, 1, 0)
            + struct.pack(">I", 0)
            + struct.pack(">I", 1)
            + b"X\0\0\0"
            + struct.pack(">I", hw.RPC_PROG_MISMATCH),
            "not version 3",
        ),
        (
            struct.pack(">I", 0x8000_0000 | 28)
            + struct.pack(">6I", hw.RPC_XID, 1, 0, 0, 0, 0),
            "24 bytes of a 28-byte",
        ),
        (
            struct.pack(">I", 0x8000_0000 | 65536)
            + struct.pack(">6I", hw.RPC_XID, 1, 0, 0, 0, 0)
            + b"\0" * 1000,
            "65536-byte",
        ),
    ],
    ids=[
        "short-record",
        "split-record",
        "wrong-xid",
        "padded-verifier",
        "under-its-marker",
        "oversized-marker",
    ],
)
def test_the_nfsv3_probe_decodes_a_reply_without_trusting_it(
    reply: bytes, expected: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Reject malformed, split, or mismatched replies without a traceback.

    Validate field bounds, XID, and final-fragment status, accounting for
    verifier padding, before using a reply from port 2049.
    """

    class Stub:
        """Hand the probe a canned reply through the socket API it uses."""

        def __init__(self, payload: bytes) -> None:
            self.payload = payload

        def __enter__(self) -> "Stub":
            return self

        def __exit__(self, *args: object) -> None:
            return None

        def settimeout(self, timeout: float) -> None:
            return None

        def sendall(self, data: bytes) -> None:
            return None

        def recv(self, count: int) -> bytes:
            head, self.payload = self.payload[:count], self.payload[count:]
            return head

    monkeypatch.setattr(hw.socket, "create_connection", lambda *a, **k: Stub(reply))
    reason = hw.probe_nfs3_tcp("stub")
    assert reason is not None and expected in reason


def test_the_nfsv3_probe_reports_a_server_that_is_not_there() -> None:
    """A closed port is the ordinary 'the server is down' case."""
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    _, port = listener.getsockname()
    listener.close()
    reason = hw.probe_nfs3_tcp("127.0.0.1", port, timeout_s=2.0)
    assert reason is not None and "did not answer" in reason


MODULE_PATH = "usr/lib/modules/6.12/updates/dkms/frost_net10g.ko"


def _driver_version() -> str:
    """Return the driver version this tree builds."""
    return hw.source_driver_version(REPO_ROOT)


def _install_initrd_tools(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    *,
    files: dict[str, str] | None = None,
    symlinks: dict[str, str] | None = None,
    dirs: dict[str, int] | None = None,
    unmk_exit: int = 0,
    unmk_stderr: bytes = b"",
    unmk_hang: bool = False,
    unmk_present: bool = True,
    unmk_enoexec: bool = False,
    modinfo_versions: dict[str, str] | None = None,
    modinfo_stdout: bytes | None = None,
    modinfo_stderr: bytes = b"",
    modinfo_exit: int = 0,
    modinfo_hang: bool = False,
    modinfo_present: bool = True,
    modinfo_enoexec: bool = False,
) -> Path:
    """Put stand-in ``unmkinitramfs`` and ``modinfo`` executables on PATH.

    Each tool records its command-line arguments as JSON lines in
    ``tool_dir/<tool>_calls.jsonl``. ``PATH`` is set to ``tool_dir`` alone so
    host binaries cannot mask missing-tool tests.
    """
    tool_dir = tmp_path / "initrd_tools"
    tool_dir.mkdir(exist_ok=True)
    if files is None and symlinks is None and dirs is None:
        files = {MODULE_PATH + ".xz": "stub-ko"}
    if modinfo_versions is None and modinfo_stdout is None:
        modinfo_versions = {"*": f"{_driver_version()}\n"}

    unmk_spec = {
        "files": files or {},
        "symlinks": symlinks or {},
        "dirs": dirs or {},
        "exit": unmk_exit,
        "stderr_hex": unmk_stderr.hex(),
        "hang": unmk_hang,
    }
    (tool_dir / "unmk_spec.json").write_text(json.dumps(unmk_spec))

    modinfo_spec = {
        "versions": modinfo_versions or {},
        "stdout_hex": None if modinfo_stdout is None else modinfo_stdout.hex(),
        "stderr_hex": modinfo_stderr.hex(),
        "exit": modinfo_exit,
        "hang": modinfo_hang,
    }
    (tool_dir / "modinfo_spec.json").write_text(json.dumps(modinfo_spec))

    unmk_path = tool_dir / "unmkinitramfs"
    if unmk_path.exists():
        unmk_path.unlink()
    if unmk_present:
        if unmk_enoexec:
            unmk_path.write_bytes(b"\x00\x01 not an executable\n")
        else:
            unmk_path.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys, time\n"
                "from pathlib import Path\n"
                f"tool_dir = Path({str(tool_dir)!r})\n"
                "with (tool_dir / 'unmkinitramfs_calls.jsonl').open('a') as log:\n"
                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "spec = json.loads((tool_dir / 'unmk_spec.json').read_text())\n"
                "if spec['hang']:\n"
                "    time.sleep(30)\n"
                "if spec['stderr_hex']:\n"
                "    sys.stderr.buffer.write(bytes.fromhex(spec['stderr_hex']))\n"
                "    sys.stderr.buffer.flush()\n"
                "if spec['exit'] != 0:\n"
                "    raise SystemExit(spec['exit'])\n"
                "dest = Path(sys.argv[2])\n"
                "for rel, text in spec['files'].items():\n"
                "    target = dest / rel\n"
                "    target.parent.mkdir(parents=True, exist_ok=True)\n"
                "    target.write_text(text)\n"
                "for rel, link_target in spec['symlinks'].items():\n"
                "    target = dest / rel\n"
                "    target.parent.mkdir(parents=True, exist_ok=True)\n"
                "    os.symlink(link_target, target)\n"
                "for rel, mode in spec['dirs'].items():\n"
                "    target = dest / rel\n"
                "    target.mkdir(parents=True, exist_ok=True)\n"
                "for rel, mode in sorted(spec['dirs'].items(), key=lambda i: -len(i[0])):\n"
                "    os.chmod(dest / rel, mode)\n"
            )
        unmk_path.chmod(0o755)

    modinfo_path = tool_dir / "modinfo"
    if modinfo_path.exists():
        modinfo_path.unlink()
    if modinfo_present:
        if modinfo_enoexec:
            modinfo_path.write_bytes(b"\x00\x01 not an executable\n")
        else:
            modinfo_path.write_text(
                f"#!{sys.executable}\n"
                "import json, sys, time\n"
                "from pathlib import Path\n"
                f"tool_dir = Path({str(tool_dir)!r})\n"
                "with (tool_dir / 'modinfo_calls.jsonl').open('a') as log:\n"
                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "spec = json.loads((tool_dir / 'modinfo_spec.json').read_text())\n"
                "if spec['hang']:\n"
                "    time.sleep(30)\n"
                "if spec['stderr_hex']:\n"
                "    sys.stderr.buffer.write(bytes.fromhex(spec['stderr_hex']))\n"
                "    sys.stderr.buffer.flush()\n"
                "if spec['exit'] != 0:\n"
                "    raise SystemExit(spec['exit'])\n"
                "if spec['stdout_hex'] is not None:\n"
                "    sys.stdout.buffer.write(bytes.fromhex(spec['stdout_hex']))\n"
                "    sys.stdout.buffer.flush()\n"
                "    raise SystemExit(0)\n"
                "target = sys.argv[-1]\n"
                "versions = spec['versions']\n"
                "out = versions.get('*')\n"
                "for suffix, val in versions.items():\n"
                "    if suffix != '*' and target.endswith(suffix):\n"
                "        out = val\n"
                "        break\n"
                "if out is not None:\n"
                "    sys.stdout.write(out)\n"
                "    sys.stdout.flush()\n"
            )
        modinfo_path.chmod(0o755)

    monkeypatch.setenv("PATH", str(tool_dir))
    return tool_dir


def _tool_calls(tool_dir: Path, tool: str) -> list[list[str]]:
    """Return the recorded argv lists for a stand-in tool."""
    log = tool_dir / f"{tool}_calls.jsonl"
    if not log.exists():
        return []
    return [json.loads(line) for line in log.read_text().splitlines() if line]


def _fake_export(tmp_path: Path, kernel_release: str = hw.KERNEL_RELEASE) -> Path:
    """Build an export tree the preflight accepts: console, bin, kernel, initrd."""
    export = tmp_path / "export"
    (export / "usr/local/bin").mkdir(parents=True)
    dropin = export / f"etc/systemd/system/{hw.CONSOLE_UNIT}.d"
    dropin.mkdir(parents=True)
    (dropin / "autologin.conf").write_text(
        "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root - $TERM\n"
    )
    boot = export / "boot"
    boot.mkdir()
    (boot / f"vmlinux-{kernel_release}").write_bytes(
        b"\x00" * 64 + b"Linux version " + kernel_release.encode() + b" (deb) #1\n"
    )
    (boot / f"initrd.img-{kernel_release}").write_bytes(
        b"\x1f\x8b\x08\x00stub-initrd\n"
    )
    return export


def _fake_root(export: Path) -> Any:
    """Return a LinuxRoot naming a stub export tree on this host."""
    release = hw.KERNEL_RELEASE
    return hw.LinuxRoot(
        nfsroot=f"192.0.2.1:{export}",
        server="192.0.2.1",
        export=export,
        ip=BOARD_IP,
        interface="eth0",
        kernel=export / f"boot/vmlinux-{release}",
        initrd=export / f"boot/initrd.img-{release}",
    )


def _fake_cross(tmp_path: Path) -> tuple[Path, dict[str, str]]:
    """Return a stub cross toolchain (gcc, readelf, objdump) and its env prefix.

    The gcc stub writes ``stub`` to its ``-o`` file; readelf and objdump report
    clean RV64GC attributes and scalar disassembly.
    """
    binary_dir = tmp_path / "toolchain"
    binary_dir.mkdir()
    gcc = binary_dir / "stub-gcc"
    gcc.write_text(
        '#!/bin/sh\nwhile [ "$1" != "-o" ]; do shift; done\n'
        'printf stub > "$2"\nexit 0\n'
    )
    gcc.chmod(0o755)
    readelf = binary_dir / "stub-readelf"
    readelf.write_text(
        "#!/bin/sh\necho '  Tag_RISCV_arch: \"rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_zicsr2p0\"'\n"
    )
    readelf.chmod(0o755)
    objdump = binary_dir / "stub-objdump"
    objdump.write_text(
        "#!/bin/sh\n"
        "printf '0000000000010000 <main>:\\n   10000:\\t00000013\\taddi\\tzero,zero,0\\n'\n"
    )
    objdump.chmod(0o755)
    return gcc, {hw.CROSS_COMPILE_ENV: str(binary_dir / "stub-")}


def test_the_preflight_accepts_a_prepared_export_and_installs_the_programs(
    prepared: tuple[Any, dict[str, str]],
) -> None:
    """The happy path: the notes name the server, the files and the install."""
    root, environment = prepared
    export = root.export
    notes = hw.linux_root_preflight(root, REPO_ROOT, environment)
    assert any("NFSv3" in note for note in notes)
    assert any(hw.KERNEL_RELEASE in note for note in notes)
    assert any("autologin" in note for note in notes)
    assert any(
        "installed frost_stress, frost_nettest, frost_isa_probe, frost_supm_probe"
        in note
        for note in notes
    )
    assert any(f"installed {hw.MEMERR.name}.ko" in note for note in notes)
    assert (
        export / f"usr/local/bin/{hw.MEMERR.name}.ko"
    ).read_bytes() == b"stub module"
    for name in (
        "frost_stress",
        "frost_nettest",
        "frost_isa_probe",
        "frost_supm_probe",
    ):
        installed = export / "usr/local/bin" / name
        assert installed.read_bytes() == b"stub"
        assert installed.stat().st_mode & 0o111
    assert not list((export / "usr/local/bin").glob(".*"))


@pytest.fixture
def prepared(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> tuple[Any, dict[str, str]]:
    """Return a prepared export, stub toolchain, RPC probe, and initrd tools."""
    export = _fake_export(tmp_path)
    _, environment = _fake_cross(tmp_path)
    _install_initrd_tools(tmp_path, monkeypatch)
    module = tmp_path / f"{hw.MEMERR.name}.ko"
    module.write_bytes(b"stub module")
    environment[hw.MEMERR.env] = str(module)
    monkeypatch.setattr(hw, "probe_nfs3_tcp", lambda *args, **kwargs: None)
    return _fake_root(export), environment


def test_the_preflight_reports_a_server_that_is_not_serving(
    prepared: tuple[Any, dict[str, str]], monkeypatch: pytest.MonkeyPatch
) -> None:
    """A server problem is reported as the environment, never as the board."""
    root, environment = prepared
    monkeypatch.setattr(hw, "probe_nfs3_tcp", lambda *a, **k: "nothing listening")
    with pytest.raises(hw.LinuxEnvironmentError) as down:
        hw.linux_root_preflight(root, REPO_ROOT, environment)
    message = str(down.value)
    assert message.startswith(hw.ENV_NOT_READY) and "nothing listening" in message


def test_the_preflight_names_the_missing_kernel(
    prepared: tuple[Any, dict[str, str]],
) -> None:
    """A kernel or initramfs that is not on this host is an environment failure."""
    root, environment = prepared
    root.kernel.unlink()
    with pytest.raises(hw.LinuxEnvironmentError) as absent:
        hw.linux_root_preflight(root, REPO_ROOT, environment)
    message = str(absent.value)
    assert message.startswith(hw.ENV_NOT_READY)
    assert hw.LINUX_KERNEL_ENV in message and "is not a file" in message


def test_the_preflight_rejects_an_empty_initramfs(
    prepared: tuple[Any, dict[str, str]],
) -> None:
    """Reject an empty initramfs during preflight."""
    root, environment = prepared
    root.initrd.write_bytes(b"")
    with pytest.raises(hw.LinuxEnvironmentError, match="is empty"):
        hw.linux_root_preflight(root, REPO_ROOT, environment)


def test_the_preflight_rejects_a_kernel_that_is_not_the_pin(
    prepared: tuple[Any, dict[str, str]],
) -> None:
    """Reject a kernel without the pinned banner before it becomes a board failure."""
    root, environment = prepared
    root.kernel.write_bytes(b"\x00" * 64 + b"Linux version 6.18.7-riscv64 (deb)\n")
    with pytest.raises(hw.LinuxEnvironmentError) as wrong:
        hw.linux_root_preflight(root, REPO_ROOT, environment)
    message = str(wrong.value)
    assert "6.18.7-riscv64" in message and hw.KERNEL_RELEASE in message


def test_the_preflight_rejects_a_compressed_kernel(
    prepared: tuple[Any, dict[str, str]],
) -> None:
    """Vmlinuz carries no readable banner, and the packer cannot use it."""
    root, environment = prepared
    root.kernel.write_bytes(b"\x1f\x8b\x08\x00" + b"\x00" * 4096)
    with pytest.raises(hw.LinuxEnvironmentError, match="vmlinuz"):
        hw.linux_root_preflight(root, REPO_ROOT, environment)
    assert hw.kernel_image_release(root.kernel) is None


def test_the_banner_is_found_across_a_read_boundary(tmp_path: Path) -> None:
    """Find the complete release across chunk boundaries without loading the Image."""
    banner = f"Linux version {hw.KERNEL_RELEASE} (deb) #1\n".encode()
    for offset in (0, (1 << 20) - 20, (1 << 20) + 7, 3 << 20):
        image = tmp_path / f"vmlinux-at-{offset}"
        image.write_bytes(b"\x00" * offset + banner + b"\x00" * 4096)
        assert hw.kernel_image_release(image) == hw.KERNEL_RELEASE
    truncated = tmp_path / "vmlinux-truncated"
    truncated.write_bytes(b"\x00" * 64 + b"Linux version 6.12.1")
    assert hw.kernel_image_release(truncated) is None


def test_the_banner_of_the_pinned_kernel_reads_as_the_pin() -> None:
    """The real pinned Image reads as the pin (skipped until it is fetched)."""
    images = sorted(
        (REPO_ROOT / "linux/debian-kernel").glob(
            f"*/usr/lib/modules/{hw.KERNEL_RELEASE}/vmlinuz"
        )
    )
    if not images:
        pytest.skip("linux/debian-kernel holds no extracted kernel")
    assert hw.kernel_image_release(images[0]) == hw.KERNEL_RELEASE


def test_the_preflight_requires_a_console_autologin(
    prepared: tuple[Any, dict[str, str]],
) -> None:
    """The stage logs in on the UART, and Debian's root has no usable password."""
    root, environment = prepared
    dropin = root.export / f"etc/systemd/system/{hw.CONSOLE_UNIT}.d/autologin.conf"
    dropin.write_text("[Service]\nExecStart=\nExecStart=-/sbin/agetty - $TERM\n")
    with pytest.raises(hw.LinuxEnvironmentError) as no_login:
        hw.linux_root_preflight(root, REPO_ROOT, environment)
    assert hw.CONSOLE_AUTOLOGIN in str(no_login.value)
    assert hw.CONSOLE_UNIT in str(no_login.value)
    # A commented-out drop-in configures nothing, which is the likeliest way to
    # have the option present but inactive.
    dropin.write_text("[Service]\n# ExecStart=-/sbin/agetty --autologin root - $TERM\n")
    assert not hw.console_autologin_files(root.export)
    with pytest.raises(hw.LinuxEnvironmentError, match=hw.CONSOLE_AUTOLOGIN):
        hw.linux_root_preflight(root, REPO_ROOT, environment)
    # A full unit override in place of the drop-in is accepted too.
    dropin.unlink()
    (root.export / f"etc/systemd/system/{hw.CONSOLE_UNIT}").write_text(
        "[Service]\nExecStart=-/sbin/agetty --autologin root - $TERM\n"
    )
    assert hw.console_autologin_files(root.export)


def test_the_preflight_notes_the_drivers_module_and_the_servers_subnet(
    prepared: tuple[Any, dict[str, str]],
) -> None:
    """Report module presence and server subnet without failing preflight.

    A server outside the board's subnet may need its route restored after
    frost_nettest takes the interface down.
    """
    root, environment = prepared
    root.initrd.write_bytes(
        b"07070100000000usr/lib/modules/x/updates/dkms/frost_net10g.ko.xz\0"
    )
    assert hw.initrd_driver_note(root.initrd) == ["the initramfs names frost_net10g"]
    notes = hw.linux_root_preflight(root, REPO_ROOT, environment)
    assert any("carries frost_net10g version" in note for note in notes)
    assert any("shares the board's subnet" in note for note in notes)
    # The docs' example server is on the board's subnet; another one is not.
    elsewhere = dataclasses.replace(root, server="198.51.100.9")
    assert "may not" in hw.subnet_note(elsewhere)[0]
    # An initramfs whose members are compressed says nothing about its names.
    root.initrd.write_bytes(b"\x1f\x8b\x08\x00compressed-stub\n")
    assert hw.initrd_driver_note(root.initrd) == []
    assert hw.linux_root_preflight(root, REPO_ROOT, environment)


def test_the_preflight_rejects_an_export_that_is_not_here(
    prepared: tuple[Any, dict[str, str]],
) -> None:
    """The export has to be a directory on the host that runs the loader."""
    root, environment = prepared
    elsewhere = dataclasses.replace(root, export=root.export / "absent")
    with pytest.raises(hw.LinuxEnvironmentError, match="is not a directory"):
        hw.linux_root_preflight(elsewhere, REPO_ROOT, environment)


def test_the_preflight_names_the_fix_for_an_unwritable_export(
    prepared: tuple[Any, dict[str, str]],
) -> None:
    """The export belongs to root; the stage needs that one directory."""
    root, environment = prepared
    (root.export / "usr/local/bin").chmod(0o555)
    try:
        with pytest.raises(hw.LinuxEnvironmentError) as unwritable:
            hw.linux_root_preflight(root, REPO_ROOT, environment)
    finally:
        (root.export / "usr/local/bin").chmod(0o755)
    message = str(unwritable.value)
    assert "not writable" in message and "install -d" in message


def test_the_preflight_names_every_cross_prefix_it_tried(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A host with no riscv64 Linux gcc is an environment failure with the fix."""
    monkeypatch.setattr(hw.shutil, "which", lambda command: None)
    with pytest.raises(hw.LinuxEnvironmentError) as no_gcc:
        hw.resolve_cross_compile(
            tmp_path, {hw.CROSS_COMPILE_ENV: str(tmp_path / "no-")}
        )
    message = str(no_gcc.value)
    assert str(tmp_path / "no-gcc") in message
    assert str(tmp_path / hw.BUILDROOT_CROSS) + "gcc" in message
    assert hw.DEBIAN_CROSS + "gcc" in message


def test_the_cross_prefix_prefers_the_environment_then_buildroot(
    tmp_path: Path,
) -> None:
    """Prefer FROST_LINUX_CROSS_COMPILE, then the loader's Buildroot toolchain.

    This also matches the NIC module build's compiler selection.
    """
    gcc, environment = _fake_cross(tmp_path)
    buildroot_gcc = tmp_path / f"{hw.BUILDROOT_CROSS}gcc"
    buildroot_gcc.parent.mkdir(parents=True)
    buildroot_gcc.write_text("#!/bin/sh\nexit 1\n")
    buildroot_gcc.chmod(0o755)
    assert hw.resolve_cross_compile(tmp_path, environment) == str(gcc.parent / "stub-")
    assert hw.resolve_cross_compile(tmp_path, {}) == str(tmp_path / hw.BUILDROOT_CROSS)


def test_the_programs_are_built_from_this_checkouts_sources() -> None:
    """Build the checkout's payloads statically for the Debian root.

    Buildroot's musl-linked payloads need a loader absent from the glibc root.
    Static linking also lets frost_nettest run while its root's link is down.
    """
    for name in hw.ROOT_PROGRAMS:
        assert (REPO_ROOT / hw.ROOT_PROGRAM_SRC / f"{name}.c").is_file()
    assert "-static" in hw.ROOT_PROGRAM_CFLAGS


def _stub_board(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """Run main() without a board: no UART, no loader, every stage a PASS."""
    seen: dict[str, Any] = {}
    monkeypatch.setattr(hw, "serial_holders", lambda path: [])
    monkeypatch.setattr(
        hw, "configure_serial", lambda path: os.open(os.devnull, os.O_RDWR)
    )

    def fake_run_uart_stage(
        repo: Path,
        serial_fd: int,
        board: str,
        stage: Any,
        timeout_s: float,
        loader_extra: list[str],
        target: str,
        loader_env: Any = None,
    ) -> dict[str, Any]:
        """Record what the stage was given and report a pass."""
        seen[stage.app] = {"env": loader_env, "timeout": timeout_s, "stage": stage}
        return {"stage": stage.app, "status": "PASS", "elapsed": 1.0, "note": ""}

    monkeypatch.setattr(hw, "run_uart_stage", fake_run_uart_stage)
    return seen


def test_the_stage_hands_the_root_and_its_timeout_to_the_loader(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The loader packs this root, so it gets all four variables and the budget."""
    seen = _stub_board(monkeypatch)
    monkeypatch.setattr(hw, "linux_root_preflight", lambda *args, **kwargs: ["stub"])
    for name, value in hw.linux_loader_env(ROOT).items():
        monkeypatch.setenv(name, value)
    monkeypatch.setattr(
        hw.sys, "argv", ["hw_regression.py", "--board", "x3", "linux_boot"]
    )
    assert hw.main() == 0
    assert seen[hw.LINUX_STAGE]["env"] == hw.linux_loader_env(ROOT)
    assert seen[hw.LINUX_STAGE]["timeout"] == hw.DEFAULT_LINUX_TIMEOUT


def test_keep_going_records_env_fail_and_still_runs_the_other_stages(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """--keep-going means the app stages still run; linux_boot is not a FAIL."""
    seen = _stub_board(monkeypatch)
    _no_site_values(monkeypatch)
    monkeypatch.setattr(
        hw.sys,
        "argv",
        [
            "hw_regression.py",
            "--board",
            "x3",
            "--keep-going",
            "hello_world",
            "linux_boot",
        ],
    )
    assert hw.main() == 1
    assert "hello_world" in seen and hw.LINUX_STAGE not in seen
    captured = capsys.readouterr()
    assert hw.ENV_NOT_READY in captured.err
    assert hw.ENV_FAIL_STATUS in captured.out
    assert "REGRESSION FAIL" in captured.out


def test_the_regression_does_not_touch_the_board_when_the_root_is_unset(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A missing value stops the run before any stage, and is not a FAIL."""
    _no_site_values(monkeypatch)
    monkeypatch.setattr(
        hw.sys, "argv", ["hw_regression.py", "--board", "x3", "linux_boot"]
    )
    monkeypatch.setattr(hw, "serial_holders", lambda path: [])
    monkeypatch.setattr(
        hw, "run_uart_stage", lambda *args, **kwargs: pytest.fail("loaded the board")
    )
    assert hw.main() == 1
    captured = capsys.readouterr()
    assert hw.ENV_NOT_READY in captured.err
    assert "SUMMARY" not in captured.out


# --- The console a board really sends ----------------------------------------

# Composite X3 UART fixture. The boot and stage output come from one
# recording with the regression's typed-input notes removed. The ISA probe
# command echo, four case verdicts, summary and exit come from a separate
# Linux console capture. Both excerpts preserve CRs and escapes.
# Bash disables bracketed paste before each command's first output:
# ESC[?2004l CR <output>. Anchored patterns must handle that prefix.
BOARD_CONSOLE = REPO_ROOT / "tests/fixtures/x3_linux_boot_console.log"
# The site that run used, as its own log shows it.
BOARD_NFSROOT = "192.168.77.1:/srv/frost/debian"
BOARD_ROOT = hw.LinuxRoot(
    nfsroot=BOARD_NFSROOT,
    server="192.168.77.1",
    export=Path("/srv/frost/debian"),
    ip="192.168.77.2::192.168.77.1:255.255.255.0:frost:eth0:off",
    interface="eth0",
    kernel=Path(f"/srv/frost/debian/boot/vmlinux-{hw.KERNEL_RELEASE}"),
    initrd=Path(f"/srv/frost/debian/boot/initrd.img-{hw.KERNEL_RELEASE}"),
)


def board_console() -> str:
    """Return the fixture as the stage reads a UART: bytes, no newline rewriting."""
    return BOARD_CONSOLE.read_bytes().decode("utf-8", errors="replace")


def fixture_isa_run_id(raw_console: str) -> str:
    """Extract the frost_isa_probe run id recorded in a captured UART log."""
    clean = hw.console_text(raw_console)
    match = hw.LINUX_ISA_SUMMARY_RE.search(clean) or hw.LINUX_ISA_EXIT_RE.search(clean)
    assert match is not None, "capture carries no FROST_ISA_PROBE summary or exit line"
    return match.group(1)


def assert_captured_linux_console_passes(
    raw_console: str,
    nfsroot: str = BOARD_NFSROOT,
    *,
    isa_expect: str = hw.LINUX_ISA_EXPECT_DEFAULT,
    isa_vlenb: int | None = None,
) -> str:
    """Verify a recorded Linux console capture passes the stage end to end."""
    release = re.search(r"Linux version (\S+) ", raw_console)
    assert release is not None
    console = raw_console.replace(release[1], hw.KERNEL_RELEASE)
    run_id = fixture_isa_run_id(console)
    root = dataclasses.replace(BOARD_ROOT, nfsroot=nfsroot)
    linux = hw.linux_stage(
        root, isa_expect=isa_expect, isa_run_id=run_id, isa_vlenb=isa_vlenb
    )
    assert linux.success_done(console)
    assert not linux.failure_done(console)
    ok, note = linux.judge(console)
    assert ok, note
    assert hw.KERNEL_RELEASE in note
    assert f"NIC driver {hw.source_driver_version(REPO_ROOT)}" in note
    assert nfsroot in note and "vers=3" in note
    assert "systemd running" in note
    counts = hw.counter_values(hw.console_text(console))
    assert all(int(counts[event]) > 0 for event in hw.LINUX_COUNTER_EVENTS)
    assert "no memory errors" in note
    assert "scrub self-test" in note and "a full pass" in note
    expected_count = len(hw.LINUX_ISA_PROBE_CASES[isa_expect])
    assert f"isa probe {isa_expect} ({expected_count}/{expected_count} cases)" in note
    assert "supm probe (4/4 cases)" in note
    assert "root alive" in note
    return note


def test_recorded_console_with_pinned_release_passes_the_stage() -> None:
    """Parse the composite fixture with the recorded ISA probe run ID."""
    raw = board_console()
    assert fixture_isa_run_id(raw) == "d536f34d"
    assert " -- \rrun-id d536f34d;" in raw
    assert_captured_linux_console_passes(raw)


def test_the_fixture_still_carries_the_escapes_it_is_here_for() -> None:
    """Preserve the fixture's bracketed-paste escapes, colored greeting, and CRs."""
    console = board_console()
    # The probe's closing escape precedes its diagnostic output in the capture.
    assert console.count("\x1b[?2004l") == 7
    assert "\x1b[?2004l\rnfs " in console
    assert f"\x1b[?2004l\r{hw.LINUX_DRIVER_VERSION_TOKEN}=" in console
    assert f"\x1b[?2004l\rstate={hw.LINUX_SYSTEMD_RUNNING}" in console
    assert "Welcome to \x1b[0m\x1b[1mDebian GNU/Linux" in console
    assert "\r\n" in console


def test_the_anchored_patterns_need_the_escapes_removed() -> None:
    """Match mount, driver, and state lines only after console_text removes escapes."""
    raw = board_console()
    assert hw.LINUX_ROOT_MOUNT_RE.search(raw) is None
    assert hw.LINUX_DRIVER_VERSION_RE.search(raw) is None
    assert hw.LINUX_SYSTEMD_STATE_RE.search(raw) is None
    clean = hw.console_text(raw)
    assert hw.LINUX_ROOT_MOUNT_RE.search(clean) is not None
    assert hw.LINUX_DRIVER_VERSION_RE.search(clean) is not None
    assert hw.LINUX_SYSTEMD_STATE_RE.search(clean) is not None
    assert hw.systemd_state(clean) == hw.LINUX_SYSTEMD_RUNNING
    ok, note = hw.root_mount_verdict(clean, BOARD_NFSROOT)
    assert ok, note
    ok, note = hw.driver_version_verdict(clean, hw.source_driver_version(REPO_ROOT))
    assert ok, note
    # The one value that did read raw: bash turns bracketed paste off once per
    # typed line, so a later command's output on that line starts clean.
    assert hw.root_alive_status(raw) == 0


@pytest.mark.parametrize(
    "escaped,plain",
    [
        ("\x1b[?2004l\rstate=running\r\n", "\rstate=running\r\n"),
        ("\x1b[0;1;39mWelcome to \x1b[0m\x1b[1mDebian\x1b[0m", "Welcome to Debian"),
        ("\x1b]0;root@frost: ~\x07root@frost:~# ", "root@frost:~# "),
        # An escape the capture stopped in the middle of, or a stray byte from a
        # program, must not swallow the line after it.
        ("\x1b]0;unterminated\nstate=running\r\n", "\nstate=running\r\n"),
        ("plain text", "plain text"),
    ],
    ids=[
        "bracketed-paste",
        "systemd-colour",
        "window-title",
        "unterminated",
        "nothing-to-do",
    ],
)
def test_console_text_removes_terminal_escapes(escaped: str, plain: str) -> None:
    """Bracketed paste, colours and a window title all come out."""
    assert hw.console_text(escaped) == plain


def test_the_real_prompts_fire_every_stimulus_in_order() -> None:
    """Sequence commands on the raw capture, preserving run_uart_stage's offsets.

    Triggers must match ESC[?2004h before the shell prompt and the autologin
    message "frost login: root (automatic login)". This capture has no stray
    root command because login discards the typed answer.
    """
    raw = board_console()
    linux = hw.linux_stage(BOARD_ROOT, isa_run_id=fixture_isa_run_id(raw))
    assert "frost login: root (automatic login)" in raw
    assert "\x1b[?2004hroot@frost:~# " in raw
    assert "command not found" not in raw
    sent, after = 0, 0
    for expected in [text for _, text in linux.stimuli]:
        pending = hw.next_stimulus(linux, raw, sent, after)
        assert pending is not None, expected
        typed, after = pending
        assert typed == expected
        sent += 1
    assert hw.next_stimulus(linux, raw, sent, after) is None


def test_linux_stage_accepts_real_probe_capture() -> None:
    """Check a capture or exercise a synthetic probe with INFO lines and UART wrap.

    Set ``FROST_TEST_LINUX_CAPTURE`` to a captured serial log file to verify a
    fresh live capture directly through this hook.
    """
    capture_env = os.environ.get("FROST_TEST_LINUX_CAPTURE", "").strip()
    if capture_env:
        live = Path(capture_env).read_bytes().decode("utf-8", errors="replace")
        assert_captured_linux_console_passes(live)
        return

    raw = board_console()
    probe_start = raw.index(
        f"\x1b[?2004h{PROMPT}timeout -k 5 45 /usr/local/bin/frost_isa_probe suite "
    )
    exit_line = f"{hw.LINUX_ISA_PROBE_EXIT_TOKEN} id={fixture_isa_run_id(raw)} rc=0\r\n"
    probe_end = raw.index(exit_line, probe_start) + len(exit_line)
    synthetic_id = "f7e6d5c4"
    synthetic_block = (
        "\x1b[?2004hroot@frost:~# timeout -k 5 45 /usr/local/bin/frost_isa_probe su\ruite "
        f"--vlenb 32 --run-id {synthetic_id}; printf 'FROST_ISA_PROBE_EXIT id=%s rc=%s\\n' "
        f'{synthetic_id} "$?"\r\n'
        f"\x1b[?2004l\rFROST_ISA_PROBE_INFO id={synthetic_id} case=discover of=/sys/firmware/devicetree/base/cpus/cpu@0 dt_ext_ok=1 dt_ext_v=0 dt_ext_zve=0 dt_ext_cnt=49 dt_isa_ok=1 dt_isa_v=0 dt_isa_zve=0 ci_ok=1 ci_isa_v=0 ci_hart_v=0\r\n"
        f"FROST_ISA_PROBE_INFO id={synthetic_id} case=discover hwprobe_all_rc=0(e=0) base=0x1 ext0=0x12811200000fb hwprobe_hart_rc=0(e=0) hbase=0x1 hext0=0x12811200000fb hwcap=0x112d prctl=-1(e=22) default_allow=missing\r\n"
        f"FROST_ISA_PROBE id={synthetic_id} case=discover verdict=PASS mode=absent\r\n"
        f"FROST_ISA_PROBE id={synthetic_id} case=illegal verdict=PASS sigill=1 pc_match=1 scalar_pre=1\r\n"
        f"FROST_ISA_PROBE id={synthetic_id} case=signal verdict=PASS rounds=4 end_magic=0 end_size=0\r\n"
        f"FROST_ISA_PROBE id={synthetic_id} case=ptrace verdict=PASS gpr_ok=1 einval=1\r\n"
        f"FROST_ISA_PROBE_SUMMARY id={synthetic_id} mode=absent passed=4 failed=0 verdict=PASS\r\n"
        f"FROST_ISA_PROBE_EXIT id={synthetic_id} rc=0\r\n"
    )
    transcript = (
        raw[:probe_start]
        + synthetic_block
        + raw[probe_end:].replace(fixture_isa_run_id(raw), synthetic_id)
    )
    assert fixture_isa_run_id(transcript) == synthetic_id
    assert_captured_linux_console_passes(transcript)


def test_console_text_keeps_what_the_stage_reads() -> None:
    """Normalize escapes without changing console tokens, counts, or prompts."""
    assert hw.console_text(MOUNT_LINE) == MOUNT_LINE
    assert hw.console_text(COUNTER_LINE) == COUNTER_LINE
    stripped = hw.console_text(FULL_TRANSCRIPT)
    assert hw.linux_stage(ROOT, isa_run_id=ISA_RUN_ID).judge(stripped)[0]
    assert stripped.count(PROMPT) == FULL_TRANSCRIPT.count(PROMPT)


# --- Stages and other apps ---------------------------------------------------


# Synthetic output follows bootrom.c, fsbl.c and the U-Boot configuration.
ROM_VERIFIED = "[BOOTROM] FSBL CRC-32 verified (0x1234abcd). Jumping to 0x00004000...\n"
FSBL_READY = (
    "[FSBL] Boot chain ready: OpenSBI @ 0x80000000 -> U-Boot @ 0x80200000 "
    "(DTB @ 0x82200000)\n"
)
FSBL_HANDOFF = "[FSBL] Handing off to OpenSBI + U-Boot Proper in DRAM...\n"
UBOOT_BANNER = "U-Boot 2026.10-g5508406582f6-dirty (Oct 28 2026 - 12:00:00 +0000)\n"
UBOOT_PROMPT = "frost=> "
FLASH_BOOT_TRANSCRIPT = (
    "FROST Core Boot ROM v1.0 (On-Chip BRAM @ 0x00000000)\n"
    "[BOOTROM] SYS_STATUS=0x46520300  SPI Flash JEDEC ID=0x20bb21\n"
    "[BOOTROM] Loading FSBL (4568 bytes) from flash 0x04000020 -> SRAM 0x00004000...\n"
    + ROM_VERIFIED
    + "FROST 2nd-Stage Bootloader (FSBL) v1.0 (SRAM @ 0x00004000)\n"
    "[FSBL] Waiting for DDR4 MIG calibration and hardware ECC scrub...\n"
    "[FSBL] DDR4 controller ready (SYS_STATUS=0x46520300)\n"
    "[FSBL] DDR4 2 GiB @ 0x80000000 verified and boot regions scrubbed.\n"
    "[FSBL] Loading      OpenSBI ( 267864 bytes) flash 0x04100020 -> DRAM 0x80000000..."
    " CRC OK (0x01234567)\n"
    "[FSBL] Loading   DeviceTree (   3416 bytes) flash 0x04200020 -> DRAM 0x82200000..."
    " CRC OK (0x12345678)\n"
    "[FSBL] Loading       U-Boot ( 582824 bytes) flash 0x04300020 -> DRAM 0x80200000..."
    " CRC OK (0x23456789)\n"
    + FSBL_READY
    + FSBL_HANDOFF
    + "\nOpenSBI v1.8\n\n"
    + UBOOT_BANNER
    + "\nDRAM:  2 GiB\nIn:    serial@40001000\nOut:   serial@40001000\n"
    + UBOOT_PROMPT
)


@pytest.mark.parametrize("newline", ["\n", "\r\n", "\r\r\n"])
@pytest.mark.parametrize("ansi_prompt", [False, True])
def test_flash_boot_requires_the_complete_prompt(
    newline: str, ansi_prompt: bool
) -> None:
    """Verified ROM/FSBL progress and the U-Boot prompt prove the boot chain."""
    bootrom = hw.build_stage("bootrom", "vcu118", 1.0)
    transcript = FLASH_BOOT_TRANSCRIPT.replace("\n", newline)
    if ansi_prompt:
        transcript = transcript.replace(UBOOT_PROMPT, "\x1b[0m" + UBOOT_PROMPT)
    assert "<<PASS>>" not in transcript
    for end in range(len(transcript)):
        assert not bootrom.success_done(transcript[:end]), end
        assert not bootrom.failure_done(transcript[:end]), end
    assert bootrom.success_done(transcript)
    assert not bootrom.failure_done(transcript)
    ok, note = bootrom.judge(transcript)
    assert ok and "U-Boot prompt reached" in note
    assert bootrom.stimuli == ()


@pytest.mark.parametrize(
    "missing", [ROM_VERIFIED, FSBL_READY, FSBL_HANDOFF, UBOOT_BANNER, UBOOT_PROMPT]
)
def test_flash_boot_needs_every_handoff(missing: str) -> None:
    """Neither an early handoff nor a prompt alone proves the complete chain."""
    bootrom = hw.build_stage("bootrom", "vcu118", 1.0)
    transcript = FLASH_BOOT_TRANSCRIPT.replace(missing, "")
    assert not bootrom.success_done(transcript)
    assert not bootrom.failure_done(transcript)
    ok, note = bootrom.judge(transcript)
    assert not ok and note.startswith("missing ")


@pytest.mark.parametrize(
    "transcript",
    [
        "<<PASS>>\n",
        UBOOT_BANNER + UBOOT_PROMPT,
        UBOOT_PROMPT + "\n" + FLASH_BOOT_TRANSCRIPT.removesuffix(UBOOT_PROMPT),
        FLASH_BOOT_TRANSCRIPT.replace(ROM_VERIFIED, "").replace(
            FSBL_READY, FSBL_READY + ROM_VERIFIED
        ),
        FLASH_BOOT_TRANSCRIPT.replace(FSBL_HANDOFF, "").replace(
            UBOOT_BANNER, UBOOT_BANNER + FSBL_HANDOFF
        ),
        FLASH_BOOT_TRANSCRIPT.replace("0x82200000)", "0x82000000)"),
        FLASH_BOOT_TRANSCRIPT.replace(UBOOT_PROMPT, "example prompt: frost=> "),
        FLASH_BOOT_TRANSCRIPT.replace(UBOOT_PROMPT, "frost=> help"),
    ],
)
def test_flash_boot_rejects_unrelated_or_unordered_success(transcript: str) -> None:
    """Generic pass tokens and prompts outside the verified sequence cannot pass."""
    bootrom = hw.build_stage("bootrom", "vcu118", 1.0)
    assert not bootrom.success_done(transcript)
    assert not bootrom.judge(transcript)[0]


def test_flash_boot_uses_the_latest_rom_attempt() -> None:
    """A restart must supply its own verified handoffs and prompt."""
    bootrom = hw.build_stage("bootrom", "vcu118", 1.0)
    restarted = (
        FLASH_BOOT_TRANSCRIPT + "\n" + FLASH_BOOT_TRANSCRIPT.splitlines()[0] + "\n"
    )
    assert not bootrom.success_done(restarted)
    assert not bootrom.success_done(restarted + UBOOT_BANNER + UBOOT_PROMPT)
    assert not bootrom.judge(restarted + UBOOT_BANNER + UBOOT_PROMPT)[0]
    assert bootrom.success_done(FLASH_BOOT_TRANSCRIPT + "\n" + FLASH_BOOT_TRANSCRIPT)


@pytest.mark.parametrize(
    "failure",
    [
        "[BOOTROM] HALT: Boot/SPI controller not present on this platform",
        "[BOOTROM] HALT: Waiting for JTAG or SPI flash programming",
        "[BOOTROM] HALT: FSBL image header out of on-chip SRAM bounds",
        "[BOOTROM] HALT: FSBL CRC verification failed",
        "[BOOTROM] HALT: FSBL returned unexpectedly",
        "[FSBL] HALT: DDR4 memory verification failed",
        "[FSBL] HALT: Missing or invalid stage-3 image in SPI flash",
        "[FSBL] HALT: Image header does not match its boot partition",
        "[FSBL] HALT: DRAM image CRC-32 mismatch",
        "[FSBL] HALT: OpenSBI returned unexpectedly",
        "[BOOTROM] No valid FSBL header @ flash 0x04000000 (magic=0xffffffff ver=4294967295)",
        "[BOOTROM] Invalid FSBL bounds: load=0x00000000 len=4096 entry=0x00000000",
        "[BOOTROM] FSBL CRC-32 mismatch! expected=0x12345678 actual=0x87654321",
        "[FSBL] DRAM verify failed @ 0x80000000: exp=0xa5a55a5a700dcafe got=0x0000000000000000",
        "[FSBL] Invalid OpenSBI header @ flash 0x04100000 (magic=0x00000000 ver=0 len=0)",
        "[FSBL] Invalid DeviceTree header @ flash 0x04200000 (magic=0x00000000 ver=0 len=0)",
        "[FSBL] Invalid U-Boot header @ flash 0x04300000 (magic=0x00000000 ver=0 len=0)",
        "[FSBL] Loading      OpenSBI ( 267864 bytes) flash 0x04100020 -> DRAM 0x80000000..."
        " FAIL (exp=0x12345678 got=0x87654321)",
        "[FSBL] Loading %-12s (  20480 bytes) flash 0x00041658 -> DRAM 0x04100020..."
        " FAIL (exp=0x12345678 got=0x87654321)",
        "<<FAIL>>",
        "<<TRAP>>",
        "sbi_trap_error: hart0: trap handler failed (error -2)",
        "Unhandled exception: Load access fault",
        "Unhandled exception code: 99",
        "### ERROR ### Please RESET the board ###",
        "init_coldboot: pmu init failed (error -2)",
        "init_coldboot: irqchip init failed (error -2)",
        "init_coldboot: ipi init failed (error -2)",
        "init_coldboot: tlb init failed (error -2)",
        "init_coldboot: fwft init failed (error -2)",
        "init_coldboot: mpxy init failed (error -2)",
        "init_coldboot: domain finalize failed (error -2)",
        "init_coldboot: platform final init failed (error -2)",
        "init_coldboot: sse init failed (error -2)",
        "init_coldboot: ecall init failed (error -2)",
        "Error 0 getting MISA XLEN",
    ],
)
def test_flash_boot_failure_overrides_progress_and_prompt(failure: str) -> None:
    """Firmware failures terminate capture and override any successful progress."""
    bootrom = hw.build_stage("bootrom", "vcu118", 1.0)
    for transcript in (
        failure,
        ROM_VERIFIED + failure,
        failure + "\n" + FLASH_BOOT_TRANSCRIPT,
        FLASH_BOOT_TRANSCRIPT + "\n" + failure,
    ):
        assert bootrom.failure_done(transcript)
        assert not bootrom.success_done(transcript)
        ok, note = bootrom.judge(transcript)
        assert not ok and failure in note


@pytest.mark.parametrize(
    "board,before_load,uart,tail,flush_delay,status",
    [
        ("vcu118", "", FLASH_BOOT_TRANSCRIPT, "", 0.0, "PASS"),
        ("vcu118", "", "[FSBL] HALT: DRAM image CRC-32 mismatch\n", "", 0.0, "FAIL"),
        (
            "vcu118",
            "",
            FLASH_BOOT_TRANSCRIPT.removesuffix(UBOOT_PROMPT),
            "",
            0.0,
            "TIMEOUT",
        ),
        ("vcu118", FLASH_BOOT_TRANSCRIPT, "", "", 0.0, "TIMEOUT"),
        ("vcu118", "", FLASH_BOOT_TRANSCRIPT, "\n<<TRAP>>\n", 0.0, "FAIL"),
        ("vcu118", "", FLASH_BOOT_TRANSCRIPT, "help", 0.0, "TIMEOUT"),
        (
            "vcu118",
            "",
            FLASH_BOOT_TRANSCRIPT,
            "\n" + FLASH_BOOT_TRANSCRIPT.splitlines()[0] + "\n",
            0.0,
            "TIMEOUT",
        ),
        ("x3", "", "<<PASS>>\n", "", 0.0, "PASS"),
        ("x3", "", "<<PASS>>\n", "\n<<TRAP>>\n", 0.0, "PASS"),
        ("vcu118", "", FLASH_BOOT_TRANSCRIPT, "\n<<TRAP>>\n", 2.0, "FAIL"),
        ("vcu118", "", FLASH_BOOT_TRANSCRIPT, "", 2.0, "PASS"),
    ],
)
@pytest.mark.parametrize("read_interval", [0.25, 3.0])
def test_flash_boot_capture_reports_pass_failure_and_timeout(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    board: str,
    before_load: str,
    uart: str,
    tail: str,
    flush_delay: float,
    status: str,
    read_interval: float,
) -> None:
    """Capture uses post-load UART evidence and stops on failure or its deadline."""
    loader_fd, loader_write = os.pipe()
    serial_fd, serial_write = os.pipe()
    pending = {
        loader_fd: [f"{hw.LOAD_COMPLETE_SENTINEL}\n".encode()],
        serial_fd: ([before_load.encode()] if before_load else [])
        + (
            [uart[: len(uart) // 2].encode(), uart[len(uart) // 2 :].encode()]
            if uart
            else []
        )
        + ([tail.encode()] if tail and not flush_delay else []),
    }
    now = 0.0
    console = hw.sys.stdout

    class SlowConsole:
        delay_pending = False

        def write(self, text: str) -> Any:
            self.delay_pending = text.endswith(UBOOT_PROMPT)
            return console.write(text)

        def flush(self) -> None:
            nonlocal now
            if self.delay_pending:
                now += flush_delay
                if flush_delay and tail:
                    pending[serial_fd].append(tail.encode())
                self.delay_pending = False
            console.flush()

    class FinishedLoader:
        returncode = 0

        def __init__(self, *_args: Any, **_kwargs: Any) -> None:
            self.stdout = SimpleNamespace(fileno=lambda: loader_fd)

        def poll(self) -> int:
            return 0

    def select(
        readable: list[int], _write: list[int], _error: list[int], _timeout: float
    ) -> tuple[list[int], list[int], list[int]]:
        nonlocal now
        if _timeout:
            now += read_interval
        if loader_fd in readable:
            return ([serial_fd] if before_load else []), [], []
        return ([serial_fd] if pending[serial_fd] else []), [], []

    monkeypatch.setattr(hw, "time", SimpleNamespace(monotonic=lambda: now))
    monkeypatch.setattr(hw, "select", SimpleNamespace(select=select))
    monkeypatch.setattr(hw, "sys", SimpleNamespace(stdout=SlowConsole()))
    monkeypatch.setattr(hw, "drain", lambda _fd: None)
    monkeypatch.setattr(
        hw, "read_available", lambda fd: pending[fd].pop(0) if pending[fd] else b""
    )
    monkeypatch.setattr(hw.subprocess, "Popen", FinishedLoader)
    monkeypatch.setattr(
        hw, "send_uart_probe", lambda *args: pytest.fail("flash boot typed UART input")
    )
    try:
        result = hw.run_uart_stage(
            tmp_path,
            serial_fd,
            board,
            hw.build_stage(
                "bootrom" if board == "vcu118" else "memory_test", board, 1.0
            ),
            7.0,
            [],
            "fixture-target",
        )
    finally:
        for fd in (loader_fd, loader_write, serial_fd, serial_write):
            os.close(fd)
    if board == "vcu118" and read_interval == 3.0 and status == "PASS":
        status = "TIMEOUT"
    if board == "vcu118" and read_interval == 3.0 and tail:
        status = "TIMEOUT"
    assert result["status"] == status
    if status == "TIMEOUT":
        assert result["elapsed"] >= 7.0
        assert "no terminal UART output" in result["note"]
    elif board == "x3":
        assert result["elapsed"] == 3 * read_interval
    else:
        assert result["elapsed"] < 7.0


@pytest.mark.parametrize("requested", [None, 1.0, 1800.0])
@pytest.mark.parametrize("board", ["x3", "vcu118"])
def test_flash_boot_timeout_preserves_other_apps_and_longer_budgets(
    monkeypatch: pytest.MonkeyPatch, requested: float | None, board: str
) -> None:
    """Only VCU118 bootrom raises the base timeout to its flash-boot minimum."""
    seen = _stub_board(monkeypatch)
    argv = ["runner", "--board", board]
    if requested is not None:
        argv += ["--timeout", str(requested)]
    argv += ["hello_world"]
    if board == "vcu118":
        argv += ["bootrom"]
    monkeypatch.setattr(hw.sys, "argv", argv)
    assert hw.main() == 0
    base = hw.DEFAULT_TIMEOUTS[board] if requested is None else requested
    assert seen["hello_world"]["timeout"] == base
    if board == "vcu118":
        assert seen["bootrom"]["timeout"] == max(base, 600.0)
    else:
        assert "bootrom" not in seen


def test_x3_app_verdicts_use_their_application_markers() -> None:
    """Flash progress cannot stand in for an X3 application's pass marker."""
    special = {
        "hello_world",
        "uart_echo",
        "coremark",
        "coremark_pro",
        "linux_boot",
        "ddr_ecc",
        "debug_port",
    }
    for app in hw.regression_stages("x3"):
        if app in special:
            continue
        stage = hw.build_stage(app, "x3", 1.0)
        assert stage.success_quiet_s == 0.0
        assert stage.judge("<<PASS>>\n") == (True, "")
        assert not stage.judge(FLASH_BOOT_TRANSCRIPT)[0]
        assert stage.failure_done("<<FAIL>>\n")


@pytest.mark.parametrize("board,board_apps", [("x3", []), ("vcu118", ["bootrom"])])
def test_default_stages_match_board(board: str, board_apps: list[str]) -> None:
    """Stage lists contain supported apps, with hello_world first and ECC last."""
    stages = hw.regression_stages(board)
    assert stages == [
        "hello_world",
        *(["debug_port"] if board == "x3" else []),
        *board_apps,
        "amo_irq_torture",
        "asid_test",
        *(["bpred_probe"] if board == "x3" else []),
        "bpred_trap_pair_test",
        "branch_pred_test",
        "c_ext_test",
        "cbo_mgmt_test",
        "call_stress",
        "cf_ext_test",
        "coremark",
        "csr_test",
        "imsic_csr_test",
        "imsic_msi_test",
        "imsic_aplic_coexist_test",
        "ddr_exec_test",
        "ddr_atomic_test",
        "ddr_bench",
        "ddr_heap_test",
        "ddr_smc_test",
        "ddr_test",
        "dma_torture",
        "fencei_jit_bench",
        *(["fplat_probe"] if board == "x3" else []),
        "freertos_demo",
        "fpu_assembly_test",
        "fpu_test",
        "full_line_test",
        "isa_test",
        "itlb_test",
        "l1i_set_test",
        "l2_capacity_chase",
        "linux_irq_active_ddr_test",
        "linux_irq_ddr_test",
        "linux_irq_stack_slot_test",
        "lq_stale_slot_probe",
        *(["memerr_readback"] if board == "x3" else []),
        "memory_test",
        "misaligned_test",
        *(["mispen_probe"] if board == "x3" else []),
        "nic_cmo_loopback",
        "nic_loopback",
        "odd_halfword_pred_test",
        "opensbi_smoke",
        "packet_parser",
        "pd_itt_slot2",
        "pde_return_hazard",
        "perf_off_test",
        "pma_fault_test",
        *(["print_clock_speed"] if board == "x3" else []),
        "ptw_coherence_test",
        "ras_stress_test",
        "ras_test",
        "smc_predict_test",
        "smode_test",
        "spanning_test",
        "sprintf_test",
        "sscofpmf_test",
        "store_fill_bench",
        "strings_test",
        "sum_toggle_test",
        *(["svpbmt_cmo_test"] if board == "x3" else []),
        "sysreset_test",
        "tick_torture",
        *(["tomasulo_perf"] if board == "x3" else []),
        "tomasulo_test",
        "uart_echo",
        "umode_test",
        # The vector-only test programs run where the build has the vector unit;
        # vec_state_test runs on every board with its RTL vector configuration.
        *(
            [
                "vec_arith_test",
                "vec_crypto_exec_test",
                "vec_ff_test",
                "vec_fp_test",
                "vec_index_test",
                "vec_integer_test",
                "vec_mem_reserved_forms_test",
                "vec_mem_source_eew_test",
                "vec_mem_test",
                "vec_order_test",
                "vec_segment_test",
                "vec_source_eew_test",
                "vec_state_test",
                "vec_stride_test",
                "vec_vsetvl_test",
                "vec_vstart_reload_test",
                "vec_vtype_handoff_test",
            ]
            if board == "x3"
            else ["vec_state_test"]
        ),
        "vm_test",
        "coremark_pro",
        "linux_boot",
        "ddr_ecc",
    ]
    assert "debug_target" in hw.valid_apps_for_board(board)
    assert "debug_target" not in stages
    # nic_echo needs a link partner sending the cocotb wire peer's frames.
    assert "nic_echo" in hw.valid_apps_for_board(board)
    assert "nic_echo" not in stages
    assert ("nic_bench" in hw.valid_apps_for_board(board)) == (board == "vcu118")
    assert "nic_bench" not in stages
    assert "fsbl" not in hw.valid_apps_for_board(board)
    assert not set(hw.COREMARK_PRO_APP_NAMES) & set(stages)
    assert len(stages) == len(set(stages))


def test_ecc_stage_requires_a_design_window(monkeypatch: pytest.MonkeyPatch) -> None:
    """Select controller ECC only where the target has a defined window."""
    monkeypatch.delitem(hw.ECC_WINDOW_DESIGNS, "vcu118")
    assert hw.ECC_STAGE not in hw.regression_stages("vcu118")
    assert hw.regression_stages("x3")[-1] == hw.ECC_STAGE


@pytest.mark.parametrize("board", ["x3", "vcu118"])
def test_default_stage_dispatch_uses_selected_board(
    monkeypatch: pytest.MonkeyPatch, board: str
) -> None:
    """The CLI dispatches exactly the selected board's default stage list."""
    seen = _stub_board(monkeypatch)
    monkeypatch.setattr(hw, "linux_root_from_env", lambda: ROOT)
    monkeypatch.setattr(hw, "linux_root_preflight", lambda *args: [])

    def finish(stage: str) -> dict[str, Any]:
        seen[stage] = {}
        return {"stage": stage, "status": "PASS", "elapsed": 0.0, "note": ""}

    monkeypatch.setattr(hw, "run_sweep_stage", lambda *args: finish(hw.SWEEP_STAGE))
    monkeypatch.setattr(hw, "run_ecc_stage", lambda *args: finish(hw.ECC_STAGE))
    monkeypatch.setattr(hw, "run_debug_stage", lambda *args: finish(hw.DEBUG_STAGE))
    monkeypatch.setattr(hw.sys, "argv", ["runner", "--board", board])
    assert hw.main() == 0
    assert list(seen) == hw.regression_stages(board)


@pytest.mark.parametrize(
    "board,stage_name",
    [
        (board, stage)
        for board in hw.BOARD_CONFIG
        for stage in hw.regression_stages(board)
    ],
)
def test_selected_stage_helper_accepts_the_board(
    monkeypatch: pytest.MonkeyPatch, board: str, stage_name: str
) -> None:
    """Run the emitted commands through their CLI checks up to JTAG discovery."""
    target_pattern = "test cable"
    loader_apps: list[str] = []

    class TargetDiscoveryReachedError(Exception):
        """Signal that a helper accepted the arguments before discovering cables."""

    def select_target(*_args: Any, **kwargs: Any) -> None:
        assert kwargs["board"] == board
        assert kwargs["target_pattern"] == target_pattern
        raise TargetDiscoveryReachedError

    def invoke_helper(command: list[str], **_kwargs: Any) -> Any:
        script = Path(command[0]).name
        with monkeypatch.context() as invocation:
            invocation.setattr(sys, "argv", command)
            if script == "sweep_coremark_pro.py":
                assert stage_name == hw.SWEEP_STAGE
                assert command[command.index("--board") + 1] == board
                # The mock loaders stop at discovery, before a UART result.
                assert sweep_coremark_pro.main() == 1
                raise TargetDiscoveryReachedError
            elif script == "ddr_ecc_status.py":
                assert stage_name == hw.ECC_STAGE
                assert "--non-interactive" in command
                ddr_ecc_status.main()
            else:
                assert script == "load_software.py"
                loader_apps.append(command[2])
                if stage_name == hw.SWEEP_STAGE:
                    with pytest.raises(TargetDiscoveryReachedError):
                        load_software.main()
                    return SimpleNamespace(stdout=None, returncode=1, poll=lambda: 1)
                assert command[2] == stage_name
                load_software.main()
        pytest.fail(f"{script} returned before target discovery")

    def check_debug_helper(_repo: Path, selected_board: str) -> None:
        assert stage_name == hw.DEBUG_STAGE
        assert selected_board == board == "x3"
        raise TargetDiscoveryReachedError

    monkeypatch.setattr(hw, "run_debug_stage", check_debug_helper)
    monkeypatch.delenv("FROST_CPU_CLK_HZ", raising=False)
    monkeypatch.setattr(load_software, "_linux_boot_preflight", lambda: None)
    monkeypatch.setattr(load_software, "compile_app_for_board", lambda *a, **kw: True)
    monkeypatch.setattr(load_software, "validate_prebuilt_app", lambda *a, **kw: {})
    monkeypatch.setattr(load_software, "select_target", select_target)
    monkeypatch.setattr(ddr_ecc_status, "select_target", select_target)
    monkeypatch.setattr(hw, "linux_root_from_env", lambda: ROOT)
    monkeypatch.setattr(hw, "linux_root_preflight", lambda *args: [])
    for runner in (hw, sweep_coremark_pro):
        monkeypatch.setattr(runner, "serial_holders", lambda _serial: [])
        monkeypatch.setattr(
            runner, "configure_serial", lambda _serial: os.open(os.devnull, os.O_RDONLY)
        )
        monkeypatch.setattr(runner, "drain", lambda _fd: None)
    monkeypatch.setattr(hw.subprocess, "Popen", invoke_helper)
    monkeypatch.setattr(hw.subprocess, "run", invoke_helper)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "runner",
            "--board",
            board,
            "--serial",
            "test",
            "--target",
            target_pattern,
            stage_name,
        ],
    )
    # The outer CLI exception reporter handles errors that escape dispatch.
    with pytest.raises(TargetDiscoveryReachedError):
        hw._main()
    if stage_name == hw.SWEEP_STAGE:
        assert tuple(loader_apps) == sweep_coremark_pro.HW_APPS


@pytest.mark.parametrize(
    "board,app",
    [
        ("x3", "bootrom"),
        ("x3", "fsbl"),
        ("vcu118", "fsbl"),
        ("vcu118", "memerr_readback"),
        ("vcu118", "svpbmt_cmo_test"),
        ("vcu118", "bpred_probe"),
    ],
)
def test_unsupported_stage_is_rejected_before_board_access(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    board: str,
    app: str,
) -> None:
    """An explicit stage request must belong to the selected board's list."""
    monkeypatch.setattr(hw.sys, "argv", ["runner", "--board", board, app])
    monkeypatch.setattr(
        hw, "serial_holders", lambda *args: pytest.fail("serial preflight started")
    )
    monkeypatch.setattr(
        hw, "linux_root_from_env", lambda: pytest.fail("Linux preflight started")
    )
    with pytest.raises(SystemExit) as rejected:
        hw.main()
    assert rejected.value.code == 2
    error = capsys.readouterr().err
    assert f"unknown stage(s): {app}\n" in error
    assert app not in error.split("valid stages:", 1)[1]


def test_vcu118_accepts_explicit_bootrom_stage(monkeypatch: pytest.MonkeyPatch) -> None:
    """The VCU118 selector accepts bootrom as a standalone stage."""
    seen = _stub_board(monkeypatch)
    monkeypatch.setattr(hw.sys, "argv", ["runner", "--board", "vcu118", "bootrom"])
    assert hw.main() == 0
    assert list(seen) == ["bootrom"]


def test_stage_loader_extra_forwards_vector_options_selectively() -> None:
    """--vlen reaches only VEC_VLEN_APPS; --vec-advertise reaches only vec_state_test."""
    assert hw.stage_loader_extra(
        "vec_state_test", ["--ddr"], vlen=128, vec_advertise=True
    ) == ["--ddr", "--vlen", "128", "--vec-advertise"]
    assert hw.stage_loader_extra(
        "vec_state_test", [], vlen=256, vec_advertise=False
    ) == ["--vlen", "256", "--no-vec-advertise"]
    assert hw.stage_loader_extra(
        "vec_fp_test", ["--ddr"], vlen=512, vec_advertise=True
    ) == ["--ddr", "--vlen", "512"]
    assert hw.stage_loader_extra(
        "vec_arith_test", ["--ddr"], vlen=128, vec_advertise=True
    ) == ["--ddr"]
    assert hw.stage_loader_extra("hello_world", [], vlen=128, vec_advertise=False) == []


@pytest.mark.parametrize(
    "board,extra_args,stages,expected_make_vars",
    [
        (
            "x3",
            ["--vlen", "128", "--vec-advertise"],
            ["vec_arith_test", "vec_fp_test", "vec_state_test"],
            {
                "vec_arith_test": {},
                "vec_fp_test": {"EXTRA_CFLAGS": "-DVEC_VLEN=128"},
                "vec_state_test": {"EXTRA_CFLAGS": "-DVEC_VLEN=128 -DVEC_ADVERTISE=1"},
            },
        ),
        (
            "x3",
            ["--vlen", "512", "--no-vec-advertise"],
            ["vec_integer_test", "vec_state_test"],
            {
                "vec_integer_test": {"EXTRA_CFLAGS": "-DVEC_VLEN=512"},
                "vec_state_test": {"EXTRA_CFLAGS": "-DVEC_VLEN=512 -DVEC_ADVERTISE=0"},
            },
        ),
        (
            "x3",
            ["--vlen", "0"],
            ["vec_state_test"],
            {"vec_state_test": {"EXTRA_CFLAGS": "-DVEC_VLEN=0 -DVEC_ADVERTISE=0"}},
        ),
        (
            "vcu118",
            [],
            ["vec_state_test"],
            {"vec_state_test": {"EXTRA_CFLAGS": "-DVEC_VLEN=0 -DVEC_ADVERTISE=0"}},
        ),
        (
            "vcu118",
            ["--vlen", "0"],
            ["vec_state_test"],
            {"vec_state_test": {"EXTRA_CFLAGS": "-DVEC_VLEN=0 -DVEC_ADVERTISE=0"}},
        ),
        (
            "vcu118",
            ["--vlen", "256", "--vec-advertise"],
            ["vec_state_test"],
            {"vec_state_test": {"EXTRA_CFLAGS": "-DVEC_VLEN=256 -DVEC_ADVERTISE=1"}},
        ),
    ],
)
def test_regression_vector_options_reach_loader_make_vars(
    monkeypatch: pytest.MonkeyPatch,
    board: str,
    extra_args: list[str],
    stages: list[str],
    expected_make_vars: dict[str, dict[str, str]],
) -> None:
    """hw_regression.py forwards vector flags into load_software.py make_vars."""
    seen_make_vars: dict[str, dict[str, str]] = {}

    def fake_compile(*args: Any, **kwargs: Any) -> bool:
        seen_make_vars[args[0]] = dict(args[4])
        return True

    def fake_run_stage(
        _repo: Path,
        _serial_fd: int,
        selected_board: str,
        stage: Any,
        _timeout_s: float,
        loader_extra: list[str],
        target: str,
        _loader_env: Any = None,
    ) -> dict[str, Any]:
        cmd = [
            "./fpga/load_software/load_software.py",
            selected_board,
            stage.app,
            "--target",
            target,
            *loader_extra,
            "--build-only",
        ]
        with monkeypatch.context() as invocation:
            invocation.setattr(sys, "argv", cmd)
            load_software.main()
        return {"stage": stage.app, "status": "PASS", "elapsed": 0.0, "note": ""}

    monkeypatch.delenv("FROST_CPU_CLK_HZ", raising=False)
    monkeypatch.delenv("EXTRA_CFLAGS", raising=False)
    monkeypatch.setattr(load_software, "compile_app_for_board", fake_compile)
    monkeypatch.setattr(load_software, "validate_prebuilt_app", lambda *a, **k: {})
    monkeypatch.setattr(
        load_software, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )
    monkeypatch.setattr(hw, "serial_holders", lambda _serial: [])
    monkeypatch.setattr(
        hw, "configure_serial", lambda _serial: os.open(os.devnull, os.O_RDONLY)
    )
    monkeypatch.setattr(hw, "run_uart_stage", fake_run_stage)
    monkeypatch.setattr(
        sys,
        "argv",
        ["runner", "--board", board, "--serial", "test", *extra_args, *stages],
    )
    assert hw.main() == 0
    assert seen_make_vars == expected_make_vars


@pytest.mark.parametrize(
    "argv,reason",
    [
        (
            ["--board", "x3", "--vlen", "0", "--vec-advertise", "vec_state_test"],
            "--vec-advertise requires a nonzero --vlen",
        ),
        (
            ["--board", "x3", "--vlen", "0", "vec_fp_test"],
            "--vlen 0 cannot run vector-unit stages: vec_fp_test",
        ),
        (
            ["--board", "x3", "--vlen", "0", "vec_arith_test", "vec_state_test"],
            "--vlen 0 cannot run vector-unit stages: vec_arith_test",
        ),
        (
            ["--board", "vcu118", "--vec-advertise", "vec_state_test"],
            "--vec-advertise requires a nonzero --vlen",
        ),
        (
            [
                "--board",
                "x3",
                "--vlen",
                "128",
                "--loader-extra=--vlen=256",
                "vec_state_test",
            ],
            "--vlen cannot also be passed through --loader-extra",
        ),
        (
            [
                "--board",
                "x3",
                "--vec-advertise",
                "--loader-extra=--no-vec-advertise",
                "vec_state_test",
            ],
            "--vec-advertise/--no-vec-advertise cannot also be passed",
        ),
    ],
)
def test_regression_rejects_invalid_vector_options_before_board_access(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    argv: list[str],
    reason: str,
) -> None:
    """Conflicting or impossible vector options fail before serial or Linux checks."""
    monkeypatch.setattr(hw.sys, "argv", ["runner", *argv])
    monkeypatch.setattr(
        hw, "serial_holders", lambda *args: pytest.fail("serial preflight started")
    )
    monkeypatch.setattr(
        hw, "linux_root_from_env", lambda: pytest.fail("Linux preflight started")
    )
    with pytest.raises(SystemExit) as rejected:
        hw.main()
    assert rejected.value.code == 2
    assert reason in capsys.readouterr().err


def test_ecc_stage_verdict_follows_the_script_exit(monkeypatch: Any) -> None:
    """A clean report passes; a dirty one fails and carries its reasons."""
    calls: list[list[str]] = []
    reply: dict[str, Any] = {"returncode": 0, "stdout": ""}

    def fake_run(command: list[str], **kwargs: Any) -> Any:
        calls.append(command)
        return SimpleNamespace(
            returncode=reply["returncode"], stdout=reply["stdout"], stderr=""
        )

    monkeypatch.setattr(hw.subprocess, "run", fake_run)

    reply["stdout"] = "Clean: no ECC error has been reported since the last clear.\n"
    result = hw.run_ecc_stage(ROOT, "x3", "some:target", 60.0)
    assert result["status"] == "PASS" and result["stage"] == hw.ECC_STAGE
    assert result["note"] == ""
    # The runner's target is a pattern, as the loader stages take it, so an
    # index or a serial substring keeps working for this stage too.
    assert "--target" in calls[0] and "some:target" in calls[0]
    assert "--target-exact" not in calls[0]

    reply["returncode"] = hw.ECC_DIRTY_EXIT
    reply["stdout"] = (
        "DDR4 ECC state (read over hw_axi_1):\n"
        "Not clean: an uncorrectable error is latched in ECC_STATUS\n"
        "Not clean: CE_CNT is 3\n"
    )
    result = hw.run_ecc_stage(ROOT, "x3", "some:target", 60.0)
    assert result["status"] == "FAIL"
    assert "uncorrectable" in result["note"] and "CE_CNT is 3" in result["note"]

    # A read that failed is not a clean report either.
    reply["returncode"] = 1
    reply["stdout"] = "ECC read failed: missing final FROST_ECC_DONE line\n"
    result = hw.run_ecc_stage(ROOT, "x3", "some:target", 60.0)
    assert result["status"] == "FAIL"
    assert "missing final FROST_ECC_DONE line" in result["note"]


def test_uart_echo_stage_keeps_its_single_probe() -> None:
    """uart_echo types its one probe at the prompt."""
    echo = hw.build_stage("uart_echo", "x3", 1.0)
    assert echo.stimuli == ((hw.ECHO_PROMPT, hw.ECHO_PROBE + "\r"),)
    assert hw.next_stimulus(echo, "boot\r\nfrost> ", 0, 0) == (
        hw.ECHO_PROBE + "\r",
        len("boot\r\nfrost> "),
    )


def test_cpu_clock_override_reaches_the_loader_and_skips_score_checks() -> None:
    """FROST_CPU_CLK_HZ names a functional-validation bitstream's clock.

    The loader builds apps for it and the regression skips the CoreMark
    full-rate baseline check.
    """
    local = _load_hw_regression()
    rated, overridden = local.board_clock_freq("x3", {})
    assert (rated, overridden) == (322_265_625, False)
    assert local.board_clock_freq("x3", {"FROST_CPU_CLK_HZ": "161132812"}) == (
        161_132_812,
        True,
    )
    with pytest.raises(ValueError):
        local.board_clock_freq("x3", {"FROST_CPU_CLK_HZ": "fast"})
    with pytest.raises(ValueError):
        local.board_clock_freq("x3", {"FROST_CPU_CLK_HZ": "0"})

    baseline = local.BASELINE_SCORES.get("x3", {}).get("coremark")
    if baseline is None:
        pytest.skip("no x3 CoreMark baseline recorded")
    ok, note = local.check_score("x3", "coremark", baseline * 0.4, 5.0)
    assert not ok
    old = dict(local.os.environ)
    try:
        local.os.environ["FROST_CPU_CLK_HZ"] = "161132812"
        ok, note = local.check_score("x3", "coremark", baseline * 0.4, 5.0)
        assert ok
        assert "clock override" in note
    finally:
        local.os.environ.clear()
        local.os.environ.update(old)


def test_counters_absent_stage_runs_at_every_clock(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Accept perf_off_test under a clock override.

    Profiling counters default off at every clock. An unknown stage alongside
    perf_off_test must be the only rejected name.
    """
    assert "perf_off_test" in hw.valid_apps_for_board("x3")
    assert "perf_off_test" in hw.regression_stages("x3")
    monkeypatch.setenv("FROST_CPU_CLK_HZ", "161132812")
    monkeypatch.setattr(
        hw.sys,
        "argv",
        ["hw_regression.py", "--board", "x3", "perf_off_test", "no_such_stage"],
    )
    with pytest.raises(SystemExit) as rejected:
        hw.main()
    assert rejected.value.code == 2
    err = capsys.readouterr().err
    assert "unknown stage(s): no_such_stage\n" in err
    assert "perf_off_test" in err.split("valid stages:", 1)[1]


# --- The network test's diagnostic repetitions ---------------------------------

# The default command runs once with the root interface passed to the test.
NETTEST_COMMAND_ETH0 = (
    "m=$(cat /sys/class/net/eth0/mtu); f=$(cat /sys/class/net/eth0/flags); "
    "echo 1 > /proc/sys/net/ipv6/conf/eth0/disable_ipv6; "
    "cp /usr/local/bin/frost_nettest /dev/shm/; "
    "{ if echo 2 > /proc/sys/vm/drop_caches; then "
    "FROST_NETTEST_EXPIRE_NFS_CACHE=1 /dev/shm/frost_nettest eth0; "
    "else echo FROST_NET_LOOPBACK'_'FAIL drop_caches; fi; "
    "echo $m >&3; echo $f >&4; echo 0 >&5; } "
    "3> /sys/class/net/eth0/mtu 4> /sys/class/net/eth0/flags "
    "5> /proc/sys/net/ipv6/conf/eth0/disable_ipv6; "
    'timeout -k 5 120 sh -c "echo frost > /root/.frost_alive && sync && '
    'rm -f /root/.frost_alive"; echo FROST_ROOT_ALIVE=$?'
)

# A stand-in for frost_nettest that prints what the real one prints for a
# repetition: the repetition line, then its verdict under the marker the
# repetition gets. FAKE_FAIL_REP names a repetition that fails.
FAKE_NETTEST = r"""#!/bin/sh
if [ "$#" != 1 ]; then exit 1; fi
if [ -n "$FROST_NETTEST_REPETITION" ]; then
  rep=${FROST_NETTEST_REPETITION%/*}
  reps=${FROST_NETTEST_REPETITION#*/}
  echo "FROST_NET_LOOPBACK: repetition $rep of $reps"
else rep=1; reps=1; fi
echo "FROST_NET_LOOPBACK: $1: driver frost_net10g, address 02:11:22:33:44:55"
echo "FROST_NET_LOOPBACK: capture idle-jumbo t=70100..70300: own out 0 in 0, kernel out 1 in 1, foreign 2, enetdown 1, drops 0"
if [ "$rep" -lt "$reps" ]; then marker=FROST_NET_DIAG; tag=" rep=$rep"; else marker=FROST_NET_LOOPBACK; tag=; fi
if [ "$rep" = "${FAKE_FAIL_REP:-0}" ]; then
  echo "${marker}_FAIL$tag statistics before jumbo traffic: tx +1 rx +1 rxerr +0 txerr +0 with nothing sent"
else
  echo "${marker}_PASS$tag"
fi
"""


def test_without_the_repeat_variable_the_command_is_unchanged() -> None:
    """The stage types today's single-run command byte for byte."""
    assert hw.nettest_command("eth0") == NETTEST_COMMAND_ETH0
    assert hw.nettest_command("eth0", 1) == NETTEST_COMMAND_ETH0
    assert hw.nettest_repeat({}) == 1
    assert hw.nettest_repeat({hw.NETTEST_REPEAT_ENV: ""}) == 1
    assert stage().stimuli[-1][1] == NETTEST_COMMAND_ETH0 + "\r"


@pytest.mark.parametrize("text", ["0", "-1", "two", "2.5", "21"])
def test_a_bad_repeat_count_is_refused(text: str) -> None:
    """Only a whole number from 1 to the maximum is accepted."""
    with pytest.raises(ValueError, match=hw.NETTEST_REPEAT_ENV):
        hw.nettest_repeat({hw.NETTEST_REPEAT_ENV: text})
    assert hw.nettest_repeat({hw.NETTEST_REPEAT_ENV: " 4 "}) == 4


def test_the_repeated_command_carries_no_marker_and_types_once() -> None:
    """The repeated command is one typed line holding no marker itself."""
    command = hw.nettest_command("eth0", 3)
    for marker in (
        hw.LINUX_NET_TOKEN,
        hw.LINUX_NET_TOKEN_FAIL,
        "FROST_NET_DIAG_PASS",
        "FROST_NET_DIAG_FAIL",
    ):
        assert marker not in command
    assert not hw.LINUX_NET_DIAG_RE.search(command + "\r\n")
    assert hw.root_alive_status(command + "\r\n") is None
    assert "FROST_NETTEST_REPETITION=$r/3 FROST_NETTEST_EXPIRE_NFS_CACHE=1" in command
    linux = hw.linux_stage(ROOT, 3, isa_run_id=ISA_RUN_ID)
    assert linux.stimuli[-1][1] == hw.nettest_command(ROOT.interface, 3) + "\r"
    assert linux.stimuli[:-1] == stage().stimuli[:-1]


def _run_repeated(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    repeat: int,
    fail_rep: int = 0,
    drop_caches_fails: bool = False,
    alive_status: int = 0,
    poke_s: int = 0,
    interface: str = "eth0",
) -> tuple[str, Path, Path]:
    """Run the repeated command in sh against stand-in files and programs."""
    sysfs = tmp_path / "sysfs"
    sysfs.mkdir()
    (sysfs / "mtu").write_text("1500\n")
    (sysfs / "flags").write_text("0x1003\n")
    ipv6 = tmp_path / "disable_ipv6"
    ipv6.write_text("0\n")
    drop = tmp_path / "drop_caches"
    if drop_caches_fails:
        drop.mkdir()
    source = tmp_path / "bin"
    target = tmp_path / "shm"
    source.mkdir()
    target.mkdir()
    program = source / "frost_nettest"
    program.write_text(FAKE_NETTEST)
    program.chmod(0o755)
    timeout = source / "timeout"
    # The poke's timeout runs long in the background; the root check's exits
    # with the status asked for.
    timeout.write_text(
        "#!/bin/sh\n"
        'case "$*" in *frost_poke*) exec sleep 5;; esac\n'
        f"exit {alive_status}\n"
    )
    timeout.chmod(0o755)
    monkeypatch.setenv("PATH", f"{source}:{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_FAIL_REP", str(fail_rep))
    monkeypatch.setattr(hw, "LINUX_ROOT_BIN", str(source))
    monkeypatch.setattr(hw, "LINUX_TMPFS", str(target))
    command = (
        hw.nettest_command(interface, repeat, poke_s)
        .replace(f"/sys/class/net/{interface}", str(sysfs))
        .replace(f"/proc/sys/net/ipv6/conf/{interface}/disable_ipv6", str(ipv6))
        .replace("/proc/sys/vm/drop_caches", str(drop))
    )
    done = hw.subprocess.run(
        ["sh", "-c", command], check=True, capture_output=True, text=True, timeout=20
    )
    # The restore ran after every repetition.
    assert (sysfs / "mtu").read_text() == "1500\n"
    assert (sysfs / "flags").read_text() == "0x1003\n"
    assert ipv6.read_text() == "0\n"
    return done.stdout.replace("\n", "\r\r\n"), sysfs, ipv6


@pytest.mark.parametrize("repeat", [1, 3])
def test_vcu118_linux_loopback_exercises_the_rj45_root_interface(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, repeat: int
) -> None:
    """Pass eth1 to the executable and require each run to report that interface."""
    root = dataclasses.replace(
        ROOT, interface="eth1", ip=ROOT.ip.replace("eth0", "eth1")
    )
    linux = hw.linux_stage(root, repeat, board="vcu118", isa_run_id=ISA_RUN_ID)
    output, _, _ = _run_repeated(
        tmp_path, monkeypatch, repeat, interface=root.interface
    )
    before_loopback = SUPM_TRANSCRIPT.replace(
        "active=1 polls=4113,5342", "active=0 polls=0,0"
    )
    transcript = (
        before_loopback + hw.nettest_command(root.interface, repeat) + "\r\r\n" + output
    )
    assert output.count("eth1: driver frost_net10g") == repeat
    ok, note = linux.judge(transcript)
    assert ok, note
    ok, note = linux.judge(transcript.replace("eth1: driver", "eth0: driver", 1))
    assert not ok
    assert f"expected {repeat} run(s) on eth1, found eth0" in note


def test_every_repetition_is_logged_and_only_the_last_ends_the_capture(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Earlier repetitions report under FROST_NET_DIAG; a failed one fails the stage."""
    output, _, _ = _run_repeated(tmp_path, monkeypatch, 3, fail_rep=2)
    lines = output.split("\r\r\n")
    assert [line for line in lines if "repetition" in line] == [
        f"FROST_NET_LOOPBACK: repetition {rep} of 3" for rep in (1, 2, 3)
    ]
    assert "FROST_NET_DIAG_PASS rep=1" in lines
    assert lines.count("FROST_ROOT_ALIVE=0") == 3
    assert hw.nettest_diag_verdicts(output) == {
        1: ("PASS", ""),
        2: (
            "FAIL",
            "statistics before jumbo traffic: tx +1 rx +1 rxerr +0 txerr +0 "
            "with nothing sent",
        ),
    }
    linux = hw.linux_stage(ROOT, 3, isa_run_id=ISA_RUN_ID)
    echo = hw.nettest_command(ROOT.interface, 3) + "\r\r\n"
    # Nothing before the last repetition's lines ends the capture.
    last = output.index("FROST_NET_LOOPBACK: repetition 3 of 3")
    early = SUPM_TRANSCRIPT + echo + output[:last]
    assert not linux.failure_done(early) and not linux.success_done(early)
    transcript = SUPM_TRANSCRIPT + echo + output + PROMPT
    assert linux.success_done(transcript) and not linux.failure_done(transcript)
    ok, note = linux.judge(transcript)
    assert not ok
    assert "repetition 2: statistics before jumbo traffic: tx +1 rx +1" in note


def test_all_repetitions_passing_pass_the_stage(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The note says how many times the test ran."""
    output, _, _ = _run_repeated(tmp_path, monkeypatch, 3)
    linux = hw.linux_stage(ROOT, 3, isa_run_id=ISA_RUN_ID)
    transcript = (
        SUPM_TRANSCRIPT + hw.nettest_command(ROOT.interface, 3) + "\r\r\n" + output
    )
    ok, note = linux.judge(transcript + PROMPT)
    assert ok, note
    assert "frost_nettest 3 times, root alive" in note
    # The last pass does not end the capture before its own root check: an
    # earlier repetition's status does not stand in for it.
    cut = transcript[: transcript.rindex("FROST_ROOT_ALIVE=0")]
    assert cut.endswith(hw.LINUX_NET_TOKEN + "\r\r\n")
    assert not linux.success_done(cut) and not linux.failure_done(cut)
    # A repetition that printed no verdict is not passed over.
    missing = transcript.replace("FROST_NET_DIAG_PASS rep=2\r\r\n", "")
    ok, note = linux.judge(missing + PROMPT)
    assert not ok and "repetition 2: no verdict" in note


def test_a_failing_last_repetition_reports_the_earlier_ones(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The last repetition's FAIL ends the capture; the note lists the others."""
    output, _, _ = _run_repeated(tmp_path, monkeypatch, 2, fail_rep=2)
    linux = hw.linux_stage(ROOT, 2, isa_run_id=ISA_RUN_ID)
    transcript = (
        SUPM_TRANSCRIPT + hw.nettest_command(ROOT.interface, 2) + "\r\r\n" + output
    )
    assert linux.failure_done(transcript)
    ok, note = linux.judge(transcript)
    assert not ok and hw.LINUX_NET_TOKEN_FAIL in note
    assert "repetitions before the last: 1 PASS" in note


def test_a_failed_cache_drop_is_reported_per_repetition(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Earlier repetitions report a failed cache drop under FROST_NET_DIAG."""
    output, _, _ = _run_repeated(tmp_path, monkeypatch, 2, drop_caches_fails=True)
    assert "FROST_NET_DIAG_FAIL rep=1 drop_caches\r\r\n" in output
    assert output.endswith(
        f"{hw.LINUX_NET_TOKEN_FAIL} drop_caches\r\r\nFROST_ROOT_ALIVE=0\r\r\n"
    )
    assert "repetition" not in output  # the program never ran


def test_a_root_that_does_not_come_back_ends_the_repetitions(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """No later repetition runs on a root that is not back."""
    output, _, _ = _run_repeated(tmp_path, monkeypatch, 3, alive_status=124)
    assert output.count("repetition") == 1
    assert output.endswith("FROST_ROOT_ALIVE=124\r\r\n")
    transcript = SUPM_TRANSCRIPT + hw.nettest_command(ROOT.interface, 3) + output
    assert hw.linux_stage(ROOT, 3, isa_run_id=ISA_RUN_ID).failure_done(transcript)


def test_the_rest_of_a_failure_line_is_read() -> None:
    """A failure that ends the capture mid-line still gets its whole line."""
    read_end, write_end = os.pipe()
    try:
        os.set_blocking(read_end, False)
        head = f"{hw.LINUX_NET_TOKEN_FAIL} statistics before jumbo traffic: tx +1 r"
        rest = "x +1 rxerr +0 txerr +0 with nothing sent\r\r\nFROST_ROOT_ALIVE=0\r\r\n"

        def write_later() -> None:
            os.write(write_end, rest[:20].encode())
            threading.Event().wait(0.2)
            os.write(write_end, rest[20:].encode())

        writer = threading.Thread(target=write_later)
        writer.start()
        text = hw.finish_line(read_end, head, 5.0)
        writer.join()
        assert (head + text).startswith(
            head + "x +1 rxerr +0 txerr +0 with nothing sent"
        )
        assert (head + text).endswith("\n")
        # A complete line needs nothing more; a silent line gives up in time.
        assert hw.finish_line(read_end, "done\r\n", 5.0) == ""
        assert hw.finish_line(read_end, "cut", 0.3) == ""
    finally:
        os.close(read_end)
        os.close(write_end)
    assert hw.linux_stage(ROOT).failure_line_grace_s == hw.LINUX_FAILURE_LINE_GRACE_S


NETTEST_SOURCE = (
    REPO_ROOT / "linux/buildroot-external/package/frost-stress/src/frost_nettest.c"
)


def test_frost_nettest_decoder_self_test_and_markers(tmp_path: Path) -> None:
    """Build frost_nettest natively and run its frame decoder's self-test.

    Then run it as repetition 1 of 2 on a host without the driver: its
    verdict comes out under the diagnostic marker the stage reads.
    """
    compiler = next(
        (hw.shutil.which(name) for name in ("cc", "gcc") if hw.shutil.which(name)), None
    )
    if compiler is None:
        pytest.skip("no native C compiler")
    binary = tmp_path / "frost_nettest"
    built = hw.subprocess.run(
        [compiler, "-O2", "-Wall", "-Wextra", "-o", str(binary), str(NETTEST_SOURCE)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if (
        built.returncode != 0
        and "linux/" in built.stderr
        and "No such file" in built.stderr
    ):
        pytest.skip("no Linux kernel headers for a native build")
    assert built.returncode == 0, built.stderr
    assert "warning" not in built.stderr, built.stderr
    done = hw.subprocess.run(
        [str(binary), "--selftest"], capture_output=True, text=True, timeout=30
    )
    assert done.returncode == 0, done.stdout
    assert done.stdout.endswith("FROST_NET_SELFTEST_PASS\n")
    for case in (
        "arp-request",
        "vlan-arp",
        "tcp-psh-ack",
        "udp",
        "duplicate-1514-in",
        "stale-test-frame",
        "other-run",
    ):
        assert f"FROST_NET_SELFTEST {case} " in done.stdout
    # The window accounting: a looped kernel ARP request in an idle window
    # passes; an in-only frame, a stale test frame, a dropped capture and
    # unexplained counts each fail with their own reason.
    for case, verdict in (
        ("idle-arp-looped", "pass"),
        ("idle-arp-twice", "pass"),
        ("traffic-arp-exact", "pass"),
        ("idle-in-only", "1 received frames match no frame sent"),
        ("idle-changed-copy", "match no frame sent"),
        ("idle-not-looped", "1 of 1 kernel frames not looped back"),
        ("idle-stale-test-frame", "stale test frame seq=2990"),
        ("idle-capture-dropped", "1 frames dropped"),
        ("idle-unexplained", "tx +1 rx +1 rxerr +0 txerr +0 with nothing sent"),
        ("traffic-one-extra", "for 600 frames and 2 kernel frames"),
        ("idle-down-dropped", "pass"),
        ("idle-down-not-dropped", "not looped back (tx_dropped +0)"),
        ("idle-dropped-without-down", "not looped back (tx_dropped +1)"),
        ("idle-unicast-not-back", "pass"),
        ("idle-unicast-came-back", "came back through the receive filter"),
        ("idle-offloaded-checksum", "offloaded checksum cannot be compared"),
        ("idle-segmentation-offload", "segmentation offload cannot be accounted"),
    ):
        line = next(
            line
            for line in done.stdout.splitlines()
            if line.startswith(f"FROST_NET_SELFTEST {case}: ")
        )
        assert verdict in line, line
    # No such interface here: the run fails at once, under the DIAG marker.
    diag = hw.subprocess.run(
        [str(binary), "frost-no-such-if"],
        capture_output=True,
        text=True,
        timeout=30,
        env={**os.environ, "FROST_NETTEST_REPETITION": "1/2"},
    )
    assert diag.returncode == 1
    output = diag.stdout.replace("\n", "\r\r\n")
    assert "FROST_NET_LOOPBACK: repetition 1 of 2\r\r\n" in output
    verdicts = hw.nettest_diag_verdicts(output)
    assert list(verdicts) == [1] and verdicts[1][0] == "FAIL"
    assert hw.LINUX_NET_TOKEN_FAIL not in output


def test_without_the_poke_variable_the_command_is_unchanged() -> None:
    """No poke unless asked: both command forms stay as they were."""
    assert hw.nettest_poke({}) == 0
    assert hw.nettest_poke({hw.NETTEST_POKE_ENV: " "}) == 0
    assert hw.nettest_command("eth0", 1, 0) == NETTEST_COMMAND_ETH0
    assert hw.nettest_command("eth0", 3, 0) == hw.nettest_command("eth0", 3)
    assert "frost_poke" not in hw.nettest_command("eth0", 3)
    assert hw.linux_stage(ROOT, 1, 0, isa_run_id=ISA_RUN_ID).stimuli == stage().stimuli


@pytest.mark.parametrize("text", ["0", "-5", "x", "1.5", "301"])
def test_a_bad_poke_delay_is_refused(text: str) -> None:
    """Only whole seconds from 1 to the maximum are accepted."""
    with pytest.raises(ValueError, match=hw.NETTEST_POKE_ENV):
        hw.nettest_poke({hw.NETTEST_POKE_ENV: text})
    assert hw.nettest_poke({hw.NETTEST_POKE_ENV: "30"}) == 30


def test_the_poke_is_scheduled_before_each_test_run_and_does_not_block(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """One poke per repetition, after the cache drop, detached from the test."""
    single = hw.nettest_command("eth0", 1, 30)
    head, _, rest = single.partition("then ")
    assert NETTEST_COMMAND_ETH0.startswith(head + "then ")
    assert rest.startswith(
        '( timeout -k 5 330 sh -c "sleep 30; [ -e /root/.frost_poke.$$ ]" '
        "> /dev/null 2>&1 3>&- 4>&- 5>&- & ); "
        "echo FROST_NET_DIAG: nfs poke scheduled at +30 s; "
        "FROST_NETTEST_EXPIRE_NFS_CACHE=1 "
    )
    assert single.replace(rest[: rest.index("FROST_NETTEST_EXPIRE")], "") == (
        NETTEST_COMMAND_ETH0
    )
    repeated = hw.nettest_command("eth0", 3, 30)
    assert repeated.count("frost_poke") == 1 and "/root/.frost_poke.$$.$r" in repeated
    assert not hw.LINUX_NET_DIAG_RE.search(repeated + "\r\n")
    linux = hw.linux_stage(ROOT, 3, 30, isa_run_id=ISA_RUN_ID)
    assert linux.stimuli[-1][1] == repeated.replace("eth0", ROOT.interface) + "\r"

    started = time.monotonic()
    output, _, _ = _run_repeated(tmp_path, monkeypatch, 3, poke_s=30)
    # Each poke's stand-in sleeps 5 s in the background; nothing waits for it.
    assert time.monotonic() - started < 4
    lines = output.split("\r\r\n")
    scheduled = "FROST_NET_DIAG: nfs poke scheduled at +30 s"
    assert lines.count(scheduled) == 3
    for rep in (1, 2, 3):
        at = lines.index(f"FROST_NET_LOOPBACK: repetition {rep} of 3")
        assert lines[at - 1] == scheduled
    transcript = SUPM_TRANSCRIPT + repeated + "\r\r\n" + output
    ok, note = linux.judge(transcript + PROMPT)
    assert ok, note


# ---------------------------------------------------------------------------
# The initramfs driver version (system tools: unmkinitramfs and modinfo)
# ---------------------------------------------------------------------------


def test_the_tree_defines_one_driver_version() -> None:
    """The source's MODULE_VERSION and the DKMS package version are the same."""
    dkms = (REPO_ROOT / "linux/frost-net10g/dkms.conf").read_text()
    package = re.search(r'^PACKAGE_VERSION="([^"]+)"', dkms, re.MULTILINE)
    assert package is not None
    assert _driver_version() == package.group(1)


@pytest.mark.parametrize("suffix", ["", ".xz", ".zst", ".gz"])
def test_a_matching_driver_version_passes_for_every_supported_suffix(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, suffix: str
) -> None:
    """Each kernel-loadable suffix passes, args are fixed, and tmpdir is removed."""
    good = _driver_version()
    rel = MODULE_PATH + suffix
    tool_dir = _install_initrd_tools(
        tmp_path,
        monkeypatch,
        files={
            "early/kernel/x86/microcode/test.bin": "ucode",
            f"main/{rel}": "stub-ko",
            "main/init": "#!/bin/sh\n",
        },
        modinfo_versions={"*": f"{good}\n"},
    )
    image = tmp_path / "initrd.img"
    image.write_bytes(b"stub-initrd")
    notes = hw.check_initrd_driver_version(image, REPO_ROOT)
    assert notes == [
        f"the initramfs carries frost_net10g version {good} "
        "(checked: the early section and the first compressed archive)"
    ]
    unmk_calls = _tool_calls(tool_dir, "unmkinitramfs")
    assert len(unmk_calls) == 1
    assert unmk_calls[0][0] == str(image.resolve())
    tmpdir = Path(unmk_calls[0][1])
    assert not tmpdir.exists(), "temporary unpack directory was not removed"
    modinfo_calls = _tool_calls(tool_dir, "modinfo")
    assert modinfo_calls == [["-F", "version", str(tmpdir / "main" / rel)]]


def test_a_stale_driver_fails_the_preflight_before_any_stage(
    prepared: tuple[Any, dict[str, str]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The message names the file, both versions, and the rebuild; nothing installs."""
    root, environment = prepared
    tool_dir = _install_initrd_tools(
        tmp_path,
        monkeypatch,
        files={MODULE_PATH + ".xz": "stub-ko"},
        modinfo_versions={"*": "0.9\n"},
    )
    monkeypatch.setattr(
        hw, "install_root_programs", lambda *a: pytest.fail("installed programs")
    )
    with pytest.raises(hw.LinuxEnvironmentError) as stale:
        hw.linux_root_preflight(root, REPO_ROOT, environment)
    message = str(stale.value)
    assert message.startswith(hw.ENV_NOT_READY)
    assert MODULE_PATH + ".xz" in message
    assert "version 0.9" in message and f"version {_driver_version()}" in message
    assert "docs/debian_nfsroot.md" in message and "update-initramfs" in message
    tmpdir = Path(_tool_calls(tool_dir, "unmkinitramfs")[0][1])
    assert not tmpdir.exists()


def test_a_stale_driver_is_an_env_fail_for_the_cli(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    """main() stops before the first stage, or records ENV_FAIL with --keep-going."""
    seen = _stub_board(monkeypatch)
    export = _fake_export(tmp_path)
    root = _fake_root(export)
    _install_initrd_tools(
        tmp_path,
        monkeypatch,
        files={MODULE_PATH + ".xz": "stub-ko"},
        modinfo_versions={"*": "0.9\n"},
    )
    _, environment = _fake_cross(tmp_path)
    monkeypatch.setattr(hw, "probe_nfs3_tcp", lambda *a, **k: None)
    monkeypatch.setattr(hw, "linux_root_from_env", lambda: root)
    for name, value in environment.items():
        monkeypatch.setenv(name, value)
    argv = ["hw_regression.py", "--board", "x3", "linux_boot"]
    monkeypatch.setattr(hw.sys, "argv", argv)
    assert hw.main() == 1
    assert not seen
    err = capsys.readouterr().err
    assert "version 0.9" in err and f"version {_driver_version()}" in err
    monkeypatch.setattr(hw.sys, "argv", [*argv, "--keep-going"])
    assert hw.main() == 1
    assert not seen
    captured = capsys.readouterr()
    assert hw.ENV_FAIL_STATUS in captured.out and "version 0.9" in captured.err


def test_every_unpacked_copy_must_match_the_tree_version(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Multiple copies pass only if every copy matches; any stale copy fails."""
    good = _driver_version()
    first = "early/lib/modules/6.12/updates/dkms/frost_net10g.ko"
    second = "main/usr/lib/modules/6.12/updates/dkms/frost_net10g.ko.xz"
    image = tmp_path / "initrd.img"
    image.write_bytes(b"stub")

    # Both copies match -> PASS.
    tool_dir = _install_initrd_tools(
        tmp_path,
        monkeypatch,
        files={first: "ko1", second: "ko2"},
        modinfo_versions={first: f"{good}\n", second: f"{good}\n"},
    )
    assert hw.check_initrd_driver_version(image, REPO_ROOT)
    assert len(_tool_calls(tool_dir, "modinfo")) == 2
    assert not Path(_tool_calls(tool_dir, "unmkinitramfs")[-1][1]).exists()

    # First copy stale, second current -> FAIL naming first copy and both versions.
    _install_initrd_tools(
        tmp_path,
        monkeypatch,
        files={first: "ko1", second: "ko2"},
        modinfo_versions={first: "0.8\n", second: f"{good}\n"},
    )
    with pytest.raises(hw.LinuxEnvironmentError) as err1:
        hw.check_initrd_driver_version(image, REPO_ROOT)
    assert (
        first in str(err1.value)
        and "0.8" in str(err1.value)
        and good in str(err1.value)
    )

    # First copy current, second stale -> FAIL naming second copy and both versions.
    _install_initrd_tools(
        tmp_path,
        monkeypatch,
        files={first: "ko1", second: "ko2"},
        modinfo_versions={first: f"{good}\n", second: "0.9\n"},
    )
    with pytest.raises(hw.LinuxEnvironmentError) as err2:
        hw.check_initrd_driver_version(image, REPO_ROOT)
    assert (
        second in str(err2.value)
        and "0.9" in str(err2.value)
        and good in str(err2.value)
    )


def test_only_the_supported_module_file_names_count(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Backup names, non-regular entries, and directory symlinks cannot fool the check."""
    good = _driver_version()
    image = tmp_path / "initrd.img"
    image.write_bytes(b"stub")

    # Lookalike filenames and a directory named frost_net10g.ko are not modules.
    _install_initrd_tools(
        tmp_path,
        monkeypatch,
        files={
            MODULE_PATH + ".bak": "stub",
            MODULE_PATH + ".lz4": "stub",
            MODULE_PATH + ".bz2": "stub",
            MODULE_PATH + ".orig": "stub",
            "usr/lib/modules/6.12/other_frost_net10g.ko": "stub",
        },
        dirs={"usr/lib/modules/6.12/frost_net10g.ko": 0o755},
        modinfo_versions={"*": f"{good}\n"},
    )
    with pytest.raises(hw.LinuxEnvironmentError, match="carries no frost_net10g"):
        hw.check_initrd_driver_version(image, REPO_ROOT)

    # A stale backup name does not block a current module, and a usrmerge dir
    # symlink (lib -> usr/lib) is not followed.
    tool_dir = _install_initrd_tools(
        tmp_path,
        monkeypatch,
        files={MODULE_PATH + ".bak": "stale", MODULE_PATH: "current"},
        symlinks={"lib": "usr/lib"},
        modinfo_versions={MODULE_PATH + ".bak": "0.9\n", MODULE_PATH: f"{good}\n"},
    )
    assert hw.check_initrd_driver_version(image, REPO_ROOT)
    assert len(_tool_calls(tool_dir, "modinfo")) == 1

    # A symlink named frost_net10g.ko (file target, broken target, or dir target)
    # is rejected fail-closed rather than followed.
    external = tmp_path / "host_decoy.ko"
    external.write_text("host-file")
    for link_target in (str(external), "missing_target", str(tmp_path)):
        _install_initrd_tools(
            tmp_path,
            monkeypatch,
            files={"init": "x"},
            symlinks={MODULE_PATH: link_target},
            modinfo_versions={"*": f"{good}\n"},
        )
        with pytest.raises(
            hw.LinuxEnvironmentError, match="not a regular|symbolic link"
        ):
            hw.check_initrd_driver_version(image, REPO_ROOT)


@pytest.mark.parametrize(
    "case,tool_name",
    [
        ("missing_unmk", "unmkinitramfs"),
        ("missing_modinfo", "modinfo"),
        ("enoexec_unmk", "unmkinitramfs"),
        ("enoexec_modinfo", "modinfo"),
    ],
)
def test_missing_or_unexecutable_initrd_tools_are_env_fails(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, case: str, tool_name: str
) -> None:
    """A missing or unlaunchable host tool is an ENV_FAIL naming that tool."""
    image = tmp_path / "initrd.img"
    image.write_bytes(b"stub")
    _install_initrd_tools(
        tmp_path,
        monkeypatch,
        unmk_present=(case != "missing_unmk"),
        modinfo_present=(case != "missing_modinfo"),
        unmk_enoexec=(case == "enoexec_unmk"),
        modinfo_enoexec=(case == "enoexec_modinfo"),
    )
    with pytest.raises(hw.LinuxEnvironmentError) as raised:
        hw.check_initrd_driver_version(image, REPO_ROOT)
    message = str(raised.value)
    assert message.startswith(hw.ENV_NOT_READY)
    assert tool_name in message and f"version {_driver_version()}" in message


@pytest.mark.parametrize(
    "case",
    ["nonzero", "non_utf8_stderr", "timeout"],
)
def test_a_failing_or_timed_out_unmkinitramfs_is_an_env_fail(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, case: str
) -> None:
    """Unmkinitramfs errors and timeouts name the tool, clean up, and never crash."""
    export = _fake_export(tmp_path)
    root = _fake_root(export)
    if case == "timeout":
        monkeypatch.setattr(hw, "UNMKINITRAMFS_TIMEOUT_S", 0.3)
    tool_dir = _install_initrd_tools(
        tmp_path,
        monkeypatch,
        unmk_exit=2 if case != "timeout" else 0,
        unmk_stderr=b"bad header \xff\xfe\n"
        if case == "non_utf8_stderr"
        else b"corrupt archive\n",
        unmk_hang=(case == "timeout"),
    )
    with pytest.raises(hw.LinuxEnvironmentError) as raised:
        hw.check_initrd_driver_version(root.initrd, REPO_ROOT)
    message = str(raised.value)
    assert message.startswith(hw.ENV_NOT_READY) and "unmkinitramfs" in message
    if case == "timeout":
        assert "timed out" in message
    else:
        assert "exited 2" in message
    calls = _tool_calls(tool_dir, "unmkinitramfs")
    assert len(calls) == 1 and not Path(calls[0][1]).exists()

    # Also through main() with and without --keep-going (no traceback).
    if case == "nonzero":
        seen = _stub_board(monkeypatch)
        _, environment = _fake_cross(tmp_path)
        monkeypatch.setattr(hw, "probe_nfs3_tcp", lambda *a, **k: None)
        monkeypatch.setattr(hw, "linux_root_from_env", lambda: root)
        for name, value in environment.items():
            monkeypatch.setenv(name, value)
        for extra in ([], ["--keep-going"]):
            monkeypatch.setattr(
                hw.sys,
                "argv",
                ["hw_regression.py", "--board", "x3", "linux_boot", *extra],
            )
            assert hw.main() == 1
        assert not seen


@pytest.mark.parametrize(
    "case,kwargs,expected_fragment",
    [
        (
            "nonzero",
            {"modinfo_exit": 1, "modinfo_stderr": b"ELF error\n"},
            "modinfo exited 1",
        ),
        ("empty", {"modinfo_stdout": b""}, "printed no version"),
        ("blank_newline", {"modinfo_stdout": b"\n"}, "printed no version"),
        ("whitespace_only", {"modinfo_stdout": b"   \n"}, "printed no version"),
        ("multiple_versions", {"modinfo_stdout": b"1.3\n0.9\n"}, "multiple versions"),
        ("no_final_newline", {"modinfo_stdout": b"1.3"}, "did not end with a newline"),
        ("trailing_space", {"modinfo_stdout": b"1.3 \n"}, "version '1.3 '"),
        ("crlf", {"modinfo_stdout": b"1.3\r\n"}, "version '1.3\\r'"),
        ("non_utf8", {"modinfo_stdout": b"\xff\xfe\n"}, "version "),
        (
            "huge_version",
            {"modinfo_stdout": b"v" * 200_000 + b"\n"},
            "200000 chars",
        ),
        (
            "many_lines",
            {"modinfo_stdout": b"0.9\n" * 1000},
            "1000 lines total",
        ),
        (
            "escaped_ansi_version",
            {"modinfo_stdout": b"\x1b[31m0.9\x1b[0m\n"},
            "\\x1b[31m0.9\\x1b[0m",
        ),
        ("timeout", {"modinfo_hang": True}, "modinfo timed out"),
    ],
)
def test_a_failing_lying_or_timed_out_modinfo_is_an_env_fail(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    case: str,
    kwargs: dict[str, Any],
    expected_fragment: str,
) -> None:
    """Every modinfo failure mode fails closed, names tool/file, and cleans tmpdir."""
    image = tmp_path / "initrd.img"
    image.write_bytes(b"stub")
    if case == "timeout":
        monkeypatch.setattr(hw, "MODINFO_TIMEOUT_S", 0.3)
    tool_dir = _install_initrd_tools(
        tmp_path, monkeypatch, files={MODULE_PATH: "stub-ko"}, **kwargs
    )
    with pytest.raises(hw.LinuxEnvironmentError) as raised:
        hw.check_initrd_driver_version(image, REPO_ROOT)
    message = str(raised.value)
    assert message.startswith(hw.ENV_NOT_READY)
    assert expected_fragment in message
    assert len(message) < 1000, f"unbounded message length: {len(message)}"
    assert "\x1b" not in message
    assert MODULE_PATH in message and f"version {_driver_version()}" in message
    unmk_calls = _tool_calls(tool_dir, "unmkinitramfs")
    assert len(unmk_calls) == 1 and not Path(unmk_calls[0][1]).exists()


def test_the_temp_dir_is_removed_even_with_readonly_unpacked_entries(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Read-only (0555) and unreadable (0000) unpacked dirs are cleaned up cleanly."""
    good = _driver_version()
    image = tmp_path / "initrd.img"
    image.write_bytes(b"stub")

    # 0555 directory containing a valid module passes and still removes tmpdir.
    tool_dir = _install_initrd_tools(
        tmp_path,
        monkeypatch,
        files={"readonly_dir/frost_net10g.ko": "stub"},
        dirs={"readonly_dir": 0o555},
        modinfo_versions={"*": f"{good}\n"},
    )
    assert hw.check_initrd_driver_version(image, REPO_ROOT)
    assert not Path(_tool_calls(tool_dir, "unmkinitramfs")[-1][1]).exists()

    # 0000 directory fails closed (cannot silently hide a stale module) and cleans up.
    tool_dir = _install_initrd_tools(
        tmp_path,
        monkeypatch,
        files={MODULE_PATH: "good", "locked_dir/frost_net10g.ko": "hidden"},
        dirs={"locked_dir": 0o000},
        modinfo_versions={"*": f"{good}\n"},
    )
    with pytest.raises(hw.LinuxEnvironmentError, match="cannot check"):
        hw.check_initrd_driver_version(image, REPO_ROOT)
    assert not Path(_tool_calls(tool_dir, "unmkinitramfs")[-1][1]).exists()


def test_a_driver_source_without_a_version_is_an_env_fail(tmp_path: Path) -> None:
    """A tree whose version cannot be read does not pass by default."""
    with pytest.raises(hw.LinuxEnvironmentError, match="cannot read the driver"):
        hw.source_driver_version(tmp_path)
    source = tmp_path / hw.DRIVER_SOURCE
    source.parent.mkdir(parents=True)
    source.write_text("int x;\n")
    with pytest.raises(hw.LinuxEnvironmentError, match="no MODULE_VERSION"):
        hw.source_driver_version(tmp_path)


def test_real_unmkinitramfs_and_modinfo_check_a_real_initramfs(tmp_path: Path) -> None:
    """Integration test using the host's real unmkinitramfs and modinfo when present."""
    missing = [
        tool
        for tool in (hw.UNMKINITRAMFS_TOOL, hw.MODINFO_TOOL)
        if shutil.which(tool) is None
    ]
    if missing:
        pytest.skip(f"{', '.join(missing)} not installed on PATH")

    def tiny_elf(version: str, *, rodata: bytes = b"") -> bytes:
        # Minimal ELF64 relocatable object with .rodata, .modinfo, and a 64 KiB
        # SHT_NOBITS .bss section larger than the file (exercises real modinfo).
        info = f"license=GPL\0version={version}\0".encode()
        names = b"\0.rodata\0.modinfo\0.bss\0.shstrtab\0"
        rodata_at = 64
        info_at = rodata_at + len(rodata)
        names_at = info_at + len(info)
        table_at = (names_at + len(names) + 7) & ~7
        body = rodata + info + names + b"\0" * (table_at - names_at - len(names))

        def shdr(name: int, kind: int, offset: int, size: int) -> bytes:
            return struct.pack(
                "<IIQQQQIIQQ", name, kind, 0, 0, offset, size, 0, 0, 1, 0
            )

        table = (
            shdr(0, 0, 0, 0)
            + shdr(1, 1, rodata_at, len(rodata))
            + shdr(9, 1, info_at, len(info))
            + shdr(18, 8, names_at, 65536)  # SHT_NOBITS .bss
            + shdr(23, 3, names_at, len(names))
        )
        hdr = (
            b"\x7fELF\x02\x01\x01"
            + b"\0" * 9
            + struct.pack(
                "<HHIQQQIHHHHHH", 1, 243, 1, 0, 0, table_at, 0, 64, 0, 0, 64, 5, 4
            )
        )
        return hdr + body + table

    def tiny_cpio(files: list[tuple[str, bytes]]) -> bytes:
        entries: list[tuple[str, int, bytes]] = []
        seen_dirs: set[str] = set()
        for rel, data in files:
            parts = rel.split("/")
            for i in range(1, len(parts)):
                parent = "/".join(parts[:i])
                if parent not in seen_dirs:
                    seen_dirs.add(parent)
                    entries.append((parent, 0o040755, b""))
            entries.append((rel, 0o100644, data))
        entries.append(("TRAILER!!!", 0, b""))
        out = b""
        for name, mode, data in entries:
            enc = name.encode() + b"\0"
            fields = [1, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(enc), 0]
            out += b"070701" + b"".join(f"{val:08x}".encode() for val in fields)
            out += enc + b"\0" * (-(110 + len(enc)) % 4)
            out += data + b"\0" * (-len(data) % 4)
        return out

    good = _driver_version()
    early = tiny_cpio([("kernel/x86/microcode/test.bin", b"\x01" * 16)])
    early += b"\0" * (-len(early) % 512)

    # Matching real initramfs (early cpio + gzip cpio + ELF with SHT_NOBITS .bss).
    good_img = tmp_path / "good.img"
    good_img.write_bytes(
        early + gzip.compress(tiny_cpio([(MODULE_PATH, tiny_elf(good))]))
    )
    assert hw.check_initrd_driver_version(good_img, REPO_ROOT) == [
        f"the initramfs carries frost_net10g version {good} "
        "(checked: the early section and the first compressed archive)"
    ]

    # Stale .modinfo with matching decoy in .rodata must fail with both versions.
    decoy = f"\0version={good}\0".encode()
    stale_img = tmp_path / "stale.img"
    stale_img.write_bytes(
        early + gzip.compress(tiny_cpio([(MODULE_PATH, tiny_elf("0.9", rodata=decoy))]))
    )
    with pytest.raises(hw.LinuxEnvironmentError) as stale:
        hw.check_initrd_driver_version(stale_img, REPO_ROOT)
    assert "version 0.9" in str(stale.value) and f"version {good}" in str(stale.value)

    # Corrupt initramfs fails naming unmkinitramfs.
    corrupt_img = tmp_path / "corrupt.img"
    corrupt_img.write_bytes(b"not an initramfs at all")
    with pytest.raises(hw.LinuxEnvironmentError, match="unmkinitramfs"):
        hw.check_initrd_driver_version(corrupt_img, REPO_ROOT)


# ---------------------------------------------------------------------------
# The debug_port stage
# ---------------------------------------------------------------------------

GOOD_ITEMS = [
    ("dtmcs", "0x00003071"),
    ("dmstatus", "0x00430c82"),
    ("hartinfo", "0x002017b4"),
    ("state_before", "running"),
    ("state_halted", "halted"),
    ("dmstatus_halted", "0x00430382"),
    ("dpc", "0x80001234"),
    ("state_after_resume", "running"),
    ("dmstatus_running", "0x00430c82"),
    ("dtmcs_after", "0x00003071"),
    ("hartinfo_after", "0x002017b4"),
    ("state_left", "running"),
]
DEBUG_GOOD = (
    "".join(f"FROST_DEBUG {key}={value}\n" for key, value in GOOD_ITEMS)
    + "FROST_DEBUG_DONE\n"
)
RECOVER_GOOD = "FROST_DEBUG state_left=running\nFROST_DEBUG_DONE\n"


def _transcript(**changes: str | None) -> str:
    """Return DEBUG_GOOD with each named value replaced (None removes the line)."""
    out = ""
    for key, value in GOOD_ITEMS:
        if key in changes:
            if changes[key] is None:
                continue
            value = changes[key]  # type: ignore[assignment]
        out += f"FROST_DEBUG {key}={value}\n"
    return out + "FROST_DEBUG_DONE\n"


def _within(seconds: float, call: Callable[[], Any]) -> Any:
    """Run a call and fail the test if it does not return in time."""

    def alarm(signum: int, frame: Any) -> None:
        raise TimeoutError("the call did not return in time")

    previous = signal.signal(signal.SIGALRM, alarm)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        return call()
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def test_a_good_debug_transcript_passes() -> None:
    """Exactly the expected sequence, every value right, hart running."""
    ok, note = hw.judge_debug_output(DEBUG_GOOD)
    assert ok
    assert "dtmcs 0x00003071" in note and "dpc 0x80001234" in note
    # A hart that was halted before the check, and is resumed, passes too.
    halted_first = _transcript(state_before="halted", dmstatus="0x00430382")
    assert hw.judge_debug_output(halted_first)[0]


@pytest.mark.parametrize(
    "output,reason",
    [
        (_transcript(dtmcs="0x00000061"), "unexpected dtmcs=0x00000061"),
        (_transcript(dtmcs="0x00000c71", dtmcs_after="0x00000c71"), "status 3"),
        (_transcript(dtmcs="0xffff3071", dtmcs_after="0xffff3071"), "reserved"),
        (_transcript(dtmcs_after="0x010c3208"), "dtmcs changed"),
        (_transcript(dtmcs_after="0x00003c71"), "dtmcs changed"),
        (_transcript(dmstatus="0x00430c01"), "does not report the hart running"),
        (_transcript(dmstatus="0x00430f82"), "does not report the hart running"),
        (_transcript(dmstatus="0x00430082"), "does not report the hart running"),
        (_transcript(dmstatus="0x00430382"), "does not report the hart running"),
        (_transcript(hartinfo="0x00000000"), "unexpected hartinfo=0x00000000"),
        (_transcript(hartinfo_after="0x002017b5"), "hartinfo changed"),
        (_transcript(state_before="unavailable"), "unavailable before"),
        (_transcript(state_halted="running"), "halt was refused"),
        (_transcript(dmstatus_halted="0x00000c82"), "does not report the hart halted"),
        (_transcript(dmstatus_halted="0x00430f82"), "does not report the hart halted"),
        (_transcript(dmstatus_halted="0x00433382"), "does not report the hart halted"),
        (_transcript(dmstatus_halted="0x00531382"), "does not report the hart halted"),
        (
            _transcript(dmstatus_running="0x0043cc82"),
            "does not report the hart running",
        ),
        (_transcript(dmstatus_running="0x00030c82"), "static bits"),
        (
            _transcript(dmstatus_running="0x00430f82"),
            "does not report the hart running",
        ),
        (_transcript(state_after_resume="halted"), "did not resume"),
        (
            _transcript(dmstatus_running="0x00430382"),
            "does not report the hart running",
        ),
        (_transcript(state_left="halted"), "left halted"),
    ],
)
def test_wrong_values_fail_with_their_reason(output: str, reason: str) -> None:
    """Each value check names what was wrong."""
    ok, note = hw.judge_debug_output(output)
    assert not ok and reason in note, note


def _structure_cases() -> list[tuple[str, str]]:
    lines = DEBUG_GOOD.splitlines()
    cases: list[tuple[str, str]] = [
        ("empty", ""),
        ("reversed", "\n".join(reversed(lines)) + "\n"),
        ("swapped", "\n".join([lines[0], lines[2], lines[1], *lines[3:]]) + "\n"),
        ("state_left first", "\n".join([lines[11], *lines[:11], lines[12]]) + "\n"),
        ("dpc early", "\n".join([lines[6], *lines[:6], *lines[7:]]) + "\n"),
        ("no end", "\n".join(lines[:-1]) + "\n"),
        ("no final newline", DEBUG_GOOD[:-1]),
        ("end twice", DEBUG_GOOD + "FROST_DEBUG_DONE\n"),
        ("end corrupted", DEBUG_GOOD.replace("DONE\n", "DONE corrupted\n")),
        ("text before", "Open On-Chip Debugger\n" + DEBUG_GOOD),
        ("text after", DEBUG_GOOD + "Info : done\n"),
        ("text between", DEBUG_GOOD.replace("dmstatus=", "x\nFROST_DEBUG dmstatus=")),
        (
            "blank line",
            DEBUG_GOOD.replace("FROST_DEBUG hartinfo", "\nFROST_DEBUG hartinfo"),
        ),
        ("error no space", DEBUG_GOOD + "FROST_DEBUG_ERR:\n"),
        ("error no space text", DEBUG_GOOD + "FROST_DEBUG_ERR:halt failed\n"),
        ("error with space", DEBUG_GOOD + "FROST_DEBUG_ERR: halt failed\n"),
        ("openocd error", DEBUG_GOOD + "Error: JTAG communication error\n"),
        ("crlf", DEBUG_GOOD.replace("\n", "\r\n")),
        ("trailing space", DEBUG_GOOD.replace("running\n", "running \n", 1)),
        ("leading space", " " + DEBUG_GOOD),
        ("uppercase hex", DEBUG_GOOD.replace("0x00003071", "0x0000307F", 1)),
        ("hex digit upper", DEBUG_GOOD.replace("0x00430c82", "0x00430C82", 1)),
        ("short hex", DEBUG_GOOD.replace("0x00003071", "0x3071", 1)),
        ("unknown key", DEBUG_GOOD.replace("FROST_DEBUG dpc", "FROST_DEBUG dpd")),
        (
            "duplicate key",
            DEBUG_GOOD.replace(
                "FROST_DEBUG dpc=", "FROST_DEBUG dtmcs=0x00003071\nFROST_DEBUG dpc="
            ),
        ),
        (
            "duplicate state_left",
            DEBUG_GOOD.replace(
                "FROST_DEBUG_DONE", "FROST_DEBUG state_left=halted\nFROST_DEBUG_DONE"
            ),
        ),
        ("equals missing", DEBUG_GOOD.replace("dpc=", "dpc ")),
    ]
    for key, _ in GOOD_ITEMS:
        cases.append((f"missing {key}", _transcript(**{key: None})))
    return cases


@pytest.mark.parametrize("name,output", _structure_cases())
def test_anything_but_the_exact_sequence_fails(name: str, output: str) -> None:
    """Text before, between or after, and any reordering, is a FAIL."""
    ok, note = hw.judge_debug_output(output)
    assert not ok, name
    assert note and "\n" not in note


def test_the_first_offending_line_is_quoted_and_masked(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The message quotes the line, and the serial in it is masked."""
    monkeypatch.setenv(hw.JTAG_SERIAL_ENV, "SER777")
    ok, note = hw.judge_debug_output(
        DEBUG_GOOD.replace(
            "FROST_DEBUG dmstatus=", "Info : SER777\nFROST_DEBUG dmstatus="
        )
    )
    assert not ok
    assert "Info : <cable serial>" in note and "SER777" not in note


def test_a_script_error_is_quoted_in_the_failure() -> None:
    """The script's own error line is reported, with what the sequence lacked."""
    cut = (
        "".join(f"FROST_DEBUG {k}={v}\n" for k, v in GOOD_ITEMS[:5])
        + "FROST_DEBUG_ERR: Timed out waiting for target to halt\n"
        + "FROST_DEBUG state_left=running\nFROST_DEBUG_DONE\n"
    )
    ok, note = hw.judge_debug_output(cut)
    assert not ok and "Timed out waiting" in note


def _fake_openocd(
    tmp_path: Path, checks: str | bytes, recovery: str | bytes = RECOVER_GOOD
) -> Path:
    """Return a stand-in OpenOCD that prints a canned transcript per procedure.

    Transcript goes to stdout and log lines to stderr, as OpenOCD does. Records
    argv and ``FROST_JTAG_SERIAL``. Optional control files under ``tmp_path``:
    ``stderr.txt``, ``exit.txt``, ``hang``, ``kill`` for ``frost_debug_check``;
    ``recover_stderr.txt``, ``recover_exit.txt``, ``hang_recover``,
    ``kill_recover``, and ``probe_lock`` (probing ``tmp_path / 'lock'``) for
    ``frost_debug_recover``.
    """
    (tmp_path / "check.txt").write_bytes(
        checks if isinstance(checks, bytes) else checks.encode()
    )
    (tmp_path / "recover.txt").write_bytes(
        recovery if isinstance(recovery, bytes) else recovery.encode()
    )
    script = tmp_path / "openocd"
    script.write_text(
        f"#!{sys.executable}\n"
        "import fcntl, os, signal, sys, time\n"
        "from pathlib import Path\n"
        f"root = Path({str(tmp_path)!r})\n"
        "with (root / 'calls.txt').open('a') as f:\n"
        "    f.write(' '.join(sys.argv[1:]) + '\\n')\n"
        "with (root / 'serials.txt').open('a') as f:\n"
        "    f.write(os.environ.get('FROST_JTAG_SERIAL', '') + '\\n')\n"
        "if 'frost_debug_recover' in sys.argv[1:]:\n"
        "    if (root / 'probe_lock').exists():\n"
        "        with (root / 'lock').open('a') as lf:\n"
        "            try:\n"
        "                fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
        "                state = 'UNLOCKED'\n"
        "            except BlockingIOError:\n"
        "                state = 'LOCKED'\n"
        "        with (root / 'lock_states.txt').open('a') as ls:\n"
        "            ls.write(state + '\\n')\n"
        "    (root / 'recover_started').touch()\n"
        "    sys.stdout.buffer.write((root / 'recover.txt').read_bytes())\n"
        "    sys.stdout.buffer.flush()\n"
        "    if (root / 'recover_stderr.txt').exists():\n"
        "        sys.stderr.buffer.write((root / 'recover_stderr.txt').read_bytes())\n"
        "        sys.stderr.buffer.flush()\n"
        "    if (root / 'kill_recover').exists():\n"
        "        os.kill(os.getpid(), signal.SIGKILL)\n"
        "    if (root / 'hang_recover').exists():\n"
        "        time.sleep(30)\n"
        "    if (root / 'recover_exit.txt').exists():\n"
        "        raise SystemExit(int((root / 'recover_exit.txt').read_text().strip()))\n"
        "    raise SystemExit(0)\n"
        "(root / 'primary_started').touch()\n"
        "sys.stdout.buffer.write((root / 'check.txt').read_bytes())\n"
        "sys.stdout.buffer.flush()\n"
        "if (root / 'stderr.txt').exists():\n"
        "    sys.stderr.buffer.write((root / 'stderr.txt').read_bytes())\n"
        "    sys.stderr.buffer.flush()\n"
        "if (root / 'kill').exists():\n"
        "    os.kill(os.getpid(), signal.SIGKILL)\n"
        "if (root / 'hang').exists():\n"
        "    time.sleep(30)\n"
        "if (root / 'exit.txt').exists():\n"
        "    raise SystemExit(int((root / 'exit.txt').read_text().strip()))\n"
        "raise SystemExit(0)\n"
    )
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return script


@pytest.fixture
def debug_env(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> Callable[..., dict[str, str]]:
    """Return a builder of stage environments around a stand-in OpenOCD."""
    monkeypatch.setattr(hw, "DEBUG_LOCK", tmp_path / "lock")
    monkeypatch.setattr(hw, "hw_server_running", lambda: False)

    def build(
        checks: str | bytes, recovery: str | bytes = RECOVER_GOOD
    ) -> dict[str, str]:
        script = _fake_openocd(tmp_path, checks, recovery)
        return {hw.JTAG_SERIAL_ENV: "TESTSERIAL", hw.OPENOCD_ENV: str(script)}

    return build


def _calls(tmp_path: Path) -> list[str]:
    path = tmp_path / "calls.txt"
    return path.read_text().splitlines() if path.exists() else []


def test_the_stage_always_confirms_the_hart_even_on_a_passing_run(
    tmp_path: Path, debug_env: Any
) -> None:
    """PASS always runs frost_debug_check followed by a separate confirmation."""
    environment = debug_env(DEBUG_GOOD)
    result = hw.run_debug_stage(REPO_ROOT, "x3", environment)
    assert result["status"] == "PASS" and result["stage"] == hw.DEBUG_STAGE
    calls = _calls(tmp_path)
    assert len(calls) == 2
    assert "hart confirmed running" in result["note"]
    assert "-f " + str(REPO_ROOT / "fpga/debug/openocd_x3.cfg") in calls[0]
    assert "-f " + str(REPO_ROOT / "fpga/debug/hw_debug_check.tcl") in calls[0]
    assert calls[0].endswith("-c init -c frost_debug_check -c shutdown")
    assert calls[1].endswith("-c init -c frost_debug_recover -c shutdown")
    assert (tmp_path / "serials.txt").read_text().split() == [
        "TESTSERIAL",
        "TESTSERIAL",
    ]


def test_r0_nonzero_exit_and_contradictory_dmstatus_fail_and_confirm(
    tmp_path: Path, debug_env: Any
) -> None:
    """Review 1: nonzero exit and contradictory dmstatus both FAIL and confirm."""
    # Nonzero exit with valid transcript + shutdown error.
    environment = debug_env(DEBUG_GOOD)
    (tmp_path / "exit.txt").write_text("7")
    (tmp_path / "stderr.txt").write_text("Error: shutdown failed on TESTSERIAL\n")
    result = hw.run_debug_stage(REPO_ROOT, "x3", environment)
    assert result["status"] == "FAIL", result
    calls = _calls(tmp_path)
    assert len(calls) == 2 and calls[1].endswith("-c frost_debug_recover -c shutdown")
    assert "OpenOCD exited 7" in result["note"]
    assert "hart confirmed running" in result["note"]
    assert "TESTSERIAL" not in result["note"]

    # Contradictory dmstatus (both halted and running bits set) in valid sequence.
    (tmp_path / "calls.txt").unlink()
    (tmp_path / "exit.txt").unlink()
    (tmp_path / "stderr.txt").unlink()
    environment = debug_env(_transcript(dmstatus_running="0x00430f82"))
    result = hw.run_debug_stage(REPO_ROOT, "x3", environment)
    assert result["status"] == "FAIL", result
    calls = _calls(tmp_path)
    assert len(calls) == 2 and calls[1].endswith("-c frost_debug_recover -c shutdown")
    assert "hart confirmed running" in result["note"]


@pytest.mark.parametrize(
    "case",
    [
        "sigkill_empty_stdout",
        "sigkill_partial_stdout",
        "sigkill_after_full_stdout",
        "duplicate_state_left",
        "non_utf8_and_sigkill",
    ],
)
def test_d1_sigkill_and_duplicate_state_left_always_confirm(
    tmp_path: Path, debug_env: Any, case: str
) -> None:
    """D1: SIGKILL (even after full output) and duplicate state_left always confirm."""
    partial = "".join(f"FROST_DEBUG {k}={v}\n" for k, v in GOOD_ITEMS[:5])
    payloads: dict[str, str | bytes] = {
        "sigkill_empty_stdout": "",
        "sigkill_partial_stdout": partial,
        "sigkill_after_full_stdout": DEBUG_GOOD,
        "duplicate_state_left": _transcript().replace(
            "FROST_DEBUG state_left=running",
            "FROST_DEBUG state_left=halted\nFROST_DEBUG state_left=running",
        ),
        "non_utf8_and_sigkill": partial.encode() + b"\xff\xfe\n",
    }
    environment = debug_env(payloads[case])
    if "sigkill" in case:
        (tmp_path / "kill").touch()
    result = hw.run_debug_stage(REPO_ROOT, "x3", environment)
    assert result["status"] == "FAIL", result
    calls = _calls(tmp_path)
    assert len(calls) == 2 and calls[1].endswith("-c frost_debug_recover -c shutdown")
    assert "hart confirmed running" in result["note"]


def test_d2_dtmcs_after_does_not_clear_sticky_error_and_polling_is_restored() -> None:
    """D2: hw_debug_check.tcl switches polling off/on and keeps dtmcs_after raw."""
    openocd = shutil.which("openocd")
    if openocd is None:
        pytest.skip("openocd is not installed")
    script = REPO_ROOT / hw.DEBUG_SCRIPT

    def run_tcl(mode: str) -> tuple[int, str, str]:
        harness = f"""
set mode "{mode}"
set poll_state "on"
set poll_history {{}}
set cur_state "running"
set last_ir 0
set dtmcs_reads 0
set dmireset_writes 0
set raw_scan_poll_states {{}}
set dmireset_had_ir {{}}

proc poll {{args}} {{
    global poll_state poll_history
    if {{[llength $args] == 1}} {{
        set arg [lindex $args 0]
        if {{$arg eq "on" || $arg eq "off"}} {{
            set poll_state $arg
            lappend poll_history $arg
        }}
    }}
}}
proc target {{sub}} {{ return "mock.cpu" }}
proc mock.cpu {{args}} {{
    global cur_state
    if {{[lindex $args 0] eq "cget"}} {{ return "frost.fpga" }}
    if {{[lindex $args 0] eq "curstate"}} {{ return $cur_state }}
    return ""
}}
proc irscan {{tap ir}} {{
    global last_ir poll_state raw_scan_poll_states
    set last_ir $ir
    lappend raw_scan_poll_states $poll_state
}}
proc drscan {{tap bits val}} {{
    global last_ir dtmcs_reads dmireset_writes mode poll_state raw_scan_poll_states dmireset_had_ir
    lappend raw_scan_poll_states $poll_state
    if {{$val == 0x10000}} {{
        incr dmireset_writes
        lappend dmireset_had_ir $last_ir
        set last_ir 0
        return "00003071"
    }}
    incr dtmcs_reads
    set last_ir 0
    if {{$mode eq "initial_sticky" && $dtmcs_reads == 1}} {{
        return "00003c71"
    }}
    if {{$mode eq "after_sticky" && $dtmcs_reads == 2}} {{
        return "00003c71"
    }}
    return "00003071"
}}
proc riscv {{args}} {{
    global cur_state
    if {{[lindex $args 0] eq "dmi_read"}} {{
        set addr [lindex $args 1]
        if {{$addr == 0x11}} {{
            return [expr {{$cur_state eq "halted" ? 0x00430382 : 0x00430c82}}]
        }}
        if {{$addr == 0x12}} {{ return 0x002017b4 }}
    }}
    return ""
}}
proc halt {{}} {{
    global cur_state
    set cur_state "halted"
}}
proc wait_halt {{ms}} {{}}
proc get_reg {{args}} {{
    global mode
    if {{$mode eq "fail_dpc"}} {{ error "dpc read failed" }}
    return [dict create dpc 0x80001234]
}}
proc resume {{}} {{
    global cur_state mode
    if {{$mode eq "fail_recover_resume"}} {{ error "resume failed" }}
    set cur_state "running"
}}
source "{script}"
if {{$mode eq "fail_recover_resume"}} {{
    set cur_state "halted"
    frost_debug_recover
}} else {{
    frost_debug_check
}}
puts stderr "META poll_end=$poll_state poll_hist=$poll_history dmireset=$dmireset_writes dmireset_ir=$dmireset_had_ir scan_polls=$raw_scan_poll_states state=$cur_state"
"""
        done = hw.subprocess.run(
            [
                openocd,
                "-c",
                "gdb_port disabled",
                "-c",
                "telnet_port disabled",
                "-c",
                "tcl_port disabled",
                "-c",
                harness,
                "-c",
                "shutdown",
            ],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        return done.returncode, done.stdout, done.stderr

    # 1. Sticky busy on dtmcs_after: NOT cleared (dmireset=0), reported raw, fails.
    rc, out, err = run_tcl("after_sticky")
    assert rc == 0, err
    assert "dmireset=0" in err
    assert "FROST_DEBUG dtmcs_after=0x00003c71\n" in out
    ok, note = hw.judge_debug_output(out)
    assert not ok and "dtmcs changed" in note

    # 2. Sticky busy on initial dtmcs: cleared with irscan+drscan under poll off;
    #    poll restored on; transcript passes.
    rc, out, err = run_tcl("initial_sticky")
    assert rc == 0, err
    assert "poll_end=on poll_hist=off on dmireset=1 dmireset_ir=34" in err
    assert "scan_polls=off off off off off off off off" in err
    ok, note = hw.judge_debug_output(out)
    assert ok, f"{note}\n{out}\n{err}"

    # 3. Error during dpc read: poll still restored to on, hart resumed.
    rc, out, err = run_tcl("fail_dpc")
    assert rc == 0, err
    assert "poll_end=on" in err and "state=running" in err
    ok, note = hw.judge_debug_output(out)
    assert not ok and "dpc read failed" in note

    # 4. frost_debug_recover emits FROST_DEBUG_ERR when resume throws.
    rc, out, err = run_tcl("fail_recover_resume")
    assert rc == 0, err
    assert "FROST_DEBUG_ERR: resume failed\n" in out
    ok, note = hw.judge_debug_recovery(out, "", False, 0)
    assert not ok and "resume failed" in note


@pytest.mark.parametrize(
    "stderr_text",
    [
        "Error: JTAG communication error\n",
        "Error: \n",
        "Error:\n",
        "FROST_DEBUG_ERR: late failure\n",
        "FROST_DEBUG_ERR:\n",
    ],
)
def test_d3_bare_error_line_on_stderr_fails_and_confirms(
    tmp_path: Path, debug_env: Any, stderr_text: str
) -> None:
    """D3: any Error: or FROST_DEBUG_ERR: marker (even empty) fails and confirms."""
    environment = debug_env(DEBUG_GOOD)
    (tmp_path / "stderr.txt").write_text(stderr_text)
    result = hw.run_debug_stage(REPO_ROOT, "x3", environment)
    assert result["status"] == "FAIL", result
    calls = _calls(tmp_path)
    assert len(calls) == 2 and calls[1].endswith("-c frost_debug_recover -c shutdown")
    assert "hart confirmed running" in result["note"]


@pytest.mark.parametrize(
    "case",
    [
        "dmstatus_running_halted",
        "state_after_resume_halted",
        "dtmcs_after_dmi_word",
        "exit_nonzero_with_error",
        "sigkill_after_full_stdout",
        "timeout_after_full_stdout",
    ],
)
def test_r1_d1_failing_runs_with_state_left_running_always_confirm(
    tmp_path: Path, debug_env: Any, monkeypatch: pytest.MonkeyPatch, case: str
) -> None:
    """R1-D1: state_left=running in a failing/killed/timed-out run never skips confirm."""
    transcripts = {
        "dmstatus_running_halted": _transcript(dmstatus_running="0x00430382"),
        "state_after_resume_halted": _transcript(
            state_after_resume="halted", dmstatus_running="0x00430382"
        ),
        "dtmcs_after_dmi_word": _transcript(dtmcs_after="0x010c3208"),
        "exit_nonzero_with_error": DEBUG_GOOD,
        "sigkill_after_full_stdout": DEBUG_GOOD,
        "timeout_after_full_stdout": DEBUG_GOOD,
    }
    environment = debug_env(transcripts[case])
    if case == "exit_nonzero_with_error":
        (tmp_path / "exit.txt").write_text("7")
        (tmp_path / "stderr.txt").write_text("Error: target failed\n")
    elif case == "sigkill_after_full_stdout":
        (tmp_path / "kill").touch()
    elif case == "timeout_after_full_stdout":
        (tmp_path / "hang").touch()
        monkeypatch.setattr(hw, "DEBUG_TIMEOUT_S", 0.3)

    result = hw.run_debug_stage(REPO_ROOT, "x3", environment)
    expected = "TIMEOUT" if case == "timeout_after_full_stdout" else "FAIL"
    assert result["status"] == expected, result
    calls = _calls(tmp_path)
    assert len(calls) == 2 and calls[1].endswith("-c frost_debug_recover -c shutdown")
    assert "hart confirmed running" in result["note"]


@pytest.mark.parametrize("primary_kind", ["pass", "fail", "timeout"])
@pytest.mark.parametrize(
    "confirm_failure",
    [
        "exit_nonzero_with_good_stdout",
        "timeout_with_good_stdout",
        "stderr_error_with_good_stdout",
        "stderr_bare_error_with_good_stdout",
        "arbitrary_state_word",
        "still_halted",
        "extra_stdout_line",
        "empty_stdout",
        "script_err_line",
        "killed_recover",
    ],
)
def test_r1_d2_confirmation_requires_clean_exit_no_errors_and_exact_running_line(
    tmp_path: Path,
    debug_env: Any,
    monkeypatch: pytest.MonkeyPatch,
    primary_kind: str,
    confirm_failure: str,
) -> None:
    """R1-D2 & Part B: any imperfect confirmation reports FAIL, UNKNOWN, and recovery cmd."""
    partial = "".join(f"FROST_DEBUG {k}={v}\n" for k, v in GOOD_ITEMS[:5])
    primary_out = DEBUG_GOOD if primary_kind == "pass" else partial
    recover_outputs = {
        "exit_nonzero_with_good_stdout": RECOVER_GOOD,
        "timeout_with_good_stdout": RECOVER_GOOD,
        "stderr_error_with_good_stdout": RECOVER_GOOD,
        "stderr_bare_error_with_good_stdout": RECOVER_GOOD,
        "arbitrary_state_word": "FROST_DEBUG state_left=banana\nFROST_DEBUG_DONE\n",
        "still_halted": "FROST_DEBUG state_left=halted\nFROST_DEBUG_DONE\n",
        "extra_stdout_line": RECOVER_GOOD + "extra\n",
        "empty_stdout": "",
        "script_err_line": "FROST_DEBUG_ERR: resume failed\n" + RECOVER_GOOD,
        "killed_recover": RECOVER_GOOD,
    }
    environment = debug_env(primary_out, recover_outputs[confirm_failure])
    if primary_kind == "timeout":
        (tmp_path / "hang").touch()
        monkeypatch.setattr(hw, "DEBUG_TIMEOUT_S", 0.3)
    if confirm_failure == "exit_nonzero_with_good_stdout":
        (tmp_path / "recover_exit.txt").write_text("7")
        (tmp_path / "recover_stderr.txt").write_text(
            "Error: JTAG failed on TESTSERIAL\n"
        )
    elif confirm_failure == "timeout_with_good_stdout":
        (tmp_path / "hang_recover").touch()
        monkeypatch.setattr(hw, "DEBUG_RECOVERY_TIMEOUT_S", 0.3)
    elif confirm_failure == "stderr_error_with_good_stdout":
        (tmp_path / "recover_stderr.txt").write_text(
            "Error: JTAG failed on TESTSERIAL\n"
        )
    elif confirm_failure == "stderr_bare_error_with_good_stdout":
        (tmp_path / "recover_stderr.txt").write_text("Error: \n")
    elif confirm_failure == "killed_recover":
        (tmp_path / "kill_recover").touch()

    result = hw.run_debug_stage(REPO_ROOT, "x3", environment)
    assert result["status"] == "FAIL", result
    assert "UNKNOWN" in result["note"], result
    assert hw.RECOVERY_COMMAND in result["note"], result
    assert "TESTSERIAL" not in result["note"], result


@pytest.mark.parametrize("path", ["pass", "fail", "exc_show", "exc_judge", "exc_parse"])
def test_r1_d2_confirmation_holds_board_lock_on_normal_and_exception_paths(
    tmp_path: Path, debug_env: Any, monkeypatch: pytest.MonkeyPatch, path: str
) -> None:
    """R1-D2 & Part B: DEBUG_LOCK remains held while frost_debug_recover runs."""
    partial = "".join(f"FROST_DEBUG {k}={v}\n" for k, v in GOOD_ITEMS[:5])
    environment = debug_env(DEBUG_GOOD if path != "fail" else partial)
    (tmp_path / "probe_lock").touch()
    if path.startswith("exc_"):
        target = {
            "exc_show": "mask_serial",
            "exc_judge": "judge_debug_output",
            "exc_parse": "parse_transcript",
        }[path]
        real = getattr(hw, target)
        fired: list[int] = []

        def fail_once(*args: Any, **kwargs: Any) -> Any:
            if not fired:
                fired.append(1)
                raise RuntimeError("injected")
            return real(*args, **kwargs)

        monkeypatch.setattr(hw, target, fail_once)

    result = hw.run_debug_stage(REPO_ROOT, "x3", environment)
    expected = "PASS" if path == "pass" else "FAIL"
    assert result["status"] == expected, result
    assert (tmp_path / "lock_states.txt").read_text().splitlines() == ["LOCKED"]


@pytest.mark.parametrize(
    "step", ["run", "print", "judge", "parse", "mask", "confirm_judge"]
)
def test_an_exception_at_any_step_is_a_fail_after_a_confirmation(
    tmp_path: Path, debug_env: Any, monkeypatch: pytest.MonkeyPatch, step: str
) -> None:
    """Whatever raises once the process has started, the hart is confirmed."""
    partial = "".join(f"FROST_DEBUG {k}={v}\n" for k, v in GOOD_ITEMS[:5])
    environment = debug_env(partial)
    target = {
        "run": "run_openocd_procedure",
        "print": "mask_serial",
        "judge": "judge_debug_output",
        "parse": "parse_transcript",
        "mask": "remember_serial",
        "confirm_judge": "judge_debug_recovery",
    }[step]
    real = getattr(hw, target)
    fired: list[int] = []

    def once(*args: Any, **kwargs: Any) -> Any:
        if not fired:
            fired.append(1)
            raise RuntimeError("injected")
        return real(*args, **kwargs)

    monkeypatch.setattr(hw, target, once)
    result = hw.run_debug_stage(REPO_ROOT, "x3", environment)
    assert fired and result["status"] == "FAIL", result
    if step == "mask":
        assert not _calls(tmp_path)
        return
    calls = _calls(tmp_path)
    assert calls and calls[-1].endswith("-c frost_debug_recover -c shutdown")
    if step == "confirm_judge":
        assert "UNKNOWN" in result["note"] and hw.RECOVERY_COMMAND in result["note"]
    else:
        assert "unexpected RuntimeError" in result["note"]
        assert "hart confirmed running" in result["note"]


def test_an_unwritable_lock_is_an_environment_failure(
    tmp_path: Path, debug_env: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The shared lock file cannot be opened: setup problem, no traceback."""
    environment = debug_env(DEBUG_GOOD)
    monkeypatch.setattr(hw, "DEBUG_LOCK", tmp_path)  # a directory
    result = hw.run_debug_stage(REPO_ROOT, "x3", environment)
    assert result["status"] == hw.ENV_FAIL_STATUS and "lock" in result["note"]
    assert not _calls(tmp_path)


def test_a_launch_failure_starts_nothing_and_is_not_confirmed(
    tmp_path: Path, debug_env: Any
) -> None:
    """An OpenOCD that cannot start never touched the hart."""
    environment = debug_env(DEBUG_GOOD)
    broken = tmp_path / "broken"
    broken.write_bytes(b"\x00\x01 not a program\n")
    broken.chmod(0o755)
    environment[hw.OPENOCD_ENV] = str(broken)
    result = hw.run_debug_stage(REPO_ROOT, "x3", environment)
    assert result["status"] == hw.ENV_FAIL_STATUS and "cannot run" in result["note"]
    assert result["note"].startswith(hw.ENV_NOT_READY)
    assert not _calls(tmp_path)


def test_the_stage_is_skipped_without_a_cable_serial(
    tmp_path: Path, debug_env: Any
) -> None:
    """Skipped is neither passed nor failed, and OpenOCD is never started."""
    environment = debug_env(DEBUG_GOOD)
    del environment[hw.JTAG_SERIAL_ENV]
    result = hw.run_debug_stage(REPO_ROOT, "x3", environment)
    assert result["status"] == hw.SKIP_STATUS
    assert "FROST_JTAG_SERIAL is not set" in result["note"]
    assert "\n" not in result["note"]
    assert not (tmp_path / "calls.txt").exists()
    environment[hw.JTAG_SERIAL_ENV] = "  "
    assert hw.run_debug_stage(REPO_ROOT, "x3", environment)["status"] == hw.SKIP_STATUS


def test_the_stage_reports_a_missing_openocd_as_the_environment(
    debug_env: Any,
) -> None:
    """No OpenOCD is a setup problem, not a board failure."""
    environment = debug_env(DEBUG_GOOD)
    environment[hw.OPENOCD_ENV] = "/nonexistent/openocd"
    result = hw.run_debug_stage(REPO_ROOT, "x3", environment)
    assert result["status"] == hw.ENV_FAIL_STATUS
    assert result["note"].startswith(hw.ENV_NOT_READY)


def test_the_stage_waits_for_hw_server_and_never_stops_it(
    tmp_path: Path, debug_env: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A cable that stays busy fails the stage without starting OpenOCD."""
    environment = debug_env(DEBUG_GOOD)
    monkeypatch.setattr(hw, "hw_server_running", lambda: True)
    result = hw.run_debug_stage(REPO_ROOT, "x3", environment, cable_wait_s=0.0)
    assert result["status"] == "FAIL" and "hw_server" in result["note"]
    assert not (tmp_path / "calls.txt").exists()
    states = iter([True, True, False])
    slept: list[float] = []
    assert hw.wait_for_cable(30.0, lambda: next(states), slept.append, 3.0)
    assert slept == [3.0, 3.0]
    assert not hw.wait_for_cable(6.0, lambda: True, lambda s: None, 3.0)


def test_a_skipped_stage_does_not_fail_the_regression(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The summary counts it as skipped, and the run goes on and passes."""
    seen = _stub_board(monkeypatch)
    monkeypatch.delenv(hw.JTAG_SERIAL_ENV, raising=False)
    monkeypatch.setattr(
        hw.sys,
        "argv",
        ["hw_regression.py", "--board", "x3", "hello_world", "debug_port", "csr_test"],
    )
    assert hw.main() == 0
    assert list(seen) == ["hello_world", "csr_test"]
    out = capsys.readouterr().out
    assert "debug_port" in out and "SKIPPED" in out
    assert "REGRESSION PASS: 2/3 stages passed, 1 skipped" in out


def test_a_run_of_only_skipped_stages_is_not_a_pass(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Nothing was checked, so the verdict is not PASS."""
    _stub_board(monkeypatch)
    monkeypatch.delenv(hw.JTAG_SERIAL_ENV, raising=False)
    monkeypatch.setattr(
        hw.sys, "argv", ["hw_regression.py", "--board", "x3", "debug_port"]
    )
    assert hw.main() == 1
    assert "REGRESSION FAIL: 0/1 stages passed, 1 skipped" in capsys.readouterr().out


def test_a_failed_debug_stage_stops_the_run_unless_keep_going(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """debug_port follows --keep-going like every other stage."""
    seen = _stub_board(monkeypatch)
    failed = {"stage": hw.DEBUG_STAGE, "status": "FAIL", "elapsed": 0.0, "note": "x"}
    monkeypatch.setattr(hw, "run_debug_stage", lambda *args: failed)
    argv = [
        "hw_regression.py",
        "--board",
        "x3",
        "hello_world",
        "debug_port",
        "csr_test",
    ]
    monkeypatch.setattr(hw.sys, "argv", argv)
    assert hw.main() == 1
    assert list(seen) == ["hello_world"]
    seen.clear()
    monkeypatch.setattr(hw.sys, "argv", [*argv, "--keep-going"])
    assert hw.main() == 1
    assert list(seen) == ["hello_world", "csr_test"]


def test_a_debug_only_selection_does_not_need_the_uart(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Another process holding the UART does not stop a JTAG-only selection."""
    _stub_board(monkeypatch)
    monkeypatch.setattr(hw, "serial_holders", lambda path: ["some other process"])
    monkeypatch.delenv(hw.JTAG_SERIAL_ENV, raising=False)
    monkeypatch.setattr(
        hw.sys, "argv", ["hw_regression.py", "--board", "x3", "debug_port"]
    )
    hw.main()
    captured = capsys.readouterr()
    assert "already open" not in captured.err and "SKIPPED" in captured.out
    monkeypatch.setattr(
        hw.sys, "argv", ["hw_regression.py", "--board", "x3", "hello_world"]
    )
    assert hw.main() == 1
    assert "already open" in capsys.readouterr().err


def test_the_debug_script_loads_in_openocd() -> None:
    """OpenOCD parses the Tcl and defines every procedure (no board needed)."""
    openocd = shutil.which("openocd")
    if openocd is None:
        pytest.skip("openocd is not installed")
    done = hw.subprocess.run(
        [
            openocd,
            "-c",
            "gdb_port disabled",
            "-c",
            "telnet_port disabled",
            "-c",
            "tcl_port disabled",
            "-c",
            f"source {REPO_ROOT / hw.DEBUG_SCRIPT}",
            "-c",
            'puts "DEFINED [info commands frost_debug_check] '
            "[info commands frost_debug_check_steps] "
            "[info commands frost_debug_read_dtmcs] "
            "[info commands frost_debug_clean_dtmcs] "
            '[info commands frost_debug_recover]"',
            "-c",
            "shutdown",
        ],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert done.returncode == 0, done.stdout + done.stderr
    assert (
        "DEFINED frost_debug_check frost_debug_check_steps "
        "frost_debug_read_dtmcs frost_debug_clean_dtmcs frost_debug_recover"
    ) in done.stdout + done.stderr


# ---------------------------------------------------------------------------
# Serial masking and preflight error boundary
# ---------------------------------------------------------------------------

SECRET = "SECRETSER42"


def test_the_cable_serial_never_appears_anywhere(
    tmp_path: Path,
    debug_env: Any,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Across failure fixtures the serial is in no output, note or exception."""
    texts: list[str] = []
    environment = debug_env(DEBUG_GOOD)
    environment[hw.JTAG_SERIAL_ENV] = SECRET

    # An OPENOCD path that names the serial and does not exist, or cannot run.
    for name, content in ((f"openocd-{SECRET}", None), (f"broken-{SECRET}", b"\x00 x")):
        env = {**environment, hw.OPENOCD_ENV: str(tmp_path / name)}
        if content is not None:
            (tmp_path / name).write_bytes(content)
            (tmp_path / name).chmod(0o755)
        texts.append(str(hw.run_debug_stage(REPO_ROOT, "x3", env)))

    # OpenOCD log text, nonzero exit, garbled transcript, and confirmation error.
    (tmp_path / "stderr.txt").write_text(f"Error: no device {SECRET}\n")
    (tmp_path / "exit.txt").write_text("3")
    (tmp_path / "recover_stderr.txt").write_text(f"Error: recover {SECRET}\n")
    texts.append(str(hw.run_debug_stage(REPO_ROOT, "x3", environment)))
    (tmp_path / "check.txt").write_text(f"Info : {SECRET}\n" + DEBUG_GOOD)
    texts.append(str(hw.run_debug_stage(REPO_ROOT, "x3", environment)))

    # The initramfs path and tool stderr in a preflight failure, directly & via main().
    monkeypatch.setenv(hw.JTAG_SERIAL_ENV, SECRET)
    initrd = tmp_path / f"initrd-{SECRET}"
    initrd.write_bytes(b"stub-initrd")
    _install_initrd_tools(
        tmp_path,
        monkeypatch,
        files={MODULE_PATH: "stub"},
        modinfo_versions={"*": "0.9\n"},
    )
    with pytest.raises(hw.LinuxEnvironmentError) as raised:
        hw.check_initrd_driver_version(initrd, REPO_ROOT)
    texts.append(str(raised.value))
    assert "<cable serial>" in str(raised.value)
    _install_initrd_tools(
        tmp_path,
        monkeypatch,
        unmk_exit=1,
        unmk_stderr=f"cannot open {SECRET}\n".encode(),
    )
    with pytest.raises(hw.LinuxEnvironmentError) as tool_raised:
        hw.check_initrd_driver_version(initrd, REPO_ROOT)
    texts.append(str(tool_raised.value))
    assert "<cable serial>" in str(tool_raised.value)
    _install_initrd_tools(
        tmp_path,
        monkeypatch,
        files={MODULE_PATH: "stub"},
        modinfo_versions={"*": "0.9\n"},
    )

    export = _fake_export(tmp_path / "x")
    root = dataclasses.replace(_fake_root(export), initrd=initrd)
    _stub_board(monkeypatch)
    monkeypatch.setattr(hw, "probe_nfs3_tcp", lambda *a, **k: None)
    real_from_env = hw.linux_root_from_env
    monkeypatch.setattr(hw, "linux_root_from_env", lambda: root)
    for tail in ([], ["--keep-going"]):
        monkeypatch.setattr(
            hw.sys, "argv", ["hw_regression.py", "--board", "x3", "linux_boot", *tail]
        )
        hw.main()

    # An exception that escapes a stage and carries the serial.
    def boom(*args: Any) -> Any:
        raise RuntimeError(f"unexpected {SECRET}")

    monkeypatch.setattr(hw, "run_debug_stage", boom)
    monkeypatch.setattr(
        hw.sys, "argv", ["hw_regression.py", "--board", "x3", "debug_port"]
    )
    assert hw.main() == 1

    # writelines, case-insensitive masking, and a serial only in explicit env.
    hw._MaskedStream(hw.sys.stdout).writelines(
        [f"serial={SECRET}\n", f"lower={SECRET.lower()}\n", "mixed=sEcReTsEr42\n"]
    )
    assert (
        hw.mask_serial(
            f"up={SECRET} lo={SECRET.lower()} mix=SeCrEtSeR42",
            {hw.JTAG_SERIAL_ENV: SECRET},
        )
        == "up=<cable serial> lo=<cable serial> mix=<cable serial>"
    )
    monkeypatch.delenv(hw.JTAG_SERIAL_ENV)
    hw._SEEN_SERIALS.clear()
    with pytest.raises(hw.LinuxEnvironmentError) as custom:
        real_from_env(
            {
                hw.LINUX_NFSROOT_ENV: f"bad{SECRET.lower()}",
                hw.LINUX_IP_ENV: "dhcp",
                hw.JTAG_SERIAL_ENV: SECRET,
            },
            site={},
        )
    texts.append(str(custom.value))
    captured = capsys.readouterr()
    texts += [captured.out, captured.err]
    assert all(text for text in texts)
    assert not [text for text in texts if SECRET.lower() in text.lower()]


def test_an_unexpected_error_in_the_preflight_is_an_env_fail(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The preflight is one boundary: any exception becomes the same outcome."""
    root = _fake_root(_fake_export(tmp_path))
    monkeypatch.setattr(
        hw, "probe_nfs3_tcp", lambda *a, **k: (_ for _ in ()).throw(KeyError("boom"))
    )
    with pytest.raises(hw.LinuxEnvironmentError, match="failed unexpectedly"):
        hw.linux_root_preflight(root, REPO_ROOT, {})
    seen = _stub_board(monkeypatch)
    monkeypatch.setattr(hw, "linux_root_from_env", lambda: root)
    for tail in ([], ["--keep-going"]):
        monkeypatch.setattr(
            hw.sys, "argv", ["hw_regression.py", "--board", "x3", "linux_boot", *tail]
        )
        assert hw.main() == 1
    err = capsys.readouterr().err
    assert "Traceback" not in err and "failed unexpectedly" in err and not seen


# ---------------------------------------------------------------------------
# Seeded mutation tests: transcripts and confirmation outputs
# ---------------------------------------------------------------------------

MUTATION_SEED = 20261119
MARKER = "MARKERSER99"


def _mutate_lines(rng: Any, text: str) -> str:
    """Return a mutation of a transcript: lines or characters changed."""
    lines = text.split("\n")
    ops = [
        "flip",
        "delete",
        "duplicate",
        "insert",
        "reorder",
        "truncate",
        "digit",
        "cr",
        "marker",
    ]
    for _ in range(rng.randint(1, 3)):
        if not lines:
            lines = [""]
        op = rng.choice(ops)
        index = rng.randrange(len(lines))
        if op == "flip" and lines[index]:
            at = rng.randrange(len(lines[index]))
            lines[index] = (
                lines[index][:at] + chr(rng.randrange(32, 127)) + lines[index][at + 1 :]
            )
        elif op == "delete":
            del lines[index]
        elif op == "duplicate":
            lines.insert(index, lines[index])
        elif op == "insert":
            lines.insert(
                index,
                rng.choice(
                    [
                        "",
                        "Info : x",
                        "FROST_DEBUG",
                        "FROST_DEBUG_ERR:",
                        "FROST_DEBUG_ERR: e",
                        "FROST_DEBUG_DONE",
                        "Error: e",
                        "Error:",
                    ]
                ),
            )
        elif op == "marker":
            lines.insert(
                index,
                rng.choice(
                    [
                        f"Info : {MARKER}",
                        f"FROST_DEBUG note={MARKER}",
                        f"FROST_DEBUG_ERR: {MARKER}",
                    ]
                ),
            )
        elif op == "reorder":
            other = rng.randrange(len(lines))
            lines[index], lines[other] = lines[other], lines[index]
        elif op == "truncate":
            lines = lines[: index + 1]
        elif op == "digit":
            hexdigits = [
                i for i, c in enumerate(lines[index]) if c in "0123456789abcdef"
            ]
            if hexdigits:
                at = rng.choice(hexdigits)
                lines[index] = (
                    lines[index][:at] + rng.choice("xg-+ .Z") + lines[index][at + 1 :]
                )
        elif op == "cr":
            lines[index] += "\r"
    return "\n".join(lines)


def _canonical(text: str) -> str:
    """Return the transcript with dpc, which may be any address, fixed."""
    return re.sub(r"^(FROST_DEBUG dpc=)0x[0-9a-f]{1,16}$", r"\g<1>X", text, flags=re.M)


def test_mutated_transcripts_never_pass_unless_still_valid(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Seeded mutants: no exception, quick return, PASS only if exactly valid."""
    monkeypatch.setenv(hw.JTAG_SERIAL_ENV, MARKER)
    rng = random.Random(MUTATION_SEED)
    started = time.monotonic()
    for _ in range(600):
        mutant = _mutate_lines(rng, DEBUG_GOOD)
        ok, note = _within(2, lambda: hw.judge_debug_output(mutant))
        assert MARKER not in note
        if ok:
            assert _canonical(mutant) == _canonical(DEBUG_GOOD), mutant
        else:
            assert note
    assert time.monotonic() - started < 5


def test_mutated_confirmation_outputs_never_confirm_unless_exact(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Seeded confirmation mutants: confirmed ONLY on clean exit 0 and exact output."""
    monkeypatch.setenv(hw.JTAG_SERIAL_ENV, MARKER)
    rng = random.Random(MUTATION_SEED + 2)
    started = time.monotonic()
    stderr_choices = [
        "",
        f"Info : connected {MARKER}\n",
        f"Error: {MARKER}\n",
        "Error: \n",
        "Error:\n",
        f"FROST_DEBUG_ERR: {MARKER}\n",
        "FROST_DEBUG_ERR:\n",
    ]
    confirmed_count = 0
    for _ in range(600):
        stdout = (
            RECOVER_GOOD if rng.random() < 0.25 else _mutate_lines(rng, RECOVER_GOOD)
        )
        stderr = rng.choice(stderr_choices)
        timed_out = rng.random() < 0.1
        exit_code = None if timed_out else rng.choice([0, 0, 0, 1, 7, -9])
        ok, note = _within(
            2, lambda: hw.judge_debug_recovery(stdout, stderr, timed_out, exit_code)
        )
        assert MARKER not in note
        has_err = any(
            line.rstrip("\r").startswith(("Error:", "FROST_DEBUG_ERR:"))
            for line in stderr.split("\n")
        )
        expected_ok = (
            not timed_out and exit_code == 0 and not has_err and stdout == RECOVER_GOOD
        )
        assert ok == expected_ok, (stdout, stderr, timed_out, exit_code, note)
        if ok:
            confirmed_count += 1
    assert 0 < confirmed_count < 600
    assert time.monotonic() - started < 5


def test_mutated_transcripts_through_the_whole_stage(
    tmp_path: Path,
    debug_env: Any,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Whole-stage seeded mutants: 2 processes always run, UNKNOWN on bad confirm."""
    rng = random.Random(MUTATION_SEED + 1)
    environment = debug_env(DEBUG_GOOD)
    environment[hw.JTAG_SERIAL_ENV] = MARKER
    stderr_pool = ["", f"Info : {MARKER}\n", f"Error: {MARKER}\n", "Error:\n"]
    for _ in range(30):
        if (tmp_path / "calls.txt").exists():
            (tmp_path / "calls.txt").unlink()
        primary = DEBUG_GOOD if rng.random() < 0.3 else _mutate_lines(rng, DEBUG_GOOD)
        recover = (
            RECOVER_GOOD if rng.random() < 0.5 else _mutate_lines(rng, RECOVER_GOOD)
        )
        p_err = rng.choice(stderr_pool)
        r_err = rng.choice(stderr_pool)
        r_exit = rng.choice([0, 0, 0, 5])
        (tmp_path / "check.txt").write_text(primary)
        (tmp_path / "stderr.txt").write_text(p_err)
        (tmp_path / "recover.txt").write_text(recover)
        (tmp_path / "recover_stderr.txt").write_text(r_err)
        (tmp_path / "recover_exit.txt").write_text(str(r_exit))

        result = _within(30, lambda: hw.run_debug_stage(REPO_ROOT, "x3", environment))
        calls = _calls(tmp_path)
        assert len(calls) == 2, calls
        assert result["status"] in {"PASS", "FAIL"}
        assert MARKER not in result["note"]
        r_has_err = any(
            line.rstrip("\r").startswith(("Error:", "FROST_DEBUG_ERR:"))
            for line in r_err.split("\n")
        )
        p_has_err = any(
            line.rstrip("\r").startswith(("Error:", "FROST_DEBUG_ERR:"))
            for line in p_err.split("\n")
        )
        confirm_ok = r_exit == 0 and not r_has_err and recover == RECOVER_GOOD
        if not confirm_ok:
            assert result["status"] == "FAIL"
            assert "UNKNOWN" in result["note"]
            assert hw.RECOVERY_COMMAND in result["note"]
        if result["status"] == "PASS":
            assert _canonical(primary) == _canonical(DEBUG_GOOD)
            assert not p_has_err and confirm_ok
    captured = capsys.readouterr()
    assert MARKER not in captured.out + captured.err


# ---------------------------------------------------------------------------
# F1: SIGINT / SIGTERM confirmation under lock at every step
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("sig", [signal.SIGINT, signal.SIGTERM])
@pytest.mark.parametrize(
    "step",
    [
        "before_launch",
        "during_primary",
        "during_show",
        "during_judge",
        "during_confirm",
        "during_primary_and_confirm",
        "during_primary_with_failing_confirm",
    ],
)
def test_f1_interrupt_and_sigterm_confirm_under_lock_at_every_step(
    tmp_path: Path,
    debug_env: Any,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    sig: signal.Signals,
    step: str,
) -> None:
    """SIGINT and SIGTERM confirm under DEBUG_LOCK, restore SIGTERM, and re-raise."""
    environment = debug_env(DEBUG_GOOD)
    environment[hw.JTAG_SERIAL_ENV] = SECRET
    (tmp_path / "probe_lock").touch()
    expected_exc = KeyboardInterrupt if sig == signal.SIGINT else hw._StageTerminated

    def sentinel_handler(signum: int, frame: Any) -> None:
        pass

    prev_sigint = signal.getsignal(signal.SIGINT)
    prev_sigterm = signal.getsignal(signal.SIGTERM)
    signal.signal(signal.SIGINT, signal.default_int_handler)
    signal.signal(signal.SIGTERM, sentinel_handler)

    threads: list[threading.Thread] = []

    def send_when_file(marker: Path) -> None:
        deadline = time.monotonic() + 10.0
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        if marker.exists():
            os.kill(os.getpid(), sig)

    try:
        if step == "before_launch":

            def wait_and_signal(*args: Any, **kwargs: Any) -> bool:
                os.kill(os.getpid(), sig)
                return True

            monkeypatch.setattr(hw, "wait_for_cable", wait_and_signal)
        elif step in {
            "during_primary",
            "during_primary_and_confirm",
            "during_primary_with_failing_confirm",
        }:
            (tmp_path / "hang").touch()
            t1 = threading.Thread(
                target=send_when_file, args=(tmp_path / "primary_started",), daemon=True
            )
            t1.start()
            threads.append(t1)
            if step == "during_primary_and_confirm":
                (tmp_path / "hang_recover").touch()
                t2 = threading.Thread(
                    target=send_when_file,
                    args=(tmp_path / "recover_started",),
                    daemon=True,
                )
                t2.start()
                threads.append(t2)
            elif step == "during_primary_with_failing_confirm":
                (tmp_path / "recover_exit.txt").write_text("5")
                (tmp_path / "recover_stderr.txt").write_text(
                    f"Error: cable {SECRET.lower()} lost\n"
                )
        elif step == "during_show":
            real_mask = hw.mask_serial
            fired: list[int] = []

            def interrupt_once(text: str, env: Any = None) -> str:
                if not fired:
                    fired.append(1)
                    os.kill(os.getpid(), sig)
                return real_mask(text, env)

            monkeypatch.setattr(hw, "mask_serial", interrupt_once)
        elif step == "during_judge":

            def interrupt_judge(out: str) -> Any:
                os.kill(os.getpid(), sig)

            monkeypatch.setattr(hw, "judge_debug_output", interrupt_judge)
        elif step == "during_confirm":
            (tmp_path / "hang_recover").touch()
            t = threading.Thread(
                target=send_when_file, args=(tmp_path / "recover_started",), daemon=True
            )
            t.start()
            threads.append(t)

        with pytest.raises(expected_exc):
            hw.run_debug_stage(REPO_ROOT, "x3", environment)
    finally:
        for t in threads:
            t.join(timeout=2.0)
        restored_sigterm = signal.getsignal(signal.SIGTERM)
        signal.signal(signal.SIGINT, prev_sigint)
        signal.signal(signal.SIGTERM, prev_sigterm)

    assert restored_sigterm is sentinel_handler
    captured = capsys.readouterr()
    combined = captured.out + captured.err
    assert SECRET.lower() not in combined.lower()
    calls = _calls(tmp_path)
    if step == "before_launch":
        assert calls == []
        return
    assert len(calls) == 2, calls
    assert calls[1].endswith("-c frost_debug_recover -c shutdown")
    assert (tmp_path / "lock_states.txt").read_text().splitlines() == ["LOCKED"]
    if step in {
        "during_confirm",
        "during_primary_and_confirm",
        "during_primary_with_failing_confirm",
    }:
        err_lines = [line for line in captured.err.splitlines() if line.strip()]
        assert len(err_lines) == 1, err_lines
        assert "UNKNOWN" in err_lines[0] and hw.RECOVERY_COMMAND in err_lines[0]
    else:
        assert "hart confirmed running" in captured.err


# ---------------------------------------------------------------------------
# F2(b): authoritative runtime /sys/module/frost_net10g/version check
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "line,expected_reason",
    [
        (f"{hw.LINUX_DRIVER_VERSION_TOKEN}=0.9\r\r\n", "version 0.9"),
        (
            f"{hw.LINUX_DRIVER_VERSION_TOKEN}={hw.LINUX_DRIVER_VERSION_MISSING}\r\r\n",
            "missing or unreadable",
        ),
        (f"{hw.LINUX_DRIVER_VERSION_TOKEN}=\r\r\n", "missing or unreadable"),
        (f"{hw.LINUX_DRIVER_VERSION_TOKEN}=1.3 \r\r\n", "version '1.3 '"),
        (f"{hw.LINUX_DRIVER_VERSION_TOKEN}=1.3-dirty\r\r\n", "version 1.3-dirty"),
        (
            f"{hw.LINUX_DRIVER_VERSION_TOKEN}=1.3\r\r\n"
            f"{hw.LINUX_DRIVER_VERSION_TOKEN}=0.9\r\r\n",
            "multiple",
        ),
    ],
)
def test_f2_runtime_driver_version_mismatch_or_missing_fails_immediately(
    line: str, expected_reason: str
) -> None:
    """A stale, missing, or unreadable runtime sysfs version fails with the remedy."""
    linux = hw.linux_stage(ROOT, driver_version="1.3")
    bad = TO_MOUNT + DRIVER_ECHO + line + PROMPT
    assert linux.failure_done(bad), bad
    assert not linux.success_done(bad)
    ok, note = linux.judge(bad)
    assert not ok
    assert expected_reason in note, note
    assert hw.LINUX_DRIVER_VERSION_PATH in note
    assert "docs/debian_nfsroot.md" in note and "update-initramfs" in note


def test_f2_runtime_driver_version_before_login_cannot_satisfy_the_check() -> None:
    """A line printed before the login prompt does not satisfy the runtime check."""
    linux = hw.linux_stage(ROOT, driver_version="1.3", isa_run_id=ISA_RUN_ID)
    spoofed = (
        BOOT_TO_LOGIN.replace(
            "login: ", f"{hw.LINUX_DRIVER_VERSION_TOKEN}=1.3\r\r\nlogin: "
        )
        + LOGIN_TO_SHELL
        + MOUNT_ECHO
        + MOUNT_LINE
        + SYSTEMD_ECHO
        + SYSTEMD_RUNNING
        + STRESS_ECHO
        + STRESS_OUT
        + COUNTER_ECHO
        + COUNTER_LINE
        + MEMERR_ECHO
        + MEMERR_LINE
        + ISA_ABSENT_ECHO
        + ISA_ABSENT_LINES
        + SUPM_ECHO
        + SUPM_LINES
        + NET_ECHO
        + NET_START
        + NET_PASS
        + NET_ALIVE
    )
    assert not linux.success_done(spoofed)
    ok, note = linux.judge(spoofed)
    assert not ok and f"no {hw.LINUX_DRIVER_VERSION_TOKEN}= line" in note


def test_f2_driver_version_echo_never_matches_at_any_wrap_offset() -> None:
    """The typed command omits ``FROST_DRIVER_VERSION=`` so wraps cannot match it."""
    assert f"{hw.LINUX_DRIVER_VERSION_TOKEN}=" not in DRIVER_ECHO
    for wrap in range(len(DRIVER_ECHO)):
        wrapped = f"{DRIVER_ECHO[:wrap]}\r\r\n{DRIVER_ECHO[wrap:]}"
        assert hw.LINUX_DRIVER_VERSION_RE.search(TO_MOUNT + wrapped) is None, wrap


def test_f2_driver_version_shell_command_handles_present_empty_and_missing(
    tmp_path: Path,
) -> None:
    """The real shell command prints exact version, empty line, or MISSING."""
    ver_file = tmp_path / "version"
    cmd = hw.LINUX_DRIVER_VERSION_COMMAND.replace(
        hw.LINUX_DRIVER_VERSION_PATH, str(ver_file)
    )
    for content, expected in (
        ("1.3\n", f"{hw.LINUX_DRIVER_VERSION_TOKEN}=1.3\n"),
        ("0.9\n", f"{hw.LINUX_DRIVER_VERSION_TOKEN}=0.9\n"),
        ("", f"{hw.LINUX_DRIVER_VERSION_TOKEN}=\n"),
        (None, f"{hw.LINUX_DRIVER_VERSION_TOKEN}=MISSING\n"),
    ):
        if content is None:
            ver_file.unlink()
        else:
            ver_file.write_text(content)
        done = hw.subprocess.run(
            ["sh", "-c", cmd], capture_output=True, text=True, check=True, timeout=10
        )
        assert done.stdout == expected


# --- ISA discovery and extended register-state probe -------------------------


ISA_PROBE_SOURCE = (
    REPO_ROOT / "linux/buildroot-external/package/frost-stress/src/frost_isa_probe.c"
)
ISA_PROBE_ASM = (
    REPO_ROOT
    / "linux/buildroot-external/package/frost-stress/src/frost_isa_probe_asm.S"
)


def _valid_dtb_bytes(size: int = 128) -> bytes:
    """Return a minimal header-valid compiled FDT blob of ``size`` bytes."""
    return struct.pack(">10I", 0xD00DFEED, size, 40, 40, 40, 17, 16, 0, 0, 0).ljust(
        size, b"\x00"
    )


def test_isa_probe_command_carries_no_verdict_tokens_and_resists_wrapping() -> None:
    """The echoed command never matches anchored probe verdict or exit lines."""
    for expect, limit in (("absent", 45), ("present", 420)):
        cmd = hw.isa_probe_command(ISA_RUN_ID, expect)
        assert f"timeout -k 5 {limit} /usr/local/bin/frost_isa_probe suite" in cmd
        assert f"--run-id {ISA_RUN_ID}" in cmd
        for wrap in range(len(cmd)):
            wrapped = f"{MEMERR_TRANSCRIPT}{cmd[:wrap]}\r\r\n{cmd[wrap:]}\r\r\n"
            fail, passed, _ = hw.isa_probe_verdict(wrapped, ISA_RUN_ID, expect)
            assert not fail and not passed, (expect, wrap)
    # Default stage generates distinct 8-hex-digit run IDs across calls.
    first = hw.linux_stage(ROOT).stimuli[-3][1]
    second = hw.linux_stage(ROOT).stimuli[-3][1]
    assert first != second


def test_isa_probe_present_transcript_passes_with_present_expectation() -> None:
    """All eight present-mode cases pass when the stage expects present."""
    linux = hw.linux_stage(ROOT, isa_expect="present", isa_run_id=ISA_RUN_ID)
    transcript = (
        MEMERR_TRANSCRIPT
        + ISA_PRESENT_ECHO
        + ISA_PRESENT_LINES
        + SUPM_ECHO
        + SUPM_LINES
        + NET_ECHO
        + NET_START
        + NET_PASS
        + NET_ALIVE
    )
    assert linux.success_done(transcript)
    assert not linux.failure_done(transcript)
    ok, note = linux.judge(transcript)
    assert ok, note
    assert "isa probe present (8/8 cases)" in note


def test_isa_probe_rejects_mode_mismatch_in_both_directions() -> None:
    """An absent run fails a present stage and a present run fails an absent stage."""
    present_stage = hw.linux_stage(ROOT, isa_expect="present", isa_run_id=ISA_RUN_ID)
    assert present_stage.failure_done(FULL_TRANSCRIPT)
    ok, note = present_stage.judge(FULL_TRANSCRIPT)
    assert not ok and "observed mode 'absent', expected 'present'" in note

    present_transcript = (
        MEMERR_TRANSCRIPT
        + ISA_PRESENT_ECHO
        + ISA_PRESENT_LINES
        + SUPM_ECHO
        + SUPM_LINES
        + NET_ECHO
        + NET_START
        + NET_PASS
        + NET_ALIVE
    )
    absent_stage = stage()
    assert absent_stage.failure_done(present_transcript)
    ok, note = absent_stage.judge(present_transcript)
    assert not ok and "observed mode 'present', expected 'absent'" in note


@pytest.mark.parametrize(
    "expect,before,after,expected_note",
    [
        ("absent", "sigill=1", "sigill=0", "illegal sigill='0'"),
        ("absent", "rounds=4", "rounds=0", "signal rounds='0'"),
        ("absent", "end_magic=0", "end_magic=1", "signal end=(1,0)"),
        ("absent", "einval=1", "einval=0", "ptrace einval='0'"),
        ("present", "smoke=1", "smoke=0", "discover smoke='0'"),
        ("present", "traps_phase2=1", "traps_phase2=2", "first-use traps=(1,2)"),
        ("present", "missed=0", "missed=1", "first-use missed=1"),
        ("present", "rounds_a=64", "rounds_a=0", "switch rounds=(0,64)"),
        ("present", "clobbers=16", "clobbers=15", "clobbers=15"),
        ("present", "active_bytes=1064", "active_bytes=1024", "bytes=1024"),
        ("present", "setregset_ok=1", "setregset_ok=0", "setregset=0"),
        ("present", "restored=1", "restored=0", "restored=0"),
        ("present", "isolated=1", "isolated=0", "fork isolated='0'"),
        ("present", "off_sigill=1", "off_sigill=0", "exec off_sigill='0'"),
    ],
)
def test_isa_probe_rejects_zero_or_invalid_coverage_fields(
    expect: str, before: str, after: str, expected_note: str
) -> None:
    """Zero counts or wrong field sizes fail the stage even with rc=0."""
    base = (
        FULL_TRANSCRIPT
        if expect == "absent"
        else (
            MEMERR_TRANSCRIPT
            + ISA_PRESENT_ECHO
            + ISA_PRESENT_LINES
            + SUPM_ECHO
            + SUPM_LINES
            + NET_ECHO
            + NET_START
            + NET_PASS
            + NET_ALIVE
        )
    )
    mutated = base.replace(before, after, 1)
    assert mutated != base
    linux = hw.linux_stage(ROOT, isa_expect=expect, isa_run_id=ISA_RUN_ID)
    assert linux.failure_done(mutated)
    ok, note = linux.judge(mutated)
    assert not ok and expected_note in note


def test_isa_probe_rejects_missing_stale_failed_and_nonzero_exit_records() -> None:
    """Missing cases, stale run IDs, explicit FAIL lines, and timeouts all fail."""
    # Missing one case line.
    missing_case = FULL_TRANSCRIPT.replace(
        f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=ptrace verdict=PASS gpr_ok=1 einval=1\r\r\n",
        "",
    )
    assert stage().failure_done(missing_case)
    ok, note = stage().judge(missing_case)
    assert not ok and "missing ptrace" in note

    # Stale lines with another hex ID cannot satisfy the current run ID.
    stale = FULL_TRANSCRIPT.replace(ISA_RUN_ID, "deadbeef")
    assert not stage().success_done(stale)
    ok, note = stage().judge(stale)
    assert not ok and f"no {hw.LINUX_ISA_PROBE_EXIT_TOKEN} line" in note

    # Pre-login lines cannot satisfy the post-login check.
    before_prompt = BOOT_TO_LOGIN[: -len(hw.LINUX_LOGIN_PROMPT)]
    early = (
        before_prompt
        + ISA_ABSENT_LINES
        + hw.LINUX_LOGIN_PROMPT
        + LOGIN_TO_SHELL
        + MOUNT_ECHO
        + MOUNT_LINE
        + DRIVER_ECHO
        + DRIVER_LINE
        + SYSTEMD_ECHO
        + SYSTEMD_RUNNING
        + STRESS_ECHO
        + STRESS_OUT
        + COUNTER_ECHO
        + COUNTER_LINE
        + MEMERR_ECHO
        + MEMERR_LINE
        + NET_ECHO
        + NET_START
        + NET_PASS
        + NET_ALIVE
    )
    assert not stage().success_done(early)

    # Explicit case FAIL ends capture immediately.
    failed = (
        MEMERR_TRANSCRIPT
        + ISA_ABSENT_ECHO
        + f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=illegal verdict=FAIL reason=no_sigill\r\r\n"
    )
    assert stage().failure_done(failed)
    ok, note = stage().judge(failed)
    assert not ok and "illegal: FAIL (no_sigill)" in note

    # Nonzero wrapper exit code (e.g. timeout -> 124) ends capture immediately.
    timed_out = (
        MEMERR_TRANSCRIPT
        + ISA_ABSENT_ECHO
        + f"{hw.LINUX_ISA_PROBE_EXIT_TOKEN} id={ISA_RUN_ID} rc=124\r\r\n"
    )
    assert stage().failure_done(timed_out)
    ok, note = stage().judge(timed_out)
    assert not ok and "exited 124" in note

    # Incomplete line without trailing newline is not parsed yet.
    partial = (
        MEMERR_TRANSCRIPT
        + ISA_ABSENT_ECHO
        + f"{hw.LINUX_ISA_PROBE_EXIT_TOKEN} id={ISA_RUN_ID} rc=124"
    )
    assert not stage().failure_done(partial)


def test_supm_probe_command_verdicts_and_failure_modes() -> None:
    """Verify frost_supm_probe command wrapping resistance, coverage checks, and failures."""
    cmd = hw.supm_probe_command(ISA_RUN_ID)
    assert (
        f"timeout -k 5 {hw.LINUX_SUPM_PROBE_TIMEOUT_S} "
        f"/usr/local/bin/frost_supm_probe --run-id {ISA_RUN_ID}" in cmd
    )
    for wrap in range(len(cmd)):
        wrapped = f"{ISA_TRANSCRIPT}{cmd[:wrap]}\r\r\n{cmd[wrap:]}\r\r\n"
        fail, passed, _ = hw.supm_probe_verdict(wrapped, ISA_RUN_ID)
        assert not fail and not passed, wrap

    # Source file exists and is compiled as a plain scalar RV64GC program.
    supm_src = (
        REPO_ROOT
        / "linux/buildroot-external/package/frost-stress/src/frost_supm_probe.c"
    )
    assert supm_src.is_file()
    assert "frost_supm_probe" in hw.ROOT_PROGRAMS
    assert "frost_supm_probe" not in hw.ROOT_PROGRAM_EXT_LEAF_PREFIXES

    # Explicit case FAIL ends capture immediately.
    failed = (
        ISA_TRANSCRIPT
        + SUPM_ECHO
        + f"{hw.LINUX_SUPM_PROBE_TOKEN} id={ISA_RUN_ID} case=disable-fault "
        "verdict=FAIL reason=tagged_load_did_not_fault\r\r\n"
    )
    assert stage().failure_done(failed)
    ok, note = stage().judge(failed)
    assert not ok and "disable-fault: FAIL (tagged_load_did_not_fault)" in note

    # Missing case fails even with rc=0.
    missing_case = FULL_TRANSCRIPT.replace(
        f"{hw.LINUX_SUPM_PROBE_TOKEN} id={ISA_RUN_ID} case=pmlen7 "
        "verdict=PASS pmlen=7 loads=8 stores=8\r\r\n",
        "",
    )
    assert stage().failure_done(missing_case)
    ok, note = stage().judge(missing_case)
    assert not ok and "missing pmlen7" in note

    # Zero or invalid positive coverage fields fail even with rc=0.
    for before, after, expected in (
        ("hwprobe=1", "hwprobe=0", "discover hwprobe=0"),
        ("pmlen=7 loads=8", "pmlen=0 loads=8", "pmlen7 pmlen=0"),
        ("syscall=1", "syscall=0", "syscall=0"),
        ("store_sigsegv=1", "store_sigsegv=0", "disable-fault store_sigsegv='0'"),
        (
            "store_unmodified=1",
            "store_unmodified=0",
            "disable-fault store_unmodified='0'",
        ),
    ):
        mutated = FULL_TRANSCRIPT.replace(before, after, 1)
        assert mutated != FULL_TRANSCRIPT
        assert stage().failure_done(mutated)
        ok, note = stage().judge(mutated)
        assert not ok and expected in note

    # Nonzero wrapper exit code ends capture immediately; partial line waits.
    timed_out = (
        ISA_TRANSCRIPT
        + SUPM_ECHO
        + f"{hw.LINUX_SUPM_PROBE_EXIT_TOKEN} id={ISA_RUN_ID} rc=124\r\r\n"
    )
    assert stage().failure_done(timed_out)
    ok, note = stage().judge(timed_out)
    assert not ok and "exited 124" in note
    partial = (
        ISA_TRANSCRIPT
        + SUPM_ECHO
        + f"{hw.LINUX_SUPM_PROBE_EXIT_TOKEN} id={ISA_RUN_ID} rc=124"
    )
    assert not stage().failure_done(partial)

    # Pre-login lines cannot satisfy the post-login check.
    before_prompt = BOOT_TO_LOGIN[: -len(hw.LINUX_LOGIN_PROMPT)]
    early = (
        before_prompt
        + SUPM_LINES
        + hw.LINUX_LOGIN_PROMPT
        + LOGIN_TO_SHELL
        + MOUNT_ECHO
        + MOUNT_LINE
        + DRIVER_ECHO
        + DRIVER_LINE
        + SYSTEMD_ECHO
        + SYSTEMD_RUNNING
        + STRESS_ECHO
        + STRESS_OUT
        + COUNTER_ECHO
        + COUNTER_LINE
        + MEMERR_ECHO
        + MEMERR_LINE
        + ISA_ABSENT_ECHO
        + ISA_ABSENT_LINES
        + NET_ECHO
        + NET_START
        + NET_PASS
        + NET_ALIVE
    )
    assert not stage().success_done(early)


def test_linux_dtb_option_env_preflight_and_cli_dispatch(
    prepared: tuple[Any, dict[str, str]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """--linux-dtb and FROST_LINUX_DTB validate the DTB and forward it to the loader."""
    root, environment = prepared
    dtb = tmp_path / "custom.dtb"
    dtb.write_bytes(_valid_dtb_bytes())

    # Env resolution and loader_env forwarding.
    base_env = {hw.LINUX_NFSROOT_ENV: NFSROOT, hw.LINUX_IP_ENV: BOARD_IP}
    from_env = hw.linux_root_from_env({**base_env, hw.LINUX_DTB_ENV: str(dtb)}, site={})
    assert from_env.dtb == dtb.resolve()
    assert hw.linux_loader_env(from_env)[hw.LINUX_DTB_ENV] == str(dtb.resolve())

    # CLI override wins over environment.
    dtb2 = tmp_path / "override.dtb"
    dtb2.write_bytes(_valid_dtb_bytes())
    from_cli = hw.linux_root_from_env(
        {**base_env, hw.LINUX_DTB_ENV: str(dtb)}, site={}, dtb_override=dtb2
    )
    assert from_cli.dtb == dtb2.resolve()

    # Preflight accepts a valid DTB and rejects bad/missing/oversized DTBs.
    notes = hw.linux_root_preflight(
        dataclasses.replace(root, dtb=dtb), REPO_ROOT, environment
    )
    assert any(f"device tree {dtb}" in note for note in notes)

    bad = tmp_path / "bad.dtb"
    bad.write_bytes(b"not a dtb" * 8)
    with pytest.raises(hw.LinuxEnvironmentError, match="not a valid compiled DTB"):
        hw.linux_root_preflight(
            dataclasses.replace(root, dtb=bad), REPO_ROOT, environment
        )

    huge = tmp_path / "huge.dtb"
    huge.write_bytes(_valid_dtb_bytes(0xF000))
    with pytest.raises(hw.LinuxEnvironmentError, match="exceeds the boot DTB slot"):
        hw.linux_root_preflight(
            dataclasses.replace(root, dtb=huge), REPO_ROOT, environment
        )

    with pytest.raises(hw.LinuxEnvironmentError, match="is not a file"):
        hw.linux_root_preflight(
            dataclasses.replace(root, dtb=tmp_path / "missing.dtb"),
            REPO_ROOT,
            environment,
        )

    # CLI forwards --linux-dtb and --linux-isa-expect through main().
    seen = _stub_board(monkeypatch)
    seen_expect: list[str] = []
    real_linux_stage = hw.linux_stage

    def capture_stage(*args: Any, **kwargs: Any) -> Any:
        seen_expect.append(kwargs.get("isa_expect", hw.LINUX_ISA_EXPECT_DEFAULT))
        return real_linux_stage(*args, **kwargs)

    monkeypatch.setattr(hw, "linux_stage", capture_stage)
    monkeypatch.setattr(hw, "linux_root_preflight", lambda *args, **kwargs: ["stub"])
    for name, value in hw.linux_loader_env(ROOT).items():
        monkeypatch.setenv(name, value)
    monkeypatch.setattr(
        hw.sys,
        "argv",
        [
            "runner",
            "--board",
            "x3",
            "--linux-dtb",
            str(dtb),
            "--linux-isa-expect",
            "present",
            "linux_boot",
        ],
    )
    assert hw.main() == 0
    assert seen[hw.LINUX_STAGE]["env"][hw.LINUX_DTB_ENV] == str(dtb.resolve())
    assert seen_expect == ["present"]


def _build_fdt_with_cpu_isa(isa_str: str, ext_list: tuple[str, ...]) -> bytes:
    """Build a minimal compiled FDT with ``/cpus/cpu@0`` ISA properties."""

    def pad4(data: bytes) -> bytes:
        rem = len(data) & 3
        return data if rem == 0 else data + b"\x00" * (4 - rem)

    strings = b"riscv,isa\x00riscv,isa-extensions\x00"
    off_isa = 0
    off_ext = len(b"riscv,isa\x00")
    val_isa = isa_str.encode("ascii") + b"\x00"
    val_ext = b"".join(tok.encode("ascii") + b"\x00" for tok in ext_list)

    struct_parts = [
        struct.pack(">I", 1),
        pad4(b"\x00"),  # /
        struct.pack(">I", 1),
        pad4(b"cpus\x00"),
        struct.pack(">I", 1),
        pad4(b"cpu@0\x00"),
        struct.pack(">3I", 3, len(val_isa), off_isa),
        pad4(val_isa),
        struct.pack(">3I", 3, len(val_ext), off_ext),
        pad4(val_ext),
        struct.pack(">I", 2),  # end cpu@0
        struct.pack(">I", 2),  # end cpus
        struct.pack(">I", 2),  # end /
        struct.pack(">I", 9),  # FDT_END
    ]
    struct_block = b"".join(struct_parts)
    off_mem_rsvmap = 40
    mem_rsvmap = b"\x00" * 16
    off_struct = off_mem_rsvmap + len(mem_rsvmap)
    off_strings = off_struct + len(struct_block)
    totalsize = off_strings + len(strings)
    header = struct.pack(
        ">10I",
        0xD00DFEED,
        totalsize,
        off_struct,
        off_strings,
        off_mem_rsvmap,
        17,
        16,
        0,
        len(strings),
        len(struct_block),
    )
    return header + mem_rsvmap + struct_block + strings


def test_isa_probe_accepts_vlen_128_256_512_and_resolves_from_dtb_or_rtl(
    tmp_path: Path,
) -> None:
    """Stage accepts 128/256/512-bit widths and derives expected vlenb from DTB or RTL."""
    for vlenb in (16, 32, 64):
        regset_bytes = 40 + 32 * vlenb
        lines = (
            ISA_PRESENT_LINES.replace("vlenb=32", f"vlenb={vlenb}")
            .replace("active_bytes=1064", f"active_bytes={regset_bytes}")
            .replace("note_bytes=1064", f"note_bytes={regset_bytes}")
        )
        transcript = (
            MEMERR_TRANSCRIPT
            + hw.isa_probe_command(ISA_RUN_ID, "present", vlenb)
            + "\r\r\n"
            + lines
            + SUPM_ECHO
            + SUPM_LINES
            + NET_ECHO
            + NET_START
            + NET_PASS
            + NET_ALIVE
        )
        # Auto mode (isa_vlenb=None) accepts any supported width with consistent byte counts.
        auto_stage = hw.linux_stage(ROOT, isa_expect="present", isa_run_id=ISA_RUN_ID)
        assert auto_stage.success_done(transcript)
        assert not auto_stage.failure_done(transcript)
        assert auto_stage.judge(transcript)[0]
        # Explicit expected vlenb accepts matching width and rejects mismatched width.
        exact_stage = hw.linux_stage(
            ROOT, isa_expect="present", isa_run_id=ISA_RUN_ID, isa_vlenb=vlenb
        )
        assert exact_stage.judge(transcript)[0]
        wrong_vlenb = 64 if vlenb != 64 else 32
        wrong_stage = hw.linux_stage(
            ROOT, isa_expect="present", isa_run_id=ISA_RUN_ID, isa_vlenb=wrong_vlenb
        )
        assert wrong_stage.failure_done(transcript)
        assert f"discover vlenb='{vlenb}'" in wrong_stage.judge(transcript)[1]

    # resolve_isa_vlenb prefers DTB zvl<N>b over RTL, then board top, then hw/rtl/frost.sv.
    fake_repo = tmp_path / "repo"
    (fake_repo / "boards/x3").mkdir(parents=True)
    (fake_repo / "hw/rtl").mkdir(parents=True)
    (fake_repo / "boards/x3/x3_frost.sv").write_text("  .VLEN(512),\n")
    (fake_repo / "hw/rtl/frost.sv").write_text("parameter int unsigned VLEN = 256,\n")
    assert hw.resolve_isa_vlenb(fake_repo, "x3", None) == 64

    dtb_128 = tmp_path / "v128.dtb"
    dtb_128.write_bytes(
        _build_fdt_with_cpu_isa(
            "rv64imafdcv_zvl128b", ("i", "m", "a", "f", "d", "c", "v", "zvl128b")
        )
    )
    assert hw.resolve_isa_vlenb(fake_repo, "x3", dtb_128) == 16

    # DTB without zvl*b falls back to the board RTL parameter.
    dtb_no_zvl = tmp_path / "nozvl.dtb"
    dtb_no_zvl.write_bytes(
        _build_fdt_with_cpu_isa("rv64imafdcv_zfa", ("i", "m", "a", "f", "d", "c", "v"))
    )
    assert hw.resolve_isa_vlenb(fake_repo, "x3", dtb_no_zvl) == 64

    # Repository's real X3 top resolves to 32 (VLEN=256).
    assert hw.resolve_isa_vlenb(REPO_ROOT, "x3", None) == 32


def test_preflight_scalar_binary_scan_fails_closed_and_scopes_leaf_exception(
    prepared: tuple[Any, dict[str, str]],
) -> None:
    """Binary scan fails closed on tool errors and limits probe encodings to leaf symbols."""
    root, environment = prepared
    prefix = environment[hw.CROSS_COMPILE_ENV]
    readelf = Path(prefix + "readelf")
    objdump = Path(prefix + "objdump")
    clean_readelf = readelf.read_text()
    clean_objdump = objdump.read_text()

    # 1. Missing readelf fails closed instead of passing silently.
    readelf.unlink()
    with pytest.raises(hw.LinuxEnvironmentError, match="readelf is not on PATH"):
        hw.linux_root_preflight(root, REPO_ROOT, environment)

    # 2. Nonzero readelf exit fails closed.
    readelf.write_text("#!/bin/sh\necho bad >&2\nexit 1\n")
    readelf.chmod(0o755)
    with pytest.raises(hw.LinuxEnvironmentError, match="readelf -A failed"):
        hw.linux_root_preflight(root, REPO_ROOT, environment)

    # 3. Missing Tag_RISCV_arch fails closed.
    readelf.write_text("#!/bin/sh\necho 'Attribute Section: riscv'\n")
    with pytest.raises(hw.LinuxEnvironmentError, match="no Tag_RISCV_arch"):
        hw.linux_root_preflight(root, REPO_ROOT, environment)

    # 4. Static C library carrying V or Zve* extension tag is rejected.
    readelf.write_text(
        "#!/bin/sh\necho '  Tag_RISCV_arch: \"rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_v1p0\"'\n"
    )
    with pytest.raises(hw.LinuxEnvironmentError, match="Tag_RISCV_arch"):
        hw.linux_root_preflight(root, REPO_ROOT, environment)
    readelf.write_text(clean_readelf)

    # 5. Missing or failing objdump fails closed.
    objdump.unlink()
    with pytest.raises(hw.LinuxEnvironmentError, match="objdump is not on PATH"):
        hw.linux_root_preflight(root, REPO_ROOT, environment)
    objdump.write_text("#!/bin/sh\nexit 1\n")
    objdump.chmod(0o755)
    with pytest.raises(hw.LinuxEnvironmentError, match="objdump -d failed"):
        hw.linux_root_preflight(root, REPO_ROOT, environment)

    # 6. Explicit leaf-routine exception allows isa_probe_* ONLY inside frost_isa_probe.
    objdump.write_text(
        "#!/bin/sh\n"
        'for a in "$@"; do last="$a"; done\n'
        'case "${last##*/}" in\n'
        "  frost_isa_probe)\n"
        "    printf '0000000000010000 <isa_probe_first_use_vsetvli>:\\n"
        "   10000:\\t00807557\\tvsetvli\\ta0,zero,e16,m1,tu,mu\\n'\n"
        "    ;;\n"
        "  *)\n"
        "    printf '0000000000010000 <main>:\\n   10000:\\t00000013\\taddi\\tzero,zero,0\\n'\n"
        "    ;;\n"
        "esac\n"
    )
    assert hw.linux_root_preflight(root, REPO_ROOT, environment)

    # 7. Extended opcode outside isa_probe_* inside frost_isa_probe is rejected.
    objdump.write_text(
        "#!/bin/sh\n"
        'for a in "$@"; do last="$a"; done\n'
        'case "${last##*/}" in\n'
        "  frost_isa_probe)\n"
        "    printf '0000000000010000 <__libc_start_main>:\\n"
        "   10000:\\t00807557\\tvsetvli\\ta0,zero,e16,m1,tu,mu\\n'\n"
        "    ;;\n"
        "  *)\n"
        "    printf '0000000000010000 <main>:\\n   10000:\\t00000013\\taddi\\tzero,zero,0\\n'\n"
        "    ;;\n"
        "esac\n"
    )
    with pytest.raises(hw.LinuxEnvironmentError, match="__libc_start_main"):
        hw.linux_root_preflight(root, REPO_ROOT, environment)

    # 8. Other root programs get NO leaf exception even for a matching symbol prefix.
    objdump.write_text(
        "#!/bin/sh\n"
        "printf '0000000000010000 <isa_probe_fake>:\\n"
        "   10000:\\t00807557\\tvsetvli\\ta0,zero,e16,m1,tu,mu\\n'\n"
    )
    with pytest.raises(hw.LinuxEnvironmentError, match="frost_stress"):
        hw.linux_root_preflight(root, REPO_ROOT, environment)
    objdump.write_text(clean_objdump)
    assert hw.linux_root_preflight(root, REPO_ROOT, environment)


def test_frost_isa_probe_host_selftest_and_sources(tmp_path: Path) -> None:
    """Build frost_isa_probe's parser self-test natively and run it."""
    assert ISA_PROBE_SOURCE.is_file() and ISA_PROBE_ASM.is_file()
    compiler = next(
        (hw.shutil.which(name) for name in ("cc", "gcc") if hw.shutil.which(name)), None
    )
    if compiler is None:
        pytest.skip("no native C compiler")
    binary = tmp_path / "frost_isa_probe_selftest"
    built = hw.subprocess.run(
        [
            compiler,
            "-DFROST_ISA_PROBE_HOST_SELFTEST",
            "-O2",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-o",
            str(binary),
            str(ISA_PROBE_SOURCE),
        ],
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert built.returncode == 0, built.stderr
    done = hw.subprocess.run(
        [str(binary), "--selftest"], capture_output=True, text=True, timeout=30
    )
    assert done.returncode == 0, done.stdout
    assert done.stdout.endswith("FROST_ISA_SELFTEST_PASS\n")
    for case in (
        "sha256",
        "isa-parser",
        "dt-parser",
        "core-valid",
        "core-scalar",
        "core-owner",
        "core-truncated",
        "cpuinfo-zero",
        "first-use-budget",
        "progress-format",
    ):
        assert f"FROST_ISA_SELFTEST {case}: pass\n" in done.stdout

    # Untraced present-mode cases must run before tracefs-based first-use in run_suite.
    src = ISA_PROBE_SOURCE.read_text(encoding="utf-8")
    suite_body = src[src.index("if (disc.mode == OBS_PRESENT) {") :]
    suite_body = suite_body[: suite_body.index("/* Stock / absent matrix")]
    first_use_pos = suite_body.index("run_first_use(")
    for fn in (
        "run_switch(",
        "run_signal(",
        "run_ptrace(",
        "run_core(",
        "run_fork_case(",
        "run_exec_case(",
    ):
        assert suite_body.index(fn) < first_use_pos, fn


def test_linux_stage_replays_first_use_phase1_timeout_capture() -> None:
    """Replay a captured present-mode first-use phase1_timeout console log.

    Set ``FROST_TEST_LINUX_CAPTURE_FAIL`` to a captured console file to replay
    it directly through the integrated Linux stage judge.
    """
    capture_env = os.environ.get("FROST_TEST_LINUX_CAPTURE_FAIL", "").strip()
    if capture_env:
        transcript = Path(capture_env).read_bytes().decode("utf-8", errors="replace")
        clean = hw.console_text(transcript)
        match = hw.LINUX_ISA_CASE_RE.search(clean)
        assert match is not None, "capture carries no FROST_ISA_PROBE case line"
        run_id = match.group(1)
    else:
        raw = board_console()
        probe_start = raw.index(
            f"\x1b[?2004h{PROMPT}timeout -k 5 45 /usr/local/bin/frost_isa_probe suite "
        )
        run_id = "dd8b2724"
        captured_fail_block = (
            f"\x1b[?2004h{PROMPT}timeout -k 5 240 /usr/local/bin/frost_isa_probe suite "
            f"--vlenb 32 - \r-run-id {run_id}; printf 'FROST_ISA_PROBE_EXIT id=%s rc=%s\\n' "
            f'{run_id} "$?"\r\n'
            f"\x1b[?2004l\rFROST_ISA_PROBE_INFO id={run_id} case=discover "
            "of=/sys/firmware/devicetree/base/cpus/cpu@0 dt_ext_ok=1 dt_ext_v=1 "
            "dt_ext_zve=0 dt_ext_cnt=51 dt_isa_ok=1 dt_isa_v=1 dt_isa_zve=0 "
            "ci_ok=1 ci_isa_v=1 ci_hart_v=1\r\n"
            f"FROST_ISA_PROBE_INFO id={run_id} case=discover hwprobe_all_rc=0(e=0) "
            "base=0x1 ext0=0x1bff9300103ff hwprobe_hart_rc=0(e=0) hbase=0x1 "
            "hext0=0x1bff9300103ff hwcap=0x20112d prctl=2(e=0) default_allow=1\r\n"
            f"FROST_ISA_PROBE id={run_id} case=discover verdict=PASS "
            "mode=present vlenb=32 smoke=1\r\n"
            f"FROST_ISA_PROBE id={run_id} case=first-use verdict=FAIL "
            "reason=phase1_timeout\r\n"
        )
        transcript = raw[:probe_start] + captured_fail_block

    linux = hw.linux_stage(
        BOARD_ROOT,
        isa_expect="present",
        isa_run_id=run_id,
        isa_vlenb=32,
    )
    assert linux.failure_done(transcript)
    assert not linux.success_done(transcript)
    assert linux.failure_post_wait_s is not None
    assert linux.failure_post_wait_s(transcript) == hw.LINUX_ISA_FAILURE_WAIT_S
    ok, note = linux.judge(transcript)
    assert not ok
    assert "frost_isa_probe first-use: FAIL (phase1_timeout)" in note


def test_linux_stage_passes_with_synthetic_slow_first_use_setup() -> None:
    """Untraced cases precede first-use and a slow tracefs setup still passes."""
    assert hw.LINUX_ISA_PROBE_CASES["present"] == (
        "discover",
        "switch",
        "signal",
        "ptrace",
        "core",
        "fork",
        "exec",
        "first-use",
    )
    assert hw.LINUX_ISA_PROBE_TIMEOUT_S["present"] >= 420

    progress_and_verdicts = (
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=discover step=start t=0.000s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=discover step=surfaces_read t=0.120s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=discover step=smoke_start t=0.125s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=discover step=smoke_done t=0.290s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=discover step=done t=0.291s\r\r\n"
        f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=discover verdict=PASS mode=present vlenb=32 smoke=1\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=switch step=start t=0.295s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=switch step=workers_spawned t=0.330s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=switch step=done t=2.140s\r\r\n"
        f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=switch verdict=PASS rounds_a=64 rounds_b=64 cpu=0\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=signal step=start t=2.145s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=signal step=normal_start t=2.146s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=signal step=normal_done t=2.910s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=signal step=alt_start t=2.911s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=signal step=alt_done t=3.700s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=signal step=done t=3.701s\r\r\n"
        f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=signal verdict=PASS normal_rounds=8 alt_rounds=8 clobbers=16\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=ptrace step=start t=3.705s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=ptrace step=stop1_done t=3.920s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=ptrace step=stop2_done t=4.180s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=ptrace step=stop3_done t=4.390s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=ptrace step=done t=4.410s\r\r\n"
        f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=ptrace verdict=PASS inactive_einval=1 active_bytes=1064 setregset_ok=1 resumed_ok=1\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=core step=start t=4.415s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=core step=scalar_trial t=4.440s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=core step=live_trial t=5.120s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=core step=restore t=5.890s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=core step=done t=5.900s\r\r\n"
        f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=core verdict=PASS scalar_ok=1 note_bytes=1064 restored=1\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=fork step=start t=5.905s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=fork step=launcher_spawned t=5.940s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=fork step=child_exited t=6.420s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=fork step=done t=6.480s\r\r\n"
        f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=fork verdict=PASS ctrl_ok=1 inactive_einval=1 init_zero=1 isolated=1\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=exec step=start t=6.485s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=exec step=exec_on_start t=6.490s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=exec step=exec_off_start t=7.110s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=exec step=done t=7.650s\r\r\n"
        f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=exec verdict=PASS on_ok=1 off_sigill=1\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=start t=7.655s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=preflight_done t=8.920s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=spawn_child t=8.921s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=gate_ready t=9.230s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=mkdir t=9.231s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=filter t=14.530s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=pid t=64.180s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=tracer t=64.420s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=options t=64.700s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=enable t=64.750s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=setup_done t=65.418s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=phase1_release t=65.419s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=phase1_done t=65.422s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=phase2_release t=65.423s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=phase2_done t=65.430s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=cleanup t=65.431s\r\r\n"
        f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use step=done t=82.100s\r\r\n"
        f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=first-use verdict=PASS traps_before=0 traps_phase1=1 traps_phase2=1 missed=0 init_zero=1\r\r\n"
        f"{hw.LINUX_ISA_PROBE_SUMMARY_TOKEN} id={ISA_RUN_ID} mode=present passed=8 failed=0 verdict=PASS\r\r\n"
        f"{hw.LINUX_ISA_PROBE_EXIT_TOKEN} id={ISA_RUN_ID} rc=0\r\r\n{PROMPT}"
    )
    transcript = (
        MEMERR_TRANSCRIPT
        + hw.isa_probe_command(ISA_RUN_ID, "present", 32)
        + "\r\r\n"
        + progress_and_verdicts
        + SUPM_ECHO
        + SUPM_LINES
        + NET_ECHO
        + NET_START
        + NET_PASS
        + NET_ALIVE
    )
    linux = hw.linux_stage(
        ROOT, isa_expect="present", isa_run_id=ISA_RUN_ID, isa_vlenb=32
    )
    assert linux.success_done(transcript)
    assert not linux.failure_done(transcript)
    ok, note = linux.judge(transcript)
    assert ok, note
    assert "isa probe present (8/8 cases)" in note


def test_run_uart_stage_reads_console_for_60s_after_isa_case_fail_and_records_output(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """After an ISA probe case FAIL line, read and record 60 s of trailing console output."""
    linux = hw.linux_stage(
        ROOT, isa_expect="present", isa_run_id=ISA_RUN_ID, isa_vlenb=32
    )
    assert linux.failure_post_wait_s is not None
    assert linux.failure_post_wait_s(MEMERR_TRANSCRIPT + hw.LINUX_TOKEN_FAIL) == 0.0

    loader_fd, loader_write = os.pipe()
    serial_fd, serial_write = os.pipe()
    now = 0.0
    failure_time: float | None = None
    typed: list[str] = []
    printed: list[str] = []
    # Each entry is (deliver_at_s, payload_bytes).
    scheduled: list[tuple[float, bytes]] = []
    loader_chunks: list[bytes] = [(hw.LOAD_COMPLETE_SENTINEL + "\n").encode()]

    class CaptureStdout:
        def write(self, text: str) -> int:
            printed.append(text)
            return len(text)

        def flush(self) -> None:
            pass

    class FinishedLoader:
        returncode = 0

        def __init__(self, *_args: Any, **_kwargs: Any) -> None:
            self.stdout = SimpleNamespace(fileno=lambda: loader_fd)

        def poll(self) -> int:
            return 0

    pre_fail_prefix = (
        MEMERR_TRANSCRIPT
        + hw.isa_probe_command(ISA_RUN_ID, "present", 32)
        + "\r\r\n"
        + f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=discover verdict=PASS mode=present vlenb=32 smoke=1\r\r\n"
        + f"{hw.LINUX_ISA_PROBE_TOKEN} id={ISA_RUN_ID} case=first-use verdict=FAIL reason=phase1_timeout\r\r\n"
    )
    # Deliver after the loader sentinel resets serial_buf at t=0.0.
    scheduled.append((0.1, pre_fail_prefix.encode()))

    def fake_select(
        readable: list[int], _write: list[int], _error: list[int], timeout: float
    ) -> tuple[list[int], list[int], list[int]]:
        nonlocal now, failure_time
        ready: list[int] = []
        if loader_fd in readable and loader_chunks:
            ready.append(loader_fd)
        if serial_fd in readable and any(ts <= now for ts, _ in scheduled):
            ready.append(serial_fd)
        if ready:
            return ready, [], []
        now += timeout
        return [], [], []

    def fake_read(fd: int) -> bytes:
        nonlocal failure_time
        if fd == loader_fd:
            return loader_chunks.pop(0) if loader_chunks else b""
        due = [item for item in scheduled if item[0] <= now]
        if not due:
            return b""
        scheduled[:] = [item for item in scheduled if item[0] > now]
        payload = b"".join(chunk for _, chunk in due)
        if failure_time is None and b"case=first-use verdict=FAIL" in payload:
            failure_time = now
            scheduled.extend(
                [
                    (
                        failure_time + 10.0,
                        (
                            f"FROST_ISA_PROBE_INFO id={ISA_RUN_ID} case=first-use "
                            "step=cleanup t=80.000s\r\n"
                            f"{hw.LINUX_ISA_PROBE_SUMMARY_TOKEN} id={ISA_RUN_ID} "
                            "mode=present passed=1 failed=1 verdict=FAIL\r\n"
                            f"{hw.LINUX_ISA_PROBE_EXIT_TOKEN} id={ISA_RUN_ID} rc=1\r\n"
                        ).encode(),
                    ),
                    (
                        failure_time + 45.0,
                        b"[  780.000000] Oops: delayed post-failure trace\r\n"
                        + PROMPT.encode(),
                    ),
                    (
                        failure_time + 65.0,
                        b"AFTER_60S_WINDOW_NOT_READ\r\n",
                    ),
                ]
            )
        return payload

    def fake_send(_fd: int, text: str) -> None:
        typed.append(text)

    monkeypatch.setattr(hw, "time", SimpleNamespace(monotonic=lambda: now))
    monkeypatch.setattr(hw, "select", SimpleNamespace(select=fake_select))
    monkeypatch.setattr(hw, "sys", SimpleNamespace(stdout=CaptureStdout()))
    monkeypatch.setattr(hw, "drain", lambda _fd: None)
    monkeypatch.setattr(hw, "read_available", fake_read)
    monkeypatch.setattr(hw.subprocess, "Popen", FinishedLoader)
    monkeypatch.setattr(hw, "send_uart_probe", fake_send)

    try:
        result = hw.run_uart_stage(
            tmp_path, serial_fd, "x3", linux, 300.0, [], "fixture-target"
        )
    finally:
        for fd in (loader_fd, loader_write, serial_fd, serial_write):
            os.close(fd)

    assert failure_time is not None
    assert result["status"] == "FAIL"
    assert hw.LINUX_ISA_FAILURE_WAIT_S == 60.0
    assert failure_time + 60.0 <= result["elapsed"] < failure_time + 61.0
    assert "frost_isa_probe first-use: FAIL (phase1_timeout)" in result["note"]
    assert "Oops" in result["note"]
    post = result["post_failure_output"]
    assert f"{hw.LINUX_ISA_PROBE_EXIT_TOKEN} id={ISA_RUN_ID} rc=1" in post
    assert "Oops: delayed post-failure trace" in post
    assert "AFTER_60S_WINDOW_NOT_READ" not in post
    combined_stdout = "".join(printed)
    driver_stdout = capsys.readouterr().out
    assert "reading console for 60s before ending stage" in driver_stdout
    assert "Oops: delayed post-failure trace" in combined_stdout
    assert "AFTER_60S_WINDOW_NOT_READ" not in combined_stdout
    assert not any("frost_nettest" in cmd for cmd in typed)


def test_vcu118_vector_regression_options(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """--vector enables VCU118 vector stages and forwards --vector to loader and sweep."""
    scalar_stages = hw.regression_stages("vcu118")
    vector_stages = hw.regression_stages("vcu118", vector=True)
    assert not (set(scalar_stages) & hw.VECTOR_UNIT_APPS)
    assert hw.VECTOR_UNIT_APPS <= set(vector_stages)
    assert "vec_state_test" in scalar_stages
    assert "vec_state_test" in vector_stages
    assert hw.resolve_isa_vlenb(REPO_ROOT, "vcu118", None) == 32

    assert hw.stage_loader_extra("hello_world", [], board="vcu118", vector=True) == [
        "--vector"
    ]
    assert hw.stage_loader_extra("hello_world", [], board="vcu118", vector=False) == [
        "--no-vector"
    ]
    assert hw.stage_loader_extra("hello_world", [], board="x3", vector=True) == []

    # CoreMark score calculation uses 162.5 MHz on VCU118 --vector.
    monkeypatch.delenv("FROST_CPU_CLK_HZ", raising=False)
    stage_vec = hw.build_stage("coremark", "vcu118", 1.0, vector=True)
    ok, note = stage_vec.judge("Total 64-bit ticks : 1625000000\n<<PASS>>\n")
    assert ok and "1080.00" in note
    stage_scalar = hw.build_stage("coremark", "vcu118", 1.0, vector=False)
    ok_s, note_s = stage_scalar.judge("Total 64-bit ticks : 2000000000\n<<PASS>>\n")
    assert ok_s and "1080.00" in note_s

    # CLI forwards --vector to UART stages and sweep_coremark_pro.
    seen_uart: dict[str, list[str]] = {}
    seen_sweep: list[list[str]] = []
    monkeypatch.setattr(hw, "serial_holders", lambda _serial: [])
    monkeypatch.setattr(hw, "configure_serial", lambda _serial: 99)
    monkeypatch.setattr(hw.os, "close", lambda _fd: None)

    def fake_uart(
        _repo: Path,
        _fd: int,
        _board: str,
        stage: Any,
        _timeout: float,
        loader_extra: list[str],
        _target: str,
        _loader_env: Any = None,
    ) -> dict[str, Any]:
        seen_uart[stage.app] = list(loader_extra)
        return {"stage": stage.app, "status": "PASS", "elapsed": 0.1, "note": "ok"}

    def fake_sweep(
        _repo: Path,
        _board: str,
        _serial: str,
        _target: str,
        _timeout: float,
        loader_extra: list[str],
        _tolerance: float,
        *,
        vector: bool | None = None,
    ) -> dict[str, Any]:
        assert vector is True
        seen_sweep.append(list(loader_extra))
        return {"stage": hw.SWEEP_STAGE, "status": "PASS", "elapsed": 0.1, "note": "ok"}

    monkeypatch.setattr(hw, "run_uart_stage", fake_uart)
    monkeypatch.setattr(hw, "run_sweep_stage", fake_sweep)
    monkeypatch.setattr(
        hw.sys,
        "argv",
        [
            "runner",
            "--board",
            "vcu118",
            "--vector",
            "vec_arith_test",
            "coremark_pro",
        ],
    )
    assert hw.main() == 0
    assert seen_uart == {"vec_arith_test": ["--vector"]}
    assert seen_sweep == [["--vector"]]

    # Reject x3 --no-vector and duplicate --vector in --loader-extra.
    for bad_argv, expected_err in (
        (
            ["--board", "x3", "--no-vector", "hello_world"],
            "--no-vector is only supported for vcu118",
        ),
        (
            [
                "--board",
                "vcu118",
                "--vector",
                "--loader-extra=--vector",
                "hello_world",
            ],
            "cannot also be passed through --loader-extra",
        ),
    ):
        monkeypatch.setattr(hw.sys, "argv", ["runner", *bad_argv])
        with pytest.raises(SystemExit) as stopped:
            hw.main()
        assert stopped.value.code == 2
        assert expected_err in capsys.readouterr().err
