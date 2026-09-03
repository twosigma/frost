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

A boot requires the ``FROST_USERSPACE_STRESS_PASS`` token followed by the
login prompt; ``--login-only`` requires only the prompt. Crash signatures,
timeout, or ``counters=unavailable`` fail. The counter result is mandatory
because FROST resets ``mcounteren`` to 0x7, making Zicntr U-readable.

The script reads 115200 8N1 directly through termios and reasserts the speed
after every load because Vivado hw_server FTDI probes can corrupt the UART
baud setting.

Usage:
    ./fpga/linux_boot_soak.py x3 --boots 5
    ./fpga/linux_boot_soak.py x3 --boots 10 --login-only
"""

import argparse
import os
import subprocess
import sys
import termios
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "fpga" / "common"))

from hw_defaults import DEFAULT_SERIALS  # noqa: E402

PASS_TOKEN = "FROST_USERSPACE_STRESS_PASS"
FAIL_TOKEN = "FROST_USERSPACE_STRESS_FAIL"
LOGIN_MARKER = "login:"
CRASH_MARKERS = (
    "Attempted to kill init",
    "Kernel panic",
    "not syncing",
    "Oops",
    "Bad trap",
    "SIGILL",
    FAIL_TOKEN,
)


def open_uart(device: str) -> int:
    """Open the UART raw/non-blocking and force 115200 8N1."""
    fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    force_baud(fd)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def force_baud(fd: int) -> None:
    """(Re-)assert 115200 8N1 raw; hw_server FTDI probes can wedge this."""
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

    Returns (verdict, transcript). PASS requires the login prompt and, when
    expect_stress, the payload token before it.
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
            if not expect_stress or PASS_TOKEN in text:
                return ("PASS", text)
            # Missing token means the payload was skipped or its output was lost.
            return ("FAIL(login-without-stress-token)", text)
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
        help="Assert only the login prompt (image without the stress payload)",
    )
    parser.add_argument(
        "--timeout-per-boot",
        type=int,
        default=600,
        help="Seconds from load completion to required boot outcome",
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
            force_baud(fd)  # undo any hw_server termios wedge from the load
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
                # Only QEMU may degrade; FROST resets all counters enabled.
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
