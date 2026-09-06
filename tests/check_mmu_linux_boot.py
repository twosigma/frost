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

"""Assert the health of an OpenSBI + Sv39 Linux boot from a cocotb capture log.

The CI ``linux-boot-cocotb-mmu`` job boots the MMU Linux images on the FROST
RTL in ``FROST_LINUX_RUN_FULL`` capture mode with ``COCOTB_PROGRESS_INTERVAL``
set, so the log carries the console plus per-interval retire and timer lines.
The simulated core boots at a few thousand cycles per second, so the job
asserts a bounded checkpoint rather than the userspace token (that is the
QEMU job's and the hardware soak's role); the checkpoint proves the parts of
the boot that the firmware and the RTL must get right.

Health criteria (all must hold):
  1. OpenSBI's banner, with the hart classified as privileged v1.12 (the
     ``mcountinhibit`` probe) and the ISA extension line carrying ``sstc``
     and ``svade`` (the DT and the firmware's own CSR probes agree),
  2. the kernel banner (``Linux version``), then the SBI probe lines
     (``SBI implementation ID=0x1`` = OpenSBI) and OpenSBI's reserved-memory
     fixup as the kernel sees it (``mmode_resv``),
  3. the kernel's timer driver took the Sstc path (``riscv-timer: Timer
     interrupt in S-mode is available via sstc extension``: the DT's
     extension list was parsed and stimecmp is what the kernel arms),
  4. early init reached (``devtmpfs: initialized``),
  5. no panic, oops, unhandled exception, or firmware trap error,
  6. the run reached at least ``--min-cycle``,
  7. the core was still retiring instructions in the final progress window,
  8. the S-mode timer was serviced: ``stimecmp`` was re-armed to at least
     ``--min-timer-arms`` distinct non-disabled values (Sstc; the no-MMU
     lane's equivalent was the mtimecmp criterion).

Optional depth markers, for runs that go far enough (local or hardware
captures): ``--require-init`` (``Run /init as init process``) and
``--require-token`` (``FROST_USERSPACE_STRESS_PASS``).

Usage: ``check_mmu_linux_boot.py <cocotb-boot-log> [options]``
"""

import argparse
import re
import sys

OPENSBI_BANNER = "OpenSBI v"
PRIV_VERSION_RE = re.compile(r"Boot HART Priv Version\s*:\s*v1\.12")
ISA_EXT_RE = re.compile(r"Boot HART ISA Extensions\s*:\s*(\S+)")
KERNEL_BANNER = "Linux version"
SBI_IMPL = "SBI implementation ID=0x1"
RESERVED_MEM = "mmode_resv"
SSTC_TIMER = "Timer interrupt in S-mode is available via sstc extension"
EARLY_INIT = "devtmpfs: initialized"
INIT_MARKER = "Run /init as init process"
TOKEN = "FROST_USERSPACE_STRESS_PASS"
FAILURE_MARKERS = (
    "Kernel panic",
    "Oops",
    "Unhandled exception",
    "sbi_trap_error",
    "FROST_USERSPACE_STRESS_FAIL",
)
TIMER_DISABLED = 0xFFFFFFFFFFFFFFFF

# "... progress: cycle=<n> retired=<r> delta_retired=<d> ..."
PROGRESS_RE = re.compile(r"progress: cycle=(\d+) retired=\d+ delta_retired=(\d+)")
# "... CLINT/serial: ... stimecmp=0x<hex> ..."
STIMECMP_RE = re.compile(r"stimecmp=0x([0-9a-fA-F]+)")


def main() -> int:
    """Read the capture log and assert boot health.

    Returns 0 when healthy, 1 when a criterion fails, 2 if the log is unreadable.
    """
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("logfile", help="cocotb linux_boot capture log")
    ap.add_argument(
        "--min-cycle",
        type=int,
        default=25_000_000,
        help="require the run reached at least this sim cycle (default: 25e6)",
    )
    ap.add_argument(
        "--min-end-delta",
        type=int,
        default=1000,
        help="require this many retired instructions in the final progress "
        "window (default: 1000 -- a hung boot retires ~0)",
    )
    ap.add_argument(
        "--min-timer-arms",
        type=int,
        default=2,
        help="require this many distinct armed stimecmp values, i.e. S-mode "
        "timer ticks serviced (default: 2)",
    )
    ap.add_argument(
        "--require-init", action="store_true", help=f"also require {INIT_MARKER!r}"
    )
    ap.add_argument(
        "--require-token", action="store_true", help=f"also require {TOKEN!r}"
    )
    args = ap.parse_args()

    try:
        with open(args.logfile, errors="replace") as f:
            text = f.read()
    except OSError as exc:
        print(f"error: cannot read {args.logfile}: {exc}", file=sys.stderr)
        return 2

    failures = []

    if OPENSBI_BANNER not in text:
        failures.append(
            f"OpenSBI banner ({OPENSBI_BANNER!r}) not found -- firmware did not boot"
        )
    if not PRIV_VERSION_RE.search(text):
        failures.append(
            "OpenSBI did not classify the hart as privileged v1.12 (mcountinhibit probe)"
        )
    ext_match = ISA_EXT_RE.search(text)
    exts = set(ext_match.group(1).split(",")) if ext_match else set()
    for ext in ("sstc", "svade"):
        if ext not in exts:
            failures.append(
                f"OpenSBI's ISA extension line lacks {ext!r} (got {sorted(exts)})"
            )
    if KERNEL_BANNER not in text:
        failures.append(
            f"kernel banner ({KERNEL_BANNER!r}) not found -- kernel did not boot"
        )
    if SBI_IMPL not in text:
        failures.append(f"kernel did not report OpenSBI ({SBI_IMPL!r})")
    if RESERVED_MEM not in text:
        failures.append(
            f"kernel did not see the firmware's reserved-memory nodes ({RESERVED_MEM!r})"
        )
    if SSTC_TIMER not in text:
        failures.append(f"kernel timer did not take the Sstc path ({SSTC_TIMER!r})")
    if EARLY_INIT not in text:
        failures.append(f"early-init marker ({EARLY_INIT!r}) not reached")
    if args.require_init and INIT_MARKER not in text:
        failures.append(f"init marker ({INIT_MARKER!r}) not reached")
    if args.require_token and TOKEN not in text:
        failures.append(f"userspace token ({TOKEN!r}) not printed")
    for marker in FAILURE_MARKERS:
        if marker in text:
            failures.append(f"failure marker found ({marker!r})")

    progress = [(int(c), int(d)) for c, d in PROGRESS_RE.findall(text)]
    max_cycle = 0
    if not progress:
        failures.append(
            "no progress lines found -- set COCOTB_PROGRESS_INTERVAL so the run "
            "emits retire/timer progress, or the sim did not start"
        )
    else:
        max_cycle = max(c for c, _ in progress)
        if max_cycle < args.min_cycle:
            failures.append(
                f"boot stopped early: reached cycle {max_cycle:,} < {args.min_cycle:,}"
            )
        _, last_delta = max(progress, key=lambda cd: cd[0])
        if last_delta < args.min_end_delta:
            failures.append(
                f"no forward progress at the cap: delta_retired={last_delta} at "
                f"cycle {max_cycle:,} < {args.min_end_delta} (boot hung?)"
            )

    armed = {
        int(v, 16) for v in STIMECMP_RE.findall(text) if int(v, 16) != TIMER_DISABLED
    }
    if len(armed) < args.min_timer_arms:
        failures.append(
            f"S-mode timer not serviced: {len(armed)} distinct armed stimecmp "
            f"value(s) < {args.min_timer_arms} (timer hang, or the bench did not "
            "print stimecmp)"
        )

    if failures:
        print("FROST MMU linux_boot check FAILED:", file=sys.stderr)
        for msg in failures:
            print(f"  - {msg}", file=sys.stderr)
        return 1

    print(
        "FROST MMU linux_boot check PASSED: OpenSBI v1.12/sstc/svade, kernel banner, "
        f"reserved memory, Sstc timer, devtmpfs, no faults, S timer serviced ({len(armed)} arms), "
        f"forward progress to cycle {max_cycle:,}."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
