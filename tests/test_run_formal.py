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

import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

# Path to the formal/ directory relative to the repository root
FORMAL_DIR = "formal"

# Per-task hang backstop in seconds; proof depth is set by each .sby file.
SBY_TASK_TIMEOUT_S = 2400
# Slow control, data and composed tasks have measured allowances in their
# SBY files and separate CI jobs. Keep the runner's backstops in sync with
# those files and document the budgets and depths in formal/README.md.
SBY_TASK_TIMEOUT_OVERRIDES_S = {
    ("csr_file", "bmc"): 5400,
    ("csr_file", "bmc_perf_off"): 5400,
    ("reorder_buffer", "bmc"): 5400,
    ("coherent_hart_cache", "coh_hart_maint_prove"): 7200,
    ("coherent_hart_cache", "coh_hart_maint_owned_prove"): 1200,
    ("coherent_hart_cache", "coh_hart_maint_four_bmc"): 7200,
    ("coherence_l1d", "coh_l1d_stream_bmc"): 3600,
    ("coherence_l1d", "coh_l1d_stream_hold_bmc"): 3600,
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
    ("coherence_store_boundary", "bmc_four"): 18000,
    ("coherence_store_boundary", "cover_four"): 7200,
    ("coherence_store_boundary", "bmc_intervening"): 14400,
    ("coherence_store_boundary", "bmc_amo_same"): 3300,
    ("coherence_store_boundary", "bmc_amo_other"): 4800,
    ("coherence_store_boundary", "bmc_sc"): 3600,
    ("coherence_store_home", "bmc_siblings"): 1800,
    ("coherence_store_home", "bmc_rows"): 2100,
    ("coherence_store_home", "bmc_conflict"): 2400,
    ("coherence_store_home", "bmc_pressure"): 2700,
    ("coherence_store_home", "link_bmc_siblings"): 2700,
    ("coherence_store_home", "link_bmc_pressure"): 3600,
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
            "bmc_rows",
            "bmc_conflict",
            "cover_siblings",
            "cover_rows",
            "cover_conflict",
            "bmc_pressure",
            "cover_pressure",
            "link_bmc_siblings",
            "link_bmc_pressure",
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
            "cover_amo_other_home",
            "cover_sc",
            "cover_edges_same",
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
        "Coherent SC ownership, load selection, parking, and reservation cuts.",
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
        ),
    ),
    FormalTarget(
        "coherence_home_select.sby",
        "Seat admission and circular work selection match serial priority.",
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
            "coh_home_wb_prove",
            "coh_home_victim_cover",
            "coh_home_error_cover",
            "coh_home_prefetch_cover",
        ),
    ),
    FormalTarget(
        "coherence_dma_ingress.sby",
        "DMA issue order, opaque identities, independent completion, and reset ownership.",
        tasks=(
            "coh_dma_ingress_prove",
            "coh_dma_ingress_cover",
            "coh_dma_ingress_soc_prove",
            "coh_dma_ingress_soc_cover",
        ),
    ),
    FormalTarget(
        "coherence_home_engine.sby",
        "Resident image merges, independent probe/data arrival, and held service payloads.",
        tasks=(
            "coh_home_engine_prove",
            "coh_home_engine64_prove",
            "coh_home_engine_cover",
        ),
    ),
    FormalTarget(
        "coherence_home_array.sby",
        "Independent L2 ports preserve byte values, tokens and physical-row exclusions.",
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
        "Store-queue live counts match reference allocation arithmetic",
        tasks=("bmc",),
    ),
    FormalTarget(
        "sq_committed_empty.sby",
        "Store-queue committed-empty state matches the reference through flush and commit",
        tasks=("bmc",),
    ),
    FormalTarget(
        "pc_pending_capture.sby",
        "Pending-prediction capture matches reference clear/set/hold priority",
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
        "contract",
        tasks=("prove", "prove_integrated", "prove_perf_off"),
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
        "RV64C predecode expansion matches the reference decoder for every parcel",
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
        "overrides",
        tasks=("bmc",),
    ),
    FormalTarget(
        "decoded_bundle_queue.sby",
        "Decoded bundles preserve FIFO order through bypass, backpressure, flush, and "
        "wraparound",
        tasks=("prove", "prove_depth2", "cover"),
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
        "Trap-unit exception and interrupt handling, and the CSR entry enables in "
        "every state",
        tasks=("bmc", "cover", "prove"),
    ),
    FormalTarget(
        "csr_file.sby",
        "CSR state and access behavior with profiling counters on or off",
        tasks=("bmc", "cover", "bmc_perf_off"),
    ),
    FormalTarget(
        "tlb.sby",
        "TLB entry tracking and lookup selection in DTLB and ITLB configurations",
        tasks=("bmc", "cover", "bmc_itlb", "cover_itlb"),
    ),
    FormalTarget(
        "ptw.sby",
        "Page-table walk state matches reference PTE classification, and the walk "
        "cache holds only valid pointers that memory holds, cleared by every discard",
        tasks=("bmc", "cover", "bmc_nopwc", "bmc_replace"),
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
        "alu_shift_hint.sby",
        "ALU shifts and rotates match the reference with captured shift amounts on or "
        "off",
        tasks=("bmc",),
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
        "buses with up to eight bursts and eight line IDs per direction",
        tasks=(
            "prove",
            "prove_full_width",
            "prove_soc",
            "prove_soc8_0",
            "prove_soc8_1",
            "prove_soc8_2",
            "prove_soc8_3",
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
        tasks=("prove", "prove_soc", "cover"),
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
        "entries, at two and four ways",
        tasks=("bmc", "bmc_four_way", "prove", "prove_four_way", "cover"),
    ),
    FormalTarget(
        "pd_backing_redirect.sby",
        "Backing BTB redirects fire for their slot's jump with its vetoes clear, "
        "stack operations and refreshes follow them, and the redirect targets "
        "match PD's reference models",
        tasks=("bmc", "cover"),
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
        "registered PC relations, and the instruction buffer takes only pc_reg's word",
        tasks=("bmc", "cover", "prove"),
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
        "coherence_l1d_twin.sby",
        "L1D: primitive and portable forms are equivalent.",
        tasks=(
            "l1d_twin_single",
            "l1d_twin_multi",
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
        tasks=("immu_twin",),
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
        "CSR file: primitive and portable forms are equivalent.",
        tasks=("csr_twin",),
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
        tasks=("sq_twin",),
    ),
    FormalTarget(
        "reservation_station_twin.sby",
        "Reservation station: primitive and portable forms are equivalent.",
        tasks=("rs_twin_indexed",),
    ),
]

# SymbiYosys task types (for CLI --task filter and pytest parametrize)
SBY_TASKS = [
    ("link_zero_prove", "A link with no stages is wires."),
    ("link_always1_prove", "Always-taken link, one stage: order, payload and latency."),
    (
        "link_always2_prove",
        "Always-taken link, two stages: order, payload and latency.",
    ),
    (
        "link_credit1_bmc",
        "Credit link, one stage, three credits: order, payload and credit count, 40 frames.",
    ),
    (
        "link_credit2_bmc",
        "Credit link, two stages, five credits: order, payload and credit count, 40 frames.",
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
        "Production L1D and home through one-stage links preserve sibling-sector bytes.",
    ),
    (
        "link_bmc_pressure",
        "One-stage links under two dirty victims, delayed releases and a probing DMA read.",
    ),
    ("link_cover_pressure", "The pressure schedule completes through one-stage links."),
    ("limit_bmc", "Bounded proof that the runtime occupancy limit caps the writer."),
    ("limit_cover", "The writer stalls at a runtime limit below the RAM's capacity."),
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
    ("bmc_siblings", "Real-home sibling store byte safety."),
    ("bmc_rows", "Real-home distinct-row store byte safety."),
    ("bmc_conflict", "Real-home conflicting-row store byte safety."),
    ("cover_siblings", "Sibling acquisitions complete and supply DMA data."),
    (
        "cover_rows",
        "Distinct-row concurrent acquisitions complete and supply DMA data.",
    ),
    ("cover_conflict", "A same-set conflict serializes and supplies DMA data."),
    (
        "bmc_pressure",
        "Real-home stores and load data survive held writebacks and releases.",
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
    ("cover_amo_other_home", "Different-sector AMO home write lookup and release."),
    ("cover_sc", "SC retirement, delayed release and younger-store admission."),
    (
        "cover_edges_same",
        "Load staging at capture, acknowledgement, promotion and drain of same-sector stores.",
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
    ("coh_read_payload_prove", "Coherent read payload storage at 32 address bits."),
    ("coh_read_payload64_prove", "Coherent read payload storage at 64 address bits."),
    ("bmc_core", "Load-result selection with the CPU feature configuration."),
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
        "Ready work and circular priority match serial selection, last pick coded.",
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
    ("prove_perf_off", "Unbounded proof with profiling counters absent"),
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
    ("prove_full_width", "Unbounded proof with a bus as wide as a line"),
    (
        "prove_soc",
        "Unbounded proof at SoC bus widths; AXI bridge uses four bursts and IDs per direction",
    ),
    ("bmc_soc", "Bounded check with SoC burst and line-ID capacities"),
    (
        "prove_soc8_0",
        "Eight-burst AXI bridge safety, assertion partition 0 of four",
    ),
    (
        "prove_soc8_1",
        "Eight-burst AXI bridge safety, assertion partition 1 of four",
    ),
    (
        "prove_soc8_2",
        "Eight-burst AXI bridge safety, assertion partition 2 of four",
    ),
    (
        "prove_soc8_3",
        "Eight-burst AXI bridge safety, assertion partition 3 of four",
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
    ("bmc", "Check assertions up to the configured depth"),
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
    ("bmc_nopwc", "Bounded checking of the page-table walker without its walk cache"),
    ("bmc_replace", "Bounded checking through replacement in one-entry walk caches"),
    ("bmc_xlen32", "Bounded checking with a local 32-bit datapath"),
    (
        "bmc_small_btb",
        "Bounded tag comparison with a 16-entry BTB and partial final group",
    ),
    ("bmc_btb_index1", "Bounded relation checking with one BTB index bit"),
    ("bmc_btb_index3", "Bounded relation checking with three BTB index bits"),
    ("bmc_four_way", "Bounded checking with four ways"),
    ("prove_four_way", "Unbounded safety checking with four ways"),
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
        "rs_twin_indexed",
        "Indexed-write reservation station primitive form equals its portable form.",
    ),
]


def test_formal_target_tasks_are_registered() -> None:
    """Every SBY file and task must participate in CLI and pytest execution."""
    formal_dir = Path(__file__).resolve().parents[1] / FORMAL_DIR
    files = [target.sby_file for target in FORMAL_TARGETS]
    assert len(files) == len(set(files)), "Duplicate formal target registration"
    assert set(files) == {path.name for path in formal_dir.glob("*.sby")}
    for target in FORMAL_TARGETS:
        text = (formal_dir / target.sby_file).read_text()
        section = text.split("[tasks]", 1)[1].split("[", 1)[0]
        declared = [
            line.split()[0]
            for raw in section.splitlines()
            if (line := raw.split("#", 1)[0].strip())
        ]
        assert len(declared) == len(set(declared)), target.name
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


def test_atomic_proof_pairs_and_formal_shards() -> None:
    """Require proof dependencies and one CI shard for every formal case."""
    import yaml  # type: ignore[import-untyped]
    from _pytest.mark.expression import Expression

    root = Path(__file__).resolve().parents[1]
    registered = [name for name, _ in SBY_TASKS]
    required = {
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
        task_text = (root / "formal" / target.sby_file).read_text()
        task_lines = task_text.split("[tasks]", 1)[1].split("[options]", 1)[0]
        sby_tasks = [
            line.split()[0] for line in task_lines.splitlines() if line.strip()
        ]
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
        "coherence_l1d_coh_l1d_local_data_bmc": "Coherence L1D local data",
        "coherence_l1d_coh_l1d_local_hold_bmc": "Coherence L1D local holds",
        "coherence_l1d_coh_l1d_local_control_bmc": "Coherence L1D local control",
        "coherence_store_boundary_bmc_four": "Store boundary four records",
        "coherence_store_boundary_bmc_intervening": "Store boundary intervening load",
        "coherence_store_boundary_bmc_amo_same": "Store boundary AMO flow",
        "coherence_store_boundary_bmc_amo_other": "Store boundary AMO flow",
        "coherence_store_boundary_bmc_sc": "Store boundary",
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
        for test_id, shard in dedicated_shards.items():
            if node.endswith(f"[{test_id}]"):
                assert matches == [shard], (node, matches)
        if any(f"[coherence_l1d_{prefix}" in node for prefix in data_prefixes):
            assert matches[0].startswith("Coherence L1D data"), (node, matches)


def formal_task_config(target: str, task: str) -> dict[str, list[str]]:
    """Return an SBY task's resolved sections, without comments."""
    result = subprocess.run(
        ["sby", "--dumpcfg", f"{target}.sby", task],
        cwd=Path(__file__).resolve().parents[1] / "formal",
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )
    sections: dict[str, list[str]] = {}
    section = ""
    for raw in result.stdout.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            section = line
            sections[section] = []
        else:
            sections[section].append(line)
    return sections


def l1d_task_config(task: str) -> dict[str, list[str]]:
    """Return a coherence_l1d.sby task's resolved sections, without comments."""
    return formal_task_config("coherence_l1d", task)


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
        assert payload_options == control_options | {"timeout": "1200"}
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
    for suffix, depth, timeout, engine in (
        ("bmc", "40", "10800", "abc bmc3"),
        ("multi_bmc", "30", "18000", "abc bmc3 -c"),
        ("payload_bmc", "40", "1200", "abc bmc3 -c"),
    ):
        payload = suffix == "payload_bmc"
        define = " -D STORE_DATA_PROOF" if payload else ""
        endpoints = " -set MISSES 3" if suffix == "multi_bmc" else ""
        script = (
            reads
            + [
                f"read -formal -sv -D ZERO_WRITES{define} coherence_read_payload.sv coherence_l1d.sv",
                "read -sv coherence_store_buffer.sv",
                "read -sv sdp_block_ram.sv sdp_packed_tag_uram.sv sdp_ram_byte_en.sv coherence_array.sv",
                f"chparam -set CACHE_BYTES 64 -set WAYS 1 -set TAG_BITS 2{endpoints} coherence_l1d",
                "prep -flatten -top coherence_l1d",
            ]
            + (payload_properties if payload else control_properties)
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
            ("[script]", "delete -input w:i_rst"),
            ("[script]", "cutpoint w:phase_q"),
            ("[script]", "chformal -assume -remove"),
            ("[script]", "chformal -assert2assume c:p_zero_twin_install"),
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
            "timeout": "2400",
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
            "select -assert-count 326 t:$check r:FLAVOR=assert %i",
            f"select -assert-count 4 {holds}",
            f"chformal -assert -remove t:$check r:FLAVOR=assert %i {holds} %u %u %u %d",
            "select -assert-count 4 t:$check r:FLAVOR=assert %i",
        ],
        "bmc": common
        + [
            "select -assert-count 326 t:$check r:FLAVOR=assert %i",
            f"chformal -assert -remove {holds}",
            "select -assert-count 322 t:$check r:FLAVOR=assert %i",
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
            assert options == {
                "mode": "bmc",
                "depth": str(depth),
                "timeout": "3600",
                "aigsmt": "boolector",
                "expect": "PASS",
            }
            assert task["[engines]"] == [
                "abc bmc3 -c" if role == "hold" else "abc bmc3"
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
        "chparam -set ZERO_LINE 0 coherence_l1d",
        "prep -flatten -top coherence_l1d",
        "select -assert-count 1 c:p_prefetch_conflict_split t:$check %i r:FLAVOR=assert %i",
        "chformal -assert2assume c:p_prefetch_conflict_split",
    ]
    script += ["select -assert-count 326 t:$check r:FLAVOR=assert %i"]
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
            "select -assert-count 322 t:$check r:FLAVOR=assert %i",
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
        assert options == {
            "mode": "prove" if outlier else "bmc",
            "depth": depth,
            "timeout": "2400" if outlier else "10800" if bulk else "3600",
            "aigsmt": "boolector",
            "expect": "PASS",
        }
        assert config["[engines]"] == [
            "abc pdr" if outlier else "abc bmc3 -c" if hold else "abc bmc3"
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
        "select -assert-count 372 t:$check r:FLAVOR=assert %i",
    ]
    lemmas = (
        "c:*p_maint_owned_* c:p_maint_data_* c:*p_maint_ledger_* "
        "c:*p_maint_seq_* c:*p_maint_if_* c:*p_maint_ppn_* "
        "c:*p_maint_fact_* c:*p_maint_ptw_*"
    )
    covers = "chformal -cover -remove"
    owned_commands = common + [
        f"chformal -assert -remove t:$check r:FLAVOR=assert %i {lemmas} %u %u %u %u %u %u %u %d",
        "select -assert-count 284 t:$check r:FLAVOR=assert %i",
        covers,
    ]
    proof_commands = common + [
        f"select -assert-count 284 t:$check r:FLAVOR=assert %i {lemmas} %u %u %u %u %u %u %u %i",
        f"chformal -assert2assume {lemmas}",
        "select -assert-count 284 t:$check r:FLAVOR=assume %i",
        "select -assert-count 88 t:$check r:FLAVOR=assert %i",
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


def timeout_log_tail(error: subprocess.TimeoutExpired) -> str:
    """Keep recent solver progress when a captured run exceeds its backstop."""
    output = "".join(
        part.decode(errors="replace") if isinstance(part, bytes) else part or ""
        for part in (error.stdout, error.stderr)
    )
    return "\n".join(output.splitlines()[-40:])


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
        ("coherence_l1d", "coh_l1d_stream_bmc", 3600),
        ("coherence_l1d", "coh_l1d_stream_free_nostore_bmc", 3600),
        ("coherence_l1d", "coh_l1d_stream_outlier_prove", 2400),
        ("coherence_l1d", "coh_l1d_stream_hold_bmc", 3600),
        ("coherence_l1d", "coh_l1d_stream_free_nostore_hold_bmc", 3600),
        ("coherence_l1d", "coh_l1d_bmc", 10800),
        ("coherence_store_boundary", "bmc_four", 18000),
        ("coherence_store_boundary", "bmc_intervening", 14400),
        ("coherence_store_boundary", "bmc_amo_same", 3300),
        ("coherence_store_boundary", "bmc_amo_other", 4800),
        ("coherence_store_boundary", "bmc_sc", 3600),
        ("coherence_store_home", "bmc_siblings", 1800),
        ("coherence_store_home", "bmc_rows", 2100),
        ("coherence_store_home", "bmc_conflict", 2400),
        ("coherence_store_home", "bmc_pressure", 2700),
        ("coherence_store_home", "cover_siblings", 2400),
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

        with capsys.disabled():
            print(f"\nRunning formal {task_name}: {target.description}...")

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
