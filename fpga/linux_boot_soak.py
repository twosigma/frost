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

"""Repeatedly load and score Linux boots from the board UART.

The boot is Debian's pinned riscv64 kernel with the Buildroot test initramfs
(``linux/debian_kernel.py``). Before the login prompt, a boot must print the
NIC module's ``FROST_NET10G_MODULE_PASS <release>`` line (Debian's kernel has
no FROST driver built in, and the line names the running release) and the
``FROST_USERSPACE_STRESS_PASS`` token; ``--login-only`` requires only the
prompt. A crash signature or a timeout fails the boot, and so does
``counters=unavailable``: the boot image's DTB maps the cycle and instruction
events to FROST's fixed counters, so the SBI PMU must serve them to the stress
payload's ``perf_event_open``.

The script reads the UART at 115200 8N1 through termios and sets the speed
again after every load, because Vivado hw_server's FTDI probes can corrupt the
UART baud setting.

Usage:
    ./fpga/linux_boot_soak.py x3 --boots 5
    ./fpga/linux_boot_soak.py x3 --boots 10 --login-only
"""

import argparse
import os
import re
import subprocess
import sys
import termios
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "fpga" / "common"))
sys.path.insert(0, str(REPO_ROOT / "linux"))

from debian_kernel import (  # noqa: E402
    MODULE_FAIL_TOKEN,
    MODULE_PASS_LINE,
    MODULE_PASS_RE,
)
from hw_defaults import DEFAULT_SERIALS  # noqa: E402

PASS_TOKEN = "FROST_USERSPACE_STRESS_PASS"
FAIL_TOKEN = "FROST_USERSPACE_STRESS_FAIL"
# Both are printed from sysinit entries, so both precede the login prompt. The
# module line carries the release its init script read from ``uname -r``. The
# whole line must match, up to a boundary, so a longer release cannot satisfy
# it. The pinned kernel sets CONFIG_MODVERSIONS, so Linux ignores the release
# field of vermagic and a successful insmod alone does not identify the kernel.
BOOT_TOKENS = (
    (MODULE_PASS_LINE, MODULE_PASS_RE),
    (PASS_TOKEN, re.compile(re.escape(PASS_TOKEN))),
)
LOGIN_MARKER = "login:"
CRASH_MARKERS = (
    "Attempted to kill init",
    "Kernel panic",
    "not syncing",
    "Oops",
    "Bad trap",
    "SIGILL",
    FAIL_TOKEN,
    MODULE_FAIL_TOKEN,
)


def open_uart(device: str) -> int:
    """Open the UART raw/non-blocking and force 115200 8N1."""
    fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    force_baud(fd)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def force_baud(fd: int) -> None:
    """Set raw 115200 8N1; hw_server's FTDI probes can corrupt the setting."""
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0  # iflag
    attrs[1] = 0  # oflag
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL  # cflag
    attrs[3] = 0  # lflag
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def drain(fd: int) -> bytes:
    """Read whatever is buffered without blocking."""
    chunks = []
    while True:
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            break
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


def run_load(board: str, vivado_path: str) -> int:
    """JTAG-load ``linux_boot`` and return the loader status."""
    cmd = [
        sys.executable,
        str(REPO_ROOT / "fpga" / "load_software" / "load_software.py"),
        board,
        "linux_boot",
    ]
    if vivado_path:
        cmd += ["--vivado-path", vivado_path]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stdout.write(result.stdout[-2000:])
        sys.stdout.write(result.stderr[-2000:])
    return result.returncode


def score_boot(fd: int, expect_stress: bool, timeout_s: int) -> tuple[str, str]:
    """Watch the UART until the boot passes, crashes, or times out.

    Returns (result, transcript), where result is PASS, FAIL(...) or
    TIMEOUT(...). PASS requires the login prompt and, when expect_stress,
    every BOOT_TOKENS entry before it.
    """
    deadline = time.monotonic() + timeout_s
    transcript = b""
    while time.monotonic() < deadline:
        transcript += drain(fd)
        text = transcript.decode("utf-8", errors="replace")
        for marker in CRASH_MARKERS:
            if marker in text:
                return (f"FAIL({marker})", text)
        if LOGIN_MARKER in text:
            if not expect_stress:
                return ("PASS", text)
            missing = [
                label for label, pattern in BOOT_TOKENS if not pattern.search(text)
            ]
            if not missing:
                return ("PASS", text)
            # A missing line means the entry was skipped, its output was lost,
            # or the kernel is not the one the module was built for.
            return (f"FAIL(login-without-{'-and-'.join(missing)})", text)
        time.sleep(0.5)
    return (f"TIMEOUT({timeout_s}s)", transcript.decode("utf-8", errors="replace"))


def main() -> int:
    """Run the soak; return 0 iff every boot passes."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("board", choices=list(DEFAULT_SERIALS))
    parser.add_argument("--boots", type=int, default=5)
    parser.add_argument(
        "--login-only",
        action="store_true",
        help="Require only the login prompt (for an image without the stress test)",
    )
    parser.add_argument(
        "--timeout-per-boot",
        type=int,
        default=600,
        help="Seconds to wait after each load for the boot result",
    )
    parser.add_argument("--vivado-path", default="vivado")
    parser.add_argument(
        "--uart",
        default="",
        help=f"UART device (default: per-board {DEFAULT_SERIALS})",
    )
    args = parser.parse_args()

    uart_device = args.uart or DEFAULT_SERIALS[args.board]
    fd = open_uart(uart_device)
    passes = 0
    failures = 0
    try:
        for boot in range(1, args.boots + 1):
            termios.tcflush(fd, termios.TCIFLUSH)
            print(f"boot {boot}/{args.boots}: loading ...", flush=True)
            rc = run_load(args.board, args.vivado_path)
            force_baud(fd)  # the load's hw_server session can change the UART settings
            if rc != 0:
                print(f"boot {boot}: LOAD-FAIL rc={rc}", flush=True)
                failures += 1
                continue
            verdict, transcript = score_boot(
                fd, expect_stress=not args.login_only, timeout_s=args.timeout_per_boot
            )
            stress_line = next(
                (
                    line.strip()
                    for line in transcript.splitlines()
                    if "FROST_USERSPACE_STRESS:" in line and "verdict=" in line
                ),
                "",
            )
            if (
                verdict == "PASS"
                and not args.login_only
                and "counters=unavailable" in stress_line
            ):
                # The boot image's DTB gives the SBI PMU both fixed counters,
                # so a FROST boot must be able to read them.
                verdict = "FAIL(counters-unavailable)"
            print(f"boot {boot}: {verdict}  {stress_line}", flush=True)
            if verdict == "PASS":
                passes += 1
            else:
                failures += 1
    finally:
        os.close(fd)

    print(f"SOAK RESULT: {passes} PASS, {failures} FAIL of {args.boots}", flush=True)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
