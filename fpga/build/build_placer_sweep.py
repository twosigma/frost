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

"""Run FPGA builds with multiple placer directives in parallel and harvest the best result.

This script runs synthesis once, then forks into parallel place+route runs with different
placer directives. As soon as ANY run passes timing, all remaining runs are terminated
and that result is used. If no run passes timing, the best result (by WNS) is selected.
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

# All available Vivado place_design directives
ALL_PLACER_DIRECTIVES = [
    "Default",
    "Explore",
    "WLDrivenBlockPlacement",
    "EarlyBlockPlacement",
    "ExtraNetDelay_high",
    "ExtraNetDelay_low",
    "SSI_SpreadLogic_high",
    "SSI_SpreadLogic_low",
    "AltSpreadLogic_high",
    "AltSpreadLogic_medium",
    "AltSpreadLogic_low",
    "ExtraPostPlacementOpt",
    "ExtraTimingOpt",
    "SSI_SpreadSLLs",
    "SSI_BalanceSLLs",
    "SSI_BalanceSLRs",
    "SSI_HighUtilSLRs",
    "RuntimeOptimized",
    "Quick",
]

# ML-predicted directives (Auto_1, Auto_2, Auto_3)
AUTO_DIRECTIVES = ["Auto_1", "Auto_2", "Auto_3"]

# Recommended subset for non-SSI devices (7-series, single-die UltraScale+)
# SSI_* directives only work on stacked silicon interconnect devices
NON_SSI_DIRECTIVES = [
    "Default",
    "Explore",
    "WLDrivenBlockPlacement",
    "EarlyBlockPlacement",
    "ExtraNetDelay_high",
    "ExtraNetDelay_low",
    "AltSpreadLogic_high",
    "AltSpreadLogic_medium",
    "AltSpreadLogic_low",
    "ExtraPostPlacementOpt",
    "ExtraTimingOpt",
    "RuntimeOptimized",
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


def run_synthesis_and_opt(
    script_dir: Path,
    board_name: str,
    retiming: bool,
    vivado_path: str,
) -> Path | None:
    """Run synthesis and opt_design, return path to checkpoint."""
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
        "1",  # opt_only - stop after opt_design
        "Default",  # placer_directive (not used since opt_only=1)
        "",  # checkpoint_path (none - full synthesis)
        "",  # work_suffix (none - use default work directory)
    ]

    print(f"\n{'='*60}")
    print("Running synthesis and opt_design...")
    print(f"{'='*60}\n")

    result = subprocess.run(vivado_command)
    if result.returncode != 0:
        print("Error: Synthesis failed", file=sys.stderr)
        return None

    checkpoint = work_dir / "post_opt.dcp"
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


def start_place_route_process(
    script_dir: Path,
    board_name: str,
    directive: str,
    checkpoint_path: Path,
    vivado_path: str,
) -> VivadoProcess:
    """Start a place+route process with a specific directive. Returns VivadoProcess."""
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
        directive,  # placer_directive
        str(checkpoint_path),  # checkpoint_path
        directive,  # work_suffix
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
    """Move the winning run's results to the main work directory."""
    main_work = script_dir / board_name / "work"

    # Remove main work directory if it exists
    if main_work.exists():
        shutil.rmtree(main_work)

    # Move winner to main work
    shutil.move(winner.work_dir, main_work)

    print(f"\nMoved winning results from {winner.work_dir} to {main_work}")


def print_results_table(
    results: list[TimingResult], winner: TimingResult | None
) -> None:
    """Print a formatted table of results."""
    print("\n" + "=" * 80)
    print("PLACER DIRECTIVE SWEEP RESULTS")
    print("=" * 80)
    print(
        f"{'Directive':<28} {'WNS (ns)':>10} {'TNS (ns)':>12} {'WHS (ns)':>10} {'Met':>6} {'Winner':>8}"
    )
    print("-" * 80)

    for r in sorted(results, key=lambda x: x.wns_ns or float("-inf"), reverse=True):
        wns = f"{r.wns_ns:.3f}" if r.wns_ns is not None else "FAILED"
        tns = f"{r.tns_ns:.3f}" if r.tns_ns is not None else "FAILED"
        whs = f"{r.whs_ns:.3f}" if r.whs_ns is not None else "FAILED"
        met = "Yes" if r.timing_met else "No"
        is_winner = "*" if winner and r.directive == winner.directive else ""

        print(
            f"{r.directive:<28} {wns:>10} {tns:>12} {whs:>10} {met:>6} {is_winner:>8}"
        )

    print("=" * 80)


def main() -> None:
    """Run placer directive sweep."""
    parser = argparse.ArgumentParser(
        description="Run FPGA builds with multiple placer directives in parallel"
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
        help="Specific directives to run (default: all non-SSI directives)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Run ALL directives including SSI-specific ones",
    )
    parser.add_argument(
        "--auto",
        action="store_true",
        help="Include ML-predicted Auto_1, Auto_2, Auto_3 directives",
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
        "--skip-synth-opt",
        action="store_true",
        help="Skip synthesis and opt_design, use existing post_opt.dcp checkpoint",
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
    elif args.all:
        directives = ALL_PLACER_DIRECTIVES.copy()
    else:
        directives = NON_SSI_DIRECTIVES.copy()

    if args.auto:
        directives.extend(AUTO_DIRECTIVES)

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

    # Step 2: Run synthesis + opt_design (or use existing checkpoint)
    if args.skip_synth_opt:
        checkpoint = script_dir / board_name / "work" / "post_opt.dcp"
        if not checkpoint.exists():
            print(f"Error: Checkpoint not found: {checkpoint}", file=sys.stderr)
            print("Run without --skip-synth-opt first to generate it.")
            sys.exit(1)
        print(f"\nUsing existing checkpoint: {checkpoint}")
    else:
        checkpoint = run_synthesis_and_opt(
            script_dir, board_name, args.retiming, args.vivado_path
        )
        if checkpoint is None:
            sys.exit(1)

    # Step 3: Run place+route with all directives in parallel
    print(f"\n{'='*60}")
    print(f"Running {len(directives)} place+route jobs in parallel...")
    print("Will terminate all jobs when first one passes timing.")
    print(f"{'='*60}\n")

    # Start all processes
    running_procs: list[VivadoProcess] = []
    for directive in directives:
        proc = start_place_route_process(
            script_dir, board_name, directive, checkpoint, args.vivado_path
        )
        running_procs.append(proc)
        print(f"  [STARTED] {directive} (PID {proc.process.pid})")

    # Poll for completion and check timing
    completed_directives: list[str] = []
    failed_directives: list[str] = []
    winner: TimingResult | None = None
    early_exit = False

    while running_procs and not early_exit:
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

                    # Check if timing is met
                    timing_rpt = proc.work_dir / "post_route_timing.rpt"
                    timing = extract_timing_from_report(timing_rpt)

                    if timing.get("timing_met", False):
                        print(f"\n  *** TIMING MET with {proc.directive}! ***")
                        winner = TimingResult(
                            directive=proc.directive,
                            wns_ns=timing.get("wns_ns"),
                            tns_ns=timing.get("tns_ns"),
                            whs_ns=timing.get("whs_ns"),
                            ths_ns=timing.get("ths_ns"),
                            timing_met=True,
                            work_dir=proc.work_dir,
                        )
                        early_exit = True
                else:
                    failed_directives.append(proc.directive)
                    print(f"  [FAIL] {proc.directive} (return code {ret})")

        running_procs = still_running

    # If we found a winner with timing met, kill remaining processes
    if early_exit and running_procs:
        print(f"\n  Terminating {len(running_procs)} remaining jobs...")
        for proc in running_procs:
            kill_process_tree(proc)
            print(f"    [KILLED] {proc.directive}")
        # Give processes time to die
        time.sleep(2)

    print(f"\nCompleted: {len(completed_directives)}/{len(directives)}")
    if failed_directives:
        print(f"Failed: {', '.join(failed_directives)}")
    if early_exit:
        killed = [p.directive for p in running_procs]
        if killed:
            print(f"Killed (early exit): {', '.join(killed)}")

    # If no early winner, harvest all results and pick the best
    if winner is None:
        print("\nNo run passed timing. Harvesting all results to find best...")
        results = harvest_results(script_dir, board_name, directives)
        winner = select_best_result(results)
        print_results_table(results, winner)
    else:
        # We have an early winner, but still show what completed
        results = harvest_results(script_dir, board_name, completed_directives)
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
    else:
        print("\nError: No successful runs!", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
