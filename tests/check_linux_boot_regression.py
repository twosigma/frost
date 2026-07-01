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

"""Assert FROST no-MMU Linux boot health from a cocotb linux_boot capture log.

The CI ``linux-boot-cocotb`` job boots the freshly built image on the FROST RTL
for ~22M cycles in ``FROST_LINUX_RUN_FULL`` capture mode (with
``COCOTB_PROGRESS_INTERVAL`` set so the run emits per-interval retire + CLINT
lines). That window is *silent* ``mem_init`` after ``devtmpfs: initialized`` --
the next console line is millions of cycles further on -- so there is no deep
boot marker to match on. Instead this checker asserts the signals that actually
separate a healthy boot from the regressions the job guards:

  * the "gremlin": a timer-IRQ hang that froze the boot at the periodic CLINT
    tick (retire count stops advancing; mtimecmp stops being re-armed), and
  * fence.i / instruction-fetch breakage that derails a long real-code boot.

Health criteria (all must hold):
  1. the kernel banner printed (the core booted Linux at all),
  2. early init was reached (``devtmpfs: initialized``),
  3. no kernel panic,
  4. the run reached at least ``--min-cycle`` (past the historical gremlin tick
     at ~cycle 20.96M),
  5. the core was still retiring instructions in the final progress window
     (``delta_retired`` >= ``--min-end-delta`` -- i.e. it did not hang), and
  6. the periodic CLINT timer tick was serviced: mtimecmp was re-armed to at
     least ``--min-timer-arms`` distinct non-disabled values (the gremlin hung
     here, freezing the tick).

Usage: ``check_linux_boot_regression.py <cocotb-boot-log>``
"""

import argparse
import re
import sys

BANNER = "Linux version"
EARLY_INIT = "devtmpfs: initialized"
PANIC = "Kernel panic"
MTIMECMP_DISABLED = 0xFFFFFFFFFFFFFFFF

# "... progress: cycle=<n> retired=<r> delta_retired=<d> ..."
PROGRESS_RE = re.compile(r"progress: cycle=(\d+) retired=\d+ delta_retired=(\d+)")
# "... CLINT/serial: ... mtimecmp=0x<hex> ..."
MTIMECMP_RE = re.compile(r"mtimecmp=0x([0-9a-fA-F]+)")


def main() -> int:
    """Read the capture log, assert boot health, return 0 (healthy) else 1."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("logfile", help="cocotb linux_boot capture log")
    ap.add_argument(
        "--min-cycle",
        type=int,
        default=21_000_000,
        help="require the run reached at least this sim cycle (default: 21e6, "
        "past the historical gremlin tick at ~20.96e6)",
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
        help="require this many distinct armed mtimecmp values, i.e. periodic "
        "timer ticks serviced (default: 2)",
    )
    args = ap.parse_args()

    try:
        with open(args.logfile, errors="replace") as f:
            text = f.read()
    except OSError as exc:
        print(f"error: cannot read {args.logfile}: {exc}", file=sys.stderr)
        return 2

    failures = []

    if BANNER not in text:
        failures.append(
            f"kernel banner ({BANNER!r}) not found -- core did not boot Linux"
        )
    if EARLY_INIT not in text:
        failures.append(f"early-init marker ({EARLY_INIT!r}) not reached")
    if PANIC in text:
        failures.append(f"kernel panic detected ({PANIC!r})")

    progress = [(int(c), int(d)) for c, d in PROGRESS_RE.findall(text)]
    max_cycle = 0
    if not progress:
        failures.append(
            "no progress lines found -- set COCOTB_PROGRESS_INTERVAL so the run "
            "emits retire/CLINT progress, or the sim did not start"
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
        int(v, 16) for v in MTIMECMP_RE.findall(text) if int(v, 16) != MTIMECMP_DISABLED
    }
    if len(armed) < args.min_timer_arms:
        failures.append(
            f"periodic timer tick not serviced: {len(armed)} distinct armed "
            f"mtimecmp value(s) < {args.min_timer_arms} (gremlin timer-IRQ hang?)"
        )

    if failures:
        print("FROST linux_boot regression FAILED:", file=sys.stderr)
        for msg in failures:
            print(f"  - {msg}", file=sys.stderr)
        return 1

    print(
        "FROST linux_boot regression PASSED: banner + devtmpfs reached, no panic, "
        f"timer serviced ({len(armed)} distinct arms), forward progress to "
        f"cycle {max_cycle:,}."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
