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

"""FPGA build script with per-step directive selection.

Steps:
1. Synthesis           (post_synth.dcp)
2. Opt                 (post_opt.dcp)
3. Place               (post_place.dcp)
4. Post-place phys_opt (post_place_physopt.dcp)
5. Route               (post_route.dcp)
6. Post-route phys_opt (final.dcp)
7. Bitstream generation
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


# =============================================================================
# Configuration
# =============================================================================

BOARD_CONFIG = {
    "x3": {"clock_freq": 300000000, "is_ultrascale": True},
    "genesys2": {"clock_freq": 133333333, "is_ultrascale": False},
    "nexys_a7": {"clock_freq": 80000000, "is_ultrascale": False},
}

# Directive choices for each step
SYNTH_DIRECTIVES = [
    "Default",
    "PerformanceOptimized",
    "AreaOptimized_high",
    "AreaOptimized_medium",
    "AlternateRoutability",
    "AreaMapLargeShiftRegToBRAM",
    "AreaMultThresholdDSP",
    "FewerCarryChains",
    "LogicCompaction",
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

# Map step name to canonical report prefix (used in main work directory)
STEP_REPORT_PREFIX = {
    "synth": "post_synth",
    "opt": "post_opt",
    "place": "post_place",
    "post_place_physopt": "post_place_physopt",
    "route": "post_route",
    "post_route_physopt": "final",
}

# Map step name to the report prefix the TCL script actually produces
_TCL_REPORT_PREFIX = {
    "synth": "post_synth",
    "opt": "post_opt",
    "place": "post_place",
    "post_place_physopt": "phys_opt",
    "route": "post_route",
    "post_route_physopt": "phys_opt",
}


# =============================================================================
# Utility Functions
# =============================================================================


def extract_timing_from_report(timing_rpt_path: Path) -> dict:
    """Extract WNS, TNS, WHS, THS and failing endpoint counts from timing report."""
    result = {}

    if not timing_rpt_path.exists():
        return result

    timing_rpt = timing_rpt_path.read_text()

    # Find the Design Timing Summary table
    # Columns: WNS TNS TNS_Failing TNS_Total WHS THS THS_Failing THS_Total
    pattern = r"WNS\(ns\)\s+TNS\(ns\).*?\n\s*-+\s*-+.*?\n\s*([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)"
    match = re.search(pattern, timing_rpt)
    if match:
        result["wns_ns"] = float(match.group(1))
        result["tns_ns"] = float(match.group(2))
        result["failing_endpoints"] = int(match.group(3))
        result["total_endpoints"] = int(match.group(4))
        result["whs_ns"] = float(match.group(5))
        result["ths_ns"] = float(match.group(6))

    return result


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


def copy_results_to_main_work(
    work_dir: Path,
    main_work: Path,
    step: str,
) -> None:
    """Copy checkpoint and reports from step work dir to main work directory."""
    report_prefix = STEP_REPORT_PREFIX[step]
    checkpoint_name = STEP_PRODUCES_CHECKPOINT[step]

    # Copy checkpoint (rename to standard name)
    for dcp in work_dir.glob("*.dcp"):
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
        for rpt in work_dir.glob(f"*{suffix}"):
            dst = main_work / f"{report_prefix}{suffix}"
            shutil.copy2(rpt, dst)
            break

    # Copy vivado.log
    vivado_log = work_dir / "vivado.log"
    if vivado_log.exists():
        dst = main_work / f"{report_prefix}_vivado.log"
        shutil.copy2(vivado_log, dst)


# =============================================================================
# Step Execution
# =============================================================================


def run_step(
    script_dir: Path,
    board_name: str,
    step: str,
    directive: str,
    vivado_path: str,
    retiming: bool = False,
    keep_temps: bool = False,
) -> bool:
    """Run a single build step with the given directive.

    Returns True on success, False on failure.
    """
    main_work = script_dir / board_name / "work"
    main_work.mkdir(parents=True, exist_ok=True)

    # Check input checkpoint
    required_checkpoint = STEP_REQUIRES_CHECKPOINT[step]
    if required_checkpoint:
        input_checkpoint = main_work / required_checkpoint
        if not input_checkpoint.exists():
            print(f"Error: Required checkpoint not found: {input_checkpoint}")
            return False
    else:
        input_checkpoint = None

    tcl_report_prefix = _TCL_REPORT_PREFIX[step]
    work_dir = script_dir / board_name / f"work_{step}_{directive}"
    work_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*70}")
    print(f"STEP: {step.upper()} — Directive: {directive}")
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
        step,
        directive,
        str(input_checkpoint) if input_checkpoint else "",
        "1" if retiming else "0",
    ]

    result = subprocess.run(vivado_command, cwd=work_dir)

    if result.returncode != 0:
        print(f"\n  [FAIL] {step} / {directive} (exit code {result.returncode})")
        return False

    # Extract timing
    timing_rpt = work_dir / f"{tcl_report_prefix}_timing.rpt"
    timing = extract_timing_from_report(timing_rpt)
    wns = timing.get("wns_ns")

    if wns is not None:
        tns = timing.get("tns_ns")
        failing = timing.get("failing_endpoints", 0)
        total = timing.get("total_endpoints", 0)
        met = "TIMING MET" if wns >= 0 else f"WNS: {wns:.3f} ns"
        print(f"\n  [DONE] {step} / {directive} ({met})")
        print(
            f"  WNS: {wns:.3f} ns | TNS: {tns:.3f} ns | Failing endpoints: {failing}/{total}"
        )
    else:
        print(f"\n  [DONE] {step} / {directive} (no timing data)")

    # Copy results to main work directory
    copy_results_to_main_work(work_dir, main_work, step)

    # Clean up temp directory
    if not keep_temps:
        shutil.rmtree(work_dir)

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
    """Run FPGA build."""
    parser = argparse.ArgumentParser(
        description="FROST FPGA build script",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Steps (in order):
  synth              - Synthesis
  opt                - Opt design
  place              - Place design
  post_place_physopt - Post-place phys_opt
  route              - Route design
  post_route_physopt - Post-route phys_opt

Each step uses the "Default" directive unless overridden with --*-directive.

Examples:
  ./build.py x3                           # Full build, Default directives
  ./build.py x3 --start-at place          # Resume from post_opt checkpoint
  ./build.py x3 --stop-after synth        # Synth only
  ./build.py x3 --synth-directive PerformanceOptimized  # Specific synth directive
  ./build.py x3 --synth-directive PerformanceOptimized --stop-after synth
  ./build.py x3 --start-at route --route-directive AggressiveExplore
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
        "--synth-directive",
        choices=SYNTH_DIRECTIVES,
        default="PerformanceOptimized",
        help="Synthesis directive (default: PerformanceOptimized)",
    )
    parser.add_argument(
        "--opt-directive",
        choices=OPT_DIRECTIVES,
        default="Explore",
        help="Opt directive (default: Explore)",
    )
    parser.add_argument(
        "--place-directive",
        choices=PLACER_DIRECTIVES,
        default="ExtraTimingOpt",
        help="Placer directive (default: ExtraTimingOpt)",
    )
    parser.add_argument(
        "--route-directive",
        choices=ROUTER_DIRECTIVES + ULTRASCALE_ROUTER_DIRECTIVES,
        default="AggressiveExplore",
        help="Router directive (default: AggressiveExplore)",
    )
    parser.add_argument(
        "--physopt-directive",
        choices=PHYS_OPT_DIRECTIVES,
        default="AggressiveExplore",
        help="Phys_opt directive for both post-place and post-route (default: AggressiveExplore)",
    )
    args = parser.parse_args()

    board_name = args.board_name
    script_dir = Path(__file__).parent.resolve()
    project_root = script_dir.parent.parent

    # Get board configuration
    board_config = BOARD_CONFIG[board_name]
    clock_freq = board_config["clock_freq"]
    is_ultrascale = board_config["is_ultrascale"]

    # Per-step directives
    step_directives = {
        "synth": args.synth_directive,
        "opt": args.opt_directive,
        "place": args.place_directive,
        "post_place_physopt": args.physopt_directive,
        "route": args.route_directive,
        "post_route_physopt": args.physopt_directive,
    }

    print(f"\n{'#'*70}")
    print(f"# FROST FPGA Build — {board_name.upper()}")
    print(f"# Clock: {clock_freq:,} Hz")
    print(f"# UltraScale: {'Yes' if is_ultrascale else 'No'}")
    directives_summary = [
        f"{s}={d}" for s, d in step_directives.items() if d != "Default"
    ]
    if directives_summary:
        print(f"# Directives: {', '.join(directives_summary)}")
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

    # Run steps
    for step in steps_to_run:
        directive = step_directives[step]
        retiming = args.retiming if step == "synth" else False

        if not run_step(
            script_dir,
            board_name,
            step,
            directive,
            args.vivado_path,
            retiming=retiming,
            keep_temps=args.keep_temps,
        ):
            print(f"\nError: Step '{step}' failed!")
            sys.exit(1)

    # Generate bitstream if we completed post_route_physopt
    if "post_route_physopt" in steps_to_run:
        if not generate_bitstream(script_dir, board_name, args.vivado_path):
            sys.exit(1)

    # Update README.md utilization tables
    from extract_timing_and_util_summary import (
        collect_all_board_utilization,
        update_readme_utilization,
    )

    all_util = collect_all_board_utilization(script_dir)
    if all_util:
        update_readme_utilization(script_dir, all_util)

    # Final summary
    last_prefix = STEP_REPORT_PREFIX[steps_to_run[-1]]
    print(f"\n{'#'*70}")
    print("# BUILD COMPLETE!")
    print(f"{'#'*70}")

    last_timing_rpt = main_work / f"{last_prefix}_timing.rpt"
    if last_timing_rpt.exists():
        timing = extract_timing_from_report(last_timing_rpt)
        if timing.get("wns_ns") is not None:
            failing = timing.get("failing_endpoints", 0)
            total = timing.get("total_endpoints", 0)
            print(f"\nTiming (after {last_prefix}):")
            print(f"  WNS: {timing['wns_ns']:.3f} ns")
            print(f"  TNS: {timing['tns_ns']:.3f} ns")
            print(f"  Failing endpoints: {failing}/{total}")
            print(f"  Timing Met: {'YES!' if timing['wns_ns'] >= 0 else 'No'}")

    bitstream = main_work / f"{board_name}_frost.bit"
    if bitstream.exists():
        print(f"\nBitstream: {bitstream}")


if __name__ == "__main__":
    main()
