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
# The unchanged ROB BMC can take about an hour on a shared runner.
# These tasks run in separate CI jobs. Their proof depth and input contracts
# stay unchanged; only the solver's wall-clock allowance differs.
SBY_TASK_TIMEOUT_OVERRIDES_S = {
    ("csr_file", "bmc"): 5400,
    ("csr_file", "bmc_perf_off"): 5400,
    ("reorder_buffer", "bmc"): 5400,
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
        "coherent_l0.sby",
        "Coherent L0 valid masks, data, and invalidation at two cache depths.",
        tasks=(
            "coh_l0_flags_prove",
            "coh_l0_flags256_prove",
            "coh_l0_bmc",
            "coh_l0256_bmc",
            "coh_l0_cover",
            "coh_l0256_cover",
        ),
    ),
    FormalTarget(
        "coherent_cpu.sby",
        "Coherent SC ownership, load selection, parking, and reservation cuts.",
        tasks=(
            "coh_sc_selected_prove",
            "coh_lq_cut_prove",
            "coh_lq_forward_prove",
            "coh_lq_normal_fill_prove",
            "coh_address_class_prove",
            "coh_candidate_select_prove",
            "coh_lq_selector_prove",
            "coh_lq_selector4_prove",
            "coh_lq_selector16_prove",
        ),
    ),
    FormalTarget(
        "coherence_l1d.sby",
        "The coherent L1 preserves pending stores, cuts, and exact atomic writes.",
        tasks=("coh_l1d_bmc",),
    ),
    FormalTarget(
        "coherence_home.sby",
        "The coherent home preserves pins, dirty replies, and victim ownership.",
        tasks=(
            "coh_home_bmc",
            "coh_home_wb_prove",
            "coh_home_victim_cover",
            "coh_home_error_cover",
        ),
    ),
    FormalTarget(
        "coherence_array.sby",
        "A watched byte preserves masked updates across serialized array operations.",
        tasks=("coh_array_bmc", "coh_array_uram_bmc"),
    ),
    FormalTarget(
        "coherence_control.sby",
        "Coherent request arbitration, bridge lifetime, and atomic protection.",
        tasks=(
            "coh_arbiter_prove",
            "coh_reader_prove",
            "coh_ingress_prove",
            "coh_atomic_guard_prove",
            "coh_read_flags_prove",
            "coh_read_select_prove",
            "coh_read_select64_prove",
        ),
    ),
    FormalTarget(
        "coherence_endpoints.sby",
        "Coherent endpoint payloads, identities and cancellation lifetimes",
        tasks=(
            "request_prove",
            "request_cover",
            "home_prove",
            "home_cover",
            "put_prove",
            "put_cover",
            "channel_prove",
            "channel_cover",
            "home_wide",
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
        "Store-queue committed-empty state matches the reference through reset, flush, "
        "and commit",
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
        tasks=("bmc", "bmc_forward", "bmc_forward_only", "cover"),
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
        "Page-table walk state matches reference PTE classification",
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
        "Divider arithmetic at 8 bits and step-count/remainder bounds at 64 bits",
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
        "the coherent ingress's request rules, unbounded on narrow, line-wide and "
        "soc_top buses",
        tasks=("prove", "prove_full_width", "prove_soc", "cover"),
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
        "registered PC relations",
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
        "FIFO capacity, flow control, and data ordering across unrelated clocks",
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

]

# SymbiYosys task types (for CLI --task filter and pytest parametrize)
SBY_TASKS = [
    ("coh_l0_flags_prove", "Coherent L0 next-state equality at 128 entries."),
    ("coh_l0_flags256_prove", "Coherent L0 next-state equality at 256 entries."),
    ("coh_l0_bmc", "Coherent L0 data and invalidation at 128 entries."),
    ("coh_l0256_bmc", "Coherent L0 data and invalidation at 256 entries."),
    ("coh_l0_cover", "Coherent L0 hit and invalidation covers at 128 entries."),
    ("coh_l0256_cover", "Coherent L0 hit and invalidation covers at 256 entries."),
    (
        "coh_sc_selected_prove",
        "Selected SC payload survives flushes through its result.",
    ),
    (
        "coh_lq_cut_prove",
        "Coherent cuts block load completion and reservation renewal.",
    ),
    ("coh_lq_forward_prove", "Coherent forwarding obeys cuts and same-sector holds."),
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
    ("coh_l1d_bmc", "Coherent L1 pending ownership and independent probes."),
    ("coh_home_wb_prove", "Detached victim ownership through successful B."),
    ("coh_home_victim_cover", "Victim allocation, delayed B, and blocked refetch."),
    ("coh_home_error_cover", "Failed B preserves dirty victim ownership."),
    ("coh_home_bmc", "Coherent home completion, merge, and victim locks."),
    ("coh_array_bmc", "Coherent array byte values and held responses."),
    ("coh_array_uram_bmc", "Coherent array byte values through registered RAM ports."),
    ("coh_arbiter_prove", "Coherent arbitration preserves held payloads."),
    ("coh_reader_prove", "Read identities survive through release."),
    ("coh_ingress_prove", "DMA identities survive through release."),
    ("coh_atomic_guard_prove", "Atomic protection covers retirement and release."),
    ("layout32", "Coherent channel layout at 32 physical address bits"),
    ("layout56", "Coherent channel layout at 56 physical address bits"),
    ("request_prove", "Unbounded coherent endpoint safety"),
    ("request_cover", "Coherent endpoint completion reachability"),
    ("home_prove", "Unbounded coherent endpoint safety"),
    ("home_cover", "Coherent endpoint completion reachability"),
    ("put_prove", "Unbounded coherent endpoint safety"),
    ("put_cover", "Coherent endpoint completion reachability"),
    ("channel_prove", "Unbounded coherent endpoint safety"),
    ("channel_cover", "Coherent endpoint completion reachability"),
    ("home_wide", "Coherent home safety with wide physical addresses"),
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
    ("prove_soc", "Unbounded proof in soc_top's configuration"),
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
    ("bmc_itlb", "Bounded model checking in the 8-entry 2-port ITLB shape"),
    ("cover_itlb", "Cover checking in the 8-entry 2-port ITLB shape"),
    ("bmc_xlen32", "Bounded checking with a local 32-bit datapath"),
    (
        "bmc_small_btb",
        "Bounded tag comparison with a 16-entry BTB and partial final group",
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
]


def test_formal_target_tasks_are_registered() -> None:
    """Every declared task must participate in CLI and pytest execution."""
    registered = {name for name, _ in SBY_TASKS}
    missing = {
        target.name: sorted(set(target.tasks) - registered)
        for target in FORMAL_TARGETS
        if set(target.tasks) - registered
    }
    assert not missing, f"Formal tasks would be silently skipped: {missing}"


def formal_task_timeout_s(target: str, task: str) -> int:
    """Return the wall-clock backstop for a target's task."""
    return SBY_TASK_TIMEOUT_OVERRIDES_S.get((target, task), SBY_TASK_TIMEOUT_S)


def timeout_log_tail(error: subprocess.TimeoutExpired) -> str:
    """Keep recent solver progress when a captured run exceeds its backstop."""
    output = "".join(
        part.decode(errors="replace") if isinstance(part, bytes) else part or ""
        for part in (error.stdout, error.stderr)
    )
    return "\n".join(output.splitlines()[-40:])


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
            capture_output: If True, capture stdout/stderr. If False, stream to console.

        Returns:
            CompletedProcess with results.
        """
        sby_path = self.formal_dir / target.sby_file
        if not sby_path.exists():
            raise FileNotFoundError(f"SBY file not found: {sby_path}")

        cmd = ["sby", "-t", "-f", str(sby_path), task]

        if capture_output:
            return subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                cwd=self.formal_dir,
                timeout=formal_task_timeout_s(target.name, task),
            )
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
@pytest.mark.parametrize(
    "target_name,task,expected_timeout",
    (
        ("csr_file", "bmc", 5400),
        ("csr_file", "bmc_perf_off", 5400),
        ("reorder_buffer", "bmc", 5400),
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
    """CLI and captured runs give only the slow BMC tasks extra wall time."""
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

    targets = FORMAL_TARGETS
    if args.target:
        targets = [t for t in FORMAL_TARGETS if t.name == args.target]

    tasks = SBY_TASKS
    if args.task:
        tasks = [(n, d) for n, d in SBY_TASKS if n == args.task]

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
