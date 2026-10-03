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

"""Unit tests for hw_regression's Linux stage: its NFS-root preflight and judge.

No board and no server are needed. The stage's predicates, judge and stimulus
sequencing run against a console transcript of Debian 13 booting from its NFS
root over the NIC, in the shape ``docs/debian_nfsroot.md`` records (the driver's
probe line, the IP configuration, the mount, systemd's greeting, the console
autologin) and with the CRLF pairs the getty and bash emit. The counts and the
``findmnt`` line are written in each program's output format rather than
captured, since nothing in this repository can boot that root without hardware.
Other tests check the stage against a real board capture from
``tests/fixtures``.

The preflight is exercised against a tree under ``tmp_path``: a stub RPC server
answers the NFSv3 probe, and a stub compiler stands in for the cross toolchain,
so both the accept and the refuse paths are covered without an export.
"""

import dataclasses
import importlib.util
import os
import socket
import struct
import sys
import threading
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
# systemd prints its greeting as "Welcome to ", the ANSI color from
# /etc/os-release, the pretty name and a reset, so no substring of the
# console spans "Welcome to " and the name (systemd's main.c,
# status_welcome). The stage matches the name, which the console getty's
# /etc/issue carries as well.
SYSTEMD_GREETING = (
    "\r\r\nWelcome to \x1b[0;1;31mDebian GNU/Linux 13 (trixie)\x1b[0m!\r\r\n"
)
# Debian's kernel, its initramfs mounting the export over the NIC, systemd, and
# the console autologin the export configures (docs/debian_nfsroot.md).
BOOT_TO_LOGIN = (
    f"[    0.000000] {hw.KERNEL_BANNER}"
    "(debian-kernel@debian) (riscv64-linux-gnu-gcc-14 (Debian 14.2.0-19) "
    "14.2.0, GNU ld (GNU Binutils for Debian) 2.44) #1 SMP Debian "
    "6.12.107-1 (2026-08-29)\r\r\n"
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
    f"Linux frost {hw.KERNEL_RELEASE} #1 SMP Debian 6.12.107-1 riscv64\r\r\n"
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
# What the program prints when perf_event_open on the child fails.
COUNTER_FAIL_LINE = (
    f"FROST_COUNTERS: scope=exec-child counters=unavailable verdict=FAIL\r\r\n{PROMPT}"
)
# frost_nettest's first and last lines around its verdict (trimmed). The typed
# line also copies it to tmpfs and restores the link, which print nothing.
NET_ECHO = hw.nettest_command(ROOT.interface) + "\r\r\n"
NET_START = (
    "FROST_NET_LOOPBACK: eth0: driver frost_net10g, address 02:11:22:33:44:55, "
    "loopback feature bit 42, run 5b3f1d07; down\r\r\n"
)
NET_PASS = (
    f"FROST_NET_LOOPBACK: eth0 down, loopback off\r\r\n{hw.LINUX_NET_TOKEN}\r\r\n"
)
# The rest of that typed line: the MTU, flags and IPv6 restore print nothing,
# and the bounded sync prints its status, which is how the stage learns that the
# root came back with its link.
NET_ALIVE = f"{hw.LINUX_ROOT_ALIVE_TOKEN}=0\r\r\n{PROMPT}"
NET_STRANDED = f"{hw.LINUX_ROOT_ALIVE_TOKEN}=124\r\r\n{PROMPT}"
NET_FAIL = (
    f"{hw.LINUX_NET_TOKEN_FAIL} burst: expected frame 250, received frame 251 "
    f"(lost or reordered)\r\r\n{PROMPT}"
)

TO_SHELL = BOOT_TO_LOGIN + LOGIN_TO_SHELL
TO_MOUNT = TO_SHELL + MOUNT_ECHO + MOUNT_LINE
TO_SYSTEMD = TO_MOUNT + SYSTEMD_ECHO + SYSTEMD_RUNNING
TO_STRESS = TO_SYSTEMD + STRESS_ECHO + STRESS_OUT
COUNTER_TRANSCRIPT = TO_STRESS + COUNTER_ECHO + COUNTER_LINE
FULL_TRANSCRIPT = COUNTER_TRANSCRIPT + NET_ECHO + NET_START + NET_PASS + NET_ALIVE


def stage() -> Any:
    """Build the Linux stage for the transcript's root."""
    return hw.linux_stage(ROOT)


# --- The judge and the capture predicates ------------------------------------


def test_stage_passes_on_the_whole_debian_transcript() -> None:
    """The full transcript passes and the note names every piece of evidence."""
    linux = stage()
    assert linux.success_done(FULL_TRANSCRIPT)
    assert not linux.failure_done(FULL_TRANSCRIPT)
    ok, note = linux.judge(FULL_TRANSCRIPT)
    assert ok, note
    assert hw.KERNEL_RELEASE in note
    assert NFSROOT in note and "vers=3" in note
    assert "systemd running" in note
    assert "cycles=4433680" in note and "instret=3275440" in note
    assert hw.LINUX_NET_COMMAND in note


@pytest.mark.parametrize(
    "transcript,expected",
    [
        (BOOT_TO_LOGIN, "no nfs line"),
        (TO_MOUNT, "no 'running' line"),
        (TO_SYSTEMD, "no 'FROST_USERSPACE_STRESS_PASS' after the login"),
        (TO_STRESS, "no FROST_COUNTERS: count"),
        (COUNTER_TRANSCRIPT, "FROST_NET_LOOPBACK_PASS"),
        (
            COUNTER_TRANSCRIPT + NET_ECHO + NET_START + NET_PASS,
            f"no {hw.LINUX_ROOT_ALIVE_TOKEN}= status",
        ),
    ],
    ids=[
        "at-login",
        "after-findmnt",
        "after-systemctl",
        "after-stress",
        "after-counters",
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
    """The NIC driver's own line is what proves the module loaded on this root.

    Debian's initramfs modprobes it quietly, so there is no token from an init
    script of this tree's; the driver's probe message prints before the root is
    mounted, so it still precedes the getty.
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
    """Booting any kernel but the pinned one fails, userspace markers or not.

    The marker ends in a space, so a release that merely starts with the pinned
    one (a -debug build of the same version, say) does not satisfy it. The
    root's kernel must stay at the pin, and the preflight checks the packed file
    for exactly this release before the load.
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
    """Systemd's greeting puts an ANSI colour between "Welcome to " and the name.

    Requiring the whole greeting as one substring would fail every board run:
    the escape sits inside it. The transcript carries the escapes the console
    really shows, and no substring of it spans them.
    """
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
    """A server name that differs from the mount's address gets its own message.

    The initramfs mounts whatever ``nfsroot=`` gave it, and ``findmnt`` reports
    the address it used, so the message points at the one field that differs
    instead of reading as a wrong export.
    """
    ok, note = hw.root_mount_verdict(MOUNT_LINE, "server.example:/srv/nfs/debian")
    assert not ok
    assert "names that server server.example" in note
    assert "address the mount shows" in note


def test_a_degraded_systemd_is_terminal_and_names_the_state() -> None:
    """A failed unit ends the capture with the state, not with the timeout.

    The typed line lists the failed units before the state, so the capture that
    stops here already says which unit failed.
    """
    linux = stage()
    transcript = TO_MOUNT + SYSTEMD_ECHO + SYSTEMD_DEGRADED
    assert linux.failure_done(transcript), "the stage would run to the timeout"
    assert not linux.success_done(transcript)
    ok, note = linux.judge(transcript)
    assert not ok and "systemd is degraded, not running" in note
    assert "serial-getty@ttyS0.service" in transcript


def test_the_systemd_state_is_not_read_out_of_the_typed_command() -> None:
    """The board echoes every typed byte, and the command names its own state.

    The state is read from a ``state=`` line, which the echo cannot produce
    because the command writes ``state=$(...)``; matching a bare ``running``
    line would depend on where the terminal wrapped that echo. The echo is
    checked line by line, as the board sends it and as a wrap could break it.
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
    """The predicates run on a capture that grows byte by byte.

    The mount fields, the systemd state, and the root-alive status each wait for
    their line's newline. ``$`` also matches at the end of the buffer, so a read
    that stopped inside ``state=running`` would otherwise see the state ``r``
    and fail a healthy boot.
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
    """The stage types the stress run, so a token before the prompt cannot stand in.

    The Buildroot test initramfs prints the token from inittab, before the
    getty; a line like that on this root would not be the run the stage typed.
    """
    linux = stage()
    before_prompt = BOOT_TO_LOGIN[: -len(hw.LINUX_LOGIN_PROMPT)]
    early = (
        f"{before_prompt}{hw.LINUX_TOKEN}\r\r\n{hw.LINUX_LOGIN_PROMPT}"
        + LOGIN_TO_SHELL
        + MOUNT_ECHO
        + MOUNT_LINE
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
    """A failed counter run ends the capture instead of waiting out the deadline.

    It matches no success predicate, so a failure predicate has to match it, or
    the stage would run to its deadline. This checks the capture predicates, not
    only the judge.
    """
    linux = stage()
    transcript = TO_STRESS + COUNTER_ECHO + COUNTER_FAIL_LINE
    assert not linux.success_done(transcript)
    assert linux.failure_done(transcript), "the stage would run to the timeout"
    ok, note = linux.judge(transcript)
    assert not ok
    assert "counters=unavailable" in note and "verdict=FAIL" in note


def test_counters_are_not_matched_in_the_echo_or_the_stress_summary() -> None:
    """Only the counter run's own line counts.

    The typed command and the stress payload's summary line, which carries
    ``cycles=`` and ``instret=`` of its own, must not stand in for it.
    """
    assert hw.counter_values(TO_STRESS + COUNTER_ECHO) == {}
    assert "cycles=" in STRESS_OUT and "instret=" in STRESS_OUT


def test_nettest_fail_token_fails_the_stage_and_wins_over_pass() -> None:
    """frost_nettest's fail token ends capture and fails the stage, pass or not."""
    linux = stage()
    failed = COUNTER_TRANSCRIPT + NET_ECHO + NET_START + NET_FAIL
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


# --- The typed commands ------------------------------------------------------


def test_stimuli_fire_in_order_after_their_triggers() -> None:
    """Each stimulus fires once, in order, only after the previous trigger."""
    linux = stage()
    assert [text for _, text in linux.stimuli] == [
        "root\r",
        hw.LINUX_ROOT_MOUNT_COMMAND + "\r",
        hw.LINUX_SYSTEMD_COMMAND + "\r",
        hw.LINUX_STRESS_COMMAND + "\r",
        hw.LINUX_COUNTER_COMMAND + "\r",
        hw.nettest_command("eth0") + "\r",
    ]
    assert [trigger for trigger, _ in linux.stimuli[1:]] == [hw.LINUX_SHELL_PROMPT] * 5
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
        (TO_MOUNT, hw.LINUX_SYSTEMD_COMMAND),
        (TO_SYSTEMD, hw.LINUX_STRESS_COMMAND),
        (TO_STRESS, hw.LINUX_COUNTER_COMMAND),
        (COUNTER_TRANSCRIPT, hw.nettest_command("eth0")),
    ):
        # The prompt that took the previous command cannot fire this one.
        assert hw.next_stimulus(linux, transcript[: -len(PROMPT)], sent, after) is None
        typed, after = hw.next_stimulus(linux, transcript, sent, after)
        assert typed == expected + "\r"
        assert after == len(transcript)
        sent += 1
    assert hw.next_stimulus(linux, FULL_TRANSCRIPT, sent, after) is None


def test_the_autologin_stray_command_does_not_break_the_chain() -> None:
    """Under autologin the typed ``root`` reaches the shell as a command.

    agetty logs root in by itself, so the login answer the stage types is either
    flushed by ``login`` or read by bash, which reports it and prints a second
    prompt. The stage can then be one prompt ahead: the shell runs its commands
    in order all the same, since they queue on the terminal, and every stimulus
    still fires exactly once and in order.
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
        boot + MOUNT_ECHO + MOUNT_LINE + SYSTEMD_ECHO + SYSTEMD_RUNNING,
        boot
        + MOUNT_ECHO
        + MOUNT_LINE
        + SYSTEMD_ECHO
        + SYSTEMD_RUNNING
        + STRESS_ECHO
        + STRESS_OUT,
    ):
        pending = hw.next_stimulus(linux, transcript, sent, after)
        assert pending is not None, sent
        text, after = pending
        fired.append(text)
        sent += 1
    assert fired == [text for _, text in linux.stimuli]
    assert hw.next_stimulus(linux, boot + FULL_TRANSCRIPT, sent, after) is None


def test_the_typed_programs_are_named_by_absolute_path() -> None:
    """The payload re-execs itself with execv, which does not search PATH.

    Both commands therefore name the path the preflight installs them at, which
    is also in root's PATH on Debian.
    """
    assert hw.LINUX_ROOT_BIN == "/usr/local/bin"
    assert hw.LINUX_STRESS_COMMAND.startswith(f"{hw.LINUX_ROOT_BIN}/frost_stress ")
    assert hw.LINUX_COUNTER_COMMAND.startswith(f"{hw.LINUX_ROOT_BIN}/frost_stress ")
    assert f"{hw.LINUX_ROOT_BIN}/{hw.LINUX_NET_COMMAND}" in hw.nettest_command("eth0")


def test_nettest_runs_from_tmpfs_and_gives_the_roots_link_back() -> None:
    """frost_nettest takes down the interface the root is mounted over.

    It runs from a tmpfs copy, so a page fault on its own text cannot block on
    the hard mount it has just cut. IPv6 is off during the test, because the
    autoconfiguration frames a link-up sends come back through the loopback and
    fail its idle checks. Shell built-ins then restore the MTU and flags the line
    read first and turn IPv6 back on, so nothing has to be paged in from the root
    before the link is up. The bounded sync at the end reports whether the root
    really came back.
    """
    command = hw.nettest_command("enp1s0")
    sysfs = "/sys/class/net/enp1s0"
    ipv6 = "/proc/sys/net/ipv6/conf/enp1s0/disable_ipv6"
    run_at = command.index(f"{hw.LINUX_TMPFS}/frost_nettest;")
    assert f"cp {hw.LINUX_ROOT_BIN}/frost_nettest {hw.LINUX_TMPFS}/" in command
    assert command.index(f"cat {sysfs}/mtu") < run_at
    assert command.index(f"cat {sysfs}/flags") < run_at
    assert command.index(f"echo 1 > {ipv6}") < run_at
    assert command.index(f"echo $m > {sysfs}/mtu") > run_at
    assert command.index(f"echo $f > {sysfs}/flags") > command.index(
        f"echo $m > {sysfs}/mtu"
    )
    assert command.index(f"echo 0 > {ipv6}") > run_at
    # The liveness step creates a file, which is a round trip to the server,
    # where a sync over a clean tree would return without one.
    assert command.endswith(f"; echo {hw.LINUX_ROOT_ALIVE_TOKEN}=$?")
    assert f"timeout -k 5 {hw.LINUX_ROOT_SYNC_S} sh -c " in command
    assert f"echo frost > {hw.LINUX_ROOT_ALIVE_FILE} && sync" in command
    assert f"rm -f {hw.LINUX_ROOT_ALIVE_FILE}" in command
    assert command.index("timeout -k 5") > run_at
    # Every step of the recovery runs whatever the one before it did: the
    # restore must not be skipped because the test failed. Only the liveness
    # step chains with &&, so its status is the first thing that went wrong.
    assert " && " not in command[: command.index("timeout -k 5")]


def test_a_root_that_does_not_come_back_is_a_failure_not_a_pass() -> None:
    """The pass token is printed with the root's link still down.

    The program leaves the interface down, so a stage that ended at that token
    would report PASS for a root that never came back because a link, route, or
    server stayed away. On this board, bringing the root back exercises the
    NIC's own recovery path.
    """
    linux = stage()
    stranded = COUNTER_TRANSCRIPT + NET_ECHO + NET_START + NET_PASS + NET_STRANDED
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
    """Leave the site values unset however this machine would supply them.

    A developer box has fpga/site.env; CI does not. Without pointing the
    lookup at a file that is not there, these tests would assert an
    environment failure that only happens on the machines lacking one.
    """
    for name in hw.LINUX_ROOT_ENV_VARS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(hw, "SITE_ENV_FILE", Path("/nonexistent/site.env"))


def test_only_the_site_variables_are_required_and_are_named_when_unset() -> None:
    """The NFS root and IP settings have no default; an error names each one missing.

    A guess at the site would boot a board against somebody else's export.
    """
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
    assert hw.KERNEL_RELEASE in derived.kernel.name
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
    """A malformed, split or mismatched reply is reported, never a traceback.

    The probe speaks to whatever is on port 2049, so every field it reads is
    bounded first: an XID that is not the call's, a record that is not the last
    fragment, and the four-byte padding of the verifier all decide the answer.
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
    (boot / f"initrd.img-{kernel_release}").write_bytes(b"07070100000000" * 16)
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
    """Return a stub cross gcc and an environment that selects its prefix.

    The stub writes ``stub`` to its ``-o`` file.
    """
    binary_dir = tmp_path / "toolchain"
    binary_dir.mkdir()
    gcc = binary_dir / "stub-gcc"
    gcc.write_text(
        '#!/bin/sh\nwhile [ "$1" != "-o" ]; do shift; done\n'
        'printf stub > "$2"\nexit 0\n'
    )
    gcc.chmod(0o755)
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
    assert any("installed frost_stress, frost_nettest" in note for note in notes)
    for name in ("frost_stress", "frost_nettest"):
        installed = export / "usr/local/bin" / name
        assert installed.read_bytes() == b"stub"
        assert installed.stat().st_mode & 0o111
    assert not list((export / "usr/local/bin").glob(".*"))


@pytest.fixture
def prepared(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> tuple[Any, dict[str, str]]:
    """Return a prepared export and a stub toolchain, with the probe answering.

    The probe has its own tests against a stub RPC server; here it is replaced
    so that the rest of the preflight is exercised without a server.
    """
    export = _fake_export(tmp_path)
    _, environment = _fake_cross(tmp_path)
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
    """An initramfs of zero bytes would boot to an initramfs prompt."""
    root, environment = prepared
    root.initrd.write_bytes(b"")
    with pytest.raises(hw.LinuxEnvironmentError, match="is empty"):
        hw.linux_root_preflight(root, REPO_ROOT, environment)


def test_the_preflight_rejects_a_kernel_that_is_not_the_pin(
    prepared: tuple[Any, dict[str, str]],
) -> None:
    """The stage requires the pinned banner, so the packed file must carry it.

    Without this the operator's newer root kernel fails the stage on the board
    and reads as a regression.
    """
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
    """The scan reads in chunks, and the banner may straddle one.

    An Image is tens of megabytes, so the release has to be read without holding
    the whole file, and half a release must never be reported as the version.
    """
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
        (REPO_ROOT / "linux/debian-kernel").glob(f"*/boot/vmlinux-{hw.KERNEL_RELEASE}")
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
    """The preflight notes the module and the server's subnet but fails on neither.

    An initramfs that names the module is evidence it is there; a server outside
    the board's subnet is the case where the root's route may not come back after
    frost_nettest takes the interface down.
    """
    root, environment = prepared
    root.initrd.write_bytes(
        b"07070100000000usr/lib/modules/x/updates/dkms/frost_net10g.ko.xz\0"
    )
    notes = hw.linux_root_preflight(root, REPO_ROOT, environment)
    assert any("names frost_net10g" in note for note in notes)
    assert any("shares the board's subnet" in note for note in notes)
    # The docs' example server is on the board's subnet; another one is not.
    elsewhere = dataclasses.replace(root, server="198.51.100.9")
    assert "may not" in hw.subnet_note(elsewhere)[0]
    # An initramfs whose members are compressed says nothing either way.
    root.initrd.write_bytes(b"\x28\xb5\x2f\xfd" + b"\x00" * 512)
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
    """FROST_LINUX_CROSS_COMPILE wins, then Buildroot's own toolchain.

    Buildroot's is the second candidate because the loader's own stage 1a built
    it, so a Vivado host with no cross compiler installed still has one; the
    NIC module's build resolves its toolchain the same way.
    """
    gcc, environment = _fake_cross(tmp_path)
    buildroot_gcc = tmp_path / f"{hw.BUILDROOT_CROSS}gcc"
    buildroot_gcc.parent.mkdir(parents=True)
    buildroot_gcc.write_text("#!/bin/sh\nexit 1\n")
    buildroot_gcc.chmod(0o755)
    assert hw.resolve_cross_compile(tmp_path, environment) == str(gcc.parent / "stub-")
    assert hw.resolve_cross_compile(tmp_path, {}) == str(tmp_path / hw.BUILDROOT_CROSS)


def test_the_programs_are_built_from_this_checkouts_sources() -> None:
    """The sources the stage types are the Buildroot package's, built static.

    Buildroot links them against musl for the test initramfs, which a glibc
    Debian root cannot run, and frost_nettest has to be static to survive the
    link it takes down.
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
        seen[stage.app] = {"env": loader_env, "timeout": timeout_s}
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

# The UART capture of an X3 board run at 300 MHz, byte for byte: only the
# loader's interleaved stdout lines are removed, so every CR and every escape
# sequence is the board's. Debian's bash turns bracketed paste off as it starts
# each command, so the first line of each command's output arrives as
# ``ESC[?2004l CR <output>``, with the escape where the anchored patterns look
# for the line to start. A synthesized transcript cannot be trusted to carry
# that, so the judge is also checked against this one.
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


def test_the_real_board_capture_ends_and_passes_the_stage() -> None:
    """The real capture ends the stage and passes the judge.

    Every check in it printed and was correct, but the mount line and the
    systemd state sit behind a bracketed-paste escape, which the predicates must
    see past.
    """
    console = board_console()
    linux = hw.linux_stage(BOARD_ROOT)
    assert linux.success_done(console)
    assert not linux.failure_done(console)
    ok, note = linux.judge(console)
    assert ok, note
    assert hw.KERNEL_RELEASE in note
    assert BOARD_NFSROOT in note and "vers=3" in note
    assert "systemd running" in note
    assert "cycles=733467" in note and "instret=130278" in note
    assert "root alive" in note


def test_the_fixture_still_carries_the_escapes_it_is_here_for() -> None:
    """The fixture keeps the escapes it exists to cover.

    The bracketed-paste sequences, the coloured systemd greeting and the CRs are
    the whole reason this file is a fixture rather than a transcript written here.
    """
    console = board_console()
    assert console.count("\x1b[?2004l") == 5
    assert "\x1b[?2004l\rnfs " in console
    assert f"\x1b[?2004l\rstate={hw.LINUX_SYSTEMD_RUNNING}" in console
    assert "Welcome to \x1b[0m\x1b[1mDebian GNU/Linux" in console
    assert "\r\n" in console


def test_the_anchored_patterns_need_the_escapes_removed() -> None:
    """The anchored patterns read the real capture only after ``console_text``.

    Raw, the mount line and the state line match nothing, because the escape sits
    where the line starts; the same patterns read them once it is gone.
    """
    raw = board_console()
    assert hw.LINUX_ROOT_MOUNT_RE.search(raw) is None
    assert hw.LINUX_SYSTEMD_STATE_RE.search(raw) is None
    clean = hw.console_text(raw)
    assert hw.LINUX_ROOT_MOUNT_RE.search(clean) is not None
    assert hw.LINUX_SYSTEMD_STATE_RE.search(clean) is not None
    assert hw.systemd_state(clean) == hw.LINUX_SYSTEMD_RUNNING
    ok, note = hw.root_mount_verdict(clean, BOARD_NFSROOT)
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
    """The typed commands are sequenced on the raw capture, escapes and all.

    ``run_uart_stage`` searches the untouched buffer, because its offsets are
    into that buffer, so the triggers have to survive what the board sends: the
    prompt arrives as ``ESC[?2004h root@frost:~# `` and the getty's line as
    ``frost login: root (automatic login)``, which is what an autologin console
    prints and what the login marker matches. There is no prompt to answer, and
    ``login`` discards the answer the stage types, which is why this capture
    holds no stray command.
    """
    raw = board_console()
    linux = hw.linux_stage(BOARD_ROOT)
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


def test_console_text_keeps_what_the_stage_reads() -> None:
    """The transcript written in this file is unchanged by normalizing it.

    The escapes are the only thing removed, so a capture without any is passed
    through and every token, count and prompt still reads the same.
    """
    assert hw.console_text(MOUNT_LINE) == MOUNT_LINE
    assert hw.console_text(COUNTER_LINE) == COUNTER_LINE
    stripped = hw.console_text(FULL_TRANSCRIPT)
    assert hw.linux_stage(ROOT).judge(stripped)[0]
    assert stripped.count(PROMPT) == FULL_TRANSCRIPT.count(PROMPT)


# --- Stages and other apps ---------------------------------------------------


def test_default_stages_skip_debugger_driven_apps() -> None:
    """debug_target stays loadable but cannot pass unattended, so it is no stage."""
    stages = hw.regression_stages()
    assert "debug_target" in hw.VALID_APPS
    assert "debug_target" not in stages
    # nic_echo needs a link partner sending the cocotb wire peer's frames.
    assert "nic_echo" in hw.VALID_APPS
    assert "nic_echo" not in stages
    assert "nic_loopback" in stages
    assert stages[0] == "hello_world"
    assert stages[-3:] == [hw.SWEEP_STAGE, hw.LINUX_STAGE, hw.ECC_STAGE]
    assert not set(hw.COREMARK_PRO_APP_NAMES) & set(stages)
    assert len(stages) == len(set(stages))


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
    reply["stdout"] = "ECC read failed\n"
    assert hw.run_ecc_stage(ROOT, "x3", "some:target", 60.0)["status"] == "FAIL"


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
    """perf_off_test is a stage under a clock override too.

    build.py leaves the profiling counters out unless --perf-counters asks for
    them, at any clock, so the regression assumes them absent. Naming the
    stage next to an unknown one shows it is accepted: only the unknown name
    is rejected, and the valid list includes perf_off_test.
    """
    assert "perf_off_test" in hw.VALID_APPS
    assert "perf_off_test" in hw.regression_stages()
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
