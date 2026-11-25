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
 * Instruction fetch (IF), decoupled around a 16-halfword parcel queue with
 * zero-cycle empty and partial bypass.
 *
 * Fetch (F0) runs ahead of decode on o_pc: fetch_pc_decoupled steps by 8 bytes
 * per 64-bit window or steers immediately on a two-bank fast-BTB hit
 * (fetch_btb_2w) while fetch_dir_4b, backing_btb, tage_predictor,
 * ittage_predictor, and immu look up the same window in parallel.
 *
 * Validate (F1) checks the arriving window's served tag against the launched
 * request, walks the four halfwords' instruction boundaries (tracking a
 * spanning 32-bit instruction across sequential windows with f1_carry_hi_q),
 * cancels or resteers on false fast-BTB hits, and pushes 1 to 4 parcels plus
 * one window metadata record into fetch_parcel_queue.
 *
 * Drain reads up to four head parcels (bypassing directly from F1 when the
 * queue is empty or partially filled), aligns and pairs slot 1 and slot 2
 * across window boundaries, expands slot 2 from the predecode sideband,
 * computes PD redirect target sums, and advances the queue by 1 to 4 halfwords
 * when PD accepts the bundle.
 */
module if_stage #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter bit USE_EXTERNAL_TAGE_FOLD = 1'b0
) (
    input logic i_clk,
    input logic [riscv_pkg::XLEN-1:0] i_boot_addr = '0,
    input riscv_pkg::from_ex_comb_t i_from_ex_comb,
    input logic i_btb_early_update_active,
    input logic [XLEN-1:0] i_btb_early_update_pc,
    input logic i_btb_early_update_taken,
    input logic [XLEN-1:0] i_btb_late_update_pc,
    input logic i_btb_late_update_taken,
    input logic [63:0] i_instr,
    input logic [63:0] i_instr_low_by_parity,
    input logic [63:0] i_instr_high,
    input logic i_instr_window_high,
    input logic [riscv_pkg::ImemFetchSidebandWidth-1:0] i_instr_sideband,
    input logic [7:0] i_instr_pc_metadata,
    input logic [15:0] i_instr_pc_metadata_by_provider_parity,
    input logic [7:0] i_pc_pairability_by_provider_parity,
    input logic [3:0] i_slot2_start_valid_lo_by_provider_parity,
    input logic i_instr_pc_metadata_served_high,
    input logic i_instr_bank_sel_r,
    input logic [XLEN-3:0] i_served_word_low,
    input logic [XLEN-3:0] i_served_last_word_low,
    input logic [XLEN-3:0] i_served_prev_word_low,
    input logic i_served_prev_word_valid_low,
    input logic [XLEN-3:0] i_served_word_high,
    input logic [XLEN-3:0] i_served_last_word_high,
    input logic [XLEN-3:0] i_served_prev_word_high,
    input logic i_served_prev_word_valid_high,
    input logic i_instr_valid,
    input logic i_instr_fault0,
    input logic i_instr_fault0_page,
    input logic i_instr_fault1,
    input logic i_instr_fault1_page,
    input logic i_served_high,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::trap_ctrl_t i_trap_ctrl,
    input logic i_frontend_state_flush,
    input logic i_flush_all,
    input logic i_fence_i_flush,
    input logic [XLEN-1:0] i_fence_i_target,
    input logic i_btb_invalidate,
    input logic i_disable_branch_prediction,
    input logic i_fetch_trap_hold = 1'b0,
    input logic i_dir_update_valid,
    input logic [riscv_pkg::BpDirIdxBits-1:0] i_dir_update_idx,
    input logic i_dir_update_taken,
    input logic i_pd_redirect,
    input logic i_pd_redirect_taken,
    input logic [XLEN-1:0] i_pd_redirect_target,
    input logic i_pd_redirect_ras_push,
    input logic i_pd_redirect_ras_pop,
    input logic [XLEN-1:0] i_pd_redirect_ras_link,
    input logic i_pd_backing_refresh,
    input logic [XLEN-1:0] i_pd_backing_refresh_pc,
    output logic [XLEN-1:0] o_pc,
    output logic o_fetch_replay_consume,
    output logic o_fetch_live_claim,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_fetch_pa0,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_fetch_pa1,
    output logic o_fetch_pa_valid,
    output logic o_fetch_fault0,
    output logic o_fetch_fault0_page,
    output logic o_fetch_fault1,
    output logic o_fetch_fault1_page,
    output logic o_fetch_line_after_ok,
    output logic o_fetch_redirect,
    output logic o_fetch_cached_retarget,
    output logic o_fetch_pa_hold,
    output logic [riscv_pkg::FetchPaHoldCopies-1:0] o_fetch_pa_hold_copy,
    input logic i_fetch_translation_active,
    input logic i_fetch_priv_u,
    input logic [riscv_pkg::AsidBits-1:0] i_fetch_asid,
    input logic i_tlb_invalidate,
    input riscv_pkg::tlb_flush_t i_tlb_flush,
    output logic o_walk_req_valid,
    input logic i_walk_req_ready,
    output logic [riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,
    input logic i_walk_resp_valid,
    input riscv_pkg::ptw_resp_t i_walk_resp,
    output riscv_pkg::from_if_to_pd_t o_from_if_to_pd,
    output riscv_pkg::from_if_to_pd_t o_from_if_to_pd_2,
    output logic [1:0] o_backing_hit,
    output logic [1:0] o_backing_compressed,
    output logic [1:0] o_backing_return,
    output logic [1:0][riscv_pkg::PhysAddrBits-2:0] o_backing_target,
    output logic [1:0] o_backing_slot2_return_by_size,
    output logic [1:0][riscv_pkg::PhysAddrBits-2:0] o_backing_slot2_target_by_size,
    output logic o_slot1_has_control_flow,
    output logic o_slot1_is_indirect,
    output riscv_pkg::if_width_events_t o_width_events,
    input logic [riscv_pkg::TageDirHistBits-1:0] i_tage_hist,
    input logic [riscv_pkg::TageTables-1:0][riscv_pkg::TageIndexBits-1:0] i_tage_hist_fold = '0,
    input logic [riscv_pkg::TageHistBits-1:0] i_itt_hist,
    input logic i_tage_train_valid,
    input riscv_pkg::tage_lookup_t i_tage_train_lookup,
    input logic i_tage_train_bank,
    input logic i_tage_train_alt_taken,
    input logic i_tage_train_taken,
    input logic i_tage_train_mispredicted,
    output logic o_tage_hist_push,
    output logic [4:1] o_tage_hist_restore_arm,
    output logic [riscv_pkg::TagePathBits-1:0] o_tage_fetch_path_bits,
    output logic [1:0] o_tage_slot_valid,
    output riscv_pkg::tage_lookup_t o_tage_slot_lookup,
    output riscv_pkg::tage_lookup_t o_tage_slot_lookup_2,
    output logic [riscv_pkg::TageHistBits-1:0] o_tage_lookup_hist,
    input logic i_itt_train_valid,
    input riscv_pkg::itt_lookup_t i_itt_train_lookup,
    input logic i_itt_train_bank,
    input logic [riscv_pkg::PhysAddrBits-2:0] i_itt_train_target,
    input logic i_itt_train_mispredicted,
    output riscv_pkg::itt_lookup_t o_itt_slot_lookup,
    output riscv_pkg::itt_lookup_t o_itt_slot_lookup_2,
    output logic [1:0] o_itt_hit,
    output logic [1:0][riscv_pkg::PhysAddrBits-2:0] o_itt_target
);

  // ===========================================================================
  // Local Constants & Packed Types
  // ===========================================================================
  localparam int unsigned SbWidth = riscv_pkg::ImemSidebandWidth;
  localparam int unsigned BtbIndexBits = 8;
  localparam int unsigned BackingIndexBits = $clog2(
      riscv_pkg::BackingBtbEntries / riscv_pkg::BackingBtbWays
  );
  localparam int unsigned BackingTargetBits = riscv_pkg::PhysAddrBits - 1;
  localparam int unsigned RasPtrBits = riscv_pkg::RasPtrBits;

  typedef struct packed {
    logic [15:0] parcel;
    logic allows_slot2_after;
    logic slot2_start_valid;
    logic is_indirect;
    logic is_control;
    logic [1:0] rvc_source_hot;
    logic [4:0] rvc_bits24_20;
    logic [2:0] rvc_rs1_rest;
    logic [22:0] rvc_extra;
    logic [1:0] hw_in_win;  // bit 1: word_in_win (0=W, 1=W+1), bit 0: PC[1]
    logic fault;
    logic fault_page;
    logic bp_dir_taken;
    logic btb_taken;
    logic backing_hit;
    logic backing_compressed;
    logic backing_return;
    logic [BackingTargetBits-1:0] backing_target;
  } parcel_t;

  // Explicit bit width for Yosys parameter-override compatibility (checked below).
  localparam int unsigned ParcelBits = 16 + 4 + 2 + 5 + 3 + 23 + 2 + 2 + 2 + 3 + BackingTargetBits;

  typedef struct packed {
    logic [XLEN-3:0] word0_pc;
    logic [XLEN-3:0] word1_pc;
    logic [XLEN-2:0] btb_target_hi;
    logic [RasPtrBits-1:0] ras_ckpt_tos;
    logic [RasPtrBits:0] ras_ckpt_cnt;
    logic [XLEN-1:0] ras_ckpt_top;
    logic [1:0] tage_cov;
    riscv_pkg::tage_lookup_t tage_w0;
    riscv_pkg::tage_lookup_t tage_w1;
    riscv_pkg::itt_lookup_t itt_w0;
    riscv_pkg::itt_lookup_t itt_w1;
    logic [1:0] itt_hit;
    logic [1:0][BackingTargetBits-1:0] itt_target;
    logic [riscv_pkg::TageHistBits-1:0] itt_hist;
  } meta_t;

  localparam int unsigned MetaBits = (2 * (XLEN - 2)) + (XLEN - 1) +
      RasPtrBits + (RasPtrBits + 1) + XLEN + 2 + (2 * riscv_pkg::TageLookupBits) +
      (2 * riscv_pkg::IttLookupBits) + 2 + (2 * BackingTargetBits) + riscv_pkg::TageHistBits;

  typedef struct packed {
    logic [XLEN-1:0] pc;
    logic span_veto;
    logic span_tail;
    logic btb_taken;
    logic btb_is_span;
    logic [1:0] btb_pos;
    logic btb_comp;
    logic [XLEN-1:0] btb_target;
    logic [riscv_pkg::BpDirIdxBits-3:0] btb_even_dir_idx;
    logic btb_is_call;
    logic btb_is_return;
    logic [XLEN-1:0] btb_link;
    logic btb_link_cached;
    logic [3:0] dir_taken;
    logic [RasPtrBits-1:0] ras_ckpt_tos;
    logic [RasPtrBits:0] ras_ckpt_cnt;
    logic [XLEN-1:0] ras_ckpt_top;
    logic ras_ckpt_from_live;
  } f1_req_t;

  typedef struct packed {
    logic [XLEN-1:0] target;
    logic [riscv_pkg::BpDirIdxBits-3:0] even_dir_idx;
    logic is_call;
    logic is_return;
    logic [XLEN-1:0] link;
    logic link_cached;
  } span_btb_t;

  typedef struct packed {
    logic [riscv_pkg::TageLookupHiBit:2] tage_word;
    logic [riscv_pkg::TageLookupHiBit:2] tage_word_next;
    riscv_pkg::tage_lookup_t tage_bank0;
    riscv_pkg::tage_lookup_t tage_bank1;
    riscv_pkg::itt_lookup_t itt_bank0;
    riscv_pkg::itt_lookup_t itt_bank1;
    logic [1:0] itt_hit;
    logic [1:0][BackingTargetBits-1:0] itt_target;
    logic [riscv_pkg::TageHistBits-1:0] itt_hist;
    logic [3:0] backing_hit;
    logic [3:0] backing_comp;
    logic [3:0] backing_ret;
    logic [3:0][BackingTargetBits-1:0] backing_target;
  } pred_hold_t;

  // ===========================================================================
  // Shared Control & Flush Classification
  // ===========================================================================
  logic frontend_flush;
  logic any_redirect;
  logic pqueue_flush;
  assign frontend_flush = i_pipeline_ctrl.flush || i_frontend_state_flush;
  assign any_redirect = frontend_flush || i_pd_redirect || i_trap_ctrl.trap_taken ||
      i_trap_ctrl.mret_taken || i_fence_i_flush || i_from_ex_comb.branch_taken;
  assign pqueue_flush = any_redirect;

  // ===========================================================================
  // Forward Declarations (declared before first use)
  // ===========================================================================
  logic [XLEN-1:0] pc;
  logic [riscv_pkg::TageLookupHiBit:2] pc_tage_lookup;
  logic [BtbIndexBits-2:0] pc_even_btb_idx;
  logic [riscv_pkg::BpDirIdxBits-3:0] pc_even_dir_idx;
  logic [XLEN-1:0] next_pc;
  logic pc_update_en;
  logic f0_self_loop;
  logic [riscv_pkg::PcNextArms-1:0] npc_sel;

  logic fetch_pa_valid;
  logic fetch_fault0_live;
  logic [riscv_pkg::PhysAddrBits-1:0] fetch_pa0_live;
  logic [riscv_pkg::PhysAddrBits-1:0] fetch_pa1_live;

  logic f1_req_valid_q;
  f1_req_t f1_req_q;
  (* max_fanout = 16 *) logic f1_start_off_q;
  logic span_btb_valid_q;
  span_btb_t span_btb_pending_q;
  logic f1_carry_hi_q;
  (* max_fanout = 64 *) logic f1_pred_fresh_q;
  logic collapsed_armed_q;
  logic f1_resteer_nopred_q;
  pred_hold_t f1_pred_hold_q;

  logic q_stop_fetch;
  logic f0_stop_fetch;
  logic f0_launch_raw;
  logic f0_launch;
  assign f0_stop_fetch = q_stop_fetch || i_fetch_trap_hold;
  logic f1_accept_raw;
  logic f1_accept;
  logic f1_collapsed_accept_raw;
  logic f1_collapsed_accept;
  logic f1_collapsed_btb_steer_raw;
  logic f1_collapsed_btb_steer;
  logic f1_collapsed_btb_span_raw;
  logic f1_collapsed_btb_span;
  logic f1_collapsed_span_fire_raw;
  logic f1_collapsed_span_fire;
  logic f1_tag_resteer_raw;
  logic f1_tag_resteer;
  logic f1_false_btb_raw;
  logic f1_false_btb_resteer_raw;
  logic f1_false_btb_resteer;
  logic f1_cancel_span_raw;
  logic f1_cancel_span;
  (* max_fanout = 24 *) logic f1_resteer_raw;
  logic f1_resteer;
  logic [XLEN-1:0] f1_resteer_target;
  logic f1_span_tail_fault;

  logic ras_nonempty;
  logic [XLEN-1:0] ras_top;
  logic [RasPtrBits-1:0] ras_tos;
  logic [RasPtrBits:0] ras_valid_count;
  logic f0_ras_push;
  logic f0_ras_pop;
  logic [XLEN-1:0] f0_ras_link;
  logic f0_ras_link_cached;
  logic f0_ras_push_q;
  logic f0_ras_pop_q;
  logic [XLEN-1:0] f0_ras_link_q;
  logic f0_ras_link_cached_q;
  logic [riscv_pkg::RasDepth-1:0] ras_cached_q;
  logic [RasPtrBits-1:0] ras_cached_tos_q;
  logic [RasPtrBits:0] ras_cached_cnt_q;
  logic ras_cached_ne0_q;
  logic ras_cached_gt1_q;
  logic [RasPtrBits-1:0] ras_sh_tos_next;
  logic [RasPtrBits:0] ras_sh_cnt_next;
  logic f1_ras_restore_comb;
  logic ras_restore_q;
  logic [RasPtrBits-1:0] ras_restore_tos_q;
  logic [RasPtrBits:0] ras_restore_cnt_q;
  logic [XLEN-1:0] ras_restore_top_q;
  logic ras_restore_push_q;
  logic ras_restore_pop_q;
  logic [XLEN-1:0] ras_restore_link_q;
  logic ras_restore_top_cached_q;
  logic ras_restore_link_cached_q;
  logic ras_restore_pure_pop_q;
  logic ras_restore_nonempty_q;
  logic ras_restore_uses_link_q;

  logic [RasPtrBits-1:0] pd_ras_ckpt_tos_q;
  logic [RasPtrBits:0] pd_ras_ckpt_cnt_q;
  logic [XLEN-1:0] pd_ras_ckpt_top_q;
  logic pd_ras_restore_done_q;
  logic pd_ras_restore;

  // ===========================================================================
  // F0: Fast-BTB (2-Bank Even/Odd) & 4-Bank Bimodal Direction Predictor
  // ===========================================================================
  // Register BTB training by one cycle for timing and hold i_btb_invalidate
  // for four cycles so pre-flush in-flight training writes cannot reinstall
  // stale entries after FENCE.I, SFENCE.VMA, satp, or Debug Mode transitions.
  logic btb_update_q;
  logic [XLEN-1:0] btb_update_pc_q;
  logic [XLEN-1:0] btb_update_target_q;
  logic btb_update_taken_q;
  logic btb_update_compressed_q;
  logic btb_update_call_q;
  logic btb_update_return_q;
  logic btb_early_update_active_q;
  (* max_fanout = 48 *) logic [XLEN-1:0] btb_early_update_pc_q;
  logic btb_early_update_taken_q;
  logic [XLEN-1:0] btb_late_update_pc_q;
  logic btb_late_update_taken_q;
  logic [1:0] btb_invalidate_hold_q;
  logic btb_invalidate_active;

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      btb_update_q              <= 1'b0;
      btb_early_update_active_q <= 1'b0;
      btb_invalidate_hold_q     <= '0;
    end else begin
      btb_update_q              <= i_from_ex_comb.btb_update;
      btb_early_update_active_q <= i_btb_early_update_active;
      if (i_btb_invalidate) btb_invalidate_hold_q <= 2'd3;
      else if (btb_invalidate_hold_q != '0) btb_invalidate_hold_q <= btb_invalidate_hold_q - 2'd1;
    end
    btb_update_pc_q          <= i_from_ex_comb.btb_update_pc;
    btb_update_target_q      <= i_from_ex_comb.btb_update_target;
    btb_update_taken_q       <= i_from_ex_comb.btb_update_taken;
    btb_update_compressed_q  <= i_from_ex_comb.btb_update_compressed;
    btb_update_call_q        <= i_from_ex_comb.btb_update_call;
    btb_update_return_q      <= i_from_ex_comb.btb_update_return;
    btb_early_update_pc_q    <= i_btb_early_update_pc;
    btb_early_update_taken_q <= i_btb_early_update_taken;
    btb_late_update_pc_q     <= i_btb_late_update_pc;
    btb_late_update_taken_q  <= i_btb_late_update_taken;
  end
  assign btb_invalidate_active = i_btb_invalidate || (btb_invalidate_hold_q != '0);

  // Mirror the RAS entries' cached-region membership in an 8-bit FF bank so
  // F0 BTB tier checking reads a single LUT instead of traversing u_ras RAM
  // and a 64-bit PMA range comparator.
  logic ras_sh_not_empty;
  logic ras_sh_pending_swap;
  logic ras_sh_pending_push;
  logic ras_sh_pending_pop;
  logic [RasPtrBits-1:0] ras_sh_below_tos;
  assign ras_sh_not_empty    = ras_cached_ne0_q;
  assign ras_sh_pending_swap = f0_ras_push_q && f0_ras_pop_q && ras_sh_not_empty;
  assign ras_sh_pending_push = f0_ras_push_q && !f0_ras_pop_q;
  assign ras_sh_pending_pop  = f0_ras_pop_q && !f0_ras_push_q && ras_sh_not_empty;
  assign ras_sh_below_tos    = ras_cached_tos_q - RasPtrBits'(1);

  logic ras_top_is_cached;
  logic pc_is_cached;
  (* keep = "true" *) logic eff_ras_nonempty;
  logic [XLEN-1:0] eff_ras_top;
  logic eff_ras_top_cached;
  logic [RasPtrBits-1:0] eff_ras_tos;
  logic [RasPtrBits:0] eff_ras_cnt;
  logic [riscv_pkg::BpDirIdxBits-3:0] ras_even_dir_idx;

  assign ras_top_is_cached = (ras_sh_pending_push || ras_sh_pending_swap) ?
      f0_ras_link_cached_q :
      ras_sh_pending_pop ? ras_cached_q[ras_sh_below_tos] : ras_cached_q[ras_cached_tos_q];
  assign pc_is_cached = riscv_pkg::pma_cached_ok(pc);

  // While a registered RAS restore commits into u_ras, forward the exact
  // post-restore top, pointer, count, and cached bit for every non-pure-pop
  // restore so F0 predictions and checkpoints keep zero-cycle availability.
  // Compute eff_ras_nonempty from 6 registered flags in a single LUT6.
  assign eff_ras_nonempty = ras_restore_q ? ras_restore_nonempty_q :
      (f0_ras_push_q ? (!f0_ras_pop_q || ras_cached_ne0_q) :
                       (f0_ras_pop_q ? ras_cached_gt1_q : ras_cached_ne0_q));
  assign eff_ras_top = ras_restore_q ?
      (ras_restore_uses_link_q ? ras_restore_link_q : ras_restore_top_q) : ras_top;
  assign eff_ras_top_cached = ras_restore_q ?
      (ras_restore_uses_link_q ? ras_restore_link_cached_q : ras_restore_top_cached_q) :
      ras_top_is_cached;
  assign eff_ras_tos = ras_restore_q ? ras_sh_tos_next : ras_tos;
  assign eff_ras_cnt = ras_restore_q ? ras_sh_cnt_next : ras_valid_count;
  assign ras_even_dir_idx =
      eff_ras_top[riscv_pkg::BpDirIdxBits:3] + (riscv_pkg::BpDirIdxBits - 2)'(eff_ras_top[2]);

  logic btb_taken_raw;
  logic btb_steer_raw;
  logic [1:0] btb_taken_pos;
  logic [XLEN-1:0] f0_btb_eff_target;
  logic [riscv_pkg::BpDirIdxBits-3:0] f0_btb_even_dir_idx;
  logic btb_compressed;
  logic btb_is_call;
  logic btb_is_return;
  logic btb_is_span;
  logic btb_w0_taken;
  logic btb_w0_link_inc;
  logic btb_w1_link_inc;
  logic btb_w0_link_hw;
  logic btb_w1_link_hw;

  fetch_btb_2w #(
      .XLEN(XLEN),
      .BTB_INDEX_BITS(BtbIndexBits),
      .BIM_BITS(riscv_pkg::BpDirIdxBits)
  ) u_fetch_btb_2w (
      .i_clk,
      .i_rst(i_pipeline_ctrl.reset),
      .i_pc(pc),
      .i_pc_even_idx(pc_even_btb_idx),
      .i_fetch_translation_active(i_fetch_translation_active),
      .i_pc_is_cached(pc_is_cached),
      .i_ras_nonempty(eff_ras_nonempty),
      .i_ras_top_is_cached(eff_ras_top_cached),
      .i_ras_top(eff_ras_top),
      .i_ras_even_dir_idx(ras_even_dir_idx),
      .o_taken(btb_taken_raw),
      .o_taken_steer(btb_steer_raw),
      .o_taken_pos(btb_taken_pos),
      .o_target(f0_btb_eff_target),
      .o_target_even_dir_idx(f0_btb_even_dir_idx),
      .o_compressed(btb_compressed),
      .o_is_call(btb_is_call),
      .o_is_return(btb_is_return),
      .o_is_span(btb_is_span),
      .o_target_is_cached(),
      .o_w0_hit(),
      .o_w1_hit(),
      .o_w0_taken(btb_w0_taken),
      .o_w0_link_inc(btb_w0_link_inc),
      .o_w1_link_inc(btb_w1_link_inc),
      .o_w0_link_hw(btb_w0_link_hw),
      .o_w1_link_hw(btb_w1_link_hw),
      .i_update(btb_update_q),
      .i_update_pc(btb_update_pc_q),
      .i_update_target(btb_update_target_q),
      .i_update_taken(btb_update_taken_q),
      .i_update_compressed(btb_update_compressed_q),
      .i_update_call(btb_update_call_q),
      .i_update_return(btb_update_return_q),
      .i_early_update_active(btb_early_update_active_q),
      .i_early_update_pc(btb_early_update_pc_q),
      .i_early_update_taken(btb_early_update_taken_q),
      .i_late_update_pc(btb_late_update_pc_q),
      .i_late_update_taken(btb_late_update_taken_q),
      .i_invalidate_all(btb_invalidate_active)
  );

  logic [3:0] dir_taken_f0;
  fetch_dir_4b #(
      .XLEN(XLEN),
      .BIM_BITS(riscv_pkg::BpDirIdxBits)
  ) u_fetch_dir_4b (
      .i_clk,
      .i_rst(i_pipeline_ctrl.reset),
      .i_pc(pc),
      .i_pc_even_dir_idx(pc_even_dir_idx),
      .o_taken(dir_taken_f0),
      .i_update_valid(i_dir_update_valid),
      .i_update_idx(i_dir_update_idx),
      .i_update_taken(i_dir_update_taken)
  );

  // Qualify F0 fast-BTB prediction: block when prediction is disabled, on a
  // faulting word 0, after a tag resteer, while a pure-pop RAS restore updates
  // u_ras, or while a spanning BTB target is completing. Bare-mode tier
  // matching is already folded inside u_fetch_btb_2w.
  logic f0_span_fault_veto;
  logic f0_span_btb_fire;
  logic f0_pred_en;
  logic f0_btb_valid;
  logic f0_btb_steer_now;
  logic [XLEN-1:0] f0_btb_link;
  logic f0_btb_link_cached;

  assign f0_span_fault_veto = span_btb_valid_q && !f1_cancel_span_raw && fetch_fault0_live;
  assign f0_span_btb_fire   = span_btb_valid_q && !f1_cancel_span_raw && !fetch_fault0_live;
  assign f0_pred_en = !i_disable_branch_prediction && !fetch_fault0_live &&
      !f1_resteer_nopred_q && !ras_restore_pure_pop_q && !f0_span_btb_fire &&
      (i_fetch_translation_active || riscv_pkg::pma_fetch_ok(pc));
  assign f0_btb_valid     = f0_pred_en && btb_taken_raw;
  assign f0_btb_steer_now = f0_pred_en && btb_steer_raw;

  // Precompute word+1, word+2, and per-word candidate link addresses and
  // cached-region flags in parallel with BTB tag compare so only one 2:1 LUT3
  // mux controlled by btb_w0_taken sits on the F0 link path.
  (* keep = "true" *) logic [XLEN-3:0] pc_word_p1;
  (* keep = "true" *) logic [XLEN-3:0] pc_word_p2;
  logic pc_p1_cached;
  logic pc_p2_cached;
  logic [XLEN-3:0] w0_link_word;
  logic [XLEN-3:0] w1_link_word;
  logic w0_link_cached;
  logic w1_link_cached;
  assign pc_word_p1     = pc[XLEN-1:2] + (XLEN - 2)'(1);
  assign pc_word_p2     = pc[XLEN-1:2] + (XLEN - 2)'(2);
  assign pc_p1_cached   = riscv_pkg::pma_cached_ok({pc_word_p1, 2'b00});
  assign pc_p2_cached   = riscv_pkg::pma_cached_ok({pc_word_p2, 2'b00});
  assign w0_link_word   = btb_w0_link_inc ? pc_word_p1 : pc[XLEN-1:2];
  assign w1_link_word   = btb_w1_link_inc ? pc_word_p2 : pc_word_p1;
  assign w0_link_cached = btb_w0_link_inc ? pc_p1_cached : pc_is_cached;
  assign w1_link_cached = btb_w1_link_inc ? pc_p2_cached : pc_p1_cached;
  assign f0_btb_link = btb_w0_taken ?
      {w0_link_word, btb_w0_link_hw, 1'b0} : {w1_link_word, btb_w1_link_hw, 1'b0};
  assign f0_btb_link_cached = btb_w0_taken ? w0_link_cached : w1_link_cached;

  // ===========================================================================
  // F0: Decoupled PC Controller (instance name kept for RVFI/testbench probes)
  // ===========================================================================
  fetch_pc_decoupled #(
      .XLEN(XLEN),
      .BTB_INDEX_BITS(BtbIndexBits),
      .BIM_BITS(riscv_pkg::BpDirIdxBits)
  ) pc_controller_inst (
      .i_clk,
      .i_boot_addr,
      .i_reset(i_pipeline_ctrl.reset),
      .i_trap_taken(i_trap_ctrl.trap_taken),
      .i_mret_taken(i_trap_ctrl.mret_taken),
      .i_trap_target(i_trap_ctrl.trap_target),
      .i_fence_i_flush(i_fence_i_flush),
      .i_fence_i_target(i_fence_i_target),
      .i_branch_taken(i_from_ex_comb.branch_taken),
      .i_branch_target(i_from_ex_comb.branch_target_address),
      .i_pd_redirect(i_pd_redirect && !i_pipeline_ctrl.stall),
      .i_pd_redirect_target(i_pd_redirect_target),
      .i_any_redirect(any_redirect),
      .i_f1_resteer(f1_resteer_raw),
      .i_f1_resteer_target(f1_resteer_target),
      .i_f0_launch(f0_launch_raw),
      .i_f1_collapsed_accept(f1_collapsed_accept_raw),
      .i_span_btb_fire(f1_collapsed_accept_raw ? f1_collapsed_span_fire_raw : f0_span_btb_fire),
      .i_span_btb_target(span_btb_pending_q.target),
      .i_span_btb_even_dir_idx(span_btb_pending_q.even_dir_idx),
      .i_collapsed_btb_taken(f1_collapsed_btb_steer_raw),
      .i_collapsed_btb_target(f1_req_q.btb_target),
      .i_collapsed_btb_even_dir_idx(f1_req_q.btb_even_dir_idx),
      .i_btb_en(f0_pred_en),
      .i_btb_taken(btb_steer_raw),
      .i_btb_target(f0_btb_eff_target),
      .i_btb_even_dir_idx(f0_btb_even_dir_idx),
      .o_pc(pc),
      .o_pc_tage_lookup(pc_tage_lookup),
      .o_pc_even_btb_idx(pc_even_btb_idx),
      .o_pc_even_dir_idx(pc_even_dir_idx),
      .o_next_pc(next_pc),
      .o_pc_update_en(pc_update_en),
      .o_f0_self_loop(f0_self_loop),
      .o_tage_hist_push(o_tage_hist_push),
      .o_tage_hist_restore_arm(o_tage_hist_restore_arm),
      .o_fetch_redirect(o_fetch_redirect),
      .o_fetch_cached_retarget(o_fetch_cached_retarget),
      .o_npc_sel(npc_sel),
      .o_npc_val()
  );

  assign o_pc = pc;
  assign o_tage_fetch_path_bits = pc_tage_lookup[3:2];

  // ===========================================================================
  // Instruction MMU (decoupled from PD/ID: fetch_pa_valid gates F0 launch only)
  // ===========================================================================
  immu #(
      .XLEN(XLEN),
      .NUM_ENTRIES(16),
      .PA_VALID_COPIES(riscv_pkg::FetchPaHoldCopies),
      .PA_COPY_HOLD(1'b1)
  ) u_immu (
      .i_clk(i_clk),
      .i_rst(i_pipeline_ctrl.reset),
      .i_active(i_fetch_translation_active),
      .i_priv_u(i_fetch_priv_u),
      .i_tlb_invalidate(i_tlb_invalidate),
      .i_tlb_flush(i_tlb_flush),
      .i_asid(i_fetch_asid),
      .i_full_flush(i_flush_all),
      .i_pc(pc),
      .o_pa0(fetch_pa0_live),
      .o_pa1(fetch_pa1_live),
      .o_pa_valid(fetch_pa_valid),
      .o_pa_valid_copy(),
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

  assign o_fetch_pa0          = fetch_pa0_live;
  assign o_fetch_pa1          = fetch_pa1_live;
  assign o_fetch_pa_valid     = fetch_pa_valid;
  assign o_fetch_fault0       = fetch_fault0_live;
  assign o_fetch_pa_hold      = 1'b0;
  assign o_fetch_pa_hold_copy = '0;

  // ===========================================================================
  // Return Address Stack (speculative F0 push/pop, exact EX/PD/F1 restore)
  // ===========================================================================
  assign pd_ras_restore = i_pd_redirect && !i_pipeline_ctrl.stall && !frontend_flush &&
      !i_trap_ctrl.trap_taken && !i_trap_ctrl.mret_taken && !i_fence_i_flush &&
      !i_from_ex_comb.branch_taken && !i_from_ex_comb.ras_misprediction;

  // Keep pd_ras_restore_done_q cleared now that pd_ras_restore fires only on the
  // unstalled cycle that releases the redirecting bundle from PD.
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) pd_ras_restore_done_q <= 1'b0;
    else pd_ras_restore_done_q <= 1'b0;
  end

  // Resolve F1's effective RAS checkpoint (using live u_ras outputs when the
  // window launched during a pure-pop RAS restore cycle).
  logic [RasPtrBits-1:0] f1_eff_ras_ckpt_tos;
  logic [RasPtrBits:0] f1_eff_ras_ckpt_cnt;
  logic [XLEN-1:0] f1_eff_ras_ckpt_top;
  assign f1_eff_ras_ckpt_tos = f1_req_q.ras_ckpt_from_live ? ras_tos : f1_req_q.ras_ckpt_tos;
  assign f1_eff_ras_ckpt_cnt = f1_req_q.ras_ckpt_from_live ?
      ras_valid_count : f1_req_q.ras_ckpt_cnt;
  assign f1_eff_ras_ckpt_top = f1_req_q.ras_ckpt_from_live ? ras_top : f1_req_q.ras_ckpt_top;

  // Register unified EX/PD/F1 RAS restores and their precomputed cached-region
  // flags by one cycle so ROB commit, PD redirect, and F1 validation paths
  // never drive return_address_stack's RAM write ports or ras_cached_q directly.
  assign f1_ras_restore_comb = !any_redirect && !i_from_ex_comb.ras_misprediction &&
      (f1_resteer || f1_span_tail_fault);

  logic ex_ras_top_cached;
  logic ex_ras_link_cached;
  logic pd_ras_top_cached;
  logic pd_ras_link_cached;
  logic f1_ras_top_cached;
  assign ex_ras_top_cached  = riscv_pkg::pma_cached_ok(i_from_ex_comb.ras_restore_top);
  assign ex_ras_link_cached =
      riscv_pkg::pma_cached_ok(i_from_ex_comb.ras_push_address_after_restore);
  assign pd_ras_top_cached  = riscv_pkg::pma_cached_ok(pd_ras_ckpt_top_q);
  assign pd_ras_link_cached = riscv_pkg::pma_cached_ok(i_pd_redirect_ras_link);
  assign f1_ras_top_cached  = f1_req_q.ras_ckpt_from_live ?
      ras_top_is_cached : riscv_pkg::pma_cached_ok(f1_req_q.ras_ckpt_top);

  logic ras_restore_comb;
  logic [RasPtrBits-1:0] ras_restore_tos_comb;
  logic [RasPtrBits:0] ras_restore_cnt_comb;
  logic [XLEN-1:0] ras_restore_top_comb;
  logic ras_restore_push_comb;
  logic ras_restore_pop_comb;
  logic [XLEN-1:0] ras_restore_link_comb;
  logic ras_restore_top_cached_comb;
  logic ras_restore_link_cached_comb;

  always_comb begin
    if (i_from_ex_comb.ras_misprediction) begin
      ras_restore_comb             = 1'b1;
      ras_restore_tos_comb         = i_from_ex_comb.ras_restore_tos;
      ras_restore_cnt_comb         = i_from_ex_comb.ras_restore_valid_count;
      ras_restore_top_comb         = i_from_ex_comb.ras_restore_top;
      ras_restore_push_comb        = i_from_ex_comb.ras_push_after_restore;
      ras_restore_pop_comb         = i_from_ex_comb.ras_pop_after_restore;
      ras_restore_link_comb        = i_from_ex_comb.ras_push_address_after_restore;
      ras_restore_top_cached_comb  = ex_ras_top_cached;
      ras_restore_link_cached_comb = ex_ras_link_cached;
    end else if (pd_ras_restore) begin
      ras_restore_comb             = 1'b1;
      ras_restore_tos_comb         = pd_ras_ckpt_tos_q;
      ras_restore_cnt_comb         = pd_ras_ckpt_cnt_q;
      ras_restore_top_comb         = pd_ras_ckpt_top_q;
      ras_restore_push_comb        = i_pd_redirect_ras_push;
      ras_restore_pop_comb         = i_pd_redirect_ras_pop;
      ras_restore_link_comb        = i_pd_redirect_ras_link;
      ras_restore_top_cached_comb  = pd_ras_top_cached;
      ras_restore_link_cached_comb = pd_ras_link_cached;
    end else begin
      // Default payload to F1's checkpoint so f1_ras_restore_comb drives only
      // the 1-bit restore flags and never fans out across 64-bit payload flops.
      ras_restore_comb             = f1_ras_restore_comb;
      ras_restore_tos_comb         = f1_eff_ras_ckpt_tos;
      ras_restore_cnt_comb         = f1_eff_ras_ckpt_cnt;
      ras_restore_top_comb         = f1_eff_ras_ckpt_top;
      ras_restore_push_comb        = 1'b0;
      ras_restore_pop_comb         = 1'b0;
      ras_restore_link_comb        = '0;
      ras_restore_top_cached_comb  = f1_ras_top_cached;
      ras_restore_link_cached_comb = 1'b0;
    end
  end

  logic ras_restore_nonempty_comb;
  assign ras_restore_nonempty_comb =
      (ras_restore_push_comb && !ras_restore_pop_comb) ? 1'b1 :
      (ras_restore_pop_comb && !ras_restore_push_comb) ?
          (ras_restore_cnt_comb > (RasPtrBits + 1)'(1)) :
          (ras_restore_cnt_comb != '0);

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      ras_restore_q             <= 1'b0;
      ras_restore_pure_pop_q    <= 1'b0;
      ras_restore_nonempty_q    <= 1'b0;
      ras_restore_uses_link_q   <= 1'b0;
      ras_restore_tos_q         <= '0;
      ras_restore_cnt_q         <= '0;
      ras_restore_top_q         <= '0;
      ras_restore_push_q        <= 1'b0;
      ras_restore_pop_q         <= 1'b0;
      ras_restore_link_q        <= '0;
      ras_restore_top_cached_q  <= 1'b0;
      ras_restore_link_cached_q <= 1'b0;
    end else begin
      ras_restore_q             <= ras_restore_comb;
      ras_restore_pure_pop_q    <=
          ras_restore_comb && ras_restore_pop_comb && !ras_restore_push_comb;
      ras_restore_nonempty_q    <= ras_restore_comb && ras_restore_nonempty_comb;
      ras_restore_uses_link_q   <= ras_restore_comb && ras_restore_push_comb &&
          (!ras_restore_pop_comb || (ras_restore_cnt_comb != '0));
      ras_restore_tos_q         <= ras_restore_tos_comb;
      ras_restore_cnt_q         <= ras_restore_cnt_comb;
      ras_restore_top_q         <= ras_restore_top_comb;
      ras_restore_push_q        <= ras_restore_push_comb;
      ras_restore_pop_q         <= ras_restore_pop_comb;
      ras_restore_link_q        <= ras_restore_link_comb;
      ras_restore_top_cached_q  <= ras_restore_top_cached_comb;
      ras_restore_link_cached_q <= ras_restore_link_cached_comb;
    end
  end

  assign f0_ras_push = !any_redirect && !i_from_ex_comb.ras_misprediction && !f1_ras_restore_comb &&
      !fetch_fault0_live &&
      ((f0_launch && ((f0_btb_steer_now && btb_is_call) ||
                      (f0_span_btb_fire && span_btb_pending_q.is_call))) ||
       (f1_collapsed_btb_steer && f1_req_q.btb_is_call) ||
       (f1_collapsed_span_fire && span_btb_pending_q.is_call));
  assign f0_ras_pop = !any_redirect && !i_from_ex_comb.ras_misprediction && !f1_ras_restore_comb &&
      !fetch_fault0_live &&
      ((f0_launch && ((f0_btb_steer_now && btb_is_return) ||
                      (f0_span_btb_fire && span_btb_pending_q.is_return))) ||
       (f1_collapsed_btb_steer && f1_req_q.btb_is_return) ||
       (f1_collapsed_span_fire && span_btb_pending_q.is_return));
  assign f0_ras_link = ((f0_launch && f0_span_btb_fire) || f1_collapsed_span_fire) ?
      span_btb_pending_q.link : (f1_collapsed_btb_steer ? f1_req_q.btb_link : f0_btb_link);
  assign f0_ras_link_cached = ((f0_launch && f0_span_btb_fire) || f1_collapsed_span_fire) ?
      span_btb_pending_q.link_cached :
      (f1_collapsed_btb_steer ? f1_req_q.btb_link_cached : f0_btb_link_cached);

  // Register F0's speculative push/pop by one cycle to match return_address_stack's
  // pending-op contract: o_top/o_tos/o_valid_count reflect the prior cycle's push/pop
  // with zero-cycle bypass, stay free of this cycle's own op (giving exact pre-op
  // checkpoints and exact return targets), and avoid a combinational loop through o_top.
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      f0_ras_push_q        <= 1'b0;
      f0_ras_pop_q         <= 1'b0;
      f0_ras_link_q        <= '0;
      f0_ras_link_cached_q <= 1'b0;
    end else begin
      if (any_redirect || i_from_ex_comb.ras_misprediction || f1_ras_restore_comb) begin
        f0_ras_push_q <= 1'b0;
        f0_ras_pop_q  <= 1'b0;
      end else begin
        f0_ras_push_q <= f0_ras_push;
        f0_ras_pop_q  <= f0_ras_pop;
      end
      f0_ras_link_q        <= f0_ras_link;
      f0_ras_link_cached_q <= f0_ras_link_cached;
    end
  end

  // Maintain the 8-bit cached-region shadow in lockstep with u_ras purely from
  // registered F0/restore flops.
  logic [RasPtrBits:0] ras_sh_cnt_after_push;
  logic ras_sh_restore_swap_req;
  logic ras_sh_do_restore_swap;
  logic ras_sh_do_restore_push;
  logic ras_sh_do_swap;
  logic ras_sh_do_push;
  logic [RasPtrBits-1:0] ras_sh_write_base;
  logic [RasPtrBits-1:0] ras_sh_above_addr;
  logic ras_sh_link_cached;
  logic ras_sh_top_write;
  logic ras_sh_above_write;
  logic ras_sh_top_data;

  assign ras_sh_cnt_after_push = (ras_cached_cnt_q != (RasPtrBits + 1)'(riscv_pkg::RasDepth)) ?
      (ras_cached_cnt_q + (RasPtrBits + 1)'(1)) : ras_cached_cnt_q;
  assign ras_sh_restore_swap_req = ras_restore_pop_q && ras_restore_push_q;
  assign ras_sh_do_restore_swap  =
      ras_restore_q && ras_sh_restore_swap_req && (ras_restore_cnt_q != '0);
  assign ras_sh_do_restore_push  = ras_restore_q && ras_restore_push_q && !ras_sh_restore_swap_req;
  assign ras_sh_do_swap          = !ras_restore_q && ras_sh_pending_swap;
  assign ras_sh_do_push          = !ras_restore_q && ras_sh_pending_push;
  assign ras_sh_write_base       = ras_restore_q ? ras_restore_tos_q : ras_cached_tos_q;
  assign ras_sh_above_addr       = ras_sh_write_base + RasPtrBits'(1);
  assign ras_sh_link_cached      = ras_restore_q ? ras_restore_link_cached_q : f0_ras_link_cached_q;
  assign ras_sh_top_write        = ras_restore_q || ras_sh_do_swap;
  assign ras_sh_above_write      = ras_sh_do_restore_push || ras_sh_do_push;
  assign ras_sh_top_data         = (ras_sh_do_restore_swap || ras_sh_do_swap) ?
      ras_sh_link_cached : ras_restore_top_cached_q;

  always_comb begin
    ras_sh_tos_next = ras_cached_tos_q;
    ras_sh_cnt_next = ras_cached_cnt_q;
    if (ras_sh_pending_push) begin
      ras_sh_tos_next = ras_cached_tos_q + RasPtrBits'(1);
      ras_sh_cnt_next = ras_sh_cnt_after_push;
    end else if (ras_sh_pending_pop) begin
      ras_sh_tos_next = ras_cached_tos_q - RasPtrBits'(1);
      ras_sh_cnt_next = ras_cached_cnt_q - (RasPtrBits + 1)'(1);
    end
    if (ras_restore_q) begin
      if (ras_sh_restore_swap_req) begin
        ras_sh_tos_next = ras_restore_tos_q;
        ras_sh_cnt_next = ras_restore_cnt_q;
      end else if (ras_restore_pop_q && (ras_restore_cnt_q != '0)) begin
        ras_sh_tos_next = ras_restore_tos_q - RasPtrBits'(1);
        ras_sh_cnt_next = ras_restore_cnt_q - (RasPtrBits + 1)'(1);
      end else if (ras_restore_push_q) begin
        ras_sh_tos_next = ras_restore_tos_q + RasPtrBits'(1);
        ras_sh_cnt_next = (ras_restore_cnt_q != (RasPtrBits + 1)'(riscv_pkg::RasDepth)) ?
            (ras_restore_cnt_q + (RasPtrBits + 1)'(1)) : ras_restore_cnt_q;
      end else begin
        ras_sh_tos_next = ras_restore_tos_q;
        ras_sh_cnt_next = ras_restore_cnt_q;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      ras_cached_q     <= '0;
      ras_cached_tos_q <= '0;
      ras_cached_cnt_q <= '0;
      ras_cached_ne0_q <= 1'b0;
      ras_cached_gt1_q <= 1'b0;
    end else begin
      ras_cached_tos_q <= ras_sh_tos_next;
      ras_cached_cnt_q <= ras_sh_cnt_next;
      ras_cached_ne0_q <= (ras_sh_cnt_next != '0);
      ras_cached_gt1_q <= (ras_sh_cnt_next > (RasPtrBits + 1)'(1));
      if (ras_sh_top_write) ras_cached_q[ras_sh_write_base] <= ras_sh_top_data;
      if (ras_sh_above_write) ras_cached_q[ras_sh_above_addr] <= ras_sh_link_cached;
    end
  end

  // Drive all return_address_stack write controls directly from flops.
  return_address_stack #(
      .RAS_DEPTH(riscv_pkg::RasDepth),
      .RAS_PTR_BITS(RasPtrBits)
  ) u_ras (
      .i_clk,
      .i_rst(i_pipeline_ctrl.reset),
      .i_push(f0_ras_push_q),
      .i_pop(f0_ras_pop_q),
      .i_push_address(f0_ras_link_q),
      .i_misprediction(ras_restore_q),
      .i_restore_tos(ras_restore_tos_q),
      .i_restore_valid_count(ras_restore_cnt_q),
      .i_restore_top(ras_restore_top_q),
      .i_pop_after_restore(ras_restore_pop_q),
      .i_push_after_restore(ras_restore_push_q),
      .i_push_address_after_restore(ras_restore_link_q),
      .o_nonempty(ras_nonempty),
      .o_top(ras_top),
      .o_tos(ras_tos),
      .o_valid_count(ras_valid_count)
  );

  // ===========================================================================
  // Synchronous Predictors (Backing BTB, TAGE, ITTAGE)
  // ===========================================================================
  // Keep any_redirect off pred_lookup_capture: on a redirect cycle f1_req_valid_q
  // and f1_pred_fresh_q clear on the same edge, so any captured lookup is ignored.
  logic pred_lookup_capture;
  assign pred_lookup_capture =
      (i_instr_valid && fetch_pa_valid && !f0_stop_fetch && !f1_resteer_raw &&
       !f1_collapsed_accept_raw) ||
      (!f1_req_valid_q && !i_instr_valid && fetch_pa_valid && !f0_stop_fetch);

  logic [XLEN-1:0] f1_win_pc;
  assign f1_win_pc = f1_req_q.pc;

  logic [3:0] backing_win_hit_live;
  logic [3:0] backing_win_comp_live;
  logic [3:0] backing_win_ret_live;
  logic [3:0][BackingTargetBits-1:0] backing_win_target_live;

  logic backing_refresh_q;
  logic [XLEN-1:0] backing_refresh_pc_q;
  always_ff @(posedge i_clk) begin
    backing_refresh_q    <= i_pd_backing_refresh;
    backing_refresh_pc_q <= i_pd_backing_refresh_pc;
  end

  backing_btb #(
      .XLEN(XLEN)
  ) u_backing_btb (
      .i_clk,
      .i_reset(i_pipeline_ctrl.reset),
      .i_redirect(|npc_sel[5:1]),
      .i_lookup_index(pc_tage_lookup[BackingIndexBits+1:2]),
      .i_packet_pc('0),
      .i_packet_compressed(1'b0),
      .o_hit(),
      .o_compressed(),
      .o_return(),
      .o_target(),
      .o_slot2_return_by_size(),
      .o_slot2_target_by_size(),
      .i_win_pc(f1_win_pc),
      .o_win_hit(backing_win_hit_live),
      .o_win_compressed(backing_win_comp_live),
      .o_win_return(backing_win_ret_live),
      .o_win_target(backing_win_target_live),
      .i_update(i_from_ex_comb.btb_update && i_from_ex_comb.btb_update_jump),
      .i_update_pc(i_from_ex_comb.btb_update_pc),
      .i_update_target(i_from_ex_comb.btb_update_target),
      .i_update_compressed(i_from_ex_comb.btb_update_compressed),
      .i_update_return(i_from_ex_comb.btb_update_return),
      .i_refresh(backing_refresh_q),
      .i_refresh_pc(backing_refresh_pc_q)
  );

  logic [riscv_pkg::TageLookupHiBit:2] tage_word_live;
  logic [riscv_pkg::TageLookupHiBit:2] tage_word_next_live;
  riscv_pkg::tage_lookup_t tage_bank0_live;
  riscv_pkg::tage_lookup_t tage_bank1_live;

  tage_predictor #(
      .HIST_BITS(riscv_pkg::TageDirHistBits),
      .USE_EXTERNAL_FOLD_INDEX(USE_EXTERNAL_TAGE_FOLD)
  ) u_tage_predictor (
      .i_clk,
      .i_lookup_word(pc_tage_lookup),
      .i_lookup_hist(i_tage_hist),
      .i_lookup_fold_index(i_tage_hist_fold),
      .i_lookup_capture(pred_lookup_capture),
      .o_lookup_word(tage_word_live),
      .o_lookup_word_next(tage_word_next_live),
      .o_lookup_hist(),
      .o_bank0(tage_bank0_live),
      .o_bank1(tage_bank1_live),
      .i_train_valid(i_tage_train_valid),
      .i_train_lookup(i_tage_train_lookup),
      .i_train_bank(i_tage_train_bank),
      .i_train_alt_taken(i_tage_train_alt_taken),
      .i_train_taken(i_tage_train_taken),
      .i_train_mispredicted(i_tage_train_mispredicted)
  );

  riscv_pkg::itt_lookup_t itt_bank0_live;
  riscv_pkg::itt_lookup_t itt_bank1_live;
  logic [1:0] itt_hit_live;
  logic [1:0][BackingTargetBits-1:0] itt_target_live;
  logic [riscv_pkg::TageHistBits-1:0] itt_hist_live;

  ittage_predictor u_ittage_predictor (
      .i_clk,
      .i_lookup_word(pc_tage_lookup),
      .i_lookup_hist(i_itt_hist),
      .i_lookup_capture(pred_lookup_capture),
      .o_lookup_hist(itt_hist_live),
      .o_bank0(itt_bank0_live),
      .o_bank1(itt_bank1_live),
      .o_hit(itt_hit_live),
      .o_target(itt_target_live),
      .i_train_valid(i_itt_train_valid),
      .i_train_lookup(i_itt_train_lookup),
      .i_train_bank(i_itt_train_bank),
      .i_train_target(i_itt_train_target),
      .i_train_mispredicted(i_itt_train_mispredicted)
  );

  // Select live or miss-held synchronous predictor results.
  pred_hold_t f1_pred_live;
  pred_hold_t f1_pred;
  assign f1_pred_live.tage_word      = tage_word_live;
  assign f1_pred_live.tage_word_next = tage_word_next_live;
  assign f1_pred_live.tage_bank0     = tage_bank0_live;
  assign f1_pred_live.tage_bank1     = tage_bank1_live;
  assign f1_pred_live.itt_bank0      = itt_bank0_live;
  assign f1_pred_live.itt_bank1      = itt_bank1_live;
  assign f1_pred_live.itt_hit        = itt_hit_live;
  assign f1_pred_live.itt_target     = itt_target_live;
  assign f1_pred_live.itt_hist       = itt_hist_live;
  assign f1_pred_live.backing_hit    = backing_win_hit_live;
  assign f1_pred_live.backing_comp   = backing_win_comp_live;
  assign f1_pred_live.backing_ret    = backing_win_ret_live;
  assign f1_pred_live.backing_target = backing_win_target_live;

  assign f1_pred = f1_pred_fresh_q ? f1_pred_live : f1_pred_hold_q;

  // ===========================================================================
  // F1: Tag Check, Boundary Walk, False-BTB Validation, and Window Packing
  // ===========================================================================
  // Compare both providers' 62-bit served-word tags against f1_req_q.pc in
  // parallel 3-bit-chunk LUT trees to keep carry chains and provider_q muxing
  // off the F1 accept/resteer cone.
  localparam int unsigned ServedWordBits = XLEN - 2;
  localparam int unsigned TagChunkCount = (ServedWordBits + 2) / 3;
  localparam int unsigned TagGroupCount = (TagChunkCount + 5) / 6;
  (* keep = "true" *) logic [TagChunkCount-1:0] f1_tag_low_chunk;
  (* keep = "true" *) logic [TagChunkCount-1:0] f1_tag_high_chunk;
  (* keep = "true" *) logic [TagGroupCount-1:0] f1_tag_low_group;
  (* keep = "true" *) logic [TagGroupCount-1:0] f1_tag_high_group;
  for (genvar k = 0; k < TagChunkCount; k++) begin : gen_f1_tag_chunks
    localparam int unsigned W = (ServedWordBits - 3 * k < 3) ? (ServedWordBits - 3 * k) : 3;
    assign f1_tag_low_chunk[k]  = ~|(i_served_word_low[3*k+:W] ^ f1_req_q.pc[2+3*k+:W]);
    assign f1_tag_high_chunk[k] = ~|(i_served_word_high[3*k+:W] ^ f1_req_q.pc[2+3*k+:W]);
  end
  for (genvar k = 0; k < TagGroupCount; k++) begin : gen_f1_tag_groups
    localparam int unsigned W = (TagChunkCount - 6 * k < 6) ? (TagChunkCount - 6 * k) : 6;
    assign f1_tag_low_group[k]  = &f1_tag_low_chunk[6*k+:W];
    assign f1_tag_high_group[k] = &f1_tag_high_chunk[6*k+:W];
  end
  // Fold i_instr_valid and provider selection into the 4-bit group reductions
  // so each provider's qualified tag match takes a single 6-input LUT6 and
  // f1_push_valid resolves in one LUT5 immediately behind it.
  (* keep = "true" *) logic f1_tag_match_low_valid;
  (* keep = "true" *) logic f1_tag_match_high_valid;
  assign f1_tag_match_low_valid =
      (&f1_tag_low_group) && i_instr_valid && !i_instr_pc_metadata_served_high;
  assign f1_tag_match_high_valid =
      (&f1_tag_high_group) && i_instr_valid && i_instr_pc_metadata_served_high;

  assign f1_accept_raw = f1_req_valid_q && (f1_tag_match_low_valid || f1_tag_match_high_valid);
  // collapsed_armed_q is only set after fetch_pa_valid was observed for this
  // PC, so keep live u_immu translation valid off the F1 accept cone.
  assign f1_collapsed_accept_raw = !f1_req_valid_q && collapsed_armed_q && !f0_stop_fetch &&
      (f1_tag_match_low_valid || f1_tag_match_high_valid);
  assign f1_tag_resteer_raw = f1_req_valid_q && i_instr_valid &&
      !(f1_tag_match_low_valid || f1_tag_match_high_valid);

  assign f1_accept = !any_redirect && f1_accept_raw;
  assign f1_tag_resteer = !any_redirect && f1_tag_resteer_raw;
  assign f1_collapsed_accept = !any_redirect && f1_collapsed_accept_raw;

  // Extract the four halfwords and their predecode sideband fields from i_instr.
  logic [15:0] hw_raw[4];
  logic [3:0] hw_comp;
  logic [3:0] hw_allows_s2;
  logic [3:0] hw_s2_start_valid;
  logic [3:0] hw_is_indirect;
  logic [3:0] hw_is_control;
  logic [1:0] hw_rvc_src_hot[4];
  logic [4:0] hw_rvc_b24_20[4];
  logic [2:0] hw_rvc_rs1_rest[4];
  logic [22:0] hw_rvc_extra[4];
  logic [3:0] hw_fault;
  logic [3:0] hw_fault_page;

  logic [SbWidth-1:0] sb_w0;
  logic [SbWidth-1:0] sb_w1;
  assign sb_w0 = i_instr_sideband[SbWidth-1:0];
  assign sb_w1 = i_instr_sideband[2*SbWidth-1:SbWidth];

  assign hw_raw[0] = i_instr[15:0];
  assign hw_raw[1] = i_instr[31:16];
  assign hw_raw[2] = i_instr[47:32];
  assign hw_raw[3] = i_instr[63:48];

  assign hw_comp[0] = sb_w0[riscv_pkg::ImemSbIsCompressedLo];
  assign hw_comp[1] = sb_w0[riscv_pkg::ImemSbIsCompressedHi];
  assign hw_comp[2] = sb_w1[riscv_pkg::ImemSbIsCompressedLo];
  assign hw_comp[3] = sb_w1[riscv_pkg::ImemSbIsCompressedHi];

  assign hw_allows_s2[0] = sb_w0[riscv_pkg::ImemSbAllowsSlot2AfterLo];
  assign hw_allows_s2[1] = sb_w0[riscv_pkg::ImemSbAllowsSlot2AfterHi];
  assign hw_allows_s2[2] = sb_w1[riscv_pkg::ImemSbAllowsSlot2AfterLo];
  assign hw_allows_s2[3] = sb_w1[riscv_pkg::ImemSbAllowsSlot2AfterHi];

  assign hw_s2_start_valid[0] = sb_w0[riscv_pkg::ImemSbSlot2StartValidLo];
  assign hw_s2_start_valid[1] = sb_w0[riscv_pkg::ImemSbSlot2StartValidHi];
  assign hw_s2_start_valid[2] = sb_w1[riscv_pkg::ImemSbSlot2StartValidLo];
  assign hw_s2_start_valid[3] = sb_w1[riscv_pkg::ImemSbSlot2StartValidHi];

  assign hw_is_indirect[0] = sb_w0[riscv_pkg::ImemSbIsIndirectLo];
  assign hw_is_indirect[1] = sb_w0[riscv_pkg::ImemSbIsIndirectHi];
  assign hw_is_indirect[2] = sb_w1[riscv_pkg::ImemSbIsIndirectLo];
  assign hw_is_indirect[3] = sb_w1[riscv_pkg::ImemSbIsIndirectHi];

  assign hw_rvc_src_hot[0] = sb_w0[riscv_pkg::ImemSbRvcSourceHotLoLsb+:2];
  assign hw_rvc_src_hot[1] = sb_w0[riscv_pkg::ImemSbRvcSourceHotHiLsb+:2];
  assign hw_rvc_src_hot[2] = sb_w1[riscv_pkg::ImemSbRvcSourceHotLoLsb+:2];
  assign hw_rvc_src_hot[3] = sb_w1[riscv_pkg::ImemSbRvcSourceHotHiLsb+:2];

  assign hw_rvc_b24_20[0] = sb_w0[riscv_pkg::ImemSbRvcBits24To20LoLsb+:5];
  assign hw_rvc_b24_20[1] = sb_w0[riscv_pkg::ImemSbRvcBits24To20HiLsb+:5];
  assign hw_rvc_b24_20[2] = sb_w1[riscv_pkg::ImemSbRvcBits24To20LoLsb+:5];
  assign hw_rvc_b24_20[3] = sb_w1[riscv_pkg::ImemSbRvcBits24To20HiLsb+:5];

  assign hw_rvc_rs1_rest[0] = sb_w0[riscv_pkg::ImemSbRvcRs1RestLoLsb+:3];
  assign hw_rvc_rs1_rest[1] = sb_w0[riscv_pkg::ImemSbRvcRs1RestHiLsb+:3];
  assign hw_rvc_rs1_rest[2] = sb_w1[riscv_pkg::ImemSbRvcRs1RestLoLsb+:3];
  assign hw_rvc_rs1_rest[3] = sb_w1[riscv_pkg::ImemSbRvcRs1RestHiLsb+:3];

  assign hw_rvc_extra[0] = sb_w0[riscv_pkg::ImemSbRvcExtraLoLsb+:23];
  assign hw_rvc_extra[1] = sb_w0[riscv_pkg::ImemSbRvcExtraHiLsb+:23];
  assign hw_rvc_extra[2] = sb_w1[riscv_pkg::ImemSbRvcExtraLoLsb+:23];
  assign hw_rvc_extra[3] = sb_w1[riscv_pkg::ImemSbRvcExtraHiLsb+:23];

  // Propagate launch-cycle spanning-branch fault vetoes into F1 word-0 fault
  // purely from registered f1_req_q.span_veto (captured on both F0 launch and
  // collapsed-lead arming) so live u_immu faults never enter F1, the parcel
  // queue, or PD.
  logic f1_fault0_eff;
  assign f1_fault0_eff = i_instr_fault0 || f1_req_q.span_veto;
  assign hw_fault      = {i_instr_fault1, i_instr_fault1, f1_fault0_eff, f1_fault0_eff};
  assign hw_fault_page = {
    i_instr_fault1_page, i_instr_fault1_page, i_instr_fault0_page, i_instr_fault0_page
  };

  // Reuse predecoded hw_is_indirect (JALR / C.JR / C.JALR) so compressed
  // control classification depends only on bits [15:13] and [1:0].
  for (genvar h = 0; h < 4; h++) begin : gen_hw_ctrl
    assign hw_is_control[h] = hw_comp[h] ?
        (hw_is_indirect[h] ||
         ((hw_raw[h][1:0] == 2'b01) && hw_raw[h][15] && (hw_raw[h][14] || hw_raw[h][13]))) :
        ((hw_raw[h][6:4] == 3'b110) && (hw_raw[h][3:2] != 2'b10));
  end

  // Walk instruction boundaries directly from flop-only entry state.
  // Because f1_btb_ok requires !f1_btb_fault (which guarantees word 0 did not
  // fault, and word 1 did not fault when btb_pos >= 2), boundary validity at
  // f1_btb_pos depends only on 6 inputs (f1_start_at_1, f1_btb_pos[1:0], and
  // hw_comp[2:0]) and folds into one LUT6.
  logic f1_start_off;
  logic f1_is_span_tail;
  logic f1_start_at_1;

  assign f1_start_off    = f1_start_off_q;
  assign f1_is_span_tail = f1_req_valid_q ? f1_req_q.span_tail : span_btb_valid_q;
  assign f1_start_at_1   = f1_start_off || (!f1_is_span_tail && f1_carry_hi_q);

  // Validate F0's registered fast-BTB prediction against actual instruction
  // boundaries, size, control-flow opcode class, and fetch faults. Both normal
  // F1 accepts and collapsed-lead accepts read from f1_req_q flops so F0's
  // BTB/dir/RAS/IMMU lookup never chains into F1, the parcel queue, or PD.
  logic f1_collapsed_btb_en;
  logic f1_src_btb_taken;
  logic f1_src_btb_is_span;
  logic [1:0] f1_src_btb_pos;
  logic f1_src_btb_comp;
  logic [XLEN-1:0] f1_src_btb_target;

  assign f1_collapsed_btb_en = !i_disable_branch_prediction && !btb_invalidate_active;
  assign f1_src_btb_taken   = f1_req_valid_q ?
      f1_req_q.btb_taken : (f1_req_q.btb_taken && f1_collapsed_btb_en);
  assign f1_src_btb_is_span = f1_req_q.btb_is_span;
  assign f1_src_btb_pos     = f1_req_q.btb_pos;
  assign f1_src_btb_comp    = f1_req_q.btb_comp;
  assign f1_src_btb_target  = f1_req_q.btb_target;

  logic [1:0] f1_btb_pos;
  logic f1_btb_fault;
  (* keep = "true" *) logic f1_btb_valid_start;
  logic [15:0] btb_hw_raw;
  logic btb_hw_comp;
  logic btb_hw_indirect;
  logic btb_ctrl_comp;
  logic btb_ctrl_nat;
  logic f1_btb_ok;
  logic f1_btb_taken_raw;
  logic f1_valid_btb_taken;
  logic f1_false_btb;

  assign f1_btb_pos = f1_src_btb_pos;
  assign f1_btb_fault = f1_fault0_eff ||
      (i_instr_fault1 && (f1_btb_pos[1] || (f1_btb_pos == 2'd1 && !hw_comp[1])));

  always_comb begin
    logic vs1_nf;
    logic vs2_nf;
    vs1_nf = f1_start_at_1 || hw_comp[0];
    vs2_nf = vs1_nf ? hw_comp[1] : 1'b1;
    unique case (f1_btb_pos)
      2'd0:    f1_btb_valid_start = !f1_start_at_1;
      2'd1:    f1_btb_valid_start = vs1_nf;
      2'd2:    f1_btb_valid_start = vs2_nf;
      default: f1_btb_valid_start = (vs1_nf && !hw_comp[1]) || (vs2_nf && hw_comp[2]);
    endcase
  end

  // Pre-select the predicted halfword by registered f1_btb_pos so control-flow
  // validation runs in three shallow LUT levels without chaining through all
  // four hw_is_control cones.
  assign btb_hw_raw      = hw_raw[f1_btb_pos];
  assign btb_hw_comp     = hw_comp[f1_btb_pos];
  assign btb_hw_indirect = hw_is_indirect[f1_btb_pos];
  assign btb_ctrl_comp   = btb_hw_indirect ||
      ((btb_hw_raw[1:0] == 2'b01) && btb_hw_raw[15] && (btb_hw_raw[14] || btb_hw_raw[13]));
  assign btb_ctrl_nat    = (btb_hw_raw[6:4] == 3'b110) && (btb_hw_raw[3:2] != 2'b10);
  assign f1_btb_ok       = f1_btb_valid_start && (btb_hw_comp == f1_src_btb_comp) &&
      (f1_src_btb_comp ? btb_ctrl_comp : btb_ctrl_nat) && !f1_btb_fault;

  // Redirect-free, tag-match-free, and IMMU-free taken flag for parcel packing
  // and push count. If a spanning branch's second word faults at F0, that next
  // window carries fault=1 on hw[0], so drain clears btb_predicted_taken via
  // s1_fault_hi / s2_fault when the 32-bit instruction assembles.
  assign f1_btb_taken_raw   = !f1_is_span_tail && f1_src_btb_taken && f1_btb_ok;
  assign f1_valid_btb_taken = (f1_accept || f1_collapsed_accept) && f1_btb_taken_raw;

  assign f1_false_btb_raw         =
      f1_accept_raw && !f1_req_q.span_tail && f1_req_q.btb_taken && !f1_btb_ok;
  assign f1_cancel_span_raw       = f1_false_btb_raw && f1_req_q.btb_is_span;
  assign f1_false_btb_resteer_raw = f1_false_btb_raw && !f1_req_q.btb_is_span;
  assign f1_false_btb             = !any_redirect && f1_false_btb_raw;
  assign f1_cancel_span           = !any_redirect && f1_cancel_span_raw;
  assign f1_false_btb_resteer     = !any_redirect && f1_false_btb_resteer_raw;
  assign f1_span_tail_fault       = f1_accept && f1_req_q.span_tail && f1_fault0_eff;

  assign f1_collapsed_btb_steer_raw = !span_btb_valid_q &&
      f1_req_q.btb_taken && !f1_req_q.btb_is_span && f1_collapsed_btb_en && f1_btb_ok;
  assign f1_collapsed_btb_steer = f1_collapsed_accept && f1_collapsed_btb_steer_raw;
  assign f1_collapsed_btb_span_raw = f1_collapsed_accept_raw && !span_btb_valid_q &&
      f1_req_q.btb_taken && f1_req_q.btb_is_span && f1_collapsed_btb_en && f1_btb_ok;
  assign f1_collapsed_btb_span = !any_redirect && f1_collapsed_btb_span_raw;
  assign f1_collapsed_span_fire_raw = span_btb_valid_q &&
      !i_instr_fault0 && !f1_req_q.span_veto;
  assign f1_collapsed_span_fire = f1_collapsed_accept && f1_collapsed_span_fire_raw;

  assign f1_resteer_raw = f1_tag_resteer_raw || f1_false_btb_resteer_raw;
  assign f1_resteer = !any_redirect && f1_resteer_raw;
  assign f1_resteer_target = f1_tag_resteer_raw ?
      f1_req_q.pc : {f1_req_q.pc[XLEN-1:2] + (XLEN - 2)'(2), 2'b00};

  // F0 launches a new fetch when memory is valid, translation is ready, the
  // parcel queue has headroom, and no redirect, resteer, or collapsed accept
  // is taking this cycle.
  assign f0_launch_raw = i_instr_valid && fetch_pa_valid && !f0_stop_fetch &&
      !f1_resteer_raw && !f1_collapsed_accept_raw;
  assign f0_launch = !any_redirect && f0_launch_raw;

  // Next f1_carry_hi_q after an accepted window: set when a non-taken (or
  // spanning-taken, in case W+2 faults and drops span_tail) non-faulting
  // 32-bit instruction starts at hw[3] and extends into W+2:0.
  logic valid_start_hw3;
  always_comb begin
    logic c0_f, c1_f, vs1_f, vs2_f;
    c0_f  = hw_comp[0] || f1_fault0_eff;
    c1_f  = hw_comp[1] || f1_fault0_eff;
    vs1_f = f1_start_at_1 || c0_f;
    vs2_f = vs1_f ? c1_f : 1'b1;
    valid_start_hw3 = (vs1_f && !c1_f) || (vs2_f && hw_comp[2]);
  end

  logic f1_next_carry_hi;
  assign f1_next_carry_hi = !f1_is_span_tail && (!f1_btb_taken_raw || f1_src_btb_is_span) &&
      valid_start_hw3 && !hw_comp[3] && !i_instr_fault1;

  // Build the four candidate parcels and pack them left-aligned for the queue.
  // Use scalar packed structs rather than an unpacked array of structs so
  // Yosys resolves every field select cleanly.
  logic [3:0] f1_dir_taken;
  assign f1_dir_taken = f1_req_q.dir_taken;

  function automatic parcel_t make_parcel(
      input logic [15:0] p_raw, input logic p_allows_s2,
      input logic p_s2_start, input logic p_indirect, input logic p_ctrl,
      input logic [1:0] p_src_hot, input logic [4:0] p_b24_20, input logic [2:0] p_rs1_rest,
      input logic [22:0] p_extra, input logic [1:0] p_hw_idx, input logic p_fault,
      input logic p_fault_page, input logic p_dir, input logic p_btb_taken,
      input logic p_bk_hit, input logic p_bk_comp, input logic p_bk_ret,
      input logic [BackingTargetBits-1:0] p_bk_tgt);
    parcel_t res;
    res.parcel             = p_raw;
    res.allows_slot2_after = p_allows_s2;
    res.slot2_start_valid  = p_s2_start;
    res.is_indirect        = p_indirect;
    res.is_control         = p_ctrl;
    res.rvc_source_hot     = p_src_hot;
    res.rvc_bits24_20      = p_b24_20;
    res.rvc_rs1_rest       = p_rs1_rest;
    res.rvc_extra          = p_extra;
    res.hw_in_win          = p_hw_idx;
    res.fault              = p_fault;
    res.fault_page         = p_fault_page;
    res.bp_dir_taken       = p_dir;
    res.btb_taken          = p_btb_taken;
    res.backing_hit        = p_bk_hit;
    res.backing_compressed = p_bk_comp;
    res.backing_return     = p_bk_ret;
    res.backing_target     = p_bk_tgt;
    make_parcel = res;
  endfunction

  parcel_t f1_raw_p0, f1_raw_p1, f1_raw_p2, f1_raw_p3;
  assign f1_raw_p0 = make_parcel(
      hw_raw[0], hw_allows_s2[0], hw_s2_start_valid[0], hw_is_indirect[0],
      hw_is_control[0], hw_rvc_src_hot[0], hw_rvc_b24_20[0], hw_rvc_rs1_rest[0], hw_rvc_extra[0],
      2'd0, hw_fault[0], hw_fault_page[0], f1_dir_taken[0],
      f1_btb_taken_raw && (f1_btb_pos == 2'd0),
      f1_pred.backing_hit[0], f1_pred.backing_comp[0], f1_pred.backing_ret[0],
      f1_pred.backing_target[0]
  );
  assign f1_raw_p1 = make_parcel(
      hw_raw[1], hw_allows_s2[1], hw_s2_start_valid[1], hw_is_indirect[1],
      hw_is_control[1], hw_rvc_src_hot[1], hw_rvc_b24_20[1], hw_rvc_rs1_rest[1], hw_rvc_extra[1],
      2'd1, hw_fault[1], hw_fault_page[1], f1_dir_taken[1],
      f1_btb_taken_raw && (f1_btb_pos == 2'd1),
      f1_pred.backing_hit[1], f1_pred.backing_comp[1], f1_pred.backing_ret[1],
      f1_pred.backing_target[1]
  );
  assign f1_raw_p2 = make_parcel(
      hw_raw[2], hw_allows_s2[2], hw_s2_start_valid[2], hw_is_indirect[2],
      hw_is_control[2], hw_rvc_src_hot[2], hw_rvc_b24_20[2], hw_rvc_rs1_rest[2], hw_rvc_extra[2],
      2'd2, hw_fault[2], hw_fault_page[2], f1_dir_taken[2],
      f1_btb_taken_raw && (f1_btb_pos == 2'd2),
      f1_pred.backing_hit[2], f1_pred.backing_comp[2], f1_pred.backing_ret[2],
      f1_pred.backing_target[2]
  );
  assign f1_raw_p3 = make_parcel(
      hw_raw[3], hw_allows_s2[3], hw_s2_start_valid[3], hw_is_indirect[3],
      hw_is_control[3], hw_rvc_src_hot[3], hw_rvc_b24_20[3], hw_rvc_rs1_rest[3], hw_rvc_extra[3],
      2'd3, hw_fault[3], hw_fault_page[3], f1_dir_taken[3],
      f1_btb_taken_raw && (f1_btb_pos == 2'd3),
      f1_pred.backing_hit[3], f1_pred.backing_comp[3], f1_pred.backing_ret[3],
      f1_pred.backing_target[3]
  );

  (* keep = "true", max_fanout = 64 *) logic f1_push_valid;
  logic [2:0] f1_push_count;
  logic [3:0][ParcelBits-1:0] f1_push_parcels;
  logic [1:0] btb_end_hw;
  logic [2:0] f1_push_count_taken;
  logic [2:0] f1_push_count_notaken;
  // Pass redirect-free push valid to u_parcel_queue; u_parcel_queue resets
  // pointers and counts synchronously when i_flush (pqueue_flush) fires.
  // Combine both providers' qualified tag matches directly into one LUT5.
  assign f1_push_valid = (f1_tag_match_low_valid || f1_tag_match_high_valid) &&
      (f1_req_valid_q || (collapsed_armed_q && !f0_stop_fetch));
  // When f1_btb_taken_raw holds, f1_src_btb_comp matches hw_comp[f1_btb_pos],
  // so both candidate push counts depend only on registered F1 state.
  assign btb_end_hw = f1_src_btb_pos + (f1_src_btb_comp ? 2'd0 : 2'd1);
  assign f1_push_count_taken = {1'b0, btb_end_hw} - {2'b00, f1_start_off} + 3'd1;
  assign f1_push_count_notaken = f1_is_span_tail ? 3'd1 : (f1_start_off ? 3'd3 : 3'd4);
  assign f1_push_count = (f1_btb_taken_raw && !f1_src_btb_is_span) ?
      f1_push_count_taken : f1_push_count_notaken;

  assign f1_push_parcels[0] = f1_start_off ? f1_raw_p1 : f1_raw_p0;
  assign f1_push_parcels[1] = f1_start_off ? f1_raw_p2 : f1_raw_p1;
  assign f1_push_parcels[2] = f1_start_off ? f1_raw_p3 : f1_raw_p2;
  assign f1_push_parcels[3] = f1_raw_p3;

  // Build window metadata record in window-word order (w0 = W, w1 = W+1).
  meta_t f1_push_meta;
  logic f1_w0_odd;
  logic [riscv_pkg::TageLookupHiBit:2] f1_tage_w0_tag;
  logic [riscv_pkg::TageLookupHiBit:2] f1_tage_w1_tag;
  logic [1:0] f1_tage_cov;

  assign f1_w0_odd      = f1_win_pc[2];
  assign f1_tage_w0_tag = f1_win_pc[riscv_pkg::TageLookupHiBit:2];
  assign f1_tage_w1_tag = (riscv_pkg::TageLookupHiBit - 1)'(f1_tage_w0_tag + 1'b1);
  assign f1_tage_cov[0] = (f1_pred.tage_word == f1_tage_w0_tag);
  assign f1_tage_cov[1] = (f1_pred.tage_word_next == f1_tage_w1_tag);

  always_comb begin
    f1_push_meta.word0_pc      = f1_win_pc[XLEN-1:2];
    f1_push_meta.word1_pc      = f1_win_pc[XLEN-1:2] + (XLEN - 2)'(1);
    f1_push_meta.btb_target_hi = f1_src_btb_target[XLEN-1:1];
    f1_push_meta.ras_ckpt_tos  = f1_eff_ras_ckpt_tos;
    f1_push_meta.ras_ckpt_cnt  = f1_eff_ras_ckpt_cnt;
    f1_push_meta.ras_ckpt_top  = f1_eff_ras_ckpt_top;
    f1_push_meta.tage_cov      = f1_tage_cov;
    f1_push_meta.tage_w0       = f1_w0_odd ? f1_pred.tage_bank1 : f1_pred.tage_bank0;
    f1_push_meta.tage_w1       = f1_w0_odd ? f1_pred.tage_bank0 : f1_pred.tage_bank1;
    f1_push_meta.itt_w0        = f1_w0_odd ? f1_pred.itt_bank1 : f1_pred.itt_bank0;
    f1_push_meta.itt_w1        = f1_w0_odd ? f1_pred.itt_bank0 : f1_pred.itt_bank1;
    f1_push_meta.itt_hit[0]    =
        f1_tage_cov[0] && (f1_w0_odd ? f1_pred.itt_hit[1] : f1_pred.itt_hit[0]);
    f1_push_meta.itt_hit[1]    =
        f1_tage_cov[1] && (f1_w0_odd ? f1_pred.itt_hit[0] : f1_pred.itt_hit[1]);
    f1_push_meta.itt_target[0] = f1_w0_odd ? f1_pred.itt_target[1] : f1_pred.itt_target[0];
    f1_push_meta.itt_target[1] = f1_w0_odd ? f1_pred.itt_target[0] : f1_pred.itt_target[1];
    f1_push_meta.itt_hist      = f1_pred.itt_hist;
  end

  // Provider claim & replay handshakes (no stall replay in decoupled front end).
  assign o_fetch_live_claim = !any_redirect && f1_push_valid && !f0_self_loop;
  assign o_fetch_replay_consume = 1'b0;

  // ===========================================================================
  // F0/F1 Pipeline State Registers
  // ===========================================================================
  // Keep wide payload registers (f1_pred_hold_q, f1_req_q, span_btb_pending_q)
  // in separate always_ff blocks with shallow enables so tag-match and redirect
  // trees never drive hundreds of clock-enable pins.
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      f1_req_valid_q      <= 1'b0;
      span_btb_valid_q    <= 1'b0;
      f1_carry_hi_q       <= 1'b0;
      f1_pred_fresh_q     <= 1'b0;
      collapsed_armed_q   <= 1'b0;
      f1_resteer_nopred_q <= 1'b0;
    end else if (any_redirect) begin
      f1_req_valid_q      <= 1'b0;
      span_btb_valid_q    <= 1'b0;
      f1_carry_hi_q       <= 1'b0;
      f1_pred_fresh_q     <= 1'b0;
      collapsed_armed_q   <= 1'b0;
      f1_resteer_nopred_q <= 1'b0;
    end else if (f1_resteer) begin
      f1_req_valid_q      <= 1'b0;
      span_btb_valid_q    <= f1_tag_resteer && (f1_req_q.span_tail || f1_req_q.span_veto);
      f1_pred_fresh_q     <= 1'b0;
      collapsed_armed_q   <= 1'b0;
      f1_resteer_nopred_q <= f1_tag_resteer;
      if (f1_false_btb_resteer) begin
        f1_carry_hi_q <= f1_next_carry_hi;
      end
    end else if (f0_launch) begin
      f1_req_valid_q      <= 1'b1;
      f1_pred_fresh_q     <= 1'b1;
      collapsed_armed_q   <= 1'b0;
      f1_resteer_nopred_q <= 1'b0;
      span_btb_valid_q    <= f0_btb_valid && btb_is_span;
      if (f1_accept) begin
        f1_carry_hi_q <= f1_next_carry_hi;
      end
    end else if (f1_collapsed_accept) begin
      f1_req_valid_q      <= 1'b0;
      f1_pred_fresh_q     <= 1'b0;
      collapsed_armed_q   <= 1'b0;
      f1_resteer_nopred_q <= 1'b0;
      f1_carry_hi_q       <= f1_next_carry_hi;
      span_btb_valid_q    <= f1_collapsed_btb_span;
    end else begin
      if (f1_accept) begin
        f1_req_valid_q  <= 1'b0;
        f1_pred_fresh_q <= 1'b0;
        f1_carry_hi_q   <= f1_next_carry_hi;
        if (f1_cancel_span) span_btb_valid_q <= 1'b0;
      end else if (f1_req_valid_q && !i_instr_valid) begin
        if (f1_pred_fresh_q) begin
          f1_pred_fresh_q <= 1'b0;
        end
      end else if (!f1_req_valid_q && !i_instr_valid && fetch_pa_valid && !f0_stop_fetch) begin
        collapsed_armed_q <= 1'b1;
        f1_pred_fresh_q   <= 1'b1;
      end else if (!f1_req_valid_q && i_instr_valid && f1_pred_fresh_q) begin
        f1_pred_fresh_q <= 1'b0;
      end
    end
  end

  // Capture live synchronous predictor outputs whenever f1_pred_fresh_q is
  // asserted so the hold latch is always valid if the next cycle stalls on a miss.
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      f1_pred_hold_q <= '0;
    end else if (f1_pred_fresh_q) begin
      f1_pred_hold_q <= f1_pred_live;
    end
  end

  // Load F1 request payload on F0 launch or collapsed-lead arming without
  // gating on tag-match, resteer, or redirect (every non-launch cycle where
  // i_instr_valid is high clears both f1_req_valid_q and collapsed_armed_q).
  (* keep = "true", max_fanout = 64 *) logic f1_req_data_we;
  assign f1_req_data_we = fetch_pa_valid && !f0_stop_fetch && (i_instr_valid || !f1_req_valid_q);

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      f1_req_q       <= '0;
      f1_start_off_q <= 1'b0;
    end else if (f1_req_data_we) begin
      f1_req_q.pc                 <= pc;
      f1_start_off_q              <= pc[1];
      f1_req_q.span_veto          <= f0_span_fault_veto;
      f1_req_q.span_tail          <= i_instr_valid && f0_span_btb_fire;
      f1_req_q.btb_taken          <= f0_btb_valid;
      f1_req_q.btb_is_span        <= f0_btb_valid && btb_is_span;
      f1_req_q.btb_pos            <= btb_taken_pos;
      f1_req_q.btb_comp           <= btb_compressed;
      f1_req_q.btb_target         <= f0_btb_eff_target;
      f1_req_q.btb_even_dir_idx   <= f0_btb_even_dir_idx;
      f1_req_q.btb_is_call        <= btb_is_call;
      f1_req_q.btb_is_return      <= btb_is_return;
      f1_req_q.btb_link           <= f0_btb_link;
      f1_req_q.btb_link_cached    <= f0_btb_link_cached;
      f1_req_q.dir_taken          <= dir_taken_f0;
      f1_req_q.ras_ckpt_tos       <= eff_ras_tos;
      f1_req_q.ras_ckpt_cnt       <= eff_ras_cnt;
      f1_req_q.ras_ckpt_top       <= eff_ras_top;
      f1_req_q.ras_ckpt_from_live <= ras_restore_pure_pop_q;
    end
  end

  // Keep any_redirect off span_btb_pending_q payload CE (any_redirect clears
  // span_btb_valid_q and f1_req_valid_q on the same edge).
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      span_btb_pending_q <= '0;
    end else if (f0_launch_raw && f0_btb_valid && btb_is_span) begin
      span_btb_pending_q.target       <= f0_btb_eff_target;
      span_btb_pending_q.even_dir_idx <= f0_btb_even_dir_idx;
      span_btb_pending_q.is_call      <= btb_is_call;
      span_btb_pending_q.is_return    <= btb_is_return;
      span_btb_pending_q.link         <= f0_btb_link;
      span_btb_pending_q.link_cached  <= f0_btb_link_cached;
    end else if (f1_collapsed_btb_span_raw) begin
      span_btb_pending_q.target       <= f1_req_q.btb_target;
      span_btb_pending_q.even_dir_idx <= f1_req_q.btb_even_dir_idx;
      span_btb_pending_q.is_call      <= f1_req_q.btb_is_call;
      span_btb_pending_q.is_return    <= f1_req_q.btb_is_return;
      span_btb_pending_q.link         <= f1_req_q.btb_link;
      span_btb_pending_q.link_cached  <= f1_req_q.btb_link_cached;
    end
  end

  // ===========================================================================
  // Parcel Queue (16 halfwords + 8 window metadata entries, 0-cycle bypass)
  // ===========================================================================
  logic [2:0] q_pop_count;
  logic [4:0] q_avail;
  logic [3:0] q_avail_ge;
  logic [3:0] q_count_ge;
  logic [3:0] q_avail_ge_drain;
  logic [3:0][ParcelBits-1:0] q_view_raw;
  logic [3:0] q_view_last;
  logic [1:0] q_ring_last;
  logic q_count_eq1;
  logic q_count_ge2;
  logic [MetaBits-1:0] q_meta0_raw;
  logic [MetaBits-1:0] q_meta1_raw;

  fetch_parcel_queue #(
      .PARCEL_WIDTH(ParcelBits),
      .META_WIDTH(MetaBits),
      .DEPTH(16),
      .META_DEPTH(8),
      .STOP_PARCEL_THRESH(8),
      .STOP_META_THRESH(7)
  ) u_parcel_queue (
      .i_clk,
      .i_rst(i_pipeline_ctrl.reset),
      .i_flush(pqueue_flush),
      .i_push_valid(f1_push_valid),
      .i_push_count(f1_push_count),
      .i_push_parcels(f1_push_parcels),
      .i_push_meta(f1_push_meta),
      .i_pop_count(q_pop_count),
      .o_avail(q_avail),
      .o_avail_ge(q_avail_ge),
      .o_count_ge(q_count_ge),
      .o_view_parcels(q_view_raw),
      .o_view_last(q_view_last),
      .o_ring_last(q_ring_last),
      .o_count_eq1(q_count_eq1),
      .o_count_ge2(q_count_ge2),
      .o_meta0(q_meta0_raw),
      .o_meta1(q_meta1_raw),
      .o_stop_fetch(q_stop_fetch)
  );

  // Derive drain availability from registered occupancy and f1_push_valid
  // without waiting for f1_push_count: a validated BTB hit always pushes all
  // halfwords through the end of that control instruction (stopping slot 2 via
  // allows_slot2_after), so push truncation never shortens a valid slot-1 or
  // pairable slot-2 instruction.
  assign q_avail_ge_drain[0] = q_count_ge[0] || f1_push_valid;
  assign q_avail_ge_drain[1] = q_count_ge[1] ||
      (f1_push_valid && (f1_is_span_tail ? q_count_ge[0] : 1'b1));
  assign q_avail_ge_drain[2] = q_count_ge[2] ||
      (f1_push_valid && (f1_is_span_tail ? q_count_ge[1] : 1'b1));
  assign q_avail_ge_drain[3] = q_count_ge[3] ||
      (f1_push_valid && (f1_is_span_tail ? q_count_ge[2] : (q_count_ge[0] || !f1_start_off)));

  parcel_t view0, view1, view2, view3;
  meta_t meta0;
  meta_t meta1;
  assign view0 = q_view_raw[0];
  assign view1 = q_view_raw[1];
  assign view2 = q_view_raw[2];
  assign view3 = q_view_raw[3];
  assign meta0 = q_meta0_raw;
  assign meta1 = q_meta1_raw;

  // ===========================================================================
  // Drain: Slot 1 & Slot 2 Alignment, Pairing, Expansion, and PD Targets
  // ===========================================================================
  function automatic logic [riscv_pkg::PdTargetSplit-1:0] native_branch_imm_low(
      input logic [31:0] instr);
    native_branch_imm_low = {instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
  endfunction

  function automatic logic [riscv_pkg::PdTargetSplit-1:0] compressed_branch_imm_low(
      input logic [15:0] parcel);
    compressed_branch_imm_low = {
      {(riscv_pkg::PdTargetSplit - 9) {parcel[12]}},
      parcel[12],
      parcel[6:5],
      parcel[2],
      parcel[11:10],
      parcel[4:3],
      1'b0
    };
  endfunction

  // ---- Slot 1 ----
  parcel_t s1_p;
  meta_t s1_m;
  assign s1_p = view0;
  assign s1_m = meta0;

  logic s1_comp;
  logic s1_fault_lo;
  logic s1_fault_hi;
  logic s1_fault;
  logic s1_fault_page;
  logic s1_need_2;
  logic s1_have_bytes;
  logic s1_valid_raw;
  logic s1_valid;

  assign s1_comp       = (s1_p.parcel[1:0] != 2'b11);
  assign s1_fault_lo   = s1_p.fault;
  assign s1_fault_hi   = !s1_fault_lo && !s1_comp && view1.fault;
  assign s1_fault      = s1_fault_lo || s1_fault_hi;
  assign s1_fault_page = s1_fault_lo ? s1_p.fault_page : view1.fault_page;
  assign s1_need_2     = !s1_fault_lo && !s1_comp;
  assign s1_have_bytes = s1_need_2 ? q_avail_ge_drain[1] : q_avail_ge_drain[0];
  assign s1_valid_raw  = !i_fetch_trap_hold && s1_have_bytes;
  assign s1_valid      = !pqueue_flush && s1_valid_raw;

  logic [XLEN-1:0] s1_pc;
  logic [31:0] s1_instr;
  assign s1_pc    = {s1_p.hw_in_win[1] ? s1_m.word1_pc : s1_m.word0_pc, s1_p.hw_in_win[0], 1'b0};
  assign s1_instr = {view1.parcel, s1_p.parcel};

  logic [2:0] s1_source_hot;
  logic [4:0] s1_bits24_20;
  logic [2:0] s1_rs1_rest;
  assign s1_source_hot = s1_comp ?
      {s1_p.rvc_bits24_20[1], s1_p.rvc_source_hot} : {s1_instr[21], s1_instr[17:16]};
  assign s1_bits24_20  = s1_comp ? s1_p.rvc_bits24_20 : s1_instr[24:20];
  assign s1_rs1_rest   = s1_comp ? s1_p.rvc_rs1_rest : {s1_instr[19:18], s1_instr[15]};

  logic s1_btb_taken;
  logic [XLEN-1:0] s1_btb_target;
  assign s1_btb_taken  = s1_valid && s1_p.btb_taken && !s1_fault;
  assign s1_btb_target = {s1_m.btb_target_hi, 1'b0};

  logic s1_tage_cov;
  riscv_pkg::tage_lookup_t s1_tage_lookup;
  riscv_pkg::itt_lookup_t s1_itt_lookup;
  logic s1_itt_hit;
  logic [BackingTargetBits-1:0] s1_itt_target;
  assign s1_tage_cov    = s1_p.hw_in_win[1] ? s1_m.tage_cov[1] : s1_m.tage_cov[0];
  assign s1_tage_lookup = s1_p.hw_in_win[1] ? s1_m.tage_w1 : s1_m.tage_w0;
  assign s1_itt_lookup  = s1_p.hw_in_win[1] ? s1_m.itt_w1 : s1_m.itt_w0;
  assign s1_itt_hit     = s1_tage_cov && !s1_fault &&
      (s1_p.hw_in_win[1] ? s1_m.itt_hit[1] : s1_m.itt_hit[0]);
  assign s1_itt_target  = s1_p.hw_in_win[1] ? s1_m.itt_target[1] : s1_m.itt_target[0];

  logic [riscv_pkg::PdTargetSplit:0] s1_native_sum;
  logic [riscv_pkg::PdTargetSplit:0] s1_comp_sum;
  assign s1_native_sum = (riscv_pkg::PdTargetSplit + 1)'(s1_pc[riscv_pkg::PdTargetSplit-1:0]) +
      (riscv_pkg::PdTargetSplit + 1)'(native_branch_imm_low(s1_instr));
  assign s1_comp_sum = (riscv_pkg::PdTargetSplit + 1)'(s1_pc[riscv_pkg::PdTargetSplit-1:0]) +
      (riscv_pkg::PdTargetSplit + 1)'(compressed_branch_imm_low(s1_p.parcel));

  // ---- Slot 2 (precompute +2 and +4 candidates in parallel, select by s1_comp) ----
  logic [XLEN-1:0] s2_pc_p2;
  logic [XLEN-1:0] s2_pc_p4;
  logic [XLEN-1:0] s2_pc;
  assign s2_pc_p2 = s1_pc + riscv_pkg::PcIncrementCompressed;
  assign s2_pc_p4 = s1_pc + riscv_pkg::PcIncrement32bit;
  assign s2_pc    = s1_comp ? s2_pc_p2 : s2_pc_p4;

  parcel_t s2_p;
  logic [15:0] s2_hi_parcel;
  logic s2_hi_fault;
  logic s2_uses_meta1;
  meta_t s2_m;

  assign s2_p          = s1_comp ? view1 : view2;
  assign s2_hi_parcel  = s1_comp ? view2.parcel : view3.parcel;
  assign s2_hi_fault   = s1_comp ? view2.fault : view3.fault;
  // Use ring-only last flags and occupancy: when count_q == 0 both meta0 and
  // meta1 equal i_push_meta; when count_q == 1 view0 ends window 0 so slot 2
  // always belongs to meta1; when count_q >= 2 both view0 and view1 come from
  // the ring. This keeps F1's push count off PD's slot-2 metadata mux.
  assign s2_uses_meta1 = q_count_ge2 ?
      (s1_comp ? q_ring_last[0] : (q_ring_last[0] || q_ring_last[1])) : q_count_eq1;
  assign s2_m          = s2_uses_meta1 ? meta1 : meta0;

  logic s2_comp;
  logic s2_fault;
  logic s2_have_bytes;
  logic s2_valid_raw;
  logic s2_valid;

  assign s2_comp  = (s2_p.parcel[1:0] != 2'b11);
  assign s2_fault = s2_p.fault || (!s2_comp && s2_hi_fault);

  always_comb begin
    unique case ({s1_comp, s2_comp})
      2'b11:   s2_have_bytes = q_avail_ge_drain[1];
      2'b10:   s2_have_bytes = q_avail_ge_drain[2];
      2'b01:   s2_have_bytes = q_avail_ge_drain[2];
      default: s2_have_bytes = q_avail_ge_drain[3];
    endcase
  end

  // s2_have_bytes already implies s1_have_bytes, and s1_p.allows_slot2_after
  // already excludes control-flow instructions (hence any BTB-taken slot 1).
  // Keep pqueue_flush off the raw slot-2 qualifier so queue pop counts stay
  // decoupled from redirects.
  assign s2_valid_raw = !i_fetch_trap_hold && !s1_fault &&
      s1_p.allows_slot2_after && s2_have_bytes && !s2_fault && s2_p.slot2_start_valid;
  assign s2_valid = !pqueue_flush && s2_valid_raw;

  // Build +2 (view1) and +4 (view2) expanded instructions and target sums in parallel.
  logic [31:0] s2_rvc_exp_p2;
  logic [31:0] s2_rvc_exp_p4;
  logic [31:0] s2_nat_p2;
  logic [31:0] s2_nat_p4;
  logic [31:0] s2_instr_p2;
  logic [31:0] s2_instr_p4;
  logic [31:0] s2_instr;

  assign s2_rvc_exp_p2 = {
    view1.rvc_extra[21:15],
    view1.rvc_bits24_20,
    view1.rvc_rs1_rest[2:1],
    view1.rvc_source_hot,
    view1.rvc_rs1_rest[0],
    view1.rvc_extra[14:0]
  };
  assign s2_rvc_exp_p4 = {
    view2.rvc_extra[21:15],
    view2.rvc_bits24_20,
    view2.rvc_rs1_rest[2:1],
    view2.rvc_source_hot,
    view2.rvc_rs1_rest[0],
    view2.rvc_extra[14:0]
  };
  assign s2_nat_p2   = {view2.parcel, view1.parcel};
  assign s2_nat_p4   = {view3.parcel, view2.parcel};
  assign s2_instr_p2 = (view1.parcel[1:0] != 2'b11) ? s2_rvc_exp_p2 : s2_nat_p2;
  assign s2_instr_p4 = (view2.parcel[1:0] != 2'b11) ? s2_rvc_exp_p4 : s2_nat_p4;
  assign s2_instr    = s1_comp ? s2_instr_p2 : s2_instr_p4;

  logic [2:0] s2_source_hot;
  logic [4:0] s2_bits24_20;
  logic [2:0] s2_rs1_rest;
  logic s2_decomp_illegal;
  logic s2_is_cond_branch;

  assign s2_source_hot = s2_comp ?
      {s2_p.rvc_bits24_20[1], s2_p.rvc_source_hot} : {s2_instr[21], s2_instr[17:16]};
  assign s2_bits24_20      = s2_comp ? s2_p.rvc_bits24_20 : s2_instr[24:20];
  assign s2_rs1_rest       = s2_comp ? s2_p.rvc_rs1_rest : {s2_instr[19:18], s2_instr[15]};
  assign s2_decomp_illegal = s2_comp && s2_p.rvc_extra[22];
  assign s2_is_cond_branch = (s2_instr[6:0] == riscv_pkg::OPC_BRANCH) && (s2_instr[14:13] != 2'b01);

  logic [riscv_pkg::PdTargetSplit:0] s2_nat_sum_p2, s2_nat_sum_p4;
  logic [riscv_pkg::PdTargetSplit:0] s2_cmp_sum_p2, s2_cmp_sum_p4;
  assign s2_nat_sum_p2 = (riscv_pkg::PdTargetSplit + 1)'(s2_pc_p2[riscv_pkg::PdTargetSplit-1:0]) +
      (riscv_pkg::PdTargetSplit + 1)'(native_branch_imm_low(s2_instr_p2));
  assign s2_nat_sum_p4 = (riscv_pkg::PdTargetSplit + 1)'(s2_pc_p4[riscv_pkg::PdTargetSplit-1:0]) +
      (riscv_pkg::PdTargetSplit + 1)'(native_branch_imm_low(s2_instr_p4));
  assign s2_cmp_sum_p2 = (riscv_pkg::PdTargetSplit + 1)'(s2_pc_p2[riscv_pkg::PdTargetSplit-1:0]) +
      (riscv_pkg::PdTargetSplit + 1)'(compressed_branch_imm_low(view1.parcel));
  assign s2_cmp_sum_p4 = (riscv_pkg::PdTargetSplit + 1)'(s2_pc_p4[riscv_pkg::PdTargetSplit-1:0]) +
      (riscv_pkg::PdTargetSplit + 1)'(compressed_branch_imm_low(view2.parcel));

  logic s2_tage_cov;
  riscv_pkg::tage_lookup_t s2_tage_lookup;
  riscv_pkg::itt_lookup_t s2_itt_lookup;
  logic s2_itt_hit;
  logic [BackingTargetBits-1:0] s2_itt_target;

  assign s2_tage_cov    = s2_p.hw_in_win[1] ? s2_m.tage_cov[1] : s2_m.tage_cov[0];
  assign s2_tage_lookup = s2_p.hw_in_win[1] ? s2_m.tage_w1 : s2_m.tage_w0;
  assign s2_itt_lookup  = s2_p.hw_in_win[1] ? s2_m.itt_w1 : s2_m.itt_w0;
  assign s2_itt_hit     = s2_tage_cov && !s2_fault &&
      (s2_p.hw_in_win[1] ? s2_m.itt_hit[1] : s2_m.itt_hit[0]);
  assign s2_itt_target  = s2_p.hw_in_win[1] ? s2_m.itt_target[1] : s2_m.itt_target[0];

  logic s2_btb_taken;
  logic [XLEN-1:0] s2_btb_target;
  assign s2_btb_taken  = s2_valid && s2_p.btb_taken;
  assign s2_btb_target = {s2_m.btb_target_hi, 1'b0};

  // Parcel queue pop count: keep pqueue_flush off q_pop_count (u_parcel_queue
  // synchronously resets all pointers and counts when pqueue_flush fires).
  logic [2:0] s1_pop_hw;
  logic [2:0] s2_pop_hw;
  assign s1_pop_hw   = s1_need_2 ? 3'd2 : 3'd1;
  assign s2_pop_hw   = s2_valid_raw ? (s2_comp ? 3'd1 : 3'd2) : 3'd0;
  assign q_pop_count = (!i_pipeline_ctrl.stall && s1_valid_raw) ? (s1_pop_hw + s2_pop_hw) : 3'd0;

  // ===========================================================================
  // Outputs to PD Stage & Predictor Metadata
  // ===========================================================================
  always_comb begin
    o_from_if_to_pd.program_counter                  = s1_pc;
    o_from_if_to_pd.raw_parcel                       = s1_p.parcel;
    o_from_if_to_pd.sel_nop                          = !s1_valid;
    o_from_if_to_pd.sel_compressed                   = s1_comp;
    o_from_if_to_pd.effective_instr                  = s1_instr;
    o_from_if_to_pd.source_hot_predecoded            = s1_source_hot;
    o_from_if_to_pd.bits24_20_predecoded             = s1_bits24_20;
    o_from_if_to_pd.rs1_rest_predecoded              = s1_rs1_rest;
    o_from_if_to_pd.rvc_extra_predecoded             = s1_p.rvc_extra;
    o_from_if_to_pd.btb_predicted_taken              = s1_btb_taken;
    o_from_if_to_pd.btb_predicted_target             = s1_btb_target;
    o_from_if_to_pd.ras_checkpoint_tos               = s1_m.ras_ckpt_tos;
    o_from_if_to_pd.ras_checkpoint_valid_count       = s1_m.ras_ckpt_cnt;
    o_from_if_to_pd.ras_checkpoint_top               = s1_m.ras_ckpt_top;
    o_from_if_to_pd.bp_dir_taken                     = s1_p.bp_dir_taken;
    o_from_if_to_pd.bp_dir_idx                       = s1_pc[riscv_pkg::BpDirIdxBits:1];
    o_from_if_to_pd.tage_valid                       =
        s1_tage_cov && (|s1_tage_lookup.hit) && !s1_fault;
    o_from_if_to_pd.tage_taken                       = s1_tage_lookup.taken;
    o_from_if_to_pd.fetch_fault                      = s1_fault;
    o_from_if_to_pd.fetch_fault_page                 = s1_fault_page;
    o_from_if_to_pd.fetch_fault_hi                   = s1_fault_hi;
    o_from_if_to_pd.decomp_illegal                   = 1'b0;
    o_from_if_to_pd.is_cond_branch                   = 1'b0;
    o_from_if_to_pd.pd_target_native_low             = s1_native_sum[riscv_pkg::PdTargetSplit-1:0];
    o_from_if_to_pd.pd_target_native_high_select     =
        {s1_instr[31], s1_native_sum[riscv_pkg::PdTargetSplit]};
    o_from_if_to_pd.pd_target_compressed_low         = s1_comp_sum[riscv_pkg::PdTargetSplit-1:0];
    o_from_if_to_pd.pd_target_compressed_high_select =
        {s1_p.parcel[12], s1_comp_sum[riscv_pkg::PdTargetSplit]};
  end

  always_comb begin
    o_from_if_to_pd_2.program_counter                  = s2_pc;
    o_from_if_to_pd_2.raw_parcel                       = s2_p.parcel;
    o_from_if_to_pd_2.sel_nop                          = !s2_valid;
    o_from_if_to_pd_2.sel_compressed                   = s2_comp;
    o_from_if_to_pd_2.effective_instr                  = s2_instr;
    o_from_if_to_pd_2.source_hot_predecoded            = s2_source_hot;
    o_from_if_to_pd_2.bits24_20_predecoded             = s2_bits24_20;
    o_from_if_to_pd_2.rs1_rest_predecoded              = s2_rs1_rest;
    o_from_if_to_pd_2.rvc_extra_predecoded             = '0;
    o_from_if_to_pd_2.btb_predicted_taken              = s2_btb_taken;
    o_from_if_to_pd_2.btb_predicted_target             = s2_btb_target;
    o_from_if_to_pd_2.ras_checkpoint_tos               = s1_m.ras_ckpt_tos;
    o_from_if_to_pd_2.ras_checkpoint_valid_count       = s1_m.ras_ckpt_cnt;
    o_from_if_to_pd_2.ras_checkpoint_top               = s1_m.ras_ckpt_top;
    o_from_if_to_pd_2.bp_dir_taken                     = 1'b0;
    o_from_if_to_pd_2.bp_dir_idx                       = s2_pc[riscv_pkg::BpDirIdxBits:1];
    o_from_if_to_pd_2.tage_valid                       =
        s2_tage_cov && (|s2_tage_lookup.hit) && !s2_fault;
    o_from_if_to_pd_2.tage_taken                       = s2_tage_lookup.taken;
    o_from_if_to_pd_2.fetch_fault                      = 1'b0;
    o_from_if_to_pd_2.fetch_fault_page                 = 1'b0;
    o_from_if_to_pd_2.fetch_fault_hi                   = 1'b0;
    o_from_if_to_pd_2.decomp_illegal                   = s2_decomp_illegal;
    o_from_if_to_pd_2.is_cond_branch                   = s2_is_cond_branch;
    o_from_if_to_pd_2.pd_target_native_low             = s1_comp ?
        s2_nat_sum_p2[riscv_pkg::PdTargetSplit-1:0] : s2_nat_sum_p4[riscv_pkg::PdTargetSplit-1:0];
    o_from_if_to_pd_2.pd_target_native_high_select     = s1_comp ?
        {s2_instr_p2[31], s2_nat_sum_p2[riscv_pkg::PdTargetSplit]} :
        {s2_instr_p4[31], s2_nat_sum_p4[riscv_pkg::PdTargetSplit]};
    o_from_if_to_pd_2.pd_target_compressed_low         = s1_comp ?
        s2_cmp_sum_p2[riscv_pkg::PdTargetSplit-1:0] : s2_cmp_sum_p4[riscv_pkg::PdTargetSplit-1:0];
    o_from_if_to_pd_2.pd_target_compressed_high_select = s1_comp ?
        {view1.parcel[12], s2_cmp_sum_p2[riscv_pkg::PdTargetSplit]} :
        {view2.parcel[12], s2_cmp_sum_p4[riscv_pkg::PdTargetSplit]};
  end

  // Capture PD's accepted bundle RAS checkpoint for restoring on a PD redirect.
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      pd_ras_ckpt_tos_q <= '0;
      pd_ras_ckpt_cnt_q <= '0;
      pd_ras_ckpt_top_q <= '0;
    end else if (!i_pipeline_ctrl.stall) begin
      pd_ras_ckpt_tos_q <= s1_m.ras_ckpt_tos;
      pd_ras_ckpt_cnt_q <= s1_m.ras_ckpt_cnt;
      pd_ras_ckpt_top_q <= s1_m.ras_ckpt_top;
    end
  end

  // Backing BTB outputs (keep slot-2 by-size contract for PD target muxing;
  // gate slot-2 hit on staying within slot 1's physical-address region by
  // checking whether s1_pc + (2 or 4) carries out of bit PhysAddrBits-1,
  // avoiding a 64-bit carry chain and upper-bit compare behind s2_pc).
  logic s2_same_region;
  assign s2_same_region = !((&s1_pc[riscv_pkg::PhysAddrBits-1:2]) && (s1_pc[1] || !s1_comp));

  assign o_backing_hit[0]                  = s1_valid && !s1_fault && s1_p.backing_hit;
  assign o_backing_compressed[0]           = s1_p.backing_compressed;
  assign o_backing_return[0]               = s1_p.backing_return;
  assign o_backing_target[0]               = s1_p.backing_target;
  assign o_backing_slot2_return_by_size[0] = view2.backing_return;
  assign o_backing_slot2_return_by_size[1] = view1.backing_return;
  assign o_backing_slot2_target_by_size[0] = view2.backing_target;
  assign o_backing_slot2_target_by_size[1] = view1.backing_target;
  assign o_backing_hit[1]                  = s2_valid && s2_same_region && s2_p.backing_hit;
  assign o_backing_compressed[1]           = s2_p.backing_compressed;
  assign o_backing_return[1]               = s1_comp ? view1.backing_return : view2.backing_return;
  assign o_backing_target[1]               = s1_comp ? view1.backing_target : view2.backing_target;

  // TAGE and ITTAGE outputs
  assign o_tage_slot_valid[0] = s1_tage_cov;
  assign o_tage_slot_valid[1] = s2_tage_cov;
  assign o_tage_slot_lookup   = s1_tage_lookup;
  assign o_tage_slot_lookup_2 = s2_tage_lookup;
  // When slot 2 is valid, slot 1 is non-control-flow, so any branch/jump in
  // the bundle belongs to slot 2's window. Use s2_valid_raw so pqueue_flush
  // does not drive the 64-bit lookup history bus (bubbles are ignored by PD).
  assign o_tage_lookup_hist   = s2_valid_raw ? s2_m.itt_hist : s1_m.itt_hist;
  assign o_itt_slot_lookup    = s1_itt_lookup;
  assign o_itt_slot_lookup_2  = s2_itt_lookup;
  assign o_itt_hit[0]         = s1_itt_hit;
  assign o_itt_hit[1]         = s2_itt_hit;
  assign o_itt_target[0]      = s1_itt_target;
  assign o_itt_target[1]      = s2_itt_target;

  // Frontend validity tracker control taps
  assign o_slot1_has_control_flow = s1_valid && s1_p.is_control;
  assign o_slot1_is_indirect      = s1_p.is_indirect;

  // ===========================================================================
  // Width-Funnel Profiling Events (registered)
  // ===========================================================================
  logic width_deliver1;
  logic width_deliver2;
  logic width_slot2_killed;
  logic kill_s1_native_ctrl;
  logic kill_s1_native_serialize;
  logic kill_s1_comp_ctrl;
  logic kill_class;
  logic kill_window_limit;
  logic kill_transient;

  assign width_deliver1     = !i_pipeline_ctrl.stall && s1_valid;
  assign width_deliver2     = width_deliver1 && s2_valid;
  assign width_slot2_killed = width_deliver1 && !s2_valid;

  assign kill_s1_native_ctrl      = !s1_fault && !s1_comp && s1_p.is_control;
  assign kill_s1_native_serialize = !s1_fault && !s1_comp && !s1_p.is_control &&
      !s1_p.allows_slot2_after;
  assign kill_s1_comp_ctrl        = !s1_fault && s1_comp && s1_p.is_control;
  assign kill_class               = !s1_fault && s1_p.allows_slot2_after &&
      s2_have_bytes && !s2_fault && !s2_p.slot2_start_valid;
  assign kill_window_limit        = !s1_fault && s1_p.allows_slot2_after && !s2_have_bytes;
  assign kill_transient           =
      s1_fault || (s1_p.allows_slot2_after && s2_have_bytes && s2_fault);

  riscv_pkg::if_width_events_t width_events_q;
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      width_events_q <= '0;
    end else begin
      width_events_q.deliver1                 <= width_deliver1;
      width_events_q.deliver2                 <= width_deliver2;
      width_events_q.kill_s1_native_ctrl      <= width_slot2_killed && kill_s1_native_ctrl;
      width_events_q.kill_s1_native_serialize <= width_slot2_killed && kill_s1_native_serialize;
      width_events_q.kill_slot1_ctrl          <= width_slot2_killed && kill_s1_comp_ctrl;
      width_events_q.kill_class               <= width_slot2_killed && kill_class;
      width_events_q.kill_window_limit        <= width_slot2_killed && kill_window_limit;
      width_events_q.kill_transient           <= width_slot2_killed && kill_transient;
      width_events_q.slot2_pred_taken         <= width_deliver2 && s2_btb_taken;
    end
  end
  assign o_width_events = width_events_q;

  // Unused provider-replica inputs kept for interface stability.
  wire _unused_if = &{
    1'b0,
    i_instr_low_by_parity,
    i_instr_high,
    i_instr_window_high,
    i_instr_pc_metadata,
    i_instr_pc_metadata_by_provider_parity,
    i_pc_pairability_by_provider_parity,
    i_slot2_start_valid_lo_by_provider_parity,
    i_instr_bank_sel_r,
    i_served_last_word_low,
    i_served_prev_word_low,
    i_served_prev_word_valid_low,
    i_served_last_word_high,
    i_served_prev_word_high,
    i_served_prev_word_valid_high,
    i_served_high,
    i_pd_redirect_taken,
    next_pc,
    pc_update_en,
    ras_nonempty,
    q_avail,
    q_avail_ge,
    q_view_last
  };

`ifdef FROST_DEBUG_FETCH_ILA
  // Fetch debug probes (optional debug probe tap): mark_debug copies for the debug
  // core; nothing here feeds the design.
  (* mark_debug = "true" *) logic [15:0] dbg_ila_if_pc;
  (* mark_debug = "true" *) logic dbg_ila_if_instr_valid;
  (* mark_debug = "true" *) logic dbg_ila_if_f0_launch;
  (* mark_debug = "true" *) logic dbg_ila_if_f1_accept;
  (* mark_debug = "true" *) logic dbg_ila_if_stop_fetch;
  (* mark_debug = "true" *) logic dbg_ila_if_flush;
  (* mark_debug = "true" *) logic dbg_ila_if_stall;
  (* mark_debug = "true" *) logic dbg_ila_if_pd_redirect;
  (* mark_debug = "true" *) logic dbg_ila_if_instr_fault0;
  (* mark_debug = "true" *) logic dbg_ila_if_instr_fault1;
  (* mark_debug = "true" *) logic [15:0] dbg_ila_if_pd_pc;
  (* mark_debug = "true" *) logic [31:0] dbg_ila_if_pd_instr;
  (* mark_debug = "true" *) logic dbg_ila_if_pd_sel_nop;
  (* mark_debug = "true" *) logic dbg_ila_if_pd_fetch_fault;
  (* mark_debug = "true" *) logic dbg_ila_if_pd_fetch_fault_hi;
  (* mark_debug = "true" *) logic [15:0] dbg_ila_if_pd2_pc;
  (* mark_debug = "true" *) logic dbg_ila_if_pd2_sel_nop;
  (* mark_debug = "true" *) logic dbg_ila_if_pd2_fetch_fault;

  assign dbg_ila_if_pc             = o_pc[15:0];
  assign dbg_ila_if_instr_valid    = i_instr_valid;
  assign dbg_ila_if_f0_launch      = f0_launch;
  assign dbg_ila_if_f1_accept      = f1_accept;
  assign dbg_ila_if_stop_fetch     = q_stop_fetch;
  assign dbg_ila_if_flush          = i_pipeline_ctrl.flush;
  assign dbg_ila_if_stall          = i_pipeline_ctrl.stall;
  assign dbg_ila_if_pd_redirect    = i_pd_redirect;
  assign dbg_ila_if_instr_fault0   = i_instr_fault0;
  assign dbg_ila_if_instr_fault1   = i_instr_fault1;
  assign dbg_ila_if_pd_pc          = o_from_if_to_pd.program_counter[15:0];
  assign dbg_ila_if_pd_instr       = o_from_if_to_pd.effective_instr;
  assign dbg_ila_if_pd_sel_nop     = o_from_if_to_pd.sel_nop;
  assign dbg_ila_if_pd_fetch_fault = o_from_if_to_pd.fetch_fault;
  assign dbg_ila_if_pd_fetch_fault_hi = o_from_if_to_pd.fetch_fault_hi;
  assign dbg_ila_if_pd2_pc         = o_from_if_to_pd_2.program_counter[15:0];
  assign dbg_ila_if_pd2_sel_nop    = o_from_if_to_pd_2.sel_nop;
  assign dbg_ila_if_pd2_fetch_fault = o_from_if_to_pd_2.fetch_fault;
`endif

`ifndef SYNTHESIS
  logic sim_reset_seen_q = 1'b0;
  parcel_t check_parcel;
  meta_t check_meta;

  initial begin
    if ($bits(check_parcel) != ParcelBits)
      $fatal(
          1, "if_stage: ParcelBits (%0d) != $bits(parcel_t) (%0d)", ParcelBits, $bits(check_parcel)
      );
    if ($bits(check_meta) != MetaBits)
      $fatal(1, "if_stage: MetaBits (%0d) != $bits(meta_t) (%0d)", MetaBits, $bits(check_meta));
  end

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) sim_reset_seen_q <= 1'b1;
    if (sim_reset_seen_q && !i_pipeline_ctrl.reset) begin
      if (!$isunknown({o_from_if_to_pd.sel_nop, o_from_if_to_pd_2.sel_nop})) begin
        p_if_slot1_nop_implies_slot2_nop :
        assert (!o_from_if_to_pd.sel_nop || o_from_if_to_pd_2.sel_nop);
      end
      if (!$isunknown({o_from_if_to_pd.fetch_fault, o_from_if_to_pd.btb_predicted_taken})) begin
        p_if_fault_clears_slot1_taken :
        assert (!o_from_if_to_pd.fetch_fault || !o_from_if_to_pd.btb_predicted_taken);
      end
      if (!$isunknown({o_from_if_to_pd_2.fetch_fault, o_from_if_to_pd_2.btb_predicted_taken})) begin
        p_if_fault_clears_slot2_taken :
        assert (!o_from_if_to_pd_2.fetch_fault || !o_from_if_to_pd_2.btb_predicted_taken);
      end
      if (!o_from_if_to_pd.sel_nop && !$isunknown(
              {o_from_if_to_pd.program_counter, o_from_if_to_pd.sel_compressed,
               o_from_if_to_pd_2.program_counter}
          )) begin
        p_if_slot2_pc_step_exact :
        assert (o_from_if_to_pd_2.program_counter ==
                (o_from_if_to_pd.program_counter +
                 (o_from_if_to_pd.sel_compressed ? riscv_pkg::PcIncrementCompressed :
                                                   riscv_pkg::PcIncrement32bit)));
      end
      if (!$isunknown(
              {o_from_if_to_pd.sel_compressed, o_backing_return[1], o_backing_target[1],
               o_backing_slot2_return_by_size, o_backing_slot2_target_by_size}
          )) begin
        p_if_backing_slot2_by_size_exact :
        assert ({o_backing_return[1], o_backing_target[1]} ==
                {o_backing_slot2_return_by_size[o_from_if_to_pd.sel_compressed],
                 o_backing_slot2_target_by_size[o_from_if_to_pd.sel_compressed]});
      end
      if (!o_from_if_to_pd_2.sel_nop && !o_from_if_to_pd.fetch_fault && !$isunknown(
              {o_from_if_to_pd.sel_compressed, o_from_if_to_pd.raw_parcel,
               o_from_if_to_pd.effective_instr[6:0]}
          )) begin
        p_if_slot1_size_matches_raw_parcel :
        assert (o_from_if_to_pd.sel_compressed == (o_from_if_to_pd.raw_parcel[1:0] != 2'b11));
        p_if_slot2_follows_non_control_slot1 :
        assert ((o_from_if_to_pd.raw_parcel[1:0] != 2'b11) ? !riscv_pkg::imem_compressed_control(
            o_from_if_to_pd.raw_parcel
        ) : !riscv_pkg::imem_native_control(
            o_from_if_to_pd.effective_instr[6:0]
        ));
      end
      if (!o_from_if_to_pd_2.sel_nop && !$isunknown(
              {o_from_if_to_pd_2.sel_compressed, o_from_if_to_pd_2.raw_parcel[1:0]}
          )) begin
        p_if_slot2_size_matches_raw_parcel :
        assert (o_from_if_to_pd_2.sel_compressed == (o_from_if_to_pd_2.raw_parcel[1:0] != 2'b11));
      end
      if (!$isunknown(
              {o_backing_hit[1], o_from_if_to_pd.program_counter[XLEN-1:riscv_pkg::PhysAddrBits],
               o_from_if_to_pd_2.program_counter[XLEN-1:riscv_pkg::PhysAddrBits]}
          )) begin
        p_if_slot2_backing_hit_same_region :
        assert (!o_backing_hit[1] ||
                (o_from_if_to_pd_2.program_counter[XLEN-1:riscv_pkg::PhysAddrBits] ==
                 o_from_if_to_pd.program_counter[XLEN-1:riscv_pkg::PhysAddrBits]));
      end
      if (ras_nonempty && !$isunknown({ras_top, ras_top_is_cached})) begin
        p_if_ras_cached_shadow_exact :
        assert (ras_top_is_cached == riscv_pkg::pma_cached_ok(ras_top));
      end
      if (eff_ras_nonempty && !ras_restore_pure_pop_q &&
          !$isunknown({eff_ras_top, eff_ras_top_cached})) begin
        p_if_eff_ras_cached_exact :
        assert (eff_ras_top_cached == riscv_pkg::pma_cached_ok(eff_ras_top));
      end
      if (!$isunknown({eff_ras_nonempty, ras_restore_q, ras_sh_cnt_next, ras_nonempty})) begin
        p_if_eff_ras_nonempty_exact :
        assert (eff_ras_nonempty == (ras_restore_q ? (ras_sh_cnt_next != '0) : ras_nonempty));
      end
      if (!pqueue_flush && !$isunknown({s1_have_bytes, s1_need_2, q_avail_ge})) begin
        p_if_drain_avail_s1_exact :
        assert (s1_have_bytes == (s1_need_2 ? q_avail_ge[1] : q_avail_ge[0]));
      end
      if (!pqueue_flush && !i_fetch_trap_hold && !s1_fault && s1_p.allows_slot2_after &&
          !s2_fault && s2_p.slot2_start_valid &&
          !$isunknown({s2_have_bytes, s1_comp, s2_comp, q_avail_ge})) begin
        p_if_drain_avail_s2_exact :
        assert (s2_have_bytes ==
                (s1_comp ? (s2_comp ? q_avail_ge[1] : q_avail_ge[2]) :
                           (s2_comp ? q_avail_ge[2] : q_avail_ge[3])));
      end
    end
  end
`endif

`ifdef IF_SLOT2_PRECOMPUTE_FORMAL
  // Formal model (formal/if_slot2_precompute.sby): proves that IF's precomputed
  // slot-2 TAGE/ITTAGE lookup selection, conditional-branch flag, target
  // candidates, PC step, bubble/fault pairing, and per-size backing outputs
  // match direct references across empty-bypass and queued packets.
  logic f_slot2_past_valid = 1'b0;

  always_ff @(posedge i_clk) begin
    f_slot2_past_valid <= 1'b1;
    if (!f_slot2_past_valid) assume (i_pipeline_ctrl.reset);
  end

  always_comb begin
    if (f_slot2_past_valid && !i_pipeline_ctrl.reset) begin
      f_if_slot1_itt_hit_exact :
      assert (o_itt_hit[0] == (o_tage_slot_valid[0] && !o_from_if_to_pd.fetch_fault &&
                               (s1_p.hw_in_win[1] ? s1_m.itt_hit[1] : s1_m.itt_hit[0])));
      f_if_slot2_itt_hit_exact :
      assert (o_itt_hit[1] == (o_tage_slot_valid[1] && !s2_fault &&
                               (s2_p.hw_in_win[1] ? s2_m.itt_hit[1] : s2_m.itt_hit[0])));
      f_if_slot1_itt_payload_exact :
      assert ({o_itt_target[0], o_itt_slot_lookup} == (s1_p.hw_in_win[1] ?
          {s1_m.itt_target[1], s1_m.itt_w1} : {s1_m.itt_target[0], s1_m.itt_w0}));
      f_if_slot2_itt_payload_exact :
      assert ({o_itt_target[1], o_itt_slot_lookup_2} == (s2_p.hw_in_win[1] ?
          {s2_m.itt_target[1], s2_m.itt_w1} : {s2_m.itt_target[0], s2_m.itt_w0}));
      f_if_slot2_tage_cov_exact :
      assert (o_tage_slot_valid[1] == (s2_p.hw_in_win[1] ? s2_m.tage_cov[1] : s2_m.tage_cov[0]));
      f_if_slot2_tage_lookup_exact :
      assert (o_tage_slot_lookup_2 == (s2_p.hw_in_win[1] ? s2_m.tage_w1 : s2_m.tage_w0));
      f_if_slot2_tage_valid_exact :
      assert (o_from_if_to_pd_2.tage_valid ==
              (o_tage_slot_valid[1] && (|o_tage_slot_lookup_2.hit) && !s2_fault));
      f_if_slot2_tage_taken_exact :
      assert (o_from_if_to_pd_2.tage_taken == o_tage_slot_lookup_2.taken);
      f_if_slot2_is_cond_branch_exact :
      assert (o_from_if_to_pd_2.is_cond_branch ==
              ((o_from_if_to_pd_2.effective_instr[6:0] == riscv_pkg::OPC_BRANCH) &&
               (o_from_if_to_pd_2.effective_instr[14:13] != 2'b01)));
      if (!o_from_if_to_pd_2.sel_compressed) begin
        f_if_slot2_pd_target_native_exact :
        assert ({o_from_if_to_pd_2.pd_target_native_high_select[1],
                 o_from_if_to_pd_2.pd_target_native_high_select[0],
                 o_from_if_to_pd_2.pd_target_native_low} ==
                {o_from_if_to_pd_2.effective_instr[31],
                 (riscv_pkg::PdTargetSplit + 1)'(
                     o_from_if_to_pd_2.program_counter[riscv_pkg::PdTargetSplit-1:0] +
                     native_branch_imm_low(o_from_if_to_pd_2.effective_instr))});
      end
      f_if_slot2_pd_target_compressed_exact :
      assert ({o_from_if_to_pd_2.pd_target_compressed_high_select[1],
               o_from_if_to_pd_2.pd_target_compressed_high_select[0],
               o_from_if_to_pd_2.pd_target_compressed_low} ==
              {o_from_if_to_pd_2.raw_parcel[12],
               (riscv_pkg::PdTargetSplit + 1)'(
                   o_from_if_to_pd_2.program_counter[riscv_pkg::PdTargetSplit-1:0] +
                   compressed_branch_imm_low(o_from_if_to_pd_2.raw_parcel))});
      f_if_slot2_pc_step_exact :
      assert (o_from_if_to_pd_2.program_counter ==
              (o_from_if_to_pd.program_counter +
               (o_from_if_to_pd.sel_compressed ? riscv_pkg::PcIncrementCompressed :
                                                 riscv_pkg::PcIncrement32bit)));
      f_if_slot1_nop_implies_slot2_nop :
      assert (!o_from_if_to_pd.sel_nop || o_from_if_to_pd_2.sel_nop);
      f_if_slot1_fault_implies_slot2_fault_or_nop :
      assert (o_from_if_to_pd_2.sel_nop || !o_from_if_to_pd.fetch_fault ||
              o_from_if_to_pd_2.fetch_fault);
    end
  end

  // Unconditional check of slot-2 per-size backing selection (no reset qualifier).
  always_comb begin
    f_if_backing_slot2_by_size_exact :
    assert ({o_backing_return[1], o_backing_target[1]} ==
            {o_backing_slot2_return_by_size[o_from_if_to_pd.sel_compressed],
             o_backing_slot2_target_by_size[o_from_if_to_pd.sel_compressed]});
  end

  always_ff @(posedge i_clk) begin
    if (f_slot2_past_valid && !i_pipeline_ctrl.reset) begin
      cover (!o_from_if_to_pd_2.sel_nop && o_itt_hit[1]);
      cover (!o_from_if_to_pd_2.sel_nop && o_from_if_to_pd.sel_compressed &&
             o_from_if_to_pd_2.sel_compressed && o_from_if_to_pd_2.is_cond_branch &&
             o_from_if_to_pd_2.tage_valid && o_from_if_to_pd_2.tage_taken);
      cover (!o_from_if_to_pd_2.sel_nop && o_from_if_to_pd.sel_compressed &&
             !o_from_if_to_pd_2.sel_compressed && o_from_if_to_pd_2.is_cond_branch &&
             o_from_if_to_pd_2.tage_valid && !o_from_if_to_pd_2.tage_taken);
      cover (!o_from_if_to_pd_2.sel_nop && !o_from_if_to_pd.sel_compressed &&
             !o_from_if_to_pd_2.sel_compressed && o_from_if_to_pd_2.is_cond_branch &&
             o_from_if_to_pd_2.tage_valid);
      cover (!o_from_if_to_pd_2.sel_nop && s2_uses_meta1);
      cover (!o_from_if_to_pd_2.sel_nop && i_pipeline_ctrl.stall);
    end
  end
`endif

`ifdef IF_FAULT_RAS_VETO_PROOF
  // Formal model (formal/if_fault_ras_veto.sby): fetch-faulted IF packets never
  // carry a predicted-taken flag, faulted F0 fetches never trigger live or
  // spanning RAS ops, and spanning second-word faults restore RAS and cancel
  // pending speculative F0 RAS ops.
  logic f_fault_past_valid = 1'b0;
  logic f_prev_fault0_q;
  logic f_prev_span_tail_fault_q;
  initial assume (i_pipeline_ctrl.reset);

  always_comb begin
    p_fault_packet_clears_slot1_taken :
    assert (!o_from_if_to_pd.fetch_fault || !o_from_if_to_pd.btb_predicted_taken);
    p_fault_packet_clears_slot2_taken :
    assert (!o_from_if_to_pd_2.fetch_fault || !o_from_if_to_pd_2.btb_predicted_taken);
    p_fault_f0_vetoes_span_btb : assert (!fetch_fault0_live || !f0_span_btb_fire);
    p_fault_f0_clears_ras_op :
    assert (!fetch_fault0_live || (!f0_ras_push && !f0_ras_pop));
  end

  always_ff @(posedge i_clk) begin
    f_fault_past_valid <= 1'b1;
    f_prev_fault0_q <= !i_pipeline_ctrl.reset && fetch_fault0_live;
    f_prev_span_tail_fault_q <= !i_pipeline_ctrl.reset && !any_redirect &&
        !i_from_ex_comb.ras_misprediction && f1_span_tail_fault;
    if (f_fault_past_valid) begin
      p_prev_fault0_clears_ras_q :
      assert (!f_prev_fault0_q || (!f0_ras_push_q && !f0_ras_pop_q));
      p_prev_span_tail_fault_clears_ras_q :
      assert (!f_prev_span_tail_fault_q || (!f0_ras_push_q && !f0_ras_pop_q));
      p_span_tail_fault_restores_ras :
      assert (!f_prev_span_tail_fault_q || i_pipeline_ctrl.reset || ras_restore_q);
      cover_span_fault_veto :
      cover (!i_pipeline_ctrl.reset && f0_span_fault_veto && !f0_span_btb_fire &&
             !f0_ras_push && !f0_ras_pop);
      cover_span_tail_fault_restore :
      cover (!i_pipeline_ctrl.reset && f_prev_span_tail_fault_q && ras_restore_q);
      cover_slot1_hi_fault_clears_taken :
      cover (!i_pipeline_ctrl.reset && s1_valid && o_from_if_to_pd.fetch_fault &&
             o_from_if_to_pd.fetch_fault_hi && !o_from_if_to_pd.btb_predicted_taken);
      cover_slot2_fault_defers_to_slot1 :
      cover (!i_pipeline_ctrl.reset && s1_valid && !s1_fault && s2_fault &&
             o_from_if_to_pd_2.sel_nop);
    end
  end
`endif

`ifdef IF_SLOT2_VETO_REDUNDANT_PROOF
  // Formal model (formal/if_fault_ras_veto.sby, prove_slot2_veto_redundant):
  // intact decoupled if_stage never pairs a faulting instruction into slot 2
  // and always forces o_from_if_to_pd_2.fetch_fault low.
  logic f_veto_past_valid = 1'b0;
  initial assume (i_pipeline_ctrl.reset);

  always_ff @(posedge i_clk) begin
    f_veto_past_valid <= 1'b1;
    if (f_veto_past_valid) begin
      p_slot2_never_faults : assert (!o_from_if_to_pd_2.fetch_fault);
      p_slot2_valid_no_fault : assert (o_from_if_to_pd_2.sel_nop || (!s1_fault && !s2_fault));
      p_slot2_btb_requires_valid :
      assert (!o_from_if_to_pd_2.btb_predicted_taken || !o_from_if_to_pd_2.sel_nop);
      p_slot2_fault_clears_btb :
      assert (!s2_fault || !o_from_if_to_pd_2.btb_predicted_taken);
      p_slot1_fault_kills_slot2 : assert (!s1_fault || o_from_if_to_pd_2.sel_nop);
    end
  end
`endif

`ifdef IF_WALK_PAST_PROOF
  // Formal model (formal/if_prediction_walk_past.sby): checks interior-halfword
  // false-BTB resteer, phantom suppression, and emitted PC continuity.
  logic f_wp_past_valid = 1'b0;
  logic f_wp_s1_real;
  logic f_wp_s2_real;
  logic [3:0] valid_start;
  assign valid_start[0] = !f1_start_at_1;
  assign valid_start[1] = f1_start_at_1 || (valid_start[0] && (hw_comp[0] || hw_fault[0]));
  assign valid_start[2] = (valid_start[0] && !hw_comp[0] && !hw_fault[0]) ||
      (valid_start[1] && (hw_comp[1] || hw_fault[1]));
  assign valid_start[3] = (valid_start[1] && !hw_comp[1] && !hw_fault[1]) ||
      (valid_start[2] && (hw_comp[2] || hw_fault[2]));
  assign f_wp_s1_real = !o_from_if_to_pd.sel_nop;
  assign f_wp_s2_real = !o_from_if_to_pd_2.sel_nop;

  always_comb begin
    // An interior-halfword BTB hit (not on a valid instruction boundary) or a
    // size/opcode/fault mismatch on an accepted F1 window must trigger
    // f1_false_btb_resteer and suppress btb_taken on every pushed parcel.
    if (f1_accept && f1_src_btb_taken && !f1_is_span_tail &&
        (!valid_start[f1_src_btb_pos] ||
         (hw_comp[f1_src_btb_pos] != f1_src_btb_comp) ||
         !hw_is_control[f1_src_btb_pos] ||
         hw_fault[f1_src_btb_pos])) begin
      p_false_btb_triggers_resteer :
      assert (f1_false_btb &&
              (f1_req_q.btb_is_span ? f1_cancel_span : (f1_false_btb_resteer && f1_resteer)));
      p_false_btb_suppresses_taken : assert (!f1_valid_btb_taken);
    end
    // When a false-BTB resteer fires, F0 must not launch a new window and must
    // steer to f1_resteer_target on arm 5.
    if (!any_redirect && f1_false_btb_resteer) begin
      p_false_btb_blocks_f0_launch : assert (!f0_launch);
      p_false_btb_selects_arm5 : assert (npc_sel[5]);
    end
    // Slot 2 never emits when slot 1 is a bubble, fault, or predicted-taken
    // (checked after reset once count_ge_q is initialized).
    if (f_wp_past_valid && !i_pipeline_ctrl.reset) begin
      p_wp_slot2_order :
      assert (!f_wp_s2_real || (f_wp_s1_real && !o_from_if_to_pd.fetch_fault &&
                                !o_from_if_to_pd.btb_predicted_taken));
      p_wp_slot2_pc_step :
      assert (!f_wp_s2_real ||
              (o_from_if_to_pd_2.program_counter ==
               o_from_if_to_pd.program_counter +
               (o_from_if_to_pd.sel_compressed ? riscv_pkg::PcIncrementCompressed :
                                                 riscv_pkg::PcIncrement32bit)));
      if (!pqueue_flush) begin
        p_wp_drain_avail_s1_exact :
        assert (s1_have_bytes == (s1_need_2 ? q_avail_ge[1] : q_avail_ge[0]));
        if (!i_fetch_trap_hold && !s1_fault && s1_p.allows_slot2_after &&
            !s2_fault && s2_p.slot2_start_valid) begin
          p_wp_drain_avail_s2_exact :
          assert (s2_have_bytes ==
                  (s1_comp ? (s2_comp ? q_avail_ge[1] : q_avail_ge[2]) :
                             (s2_comp ? q_avail_ge[2] : q_avail_ge[3])));
        end
      end
    end
  end

`ifdef IF_CONTINUITY_PROOF
  logic f_wp_cont_valid_q = 1'b0;
  logic [XLEN-1:0] f_wp_expected_pc_q = '0;
  logic [XLEN-1:0] f_wp_s1_step;
  logic [XLEN-1:0] f_wp_s2_step;
  logic [XLEN-1:0] f_wp_bundle_next_pc;

  assign f_wp_s1_step = o_from_if_to_pd.sel_compressed ? 64'd2 : 64'd4;
  assign f_wp_s2_step = o_from_if_to_pd_2.sel_compressed ? 64'd2 : 64'd4;
  assign f_wp_bundle_next_pc =
      o_from_if_to_pd.btb_predicted_taken ? o_from_if_to_pd.btb_predicted_target :
      (f_wp_s2_real && o_from_if_to_pd_2.btb_predicted_taken) ?
      o_from_if_to_pd_2.btb_predicted_target :
      (o_from_if_to_pd.program_counter + f_wp_s1_step + (f_wp_s2_real ? f_wp_s2_step : 64'd0));
`endif

  always_ff @(posedge i_clk) begin
    f_wp_past_valid <= 1'b1;
`ifdef IF_CONTINUITY_PROOF
    if (i_pipeline_ctrl.reset || any_redirect) begin
      f_wp_cont_valid_q <= 1'b0;
    end else begin
      if (f_wp_past_valid && f_wp_cont_valid_q && f_wp_s1_real) begin
        p_formal_emitted_pc_continuity :
        assert (o_from_if_to_pd.program_counter == f_wp_expected_pc_q);
      end
      if (!i_pipeline_ctrl.stall && f_wp_s1_real) begin
        if (o_from_if_to_pd.fetch_fault) begin
          f_wp_cont_valid_q <= 1'b0;
        end else begin
          f_wp_cont_valid_q  <= 1'b1;
          f_wp_expected_pc_q <= f_wp_bundle_next_pc;
        end
      end
    end
`else
    if (f_wp_past_valid && !i_pipeline_ctrl.reset) begin
      cover_interior_halfword_false_btb :
      cover (f1_accept && f1_src_btb_taken && !f1_is_span_tail &&
             !valid_start[f1_src_btb_pos] && f1_false_btb_resteer);
      cover_real_slot2_packet : cover (f_wp_s1_real && f_wp_s2_real);
      cover_reserved_comp_then_itt :
      cover (f_wp_s1_real && o_from_if_to_pd.sel_compressed &&
             (o_from_if_to_pd.raw_parcel[1:0] == 2'b00) && o_itt_hit[0]);
      cover_backing_region_cross :
      cover (f_wp_s2_real && !s2_same_region && s2_p.backing_hit && !o_backing_hit[1]);
    end
`endif
  end
`endif

endmodule : if_stage
