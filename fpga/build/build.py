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

"""Build FPGA bitstreams through checkpointed Vivado stages.

Stages run in order: synth, opt, place, post-place phys-opt, route, post-route
phys-opt, second route, post-second-route phys-opt, bitstream. Closing timing
at route, post-route phys-opt, or second route promotes that output to
final.dcp and skips to the bitstream; the last phys-opt stage always writes
final.dcp.

On X3, place and both route stages are sweeps that promote the best qualified
candidate, scored at zero added setup uncertainty. A placement guided by a
temporary PC-tail path group is scored only if its audit on a clean reopen
passes. Every later stage, and the bitstream, checks that its input checkpoint
descends from the current qualified placement, using the sidecar files written
beside each checkpoint.

Run natively; see ``fpga/README.md`` and ``--help`` for commands and tuning.
"""

import argparse
from collections.abc import Mapping
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
import zipfile
from pathlib import Path
from typing import TextIO, TypedDict

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sw" / "apps"))
from riscv_toolchain import default_riscv_prefix  # noqa: E402


# Configuration

# Default cap on concurrent full-design Vivado processes, separate from each
# process's own thread count. A worker needs about 8 GB, so launching a whole
# placement sweep at once can exhaust the host's memory.
DEFAULT_MAX_JOBS = 12

# ``synth_directive`` is the board's default synthesis directive. On x3,
# PerformanceOptimized improves post-opt timing but maps many more MUXF7/MUXF8
# cells, which leaves little of that gain after placement and congests routing,
# so the more routable AlternateRoutability netlist is the default.
BOARD_CONFIG = {
    "x3": {
        "clock_freq": 322265625,
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

# The AltSpreadLogic directives spread out the densely packed X3 core region
# and its integer-RS congestion hotspot.
X3_PLACER_SWEEP_DIRECTIVES = [
    "ExtraNetDelay_high",
    "ExtraPostPlacementOpt",
    "AltSpreadLogic_high",
    "AltSpreadLogic_medium",
]

# X3 places with added setup uncertainty (overconstraint). Vivado's placer has
# no seed option, so each 50 ps step down from the 0.5 ns baseline yields
# another placement, and the lower values ease packing that at 0.5 ns alone
# can be too dense to route. build_step.tcl reports at zero added uncertainty
# after placement, so the seed-grid baseline and the reporting uncertainty are
# separate constants.
X3_PLACE_BASELINE_UNCERTAINTY_NS = 0.5
X3_PLACE_REPORT_UNCERTAINTY_NS = 0.0
X3_POST_PLACE_GATE_NS = Decimal("-0.200")
# Vivado reports slack and clock periods to three decimals, and the gate's
# native queries carry more precision than the timing summary prints. Half a
# printed digit accepts every value that displays as the expected one and
# still rejects a different printed number (3.104 ns against 3.103 ns).
X3_GATE_DISPLAY_TOLERANCE_NS = Decimal("0.0005")
# XDC constrains the 300 MHz reference to 3.333 ns. Use that physical period
# and the fixed MMCM recipe, including its rounding, for native timing evidence.
X3_CPU_PERIOD_NS = Decimal("3.333") * 8 * 4 / Decimal("34.375")
X3_PLACE_SEED_UNCERTAINTY_REDUCTION_NS = 0.050
X3_PLACE_DEFAULT_SETUP_UNCERTAINTY_COUNT = 6
X3_PLACE_MAX_SETUP_UNCERTAINTY_COUNT = int(
    round(X3_PLACE_BASELINE_UNCERTAINTY_NS / X3_PLACE_SEED_UNCERTAINTY_REDUCTION_NS)
)
# Synthesis-time netlist options recorded beside the checkpoints they produced.
X3_NETLIST_CONFIG_NAME = "netlist_config.json"
# Only these pairs receive PC-tail guidance. Every seed, guided or not, is
# reported at zero added uncertainty.
X3_PC_TAIL_GUIDED_CANDIDATES = (
    ("ExtraNetDelay_high", X3_PLACE_BASELINE_UNCERTAINTY_NS),
    ("ExtraPostPlacementOpt", 0.450),
    ("ExtraPostPlacementOpt", 0.425),
)

# The off-grid seed competes under the same veto, probe, and rescoring
# rules as grid seeds.
X3_PLACE_EXTRA_SEED_CANDIDATES = (("ExtraPostPlacementOpt", 0.425),)

# Integer-RS cell-bloat variants, each added beside its unbloated control; a
# narrowed grid gets a variant only if its control is still in the grid.
# Setting either bloat environment variable disables these variants and
# applies the caller's setting to every candidate (an empty factor means no
# bloat).
X3_PLACE_INT_RS_BLOAT_CANDIDATES = (
    ("ExtraNetDelay_high", 0.350),
    ("ExtraPostPlacementOpt", 0.450),
)
X3_PLACE_INT_RS_BLOAT_FACTOR = "LOW"
X3_PLACE_INT_RS_BLOAT_CELLS = "*u_tomasulo/u_int_rs"


@dataclass(frozen=True)
class DirectiveSweepCandidate:
    """One single-placement recipe with optional pre-place cell bloat."""

    directive: str
    setup_uncertainty_ns: float | None = None
    cell_bloat_factor: str | None = None
    cell_bloat_cells: str | None = None

    @property
    def label(self) -> str:
        """Return a distinct work-directory label for each automatic recipe."""
        label = self.directive
        if self.setup_uncertainty_ns is not None:
            label += f"_u{self.setup_uncertainty_ns:.3f}"
        if self.cell_bloat_factor is not None:
            label += f"_bloat{self.cell_bloat_factor}_intRS"
        return label

    def environment(self, inherited: Mapping[str, str]) -> dict[str, str]:
        """Copy environment settings without leaking a variant into controls."""
        environment = dict(inherited)
        # Nothing reads these obsolete switches of the diagnostic flush-guidance
        # and pin-swap helpers, which never run in production; drop them so no
        # candidate inherits them.
        environment.pop("FROST_PLACE_FLUSH_INCREMENTAL", None)
        environment.pop("FROST_X3_PD_TARGET_PIN_SWAPS", None)
        if self.setup_uncertainty_ns is not None:
            environment["FROST_PLACE_SETUP_UNCERTAINTY"] = (
                f"{self.setup_uncertainty_ns:.3f}"
            )
        if self.cell_bloat_factor is not None:
            if self.cell_bloat_cells is None:
                raise ValueError("a cell-bloat variant requires an explicit target")
            environment["FROST_PLACE_CELL_BLOAT"] = self.cell_bloat_factor
            environment["FROST_PLACE_CELL_BLOAT_CELLS"] = self.cell_bloat_cells
        return environment


# Congestion level 5+ makes the router sacrifice timing for completion, so the
# selector vetoes those seeds. Explicit quick-route requests rank the leading
# gate-passing survivors by routed WNS. Environment overrides:
#   FROST_PLACE_CONGESTION_VETO_LEVEL  (default 5)
#   FROST_PLACE_QUICK_ROUTE_COUNT      (default 0; positive counts enable
#                                       probes for gate-passing seeds only;
#                                       zero ranks by actual post-place WNS)
X3_PLACE_CONGESTION_VETO_LEVEL_DEFAULT = 5
X3_PLACE_QUICK_ROUTE_COUNT_DEFAULT = 0


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


def make_x3_place_sweep_candidates(
    directives: list[str],
    setup_uncertainties_ns: list[float],
    environment: Mapping[str, str],
    include_extra_seeds: bool = True,
) -> list[DirectiveSweepCandidate]:
    """Return the control grid plus the off-grid seed and eligible bloat variants.

    With ``include_extra_seeds`` false (divided-clock builds), return the grid
    exactly as requested.
    """
    candidates = [
        DirectiveSweepCandidate(directive, uncertainty)
        for directive in directives
        for uncertainty in setup_uncertainties_ns
    ]
    if not include_extra_seeds:
        return candidates
    for directive, uncertainty in X3_PLACE_EXTRA_SEED_CANDIDATES:
        if not any(
            candidate.directive == directive
            and candidate.setup_uncertainty_ns is not None
            and abs(candidate.setup_uncertainty_ns - uncertainty) < 1.0e-9
            for candidate in candidates
        ):
            candidates.append(DirectiveSweepCandidate(directive, uncertainty))

    # Test presence, not truthiness: an empty factor, or a target pattern with
    # no factor, still turns off the automatic variants and yields a sweep
    # without bloat.
    manual_bloat = any(
        name in environment
        for name in ("FROST_PLACE_CELL_BLOAT", "FROST_PLACE_CELL_BLOAT_CELLS")
    )
    if not manual_bloat:
        for directive, uncertainty in X3_PLACE_INT_RS_BLOAT_CANDIDATES:
            if directive in directives and any(
                abs(grid_uncertainty - uncertainty) < 1.0e-9
                for grid_uncertainty in setup_uncertainties_ns
            ):
                candidates.append(
                    DirectiveSweepCandidate(
                        directive,
                        uncertainty,
                        X3_PLACE_INT_RS_BLOAT_FACTOR,
                        X3_PLACE_INT_RS_BLOAT_CELLS,
                    )
                )
    return candidates


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

ALL_ROUTER_DIRECTIVES = ROUTER_DIRECTIVES + ULTRASCALE_ROUTER_DIRECTIVES

# Keep the sweep focused on the competitive full-rate X3 candidates. Other
# legal directives remain available explicitly, including RuntimeOptimized
# for the divided-clock functional-validation flow.
ROUTER_SWEEP_DIRECTIVES = [
    "Explore",
    "AggressiveExplore",
    "NoTimingRelaxation",
    "AlternateCLBRouting",
]


def resolve_x3_route_sweep_directives(requested: list[str] | None) -> list[str]:
    """Return the default x3 sweep or unique explicitly requested legal directives."""
    if not requested:
        return list(ROUTER_SWEEP_DIRECTIVES)
    unique: list[str] = []
    for directive in requested:
        if directive not in ALL_ROUTER_DIRECTIVES:
            raise ValueError(f"unknown router directive: {directive}")
        if directive not in unique:
            unique.append(directive)
    return unique


X3_FUNCTIONAL_PLACE_DIRECTIVE = "RuntimeOptimized"
X3_FUNCTIONAL_ROUTE_DIRECTIVE = "RuntimeOptimized"
CPU_CLOCK_DIV_CHOICES = (1, 2, 3, 4)


@dataclass(frozen=True)
class FunctionalBuildPolicy:
    """What a divided-clock (functional-validation) build changes in the flow."""

    cpu_clock_div: int
    clock_freq: int
    place_directives: list[str]
    place_uncertainty_count: int
    include_extra_seeds: bool
    quick_route_count: int | None  # None: leave the environment's choice alone
    route_directives: list[str]
    update_readme: bool
    # Profiling counters in the netlist (the board top's PERF_COUNTERS generic).
    perf_counters: bool


def resolve_functional_build_policy(
    cpu_clock_div: int,
    base_clock_freq: int,
    place_directives: list[str],
    place_uncertainty_count: int,
    placer_sweep_overridden: bool,
    route_directives: list[str],
    route_sweep_overridden: bool,
    perf_counters: bool | None = None,
) -> FunctionalBuildPolicy:
    """Return the flow settings for ``--cpu-clock-div``.

    A divider of 1 keeps every setting as resolved by the caller. A larger
    divider builds for the board clock divided by N. An explicit
    ``--directives`` or ``--num-uncertainties`` keeps the requested placer
    grid and an explicit ``--route-directives`` keeps the requested router
    list; otherwise placement and routing each run once with RuntimeOptimized,
    which is enough for a design with hundreds of picoseconds of margin.

    ``perf_counters`` is ``--perf-counters``/``--no-perf-counters``; ``None``
    leaves the counters out of a full-rate build and includes them in a
    divided-clock build.
    """
    if cpu_clock_div not in CPU_CLOCK_DIV_CHOICES:
        raise ValueError(f"unsupported CPU clock divider: {cpu_clock_div}")
    include_counters = (cpu_clock_div != 1) if perf_counters is None else perf_counters
    if cpu_clock_div == 1:
        return FunctionalBuildPolicy(
            1,
            base_clock_freq,
            list(place_directives),
            place_uncertainty_count,
            True,
            None,
            list(route_directives),
            True,
            include_counters,
        )
    return FunctionalBuildPolicy(
        cpu_clock_div,
        base_clock_freq // cpu_clock_div,
        list(place_directives)
        if placer_sweep_overridden
        else [X3_FUNCTIONAL_PLACE_DIRECTIVE],
        place_uncertainty_count if placer_sweep_overridden else 1,
        False,
        0,
        list(route_directives)
        if route_sweep_overridden
        else [X3_FUNCTIONAL_ROUTE_DIRECTIVE],
        False,
        include_counters,
    )


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

# Report prefix in the main work directory.
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
# stage always writes final output; post-place phys-opt does not promote final.
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
    # Per-candidate pre-place physical settings.
    cell_bloat_factor: str | None = None
    cell_bloat_cells: str | None = None


# report_design_analysis congestion-table row, e.g.:
# | East | Short | 5 | (CLEL_R_X21Y402,CLEL_L_X37Y433) | ...
_CONGESTION_ROW_RE = re.compile(
    r"^\|\s*(?:North|South|East|West)\s*\|\s*\S+\s*\|\s*(\d+)\s*\|", re.MULTILINE
)

# A quick-route probe whose log carries this timing-capitulation warning
# ranks last.
_ROUTER_CONGESTION_WARNING = "Congestion is preventing the router from routing all nets"


def extract_max_congestion_level(congestion_rpt_path: Path) -> int | None:
    """Return the worst reported congestion window level.

    Parses report_design_analysis -congestion output. Zero is an internal
    sentinel for no parsed window rows, NOT a measured congestion level.
    The default report threshold is 5, so smaller windows remain unmeasured.
    Returns None if the report is missing/unreadable.
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


def x3_place_cell_bloat_override_is_valid(
    log_path: Path, expected_factor: str, expected_cells: str
) -> bool:
    """Return whether the log shows the recipe's bloat applied to exactly one cell."""
    try:
        content = log_path.read_text(errors="replace")
    except OSError:
        return False
    matches = re.findall(
        r"^Set CELL_BLOAT_FACTOR (LOW|MEDIUM|HIGH) on (\d+) cell\(s\) "
        r"matching '([^']+)'$",
        content,
        re.MULTILINE,
    )
    return matches == [(expected_factor, "1", expected_cells)]


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
# Obsolete IMEM init images, deleted from reused build directories.
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
    """Return whether a guided placement's PC-tail audit passes for this seed.

    Vivado physical synthesis may add, remove, or rename register replicas
    during placement, so the audit requires the same launch names and the same
    canonical (non-replica) endpoint names before and after placement, then
    the same full endpoint names across the clean checkpoint reopen. The
    ``COMPRESSED_*`` fields cover the fourteen pinned scalar-overlay launches
    of the predecode metadata.
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
        # Selected and state PC families cover all 64 architectural bits.
        # The sequential PC register holds 63 bits.
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
        == f"{X3_PLACE_REPORT_UNCERTAINTY_NS:.3f}"
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

    # Delete obsolete images left in reused build directories, and this build's
    # outputs so the existence check below sees only files this build wrote.
    retired_init_outputs = tuple(
        output_dir / name for name in IMEM_RETIRED_INIT_IMAGE_NAMES
    )
    for output_path in (*outputs.values(), *retired_init_outputs):
        output_path.unlink(missing_ok=True)

    env = os.environ.copy()
    if "RISCV_PREFIX" not in env:
        env["RISCV_PREFIX"] = default_riscv_prefix(project_root)
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


@dataclass(frozen=True)
class X3PlaceGate:
    """Post-place gate result at the actual CPU clock and zero added uncertainty."""

    passed: bool
    cpu_period_ns: Decimal
    worst_slack_ns: Decimal


def read_x3_place_gate(path: Path, expected_wns: float | None = None) -> X3PlaceGate:
    """Parse and check the six-field record that x3_post_place_gate.tcl writes.

    Raise OSError if the file is missing, and ValueError if the record is
    malformed, contradicts itself or ``expected_wns``, or used another clock
    period, threshold, or added setup uncertainty. PASS comes from Vivado's
    strict search for paths below -0.200 ns, never from the printed worst
    slack. Numbers that differ only within Vivado's three-decimal rounding
    agree; a different printed number is wrong evidence.
    """
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        key, separator, value = line.partition("=")
        if not separator or key in values:
            raise ValueError("malformed or duplicate post-place gate field")
        values[key] = value
    expected_keys = {
        "STATUS",
        "THRESHOLD_NS",
        "CPU_PERIOD_NS",
        "USER_SETUP_UNCERTAINTY_NS",
        "STRICT_BELOW_GATE_PATHS",
        "WORST_SLACK_NS",
    }
    if set(values) != expected_keys:
        raise ValueError("post-place gate must contain exactly six native fields")
    try:
        numbers = {
            key: Decimal(values[key])
            for key in (
                "THRESHOLD_NS",
                "CPU_PERIOD_NS",
                "USER_SETUP_UNCERTAINTY_NS",
                "WORST_SLACK_NS",
            )
        }
        divider = int(os.environ.get("FROST_CPU_CLK_DIV", "1"))
    except (InvalidOperation, ValueError) as error:
        raise ValueError("invalid post-place gate number or CPU divider") from error
    if not all(value.is_finite() for value in numbers.values()):
        raise ValueError("nonfinite post-place gate number")
    if divider not in CPU_CLOCK_DIV_CHOICES:
        raise ValueError("unsupported CPU divider for post-place gate")
    period = numbers["CPU_PERIOD_NS"]
    expected_period = X3_CPU_PERIOD_NS * divider
    # A divided clock's expected period is a multiple of the rounded base
    # period, so it gets a full printed digit (1 ps) of tolerance.
    tolerance = X3_GATE_DISPLAY_TOLERANCE_NS if divider == 1 else Decimal("0.001")
    if abs(period - expected_period) > tolerance:
        raise ValueError(
            "post-place CPU period does not match the selected clock and divider"
        )
    if numbers["THRESHOLD_NS"] != X3_POST_PLACE_GATE_NS or numbers[
        "USER_SETUP_UNCERTAINTY_NS"
    ] != Decimal(str(X3_PLACE_REPORT_UNCERTAINTY_NS)):
        raise ValueError("post-place gate threshold or added uncertainty differs")
    count = values["STRICT_BELOW_GATE_PATHS"]
    if count not in {"0", "1"} or values["STATUS"] != (
        "PASS" if count == "0" else "FAIL"
    ):
        raise ValueError("post-place gate status/count disagree")
    worst = numbers["WORST_SLACK_NS"]
    passed = count == "0"
    # The native strict search, not this displayed value, decides PASS; the
    # comparisons below only catch evidence that contradicts it beyond what
    # three-decimal rounding can explain.
    if (passed and worst < X3_POST_PLACE_GATE_NS - X3_GATE_DISPLAY_TOLERANCE_NS) or (
        not passed and worst > X3_POST_PLACE_GATE_NS + X3_GATE_DISPLAY_TOLERANCE_NS
    ):
        raise ValueError("post-place gate contradicts displayed worst slack")
    if (
        expected_wns is not None
        and abs(worst - Decimal(str(expected_wns))) > X3_GATE_DISPLAY_TOLERANCE_NS
    ):
        raise ValueError("post-place gate and timing report disagree")
    return X3PlaceGate(passed, period, worst)


def x3_place_gate_passes(path: Path, expected_wns: float | None = None) -> bool:
    """Return false for missing/invalid evidence or a native threshold failure."""
    try:
        return read_x3_place_gate(path, expected_wns).passed
    except (OSError, ValueError):
        return False


def file_sha256(path: Path) -> str:
    """Hash checkpoint or gate bytes without loading the checkpoint into memory."""
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def bind_x3_place_gate(work_dir: Path, expected_wns: float | None = None) -> bool:
    """Bind a valid gate record to post_place.dcp by hash; a failing gate only warns."""
    binding_path = work_dir / "post_place_gate_binding.json"
    binding_path.unlink(missing_ok=True)
    gate_path = work_dir / "post_place_gate.txt"
    try:
        gate = read_x3_place_gate(gate_path, expected_wns)
        binding = {
            "schema": "x3_post_place_gate_binding_v1",
            "checkpoint_sha256": file_sha256(work_dir / "post_place.dcp"),
            "gate_sha256": file_sha256(gate_path),
        }
    except (OSError, ValueError):
        return False
    binding_path.write_text(json.dumps(binding, indent=2) + "\n")
    if not gate.passed:
        print(
            f"Warning: post-place WNS {gate.worst_slack_ns} ns is below "
            f"{X3_POST_PLACE_GATE_NS} ns; continuing with downstream optimization."
        )
    return True


def require_x3_post_place_gate(main_work: Path) -> bool:
    """Require valid bound timing evidence; below-threshold slack only warns."""
    path = main_work / "post_place_gate.txt"
    try:
        gate = read_x3_place_gate(path)
        binding_path = main_work / "post_place_gate_binding.json"
        try:
            binding = json.loads(binding_path.read_text())
        except FileNotFoundError as error:
            raise ValueError(
                f"{binding_path.name} is missing, so the placement is "
                "unqualified: rerun the placement step, or restore the "
                "sidecar alongside the checkpoint it was written with"
            ) from error
        if binding != {
            "schema": "x3_post_place_gate_binding_v1",
            "checkpoint_sha256": file_sha256(main_work / "post_place.dcp"),
            "gate_sha256": file_sha256(path),
        }:
            raise ValueError("post-place checkpoint or gate binding changed")
    except (OSError, ValueError) as error:
        print(f"Error: x3 downstream work requires a valid {path}: {error}")
        return False
    if not gate.passed:
        print(
            f"Warning: post-place WNS {gate.worst_slack_ns} ns is below "
            f"{X3_POST_PLACE_GATE_NS} ns; continuing with downstream optimization."
        )
    return True


@dataclass(frozen=True)
class X3InputLineage:
    """The consumed parent and qualified placement captured before a launch."""

    parent: dict[str, str]
    placement: dict[str, str]


def _x3_downstream_outputs(step: str) -> set[str]:
    outputs = {STEP_PRODUCES_CHECKPOINT[step]}
    if step in FINAL_ELIGIBLE_STEPS:
        outputs.add("final.dcp")
    return outputs


def capture_x3_input_lineage(
    main_work: Path, checkpoint_name: str
) -> X3InputLineage | None:
    """Return the provenance of ``checkpoint_name``, or print why and return None.

    Follow the ``.lineage.json`` sidecars back to post_place.dcp and require
    every recorded hash to match, so an older checkpoint left on disk cannot
    pass as a descendant of a newer qualified placement.
    """
    if not require_x3_post_place_gate(main_work):
        return None
    try:
        gate_path = main_work / "post_place_gate_binding.json"
        gate_binding = json.loads(gate_path.read_text())
        placement = {
            "checkpoint_sha256": gate_binding["checkpoint_sha256"],
            "gate_sha256": gate_binding["gate_sha256"],
            "binding_sha256": file_sha256(gate_path),
        }
        downstream = STEPS[STEPS.index("place") + 1 :]
        allowed_names = {"post_place.dcp", "final.dcp"} | {
            STEP_PRODUCES_CHECKPOINT[step] for step in downstream
        }

        def verify(name: str, visited: set[str]) -> dict[str, str]:
            if name not in allowed_names or name in visited:
                raise ValueError("invalid or cyclic checkpoint lineage")
            digest = file_sha256(main_work / name)
            if name == "post_place.dcp":
                if digest != placement["checkpoint_sha256"]:
                    raise ValueError("placement changed while reading lineage")
                provenance = placement["binding_sha256"]
            else:
                sidecar = (main_work / name).with_suffix(".lineage.json")
                try:
                    raw = sidecar.read_bytes()
                except FileNotFoundError as error:
                    raise ValueError(
                        f"{name} has no {sidecar.name}: its producing stage may "
                        "still be running, or it was copied without its sidecar"
                    ) from error
                record = json.loads(raw)
                if (
                    not isinstance(record, dict)
                    or record.get("stage") not in downstream
                ):
                    raise ValueError("invalid downstream producer stage")
                stage = record["stage"]
                if name not in _x3_downstream_outputs(stage):
                    raise ValueError("checkpoint does not belong to its producer stage")
                parent = STEP_REQUIRES_CHECKPOINT[stage]
                if parent is None:
                    raise ValueError("downstream checkpoint has no parent")
                expected = {
                    "schema": "x3_checkpoint_lineage_v1",
                    "stage": stage,
                    "checkpoint": name,
                    "checkpoint_sha256": digest,
                    "parent": verify(parent, visited | {name}),
                    "placement": placement,
                }
                if record != expected:
                    raise ValueError("checkpoint, parent, or placement lineage changed")
                provenance = hashlib.sha256(raw).hexdigest()
            return {
                "checkpoint": name,
                "sha256": digest,
                "provenance_sha256": provenance,
            }

        return X3InputLineage(verify(checkpoint_name, set()), placement)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(
            f"Error: x3 {checkpoint_name} has missing or stale provenance: {error}. "
            "Rerun from post_place_physopt with the current qualified placement; "
            "existing checkpoints and reports are retained. A work directory "
            "moved or copied from elsewhere must bring its *.lineage.json "
            "sidecars and post_place_gate_binding.json with it. If post-place "
            "phys-opt is still running, wait for stage completion or use "
            "--snapshot-physopt-from WORK --build-dir NEW_DIRECTORY to route "
            "a completed sweep independently."
        )
        return None


def begin_x3_downstream_stage(main_work: Path, step: str) -> X3InputLineage | None:
    """Capture the parent and invalidate only this stage's completion sidecars."""
    parent = STEP_REQUIRES_CHECKPOINT[step]
    if parent is None:
        return None
    lineage = capture_x3_input_lineage(main_work, parent)
    if lineage is not None:
        # Tcl may publish intermediate phys-opt DCPs directly into main_work.
        # Only clean Python completion can qualify a newly produced checkpoint.
        try:
            for name in _x3_downstream_outputs(step):
                (main_work / name).with_suffix(".lineage.json").unlink(missing_ok=True)
        except OSError as error:
            print(f"Error: cannot invalidate downstream completion provenance: {error}")
            return None
    return lineage


def bind_x3_output_lineage(
    main_work: Path,
    step: str,
    checkpoint_name: str,
    source_checkpoint: Path,
    consumed: X3InputLineage,
) -> bool:
    """Qualify a promoted output only if its prelaunch input remains unchanged."""
    try:
        if checkpoint_name not in _x3_downstream_outputs(step):
            raise ValueError("unexpected downstream output name")
        if consumed.parent["checkpoint"] != STEP_REQUIRES_CHECKPOINT[step]:
            raise ValueError("captured parent does not belong to this stage")
        if source_checkpoint.name != f"{_TCL_REPORT_PREFIX[step]}.dcp":
            raise ValueError("unexpected completed worker checkpoint name")
        current = capture_x3_input_lineage(main_work, consumed.parent["checkpoint"])
        if current != consumed:
            raise ValueError("consumed parent or placement changed during the stage")
        digest = file_sha256(source_checkpoint)
        if file_sha256(main_work / checkpoint_name) != digest:
            raise ValueError(
                "promoted checkpoint differs from the completed worker output"
            )
        record = {
            "schema": "x3_checkpoint_lineage_v1",
            "stage": step,
            "checkpoint": checkpoint_name,
            "checkpoint_sha256": digest,
            "parent": consumed.parent,
            "placement": consumed.placement,
        }
        (main_work / checkpoint_name).with_suffix(".lineage.json").write_text(
            json.dumps(record, indent=2, sort_keys=True) + "\n"
        )
    except (OSError, ValueError) as error:
        print(f"Error: downstream output remains unqualified: {error}")
        return False
    return True


def snapshot_x3_physopt(source_work: Path, build_dir: Path) -> bool:
    """Copy a completed post-place phys-opt result into a new build directory.

    The source is either a finished stage, qualified by its lineage sidecar,
    or the latest completed sweep of an unfinished stage, qualified by its
    launch manifest and iteration record. Nothing in the source directory
    changes. The copy gets its own lineage sidecar, so later stages check it
    like any other checkpoint.
    """
    source_work = source_work.resolve()
    build_dir = build_dir.resolve()
    created = False
    try:
        if build_dir.exists() or build_dir.is_relative_to(source_work):
            raise ValueError("the snapshot build directory must be new and separate")
        consumed = capture_x3_input_lineage(source_work, "post_place.dcp")
        if consumed is None:
            raise ValueError("the source placement is not qualified")
        sidecar = source_work / "post_place_physopt.lineage.json"
        watched_records: dict[Path, bytes] = {}
        metadata: dict[str, object] = {
            "schema": "x3_physopt_snapshot_v1",
            "source_work": str(source_work),
        }
        if sidecar.exists():
            qualified = capture_x3_input_lineage(source_work, "post_place_physopt.dcp")
            if qualified is None:
                raise ValueError("the completed source stage has stale lineage")
            source_dir, prefix = source_work, "post_place_physopt"
            expected_digest = qualified.parent["sha256"]
            watched_records[sidecar] = sidecar.read_bytes()
            metadata["source_kind"] = "completed_stage"
        else:
            source_dir = source_work.parent / "work_post_place_physopt_Sweep"
            prefix = "phys_opt"
            launch_path = source_dir / "phys_opt_launch.json"
            iteration_path = source_dir / "phys_opt_iteration.json"
            if not launch_path.exists():
                raise ValueError(
                    "phys_opt_launch.json is missing: post-place phys-opt has "
                    "not started, or it was launched without that file and can "
                    "be snapshotted only after it finishes; no restart is needed"
                )
            if not iteration_path.exists():
                raise ValueError(
                    "phys-opt has not published a completed sweep yet; retry "
                    "after the first sweep finishes"
                )
            for path in (launch_path, iteration_path):
                watched_records[path] = path.read_bytes()
            launch = json.loads(watched_records[launch_path])
            iteration = json.loads(watched_records[iteration_path])
            run_id = launch.get("run_id")
            if (
                not isinstance(run_id, str)
                or re.fullmatch(r"[0-9a-f]{32}", run_id) is None
                or launch
                != {
                    "schema": "x3_physopt_launch_v1",
                    "run_id": run_id,
                    "parent": consumed.parent,
                    "placement": consumed.placement,
                }
                or iteration.get("schema") != "x3_physopt_iteration_v1"
                or iteration.get("run_id") != run_id
                or not isinstance(iteration.get("sweep"), int)
                or iteration["sweep"] < 1
            ):
                raise ValueError(
                    "the completed sweep does not match its qualified launch"
                )
            expected_digest = iteration["checkpoint_sha256"]
            metadata.update(
                source_kind="completed_sweep", run_id=run_id, sweep=iteration["sweep"]
            )

        source_checkpoint = source_dir / f"{prefix}.dcp"
        if file_sha256(source_checkpoint) != expected_digest:
            raise ValueError(
                "the source sweep is being replaced; retry after publication"
            )
        sources = {
            name: source_work / name
            for name in (
                "post_place.dcp",
                "post_place_gate.txt",
                "post_place_gate_binding.json",
            )
        }
        config = source_work / X3_NETLIST_CONFIG_NAME
        if config.exists():
            sources[config.name] = config
        for suffix in (
            "_timing.rpt",
            "_util.rpt",
            "_high_fanout.rpt",
            "_failing_paths.csv",
        ):
            report = source_dir / f"{prefix}{suffix}"
            if report.exists():
                sources[f"post_place_physopt{suffix}"] = report
        digests = {name: file_sha256(path) for name, path in sources.items()}

        # Copy rather than link: the running stage may rewrite the source, and a
        # symlink or hard link could then see the new content.
        build_dir.mkdir(parents=True, exist_ok=False)
        created = True
        work = build_dir / "work"
        work.mkdir()
        temporary_checkpoint = build_dir / "phys_opt.dcp"
        shutil.copy2(source_checkpoint, temporary_checkpoint)
        if file_sha256(temporary_checkpoint) != expected_digest:
            raise ValueError("the checkpoint changed while copying; retry the snapshot")
        with zipfile.ZipFile(temporary_checkpoint) as checkpoint_archive:
            if checkpoint_archive.testzip() is not None:
                raise ValueError("the completed checkpoint archive is corrupt")
        for name, path in sources.items():
            shutil.copy2(path, work / name)
            if (
                file_sha256(work / name) != digests[name]
                or file_sha256(path) != digests[name]
            ):
                raise ValueError(f"{name} changed while copying; retry the snapshot")
        if (
            file_sha256(source_checkpoint) != expected_digest
            or any(path.read_bytes() != raw for path, raw in watched_records.items())
            or capture_x3_input_lineage(source_work, "post_place.dcp") != consumed
            or capture_x3_input_lineage(work, "post_place.dcp") != consumed
        ):
            raise ValueError(
                "the source generation changed while copying; retry the snapshot"
            )
        shutil.copy2(temporary_checkpoint, work / "post_place_physopt.dcp")
        if not bind_x3_output_lineage(
            work,
            "post_place_physopt",
            "post_place_physopt.dcp",
            temporary_checkpoint,
            consumed,
        ):
            raise ValueError("could not qualify the frozen checkpoint")
        temporary_checkpoint.unlink()
        metadata["checkpoint_sha256"] = expected_digest
        (work / "physopt_snapshot.json").write_text(
            json.dumps(metadata, indent=2) + "\n"
        )
        print(f"Frozen phys-opt snapshot: {work / 'post_place_physopt.dcp'}")
        print(f"Snapshot SHA256: {expected_digest}")
        return True
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        zipfile.BadZipFile,
    ) as error:
        if created:
            shutil.rmtree(build_dir)
        print(f"Error: cannot snapshot phys-opt: {error}")
        return False


def is_reference_x3_netlist(main_work: Path) -> bool:
    """Return whether the options recorded at synthesis describe a full-rate X3 build.

    Resumed runs rely on this record rather than on their own default options.
    """
    try:
        config = json.loads((main_work / X3_NETLIST_CONFIG_NAME).read_text())
    except (OSError, ValueError):
        return False
    return (
        isinstance(config, dict)
        and config.get("schema") == "x3_netlist_config_v3"
        and config.get("cpu_base_clock_hz") == BOARD_CONFIG["x3"]["clock_freq"]
        and config.get("cpu_clock_div") == 1
    )


def require_x3_netlist_clock(main_work: Path, cpu_clock_div: int) -> bool:
    """Resume only a checkpoint built for the requested X3 clock divider."""
    try:
        config = json.loads((main_work / X3_NETLIST_CONFIG_NAME).read_text())
        if not isinstance(config, dict) or (
            config.get("cpu_base_clock_hz") != BOARD_CONFIG["x3"]["clock_freq"]
            or config.get("cpu_clock_div") != cpu_clock_div
        ):
            raise ValueError("checkpoint clock differs from the requested X3 clock")
    except (OSError, ValueError) as error:
        print(
            f"Error: cannot resume X3 clock configuration: {error}. "
            "Use the checkpoint's --cpu-clock-div or restart synthesis."
        )
        return False
    return True


def copy_results_to_main_work(
    work_dir: Path,
    main_work: Path,
    checkpoint_name: str,
    report_prefix: str,
    source_report_prefix: str | None = None,
) -> None:
    """Promote a step's checkpoint and reports into the main work directory.

    Each report name is cleared before promotion, so reports about an older
    checkpoint never remain beside a new one. A new post-opt checkpoint also
    deletes the ad hoc ``audit_post_opt_*`` and obsolete ``post_opt_fence_*``
    reports, which nothing ties to a checkpoint. A new post-synth checkpoint
    records the synthesis-time netlist options (``netlist_config.json``) that
    nothing downstream can recover.
    """
    # Promote the checkpoint under its main-directory name.
    checkpoint_candidates = []
    if source_report_prefix:
        checkpoint_candidates.append(work_dir / f"{source_report_prefix}.dcp")
    checkpoint_candidates.append(work_dir / checkpoint_name)
    if report_prefix != "post_place":
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

    if checkpoint_promoted and report_prefix == "post_synth":
        # PERF_COUNTERS is fixed at synthesis and inherited by every later
        # checkpoint and the bitstream, but no netlist, report, or bitstream
        # records it. Save the value synthesis read so a later run can tell
        # whether the profiling counters are present (perf_off_test expects
        # them absent; tomasulo_perf expects them).
        perf_counters = int(os.environ.get("FROST_PERF_COUNTERS", "0") == "1")
        (main_work / X3_NETLIST_CONFIG_NAME).write_text(
            json.dumps(
                {
                    "schema": "x3_netlist_config_v3",
                    "perf_counters": perf_counters,
                    "cpu_base_clock_hz": BOARD_CONFIG["x3"]["clock_freq"],
                    "cpu_clock_div": int(os.environ.get("FROST_CPU_CLK_DIV", "1")),
                },
                indent=2,
            )
            + "\n"
        )
        print(
            f"  Netlist options: PERF_COUNTERS={perf_counters} "
            f"({main_work / X3_NETLIST_CONFIG_NAME})"
        )

    if checkpoint_promoted and report_prefix == "post_opt":
        for stale_pattern in ("audit_post_opt_*", "post_opt_fence_*"):
            for stale_audit in main_work.glob(stale_pattern):
                if stale_audit.is_file() or stale_audit.is_symlink():
                    stale_audit.unlink()

    if checkpoint_promoted and report_prefix in {"post_synth", "post_opt"}:
        (main_work / "post_place_gate.txt").unlink(missing_ok=True)
        (main_work / "post_place_gate_binding.json").unlink(missing_ok=True)
    if report_prefix == "post_place":
        # This decision belongs to this exact promoted placement; never use
        # a glob fallback that could pick up another stage's stale evidence.
        destination = main_work / "post_place_gate.txt"
        destination.unlink(missing_ok=True)
        (main_work / "post_place_gate_binding.json").unlink(missing_ok=True)
        source_gate = work_dir / "post_place_gate.txt"
        if checkpoint_promoted and source_gate.is_file():
            shutil.copy2(source_gate, destination)
        # Audits from the diagnostic pin-swap and flush-guidance helpers cannot
        # describe this placement.
        for retired_audit in (
            "post_place_flush_guidance_audit.tcldict",
            "post_place_pin_swap_audit.txt",
        ):
            (main_work / retired_audit).unlink(missing_ok=True)
        for suffix in ("worst", "cpu", "below"):
            report_name = f"post_place_gate_{suffix}.rpt"
            destination_report = main_work / report_name
            destination_report.unlink(missing_ok=True)
            source_report = work_dir / report_name
            if checkpoint_promoted and source_report.is_file():
                shutil.copy2(source_report, destination_report)

    # Promote reports under the main-directory prefix.
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

    Both placement and router reports use actual zero added setup uncertainty.
    """
    return run.wns


def placement_seed_wns(run: DirectiveSweepRun) -> float | None:
    """Estimate seed WNS; the limiting clock/path may differ under that seed."""
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
    max_jobs: int = DEFAULT_MAX_JOBS,
) -> None:
    """Quick-route candidates at real constraints and record their timing.

    Every probe uses the same, cheapest router directive. Probe results fill
    ``quick_route_*``; promotion still uses the untouched ``post_place.dcp``.
    At most ``max_jobs`` probes run concurrently.
    """
    if max_jobs < 1:
        raise ValueError("max_jobs must be positive")
    active: list[tuple[DirectiveSweepRun, subprocess.Popen[bytes], TextIO, float]] = []
    next_candidate = 0
    try:
        while next_candidate < len(candidates) or active:
            while next_candidate < len(candidates) and len(active) < max_jobs:
                run = candidates[next_candidate]
                next_candidate += 1
                checkpoint = run.work_dir / "post_place.dcp"
                if not checkpoint.exists():
                    run.quick_route_returncode = -1
                    print(f"  quick-route skip {run.label}: missing {checkpoint}")
                    continue
                if not require_x3_post_place_gate(run.work_dir):
                    run.quick_route_returncode = -1
                    print(
                        f"  quick-route skip {run.label}: post-place gate not qualified"
                    )
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
                stdout_handle = None
                try:
                    stdout_handle = stdout_path.open("w")
                    process = subprocess.Popen(
                        command,
                        cwd=run.work_dir,
                        stdout=stdout_handle,
                        stderr=subprocess.STDOUT,
                        start_new_session=True,
                    )
                except OSError as e:
                    if stdout_handle is not None:
                        stdout_handle.close()
                    run.quick_route_returncode = -1
                    print(f"  quick-route launch failed for {run.label}: {e}")
                    continue
                active.append((run, process, stdout_handle, time.monotonic()))
                print(f"  quick-route {run.label:<30} pid={process.pid}")

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
            if active and (
                next_candidate == len(candidates) or len(active) == max_jobs
            ):
                time.sleep(5)
    except KeyboardInterrupt:
        # Use separate runtime records so cleanup cannot overwrite the
        # placement processes' return codes or elapsed times.
        probe_runs = [
            DirectiveSweepRun(
                directive=run.directive,
                label=run.label,
                work_dir=run.work_dir,
                stdout_path=run.work_dir / "quick_route_stdout.log",
                process=process,
                stdout_handle=stdout_handle,
                start_time=started,
            )
            for run, process, stdout_handle, started in active
        ]
        terminate_x3_directive_sweep_runs(probe_runs, "quick-route probes")
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
    max_jobs: int = DEFAULT_MAX_JOBS,
) -> DirectiveSweepRun | None:
    """Select the best x3 place seed with congestion awareness.

    Gate-passing seeds compete first. Optional quick-route probes only receive
    those seeds. If none passes, continue with the best measured placement.
    """
    eligible = [
        run
        for run in runs
        if run.returncode == 0
        and run.wns is not None
        and (run.work_dir / "post_place.dcp").is_file()
    ]
    if not eligible:
        return None

    for run in eligible:
        run.congestion_level = extract_max_congestion_level(
            run.work_dir / "post_place_congestion.rpt"
        )

    passing = [
        run
        for run in eligible
        if x3_place_gate_passes(run.work_dir / "post_place_gate.txt", run.wns)
    ]
    if not passing:
        print(
            f"\nNo placement meets {X3_POST_PLACE_GATE_NS} ns; "
            "selecting the best measured result."
        )
        return min(eligible, key=directive_sweep_rank_key)
    eligible = passing

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
    for run in candidates:
        bind_x3_place_gate(run.work_dir, run.wns)
    print(
        f"\nQuick-route probing the top {len(candidates)} surviving seeds "
        f"(routed WNS decides):"
    )
    run_x3_place_quick_route_probes(
        script_dir, candidates, vivado_path, max_jobs=max_jobs
    )

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
    label_width = max(30, max((len(run.label) for run in runs), default=0))

    print(f"\n{title}:")
    if show_placement_wns:
        print(
            f"{'Sel':<3} {'Directive':<{label_width}} {'Status':<10} "
            f"{'WNS@0':>9} {'Seed est.':>11} {'TNS@0':>11} "
            f"{'Cong':>5} {'RouteWNS':>9} "
            f"{'Failing EP':>14} {'Elapsed':>8}"
        )
        print("-" * (91 + label_width))
    else:
        print(
            f"{'Sel':<3} {'Directive':<{label_width}} {'Status':<10} "
            f"{'WNS(ns)':>9} {'TNS(ns)':>11} {'Failing EP':>14} {'Elapsed':>8}"
        )
        print("-" * (63 + label_width))

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
                "N/A"
                if run.congestion_level is None
                else "none"
                if run.congestion_level == 0
                else str(run.congestion_level)
            )
            route_wns = format_sweep_ns(run.quick_route_wns)
            if run.quick_route_warning:
                route_wns += "!"
            print(
                f"{selected:<3} {run.label:<{label_width}} {status:<10} "
                f"{format_sweep_ns(directive_sweep_rank_wns(run)):>9} "
                f"{format_sweep_ns(placement_seed_wns(run)):>11} "
                f"{format_sweep_ns(run.tns):>11} "
                f"{congestion:>5} {route_wns:>9} "
                f"{failing:>14} "
                f"{format_sweep_elapsed(run.elapsed_s):>8}"
            )
        else:
            print(
                f"{selected:<3} {run.label:<{label_width}} {status:<10} "
                f"{format_sweep_ns(run.wns):>9} "
                f"{format_sweep_ns(run.tns):>11} "
                f"{failing:>14} "
                f"{format_sweep_elapsed(run.elapsed_s):>8}"
            )

    if show_placement_wns:
        print(
            "    (Cong = worst reported placer congestion window level; "
            "none = no windows reported at the reporting threshold "
            "(default 5), not zero congestion; CONGVETO = disqualified by "
            "reported level; RouteWNS = quick-route probe at real "
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


def read_log_tail(path: Path, offset: int) -> tuple[str, int]:
    """Return the text appended to ``path`` since ``offset`` and the new offset.

    A missing file yields no text; a truncated one (offset past the end) is read
    again from the beginning. Partial UTF-8 at the end of a write is replaced
    rather than raised, since Vivado logs mix encodings.
    """
    try:
        size = path.stat().st_size
    except OSError:
        return "", offset
    if size < offset:
        offset = 0
    if size == offset:
        return "", offset
    with path.open("rb") as handle:
        handle.seek(offset)
        data = handle.read(size - offset)
    return data.decode("utf-8", errors="replace"), offset + len(data)


def run_x3_step_directive_sweep(
    script_dir: Path,
    step: str,
    directives: list[str],
    sweep_kind: str,
    vivado_path: str,
    keep_temps: bool = False,
    setup_uncertainties_ns: list[float] | None = None,
    include_extra_seeds: bool = True,
    max_jobs: int = DEFAULT_MAX_JOBS,
    build_dir: Path | None = None,
) -> tuple[bool, float | None, str]:
    """Run every x3 candidate with bounded concurrency and promote the best run.

    Route sweeps promote the best-WNS run. The place sweep instead uses
    congestion-aware selection (congestion veto + quick-route probes; see
    select_x3_place_best_run).

    When setup_uncertainties_ns is given, each directive is launched once per
    uncertainty value, exported to the job as FROST_PLACE_SETUP_UNCERTAINTY.
    Vivado's placer has no seed knob, so these overconstraint variants serve
    as extra placement "seeds" per directive. Eligible LOW integer-RS variants
    compete alongside their controls unless the caller sets a bloat variable.
    Each candidate performs one placement without post-place netlist edits.
    At most ``max_jobs`` Vivado processes run at once, including the later
    quick-route probes. The cap changes scheduling, not candidate selection.
    """
    if max_jobs < 1:
        raise ValueError("max_jobs must be positive")
    board_name = "x3"
    tcl_report_prefix = _TCL_REPORT_PREFIX[step]
    board_build = build_dir if build_dir is not None else script_dir / board_name
    main_work = board_build / "work"
    main_work.mkdir(parents=True, exist_ok=True)

    # Validate the input checkpoint before launching Vivado.
    if step in STEPS[STEPS.index("place") + 1 :] and not require_x3_post_place_gate(
        main_work
    ):
        return False, None, ""
    if step == "place":
        (main_work / "post_place_gate.txt").unlink(missing_ok=True)
        (main_work / "post_place_gate_binding.json").unlink(missing_ok=True)
    required_checkpoint = STEP_REQUIRES_CHECKPOINT[step]
    if required_checkpoint is None:
        print(f"Error: x3 {step} sweep requires an input checkpoint")
        return False, None, ""
    input_checkpoint = main_work / required_checkpoint
    if not input_checkpoint.exists():
        print(f"Error: Required checkpoint not found: {input_checkpoint}")
        return False, None, ""

    consumed_lineage = None
    if step in STEPS[STEPS.index("place") + 1 :]:
        consumed_lineage = begin_x3_downstream_stage(main_work, step)
        if consumed_lineage is None:
            return False, None, ""

    route_note = ""
    if step == "route":
        route_note = " (with -tns_cleanup)"
    elif step == "second_route":
        route_note = " (without -tns_cleanup)"

    print(f"\n{'=' * 70}")
    print(f"STEP: {step.upper()} - X3 {sweep_kind} directive sweep{route_note}")
    print(f"{'=' * 70}\n")

    if setup_uncertainties_ns:
        sweep_jobs = make_x3_place_sweep_candidates(
            directives,
            setup_uncertainties_ns,
            os.environ,
            include_extra_seeds=include_extra_seeds,
        )
        extra_jobs = [
            candidate
            for candidate in sweep_jobs
            if candidate.cell_bloat_factor is None
            and not (
                candidate.directive in directives
                and candidate.setup_uncertainty_ns in setup_uncertainties_ns
            )
        ]
        bloat_jobs = [
            candidate
            for candidate in sweep_jobs
            if candidate.cell_bloat_factor is not None
        ]
        uncertainty_list = ", ".join(f"{u:.3f}" for u in setup_uncertainties_ns)
        extra_list = ", ".join(candidate.label for candidate in extra_jobs)
        extra_note = f" + vetted extra seeds ({extra_list})" if extra_jobs else ""
        bloat_list = ", ".join(candidate.label for candidate in bloat_jobs)
        bloat_note = f" + LOW integer-RS variants ({bloat_list})" if bloat_jobs else ""
        print(
            f"Scheduling {len(sweep_jobs)} jobs: {len(directives)} "
            f"{sweep_kind} directives x {len(setup_uncertainties_ns)} "
            f"overconstraint seeds ({uncertainty_list} ns setup uncertainty)"
            f"{extra_note}{bloat_note}:"
        )
    else:
        sweep_jobs = [DirectiveSweepCandidate(directive) for directive in directives]
        print(f"Scheduling {len(sweep_jobs)} {sweep_kind} directive jobs:")

    print(f"  Up to {max_jobs} Vivado jobs at a time (--jobs); remaining jobs queue.")

    # A sweep of one job has nothing to compare, so its Vivado output streams
    # to the terminal instead of sitting silently in the work directory.
    stream_single_job = len(sweep_jobs) == 1
    stream_offset = 0

    runs: list[DirectiveSweepRun] = []
    next_candidate = 0
    pending: set[int] = set()
    try:
        while next_candidate < len(sweep_jobs) or pending:
            while next_candidate < len(sweep_jobs) and len(pending) < max_jobs:
                candidate = sweep_jobs[next_candidate]
                next_candidate += 1
                directive = candidate.directive
                uncertainty_ns = candidate.setup_uncertainty_ns
                pc_tail_guided = x3_place_uses_pc_tail_guidance(
                    directive, uncertainty_ns
                )
                label = candidate.label
                job_env = (
                    candidate.environment(os.environ)
                    if step == "place" or uncertainty_ns is not None
                    else None
                )

                work_dir = board_build / f"work_{step}_{label}"
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
                    cell_bloat_factor=candidate.cell_bloat_factor,
                    cell_bloat_cells=candidate.cell_bloat_cells,
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

                if run.process is not None:
                    pending.add(len(runs) - 1)
                    if stream_single_job:
                        print(f"\n--- streaming {run.label} ({run.stdout_path}) ---")
            if stream_single_job:
                text, stream_offset = read_log_tail(runs[0].stdout_path, stream_offset)
                if text:
                    sys.stdout.write(text)
                    sys.stdout.flush()
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
                if stream_single_job:
                    text, stream_offset = read_log_tail(run.stdout_path, stream_offset)
                    if text:
                        sys.stdout.write(text)
                    sys.stdout.write(f"--- end of {run.label} output ---\n")
                    sys.stdout.flush()

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

                if returncode == 0 and run.cell_bloat_factor is not None:
                    if run.cell_bloat_cells is None or not (
                        x3_place_cell_bloat_override_is_valid(
                            run.stdout_path, run.cell_bloat_factor, run.cell_bloat_cells
                        )
                    ):
                        returncode = -1
                        run.returncode = returncode
                        run.launch_error = (
                            "missing or invalid single-cell integer-RS bloat match"
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
                            f"ns, estimated WNS@seed="
                            f"{format_sweep_ns(placement_seed_wns(run))} ns, "
                            f"TNS@0={format_sweep_ns(run.tns)} ns"
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

            if pending and (
                next_candidate == len(sweep_jobs) or len(pending) == max_jobs
            ):
                time.sleep(1 if stream_single_job else 5)
    except KeyboardInterrupt:
        terminate_x3_directive_sweep_runs(runs, f"{sweep_kind} sweep")
        print(f"Interrupted; x3 {sweep_kind} sweep stopped.")
        raise SystemExit(130)

    if step == "place":
        best_run = select_x3_place_best_run(
            script_dir, runs, vivado_path, max_jobs=max_jobs
        )
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
        if best_run.congestion_level == 0:
            congestion_note = ", no congestion windows reported"
        elif best_run.congestion_level is not None:
            congestion_note = (
                f", worst reported congestion level {best_run.congestion_level}"
            )
        print(
            f"\nSelected x3 {sweep_kind} directive for {step}: {best_run.label} "
            f"(WNS@0={format_sweep_ns(directive_sweep_rank_wns(best_run))} ns, "
            f"estimated WNS@seed={format_sweep_ns(placement_seed_wns(best_run))} ns, "
            f"TNS@0={format_sweep_ns(best_run.tns)} ns"
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

    if step == "place" and not bind_x3_place_gate(main_work, best_run.wns):
        print(
            "Error: could not bind post-place timing evidence; checkpoint and reports preserved. No downstream work started."
        )
        return False, best_run.wns, report_prefix

    if consumed_lineage is not None and not bind_x3_output_lineage(
        main_work,
        step,
        checkpoint_name,
        best_run.work_dir / f"{tcl_report_prefix}.dcp",
        consumed_lineage,
    ):
        return False, best_run.wns, report_prefix

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
    build_dir: Path | None = None,
) -> tuple[bool, float | None, str]:
    """Run a single build step with the given directive.

    Returns (success, wns_ns, actual_report_prefix). actual_report_prefix is
    "final" when the step's outputs were promoted to final.dcp/final_*.rpt
    (final-eligible step + WNS>=0, or post_second_route_physopt unconditionally),
    otherwise the step's own prefix from STEP_REPORT_PREFIX.
    """
    board_build = build_dir if build_dir is not None else script_dir / board_name
    main_work = board_build / "work"
    main_work.mkdir(parents=True, exist_ok=True)

    # Validate the step's required input checkpoint.
    if (
        board_name == "x3"
        and step in STEPS[STEPS.index("place") + 1 :]
        and not require_x3_post_place_gate(main_work)
    ):
        return False, None, ""
    required_checkpoint = STEP_REQUIRES_CHECKPOINT[step]
    if required_checkpoint:
        input_checkpoint = main_work / required_checkpoint
        if not input_checkpoint.exists():
            print(f"Error: Required checkpoint not found: {input_checkpoint}")
            return False, None, ""
    else:
        input_checkpoint = None

    consumed_lineage = None
    if board_name == "x3" and step in STEPS[STEPS.index("place") + 1 :]:
        consumed_lineage = begin_x3_downstream_stage(main_work, step)
        if consumed_lineage is None:
            return False, None, ""

    tcl_report_prefix = _TCL_REPORT_PREFIX[step]
    work_dir = board_build / f"work_{step}_{directive}"
    work_dir.mkdir(parents=True, exist_ok=True)
    if board_name == "x3" and step == "place":
        for directory in (main_work, work_dir):
            (directory / "post_place_gate.txt").unlink(missing_ok=True)
            (directory / "post_place_gate_binding.json").unlink(missing_ok=True)

    print(f"\n{'=' * 70}")
    print(f"STEP: {step.upper()} — Directive: {directive}")
    print(f"{'=' * 70}\n")

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

    if step == "post_place_physopt" and consumed_lineage is not None:
        # Record the input this launch consumed. --snapshot-physopt-from uses
        # it to copy a completed sweep while this process still runs, without
        # qualifying the main directory's checkpoint, which the stage keeps
        # rewriting.
        (work_dir / "phys_opt_launch.json").write_text(
            json.dumps(
                {
                    "schema": "x3_physopt_launch_v1",
                    "run_id": uuid.uuid4().hex,
                    "parent": consumed_lineage.parent,
                    "placement": consumed_lineage.placement,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n"
        )
        (work_dir / "phys_opt_iteration.json").unlink(missing_ok=True)
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

    if (
        board_name == "x3"
        and step == "place"
        and not bind_x3_place_gate(main_work, wns)
    ):
        print(
            "Error: could not bind post-place timing evidence; checkpoint and reports preserved."
        )
        return False, wns, report_prefix

    if consumed_lineage is not None and not bind_x3_output_lineage(
        main_work,
        step,
        checkpoint_name,
        work_dir / f"{tcl_report_prefix}.dcp",
        consumed_lineage,
    ):
        return False, wns, report_prefix

    # Remove the per-step directory unless debugging was requested.
    if not keep_temps:
        shutil.rmtree(work_dir)

    return True, wns, report_prefix


def generate_bitstream(
    script_dir: Path,
    board_name: str,
    vivado_path: str,
    build_dir: Path | None = None,
) -> bool:
    """Generate bitstream from final checkpoint."""
    board_build = build_dir if build_dir is not None else script_dir / board_name
    main_work = board_build / "work"
    final_checkpoint = main_work / "final.dcp"

    if board_name == "x3" and not require_x3_post_place_gate(main_work):
        return False
    if not final_checkpoint.exists():
        print(f"Error: Final checkpoint not found: {final_checkpoint}")
        return False
    if board_name == "x3" and capture_x3_input_lineage(main_work, "final.dcp") is None:
        return False

    print(f"\n{'=' * 70}")
    print("Generating bitstream...")
    print(f"{'=' * 70}\n")

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
    # The defaults the epilog quotes.
    jobs = DEFAULT_MAX_JOBS
    gate = X3_POST_PLACE_GATE_NS
    veto = X3_PLACE_CONGESTION_VETO_LEVEL_DEFAULT
    probes = X3_PLACE_QUICK_ROUTE_COUNT_DEFAULT
    parser = argparse.ArgumentParser(
        description="FROST FPGA build script",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Steps (in order):
  synth                       - Synthesis
  opt                         - Opt design
  place                       - Place design (x3 sweeps selected placer
                                directives x uncertainty seeds, up to --jobs
                                at a time; warn below {gate} ns,
                                veto congested seeds, keep the best post-place
                                WNS; no quick-route probe by default)
  post_place_physopt          - Phys_opt sweep (always continues to route, even
                                if timing closes mid-sweep under overconstraint)
  route                       - Route design (with -tns_cleanup; x3 sweeps selected
                                router directives, up to --jobs at a time,
                                and keeps the best-WNS result)
  post_route_physopt          - Phys_opt directive sweep plus retime pass (serial)
  second_route                - Route design (without -tns_cleanup; x3 sweeps
                                selected router directives, up to --jobs at a time,
                                and keeps the best-WNS result)
  post_second_route_physopt   - Phys_opt directive sweep plus retime pass (serial);
                                always writes final.dcp + final_*.rpt + bitstream

Behavior:
  * --jobs / -j limits simultaneous Vivado processes per build (default {jobs}).
    This covers X3 placement, quick-route probes, and both router sweeps.
    Candidates queue and start as slots become free; every candidate still runs.
    Separate build invocations have independent limits. Vivado's per-process
    thread settings are unchanged. Use --jobs 1 for serial execution.
  * On x3, place ignores --place-directive. By default its grid runs
    ExtraNetDelay_high, ExtraPostPlacementOpt, AltSpreadLogic_high, and
    AltSpreadLogic_medium at six overconstraint seeds (0.500 down
    to 0.250 ns pre-place setup uncertainty in 50 ps steps). The off-grid
    ExtraPostPlacementOpt/0.425 seed is appended unless already in the grid,
    and LOW integer-RS cell-bloat variants are added beside the grid's
    ExtraNetDelay_high/0.350 and ExtraPostPlacementOpt/0.450 controls. Each
    candidate runs exactly one place_design, with any physical settings
    applied before it and no netlist or pin edits after it.
    A narrowed grid keeps a bloat variant only if its control is still there.
    --directives sets the grid to any nonempty unique subset of legal placer
    directives, and --num-uncertainties changes its seed count while keeping
    50 ps spacing. Both overrides require a run that includes place.
  * The X3 ExtraNetDelay_high/0.500, ExtraPostPlacementOpt/0.450, and
    ExtraPostPlacementOpt/0.425 candidates place with a temporary path group
    from the fourteen predecode-metadata output flops (pinned scalar LUTRAM
    overlays) to the selected, state, sequential, and pending-valid PC
    registers. The group is removed after placement. Before such a candidate
    can be scored or promoted, its audit from a clean reopen of the checkpoint
    must show no paths left in the group, all of those paths back in
    clock_from_mmcm, and the candidate's own directive and uncertainty.
  * X3 place-seed selection is congestion-aware. Among seeds that pass the
    {gate} ns gate, those whose placer congestion estimate reaches
    FROST_PLACE_CONGESTION_VETO_LEVEL (default {veto}) are dropped; if that drops
    them all, the least congested remain. FROST_PLACE_QUICK_ROUTE_COUNT
    (default {probes}) quick-routes that many of the best remaining seeds and ranks
    them by routed WNS; without probes they rank by post-place WNS. Scores and
    the promoted checkpoint and reports use zero added setup uncertainty. If
    no seed meets {gate} ns, the build warns and continues with the best one.
  * FROST_PLACE_CELL_BLOAT=LOW/MEDIUM/HIGH spreads wire-dense hierarchies
    (FROST_PLACE_CELL_BLOAT_CELLS, default *u_tomasulo/u_int_rs) in every
    candidate. Setting either variable, even to an empty value, disables the
    automatic LOW variants; an empty FROST_PLACE_CELL_BLOAT means no bloat.
    Each automatic LOW variant's log must show its bloat applied to exactly
    one cell, the integer-RS hierarchy.
  * Quick routes and every later stage, including resumed builds, require
    post_place_gate.txt and post_place_gate_binding.json, which ties the gate
    to post_place.dcp by hash. Later input checkpoints also need their
    *.lineage.json chain back to that placement; rebuild stale ones from
    post_place_physopt.
  * On x3, route and second_route ignore --route-directive and
    --second-route-directive, respectively. Each defaults to Explore,
    AggressiveExplore, NoTimingRelaxation, and AlternateCLBRouting, subject
    to --jobs, and promotes only the best-WNS checkpoint/reports.
    --route-directives overrides this list with any legal router directives.
    The route step still uses -tns_cleanup; second_route does not.
  * Every phys_opt stage runs a directive sweep that starts with
    AggressiveExplore and ends with one retime-only pass
    (phys_opt_design -retime). Each sweep keeps the best-WNS pass and stops
    early if a pass closes timing (WNS>=0). Sweeps repeat while they keep
    improving, and each completed sweep writes the current best checkpoint
    and reports.
  * Early exit: when route, post_route_physopt, or second_route closes timing,
    its outputs are promoted to final.dcp/final_*, the remaining stages are
    skipped, and the bitstream runs next.

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
        "--build-dir",
        type=Path,
        help="Board build directory containing work/ and per-stage workers "
        "(default: fpga/build/<board>). Builds in a custom directory do not "
        "update the README utilization table.",
    )
    parser.add_argument(
        "--snapshot-physopt-from",
        type=Path,
        metavar="WORK",
        help="Freeze a completed post-place phys-opt sweep from WORK into a "
        "new --build-dir before routing. Requires --start-at route; the "
        "source phys-opt may continue running in its original directory.",
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
        "--jobs",
        "-j",
        type=int,
        default=DEFAULT_MAX_JOBS,
        metavar="N",
        help="Maximum simultaneous Vivado jobs per build, including X3 place, "
        "route, and quick-route sweeps. Remaining candidates queue; "
        f"N must be positive (default: {DEFAULT_MAX_JOBS}; 1 runs serially). "
        "Does not change Vivado's per-process thread count.",
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
        "seed is still appended unless already present, and eligible LOW "
        "integer-RS variants are added beside matching grid controls. The run must include "
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
        choices=ALL_ROUTER_DIRECTIVES,
        default="AggressiveExplore",
        help="Router directive for the first route step on non-x3 boards "
        "(with -tns_cleanup, default: AggressiveExplore). Ignored on x3, "
        "which uses --route-directives or its default four-directive sweep, "
        "subject to --jobs.",
    )
    parser.add_argument(
        "--second-route-directive",
        choices=ALL_ROUTER_DIRECTIVES,
        default="Explore",
        help="Router directive for the second route step on non-x3 boards "
        "(without -tns_cleanup, default: Explore). Ignored on x3, which "
        "uses --route-directives or its default four-directive sweep, "
        "subject to --jobs.",
    )
    parser.add_argument(
        "--route-directives",
        nargs="+",
        choices=ALL_ROUTER_DIRECTIVES,
        metavar="DIRECTIVE",
        help="Set the x3 router sweep (both route stages) to these legal "
        "directives, subject to --jobs. One directive is a single route run. "
        "Default: " + ", ".join(ROUTER_SWEEP_DIRECTIVES) + ".",
    )
    parser.add_argument(
        "--debug-ila",
        action="store_true",
        help="Add the fetch debug ILA (x3): synthesis compiles in the "
        "FROST_DEBUG_FETCH_ILA mirrors of fetch, translation, commit, and trap "
        "signals and inserts one ILA on the CPU clock over every marked net; "
        "the bitstream step writes the probes file beside the bitstream. Takes "
        "effect only when the run includes synthesis. Capture with "
        "fpga/debug/capture_fetch_ila.py.",
    )
    parser.add_argument(
        "--cpu-clock-div",
        type=int,
        choices=CPU_CLOCK_DIV_CHOICES,
        default=1,
        metavar="N",
        help="Functional-validation build at 322265625 Hz divided by N (x3): the board top's "
        "CPU_CLK_DIV generic divides the MMCM output, the DDR block design "
        "declares the divided clocks, and hello_world is compiled for it. "
        "Unless --directives/--num-uncertainties/--route-directives say "
        "otherwise, runs one RuntimeOptimized placement without probes or "
        "the off-grid seed, routes with RuntimeOptimized only, and leaves "
        "the README utilization table alone. Run the board with "
        "FROST_CPU_CLK_HZ set to the divided clock.",
    )
    parser.add_argument(
        "--perf-counters",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="Include the profiling counters (the mperf* CSRs) "
        "through the board top's PERF_COUNTERS generic. Default: left out of a "
        "full-rate build, included in a --cpu-clock-div N>1 build; "
        "--no-perf-counters overrides the latter.",
    )
    parser.add_argument(
        "--physopt-directive",
        choices=PHYS_OPT_DIRECTIVES,
        default="AggressiveExplore",
        help="Ignored: every phys_opt stage (post_place, post_route, "
        "post_second_route) runs a directive sweep plus a retime-only pass. "
        "Kept for backward compatibility.",
    )
    args = parser.parse_args()

    if os.environ.get("FROST_CPU_BASE_CLK_HZ"):
        parser.error(
            "FROST_CPU_BASE_CLK_HZ is no longer supported; X3 uses 322265625 Hz. "
            "Unset it and use --cpu-clock-div for a divided-clock build."
        )
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if args.snapshot_physopt_from is not None and (
        args.build_dir is None or args.start_at != "route"
    ):
        parser.error(
            "--snapshot-physopt-from requires --build-dir and --start-at route"
        )
    if args.build_dir is not None:
        args.build_dir = args.build_dir.resolve()

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
    route_sweep_directives = resolve_x3_route_sweep_directives(args.route_directives)
    if args.cpu_clock_div != 1 and board_name != "x3":
        parser.error("--cpu-clock-div is only supported for x3")
    functional_policy = resolve_functional_build_policy(
        args.cpu_clock_div,
        clock_freq,
        place_sweep_directives,
        place_uncertainty_count,
        placer_sweep_overridden,
        route_sweep_directives,
        args.route_directives is not None,
        perf_counters=args.perf_counters,
    )
    clock_freq = functional_policy.clock_freq
    place_sweep_directives = functional_policy.place_directives
    place_uncertainty_count = functional_policy.place_uncertainty_count
    place_setup_uncertainties_ns = make_x3_place_setup_uncertainties_ns(
        place_uncertainty_count
    )
    route_sweep_directives = functional_policy.route_directives
    if args.debug_ila:
        if board_name != "x3":
            parser.error("--debug-ila is only supported for x3")
        if "synth" not in steps_to_run:
            print(
                "# Note: --debug-ila takes effect at synthesis; this run starts "
                f"at '{args.start_at}' and keeps the checkpoint's debug cores"
            )
        os.environ["FROST_DEBUG_ILA"] = "1"
    if board_name == "x3":
        # The CLI is authoritative even at divider 1; an inherited override
        # must not silently change synthesis/BD clocks away from the board rate.
        os.environ["FROST_CPU_CLK_DIV"] = str(functional_policy.cpu_clock_div)
    # The CLI is authoritative for the counters as well: synthesis reads
    # FROST_PERF_COUNTERS, and an inherited value must not change the netlist.
    os.environ["FROST_PERF_COUNTERS"] = "1" if functional_policy.perf_counters else "0"
    if functional_policy.cpu_clock_div != 1:
        # The Vivado steps (synthesis generic, block-design clock rates) and
        # the quick-route probe count read the environment.
        if functional_policy.quick_route_count is not None:
            os.environ.setdefault(
                "FROST_PLACE_QUICK_ROUTE_COUNT",
                str(functional_policy.quick_route_count),
            )
    if board_name == "x3":
        place_directive = "Sweep"
        route_directive = "Sweep"
        second_route_directive = "Sweep"
    else:
        place_directive = args.place_directive or "ExtraTimingOpt"
        route_directive = args.route_directive
        second_route_directive = args.second_route_directive

    # build_step.tcl runs the phys-opt sweeps itself; ``Sweep`` only labels their
    # banners and work directories.
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

    print(f"\n{'#' * 70}")
    print(f"# FROST FPGA Build — {board_name.upper()}")
    print(f"# Clock: {clock_freq:,} Hz")
    if functional_policy.cpu_clock_div != 1:
        print(
            f"# Functional-validation build: CPU clock divided by "
            f"{functional_policy.cpu_clock_div} (CPU_CLK_DIV generic); run the "
            f"board with FROST_CPU_CLK_HZ={clock_freq}"
        )
    if "synth" not in steps_to_run:
        print(
            "# Note: the profiling counters follow the checkpoint's netlist; "
            "--perf-counters takes effect at synthesis"
        )
    elif functional_policy.perf_counters:
        print("# Profiling counters included (PERF_COUNTERS generic)")
    if args.debug_ila:
        print("# Fetch ILA: FROST_DEBUG_FETCH_ILA mirrors + one ILA on main_clock")
    print(f"# UltraScale: {'Yes' if is_ultrascale else 'No'}")
    directives_summary = [
        f"{s}={d}" for s, d in step_directives.items() if d != "Default"
    ]
    if directives_summary:
        print(f"# Directives: {', '.join(directives_summary)}")
    print(f"# Vivado concurrency: up to {args.jobs} jobs at a time (--jobs)")
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
            "use --route-directives to restrict the router sweep."
        )
    if board_name == "x3" and args.second_route_directive != "Explore":
        print(
            "# Note: --second-route-directive is ignored for x3; "
            "use --route-directives to restrict the router sweep."
        )
    if board_name == "x3" and route_sweep_directives != ROUTER_SWEEP_DIRECTIVES:
        print(f"# X3 router sweep (custom): {', '.join(route_sweep_directives)}")
    print(f"{'#' * 70}")

    build_options = {"build_dir": args.build_dir} if args.build_dir is not None else {}
    board_build = (
        args.build_dir if args.build_dir is not None else script_dir / board_name
    )
    main_work = board_build / "work"
    if args.snapshot_physopt_from is not None and not snapshot_x3_physopt(
        args.snapshot_physopt_from, board_build
    ):
        sys.exit(1)
    if args.build_dir is not None:
        print(f"Build directory: {board_build}")
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
        if board_name == "x3" and not require_x3_netlist_clock(
            main_work, functional_policy.cpu_clock_div
        ):
            sys.exit(1)

    # Execute the requested pipeline range.
    final_produced = False
    bitstream_generated = False
    last_report_prefix = None
    for step in steps_to_run:
        directive = step_directives[step]
        retiming = args.retiming if step == "synth" else False

        if (
            board_name == "x3"
            and step in STEPS[STEPS.index("place") + 1 :]
            and not require_x3_post_place_gate(main_work)
        ):
            sys.exit(1)

        if board_name == "x3" and step == "place":
            success, wns, actual_prefix = run_x3_step_directive_sweep(
                script_dir,
                step,
                place_sweep_directives,
                "placer",
                args.vivado_path,
                keep_temps=args.keep_temps,
                setup_uncertainties_ns=place_setup_uncertainties_ns,
                include_extra_seeds=functional_policy.include_extra_seeds,
                max_jobs=args.jobs,
                **build_options,
            )
        elif board_name == "x3" and step in {"route", "second_route"}:
            success, wns, actual_prefix = run_x3_step_directive_sweep(
                script_dir,
                step,
                route_sweep_directives,
                "router",
                args.vivado_path,
                keep_temps=args.keep_temps,
                max_jobs=args.jobs,
                **build_options,
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
                **build_options,
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
                    f"\nTiming met at {step}; skipping the remaining stages: "
                    f"{', '.join(remaining)}"
                )
            break

    if final_produced:
        if not generate_bitstream(
            script_dir, board_name, args.vivado_path, **build_options
        ):
            sys.exit(1)
        bitstream_generated = True

    # Refresh the active board from this invocation's last completed stage;
    # resumed/partial builds may leave stale later-stage reports in work/.
    from extract_timing_and_util_summary import (
        collect_all_board_utilization,
        update_readme_utilization,
    )

    reference_netlist = board_name != "x3" or is_reference_x3_netlist(main_work)
    if functional_policy.update_readme and args.build_dir is None and reference_netlist:
        all_util = collect_all_board_utilization(
            script_dir,
            stage_overrides={board_name: last_report_prefix}
            if last_report_prefix
            else None,
        )
        if all_util:
            update_readme_utilization(script_dir, all_util)
    else:
        print(
            "\nREADME utilization table not updated: it tracks only full-rate "
            "builds in the default build directory whose netlist_config.json "
            "records the reference configuration."
        )

    # Summarize the last completed step, including partial/resumed runs.
    print(f"\n{'#' * 70}")
    print("# BUILD COMPLETE!")
    print(f"{'#' * 70}")

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
