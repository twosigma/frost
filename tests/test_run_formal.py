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

"""Run SymbiYosys targets directly or through pytest.

Runs bounded checks, unbounded proofs and cover searches. Each .sby file in
formal/ is one target and defines its tasks; the properties and assumptions
live in the RTL (under `ifdef FORMAL` or a proof define) or in the harnesses
in formal/.
"""

import difflib
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, replace
from itertools import zip_longest
from pathlib import Path
from typing import Any

import pytest

import ci_reuse
import l0_store_boundary
import sby_config
from formal_predicates import (
    PredicateExemption,
    harness_tokens,
    predicate_spans,
    resolve_predicate_sites,
)
from sby_config import SCRIPT_FORMS, UNDEFINED_CONSTANT

# Path to the formal/ directory relative to the repository root
FORMAL_DIR = "formal"

# Per-task hang backstop in seconds; proof depth is set by each .sby file.
SBY_TASK_TIMEOUT_S = 2400
# Slow control, data and composed tasks have measured allowances in their
# SBY files and separate CI jobs. Keep the runner's backstops in sync with
# those files and document the budgets and depths in formal/README.md.
SBY_TASK_TIMEOUT_OVERRIDES_S = {
    ("imem_predecode_twin", "imem_predecode_live"): 60,
    ("l0_store_boundary_twin", "boundary_twin"): 60,
    ("coherence_store_bank", "coh_store_bank_class_bmc"): 3600,
    ("coherence_dma_ingress", "coh_dma_ingress_soc_prove"): 3120,
    ("pd_target_candidate_twin", "pdt_twin"): 60,
    ("decoded_bundle_queue_twin", "dbq_twin"): 60,
    ("cached_tier_adapter_twin", "cached_tier_twin"): 60,
    ("cached_tier_adapter_twin", "cached_tier_unsplit"): 60,
    ("coherent_store_pma_twin", "store_pma_twin_ddr30"): 60,
    ("coherent_store_pma_twin", "store_pma_twin_ddr31"): 60,
    ("control_flow_tracker_twin", "cft_twin"): 60,
    ("data_mem_request_router_twin", "router_twin"): 60,
    ("csr_file_twin", "csr_twin"): 60,
    ("csr_file_twin", "csr_twin_vector"): 60,
    ("fp_engine_twin", "fp_engine_twin"): 60,
    ("pc_controller_twin", "pc_controller_twin"): 120,
    ("pc_controller_twin", "pc_controller_twin_slot2"): 120,
    ("store_queue_twin", "sq_twin"): 120,
    ("store_queue_twin", "sq_twin_cpu"): 120,
    ("id_stage_kill_equiv", "id_kill_equiv"): 120,
    ("id_stage_kill_equiv", "id_kill_equiv_vector"): 120,
    ("immu_twin", "immu_twin"): 180,
    ("immu_twin", "immu_twin_hold"): 180,
    ("coherence_home_engine_twin", "home_engine_twin32"): 240,
    ("coherence_home_engine_twin", "home_engine_twin64"): 240,
    ("coherence_home_engine_twin", "home_engine_twin40"): 240,
    ("dmmu_twin", "dmmu_twin"): 240,
    ("coherence_l1d_twin", "l1d_twin_single"): 600,
    ("coherence_l1d_twin", "l1d_twin_multi"): 600,
    ("coherence_l1d_twin", "l1d_twin_stream"): 600,
    ("reservation_station_twin", "rs_twin_indexed"): 600,
    ("branch_predictor_twin", "bp_twin"): 900,
    ("coherence_home_twin", "home_twin_small"): 600,
    ("coherence_home_twin", "home_twin_four"): 2400,
    ("coherence_home_twin", "home_twin_addr40"): 600,
    ("coherence_sc_wa", "sc_wa_s0_prove"): 600,
    ("coherence_sc_wa", "sc_wa_s1_prove"): 600,
    ("coherence_sc_wa", "sc_wa_s2_prove"): 600,
    ("coherence_sc_wa", "sc_wa_s3_prove"): 600,
    ("coherence_sc_wa", "sc_wa_s0_cover"): 1200,
    ("coherence_sc_wa", "sc_wa_s1_cover"): 1200,
    ("coherence_sc_wa", "sc_wa_s2_cover"): 1200,
    ("coherence_sc_wa", "sc_wa_s3_cover"): 1200,
    ("coherence_home", "coh_home_control_prove"): 1800,
    ("coherence_home", "coh_home_control64_prove"): 1800,
    ("coherence_home", "coh_home_control_partition_prove"): 1800,
    ("coherence_home", "coh_home_control_ultra_prove"): 900,
    ("coherence_home", "coh_home_control_ultra_fast_prove"): 900,
    ("coherence_home", "coh_home_control_fast_prove"): 1800,
    ("coherence_home", "coh_home_control64_fast_prove"): 1800,
    ("coherence_home", "coh_home_control_partition_fast_prove"): 1800,
    ("coherence_home", "coh_home_fill_cover"): 1800,
    ("coherence_home", "coh_home_control4_bmc"): 1200,
    ("coherence_home", "coh_home_control4_ultra_bmc"): 1200,
    ("coherence_home", "coh_home_control4_ultra_fast_bmc"): 1200,
    ("coherence_home", "coh_home_prefetch_cover"): 1200,
    ("coherence_home", "coh_home_fast_cover"): 600,
    ("coherence_home", "coh_home_wb_prove"): 180,
    ("coherence_home", "coh_home_victim_cover"): 180,
    ("coherence_home", "coh_home_error_cover"): 180,
    ("coherence_l1d", "coh_l1d_perf_prove"): 120,
    ("csr_file", "bmc"): 5400,
    ("csr_file", "bmc_perf_off"): 5400,
    ("csr_file", "vector_bmc"): 5400,
    ("reorder_buffer", "bmc"): 5400,
    ("rob_retire_successor", "bmc"): 3600,
    ("tomasulo_wrapper_commit_bus", "bmc"): 180,
    ("tomasulo_wrapper_commit_bus", "cover"): 360,
    ("coherence_home", "coh_home_cmo_cover"): 6000,
    ("coherence_home", "coh_home_cmo_fast_cover"): 600,
    ("coherent_hart_cache", "coh_hart_maint_prove"): 7200,
    ("coherent_hart_cache", "coh_hart_maint_owned_prove"): 1200,
    ("coherent_hart_cache", "coh_hart_maint_free_owned_prove"): 7200,
    ("coherent_hart_cache", "coh_hart_maint_free_prove"): 7200,
    ("coherent_hart_cache", "coh_hart_maint_four_bmc"): 7200,
    ("coherence_l1d", "coh_l1d_stream_bmc"): 5100,
    ("coherence_l1d", "coh_l1d_stream_hold_bmc"): 3600,
    ("coherence_l1d", "coh_l1d_stream_cover"): 1200,
    ("coherence_l1d", "coh_l1d_stream_free_nostore_bmc"): 3600,
    ("coherence_l1d", "coh_l1d_stream_free_nostore_hold_bmc"): 3600,
    ("coherence_l1d", "coh_l1d_stream_free_bmc"): 10800,
    ("coherence_array", "coh_array4_port_bmc"): 6000,
    ("coherence_l1d", "coh_l1d_bmc"): 14400,
    ("coherence_l1d", "coh_l1d_multi_bmc"): 20400,
    ("coherence_l1d", "coh_l1d_local_control_bmc"): 3600,
    ("coherence_l1d", "coh_l1d_data_bmc"): 3900,
    ("coherence_l1d", "coh_l1d_data1_bmc"): 3900,
    ("coherence_l1d", "coh_l1d_data2_bmc"): 3900,
    ("coherence_l1d", "coh_l1d_data3_bmc"): 3900,
    ("coherence_l1d", "coh_l1d_store_payload_bmc"): 900,
    ("coherence_l1d", "coh_l1d_store_grant_bmc"): 1200,
    ("coherence_l1d", "coh_l1d_store_multi_payload_bmc"): 1800,
    ("coherence_l1d", "coh_l1d_store_multi_grant_bmc"): 3600,
    ("coherence_l1d", "coh_l1d_multi_data0_bmc"): 4200,
    ("coherence_l1d", "coh_l1d_multi_data1_bmc"): 4200,
    ("coherence_l1d", "coh_l1d_multi_data2_bmc"): 4200,
    ("coherence_l1d", "coh_l1d_multi_data3_bmc"): 4200,
    ("coherence_l1d", "coh_l1d_ways_data_bmc"): 5100,
    ("coherence_l1d", "coh_l1d_zero_bmc"): 10800,
    ("coherence_l1d", "coh_l1d_zero_multi_bmc"): 18000,
    ("coherence_l1d", "coh_l1d_zero_cover"): 14400,
    ("coherence_l1d", "coh_l1d_full_bmc"): 10800,
    ("coherence_l1d", "coh_l1d_full_multi_bmc"): 18000,
    ("coherence_l1d", "coh_l1d_zero_payload_bmc"): 5400,
    ("coherence_l1d", "coh_l1d_full_payload_bmc"): 5700,
    ("coherence_l1d", "coh_l1d_full_cover"): 7200,
    ("coherence_l1d", "coh_l1d_full_lookahead_cover"): 7200,
    ("coherence_l1d", "coh_l1d_withdraw_full_bmc"): 10800,
    ("coherence_l1d", "coh_l1d_withdraw_zero_bmc"): 10800,
    ("coherence_l1d", "coh_l1d_withdraw_full_payload_bmc"): 5400,
    ("coherence_l1d", "coh_l1d_withdraw_zero_payload_bmc"): 5400,
    ("coherence_l1d", "coh_l1d_withdraw_full_cover"): 5160,
    ("coherence_l1d", "coh_l1d_full_hold_cover"): 1200,
    ("coherence_l1d", "coh_l1d_buffer_contract_bmc"): 900,
    ("coherence_l1d", "coh_l1d_zero_stream_line_bmc"): 3600,
    ("coherence_l1d", "coh_l1d_zero_stream_upper_ep0_bmc"): 6120,
    ("coherence_l1d", "coh_l1d_zero_stream_upper_ep1_read_bmc"): 2100,
    ("coherence_l1d", "coh_l1d_zero_stream_upper_ep1_store_bmc"): 600,
    ("coherence_l1d", "coh_l1d_zero_stream_upper_ep1_lookahead_bmc"): 300,
    ("coherence_l1d", "coh_l1d_zero_stream_upper_ep1_prefetch_bmc"): 300,
    ("coherence_l1d", "coh_l1d_zero_stream_upper_ep1_rest_bmc"): 300,
    ("coherence_l1d", "coh_l1d_zero_stream_upper_ep2_bmc"): 1500,
    ("coherence_l1d", "coh_l1d_answer_bmc"): 3600,
    ("coherence_l1d", "coh_l1d_stream_answer_bmc"): 3600,
    ("coherence_store_boundary", "bmc_four_control"): 3600,
    ("coherence_store_boundary", "bmc_four_value_0"): 15840,
    ("coherence_store_boundary", "bmc_four_value_1"): 10800,
    ("coherence_store_boundary", "bmc_four_value_2"): 8400,
    ("coherence_store_boundary", "bmc_four_value_3"): 3600,
    ("coherence_store_boundary", "cover_four"): 7200,
    ("coherence_store_boundary", "bmc_intervening_same_flow"): 8400,
    ("coherence_store_boundary", "bmc_intervening_other_flow"): 13200,
    ("coherence_store_boundary", "bmc_intervening_same_value"): 10800,
    ("coherence_store_boundary", "bmc_intervening_other_value"): 15840,
    ("coherence_store_boundary", "bmc_intervening_fatal"): 1200,
    ("coherence_store_boundary", "bmc_amo_same"): 6600,
    ("coherence_store_boundary", "bmc_amo_other"): 9600,
    ("coherence_store_boundary", "bmc_amo_same_owner"): 3000,
    ("coherence_store_boundary", "bmc_amo_same_fatal"): 3000,
    ("coherence_store_boundary", "bmc_amo_other_fatal"): 4800,
    ("coherence_store_boundary", "bmc_load_same_probe_launch"): 3600,
    ("coherence_store_boundary", "bmc_probe_kept_same"): 5400,
    ("coherence_store_boundary", "bmc_probe_kept_other"): 8400,
    ("coherence_store_boundary", "bmc_sc"): 6000,
    ("coherence_store_home", "bmc_siblings"): 900,
    ("coherence_store_home", "bmc_siblings_second"): 900,
    ("coherence_store_home", "bmc_rows"): 900,
    ("coherence_store_home", "bmc_rows_second"): 900,
    ("coherence_store_home", "bmc_conflict"): 900,
    ("coherence_store_home", "bmc_conflict_second"): 900,
    ("coherence_store_home", "bmc_pressure"): 900,
    ("coherence_store_home", "bmc_pressure_second"): 900,
    ("coherence_store_home", "link_bmc_siblings"): 900,
    ("coherence_store_home", "link_bmc_siblings_second"): 900,
    ("coherence_store_home", "link_bmc_pressure"): 900,
    ("coherence_store_home", "link_bmc_pressure_second"): 900,
    ("coherence_store_home", "cover_conflict"): 900,
    ("coherence_store_home", "cover_pressure"): 900,
    ("coherence_store_home", "link_cover_pressure"): 900,
    ("line_client_link", "line_link0_bmc"): 5280,
    ("line_client_link", "line_link1_bmc"): 4200,
    ("line_client_link", "line_link1_four_bmc"): 4200,
    ("line_client_link", "line_link1_eight_bmc"): 4200,
    ("rs_issue_tag_banks", "int_equiv"): 600,
    ("rs_issue_tag_banks", "int_equiv_prims"): 600,
    ("rs_issue_tag_copies", "prove"): 600,
    ("rs_mem_broadcast", "prove"): 300,
    ("rs_mem_broadcast", "prove_prims"): 300,
    ("rs_mem_broadcast", "cover"): 90,
    ("store_completion_cofactor", "prove"): 60,
    ("store_completion_cofactor", "cover"): 120,
}


@dataclass(frozen=True)
class FormalTarget:
    """A formal verification target defined by an .sby file."""

    sby_file: str  # Filename of the .sby file (e.g., "trap_unit.sby")
    description: str  # Human-readable description
    tasks: tuple[str, ...] = ("bmc", "cover")  # Tasks this target supports

    @property
    def name(self) -> str:
        """Short name derived from the .sby filename."""
        return Path(self.sby_file).stem


# Registry of formal verification targets.
# Each entry maps to an .sby file in the formal/ directory.
FORMAL_TARGETS = [
    FormalTarget(
        "coherence_link.sby",
        "Hart and home links: wires at zero stages; order, payload, latency and credits per kind.",
        tasks=(
            "link_zero_prove",
            "link_always1_prove",
            "link_always2_prove",
            "link_credit1_bmc",
            "link_credit2_bmc",
            "link_one1_prove",
            "link_one2_prove",
            "link_mirror1_prove",
            "link_mirror2_prove",
            "link_credit1_cover",
            "link_mirror1_cover",
        ),
    ),
    FormalTarget(
        "coherence_sc_wa.sby",
        "Composed L1D, home engine, completions, arbiters and links prove SC GrantM writeback exclusion.",
        tasks=(
            "sc_wa_s0_prove",
            "sc_wa_s1_prove",
            "sc_wa_s2_prove",
            "sc_wa_s3_prove",
            "sc_wa_s0_cover",
            "sc_wa_s1_cover",
            "sc_wa_s2_cover",
            "sc_wa_s3_cover",
        ),
    ),
    FormalTarget(
        "coherence_prefetch_pause.sby",
        "DMA credits and seven idle cycles gate prefetch admission.",
        tasks=("pf_pause_prove", "pf_pause_cover"),
    ),
    FormalTarget(
        "coherence_prefetch_agent.sby",
        "Prefetch identities, held requests, error completion and reset at both line sizes.",
        tasks=(
            "pf_agent64_prove",
            "pf_agent32_prove",
            "pf_agent1_prove",
            "pf_agent2_prove",
            "pf_agent4_prove",
            "pf_agent64_cover",
            "pf_agent32_cover",
        ),
    ),
    FormalTarget(
        "coherent_local_owners.sby",
        "Two-owner permission, evicted reservations and observation replay under the shared-home contract.",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "coherent_local_atomic.sby",
        "Local ownership progresses through production CPU memory dependencies beside held probes and grants.",
        tasks=("amo_bmc", "sc_bmc", "amo_cover", "sc_cover", "reservation_prove"),
    ),
    FormalTarget(
        "coherence_store_home.sby",
        "Production private and home caches preserve streamed bytes through replacement and DMA.",
        tasks=(
            "bmc_siblings",
            "bmc_siblings_second",
            "bmc_rows",
            "bmc_rows_second",
            "bmc_conflict",
            "bmc_conflict_second",
            "cover_siblings",
            "cover_rows",
            "cover_conflict",
            "bmc_pressure",
            "bmc_pressure_second",
            "cover_pressure",
            "link_bmc_siblings",
            "link_bmc_siblings_second",
            "link_bmc_pressure",
            "link_bmc_pressure_second",
            "link_cover_pressure",
        ),
    ),
    FormalTarget(
        "coherence_store_boundary.sby",
        "Production SQ, router, buffered L1D and LQ preserve credit, drain and atomic exclusion.",
        tasks=(
            "bmc_four_control",
            "bmc_four_value_0",
            "bmc_four_value_1",
            "bmc_four_value_2",
            "bmc_four_value_3",
            "cover_four",
            "bmc_intervening_same_flow",
            "bmc_intervening_other_flow",
            "bmc_intervening_same_value",
            "bmc_intervening_other_value",
            "bmc_intervening_fatal",
            "prove_intervening_fatal_sticky",
            "bmc_load_same",
            "bmc_load_other",
            "bmc_load_same_probe_launch",
            "bmc_probe_kept_other",
            "bmc_probe_kept_same",
            "bmc_amo_same",
            "bmc_amo_same_owner",
            "bmc_amo_same_fatal",
            "prove_amo_same_fatal_sticky",
            "bmc_amo_other",
            "bmc_amo_other_fatal",
            "prove_amo_other_fatal_sticky",
            "bmc_sc",
            "bmc_old",
            "cover_load",
            "cover_old",
            "cover_amo",
            "cover_amo_same",
            "cover_amo_same_two",
            "cover_amo_other_home",
            "cover_sc",
            "cover_edges_same",
            "cover_edges_same_combined",
            "cover_edges_other",
            "cover_probe_kept_other",
            "cover_probe_kept_same",
        ),
    ),
    FormalTarget(
        "coherence_store_buffer.sby",
        "Four combining records preserve byte order, bounded contributors, launch credit and acknowledgement.",
        tasks=("prove", "cover", "store_saturation_bmc", "store_saturation_cover"),
    ),
    FormalTarget(
        "coherent_hart_cache.sby",
        "Fence ordering and coherent instruction/PTE visibility, supported by independent data ownership lemmas.",
        tasks=(
            "coh_hart_maint_prove",
            "coh_hart_maint_owned_prove",
            "coh_hart_maint_owned_reset_prove",
            "coh_hart_maint_free_owned_prove",
            "coh_hart_maint_free_prove",
            "coh_hart_maint_cover",
            "coh_hart_maint_four_bmc",
            "coh_hart_maint_four_cover",
            "coh_hart_snapshot_bmc",
            "coh_hart_snapshot_cover",
        ),
    ),
    FormalTarget(
        "cpu_axi_payload.sby",
        "Occupied read-buffer payload equals owned-response capture through reset and backpressure",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "early_backend_hold.sby",
        "Combined backend hold equals early recovery or independently sampled fatal "
        "stop through reset and flush. A coherent not-taken launch redirects to "
        "its issued PC plus the instruction length",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "early_redirect_completion.sby",
        "An accepted early redirect flushes younger entries by tag on the next "
        "edge or an older full flush supersedes it",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "wfi_commit_guard.sby",
        "The WFI resume-PC arm satisfies the ROB's recovery and full-flush "
        "retirement qualification. A head WFI cannot retire during an early redirect, "
        "commit recovery, or flush.",
        tasks=("prove", "cover", "retirement_prove", "retirement_cover"),
    ),
    FormalTarget(
        "rob_wfi_head_ready.sby",
        "Accepted WFI allocations complete and a nonexceptional WFI head is stored-ready",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "debug_go_pipeline.sby",
        "Registered debug GO keeps its command or resume target, holds until "
        "acknowledgement, and clears on acknowledgement or module reset",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "debug_fetch_barrier.sby",
        "Debug go follows fetch invalidation, preserves its target, and handles "
        "withdrawal and reset without replay",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "coherent_rs_payload.sby",
        "Coherent second-issue payload equals two-write banked storage.",
        tasks=(
            "coh_rs_payload4_prove",
            "coh_rs_payload8_prove",
            "coh_rs_payload16_prove",
            "coh_rs_payload_wide_prove",
        ),
    ),
    FormalTarget(
        "coherent_rs_control.sby",
        "Coherent allocation masks, issue metadata and controls, shift and count equality.",
        tasks=(
            "coh_rs_control_prove",
            "coh_rs_control_int_prove",
            "coh_rs_control_window_prove",
            "coh_rs_control_partial_prove",
            "coh_rs_control_mul_prove",
        ),
    ),
    FormalTarget(
        "coherent_rs_issue2_selector.sby",
        "Coherent second-issue selection equals the tree and serial references.",
        tasks=(
            "coh_rs_issue2_8_prove",
            "coh_rs_issue2_16_prove",
            "coh_rs_issue2_5_prove",
            "coh_rs_issue2_2_prove",
            "coh_rs_issue2_3_prove",
        ),
    ),
    FormalTarget(
        "coherent_debug_request_count.sby",
        "Coherent debug request count equality, including modulo wrap and reset.",
        tasks=("debug_request_count_prove", "debug_request_count4_prove"),
    ),
    FormalTarget(
        "coherent_rs_capacity.sby",
        "Coherent reservation-station count and full flags match issue/dispatch arithmetic.",
        tasks=(
            "coh_rs_capacity4_prove",
            "coh_rs_capacity8_prove",
            "coh_rs_capacity16_prove",
        ),
    ),
    FormalTarget(
        "debug_dirty_next.sby",
        "Debug dirty-word next-state equality for arbitrary control inputs.",
        tasks=("debug_dirty_next_prove",),
    ),
    FormalTarget(
        "debug_store_mirror_hold.sby",
        "Debug mirror validity and occupied address equality.",
        tasks=("mirror_hold_prove", "mirror_hold15_prove", "mirror_hold32_prove"),
    ),
    FormalTarget(
        "coherence_read_capture.sby",
        "Read-slot capture, the Idle phase and operation selection, per-slot kinds and registered array responses equal their references.",
        tasks=(
            "coh_read_capture_prove",
            "coh_read_capture_stream_prove",
            "coh_idle_select_prove",
            "coh_idle_select_stream_prove",
            "coh_idle_phase_prove",
            "coh_idle_phase_stream_prove",
            "coh_read_kind_prove",
            "coh_array_reply_prove",
            "coh_array_reply4_prove",
            "coh_array_reply_uram_prove",
            "coh_array_reply4_uram_prove",
        ),
    ),
    FormalTarget(
        "coherence_read_payload.sby",
        "Buffered coherent read payloads and exports equal independent reference storage.",
        tasks=("coh_read_payload_prove", "coh_read_payload64_prove"),
    ),
    FormalTarget(
        "coherent_l0.sby",
        "L0 validity and invalidation masks at two cache depths.",
        tasks=(
            "coh_l0_flags_prove",
            "coh_l0_flags256_prove",
        ),
    ),
    FormalTarget(
        "coherent_cpu.sby",
        "Coherent SC ownership, load selection, address/PBMT classification, parking, and reservation cuts.",
        tasks=(
            "coh_sc_selected_prove",
            "coh_sc_class_small_prove",
            "coh_sc_class_offset_prove",
            "coh_sc_class_size_prove",
            "coh_sc_class_zero_prove",
            "coh_sc_class_wrap_prove",
            "coh_lq_cut_prove",
            "coh_lq_forward_prove",
            "coh_lq_forward_normal_prove",
            "coh_lq_busy_prove",
            "coh_lq_normal_fill_prove",
            "coh_lq_cut_probe_launch_prove",
            "coh_lq_forward_probe_launch_prove",
            "coh_lq_forward_normal_probe_launch_prove",
            "coh_lq_busy_probe_launch_prove",
            "coh_lq_normal_fill_probe_launch_prove",
            "coh_address_class_prove",
            "coh_candidate_select_prove",
            "coh_lq_selector_prove",
            "coh_lq_selector4_prove",
            "coh_lq_selector16_prove",
        ),
    ),
    FormalTarget(
        "coherence_read_stream.sby",
        "Ascending demand streams stay within the look-ahead window and physical page.",
        tasks=("stream_prove", "stream_cover"),
    ),
    FormalTarget(
        "coherence_l1d.sby",
        "The coherent L1 preserves pending stores, cuts, and exact atomic writes.",
        tasks=(
            "coh_l1d_perf_prove",
            "coh_l1d_conflict_prove",
            "coh_l1d_conflict_multi_prove",
            "coh_l1d_conflict_stream_prove",
            "coh_l1d_bmc",
            "coh_l1d_multi_bmc",
            "coh_l1d_stream_bmc",
            "coh_l1d_stream_hold_bmc",
            "coh_l1d_stream_free_bmc",
            "coh_l1d_stream_free_nostore_bmc",
            "coh_l1d_stream_free_nostore_hold_bmc",
            "coh_l1d_stream_owned_prove",
            "coh_l1d_stream_snapshot_prove",
            "coh_l1d_stream_prove",
            "coh_l1d_stream_outlier_prove",
            "coh_l1d_stream_cover",
            "coh_l1d_snapshot_cover",
            "coh_l1d_turn_cover",
            "coh_l1d_local_prove",
            "coh_l1d_local_multi_prove",
            "coh_l1d_local_owned_prove",
            "coh_l1d_local_multi_owned_prove",
            "coh_l1d_local_ways_owned_prove",
            "coh_l1d_local_sector_prove",
            "coh_l1d_local_multi_sector_prove",
            "coh_l1d_local_ways_sector_prove",
            "coh_l1d_local_cover",
            "coh_l1d_local_data_bmc",
            "coh_l1d_local_hold_bmc",
            "coh_l1d_local_control_bmc",
            "coh_l1d_local_ways_prove",
            "coh_l1d_cover",
            "coh_l1d_path_cover",
            "coh_l1d_put_select_prove",
            "coh_l1d_data_bmc",
            "coh_l1d_data1_bmc",
            "coh_l1d_data2_bmc",
            "coh_l1d_data3_bmc",
            "coh_l1d_store_payload_bmc",
            "coh_l1d_store_grant_bmc",
            "coh_l1d_store_multi_payload_bmc",
            "coh_l1d_store_multi_grant_bmc",
            "coh_l1d_multi_data0_bmc",
            "coh_l1d_multi_data1_bmc",
            "coh_l1d_multi_data2_bmc",
            "coh_l1d_multi_data3_bmc",
            "coh_l1d_ways_data_bmc",
            "coh_l1d_zero_bmc",
            "coh_l1d_zero_multi_bmc",
            "coh_l1d_zero_payload_bmc",
            "coh_l1d_zero_cover",
            "coh_l1d_zero_lookahead_cover",
            "coh_l1d_zero_stream_hint_bmc",
            "coh_l1d_zero_stream_line_bmc",
            "coh_l1d_zero_stream_upper_ep0_bmc",
            "coh_l1d_zero_stream_upper_ep1_read_bmc",
            "coh_l1d_zero_stream_upper_ep1_store_bmc",
            "coh_l1d_zero_stream_upper_ep1_lookahead_bmc",
            "coh_l1d_zero_stream_upper_ep1_prefetch_bmc",
            "coh_l1d_zero_stream_upper_ep1_rest_bmc",
            "coh_l1d_zero_stream_upper_ep2_bmc",
            "coh_l1d_zero_progress_cover",
            "coh_l1d_zero_stream_bmc",
            "coh_l1d_zero_request_cover",
            "coh_l1d_full_bmc",
            "coh_l1d_full_multi_bmc",
            "coh_l1d_full_payload_bmc",
            "coh_l1d_full_cover",
            "coh_l1d_full_lookahead_cover",
            "coh_l1d_withdraw_full_bmc",
            "coh_l1d_withdraw_zero_bmc",
            "coh_l1d_withdraw_full_payload_bmc",
            "coh_l1d_withdraw_zero_payload_bmc",
            "coh_l1d_withdraw_full_cover",
            "coh_l1d_full_hold_cover",
            "coh_l1d_buffer_contract_bmc",
            "coh_l1d_answer_bmc",
            "coh_l1d_stream_answer_bmc",
        ),
    ),
    FormalTarget(
        "coherence_l1d_lookup.sby",
        "The L1D lookup address and head readiness match the one-chain reference.",
        tasks=("lookup_prove", "lookup_multi_prove", "lookup_stream_prove"),
    ),
    FormalTarget(
        "coherence_home_select.sby",
        "Seat admission and circular work selection, in encoded and one-hot form, "
        "match serial priority.",
        tasks=("coh_seat_select_prove", "coh_work_select_prove"),
    ),
    FormalTarget(
        "coherence_home_completions.sby",
        "Independent completion identities, predecessor order, result ownership, "
        "and prefetch slots.",
        tasks=(
            "coh_completions_prove",
            "coh_completions_pairs_prove",
            "coh_completions_partition_prove",
            "coh_completions_partition2_prove",
            "coh_completions_fast_prove",
            "coh_completions_fast_partition_prove",
            "coh_completions_cover",
            "coh_completions_partition_cover",
            "coh_completions_partition2_cover",
            "coh_completions_fast_cover",
            "coh_if_pair_cover",
        ),
    ),
    FormalTarget(
        "coherence_home_forward_pins.sby",
        "Per-fill forward priority matches the reference for arbitrary ready/later masks.",
        tasks=(
            "coh_home_forward1_prove",
            "coh_home_forward3_prove",
            "coh_home_forward8_prove",
            "coh_home_forward1_xilinx_prove",
            "coh_home_forward3_xilinx_prove",
            "coh_home_forward8_xilinx_prove",
        ),
    ),
    FormalTarget(
        "coherence_home.sby",
        "The coherent home preserves pins, dirty replies, and victim ownership.",
        tasks=(
            "coh_home_control_prove",
            "coh_home_control64_prove",
            "coh_home_control_partition_prove",
            "coh_home_control_ultra_prove",
            "coh_home_control_ultra_fast_prove",
            "coh_home_control_fast_prove",
            "coh_home_control64_fast_prove",
            "coh_home_control_partition_fast_prove",
            "coh_home_control4_bmc",
            "coh_home_control4_ultra_bmc",
            "coh_home_control4_ultra_fast_bmc",
            "coh_home_fill_cover",
            "coh_home_cmo_cover",
            "coh_home_cmo_fast_cover",
            "coh_home_wb_prove",
            "coh_home_victim_cover",
            "coh_home_error_cover",
            "coh_home_prefetch_cover",
            "coh_home_dispatch_cover",
            "coh_home_fast_cover",
        ),
    ),
    FormalTarget(
        "coherence_dma_ingress.sby",
        "DMA issue order, opaque identities, independent completion, and reset ownership; "
        "the same for the hart's two- and eight-identity line client.",
        tasks=(
            "coh_dma_ingress_prove",
            "coh_dma_ingress_cover",
            "coh_dma_ingress_soc_prove",
            "coh_dma_ingress_soc_cover",
            "coh_line_client_prove",
            "coh_line_client_eight_prove",
            "coh_line_client_cover",
            "coh_line_client_eight_cover",
        ),
    ),
    FormalTarget(
        "coherence_home_engine.sby",
        "Resident image merges, independent probe/data arrival, quick result offers, "
        "and held service payloads.",
        tasks=(
            "coh_home_engine_prove",
            "coh_home_engine64_prove",
            "coh_home_engine_cover",
        ),
    ),
    FormalTarget(
        "coherence_home_array.sby",
        "Independent L2 ports and one- and four-way parallel UltraRAM reads preserve "
        "byte values, tokens and physical-row exclusions. An open read at the output "
        "follows a stalled reply.",
        tasks=(
            "coh_home_array_prove",
            *(f"coh_home_array_uram_byte{lane}_prove" for lane in range(64)),
            *(f"coh_home_array_uram4_byte{lane}_prove" for lane in (0, 31, 32, 63)),
            "coh_home_array_cover",
            "coh_home_array_uram_cover",
        ),
    ),
    FormalTarget(
        "coherence_array_plru.sby",
        "Deferred hit touches preserve replacement values at every lookup.",
        tasks=(
            "coh_array_plru_prove",
            "coh_array_plru_uram_prove",
            "coh_array_plru_bimodal_prove",
            "coh_array_plru_port_prove",
            "coh_array_plru_cover",
            "coh_array_plru_uram_cover",
            "coh_array_plru_bimodal_cover",
            "coh_array_plru_port_cover",
        ),
    ),
    FormalTarget(
        "coherence_snapshot.sby",
        "A four-way L1D and the home retain and publish successive store versions.",
        tasks=("coh_snapshot_versions_bmc", "coh_snapshot_versions_cover"),
    ),
    FormalTarget(
        "coherence_array.sby",
        "Serialized array byte values and exact conditional data selection.",
        tasks=(
            "coh_array_select_prove",
            "coh_array_select4_prove",
            "coh_array_select56_prove",
            "coh_array_select4_56_prove",
            "coh_array_bmc",
            "coh_array_uram_bmc",
            "coh_array4_bmc",
            "coh_array4_uram_bmc",
            "coh_array_port_bmc",
            "coh_array4_port_bmc",
            "coh_array_cover",
            "coh_array_uram_cover",
            "coh_array4_port_cover",
            "coh_array4_snapshot_cover",
            "coh_array4_uram_snapshot_cover",
        ),
    ),
    FormalTarget(
        "coherence_array_progress.sby",
        "Controller progress with independent load streams and a common victim history.",
        tasks=(
            "coh_progress_prove",
            "coh_progress4_prove",
            "coh_progress4_56_prove",
            "coh_progress4_cover",
        ),
    ),
    FormalTarget(
        "coherence_store_bank.sby",
        "Store lookup classification and isolation of invalid bank data from consumers.",
        tasks=(
            "coh_store_bank_taint_prove",
            "coh_store_bank_class_bmc",
            "coh_store_bank_cover",
        ),
    ),
    FormalTarget(
        "coherence_array_equiv.sby",
        "The array matches its reference with one data RAM and whole replacement writes.",
        tasks=(
            "coh_array_equiv_bmc",
            "coh_array_equiv_data0_bmc",
            "coh_array_equiv_data31_bmc",
            "coh_array_equiv4_bmc",
            "coh_array_equiv4_data0_bmc",
            "coh_array_equiv4_data17_bmc",
            "coh_array_equiv4_bimodal_bmc",
            "coh_array_equiv_uram_bmc",
            "coh_array_equiv_uram_data5_bmc",
            "coh_array_equiv4_uram_bmc",
            "coh_array_equiv_port_bmc",
            "coh_array_equiv_port_data0_bmc",
            "coh_array_equiv_cover",
        ),
    ),
    FormalTarget(
        "coherence_control.sby",
        "Coherent request arbitration, bridge lifetime, and atomic protection.",
        tasks=(
            "coh_c_payload_prove",
            "coh_c_payload_wide_prove",
            "coh_arbiter_prove",
            "coh_arbiter24_prove",
            "coh_arbiter_held_prove",
            "coh_arbiter_bypass_prove",
            "coh_reader_prove",
            "coh_reader_cover",
            "coh_reader_slot1_prove",
            "coh_reader_slot1_cover",
            "coh_ptw_reader_prove",
            "coh_ptw_reader_cover",
            "coh_ptw_reader_slot1_prove",
            "coh_ptw_reader_slot1_cover",
            "coh_reader_late_prove",
            "coh_ingress_prove",
            "coh_atomic_guard_prove",
            "coh_atomic_select_prove",
            "coh_atomic_select_wide_prove",
            "coh_atomic_pair_prove",
            "coh_atomic_pair_wide_prove",
            "coh_read_flags_prove",
            "coh_read_select_prove",
            "coh_read_select64_prove",
            "coh_read_select_xilinx_prove",
            "coh_read_select64_xilinx_prove",
            "coh_grant_select2_prove",
            "coh_grant_select4_prove",
            "coh_grant_select8_prove",
            "coh_read_owners1_prove",
            "coh_read_owners3_prove",
            "coh_read_owners4_prove",
            "coh_read_owners8_prove",
            "coh_miss_credit1_prove",
            "coh_miss_credit3_prove",
            "coh_miss_credit4_prove",
            "coh_miss_credit8_prove",
        ),
    ),
    FormalTarget(
        "coherence_endpoints.sby",
        "Coherent endpoint payloads, identities and cancellation lifetimes",
        tasks=(
            "request_prove",
            "request_cover",
            "request_equiv32",
            "request_equiv56",
            "request_equiv_slot0",
            "request_equiv_wide_slot0",
            "request_equiv_ptw",
            "request_equiv_wide_ptw",
            "request_equiv_cover",
            "home_prove",
            "home_cover",
            "put_prove",
            "put_cover",
            "channel_prove",
            "channel_cover",
            "home_wide",
            "home_pending_prove",
            "home_pending_wide_prove",
            "home_pending_cover",
            "layout32",
            "layout56",
        ),
    ),
    FormalTarget(
        "uncached_read_capture.sby",
        "Uncached read ownership preserves enqueue, handoff, and reset priority",
        tasks=("bmc",),
    ),
    FormalTarget(
        "rs_lq_prematch.sby",
        "MEM reservation-station and load-queue pre-issue matches agree with the "
        "reference CAM",
        tasks=("bmc", "prove"),
    ),
    FormalTarget(
        "rob_retire_ready.sby",
        "ROB retirement eligibility and head masks match the reference",
        tasks=("prove",),
    ),
    FormalTarget(
        "fetch_shadow_capture.sby",
        "Fetch shadows and grouped direct-cache writes match qualified captures; "
        "indexed hits match complete tags",
        tasks=(
            "prove",
            "cover",
            "prove_victim0",
            "prove_victim1",
            "prove_direct",
            "cover_direct",
        ),
    ),
    FormalTarget(
        "sq_live_count.sby",
        "Store-queue live count and its staged removal mask match the reference arithmetic",
        tasks=("bmc", "bmc_cpu"),
    ),
    FormalTarget(
        "sq_committed_empty.sby",
        "Store-queue committed-empty state matches the reference through flush and commit",
        tasks=("bmc",),
    ),
    FormalTarget(
        "sq_next_same.sby",
        "Store-queue sent bits and same-sector claim match the reference updates",
        tasks=("bmc", "bmc_cpu"),
    ),
    FormalTarget(
        "pc_pending_capture.sby",
        "Pending-prediction capture matches reference clear/set/hold priority, including "
        "walked-past entries",
        tasks=("bmc", "bmc_integrated"),
    ),
    FormalTarget(
        "rs_issue_clear.sby",
        "RS second-issue entry clearing matches the reference across station sizes",
        tasks=("bmc", "bmc4", "bmc8", "bmc16", "bmc32"),
    ),
    FormalTarget(
        "rs_dispatch_defer.sby",
        "Dispatch CDB deferral matches the reference with insertion-time repair on or "
        "off",
        tasks=("bmc", "bmc_repair"),
    ),
    FormalTarget(
        "control_flow_holdoff.sby",
        "Reset and redirect holdoffs match the reference with late prediction flags",
        tasks=("bmc",),
    ),
    FormalTarget(
        "rob_retire_stall.sby",
        "ROB retirement strobes and performance events match the serializer-stall "
        "reference",
        tasks=("bmc",),
    ),
    FormalTarget(
        "rob_control_next.sby",
        "ROB entry control state follows reference write priority",
        tasks=("bmc",),
    ),
    FormalTarget(
        "csr_commit_cofactor.sby",
        "Selected CSR commit updates match reference transitions under each interface "
        "contract, including VECTOR=1",
        tasks=("prove", "prove_integrated", "prove_perf_off", "prove_vector"),
    ),
    FormalTarget(
        "csr_sscofpmf.sby",
        "Sscofpmf counter overflow, OF stickiness, inhibits, privilege attribution "
        "and LCOFIP updates hold from arbitrary state",
        tasks=("prove", "prove_integrated", "prove_perf_off"),
    ),
    FormalTarget(
        "pc_increment_relation.sby",
        "PC increment comparisons and selection match full-width arithmetic, including "
        "wraparound",
        tasks=("generic32", "generic64"),
    ),
    FormalTarget(
        "pc_increment_holdoff.sby",
        "Sequential fetch PCs match the reference under reset and redirect holdoffs",
        tasks=("bmc", "bmc_xilinx"),
    ),
    FormalTarget(
        "rs_raw_pretag.sby",
        "Raw wakeup tags and ready vectors match merged-lane reservation-station "
        "selection",
        tasks=("bmc", "bmc_export", "bmc_ready_vector"),
    ),
    FormalTarget(
        "lq_ram_payload.sby",
        "Load-result RAM writes and CDB values match reference selection",
        tasks=("bmc", "bmc_forward", "bmc_forward_only", "bmc_core", "cover"),
    ),
    FormalTarget(
        "lq_result_valid.sby",
        "Load-result validity matches completion and allocation priorities for arbitrary state.",
        tasks=(
            "result4_prove",
            "result8_prove",
            "result16_prove",
            "result_no_forward_prove",
            "result_no_l0_prove",
            "result_plain_prove",
            "result8_xilinx_prove",
        ),
    ),
    FormalTarget(
        "lq_result_pins.sby",
        "Completion, response and allocation LUTs match their portable equations.",
        tasks=("result_pins_prove", "result_pins_xilinx_prove"),
    ),
    FormalTarget(
        "lq_sector_copy.sby",
        "The staged load's registered sector matches equal its entry's matches.",
        tasks=("sector_copy_prove", "sector_copy_xilinx_prove"),
    ),
    FormalTarget(
        "lq_age_groups.sby",
        "Entry eligibility and grouped age selection match their direct equations.",
        tasks=("age_groups_prove", "age_groups_xilinx_prove"),
    ),
    FormalTarget(
        "lq_capture.sby",
        "Capture choices, clear outputs, completion validity, bypass eligibility, entry release and staged "
        "next state match the reference for arbitrary current state.",
        tasks=(
            "coh_lq_capture4_prove",
            "coh_lq_capture8_prove",
            "coh_lq_capture16_prove",
            "coh_lq_capture_no_forward_prove",
            "coh_lq_capture_no_l0_prove",
            "coh_lq_capture_plain_prove",
            "coh_lq_capture8_xilinx_prove",
        ),
    ),
    FormalTarget(
        "lq_l0_lookup.sby",
        "L0 validity selection and permission match the indexed reference for arbitrary inputs.",
        tasks=(
            "lookup8_prove",
            "lookup8_xilinx_prove",
            "lookup16_prove",
            "lookup16_xilinx_prove",
            "lookup32_prove",
            "lookup32_xilinx_prove",
            "lookup128_prove",
            "lookup128_xilinx_prove",
            "lookup256_prove",
            "lookup256_xilinx_prove",
            "lookup512_prove",
            "lookup512_xilinx_prove",
        ),
    ),
    FormalTarget(
        "lq_capture_pins.sby",
        "Capture, in-flight, release and staged-copy choices match independent pin equations.",
        tasks=("capture_pins_prove", "capture_pins_xilinx_prove"),
    ),
    FormalTarget(
        "lq_replace_select.sby",
        "Load-queue replacement matches reference head and ring-position priority",
        tasks=("bmc4", "bmc8", "bmc16"),
    ),
    FormalTarget(
        "cache_mshr_payload.sby",
        "Readable MSHR bytes match reference fill/store merging",
        tasks=("bmc", "bmc_mshr8"),
    ),
    FormalTarget(
        "cache_way_choice.sby",
        "A completing allocation avoids the owned-way mask, the factored completion "
        "matches its reference, a touched way is not the next victim, and the "
        "restricted victim walk keeps the pseudo-LRU way when it is unowned",
        tasks=("bmc", "bmc_ways1", "bmc_delayed"),
    ),
    FormalTarget(
        "cache_flash_valid.sby",
        "Flash-valid assignment checks and independent watched-line hit exclusion "
        "after invalidation, with install/invalidate/refill covers in each mode",
        tasks=(
            "bmc_fast",
            "bmc_fast_ways1",
            "bmc_hw",
            "cover_fast",
            "cover_fast_ways1",
            "cover_hw",
        ),
    ),
    FormalTarget(
        "lq_alloc_mask.sby",
        "Load-queue allocation masks and capacity checks match the reference search",
        tasks=("bmc4", "bmc8", "bmc16"),
    ),
    FormalTarget(
        "lq_normal_fill_policy.sby",
        "Early Normal-PMA classification preserves the selected-response L0 fill policy",
        tasks=("bmc_strict", "bmc_normal", "bmc_legacy"),
    ),
    FormalTarget(
        "lq_response_bypass.sby",
        "Load-response bypass matches full acceptance under the partial-flush guard",
        tasks=("bmc",),
    ),
    FormalTarget(
        "lq_capacity.sby",
        "Load-queue capacity flags match exact free-entry counts",
        tasks=("bmc",),
    ),
    FormalTarget(
        "if_direction_payload.sby",
        "Branch-direction payload selection preserves live and replayed non-NOP "
        "packets",
        tasks=("bmc", "prove"),
    ),
    FormalTarget(
        "if_fault_ras_veto.sby",
        "Fetch-faulted IF packets never carry a predicted-taken flag or operate "
        "the return-address stack, and intact if_stage makes the slot-2 veto redundant",
        tasks=("bmc", "cover", "prove", "prove_slot2_veto_redundant"),
    ),
    FormalTarget(
        "mispredict_capture.sby",
        "Recovery payload, pulse copies, frontend flush and registered fetch flush "
        "match their references",
        tasks=("bmc", "prove"),
    ),
    FormalTarget(
        "line_arbiter_grant.sby",
        "Two- and three-port line arbitration matches bounded-starvation priority",
        tasks=("bmc", "bmc_xilinx", "bmc_2port", "bmc_xilinx_2port"),
    ),
    FormalTarget(
        "lq_cached_flags.sby",
        "Cached-load invalidation and LR suppression match reference state updates",
        tasks=("bmc",),
    ),
    FormalTarget(
        "lq_prematch_cofactors.sby",
        "Load-queue pre-issue matches and registered selection match the reference CAM",
        tasks=(
            "bmc",
            "prove",
            "bmc_raw",
            "prove_raw",
            "pick8_bmc",
            "pick8_prove",
            "pick4_bmc",
            "pick4_prove",
            "pickg4_bmc",
            "pickg4_prove",
            "pickg6_bmc",
            "pickg6_prove",
        ),
    ),
    FormalTarget(
        "lq_cached_hold.sby",
        "Cached-load hold state matches the full slot-mask reference",
        tasks=("bmc",),
    ),
    FormalTarget(
        "prediction_metadata_output.sby",
        "Prediction taken bits match the reference and apply only to the matching "
        "packet",
        tasks=("bmc",),
    ),
    FormalTarget(
        "c_ext_buffer_next.sby",
        "Compressed-instruction slot-2 buffer updates match reference priority",
        tasks=("bmc",),
    ),
    FormalTarget(
        "sq_repair_mmio.sby",
        "Store-repair MMIO classification matches full-width address addition",
        tasks=("bmc",),
    ),
    FormalTarget(
        "dmmu_mmio.sby",
        "Data-MMU MMIO classification, leaf checks, address splitting, and fault capture match the "
        "reference",
        tasks=("bmc",),
    ),
    FormalTarget(
        "dmmu_capture.sby",
        "Data-MMU registered packets, one-cycle bypass, invalidation and preceding LQ "
        "look-ahead agree across arbitrary issue, flush and TLB answers",
        tasks=("bmc", "prove", "cover"),
    ),
    FormalTarget(
        "dmmu_bypass.sby",
        "Sum-addressed DTLB selection and S2 results agree with an ordinary lookup, "
        "including a replay through the real S1 port",
        tasks=("prove", "bmc", "cover"),
    ),
    FormalTarget(
        "dmmu_va_next.sby",
        "Data-MMU S1 load and S2 VA next states, selected after the issue address, "
        "equal the whole-payload selects, portable and primitive forms",
        tasks=("bmc", "bmc_xilinx"),
    ),
    FormalTarget(
        "rs_alloc_parallel.sby",
        "Parallel RS allocation indices match the serial free-entry search",
        tasks=("bmc4", "bmc8", "bmc16", "bmc32"),
    ),
    FormalTarget(
        "rs_pretag_cofactor.sby",
        "RS pre-issue tags and readiness match reference CDB priority selection",
        tasks=(
            "bmc",
            "bmc_tag_indexed",
            "bmc_export",
            "bmc_export_tag_indexed",
            "bmc_ready_vector",
        ),
    ),
    FormalTarget(
        "lq_tag_order.sby",
        "Load-queue tag ordering and full-window detection match extended arithmetic",
        tasks=("bmc",),
    ),
    FormalTarget(
        "ras_checkpoint.sby",
        "Return-stack outputs and state updates match the checkpoint reference",
        tasks=("bmc",),
    ),
    FormalTarget(
        "ras_flush_checkpoint.sby",
        "A full flush restores the return stack to the oldest discarded checkpoint",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "low_bram_presenter_tier.sby",
        "Low-BRAM fetch responses match with separate address retargeting on or off",
        tasks=("bmc", "prove"),
    ),
    FormalTarget(
        "imem_predecode_twin.sby",
        "IMEM fetch data and registered bank select match the frozen live cone",
        tasks=("imem_predecode_live",),
    ),
    FormalTarget(
        "rvc_predecode.sby",
        "RV64C/Zcb/Zcmop expansion and source metadata match every parcel; MOPs permit pairing",
        tasks=("bmc",),
    ),
    FormalTarget(
        "dispatch_admission.sby",
        "Bundle, station and checkpoint admission match the encoded station types "
        "with local or registered selects, and slot 2 uses no FP source 3",
        tasks=("bmc", "bmc_queued", "bmc_queued_vector"),
    ),
    FormalTarget(
        "instr_operand_classifier.sby",
        "Direct instruction operand classes match operation decoding and fault "
        "overrides, without and with the vector floating-point decode",
        tasks=("bmc", "vector_bmc"),
    ),
    FormalTarget(
        "decoded_bundle_queue.sby",
        "Decoded bundles preserve FIFO order through bypass, backpressure, flush, and "
        "wraparound",
        tasks=("prove", "prove_depth2", "cover"),
    ),
    FormalTarget(
        "id_stage_kill_equiv.sby",
        "ID post-classifier kill masking equals in-classifier legality and fault "
        "overrides across both slots and all stage outputs, without and with the vector "
        "floating-point decode",
        tasks=("id_kill_equiv", "id_kill_equiv_vector"),
    ),
    FormalTarget(
        "vec_vtype_tracker.sby",
        "A surviving vector allocation (integer, FP, crypto, vector-to-scalar, load or "
        "store) clears restart state across delayed architectural reload and "
        "checkpoint recovery; the tracked vtype follows "
        "configuration allocation, flush, reload and restore",
        tasks=("bmc", "prove", "cover"),
    ),
    FormalTarget(
        "vec_lmul_legality_equiv.sby",
        "Vector arithmetic legality, including FP and cryptographic element groups at each vector length, equals the reference "
        "for every vtype and instruction; dispatch applies it with the VTOX and "
        "nonzero-vstart rules. The registered legality and restart classes match "
        "the current queue head whenever it is ready",
        tasks=("bmc", "prove", "cover"),
    ),
    FormalTarget(
        "vec_vmu.sby",
        "Vector sector order, identity conservation and stalled preparation registers",
        tasks=("bmc", "cover"),
    ),
    FormalTarget(
        "vec_head_mmu.sby",
        "Head vector translation before access, precise partial faults, commit shield "
        "and consumption of every commit; strided and indexed element runs in order with "
        "each element translated first, mid-run interrupt boundaries, precise mid-run "
        "faults and pointer masking",
        tasks=(
            "bmc",
            "cover",
            "stride_bmc",
            "stride_cover",
            "index_bmc",
            "index_cover",
        ),
    ),
    FormalTarget(
        "vec_hold_rows.sby",
        "Vector range holds: an older live vector memory table entry holds an "
        "atomic scalar entry or one with an unknown address, unknown vector range, "
        "or overlap. A settled hold has such a cause in either queue. The cleanup "
        "covers forbid head advancement on rollback edges",
        tasks=("vhold_lq_bmc", "vhold_sq_bmc", "vhold_lq_cover", "cover"),
    ),
    FormalTarget(
        "vec_vmt.sby",
        "Vector memory table lifecycle: allocation into free entries, retirement "
        "exactly as the head passes, registered flush cleanup, fixed ranges and the exact "
        "no-live-retired-entry output",
        tasks=("vmt_bmc", "cover"),
    ),
    FormalTarget(
        "cl_multiplier.sby",
        "Carry-less result slices and three-stage valid alignment",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "int_muldiv_shim.sby",
        "MUL/DIV completion tracking, data alignment, and backpressure",
        tasks=(
            "prove",
            "prove_alignment",
            "prove_fallback",
            "prove_alignment_fallback",
            "prove_direct",
            "prove_alignment_direct",
            "prove_direct_fallback",
            "prove_alignment_direct_fallback",
            "cover_direct",
            "cover",
        ),
    ),
    FormalTarget(
        "mem_wakeup_merge.sby",
        "Early load wakeup preserves registered CDB results and adds at most one "
        "matching value",
        tasks=("bmc",),
    ),
    FormalTarget(
        "trap_unit.sby",
        "Trap-unit exception and interrupt handling, the CSR entry enables in "
        "every state, and the trap value with its pointer-masking transform after "
        "the register",
        tasks=("bmc", "cover", "prove"),
    ),
    FormalTarget(
        "csr_file.sby",
        "CSR state and access behavior with profiling counters on or off, and "
        "with the vector state",
        tasks=(
            "bmc",
            "cover",
            "bmc_perf_off",
            "vector_bmc",
            "vector_cover",
            "pm_mode_bmc",
        ),
    ),
    FormalTarget(
        "tlb.sby",
        "TLB entry tracking and lookup selection in DTLB and ITLB configurations",
        tasks=("bmc", "cover", "bmc_itlb", "cover_itlb"),
    ),
    FormalTarget(
        "dtlb_entry_verdict.sby",
        "Registered DTLB entry validity, permissions and whole-leaf PMA verdicts "
        "against the data lookup for an arbitrary access on two DDR maps",
        tasks=("prove", "cover", "prove_256m", "cover_256m"),
    ),
    FormalTarget(
        "l2tlb.sby",
        "Second-level TLB hits are backed by a fill no flush has removed, return the "
        "filled data, and never run during a flush; the shared walk port selects "
        "its VPN from registered state and delays an instruction walk one cycle "
        "at most",
        tasks=("bmc", "cover", "walk_select_prove", "walk_select_cover"),
    ),
    FormalTarget(
        "ptw_pbmt_alias.sby",
        "Svpbmt alias decode on enabled maps and NC/IO leaf faults on the small map",
        tasks=(
            "bmc_small",
            "bmc_1g",
            "bmc_4g",
            "bmc_8g",
            "bmc_16g",
            "bmc_32g",
            "bmc_64g",
            "bmc_128g",
        ),
    ),
    FormalTarget(
        "ptw.sby",
        "Page-table walk state matches reference PTE classification, including the "
        "Svnapot PPN substitution, Svpbmt reserved encodings, PBMTE and the uncached alias. "
        "The walk cache holds only valid pointers and clears on every discard. "
        "Covers reach a successful Svnapot response with the substituted PPN and leaf permissions.",
        tasks=(
            "bmc",
            "cover",
            "bmc_nopwc",
            "bmc_replace",
            "bmc_wide",
            "cover_wide",
            "bmc_2g",
            "cover_2g",
            "bmc_external",
            "cover_external",
        ),
    ),
    FormalTarget(
        "reorder_buffer.sby",
        "In-order ROB commit and instruction serialization",
    ),
    FormalTarget(
        "rob_retire_successor.sby",
        "Each ROB commit is at the architectural next PC of the one before it",
    ),
    FormalTarget(
        "rob_start_cofactor.sby",
        "ROB CSR/return start signals match the reference and exclude completion "
        "bypass",
        tasks=("prove",),
    ),
    FormalTarget(
        "register_alias_table.sby",
        "Register renaming and checkpoint recovery",
    ),
    FormalTarget(
        "rs_issue2_selector.sby",
        "INT-RS second-issue selection matches a serial reference",
        tasks=("bmc",),
    ),
    FormalTarget(
        "line_client_link.sby",
        "The hart's line client through its links at zero and one stage against an "
        "abstract home: legal identities, never one already live, C after G, every "
        "always-taken G and U taken, one response per request",
        tasks=(
            "line_link0_bmc",
            "line_link1_bmc",
            "line_link1_four_bmc",
            "line_link1_eight_bmc",
            "line_link1_cover",
        ),
    ),
    FormalTarget(
        "home_capture_equiv.sby",
        "Consumed home payloads match handshake-only captures, and registered "
        "fill flags match their phase decodes across arbitrary reset and stalls. "
        "Array covers reach hit and row captures in every configuration and kept "
        "parallel captures in both banked configurations. "
        "The parked next-state function preserves event priority; selected-slot "
        "parking, the one-hot selection, dispatch and waiter eligibility match a "
        "slot-table reference.",
        tasks=(
            "home_small",
            "home_four",
            "home_default",
            "array_bram",
            "array_bram_four",
            "array_uram",
            "array_uram32",
            "array_uram_row",
            "array_bram_cover",
            "array_bram_four_cover",
            "array_uram_cover",
            "array_uram32_cover",
            "array_uram_row_cover",
            "endpoint32",
            "endpoint56",
            "arbiter_default",
            "arbiter_idle",
            "completions_two",
            "completions_three",
            "completions_default",
        ),
    ),
    FormalTarget(
        "home_forward_next_equiv.sby",
        "The home's forward-turn next state, formed for both outcomes of the memory "
        "response and selected last, equals the single-ready-set form at eight and "
        "three fills, portable and primitive",
        tasks=("bmc", "bmc_fills3", "bmc_xilinx"),
    ),
    FormalTarget(
        "home_seat_next_equiv.sby",
        "The home's fill waiter masks, seat counts and parking, formed for both "
        "values of the decision's late term and selected last, equal the original "
        "form, and the fill images' next state equals the response load and "
        "registered zero clear, for any state and input, at two, three and eight fills, "
        "portable and primitive",
        tasks=("bmc_seat2", "bmc_seat3", "bmc", "bmc_xilinx"),
    ),
    FormalTarget(
        "line_align.sby",
        "Line alignment matches a byte-by-byte reference for extract and place, and a "
        "placed access reads back, for 32- and 64-byte lines",
        tasks=("bmc", "bmc_64x8", "bmc_32x32"),
    ),
    FormalTarget(
        "ma_pkg.sby",
        "Misaligned-access split geometry, fault outcome, trap value and load value "
        "match direct references",
        tasks=("bmc",),
    ),
    FormalTarget(
        "ma_engine.sby",
        "Misaligned-access engine: unbounded equality of request controls and issue-state "
        "decodes from reset. Bounded checks cover translation before requests, lower sector "
        "first, unique request identities, completion, faults, write-back and terminal stops",
        tasks=("bmc", "cover", "prove"),
    ),
    FormalTarget(
        "alu_shift_hint.sby",
        "ALU shifts and rotates match the reference with captured shift amounts on or "
        "off",
        tasks=("bmc",),
    ),
    FormalTarget(
        "pointer_masking.sby",
        "Ssnpm: the MEM_RS base transform gives the Sv39 canonical check, the Bare PMA "
        "decodes, xtval and misaligned assist the ignore transformation's result "
        "across DDR apertures, and senvcfg.PMM is WARL",
        tasks=("bmc", "bmc_ddr31", "bmc_ddr36", "bmc_ddr37"),
    ),
    FormalTarget(
        "pm_mode_select.sby",
        "Ssnpm: the store PMA verdict and untranslated store completion with the "
        "pointer-masking mode applied to operand terms, and the trap value "
        "latched before the transform, equal the transform-first forms for every "
        "input and mode across DDR apertures",
        tasks=("bmc", "bmc_ddr31", "bmc_ddr36", "bmc_ddr37"),
    ),
    FormalTarget(
        "divider.sby",
        "Divider arithmetic at 8 bits and setup, completion, and cancellation at 64 bits",
        tasks=("bmc_width8", "prove_width64", "cover_width8"),
    ),
    FormalTarget(
        "reservation_station.sby",
        "RS dispatch, wakeup, issue, and flush at defaults and with eight-entry INT "
        "features",
        tasks=("bmc", "cover", "bmc_tag_indexed", "cover_tag_indexed"),
    ),
    FormalTarget(
        "rs_indexed_deferred_fold.sby",
        "Indexed RS deferred delivery and repair preserve write enables and selected "
        "data",
        tasks=("prove_int", "prove_mem", "prove_mul", "prove_src3", "cover_int"),
    ),
    FormalTarget(
        "rs_mem_broadcast.sby",
        "Memory station operand broadcasts preserve live rows, issue and LQ prematch",
        tasks=("prove", "prove_prims", "cover"),
    ),
    FormalTarget(
        "rob_alloc_lvt.sby",
        "Packed ROB allocation memories match separate field memories",
        tasks=("prove",),
    ),
    FormalTarget(
        "rob_bypass_control.sby",
        "ROB head completion bypass matches the per-lane reference",
        tasks=("bmc",),
    ),
    FormalTarget(
        "rob_link_value_ram.sby",
        "Shared ROB link RAM matches reference reads under single-branch allocation",
        tasks=(
            "prove_bin",
            "prove_oh",
            "prove_narrow_bin",
            "prove_narrow_oh",
            "bmc_free_bin",
            "bmc_free_oh",
            "bmc_free_small_bin",
            "bmc_free_small_oh",
            "cover_bin",
            "cover_oh",
            "prove_copy",
        ),
    ),
    FormalTarget(
        "rob_link_dispatch.sby",
        "Dispatch allocates at most one branch per bundle across all interface "
        "configurations",
        tasks=("p00", "p01", "p10", "p11"),
    ),
    FormalTarget(
        "sq_live_result_select.sby",
        "Store addresses and MMIO flags match reference CDB priority selection",
        tasks=("prove",),
    ),
    FormalTarget(
        "sq_early_sq_copy.sby",
        "Store-address copies and the instantiated wrapper's consumed packets equal "
        "the translation select, with reset, flush and translation-change covers",
        tasks=("prove", "prove_integrated", "cover"),
    ),
    FormalTarget(
        "rs_payload_twin.sby",
        "Two tomasulo_wrapper copies whose reservation stations hold arbitrary stage2 payloads while "
        "empty have equal outputs",
        tasks=(
            "bmc",
            "bmc_cdb",
            "bmc_cdb_2",
            "bmc_commit",
            "bmc_commit_2",
            "bmc_operands",
            "cover_cmo_request",
        ),
    ),
    FormalTarget(
        "rs_stage2_payload_equiv.sby",
        "Occupied reservation-station stage2 and stage2b payloads loaded on FU readiness equal "
        "issue-fire capture across all four station configurations",
        tasks=("int_prove", "mul_prove", "mem_prove", "fp_prove", "int_cover"),
    ),
    FormalTarget(
        "store_completion_cofactor.sby",
        "The wrapper's ROB store-completion assertion with free cached bounds, "
        "memory flags and issue inputs",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "rs_issue_tag_banks.sby",
        "INT_RS with four issue-tag copies equal to the tags equals INT_RS with the single "
        "tags, in portable and primitive builds",
        tasks=("int_equiv", "int_equiv_prims"),
    ),
    FormalTarget(
        "rs_issue_tag_copies.sby",
        "Each INT_RS issue-tag copy in tomasulo_wrapper equals its tag after one clock edge, "
        "from any initial state, by induction",
        tasks=("prove",),
    ),
    FormalTarget(
        "served_window_coverage.sby",
        "Per-provider fetch-window coverage and guard match full-address and "
        "aligner references across portable/Xilinx twins for 32/64-bit addresses",
        tasks=("bmc", "bmc_xilinx", "bmc_32", "bmc_32_xilinx", "prove", "cover"),
    ),
    FormalTarget(
        "rs_primary_payload.sby",
        "Primary RS payload storage and selection match the reference",
        tasks=("bmc16", "bmc8", "bmc4", "prove"),
    ),
    FormalTarget(
        "fp_engine_op_class.sby",
        "FP_RS engine-gate and fp_shim pipelined opcode classifications agree for every opcode",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "fp_forward_wake.sby",
        "FP forward offers, ROB tag ownership and both station wakeup lanes in the wrapper",
        tasks=(
            "bmc",
            "delivery_bmc",
            "cover",
            "fifo_prove",
            "route_prove",
            "route_cover",
        ),
    ),
    FormalTarget(
        "rs_divide_gate.sby",
        "The MUL and FP stations gate engine issues while pipelined operations may pass",
        tasks=("prove", "cover", "fp_gate_prove", "fp_gate_cover"),
    ),
    FormalTarget(
        "cdb_arbiter.sby",
        "CDB arbitration priority, exclusive grants, and result delivery",
    ),
    FormalTarget(
        "fu_cdb_adapter.sby",
        "FU completion buffering, backpressure, and flush handling",
        tasks=(
            "bmc",
            "cover",
            "bmc_registered",
            "cover_registered",
            "bmc_no_refill",
            "cover_no_refill",
            "bmc_precomputed",
            "bmc_always_granted",
        ),
    ),
    FormalTarget(
        "fu_cdb_adapter_payload_no_refill.sby",
        "FU CDB payload writes with grant-refill qualification disabled",
        tasks=("bmc",),
    ),
    FormalTarget(
        "mul_completion_tag.sby",
        "Unqualified invalid MUL tags preserve adapter state and valid completion data",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "mul_adapter_grant.sby",
        "Local MUL grants and always-granted MUL/MEM adapters preserve completion data "
        "and state",
        tasks=(
            "prove",
            "cover",
            "prove_always_mul",
            "cover_always_mul",
            "prove_always_mem",
            "cover_always_mem",
        ),
    ),
    FormalTarget(
        "load_queue.sby",
        "Load-queue allocation, memory ordering, response handling, and recovery",
        tasks=(
            "bmc",
            "cover",
            "bmc_age_order",
            "prove_pre_match",
            "prove_port1_amo",
            "cover_port1_amo",
            "bmc_no_prepare_busy",
            "cover_no_prepare_busy",
            "bmc_probe_launch",
            "cover_probe_launch",
        ),
    ),
    FormalTarget(
        "load_queue_amo_compute.sby",
        "Load-queue AMO results and control through cancellation, coherence, and "
        "stalled writes",
        tasks=("bmc", "cover"),
    ),
    FormalTarget(
        "data_mem_response_mux.sby",
        "Standalone response-mux equivalence for portable and Xilinx 32/64-bit "
        "implementations",
        tasks=("generic32", "generic64", "xilinx32", "xilinx64"),
    ),
    FormalTarget(
        "sc_head_query.sby",
        "SC head line matching and cache classification agree with the selected-address reference",
        tasks=("bmc",),
    ),
    FormalTarget(
        "coherence_replay_compare.sby",
        "Local coherence-line comparisons preserve replay masks and timing",
        tasks=("prove", "prove_xlen32", "prove_xlen66", "cover"),
    ),
    FormalTarget(
        "coherence_observation.sby",
        "Coherence tracking and replay masks across commit, flush, and tag reuse",
        tasks=("prove", "prove_unrestricted", "cover"),
    ),
    FormalTarget(
        "data_mem_request_router.sby",
        "Memory-router device staging, flush cancellation, and store-drain ordering",
    ),
    FormalTarget(
        "line_port_axi_bridge.sby",
        "AXI handshake legality, full-width offsets, and response tracking across "
        "CPU and AXI resets at default, 64 GiB, and 128 GiB widths",
        tasks=("bmc", "cover", "bmc_64g", "cover_64g", "bmc_128g", "cover_128g"),
    ),
    FormalTarget(
        "axi_coherent_bridge.sby",
        "AXI4 safety with arbitrary AXI offers and ingress replies at reset, response ordering and "
        "conservation, burst bytes to line requests and back, error bursts, and "
        "the coherent ingress's request rules, unbounded on narrow and line-wide "
        "buses with up to eight bursts and eight line IDs per direction; "
        "a four-burst proof pair and nine explicit eight-burst partitions",
        tasks=(
            "prove",
            "prove_full_width",
            "prove_soc",
            "prove_soc_held",
            "prove_soc8_0",
            "prove_soc8_1",
            "prove_soc8_2",
            "prove_soc8_3",
            "prove_soc8_4",
            "prove_soc8_5",
            "prove_soc8_6",
            "prove_soc8_7",
            "prove_soc8_8",
            "bmc_soc",
            "cover",
            "cover_soc",
        ),
    ),
    FormalTarget(
        "axil_reg_bridge.sby",
        "AXI4-Lite channel independence, response conservation and register mapping",
        tasks=("prove", "prove_engine", "cover"),
    ),
    FormalTarget(
        "axi_mux.sby",
        "AXI4 rules on every port, reset with active offers, W in AW-grant order, "
        "and B and R steered by port, unbounded",
        tasks=("prove", "prove_soc", "prove_soc4", "cover"),
    ),
    FormalTarget(
        "line_size_adapter.sby",
        "L1-line requests map onto their sector of a wider L2 line and back",
    ),
    FormalTarget(
        "store_queue.sby",
        "Store-queue capacity, forwarding, and committed-write preservation",
        tasks=("bmc", "cover", "bmc_trusted", "cover_trusted"),
    ),
    FormalTarget(
        "lq_l0_cache.sby",
        "L0 load-cache data and DMA invalidation at 128 and 256 entries",
        tasks=("bmc", "cover", "bmc_256", "cover_256"),
    ),
    FormalTarget(
        "branch_prediction_alias.sby",
        "Branch-prediction slot aliases match base-PC offset arithmetic",
        tasks=("bmc",),
    ),
    FormalTarget(
        "backing_btb.sby",
        "Backing BTB lookups match a mirror of its sets, every set holds each "
        "valid tag once, a redirect drops held and outstanding reads, and training holds current "
        "entries, at two and four ways; slot 2's fields formed for each slot-1 "
        "size and selected by the packet's size equal the single reduction they "
        "replace, for any register state",
        tasks=(
            "bmc",
            "bmc_four_way",
            "prove",
            "prove_four_way",
            "cover",
            "size_select",
            "size_select_four_way",
        ),
    ),
    FormalTarget(
        "branch_prediction_resolution.sby",
        "Two arbitrary predictions leave the resolved branch outcome, target and ROB update "
        "identity equal; each wrong direction or taken target requests recovery",
        tasks=("bmc", "cover"),
    ),
    FormalTarget(
        "predictor_fetch_contract.sby",
        "The real fetch stage supplies PD packet order, PC and backing fields, source "
        "register and target data, and the PC controller's registered recovery arm",
        tasks=(
            "bmc",
            "prove_order",
            "prove_addresses",
            "prove_buffer_source",
            "prove_slot1_sources",
            "prove_slot2_sources",
            "prove_targets",
            "cover",
            "cover_backing",
        ),
    ),
    FormalTarget(
        "backing_btb_twin.sby",
        "Every backing lookup result, including misses, held and shifted reads, "
        "and the pins of all five RAMs match the original backing BTB",
        tasks=("bmc", "prove", "cover"),
    ),
    FormalTarget(
        "pd_history_twin.sby",
        "Both full decode packets, fetch redirects, return stack operations, history "
        "folds, training and FTQ RAM pins match the original PD and history stages together",
        tasks=("bmc", "prove", "cover"),
    ),
    FormalTarget(
        "tage_predictor_twin.sby",
        "Both direction banks, captured lookup, and every table RAM pin match "
        "the original direction predictor with the index folded outside the predictor",
        tasks=("bmc", "prove", "cover"),
    ),
    FormalTarget(
        "ittage_predictor_twin.sby",
        "Both indirect banks, target selection, captured lookup, and every "
        "table RAM pin match the original indirect predictor",
        tasks=("bmc", "prove", "cover"),
    ),
    FormalTarget(
        "ittage_training.sby",
        "Indirect prediction holds the captured lookup; each table uses the retiring lookup's "
        "bank and index, forwards a colliding write, and repairs an unowned provider",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "tage_history_recovery.sby",
        "Both lookup histories follow accepted predictions, ordered retirement, "
        "saved early-recovery histories and every PC restore arm; only retired lookups train",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "tage_copy_convergence.sby",
        "Tagged predictor training: with a table entry's two copies equal, "
        "each copy's next value matches the write without the provider "
        "write-back; with them unequal, a write makes them equal",
        tasks=("prove", "cover", "bmc_unequal", "cover_unequal"),
    ),
    FormalTarget(
        "pd_backing_redirect.sby",
        "PD backing, indirect and direction redirects require a live slot; each "
        "indirect candidate and target selection matches the compare-before-register "
        "equations, both history outputs match the branch direction or jump target bit, "
        "a reserved compressed jump preserves only its trap, and stack operations, "
        "refreshes, directions and targets match PD's reference models across address regions; induction checks "
        "indirect eligibility, payloads and reserved traps. "
        "Each redirect has sources in only one slot. Redirects from aligned inputs "
        "are aligned, indirect targets select a taken "
        "JALR, and taken direction redirects select the decoded branch target",
        tasks=("bmc", "cover", "prove_indirect"),
    ),
    FormalTarget(
        "pd_redirect_next_equiv.sby",
        "PD's redirect target fields equal the direct expressions for any packet, "
        "candidates, backing BTB result and stack state. The slot-1 backing owner "
        "selects between independent address candidates after capture",
        tasks=("bmc",),
    ),
    FormalTarget(
        "pd_id_slot2_redirect.sby",
        "Composed PD and ID stages dispatch slot 2's effective prediction and "
        "target equal to PD's slot-2 redirect while leaving slot 1 untouched, without and "
        "with the vector floating-point decode",
        tasks=(
            "pd_id_slot2_bmc",
            "pd_id_slot2_cover",
            "pd_id_slot2_vector_bmc",
            "pd_id_slot2_vector_cover",
        ),
    ),
    FormalTarget(
        "if_slot2_precompute.sby",
        "IF precomputed slot-2 TAGE coverage, lookup select, branch flag, target "
        "candidates, PC step, and bubble/fault pairing match direct references "
        "across live and stall-replayed packets",
        tasks=("if_slot2_precompute_bmc", "if_slot2_precompute_cover"),
    ),
    FormalTarget(
        "slot2_prediction_capture.sby",
        "A staged slot-2 candidate and its metadata survive stalls, are consumed "
        "only with replay, and are cancelled by reset or recovery",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "c_ext_state_cofactor.sby",
        "Compressed-instruction buffer state matches reference handoff priority",
        tasks=("bmc",),
    ),
    FormalTarget(
        "immu_page_offset.sby",
        "Instruction translation preserves page offsets and visible outputs",
        tasks=("bmc", "prove"),
    ),
    FormalTarget(
        "immu_memo.sby",
        "Instruction-MMU refusals expire within bounded time, full flushes drop "
        "coincident faults, first-word faults complete the window, and memo fills "
        "follow walk acceptance (Svvptc)",
        tasks=("bmc", "prove"),
    ),
    FormalTarget(
        "immu_successor.sby",
        "Instruction superpage successor eligibility, PPN and PMA equal the "
        "selected-leaf reference for arbitrary TLB and walk state",
        tasks=("bmc",),
    ),
    FormalTarget(
        "immu_capture_next.sby",
        "Instruction-MMU word-1 fault, cause, VA placeholder and neighbor-miss next "
        "states equal the priority-ordered capture reference, portable and "
        "primitive forms",
        tasks=("bmc", "bmc_xilinx"),
    ),
    FormalTarget(
        "immu_bare.sby",
        "Bare instruction-fetch addresses and PMA faults match the reference across "
        "datapath widths",
        tasks=("bmc", "bmc_1g", "bmc_64g", "bmc_128g", "bmc_xlen32", "bmc_xlen72"),
    ),
    FormalTarget(
        "fetch_pc_mux.sby",
        "Fetch-PC prediction selection matches reference priority",
        tasks=("bmc", "bmc_integrated", "bmc_xilinx", "bmc_integrated_xilinx"),
    ),
    FormalTarget(
        "fetch_redirect.sby",
        "Registered fetch redirects match reference selection",
        tasks=("bmc", "prove", "cover"),
    ),
    FormalTarget(
        "pc_redirect_catchup_producer.sby",
        "PC-controller catch-up redirects satisfy the consumer requirements",
        tasks=("x32", "x64", "x66"),
    ),
    FormalTarget(
        "pc_redirect_catchup_consumer.sby",
        "Fetch redirects match the reference when sequential catch-up requests are "
        "omitted",
        tasks=("prove",),
    ),
    FormalTarget(
        "pc_tage_events.sby",
        "Registered history events match PC-load qualification",
        tasks=("pc_tage_events_prove", "pc_tage_events_cover"),
    ),
    FormalTarget(
        "pc_register_mux.sby",
        "Architectural PC and pending-relation selection match reference priority",
        tasks=("bmc", "bmc_integrated", "bmc_xilinx", "bmc_integrated_xilinx"),
    ),
    FormalTarget(
        "pc_holdoff_cofactor.sby",
        "Pending-fetch holdoff enables match the reference",
        tasks=("bmc",),
    ),
    FormalTarget(
        "pc_holdoff_tag.sby",
        "Captured pending-prediction tags preserve reference holdoff behavior",
        tasks=("prove", "prove_xlen32", "prove_xlen72", "cover"),
    ),
    FormalTarget(
        "btb_pending_relation.sby",
        "Raw slot-2 relations match per-candidate targets including uncovered rows",
        tasks=("bmc", "bmc_btb_index1", "bmc_btb_index3"),
    ),
    FormalTarget(
        "btb_tag_compare.sby",
        "Grouped BTB lookup and update comparisons match full-width tags",
        tasks=("bmc", "bmc_small_btb"),
    ),
    FormalTarget(
        "branch_prediction_disable.sby",
        "Branch-prediction guards and metadata obey staged and live disable rules, "
        "and slot-2 target relations match direct compares",
        tasks=("bmc",),
    ),
    FormalTarget(
        "btb_invalidate_hold.sby",
        "BTB invalidate holds for four cycles, clears every slot-1 and slot-2 valid "
        "array and staged valid flop, and drops updates arriving during the hold",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "prediction_handoff.sby",
        "Pending-prediction handoff preserves slot-2 veto and state masking",
        tasks=("bmc", "cover", "prove"),
    ),
    FormalTarget(
        "prediction_release.sby",
        "Pending-prediction release preserves state masking, fetch holdoffs, and the "
        "registered PC relations, including walked-past entries, and the instruction "
        "buffer takes only pc_reg's word",
        tasks=("bmc", "cover", "prove"),
    ),
    FormalTarget(
        "if_prediction_walk_past.sby",
        "Fetch stage preserves pc_reg continuity and emits no real packet while "
        "post-prediction holdoff holds pc_reg, including walked-past pending predictions; "
        "covers real slot-2 packets, an indirect hit after a reserved compressed parcel, and a hit across the target-address region",
        tasks=("bmc", "continuity", "cover"),
    ),
    FormalTarget(
        "prediction_metadata_tracker.sby",
        "Prediction validity and payloads stay with the matching packet",
        tasks=("bmc", "cover", "prove"),
    ),
    FormalTarget(
        "fp_shim.sby",
        "FP completion tags, busy state, and cancellation",
    ),
    FormalTarget(
        "fp_shim_pipe.sby",
        "Pipelined FP tracker, forward wake, result FIFO and credits: no stale or "
        "duplicate completion through flushes",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "fp_launch_squash.sby",
        "FP launch cancellation matches the reference under the producer bubble "
        "requirement",
        tasks=("on", "off", "cover"),
    ),
    FormalTarget(
        "fp_launch_squash_rs.sby",
        "The FP station leaves an issue bubble after a flushed issue",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "imsic_file.sby",
        "IMSIC interrupt file with the CPU's registered select and identity decodes",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "imsic.sby",
        "IMSIC topei selection, pending and enable updates, claims, interrupt "
        "lines, register reads, and the MSI address decode",
        tasks=(
            "bmc",
            "prove",
            "cover",
            "prove_harts3",
            "cover_harts3",
            "prove_ids511",
            "bmc_ids2047",
        ),
    ),
    FormalTarget(
        "async_fifo.sby",
        "FIFO capacity, flow control, and data ordering across unrelated clocks, "
        "and the runtime occupancy limit",
        tasks=("bmc", "cover", "limit_bmc", "limit_cover"),
    ),
    FormalTarget(
        "aplic.sby",
        "APLIC topi selection, pending-bit rules, delegation, domain isolation, "
        "claims, MSI forwarding, address configuration, and register reads",
        tasks=(
            "bmc",
            "prove",
            "cover",
            "prove_one_hart",
            "prove_wide",
            "prove_three_harts",
            "msi_bmc",
            "msi_prove",
            "msi_cover",
            "msi_prove_32",
            "msi_prove_locked",
            "msi_prove_wide",
            "msi_prove_four_harts",
        ),
    ),
    FormalTarget(
        "tomasulo_wrapper.sby",
        "Tomasulo commit and flush integration, including FP dispatch done repair",
        tasks=(
            "bmc",
            "cover",
            "cover_alu_issue",
            "fp_repair_bmc",
            "bmc_depth6",
            "bmc_wakeup_depth6",
            "fp_repair_bmc_depth6",
            "cover_depth6",
            "cover_wakeup_depth6",
            "cover_fu_depth6",
        ),
    ),
    FormalTarget(
        "tomasulo_wrapper_commit_bus.sby",
        "Registered commit propagation from the Tomasulo ROB through the RAT and fence flush",
        tasks=("bmc", "cover"),
    ),
    FormalTarget(
        "coherence_home_engine_twin.sby",
        "Home engine: primitive and portable forms are equivalent.",
        tasks=(
            "home_engine_twin32",
            "home_engine_twin64",
            "home_engine_twin40",
        ),
    ),
    FormalTarget(
        "coherence_home_twin.sby",
        "Home: primitive and portable forms are equivalent.",
        tasks=(
            "home_twin_small",
            "home_twin_four",
            "home_twin_addr40",
        ),
    ),
    FormalTarget(
        "coherence_l1d_zero_index.sby",
        "Zero look-ahead blocking equals its address and index forms and the GetMZero choice implies both, under buffer invariants proved under the buffer's interface contract.",
        tasks=("zero_index_prove", "zero_index_invariants"),
    ),
    FormalTarget(
        "coherence_l1d_twin.sby",
        "L1D: primitive and portable forms are equivalent.",
        tasks=(
            "l1d_twin_single",
            "l1d_twin_multi",
            "l1d_twin_stream",
        ),
    ),
    FormalTarget(
        "l0_store_boundary_twin.sby",
        "Store-queue write capture and the load cache store port across each clock edge.",
        tasks=("boundary_twin",),
    ),
    FormalTarget(
        "decoded_bundle_queue_twin.sby",
        "Decoded bundle queue: primitive and portable forms are equivalent.",
        tasks=("dbq_twin",),
    ),
    FormalTarget(
        "dmmu_twin.sby",
        "Data MMU: primitive and portable forms are equivalent.",
        tasks=("dmmu_twin",),
    ),
    FormalTarget(
        "immu_twin.sby",
        "Instruction MMU: primitive and portable forms are equivalent.",
        tasks=("immu_twin", "immu_twin_hold"),
    ),
    FormalTarget(
        "cached_tier_adapter_twin.sby",
        "Cached tier adapter: primitive and portable forms are equivalent.",
        tasks=(
            "cached_tier_twin",
            "cached_tier_unsplit",
        ),
    ),
    FormalTarget(
        "csr_file_twin.sby",
        "CSR file: primitive and portable forms are equivalent with VECTOR=0 and 1.",
        tasks=("csr_twin", "csr_twin_vector"),
    ),
    FormalTarget(
        "fp_engine_twin.sby",
        "FP engine: primitive and portable forms are equivalent.",
        tasks=("fp_engine_twin",),
    ),
    FormalTarget(
        "control_flow_tracker_twin.sby",
        "Control-flow tracker: primitive and portable forms are equivalent.",
        tasks=("cft_twin",),
    ),
    FormalTarget(
        "pd_target_candidate_twin.sby",
        "Predecode target candidate: primitive and portable forms are equivalent.",
        tasks=("pdt_twin",),
    ),
    FormalTarget(
        "data_mem_request_router_twin.sby",
        "Data memory request router: primitive and portable forms are equivalent.",
        tasks=("router_twin",),
    ),
    FormalTarget(
        "branch_predictor_twin.sby",
        "Branch predictor: primitive and portable forms are equivalent.",
        tasks=("bp_twin",),
    ),
    FormalTarget(
        "pc_controller_twin.sby",
        "PC controller: primitive and portable forms are equivalent.",
        tasks=(
            "pc_controller_twin",
            "pc_controller_twin_slot2",
        ),
    ),
    FormalTarget(
        "store_queue_twin.sby",
        "Store queue: primitive and portable forms are equivalent.",
        tasks=("sq_twin", "sq_twin_cpu"),
    ),
    FormalTarget(
        "coherent_store_pma_twin.sby",
        "Store page decoder: primitive and portable forms are equivalent at the "
        "1 GiB and 2 GiB DDR sizes.",
        tasks=("store_pma_twin_ddr30", "store_pma_twin_ddr31"),
    ),
    FormalTarget(
        "reservation_station_twin.sby",
        "Reservation station: primitive and portable forms are equivalent.",
        tasks=("rs_twin_indexed",),
    ),
    FormalTarget(
        "sq_forwarding_unit.sby",
        "Store-queue forwarding: byte merge, CMO/MMIO/SC blocks, ring-order priority and tree equivalence.",
        tasks=("prove", "cover", "tree_equiv"),
    ),
    FormalTarget(
        "axi_cdc.sby",
        "AXI4 clock-domain crossing: staggered resets, ordering and payload preservation.",
        tasks=("prove_aw", "prove_w", "prove_b", "prove_ar", "prove_r", "cover"),
    ),
    FormalTarget(
        "cdc_mailbox.sby",
        "Toggle-handshake CDC mailbox: single in-flight transfer and stable payload capture.",
        tasks=("bmc", "cover"),
    ),
    FormalTarget(
        "dc_fifo.sby",
        "Dual-clock BRAM FIFO: free-clock occupancy, ready margin and payload delivery.",
        tasks=("prove", "prove_margin2", "cover"),
    ),
    FormalTarget(
        "sync_dist_ram_fifo.sby",
        "Synchronous distributed-RAM FIFO: flags, pointer wrap and ordered word delivery.",
        tasks=("bmc", "cover"),
    ),
    FormalTarget(
        "mwp_dist_ram.sby",
        "Multi-write-port LVT distributed RAM: staged write forwarding and port priority.",
        tasks=("bmc", "bmc_addr1", "bmc_unstaged", "cover"),
    ),
    FormalTarget(
        "nic_irq.sby",
        "NIC interrupt controller: W1C priority, count/timer coalescing and mask control.",
        tasks=("prove", "bmc", "cover"),
    ),
    FormalTarget(
        "nic_dma_front.sby",
        "NIC DMA front-end: aperture filter, unique IDs, side caps and same-line RW exclusion.",
        tasks=("bmc", "cover"),
    ),
    FormalTarget(
        "nic_reset_split_equiv.sby",
        "NIC reset split equivalence: core and MAC reset controllers match the monolithic FSM.",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "nic_axis_boundary.sby",
        "NIC AXI4-Stream beat-code bijection, abort code isolation and TX checksum side-FIFO framing.",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "axi_register_slice.sby",
        "AXI4 and AXI4-Lite five-channel register slices: hold rules, FIFO ordering, full rate and reset.",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "nic_diag.sby",
        "NIC diagnostic CDC pin and register mapping, disabled slots, and PHY sample equivalence.",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "nic_tx_hold.sby",
        "NIC TX FIFO offer stability through acceptance, with rejection and reset-drain covers.",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "rat_checkpoint_restore.sby",
        "Register alias table: unbounded circular ROB and sequence oracle across save, restore and commit.",
        tasks=(
            "prove_int_active",
            "prove_int_ckpt_lo",
            "prove_int_ckpt_mid",
            "prove_int_ckpt_hi",
            "prove_fp_active",
            "prove_fp_ckpt_lo",
            "prove_fp_ckpt_mid",
            "prove_fp_ckpt_hi",
            "cover",
        ),
    ),
]

# SymbiYosys task types (for CLI --task filter and pytest parametrize)
SBY_TASKS = [
    ("retirement_prove", "Check head WFI retirement against a reference flush window"),
    ("retirement_cover", "Reach a ready head WFI in each recovery or flush window"),
    (
        "cover_backing",
        "Reach a real second-slot backing hit after the full reset sweep",
    ),
    (
        "prove_order",
        "Prove fetch slot order, fault propagation and the registered PD restore",
    ),
    (
        "prove_addresses",
        "Prove the slot PC step and backing target region and size selection",
    ),
    (
        "prove_buffer_source",
        "Prove a live buffered first slot reads a paired instruction and sideband",
    ),
    (
        "prove_slot1_sources",
        "Prove first-slot expansion and source fields with the buffer source lemma",
    ),
    ("prove_slot2_sources", "Prove second-slot expansion, class and source fields"),
    ("prove_targets", "Prove the target sums and high selectors used by fetch"),
    (
        "prove_indirect",
        "Unbounded pre-decode indirect target, eligibility and trap isolation.",
    ),
    (
        "delivery_bmc",
        "Check delivery or recovery of a pipelined result through the registered CDB.",
    ),
    (
        "route_cover",
        "Reach a stalled FP result and its grant on each registered CDB lane.",
    ),
    (
        "route_prove",
        "The FP adapter retains a stalled FIFO head and a slot-6 grant registers its word.",
    ),
    (
        "fifo_prove",
        "A selected forward word stays in its physical FIFO slot until delivery or recovery.",
    ),
    ("fp_gate_prove", "FP station engine issue, opcode and busy interlock."),
    ("fp_gate_cover", "FP pipeline bypass, engine release and squashed launch."),
    ("prove_prims", "Prove the memory station equivalence with Xilinx LUTs."),
    ("pm_mode_bmc", "Registered pointer-masking mode and legal PMM states, 20 frames."),
    ("link_zero_prove", "A link with no stages is wires."),
    ("link_always1_prove", "Always-taken link, one stage: order, payload and latency."),
    (
        "link_always2_prove",
        "Always-taken link, two stages: order, payload and latency.",
    ),
    (
        "link_credit1_bmc",
        "Credit link, one stage, three credits: order, payload and credit count, 28 frames.",
    ),
    (
        "link_credit2_bmc",
        "Credit link, two stages, five credits: order, payload and credit count, 28 frames.",
    ),
    (
        "link_one1_prove",
        "One-credit link, one stage: order, payload and a single message.",
    ),
    (
        "link_one2_prove",
        "One-credit link, two stages: order, payload and a single message.",
    ),
    (
        "link_mirror1_prove",
        "Mirrored link, one stage: each acceptance completes one sender handshake.",
    ),
    (
        "link_mirror2_prove",
        "Mirrored link, two stages: each acceptance completes one sender handshake.",
    ),
    (
        "sc_wa_s0_prove",
        "Production L1D, home and links (0 stages): SC GrantM has no same-sector wb_live slot.",
    ),
    (
        "sc_wa_s1_prove",
        "Production L1D, home and links (1 stage): SC GrantM has no same-sector wb_live slot.",
    ),
    (
        "sc_wa_s2_prove",
        "Production L1D, home and links (2 stages): SC GrantM has no same-sector wb_live slot.",
    ),
    (
        "sc_wa_s3_prove",
        "Production L1D, home and links (3 stages): SC GrantM has no same-sector wb_live slot.",
    ),
    (
        "sc_wa_s0_cover",
        "Production L1D, home and links (0 stages): cover SC GrantM, PutM token, put_blocks, ProbeSnapshot and FillRecall.",
    ),
    (
        "sc_wa_s1_cover",
        "Production L1D, home and links (1 stage): cover SC GrantM, PutM token, put_blocks, ProbeSnapshot and FillRecall.",
    ),
    (
        "sc_wa_s2_cover",
        "Production L1D, home and links (2 stages): cover SC GrantM, PutM token, put_blocks, ProbeSnapshot and FillRecall.",
    ),
    (
        "sc_wa_s3_cover",
        "Production L1D, home and links (3 stages): cover SC GrantM, PutM token, put_blocks, ProbeSnapshot and FillRecall.",
    ),
    ("link_credit1_cover", "A credit link delivers four messages."),
    ("link_mirror1_cover", "A mirrored link completes four handshakes."),
    (
        "link_bmc_siblings",
        "Production L1D and home through one-stage links preserve sibling-sector bytes; first watched byte.",
    ),
    (
        "link_bmc_siblings_second",
        "Production L1D and home through one-stage links preserve sibling-sector bytes; second watched byte.",
    ),
    (
        "link_bmc_pressure",
        "One-stage links under two dirty victims, delayed releases and a probing DMA read; first watched byte.",
    ),
    (
        "link_bmc_pressure_second",
        "One-stage links under two dirty victims, delayed releases and a probing DMA read; second watched byte.",
    ),
    (
        "link_cover_pressure",
        "The pressure schedule completes through one-stage links.",
    ),
    ("limit_bmc", "Bounded proof that the runtime occupancy limit caps the writer."),
    ("limit_cover", "The writer stalls at a runtime limit below the RAM's capacity."),
    (
        "coh_l1d_perf_prove",
        "The L1D counter stream equals the direct serializer delayed once.",
    ),
    ("coh_l1d_conflict_prove", "Guarded conflict identity with one endpoint."),
    ("coh_l1d_conflict_multi_prove", "Guarded conflict identity with three endpoints."),
    (
        "coh_l1d_conflict_stream_prove",
        "Guarded conflict identity with eight endpoints and streaming enabled.",
    ),
    (
        "stream_prove",
        "Demand stream confirmation, cancellation and bounded sector cursor.",
    ),
    (
        "stream_cover",
        "Page-end saturation and simultaneous demand advance and hint consumption.",
    ),
    (
        "coh_l1d_stream_bmc",
        "Scripted stream control through 42 frames, with payload checks proved independently and arbitrary replies after cycle 24.",
    ),
    (
        "coh_l1d_stream_hold_bmc",
        "The scripted stream's payload identities and holds through all 42 cycles.",
    ),
    (
        "coh_l1d_stream_free_bmc",
        "Stream control with arbitrary inputs and stores through 32 frames, with payload checks proved independently.",
    ),
    (
        "coh_l1d_stream_owned_prove",
        "Unbounded: read-slot ownership, the selected read's kind and shadow lookups with eight endpoints, by induction.",
    ),
    (
        "coh_l1d_stream_snapshot_prove",
        "Unbounded: absorbed-PutM ownership disjointness with eight endpoints, by induction.",
    ),
    (
        "coh_l1d_stream_prove",
        "Unbounded: most control assertions with eight endpoints, arbitrary inputs and stores.",
    ),
    (
        "coh_l1d_stream_outlier_prove",
        "Independent unbounded grant multiplexer, image, load payload, reply hold and snapshot data checks for the stream BMCs.",
    ),
    (
        "coh_l1d_stream_free_nostore_bmc",
        "Stream control with arbitrary inputs and no stores through 24 frames, with payload checks proved independently.",
    ),
    (
        "coh_l1d_stream_free_nostore_hold_bmc",
        "Payload identities and holds with arbitrary inputs and no stores through all 24 cycles.",
    ),
    ("coh_l1d_stream_cover", "Two speculative endpoints and demand attachment."),
    (
        "coh_l1d_snapshot_cover",
        "StoreConditional grant ordering against live writebacks and snapshot probe lookups.",
    ),
    ("coh_l1d_turn_cover", "A demand retry between buffered load grants."),
    (
        "pf_pause_prove",
        "Prefetch pause equals live DMA identities and recent activity.",
    ),
    ("pf_pause_cover", "Eight DMA identities, simultaneous reuse and return to idle."),
    ("pf_agent64_prove", "Prefetch endpoint ownership with 64-byte lines."),
    ("pf_agent32_prove", "Prefetch endpoint ownership with 32-byte lines."),
    ("pf_agent1_prove", "Prefetch endpoint ownership with a one-request cap."),
    ("pf_agent2_prove", "Prefetch endpoint ownership with a two-request cap."),
    (
        "pf_agent4_prove",
        "Prefetch endpoint ownership with all four identities enabled.",
    ),
    (
        "pf_agent64_cover",
        "Four prefetch identities, errors, release and reset with 64-byte lines.",
    ),
    (
        "pf_agent32_cover",
        "Four prefetch identities, errors, release and reset with 32-byte lines.",
    ),
    (
        "reservation_prove",
        "Successful SC clears at installation; failed SC clears and discards.",
    ),
    ("amo_bmc", "Local AMO dependency safety and bounded progress."),
    ("sc_bmc", "Local SC dependency safety and bounded progress."),
    ("amo_cover", "Local AMO release and pending control-entry stages."),
    ("sc_cover", "Local SC retirement and pending control-entry stages."),
    (
        "coh_l1d_local_prove",
        "Local service exclusion, saved image and release by induction.",
    ),
    (
        "coh_l1d_local_multi_prove",
        "Local ownership beside unrelated endpoints by induction.",
    ),
    ("coh_l1d_local_ways_prove", "Local ownership with multiple ways by induction."),
    (
        "coh_l1d_local_owned_prove",
        "A failed read stays owned until its ready flag sets, by induction.",
    ),
    (
        "coh_l1d_local_multi_owned_prove",
        "A failed read stays owned beside other endpoints, by induction.",
    ),
    (
        "coh_l1d_local_ways_owned_prove",
        "A failed read stays owned with multiple ways, by induction.",
    ),
    ("coh_l1d_local_sector_prove", "Local sector admission and identity by induction."),
    (
        "coh_l1d_local_multi_sector_prove",
        "Local sector admission beside unrelated endpoints by induction.",
    ),
    (
        "coh_l1d_local_ways_sector_prove",
        "Local sector admission with multiple ways by induction.",
    ),
    (
        "coh_l1d_local_cover",
        "Local failure, completed update and deferred probe reply.",
    ),
    (
        "coh_l1d_local_data_bmc",
        "Local atomic arbitrary-byte preservation and deferred probe data through 80 real-array cycles.",
    ),
    (
        "coh_l1d_local_hold_bmc",
        "Local atomic payload identities and holds through 80 real-array cycles.",
    ),
    (
        "coh_l1d_local_control_bmc",
        "All other local scheduled assertions through 80 real-array cycles, without partition assumptions.",
    ),
    (
        "store_saturation_bmc",
        "A delayed head preserves 33 younger same-byte stores through saturation and drain.",
    ),
    (
        "store_saturation_cover",
        "A younger record saturates at 32 contributors and its successor drains.",
    ),
    (
        "coh_hart_maint_four_bmc",
        "Four occupied records drain before a fence and final PTE publication.",
    ),
    (
        "coh_hart_snapshot_bmc",
        "Two CPU versions reach instruction fetch and the walker.",
    ),
    (
        "coh_hart_snapshot_cover",
        "Post-fence fetch and walking after a retained M-hit store.",
    ),
    (
        "coh_hart_maint_four_cover",
        "Four occupied records reach fence, instruction and PTW completion.",
    ),
    (
        "coh_grant_select2_prove",
        "Two grant candidates preserve credit-qualified priority, failure and packet fields.",
    ),
    (
        "coh_grant_select4_prove",
        "Four grant candidates preserve credit-qualified priority, failure and packet fields.",
    ),
    (
        "coh_grant_select8_prove",
        "Eight grant candidates preserve credit-qualified priority, failure and packet fields.",
    ),
    (
        "coh_read_owners1_prove",
        "One endpoint preserves the binary read ownership mask.",
    ),
    (
        "coh_read_owners3_prove",
        "The binary read ownership mask covers 3 endpoints.",
    ),
    (
        "coh_read_owners4_prove",
        "The binary read ownership mask covers 4 endpoints.",
    ),
    (
        "coh_read_owners8_prove",
        "The binary read ownership mask covers 8 endpoints.",
    ),
    ("coh_miss_credit1_prove", "Binary acquisition credits cover one endpoint."),
    ("coh_miss_credit3_prove", "Binary acquisition credits cover 3 endpoints."),
    ("coh_miss_credit4_prove", "Binary acquisition credits cover 4 endpoints."),
    ("coh_miss_credit8_prove", "Binary acquisition credits cover 8 endpoints."),
    ("bmc_siblings", "Real-home sibling store byte safety; first watched byte."),
    (
        "bmc_siblings_second",
        "Real-home sibling store byte safety; second watched byte.",
    ),
    ("bmc_rows", "Real-home distinct-row store byte safety; first watched byte."),
    (
        "bmc_rows_second",
        "Real-home distinct-row store byte safety; second watched byte.",
    ),
    (
        "bmc_conflict",
        "Real-home conflicting-row store byte safety; first watched byte.",
    ),
    (
        "bmc_conflict_second",
        "Real-home conflicting-row store byte safety; second watched byte.",
    ),
    ("cover_siblings", "Sibling acquisitions complete and supply DMA data."),
    (
        "cover_rows",
        "Distinct-row concurrent acquisitions complete and supply DMA data.",
    ),
    (
        "cover_conflict",
        "A same-set conflict serializes and supplies DMA data.",
    ),
    (
        "bmc_pressure",
        "Real-home stores and load data survive held writebacks and releases; first watched byte.",
    ),
    (
        "bmc_pressure_second",
        "Real-home stores and load data survive held writebacks and releases; second watched byte.",
    ),
    (
        "cover_pressure",
        "Two held dirty victims yield to a probing DMA request and a waiting load.",
    ),
    (
        "bmc_four_control",
        "Four sector records preserve credit, drain and completion identities through 114 cycles.",
    ),
    (
        "bmc_four_value_0",
        "Four sector records preserve the load value for watched store 0 through 114 cycles.",
    ),
    (
        "bmc_four_value_1",
        "Four sector records preserve the load value for watched store 1 through 114 cycles.",
    ),
    (
        "bmc_four_value_2",
        "Four sector records preserve the load value for watched store 2 through 114 cycles.",
    ),
    (
        "bmc_four_value_3",
        "Four sector records preserve the load value for watched store 3 through 114 cycles.",
    ),
    (
        "cover_four",
        "Four acknowledged holders drain with concurrent store acquisitions.",
    ),
    (
        "bmc_intervening_same_flow",
        "Same-sector intervening load preserves credit, drain and completion identities.",
    ),
    (
        "bmc_intervening_other_flow",
        "Different-sector intervening load preserves credit, drain and completion identities.",
    ),
    (
        "bmc_intervening_same_value",
        "A younger same-sector store cannot change an intervening load result.",
    ),
    (
        "bmc_intervening_other_value",
        "A younger different-sector store cannot change an intervening load result.",
    ),
    (
        "bmc_intervening_fatal",
        "Intervening-load traffic raises no fatal L1D status through frame 139.",
    ),
    (
        "prove_intervening_fatal_sticky",
        "Intervening-load L1D fatal status persists after initial reset.",
    ),
    (
        "coh_l1d_multi_data0_bmc",
        "Concurrent store acquisitions preserve array and probe bytes in word 0.",
    ),
    (
        "coh_l1d_multi_data1_bmc",
        "Concurrent store acquisitions preserve array and probe bytes in word 1.",
    ),
    (
        "coh_l1d_multi_data2_bmc",
        "Concurrent store acquisitions preserve array and probe bytes in word 2.",
    ),
    (
        "coh_l1d_multi_data3_bmc",
        "Concurrent store acquisitions preserve array and probe bytes in word 3.",
    ),
    (
        "coh_l1d_ways_data_bmc",
        "Four-way array, probe and hit-path bytes in word 0 with three endpoints.",
    ),
    (
        "coh_l1d_zero_bmc",
        "cbo.zero writes: GetMZero records, owed twin installation and control checks.",
    ),
    (
        "coh_l1d_zero_multi_bmc",
        "cbo.zero writes with three endpoints and look-ahead GetMZero.",
    ),
    ("coh_l1d_zero_payload_bmc", "Store byte values with cbo.zero writes."),
    (
        "coh_l1d_zero_cover",
        "cbo.zero twin installation, victim, wait and fallback covers.",
    ),
    ("coh_l1d_zero_lookahead_cover", "A look-ahead GetMZero with three endpoints."),
    (
        "coh_l1d_zero_stream_hint_bmc",
        "Stream prefetching and Modified-sector grants with cbo.zero writes, full-line stores and the store queue's hints free.",
    ),
    (
        "coh_l1d_zero_stream_line_bmc",
        "GetMZero starts only with its own same-block twin or full upper record next, with streaming, cbo.zero writes, full-line stores and the store queue's hints free.",
    ),
    (
        "coh_l1d_zero_stream_upper_ep0_bmc",
        "No upper-sector request is accepted while endpoint 0 holds GetMZero through Done, with streaming, cbo.zero writes, full-line stores and the store queue's hints free.",
    ),
    (
        "coh_l1d_zero_stream_upper_ep1_read_bmc",
        "No upper-sector request is accepted while endpoint 1 holds GetMZero through Done and a read is in operation_q, with streaming, cbo.zero writes, full-line stores and the store queue's hints free.",
    ),
    (
        "coh_l1d_zero_stream_upper_ep1_store_bmc",
        "No upper-sector request is accepted while endpoint 1 holds GetMZero through Done and a store is in operation_q, with streaming, cbo.zero writes, full-line stores and the store queue's hints free.",
    ),
    (
        "coh_l1d_zero_stream_upper_ep1_lookahead_bmc",
        "No upper-sector request is accepted while endpoint 1 holds GetMZero through Done and a look-ahead is in operation_q, with streaming, cbo.zero writes, full-line stores and the store queue's hints free.",
    ),
    (
        "coh_l1d_zero_stream_upper_ep1_prefetch_bmc",
        "No upper-sector request is accepted while endpoint 1 holds GetMZero through Done and a prefetch is in operation_q, with streaming, cbo.zero writes, full-line stores and the store queue's hints free.",
    ),
    (
        "coh_l1d_zero_stream_upper_ep1_rest_bmc",
        "No upper-sector request is accepted while endpoint 1 holds GetMZero through Done and any other operation is in operation_q, with streaming, cbo.zero writes, full-line stores and the store queue's hints free.",
    ),
    (
        "coh_l1d_zero_stream_upper_ep2_bmc",
        "No upper-sector request is accepted while endpoint 2 holds GetMZero through Done, with streaming, cbo.zero writes, full-line stores and the store queue's hints free.",
    ),
    (
        "coh_l1d_zero_progress_cover",
        "Full-buffer zero wrap with a different-block or same-block head twin resolves through both sector installations and Done.",
    ),
    (
        "coh_l1d_zero_stream_bmc",
        "A dropped load retries beside a full-buffer zero wrap without accepting an upper-sector request during GetMZero.",
    ),
    (
        "coh_l1d_zero_request_cover",
        "The dropped-load schedule reaches its final checked frame after retry and zero completion.",
    ),
    (
        "zero_index_prove",
        "Upper-flag zero look-ahead blocking equals the address and index forms, and the GetMZero choice implies both, under the buffer's upper-line, twin-pairing and sampled-conflict invariants.",
    ),
    (
        "zero_index_invariants",
        "Store-buffer shape, upper-flag lines, zero and data twin pairing, and the sampled same-block head conflict under the buffer interface contract.",
    ),
    (
        "coh_l1d_full_bmc",
        "Full-line stores: full-pair GetMZero, data twin installation and control checks.",
    ),
    (
        "coh_l1d_full_multi_bmc",
        "Full-line stores with three endpoints and look-ahead full pairs.",
    ),
    ("coh_l1d_full_payload_bmc", "Store byte values with full-line stores."),
    (
        "coh_l1d_full_cover",
        "Full pair acquisition, data twin installation and partial-pair fallback covers.",
    ),
    ("coh_l1d_full_lookahead_cover", "A look-ahead full pair with three endpoints."),
    (
        "coh_l1d_withdraw_full_bmc",
        "Full-line control checks with absorbed puts withdrawn, as link stages need.",
    ),
    (
        "coh_l1d_withdraw_zero_bmc",
        "cbo.zero and full-line control checks with absorbed puts withdrawn.",
    ),
    (
        "coh_l1d_withdraw_full_payload_bmc",
        "Full-line store byte values with absorbed puts withdrawn.",
    ),
    (
        "coh_l1d_withdraw_zero_payload_bmc",
        "cbo.zero store byte values with absorbed puts withdrawn.",
    ),
    (
        "coh_l1d_withdraw_full_cover",
        "Absorbed put withdrawn beside a full-line pair or owed data twin.",
    ),
    (
        "coh_l1d_full_hold_cover",
        "Gather and pair holds and claimed credit at three and four records.",
    ),
    (
        "coh_l1d_buffer_contract_bmc",
        "The L1D drives the store buffer within the interface contract the buffer's proofs assume, with cbo.zero writes, full-line stores, free hints and three endpoints.",
    ),
    ("coh_l1d_data1_bmc", "Store and probe byte values in sector word 1."),
    ("coh_l1d_data2_bmc", "Store and probe byte values in sector word 2."),
    ("coh_l1d_data3_bmc", "Store and probe byte values in sector word 3."),
    (
        "bmc_load_same",
        "Loads through acceptance and installation of same-sector stores.",
    ),
    (
        "bmc_load_other",
        "Loads through acceptance and installation of different-sector stores.",
    ),
    (
        "bmc_load_same_probe_launch",
        "Probe-cycle launches dropped beside overlapping same-sector stores.",
    ),
    (
        "bmc_probe_kept_other",
        "Kept probe-cycle reads and C2b store_ack launches beside a different-sector store.",
    ),
    (
        "bmc_probe_kept_same",
        "Kept probe-cycle reads and C2b push_prev_q sector holds beside a same-sector other-dword store.",
    ),
    ("bmc_amo_same", "Same-sector store and AMO credit and drain through release."),
    ("bmc_amo_same_owner", "Same-sector buffered-store and atomic-owner exclusion."),
    (
        "bmc_amo_same_fatal",
        "Same-sector fatal status at frame 139, paired with fatal persistence induction.",
    ),
    (
        "prove_amo_same_fatal_sticky",
        "Fatal persistence after initial reset for the 140-frame AMO safety check.",
    ),
    ("bmc_amo_other", "Different-sector store and AMO credit, drain and ownership."),
    (
        "bmc_amo_other_fatal",
        "Different-sector fatal status at frame 139, paired with fatal persistence induction.",
    ),
    (
        "prove_amo_other_fatal_sticky",
        "Different-sector fatal persistence after initial reset for the AMO safety check.",
    ),
    ("bmc_sc", "SC handoff, acknowledgement and drain through release."),
    ("bmc_old", "Old load responses and fresh bytes across buffered stores."),
    ("cover_load", "Buffered store overlap with a younger load."),
    ("cover_old", "Delayed old response and a fresh load staged before drain."),
    ("cover_amo", "AMO retirement, delayed release and younger-store admission."),
    ("cover_amo_same", "Same-sector buffered stores and local AMO through release."),
    (
        "cover_amo_same_two",
        "Delayed same-sector two-record buffered stores and local AMO through release.",
    ),
    ("cover_amo_other_home", "Different-sector AMO home write lookup and release."),
    ("cover_sc", "SC retirement, delayed release and younger-store admission."),
    (
        "cover_edges_same",
        "Load staging at capture, acknowledgement, promotion and drain of same-sector stores.",
    ),
    (
        "cover_edges_same_combined",
        "Load staging at capture, acknowledgment and drain of combined same-sector stores.",
    ),
    (
        "cover_edges_other",
        "Load staging at capture, acknowledgement, promotion and drain of different-sector stores.",
    ),
    (
        "cover_probe_kept_other",
        "Reachability of kept probe-cycle reads, store_ack launches and sector holds across sectors.",
    ),
    (
        "cover_probe_kept_same",
        "Reachability of kept probe-cycle reads and store_ack sector holds across dwords in one sector.",
    ),
    ("coh_l1d_store_payload_bmc", "Ordered head payload and masked hit installation."),
    ("coh_l1d_store_grant_bmc", "Store miss byte merging against grant bytes."),
    (
        "coh_l1d_store_multi_payload_bmc",
        "Ordered store bytes with concurrent endpoints.",
    ),
    (
        "coh_l1d_store_multi_grant_bmc",
        "Concurrent store grants merge only the head record.",
    ),
    (
        "coh_l1d_answer_bmc",
        "Grant answers and same-sector merges complete each read once, in order "
        "with stores and probes.",
    ),
    (
        "coh_l1d_stream_answer_bmc",
        "Speculative grants answer attached loads; merges keep store and probe order.",
    ),
    (
        "coh_l1d_data_bmc",
        "Arbitrary-byte store and probe images in the production array.",
    ),
    ("coh_l1d_cover", "Buffered stores, ordered installation, probes and errors."),
    (
        "coh_l1d_path_cover",
        "Hit-path answers, shadow lookups and the hit path's refusals with free inputs.",
    ),
    (
        "coh_l1d_put_select_prove",
        "The W selection releases a slot without a put on the next edge.",
    ),
    (
        "lookup_prove",
        "L1D lookup address selected last by head readiness equals the reference, one miss slot.",
    ),
    (
        "lookup_multi_prove",
        "L1D lookup address selected last by head readiness equals the reference, three miss slots.",
    ),
    (
        "lookup_stream_prove",
        "L1D lookup address selected last by head readiness equals the reference, eight slots, streaming.",
    ),
    ("coh_array_select_prove", "Conditional data selection with one way."),
    ("coh_array_select4_prove", "Conditional data selection with four ways."),
    ("coh_array_select56_prove", "Conditional data selection at 56 address bits."),
    ("coh_array_select4_56_prove", "Four-way conditional data selection at 56 bits."),
    ("coh_array_cover", "Masked byte updates and tag-only hits in block RAM."),
    ("coh_array_uram_cover", "Masked byte updates and tag-only hits in UltraRAM."),
    ("coh_array_plru_prove", "Deferred hit replacement equality in block RAM."),
    (
        "coh_array_plru_uram_prove",
        "Deferred hit replacement equality with UltraRAM tags.",
    ),
    (
        "coh_array_plru_bimodal_prove",
        "Deferred hit replacement equality with bimodal insertion.",
    ),
    ("coh_array_plru_cover", "Deferred hit writes and following lookups in block RAM."),
    (
        "coh_array_plru_uram_cover",
        "Deferred hit writes and following lookups with UltraRAM tags.",
    ),
    (
        "coh_array_plru_bimodal_cover",
        "Insertions that update replacement state under bimodal insertion.",
    ),
    (
        "coh_array_plru_port_prove",
        "Replacement equality with hit-port touches beside the array's writes.",
    ),
    (
        "coh_array_plru_port_cover",
        "Hit-port touches applied beside a hit and dropped under an array write.",
    ),
    (
        "coh_hart_maint_prove",
        "Buffered store installation, fence invalidation and coherent reads, with proven cache image facts.",
    ),
    (
        "coh_hart_maint_owned_prove",
        "Independent image, fill and walker invariants plus 21 maintenance checks by induction.",
    ),
    (
        "coh_hart_maint_owned_reset_prove",
        "The same induction from the state after the reset cycle, every other register free.",
    ),
    (
        "coh_hart_maint_free_owned_prove",
        "Independent PDR proof of all maintenance ownership facts with free initial values.",
    ),
    (
        "coh_hart_maint_free_prove",
        "Maintenance visibility and completion using ownership facts on the same free-state model.",
    ),
    (
        "coh_hart_maint_cover",
        "Discard, PutM absorption, old fills and delayed completions.",
    ),
    ("coh_home_engine_prove", "Resident image values and held service payloads."),
    ("coh_home_engine64_prove", "Sector image values in a two-sector resident line."),
    ("coh_home_engine_cover", "Coincident dirty reply/data and failed SC completion."),
    ("coh_dma_ingress_prove", "DMA credits, payloads, and identity conservation."),
    ("coh_dma_ingress_cover", "Full DMA admission and delayed error completion."),
    (
        "coh_dma_ingress_soc_prove",
        "DMA identity and payload conservation with eight credits.",
    ),
    (
        "coh_dma_ingress_soc_cover",
        "Eight DMA credits, queue wrap, drain, and ID reuse.",
    ),
    ("pc_tage_events_prove", "Unbounded history event equivalence"),
    ("pc_tage_events_cover", "History event and suppression reachability"),
    (
        "pd_id_slot2_bmc",
        "Bounded PD and ID composition check for slot-2 prediction overrides",
    ),
    (
        "pd_id_slot2_cover",
        "Reachability of slot-2 taken overrides, not-taken vetoes, and stall holds",
    ),
    (
        "pd_id_slot2_vector_bmc",
        "Bounded PD and ID composition check for slot-2 prediction overrides with the "
        "vector floating-point decode",
    ),
    (
        "pd_id_slot2_vector_cover",
        "Reachability of slot-2 taken overrides, not-taken vetoes, and stall holds with the "
        "vector floating-point decode",
    ),
    (
        "if_slot2_precompute_bmc",
        "Bounded IF slot-2 TAGE coverage, decode, and target-candidate check",
    ),
    (
        "if_slot2_precompute_cover",
        "Reachability of live and stall-replayed slot-2 TAGE-covered packets",
    ),
    ("coh_rs_payload4_prove", "Coherent payload storage equality at four entries."),
    ("coh_rs_payload8_prove", "Coherent payload storage equality at eight entries."),
    ("coh_rs_payload16_prove", "Coherent payload storage equality at sixteen entries."),
    ("coh_rs_payload_wide_prove", "Coherent payload storage equality at 125 bits."),
    (
        "coh_rs_control_prove",
        "Coherent allocation masks and issue, immediate, shift and count controls with three sources.",
    ),
    (
        "coh_rs_control_int_prove",
        "Coherent integer allocation masks and issue, immediate, shift and count equality.",
    ),
    (
        "coh_rs_control_window_prove",
        "Coherent allocation masks and issue controls with a five-entry window.",
    ),
    (
        "coh_rs_control_partial_prove",
        "Coherent issue controls with a partial primary payload group.",
    ),
    (
        "coh_rs_control_mul_prove",
        "Coherent allocation and count controls in the multiply station.",
    ),
    ("coh_rs_issue2_8_prove", "Coherent second-issue equality at eight entries."),
    ("coh_rs_issue2_16_prove", "Coherent second-issue equality at sixteen entries."),
    ("coh_rs_issue2_5_prove", "Coherent second-issue equality at five entries."),
    ("coh_rs_issue2_2_prove", "Coherent second-issue equality at two entries."),
    ("coh_rs_issue2_3_prove", "Coherent second-issue equality at three entries."),
    ("debug_request_count_prove", "Coherent debug request count at eight bits."),
    ("debug_request_count4_prove", "Coherent debug request count at four bits."),
    ("coh_rs_capacity4_prove", "Coherent capacity equality at four entries."),
    ("coh_rs_capacity8_prove", "Coherent capacity equality at eight entries."),
    ("coh_rs_capacity16_prove", "Coherent capacity equality at sixteen entries."),
    ("coh_c_payload_prove", "Completion payload equality outside reset at fifty bits."),
    (
        "coh_c_payload_wide_prove",
        "Completion payload equality outside reset at seventy-four bits.",
    ),
    ("debug_dirty_next_prove", "Debug dirty-word clear and set priority."),
    ("coh_sc_class_small_prove", "Coherent SC class for an aligned four-KiB region."),
    ("coh_sc_class_offset_prove", "Coherent SC class for an unaligned base."),
    ("coh_sc_class_size_prove", "Coherent SC class for a non-power-of-two size."),
    ("coh_sc_class_zero_prove", "Coherent SC class for an empty region."),
    ("coh_sc_class_wrap_prove", "Coherent SC class for a wrapping region limit."),
    ("mirror_hold_prove", "Debug mirror address equality at sixteen bits."),
    ("mirror_hold15_prove", "Debug mirror address equality at fifteen bits."),
    ("mirror_hold32_prove", "Debug mirror address equality at thirty-two bits."),
    (
        "coh_read_capture_prove",
        "Read data capture for both endpoint-zero install classes.",
    ),
    ("coh_read_capture_stream_prove", "Read data capture with stream endpoints."),
    ("coh_idle_select_prove", "Idle phase and operation selection with one endpoint."),
    (
        "coh_idle_select_stream_prove",
        "Idle phase and operation selection with stream endpoints.",
    ),
    (
        "coh_idle_phase_prove",
        "Idle phase and endpoint-zero install class with one endpoint.",
    ),
    (
        "coh_idle_phase_stream_prove",
        "Idle phase and endpoint-zero install class with stream endpoints.",
    ),
    ("coh_read_kind_prove", "Per-slot read kinds equal buffered allocation payloads."),
    ("coh_array_reply_prove", "Registered response indication with block RAM."),
    (
        "coh_array_reply4_prove",
        "Registered response indication with four block-RAM ways.",
    ),
    ("coh_array_reply_uram_prove", "Registered response indication with UltraRAM."),
    (
        "coh_array_reply4_uram_prove",
        "Registered response indication with four UltraRAM ways.",
    ),
    ("coh_read_payload_prove", "Coherent read payload storage at 32 address bits."),
    ("coh_read_payload64_prove", "Coherent read payload storage at 64 address bits."),
    ("bmc_core", "Load-result selection with the CPU feature configuration."),
    (
        "bmc_cpu",
        "The store-queue reference check (live count or same-sector claim) with the CPU's store-queue, dispatch, precise and Normal-memory settings.",
    ),
    ("coh_lq_capture4_prove", "Coherent capture equality at four entries."),
    ("coh_lq_capture8_prove", "Coherent capture equality at eight entries."),
    ("coh_lq_capture16_prove", "Coherent capture equality at sixteen entries."),
    (
        "coh_lq_capture_no_forward_prove",
        "Coherent capture equality without forwarding.",
    ),
    ("coh_lq_capture_no_l0_prove", "Coherent capture equality without L0 completion."),
    (
        "coh_lq_capture_plain_prove",
        "Coherent capture equality without local completion.",
    ),
    ("coh_lq_capture8_xilinx_prove", "Coherent capture equality with primitive LUTs."),
    ("lookup8_prove", "L0 permission equality at 8 entries using portable logic."),
    (
        "lookup8_xilinx_prove",
        "L0 permission equality at 8 entries using primitive LUTs.",
    ),
    ("lookup16_prove", "L0 permission equality at 16 entries using portable logic."),
    (
        "lookup16_xilinx_prove",
        "L0 permission equality at 16 entries using primitive LUTs.",
    ),
    ("lookup32_prove", "L0 permission equality at 32 entries using portable logic."),
    (
        "lookup32_xilinx_prove",
        "L0 permission equality at 32 entries using primitive LUTs.",
    ),
    ("lookup128_prove", "L0 permission equality at 128 entries using portable logic."),
    (
        "lookup128_xilinx_prove",
        "L0 permission equality at 128 entries using primitive LUTs.",
    ),
    ("lookup256_prove", "L0 permission equality at 256 entries using portable logic."),
    (
        "lookup256_xilinx_prove",
        "L0 permission equality at 256 entries using primitive LUTs.",
    ),
    ("lookup512_prove", "L0 permission equality at 512 entries using portable logic."),
    (
        "lookup512_xilinx_prove",
        "L0 permission equality at 512 entries using primitive LUTs and wide multiplexers.",
    ),
    (
        "age_groups_prove",
        "Portable entry eligibility, age-group selection and tails padded with zeros.",
    ),
    (
        "age_groups_xilinx_prove",
        "Primitive entry eligibility, age-group selection and tails padded with zeros.",
    ),
    (
        "capture_pins_prove",
        "Portable capture and release selection for every input combination.",
    ),
    (
        "capture_pins_xilinx_prove",
        "Capture and release LUT INITs for every input combination.",
    ),
    ("result4_prove", "Result-valid next state for four load entries."),
    ("result8_prove", "Result-valid next state for eight load entries."),
    ("result16_prove", "Result-valid next state for sixteen load entries."),
    ("result_no_forward_prove", "Result validity with store forwarding disabled."),
    ("result_no_l0_prove", "Result validity with L0 completion disabled."),
    (
        "result_plain_prove",
        "Result validity with both local completion paths disabled.",
    ),
    ("result8_xilinx_prove", "Result-valid next state through the primitive LUTs."),
    (
        "result_pins_prove",
        "Completion, response and allocation for arbitrary portable inputs.",
    ),
    (
        "result_pins_xilinx_prove",
        "Completion, response and allocation INITs for arbitrary pin inputs.",
    ),
    ("sector_copy_prove", "Staged sector-match copy equals the indexed select."),
    (
        "sector_copy_xilinx_prove",
        "Staged sector-match copy equals the indexed select with FDRE index cells.",
    ),
    ("coh_l0_flags_prove", "Coherent L0 next-state equality at 128 entries."),
    ("coh_l0_flags256_prove", "Coherent L0 next-state equality at 256 entries."),
    (
        "coh_sc_selected_prove",
        "Selected SC payload survives flushes through its result.",
    ),
    (
        "coh_lq_cut_prove",
        "Coherent cuts block load launches and local fast paths; "
        "invalidated LR responses cannot renew reservations.",
    ),
    ("coh_lq_forward_prove", "Coherent forwarding obeys cuts and same-sector holds."),
    (
        "coh_lq_forward_normal_prove",
        "Coherent forwarding and Normal-cache controls obey local invariants.",
    ),
    (
        "coh_lq_busy_prove",
        "Coherent capture obeys busy gating with load preparation disabled.",
    ),
    (
        "coh_lq_normal_fill_prove",
        "Coherent L0 fill permission agrees for both response sources.",
    ),
    (
        "coh_lq_cut_probe_launch_prove",
        "Coherent cuts block probe-cycle launches and preserve LR reservation invariants.",
    ),
    (
        "coh_lq_forward_probe_launch_prove",
        "Coherent forwarding and probe-cycle launches obey cuts and same-sector holds.",
    ),
    (
        "coh_lq_forward_normal_probe_launch_prove",
        "Coherent forwarding, Normal-cache controls and probe-cycle launches obey local invariants.",
    ),
    (
        "coh_lq_busy_probe_launch_prove",
        "Coherent capture and probe-cycle launches obey busy gating with load preparation disabled.",
    ),
    (
        "coh_lq_normal_fill_probe_launch_prove",
        "Coherent L0 fill permission agrees for both response sources with probe-cycle launches enabled.",
    ),
    (
        "coh_address_class_prove",
        "Coherent address slots carry exact PMA and cache classes.",
    ),
    (
        "coh_candidate_select_prove",
        "Coherent candidate selection matches its registered index.",
    ),
    ("coh_lq_selector_prove", "Coherent issue selection matches both SQ drain states."),
    ("coh_lq_selector4_prove", "Coherent issue selection matches at depth four."),
    ("coh_lq_selector16_prove", "Coherent issue selection matches at depth sixteen."),
    (
        "coh_read_flags_prove",
        "Coherent read flags preserve response and completion priority.",
    ),
    (
        "coh_read_select_prove",
        "Coherent reads preserve blocked-slot circular priority.",
    ),
    ("coh_read_select64_prove", "Coherent read selection covers full-width addresses."),
    (
        "coh_read_select_xilinx_prove",
        "Coherent read selection built from LUT primitives matches the reference.",
    ),
    (
        "coh_read_select64_xilinx_prove",
        "Primitive-form coherent read selection at full-width addresses.",
    ),
    ("coh_l1d_bmc", "Coherent L1 pending ownership and independent probes."),
    (
        "coh_l1d_multi_bmc",
        "Coherent L1 with three request endpoints: line exclusion and waiters.",
    ),
    (
        "coh_home_wb_prove",
        "Detached victim ownership through B and forwarded sector bytes.",
    ),
    ("coh_home_victim_cover", "Victim allocation, delayed B, and blocked refetch."),
    ("coh_home_error_cover", "Failed B preserves dirty victim ownership."),
    (
        "coh_completions_prove",
        "Completion identity, pin lifetime, and predecessor order.",
    ),
    (
        "coh_completions_pairs_prove",
        "A prefetch's no-fill flag covers every live demand for its block.",
    ),
    (
        "coh_completions_partition_prove",
        "Kept prefetch slots: admission, unordered prefetches, and G taken on arrival.",
    ),
    (
        "coh_completions_partition2_prove",
        "Two kept prefetch slots sharing one place in the work rotation.",
    ),
    (
        "coh_completions_fast_prove",
        "Direct D selection and registered work metadata with completion invariants.",
    ),
    (
        "coh_completions_fast_partition_prove",
        "Direct D selection with a completion slot kept for prefetches.",
    ),
    (
        "coh_completions_cover",
        "Concurrent results, independent release and a suppressed DMA read through release.",
    ),
    (
        "coh_completions_partition_cover",
        "A full prefetch partition and a prefetch slot's G taken.",
    ),
    (
        "coh_completions_partition2_cover",
        "The prefetch rotation passing over an offered prefetch slot.",
    ),
    (
        "coh_completions_fast_cover",
        "Direct D selection reachability alongside blocked or prefetch admissions.",
    ),
    ("coh_seat_select_prove", "Fill waiter ranks match serial seat allocation."),
    (
        "coh_work_select_prove",
        "Encoded and one-hot ready/circular selection match serial priority, "
        "with the last pick coded.",
    ),
    ("coh_home_forward1_prove", "One-fill forward choice matches the reference."),
    ("coh_home_forward3_prove", "Three-fill forward choice matches the reference."),
    ("coh_home_forward8_prove", "Eight-fill forward choice matches the reference."),
    (
        "coh_home_forward1_xilinx_prove",
        "Primitive one-fill forward choice matches the reference.",
    ),
    (
        "coh_home_forward3_xilinx_prove",
        "Primitive three-fill forward choice matches the reference.",
    ),
    (
        "coh_home_forward8_xilinx_prove",
        "Primitive eight-fill forward choice matches the reference.",
    ),
    ("coh_home_control_prove", "Composed home ownership and independent memory debt."),
    ("coh_home_control64_prove", "Composed home ownership across sibling sectors."),
    (
        "coh_home_control_partition_prove",
        "Composed home ownership with a completion slot kept for prefetches.",
    ),
    (
        "coh_home_control_ultra_prove",
        "Composed home ownership and parallel-read delivery bounds with UltraRAM.",
    ),
    (
        "coh_home_control_ultra_fast_prove",
        "Composed UltraRAM home ownership and parallel-read bounds with direct tag launch.",
    ),
    (
        "coh_home_control_fast_prove",
        "Composed home ownership with direct D selection and direct tag launch.",
    ),
    (
        "coh_home_control64_fast_prove",
        "Composed home ownership across sibling sectors with direct tag launch.",
    ),
    (
        "coh_home_control_partition_fast_prove",
        "Composed home ownership with prefetch slots and direct tag launch.",
    ),
    (
        "coh_home_control4_bmc",
        "Bounded home checks with four ways, three fills and a fill reserve.",
    ),
    (
        "coh_home_control4_ultra_bmc",
        "Bounded four-way home checks with the registered tag array.",
    ),
    (
        "coh_home_control4_ultra_fast_bmc",
        "Bounded four-way registered-tag home checks with direct tag launch.",
    ),
    (
        "coh_home_prefetch_cover",
        "Prefetch fills that install, gain a seat or fail; reserve and no-fill decisions.",
    ),
    ("coh_home_fill_cover", "Fill installation, forward and waiter wake reachability."),
    (
        "coh_home_cmo_cover",
        "Reach four Zicbom grant cases and replay their inputs on the undriven home.",
    ),
    (
        "coh_home_cmo_fast_cover",
        "Reach Zicbom grants and dirty fast-launch write-back with direct tag launch, replayed undriven.",
    ),
    (
        "coh_home_dispatch_cover",
        "A dispatch-cycle lookup offer that loses the tag arbiter and wins from Lookup.",
    ),
    (
        "coh_home_fast_cover",
        "Direct tag launch for demand, prefetch and management work plus arbiter fallback.",
    ),
    ("coh_home_array_prove", "Independent L2 ports preserve watched bytes."),
    *[
        (
            f"coh_home_array_uram_byte{lane}_prove",
            f"Registered L2 ports preserve byte {lane} and exclude row collisions.",
        )
        for lane in range(64)
    ],
    (
        "coh_home_array_cover",
        "Tag, read and update ports operate concurrently in block RAM.",
    ),
    *[
        (
            f"coh_home_array_uram4_byte{lane}_prove",
            f"Four-way banked UltraRAM L2 ports preserve byte {lane} across parallel reads.",
        )
        for lane in (0, 31, 32, 63)
    ],
    (
        "coh_home_array_uram_cover",
        "Four-way UltraRAM ports operate concurrently and reach a kept parallel read.",
    ),
    (
        "coh_snapshot_versions_bmc",
        "Snapshot bytes across a later M-hit store and DMA write.",
    ),
    (
        "coh_snapshot_versions_cover",
        "A held first grant, a changed byte and both publications.",
    ),
    ("coh_array_bmc", "Coherent array byte values and held responses."),
    ("coh_array_uram_bmc", "Coherent array byte values through registered RAM ports."),
    ("coh_array4_bmc", "Coherent array byte values and held responses with four ways."),
    ("coh_array4_uram_bmc", "Four-way coherent array byte values in UltraRAM."),
    ("coh_array_port_bmc", "Hit-port tags and byte values beside lookups, one way."),
    ("coh_array4_port_bmc", "Hit-port tags and byte values beside lookups, four ways."),
    ("coh_array4_port_cover", "Hit-port hits beside lookups and after writes."),
    ("coh_array4_snapshot_cover", "Same-set Modified tags with different home copies."),
    ("coh_array4_uram_snapshot_cover", "Same-set snapshot selection in packed tags."),
    ("coh_array_equiv_bmc", "Cycle equivalence with the reference array, one way."),
    ("coh_array_equiv_data0_bmc", "One-way response data equivalence in byte lane 0."),
    (
        "coh_array_equiv_data31_bmc",
        "One-way response data equivalence in byte lane 31.",
    ),
    ("coh_array_equiv4_bmc", "Cycle equivalence with the reference array, four ways."),
    (
        "coh_array_equiv4_data0_bmc",
        "Four-way response data equivalence in byte lane 0.",
    ),
    (
        "coh_array_equiv4_data17_bmc",
        "Four-way response data equivalence in byte lane 17.",
    ),
    (
        "coh_array_equiv4_bimodal_bmc",
        "Four-way cycle equivalence with bimodal insertion.",
    ),
    (
        "coh_array_equiv_uram_bmc",
        "Cycle equivalence with the reference array in UltraRAM.",
    ),
    (
        "coh_array_equiv_uram_data5_bmc",
        "UltraRAM response data equivalence in byte lane 5.",
    ),
    ("coh_array_equiv4_uram_bmc", "Four-way cycle equivalence in UltraRAM."),
    (
        "coh_array_equiv_port_bmc",
        "Cycle equivalence with hit-port reads beside the lookups, one way.",
    ),
    (
        "coh_array_equiv_port_data0_bmc",
        "Byte lane 0 data equivalence with hit-port reads beside the lookups.",
    ),
    (
        "coh_array_equiv_cover",
        "Data hits, insertions and no-bank store hits and misses.",
    ),
    (
        "coh_progress_prove",
        "One-way array progress under two independent load streams.",
    ),
    ("coh_progress4_prove", "Four-way array progress with common replacement touches."),
    (
        "coh_progress4_56_prove",
        "Four-way controller progress with 56-bit physical addresses.",
    ),
    (
        "coh_progress4_cover",
        "Independent load takes and touches, consecutive offers and held replies.",
    ),
    (
        "coh_store_bank_class_bmc",
        "Store lookup class, sealed head, response and seven scratch-byte consumers.",
    ),
    (
        "coh_store_bank_taint_prove",
        "A scratch row cannot enter an active byte consumer.",
    ),
    (
        "coh_store_bank_cover",
        "Store miss scratch, its capture, overlapping offers and fast probes.",
    ),
    (
        "coh_arbiter24_prove",
        "Twenty-four-way held arbitration and circular selection equality.",
    ),
    ("coh_arbiter_prove", "Coherent arbitration preserves held payloads."),
    (
        "coh_arbiter_held_prove",
        "Captured arbitration validity matches held source offers.",
    ),
    (
        "coh_arbiter_bypass_prove",
        "Idle pass-through arbitration preserves payloads and hold contracts.",
    ),
    (
        "coh_if_pair_cover",
        "Two IF identities coexist, complete out of order and are reused after U.",
    ),
    (
        "coh_reader_prove",
        "IF response at grant and identity ownership through release.",
    ),
    ("coh_reader_cover", "Early IF response, stalls, errors and reset reachability."),
    (
        "coh_reader_slot1_prove",
        "Second IF identity responds at grant and survives through release.",
    ),
    ("coh_reader_slot1_cover", "Second IF response and ownership tail reachability."),
    (
        "coh_ptw_reader_prove",
        "PTW response at grant and identity ownership through release.",
    ),
    ("coh_ptw_reader_cover", "PTW response, errors, stalls and reset reachability."),
    (
        "coh_ptw_reader_slot1_prove",
        "Second PTW identity responds at grant and survives through release.",
    ),
    (
        "coh_ptw_reader_slot1_cover",
        "Second PTW response and ownership tail reachability.",
    ),
    ("coh_reader_late_prove", "Default reader response follows release."),
    ("coh_ingress_prove", "DMA identities survive through release."),
    ("coh_atomic_guard_prove", "Atomic protection covers retirement and release."),
    ("coh_atomic_select_prove", "Atomic source qualification at five tag bits."),
    ("coh_atomic_select_wide_prove", "Atomic source qualification at nine tag bits."),
    (
        "coh_atomic_pair_prove",
        "Atomic guard state equality after source qualification.",
    ),
    ("coh_atomic_pair_wide_prove", "Atomic guard state equality at nine tag bits."),
    ("layout32", "Coherent channel layout at 32 physical address bits"),
    ("layout56", "Coherent channel layout at 56 physical address bits"),
    ("request_prove", "Unbounded coherent endpoint safety"),
    ("request_cover", "Coherent endpoint completion reachability"),
    ("request_equiv32", "Request endpoint phase and payload equivalence at 32 bits"),
    ("request_equiv56", "Request endpoint phase and payload equivalence at 56 bits"),
    ("request_equiv_slot0", "Request endpoint slot-zero phase equivalence"),
    ("request_equiv_wide_slot0", "Wide request endpoint slot-zero phase equivalence"),
    ("request_equiv_ptw", "PTW request endpoint phase equivalence"),
    ("request_equiv_wide_ptw", "Wide PTW request endpoint phase equivalence"),
    ("request_equiv_cover", "Request endpoint complete lifecycle reachability"),
    ("home_prove", "Unbounded coherent endpoint safety"),
    ("home_cover", "Coherent endpoint completion reachability"),
    ("put_prove", "Unbounded coherent endpoint safety"),
    ("put_cover", "Coherent endpoint completion reachability"),
    ("channel_prove", "Unbounded coherent endpoint safety"),
    ("channel_cover", "Coherent endpoint completion reachability"),
    ("home_wide", "Coherent home safety with wide physical addresses"),
    (
        "home_pending_prove",
        "Home pending mask equals admission-clear reference after reset.",
    ),
    (
        "home_pending_wide_prove",
        "Home pending-mask equality with wide physical addresses.",
    ),
    (
        "home_pending_cover",
        "Home pending-mask equality through absorption and release.",
    ),
    ("prove_engine", "Unbounded AXI4-Lite mapping for the DMA register bank"),
    ("msi_bmc", "Bounded APLIC MSI forwarding and pending transitions"),
    ("msi_prove", "Unbounded APLIC MSI registers, forwarding and ordering"),
    (
        "msi_cover",
        "APLIC MSI acceptance, backpressure, delegation and lock reachability",
    ),
    ("msi_prove_32", "Unbounded APLIC MSI with 32-bit addresses and three harts"),
    (
        "msi_prove_locked",
        "Unbounded APLIC MSI with address configuration locked at reset",
    ),
    ("msi_prove_wide", "Unbounded APLIC MSI with two words of source bits"),
    ("msi_prove_four_harts", "MSI proof with four harts and 56-bit addresses"),
    ("bmc_strict", "Bounded check with strict uncached Normal memory"),
    ("bmc_normal", "Bounded check with Normal read caching"),
    ("bmc_legacy", "Bounded check with legacy unconditional data caching"),
    ("x32", "Unbounded catch-up contracts at XLEN 32"),
    ("x64", "Unbounded catch-up contracts at XLEN 64"),
    ("x66", "Unbounded catch-up contracts at XLEN 66"),
    ("on", "Unbounded equivalence with launch squash enabled"),
    ("off", "Unbounded equivalence with launch squash disabled"),
    ("prove_bin", "Unbounded shared-link memory equivalence with binary reads"),
    ("prove_oh", "Unbounded shared-link memory equivalence with one-hot reads"),
    ("prove_narrow_bin", "Unbounded narrow-link memory equivalence with binary reads"),
    ("prove_narrow_oh", "Unbounded narrow-link memory equivalence with one-hot reads"),
    ("bmc_mshr8", "Bounded check with eight miss-status slots"),
    ("bmc_ways1", "Bounded check of a direct-mapped cache"),
    ("bmc_delayed", "Bounded check with delayed (UltraRAM) tags"),
    ("bmc_fast", "Bounded check with the simulation bulk clear"),
    (
        "bmc_fast_ways1",
        "Bounded check of a direct-mapped cache with the simulation bulk clear",
    ),
    ("bmc_hw", "Bounded check of the hardware maintenance path"),
    ("cover_fast", "Reachability covers with the simulation bulk clear"),
    ("cover_fast_ways1", "Watched-line covers for the direct-mapped flash cache"),
    ("cover_hw", "Watched-line covers for the hardware flash-invalidate path"),
    ("bmc_free_bin", "Bounded shared-link memory equivalence with free binary reads"),
    ("bmc_free_oh", "Bounded shared-link memory equivalence with free one-hot reads"),
    (
        "bmc_free_small_bin",
        "Bounded small-datapath memory equivalence with free binary reads",
    ),
    (
        "bmc_free_small_oh",
        "Bounded small-datapath memory equivalence with free one-hot reads",
    ),
    ("cover_bin", "Shared-link staging and collision reachability with binary reads"),
    ("cover_oh", "Shared-link staging and collision reachability with one-hot reads"),
    (
        "p00",
        "Dispatch branch contract with direct slot-2 validity and corrected operands",
    ),
    ("p01", "Dispatch branch contract with direct slot-2 validity and raw operands"),
    (
        "p10",
        "Dispatch branch contract with bundle slot-2 validity and corrected operands",
    ),
    ("p11", "Dispatch branch contract with bundle slot-2 validity and raw operands"),
    ("bmc_export", "Bounded equivalence with candidate ready vectors exported"),
    (
        "bmc_export_tag_indexed",
        "Bounded ready-vector equivalence with indexed issue tags",
    ),
    ("bmc_ready_vector", "Bounded equality of the exported and issue ready vectors"),
    (
        "pick8_bmc",
        "Bounded ready-pick equivalence with eight candidates and eight RS entries",
    ),
    (
        "pick8_prove",
        "Unbounded ready-pick equivalence with eight candidates and eight RS entries",
    ),
    (
        "pick4_bmc",
        "Bounded ready-pick equivalence with four candidates and eight RS entries",
    ),
    (
        "pick4_prove",
        "Unbounded ready-pick equivalence with four candidates and eight RS entries",
    ),
    (
        "pickg4_bmc",
        "Bounded ready-pick equivalence with four candidates and the generic four-entry pick",
    ),
    (
        "pickg4_prove",
        "Unbounded ready-pick equivalence with four candidates and the generic four-entry pick",
    ),
    (
        "pickg6_bmc",
        "Bounded ready-pick equivalence with eight candidates and the generic six-entry pick",
    ),
    (
        "pickg6_prove",
        "Unbounded ready-pick equivalence with eight candidates and the generic six-entry pick",
    ),
    (
        "prove_victim0",
        "Unbounded fetch-shadow equivalence with the victim store disabled",
    ),
    ("prove_victim1", "Unbounded fetch-shadow equivalence with one victim entry"),
    ("prove_direct", "Unbounded grouped direct-fetch payload equivalence"),
    ("cover_direct", "Direct-fetch responses coincident with clears and errors"),
    ("bmc_repair", "Bounded equivalence with insertion-time repair enabled"),
    ("prove_integrated", "Unbounded proof under the integrated interface contract"),
    (
        "prove_slot2_veto_redundant",
        "Unbounded induction that intact if_stage makes the slot-2 fetch-fault veto redundant",
    ),
    ("prove_copy", "Staged address copies sample identical inputs on every edge"),
    ("prove_perf_off", "Unbounded proof with profiling counters absent"),
    ("prove_vector", "Unbounded proof with vector state enabled"),
    ("bmc_raw", "Bounded equivalence with eight raw-wakeup candidates"),
    ("prove_raw", "Unbounded equivalence with eight raw-wakeup candidates"),
    ("bmc_forward", "Bounded equivalence with store forwarding enabled"),
    ("bmc_forward_only", "Bounded equivalence with store forwarding and no L0"),
    ("bmc_integrated_xilinx", "Bounded integrated equivalence with Xilinx primitives"),
    ("bmc4", "Bounded local equivalence at depth 4"),
    ("bmc8", "Bounded local equivalence at depth 8"),
    ("bmc16", "Bounded local equivalence at depth 16"),
    ("bmc32", "Bounded local equivalence at depth 32"),
    ("bmc_1g", "Bounded physical-address check at a 1 GiB DDR capacity"),
    ("bmc_small", "Disabled alias decode and NC/IO leaf faults on the 256 MiB DDR map"),
    ("bmc_2g", "Svpbmt translation and alias refusal at a 2 GiB DDR capacity"),
    ("cover_2g", "Svpbmt no-alias faults and device-page translations at 2 GiB"),
    ("bmc_4g", "Svpbmt alias range equivalence at a 4 GiB DDR capacity"),
    ("bmc_8g", "Svpbmt alias range equivalence at an 8 GiB DDR capacity"),
    ("bmc_16g", "Svpbmt alias range equivalence at a 16 GiB DDR capacity"),
    ("bmc_32g", "Svpbmt alias range equivalence at a 32 GiB DDR capacity"),
    (
        "bmc_external",
        "Svpbmt walker response and leaf payload outside the FROST physical map",
    ),
    (
        "cover_external",
        "Svpbmt no-alias faults and device translations outside the FROST map",
    ),
    ("prove_full_width", "Unbounded proof with a bus as wide as a line"),
    (
        "prove_soc",
        "Unbounded proof at SoC bus widths; AXI bridge uses four bursts and IDs "
        "per direction, paired with prove_soc_held",
    ),
    ("prove_soc_held", "Four-burst AXI bridge B-channel stability partition"),
    ("bmc_soc", "Bounded check with SoC burst and line-ID capacities"),
    ("prove_soc4", "Unbounded proof of the four-port SoC AXI mux"),
    (
        "prove_soc8_0",
        "Eight-burst AXI bridge safety, explicit assertion partition 0 of nine",
    ),
    (
        "prove_soc8_1",
        "Eight-burst AXI bridge safety, explicit assertion partition 1 of nine",
    ),
    (
        "prove_soc8_2",
        "Eight-burst AXI bridge safety, explicit assertion partition 2 of nine",
    ),
    (
        "prove_soc8_3",
        "Eight-burst AXI bridge safety, explicit assertion partition 3 of nine",
    ),
    (
        "prove_soc8_4",
        "Eight-burst AXI bridge safety, explicit assertion partition 4 of nine",
    ),
    (
        "prove_soc8_5",
        "Eight-burst AXI bridge safety, explicit assertion partition 5 of nine",
    ),
    (
        "prove_soc8_6",
        "Eight-burst AXI bridge safety, explicit assertion partition 6 of nine",
    ),
    (
        "prove_soc8_7",
        "Eight-burst AXI bridge safety, explicit assertion partition 7 of nine",
    ),
    (
        "prove_soc8_8",
        "Eight-burst AXI bridge safety, explicit assertion partition 8 of nine",
    ),
    (
        "cover_soc",
        "SoC burst and ID capacity, allocator wrap, reordered replies, drain, and reuse",
    ),
    ("prove_256m", "Inductive entry verdict checks on a 256 MiB DDR map"),
    (
        "cover_256m",
        "Reach a gigapage crossing the DDR limit and an NC load at the disabled alias",
    ),
    ("bmc_64g", "Bounded physical-address check at a 64 GiB DDR capacity"),
    ("bmc_128g", "Bounded physical-address check at a 128 GiB DDR capacity"),
    ("cover_64g", "Physical-address reachability at a 64 GiB DDR capacity"),
    ("cover_128g", "Physical-address reachability at a 128 GiB DDR capacity"),
    ("bmc_xilinx", "Bounded equivalence with the Xilinx primitive implementation"),
    ("bmc_32", "Bounded equivalence with 32-bit addresses"),
    (
        "bmc_32_xilinx",
        "Bounded equivalence with 32-bit addresses and Xilinx primitives",
    ),
    ("bmc_2port", "Bounded two-port arbitration equivalence"),
    ("bmc_xilinx_2port", "Bounded two-port arbitration with Xilinx primitives"),
    ("bmc_queued", "Bounded check with decoded-queue admission contract"),
    (
        "bmc_queued_vector",
        "Queued admission with registered vector and station classes",
    ),
    (
        "vhold_lq_bmc",
        "Vector range holds with the load queue's address-update port, 8 frames.",
    ),
    (
        "vhold_sq_bmc",
        "Vector range holds with the store queue's per-entry addresses, 8 frames.",
    ),
    (
        "vhold_lq_cover",
        "Vector range-hold reachability with the load queue's address-update port, 16 frames.",
    ),
    (
        "vmt_bmc",
        "Vector memory table lifecycle against a ghost reorder buffer, 14 frames.",
    ),
    (
        "stride_bmc",
        "Strided head run: element order, translation first, precise faults, 60 frames.",
    ),
    ("stride_cover", "Strided head run reachability: retirement, mid-run fault, tag."),
    (
        "index_bmc",
        "Indexed head run: index reads, order, translation first, precise faults, 60 frames.",
    ),
    ("index_cover", "Indexed head run reachability: retirement, mid-run fault."),
    ("bmc", "Check assertions up to the configured depth"),
    ("bmc_cdb", "Compare the first valid CDB packet across wrapper copies."),
    ("bmc_cdb_2", "Compare the second valid CDB packet across wrapper copies."),
    ("bmc_commit", "Compare the first valid combinational commit packet."),
    ("bmc_commit_2", "Compare the second commit packet and the coherent CMO request."),
    (
        "cover_cmo_request",
        "Reach both wrappers' first coherent CMO request in six frames.",
    ),
    (
        "bmc_operands",
        "Compare bypass and register-file operands in the Block proofs job.",
    ),
    ("continuity", "Bounded pc_reg and slot-1 PC continuity check"),
    ("bmc_64x8", "Line alignment with 64-byte lines and 8 data bytes."),
    ("home_small", "Consumed packets and fill phase flags with two fills."),
    (
        "home_four",
        "Consumed packets and fill phase flags with three fills and four ways.",
    ),
    ("home_default", "Consumed packets and fill phase flags with eight fills."),
    ("array_bram", "Separate selection and row-read captures with one BRAM way."),
    (
        "array_bram_four",
        "Separate selection and row-read captures with four BRAM ways.",
    ),
    ("array_uram", "Folded selection and banked captures with four 64-byte URAM ways."),
    (
        "array_uram32",
        "Folded selection and banked captures with four 32-byte URAM ways.",
    ),
    (
        "array_uram_row",
        "Folded selection and single-array captures with short read latency.",
    ),
    ("array_bram_cover", "Tag hit and row data capture with one BRAM way."),
    ("array_bram_four_cover", "Tag hit and row data capture with four BRAM ways."),
    (
        "array_uram_cover",
        "Hit, row and kept parallel captures with 64-byte URAM lines.",
    ),
    (
        "array_uram32_cover",
        "Hit, row and kept parallel captures with 32-byte URAM lines.",
    ),
    ("array_uram_row_cover", "Tag hit and row data capture in the single-array URAM."),
    ("endpoint32", "Demand and grant captures with 32-bit addresses."),
    ("endpoint56", "Demand and grant captures with 56-bit addresses."),
    ("arbiter_default", "Selected payloads with handshake-only loading."),
    ("arbiter_idle", "Selected payloads with loading on every idle cycle."),
    (
        "completions_two",
        "Selected parking, dispatch and waiter exclusion with two completion slots.",
    ),
    (
        "completions_three",
        "Selected parking, dispatch and waiter exclusion with three completion slots.",
    ),
    (
        "completions_default",
        "Selected parking, dispatch and waiter exclusion with the full completion table.",
    ),
    ("bmc_fills3", "Forward-turn equivalence with three fills."),
    ("bmc_seat2", "Seat next-state equivalence with two fills."),
    ("bmc_seat3", "Seat next-state equivalence with three fills and four ways."),
    ("line_link0_bmc", "Line client and links at zero stages, two identities."),
    (
        "coh_line_client_prove",
        "Ingress under a hart source and class 3 with two identities.",
    ),
    (
        "coh_line_client_eight_prove",
        "Ingress under a hart source and class 3 with eight identities.",
    ),
    (
        "coh_line_client_cover",
        "Ingress reachability under a hart source with two identities.",
    ),
    (
        "coh_line_client_eight_cover",
        "Ingress reachability under a hart source with eight identities.",
    ),
    ("line_link1_bmc", "Line client and links at one stage, two identities."),
    ("line_link1_four_bmc", "Line client and links at one stage, four identities."),
    ("line_link1_eight_bmc", "Line client and links at one stage, eight identities."),
    (
        "line_link1_cover",
        "Line client at one stage reaches two live identities and a write response.",
    ),
    ("bmc_32x32", "Line alignment with 32-byte lines and 32 data bytes."),
    ("cover", "Search for reachable cover scenarios"),
    ("prove", "Prove safety assertions without a depth bound"),
    ("prove_depth2", "Unbounded proof of the two-entry decoded bundle queue"),
    (
        "bmc_no_prepare_busy",
        "Load queue component with busy-port preparation disabled",
    ),
    ("cover_no_prepare_busy", "Load queue reachability without busy-port preparation"),
    (
        "bmc_probe_launch",
        "Load queue with forwarding and cached loads launched during the store-queue probe",
    ),
    (
        "cover_probe_launch",
        "Load queue reachability of each verdict on a read launched during the probe",
    ),
    (
        "bmc_age_order",
        "Load queue registered-age order and oldest-eligible issue selection",
    ),
    ("prove_alignment", "Unbounded mixed-width tracker and physical FU alignment"),
    ("prove_alignment_direct", "Unbounded direct multiply completion alignment"),
    ("prove_direct_fallback", "Unbounded direct full-width fallback control"),
    (
        "prove_alignment_direct_fallback",
        "Unbounded direct full-width fallback alignment",
    ),
    ("prove_fallback", "Unbounded full-width fallback tracker and credits"),
    ("prove_alignment_fallback", "Unbounded full-width fallback FU alignment"),
    (
        "prove_pre_match",
        "Unbounded equivalence of split load-queue pre-issue match registers",
    ),
    (
        "prove_port1_amo",
        "Unbounded exclusivity of load-queue port-1 AMO writes against L0 hits and SQ forwards",
    ),
    (
        "cover_port1_amo",
        "Reachability of load-queue port-1 AMO writes, L0 hits, and post-AMO SQ forwards",
    ),
    (
        "prove_unrestricted",
        "Unbounded observation tracking with only initial reset assumed",
    ),
    ("prove_always_mul", "Unbounded constant-idle MUL adapter equivalence"),
    ("cover_always_mul", "MUL grant, flush and injection reachability"),
    ("prove_always_mem", "Unbounded constant-idle MEM adapter equivalence"),
    ("cover_always_mem", "MEM grant, contention, flush and injection reachability"),
    ("prove_int", "Unbounded shared delivery-bus equivalence at INT capacity"),
    ("prove_mem", "Unbounded shared delivery-bus equivalence at MEM capacity"),
    ("prove_mul", "Unbounded shared delivery-bus equivalence at MUL capacity"),
    ("prove_src3", "Unbounded shared delivery-bus equivalence with three sources"),
    ("cover_int", "INT deferred delivery, slot-2-only dispatch and flush reachability"),
    ("generic32", "Arbitrary-input portable equivalence at 32 bits"),
    ("generic64", "Arbitrary-input portable equivalence at 64 bits"),
    ("xilinx32", "Arbitrary-input LUT5 response-mux equivalence at 32 bits"),
    ("xilinx64", "Arbitrary-input LUT5 response-mux equivalence at 64 bits"),
    # Parameter-shape variants (chparam'd tops): the ITLB shape of the TLB.
    ("bmc_itlb", "Bounded checking of 16-entry 2-port ITLB fetch verdicts"),
    ("cover_itlb", "Cover checking in the 16-entry 2-port ITLB shape"),
    ("walk_select_prove", "Induction proof of the shared walk port's VPN select"),
    (
        "walk_select_cover",
        "Cover a select refusal and the instruction priority after it",
    ),
    ("bmc_nopwc", "Bounded checking of the page-table walker without its walk cache"),
    ("bmc_replace", "Bounded checking through replacement in one-entry walk caches"),
    (
        "bmc_wide",
        "Bounded walker checking with the 64 GiB DDR map and its Svpbmt alias gap",
    ),
    ("cover_wide", "Svpbmt alias and no-alias reachability with the 64 GiB DDR map"),
    ("bmc_xlen32", "Bounded checking with a local 32-bit datapath"),
    ("bmc_ddr31", "Pointer masking with a 2 GiB DDR aperture"),
    ("bmc_ddr36", "Pointer masking with a 64 GiB DDR aperture"),
    ("bmc_ddr37", "Pointer masking with a 128 GiB DDR aperture"),
    (
        "bmc_small_btb",
        "Bounded tag comparison with a 16-entry BTB and partial final group",
    ),
    ("bmc_btb_index1", "Bounded relation checking with one BTB index bit"),
    ("bmc_btb_index3", "Bounded relation checking with three BTB index bits"),
    ("bmc_four_way", "Bounded checking with four ways"),
    ("prove_four_way", "Unbounded safety checking with four ways"),
    ("bmc_unequal", "Bounded check starting from unequal table copies"),
    ("cover_unequal", "Cover scenarios starting from unequal table copies"),
    (
        "size_select",
        "Slot-2 fields per slot-1 size equal the single reduction, any state.",
    ),
    (
        "size_select_four_way",
        "Slot-2 fields per slot-1 size equal the single reduction, four ways.",
    ),
    ("bmc_xlen72", "Bounded Bare-output checking with local XLEN 72"),
    ("bmc_integrated", "Bounded checking with the integrated IF handoff parameter"),
    ("prove_xlen32", "Unbounded safety checking with a local 32-bit datapath"),
    (
        "prove_xlen66",
        "Unbounded replay comparison at XLEN 66, including a one-bit final group",
    ),
    ("prove_xlen72", "Unbounded captured-tag checking with local XLEN 72"),
    (
        "fp_repair_bmc",
        "Bounded model checking with production FP dispatch done repair enabled",
    ),
    (
        "bmc_depth6",
        "Depth-6 bounded model checking of station and wrapper assertions with abstract leaf FUs",
    ),
    (
        "bmc_wakeup_depth6",
        "Depth-6 bounded model checking of early-load wakeup merger assertions with abstract leaf FUs",
    ),
    (
        "fp_repair_bmc_depth6",
        "Depth-6 bounded model checking with FP dispatch done repair enabled and abstract leaf FUs",
    ),
    (
        "cover_depth6",
        "Cover search for frames 4 and 5 in the abstract-FU depth-6 environment",
    ),
    (
        "cover_wakeup_depth6",
        "Cover search for queue overlap, recovery, ALU CDB, and wakeup merge in the narrowed depth-6 wakeup environment",
    ),
    (
        "cover_fu_depth6",
        "Cover search for multi-cycle abstracted MUL and FP engine completions reaching the CDB with FU test ports tied to zero",
    ),
    (
        "cover_alu_issue",
        "Cover search for the ALU-issue scenarios, split from the other covers",
    ),
    # INT reservation-station features at eight-entry component capacity;
    # the wrapper target checks the production sixteen-entry station.
    (
        "bmc_tag_indexed",
        "Bounded checks with indexed CDB tags at eight-entry RS capacity",
    ),
    (
        "cover_tag_indexed",
        "Cover checking of INT station features at eight-entry capacity",
    ),
    ("bmc_perf_off", "Bounded model checking with the profiling counters left out"),
    ("vector_bmc", "Bounded model checking with the vector state present"),
    ("vector_cover", "Cover search with the vector state present"),
    (
        "prove_harts3",
        "Unbounded proof with three harts, 191 interrupt identities, and no APLIC "
        "delivery",
    ),
    (
        "cover_harts3",
        "Cover checking with three harts, 191 interrupt identities, and no APLIC "
        "delivery",
    ),
    ("prove_ids511", "Unbounded proof with 511 interrupt identities"),
    ("bmc_ids2047", "Bounded checking with 2047 interrupt identities"),
    ("bmc_width8", "Bounded checking against a reference model at 8 bits"),
    ("cover_width8", "Cover checking at 8 bits"),
    ("prove_width64", "Unbounded invariant proof at 64 bits"),
    ("bmc_256", "Bounded checking with a 256-entry L0 cache"),
    ("cover_256", "Cover checking with a 256-entry L0 cache"),
    (
        "bmc_trusted",
        "Bounded checking with allocation trusted to dispatch, as the core builds it",
    ),
    (
        "cover_trusted",
        "Cover checking with allocation trusted to dispatch, as the core builds it",
    ),
    (
        "bmc_registered",
        "Bounded checking with the registered output, as the core builds it",
    ),
    (
        "bmc_no_refill",
        "Bounded checking without grant refill, as the FP pipe's adapter",
    ),
    (
        "cover_no_refill",
        "Cover checking without grant refill, as the FP pipe's adapter",
    ),
    (
        "bmc_precomputed",
        "Bounded checking with a precomputed age compare, as the second ALU's adapter",
    ),
    (
        "bmc_always_granted",
        "Bounded checking of an always-granted adapter, as the memory adapter",
    ),
    (
        "cover_registered",
        "Cover checking with the registered output, as the core builds it",
    ),
    (
        "prove_one_hart",
        "Unbounded proof with one source, one hart, and one priority bit",
    ),
    ("prove_wide", "Unbounded proof with 33 sources, two words of each bitmap"),
    ("prove_three_harts", "Unbounded proof with three harts and 8-bit priorities"),
    (
        "home_engine_twin32",
        "Home engine primitive form equals its portable form at 32-byte lines.",
    ),
    (
        "home_engine_twin64",
        "Home engine primitive form equals its portable form at 64-byte lines.",
    ),
    (
        "home_engine_twin40",
        "Home engine primitive form equals its portable form at 40-bit addresses.",
    ),
    (
        "home_twin_small",
        "Coherent home primitive form equals its portable form, one way, two fills.",
    ),
    (
        "home_twin_four",
        "Coherent home primitive form equals its portable form, four ways, three fills.",
    ),
    (
        "home_twin_addr40",
        "Coherent home primitive form equals its portable form at 40-bit addresses.",
    ),
    (
        "l1d_twin_single",
        "L1D primitive form equals its portable form, one miss slot.",
    ),
    (
        "l1d_twin_multi",
        "L1D primitive form equals its portable form, three miss slots.",
    ),
    (
        "l1d_twin_stream",
        "L1D primitive form equals its portable form, eight miss slots with stream prefetching.",
    ),
    (
        "boundary_twin",
        "SQ write capture and the L0 store strobe equal the address-decoded boundary.",
    ),
    (
        "dbq_twin",
        "Decoded bundle queue primitive form equals its portable form with the split shadow stall.",
    ),
    (
        "imem_predecode_live",
        "Fetch data, bank select and live IMEM state agree with the reference.",
    ),
    (
        "dmmu_twin",
        "Data MMU primitive form equals its portable form.",
    ),
    (
        "immu_twin",
        "Instruction MMU primitive form equals its portable form.",
    ),
    (
        "immu_twin_hold",
        "Instruction MMU primitive form equals its portable form with four hold-polarity copies.",
    ),
    (
        "id_kill_equiv_vector",
        "ID post-classifier kill masking equals in-classifier legality and fault overrides "
        "with the vector floating-point decode.",
    ),
    (
        "id_kill_equiv",
        "ID post-classifier kill masking equals in-classifier legality and fault overrides.",
    ),
    (
        "cached_tier_twin",
        "Cached tier adapter primitive form equals its portable form with split read requests.",
    ),
    (
        "cached_tier_unsplit",
        "Cached tier adapter primitive form equals its portable form with one read request input.",
    ),
    (
        "csr_twin",
        "CSR file primitive form equals its portable form.",
    ),
    (
        "csr_twin_vector",
        "CSR file primitive form equals its portable form with vector state enabled.",
    ),
    (
        "fp_engine_twin",
        "FP engine primitive form equals its portable form.",
    ),
    (
        "cft_twin",
        "Control-flow tracker primitive form equals its portable form.",
    ),
    (
        "pdt_twin",
        "Predecode target adder primitive form equals its portable form.",
    ),
    (
        "router_twin",
        "Router MMIO drain gate primitive form equals its portable form.",
    ),
    (
        "bp_twin",
        "Branch predictor primitive form equals its portable form.",
    ),
    (
        "pc_controller_twin",
        "PC controller, increment calculator and control-flow tracker primitive forms equal their portable forms.",
    ),
    (
        "pc_controller_twin_slot2",
        "Same with slot-2 pending handoff excluded.",
    ),
    (
        "sq_twin",
        "Store queue primitive form equals its portable form.",
    ),
    (
        "sq_twin_cpu",
        "Store queue primitive form equals its portable form with the CPU's store-queue settings.",
    ),
    (
        "store_pma_twin_ddr30",
        "Store page decoder primitive form equals its portable form, 1 GiB DDR.",
    ),
    (
        "store_pma_twin_ddr31",
        "Store page decoder primitive form equals its portable form, 2 GiB DDR.",
    ),
    (
        "rs_twin_indexed",
        "Indexed-write reservation station primitive form equals its portable form.",
    ),
    (
        "int_equiv",
        "INT_RS issue-tag copies: every output and next state equal the single-tag station.",
    ),
    (
        "int_equiv_prims",
        "Same with Xilinx primitives in both stations.",
    ),
    (
        "prove_aw",
        "Unbounded AXI4 CDC proof on the write-address channel.",
    ),
    (
        "prove_w",
        "Unbounded AXI4 CDC proof on the write-data channel.",
    ),
    (
        "prove_b",
        "Unbounded AXI4 CDC proof on the write-response channel.",
    ),
    (
        "prove_ar",
        "Unbounded AXI4 CDC proof on the read-address channel.",
    ),
    (
        "prove_r",
        "Unbounded AXI4 CDC proof on the read-data channel.",
    ),
    (
        "prove_margin2",
        "Unbounded dual-clock FIFO proof with almost-full margin 2.",
    ),
    (
        "prove_int_active",
        "Unbounded RAT proof for active integer rename, checkpoint pool and RAS outputs.",
    ),
    (
        "prove_int_ckpt_lo",
        "Unbounded RAT proof for integer snapshot invariants in checkpoints 0 through 3.",
    ),
    (
        "prove_int_ckpt_mid",
        "Unbounded RAT proof for integer snapshot invariants in checkpoints 4 through 7.",
    ),
    (
        "prove_int_ckpt_hi",
        "Unbounded RAT proof for integer snapshot invariants in checkpoints 8 through 11.",
    ),
    (
        "prove_fp_active",
        "Unbounded RAT proof for active floating-point rename state.",
    ),
    (
        "prove_fp_ckpt_lo",
        "Unbounded RAT proof for floating-point snapshot invariants in checkpoints 0 through 3.",
    ),
    (
        "prove_fp_ckpt_mid",
        "Unbounded RAT proof for floating-point snapshot invariants in checkpoints 4 through 7.",
    ),
    (
        "prove_fp_ckpt_hi",
        "Unbounded RAT proof for floating-point snapshot invariants in checkpoints 8 through 11.",
    ),
    (
        "bmc_addr1",
        "Bounded multi-write RAM equivalence with two entries.",
    ),
    (
        "bmc_unstaged",
        "Bounded multi-write RAM equivalence without write staging.",
    ),
    (
        "tree_equiv",
        "Store-queue forwarding balanced winner tree equals the linear formal selector.",
    ),
    (
        "int_prove",
        "Unbounded stage2 and stage2b payload equivalence in the INT station configuration.",
    ),
    (
        "mul_prove",
        "Unbounded stage2 payload equivalence in the MUL station configuration.",
    ),
    (
        "mem_prove",
        "Unbounded stage2 payload equivalence in the MEM station configuration.",
    ),
    (
        "fp_prove",
        "Unbounded stage2 payload equivalence in the FP station configuration.",
    ),
    (
        "int_cover",
        "Stage2 and stage2b stall, flush, back-to-back issue, and reset reachability.",
    ),
]

# Explicit mode assignments for registered task names whose underscore-separated
# words do not carry a single bmc*, prove*, or cover* token.
SBY_TASK_MODE_OVERRIDES: dict[str, str] = {
    "arbiter_default": "prove",
    "arbiter_idle": "prove",
    "array_bram": "prove",
    "array_bram_four": "prove",
    "array_uram": "prove",
    "array_uram32": "prove",
    "array_uram_row": "prove",
    "bp_twin": "bmc",
    "cached_tier_twin": "bmc",
    "cached_tier_unsplit": "bmc",
    "cft_twin": "bmc",
    "completions_default": "prove",
    "completions_three": "prove",
    "completions_two": "prove",
    "continuity": "bmc",
    "csr_twin": "bmc",
    "csr_twin_vector": "bmc",
    "boundary_twin": "bmc",
    "dbq_twin": "bmc",
    "imem_predecode_live": "bmc",
    "dmmu_twin": "bmc",
    "endpoint32": "prove",
    "endpoint56": "prove",
    "fp_engine_twin": "bmc",
    "generic32": "bmc",
    "generic64": "bmc",
    "home_default": "prove",
    "home_engine_twin32": "bmc",
    "home_engine_twin40": "bmc",
    "home_engine_twin64": "bmc",
    "home_four": "prove",
    "home_small": "prove",
    "home_twin_addr40": "bmc",
    "home_twin_four": "bmc",
    "home_twin_small": "bmc",
    "home_wide": "prove",
    "id_kill_equiv": "bmc",
    "id_kill_equiv_vector": "bmc",
    "immu_twin": "bmc",
    "immu_twin_hold": "bmc",
    "int_equiv": "bmc",
    "int_equiv_prims": "bmc",
    "l1d_twin_multi": "bmc",
    "l1d_twin_single": "bmc",
    "l1d_twin_stream": "bmc",
    "layout32": "bmc",
    "layout56": "bmc",
    "lookup_multi_prove": "bmc",
    "lookup_prove": "bmc",
    "lookup_stream_prove": "bmc",
    "off": "prove",
    "on": "prove",
    "p00": "prove",
    "p01": "prove",
    "p10": "prove",
    "p11": "prove",
    "pc_controller_twin": "bmc",
    "pc_controller_twin_slot2": "bmc",
    "pdt_twin": "bmc",
    "request_equiv32": "prove",
    "request_equiv56": "prove",
    "request_equiv_ptw": "prove",
    "request_equiv_slot0": "prove",
    "request_equiv_wide_ptw": "prove",
    "request_equiv_wide_slot0": "prove",
    "router_twin": "bmc",
    "rs_twin_indexed": "bmc",
    "size_select": "bmc",
    "size_select_four_way": "bmc",
    "sq_twin": "bmc",
    "sq_twin_cpu": "bmc",
    "store_pma_twin_ddr30": "bmc",
    "store_pma_twin_ddr31": "bmc",
    "tree_equiv": "prove",
    "x32": "prove",
    "x64": "prove",
    "x66": "prove",
    "xilinx32": "bmc",
    "xilinx64": "bmc",
    "zero_index_invariants": "prove",
}

SKIP_PINNED: dict[tuple[str, str], int] = {
    ("axi_coherent_bridge", "cover_soc"): 60,
    ("coherence_l1d", "coh_l1d_zero_cover"): 48,
    ("coherence_l1d", "coh_l1d_zero_progress_cover"): 128,
    ("coherence_l1d", "coh_l1d_zero_request_cover"): 159,
    ("coherence_l1d", "coh_l1d_withdraw_full_cover"): 48,
    # One reset clock and 512 backing set clears precede the first hit.
    ("predictor_fetch_contract", "cover_backing"): 513,
}

FATAL_START_FRAME_TASKS: frozenset[tuple[str, str]] = frozenset(
    {
        ("coherence_store_boundary", "bmc_amo_same_fatal"),
        ("coherence_store_boundary", "bmc_amo_other_fatal"),
        ("coherence_store_boundary", "bmc_intervening_fatal"),
    }
)

ALLOWED_TARGET_YS_FILES: dict[str, frozenset[str]] = {
    "axi_coherent_bridge": frozenset(
        {"free_undefined.ys", "axi_coherent_bridge_groups.ys"}
    ),
}


def _inferred_task_mode(task_name: str) -> str | None:
    """Infer mode when task_name contains one unambiguous bmc/prove/cover word."""
    parts = task_name.split("_")
    matches = [
        mode
        for mode in ("bmc", "prove", "cover")
        if any(part.startswith(mode) for part in parts)
    ]
    return matches[0] if len(matches) == 1 else None


def registered_task_mode(task_name: str) -> str:
    """Return the required SymbiYosys mode for a registered task name."""
    if task_name in SBY_TASK_MODE_OVERRIDES:
        return SBY_TASK_MODE_OVERRIDES[task_name]
    inferred = _inferred_task_mode(task_name)
    if inferred is None:
        raise ValueError(f"Task {task_name!r} has no unambiguous registered mode")
    return inferred


def registered_task_config_gaps(
    target_name: str,
    task_name: str,
    cfg: sby_config.TaskConfig,
    formal_dir: Path,
) -> list[str]:
    """Validate options, engines, task mode, pins, and helper files for one task."""
    gaps: list[str] = []
    try:
        cfg.validate()
        cfg.parsed(formal_dir, expand_opening=True)
    except sby_config.ConfigError as error:
        gaps.append(str(error))
        return gaps

    try:
        expected_mode = registered_task_mode(task_name)
    except ValueError as error:
        gaps.append(str(error))
    else:
        actual_mode = cfg.options.get("mode")
        if actual_mode != expected_mode:
            gaps.append(
                f"[options] mode {actual_mode!r} does not match registered mode {expected_mode!r}"
            )

    key = (target_name, task_name)
    if "skip" in cfg.options:
        actual_skip = int(cfg.options["skip"])
        if SKIP_PINNED.get(key) != actual_skip:
            gaps.append(
                f"[options] skip {actual_skip} is not pinned in SKIP_PINNED for {target_name}:{task_name}"
            )
    elif key in SKIP_PINNED:
        gaps.append(
            f"SKIP_PINNED entry {SKIP_PINNED[key]} missing from {target_name}:{task_name}"
        )

    uses_start_frame = tuple(cfg.engines[0]) == ("abc", "bmc3", "-c", "-S", "139")
    if uses_start_frame != (key in FATAL_START_FRAME_TASKS):
        gaps.append(f"start-frame engine pin mismatch on {target_name}:{task_name}")

    if cfg.inline_files:
        gaps.append(
            f"inline [file ...] not allowed in registered target: {sorted(cfg.inline_files)}"
        )
    allowed_ys = ALLOWED_TARGET_YS_FILES.get(
        target_name, frozenset({"free_undefined.ys"})
    )
    extra_ys = sorted(
        dest for dest in cfg.files if dest.endswith(".ys") and dest not in allowed_ys
    )
    if extra_ys:
        gaps.append(f"unpinned .ys helper in [files]: {extra_ys}")
    return gaps


def test_predictor_twins_use_the_core_connections() -> None:
    """Check the register boundary and external fold wiring used by the twins."""
    root = Path(__file__).resolve().parents[1]
    cpu = root / "hw/rtl/cpu_and_mem/cpu"

    def source(path: Path) -> str:
        return re.sub(r"//[^\n]*|/\*.*?\*/", "", path.read_text(), flags=re.S)

    def body(text: str, instance: str) -> str:
        match = re.search(rf"\b{instance}\s*\((.*?)\);", text, re.S)
        assert match, instance
        return re.sub(r"\s+", "", match[1])

    def pin(body_text: str, name: str) -> str:
        match = re.search(rf"\.{name}\(([^()]*)\)", body_text)
        assert match, name
        return match[1]

    def expr(text: str, name: str) -> str:
        match = re.search(rf"\b{re.escape(name)}\s*=\s*([^;]+);", text)
        assert match, name
        return re.sub(r"\s+", "", match[1])

    core = source(cpu / "cpu_ooo/cpu_ooo.sv")
    fetch = source(cpu / "if_stage/if_stage.sv")
    twin = source(root / "formal/pd_history_twin_side.sv")
    core_pd, core_hist = body(core, "pd_stage_inst"), body(core, "u_tage_history")
    twin_pd, twin_hist = body(twin, "pd"), body(twin, "history")
    for field in ("cond_branch", "jalr", "itt_eligible", "cf", "pred_taken"):
        for pd, history in ((core_pd, core_hist), (twin_pd, twin_hist)):
            assert pin(pd, "o_q_" + field) == pin(history, "i_pd_q_" + field), field

    core_if = body(core, "if_stage_inst")
    table = body(fetch, "u_tage_predictor")
    for output, input_name in (
        ("o_lookup_dir_fold", "i_tage_hist_fold"),
        ("o_lookup_dir_hist", "i_tage_hist"),
        ("o_lookup_hist", "i_itt_hist"),
    ):
        assert pin(core_hist, output) == pin(core_if, input_name)
    assert pin(table, "i_lookup_fold_index") == "i_tage_hist_fold"
    assert pin(table, "i_lookup_hist") == "i_tage_hist"
    for text, module, instance, parameter, value in (
        (core, "if_stage", "if_stage_inst", "USE_EXTERNAL_TAGE_FOLD", "1'b1"),
        (
            fetch,
            "tage_predictor",
            "u_tage_predictor",
            "USE_EXTERNAL_FOLD_INDEX",
            "USE_EXTERNAL_TAGE_FOLD",
        ),
    ):
        parameters = re.search(
            rf"\b{module}\s*#\s*\((.*?)\)\s*{instance}\b", text, re.S
        )
        assert parameters, module
        assert pin(re.sub(r"\s+", "", parameters[1]), parameter) == value

    assert pin(core_pd, "o_pd_redirect_taken") == pin(core_hist, "i_pd_redirect_taken")
    assert pin(twin_pd, "o_pd_redirect_taken") == pin(twin_hist, "i_pd_redirect_taken")
    assert expr(twin, "accept").replace("i.", "").replace("o.", "") == expr(
        core, pin(core_hist, "i_pd_accept")
    )
    for bus, name in (("i_tage_slot_bank", "bank"), ("i_base_taken", "base_taken")):
        core_name = pin(core_hist, bus)
        assert pin(twin_hist, bus) == name
        expected = "{" + ",".join(expr(core, f"{core_name}[{s}]") for s in (1, 0)) + "}"
        assert expr(twin, name).replace("i.", "") == expected


def test_fetch_contract_selects_its_mutation_cases() -> None:
    """Editing the shared monitor selects the IF case and both PD cases."""
    from formal_selection import FIXTURE_PROOFS, ROOT, affected_nodes

    prefix = "tests/test_predictor_mutations.py::test_predictor_rejects_difference"
    nodes = [node for node in FIXTURE_PROOFS if node.startswith(prefix)]
    selected = affected_nodes(nodes, {ROOT / "formal/predictor_fetch_contract.sv"})
    assert set(selected) == {
        f"{prefix}[fetch_slot2_branch]",
        f"{prefix}[direction_history]",
        f"{prefix}[pd_indirect_class]",
    }
    unknown = f"{prefix}[unmapped]"
    with pytest.raises(ValueError, match="No proof mapping"):
        affected_nodes([unknown], {ROOT / "tests/test_predictor_mutations.py"})


def test_predictor_reference_sources_are_frozen() -> None:
    """The reference side is the exact source tree before the predictor register changes."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR / "predictor_reference"
    blobs = {
        "backing_btb.original.sv": "921c71bb493a2d40eb0fef1d4b01e84f528e365b",
        "ittage_predictor.original.sv": "734034d46cb89c457287816e80fa522351afa982",
        "pd_redirect_next.original.sv": "fc147c9b68002a4e9b24eac60c911f44665f72f0",
        "pd_stage.original.sv": "951b0b09da7021e2f90bee2849c3aaa033560827",
        "pd_target_high_precompute.original.sv": "2867ccea13165eaed9f78cc11289af9d1b00cf63",
        "riscv_pkg.original.sv": "c57a8b22aecde88af5c7038440854363b50f766a",
        "rvc_decompressor.original.sv": "b0cd92a276ccc22482b921ec07ff60483bf7d9a6",
        "tage_history.original.sv": "1af737016740dd859e164fe8351d19902b92717d",
        "tage_predictor.original.sv": "4a14696c3a70f50a4946fd2bfb7d182140cc66c2",
    }
    for filename, expected in blobs.items():
        source = (formal / filename).read_bytes()
        git_object = f"blob {len(source)}\0".encode() + source
        assert (
            hashlib.sha1(git_object, usedforsecurity=False).hexdigest() == expected
        ), filename


@pytest.mark.parametrize(
    ("form", "original", "replacement"),
    [
        ("gold", "select -assert-none a:init t:$initstate t:$anyinit\n", ""),
        ("gate", "select -assert-none a:init t:$initstate t:$anyinit\n", ""),
        (
            "gate",
            "t:$dff i:i_clk %co1:+$dff[CLK] %d",
            "t:$dff i:i_rst_n %co1:+$dff[CLK] %d",
        ),
        (
            "gold",
            "select -assert-none a:init t:$initstate t:$anyinit t:$anyconst",
            "select -assert-none t:$anyconst",
        ),
        (
            "gate",
            "select -assert-none a:init t:$initstate t:$anyinit t:$anyconst",
            "select -assert-none t:$anyconst",
        ),
        ("point proof", "select -assert-min 6 @blk", "select -assert-min 1 @blk"),
        ("point proof", "equiv_status -assert\n", "equiv_status -assert @blk\n"),
    ],
)
def test_l0_store_boundary_requires_each_form(
    tmp_path: Path, form: str, original: str, replacement: str
) -> None:
    """A changed source cut, initial state, clock or point proof fails before the solver."""
    runner = FormalRunner()
    target = next(t for t in FORMAL_TARGETS if t.name == l0_store_boundary.PAIR[0])
    source = runner.formal_dir / target.sby_file
    task = l0_store_boundary.PAIR[1]
    l0_store_boundary.check_script(sby_config.source(source).task(task), source.parent)
    staged = sby_config.stage_proof(source, runner.root_dir, tmp_path)
    runner.formal_dir = staged.parent
    arms = staged.read_text().split("design -stash gold\n")
    index = 0 if form == "gold" else 1
    assert original in arms[index]
    arms[index] = arms[index].replace(original, replacement, 1)
    staged.write_text("design -stash gold\n".join(arms))
    with pytest.raises(sby_config.ConfigError, match=f"store boundary {form}:"):
        runner.run_formal(target, task)


def test_store_completion_cofactor_production_inputs(tmp_path: Path) -> None:
    """Bind the proof's file map and staged bytes to the checkout sources."""
    root = Path(__file__).resolve().parents[1]
    formal = root / FORMAL_DIR
    cpu_rtl = root / "hw/rtl/cpu_and_mem/cpu"
    proof = formal / "store_completion_cofactor.sby"
    expected = {
        "riscv_pkg.sv": cpu_rtl / "riscv_pkg.sv",
        "dtlb.sv": cpu_rtl / "mmu/dtlb.sv",
        "dmmu.sv": cpu_rtl / "mmu/dmmu.sv",
        "tomasulo_wrapper.sv": (
            cpu_rtl / "tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv"
        ),
        "store_completion_cofactor_cover.sv": formal
        / "store_completion_cofactor_cover.sv",
        "free_undefined.ys": formal / "free_undefined.ys",
    }
    source = sby_config.source(proof)
    for task in source.tasks:
        resolved = {
            name: (formal / path).resolve(strict=True)
            for name, path in source.task(task).files.items()
        }
        assert resolved == expected, task

        setup = tmp_path / task
        result = subprocess.run(
            ["sby", "--setup", "-d", str(setup), proof.name, task],
            cwd=formal,
            capture_output=True,
            text=True,
            timeout=20,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        staged = setup / "src"
        assert {path.name for path in staged.iterdir()} == expected.keys(), task
        for name, path in expected.items():
            assert (staged / name).read_bytes() == path.read_bytes(), (task, name)


def test_fp_engine_op_formal_matches_wrapper_params() -> None:
    """The engine-op harness uses the wrapper's FP_RS and fp_shim settings and selects mutations."""
    from formal_selection import FIXTURE_PROOFS, ROOT, affected_nodes

    wrapper = (
        ROOT / "hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv"
    ).read_text(encoding="utf-8")
    harness = (ROOT / "formal/fp_engine_op_formal.sv").read_text(encoding="utf-8")

    def params_of(text: str, module: str, inst: str) -> dict[str, str]:
        match = re.search(rf"\b{module}\s*#\s*\((.*?)\)\s*{inst}\b", text, re.S)
        assert match, (module, inst)
        body = re.sub(r"//.*", "", match[1])
        return dict(re.findall(r"\.(\w+)\s*\(\s*([^)]+?)\s*\)", body))

    wrap_rs = params_of(wrapper, "reservation_station", "u_fp_rs")
    harm_rs = params_of(harness, "reservation_station", "u_fp_rs")
    for key in ("DIVIDE_ISSUE_GATE", "FP_ENGINE_GATE", "FWD_WAKE", "HAS_SRC3"):
        assert wrap_rs[key] == harm_rs[key] == "1'b1", (key, wrap_rs, harm_rs)
    wrap_shim = params_of(wrapper, "fp_shim", "u_fp_shim")
    harm_shim = params_of(harness, "fp_shim", "u_fp_shim")
    for key in ("LAUNCH_SQUASH", "PIPELINE"):
        assert wrap_shim[key] == harm_shim[key] == "1'b1", (key, wrap_shim, harm_shim)

    prefix = (
        "tests/test_fp_forward_wake_mutations.py::test_fp_forward_wake_rejects_fault"
    )
    nodes = [node for node in FIXTURE_PROOFS if node.startswith(prefix)]
    assert set(affected_nodes(nodes, {ROOT / "formal/fp_engine_op_formal.sv"})) == {
        f"{prefix}[engine_op_rs_mismatch]",
        f"{prefix}[engine_op_shim_mismatch]",
    }
    assert set(
        affected_nodes(nodes, {ROOT / "tests/test_fp_forward_wake_mutations.py"})
    ) == set(nodes)


def test_formal_target_tasks_are_registered() -> None:
    """Every SBY file and task must participate in CLI and pytest execution."""
    formal_dir = Path(__file__).resolve().parents[1] / FORMAL_DIR
    files = [target.sby_file for target in FORMAL_TARGETS]
    assert len(files) == len(set(files)), "Duplicate formal target registration"
    assert set(files) == {path.name for path in formal_dir.glob("*.sby")}
    for target in FORMAL_TARGETS:
        declared = list(sby_config.source(formal_dir / target.sby_file).tasks)
        assert len(target.tasks) == len(set(target.tasks)), target.name
        assert set(declared) == set(target.tasks), (
            target.name,
            sorted(set(declared) - set(target.tasks)),
            sorted(set(target.tasks) - set(declared)),
        )
    registered = {name for name, _ in SBY_TASKS}
    missing = {
        target.name: sorted(set(target.tasks) - registered)
        for target in FORMAL_TARGETS
        if set(target.tasks) - registered
    }
    assert not missing, f"Formal tasks would be silently skipped: {missing}"
    stale_overrides = sorted(set(SBY_TASK_MODE_OVERRIDES) - registered)
    assert not stale_overrides, stale_overrides
    redundant_overrides = [
        name
        for name, mode in sorted(SBY_TASK_MODE_OVERRIDES.items())
        if _inferred_task_mode(name) == mode
    ]
    assert not redundant_overrides, redundant_overrides
    for name in sorted(registered):
        assert registered_task_mode(name) in ("bmc", "prove", "cover")

    all_pairs = {
        (target.name, task_name)
        for target in FORMAL_TARGETS
        for task_name in target.tasks
    }
    assert set(SKIP_PINNED) <= all_pairs
    assert set(FATAL_START_FRAME_TASKS) <= all_pairs

    seen_options: set[str] = set()
    seen_engines: set[tuple[str, ...]] = set()
    config_gaps: list[str] = []
    for target in FORMAL_TARGETS:
        src = sby_config.source(formal_dir / target.sby_file)
        for task_name in target.tasks:
            cfg = src.task(task_name)
            seen_options.update(cfg.options)
            for eng in cfg.engines:
                seen_engines.add(tuple(eng))
            for gap in registered_task_config_gaps(
                target.name, task_name, cfg, formal_dir
            ):
                config_gaps.append(f"{target.name}:{task_name}: {gap}")
    assert not config_gaps, config_gaps
    assert seen_options == set(sby_config.OPTION_SPECS)
    assert seen_engines == set(sby_config.ENGINE_FORMS)


def test_formal_cli_rejects_empty_selection(monkeypatch: pytest.MonkeyPatch) -> None:
    """A valid global task that a target does not declare cannot pass zero jobs."""
    monkeypatch.setattr(
        sys, "argv", ["test_run_formal.py", "--target", "csr_sscofpmf", "--task", "bmc"]
    )

    def unexpected_tool(*args: Any, **kwargs: Any) -> None:
        pytest.fail("An empty selection must fail before invoking a tool")

    monkeypatch.setattr(subprocess, "run", unexpected_tool)
    with pytest.raises(SystemExit) as error:
        main()
    assert error.value.code == 2


def formal_task_timeout_s(target: str, task: str) -> int:
    """Return the wall-clock backstop for a target's task."""
    return SBY_TASK_TIMEOUT_OVERRIDES_S.get((target, task), SBY_TASK_TIMEOUT_S)


# Measured CI setup budget (checkout, image download and docker load, collection).
FORMAL_SHARD_SETUP_S = 600


def _sby_task_timeouts_s(sby_path: Path) -> dict[str, int]:
    """Return explicit ``timeout`` options (seconds) by task for an SBY file."""
    source = sby_config.source(sby_path)
    return {
        name: int(value)
        for name in source.tasks
        if (value := source.task(name).options.get("timeout")) is not None
    }


def check_formal_shard_budgets(
    shard_timeouts_s: dict[str, int],
    selected_limits_s: dict[str, list[int]],
    allowance_shards: set[str],
    setup_s: int = FORMAL_SHARD_SETUP_S,
) -> None:
    """Check per-shard task limit sums and multi-hour task isolation."""
    for shard_name, limits_s in selected_limits_s.items():
        budget_s = shard_timeouts_s[shard_name]
        for limit_s in limits_s:
            assert limit_s + setup_s <= budget_s, (shard_name, limit_s, budget_s)
            if limit_s > 7200:
                assert shard_name in allowance_shards, (shard_name, limit_s)
        if shard_name in allowance_shards:
            assert sum(limits_s) + setup_s <= budget_s, (
                shard_name,
                sum(limits_s),
                setup_s,
                budget_s,
            )


def test_atomic_proof_pairs_and_formal_shards() -> None:
    """Require proof dependencies and one CI shard for every formal case."""
    import yaml  # type: ignore[import-untyped]
    from _pytest.mark.expression import Expression

    root = Path(__file__).resolve().parents[1]
    registered = [name for name, _ in SBY_TASKS]
    required = {
        "predictor_fetch_contract": ["prove_buffer_source", "prove_slot1_sources"],
        "tomasulo_wrapper_commit_bus": ["bmc", "cover"],
        "rs_mem_broadcast": ["prove", "prove_prims", "cover"],
        "axi_coherent_bridge": [
            "prove_soc",
            "prove_soc_held",
            *(f"prove_soc8_{index}" for index in range(9)),
        ],
        "rat_checkpoint_restore": [
            "prove_int_active",
            "prove_int_ckpt_lo",
            "prove_int_ckpt_mid",
            "prove_int_ckpt_hi",
            "prove_fp_active",
            "prove_fp_ckpt_lo",
            "prove_fp_ckpt_mid",
            "prove_fp_ckpt_hi",
        ],
        "coherent_hart_cache": [
            "coh_hart_maint_owned_prove",
            "coh_hart_maint_prove",
            "coh_hart_maint_free_owned_prove",
            "coh_hart_maint_free_prove",
        ],
        "coherence_store_boundary": [
            "bmc_four_control",
            "bmc_four_value_0",
            "bmc_four_value_1",
            "bmc_four_value_2",
            "bmc_four_value_3",
            "bmc_intervening_same_flow",
            "bmc_intervening_other_flow",
            "bmc_intervening_same_value",
            "bmc_intervening_other_value",
            "bmc_intervening_fatal",
            "prove_intervening_fatal_sticky",
        ]
        + [
            f"{prefix}_amo_{sector}_{suffix}"
            for sector in ("same", "other")
            for prefix, suffix in (("bmc", "fatal"), ("prove", "fatal_sticky"))
        ],
        "coherence_sc_wa": [
            f"sc_wa_s{stages}_{kind}"
            for kind in ("prove", "cover")
            for stages in (0, 1, 2, 3)
        ],
        "coherence_l1d": [
            f"coh_l1d_local{geometry}{part}_prove"
            for geometry in ("", "_multi", "_ways")
            for part in ("", "_sector", "_owned")
        ]
        + [
            "coh_l1d_stream_owned_prove",
            "coh_l1d_stream_snapshot_prove",
            "coh_l1d_stream_prove",
            "coh_l1d_stream_outlier_prove",
            "coh_l1d_snapshot_cover",
            "coh_l1d_stream_free_bmc",
            "coh_l1d_stream_bmc",
            "coh_l1d_stream_hold_bmc",
            "coh_l1d_stream_free_nostore_bmc",
            "coh_l1d_stream_free_nostore_hold_bmc",
            "coh_l1d_local_data_bmc",
            "coh_l1d_local_hold_bmc",
            "coh_l1d_local_control_bmc",
        ],
    }
    for target_name, names in required.items():
        target = next(t for t in FORMAL_TARGETS if t.name == target_name)
        sby_tasks = list(sby_config.source(root / "formal" / target.sby_file).tasks)
        for name in names:
            assert registered.count(name) == 1, name
            assert target.tasks.count(name) == 1, name
            assert sby_tasks.count(name) == 1, name

    workflow = yaml.safe_load((root / ".github/workflows/ci.yml").read_text())
    shards = workflow["jobs"]["test-formal"]["strategy"]["matrix"]["include"]
    filters = {
        shard["shard"]: Expression.compile(shard["pytest_filter"]) for shard in shards
    }
    dedicated_shards = {
        "rob_retire_successor_bmc": "ROB retirement successor",
        "rob_retire_successor_cover": "ROB retirement successor",
        "coherent_hart_cache_coh_hart_maint_prove": "Hart maintenance",
        "coherent_hart_cache_coh_hart_maint_owned_prove": "Hart maintenance",
        "coherent_hart_cache_coh_hart_maint_free_owned_prove": "Hart snapshot ownership",
        "coherent_hart_cache_coh_hart_maint_free_prove": "Hart snapshot ownership",
        "coherence_l1d_coh_l1d_stream_bmc": "Hart maintenance",
        "coherence_l1d_coh_l1d_stream_free_nostore_bmc": "Hart maintenance",
        "coherence_l1d_coh_l1d_stream_outlier_prove": "Hart maintenance",
        "coherence_l1d_coh_l1d_stream_free_bmc": "Coherence L1D free stream",
        "coherence_l1d_coh_l1d_stream_hold_bmc": "Coherence L1D scripted holds",
        "coherence_l1d_coh_l1d_stream_free_nostore_hold_bmc": "Coherence L1D no-store holds",
        "coherence_l1d_coh_l1d_bmc": "Coherence L1D control",
        "coherence_l1d_coh_l1d_multi_bmc": "Coherence L1D multi-endpoint",
        "coherence_l1d_coh_l1d_zero_bmc": "Coherence L1D zero control",
        "coherence_l1d_coh_l1d_zero_multi_bmc": "Coherence L1D zero multi-endpoint",
        "coherence_l1d_coh_l1d_zero_cover": "Coherence L1D zero cover",
        "coherence_l1d_coh_l1d_zero_stream_upper_ep0_bmc": (
            "Coherence L1D zero stream, hinted endpoints 0 and 2"
        ),
        "coherence_l1d_coh_l1d_zero_stream_upper_ep2_bmc": (
            "Coherence L1D zero stream, hinted endpoints 0 and 2"
        ),
        "coherence_l1d_coh_l1d_zero_stream_upper_ep1_read_bmc": (
            "Coherence L1D zero stream, hinted endpoint 1"
        ),
        "coherence_l1d_coh_l1d_zero_stream_upper_ep1_store_bmc": (
            "Coherence L1D zero stream, hinted endpoint 1"
        ),
        "coherence_l1d_coh_l1d_zero_stream_upper_ep1_lookahead_bmc": (
            "Coherence L1D zero stream, hinted endpoint 1"
        ),
        "coherence_l1d_coh_l1d_zero_stream_upper_ep1_prefetch_bmc": (
            "Coherence L1D zero stream, hinted endpoint 1"
        ),
        "coherence_l1d_coh_l1d_zero_stream_upper_ep1_rest_bmc": (
            "Coherence L1D zero stream, hinted endpoint 1"
        ),
        "coherence_l1d_coh_l1d_full_bmc": "Coherence L1D full control",
        "coherence_l1d_coh_l1d_full_multi_bmc": "Coherence L1D full multi-endpoint",
        "coherence_l1d_coh_l1d_full_payload_bmc": "Coherence L1D full payload",
        "coherence_l1d_coh_l1d_withdraw_full_bmc": (
            "Coherence L1D withdrawn puts, full-line control"
        ),
        "coherence_l1d_coh_l1d_withdraw_zero_bmc": (
            "Coherence L1D withdrawn puts, zero-line control"
        ),
        "coherence_l1d_coh_l1d_local_data_bmc": "Coherence L1D local data",
        "coherence_l1d_coh_l1d_local_hold_bmc": "Coherence L1D local holds",
        "coherence_l1d_coh_l1d_local_control_bmc": "Coherence L1D local control",
        "coherence_store_boundary_bmc_four_control": "Store boundary four control",
        "coherence_store_boundary_bmc_four_value_3": "Store boundary four control",
        "coherence_store_boundary_bmc_four_value_0": "Store boundary four value 0",
        "coherence_store_boundary_bmc_four_value_1": "Store boundary four value 1",
        "coherence_store_boundary_bmc_four_value_2": "Store boundary four value 2",
        "coherence_store_boundary_bmc_intervening_same_flow": (
            "Store boundary intervening same flow"
        ),
        "coherence_store_boundary_bmc_intervening_fatal": (
            "Store boundary intervening same flow"
        ),
        "coherence_store_boundary_prove_intervening_fatal_sticky": (
            "Store boundary intervening same flow"
        ),
        "coherence_store_boundary_bmc_intervening_other_flow": (
            "Store boundary intervening other flow"
        ),
        "coherence_store_boundary_bmc_intervening_same_value": (
            "Store boundary intervening same value"
        ),
        "coherence_store_boundary_bmc_intervening_other_value": (
            "Store boundary intervening other value"
        ),
        "coherence_store_boundary_bmc_amo_same": "Store boundary AMO same",
        "coherence_store_boundary_bmc_amo_other": "Store boundary AMO other",
        "coherence_store_boundary_bmc_sc": "Store boundary",
    }
    # Shards sized directly from their tasks' allowances plus CI setup; the
    # remaining catch-all shards group short partitions under hang backstops
    # and may not hold any multi-hour (> 120 minute) task.
    allowance_shards = (set(dedicated_shards.values()) - {"Store boundary"}) | {
        "Load queue",
        "Coherence store lookup banks",
        "Coherence home fast",
        "Coherence links pressure",
        "Coherence L1D data single-endpoint",
        "Coherence L1D data multi-endpoint",
        "Coherence L1D data stores and ways",
        "Coherence L1D zero payload and stream",
        "Coherence L1D zero schedules",
        "Coherence L1D full-line covers",
        "Coherence L1D full-line holds",
        "Coherence L1D withdrawn puts, payloads",
        "Store boundary AMO fatal",
        "Store boundary AMO checks",
        "Store boundary probe launch other",
        "Store boundary probe launch same",
        "Reorder buffer",
    }
    data_prefixes = (
        "coh_l1d_data",
        "coh_l1d_multi_data",
        "coh_l1d_store_",
        "coh_l1d_ways_data",
    )
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "tests/test_run_formal.py",
            "tests/test_pa_bridge_mutation.py",
            "tests/test_predictor_mutations.py",
            "tests/test_fp_forward_wake_mutations.py",
            "tests/test_probe_launch_mutations.py",
            "tests/test_lq_port1_amo_mutations.py",
            "--collect-only",
            "-q",
            "-m",
            "formal",
            "-p",
            "no:cacheprovider",
        ],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
        timeout=120,
    )
    nodes = [
        line.strip()
        for line in result.stdout.splitlines()
        if line.startswith("tests/") and "::" in line
    ]
    assert nodes
    for target_name, names in required.items():
        for name in names:
            assert sum(f"[{target_name}_{name}]" in node for node in nodes) == 1
    sby_timeouts = {
        target.name: _sby_task_timeouts_s(root / "formal" / target.sby_file)
        for target in FORMAL_TARGETS
    }
    target_by_id = {
        f"{target.name}_{task}": (target.name, task)
        for target in FORMAL_TARGETS
        for task in target.tasks
    }
    shard_timeouts_s = {
        shard["shard"]: shard["timeout_minutes"] * 60 for shard in shards
    }
    retire_limits = sby_timeouts["rob_retire_successor"]
    assert retire_limits == {"bmc": 3600, "cover": 300}
    assert formal_task_timeout_s("rob_retire_successor", "bmc") == retire_limits["bmc"]
    assert shard_timeouts_s["ROB retirement successor"] == 10 * 60 + sum(
        retire_limits.values()
    )
    selected_by_shard: dict[str, list[str]] = {name: [] for name in filters}
    selected_limits_s: dict[str, list[int]] = {name: [] for name in filters}
    for node in nodes:

        def matches_keyword(keyword: str, /, **kwargs: str | int | bool | None) -> bool:
            """Match a keyword against the collected test's node ID."""
            assert not kwargs
            return keyword.casefold() in node.casefold()

        matches = [
            name
            for name, expression in filters.items()
            if expression.evaluate(matches_keyword)
        ]
        assert len(matches) == 1, (node, matches)
        shard_name = matches[0]
        if node.startswith("tests/test_predictor_mutations.py::"):
            assert shard_name == "Frontend and predictor", node
        if node.startswith("tests/test_fp_forward_wake_mutations.py::"):
            assert shard_name == "Floating-point and vector memory", node
        if node.startswith("tests/test_lq_port1_amo_mutations.py::"):
            assert shard_name == "Load queue", node
        selected_by_shard[shard_name].append(node)
        if node.startswith("tests/test_run_formal.py::") and "[" in node:
            test_id = node.split("[", 1)[1].rstrip("]")
            if test_id in target_by_id:
                tgt, tsk = target_by_id[test_id]
                limit_s = sby_timeouts[tgt].get(tsk)
                if limit_s is None and shard_name in allowance_shards:
                    limit_s = formal_task_timeout_s(tgt, tsk)
                if limit_s is not None:
                    selected_limits_s[shard_name].append(limit_s)
        for test_id, shard in dedicated_shards.items():
            if node.endswith(f"[{test_id}]"):
                assert matches == [shard], (node, matches)
        if any(f"[coherence_l1d_{prefix}" in node for prefix in data_prefixes):
            assert shard_name.startswith("Coherence L1D data"), (node, matches)
    assert len(selected_by_shard["Coherence L1D zero control"]) == 1
    assert len(selected_by_shard["Coherence L1D zero cover"]) == 1
    assert len(selected_by_shard["Coherence L1D local holds"]) == 1
    for task in ("prove", "cover"):
        assert any(
            node.endswith(f"[nic_tx_hold_{task}]")
            for node in selected_by_shard["Other tasks"]
        )
    split_shard_limits_minutes = {
        "Frontend and predictor": 150,
        "Block proofs": 150,
        "Floating-point and vector memory": 140,
        "Other tasks": 124,
    }
    for shard_name, minutes in split_shard_limits_minutes.items():
        assert shard_timeouts_s[shard_name] == minutes * 60, (
            shard_name,
            shard_timeouts_s.get(shard_name),
        )
    for test_id, expected_shard in (
        ("backing_btb_bmc_four_way", "Frontend and predictor"),
        ("prediction_handoff_bmc", "Frontend and predictor"),
        ("predictor_fetch_contract_cover_backing", "Frontend and predictor"),
        ("cache_flash_valid_bmc_fast", "Block proofs"),
        ("rs_payload_twin_bmc_operands", "Block proofs"),
        ("fp_forward_wake_bmc", "Floating-point and vector memory"),
        ("vec_head_mmu_stride_bmc", "Floating-point and vector memory"),
        ("vec_hold_rows_vhold_sq_bmc", "Floating-point and vector memory"),
        ("store_queue_bmc", "Other tasks"),
    ):
        assert any(
            node.endswith(f"[{test_id}]") for node in selected_by_shard[expected_shard]
        ), (test_id, expected_shard)
    assert all(selected_by_shard.values()), {
        name for name, items in selected_by_shard.items() if not items
    }
    check_formal_shard_budgets(shard_timeouts_s, selected_limits_s, allowance_shards)


def test_runner_limits_cover_sby_limits() -> None:
    """Give every task at least its SBY limit, so the runner never stops a task SBY still allows."""
    root = Path(__file__).resolve().parents[1]
    for target in FORMAL_TARGETS:
        limits = _sby_task_timeouts_s(root / "formal" / target.sby_file)
        for task in target.tasks:
            sby_limit = limits.get(task, limits.get(""))
            if sby_limit is not None:
                assert sby_limit <= formal_task_timeout_s(target.name, task), (
                    target.name,
                    task,
                    sby_limit,
                )


def test_formal_shard_budget_sum_rejects_overcommitted_shard() -> None:
    """Reject a shard whose summed task allowances plus setup exceed its limit."""
    check_formal_shard_budgets(
        {"Dedicated": 260 * 60, "Shared": 330 * 60},
        {"Dedicated": [240 * 60], "Shared": [20 * 60, 40 * 60]},
        {"Dedicated"},
    )
    with pytest.raises(AssertionError):
        check_formal_shard_budgets(
            {"Dedicated": 330 * 60},
            {"Dedicated": [120 * 60, 240 * 60]},
            {"Dedicated"},
        )
    with pytest.raises(AssertionError):
        check_formal_shard_budgets(
            {"Shared": 330 * 60},
            {"Shared": [240 * 60]},
            set(),
        )


def formal_task_config(target: str, task: str) -> dict[str, list[str]]:
    """Return an SBY task's resolved sections, with parsed script commands."""
    path = Path(__file__).resolve().parents[1] / FORMAL_DIR / f"{target}.sby"
    return sby_config.resolved(path)[task].sections(path.parent)


# SymbiYosys gives a register without an initial value its free starting value
# only after a task's whole script, in its preparation step (formalff -setundef
# -clk2ff -ff2anyinit), and there also turns undefined constants and undriven
# nets into free inputs (setundef -undriven -anyseq). Until then a pass that
# treats an undefined value as a don't-care can change the model: opt_dff can
# fix such a register to the constant it loads, or turn one that never loads
# into a constant x that each reader resolves on its own; opt_merge can fuse two
# such registers that share an input; opt_expr and wreduce can resolve an
# undefined bit differently at each reader; memory_map and the memory passes
# can turn the words of a memory that is never written into constants; abc
# reads an undefined bit as 0; and -share_all lets opt_merge fuse free inputs.
# The proof can then miss behaviors of the hardware or combine values that it
# cannot produce.
#
# Every command line of every task's script and included .ys file must parse
# completely into a form in sby_config.SCRIPT_FORMS. DONT_CARE_SAFE and
# DONT_CARE_REJECTED are direct projections of that closed form table: apart
# from the edits a script names itself (connect, delete, chformal and the
# like), the safe forms keep the unknown starting value of registers and
# memories and never merge two free inputs, and the rejected forms require an
# explicit per-task pin in DONT_CARE_OPEN.
#
# No list of forms keeps undefined constants: these passes, which safe forms
# run, fuse or fix them before SymbiYosys frees them.
#   opt_muxtree (opt without -fast, prep): a constant-x select reads as 0.
#   opt_expr (proc, prep, every opt): constant-x bits at the same position of
#     an $eq or $ne compare equal ($eqx and $nex compare them exactly).
#   opt_merge (prep, every opt): identical cells whose inputs hold a constant x
#     become one.
#   opt_reduce (opt without -fast, prep): equal output bits of a multiplexer
#     that drives a memory write enable, constant x included, become one bit,
#     as do repeated constant-x select bits of a $bmux or $demux.
#   proc_rom (proc unless -norom, prep): a case of constants becomes a ROM.
#     After memory_collect (in prep) or memory_map -keepdc, each x word, such
#     as an x default, holds one value for the whole trace. Yosys's global-clock
#     memory_map -formal implies -keepdc. FROST scripts accept only the
#     -keepdc form and pinned plain memory_map.
#   proc_dlatch (proc, prep): in a latch's fan-in, all-x cases are dropped and
#     an all-x default is replaced by a defined case; when it decides in which
#     cases a latch holds, it reads multiplexer inputs through connections, so
#     an x that a wire carries to a multiplexer in the feedback path counts too.
#   proc_dff (proc, prep): an undefined asynchronous reset value becomes a
#     register parameter, which setundef does not reach and opt_merge compares
#     exactly, so two such registers can become one.
#   The default techmap: its shift templates run opt_muxtree and opt_expr
#     -mux_undef on the constant inputs of the cell they map.
# opt_clean drops the initial value of a wire that a constant x drives, so
# that x stays undefined. Every script therefore opens as the check of
# undefined constants below describes, which leaves none of these passes an
# undefined constant of the sources in a cell port, a connection or a
# register.
DONT_CARE_SAFE: dict[str, list[tuple[str, str]]] = {}
DONT_CARE_REJECTED: dict[str, list[tuple[str, str]]] = {}
for _form in SCRIPT_FORMS:
    if _form.safe_reason is not None:
        DONT_CARE_SAFE.setdefault(_form.command, []).append(
            (_form.id, _form.safe_reason)
        )
    elif _form.rejected_reason is not None:
        DONT_CARE_REJECTED.setdefault(_form.command, []).append(
            (_form.id, _form.rejected_reason)
        )
# Each open entry gives a reason and the ordered list of rejected commands
# for each task. The pin check catches additions, repetitions, removals,
# reordering and moves between tasks that change these lists. Adding,
# removing or editing commands in safe forms leaves the pins intact when the
# rejected lists stay the same, as does moving a pinned command past safe
# commands. ROADMAP.md's verification items describe the open work.
DONT_CARE_OPEN: dict[str, tuple[str, dict[str, list[str]]]] = {
    "axi_cdc": (
        "not converted: memory_map and opt -full; no setundef",
        {
            "prove_aw prove_w prove_b prove_ar prove_r cover": [
                "memory_map",
                "opt -full",
            ],
        },
    ),
    "axi_coherent_bridge": (
        "the partitions retype their assertions and map them with a file that adds an assumption per assertion and a register starting at 1",
        {
            "prove_soc": [
                "chtype -set axi_coherent_bridge_checked_assert @other",
                "techmap -max_iter 1 -map %assertion_map",
            ],
            "prove_soc_held": [
                "chtype -set axi_coherent_bridge_checked_assert @held",
                "techmap -max_iter 1 -map %assertion_map",
            ],
            "prove_soc8_0": [
                "chtype -set axi_coherent_bridge_checked_assert @group0",
                "techmap -max_iter 1 -map %assertion_map",
            ],
            "prove_soc8_1": [
                "chtype -set axi_coherent_bridge_checked_assert @group1",
                "techmap -max_iter 1 -map %assertion_map",
            ],
            "prove_soc8_2": [
                "chtype -set axi_coherent_bridge_checked_assert @group2",
                "techmap -max_iter 1 -map %assertion_map",
            ],
            "prove_soc8_3": [
                "chtype -set axi_coherent_bridge_checked_assert @group3",
                "techmap -max_iter 1 -map %assertion_map",
            ],
            "prove_soc8_4": [
                "chtype -set axi_coherent_bridge_checked_assert @group4",
                "techmap -max_iter 1 -map %assertion_map",
            ],
            "prove_soc8_5": [
                "chtype -set axi_coherent_bridge_checked_assert @group5",
                "techmap -max_iter 1 -map %assertion_map",
            ],
            "prove_soc8_6": [
                "chtype -set axi_coherent_bridge_checked_assert @group6",
                "techmap -max_iter 1 -map %assertion_map",
            ],
            "prove_soc8_7": [
                "chtype -set axi_coherent_bridge_checked_assert @group7",
                "techmap -max_iter 1 -map %assertion_map",
            ],
            "prove_soc8_8": [
                "chtype -set axi_coherent_bridge_checked_assert @group8",
                "techmap -max_iter 1 -map %assertion_map",
            ],
        },
    ),
    "backing_btb": (
        "runs memory_map and opt -fast without -keepdc after the opening",
        {
            "bmc bmc_four_way prove prove_four_way cover size_select size_select_four_way": [
                "memory_map",
                "opt -fast",
            ],
        },
    ),
    "branch_prediction_alias": (
        "opt -purge prunes predictor state outside the alias comparison",
        {
            "bmc": ["opt -purge"],
        },
    ),
    "branch_prediction_disable": (
        "not converted: plain opt after its setundef",
        {
            "bmc": ["opt"],
        },
    ),
    "branch_predictor_twin": (
        "equiv_struct merges structurally equal cells and equiv_simple reads undefined bits as zero, after both forms open with free_undefined.ys",
        {
            "bp_twin": ["equiv_struct -icells", "equiv_simple"],
        },
    ),
    "btb_pending_relation": (
        "not converted: plain opt after its setundef",
        {
            "bmc bmc_btb_index1 bmc_btb_index3": ["opt"],
        },
    ),
    "btb_tag_compare": (
        "not converted: plain opt after its setundef",
        {
            "bmc bmc_small_btb": ["opt"],
        },
    ),
    "cache_flash_valid": (
        "runs memory_map and opt without -keepdc after the opening",
        {
            "bmc_fast bmc_fast_ways1 bmc_hw cover_fast cover_fast_ways1 cover_hw": [
                "memory_map",
                "opt",
            ],
        },
    ),
    "cache_mshr_payload": (
        "not converted: memory_map and opt without -keepdc; no setundef",
        {
            "bmc bmc_mshr8": ["memory_map", "opt"],
        },
    ),
    "cache_way_choice": (
        "not converted: memory_map and opt without -keepdc; no setundef",
        {
            "bmc bmc_ways1 bmc_delayed": ["memory_map", "opt"],
        },
    ),
    "cached_tier_adapter_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "cached_tier_twin cached_tier_unsplit": ["equiv_simple"],
        },
    ),
    "cdc_mailbox": (
        "not converted: opt -fast; no setundef",
        {
            "bmc cover": ["opt -fast"],
        },
    ),
    "coherence_dma_ingress": (
        "runs memory_map and opt without -keepdc after the opening",
        {
            "coh_dma_ingress_prove coh_dma_ingress_cover coh_dma_ingress_soc_prove coh_dma_ingress_soc_cover coh_line_client_prove coh_line_client_eight_prove coh_line_client_cover coh_line_client_eight_cover": [
                "memory_map",
                "opt",
            ],
        },
    ),
    "coherence_home": (
        "not converted: memory_map and opt without -keepdc; no setundef",
        {
            "coh_home_control_prove coh_home_control64_prove coh_home_control_partition_prove coh_home_control_fast_prove coh_home_control64_fast_prove coh_home_control_partition_fast_prove coh_home_control4_bmc coh_home_control4_ultra_bmc coh_home_control4_ultra_fast_bmc coh_home_fill_cover coh_home_cmo_cover coh_home_wb_prove coh_home_victim_cover coh_home_error_cover coh_home_prefetch_cover coh_home_dispatch_cover coh_home_fast_cover": [
                "memory_map",
                "opt",
            ],
        },
    ),
    "coherence_home_engine": (
        "not converted: memory_map and opt without -keepdc; no setundef",
        {
            "coh_home_engine_prove coh_home_engine64_prove coh_home_engine_cover": [
                "memory_map",
                "opt",
            ],
        },
    ),
    "coherence_home_engine_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "home_engine_twin32 home_engine_twin64 home_engine_twin40": [
                "equiv_simple"
            ],
        },
    ),
    "coherence_home_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "home_twin_small home_twin_four home_twin_addr40": ["equiv_simple"],
        },
    ),
    "coherence_l1d": (
        "converted in its own commit; its conflict tasks cut every flop, then run opt -full and sat",
        {
            "coh_l1d_perf_prove coh_l1d_bmc coh_l1d_multi_bmc coh_l1d_stream_bmc coh_l1d_stream_hold_bmc coh_l1d_stream_free_nostore_bmc coh_l1d_stream_free_nostore_hold_bmc coh_l1d_stream_free_bmc coh_l1d_stream_outlier_prove coh_l1d_stream_owned_prove coh_l1d_stream_snapshot_prove coh_l1d_stream_prove coh_l1d_stream_cover coh_l1d_snapshot_cover coh_l1d_turn_cover coh_l1d_cover coh_l1d_path_cover coh_l1d_put_select_prove coh_l1d_data_bmc coh_l1d_data1_bmc coh_l1d_data2_bmc coh_l1d_data3_bmc coh_l1d_store_payload_bmc coh_l1d_store_grant_bmc coh_l1d_store_multi_payload_bmc coh_l1d_store_multi_grant_bmc coh_l1d_multi_data0_bmc coh_l1d_multi_data1_bmc coh_l1d_multi_data2_bmc coh_l1d_multi_data3_bmc coh_l1d_ways_data_bmc coh_l1d_answer_bmc coh_l1d_stream_answer_bmc coh_l1d_local_prove coh_l1d_local_multi_prove coh_l1d_local_owned_prove coh_l1d_local_multi_owned_prove coh_l1d_local_ways_owned_prove coh_l1d_local_sector_prove coh_l1d_local_multi_sector_prove coh_l1d_local_ways_sector_prove coh_l1d_local_cover coh_l1d_local_data_bmc coh_l1d_local_hold_bmc coh_l1d_local_control_bmc coh_l1d_local_ways_prove coh_l1d_zero_bmc coh_l1d_zero_multi_bmc coh_l1d_zero_payload_bmc coh_l1d_zero_cover coh_l1d_zero_lookahead_cover coh_l1d_zero_stream_hint_bmc coh_l1d_zero_stream_line_bmc coh_l1d_zero_stream_upper_ep0_bmc coh_l1d_zero_stream_upper_ep1_read_bmc coh_l1d_zero_stream_upper_ep1_store_bmc coh_l1d_zero_stream_upper_ep1_lookahead_bmc coh_l1d_zero_stream_upper_ep1_prefetch_bmc coh_l1d_zero_stream_upper_ep1_rest_bmc coh_l1d_zero_stream_upper_ep2_bmc coh_l1d_zero_progress_cover coh_l1d_zero_stream_bmc coh_l1d_zero_request_cover coh_l1d_full_bmc coh_l1d_full_multi_bmc coh_l1d_full_payload_bmc coh_l1d_full_cover coh_l1d_full_lookahead_cover coh_l1d_withdraw_full_bmc coh_l1d_withdraw_zero_bmc coh_l1d_withdraw_full_payload_bmc coh_l1d_withdraw_zero_payload_bmc coh_l1d_withdraw_full_cover coh_l1d_full_hold_cover coh_l1d_buffer_contract_bmc": [
                "memory_map",
                "opt",
                "opt -fast",
            ],
            "coh_l1d_conflict_prove coh_l1d_conflict_multi_prove coh_l1d_conflict_stream_prove": [
                "memory_map",
                "opt",
                "opt -fast",
                "opt -full",
                "sat -seq 2 -prove-asserts -verify -timeout 60",
                "opt -full",
                "sat -seq 2 -prove-asserts -verify -timeout 60",
            ],
        },
    ),
    "coherence_l1d_twin": (
        "the two autoname passes pair free cells before equiv_simple, which reads undefined bits as zero",
        {
            "l1d_twin_single l1d_twin_multi l1d_twin_stream": [
                "autoname t:$anyseq",
                "autoname t:$anyseq",
                "equiv_simple",
            ],
        },
    ),
    "coherence_l1d_zero_index": (
        "converted together with coherence_l1d, in its own commit",
        {
            "zero_index_prove zero_index_invariants": ["memory_map", "opt"],
        },
    ),
    "coherence_read_capture": (
        "converted together with coherence_l1d, in its own commit",
        {
            "coh_read_capture_prove coh_read_capture_stream_prove coh_idle_select_prove coh_idle_select_stream_prove coh_idle_phase_prove coh_idle_phase_stream_prove coh_read_kind_prove coh_array_reply_prove coh_array_reply4_prove coh_array_reply_uram_prove coh_array_reply4_uram_prove": [
                "memory_map"
            ],
        },
    ),
    "coherence_sc_wa": (
        "cover-only compaction: abc reads constant x bits as 0 and opt -fine merges equal multiplexer output bits with constant x; all four prove tasks stay in DONT_CARE_SAFE",
        {
            "sc_wa_s0_cover sc_wa_s1_cover sc_wa_s2_cover sc_wa_s3_cover": [
                "abc",
                "opt -keepdc -mux_bool -fine",
            ],
        },
    ),
    # With every register starting free, bmc_load_same takes 1,480 s against
    # 451 s, about 3.5 times as long per frame, also from the state after the
    # reset cycle, and smtbmc with Boolector checks 38 of its 80 steps in 20
    # minutes; the long tasks would not fit their limits.
    "coherence_store_boundary": (
        "plain memory_map and opt: its BMC tasks run them before their setundef, its cover and sticky tasks have none",
        {
            "bmc_four_control bmc_four_value_0 bmc_four_value_1 bmc_four_value_2 bmc_four_value_3 bmc_intervening_same_flow bmc_intervening_other_flow bmc_intervening_same_value bmc_intervening_other_value bmc_intervening_fatal bmc_load_same bmc_load_other bmc_load_same_probe_launch bmc_probe_kept_other bmc_probe_kept_same bmc_amo_same bmc_amo_same_owner bmc_amo_same_fatal bmc_amo_other bmc_amo_other_fatal bmc_sc bmc_old": [
                "memory_map",
                "opt",
                "opt -fast",
            ],
            "cover_four prove_intervening_fatal_sticky prove_amo_same_fatal_sticky prove_amo_other_fatal_sticky cover_load cover_amo cover_amo_same cover_amo_same_two cover_amo_other_home cover_sc cover_old cover_edges_same cover_edges_same_combined cover_edges_other cover_probe_kept_other cover_probe_kept_same": [
                "memory_map",
                "opt",
            ],
        },
    ),
    "coherence_store_home": (
        "peepopt in the BMCs and abc in the compact covers read constant x bits as 0, and the compact covers' opt -fine merges equal multiplexer output bits with constant x",
        {
            "bmc_siblings bmc_siblings_second bmc_rows bmc_rows_second bmc_conflict bmc_conflict_second bmc_pressure bmc_pressure_second link_bmc_siblings link_bmc_siblings_second link_bmc_pressure link_bmc_pressure_second": [
                "peepopt"
            ],
            "cover_conflict cover_pressure link_cover_pressure": [
                "abc",
                "opt -keepdc -mux_bool -fine",
            ],
        },
    ),
    # From the state after the reset cycle with every other register free, the
    # PDR proof of the unbounded pair leaves one assertion unresolved in its
    # limit.
    "coherent_hart_cache": (
        "plain passes in the unbounded pair; the reset-state task retypes $eqx and $nex as $eq and $ne for sim, whose -w gives it its start; the covers zero undefined constants",
        {
            "coh_hart_maint_prove coh_hart_maint_owned_prove": [
                "memory_map",
                "opt",
                "opt -fast",
            ],
            "coh_hart_maint_owned_reset_prove": [
                "chtype -map $eqx $eq",
                "chtype -map $nex $ne",
                "sim -clock i_clk -n 1 -w",
            ],
            "coh_hart_maint_cover coh_hart_maint_four_cover": ["setundef -zero"],
        },
    ),
    "coherent_store_pma_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "store_pma_twin_ddr30 store_pma_twin_ddr31": ["equiv_simple"],
        },
    ),
    "control_flow_tracker_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "cft_twin": ["equiv_simple"],
        },
    ),
    "csr_file_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "csr_twin csr_twin_vector": ["equiv_simple"],
        },
    ),
    "data_mem_request_router_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "router_twin": ["equiv_simple"],
        },
    ),
    "dc_fifo": (
        "not converted: memory_map and opt -full; no setundef",
        {
            "prove prove_margin2 cover": ["memory_map", "opt -full"],
        },
    ),
    "l0_store_boundary_twin": (
        "equiv_simple runs after undefined constants are opened in both boundary forms",
        {"boundary_twin": ["equiv_simple"]},
    ),
    "decoded_bundle_queue_twin": (
        "the two autoname passes pair free cells before equiv_simple, which reads undefined bits as zero",
        {
            "dbq_twin": ["autoname t:$anyseq", "autoname t:$anyseq", "equiv_simple"],
        },
    ),
    "dmmu_capture": (
        "not converted: plain opt after its setundef",
        {
            "bmc prove cover": ["opt"],
        },
    ),
    "dmmu_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "dmmu_twin": ["equiv_simple"],
        },
    ),
    "fetch_pc_mux": (
        "not converted: plain opt after its setundef",
        {
            "bmc bmc_integrated bmc_xilinx bmc_integrated_xilinx": ["opt"],
        },
    ),
    "fp_engine_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "fp_engine_twin": ["equiv_simple"],
        },
    ),
    "id_stage_kill_equiv": (
        "the two autoname passes pair free cells before equiv_simple, which reads undefined bits as zero",
        {
            "id_kill_equiv id_kill_equiv_vector": [
                "autoname t:$anyseq",
                "autoname t:$anyseq",
                "equiv_simple",
            ],
        },
    ),
    "if_slot2_precompute": (
        "not converted: plain opt after its setundef",
        {
            "if_slot2_precompute_bmc if_slot2_precompute_cover": ["opt"],
        },
    ),
    "imem_predecode_twin": (
        "equiv_simple runs after opening undefined constants in both IMEM forms",
        {"imem_predecode_live": ["equiv_simple"]},
    ),
    "immu_bare": (
        "opt -purge prunes translation state outside the Bare outputs",
        {
            "bmc bmc_1g bmc_64g bmc_128g bmc_xlen32 bmc_xlen72": ["opt -purge"],
        },
    ),
    "immu_memo": (
        "not converted: plain opt after its setundef",
        {
            "bmc prove": ["opt"],
        },
    ),
    "immu_page_offset": (
        "not converted: plain opt after its setundef",
        {
            "bmc prove": ["opt"],
        },
    ),
    "immu_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "immu_twin immu_twin_hold": ["equiv_simple"],
        },
    ),
    "line_client_link": (
        "memory_map and opt run without -keepdc after undefined constants are freed",
        {
            "line_link0_bmc line_link1_bmc line_link1_four_bmc line_link1_eight_bmc line_link1_cover": [
                "memory_map",
                "opt",
            ],
        },
    ),
    "lq_capture": (
        "abc -g AND, which reads an undefined bit as 0, after cutpoint has cut every flop",
        {
            "coh_lq_capture4_prove coh_lq_capture8_prove coh_lq_capture8_xilinx_prove coh_lq_capture16_prove coh_lq_capture_no_forward_prove coh_lq_capture_no_l0_prove coh_lq_capture_plain_prove": [
                "abc -g AND"
            ],
        },
    ),
    "lq_ram_payload": (
        "not converted: plain opt after its setundef",
        {
            "bmc bmc_forward bmc_forward_only bmc_core cover": ["opt"],
        },
    ),
    "lq_result_valid": (
        "abc -g AND, which reads an undefined bit as 0, after cutpoint has cut every flop",
        {
            "result4_prove result8_prove result8_xilinx_prove result16_prove result_no_forward_prove result_no_l0_prove result_plain_prove": [
                "abc -g AND"
            ],
        },
    ),
    "lq_sector_copy": (
        "not converted: plain opt after its setundef",
        {
            "sector_copy_prove sector_copy_xilinx_prove": ["opt"],
        },
    ),
    "mwp_dist_ram": (
        "not converted: memory_map and opt -fast without -keepdc; no setundef",
        {
            "bmc bmc_addr1 bmc_unstaged cover": ["memory_map", "opt -fast"],
        },
    ),
    "nic_dma_front": (
        "runs opt -fast without -keepdc after the opening",
        {
            "bmc cover": ["opt -fast"],
        },
    ),
    "pc_controller_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "pc_controller_twin pc_controller_twin_slot2": ["equiv_simple"],
        },
    ),
    "pc_holdoff_cofactor": (
        "not converted: plain opt after its setundef",
        {
            "bmc": ["opt"],
        },
    ),
    "pc_holdoff_tag": (
        "not converted: plain opt after its setundef",
        {
            "prove prove_xlen32 prove_xlen72 cover": ["opt"],
        },
    ),
    "pc_pending_capture": (
        "not converted: plain opt after its setundef",
        {
            "bmc bmc_integrated": ["opt"],
        },
    ),
    "pc_redirect_catchup_producer": (
        "not converted: plain opt after its setundef",
        {
            "x32 x64 x66": ["opt"],
        },
    ),
    "pc_register_mux": (
        "not converted: plain opt after its setundef",
        {
            "bmc bmc_integrated bmc_xilinx bmc_integrated_xilinx": ["opt"],
        },
    ),
    "pc_tage_events": (
        "not converted: plain opt after its setundef",
        {
            "pc_tage_events_prove pc_tage_events_cover": ["opt"],
        },
    ),
    "pd_target_candidate_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "pdt_twin": ["equiv_simple"],
        },
    ),
    "ras_checkpoint": (
        "not converted: plain opt after its setundef",
        {
            "bmc": ["opt"],
        },
    ),
    "rat_checkpoint_restore": (
        "runs memory_map and opt -full without -keepdc after the opening",
        {
            "prove_int_active prove_int_ckpt_lo prove_int_ckpt_mid prove_int_ckpt_hi prove_fp_active prove_fp_ckpt_lo prove_fp_ckpt_mid prove_fp_ckpt_hi cover": [
                "memory_map",
                "opt -full",
            ],
        },
    ),
    "reservation_station_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "rs_twin_indexed": ["equiv_simple"],
        },
    ),
    "rob_bypass_control": (
        "not converted: plain opt after its setundef",
        {
            "bmc": ["opt"],
        },
    ),
    "rob_control_next": (
        "not converted: plain opt after its setundef",
        {
            "bmc": ["opt"],
        },
    ),
    "rob_retire_ready": (
        "not converted: plain opt after its setundef",
        {
            "prove": ["opt"],
        },
    ),
    "rob_retire_stall": (
        "not converted: plain opt after its setundef",
        {
            "bmc": ["opt"],
        },
    ),
    "rob_start_cofactor": (
        "not converted: plain opt after its setundef",
        {
            "prove": ["opt"],
        },
    ),
    "rs_divide_gate": (
        "not converted: plain opt after its setundef",
        {
            "prove cover": ["opt"],
        },
    ),
    "rs_indexed_deferred_fold": (
        "not converted: plain opt after its setundef",
        {
            "prove_int prove_mem prove_src3 prove_mul cover_int": ["opt"],
        },
    ),
    "rs_issue_clear": (
        "not converted: plain opt after its setundef",
        {
            "bmc bmc4 bmc8 bmc16 bmc32": ["opt"],
        },
    ),
    "rs_issue_tag_banks": (
        "in-script equivalence check with every flop cut: equiv_struct merging, and sat and equiv_simple reading x as 0 after opening with free_undefined.ys",
        {
            "int_equiv int_equiv_prims": [
                "sat -seq 1 -verify -prove entry_cdb_tag[0] i_issue_cdb_tag -prove entry_cdb_tag[5] i_issue_cdb_tag -prove entry_cdb_tag[10] i_issue_cdb_tag -prove entry_cdb_tag[15] i_issue_cdb_tag -prove entry_cdb_2_tag[0] i_issue_cdb_2_tag -prove entry_cdb_2_tag[5] i_issue_cdb_2_tag -prove entry_cdb_2_tag[10] i_issue_cdb_2_tag -prove entry_cdb_2_tag[15] i_issue_cdb_2_tag reservation_station",
                "sat -seq 1 -verify -prove entry_cdb_tag[0] i_issue_cdb_tag -prove entry_cdb_tag[5] i_issue_cdb_tag -prove entry_cdb_tag[10] i_issue_cdb_tag -prove entry_cdb_tag[15] i_issue_cdb_tag -prove entry_cdb_2_tag[0] i_issue_cdb_2_tag -prove entry_cdb_2_tag[5] i_issue_cdb_2_tag -prove entry_cdb_2_tag[10] i_issue_cdb_2_tag -prove entry_cdb_2_tag[15] i_issue_cdb_2_tag reservation_station",
                "equiv_struct -icells",
                "equiv_simple",
            ],
        },
    ),
    "rs_lq_prematch": (
        "not converted: plain opt after its setundef",
        {
            "bmc prove": ["opt"],
        },
    ),
    "rs_payload_twin": (
        "both copies start from the same zero state, as its harness states",
        {
            "bmc bmc_cdb bmc_cdb_2 bmc_commit bmc_commit_2 bmc_operands cover_cmo_request": [
                "setundef -zero -init"
            ],
        },
    ),
    "rs_primary_payload": (
        "not converted: plain opt after its setundef; memory_map and opt and no setundef in prove",
        {
            "bmc16 bmc8 bmc4": ["opt"],
            "prove": ["memory_map", "opt"],
        },
    ),
    "rs_raw_pretag": (
        "not converted: plain opt after its setundef",
        {
            "bmc bmc_export bmc_ready_vector": ["opt"],
        },
    ),
    "rs_stage2_payload_equiv": (
        "not converted: plain opt after its setundef",
        {
            "int_prove mul_prove mem_prove fp_prove int_cover": ["opt"],
        },
    ),
    "sq_committed_empty": (
        "not converted: plain opt after its setundef",
        {
            "bmc": ["opt"],
        },
    ),
    "sq_early_sq_copy": (
        "not converted: plain opt after its setundef in prove_integrated, without one in the others",
        {
            "prove prove_integrated cover": ["opt"],
        },
    ),
    "sq_forwarding_unit": (
        "not converted: opt -fast in one task, which has no setundef",
        {
            "tree_equiv": ["opt -fast"],
        },
    ),
    "sq_live_result_select": (
        "not converted: opt; no setundef",
        {
            "prove": ["opt"],
        },
    ),
    "store_queue_twin": (
        "equiv_simple reads undefined bits as zero, so every comparison point is opened first",
        {
            "sq_twin sq_twin_cpu": ["equiv_simple"],
        },
    ),
    "sync_dist_ram_fifo": (
        "not converted: memory_map and opt -fast without -keepdc; no setundef",
        {
            "bmc cover": ["memory_map", "opt -fast"],
        },
    ),
}


def sby_task_tags(sby_path: Path) -> dict[str, set[str]]:
    """Return the declared tasks and their literal group tags."""
    return {
        task: tags for task, tags in sby_config.source(sby_path).tasks.items() if task
    }


def sby_line_tag(line: str, every_tag: set[str]) -> tuple[str, str]:
    """Split a literal task selector at the start of a validated source line."""
    match = sby_config.TAG.fullmatch(line)
    if match and match[2] in every_tag:
        return match[1] + match[2] + ":", match[3].lstrip()
    return "", line


def dont_care_safe(args: list[str]) -> bool:
    """Report whether args match a don't-care-safe form in SCRIPT_FORMS."""
    try:
        return sby_config.match_command_form(args).is_safe
    except sby_config.ConfigError:
        return False


def dont_care_optimizations(commands: list[list[str]]) -> list[str]:
    """Return the commands outside DONT_CARE_SAFE a script runs, in order."""
    return [" ".join(args) for args in commands if not dont_care_safe(args)]


def sby_dont_care_optimizations(sby_path: Path) -> dict[str, list[str]]:
    """Return each task's commands outside DONT_CARE_SAFE, in execution order."""
    return {
        task: found
        for task, cfg in sby_config.resolved(sby_path).items()
        if (
            found := [
                " ".join(cmd.args)
                for cmd in cfg.parsed(sby_path.parent)
                if not cmd.form.is_safe
            ]
        )
    }


def dont_care_pins(name: str) -> dict[str, list[str]]:
    """Return each task's pinned commands from a target's open entry."""
    pins: dict[str, list[str]] = {}
    for tasks, commands in DONT_CARE_OPEN.get(name, ("", {}))[1].items():
        assert commands, (name, tasks)
        for task in tasks.split():
            assert task not in pins, (name, task)
            pins[task] = commands
    return pins


def dont_care_changes(sby_path: Path) -> tuple[list[str], list[str]]:
    """Return the flagged commands a script runs beyond its open entry, and those it lacks.

    Each task's commands are compared in order with its pinned ones: a command
    run a further time is added, one dropped is lacking, and a reordered or
    moved one is both. A file without an entry adds every command it flags. A
    task named "-" is the one task of a file without a [tasks] section.
    """
    try:
        flagged = sby_dont_care_optimizations(sby_path)
    except sby_config.ConfigError as error:
        return [str(error)], []
    found = {task or "-": commands for task, commands in flagged.items()}
    pinned = dont_care_pins(sby_path.stem)
    added: list[str] = []
    missing: list[str] = []
    for task in sorted(found.keys() | pinned.keys()):
        old, new = pinned.get(task, []), found.get(task, [])
        matcher = difflib.SequenceMatcher(a=old, b=new, autojunk=False)
        for tag, start, end, new_start, new_end in matcher.get_opcodes():
            if tag != "equal":
                missing += [f"{sby_path.name} {task}: {c}" for c in old[start:end]]
                added += [
                    f"{sby_path.name} {task}: {c}" for c in new[new_start:new_end]
                ]
    return added, missing


def test_scripts_keep_dont_cares() -> None:
    """No proof script runs a command outside DONT_CARE_SAFE beyond its open entry."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    sby_config.resolve_files(formal.glob("*.sby"))
    added: list[str] = []
    missing: list[str] = []
    for sby_path in sorted(formal.glob("*.sby")):
        new, gone = dont_care_changes(sby_path)
        added += new
        missing += gone
    # An added command needs a form in DONT_CARE_SAFE, a converted script, or
    # its place in the task's open entry.
    assert not added, added
    # A pinned command that does not occur in its place is stale: update
    # DONT_CARE_OPEN.
    assert not missing, missing
    assert (
        sorted(
            name for name in DONT_CARE_OPEN if not (formal / f"{name}.sby").is_file()
        )
        == []
    )


def test_dont_care_classifies_every_command() -> None:
    """Every form and option in SCRIPT_FORMS is classified and used on main."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    sby_config.resolve_files(formal.glob("*.sby"))
    used_forms: set[str] = set()
    used_options: dict[str, set[str]] = {form.id: set() for form in SCRIPT_FORMS}
    for sby_path in sorted(formal.glob("*.sby")):
        for cfg in sby_config.resolved(sby_path).values():
            for expand in (False, True):
                for cmd in cfg.parsed(sby_path.parent, expand_opening=expand):
                    form = cmd.form
                    used_forms.add(form.id)
                    opt_map = dict(form.opt_args)
                    idx = 1
                    while idx < len(cmd.args):
                        tok = cmd.args[idx]
                        if tok in form.flags or tok in form.required_flags:
                            used_options[form.id].add(tok)
                            idx += 1
                        elif tok in opt_map:
                            used_options[form.id].add(tok)
                            idx += 1 + len(opt_map[tok])
                        else:
                            for prefix, _ in form.prefix_opts:
                                if tok.startswith(prefix) and len(tok) > len(prefix):
                                    used_options[form.id].add(prefix)
                                    break
                            idx += 1
    unused = [form.id for form in SCRIPT_FORMS if form.id not in used_forms]
    assert not unused, unused
    for form in SCRIPT_FORMS:
        declared = (
            set(form.flags)
            | set(form.required_flags)
            | {opt for opt, _ in form.opt_args}
            | {prefix for prefix, _ in form.prefix_opts}
        )
        assert used_options[form.id] == declared, (
            form.id,
            declared - used_options[form.id],
        )
        reason = form.safe_reason or form.rejected_reason
        assert reason and "\n" not in reason, form.id


# Undefined constants. SymbiYosys makes them free inputs only after the script,
# and the passes above fuse or fix them first. So each task's script opens,
# after the commands that read sources, set parameters and elaborate, with
#
#   hierarchy -top <top>
#   script free_undefined.ys
#
# and lists formal/free_undefined.ys in [files]. That file runs
# UNDEFINED_OPENING and says why each command is there: proc pass by pass,
# without proc_rom; a setundef -anyseq on every multiplexer and every
# connection, but on no memory or process, before proc_dlatch, which reads
# both and would let a latch keep its value in an all-x case of its fan-in; an
# opt_expr on memory initializations alone, which setundef's memory handling
# needs; a setundef -anyseq on the whole design before proc_dff, so that an
# undefined asynchronous reset value becomes a free asynchronous load rather
# than a register parameter; and proc's own closing opt_expr -keepdc once
# nothing undefined is left, so that the commands after the opening see the
# netlist plain proc gives them (a multiplexer with a constant select folded
# into a connection), apart from case tables kept as multiplexers, the free
# values and the asynchronous loads. After it no undefined constant of the
# sources is left in a cell port, a connection or a register. Commands pinned
# in an open entry are the exception: a plain memory_map, for one, writes x
# for words that nothing writes, and a plain opt after it can read them before
# SymbiYosys frees them. What is left are memory parameters: the initial
# contents, which memory_map -keepdc keeps free, and the reset and initial
# values of read ports without a clock, which no pass reads. Later passes
# write x only where nothing uses the value: opt_dff on the feedback path of a
# register it gives an enable, wreduce on bits that nothing reads. In a script
# that opens this way, the undefined-constant cases in the reasons of prep,
# proc, proc_dlatch, proc_dff, opt, opt_expr, opt_merge, opt_muxtree and
# techmap above find none of these constants to act on.
#
# For every task of a script that neither pending list names, the check
# requires `script free_undefined.ys`, with free_undefined.ys listed in
# [files] as that single word, so that SymbiYosys copies the repository's
# file, and neither a changed copy, another path nor a [file] section in its
# place (the file's own commands are pinned to UNDEFINED_OPENING, and its
# commands written out or held in another file are not the opening); a
# hierarchy -top after the last source and before it; the whole design
# selected when it runs (select -module and cd <module> scope it until select
# -clear or cd .., design -save and -stash keep that scope with the design for
# design -load to bring back, design -reset clears it, and free_undefined.ys
# begins with select -clear); after it, another opening before the next
# command that acts once a source is read, a macro is defined, or a parameter
# is set again (read, read_verilog, read_slang, verilog_defines, chparam,
# hierarchy -chparam), the design is reset, or a module of a kept design joins
# it (design -copy-from), a design that design -load brings back opened only
# if it was when it was kept, and the final design at the end of [script]
# opened; the same top in every later hierarchy -top and prep -top; no connect
# to a constant with an x or z bit, in any spelling; and setundef -anyseq on
# the whole design right after a script's own async2sync, which writes x where
# an asynchronous set and clear are both active.
#
# The opening does not reach undefined values that a cell computes, such as a
# $shiftx read past its input, which the backends and the default techmap's
# shift templates give a defined value, or a $pmux with more than one select
# set. The runner checks the elaborated model for constant z bits before the
# opening. An x-initialized memory stops the first pass that reads it with
# "Non-constant data".
UNDEFINED_OPENING = [
    ["select", "-clear"],
    ["proc_clean"],
    ["proc_rmdead"],
    ["proc_prune"],
    ["proc_init"],
    ["proc_arst"],
    ["proc_mux"],
    ["setundef", "-anyseq", "t:$mux", "t:$pmux", "t:$bwmux", "w:*"],
    ["proc_dlatch"],
    ["opt_expr", "-keepdc", "t:$meminit*"],
    ["setundef", "-anyseq"],
    ["proc_dff"],
    ["proc_memwr"],
    ["proc_clean"],
    ["opt_expr", "-keepdc"],
]
# File-writing forms are a direct consequence of SCRIPT_FORMS: only forms with
# writes_file=True may write a file. These include compiled port lists in JSON
# and the bridge's RTLIL model.
SCRIPT_FILE_WRITES = frozenset(form.id for form in SCRIPT_FORMS if form.writes_file)
# Options that write files on commands present in SCRIPT_FORMS; checked against
# Yosys's help so no writes_file=False form can gain a file-writing option.
FORBIDDEN_WRITE_OPTIONS = frozenset(
    {
        "-o",
        "-a",
        "-write",
        "-dump_vcd",
        "-dump_json",
        "-dump_cnf",
        "-vcd",
        "-fst",
        "-aiw",
        "-script",
        "-vlog",
        "-encfile",
        "-fm_set_fsm_file",
        "-export",
        "--diag-json",
        "--Mall",
        "--all-deps",
        "--Minclude",
        "--include-deps",
        "--Mmodule",
        "--module-deps",
    }
)
UNDEFINED_OPENING_FILE = "free_undefined.ys"
UNDEFINED_OPENING_MARK = ["script", UNDEFINED_OPENING_FILE]
# Scripts that do not open that way yet. The list only shrinks: a listed script
# whose every task opens fails the check.
UNDEFINED_OPENING_PENDING: tuple[str, ...] = ()
# Each exception names the existing tasks that still prove a selected cone.
UNDEFINED_OPENING_TWINS: dict[str, tuple[str, ...]] = {}


@dataclass(frozen=True)
class TwinComparison:
    """Inputs, cut state and comparison points for one pair of compiled forms."""

    primitive_points: int | None
    all_points: int
    top: str
    gold_inputs: tuple[str, ...]
    gate_inputs: tuple[str, ...]
    registers: int
    clock: str | None
    paired_free: int = 0
    gold_only_free: int = 0
    gate_only_free: int = 0
    equiv_free: int = 0
    name_free: bool = False
    hide_wires: tuple[str, ...] = ()
    clean_hidden: bool = False
    opt_clean_purge: bool = False
    pre_initialized_nets: int = 0
    initialized_nets: int = 0
    delete_after_copy: bool = False
    equiv_struct: bool = False
    gold_post_open: tuple[str, ...] = ()
    gold_post_flatten: tuple[str, ...] = ()
    gate_post_flatten: tuple[str, ...] = ()
    post_cut_checks: tuple[str, ...] = ()
    equiv_extra_checks: tuple[str, ...] = ()


DBQ_TWIN_PARAMETERS = (
    "chparam -set WIDTH 8 -set SHADOW_WIDTH 3 -set SPLIT_SHADOW_STALL 1 "
    "-set STALL_LATE_COPIES 4 decoded_bundle_queue"
)
HIDE_FUNC_AND_LOOP_TEMPS = ("w:*$func$*", "w:*$fordecl_block$*")
HOME_ENGINE_TWIN_GOLD = (
    "read -sv -D SYNTHESIS coherence_pkg.sv coherence_home_engine.sv",
    "chparam -set LINE_BYTES 32 -set WAYS 1 coherence_home_engine",
)
HOME_ENGINE_TWIN_GATE = (
    "read_verilog -formal +/xilinx/cells_sim.v",
    "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS coherence_pkg.sv coherence_home_engine.sv",
    "chparam -set LINE_BYTES 32 -set WAYS 1 coherence_home_engine",
)
HOME_TWIN_GOLD_READS = (
    "read -sv -D SYNTHESIS cache_perf_pkg.sv coherence_pkg.sv",
    "read -sv -D SYNTHESIS sdp_block_ram.sv sdp_packed_tag_uram.sv sdp_ram_byte_en.sv",
    "read -sv -D SYNTHESIS coherence_seat_select.sv coherence_work_select.sv "
    "coherence_home_endpoint.sv coherence_d_arbiter.sv coherence_home_completions.sv "
    "coherence_home_array.sv coherence_home_engine.sv coherence_home.sv",
)
HOME_TWIN_GATE_READS = (
    "read_verilog -formal +/xilinx/cells_sim.v",
    "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS cache_perf_pkg.sv coherence_pkg.sv",
    "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS sdp_block_ram.sv "
    "sdp_packed_tag_uram.sv sdp_ram_byte_en.sv",
    "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS coherence_seat_select.sv "
    "coherence_work_select.sv coherence_home_endpoint.sv coherence_d_arbiter.sv "
    "coherence_home_completions.sv coherence_home_array.sv coherence_home_engine.sv "
    "coherence_home.sv",
)
HOME_TWIN_SMALL_PARAMS = (
    "chparam -set CACHE_BYTES 128 -set WAYS 1 -set ULTRA 0 -set COMPLETIONS 2 "
    "-set RESULTS 2 -set FILLS 2 -set PREFETCH_SLOTS 0 coherence_home"
)
HOME_TWIN_FOUR_PARAMS = (
    "chparam -set CACHE_BYTES 1024 -set WAYS 4 -set ULTRA 1 -set COMPLETIONS 4 "
    "-set RESULTS 3 -set FILLS 3 -set PREFETCH_RESERVE 1 -set PREFETCH_SLOTS 0 "
    "coherence_home"
)
L1D_TWIN_GOLD_READS = (
    "read -sv -D SYNTHESIS cache_perf_pkg.sv coherence_pkg.sv",
    "read -sv -D SYNTHESIS coherence_read_stream.sv coherence_request_endpoint.sv",
    "read -sv -D SYNTHESIS coherence_put_endpoint.sv coherence_read_owners.sv "
    "coherence_miss_credit.sv coherence_read_flags.sv coherence_grant_select.sv "
    "coherence_read_payload.sv coherence_store_buffer.sv",
    "read -sv -D SYNTHESIS coherence_read_select.sv",
    "read -sv -D SYNTHESIS sdp_block_ram.sv sdp_packed_tag_uram.sv "
    "sdp_ram_byte_en.sv coherence_array.sv coherence_l1d.sv",
)
L1D_TWIN_GATE_READS = (
    "read_verilog -formal +/xilinx/cells_sim.v",
    "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS cache_perf_pkg.sv coherence_pkg.sv",
    "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS coherence_read_stream.sv "
    "coherence_request_endpoint.sv",
    "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS coherence_put_endpoint.sv "
    "coherence_read_owners.sv coherence_miss_credit.sv coherence_read_flags.sv "
    "coherence_grant_select.sv coherence_read_payload.sv coherence_store_buffer.sv",
    "read -sv -D SYNTHESIS coherence_read_select.sv",
    "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS sdp_block_ram.sv "
    "sdp_packed_tag_uram.sv sdp_ram_byte_en.sv coherence_array.sv coherence_l1d.sv",
)
RS_TWIN_SOURCES = (
    "riscv_pkg.sv sdp_dist_ram.sv mwp_dist_ram.sv mwp_dist_ram_ohread.sv "
    "rs_issue2_selector.sv coherent_rs_capacity.sv coherent_rs_issue2_selector.sv "
    "coherent_rs_payload_store.sv reservation_station.sv"
)
RS_TWIN_INDEXED_PARAMS = (
    "chparam -set PREPARE_ISSUE_CONTROLS 1 -set TAG_INDEXED_BRANCH_PAYLOAD 1 "
    "-set DUAL_ISSUE 1 -set HAS_SRC3 0 -set DISPATCH_REPAIR_BYPASS 0 "
    "-set ISSUE_REPAIR_BYPASS 0 -set ALLOC_INDEXED_REPAIR 1 "
    "-set TRACK_INT_WRITEBACK_HINT 1 -set SPECULATIVE_DATA_WRITES 1 "
    "-set BROADCAST_FREE_SOURCE_VALUES 1 -set ISSUE_CDB_TAG_SHADOW 1 "
    "-set ISSUE_CDB_META_ANCHORS 1 -set CAPTURE_PRIMARY_EFFECTIVE_OPERANDS 1 "
    "-set BRANCH_PREDICATE_TAG_ANCHOR 1 -set TRUST_DISPATCH_VALID 1 "
    "reservation_station"
)
RS_BANKS_GOLD_PARAMS = (
    "chparam -set PREPARE_ISSUE_CONTROLS 1 -set DEPTH 16 -set HAS_SRC3 0 "
    "-set DISPATCH_REPAIR_BYPASS 0 -set ISSUE_REPAIR_BYPASS 0 "
    "-set ALLOC_INDEXED_REPAIR 1 -set TRACK_INT_WRITEBACK_HINT 1 "
    "-set SPECULATIVE_DATA_WRITES 1 -set BROADCAST_FREE_SOURCE_VALUES 1 "
    "-set ISSUE2_WINDOW 8 -set ISSUE_CDB_TAG_SHADOW 1 -set ISSUE_CDB_META_ANCHORS 1 "
    "-set CAPTURE_PRIMARY_EFFECTIVE_OPERANDS 1 -set BRANCH_PREDICATE_TAG_ANCHOR 1 "
    "-set TRUST_DISPATCH_VALID 1 -set DUAL_ISSUE 1 -set TAG_INDEXED_BRANCH_PAYLOAD 1 "
    "-set FORMAL_STANDALONE_ENV 0 reservation_station"
)
RS_BANKS_GATE_PARAMS = (
    "chparam -set PREPARE_ISSUE_CONTROLS 1 -set DEPTH 16 -set HAS_SRC3 0 "
    "-set DISPATCH_REPAIR_BYPASS 0 -set ISSUE_REPAIR_BYPASS 0 "
    "-set ALLOC_INDEXED_REPAIR 1 -set TRACK_INT_WRITEBACK_HINT 1 "
    "-set SPECULATIVE_DATA_WRITES 1 -set BROADCAST_FREE_SOURCE_VALUES 1 "
    "-set ISSUE2_WINDOW 8 -set ISSUE_CDB_TAG_SHADOW 1 -set ISSUE_CDB_META_ANCHORS 1 "
    "-set ISSUE_CDB_TAG_BANKS 4 -set CAPTURE_PRIMARY_EFFECTIVE_OPERANDS 1 "
    "-set BRANCH_PREDICATE_TAG_ANCHOR 1 -set TRUST_DISPATCH_VALID 1 "
    "-set DUAL_ISSUE 1 -set TAG_INDEXED_BRANCH_PAYLOAD 1 "
    "-set FORMAL_STANDALONE_ENV 0 reservation_station"
)
RS_BANKS_SAT = (
    "sat -seq 1 -verify "
    "-prove entry_cdb_tag[0] i_issue_cdb_tag "
    "-prove entry_cdb_tag[5] i_issue_cdb_tag "
    "-prove entry_cdb_tag[10] i_issue_cdb_tag "
    "-prove entry_cdb_tag[15] i_issue_cdb_tag "
    "-prove entry_cdb_2_tag[0] i_issue_cdb_2_tag "
    "-prove entry_cdb_2_tag[5] i_issue_cdb_2_tag "
    "-prove entry_cdb_2_tag[10] i_issue_cdb_2_tag "
    "-prove entry_cdb_2_tag[15] i_issue_cdb_2_tag reservation_station",
)
ID_KILL_READ = (
    "read -sv -D SYNTHESIS riscv_pkg.sv instr_decoder.sv instr_operand_classifier.sv "
    "immediate_decoder.sv instruction_type_decoder.sv branch_target_precompute.sv "
    "id_stage.sv"
)
ID_KILL_GOLD_POST_OPEN = (
    "opt_clean",
    "select -module id_stage",
    r"connect -port operand_classifier \i_illegal \is_illegal_instruction",
    r"connect -port operand_classifier \i_fetch_fault \is_fetch_fault",
    r"connect -port operand_classifier_2 \i_illegal \is_illegal_instruction_2",
    r"connect -port operand_classifier_2 \i_fetch_fault \is_fetch_fault_2",
    r"delete w:\id_kill %ci t:$* %i",
    r"delete w:\id_kill_2 %ci t:$* %i",
    r"connect -set \id_kill 1'b0",
    r"connect -set \id_kill_2 1'b0",
    "select -clear",
)
ID_KILL_HIDE_WIRES = (
    "w:id_kill*",
    "w:*_nokill*",
    "w:operand_classifier.*",
    "w:operand_classifier_2.*",
)
ID_KILL_EXTRA_CHECKS = (
    "select -assert-count 34 w:has_int_dest_pre_gold w:has_fp_dest_pre_gold "
    "w:uses_int_rs1_pre_gold w:uses_int_rs2_pre_gold w:uses_fp_rs1_pre_gold "
    "w:uses_fp_rs2_pre_gold w:uses_fp_rs3_pre_gold w:rs_type_pre_gold "
    "w:is_int_store_pre_gold w:is_branch_or_jump_pre_gold w:is_fence_pre_gold "
    "w:is_fence_i_pre_gold w:is_sfence_vma_pre_gold w:is_csr_imm_pre_gold "
    "w:has_fp_flags_pre_gold w:needs_lq_pre_gold w:needs_sq_pre_gold "
    "w:has_int_dest_pre_2_gold w:has_fp_dest_pre_2_gold w:uses_int_rs1_pre_2_gold "
    "w:uses_int_rs2_pre_2_gold w:uses_fp_rs1_pre_2_gold w:uses_fp_rs2_pre_2_gold "
    "w:uses_fp_rs3_pre_2_gold w:rs_type_pre_2_gold w:is_int_store_pre_2_gold "
    "w:is_branch_or_jump_pre_2_gold w:is_fence_pre_2_gold w:is_fence_i_pre_2_gold "
    "w:is_sfence_vma_pre_2_gold w:is_csr_imm_pre_2_gold w:has_fp_flags_pre_2_gold "
    "w:needs_lq_pre_2_gold w:needs_sq_pre_2_gold",
    "select -assert-count 8 o:o_from_id_to_ex*",
)

# Each declaration pins both forms, their state cuts and the full point proof.
TWIN_COMPARISONS = {
    ("pd_target_candidate_twin", "pdt_twin"): TwinComparison(
        primitive_points=16,
        all_points=16,
        top="pd_target_candidate",
        gold_inputs=("read -sv -D SYNTHESIS riscv_pkg.sv pd_target_candidate.sv",),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv pd_target_candidate.sv",
        ),
        registers=0,
        clock=None,
    ),
    ("decoded_bundle_queue_twin", "dbq_twin"): TwinComparison(
        primitive_points=3,
        all_points=109,
        top="decoded_bundle_queue",
        gold_inputs=(
            "read -sv -D SYNTHESIS riscv_pkg.sv decoded_bundle_queue.sv",
            DBQ_TWIN_PARAMETERS,
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv decoded_bundle_queue.sv",
            DBQ_TWIN_PARAMETERS,
        ),
        registers=19,
        clock="i_clk",
        paired_free=6,
        name_free=True,
    ),
    ("imem_predecode_twin", "imem_predecode_live"): TwinComparison(
        primitive_points=64,
        all_points=1317,
        top="imem_predecode_boundary",
        gold_inputs=(
            "read -sv -D SYNTHESIS sdp_block_ram_dc_init.sv",
            "read -sv -D SYNTHESIS -D FROST_RANDOM_START -D FROST_VIVADO_SYNTH "
            "imem_predecode_reference.sv imem_predecode_boundary.sv",
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS sdp_block_ram_dc_init.sv",
            "read -sv -D SYNTHESIS -D FROST_RANDOM_START -D FROST_VIVADO_SYNTH "
            "-D IMEM_PREDECODE_CANDIDATE riscv_pkg.sv imem_predecode.sv "
            "imem_predecode_boundary.sv",
        ),
        registers=35,
        clock="i_clk",
        gold_only_free=22,
        gate_only_free=25,
    ),
    l0_store_boundary.PAIR: TwinComparison(
        primitive_points=6,
        all_points=739,
        top="l0_store_boundary",
        gold_inputs=("read -sv -D SYNTHESIS riscv_pkg.sv l0_store_boundary.v",),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS -D L0_STORE_BOUNDARY_PROOF "
            "riscv_pkg.sv l0_store_boundary.sv",
        ),
        registers=12,
        clock="i_clk",
        gold_only_free=6,
        gate_only_free=6,
    ),
    ("cached_tier_adapter_twin", "cached_tier_twin"): TwinComparison(
        primitive_points=64,
        all_points=2515,
        top="cached_tier_adapter",
        gold_inputs=(
            "read -sv -D SYNTHESIS riscv_pkg.sv cached_tier_adapter.sv",
            "chparam -set SPLIT_READ_REQ 1 cached_tier_adapter",
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv cached_tier_adapter.sv",
            "chparam -set SPLIT_READ_REQ 1 cached_tier_adapter",
        ),
        registers=43,
        clock="i_clk",
        gold_only_free=15,
        gate_only_free=15,
    ),
    ("cached_tier_adapter_twin", "cached_tier_unsplit"): TwinComparison(
        primitive_points=64,
        all_points=2515,
        top="cached_tier_adapter",
        gold_inputs=("read -sv -D SYNTHESIS riscv_pkg.sv cached_tier_adapter.sv",),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv cached_tier_adapter.sv",
        ),
        registers=43,
        clock="i_clk",
        gold_only_free=15,
        gate_only_free=15,
    ),
    ("coherent_store_pma_twin", "store_pma_twin_ddr30"): TwinComparison(
        primitive_points=17,
        all_points=235,
        top="coherent_store_pma",
        gold_inputs=(
            "read -sv -D SYNTHESIS -D FROST_DDR_CAPACITY_LOG2_BYTES=30 riscv_pkg.sv tomasulo_wrapper.sv",
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS -D FROST_DDR_CAPACITY_LOG2_BYTES=30 riscv_pkg.sv tomasulo_wrapper.sv",
        ),
        registers=0,
        clock=None,
        gold_only_free=29,
        gate_only_free=29,
    ),
    ("coherent_store_pma_twin", "store_pma_twin_ddr31"): TwinComparison(
        primitive_points=17,
        all_points=235,
        top="coherent_store_pma",
        gold_inputs=(
            "read -sv -D SYNTHESIS -D FROST_DDR_CAPACITY_LOG2_BYTES=31 riscv_pkg.sv tomasulo_wrapper.sv",
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS -D FROST_DDR_CAPACITY_LOG2_BYTES=31 riscv_pkg.sv tomasulo_wrapper.sv",
        ),
        registers=0,
        clock=None,
        gold_only_free=29,
        gate_only_free=29,
    ),
    ("control_flow_tracker_twin", "cft_twin"): TwinComparison(
        primitive_points=1,
        all_points=20,
        top="control_flow_tracker",
        gold_inputs=("read -sv -D SYNTHESIS riscv_pkg.sv control_flow_tracker.sv",),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv control_flow_tracker.sv",
        ),
        registers=4,
        clock="i_clk",
    ),
    ("data_mem_request_router_twin", "router_twin"): TwinComparison(
        primitive_points=1,
        all_points=990,
        top="data_mem_request_router",
        gold_inputs=("read -sv -D SYNTHESIS riscv_pkg.sv data_mem_request_router.sv",),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv data_mem_request_router.sv",
        ),
        registers=16,
        clock="i_clk",
        gold_only_free=15,
        gate_only_free=15,
    ),
    ("immu_twin", "immu_twin"): TwinComparison(
        primitive_points=6,
        all_points=6437,
        top="immu",
        gold_inputs=("read -sv -D SYNTHESIS riscv_pkg.sv dtlb.sv immu.sv",),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv dtlb.sv immu.sv",
        ),
        registers=117,
        clock="i_clk",
        gold_only_free=1402,
        gate_only_free=1402,
    ),
    ("immu_twin", "immu_twin_hold"): TwinComparison(
        primitive_points=12,
        all_points=6443,
        top="immu",
        gold_inputs=(
            "read -sv -D SYNTHESIS riscv_pkg.sv dtlb.sv immu.sv",
            "chparam -set PA_VALID_COPIES 4 -set PA_COPY_HOLD 1 immu",
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv dtlb.sv immu.sv",
            "chparam -set PA_VALID_COPIES 4 -set PA_COPY_HOLD 1 immu",
        ),
        registers=117,
        clock="i_clk",
        gold_only_free=1402,
        gate_only_free=1402,
    ),
    ("pc_controller_twin", "pc_controller_twin"): TwinComparison(
        primitive_points=3708,
        all_points=11638,
        top="pc_controller",
        gold_inputs=(
            "read -sv -D SYNTHESIS riscv_pkg.sv control_flow_tracker.sv "
            "pc_reg_precompute.sv pc_increment_calculator.sv pc_controller.sv",
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv "
            "control_flow_tracker.sv pc_reg_precompute.sv pc_increment_calculator.sv "
            "pc_controller.sv",
        ),
        registers=28,
        clock="i_clk",
        gold_only_free=80,
        gate_only_free=75,
    ),
    ("pc_controller_twin", "pc_controller_twin_slot2"): TwinComparison(
        primitive_points=3708,
        all_points=11638,
        top="pc_controller",
        gold_inputs=(
            "read -sv -D SYNTHESIS riscv_pkg.sv control_flow_tracker.sv "
            "pc_reg_precompute.sv pc_increment_calculator.sv pc_controller.sv",
            "chparam -set PENDING_HANDOFF_EXCLUDES_SLOT2 1 pc_controller",
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv "
            "control_flow_tracker.sv pc_reg_precompute.sv pc_increment_calculator.sv "
            "pc_controller.sv",
            "chparam -set PENDING_HANDOFF_EXCLUDES_SLOT2 1 pc_controller",
        ),
        registers=28,
        clock="i_clk",
        gold_only_free=80,
        gate_only_free=75,
    ),
    ("coherence_home_engine_twin", "home_engine_twin32"): TwinComparison(
        primitive_points=1,
        all_points=2751,
        top="coherence_home_engine",
        gold_inputs=HOME_ENGINE_TWIN_GOLD,
        gate_inputs=HOME_ENGINE_TWIN_GATE,
        registers=16,
        clock="i_clk",
        gold_only_free=144,
        gate_only_free=144,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
    ),
    ("coherence_home_engine_twin", "home_engine_twin64"): TwinComparison(
        primitive_points=1,
        all_points=3295,
        top="coherence_home_engine",
        gold_inputs=(
            *HOME_ENGINE_TWIN_GOLD,
            "chparam -set LINE_BYTES 64 coherence_home_engine",
        ),
        gate_inputs=(
            *HOME_ENGINE_TWIN_GATE,
            "chparam -set LINE_BYTES 64 coherence_home_engine",
        ),
        registers=16,
        clock="i_clk",
        gold_only_free=149,
        gate_only_free=149,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
    ),
    ("coherence_home_engine_twin", "home_engine_twin40"): TwinComparison(
        primitive_points=1,
        all_points=2840,
        top="coherence_home_engine",
        gold_inputs=(
            *HOME_ENGINE_TWIN_GOLD,
            "chparam -set ADDR_WIDTH 40 coherence_home_engine",
        ),
        gate_inputs=(
            *HOME_ENGINE_TWIN_GATE,
            "chparam -set ADDR_WIDTH 40 coherence_home_engine",
        ),
        registers=16,
        clock="i_clk",
        gold_only_free=144,
        gate_only_free=144,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
    ),
    ("coherence_home_twin", "home_twin_small"): TwinComparison(
        primitive_points=4177,
        all_points=61950,
        top="coherence_home",
        gold_inputs=(*HOME_TWIN_GOLD_READS, HOME_TWIN_SMALL_PARAMS),
        gate_inputs=(*HOME_TWIN_GATE_READS, HOME_TWIN_SMALL_PARAMS),
        registers=321,
        clock="i_clk",
        gold_only_free=629,
        gate_only_free=629,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
        initialized_nets=2,
        delete_after_copy=True,
    ),
    ("coherence_home_twin", "home_twin_four"): TwinComparison(
        primitive_points=5261,
        all_points=112256,
        top="coherence_home",
        gold_inputs=(*HOME_TWIN_GOLD_READS, HOME_TWIN_FOUR_PARAMS),
        gate_inputs=(*HOME_TWIN_GATE_READS, HOME_TWIN_FOUR_PARAMS),
        registers=512,
        clock="i_clk",
        gold_only_free=1452,
        gate_only_free=1452,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
        initialized_nets=4,
        delete_after_copy=True,
    ),
    ("coherence_home_twin", "home_twin_addr40"): TwinComparison(
        primitive_points=4177,
        all_points=63954,
        top="coherence_home",
        gold_inputs=(
            *HOME_TWIN_GOLD_READS,
            HOME_TWIN_SMALL_PARAMS,
            "chparam -set ADDR_WIDTH 40 coherence_home",
        ),
        gate_inputs=(
            *HOME_TWIN_GATE_READS,
            HOME_TWIN_SMALL_PARAMS,
            "chparam -set ADDR_WIDTH 40 coherence_home",
        ),
        registers=321,
        clock="i_clk",
        gold_only_free=629,
        gate_only_free=629,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
        initialized_nets=2,
        delete_after_copy=True,
    ),
    ("csr_file_twin", "csr_twin"): TwinComparison(
        primitive_points=2,
        all_points=14717,
        top="csr_file",
        gold_inputs=("read -sv -D SYNTHESIS riscv_pkg.sv csr_file.sv",),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv csr_file.sv",
        ),
        registers=105,
        clock="i_clk",
        gold_only_free=250,
        gate_only_free=250,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
    ),
    ("csr_file_twin", "csr_twin_vector"): TwinComparison(
        primitive_points=2,
        all_points=14949,
        top="csr_file",
        gold_inputs=(
            "read -sv -D SYNTHESIS riscv_pkg.sv csr_file.sv",
            "chparam -set VECTOR 1 -set VLEN 256 csr_file",
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv csr_file.sv",
            "chparam -set VECTOR 1 -set VLEN 256 csr_file",
        ),
        registers=114,
        clock="i_clk",
        gold_only_free=250,
        gate_only_free=250,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
    ),
    ("dmmu_twin", "dmmu_twin"): TwinComparison(
        primitive_points=600,
        all_points=11870,
        top="dmmu",
        gold_inputs=("read -sv -D SYNTHESIS riscv_pkg.sv dtlb.sv dmmu.sv",),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv dtlb.sv dmmu.sv",
        ),
        registers=195,
        clock="i_clk",
        gold_only_free=171,
        gate_only_free=171,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
    ),
    ("fp_engine_twin", "fp_engine_twin"): TwinComparison(
        primitive_points=43,
        all_points=7930,
        top="fp_engine",
        gold_inputs=(
            "read -sv -D SYNTHESIS riscv_pkg.sv dsp_tiled_multiplier_unsigned.sv fp_engine.sv",
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv "
            "dsp_tiled_multiplier_unsigned.sv fp_engine.sv",
        ),
        registers=63,
        clock="i_clk",
        gold_only_free=679,
        gate_only_free=679,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
    ),
    ("store_queue_twin", "sq_twin"): TwinComparison(
        primitive_points=87,
        all_points=9057,
        top="store_queue",
        gold_inputs=(
            "read -sv -D SYNTHESIS riscv_pkg.sv vec_hold_rows.sv sdp_dist_ram.sv "
            "sq_forwarding_unit.sv store_queue.sv",
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv "
            "vec_hold_rows.sv sdp_dist_ram.sv sq_forwarding_unit.sv store_queue.sv",
        ),
        registers=117,
        clock="i_clk",
        gold_only_free=243,
        gate_only_free=243,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
        initialized_nets=16,
    ),
    ("store_queue_twin", "sq_twin_cpu"): TwinComparison(
        primitive_points=87,
        all_points=9066,
        top="store_queue",
        gold_inputs=(
            "read -sv -D SYNTHESIS riscv_pkg.sv vec_hold_rows.sv sdp_dist_ram.sv "
            "sq_forwarding_unit.sv store_queue.sv",
            "chparam -set TRUST_DISPATCH_VALID 1 -set PRECISE_UNCACHED 1 "
            "-set CACHE_NORMAL_MEMORY 1 store_queue",
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv "
            "vec_hold_rows.sv sdp_dist_ram.sv sq_forwarding_unit.sv store_queue.sv",
            "chparam -set TRUST_DISPATCH_VALID 1 -set PRECISE_UNCACHED 1 "
            "-set CACHE_NORMAL_MEMORY 1 store_queue",
        ),
        registers=121,
        clock="i_clk",
        gold_only_free=246,
        gate_only_free=246,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
        initialized_nets=16,
    ),
    ("coherence_l1d_twin", "l1d_twin_single"): TwinComparison(
        primitive_points=9,
        all_points=31351,
        top="coherence_l1d",
        gold_inputs=(
            *L1D_TWIN_GOLD_READS,
            "chparam -set CACHE_BYTES 64 -set WAYS 1 -set TAG_BITS 2 coherence_l1d",
        ),
        gate_inputs=(
            *L1D_TWIN_GATE_READS,
            "chparam -set CACHE_BYTES 64 -set WAYS 1 -set TAG_BITS 2 coherence_l1d",
        ),
        registers=298,
        clock="i_clk",
        paired_free=467,
        gold_only_free=103,
        gate_only_free=103,
        equiv_free=40,
        name_free=True,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
        initialized_nets=4,
    ),
    ("coherence_l1d_twin", "l1d_twin_multi"): TwinComparison(
        primitive_points=12,
        all_points=40268,
        top="coherence_l1d",
        gold_inputs=(
            *L1D_TWIN_GOLD_READS,
            "chparam -set CACHE_BYTES 64 -set WAYS 1 -set TAG_BITS 2 -set MISSES 3 coherence_l1d",
        ),
        gate_inputs=(
            *L1D_TWIN_GATE_READS,
            "chparam -set CACHE_BYTES 64 -set WAYS 1 -set TAG_BITS 2 -set MISSES 3 coherence_l1d",
        ),
        registers=333,
        clock="i_clk",
        paired_free=547,
        gold_only_free=52,
        gate_only_free=52,
        equiv_free=28,
        name_free=True,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
        initialized_nets=4,
    ),
    ("coherence_l1d_twin", "l1d_twin_stream"): TwinComparison(
        primitive_points=14,
        all_points=62326,
        top="coherence_l1d",
        gold_inputs=(
            *L1D_TWIN_GOLD_READS,
            "chparam -set CACHE_BYTES 64 -set WAYS 1 -set TAG_BITS 2 -set MISSES 8 -set STREAM_PREFETCH 1 coherence_l1d",
        ),
        gate_inputs=(
            *L1D_TWIN_GATE_READS,
            "chparam -set CACHE_BYTES 64 -set WAYS 1 -set TAG_BITS 2 -set MISSES 8 -set STREAM_PREFETCH 1 coherence_l1d",
        ),
        registers=432,
        clock="i_clk",
        paired_free=579,
        gold_only_free=56,
        gate_only_free=56,
        equiv_free=3,
        name_free=True,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
        initialized_nets=4,
    ),
    ("reservation_station_twin", "rs_twin_indexed"): TwinComparison(
        primitive_points=2144,
        all_points=32414,
        top="reservation_station",
        gold_inputs=(
            f"read -sv -D SYNTHESIS {RS_TWIN_SOURCES}",
            RS_TWIN_INDEXED_PARAMS,
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            f"read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS {RS_TWIN_SOURCES}",
            RS_TWIN_INDEXED_PARAMS,
        ),
        registers=288,
        clock="i_clk",
        gold_only_free=155,
        gate_only_free=155,
        equiv_free=12,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
        pre_initialized_nets=18,
        initialized_nets=139,
    ),
    ("branch_predictor_twin", "bp_twin"): TwinComparison(
        primitive_points=220,
        all_points=126988,
        top="branch_predictor",
        gold_inputs=(
            "read -sv -D SYNTHESIS riscv_pkg.sv sdp_dist_ram.sv sdp_block_ram.sv "
            "backing_btb.sv branch_predictor.sv direction_predictor.sv "
            "tage_predictor.sv return_address_stack.sv",
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            "read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS riscv_pkg.sv "
            "sdp_dist_ram.sv sdp_block_ram.sv backing_btb.sv branch_predictor.sv "
            "direction_predictor.sv tage_predictor.sv return_address_stack.sv",
        ),
        registers=4882,
        clock="i_clk",
        gold_only_free=60,
        gate_only_free=60,
        equiv_free=4,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
        initialized_nets=3840,
        delete_after_copy=True,
        equiv_struct=True,
    ),
    ("id_stage_kill_equiv", "id_kill_equiv"): TwinComparison(
        primitive_points=None,
        all_points=7375,
        top="id_stage",
        gold_inputs=(ID_KILL_READ, "chparam -set VECTOR 0 id_stage"),
        gate_inputs=(ID_KILL_READ, "chparam -set VECTOR 0 id_stage"),
        registers=2,
        clock="i_clk",
        paired_free=1032,
        gold_only_free=198,
        gate_only_free=198,
        name_free=True,
        hide_wires=ID_KILL_HIDE_WIRES,
        clean_hidden=True,
        opt_clean_purge=True,
        gold_post_open=ID_KILL_GOLD_POST_OPEN,
        equiv_extra_checks=ID_KILL_EXTRA_CHECKS,
    ),
    ("id_stage_kill_equiv", "id_kill_equiv_vector"): TwinComparison(
        primitive_points=None,
        all_points=7375,
        top="id_stage",
        gold_inputs=(ID_KILL_READ, "chparam -set VECTOR 1 id_stage"),
        gate_inputs=(ID_KILL_READ, "chparam -set VECTOR 1 id_stage"),
        registers=2,
        clock="i_clk",
        paired_free=1126,
        gold_only_free=226,
        gate_only_free=226,
        name_free=True,
        hide_wires=ID_KILL_HIDE_WIRES,
        clean_hidden=True,
        opt_clean_purge=True,
        gold_post_open=ID_KILL_GOLD_POST_OPEN,
        equiv_extra_checks=ID_KILL_EXTRA_CHECKS,
    ),
    ("rs_issue_tag_banks", "int_equiv"): TwinComparison(
        primitive_points=None,
        all_points=44316,
        top="reservation_station",
        gold_inputs=(f"read -sv -D SYNTHESIS {RS_TWIN_SOURCES}", RS_BANKS_GOLD_PARAMS),
        gate_inputs=(f"read -sv -D SYNTHESIS {RS_TWIN_SOURCES}", RS_BANKS_GATE_PARAMS),
        registers=388,
        clock="i_clk",
        gold_only_free=271,
        gate_only_free=271,
        equiv_free=15,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
        pre_initialized_nets=34,
        initialized_nets=181,
        equiv_struct=True,
        gold_post_flatten=(
            "delete reservation_station/w:i_issue_cdb_tag_bank "
            "reservation_station/w:i_issue_cdb_2_tag_bank",
        ),
        gate_post_flatten=(
            "cd reservation_station",
            "delete -port w:i_issue_cdb_tag_bank w:i_issue_cdb_2_tag_bank",
            "connect -nounset -set i_issue_cdb_tag_bank "
            "i_issue_cdb_tag,i_issue_cdb_tag,i_issue_cdb_tag,i_issue_cdb_tag",
            "connect -nounset -set i_issue_cdb_2_tag_bank "
            "i_issue_cdb_2_tag,i_issue_cdb_2_tag,i_issue_cdb_2_tag,i_issue_cdb_2_tag",
            "cd ..",
        ),
        post_cut_checks=RS_BANKS_SAT,
    ),
    ("rs_issue_tag_banks", "int_equiv_prims"): TwinComparison(
        primitive_points=None,
        all_points=48956,
        top="reservation_station",
        gold_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            f"read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS {RS_TWIN_SOURCES}",
            RS_BANKS_GOLD_PARAMS,
        ),
        gate_inputs=(
            "read_verilog -formal +/xilinx/cells_sim.v",
            f"read -sv -D SYNTHESIS -D FROST_XILINX_PRIMS {RS_TWIN_SOURCES}",
            RS_BANKS_GATE_PARAMS,
        ),
        registers=388,
        clock="i_clk",
        gold_only_free=271,
        gate_only_free=271,
        equiv_free=15,
        hide_wires=HIDE_FUNC_AND_LOOP_TEMPS,
        clean_hidden=True,
        pre_initialized_nets=34,
        initialized_nets=181,
        equiv_struct=True,
        gold_post_flatten=(
            "delete reservation_station/w:i_issue_cdb_tag_bank "
            "reservation_station/w:i_issue_cdb_2_tag_bank",
        ),
        gate_post_flatten=(
            "cd reservation_station",
            "delete -port w:i_issue_cdb_tag_bank w:i_issue_cdb_2_tag_bank",
            "connect -nounset -set i_issue_cdb_tag_bank "
            "i_issue_cdb_tag,i_issue_cdb_tag,i_issue_cdb_tag,i_issue_cdb_tag",
            "connect -nounset -set i_issue_cdb_2_tag_bank "
            "i_issue_cdb_2_tag,i_issue_cdb_2_tag,i_issue_cdb_2_tag,i_issue_cdb_2_tag",
            "cd ..",
        ),
        post_cut_checks=RS_BANKS_SAT,
    ),
}


# The registered proofs require no native $isunknown operand exemptions.
HIGH_IMPEDANCE_PENDING: tuple[PredicateExemption, ...] = ()


# These tasks prove SystemVerilog assertions over two stashed instances.
# Each identity includes the harness's guards and predicates, the complete
# preparation and check selections, and the mapping of staged source files.
PREDICTOR_ASSERTION_TASKS = {
    (target, task): (sources, identity, depth)
    for target, sources, identity, depths in (
        (
            "backing_btb_twin",
            ("backing_btb_twin.sv",),
            "3cacf9d4afa13311be049f7f63f15a2151e1ae01d7d51dc96f6020ffad85152e",
            (5, 2, 5),
        ),
        (
            "pd_history_twin",
            ("pd_history_twin.sv", "predictor_fetch_contract.sv"),
            "829871a49e6eff8f602c4c23d19e9bdbb0f881366ece942162ee506a5feee49d",
            (12, 3, 7),
        ),
        (
            "tage_predictor_twin",
            ("predictor_table_twin.sv",),
            "f2ea5071b8098c7c6598927c705b0f9a0418ecb12e2aca8188fe2b5f12a4418b",
            (5, 2, 5),
        ),
        (
            "ittage_predictor_twin",
            ("predictor_table_twin.sv",),
            "a2f9520e9c188a50ebcab346bb6b9e1f812f939080ac37b1fd437d1acaf7d0f6",
            (5, 2, 5),
        ),
    )
    for task, depth in zip(("bmc", "prove", "cover"), depths, strict=True)
}


def check_predictor_assertion_task(
    target: str,
    task: str,
    directory: Path,
    cfg: sby_config.TaskConfig,
    commands: list[str],
) -> None:
    """Require the registered checks and the projection for this assertion task."""
    sources, expected, depth = PREDICTOR_ASSERTION_TASKS[target, task]
    projection = (
        "chformal -assert -remove" if task == "cover" else "chformal -cover -remove"
    )
    if cfg.options != {"mode": task, "depth": str(depth)} or cfg.engines != [
        ["smtbmc", "boolector"]
    ]:
        raise sby_config.ConfigError(
            f"{target}:{task}: wrong assertion-harness options or engine"
        )
    if not commands or commands[-1] != projection:
        raise sby_config.ConfigError(
            f"{target}:{task}: wrong assertion-harness mode or projection"
        )
    if any(name not in cfg.files or name in cfg.inline_files for name in sources):
        raise sby_config.ConfigError(
            f"{target}:{task}: missing registered assertion-harness source"
        )
    body = [harness_tokens(directory / cfg.files[name]) for name in sources]
    identity = json.dumps(
        [commands[:-1], sorted(cfg.files.items()), body], separators=(",", ":")
    )
    if hashlib.sha256(identity.encode("ascii")).hexdigest() != expected:
        raise sby_config.ConfigError(
            f"{target}:{task}: assertion-harness check identity changed"
        )


def checked_predicate_exemptions(
    target: str,
    task: str,
    directory: Path,
    cfg: sby_config.TaskConfig,
    parsed: list[sby_config.ParsedCommand],
) -> tuple[PredicateExemption, ...]:
    """Validate this task's keys against its declared sources before staging."""
    entries = tuple(e for e in HIGH_IMPEDANCE_PENDING if (target, task) in e.tasks)
    if not entries:
        return ()
    if (target, task) in TWIN_COMPARISONS or any(
        c.args[0] == "equiv_make" for c in parsed
    ):
        raise sby_config.ConfigError(
            f"{target}:{task}: high-impedance exemptions are forbidden for in-script comparisons"
        )
    for entry in entries:
        name = Path(entry.source).name
        if cfg.files.get(name) != entry.source or name in cfg.inline_files:
            raise sby_config.ConfigError(
                f"{target}:{task}: expected one staged predicate source {entry.source}"
            )
    resolve_predicate_sites(directory, entries)
    return entries


def twin_form_commands(spec: TwinComparison, form: str) -> list[str]:
    """Prepare one full design and check its initial state and clock before cutting it."""
    gate = form == "gate"
    inputs = spec.gate_inputs if gate else spec.gold_inputs
    for line in inputs:
        form_id = sby_config.match_command_form(line.split()).id
        if form_id not in (
            "read_sources",
            "read_verilog",
            "read_slang",
            "read_define",
            "verilog_defines",
            "chparam",
        ):
            raise sby_config.ConfigError(
                f"{form} form input declaration cannot run {line!r}"
            )
    commands = ["design -reset", *inputs] if gate else list(inputs)
    commands.extend(
        [
            f"hierarchy -check -top {spec.top}",
            "script free_undefined.ys",
        ]
    )
    if spec.pre_initialized_nets:
        commands.extend(
            [
                "select -assert-none t:$initstate t:$anyinit",
                f"select -assert-count {spec.pre_initialized_nets} a:init",
            ]
        )
    else:
        commands.append("select -assert-none a:init t:$initstate t:$anyinit")
    if not gate and spec.gold_post_open:
        commands.extend(spec.gold_post_open)
    commands.append("setattr -mod -unset keep_hierarchy *")
    if gate and spec.primitive_points is not None:
        commands.append(
            "setattr -set from_prim 1 $paramod*LUT*/* $paramod*MUXF*/* "
            "$paramod*CARRY*/* $paramod*FD*/* LUT*/* MUXF*/* CARRY*/* FD*/*"
        )
    commands.append("flatten")
    post_flatten = spec.gate_post_flatten if gate else spec.gold_post_flatten
    if post_flatten:
        commands.extend(post_flatten)
    commands.extend(
        [
            "memory_map -keepdc",
            "dffunmap",
            "setundef -undriven -anyseq",
        ]
    )
    clean_cmd = "opt_clean -purge" if spec.opt_clean_purge else "opt_clean"
    if spec.hide_wires:
        commands.append(f"rename -hide {' '.join(spec.hide_wires)}")
        if spec.clean_hidden:
            commands.append(clean_cmd)
    commands.extend(
        [
            "setattr -set keep 1 w:* w:$* %d",
            clean_cmd,
            "check -assert",
        ]
    )
    if spec.initialized_nets:
        commands.extend(
            [
                "select -assert-none t:$initstate t:$anyinit t:$anyconst t:$allseq t:$allconst t:$sr t:$*latch* t:$*ff* t:$dff %d",
                f"select -assert-count {spec.initialized_nets} a:init",
            ]
        )
    else:
        commands.append(
            "select -assert-none a:init t:$initstate t:$anyinit t:$anyconst t:$allseq t:$allconst t:$sr t:$*latch* t:$*ff* t:$dff %d"
        )
    commands.extend(
        [
            "select -assert-none i:* o:* %i",
            f"select -assert-count {spec.registers} t:$dff",
        ]
    )
    if spec.clock is not None:
        commands.append(f"select -assert-none t:$dff i:{spec.clock} %co1:+$dff[CLK] %d")
    free = spec.paired_free + (spec.gate_only_free if gate else spec.gold_only_free)
    commands.extend(
        [
            f"expose -dff -cut {spec.top}/w:*",
            f"select -assert-none {spec.top}/t:$dff %co:+[Q] {spec.top}/w:* %i %co1 {spec.top}/t:* %i",
            f"select -assert-count {free} t:$anyseq",
        ]
    )
    if spec.name_free:
        commands.append("autoname t:$anyseq")
    if spec.post_cut_checks:
        commands.extend(spec.post_cut_checks)
    return [*commands, f"rename -top {form}", f"design -stash {form}"]


def check_twin_forms(
    target: str, task: str, commands: list[str], spec: TwinComparison
) -> None:
    """Both stashes must contain the specified forms with their checks in order."""
    if (
        spec.registers < 0
        or (spec.registers == 0) != (spec.clock is None)
        or (spec.clock is not None and not sby_config.IDENT.fullmatch(spec.clock))
    ):
        raise sby_config.ConfigError(
            f"{target}:{task}: declare one scalar clock input for a positive register count "
            "or no clock for zero registers"
        )
    actual = iter(commands)
    for form in ("gold", "gate"):
        arm = []
        for command in actual:
            if command.startswith("setattr ") and re.search(
                r" -(?:un)?set init(?: |$)", command
            ):
                raise sby_config.ConfigError(
                    f"{target}:{task}: {form} form cannot change initial values with {command!r}"
                )
            arm.append(command)
            if command == f"design -stash {form}":
                break
        for expected, command in zip_longest(twin_form_commands(spec, form), arm):
            if command != expected:
                raise sby_config.ConfigError(
                    f"{target}:{task}: {form} form expected {expected!r}, got {command!r}"
                )
    trailing = next(actual, None)
    if trailing is not None:
        raise sby_config.ConfigError(
            f"{target}:{task}: unexpected command after gate stash: {trailing}"
        )


FORMAL_DEFINE_TASKS = frozenset(
    f"{target.name}:{task}" for target in FORMAL_TARGETS for task in target.tasks
)


def check_formal_input_contract(
    target: str,
    task: str,
    directory: Path,
    cfg: sby_config.TaskConfig,
    *,
    expanded: list[sby_config.ParsedCommand] | None = None,
    define_declarations: dict[str, tuple[str, ...]] | None = None,
) -> tuple[bool, tuple[PredicateExemption, ...]]:
    """Check the task's input contract and return its compiled requirements."""
    if expanded is None:
        expanded = cfg.parsed(directory, keep_script_entries=True)
    # The elaboration and twin contracts treat the opening as a single command.
    parsed = [
        command
        for command in expanded
        if UNDEFINED_OPENING_FILE not in command.included_from
        and (command.form.id != "script" or command.args[1] == UNDEFINED_OPENING_FILE)
    ]
    requirements = formal_input_requirements(target, task, directory, cfg, parsed)
    case = f"{target}:{task}"
    if case in FORMAL_DEFINE_TASKS:
        if define_declarations is None:
            define_declarations = sby_config.read_define_inputs(
                Path(__file__).resolve().parents[1]
            )
        if case not in define_declarations:
            raise sby_config.ConfigError(f"{case}: missing define input declaration")
        actual = sby_config.define_inputs(expanded)
        expected = define_declarations[case]
        for claimed, observed in zip_longest(expected, actual):
            if claimed != observed:
                raise sby_config.ConfigError(
                    f"{case}: define inputs differ, expected {claimed!r}, observed {observed!r}"
                )
    return requirements


def formal_input_requirements(
    target: str,
    task: str,
    directory: Path,
    cfg: sby_config.TaskConfig,
    parsed: list[sby_config.ParsedCommand],
) -> tuple[bool, tuple[PredicateExemption, ...]]:
    """Check elaboration and return port requirements and predicate keys."""
    entries = checked_predicate_exemptions(target, task, directory, cfg, parsed)
    pending: str | None = None
    for cmd in parsed:
        if cmd.form.id in ("hierarchy_top", "hierarchy_chparam", "prep"):
            pending = None
        elif cmd.form.transition == "source":
            pending = " ".join(cmd.args)
        elif pending and cmd.form.transition not in (
            "define",
            "design_copy_from",
            "design_delete",
        ):
            # A partition can omit properties or remove named modules/instances
            # before elaboration. Neither operation assigns a value to a retained net.
            if cmd.form.id == "chformal_remove" or (
                cmd.form.id == "delete"
                and all(
                    re.fullmatch(r"(?:t:)?[a-zA-Z_][a-zA-Z0-9_]*", arg)
                    for arg in cmd.args[1:]
                )
            ):
                continue
            raise sby_config.ConfigError(
                f"{target}:{task}: {pending} requires hierarchy -top or prep -top "
                f"before {' '.join(cmd.args)}"
            )
    if pending:
        raise sby_config.ConfigError(
            f"{target}:{task}: missing elaboration after {pending}"
        )

    commands = [" ".join(cmd.args) for cmd in parsed]
    if (target, task) in PREDICTOR_ASSERTION_TASKS:
        check_predictor_assertion_task(target, task, directory, cfg, commands)
        return False, entries
    declaration = TWIN_COMPARISONS.get((target, task))
    if declaration is None:
        # rs_payload_twin uses a bounded two-instance assertion harness.
        # A new *_twin script still needs a declaration if its entire point
        # proof was accidentally omitted. Detect paired stashes under other
        # names too. The unopened SQ forwarding harness predates this rule.
        named_twin = target.endswith("_twin") and target != "rs_payload_twin"
        copies = {
            cmd.args[cmd.args.index("-copy-from") + 1]
            for cmd in parsed
            if cmd.form.id == "design_copy_from"
        }
        sq_tree = (
            (target, task) == ("sq_forwarding_unit", "tree_equiv")
            and copies == {"shipped", "formal_sel"}
            and "script free_undefined.ys" in commands
        )
        if (
            not named_twin
            and (len(copies) < 2 or sq_tree)
            and not any(
                cmd.args[0].startswith("equiv_") or "prim_twin_done.sv" in cmd.args
                for cmd in parsed
            )
        ):
            return False, entries
        if (
            task in UNDEFINED_OPENING_TWINS.get(target, ())
            and "script free_undefined.ys" not in commands
        ):
            return False, entries
        raise sby_config.ConfigError(
            f"{target}:{task}: missing twin comparison declaration for all points and compiled ports"
        )

    # Make the ports and the points come from the same, fully selected pair.
    wrapper = [
        "design -reset",
        "read -sv twin_both.sv",
        "design -copy-from gold -as gold gold",
        *(["design -delete gold"] if declaration.delete_after_copy else []),
        "design -copy-from gate -as gate gate",
        *(["design -delete gate"] if declaration.delete_after_copy else []),
        "hierarchy -top twin_both",
        "script free_undefined.ys",
        "write_json twin_ports.json",
        "equiv_make gold gate equiv",
        "delete gold gate twin_both",
        "setundef -anyseq",
        "select -assert-none i:*_gold i:*_gate o:*_gold o:*_gate",
    ]
    proof = [
        *declaration.equiv_extra_checks,
        *(
            [
                "select -set prim t:* a:from_prim %i",
                "select -set blk @prim %co*:-$equiv[Y] t:$equiv %i",
                f"select -assert-min {declaration.primitive_points} @blk",
            ]
            if declaration.primitive_points is not None
            else []
        ),
        f"select -assert-min {declaration.all_points} t:$equiv",
        *(["equiv_struct -icells"] if declaration.equiv_struct else []),
        "equiv_simple",
        "equiv_status -assert",
        "design -reset",
        "read -formal -sv prim_twin_done.sv",
        "hierarchy -top prim_twin_done",
        "script free_undefined.ys",
        "prep -top prim_twin_done",
    ]
    if declaration.primitive_points is not None:
        if not 0 < declaration.primitive_points <= declaration.all_points:
            raise sby_config.ConfigError(
                f"{target}:{task}: invalid comparison point floors"
            )
    elif declaration.all_points <= 0:
        raise sby_config.ConfigError(
            f"{target}:{task}: invalid comparison point floors"
        )
    if [cmd.args for cmd in parsed if cmd.args[0] == "equiv_make"] != [
        ("equiv_make", "gold", "gate", "equiv")
    ]:
        raise sby_config.ConfigError(
            f"{target}:{task}: expected one gold/gate comparison"
        )
    start = commands.index("equiv_make gold gate equiv") - wrapper.index(
        "equiv_make gold gate equiv"
    )
    if start < 0 or commands[start : start + len(wrapper)] != wrapper:
        raise sby_config.ConfigError(
            f"{target}:{task}: expected compiled twin_ports.json from the opened gold/gate comparison"
        )
    opening_errors = undefined_opening_file_gaps(directory, cfg)
    if opening_errors:
        raise sby_config.ConfigError(f"{target}:{task}: {opening_errors[0]}")
    check_twin_forms(target, task, commands[:start], declaration)
    census = parsed[start + len(wrapper) : len(parsed) - len(proof)]
    if (
        not all(
            cmd.form.id in ("select_assert_count", "select_assert_none")
            for cmd in census
        )
        or commands[-len(proof) :] != proof
    ):
        raise sby_config.ConfigError(
            f"{target}:{task}: expected both declared floors and an unselected proof of all comparison points"
        )
    return True, entries


def test_registered_formal_input_contracts() -> None:
    """Discover comparisons from the registered scripts, including new task names."""
    root = Path(__file__).resolve().parents[1]
    formal = root / FORMAL_DIR
    define_declarations = sby_config.read_define_inputs(root)
    checked = set()
    assertion_tasks = set()
    pending = set()
    for target in FORMAL_TARGETS:
        src = sby_config.source(formal / target.sby_file)
        for task in target.tasks:
            twin, entries = check_formal_input_contract(
                target.name,
                task,
                formal,
                src.task(task),
                define_declarations=define_declarations,
            )
            if twin:
                checked.add((target.name, task))
            if (target.name, task) in PREDICTOR_ASSERTION_TASKS:
                assertion_tasks.add((target.name, task))
            if entries:
                pending.add((target.name, task))
    assert checked == set(TWIN_COMPARISONS)
    assert assertion_tasks == PREDICTOR_ASSERTION_TASKS.keys()
    assert pending == {pair for entry in HIGH_IMPEDANCE_PENDING for pair in entry.tasks}
    assert not HIGH_IMPEDANCE_PENDING, (
        "registered proofs require an empty predicate exemption list"
    )


def test_formal_define_input_membership() -> None:
    """Every registered task has one declaration, including empty input lists."""
    declared = sby_config.read_define_inputs(Path(__file__).resolve().parents[1])
    missing = FORMAL_DEFINE_TASKS - declared.keys()
    stale = declared.keys() - FORMAL_DEFINE_TASKS
    assert not (missing or stale), {"missing": sorted(missing), "stale": sorted(stale)}


def test_formal_define_inputs_preserve_read_scope(tmp_path: Path) -> None:
    """Resolve tags and includes while keeping persistent and read-local inputs."""
    config = sby_config.read_source(
        Path("sample.sby"),
        "[tasks]\nbmc\nother alternate\n[script]\n"
        "script macros.ys\n"
        "read -formal -sv top.sv\n"
        "alternate: verilog_defines -DWIDTH=8\n"
        "read_verilog -sv -D LOCAL=ReadOp top.sv\n"
        "design -reset\n"
        "read_slang --top top --single-unit -DLOCAL=0 top.sv\n"
        "[files]\ntop.sv\n[file macros.ys]\n"
        "read -define PERSISTENT\n"
        "verilog_defines -D WIDTH=0 -D FLAG\n",
    )
    ordinary = sby_config.define_inputs(config.task("bmc").parsed(tmp_path))
    assert ordinary == (
        "design 0 before read 1: read -define PERSISTENT",
        "design 0 before read 1: verilog_defines -DWIDTH=0 -DFLAG",
        "design 0 read 1: read -formal -sv top.sv",
        "design 0 read 2: read_verilog -sv -DLOCAL=ReadOp top.sv",
        "design 1 read 3: read_slang -DLOCAL=0 top.sv",
    )
    alternate = sby_config.define_inputs(config.task("other").parsed(tmp_path))
    assert alternate == (
        *ordinary[:3],
        "design 0 before read 2: verilog_defines -DWIDTH=8",
        *ordinary[3:],
    )


def test_pm_mode_select_ddr36_define_value(tmp_path: Path) -> None:
    """Reject an aperture override that disagrees with the registered value."""
    runner = FormalRunner()
    target = next(
        target for target in FORMAL_TARGETS if target.name == "pm_mode_select"
    )
    task = "bmc_ddr36"
    staged = sby_config.stage_proof(
        runner.formal_dir / target.sby_file, runner.root_dir, tmp_path
    )
    runner.formal_dir = staged.parent
    check_formal_input_contract(
        target.name, task, staged.parent, sby_config.source(staged).task(task)
    )
    original = "FROST_DDR_CAPACITY_LOG2_BYTES=36"
    text = staged.read_text()
    assert text.count(original) == 1
    staged.write_text(text.replace(original, "FROST_DDR_CAPACITY_LOG2_BYTES=35"))
    with pytest.raises(
        sby_config.ConfigError,
        match=r"pm_mode_select:bmc_ddr36: define inputs differ.*BYTES=36.*BYTES=35",
    ):
        runner.run_formal(target, task)


@pytest.mark.parametrize(("target", "task"), TWIN_COMPARISONS)
def test_opened_primitive_twin_comparison(target: str, task: str) -> None:
    """Check each declared task's budget and measured free-cell pairing."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    cfg = sby_config.source(formal / f"{target}.sby").task(task)
    assert int(cfg.options["timeout"]) == formal_task_timeout_s(target, task)
    needs_ports, _ = check_formal_input_contract(target, task, formal, cfg)
    assert needs_ports
    spec = TWIN_COMPARISONS[target, task]
    script = [" ".join(c.args) for c in cfg.parsed(formal, expand_opening=False)]
    start = script.index("select -assert-none i:*_gold i:*_gate o:*_gold o:*_gate") + 1
    end_marker = (
        spec.equiv_extra_checks[0]
        if spec.equiv_extra_checks
        else "select -set prim t:* a:from_prim %i"
        if spec.primitive_points is not None
        else f"select -assert-min {spec.all_points} t:$equiv"
    )
    count = (
        spec.paired_free + spec.gold_only_free + spec.gate_only_free + spec.equiv_free
    )
    expected = [f"select -assert-count {count} t:$anyseq"]
    if spec.gold_only_free or spec.gate_only_free:
        expected.extend(
            [
                f"select -assert-count {spec.gold_only_free} t:$anyseq n:*_gold %i",
                f"select -assert-count {spec.gate_only_free} t:$anyseq n:*_gate %i",
            ]
        )
    else:
        expected.append(
            "select -assert-none t:$anyseq n:*_gold %i t:$anyseq n:*_gate %i"
        )
    assert script[start : script.index(end_marker)] == expected


def script_write_gaps(sby_path: Path, cfg: sby_config.TaskConfig) -> list[str]:
    """Return file-write violations in a task's parsed commands."""
    try:
        parsed = cfg.parsed(sby_path.parent, expand_opening=False)
    except sby_config.ConfigError as error:
        return [str(error)]
    gaps: list[str] = []
    copied = set(cfg.files) | set(cfg.inline_files)
    for index, cmd in enumerate(parsed):
        if not cmd.form.writes_file:
            continue
        assert cmd.form.id in SCRIPT_FILE_WRITES and len(cmd.args) == 2
        text = " ".join(cmd.args)
        target = cmd.args[1]
        match = re.fullmatch(r"(\.\./model/)?([A-Za-z0-9_][A-Za-z0-9_.-]*)", target)
        named = {
            word
            for other, item in enumerate(parsed)
            if other != index
            for word in item.args[1:]
        }
        if (
            not match
            or (match[1] and match[2].startswith("design"))
            or (not match[1] and match[2] in copied)
            or target in named
            or match[2] in named
        ):
            gaps.append(f"{text}: writes a file the task reads or SymbiYosys owns")
    return gaps


@dataclass
class DesignState:
    """Opening and scope state of one Yosys design."""

    opened: bool = False
    early: bool = False
    after_async: bool = False
    scoped: bool = False
    slang_top: str | None = None
    elaborated: str | None = None
    top: str | None = None


def undefined_opening_gaps(
    commands: list[sby_config.ParsedCommand] | list[list[str]],
) -> list[str]:
    """Return what keeps a task's commands from opening as required, in order."""
    parsed: list[sby_config.ParsedCommand] = []
    for entry in commands:
        if isinstance(entry, sby_config.ParsedCommand):
            parsed.append(entry)
        else:
            try:
                parsed.append(
                    sby_config.ParsedCommand(
                        tuple(entry), sby_config.match_command_form(entry)
                    )
                )
            except sby_config.ConfigError as error:
                return [str(error)]

    gaps: list[str] = []
    openings = 0
    current = DesignState()
    saved: dict[str, DesignState] = {}

    for cmd in parsed:
        args = cmd.args
        text = " ".join(args)
        transition = cmd.form.transition

        if current.after_async:
            if transition == "free_async" and not current.scoped:
                current.after_async = False
            else:
                gaps.append(f"{text}: acts on what async2sync writes")
                current.after_async = False

        if transition == "open":
            if args != tuple(UNDEFINED_OPENING_MARK):
                gaps.append(f"{text}: expected script {UNDEFINED_OPENING_FILE}")
                continue
            if current.scoped:
                gaps.append(f"{text}: the opening runs on a selection, not the design")
            if not current.opened:
                if current.elaborated is None:
                    gaps.append(f"{text}: no hierarchy -top after the last source")
                current.opened = True
                current.top = current.elaborated
                openings += 1
        elif transition == "define":
            current.opened = False
            current.early = False
            current.elaborated = None
        elif transition == "source":
            current.opened = False
            current.early = False
            current.elaborated = None
            if cmd.form.id == "read_slang":
                slang_top = args[args.index("--top") + 1]
                if current.slang_top not in (None, slang_top):
                    gaps.append(
                        f"{text}: top does not match read_slang --top {current.slang_top!r}"
                    )
                current.slang_top = slang_top
        elif transition == "elaborate":
            top_arg = args[args.index("-top") + 1]
            if current.slang_top not in (None, top_arg):
                gaps.append(
                    f"{text}: top does not match read_slang --top {current.slang_top!r}"
                )
            if not current.opened:
                if current.top not in (None, top_arg):
                    gaps.append(f"{text}: another top after the opening")
                current.elaborated = top_arg
            elif top_arg != current.top:
                gaps.append(f"{text}: another top after the opening")
        elif transition == "scope_module":
            current.scoped = True
        elif transition == "scope_clear":
            current.scoped = False
        elif transition == "rename_top":
            new_top = args[args.index("-top") + 1]
            if not current.opened and current.elaborated is None:
                gaps.append(f"{text}: renames top before hierarchy -top")
            if current.opened:
                current.top = new_top
            if current.elaborated is not None:
                current.elaborated = new_top
            if current.slang_top is not None:
                current.slang_top = new_top
        elif transition == "passive":
            pass
        elif transition == "design_save":
            slot = args[2]
            if not current.opened:
                gaps.append(f"{text}: the source design has no opening")
            saved[slot] = replace(current)
        elif transition == "design_stash":
            slot = args[2]
            if not current.opened:
                gaps.append(f"{text}: the source design has no opening")
            saved[slot] = replace(current)
            current = DesignState()
        elif transition == "design_load":
            slot = args[2]
            if slot not in saved or not saved[slot].opened:
                gaps.append(f"{text}: saved design {slot!r} has no opening")
            current = (
                replace(saved[slot]) if slot in saved else DesignState(scoped=True)
            )
        elif transition == "design_reset":
            current = DesignState()
        elif transition == "design_delete":
            saved.pop(args[2], None)
        elif transition == "design_copy_from":
            slot = args[args.index("-copy-from") + 1]
            if slot not in saved or not saved[slot].opened:
                gaps.append(f"{text}: saved design {slot!r} has no opening")
            current.opened = False
            current.early = False
            current.elaborated = None
        elif transition == "techmap_map":
            if not current.opened:
                if not current.early:
                    gaps.append(f"{text}: acts before the opening")
                current.early = True
            slot = args[args.index("-map") + 1][1:]
            if slot not in saved or not saved[slot].opened:
                gaps.append(f"{text}: map '%{slot}' has no saved opening")
        elif transition == "prep":
            if not current.opened:
                if not current.early:
                    gaps.append(f"{text}: acts before the opening")
                current.early = True
            else:
                top_arg = args[args.index("-top") + 1]
                if top_arg != current.top:
                    gaps.append(f"{text}: another top after the opening")
        elif transition == "async":
            if not current.opened:
                if not current.early:
                    gaps.append(f"{text}: acts before the opening")
                current.early = True
            else:
                current.after_async = True
        elif transition in ("free_async", "act"):
            if not current.opened:
                if not current.early:
                    gaps.append(f"{text}: acts before the opening")
                current.early = True
        else:
            raise AssertionError(f"unhandled form transition: {transition}")

    if not openings:
        gaps.append("no opening")
    elif not current.opened:
        gaps.append("the final design has no opening")
    if current.after_async:
        gaps.append("async2sync without setundef -anyseq")
    return gaps


def sby_tag_gaps(sby_path: Path) -> list[str]:
    """Return syntax that cannot be read identically by all proof tools."""
    try:
        sby_config.source(sby_path)
    except sby_config.ConfigError as error:
        return [str(error)]
    return []


def undefined_opening_file_gaps(
    directory: Path, cfg: sby_config.TaskConfig
) -> list[str]:
    """Check the named opening against the file SymbiYosys gives this task."""
    name = UNDEFINED_OPENING_FILE
    if name in cfg.inline_files:
        return [f"[file {name}]: the opening's file is written in the script"]
    if cfg.files.get(name) != name:
        return [
            f"[files]: expected the single entry {name}, got {cfg.files.get(name)!r}"
        ]
    copy = directory / name
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    if not copy.is_file() or copy.read_bytes() != (formal / name).read_bytes():
        return [f"{copy}: not the repository's {name}"]
    return []


def sby_undefined_opening_gaps(sby_path: Path) -> dict[str, list[str]]:
    """Return each task's opening gaps on its resolved SymbiYosys configuration."""
    try:
        configs = sby_config.resolved(sby_path)
    except sby_config.ConfigError as error:
        return {"-": [str(error)]}
    result = {}
    for task, cfg in configs.items():
        pre_named = (
            UNDEFINED_OPENING_FILE in cfg.files
            or UNDEFINED_OPENING_FILE in cfg.inline_files
        )
        gaps = undefined_opening_file_gaps(sby_path.parent, cfg) if pre_named else []
        try:
            parsed = cfg.parsed(sby_path.parent, expand_opening=False)
        except sby_config.ConfigError as error:
            result[task or "-"] = [*gaps, str(error)]
            continue
        if not pre_named and any(
            cmd.args == tuple(UNDEFINED_OPENING_MARK) for cmd in parsed
        ):
            gaps = undefined_opening_file_gaps(sby_path.parent, cfg)
        gaps += undefined_opening_gaps(parsed)
        gaps += script_write_gaps(sby_path, cfg)
        if gaps:
            result[task or "-"] = gaps
    return result


def test_scripts_write_no_task_file() -> None:
    """No task of any script, pending ones too, writes a file outside its list."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    sby_config.resolve_files(formal.glob("*.sby"))
    found = [
        f"{path.name} {task}: {gap}"
        for path in sorted(formal.glob("*.sby"))
        for task, cfg in sby_config.resolved(path).items()
        for gap in script_write_gaps(path, cfg)
    ]
    assert found == []


# A file a command writes while the task runs, with the reviewed cases first
# (the opening's file rewritten by tee, a copied source overwritten, the
# opening's file emptied by select -write, test_cell -vlog), then other writing
# forms; each must fail the check. The controls are the forms scripts on main use.
SCRIPT_WRITE_CASES: list[tuple[str, str]] = [
    (
        "flag",
        "tee -q -o free_undefined.ys log proc\ntee -q -a free_undefined.ys log setundef -zero\n",
    ),
    ("flag", "tee -q -o top.sv log //\n"),
    ("flag", "select -none\nselect -write free_undefined.ys\nselect -clear\n"),
    ("flag", "select -none -write free_undefined.ys\nselect -clear\n"),
    ("flag", "test_cell -s 1 -n 1 -noeval -nosat -vlog top.sv $not\n"),
    ("flag", "write_rtlil free_undefined.ys\n"),
    ("flag", "write_json top.sv\n"),
    ("flag", "write_verilog out.v\n"),
    ("flag", "write_file -a free_undefined.ys\n"),
    ("flag", "dump -o free_undefined.ys\n"),
    ("flag", "sat -dump_vcd trace.vcd -prove-asserts\n"),
    ("flag", "write_json -selected model.json\n"),
    ("flag", "write_json ../top.sv\n"),
    ("flag", "write_rtlil ../model/design.il\n"),
    ("flag", "write_json model.json\nread_json model.json\n"),
    ("flag", "tee -q -o run.log stat\n"),
    ("accept", "write_json prepared_model.json\n"),
    ("accept", "write_rtlil ../model/unpartitioned.il\n"),
]


@pytest.mark.parametrize("expect,commands", SCRIPT_WRITE_CASES)
def test_script_write_gaps(tmp_path: Path, expect: str, commands: str) -> None:
    """A task writes a file only in a listed form and never one it reads."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    (tmp_path / UNDEFINED_OPENING_FILE).write_bytes(
        (formal / UNDEFINED_OPENING_FILE).read_bytes()
    )
    (tmp_path / "top.sv").write_text(
        "module top(input a, output y);\n  assign y = a;\nendmodule\n"
    )
    path = tmp_path / "writes.sby"
    path.write_text(
        "[options]\nmode bmc\ndepth 1\n\n[engines]\nsmtbmc boolector\n\n[script]\n"
        "read -formal top.sv\nhierarchy -top top\n"
        + commands
        + "script free_undefined.ys\nprep -top top\n\n[files]\ntop.sv\nfree_undefined.ys\n"
    )
    (cfg,) = sby_config.resolved(path).values()
    gaps = script_write_gaps(path, cfg)
    assert bool(gaps) == (expect == "flag"), gaps
    if expect == "flag":
        assert sby_undefined_opening_gaps(path), commands


def test_file_writes_follow_the_installed_yosys() -> None:
    """Every command and option in SCRIPT_FORMS exists in Yosys and hides no write."""
    listing = subprocess.run(
        ["yosys", "-Q", "-p", "help"],
        capture_output=True,
        text=True,
        check=True,
        timeout=120,
    ).stdout
    known = set(re.findall(r"^\s+([a-z_0-9]+)\s", listing, re.M))
    assert SCRIPT_FILE_WRITES == {"write_json", "write_rtlil"}
    help_cache: dict[str, str] = {}
    for form in SCRIPT_FORMS:
        assert form.command in known, form.id
        assert form.writes_file == form.command.startswith("write_"), form.id
        extra_help = {"read": ("read_verilog",), "opt": ("prep",)}.get(form.command, ())
        for cmd_help in (form.command, *extra_help):
            if cmd_help not in help_cache:
                help_cache[cmd_help] = subprocess.run(
                    ["yosys", "-h", cmd_help],
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=120,
                ).stdout
        text = "\n".join(help_cache[name] for name in (form.command, *extra_help))
        prefix_set = {prefix for prefix, _ in form.prefix_opts}
        accepted_options = (
            set(form.flags)
            | set(form.required_flags)
            | {opt for opt, _ in form.opt_args}
            | prefix_set
        )
        if not form.writes_file:
            assert not (accepted_options & FORBIDDEN_WRITE_OPTIONS), form.id
        missing = [
            option
            for option in accepted_options
            if not re.search(
                rf"(^|[\s,|\[{{]){re.escape(option)}"
                rf"({'[A-Za-z' if option in prefix_set else '['}\s,=<\[\]|}}]|$)",
                text,
                re.M,
            )
        ]
        assert missing == [], (form.id, missing)


@pytest.mark.parametrize(
    "line",
    [
        "tee -q -o x.log opt -keepdc",
        "trace debug prep -top top",
        "debug -on",
        "lbl: opt -keepdc",
        ": comment",
        "opt -keepdc; opt_clean",
        "opt -keepdc;;",
        "!rm -f top.sv",
        "tcl script.tcl",
        "exec echo hi",
        "python -c pass",
        "plugin -i foo.so",
        "read paired.sv",
        "read -D FOO paired.sv",
        "read_verilog paired.sv",
        "opt -fine",
        "delete -input -output w:a",
    ],
)
def test_closed_language_refuses_wrappers_labels_and_semicolons(line: str) -> None:
    """Wrappers, labels, semicolons and shell or interpreter escapes fail parsing."""
    with pytest.raises(sby_config.ConfigError):
        sby_config.parse_script_lines([line])


def test_home_cmo_witness_driver_is_cover_only() -> None:
    """Keep directed inputs out of every other home task, including BMC and induction."""
    sby = Path(__file__).resolve().parents[1] / FORMAL_DIR / "coherence_home.sby"
    text = sby.read_text()
    driver = "COHERENCE_HOME_CMO_WITNESS"

    def check(config: str) -> None:
        source = sby_config.read_source(sby, config)
        for name, tags in source.tasks.items():
            task = source.task(name)
            commands = [
                cmd
                for cmd in task.commands(sby.parent)
                if any(driver in token for token in cmd)
            ]
            if name == "coh_home_cmo_cover":
                assert "cmo_witness" in tags
                assert task.options["mode"] == "cover"
                assert (task.options["depth"], task.options["timeout"]) == (
                    "40",
                    "6000",
                )
                assert commands == [["verilog_defines", "-D", driver]]
            elif name == "coh_home_cmo_fast_cover":
                assert "cmo_witness" in tags
                assert task.options["mode"] == "cover"
                assert (task.options["depth"], task.options["timeout"]) == (
                    "40",
                    "600",
                )
                assert len(commands) == 1 and commands[0][0] == "read_slang"
                assert f"-D{driver}" in commands[0]
                assert "-GFAST_TAG_LAUNCH=1" in commands[0]
                assert [
                    "select",
                    "-assert-count",
                    "5",
                    "t:$check",
                    "r:FLAVOR=cover",
                    "%i",
                ] in task.commands(sby.parent)
            else:
                assert "cmo_witness" not in tags and not commands, name

    check(text)
    for tag in ("bmc4", "control"):
        with pytest.raises(AssertionError):
            check(
                text.replace(
                    "[script]", "[script]\n" + f"{tag}: verilog_defines -D {driver}"
                )
            )


@pytest.mark.parametrize("task", ("coh_home_cmo_cover", "coh_home_cmo_fast_cover"))
@pytest.mark.parametrize("capture_output", (False, True))
@pytest.mark.parametrize(
    "case", ("pass", "solver failure", "artifact failure", "replay failure")
)
def test_home_cmo_replays_verified_run(
    monkeypatch: pytest.MonkeyPatch, task: str, capture_output: bool, case: str
) -> None:
    """Only the verified guided run supplies witnesses and the remaining time."""
    target = next(t for t in FORMAL_TARGETS if t.name == "coherence_home")
    expected_timeout = formal_task_timeout_s(target.name, task)
    runner = FormalRunner()
    events: list[str] = []
    guided_dir: Path | None = None

    def run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        nonlocal guided_dir
        if command[0] == "sby":
            assert "--yosys" in command and command[-1] == task
            guided_dir = Path(command[command.index("-d") + 1])
            assert kwargs["timeout"] == expected_timeout
            events.append("guided")
            return subprocess.CompletedProcess(
                command, int(case == "solver failure"), "guided\n", ""
            )
        assert events == ["guided", "artifacts"] and guided_dir is not None
        helper = sby_config.cmo_replay_helper(runner.formal_dir / target.sby_file, task)
        assert command[:4] == [
            sys.executable,
            str(helper),
            "--replay-verified",
            str(guided_dir),
        ]
        assert 0 < kwargs["timeout"] <= expected_timeout and kwargs["timeout"] == float(
            command[4]
        )
        assert kwargs["capture_output"] is capture_output
        events.append("replay")
        return subprocess.CompletedProcess(
            command, int(case == "replay failure"), "replay\n", ""
        )

    def verify(work: Path, sby: Path, name: str, selected: str, result: Any) -> None:
        assert work == guided_dir and sby == runner.formal_dir / target.sby_file
        assert name == target.name and selected == task and result.returncode == 0
        events.append("artifacts")
        if case == "artifact failure":
            raise ValueError("invalid guided model")

    monkeypatch.setattr(subprocess, "run", run)
    monkeypatch.setattr(runner, "verify_model_artifacts", verify)
    if case == "artifact failure":
        with pytest.raises(ValueError, match="invalid guided model"):
            runner.run_formal(target, task, capture_output=capture_output)
        assert events == ["guided", "artifacts"]
        return
    result = runner.run_formal(target, task, capture_output=capture_output)
    if case == "solver failure":
        assert events == ["guided"]
    else:
        assert events == ["guided", "artifacts", "replay"]
        if capture_output:
            assert result.stdout == "guided\nreplay\n"
    assert result.returncode == int(case != "pass")


def test_home_cmo_replay_strips_slang_witness_driver() -> None:
    """Remove only the slang witness define and require five covers for the fast cover."""
    from coherence_home_cmo_replay import cover_goals, strip_witness_driver

    script = (
        "read_slang --top coherence_home_control_harness --single-unit "
        "-DFORMAL -DCOHERENCE_HOME_CONTROL -DCOHERENCE_HOME_CMO_COVER "
        "-DCOHERENCE_HOME_CMO_FAST_COVER -DCOHERENCE_HOME_CMO_WITNESS "
        "-GFAST_TAG_LAUNCH=1 coherence_home_control_harness.sv\n"
    )
    stripped, goals = strip_witness_driver(script)
    assert goals == 5
    assert "-DCOHERENCE_HOME_CMO_WITNESS" not in stripped
    assert "-DCOHERENCE_HOME_CMO_FAST_COVER" in stripped
    assert "-GFAST_TAG_LAUNCH=1" in stripped
    with pytest.raises(ValueError):
        strip_witness_driver(stripped)
    assert cover_goals(
        "; yosys-smt2-cover 0 c_cmo_fast_dirty_grant\n"
        "; yosys-smt2-cover 1 $14815 coherence_home.sv:3128.7-3129.34\n"
    ) == {"c_cmo_fast_dirty_grant", "coherence_home.sv:3128.7-3129.34"}


def test_home_cmo_replay_uses_only_complete_primary_inputs(tmp_path: Path) -> None:
    """Leave the home's initial storage and the driver's case selection free on replay."""
    from coherence_home_cmo_replay import primary_inputs

    trace = tmp_path / "trace.smtc"
    state = "state 0\nassume (= [i_rst] true)\nassume (= [i_stop] false)\n"
    initial = "initial\nassume (= [home.slot] #b01)\nassume (= [witness_case] #b11)\n"
    hidden = "assume (= [home.fill] #b10)\n"
    trace.write_text(initial + state + hidden)
    assert primary_inputs(trace, {"i_rst", "i_stop"}, 0) == state
    for invalid in (
        state.split("assume (= [i_stop]")[0],
        state + "assume (= [i_rst] true)\n",
    ):
        trace.write_text(initial + invalid)
        with pytest.raises(ValueError):
            primary_inputs(trace, {"i_rst", "i_stop"}, 0)


def test_scripts_free_undefined_constants_first() -> None:
    """Every script outside the two pending lists opens with UNDEFINED_OPENING."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    sby_config.resolve_files(formal.glob("*.sby"))
    waiting = set(UNDEFINED_OPENING_PENDING) | set(UNDEFINED_OPENING_TWINS)
    lacking: list[str] = []
    opened: list[str] = []
    for sby_path in sorted(formal.glob("*.sby")):
        gaps = sby_undefined_opening_gaps(sby_path)
        if sby_path.stem in waiting:
            if not gaps:
                opened.append(sby_path.stem)
        else:
            lacking += [
                f"{sby_path.name} {task}: {gap}"
                for task, found in gaps.items()
                for gap in found
            ]
    # A script outside the lists must open in every task.
    assert not lacking, lacking
    # A listed script that opens in every task leaves its list.
    assert not opened, opened
    for names in (UNDEFINED_OPENING_PENDING, UNDEFINED_OPENING_TWINS):
        assert list(names) == sorted(set(names))
        assert [name for name in names if not (formal / f"{name}.sby").is_file()] == []
    assert not set(UNDEFINED_OPENING_PENDING) & set(UNDEFINED_OPENING_TWINS)
    # The opening's own file runs exactly UNDEFINED_OPENING.
    opening = sby_config.split_lf_lines(
        sby_config.read_checked_text(formal / "free_undefined.ys"),
        "free_undefined.ys",
    )
    assert [
        list(cmd.args) for cmd in sby_config.parse_script_lines(opening)
    ] == UNDEFINED_OPENING


def unqualified_check_count_guards(
    commands: list[sby_config.ParsedCommand],
) -> list[str]:
    """Return select -assert-count/-assert-min lines that select t:$check without a FLAVOR filter."""
    bad: list[str] = []
    for cmd in commands:
        if cmd.form.id not in ("select_assert_count", "select_assert_min"):
            continue
        selection = cmd.args[3:]
        if "t:$check" not in selection:
            continue
        has_flavor = any(
            tok in ("r:FLAVOR=assert", "r:FLAVOR=assume", "r:FLAVOR=cover")
            for tok in selection
        )
        if not (has_flavor and "%i" in selection):
            bad.append(" ".join(cmd.args))
    return bad


def test_check_count_guards_specify_flavor() -> None:
    """Every select -assert-count/-assert-min over t:$check qualifies its FLAVOR."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    sby_config.resolve_files(formal.glob("*.sby"))
    lacking: list[str] = []
    for sby_path in sorted(formal.glob("*.sby")):
        for task, cfg in sby_config.resolved(sby_path).items():
            parsed = cfg.parsed(sby_path.parent, expand_opening=False)
            lacking.extend(
                f"{sby_path.name} {task}: {line}"
                for line in unqualified_check_count_guards(parsed)
            )
    assert not lacking, lacking
    bare = sby_config.parse_script_lines(["select -assert-count 2 t:$check"])
    assert unqualified_check_count_guards(bare) == ["select -assert-count 2 t:$check"]
    qualified = sby_config.parse_script_lines(
        ["select -assert-count 2 t:$check r:FLAVOR=assert %i"]
    )
    assert unqualified_check_count_guards(qualified) == []


DONT_CARE_NO_STATE = (
    "select -assert-none t:*ff* t:*FF* t:*latch* t:*LATCH* t:$sr t:$_SR_* t:$mem* "
    "t:$anyinit t:$fsm"
)
DONT_CARE_ARRAY_CUT = (
    "selection: select -assert-none t:*ff* t:*FF* t:*latch*\n"
    "selection: setattr -unset init w:*\nselection: delete -output w:*\n"
    "selection: opt_clean\nselection: opt -keepdc\n"
)
# Each case edits a real script. A "flag" edit must make a task run a command
# that the checks reject beyond its open entry, an "accept" edit must leave
# every task's rejected commands as they are, a "stale" edit drops a pinned
# command, which leaves its open entry stale, and a "moved" edit runs a pinned
# command in another place, which both adds and drops one.
DONT_CARE_MUTATIONS: list[tuple[str, str, tuple[tuple[str, str], ...]]] = [
    # A command after ';' on a line.
    (
        "flag",
        "vec_vmu",
        (
            (
                "bmc: memory_map -keepdc\nbmc: opt -keepdc\n",
                "bmc: memory_map -keepdc; opt\n",
            ),
        ),
    ),
    # -keepdc in a comment.
    (
        "flag",
        "coherence_home_completions",
        (
            (
                "memory_map -keepdc\nopt -keepdc\n",
                "memory_map -keepdc\nopt # -keepdc after the next measurement\n",
            ),
        ),
    ),
    # Commands run through tee, debug and trace.
    (
        "flag",
        "coherent_local_atomic",
        (("memory_map -keepdc\nopt -keepdc\n", "memory_map -keepdc\ntee -q opt\n"),),
    ),
    (
        "flag",
        "coherent_local_atomic",
        (
            (
                "memory_map -keepdc\nopt -keepdc\n",
                "memory_map -keepdc\ntee -q -o opt.log +1 opt_expr\n",
            ),
        ),
    ),
    (
        "flag",
        "coherent_local_atomic",
        (("memory_map -keepdc\nopt -keepdc\n", "memory_map -keepdc\ndebug opt\n"),),
    ),
    (
        "flag",
        "coherent_local_atomic",
        (("memory_map -keepdc\nopt -keepdc\n", "memory_map -keepdc\ntrace opt_dff\n"),),
    ),
    # A plain opt after the script's last setundef.
    (
        "flag",
        "coherence_array_equiv",
        (("setundef -anyseq\nopt_clean\n", "setundef -anyseq\nopt_clean\nopt\n"),),
    ),
    # An option that resolves undefined multiplexer inputs, with -keepdc.
    (
        "flag",
        "coherence_array",
        (
            (
                "undefined: opt -fast -keepdc\n",
                "undefined: opt -fast -keepdc -mux_undef\n",
            ),
        ),
    ),
    (
        "flag",
        "coherent_local_atomic",
        (("\nopt -fast -keepdc\n", "\nopt -keepdc -full\n"),),
    ),
    # A tag after leading whitespace: the line runs in every task.
    (
        "flag",
        "vec_vmu",
        (("bmc: opt -keepdc\nbmc: techmap\n", "  bmc: opt\nbmc: techmap\n"),),
    ),
    # A second tag on a line is a label.
    (
        "flag",
        "vec_vmu",
        (("bmc: opt -keepdc\nbmc: techmap\n", "bmc: cover: opt\nbmc: techmap\n"),),
    ),
    # A tag block.
    (
        "flag",
        "vec_vmu",
        (("bmc: opt -keepdc\nbmc: techmap\n", "bmc:\nopt\n--\nbmc: techmap\n"),),
    ),
    # synth and memory run plain passes; so does prep -nokeepdc.
    (
        "flag",
        "coherence_array_plru",
        (("memory_map -keepdc\n", "memory_map -keepdc\nsynth -run coarse\n"),),
    ),
    ("flag", "coherence_array_plru", (("memory_map -keepdc\n", "memory\n"),)),
    (
        "flag",
        "coherence_array_plru",
        (
            (
                "memory_map -keepdc\n",
                "memory_map -keepdc\nprep -nokeepdc -top coherence_array_plru_formal\n",
            ),
        ),
    ),
    # A plain memory_map.
    ("flag", "coherence_store_home", (("memory_map -keepdc\n", "memory_map\n"),)),
    # A continued line.
    (
        "flag",
        "coherence_array_plru",
        (("memory_map -keepdc\n", "memory_map -keepdc\nopt \\\n-fast\n"),),
    ),
    # A quoted argument hides neither ';' nor what follows it.
    (
        "flag",
        "coherence_array_plru",
        (("memory_map -keepdc\n", 'memory_map -keepdc\nlog "done # ok"; opt\n'),),
    ),
    # Options that resolve undefined values after -keepdc, a script file, tee
    # with several options, a negated tag, wreduce and opt_dff without -keepdc,
    # -share_all, synth_xilinx and a tag inside a block.
    (
        "flag",
        "coherence_home_completions",
        (("proof: opt -keepdc\n", "proof: opt -keepdc -undriven\n"),),
    ),
    (
        "flag",
        "coherence_array_plru",
        (("memory_map -keepdc\n", "memory_map -keepdc; opt -mux_undef -keepdc\n"),),
    ),
    (
        "flag",
        "vec_vmu",
        (
            ("bmc: techmap\n", "bmc: script extra.ys\nbmc: techmap\n"),
            ("[files]\n", "[file extra.ys]\nopt\n\n[files]\n"),
        ),
    ),
    (
        "flag",
        "coherent_local_atomic",
        (("\nopt -fast -keepdc\n", "\ntee -a t.log -q +2 -s pad opt -fast\n"),),
    ),
    ("flag", "vec_vmu", (("bmc: techmap\n", "~bmc: opt\nbmc: techmap\n"),)),
    (
        "flag",
        "coherence_home_array",
        (("proof: techmap\n", "wreduce\nproof: techmap\n"),),
    ),
    (
        "flag",
        "coherence_array_equiv",
        (("techmap\n", "opt_merge -share_all\ntechmap\n"),),
    ),
    (
        "flag",
        "coherence_array_plru",
        (
            (
                "memory_map -keepdc\n",
                "synth_xilinx -run begin:coarse\nmemory_map -keepdc\n",
            ),
        ),
    ),
    ("flag", "coherent_local_atomic", (("\nopt -fast -keepdc\n", "\nopt_dff -sat\n"),)),
    (
        "flag",
        "vec_vmu",
        (("bmc: techmap\n", "bmc:\n  cover: opt\n--\nbmc: techmap\n"),),
    ),
    # Passes that resolve undefined memory words, multiplexer inputs, initial
    # values or free inputs, and a register added after an assertion that no
    # state is left.
    (
        "flag",
        "coherence_array_plru",
        (("memory_map -keepdc\n", "memory -nomap\nmemory_map -keepdc\n"),),
    ),
    (
        "flag",
        "coherence_store_home",
        (("memory_map -keepdc\n", "opt_mem\nmemory_map -keepdc\n"),),
    ),
    (
        "flag",
        "coherence_home_array",
        (("memory_map -keepdc\n", "memory_share\nmemory_map -keepdc\n"),),
    ),
    (
        "flag",
        "coherent_local_atomic",
        (("memory_map -keepdc\n", "opt_mem_feedback\nmemory_map -keepdc\n"),),
    ),
    (
        "flag",
        "coherence_array",
        (
            (
                DONT_CARE_ARRAY_CUT,
                f"selection: {DONT_CARE_NO_STATE}\nselection: chformal -delay 1\n"
                "selection: setattr -unset init w:*\nselection: delete -output w:*\n"
                "selection: opt_clean\nselection: opt -full\n",
            ),
        ),
    ),
    ("flag", "coherence_array_equiv", (("techmap\n", "techmap\nabc\n"),)),
    ("flag", "coherence_array_equiv", (("techmap\n", "techmap\nzinit -all\n"),)),
    (
        "flag",
        "vec_vmu",
        (("bmc: techmap\n", "bmc: setundef -zero -init\nbmc: techmap\n"),),
    ),
    (
        "flag",
        "coherence_home_completions",
        (("proof: techmap\n", "fsm\nproof: techmap\n"),),
    ),
    (
        "flag",
        "coherence_array_equiv",
        (("techmap\n", "techmap\ndfflegalize -cell $_DFF_P_ 0\n"),),
    ),
    # More passes outside the list: -share_all with -keepdc, chformal -skip, a
    # constant free input, opt_mem_priority inside tee and peepopt.
    (
        "flag",
        "coherence_home_array",
        (("memory_map -keepdc\n", "memory_map -keepdc\nopt -keepdc -share_all\n"),),
    ),
    ("flag", "vec_vmu", (("bmc: techmap\n", "bmc: chformal -skip 1\nbmc: techmap\n"),)),
    (
        "flag",
        "coherence_array_plru",
        (("memory_map -keepdc\n", "memory_map -keepdc\nsetundef -anyconst\n"),),
    ),
    (
        "flag",
        "coherent_local_atomic",
        (("memory_map -keepdc\n", "tee -q opt_mem_priority\nmemory_map -keepdc\n"),),
    ),
    ("flag", "vec_vmu", (("bmc: techmap\n", "bmc: peepopt\nbmc: techmap\n"),)),
    # An added task or line in a file with an open entry.
    (
        "flag",
        "coherent_hart_cache",
        (
            (
                "coh_hart_maint_four_cover four covers base\n",
                "coh_hart_maint_four_cover four covers base\n"
                "coh_hart_maint_four_plain_bmc four bounded fourbmc base plain\n",
            ),
        ),
    ),
    (
        "flag",
        "coherence_store_boundary",
        (("[script]\n", "[script]\nread -formal -sv coherence_pkg.sv\nopt -full\n"),),
    ),
    (
        "flag",
        "coherent_hart_cache",
        (
            (
                "coh_hart_maint_cover covers base\n",
                "coh_hart_maint_cover covers base\ncoh_hart_maint_cover2 covers base\n",
            ),
        ),
    ),
    (
        "flag",
        "branch_predictor_twin",
        (
            (
                "select -assert-count 60 t:$anyseq\nrename -top gold\n",
                "select -assert-count 60 t:$anyseq\nsetundef -one\nrename -top gold\n",
            ),
        ),
    ),
    (
        "flag",
        "coherence_store_home",
        (("compact_covers: abc\n", "compact_covers: abc\ncompact_covers: peepopt\n"),),
    ),
    ("flag", "rs_payload_twin", (("opt_clean\n", "opt_clean\nabc\n"),)),
    (
        "flag",
        "coherence_l1d",
        (("[script]\n", "[script]\nread -formal -sv coherence_pkg.sv\nopt -full\n"),),
    ),
    # A pinned command that a script drops.
    ("stale", "coherent_hart_cache", (("covers: setundef -zero\n", ""),)),
    ("stale", "coherence_store_home", (("bmc: peepopt\n", ""),)),
    # A pinned command run a further time in the tasks that run it: a plain opt
    # after the BMCs' setundef, and a plain memory_map after their opt_clean.
    (
        "flag",
        "coherence_store_boundary",
        (("bmc: setundef -anyseq\n", "bmc: setundef -anyseq\nbmc: opt\n"),),
    ),
    (
        "flag",
        "coherence_store_boundary",
        (("bmc: opt_clean\n", "bmc: opt_clean\nbmc: memory_map\n"),),
    ),
    # A pinned command moved before another one, or to the other tasks. One
    # moved only past listed commands keeps its pin.
    (
        "moved",
        "coherence_store_boundary",
        (("memory_map\nopt\n", "opt\nmemory_map\n"),),
    ),
    ("moved", "coherence_store_boundary", (("bmc: opt -fast\n", "~bmc: opt -fast\n"),)),
    (
        "accept",
        "coherence_store_boundary",
        (
            (
                "bmc: opt -fast\nbmc: setundef -anyseq\n",
                "bmc: setundef -anyseq\nbmc: opt -fast\n",
            ),
        ),
    ),
    # No assertion exempts a later command: opt -full after an assertion that
    # no state is left, also with the assertion scoped to one module, and -fine,
    # which merges equal multiplexer output bits.
    (
        "flag",
        "coherence_array",
        (
            (
                DONT_CARE_ARRAY_CUT,
                f"selection: {DONT_CARE_NO_STATE}\nselection: setattr -unset init w:*\n"
                "selection: delete -output w:*\nselection: opt_clean\n"
                "selection: opt -full\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vmu",
        (
            (
                "bmc: techmap\n",
                "bmc: select -list -module vec_vmu_formal\n"
                f"bmc: {DONT_CARE_NO_STATE}\nbmc: opt -full\nbmc: techmap\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vmu",
        (("bmc: techmap\n", "bmc: opt_expr -keepdc -fine\nbmc: techmap\n"),),
    ),
    (
        "flag",
        "coherence_array_plru",
        (("proof: opt -fast -keepdc\n", "proof: opt -fast -keepdc -fine\n"),),
    ),
    # Options a listed form does not take: -mux_undef on opt_expr and wreduce,
    # -ifx on prep, -undef on cutpoint, -delay beside chformal -remove.
    (
        "flag",
        "vec_vmu",
        (("bmc: techmap\n", "bmc: opt_expr -keepdc -mux_undef\nbmc: techmap\n"),),
    ),
    (
        "flag",
        "coherence_array_plru",
        (
            (
                "proof: opt -fast -keepdc\n",
                "proof: wreduce -keepdc -mux_undef\nproof: opt -fast -keepdc\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vmu",
        (
            (
                "prep -top vec_vmu_formal -flatten\n",
                "prep -top vec_vmu_formal -flatten -ifx\n",
            ),
        ),
    ),
    (
        "flag",
        "coherence_home_completions",
        (("memory_map -keepdc\n", "cutpoint -undef t:$dff\nmemory_map -keepdc\n"),),
    ),
    (
        "flag",
        "coherence_home_completions",
        (("proof: techmap\n", "chformal -remove -cover -delay 1\nproof: techmap\n"),),
    ),
    # An attribute setattr may not set, and commands hidden in debug and tee,
    # in a script file, behind a label, trace and ';', behind a task's own name
    # as a tag, behind a negated tag, under another name and in quotes.
    (
        "flag",
        "coherence_array_plru",
        (
            (
                "proof: setundef -anyseq\nopt_clean\n",
                "proof: setundef -anyseq\nsetattr -set init 1'0 w:*\nopt_clean\n",
            ),
        ),
    ),
    (
        "flag",
        "coherent_local_atomic",
        (("\nopt -fast -keepdc\n", "\ndebug tee -q opt -full\n"),),
    ),
    (
        "flag",
        "vec_vmu",
        (
            ("bmc: techmap\n", "bmc: script hide.ys\nbmc: techmap\n"),
            ("[files]\n", "[file hide.ys]\ntee -q memory -nomap\n\n[files]\n"),
        ),
    ),
    (
        "flag",
        "coherence_array_plru",
        (
            (
                "memory_map -keepdc\n",
                "memory_map -keepdc\nstep: trace opt_clean; opt -purge\n",
            ),
        ),
    ),
    (
        "flag",
        "coherence_array_plru",
        (
            (
                "proof: techmap\n",
                "coh_array_plru_port_cover: opt -keepdc -mux_undef\nproof: techmap\n",
            ),
        ),
    ),
    (
        "flag",
        "coherence_home_completions",
        (("proof: techmap\n", "~plain: memory_map\nproof: techmap\n"),),
    ),
    ("flag", "vec_vmu", (("bmc: techmap\n", "bmc: write_ilang x.il\nbmc: techmap\n"),)),
    ("flag", "vec_vmu", (("bmc: techmap\n", 'bmc: "opt"\nbmc: techmap\n'),)),
    # opt -full after assertions that leave out a state type, add a selection
    # to the list, hold in one task only, or come before techmap -map.
    (
        "flag",
        "vec_vmu",
        (
            (
                "bmc: techmap\n",
                f"bmc: {DONT_CARE_NO_STATE.replace('t:$mem*', 't:$mem')}\n"
                "bmc: opt -full\nbmc: techmap\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vmu",
        (
            (
                "bmc: techmap\n",
                f"bmc: {DONT_CARE_NO_STATE} %u\nbmc: opt -full\nbmc: techmap\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vmu",
        (
            (
                "bmc: techmap\n",
                f"bmc: techmap\ncover: {DONT_CARE_NO_STATE}\nopt -full\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vmu",
        (
            (
                "bmc: techmap\n",
                f"bmc: {DONT_CARE_NO_STATE}\nbmc: techmap -map +/techmap.v\n"
                "bmc: opt -full\nbmc: techmap\n",
            ),
        ),
    ),
    # Naming free cells is registered once per form of the queue comparison.
    (
        "flag",
        "coherence_array_plru",
        (
            (
                "proof: opt -fast -keepdc\n",
                "proof: autoname t:$anyseq\nproof: opt -fast -keepdc\n",
            ),
        ),
    ),
    (
        "flag",
        "pd_target_candidate_twin",
        (("rename -top gold\n", "autoname t:$anyseq\nrename -top gold\n"),),
    ),
    (
        "flag",
        "decoded_bundle_queue_twin",
        (("rename -top gold\n", "autoname t:$anyseq\nrename -top gold\n"),),
    ),
    (
        "flag",
        "decoded_bundle_queue_twin",
        (("autoname t:$anyseq\nrename -top gold", "autoname\nrename -top gold"),),
    ),
    # A further command in pinned tasks of a file with an open entry.
    (
        "flag",
        "coherent_hart_cache",
        (("covers: setundef -zero\n", "covers: setundef -zero\ncovers: opt -full\n"),),
    ),
    # Sound edits in the closed language, alongside wrappers, semicolons,
    # unlisted flags, complex quotes and labels, which the closed language
    # refuses.
    (
        "accept",
        "coherence_array_plru",
        (("proof: opt -fast -keepdc\n", "proof: opt -purge -fast -keepdc\n"),),
    ),
    (
        "flag",
        "coherent_local_atomic",
        (("\nopt -fast -keepdc\n", "\ntee -q -o t.log opt -keepdc -fast\n"),),
    ),
    (
        "accept",
        "coherence_home_completions",
        (
            (
                "proof: setundef -undriven -anyseq\n",
                "proof: setundef -anyseq -undriven\n",
            ),
        ),
    ),
    (
        "accept",
        "coherence_home_completions",
        (("proof: techmap\n", "chformal -cover -remove c:none\nproof: techmap\n"),),
    ),
    (
        "flag",
        "vec_vmu",
        (("bmc: techmap\n", "bmc: debug -on opt -full\nbmc: techmap\n"),),
    ),
    (
        "flag",
        "coherence_array_plru",
        (("memory_map -keepdc\n", "memory_map -keepdc;;\nclean -purge\n"),),
    ),
    (
        "flag",
        "coherence_array_plru",
        (("memory_map -keepdc\n", "memory_map -keepdc -formal\n"),),
    ),
    (
        "accept",
        "coherence_home_completions",
        (("proof: techmap\n", "setattr -unset init w:*\nproof: techmap\n"),),
    ),
    (
        "accept",
        "coherence_home_completions",
        (
            (
                "memory_map -keepdc\nopt -keepdc\n",
                "memory_map -keepdc\nopt -kee\\\npdc\n",
            ),
        ),
    ),
    (
        "accept",
        "coherence_home_completions",
        (("proof: opt -keepdc\n", "proof: opt -keepdc # -full\n"),),
    ),
    (
        "flag",
        "coherence_array_plru",
        (("memory_map -keepdc\n", 'memory_map -keepdc\nlog "opt -full; opt"\n'),),
    ),
    (
        "flag",
        "coherence_array_plru",
        (("memory_map -keepdc\n", "memory_map -keepdc\ndebug -on opt\n"),),
    ),
    (
        "flag",
        "coherence_array_equiv",
        (("techmap\n", "  lbl: opt -keepdc\ntechmap\n"),),
    ),
    (
        "accept",
        "coherence_home_completions",
        (("proof: techmap\n", "setundef -undriven -anyseq\nproof: techmap\n"),),
    ),
    (
        "flag",
        "coherence_array_plru",
        (("memory_map -keepdc\n", "memory_map -formal\n"),),
    ),
    ("accept", "coherence_array_equiv", (("techmap\n", "cutpoint t:$dff\ntechmap\n"),)),
    (
        "accept",
        "coherence_home_array",
        (
            (
                "memory_map -keepdc\n",
                "design -save before\ndesign -load before\nmemory_map -keepdc\n",
            ),
        ),
    ),
]


@pytest.mark.parametrize("expect,name,edits", DONT_CARE_MUTATIONS)
def test_dont_care_guard_mutations(
    tmp_path: Path, expect: str, name: str, edits: tuple[tuple[str, str], ...]
) -> None:
    """Check the command guard on an isolated copy of each proof and its inputs."""
    root = Path(__file__).resolve().parents[1]
    source = root / FORMAL_DIR / f"{name}.sby"
    mutated = sby_config.stage_proof(source, root, tmp_path)
    text = sby_config.read_checked_text(mutated)
    for old, new in edits:
        assert text.count(old) == 1, (name, old)
        text = text.replace(old, new)
    mutated.write_bytes(text.encode("utf-8"))
    assert dont_care_changes(source) == ([], [])
    added, missing = dont_care_changes(mutated)
    if expect == "flag":
        assert added, edits
    elif expect == "accept":
        assert (added, missing) == ([], []), (added, missing)
    elif expect == "moved":
        assert added and missing, (added, missing)
    else:
        assert missing and not added, (added, missing)


def test_dont_care_guard_reads_scripts_as_yosys_does(tmp_path: Path) -> None:
    """Tags, comments, included .ys files, and assertions exempt nothing."""
    no_state = "select -assert-none " + " ".join(
        f"t:{pattern}"
        for pattern in (
            "*ff*",
            "*FF*",
            "*latch*",
            "*LATCH*",
            "$sr",
            "$_SR_*",
            "$mem*",
            "$anyinit",
            "$fsm",
        )
    )
    sby_path = tmp_path / "tags.sby"
    sby_path.write_text(
        "[tasks]\nfirst proof\nsecond covers\nthird:\n\n[options]\nmode bmc\ndepth 1\n"
        "\n[engines]\nsmtbmc boolector\n\n[script]\nprep -top top\n"
        "proof: opt # -keepdc\n~proof: opt -keepdc\n"
        "covers: script extra.ys\nlog -stderr opt\n"
        f"proof: {no_state}\nproof: opt -full\n"
        "\n[file extra.ys]\nopt_expr -keepdc\nmemory_map -keepdc\npeepopt\n"
    )
    resolved = sby_config.resolved(sby_path)
    assert {task: cfg.commands(tmp_path) for task, cfg in resolved.items()} == {
        "first": [
            ["prep", "-top", "top"],
            ["opt"],
            ["log", "-stderr", "opt"],
            no_state.split(),
            ["opt", "-full"],
        ],
        "second": [
            ["prep", "-top", "top"],
            ["opt", "-keepdc"],
            ["opt_expr", "-keepdc"],
            ["memory_map", "-keepdc"],
            ["peepopt"],
            ["log", "-stderr", "opt"],
        ],
        "third": [
            ["prep", "-top", "top"],
            ["opt", "-keepdc"],
            ["log", "-stderr", "opt"],
        ],
    }
    assert sby_dont_care_optimizations(sby_path) == {
        "first": ["opt", "opt -full"],
        "second": ["peepopt"],
    }
    for prefix in ([], [["cd", "top"]], [["select", "-module", "sub"]]):
        assert dont_care_optimizations(
            [*prefix, no_state.split(), ["opt", "-full"]]
        ) == ["opt -full"]
    assert dont_care_optimizations(
        [no_state.split(), ["chformal", "-delay", "1"], ["opt"]]
    ) == ["chformal -delay 1", "opt"]
    assert dont_care_optimizations([["opt", "-keepdc", "-share_all"]]) == [
        "opt -keepdc -share_all"
    ]
    assert dont_care_pins("coherence_store_boundary")["bmc_sc"] == [
        "memory_map",
        "opt",
        "opt -fast",
    ]


UNDEFINED_OPEN_VTYPE = (
    "hierarchy -top vec_vtype_tracker_formal\nscript free_undefined.ys\n"
)
# Each case edits a real script that opens. A "flag" edit must leave some task
# without the opening, an "accept" edit must leave every task opened.
UNDEFINED_OPENING_MUTATIONS: list[tuple[str, str, tuple[tuple[str, str], ...]]] = [
    # The opening removed, its two lines swapped, placed after an optimizing
    # pass or after prep, in one task only, or another proc in its place.
    ("flag", "vec_vtype_tracker", ((UNDEFINED_OPEN_VTYPE, ""),)),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                UNDEFINED_OPEN_VTYPE,
                "script free_undefined.ys\nhierarchy -top vec_vtype_tracker_formal\n",
            ),
        ),
    ),
    (
        "flag",
        "coherence_array_plru",
        (
            (
                "hierarchy -top coherence_array\n",
                "opt -keepdc\nhierarchy -top coherence_array\n",
            ),
        ),
    ),
    (
        "flag",
        "async_fifo",
        (
            (
                "hierarchy -top async_fifo\nscript free_undefined.ys\nprep -top async_fifo\n",
                "prep -top async_fifo\nhierarchy -top async_fifo\nscript free_undefined.ys\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vmu",
        (
            (
                "hierarchy -top vec_vmu_formal\nscript free_undefined.ys\n",
                "bmc: hierarchy -top vec_vmu_formal\nbmc: script free_undefined.ys\n",
            ),
        ),
    ),
    (
        "flag",
        "coherence_store_buffer",
        (
            (
                "~saturation: script free_undefined.ys\n",
                "prove: script free_undefined.ys\n",
            ),
        ),
    ),
    (
        "flag",
        "rs_issue_tag_copies",
        (("script free_undefined.ys\n", "proc -norom -noopt\nsetundef -anyseq\n"),),
    ),
    ("flag", "sq_live_count", (("hierarchy -top store_queue\n", ""),)),
    # Sources or parameters after the opening, another top, what async2sync
    # writes, and a connection to an undefined constant in four spellings.
    (
        "flag",
        "async_fifo",
        (
            (
                "script free_undefined.ys\nprep -top async_fifo\n",
                "script free_undefined.ys\nchparam -set DEPTH 8 async_fifo\nprep -top async_fifo\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\nprep",
                "script free_undefined.ys\nread -formal -sv vec_cfg_unit.sv\nprep",
            ),
        ),
    ),
    (
        "flag",
        "coherence_store_buffer",
        (
            (
                "saturation: prep -flatten -top coherence_store_saturation_formal\n",
                "saturation: prep -flatten -top coherence_store_buffer\n",
            ),
        ),
    ),
    (
        "flag",
        "coherent_local_atomic",
        (("memory_map -keepdc\n", "async2sync\nmemory_map -keepdc\n"),),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\nprep",
                "script free_undefined.ys\nasync2sync\nsetundef -anyseq w:*\nprep",
            ),
        ),
    ),
    (
        "flag",
        "lq_capture",
        (
            (
                "connect -nounset -set p_hold dut.coh_launch_hold_q\n",
                "connect -nounset -set p_hold 1'x\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\nprep",
                "script free_undefined.ys\nconnect -set clk 1'bx\nprep",
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\nprep",
                "script free_undefined.ys\nconnect -set clk 1'X\nprep",
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\nprep",
                "script free_undefined.ys\nconnect -set clk {1'b0,4'hx}\nprep",
            ),
        ),
    ),
    # The opening on part of the design: an emptied, replaced or scoped
    # selection before it, or cd into a module.
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\n",
                "select -none\nscript free_undefined.ys\nselect -clear\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\n",
                "cd vec_vtype_tracker\nscript free_undefined.ys\ncd\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\n",
                "select -list -module vec_vtype_tracker\nscript free_undefined.ys\ncd\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\n",
                "select w:*\nscript free_undefined.ys\nselect -clear\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\n",
                "select -assert-none -module vec_vtype_tracker t:$nonexistent\n"
                "script free_undefined.ys\ncd\n",
            ),
        ),
    ),
    # A narrower selection or active module kept with a design and brought
    # back by design -load or -pop, and a design that comes back, or joins,
    # without its opening.
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                UNDEFINED_OPEN_VTYPE,
                "cd vec_vtype_tracker_formal\ndesign -save s\ncd\ndesign -load s\n"
                + UNDEFINED_OPEN_VTYPE,
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                UNDEFINED_OPEN_VTYPE,
                "select w:*\ndesign -save s\nselect -clear\ndesign -load s\n"
                + UNDEFINED_OPEN_VTYPE,
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                UNDEFINED_OPEN_VTYPE,
                "select w:*\ndesign -push-copy\nselect -clear\ndesign -pop\n"
                + UNDEFINED_OPEN_VTYPE,
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                UNDEFINED_OPEN_VTYPE,
                "design -push-copy\n" + UNDEFINED_OPEN_VTYPE + "design -pop\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                UNDEFINED_OPEN_VTYPE,
                "design -save raw\n" + UNDEFINED_OPEN_VTYPE + "design -load raw\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                UNDEFINED_OPEN_VTYPE,
                "design -save raw\n" + UNDEFINED_OPEN_VTYPE + "design -import raw\n",
            ),
        ),
    ),
    # A script file included with a label that skips the opening.
    (
        "flag",
        "vec_vtype_tracker",
        (
            (UNDEFINED_OPEN_VTYPE, "script open.ys rest\n"),
            (
                "[files]\n",
                f"[file open.ys]\n opening:\n{UNDEFINED_OPEN_VTYPE} rest:\nlog skipped\n\n[files]\n",
            ),
        ),
    ),
    # The opening's file reached any other way: a [files] entry with a path,
    # under another source name, listed twice, written as a [file] section,
    # the opening's commands written out, or another file that holds them.
    (
        "flag",
        "vec_vtype_tracker",
        (("\nfree_undefined.ys\n", "\ncopy/free_undefined.ys\n"),),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (("\nfree_undefined.ys\n", "\nfree_undefined.ys vec_unit_opening.ys\n"),),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (("\nfree_undefined.ys\n", "\nfree_undefined.ys\nfree_undefined.ys\n"),),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            ("\nfree_undefined.ys\n", "\n"),
            (
                "[files]\n",
                "[file free_undefined.ys]\nproc\nsetundef -anyseq\n\n[files]\n",
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\n",
                "".join(" ".join(c) + "\n" for c in UNDEFINED_OPENING),
            ),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            ("script free_undefined.ys\n", "script opening.ys\n"),
            (
                "[files]\n",
                "[file opening.ys]\n"
                + "".join(" ".join(c) + "\n" for c in UNDEFINED_OPENING)
                + "\n[files]\n",
            ),
        ),
    ),
    # Sound variants: the opening in an included script;
    # setundef -undriven after it; a selection asserted or cleared
    # before it; the opening run again after a parameter is set.
    (
        "flag",
        "vec_vtype_tracker",
        (
            (
                UNDEFINED_OPEN_VTYPE,
                "cd vec_vtype_tracker_formal\ndesign -save s\ncd\n"
                + UNDEFINED_OPEN_VTYPE,
            ),
        ),
    ),
    (
        "accept",
        "vec_vtype_tracker",
        (
            (
                UNDEFINED_OPEN_VTYPE,
                UNDEFINED_OPEN_VTYPE
                + "design -save opened\ndesign -reset\ndesign -load opened\n",
            ),
        ),
    ),
    (
        "accept",
        "vec_vtype_tracker",
        (
            (UNDEFINED_OPEN_VTYPE, "script open.ys\n"),
            ("[files]\n", f"[file open.ys]\n{UNDEFINED_OPEN_VTYPE}\n[files]\n"),
        ),
    ),
    (
        "flag",
        "vec_vtype_tracker",
        (
            (UNDEFINED_OPEN_VTYPE, "script open.ys opening\n"),
            (
                "[files]\n",
                f"[file open.ys]\n opening:\n{UNDEFINED_OPEN_VTYPE} rest:\nlog done\n\n[files]\n",
            ),
        ),
    ),
    (
        "accept",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\nprep",
                "script free_undefined.ys\nsetundef -undriven -anyseq\nprep",
            ),
        ),
    ),
    (
        "accept",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\nprep",
                "script free_undefined.ys\nasync2sync\nsetundef -anyseq\nprep",
            ),
        ),
    ),
    (
        "accept",
        "vec_vtype_tracker",
        (
            (
                "script free_undefined.ys\n",
                "select -assert-min 1 t:*\nselect -module vec_vtype_tracker_formal\n"
                "select -clear\nscript free_undefined.ys\n",
            ),
        ),
    ),
    (
        "accept",
        "async_fifo",
        (
            (
                "script free_undefined.ys\nprep -top async_fifo\n",
                "script free_undefined.ys\nchparam -set DEPTH 4 async_fifo\n"
                "hierarchy -top async_fifo\nscript free_undefined.ys\nprep -top async_fifo\n",
            ),
        ),
    ),
]
# Edits of the copy of the opening's file that vec_vtype_tracker's script
# gets: a command dropped, moved, added or run on another selection, and also
# a change that leaves the commands as they are. Each is refused.
UNDEFINED_OPENING_FILE_MUTATIONS: list[tuple[str, tuple[tuple[str, str], ...]]] = [
    ("flag", (("select -clear\n", ""),)),
    ("flag", (("setundef -anyseq t:$mux t:$pmux t:$bwmux w:*\n", ""),)),
    (
        "flag",
        (
            (
                "setundef -anyseq t:$mux t:$pmux t:$bwmux w:*\n",
                "setundef -anyseq t:$mux t:$pmux t:$bwmux\n",
            ),
        ),
    ),
    ("flag", (("setundef -anyseq\nproc_dff\n", "proc_dff\nsetundef -anyseq\n"),)),
    ("flag", (("proc_mux\n", "proc_rom\nproc_mux\n"),)),
    ("flag", (("opt_expr -keepdc t:$meminit*\n", "opt_expr -keepdc\n"),)),
    (
        "flag",
        (
            (
                "proc_clean\nopt_expr -keepdc\n",
                "proc_clean\nopt_expr -keepdc -mux_undef\n",
            ),
        ),
    ),
    (
        "flag",
        (("proc_clean\nproc_rmdead\n", "select -none\nproc_clean\nproc_rmdead\n"),),
    ),
    ("flag", (("proc_dlatch\n", "cd top\nproc_dlatch\ncd\n"),)),
    ("flag", (("proc_dlatch\n", "log latches\nproc_dlatch\necho off\n"),)),
    (
        "flag",
        (("proc_dff\n", "select -assert-none t:$meminit_v2 %n %n\nproc_dff\n"),),
    ),
    ("flag", (("# Frees the undefined", "# Makes free the undefined"),)),
]


def undefined_opening_mutant(
    tmp_path: Path,
    name: str,
    edits: tuple[tuple[str, str], ...],
    file_edits: tuple[tuple[str, str], ...] = (),
) -> Path:
    """Stage the proof's inputs before editing the configuration or opening."""
    root = Path(__file__).resolve().parents[1]
    mutated = sby_config.stage_proof(root / FORMAL_DIR / f"{name}.sby", root, tmp_path)
    text = sby_config.read_checked_text(mutated)
    for old, new in edits:
        assert text.count(old) == 1, (name, old)
        text = text.replace(old, new)
    mutated.write_bytes(text.encode("utf-8"))
    if file_edits:
        opening = mutated.with_name(UNDEFINED_OPENING_FILE)
        body = sby_config.read_checked_text(opening)
        for old, new in file_edits:
            assert body.count(old) == 1, old
            body = body.replace(old, new)
        opening.write_bytes(body.encode("utf-8"))
    return mutated


@pytest.mark.parametrize("expect,name,edits", UNDEFINED_OPENING_MUTATIONS)
def test_undefined_opening_mutations(
    tmp_path: Path, expect: str, name: str, edits: tuple[tuple[str, str], ...]
) -> None:
    """The opening check finds a task that a mutation leaves without its opening."""
    source = Path(__file__).resolve().parents[1] / FORMAL_DIR / f"{name}.sby"
    assert sby_undefined_opening_gaps(source) == {}
    gaps = sby_undefined_opening_gaps(undefined_opening_mutant(tmp_path, name, edits))
    if expect == "flag":
        assert gaps, edits
    else:
        assert gaps == {}, gaps


@pytest.mark.parametrize("expect,edits", UNDEFINED_OPENING_FILE_MUTATIONS)
def test_undefined_opening_file_mutations(
    tmp_path: Path, expect: str, edits: tuple[tuple[str, str], ...]
) -> None:
    """A script must get the repository's opening file unchanged."""
    mutated = undefined_opening_mutant(tmp_path, "vec_vtype_tracker", (), edits)
    gaps = sby_undefined_opening_gaps(mutated)
    assert expect == "flag"
    assert gaps, edits
    assert all(
        f"not the repository's {UNDEFINED_OPENING_FILE}" in found[0]
        for found in gaps.values()
    ), gaps


# H7: SymbiYosys drops twin and opening files per task, which the checks, which
# read [files] once, would not see. Each case is a script with the tag where
# the check must find it, or a control the check must accept.
SBY_TAG_HEAD = """[tasks]
t
u

[options]
mode bmc
t: depth 1
u: depth 2

[engines]
smtbmc boolector

[script]
read -sv top.sv
hierarchy -top top
"""
SBY_TAG_CASES: list[tuple[str, str]] = [
    # The reviewed script: a block drops the pinned file for task t, and a
    # tagged section writes its own for t.
    (
        "flag",
        "script free_undefined.ys\nprep -top top\n\n[files]\ntop.sv\n~t:\n"
        "free_undefined.ys\n--\n\nt: [file free_undefined.ys]\nt: proc\n",
    ),
    ("flag", "script free_undefined.ys\n\n[files]\ntop.sv\nt: free_undefined.ys\n"),
    (
        "flag",
        "script free_undefined.ys\n\n[files]\ntop.sv\nt:\nfree_undefined.ys\n--\n",
    ),
    ("flag", "script free_undefined.ys\n\nt: [files]\ntop.sv\nfree_undefined.ys\n"),
    (
        "flag",
        "script free_undefined.ys\nt:\nprep\n\n[files]\ntop.sv\nfree_undefined.ys\n--\n",
    ),
    (
        "flag",
        "script free_undefined.ys\n\n[files]\ntop.sv\nfree_undefined.ys\n\n"
        "[file x.ys]\nt: proc\n",
    ),
    # The checks read [script] per task, as SymbiYosys does, so tags there,
    # on the opening too, and on [options] lines are the scripts' own.
    ("accept", "t: script free_undefined.ys\n\n[files]\ntop.sv\nfree_undefined.ys\n"),
    (
        "accept",
        "u:\nscript free_undefined.ys\n--\n\n[files]\ntop.sv\nfree_undefined.ys\n",
    ),
    (
        "accept",
        "script free_undefined.ys\nt: chparam -set W 4 top\nu:\nprep\n--\n\n"
        "[files]\ntop.sv\nfree_undefined.ys\n",
    ),
]


@pytest.mark.parametrize("expect,body", SBY_TAG_CASES)
def test_sby_tag_gaps(tmp_path: Path, expect: str, body: str) -> None:
    """The tag check finds the tags on files and section headers, and only those."""
    script = tmp_path / "tags.sby"
    script.write_text(SBY_TAG_HEAD + body)
    gaps = sby_tag_gaps(script)
    assert bool(gaps) == (expect == "flag"), gaps
    if expect == "flag":
        assert sby_undefined_opening_gaps(script), body


@pytest.mark.parametrize(
    "pattern",
    [
        "hidden_.*",
        "hidden_.+",
        "hidden_[a-z]+",
        "(hidden_tag)",
        "hidden_ta[g]",
        "hidden_tag|unused",
        "hidden_tag$",
    ],
)
def test_sby_task_groups_are_literal(tmp_path: Path, pattern: str) -> None:
    """Refuse patterns that add another task to a group."""
    path = tmp_path / "groups.sby"
    path.write_text(
        f"[tasks]\nhelper: hidden_tag\nmain_task: {pattern}\n"
        "[script]\nread -formal top.sv\nhierarchy -top top\n"
        "helper: script free_undefined.ys\n~hidden_tag: script free_undefined.ys\n"
        "hidden_tag:\n~helper: proc\n~helper: setundef -zero\n--\nprep -top top\n"
        "[files]\ntop.sv\nfree_undefined.ys\n"
    )
    assert pattern in sby_undefined_opening_gaps(path)["-"][0]
    assert pattern in dont_care_changes(path)[0][0]


@pytest.mark.parametrize(
    "first,second",
    [
        ("[file dummy.ys] # copy", "  [file free_undefined.ys]"),
        ("[file dummy.ys]\t# copy", "[file free_undefined.ys]"),
        (" [file dummy.ys]", "[file free_undefined.ys]"),
        ("[file dummy.ys]", "\t[file free_undefined.ys]"),
        ("[file dummy.ys] ", "[file free_undefined.ys]"),
        ("[file dummy.ys]", "[file ./free_undefined.ys]"),
        ("[file dummy.ys]", "[file free_undefined.ys] # override"),
    ],
)
def test_sby_file_headers_are_literal(tmp_path: Path, first: str, second: str) -> None:
    """Refuse an ambiguous header before it can shadow the opening file."""
    path = tmp_path / "headers.sby"
    path.write_text(
        SBY_TAG_HEAD
        + "script free_undefined.ys\nprep -top top\n[files]\ntop.sv\n"
        + f"{first}\nfree_undefined.ys\n{second}\nproc\nsetundef -zero\n"
    )
    assert "file " in sby_undefined_opening_gaps(path)["-"][0]
    assert "file " in dont_care_changes(path)[0][0]


def test_sby_resolves_nondefault_tasks(tmp_path: Path) -> None:
    """Check every declared task even when only one is a default."""
    path = tmp_path / "groups.sby"
    path.write_text(
        "[tasks]\na: group default\nb: group\n[options]\nmode bmc\ndepth 1\n"
        "[engines]\nsmtbmc boolector\n[script]\n"
        "group: hierarchy -top top\na: script free_undefined.ys\nb: setundef -zero\n"
        "[files]\nfree_undefined.ys\n"
    )
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    (tmp_path / UNDEFINED_OPENING_FILE).write_bytes(
        (formal / UNDEFINED_OPENING_FILE).read_bytes()
    )
    assert list(sby_config.resolved(path)) == ["a", "b"]
    assert sby_config.resolved(path)["b"].commands(tmp_path) == [
        ["hierarchy", "-top", "top"],
        ["setundef", "-zero"],
    ]
    assert dont_care_changes(path)[0] == ["groups.sby b: setundef -zero"]


def test_stage_proof_carries_nested_script_inputs(tmp_path: Path) -> None:
    """A relocated proof keeps sibling RTL, nested scripts and inline inputs."""
    root = tmp_path / "checkout"
    proof = root / "formal/top.sby"
    inputs = {
        "formal/top.sby": (
            "[script]\nscript setup.ys\nprep -top top\n"
            "[files]\nshared/setup.ys\n../tools/read_top.ys\n../hw/top.sv\n"
            "[file defines.ys]\nread -define FORMAL_INPUT\n"
        ),
        "formal/shared/setup.ys": "script defines.ys\nscript read_top.ys\n",
        "tools/read_top.ys": "read -formal -sv top.sv\n",
        "hw/top.sv": "module top; endmodule\n",
        "formal/unused.ys": "log unused\n",
    }
    for name, content in inputs.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    fixture = tmp_path / "fixture"
    copied = sby_config.stage_proof(proof, root, fixture)
    assert copied == fixture / "formal/top.sby"
    assert {
        path.relative_to(fixture).as_posix(): path.read_text()
        for path in fixture.rglob("*")
        if path.is_file()
    } == {name: body for name, body in inputs.items() if name != "formal/unused.ys"}
    assert sby_config.source(copied).task("").commands(copied.parent) == [
        ["read", "-define", "FORMAL_INPUT"],
        ["read", "-formal", "-sv", "top.sv"],
        ["prep", "-top", "top"],
    ]


@pytest.mark.parametrize("section", ["files", "script", "options", "engines", "tasks"])
def test_sby_sections_have_one_header(tmp_path: Path, section: str) -> None:
    """Reject a repeated header before a reader can overwrite its first body."""
    path = tmp_path / "repeated.sby"
    path.write_text(
        SBY_TAG_HEAD
        + "script free_undefined.ys\n[files]\nfree_undefined.ys\n"
        + f"[{section}]\n"
    )
    assert f"[{section}]" in sby_undefined_opening_gaps(path)["-"][0]


def test_opening_tracks_map_sources() -> None:
    """Every map and every saved design that supplies modules has an opening."""
    read = [["read", "-sv", "map.sv"]]
    opening = [["hierarchy", "-top", "template"], UNDEFINED_OPENING_MARK]
    save = [["design", "-stash", "map"]]
    apply = [["techmap", "-max_iter", "1", "-map", "%map"]]
    assert not undefined_opening_gaps(read + opening + save + opening + apply)
    assert undefined_opening_gaps(read + save + opening + apply)
    for source in ("map.sv", "+/techmap.v", "%missing", ""):
        assert undefined_opening_gaps(opening + [["techmap", "-map", source]])
        assert undefined_opening_gaps(
            opening + save + opening + [apply[0] + ["-map", source]]
        )
    for action in ("-load", "-import", "-copy-from", "-copy-to"):
        assert undefined_opening_gaps(
            opening + [["design", action, "missing"]] + opening
        )
    for action in ("-save", "-stash", "-push", "-push-copy"):
        assert undefined_opening_gaps(read + [["design", action, "raw"]] + opening)
    assert undefined_opening_gaps(opening + [["design", "-pop"]])
    assert undefined_opening_gaps(
        opening + save + opening + [["design", "-delete", "map"]] + apply
    )


@pytest.mark.parametrize(
    "command",
    [
        "select -write sel.txt",
        "select -read sel.txt",
        "log -o x.log message",
        "check -assert -noinit",
        "read -formal -I/tmp top.sv",
        "setattr -set foo 1 w:*",
        "chparam -set W 4 -set",
        "debug -on",
        "echo on",
        "stat",
    ],
)
def test_opening_holds_commands_to_their_forms(command: str) -> None:
    """A command before the opening runs only in a form DONT_CARE_SAFE lists."""
    opening = [["hierarchy", "-top", "top"], UNDEFINED_OPENING_MARK]
    commands = [["read", "-formal", "top.sv"], command.split(), *opening]
    assert undefined_opening_gaps(commands), command


# Configurations SymbiYosys refuses, which the checkout-only reader must
# refuse too, and well-formed ones it must read as SymbiYosys does.
SBY_READER_CORPUS: list[str] = [
    "[tasks]\nbmc\n[options]\n#TODO: fix\nmode bmc\n[script]\nread -formal a.sv\n",
    "[tasks]\nbmc\n[script]\nread -formal a.sv\n#note: here\n",
    "[tasks]\nbmc\n[files]\n#x: y\na.sv\n",
    "[tasks]\nbmc\n[file x.ys]\n#tag: x\n",
    "[tasks]\nbmc\n[script]\n:\n",
    "[tasks]\nbmc\n[script]\n: comment\n",
    "[tasks]\n[options]\nmode bmc\n[script]\nread -formal a.sv\n",
    "[tasks]\n# only a comment\n[options]\nmode bmc\n",
    "[tasks]\nbmc\n[options]\nmode bmc\n[script]\nfoo: read -formal a.sv\n",
    "[tasks]\nbmc: a: b\n[options]\nmode bmc\n",
    "[tasks]\nbmc\n[options]\nbmc:\nmode bmc\n",
    "[tasks]\nbmc\n[options]\nmode bmc\n--\n",
    "[tasks]\nbmc .*\n[options]\nmode bmc\n",
    "[tasks]\nbmc\n[options]\nmode bmc\n[options]\nmode prove\n",
    "[tasks]\nbmc\n[script] # x\nread -formal a.sv\n",
    "[tasks]\nbmc\n [script]\nread -formal a.sv\n",
    "[tasks]\nbmc\n[stage x]\n",
    "[options]\nmode bmc\n[tasks]\nbmc\n",
    "--pycode-begin--\noutput('[options]')\n--pycode-end--\n",
    # Well-formed: the reader must give what SymbiYosys gives.
    "[tasks]\nbmc\nprove\n[options]\nbmc: mode bmc\nprove: mode prove\n# TODO: x\n"
    "[script]\nread -formal a.sv\n  #note: indented\nbmc:\nprep -top a\n--\n[files]\na.sv\n",
    "[options]\nmode bmc\n#TODO: no tasks here\n[script]\nread -formal a.sv\n",
    "[tasks]\nbmc\n[options]\nmode bmc #comment\n[engines]\nsmtbmc\n[script]\n"
    "read -formal a.sv; prep -top a\n[files]\na.sv\n",
]


def test_reader_refuses_what_sby_refuses(tmp_path: Path) -> None:
    """Refuse each text SymbiYosys refuses, and read the others as it does."""
    texts = {f"case{index}": text for index, text in enumerate(SBY_READER_CORPUS)}
    outcomes = sby_config.sby_outcomes(texts)
    refused = 0
    for name, text in texts.items():
        try:
            source = sby_config.read_source(tmp_path / f"{name}.sby", text)
        except sby_config.ConfigError:
            source = None
        if "error" in outcomes[name]:
            refused += 1
            assert source is None, (name, text, outcomes[name]["error"])
        elif source is not None:
            tasks = outcomes[name]["tasks"]
            assert list(source.tasks) == list(tasks), name
            for task, entry in tasks.items():
                assert source.task(task) == sby_config.TaskConfig.from_raw(**entry), (
                    name,
                    task,
                )
    assert refused == 14


def test_generated_sby_corpus_matches_symbiyosys(tmp_path: Path) -> None:
    """Compare read_source acceptance and rejection with SymbiYosys on mutations."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    seeds = (
        "alu_shift_hint.sby",
        "vec_vmu.sby",
        "coherence_home_forward_pins.sby",
        "coherence_link.sby",
        "nic_irq.sby",
        "control_flow_tracker_twin.sby",
        "axi_coherent_bridge.sby",
        "rs_payload_twin.sby",
    )
    corpus: dict[str, str] = {}

    def add(label: str, text: str) -> None:
        corpus[f"m{len(corpus)}_{label}"] = text

    for stem in seeds:
        base = (formal / stem).read_text()
        lines = base.splitlines()
        tasks = list(sby_config.source(formal / stem).tasks)
        first_task = tasks[0]

        # Valid dialect mutations: comments, blank lines, option edits, tag blocks,
        # negated tags, inline .ys sections, and colon-form [tasks] entries.
        add("orig", base)
        add("no_trailing_nl", base.rstrip("\n"))
        add("leading_comment", "# top comment\n\n" + base)
        add(
            "indented_colon_comment",
            base.replace("[script]\n", "[script]\n  #note: ok\n", 1),
        )
        add(
            "option_inline_comment",
            base.replace("[options]\n", "[options]\ntimeout 60 # sec\n", 1),
        )
        add(
            "engine_inline_comment",
            base.replace("[engines]\n", "[engines]\n# engine note\n", 1),
        )
        add("inline_ys", base + "\n[file helper_extra.ys]\nselect -clear\n")
        if first_task:
            add(
                "tagged_block",
                base.replace(
                    "[script]\n",
                    f"[script]\n{first_task}:\nselect -clear\n--\n",
                    1,
                ),
            )
            add(
                "negated_tag",
                base.replace(
                    "[script]\n",
                    f"[script]\n~{first_task}: select -clear\n",
                    1,
                ),
            )
            add(
                "tagged_option",
                base.replace(
                    "[options]\n",
                    f"[options]\n{first_task}: vcd off\n",
                    1,
                ),
            )
            add(
                "tasks_extra_colon",
                base.replace(
                    "[tasks]\n",
                    f"[tasks]\nextra_variant: {first_task} default\n",
                    1,
                ),
            )

        # Invalid mutations refused by SymbiYosys and/or the strict dialect.
        add("prep_mode", base.replace("[options]\n", "[options]\nmode prep\n", 1))
        add(
            "smtc_option",
            base.replace("[options]\n", "[options]\nsmtc extra.smtc\n", 1),
        )
        add(
            "expect_option",
            base.replace("[options]\n", "[options]\nexpect PASS,TIMEOUT\n", 1),
        )
        add(
            "skip_prep_option",
            base.replace("[options]\n", "[options]\nskip_prep on\n", 1),
        )
        add("wait_option", base.replace("[options]\n", "[options]\nwait on\n", 1))
        add(
            "unknown_engine",
            base.replace("[engines]\n", "[engines]\nsmtbmc --basecase boolector\n", 1),
        )
        add("smtc_file", base.replace("[files]\n", "[files]\nextra.smtc\n", 1))
        add("dup_options", base + "\n[options]\nmode bmc\n")
        add("dup_script", base + "\n[script]\nselect -clear\n")
        add("dup_files", base + "\n[files]\nextra_dup.sv\n")
        add("indented_header", base.replace("[script]", "  [script]", 1))
        add("commented_header", base.replace("[script]", "[script] # tail", 1))
        add("unknown_header", base + "\n[setup]\ncutpoint a\n")
        add("stage_header", base + "\n[stage s]\nmode bmc\n")
        add("engines_arg", base.replace("[engines]", "[engines bmc]", 1))
        add("pycode", "--pycode-begin--\noutput('[tasks]')\n--pycode-end--\n" + base)
        add("stray_block_end", base.replace("[script]\n", "[script]\n--\n", 1))
        add("bad_option_arity", base.replace("[options]\n", "[options]\nmode\n", 1))
        add("two_arg_files", base.replace("[files]\n", "[files]\ndst.sv src.sv\n", 1))
        add("dot_slash_file", base.replace("[files]\n", "[files]\n./local.sv\n", 1))
        add("control_char", base.replace("[script]\n", "[script]\n\x0b\n", 1))
        add(
            "non_ascii_ws",
            base.replace("[script]\n", "[script]\n\u00a0opt -keepdc\n", 1),
        )
        add("indented_comment_before_section", "  # leading comment\n" + base)
        add("orphan_before_section", "mode bmc\n" + base)
        if "[tasks]\n" in base:
            after_tasks = "[options]" + base.split("[options]", 1)[1]
            add("empty_tasks", "[tasks]\n" + after_tasks)
            add("comment_only_tasks", "[tasks]\n# none\n" + after_tasks)
            add(
                "indented_comment_in_tasks",
                base.replace("[tasks]\n", "[tasks]\n  # note\n", 1),
            )
            add("tasks_after_options", after_tasks + "\n[tasks]\nt1\n")
            add(
                "double_colon_tasks", base.replace("[tasks]\n", "[tasks]\na: b: c\n", 1)
            )
            add("regex_task", base.replace("[tasks]\n", "[tasks]\nt_.*: grp\n", 1))
            add("regex_group", base.replace("[tasks]\n", "[tasks]\nt_new: grp_.*\n", 1))
            add("dup_task", base.replace("[tasks]\n", f"[tasks]\n{first_task}\n", 1))
            add(
                "hash_colon_script",
                base.replace("[script]\n", "[script]\n#TODO: x\n", 1),
            )
            add(
                "hash_colon_files", base.replace("[files]\n", "[files]\n#FIXME: y\n", 1)
            )
            add("bare_colon_script", base.replace("[script]\n", "[script]\n:\n", 1))
            add(
                "colon_comment_script",
                base.replace("[script]\n", "[script]\n: note\n", 1),
            )
            add(
                "unknown_tag",
                base.replace("[script]\n", "[script]\nno_such_tag: opt\n", 1),
            )
            add(
                "unterminated_block",
                base + f"\n[script]\n{first_task}:\n"
                if "[script]" not in base
                else base.replace("[files]", f"{first_task}:\n[files]", 1),
            )
            add(
                "unclosed_eof_block",
                base.replace("[script]\n", f"[script]\n{first_task}:\n", 1),
            )
            add(
                "nested_block",
                base.replace(
                    "[script]\n",
                    f"[script]\n{first_task}:\n{first_task}:\n--\n",
                    1,
                ),
            )
            add(
                "tagged_files",
                base.replace("[files]\n", f"[files]\n{first_task}: a.sv\n", 1),
            )
            add("tagged_header", base.replace("[files]", f"{first_task}: [files]", 1))
        # Drop each non-blank line in turn on small seeds to exercise missing
        # headers and structural truncations.
        if len(lines) <= 40:
            for idx in range(0, len(lines), 3):
                mutated = "\n".join(lines[:idx] + lines[idx + 1 :]) + "\n"
                add(f"drop{idx}", mutated)

    outcomes = sby_config.sby_outcomes(corpus)
    both_accepted = 0
    sby_refused = 0
    for name, text in corpus.items():
        try:
            parsed_src = sby_config.read_source(tmp_path / f"{name}.sby", text)
        except sby_config.ConfigError:
            parsed_src = None
        outcome = outcomes[name]
        if "error" in outcome:
            sby_refused += 1
            assert parsed_src is None, (name, text, outcome["error"])
        elif parsed_src is not None:
            both_accepted += 1
            tasks = outcome["tasks"]
            assert list(parsed_src.tasks) == list(tasks), name
            for task, entry in tasks.items():
                assert parsed_src.task(task) == sby_config.TaskConfig.from_raw(
                    **entry
                ), (name, task)
    assert both_accepted >= 80, both_accepted
    assert sby_refused >= 80, sby_refused


def test_scripts_match_resolved_sby_tasks() -> None:
    """The checkout-only reader agrees with SymbiYosys on every task and file."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    sby_config.resolve_files(formal.glob("*.sby"))
    for path in sorted(formal.glob("*.sby")):
        source = sby_config.source(path)
        resolved = sby_config.resolved(path)
        assert list(source.tasks) == list(resolved), path
        for task, config in resolved.items():
            assert source.task(task) == config, (path.name, task)


def test_undefined_opening_reads_commands() -> None:
    """Which commands may precede the opening, and what resets, scopes or closes it."""
    opening = [["hierarchy", "-top", "top"], UNDEFINED_OPENING_MARK]
    assert (
        undefined_opening_gaps(
            [["read", "-formal", "a.sv"], *opening, ["opt", "-keepdc"]]
        )
        == []
    )
    assert (
        undefined_opening_gaps(
            [
                ["delete", "t:sub"],
                ["cutpoint", "w:x"],
                ["select", "-assert-none", "t:$assume"],
                *opening,
            ]
        )
        == []
    )
    assert undefined_opening_gaps([["flatten"], *opening]) == [
        "flatten: acts before the opening"
    ]
    assert undefined_opening_gaps([["select", "-module", "sub"], *opening]) == [
        "script free_undefined.ys: the opening runs on a selection, not the design"
    ]
    assert undefined_opening_gaps(
        [["hierarchy", "-top", "top"], *UNDEFINED_OPENING, ["prep", "-top", "top"]]
    ) == ["proc_clean: acts before the opening", "no opening"]
    assert undefined_opening_gaps([["cd", "sub"], ["cd", ".."], *opening]) == []
    assert (
        undefined_opening_gaps(
            [["cd", "sub"], ["design", "-reset"], ["read", "-formal", "a.sv"], *opening]
        )
        == []
    )
    assert undefined_opening_gaps(
        [["cd", "sub"], ["design", "-stash", "s"], ["design", "-load", "s"], *opening]
    ) == [
        "design -stash s: the source design has no opening",
        "design -load s: saved design 's' has no opening",
        "script free_undefined.ys: the opening runs on a selection, not the design",
    ]
    assert undefined_opening_gaps(
        [*opening, ["design", "-reset"], ["read", "-sv", "b.sv"], ["prep", "-top", "b"]]
    ) == ["prep -top b: acts before the opening", "the final design has no opening"]
    assert undefined_opening_gaps(
        [
            *opening,
            ["design", "-reset"],
            ["read", "-formal", "b.sv"],
            ["hierarchy", "-top", "b"],
        ]
    ) == ["the final design has no opening"]
    assert (
        undefined_opening_gaps(
            [*opening, ["hierarchy", "-top", "top"], ["prep", "-top", "top"]]
        )
        == []
    )
    assert undefined_opening_gaps([*opening, ["hierarchy", "-top", "sub"]]) == [
        "hierarchy -top sub: another top after the opening"
    ]
    assert undefined_opening_gaps(
        [
            *opening,
            ["design", "-save", "s"],
            ["design", "-copy-from", "s", "-as", "copy", "top"],
            ["hierarchy", "-top", "sub"],
            UNDEFINED_OPENING_MARK,
        ]
    ) == ["hierarchy -top sub: another top after the opening"]
    assert (
        undefined_opening_gaps(
            [*opening, ["async2sync"], ["setundef", "-anyseq"], ["opt", "-keepdc"]]
        )
        == []
    )
    assert undefined_opening_gaps([*opening, ["async2sync"], ["opt", "-keepdc"]]) == [
        "opt -keepdc: acts on what async2sync writes"
    ]
    assert undefined_opening_gaps([*opening, ["async2sync"]]) == [
        "async2sync without setundef -anyseq"
    ]
    assert undefined_opening_gaps(
        [*opening, ["async2sync"], ["design", "-stash", "s"], *opening]
    ) == ["design -stash s: acts on what async2sync writes"]
    assert undefined_opening_gaps([*opening, ["clk2fflogic"], ["setundef", "-anyseq"]])
    for spelled in ("1'x", "1'bx", "1'X", "4'hx", "2'b0?", "{a,1'bz}", "8'hxF"):
        assert UNDEFINED_CONSTANT.search(spelled), spelled
    for spelled in ("1'b0", "8'h00", "5'b00000", "16'hDEAD", "w:x_q", "dut.x"):
        assert not UNDEFINED_CONSTANT.search(spelled), spelled


@pytest.mark.parametrize(
    ("case_id", "sby_text"),
    [
        # Regex RHS group tag, commented or indented [file] override, and
        # repeated section headers.
        (
            "regex_group_tag",
            "[tasks]\nhelper: hidden_tag\nmain_task: hidden_.*\n[options]\nmode bmc\n"
            "[engines]\nsmtbmc\n[script]\nread -formal -sv top.sv\nhierarchy -top top\n"
            "~hidden_tag: script free_undefined.ys\nhidden_tag: proc\n"
            "hidden_tag: setundef -zero\nprep -top top\n[files]\ntop.sv\nfree_undefined.ys\n",
        ),
        (
            "indented_file_override",
            "[options]\nmode bmc\n[engines]\nsmtbmc\n[script]\n"
            "read -formal -sv top.sv\nhierarchy -top top\nscript free_undefined.ys\n"
            "prep -top top\n[files]\ntop.sv\n[file dummy.ys] # comment\n"
            "free_undefined.ys\n  [file free_undefined.ys]\nproc\nsetundef -zero\n",
        ),
        (
            "repeated_files_section",
            "[tasks]\nbmc\n[options]\nmode bmc\n[engines]\nsmtbmc\n[script]\n"
            "read -formal -sv top.sv\nhierarchy -top top\nscript free_undefined.ys\n"
            "prep -top top\n[files]\ntop.sv\n[files]\nfree_undefined.ys\n",
        ),
        # tee -o/-a, select -write, column-one #word:, and empty [tasks].
        (
            "tee_override",
            "[tasks]\nbmc\n[options]\nmode bmc\n[engines]\nsmtbmc\n[script]\n"
            "tee -q -o free_undefined.ys log proc\n"
            "read -formal -sv top.sv\nhierarchy -top top\nscript free_undefined.ys\n"
            "prep -top top\n[files]\ntop.sv\nfree_undefined.ys\n",
        ),
        (
            "select_write_wipe",
            "[tasks]\nbmc\n[options]\nmode bmc\n[engines]\nsmtbmc\n[script]\n"
            "read -formal -sv top.sv\nhierarchy -top top\nselect -none\n"
            "select -write free_undefined.ys\nselect -clear\nscript free_undefined.ys\n"
            "prep -top top\n[files]\ntop.sv\nfree_undefined.ys\n",
        ),
        (
            "hash_colon_comment",
            "[tasks]\nbmc\n[options]\n#TODO: fix\nmode bmc\n[engines]\nsmtbmc\n[script]\n"
            "read -formal -sv top.sv\nhierarchy -top top\nscript free_undefined.ys\n"
            "prep -top top\n[files]\ntop.sv\nfree_undefined.ys\n",
        ),
        (
            "empty_tasks",
            "[tasks]\n[options]\nmode bmc\n[engines]\nsmtbmc\n[script]\n"
            "read -formal -sv top.sv\nhierarchy -top top\nscript free_undefined.ys\n"
            "prep -top top\n[files]\ntop.sv\nfree_undefined.ys\n",
        ),
        # design -reset leaving final design unopened, select -set -clear,
        # bare ':' selector, indented label in [script], test_cell -vlog writer,
        # and async2sync at end of script without setundef -anyseq.
        (
            "reset_unopened_tail",
            "[tasks]\nbmc\n[options]\nmode bmc\nskip_prep on\n[engines]\n"
            "smtbmc --syn boolector\n[script]\nread -formal -sv top.sv\n"
            "hierarchy -top top\nscript free_undefined.ys\nprep -top top\n"
            "design -reset\nread_slang --top top --single-unit --no-synthesis-define "
            "-DFORMAL top.sv\nchformal -lower\nhierarchy -top top\n"
            "[files]\ntop.sv\nfree_undefined.ys\n",
        ),
        (
            "select_set_clear",
            "[tasks]\nbmc\n[options]\nmode bmc\n[engines]\nsmtbmc\n[script]\n"
            "read -formal -sv top.sv\nhierarchy -top top\nselect -none\n"
            "select -set -clear %\nscript free_undefined.ys\nselect -clear\n"
            "prep -top top\n[files]\ntop.sv\nfree_undefined.ys\n",
        ),
        (
            "bare_colon",
            "[tasks]\nbmc\n[options]\nmode bmc\n[engines]\nsmtbmc\n[script]\n"
            ": comment\nread -formal -sv top.sv\nhierarchy -top top\n"
            "script free_undefined.ys\nprep -top top\n[files]\ntop.sv\nfree_undefined.ys\n",
        ),
        (
            "indented_label",
            "[tasks]\nbmc\n[options]\nmode bmc\n[engines]\nsmtbmc\n[script]\n"
            "read -formal -sv top.sv\nhierarchy -top top\nscript free_undefined.ys\n"
            "prep -top top\n  lbl: delete t:$check\n[files]\ntop.sv\nfree_undefined.ys\n",
        ),
        (
            "unlisted_writer_test_cell",
            "[tasks]\nbmc\n[options]\nmode bmc\n[engines]\nsmtbmc\n[script]\n"
            "test_cell -s 1 -n 1 -noeval -nosat -vlog top.sv $not\n"
            "read -formal -sv top.sv\nhierarchy -top top\nscript free_undefined.ys\n"
            "prep -top top\n[files]\ntop.sv\nfree_undefined.ys\n",
        ),
        (
            "async2sync_tail",
            "[tasks]\nbmc\n[options]\nmode bmc\nskip_prep on\n[engines]\n"
            "smtbmc --syn boolector\n[script]\nread -formal -sv top.sv\n"
            "hierarchy -top top\nscript free_undefined.ys\nprep -top top\n"
            "async2sync\n[files]\ntop.sv\nfree_undefined.ys\n",
        ),
    ],
)
def test_script_and_dialect_bypass_cases_refused(
    tmp_path: Path, case_id: str, sby_text: str
) -> None:
    """Each dialect, file-write, scoping and unopened-tail bypass is refused."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    (tmp_path / UNDEFINED_OPENING_FILE).write_bytes(
        (formal / UNDEFINED_OPENING_FILE).read_bytes()
    )
    (tmp_path / "top.sv").write_text("module top;\nendmodule\n")
    path = tmp_path / f"{case_id}.sby"
    path.write_text(sby_text)
    assert sby_undefined_opening_gaps(path), case_id


def test_coherence_sc_wa_contract() -> None:
    """Pin the composed SC GrantM writeback-exclusion proofs and covers."""
    target = next(t for t in FORMAL_TARGETS if t.name == "coherence_sc_wa")
    harness_text = (Path(FORMAL_DIR) / "coherence_sc_wa_formal.sv").read_text(
        encoding="utf-8"
    )
    assert "coherence_home #(" in harness_text
    assert target.tasks == (
        "sc_wa_s0_prove",
        "sc_wa_s1_prove",
        "sc_wa_s2_prove",
        "sc_wa_s3_prove",
        "sc_wa_s0_cover",
        "sc_wa_s1_cover",
        "sc_wa_s2_cover",
        "sc_wa_s3_cover",
    )
    for stages in (0, 1, 2, 3):
        prove_task = f"sc_wa_s{stages}_prove"
        prove_cfg = formal_task_config(target.name, prove_task)
        prove_opts = dict(line.split(None, 1) for line in prove_cfg["[options]"])
        assert prove_opts == {"mode": "prove", "depth": "2", "timeout": "600"}
        assert formal_task_timeout_s(target.name, prove_task) == 600
        assert prove_cfg["[engines]"] == ["smtbmc boolector"]
        prove_script = prove_cfg["[script]"]
        assert any(
            f"-GLINK_STAGES={stages}" in line
            and "-GCOVER_MODE=0" in line
            and "coherence_home.sv" in line
            and "coherence_home_array.sv" in line
            and "coherence_seat_select.sv" in line
            for line in prove_script
        )
        assert "../hw/rtl/lib/cache/coherence_home.sv" in prove_cfg["[files]"]
        assert "../hw/rtl/lib/cache/coherence_home_array.sv" in prove_cfg["[files]"]
        assert "select -assert-none t:$check r:FLAVOR=assume %i" in prove_script
        expected_asserts = 141 if stages == 0 else 150
        assert (
            f"select -assert-count {expected_asserts} t:$check r:FLAVOR=assert %i"
            in prove_script
        )
        assert "techmap" not in prove_script
        assert "abc" not in prove_script

        cover_task = f"sc_wa_s{stages}_cover"
        cover_cfg = formal_task_config(target.name, cover_task)
        cover_opts = dict(line.split(None, 1) for line in cover_cfg["[options]"])
        assert cover_opts == {
            "mode": "cover",
            "depth": "200",
            "vcd_sim": "on",
            "timeout": "1200",
        }
        assert formal_task_timeout_s(target.name, cover_task) == 1200
        assert cover_cfg["[engines]"] == ["btor btormc"]
        cover_script = cover_cfg["[script]"]
        assert any(
            f"-GLINK_STAGES={stages}" in line
            and "-GCOVER_MODE=1" in line
            and "coherence_home.sv" in line
            for line in cover_script
        )
        assert "select -assert-none t:$check r:FLAVOR=assume %i" in cover_script
        assert "select -assert-count 12 t:$check r:FLAVOR=cover %i" in cover_script


def test_store_home_cover_budgets() -> None:
    """Pin cover bounds, engines and the complete task selection."""
    target = next(t for t in FORMAL_TARGETS if t.name == "coherence_store_home")
    assert tuple(task for task in target.tasks if "cover" in task) == (
        "cover_siblings",
        "cover_rows",
        "cover_conflict",
        "cover_pressure",
        "link_cover_pressure",
    )
    for task, depth, timeout in (
        ("cover_siblings", 240, 2400),
        ("cover_rows", 240, 2400),
        ("cover_conflict", 233, 900),
        ("cover_pressure", 235, 900),
        ("link_cover_pressure", 250, 900),
    ):
        config = formal_task_config(target.name, task)
        options = dict(line.split(None, 1) for line in config["[options]"])
        assert options == {
            "mode": "cover",
            "vcd_sim": "on",
            "depth": str(depth),
            "timeout": str(timeout),
        }
        assert formal_task_timeout_s(target.name, task) == timeout
        assert config["[engines]"] == ["btor btormc"]
        script = config["[script]"]
        assert "chparam -set COVER_MODE 1 coherence_store_home_formal" in script
        if "pressure" in task:
            assert "chparam -set PRESSURE 1 coherence_store_home_formal" in script
        elif task == "cover_conflict":
            assert "chparam -set SECTOR_CASE 2 coherence_store_home_formal" in script
        elif task == "cover_rows":
            assert "chparam -set SECTOR_CASE 1 coherence_store_home_formal" in script
        if task == "link_cover_pressure":
            assert "chparam -set LINK_STAGES 1 coherence_store_home_formal" in script
        assert "peepopt" not in script
        if timeout == 2400:
            assert not any("chformal" in line for line in script)
            assert "abc" not in script
            continue
        assert [line for line in script if line.startswith("chformal")] == [
            "chformal -assert -remove"
        ]
        pipeline = (
            "chformal -assert -remove",
            "setattr -unset keep",
            "techmap",
            "opt -fast -keepdc",
            "abc",
            "opt -keepdc -mux_bool -fine",
            "setundef -undriven -anyseq",
            "select -assert-count 1 t:$check r:FLAVOR=cover %i",
            "select -assert-count 1 t:$check r:FLAVOR=assume %i",
            "select -clear",
        )
        model = script[script.index("prep -flatten -top coherence_store_home_formal") :]
        positions = [model.index(command) for command in pipeline]
        assert positions == sorted(positions)
        assert positions[-1] < model.index("setundef -anyseq")
    bounded_tasks = (
        ("bmc_siblings", 240),
        ("bmc_rows", 240),
        ("bmc_conflict", 360),
        ("bmc_pressure", 360),
        ("link_bmc_siblings", 300),
        ("link_bmc_pressure", 420),
    )
    assert {task for task in target.tasks if "bmc" in task} == {
        task + suffix for task, _ in bounded_tasks for suffix in ("", "_second")
    }
    for base, depth in bounded_tasks:
        pair = []
        for choice, suffix in enumerate(("", "_second")):
            task = base + suffix
            bounded = formal_task_config(target.name, task)
            options = dict(line.split(None, 1) for line in bounded["[options]"])
            assert options == {
                "mode": "bmc",
                "depth": str(depth),
                "timeout": "900",
                "aigsmt": "boolector",
            }
            assert formal_task_timeout_s(target.name, task) == 900
            engine = "abc bmc3"
            if base == "link_bmc_siblings":
                engine = "abc bmc3 -c"
            assert bounded["[engines]"] == [engine]
            script = bounded["[script]"]
            assert "abc" not in script
            assert not any("chformal" in line for line in script)
            assert not any(
                "cutpoint" in line or "setundef -zero" in line for line in script
            )
            bind = f"connect -nomap -set watch_second 1'b{choice}"
            assert [line for line in script if line.startswith("connect ")] == [bind]
            assert [line for line in script if line.startswith("delete ")] == [
                "delete @watch_choice"
            ]
            partition = (
                "select -module coherence_store_home_formal",
                "select -assert-count 3 t:$anyconst",
                "select -set watch_choice w:watch_second %ci* t:$anyconst %i",
                "select -assert-count 1 @watch_choice",
                "select -assert-count 1 t:$anyconst r:WIDTH=1 %i",
                "delete @watch_choice",
                bind,
                "select -assert-count 2 t:$anyconst r:WIDTH=8 %i",
                "select -assert-none t:$anyconst r:WIDTH=1 %i",
                "select -clear",
            )
            model = script[
                script.index("prep -flatten -top coherence_store_home_formal") :
            ]
            positions = [model.index(command) for command in partition]
            assert positions == sorted(positions)
            assert positions[-1] < model.index("memory_map -keepdc")
            assert model.index("peepopt") < model.index("techmap")
            assert model.index("techmap") < model.index("setundef -anyseq")
            assert "select -assert-none t:$check r:FLAVOR=assume %i" in script
            assert "select -assert-none t:$assume" in script
            # The complete configurations differ only by the exhaustive watch value.
            bounded["[script]"] = [line for line in script if line != bind]
            pair.append(bounded)
        assert pair[0] == pair[1]


def test_home_twin_snapshot_budget() -> None:
    """Equivalence construction releases saved copies without changing geometry."""
    for task, blk_floor, all_floor, timeout in (
        ("home_twin_small", 4177, 61950, 600),
        ("home_twin_four", 5261, 112256, 2400),
        ("home_twin_addr40", 4177, 63954, 600),
    ):
        config = formal_task_config("coherence_home_twin", task)
        options = dict(line.split(None, 1) for line in config["[options]"])
        assert options == {"mode": "bmc", "depth": "1", "timeout": str(timeout)}
        assert formal_task_timeout_s("coherence_home_twin", task) == timeout
        script = config["[script]"]
        make = script.index("equiv_make gold gate equiv")
        for variant in ("gold", "gate"):
            copy = f"design -copy-from {variant} -as {variant} {variant}"
            release = f"design -delete {variant}"
            assert script.index(copy) < script.index(release) < make
        assert f"select -assert-min {blk_floor} @blk" in script
        assert f"select -assert-min {all_floor} t:$equiv" in script
        assert "equiv_simple" in script
        assert "equiv_status -assert" in script
        if task == "home_twin_four":
            geometry = (
                "chparam -set CACHE_BYTES 1024 -set WAYS 4 -set ULTRA 1 "
                "-set COMPLETIONS 4 -set RESULTS 3 -set FILLS 3 "
                "-set PREFETCH_RESERVE 1 -set PREFETCH_SLOTS 0 coherence_home"
            )
            assert script.count(geometry) == 2


def test_home_shard_budget() -> None:
    """The complete home task limits and image setup fit their CI jobs."""
    import yaml
    from _pytest.mark.expression import Expression

    root = Path(__file__).resolve().parents[1]
    workflow = yaml.safe_load((root / ".github/workflows/ci.yml").read_text())
    shards = workflow["jobs"]["test-formal"]["strategy"]["matrix"]["include"]
    home = next(target for target in FORMAL_TARGETS if target.name == "coherence_home")
    all_selected: list[tuple[str, str]] = []
    setup_seconds = 20 * 60
    for shard_name in ("Coherence home", "Coherence home fast"):
        shard = next(row for row in shards if row["shard"] == shard_name)
        expression = Expression.compile(shard["pytest_filter"])
        selected = []
        for target in FORMAL_TARGETS:
            for task in target.tasks:
                node = f"{target.name}_{task}"

                def matches_keyword(
                    keyword: str, /, **kwargs: str | int | bool | None
                ) -> bool:
                    assert not kwargs
                    return keyword.casefold() in node.casefold()

                if expression.evaluate(matches_keyword):
                    selected.append((target.name, task))
        assert selected, shard_name
        limits = []
        for target_name, task in selected:
            options = {
                key: value
                for key, value in (
                    line.split(None, 1)
                    for line in formal_task_config(target_name, task)["[options]"]
                )
            }
            limit = formal_task_timeout_s(target_name, task)
            sby_limit = int(options.get("timeout", str(limit)))
            if (target_name, task) in SBY_TASK_TIMEOUT_OVERRIDES_S:
                assert sby_limit == limit, task
            limits.append(min(sby_limit, limit))
        assert sum(limits) + setup_seconds <= shard["timeout_minutes"] * 60
        all_selected.extend(selected)
    assert sorted(all_selected) == sorted((home.name, task) for task in home.tasks)


def l1d_task_config(task: str) -> dict[str, list[str]]:
    """Return a coherence_l1d.sby task's resolved sections, without comments."""
    return formal_task_config("coherence_l1d", task)


def normalize_axi_bridge_post_map_count(commands: list[str], task: str) -> None:
    """Check the exact mapped-property guard before comparing partition models."""
    # The four-burst partitions cover all 139 assertions. The eight-burst
    # partitions check exact membership before mapping and a nonzero floor after.
    counts = {
        "prove_soc": ("-assert-count", 138),
        "prove_soc_held": ("-assert-count", 1),
        **{f"prove_soc8_{index}": ("-assert-min", 1) for index in range(9)},
    }
    kind, count = counts[task]
    map_command = "techmap -max_iter 1 -map %assertion_map"
    assert commands.count(map_command) == 1
    after_map = commands.index(map_command) + 1
    assert commands[after_map:] == [
        "opt_clean",
        "select -assert-none t:axi_coherent_bridge_checked_assert",
        f"select {kind} {count} t:$assert",
        "select -clear",
    ]
    commands[after_map + 2] = f"select {kind} <partition-count> t:$assert"


def test_axi_bridge_post_map_count_rejects_another_selection() -> None:
    """The count guard must still select the mapped assertions."""
    commands = formal_task_config("axi_coherent_bridge", "prove_soc")["[script]"]
    index = commands.index("select -assert-count 138 t:$assert")
    commands[index] = "select -assert-count 138 t:$assume"
    with pytest.raises(AssertionError):
        normalize_axi_bridge_post_map_count(commands, "prove_soc")


@pytest.mark.parametrize(
    ("source", "old", "new"),
    [
        pytest.param("", "", "", id="reviewed-model"),
        pytest.param("sby", "depth 5", "depth 5\nbmc_operands: depth 1", id="depth"),
        pytest.param(
            "sby",
            "[files]",
            "[files]\nspare.sv ../hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv\n\n[files]",
            id="earlier-files-section",
        ),
        pytest.param(
            "sby", "mode bmc", "mode bmc\nexpect PASS,UNKNOWN,TIMEOUT", id="expect"
        ),
        pytest.param(
            "sby",
            "[files]",
            "bmc_cdb: delete c:p_twin_cdb\n[files]",
            id="delete-after-count",
        ),
        pytest.param(
            "sby",
            "[files]",
            " chformal -assert2assume c:p_twin_cdb\n[files]",
            id="assert-to-assume",
        ),
        pytest.param(
            "sby",
            "rs_payload_twin_formal.sv\nfree_undefined.ys",
            "other.sv\nfree_undefined.ys",
            id="source-file",
        ),
        pytest.param(
            "sv",
            "p_twin_operand_int_src1 :",
            "p_twin_operand_renamed :",
            id="operand-label",
        ),
        pytest.param(
            "sv",
            "assert (o_cdb_a.valid == o_cdb_b.valid);\n    if (o_cdb_a.valid) p_twin_cdb :",
            "p_twin_cdb : assert (o_cdb_a.valid == o_cdb_b.valid);\n    if (o_cdb_a.valid)",
            id="packet-label-on-valid",
        ),
        pytest.param("sv", "o_cdb_a == o_cdb_b", "o_cdb_a == o_cdb_a", id="packet-rhs"),
        pytest.param(
            "sv",
            "if (o_trap_pending_a) assert (o_trap_pc_a",
            "assert (o_trap_pc_a",
            id="missing-qualifier",
        ),
        pytest.param(
            "sv",
            "if (o_cmo_valid_a) p_twin_cmo_kind :",
            "p_twin_cmo_kind :",
            id="cmo-kind-without-valid",
        ),
        pytest.param(
            "sv",
            "o_cmo_addr_a == o_cmo_addr_b",
            "o_cmo_addr_a == o_cmo_addr_a",
            id="cmo-address-rhs",
        ),
        pytest.param(
            "sby",
            "cmo: depth 6",
            "cmo: depth 5",
            id="cmo-before-request",
        ),
        pytest.param(
            "sby",
            "cover_cmo_request: mode cover",
            "cover_cmo_request: mode bmc",
            id="request-cover-mode",
        ),
        pytest.param(
            "sby",
            "cover_cmo_request cmo\n",
            "",
            id="request-cover-missing-task",
        ),
        pytest.param(
            "sv",
            "cover (o_cmo_valid_a && o_cmo_valid_b)",
            "cover (o_cmo_valid_a || o_cmo_valid_b)",
            id="request-cover-requires-both-copies",
        ),
    ],
)
def test_rs_payload_twin_assertion_groups(
    source: str, old: str, new: str, tmp_path: Path
) -> None:
    """Check the six assertion groups, the request cover and their guarded properties."""
    from hashlib import sha256

    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    sby = formal / "rs_payload_twin.sby"
    harness = (formal / "rs_payload_twin_formal.sv").read_text()
    if source == "sby":
        original = sby.read_text()
        assert original.count(old) == 1
        sby = sby_config.stage_proof(sby, formal.parent, tmp_path)
        sby.write_text(original.replace(old, new))
    elif source == "sv":
        assert harness.count(old) == 1
        harness = harness.replace(old, new)

    packets = {
        "bmc_cdb": "cdb",
        "bmc_cdb_2": "cdb_2",
        "bmc_commit": "commit_comb",
        "bmc_commit_2": "commit_comb_2",
    }
    operands = """
        bypass_value_1 bypass_value_2 bypass_value_3 bypass_value_4 bypass_value_5
        bypass_value_6 int_src1 int_src2 fp_src1 fp_src2 fp_src3 int_src1_2
        int_src2_2 fp_src1_2 fp_src2_2 fp_src3_2
    """.split()
    # Port names use the wrapper spelling before the copy suffix and any field.
    general = {
        "": """
            coherent_sc_valid coherent_sc_result_ready coherent_reservation_valid
            coherent_arm_valid coherent_read_kind coherent_read_tag coherent_write_sc
            coherent_write_zero coherent_sq_write_tag coherent_amo_write_tag alloc_resp
            alloc_resp_2 cdb_grant cdb.valid cdb_2.valid commit.valid vcfg_commit.valid
            vcfg_in_flight commit_comb.valid commit_valid_raw commit_misprediction_raw
            commit_correct_branch_raw commit_correct_branch_2_raw
            head_commit_misprediction_candidate commit_2.valid commit_comb_2.valid
            commit_2_valid_raw csr_start trap_pending head_is_wfi head_is_amo
            head_mem_funct3 head_mem_rs2 head_dest_reg head_dest_rf head_dest_valid
            head_mem_store head_mem_fp_store head_mem_atomic head_fallthrough_pc
            head_bypass_int_we_early head_bypass_fp_we_early
            head_next_bypass_int_we_early head_next_bypass_fp_we_early
            head_dir_train_early head_branch_taken_early head_next_dir_train_early
            head_next_branch_taken_early head_retired_next_pc head_next_retired_next_pc
            head_bus_fault mret_start mret_start_is_sret mret_start_is_dret
            tlb_invalidate tlb_flush walk_req_valid walk_hold coh_admit_ready
            coh_admit_clean coh_inval_done fence_i_sync_req fence_i_flush
            fence_class_flush_event translation_csr_commit_shadow sq_committed_empty
            sq_committed_empty_trap rob_full rob_full_for_2 rob_empty rob_count head_tag
            head_valid head_done rob_entry_done_vec ras_tos ras_valid_count ras_top
            checkpoint_available checkpoint_alloc_id rs_full rs_issue.valid
            rs_issue_branch_predicate_tag int_rs_full int_rs_full_for_2 rs_empty
            rs_count mul_rs_issue.valid mul_rs_full mul_rs_full_for_2 mul_rs_empty
            mul_rs_count mem_rs_issue.valid mem_rs_full mem_rs_full_for_2 mem_rs_empty
            mem_rs_count fp_rs_issue.valid fp_rs_full fp_rs_full_for_2 fp_rs_empty
            fp_rs_count sq_mem_write_en uncached_store_pending lq_mem_read_en
            lq_mem_addr_valid lq_full lq_full_for_2 lq_empty lq_count sq_full
            sq_full_for_2 sq_empty sq_count amo_mem_write_en perf_counter_data
            perf_mem_rs_two_ready_one_issued perf_cdb_oversubscribed
        """.split(),
        "o_coherent_sc_valid_a": [
            "coherent_sc_addr",
            "coherent_sc_size",
            "coherent_sc_tag",
        ],
        "o_coherent_reservation_valid_a": [
            "coherent_reservation_addr",
            "coherent_reservation_size",
        ],
        "o_coherent_arm_valid_a": ["coherent_arm_tag"],
        "o_commit_a.valid": ["commit"],
        "o_vcfg_commit_a.valid": ["vcfg_commit"],
        "o_commit_2_a.valid": ["commit_2"],
        "o_trap_pending_a": ["trap_pc", "trap_cause", "trap_value", "trap_insn"],
        "o_head_bus_fault_a": ["head_bus_fault_va"],
        "o_walk_req_valid_a": ["walk_vpn"],
        "o_rs_issue_a.valid": ["rs_issue"],
        "o_mul_rs_issue_a.valid": ["mul_rs_issue"],
        "o_mem_rs_issue_a.valid": ["mem_rs_issue"],
        "o_fp_rs_issue_a.valid": ["fp_rs_issue"],
        "o_sq_mem_write_en_a": [
            "sq_mem_write_addr",
            "sq_mem_write_data",
            "sq_mem_write_byte_en",
            "sq_mem_write_buffered",
            "sq_mem_write_size",
            "sq_mem_write_is_mmio",
            "sq_mem_write_is_cached",
        ],
        "o_lq_mem_read_en_a": [
            "lq_mem_read_addr",
            "lq_mem_read_size",
            "lq_mem_read_id",
            "lq_mem_read_no_merge",
        ],
        "o_amo_mem_write_en_a": [
            "amo_mem_write_addr",
            "amo_mem_write_data",
            "amo_mem_write_is_dword",
            "amo_mem_write_is_cached",
        ],
    }
    cmo = {"cmo_valid": "", "cmo_kind": "o_cmo_valid_a", "cmo_addr": "o_cmo_valid_a"}
    counts = {
        "bmc": 152,
        "bmc_cdb": 1,
        "bmc_cdb_2": 1,
        "bmc_commit": 1,
        "bmc_commit_2": 4,
        "bmc_operands": 16,
    }
    all_asserts = "t:$check r:FLAVOR=assert %i"
    selections = {
        "bmc": "@packets @operands @cmo",
        "bmc_operands": f"{all_asserts} @operands %d",
        **{task: f"{all_asserts} c:p_twin_{port} %d" for task, port in packets.items()},
    }
    selections["bmc_commit_2"] = f"{all_asserts} @commit_and_cmo %d"
    model = [
        "read -formal -sv riscv_pkg.sv vec_hold_rows.sv",
        "read -formal -sv sdp_dist_ram.sv",
        "read -formal -sv mwp_dist_ram.sv",
        "read -formal -sv mwp_dist_ram_ohread.sv",
        "read -sv rob_serializer.sv sfence_operand_store.sv",
        "read -sv reorder_buffer.sv",
        "read -sv register_alias_table.sv",
        "read -formal -sv rs_issue2_selector.sv",
        "read -sv coherent_rs_capacity.sv",
        "read -sv coherent_rs_issue2_selector.sv",
        "read -sv coherent_rs_payload_store.sv",
        "read -formal -sv -D RS_STAGE2_PAYLOAD_HAVOC reservation_station.sv",
        "read -sv cdb_arbiter.sv",
        "read -sv fu_cdb_adapter.sv",
        "read -sv int_alu_shim.sv",
        "read -sv int_muldiv_shim.sv",
        "read -sv load_unit.sv",
        "read -sv coherent_l0_flags.sv",
        "read -sv lq_l0_cache.sv",
        "read -sv lq_issue_selector.sv",
        "read -sv coherent_lq_issue_selector.sv",
        "read -sv coherent_lq_candidate_select.sv",
        "read -sv coherent_lq_address_store.sv",
        "read -sv -DFROST_YOSYS load_queue.sv",
        "read -sv sq_forwarding_unit.sv",
        "read -sv store_queue.sv",
        "read -sv dtlb.sv",
        "read -sv dmmu.sv",
        "read -sv tomasulo_perf_counters.sv",
        "read -sv sq_early_addr_pipeline.sv",
        "read -sv commit_bus_pipeline.sv",
        "read -sv dispatch_rs_router.sv",
        "read -sv sc_pending_unit.sv",
        "read -sv coherent_atomic_select.sv",
        "read -formal -sv mem_wakeup_merge.sv",
        "read -sv lq_coherence_port.sv",
        "read -sv divider.sv",
        "read -sv dsp_tiled_multiplier_unsigned.sv",
        "read -sv multiplier.sv cl_multiplier.sv",
        "read -sv alu.sv",
        "read -sv fp_engine.sv",
        "read -formal -D FP_FMA_PIPE_ABSTRACT -sv fp_pipe_lzc.sv fp_fma_pipe.sv",
        "read -sv fp_div_unit.sv",
        "read -sv fp_shim.sv",
        "read -formal -sv tomasulo_wrapper.sv",
        "read -formal -sv rs_payload_twin_formal.sv",
        "hierarchy -top rs_payload_twin_formal",
        *(" ".join(c) for c in UNDEFINED_OPENING),
        "chformal -assert -remove * rs_payload_twin_formal %d",
        "prep -top rs_payload_twin_formal",
        "setattr -mod -unset keep_hierarchy *",
        "flatten",
        "memory_map -keepdc",
        "opt_clean",
        "setundef -zero -init",
        "select -assert-count 112 t:$check r:FLAVOR=assume %i",
        "select -assert-count 175 t:$check r:FLAVOR=assert %i",
        "select -set packets c:p_twin_cdb c:p_twin_cdb_2 c:p_twin_commit_comb c:p_twin_commit_comb_2",
        "select -set operands c:p_twin_operand_*",
        "select -set cmo c:p_twin_cmo_*",
        "select -set commit_and_cmo c:p_twin_commit_comb_2 @cmo",
        "select -assert-count 3 @cmo",
        "select -assert-count 4 @commit_and_cmo",
        "select -assert-count 4 @packets",
        "select -assert-count 16 @operands",
    ]
    files = [
        "../hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv",
        "../hw/rtl/cpu_and_mem/cpu/vector/vec_hold_rows.sv",
        "../hw/rtl/lib/ram/sdp_dist_ram.sv",
        "../hw/rtl/lib/ram/mwp_dist_ram.sv",
        "../hw/rtl/lib/ram/mwp_dist_ram_ohread.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/rob_serializer.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/sfence_operand_store.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/reorder_buffer/reorder_buffer.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/register_alias_table/register_alias_table.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/rs_issue2_selector.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/reservation_station.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/cdb_arbiter/cdb_arbiter.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/fu_cdb_adapter/fu_cdb_adapter.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_alu_shim.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/int_muldiv_shim.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_unit.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_l0_cache.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/lq_issue_selector.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/sq_forwarding_unit.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/store_queue/store_queue.sv",
        "../hw/rtl/cpu_and_mem/cpu/mmu/dtlb.sv",
        "../hw/rtl/cpu_and_mem/cpu/mmu/dmmu.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/perf/tomasulo_perf_counters.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/store_addr/sq_early_addr_pipeline.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/commit_bus/commit_bus_pipeline.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/dispatch_routing/dispatch_rs_router.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/atomics/sc_pending_unit.sv",
        "../hw/rtl/cpu_and_mem/cpu/cpu_ooo/memory_if/coherent_atomic_select.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/wakeup/mem_wakeup_merge.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/coherence/lq_coherence_port.sv",
        "../hw/rtl/cpu_and_mem/cpu/ex_stage/alu/divider.sv",
        "../hw/rtl/cpu_and_mem/cpu/ex_stage/dsp_tiled_multiplier_unsigned.sv",
        "../hw/rtl/cpu_and_mem/cpu/ex_stage/alu/multiplier.sv",
        "../hw/rtl/cpu_and_mem/cpu/ex_stage/cl_multiplier.sv",
        "../hw/rtl/cpu_and_mem/cpu/ex_stage/alu/alu.sv",
        "../hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_engine.sv",
        "../hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_pipe_lzc.sv",
        "../hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_fma_pipe.sv",
        "../hw/rtl/cpu_and_mem/cpu/ex_stage/fpu/fp_div_unit.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/fu_shims/fp_shim.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/coherent_lq_issue_selector.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/coherent_lq_candidate_select.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/coherent_lq_address_store.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/coherent_l0_flags.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/coherent_rs_capacity.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/coherent_rs_issue2_selector.sv",
        "../hw/rtl/cpu_and_mem/cpu/tomasulo/reservation_station/coherent_rs_payload_store.sv",
        "rs_payload_twin_formal.sv",
        "free_undefined.ys",
    ]

    if not source:
        hashes = {
            "rs_payload_twin.sby": "d09dccd46f90225774a5c354cd7b7347cd24963d12ffac1f4316830d898ad625",
            "rs_payload_twin_formal.sv": "bf55b92f3eb8eda22aef16b2268c2a1c1f458f946711b536cdc397fbb008ae61",
            "free_undefined.ys": "d9383d13eaa8e490ab3671853c1390d92160abbfa19ca0d93fdf40138549e7d6",
        }
        procedure = (
            "For a deliberate edit, run python3 tests/rs_payload_twin_partition.py "
            "in the formal image, review the compiled partition, then update the "
            "expected comparisons and SHA-256 hashes."
        )
        design_rtl = formal.parent / "hw/rtl"
        non_rtl = {
            entry
            for entry in files
            if not (formal / entry).resolve().is_relative_to(design_rtl)
        }
        assert hashes.keys() == {sby.name, *non_rtl}, procedure
        for name, digest in hashes.items():
            assert sha256((formal / name).read_bytes()).hexdigest() == digest, (
                f"{name} changed. {procedure}"
            )

    def check() -> None:
        assert not sby_tag_gaps(sby)
        # Check every source in the untagged file section.
        entries = [line.strip() for line in sby_config.source(sby).sections["files"]]
        assert [line for line in entries if line and not line.startswith("#")] == files
        try:
            configs = sby_config.resolved(sby)
        except sby_config.ConfigError as error:
            raise AssertionError(str(error)) from error
        cover_task = "cover_cmo_request"
        assert configs.keys() == {*counts, cover_task}
        cover = configs[cover_task].sections(formal)
        second_commit = configs["bmc_commit_2"].sections(formal)
        assert cover == {
            "[options]": ["mode cover", "depth 6"],
            "[engines]": ["smtbmc boolector"],
            "[script]": [
                *second_commit["[script]"],
                "chformal -cover -remove t:$check r:FLAVOR=cover %i c:c_twin_cmo_request %d",
                "select -assert-count 1 t:$check r:FLAVOR=cover %i",
            ],
            "[files]": files,
        }
        for task, count in counts.items():
            try:
                config = configs[task].sections(formal)
            except sby_config.ConfigError as error:
                raise AssertionError(str(error)) from error
            depth = 6 if task == "bmc_commit_2" else 5
            options = ["mode bmc", f"depth {depth}"]
            engine = "smtbmc boolector"
            cover_check = []
            if task == "bmc_commit_2":
                cover_check = [
                    "select -assert-count 1 c:c_twin_cmo_request t:$check %i r:FLAVOR=cover %i"
                ]
            if task in packets:
                options.append("vcd_sim on")
                engine = "btor btormc"
            assert config == {
                "[options]": options,
                "[engines]": [engine],
                "[script]": [
                    *model,
                    *cover_check,
                    "chformal -assert -remove " + selections[task],
                    f"select -assert-count {count} {all_asserts}",
                ],
                "[files]": files,
            }, task

        # Key by the complete property, including both sides of the comparison.
        expected: dict[tuple[str, str, str, str], str] = {}

        def record(task: str, qualifier: str, label: str, port: str) -> None:
            name, dot, field = port.partition(".")
            lhs = f"o_{name}_a{dot}{field}"
            rhs = f"o_{name}_b{dot}{field}"
            expected[qualifier, label, lhs, rhs] = task

        for qualifier, ports in general.items():
            for port in ports:
                record("bmc", qualifier, "", port)
        for task, port in packets.items():
            record(task, f"o_{port}_a.valid", f"p_twin_{port}", port)
        for port, qualifier in cmo.items():
            record("bmc_commit_2", qualifier, f"p_twin_{port}", port)
        for port in operands:
            record("bmc_operands", "", f"p_twin_operand_{port}", port)

        # Consume complete statements so a nested condition or trailing expression
        # cannot disappear between two matched assertions.
        body = re.sub(r"//[^\n]*|/\*.*?\*/", " ", harness, flags=re.DOTALL)
        assert re.findall(
            r"\bc_twin_cmo_request\s*:\s*cover\s*\(([^;]+)\)\s*;", body
        ) == ["o_cmo_valid_a && o_cmo_valid_b"]
        assert len(re.findall(r"\bassert\s*\(", body)) == 175
        block = re.search(
            r"\balways_comb\s+begin\b(.*?)\bend\s+endmodule\s*:\s*rs_payload_twin_formal\s*\Z",
            body,
            re.DOTALL,
        )
        assert block is not None
        statements = block[1].strip().split(";")
        assert statements.pop() == ""
        assert len(statements) == len(expected) == sum(counts.values()) == 175
        comparison = re.compile(
            r"(?:if\s*\(\s*([\w.]+)\s*\)\s*)?(?:(\w+)\s*:\s*)?"
            r"assert\s*\(\s*([\w.]+)\s*==\s*([\w.]+)\s*\)"
        )
        owners = {
            "": "bmc",
            **{f"p_twin_{p}": t for t, p in packets.items()},
            **{f"p_twin_{p}": "bmc_commit_2" for p in cmo},
            **{f"p_twin_operand_{p}": "bmc_operands" for p in operands},
        }
        actual: dict[tuple[str, str, str, str], str] = {}
        for statement in statements:
            match = comparison.fullmatch(statement.strip())
            assert match is not None, statement
            qualifier, label, lhs, rhs = match.groups(default="")
            assert label in owners, label
            actual[qualifier, label, lhs, rhs] = owners[label]
        assert actual == expected
        assert {task: list(actual.values()).count(task) for task in counts} == counts

    if source:
        with pytest.raises(AssertionError):
            check()
    else:
        check()


def test_axi_bridge_partitions_share_model_and_history() -> None:
    """Partitions of each configuration share one model and history contract."""
    families = [
        (
            ["prove_soc", "prove_soc_held"],
            ["other", "held"],
            "select -assert-count 1 @held",
            {},
        ),
        (
            [f"prove_soc8_{index}" for index in range(9)],
            [f"group{index}" for index in range(9)],
            "select -assert-none @remaining",
            {"timeout": "1800"},
        ),
    ]
    for tasks, groups, guard, options in families:
        reference = formal_task_config("axi_coherent_bridge", tasks[0])
        normalize_axi_bridge_post_map_count(reference["[script]"], tasks[0])
        for task, group in zip(tasks, groups, strict=True):
            config = formal_task_config("axi_coherent_bridge", task)
            assert dict(line.split(maxsplit=1) for line in config["[options]"]) == {
                "mode": "prove",
                "depth": "3",
                **options,
            }
            commands = config["[script]"]
            normalize_axi_bridge_post_map_count(commands, task)
            choose = f"chtype -set axi_coherent_bridge_checked_assert @{group}"
            assert commands.count(choose) == 1
            assert (
                commands.index(guard)
                < commands.index(choose)
                < commands.index("techmap -max_iter 1 -map %assertion_map")
            )
            config["[script]"] = [
                f"chtype -set axi_coherent_bridge_checked_assert @{groups[0]}"
                if line == choose
                else line
                for line in commands
            ]
            assert config == reference


def assertion_command(line: str) -> bool:
    """Report whether an SBY script line selects or converts properties."""
    return line.startswith(("select -assert-", "chformal "))


def test_zero_payload_partition_models_match() -> None:
    """Keep zero control and byte payload checks at depth 40 without added assumptions."""
    control = l1d_task_config("coh_l1d_zero_bmc")
    payload = l1d_task_config("coh_l1d_zero_payload_bmc")
    control_commands = [
        "select -assert-count 1 c:p_prefetch_conflict_split t:$check %i r:FLAVOR=assert %i",
        "chformal -assert2assume c:p_prefetch_conflict_split",
        "select -assert-min 1 c:p_zero_* t:$check %i r:FLAVOR=assert %i",
    ]
    data = " ".join(f"c:p_store_data_{index}" for index in range(1, 6))
    payload_commands = [
        f"select -assert-count 5 {data}",
        f"chformal -assert -remove t:$check r:FLAVOR=assert %i {data} %u %u %u %u %d",
        "select -assert-count 5 t:$check r:FLAVOR=assert %i",
    ]

    def validate(part: dict[str, list[str]]) -> None:
        assert part.keys() == control.keys()
        for section in part.keys() - {"[options]", "[engines]", "[script]"}:
            assert part[section] == control[section]
        assert [
            line for line in control["[script]"] if assertion_command(line)
        ] == control_commands
        assert [
            line for line in part["[script]"] if assertion_command(line)
        ] == payload_commands
        assert [
            line.replace(" -D STORE_DATA_PROOF", "")
            for line in part["[script]"]
            if not assertion_command(line)
        ] == [line for line in control["[script]"] if not assertion_command(line)]
        control_options = dict(line.split(maxsplit=1) for line in control["[options]"])
        payload_options = dict(line.split(maxsplit=1) for line in part["[options]"])
        assert control_options["mode"] == "bmc" and control_options["depth"] == "40"
        assert payload_options == control_options | {"timeout": "5400"}
        assert part["[engines]"] == ["abc bmc3 -c"]

    validate(payload)
    for section, line in (
        ("[script]", "chformal -assert2assume c:p_zero_twin_install"),
        ("[script]", "chformal -assert -remove c:p_store_data_5"),
        ("[script]", "cutpoint w:image_q"),
        ("[script]", "connect -set i_write_zero 1'b0"),
        ("[options]", "depth 39"),
        ("[options]", "expect PASS,UNKNOWN,TIMEOUT"),
        ("[file partition_only.smtc]", "assume (= hidden 0)"),
    ):
        altered = {key: list(value) for key, value in payload.items()}
        altered.setdefault(section, []).append(line)
        with pytest.raises(AssertionError):
            validate(altered)


def test_zero_safety_models_reject_cover_constraints() -> None:
    """Pin each safety environment independently of the cover's reference model."""
    reads = [
        "read -sv coherence_read_stream.sv",
        "read -sv cache_perf_pkg.sv",
        "read -sv coherence_pkg.sv",
        "read -sv coherence_request_endpoint.sv",
        "read -sv coherence_put_endpoint.sv coherence_read_owners.sv "
        "coherence_miss_credit.sv coherence_read_flags.sv "
        "coherence_grant_select.sv coherence_read_select.sv",
    ]
    files = (
        [
            "../hw/rtl/lib/cache/coherence_read_stream.sv",
            "../hw/rtl/lib/ram/sdp_block_ram.sv",
            "../hw/rtl/lib/ram/sdp_packed_tag_uram.sv",
            "../hw/rtl/lib/ram/sdp_ram_byte_en.sv",
        ]
        + [
            f"../hw/rtl/lib/cache/{name}"
            for name in (
                "coherence_pkg.sv",
                "coherence_types.svh",
                "coherence_array.sv",
                "coherence_request_endpoint.sv",
                "coherence_put_endpoint.sv",
                "coherence_l1d.sv",
                "coherence_read_owners.sv",
                "coherence_miss_credit.sv",
                "coherence_read_flags.sv",
                "coherence_grant_select.sv",
                "coherence_read_select.sv",
                "coherence_read_payload.sv",
                "cache_perf_pkg.sv",
                "coherence_store_buffer.sv",
            )
        ]
        + ["free_undefined.ys"]
    )
    control_properties = [
        "select -assert-count 1 c:p_prefetch_conflict_split t:$check %i r:FLAVOR=assert %i",
        "chformal -assert2assume c:p_prefetch_conflict_split",
        "select -assert-min 1 c:p_zero_* t:$check %i r:FLAVOR=assert %i",
    ]
    data = " ".join(f"c:p_store_data_{index}" for index in range(1, 6))
    payload_properties = [
        f"select -assert-count 5 {data}",
        f"chformal -assert -remove t:$check r:FLAVOR=assert %i {data} %u %u %u %u %d",
        "select -assert-count 5 t:$check r:FLAVOR=assert %i",
    ]
    # The hinted single-property stream tasks: the same-block twin rule, and
    # upper-sector request exclusion one holding endpoint at a time, with
    # endpoint 1's case split by the operation in operation_q.
    ep1_parts = {
        "read": " -D ZERO_UPPER_OP=ReadOp",
        "store": " -D ZERO_UPPER_OP=StoreOp",
        "lookahead": " -D ZERO_UPPER_OP=LookaheadOp",
        "prefetch": " -D ZERO_UPPER_OP=PrefetchOp",
        "rest": " -D ZERO_UPPER_OP_REST",
    }
    hinted = {
        "stream_line_bmc": ("c:p_zero_acquire_line", ""),
        **{
            f"stream_upper_ep{ep}_bmc": (
                "c:p_zero_no_upper_request_ep",
                f" -D ZERO_UPPER_EP={ep}",
            )
            for ep in (0, 2)
        },
        **{
            f"stream_upper_ep1_{part}_bmc": (
                "c:p_zero_no_upper_request_ep",
                f" -D ZERO_UPPER_EP=1{define}",
            )
            for part, define in ep1_parts.items()
        },
    }
    for suffix, depth, timeout, engine in (
        ("bmc", "40", "10800", "abc bmc3 -g"),
        ("multi_bmc", "30", "18000", "abc bmc3 -c"),
        ("payload_bmc", "40", "5400", "abc bmc3 -c"),
        ("stream_hint_bmc", "31", "1200", "abc bmc3 -c"),
        ("stream_line_bmc", "31", "3600", "abc bmc3 -g"),
        ("stream_upper_ep0_bmc", "31", "6120", "abc bmc3 -c"),
        ("stream_upper_ep1_read_bmc", "31", "2100", "abc bmc3 -g"),
        ("stream_upper_ep1_store_bmc", "31", "600", "abc bmc3 -g"),
        ("stream_upper_ep1_lookahead_bmc", "31", "300", "abc bmc3 -g"),
        ("stream_upper_ep1_prefetch_bmc", "31", "300", "abc bmc3 -g"),
        ("stream_upper_ep1_rest_bmc", "31", "300", "abc bmc3 -g"),
        ("stream_upper_ep2_bmc", "31", "1500", "abc bmc3 -g"),
    ):
        payload = suffix == "payload_bmc"
        hint = suffix == "stream_hint_bmc"
        turn = hint or suffix in hinted
        define = " -D STORE_DATA_PROOF" if payload else ""
        if suffix in hinted:
            define = hinted[suffix][1]
        endpoints = " -set MISSES 3" if turn or suffix == "multi_bmc" else ""
        properties = control_properties
        if payload:
            properties = payload_properties
        if hint:
            # The two original stream properties, with the hints free.
            check = "c:p_prefetch_not_record c:p_grant_keeps_modified"
            properties = [
                f"select -assert-count 2 {check}",
                f"chformal -assert -remove t:$check r:FLAVOR=assert %i {check} %u %d",
                "select -assert-count 2 t:$check r:FLAVOR=assert %i",
                "check -assert",
            ]
        if suffix in hinted:
            check = hinted[suffix][0]
            properties = [
                f"select -assert-count 1 {check}",
                f"chformal -assert -remove t:$check r:FLAVOR=assert %i {check} %d",
                "select -assert-count 1 t:$check r:FLAVOR=assert %i",
                "check -assert",
            ]
        script = (
            reads
            + [
                f"read -formal -sv -D ZERO_WRITES{define} coherence_read_payload.sv coherence_l1d.sv",
                "read -sv coherence_store_buffer.sv",
                "read -sv sdp_block_ram.sv sdp_packed_tag_uram.sv sdp_ram_byte_en.sv coherence_array.sv",
                f"chparam -set CACHE_BYTES 64 -set WAYS 1 -set TAG_BITS 2{endpoints} coherence_l1d",
            ]
            + (["chparam -set STREAM_PREFETCH 1 coherence_l1d"] if turn else [])
            + [
                "hierarchy -top coherence_l1d",
                *(" ".join(c) for c in UNDEFINED_OPENING),
                "prep -flatten -top coherence_l1d",
            ]
            + properties
            + [
                "memory_map",
                "opt",
                "techmap",
                "opt -fast",
                "setundef -anyseq",
                "opt_clean",
            ]
        )

        def validate(task: dict[str, list[str]]) -> None:
            assert task.keys() == {"[options]", "[engines]", "[script]", "[files]"}
            assert dict(line.split(maxsplit=1) for line in task["[options]"]) == {
                "mode": "bmc",
                "depth": depth,
                "timeout": timeout,
                "aigsmt": "boolector",
            }
            assert task["[engines]"] == [engine]
            assert task["[script]"] == script
            assert task["[files]"] == files

        safety = l1d_task_config(f"coh_l1d_zero_{suffix}")
        validate(safety)
        for section, line in (
            ("[script]", "connect -set i_address 32'h80000000"),
            ("[script]", "connect -set i_rst 1'b0"),
            ("[script]", "connect -set i_write_more 1'b0"),
            ("[script]", "connect -set i_next_same 1'b0"),
            ("[script]", "delete -input w:i_rst"),
            ("[script]", "cutpoint w:phase_q"),
            ("[script]", "chformal -assume -remove"),
            ("[script]", "chformal -assert2assume c:p_zero_twin_install"),
            ("[script]", "chformal -assert -remove c:p_zero_no_upper_request"),
            ("[options]", f"depth {int(depth) - 1}"),
            ("[options]", "skip 48"),
            ("[options]", "smtc hidden.smtc"),
            ("[engines]", "smtbmc boolector --smtc hidden.smtc"),
            ("[files]", "hidden.smtc"),
            ("[file hidden.smtc]", "assume (= hidden 0)"),
        ):
            altered = {key: list(value) for key, value in safety.items()}
            altered.setdefault(section, []).append(line)
            with pytest.raises(AssertionError):
                validate(altered)


def _zero_upper_tasks() -> dict[str, str]:
    """Map each upper-sector request exclusion task to its model's read and chparam lines."""
    root = Path(__file__).resolve().parents[1]
    tasks = sby_config.source(root / "formal" / "coherence_l1d.sby").tasks
    names = [
        name
        for name in tasks
        if re.fullmatch(r"coh_l1d_zero_stream_upper_ep\w+_bmc", name)
    ]
    result = {}
    for name in names:
        script = l1d_task_config(name)["[script]"]
        reads = [
            line for line in script if "coherence_l1d.sv" in line and "-D " in line
        ]
        assert len(reads) == 1, name
        result[name] = (
            reads[0]
            + " "
            + " ".join(line for line in script if line.startswith("chparam "))
        )
    return result


def test_zero_upper_endpoint_one_parts_cover_every_operation() -> None:
    """Check that endpoint 1's rest part excludes exactly the other parts' operations."""
    root = Path(__file__).resolve().parents[1]
    rtl = (root / "hw/rtl/lib/cache/coherence_l1d.sv").read_text()
    match = re.search(
        r"`ifdef ZERO_UPPER_OP\n(?P<one>.*?)`elsif ZERO_UPPER_OP_REST\n"
        r"(?P<rest>.*?)`else\n(?P<all>.*?)`endif\n",
        rtl,
        flags=re.DOTALL,
    )
    assert match
    one, rest, everything = (
        " ".join(match[group].split()) for group in ("one", "rest", "all")
    )
    # Every branch checks the same request condition: the one-operation branch
    # adds a match on the operation and the rest branch one exclusion for each
    # operation the other parts name.
    assert one == everything.replace(
        ") p_zero_no_upper_request_ep",
        " && operation_q == `ZERO_UPPER_OP) p_zero_no_upper_request_ep",
        1,
    )
    excluded = re.findall(r" && operation_q != (\w+)", rest)
    assert len(excluded) == len(set(excluded))
    stripped = rest
    for name in excluded:
        stripped = stripped.replace(f" && operation_q != {name}", "", 1)
    assert stripped == everything
    parts = {}
    for name, model in _zero_upper_tasks().items():
        if "ZERO_UPPER_EP=1" not in model:
            continue
        operations = re.findall(r"-D ZERO_UPPER_OP=(\w+)", model)
        if operations:
            assert len(operations) == 1, name
            parts[name] = operations[0]
        else:
            assert "-D ZERO_UPPER_OP_REST" in model, name
            assert name.endswith("_rest_bmc"), name
    assert len(parts) == 4
    assert sorted(excluded) == sorted(parts.values())


def test_zero_upper_endpoint_tasks_cover_every_endpoint() -> None:
    """Check that the holding-endpoint tasks name every endpoint index of their model."""
    endpoints: set[int] = set()
    sizes: set[int] = set()
    for name, model in _zero_upper_tasks().items():
        holders = re.findall(r"-D ZERO_UPPER_EP=(\d+)", model)
        assert len(holders) == 1, name
        endpoints.add(int(holders[0]))
        misses = re.findall(r"-set MISSES (\d+)", model)
        assert len(misses) == 1, name
        sizes.add(int(misses[0]))
    assert len(sizes) == 1
    assert endpoints == set(range(sizes.pop()))


# The zero stream model: three endpoints with stream prefetching, cbo.zero
# writes and full-line stores, and its four properties.
ZERO_STREAM_PROPERTIES = (
    "p_prefetch_not_record",
    "p_grant_keeps_modified",
    "p_zero_acquire_line",
    "p_zero_no_upper_request",
)
ZERO_STREAM_ENDPOINTS = 3
# The upper-request case macros: the holding endpoint, optionally narrowed to
# one operation in operation_q or to the operations no one-operation case names.
_ZERO_UPPER_CASE_DEFINE = re.compile(r" -D ZERO_UPPER_(?:EP=\d+|OP=\w+|OP_REST)\b")


def zero_stream_selection(names: list[str]) -> list[str]:
    """Return the script lines that keep exactly the named assertions."""
    kept = " ".join(f"c:{name}" for name in names)
    unions = " %u" * (len(names) - 1)
    return [
        f"select -assert-count {len(names)} {kept}",
        f"chformal -assert -remove t:$check r:FLAVOR=assert %i {kept}{unions} %d",
        f"select -assert-count {len(names)} t:$check r:FLAVOR=assert %i",
        "check -assert",
    ]


def zero_stream_checks(config: dict[str, list[str]]) -> set[tuple[str | int, ...]]:
    """Return what a task checks on the zero stream model with the store queue's hints free.

    A task counts only as a bounded check of depth 31 or more whose script is
    exactly the model's apart from its assertion selection and the
    upper-request case macros: no tie-off, cutpoint, assumption change or
    other added line. Each check is ``(property,)``, or
    ``("p_zero_no_upper_request", endpoint, operation)`` for one case of that
    property, with operation ``""`` for the whole endpoint case and ``"rest"``
    for the operations that no one-operation case names.
    """
    model = [
        "read -sv coherence_read_stream.sv",
        "read -sv cache_perf_pkg.sv",
        "read -sv coherence_pkg.sv",
        "read -sv coherence_request_endpoint.sv",
        "read -sv coherence_put_endpoint.sv coherence_read_owners.sv "
        "coherence_miss_credit.sv coherence_read_flags.sv "
        "coherence_grant_select.sv coherence_read_select.sv",
        "read -formal -sv -D ZERO_WRITES coherence_read_payload.sv coherence_l1d.sv",
        "read -sv coherence_store_buffer.sv",
        "read -sv sdp_block_ram.sv sdp_packed_tag_uram.sv sdp_ram_byte_en.sv coherence_array.sv",
        "chparam -set CACHE_BYTES 64 -set WAYS 1 -set TAG_BITS 2 "
        f"-set MISSES {ZERO_STREAM_ENDPOINTS} coherence_l1d",
        "chparam -set STREAM_PREFETCH 1 coherence_l1d",
        "hierarchy -top coherence_l1d",
        *(" ".join(c) for c in UNDEFINED_OPENING),
        "prep -flatten -top coherence_l1d",
        "memory_map",
        "opt",
        "techmap",
        "opt -fast",
        "setundef -anyseq",
        "opt_clean",
    ]
    files = (
        [
            "../hw/rtl/lib/cache/coherence_read_stream.sv",
            "../hw/rtl/lib/ram/sdp_block_ram.sv",
            "../hw/rtl/lib/ram/sdp_packed_tag_uram.sv",
            "../hw/rtl/lib/ram/sdp_ram_byte_en.sv",
        ]
        + [
            f"../hw/rtl/lib/cache/{name}"
            for name in (
                "coherence_pkg.sv",
                "coherence_types.svh",
                "coherence_array.sv",
                "coherence_request_endpoint.sv",
                "coherence_put_endpoint.sv",
                "coherence_l1d.sv",
                "coherence_read_owners.sv",
                "coherence_miss_credit.sv",
                "coherence_read_flags.sv",
                "coherence_grant_select.sv",
                "coherence_read_select.sv",
                "coherence_read_payload.sv",
                "cache_perf_pkg.sv",
                "coherence_store_buffer.sv",
            )
        ]
        + ["free_undefined.ys"]
    )
    options = dict(line.split(maxsplit=1) for line in config.get("[options]", []))
    if options.get("mode") != "bmc" or int(options.get("depth", "0")) < 31:
        return set()
    if config.get("[files]") != files:
        return set()
    script = config.get("[script]", [])
    selection = [
        line for line in script if assertion_command(line) or line == "check -assert"
    ]
    others = [line for line in script if line not in selection]
    if [_ZERO_UPPER_CASE_DEFINE.sub("", line) for line in others] != model:
        return set()
    removals = [line for line in selection if line.startswith("chformal ")]
    if len(removals) != 1:
        return set()
    names = [token[2:] for token in removals[0].split() if token.startswith("c:")]
    if selection != zero_stream_selection(names):
        return set()
    read = next(line for line in others if "coherence_l1d.sv" in line)
    endpoint = re.findall(r" -D ZERO_UPPER_EP=(\d+)\b", read)
    operation = re.findall(r" -D ZERO_UPPER_OP=(\w+)", read)
    rest = " -D ZERO_UPPER_OP_REST" in read
    checks: set[tuple[str | int, ...]] = set()
    for name in names:
        if name != "p_zero_no_upper_request_ep":
            checks.add((name,))
        elif len(endpoint) == 1 and len(operation) + rest <= 1:
            case = operation[0] if operation else "rest" if rest else ""
            checks.add(("p_zero_no_upper_request", int(endpoint[0]), case))
    return checks


def check_zero_stream_subsumption(
    checks: set[tuple[str | int, ...]],
    named_operations: list[str],
    endpoints: int = ZERO_STREAM_ENDPOINTS,
) -> None:
    """Require each of the four stream properties, or all of its cases, among the checks."""
    for name in ZERO_STREAM_PROPERTIES:
        if (name,) in checks:
            continue
        assert name == "p_zero_no_upper_request", name
        for endpoint in range(endpoints):
            cases = {check[2] for check in checks if check[:2] == (name, endpoint)}
            assert "" in cases or cases >= {*named_operations, "rest"}, (
                endpoint,
                cases,
            )


def test_zero_stream_properties_checked_with_hints_free() -> None:
    """Check each zero stream property, or all its cases, with the store queue's hints free.

    No 31-frame stream task holds the write-more hint or the same-sector claim
    low: with both free, these tasks check every trace that holding them low
    would leave. This test checks each task's mode and depth;
    test_zero_safety_models_reject_cover_constraints pins their other options
    and their engines.
    """
    root = Path(__file__).resolve().parents[1]
    rtl = (root / "hw/rtl/lib/cache/coherence_l1d.sv").read_text()
    # The whole-endpoint case has the property's guard and one endpoint's bit
    # of its upper-request vector, so the endpoint cases together are the
    # property; test_zero_upper_endpoint_one_parts_cover_every_operation pins
    # the one-operation and remaining-operation branches against this case.
    whole = re.search(
        r"if \((?P<guard>[^;]*?)\)\s*p_zero_no_upper_request : assert "
        r"\(!\(\|f_zero_upper_request\)\);",
        rtl,
    )
    branches = re.search(
        r"`elsif ZERO_UPPER_OP_REST\n(?P<rest>.*?)`else\n(?P<all>.*?)`endif\n",
        rtl,
        flags=re.DOTALL,
    )
    assert whole and branches
    assert "logic [MISSES-1:0] f_zero_upper_request;" in rtl
    guard = " ".join(whole["guard"].split())
    assert " ".join(branches["all"].split()) == (
        f"if ({guard}) p_zero_no_upper_request_ep : assert "
        "(!f_zero_upper_request[`ZERO_UPPER_EP]);"
    )
    named = re.findall(r" && operation_q != (\w+)", " ".join(branches["rest"].split()))
    assert named and len(named) == len(set(named))

    target = next(t for t in FORMAL_TARGETS if t.name == "coherence_l1d")
    configs = {
        task: l1d_task_config(task)
        for task in target.tasks
        if task.startswith("coh_l1d_zero_stream_")
    }

    def checked(tasks: dict[str, dict[str, list[str]]]) -> set[tuple[str | int, ...]]:
        return {
            check for config in tasks.values() for check in zero_stream_checks(config)
        }

    def copied() -> dict[str, dict[str, list[str]]]:
        return {
            name: {key: list(value) for key, value in config.items()}
            for name, config in configs.items()
        }

    def altered(task: str, section: str, line: str) -> dict[str, dict[str, list[str]]]:
        changed = copied()
        lines = changed[task][section]
        if section == "[script]":
            lines.insert(lines.index("memory_map"), line)
        else:
            lines.append(line)
        return changed

    def narrowed(task: str, names: list[str]) -> dict[str, dict[str, list[str]]]:
        changed = copied()
        script = changed[task]["[script]"]
        start = next(
            i for i, line in enumerate(script) if line.startswith("select -assert-")
        )
        script[start : start + 4] = zero_stream_selection(names)
        return changed

    check_zero_stream_subsumption(checked(configs), named)
    hint, line = "coh_l1d_zero_stream_hint_bmc", "coh_l1d_zero_stream_line_bmc"
    upper = "coh_l1d_zero_stream_upper_ep{}_bmc".format
    for tasks in (
        # A hint held low in one task.
        altered(hint, "[script]", "connect -set i_next_same 1'b0"),
        altered(line, "[script]", "connect -set i_write_more 1'b0"),
        altered(upper(2), "[script]", "connect -set i_write_more 1'b0"),
        altered(upper("1_rest"), "[script]", "connect -set i_next_same 1'b0"),
        # A shallower task, or an added cutpoint.
        altered(upper(0), "[options]", "depth 30"),
        altered(line, "[script]", "cutpoint w:store_upper"),
        # A task gone from the registry.
        {name: config for name, config in configs.items() if name != hint},
        {name: config for name, config in configs.items() if name != upper(2)},
        {name: config for name, config in configs.items() if name != upper("1_rest")},
        # An assertion dropped from a task's selection.
        narrowed(hint, ["p_prefetch_not_record"]),
    ):
        with pytest.raises(AssertionError):
            check_zero_stream_subsumption(checked(tasks), named)
    # An operation or an endpoint that no case covers.
    with pytest.raises(AssertionError):
        check_zero_stream_subsumption(checked(configs), [*named, "GrantOp"])
    with pytest.raises(AssertionError):
        check_zero_stream_subsumption(
            checked(configs), named, ZERO_STREAM_ENDPOINTS + 1
        )


def test_full_line_safety_models_pinned() -> None:
    """Pin the full-line and withdrawn-put safety models: sources, scripts, engines, bounds."""
    reads = [
        "read -sv coherence_read_stream.sv",
        "read -sv cache_perf_pkg.sv",
        "read -sv coherence_pkg.sv",
        "read -sv coherence_request_endpoint.sv",
        "read -sv coherence_put_endpoint.sv coherence_read_owners.sv "
        "coherence_miss_credit.sv coherence_read_flags.sv "
        "coherence_grant_select.sv coherence_read_select.sv",
    ]
    files = (
        [
            "../hw/rtl/lib/cache/coherence_read_stream.sv",
            "../hw/rtl/lib/ram/sdp_block_ram.sv",
            "../hw/rtl/lib/ram/sdp_packed_tag_uram.sv",
            "../hw/rtl/lib/ram/sdp_ram_byte_en.sv",
        ]
        + [
            f"../hw/rtl/lib/cache/{name}"
            for name in (
                "coherence_pkg.sv",
                "coherence_types.svh",
                "coherence_array.sv",
                "coherence_request_endpoint.sv",
                "coherence_put_endpoint.sv",
                "coherence_l1d.sv",
                "coherence_read_owners.sv",
                "coherence_miss_credit.sv",
                "coherence_read_flags.sv",
                "coherence_grant_select.sv",
                "coherence_read_select.sv",
                "coherence_read_payload.sv",
                "cache_perf_pkg.sv",
                "coherence_store_buffer.sv",
            )
        ]
        + ["free_undefined.ys"]
    )
    data = " ".join(f"c:p_store_data_{index}" for index in range(1, 6))
    payload_properties = [
        f"select -assert-count 5 {data}",
        f"chformal -assert -remove t:$check r:FLAVOR=assert %i {data} %u %u %u %u %d",
        "select -assert-count 5 t:$check r:FLAVOR=assert %i",
    ]
    for task, depth, timeout, engine in (
        ("coh_l1d_full_bmc", "40", "10800", "abc bmc3 -g"),
        ("coh_l1d_full_multi_bmc", "30", "18000", "abc bmc3 -c"),
        ("coh_l1d_full_payload_bmc", "40", "5700", "abc bmc3 -c"),
        ("coh_l1d_withdraw_full_bmc", "40", "10800", "abc bmc3 -g"),
        ("coh_l1d_withdraw_zero_bmc", "40", "10800", "abc bmc3 -g"),
        ("coh_l1d_withdraw_full_payload_bmc", "40", "5400", "abc bmc3 -c"),
        ("coh_l1d_withdraw_zero_payload_bmc", "40", "5400", "abc bmc3 -c"),
    ):
        payload = task.endswith("payload_bmc")
        # The full-line tasks hold the zero write low; the zero-line ones
        # leave it free and keep the zero-line property selection.
        full = "_full_" in task
        defines = " -D ZERO_WRITES" + (" -D FULL_WRITES" if full else "")
        defines += " -D STORE_DATA_PROOF" if payload else ""
        endpoints = " -set MISSES 3" if "multi" in task else ""
        withdraw = (
            ["chparam -set WITHDRAW_ABSORBED_W 1 coherence_l1d"]
            if task.startswith("coh_l1d_withdraw_")
            else []
        )
        control_properties = [
            "select -assert-count 1 c:p_prefetch_conflict_split t:$check %i r:FLAVOR=assert %i",
            "chformal -assert2assume c:p_prefetch_conflict_split",
            f"select -assert-min 1 c:p_{'full' if full else 'zero'}_* t:$check %i "
            "r:FLAVOR=assert %i",
        ]
        script = (
            reads
            + [
                f"read -formal -sv{defines} coherence_read_payload.sv coherence_l1d.sv",
                "read -sv coherence_store_buffer.sv",
                "read -sv sdp_block_ram.sv sdp_packed_tag_uram.sv sdp_ram_byte_en.sv coherence_array.sv",
                f"chparam -set CACHE_BYTES 64 -set WAYS 1 -set TAG_BITS 2{endpoints} coherence_l1d",
            ]
            + withdraw
            + [
                "hierarchy -top coherence_l1d",
                *(" ".join(c) for c in UNDEFINED_OPENING),
                "prep -flatten -top coherence_l1d",
            ]
            + (payload_properties if payload else control_properties)
            + (["connect -set i_write_zero 1'b0"] if full else [])
            + [
                "memory_map",
                "opt",
                "techmap",
                "opt -fast",
                "setundef -anyseq",
                "opt_clean",
            ]
        )

        def validate(config: dict[str, list[str]]) -> None:
            assert config.keys() == {"[options]", "[engines]", "[script]", "[files]"}
            assert dict(line.split(maxsplit=1) for line in config["[options]"]) == {
                "mode": "bmc",
                "depth": depth,
                "timeout": timeout,
                "aigsmt": "boolector",
            }
            assert config["[engines]"] == [engine]
            assert config["[script]"] == script, task
            assert config["[files]"] == files

        safety = l1d_task_config(task)
        validate(safety)
        for section, line in (
            ("[script]", "connect -set i_read_valid 1'b0"),
            ("[script]", "connect -set i_next_same 1'b0"),
            ("[script]", "connect -set i_write_more 1'b0"),
            ("[script]", "delete -input w:i_p_valid"),
            ("[script]", "cutpoint w:store_upper"),
            ("[script]", "chformal -assume -remove"),
            ("[script]", "chformal -assert2assume c:p_zero_acquire_line"),
            ("[options]", "skip 48"),
            ("[options]", "smtc hidden.smtc"),
            ("[engines]", "smtbmc boolector --smtc hidden.smtc"),
            ("[files]", "hidden.smtc"),
            ("[file hidden.smtc]", "assume (= hidden 0)"),
        ):
            altered = {key: list(value) for key, value in safety.items()}
            altered.setdefault(section, []).append(line)
            with pytest.raises(AssertionError):
                validate(altered)


def _guarded_checks(text: str, keyword: str) -> list[tuple[str, str]]:
    """Return (guard, condition) for each immediate ``keyword`` in ``text``.

    The guard is the condition of an ``if`` directly before the check, or of
    the ``if (...) begin`` block that holds it; whitespace is removed.
    """
    checks: list[tuple[str, str]] = []
    block_guard = ""
    position = 0
    pattern = re.compile(r"\bif\s*\(|\bend\b|\b" + keyword + r"\s*\(")
    pending_guard = ""
    while True:
        match = pattern.search(text, position)
        if match is None:
            return checks
        start = match.end()
        if match.group(0) == "end":
            block_guard = ""
            position = start
            continue
        depth = 1
        index = start
        while depth:
            depth += {"(": 1, ")": -1}.get(text[index], 0)
            index += 1
        body = re.sub(r"\s+", "", text[start : index - 1])
        if match.group(0).startswith("if"):
            following = text[index:].lstrip()
            if following.startswith("begin"):
                block_guard = body
                pending_guard = ""
                position = index + text[index:].index("begin") + len("begin")
            else:
                pending_guard = body
                position = index
            continue
        checks.append((pending_guard or block_guard, body))
        pending_guard = ""
        position = index


def test_store_buffer_contract_assertions_mirror_its_assumptions() -> None:
    """The controller-side contract asserts exactly what the buffer's proofs assume.

    ``coherence_l1d:coh_l1d_buffer_contract_bmc`` reads the buffer with
    ``BUFFER_CONTRACT``; its assertions must stay the same conditions, under the
    same guards and in the same order, as the interface assumptions that the
    buffer's own proofs make about their inputs.
    """
    source = (
        Path(__file__).resolve().parents[1]
        / "hw/rtl/lib/cache/coherence_store_buffer.sv"
    ).read_text()
    formal = source.split("`ifdef FORMAL", 1)[1].split("`ifdef BUFFER_CONTRACT", 1)[0]
    first = formal.index("if (i_push) assume")
    last = formal.index("f_outstanding_q <= f_outstanding_q")
    assumptions = _guarded_checks(formal[first:last], "assume")
    contract = source.split("`ifdef BUFFER_CONTRACT", 1)[1].split("`endif", 1)[0]
    body = contract.split("if (c_past_valid && !i_rst) begin", 1)[1]
    assertions = [
        (guard, condition) for guard, condition in _guarded_checks(body, "assert")
    ]
    renamed = [
        (
            guard,
            condition.replace("c_last_scalar_q", "f_last_scalar_q").replace(
                "c_claim_sector_q", "f_claim_sector_q"
            ),
        )
        for guard, condition in assertions
    ]
    # The proofs also assume the cycle after reset; the contract asserts from
    # that cycle on, so its push condition omits the past-valid term.
    expected = [
        (
            guard,
            condition.replace("f_past_valid&&", "", 1)
            if guard == "i_push"
            else condition,
        )
        for guard, condition in assumptions
    ]
    assert len(expected) == 12
    assert renamed == expected
    labels = re.findall(r"\b(p_buffer_contract_\w+)\s*:", contract)
    assert len(labels) == len(set(labels)) == len(expected)
    formal_dir = Path(__file__).resolve().parents[1] / "formal"
    task = sby_config.resolved(formal_dir / "coherence_l1d.sby")
    commands = task["coh_l1d_buffer_contract_bmc"].commands(formal_dir)
    assert any(
        args[:4]
        == ["select", "-assert-count", str(len(expected)), "c:*p_buffer_contract_*"]
        for args in commands
    )
    assert [args for args in commands if "coherence_store_buffer.sv" in args] == [
        ["read", "-sv", "-D", "BUFFER_CONTRACT", "coherence_store_buffer.sv"]
    ]


def test_zero_cover_keeps_reset_and_legal_input_profile() -> None:
    """Keep every cover, reset and interface assumption under a public-input profile."""
    control = l1d_task_config("coh_l1d_zero_bmc")
    cover = l1d_task_config("coh_l1d_zero_cover")
    model = [line for line in control["[script]"] if not assertion_command(line)]
    idle_inputs = (
        "i_read_valid",
        "i_fatal_stop",
        "i_write_atomic",
        "i_write_sc",
        "i_sc_valid",
        "i_sc_commit",
        "i_maint_valid",
        "i_p_valid",
    )
    ready_inputs = (
        "i_read_ready",
        "i_sc_result_ready",
        "i_d_ready",
        "i_c_ready",
        "i_r_ready",
        "i_w_ready",
        "i_cut_admit_ready",
        "i_cut_admit_clean",
        "i_cut_inval_done",
    )
    tied_inputs = idle_inputs + ("i_read_kind",) + ready_inputs
    profile = (
        ["delete -input " + " ".join(f"w:{name}" for name in tied_inputs)]
        + [f"connect -set {name} 1'b0" for name in idle_inputs]
        + ["connect -set i_read_kind 2'b00"]
        + [f"connect -set {name} 1'b1" for name in ready_inputs]
    )
    connection_index = model.index("memory_map")
    profiled_model = model[:connection_index] + profile + model[connection_index:]
    selected = (
        "c:p_zero_cover_twin c:p_zero_cover_twin_victim "
        "c:p_zero_cover_twin_wait c:p_zero_cover_fallback"
    )

    def validate(task: dict[str, list[str]]) -> None:
        assert task.keys() == control.keys()
        for section in task.keys() - {"[options]", "[engines]", "[script]"}:
            assert task[section] == control[section]
        assert [
            line for line in task["[script]"] if not assertion_command(line)
        ] == profiled_model
        assert [line for line in task["[script]"] if assertion_command(line)] == [
            "select -assert-count 5 c:p_zero_cover_* t:$check %i r:FLAVOR=cover %i",
            "chformal -cover -remove t:$check r:FLAVOR=cover %i "
            f"{selected} %u %u %u %d",
            "select -assert-count 4 t:$check r:FLAVOR=cover %i",
            "chformal -assert -remove",
        ]
        assert dict(line.split(maxsplit=1) for line in task["[options]"]) == {
            "mode": "cover",
            "depth": "80",
            "timeout": "14400",
            "vcd_sim": "on",
            "skip": "48",
        }
        assert task["[engines]"] == ["smtbmc boolector"]

    validate(cover)
    for section, line in (
        ("[script]", "chformal -cover -remove c:p_zero_cover_twin_victim"),
        ("[script]", "chformal -assert2assume c:p_zero_twin_install"),
        ("[script]", "cutpoint w:image_q"),
        ("[script]", "connect -set i_rst 1'b0"),
        ("[script]", "delete -input w:i_rst"),
        ("[script]", "connect -set i_write_zero 1'b0"),
        ("[options]", "depth 79"),
        ("[options]", "skip 40"),
        ("[options]", "expect PASS,UNKNOWN,TIMEOUT"),
        ("[file cover_only.smtc]", "assume (= hidden 0)"),
    ):
        altered = {key: list(value) for key, value in cover.items()}
        altered.setdefault(section, []).append(line)
        with pytest.raises(AssertionError):
            validate(altered)
    for task_name in (
        "coh_l1d_zero_bmc",
        "coh_l1d_zero_multi_bmc",
        "coh_l1d_zero_payload_bmc",
    ):
        options = l1d_task_config(task_name)["[options]"]
        assert all(not line.startswith("skip ") for line in options)
        assert all(
            line not in l1d_task_config(task_name)["[script]"] for line in profile
        )


def test_store_boundary_four_and_intervening_partitions_complete() -> None:
    """Require disjoint, exhaustive assertion partitions for bmc_four and bmc_intervening."""
    root = Path(__file__).resolve().parents[1]
    sby_path = root / FORMAL_DIR / "coherence_store_boundary.sby"
    configs = {
        name: cfg.sections(sby_path.parent)
        for name, cfg in sby_config.resolved(sby_path).items()
    }

    def partition_lines(script: list[str]) -> list[str]:
        return [
            line
            for line in script
            if line.startswith(("select -assert-", "chformal -assert -remove "))
        ]

    def model_without_specialization(
        script: list[str], param: str
    ) -> tuple[list[str], str | None]:
        spec: str | None = None
        base: list[str] = []
        prefix = f"chparam -set {param} "
        for line in script:
            if line.startswith(prefix):
                assert spec is None, line
                spec = line
            elif not line.startswith(("select -assert-", "chformal -assert -remove ")):
                base.append(line)
        return base, spec

    def validate_four(tasks: dict[str, dict[str, list[str]]]) -> None:
        ctrl = tasks["bmc_four_control"]
        ctrl_model, ctrl_spec = model_without_specialization(
            ctrl["[script]"], "WATCHED_STORE"
        )
        assert ctrl_spec is None
        assert "free_undefined.ys" in ctrl["[files]"]
        assert "setundef -anyseq t:$mux t:$pmux t:$bwmux w:*" in ctrl_model
        assert not any(
            line.startswith(("cutpoint ", "connect ", "chformal -assert2assume"))
            for line in ctrl["[script]"]
        )
        assert partition_lines(ctrl["[script]"]) == [
            "select -assert-count 23 t:$check r:FLAVOR=assert %i",
            "chformal -assert -remove c:p_load_value",
            "select -assert-count 22 t:$check r:FLAVOR=assert %i",
        ]
        # Disjoint union: control keeps 23 - 1 = 22 assertions across all four
        # watched_store values; value_0..3 each keep the complementary 1
        # assertion (p_load_value) across WATCHED_STORE = 0, 1, 2, 3.
        seen_watched: set[int] = set()
        for idx in range(4):
            name = f"bmc_four_value_{idx}"
            task = tasks[name]
            assert task["[files]"] == ctrl["[files]"]
            assert task["[engines]"] == ["abc bmc3 -c"]
            model, spec = model_without_specialization(
                task["[script]"], "WATCHED_STORE"
            )
            assert model == ctrl_model
            assert (
                spec
                == f"chparam -set WATCHED_STORE {idx} coherence_store_boundary_formal"
            )
            seen_watched.add(idx)
            assert partition_lines(task["[script]"]) == [
                "select -assert-count 23 t:$check r:FLAVOR=assert %i",
                "chformal -assert -remove t:$check r:FLAVOR=assert %i c:p_load_value %d",
                "select -assert-count 1 t:$check r:FLAVOR=assert %i",
                "select -assert-count 1 c:p_load_value",
            ]
        assert seen_watched == {0, 1, 2, 3}
        for name in (
            "bmc_four_control",
            *(f"bmc_four_value_{idx}" for idx in range(4)),
        ):
            opts = dict(line.split(maxsplit=1) for line in tasks[name]["[options]"])
            assert opts["mode"] == "bmc"
            assert opts["depth"] == "114"
            assert opts["aigsmt"] == "boolector"
            assert int(opts["timeout"]) <= 15840
            assert formal_task_timeout_s("coherence_store_boundary", name) <= 15840

    def validate_intervening(tasks: dict[str, dict[str, list[str]]]) -> None:
        fatal = tasks["bmc_intervening_fatal"]
        fatal_model, fatal_spec = model_without_specialization(
            fatal["[script]"], "SECTOR_CASE"
        )
        assert fatal_spec is None
        assert "free_undefined.ys" in fatal["[files]"]
        assert "setundef -anyseq t:$mux t:$pmux t:$bwmux w:*" in fatal_model
        assert fatal["[engines]"] == ["abc bmc3 -c -S 139"]
        assert ("coherence_store_boundary", "bmc_intervening_fatal") in (
            FATAL_START_FRAME_TASKS
        )
        assert partition_lines(fatal["[script]"]) == [
            "select -assert-count 19 t:$check r:FLAVOR=assert %i",
            "chformal -assert -remove t:$check r:FLAVOR=assert %i c:p_no_fatal %d",
            "select -assert-count 1 t:$check r:FLAVOR=assert %i",
            "select -assert-count 1 c:p_no_fatal",
            "select -assert-none t:$assume",
            "select -assert-none t:$check r:FLAVOR=assume %i",
        ]
        sticky = tasks["prove_intervening_fatal_sticky"]
        sticky_opts = dict(line.split(maxsplit=1) for line in sticky["[options]"])
        assert sticky_opts == {"mode": "prove", "depth": "2", "timeout": "120"}
        assert sticky["[engines]"] == ["smtbmc boolector"]
        assert partition_lines(sticky["[script]"]) == [
            "select -assert-count 20 t:$check r:FLAVOR=assert %i",
            "chformal -assert -remove t:$check r:FLAVOR=assert %i c:p_fatal_sticky %d",
            "select -assert-count 1 t:$check r:FLAVOR=assert %i",
            "select -assert-count 1 c:p_fatal_sticky",
            "select -assert-none t:$assume",
            "select -assert-none t:$check r:FLAVOR=assume %i",
        ]
        # Disjoint union for both SECTOR_CASE in {0, 1}: 17 flow + 1 value
        # (p_load_value) + 1 fatal (p_no_fatal, frame 139 + sticky induction)
        # equals all 19 assertions of bmc_intervening with zero assumptions.
        for sector, value in (("same", 0), ("other", 1)):
            flow = tasks[f"bmc_intervening_{sector}_flow"]
            val = tasks[f"bmc_intervening_{sector}_value"]
            for name, task, expected_part in (
                (
                    f"bmc_intervening_{sector}_flow",
                    flow,
                    [
                        "select -assert-count 19 t:$check r:FLAVOR=assert %i",
                        "chformal -assert -remove c:p_load_value c:p_no_fatal",
                        "select -assert-count 17 t:$check r:FLAVOR=assert %i",
                    ],
                ),
                (
                    f"bmc_intervening_{sector}_value",
                    val,
                    [
                        "select -assert-count 19 t:$check r:FLAVOR=assert %i",
                        "chformal -assert -remove t:$check r:FLAVOR=assert %i c:p_load_value %d",
                        "select -assert-count 1 t:$check r:FLAVOR=assert %i",
                        "select -assert-count 1 c:p_load_value",
                    ],
                ),
            ):
                assert task["[files]"] == fatal["[files]"]
                assert task["[engines]"] == ["abc bmc3 -c"]
                model, spec = model_without_specialization(
                    task["[script]"], "SECTOR_CASE"
                )
                assert model == fatal_model
                assert (
                    spec
                    == f"chparam -set SECTOR_CASE {value} coherence_store_boundary_formal"
                )
                assert partition_lines(task["[script]"]) == expected_part
                assert not any(
                    line.startswith(
                        ("cutpoint ", "connect ", "chformal -assert2assume")
                    )
                    for line in task["[script]"]
                )
                opts = dict(line.split(maxsplit=1) for line in task["[options]"])
                assert opts["mode"] == "bmc"
                assert opts["depth"] == "140"
                assert opts["aigsmt"] == "boolector"
                assert int(opts["timeout"]) <= 15840
                assert formal_task_timeout_s("coherence_store_boundary", name) <= 15840
        fatal_opts = dict(line.split(maxsplit=1) for line in fatal["[options]"])
        assert fatal_opts["mode"] == "bmc"
        assert fatal_opts["depth"] == "140"
        assert int(fatal_opts["timeout"]) <= 15840

    validate_four(configs)
    validate_intervening(configs)

    # Negative self-checks: dropping an assertion, lowering depth, or adding an
    # assumption/cutpoint must fail validation.
    for validator, target_task, section, line in (
        (
            validate_four,
            "bmc_four_control",
            "[script]",
            "chformal -assert -remove c:p_no_fatal",
        ),
        (validate_four, "bmc_four_value_0", "[options]", "depth 113"),
        (
            validate_four,
            "bmc_four_value_1",
            "[script]",
            "chformal -assert2assume c:p_no_fatal",
        ),
        (validate_four, "bmc_four_value_0", "[options]", "timeout 15841"),
        (
            validate_intervening,
            "bmc_intervening_same_flow",
            "[script]",
            "cutpoint w:l1_fatal",
        ),
        (validate_intervening, "bmc_intervening_other_value", "[options]", "depth 139"),
        (
            validate_intervening,
            "bmc_intervening_fatal",
            "[script]",
            "chformal -assert -remove c:p_no_fatal",
        ),
    ):
        altered = {
            name: {sec: list(vals) for sec, vals in data.items()}
            for name, data in configs.items()
        }
        altered[target_task][section].append(line)
        with pytest.raises(AssertionError):
            validator(altered)


def test_local_data_partition_models_match() -> None:
    """Keep every scheduled real-array assertion at its original depth."""
    reference = l1d_task_config("coh_l1d_local_cover")
    model = [line for line in reference["[script]"] if not assertion_command(line)]
    assert (
        "read -formal -sv -D LOCAL_ATOMIC_PROOF -D LOCAL_ATOMIC_COVER "
        "coherence_read_payload.sv coherence_l1d.sv"
    ) in model
    data = "c:p_local_image c:p_local_probe_data"
    hold = (
        "c:p_grant_mux_exact c:p_local_image_stable "
        "c:p_load_payload_held c:p_reply_hold"
    )
    commands = {
        "data": [
            f"select -assert-count 2 {data}",
            f"chformal -assert -remove t:$check r:FLAVOR=assert %i {data} %u %d",
            "select -assert-count 2 t:$check r:FLAVOR=assert %i",
        ],
        "hold": [
            f"select -assert-count 4 {hold}",
            f"chformal -assert -remove t:$check r:FLAVOR=assert %i {hold} %u %u %u %d",
            "select -assert-count 4 t:$check r:FLAVOR=assert %i",
        ],
        # The complement includes unnamed checks and future assertions.
        "control": [
            f"chformal -assert -remove {data} {hold}",
            "select -assert-min 1 t:$check r:FLAVOR=assert %i",
        ],
    }

    def validate(part: str, task: dict[str, list[str]]) -> None:
        assert task.keys() == reference.keys()
        for section in task.keys() - {"[options]", "[engines]", "[script]"}:
            assert task[section] == reference[section]
        script = task["[script]"]
        assert [line for line in script if assertion_command(line)] == commands[part]
        assert [line for line in script if not assertion_command(line)] == model
        options = dict(line.split(maxsplit=1) for line in task["[options]"])
        options.setdefault("expect", "PASS")
        assert options == {
            "mode": "bmc",
            "depth": "80",
            "timeout": "3600" if part == "control" else "1200",
            "aigsmt": "boolector",
            "expect": "PASS",
        }
        engine = "abc bmc3" if part == "control" else "abc bmc3 -c"
        assert task["[engines]"] == [engine]

    for part in commands:
        task = l1d_task_config(f"coh_l1d_local_{part}_bmc")
        validate(part, task)
        for section, line in (
            ("[script]", "chformal -assert2assume c:p_local_image"),
            ("[script]", "chformal -assert -remove c:p_local_failure"),
            ("[script]", "cutpoint w:array_data"),
            ("[script]", "connect -set i_sc_valid 1'b0"),
            ("[options]", "depth 79"),
            ("[options]", "expect PASS,UNKNOWN,TIMEOUT"),
            ("[options]", "smtc partition_only.smtc"),
            ("[file partition_only.smtc]", "assume (= hidden 0)"),
        ):
            altered = {key: list(value) for key, value in task.items()}
            altered.setdefault(section, []).append(line)
            with pytest.raises(AssertionError):
                validate(part, altered)


@pytest.mark.parametrize(
    ("prefix", "depth", "scripted"),
    (("stream", 42, True), ("stream_free_nostore", 24, False)),
)
def test_stream_partition_models_match(prefix: str, depth: int, scripted: bool) -> None:
    """Keep every stream assertion at its original depth and input scope."""
    bmc = l1d_task_config(f"coh_l1d_{prefix}_bmc")
    hold = l1d_task_config(f"coh_l1d_{prefix}_hold_bmc")
    holds = (
        "c:p_grant_mux_exact c:p_local_image_stable "
        "c:p_load_payload_held c:p_reply_hold c:p_snapshot_credit_data"
    )
    common = [
        "select -assert-count 1 c:p_prefetch_conflict_split t:$check %i r:FLAVOR=assert %i",
        "chformal -assert2assume c:p_prefetch_conflict_split",
    ]
    commands = {
        "hold": common
        + [
            "select -assert-count 332 t:$check r:FLAVOR=assert %i",
            f"select -assert-count 5 {holds}",
            f"chformal -assert -remove t:$check r:FLAVOR=assert %i {holds} %u %u %u %u %d",
            "select -assert-count 5 t:$check r:FLAVOR=assert %i",
        ],
        "bmc": common
        + [
            "select -assert-count 332 t:$check r:FLAVOR=assert %i",
            f"chformal -assert -remove {holds}",
            "select -assert-count 327 t:$check r:FLAVOR=assert %i",
        ],
    }

    def validate(
        candidate: dict[str, list[str]], consumer: dict[str, list[str]]
    ) -> None:
        assert candidate.keys() == consumer.keys()
        for section in candidate.keys() - {"[options]", "[engines]", "[script]"}:
            assert candidate[section] == consumer[section]
        model = [line for line in consumer["[script]"] if not assertion_command(line)]
        read = (
            "read -formal -sv -D STREAM_COVER -D STREAM_PASSIVE_CYCLES=24 "
            "coherence_read_payload.sv coherence_l1d.sv"
            if scripted
            else "read -formal -sv coherence_read_payload.sv coherence_l1d.sv"
        )
        assert read in model
        assert not any(line.startswith("cutpoint ") for line in model)
        assert [line for line in model if line.startswith("connect ")] == (
            ([] if scripted else ["connect -set i_write_mask 8'h00"])
            + ["connect -set i_write_zero 1'b0"]
        )
        for role, task in (("hold", candidate), ("bmc", consumer)):
            assert [
                line for line in task["[script]"] if assertion_command(line)
            ] == commands[role]
            assert [
                line for line in task["[script]"] if not assertion_command(line)
            ] == model
            options = dict(line.split(maxsplit=1) for line in task["[options]"])
            options.setdefault("expect", "PASS")
            # The scripted control task alone has a longer allowance.
            assert options == {
                "mode": "bmc",
                "depth": str(depth),
                "timeout": "5100" if scripted and role == "bmc" else "3600",
                "aigsmt": "boolector",
                "expect": "PASS",
            }
            # The scripted control task also uses the CaDiCaL-based engine.
            assert task["[engines]"] == [
                "abc bmc3 -c" if role == "hold" or scripted else "abc bmc3"
            ]

    validate(hold, bmc)
    for role, section, line in (
        ("hold", "[script]", "chformal -assert2assume c:p_reply_hold"),
        ("hold", "[script]", "chformal -assert -remove c:p_reply_hold"),
        ("hold", "[script]", "cutpoint w:array_data"),
        ("hold", "[options]", "smtc narrower.smtc"),
        ("bmc", "[options]", f"depth {depth - 1}"),
        ("bmc", "[options]", "expect PASS,UNKNOWN,TIMEOUT"),
        ("bmc", "[script]", "chformal -assert -remove c:p_atomic_single_owner"),
    ):
        altered = {
            key: list(value) for key, value in (hold if role == "hold" else bmc).items()
        }
        altered[section].append(line)
        with pytest.raises(AssertionError):
            validate(
                altered if role == "hold" else hold, altered if role == "bmc" else bmc
            )


def test_local_sector_lemma_models_match() -> None:
    """Require identical models for each unbounded lookup lemma and consumer."""
    config = l1d_task_config

    common = [
        "chformal -assert -remove t:$check r:FLAVOR=assert %i c:p_local_* "
        "c:p_atomic_context_identity c:p_atomic_read_identity c:p_selected_kind "
        "%u %u %u %d",
        "chformal -assert -remove c:p_local_probe_data",
    ]
    sector_names = (
        "c:p_local_sector c:p_local_lookup_stable c:p_local_conflict_sample "
        "c:p_local_admit_sector c:p_local_lookup_owner c:p_local_service "
        "c:p_local_sc_lookup c:p_local_active"
    )
    lemmas = "c:p_local_lookup_owner c:p_local_sc_lookup"
    role_check = f"select -assert-count 2 {lemmas} %u t:$check %i r:FLAVOR={{}} %i"
    # The owned task proves these facts; the owner task assumes them.
    owned_facts = (
        "c:p_local_failed_owned c:p_local_write_pending c:p_local_write_op "
        "c:p_local_amo_acquire c:p_local_acquired_amo c:p_local_phase "
        "c:p_local_granted c:p_local_acquired_sc c:p_local_active "
        "c:p_local_service c:p_local_failure c:p_selected_kind"
    )
    owner_commands = common + [
        f"chformal -assert2assume {owned_facts}",
        "chformal -assert -remove c:p_local_sector c:p_local_lookup_stable "
        "c:p_local_conflict_sample c:p_local_admit_sector",
        "select -assert-count 16 t:$check r:FLAVOR=assert %i",
        role_check.format("assert"),
    ]
    sector_commands = common + [
        f"select -assert-count 8 {sector_names}",
        f"chformal -assert -remove t:$check r:FLAVOR=assert %i {sector_names}"
        + " %u" * 7
        + " %d",
        f"chformal -assert2assume {lemmas}",
        "select -assert-count 6 t:$check r:FLAVOR=assert %i",
        role_check.format("assume"),
    ]
    # An owned task's proof supports its owner task, so it assumes nothing back.
    owned_names = owned_facts.split()
    owned_names.insert(1, "c:p_owned_*")
    owned_commands = [
        "chformal -assert -remove t:$check r:FLAVOR=assert %i "
        + " ".join(owned_names)
        + " %u" * (len(owned_names) - 1)
        + " %d",
        "select -assert-count 29 t:$check r:FLAVOR=assert %i",
    ]
    # Only these reads differ from the owner task's model: both expose the
    # request endpoint's phase, and neither changes its design logic.
    owned_reads = {
        "read -sv coherence_request_endpoint.sv": (
            "read -formal -sv coherence_request_endpoint.sv"
        ),
        "read -formal -sv -D LOCAL_ATOMIC_PROOF coherence_read_payload.sv "
        "coherence_l1d.sv": (
            "read -formal -sv -D LOCAL_ATOMIC_PROOF -D READ_OWNER_PROOF "
            "coherence_read_payload.sv coherence_l1d.sv"
        ),
    }

    def validate_owned(
        owner: dict[str, list[str]], owned: dict[str, list[str]]
    ) -> None:
        assert owned.keys() == owner.keys()
        for section in owned.keys() - {"[options]", "[engines]", "[script]"}:
            assert owned[section] == owner[section]
        script = owned["[script]"]
        assert [line for line in script if assertion_command(line)] == owned_commands
        assert [line for line in script if not assertion_command(line)] == [
            owned_reads.get(line, line)
            for line in owner["[script]"]
            if not assertion_command(line)
        ]
        options = dict(line.split(maxsplit=1) for line in owned["[options]"])
        options.setdefault("expect", "PASS")
        assert options == {
            "mode": "prove",
            "depth": "8",
            "timeout": "1200",
            "aigsmt": "boolector",
            "expect": "PASS",
        }
        assert owned["[engines]"] == ["smtbmc boolector"]

    def validate(owner: dict[str, list[str]], sector: dict[str, list[str]]) -> None:
        assert owner.keys() == sector.keys()
        for section in owner.keys() - {"[options]", "[engines]", "[script]"}:
            assert owner[section] == sector[section]
        model_scripts = []
        for task, commands, depth, engine in (
            (owner, owner_commands, "80", "abc pdr"),
            (sector, sector_commands, "8", "smtbmc boolector"),
        ):
            script = task["[script]"]
            assert [line for line in script if assertion_command(line)] == commands
            model_scripts.append(
                [line for line in script if not assertion_command(line)]
            )
            options = dict(line.split(maxsplit=1) for line in task["[options]"])
            options.setdefault("expect", "PASS")
            assert options == {
                "mode": "prove",
                "depth": depth,
                "timeout": "1200",
                "aigsmt": "boolector",
                "expect": "PASS",
            }
            assert task["[engines]"] == [engine]
        assert model_scripts[0] == model_scripts[1]

    for geometry in ("", "_multi", "_ways"):
        owner = config(f"coh_l1d_local{geometry}_prove")
        sector = config(f"coh_l1d_local{geometry}_sector_prove")
        validate(owner, sector)
        owned = config(f"coh_l1d_local{geometry}_owned_prove")
        validate_owned(owner, owned)
        for section, line in (
            ("[script]", "chformal -assert2assume c:p_local_lookup_owner"),
            ("[script]", "chparam -set MISSES 4 coherence_l1d"),
            ("[options]", "smtc owned_only.smtc"),
            ("[options]", "expect PASS,UNKNOWN,TIMEOUT"),
            ("[file owned_only.smtc]", "assume (= hidden 0)"),
        ):
            altered_owned = {key: list(value) for key, value in owned.items()}
            altered_owned.setdefault(section, []).append(line)
            with pytest.raises(AssertionError):
                validate_owned(owner, altered_owned)
        for side, section, line in (
            (0, "[script]", "chformal -assert -remove c:p_local_sc_lookup"),
            (0, "[script]", "chformal -remove -assert c:p_local_sc_lookup"),
            (1, "[script]", "chformal -assert -remove c:p_local_sector"),
            (1, "[script]", "chformal -remove c:p_local_sector"),
            (1, "[options]", "expect PASS,UNKNOWN,TIMEOUT"),
            (1, "[options]", "smtc sector_only.smtc"),
            (1, "[options]", "timeout 2400"),
            (1, "[file sector_only.smtc]", "assume (= hidden 0)"),
        ):
            altered = [
                {key: list(value) for key, value in task.items()}
                for task in (owner, sector)
            ]
            altered[side].setdefault(section, []).append(line)
            with pytest.raises(AssertionError):
                validate(*altered)


def test_stream_owned_lemma_model_matches() -> None:
    """Require the stream ownership and snapshot lemmas' models to match their consumer's."""
    owned = l1d_task_config("coh_l1d_stream_owned_prove")
    snapshot = l1d_task_config("coh_l1d_stream_snapshot_prove")
    proof = l1d_task_config("coh_l1d_stream_prove")
    assert owned.keys() == snapshot.keys() == proof.keys()
    for section in owned.keys() - {"[options]", "[engines]", "[script]"}:
        assert owned[section] == snapshot[section] == proof[section]
    model = [line for line in owned["[script]"] if not assertion_command(line)]
    assert model == [
        line for line in snapshot["[script]"] if not assertion_command(line)
    ]
    assert model == [line for line in proof["[script]"] if not assertion_command(line)]
    assert "read -formal -sv coherence_request_endpoint.sv" in model
    assert (
        "read -formal -sv -D STREAM_UNBOUNDED_PROOF -D READ_OWNER_PROOF "
        "-D SNAPSHOT_OWNER_PROOF coherence_read_payload.sv coherence_l1d.sv"
    ) in model
    assert "read -sv -D SNAPSHOT_OWNER_PROOF coherence_store_buffer.sv" in model
    assert (
        "read -sv -D SNAPSHOT_OWNER_PROOF sdp_block_ram.sv sdp_packed_tag_uram.sv "
        "sdp_ram_byte_en.sv coherence_array.sv"
    ) in model
    lemmas = "c:p_owned_* c:p_selected_kind c:p_path_shadowed"
    # The read ownership task proves its lemmas from the design alone.
    assert [line for line in owned["[script]"] if assertion_command(line)] == [
        f"chformal -assert -remove t:$check r:FLAVOR=assert %i {lemmas} %u %u %d",
        "select -assert-count 18 t:$check r:FLAVOR=assert %i",
    ]
    # The snapshot ownership task assumes only the read ownership lemmas.
    assert [line for line in snapshot["[script]"] if assertion_command(line)] == [
        "chformal -assert -remove t:$check r:FLAVOR=assert %i "
        "a:src=*coherence_request_endpoint.sv:* %i",
        f"select -assert-count 18 t:$check r:FLAVOR=assert %i {lemmas} %u %u %i",
        f"chformal -assert2assume {lemmas}",
        "chformal -assert -remove t:$check r:FLAVOR=assert %i "
        "c:p_snapshot_absorbed_clean c:p_snapshot_put_owner c:p_snap_* %u %u %d",
        "select -assert-count 53 t:$check r:FLAVOR=assert %i",
        "select -assert-count 1 c:p_snapshot_absorbed_clean t:$check %i r:FLAVOR=assert %i",
    ]
    proof_commands = [line for line in proof["[script]"] if assertion_command(line)]
    assert (
        f"select -assert-count 18 t:$check r:FLAVOR=assert %i {lemmas} %u %u %i"
        in proof_commands
    )
    assert f"chformal -assert2assume {lemmas}" in proof_commands
    assert (
        "select -assert-count 1 c:p_snapshot_absorbed_clean t:$check %i r:FLAVOR=assert %i"
        in proof_commands
    )
    assert "chformal -assert2assume c:p_snapshot_absorbed_clean" in proof_commands
    assert "chformal -assert -remove c:p_snap_*" in proof_commands
    owned_options = dict(line.split(maxsplit=1) for line in owned["[options]"])
    owned_options.setdefault("expect", "PASS")
    assert owned_options == {
        "mode": "prove",
        "depth": "8",
        "timeout": "1200",
        "aigsmt": "boolector",
        "expect": "PASS",
    }
    assert owned["[engines]"] == ["smtbmc boolector"]
    snap_options = dict(line.split(maxsplit=1) for line in snapshot["[options]"])
    snap_options.setdefault("expect", "PASS")
    assert snap_options == {
        "mode": "prove",
        "depth": "3",
        "timeout": "600",
        "aigsmt": "boolector",
        "expect": "PASS",
    }
    assert snapshot["[engines]"] == ["smtbmc boolector"]


@pytest.mark.parametrize(
    "task,depth,read",
    (
        (
            "coh_l1d_stream_bmc",
            "42",
            "read -formal -sv -D STREAM_COVER -D STREAM_PASSIVE_CYCLES=24 "
            "coherence_read_payload.sv coherence_l1d.sv",
        ),
        (
            "coh_l1d_stream_free_nostore_bmc",
            "24",
            "read -formal -sv coherence_read_payload.sv coherence_l1d.sv",
        ),
        (
            "coh_l1d_stream_free_bmc",
            "32",
            "read -formal -sv coherence_read_payload.sv coherence_l1d.sv",
        ),
        (
            "coh_l1d_stream_hold_bmc",
            "42",
            "read -formal -sv -D STREAM_COVER -D STREAM_PASSIVE_CYCLES=24 "
            "coherence_read_payload.sv coherence_l1d.sv",
        ),
        (
            "coh_l1d_stream_free_nostore_hold_bmc",
            "24",
            "read -formal -sv coherence_read_payload.sv coherence_l1d.sv",
        ),
        (
            "coh_l1d_stream_outlier_prove",
            "40",
            "read -formal -sv coherence_read_payload.sv coherence_l1d.sv",
        ),
    ),
)
def test_stream_control_and_payload_contracts(task: str, depth: str, read: str) -> None:
    """Keep the full stream models, bounds and independent coverage split."""
    bulk = task == "coh_l1d_stream_free_bmc"
    outlier = task == "coh_l1d_stream_outlier_prove"
    hold = task.endswith("_hold_bmc")
    # The scripted and free control tasks use the CaDiCaL-based engine, as the
    # holds do.
    cadical = hold or bulk or task == "coh_l1d_stream_bmc"
    script = [
        "read -sv coherence_read_stream.sv",
        "read -sv cache_perf_pkg.sv",
        "read -sv coherence_pkg.sv",
        "read -sv coherence_request_endpoint.sv",
        "read -sv coherence_put_endpoint.sv coherence_read_owners.sv "
        "coherence_miss_credit.sv coherence_read_flags.sv coherence_grant_select.sv "
        "coherence_read_select.sv",
        read,
        "read -sv coherence_store_buffer.sv",
        "read -sv sdp_block_ram.sv sdp_packed_tag_uram.sv sdp_ram_byte_en.sv "
        "coherence_array.sv",
        "chparam -set CACHE_BYTES 64 -set WAYS 1 -set TAG_BITS 2 -set MISSES 3 coherence_l1d",
        "chparam -set MISSES 8 -set STREAM_PREFETCH 1 coherence_l1d",
        "chparam -set ZERO_LINE 0 -set FULL_LINE 0 coherence_l1d",
        "hierarchy -top coherence_l1d",
        *(" ".join(c) for c in UNDEFINED_OPENING),
        "prep -flatten -top coherence_l1d",
        "select -assert-count 1 c:p_prefetch_conflict_split t:$check %i r:FLAVOR=assert %i",
        "chformal -assert2assume c:p_prefetch_conflict_split",
    ]
    script += ["select -assert-count 332 t:$check r:FLAVOR=assert %i"]
    if outlier or hold:
        if hold:
            script += [
                "select -assert-count 5 c:p_grant_mux_exact c:p_local_image_stable "
                "c:p_load_payload_held c:p_reply_hold c:p_snapshot_credit_data"
            ]
        script += [
            "chformal -assert -remove t:$check r:FLAVOR=assert %i "
            "c:p_grant_mux_exact c:p_local_image_stable c:p_load_payload_held "
            "c:p_reply_hold c:p_snapshot_credit_data %u %u %u %u %d",
            "select -assert-count 5 t:$check r:FLAVOR=assert %i",
        ]
    else:
        script += [
            "chformal -assert -remove c:p_grant_mux_exact c:p_local_image_stable "
            "c:p_load_payload_held c:p_reply_hold c:p_snapshot_credit_data",
            "select -assert-count 327 t:$check r:FLAVOR=assert %i",
        ]
    if task.startswith("coh_l1d_stream_free_nostore_"):
        script += ["connect -set i_write_mask 8'h00"]
    script += [
        "connect -set i_write_zero 1'b0",
        "memory_map",
        "opt",
        "techmap",
        "opt -fast",
        "setundef -anyseq",
        "opt_clean",
    ]
    files = [
        "../hw/rtl/lib/cache/coherence_read_stream.sv",
        "../hw/rtl/lib/ram/sdp_block_ram.sv",
        "../hw/rtl/lib/ram/sdp_packed_tag_uram.sv",
        "../hw/rtl/lib/ram/sdp_ram_byte_en.sv",
        "../hw/rtl/lib/cache/coherence_pkg.sv",
        "../hw/rtl/lib/cache/coherence_types.svh",
        "../hw/rtl/lib/cache/coherence_array.sv",
        "../hw/rtl/lib/cache/coherence_request_endpoint.sv",
        "../hw/rtl/lib/cache/coherence_put_endpoint.sv",
        "../hw/rtl/lib/cache/coherence_l1d.sv",
        "../hw/rtl/lib/cache/coherence_read_owners.sv",
        "../hw/rtl/lib/cache/coherence_miss_credit.sv",
        "../hw/rtl/lib/cache/coherence_read_flags.sv",
        "../hw/rtl/lib/cache/coherence_grant_select.sv",
        "../hw/rtl/lib/cache/coherence_read_select.sv",
        "../hw/rtl/lib/cache/coherence_read_payload.sv",
        "../hw/rtl/lib/cache/cache_perf_pkg.sv",
        "../hw/rtl/lib/cache/coherence_store_buffer.sv",
        "free_undefined.ys",
    ]

    def validate(config: dict[str, list[str]]) -> None:
        assert config.keys() == {"[options]", "[engines]", "[script]", "[files]"}
        options = dict(line.split(maxsplit=1) for line in config["[options]"])
        options.setdefault("expect", "PASS")
        timeout = {"coh_l1d_stream_bmc": "5100"}.get(task, "3600")
        if outlier:
            timeout = "2400"
        elif bulk:
            timeout = "10800"
        assert options == {
            "mode": "prove" if outlier else "bmc",
            "depth": depth,
            "timeout": timeout,
            "aigsmt": "boolector",
            "expect": "PASS",
        }
        assert config["[engines]"] == [
            "abc pdr" if outlier else "abc bmc3 -c" if cadical else "abc bmc3"
        ]
        assert config["[script]"] == script
        assert config["[files]"] == files

    config = l1d_task_config(task)
    validate(config)
    for section, line in (
        ("[script]", "connect -set i_read_valid 1'b0"),
        ("[script]", "connect -set i_write_mask 8'h00"),
        ("[script]", "chformal -assert -remove"),
        ("[script]", "delete c:p_path_shadowed"),
        ("[options]", "depth 1"),
        ("[options]", "expect PASS,UNKNOWN,TIMEOUT"),
        ("[options]", "smtc hidden.smtc"),
        ("[engines]", "abc bmc3 -F 1"),
        ("[files]", "hidden.smtc"),
        ("[file hidden.smtc]", "assume (= hidden 0)"),
    ):
        altered = {key: list(value) for key, value in config.items()}
        altered.setdefault(section, []).append(line)
        with pytest.raises(AssertionError):
            validate(altered)


def test_stream_payload_proof_model_covers_bmcs() -> None:
    """The independent payload proof permits each bounded specialization."""
    proof = l1d_task_config("coh_l1d_stream_outlier_prove")
    model = [line for line in proof["[script]"] if not assertion_command(line)]
    plain_read = "read -formal -sv coherence_read_payload.sv coherence_l1d.sv"
    scripted_read = (
        "read -formal -sv -D STREAM_COVER -D STREAM_PASSIVE_CYCLES=24 "
        "coherence_read_payload.sv coherence_l1d.sv"
    )
    # Pin the only macro-dependent block as well as the SBY reads. A new
    # use of either macro must revisit the model-inclusion argument.
    expected_stimulus = """
`ifdef STREAM_COVER
`ifndef STREAM_PASSIVE_CYCLES
`define STREAM_PASSIVE_CYCLES 127
`endif
  logic [6:0] f_stream_cycle_q = 0;
  (* anyconst *) logic [1:0] f_stream_atomic;
  logic f_stream_atomic_sent_q = 0;
  wire f_stream_admit = f_stream_atomic != 0 && !f_stream_atomic_sent_q &&
      phase_q == Acquire && operation_q == PrefetchOp &&
      |(ep_request_valid & ep_request_ready);
  always_ff @(posedge i_clk) begin
    if (f_stream_cycle_q != 127) f_stream_cycle_q <= f_stream_cycle_q + 1'b1;
    assume (i_rst == !f_past_valid);
    assume (!i_fatal_stop && !i_maint_valid && !i_sc_valid && !i_sc_commit);
    assume (i_write_mask == 0);
    if (f_stream_cycle_q < `STREAM_PASSIVE_CYCLES)
      assume (!i_p_valid && !i_wa_valid && !i_g_valid && !i_u_valid);
    assume (f_stream_atomic <= 2);
    if (f_stream_admit) f_stream_atomic_sent_q <= 1;
    assume (i_read_valid == (f_stream_cycle_q == 4 || f_stream_cycle_q == 5 ||
        f_stream_cycle_q == 6 || (f_stream_atomic == 0 && f_stream_cycle_q == 48) ||
        f_stream_admit));
    assume (i_read_id == (f_stream_cycle_q == 4 ? 0 : f_stream_cycle_q == 5 ? 1 :
        f_stream_cycle_q == 6 ? 2 : 3));
    assume (i_address == (f_stream_admit ? lookup_addr_q :
        ADDR_WIDTH'(32'h80000000 + (f_stream_cycle_q == 4 ? 0 :
        f_stream_cycle_q == 5 ? 32 : f_stream_cycle_q == 6 ? 64 : 96))));
    assume (i_read_kind == (f_stream_admit ? f_stream_atomic : ReadLoad));
    assume (i_read_size == 3 && i_read_tag == 0);
    if (f_stream_cycle_q < `STREAM_PASSIVE_CYCLES)
      assume (i_d_ready == 0 && i_c_ready == 0 && !i_read_ready);
  end
`endif
"""
    root = Path(__file__).resolve().parents[1] / "formal"
    source = (root / "../hw/rtl/lib/cache/coherence_l1d.sv").read_text()
    assert source.count("`ifdef STREAM_COVER\n") == 1
    start = source.index("`ifdef STREAM_COVER\n")
    end = source.index("`ifdef STREAM_TURN_COVER\n", start)
    stimulus = source[start:end]
    without_comments = "\n".join(
        line.split("//", 1)[0] for line in stimulus.splitlines()
    )
    assert without_comments.split() == expected_stimulus.split()
    for file in proof["[files]"]:
        contents = (root / file).read_text().replace(stimulus, "", 1)
        assert "STREAM_COVER" not in contents
        assert "STREAM_PASSIVE_CYCLES" not in contents
    # STREAM_COVER only adds ghost counters and input assumptions. The
    # common interface assumptions and payload predicates are unchanged.
    # Stores disabled by a constant tie are also a specialization of the
    # unrestricted, stores-enabled proof; neither proof assumes BMC facts.
    for task in (
        "coh_l1d_stream_bmc",
        "coh_l1d_stream_hold_bmc",
        "coh_l1d_stream_free_nostore_bmc",
        "coh_l1d_stream_free_nostore_hold_bmc",
        "coh_l1d_stream_free_bmc",
    ):
        bounded = l1d_task_config(task)
        assert bounded["[files]"] == proof["[files]"]
        bounded_model = [
            plain_read if line == scripted_read else line
            for line in bounded["[script]"]
            if not assertion_command(line) and line != "connect -set i_write_mask 8'h00"
        ]
        assert bounded_model == model


def test_hart_maintenance_lemma_model_matches() -> None:
    """Keep the maintenance proof's lemmas independent on an identical model."""
    owned = formal_task_config("coherent_hart_cache", "coh_hart_maint_owned_prove")
    proof = formal_task_config("coherent_hart_cache", "coh_hart_maint_prove")
    common = [
        "select -assert-none t:$check r:FLAVOR=assume %i",
        "select -assert-count 375 t:$check r:FLAVOR=assert %i",
    ]
    lemmas = (
        "c:*p_maint_owned_* c:p_maint_data_* c:*p_maint_ledger_* "
        "c:*p_maint_seq_* c:*p_maint_if_* c:*p_maint_ppn_* "
        "c:*p_maint_fact_* c:*p_maint_ptw_*"
    )
    covers = "chformal -cover -remove"
    owned_commands = common + [
        f"chformal -assert -remove t:$check r:FLAVOR=assert %i {lemmas} %u %u %u %u %u %u %u %d",
        "select -assert-count 286 t:$check r:FLAVOR=assert %i",
        covers,
    ]
    proof_commands = common + [
        f"select -assert-count 286 t:$check r:FLAVOR=assert %i {lemmas} %u %u %u %u %u %u %u %i",
        f"chformal -assert2assume {lemmas}",
        "select -assert-count 286 t:$check r:FLAVOR=assume %i",
        "select -assert-count 89 t:$check r:FLAVOR=assert %i",
        covers,
    ]

    def validate(lemma: dict[str, list[str]], consumer: dict[str, list[str]]) -> None:
        assert lemma.keys() == consumer.keys()
        for section in lemma.keys() - {"[options]", "[engines]", "[script]"}:
            assert lemma[section] == consumer[section]
        models = []
        for config, commands, depth, timeout, engine in (
            (lemma, owned_commands, "8", "1200", "smtbmc boolector"),
            (consumer, proof_commands, "32", "7200", "abc pdr -r"),
        ):
            script = config["[script]"]
            assert [line for line in script if assertion_command(line)] == commands
            models.append([line for line in script if not assertion_command(line)])
            options = dict(line.split(maxsplit=1) for line in config["[options]"])
            options.setdefault("expect", "PASS")
            expected = {
                "mode": "prove",
                "depth": depth,
                "timeout": timeout,
                "expect": "PASS",
            }
            if config is consumer:
                expected["aigsmt"] = "boolector"
            assert options == expected
            assert config["[engines]"] == [engine]
        assert models[0] == models[1]
        assert (
            "read -formal -D COH_MAINT_OWNED -sv coherent_hart_cache_models.sv "
            "coherent_hart_cache.sv coherent_hart_cache_formal.sv"
        ) in models[0]

    validate(owned, proof)
    # Both free-state PDR tasks use the original pair's precise property
    # selections. Compare the entire resolved model, including staged files.
    free_passes = {
        "memory_map": "memory_map -keepdc",
        "opt": "opt -keepdc",
        "opt -fast": "opt -fast -keepdc",
    }
    for task, original in (
        ("coh_hart_maint_free_owned_prove", owned),
        ("coh_hart_maint_free_prove", proof),
    ):
        expected = dict(original)
        expected["[script]"] = [
            free_passes.get(line, line) for line in original["[script]"]
        ]
        expected["[options]"] = [
            "timeout 7200" if line == "timeout 1200" else line
            for line in original["[options]"]
        ]
        expected["[engines]"] = ["abc pdr -r"]
        assert formal_task_config("coherent_hart_cache", task) == expected
    for side, section, line in (
        (0, "[script]", "chformal -assert2assume c:p_maint_owned_engine"),
        (0, "[script]", "chformal -assume -remove"),
        (0, "[options]", "smtc owned_only.smtc"),
        (0, "[engines]", "abc bmc3"),
        (0, "[file owned_only.smtc]", "assume (= hidden 0)"),
        (1, "[script]", "chformal -assert -remove c:p_grant_address"),
        (1, "[script]", "chformal -assert2assume c:p_extra"),
        (1, "[script]", "chparam -set COVER_MODE 1 coherent_hart_cache_formal"),
        (1, "[options]", "expect PASS,UNKNOWN,TIMEOUT"),
        (1, "[options]", "mode bmc"),
    ):
        altered = [
            {key: list(value) for key, value in config.items()}
            for config in (owned, proof)
        ]
        altered[side].setdefault(section, []).append(line)
        with pytest.raises(AssertionError):
            validate(*altered)
    # coh_hart_maint_owned_reset_prove proves the same facts by the same
    # induction from the state after the reset cycle, which sim computes. sim
    # treats an undefined enable or synchronous reset as inactive and compares
    # undefined bits literally in $eqx and $nex, so no opt_dff runs before it
    # (prep runs opt with -noff), only plain $dff cells reach it, and those
    # comparisons take their meaning in the proof first.
    # No task assumes its facts.
    reset = formal_task_config(
        "coherent_hart_cache", "coh_hart_maint_owned_reset_prove"
    )
    plain_dffs = (
        "select -assert-none t:$ff t:$dffe t:$adff* t:$aldff* t:$sdff* t:$dffsr* "
        "t:$dlatch* t:$adlatch t:$sr t:$mem* t:$_*DFF* t:$_*LATCH* t:$_SR_* "
        "t:$_FF_ t:$anyinit t:$fsm"
    )
    pair_model = [line for line in owned["[script]"] if not assertion_command(line)]
    start = pair_model.index("memory_map")
    assert pair_model[start : start + 4] == [
        "memory_map",
        "opt",
        "techmap",
        "opt -fast",
    ]
    assert pair_model[start - 2 : start] == [
        "prep -flatten -top coherent_hart_cache_formal",
        "check -assert",
    ]
    reset_model = (
        pair_model[:start]
        + [
            "memory_map -keepdc",
            "async2sync",
            "setundef -anyseq",
            "chtype -map $eqx $eq",
            "chtype -map $nex $ne",
            "sim -clock i_clk -n 1 -w",
            "opt -keepdc",
            "techmap",
            "opt -fast -keepdc",
        ]
        + pair_model[start + 4 :]
    )

    def validate_reset(config: dict[str, list[str]]) -> None:
        assert {key: value for key, value in config.items() if key != "[script]"} == {
            key: value for key, value in owned.items() if key != "[script]"
        }
        script = config["[script]"]
        assert [
            line for line in script if assertion_command(line)
        ] == owned_commands + [plain_dffs]
        assert [line for line in script if not assertion_command(line)] == reset_model

    validate_reset(reset)
    for edit in (
        lambda script: script.insert(script.index("async2sync"), "opt_dff -keepdc"),
        lambda script: script.remove(plain_dffs),
        lambda script: script.remove("chtype -map $eqx $eq"),
        lambda script: script.insert(
            script.index("async2sync"), "chformal -assert2assume c:*"
        ),
    ):
        changed = {key: list(value) for key, value in reset.items()}
        edit(changed["[script]"])
        with pytest.raises(AssertionError):
            validate_reset(changed)


def timeout_log_tail(error: subprocess.TimeoutExpired) -> str:
    """Keep recent solver progress when a captured run exceeds its backstop."""
    output = "".join(
        part.decode(errors="replace") if isinstance(part, bytes) else part or ""
        for part in (error.stdout, error.stderr)
    )
    return "\n".join(output.splitlines()[-40:])


def formal_reuse_key(root: Path, target: FormalTarget, task: str, tools_id: str) -> str:
    """Return a task's reuse key, failing the test if it cannot be computed."""
    test_id = f"{target.name}_{task}"
    try:
        registry = ci_reuse.FormalRegistry(root)
        entry = registry.tasks.get(test_id)
        if entry is None or entry.sby_file != target.sby_file:
            raise ci_reuse.ReuseKeyError(f"{test_id} is not in the registry")
        if registry.timeout(entry) != formal_task_timeout_s(target.name, task):
            raise ci_reuse.ReuseKeyError(f"{test_id}: the key holds another timeout")
        return ci_reuse.formal_task_key(root, test_id, tools_id, registry)
    except ci_reuse.ReuseKeyError as error:
        pytest.fail(f"Cannot compute the reuse key of {test_id}: {error}")


def fatal_frame_completed(output: str) -> bool:
    """Require a complete frame-139 evaluation of fatal status."""
    # ABC's nonzero start-frame summary can report zero completed frames.
    # The per-frame result distinguishes a checked horizon from an empty range.
    return all(
        re.search(pattern, output)
        for pattern in (
            r"Params: FramesMax = 140\. Start = 139\. ConfLimit = 0\. TimeOut = 0\.",
            r"engine_0: 139 \+ :",
            r"engine_0: finished \(returncode=0\)",
            r"engine_0: Status returned by engine: PASS",
            r"DONE \(PASS, rc=0\)",
        )
    )


_YOSYS_SCRIPT_BANNER = re.compile(r"^-- Executing script file `([^']+)' --$")
_YOSYS_TOP_HEADER = re.compile(r"^([1-9][0-9]*)\. (.*)$")


# Slang emits this warning while an authored Z is still distinguishable from X.
SLANG_Z_WARNING = "high-impedance state [(]Z[)] will be treated as undefined state [(]X[)] in this context"


def write_yosys_header_wrapper(
    wrapper_path: Path,
    pending_predicates: tuple[PredicateExemption, ...] = (),
    *,
    uses_slang: bool = False,
    source_projection: Path | None = None,
) -> Path:
    """Prepare the base-model checks, header trace, and optional projection."""
    plugin = Path(__file__).with_name("formal_model.cc").read_text()
    predicate_setup = "os.environ['FROST_YOSYS_PENDING_PREDICATES'] = ''\n"
    if pending_predicates:
        # Resolve the content again in SBY's src directory before loading the plugin.
        predicate_setup = (
            f"sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})\n"
            "from formal_predicates import PredicateExemption, resolve_predicate_sites\n"
            f"sites = resolve_predicate_sites(Path.cwd(), {pending_predicates!r}, staged=True)\n"
            "os.environ['FROST_YOSYS_PENDING_PREDICATES'] = '\\n'.join(sites)\n"
        )
    warning_args = ["-e", SLANG_Z_WARNING] if uses_slang else []
    script = (
        "#!/usr/bin/env python3\n"
        "import fcntl, hashlib, os, subprocess, sys\n"
        "from pathlib import Path\n"
        f"CC_SRC = {plugin!r}\n"
        f"WARNING_ARGS = {warning_args!r}\n"
        "args = sys.argv[1:]\n"
        'if "../model/design.ys" not in args:\n'
        '    os.execvp("yosys", ["yosys", *args])\n'
        f"source_projection = {str(source_projection) if source_projection else None!r}\n"
        "if source_projection is not None:\n"
        "    subprocess.run([sys.executable, source_projection], check=True, timeout=10)\n"
        "ver = subprocess.check_output(['yosys', '-V'], text=True)\n"
        "digest = hashlib.sha256((ver + CC_SRC).encode()).hexdigest()[:16]\n"
        "so_path = Path(f'/tmp/frost-yosys-trace-{digest}.so')\n"
        "if not so_path.is_file():\n"
        "    lock_path = Path(f'/tmp/frost-yosys-trace-{digest}.lock')\n"
        "    with lock_path.open('w') as lock_file:\n"
        "        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)\n"
        "        if not so_path.is_file():\n"
        "            cc_path = Path(f'/tmp/frost-yosys-trace-{digest}-{os.getpid()}.cc')\n"
        "            tmp_so = Path(f'/tmp/frost-yosys-trace-{digest}-{os.getpid()}.so')\n"
        "            cc_path.write_text(CC_SRC)\n"
        "            try:\n"
        "                subprocess.run(['yosys-config', '--build', str(tmp_so), str(cc_path)], check=True)\n"
        "                os.replace(tmp_so, so_path)\n"
        "            finally:\n"
        "                cc_path.unlink(missing_ok=True)\n"
        "                tmp_so.unlink(missing_ok=True)\n"
        "os.environ['FROST_YOSYS_HEADER_TRACE'] = '../model/design.headers'\n"
        f"{predicate_setup}"
        "os.execvp('yosys', ['yosys', *WARNING_ARGS, '-m', str(so_path), *args])\n"
    )
    wrapper_path.write_text(script)
    wrapper_path.chmod(0o755)
    return wrapper_path


def yosys_log_events(
    log_text: str, *, structured: bool = False
) -> list[tuple[str, str]]:
    """Extract contiguous top-level script banners and pass headers."""
    events: list[tuple[str, str]] = []
    expected_num = 1
    saw_end = False

    if structured:
        for raw_line in log_text.splitlines():
            if not raw_line:
                continue
            if saw_end:
                raise ValueError(f"trailing event after End of script: {raw_line!r}")
            tag, sep, payload = raw_line.partition("\t")
            if not sep:
                raise ValueError(f"malformed header trace line: {raw_line!r}")
            if tag == "S":
                script_match = _YOSYS_SCRIPT_BANNER.match(payload)
                if script_match is None:
                    raise ValueError(f"unexpected script banner: {payload!r}")
                events.append(("script", script_match[1]))
            elif tag == "H":
                top_match = _YOSYS_TOP_HEADER.match(payload)
                if top_match is None:
                    continue
                num = int(top_match[1])
                rest = top_match[2]
                if num != expected_num:
                    raise ValueError(
                        f"non-contiguous Yosys header number: expected {expected_num}, got {num} ({rest!r})"
                    )
                if not rest.startswith("Executing "):
                    raise ValueError(f"unexpected top-level Yosys header: {payload!r}")
                expected_num += 1
                events.append(("exec", rest.removeprefix("Executing ")))
            elif tag == "E":
                if not payload.startswith("End of script."):
                    raise ValueError(f"unexpected end banner: {payload!r}")
                saw_end = True
            else:
                raise ValueError(f"unknown header trace tag {tag!r}")
        if not saw_end:
            raise ValueError("Yosys header trace lacks 'End of script.'")
        return events

    for line in log_text.splitlines():
        if line.startswith("End of script."):
            saw_end = True
            continue
        script_match = _YOSYS_SCRIPT_BANNER.match(line)
        if script_match is not None:
            events.append(("script", script_match[1]))
            continue
        top_match = _YOSYS_TOP_HEADER.match(line)
        if top_match is not None:
            num = int(top_match[1])
            rest = top_match[2]
            if num != expected_num:
                raise ValueError(
                    f"non-contiguous Yosys header number: expected {expected_num}, got {num} ({rest!r})"
                )
            if not rest.startswith("Executing "):
                raise ValueError(f"unexpected top-level Yosys header: {line!r}")
            expected_num += 1
            events.append(("exec", rest.removeprefix("Executing ")))
    if not saw_end:
        raise ValueError("Yosys base log lacks 'End of script.'")
    return events


def check_yosys_log(
    log_text: str,
    parsed: list[sby_config.ParsedCommand],
    *,
    structured: bool = False,
) -> None:
    """Run an ordered header check of Yosys base execution against parsed commands."""
    if any(cmd.included_from for cmd in parsed) and not any(
        cmd.form.id == "script" for cmd in parsed
    ):
        raise AssertionError("check_yosys_log requires keep_script_entries=True")
    events = yosys_log_events(log_text, structured=structured)
    if not events or events[0] != ("script", "../model/design.ys"):
        raise ValueError(f"unexpected first Yosys log event: {events[:1]!r}")
    pos = 1

    def consume_derive() -> None:
        nonlocal pos
        while (
            pos < len(events)
            and events[pos][0] == "exec"
            and events[pos][1].startswith("AST frontend in derive mode")
        ):
            pos += 1

    def require_prefix(prefix: str, context: str) -> str:
        nonlocal pos
        if (
            pos >= len(events)
            or events[pos][0] != "exec"
            or not events[pos][1].startswith(prefix)
        ):
            got = events[pos] if pos < len(events) else "EOF"
            raise ValueError(f"{context}: expected {prefix!r}, got {got!r}")
        header = events[pos][1]
        pos += 1
        return header

    for cmd in parsed:
        kind = cmd.form.log_kind
        context = " ".join(cmd.args)
        if kind == "none":
            continue
        if kind == "script":
            ys_name = cmd.args[1]
            if pos >= len(events) or events[pos] != ("script", ys_name):
                got = events[pos] if pos < len(events) else "EOF"
                raise ValueError(f"expected included script {ys_name!r}, got {got!r}")
            pos += 1
            continue
        if kind == "verilog":
            sources: list[str] = []
            idx = 1
            while idx < len(cmd.args):
                token = cmd.args[idx]
                if token == "-D":
                    idx += 2
                    continue
                if not token.startswith("-"):
                    sources.append(token)
                idx += 1
            for source_arg in sources:
                header = require_prefix("Verilog-2005 frontend: ", context)
                logged_path = header.removeprefix("Verilog-2005 frontend: ").strip()
                if Path(logged_path).name != Path(source_arg).name:
                    raise ValueError(
                        f"{context}: expected {source_arg!r}, got {logged_path!r}"
                    )
        elif kind == "slang":
            require_prefix("SLANG frontend.", context)
        elif kind == "chparam":
            consume_derive()
        elif kind == "hierarchy":
            require_prefix("HIERARCHY pass", context)
            consume_derive()
        elif kind == "pass":
            require_prefix(f"{cmd.form.command.upper()} pass", context)
        elif kind == "json_backend":
            require_prefix("JSON backend.", context)
        elif kind == "rtlil_backend":
            require_prefix("RTLIL backend.", context)
        else:
            raise AssertionError(f"unhandled log_kind: {kind}")

    # SymbiYosys's base step closes model/design.ys with hierarchy -smtcheck,
    # optional rename -witness, write_jny and write_rtlil.
    require_prefix("HIERARCHY pass", "sby base trailer")
    consume_derive()
    require_prefix("jny backend.", "sby base trailer")
    require_prefix("RTLIL backend.", "sby base trailer")
    if pos != len(events):
        raise ValueError(f"unexpected trailing Yosys log events: {events[pos:]!r}")


def _solver_verdict(result: subprocess.CompletedProcess[str], workdir: Path) -> str:
    """Return the solver's summary banner from result or staged logfile/status."""
    output = (result.stdout or "") + (result.stderr or "")
    for text in (
        output,
        (workdir / "logfile.txt").read_text(errors="replace")
        if (workdir / "logfile.txt").is_file()
        else "",
    ):
        done = [line.strip() for line in text.splitlines() if "DONE (" in line]
        if done:
            match = re.search(r"DONE \([^)]+\)", done[-1])
            return match[0] if match else done[-1]
    if (workdir / "status").is_file():
        words = (workdir / "status").read_text(errors="replace").split()
        if words:
            return f"{words[0]} (rc={result.returncode})"
    return f"rc={result.returncode}"


def _output_has_engine_pass(output: str) -> bool:
    """Report whether SymbiYosys output records a final engine PASS verdict."""
    if "did not return a status" in output:
        return False
    done = [line.strip() for line in output.splitlines() if "DONE (" in line]
    if not done or "DONE (PASS, rc=0)" not in done[-1]:
        return False
    return bool(
        re.search(
            r"engine_\d+(?:\.\w+)?: Status returned by engine(?: for \w+)?: pass\b"
            r"|engine_\d+ \([^)]+\) returned pass\b"
            r"|engine_\d+\.\w+: ##\s+[0-9:]+\s+Status: passed\b",
            output,
            re.I,
        )
    )


def check_twin_interfaces(path: Path, comparison: TwinComparison) -> None:
    """Check the register clocks, initial state and ordered ports of both cut designs."""
    if not path.is_file():
        raise ValueError(f"missing compiled twin interfaces in {path.name}")
    try:
        modules = json.loads(path.read_bytes())["modules"]
        interfaces = []
        inits_by_form: dict[str, dict[str, object]] = {}
        for form in ("gold", "gate"):
            module = modules[form]
            ports = module["ports"]
            inits = {
                name: net["attributes"]["init"]
                for name, net in module["netnames"].items()
                if "init" in net["attributes"]
            }
            if comparison.initialized_nets == 0:
                for name in inits:
                    raise ValueError(f"{form}: {name} has a compiled initial value")
            elif len(inits) != comparison.initialized_nets:
                raise ValueError(
                    f"{form}: expected {comparison.initialized_nets} compiled initial values, "
                    f"found {len(inits)}"
                )
            inits_by_form[form] = inits
            dffs = {
                name: cell
                for name, cell in module["cells"].items()
                if cell["type"] == "$dff"
            }
            if len(dffs) != comparison.registers:
                raise ValueError(
                    f"{form}: expected {comparison.registers} compiled $dff cells, found {len(dffs)}"
                )
            clock = comparison.clock
            if clock is not None:
                port = ports.get(clock)
                if (
                    port is None
                    or port["direction"] != "input"
                    or len(port["bits"]) != 1
                    or type(port["bits"][0]) is not int
                ):
                    raise ValueError(f"{form}: {clock} must be a scalar clock input")
            for name, cell in dffs.items():
                if int(cell["parameters"]["CLK_POLARITY"], 2) != 1:
                    raise ValueError(
                        f"{form}: {name} does not use the rising clock edge"
                    )
                if clock is None or cell["connections"]["CLK"] != ports[clock]["bits"]:
                    raise ValueError(
                        f"{form}: {name}.CLK does not use the declared clock input {clock}"
                    )
            interfaces.append(
                [
                    (
                        name,
                        port["direction"],
                        len(port["bits"]),
                        port.get("offset", 0),
                        port.get("upto", 0),
                        port.get("signed", 0),
                    )
                    for name, port in ports.items()
                ]
            )
    except (KeyError, TypeError, AttributeError) as error:
        raise ValueError(f"invalid compiled twin interfaces in {path.name}") from error
    if inits_by_form["gold"] != inits_by_form["gate"]:
        raise ValueError("compiled twin initial values differ")
    for gold, gate in zip_longest(*interfaces):
        if gold != gate:
            raise ValueError(f"compiled twin ports differ: gold {gold}, gate {gate}")


@pytest.mark.parametrize(
    ("field", "value"),
    [("upto", 1), ("offset", 1), ("signed", 1), ("direction", "input"), ("bits", [7])],
)
def test_twin_port_shape(tmp_path: Path, field: str, value: object) -> None:
    """The compiled declarations must agree even when equiv_make matches a net."""
    path = tmp_path / "twin_ports.json"
    gold = {"direction": "output", "bits": [2, 3]}
    gate: dict[str, object] = {"direction": "output", "bits": [9, 7]}
    modules = {
        name: {"ports": {"y": port}, "cells": {}, "netnames": {}}
        for name, port in (("gold", gold), ("gate", gate))
    }
    path.write_text(json.dumps({"modules": modules}))
    check_twin_interfaces(
        path, TWIN_COMPARISONS["pd_target_candidate_twin", "pdt_twin"]
    )
    gate[field] = value
    path.write_text(json.dumps({"modules": modules}))
    with pytest.raises(ValueError, match="compiled twin ports differ"):
        check_twin_interfaces(
            path, TWIN_COMPARISONS["pd_target_candidate_twin", "pdt_twin"]
        )


@pytest.mark.parametrize("other", [("b", "a"), ("a",), ("a", "b", "c")])
def test_twin_compiled_port_order_and_membership(
    tmp_path: Path, other: tuple[str, ...]
) -> None:
    """Even an extra or reordered port changes the compiled interface."""
    path = tmp_path / "twin_ports.json"
    modules = {
        form: {
            "ports": {
                name: {"direction": "input", "bits": [bit]}
                for bit, name in enumerate(names, 2)
            },
            "cells": {},
            "netnames": {},
        }
        for form, names in (("gold", ("a", "b")), ("gate", other))
    }
    path.write_text(json.dumps({"modules": modules}))
    with pytest.raises(ValueError, match="compiled twin ports differ"):
        check_twin_interfaces(
            path, TWIN_COMPARISONS["pd_target_candidate_twin", "pdt_twin"]
        )


@pytest.mark.parametrize(
    ("edits", "reason"),
    [
        ({}, None),
        (
            {"gate.cells.q.connections.CLK": [8]},
            "gate: q.CLK does not use the declared clock input clk",
        ),
        (
            {"gold.cells.q.connections.CLK": [3], "gate.cells.q.connections.CLK": [8]},
            "gold: q.CLK does not use the declared clock input clk",
        ),
        (
            {"gate.cells.q.parameters.CLK_POLARITY": "0"},
            "gate: q does not use the rising clock edge",
        ),
        (
            {"gate.cells.q.connections.CLK": ["1"]},
            "gate: q.CLK does not use the declared clock input clk",
        ),
        ({"gate.ports": {}}, "gate: clk must be a scalar clock input"),
        (
            {"gate.ports.clk.direction": "output"},
            "gate: clk must be a scalar clock input",
        ),
        ({"gate.ports.clk.bits": [7, 9]}, "gate: clk must be a scalar clock input"),
        ({"gate.ports.clk.bits": ["1"]}, "gate: clk must be a scalar clock input"),
        ({"gate.cells": {}}, "gate: expected 1 compiled $dff cells, found 0"),
        (
            {"gate.netnames.value.attributes.init": "1"},
            "gate: value has a compiled initial value",
        ),
    ],
)
def test_twin_compiled_state(
    tmp_path: Path, edits: dict[str, object], reason: str | None
) -> None:
    """Clock net IDs are local to each module. Both must resolve to the declared input."""
    path = tmp_path / "twin_ports.json"
    spec = replace(
        TWIN_COMPARISONS["decoded_bundle_queue_twin", "dbq_twin"],
        registers=1,
        clock="clk",
    )
    modules: dict[str, Any] = {}
    for form, bit in (("gold", 2), ("gate", 7)):
        modules[form] = {
            "ports": {
                "clk": {"direction": "input", "bits": [bit]},
                "advance": {"direction": "input", "bits": [bit + 1]},
            },
            "netnames": {"value": {"attributes": {}}},
            "cells": {
                "q": {
                    "type": "$dff",
                    "parameters": {"CLK_POLARITY": "1"},
                    "connections": {"CLK": [bit]},
                }
            },
        }
    for field, value in edits.items():
        keys = field.split(".")
        record = modules
        for key in keys[:-1]:
            record = record[key]
        record[keys[-1]] = value
    path.write_text(json.dumps({"modules": modules}))
    if reason is None:
        check_twin_interfaces(path, spec)
    else:
        with pytest.raises(ValueError, match=re.escape(reason)):
            check_twin_interfaces(path, spec)


def test_twin_compiled_initialized_nets_must_match(tmp_path: Path) -> None:
    """Declared RAM initializers must agree in count, net name, and bit value."""
    path = tmp_path / "twin_ports.json"
    spec = replace(
        TWIN_COMPARISONS["store_queue_twin", "sq_twin"],
        registers=1,
        clock="clk",
        initialized_nets=1,
    )

    def write(gold_inits: dict[str, str], gate_inits: dict[str, str]) -> None:
        modules = {
            form: {
                "ports": {"clk": {"direction": "input", "bits": [bit]}},
                "netnames": {
                    name: {"attributes": {"init": val}} for name, val in inits.items()
                },
                "cells": {
                    "q": {
                        "type": "$dff",
                        "parameters": {"CLK_POLARITY": "1"},
                        "connections": {"CLK": [bit]},
                    }
                },
            }
            for form, bit, inits in (
                ("gold", 2, gold_inits),
                ("gate", 7, gate_inits),
            )
        }
        path.write_text(json.dumps({"modules": modules}))

    write({"ram[0]": "0000"}, {"ram[0]": "0000"})
    check_twin_interfaces(path, spec)
    write({"ram[0]": "0000"}, {"ram[0]": "0001"})
    with pytest.raises(ValueError, match="compiled twin initial values differ"):
        check_twin_interfaces(path, spec)
    write({"ram[0]": "0000"}, {})
    with pytest.raises(ValueError, match="expected 1 compiled initial values, found 0"):
        check_twin_interfaces(path, spec)


def _verify_staged_engine_pass(workdir: Path, cfg: sby_config.TaskConfig) -> str | None:
    """Return an error reason if workdir lacks a genuine engine PASS verdict."""
    if not (workdir / "engine_0").is_dir():
        return "missing engine_0 directory (no solver engine ran)"
    pass_file = workdir / "PASS"
    if not pass_file.is_file():
        return "missing SymbiYosys PASS summary file"
    pass_summary = pass_file.read_text(errors="replace")
    if "did not return a status" in pass_summary:
        return "engine did not return a status"
    logfile = workdir / "logfile.txt"
    if logfile.is_file():
        log_text = logfile.read_text(errors="replace")
        if "did not return a status" in log_text:
            return "engine did not return a status"
        done = [line.strip() for line in log_text.splitlines() if "DONE (" in line]
        if not done or "DONE (PASS, rc=0)" not in done[-1]:
            return "logfile.txt lacks final DONE (PASS, rc=0)"
    mode = cfg.options.get("mode")
    engine = cfg.engines[0][0] if cfg.engines else ""
    if mode == "prove" and engine == "smtbmc":
        for subcase in ("basecase", "induction"):
            if not re.search(
                rf"^engine_0 \([^)]+\) returned pass for {subcase}$",
                pass_summary,
                re.M | re.I,
            ):
                return f"PASS summary lacks engine_0 pass for {subcase}"
    else:
        if not re.search(
            r"^engine_0 \([^)]+\) returned pass$",
            pass_summary,
            re.M | re.I,
        ):
            return "PASS summary lacks engine_0 returned pass"
    return None


class FormalArtifactError(ValueError):
    """Post-solver artifact or model-log verification failed after sby exited 0."""

    def __init__(
        self,
        target: str,
        task: str,
        solver_verdict: str,
        reason: str,
        result: subprocess.CompletedProcess[str],
    ) -> None:
        """Record the target, task, distinct solver verdict, and check failure."""
        self.target = target
        self.task = task
        self.solver_verdict = solver_verdict
        self.reason = reason
        self.result = result
        super().__init__(
            f"{target}:{task}: solver {solver_verdict}; model check failed: {reason}"
        )


class FormalRunner:
    """Run SymbiYosys tasks from the repository's formal/ directory."""

    def __init__(self) -> None:
        """Initialize runner with paths."""
        self.test_dir = Path(__file__).parent.resolve()
        self.root_dir = self.test_dir.parent
        self.formal_dir = self.root_dir / FORMAL_DIR

        if not self.formal_dir.exists():
            raise FileNotFoundError(f"Formal directory not found: {self.formal_dir}")

    def verify_model_artifacts(
        self,
        workdir: Path,
        sby_path: Path,
        target_name: str,
        task: str,
        result: subprocess.CompletedProcess[str],
        *,
        require_engine_pass: bool = True,
    ) -> None:
        """Require solver pass, staged inputs, model/design.il, and header trace."""
        verdict = _solver_verdict(result, workdir)

        def fail(reason: str) -> None:
            raise FormalArtifactError(target_name, task, verdict, reason, result)

        if not workdir.is_dir():
            fail(f"missing workdir {workdir.name}")
        config_sby = workdir / "config.sby"
        if not config_sby.is_file():
            fail("missing config.sby")
        src_dir = workdir / "src"
        if not src_dir.is_dir():
            fail("missing src directory")
        design_il = workdir / "model/design.il"
        if not design_il.is_file() or design_il.stat().st_size == 0:
            fail("missing or empty model/design.il")
        design_log = workdir / "model/design.log"
        if not design_log.is_file():
            fail("missing model/design.log")
        design_headers = workdir / "model/design.headers"
        if not design_headers.is_file():
            fail("missing model/design.headers")

        try:
            staged_cfg = sby_config.read_source(
                config_sby, sby_config.read_checked_text(config_sby)
            ).task("")
            checkout_cfg = sby_config.source(sby_path).task(task)
            if (
                staged_cfg.options != checkout_cfg.options
                or staged_cfg.engines != checkout_cfg.engines
                or staged_cfg.files != checkout_cfg.files
                or set(staged_cfg._inline) != set(checkout_cfg._inline)
            ):
                fail("staged config.sby differs from checkout task")
            expected_mode = registered_task_mode(task)
            if checkout_cfg.options.get("mode") != expected_mode:
                fail(
                    f"[options] mode {checkout_cfg.options.get('mode')!r} "
                    f"does not match registered mode {expected_mode!r}"
                )
            pair = (target_name, task)
            if "skip" in checkout_cfg.options:
                if SKIP_PINNED.get(pair) != int(checkout_cfg.options["skip"]):
                    fail(f"unpinned skip option on {target_name}:{task}")
            elif pair in SKIP_PINNED:
                fail(f"missing pinned skip option on {target_name}:{task}")
            uses_start = tuple(checkout_cfg.engines[0]) == (
                "abc",
                "bmc3",
                "-c",
                "-S",
                "139",
            )
            if uses_start != (pair in FATAL_START_FRAME_TASKS):
                fail(f"start-frame engine pin mismatch on {target_name}:{task}")
            if require_engine_pass:
                output = (result.stdout or "") + (result.stderr or "")
                if output and not _output_has_engine_pass(output):
                    fail("solver output lacks an engine DONE (PASS, rc=0) verdict")
                engine_err = _verify_staged_engine_pass(workdir, staged_cfg)
                if engine_err is not None:
                    fail(engine_err)
            for dest in staged_cfg.files:
                if not (src_dir / dest).is_file():
                    fail(f"missing staged source {dest}")
            expanded = checkout_cfg.parsed(sby_path.parent, keep_script_entries=True)
            needs_ports, _ = check_formal_input_contract(
                target_name, task, sby_path.parent, checkout_cfg, expanded=expanded
            )
            if needs_ports:
                check_twin_interfaces(
                    src_dir / "twin_ports.json", TWIN_COMPARISONS[pair]
                )
            if pair == l0_store_boundary.PAIR:
                l0_store_boundary.check_model(src_dir / "twin_ports.json")
            if pair in PREDICTOR_ASSERTION_TASKS:
                sources, _, _ = PREDICTOR_ASSERTION_TASKS[pair]
                for name in sources:
                    checkout = sby_path.parent / checkout_cfg.files[name]
                    if (src_dir / name).read_bytes() != checkout.read_bytes():
                        fail(f"staged assertion harness differs from checkout: {name}")
            local_cfg = replace(
                staged_cfg, files={dest: dest for dest in staged_cfg.files}
            )
            parsed = local_cfg.parsed(src_dir, keep_script_entries=True)
            if parsed != expanded:
                fail("staged script differs from checkout task")
            check_yosys_log(
                sby_config.read_checked_text(design_headers),
                parsed,
                structured=True,
            )
        except FormalArtifactError:
            raise
        except (sby_config.ConfigError, ValueError) as error:
            fail(str(error))

    def run_formal(
        self,
        target: FormalTarget,
        task: str,
        capture_output: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        """Run SymbiYosys on a target with a specific task.

        Args:
            target: The formal verification target to run.
            task: SymbiYosys task name (e.g., "bmc", "cover").
            capture_output: If True, capture stdout/stderr. Otherwise show tool output.

        Returns:
            CompletedProcess with results.
        """
        sby_path = self.formal_dir / target.sby_file
        if not sby_path.exists():
            raise FileNotFoundError(f"SBY file not found: {sby_path}")

        checkout_cfg = sby_config.source(sby_path).task(task)
        expanded = checkout_cfg.parsed(sby_path.parent, keep_script_entries=True)
        if (target.name, task) == l0_store_boundary.PAIR:
            l0_store_boundary.check_script(checkout_cfg, sby_path.parent)
        _, entries = check_formal_input_contract(
            target.name, task, sby_path.parent, checkout_cfg, expanded=expanded
        )
        expected_mode = registered_task_mode(task)
        if checkout_cfg.options.get("mode") != expected_mode:
            raise sby_config.ConfigError(
                f"{target.name}:{task}: mode {checkout_cfg.options.get('mode')!r} "
                f"does not match registered mode {expected_mode!r}"
            )

        timeout = formal_task_timeout_s(target.name, task)
        deadline = time.monotonic() + timeout
        check_fatal_frame = (target.name, task) in FATAL_START_FRAME_TASKS
        with tempfile.TemporaryDirectory(prefix="frost-sby-") as tmp_dir:
            workdir = Path(tmp_dir) / f"{target.name}_{task}"
            yosys_wrapper = write_yosys_header_wrapper(
                Path(tmp_dir) / "yosys_wrapper.py",
                entries,
                uses_slang=any(cmd.form.id == "read_slang" for cmd in expanded),
                source_projection=sby_config.store_completion_cone_helper(sby_path),
            )
            cmd = [
                "sby",
                "-f",
                "-d",
                str(workdir),
                "--yosys",
                str(yosys_wrapper),
                str(sby_path),
                task,
            ]
            if capture_output or check_fatal_frame:
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    cwd=self.formal_dir,
                    timeout=timeout,
                )
                if not capture_output:
                    print(result.stdout or "", end="")
                    print(result.stderr or "", end="", file=sys.stderr)
                if check_fatal_frame and result.returncode == 0:
                    output = (result.stdout or "") + (result.stderr or "")
                    if not fatal_frame_completed(output):
                        raise ValueError(
                            "Fatal-status BMC did not complete its frame-139 check"
                        )
            else:
                result = subprocess.run(
                    cmd,
                    cwd=self.formal_dir,
                    timeout=timeout,
                    text=True,
                )
            if result.returncode == 0:
                self.verify_model_artifacts(
                    workdir, sby_path, target.name, task, result
                )
                if helper := sby_config.cmo_replay_helper(sby_path, task):
                    remaining = deadline - time.monotonic()
                    replay_cmd = [
                        sys.executable,
                        str(helper),
                        "--replay-verified",
                        str(workdir),
                        str(remaining),
                    ]
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(replay_cmd, timeout)
                    replay = subprocess.run(
                        replay_cmd,
                        cwd=self.formal_dir,
                        capture_output=capture_output,
                        text=True,
                        timeout=remaining,
                    )
                    if capture_output:
                        result.stdout = (result.stdout or "") + (replay.stdout or "")
                        result.stderr = (result.stderr or "") + (replay.stderr or "")
                    result.returncode = replay.returncode
            return result

    def check_for_errors(
        self, result: subprocess.CompletedProcess[str]
    ) -> tuple[bool, list[str]]:
        """Return (has_error, error_lines) from the SymbiYosys output."""
        has_error = False
        error_lines = []

        output = (result.stdout or "") + (result.stderr or "")

        if "DONE (FAIL" in output:
            has_error = True
            for line in output.splitlines():
                if "Assert failed" in line or "FAIL" in line:
                    error_lines.append(line.strip())

        # A "DONE (ERROR" line means sby itself failed (syntax error, missing
        # file) rather than a property failing.
        if "DONE (ERROR" in output:
            has_error = True
            for line in output.splitlines():
                if "ERROR" in line:
                    error_lines.append(line.strip())

        if result.returncode != 0:
            has_error = True
            if not error_lines:
                error_lines.append(f"sby exited with code {result.returncode}")

        # Require an explicit engine PASS verdict whenever output was captured.
        if (
            not has_error
            and (getattr(result, "stdout", None), getattr(result, "stderr", None))
            != (None, None)
            and not _output_has_engine_pass(output)
        ):
            has_error = True
            done = [line.strip() for line in output.splitlines() if "DONE (" in line]
            error_lines.append(
                done[-1]
                if done
                else "sby exited 0 without an engine DONE (PASS, rc=0) verdict"
            )

        return has_error, error_lines

    def parse_results(self, result: subprocess.CompletedProcess[str]) -> dict[str, Any]:
        """Return passed, status, and details parsed from SymbiYosys output.

        Include elapsed only when SymbiYosys prints an elapsed-time line.
        """
        output = (result.stdout or "") + (result.stderr or "")
        info: dict[str, Any] = {
            "passed": result.returncode == 0,
            "status": "UNKNOWN",
            "details": [],
        }

        for line in output.splitlines():
            line = line.strip()
            if "DONE (PASS" in line:
                info["status"] = "PASS"
            elif "DONE (FAIL" in line:
                info["status"] = "FAIL"
            elif "DONE (ERROR" in line:
                info["status"] = "ERROR"
            elif "Assert failed" in line:
                info["details"].append(line)
            elif "reached cover statement" in line:
                info["details"].append(line)
            elif "Elapsed clock time" in line:
                info["elapsed"] = line

        return info


def _stage_twin(fixture: Path, name: str) -> tuple[FormalRunner, FormalTarget, Path]:
    runner = FormalRunner()
    target = next(t for t in FORMAL_TARGETS if t.name == name)
    staged = sby_config.stage_proof(
        runner.formal_dir / target.sby_file, runner.root_dir, fixture
    )
    runner.formal_dir = staged.parent
    return runner, target, staged


@pytest.mark.parametrize(
    ("body", "diagnostic"),
    [
        ("assign y = a ? 1'b1 : 1'bz;", "port"),
        ("always @* if (a) y = 1'bz; else y = 1'b0;", "process"),
        ("child #(.VALUE(1'bz)) u(.y(y));", "VALUE"),
        ("always @* y = a === 1'bz;", "port"),
        ("always @* y = $isunknown(a);", "port"),
        ("always @* casez ({a, a}) 2'b1?: y = 1; default: y = 0; endcase", ""),
    ],
)
def test_elaborated_formal_input_values(
    tmp_path: Path, body: str, diagnostic: str
) -> None:
    """Check ordinary prep, live children and case patterns at the elaboration boundary."""
    src = tmp_path / "src"
    model = tmp_path / "model"
    src.mkdir()
    model.mkdir()
    (src / "design.sv").write_text(
        "module child #(parameter VALUE = 0)(output y); assign y = VALUE; endmodule\n"
        "module unused(output y); assign y = 1'bz; endmodule\n"
        f"module top(input a, output reg y); {body} endmodule\n"
    )
    (model / "design.ys").write_text("read -sv design.sv\nprep -top top\n")
    wrapper = write_yosys_header_wrapper(tmp_path / "yosys_wrapper.py")
    result = subprocess.run(
        [str(wrapper), "-Q", "-T", "-s", "../model/design.ys"],
        cwd=src,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if diagnostic:
        assert result.returncode != 0
        assert "High-impedance constant in elaborated module" in result.stderr
        assert diagnostic in result.stderr
    else:
        assert result.returncode == 0, result.stderr
        assert "Checked elaborated formal inputs of top" in result.stdout


@pytest.mark.parametrize(
    ("expression", "diagnostic"),
    [
        ("a ? 1'bz : 1'b0", "$tribuf"),
        (
            "1'bz",
            "ERROR: high-impedance state (Z) will be treated as undefined state (X)",
        ),
        (
            "a === 1'bz",
            "ERROR: high-impedance state (Z) will be treated as undefined state (X)",
        ),
        (
            "1'b?",
            "ERROR: high-impedance state (Z) will be treated as undefined state (X)",
        ),
    ],
)
def test_slang_high_impedance_driver(
    tmp_path: Path, expression: str, diagnostic: str
) -> None:
    """Catch both frontend Z-to-X conversion and conditional tri-state drivers."""
    runner = FormalRunner()
    runner.formal_dir = tmp_path
    target = FormalTarget("slang_z.sby", "Slang elaboration", ("bmc",))
    (tmp_path / "top.sv").write_text(
        f"module top(input a, output y); assign y = {expression}; endmodule\n"
    )
    (tmp_path / target.sby_file).write_text(
        "[tasks]\nbmc\n[options]\nmode bmc\ndepth 1\n[engines]\nsmtbmc boolector\n"
        "[script]\nscript sources.ys\nhierarchy -top top\nprep -top top\n[files]\ntop.sv\n"
        "[file sources.ys]\nread_slang --top top --single-unit top.sv\n"
    )
    result = runner.run_formal(target, "bmc")
    assert result.returncode != 0
    assert diagnostic in result.stdout


@pytest.mark.parametrize(
    ("variant", "error"),
    [
        ("retained", None),
        ("line_shift", None),
        ("formatting", None),
        ("changed_operand", "found 0"),
        ("changed_expression", "found 0"),
        ("renamed_block", "found 0"),
        ("removed", "found 0"),
        ("comment_only", "found 0"),
        ("empty_source", "found 0"),
        ("duplicate", "found 2"),
        ("duplicate_entry", "duplicate high-impedance predicate exemption"),
        ("other_file", "expected one staged predicate source"),
        ("inactive", "Unused high-impedance predicate exemption"),
        ("extra_comparison", "High-impedance constant in elaborated module"),
        ("new_driver", "High-impedance constant in elaborated module"),
        ("another_block", "High-impedance constant in elaborated module"),
        ("unlisted", "High-impedance constant in elaborated module"),
    ],
)
def test_high_impedance_exemption_through_runner(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, variant: str, error: str | None
) -> None:
    """Only the unique named predicate may supply the compiled comparison operand."""
    runner = FormalRunner()
    runner.formal_dir = tmp_path
    target = FormalTarget("predicate.sby", "unknown-value predicate", ("bmc",))
    source = "elsewhere/d.sv" if variant == "other_file" else "d.sv"
    (tmp_path / target.sby_file).write_text(
        "[tasks]\nbmc\n[options]\nmode bmc\ndepth 1\n[engines]\nsmtbmc boolector\n"
        "[script]\nread -formal -sv d.sv\nhierarchy -top top\nprep -top top\n[files]\n"
        f"{source}\n"
    )
    chosen = "another_task" if variant == "unlisted" else target.name
    entry = PredicateExemption(
        "d.sv", "top.known_input", "$isunknown ( a )", ((chosen, "bmc"),)
    )
    monkeypatch.setattr(
        sys.modules[__name__],
        "HIGH_IMPEDANCE_PENDING",
        (entry, entry) if variant == "duplicate_entry" else (entry,),
    )
    predicate = {
        "formatting": "$isunknown /* signal */ (\n	 a )",
        "changed_operand": "$isunknown(b)",
        "changed_expression": "!$isunknown(a)",
        "removed": "a",
        "comment_only": "a /* $isunknown(a) */",
    }.get(variant, "$isunknown(a)")
    label = "other" if variant == "renamed_block" else "known_input"
    extra = {"extra_comparison": "a === 1'bz", "new_driver": "1'bz"}.get(variant, "a")
    body = (
        "module top(input a, b, output y, extra);\n"
        + (
            "// unrelated change before the block\n\n"
            if variant == "line_shift"
            else ""
        )
        + f"if ({int(variant != 'inactive')}) begin : {label}\n"
        + f" assign y = {predicate};\n"
        + (
            " wire copy; assign copy = $isunknown(a);\n"
            if variant == "duplicate"
            else ""
        )
        + "end\n"
        + (
            "if (1) begin : second_check assign extra = $isunknown(a); end\n"
            if variant == "another_block"
            else f" assign extra = {extra};\n"
        )
        + " always @* assert (a == a); endmodule\n"
    )
    (tmp_path / source).parent.mkdir(exist_ok=True)
    (tmp_path / source).write_text("" if variant == "empty_source" else body)
    # The task sets its own compiled permission even if the caller supplies a span.
    monkeypatch.setenv("FROST_YOSYS_PENDING_PREDICATES", "d.sv:3.13-3.23")
    if error is not None and not error.startswith(("High-impedance", "Unused")):
        with pytest.raises(sby_config.ConfigError, match=error):
            runner.run_formal(target, "bmc")
        return
    result = runner.run_formal(target, "bmc")
    if error is None:
        assert result.returncode == 0, result.stdout + result.stderr
    else:
        assert result.returncode != 0
        assert error in result.stdout


def test_predicate_in_named_checks(tmp_path: Path) -> None:
    """Named assertions and properties retain the entire condition and enclosing blocks."""
    src = tmp_path / "checks.sv"
    src.write_text(
        "module top(input clk, a, b);\n"
        " always @* begin : guards\n"
        "   known: assert (b || !$isunknown(a));\n"
        " end\n"
        " p_known: assert property (@(posedge clk) disable iff (b) !$isunknown(a));\n"
        " property check_b; @(posedge clk) a |-> !$isunknown(b); endproperty\n"
        " if (1) begin wire y = $isunknown(a); end\n"
        " always @* begin : guarded\n"
        "   checked: assert (a) $display($isunknown(b)); else $display($isunknown(a));\n"
        " end\n"
        " `define WATCHED a\n"
        " if (1) begin : with_macro wire y = $isunknown(`WATCHED); end\n"
        "endmodule\n"
    )
    assert predicate_spans(src, "checks.sv") == {
        ("top.guards.known", "b || ! $isunknown ( a )"): ["checks.sv:3.25-3.35"],
        ("top.p_known", "@ ( posedge clk ) disable iff ( b ) ! $isunknown ( a )"): [
            "checks.sv:5.60-5.70"
        ],
        ("top.check_b", "@ ( posedge clk ) a |-> ! $isunknown ( b )"): [
            "checks.sv:6.42-6.52"
        ],
    }


@pytest.mark.parametrize(
    "change_operand", [False, True], ids=["line_shift", "changed_operand"]
)
def test_compiler_resolves_predicate_in_staged_file(
    tmp_path: Path, change_operand: bool
) -> None:
    """Grant the operand in the compiled copy only when its content still matches."""
    src = tmp_path / "src"
    model = tmp_path / "model"
    src.mkdir()
    model.mkdir()
    rtl = "module top(input a, b, output y);\n if (1) begin : known\n assign y = $isunknown(a);\n end\nendmodule\n"
    checkout = tmp_path / "rtl" / "d.sv"
    checkout.parent.mkdir()
    checkout.write_text(rtl)
    entry = PredicateExemption(
        "rtl/d.sv", "top.known", "$isunknown ( a )", (("sample", "bmc"),)
    )
    assert resolve_predicate_sites(tmp_path, (entry,)) == ("d.sv:3.13-3.23",)
    compiled = (
        rtl.replace("$isunknown(a)", "$isunknown(b)")
        if change_operand
        else "\n\n" + rtl
    )
    (src / "d.sv").write_text(compiled)
    (model / "design.ys").write_text("read -sv d.sv\nhierarchy -top top\n")
    wrapper = write_yosys_header_wrapper(tmp_path / "yosys_wrapper.py", (entry,))
    result = subprocess.run(
        [str(wrapper), "-Q", "-T", "-s", "../model/design.ys"],
        cwd=src,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if change_operand:
        assert result.returncode != 0
        assert (
            "expected one $isunknown predicate in rtl/d.sv at top.known"
            in result.stderr
        )
        assert "found 0" in result.stderr
    else:
        assert result.returncode == 0, result.stderr
        assert (
            "Retained high-impedance predicate exemption at d.sv:5.13-5.23"
            in result.stdout
        )


def test_in_script_twin_cannot_take_a_predicate_exemption(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The equivalence comparison always checks every input, including predicate operands."""
    target = next(t for t in FORMAL_TARGETS if t.name == "pd_target_candidate_twin")
    (task,) = target.tasks
    monkeypatch.setattr(
        sys.modules[__name__],
        "HIGH_IMPEDANCE_PENDING",
        (
            PredicateExemption(
                "pd_target_candidate.sv",
                "top.check",
                "$isunknown ( a )",
                ((target.name, task),),
            ),
        ),
    )
    with pytest.raises(
        sby_config.ConfigError,
        match="exemptions are forbidden for in-script comparisons",
    ):
        FormalRunner().run_formal(target, task)


def test_registered_proofs_require_empty_predicate_list(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Even a valid, uniquely resolved predicate cannot enter the registered inventory."""
    target = FormalTarget("sample.sby", "named predicate", ("bmc",))
    (tmp_path / target.sby_file).write_text(
        "[tasks]\nbmc\n[options]\nmode bmc\ndepth 1\n[engines]\nsmtbmc boolector\n"
        "[script]\nread -formal -sv d.sv\nprep -top top\n[files]\nd.sv\n"
    )
    (tmp_path / "d.sv").write_text(
        "module top(input a, output y); if (1) begin : known\n"
        " assign y = $isunknown(a); end endmodule\n"
    )
    entry = PredicateExemption(
        "d.sv", "top.known", "$isunknown ( a )", (("sample", "bmc"),)
    )
    module = sys.modules[__name__]
    monkeypatch.setattr(module, "FORMAL_DIR", str(tmp_path))
    monkeypatch.setattr(module, "FORMAL_TARGETS", [target])
    monkeypatch.setattr(module, "TWIN_COMPARISONS", {})
    monkeypatch.setattr(module, "PREDICTOR_ASSERTION_TASKS", {})
    monkeypatch.setattr(module, "HIGH_IMPEDANCE_PENDING", (entry,))
    with pytest.raises(AssertionError, match="empty predicate exemption list"):
        test_registered_formal_input_contracts()


@pytest.mark.parametrize(
    ("target_name", "filename", "original", "changed"),
    [
        ("backing_btb_twin", "backing_btb_twin.sv", "p_hit :", "p_other :"),
        (
            "tage_predictor_twin",
            "predictor_table_twin.sv",
            "ref_out.bank0 ==",
            "ref_out.bank0 !=",
        ),
        (
            "pd_history_twin",
            "predictor_fetch_contract.sv",
            "assert (!i_backing_hit[1]",
            "assert (i_backing_hit[1]",
        ),
        (
            "ittage_predictor_twin",
            "ittage_predictor_twin.sby",
            "select -assert-count 10",
            "select -assert-count 9",
        ),
    ],
)
def test_predictor_assertion_task_requires_its_checks(
    tmp_path: Path, target_name: str, filename: str, original: str, changed: str
) -> None:
    """Changing a label, predicate, assumption or selection invalidates the registration."""
    runner, target, staged = _stage_twin(tmp_path, target_name)
    path = staged.parent / filename
    source = path.read_text()
    assert source.count(original) == 1
    path.write_text(source.replace(original, changed))
    with pytest.raises(
        sby_config.ConfigError, match="assertion-harness check identity changed"
    ):
        runner.run_formal(target, "bmc")


def test_new_paired_assertion_harness_requires_full_comparison(tmp_path: Path) -> None:
    """The known assertion harness cannot authorize a differently named comparison."""
    runner, original, script = _stage_twin(tmp_path, "backing_btb_twin")
    target = replace(original, sby_file="another_predictor.sby")
    script.rename(script.with_name(target.sby_file))
    with pytest.raises(
        sby_config.ConfigError, match="missing twin comparison declaration"
    ):
        runner.run_formal(target, "prove")


def test_twin_gate_carry_rejects_high_impedance(tmp_path: Path) -> None:
    """A Z carry-in can compare equal to zero if it reaches the point solver."""
    runner, target, staged = _stage_twin(tmp_path, "pd_target_candidate_twin")
    (task,) = target.tasks
    clean = runner.run_formal(target, task)
    assert clean.returncode == 0, clean.stdout + clean.stderr
    cfg = sby_config.source(staged).task(task)
    rtl = staged.parent / cfg.files["pd_target_candidate.sv"]
    source = rtl.read_text()
    carry = "assign chain_ci = 1'b0;"
    assert source.count(carry) == 1
    rtl.write_text(source.replace(carry, "assign chain_ci = 1'bz;"))
    result = runner.run_formal(target, task)
    assert result.returncode != 0
    assert (
        "High-impedance constant in elaborated module pd_target_candidate"
        in result.stdout
    )
    assert "gen_chain[0].chain_ci" in result.stdout


def test_twin_forms_reject_erased_init_and_missing_clock(tmp_path: Path) -> None:
    """Removing init and the clock checks from both stashes must fail the registered task."""
    runner, target, staged = _stage_twin(tmp_path, "decoded_bundle_queue_twin")
    source = staged.read_text()
    clean = "opt_clean\ncheck -assert\n"
    clock = "select -assert-none t:$dff i:i_clk %co1:+$dff[CLK] %d\n"
    assert source.count(clean) == source.count(clock) == 2
    staged.write_text(
        source.replace(
            clean, "opt_clean\nsetattr -unset init\ncheck -assert\n"
        ).replace(clock, "")
    )
    with pytest.raises(sby_config.ConfigError, match="gold form.*setattr -unset init"):
        runner.run_formal(target, target.tasks[0])


@pytest.mark.parametrize("form", ["gold", "gate"])
@pytest.mark.parametrize(
    ("original", "replacement"),
    [
        ("select -assert-none a:init t:$initstate t:$anyinit\n", ""),
        (
            "select -assert-none a:init t:$initstate t:$anyinit t:$anyconst",
            "select -assert-none t:$anyconst",
        ),
        ("select -assert-none t:$dff i:i_clk %co1:+$dff[CLK] %d\n", ""),
        ("i:i_clk %co1:+$dff[CLK] %d", "i:i_advance %co1:+$dff[CLK] %d"),
        ("check -assert\n", "setattr -unset init\ncheck -assert\n"),
        ("rename -top", "setattr -unset init\nrename -top"),
    ],
)
def test_new_twin_checks_each_form_before_stash(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    form: str,
    original: str,
    replacement: str,
) -> None:
    """The general rule covers each arm of a newly declared comparison."""
    runner, template, staged = _stage_twin(tmp_path, "decoded_bundle_queue_twin")
    target = replace(template, sby_file="additional_comparison.sby")
    task = target.tasks[0]
    monkeypatch.setitem(
        TWIN_COMPARISONS, (target.name, task), TWIN_COMPARISONS[template.name, task]
    )
    staged = staged.rename(staged.with_name(target.sby_file))
    gold, separator, remainder = staged.read_text().partition("design -stash gold")
    gate, gate_end, tail = remainder.partition("design -stash gate")
    assert separator and gate_end and gold.count(original) == gate.count(original) == 1
    if form == "gold":
        gold = gold.replace(original, replacement)
    else:
        gate = gate.replace(original, replacement)
    staged.write_text(gold + separator + gate + gate_end + tail)
    with pytest.raises(
        sby_config.ConfigError,
        match=f"{form} form (expected|cannot change initial values)",
    ):
        runner.run_formal(target, task)


@pytest.mark.parametrize(
    ("registers", "clock"), [(19, None), (0, "i_clk"), (19, "*"), (-1, None)]
)
def test_twin_form_declaration_requires_clock_for_registers(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, registers: int, clock: str | None
) -> None:
    """Reject an inconsistent register count or an ambiguous clock selection."""
    runner, target, _ = _stage_twin(tmp_path, "decoded_bundle_queue_twin")
    pair = (target.name, target.tasks[0])
    monkeypatch.setitem(
        TWIN_COMPARISONS,
        pair,
        replace(TWIN_COMPARISONS[pair], registers=registers, clock=clock),
    )
    with pytest.raises(sby_config.ConfigError, match="declare one scalar clock input"):
        runner.run_formal(target, target.tasks[0])


def test_new_twin_checks_declared_clock_in_compiled_design(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A new task can choose its clock's name and leave free values independent."""
    runner, template, staged = _stage_twin(tmp_path, "decoded_bundle_queue_twin")
    target = replace(template, sby_file="additional_comparison.sby")
    task = target.tasks[0]
    spec = replace(
        TWIN_COMPARISONS[template.name, task],
        clock="queue_clock",
        paired_free=0,
        gold_only_free=6,
        gate_only_free=6,
        name_free=False,
    )
    monkeypatch.setitem(TWIN_COMPARISONS, (target.name, task), spec)
    monkeypatch.setitem(SBY_TASK_TIMEOUT_OVERRIDES_S, (target.name, task), 60)
    cfg = sby_config.source(staged).task(task)
    rtl = staged.parent / cfg.files["decoded_bundle_queue.sv"]
    rtl.write_text(rtl.read_text().replace("i_clk", "queue_clock"))
    staged = staged.rename(staged.with_name(target.sby_file))
    src = (
        staged.read_text()
        .replace("i:i_clk ", "i:queue_clock ")
        .replace("autoname t:$anyseq\n", "")
    )
    staged.write_text(
        src.replace(
            "dbq_twin: select -assert-count 6 t:$anyseq\nselect -assert-none t:$anyseq n:*_gold %i t:$anyseq n:*_gate %i",
            "dbq_twin: select -assert-count 12 t:$anyseq\nselect -assert-count 6 t:$anyseq n:*_gold %i\n"
            "select -assert-count 6 t:$anyseq n:*_gate %i",
        )
    )
    monkeypatch.setattr(sys.modules[__name__], "FORMAL_DIR", str(runner.formal_dir))
    test_opened_primitive_twin_comparison(target.name, task)
    result = runner.run_formal(target, task)
    assert result.returncode == 0, result.stdout + result.stderr


def test_twin_initial_values_require_repository_opening(tmp_path: Path) -> None:
    """An included opening cannot hide an init erasure from the form contract."""
    runner, target, staged = _stage_twin(tmp_path, "decoded_bundle_queue_twin")
    opening = staged.parent / UNDEFINED_OPENING_FILE
    opening.write_text(opening.read_text() + "setattr -unset init\n")
    with pytest.raises(
        sby_config.ConfigError, match="not the repository's free_undefined.ys"
    ):
        runner.run_formal(target, target.tasks[0])


def test_twin_solver_pass_requires_compiled_interface(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A successful solver run still needs its compiled gold and gate port artifact."""
    runner, target, _ = _stage_twin(tmp_path, "pd_target_candidate_twin")
    check = check_twin_interfaces

    def remove_artifact(path: Path, comparison: TwinComparison) -> None:
        path.unlink()
        check(path, comparison)

    monkeypatch.setattr(sys.modules[__name__], "check_twin_interfaces", remove_artifact)
    with pytest.raises(FormalArtifactError, match="missing compiled twin interfaces"):
        runner.run_formal(target, target.tasks[0])


def test_twin_register_edge_selected_in_common_code(tmp_path: Path) -> None:
    """A gate-arm macro can select a falling edge outside the primitive conditional."""
    runner, target, staged = _stage_twin(tmp_path, "decoded_bundle_queue_twin")
    (task,) = target.tasks
    cfg = sby_config.source(staged).task(task)
    rtl = staged.parent / cfg.files["decoded_bundle_queue.sv"]
    source = rtl.read_text()
    arm = "if (SPLIT_SHADOW_STALL) begin : gen_split_shadow_stall\n`ifdef FROST_XILINX_PRIMS"
    update = (
        "    always_ff @(posedge i_clk) begin\n      nonempty_copy_q <= nonempty_next;"
    )
    assert source.count(arm) == source.count(update) == 1
    rtl.write_text(
        source.replace(arm, arm + "\n`define DBQ_TWIN_FALL").replace(
            update,
            "`ifdef DBQ_TWIN_FALL\n    always_ff @(negedge i_clk) begin\n`else\n"
            "    always_ff @(posedge i_clk) begin\n`endif\n      nonempty_copy_q <= nonempty_next;",
        )
    )
    with pytest.raises(
        FormalArtifactError, match="gate: .* does not use the rising clock edge"
    ):
        runner.run_formal(target, task)


@pytest.mark.parametrize(
    ("original", "changed", "reason"),
    [
        ("write_json twin_ports.json", "", "expected compiled twin_ports.json"),
        ("pdt_twin: select -assert-min 16 t:$equiv", "", "declared floors"),
        ("equiv_simple\n", "equiv_simple @blk\n", "unselected proof"),
        ("equiv_status -assert\n", "equiv_status -assert @blk\n", "unselected proof"),
        (
            "hierarchy -check -top pd_target_candidate",
            "opt_clean\nhierarchy -check -top pd_target_candidate",
            "requires hierarchy",
        ),
    ],
)
def test_twin_input_contract_through_runner(
    tmp_path: Path, original: str, changed: str, reason: str
) -> None:
    """Reject a missing interface, a partial point proof or an early transformation."""
    runner, target, staged = _stage_twin(tmp_path, "pd_target_candidate_twin")
    source = staged.read_text()
    assert original in source
    staged.write_text(source.replace(original, changed, 1))
    with pytest.raises(sby_config.ConfigError, match=reason):
        runner.run_formal(target, target.tasks[0])


@pytest.mark.parametrize("omit_comparison", (False, True))
def test_unregistered_twin_declaration_through_registry_and_runner(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, omit_comparison: bool
) -> None:
    """A new registered script using the same comparison must declare its points and ports."""
    runner, original, staged = _stage_twin(tmp_path, "pd_target_candidate_twin")
    if omit_comparison:
        source = staged.read_text()
        before = source.index("[script]")
        after = source.index("[files]", before)
        staged.write_text(
            source[:before] + "[script]\n"
            "read -sv -D SYNTHESIS riscv_pkg.sv pd_target_candidate.sv\n"
            "prep -top pd_target_candidate\n\n" + source[after:]
        )
    target = replace(
        original,
        sby_file="additional_twin.sby"
        if omit_comparison
        else "additional_comparison.sby",
    )
    staged.rename(staged.with_name(target.sby_file))
    monkeypatch.setattr(sys.modules[__name__], "FORMAL_DIR", str(runner.formal_dir))
    monkeypatch.setattr(sys.modules[__name__], "FORMAL_TARGETS", [target])
    with pytest.raises(
        sby_config.ConfigError, match="missing twin comparison declaration"
    ):
        test_registered_formal_input_contracts()
    with pytest.raises(
        sby_config.ConfigError, match="missing twin comparison declaration"
    ):
        runner.run_formal(target, target.tasks[0])


@pytest.mark.parametrize("capture_output", (False, True))
@pytest.mark.parametrize(
    "task",
    ("bmc_amo_same_fatal", "bmc_amo_other_fatal", "bmc_intervening_fatal"),
)
@pytest.mark.parametrize(
    "case",
    (
        "complete",
        "empty_range",
        "short_bound",
        "wrong_start",
        "conflict_limit",
        "time_limit",
        "missing_completion",
        "missing_pass",
    ),
)
def test_fatal_frame_validation(
    monkeypatch: pytest.MonkeyPatch, capture_output: bool, case: str, task: str
) -> None:
    """Reject a success banner without the configured fatal-status evaluation."""
    output = "\n".join(
        (
            "engine_0: Params: FramesMax = 140. Start = 139. ConfLimit = 0. TimeOut = 0.",
            "engine_0: 139 + : Var = 100. UNSAT = 1.0 sec",
            "engine_0: No output asserted in 0 frames.",
            "engine_0: finished (returncode=0)",
            "engine_0: Status returned by engine: PASS",
            "DONE (PASS, rc=0)",
        )
    )
    changes = {
        "empty_range": ("engine_0: 139 + :", "engine_0: no evaluation:"),
        "short_bound": ("FramesMax = 140", "FramesMax = 139"),
        "wrong_start": ("Start = 139", "Start = 140"),
        "conflict_limit": ("ConfLimit = 0", "ConfLimit = 1"),
        "time_limit": ("TimeOut = 0", "TimeOut = 1"),
        "missing_completion": ("finished (returncode=0)", "interrupted"),
        "missing_pass": ("DONE (PASS, rc=0)", "summary pending"),
    }
    if case != "complete":
        output = output.replace(*changes[case])

    def run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        assert kwargs["capture_output"]
        return subprocess.CompletedProcess(command, 0, output, "")

    monkeypatch.setattr(subprocess, "run", run)
    monkeypatch.setattr(
        FormalRunner, "verify_model_artifacts", lambda *args, **kwargs: None
    )
    target = next(t for t in FORMAL_TARGETS if t.name == "coherence_store_boundary")
    if case == "complete":
        result = FormalRunner().run_formal(target, task, capture_output=capture_output)
        assert result.returncode == 0
    else:
        with pytest.raises(ValueError, match="did not complete its frame-139 check"):
            FormalRunner().run_formal(target, task, capture_output=capture_output)


@pytest.mark.parametrize("capture_output", (False, True))
@pytest.mark.parametrize(
    "target_name,task,expected_timeout",
    (
        ("csr_file", "bmc", 5400),
        ("csr_file", "bmc_perf_off", 5400),
        ("reorder_buffer", "bmc", 5400),
        ("coherent_hart_cache", "coh_hart_maint_prove", 7200),
        ("coherent_hart_cache", "coh_hart_maint_owned_prove", 1200),
        ("coherent_hart_cache", "coh_hart_maint_free_owned_prove", 7200),
        ("coherent_hart_cache", "coh_hart_maint_free_prove", 7200),
        ("coherent_hart_cache", "coh_hart_maint_four_bmc", 7200),
        ("coherence_l1d", "coh_l1d_stream_bmc", 5100),
        ("coherence_l1d", "coh_l1d_stream_free_nostore_bmc", 3600),
        ("coherence_l1d", "coh_l1d_stream_outlier_prove", 2400),
        ("coherence_l1d", "coh_l1d_stream_hold_bmc", 3600),
        ("coherence_l1d", "coh_l1d_stream_free_nostore_hold_bmc", 3600),
        ("coherence_l1d", "coh_l1d_bmc", 14400),
        ("coherence_store_boundary", "bmc_four_control", 3600),
        ("coherence_store_boundary", "bmc_four_value_0", 15840),
        ("coherence_store_boundary", "bmc_four_value_1", 10800),
        ("coherence_store_boundary", "bmc_four_value_2", 8400),
        ("coherence_store_boundary", "bmc_four_value_3", 3600),
        ("coherence_store_boundary", "bmc_intervening_same_flow", 8400),
        ("coherence_store_boundary", "bmc_intervening_other_flow", 13200),
        ("coherence_store_boundary", "bmc_intervening_same_value", 10800),
        ("coherence_store_boundary", "bmc_intervening_other_value", 15840),
        ("coherence_store_boundary", "bmc_intervening_fatal", 1200),
        ("coherence_store_boundary", "bmc_amo_same", 6600),
        ("coherence_store_boundary", "bmc_amo_other", 9600),
        ("coherence_store_boundary", "bmc_amo_same_owner", 3000),
        ("coherence_store_boundary", "bmc_amo_same_fatal", 3000),
        ("coherence_store_boundary", "bmc_amo_other_fatal", 4800),
        ("coherence_store_boundary", "bmc_load_same_probe_launch", 3600),
        ("coherence_store_boundary", "bmc_probe_kept_same", 5400),
        ("coherence_store_boundary", "bmc_probe_kept_other", 8400),
        ("coherence_store_boundary", "bmc_sc", 6000),
        ("coherence_store_home", "bmc_siblings", 900),
        ("coherence_store_home", "bmc_siblings_second", 900),
        ("coherence_store_home", "bmc_rows", 900),
        ("coherence_store_home", "bmc_rows_second", 900),
        ("coherence_store_home", "bmc_conflict", 900),
        ("coherence_store_home", "bmc_conflict_second", 900),
        ("coherence_store_home", "bmc_pressure", 900),
        ("coherence_store_home", "bmc_pressure_second", 900),
        ("coherence_store_home", "link_bmc_siblings", 900),
        ("coherence_store_home", "link_bmc_siblings_second", 900),
        ("coherence_store_home", "link_bmc_pressure", 900),
        ("coherence_store_home", "link_bmc_pressure_second", 900),
        ("coherence_store_home", "cover_siblings", 2400),
        ("coherence_store_home", "cover_conflict", 900),
        ("coherence_store_home", "cover_pressure", 900),
        ("coherence_store_home", "link_cover_pressure", 900),
        ("coherence_home_twin", "home_twin_small", 600),
        ("coherence_home_twin", "home_twin_four", 2400),
        ("coherence_home_twin", "home_twin_addr40", 600),
        ("coherence_l1d", "coh_l1d_stream_free_bmc", 10800),
        ("coherence_l1d", "coh_l1d_multi_bmc", 20400),
        ("coherence_l1d", "coh_l1d_local_control_bmc", 3600),
        ("coherence_l1d", "coh_l1d_data_bmc", 3900),
        ("coherence_l1d", "coh_l1d_data1_bmc", 3900),
        ("coherence_l1d", "coh_l1d_data2_bmc", 3900),
        ("coherence_l1d", "coh_l1d_data3_bmc", 3900),
        ("coherence_l1d", "coh_l1d_multi_data0_bmc", 4200),
        ("coherence_l1d", "coh_l1d_multi_data1_bmc", 4200),
        ("coherence_l1d", "coh_l1d_multi_data2_bmc", 4200),
        ("coherence_l1d", "coh_l1d_multi_data3_bmc", 4200),
        ("coherence_l1d", "coh_l1d_store_payload_bmc", 900),
        ("coherence_l1d", "coh_l1d_store_grant_bmc", 1200),
        ("coherence_l1d", "coh_l1d_store_multi_payload_bmc", 1800),
        ("coherence_l1d", "coh_l1d_store_multi_grant_bmc", 3600),
        ("coherence_l1d", "coh_l1d_ways_data_bmc", 5100),
        ("coherence_array", "coh_array_port_bmc", 2400),
        ("coherence_array", "coh_array4_port_bmc", 6000),
        ("coherence_store_boundary", "cover_four", 7200),
        ("csr_file", "cover", 2400),
        ("reorder_buffer", "cover", 2400),
        ("line_port_axi_bridge", "bmc_128g", 2400),
    ),
)
def test_formal_runner_task_timeout(
    monkeypatch: pytest.MonkeyPatch,
    target_name: str,
    task: str,
    expected_timeout: int,
    capture_output: bool,
) -> None:
    """CLI and captured runs apply each task's measured wall-clock allowance."""
    target = next(target for target in FORMAL_TARGETS if target.name == target_name)
    assert task in target.tasks
    calls: list[dict[str, Any]] = []

    def run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        calls.append(kwargs)
        assert command[-1] == task
        stdout = ""
        if (target_name, task) in FATAL_START_FRAME_TASKS:
            stdout = "\n".join(
                (
                    "engine_0: Params: FramesMax = 140. Start = 139. ConfLimit = 0. TimeOut = 0.",
                    "engine_0: 139 + : Var = 100. UNSAT = 1.0 sec",
                    "engine_0: No output asserted in 0 frames.",
                    "engine_0: finished (returncode=0)",
                    "engine_0: Status returned by engine: PASS",
                    "DONE (PASS, rc=0)",
                )
            )
        return subprocess.CompletedProcess(command, 0, stdout, "")

    monkeypatch.setattr(subprocess, "run", run)
    monkeypatch.setattr(
        FormalRunner, "verify_model_artifacts", lambda *args, **kwargs: None
    )
    FormalRunner().run_formal(target, task, capture_output=capture_output)
    assert calls[0]["timeout"] == expected_timeout


@pytest.mark.parametrize("as_bytes", (False, True))
def test_timeout_retains_solver_progress(as_bytes: bool) -> None:
    """Timed-out subprocesses may expose bytes even when text mode is enabled."""
    output = "".join(f"step {step}\n" for step in range(50))
    error = subprocess.TimeoutExpired(
        ["sby"],
        5400,
        output=output.encode() if as_bytes else output,
        stderr=b"solver pending\n" if as_bytes else "solver pending\n",
    )
    lines = timeout_log_tail(error).splitlines()
    assert len(lines) == 40
    assert lines[0] == "step 11"
    assert lines[-1] == "solver pending"


def test_yosys_log_crosscheck(tmp_path: Path) -> None:
    """Match Yosys pass logs in order and reject tampered or truncated logs."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    (tmp_path / UNDEFINED_OPENING_FILE).write_bytes(
        (formal / UNDEFINED_OPENING_FILE).read_bytes()
    )
    for name in ("pkg.sv", "top.sv"):
        (tmp_path / name).write_text("module top;\nendmodule\n")
    sby = tmp_path / "check.sby"
    sby.write_text(
        "[options]\nmode bmc\ndepth 1\n[engines]\nsmtbmc boolector\n[script]\n"
        "read -formal -D FLAG -sv pkg.sv top.sv\n"
        "chparam -set W 4 top\n"
        "hierarchy -top top\n"
        "script free_undefined.ys\n"
        "prep -top top\n"
        "select -assert-none t:$mem\n"
        "write_json dump.json\n"
        "[files]\npkg.sv\ntop.sv\nfree_undefined.ys\n"
    )
    (cfg,) = sby_config.resolved(sby).values()
    parsed = cfg.parsed(tmp_path, keep_script_entries=True)
    opening_passes = [
        "PROC_CLEAN pass (remove empty switches).",
        "PROC_RMDEAD pass (remove dead branches).",
        "PROC_PRUNE pass (remove redundant assignments).",
        "PROC_INIT pass (extract init attributes).",
        "PROC_ARST pass (detect async resets).",
        "PROC_MUX pass (convert decision trees).",
        "SETUNDEF pass (replace undef values).",
        "PROC_DLATCH pass (convert latches).",
        "OPT_EXPR pass (perform const folding).",
        "SETUNDEF pass (replace undef values).",
        "PROC_DFF pass (convert FFs).",
        "PROC_MEMWR pass (convert memory writes).",
        "PROC_CLEAN pass (remove empty switches).",
        "OPT_EXPR pass (perform const folding).",
    ]
    body_lines = [
        "-- Executing script file `../model/design.ys' --",
        "1. Executing Verilog-2005 frontend: pkg.sv",
        "2. Executing Verilog-2005 frontend: top.sv",
        "3. Executing AST frontend in derive mode using pre-parsed AST for module `\\top'.",
        "4. Executing HIERARCHY pass (managing design hierarchy).",
        "4.1. Analyzing design hierarchy..",
        "5. Executing AST frontend in derive mode using pre-parsed AST for module `\\sub'.",
        "-- Executing script file `free_undefined.ys' --",
        *[
            f"{idx}. Executing {header}"
            for idx, header in enumerate(opening_passes, start=6)
        ],
        "20. Executing PREP pass.",
        "20.1. Executing HIERARCHY pass (nested).",
        "21. Executing JSON backend.",
        "22. Executing HIERARCHY pass (managing design hierarchy).",
        "23. Executing jny backend.",
        "24. Executing RTLIL backend.",
        "End of script. Logfile hash: 0123456789",
    ]
    valid_log = "\n".join(body_lines) + "\n"
    check_yosys_log(valid_log, parsed)

    tampered_cases = [
        valid_log.replace("End of script.", "Terminated early."),
        valid_log.replace("pkg.sv", "other.sv", 1),
        valid_log.replace("-- Executing script file `free_undefined.ys' --\n", ""),
        valid_log.replace("20. Executing PREP pass.\n", ""),
        valid_log.replace(
            "20. Executing PREP pass.\n",
            "20. Executing PREP pass.\n20b.1. note\n99. Executing OPT pass.\n",
        ),
        valid_log.replace(
            "21. Executing JSON backend.\n"
            "22. Executing HIERARCHY pass (managing design hierarchy).\n"
            "23. Executing jny backend.\n"
            "24. Executing RTLIL backend.\n",
            "22. Executing JSON backend.\n"
            "23. Executing HIERARCHY pass (managing design hierarchy).\n"
            "24. Executing jny backend.\n"
            "25. Executing RTLIL backend.\n",
        ),
        valid_log.replace(
            "20. Executing PREP pass.\n20.1. Executing HIERARCHY pass (nested).\n"
            "21. Executing JSON backend.\n",
            "20. Executing JSON backend.\n21. Executing PREP pass.\n",
        ),
        valid_log.replace("23. Executing jny backend.\n", ""),
    ]
    for tampered in tampered_cases:
        with pytest.raises(ValueError):
            check_yosys_log(tampered, parsed)

    # Comment-only, repeated back-to-back, and nested script includes.
    nested_sby = tmp_path / "nested.sby"
    nested_sby.write_text(
        "[options]\nmode prove\ndepth 1\n[engines]\nsmtbmc boolector\n[script]\n"
        "read -formal -sv top.sv\n"
        "hierarchy -top top\n"
        "script free_undefined.ys\n"
        "prep -top top\n"
        "script empty_helper.ys\n"
        "script local_checks.ys\n"
        "script local_checks.ys\n"
        "script outer_helper.ys\n"
        "[files]\ntop.sv\nfree_undefined.ys\n"
        "[file empty_helper.ys]\n# comment-only helper\n\n"
        "[file local_checks.ys]\ncheck -assert\n\n"
        "[file inner_helper.ys]\nopt_clean\n\n"
        "[file outer_helper.ys]\nscript inner_helper.ys\nscript empty_helper.ys\nscript inner_helper.ys\n"
    )
    (nested_cfg,) = sby_config.resolved(nested_sby).values()
    nested_parsed = nested_cfg.parsed(tmp_path, keep_script_entries=True)
    nested_log = (
        "\n".join(
            [
                "-- Executing script file `../model/design.ys' --",
                "1. Executing Verilog-2005 frontend: top.sv",
                "2. Executing HIERARCHY pass (managing design hierarchy).",
                "-- Executing script file `free_undefined.ys' --",
                *[
                    f"{idx}. Executing {header}"
                    for idx, header in enumerate(opening_passes, start=3)
                ],
                "17. Executing PREP pass.",
                "-- Executing script file `empty_helper.ys' --",
                "-- Executing script file `local_checks.ys' --",
                "18. Executing CHECK pass (checking for obvious problems).",
                "-- Executing script file `local_checks.ys' --",
                "19. Executing CHECK pass (checking for obvious problems).",
                "-- Executing script file `outer_helper.ys' --",
                "-- Executing script file `inner_helper.ys' --",
                "20. Executing OPT_CLEAN pass (remove unused cells and wires).",
                "-- Executing script file `empty_helper.ys' --",
                "-- Executing script file `inner_helper.ys' --",
                "21. Executing OPT_CLEAN pass (remove unused cells and wires).",
                "22. Executing HIERARCHY pass (managing design hierarchy).",
                "23. Executing jny backend.",
                "24. Executing RTLIL backend.",
                "End of script. Logfile hash: abcdef0123",
            ]
        )
        + "\n"
    )
    check_yosys_log(nested_log, nested_parsed)
    for bad_nested in (
        nested_log.replace("-- Executing script file `empty_helper.ys' --\n", "", 1),
        nested_log.replace(
            "-- Executing script file `local_checks.ys' --\n"
            "18. Executing CHECK pass (checking for obvious problems).\n",
            "",
            1,
        ),
    ):
        with pytest.raises(ValueError):
            check_yosys_log(bad_nested, nested_parsed)


def _to_structured_headers(log_lines: list[str]) -> str:
    """Convert synthetic plain log lines into HeaderTraceSink format."""
    out: list[str] = []
    for line in log_lines:
        if line.startswith("-- Executing script file "):
            out.append(f"S\t{line}")
        elif line.startswith("End of script."):
            out.append(f"E\t{line}")
        else:
            out.append(f"H\t{line}")
    return "\n".join(out) + "\n"


@pytest.mark.parametrize(
    "case",
    (
        "empty_inline",
        "repeated_inline",
        "missing_log",
        "missing_headers",
        "missing_il",
        "missing_workdir",
        "missing_engine_pass",
    ),
)
def test_formal_runner_include_and_artifact_checks(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, case: str
) -> None:
    """Preserve solver verdicts and check includes, engine pass, and missing outputs."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    repo = tmp_path / "repo"
    (repo / "formal").mkdir(parents=True)
    (repo / "hw").symlink_to(formal.parent / "hw", target_is_directory=True)
    for name in (
        "coherence_prefetch_pause.sby",
        "coherence_prefetch_pause_formal.sv",
        "free_undefined.ys",
    ):
        (repo / "formal" / name).write_bytes((formal / name).read_bytes())

    sby_path = repo / "formal/coherence_prefetch_pause.sby"
    text = sby_config.read_checked_text(sby_path)
    if case == "empty_inline":
        sby_path.write_text(
            text.replace("\n[files]", "\nscript local_checks.ys\n\n[files]")
            + "\n[file local_checks.ys]\n# comment-only helper\n"
        )
    elif case == "repeated_inline":
        sby_path.write_text(
            text.replace(
                "\n[files]",
                "\nscript local_checks.ys\nscript local_checks.ys\n\n[files]",
            )
            + "\n[file local_checks.ys]\ncheck -assert\n"
        )

    opening_passes = [
        "PROC_CLEAN pass.",
        "PROC_RMDEAD pass.",
        "PROC_PRUNE pass.",
        "PROC_INIT pass.",
        "PROC_ARST pass.",
        "PROC_MUX pass.",
        "SETUNDEF pass.",
        "PROC_DLATCH pass.",
        "OPT_EXPR pass.",
        "SETUNDEF pass.",
        "PROC_DFF pass.",
        "PROC_MEMWR pass.",
        "PROC_CLEAN pass.",
        "OPT_EXPR pass.",
    ]
    extra_events: list[str] = []
    next_num = 19
    if case == "empty_inline":
        extra_events = ["-- Executing script file `local_checks.ys' --"]
    elif case == "repeated_inline":
        extra_events = [
            "-- Executing script file `local_checks.ys' --",
            "19. Executing CHECK pass.",
            "-- Executing script file `local_checks.ys' --",
            "20. Executing CHECK pass.",
        ]
        next_num = 21

    sby_stdout = (
        (
            "SBY 00:00:01 [t] summary: engine_0 (smtbmc boolector) did not return a status\n"
            "SBY 00:00:01 [t] DONE (PASS, rc=0)\n"
        )
        if case == "missing_engine_pass"
        else (
            "SBY 00:00:01 [t] engine_0.basecase: Status returned by engine for basecase: pass\n"
            "SBY 00:00:01 [t] engine_0.induction: Status returned by engine for induction: pass\n"
            "SBY 00:00:01 [t] summary: engine_0 (smtbmc boolector) returned pass for basecase\n"
            "SBY 00:00:01 [t] summary: engine_0 (smtbmc boolector) returned pass for induction\n"
            "SBY 00:00:01 [t] DONE (PASS, rc=0)\n"
        )
    )

    def fake_run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        workdir = Path(command[command.index("-d") + 1])
        if case == "missing_workdir":
            return subprocess.CompletedProcess(command, 0, sby_stdout, "")
        (workdir / "src").mkdir(parents=True)
        (workdir / "model").mkdir(parents=True)
        (workdir / "engine_0").mkdir(parents=True)
        src_cfg = sby_config.source(sby_path).task("pf_pause_prove")
        cfg_lines = (
            ["[options]"]
            + [f"{k} {v}" for k, v in src_cfg.options.items()]
            + ["", "[engines]"]
            + [" ".join(e) for e in src_cfg.engines]
            + ["", "[script]"]
            + list(src_cfg._script)
            + ["", "[files]"]
            + list(src_cfg.files.values())
        )
        for inline_name, inline_lines in src_cfg._inline.items():
            cfg_lines += ["", f"[file {inline_name}]", *inline_lines]
            (workdir / "src" / inline_name).write_text("\n".join(inline_lines) + "\n")
        (workdir / "config.sby").write_text("\n".join(cfg_lines) + "\n")
        for dest, rel in src_cfg.files.items():
            (workdir / "src" / dest).write_bytes((repo / "formal" / rel).read_bytes())
        (workdir / "status").write_text("PASS 0 1\n")
        (workdir / "logfile.txt").write_text(sby_stdout)
        if case == "missing_engine_pass":
            (workdir / "PASS").write_text(
                "engine_0 (smtbmc boolector) did not return a status\n"
            )
        else:
            (workdir / "PASS").write_text(
                "engine_0 (smtbmc boolector) returned pass for basecase\n"
                "engine_0 (smtbmc boolector) returned pass for induction\n"
            )
        if case != "missing_il":
            (workdir / "model/design.il").write_text("module \\top\nend\n")
        log_lines = [
            "-- Executing script file `../model/design.ys' --",
            "1. Executing Verilog-2005 frontend: coherence_prefetch_pause.sv",
            "2. Executing Verilog-2005 frontend: coherence_prefetch_pause_formal.sv",
            "3. Executing HIERARCHY pass.",
            "-- Executing script file `free_undefined.ys' --",
            *[
                f"{idx}. Executing {header}"
                for idx, header in enumerate(opening_passes, start=4)
            ],
            "18. Executing PREP pass.",
            *extra_events,
            f"{next_num}. Executing HIERARCHY pass.",
            f"{next_num + 1}. Executing jny backend.",
            f"{next_num + 2}. Executing RTLIL backend.",
            "End of script.",
        ]
        if case != "missing_log":
            (workdir / "model/design.log").write_text("\n".join(log_lines) + "\n")
        if case != "missing_headers":
            (workdir / "model/design.headers").write_text(
                _to_structured_headers(log_lines)
            )
        return subprocess.CompletedProcess(command, 0, sby_stdout, "")

    monkeypatch.setattr(subprocess, "run", fake_run)
    runner = FormalRunner()
    runner.root_dir = repo
    runner.formal_dir = repo / "formal"
    target = next(t for t in FORMAL_TARGETS if t.name == "coherence_prefetch_pause")
    if case in ("empty_inline", "repeated_inline"):
        result = runner.run_formal(target, "pf_pause_prove", capture_output=True)
        assert result.returncode == 0
    else:
        expected_reason = {
            "missing_log": "missing model/design.log",
            "missing_headers": "missing model/design.headers",
            "missing_il": "missing or empty model/design.il",
            "missing_workdir": "missing workdir",
            "missing_engine_pass": "solver output lacks an engine DONE (PASS, rc=0) verdict",
        }[case]
        with pytest.raises(FormalArtifactError) as exc_info:
            runner.run_formal(target, "pf_pause_prove", capture_output=True)
        assert exc_info.value.solver_verdict == "DONE (PASS, rc=0)"
        assert "DONE (PASS, rc=0)" in str(exc_info.value)
        assert expected_reason in str(exc_info.value)


def test_a5_f1_byte_rule_and_carriage_return_refused(tmp_path: Path) -> None:
    """Refuse CR, NUL, control, and non-ASCII bytes across .sby, .ys, and [files]."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    repo = tmp_path / "repo"
    (repo / "formal").mkdir(parents=True)
    (repo / "hw").symlink_to(formal.parent / "hw", target_is_directory=True)
    for name in ("rs_issue2_selector.sby", "free_undefined.ys"):
        (repo / "formal" / name).write_bytes((formal / name).read_bytes())

    # Exact F1 demonstration payload: backslash + CR inside a comment line in an
    # included .ys file, which Python text-mode splitlines read as a comment
    # continuation while Yosys's fgets executed `tee -q setundef -zero ...`.
    f1_helper = repo / "formal/rs_issue2_selector_extra.ys"
    f1_helper.write_bytes(
        b"# Hook for local experiments. \\\r"
        b"tee -q setundef -zero t:$mux t:$pmux t:$bwmux w:*\n"
    )
    sby_path = repo / "formal/rs_issue2_selector.sby"
    orig_sby = sby_path.read_bytes()
    sby_path.write_bytes(
        orig_sby.replace(
            b"hierarchy -top rs_issue2_selector\n",
            b"hierarchy -top rs_issue2_selector\nscript rs_issue2_selector_extra.ys\n",
        )
        + b"rs_issue2_selector_extra.ys\n"
    )

    gaps = sby_undefined_opening_gaps(sby_path)
    assert "bmc" in gaps and "0x0d" in gaps["bmc"][0], gaps
    added, _ = dont_care_changes(sby_path)
    assert added and "0x0d" in added[0], added
    cfg = sby_config.source(sby_path).task("bmc")
    reg_gaps = registered_task_config_gaps(
        "rs_issue2_selector", "bmc", cfg, repo / "formal"
    )
    assert reg_gaps and "0x0d" in reg_gaps[0], reg_gaps
    with pytest.raises(sby_config.ConfigError, match="0x0d"):
        sby_config.read_checked_text(f1_helper)

    # Even with pure LF, an unpinned .ys helper in a registered target is refused.
    f1_helper.write_bytes(b"# clean ASCII LF comment\n")
    cfg_clean = sby_config.source(sby_path).task("bmc")
    assert any(
        "unpinned .ys helper" in g
        for g in registered_task_config_gaps(
            "rs_issue2_selector", "bmc", cfg_clean, repo / "formal"
        )
    )

    # Disallowed bytes in .sby, .ys, and .sv [files] entries are all refused.
    for bad_byte in (b"\r", b"\r\n", b"\x00", b"\x0b", b"\x0c", b"\x7f", b"\x80"):
        bad_sby = tmp_path / "bad.sby"
        bad_sby.write_bytes(b"[options]\nmode bmc" + bad_byte + b"\n")
        with pytest.raises(sby_config.ConfigError):
            sby_config.source(bad_sby)

        bad_sv_dir = tmp_path / "sv_case"
        bad_sv_dir.mkdir(exist_ok=True)
        (bad_sv_dir / "free_undefined.ys").write_bytes(
            (formal / "free_undefined.ys").read_bytes()
        )
        (bad_sv_dir / "dut.sv").write_bytes(
            b"module dut;\n//" + bad_byte + b"\nendmodule\n"
        )
        sv_sby = bad_sv_dir / "dut.sby"
        sv_sby.write_bytes(
            b"[options]\nmode bmc\ndepth 1\n[engines]\nsmtbmc boolector\n"
            b"[script]\nread -formal -sv dut.sv\nhierarchy -top dut\n"
            b"script free_undefined.ys\nprep -top dut\n"
            b"[files]\ndut.sv\nfree_undefined.ys\n"
        )
        with pytest.raises(sby_config.ConfigError):
            sby_config.source(sv_sby).task("").parsed(bad_sv_dir)


@pytest.mark.parametrize(
    "case_name,mutator",
    [
        # F2: mode prep reports PASS without running a solver.
        ("f2_mode_prep", lambda s: s.replace("bmc: mode bmc", "bmc: mode prep")),
        # Cross-mode downgrade: registered bmc task switched to mode cover.
        (
            "mode_mismatch_cover",
            lambda s: s.replace("bmc: mode bmc", "bmc: mode cover"),
        ),
        # F3: smtc constraint file in [options] and [files].
        (
            "f3_smtc_option_and_file",
            lambda s: (
                s.replace(
                    "bmc: depth 1\n",
                    "bmc: depth 1\nbmc: smtc rs_issue2_selector.smtc\n",
                )
                + "rs_issue2_selector.smtc\n"
            ),
        ),
        (
            "f3_inline_smtc",
            lambda s: s + "\n[file hidden.smtc]\nalways\nassume (= [a] #b0)\n",
        ),
        (
            "f3_engine_extra_args",
            lambda s: s.replace(
                "smtbmc boolector", "smtbmc boolector -- --smtc hidden.smtc"
            ),
        ),
        (
            "f3_engine_basecase_only",
            lambda s: s.replace("smtbmc boolector", "smtbmc --basecase boolector"),
        ),
        (
            "f3_unpinned_skip_bmc",
            lambda s: s.replace("bmc: depth 1\n", "bmc: depth 2\nbmc: skip 1\n"),
        ),
        # N1: expect PASS,TIMEOUT with timeout 1.
        (
            "n1_expect_timeout",
            lambda s: s.replace(
                "bmc: depth 1\n",
                "bmc: depth 1\nbmc: expect PASS,TIMEOUT\nbmc: timeout 1\n",
            ),
        ),
        # N3: skip_prep on removes SymbiYosys's setundef -undriven -anyseq.
        (
            "n3_skip_prep_on",
            lambda s: s.replace("bmc: depth 1\n", "bmc: depth 1\nbmc: skip_prep on\n"),
        ),
        # Unpinned start-frame engine on another target.
        (
            "unpinned_abc_start_frame",
            lambda s: s.replace("smtbmc boolector", "abc bmc3 -c -S 139"),
        ),
        # Omitted [options] and [engines] sections altogether.
        (
            "missing_options_and_engines",
            lambda s: "[tasks]\nbmc\ncover\n" + s[s.index("[script]\n") :],
        ),
    ],
)
def test_a5_f2_f3_n1_n3_closed_options_engines_and_task_modes(
    tmp_path: Path, case_name: str, mutator: Any
) -> None:
    """Refuse unlisted options/engines, mode mismatches, smtc, expect, skip_prep, and unpinned skip."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    work = tmp_path / case_name
    work.mkdir()
    (work / "free_undefined.ys").write_bytes(
        (formal / "free_undefined.ys").read_bytes()
    )
    (work / "rs_issue2_selector.smtc").write_text("always\n")
    orig = sby_config.read_checked_text(formal / "rs_issue2_selector.sby")
    sby_path = work / "rs_issue2_selector.sby"
    sby_path.write_text(mutator(orig))

    refused = False
    try:
        src = sby_config.source(sby_path)
        cfg = src.task("bmc")
        gaps = registered_task_config_gaps("rs_issue2_selector", "bmc", cfg, formal)
        if gaps:
            refused = True
    except sby_config.ConfigError:
        refused = True
    assert refused, case_name
    if case_name == "missing_options_and_engines":
        with pytest.raises(sby_config.ConfigError, match="missing required 'mode'"):
            sby_config.resolved(sby_path)
        assert sby_undefined_opening_gaps(sby_path)
        assert dont_care_changes(sby_path)[0]

    # Also check the N3 u_on.sby toy directly.
    if case_name == "n3_skip_prep_on":
        u_on = work / "u_on.sby"
        u_on.write_text(
            "[options]\nmode bmc\ndepth 1\nskip_prep on\n[engines]\nsmtbmc boolector\n"
            "[script]\nread -formal -sv u.sv\nhierarchy -top u\ndelete u/b0\n"
            "script free_undefined.ys\nprep -top u -flatten\n[files]\nu.sv\nfree_undefined.ys\n"
        )
        with pytest.raises(sby_config.ConfigError, match="skip_prep"):
            sby_config.source(u_on)

    # Verify check_for_errors rejects engine-less or non-PASS solver outputs (F2, N1).
    runner = FormalRunner()
    for bad_out in (
        "SBY 00:00:01 [t] DONE (TIMEOUT, rc=0)\n",
        "SBY 00:00:01 [t] DONE (UNKNOWN, rc=0)\n",
        "SBY 00:00:01 [t] summary: engine_0 (smtbmc boolector) did not return a status\n"
        "SBY 00:00:01 [t] DONE (PASS, rc=0)\n",
        "",
    ):
        has_err, _ = runner.check_for_errors(
            subprocess.CompletedProcess(["sby"], 0, bad_out, "")
        )
        assert has_err, bad_out


def test_a5_n2_header_trace_neither_satisfiable_nor_breakable(tmp_path: Path) -> None:
    """Header-shaped log -stderr commands fail grammar, and RTL $display cannot spoof or break."""
    for spoofed_log in (
        "log -stderr 7. Executing SETUNDEF pass",
        "log -stderr -- Executing script file",
        "log -stderr End of script.",
    ):
        with pytest.raises(sby_config.ConfigError):
            sby_config.parse_script_lines([spoofed_log])

    # Run real Yosys through write_yosys_header_wrapper on an RTL module whose
    # initial blocks emit spoofed pass headers, script banners, and End of script.
    wrapper = write_yosys_header_wrapper(tmp_path / "yosys_wrapper.py")
    src_dir = tmp_path / "src"
    model_dir = tmp_path / "model"
    src_dir.mkdir()
    model_dir.mkdir()
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    (src_dir / "free_undefined.ys").write_bytes(
        (formal / "free_undefined.ys").read_bytes()
    )
    (src_dir / "d.sv").write_text(
        "module d(input logic c, output logic y);\n"
        '  initial $display("9. Executing SETUNDEF pass");\n'
        '  initial $display("\\n4. Executing PROC_CLEAN pass.");\n'
        '  initial $display("-- Executing script file `fake.ys\' --");\n'
        '  initial $display("End of script. Logfile hash: deadbeef");\n'
        "  assign y = c;\n"
        "  always_comb assert (y == c);\n"
        "endmodule\n"
    )
    sby_file = tmp_path / "d.sby"
    sby_file.write_text(
        "[options]\nmode bmc\ndepth 1\n[engines]\nsmtbmc boolector\n[script]\n"
        "read -formal -sv d.sv\n"
        "hierarchy -top d\n"
        "script free_undefined.ys\n"
        "prep -top d\n"
        "[files]\nd.sv\nfree_undefined.ys\n"
    )
    (model_dir / "design.ys").write_text(
        f"# running in {src_dir}/\n"
        "read -formal -sv d.sv\n"
        "hierarchy -top d\n"
        "script free_undefined.ys\n"
        "prep -top d\n"
        "hierarchy -smtcheck\n"
        "write_jny -no-connections ../model/design.json\n"
        "write_rtlil ../model/design.il\n"
    )
    subprocess.run(
        [str(wrapper), "-ql", "../model/design.log", "../model/design.ys"],
        cwd=src_dir,
        check=True,
        timeout=60,
    )
    headers_text = sby_config.read_checked_text(model_dir / "design.headers")
    parsed = (
        sby_config.source(sby_file).task("").parsed(src_dir, keep_script_entries=True)
    )

    # Not breakable: valid script with hostile $display lines passes structured check.
    check_yosys_log(headers_text, parsed, structured=True)

    # Not satisfiable: if a pass (prep) did not run while $display printed its
    # exact header text, the structured trace lacks the missing Header event and fails.
    (src_dir / "d.sv").write_text(
        "module d(input logic c, output logic y);\n"
        '  initial $display("18. Executing PREP pass.");\n'
        "  assign y = c;\n"
        "endmodule\n"
    )
    (model_dir / "design.ys").write_text(
        f"# running in {src_dir}/\n"
        "read -formal -sv d.sv\n"
        "hierarchy -top d\n"
        "script free_undefined.ys\n"
        "hierarchy -smtcheck\n"
        "write_jny -no-connections ../model/design.json\n"
        "write_rtlil ../model/design.il\n"
    )
    subprocess.run(
        [str(wrapper), "-ql", "../model/design.log", "../model/design.ys"],
        cwd=src_dir,
        check=True,
        timeout=60,
    )
    spoof_attempt_headers = sby_config.read_checked_text(model_dir / "design.headers")
    with pytest.raises(ValueError, match="PREP pass"):
        check_yosys_log(spoof_attempt_headers, parsed, structured=True)


# ===========================================================================
# Pytest integration
# ===========================================================================


@pytest.mark.formal
class TestFormalVerification:
    """Formal verification tests using SymbiYosys."""

    def test_sby_installed(self) -> None:
        """Test that SymbiYosys is installed and available."""
        try:
            result = subprocess.run(
                ["sby", "--version"], capture_output=True, text=True, timeout=10
            )
            if result.returncode != 0:
                pytest.fail(
                    "sby (SymbiYosys) not found - required for formal verification tests"
                )
        except FileNotFoundError:
            pytest.fail("sby (SymbiYosys) not installed - required for formal tests")
        except subprocess.TimeoutExpired:
            pytest.fail("sby version check timed out")

    @pytest.mark.parametrize(
        "target,task_name,task_description",
        [
            (target, task_name, task_desc)
            for target in FORMAL_TARGETS
            for task_name, task_desc in SBY_TASKS
            if task_name in target.tasks
        ],
        ids=[
            f"{target.name}_{task_name}"
            for target in FORMAL_TARGETS
            for task_name, _ in SBY_TASKS
            if task_name in target.tasks
        ],
    )
    def test_formal(
        self,
        target: FormalTarget,
        task_name: str,
        task_description: str,
        capsys: Any,
    ) -> None:
        """Run formal verification for a specific target and task."""
        try:
            subprocess.run(["sby", "--version"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            pytest.fail("sby (SymbiYosys) not installed - required for formal tests")

        runner = FormalRunner()
        test_id = f"{target.name}_{task_name}"
        # In CI, skip a task that passed before with the same key
        # (tests/README.md, "Reusing formal and synthesis results").
        reuse = ci_reuse.Reuse.from_env(runner.root_dir, "formal")
        decision = None
        key = ""
        if reuse is not None:
            key = formal_reuse_key(runner.root_dir, target, task_name, reuse.tools_id)
            decision = reuse.decide(test_id, key)
            if decision.action == "reuse":
                assert decision.marker is not None
                reuse.report(test_id, "reused", key, decision.marker)
                origin = ci_reuse.describe_origin(decision.marker["origin"])
                pytest.skip(f"Passed with the same key in {origin}")

        with capsys.disabled():
            print(f"\nRunning formal {task_name}: {target.description}...")

        try:
            summary = self.prove(runner, target, task_name, capsys)
        except BaseException as error:
            if reuse is not None and decision is not None:
                if decision.marker is not None:
                    # A canary, or a forced run, of a task with a marker.
                    reuse.store.drop(test_id)
                    reuse.report(test_id, "canary-failed", key)
                    origin = ci_reuse.describe_origin(decision.marker["origin"])
                    pytest.fail(
                        f"CANARY: {test_id} had a pass marker for this exact key "
                        f"from {origin} but did not pass now. The key misses an "
                        "input of the task, or the tools are not what the key "
                        f"says.\n{error}"
                    )
                reuse.report(test_id, "failed", key)
            raise
        if reuse is not None and decision is not None:
            if (
                formal_reuse_key(runner.root_dir, target, task_name, reuse.tools_id)
                != key
            ):
                reuse.report(test_id, "failed", key)
                pytest.fail(f"The inputs of {test_id} changed while it ran")
            if summary != "PASS":
                # The test passes as before, but only a PASS summary earns a
                # marker, and an earlier marker for this key no longer stands.
                reuse.store.drop(test_id)
                reuse.report(test_id, "proved-without-marker", key)
                return
            reuse.store.record_pass(test_id, key, ci_reuse.environment_origin())
            status = "canary" if decision.action == "canary" else "proved"
            reuse.report(test_id, status, key)

    @staticmethod
    def prove(
        runner: FormalRunner, target: FormalTarget, task_name: str, capsys: Any
    ) -> str:
        """Run one task, fail the test unless it passes, and return its status.

        The status is PASS when SymbiYosys's last summary line is
        "DONE (PASS, rc=0)" and it exits with 0, and UNKNOWN otherwise.
        """
        try:
            result = runner.run_formal(target, task_name, capture_output=True)
            has_error, error_lines = runner.check_for_errors(result)
            info = runner.parse_results(result)

            with capsys.disabled():
                if has_error:
                    print(f"\nFormal {task_name} for {target.name} FAILED:")
                    for line in error_lines:
                        print(f"  {line}")
                else:
                    elapsed = info.get("elapsed", "")
                    print(
                        f"\nFormal {task_name} for {target.name} PASSED"
                        f"{' (' + elapsed + ')' if elapsed else ''}"
                    )

            if has_error:
                error_msg = (
                    f"Formal {task_name} for {target.name} failed:\n"
                    + "\n".join(error_lines)
                )
                pytest.fail(error_msg)
            output = (result.stdout or "") + (result.stderr or "")
            done = [line for line in output.splitlines() if "DONE (" in line]
            if result.returncode == 0 and done and "DONE (PASS, rc=0)" in done[-1]:
                return "PASS"
            return "UNKNOWN"

        except subprocess.TimeoutExpired as error:
            pytest.fail(
                f"Formal {task_name} for {target.name} timed out after "
                f"{error.timeout // 60} minutes\n{timeout_log_tail(error)}"
            )
        except FormalArtifactError as error:
            with capsys.disabled():
                print(f"\nFormal {task_name} for {target.name} ERROR: {error}")
            pytest.fail(str(error))
        except Exception as e:
            pytest.fail(
                f"Unexpected error during formal {task_name} for {target.name}: {e}"
            )


# ===========================================================================
# Command-line interface for standalone execution
# ===========================================================================


def update_define_inputs(root: Path, case: str | None) -> None:
    """Initialize the declaration file or update a single registered task."""
    import fcntl
    import os

    path = root / sby_config.DEFINE_INPUTS_PATH
    directory_fd = os.open(path.parent, os.O_RDONLY)
    try:
        fcntl.flock(directory_fd, fcntl.LOCK_EX)
        registered = {
            f"{target.name}:{task}": (target.sby_file, task)
            for target in FORMAL_TARGETS
            for task in target.tasks
        }
        if case is None:
            if path.exists():
                raise sby_config.ConfigError(
                    f"{sby_config.DEFINE_INPUTS_PATH} already exists. "
                    "Use --update-define-inputs TARGET:TASK."
                )
            declarations = {}
            updates = registered
        else:
            declarations = sby_config.read_define_inputs(root)
            updates = {}
            if case in registered:
                updates[case] = registered[case]
            elif case in declarations:
                del declarations[case]
            else:
                raise sby_config.ConfigError(f"{case}: unknown formal task")

        sources: dict[str, sby_config.Source] = {}
        for key, (sby_file, task) in updates.items():
            if sby_file not in sources:
                sources[sby_file] = sby_config.source(root / FORMAL_DIR / sby_file)
            source = sources[sby_file]
            if task not in source.tasks:
                raise sby_config.ConfigError(f"{key}: task absent from {sby_file}")
            parsed = source.task(task).parsed(root / FORMAL_DIR)
            declarations[key] = sby_config.define_inputs(parsed)

        rows = [
            f"  {json.dumps(key)}: {json.dumps(inputs)}"
            for key, inputs in sorted(declarations.items())
        ]
        text = "{\n" + ",\n".join(rows) + "\n}\n"
        with tempfile.TemporaryDirectory(dir=path.parent) as temporary:
            updated = Path(temporary) / path.name
            updated.write_text(text)
            updated.replace(path)
    finally:
        os.close(directory_fd)


def main() -> int:
    """Run formal verification from command line."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Run SymbiYosys formal verification for FROST",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                           # Run every target's declared tasks
  %(prog)s --target trap_unit        # Run one target
  %(prog)s --task bmc                # Run only the bmc task
  %(prog)s --verbose                 # Show full sby output
  %(prog)s --list-targets            # List targets and tasks

With pytest:
  pytest test_run_formal.py                              # Run all formal tests
  pytest test_run_formal.py -k bmc                       # Run only BMC tests
  pytest test_run_formal.py -k cover                     # Run only cover tests
""",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Show full sby output (default: summaries and failure details)",
    )
    parser.add_argument(
        "--list-targets",
        action="store_true",
        help="List targets and task descriptions, then exit",
    )
    parser.add_argument(
        "--target",
        "-t",
        default=None,
        choices=[t.name for t in FORMAL_TARGETS],
        help="Target to run (default: all targets)",
    )
    parser.add_argument(
        "--task",
        default=None,
        choices=[t[0] for t in SBY_TASKS],
        help="Task name to run on targets that declare it (default: all declared "
        "tasks)",
    )
    declarations = parser.add_mutually_exclusive_group()
    declarations.add_argument(
        "--initialize-define-inputs",
        action="store_true",
        help="Generate the define declarations when the file is first introduced",
    )
    declarations.add_argument(
        "--update-define-inputs",
        metavar="TARGET:TASK",
        help="Refresh one task's define declaration after an intentional change",
    )

    args = parser.parse_args()

    if args.initialize_define_inputs or args.update_define_inputs is not None:
        try:
            update_define_inputs(
                Path(__file__).resolve().parents[1], args.update_define_inputs
            )
        except sby_config.ConfigError as error:
            parser.error(str(error))
        return 0

    if args.list_targets:
        print("Available formal targets (from FORMAL_TARGETS):")
        for target in FORMAL_TARGETS:
            print(
                f"  {target.name:20} tasks={','.join(target.tasks):15} - {target.description}"
            )
        print("\nSupported tasks:")
        for task_name, task_desc in SBY_TASKS:
            print(f"  {task_name:8} - {task_desc}")
        return 0

    targets = FORMAL_TARGETS
    if args.target:
        targets = [t for t in FORMAL_TARGETS if t.name == args.target]

    tasks = SBY_TASKS
    if args.task:
        tasks = [(n, d) for n, d in SBY_TASKS if n == args.task]
    if not any(name in target.tasks for target in targets for name, _ in tasks):
        parser.error("the selected targets declare none of the requested tasks")

    try:
        result = subprocess.run(
            ["sby", "--version"], capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            print("Error: sby (SymbiYosys) not found or failed to run")
            return 1
        print(f"Found: {result.stdout.strip()}")
    except FileNotFoundError:
        print("Error: sby (SymbiYosys) is not installed or not in PATH")
        return 1

    runner = FormalRunner()

    failed = []
    passed = 0
    for target in targets:
        for task_name, task_desc in tasks:
            if task_name not in target.tasks:
                continue
            test_id = f"{target.name}:{task_name}"
            try:
                print(f"\n{'=' * 60}")
                print(f"Formal {task_name}: {target.description}")
                print(f"{'=' * 60}")

                result = runner.run_formal(
                    target, task_name, capture_output=not args.verbose
                )
                has_error, error_lines = runner.check_for_errors(result)

                if not args.verbose:
                    output = (result.stdout or "") + (result.stderr or "")
                    for line in output.splitlines():
                        if any(
                            kw in line
                            for kw in [
                                "DONE",
                                "Assert failed",
                                "reached cover",
                                "Status:",
                                "Elapsed",
                            ]
                        ):
                            print(f"  {line.strip()}")

                if has_error:
                    print(f"\n{test_id} FAILED")
                    for line in error_lines:
                        print(f"  {line}")
                    # Show full output on failure for debugging
                    if not args.verbose:
                        full_output = (result.stdout or "") + (result.stderr or "")
                        if full_output.strip():
                            print("\n  Full output:")
                            for line in full_output.strip().splitlines()[-20:]:
                                print(f"    {line}")
                    failed.append(test_id)
                else:
                    print(f"\n{test_id} PASSED")
                    passed += 1

            except subprocess.TimeoutExpired as error:
                print(f"\n{test_id} TIMEOUT ({error.timeout // 60} minutes)")
                if output := timeout_log_tail(error):
                    print(output)
                failed.append(test_id)
            except FormalArtifactError as error:
                if not args.verbose:
                    output = (error.result.stdout or "") + (error.result.stderr or "")
                    for line in output.splitlines():
                        if any(kw in line for kw in ("DONE", "Status:", "Elapsed")):
                            print(f"  {line.strip()}")
                print(f"\n{test_id} ERROR: {error}")
                failed.append(test_id)
            except Exception as e:
                print(f"\n{test_id} ERROR: {e}")
                failed.append(test_id)

    # Summary
    total = passed + len(failed)
    print(f"\n{'=' * 60}")
    print("FORMAL VERIFICATION SUMMARY")
    print(f"{'=' * 60}")
    print(f"Passed: {passed}/{total}")
    if failed:
        print(f"Failed: {', '.join(failed)}")
        return 1
    else:
        print("All formal verification targets passed!")
        return 0


if __name__ == "__main__":
    sys.exit(main())
