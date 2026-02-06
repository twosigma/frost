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

"""Unified FPGA build script with parallel directive sweeps at each stage.

One script to rule them all, one script to find them, one script to bring
them all, and in the darkness bind them.

Steps:
1. Synthesis      - parallel sweep of synth directives (wait for all, pick best WNS)
2. Opt            - parallel sweep of opt directives (wait for all, pick best WNS)
3. Place          - parallel sweep of placer directives (wait for all, pick best WNS)
4. Post-place     - loop of phys_opt directive sweeps until no improvement
5. Route + Post-route meta-loop:
   - Route sweep (early-terminate on timing met)
   - Post-route phys_opt loop (early-terminate on timing met)
   - If improvement, repeat route from post_place_physopt
   - If no improvement or route regresses, stop and keep best result

Early termination:
- Early steps (synth, opt, place, post_place_physopt): Wait for ALL jobs to complete
  and pick the best WNS. This maximizes timing margin for subsequent steps.
- Final steps (route, post_route_physopt): Early terminate as soon as any job
  achieves WNS >= 0. Timing is already met, no need to wait.

Phys_opt loops:
- Each pass runs a parallel sweep of all phys_opt directives
- Picks winner based on greatest WNS/TNS improvement (or timing met)
- Continues until WNS >= 0 OR no improvement in either WNS or TNS

Route + Post-route meta-loop:
- Alternates between route sweeps and phys_opt loops
- Each route starts fresh from post_place_physopt checkpoint
- Tracks best result across all iterations
- Stops when: timing met, route doesn't improve, or phys_opt loop doesn't improve
- Rolls back to previous best if current iteration regresses

Checkpoints:
- post_synth.dcp           (after synthesis)
- post_opt.dcp             (after opt design)
- post_place.dcp           (after placement)
- post_place_physopt.dcp   (after post-place phys_opt)
- post_route.dcp           (after routing, updated each meta-loop iteration)
- final.dcp                (after post-route phys_opt, used for bitstream)
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

# =============================================================================
# Global Process Tracking (for cleanup on Ctrl+C)
# =============================================================================

_running_processes: list["VivadoProcess"] = []


def _cleanup_handler(signum: int, frame) -> None:
    """Signal handler to kill all running Vivado processes on Ctrl+C."""
    if _running_processes:
        print(
            f"\n\nInterrupted! Killing {len(_running_processes)} running Vivado process(es)..."
        )
        for proc in _running_processes:
            kill_process_tree(proc)
        _running_processes.clear()
    sys.exit(1)


# Register signal handlers
signal.signal(signal.SIGINT, _cleanup_handler)
signal.signal(signal.SIGTERM, _cleanup_handler)


# =============================================================================
# Configuration
# =============================================================================

BOARD_CONFIG = {
    "x3": {"clock_freq": 300000000, "is_ultrascale": True},
    "genesys2": {"clock_freq": 133333333, "is_ultrascale": False},
    "nexys_a7": {"clock_freq": 80000000, "is_ultrascale": False},
}

# Directive lists for each step
SYNTH_DIRECTIVES = [
    "Default",
    "PerformanceOptimized",
    "AreaOptimized_high",
    "AreaOptimized_medium",
    "AlternateRoutability",
    "AreaMapLargeShiftRegToBRAM",
    "AreaMultThresholdDSP",
    "FewerCarryChains",
]

OPT_DIRECTIVES = [
    "Default",
    "Explore",
    "ExploreArea",
    "ExploreWithRemap",
    "ExploreSequentialArea",
    "AddRemap",
    "NoBramPowerOpt",
    "RuntimeOptimized",
]

PLACER_DIRECTIVES = [
    "Default",
    "Explore",
    "ExtraNetDelay_high",
    "ExtraNetDelay_low",
    "ExtraPostPlacementOpt",
    "ExtraTimingOpt",
    "AltSpreadLogic_high",
    "AltSpreadLogic_low",
    "AltSpreadLogic_medium",
    "SpreadLogic_high",
    "SpreadLogic_low",
    "EarlyBlockPlacement",
]

ROUTER_DIRECTIVES = [
    "Default",
    "Explore",
    "AggressiveExplore",
    "NoTimingRelaxation",
    "MoreGlobalIterations",
    "HigherDelayCost",
    "AdvancedSkewModeling",
    "RuntimeOptimized",
]

# UltraScale-only router directives
ULTRASCALE_ROUTER_DIRECTIVES = [
    "AlternateCLBRouting",
]

PHYS_OPT_DIRECTIVES = [
    "Default",
    "Explore",
    "ExploreWithHoldFix",
    "AggressiveExplore",
    "AlternateReplication",
    "AggressiveFanoutOpt",
    "AlternateFlowWithRetiming",
    "RuntimeOptimized",
]

# Step names in order
STEPS = ["synth", "opt", "place", "post_place_physopt", "route", "post_route_physopt"]

# Map step name to checkpoint that must exist to start at that step
STEP_REQUIRES_CHECKPOINT = {
    "synth": None,
    "opt": "post_synth.dcp",
    "place": "post_opt.dcp",
    "post_place_physopt": "post_place.dcp",
    "route": "post_place_physopt.dcp",
    "post_route_physopt": "post_route.dcp",
}

# Map step name to checkpoint produced after that step
STEP_PRODUCES_CHECKPOINT = {
    "synth": "post_synth.dcp",
    "opt": "post_opt.dcp",
    "place": "post_place.dcp",
    "post_place_physopt": "post_place_physopt.dcp",
    "route": "post_route.dcp",
    "post_route_physopt": "final.dcp",
}

# Map step name to report prefix
STEP_REPORT_PREFIX = {
    "synth": "post_synth",
    "opt": "post_opt",
    "place": "post_place",
    "post_place_physopt": "post_place_physopt",
    "route": "post_route",
    "post_route_physopt": "final",
}


# =============================================================================
# Data Classes
# =============================================================================


@dataclass
class TimingResult:
    """Timing results from a Vivado run."""

    directive: str
    wns_ns: float | None
    tns_ns: float | None
    whs_ns: float | None
    ths_ns: float | None
    work_dir: Path

    @property
    def timing_met(self) -> bool:
        """Return True if setup timing is met (WNS >= 0)."""
        return self.wns_ns is not None and self.wns_ns >= 0


@dataclass
class VivadoProcess:
    """A running Vivado process."""

    directive: str
    process: subprocess.Popen
    log_file: Path
    work_dir: Path


# =============================================================================
# Utility Functions
# =============================================================================


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


def select_best_result(results: list[TimingResult]) -> TimingResult | None:
    """Select the best result based on timing.

    Priority:
    1. Timing met (WNS >= 0)
    2. Best WNS (highest = least negative)
    3. Best TNS (least negative)
    """
    valid_results = [r for r in results if r.wns_ns is not None]
    if not valid_results:
        return None

    sorted_results = sorted(
        valid_results,
        key=lambda r: (
            r.timing_met,
            r.wns_ns if r.wns_ns is not None else float("-inf"),
            r.tns_ns if r.tns_ns is not None else float("-inf"),
        ),
        reverse=True,
    )

    return sorted_results[0]


def select_best_improvement(
    results: list[TimingResult], baseline_wns: float, baseline_tns: float
) -> TimingResult | None:
    """Select the result with the greatest improvement over baseline.

    For phys_opt loops, we want the directive that improved timing the most.
    If any achieves WNS >= 0, that wins immediately.
    """
    valid_results = [r for r in results if r.wns_ns is not None]
    if not valid_results:
        return None

    # If any met timing, pick it
    met_results = [r for r in valid_results if r.timing_met]
    if met_results:
        return select_best_result(met_results)

    # Otherwise pick the one with greatest WNS improvement
    sorted_results = sorted(
        valid_results,
        key=lambda r: (
            (r.wns_ns if r.wns_ns is not None else float("-inf")) - baseline_wns,
            (r.tns_ns if r.tns_ns is not None else float("-inf")) - baseline_tns,
        ),
        reverse=True,
    )

    return sorted_results[0]


def kill_process_tree(proc: VivadoProcess) -> None:
    """Kill a Vivado process and all its children."""
    try:
        os.killpg(os.getpgid(proc.process.pid), signal.SIGTERM)
    except (ProcessLookupError, OSError):
        pass


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


def print_results_table(
    results: list[TimingResult], winner: TimingResult | None, step: str
) -> None:
    """Print a formatted table of sweep results."""
    print(f"\n{'-'*90}")
    print(f"{step.upper()} SWEEP RESULTS")
    print(f"{'-'*90}")
    print(
        f"{'Directive':<30} {'WNS (ns)':>10} {'TNS (ns)':>12} {'Met':>6} {'Winner':>8}"
    )
    print(f"{'-'*90}")

    for r in sorted(results, key=lambda x: x.wns_ns or float("-inf"), reverse=True):
        wns = f"{r.wns_ns:.3f}" if r.wns_ns is not None else "FAILED"
        tns = f"{r.tns_ns:.3f}" if r.tns_ns is not None else "FAILED"
        met = "Yes" if r.timing_met else "No"
        is_winner = "*" if winner and r.directive == winner.directive else ""

        print(f"{r.directive:<30} {wns:>10} {tns:>12} {met:>6} {is_winner:>8}")

    print(f"{'-'*90}")
    if winner:
        print(f"Winner: {winner.directive} (WNS: {winner.wns_ns:.3f} ns)")


# =============================================================================
# Vivado Process Management
# =============================================================================


def start_vivado_step(
    script_dir: Path,
    board_name: str,
    step: str,
    directive: str,
    input_checkpoint: Path | None,
    vivado_path: str,
    retiming: bool = False,
    vivado_step_override: str | None = None,
) -> VivadoProcess:
    """Start a Vivado process for a single step with a specific directive.

    Args:
        vivado_step_override: Override the step name passed to Vivado TCL script.
                              Useful when step is used for directory naming but
                              Vivado needs a standard step name (e.g., "route" not "route_iter1").
    """
    work_dir = script_dir / board_name / f"work_{step}_{directive}"
    vivado_step = vivado_step_override or step
    work_dir.mkdir(parents=True, exist_ok=True)

    vivado_command = [
        vivado_path,
        "-mode",
        "batch",
        "-source",
        str(script_dir / "build_step.tcl"),
        "-nojournal",
        "-tclargs",
        board_name,
        vivado_step,
        directive,
        str(input_checkpoint) if input_checkpoint else "",
        "1" if retiming else "0",
    ]

    log_file = work_dir / "vivado.log"
    log_handle = open(log_file, "w")

    process = subprocess.Popen(
        vivado_command,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        cwd=work_dir,
        start_new_session=True,
    )

    return VivadoProcess(
        directive=directive,
        process=process,
        log_file=log_file,
        work_dir=work_dir,
    )


def run_parallel_sweep(
    script_dir: Path,
    board_name: str,
    step: str,
    directives: list[str],
    input_checkpoint: Path | None,
    vivado_path: str,
    retiming: bool = False,
    report_prefix_override: str | None = None,
    early_terminate: bool = False,
    vivado_step_override: str | None = None,
) -> tuple[TimingResult | None, list[TimingResult]]:
    """Run a parallel sweep of directives for a given step.

    Args:
        early_terminate: If True, stop as soon as any job achieves WNS >= 0.
                        If False, wait for all jobs and pick the best WNS.
                        Use False for early steps (to maximize margin for subsequent steps).
                        Use True for final steps (route, post_route_physopt).
        vivado_step_override: Override the step name passed to Vivado TCL script.

    Returns (winner, all_results).
    """
    report_prefix = report_prefix_override or STEP_REPORT_PREFIX.get(step, step)

    print(f"\n{'='*70}")
    if len(directives) == 1:
        print(f"STEP: {step.upper()} - Running {directives[0]} directive")
    else:
        print(
            f"STEP: {step.upper()} - Running {len(directives)} directives in parallel"
        )
    print(f"{'='*70}\n")

    # Single directive: run synchronously with output to stdout
    if len(directives) == 1:
        directive = directives[0]
        vivado_step = vivado_step_override or step
        work_dir = script_dir / board_name / f"work_{step}_{directive}"
        work_dir.mkdir(parents=True, exist_ok=True)

        vivado_command = [
            vivado_path,
            "-mode",
            "batch",
            "-source",
            str(script_dir / "build_step.tcl"),
            "-nojournal",
            "-tclargs",
            board_name,
            vivado_step,
            directive,
            str(input_checkpoint) if input_checkpoint else "",
            "1" if retiming else "0",
        ]

        result = subprocess.run(vivado_command, cwd=work_dir)

        if result.returncode == 0:
            timing_rpt = work_dir / f"{report_prefix}_timing.rpt"
            timing = extract_timing_from_report(timing_rpt)
            wns = timing.get("wns_ns")

            winner = TimingResult(
                directive=directive,
                wns_ns=wns,
                tns_ns=timing.get("tns_ns"),
                whs_ns=timing.get("whs_ns"),
                ths_ns=timing.get("ths_ns"),
                work_dir=work_dir,
            )

            if wns is not None:
                print(f"\n  [DONE] {directive} (WNS: {wns:.3f} ns)")
            else:
                print(f"\n  [DONE] {directive} (no timing data)")

            return winner, [winner]
        else:
            print(f"\n  [FAIL] {directive} (exit code {result.returncode})")
            return None, []

    # Multiple directives: run in parallel with output to log files
    running_procs: list[VivadoProcess] = []
    for directive in directives:
        proc = start_vivado_step(
            script_dir,
            board_name,
            step,
            directive,
            input_checkpoint,
            vivado_path,
            retiming,
            vivado_step_override,
        )
        running_procs.append(proc)
        _running_processes.append(proc)
        print(f"  [STARTED] {directive} (PID {proc.process.pid})")

    # Poll for completion
    completed: list[TimingResult] = []
    failed_directives: list[str] = []
    early_winner: TimingResult | None = None

    while running_procs:
        time.sleep(5)

        still_running = []
        for proc in running_procs:
            ret = proc.process.poll()
            if ret is None:
                still_running.append(proc)
            else:
                # Remove from global tracking
                if proc in _running_processes:
                    _running_processes.remove(proc)
                if ret == 0:
                    timing_rpt = proc.work_dir / f"{report_prefix}_timing.rpt"
                    timing = extract_timing_from_report(timing_rpt)
                    wns = timing.get("wns_ns")

                    result = TimingResult(
                        directive=proc.directive,
                        wns_ns=wns,
                        tns_ns=timing.get("tns_ns"),
                        whs_ns=timing.get("whs_ns"),
                        ths_ns=timing.get("ths_ns"),
                        work_dir=proc.work_dir,
                    )
                    completed.append(result)

                    if wns is not None:
                        print(f"  [DONE] {proc.directive} (WNS: {wns:.3f} ns)")
                        if (
                            early_terminate
                            and result.timing_met
                            and early_winner is None
                        ):
                            print("\n  *** TIMING MET! Stopping other jobs ***")
                            early_winner = result
                    else:
                        print(f"  [DONE] {proc.directive} (no timing data)")
                else:
                    failed_directives.append(proc.directive)
                    print(f"  [FAIL] {proc.directive} (exit code {ret})")

        running_procs = still_running

        # Early termination
        if early_winner is not None and running_procs:
            print(f"  Killing {len(running_procs)} remaining jobs...")
            for proc in running_procs:
                kill_process_tree(proc)
                if proc in _running_processes:
                    _running_processes.remove(proc)
            break

    print(f"\nCompleted: {len(completed)}/{len(directives)}")
    if failed_directives:
        print(f"Failed: {', '.join(failed_directives)}")

    # Select winner
    if early_winner is not None:
        winner = early_winner
    else:
        winner = select_best_result(completed)

    if winner:
        print_results_table(completed, winner, step)

    return winner, completed


def run_phys_opt_loop(
    script_dir: Path,
    board_name: str,
    step: str,
    directives: list[str],
    input_checkpoint: Path,
    vivado_path: str,
    report_prefix_override: str | None = None,
    output_checkpoint_override: str | None = None,
) -> TimingResult | None:
    """Run a loop of phys_opt sweeps until timing met or no improvement.

    Args:
        report_prefix_override: Override the output report prefix (default: from STEP_REPORT_PREFIX)
        output_checkpoint_override: Override the output checkpoint name (default: from STEP_PRODUCES_CHECKPOINT)
    """
    report_prefix = report_prefix_override or STEP_REPORT_PREFIX.get(step, "phys_opt")
    output_checkpoint = output_checkpoint_override or STEP_PRODUCES_CHECKPOINT.get(
        step, "phys_opt.dcp"
    )
    main_work = script_dir / board_name / "work"

    # Get baseline timing from input checkpoint's timing report
    input_stem = input_checkpoint.stem
    baseline_timing_rpt = input_checkpoint.parent / f"{input_stem}_timing.rpt"

    if not baseline_timing_rpt.exists():
        # Try main work directory - use step prefix to determine previous stage
        if step.startswith("post_place_physopt"):
            prev_prefix = "post_place"
        else:
            prev_prefix = "post_route"
        baseline_timing_rpt = main_work / f"{prev_prefix}_timing.rpt"

    baseline_timing = extract_timing_from_report(baseline_timing_rpt)
    baseline_wns = baseline_timing.get("wns_ns", float("-inf"))
    baseline_tns = baseline_timing.get("tns_ns", float("-inf"))

    print(f"\n{'='*70}")
    print(f"STEP: {step.upper()} - Phys_opt loop")
    print(f"Baseline: WNS={baseline_wns:.3f} ns, TNS={baseline_tns:.3f} ns")
    print(f"{'='*70}")

    # If already met timing, skip the loop
    if baseline_wns >= 0:
        print("\nTiming already met! Skipping phys_opt loop.")
        # Copy input checkpoint to output location
        output_checkpoint_path = main_work / output_checkpoint
        shutil.copy2(input_checkpoint, output_checkpoint_path)
        # Copy timing/util reports
        for suffix in [
            "_timing.rpt",
            "_util.rpt",
            "_high_fanout.rpt",
            "_failing_paths.csv",
        ]:
            src = (
                baseline_timing_rpt.parent
                / f"{baseline_timing_rpt.stem.replace('_timing', '')}{suffix}"
            )
            if src.exists():
                dst = main_work / f"{report_prefix}{suffix}"
                shutil.copy2(src, dst)
        return TimingResult(
            directive="(skipped - timing already met)",
            wns_ns=baseline_wns,
            tns_ns=baseline_tns,
            whs_ns=baseline_timing.get("whs_ns"),
            ths_ns=baseline_timing.get("ths_ns"),
            work_dir=main_work,
        )

    current_checkpoint = input_checkpoint
    pass_num = 0
    prev_wns = baseline_wns
    prev_tns = baseline_tns
    last_winner: TimingResult | None = None

    while True:
        pass_num += 1
        print(f"\n--- Pass {pass_num} (WNS={prev_wns:.3f}, TNS={prev_tns:.3f}) ---")

        # Run parallel sweep with unique step name
        # Only early-terminate for post_route_physopt (final step where timing met = done)
        # For post_place_physopt, wait for all to finish and pick best margin
        pass_step = f"{step}_pass{pass_num}"
        is_post_route = step.startswith("post_route_physopt")
        winner, all_results = run_parallel_sweep(
            script_dir,
            board_name,
            pass_step,
            directives,
            current_checkpoint,
            vivado_path,
            report_prefix_override="phys_opt",
            early_terminate=is_post_route,
        )

        if winner is None:
            print(f"All directives failed in pass {pass_num}!")
            if last_winner:
                return last_winner
            return None

        last_winner = winner

        # Check if timing met
        if winner.timing_met:
            print(f"\n*** TIMING MET in pass {pass_num}! WNS={winner.wns_ns:.3f} ***")
            break

        # Check for improvement
        curr_wns = winner.wns_ns if winner.wns_ns is not None else float("-inf")
        curr_tns = winner.tns_ns if winner.tns_ns is not None else float("-inf")
        wns_improved = curr_wns > prev_wns
        tns_improved = curr_tns > prev_tns

        if not wns_improved and not tns_improved:
            print(f"\nNo improvement in pass {pass_num}. Stopping loop.")
            print(f"  Previous: WNS={prev_wns:.3f}, TNS={prev_tns:.3f}")
            print(f"  Current:  WNS={curr_wns:.3f}, TNS={curr_tns:.3f}")
            break

        wns_delta = curr_wns - prev_wns
        tns_delta = curr_tns - prev_tns
        print(f"\nImprovement in pass {pass_num}:")
        print(
            f"  WNS: {prev_wns:.3f} -> {curr_wns:.3f} ({'+' if wns_delta >= 0 else ''}{wns_delta:.3f})"
        )
        print(
            f"  TNS: {prev_tns:.3f} -> {curr_tns:.3f} ({'+' if tns_delta >= 0 else ''}{tns_delta:.3f})"
        )

        # Update for next pass
        prev_wns = curr_wns
        prev_tns = curr_tns

        # Use winner's checkpoint for next pass
        phys_opt_checkpoint = winner.work_dir / "phys_opt.dcp"
        if phys_opt_checkpoint.exists():
            current_checkpoint = phys_opt_checkpoint
        else:
            print(f"Warning: phys_opt.dcp not found in {winner.work_dir}")
            break

    return last_winner


def run_route_physopt_meta_loop(
    script_dir: Path,
    board_name: str,
    input_checkpoint: Path,
    vivado_path: str,
    router_directives: list[str],
    physopt_directives: list[str],
    keep_temps: bool = False,
    no_sweeping: bool = False,
) -> TimingResult | None:
    """Run route + post_route_physopt meta-loop until no improvement.

    Flow:
    1. Run route sweep
    2. Run post_route_physopt loop (until no internal improvement)
    3. If iteration > 1 and route didn't improve over previous best, stop and use previous best
    4. Otherwise update best and go back to step 1
    5. Stop when timing met (WNS >= 0) or no improvement

    Returns the best result achieved.
    """
    main_work = script_dir / board_name / "work"

    # Get baseline timing from input checkpoint
    baseline_timing_rpt = main_work / "post_place_physopt_timing.rpt"
    baseline_timing = extract_timing_from_report(baseline_timing_rpt)
    best_wns = baseline_timing.get("wns_ns", float("-inf"))
    best_tns = baseline_timing.get("tns_ns", float("-inf"))

    print(f"\n{'#'*70}")
    print("# ROUTE + POST_ROUTE_PHYSOPT META-LOOP")
    print(f"# Baseline: WNS={best_wns:.3f} ns, TNS={best_tns:.3f} ns")
    print(f"{'#'*70}")

    # Track the best result we've achieved
    best_result: TimingResult | None = None
    current_checkpoint = input_checkpoint

    iteration = 0
    while True:
        iteration += 1
        print(f"\n{'='*70}")
        print(f"META-LOOP ITERATION {iteration}")
        print(f"Best so far: WNS={best_wns:.3f} ns, TNS={best_tns:.3f} ns")
        print(f"{'='*70}")

        # === ROUTE SWEEP ===
        route_step = f"route_iter{iteration}"
        route_winner, _ = run_parallel_sweep(
            script_dir,
            board_name,
            route_step,
            router_directives,
            current_checkpoint,
            vivado_path,
            report_prefix_override="post_route",
            early_terminate=True,  # Can early-terminate at route stage
            vivado_step_override="route",  # TCL expects "route", not "route_iter1"
        )

        if route_winner is None:
            print(f"Route sweep failed in iteration {iteration}!")
            break

        route_wns = (
            route_winner.wns_ns if route_winner.wns_ns is not None else float("-inf")
        )
        route_tns = (
            route_winner.tns_ns if route_winner.tns_ns is not None else float("-inf")
        )

        # After iteration 1, check if route improved over previous best
        if iteration > 1:
            route_improved = (route_wns > best_wns) or (
                route_wns == best_wns and route_tns > best_tns
            )
            if not route_improved:
                print(
                    f"\nRoute iteration {iteration} did not improve over previous best."
                )
                print(f"  Previous best: WNS={best_wns:.3f}, TNS={best_tns:.3f}")
                print(f"  Route result:  WNS={route_wns:.3f}, TNS={route_tns:.3f}")
                print("Rolling back to previous best result.")
                # Clean up this route iteration's temp dirs
                if not keep_temps:
                    cleanup_temp_dirs(script_dir, board_name, route_step)
                break

        print(
            f"\nRoute iteration {iteration} result: WNS={route_wns:.3f}, TNS={route_tns:.3f}"
        )

        # Copy route winner to main work as post_route checkpoint
        copy_winner_to_main_work(script_dir, board_name, route_winner, "route")
        if not keep_temps:
            cleanup_temp_dirs(script_dir, board_name, route_step)

        # If timing met after route, we're done - copy post_route to final
        if route_wns >= 0:
            print(f"\n*** TIMING MET after route! WNS={route_wns:.3f} ***")
            # Copy post_route checkpoint and reports to final
            shutil.copy2(main_work / "post_route.dcp", main_work / "final.dcp")
            for suffix in [
                "_timing.rpt",
                "_util.rpt",
                "_high_fanout.rpt",
                "_failing_paths.csv",
            ]:
                src = main_work / f"post_route{suffix}"
                if src.exists():
                    shutil.copy2(src, main_work / f"final{suffix}")
            best_result = route_winner
            best_result.work_dir = main_work
            best_wns = route_wns
            best_tns = route_tns
            break

        # === POST-ROUTE PHYS_OPT LOOP ===
        physopt_step = f"post_route_physopt_iter{iteration}"
        post_route_checkpoint = main_work / "post_route.dcp"

        physopt_winner = run_phys_opt_loop(
            script_dir,
            board_name,
            physopt_step,
            physopt_directives,
            post_route_checkpoint,
            vivado_path,
            report_prefix_override="final",
            output_checkpoint_override="final.dcp",
        )

        if physopt_winner is None:
            print(f"Post-route phys_opt failed in iteration {iteration}!")
            # Use route result as best for this iteration
            best_result = route_winner
            best_result.work_dir = main_work
            best_wns = route_wns
            best_tns = route_tns
            break

        physopt_wns = (
            physopt_winner.wns_ns
            if physopt_winner.wns_ns is not None
            else float("-inf")
        )
        physopt_tns = (
            physopt_winner.tns_ns
            if physopt_winner.tns_ns is not None
            else float("-inf")
        )

        print(
            f"\nPost-route phys_opt iteration {iteration} result: WNS={physopt_wns:.3f}, TNS={physopt_tns:.3f}"
        )

        # Copy phys_opt winner to main work as final checkpoint
        if physopt_winner.work_dir != main_work:
            copy_winner_to_main_work(
                script_dir, board_name, physopt_winner, "post_route_physopt"
            )
        if not keep_temps:
            cleanup_temp_dirs(script_dir, board_name, physopt_step)
            # Also clean up phys_opt pass directories
            for pattern in [f"work_{physopt_step}_pass*_*"]:
                for d in (script_dir / board_name).glob(pattern):
                    if d.is_dir():
                        shutil.rmtree(d)

        # Update best result
        improved = (physopt_wns > best_wns) or (
            physopt_wns == best_wns and physopt_tns > best_tns
        )
        if improved:
            best_wns = physopt_wns
            best_tns = physopt_tns
            best_result = TimingResult(
                directive=f"iter{iteration}:{physopt_winner.directive}",
                wns_ns=physopt_wns,
                tns_ns=physopt_tns,
                whs_ns=physopt_winner.whs_ns,
                ths_ns=physopt_winner.ths_ns,
                work_dir=main_work,
            )
            print(f"New best: WNS={best_wns:.3f}, TNS={best_tns:.3f}")

        # If timing met, we're done
        if physopt_wns >= 0:
            print(f"\n*** TIMING MET after phys_opt! WNS={physopt_wns:.3f} ***")
            break

        # For next iteration, we still route from the original post_place_physopt checkpoint
        # (current_checkpoint remains unchanged - we always route fresh from the placed design)

    # Final summary
    if best_result:
        print(f"\n{'='*70}")
        print(f"META-LOOP COMPLETE after {iteration} iteration(s)")
        print(f"Final: WNS={best_wns:.3f} ns, TNS={best_tns:.3f} ns")
        print(f"Timing Met: {'YES!' if best_wns >= 0 else 'No'}")
        print(f"{'='*70}")

    return best_result


# =============================================================================
# Step Execution
# =============================================================================


def copy_winner_to_main_work(
    script_dir: Path,
    board_name: str,
    winner: TimingResult,
    step: str,
) -> None:
    """Copy winning run's checkpoint and reports to main work directory."""
    main_work = script_dir / board_name / "work"
    main_work.mkdir(parents=True, exist_ok=True)

    report_prefix = STEP_REPORT_PREFIX[step]
    checkpoint_name = STEP_PRODUCES_CHECKPOINT[step]

    # Copy checkpoint
    for dcp in winner.work_dir.glob("*.dcp"):
        # Rename to standard name
        dst = main_work / checkpoint_name
        shutil.copy2(dcp, dst)
        print(f"  Checkpoint: {dst}")
        break

    # Copy reports with standard naming
    for suffix in [
        "_timing.rpt",
        "_util.rpt",
        "_high_fanout.rpt",
        "_failing_paths.csv",
    ]:
        # Look for report with any prefix
        for rpt in winner.work_dir.glob(f"*{suffix}"):
            dst = main_work / f"{report_prefix}{suffix}"
            shutil.copy2(rpt, dst)
            break


def cleanup_temp_dirs(script_dir: Path, board_name: str, step: str) -> None:
    """Clean up temporary work directories for a step."""
    board_dir = script_dir / board_name
    patterns = [
        f"work_{step}_*",
        f"work_{step}_pass*_*",
    ]
    for pattern in patterns:
        for d in board_dir.glob(pattern):
            if d.is_dir():
                shutil.rmtree(d)


def run_step(
    script_dir: Path,
    board_name: str,
    step: str,
    vivado_path: str,
    retiming: bool,
    is_ultrascale: bool,
    keep_temps: bool = False,
    no_sweeping: bool = False,
) -> bool:
    """Run a single build step with parallel sweep."""
    main_work = script_dir / board_name / "work"
    main_work.mkdir(parents=True, exist_ok=True)

    # Get input checkpoint
    required_checkpoint = STEP_REQUIRES_CHECKPOINT[step]
    if required_checkpoint:
        input_checkpoint = main_work / required_checkpoint
        if not input_checkpoint.exists():
            print(f"Error: Required checkpoint not found: {input_checkpoint}")
            return False
    else:
        input_checkpoint = None

    # Get directives for this step
    if no_sweeping:
        directives = ["Default"]
    elif step == "synth":
        directives = SYNTH_DIRECTIVES.copy()
    elif step == "opt":
        directives = OPT_DIRECTIVES.copy()
    elif step == "place":
        directives = PLACER_DIRECTIVES.copy()
    elif step in ["post_place_physopt", "post_route_physopt"]:
        directives = PHYS_OPT_DIRECTIVES.copy()
    elif step == "route":
        directives = ROUTER_DIRECTIVES.copy()
        if is_ultrascale:
            directives.extend(ULTRASCALE_ROUTER_DIRECTIVES)
    else:
        print(f"Error: Unknown step {step}")
        return False

    # Run the step
    if step in ["post_place_physopt", "post_route_physopt"]:
        winner = run_phys_opt_loop(
            script_dir,
            board_name,
            step,
            directives,
            input_checkpoint,
            vivado_path,
        )
    else:
        # Only early-terminate for route step (final steps where timing met = done)
        # For earlier steps, wait for all to finish and pick best margin
        winner, _ = run_parallel_sweep(
            script_dir,
            board_name,
            step,
            directives,
            input_checkpoint,
            vivado_path,
            retiming=retiming if step == "synth" else False,
            early_terminate=(step == "route"),
        )

    if winner is None:
        print(f"\nNo successful runs for step {step}!")
        return False

    # Copy winner to main work directory
    if winner.work_dir != main_work:
        print(f"\nCopying winner ({winner.directive}) to main work directory...")
        copy_winner_to_main_work(script_dir, board_name, winner, step)

    # Clean up temp directories
    if not keep_temps:
        cleanup_temp_dirs(script_dir, board_name, step)

    print(
        f"\n*** Step {step} complete: Winner = {winner.directive}, WNS = {winner.wns_ns:.3f} ns ***"
    )
    return True


def generate_bitstream(
    script_dir: Path,
    board_name: str,
    vivado_path: str,
) -> bool:
    """Generate bitstream from final checkpoint."""
    main_work = script_dir / board_name / "work"
    final_checkpoint = main_work / "final.dcp"

    if not final_checkpoint.exists():
        print(f"Error: Final checkpoint not found: {final_checkpoint}")
        return False

    print(f"\n{'='*70}")
    print("Generating bitstream...")
    print(f"{'='*70}\n")

    vivado_command = [
        vivado_path,
        "-mode",
        "batch",
        "-source",
        str(script_dir / "build_step.tcl"),
        "-nojournal",
        "-tclargs",
        board_name,
        "bitstream",
        "Default",
        str(final_checkpoint),
        "0",
    ]

    result = subprocess.run(vivado_command, cwd=main_work)
    if result.returncode != 0:
        print("Error: Bitstream generation failed")
        return False

    bitstream = main_work / f"{board_name}_frost.bit"
    if bitstream.exists():
        print(f"\nBitstream generated: {bitstream}")
        return True
    else:
        print("Error: Bitstream not created")
        return False


# =============================================================================
# Main
# =============================================================================


def main() -> None:
    """Run unified FPGA build with parallel sweeps."""
    parser = argparse.ArgumentParser(
        description="One script to rule them all - unified FPGA build with parallel sweeps",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Steps (in order):
  synth              - Synthesis with directive sweep (wait for all, pick best)
  opt                - Opt design with directive sweep (wait for all, pick best)
  place              - Place design with directive sweep (wait for all, pick best)
  post_place_physopt - Post-place phys_opt loop of sweeps (wait for all each pass)
  route              - Route + post_route_physopt meta-loop:
  post_route_physopt   - Alternates route/physopt until no improvement or timing met

Note: When running both route and post_route_physopt, they execute as a single
meta-loop that iterates until timing is met or no further improvement is found.

Examples:
  ./build.py x3                           # Full build with all sweeps
  ./build.py x3 --start-at place          # Resume from post_opt checkpoint
  ./build.py x3 --stop-after place        # Run synth, opt, place only
  ./build.py nexys_a7 --start-at route    # Resume at route+physopt meta-loop
  ./build.py x3 --start-at post_route_physopt  # Run physopt only (no re-routing)
  ./build.py x3 --no-sweeping             # Fast build with Default directives only
  ./build.py genesys2 --sweep             # Force parallel sweeps (not default for genesys2)
""",
    )
    parser.add_argument(
        "board_name",
        nargs="?",
        default="x3",
        choices=["x3", "genesys2", "nexys_a7"],
        help="Target board (default: x3)",
    )
    parser.add_argument(
        "--start-at",
        choices=STEPS,
        default="synth",
        help="Start at this step (requires appropriate checkpoint)",
    )
    parser.add_argument(
        "--stop-after",
        choices=STEPS,
        help="Stop after this step",
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
        "--keep-temps",
        action="store_true",
        help="Keep temporary work directories",
    )
    parser.add_argument(
        "--no-sweeping",
        action="store_true",
        help="Use only Default directive for each step (default for genesys2/nexys_a7)",
    )
    parser.add_argument(
        "--sweep",
        action="store_true",
        help="Force parallel directive sweeps (override default for genesys2/nexys_a7)",
    )
    args = parser.parse_args()

    board_name = args.board_name

    # Determine sweeping behavior: x3 sweeps by default, others don't
    if args.no_sweeping and args.sweep:
        print("Error: Cannot specify both --no-sweeping and --sweep", file=sys.stderr)
        sys.exit(1)
    if args.sweep:
        no_sweeping = False
    elif args.no_sweeping:
        no_sweeping = True
    else:
        # Default: sweep only for x3
        no_sweeping = board_name in ["genesys2", "nexys_a7"]
    script_dir = Path(__file__).parent.resolve()
    project_root = script_dir.parent.parent

    # Get board configuration
    board_config = BOARD_CONFIG[board_name]
    clock_freq = board_config["clock_freq"]
    is_ultrascale = board_config["is_ultrascale"]

    print(f"\n{'#'*70}")
    print(f"# FROST FPGA Build - {board_name.upper()}")
    print(f"# Clock: {clock_freq:,} Hz")
    print(f"# UltraScale: {'Yes' if is_ultrascale else 'No'}")
    if no_sweeping:
        print("# Mode: No sweeping (Default directives only)")
    print(f"{'#'*70}")

    # Compile hello_world (skip if resuming from a checkpoint)
    if args.start_at == "synth":
        if not compile_hello_world(project_root, clock_freq):
            print("Error: Failed to compile hello_world", file=sys.stderr)
            sys.exit(1)

    # Determine which steps to run
    start_idx = STEPS.index(args.start_at)
    if args.stop_after:
        stop_idx = STEPS.index(args.stop_after)
    else:
        stop_idx = len(STEPS) - 1

    steps_to_run = STEPS[start_idx : stop_idx + 1]

    print(f"\nSteps to run: {' -> '.join(steps_to_run)}")

    # Check required checkpoint for start step
    main_work = script_dir / board_name / "work"
    required_checkpoint = STEP_REQUIRES_CHECKPOINT[args.start_at]
    if required_checkpoint:
        checkpoint_path = main_work / required_checkpoint
        if not checkpoint_path.exists():
            print(f"\nError: Cannot start at '{args.start_at}'")
            print(f"Required checkpoint not found: {checkpoint_path}")
            sys.exit(1)
        print(f"Starting from checkpoint: {checkpoint_path}")

    # Get router directives with ultrascale variants if needed
    if no_sweeping:
        router_directives = ["Default"]
        physopt_directives = ["Default"]
    else:
        router_directives = ROUTER_DIRECTIVES.copy()
        if is_ultrascale:
            router_directives.extend(ULTRASCALE_ROUTER_DIRECTIVES)
        physopt_directives = PHYS_OPT_DIRECTIVES.copy()

    # Run steps - use meta-loop for route+post_route_physopt
    run_meta_loop = "route" in steps_to_run and "post_route_physopt" in steps_to_run
    meta_loop_start_step = None

    for step in steps_to_run:
        # If we're at route and need to run meta-loop, do it and skip both route steps
        if step == "route" and run_meta_loop:
            meta_loop_start_step = "route"
            input_checkpoint = main_work / STEP_REQUIRES_CHECKPOINT["route"]

            result = run_route_physopt_meta_loop(
                script_dir,
                board_name,
                input_checkpoint,
                args.vivado_path,
                router_directives,
                physopt_directives,
                args.keep_temps,
                no_sweeping,
            )

            if result is None:
                print("\nError: Route + post_route_physopt meta-loop failed!")
                sys.exit(1)

            continue

        # Skip post_route_physopt if we already ran the meta-loop
        if step == "post_route_physopt" and meta_loop_start_step == "route":
            continue

        # If starting at post_route_physopt directly (not from route), run it standalone
        if step == "post_route_physopt" and meta_loop_start_step is None:
            winner = run_phys_opt_loop(
                script_dir,
                board_name,
                step,
                physopt_directives,
                main_work / STEP_REQUIRES_CHECKPOINT[step],
                args.vivado_path,
            )
            if winner is None:
                print(f"\nError: Step '{step}' failed!")
                sys.exit(1)
            if winner.work_dir != main_work:
                copy_winner_to_main_work(script_dir, board_name, winner, step)
            if not args.keep_temps:
                cleanup_temp_dirs(script_dir, board_name, step)
            continue

        if not run_step(
            script_dir,
            board_name,
            step,
            args.vivado_path,
            args.retiming,
            is_ultrascale,
            args.keep_temps,
            no_sweeping,
        ):
            print(f"\nError: Step '{step}' failed!")
            sys.exit(1)

    # Generate bitstream if we completed post_route_physopt
    if "post_route_physopt" in steps_to_run or meta_loop_start_step == "route":
        if not generate_bitstream(script_dir, board_name, args.vivado_path):
            sys.exit(1)

    # Generate SUMMARY files only for the stages that were actually run
    print(f"\n{'='*70}")
    print("Generating SUMMARY files...")
    print(f"{'='*70}")

    # Determine which report prefixes correspond to the steps we ran
    stages_run = [STEP_REPORT_PREFIX[s] for s in steps_to_run]

    extract_script = script_dir / "extract_timing_and_util_summary.py"
    if extract_script.exists():
        subprocess.run(
            [
                "python3",
                str(extract_script),
                board_name,
                "--stages",
                ",".join(stages_run),
            ],
            check=True,
        )

    # Final summary - use timing from the last step that was actually run
    print(f"\n{'#'*70}")
    print("# BUILD COMPLETE!")
    print(f"{'#'*70}")

    last_stage = stages_run[-1]
    last_timing_rpt = main_work / f"{last_stage}_timing.rpt"
    if last_timing_rpt.exists():
        timing = extract_timing_from_report(last_timing_rpt)
        if timing.get("wns_ns") is not None:
            print(f"\nTiming (after {last_stage}):")
            print(f"  WNS: {timing['wns_ns']:.3f} ns")
            print(f"  TNS: {timing['tns_ns']:.3f} ns")
            print(f"  Timing Met: {'YES!' if timing['wns_ns'] >= 0 else 'No'}")

    bitstream = main_work / f"{board_name}_frost.bit"
    if bitstream.exists():
        print(f"\nBitstream: {bitstream}")


if __name__ == "__main__":
    main()
