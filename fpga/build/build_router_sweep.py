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

"""Run FPGA route_design with multiple directives in parallel and harvest the best result.

This script runs synthesis, opt_design, and place_design once (or uses an existing
post_place checkpoint), then forks into parallel route_design runs with different
router directives. The best result (by WNS) is selected and moved to work/.
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

# All available Vivado route_design directives
ALL_ROUTER_DIRECTIVES = [
    "Default",
    "Explore",
    "AggressiveExplore",
    "NoTimingRelaxation",
    "MoreGlobalIterations",
    "HigherDelayCost",
    "AdvancedSkewModeling",
    "RuntimeOptimized",
]

# UltraScale-only directives
ULTRASCALE_DIRECTIVES = [
    "AlternateCLBRouting",
]


@dataclass
class TimingResult:
    """Timing results from a Vivado run."""

    directive: str
    wns_ns: float | None
    tns_ns: float | None
    whs_ns: float | None
    ths_ns: float | None
    timing_met: bool
    work_dir: Path


def select_best_result(results: list[TimingResult]) -> TimingResult | None:
    """Select the best result based on timing.

    Priority:
    1. Timing met (prefer runs where all constraints are satisfied)
    2. Best WNS (highest value = least negative = best slack)
    3. Best TNS (least negative total negative slack)
    """
    # Filter out runs that failed (no timing data)
    valid_results = [r for r in results if r.wns_ns is not None]

    if not valid_results:
        return None

    # Sort by: timing_met (True first), then WNS (highest first), then TNS (highest first)
    sorted_results = sorted(
        valid_results,
        key=lambda r: (
            r.timing_met,
            r.wns_ns or float("-inf"),
            r.tns_ns or float("-inf"),
        ),
        reverse=True,
    )

    return sorted_results[0]


def move_winner_to_main_work(
    script_dir: Path,
    board_name: str,
    winner: TimingResult,
) -> None:
    """Move the winning run's results to the main work directory.

    Preserves post_synth, post_opt, and post_place files from original work directory.
    """
    main_work = script_dir / board_name / "work"

    # Collect files to preserve from original work directory
    files_to_preserve = []
    if main_work.exists():
        for prefix in ["post_synth", "post_opt", "post_place"]:
            for f in main_work.glob(f"{prefix}*"):
                files_to_preserve.append(f)

    # Copy files to temp location before removing work directory
    temp_dir = script_dir / board_name / "work_preserve_temp"
    if files_to_preserve:
        temp_dir.mkdir(exist_ok=True)
        for f in files_to_preserve:
            shutil.copy2(f, temp_dir / f.name)

    # Remove main work directory if it exists
    if main_work.exists():
        shutil.rmtree(main_work)

    # Move winner to main work
    shutil.move(winner.work_dir, main_work)

    # Restore preserved files
    if temp_dir.exists():
        for f in temp_dir.iterdir():
            shutil.copy2(f, main_work / f.name)
        shutil.rmtree(temp_dir)

    print(f"\nMoved winning results from {winner.work_dir} to {main_work}")


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


def run_through_placement(
    script_dir: Path,
    board_name: str,
    retiming: bool,
    vivado_path: str,
) -> Path | None:
    """Run synthesis, opt_design, and place_design. Return path to checkpoint."""
    work_dir = script_dir / board_name / "work"

    # Clean work directory
    if work_dir.exists():
        shutil.rmtree(work_dir)

    vivado_command = [
        vivado_path,
        "-mode",
        "batch",
        "-source",
        str(script_dir / "build.tcl"),
        "-nojournal",
        "-tclargs",
        board_name,
        "0",  # synth_only
        "1" if retiming else "0",
        "0",  # opt_only
        "AltSpreadLogic_high",  # placer_directive
        "",  # checkpoint_path (none - full flow)
        "",  # work_suffix
        "PerformanceOptimized",  # synth_directive
        "ExploreWithRemap",  # opt_directive
        "1",  # place_only - stop after place_design
    ]

    print(f"\n{'='*60}")
    print("Running synthesis, opt_design, and place_design...")
    print(f"{'='*60}\n")

    result = subprocess.run(vivado_command)
    if result.returncode != 0:
        print("Error: Build through placement failed", file=sys.stderr)
        return None

    checkpoint = work_dir / "post_place.dcp"
    if not checkpoint.exists():
        print(f"Error: Checkpoint not found at {checkpoint}", file=sys.stderr)
        return None

    return checkpoint


@dataclass
class VivadoProcess:
    """A running Vivado process."""

    directive: str
    process: subprocess.Popen
    log_file: Path
    work_dir: Path


def start_route_process(
    script_dir: Path,
    board_name: str,
    directive: str,
    checkpoint_path: Path,
    vivado_path: str,
) -> VivadoProcess:
    """Start a route_design process with a specific directive. Returns VivadoProcess."""
    vivado_command = [
        vivado_path,
        "-mode",
        "batch",
        "-source",
        str(script_dir / "build.tcl"),
        "-nojournal",
        "-tclargs",
        board_name,
        "0",  # synth_only
        "0",  # retiming (not used when loading checkpoint)
        "0",  # opt_only
        "Default",  # placer_directive (not used - loading post_place checkpoint)
        str(checkpoint_path),  # checkpoint_path (post_place.dcp)
        directive,  # work_suffix
        "PerformanceOptimized",  # synth_directive (not used)
        "ExploreWithRemap",  # opt_directive (not used)
        "0",  # place_only (not used - loading post_place checkpoint)
        directive,  # router_directive
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

    result["timing_met"] = "All user specified timing constraints are met" in timing_rpt

    return result


def harvest_results(
    script_dir: Path,
    board_name: str,
    directives: list[str],
) -> list[TimingResult]:
    """Parse timing reports from all runs and return results."""
    results = []

    for directive in directives:
        work_dir = script_dir / board_name / f"work_{directive}"
        timing_rpt = work_dir / "post_route_timing.rpt"

        timing = extract_timing_from_report(timing_rpt)

        results.append(
            TimingResult(
                directive=directive,
                wns_ns=timing.get("wns_ns"),
                tns_ns=timing.get("tns_ns"),
                whs_ns=timing.get("whs_ns"),
                ths_ns=timing.get("ths_ns"),
                timing_met=timing.get("timing_met", False),
                work_dir=work_dir,
            )
        )

    return results


def print_results_table(
    results: list[TimingResult], winner: TimingResult | None
) -> None:
    """Print a formatted table of results."""
    print("\n" + "=" * 100)
    print("ROUTER DIRECTIVE SWEEP RESULTS")
    print("=" * 100)
    print(
        f"{'Directive':<24} {'WNS (ns)':>10} {'TNS (ns)':>12} {'WHS (ns)':>10} {'Met':>6} {'Winner':>8}"
    )
    print("-" * 100)

    for r in sorted(results, key=lambda x: x.wns_ns or float("-inf"), reverse=True):
        wns = f"{r.wns_ns:.3f}" if r.wns_ns is not None else "FAILED"
        tns = f"{r.tns_ns:.3f}" if r.tns_ns is not None else "FAILED"
        whs = f"{r.whs_ns:.3f}" if r.whs_ns is not None else "FAILED"
        met = "Yes" if r.timing_met else "No"
        is_winner = "*" if winner and r.directive == winner.directive else ""

        print(
            f"{r.directive:<24} {wns:>10} {tns:>12} {whs:>10} {met:>6} {is_winner:>8}"
        )

    print("=" * 100)


def main() -> None:
    """Run router directive sweep."""
    parser = argparse.ArgumentParser(
        description="Run FPGA route_design with multiple directives in parallel"
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
        help="Specific directives to run (default: all router directives)",
    )
    parser.add_argument(
        "--ultrascale",
        action="store_true",
        help="Include UltraScale-only directives (AlternateCLBRouting)",
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
        "--skip-place",
        action="store_true",
        help="Skip synth/opt/place, use existing post_place.dcp checkpoint",
    )
    parser.add_argument(
        "--keep-all",
        action="store_true",
        help="Keep all work directories (don't clean up non-winners)",
    )
    args = parser.parse_args()

    board_name = args.board_name
    script_dir = Path(__file__).parent.resolve()
    project_root = script_dir.parent.parent

    # Determine which directives to run
    if args.directives:
        directives = args.directives
    else:
        directives = ALL_ROUTER_DIRECTIVES.copy()
        if args.ultrascale or board_name == "x3":
            directives.extend(ULTRASCALE_DIRECTIVES)

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

    # Step 2: Run through placement (or use existing checkpoint)
    if args.skip_place:
        checkpoint = script_dir / board_name / "work" / "post_place.dcp"
        if not checkpoint.exists():
            print(f"Error: Checkpoint not found: {checkpoint}", file=sys.stderr)
            print("Run without --skip-place first to generate it.")
            sys.exit(1)
        print(f"\nUsing existing checkpoint: {checkpoint}")
    else:
        checkpoint = run_through_placement(
            script_dir, board_name, args.retiming, args.vivado_path
        )
        if checkpoint is None:
            sys.exit(1)

    # Step 3: Run route_design with all directives in parallel
    print(f"\n{'='*60}")
    print(f"Running {len(directives)} route_design jobs in parallel...")
    print(f"{'='*60}\n")

    # Start all processes
    running_procs: list[VivadoProcess] = []
    for directive in directives:
        proc = start_route_process(
            script_dir, board_name, directive, checkpoint, args.vivado_path
        )
        running_procs.append(proc)
        print(f"  [STARTED] {directive} (PID {proc.process.pid})")

    # Poll for completion
    completed_directives: list[str] = []
    failed_directives: list[str] = []

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
                    completed_directives.append(proc.directive)
                    print(f"  [DONE] {proc.directive}")
                else:
                    failed_directives.append(proc.directive)
                    print(f"  [FAIL] {proc.directive} (return code {ret})")

        running_procs = still_running

    print(f"\nCompleted: {len(completed_directives)}/{len(directives)}")
    if failed_directives:
        print(f"Failed: {', '.join(failed_directives)}")

    # Harvest all results and pick the best
    results = harvest_results(script_dir, board_name, directives)
    winner = select_best_result(results)
    print_results_table(results, winner)

    if winner:
        print(f"\n*** WINNER: {winner.directive} ***")
        print(f"    WNS: {winner.wns_ns:.3f} ns")
        print(f"    TNS: {winner.tns_ns:.3f} ns")
        print(f"    Timing Met: {'Yes' if winner.timing_met else 'No'}")

        # Move winner to main work directory
        move_winner_to_main_work(script_dir, board_name, winner)

        # Extract timing summaries
        extract_script = script_dir / "extract_timing_and_util_summary.py"
        subprocess.run(["python3", str(extract_script), board_name], check=True)

        # Clean up remaining work_* directories (unless --keep-all)
        if not args.keep_all:
            print("\nCleaning up work directories...")
            for directive in directives:
                work_dir = script_dir / board_name / f"work_{directive}"
                if work_dir.exists():
                    shutil.rmtree(work_dir)
            print("Done.")

        print(
            f"\nBitstream: {script_dir / board_name / 'work' / f'{board_name}_frost.bit'}"
        )
    else:
        print("\nError: No successful runs!", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
