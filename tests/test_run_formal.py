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
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

import ci_reuse
import sby_config
from sby_config import commands as yosys_commands
from sby_config import script_block

# Path to the formal/ directory relative to the repository root
FORMAL_DIR = "formal"

# Per-task hang backstop in seconds; proof depth is set by each .sby file.
SBY_TASK_TIMEOUT_S = 2400
# Slow control, data and composed tasks have measured allowances in their
# SBY files and separate CI jobs. Keep the runner's backstops in sync with
# those files and document the budgets and depths in formal/README.md.
SBY_TASK_TIMEOUT_OVERRIDES_S = {
    ("coherence_dma_ingress", "coh_dma_ingress_soc_prove"): 3120,
    ("coherence_home_twin", "home_twin_small"): 600,
    ("coherence_home_twin", "home_twin_four"): 600,
    ("coherence_home_twin", "home_twin_addr40"): 600,
    ("coherence_home", "coh_home_control_prove"): 1800,
    ("coherence_home", "coh_home_control64_prove"): 1800,
    ("coherence_home", "coh_home_control_partition_prove"): 1800,
    ("coherence_home", "coh_home_fill_cover"): 1800,
    ("coherence_home", "coh_home_control4_bmc"): 1200,
    ("coherence_home", "coh_home_control4_ultra_bmc"): 1200,
    ("coherence_home", "coh_home_prefetch_cover"): 1200,
    ("coherence_home", "coh_home_wb_prove"): 180,
    ("coherence_home", "coh_home_victim_cover"): 180,
    ("coherence_home", "coh_home_error_cover"): 180,
    ("coherence_l1d", "coh_l1d_perf_prove"): 120,
    ("csr_file", "bmc"): 5400,
    ("csr_file", "bmc_perf_off"): 5400,
    ("csr_file", "vector_bmc"): 5400,
    ("reorder_buffer", "bmc"): 5400,
    ("coherence_home", "coh_home_cmo_cover"): 6000,
    ("coherent_hart_cache", "coh_hart_maint_prove"): 7200,
    ("coherent_hart_cache", "coh_hart_maint_owned_prove"): 1200,
    ("coherent_hart_cache", "coh_hart_maint_four_bmc"): 7200,
    ("coherence_l1d", "coh_l1d_stream_bmc"): 5100,
    ("coherence_l1d", "coh_l1d_stream_hold_bmc"): 3600,
    ("coherence_l1d", "coh_l1d_stream_cover"): 1200,
    ("coherence_l1d", "coh_l1d_stream_free_nostore_bmc"): 3600,
    ("coherence_l1d", "coh_l1d_stream_free_nostore_hold_bmc"): 3600,
    ("coherence_l1d", "coh_l1d_stream_free_bmc"): 10800,
    ("coherence_array", "coh_array4_port_bmc"): 6000,
    ("coherence_l1d", "coh_l1d_bmc"): 10800,
    ("coherence_l1d", "coh_l1d_multi_bmc"): 18000,
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
    ("coherence_store_boundary", "bmc_four"): 18000,
    ("coherence_store_boundary", "cover_four"): 7200,
    ("coherence_store_boundary", "bmc_intervening"): 14400,
    ("coherence_store_boundary", "bmc_amo_same"): 3300,
    ("coherence_store_boundary", "bmc_amo_other"): 4800,
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
    ("line_client_link", "line_link0_bmc"): 4200,
    ("line_client_link", "line_link1_bmc"): 4200,
    ("line_client_link", "line_link1_four_bmc"): 4200,
    ("line_client_link", "line_link1_eight_bmc"): 4200,
    ("rs_issue_tag_banks", "int_equiv"): 600,
    ("rs_issue_tag_banks", "int_equiv_prims"): 600,
    ("rs_issue_tag_copies", "prove"): 600,
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
            "bmc_four",
            "cover_four",
            "bmc_intervening",
            "bmc_load_same",
            "bmc_load_other",
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
            "coh_hart_maint_cover",
            "coh_hart_maint_four_bmc",
            "coh_hart_maint_four_cover",
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
        "stop through reset and flush",
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
            "coh_l1d_stream_prove",
            "coh_l1d_stream_outlier_prove",
            "coh_l1d_stream_cover",
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
            "coh_completions_cover",
            "coh_completions_partition_cover",
            "coh_completions_partition2_cover",
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
            "coh_home_control4_bmc",
            "coh_home_control4_ultra_bmc",
            "coh_home_fill_cover",
            "coh_home_cmo_cover",
            "coh_home_wb_prove",
            "coh_home_victim_cover",
            "coh_home_error_cover",
            "coh_home_prefetch_cover",
            "coh_home_dispatch_cover",
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
        "Independent L2 ports and one-way parallel reads preserve byte values, tokens "
        "and physical-row exclusions.",
        tasks=(
            "coh_home_array_prove",
            *(f"coh_home_array_uram_byte{lane}_prove" for lane in range(64)),
            "coh_home_array_cover",
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
        "Store-queue same-sector claim matches the reference after launch and allocation",
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
        "mispredict_capture.sby",
        "Recovery payload, pulse copies and frontend flush match their references",
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
        "low_bram_presenter_tier.sby",
        "Low-BRAM fetch responses match with separate address retargeting on or off",
        tasks=("bmc", "prove"),
    ),
    FormalTarget(
        "rvc_predecode.sby",
        "RV64C/Zcb/Zcmop expansion and source metadata match every parcel; MOPs permit pairing",
        tasks=("bmc",),
    ),
    FormalTarget(
        "dispatch_admission.sby",
        "Dispatch admission matches the reference; slot-2 instructions use no FP "
        "source 3",
        tasks=("bmc", "bmc_queued"),
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
        "A surviving vector allocation (arithmetic, FP, vector-to-scalar, load or "
        "store) clears restart state across delayed architectural reload and "
        "checkpoint recovery; the tracked vtype follows "
        "configuration allocation, flush, reload and restore",
        tasks=("bmc", "prove", "cover"),
    ),
    FormalTarget(
        "vec_lmul_legality_equiv.sby",
        "Vector arithmetic legality, floating point included, equals the reference "
        "for every vtype and instruction; dispatch applies it with the VTOX and "
        "nonzero-vstart rules; the registered queue-head result is current whenever "
        "it is ready",
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
        "each element translated first, precise mid-run faults and pointer masking",
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
        "Vector range holds: a scalar entry is held exactly while an older live "
        "vector memory table entry overlaps it or has an unknown range",
        tasks=("vhold_lq_bmc", "vhold_sq_bmc", "cover"),
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
        "l2tlb.sby",
        "Second-level TLB hits are backed by a fill no flush has removed, return the "
        "filled data, and never run during a flush; the shared walk port selects "
        "its VPN from registered state and delays an instruction walk one cycle "
        "at most",
        tasks=("bmc", "cover", "walk_select_prove", "walk_select_cover"),
    ),
    FormalTarget(
        "ptw_pbmt_alias.sby",
        "Svpbmt alias bit predicates equal the full-address range check for every address",
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
        "Svnapot PPN substitution, Svpbmt reserved encodings, PBMTE and the uncached "
        "alias, and the walk "
        "cache holds only valid pointers that memory holds, cleared by every discard",
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
        "Misaligned-access engine: request controls match the issue states, no memory request before both parts pass their "
        "checks, lower sector first, one request and response per identity, one "
        "completion, fault or write-back per access, and terminal fatal stops",
        tasks=("bmc", "cover"),
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
        ),
    ),
    FormalTarget(
        "rs_stage2_payload_equiv.sby",
        "Occupied reservation-station stage2 and stage2b payloads loaded on FU readiness equal "
        "issue-fire capture across all four station configurations",
        tasks=("int_prove", "mul_prove", "mem_prove", "fp_prove", "int_cover"),
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
        "Fetch-window coverage matches full-address comparisons for 32/64-bit "
        "addresses and portable/Xilinx implementations",
        tasks=("bmc", "bmc_xilinx", "bmc_32", "bmc_32_xilinx"),
    ),
    FormalTarget(
        "rs_primary_payload.sby",
        "Primary RS payload storage and selection match the reference",
        tasks=("bmc16", "bmc8", "bmc4", "prove"),
    ),
    FormalTarget(
        "rs_divide_gate.sby",
        "The MUL station issues a divide only while the divider is idle",
        tasks=("prove", "cover"),
    ),
    FormalTarget(
        "cdb_arbiter.sby",
        "CDB arbitration priority, exclusive grants, and result delivery",
    ),
    FormalTarget(
        "fu_cdb_adapter.sby",
        "FU completion buffering, backpressure, and flush handling",
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
            "prove_pre_match",
            "bmc_no_prepare_busy",
            "cover_no_prepare_busy",
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
        "AXI4 safety: response ordering and conservation, burst bytes to line "
        "requests and back, error bursts, and "
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
        "AXI4 rules on every port, W in AW-grant order, and B and R steered by port, "
        "unbounded",
        tasks=("prove", "prove_soc", "prove_soc4", "cover"),
    ),
    FormalTarget(
        "line_size_adapter.sby",
        "L1-line requests map onto their sector of a wider L2 line and back",
    ),
    FormalTarget(
        "store_queue.sby",
        "Store-queue capacity, forwarding, and committed-write preservation",
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
        "valid tag once, and requests in training hold their set's current "
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
        "tage_copy_convergence.sby",
        "Tagged predictor training: with a table entry's two copies equal, "
        "each copy's next value matches the write without the provider "
        "write-back; with them unequal, a write makes them equal",
        tasks=("prove", "cover", "bmc_unequal", "cover_unequal"),
    ),
    FormalTarget(
        "pd_backing_redirect.sby",
        "PD backing-BTB jump redirects and slot-1/slot-2 TAGE conditional-branch "
        "overrides fire only with their vetoes clear, stack operations and "
        "refreshes follow them, and redirect directions and targets match PD's "
        "reference models",
        tasks=("bmc", "cover"),
    ),
    FormalTarget(
        "pd_redirect_next_equiv.sby",
        "PD's redirect target registers' next values, with every candidate formed "
        "before the slot selects and slot 1's size picked last, equal the form "
        "they replace for any decode, packet, candidates, backing BTB result and "
        "stack state",
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
        "post-prediction holdoff holds pc_reg, including walked-past pending predictions",
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
        tasks=("bmc", "cover", "fp_repair_bmc"),
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
        "rat_checkpoint_restore.sby",
        "Register alias table: unbounded circular ROB and sequence oracle across save, restore and commit.",
        tasks=(
            "prove_int_active",
            "prove_int_ckpt_lo",
            "prove_int_ckpt_hi",
            "prove_fp_active",
            "prove_fp_ckpt_lo",
            "prove_fp_ckpt_hi",
            "cover",
        ),
    ),
]

# SymbiYosys task types (for CLI --task filter and pytest parametrize)
SBY_TASKS = [
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
        "coh_l1d_stream_prove",
        "Unbounded: most control assertions with eight endpoints, arbitrary inputs and stores.",
    ),
    (
        "coh_l1d_stream_outlier_prove",
        "Independent unbounded grant multiplexer, image, load payload and reply hold checks for the stream BMCs.",
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
        "bmc_four",
        "Four sector records preserve the production SQ and LQ handoff through 114 cycles.",
    ),
    (
        "cover_four",
        "Four acknowledged holders drain with concurrent store acquisitions.",
    ),
    ("bmc_intervening", "A younger store cannot change an intervening load result."),
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
    ("coh_read_capture_prove", "Read data capture with arbitrary controller state."),
    ("coh_read_capture_stream_prove", "Read data capture with stream endpoints."),
    ("coh_idle_select_prove", "Idle phase and operation selection with one endpoint."),
    (
        "coh_idle_select_stream_prove",
        "Idle phase and operation selection with stream endpoints.",
    ),
    ("coh_idle_phase_prove", "Phase register after Idle cycles with one endpoint."),
    (
        "coh_idle_phase_stream_prove",
        "Phase register after Idle cycles with stream endpoints.",
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
    ("coh_completions_cover", "Concurrent results and independent release."),
    (
        "coh_completions_partition_cover",
        "A full prefetch partition and a prefetch slot's G taken.",
    ),
    (
        "coh_completions_partition2_cover",
        "The prefetch rotation passing over an offered prefetch slot.",
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
        "coh_home_control4_bmc",
        "Bounded home checks with four ways, three fills and a fill reserve.",
    ),
    (
        "coh_home_control4_ultra_bmc",
        "Bounded four-way home checks with the registered tag array.",
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
        "coh_home_dispatch_cover",
        "A dispatch-cycle lookup offer that loses the tag arbiter and wins from Lookup.",
    ),
    ("coh_home_array_prove", "Independent L2 ports preserve watched bytes."),
    *[
        (
            f"coh_home_array_uram_byte{lane}_prove",
            f"Registered L2 ports preserve byte {lane} and exclude row collisions.",
        )
        for lane in range(64)
    ],
    ("coh_home_array_cover", "Tag, read and update ports operate concurrently."),
    ("coh_array_bmc", "Coherent array byte values and held responses."),
    ("coh_array_uram_bmc", "Coherent array byte values through registered RAM ports."),
    ("coh_array4_bmc", "Coherent array byte values and held responses with four ways."),
    ("coh_array4_uram_bmc", "Four-way coherent array byte values in UltraRAM."),
    ("coh_array_port_bmc", "Hit-port tags and byte values beside lookups, one way."),
    ("coh_array4_port_bmc", "Hit-port tags and byte values beside lookups, four ways."),
    ("coh_array4_port_cover", "Hit-port hits beside lookups and after writes."),
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
    ("coh_array_equiv_cover", "Compared data responses and insertions are reachable."),
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
    ("prove_predecoded", "Unbounded IMSIC equivalence with registered input decodes"),
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
    ("bmc_small", "Svpbmt alias range equivalence at a 256 MiB DDR capacity"),
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
        "vhold_lq_bmc",
        "Vector range holds with the load queue's address-update port, 8 frames.",
    ),
    (
        "vhold_sq_bmc",
        "Vector range holds with the store queue's per-entry addresses, 8 frames.",
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
        "dbq_twin",
        "Decoded bundle queue primitive form equals its portable form with the split shadow stall.",
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
        "prove_int_ckpt_hi",
        "Unbounded RAT proof for integer snapshot invariants in checkpoints 4 through 7.",
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
        "prove_fp_ckpt_hi",
        "Unbounded RAT proof for floating-point snapshot invariants in checkpoints 4 through 7.",
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
        "axi_coherent_bridge": [
            "prove_soc",
            "prove_soc_held",
            *(f"prove_soc8_{index}" for index in range(9)),
        ],
        "rat_checkpoint_restore": [
            "prove_int_active",
            "prove_int_ckpt_lo",
            "prove_int_ckpt_hi",
            "prove_fp_active",
            "prove_fp_ckpt_lo",
            "prove_fp_ckpt_hi",
        ],
        "coherent_hart_cache": [
            "coh_hart_maint_owned_prove",
            "coh_hart_maint_prove",
        ],
        "coherence_store_boundary": [
            f"{prefix}_amo_{sector}_{suffix}"
            for sector in ("same", "other")
            for prefix, suffix in (("bmc", "fatal"), ("prove", "fatal_sticky"))
        ],
        "coherence_l1d": [
            f"coh_l1d_local{geometry}{part}_prove"
            for geometry in ("", "_multi", "_ways")
            for part in ("", "_sector", "_owned")
        ]
        + [
            "coh_l1d_stream_owned_prove",
            "coh_l1d_stream_prove",
            "coh_l1d_stream_outlier_prove",
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
        "coherent_hart_cache_coh_hart_maint_prove": "Hart maintenance",
        "coherent_hart_cache_coh_hart_maint_owned_prove": "Hart maintenance",
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
        "coherence_store_boundary_bmc_four": "Store boundary four records",
        "coherence_store_boundary_bmc_intervening": "Store boundary intervening load",
        "coherence_store_boundary_bmc_amo_same": "Store boundary AMO flow",
        "coherence_store_boundary_bmc_amo_other": "Store boundary AMO flow",
        "coherence_store_boundary_bmc_sc": "Store boundary",
    }
    # Shards sized directly from their tasks' allowances plus CI setup; the
    # remaining catch-all shards group short partitions under hang backstops
    # and may not hold any multi-hour (> 120 minute) task.
    allowance_shards = (set(dedicated_shards.values()) - {"Store boundary"}) | {
        "Coherence links pressure",
        "Coherence L1D data single-endpoint",
        "Coherence L1D data multi-endpoint",
        "Coherence L1D data stores and ways",
        "Coherence L1D zero payload and stream",
        "Coherence L1D zero schedules",
        "Coherence L1D full-line covers",
        "Coherence L1D full-line holds",
        "Coherence L1D withdrawn puts, payloads",
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
    """Return an SBY task's resolved sections, without comments."""
    path = Path(__file__).resolve().parents[1] / FORMAL_DIR / f"{target}.sby"
    return sby_config.resolved(path)[task].sections()


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
# So every command of every task's script must match a form in DONT_CARE_SAFE,
# each with the reason this Yosys's source gives. Apart from the edits a script
# names itself (connect, delete, chformal and the like), the listed forms keep
# the unknown starting value of registers and memories and never merge two
# free inputs. Every other form fails, among them every form known to fix such
# a value or to merge free inputs; DONT_CARE_REJECTED gives the reason for the
# forms that registered scripts run, and -share_all fails in any command.
#
# No list of forms keeps undefined constants: these passes, which listed forms
# run, fuse or fix them before SymbiYosys frees them.
#   opt_muxtree (opt without -fast, prep): a constant-x select reads as 0.
#   opt_expr (proc, prep, every opt): constant-x bits at the same position of
#     an $eq or $ne compare equal ($eqx and $nex compare them exactly).
#   opt_merge (prep, every opt): identical cells whose inputs hold a constant x
#     become one.
#   opt_reduce (opt without -fast, prep): equal output bits of a multiplexer
#     that drives a memory write enable, constant x included, become one bit,
#     as do repeated constant-x select bits of a $bmux or $demux.
#   proc_rom (proc unless -norom, prep): a case of constants becomes a ROM;
#     after memory_collect (in prep), memory_map -keepdc or memory_map -formal
#     its x words, such as an x default, hold one value for the whole trace,
#     not a free value in every cycle.
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
#
# The checks read each task's script as SymbiYosys selects it and as Yosys runs
# it: a command after ';', behind a label or inside tee, debug, trace or an
# included script counts, and an option after '#' does not. In a form, "*"
# accepts any arguments, "-x" must be given and "[-x]" may be, ":N" is the
# number of arguments an option takes, "=a|b" lists the values its first
# argument may take, and "-x*" accepts any option that begins with -x. Other
# words are selections or names, which every form accepts. No form accepts
# any option at all: an option that a form does not list, a file it would
# write among them, fails the form.
DONT_CARE_FRONT_END = (
    "reads sources; the design it builds is the design the proof checks"
)
DONT_CARE_UNCHANGED = "changes nothing in the design"
DONT_CARE_SAFE: dict[str, list[tuple[str, str]]] = {
    "read": [
        (
            "[-formal] [-sv] [-noautowire] [-nosynthesis] [-define] [-D:1] [-D*]",
            DONT_CARE_FRONT_END,
        )
    ],
    "read_verilog": [("[-formal] [-sv] [-D:1] [-D*]", DONT_CARE_FRONT_END)],
    "read_slang": [
        (
            "[--top:1] [--single-unit] [--no-synthesis-define] [-D*] [-G*]",
            DONT_CARE_FRONT_END,
        )
    ],
    "verilog_defines": [("[-D:1] [-D*]", "sets macros for the readers that follow")],
    "hierarchy": [
        ("[-check] [-top:1] [-chparam:2]", "elaborates the hierarchy below the top")
    ],
    "chparam": [("-set:2", "elaborates the modules again with the parameters it sets")],
    "prep": [
        (
            "[-top:1] [-flatten]",
            "runs hierarchy -check, proc, check and flatten (with -flatten), future, "
            "opt_expr -keepdc, check, opt_clean, opt -noff -keepdc, wreduce -keepdc, "
            "opt_clean, memory_collect, opt -noff -keepdc -fast, sort, stat and "
            "check: starting values as in those passes, undefined constants as above",
        )
    ],
    "proc": [
        (
            "[-noopt] [-norom]",
            "lowers processes into cells and registers with the same initial values; "
            "proc_rom (unless -norom), proc_dlatch and its closing opt_expr -keepdc "
            "(unless -noopt) act on undefined constants as above",
        )
    ],
    "proc_clean": [
        ("", "removes empty switches; it folds only defined switch signals")
    ],
    "proc_rmdead": [
        ("", "removes cases that cannot match; a case label with x never matches")
    ],
    "proc_prune": [
        ("", "removes assignments that a later one overrides on every path")
    ],
    "proc_init": [("", "turns initial assignments into initial values")],
    "proc_arst": [("", "finds asynchronous resets")],
    "proc_mux": [
        (
            "",
            "turns decision trees into multiplexers, with x only for the bits a full "
            "case leaves unassigned",
        )
    ],
    "proc_dlatch": [
        (
            "",
            "turns incomplete combinational assignments into latches; in a latch's "
            "fan-in it drops all-x multiplexer cases, as above",
        )
    ],
    "proc_dff": [
        (
            "",
            "turns clocked processes into registers with the same initial values; "
            "it stores a constant asynchronous reset value, x included, in the "
            "register's parameters",
        )
    ],
    "proc_memwr": [("", "turns memory writes in processes into write ports")],
    "flatten": [("", "inlines submodules with their initial values")],
    "opt": [
        (
            "-keepdc [-fast] [-noff] [-purge] [-mux_bool]",
            "runs opt_expr, opt_merge, opt_muxtree, opt_reduce, opt_dff and "
            "opt_clean (-fast leaves out opt_muxtree and opt_reduce, -noff opt_dff); "
            "with -keepdc, opt_merge and opt_dff keep registers without a defined "
            "initial value and opt_expr skips the rewrites that consume undefined "
            "bits; -mux_bool turns a 0/1 multiplexer into its select; undefined "
            "constants as above",
        )
    ],
    "opt_expr": [
        (
            "-keepdc [-noclkinv] [-mux_bool]",
            "with -keepdc it skips the rewrites that consume undefined bits "
            "(opt_expr.cc:2364), except the $eq and $ne case above",
        )
    ],
    "opt_merge": [
        (
            "-keepdc",
            "with -keepdc it merges no register without a defined initial value; it "
            "never merges memories or free inputs; cells with constant-x inputs as "
            "above",
        )
    ],
    "opt_dff": [
        (
            "-keepdc",
            "with -keepdc it never fixes a register without a defined initial value "
            "to a constant",
        )
    ],
    "opt_clean": [
        ("[-purge]", "removes unused cells and wires, with the init case above")
    ],
    "clean": [("[-purge]", "the same pass as opt_clean")],
    "opt_muxtree": [
        (
            "",
            "removes multiplexer ports that cannot be selected, with the select case above",
        )
    ],
    "wreduce": [
        ("-keepdc", "with -keepdc it keeps every bit whose value is undefined")
    ],
    "memory_map": [
        (
            "-keepdc",
            "with -keepdc a word without a defined initial value becomes a register, "
            "which SymbiYosys makes free",
        ),
        (
            "-formal [-keepdc]",
            "implies -keepdc and uses $ff cells for ROMs and asynchronous writes",
        ),
    ],
    "setundef": [
        (
            "-anyseq [-undriven]",
            "gives each undefined bit, and with -undriven each undriven net, its own "
            "$anyseq, as SymbiYosys's preparation does",
        )
    ],
    "techmap": [
        (
            "",
            "maps cells to gates; its shift templates can resolve a constant x "
            "input, as above",
        )
    ],
    "async2sync": [
        (
            "",
            "turns asynchronous resets, loads and set-reset into synchronous logic "
            "with the same initial values, writing x where set and reset are both "
            "active",
        )
    ],
    "dffunmap": [("", "turns enables and synchronous resets into multiplexers")],
    "formalff": [
        (
            "-clk2ff",
            "turns clocked flip-flops into $ff cells with the same initial values",
        )
    ],
    "chformal": [
        (
            f"{mode} [-assert] [-assume] [-cover] [-live] [-fair]",
            "removes, relabels or lowers the property cells it selects",
        )
        for mode in ("-remove", "-assert2assume", "-lower")
    ],
    "connect": [
        ("-set:2 [-nounset] [-nomap]", "connects the nets the script names"),
        ("-port:3 [-nomap]", "connects the cell port the script names"),
    ],
    "delete": [
        (
            "[-input] [-output] [-port]",
            "removes what it selects; what a removed cell drove is left undriven, "
            "which SymbiYosys makes free",
        )
    ],
    "cutpoint": [("", "drives each cut signal from its own $anyseq")],
    "expose": [
        ("-dff -cut", "turns flip-flop outputs into module inputs, which are free")
    ],
    "setattr": [
        (
            "-set=keep|from_prim:2 [-mod]",
            "sets an attribute that decides only what may be removed or selected",
        ),
        (
            "-unset=init|keep|keep_hierarchy|dont_touch:1 [-mod]",
            "removes the attribute; a register without init starts free",
        ),
    ],
    "rename": [("[-top] [-hide]", "renames modules or wires")],
    "design": [
        (
            form,
            "saves, loads, copies or clears designs without changing a cell",
        )
        for form in (
            "-stash:1",
            "-save:1",
            "-load:1",
            "-reset",
            "-delete:1",
            "-copy-from:1 [-as:1]",
        )
    ],
    "equiv_make": [
        (
            "",
            "builds the module that compares two designs; their undriven nets become x",
        )
    ],
    "equiv_status": [("[-assert]", DONT_CARE_UNCHANGED)],
    "select": [
        (
            "[-assert-count:1] [-assert-min:1] [-assert-max:1] [-assert-none] "
            "[-assert-any] [-set:1] [-module:1] [-clear] [-none] [-add] [-del] "
            "[-list] [-count]",
            "changes only the selection",
        )
    ],
    "cd": [("", "changes only the current module")],
    "check": [("[-assert]", DONT_CARE_UNCHANGED)],
    "log": [("[-stderr]", DONT_CARE_UNCHANGED)],
    # They write a file; script_write_gaps checks which one.
    "write_rtlil": [("", DONT_CARE_UNCHANGED)],
    "write_json": [("", DONT_CARE_UNCHANGED)],
}
# The other forms of the commands that registered scripts run, and why they are
# rejected.
DONT_CARE_REJECTED = {
    "opt": (
        "without -keepdc, or with -full, -mux_undef, -undriven or -sat, which resolve "
        "undefined values, -fine, which also merges equal multiplexer output bits "
        "with constant x, or -share_all"
    ),
    "memory_map": "without -keepdc, an unwritten word without an initial value is x",
    "memory": (
        "runs opt_mem, opt_mem_priority, opt_mem_feedback and memory_share, and "
        "without -nomap a plain memory_map"
    ),
    "opt_mem": "reads undefined initial and written data as don't-cares",
    "opt_mem_priority": "runs inside memory; its source was not read for undefined values",
    "opt_mem_feedback": "resolves undefined multiplexer inputs",
    "memory_share": "lets a port's defined initial value win over x, resolves x inputs",
    "setundef": (
        "-zero, -one and -random pick values, -anyconst fixes one per trace, -init "
        "sets initial values"
    ),
    "chformal": "-delay adds registers without initial values, -skip adds a counter",
    "abc": "replaces every undefined bit with 0",
    "peepopt": "reads the x bits of a constant operand as 0",
    "sim": "with -w writes simulated values as initial values",
    "chtype": "changes cell types to whatever the script names",
    "techmap": "with -map, the map file decides what runs",
    "sat": "its proof reads an undefined bit as 0 without -enable_undef",
    "equiv_simple": "its proof reads an undefined bit as 0 without -undef",
    "equiv_struct": "merges structurally equal cells, free inputs included",
    "synth": "runs opt, memory and abc without -keepdc",
}
# Targets whose scripts run a command outside DONT_CARE_SAFE, each with a
# one-line reason and, for each group of tasks, the commands outside the list
# that each of those tasks runs, in the order it runs them. The checks fail
# when a task runs such a command a further time, drops one, runs them in
# another order, or moves one to another task, without the entry changing. A
# pinned command moved only past listed commands keeps its pin, and so does
# every pin when a listed command next to a pinned one is added, removed or
# edited. ROADMAP.md's verification items describe the open work.
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
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "bp_twin": ["setundef -zero", "setundef -zero", "equiv_simple @blk"],
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
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "cached_tier_twin cached_tier_unsplit": [
                "setundef -zero",
                "setundef -zero",
                "equiv_simple @blk",
            ],
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
            "coh_home_control_prove coh_home_control64_prove coh_home_control_partition_prove coh_home_control4_bmc coh_home_control4_ultra_bmc coh_home_fill_cover coh_home_cmo_cover coh_home_wb_prove coh_home_victim_cover coh_home_error_cover coh_home_prefetch_cover coh_home_dispatch_cover": [
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
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "home_engine_twin32 home_engine_twin64 home_engine_twin40": [
                "setundef -zero",
                "setundef -zero",
                "equiv_simple @blk",
            ],
        },
    ),
    "coherence_home_twin": (
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "home_twin_small home_twin_four home_twin_addr40": [
                "setundef -zero",
                "setundef -zero",
                "equiv_simple @blk",
            ],
        },
    ),
    "coherence_l1d": (
        "converted in its own commit; its conflict tasks cut every flop, then run opt -full and sat",
        {
            "coh_l1d_perf_prove coh_l1d_bmc coh_l1d_multi_bmc coh_l1d_stream_bmc coh_l1d_stream_hold_bmc coh_l1d_stream_free_nostore_bmc coh_l1d_stream_free_nostore_hold_bmc coh_l1d_stream_free_bmc coh_l1d_stream_outlier_prove coh_l1d_stream_owned_prove coh_l1d_stream_prove coh_l1d_stream_cover coh_l1d_turn_cover coh_l1d_cover coh_l1d_path_cover coh_l1d_put_select_prove coh_l1d_data_bmc coh_l1d_data1_bmc coh_l1d_data2_bmc coh_l1d_data3_bmc coh_l1d_store_payload_bmc coh_l1d_store_grant_bmc coh_l1d_store_multi_payload_bmc coh_l1d_store_multi_grant_bmc coh_l1d_multi_data0_bmc coh_l1d_multi_data1_bmc coh_l1d_multi_data2_bmc coh_l1d_multi_data3_bmc coh_l1d_ways_data_bmc coh_l1d_answer_bmc coh_l1d_stream_answer_bmc coh_l1d_local_prove coh_l1d_local_multi_prove coh_l1d_local_owned_prove coh_l1d_local_multi_owned_prove coh_l1d_local_ways_owned_prove coh_l1d_local_sector_prove coh_l1d_local_multi_sector_prove coh_l1d_local_ways_sector_prove coh_l1d_local_cover coh_l1d_local_data_bmc coh_l1d_local_hold_bmc coh_l1d_local_control_bmc coh_l1d_local_ways_prove coh_l1d_zero_bmc coh_l1d_zero_multi_bmc coh_l1d_zero_payload_bmc coh_l1d_zero_cover coh_l1d_zero_lookahead_cover coh_l1d_zero_stream_hint_bmc coh_l1d_zero_stream_line_bmc coh_l1d_zero_stream_upper_ep0_bmc coh_l1d_zero_stream_upper_ep1_read_bmc coh_l1d_zero_stream_upper_ep1_store_bmc coh_l1d_zero_stream_upper_ep1_lookahead_bmc coh_l1d_zero_stream_upper_ep1_prefetch_bmc coh_l1d_zero_stream_upper_ep1_rest_bmc coh_l1d_zero_stream_upper_ep2_bmc coh_l1d_zero_progress_cover coh_l1d_zero_stream_bmc coh_l1d_zero_request_cover coh_l1d_full_bmc coh_l1d_full_multi_bmc coh_l1d_full_payload_bmc coh_l1d_full_cover coh_l1d_full_lookahead_cover coh_l1d_withdraw_full_bmc coh_l1d_withdraw_zero_bmc coh_l1d_withdraw_full_payload_bmc coh_l1d_withdraw_zero_payload_bmc coh_l1d_withdraw_full_cover coh_l1d_full_hold_cover coh_l1d_buffer_contract_bmc": [
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
        "plain memory_map until converted together with coherence_l1d; zeroed undefined constants and equiv_simple as in every twin",
        {
            "l1d_twin_single l1d_twin_multi l1d_twin_stream": [
                "memory_map",
                "setundef -zero",
                "memory_map",
                "setundef -zero",
                "equiv_simple @blk",
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
    # With every register starting free, bmc_load_same takes 1,480 s against
    # 451 s, about 3.5 times as long per frame, also from the state after the
    # reset cycle, and smtbmc with Boolector checks 38 of its 80 steps in 20
    # minutes; the long tasks would not fit their limits.
    "coherence_store_boundary": (
        "plain memory_map and opt: its BMC tasks run them before their setundef, its cover and sticky tasks have none",
        {
            "bmc_four bmc_intervening bmc_load_same bmc_load_other bmc_amo_same bmc_amo_same_owner bmc_amo_same_fatal bmc_amo_other bmc_amo_other_fatal bmc_sc bmc_old": [
                "memory_map",
                "opt",
                "opt -fast",
            ],
            "cover_four prove_amo_same_fatal_sticky prove_amo_other_fatal_sticky cover_load cover_amo cover_amo_same cover_amo_same_two cover_amo_other_home cover_sc cover_old cover_edges_same cover_edges_same_combined cover_edges_other": [
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
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "store_pma_twin_ddr30 store_pma_twin_ddr31": [
                "setundef -zero",
                "setundef -zero",
                "equiv_simple @blk",
            ],
        },
    ),
    "control_flow_tracker_twin": (
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "cft_twin": ["setundef -zero", "setundef -zero", "equiv_simple @blk"],
        },
    ),
    "csr_file_twin": (
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "csr_twin csr_twin_vector": [
                "setundef -zero",
                "setundef -zero",
                "equiv_simple @blk",
            ],
        },
    ),
    "data_mem_request_router_twin": (
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "router_twin": ["setundef -zero", "setundef -zero", "equiv_simple @blk"],
        },
    ),
    "dc_fifo": (
        "not converted: memory_map and opt -full; no setundef",
        {
            "prove prove_margin2 cover": ["memory_map", "opt -full"],
        },
    ),
    "decoded_bundle_queue_twin": (
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "dbq_twin": ["setundef -zero", "setundef -zero", "equiv_simple @blk"],
        },
    ),
    "dmmu_capture": (
        "not converted: plain opt after its setundef",
        {
            "bmc prove cover": ["opt"],
        },
    ),
    "dmmu_twin": (
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "dmmu_twin": ["setundef -zero", "setundef -zero", "equiv_simple @blk"],
        },
    ),
    "fetch_pc_mux": (
        "not converted: plain opt after its setundef",
        {
            "bmc bmc_integrated bmc_xilinx bmc_integrated_xilinx": ["opt"],
        },
    ),
    "fp_engine_twin": (
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "fp_engine_twin": ["setundef -zero", "setundef -zero", "equiv_simple @blk"],
        },
    ),
    "id_stage_kill_equiv": (
        "in-script equivalence check: undefined constants zeroed, proved by equiv_simple, which reads an undefined bit as 0",
        {
            "id_kill_equiv": ["setundef -zero", "setundef -zero", "equiv_simple"],
            "id_kill_equiv_vector": [
                "setundef -zero",
                "setundef -zero",
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
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "immu_twin immu_twin_hold": [
                "setundef -zero",
                "setundef -zero",
                "equiv_simple @blk",
            ],
        },
    ),
    "line_client_link": (
        "not converted: memory_map and opt without -keepdc; no setundef",
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
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "pc_controller_twin pc_controller_twin_slot2": [
                "setundef -zero",
                "setundef -zero",
                "equiv_simple @blk",
            ],
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
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "pdt_twin": ["setundef -zero", "setundef -zero", "equiv_simple @blk"],
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
            "prove_int_active prove_int_ckpt_lo prove_int_ckpt_hi prove_fp_active prove_fp_ckpt_lo prove_fp_ckpt_hi cover": [
                "memory_map",
                "opt -full",
            ],
        },
    ),
    "reservation_station_twin": (
        "primitive twin: its in-script equivalence check zeroes undefined constants and proves with equiv_simple, which reads an undefined bit as 0",
        {
            "rs_twin_indexed": [
                "setundef -zero",
                "setundef -zero",
                "equiv_simple @blk",
            ],
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
        "in-script equivalence check with every flop cut: undefined constants zeroed, equiv_struct merging, and sat and equiv_simple reading x as 0",
        {
            "int_equiv int_equiv_prims": [
                "setundef -zero",
                "sat -seq 1 -verify -prove entry_cdb_tag[0] i_issue_cdb_tag -prove entry_cdb_tag[5] i_issue_cdb_tag -prove entry_cdb_tag[10] i_issue_cdb_tag -prove entry_cdb_tag[15] i_issue_cdb_tag -prove entry_cdb_2_tag[0] i_issue_cdb_2_tag -prove entry_cdb_2_tag[5] i_issue_cdb_2_tag -prove entry_cdb_2_tag[10] i_issue_cdb_2_tag -prove entry_cdb_2_tag[15] i_issue_cdb_2_tag reservation_station",
                "setundef -zero",
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
            "bmc bmc_cdb bmc_cdb_2 bmc_commit bmc_commit_2 bmc_operands": [
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
        "plain memory_map until converted together with coherence_l1d; zeroed undefined constants and equiv_simple as in every twin",
        {
            "sq_twin sq_twin_cpu": [
                "memory_map",
                "setundef -zero",
                "memory_map",
                "setundef -zero",
                "equiv_simple @blk",
            ],
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


def sby_task_scripts(sby_path: Path) -> tuple[dict[str, list[str]], dict[str, str]]:
    """Read task scripts and shared include files for tools outside the image."""
    source = sby_config.source(sby_path)
    configs = {name: source.task(name) for name in source.tasks}
    return (
        {name: cfg.script for name, cfg in configs.items()},
        next(iter(configs.values())).scripts(sby_path.parent),
    )


def dont_care_form_matches(form: str, args: list[str]) -> bool:
    """Report whether a command's arguments fit one DONT_CARE_SAFE form."""
    if form == "*":
        return True
    options: dict[str, tuple[int, set[str] | None]] = {}
    required: set[str] = set()
    prefixes: list[str] = []
    for item in form.split():
        optional = item.startswith("[")
        item = item.strip("[]")
        if item.endswith("*"):
            prefixes.append(item[:-1])
            continue
        name, _, arity = item.partition(":")
        name, _, choices = name.partition("=")
        options[name] = (
            int(arity or bool(choices)),
            set(choices.split("|")) if choices else None,
        )
        if not optional:
            required.add(name)
    seen: set[str] = set()
    index = 1
    while index < len(args):
        arg = args[index]
        if arg in options:
            taken, allowed = options[arg]
            if taken and index + taken >= len(args):
                return False
            if allowed is not None and args[index + 1] not in allowed:
                return False
            seen.add(arg)
            index += 1 + taken
        elif arg.startswith("-") and not any(arg.startswith(p) for p in prefixes):
            return False
        else:
            index += 1
    return required <= seen


def dont_care_safe(args: list[str]) -> bool:
    """Report whether a command matches a form in DONT_CARE_SAFE."""
    return "-share_all" not in args and any(
        dont_care_form_matches(form, args)
        for form, _ in DONT_CARE_SAFE.get(args[0], [])
    )


def dont_care_optimizations(commands: list[list[str]]) -> list[str]:
    """Return the commands outside DONT_CARE_SAFE a script runs, in order."""
    return [" ".join(args) for args in commands if not dont_care_safe(args)]


def sby_dont_care_optimizations(sby_path: Path) -> dict[str, list[str]]:
    """Return each task's commands outside DONT_CARE_SAFE, in the order it runs them."""
    return {
        task: found
        for task, cfg in sby_config.resolved(sby_path).items()
        if (
            found := dont_care_optimizations(
                yosys_commands(cfg.script, cfg.scripts(sby_path.parent))
            )
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
    """Every command a registered script runs has its forms decided."""
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    sby_config.resolve_files(formal.glob("*.sby"))
    names: dict[str, str] = {}
    for sby_path in sorted(formal.glob("*.sby")):
        for cfg in sby_config.resolved(sby_path).values():
            for args in yosys_commands(cfg.script, cfg.scripts(sby_path.parent)):
                names.setdefault(args[0], sby_path.name)
    unknown = {
        name: path
        for name, path in names.items()
        if name not in DONT_CARE_SAFE and name not in DONT_CARE_REJECTED
    }
    assert not unknown, unknown
    for name, forms in DONT_CARE_SAFE.items():
        for form, reason in forms:
            assert reason and "\n" not in reason, name
            dont_care_form_matches(form, [name])


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
# selected when it runs (a select that replaces, empties or scopes the
# selection, any select -module and a cd into a module scope it until a select
# -clear or cd, and design -save, -stash and -push keep that scope with the
# design for design -load and -pop to bring back, while design -reset clears
# it); after it, another opening before the next command that acts once a
# source is read or a parameter set again (read, read_verilog, read_slang,
# chparam, hierarchy -chparam), the design is reset, or modules of a kept
# design join it (design -copy-from, -import), and a design that design -load
# or -pop brings back is opened only if it was when it was kept; the same top
# in every later hierarchy -top and prep -top; no connect to a constant with
# an x or z bit, in any spelling; and setundef -anyseq right after a script's
# own async2sync or clk2fflogic, which write x where an asynchronous set and
# clear are both active. A script file included with a label runs only that
# block, as in Yosys.
#
# The opening does not reach undefined values that a cell computes, such as a
# $shiftx read past its input, which the backends and the default techmap's
# shift templates give a defined value, or a $pmux with more than one select
# set; constant z bits, which setundef -anyseq leaves (as SymbiYosys's own
# setundef does) and no source has; or a memory initialized with x, which makes
# the next pass that reads the memory stop with "Non-constant data".
UNDEFINED_OPENING = [
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
# Commands that may run before the opening, each only in a form that
# DONT_CARE_SAFE lists: they read sources, set parameters, elaborate, or
# change neither a cell nor a constant. select and cd can change what the
# opening runs on; the check follows them.
UNDEFINED_OPENING_BEFORE = {
    "read",
    "read_verilog",
    "read_slang",
    "verilog_defines",
    "chparam",
    "hierarchy",
    "select",
    "cd",
    "log",
    "check",
    "write_rtlil",
    "write_json",
    "delete",
    "setattr",
    "rename",
    "connect",
    "cutpoint",
    "chformal",
}
# Every form of a command of the image's Yosys (0.70) that writes a file, from
# the help of each command: the options that take the file, or "*" when the
# command writes whatever its options. Every write_* command writes the files
# its words name. tee here is the wrapper `tee -o|-a <file> <command>`.
YOSYS_FILE_WRITES: dict[str, tuple[str, ...]] = {
    "tee": ("-o", "-a"),
    "select": ("-write",),
    "dump": ("-o", "-a"),
    "json": ("-o",),
    "jny": ("-o",),
    "sat": ("-dump_vcd", "-dump_json", "-dump_cnf"),
    "sim": ("-vcd", "-fst", "-aiw"),
    "qbfsat": ("-dump-final-smt2", "-write-solution"),
    "freduce": ("-dump",),
    "mutate": ("-o", "-s"),
    "fsm_export": ("*",),
    "fsm_recode": ("-fm_set_fsm_file", "-encfile"),
    "extract": ("-mine",),
    "linecoverage": ("-lcov",),
    "abc": ("-script",),
    "abc9": ("-script",),
    "abc9_exe": ("-script",),
    "abc9_ops": ("-write_lut", "-write_box"),
    "read_slang": (
        "--diag-json",
        "--Mall",
        "--all-deps",
        "--Minclude",
        "--include-deps",
        "--Mmodule",
        "--module-deps",
    ),
    "opensta": ("-sdc-out",),
    "sdc_expand": ("*",),
    "show": ("*",),
    "viz": ("*",),
    "icell_liberty": ("*",),
    "fst2tb": ("*",),
    "test_autotb": ("*",),
    "bugpoint": ("*",),
    "verific": ("-d",),
    "synth": ("-encfile",),
    "synthprop": ("-map",),
    "synth_*": (
        "-blif",
        "-edif",
        "-json",
        "-verilog",
        "-vlog",
        "-vout",
        "-vpr",
        "-vqm",
    ),
}
# The file-writing forms that scripts may run, and only these: the forms that
# the scripts on main need. btb_pending_relation, btb_tag_compare,
# data_mem_response_mux and sc_head_query write the prepared model with
# `write_json <file>`, and axi_coherent_bridge's partitioned task writes
# `write_rtlil ../model/<file>`. The file is a plain name in src/ or in
# ../model/, and never one that SymbiYosys copies into src/, one that any
# command of the task names, or SymbiYosys's own design files in model/.
SCRIPT_FILE_WRITES = {"write_json", "write_rtlil"}
# The opening's file. A script lists it in [files] as the single word
# free_undefined.ys, so that SymbiYosys copies the repository's
# formal/free_undefined.ys unchanged, and runs it with `script
# free_undefined.ys`; the check reads that command as the opening, and the
# file's content is pinned to UNDEFINED_OPENING.
UNDEFINED_OPENING_FILE = "free_undefined.ys"
UNDEFINED_OPENING_MARK = ["<free_undefined.ys>"]
UNDEFINED_OPENING_SOURCES = {"read", "read_verilog", "read_slang", "chparam"}
# A constant with an x or z digit, as Yosys's Verilog constant parser reads
# connect arguments: 1'x, 1'bx, 1'X, 4'hx, 2'b0?, in a concatenation too.
UNDEFINED_CONSTANT = re.compile(r"\d*'[sS]?[bBoOdDhH]?[0-9a-fA-F_xXzZ?]*[xXzZ?]")
# Scripts that do not open that way yet. The list only shrinks: a listed script
# whose every task opens fails the check.
UNDEFINED_OPENING_PENDING = (
    "coherence_array",
    "coherence_array_equiv",
    "coherence_home",
    "coherence_l1d",
    "coherence_store_boundary",
    "csr_commit_cofactor",
    "csr_file",
    "line_client_link",
    "pm_mode_select",
    "reorder_buffer",
    "sq_forwarding_unit",
    "vec_lmul_legality_equiv",
)
# Scripts that compare two designs inside the script (the primitive twins and
# the other in-script equivalence checks). Both designs hold the same undefined
# constants, so freeing them separately on each side would make the sides
# differ; these scripts wait for an opening of their own and do not open yet.
UNDEFINED_OPENING_TWINS = (
    "branch_predictor_twin",
    "cached_tier_adapter_twin",
    "coherence_home_engine_twin",
    "coherence_home_twin",
    "coherence_l1d_twin",
    "coherent_store_pma_twin",
    "control_flow_tracker_twin",
    "csr_file_twin",
    "data_mem_request_router_twin",
    "decoded_bundle_queue_twin",
    "dmmu_twin",
    "fp_engine_twin",
    "id_stage_kill_equiv",
    "immu_twin",
    "pc_controller_twin",
    "pd_target_candidate_twin",
    "reservation_station_twin",
    "rs_issue_tag_banks",
    "store_queue_twin",
)


def selection_change(args: list[str]) -> str | None:
    """Return "scoped" or "full" when a select or cd changes the selection.

    A select that lists, counts, asserts, writes or names a selection changes
    nothing unless it has -module, which sets the active module in any form.
    """
    if args[0] == "cd":
        return "full" if args[1:] in ([], ["/"]) else "scoped"
    if args[0] != "select":
        return None
    if "-module" in args:
        return "scoped"
    if "-clear" in args:
        return "full"
    if "-none" in args or "-add" in args or "-del" in args or "-read" in args:
        return "scoped"
    passive = {
        "-list",
        "-list-mod",
        "-count",
        "-write",
        "-set",
        "-unset",
        "-assert-none",
        "-assert-any",
        "-assert-count",
        "-assert-max",
        "-assert-min",
        "-assert-mod-count",
    }
    if passive & set(args):
        return None
    return "scoped" if len(args) > 1 else None


def file_write(args: list[str]) -> str | None:
    """Return the form of a command that writes a file, or None.

    The form is the command with the option that writes, from
    YOSYS_FILE_WRITES, or the command alone for a write_* command and for one
    that always writes.
    """
    name = args[0]
    if name.startswith("write_"):
        return name
    spec = YOSYS_FILE_WRITES.get(name)
    if spec is None and name.startswith("synth_"):
        spec = YOSYS_FILE_WRITES["synth_*"]
    if spec is None:
        return None
    if "*" in spec:
        return name
    for arg in args[1:]:
        if arg in spec:
            return f"{name} {arg}"
    return None


def script_write_gaps(sby_path: Path, cfg: sby_config.TaskConfig) -> list[str]:
    """Return the files a task writes that the checks could not follow.

    A task may write a file only with a form of SCRIPT_FILE_WRITES that has no
    option, into a plain name in src/ or ../model/; the name may not be one that
    SymbiYosys copies into src/, one that another command of the task names, or
    a design file of SymbiYosys's own in model/.
    """
    gaps: list[str] = []
    # The opening's file is pinned and writes nothing; it may be missing here.
    files = cfg.scripts(sby_path.parent)
    files.setdefault(UNDEFINED_OPENING_FILE, UNDEFINED_OPENING_MARK[0])
    try:
        commands = yosys_commands(cfg.script, files)
    except AssertionError as error:
        return [f"its commands cannot be read: {error}"]
    copied = set(cfg.files) | set(cfg.inline)
    for index, args in enumerate(commands):
        form = file_write(args)
        if form is None:
            continue
        text = " ".join(args)
        if form not in SCRIPT_FILE_WRITES or len(args) != 2:
            gaps.append(f"{text}: writes a file ({form}), which no script may")
            continue
        target = args[1]
        match = re.fullmatch(r"(\.\./model/)?([A-Za-z0-9_][A-Za-z0-9_.-]*)", target)
        named = {
            word
            for other, words in enumerate(commands)
            if other != index
            for word in words[1:]
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


def undefined_opening_gaps(commands: list[list[str]]) -> list[str]:
    """Return what keeps a task's commands from opening as required, in order."""
    gaps: list[str] = []
    openings = 0
    # What the check knows of the design Yosys works on: opened, it has had its
    # opening; early, an acting command came before it; after_async, the last
    # command was a script's own async2sync or clk2fflogic; scoped, the
    # selection or the active module is narrower than the design; elaborated,
    # the top named after the last source; top, the one the opening ran with.
    # design -save, -stash and -push keep a design with its selection and
    # active module, and -load and -pop bring both back (design.cc:344-385),
    # so the check keeps this state with them.
    fresh: dict = {
        "opened": False,
        "early": False,
        "after_async": False,
        "scoped": False,
        "elaborated": None,
        "top": None,
    }
    state = dict(fresh)
    saved: dict[str, dict] = {}
    pushed: list[dict] = []
    for args in commands:
        name, text = args[0], " ".join(args)
        named_top = args[args.index("-top") + 1] if "-top" in args[:-1] else None
        if name in UNDEFINED_OPENING_BEFORE and not dont_care_safe(args):
            gaps.append(f"{text}: not a form of {name} that DONT_CARE_SAFE lists")
            continue
        change = selection_change(args)
        if change:
            state["scoped"] = change == "scoped"
            continue
        if name == "design":
            mode = args[1] if len(args) > 1 else ""
            target = args[2] if len(args) > 2 else ""
            plain = r"[A-Za-z0-9_]+"
            if mode in ("-copy-from", "-copy-to", "-import"):
                shape = bool(
                    re.fullmatch(
                        rf"design {mode} {plain}(?: -as {plain})?(?: {plain})?", text
                    )
                )
            elif mode in ("-save", "-stash", "-load", "-delete"):
                shape = len(args) == 3 and bool(re.fullmatch(plain, target))
            else:
                shape = len(args) == 2 and mode in (
                    "-reset",
                    "-pop",
                    "-push",
                    "-push-copy",
                )
            if not shape:
                gaps.append(f"{text}: unsupported design operation")
                continue
            # Keep the provenance of every design that can supply modules.
            unknown = {**fresh, "scoped": True}
            if mode in ("-save", "-stash", "-push", "-push-copy", "-copy-to"):
                if not state["opened"]:
                    gaps.append(f"{text}: the source design has no opening")
            if mode in ("-load", "-import", "-copy-from", "-copy-to"):
                if not saved.get(target, fresh)["opened"]:
                    gaps.append(f"{text}: saved design {target!r} has no opening")
            if mode in ("-save", "-stash"):
                saved[target] = dict(state)
            if mode in ("-push", "-push-copy"):
                pushed.append(dict(state))
            if mode in ("-reset", "-stash", "-push"):
                state = dict(fresh)
            elif mode == "-load":
                state = dict(saved.get(target, unknown))
            elif mode == "-pop":
                state = pushed.pop() if pushed else unknown
                if not state["opened"]:
                    gaps.append(f"{text}: stacked design has no opening")
            elif mode in ("-copy-from", "-import"):
                state.update(opened=False, early=False, after_async=False)
                state["elaborated"] = None
            elif mode == "-copy-to":
                kept = saved.get(target, unknown)
                saved[target] = {**kept, "opened": kept["opened"] and state["opened"]}
            elif mode == "-delete":
                saved.pop(target, None)
            continue
        if name == "techmap":
            for index, arg in enumerate(args):
                if arg == "-map":
                    source = args[index + 1] if index + 1 < len(args) else ""
                    if (
                        not source.startswith("%")
                        or not saved.get(source[1:], fresh)["opened"]
                    ):
                        gaps.append(f"{text}: map {source!r} has no saved opening")
        if name in UNDEFINED_OPENING_SOURCES or (
            name == "hierarchy" and "-chparam" in args
        ):
            state.update(opened=False, early=False, after_async=False)
            state["elaborated"] = None
            continue
        if name == "hierarchy":
            if not state["opened"]:
                state["elaborated"] = named_top or state["elaborated"]
            elif named_top not in (None, state["top"]):
                gaps.append(f"{text}: another top after the opening")
            continue
        if args == UNDEFINED_OPENING_MARK:
            text = f"script {UNDEFINED_OPENING_FILE}"
            if not state["opened"]:
                if state["scoped"]:
                    gaps.append(
                        f"{text}: the opening runs on a selection, not the design"
                    )
                if state["elaborated"] is None:
                    gaps.append(f"{text}: no hierarchy -top after the last source")
                state["opened"], state["top"] = True, state["elaborated"]
                openings += 1
            continue
        if name in UNDEFINED_OPENING_BEFORE:
            if (
                state["opened"]
                and name == "connect"
                and any(UNDEFINED_CONSTANT.search(arg) for arg in args[1:])
            ):
                gaps.append(f"{text}: connects an undefined constant after the opening")
            continue
        if not state["opened"]:
            if not state["early"]:
                gaps.append(f"{text}: acts before the opening")
            state["early"] = True
            continue
        if name == "prep" and named_top not in (None, state["top"]):
            gaps.append(f"{text}: another top after the opening")
        if state["after_async"] and not (
            name == "setundef"
            and sorted(args[1:]) in (["-anyseq"], ["-anyseq", "-undriven"])
        ):
            gaps.append(f"{text}: acts on what async2sync or clk2fflogic writes")
        state["after_async"] = name in ("async2sync", "clk2fflogic")
    if not openings:
        gaps.append("no opening")
    return gaps


def sby_tag_gaps(sby_path: Path) -> list[str]:
    """Return syntax that cannot be read identically by all proof tools."""
    try:
        sby_config.source(sby_path)
    except sby_config.ConfigError as error:
        return [str(error)]
    return []


def undefined_opening_file_gaps(
    sby_path: Path, cfg: sby_config.TaskConfig
) -> list[str]:
    """Check the named opening against the file SymbiYosys gives this task."""
    name = UNDEFINED_OPENING_FILE
    if name in cfg.inline:
        return [f"[file {name}]: the opening's file is written in the script"]
    if cfg.files.get(name) != name:
        return [
            f"[files]: expected the single entry {name}, got {cfg.files.get(name)!r}"
        ]
    copy = sby_path.parent / name
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
        files = cfg.scripts(sby_path.parent)
        files[UNDEFINED_OPENING_FILE] = UNDEFINED_OPENING_MARK[0]
        commands = yosys_commands(cfg.script, files)
        named = (
            UNDEFINED_OPENING_MARK in commands
            or UNDEFINED_OPENING_FILE in cfg.files
            or UNDEFINED_OPENING_FILE in cfg.inline
        )
        gaps = undefined_opening_file_gaps(sby_path, cfg) if named else []
        gaps += undefined_opening_gaps(commands)
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
# opening's file emptied by select -write), then other writing forms; each
# must fail the check. The controls are the forms that scripts on main use.
SCRIPT_WRITE_CASES: list[tuple[str, str]] = [
    (
        "flag",
        "tee -q -o free_undefined.ys log proc\ntee -q -a free_undefined.ys log setundef -zero\n",
    ),
    ("flag", "tee -q -o top.sv log //\n"),
    ("flag", "select -none\nselect -write free_undefined.ys\nselect -clear\n"),
    ("flag", "select -none -write free_undefined.ys\nselect -clear\n"),
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
        "[options]\nmode bmc\n\n[engines]\nsmtbmc\n\n[script]\n"
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
    """Every command and option of YOSYS_FILE_WRITES is in the image's Yosys help."""
    listing = subprocess.run(
        ["yosys", "-Q", "-p", "help"],
        capture_output=True,
        text=True,
        check=True,
        timeout=120,
    ).stdout
    known = set(re.findall(r"^\s+([a-z_0-9]+)\s", listing, re.M))
    writers = sorted(name for name in known if name.startswith("write_"))
    assert writers and all(file_write([name, "x"]) == name for name in writers)
    for name, options in YOSYS_FILE_WRITES.items():
        if name == "synth_*":
            continue
        assert name in known, name
        if options == ("*",):
            continue
        text = subprocess.run(
            ["yosys", "-h", name],
            capture_output=True,
            text=True,
            check=True,
            timeout=120,
        ).stdout
        missing = [
            option
            for option in options
            if not re.search(
                rf"(^|[\s,|\[]){re.escape(option)}([\s,|\]]|$)", text, re.M
            )
        ]
        assert missing == [], (name, missing)


def test_wrappers_show_their_files() -> None:
    """tee, trace and debug come out with their options before the command."""
    assert yosys_commands(["tee -q -o x.log opt -keepdc"], {}) == [
        ["tee", "-q", "-o", "x.log"],
        ["opt", "-keepdc"],
    ]
    assert yosys_commands(["trace debug prep"], {}) == [["trace"], ["debug"], ["prep"]]
    assert yosys_commands(["debug -on"], {}) == [["debug", "-on"]]


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
    opening = (formal / "free_undefined.ys").read_text().splitlines()
    assert yosys_commands(opening, {}) == UNDEFINED_OPENING


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
                "setundef -zero\nsetattr -unset init\ndffunmap\n"
                "# Keep every named net so that registers and signals pair by name.\n"
                "setattr -set keep 1 w:* w:$* %d\nopt_clean\nrename -top gold\n",
                "setundef -one\nsetattr -unset init\ndffunmap\n"
                "# Keep every named net so that registers and signals pair by name.\n"
                "setattr -set keep 1 w:* w:$* %d\nopt_clean\nrename -top gold\n",
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
    # A further command in pinned tasks of a file with an open entry.
    (
        "flag",
        "coherent_hart_cache",
        (("covers: setundef -zero\n", "covers: setundef -zero\ncovers: opt -full\n"),),
    ),
    # Sound edits: options in another order, tee around a listed form, debug
    # -on with words after it (Yosys then runs nothing), ';;' and clean -purge,
    # memory_map -keepdc -formal and setattr -unset init.
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
        "accept",
        "coherence_array_plru",
        (("memory_map -keepdc\n", "memory_map -keepdc;;\nclean -purge\n"),),
    ),
    (
        "accept",
        "coherence_array_plru",
        (("memory_map -keepdc\n", "memory_map -keepdc -formal\n"),),
    ),
    (
        "accept",
        "coherence_home_completions",
        (("proof: techmap\n", "setattr -unset init w:*\nproof: techmap\n"),),
    ),
    # Sound edits: a continued -keepdc, a comment, a quoted string, debug -on
    # and a label after leading whitespace.
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
        "accept",
        "coherence_array_plru",
        (("memory_map -keepdc\n", 'memory_map -keepdc\nlog "opt -full; opt"\n'),),
    ),
    (
        "flag",
        "coherence_array_plru",
        (("memory_map -keepdc\n", "memory_map -keepdc\ndebug -on opt\n"),),
    ),
    (
        "accept",
        "coherence_array_equiv",
        (("techmap\n", "  lbl: opt -keepdc\ntechmap\n"),),
    ),
    # More forms on the list.
    (
        "accept",
        "coherence_home_completions",
        (("proof: techmap\n", "setundef -undriven -anyseq\nproof: techmap\n"),),
    ),
    (
        "accept",
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
    text = mutated.read_text()
    for old, new in edits:
        assert text.count(old) == 1, (name, old)
        text = text.replace(old, new)
    mutated.write_text(text)
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
    """Tags, labels, comments, ';', script files, and assertions exempt nothing."""
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
        "[tasks]\nfirst proof\nsecond covers\nthird:\n\n[script]\nprep -top top\n"
        "proof: opt;; opt -keepdc # opt\n~proof: tee -q -o opt.log opt -keepdc\n"
        "covers: script extra.ys\nlog opt\n"
        f"proof: {no_state}\nproof: opt -full\n"
        "\n[file extra.ys]\n label: opt_expr -keepdc; memory_map -formal\nmemory -nomap\n"
    )
    scripts, files = sby_task_scripts(sby_path)
    assert {
        task: yosys_commands(script, files) for task, script in scripts.items()
    } == {
        "first": [
            ["prep", "-top", "top"],
            ["opt"],
            ["clean"],
            ["opt", "-keepdc"],
            ["log", "opt"],
            no_state.split(),
            ["opt", "-full"],
        ],
        "second": [
            ["prep", "-top", "top"],
            ["tee", "-q", "-o", "opt.log"],
            ["opt", "-keepdc"],
            ["opt_expr", "-keepdc"],
            ["memory_map", "-formal"],
            ["memory", "-nomap"],
            ["log", "opt"],
        ],
        # A task line in the "name:" form is not a tag block.
        "third": [
            ["prep", "-top", "top"],
            ["tee", "-q", "-o", "opt.log"],
            ["opt", "-keepdc"],
            ["log", "opt"],
        ],
    }
    # The plain opt and, after the assertion, opt -full; memory -nomap runs
    # opt_mem and memory_share, which resolve undefined words; tee is not a
    # listed command, and it writes a file.
    assert sby_dont_care_optimizations(sby_path) == {
        "first": ["opt", "opt -full"],
        "second": ["tee -q -o opt.log", "memory -nomap"],
        "third": ["tee -q -o opt.log"],
    }
    # An assertion that no state is left exempts nothing, whatever scope or
    # selection it has, since undefined constants remain.
    for prefix in ([], [["cd", "top"]], [["select", "-list", "-module", "sub"]]):
        assert dont_care_optimizations(
            [*prefix, no_state.split(), ["opt", "-full"]]
        ) == ["opt -full"]
    assert dont_care_optimizations(
        [no_state.split(), ["chformal", "-delay", "1"], ["opt"]]
    ) == ["chformal -delay 1", "opt"]
    # -share_all fuses free inputs, whatever else the command says.
    assert dont_care_optimizations([["opt", "-keepdc", "-share_all"]]) == [
        "opt -keepdc -share_all"
    ]
    # An open entry pins each task's commands in order.
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
    # Sound variants: the opening in an included script, also entered at its
    # label; setundef -undriven after it; a selection asserted or cleared
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
        "accept",
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
                "select -assert-min 1 t:*\nselect w:*\nselect -clear\nscript free_undefined.ys\n",
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
    text = mutated.read_text()
    for old, new in edits:
        assert text.count(old) == 1, (name, old)
        text = text.replace(old, new)
    mutated.write_text(text)
    if file_edits:
        opening = mutated.with_name(UNDEFINED_OPENING_FILE)
        body = opening.read_text()
        for old, new in file_edits:
            assert body.count(old) == 1, old
            body = body.replace(old, new)
        opening.write_text(body)
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
        "[tasks]\na: group default\nb: group\n[script]\n"
        "group: hierarchy -top top\na: script free_undefined.ys\nb: setundef -zero\n"
        "[files]\nfree_undefined.ys\n"
    )
    formal = Path(__file__).resolve().parents[1] / FORMAL_DIR
    (tmp_path / UNDEFINED_OPENING_FILE).write_bytes(
        (formal / UNDEFINED_OPENING_FILE).read_bytes()
    )
    assert list(sby_config.resolved(path)) == ["a", "b"]
    assert sby_config.resolved(path)["b"].script == [
        "hierarchy -top top",
        "setundef -zero",
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
                assert source.task(task) == sby_config.TaskConfig(**entry), (name, task)
    assert refused == 12


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
    """Which commands may precede the opening, and what resets or scopes it."""
    opening = [["hierarchy", "-top", "top"], UNDEFINED_OPENING_MARK]
    assert (
        undefined_opening_gaps(
            [["read", "-formal", "a.sv"], *opening, ["opt", "-keepdc"]]
        )
        == []
    )
    # A delete, a cut or a listing may come first; an optimizing pass may not.
    assert (
        undefined_opening_gaps(
            [
                ["delete", "t:sub"],
                ["cutpoint", "w:x"],
                ["select", "-list", "t:*"],
                *opening,
            ]
        )
        == []
    )
    assert undefined_opening_gaps([["flatten"], *opening]) == [
        "flatten: acts before the opening"
    ]
    # A selection left in place when the opening runs.
    assert undefined_opening_gaps([["select", "-module", "sub"], *opening]) == [
        "script free_undefined.ys: the opening runs on a selection, not the design"
    ]
    # The opening's commands written out are not the opening.
    assert undefined_opening_gaps(
        [["hierarchy", "-top", "top"], *UNDEFINED_OPENING, ["prep", "-top", "top"]]
    ) == ["proc_clean: acts before the opening", "no opening"]
    assert undefined_opening_gaps([["cd", "sub"], ["cd"], *opening]) == []
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
    # A design read after a reset needs its own opening; a further hierarchy
    # with the same top does not.
    assert undefined_opening_gaps(
        [*opening, ["design", "-reset"], ["read", "b.sv"], ["prep", "-top", "b"]]
    ) == ["prep -top b: acts before the opening"]
    assert (
        undefined_opening_gaps(
            [*opening, ["hierarchy", "-top", "top"], ["prep", "-top", "top"]]
        )
        == []
    )
    assert undefined_opening_gaps([*opening, ["hierarchy", "-top", "sub"]]) == [
        "hierarchy -top sub: another top after the opening"
    ]
    # clk2fflogic's undefined values are freed before the next acting command.
    assert (
        undefined_opening_gaps(
            [*opening, ["clk2fflogic"], ["setundef", "-anyseq"], ["opt", "-keepdc"]]
        )
        == []
    )
    assert undefined_opening_gaps([*opening, ["clk2fflogic"], ["opt", "-keepdc"]]) == [
        "opt -keepdc: acts on what async2sync or clk2fflogic writes"
    ]
    # Constants with x or z, as connect's Verilog constant parser takes them.
    for spelled in ("1'x", "1'bx", "1'X", "4'hx", "2'b0?", "{a,1'bz}", "8'hxF"):
        assert UNDEFINED_CONSTANT.search(spelled), spelled
    for spelled in ("1'b0", "8'h00", "5'b00000", "16'hDEAD", "w:x_q", "dut.x"):
        assert not UNDEFINED_CONSTANT.search(spelled), spelled
    # A labeled include runs only its block, as Yosys runs it.
    lines = ["a: log a", "log a2", "b: log b", "c:", "log c"]
    assert script_block(list(lines), "b") == [" log b"]
    assert script_block(list(lines), "a:c") == [" log a", "log a2", " log b"]
    assert script_block(list(lines), ":b") == [" log a", "log a2"]


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
        positions = [script.index(command) for command in pipeline]
        assert positions == sorted(positions)
        assert positions[-1] < script.index("setundef -anyseq")
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
            engine = "abc bmc3 -c" if base.startswith("link_") else "abc bmc3"
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
            positions = [script.index(command) for command in partition]
            assert positions == sorted(positions)
            assert positions[-1] < script.index("memory_map -keepdc")
            assert script.index("peepopt") < script.index("techmap")
            assert script.index("techmap") < script.index("setundef -anyseq")
            assert "select -assert-none t:$check r:FLAVOR=assume %i" in script
            assert "select -assert-none t:$assume" in script
            # The complete configurations differ only by the exhaustive watch value.
            bounded["[script]"] = [line for line in script if line != bind]
            pair.append(bounded)
        assert pair[0] == pair[1]


def test_home_twin_snapshot_budget() -> None:
    """Equivalence construction releases saved copies without changing geometry."""
    for task, floor in (
        ("home_twin_small", 4296),
        ("home_twin_four", 4870),
        ("home_twin_addr40", 4328),
    ):
        config = formal_task_config("coherence_home_twin", task)
        options = dict(line.split(None, 1) for line in config["[options]"])
        assert options == {"mode": "bmc", "depth": "1", "timeout": "600"}
        assert formal_task_timeout_s("coherence_home_twin", task) == 600
        script = config["[script]"]
        make = script.index("equiv_make gold gate equiv")
        for variant in ("gold", "gate"):
            copy = f"design -copy-from {variant} -as {variant} {variant}"
            release = f"design -delete {variant}"
            assert script.index(copy) < script.index(release) < make
        assert f"select -assert-min {floor} @blk" in script
        assert "equiv_simple @blk" in script
        assert "equiv_status -assert @blk" in script
        if task == "home_twin_four":
            geometry = (
                "chparam -set CACHE_BYTES 1024 -set WAYS 4 -set ULTRA 1 "
                "-set COMPLETIONS 4 -set RESULTS 3 -set FILLS 3 "
                "-set PREFETCH_RESERVE 1 -set PREFETCH_SLOTS 0 coherence_home"
            )
            assert script.count(geometry) == 2


def test_home_shard_budget() -> None:
    """The complete home task limits and image setup fit their CI job."""
    import yaml
    from _pytest.mark.expression import Expression

    root = Path(__file__).resolve().parents[1]
    workflow = yaml.safe_load((root / ".github/workflows/ci.yml").read_text())
    shards = workflow["jobs"]["test-formal"]["strategy"]["matrix"]["include"]
    shard = next(row for row in shards if row["shard"] == "Coherence home")
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
    home = next(target for target in FORMAL_TARGETS if target.name == "coherence_home")
    assert selected == [(home.name, task) for task in home.tasks]
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
    setup_seconds = 20 * 60
    assert sum(limits) + setup_seconds <= shard["timeout_minutes"] * 60


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
            "bmc_commit_2: depth 6",
            "bmc_commit_2: depth 5",
            id="cmo-before-request",
        ),
    ],
)
def test_rs_payload_twin_assertion_groups(
    source: str, old: str, new: str, tmp_path: Path
) -> None:
    """Check six proof configurations and guarded comparisons with isolated edits."""
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
        "script free_undefined.ys",
        "chformal -assert -remove * rs_payload_twin_formal %d",
        "prep -top rs_payload_twin_formal",
        "setattr -mod -unset keep_hierarchy *",
        "flatten",
        "memory_map -keepdc",
        "opt_clean",
        "setundef -zero -init",
        "select -assert-count 104 t:$check r:FLAVOR=assume %i",
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
            "rs_payload_twin.sby": "f425330cbe1fe3b25a25f0892775085f7f55572149a5284e248d213a13d11eaf",
            "rs_payload_twin_formal.sv": "bf55b92f3eb8eda22aef16b2268c2a1c1f458f946711b536cdc397fbb008ae61",
            "free_undefined.ys": "9b2c2cb8b810c89401509a3ab42db9ea522b9e80b132d5c73d5ab8d516c3fe89",
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
        scripts, _ = sby_task_scripts(sby)
        assert scripts.keys() == counts.keys()
        for task, count in counts.items():
            config = formal_task_config(str(sby.with_suffix("")), task)
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
            "script axi_coherent_bridge_groups.ys",
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
    files = [
        "../hw/rtl/lib/cache/coherence_read_stream.sv",
        "../hw/rtl/lib/ram/sdp_block_ram.sv",
        "../hw/rtl/lib/ram/sdp_packed_tag_uram.sv",
        "../hw/rtl/lib/ram/sdp_ram_byte_en.sv",
    ] + [
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
            + ["prep -flatten -top coherence_l1d"]
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
        "prep -flatten -top coherence_l1d",
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
    ] + [
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
        start = next(i for i, line in enumerate(script) if line.startswith("select "))
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
    files = [
        "../hw/rtl/lib/cache/coherence_read_stream.sv",
        "../hw/rtl/lib/ram/sdp_block_ram.sv",
        "../hw/rtl/lib/ram/sdp_packed_tag_uram.sv",
        "../hw/rtl/lib/ram/sdp_ram_byte_en.sv",
    ] + [
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
            + ["prep -flatten -top coherence_l1d"]
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
            "timeout": "1200",
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
        "c:p_load_payload_held c:p_reply_hold"
    )
    common = [
        "select -assert-count 1 c:p_prefetch_conflict_split t:$check %i r:FLAVOR=assert %i",
        "chformal -assert2assume c:p_prefetch_conflict_split",
    ]
    commands = {
        "hold": common
        + [
            "select -assert-count 328 t:$check r:FLAVOR=assert %i",
            f"select -assert-count 4 {holds}",
            f"chformal -assert -remove t:$check r:FLAVOR=assert %i {holds} %u %u %u %d",
            "select -assert-count 4 t:$check r:FLAVOR=assert %i",
        ],
        "bmc": common
        + [
            "select -assert-count 328 t:$check r:FLAVOR=assert %i",
            f"chformal -assert -remove {holds}",
            "select -assert-count 324 t:$check r:FLAVOR=assert %i",
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
        "select -assert-count 28 t:$check r:FLAVOR=assert %i",
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
    """Require the stream ownership lemmas' model to match their consumer's."""
    owned = l1d_task_config("coh_l1d_stream_owned_prove")
    proof = l1d_task_config("coh_l1d_stream_prove")
    assert owned.keys() == proof.keys()
    for section in owned.keys() - {"[options]", "[engines]", "[script]"}:
        assert owned[section] == proof[section]
    model = [line for line in owned["[script]"] if not assertion_command(line)]
    assert model == [line for line in proof["[script]"] if not assertion_command(line)]
    assert "read -formal -sv coherence_request_endpoint.sv" in model
    assert (
        "read -formal -sv -D STREAM_UNBOUNDED_PROOF -D READ_OWNER_PROOF "
        "coherence_read_payload.sv coherence_l1d.sv"
    ) in model
    lemmas = "c:p_owned_* c:p_selected_kind c:p_path_shadowed"
    # The lemma task proves its lemmas from the design alone.
    assert [line for line in owned["[script]"] if assertion_command(line)] == [
        f"chformal -assert -remove t:$check r:FLAVOR=assert %i {lemmas} %u %u %d",
        "select -assert-count 17 t:$check r:FLAVOR=assert %i",
    ]
    proof_commands = [line for line in proof["[script]"] if assertion_command(line)]
    assert (
        f"select -assert-count 17 t:$check r:FLAVOR=assert %i {lemmas} %u %u %i"
        in proof_commands
    )
    assert f"chformal -assert2assume {lemmas}" in proof_commands
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
        "prep -flatten -top coherence_l1d",
        "select -assert-count 1 c:p_prefetch_conflict_split t:$check %i r:FLAVOR=assert %i",
        "chformal -assert2assume c:p_prefetch_conflict_split",
    ]
    script += ["select -assert-count 328 t:$check r:FLAVOR=assert %i"]
    if outlier or hold:
        if hold:
            script += [
                "select -assert-count 4 c:p_grant_mux_exact c:p_local_image_stable "
                "c:p_load_payload_held c:p_reply_hold"
            ]
        script += [
            "chformal -assert -remove t:$check r:FLAVOR=assert %i "
            "c:p_grant_mux_exact c:p_local_image_stable c:p_load_payload_held "
            "c:p_reply_hold %u %u %u %d",
            "select -assert-count 4 t:$check r:FLAVOR=assert %i",
        ]
    else:
        script += [
            "chformal -assert -remove c:p_grant_mux_exact c:p_local_image_stable "
            "c:p_load_payload_held c:p_reply_hold",
            "select -assert-count 324 t:$check r:FLAVOR=assert %i",
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


class FormalRunner:
    """Run SymbiYosys tasks from the repository's formal/ directory."""

    def __init__(self) -> None:
        """Initialize runner with paths."""
        self.test_dir = Path(__file__).parent.resolve()
        self.root_dir = self.test_dir.parent
        self.formal_dir = self.root_dir / FORMAL_DIR

        if not self.formal_dir.exists():
            raise FileNotFoundError(f"Formal directory not found: {self.formal_dir}")

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

        cmd = ["sby", "-t", "-f", str(sby_path), task]
        if replay := sby_config.cmo_replay_helper(sby_path, task):
            cmd = [
                sys.executable,
                str(replay),
                str(sby_path),
                task,
                str(formal_task_timeout_s(target.name, task)),
            ]

        check_fatal_frame = target.name == "coherence_store_boundary" and task in (
            "bmc_amo_same_fatal",
            "bmc_amo_other_fatal",
        )
        if capture_output or check_fatal_frame:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                cwd=self.formal_dir,
                timeout=formal_task_timeout_s(target.name, task),
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
            return result
        else:
            return subprocess.run(
                cmd,
                cwd=self.formal_dir,
                timeout=formal_task_timeout_s(target.name, task),
                text=True,
            )

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


@pytest.mark.parametrize("capture_output", (False, True))
@pytest.mark.parametrize("task", ("bmc_amo_same_fatal", "bmc_amo_other_fatal"))
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
        ("coherent_hart_cache", "coh_hart_maint_four_bmc", 7200),
        ("coherence_l1d", "coh_l1d_stream_bmc", 5100),
        ("coherence_l1d", "coh_l1d_stream_free_nostore_bmc", 3600),
        ("coherence_l1d", "coh_l1d_stream_outlier_prove", 2400),
        ("coherence_l1d", "coh_l1d_stream_hold_bmc", 3600),
        ("coherence_l1d", "coh_l1d_stream_free_nostore_hold_bmc", 3600),
        ("coherence_l1d", "coh_l1d_bmc", 10800),
        ("coherence_store_boundary", "bmc_four", 18000),
        ("coherence_store_boundary", "bmc_intervening", 14400),
        ("coherence_store_boundary", "bmc_amo_same", 3300),
        ("coherence_store_boundary", "bmc_amo_other", 4800),
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
        ("coherence_home_twin", "home_twin_four", 600),
        ("coherence_home_twin", "home_twin_addr40", 600),
        ("coherence_l1d", "coh_l1d_stream_free_bmc", 10800),
        ("coherence_l1d", "coh_l1d_multi_bmc", 18000),
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
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(subprocess, "run", run)
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
        except Exception as e:
            pytest.fail(
                f"Unexpected error during formal {task_name} for {target.name}: {e}"
            )


# ===========================================================================
# Command-line interface for standalone execution
# ===========================================================================


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

    args = parser.parse_args()

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
