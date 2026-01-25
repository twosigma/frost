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

"""Run FPGA synthesis with multiple synth_design directives in parallel and report results.

This script runs synthesis with all available synth_design directives in parallel,
then reports timing and utilization results for each. Unlike the placer sweep, this
does not pick a winner - it's meant for exploration and comparison of synthesis results.
"""

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

# Board configurations: clock frequency in Hz
BOARD_CONFIG = {
    "x3": {"clock_freq": 322265625},
    "genesys2": {"clock_freq": 133333333},
    "nexys_a7": {"clock_freq": 80000000},
}

# All available Vivado synth_design directives (case-sensitive)
ALL_SYNTH_DIRECTIVES = [
    "default",
    "runtimeoptimized",
    "AreaOptimized_high",
    "AreaOptimized_medium",
    "AlternateRoutability",
    "AreaMapLargeShiftRegToBRAM",
    "AreaMultThresholdDSP",
    "FewerCarryChains",
    "PerformanceOptimized",
    "LogicCompaction",
]


@dataclass
class SynthResult:
    """Synthesis results from a Vivado run."""

    directive: str
    wns_ns: float | None
    tns_ns: float | None
    whs_ns: float | None
    ths_ns: float | None
    lut_count: int | None
    ff_count: int | None
    bram_count: float | None
    dsp_count: int | None
    work_dir: Path
    success: bool


def compile_hello_world(project_root: Path, clock_freq: int) -> bool:
    """Compile hello_world application for initial BRAM contents."""
    app_dir = project_root / "sw" / "apps" / "hello_world"

    if not app_dir.exists():
        print(f"Error: Application directory not found: {app_dir}", file=sys.stderr)
        return False

    env = os.environ.copy()
    if "RISCV_PREFIX" not in env:
        env["RISCV_PREFIX"] = "riscv-none-elf-"
    env["FPGA_CPU_CLK_FREQ"] = str(clock_freq)

    try:
        print(f"Compiling hello_world with FPGA_CPU_CLK_FREQ={clock_freq}...")
        subprocess.run(
            ["make", "clean"],
            cwd=app_dir,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        result = subprocess.run(
            ["make"],
            cwd=app_dir,
            env=env,
            capture_output=False,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            return False

        sw_mem = app_dir / "sw.mem"
        if not sw_mem.exists():
            print("Error: sw.mem not created for hello_world", file=sys.stderr)
            return False

        return True

    except subprocess.TimeoutExpired:
        print("Error: Compilation timed out for hello_world", file=sys.stderr)
        return False
    except Exception as e:
        print(f"Error compiling hello_world: {e}", file=sys.stderr)
        return False


@dataclass
class VivadoProcess:
    """A running Vivado process."""

    directive: str
    process: subprocess.Popen
    log_file: Path
    work_dir: Path


def start_synth_process(
    script_dir: Path,
    board_name: str,
    directive: str,
    retiming: bool,
    vivado_path: str,
) -> VivadoProcess:
    """Start a synthesis process with a specific directive. Returns VivadoProcess."""
    vivado_command = [
        vivado_path,
        "-mode",
        "batch",
        "-source",
        str(script_dir / "build.tcl"),
        "-nojournal",
        "-tclargs",
        board_name,
        "1",  # synth_only - stop after synthesis
        "1" if retiming else "0",
        "0",  # opt_only
        "Default",  # placer_directive (not used since synth_only=1)
        "",  # checkpoint_path (none - full synthesis)
        directive,  # work_suffix
        directive,  # synth_directive
    ]

    # Redirect stdout/stderr to a log file
    work_dir = script_dir / board_name / f"work_{directive}"
    work_dir.mkdir(parents=True, exist_ok=True)
    log_file = work_dir / "vivado.log"

    log_handle = open(log_file, "w")
    process = subprocess.Popen(
        vivado_command,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        # Start new process group so we can kill all children
        start_new_session=True,
    )

    return VivadoProcess(
        directive=directive,
        process=process,
        log_file=log_file,
        work_dir=work_dir,
    )


def kill_process_tree(proc: VivadoProcess) -> None:
    """Kill a Vivado process and all its children."""
    try:
        # Kill the entire process group
        os.killpg(os.getpgid(proc.process.pid), signal.SIGTERM)
    except (ProcessLookupError, OSError):
        pass  # Process already dead


def extract_timing_from_report(timing_rpt_path: Path) -> dict:
    """Extract WNS, TNS, WHS, THS from timing report."""
    result = {}

    if not timing_rpt_path.exists():
        return result

    timing_rpt = timing_rpt_path.read_text()

    # Find the Design Timing Summary table
    pattern = r"WNS\(ns\)\s+TNS\(ns\).*?\n\s*-+\s*-+.*?\n\s*([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)"
    match = re.search(pattern, timing_rpt)
    if match:
        result["wns_ns"] = float(match.group(1))
        result["tns_ns"] = float(match.group(2))
        result["whs_ns"] = float(match.group(5))
        result["ths_ns"] = float(match.group(6))

    return result


def extract_utilization_from_report(util_rpt_path: Path) -> dict:
    """Extract LUT, FF, BRAM, DSP counts from utilization report."""
    result = {}

    if not util_rpt_path.exists():
        return result

    util_rpt = util_rpt_path.read_text()

    # Extract CLB LUTs
    lut_pattern = r"\|\s*CLB LUTs\s*\|\s*(\d+)\s*\|"
    match = re.search(lut_pattern, util_rpt)
    if match:
        result["lut_count"] = int(match.group(1))

    # Extract CLB Registers (FFs)
    ff_pattern = r"\|\s*CLB Registers\s*\|\s*(\d+)\s*\|"
    match = re.search(ff_pattern, util_rpt)
    if match:
        result["ff_count"] = int(match.group(1))

    # Extract Block RAM Tile
    bram_pattern = r"\|\s*Block RAM Tile\s*\|\s*([\d.]+)\s*\|"
    match = re.search(bram_pattern, util_rpt)
    if match:
        result["bram_count"] = float(match.group(1))

    # Extract DSPs
    dsp_pattern = r"\|\s*DSPs\s*\|\s*(\d+)\s*\|"
    match = re.search(dsp_pattern, util_rpt)
    if match:
        result["dsp_count"] = int(match.group(1))

    return result


def harvest_results(
    script_dir: Path,
    board_name: str,
    directives: list[str],
    completed: set[str],
    failed: set[str],
) -> list[SynthResult]:
    """Parse timing and utilization reports from all runs and return results."""
    results = []

    for directive in directives:
        work_dir = script_dir / board_name / f"work_{directive}"
        timing_rpt = work_dir / "post_synth_timing.rpt"
        util_rpt = work_dir / "post_synth_util.rpt"

        timing = extract_timing_from_report(timing_rpt)
        util = extract_utilization_from_report(util_rpt)

        success = directive in completed and directive not in failed

        results.append(
            SynthResult(
                directive=directive,
                wns_ns=timing.get("wns_ns"),
                tns_ns=timing.get("tns_ns"),
                whs_ns=timing.get("whs_ns"),
                ths_ns=timing.get("ths_ns"),
                lut_count=util.get("lut_count"),
                ff_count=util.get("ff_count"),
                bram_count=util.get("bram_count"),
                dsp_count=util.get("dsp_count"),
                work_dir=work_dir,
                success=success,
            )
        )

    return results


def print_results_table(results: list[SynthResult]) -> None:
    """Print a formatted table of results."""
    print("\n" + "=" * 120)
    print("SYNTHESIS DIRECTIVE SWEEP RESULTS")
    print("=" * 120)
    print(
        f"{'Directive':<28} {'WNS (ns)':>10} {'TNS (ns)':>12} {'LUTs':>8} {'FFs':>8} {'BRAM':>6} {'DSP':>5} {'Status':>8}"
    )
    print("-" * 120)

    # Sort by WNS (best timing first)
    for r in sorted(results, key=lambda x: x.wns_ns or float("-inf"), reverse=True):
        wns = f"{r.wns_ns:.3f}" if r.wns_ns is not None else "N/A"
        tns = f"{r.tns_ns:.3f}" if r.tns_ns is not None else "N/A"
        luts = f"{r.lut_count}" if r.lut_count is not None else "N/A"
        ffs = f"{r.ff_count}" if r.ff_count is not None else "N/A"
        bram = f"{r.bram_count:.1f}" if r.bram_count is not None else "N/A"
        dsp = f"{r.dsp_count}" if r.dsp_count is not None else "N/A"
        status = "OK" if r.success else "FAILED"

        print(
            f"{r.directive:<28} {wns:>10} {tns:>12} {luts:>8} {ffs:>8} {bram:>6} {dsp:>5} {status:>8}"
        )

    print("=" * 120)

    # Also show sorted by area (LUTs)
    print("\n" + "-" * 60)
    print("SORTED BY AREA (LUTs, ascending):")
    print("-" * 60)
    area_sorted = sorted(
        [r for r in results if r.lut_count is not None],
        key=lambda x: x.lut_count,
    )
    for r in area_sorted:
        print(f"  {r.directive:<28} {r.lut_count:>8} LUTs")


def main() -> None:
    """Run synthesis directive sweep."""
    parser = argparse.ArgumentParser(
        description="Run FPGA synthesis with multiple directives in parallel"
    )
    parser.add_argument(
        "board_name",
        nargs="?",
        default="x3",
        choices=["x3", "genesys2", "nexys_a7"],
        help="Target board (default: x3)",
    )
    parser.add_argument(
        "--directives",
        nargs="+",
        help="Specific directives to run (default: all synthesis directives)",
    )
    parser.add_argument(
        "--retiming",
        action="store_true",
        help="Enable global retiming during synthesis",
    )
    parser.add_argument(
        "--vivado-path",
        default="vivado",
        help="Path to Vivado executable (default: vivado from PATH)",
    )
    parser.add_argument(
        "--clean-after",
        action="store_true",
        help="Delete all work directories after reporting results",
    )
    args = parser.parse_args()

    board_name = args.board_name
    script_dir = Path(__file__).parent.resolve()
    project_root = script_dir.parent.parent

    # Determine which directives to run
    if args.directives:
        directives = args.directives
    else:
        directives = ALL_SYNTH_DIRECTIVES.copy()

    # Remove duplicates while preserving order
    seen = set()
    directives = [d for d in directives if not (d in seen or seen.add(d))]

    print(f"Board: {board_name}")
    print(f"Directives to run ({len(directives)}): {', '.join(directives)}")

    # Get board configuration
    board_config = BOARD_CONFIG[board_name]
    clock_freq = board_config["clock_freq"]

    # Step 1: Compile hello_world
    print(f"\nCompiling hello_world for {board_name} ({clock_freq} Hz)...")
    if not compile_hello_world(project_root, clock_freq):
        print("Error: Failed to compile hello_world", file=sys.stderr)
        sys.exit(1)

    # Step 2: Clean up any existing work directories for these directives
    for directive in directives:
        work_dir = script_dir / board_name / f"work_{directive}"
        if work_dir.exists():
            shutil.rmtree(work_dir)

    # Step 3: Run synthesis with all directives in parallel
    print(f"\n{'='*60}")
    print(f"Running {len(directives)} synthesis jobs in parallel...")
    print(f"{'='*60}\n")

    # Start all processes
    running_procs: list[VivadoProcess] = []
    for directive in directives:
        proc = start_synth_process(
            script_dir, board_name, directive, args.retiming, args.vivado_path
        )
        running_procs.append(proc)
        print(f"  [STARTED] {directive} (PID {proc.process.pid})")

    # Poll for completion
    completed_directives: set[str] = set()
    failed_directives: set[str] = set()

    while running_procs:
        time.sleep(5)  # Poll every 5 seconds

        still_running = []
        for proc in running_procs:
            ret = proc.process.poll()
            if ret is None:
                # Still running
                still_running.append(proc)
            else:
                # Process finished
                if ret == 0:
                    completed_directives.add(proc.directive)
                    print(f"  [DONE] {proc.directive}")
                else:
                    failed_directives.add(proc.directive)
                    print(f"  [FAIL] {proc.directive} (return code {ret})")

        running_procs = still_running

    print(f"\nCompleted: {len(completed_directives)}/{len(directives)}")
    if failed_directives:
        print(f"Failed: {', '.join(sorted(failed_directives))}")

    # Harvest all results
    results = harvest_results(
        script_dir, board_name, directives, completed_directives, failed_directives
    )
    print_results_table(results)

    # Clean up work directories if --clean-after
    if args.clean_after:
        print("\nCleaning up work directories...")
        for directive in directives:
            work_dir = script_dir / board_name / f"work_{directive}"
            if work_dir.exists():
                shutil.rmtree(work_dir)
        print("Done.")


if __name__ == "__main__":
    main()
