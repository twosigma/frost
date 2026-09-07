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

r"""Capture the fetch-seam ILA of a ``build.py --debug-ila`` bitstream.

The debug core samples the IF stage, the fetch provider, the immu, the PD
packet and the commit/trap pulses on the CPU clock. The trigger is the IF
stage's fetch-fault packet at a page offset. Arming, waiting and collecting
must share one Hardware Manager session, because the device refresh every new
session performs resets the core; and the software loader's own refresh
would reset a capture armed before it. So ``hook`` writes two scripts that
``load_software.py`` (hence ``hw_regression.py``) sources through
``FROST_ILA_ARM_HOOK`` right after its refresh, before the CPU is released,
and through ``FROST_ILA_COLLECT_HOOK`` after the load, where it waits for the
trigger and writes the CSV. ``capture`` is the standalone form for a program
that is already running.

    ./fpga/debug/capture_fetch_ila.py x3 hook --offset 5e4
    FROST_ILA_ARM_HOOK=fpga/build/x3/work/ila_arm_hook.tcl \\
        FROST_ILA_COLLECT_HOOK=fpga/build/x3/work/ila_collect_hook.tcl \\
        FROST_CPU_CLK_HZ=150000000 FROST_LINUX_LANE=mmu \\
        ./fpga/hw_regression.py --board x3 linux_boot
    ./fpga/debug/fetch_ila_report.py fpga/build/x3/work/fetch_ila.csv
"""

import argparse
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
PROJECT_ROOT = SCRIPT_DIR.parent.parent
sys.path.insert(0, str(SCRIPT_DIR.parent / "common"))

from hw_target import add_target_args, select_target  # noqa: E402

FAULT_PROBE_GLOB = "*dbg_ila_if_pd_fetch_fault"
PC_PROBE_GLOB = "*dbg_ila_if_pd_pc*"


def pc_trigger_value(offset_hex: str, width: int = 16) -> str:
    """Return the ILA compare value for a page offset: the upper nibble is don't-care.

    The probes carry the PC's low 16 bits; a page offset is 12 of them, so
    ``5e4`` becomes ``eq16'hX5E4``.
    """
    offset = int(offset_hex, 16)
    if not 0 <= offset < 0x1000:
        raise ValueError(f"page offset must be 12 bits, got {offset_hex!r}")
    if width % 4:
        raise ValueError("width must be a multiple of 4")
    dont_care = "X" * (width // 4 - 3)
    return f"eq{width}'h{dont_care}{offset:03X}"


def arm_hook_tcl(ltx: Path, pc_value: str, trigger_position: int) -> str:
    """Return the Tcl the loader sources to arm the ILA inside its own session."""
    procs = SCRIPT_DIR / "fetch_ila_procs.tcl"
    return (
        "# Written by capture_fetch_ila.py hook; sourced by load_software.tcl.\n"
        f"source {{{procs}}}\n"
        f"set frost_ila [frost_ila_attach {{{ltx.resolve()}}}]\n"
        f"frost_ila_arm $frost_ila {{{FAULT_PROBE_GLOB}}} {{{PC_PROBE_GLOB}}} "
        f"{{{pc_value}}} {trigger_position}\n"
    )


def collect_hook_tcl(csv: Path, wait_minutes: int) -> str:
    """Return the Tcl the loader sources after the load to wait and collect."""
    procs = SCRIPT_DIR / "fetch_ila_procs.tcl"
    return (
        "# Written by capture_fetch_ila.py hook; sourced by load_software.tcl.\n"
        f"source {{{procs}}}\n"
        f"frost_ila_wait_and_collect $frost_ila {{{csv.resolve()}}} {wait_minutes}\n"
    )


def main() -> None:
    """Run one capture action against the selected board."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("board", choices=["x3"], help="Target board")
    parser.add_argument(
        "action", nargs="?", choices=["hook", "capture"], help="capture action"
    )
    parser.add_argument(
        "--offset",
        default="5e4",
        help="Page offset (hex, 12 bits) of the fetch-fault packet that triggers "
        "(default: 5e4, the word after the vDSO sigreturn stub)",
    )
    parser.add_argument(
        "--trigger-position",
        type=int,
        default=3072,
        help="Samples kept before the trigger (default: 3072 of a 4096 window)",
    )
    parser.add_argument(
        "--ltx",
        type=Path,
        default=None,
        help="Probes file (default: fpga/build/<board>/work/<board>_frost.ltx)",
    )
    parser.add_argument(
        "--csv",
        type=Path,
        default=None,
        help="Capture output (default: fpga/build/<board>/work/fetch_ila.csv)",
    )
    parser.add_argument(
        "--wait-minutes",
        type=int,
        default=3,
        help="How long the collecting session waits for the trigger (default: 3)",
    )
    parser.add_argument("--remote-host", default="", help="Remote hw_server host")
    parser.add_argument("--vivado-path", default="vivado", help="Vivado executable")
    add_target_args(parser)
    args = parser.parse_args()

    work = PROJECT_ROOT / "fpga" / "build" / args.board / "work"
    ltx = args.ltx or work / f"{args.board}_frost.ltx"
    csv = args.csv or work / "fetch_ila.csv"
    if args.list_targets:
        select_target(
            args.vivado_path, args.remote_host, list_only=True, board=args.board
        )
        return
    if args.action is None:
        parser.error("an action is required: hook or capture")
    if not ltx.exists():
        print(
            f"Error: probes file not found: {ltx} (build with --debug-ila)",
            file=sys.stderr,
        )
        sys.exit(1)
    if args.action == "hook":
        arm_hook = work / "ila_arm_hook.tcl"
        collect_hook = work / "ila_collect_hook.tcl"
        arm_hook.write_text(
            arm_hook_tcl(ltx, pc_trigger_value(args.offset), args.trigger_position)
        )
        collect_hook.write_text(collect_hook_tcl(csv, args.wait_minutes))
        print(f"Hooks written: {arm_hook}, {collect_hook}")
        print(
            "Run the load with: "
            f"FROST_ILA_ARM_HOOK={arm_hook} FROST_ILA_COLLECT_HOOK={collect_hook}"
        )
        return
    target = select_target(
        args.vivado_path, args.remote_host, target_pattern=args.target, board=args.board
    )
    command = [
        args.vivado_path,
        "-mode",
        "batch",
        "-nojournal",
        "-nolog",
        "-source",
        str(SCRIPT_DIR / "capture_fetch_ila.tcl"),
        "-tclargs",
        target,
        str(ltx),
        str(csv),
        FAULT_PROBE_GLOB,
        PC_PROBE_GLOB,
        pc_trigger_value(args.offset),
        str(args.trigger_position),
        str(args.wait_minutes),
    ]
    if args.remote_host:
        command.append(args.remote_host)
    print(f"capture: {' '.join(command[-9:])}")
    result = subprocess.run(command, cwd=PROJECT_ROOT)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
