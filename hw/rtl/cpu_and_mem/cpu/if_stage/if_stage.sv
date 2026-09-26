/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/*
 * Instruction fetch (IF), the first front-end stage. It cuts up to two
 * instructions per cycle from a 64-bit fetch window. pc_controller keeps the
 * fetch PC (o_pc) and the PC of the emitted packet (pc_reg); branch_prediction
 * holds the BTB, direction predictor, RAS, and prediction metadata;
 * c_extension aligns parcels and keeps the instruction buffer; mmu/immu
 * translates o_pc into the physical addresses of the window's two words.
 *
 * IF needs no RVC decompressor: the predecode sideband carries each parcel's
 * RV64C expansion. PD forms slot 1's instruction from the fields IF passes
 * it; slot 2 is built here from fixed candidates before its position mux.
 * Misprediction redirects, BTB training, and RAS restores arrive on
 * i_from_ex_comb. IF captures its packet when a pipeline stall begins and, if
 * it was a real instruction, replays it on release, because the fetch window
 * moves on during the stall.
 */
module if_stage #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input riscv_pkg::from_ex_comb_t i_from_ex_comb,
    // Early-recovery branch PC and outcome, taken directly from early recovery
    // rather than through the BTB-update priority mux, so the BTB can compute
    // the early counter read-modify-write in parallel. i_from_ex_comb is still
    // the only BTB write and carries the update-source priority.
    input logic i_btb_early_update_active,
    input logic [XLEN-1:0] i_btb_early_update_pc,
    input logic i_btb_early_update_taken,
    // Counter read-modify-write candidate for the lower-priority update
    // sources, selected without the early-recovery term. It never decides
    // whether a BTB write happens.
    input logic [XLEN-1:0] i_btb_late_update_pc,
    input logic i_btb_late_update_taken,
    input logic [63:0] i_instr,  // 64-bit fetch: {next_word, current_word}
    input logic [riscv_pkg::ImemFetchSidebandWidth-1:0] i_instr_sideband,
    // Replica of the size and pairing predecode bits, per fetched word, ordered
    // {pairable_native_hi, pairable_compressed_hi, compressed_hi, compressed_lo}.
    // Only a simulation check reads it here; the aligner uses the per-provider
    // replicas below.
    input logic [7:0] i_instr_pc_metadata,
    // Raw timing replicas in {cached odd, cached even, BRAM odd, BRAM even}
    // provider/parity order.  The aligner selects the active lane directly.
    input logic [15:0] i_instr_pc_metadata_by_provider_parity,
    input logic [7:0] i_pc_pairability_by_provider_parity,
    input logic [3:0] i_slot2_start_valid_lo_by_provider_parity,
    input logic i_instr_pc_metadata_served_high,
    input logic i_instr_bank_sel_r,  // Fetch-word parity (PC[2] from fetch cycle)
    // Each provider's word tag for its served window, S = the window's fetch
    // PC bits [31:2]. S+1, S-1, and S != 0 are registered beside S, so the
    // served-window check has no address arithmetic or provider mux ahead of
    // its compares.
    input logic [29:0] i_served_word_low,
    input logic [29:0] i_served_last_word_low,
    input logic [29:0] i_served_prev_word_low,
    input logic i_served_prev_word_valid_low,
    input logic [29:0] i_served_word_high,
    input logic [29:0] i_served_last_word_high,
    input logic [29:0] i_served_prev_word_high,
    input logic i_served_prev_word_valid_high,
    // Fetch window valid: {i_instr, i_instr_sideband, i_instr_pc_metadata,
    // i_instr_bank_sel_r} hold the window for the fetch address presented
    // last cycle. While it is low (an L1I miss, a two-cycle
    // low-BRAM fetch outside the predecode overlay, or FETCH_VALID_FUZZ gaps)
    // and no stall-captured packet is being replayed, IF emits NOP bubbles,
    // its PCs and per-packet state hold, and the provider keeps working on the
    // owed fetch address. Backend redirects still land.
    input logic i_instr_valid,
    // Fetch-fault status of the served window's two words, {fault, page} per
    // word (page: a page fault rather than an access fault), registered with
    // the payload like i_instr_bank_sel_r. Used only while i_instr_valid is
    // high.
    input logic i_instr_fault0,
    input logic i_instr_fault0_page,
    input logic i_instr_fault1,
    input logic i_instr_fault1_page,
    // The served window came from the cached-tier provider (which withholds
    // valid across stalls) rather than the low BRAM. Only simulation checks
    // read it; the logic uses its registered replica,
    // i_instr_pc_metadata_served_high.
    input logic i_served_high,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::trap_ctrl_t i_trap_ctrl,
    // Front-end state flush. The producer guarantees it covers every
    // i_fence_i_flush pulse as well as trap, xRET, and misprediction recovery.
    input logic i_frontend_state_flush,
    // The full-flush part of the flush above: the registered trap, xRET, or
    // FENCE-class pulse. See pc_control_sel_nop.
    input logic i_flush_all,
    // Registered FENCE-class front-end flush (FENCE.I, SFENCE.VMA, or a CSR
    // access that may change translation) and its refetch target.
    input logic i_fence_i_flush,
    input logic [XLEN-1:0] i_fence_i_target,
    // Blocks BTB, RAS, and slot-2 predictions.
    input logic i_disable_branch_prediction,
    // Bimodal direction-predictor training from commit (conditional branches
    // only), at the predict-time index the branch carried.
    input logic i_dir_update_valid,
    input logic [riscv_pkg::BpDirIdxBits-1:0] i_dir_update_idx,
    input logic i_dir_update_taken,
    // PD redirect: a bimodal-taken branch without a taken BTB or RAS
    // prediction (from pd_stage)
    input logic i_pd_redirect,
    input logic [XLEN-1:0] i_pd_redirect_target,
    output logic [XLEN-1:0] o_pc,
    // Registered: last cycle released a stall by consuming the stall-captured
    // packet, which needs no live window. The fetch provider uses this only
    // to classify the PC movement it sees as served rather than redirected,
    // and it does that a cycle later anyway, so registering the export keeps
    // the late stall logic out of the provider's ask and address paths. The
    // owed ask needs no correction: o_pc holds at it through any stall a
    // replayed packet can survive (redirects kill the captured packet).
    output logic o_fetch_replay_consume,
    // Combinational claim for a live provider response that IF either consumes
    // now or captures on the first backend-stall cycle. A squashed live window
    // is not claimed; replay consumes the saved packet instead.
    output logic o_fetch_live_claim,
    // Physical side of the fetch address; o_pc stays the virtual fetch
    // address. With translation off (Bare mode or M-mode) these are a
    // combinational function of o_pc and always valid. Under Sv39 they are a
    // tagged result for the registered o_pc, and valid drops, stalling the
    // front end, for one bubble after o_pc moves, possibly a second at a
    // 4 KiB page crossing, and through an ITLB miss.
    output logic [31:0] o_fetch_pa0,
    output logic [31:0] o_fetch_pa1,
    output logic o_fetch_pa_valid,
    output logic o_fetch_fault0,
    output logic o_fetch_fault0_page,
    output logic o_fetch_fault1,
    output logic o_fetch_fault1_page,
    output logic o_fetch_line_after_ok,
    // Registered pulse: the fetch PC loaded a nonsequential next-PC arm, so
    // the low-BRAM presenter's owed request is dead. A slot-1 prediction made
    // before its branch was emitted is the exception: the branch's window is
    // still owed and must arrive before the presenter requests the target.
    output logic o_fetch_redirect,
    // Registered retarget pulse for the cached-tier provider. fetch_provider
    // detects unaccepted PC movement itself and must not abandon an owed
    // branch just because a prediction ran the fetch PC ahead, so this pulse
    // covers only redirects that kill the old request: misprediction and PD
    // redirects, served-window resteers, taken slot-2 predictions, and slot-1
    // predictions emitted with their branch. It also fires on every trap,
    // xRET, and FENCE-class flush, since those can change translation or
    // cache state.
    output logic o_fetch_cached_retarget,
    // No translated result is visible yet for o_pc, so the front end must
    // stall (cpu_ooo folds this into pipeline_ctrl.stall).
    output logic o_fetch_pa_hold,
    // Translation state (csr_file, combinational) and the page-table walker
    // port.
    input logic i_fetch_translation_active,
    input logic i_fetch_priv_u,
    input logic i_tlb_invalidate,
    output logic o_walk_req_valid,
    input logic i_walk_req_ready,
    output logic [riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,
    input logic i_walk_resp_valid,
    input riscv_pkg::ptw_resp_t i_walk_resp,
    output riscv_pkg::from_if_to_pd_t o_from_if_to_pd,
    // Slot-2 IF→PD packet. When slot 2 is invalid this cycle (slot 1 is a NOP
    // or a branch, slot 2 does not fit, or another kill cause), sel_nop is
    // asserted and PD/ID propagate it as a NOP so dispatch sees i_valid_2='0.
    output riscv_pkg::from_if_to_pd_t o_from_if_to_pd_2,
    // Replay-aligned slot-1 control-flow classification. This reuses the
    // aligner's exact native/compressed predecode rather than decoding the raw
    // instruction-memory parcel again in frontend_validity_tracker.
    output logic o_slot1_has_control_flow,
    // Two-wide profiling events at the IF→PD boundary (perf counters only;
    // see if_width_events_t). Each pulses at most once per accepted handoff,
    // and the slot-2 kill causes follow stall replay. Registered one cycle
    // after the handoff so the perf taps cannot share logic with the slot-2
    // redirect and next-PC paths.
    output riscv_pkg::if_width_events_t o_width_events
);

  // ===========================================================================
  // Signal Declarations - Grouped by Submodule Interface
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // Branch Prediction Controller Interface (branch_prediction_controller)
  // ---------------------------------------------------------------------------
  logic [XLEN-1:0] btb_predicted_target;  // Combinational: Predicted target address
  // The BTB entry behind the target is typed as a call or a return.
  logic btb_predicted_is_call;
  logic btb_predicted_is_return;
  logic prediction_used_r;  // Registered: Prediction was applied
  logic [XLEN-1:0] btb_predicted_target_r;  // Registered: Target for pipeline alignment
  logic btb_predicted_is_call_r;  // Registered with the target
  logic btb_predicted_is_return_r;
  logic prediction_used;  // Current prediction being used
  logic prediction_used_for_pc;  // Stall-ungated PC mux select
  logic prediction_used_live_cofactor;  // prediction_used without the slot-2 alias gate
  logic prediction_holdoff;  // Block prediction (stale data)
  logic disable_branch_prediction_effective;  // i_disable_branch_prediction + IF-internal gates
  // The same with window_cannot_serve_pc_reg (WCS) forced to 0 and to 1.
  logic disable_branch_prediction_effective_wcs0;
  logic disable_branch_prediction_effective_wcs;
  logic sel_prediction_r;  // Select registered prediction target
  logic prediction_requires_pc_reg_handoff;  // Predicted op must still reach IF/PD/ID
  logic control_flow_to_halfword_pred;  // Prediction targets halfword address

  // Slot-2 prediction, plus the staged and live parts of its redirect that
  // pc_controller combines itself for timing.
  logic slot2_predicted_taken;
  logic [XLEN-1:0] slot2_predicted_target;
  logic slot2_prediction_used;
  logic slot2_prediction_used_for_pc;
  logic slot2_staged_prediction_used_for_pc;
  logic slot1_aliases_slot2_candidate;
  logic slot2_live_target_used_for_pc_cofactor;
  logic [XLEN-1:0] slot2_staged_predicted_target;
  logic [XLEN-1:0] slot2_live_predicted_target;
  logic slot2_predicted_is_call;
  logic slot2_predicted_is_return;

  // Return address stack: the registered top of stack and valid count, the
  // recovery point of the packet leaving IF now, and the push or pop for that
  // packet ("Return address stack" in the CPU README).
  logic [riscv_pkg::RasPtrBits-1:0] ras_checkpoint_tos;
  logic [riscv_pkg::RasPtrBits:0] ras_checkpoint_valid_count;
  logic ras_push;
  logic ras_pop;
  logic [XLEN-1:0] ras_push_address;
  // Types of the BTB entry behind each output packet's prediction, through the
  // same live, registered, pending, and stall-replay selection as its target.
  logic slot1_packet_is_call;
  logic slot1_packet_is_return;
  logic slot2_packet_is_call;
  logic slot2_packet_is_return;

  // Bimodal direction prediction, carried with each slot-1 instruction to PD
  // so PD can redirect a branch the BTB does not predict taken.
  logic bp_dir_taken;
  logic bp_dir_taken_live;
  logic bp_dir_taken_live_cofactor;
  // Predict-time bimodal index (slot 1 and slot 2), carried to commit so
  // training updates the entry the prediction read.
  logic [riscv_pkg::BpDirIdxBits-1:0] bp_dir_idx;
  logic [riscv_pkg::BpDirIdxBits-1:0] bp_dir_idx_live;
  logic [riscv_pkg::BpDirIdxBits-1:0] bp_dir_idx_2;

  // ---------------------------------------------------------------------------
  // PC Controller Interface (pc_controller)
  // ---------------------------------------------------------------------------
  logic [XLEN-1:0] pc;  // Current program counter (fetch address)
  logic [XLEN-1:0] pc_reg;  // PC of the packet IF emits (instruction address)
  logic control_flow_change;  // Branch/jump taken this cycle
  logic control_flow_holdoff;  // Wait cycle after control flow change
  logic control_flow_to_halfword;  // Target address is halfword-aligned
  logic control_flow_to_halfword_r;  // Registered version for timing
  logic reset_holdoff;  // Wait cycle after reset
  logic any_holdoff;  // Any holdoff condition active
  logic any_holdoff_safe;  // Safe holdoff (registered signals only)
  logic pending_prediction_active;  // A slot-1 prediction waits for pc_reg to reach its branch
  logic [XLEN-1:0] pending_prediction_pc;  // PC of the branch the prediction belongs to
  logic pending_prediction_target_handoff;  // Pending branch consumed; pc_reg moves to target
  logic pending_prediction_holdoff;  // Prediction disable for a pending prediction
  logic pending_prediction_holdoff_wcs0;  // ... with WCS forced to 0
  logic pending_prediction_holdoff_wcs;  // ... with WCS forced to 1
  logic pending_prediction_fetch_holdoff;  // Packet squash for a pending prediction
  logic pending_prediction_fetch_holdoff_wcs0;  // ... with WCS forced to 0
  logic pending_prediction_fetch_holdoff_wcs;  // ... with WCS forced to 1
  logic pending_prediction_target_holdoff;  // First target cycle still returns stale data
  logic pending_prediction_redirect_kill;  // Pending prediction dies without its handoff
  logic pc_update_en;  // Fetch-PC load enable; qualifies the low-presenter retarget
  // Used only to classify fetch retargets as sequential or not.
  logic [riscv_pkg::PcNextArms-1:0] npc_sel;
  logic [riscv_pkg::PcNextArms-1:0] npc_cond;
  logic [riscv_pkg::PcNextArms-1:0] npc_seq;
  // pc_controller's one-hot next-PC arm ordering; arm 8 is slot-1 prediction.
  localparam int unsigned PredictionNpcArm = 8;
  logic fetch_pa_valid;  // physical result for o_pc is visible
  logic fetch_fault0_live;  // o_pc's word-0 fetch fault

  // ---------------------------------------------------------------------------
  // C-Extension State Interface (c_ext_state)
  // ---------------------------------------------------------------------------
  logic [31:0] instr_buffer;  // Word kept for its upper parcel (see c_ext_state)
  logic prev_was_compressed_at_lo;  // Previous instr was compressed at addr[1]=0
  logic use_instr_buffer_for_coverage_timing;
  logic is_compressed_saved;  // Saved is_compressed for fast path
  logic saved_values_valid;  // Saved values are valid (not invalidated by control flow)
  logic [riscv_pkg::ImemSidebandWidth-1:0] instr_buffer_sideband;
  logic [1:0] instr_buffer_fault;  // {fault, page} captured with the buffered word
  // Fetch-fault status of the aligner's current and next word, mapped from
  // the served window's per-word flags; see "Fetch-fault tags" below.
  logic [1:0] cur_fault_pair;  // {fault, page} of the current word
  logic [1:0] next_fault_pair;  // {fault, page} of the next word

  // ---------------------------------------------------------------------------
  // Instruction Aligner Interface (instruction_aligner)
  // ---------------------------------------------------------------------------
  logic [15:0] raw_parcel;  // Slot-1 parcel: size bits, RAS detection, PD's reference
  logic [31:0] effective_instr;  // Raw current word (for state machine/buffer)
  logic is_compressed;  // Current instruction is 16-bit compressed
  logic is_compressed_fast;  // Fast path for PC-critical path (registered selects only)
  logic is_compressed_for_pc_advance;  // PC-selector-only timing-replica path
  // With no buffer in use, a window that ends at pc_reg's word can serve the
  // packet.
  logic no_buffer_accepts_served_last;
  logic sel_nop;  // Select NOP (during holdoff/flush)
  // fetch_progress gates holdoffs, sel_nop, and stall-held clock enables
  // across all of IF. Its inputs are registered, and the fanout cap makes
  // synthesis replicate the driver LUT per consumer region.
  (* max_fanout = 32 *)
  logic fetch_progress;  // live window valid OR replay bundle presented
  logic fetch_invalid_unstalled_q;  // last unstalled cycle had no live window
  logic lookup_lead_collapsed;  // first live window after such a gap
  logic sel_compressed;  // Select compressed instruction path
  logic use_instr_buffer;  // Use buffered instruction
  logic [2:0] rvc_source_hot;
  logic [4:0] rvc_bits24_20;
  logic [2:0] rvc_rs1_rest;
  logic [22:0] rvc_extra;

  // Slot-2 outputs from instruction_aligner (2-wide dispatch).
  logic [15:0] raw_parcel_2;
  logic [31:0] effective_instr_2;
  logic slot2_decomp_illegal;
  logic is_compressed_2;
  logic sel_nop_2_aligner;  // raw output from instruction_aligner
  logic sel_nop_2;  // effective: also NOP'd whenever slot-1 NOPs
  logic sel_compressed_2;
  logic [2:0] source_hot_2;
  logic [4:0] bits24_20_2;
  logic [2:0] rs1_rest_2;
  logic slot2_valid_for_pc_live;
  logic slot2_is_compressed_for_pc_live;
  logic slot2_is_compressed_plus2_for_btb;
  logic slot2_is_compressed_plus4_for_btb;
  logic slot2_plus2_candidate_valid;
  logic slot2_plus4_candidate_valid;
  logic pending_prediction_owns_live_slot1;
  logic pending_prediction_owns_live_slot2;
  logic pending_prediction_kills_live_slot2;
  logic [XLEN-1:0] pending_prediction_prev_pc;
  logic [XLEN-1:0] pending_prediction_prev_native_pc;
  logic fetch_lookup_is_lower_parcel;
  logic pc_reg_high_for_coverage;
  logic slot2_valid_for_pc_live_effective;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_advance_sel_base_live;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_advance_sel_run_live;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_fetch_advance_sel_live;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_fetch_advance_sel_saved;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_fetch_advance_sel;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_reg_advance_sel_live;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_reg_advance_sel_saved;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_reg_advance_sel;
  logic slot2_valid;  // matches the output slot-2 valid sent to PD/dispatch
  logic slot2_prediction_valid;  // live-only valid for the current staged slot-2 lookup
  logic slot2_redirect_q;  // One-cycle bubble after slot-2 BTB redirect.
  // Slot 2 must NOP whenever slot 1 NOPs. IF's full sel_nop covers
  // control_flow_holdoff, pending-prediction holdoffs, reset_holdoff, and
  // flush, all conditions where the live BRAM data may not match pc_reg's
  // word and the slot-2 alignment math is unreliable.
  //
  // A pending prediction's saved taken metadata belongs to one instruction,
  // the branch at pending_prediction_pc. The instruction just before it may be
  // released while the handoff is still pending, but only one-wide: if that
  // live bundle puts the branch in slot 2, slot 2 is killed and the branch
  // waits to be emitted as the next slot 1. Once the branch is in slot 1, its
  // slot-2 partner is wrong-path and is killed too, even if stale bytes make
  // the branch look like a non-control instruction. One gate
  // (pending_prediction_kills_live_slot2) keeps dispatch, the staged slot-2
  // prediction, and the PC advance on that same one-wide decision.
  assign pending_prediction_owns_live_slot1 =
      pending_prediction_active && (pc_reg == pending_prediction_pc);
  // Both compares start from registered operands and run in parallel;
  // is_compressed only picks between them at the end. Adding 2 or 4 to pc_reg
  // by is_compressed instead would put a 64-bit carry chain between
  // prediction_holdoff and the slot-2 kill and next-PC choice.
  assign pending_prediction_owns_live_slot2 =
      pending_prediction_active && !sel_nop_2_aligner &&
      (is_compressed ? (pc_reg == pending_prediction_prev_pc) :
                       (pc_reg == pending_prediction_prev_native_pc));
  assign pending_prediction_kills_live_slot2 =
      pending_prediction_owns_live_slot1 || pending_prediction_owns_live_slot2;
  assign sel_nop_2 = sel_nop_2_aligner || sel_nop || pending_prediction_kills_live_slot2;
  assign slot2_valid_for_pc_live_effective =
      slot2_valid_for_pc_live && !pending_prediction_kills_live_slot2;
  // pc_controller and c_ext_state must see the same slot-2 valid as PD and
  // dispatch, so both take a replay-aware form (the PC advance selects and
  // slot2_valid) rather than the live aligner gate. During stall replay the
  // live gate reads a window that has moved on, while sel_nop_2_saved was
  // captured at stall entry. Mixing the live slot-2 valid and size with the
  // saved slot-1 size can pick the wrong bundle advance (e.g. +6 for
  // 32b+RVC) and land pc_reg on a mid-instruction byte. Only the staged
  // slot-2 BTB lookup, which qualifies the current live window, uses the live
  // gate.
  assign slot2_prediction_valid = !sel_nop_2;

`ifndef SYNTHESIS
  logic [7:0] instr_pc_metadata_canonical;
  logic [7:0] active_pc_metadata_by_parity;
  logic [7:0] active_pc_metadata_by_parity_canonical;
  logic [3:0] active_pc_pairability_by_parity;
  logic [3:0] active_pc_pairability_by_parity_canonical;
  logic [1:0] active_slot2_start_valid_lo_by_parity;
  logic [1:0] active_slot2_start_valid_lo_by_parity_canonical;
  // Simulation-only checks: each metadata replica matches the sideband bits
  // it copies, and while slot 2 is valid the +2/+4 slot-2 candidate selects
  // match the reference selector (slot 1's fast size). The fast size may
  // differ on a cycle where prediction is blocked, so the comparison also
  // requires that branch_prediction_controller's prediction_common would be
  // set.
  logic slot2_candidate_legacy_oracle_active;
  assign slot2_candidate_legacy_oracle_active =
      !i_pipeline_ctrl.reset && slot2_prediction_valid &&
      !i_trap_ctrl.trap_taken && !i_trap_ctrl.mret_taken &&
      !if_stage_stall_registered && !any_holdoff_safe &&
      !prediction_holdoff && !use_instr_buffer &&
      !disable_branch_prediction_effective;
  always_comb begin
    instr_pc_metadata_canonical = {
      i_instr_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeHi],
      i_instr_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableCompressedHi],
      i_instr_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbIsCompressedHi],
      i_instr_sideband[riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbIsCompressedLo],
      i_instr_sideband[riscv_pkg::ImemSbPairableNativeHi],
      i_instr_sideband[riscv_pkg::ImemSbPairableCompressedHi],
      i_instr_sideband[riscv_pkg::ImemSbIsCompressedHi],
      i_instr_sideband[riscv_pkg::ImemSbIsCompressedLo]
    };
    active_pc_metadata_by_parity = i_instr_pc_metadata_served_high ?
        i_instr_pc_metadata_by_provider_parity[15:8] :
        i_instr_pc_metadata_by_provider_parity[7:0];
    active_slot2_start_valid_lo_by_parity = i_instr_pc_metadata_served_high ?
        i_slot2_start_valid_lo_by_provider_parity[3:2] :
        i_slot2_start_valid_lo_by_provider_parity[1:0];
    active_pc_pairability_by_parity = i_instr_pc_metadata_served_high ?
        i_pc_pairability_by_provider_parity[7:4] :
        i_pc_pairability_by_provider_parity[3:0];
    active_pc_metadata_by_parity_canonical = i_instr_bank_sel_r ?
        {instr_pc_metadata_canonical[3:0], instr_pc_metadata_canonical[7:4]} :
        instr_pc_metadata_canonical;
    active_slot2_start_valid_lo_by_parity_canonical = i_instr_bank_sel_r ?
        {
          i_instr_sideband[riscv_pkg::ImemSbSlot2StartValidLo],
          i_instr_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbSlot2StartValidLo
          ]
        } : {
          i_instr_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbSlot2StartValidLo
          ],
          i_instr_sideband[riscv_pkg::ImemSbSlot2StartValidLo]
        };
    active_pc_pairability_by_parity_canonical = i_instr_bank_sel_r ?
        {
          i_instr_sideband[riscv_pkg::ImemSbPairableNativeLo],
          i_instr_sideband[riscv_pkg::ImemSbEvenLocalPairValid],
          i_instr_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeLo
          ],
          i_instr_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbEvenLocalPairValid
          ]
        } : {
          i_instr_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeLo
          ],
          i_instr_sideband[
              riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbEvenLocalPairValid
          ],
          i_instr_sideband[riscv_pkg::ImemSbPairableNativeLo],
          i_instr_sideband[riscv_pkg::ImemSbEvenLocalPairValid]
        };
  end
  always_ff @(posedge i_clk) begin
    if (!i_pipeline_ctrl.reset && i_instr_valid && !$isunknown(
            {i_instr_pc_metadata, instr_pc_metadata_canonical}
        )) begin
      p_pc_metadata_matches_canonical : assert (i_instr_pc_metadata == instr_pc_metadata_canonical);
    end
    if (!i_pipeline_ctrl.reset && i_instr_valid && !$isunknown(
            {
              active_pc_metadata_by_parity,
              active_pc_metadata_by_parity_canonical,
              active_pc_pairability_by_parity,
              active_pc_pairability_by_parity_canonical,
              active_slot2_start_valid_lo_by_parity,
              active_slot2_start_valid_lo_by_parity_canonical
            }
        )) begin
      p_active_pc_metadata_by_parity_matches_canonical :
      assert (active_pc_metadata_by_parity == active_pc_metadata_by_parity_canonical);
      p_active_pc_pairability_by_parity_matches_canonical :
      assert (active_pc_pairability_by_parity == active_pc_pairability_by_parity_canonical);
      p_active_slot2_start_valid_lo_by_parity_matches_canonical :
      assert (
        active_slot2_start_valid_lo_by_parity ==
        active_slot2_start_valid_lo_by_parity_canonical
      );
    end
    if (slot2_candidate_legacy_oracle_active && !$isunknown(
            {is_compressed_fast, slot2_plus2_candidate_valid, slot2_plus4_candidate_valid}
        )) begin
      p_slot2_candidate_identity_matches_legacy_live_selector :
      assert ({slot2_plus4_candidate_valid, slot2_plus2_candidate_valid} ==
              {!is_compressed_fast, is_compressed_fast});
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Derived Signals and Stall State
  // ---------------------------------------------------------------------------
  logic prev_was_compressed_at_lo_saved;  // Saved for stall recovery
  (* keep = "true", max_fanout = 32 *)logic if_stage_stall;
  (* keep = "true", max_fanout = 32 *)logic if_stage_stall_registered;
  (* keep = "true" *)logic pc_controller_stall;

  // The aligner receives the raw instruction, not a flush-gated copy, which
  // keeps flush off the path is_compressed -> pc_increment -> PC. On a flush
  // cycle pc_controller selects a redirect target anyway, so is_compressed
  // does not affect the PC. PD substitutes the NOP from sel_nop, and
  // c_ext_state's own flush checks protect its state.
  //
  // i_pd_redirect is not part of disable_branch_prediction_effective: that
  // would be a timing-critical cross-module path. Wrong-path BTB hits during
  // a PD redirect cycle are cleaned up by redirect_kill_pending_q
  // (pc_controller) and pd_redirect_q.
  //
  // Suppress every prediction source while a live window is faulted or does
  // not cover pc_reg: garbage bytes, or a false BTB tag hit on a wild PC, must
  // never redirect the front end. A non-covering window is a squashed packet,
  // so it also must not change prediction or RAS state or arm a pending
  // prediction before the served-window resteer. The fault terms are the
  // served window's flags and o_pc's word-0 fetch fault (fetch_fault0_live),
  // plus, with translation off, the PMA check of pc_reg (a translated virtual
  // address has no PMA meaning of its own). A translation that is not visible
  // yet (a translation bubble or an ITLB miss) stalls the front end, which
  // already blocks predictions.
  logic pc_pma_bad;
  logic served_fault_any;
  assign served_fault_any = i_instr_valid && (i_instr_fault0 || i_instr_fault1);
  // With translation off, fetch_fault0_live already equals
  // !pma_fetch_ok(pc), so o_pc needs no PMA check of its own (the reference
  // below includes one). The other disable causes are built without
  // fetch_fault0_live so this late fault is not merged into the pc_reg range
  // check.
  logic prediction_pma_bad_without_fetch_fault;
  assign prediction_pma_bad_without_fetch_fault = served_fault_any ||
      (!i_fetch_translation_active && !riscv_pkg::pma_fetch_ok(
      pc_reg
  ));
  assign pc_pma_bad = prediction_pma_bad_without_fetch_fault || fetch_fault0_live;
  (* keep = "true" *)logic prediction_disable_without_fetch_fault;
  (* keep = "true" *)logic prediction_disable_without_fetch_fault_wcs0;
  assign prediction_disable_without_fetch_fault =
      i_disable_branch_prediction || pending_prediction_holdoff ||
      i_pipeline_ctrl.flush || i_frontend_state_flush || !fetch_progress ||
      prediction_pma_bad_without_fetch_fault || window_cannot_serve_pc_reg;
  assign disable_branch_prediction_effective =
      prediction_disable_without_fetch_fault || fetch_fault0_live;
  // WCS (window_cannot_serve_pc_reg) is the latest input. Build the WCS=0
  // disable early and tie the WCS=1 disable to 1, so the predictor can pick
  // between finished results in its final LUT.
  assign prediction_disable_without_fetch_fault_wcs0 =
      i_disable_branch_prediction || pending_prediction_holdoff_wcs0 ||
      i_pipeline_ctrl.flush || i_frontend_state_flush || !fetch_progress ||
      prediction_pma_bad_without_fetch_fault;
  assign disable_branch_prediction_effective_wcs0 =
      prediction_disable_without_fetch_fault_wcs0 || fetch_fault0_live;
  assign disable_branch_prediction_effective_wcs = 1'b1;
`ifndef SYNTHESIS
  logic pc_pma_bad_ref;
  assign pc_pma_bad_ref = (!i_fetch_translation_active && (!riscv_pkg::pma_fetch_ok(
      pc
  ) || !riscv_pkg::pma_fetch_ok(
      pc_reg
  ))) || fetch_fault0_live || served_fault_any;
  always_comb begin
    if (!$isunknown(
            {pc, pc_reg, i_fetch_translation_active, fetch_fault0_live, served_fault_any}
        )) begin
      p_prediction_pma_fault_cofactor_exact : assert (pc_pma_bad == pc_pma_bad_ref);
    end
  end
`endif
  // IF's internal state clears on flush_for_c_ext_safe, the front-end state
  // flush. cpu_ooo drives i_frontend_state_flush and i_pipeline_ctrl.flush
  // from the same signal (flush_pipeline in misprediction_flush_controller),
  // so the two are equal on every cycle; its trap and xRET terms are the
  // registered pulses.
  logic flush_for_c_ext_safe;
  assign flush_for_c_ext_safe = i_frontend_state_flush;
  assign if_stage_stall = i_pipeline_ctrl.stall;
  assign if_stage_stall_registered = i_pipeline_ctrl.stall_registered;
  assign pc_controller_stall = if_stage_stall;
  (* max_fanout = 16 *)logic instr_bank_sel_for_c_ext;
  (* max_fanout = 16 *)logic instr_bank_sel_for_aligner;
  (* max_fanout = 16 *)logic instr_bank_sel_for_spanning;
  logic fetch_word_swapped_for_c_ext;
  logic fetch_word_swapped_for_spanning;
  // The bank-select bit is registered with the fetch window. Cached-tier (DDR)
  // windows must use the provider's own served-window bit, not the live
  // pc_reg[2], because around redirects and stalls a window fetched for one
  // address can briefly sit beside a different PC.
  assign instr_bank_sel_for_c_ext = i_instr_bank_sel_r;
  assign instr_bank_sel_for_aligner = i_instr_bank_sel_r;
  assign instr_bank_sel_for_spanning = i_instr_bank_sel_r;
  assign fetch_word_swapped_for_c_ext = instr_bank_sel_for_c_ext ^ pc_reg[2];
  assign fetch_word_swapped_for_spanning = instr_bank_sel_for_spanning ^ pc_reg[2];

  // ===========================================================================
  // Branch Prediction Controller
  // ===========================================================================
  // Declared before first use to avoid Vivado warnings.
  logic use_saved_values;
  assign use_saved_values = if_stage_stall_registered && saved_values_valid;
  logic            prediction_reset_c_ext;
  logic [    15:0] raw_parcel_sc;
  logic [    31:0] assembled_instr_sc;
  logic [XLEN-1:0] instruction_pc_sc;
  logic [XLEN-1:0] link_address_sc;

  // Slot-2 PC candidates: slot 2 sits at pc_reg+2 behind an RVC slot 1 and at
  // pc_reg+4 behind a native one. The live fetch PC reads the +2, +4, and
  // rotated +2 BTB copies one cycle ahead; when this pc_reg is served,
  // branch_prediction_controller takes the same-word entry or the rotated +2
  // entry for the next word, checked against its full tag. The aligner's
  // one-hot, valid-qualified candidate selects decide which candidate's
  // target and index are used, so the raw slot-1 size never reaches a RAM
  // address.
  logic [XLEN-1:0] slot2_pc_plus2_for_btb;
  logic [XLEN-1:0] slot2_pc_plus4_for_btb;
  assign slot2_pc_plus2_for_btb = pc_reg + riscv_pkg::PcIncrementCompressed;
  assign slot2_pc_plus4_for_btb = pc_reg + riscv_pkg::PcIncrement32bit;

  // With fixed-latency BRAM the fetch PC normally equals the emitted slot-2
  // PC: that is the intended one-request lookahead. A taken live hit at that
  // address still aliases slot 2 and is suppressed for slot 1; only a real
  // variable-latency gap in responses (lookup_lead_collapsed) hands the live
  // result to slot 2. Pipeline stalls do not count: their release uses the
  // stall-captured packet and metadata, not a new live response.
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || flush_for_c_ext_safe) begin
      fetch_invalid_unstalled_q <= 1'b0;
    end else if (!if_stage_stall) begin
      fetch_invalid_unstalled_q <= !i_instr_valid;
    end
  end
  assign lookup_lead_collapsed =
      fetch_invalid_unstalled_q && i_instr_valid && !if_stage_stall_registered;

  branch_prediction_controller #(
      .SLOT2_PC_FROM_BASE(XLEN == riscv_pkg::XLEN)
  ) branch_prediction_controller_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      // Serialization stalls (for unresolved older branches or CSRs) must also
      // block new predictions. Otherwise a younger speculative branch or return
      // can arm a pending prediction that outlives, and conflicts with, the
      // older instruction's misprediction recovery.
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_fetch_progress(fetch_progress),
      // Flush with registered trap and xRET terms; see flush_for_c_ext_safe.
      .i_flush(flush_for_c_ext_safe),
      // PD redirect kills in-flight slot-1 prediction metadata (see module).
      .i_pd_redirect(i_pd_redirect),
      .i_pd_redirect_target(i_pd_redirect_target),

      // Current PC for BTB lookup
      .i_pc(pc),

      // Slot-2 PCs for the staged BTB lookup.
      .i_pc_2(slot2_pc_plus2_for_btb),
      .i_pc_2_alt(slot2_pc_plus4_for_btb),
      .i_pc_2_base(pc_reg),
      .i_lookup_lead_collapsed(lookup_lead_collapsed),
      .i_slot2_plus2_candidate_valid(slot2_plus2_candidate_valid),
      .i_slot2_plus4_candidate_valid(slot2_plus4_candidate_valid),
      .i_slot2_valid(slot2_prediction_valid),
      .i_slot2_is_compressed_plus2(slot2_is_compressed_plus2_for_btb),
      .i_slot2_is_compressed_plus4(slot2_is_compressed_plus4_for_btb),
      // The per-candidate sizes above let branch_prediction_controller qualify
      // +2 and +4 in parallel; the selected live size feeds only its
      // simulation checks.
      .i_slot2_is_compressed(is_compressed_2),

      // Control signals for prediction gating
      .i_trap_taken(i_trap_ctrl.trap_taken),
      .i_mret_taken(i_trap_ctrl.mret_taken),
      .i_branch_taken(i_from_ex_comb.branch_taken),
      .i_any_holdoff_safe(any_holdoff_safe),
      .i_is_32bit_spanning(1'b0),
      // The buffer select without the aligner's FENCE-class term (see
      // use_instr_buffer_for_coverage_timing). The two differ only on a
      // FENCE-class flush cycle, which already blocks prediction; the packet
      // itself uses use_instr_buffer.
      .i_use_instr_buffer(use_instr_buffer_for_coverage_timing),
      .i_disable_branch_prediction(disable_branch_prediction_effective),
      .i_disable_branch_prediction_wcs0(disable_branch_prediction_effective_wcs0),
      .i_disable_branch_prediction_wcs(disable_branch_prediction_effective_wcs),
      .i_window_cannot_serve_raw(window_cannot_serve_pc_reg),
      .i_fetch_lookup_is_lower_parcel(fetch_lookup_is_lower_parcel),

      // BTB update interface (from ex_comb_synthesizer)
      .i_btb_update(i_from_ex_comb.btb_update),
      .i_btb_update_pc(i_from_ex_comb.btb_update_pc),
      .i_btb_update_target(i_from_ex_comb.btb_update_target),
      .i_btb_update_taken(i_from_ex_comb.btb_update_taken),
      .i_btb_update_compressed(i_from_ex_comb.btb_update_compressed),
      .i_btb_update_call(i_from_ex_comb.btb_update_call),
      .i_btb_update_return(i_from_ex_comb.btb_update_return),
      .i_btb_early_update_active,
      .i_btb_early_update_pc,
      .i_btb_early_update_taken,
      .i_btb_late_update_pc,
      .i_btb_late_update_taken,

      // Return address stack operation for the packet handed to PD this cycle
      .i_ras_push(ras_push),
      .i_ras_pop(ras_pop),
      .i_ras_push_address(ras_push_address),

      // RAS misprediction recovery (from branch recovery)
      .i_ras_misprediction(i_from_ex_comb.ras_misprediction),
      .i_ras_restore_tos(i_from_ex_comb.ras_restore_tos),
      .i_ras_restore_valid_count(i_from_ex_comb.ras_restore_valid_count),
      .i_ras_pop_after_restore(i_from_ex_comb.ras_pop_after_restore),
      .i_ras_push_after_restore(i_from_ex_comb.ras_push_after_restore),
      .i_ras_push_address_after_restore(i_from_ex_comb.ras_push_address_after_restore),

      // Bimodal direction-predictor training (conditional branches only)
      .i_dir_update_valid(i_dir_update_valid),
      .i_dir_update_idx  (i_dir_update_idx),
      .i_dir_update_taken(i_dir_update_taken),

      // Combinational prediction target (for pc_controller)
      .o_predicted_target(btb_predicted_target),
      .o_predicted_is_call(btb_predicted_is_call),
      .o_predicted_is_return(btb_predicted_is_return),

      // Registered prediction outputs (for pipeline alignment)
      .o_prediction_used_r(prediction_used_r),
      .o_predicted_target_r(btb_predicted_target_r),
      .o_predicted_is_call_r(btb_predicted_is_call_r),
      .o_predicted_is_return_r(btb_predicted_is_return_r),

      // Control outputs
      .o_prediction_used(prediction_used),
      .o_prediction_used_for_pc(prediction_used_for_pc),
      .o_prediction_used_live_cofactor(prediction_used_live_cofactor),
      .o_prediction_holdoff(prediction_holdoff),
      .o_sel_prediction_r(sel_prediction_r),
      .o_prediction_requires_pc_reg_handoff(prediction_requires_pc_reg_handoff),
      .o_control_flow_to_halfword_pred(control_flow_to_halfword_pred),

      // Slot-2 prediction outputs.
      .o_slot2_prediction_used(slot2_prediction_used),
      .o_slot2_prediction_used_for_pc(slot2_prediction_used_for_pc),
      .o_slot2_staged_prediction_used_for_pc(slot2_staged_prediction_used_for_pc),
      .o_slot1_aliases_slot2_candidate(slot1_aliases_slot2_candidate),
      .o_slot2_live_target_used_for_pc_cofactor(slot2_live_target_used_for_pc_cofactor),
      .o_slot2_predicted_taken(slot2_predicted_taken),
      .o_slot2_predicted_target(slot2_predicted_target),
      .o_slot2_staged_predicted_target(slot2_staged_predicted_target),
      .o_slot2_live_predicted_target(slot2_live_predicted_target),
      .o_slot2_predicted_is_call(slot2_predicted_is_call),
      .o_slot2_predicted_is_return(slot2_predicted_is_return),

      // The registered stack state: the recovery point of the packets IF hands
      // PD this cycle, before their own push or pop.
      .o_ras_checkpoint_tos(ras_checkpoint_tos),
      .o_ras_checkpoint_valid_count(ras_checkpoint_valid_count),

      // Bimodal direction and predict-time index, carried to PD
      .o_dir_predicted_taken(bp_dir_taken),
      .o_dir_predicted_taken_live(bp_dir_taken_live),
      .o_dir_predicted_taken_live_cofactor(bp_dir_taken_live_cofactor),
      .o_dir_idx(bp_dir_idx),
      .o_dir_idx_live(bp_dir_idx_live),
      .o_dir_idx_2(bp_dir_idx_2)
  );

  // ===========================================================================
  // PC Controller
  // ===========================================================================
  pc_controller #(
      .XLEN(XLEN),
      // A ready pending handoff asserts pending_prediction_holdoff_wcs0, which
      // blocks prediction_common, and the WCS=1 disable is always set. Staged
      // and live slot-2 predictions both need prediction_common, so the
      // controller can skip its own slot-2 check on the handoff.
      .PENDING_HANDOFF_EXCLUDES_SLOT2(1'b1)
  ) pc_controller_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      .i_stall(pc_controller_stall),
      .i_fetch_progress(fetch_progress),
      // Flush with registered trap and xRET terms; see flush_for_c_ext_safe.
      .i_flush(flush_for_c_ext_safe),
      .i_fence_i_flush(i_fence_i_flush),
      .i_fence_i_target(i_fence_i_target),

      .i_branch_taken (i_from_ex_comb.branch_taken),
      .i_branch_target(i_from_ex_comb.branch_target_address),

      .i_pd_redirect(i_pd_redirect),
      .i_pd_redirect_target(i_pd_redirect_target),
      .i_window_cannot_serve(window_resteer_pc_reg),
      .i_window_cannot_serve_raw(window_cannot_serve_pc_reg),

      .i_trap_taken (i_trap_ctrl.trap_taken),
      .i_mret_taken (i_trap_ctrl.mret_taken),
      .i_trap_target(i_trap_ctrl.trap_target),

      .i_is_compressed(is_compressed_fast),
      // Two-wide bundle advance. The selects fold in the slot-2 valid and size
      // and switch to their stall-captured copies during replay, so the PC
      // advance stays consistent with what dispatch sees.
      .i_pc_fetch_advance_sel(pc_fetch_advance_sel),
      .i_pc_reg_advance_sel(pc_reg_advance_sel),
      .i_pc_fetch_advance_sel_run(pc_fetch_advance_sel_run),
      .i_pc_fetch_advance_sel_nop(pc_fetch_advance_sel_nop),
      .i_pc_reg_advance_sel_run(pc_reg_advance_sel_run),
      .i_pc_reg_advance_sel_nop(pc_reg_advance_sel_nop),

      // Branch prediction (from branch_prediction_controller)
      .i_predicted_target(btb_predicted_target),
      .i_predicted_target_r(btb_predicted_target_r),
      .i_prediction_used(prediction_used),
      .i_prediction_used_for_pc(prediction_used_for_pc),
      .i_sel_prediction_r(sel_prediction_r),
      .i_prediction_requires_pc_reg_handoff(prediction_requires_pc_reg_handoff),
      .i_prediction_holdoff(prediction_holdoff),
      .i_prediction_already_emitted(live_prediction_emits_with_output),
      .i_sel_nop(pc_control_sel_nop),

      // Slot-2 redirect, plus its staged and live parts (split for timing).
      .i_slot2_prediction_used(slot2_prediction_used),
      .i_slot2_prediction_used_for_pc(slot2_prediction_used_for_pc),
      .i_slot2_predicted_target(slot2_predicted_target),
      .i_slot2_staged_prediction_used_for_pc(slot2_staged_prediction_used_for_pc),
      .i_slot1_aliases_slot2_candidate(slot1_aliases_slot2_candidate),
      .i_slot2_live_target_used_for_pc_cofactor(slot2_live_target_used_for_pc_cofactor),
      .i_slot2_staged_predicted_target(slot2_staged_predicted_target),
      .i_slot2_live_predicted_target(slot2_live_predicted_target),
      .o_slot2_redirect_q(slot2_redirect_q),

      .o_pc(pc),
      .o_pc_reg(pc_reg),
      .o_pc_reg_high_for_coverage(pc_reg_high_for_coverage),
      .o_fetch_lookup_is_lower_parcel(fetch_lookup_is_lower_parcel),
      .o_control_flow_change(control_flow_change),
      .o_control_flow_holdoff(control_flow_holdoff),
      .o_control_flow_to_halfword(control_flow_to_halfword),
      .o_control_flow_to_halfword_r(control_flow_to_halfword_r),
      .o_reset_holdoff(reset_holdoff),
      .o_any_holdoff(any_holdoff),
      .o_any_holdoff_safe(any_holdoff_safe),
      .o_pending_prediction_active(pending_prediction_active),
      .o_pending_prediction_pc(pending_prediction_pc),
      .o_pending_prediction_prev_pc(pending_prediction_prev_pc),
      .o_pending_prediction_prev_native_pc(pending_prediction_prev_native_pc),
      .o_pending_prediction_target_handoff(pending_prediction_target_handoff),
      .o_pending_prediction_holdoff(pending_prediction_holdoff),
      .o_pending_prediction_holdoff_wcs0(pending_prediction_holdoff_wcs0),
      .o_pending_prediction_holdoff_wcs(pending_prediction_holdoff_wcs),
      .o_pending_prediction_fetch_holdoff(pending_prediction_fetch_holdoff),
      .o_pending_prediction_fetch_holdoff_wcs0(pending_prediction_fetch_holdoff_wcs0),
      .o_pending_prediction_fetch_holdoff_wcs(pending_prediction_fetch_holdoff_wcs),
      .o_pending_prediction_target_holdoff(pending_prediction_target_holdoff),
      .o_pending_prediction_redirect_kill(pending_prediction_redirect_kill),
      .o_next_pc(),
      .o_next_pc_holds(),
      .o_pc_update_en(pc_update_en),
      .o_npc_sel(npc_sel),
      .o_npc_cond(npc_cond),
      .o_npc_seq(npc_seq),
      .o_npc_cmp_val(),
      .o_npc_val()
  );

  // ===========================================================================
  // Instruction MMU
  // ===========================================================================
  // With translation off, a combinational pass-through with no bubble. Under
  // Sv39 it translates only the registered o_pc: after o_pc moves, an ITLB
  // hit becomes visible one bubble later (possibly two at a page crossing);
  // see mmu/immu.sv.
  immu #(
      .XLEN(XLEN)
  ) u_immu (
      .i_clk(i_clk),
      .i_rst(i_pipeline_ctrl.reset),
      .i_active(i_fetch_translation_active),
      .i_priv_u(i_fetch_priv_u),
      .i_tlb_invalidate(i_tlb_invalidate),
      .i_pc(pc),
      .o_pa0(o_fetch_pa0),
      .o_pa1(o_fetch_pa1),
      .o_pa_valid(fetch_pa_valid),
      .o_fault0(fetch_fault0_live),
      .o_fault0_page(o_fetch_fault0_page),
      .o_fault1(o_fetch_fault1),
      .o_fault1_page(o_fetch_fault1_page),
      .o_line_after_ok(o_fetch_line_after_ok),
      .o_walk_req_valid(o_walk_req_valid),
      .i_walk_req_ready(i_walk_req_ready),
      .o_walk_vpn(o_walk_vpn),
      .i_walk_resp_valid(i_walk_resp_valid),
      .i_walk_resp(i_walk_resp)
  );
  assign o_fetch_pa_valid = fetch_pa_valid;
  assign o_fetch_fault0   = fetch_fault0_live;
  assign o_fetch_pa_hold  = !fetch_pa_valid;

  // The low-BRAM presenter has no wide PC-movement detector of its own, so it
  // needs a pulse for every nonsequential fetch-PC load, except a slot-1
  // prediction whose branch was not emitted on the redirect cycle: that
  // branch's window is still owed, so the presenter repeats the old request
  // until it is served and only then requests the already-loaded target. For
  // a slot-2 prediction, or a slot-1 prediction emitted with its branch, the
  // branch was accepted in the redirecting window, so nothing is owed for the
  // old request. Recovery and PD redirects, served-window resteers, and trap,
  // xRET, and FENCE-class flushes likewise end the old request. pc_update_en
  // limits the pulse to cycles on which the fetch PC actually loads.
  // fetch_redirect resolves the arm priority for no prediction, a slot-1
  // prediction, and a slot-2 prediction in parallel, so the late prediction
  // requests only pick among finished values; the simulation check below
  // compares it with the direct equation.
  fetch_redirect fetch_redirect_inst (
      .i_clk(i_clk),
      .i_reset(i_pipeline_ctrl.reset),
      .i_pc_update_en(pc_update_en),
      .i_npc_cond(npc_cond[riscv_pkg::PcNextArms-1:1]),
      .i_npc_seq(npc_seq[riscv_pkg::PcNextArms-1:1]),
      .i_live_prediction_emits_with_output(live_prediction_emits_with_output),
      .o_fetch_redirect(o_fetch_redirect)
  );
`ifndef SYNTHESIS
  logic fetch_redirect_reference_q;
  logic fetch_redirect_reference_valid_q = 1'b0;
  always_ff @(posedge i_clk) begin
    fetch_redirect_reference_valid_q <= 1'b1;
    fetch_redirect_reference_q <= !i_pipeline_ctrl.reset &&
        pc_update_en && |(npc_sel & ~npc_seq) &&
        !(npc_sel[PredictionNpcArm] && !live_prediction_emits_with_output);
    if (fetch_redirect_reference_valid_q && !$isunknown(
            {o_fetch_redirect, fetch_redirect_reference_q}
        )) begin
      p_fetch_redirect_original_registered_equation :
      assert (o_fetch_redirect == fetch_redirect_reference_q);
    end
  end
`endif
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      o_fetch_cached_retarget <= 1'b0;
    end else begin
      o_fetch_cached_retarget <=
          (pc_update_en &&
           (i_from_ex_comb.branch_taken || i_pd_redirect ||
            slot2_prediction_used_for_pc || live_prediction_emits_with_output ||
            window_resteer_pc_reg)) ||
          i_trap_ctrl.trap_taken || i_trap_ctrl.mret_taken || i_fence_i_flush;
    end
  end

  // ===========================================================================
  // C-Extension State Controller
  // ===========================================================================
  c_ext_state #(
      .XLEN(XLEN)
  ) c_ext_state_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      .i_stall(if_stage_stall),
      // Its registered trap and xRET terms keep exception detection off the
      // path through c_ext_state to the PC calculation.
      .i_flush(flush_for_c_ext_safe),
      .i_stall_registered(if_stage_stall_registered),

      .i_control_flow_holdoff(control_flow_holdoff),
      .i_any_holdoff_safe(any_holdoff_safe),
      .i_prediction_holdoff(prediction_holdoff),
      .i_prediction_reset_state(prediction_reset_c_ext),
      .i_pending_prediction_active(pending_prediction_active),
      .i_pending_prediction_target_handoff(pending_prediction_target_handoff),
      .i_pending_prediction_target_holdoff(pending_prediction_target_holdoff),

      .i_effective_instr(effective_instr),
      .i_pc_reg(pc_reg),

      .i_is_compressed(is_compressed),
      .i_sel_nop(sel_nop),
      .i_fetch_progress(fetch_progress),
      .i_slot2_valid(slot2_valid),
      // Align sideband to match instruction word selection
      .i_instr_sideband(fetch_word_swapped_for_c_ext ?
                            i_instr_sideband[(2*riscv_pkg::ImemSidebandWidth)-1:
                                             riscv_pkg::ImemSidebandWidth] :
                            i_instr_sideband[riscv_pkg::ImemSidebandWidth-1:0]),
      .o_instr_buffer(instr_buffer),
      .o_prev_was_compressed_at_lo(prev_was_compressed_at_lo),
      .o_is_compressed_saved(is_compressed_saved),
      .o_saved_values_valid(saved_values_valid),
      .o_instr_buffer_sideband(instr_buffer_sideband),
      .i_instr_fault(cur_fault_pair),
      .o_instr_buffer_fault(instr_buffer_fault)
  );

  // ===========================================================================
  // Stall State Preservation
  // ===========================================================================
  // prev_was_compressed_at_lo is captured when a stall begins.

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || flush_for_c_ext_safe || prediction_reset_c_ext) begin
      // A flush invalidates the pre-flush capture (registered flush; see
      // flush_for_c_ext_safe).
      prev_was_compressed_at_lo_saved <= 1'b0;
    end else if (if_stage_stall & ~if_stage_stall_registered) begin
      prev_was_compressed_at_lo_saved <= prev_was_compressed_at_lo;
    end
  end

  // ===========================================================================
  // Instruction Aligner
  // ===========================================================================
  // Live slot-2 kill-cause classification from the aligner. The native and
  // compressed slot-1 control taps also feed frontend_validity_tracker; all
  // six taps feed width-funnel profiling.
  logic slot2_kill_s1_native_ctrl_live;
  logic slot2_kill_s1_native_serialize_live;
  logic slot2_kill_slot1_ctrl_live;
  logic slot2_kill_class_live;
  logic slot2_kill_window_limit_live;
  logic slot2_kill_transient_live;

  instruction_aligner #(
      .XLEN(XLEN)
  ) instruction_aligner_inst (
      .i_instr(i_instr),
      .i_instr_sideband(i_instr_sideband),
      .i_instr_pc_metadata_by_provider_parity(i_instr_pc_metadata_by_provider_parity),
      .i_pc_pairability_by_provider_parity(i_pc_pairability_by_provider_parity),
      .i_slot2_start_valid_lo_by_provider_parity(i_slot2_start_valid_lo_by_provider_parity),
      .i_instr_pc_metadata_served_high(i_instr_pc_metadata_served_high),
      .i_instr_bank_sel_r(instr_bank_sel_for_aligner),
      .i_instr_buffer(instr_buffer),
      .i_instr_buffer_sideband(instr_buffer_sideband),
      .i_pc_reg(pc_reg),
      .i_pc_reg_high_for_coverage(pc_reg_high_for_coverage),

      .i_prev_was_compressed_at_lo(prev_was_compressed_at_lo),

      // Only the registered stall, not the combinational one, so the path
      // stall → is_compressed → PC is broken.
      .i_stall_registered(if_stage_stall_registered),
      .i_prev_was_compressed_at_lo_saved(prev_was_compressed_at_lo_saved),
      .i_is_compressed_saved(is_compressed_saved),
      .i_saved_values_valid(saved_values_valid && !i_fence_i_flush),

      .o_raw_parcel(raw_parcel),
      .o_effective_instr(effective_instr),
      .o_is_compressed(is_compressed),
      .o_is_compressed_fast(is_compressed_fast),
      .o_is_compressed_for_pc_advance(is_compressed_for_pc_advance),
      .o_no_buffer_accepts_served_last(no_buffer_accepts_served_last),
      .o_sel_compressed(sel_compressed),
      .o_use_instr_buffer(use_instr_buffer),
      .o_rvc_source_hot(rvc_source_hot),
      .o_rvc_bits24_20(rvc_bits24_20),
      .o_rvc_rs1_rest(rvc_rs1_rest),
      .o_rvc_extra(rvc_extra),

      // Slot-2 outputs. sel_nop_2 is the aligner's live pairing decision;
      // this module adds the slot-1 holdoffs and flushes.
      .o_raw_parcel_2(raw_parcel_2),
      .o_effective_instr_2(effective_instr_2),
      .o_slot2_decomp_illegal(slot2_decomp_illegal),
      .o_is_compressed_2(is_compressed_2),
      .o_sel_nop_2(sel_nop_2_aligner),
      .o_sel_compressed_2(sel_compressed_2),
      .o_source_hot_2(source_hot_2),
      .o_bits24_20_2(bits24_20_2),
      .o_rs1_rest_2(rs1_rest_2),
      .o_slot2_valid_for_pc(slot2_valid_for_pc_live),
      .o_slot2_is_compressed_for_pc(slot2_is_compressed_for_pc_live),
      .o_slot2_is_compressed_plus2_for_btb(slot2_is_compressed_plus2_for_btb),
      .o_slot2_is_compressed_plus4_for_btb(slot2_is_compressed_plus4_for_btb),
      .o_slot2_plus2_candidate_valid(slot2_plus2_candidate_valid),
      .o_slot2_plus4_candidate_valid(slot2_plus4_candidate_valid),

      // Slot-2 kill-cause taps (see their declarations above).
      .o_slot2_kill_s1_native_ctrl(slot2_kill_s1_native_ctrl_live),
      .o_slot2_kill_s1_native_serialize(slot2_kill_s1_native_serialize_live),
      .o_slot2_kill_slot1_ctrl(slot2_kill_slot1_ctrl_live),
      .o_slot2_kill_class(slot2_kill_class_live),
      .o_slot2_kill_window_limit(slot2_kill_window_limit_live),
      .o_slot2_kill_transient(slot2_kill_transient_live)
  );

  // Registered PD redirect, ORed with !prediction_holdoff in sel_nop's
  // control-flow term below. The term is redundant: pd_redirect_q = 1 implies
  // prediction_holdoff = 0. The edge that sets pd_redirect_q also clears the
  // holdoff, because a PD redirect either kills the registered prediction
  // metadata (which clears the holdoff) or finds registered metadata, whose
  // holdoff blocks any new prediction that cycle; and while pd_redirect_q
  // holds, the holdoff can only be cleared. The register is off the critical
  // path (FF output → one OR gate).
  logic pd_redirect_q;
  always_ff @(posedge i_clk) begin
    // Updates only on an unstalled cycle with fetch progress, the same gate
    // as o_slot2_redirect_q in pc_controller (!i_stall && i_fetch_progress),
    // so it holds through the stalls and no-progress cycles that
    // control_flow_holdoff also holds through.
    if (i_pipeline_ctrl.reset) pd_redirect_q <= 1'b0;
    else if (!i_pipeline_ctrl.stall && fetch_progress) pd_redirect_q <= i_pd_redirect;
  end

  // A variable-latency provider can close the normal one-window fetch lead,
  // so a predicted branch arrives while pc == pc_reg and is emitted on the
  // redirect cycle itself. The first target response must then stay an
  // ordinary bubble; otherwise prediction_holdoff mistakes it for the
  // deferred branch, exempts it from the control-flow NOP, and pc_reg
  // presents the target bundle a second time. prediction_already_emitted_q
  // records the case and, like pd_redirect_q, holds through cycles with no
  // fetch progress.
  logic prediction_already_emitted_q;
  logic lookup_pc_matches_packet_pc;
  logic live_prediction_emits_with_output;
  assign lookup_pc_matches_packet_pc = pc == pc_reg;
  assign live_prediction_emits_with_output = prediction_used_live_cofactor && !sel_nop &&
                                             !if_stage_stall_registered &&
                                             lookup_pc_matches_packet_pc;
`ifndef SYNTHESIS
  // prediction_used_live_cofactor lacks only the slot-2 alias gate. pc ==
  // pc_reg rules out both alias addresses (pc_reg+2 and pc_reg+4), so with
  // that equality applied it must match the same expression built from
  // prediction_used.
  logic live_prediction_emits_with_output_legacy;
  assign live_prediction_emits_with_output_legacy =
      prediction_used && !sel_nop && !if_stage_stall_registered &&
      lookup_pc_matches_packet_pc;
  always_comb begin
    if (!$isunknown(
            {
              lookup_pc_matches_packet_pc,
              branch_prediction_controller_inst.slot1_prediction_owned_by_slot2,
              live_prediction_emits_with_output,
              live_prediction_emits_with_output_legacy
            }
        )) begin
      p_exact_live_lookup_excludes_slot2_ownership :
      assert (!lookup_pc_matches_packet_pc ||
              !branch_prediction_controller_inst.slot1_prediction_owned_by_slot2);
      p_live_prediction_output_cofactor_is_exact :
      assert (live_prediction_emits_with_output == live_prediction_emits_with_output_legacy);
    end
  end
`endif
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || flush_for_c_ext_safe) begin
      prediction_already_emitted_q <= 1'b0;
    end else if (!i_pipeline_ctrl.stall && fetch_progress) begin
      prediction_already_emitted_q <= live_prediction_emits_with_output;
    end
  end
  // Any redirect other than a prediction leaves one stale cycle in which
  // fetch has moved to the new PC but the returned word still belongs to the
  // old path. Word-aligned redirects are not exempt: they can pair a correct
  // new PC with old-path bytes, which later corrupt the C-extension buffer
  // state. Predictions are exempted through prediction_holdoff, so an ordinary
  // BTB hit still delivers the predicted branch itself. The pending-prediction
  // fetch holdoff gets no such exemption: it releases only when the pending
  // branch's handoff is ready (or for the immediate predecessor). Exempting it
  // whenever prediction_holdoff is set could dispatch the pending branch
  // before its target handoff and metadata are ready, and then dispatch it
  // again at the handoff.
  //
  // pd_redirect_q in that exemption is redundant (see its declaration): a
  // PD redirect's holdoff cycle never has prediction_holdoff set.
  // slot2_redirect_q overrides the exemption for the slot-2 BTB redirect
  // bubble: BRAM was fetching the sequential wrong-path bundle when the
  // slot-2 prediction fired, and a same-cycle slot-1 BTB hit can set
  // prediction_holdoff, so the cycle following the redirect must NOP even if
  // prediction_holdoff is set.
  //
  // Served-window rule: pc_reg's word P (bits [31:2], as the providers tag
  // their windows) must be S, S+1, or, while the instruction buffer holds P,
  // S-1, for the provider that served the window. P = S+1 means the window
  // ends at P, which is not enough when the packet needs P+1: a native
  // instruction starting in P's high parcel spans into P+1, and a
  // buffer-backed RVC in P's high parcel can pair with a slot 2 in P+1's low
  // parcel. Otherwise the aligner's one-bit bank parity can select the wrong
  // word or spanning half and advance into bad instruction data.
  //
  // For timing, each provider registers S, S+1, and S-1 beside its payload
  // and has its own three-LUT-level equality tree (served_window_coverage).
  // Both share one buffer-use bit, pc_reg[1], and the no-buffer served-last
  // flag, which dedicated muxes apply outside the equality LUTs; the late
  // buffer-use bit drives only the final MUXF8. No address arithmetic or
  // 30-bit provider mux sits ahead of either comparator.
  logic [XLEN-1:0] pc_reg_serve_view;
  logic [29:0] pc_reg_word;
  logic served_window_covers_low;
  logic served_window_covers_high;
  logic served_window_covers_pc_reg;
  logic prev_was_compressed_at_lo_for_coverage_timing;
  assign pc_reg_serve_view = riscv_pkg::canonical_paddr(pc_reg);
  assign pc_reg_word = pc_reg_serve_view[31:2];
  // use_instr_buffer_for_coverage_timing is the aligner's buffer select
  // without its FENCE-class term (the aligner ignores the stall-saved copy on
  // an i_fence_i_flush cycle) and with the register copy of pc_reg[1]. The
  // real select, use_instr_buffer, drives the packet and the PC advance; this
  // copy drives only branch_prediction_controller and the two served-window
  // comparators, and a FENCE-class flush already squashes every result that
  // could see a difference. The aligner separately supplies the no-buffer
  // served-last flag: always true when pc_reg[1] is 0, otherwise true only
  // for a compressed high parcel, so the comparators never depend on the low
  // parcel's size. When the buffer select is 1 it wins the comparators' final
  // MUXF8, so the no-buffer flag does not matter.
  assign prev_was_compressed_at_lo_for_coverage_timing = use_saved_values ?
      prev_was_compressed_at_lo_saved : prev_was_compressed_at_lo;
  assign use_instr_buffer_for_coverage_timing =
      prev_was_compressed_at_lo_for_coverage_timing && pc_reg_high_for_coverage;

`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown(
            {
              use_instr_buffer_for_coverage_timing,
              prev_was_compressed_at_lo_for_coverage_timing,
              pc_reg_high_for_coverage,
              pc_reg[1]
            }
        )) begin
      p_use_instr_buffer_for_coverage_timing_exact :
      assert (use_instr_buffer_for_coverage_timing ==
              (prev_was_compressed_at_lo_for_coverage_timing && pc_reg[1]));
      p_pc_reg_high_for_coverage_exact : assert (pc_reg_high_for_coverage == pc_reg[1]);
    end
  end
`endif

  served_window_coverage u_served_window_coverage_low (
      .i_pc_word(pc_reg_word),
      .i_served_word(i_served_word_low),
      .i_served_last_word(i_served_last_word_low),
      .i_served_prev_word(i_served_prev_word_low),
      .i_served_prev_word_valid(i_served_prev_word_valid_low),
      .i_use_instr_buffer(use_instr_buffer_for_coverage_timing),
      .i_no_buffer_accepts_served_last(no_buffer_accepts_served_last),
      .i_pc_high(pc_reg_high_for_coverage),
      .o_covers(served_window_covers_low)
  );

  served_window_coverage u_served_window_coverage_high (
      .i_pc_word(pc_reg_word),
      .i_served_word(i_served_word_high),
      .i_served_last_word(i_served_last_word_high),
      .i_served_prev_word(i_served_prev_word_high),
      .i_served_prev_word_valid(i_served_prev_word_valid_high),
      .i_use_instr_buffer(use_instr_buffer_for_coverage_timing),
      .i_no_buffer_accepts_served_last(no_buffer_accepts_served_last),
      .i_pc_high(pc_reg_high_for_coverage),
      .o_covers(served_window_covers_high)
  );

  assign served_window_covers_pc_reg = i_instr_pc_metadata_served_high ?
      served_window_covers_high : served_window_covers_low;

`ifndef SYNTHESIS
  logic [29:0] selected_served_word;
  logic [29:0] selected_served_last_word;
  logic [29:0] selected_served_prev_word;
  logic selected_served_prev_word_valid;
  logic served_eq_pc_word;
  logic served_last_eq_pc_word;
  logic served_eq_pc_word_p1;
  logic served_window_covers_reference;
  logic served_window_covers_low_reference;
  logic served_window_covers_high_reference;
  logic served_window_native_high;
  logic served_contract_check_valid_q;

  assign served_window_native_high = pc_reg[1] && !is_compressed_for_pc_advance;

  assign selected_served_word = i_instr_pc_metadata_served_high ?
      i_served_word_high : i_served_word_low;
  assign selected_served_last_word = i_instr_pc_metadata_served_high ?
      i_served_last_word_high : i_served_last_word_low;
  assign selected_served_prev_word = i_instr_pc_metadata_served_high ?
      i_served_prev_word_high : i_served_prev_word_low;
  assign selected_served_prev_word_valid = i_instr_pc_metadata_served_high ?
      i_served_prev_word_valid_high : i_served_prev_word_valid_low;
  assign served_eq_pc_word = selected_served_word == pc_reg_word;
  assign served_last_eq_pc_word = selected_served_last_word == pc_reg_word;
  assign served_eq_pc_word_p1 = selected_served_prev_word_valid &&
      (selected_served_prev_word == pc_reg_word);
  assign served_window_covers_reference = use_instr_buffer_for_coverage_timing ?
      (served_eq_pc_word || served_eq_pc_word_p1 ||
       (!pc_reg[1] && served_last_eq_pc_word)) :
      (served_eq_pc_word || (!served_window_native_high && served_last_eq_pc_word));
  assign served_window_covers_low_reference = use_instr_buffer_for_coverage_timing ?
      ((i_served_word_low == pc_reg_word) ||
       (i_served_prev_word_valid_low && (i_served_prev_word_low == pc_reg_word)) ||
       (!pc_reg[1] && (i_served_last_word_low == pc_reg_word))) :
      ((i_served_word_low == pc_reg_word) ||
       (!served_window_native_high && (i_served_last_word_low == pc_reg_word)));
  assign served_window_covers_high_reference = use_instr_buffer_for_coverage_timing ?
      ((i_served_word_high == pc_reg_word) ||
       (i_served_prev_word_valid_high && (i_served_prev_word_high == pc_reg_word)) ||
       (!pc_reg[1] && (i_served_last_word_high == pc_reg_word))) :
      ((i_served_word_high == pc_reg_word) ||
       (!served_window_native_high && (i_served_last_word_high == pc_reg_word)));

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) served_contract_check_valid_q <= 1'b0;
    else served_contract_check_valid_q <= 1'b1;
  end

  always_comb begin
    if (served_contract_check_valid_q && !$isunknown(
            {i_served_word_low,
             i_served_last_word_low,
             i_served_prev_word_low,
             i_served_prev_word_valid_low,
             i_served_word_high,
             i_served_last_word_high,
             i_served_prev_word_high,
             i_served_prev_word_valid_high,
             i_instr_pc_metadata_served_high,
             i_served_high,
             pc_reg_word,
             served_window_native_high,
             no_buffer_accepts_served_last,
             is_compressed_for_pc_advance,
             use_instr_buffer_for_coverage_timing,
             i_fence_i_flush,
             use_instr_buffer}
        )) begin
      p_served_low_last_word_contract :
      assert (i_served_last_word_low == (i_served_word_low + 1'b1));
      p_served_low_prev_word_contract :
      assert (i_served_prev_word_low == (i_served_word_low - 1'b1));
      p_served_low_prev_valid_contract :
      assert (i_served_prev_word_valid_low == (|i_served_word_low));
      p_served_high_last_word_contract :
      assert (i_served_last_word_high == (i_served_word_high + 1'b1));
      p_served_high_prev_word_contract :
      assert (i_served_prev_word_high == (i_served_word_high - 1'b1));
      p_served_high_prev_valid_contract :
      assert (i_served_prev_word_valid_high == (|i_served_word_high));
      p_served_provider_selectors_aligned :
      assert (i_instr_pc_metadata_served_high == i_served_high);
      p_served_low_coverage_equivalent :
      assert (served_window_covers_low == served_window_covers_low_reference);
      p_served_high_coverage_equivalent :
      assert (served_window_covers_high == served_window_covers_high_reference);
      p_no_buffer_served_last_verdict_is_observationally_exact :
      assert (use_instr_buffer_for_coverage_timing ||
              (no_buffer_accepts_served_last ==
               (!pc_reg[1] || is_compressed_for_pc_advance)));
      p_served_window_guard_equivalent :
      assert (served_window_covers_pc_reg == served_window_covers_reference);
      p_coverage_buffer_select_matches_packet_outside_fence :
      assert (i_fence_i_flush || (use_instr_buffer_for_coverage_timing == use_instr_buffer));
    end
  end
`endif

  logic window_cannot_serve_pc_reg;
  // Declared here for the low-BRAM arm below, which excludes saved-replay
  // cycles; defined with the stall-capture logic.
  logic replay_saved_if_outputs;
  // The guard covers both providers: a low-BRAM window can be stale too
  // (after early recovery, for example). The aligner's bank parity only tells
  // even words from odd ones, so it cannot see a slip by an even number of
  // words, and only this word compare catches it. A mismatch squashes the
  // packet and resteers fetch to pc_reg's word.
  //
  // The low-BRAM arm must exclude saved-replay cycles: IF then consumes its
  // captured packet while the low presenter withdraws its live window, which
  // may have moved past pc_reg, and guarding the replay would squash the
  // captured instruction and wedge the handshake. The cached provider's arm
  // needs no such exclusion, because that provider holds valid low on those
  // cycles. The arm is chosen by the provider bit, not by pc_reg[31], because
  // under translation the virtual address says nothing about which provider
  // served the window. That bit is the same registered replica that selects
  // the coverage result above, kept cycle-identical to i_served_high by the
  // producer, so synthesis can fold the coverage result and the replay
  // qualification into one LUT6.
  assign window_cannot_serve_pc_reg = i_instr_valid && !served_window_covers_pc_reg &&
      (i_instr_pc_metadata_served_high || !replay_saved_if_outputs);

`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown(
            {window_cannot_serve_pc_reg, prediction_used_for_pc, slot2_prediction_used_for_pc}
        )) begin
      p_noncovering_window_blocks_all_predictions :
      assert (!window_cannot_serve_pc_reg ||
              (!prediction_used_for_pc && !slot2_prediction_used_for_pc));
    end
  end
`endif

  // Every squash condition except the served-window guard.
  logic sel_nop_existing;
  logic sel_nop_existing_wcs0;
  logic sel_nop_existing_wcs;
  assign sel_nop_existing = i_pipeline_ctrl.flush ||
                   flush_for_c_ext_safe || !fetch_progress ||
                   reset_holdoff ||
                   pending_prediction_target_holdoff ||
                   pending_prediction_fetch_holdoff ||
                   (control_flow_holdoff &&
                    (!prediction_holdoff || pd_redirect_q || slot2_redirect_q ||
                     prediction_already_emitted_q));
  // sel_nop_existing with WCS forced to 0. The squash is W | E(W), which
  // equals W | E(0), so E(0) can be built in parallel with the served-window
  // compare and W enters as one final OR, instead of passing through the
  // pending-prediction holdoff logic on its way to the PC advance.
  assign sel_nop_existing_wcs0 = i_pipeline_ctrl.flush ||
                   flush_for_c_ext_safe || !fetch_progress ||
                   reset_holdoff ||
                   pending_prediction_target_holdoff ||
                   pending_prediction_fetch_holdoff_wcs0 ||
                   (control_flow_holdoff &&
                    (!prediction_holdoff || pd_redirect_q || slot2_redirect_q ||
                     prediction_already_emitted_q));
  // sel_nop_existing with WCS forced to 1, built while the served-window
  // compare is still settling, so WCS enters the resteer only as the final
  // AND and the compare stays out of the pending-hold and priority-mux logic.
  assign sel_nop_existing_wcs = i_pipeline_ctrl.flush ||
                   flush_for_c_ext_safe || !fetch_progress ||
                   reset_holdoff ||
                   pending_prediction_target_holdoff ||
                   pending_prediction_fetch_holdoff_wcs ||
                   (control_flow_holdoff &&
                    (!prediction_holdoff || pd_redirect_q || slot2_redirect_q ||
                     prediction_already_emitted_q));

  // Resteer fetch to pc_reg's word, and hold pc_reg, only on a cycle that
  // would otherwise consume the packet. During a holdoff pc_reg is already
  // being managed, and a resteer there would thrash the front end. At a
  // holdoff release with the window still stale (fetch ran ahead during the
  // redirect bubble), this fires on the cycle the wrong-word decode would
  // otherwise advance pc_reg onto a mid-instruction byte.
  logic window_resteer_pc_reg;
  assign window_resteer_pc_reg = window_cannot_serve_pc_reg && !sel_nop_existing_wcs;

  assign sel_nop = sel_nop_existing_wcs0 || window_cannot_serve_pc_reg;

  // The PC-control consumers of the squash (the advance selects and, through
  // pc_controller, the sequential-PC calculator and the halfword catch-up
  // arm) only decide next-PC arms below the trap, xRET, and FENCE-class arms,
  // and every register they reach (the pending prediction, the saved advance
  // selects, the halfword history) clears on a full flush. Their value on a
  // full-flush cycle is therefore a don't-care, so they take a copy of the
  // squash without the full-flush term, which has the longest path into the
  // sequential PC logic. The packet-side consumers keep the complete squash.
  logic flush_pc_control;
  logic sel_nop_existing_pc_control;
  logic pc_control_sel_nop;
  assign flush_pc_control = (i_pipeline_ctrl.flush || flush_for_c_ext_safe) && !i_flush_all;
  assign sel_nop_existing_pc_control = flush_pc_control || !fetch_progress ||
                   reset_holdoff ||
                   pending_prediction_target_holdoff ||
                   pending_prediction_fetch_holdoff_wcs0 ||
                   (control_flow_holdoff &&
                    (!prediction_holdoff || pd_redirect_q || slot2_redirect_q ||
                     prediction_already_emitted_q));
  assign pc_control_sel_nop = sel_nop_existing_pc_control || window_cannot_serve_pc_reg;

`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown(
            {
              i_flush_all,
              sel_nop,
              pc_control_sel_nop,
              i_trap_ctrl.trap_taken,
              i_trap_ctrl.mret_taken,
              i_fence_i_flush
            }
        )) begin
      p_pc_control_sel_nop_exact_unless_kill :
      assert (i_flush_all || (pc_control_sel_nop == sel_nop));
      // The premise: a full-flush cycle is always a trap, xRET, or FENCE-class arm cycle.
      p_full_flush_kill_wins_next_pc :
      assert (!i_flush_all || i_trap_ctrl.trap_taken || i_trap_ctrl.mret_taken || i_fence_i_flush);
    end
  end
`endif

`ifndef SYNTHESIS
  // Every FENCE-class flush also flushes front-end state, so the other squash
  // causes must force a NOP and hide any comparator-driven resteer during the
  // redirect pulse. The served-window comparators' buffer select differs from
  // the packet's only on such a cycle.
  always_ff @(posedge i_clk) begin
    if (!i_pipeline_ctrl.reset && !$isunknown(
            {i_fence_i_flush,
             flush_for_c_ext_safe,
             prediction_used_for_pc,
             slot2_prediction_used_for_pc,
             sel_nop_existing,
             sel_nop_existing_wcs0,
             sel_nop_existing_wcs,
             sel_nop,
             window_resteer_pc_reg}
        )) begin
      p_fence_i_masks_served_window_coverage :
      assert (!i_fence_i_flush ||
              (flush_for_c_ext_safe && sel_nop_existing && sel_nop_existing_wcs0 && sel_nop &&
               !window_resteer_pc_reg && !prediction_used_for_pc &&
               !slot2_prediction_used_for_pc));
      p_sel_nop_wcs0_absorption_exact :
      assert (sel_nop == (sel_nop_existing || window_cannot_serve_pc_reg));
      p_window_resteer_wcs_cofactor_exact :
      assert (window_resteer_pc_reg == (window_cannot_serve_pc_reg && !sel_nop_existing));
    end
  end

  // A consumed low-BRAM packet must be covered by its window. The guard makes
  // this true by construction (it forces sel_nop and resteers), so this check
  // fires only if the guard is weakened. A clean simulation is no reason to
  // drop the synthesized guard: hardware has produced uncovered low-BRAM
  // windows that simulation did not.
  always_ff @(posedge i_clk) begin
    if (served_contract_check_valid_q && !i_pipeline_ctrl.reset && !$isunknown(
            {pc_reg,
             selected_served_word,
             selected_served_last_word,
             sel_nop,
             replay_saved_if_outputs,
             use_instr_buffer,
             i_instr_valid}
        ) && !i_served_high && i_instr_valid && !sel_nop && !replay_saved_if_outputs) begin
      p_bram_served_window_covers_pc_reg :
      assert (served_window_covers_pc_reg)
      else
        $error(
            "if_stage: uncovered BRAM packet: pc=%h served=%h last=%h native_hi=%b buf=%b",
            pc_reg,
            {
              selected_served_word, 2'b00
            },
            {
              selected_served_last_word, 2'b00
            },
            served_window_native_high,
            use_instr_buffer_for_coverage_timing
        );
    end
  end
`endif

  // ===========================================================================
  // Stall State Registers
  // ===========================================================================
  // Raw instruction data is captured when a stall begins and replayed after
  // release, because the BRAM output moves on while IF is stalled.

  logic sel_nop_saved;

  // Stall-capture outputs (muxed: stall_registered ? saved : live)
  logic sel_compressed_sc;

  stall_capture_reg #(
      .WIDTH(16)
  ) u_raw_parcel_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(raw_parcel),
      .o_data(raw_parcel_sc)
  );

  // ===========================================================================
  // 64-bit Spanning Assembly
  // ===========================================================================
  // With 64-bit fetch, both halves of a spanning instruction are available in
  // a single cycle.  When PC[1]=1, the 32-bit candidate is assembled
  // speculatively from the current word's upper half and the next word's
  // lower half.  This is the architecturally selected value for a native
  // instruction.  For an RVC instruction PD builds the instruction from the
  // predecoded fields instead, so the speculative upper half is a don't-care.
  //
  // Do not qualify this mux with is_compressed.  That bit comes from the IMEM
  // predecode sideband, and qualifying the 32-bit candidate with it would put
  // sideband -> assembled_instr -> native branch immediate -> target adder on
  // the D inputs of PD's redirect-target registers. PC[1] is registered and
  // is the only select the native candidate needs.
  //
  // When the instruction buffer is active, the "next word" is the BRAM's
  // current word (the lead word).  When the buffer is inactive, the "next
  // word" is the BRAM's upper 32 bits from the 64-bit fetch.
  logic [31:0] assembled_instr;
  logic [15:0] spanning_second_half;
  // The spanning half is selected by bank_sel_r parity from the 64-bit BRAM
  // output.  The BRAM always holds two consecutive words; the parity check
  // identifies which half holds word(pc_reg[31:2]+1).  This covers both the
  // buffer and non-buffer cases:
  //
  //  - Non-buffer: BRAM is aligned to pc_reg (F=W), next word at i_instr[63:32].
  //  - Buffer: BRAM is at the fetch lead (F≈W+1), next word at i_instr[31:0]
  //    (the lead address was set during the compressed-at-lo cycle).
  //
  // Parity: bank_sel_r == pc_reg[2] → next word at [63:32], bits at [47:32].
  //         bank_sel_r != pc_reg[2] → next word at [31:0],  bits at [15:0].
  assign spanning_second_half = fetch_word_swapped_for_spanning ? i_instr[15:0] : i_instr[47:32];
  assign assembled_instr = pc_reg[1] ?
      {spanning_second_half, effective_instr[31:16]} : effective_instr;

  // Carry only three source bits, {rs2[1], rs1[2:1]}, on the timing-critical
  // low-IMEM/RVC paths. Slot 1 joins the RVC sideband values with the
  // assembled native word here. Slot 2 arrives resolved from
  // instruction_aligner (each fixed candidate makes its compressed/native
  // choice before the late position mux), which keeps a second join off the
  // IMEM-to-PD capture path.
  logic [2:0] source_hot_predecoded_live;
  logic [2:0] source_hot_predecoded_2_live;
  logic [2:0] source_hot_predecoded_saved;
  logic [2:0] source_hot_predecoded_2_saved;
  assign source_hot_predecoded_live = sel_compressed ?
      rvc_source_hot : {assembled_instr[21], assembled_instr[17:16]};
  assign source_hot_predecoded_2_live = source_hot_2;
  // Slot 1's instruction bits [24:20] by the same construction: RVC values
  // come from the sideband, so PD's rs2 path has no decompressor.
  logic [ 4:0] bits24_20_predecoded_live;
  logic [ 2:0] rs1_rest_predecoded_live;
  logic [ 4:0] bits24_20_predecoded_saved;
  logic [ 2:0] rs1_rest_predecoded_saved;
  logic [22:0] rvc_extra_saved;
  logic [ 4:0] bits24_20_predecoded_2_saved;
  logic [ 2:0] rs1_rest_predecoded_2_saved;
  assign bits24_20_predecoded_live = sel_compressed ? rvc_bits24_20 : assembled_instr[24:20];
  assign rs1_rest_predecoded_live = sel_compressed ? rvc_rs1_rest :
      {assembled_instr[19:18], assembled_instr[15]};

  // Capture the narrow values once on stall entry. Apply the replay select
  // only at the packet output so the live source path does not acquire the
  // generic stall-capture mux followed by a second replay mux.
  always_ff @(posedge i_clk) begin
    if (flush_for_c_ext_safe) begin
      source_hot_predecoded_saved   <= '0;
      source_hot_predecoded_2_saved <= '0;
      bits24_20_predecoded_saved    <= '0;
      rs1_rest_predecoded_saved    <= '0;
      rvc_extra_saved <= '0;
      bits24_20_predecoded_2_saved  <= '0;
      rs1_rest_predecoded_2_saved  <= '0;
    end else if (if_stage_stall & ~if_stage_stall_registered) begin
      source_hot_predecoded_saved   <= source_hot_predecoded_live;
      source_hot_predecoded_2_saved <= source_hot_predecoded_2_live;
      bits24_20_predecoded_saved    <= bits24_20_predecoded_live;
      rs1_rest_predecoded_saved    <= rs1_rest_predecoded_live;
      rvc_extra_saved <= rvc_extra;
      bits24_20_predecoded_2_saved  <= bits24_20_2;
      rs1_rest_predecoded_2_saved  <= rs1_rest_2;
    end
  end

`ifndef SYNTHESIS
  // assembled_instr must match the sideband-qualified reference whenever the
  // native value is used. For RVC the packet uses raw_parcel, so this 32-bit
  // value is a don't-care.
  logic [31:0] assembled_instr_legacy;
  always_comb begin
    if (pc_reg[1] && !is_compressed) begin
      assembled_instr_legacy = {spanning_second_half, effective_instr[31:16]};
    end else begin
      assembled_instr_legacy = effective_instr;
    end

    if (!$isunknown(
            {pc_reg[1], is_compressed, spanning_second_half, effective_instr}
        ) && !is_compressed) begin
      p_native_assembly_matches_legacy : assert (assembled_instr == assembled_instr_legacy);
    end
  end
`endif

  stall_capture_reg #(
      .WIDTH(32)
  ) u_assembled_instr_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(assembled_instr),
      .o_data(assembled_instr_sc)
  );

  stall_capture_reg #(
      .WIDTH(1)
  ) u_sel_compressed_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(sel_compressed),
      .o_data(sel_compressed_sc)
  );

  // sel_nop_saved has non-standard flush behavior (flushes to 1'b1, not '0),
  // and is passed to prediction_metadata_tracker, so it stays in a separate
  // always_ff block.
  always_ff @(posedge i_clk) begin
    if (flush_for_c_ext_safe) begin
      sel_nop_saved <= 1'b1;
    end else if (if_stage_stall & ~if_stage_stall_registered) begin
      sel_nop_saved <= sel_nop;
    end
  end

  // Registered to match the data: the prediction redirects PC this cycle and
  // the new fetch data arrives next cycle, when c_ext_state resets.  Slot-2
  // predictions are included so c_ext_state also resets its buffer state
  // across slot-2 BTB redirects; the bubble cycle after a slot-2 prediction
  // has stale BRAM data and the buffer state must not survive the redirect.
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) prediction_reset_c_ext <= 1'b0;
    else prediction_reset_c_ext <= prediction_used || slot2_prediction_used;
  end

`ifndef SYNTHESIS
  // A slot-1 prediction never fires while slot 1 comes from the instruction
  // buffer: prediction_common requires no registered stall and a clear buffer
  // select, and with no registered stall the predictor's copy of the select
  // (use_instr_buffer_for_coverage_timing) equals use_instr_buffer. A redirect
  // therefore never needs to squash a fetch issued behind a buffered word.
  always @(posedge i_clk) begin
    if (!i_pipeline_ctrl.reset && !$isunknown({prediction_used, use_instr_buffer}))
      p_no_prediction_from_buffered_word : assert (!(prediction_used && use_instr_buffer));
  end
`endif

  // Saved IF outputs are replayed only when the stalled cycle carried a real,
  // still-valid instruction.
  assign replay_saved_if_outputs = if_stage_stall_registered &&
                                   !flush_for_c_ext_safe &&
                                   saved_values_valid &&
                                   !sel_nop_saved;

  // Fetch progress: a bundle is being presented for consumption this cycle,
  // either because the provider's live window is valid or because the replay
  // path is presenting the stall-captured bundle (whose data needs no live
  // window).  This, not i_instr_valid alone, is what gates the PC hold arms
  // and the per-delivery state freezes: on the stall-release cycle the
  // replayed bundle is consumed, so freezing there would re-present (and
  // re-dispatch) the same pc_reg on the next live cycle.  Its declaration
  // carries the max_fanout cap and the reason for it.
  assign fetch_progress = i_instr_valid || replay_saved_if_outputs;
  assign o_fetch_live_claim = i_instr_valid && !sel_nop && !if_stage_stall_registered;
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) o_fetch_replay_consume <= 1'b0;
    else o_fetch_replay_consume <= replay_saved_if_outputs && !if_stage_stall;
  end

  // ===========================================================================
  // Outputs to PD Stage
  // ===========================================================================

  assign o_pc = pc;

  // Raw parcel output: replay saved values only when the saved cycle was a real
  // instruction, otherwise use the live post-stall values.
  assign o_from_if_to_pd.raw_parcel = replay_saved_if_outputs ? raw_parcel_sc : raw_parcel;
  // Unused for slot 1: PD takes slot 1's illegal flag from the predecoded
  // sideband (rvc_extra_predecoded).
  assign o_from_if_to_pd.decomp_illegal = 1'b0;

  assign o_from_if_to_pd.sel_nop = replay_saved_if_outputs ? sel_nop_saved : sel_nop;
  assign o_from_if_to_pd.sel_compressed = replay_saved_if_outputs ? sel_compressed_sc :
                                          sel_compressed;

  // Pre-assembled instruction for PD stage (spanning already assembled in IF)
  assign o_from_if_to_pd.effective_instr = replay_saved_if_outputs ? assembled_instr_sc :
                                           assembled_instr;
  assign o_from_if_to_pd.source_hot_predecoded =
      replay_saved_if_outputs ? source_hot_predecoded_saved :
                                source_hot_predecoded_live;
  assign o_from_if_to_pd.bits24_20_predecoded =
      replay_saved_if_outputs ? bits24_20_predecoded_saved : bits24_20_predecoded_live;
  assign o_from_if_to_pd.rvc_extra_predecoded =
      replay_saved_if_outputs ? rvc_extra_saved : rvc_extra;
  assign o_from_if_to_pd.rs1_rest_predecoded =
      replay_saved_if_outputs ? rs1_rest_predecoded_saved : rs1_rest_predecoded_live;

  // Link address (the slot-1 fall-through PC, instruction_pc + 2 for a
  // compressed instruction or + 4 for a 32-bit one) feeding the RAS call
  // push.  ID computes the pipeline link address for JAL/JALR itself from
  // the registered PC and is_compressed, so this sum is not part of the
  // IF→PD packet.
  logic [XLEN-1:0] instruction_pc;
  logic [XLEN-1:0] link_address;

  // link_address must use the real size of the slot-1 instruction held
  // across a stall, so it cannot share sel_compressed_sc: that
  // stall_capture_reg zeroes its capture on a flush, and after a flush inside
  // a stall a held compressed instruction would read as 32-bit, putting its
  // link one halfword too far. This copy is captured without the flush clear,
  // so the held size matches the held instruction (pc_reg + 2 or + 4) and the
  // RAS push address stays right after the flush.
  // sel_compressed_sc's other consumers (o_from_if_to_pd.sel_compressed,
  // slot2_pc_sc) are not replayed after a flush (sel_nop_saved is 1), so the
  // zeroing is harmless there.
  logic is_compressed_for_link;
  logic sel_compressed_for_link_sc;
  stall_capture_reg #(
      .WIDTH(1)
  ) u_sel_compressed_for_link_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(1'b0),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(sel_compressed),
      .o_data(sel_compressed_for_link_sc)
  );
  assign is_compressed_for_link = sel_compressed_for_link_sc;

  assign instruction_pc = pc_reg;
  assign link_address = instruction_pc + (is_compressed_for_link ?
                        riscv_pkg::PcIncrementCompressed : riscv_pkg::PcIncrement32bit);

  stall_capture_reg #(
      .WIDTH(XLEN)
  ) u_instruction_pc_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(instruction_pc),
      .o_data(instruction_pc_sc)
  );

  stall_capture_reg #(
      .WIDTH(XLEN)
  ) u_link_address_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(link_address),
      .o_data(link_address_sc)
  );

  // Keep the instruction PC aligned with the same stall-replayed instruction
  // data that PD consumes.
  assign o_from_if_to_pd.program_counter = replay_saved_if_outputs ? instruction_pc_sc :
                                           instruction_pc;

  // ===========================================================================
  // Fetch-fault tags
  // ===========================================================================
  // The served window's per-word fault flags ({fault, page} for window words
  // 0 and 1) map onto the aligner's current and next word the same way the
  // instruction bytes do. The current word is the buffer's (whose flags were
  // captured with it), else window word 1 when the fetch lead is one word
  // ahead (bank parity swapped), else word 0; the next word follows the
  // spanning-half select (word 0 when swapped, word 1 otherwise).
  //
  // Slot 1 faults on its current word, or on the next word only when a 32-bit
  // instruction in the upper halfword straddles into it; the fault is then on
  // the second halfword (fetch_fault_hi: xtval = PC + 2). Slot 2 faults on its
  // own parcel's word, plus the next word whenever its position reads it
  // (every shape except a compressed slot 2 in the current word's upper
  // half); a native slot 2 straddling out of the current word's upper half is
  // its "hi" case. With translation off, this reduces to the PMA check of the
  // packet PC plus a straddle into an unmapped word. The flags are captured at
  // stall entry like every other IF output, so a replayed packet carries the
  // flags it was tagged with.
  assign cur_fault_pair = use_instr_buffer ? instr_buffer_fault :
      (fetch_word_swapped_for_spanning ? {i_instr_fault1, i_instr_fault1_page} :
                                         {i_instr_fault0, i_instr_fault0_page});
  assign next_fault_pair = fetch_word_swapped_for_spanning ?
      {i_instr_fault0, i_instr_fault0_page} : {i_instr_fault1, i_instr_fault1_page};

  logic slot1_straddles;  // 32-bit slot 1 at the upper halfword: consumes the next word
  assign slot1_straddles = pc_reg[1] && !is_compressed;
  logic [2:0] fetch_fault_live;  // {fault, page, hi}
  always_comb begin
    if (cur_fault_pair[1]) fetch_fault_live = {1'b1, cur_fault_pair[0], 1'b0};
    else if (slot1_straddles && next_fault_pair[1])
      fetch_fault_live = {1'b1, next_fault_pair[0], 1'b1};
    else fetch_fault_live = 3'b000;
  end

  logic [2:0] fetch_fault_sc;
  stall_capture_reg #(
      .WIDTH(3)
  ) u_fetch_fault_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(fetch_fault_live),
      .o_data(fetch_fault_sc)
  );

  logic [2:0] fetch_fault_effective;
  assign fetch_fault_effective = replay_saved_if_outputs ? fetch_fault_sc : fetch_fault_live;
  assign o_from_if_to_pd.fetch_fault = fetch_fault_effective[2];
  assign o_from_if_to_pd.fetch_fault_page = fetch_fault_effective[1];
  assign o_from_if_to_pd.fetch_fault_hi = fetch_fault_effective[0];

`ifndef SYNTHESIS
  // With translation off, the fault flag must equal the PMA check of the
  // packet PC whenever the packet is real, not replayed, and its current word
  // came from the live window rather than the buffer. A straddle into an
  // unmapped word is the one extra fault case, so it is excluded.
  always_ff @(posedge i_clk) begin
    if (!i_pipeline_ctrl.reset && !i_fetch_translation_active && i_instr_valid && !sel_nop &&
        !replay_saved_if_outputs && !use_instr_buffer && !slot1_straddles && !$isunknown(
            {fetch_fault_live, pc_reg, i_instr_fault0, i_instr_fault1}
        )) begin
      p_bare_fetch_fault_matches_pma :
      assert (fetch_fault_live[2] == !riscv_pkg::pma_fetch_ok(pc_reg))
      else
        $error(
            "if_stage: Bare fetch-fault tag %0d disagrees with PMA(pc_reg=%h)",
            fetch_fault_live[2],
            pc_reg
        );
    end
  end
`endif

  // ===========================================================================
  // Return Address Stack Operation and Recovery Point
  // ===========================================================================
  // PD takes IF's packets on an unstalled cycle and drops them on a flush or a
  // PD redirect; only a packet PD takes moves the stack, so a squashed or
  // replayed packet never pushes or pops twice. A packet whose used prediction
  // came from a BTB entry typed as a call pushes its link address, one typed
  // as a return pops, and a coroutine swap does both. At most one packet of a
  // bundle can: an instruction predicted taken ends the bundle.
  //
  // The branch predictor reads the stack top for a typed lookup. A packet
  // accepted in the same cycle as a younger typed lookup could leave that
  // lookup a stale top, but no younger lookup's prediction survives such a
  // cycle: registered slot-1 metadata implies the prediction holdoff, a
  // pending-prediction handoff blocks prediction, a stall replay comes with
  // the registered stall, a slot-2 prediction kills the same-cycle slot-1
  // prediction, and a collapsed-lead packet carries its own lookup (checked
  // below).
  //
  // The stack's registered state is both packets' recovery point: their own
  // operation lands on this edge. It does not change while IF stalls, so a
  // stall-replayed packet carries the state it was first presented with.
  logic ras_packet_accepted;
  logic ras_op_slot1;
  logic ras_op_slot2;
  logic [XLEN-1:0] slot2_link_address;
  assign ras_packet_accepted = !if_stage_stall && !i_pipeline_ctrl.flush && !i_pd_redirect;
  assign ras_op_slot1 = ras_packet_accepted && o_from_if_to_pd.btb_predicted_taken &&
                        (slot1_packet_is_call || slot1_packet_is_return);
  assign ras_op_slot2 = ras_packet_accepted && o_from_if_to_pd_2.btb_predicted_taken &&
                        (slot2_packet_is_call || slot2_packet_is_return);
  assign slot2_link_address = o_from_if_to_pd_2.program_counter +
      (o_from_if_to_pd_2.sel_compressed ? riscv_pkg::PcIncrementCompressed :
                                          riscv_pkg::PcIncrement32bit);
  assign ras_push = (ras_op_slot1 && slot1_packet_is_call) ||
                    (ras_op_slot2 && slot2_packet_is_call);
  assign ras_pop = (ras_op_slot1 && slot1_packet_is_return) ||
                   (ras_op_slot2 && slot2_packet_is_return);
  assign ras_push_address = ras_op_slot2 ? slot2_link_address : link_address_sc;

`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_pipeline_ctrl.reset && !$isunknown(
            {ras_op_slot1, ras_op_slot2, live_prediction_emits_with_output,
             prediction_used, slot2_prediction_used}
        )) begin
      p_ras_one_operation_per_bundle : assert (!(ras_op_slot1 && ras_op_slot2));
      p_ras_operation_has_no_younger_live_prediction :
      assert (!(ras_op_slot1 && !live_prediction_emits_with_output &&
                prediction_used && !slot2_prediction_used));
    end
  end
`endif

  // Output-NOP selection follows the same stall replay as the packet fields.
  logic sel_nop_effective;
  assign sel_nop_effective = replay_saved_if_outputs ? sel_nop_saved : sel_nop;

  // Capture the direction bit and index across stall replay (like the RAS
  // checkpoint above) so the carried direction stays with its instruction.
  // While a taken prediction is pending, one other real instruction can be
  // emitted: the compressed instruction just before the pending branch,
  // released by pc_controller's immediate-predecessor exception. The edge
  // that arms the pending prediction overwrites branch_prediction_controller's
  // registered snapshot with the branch's own lookup, so the predecessor's bit
  // and index are saved on every unstalled delivery edge while nothing is
  // pending. A pending prediction can arm only on such an edge, so this
  // capture needs no late arm qualifier. The saved index can differ from the
  // one the emitted PC would give, so it stays paired with the saved bit
  // rather than being recomputed.
  logic bp_dir_taken_aligned;
  logic [riscv_pkg::BpDirIdxBits-1:0] bp_dir_idx_aligned;
  // A high-half served-window recovery deliberately looks up the containing
  // word's low parcel while the architectural packet remains at pc_reg=P+2.
  // No P+2 direction row is available on that cycle, so conservatively attach
  // not-taken to the real packet and carry its own index for later training.
  // Using either the P or P+6 snapshot would train a neighboring predictor row.
  assign bp_dir_taken_aligned = fetch_lookup_is_lower_parcel ? 1'b0 :
      (lookup_pc_matches_packet_pc ? bp_dir_taken_live_cofactor : bp_dir_taken);
  assign bp_dir_idx_aligned = fetch_lookup_is_lower_parcel ?
      pc_reg[riscv_pkg::BpDirIdxBits:1] :
      (lookup_pc_matches_packet_pc ? bp_dir_idx_live : bp_dir_idx);
`ifndef SYNTHESIS
  logic bp_dir_taken_aligned_legacy;
  assign bp_dir_taken_aligned_legacy = fetch_lookup_is_lower_parcel ? 1'b0 :
      (lookup_pc_matches_packet_pc ? bp_dir_taken_live : bp_dir_taken);
  always_comb begin
    if (!$isunknown({bp_dir_taken_aligned, bp_dir_taken_aligned_legacy})) begin
      p_live_direction_output_cofactor_is_exact :
      assert (bp_dir_taken_aligned == bp_dir_taken_aligned_legacy);
    end
  end
`endif
  logic bp_dir_taken_before_pending_q;
  logic [riscv_pkg::BpDirIdxBits-1:0] bp_dir_idx_before_pending_q;
  always_ff @(posedge i_clk) begin
    if (!if_stage_stall && fetch_progress && !pending_prediction_active) begin
      bp_dir_taken_before_pending_q <= bp_dir_taken_aligned;
      bp_dir_idx_before_pending_q   <= bp_dir_idx_aligned;
    end
  end
  logic pending_prediction_metadata_owner;
  logic pending_prediction_metadata_predecessor;
  logic pending_prediction_real_nonowner;
  // Classify the packet by its PC, not by the metadata tracker's taken bit.
  // That bit is output payload that depends on collapsed-lead handling, and
  // feeding it back here would put that whole variable-latency path ahead of
  // the direction bits and the PD redirect. A check below confirms that the
  // pending branch, when emitted, always carries taken metadata. The saved
  // direction is used only for the immediate predecessor; another check
  // confirms that it is the only other real instruction emitted while a
  // prediction is pending.
  assign pending_prediction_metadata_owner =
      pending_prediction_active && !sel_nop_effective &&
      (o_from_if_to_pd.program_counter == pending_prediction_pc);
  assign pending_prediction_metadata_predecessor =
      pending_prediction_active && !sel_nop_effective &&
      (o_from_if_to_pd.program_counter == pending_prediction_prev_pc);
  assign pending_prediction_real_nonowner =
      pending_prediction_active && !sel_nop_effective &&
      !pending_prediction_metadata_owner;
  logic bp_dir_taken_pending_aligned;
  // The direction is payload: PD discards it for bubbles through its
  // registered inject_nop, and replay never presents a saved NOP, so this
  // select does not need the late sel_nop.
  assign bp_dir_taken_pending_aligned = (pending_prediction_active &&
      o_from_if_to_pd.program_counter == pending_prediction_prev_pc) ?
      bp_dir_taken_before_pending_q : bp_dir_taken_aligned;
  logic bp_dir_taken_sc;
  stall_capture_reg #(
      .WIDTH(1)
  ) u_bp_dir_taken_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(bp_dir_taken_pending_aligned),
      .o_data(bp_dir_taken_sc)
  );

`ifndef SYNTHESIS
  logic bp_dir_taken_pending_legacy, bp_dir_taken_legacy_sc;
  logic bp_dir_taken_legacy_output;
  assign bp_dir_taken_pending_legacy = pending_prediction_metadata_predecessor ?
      bp_dir_taken_before_pending_q : bp_dir_taken_aligned;
  stall_capture_reg #(
      .WIDTH(1)
  ) u_bp_dir_taken_legacy_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(bp_dir_taken_pending_legacy),
      .o_data(bp_dir_taken_legacy_sc)
  );
  assign bp_dir_taken_legacy_output = replay_saved_if_outputs ?
      bp_dir_taken_legacy_sc : bp_dir_taken_pending_legacy;
  always @(posedge i_clk) begin
    if (!i_pipeline_ctrl.reset && !o_from_if_to_pd.sel_nop)
      assert (o_from_if_to_pd.bp_dir_taken == bp_dir_taken_legacy_output);
  end
`endif

  // Capture the slot-1 predict-time index across stall replay, like the
  // direction bit above.
  //
  // A taken prediction can redirect fetch while pc_reg still has older
  // compressed instructions to emit. prediction_metadata_tracker keeps the
  // branch's BTB metadata off the immediate predecessor and attaches it only
  // when the pending PC itself is emitted. The pending branch's index is
  // recomputed from pending_prediction_pc and the predecessor's comes from the
  // snapshot saved before the prediction armed; branch_prediction_controller's
  // registered snapshot has been overwritten in both cases.
  logic [riscv_pkg::BpDirIdxBits-1:0] bp_dir_idx_pending_aligned;
  assign bp_dir_idx_pending_aligned = pending_prediction_metadata_owner ?
      pending_prediction_pc[riscv_pkg::BpDirIdxBits:1] :
      (pending_prediction_metadata_predecessor ? bp_dir_idx_before_pending_q : bp_dir_idx_aligned);
  logic [riscv_pkg::BpDirIdxBits-1:0] bp_dir_idx_sc;
  stall_capture_reg #(
      .WIDTH(riscv_pkg::BpDirIdxBits)
  ) u_bp_dir_idx_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(bp_dir_idx_pending_aligned),
      .o_data(bp_dir_idx_sc)
  );
  // Slot-2 predict-time index (combinational from the slot-2 lookup PC), captured
  // on stall entry like the other slot-2 metadata.
  logic [riscv_pkg::BpDirIdxBits-1:0] bp_dir_idx_2_sc;
  stall_capture_reg #(
      .WIDTH(riscv_pkg::BpDirIdxBits)
  ) u_bp_dir_idx_2_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(bp_dir_idx_2),
      .o_data(bp_dir_idx_2_sc)
  );

  // Recovery point: the registered stack state (see the stack operation
  // block above).
  assign o_from_if_to_pd.ras_checkpoint_tos = ras_checkpoint_tos;
  assign o_from_if_to_pd.ras_checkpoint_valid_count = ras_checkpoint_valid_count;
  // Bimodal direction carried with the slot-1 instruction (replay-aware). A
  // collapsed-lead delivery (pc == pc_reg) uses the live lookup, including
  // for a branch without a taken BTB prediction that PD may then redirect on.
  assign o_from_if_to_pd.bp_dir_taken = replay_saved_if_outputs ? bp_dir_taken_sc :
                                        bp_dir_taken_pending_aligned;
  // Predict-time index carried with the slot-1 instruction (replay-aware).
  assign o_from_if_to_pd.bp_dir_idx = replay_saved_if_outputs ? bp_dir_idx_sc :
                                      bp_dir_idx_pending_aligned;

  // ===========================================================================
  // Prediction Metadata Tracker
  // ===========================================================================
  // Carries the BTB prediction metadata across stalls.  When the output is a
  // NOP (holdoff) it clears prediction validity; the target payload is not
  // cleared and is ignored while taken is low.  Otherwise it uses the
  // registered prediction with stall handling, except that a collapsed-lead
  // packet takes the metadata of its own live lookup.

  prediction_metadata_tracker #(
      .XLEN(XLEN)
  ) prediction_metadata_tracker_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      .i_stall(if_stage_stall),
      // Flush with registered trap and xRET terms; see flush_for_c_ext_safe.
      .i_flush(flush_for_c_ext_safe),
      // A flush or redirect, or pc_reg passing the pending PC, kills the
      // pending prediction without a handoff, and the tracker's saved metadata
      // for it must die too (see o_pending_prediction_redirect_kill in
      // pc_controller).
      .i_pending_prediction_kill(pending_prediction_redirect_kill),
      .i_stall_registered(if_stage_stall_registered),

      // Registered prediction from branch_prediction_controller
      .i_prediction_used_r(prediction_used_r),
      .i_predicted_target_r(btb_predicted_target_r),
      .i_predicted_is_call_r(btb_predicted_is_call_r),
      .i_predicted_is_return_r(btb_predicted_is_return_r),
      // Pending metadata belongs to one exact instruction. The effective
      // output PC follows the same live/stall-replay mux as the packet itself.
      .i_pending_prediction_active(pending_prediction_active),
      .i_pending_prediction_pc(pending_prediction_pc),
      .i_output_pc(o_from_if_to_pd.program_counter),
      .i_live_prediction_for_output(live_prediction_emits_with_output),
      // Read only by the tracker's assertions, which check that a live target
      // comes from the lookup aligned with the packet; it does not gate the
      // synthesized target path, and hit/taken still decide validity.
      .i_live_target_aligned_with_output(lookup_pc_matches_packet_pc),
      .i_live_predicted_target(btb_predicted_target),
      .i_live_predicted_is_call(btb_predicted_is_call),
      .i_live_predicted_is_return(btb_predicted_is_return),
      .i_pending_prediction_fetch_holdoff(pending_prediction_fetch_holdoff),
      .i_pending_prediction_target_handoff(pending_prediction_target_handoff),

      // Instruction type signals
      .i_sel_nop(sel_nop),
      .i_sel_nop_saved(sel_nop_saved),
      .i_use_saved_values(replay_saved_if_outputs),

      // Outputs to PD stage
      .o_btb_predicted_taken(o_from_if_to_pd.btb_predicted_taken),
      .o_btb_predicted_target(o_from_if_to_pd.btb_predicted_target),
      .o_btb_predicted_is_call(slot1_packet_is_call),
      .o_btb_predicted_is_return(slot1_packet_is_return)
  );

`ifndef SYNTHESIS
  logic bp_dir_taken_before_pending_valid_q;
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) bp_dir_taken_before_pending_valid_q <= 1'b0;
    else if (!pending_prediction_active)
      bp_dir_taken_before_pending_valid_q <= !if_stage_stall && fetch_progress;
  end

  // pc_controller may consume a pending prediction only on a real packet at
  // the pending PC. The BTB metadata tracker and the direction-index recovery
  // above both rely on this; in particular, a served-window mismatch must
  // retry rather than consume the branch as a NOP.
  always_ff @(posedge i_clk) begin
    if (!i_pipeline_ctrl.reset && pending_prediction_target_handoff && !$isunknown(
            {sel_nop_effective, o_from_if_to_pd.program_counter,
             pending_prediction_pc, if_stage_stall}
        )) begin
      p_pending_prediction_handoff_has_exact_real_owner :
      assert (!sel_nop_effective &&
              o_from_if_to_pd.program_counter == pending_prediction_pc &&
              !if_stage_stall);
    end
    if (!i_pipeline_ctrl.reset && pending_prediction_real_nonowner && !$isunknown(
            {bp_dir_taken_before_pending_valid_q, bp_dir_idx_before_pending_q,
             o_from_if_to_pd.program_counter, pending_prediction_pc}
        )) begin
      p_pending_prediction_only_real_nonowner_is_predecessor :
      assert (o_from_if_to_pd.program_counter ==
              pending_prediction_pc - riscv_pkg::PcIncrementCompressed);
      p_pending_prediction_predecessor_direction_was_captured :
      assert (bp_dir_taken_before_pending_valid_q);
    end
    if (!i_pipeline_ctrl.reset && pending_prediction_active && !sel_nop_effective &&
        (o_from_if_to_pd.program_counter == pending_prediction_pc) && !$isunknown(
            o_from_if_to_pd.btb_predicted_taken
        )) begin
      p_pending_prediction_real_owner_has_taken_metadata :
      assert (o_from_if_to_pd.btb_predicted_taken);
    end

    if (!i_pipeline_ctrl.reset && pending_prediction_active && slot2_valid && !$isunknown(
            {o_from_if_to_pd_2.program_counter, pending_prediction_pc}
        )) begin
      p_pending_prediction_owner_never_dispatches_in_slot2 :
      assert (o_from_if_to_pd_2.program_counter != pending_prediction_pc);
    end

    // The timing-only slot-2 candidate selects are formed before the full
    // packet-valid gate. If one suppresses a live slot-1 lookup while
    // prediction is otherwise enabled, either slot 2 really exists or the
    // pending-prediction one-wide rule is withholding it. Stall replay and
    // the registered F/H/R squashes fall outside prediction_common, and there
    // the live aligner may differ from the saved packet.
    if (!i_pipeline_ctrl.reset && !$isunknown(
            {
              branch_prediction_controller_inst.slot1_prediction_owned_by_slot2,
              slot2_prediction_valid,
              branch_prediction_controller_inst.prediction_common,
              pending_prediction_kills_live_slot2,
              pending_prediction_owns_live_slot1,
              pending_prediction_owns_live_slot2,
              pc,
              pc_reg,
              pending_prediction_pc
            }
        )) begin
      p_unemitted_slot2_candidate_owner_is_masked_or_pending :
      assert (!branch_prediction_controller_inst.slot1_prediction_owned_by_slot2 ||
              slot2_prediction_valid ||
              !branch_prediction_controller_inst.prediction_common ||
              pending_prediction_kills_live_slot2);
      if (branch_prediction_controller_inst.slot1_prediction_owned_by_slot2 &&
          branch_prediction_controller_inst.prediction_common &&
          !slot2_prediction_valid) begin
        p_unemitted_enabled_slot2_candidate_has_exact_pending_owner :
        assert ($onehot(
            {pending_prediction_owns_live_slot1, pending_prediction_owns_live_slot2}
        ) && ((pending_prediction_owns_live_slot1 && (pc_reg == pending_prediction_pc)) ||
              (pending_prediction_owns_live_slot2 && (pc == pending_prediction_pc))));
      end
    end

    if (!i_pipeline_ctrl.reset && !$isunknown(
            {
              pending_prediction_owns_live_slot2,
              pending_prediction_active,
              sel_nop_2_aligner,
              is_compressed,
              pc_reg,
              pending_prediction_pc
            }
        )) begin
      p_pending_prediction_slot2_owner_predecode_exact :
      assert (pending_prediction_owns_live_slot2 ==
              (pending_prediction_active && !sel_nop_2_aligner &&
               ((pc_reg + (is_compressed ? riscv_pkg::PcIncrementCompressed :
                                           riscv_pkg::PcIncrement32bit)) ==
                pending_prediction_pc)));
    end

    if (!i_pipeline_ctrl.reset && pending_prediction_kills_live_slot2 && !$isunknown(
            {
              sel_nop_2,
              slot2_valid_for_pc_live_effective,
              pc_advance_sel_run_live,
              pc_advance_sel_base_live
            }
        )) begin
      p_pending_owner_slot2_kill_is_one_wide_everywhere :
      assert (sel_nop_2 && !slot2_valid_for_pc_live_effective &&
              (pc_advance_sel_run_live == pc_advance_sel_base_live));
    end

    if (!i_pipeline_ctrl.reset && pending_prediction_target_handoff && !$isunknown(
            slot2_valid
        )) begin
      p_pending_owner_handoff_is_single_width : assert (!slot2_valid);
    end
  end
`endif

  // ===========================================================================
  // Slot-2 IF→PD packet.
  // ===========================================================================
  // Slot 2 follows slot 1 sequentially in program order: its PC is slot 1's
  // plus the slot-1 size. A slot-2 prediction from a BTB entry typed as a
  // call or return moves the return address stack like a slot-1 one, and
  // both slots share one recovery point (see below).
  //
  // Stall handling mirrors slot 1's stall_capture_reg pattern: during a stall
  // the window moves on, so the values captured at stall entry are replayed
  // until release (gated by replay_saved_if_outputs). sel_nop_2_saved flushes
  // to 1 like sel_nop_saved. sel_nop_2 already includes slot 1's sel_nop, the
  // pending-prediction one-wide kill, and the aligner's pairing decision:
  // slot 1's AllowsSlot2After and slot 2's Slot2StartValid sideband bits,
  // whether slot 2 fits the window, and the aligner's stale-next-word gate
  // (slot2_bram_unsafe).

  logic [15:0] raw_parcel_2_saved;
  logic [31:0] effective_instr_2_sc;
  logic        sel_compressed_2_sc;
  logic        sel_nop_2_saved;
  logic        slot2_decomp_illegal_sc;

  // Slot-2's raw parcel is retained for stall replay; PD decodes the
  // aligner's expanded effective_instr and expands the raw parcel only in
  // simulation, as its reference. Keep only a saved register here and let the
  // final replay mux below select it; the generic stall_capture_reg would add
  // an unnecessary live-data mux before the replay mux.
  always_ff @(posedge i_clk) begin
    if (flush_for_c_ext_safe) begin
      raw_parcel_2_saved <= '0;
    end else if (if_stage_stall & ~if_stage_stall_registered) begin
      raw_parcel_2_saved <= raw_parcel_2;
    end
  end

  stall_capture_reg #(
      .WIDTH(32)
  ) u_effective_instr_2_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(effective_instr_2),
      .o_data(effective_instr_2_sc)
  );

  stall_capture_reg #(
      .WIDTH(1)
  ) u_sel_compressed_2_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(sel_compressed_2),
      .o_data(sel_compressed_2_sc)
  );

  stall_capture_reg #(
      .WIDTH(1)
  ) u_slot2_decomp_illegal_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(slot2_decomp_illegal),
      .o_data(slot2_decomp_illegal_sc)
  );

  // Mirror sel_nop_saved: flush forces 1, stall-entry latches the live value.
  always_ff @(posedge i_clk) begin
    if (flush_for_c_ext_safe) begin
      sel_nop_2_saved <= 1'b1;
    end else if (if_stage_stall & ~if_stage_stall_registered) begin
      sel_nop_2_saved <= sel_nop_2;
    end
  end

  // Bundle advance = slot-1 size + slot-2 size: {RVC,RVC}=+4, {RVC,32b} and
  // {32b,RVC}=+6, {32b,32b}=+8.
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] bundle_advance_sel_live;
  always_comb begin
    unique case ({
      is_compressed_for_pc_advance, slot2_is_compressed_for_pc_live
    })
      2'b11:   bundle_advance_sel_live = riscv_pkg::PcAdvancePlus4;
      2'b10:   bundle_advance_sel_live = riscv_pkg::PcAdvancePlus6;
      2'b01:   bundle_advance_sel_live = riscv_pkg::PcAdvancePlus6;
      default: bundle_advance_sel_live = riscv_pkg::PcAdvancePlus8;
    endcase
  end

  // The squash (pc_control_sel_nop) is the latest input of these selects (it
  // carries the flush, the holdoffs, and the served-window check), so the
  // selects are also exported for squash = 0 ("run") and squash = 1 ("nop").
  // pc_increment_calculator steers every candidate mux with both and applies
  // the squash as its final 2:1, keeping it out of the value path; the merged
  // selects feed the stall captures and the simulation reference.
  assign pc_advance_sel_base_live = is_compressed_for_pc_advance ? riscv_pkg::PcAdvancePlus2 :
                                                                   riscv_pkg::PcAdvancePlus4;
  assign pc_advance_sel_run_live = slot2_valid_for_pc_live_effective ? bundle_advance_sel_live :
                                                                       pc_advance_sel_base_live;
  assign pc_fetch_advance_sel_live =
      pc_control_sel_nop ? pc_advance_sel_base_live : pc_advance_sel_run_live;
  assign pc_reg_advance_sel_live =
      pc_control_sel_nop ? riscv_pkg::PcAdvancePlus2 : pc_advance_sel_run_live;

  // Save the PC-only bundle metadata directly at stall entry.  Reconstructing
  // it from the replayed PD packet (`sel_compressed_2_sc`) would put the
  // general slot-2 aligner mux back on the fetch-PC path even when the replay
  // arm is inactive.
  always_ff @(posedge i_clk) begin
    if (flush_for_c_ext_safe) begin
      pc_fetch_advance_sel_saved <= riscv_pkg::PcAdvancePlus2;
      pc_reg_advance_sel_saved   <= riscv_pkg::PcAdvancePlus2;
    end else if (if_stage_stall & ~if_stage_stall_registered) begin
      pc_fetch_advance_sel_saved <= pc_fetch_advance_sel_live;
      pc_reg_advance_sel_saved   <= pc_reg_advance_sel_live;
    end
  end

  assign pc_fetch_advance_sel =
      replay_saved_if_outputs ? pc_fetch_advance_sel_saved : pc_fetch_advance_sel_live;
  assign pc_reg_advance_sel =
      replay_saved_if_outputs ? pc_reg_advance_sel_saved : pc_reg_advance_sel_live;
  // The run and nop selects under the same replay select: on a replay cycle
  // both equal the saved select, so the final squash 2:1 does not matter
  // there.
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_fetch_advance_sel_run, pc_fetch_advance_sel_nop;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_reg_advance_sel_run, pc_reg_advance_sel_nop;
  assign pc_fetch_advance_sel_run =
      replay_saved_if_outputs ? pc_fetch_advance_sel_saved : pc_advance_sel_run_live;
  assign pc_fetch_advance_sel_nop =
      replay_saved_if_outputs ? pc_fetch_advance_sel_saved : pc_advance_sel_base_live;
  assign pc_reg_advance_sel_run =
      replay_saved_if_outputs ? pc_reg_advance_sel_saved : pc_advance_sel_run_live;
  assign pc_reg_advance_sel_nop =
      replay_saved_if_outputs ? pc_reg_advance_sel_saved : riscv_pkg::PcAdvancePlus2;

  // Slot-2 PC = slot-1 PC + slot-1 size.  Use the stall-replayed slot-1 PC so
  // slot-2's PC stays aligned with slot-1's even across stall boundaries.
  logic [XLEN-1:0] slot2_pc_live;
  assign slot2_pc_live   = instruction_pc +
                           (is_compressed ? riscv_pkg::PcIncrementCompressed :
                                            riscv_pkg::PcIncrement32bit);

  logic [XLEN-1:0] slot2_pc_sc;
  assign slot2_pc_sc   = instruction_pc_sc +
                         (sel_compressed_sc ? riscv_pkg::PcIncrementCompressed :
                                              riscv_pkg::PcIncrement32bit);

  // Slot-2 IF→PD packet assembly.
  assign o_from_if_to_pd_2.raw_parcel = replay_saved_if_outputs ? raw_parcel_2_saved : raw_parcel_2;
  assign o_from_if_to_pd_2.decomp_illegal = replay_saved_if_outputs ? slot2_decomp_illegal_sc :
                                            slot2_decomp_illegal;
  assign o_from_if_to_pd_2.sel_nop = replay_saved_if_outputs ? sel_nop_2_saved : sel_nop_2;
  assign o_from_if_to_pd_2.sel_compressed = replay_saved_if_outputs ? sel_compressed_2_sc :
                                            sel_compressed_2;
  // Derive slot2_valid from the replay-aware output, not the live aligner.
  assign slot2_valid = !o_from_if_to_pd_2.sel_nop;
  assign o_from_if_to_pd_2.effective_instr = replay_saved_if_outputs ? effective_instr_2_sc :
                                             effective_instr_2;
  assign o_from_if_to_pd_2.source_hot_predecoded =
      replay_saved_if_outputs ? source_hot_predecoded_2_saved :
                                source_hot_predecoded_2_live;
  assign o_from_if_to_pd_2.bits24_20_predecoded =
      replay_saved_if_outputs ? bits24_20_predecoded_2_saved : bits24_20_2;
  assign o_from_if_to_pd_2.rvc_extra_predecoded = '0;
  assign o_from_if_to_pd_2.rs1_rest_predecoded =
      replay_saved_if_outputs ? rs1_rest_predecoded_2_saved : rs1_rest_2;
  assign o_from_if_to_pd_2.program_counter = replay_saved_if_outputs ? slot2_pc_sc : slot2_pc_live;
  // Slot-2 fault tag (see the slot-1 block): current word, plus the next
  // word for every position that reads it.
  logic slot2_cur_hi_compressed;  // compressed slot 2 entirely in the current word
  logic slot2_cur_hi_native;  // native slot 2 straddling current[31:16] / next[15:0]
  assign slot2_cur_hi_compressed = !use_instr_buffer && !pc_reg[1] && is_compressed &&
      is_compressed_2;
  assign slot2_cur_hi_native = !use_instr_buffer && !pc_reg[1] && is_compressed && !is_compressed_2;
  logic [2:0] fetch_fault_2_live;  // {fault, page, hi}
  always_comb begin
    if (cur_fault_pair[1]) fetch_fault_2_live = {1'b1, cur_fault_pair[0], 1'b0};
    else if (!slot2_cur_hi_compressed && next_fault_pair[1])
      fetch_fault_2_live = {1'b1, next_fault_pair[0], slot2_cur_hi_native};
    else fetch_fault_2_live = 3'b000;
  end

  logic [2:0] fetch_fault_2_sc;
  stall_capture_reg #(
      .WIDTH(3)
  ) u_fetch_fault_2_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(fetch_fault_2_live),
      .o_data(fetch_fault_2_sc)
  );

  logic [2:0] fetch_fault_2_effective;
  assign fetch_fault_2_effective = replay_saved_if_outputs ? fetch_fault_2_sc : fetch_fault_2_live;
  assign o_from_if_to_pd_2.fetch_fault = fetch_fault_2_effective[2];
  assign o_from_if_to_pd_2.fetch_fault_page = fetch_fault_2_effective[1];
  assign o_from_if_to_pd_2.fetch_fault_hi = fetch_fault_2_effective[0];

  // Slot 2 has its own staged BTB lookup. Its block-RAM outputs are registered
  // from the same one-cycle-ahead request that launches the instruction RAM;
  // tag qualification and metadata remain combinational in the cycle slot 2
  // is in IF, so no extra fetch cycle is added (unlike slot 1's
  // prediction_used_r, which aligns a current-request lookup with later data).
  // Stall replay uses the values captured at stall start like the rest of the
  // slot-2 packet.
  //
  // predicted_taken is stamped only when the slot-2 prediction redirected
  // fetch (slot2_prediction_used).  A BTB hit whose counter says not-taken
  // leaves it 0, which matches fetch staying on the sequential path.  Branch
  // resolution then flags a direction or target mismatch.
  logic            slot2_predicted_taken_sc;
  logic [XLEN-1:0] slot2_predicted_target_sc;

  stall_capture_reg #(
      .WIDTH(1)
  ) u_slot2_predicted_taken_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(slot2_predicted_taken),
      .o_data(slot2_predicted_taken_sc)
  );

  stall_capture_reg #(
      .WIDTH(XLEN)
  ) u_slot2_predicted_target_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(slot2_predicted_target),
      .o_data(slot2_predicted_target_sc)
  );

  // Clear the slot-2 taken flag when slot 2 is a NOP.
  logic slot2_sel_nop_effective;
  assign slot2_sel_nop_effective = replay_saved_if_outputs ? sel_nop_2_saved : sel_nop_2;
  assign o_from_if_to_pd_2.btb_predicted_taken = slot2_sel_nop_effective ? 1'b0 :
                                     (replay_saved_if_outputs ? slot2_predicted_taken_sc :
                                      slot2_predicted_taken);
  assign o_from_if_to_pd_2.btb_predicted_target = replay_saved_if_outputs ?
                                                  slot2_predicted_target_sc :
                                                  slot2_predicted_target;
  // Types of the entry behind the slot-2 target, for the stack operation.
  logic [1:0] slot2_predicted_kind_sc;
  stall_capture_reg #(
      .WIDTH(2)
  ) u_slot2_predicted_kind_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data({slot2_predicted_is_call, slot2_predicted_is_return}),
      .o_data(slot2_predicted_kind_sc)
  );
  assign slot2_packet_is_call = replay_saved_if_outputs ? slot2_predicted_kind_sc[1] :
                                                          slot2_predicted_is_call;
  assign slot2_packet_is_return = replay_saved_if_outputs ? slot2_predicted_kind_sc[0] :
                                                            slot2_predicted_is_return;

  // Return address stack metadata: slot 2 shares slot 1's recovery point.
  // Slot 1 cannot push or pop when slot 2 is valid: an instruction predicted
  // taken ends the bundle.
  assign o_from_if_to_pd_2.ras_checkpoint_tos = o_from_if_to_pd.ras_checkpoint_tos;
  assign o_from_if_to_pd_2.ras_checkpoint_valid_count = o_from_if_to_pd.ras_checkpoint_valid_count;
  // The PD redirect heuristic does not use slot 2, so its direction bit is a
  // benign 0.  Its predict-time index is carried, so a slot-2-fetched branch
  // trains the entry it predicted.
  assign o_from_if_to_pd_2.bp_dir_taken = 1'b0;
  assign o_from_if_to_pd_2.bp_dir_idx = replay_saved_if_outputs ? bp_dir_idx_2_sc : bp_dir_idx_2;

  // ===========================================================================
  // Slot-1 Control Classification and Width-Funnel Events (IF→PD boundary)
  // ===========================================================================
  // deliver1/deliver2 pulse exactly once per accepted handoff: PD's input
  // registers only advance on !stall cycles, so gating on !if_stage_stall
  // counts each delivered bundle once (stall-held cycles do not recount; the
  // stall-release replay cycle is the accepted delivery).  The kill causes
  // ride the same stall-capture/replay muxing as the slot-2 packet, so they
  // always classify the bundle PD received. The native/compressed control
  // taps additionally provide the frontend tracker's exact slot-1 class.
  logic [5:0] slot2_kill_causes_live;
  logic [5:0] slot2_kill_causes_sc;
  logic [5:0] slot2_kill_causes_effective;
  assign slot2_kill_causes_live = {
    slot2_kill_transient_live,
    slot2_kill_window_limit_live,
    slot2_kill_class_live,
    slot2_kill_slot1_ctrl_live,
    slot2_kill_s1_native_serialize_live,
    slot2_kill_s1_native_ctrl_live
  };

  stall_capture_reg #(
      .WIDTH(6)
  ) u_slot2_kill_causes_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(slot2_kill_causes_live),
      .o_data(slot2_kill_causes_sc)
  );

  assign slot2_kill_causes_effective = replay_saved_if_outputs ? slot2_kill_causes_sc :
                                                                 slot2_kill_causes_live;

  // Indices 0 and 2 are native and compressed slot-1 control flow. The taps
  // classify slot 1 even when no slot 2 is deliverable; the replay-aware
  // slot-1 sel_nop masks invalid IF output.
  logic slot1_native_control_flow_effective;
  logic slot1_compressed_control_flow_effective;
  assign slot1_native_control_flow_effective = slot2_kill_causes_effective[0];
  assign slot1_compressed_control_flow_effective = slot2_kill_causes_effective[2];
  assign o_slot1_has_control_flow = !o_from_if_to_pd.sel_nop &&
                                    (slot1_native_control_flow_effective ||
                                     slot1_compressed_control_flow_effective);

  logic width_deliver1;
  logic width_deliver2;
  logic width_slot2_killed;
  assign width_deliver1 = !if_stage_stall && !o_from_if_to_pd.sel_nop;
  assign width_deliver2 = width_deliver1 && !o_from_if_to_pd_2.sel_nop;
  assign width_slot2_killed = width_deliver1 && o_from_if_to_pd_2.sel_nop;

  // The width-funnel taps are registered here, before they leave for the perf
  // aggregator, so the observer logic cannot share LUTs with the slot-2 kill
  // and redirect logic it taps. These bits feed only free-running counters,
  // so a uniform one-cycle delay changes no count and keeps the deliver/kill
  // split consistent. The flops sit after the stall-replay alignment
  // (slot2_kill_causes_effective, width_slot2_killed), so each event is still
  // attributed to the right bundle.
  riscv_pkg::if_width_events_t width_events_q;
  always_ff @(posedge i_clk) begin
    width_events_q.deliver1 <= width_deliver1;
    width_events_q.deliver2 <= width_deliver2;
    width_events_q.kill_s1_native_ctrl <= width_slot2_killed && slot2_kill_causes_effective[0];
    width_events_q.kill_s1_native_serialize <= width_slot2_killed && slot2_kill_causes_effective[1];
    width_events_q.kill_slot1_ctrl <= width_slot2_killed && slot2_kill_causes_effective[2];
    width_events_q.kill_class <= width_slot2_killed && slot2_kill_causes_effective[3];
    width_events_q.kill_window_limit <= width_slot2_killed && slot2_kill_causes_effective[4];
    width_events_q.kill_transient <= width_slot2_killed && slot2_kill_causes_effective[5];
    // Slot-2 BTB predicted-taken accepted (already !stall-qualified inside
    // branch_prediction_controller, so it pulses once per event).  Each
    // occurrence costs one fetch bubble, which slot2_redirect_q marks on the
    // following cycle.
    width_events_q.slot2_pred_taken <= slot2_prediction_used;
  end
  assign o_width_events = width_events_q;

`ifdef FROST_DEBUG_FETCH_ILA
  // Fetch ILA probes (build.py --debug-ila): mark_debug copies for the debug
  // core; nothing here feeds the design. The low 16 address bits are enough
  // because the capture is keyed on a page offset.
  (* mark_debug = "true" *) logic [15:0] dbg_ila_if_pc_reg;
  (* mark_debug = "true" *) logic [15:0] dbg_ila_if_pc;
  (* mark_debug = "true" *) logic dbg_ila_if_instr_valid;
  (* mark_debug = "true" *) logic dbg_ila_if_fetch_progress;
  (* mark_debug = "true" *) logic dbg_ila_if_sel_nop;
  (* mark_debug = "true" *) logic dbg_ila_if_use_instr_buffer;
  (* mark_debug = "true" *) logic dbg_ila_if_replay_saved;
  (* mark_debug = "true" *) logic dbg_ila_if_control_flow_holdoff;
  (* mark_debug = "true" *) logic dbg_ila_if_prediction_holdoff;
  (* mark_debug = "true" *) logic dbg_ila_if_prediction_used;
  (* mark_debug = "true" *) logic dbg_ila_if_ras_op;
  (* mark_debug = "true" *) logic dbg_ila_if_pending_prediction_active;
  (* mark_debug = "true" *) logic dbg_ila_if_flush;
  (* mark_debug = "true" *) logic dbg_ila_if_stall;
  (* mark_debug = "true" *) logic dbg_ila_if_frontend_state_flush;
  (* mark_debug = "true" *) logic dbg_ila_if_pd_redirect;
  (* mark_debug = "true" *) logic dbg_ila_if_covers;
  (* mark_debug = "true" *) logic dbg_ila_if_cannot_serve;
  (* mark_debug = "true" *) logic [1:0] dbg_ila_if_cur_fault_pair;
  (* mark_debug = "true" *) logic [1:0] dbg_ila_if_next_fault_pair;
  (* mark_debug = "true" *) logic [2:0] dbg_ila_if_fetch_fault_effective;
  (* mark_debug = "true" *) logic dbg_ila_if_instr_fault0;
  (* mark_debug = "true" *) logic dbg_ila_if_instr_fault1;
  (* mark_debug = "true" *) logic [13:0] dbg_ila_if_served_word_high;
  (* mark_debug = "true" *) logic dbg_ila_if_bank_sel;
  (* mark_debug = "true" *) logic [31:0] dbg_ila_if_instr_buffer;
  (* mark_debug = "true" *) logic [15:0] dbg_ila_if_pd_pc;
  (* mark_debug = "true" *) logic [31:0] dbg_ila_if_pd_instr;
  (* mark_debug = "true" *) logic dbg_ila_if_pd_sel_nop;
  (* mark_debug = "true" *) logic dbg_ila_if_pd_fetch_fault;
  (* mark_debug = "true" *) logic dbg_ila_if_pd_fetch_fault_hi;
  (* mark_debug = "true" *) logic [15:0] dbg_ila_if_pd2_pc;
  (* mark_debug = "true" *) logic dbg_ila_if_pd2_sel_nop;
  (* mark_debug = "true" *) logic dbg_ila_if_pd2_fetch_fault;
  assign dbg_ila_if_pc_reg = pc_reg[15:0];
  assign dbg_ila_if_pc = o_pc[15:0];
  assign dbg_ila_if_instr_valid = i_instr_valid;
  assign dbg_ila_if_fetch_progress = fetch_progress;
  assign dbg_ila_if_sel_nop = sel_nop;
  assign dbg_ila_if_use_instr_buffer = use_instr_buffer;
  assign dbg_ila_if_replay_saved = replay_saved_if_outputs;
  assign dbg_ila_if_control_flow_holdoff = control_flow_holdoff;
  assign dbg_ila_if_prediction_holdoff = prediction_holdoff;
  assign dbg_ila_if_prediction_used = prediction_used;
  assign dbg_ila_if_ras_op = ras_push || ras_pop;
  assign dbg_ila_if_pending_prediction_active = pending_prediction_active;
  assign dbg_ila_if_flush = i_pipeline_ctrl.flush;
  assign dbg_ila_if_stall = i_pipeline_ctrl.stall;
  assign dbg_ila_if_frontend_state_flush = i_frontend_state_flush;
  assign dbg_ila_if_pd_redirect = i_pd_redirect;
  assign dbg_ila_if_covers = served_window_covers_pc_reg;
  assign dbg_ila_if_cannot_serve = window_cannot_serve_pc_reg;
  assign dbg_ila_if_cur_fault_pair = cur_fault_pair;
  assign dbg_ila_if_next_fault_pair = next_fault_pair;
  assign dbg_ila_if_fetch_fault_effective = fetch_fault_effective;
  assign dbg_ila_if_instr_fault0 = i_instr_fault0;
  assign dbg_ila_if_instr_fault1 = i_instr_fault1;
  assign dbg_ila_if_served_word_high = i_served_word_high[13:0];
  assign dbg_ila_if_bank_sel = i_instr_bank_sel_r;
  assign dbg_ila_if_instr_buffer = instr_buffer;
  assign dbg_ila_if_pd_pc = o_from_if_to_pd.program_counter[15:0];
  assign dbg_ila_if_pd_instr = o_from_if_to_pd.effective_instr;
  assign dbg_ila_if_pd_sel_nop = o_from_if_to_pd.sel_nop;
  assign dbg_ila_if_pd_fetch_fault = o_from_if_to_pd.fetch_fault;
  assign dbg_ila_if_pd_fetch_fault_hi = o_from_if_to_pd.fetch_fault_hi;
  assign dbg_ila_if_pd2_pc = o_from_if_to_pd_2.program_counter[15:0];
  assign dbg_ila_if_pd2_sel_nop = o_from_if_to_pd_2.sel_nop;
  assign dbg_ila_if_pd2_fetch_fault = o_from_if_to_pd_2.fetch_fault;
`endif


endmodule : if_stage
