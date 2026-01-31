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

"""Full FPGA build with parallel sweeps at ALL stages.

This script performs a complete FPGA build sweeping all four stages in parallel:
1. Synthesis: 10 synth_design directives in parallel → pick best WNS
2. Optimization: 6 opt_design directives in parallel → pick best WNS
3. Placement: 12 place_design directives in parallel → pick best WNS
4. Routing: 8-9 route_design directives in parallel → pick best WNS

Each stage picks the best result (by WNS) and uses it as the starting point for the next.
All the normal build steps are preserved:
- Overconstraining (+1.0ns) applied before placement
- phys_opt_design after placement
- Overconstraining removed before routing
- Two phys_opt_design passes after routing
- Final reports and bitstream generation
"""

import argparse
import os
import re
import shutil
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

# All available Vivado synth_design directives
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

# All available Vivado opt_design directives
ALL_OPT_DIRECTIVES = [
    "Default",
    "Explore",
    "ExploreArea",
    "ExploreWithRemap",
    "ExploreSequentialArea",
    "RuntimeOptimized",
]

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

# ML-predicted placer directives
AUTO_PLACER_DIRECTIVES = ["Auto_1", "Auto_2", "Auto_3"]

# Non-SSI placer directives (for 7-series and single-die UltraScale+)
NON_SSI_PLACER_DIRECTIVES = [
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

# UltraScale-only router directives
ULTRASCALE_ROUTER_DIRECTIVES = [
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


@dataclass
class VivadoProcess:
    """A running Vivado process."""

    directive: str
    process: subprocess.Popen
    log_file: Path
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


def wait_for_processes(
    running_procs: list[VivadoProcess],
    stage_name: str,
) -> tuple[list[str], list[str]]:
    """Wait for all processes to complete, return (completed, failed) directive lists."""
    completed_directives: list[str] = []
    failed_directives: list[str] = []

    while running_procs:
        time.sleep(5)  # Poll every 5 seconds

        still_running = []
        for proc in running_procs:
            ret = proc.process.poll()
            if ret is None:
                still_running.append(proc)
            else:
                if ret == 0:
                    completed_directives.append(proc.directive)
                    print(f"  [{stage_name}] [DONE] {proc.directive}")
                else:
                    failed_directives.append(proc.directive)
                    print(
                        f"  [{stage_name}] [FAIL] {proc.directive} (return code {ret})"
                    )

        running_procs[:] = still_running

    return completed_directives, failed_directives


def print_results_table(
    results: list[TimingResult],
    winner: TimingResult | None,
    stage_name: str,
) -> None:
    """Print a formatted table of results."""
    print("\n" + "=" * 80)
    print(f"{stage_name} SWEEP RESULTS")
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


def cleanup_work_dirs(
    script_dir: Path,
    board_name: str,
    directives: list[str],
    keep_all: bool,
) -> None:
    """Clean up work directories for non-winners."""
    if keep_all:
        return
    for directive in directives:
        work_dir = script_dir / board_name / f"work_{directive}"
        if work_dir.exists():
            shutil.rmtree(work_dir)


# =============================================================================
# Stage 1: Synthesis Sweep
# =============================================================================


def start_synth_process(
    script_dir: Path,
    board_name: str,
    directive: str,
    retiming: bool,
    vivado_path: str,
) -> VivadoProcess:
    """Start a synthesis process with a specific directive."""
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
        "Default",  # placer_directive (not used)
        "",  # checkpoint_path
        directive,  # work_suffix
        directive,  # synth_directive
    ]

    work_dir = script_dir / board_name / f"work_{directive}"
    work_dir.mkdir(parents=True, exist_ok=True)
    log_file = work_dir / "vivado.log"

    log_handle = open(log_file, "w")
    process = subprocess.Popen(
        vivado_command,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )

    return VivadoProcess(
        directive=directive,
        process=process,
        log_file=log_file,
        work_dir=work_dir,
    )


def run_synth_sweep(
    script_dir: Path,
    board_name: str,
    directives: list[str],
    retiming: bool,
    vivado_path: str,
    keep_all: bool,
) -> TimingResult | None:
    """Run synthesis sweep, return winning result."""
    print(f"\n{'='*60}")
    print(f"STAGE 1: Running {len(directives)} synthesis jobs in parallel...")
    print(f"{'='*60}\n")

    # Clean up existing work directories
    for directive in directives:
        work_dir = script_dir / board_name / f"work_{directive}"
        if work_dir.exists():
            shutil.rmtree(work_dir)

    # Start all processes
    running_procs: list[VivadoProcess] = []
    for directive in directives:
        proc = start_synth_process(
            script_dir, board_name, directive, retiming, vivado_path
        )
        running_procs.append(proc)
        print(f"  [SYNTH] [STARTED] {directive} (PID {proc.process.pid})")

    # Wait for completion
    completed, failed = wait_for_processes(running_procs, "SYNTH")
    print(f"\nSynthesis completed: {len(completed)}/{len(directives)}")

    # Harvest results
    results = []
    for directive in directives:
        work_dir = script_dir / board_name / f"work_{directive}"
        timing_rpt = work_dir / "post_synth_timing.rpt"
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

    winner = select_best_result(results)
    print_results_table(results, winner, "SYNTHESIS")

    if winner:
        print(
            f"\n*** SYNTH WINNER: {winner.directive} (WNS: {winner.wns_ns:.3f} ns) ***"
        )

        # Move winner to main work directory
        main_work = script_dir / board_name / "work"
        if main_work.exists():
            shutil.rmtree(main_work)
        shutil.move(winner.work_dir, main_work)

        cleanup_work_dirs(script_dir, board_name, directives, keep_all)

    return winner


# =============================================================================
# Stage 2: Opt Sweep
# =============================================================================


def start_opt_process(
    script_dir: Path,
    board_name: str,
    directive: str,
    checkpoint_path: Path,
    vivado_path: str,
) -> VivadoProcess:
    """Start an opt_design process with a specific directive."""
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
        "1",  # opt_only - stop after opt_design
        "Default",  # placer_directive (not used)
        str(checkpoint_path),
        directive,  # work_suffix
        "PerformanceOptimized",  # synth_directive (not used)
        directive,  # opt_directive
    ]

    work_dir = script_dir / board_name / f"work_{directive}"
    work_dir.mkdir(parents=True, exist_ok=True)
    log_file = work_dir / "vivado.log"

    log_handle = open(log_file, "w")
    process = subprocess.Popen(
        vivado_command,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )

    return VivadoProcess(
        directive=directive,
        process=process,
        log_file=log_file,
        work_dir=work_dir,
    )


def run_opt_sweep(
    script_dir: Path,
    board_name: str,
    directives: list[str],
    vivado_path: str,
    keep_all: bool,
) -> TimingResult | None:
    """Run opt_design sweep, return winning result."""
    checkpoint = script_dir / board_name / "work" / "post_synth.dcp"
    if not checkpoint.exists():
        print(f"Error: Checkpoint not found: {checkpoint}", file=sys.stderr)
        return None

    print(f"\n{'='*60}")
    print(f"STAGE 2: Running {len(directives)} opt_design jobs in parallel...")
    print(f"{'='*60}\n")

    # Clean up existing work directories
    for directive in directives:
        work_dir = script_dir / board_name / f"work_{directive}"
        if work_dir.exists():
            shutil.rmtree(work_dir)

    # Start all processes
    running_procs: list[VivadoProcess] = []
    for directive in directives:
        proc = start_opt_process(
            script_dir, board_name, directive, checkpoint, vivado_path
        )
        running_procs.append(proc)
        print(f"  [OPT] [STARTED] {directive} (PID {proc.process.pid})")

    # Wait for completion
    completed, failed = wait_for_processes(running_procs, "OPT")
    print(f"\nOpt_design completed: {len(completed)}/{len(directives)}")

    # Harvest results
    results = []
    for directive in directives:
        work_dir = script_dir / board_name / f"work_{directive}"
        timing_rpt = work_dir / "post_opt_timing.rpt"
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

    winner = select_best_result(results)
    print_results_table(results, winner, "OPT_DESIGN")

    if winner:
        print(f"\n*** OPT WINNER: {winner.directive} (WNS: {winner.wns_ns:.3f} ns) ***")

        # Preserve post_synth files
        main_work = script_dir / board_name / "work"
        temp_dir = script_dir / board_name / "work_preserve_temp"
        temp_dir.mkdir(exist_ok=True)
        for f in main_work.glob("post_synth*"):
            shutil.copy2(f, temp_dir / f.name)

        # Move winner to main work
        shutil.rmtree(main_work)
        shutil.move(winner.work_dir, main_work)

        # Restore preserved files
        for f in temp_dir.iterdir():
            shutil.copy2(f, main_work / f.name)
        shutil.rmtree(temp_dir)

        cleanup_work_dirs(script_dir, board_name, directives, keep_all)

    return winner


# =============================================================================
# Stage 3: Placer Sweep
# =============================================================================


def start_place_process(
    script_dir: Path,
    board_name: str,
    directive: str,
    checkpoint_path: Path,
    vivado_path: str,
) -> VivadoProcess:
    """Start a place_design process with a specific directive."""
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
        str(checkpoint_path),
        directive,  # work_suffix
        "PerformanceOptimized",  # synth_directive (not used)
        "ExploreWithRemap",  # opt_directive (not used)
        "1",  # place_only - stop after place_design + phys_opt
    ]

    work_dir = script_dir / board_name / f"work_{directive}"
    work_dir.mkdir(parents=True, exist_ok=True)
    log_file = work_dir / "vivado.log"

    log_handle = open(log_file, "w")
    process = subprocess.Popen(
        vivado_command,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )

    return VivadoProcess(
        directive=directive,
        process=process,
        log_file=log_file,
        work_dir=work_dir,
    )


def run_placer_sweep(
    script_dir: Path,
    board_name: str,
    directives: list[str],
    vivado_path: str,
    keep_all: bool,
) -> TimingResult | None:
    """Run place_design sweep, return winning result."""
    checkpoint = script_dir / board_name / "work" / "post_opt.dcp"
    if not checkpoint.exists():
        print(f"Error: Checkpoint not found: {checkpoint}", file=sys.stderr)
        return None

    print(f"\n{'='*60}")
    print(f"STAGE 3: Running {len(directives)} place_design jobs in parallel...")
    print(f"{'='*60}\n")

    # Clean up existing work directories
    for directive in directives:
        work_dir = script_dir / board_name / f"work_{directive}"
        if work_dir.exists():
            shutil.rmtree(work_dir)

    # Start all processes
    running_procs: list[VivadoProcess] = []
    for directive in directives:
        proc = start_place_process(
            script_dir, board_name, directive, checkpoint, vivado_path
        )
        running_procs.append(proc)
        print(f"  [PLACE] [STARTED] {directive} (PID {proc.process.pid})")

    # Wait for completion
    completed, failed = wait_for_processes(running_procs, "PLACE")
    print(f"\nPlace_design completed: {len(completed)}/{len(directives)}")

    # Harvest results
    results = []
    for directive in directives:
        work_dir = script_dir / board_name / f"work_{directive}"
        timing_rpt = work_dir / "post_place_timing.rpt"
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

    winner = select_best_result(results)
    print_results_table(results, winner, "PLACE_DESIGN")

    if winner:
        print(
            f"\n*** PLACER WINNER: {winner.directive} (WNS: {winner.wns_ns:.3f} ns) ***"
        )

        # Preserve post_synth and post_opt files
        main_work = script_dir / board_name / "work"
        temp_dir = script_dir / board_name / "work_preserve_temp"
        temp_dir.mkdir(exist_ok=True)
        for prefix in ["post_synth", "post_opt"]:
            for f in main_work.glob(f"{prefix}*"):
                shutil.copy2(f, temp_dir / f.name)

        # Move winner to main work
        shutil.rmtree(main_work)
        shutil.move(winner.work_dir, main_work)

        # Restore preserved files
        for f in temp_dir.iterdir():
            shutil.copy2(f, main_work / f.name)
        shutil.rmtree(temp_dir)

        cleanup_work_dirs(script_dir, board_name, directives, keep_all)

    return winner


# =============================================================================
# Stage 4: Router Sweep
# =============================================================================


def start_route_process(
    script_dir: Path,
    board_name: str,
    directive: str,
    checkpoint_path: Path,
    vivado_path: str,
) -> VivadoProcess:
    """Start a route_design process with a specific directive."""
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
        "Default",  # placer_directive (not used - loading post_place)
        str(checkpoint_path),
        directive,  # work_suffix
        "PerformanceOptimized",  # synth_directive (not used)
        "ExploreWithRemap",  # opt_directive (not used)
        "0",  # place_only
        directive,  # router_directive
    ]

    work_dir = script_dir / board_name / f"work_{directive}"
    work_dir.mkdir(parents=True, exist_ok=True)
    log_file = work_dir / "vivado.log"

    log_handle = open(log_file, "w")
    process = subprocess.Popen(
        vivado_command,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )

    return VivadoProcess(
        directive=directive,
        process=process,
        log_file=log_file,
        work_dir=work_dir,
    )


def run_router_sweep(
    script_dir: Path,
    board_name: str,
    directives: list[str],
    vivado_path: str,
    keep_all: bool,
) -> TimingResult | None:
    """Run route_design sweep, return winning result."""
    checkpoint = script_dir / board_name / "work" / "post_place.dcp"
    if not checkpoint.exists():
        print(f"Error: Checkpoint not found: {checkpoint}", file=sys.stderr)
        return None

    print(f"\n{'='*60}")
    print(f"STAGE 4: Running {len(directives)} route_design jobs in parallel...")
    print(f"{'='*60}\n")

    # Clean up existing work directories
    for directive in directives:
        work_dir = script_dir / board_name / f"work_{directive}"
        if work_dir.exists():
            shutil.rmtree(work_dir)

    # Start all processes
    running_procs: list[VivadoProcess] = []
    for directive in directives:
        proc = start_route_process(
            script_dir, board_name, directive, checkpoint, vivado_path
        )
        running_procs.append(proc)
        print(f"  [ROUTE] [STARTED] {directive} (PID {proc.process.pid})")

    # Wait for completion
    completed, failed = wait_for_processes(running_procs, "ROUTE")
    print(f"\nRoute_design completed: {len(completed)}/{len(directives)}")

    # Harvest results
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

    winner = select_best_result(results)
    print_results_table(results, winner, "ROUTE_DESIGN")

    if winner:
        print(
            f"\n*** ROUTER WINNER: {winner.directive} (WNS: {winner.wns_ns:.3f} ns) ***"
        )

        # Preserve post_synth, post_opt, and post_place files
        main_work = script_dir / board_name / "work"
        temp_dir = script_dir / board_name / "work_preserve_temp"
        temp_dir.mkdir(exist_ok=True)
        for prefix in ["post_synth", "post_opt", "post_place"]:
            for f in main_work.glob(f"{prefix}*"):
                shutil.copy2(f, temp_dir / f.name)

        # Move winner to main work
        shutil.rmtree(main_work)
        shutil.move(winner.work_dir, main_work)

        # Restore preserved files
        for f in temp_dir.iterdir():
            shutil.copy2(f, main_work / f.name)
        shutil.rmtree(temp_dir)

        cleanup_work_dirs(script_dir, board_name, directives, keep_all)

    return winner


# =============================================================================
# Main
# =============================================================================


def main() -> None:
    """Run full build with sweeps at all stages."""
    parser = argparse.ArgumentParser(
        description="Full FPGA build with parallel sweeps at ALL stages"
    )
    parser.add_argument(
        "board_name",
        nargs="?",
        default="x3",
        choices=["x3", "genesys2", "nexys_a7"],
        help="Target board (default: x3)",
    )
    parser.add_argument(
        "--synth-directives",
        nargs="+",
        help="Specific synthesis directives (default: all 10)",
    )
    parser.add_argument(
        "--opt-directives",
        nargs="+",
        help="Specific opt_design directives (default: all 6)",
    )
    parser.add_argument(
        "--placer-directives",
        nargs="+",
        help="Specific placer directives (default: all 12 non-SSI)",
    )
    parser.add_argument(
        "--router-directives",
        nargs="+",
        help="Specific router directives (default: all 8-9)",
    )
    parser.add_argument(
        "--all-placer",
        action="store_true",
        help="Include all placer directives including SSI-specific",
    )
    parser.add_argument(
        "--auto-placer",
        action="store_true",
        help="Include ML-predicted Auto_1/2/3 placer directives",
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
        "--keep-all",
        action="store_true",
        help="Keep all work directories (don't clean up non-winners)",
    )
    args = parser.parse_args()

    board_name = args.board_name
    script_dir = Path(__file__).parent.resolve()
    project_root = script_dir.parent.parent

    # Determine directives for each stage
    synth_directives = args.synth_directives or ALL_SYNTH_DIRECTIVES.copy()
    opt_directives = args.opt_directives or ALL_OPT_DIRECTIVES.copy()

    if args.placer_directives:
        placer_directives = args.placer_directives
    elif args.all_placer:
        placer_directives = ALL_PLACER_DIRECTIVES.copy()
    else:
        placer_directives = NON_SSI_PLACER_DIRECTIVES.copy()
    if args.auto_placer:
        placer_directives.extend(AUTO_PLACER_DIRECTIVES)

    if args.router_directives:
        router_directives = args.router_directives
    else:
        router_directives = ALL_ROUTER_DIRECTIVES.copy()
        if board_name == "x3":
            router_directives.extend(ULTRASCALE_ROUTER_DIRECTIVES)

    # Remove duplicates while preserving order
    def dedup(lst):
        seen = set()
        return [x for x in lst if not (x in seen or seen.add(x))]

    synth_directives = dedup(synth_directives)
    opt_directives = dedup(opt_directives)
    placer_directives = dedup(placer_directives)
    router_directives = dedup(router_directives)

    print("=" * 60)
    print("FULL SWEEP BUILD")
    print("=" * 60)
    print(f"Board: {board_name}")
    print(
        f"Synthesis directives ({len(synth_directives)}): {', '.join(synth_directives)}"
    )
    print(f"Opt directives ({len(opt_directives)}): {', '.join(opt_directives)}")
    print(
        f"Placer directives ({len(placer_directives)}): {', '.join(placer_directives)}"
    )
    print(
        f"Router directives ({len(router_directives)}): {', '.join(router_directives)}"
    )
    print(f"Retiming: {'enabled' if args.retiming else 'disabled'}")

    # Get board configuration
    board_config = BOARD_CONFIG[board_name]
    clock_freq = board_config["clock_freq"]

    # Step 0: Compile hello_world
    print(f"\nCompiling hello_world for {board_name} ({clock_freq} Hz)...")
    if not compile_hello_world(project_root, clock_freq):
        print("Error: Failed to compile hello_world", file=sys.stderr)
        sys.exit(1)

    # Track winners for final summary
    winners = {}

    # Stage 1: Synthesis sweep
    synth_winner = run_synth_sweep(
        script_dir,
        board_name,
        synth_directives,
        args.retiming,
        args.vivado_path,
        args.keep_all,
    )
    if not synth_winner:
        print("Error: No successful synthesis runs!", file=sys.stderr)
        sys.exit(1)
    winners["synth"] = synth_winner

    # Stage 2: Opt sweep
    opt_winner = run_opt_sweep(
        script_dir, board_name, opt_directives, args.vivado_path, args.keep_all
    )
    if not opt_winner:
        print("Error: No successful opt_design runs!", file=sys.stderr)
        sys.exit(1)
    winners["opt"] = opt_winner

    # Stage 3: Placer sweep
    placer_winner = run_placer_sweep(
        script_dir, board_name, placer_directives, args.vivado_path, args.keep_all
    )
    if not placer_winner:
        print("Error: No successful place_design runs!", file=sys.stderr)
        sys.exit(1)
    winners["placer"] = placer_winner

    # Stage 4: Router sweep
    router_winner = run_router_sweep(
        script_dir, board_name, router_directives, args.vivado_path, args.keep_all
    )
    if not router_winner:
        print("Error: No successful route_design runs!", file=sys.stderr)
        sys.exit(1)
    winners["router"] = router_winner

    # Extract timing summaries
    extract_script = script_dir / "extract_timing_and_util_summary.py"
    subprocess.run(["python3", str(extract_script), board_name], check=True)

    # Print final summary
    print("\n" + "=" * 60)
    print("BUILD COMPLETE - FINAL SUMMARY")
    print("=" * 60)
    print(f"Winning synth directive:  {winners['synth'].directive}")
    print(f"Winning opt directive:    {winners['opt'].directive}")
    print(f"Winning placer directive: {winners['placer'].directive}")
    print(f"Winning router directive: {winners['router'].directive}")
    print()
    print("Post-route timing:")
    print(f"    WNS: {router_winner.wns_ns:.3f} ns")
    print(f"    TNS: {router_winner.tns_ns:.3f} ns")
    print(f"    Timing Met: {'Yes' if router_winner.timing_met else 'No'}")

    bitstream = script_dir / board_name / "work" / f"{board_name}_frost.bit"
    if bitstream.exists():
        print(f"\nBitstream: {bitstream}")
    else:
        print("\nWarning: Bitstream not found")


if __name__ == "__main__":
    main()
