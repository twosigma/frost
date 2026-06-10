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
3. Place                              (post_place.dcp; x3 sweeps placer directives)
4. Post-place phys_opt sweep          (post_place_physopt.dcp)
5. Route (with -tns_cleanup)          (post_route.dcp / final.dcp*)
6. Post-route phys_opt sweep          (post_route_physopt.dcp / final.dcp*)
7. Second route (no -tns_cleanup)     (post_second_route.dcp / final.dcp*)
8. Post-second-route phys_opt sweep   (final.dcp)
9. Bitstream generation

All three phys_opt stages (4, 6, 8) run a hardcoded sweep over every directive
in PHYS_OPT_DIRECTIVES, starting with AggressiveExplore, followed by one
retime-only pass (phys_opt_design -retime). Each sweep preserves the best-WNS
pass and stops early as soon as a phys_opt_design pass closes timing (WNS>=0).
Repeated phys_opt sweeps write the current best checkpoint and reports after
every completed sweep iteration.

For x3, the place, route, and second_route stages run every legal directive in
parallel, wait for all jobs to finish, then promote only the best-WNS checkpoint
and reports to the main work directory before continuing.

* Pipeline early-exit: at steps 5/6/7 (FINAL_ELIGIBLE_STEPS), if WNS>=0 the
  outputs are promoted to final.dcp/final_*.rpt and remaining stages are
  skipped, jumping straight to bitstream. Step 4 does not skip ahead — its
  closure is under the x3 overconstraint, and we always still want the
  unconstrained route to run. Step 8 is the last possible step and always
  writes final.dcp.
"""

import argparse
from dataclasses import dataclass
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import TextIO, TypedDict


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
    "EarlyBlockPlacement",
    "WLDrivenBlockPlacement",
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

ROUTER_SWEEP_DIRECTIVES = ROUTER_DIRECTIVES + ULTRASCALE_ROUTER_DIRECTIVES

PHYS_OPT_DIRECTIVES = [
    "Default",
    "Explore",
    "ExploreWithHoldFix",
    "AggressiveExplore",
    "AlternateReplication",
    "AggressiveFanoutOpt",
    "AlternateFlowWithRetiming",
    "RuntimeOptimized",
    "ExploreWithAggressiveHoldFix",
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


class TimingSummary(TypedDict, total=False):
    """Parsed setup/hold timing summary fields from a Vivado timing report."""

    wns_ns: float
    tns_ns: float
    failing_endpoints: int
    total_endpoints: int
    whs_ns: float
    ths_ns: float


@dataclass
class DirectiveSweepRun:
    """Runtime state for one Vivado directive sweep subprocess."""

    directive: str
    work_dir: Path
    stdout_path: Path
    process: subprocess.Popen[bytes] | None = None
    stdout_handle: TextIO | None = None
    start_time: float | None = None
    returncode: int | None = None
    elapsed_s: float | None = None
    wns: float | None = None
    tns: float | None = None
    failing_endpoints: int | None = None
    total_endpoints: int | None = None
    launch_error: str | None = None


def extract_timing_from_report(timing_rpt_path: Path) -> TimingSummary:
    """Extract WNS, TNS, WHS, THS and failing endpoint counts from timing report."""
    result: TimingSummary = {}

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


def compile_hello_world(project_root: Path, output_dir: Path, clock_freq: int) -> bool:
    """Compile hello_world application for initial BRAM contents."""
    app_dir = project_root / "sw" / "apps" / "hello_world"

    if not app_dir.exists():
        print(f"Error: Application directory not found: {app_dir}", file=sys.stderr)
        return False

    # Keep board builds isolated; Vivado reads these files during synthesis.
    output_dir.mkdir(parents=True, exist_ok=True)

    outputs = {
        "EXECUTABLE_ELF_FILE": output_dir / "sw.elf",
        "VERILOG_HEX_FILE": output_dir / "sw.mem",
        "RAW_BINARY_FILE": output_dir / "sw.bin",
        "VIVADO_BRAM_FILE": output_dir / "sw.txt",
        "DISASSEMBLY_FILE": output_dir / "sw.S",
        "IMEM_EVEN_INIT_FILE": output_dir / "sw_imem_even.mem",
        "IMEM_ODD_INIT_FILE": output_dir / "sw_imem_odd.mem",
        "IMEM_EVEN_SIDEBAND_FILE": output_dir / "sw_imem_even_sideband.mem",
        "IMEM_ODD_SIDEBAND_FILE": output_dir / "sw_imem_odd_sideband.mem",
    }

    for output_path in outputs.values():
        output_path.unlink(missing_ok=True)

    env = os.environ.copy()
    if "RISCV_PREFIX" not in env:
        env["RISCV_PREFIX"] = "riscv-none-elf-"
    env["FPGA_CPU_CLK_FREQ"] = str(clock_freq)

    try:
        print(f"Compiling hello_world with FPGA_CPU_CLK_FREQ={clock_freq}...")
        make_args = [
            "make",
            f"FPGA_CPU_CLK_FREQ={clock_freq}",
            *[f"{name}={path}" for name, path in outputs.items()],
        ]
        result = subprocess.run(
            make_args,
            cwd=app_dir,
            env=env,
            capture_output=False,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            return False

        for output_path in outputs.values():
            if not output_path.exists():
                print(
                    f"Error: {output_path.name} not created for hello_world",
                    file=sys.stderr,
                )
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
    source_report_prefix: str | None = None,
) -> None:
    """Copy checkpoint and reports from step work dir to main work directory."""
    # Copy checkpoint (rename to standard name)
    checkpoint_candidates = []
    if source_report_prefix:
        checkpoint_candidates.append(work_dir / f"{source_report_prefix}.dcp")
    checkpoint_candidates.append(work_dir / checkpoint_name)
    checkpoint_candidates.extend(sorted(work_dir.glob("*.dcp")))
    seen_checkpoints = set()
    for dcp in checkpoint_candidates:
        if dcp in seen_checkpoints:
            continue
        seen_checkpoints.add(dcp)
        if not dcp.exists() or dcp.name.endswith("_best.dcp"):
            continue
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
        report_candidates = []
        if source_report_prefix:
            report_candidates.append(work_dir / f"{source_report_prefix}{suffix}")
        report_candidates.append(work_dir / f"{report_prefix}{suffix}")
        report_candidates.extend(sorted(work_dir.glob(f"*{suffix}")))
        seen_reports = set()
        for rpt in report_candidates:
            if rpt in seen_reports:
                continue
            seen_reports.add(rpt)
            if not rpt.exists():
                continue
            dst = main_work / f"{report_prefix}{suffix}"
            shutil.copy2(rpt, dst)
            break

    # Copy vivado.log
    vivado_log = work_dir / "vivado.log"
    if vivado_log.exists():
        dst = main_work / f"{report_prefix}_vivado.log"
        shutil.copy2(vivado_log, dst)


def format_sweep_ns(value: float | None) -> str:
    """Format a timing value for compact sweep result tables."""
    return "N/A" if value is None else f"{value:.3f}"


def format_sweep_elapsed(seconds: float | None) -> str:
    """Format elapsed seconds for compact sweep result tables."""
    if seconds is None:
        return "N/A"
    seconds_i = int(round(seconds))
    minutes, sec = divmod(seconds_i, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours:d}h{minutes:02d}m"
    if minutes:
        return f"{minutes:d}m{sec:02d}s"
    return f"{sec:d}s"


def print_x3_directive_sweep_matrix(
    runs: list[DirectiveSweepRun],
    best_run: DirectiveSweepRun | None,
    title: str,
) -> None:
    """Print a compact matrix of x3 directive sweep results."""
    print(f"\n{title}:")
    print(
        f"{'Sel':<3} {'Directive':<28} {'Status':<10} "
        f"{'WNS(ns)':>9} {'TNS(ns)':>11} {'Failing EP':>14} {'Elapsed':>8}"
    )
    print("-" * 91)

    for run in runs:
        if run.launch_error:
            status = "LAUNCH"
        elif run.returncode is None:
            status = "UNKNOWN"
        elif run.returncode != 0:
            status = f"FAIL {run.returncode}"
        elif run.wns is None:
            status = "NO WNS"
        else:
            status = "OK"

        failing = "N/A"
        if run.failing_endpoints is not None and run.total_endpoints is not None:
            failing = f"{run.failing_endpoints}/{run.total_endpoints}"

        selected = "*" if best_run is run else ""
        print(
            f"{selected:<3} {run.directive:<28} {status:<10} "
            f"{format_sweep_ns(run.wns):>9} "
            f"{format_sweep_ns(run.tns):>11} "
            f"{failing:>14} "
            f"{format_sweep_elapsed(run.elapsed_s):>8}"
        )


def close_directive_sweep_logs(runs: list[DirectiveSweepRun]) -> None:
    """Close any log handles left open by active sweep processes."""
    for run in runs:
        if run.stdout_handle is not None:
            run.stdout_handle.close()
            run.stdout_handle = None


def terminate_x3_directive_sweep_runs(
    runs: list[DirectiveSweepRun],
    description: str,
) -> None:
    """Terminate active x3 Vivado process groups for a directive sweep."""
    active_runs = [
        run for run in runs if run.process is not None and run.process.poll() is None
    ]
    if not active_runs:
        close_directive_sweep_logs(runs)
        return

    print(f"\nTerminating active x3 {description} Vivado runs...")
    for run in active_runs:
        process = run.process
        if process is None:
            continue
        print(f"  SIGTERM {run.directive:<28} pid={process.pid}")
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except OSError as e:
            print(f"  Warning: failed to terminate {run.directive}: {e}")

    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        if all(
            run.process is None or run.process.poll() is not None for run in active_runs
        ):
            break
        time.sleep(0.5)

    still_running = [
        run
        for run in active_runs
        if run.process is not None and run.process.poll() is None
    ]
    if still_running:
        print(f"Forcing remaining x3 {description} Vivado runs down...")
        for run in still_running:
            process = run.process
            if process is None:
                continue
            print(f"  SIGKILL {run.directive:<28} pid={process.pid}")
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError as e:
                print(f"  Warning: failed to kill {run.directive}: {e}")

    for run in runs:
        process = run.process
        if process is None:
            continue
        try:
            run.returncode = process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            run.returncode = process.poll()
        if run.start_time is not None and run.elapsed_s is None:
            run.elapsed_s = time.monotonic() - run.start_time

    close_directive_sweep_logs(runs)


def run_x3_step_directive_sweep(
    script_dir: Path,
    step: str,
    directives: list[str],
    sweep_kind: str,
    vivado_path: str,
    keep_temps: bool = False,
) -> tuple[bool, float | None, str]:
    """Run every x3 directive in parallel and promote the best-WNS run."""
    board_name = "x3"
    tcl_report_prefix = _TCL_REPORT_PREFIX[step]
    main_work = script_dir / board_name / "work"
    main_work.mkdir(parents=True, exist_ok=True)

    required_checkpoint = STEP_REQUIRES_CHECKPOINT[step]
    if required_checkpoint is None:
        print(f"Error: x3 {step} sweep requires an input checkpoint")
        return False, None, ""
    input_checkpoint = main_work / required_checkpoint
    if not input_checkpoint.exists():
        print(f"Error: Required checkpoint not found: {input_checkpoint}")
        return False, None, ""

    route_note = ""
    if step == "route":
        route_note = " (with -tns_cleanup)"
    elif step == "second_route":
        route_note = " (without -tns_cleanup)"

    print(f"\n{'='*70}")
    print(f"STEP: {step.upper()} - X3 {sweep_kind} directive sweep{route_note}")
    print(f"{'='*70}\n")
    print(f"Launching {sweep_kind} directives in parallel:")

    runs: list[DirectiveSweepRun] = []
    try:
        for directive in directives:
            work_dir = script_dir / board_name / f"work_{step}_{directive}"
            if work_dir.exists():
                shutil.rmtree(work_dir)
            work_dir.mkdir(parents=True, exist_ok=True)

            stdout_path = work_dir / "build_step_stdout.log"
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
                str(input_checkpoint),
                "0",
            ]

            run = DirectiveSweepRun(
                directive=directive,
                work_dir=work_dir,
                stdout_path=stdout_path,
            )
            runs.append(run)

            stdout_handle = None
            try:
                stdout_handle = stdout_path.open("w")
                process = subprocess.Popen(
                    vivado_command,
                    cwd=work_dir,
                    stdout=stdout_handle,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                run.process = process
                run.stdout_handle = stdout_handle
                run.start_time = time.monotonic()
                print(
                    f"  {directive:<28} pid={process.pid:<8} "
                    f"log={work_dir / 'vivado.log'}"
                )
            except OSError as e:
                if stdout_handle is not None:
                    stdout_handle.close()
                run.returncode = -1
                run.elapsed_s = 0.0
                run.launch_error = str(e)
                print(f"  {directive:<28} launch failed: {e}")

        pending = {idx for idx, run in enumerate(runs) if run.process is not None}
        while pending:
            for idx in list(pending):
                run = runs[idx]
                running_process = run.process
                if running_process is None:
                    pending.remove(idx)
                    continue
                returncode = running_process.poll()
                if returncode is None:
                    continue

                run.returncode = returncode
                if run.start_time is not None:
                    run.elapsed_s = time.monotonic() - run.start_time
                if run.stdout_handle is not None:
                    run.stdout_handle.close()
                    run.stdout_handle = None

                timing_rpt = run.work_dir / f"{tcl_report_prefix}_timing.rpt"
                if returncode == 0:
                    timing = extract_timing_from_report(timing_rpt)
                    run.wns = timing.get("wns_ns")
                    run.tns = timing.get("tns_ns")
                    run.failing_endpoints = timing.get("failing_endpoints")
                    run.total_endpoints = timing.get("total_endpoints")

                    if run.wns is None:
                        result = "completed without timing data"
                    else:
                        result = (
                            f"WNS={format_sweep_ns(run.wns)} ns, "
                            f"TNS={format_sweep_ns(run.tns)} ns"
                        )
                else:
                    result = f"failed with exit code {returncode}"

                print(
                    f"  Finished {run.directive:<28} {result} "
                    f"({format_sweep_elapsed(run.elapsed_s)})"
                )
                pending.remove(idx)

            if pending:
                time.sleep(5)
    except KeyboardInterrupt:
        terminate_x3_directive_sweep_runs(runs, f"{sweep_kind} sweep")
        print(f"Interrupted; x3 {sweep_kind} sweep stopped.")
        raise SystemExit(130)

    eligible_runs = [run for run in runs if run.returncode == 0 and run.wns is not None]
    best_run = None
    if eligible_runs:
        best_run = max(
            eligible_runs,
            key=lambda run: (
                run.wns if run.wns is not None else float("-inf"),
                run.tns if run.tns is not None else float("-inf"),
            ),
        )

    print_x3_directive_sweep_matrix(
        runs,
        best_run,
        f"X3 {step} {sweep_kind} directive sweep results",
    )

    if best_run is None:
        print(f"\nError: No x3 {sweep_kind} directive completed with usable WNS data")
        print(f"Leaving {sweep_kind} work directories in place for debugging.")
        return False, None, ""

    timing_met = best_run.wns is not None and best_run.wns >= 0
    if step in FINAL_ELIGIBLE_STEPS and timing_met:
        checkpoint_name = "final.dcp"
        report_prefix = "final"
    else:
        checkpoint_name = STEP_PRODUCES_CHECKPOINT[step]
        report_prefix = STEP_REPORT_PREFIX[step]

    print(
        f"\nSelected x3 {sweep_kind} directive for {step}: {best_run.directive} "
        f"(WNS={format_sweep_ns(best_run.wns)} ns, "
        f"TNS={format_sweep_ns(best_run.tns)} ns)"
    )
    print(f"  Output: {checkpoint_name} + {report_prefix}_*.rpt")

    copy_results_to_main_work(
        best_run.work_dir,
        main_work,
        checkpoint_name,
        report_prefix,
        source_report_prefix=tcl_report_prefix,
    )

    promoted_checkpoint = main_work / checkpoint_name
    promoted_timing = main_work / f"{report_prefix}_timing.rpt"
    if not promoted_checkpoint.exists() or not promoted_timing.exists():
        print(
            f"Error: Selected {sweep_kind} run did not produce the expected "
            f"{checkpoint_name}/{report_prefix}_timing.rpt outputs"
        )
        return False, None, ""

    failed_runs = [run for run in runs if run.returncode not in (0, None)]
    failed_run_ids = {id(run) for run in failed_runs}
    if keep_temps:
        print(f"Keeping x3 {sweep_kind} sweep work directories.")
    else:
        for run in runs:
            if id(run) in failed_run_ids:
                continue
            shutil.rmtree(run.work_dir)
        if failed_runs:
            print(f"\nFailed {sweep_kind} work directories were left for debugging:")
            for run in failed_runs:
                print(f"  {run.directive}: {run.work_dir}")

    return True, best_run.wns, report_prefix


# =============================================================================
# Step Execution
# =============================================================================


def run_step(
    script_dir: Path,
    board_name: str,
    step: str,
    directive: str,
    vivado_path: str,
    software_mem_dir: Path | None = None,
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
    if software_mem_dir is not None:
        vivado_command.append(str(software_mem_dir))

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
    copy_results_to_main_work(
        work_dir,
        main_work,
        checkpoint_name,
        report_prefix,
        source_report_prefix=tcl_report_prefix,
    )

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
  place                       - Place design (x3 sweeps all placer directives in
                                parallel and keeps the best-WNS result)
  post_place_physopt          - Phys_opt sweep (always continues to route, even
                                if timing closes mid-sweep under overconstraint)
  route                       - Route design (with -tns_cleanup; x3 sweeps all
                                router directives in parallel and keeps the
                                best-WNS result)
  post_route_physopt          - Phys_opt directive sweep plus retime pass (serial)
  second_route                - Route design (without -tns_cleanup; x3 sweeps
                                all router directives in parallel and keeps the
                                best-WNS result)
  post_second_route_physopt   - Phys_opt directive sweep plus retime pass (serial);
                                always writes final.dcp + final_*.rpt + bitstream

Behavior:
  * On x3, place ignores --place-directive and runs every placer directive in
    parallel, promotes only the best-WNS post_place checkpoint/reports, then
    continues to post_place_physopt.
  * On x3, route and second_route ignore --route-directive and
    --second-route-directive, respectively. Each runs every router directive,
    including AlternateCLBRouting, in parallel and promotes only the best-WNS
    checkpoint/reports. The route step still uses -tns_cleanup; second_route
    does not.
  * All phys_opt stages run a hardcoded sweep, starting with AggressiveExplore
    and ending with one retime-only pass (phys_opt_design -retime). Each sweep
    preserves the best-WNS pass and stops early if a pass closes timing
    (WNS>=0). Repeated sweeps write the current best checkpoint and reports
    after every completed sweep iteration.
  * Pipeline early-exit at route, post_route_physopt, or second_route: when
    one of these closes timing, its outputs are promoted to final.dcp/final_*
    and remaining stages are skipped — bitstream runs next.

Each non-sweep step uses a tuned default directive unless overridden with --*-directive.
--route-directive controls the first route on non-x3 boards (default AggressiveExplore);
--second-route-directive controls the second route on non-x3 boards (default Explore).
--physopt-directive is currently ignored (kept for backward compatibility).

Examples:
  ./build.py x3                                    # Full build, tuned defaults
  ./build.py x3 --start-at place                   # Resume from post_opt checkpoint
  ./build.py x3 --stop-after synth                 # Synth only
  ./build.py x3 --synth-directive PerformanceOptimized
  ./build.py x3 --start-at route                   # Requires post_place_physopt.dcp
  ./build.py genesys2 --route-directive AggressiveExplore
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
        default="AlternateRoutability",
        help="Synthesis directive (default: AlternateRoutability)",
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
        help="Placer directive for non-x3 boards (default: ExtraTimingOpt). "
        "Ignored on x3, which sweeps all placer directives in parallel.",
    )
    parser.add_argument(
        "--route-directive",
        choices=ROUTER_SWEEP_DIRECTIVES,
        default="AggressiveExplore",
        help="Router directive for the first route step on non-x3 boards "
        "(with -tns_cleanup, default: AggressiveExplore). Ignored on x3, "
        "which sweeps all router directives in parallel.",
    )
    parser.add_argument(
        "--second-route-directive",
        choices=ROUTER_SWEEP_DIRECTIVES,
        default="Explore",
        help="Router directive for the second route step on non-x3 boards "
        "(without -tns_cleanup, default: Explore). Ignored on x3, which "
        "sweeps all router directives in parallel.",
    )
    parser.add_argument(
        "--physopt-directive",
        choices=PHYS_OPT_DIRECTIVES,
        default="AggressiveExplore",
        help="Currently ignored — all phys_opt stages (post_place, post_route, "
        "post_second_route) run a hardcoded directive sweep plus a retime-only "
        "pass. Kept for backward compatibility.",
    )
    args = parser.parse_args()

    board_name = args.board_name
    script_dir = Path(__file__).parent.resolve()
    project_root = script_dir.parent.parent

    # Get board configuration
    board_config = BOARD_CONFIG[board_name]
    clock_freq = board_config["clock_freq"]
    is_ultrascale = board_config["is_ultrascale"]
    if board_name == "x3":
        place_directive = "Sweep"
        route_directive = "Sweep"
        second_route_directive = "Sweep"
    else:
        place_directive = args.place_directive or "ExtraTimingOpt"
        route_directive = args.route_directive
        second_route_directive = args.second_route_directive

    # Per-step directives. The three phys_opt stages all run hardcoded sweeps
    # in the TCL and ignore the directive arg; we pass "Sweep" as a sentinel
    # so banners and the temp work dir name make this obvious.
    step_directives = {
        "synth": args.synth_directive,
        "opt": args.opt_directive,
        "place": place_directive,
        "post_place_physopt": "Sweep",
        "route": route_directive,
        "post_route_physopt": "Sweep",
        "second_route": second_route_directive,
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
    if board_name == "x3" and args.place_directive is not None:
        print(
            "# Note: --place-directive is ignored for x3; "
            "the place stage sweeps all placer directives."
        )
    if board_name == "x3" and args.route_directive != "AggressiveExplore":
        print(
            "# Note: --route-directive is ignored for x3; "
            "the first route stage sweeps all router directives."
        )
    if board_name == "x3" and args.second_route_directive != "Explore":
        print(
            "# Note: --second-route-directive is ignored for x3; "
            "the second route stage sweeps all router directives."
        )
    print(f"{'#'*70}")

    main_work = script_dir / board_name / "work"
    software_mem_dir = main_work / "hello_world"

    # Compile hello_world (skip if resuming from a checkpoint)
    if args.start_at == "synth":
        if not compile_hello_world(project_root, software_mem_dir, clock_freq):
            print("Error: Failed to compile hello_world", file=sys.stderr)
            sys.exit(1)
    else:
        print(
            f"Skipping hello_world compile because build starts at "
            f"'{args.start_at}'; BRAM contents are already in the checkpoint."
        )

    # Determine which steps to run
    start_idx = STEPS.index(args.start_at)
    if args.stop_after:
        stop_idx = STEPS.index(args.stop_after)
    else:
        stop_idx = len(STEPS) - 1

    steps_to_run = STEPS[start_idx : stop_idx + 1]

    print(f"\nSteps to run: {' -> '.join(steps_to_run)}")

    # Check required checkpoint for start step
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
    bitstream_generated = False
    last_report_prefix = None
    for step in steps_to_run:
        directive = step_directives[step]
        retiming = args.retiming if step == "synth" else False

        if board_name == "x3" and step == "place":
            success, wns, actual_prefix = run_x3_step_directive_sweep(
                script_dir,
                step,
                PLACER_DIRECTIVES,
                "placer",
                args.vivado_path,
                keep_temps=args.keep_temps,
            )
        elif board_name == "x3" and step in {"route", "second_route"}:
            success, wns, actual_prefix = run_x3_step_directive_sweep(
                script_dir,
                step,
                ROUTER_SWEEP_DIRECTIVES,
                "router",
                args.vivado_path,
                keep_temps=args.keep_temps,
            )
        else:
            success, wns, actual_prefix = run_step(
                script_dir,
                board_name,
                step,
                directive,
                args.vivado_path,
                software_mem_dir=software_mem_dir if step == "synth" else None,
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
        bitstream_generated = True

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
    if bitstream_generated:
        print(f"\nBitstream: {bitstream}")
    elif bitstream.exists():
        # A bitstream is on disk but this invocation did not produce it
        # (e.g. a resumed/partial run). Say so explicitly: reporting it as
        # this run's product invites stale-bitstream confusion.
        print(f"\nBitstream (pre-existing, NOT from this run): {bitstream}")


if __name__ == "__main__":
    main()
