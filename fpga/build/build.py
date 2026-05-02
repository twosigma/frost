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
1. Synthesis                          (post_synth.dcp)
2. Opt                                (post_opt.dcp)
3. Place                              (post_place.dcp)
4. Post-place phys_opt sweep          (post_place_physopt.dcp)
5. Route (with -tns_cleanup)          (post_route.dcp / final.dcp*)
6. Post-route phys_opt sweep          (post_route_physopt.dcp / final.dcp*)
7. Second route (no -tns_cleanup)     (post_second_route.dcp / final.dcp*)
8. Post-second-route phys_opt sweep   (final.dcp)
9. Bitstream generation

All three phys_opt stages (4, 6, 8) run a hardcoded sweep over every directive
in PHYS_OPT_DIRECTIVES, starting with AggressiveExplore. Each sweep preserves
the best-WNS pass and stops early as soon as a phys_opt_design pass closes
timing (WNS>=0).

* Pipeline early-exit: at steps 5/6/7 (FINAL_ELIGIBLE_STEPS), if WNS>=0 the
  outputs are promoted to final.dcp/final_*.rpt and remaining stages are
  skipped, jumping straight to bitstream. Step 4 does not skip ahead — its
  closure is under the x3 overconstraint, and we always still want the
  unconstrained route to run. Step 8 is the last possible step and always
  writes final.dcp.
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
STEPS = [
    "synth",
    "opt",
    "place",
    "post_place_physopt",
    "route",
    "post_route_physopt",
    "second_route",
    "post_second_route_physopt",
]

# Map step name to checkpoint that must exist to start at that step
STEP_REQUIRES_CHECKPOINT = {
    "synth": None,
    "opt": "post_synth.dcp",
    "place": "post_opt.dcp",
    "post_place_physopt": "post_place.dcp",
    "route": "post_place_physopt.dcp",
    "post_route_physopt": "post_route.dcp",
    "second_route": "post_route_physopt.dcp",
    "post_second_route_physopt": "post_second_route.dcp",
}

# Map step name to checkpoint produced after that step. Only the final stage
# (post_second_route_physopt) produces final.dcp; earlier stages produce
# intermediate step-named checkpoints.
STEP_PRODUCES_CHECKPOINT = {
    "synth": "post_synth.dcp",
    "opt": "post_opt.dcp",
    "place": "post_place.dcp",
    "post_place_physopt": "post_place_physopt.dcp",
    "route": "post_route.dcp",
    "post_route_physopt": "post_route_physopt.dcp",
    "second_route": "post_second_route.dcp",
    "post_second_route_physopt": "final.dcp",
}

# Map step name to canonical report prefix (used in main work directory)
STEP_REPORT_PREFIX = {
    "synth": "post_synth",
    "opt": "post_opt",
    "place": "post_place",
    "post_place_physopt": "post_place_physopt",
    "route": "post_route",
    "post_route_physopt": "post_route_physopt",
    "second_route": "post_second_route",
    "post_second_route_physopt": "final",
}

# Map step name to the report prefix the TCL script actually produces
_TCL_REPORT_PREFIX = {
    "synth": "post_synth",
    "opt": "post_opt",
    "place": "post_place",
    "post_place_physopt": "phys_opt",
    "route": "post_route",
    "post_route_physopt": "phys_opt",
    "second_route": "post_second_route",
    "post_second_route_physopt": "phys_opt",
}

# Steps where successful timing closure (WNS>=0) promotes outputs to "final.*"
# naming and short-circuits subsequent passes (jumping straight to bitstream).
# post_second_route_physopt is excluded because it's the last step and always
# writes final.* statically; post_place_physopt is excluded because closure
# during its sweep is under x3 overconstraint and we always still want the
# unconstrained route step to run.
FINAL_ELIGIBLE_STEPS = {"route", "post_route_physopt", "second_route"}


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
    checkpoint_name: str,
    report_prefix: str,
) -> None:
    """Copy checkpoint and reports from step work dir to main work directory."""
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
) -> tuple[bool, float | None, str]:
    """Run a single build step with the given directive.

    Returns (success, wns_ns, actual_report_prefix). actual_report_prefix is
    "final" when the step's outputs were promoted to final.dcp/final_*.rpt
    (final-eligible step + WNS>=0, or post_second_route_physopt unconditionally),
    otherwise the step's non-final canonical prefix.
    """
    main_work = script_dir / board_name / "work"
    main_work.mkdir(parents=True, exist_ok=True)

    # Check input checkpoint
    required_checkpoint = STEP_REQUIRES_CHECKPOINT[step]
    if required_checkpoint:
        input_checkpoint = main_work / required_checkpoint
        if not input_checkpoint.exists():
            print(f"Error: Required checkpoint not found: {input_checkpoint}")
            return False, None, ""
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
        return False, None, ""

    # Extract timing
    timing_rpt = work_dir / f"{tcl_report_prefix}_timing.rpt"
    timing = extract_timing_from_report(timing_rpt)
    wns = timing.get("wns_ns")
    timing_met = wns is not None and wns >= 0

    # Decide canonical output names. Final-eligible steps get promoted to
    # final.* when timing closes; post_second_route_physopt's static entry is
    # already final.* (last possible step).
    if step in FINAL_ELIGIBLE_STEPS and timing_met:
        checkpoint_name = "final.dcp"
        report_prefix = "final"
    else:
        checkpoint_name = STEP_PRODUCES_CHECKPOINT[step]
        report_prefix = STEP_REPORT_PREFIX[step]

    if wns is not None:
        tns = timing.get("tns_ns")
        failing = timing.get("failing_endpoints", 0)
        total = timing.get("total_endpoints", 0)
        met = "TIMING MET" if timing_met else f"WNS: {wns:.3f} ns"
        print(f"\n  [DONE] {step} / {directive} ({met})")
        print(
            f"  WNS: {wns:.3f} ns | TNS: {tns:.3f} ns | Failing endpoints: {failing}/{total}"
        )
    else:
        print(f"\n  [DONE] {step} / {directive} (no timing data)")

    print(f"  Output: {checkpoint_name} + {report_prefix}_*.rpt")

    # Copy results to main work directory
    copy_results_to_main_work(work_dir, main_work, checkpoint_name, report_prefix)

    # Clean up temp directory
    if not keep_temps:
        shutil.rmtree(work_dir)

    return True, wns, report_prefix


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
  synth                       - Synthesis
  opt                         - Opt design
  place                       - Place design
  post_place_physopt          - Phys_opt sweep (always continues to route, even
                                if timing closes mid-sweep under overconstraint)
  route                       - Route design (with -tns_cleanup)
  post_route_physopt          - Phys_opt sweep over every directive (serial)
  second_route                - Route design (without -tns_cleanup)
  post_second_route_physopt   - Phys_opt sweep over every directive (serial);
                                always writes final.dcp + final_*.rpt + bitstream

Behavior:
  * All phys_opt stages run a hardcoded sweep, starting with AggressiveExplore.
    Each sweep preserves the best-WNS pass and stops early if a directive closes
    timing (WNS>=0).
  * Pipeline early-exit at route, post_route_physopt, or second_route: when
    one of these closes timing, its outputs are promoted to final.dcp/final_*
    and remaining stages are skipped — bitstream runs next.

Each step uses a tuned default directive unless overridden with --*-directive.
--route-directive applies to both route and second_route.
--physopt-directive is currently ignored (kept for backward compatibility).

Examples:
  ./build.py x3                                    # Full build, tuned defaults
  ./build.py x3 --start-at place                   # Resume from post_opt checkpoint
  ./build.py x3 --stop-after synth                 # Synth only
  ./build.py x3 --synth-directive PerformanceOptimized
  ./build.py x3 --start-at route --route-directive AggressiveExplore
  ./build.py x3 --start-at second_route            # Requires post_route_physopt.dcp
""",
    )
    parser.add_argument(
        "board_name",
        nargs="?",
        default="x3",
        choices=["x3", "genesys2"],
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
        default=None,
        help="Placer directive (default: ExtraNetDelay_high on x3, "
        "ExtraTimingOpt otherwise)",
    )
    parser.add_argument(
        "--route-directive",
        choices=ROUTER_DIRECTIVES + ULTRASCALE_ROUTER_DIRECTIVES,
        default="AggressiveExplore",
        help="Router directive — used for both route (with -tns_cleanup) and "
        "second_route (without) (default: AggressiveExplore)",
    )
    parser.add_argument(
        "--physopt-directive",
        choices=PHYS_OPT_DIRECTIVES,
        default="AggressiveExplore",
        help="Currently ignored — all phys_opt stages (post_place, post_route, "
        "post_second_route) run a hardcoded sweep over every directive. Kept "
        "for backward compatibility.",
    )
    args = parser.parse_args()

    board_name = args.board_name
    script_dir = Path(__file__).parent.resolve()
    project_root = script_dir.parent.parent

    # Get board configuration
    board_config = BOARD_CONFIG[board_name]
    clock_freq = board_config["clock_freq"]
    is_ultrascale = board_config["is_ultrascale"]
    place_directive = args.place_directive
    if place_directive is None:
        place_directive = (
            "ExtraNetDelay_high" if board_name == "x3" else "ExtraTimingOpt"
        )

    # Per-step directives. The three phys_opt stages all run hardcoded sweeps
    # in the TCL and ignore the directive arg; we pass "Sweep" as a sentinel
    # so banners and the temp work dir name make this obvious.
    step_directives = {
        "synth": args.synth_directive,
        "opt": args.opt_directive,
        "place": place_directive,
        "post_place_physopt": "Sweep",
        "route": args.route_directive,
        "post_route_physopt": "Sweep",
        "second_route": args.route_directive,
        "post_second_route_physopt": "Sweep",
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
    final_produced = False
    last_report_prefix = None
    for step in steps_to_run:
        directive = step_directives[step]
        retiming = args.retiming if step == "synth" else False

        success, wns, actual_prefix = run_step(
            script_dir,
            board_name,
            step,
            directive,
            args.vivado_path,
            retiming=retiming,
            keep_temps=args.keep_temps,
        )
        if not success:
            print(f"\nError: Step '{step}' failed!")
            sys.exit(1)

        last_report_prefix = actual_prefix
        if actual_prefix == "final":
            final_produced = True

        # Pipeline early-exit: timing closure at any route or post-route
        # phys_opt step short-circuits the remaining stages and goes straight
        # to bitstream. post_second_route_physopt always finalizes naturally.
        if step in FINAL_ELIGIBLE_STEPS and wns is not None and wns >= 0:
            remaining = steps_to_run[steps_to_run.index(step) + 1 :]
            if remaining:
                print(
                    f"\nTiming met at {step} — skipping subsequent stages: "
                    f"{', '.join(remaining)}"
                )
            break

    # Generate bitstream whenever this run produced final.dcp
    if final_produced:
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

    # Final summary — read from whichever prefix the last completed step wrote
    print(f"\n{'#'*70}")
    print("# BUILD COMPLETE!")
    print(f"{'#'*70}")

    if last_report_prefix:
        last_timing_rpt = main_work / f"{last_report_prefix}_timing.rpt"
        if last_timing_rpt.exists():
            timing = extract_timing_from_report(last_timing_rpt)
            if timing.get("wns_ns") is not None:
                failing = timing.get("failing_endpoints", 0)
                total = timing.get("total_endpoints", 0)
                print(f"\nTiming (after {last_report_prefix}):")
                print(f"  WNS: {timing['wns_ns']:.3f} ns")
                print(f"  TNS: {timing['tns_ns']:.3f} ns")
                print(f"  Failing endpoints: {failing}/{total}")
                print(f"  Timing Met: {'YES!' if timing['wns_ns'] >= 0 else 'No'}")

    bitstream = main_work / f"{board_name}_frost.bit"
    if bitstream.exists():
        print(f"\nBitstream: {bitstream}")


if __name__ == "__main__":
    main()
