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
 * Formal integration harness for decoupled if_stage's false-BTB resteer,
 * packet-contract, and PC-continuity rules. Runs the real if_stage,
 * fetch_pc_decoupled, fetch_parcel_queue, backing_btb, and return_address_stack
 * together. Fast-BTB, direction-predictor, TAGE/ITTAGE, and IMMU lookup tables
 * are replaced by unconstrained lookup stubs below so arbitrary hits, targets,
 * and translation/fault responses are explored without array warm-up.
 *
 * Instruction windows are arbitrary 64-bit fetches for both providers; their
 * predecode sidebands, provider-parity replicas, and served-window word tags
 * follow the exact structural wiring of frost_hart. Redirects and pipeline
 * stall/flush follow ooo_pipeline_control's structural relations.
 */
module if_prediction_walk_past_formal (
    input logic i_clk
);

  localparam int unsigned XLEN = riscv_pkg::XLEN;

  (* anyconst *) logic [XLEN-2:0] boot_addr_hw;
  (* anyseq *) logic i_reset;
  (* anyseq *) logic raw_stall;
  (* anyseq *) logic raw_trap_taken;
  (* anyseq *) logic raw_mret_taken;
  (* anyseq *) logic [XLEN-2:0] raw_trap_target_hw;
  (* anyseq *) logic raw_fence_i_flush;
  (* anyseq *) logic [XLEN-2:0] raw_fence_i_target_hw;
  (* anyseq *) logic raw_branch_taken;
  (* anyseq *) logic [XLEN-2:0] raw_branch_target_hw;
  (* anyseq *) logic raw_pd_redirect;
  (* anyseq *) logic raw_pd_redirect_taken;
  (* anyseq *) logic [XLEN-2:0] raw_pd_redirect_target_hw;
  (* anyseq *) logic i_btb_invalidate;
  (* anyseq *) logic i_disable_branch_prediction;
  (* anyseq *) logic i_fetch_trap_hold;
  (* anyseq *) logic i_fetch_translation_active;
  (* anyseq *) logic i_fetch_priv_u;
  (* anyseq *) logic [riscv_pkg::AsidBits-1:0] i_fetch_asid;
  (* anyseq *) logic [1:0][63:0] fetch_instr;
  (* anyseq *) logic [1:0] fetch_bank;
  (* anyseq *) logic [1:0][XLEN-3:0] served_word;
  (* anyseq *) logic provider_q;
  (* anyseq *) logic raw_instr_valid;
  (* anyseq *) logic i_instr_fault0;
  (* anyseq *) logic i_instr_fault0_page;
  (* anyseq *) logic i_instr_fault1;
  (* anyseq *) logic i_instr_fault1_page;

`ifndef PREDICTOR_FETCH_CONTRACT
  logic f_init_reset_q = 1'b0;
  always_ff @(posedge i_clk) begin
    f_init_reset_q <= 1'b1;
    if (!f_init_reset_q) assume (i_reset);
  end
`endif

  logic stall_q = 1'b0;
  logic pd_redirect_r = 1'b0;
  logic pd_redirect_taken_r = 1'b0;
  logic [XLEN-1:0] pd_redirect_target_r = '0;
  logic i_instr_valid;
  riscv_pkg::pipeline_ctrl_t pipeline_ctrl;
  riscv_pkg::trap_ctrl_t trap_ctrl;
  riscv_pkg::from_ex_comb_t from_ex_comb;
  logic flush_all;
  logic fence_i_flush;
  logic [XLEN-1:0] fence_i_target;
  logic pd_redirect;
  logic pd_redirect_taken;
  logic [XLEN-1:0] pd_redirect_target;
  riscv_pkg::from_if_to_pd_t from_if_to_pd;
  riscv_pkg::from_if_to_pd_t from_if_to_pd_2;

  assign fence_i_flush  = raw_fence_i_flush && !i_reset;
  assign fence_i_target = {raw_fence_i_target_hw, 1'b0};

  // Decoupled fetch_provider receives constant-zero stall from cpu_ooo, so
  // valid windows from either provider may arrive on any cycle, including
  // immediately after a pipeline stall.
  assign i_instr_valid  = raw_instr_valid;

  always_comb begin
    trap_ctrl = '0;
    trap_ctrl.trap_taken = raw_trap_taken && !i_reset;
    trap_ctrl.mret_taken = raw_mret_taken && !raw_trap_taken && !i_reset;
    trap_ctrl.trap_target = {raw_trap_target_hw, 1'b0};

    from_ex_comb = '0;
    from_ex_comb.branch_taken = raw_branch_taken && !i_reset;
    from_ex_comb.branch_target_address = {raw_branch_target_hw, 1'b0};

    flush_all = trap_ctrl.trap_taken || trap_ctrl.mret_taken || fence_i_flush;

    pipeline_ctrl = '0;
    pipeline_ctrl.reset = i_reset;
    pipeline_ctrl.flush = flush_all || from_ex_comb.branch_taken;
    pipeline_ctrl.stall = raw_stall && !i_reset && !pipeline_ctrl.flush;
    pipeline_ctrl.stall_registered = stall_q;
    pipeline_ctrl.trap_taken_registered = trap_ctrl.trap_taken;
    pipeline_ctrl.mret_taken_registered = trap_ctrl.mret_taken;
  end

  // pd_stage registers its redirect outputs with enable !pipeline_ctrl.stall,
  // clearing on reset or flush and never firing two unstalled cycles in a row
  // or from a bubble packet (pd_stage.sv:656, 797-828).
  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      stall_q <= 1'b0;
      pd_redirect_r <= 1'b0;
      pd_redirect_taken_r <= 1'b0;
      pd_redirect_target_r <= '0;
    end else begin
      stall_q <= pipeline_ctrl.stall;
      if (pipeline_ctrl.flush) begin
        pd_redirect_r <= 1'b0;
      end else if (!pipeline_ctrl.stall) begin
        pd_redirect_r <= raw_pd_redirect && !pd_redirect_r && !from_if_to_pd.sel_nop;
        pd_redirect_taken_r <= raw_pd_redirect_taken;
        pd_redirect_target_r <= {raw_pd_redirect_target_hw, 1'b0};
      end
    end
  end

  assign pd_redirect = pd_redirect_r;
  assign pd_redirect_taken = pd_redirect_taken_r;
  assign pd_redirect_target = pd_redirect_target_r;

  // Canonical sideband and parity replicas (matching frost_hart.sv).
  logic [1:0][riscv_pkg::ImemFetchSidebandWidth-1:0] fetch_sideband;
  logic [1:0][7:0] meta_canon;
  logic [1:0][7:0] fetch_metadata;
  logic [1:0][3:0] fetch_pairability;
  logic [1:0][1:0] fetch_slot2_valid;

  for (genvar p = 0; p < 2; p++) begin : gen_provider_sideband
    assign fetch_sideband[p] = {
      riscv_pkg::imem_make_sideband(fetch_instr[p][63:32]),
      riscv_pkg::imem_make_sideband(fetch_instr[p][31:0])
    };
    assign meta_canon[p] = {
      fetch_sideband[p][riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeHi],
      fetch_sideband[p][riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableCompressedHi],
      fetch_sideband[p][riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbIsCompressedHi],
      fetch_sideband[p][riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbIsCompressedLo],
      fetch_sideband[p][riscv_pkg::ImemSbPairableNativeHi],
      fetch_sideband[p][riscv_pkg::ImemSbPairableCompressedHi],
      fetch_sideband[p][riscv_pkg::ImemSbIsCompressedHi],
      fetch_sideband[p][riscv_pkg::ImemSbIsCompressedLo]
    };
    assign fetch_metadata[p] = fetch_bank[p] ? {meta_canon[p][3:0], meta_canon[p][7:4]} :
                                               meta_canon[p];
    assign fetch_slot2_valid[p] = fetch_bank[p] ? {
      fetch_sideband[p][riscv_pkg::ImemSbSlot2StartValidLo],
      fetch_sideband[p][riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbSlot2StartValidLo]
    } : {
      fetch_sideband[p][riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbSlot2StartValidLo],
      fetch_sideband[p][riscv_pkg::ImemSbSlot2StartValidLo]
    };
    assign fetch_pairability[p] = fetch_bank[p] ? {
      fetch_sideband[p][riscv_pkg::ImemSbPairableNativeLo],
      fetch_sideband[p][riscv_pkg::ImemSbEvenLocalPairValid],
      fetch_sideband[p][riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeLo],
      fetch_sideband[p][riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbEvenLocalPairValid]
    } : {
      fetch_sideband[p][riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbPairableNativeLo],
      fetch_sideband[p][riscv_pkg::ImemSidebandWidth+riscv_pkg::ImemSbEvenLocalPairValid],
      fetch_sideband[p][riscv_pkg::ImemSbPairableNativeLo],
      fetch_sideband[p][riscv_pkg::ImemSbEvenLocalPairValid]
    };
  end

  logic [63:0] bram_instr_by_parity;
  assign bram_instr_by_parity = fetch_bank[0] ? {fetch_instr[0][31:0], fetch_instr[0][63:32]} :
                                                fetch_instr[0];

  logic [4:1] restore_arm;
  logic [1:0] backing_hit, backing_return, backing_return_by_size;
  logic [1:0][riscv_pkg::PhysAddrBits-2:0] backing_target, backing_target_by_size;

`ifdef PREDICTOR_FETCH_CONTRACT
  predictor_fetch_contract contract (
      .i_clk,
      .i_reset,
      .i_pd_redirect(pd_redirect),
      .i_restore_arm(restore_arm),
      .s1(from_if_to_pd),
      .s2(from_if_to_pd_2),
      .i_backing_hit(backing_hit),
      .i_backing_return(backing_return),
      .i_by_size_return(backing_return_by_size),
      .i_backing_target(backing_target),
      .i_by_size_target(backing_target_by_size)
  );
`endif

  if_stage #(
      .XLEN(XLEN)
  ) u_if_stage (
      .i_clk,
      .i_boot_addr({boot_addr_hw, 1'b0}),
      .i_from_ex_comb(from_ex_comb),
      .i_btb_early_update_active(1'b0),
      .i_btb_early_update_pc('0),
      .i_btb_early_update_taken(1'b0),
      .i_btb_late_update_pc('0),
      .i_btb_late_update_taken(1'b0),
      .i_instr(fetch_instr[provider_q]),
      .i_instr_low_by_parity(bram_instr_by_parity),
      .i_instr_high(fetch_instr[1]),
      .i_instr_window_high(provider_q),
      .i_instr_sideband(fetch_sideband[provider_q]),
      .i_instr_pc_metadata(meta_canon[provider_q]),
      .i_instr_pc_metadata_by_provider_parity({fetch_metadata[1], fetch_metadata[0]}),
      .i_pc_pairability_by_provider_parity({fetch_pairability[1], fetch_pairability[0]}),
      .i_slot2_start_valid_lo_by_provider_parity({fetch_slot2_valid[1], fetch_slot2_valid[0]}),
      .i_instr_pc_metadata_served_high(provider_q),
      .i_instr_bank_sel_r(fetch_bank[provider_q]),
      .i_served_word_low(served_word[0]),
      .i_served_last_word_low(served_word[0] + 1'b1),
      .i_served_prev_word_low(served_word[0] - 1'b1),
      .i_served_prev_word_valid_low(|served_word[0]),
      .i_served_word_high(served_word[1]),
      .i_served_last_word_high(served_word[1] + 1'b1),
      .i_served_prev_word_high(served_word[1] - 1'b1),
      .i_served_prev_word_valid_high(|served_word[1]),
      .i_instr_valid,
      .i_instr_fault0,
      .i_instr_fault0_page,
      .i_instr_fault1,
      .i_instr_fault1_page,
      .i_served_high(provider_q),
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_trap_ctrl(trap_ctrl),
      .i_frontend_state_flush(pipeline_ctrl.flush),
      .i_flush_all(flush_all),
      .i_fence_i_flush(fence_i_flush),
      .i_fence_i_target(fence_i_target),
      .i_btb_invalidate,
      .i_disable_branch_prediction,
      .i_fetch_trap_hold,
      .i_dir_update_valid(1'b0),
      .i_dir_update_idx('0),
      .i_dir_update_taken(1'b0),
      .i_pd_redirect(pd_redirect),
      .i_pd_redirect_taken(pd_redirect_taken),
      .i_pd_redirect_target(pd_redirect_target),
      .i_pd_redirect_ras_push(1'b0),
      .i_pd_redirect_ras_pop(1'b0),
      .i_pd_redirect_ras_link('0),
      .i_pd_backing_refresh(1'b0),
      .i_pd_backing_refresh_pc('0),
      .o_pc(),
      .o_fetch_replay_consume(),
      .o_fetch_live_claim(),
      .o_fetch_pa0(),
      .o_fetch_pa1(),
      .o_fetch_pa_valid(),
      .o_fetch_fault0(),
      .o_fetch_fault0_page(),
      .o_fetch_fault1(),
      .o_fetch_fault1_page(),
      .o_fetch_line_after_ok(),
      .o_fetch_redirect(),
      .o_fetch_cached_retarget(),
      .o_fetch_pa_hold(),
      .o_fetch_pa_hold_copy(),
      .i_fetch_translation_active,
      .i_fetch_priv_u,
      .i_fetch_asid,
      .i_tlb_invalidate(1'b0),
      .i_tlb_flush('0),
      .o_walk_req_valid(),
      .i_walk_req_ready(1'b0),
      .o_walk_vpn(),
      .i_walk_resp_valid(1'b0),
      .i_walk_resp('0),
      .o_from_if_to_pd(from_if_to_pd),
      .o_from_if_to_pd_2(from_if_to_pd_2),
      .o_backing_hit(backing_hit),
      .o_backing_compressed(),
      .o_backing_return(backing_return),
      .o_backing_target(backing_target),
      .o_backing_slot2_return_by_size(backing_return_by_size),
      .o_backing_slot2_target_by_size(backing_target_by_size),
      .o_slot1_has_control_flow(),
      .o_slot1_is_indirect(),
      .o_width_events(),
      // Each predictor stub supplies independent responses. The walk-past
      // contract has no training source and does not consume the saved lookups.
      .i_itt_hist('0),
      .i_itt_train_valid(1'b0),
      .i_itt_train_lookup('0),
      .i_itt_train_bank(1'b0),
      .i_itt_train_target('0),
      .i_itt_train_mispredicted(1'b0),
      .o_itt_slot_lookup(),
      .o_itt_slot_lookup_2(),
      .o_itt_hit(),
      .o_itt_target(),
      .i_tage_hist('0),
      .i_tage_train_valid(1'b0),
      .i_tage_train_lookup('0),
      .i_tage_train_bank(1'b0),
      .i_tage_train_alt_taken(1'b0),
      .i_tage_train_taken(1'b0),
      .i_tage_train_mispredicted(1'b0),
      .o_tage_hist_push(),
      .o_tage_hist_restore_arm(restore_arm),
      .o_tage_fetch_path_bits(),
      .o_tage_slot_valid(),
      .o_tage_slot_lookup(),
      .o_tage_slot_lookup_2(),
      .o_tage_lookup_hist()
  );

`ifdef PREDICTOR_FETCH_CONTRACT
  // Relate the parcel bytes and their predecode sideband fields across every
  // occupied entry of the decoupled parcel queue.
  localparam int unsigned FParcelBits =
      16 + 4 + 2 + 5 + 3 + 23 + 2 + 2 + 2 + 3 + (riscv_pkg::PhysAddrBits - 1);

  function automatic logic parcel_sideband_ok(input logic [FParcelBits-1:0] raw);
    logic [15:0] hw;
    logic [riscv_pkg::ImemSidebandWidth-1:0] sb;
    begin
      hw = raw[FParcelBits-1-:16];
      sb = riscv_pkg::imem_make_sideband({16'h0, hw});
      parcel_sideband_ok =
          (raw[FParcelBits-17] == sb[riscv_pkg::ImemSbAllowsSlot2AfterLo]) &&
          (raw[FParcelBits-21-:2] == sb[riscv_pkg::ImemSbRvcSourceHotLoLsb+:2]) &&
          (raw[FParcelBits-23-:5] == sb[riscv_pkg::ImemSbRvcBits24To20LoLsb+:5]) &&
          (raw[FParcelBits-28-:3] == sb[riscv_pkg::ImemSbRvcRs1RestLoLsb+:3]) &&
          (raw[FParcelBits-31-:23] == sb[riscv_pkg::ImemSbRvcExtraLoLsb+:23]);
    end
  endfunction

  logic checked_edge = 1'b0;
  logic [3:0][3:0] queue_slot_valid_q = '0;
  logic queue_source_ok;
  logic queue_sideband_ok;

  always_comb begin
    logic [3:0] q_head;
    logic [3:0] q_tail;
    logic [4:0] q_cnt;
    q_head = u_if_stage.u_parcel_queue.head_q;
    q_tail = u_if_stage.u_parcel_queue.tail_q;
    q_cnt = u_if_stage.u_parcel_queue.count_q;

    queue_source_ok = (q_cnt <= 5'd16) && (q_tail == (q_head + q_cnt[3:0])) &&
        (u_if_stage.u_parcel_queue.count_ge_q == {
           (q_cnt >= 5'd4), (q_cnt >= 5'd3), (q_cnt >= 5'd2), (q_cnt >= 5'd1)
         }) &&
        (u_if_stage.u_parcel_queue.count_eq1_q == (q_cnt == 5'd1));
    for (int b = 0; b < 4; b++) begin
      logic [1:0] wr_off;
      wr_off = 2'(b) - q_tail[1:0];
      queue_source_ok = queue_source_ok &&
          (u_if_stage.u_parcel_queue.rd_row_q[b] ==
           (q_head[3:2] + ((2'(b) < q_head[1:0]) ? 2'd1 : 2'd0))) &&
          (u_if_stage.u_parcel_queue.wr_row_q[b] ==
           (q_tail[3:2] + ((2'(b) < q_tail[1:0]) ? 2'd1 : 2'd0))) &&
          (u_if_stage.u_parcel_queue.bank_free_q[b] ==
           (5'(wr_off) < (5'd16 - q_cnt)));
    end
    for (int k = 0; k < 16; k++) begin
      logic [3:0] idx;
      idx = q_head + 4'(k);
      if (5'(k) < q_cnt) begin
        queue_source_ok = queue_source_ok && queue_slot_valid_q[idx[1:0]][idx[3:2]];
      end
    end

    queue_sideband_ok = 1'b1;
    for (int b = 0; b < 4; b++) begin
      for (int r = 0; r < 4; r++) begin
        if (queue_slot_valid_q[b][r]) begin
          queue_sideband_ok = queue_sideband_ok &&
              parcel_sideband_ok(u_if_stage.u_parcel_queue.ring_q[b][r][FParcelBits-1:0]);
        end
      end
    end
  end

  always @(posedge i_clk) begin
    checked_edge <= 1'b1;
    if (i_reset || u_if_stage.pqueue_flush) begin
      queue_slot_valid_q <= '0;
    end else begin
      for (int b = 0; b < 4; b++) begin
        if (u_if_stage.u_parcel_queue.bank_we[b]) begin
          queue_slot_valid_q[b][u_if_stage.u_parcel_queue.wr_row_q[b]] <= 1'b1;
        end
      end
    end
    if (checked_edge) begin
      p_queue_source_on_use : assert (queue_source_ok);
      p_queue_sideband : assert (queue_sideband_ok);
      c_queued_compressed :
      cover (!from_if_to_pd.sel_nop && !from_if_to_pd.fetch_fault &&
             (u_if_stage.u_parcel_queue.count_q != '0) && (from_if_to_pd.raw_parcel[1:0] != 2'b11));
      c_bypass_compressed :
      cover (!from_if_to_pd.sel_nop && !from_if_to_pd.fetch_fault &&
             (u_if_stage.u_parcel_queue.count_q == '0) && (from_if_to_pd.raw_parcel[1:0] != 2'b11));
    end
  end
`endif

endmodule : if_prediction_walk_past_formal

// verilog_lint: waive module-filename
module fetch_btb_2w #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned BTB_INDEX_BITS = 8,
    parameter int unsigned BIM_BITS = riscv_pkg::BpDirIdxBits
) (
    input  logic                      i_clk,
    input  logic                      i_rst,
    input  logic [          XLEN-1:0] i_pc,
    input  logic [BTB_INDEX_BITS-2:0] i_pc_even_idx,
    input  logic                      i_fetch_translation_active,
    input  logic                      i_pc_is_cached,
    input  logic                      i_ras_nonempty,
    input  logic                      i_ras_top_is_cached,
    input  logic [          XLEN-1:0] i_ras_top,
    input  logic [      BIM_BITS-3:0] i_ras_even_dir_idx,
    output logic                      o_taken,
    output logic                      o_taken_steer,
    output logic [               1:0] o_taken_pos,
    output logic [          XLEN-1:0] o_target,
    output logic [      BIM_BITS-3:0] o_target_even_dir_idx,
    output logic                      o_compressed,
    output logic                      o_is_call,
    output logic                      o_is_return,
    output logic                      o_is_span,
    output logic                      o_target_is_cached,
    output logic                      o_w0_hit,
    output logic                      o_w1_hit,
    output logic                      o_w0_taken,
    output logic                      o_w0_sel,
    output logic [          XLEN-1:0] o_w1_target,
    output logic [      BIM_BITS-3:0] o_w1_even_dir_idx,
    output logic                      o_w1_is_call,
    output logic                      o_w1_is_return,
    output logic                      o_w0_link_inc,
    output logic                      o_w1_link_inc,
    output logic                      o_w0_link_hw,
    output logic                      o_w1_link_hw,
    input  logic                      i_update,
    input  logic [          XLEN-1:0] i_update_pc,
    input  logic [          XLEN-1:0] i_update_target,
    input  logic                      i_update_taken,
    input  logic                      i_update_compressed,
    input  logic                      i_update_call,
    input  logic                      i_update_return,
    input  logic                      i_early_update_active,
    input  logic [          XLEN-1:0] i_early_update_pc,
    input  logic                      i_early_update_taken,
    input  logic [          XLEN-1:0] i_late_update_pc,
    input  logic                      i_late_update_taken,
    input  logic                      i_invalidate_all
);
  (* anyseq *) logic f_taken, f_comp, f_call, f_ret, f_tgt_cached, f_w0, f_w1;
  (* anyseq *) logic [1:0] f_pos;
  (* anyseq *) logic [XLEN-2:0] f_target_hw;

  logic [XLEN-1:0] eff_target;
  logic eff_cached;
  logic same_tier;
  assign eff_target            = (f_ret && i_ras_nonempty) ? i_ras_top : {f_target_hw, 1'b0};
  assign eff_cached            = (f_ret && i_ras_nonempty) ? i_ras_top_is_cached : f_tgt_cached;
  assign same_tier             = i_fetch_translation_active || (eff_cached == i_pc_is_cached);

  assign o_taken               = f_taken && same_tier;
  assign o_is_span             = o_taken && (f_pos == 2'd3) && !f_comp;
  assign o_taken_steer         = o_taken && !o_is_span;
  assign o_taken_pos           = f_pos;
  assign o_target              = eff_target;
  assign o_target_even_dir_idx = eff_target[BIM_BITS:3] + (BIM_BITS - 2)'(eff_target[2]);
  assign o_compressed          = f_comp;
  assign o_is_call             = o_taken && f_call;
  assign o_is_return           = o_taken && f_ret;
  assign o_target_is_cached    = eff_cached;
  assign o_w0_hit              = f_w0;
  assign o_w1_hit              = f_w1;
  assign o_w0_taken            = o_taken && !f_pos[1];
  assign o_w0_sel              = !f_pos[1];
  assign o_w1_target           = eff_target;
  assign o_w1_even_dir_idx     = eff_target[BIM_BITS:3] + (BIM_BITS - 2)'(eff_target[2]);
  assign o_w1_is_call          = f_call;
  assign o_w1_is_return        = f_ret;
  assign o_w0_link_inc         = f_pos[0] || !f_comp;
  assign o_w1_link_inc         = f_pos[0] || !f_comp;
  assign o_w0_link_hw          = f_pos[0] ^ f_comp;
  assign o_w1_link_hw          = f_pos[0] ^ f_comp;
endmodule : fetch_btb_2w

// verilog_lint: waive module-filename
module fetch_dir_4b #(
    parameter int unsigned XLEN     = riscv_pkg::XLEN,
    parameter int unsigned BIM_BITS = riscv_pkg::BpDirIdxBits
) (
    input  logic                i_clk,
    input  logic                i_rst,
    input  logic [    XLEN-1:0] i_pc,
    input  logic [BIM_BITS-3:0] i_pc_even_dir_idx,
    output logic [         3:0] o_taken,
    input  logic                i_update_valid,
    input  logic [BIM_BITS-1:0] i_update_idx,
    input  logic                i_update_taken
);
  (* anyseq *) logic [3:0] f_taken;
  assign o_taken = f_taken;
endmodule : fetch_dir_4b

// verilog_lint: waive module-filename
module return_address_stack #(
    parameter int unsigned RAS_DEPTH = 8,
    parameter int unsigned RAS_PTR_BITS = $clog2(RAS_DEPTH)
) (
    input  logic                       i_clk,
    input  logic                       i_rst,
    input  logic                       i_push,
    input  logic                       i_pop,
    input  logic [riscv_pkg::XLEN-1:0] i_push_address,
    input  logic                       i_misprediction,
    input  logic [   RAS_PTR_BITS-1:0] i_restore_tos,
    input  logic [     RAS_PTR_BITS:0] i_restore_valid_count,
    input  logic [riscv_pkg::XLEN-1:0] i_restore_top,
    input  logic                       i_pop_after_restore,
    input  logic                       i_push_after_restore,
    input  logic [riscv_pkg::XLEN-1:0] i_push_address_after_restore,
    output logic                       o_nonempty,
    output logic [riscv_pkg::XLEN-1:0] o_top,
    output logic [   RAS_PTR_BITS-1:0] o_tos,
    output logic [     RAS_PTR_BITS:0] o_valid_count
);
  (* anyseq *) logic f_nonempty;
  (* anyseq *) logic [riscv_pkg::XLEN-2:0] f_top_hw;
  (* anyseq *) logic [RAS_PTR_BITS-1:0] f_tos;
  (* anyseq *) logic [RAS_PTR_BITS:0] f_valid_count;
  assign o_nonempty = f_nonempty;
  assign o_top = {f_top_hw, 1'b0};
  assign o_tos = f_tos;
  assign o_valid_count = f_valid_count;
endmodule : return_address_stack

`ifndef PREDICTOR_FETCH_CONTRACT
// verilog_lint: waive module-filename
module backing_btb #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned ENTRIES = riscv_pkg::BackingBtbEntries,
    parameter int unsigned WAYS = riscv_pkg::BackingBtbWays,
    parameter int unsigned TARGET_BITS = riscv_pkg::PhysAddrBits,
    parameter bit PRECOMPARE_WIN_PC = 1'b0
) (
    input  logic                                             i_clk,
    input  logic                                             i_reset,
    input  logic                                             i_redirect,
    input  logic [$clog2(ENTRIES/WAYS)-1:0]                  i_lookup_index,
    input  logic [                XLEN-1:0]                  i_packet_pc,
    input  logic                                             i_packet_compressed,
    output logic [                     1:0]                  o_hit,
    output logic [                     1:0]                  o_compressed,
    output logic [                     1:0]                  o_return,
    output logic [                     1:0][TARGET_BITS-2:0] o_target,
    output logic [                     1:0]                  o_slot2_return_by_size,
    output logic [                     1:0][TARGET_BITS-2:0] o_slot2_target_by_size,
    input  logic [                XLEN-1:0]                  i_lookup_pc = '0,
    input  logic [                XLEN-1:0]                  i_win_pc = '0,
    output logic [                     3:0]                  o_win_hit,
    output logic [                     3:0]                  o_win_compressed,
    output logic [                     3:0]                  o_win_return,
    output logic [                     3:0][TARGET_BITS-2:0] o_win_target,
    input  logic                                             i_update,
    input  logic [                XLEN-1:0]                  i_update_pc,
    input  logic [                XLEN-1:0]                  i_update_target,
    input  logic                                             i_update_compressed,
    input  logic                                             i_update_return,
    input  logic                                             i_refresh,
    input  logic [                XLEN-1:0]                  i_refresh_pc
);
  (* anyseq *) logic [1:0] f_hit, f_comp, f_ret, f_ret_by_size;
  (* anyseq *) logic [1:0][TARGET_BITS-2:0] f_target, f_target_by_size;
  (* anyseq *) logic [3:0] f_win_hit, f_win_comp, f_win_ret;
  (* anyseq *) logic [3:0][TARGET_BITS-2:0] f_win_target;
  assign o_hit = f_hit;
  assign o_compressed = f_comp;
  // Slot 2's type and target are the entries at the packet's size, as in
  // backing_btb.
  assign o_return = {f_ret_by_size[i_packet_compressed], f_ret[0]};
  assign o_target = {f_target_by_size[i_packet_compressed], f_target[0]};
  assign o_slot2_return_by_size = f_ret_by_size;
  assign o_slot2_target_by_size = f_target_by_size;
  assign o_win_hit = f_win_hit;
  assign o_win_compressed = f_win_comp;
  assign o_win_return = f_win_ret;
  assign o_win_target = f_win_target;
endmodule : backing_btb
`endif

// verilog_lint: waive module-filename
module tage_predictor #(
    parameter int unsigned HIST_BITS = riscv_pkg::TageDirHistBits,
    parameter int unsigned TABLES = riscv_pkg::TageTables,
    parameter int unsigned INDEX_BITS = riscv_pkg::TageIndexBits,
    parameter int unsigned TAG_BITS = riscv_pkg::TageTagBits,
    parameter int unsigned LOOKUP_HI = 2 + 2 * INDEX_BITS,
    parameter bit USE_EXTERNAL_FOLD_INDEX = 1'b0
) (
    input  logic                                                    i_clk,
    input  logic                    [  LOOKUP_HI:2]                 i_lookup_word,
    input  logic                    [HIST_BITS-1:0]                 i_lookup_hist,
    input  logic                    [   TABLES-1:0][INDEX_BITS-1:0] i_lookup_fold_index = '0,
    input  logic                                                    i_lookup_capture,
    output logic                    [  LOOKUP_HI:2]                 o_lookup_word,
    output logic                    [  LOOKUP_HI:2]                 o_lookup_word_next,
    output logic                    [HIST_BITS-1:0]                 o_lookup_hist,
    output riscv_pkg::tage_lookup_t                                 o_bank0,
    output riscv_pkg::tage_lookup_t                                 o_bank1,
    input  logic                                                    i_train_valid,
    input  riscv_pkg::tage_lookup_t                                 i_train_lookup,
    input  logic                                                    i_train_bank,
    input  logic                                                    i_train_alt_taken,
    input  logic                                                    i_train_taken,
    input  logic                                                    i_train_mispredicted
);
  (* anyseq *)logic [  LOOKUP_HI:2] f_word;
  (* anyseq *)logic [HIST_BITS-1:0] f_hist;
  (* anyseq *) riscv_pkg::tage_lookup_t f_b0, f_b1;
  assign o_lookup_word = f_word;
  assign o_lookup_word_next = f_word + 1'b1;
  assign o_lookup_hist = f_hist;
  assign o_bank0 = f_b0;
  assign o_bank1 = f_b1;
endmodule : tage_predictor

// verilog_lint: waive module-filename
module ittage_predictor #(
    parameter int unsigned HIST_BITS = riscv_pkg::TageHistBits,
    parameter int unsigned HIST1 = riscv_pkg::IttHist1Bits,
    parameter int unsigned HIST2 = riscv_pkg::IttHist2Bits,
    parameter int unsigned HIST3 = riscv_pkg::IttHist3Bits,
    parameter int unsigned INDEX_BITS = riscv_pkg::IttIndexBits,
    parameter int unsigned TAG_BITS = riscv_pkg::IttTagBits,
    parameter int unsigned TARGET_BITS = riscv_pkg::PhysAddrBits,
    parameter int unsigned LOOKUP_HI = riscv_pkg::TageLookupHiBit
) (
    input  logic                                                      i_clk,
    input  logic                   [    LOOKUP_HI:2]                  i_lookup_word,
    input  logic                   [  HIST_BITS-1:0]                  i_lookup_hist,
    input  logic                                                      i_lookup_capture,
    output logic                   [  HIST_BITS-1:0]                  o_lookup_hist,
    output riscv_pkg::itt_lookup_t                                    o_bank0,
    output riscv_pkg::itt_lookup_t                                    o_bank1,
    output logic                   [            1:0]                  o_hit,
    output logic                   [            1:0][TARGET_BITS-2:0] o_target,
    input  logic                                                      i_train_valid,
    input  riscv_pkg::itt_lookup_t                                    i_train_lookup,
    input  logic                                                      i_train_bank,
    input  logic                   [TARGET_BITS-2:0]                  i_train_target,
    input  logic                                                      i_train_mispredicted
);
  // The indirect target predictor's outputs are free: the walk-past checks
  // do not depend on its predictions.
  (* anyseq *) logic [HIST_BITS-1:0] f_hist;
  (* anyseq *) riscv_pkg::itt_lookup_t f_b0, f_b1;
  (* anyseq *) logic [1:0] f_hit;
  (* anyseq *) logic [1:0][TARGET_BITS-2:0] f_target;
  assign o_lookup_hist = f_hist;
  assign o_bank0 = f_b0;
  assign o_bank1 = f_b1;
  assign o_hit = f_hit;
  assign o_target = f_target;
endmodule : ittage_predictor

// verilog_lint: waive module-filename
module immu #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned NUM_ENTRIES = 16,
    parameter int unsigned PA_VALID_COPIES = 1,
    parameter bit PA_COPY_HOLD = 1'b0
) (
    input  logic                                                i_clk,
    input  logic                                                i_rst,
    input  logic                                                i_active,
    input  logic                                                i_priv_u,
    input  logic                                                i_tlb_invalidate,
    input  riscv_pkg::tlb_flush_t                               i_tlb_flush,
    input  logic                  [    riscv_pkg::AsidBits-1:0] i_asid,
    input  logic                                                i_full_flush = 1'b0,
    input  logic                  [                   XLEN-1:0] i_pc,
    output logic                  [riscv_pkg::PhysAddrBits-1:0] o_pa0,
    output logic                  [riscv_pkg::PhysAddrBits-1:0] o_pa1,
    output logic                                                o_pa_valid,
    output logic                  [        PA_VALID_COPIES-1:0] o_pa_valid_copy,
    output logic                                                o_fault0,
    output logic                                                o_fault0_page,
    output logic                                                o_fault1,
    output logic                                                o_fault1_page,
    output logic                                                o_line_after_ok,
    output logic                                                o_walk_req_valid,
    input  logic                                                i_walk_req_ready,
    output logic                  [ riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,
    input  logic                                                i_walk_resp_valid,
    input  riscv_pkg::ptw_resp_t                                i_walk_resp
);
  (* anyseq *) logic [riscv_pkg::PhysAddrBits-1:0] f_pa0, f_pa1;
  (* anyseq *) logic f_pa_valid, f_fault0, f_fault0_page, f_fault1, f_fault1_page, f_line_ok;
  (* anyseq *) logic f_walk_req;
  (* anyseq *) logic [riscv_pkg::Sv39VpnBits-1:0] f_walk_vpn;
  assign o_pa0 = f_pa0;
  assign o_pa1 = f_pa1;
  assign o_pa_valid = f_pa_valid;
  assign o_pa_valid_copy = {PA_VALID_COPIES{PA_COPY_HOLD ? !f_pa_valid : f_pa_valid}};
  assign o_fault0 = f_fault0;
  assign o_fault0_page = f_fault0_page;
  assign o_fault1 = f_fault1;
  assign o_fault1_page = f_fault1_page;
  assign o_line_after_ok = f_line_ok;
  assign o_walk_req_valid = f_walk_req;
  assign o_walk_vpn = f_walk_vpn;
endmodule : immu
