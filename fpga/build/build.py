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

"""Build FPGA bitstreams with per-step directive selection.

Steps:
1. Synthesis                          (post_synth.dcp)
2. Opt                                (post_opt.dcp)
3. Place                              (post_place.dcp; x3 sweeps selected placer
                                       directives x configurable seeds)
4. Post-place phys_opt sweep          (post_place_physopt.dcp)
5. Route (with -tns_cleanup)          (post_route.dcp / final.dcp*)
6. Post-route phys_opt sweep          (post_route_physopt.dcp / final.dcp*)
7. Second route (no -tns_cleanup)     (post_second_route.dcp / final.dcp*)
8. Post-second-route phys_opt sweep   (final.dcp)
9. Bitstream generation

Phys-opt stages 4, 6, and 8 run build_step.tcl's own sweep over the
``PHYS_OPT_DIRECTIVES`` set, beginning with ``AggressiveExplore`` and ending
with a retime-only pass (``FROST_PHYSOPT_SWEEP_ORDER`` overrides the order).
Each sweep retains the best WNS, writes its checkpoint and reports, and stops
on closure.

X3 place and route sweeps run in parallel and promote one checkpoint. Both
route stages try every legal directive and rank by WNS. Placement defaults to
four directives at six 50 ps-spaced setup uncertainties from 0.500 to 0.250 ns;
these act as seeds because Vivado exposes no placer seed. ``--directives`` and
``--num-uncertainties`` override the grid. The qualified off-grid
``ExtraPostPlacementOpt``/0.425 seed is always included: under the then-active
fetch pblock it first passed the post-demolition gate (score -0.699, raw
-0.199 on 2026-08-20) and routed to closure. It remains a competitive
congestion-clean placement after that pblock's retirement. Every seed is
rescored at 0.500 ns and passes that constraint to post-place phys-opt.

Three qualified seeds (``ExtraNetDelay_high``/0.500 and
``ExtraPostPlacementOpt``/0.450 or 0.425) use a temporary PC-tail cost group:
the fourteen pinned scalar LUTRAM overlay output-FF launches of the predecode
metadata (seven sideband predicates on both parities) to the selected, state,
sequential, and pending-valid PC consumers. Topology-derived replica queries
enforce exact launch, endpoint-family, PC-bit, FD, and clock-domain
invariants. The group is removed after placement; a clean reopen audit must
restore all paths to the CPU clock group before 0.500 ns scoring.

Placement ranking vetoes seeds at
``FROST_PLACE_CONGESTION_VETO_LEVEL`` (default 5), quick-routes the top
``FROST_PLACE_QUICK_ROUTE_COUNT`` survivors (default 3), and selects routed
WNS; router congestion warnings rank last. A count of zero ranks by
zero-uncertainty-equivalent post-place WNS. ``FROST_PLACE_CELL_BLOAT`` and
``FROST_PLACE_CELL_BLOAT_CELLS`` can spread wire-dense hierarchies.

Closure at steps 5-7 promotes ``final.dcp`` and skips to bitstream generation.
Step 4 runs overconstrained, so its closure does not end the pipeline. Step 8
always writes the final checkpoint.
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


# Configuration

# ``synth_directive`` is the board's default synthesis directive. On x3
# PerformanceOptimized reaches -0.081 ns / 4 endpoints post-opt against
# AlternateRoutability's -0.178 ns / 143, but it maps 1.6x the MUXF7/MUXF8
# count: the placer sweep on that netlist gained only 0.07 ns (-0.372 against
# -0.442 WNS at zero uncertainty) and its quick route fell to -0.957 ns under
# router congestion warnings, so the routable netlist stays the default.
BOARD_CONFIG = {
    "x3": {
        "clock_freq": 300000000,
        "is_ultrascale": True,
        "synth_directive": "AlternateRoutability",
    },
}

# Legal directives for each implementation step.
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

# The spread directives relieve the ~93%-occupied X3 core band and its integer
# RS East congestion hotspot.
X3_PLACER_SWEEP_DIRECTIVES = [
    "ExtraNetDelay_high",
    "ExtraPostPlacementOpt",
    "AltSpreadLogic_high",
    "AltSpreadLogic_medium",
]

# X3 needs pre-place setup overconstraint for 300 MHz. With no Vivado seed knob,
# each 50 ps reduction creates another solution while easing the packing that
# made the flat 0.5 ns flow unroutably dense. build_step.tcl restores 0.5 ns
# after placement for equal scoring and post-place phys-opt. Keep its
# x3_place_baseline_uncertainty in sync.
X3_PLACE_BASELINE_UNCERTAINTY_NS = 0.5
X3_PLACE_SEED_UNCERTAINTY_REDUCTION_NS = 0.050
X3_PLACE_DEFAULT_SETUP_UNCERTAINTY_COUNT = 6
X3_PLACE_MAX_SETUP_UNCERTAINTY_COUNT = int(
    round(X3_PLACE_BASELINE_UNCERTAINTY_NS / X3_PLACE_SEED_UNCERTAINTY_REDUCTION_NS)
)
# Only these pairs receive PC-tail guidance. Every seed, guided or not, is
# rescored at the baseline uncertainty.
X3_PC_TAIL_GUIDED_CANDIDATES = (
    ("ExtraNetDelay_high", X3_PLACE_BASELINE_UNCERTAINTY_NS),
    ("ExtraPostPlacementOpt", 0.450),
    ("ExtraPostPlacementOpt", 0.425),
)

# This off-grid seed first met the post-demolition gate with PC-tail groups and
# the then-active fetch pblock (score -0.699, raw -0.199; 2026-08-20), then
# closed at 300 MHz. The pblock is retired, but this seed remains competitive
# without it. Neighbors were worse (0.4125: -0.841; 0.4375: -0.764). It
# competes under the same veto, probe, and rescoring rules as grid seeds.
X3_PLACE_EXTRA_SEED_CANDIDATES = (("ExtraPostPlacementOpt", 0.425),)

# Congestion level 5+ makes the router sacrifice timing for completion, so the
# selector vetoes those seeds, quick-routes the leading survivors, and ranks by
# routed WNS. Environment overrides:
#   FROST_PLACE_CONGESTION_VETO_LEVEL  (default 5)
#   FROST_PLACE_QUICK_ROUTE_COUNT      (default 3; 0 disables the probe and
#                                       falls back to post-place WNS ranking
#                                       among non-vetoed seeds)
X3_PLACE_CONGESTION_VETO_LEVEL_DEFAULT = 5
X3_PLACE_QUICK_ROUTE_COUNT_DEFAULT = 3


def make_x3_place_setup_uncertainties_ns(count: int) -> list[float]:
    """Return ``count`` 50 ps-spaced placer uncertainties from the baseline."""
    if not 1 <= count <= X3_PLACE_MAX_SETUP_UNCERTAINTY_COUNT:
        raise ValueError(
            f"x3 placer uncertainty count must be between 1 and "
            f"{X3_PLACE_MAX_SETUP_UNCERTAINTY_COUNT}"
        )
    return [
        round(
            X3_PLACE_BASELINE_UNCERTAINTY_NS
            - seed_index * X3_PLACE_SEED_UNCERTAINTY_REDUCTION_NS,
            3,
        )
        for seed_index in range(count)
    ]


def x3_place_uses_pc_tail_guidance(
    directive: str, setup_uncertainty_ns: float | None
) -> bool:
    """Return whether this X3 placement candidate gets PC-tail guidance."""
    return setup_uncertainty_ns is not None and any(
        directive == guided_directive
        and abs(setup_uncertainty_ns - guided_uncertainty_ns) < 1.0e-9
        for guided_directive, guided_uncertainty_ns in X3_PC_TAIL_GUIDED_CANDIDATES
    )


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

# Pipeline order.
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

# Required input checkpoint by step.
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

# Output checkpoints; only the last stage produces final.dcp unconditionally.
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

# Canonical report prefix in the main work directory.
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

# Prefix emitted by build_step.tcl.
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

# Closure in these steps promotes ``final.*`` and skips to bitstream. The last
# stage always writes final output; post-place phys-opt remains overconstrained.
FINAL_ELIGIBLE_STEPS = {"route", "post_route_physopt", "second_route"}


# Utilities


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
    label: str
    work_dir: Path
    stdout_path: Path
    process: subprocess.Popen[bytes] | None = None
    stdout_handle: TextIO | None = None
    start_time: float | None = None
    returncode: int | None = None
    elapsed_s: float | None = None
    setup_uncertainty_ns: float | None = None
    wns: float | None = None
    tns: float | None = None
    failing_endpoints: int | None = None
    total_endpoints: int | None = None
    launch_error: str | None = None
    # X3 placement ranking fields.
    congestion_level: int | None = None
    congestion_vetoed: bool = False
    quick_route_wns: float | None = None
    quick_route_tns: float | None = None
    quick_route_warning: bool = False
    quick_route_returncode: int | None = None
    quick_route_elapsed_s: float | None = None
    pc_tail_guided: bool = False


# report_design_analysis congestion-table row, e.g.:
# | East | Short | 5 | (CLEL_R_X21Y402,CLEL_L_X37Y433) | ...
_CONGESTION_ROW_RE = re.compile(
    r"^\|\s*(?:North|South|East|West)\s*\|\s*\S+\s*\|\s*(\d+)\s*\|", re.MULTILINE
)

# A quick-route probe whose log carries this timing-capitulation warning
# ranks last.
_ROUTER_CONGESTION_WARNING = "Congestion is preventing the router from routing all nets"


def extract_max_congestion_level(congestion_rpt_path: Path) -> int | None:
    """Return the worst congestion window level from a congestion report.

    Parses report_design_analysis -congestion output. Returns 0 if the report
    exists but lists no congested window, or None if the report is
    missing/unreadable.
    """
    if not congestion_rpt_path.exists():
        return None
    try:
        content = congestion_rpt_path.read_text()
    except OSError:
        return None
    levels = [int(m.group(1)) for m in _CONGESTION_ROW_RE.finditer(content)]
    return max(levels, default=0)


def quick_route_log_has_congestion_warning(log_path: Path) -> bool:
    """Report whether the quick-route Vivado log shows router capitulation.

    The router prints this warning when congestion forces it to prioritize
    completing all nets over timing optimization.
    """
    if not log_path.exists():
        return False
    try:
        return _ROUTER_CONGESTION_WARNING in log_path.read_text(errors="replace")
    except OSError:
        return False


# Predecode sideband predicates mirrored into pinned low-address scalar LUTRAM
# overlays on both IMEM parities (imem_predecode.sv,
# generate_imem_predecode_init.py); every one launches the guided PC tail.
IMEM_SCALAR_REPLICA_NAMES = (
    "is_compressed_lo",
    "is_compressed_hi",
    "even_local_pair_valid",
    "pairable_native_lo",
    "pairable_compressed_hi",
    "pairable_native_hi",
    "slot2_start_valid_lo",
)
X3_PC_TAIL_SCALAR_LAUNCH_COUNT = 2 * len(IMEM_SCALAR_REPLICA_NAMES)
# Init images of retired timing replicas, cleared from reused build directories.
IMEM_RETIRED_INIT_IMAGE_NAMES = (
    "sw_imem_even_pc_compressed.mem",
    "sw_imem_odd_pc_compressed.mem",
    "sw_imem_even_compressed_hi.mem",
    "sw_imem_odd_compressed_hi.mem",
    "sw_imem_even_pc_metadata.mem",
    "sw_imem_odd_pc_metadata.mem",
    "sw_imem_even_pc_metadata_bit2.mem",
    "sw_imem_odd_pc_metadata_bit2.mem",
    "sw_imem_even_pc_metadata_bit3.mem",
    "sw_imem_odd_pc_metadata_bit3.mem",
)


def x3_pc_tail_group_audit_is_valid(
    audit_path: Path,
    expected_directive: str,
    expected_setup_uncertainty_ns: float,
) -> bool:
    """Validate topology proofs and the exact guided placement seed.

    Vivado physical synthesis may add, remove, or rename noncanonical register
    replicas during placement. The audit therefore proves exact launch and
    canonical architectural-endpoint continuity across placement, then exact
    full endpoint-name continuity across the clean checkpoint reopen. The
    historical ``COMPRESSED_*`` field names describe the fourteen pinned
    scalar-overlay launches of the predecode metadata.
    """
    if not x3_place_uses_pc_tail_guidance(
        expected_directive, expected_setup_uncertainty_ns
    ):
        return False

    try:
        fields: dict[str, str] = {}
        for line in audit_path.read_text().splitlines():
            if "=" not in line:
                return False
            key, value = line.split("=", 1)
            if not key or key in fields:
                return False
            fields[key] = value

        required_fields = {
            "DIRECTIVE",
            "PLACE_UNCERTAINTY_NS",
            "SCORE_UNCERTAINTY_NS",
            "PRE_COMPRESSED_STARTS",
            "PRE_ENDS",
            "PRE_PC_BITS",
            "PRE_STATE_ENDS",
            "PRE_STATE_PC_BITS",
            "PRE_SEQ_ENDS",
            "PRE_SEQ_PC_BITS",
            "PRE_PENDING_ENDS",
            "PRE_PENDING_CANONICAL",
            "PRE_UNION_ENDS",
            "POST_COMPRESSED_STARTS",
            "POST_ENDS",
            "POST_PC_BITS",
            "POST_STATE_ENDS",
            "POST_STATE_PC_BITS",
            "POST_SEQ_ENDS",
            "POST_SEQ_PC_BITS",
            "POST_PENDING_ENDS",
            "POST_PENDING_CANONICAL",
            "POST_UNION_ENDS",
            "PRE_COMPRESSED_START_NAMES_MATCH_POST",
            "PRE_SELECTED_CANONICAL_NAMES_MATCH_POST",
            "PRE_STATE_CANONICAL_NAMES_MATCH_POST",
            "PRE_SEQ_CANONICAL_NAMES_MATCH_POST",
            "PRE_PENDING_CANONICAL_NAMES_MATCH_POST",
            "SCORE_COMPRESSED_STARTS",
            "SCORE_ENDS",
            "SCORE_PC_BITS",
            "SCORE_STATE_ENDS",
            "SCORE_STATE_PC_BITS",
            "SCORE_SEQ_ENDS",
            "SCORE_SEQ_PC_BITS",
            "SCORE_PENDING_ENDS",
            "SCORE_PENDING_CANONICAL",
            "SCORE_UNION_ENDS",
            "SCORE_COMPRESSED_START_NAMES_MATCH_POST",
            "SCORE_ENDPOINT_NAMES_MATCH_POST",
            "SCORE_COMPRESSED_ENDPOINT_NAMES_MATCH_POST",
            "LINGERING_CUSTOM_PATHS",
            "COMPRESSED_SCORED_GROUPS",
        }
        if set(fields) != required_fields:
            return False

        integer_field_names = {
            field_name
            for field_name in required_fields
            if field_name.startswith(("PRE_", "POST_", "SCORE_"))
            and not field_name.endswith(
                (
                    "NAMES_MATCH_POST",
                    "ENDPOINT_NAMES_MATCH_POST",
                    "SCORED_GROUPS",
                    "UNCERTAINTY_NS",
                )
            )
        }
        counts = {name: int(fields[name]) for name in integer_field_names}
    except (OSError, UnicodeError, ValueError):
        return False

    for phase in ("PRE", "POST", "SCORE"):
        if counts[f"{phase}_COMPRESSED_STARTS"] != X3_PC_TAIL_SCALAR_LAUNCH_COUNT:
            return False
        # Phase 3 M2 retired producer-side PC masking, so the selected and
        # state PC families cover all 64 architectural bits. The sequential PC
        # register holds 63 bits.
        if counts[f"{phase}_PC_BITS"] != 64:
            return False
        if counts[f"{phase}_STATE_PC_BITS"] != 64:
            return False
        if counts[f"{phase}_SEQ_PC_BITS"] != 63:
            return False
        if counts[f"{phase}_PENDING_CANONICAL"] != 1:
            return False
        if counts[f"{phase}_ENDS"] < 64:
            return False
        if counts[f"{phase}_STATE_ENDS"] < 64:
            return False
        if counts[f"{phase}_SEQ_ENDS"] < 63:
            return False
        if counts[f"{phase}_PENDING_ENDS"] < 1:
            return False
        expected_union = (
            counts[f"{phase}_ENDS"]
            + counts[f"{phase}_STATE_ENDS"]
            + counts[f"{phase}_SEQ_ENDS"]
            + counts[f"{phase}_PENDING_ENDS"]
        )
        if counts[f"{phase}_UNION_ENDS"] != expected_union:
            return False

    # Replica counts may change during placement, but the audited clean reopen
    # must preserve the complete post-place topology.
    for endpoint_field in ("ENDS", "STATE_ENDS", "SEQ_ENDS", "PENDING_ENDS"):
        if counts[f"SCORE_{endpoint_field}"] != counts[f"POST_{endpoint_field}"]:
            return False
    if counts["SCORE_UNION_ENDS"] != counts["POST_UNION_ENDS"]:
        return False

    proof_fields = (
        "PRE_COMPRESSED_START_NAMES_MATCH_POST",
        "PRE_SELECTED_CANONICAL_NAMES_MATCH_POST",
        "PRE_STATE_CANONICAL_NAMES_MATCH_POST",
        "PRE_SEQ_CANONICAL_NAMES_MATCH_POST",
        "PRE_PENDING_CANONICAL_NAMES_MATCH_POST",
        "SCORE_COMPRESSED_START_NAMES_MATCH_POST",
        "SCORE_ENDPOINT_NAMES_MATCH_POST",
        "SCORE_COMPRESSED_ENDPOINT_NAMES_MATCH_POST",
    )
    return (
        fields.get("DIRECTIVE") == expected_directive
        and fields.get("PLACE_UNCERTAINTY_NS") == f"{expected_setup_uncertainty_ns:.3f}"
        and fields.get("SCORE_UNCERTAINTY_NS")
        == f"{X3_PLACE_BASELINE_UNCERTAINTY_NS:.3f}"
        and all(fields.get(field_name) == "1" for field_name in proof_fields)
        and fields.get("LINGERING_CUSTOM_PATHS") == "0"
        and fields.get("COMPRESSED_SCORED_GROUPS") == "clock_from_mmcm"
    )


def extract_timing_from_report(timing_rpt_path: Path) -> TimingSummary:
    """Extract WNS, TNS, WHS, THS and failing endpoint counts from timing report."""
    result: TimingSummary = {}

    if not timing_rpt_path.exists():
        return result

    timing_rpt = timing_rpt_path.read_text()

    # Design Timing Summary columns: WNS, TNS, setup counts, WHS, THS, hold counts.
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
        "DWORD_HEX_FILE": output_dir / "sw64.mem",
        "RAW_BINARY_FILE": output_dir / "sw.bin",
        "VIVADO_BRAM_FILE": output_dir / "sw.txt",
        "DISASSEMBLY_FILE": output_dir / "sw.S",
        "IMEM_EVEN_COLD_INIT_FILE": output_dir / "sw_imem_even_cold.mem",
        "IMEM_ODD_COLD_INIT_FILE": output_dir / "sw_imem_odd_cold.mem",
        "IMEM_EVEN_FRONTEND_HOT_INIT_FILE": output_dir
        / "sw_imem_even_frontend_hot.mem",
        "IMEM_ODD_FRONTEND_HOT_INIT_FILE": output_dir / "sw_imem_odd_frontend_hot.mem",
        "IMEM_EVEN_SIDEBAND_FILE": output_dir / "sw_imem_even_sideband.mem",
        "IMEM_ODD_SIDEBAND_FILE": output_dir / "sw_imem_odd_sideband.mem",
        "IMEM_EVEN_COMPRESSED_FILE": output_dir / "sw_imem_even_compressed.mem",
        "IMEM_ODD_COMPRESSED_FILE": output_dir / "sw_imem_odd_compressed.mem",
    }
    # One scalar LUTRAM overlay image per sideband predicate and parity bank.
    for replica_name in IMEM_SCALAR_REPLICA_NAMES:
        for parity in ("even", "odd"):
            variable = f"IMEM_{parity.upper()}_{replica_name.upper()}_FILE"
            outputs[variable] = output_dir / f"sw_imem_{parity}_{replica_name}.mem"

    # Remove retired images from reused board build directories.
    retired_init_outputs = tuple(
        output_dir / name for name in IMEM_RETIRED_INIT_IMAGE_NAMES
    )
    for output_path in (*outputs.values(), *retired_init_outputs):
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
    """Copy checkpoint and reports from step work dir to main work directory.

    Ad hoc ``audit_post_opt_*`` reports carry no provenance tying them to the
    promoted checkpoint. Retired ``post_opt_fence_*`` diagnostics described a
    setup exception that is no longer applied. Invalidate both families when
    installing a new post-opt checkpoint so stale evidence cannot be mistaken
    for evidence about the new DCP.
    """
    # Promote the checkpoint under its canonical name.
    checkpoint_candidates = []
    if source_report_prefix:
        checkpoint_candidates.append(work_dir / f"{source_report_prefix}.dcp")
    checkpoint_candidates.append(work_dir / checkpoint_name)
    checkpoint_candidates.extend(sorted(work_dir.glob("*.dcp")))
    seen_checkpoints = set()
    checkpoint_promoted = False
    for dcp in checkpoint_candidates:
        if dcp in seen_checkpoints:
            continue
        seen_checkpoints.add(dcp)
        if not dcp.exists() or dcp.name.endswith("_best.dcp"):
            continue
        dst = main_work / checkpoint_name
        shutil.copy2(dcp, dst)
        checkpoint_promoted = True
        print(f"  Checkpoint: {dst}")
        break

    if checkpoint_promoted and report_prefix == "post_opt":
        for stale_pattern in ("audit_post_opt_*", "post_opt_fence_*"):
            for stale_audit in main_work.glob(stale_pattern):
                if stale_audit.is_file() or stale_audit.is_symlink():
                    stale_audit.unlink()

    # Promote reports under canonical names.
    for suffix in [
        "_timing.rpt",
        "_util.rpt",
        "_high_fanout.rpt",
        "_failing_paths.csv",
        "_congestion.rpt",
        "_group_audit.txt",
        "_pc_compressed_tail_timing.rpt",
    ]:
        dst = main_work / f"{report_prefix}{suffix}"
        # Never leave diagnostics from an older promoted DCP.
        dst.unlink(missing_ok=True)
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
            shutil.copy2(rpt, dst)
            break

    # Preserve the step's Vivado log beside its reports.
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


def directive_sweep_rank_wns(run: DirectiveSweepRun) -> float | None:
    """Return the WNS used to rank a directive sweep run.

    Placement reports retain ``X3_PLACE_BASELINE_UNCERTAINTY_NS``; adding it
    reconstructs zero-uncertainty WNS. This assumes the critical path belongs
    to the affected CPU timing group. Router reports need no adjustment.
    """
    if run.wns is None:
        return None
    if run.setup_uncertainty_ns is None:
        return run.wns
    return run.wns + X3_PLACE_BASELINE_UNCERTAINTY_NS


def placement_seed_wns(run: DirectiveSweepRun) -> float | None:
    """Reconstruct WNS under the uncertainty used to place this run."""
    rank_wns = directive_sweep_rank_wns(run)
    if rank_wns is None or run.setup_uncertainty_ns is None:
        return None
    return rank_wns - run.setup_uncertainty_ns


def directive_sweep_rank_key(run: DirectiveSweepRun) -> tuple[int, float, float]:
    """Sort runs best-first by comparison WNS, then reported TNS.

    Runs without WNS data (failed/launch-error) sort last; among equal-WNS
    runs, a missing TNS ranks worst, matching the best-run selection logic.
    """
    rank_wns = directive_sweep_rank_wns(run)
    if rank_wns is None:
        return (1, 0.0, 0.0)
    return (
        0,
        -rank_wns,
        -(run.tns if run.tns is not None else float("-inf")),
    )


def run_x3_place_quick_route_probes(
    script_dir: Path,
    candidates: list[DirectiveSweepRun],
    vivado_path: str,
) -> None:
    """Quick-route candidates at real constraints and record their timing.

    The cheapest router directive scores every seed equally. Probe results fill
    ``quick_route_*``; promotion still uses the untouched ``post_place.dcp``.
    """
    active: list[tuple[DirectiveSweepRun, subprocess.Popen[bytes], TextIO, float]] = []
    try:
        for run in candidates:
            checkpoint = run.work_dir / "post_place.dcp"
            if not checkpoint.exists():
                run.quick_route_returncode = -1
                print(f"  quick-route skip {run.label}: missing {checkpoint}")
                continue
            stdout_path = run.work_dir / "quick_route_stdout.log"
            command = [
                vivado_path,
                "-mode",
                "batch",
                "-source",
                str(script_dir / "build_step.tcl"),
                "-nojournal",
                "-log",
                "quick_route_vivado.log",
                "-tclargs",
                "x3",
                "quick_route",
                "RuntimeOptimized",
                str(checkpoint),
                "0",
            ]
            stdout_handle = stdout_path.open("w")
            try:
                process = subprocess.Popen(
                    command,
                    cwd=run.work_dir,
                    stdout=stdout_handle,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
            except OSError as e:
                stdout_handle.close()
                run.quick_route_returncode = -1
                print(f"  quick-route launch failed for {run.label}: {e}")
                continue
            active.append((run, process, stdout_handle, time.monotonic()))
            print(f"  quick-route {run.label:<30} pid={process.pid}")

        while active:
            for entry in list(active):
                run, process, stdout_handle, started = entry
                returncode = process.poll()
                if returncode is None:
                    continue
                stdout_handle.close()
                run.quick_route_returncode = returncode
                run.quick_route_elapsed_s = time.monotonic() - started
                if returncode == 0:
                    timing = extract_timing_from_report(
                        run.work_dir / "quick_route_timing.rpt"
                    )
                    run.quick_route_wns = timing.get("wns_ns")
                    run.quick_route_tns = timing.get("tns_ns")
                run.quick_route_warning = quick_route_log_has_congestion_warning(
                    run.work_dir / "quick_route_vivado.log"
                )
                warn_text = (
                    " [router congestion warning]" if run.quick_route_warning else ""
                )
                print(
                    f"  Finished quick-route {run.label:<30} routed "
                    f"WNS={format_sweep_ns(run.quick_route_wns)} ns{warn_text} "
                    f"({format_sweep_elapsed(run.quick_route_elapsed_s)})"
                )
                active.remove(entry)
            if active:
                time.sleep(5)
    except KeyboardInterrupt:
        print("\nTerminating active quick-route probes...")
        for run, process, stdout_handle, _ in active:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except (ProcessLookupError, OSError):
                pass
            stdout_handle.close()
        raise SystemExit(130)


def x3_place_quick_route_rank_key(run: DirectiveSweepRun) -> tuple[int, float, float]:
    """Rank quick-routed seeds best-first.

    Probes without the router's congestion-capitulation warning come first,
    then best routed WNS, then routed TNS.
    """
    assert run.quick_route_wns is not None
    return (
        1 if run.quick_route_warning else 0,
        -run.quick_route_wns,
        -(run.quick_route_tns if run.quick_route_tns is not None else float("-inf")),
    )


def select_x3_place_best_run(
    script_dir: Path,
    runs: list[DirectiveSweepRun],
    vivado_path: str,
) -> DirectiveSweepRun | None:
    """Select the best x3 place seed with congestion awareness.

    Veto seeds at the congestion threshold, quick-route the leading survivors,
    and pick the best routed WNS. Fall back to post-place WNS if probes fail.
    """
    eligible = [run for run in runs if run.returncode == 0 and run.wns is not None]
    if not eligible:
        return None

    for run in eligible:
        run.congestion_level = extract_max_congestion_level(
            run.work_dir / "post_place_congestion.rpt"
        )

    veto_level = int(
        os.environ.get(
            "FROST_PLACE_CONGESTION_VETO_LEVEL",
            str(X3_PLACE_CONGESTION_VETO_LEVEL_DEFAULT),
        )
    )
    survivors = [
        run
        for run in eligible
        if run.congestion_level is None or run.congestion_level < veto_level
    ]
    for run in eligible:
        run.congestion_vetoed = run not in survivors
    if not survivors:
        known_levels = [
            run.congestion_level for run in eligible if run.congestion_level is not None
        ]
        min_level = min(known_levels)
        survivors = [run for run in eligible if run.congestion_level == min_level]
        for run in survivors:
            run.congestion_vetoed = False
        print(
            f"\nWARNING: every place seed reached congestion level >= "
            f"{veto_level}; falling back to the level-{min_level} seeds"
        )
    elif len(survivors) < len(eligible):
        print(
            f"\nCongestion veto (level >= {veto_level}) removed "
            f"{len(eligible) - len(survivors)}/{len(eligible)} place seeds"
        )

    survivors_ranked = sorted(survivors, key=directive_sweep_rank_key)
    quick_route_count = int(
        os.environ.get(
            "FROST_PLACE_QUICK_ROUTE_COUNT", str(X3_PLACE_QUICK_ROUTE_COUNT_DEFAULT)
        )
    )
    if quick_route_count <= 0 or len(survivors_ranked) <= 1:
        return survivors_ranked[0]

    candidates = survivors_ranked[:quick_route_count]
    print(
        f"\nQuick-route probing the top {len(candidates)} surviving seeds "
        f"(routed WNS decides):"
    )
    run_x3_place_quick_route_probes(script_dir, candidates, vivado_path)

    probed = [
        run
        for run in candidates
        if run.quick_route_returncode == 0 and run.quick_route_wns is not None
    ]
    if not probed:
        print(
            "WARNING: no quick-route probe produced usable timing; "
            "falling back to post-place WNS ranking among surviving seeds"
        )
        return survivors_ranked[0]
    return min(probed, key=x3_place_quick_route_rank_key)


def print_x3_directive_sweep_matrix(
    runs: list[DirectiveSweepRun],
    best_run: DirectiveSweepRun | None,
    title: str,
) -> None:
    """Print a compact matrix of x3 directive sweep results, best WNS first."""
    show_placement_wns = any(run.setup_uncertainty_ns is not None for run in runs)

    print(f"\n{title}:")
    if show_placement_wns:
        print(
            f"{'Sel':<3} {'Directive':<30} {'Status':<10} "
            f"{'WNS@0':>9} {'WNS@seed':>11} {'TNS@.500':>11} "
            f"{'Cong':>5} {'RouteWNS':>9} "
            f"{'Failing EP':>14} {'Elapsed':>8}"
        )
        print("-" * 121)
    else:
        print(
            f"{'Sel':<3} {'Directive':<30} {'Status':<10} "
            f"{'WNS(ns)':>9} {'TNS(ns)':>11} {'Failing EP':>14} {'Elapsed':>8}"
        )
        print("-" * 93)

    for run in sorted(runs, key=directive_sweep_rank_key):
        if run.launch_error:
            status = "LAUNCH"
        elif run.returncode is None:
            status = "UNKNOWN"
        elif run.returncode != 0:
            status = f"FAIL {run.returncode}"
        elif run.wns is None:
            status = "NO WNS"
        elif run.congestion_vetoed:
            status = "CONGVETO"
        else:
            status = "OK"

        failing = "N/A"
        if run.failing_endpoints is not None and run.total_endpoints is not None:
            failing = f"{run.failing_endpoints}/{run.total_endpoints}"

        selected = "*" if best_run is run else ""
        if show_placement_wns:
            congestion = (
                "N/A" if run.congestion_level is None else str(run.congestion_level)
            )
            route_wns = format_sweep_ns(run.quick_route_wns)
            if run.quick_route_warning:
                route_wns += "!"
            print(
                f"{selected:<3} {run.label:<30} {status:<10} "
                f"{format_sweep_ns(directive_sweep_rank_wns(run)):>9} "
                f"{format_sweep_ns(placement_seed_wns(run)):>11} "
                f"{format_sweep_ns(run.tns):>11} "
                f"{congestion:>5} {route_wns:>9} "
                f"{failing:>14} "
                f"{format_sweep_elapsed(run.elapsed_s):>8}"
            )
        else:
            print(
                f"{selected:<3} {run.label:<30} {status:<10} "
                f"{format_sweep_ns(run.wns):>9} "
                f"{format_sweep_ns(run.tns):>11} "
                f"{failing:>14} "
                f"{format_sweep_elapsed(run.elapsed_s):>8}"
            )

    if show_placement_wns:
        print(
            "    (Cong = worst placer congestion window level, CONGVETO = "
            "disqualified by it; RouteWNS = quick-route probe at real "
            "constraints, '!' = router congestion warning)"
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
        print(f"  SIGTERM {run.label:<30} pid={process.pid}")
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except OSError as e:
            print(f"  Warning: failed to terminate {run.label}: {e}")

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
            print(f"  SIGKILL {run.label:<30} pid={process.pid}")
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError as e:
                print(f"  Warning: failed to kill {run.label}: {e}")

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
    setup_uncertainties_ns: list[float] | None = None,
) -> tuple[bool, float | None, str]:
    """Run every x3 directive in parallel and promote the best run.

    Route sweeps promote the best-WNS run. The place sweep instead uses
    congestion-aware selection (congestion veto + quick-route probes; see
    select_x3_place_best_run).

    When setup_uncertainties_ns is given, each directive is launched once per
    uncertainty value, exported to the job as FROST_PLACE_SETUP_UNCERTAINTY.
    Vivado's placer has no seed knob, so these overconstraint variants serve
    as extra placement "seeds" per directive.
    """
    board_name = "x3"
    tcl_report_prefix = _TCL_REPORT_PREFIX[step]
    main_work = script_dir / board_name / "work"
    main_work.mkdir(parents=True, exist_ok=True)

    # Validate the input checkpoint before launching Vivado.
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

    if setup_uncertainties_ns:
        sweep_jobs = [
            (directive, uncertainty_ns)
            for directive in directives
            for uncertainty_ns in setup_uncertainties_ns
        ]
        # Add qualified off-grid seeds unless the custom grid already has them.
        extra_jobs = [
            (directive, uncertainty_ns)
            for directive, uncertainty_ns in X3_PLACE_EXTRA_SEED_CANDIDATES
            if not any(
                directive == job_directive
                and abs(uncertainty_ns - job_uncertainty_ns) < 1.0e-9
                for job_directive, job_uncertainty_ns in sweep_jobs
            )
        ]
        sweep_jobs.extend(extra_jobs)
        uncertainty_list = ", ".join(f"{u:.3f}" for u in setup_uncertainties_ns)
        extra_list = ", ".join(
            f"{directive}/{uncertainty_ns:.3f}"
            for directive, uncertainty_ns in extra_jobs
        )
        extra_note = f" + vetted extra seeds ({extra_list})" if extra_jobs else ""
        print(
            f"Launching {len(sweep_jobs)} parallel jobs: {len(directives)} "
            f"{sweep_kind} directives x {len(setup_uncertainties_ns)} "
            f"overconstraint seeds ({uncertainty_list} ns setup uncertainty)"
            f"{extra_note}:"
        )
    else:
        sweep_jobs = [(directive, None) for directive in directives]
        print(f"Launching {sweep_kind} directives in parallel:")

    runs: list[DirectiveSweepRun] = []
    try:
        for directive, uncertainty_ns in sweep_jobs:
            pc_tail_guided = x3_place_uses_pc_tail_guidance(directive, uncertainty_ns)
            if uncertainty_ns is None:
                label = directive
                job_env = None
            else:
                label = f"{directive}_u{uncertainty_ns:.3f}"
                job_env = os.environ.copy()
                job_env["FROST_PLACE_SETUP_UNCERTAINTY"] = f"{uncertainty_ns:.3f}"

            work_dir = script_dir / board_name / f"work_{step}_{label}"
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
                label=label,
                work_dir=work_dir,
                stdout_path=stdout_path,
                setup_uncertainty_ns=uncertainty_ns,
                pc_tail_guided=pc_tail_guided,
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
                    env=job_env,
                )
                run.process = process
                run.stdout_handle = stdout_handle
                run.start_time = time.monotonic()
                print(
                    f"  {label:<30} pid={process.pid:<8} "
                    f"log={work_dir / 'vivado.log'}"
                )
            except OSError as e:
                if stdout_handle is not None:
                    stdout_handle.close()
                run.returncode = -1
                run.elapsed_s = 0.0
                run.launch_error = str(e)
                print(f"  {label:<30} launch failed: {e}")

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
                if returncode == 0 and run.pc_tail_guided:
                    audit_path = run.work_dir / "post_place_group_audit.txt"
                    if run.setup_uncertainty_ns is None or not (
                        x3_pc_tail_group_audit_is_valid(
                            audit_path,
                            run.directive,
                            run.setup_uncertainty_ns,
                        )
                    ):
                        returncode = -1
                        run.returncode = returncode
                        run.launch_error = (
                            "missing or invalid clean-reopen PC-tail group audit"
                        )

                if returncode == 0:
                    timing = extract_timing_from_report(timing_rpt)
                    run.wns = timing.get("wns_ns")
                    run.tns = timing.get("tns_ns")
                    run.failing_endpoints = timing.get("failing_endpoints")
                    run.total_endpoints = timing.get("total_endpoints")

                    if run.wns is None:
                        result = "completed without timing data"
                    elif run.setup_uncertainty_ns is not None:
                        result = (
                            f"WNS@0={format_sweep_ns(directive_sweep_rank_wns(run))} "
                            f"ns, WNS@seed="
                            f"{format_sweep_ns(placement_seed_wns(run))} ns, "
                            f"TNS@0.500={format_sweep_ns(run.tns)} ns"
                        )
                    else:
                        result = (
                            f"WNS={format_sweep_ns(run.wns)} ns, "
                            f"TNS={format_sweep_ns(run.tns)} ns"
                        )
                else:
                    result = f"failed with exit code {returncode}"

                print(
                    f"  Finished {run.label:<30} {result} "
                    f"({format_sweep_elapsed(run.elapsed_s)})"
                )
                pending.remove(idx)

            if pending:
                time.sleep(5)
    except KeyboardInterrupt:
        terminate_x3_directive_sweep_runs(runs, f"{sweep_kind} sweep")
        print(f"Interrupted; x3 {sweep_kind} sweep stopped.")
        raise SystemExit(130)

    if step == "place":
        best_run = select_x3_place_best_run(script_dir, runs, vivado_path)
    else:
        eligible_runs = [
            run for run in runs if run.returncode == 0 and run.wns is not None
        ]
        best_run = min(eligible_runs, key=directive_sweep_rank_key, default=None)

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

    if best_run.setup_uncertainty_ns is not None:
        quick_route_note = ""
        if best_run.quick_route_wns is not None:
            quick_route_note = (
                f", quick-routed WNS={format_sweep_ns(best_run.quick_route_wns)} ns"
            )
        congestion_note = ""
        if best_run.congestion_level is not None:
            congestion_note = f", congestion level {best_run.congestion_level}"
        print(
            f"\nSelected x3 {sweep_kind} directive for {step}: {best_run.label} "
            f"(WNS@0={format_sweep_ns(directive_sweep_rank_wns(best_run))} ns, "
            f"WNS@seed={format_sweep_ns(placement_seed_wns(best_run))} ns, "
            f"TNS@0.500={format_sweep_ns(best_run.tns)} ns"
            f"{congestion_note}{quick_route_note})"
        )
    else:
        print(
            f"\nSelected x3 {sweep_kind} directive for {step}: {best_run.label} "
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

    # Preserve the winning probe before deleting per-seed directories.
    if step == "place":
        for quick_route_name in (
            "quick_route_timing.rpt",
            "quick_route_congestion.rpt",
            "quick_route_vivado.log",
        ):
            quick_route_src = best_run.work_dir / quick_route_name
            quick_route_dst = main_work / f"post_place_{quick_route_name}"
            quick_route_dst.unlink(missing_ok=True)
            if quick_route_src.exists():
                shutil.copy2(quick_route_src, quick_route_dst)

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
                print(f"  {run.label}: {run.work_dir}")

    return True, best_run.wns, report_prefix


# Step execution


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

    # Validate the step's required input checkpoint.
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

    # Extract timing for promotion and early-exit decisions.
    timing_rpt = work_dir / f"{tcl_report_prefix}_timing.rpt"
    timing = extract_timing_from_report(timing_rpt)
    wns = timing.get("wns_ns")
    timing_met = wns is not None and wns >= 0

    # Closing stages promote final.*; the last stage already uses that prefix.
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

    # Promote results to the board's main work directory.
    copy_results_to_main_work(
        work_dir,
        main_work,
        checkpoint_name,
        report_prefix,
        source_report_prefix=tcl_report_prefix,
    )

    # Remove the per-step directory unless debugging was requested.
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


# CLI


def main() -> None:
    """Run FPGA build."""
    parser = argparse.ArgumentParser(
        description="FROST FPGA build script",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Steps (in order):
  synth                       - Synthesis
  opt                         - Opt design
  place                       - Place design (x3 sweeps selected placer
                                directives x configurable uncertainty seeds in
                                parallel, then picks congestion-aware: veto
                                congested seeds, quick-route survivors, keep
                                the best ROUTED WNS)
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
  * On x3, place ignores --place-directive. By default its grid runs
    ExtraNetDelay_high, ExtraPostPlacementOpt, AltSpreadLogic_high, and
    AltSpreadLogic_medium at six overconstraint seeds in parallel (0.500 down
    to 0.250 ns pre-place setup uncertainty in 50 ps steps). The qualified
    ExtraPostPlacementOpt/0.425 seed is appended unless already in the grid.
    --directives sets the grid to any nonempty unique subset of legal placer
    directives, and --num-uncertainties changes its seed count while retaining
    50 ps spacing. Both overrides require a run that includes place.
  * The X3 ExtraNetDelay_high/0.500, ExtraPostPlacementOpt/0.450, and
    ExtraPostPlacementOpt/0.425 candidates temporarily group the fourteen
    pinned scalar LUTRAM overlay output-FF launches of the predecode metadata to the
    selected, state, sequential, and pending-valid PC consumers.
    The group is removed after placement; a clean DCP reopen must prove zero
    lingering custom paths, canonical clock_from_mmcm grouping, and the exact
    directive/place-uncertainty identity before any candidate can be scored at
    0.500 ns or promoted.
  * X3 place-seed selection is congestion-aware: seeds whose placer
    congestion estimate reaches FROST_PLACE_CONGESTION_VETO_LEVEL (default 5)
    are disqualified, the top FROST_PLACE_QUICK_ROUTE_COUNT (default 3)
    survivors by zero-uncertainty-equivalent WNS are each quick-routed at
    real constraints, and the winner is chosen by routed WNS.
    FROST_PLACE_QUICK_ROUTE_COUNT=0 restores WNS-only ranking among
    non-vetoed seeds. FROST_PLACE_CELL_BLOAT=LOW/MEDIUM/HIGH optionally
    spreads wire-dense hierarchies (FROST_PLACE_CELL_BLOAT_CELLS, default
    *u_tomasulo/u_int_rs). The winning checkpoint keeps the full 0.500 ns
    uncertainty through post_place_physopt.
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
  ./build.py x3 --start-at place --stop-after place \\
      --directives ExtraNetDelay_low ExtraTimingOpt --num-uncertainties 4
  ./build.py x3 --stop-after synth                 # Synth only
  ./build.py x3 --synth-directive PerformanceOptimized  # Override the board default
  ./build.py x3 --start-at route                   # Requires post_place_physopt.dcp
  ./build.py x3 --start-at second_route            # Requires post_route_physopt.dcp
""",
    )
    parser.add_argument(
        "board_name",
        nargs="?",
        default="x3",
        choices=list(BOARD_CONFIG),
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
        default=None,
        help="Synthesis directive (default: the board's tuned directive; "
        "AlternateRoutability on x3)",
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
        "Ignored on x3; use --directives to customize the x3 placer sweep.",
    )
    parser.add_argument(
        "--directives",
        nargs="+",
        choices=PLACER_DIRECTIVES,
        metavar="DIRECTIVE",
        help="Set the x3 placer grid to one or more unique directives. "
        "Each runs at every configured uncertainty; the qualified off-grid "
        "seed is still appended unless already present. The run must include "
        "the place step. Default directives: "
        f"{', '.join(X3_PLACER_SWEEP_DIRECTIVES)}.",
    )
    parser.add_argument(
        "--num-uncertainties",
        type=int,
        metavar="N",
        help="Number of 50 ps-spaced x3 placer uncertainties, starting at "
        f"{X3_PLACE_BASELINE_UNCERTAINTY_NS:.3f} ns "
        f"(1-{X3_PLACE_MAX_SETUP_UNCERTAINTY_COUNT}; default: "
        f"{X3_PLACE_DEFAULT_SETUP_UNCERTAINTY_COUNT}). The run must include "
        "place.",
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

    start_idx = STEPS.index(args.start_at)
    stop_idx = STEPS.index(args.stop_after) if args.stop_after else len(STEPS) - 1
    if stop_idx < start_idx:
        parser.error("--stop-after cannot precede --start-at")
    steps_to_run = STEPS[start_idx : stop_idx + 1]

    if args.num_uncertainties is not None and not (
        1 <= args.num_uncertainties <= X3_PLACE_MAX_SETUP_UNCERTAINTY_COUNT
    ):
        parser.error(
            f"--num-uncertainties must be between 1 and "
            f"{X3_PLACE_MAX_SETUP_UNCERTAINTY_COUNT}"
        )

    placer_sweep_overridden = (
        args.directives is not None or args.num_uncertainties is not None
    )
    if placer_sweep_overridden:
        if board_name != "x3":
            parser.error("placer sweep overrides are only valid for x3")
        if "place" not in steps_to_run:
            parser.error("placer sweep overrides require a run that includes place")
        if args.place_directive is not None:
            parser.error(
                "placer sweep overrides cannot be combined with --place-directive"
            )

    if args.directives is not None and len(args.directives) != len(
        set(args.directives)
    ):
        parser.error("--directives must not contain duplicate values")

    place_sweep_directives = args.directives or X3_PLACER_SWEEP_DIRECTIVES
    place_uncertainty_count = (
        args.num_uncertainties
        if args.num_uncertainties is not None
        else X3_PLACE_DEFAULT_SETUP_UNCERTAINTY_COUNT
    )
    place_setup_uncertainties_ns = make_x3_place_setup_uncertainties_ns(
        place_uncertainty_count
    )
    script_dir = Path(__file__).parent.resolve()
    project_root = script_dir.parent.parent

    # Resolve board-specific clock and implementation settings.
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

    # Tcl owns the phys-opt sweeps; ``Sweep`` labels their banners and work dirs.
    step_directives = {
        "synth": args.synth_directive or board_config["synth_directive"],
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
    if board_name == "x3" and "place" in steps_to_run:
        sweep_source = "custom" if placer_sweep_overridden else "default"
        print(
            f"# X3 placer sweep ({sweep_source}): "
            f"{len(place_sweep_directives)} directives x "
            f"{len(place_setup_uncertainties_ns)} uncertainties = "
            f"{len(place_sweep_directives) * len(place_setup_uncertainties_ns)} "
            "grid jobs; qualified extra seeds are added at launch"
        )
        print(f"#   {', '.join(place_sweep_directives)}")
        print(
            "#   setup uncertainties (ns): "
            + ", ".join(f"{value:.3f}" for value in place_setup_uncertainties_ns)
        )
    if board_name == "x3" and args.place_directive is not None:
        print(
            "# Note: --place-directive is ignored for x3; "
            "use --directives to customize the placer sweep."
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

    # A synthesis start needs fresh board-local BRAM contents.
    if args.start_at == "synth":
        if not compile_hello_world(project_root, software_mem_dir, clock_freq):
            print("Error: Failed to compile hello_world", file=sys.stderr)
            sys.exit(1)
    else:
        print(
            f"Skipping hello_world compile because build starts at "
            f"'{args.start_at}'; BRAM contents are already in the checkpoint."
        )

    print(f"\nSteps to run: {' -> '.join(steps_to_run)}")

    # Resumed builds require the previous stage's checkpoint.
    required_checkpoint = STEP_REQUIRES_CHECKPOINT[args.start_at]
    if required_checkpoint:
        checkpoint_path = main_work / required_checkpoint
        if not checkpoint_path.exists():
            print(f"\nError: Cannot start at '{args.start_at}'")
            print(f"Required checkpoint not found: {checkpoint_path}")
            sys.exit(1)
        print(f"Starting from checkpoint: {checkpoint_path}")

    # Execute the requested pipeline range.
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
                place_sweep_directives,
                "placer",
                args.vivado_path,
                keep_temps=args.keep_temps,
                setup_uncertainties_ns=place_setup_uncertainties_ns,
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

        # Route-stage closure skips directly to bitstream generation.
        if step in FINAL_ELIGIBLE_STEPS and wns is not None and wns >= 0:
            remaining = steps_to_run[steps_to_run.index(step) + 1 :]
            if remaining:
                print(
                    f"\nTiming met at {step} — skipping subsequent stages: "
                    f"{', '.join(remaining)}"
                )
            break

    if final_produced:
        if not generate_bitstream(script_dir, board_name, args.vivado_path):
            sys.exit(1)
        bitstream_generated = True

    # Refresh README utilization tables from available reports.
    from extract_timing_and_util_summary import (
        collect_all_board_utilization,
        update_readme_utilization,
    )

    all_util = collect_all_board_utilization(script_dir)
    if all_util:
        update_readme_utilization(script_dir, all_util)

    # Summarize the last completed step, including partial/resumed runs.
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
        print(f"\nBitstream (pre-existing, NOT from this run): {bitstream}")


if __name__ == "__main__":
    main()
