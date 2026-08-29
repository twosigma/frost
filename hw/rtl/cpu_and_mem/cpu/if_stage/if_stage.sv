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
 * First in-order front-end stage. pc_controller selects the next PC;
 * branch_prediction handles the BTB, direction predictor, RAS, and metadata;
 * c_extension aligns parcels and tracks the instruction buffer; the
 * instruction MMU (mmu/immu, Phase 3 M5) translates the fetch PC into the
 * physical window addresses the seam presents beside the virtual o_pc.
 *
 * Slot 1 stays compressed until PD, keeping decompression off the memory path.
 * Slot 2 is decompressed here from fixed candidates before its position mux.
 * OOO branch resolution redirects through i_from_ex_comb.
 */
module if_stage #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic i_clk,
    input riscv_pkg::from_ex_comb_t i_from_ex_comb,
    // Captured early-recovery PC/outcome bypass the selected BTB-update mux for
    // the parallel early counter RMW.  i_from_ex_comb remains the only write
    // transaction and therefore retains all update-source priority semantics.
    input logic i_btb_early_update_active,
    input logic [XLEN-1:0] i_btb_early_update_pc,
    input logic i_btb_early_update_taken,
    // Independently selected lower-priority counter-RMW candidate.  It never
    // controls an actual BTB write.
    input logic [XLEN-1:0] i_btb_late_update_pc,
    input logic i_btb_late_update_taken,
    input logic [63:0] i_instr,  // 64-bit fetch: {next_word, current_word}
    input logic [riscv_pkg::ImemFetchSidebandWidth-1:0] i_instr_sideband,
    // PC-only metadata replica. Each fetched word is ordered as
    // {pairable_native_hi, pairable_compressed_hi, compressed_hi, compressed_lo}.
    input logic [7:0] i_instr_pc_metadata,
    // Raw timing replicas in {cached odd, cached even, BRAM odd, BRAM even}
    // provider/parity order.  The aligner selects the active lane directly.
    input logic [15:0] i_instr_pc_metadata_by_provider_parity,
    input logic [7:0] i_pc_pairability_by_provider_parity,
    input logic [3:0] i_slot2_start_valid_lo_by_provider_parity,
    input logic i_instr_pc_metadata_served_high,
    input logic [1:0] i_instr_hi_rd_is_x2,  // {next,current} high-parcel predicates
    input logic i_instr_bank_sel_r,  // Fetch-word parity (PC[2] from fetch cycle)
    // Provider-local 30-bit word tags for the 32-bit fetch seam. S+1 and S-1
    // are registered beside S, keeping both address arithmetic and the wide
    // provider mux outside the live PC coverage cone.
    input logic [29:0] i_served_word_low,
    input logic [29:0] i_served_last_word_low,
    input logic [29:0] i_served_prev_word_low,
    input logic i_served_prev_word_valid_low,
    input logic [29:0] i_served_word_high,
    input logic [29:0] i_served_last_word_high,
    input logic [29:0] i_served_prev_word_high,
    input logic i_served_prev_word_valid_high,
    // Fetch window valid: the {i_instr, i_instr_sideband,
    // i_instr_pc_metadata, i_instr_hi_rd_is_x2,
    // i_instr_bank_sel_r} window
    // corresponds to the fetch address presented last cycle.  When low
    // (variable-latency provider: L1I miss / fuzz), IF emits NOP bubbles,
    // PC and all per-delivery front-end state freeze, and the provider keeps
    // working on the owed fetch address; backend redirects still land.  The
    // low-BRAM path ties this 1, reducing every gate below to today's logic.
    input logic i_instr_valid,
    // Fetch-fault status of the served window's two words (Phase 3 M5:
    // {fault, page kind} per word), registered with the payload exactly
    // like i_instr_bank_sel_r; consumed only under i_instr_valid.
    input logic i_instr_fault0,
    input logic i_instr_fault0_page,
    input logic i_instr_fault1,
    input logic i_instr_fault1_page,
    // The served window came from the cached-tier provider (which withholds
    // valid across stalls) rather than the always-valid low BRAM -- the
    // served-window guard's arm selector.
    input logic i_served_high,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::trap_ctrl_t i_trap_ctrl,
    // Full frontend-state flush; the producer guarantees this covers every
    // i_fence_i_flush pulse as well as trap/MRET/mispredict recovery.
    input logic i_frontend_state_flush,
    // Registered FENCE-class frontend flush (FENCE.I, SFENCE.VMA, or
    // translation-affecting CSR serialization), plumbed to pc_controller.
    input logic i_fence_i_flush,
    input logic [XLEN-1:0] i_fence_i_target,
    // Branch prediction control (for verification - prevents BTB predictions)
    input logic i_disable_branch_prediction,
    // Bimodal direction-predictor training (from commit, conditional branches
    // only).  Forwarded to the branch_prediction_controller; trains at commit PC.
    input logic i_dir_update_valid,
    input logic [riscv_pkg::BpDirIdxBits-1:0] i_dir_update_idx,
    input logic i_dir_update_taken,
    // PD backward-branch heuristic redirect (from pd_stage)
    input logic i_pd_redirect,
    input logic [XLEN-1:0] i_pd_redirect_target,
    output logic [XLEN-1:0] o_pc,
    // REGISTERED: the stall-release cycle one cycle ago consumed the
    // stall-captured replay bundle (no live window needed).  The fetch
    // provider only needs this for served-vs-redirect classification of the
    // PC movement it observes -- which it evaluates one cycle later anyway --
    // so the export is registered to keep the late stall cone out of the
    // provider's combinational ask/address paths.  The owed-ask VALUE needs
    // no correction: o_pc is frozen at the owed ask through any stall a
    // replay bundle can survive (redirects kill the replay capture).
    output logic o_fetch_replay_consume,
    // Phase 3 M5 fetch translation -- the physical side of the fetch seam.
    // o_pc stays the VIRTUAL fetch address (the providers tag and match
    // windows by it); these shadows (mmu/immu) carry the window's two
    // physical word addresses, their validity (low while an ITLB miss or a
    // page-crossing second page resolves -- the front end stalls meanwhile)
    // and fault status, identity-timed with o_pc.
    output logic [31:0] o_fetch_pa0,
    output logic [31:0] o_fetch_pa1,
    output logic o_fetch_pa_valid,
    output logic o_fetch_fault0,
    output logic o_fetch_fault0_page,
    output logic o_fetch_fault1,
    output logic o_fetch_fault1_page,
    output logic o_fetch_line_after_ok,
    // Registered pulse: a trap, xRET, or FENCE-class redirect (FENCE.I,
    // SFENCE.VMA, or a translation-affecting CSR write) landed at the last
    // edge. The translation state may
    // have changed with it, so the provider re-latches its owed ask from
    // the live pc/PA pair even when the target VA equals the old ask.
    output logic o_fetch_redirect,
    // The fetch PC's translation is unresolved: the front end must stall
    // (cpu_ooo folds this into pipeline_ctrl.stall). Registered.
    output logic o_fetch_pa_hold,
    // Translation state (csr_file, combinational) and the walker seam.
    input logic i_fetch_translation_active,
    input logic i_fetch_priv_u,
    input logic i_tlb_invalidate,
    output logic o_walk_req_valid,
    input logic i_walk_req_ready,
    output logic [riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,
    input logic i_walk_resp_valid,
    input riscv_pkg::ptw_resp_t i_walk_resp,
    output riscv_pkg::from_if_to_pd_t o_from_if_to_pd,
    // Slot-2 IF→PD packet. When slot 2 is invalid
    // this cycle (slot-1 is a NOP/branch, slot-2 doesn't fit, etc.), sel_nop is
    // asserted and PD/ID propagate it as a NOP so dispatch sees i_valid_2='0.
    output riscv_pkg::from_if_to_pd_t o_from_if_to_pd_2,
    // 2-wide width-funnel profiling events at the IF→PD boundary (perf
    // counters only; see if_width_events_t).  Pulses once per accepted
    // handoff; kill causes are replay-exact via the stall-capture path.
    // REGISTERED at this boundary (one cycle after the observed handoff) so
    // the perf taps cannot fuse into the slot-2-redirect/next-PC cone.
    output riscv_pkg::if_width_events_t o_width_events
);

  // ===========================================================================
  // Signal Declarations - Grouped by Submodule Interface
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // Branch Prediction Controller Interface (branch_prediction_controller)
  // ---------------------------------------------------------------------------
  logic btb_predicted_taken;  // Combinational: BTB hit with taken prediction
  logic [XLEN-1:0] btb_predicted_target;  // Combinational: Predicted target address
  logic prediction_used_r;  // Registered: Prediction was applied
  logic [XLEN-1:0] btb_predicted_target_r;  // Registered: Target for pipeline alignment
  logic prediction_used;  // Current prediction being used
  logic prediction_used_for_pc;  // Stall-ungated PC mux select
  logic prediction_holdoff;  // Block prediction (stale data)
  logic btb_only_prediction_holdoff;  // Holdoff when BTB (not RAS) predicted - instr valid
  logic ras_prediction_holdoff;  // Holdoff when RAS predicted - next instr is stale
  logic disable_branch_prediction_effective;  // Also suppress predictions
  logic disable_branch_prediction_effective_wcs0;  // ... its raw-WCS cofactors
  logic disable_branch_prediction_effective_wcs;
  // during pending halfword redirect handoff
  logic sel_prediction_r;  // Select registered prediction target
  logic prediction_requires_pc_reg_handoff;  // Predicted op must still reach IF/PD/ID
  logic control_flow_to_halfword_pred;  // Prediction targets halfword address

  // Slot-2 dual-port BTB prediction signals.
  logic slot2_btb_hit;
  logic slot2_predicted_taken;
  logic [XLEN-1:0] slot2_predicted_target;
  logic slot2_prediction_used;
  logic slot2_prediction_used_for_pc;

  // RAS (Return Address Stack) signals
  logic ras_predicted;  // RAS prediction was used
  logic [XLEN-1:0] ras_predicted_target;  // RAS predicted return address
  logic [riscv_pkg::RasPtrBits-1:0] ras_checkpoint_tos;  // TOS checkpoint
  logic [riscv_pkg::RasPtrBits:0] ras_checkpoint_valid_count;  // Valid count checkpoint

  // Lever A: decoupled bimodal direction prediction, carried with each slot-1 op
  // to PD so the PD redirect can fire on a BTB miss.
  logic bp_dir_taken;
  // Lever A: predict-time bimodal index (slot-1 + slot-2), carried to commit for
  // training so the entry trained matches the entry the prediction read.
  logic [riscv_pkg::BpDirIdxBits-1:0] bp_dir_idx;
  logic [riscv_pkg::BpDirIdxBits-1:0] bp_dir_idx_2;

  // ---------------------------------------------------------------------------
  // PC Controller Interface (pc_controller)
  // ---------------------------------------------------------------------------
  logic [XLEN-1:0] pc;  // Current program counter (fetch address)
  logic [XLEN-1:0] pc_reg;  // Registered PC (instruction address)
  logic control_flow_change;  // Branch/jump taken this cycle
  logic control_flow_holdoff;  // Wait cycle after control flow change
  logic control_flow_to_halfword;  // Target address is halfword-aligned
  logic control_flow_to_halfword_r;  // Registered version for timing
  logic reset_holdoff;  // Wait cycle after reset
  logic any_holdoff;  // Any holdoff condition active
  logic any_holdoff_safe;  // Safe holdoff (registered signals only)
  logic mid_32bit_correction;  // Correction for 32-bit at halfword boundary
  logic pending_prediction_active;  // pc_reg still walking old-path instructions
  logic pending_prediction_target_handoff;  // Old-path branch consumed, pc_reg jumps to target
  logic pending_prediction_holdoff;  // Halfword prediction target while pc_reg catches up
  logic pending_prediction_holdoff_wcs0;  // ... raw served-window verdict = 0 cofactor
  logic pending_prediction_holdoff_wcs;  // ... raw served-window verdict = 1 cofactor
  logic pending_prediction_fetch_holdoff;  // Pending redirect phase with stale fetch data
  logic pending_prediction_fetch_holdoff_wcs0;  // Raw-window-mismatch=0 cofactor
  logic pending_prediction_fetch_holdoff_wcs;  // Raw-window-mismatch=1 cofactor
  logic pending_prediction_target_holdoff;  // First target cycle still returns stale data
  logic pending_prediction_redirect_kill;  // Redirect/stale death of the pending fetch state
  logic [XLEN-1:0] next_pc;  // pc_controller's next-pc mux output (immu data path)
  logic next_pc_holds;  // next_pc == pc by mux selection
  logic pc_update_en;  // pc/pc_reg flop enable (immu shadow enable)
  // The selector's arms for the immu: one-hot winner, pc + d arms, early operands.
  logic [riscv_pkg::PcNextArms-1:0] npc_sel;
  logic [riscv_pkg::PcNextArms-1:0] npc_seq;
  logic [riscv_pkg::PcNextArms-1:0][XLEN-1:0] npc_cmp_val;
  logic [riscv_pkg::PcNextArms-1:0][XLEN-1:0] npc_val;
  riscv_pkg::fetch_verdict_t [riscv_pkg::PcNextArms-1:0] npc_seq_verdict;
  logic fetch_pa_valid;  // immu shadow resolved (else the front end stalls)
  logic fetch_fault0_live;  // pc's word-0 fetch fault (immu shadow)

  // ---------------------------------------------------------------------------
  // C-Extension State Interface (c_ext_state)
  // ---------------------------------------------------------------------------
  logic [31:0] instr_buffer;  // Buffered instruction for stall recovery
  logic prev_was_compressed_at_lo;  // Previous instr was compressed at addr[1]=0
  logic is_compressed_for_buffer;  // Stall-restored is_compressed
  logic is_compressed_for_pc;  // Registered is_compressed for PC timing
  logic use_buffer_after_prediction;  // Use buffer after prediction-from-buffer holdoff
  logic use_buffer_after_prediction_timing;  // F=0,H=0,R=0 timing cofactor
  logic use_buffer_after_prediction_edge;  // ... without its prediction_holdoff mask
  logic use_instr_buffer_for_coverage_timing;
  logic is_compressed_saved;  // Saved is_compressed for fast path
  logic saved_values_valid;  // Saved values are valid (not invalidated by control flow)
  logic [riscv_pkg::ImemSidebandWidth-1:0] instr_buffer_sideband;
  logic [1:0] instr_buffer_fault;  // {fault, page kind} captured with the buffered word
  // Fetch-fault status of the aligner's current / next word (M5), mapped
  // from the served window's per-word flags; see the fault-flag block below.
  logic [1:0] cur_fault_pair;  // {fault, page} of the current word
  logic [1:0] next_fault_pair;  // {fault, page} of the next word

  // ---------------------------------------------------------------------------
  // Instruction Aligner Interface (instruction_aligner)
  // ---------------------------------------------------------------------------
  logic [15:0] raw_parcel;  // Selected 16-bit parcel for RVC decompression
  logic [31:0] effective_instr;  // Raw current word (for state machine/buffer)
  logic is_compressed;  // Current instruction is 16-bit compressed
  logic is_compressed_fast;  // Fast path for PC-critical path (registered selects only)
  logic is_compressed_for_pc_advance;  // PC-selector-only timing-replica path
  logic sel_nop;  // Select NOP (during holdoff/flush)
  // TIMING: fetch_progress gates holdoffs, sel_nop, and stall-held CEs
  // across the whole IF stage (the widest post-opt TNS family after the
  // covers-compare fix).  Its inputs are registered; the fanout cap makes
  // synthesis replicate the driver LUT per consumer region.
  (* max_fanout = 32 *)
  logic fetch_progress;  // live window valid OR replay bundle presented
  logic sel_nop_align;
  logic sel_compressed;  // Select compressed instruction path
  logic use_instr_buffer;  // Use buffered instruction
  logic [2:0] rvc_source_hot;

  // Slot-2 outputs from instruction_aligner (2-wide dispatch).
  logic [15:0] raw_parcel_2;
  logic [31:0] effective_instr_2;
  logic slot2_decomp_illegal;
  logic is_compressed_2;
  logic sel_nop_2_aligner;  // raw output from instruction_aligner
  logic sel_nop_2;  // effective: also NOP'd whenever slot-1 NOPs
  logic sel_compressed_2;
  logic [2:0] source_hot_2;
  logic slot2_valid_for_pc_live;
  logic slot2_is_compressed_for_pc_live;
  logic slot2_is_compressed_plus2_for_btb;
  logic slot2_is_compressed_plus4_for_btb;
  logic slot2_plus2_candidate_valid;
  logic slot2_plus4_candidate_valid;
  logic slot2_plus2_candidate_valid_timing;
  logic slot2_plus4_candidate_valid_timing;
  logic slot2_valid_for_pc_saved;
  logic slot2_is_compressed_for_pc_saved;
  logic slot2_valid_for_pc;
  logic slot2_is_compressed_for_pc;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_fetch_advance_sel_live;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_fetch_advance_sel_saved;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_fetch_advance_sel;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_reg_advance_sel_live;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_reg_advance_sel_saved;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_reg_advance_sel;
  logic slot1_is_branch;
  logic slot2_valid;  // matches the OUTPUT slot-2 valid sent to PD/dispatch
  logic slot2_prediction_valid;  // live-only valid for same-cycle slot-2 BTB lookup
  logic slot2_redirect_q;  // One-cycle bubble after slot-2 BTB redirect.
  // Slot 2 must NOP whenever slot 1 NOPs. IF's full sel_nop
  // covers control_flow_holdoff, pending-prediction holdoffs, reset_holdoff,
  // and flush — all conditions where the live BRAM data may not match
  // pc_reg's word and the alignment math is unreliable for slot-2.  The
  // aligner's narrow o_sel_nop (= sel_nop_align) only covers mid-32bit and
  // the prediction holdoffs, missing the rest.
  assign sel_nop_2 = sel_nop_2_aligner || sel_nop;
  // pc_controller and c_ext_state must see the same slot-2
  // valid that PD/dispatch see.  During stall replay the live aligner gate
  // can disagree with the saved sel_nop_2_saved (the gate uses live BRAM
  // which has drifted, while saved was captured at stall start when BRAM
  // was correct).  pc_controller's slot2_valid had been hardwired to the
  // live !sel_nop_2; combined with is_compressed_fast (saved-aware) and
  // is_compressed_2 (live), pc_inc could pick the wrong bundle advance
  // (e.g., 32b+RVC=+6) and land pc_reg on a mid-instruction byte.  Using
  // the OUTPUT slot-2 valid keeps pc_inc consistent with what dispatch
  // sees and forces the 1-wide path whenever the output is NOP.
  assign slot2_prediction_valid = !sel_nop_2;

`ifndef SYNTHESIS
  logic [7:0] instr_pc_metadata_canonical;
  logic [7:0] active_pc_metadata_by_parity;
  logic [7:0] active_pc_metadata_by_parity_canonical;
  logic [3:0] active_pc_pairability_by_parity;
  logic [3:0] active_pc_pairability_by_parity_canonical;
  logic [1:0] active_slot2_start_valid_lo_by_parity;
  logic [1:0] active_slot2_start_valid_lo_by_parity_canonical;
  // Simulation-only legacy selector oracle.  The timing-only fast-size copy
  // may deliberately diverge during a masked cycle, so compare it with the
  // new one-hot identity only in the exact BPC prediction-common domain.
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
            {
              is_compressed_fast,
              slot2_plus2_candidate_valid_timing,
              slot2_plus4_candidate_valid_timing
            }
        )) begin
      p_slot2_candidate_identity_matches_legacy_live_selector :
      assert ({slot2_plus4_candidate_valid_timing,
               slot2_plus2_candidate_valid_timing} ==
              {!is_compressed_fast, is_compressed_fast});
    end
    if (!$isunknown(
            {
              slot2_prediction_valid,
              slot2_plus2_candidate_valid,
              slot2_plus4_candidate_valid,
              slot2_plus2_candidate_valid_timing,
              slot2_plus4_candidate_valid_timing
            }
        )) begin
      p_live_slot2_prediction_candidates_match_canonical :
      assert (!slot2_prediction_valid ||
              ({slot2_plus4_candidate_valid_timing,
                slot2_plus2_candidate_valid_timing} ==
               {slot2_plus4_candidate_valid,
                slot2_plus2_candidate_valid}));
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Derived Signals and Stall State
  // ---------------------------------------------------------------------------
  logic prev_was_compressed_at_lo_saved;  // Saved for stall recovery
  logic ras_instruction_valid;
  logic ras_instruction_valid_live;
  (* keep = "true", max_fanout = 32 *)logic if_stage_stall;
  (* keep = "true", max_fanout = 32 *)logic if_stage_stall_registered;
  (* keep = "true" *)logic pc_controller_stall;

  // TIMING OPTIMIZATION: Pass raw instruction to aligner, not flush-gated.
  // This breaks the timing path: flush -> is_compressed -> pc_increment -> PC.
  // When flush is true, pc_controller selects branch_target anyway, so
  // is_compressed value during flush doesn't affect the PC output.
  // NOP insertion during flush is handled by PD stage, not here.
  // C-extension state updates are already protected by flush checks in c_ext_state.
  // NOTE: i_pd_redirect is intentionally NOT included in disable_branch_prediction
  // to avoid a timing-critical cross-module path.  Wrong-path BTB hits during a
  // PD redirect cycle are cleaned up via redirect_kill_pending_q and pd_redirect_q.
  // Phase 3 M2/M5: suppress every prediction source while a live window
  // is faulted. Garbage bytes (or a false BTB tag hit on a wild PC) must
  // never redirect the front end — the only exit from a faulted window is
  // the FETCH_[PAGE_]FAULT trap (escape-freedom). Translation off keeps
  // M2's VA-domain PMA terms; translation on replaces them with the
  // shadow's verdict for pc and the served window's flags for pc_reg (a
  // translated VA carries no PMA meaning of its own). An unresolved shadow
  // (ITLB miss) is a front-end stall, which already blocks predictions.
  logic pc_pma_bad;
  logic served_fault_any;
  assign served_fault_any = i_instr_valid && (i_instr_fault0 || i_instr_fault1);
  assign pc_pma_bad = (!i_fetch_translation_active && (!riscv_pkg::pma_fetch_ok(
      pc
  ) || !riscv_pkg::pma_fetch_ok(
      pc_reg
  ))) || fetch_fault0_live || served_fault_any;
  assign disable_branch_prediction_effective =
      i_disable_branch_prediction || pending_prediction_holdoff ||
      i_pipeline_ctrl.flush || i_frontend_state_flush || !fetch_progress ||
      pc_pma_bad;
  // The same term under each cofactor of the pending hold, so the branch
  // predictor can take the raw served-window verdict as its last input.
  assign disable_branch_prediction_effective_wcs0 =
      i_disable_branch_prediction || pending_prediction_holdoff_wcs0 ||
      i_pipeline_ctrl.flush || i_frontend_state_flush || !fetch_progress ||
      pc_pma_bad;
  assign disable_branch_prediction_effective_wcs =
      i_disable_branch_prediction || pending_prediction_holdoff_wcs ||
      i_pipeline_ctrl.flush || i_frontend_state_flush || !fetch_progress ||
      pc_pma_bad;
  assign ras_instruction_valid_live = !sel_nop &&
                                      (!prediction_holdoff || btb_only_prediction_holdoff);

  // IF internal state cleanup is allowed to lag the architectural pipeline
  // flush by one cycle. OOO trap/MRET recovery uses this to pay an extra
  // redirect bubble in IF while still flushing PD/ID immediately.
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
  // The bank-select sideband is registered with the fetch window.  High DDR
  // fetches must use fetch_provider's served-window bit, not live pc_reg[2],
  // because redirect/stall windows can briefly put a payload for one ask next
  // to a different live PC.
  assign instr_bank_sel_for_c_ext = i_instr_bank_sel_r;
  assign instr_bank_sel_for_aligner = i_instr_bank_sel_r;
  assign instr_bank_sel_for_spanning = i_instr_bank_sel_r;
  assign fetch_word_swapped_for_c_ext = instr_bank_sel_for_c_ext ^ pc_reg[2];
  assign fetch_word_swapped_for_spanning = instr_bank_sel_for_spanning ^ pc_reg[2];

  // ===========================================================================
  // Branch Prediction Controller
  // ===========================================================================
  // With 64-bit fetch, spanning is eliminated — no spanning detection needed.
  // RAS detection uses the assembled instruction directly.
  logic [31:0] ras_instruction;
  logic [15:0] ras_raw_parcel;
  logic        ras_is_compressed;
  logic        ras_saved_input_available_sc;
  logic        ras_replay_inputs;
  logic        ras_instruction_valid_sc;

  // Forward declarations (moved before first use to avoid Vivado warnings)
  logic        use_saved_values;
  assign use_saved_values = if_stage_stall_registered && saved_values_valid;
  logic            prediction_reset_c_ext;
  logic [    15:0] raw_parcel_sc;
  logic [    31:0] assembled_instr_sc;
  logic [XLEN-1:0] instruction_pc_sc;
  logic [XLEN-1:0] link_address_sc;
  logic            prediction_from_buffer_holdoff;
  logic            prediction_used_from_buffer;

  assign ras_replay_inputs = if_stage_stall_registered && ras_saved_input_available_sc;

  assign ras_instruction = assembled_instr_sc;
  assign ras_raw_parcel = raw_parcel_sc;
  assign ras_is_compressed = ras_replay_inputs ? is_compressed_for_buffer : is_compressed;
  assign ras_instruction_valid = !any_holdoff_safe &&
                                 !i_from_ex_comb.branch_taken &&
                                 !i_trap_ctrl.trap_taken &&
                                 !i_trap_ctrl.mret_taken &&
                                 ras_instruction_valid_sc &&
                                 (!if_stage_stall_registered ||
                                   ras_saved_input_available_sc);
  assign prediction_used_from_buffer = prediction_used && use_instr_buffer;

  // ===========================================================================
  // RAS Input Pipeline Register (Timing Optimization)
  // ===========================================================================
  // Register instruction/validity before the branch_prediction_controller to
  // break the critical path:
  //   mispredict_recovery → flush → control_flow → buffer_select →
  //   ras_instruction → RAS call/return detect → prediction_used → PC
  // This was -1.027ns WNS with 16 LUT levels.  Registering here cuts ~10
  // levels from the chain.
  //
  // Cost: RAS push/pop fires 1 cycle after the instruction appears.  Return
  // predictions are 1 cycle stale.  This is a minor IPC cost; the pending
  // prediction mechanism already handles deferred redirects.  RAS is purely
  // speculative — mispredictions are caught at commit.
  logic [    31:0] ras_instruction_q;
  logic [    15:0] ras_raw_parcel_q;
  logic            ras_is_compressed_q;
  logic            ras_instruction_valid_q;
  logic [XLEN-1:0] link_address_sc_q;

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || flush_for_c_ext_safe) begin
      ras_instruction_valid_q <= 1'b0;
    end else begin
      ras_instruction_q       <= ras_instruction;
      ras_raw_parcel_q        <= ras_raw_parcel;
      ras_is_compressed_q     <= ras_is_compressed;
      ras_instruction_valid_q <= ras_instruction_valid;
      link_address_sc_q       <= link_address_sc;
    end
  end

  // Slot-2 PC candidates for BTB lookup. Slot 2 sits at
  // pc_reg+2 behind an RVC slot-1 and pc_reg+4 behind a native slot-1.  The
  // two BTB replicas store those entries under shifted pc_reg keys, so pc_reg
  // drives both RAM addresses directly.  The aligner's one-hot, valid-qualified
  // shape arms select target/index identity and gate the two independently
  // completed safety results.  Raw slot-1 compression therefore reaches
  // neither the lookup address nor the late BPC result selector.
  logic [XLEN-1:0] slot2_pc_plus2_for_btb;
  logic [XLEN-1:0] slot2_pc_plus4_for_btb;
  assign slot2_pc_plus2_for_btb = pc_reg + riscv_pkg::PcIncrementCompressed;
  assign slot2_pc_plus4_for_btb = pc_reg + riscv_pkg::PcIncrement32bit;

  branch_prediction_controller branch_prediction_controller_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      // In OOO mode, serialization stalls (for unresolved older branches/CSRs)
      // must also block new predictions. Otherwise a younger speculative branch
      // or return can arm a pending redirect that survives long enough to fight
      // with the older instruction's eventual mispredict recovery.
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_fetch_progress(fetch_progress),
      // TIMING OPTIMIZATION: Use safe flush with registered trap/mret signals
      .i_flush(flush_for_c_ext_safe),
      // PD redirect kills in-flight slot-1 prediction metadata (see module).
      .i_pd_redirect(i_pd_redirect),
      .i_pd_redirect_target(i_pd_redirect_target),

      // Current PC for BTB lookup
      .i_pc(pc),

      // Slot-2 PC for dual-port BTB lookup.
      .i_pc_2(slot2_pc_plus2_for_btb),
      .i_pc_2_alt(slot2_pc_plus4_for_btb),
      .i_pc_2_base(pc_reg),
      .i_slot2_plus2_candidate_valid(slot2_plus2_candidate_valid_timing),
      .i_slot2_plus4_candidate_valid(slot2_plus4_candidate_valid_timing),
      .i_slot2_valid(slot2_prediction_valid),
      .i_slot2_is_compressed_plus2(slot2_is_compressed_plus2_for_btb),
      .i_slot2_is_compressed_plus4(slot2_is_compressed_plus4_for_btb),
      // Candidate-local sizes let BPC qualify +2/+4 in parallel.  Keep the
      // selected live value connected to its old/new equivalence oracle.
      .i_slot2_is_compressed(is_compressed_2),

      // Control signals for prediction gating
      .i_trap_taken(i_trap_ctrl.trap_taken),
      .i_mret_taken(i_trap_ctrl.mret_taken),
      .i_branch_taken(i_from_ex_comb.branch_taken),
      .i_any_holdoff_safe(any_holdoff_safe),
      .i_is_32bit_spanning(1'b0),
      // Exact F=0,H=0,R=0 buffer-select cofactor.  The independent holdoff,
      // flush, and prediction-disable gates make every peeled cycle
      // unobservable while keeping the canonical packet select unchanged.
      .i_use_instr_buffer(use_instr_buffer_for_coverage_timing),
      .i_disable_branch_prediction(disable_branch_prediction_effective),
      .i_disable_branch_prediction_wcs0(disable_branch_prediction_effective_wcs0),
      .i_disable_branch_prediction_wcs(disable_branch_prediction_effective_wcs),
      .i_window_cannot_serve_raw(window_cannot_serve_pc_reg),

      // BTB update interface (from EX stage)
      .i_btb_update(i_from_ex_comb.btb_update),
      .i_btb_update_pc(i_from_ex_comb.btb_update_pc),
      .i_btb_update_target(i_from_ex_comb.btb_update_target),
      .i_btb_update_taken(i_from_ex_comb.btb_update_taken),
      .i_btb_update_compressed(i_from_ex_comb.btb_update_compressed),
      .i_btb_update_requires_pc_reg_handoff(i_from_ex_comb.btb_update_requires_pc_reg_handoff),
      .i_btb_early_update_active,
      .i_btb_early_update_pc,
      .i_btb_early_update_taken,
      .i_btb_late_update_pc,
      .i_btb_late_update_taken,

      // RAS inputs (pipelined — breaks flush → RAS → prediction_used path)
      // Registered versions of the instruction/validity signals.  See
      // "RAS Input Pipeline Register" block above for rationale.
      .i_instruction(ras_instruction_q),
      .i_raw_parcel(ras_raw_parcel_q),
      .i_is_compressed(ras_is_compressed_q),
      .i_instruction_valid(ras_instruction_valid_q),
      .i_link_address(link_address_sc_q),

      // RAS misprediction recovery (from EX stage)
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

      // Combinational prediction outputs (for pc_controller)
      .o_predicted_taken (btb_predicted_taken),
      .o_predicted_target(btb_predicted_target),

      // Registered prediction outputs (for pipeline alignment)
      .o_prediction_used_r (prediction_used_r),
      .o_predicted_target_r(btb_predicted_target_r),

      // Control outputs
      .o_prediction_used(prediction_used),
      .o_prediction_used_for_pc(prediction_used_for_pc),
      .o_prediction_holdoff(prediction_holdoff),
      .o_btb_only_prediction_holdoff(btb_only_prediction_holdoff),
      .o_sel_prediction_r(sel_prediction_r),
      .o_prediction_requires_pc_reg_handoff(prediction_requires_pc_reg_handoff),
      .o_control_flow_to_halfword_pred(control_flow_to_halfword_pred),

      // Slot-2 prediction outputs.
      .o_slot2_prediction_used(slot2_prediction_used),
      .o_slot2_prediction_used_for_pc(slot2_prediction_used_for_pc),
      .o_slot2_btb_hit(slot2_btb_hit),
      .o_slot2_predicted_taken(slot2_predicted_taken),
      .o_slot2_predicted_target(slot2_predicted_target),

      // RAS prediction outputs
      .o_ras_predicted(ras_predicted),
      .o_ras_predicted_target(ras_predicted_target),
      .o_ras_checkpoint_tos(ras_checkpoint_tos),
      .o_ras_checkpoint_valid_count(ras_checkpoint_valid_count),

      // Lever A: decoupled bimodal direction + predict-time index carried to PD
      .o_dir_predicted_taken(bp_dir_taken),
      .o_dir_idx(bp_dir_idx),
      .o_dir_idx_2(bp_dir_idx_2)
  );

  // ===========================================================================
  // PC Controller
  // ===========================================================================
  pc_controller #(
      .XLEN(XLEN)
  ) pc_controller_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      .i_stall(pc_controller_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_fetch_progress(fetch_progress),
      // TIMING OPTIMIZATION: Use safe flush with registered trap/mret signals
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
      .i_is_compressed_for_pc(is_compressed_for_pc),
      // 2-wide bundle metadata.  Drives the +4/+6/+8 PC advance selection inside
      // pc_increment_calculator. Pass the
      // OUTPUT slot-2 valid + is_compressed_2 (= replay-aware via stall
      // capture register), not the live aligner outputs.  This keeps PC
      // inc consistent with what dispatch sees during stall replay.
      .i_slot2_valid(slot2_valid_for_pc),
      .i_slot2_is_compressed(slot2_is_compressed_for_pc),
      .i_pc_fetch_advance_sel(pc_fetch_advance_sel),
      .i_pc_reg_advance_sel(pc_reg_advance_sel),
      .i_pc_fetch_advance_sel_run(pc_fetch_advance_sel_run),
      .i_pc_fetch_advance_sel_nop(pc_fetch_advance_sel_nop),
      .i_pc_reg_advance_sel_run(pc_reg_advance_sel_run),
      .i_pc_reg_advance_sel_nop(pc_reg_advance_sel_nop),

      // Branch prediction (from branch_prediction_controller)
      .i_predicted_taken(btb_predicted_taken),
      .i_predicted_target(btb_predicted_target),
      .i_predicted_target_r(btb_predicted_target_r),
      .i_prediction_used(prediction_used),
      .i_prediction_used_for_pc(prediction_used_for_pc),
      .i_ras_predicted(ras_predicted),
      .i_sel_prediction_r(sel_prediction_r),
      .i_prediction_requires_pc_reg_handoff(prediction_requires_pc_reg_handoff),
      .i_prediction_holdoff(prediction_holdoff),
      .i_prediction_from_buffer_holdoff(prediction_from_buffer_holdoff),
      .i_prediction_used_from_buffer(prediction_used_from_buffer),
      .i_sel_nop(sel_nop),

      // Slot-2 dual-port BTB redirect.
      .i_slot2_prediction_used(slot2_prediction_used),
      .i_slot2_prediction_used_for_pc(slot2_prediction_used_for_pc),
      .i_slot2_predicted_target(slot2_predicted_target),
      .o_slot2_redirect_q(slot2_redirect_q),

      .o_pc(pc),
      .o_pc_reg(pc_reg),
      .o_control_flow_change(control_flow_change),
      .o_control_flow_holdoff(control_flow_holdoff),
      .o_control_flow_to_halfword(control_flow_to_halfword),
      .o_control_flow_to_halfword_r(control_flow_to_halfword_r),
      .o_reset_holdoff(reset_holdoff),
      .o_any_holdoff(any_holdoff),
      .o_any_holdoff_safe(any_holdoff_safe),
      .o_mid_32bit_correction(mid_32bit_correction),
      .o_pending_prediction_active(pending_prediction_active),
      .o_pending_prediction_target_handoff(pending_prediction_target_handoff),
      .o_pending_prediction_holdoff(pending_prediction_holdoff),
      .o_pending_prediction_holdoff_wcs0(pending_prediction_holdoff_wcs0),
      .o_pending_prediction_holdoff_wcs(pending_prediction_holdoff_wcs),
      .o_pending_prediction_fetch_holdoff(pending_prediction_fetch_holdoff),
      .o_pending_prediction_fetch_holdoff_wcs0(pending_prediction_fetch_holdoff_wcs0),
      .o_pending_prediction_fetch_holdoff_wcs(pending_prediction_fetch_holdoff_wcs),
      .o_pending_prediction_target_holdoff(pending_prediction_target_holdoff),
      .o_pending_prediction_redirect_kill(pending_prediction_redirect_kill),
      .o_next_pc(next_pc),
      .o_next_pc_holds(next_pc_holds),
      .o_pc_update_en(pc_update_en),
      .o_npc_sel(npc_sel),
      .o_npc_seq(npc_seq),
      .o_npc_cmp_val(npc_cmp_val),
      .o_npc_val(npc_val),
      .o_npc_seq_verdict(npc_seq_verdict)
  );

  // ===========================================================================
  // Instruction MMU (Phase 3 M5): ITLB + PA shadows on the PC path
  // ===========================================================================
  // The shadows are looked up on next_pc and load with pc, so the seam's
  // physical addresses are identity-timed with the virtual fetch PC; see
  // mmu/immu.sv for the contract (zero hit latency, hold on miss, faults
  // delivered as tagged windows).
  immu #(
      .XLEN(XLEN)
  ) u_immu (
      .i_clk(i_clk),
      .i_rst(i_pipeline_ctrl.reset),
      .i_active(i_fetch_translation_active),
      .i_priv_u(i_fetch_priv_u),
      .i_tlb_invalidate(i_tlb_invalidate),
      .i_pc_update_en(pc_update_en),
      .i_next_pc(next_pc),
      .i_next_pc_holds(next_pc_holds),
      .i_pc(pc),
      .i_npc_sel(npc_sel),
      .i_npc_seq(npc_seq),
      .i_npc_cmp_val(npc_cmp_val),
      .i_npc_val(npc_val),
      .i_npc_seq_verdict(npc_seq_verdict),
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

  // Translation-epoch pulse for the provider's owed-ask PA (see the port).
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) o_fetch_redirect <= 1'b0;
    else o_fetch_redirect <= i_trap_ctrl.trap_taken || i_trap_ctrl.mret_taken || i_fence_i_flush;
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
      // TIMING OPTIMIZATION: Use flush_for_c_ext_safe instead of pipeline_ctrl.flush.
      // This uses registered trap/mret signals to break the critical path from
      // EX stage exception detection through c_ext_state to PC calculation.
      .i_flush(flush_for_c_ext_safe),
      .i_fence_i_flush(i_fence_i_flush),
      .i_stall_registered(if_stage_stall_registered),

      .i_control_flow_holdoff(control_flow_holdoff),
      .i_any_holdoff_safe(any_holdoff_safe),
      .i_prediction_holdoff(prediction_holdoff),
      .i_prediction_reset_state(prediction_reset_c_ext),
      .i_pending_prediction_active(pending_prediction_active),
      .i_pending_prediction_target_handoff(pending_prediction_target_handoff),
      .i_pending_prediction_target_holdoff(pending_prediction_target_holdoff),
      .i_prediction_from_buffer_holdoff(prediction_from_buffer_holdoff),

      .i_effective_instr(effective_instr),
      // Always pass i_instr[63:32] as the next word — this is correct when
      // the BRAM is aligned (bank_sel_r == pc_reg[2]).  When misaligned, the
      // fetch_word_swapped guard inside c_ext_state blocks the update entirely.
      .i_fetch_word_swapped(fetch_word_swapped_for_c_ext),
      .i_pc(pc),
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
      .o_is_compressed_for_buffer(is_compressed_for_buffer),
      .o_is_compressed_for_pc(is_compressed_for_pc),
      .o_use_buffer_after_prediction(use_buffer_after_prediction),
      .o_use_buffer_after_prediction_timing(use_buffer_after_prediction_timing),
      .o_use_buffer_after_prediction_edge(use_buffer_after_prediction_edge),
      .o_is_compressed_saved(is_compressed_saved),
      .o_saved_values_valid(saved_values_valid),
      .o_instr_buffer_sideband(instr_buffer_sideband),
      .i_instr_fault(cur_fault_pair),
      .o_instr_buffer_fault(instr_buffer_fault)
  );

  // ===========================================================================
  // Stall State Preservation
  // ===========================================================================
  // Save prev_was_compressed_at_lo when stall begins

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || flush_for_c_ext_safe || prediction_reset_c_ext) begin
      // Clear on reset or flush - flush invalidates pre-flush state
      // TIMING OPTIMIZATION: Use safe flush with registered trap/mret signals
      prev_was_compressed_at_lo_saved <= 1'b0;
    end else if (if_stage_stall & ~if_stage_stall_registered) begin
      prev_was_compressed_at_lo_saved <= prev_was_compressed_at_lo;
    end
  end

  // ===========================================================================
  // Instruction Aligner
  // ===========================================================================
  // Live slot-2 kill-cause taps from the aligner (width-funnel profiling).
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
      .i_instr_hi_rd_is_x2(i_instr_hi_rd_is_x2),
      .i_instr_bank_sel_r(instr_bank_sel_for_aligner),
      .i_instr_buffer(instr_buffer),
      .i_instr_buffer_sideband(instr_buffer_sideband),
      .i_pc_reg(pc_reg),

      .i_prev_was_compressed_at_lo(prev_was_compressed_at_lo),
      .i_use_buffer_after_prediction(use_buffer_after_prediction),
      .i_use_buffer_after_prediction_timing(use_buffer_after_prediction_timing),

      .i_mid_32bit_correction(mid_32bit_correction),
      // RAS predicts after instruction arrives; next cycle's instruction is stale.
      // BTB predicts before instruction arrives, so we must NOT suppress that cycle.
      .i_prediction_holdoff(ras_prediction_holdoff),
      .i_prediction_from_buffer_holdoff(prediction_from_buffer_holdoff),

      // TIMING OPTIMIZATION: Only use stall_registered (not combinational stall signals)
      // to break critical path from stall → is_compressed → PC
      .i_stall_registered(if_stage_stall_registered),
      .i_prev_was_compressed_at_lo_saved(prev_was_compressed_at_lo_saved),
      .i_is_compressed_saved(is_compressed_saved),
      .i_saved_values_valid(saved_values_valid && !i_fence_i_flush),

      .o_raw_parcel(raw_parcel),
      .o_effective_instr(effective_instr),
      .o_is_compressed(is_compressed),
      .o_is_compressed_fast(is_compressed_fast),
      .o_is_compressed_for_pc_advance(is_compressed_for_pc_advance),
      .o_sel_nop(sel_nop_align),
      .o_sel_compressed(sel_compressed),
      .o_use_instr_buffer(use_instr_buffer),
      .o_rvc_source_hot(rvc_source_hot),

      // Slot-2 outputs. sel_nop_2 already folds in slot-1 sel_nop,
      // slot-1 branch detection, and the doesn't-fit cases.
      .o_raw_parcel_2(raw_parcel_2),
      .o_effective_instr_2(effective_instr_2),
      .o_slot2_decomp_illegal(slot2_decomp_illegal),
      .o_is_compressed_2(is_compressed_2),
      .o_sel_nop_2(sel_nop_2_aligner),
      .o_sel_compressed_2(sel_compressed_2),
      .o_source_hot_2(source_hot_2),
      .o_slot2_valid_for_pc(slot2_valid_for_pc_live),
      .o_slot2_is_compressed_for_pc(slot2_is_compressed_for_pc_live),
      .o_slot2_is_compressed_plus2_for_btb(slot2_is_compressed_plus2_for_btb),
      .o_slot2_is_compressed_plus4_for_btb(slot2_is_compressed_plus4_for_btb),
      .o_slot2_plus2_candidate_valid(slot2_plus2_candidate_valid),
      .o_slot2_plus4_candidate_valid(slot2_plus4_candidate_valid),
      .o_slot2_plus2_candidate_valid_timing(slot2_plus2_candidate_valid_timing),
      .o_slot2_plus4_candidate_valid_timing(slot2_plus4_candidate_valid_timing),
      .o_slot1_is_branch(slot1_is_branch),

      // Slot-2 kill-cause profiling taps (width-funnel perf counters).
      .o_slot2_kill_s1_native_ctrl(slot2_kill_s1_native_ctrl_live),
      .o_slot2_kill_s1_native_serialize(slot2_kill_s1_native_serialize_live),
      .o_slot2_kill_slot1_ctrl(slot2_kill_slot1_ctrl_live),
      .o_slot2_kill_class(slot2_kill_class_live),
      .o_slot2_kill_window_limit(slot2_kill_window_limit_live),
      .o_slot2_kill_transient(slot2_kill_transient_live)
  );

  // RAS prediction stale cycle: only when prediction came from RAS (not BTB-only).
  assign ras_prediction_holdoff = prediction_holdoff && !btb_only_prediction_holdoff;

  // Registered PD redirect: used to override the !prediction_holdoff exemption
  // in sel_nop below.  When PD redirect fires AND BTB simultaneously predicts
  // the wrong-path instruction, prediction_holdoff would otherwise prevent
  // sel_nop from squashing the stale BRAM data in the holdoff cycle.
  // This registered signal is NOT on the critical path (FF output → 1 OR gate).
  logic pd_redirect_q;
  always_ff @(posedge i_clk) begin
    // This wrong-path bubble pulse must survive any front-end freeze.
    // control_flow_holdoff and prediction_holdoff are both held across both a
    // pipeline stall (i_pipeline_ctrl.stall) AND a no-progress fetch cycle
    // (the stall-capable L1I fetch provider withholds valid through a miss),
    // so without a matching gate the override pulse outlives the freeze: on
    // release the colliding BTB hit's prediction_holdoff still defeats the
    // control-flow NOP term, the lead-restoring bubble cycle presents (and
    // dispatch consumes) the bundle, and the realigned next cycle presents the
    // SAME pc_reg again, duplicating the ROB allocation. Gate the update on a
    // delivered cycle (fetch_progress) so the override
    // holds through both stalls and fetch misses until the bubble is NOP'd.
    // This matches o_slot2_redirect_q, whose pc_controller gate is already the
    // full fetch_stall form (!i_stall && i_fetch_progress); pd_redirect_q was
    // the lone override still gated on !i_pipeline_ctrl.stall alone.
    if (i_pipeline_ctrl.reset) pd_redirect_q <= 1'b0;
    else if (!i_pipeline_ctrl.stall && fetch_progress) pd_redirect_q <= i_pd_redirect;
  end

  // Any non-prediction redirect leaves one stale BRAM cycle where fetch has
  // moved to the new PC but the returned word still belongs to the old path.
  // Word-aligned redirects are not exempt: they can still pair a correct new
  // PC with old-path bytes, which later poison the C-extension/buffer state.
  // Keep the prediction path special-cased through prediction_holdoff so BTB
  // hits still deliver the predicted branch instruction itself. This applies
  // both to the generic control-flow holdoff and to pending halfword-prediction
  // holdoff in pc_controller: the cycle after a BTB redirect is when the
  // predicted branch instruction itself arrives from BRAM.
  //
  // pd_redirect_q overrides the !prediction_holdoff exemption: when a PD
  // redirect caused the holdoff, the arriving BRAM data is stale even if a
  // spurious wrong-path BTB hit set prediction_holdoff.
  // slot2_redirect_q has the same role as pd_redirect_q for the
  // slot-2 BTB redirect bubble — BRAM was fetching the sequential
  // wrong-path bundle when the slot-2 prediction fired, so the cycle
  // following the redirect must NOP even if prediction_holdoff is set.
  // Served-window invariant: pc_reg's 30-bit physical word must be S, S+1,
  // or (while the instruction buffer owns the preceding parcel) S-1 for the
  // selected provider. Otherwise the aligner's one-bit bank parity can select
  // the wrong word and advance into the middle of an instruction.
  //
  // TIMING: each provider registers S/S+1/S-1 beside its payload and gets its
  // own fixed three-LUT-level comparator. Both receive one shared prequalified
  // buffer-use bit, keeping its constituent controls outside the equality
  // trees. Address arithmetic and the former 30-wide provider mux remain
  // outside both comparators.
  logic [XLEN-1:0] pc_reg_serve_view;
  logic [29:0] pc_reg_word;
  logic served_window_covers_low;
  logic served_window_covers_high;
  logic served_window_covers_pc_reg;
  logic prev_was_compressed_at_lo_for_coverage_timing;
  assign pc_reg_serve_view = riscv_pkg::canonical_paddr(pc_reg);
  assign pc_reg_word = pc_reg_serve_view[31:2];
  // Exact i_fence_i_flush=0, control_flow_holdoff=0,
  // prediction_reset_c_ext=0 cofactor of the instruction aligner's buffer
  // select. The canonical use_instr_buffer continues to drive every packet
  // and PC-advance consumer. One shared masked companion drives BPC and both
  // provider comparators through their protected one-bit boundaries. R
  // implies H, and F/H make all timing-only results unobservable through
  // existing squashes.
  assign prev_was_compressed_at_lo_for_coverage_timing = use_saved_values ?
      prev_was_compressed_at_lo_saved : prev_was_compressed_at_lo;
  // prediction_holdoff is the latest input of this qualification (it heads
  // the served-window -> next-pc -> IMMU cone), so the release edge comes in
  // unmasked and the mask is applied here, in this one LUT: identical to
  // (... || use_buffer_after_prediction_timing), which the oracle below pins.
  assign use_instr_buffer_for_coverage_timing =
      (prev_was_compressed_at_lo_for_coverage_timing && pc_reg[1]) ||
      (use_buffer_after_prediction_edge && !prediction_holdoff);

`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown(
            {
              use_instr_buffer_for_coverage_timing,
              prev_was_compressed_at_lo_for_coverage_timing,
              pc_reg[1],
              use_buffer_after_prediction_timing
            }
        )) begin
      p_use_instr_buffer_for_coverage_timing_exact :
      assert (use_instr_buffer_for_coverage_timing ==
              ((prev_was_compressed_at_lo_for_coverage_timing && pc_reg[1]) ||
               use_buffer_after_prediction_timing));
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
      .o_covers(served_window_covers_low)
  );

  served_window_coverage u_served_window_coverage_high (
      .i_pc_word(pc_reg_word),
      .i_served_word(i_served_word_high),
      .i_served_last_word(i_served_last_word_high),
      .i_served_prev_word(i_served_prev_word_high),
      .i_served_prev_word_valid(i_served_prev_word_valid_high),
      .i_use_instr_buffer(use_instr_buffer_for_coverage_timing),
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
  logic served_contract_check_valid_q;

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
  assign served_window_covers_reference = served_eq_pc_word || served_last_eq_pc_word ||
      (served_eq_pc_word_p1 && use_instr_buffer_for_coverage_timing);
  assign served_window_covers_low_reference =
      (i_served_word_low == pc_reg_word) || (i_served_last_word_low == pc_reg_word) ||
      (use_instr_buffer_for_coverage_timing && i_served_prev_word_valid_low &&
       (i_served_prev_word_low == pc_reg_word));
  assign served_window_covers_high_reference =
      (i_served_word_high == pc_reg_word) || (i_served_last_word_high == pc_reg_word) ||
      (use_instr_buffer_for_coverage_timing && i_served_prev_word_valid_high &&
       (i_served_prev_word_high == pc_reg_word));

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
             use_buffer_after_prediction_timing,
             prediction_holdoff,
             use_instr_buffer_for_coverage_timing,
             i_fence_i_flush,
             prediction_reset_c_ext,
             control_flow_holdoff,
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
      p_served_window_guard_equivalent :
      assert (served_window_covers_pc_reg == served_window_covers_reference);
      p_coverage_buffer_timing_matches_canonical_outside_squash :
      assert (i_fence_i_flush || control_flow_holdoff ||
              (use_instr_buffer_for_coverage_timing == use_instr_buffer));
      p_prediction_reset_implies_control_flow_holdoff :
      assert (!prediction_reset_c_ext || control_flow_holdoff);
    end
  end
`endif

  logic window_cannot_serve_pc_reg;
  // Declared here (defined with the stall-capture machinery below): the
  // low-region guard arm excludes saved-replay cycles.
  logic replay_saved_if_outputs;
  // The guard is region-independent: silicon showed low-BRAM windows up to
  // 250 bytes stale after early recovery. The aligner's mod-2-word parity
  // cannot detect same-parity slips, so only the coverage comparison catches
  // them. A mismatch squashes and resteers to pc_reg's word.
  //
  // The low-BRAM arm must exclude saved-replay cycles: BRAM keeps
  // i_instr_valid high through stalls while the live window legitimately
  // moves past pc_reg (the saved-value machinery exists for exactly that),
  // so guarding those cycles squashes the replayed instruction and wedges
  // the replay handshake. The cached provider withdraws valid across stalls,
  // so its arm remains unqualified. The arm is selected by the seam's
  // served-provider bit (M5): under translation pc_reg's VA bit 31 says
  // nothing about which provider served the window. Use the same registered
  // timing-replica selector as the coverage mux above. The producer keeps it
  // cycle-identical to i_served_high; one common selector lets synthesis fold
  // the coverage result and replay qualification into a single LUT6.
  assign window_cannot_serve_pc_reg = i_instr_valid && !served_window_covers_pc_reg &&
      (i_instr_pc_metadata_served_high || !replay_saved_if_outputs);

  // The existing (pre-served-window-guard) squash conditions.
  logic sel_nop_existing;
  logic sel_nop_existing_wcs0;
  logic sel_nop_existing_wcs;
  assign sel_nop_existing = i_pipeline_ctrl.flush ||
                   flush_for_c_ext_safe || !fetch_progress ||
                   sel_nop_align || reset_holdoff ||
                   pending_prediction_target_holdoff ||
                   (pending_prediction_fetch_holdoff && !prediction_holdoff) ||
                   (control_flow_holdoff &&
                    (!prediction_holdoff || pd_redirect_q || slot2_redirect_q));
  // Exact window_cannot_serve_pc_reg=0 cofactor of sel_nop_existing. Since the
  // architectural result is W | E(W), Shannon absorption gives the identical
  // W | E(0). Computing E(0) in parallel with the served-window comparison
  // leaves W as a single final OR instead of routing it through the pending-
  // prediction holdoff cone before it reaches the PC advance logic.
  assign sel_nop_existing_wcs0 = i_pipeline_ctrl.flush ||
                   flush_for_c_ext_safe || !fetch_progress ||
                   sel_nop_align || reset_holdoff ||
                   pending_prediction_target_holdoff ||
                   (pending_prediction_fetch_holdoff_wcs0 && !prediction_holdoff) ||
                   (control_flow_holdoff &&
                    (!prediction_holdoff || pd_redirect_q || slot2_redirect_q));
  // Exact window_cannot_serve_pc_reg=1 cofactor of sel_nop_existing. Build it
  // beside the normal squash predicate while the served-window comparator is
  // still evaluating, then let raw WCS enter the resteer as only the final
  // AND. This removes the comparator -> pending-hold -> priority-mux chain
  // without changing normal sel_nop behavior.
  assign sel_nop_existing_wcs = i_pipeline_ctrl.flush ||
                   flush_for_c_ext_safe || !fetch_progress ||
                   sel_nop_align || reset_holdoff ||
                   pending_prediction_target_holdoff ||
                   (pending_prediction_fetch_holdoff_wcs && !prediction_holdoff) ||
                   (control_flow_holdoff &&
                    (!prediction_holdoff || pd_redirect_q || slot2_redirect_q));

  // Resteer fetch onto pc_reg's word + hold pc_reg ONLY at a real consume cycle
  // (not during an existing holdoff, where pc_reg is already managed and a resteer
  // would thrash the front end -- the cause of the earlier isa_test/boot regression).
  // At a holdoff release with the served window still stale (fetch ran ahead during
  // the redirect bubble), this fires the cycle the wrong-word decode would otherwise
  // advance pc_reg onto a mid-instruction byte.
  logic window_resteer_pc_reg;
  assign window_resteer_pc_reg = window_cannot_serve_pc_reg && !sel_nop_existing_wcs;

  assign sel_nop = sel_nop_existing_wcs0 || window_cannot_serve_pc_reg;

`ifndef SYNTHESIS
  // This integrated state invariant is what lets the served-window
  // comparators consume the timing companion. Prediction holdoff can change
  // served-window coverage only on
  // a post-prediction buffer-release edge. A raw edge can overlap a newly
  // armed pending episode, but that episode's registered prediction holdoff
  // masks use_buffer_after_prediction_timing. Therefore an observable release
  // cannot reach pending_predecessor_needs_emit during a live episode.
  // Reference the c_ext history bits only in this non-synthesized checker so
  // hardware mapping and the module interface remain unchanged.
  logic prediction_release_unmasked_check;
  assign prediction_release_unmasked_check =
      (c_ext_state_inst.prediction_from_buffer_holdoff_prev &&
       !prediction_from_buffer_holdoff) ||
      (c_ext_state_inst.pending_prediction_target_holdoff_prev &&
       !pending_prediction_target_holdoff);

  // Every FENCE-class flavor flushes frontend state, so the pre-existing
  // squash must force a NOP and make any comparator-driven resteer
  // unobservable during the redirect pulse.
  always_ff @(posedge i_clk) begin
    if (!i_pipeline_ctrl.reset && !$isunknown(
            {i_fence_i_flush,
             flush_for_c_ext_safe,
             control_flow_holdoff,
             prediction_holdoff,
             prediction_release_unmasked_check,
             prediction_reset_c_ext,
             pending_prediction_active,
             use_buffer_after_prediction_timing,
             use_buffer_after_prediction,
             use_instr_buffer_for_coverage_timing,
             use_instr_buffer,
             any_holdoff_safe,
             prediction_used,
             prediction_used_for_pc,
             slot2_prediction_used,
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
      p_prediction_buffer_timing_cofactor_exact :
      assert (use_buffer_after_prediction ==
              (use_buffer_after_prediction_timing && !prediction_reset_c_ext &&
               !i_fence_i_flush && !control_flow_holdoff));
      p_prediction_reset_holdoff_invariant :
      assert (!prediction_reset_c_ext || control_flow_holdoff);
      p_pending_prediction_excludes_timing_buffer_release :
      assert (!(pending_prediction_active && use_buffer_after_prediction_timing));
      p_pending_raw_release_is_prediction_masked :
      assert (!(pending_prediction_active && prediction_release_unmasked_check) ||
              prediction_holdoff);
      // The F=0,H=0,R=0 timing companion can differ from the canonical buffer
      // select only under a registered squash (R implies H). Because the
      // companion retains the prediction-holdoff mask, both WCS squash
      // predicates are then true, PC increment uses its holdoff arm, and all
      // prediction sources are disabled. The only raw-WCS consumers outside
      // those predicates are in the pending-predecessor cone; the special
      // buffer-release pulse cannot overlap a live pending episode here.
      p_registered_squash_masks_coverage_cofactor :
      assert (i_fence_i_flush ||
              (use_instr_buffer_for_coverage_timing == use_instr_buffer) ||
              (control_flow_holdoff && !prediction_holdoff &&
               any_holdoff_safe &&
               sel_nop_existing && sel_nop_existing_wcs0 &&
               sel_nop_existing_wcs && sel_nop &&
               !window_resteer_pc_reg &&
               !pending_prediction_active &&
               !prediction_used && !prediction_used_for_pc &&
               !slot2_prediction_used && !slot2_prediction_used_for_pc));
    end
  end

  // Low-BRAM served-window coherence invariant. Since
  // window_cannot_serve_pc_reg guards every region, an incoherent
  // low-region consume is impossible by construction (the guard forces
  // sel_nop and resteers), so this assertion is an invariant lock: it can
  // only fire if the guard is weakened. Silicon exposed this condition even
  // though simulation did not, so the synthesized guard remains required.
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
            "if_stage: low-BRAM consume with non-covering window: pc_reg=%h served=%h last_word=%h",
            pc_reg,
            {
              selected_served_word, 2'b00
            },
            {
              selected_served_last_word, 2'b00
            }
        );
    end
  end
`endif

  // ===========================================================================
  // Stall State Registers
  // ===========================================================================
  // Save raw instruction data when stall begins for restoration after unstall.
  // This is needed because BRAM output changes while stalled.

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
  // a single cycle.  When PC[1]=1, speculatively assemble the 32-bit candidate
  // from the current word's upper half and the next word's lower half.  This is
  // the architecturally selected value for a native instruction.  For an RVC
  // instruction PD selects raw_parcel/decompression instead, so the
  // speculative upper half is a don't-care.
  //
  // TIMING: do not qualify this mux with is_compressed.  That bit comes from
  // the IMEM predecode sideband; qualifying the 32-bit candidate with it put
  // sideband -> assembled_instr -> native branch immediate -> target adder on
  // PD's redirect-target low/raw-state register D inputs. PC[1] is registered and
  // is the only selector the native candidate actually needs.
  //
  // When the instruction buffer is active, the "next word" is the BRAM's
  // current word (the lead word).  When the buffer is inactive, the "next
  // word" is the BRAM's upper 32 bits from the 64-bit fetch.
  logic [31:0] assembled_instr;
  logic [15:0] spanning_second_half;
  // Select the spanning half using bank_sel_r parity to pick the correct
  // 16 bits from the 64-bit BRAM output.  The BRAM always contains two
  // consecutive words — the parity check identifies which half holds
  // word(pc_reg[31:2]+1).  This works for BOTH buffer and non-buffer cases:
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

  // Carry only the three source bits on the current low-IMEM/RVC worst paths.
  // Slot 1 still joins RVC sideband metadata with the assembled native word
  // here.  Slot 2 arrives fully resolved from instruction_aligner: each fixed
  // candidate performs its compressed/native choice before the late position
  // mux, removing a second join from the IMEM-to-PD capture path.
  logic [2:0] source_hot_predecoded_live;
  logic [2:0] source_hot_predecoded_2_live;
  logic [2:0] source_hot_predecoded_saved;
  logic [2:0] source_hot_predecoded_2_saved;
  assign source_hot_predecoded_live = sel_compressed ?
      rvc_source_hot : {assembled_instr[21], assembled_instr[17:16]};
  assign source_hot_predecoded_2_live = source_hot_2;

  // Capture the narrow values once on stall entry. Apply the replay select
  // only at the packet output so the live source path does not acquire the
  // generic stall-capture mux followed by a second replay mux.
  always_ff @(posedge i_clk) begin
    if (flush_for_c_ext_safe) begin
      source_hot_predecoded_saved   <= '0;
      source_hot_predecoded_2_saved <= '0;
    end else if (if_stage_stall & ~if_stage_stall_registered) begin
      source_hot_predecoded_saved   <= source_hot_predecoded_live;
      source_hot_predecoded_2_saved <= source_hot_predecoded_2_live;
    end
  end

`ifndef SYNTHESIS
  // The specialized candidate must match the old sideband-qualified value
  // whenever the native arm is architecturally visible.  For RVC the packet's
  // raw_parcel is selected and this 32-bit value is deliberately a don't-care.
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

  // Keep RAS replay eligibility and validity aligned with the same stall-entry
  // cycle as the captured instruction data instead of depending on
  // c_ext_state.saved_values_valid in the live RAS cone.
  stall_capture_reg #(
      .WIDTH(1)
  ) u_ras_saved_input_available_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(!sel_nop),
      .o_data(ras_saved_input_available_sc)
  );

  stall_capture_reg #(
      .WIDTH(1)
  ) u_ras_instruction_valid_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(ras_instruction_valid_live),
      .o_data(ras_instruction_valid_sc)
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

  // ===========================================================================
  // Prediction From Buffer Holdoff
  // ===========================================================================
  // When RAS (or BTB) predicts from a buffered instruction, there's a fetch in
  // flight that will arrive next cycle with STALE data (it was fetched for the
  // PC after the buffered instruction, not for the predicted target).
  // This holdoff signal suppresses that stale instruction for one cycle.
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || flush_for_c_ext_safe) begin
      prediction_from_buffer_holdoff <= 1'b0;
    end else if (!if_stage_stall && fetch_progress) begin
      // Set when prediction happens while using buffered instruction.
      // Next cycle's instruction data will be stale and needs suppression.
      // Held through fetch-invalid cycles (like a stall) so the deferred
      // stale-suppression and the c_ext use-buffer edge stay sequenced.
      prediction_from_buffer_holdoff <= prediction_used_from_buffer;
    end
  end

  // Registered to break combinational loop: prediction_used → c_ext_state
  // (use_buffer_after_prediction) → instruction_aligner (is_compressed) →
  // pc_controller/branch_prediction_controller → prediction_used.
  // One cycle delay is correct: prediction redirects PC this cycle, new
  // fetch data arrives next cycle, so c_ext_state reset aligns with it.
  // Include slot-2 prediction so c_ext_state also resets its
  // buffer state across slot-2 BTB redirects (the bubble cycle following
  // a slot-2 prediction has stale BRAM data and the buffer state should
  // not survive across the redirect).
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) prediction_reset_c_ext <= 1'b0;
    else prediction_reset_c_ext <= prediction_used || slot2_prediction_used;
  end

  // Only replay saved IF outputs when the stalled cycle carried a real,
  // still-valid instruction.
  assign replay_saved_if_outputs = if_stage_stall_registered &&
                                   !flush_for_c_ext_safe &&
                                   saved_values_valid &&
                                   !sel_nop_saved;

  // Fetch progress: a bundle is being presented for consumption this cycle --
  // either the provider's live window is valid, or the replay path is
  // presenting the stall-captured bundle (whose data needs no live window).
  // This, not i_instr_valid alone, is what gates the PC hold arms and the
  // per-delivery state freezes: on the stall-release cycle the replayed
  // bundle IS consumed, so freezing there would re-present (and re-dispatch)
  // the same pc_reg on the next live cycle.
  // TIMING: fetch_progress gates holdoffs, sel_nop, and stall-held CEs
  // across the whole IF stage (the widest post-opt TNS family after the
  // covers-compare fix).  Its inputs are registered, so cap the net's
  // fanout and let synthesis replicate the driver per consumer region.
  assign fetch_progress = i_instr_valid || replay_saved_if_outputs;
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
  // Slot-1 keeps PD's local decompressor; the pre-decoded illegal flag is a
  // slot-2-only mechanism.
  assign o_from_if_to_pd.decomp_illegal = 1'b0;

  // Selection signals
  assign o_from_if_to_pd.sel_nop = replay_saved_if_outputs ? sel_nop_saved : sel_nop;
  assign o_from_if_to_pd.sel_compressed = replay_saved_if_outputs ? sel_compressed_sc :
                                          sel_compressed;

  // Pre-assembled instruction for PD stage (spanning already assembled in IF)
  assign o_from_if_to_pd.effective_instr = replay_saved_if_outputs ? assembled_instr_sc :
                                           assembled_instr;
  assign o_from_if_to_pd.source_hot_predecoded =
      replay_saved_if_outputs ? source_hot_predecoded_saved :
                                source_hot_predecoded_live;

  // Pre-computed link address (the slot-1 fall-through PC), feeding the RAS
  // call push.  ID recomputes the pipeline link address for JAL/JALR itself
  // from the registered PC and is_compressed, so this adder no longer rides
  // the IF→PD packet.
  // Link address = instruction_pc + 2 (compressed) or + 4 (32-bit)
  logic [XLEN-1:0] instruction_pc;
  logic [XLEN-1:0] link_address;

  // link_address must reflect the TRUE size of the slot-1 instruction held
  // across a stall.  The shared sel_compressed_sc is flush-zeroed by its
  // stall_capture_reg (stall_capture_reg.sv: `if (i_flush) saved <= '0`),
  // so on a flush-inside-stall a *compressed* branch held at fetch reads
  // is_compressed_for_link = 0 -> link_address = pc_reg + 4 (one halfword too
  // far).  When ID still consumed the carried link, that stale fall-through
  // became the not-taken redirect target (early_misprediction_recovery),
  // making fetch skip the branch's successor parcel — the no-MMU-Linux
  // timer-IRQ "gremlin": the revmap_size load (`lw a5,80(a0)`) right after a
  // not-taken `c.beqz` was dropped, so the dependent `bgeu a1,a5` read a stale
  // a5 and took the wrong IRQ-dispatch path.  Capture sel_compressed for the
  // link WITHOUT the flush-zero so the held size matches the actual held
  // instruction (pc_reg+2/+4 correctly); today that keeps the RAS push
  // address right in the post-flush window.  sel_compressed_sc's other
  // consumers (o_from_if_to_pd.sel_compressed, slot2_pc_sc) are replay-gated
  // by sel_nop_saved=1 after a flush, so they are unaffected.
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
  // Fetch-fault tags (Phase 3 M2/M5)
  // ===========================================================================
  // The served window's per-word flags (word 0 / word 1, each {fault, page
  // kind}) are mapped onto the aligner's CURRENT and NEXT word exactly like
  // the instruction bytes are: the current word is the buffer (whose word
  // carried its own flag in), else window word 1 when the fetch lead is one
  // word ahead (bank parity swapped), else word 0; the next word follows the
  // spanning-half select (window word 0 in the swapped/buffer case, word 1
  // otherwise). Slot 1 faults on its current word, or on the next word only
  // when a 32-bit instruction at the upper halfword actually straddles into
  // it -- then the faulting portion is the second halfword (fetch_fault_hi:
  // xtval = PC + 2). Slot 2 likewise: its own parcel's word, plus the next
  // word whenever its position reads it (every shape but a compressed slot
  // 2 in the current word's upper half); a native slot 2 straddling from
  // the current word's upper half is the slot-2 "hi" case. Bare mode
  // reduces to M2's PMA verdict of the bundle PC (the shadow verdict rides
  // the window), plus the previously silent straddle into an unmapped
  // word. Captured at stall entry like every other IF output, so the replay
  // bundle carries the flags it was tagged with.
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
  // Bare-mode oracle: with translation off the window verdict is M2's PMA
  // check of the bundle PC whenever the bundle is real and its current
  // word came from the window that covers pc_reg (the straddle-into-
  // unmapped case is the one deliberate extension, so it is excluded).
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
  // RAS Metadata for Pipeline Passthrough
  // ===========================================================================
  // RAS checkpoint data needs to be saved during stalls similar to other IF outputs.
  // The checkpoint is taken at the time of RAS prediction and passed through the
  // pipeline for misprediction recovery in EX stage.

  logic ras_predicted_saved;

  // ras_predicted_saved has a non-standard flush condition (includes
  // prediction_holdoff), so it stays in a separate always_ff block.
  always_ff @(posedge i_clk) begin
    if (flush_for_c_ext_safe || prediction_holdoff) begin
      // Clear control bit on flush or prediction-driven control flow change.
      // Saved data remains but is ignored when ras_predicted_saved is low.
      ras_predicted_saved <= 1'b0;
    end else if (if_stage_stall & ~if_stage_stall_registered) begin
      ras_predicted_saved <= ras_predicted;
    end
  end

  logic [                 XLEN-1:0] ras_predicted_target_sc;
  logic [riscv_pkg::RasPtrBits-1:0] ras_checkpoint_tos_sc;
  logic [  riscv_pkg::RasPtrBits:0] ras_checkpoint_valid_count_sc;

  stall_capture_reg #(
      .WIDTH(XLEN)
  ) u_ras_predicted_target_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(ras_predicted_target),
      .o_data(ras_predicted_target_sc)
  );

  stall_capture_reg #(
      .WIDTH(riscv_pkg::RasPtrBits)
  ) u_ras_checkpoint_tos_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(ras_checkpoint_tos),
      .o_data(ras_checkpoint_tos_sc)
  );

  stall_capture_reg #(
      .WIDTH(riscv_pkg::RasPtrBits + 1)
  ) u_ras_checkpoint_valid_count_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(ras_checkpoint_valid_count),
      .o_data(ras_checkpoint_valid_count_sc)
  );

  // Lever A: freeze the decoupled direction bit across stall replay (like the
  // RAS checkpoint capture above) so the carried direction stays matched to the op.
  logic bp_dir_taken_sc;
  stall_capture_reg #(
      .WIDTH(1)
  ) u_bp_dir_taken_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(bp_dir_taken),
      .o_data(bp_dir_taken_sc)
  );

  // Lever A: freeze the slot-1 predict-time index across stall replay, mirroring
  // the direction bit above, so the carried index stays matched to the op.
  logic [riscv_pkg::BpDirIdxBits-1:0] bp_dir_idx_sc;
  stall_capture_reg #(
      .WIDTH(riscv_pkg::BpDirIdxBits)
  ) u_bp_dir_idx_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(bp_dir_idx),
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

  // Output RAS metadata - clear for NOP/spanning, use saved during stall
  logic sel_nop_effective;
  assign sel_nop_effective = replay_saved_if_outputs ? sel_nop_saved : sel_nop;

  assign o_from_if_to_pd.ras_predicted = sel_nop_effective ? 1'b0 :
                                         (replay_saved_if_outputs ? ras_predicted_saved :
                                          ras_predicted);
  assign o_from_if_to_pd.ras_predicted_target = replay_saved_if_outputs ?
                                                ras_predicted_target_sc :
                                                ras_predicted_target;
  assign o_from_if_to_pd.ras_checkpoint_tos = replay_saved_if_outputs ? ras_checkpoint_tos_sc :
                                              ras_checkpoint_tos;
  assign o_from_if_to_pd.ras_checkpoint_valid_count = replay_saved_if_outputs ?
      ras_checkpoint_valid_count_sc : ras_checkpoint_valid_count;
  // Lever A: decoupled bimodal direction carried with this slot-1 op (replay-aware).
  assign o_from_if_to_pd.bp_dir_taken = replay_saved_if_outputs ? bp_dir_taken_sc : bp_dir_taken;
  // Lever A: predict-time index carried with this slot-1 op (replay-aware).
  assign o_from_if_to_pd.bp_dir_idx = replay_saved_if_outputs ? bp_dir_idx_sc : bp_dir_idx;

  // ===========================================================================
  // Prediction Metadata Tracker
  // ===========================================================================
  // Manages prediction metadata for stalls.
  // When outputting NOP (holdoff), clears prediction metadata.
  // Otherwise uses registered prediction with stall handling.

  prediction_metadata_tracker #(
      .XLEN(XLEN)
  ) prediction_metadata_tracker_inst (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      .i_stall(if_stage_stall),
      // TIMING OPTIMIZATION: Use safe flush with registered trap/mret signals
      .i_flush(flush_for_c_ext_safe),
      // Redirect/stale death of the pending-prediction fetch state: the
      // pending-saved metadata inside the tracker must die with it (the
      // taken-branch -> jal-at-dword+4 call-skip fix; see pc_controller).
      .i_pending_prediction_kill(pending_prediction_redirect_kill),
      .i_prediction_holdoff(prediction_holdoff),
      .i_stall_registered(if_stage_stall_registered),

      // Registered prediction from branch_prediction_controller
      .i_prediction_used_r(prediction_used_r),
      .i_predicted_target_r(btb_predicted_target_r),
      .i_pending_prediction_fetch_holdoff(pending_prediction_fetch_holdoff),

      // Instruction type signals
      .i_sel_nop(sel_nop),
      .i_sel_nop_saved(sel_nop_saved),
      .i_use_saved_values(replay_saved_if_outputs),

      // Outputs to PD stage
      .o_btb_hit(o_from_if_to_pd.btb_hit),
      .o_btb_predicted_taken(o_from_if_to_pd.btb_predicted_taken),
      .o_btb_predicted_target(o_from_if_to_pd.btb_predicted_target)
  );

  // ===========================================================================
  // Slot-2 IF→PD packet.
  // ===========================================================================
  // Slot-2 follows slot-1 sequentially in program order: PC and link address
  // are simply slot-1's plus the slot-1 / slot-2 sizes.  No RAS prediction
  // is consumed for slot-2 (decision #1: slot-2 is invalid
  // when slot-1 is a branch, so slot-1 cannot have pushed/popped RAS in the
  // same cycle).
  //
  // Stall handling mirrors slot-1's stall_capture_reg pattern: during stall
  // the BRAM moves on, so we replay the captured-at-stall-start values until
  // unstall (gated by replay_saved_if_outputs).  sel_nop_2 has the same
  // flush-to-1 behaviour as sel_nop and folds in slot-1 sel_nop, slot-1
  // branch detection, and the slot-2 doesn't-fit case.

  logic [15:0] raw_parcel_2_saved;
  logic [31:0] effective_instr_2_sc;
  logic        sel_compressed_2_sc;
  logic        sel_nop_2_saved;
  logic        slot2_decomp_illegal_sc;

  // Slot-2's live raw parcel is on the BRAM -> PD decompressor path.  Keep
  // only a saved register here and let the final replay mux below select it;
  // the generic stall_capture_reg would add an unnecessary live-data mux
  // before the replay mux.
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

  // TIMING: sel_nop is the latest input of these selects (it carries the
  // flush, the holdoffs and the served-window verdict), so the sel_nop=0
  // ("run") and sel_nop=1 ("nop") cofactors are exported beside the merged
  // selects. pc_increment_calculator steers every candidate mux with both and
  // applies sel_nop as its final 2:1, keeping it out of the value path; the
  // merged selects remain the saved copies' source and the sim reference.
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_advance_sel_base_live;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] pc_advance_sel_run_live;
  assign pc_advance_sel_base_live = is_compressed_for_pc_advance ? riscv_pkg::PcAdvancePlus2 :
                                                                   riscv_pkg::PcAdvancePlus4;
  assign pc_advance_sel_run_live = slot2_valid_for_pc_live ? bundle_advance_sel_live :
                                                             pc_advance_sel_base_live;
  assign pc_fetch_advance_sel_live = sel_nop ? pc_advance_sel_base_live : pc_advance_sel_run_live;
  assign pc_reg_advance_sel_live = sel_nop ? riscv_pkg::PcAdvancePlus2 : pc_advance_sel_run_live;

  // Save the PC-only bundle metadata directly at stall entry.  Reconstructing
  // this from the replayed PD packet (`sel_compressed_2_sc`) puts the general
  // slot-2 aligner mux back on the fetch-PC path even when the replay arm is
  // inactive.
  always_ff @(posedge i_clk) begin
    if (flush_for_c_ext_safe) begin
      slot2_valid_for_pc_saved         <= 1'b0;
      slot2_is_compressed_for_pc_saved <= 1'b0;
      pc_fetch_advance_sel_saved       <= riscv_pkg::PcAdvancePlus2;
      pc_reg_advance_sel_saved         <= riscv_pkg::PcAdvancePlus2;
    end else if (if_stage_stall & ~if_stage_stall_registered) begin
      slot2_valid_for_pc_saved         <= !sel_nop && slot2_valid_for_pc_live;
      slot2_is_compressed_for_pc_saved <= slot2_is_compressed_for_pc_live;
      pc_fetch_advance_sel_saved       <= pc_fetch_advance_sel_live;
      pc_reg_advance_sel_saved         <= pc_reg_advance_sel_live;
    end
  end

  assign slot2_valid_for_pc = replay_saved_if_outputs ? slot2_valid_for_pc_saved :
                              (!sel_nop && slot2_valid_for_pc_live);
  assign slot2_is_compressed_for_pc =
      replay_saved_if_outputs ? slot2_is_compressed_for_pc_saved :
                                slot2_is_compressed_for_pc_live;
  assign pc_fetch_advance_sel =
      replay_saved_if_outputs ? pc_fetch_advance_sel_saved : pc_fetch_advance_sel_live;
  assign pc_reg_advance_sel =
      replay_saved_if_outputs ? pc_reg_advance_sel_saved : pc_reg_advance_sel_live;
  // The cofactors under the same saved-replay steer: on a replay cycle both
  // equal the saved select, so the final sel_nop 2:1 is a don't-care there.
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

  // Slot 2 has its own BTB lookup port. The
  // metadata flows combinationally — slot-2 lookup happens at the same
  // cycle as slot-2 is in IF, so no register is needed (unlike slot-1's
  // prediction_used_r which delays slot-1 BTB results by 1 cycle to align
  // with the BRAM-fetched instruction's arrival).  Stall replay uses
  // captured-at-stall-start values like the rest of the slot-2 packet.
  //
  // Stamp predicted_taken only if the slot-2 prediction actually
  // redirected fetch (slot2_prediction_used).  A BTB hit with counter
  // saying not-taken (predicted_taken_2 == 0) is stamped with btb_hit=1
  // and predicted_taken=0, which is consistent with fetch staying on the
  // sequential path.  EX-stage mispredict detection will fire correctly
  // for direction or target mismatch.
  logic            slot2_btb_hit_sc;
  logic            slot2_predicted_taken_sc;
  logic [XLEN-1:0] slot2_predicted_target_sc;

  stall_capture_reg #(
      .WIDTH(1)
  ) u_slot2_btb_hit_sc (
      .i_clk,
      .i_reset(1'b0),
      .i_flush(flush_for_c_ext_safe),
      .i_stall(if_stage_stall),
      .i_stall_registered(if_stage_stall_registered),
      .i_data(slot2_btb_hit),
      .o_data(slot2_btb_hit_sc)
  );

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

  // Clear slot-2 BTB metadata when slot-2 is NOPing this cycle.
  logic slot2_sel_nop_effective;
  assign slot2_sel_nop_effective = replay_saved_if_outputs ? sel_nop_2_saved : sel_nop_2;
  assign o_from_if_to_pd_2.btb_hit = slot2_sel_nop_effective ? 1'b0 :
                                     (replay_saved_if_outputs ? slot2_btb_hit_sc :
                                      slot2_btb_hit);
  assign o_from_if_to_pd_2.btb_predicted_taken = slot2_sel_nop_effective ? 1'b0 :
                                     (replay_saved_if_outputs ? slot2_predicted_taken_sc :
                                      slot2_predicted_taken);
  assign o_from_if_to_pd_2.btb_predicted_target = replay_saved_if_outputs ?
                                                  slot2_predicted_target_sc :
                                                  slot2_predicted_target;

  // RAS metadata: slot-2 cannot itself drive a RAS prediction (slot-1 owns
  // the lookup).  RAS state-snapshot fields, however, must reflect the RAS
  // state BEFORE slot-2 enters, which equals the state before slot-1 because
  // slot-1 is guaranteed not to be a call/return when slot-2 fires (decision
  // #1: slot-1 branch terminates the bundle).  Mirror slot-1's snapshot.
  assign o_from_if_to_pd_2.ras_predicted = 1'b0;
  assign o_from_if_to_pd_2.ras_predicted_target = '0;
  assign o_from_if_to_pd_2.ras_checkpoint_tos = o_from_if_to_pd.ras_checkpoint_tos;
  assign o_from_if_to_pd_2.ras_checkpoint_valid_count = o_from_if_to_pd.ras_checkpoint_valid_count;
  // Slot 2 is not used by the PD redirect heuristic, so
  // carry a benign 0 for slot-2's direction bit.  Its predict-time index IS
  // carried, so a slot-2-fetched branch trains the entry it predicted.
  assign o_from_if_to_pd_2.bp_dir_taken = 1'b0;
  assign o_from_if_to_pd_2.bp_dir_idx = replay_saved_if_outputs ? bp_dir_idx_2_sc : bp_dir_idx_2;

  // ===========================================================================
  // 2-Wide Width-Funnel Profiling Events (IF→PD boundary)
  // ===========================================================================
  // deliver1/deliver2 pulse exactly once per accepted handoff: PD's input
  // registers only advance on !stall cycles, so gating on !if_stage_stall
  // counts each delivered bundle once (stall-held cycles do not recount; the
  // stall-release replay cycle is the accepted delivery).  The kill causes
  // ride the same stall-capture/replay muxing as the slot-2 packet, so they
  // always classify the bundle PD actually received.  Profiling only — these
  // feed perf_counter_aggregator, nothing functional.
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

  logic width_deliver1;
  logic width_deliver2;
  logic width_slot2_killed;
  assign width_deliver1 = !if_stage_stall && !o_from_if_to_pd.sel_nop;
  assign width_deliver2 = width_deliver1 && !o_from_if_to_pd_2.sel_nop;
  assign width_slot2_killed = width_deliver1 && o_from_if_to_pd_2.sel_nop;

  // Register width-funnel taps at the IF boundary before they
  // leave for the perf aggregator, so observer logic cannot share LUTs with
  // the slot-2 kill/redirect cluster it taps (the dispatch-side taps
  // produced that fusion in the alloc-gate cone). Registering the taps did
  // not recover the separate -0.233 to -0.300 imem-to-fetch-PC regression;
  // the residual path is the base fetch-redirect loop. These bits only
  // feed free-running counters, so a uniform one-cycle delay is
  // count-neutral over any run and keeps the deliver/kill decomposition
  // internally consistent; the flops sit AFTER the stall-capture replay
  // alignment (slot2_kill_causes_effective / width_slot2_killed), so
  // per-bundle attribution is unchanged.
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
    // occurrence costs one fetch bubble: the redirect applies via
    // slot2_redirect_q on the following cycle.
    width_events_q.slot2_pred_taken <= slot2_prediction_used;
  end
  assign o_width_events = width_events_q;

endmodule : if_stage
