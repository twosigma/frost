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

// Over-approximating RAM stubs: tag, payload, and counter memories return
// arbitrary unconstrained words each cycle, so only the real valid-bit
// flip-flops can keep lookups from hitting.
module sdp_dist_ram #(
    parameter int unsigned ADDR_WIDTH = 5,
    parameter int unsigned DATA_WIDTH = 32
) (
    input  logic                  i_clk,
    input  logic                  i_write_enable,
    input  logic [ADDR_WIDTH-1:0] i_write_address,
    input  logic [ADDR_WIDTH-1:0] i_read_address,
    input  logic [DATA_WIDTH-1:0] i_write_data,
    output logic [DATA_WIDTH-1:0] o_read_data
);
  (* anyseq *) logic [DATA_WIDTH-1:0] free_read;
  assign o_read_data = free_read;
endmodule

module sdp_block_ram #(
    parameter int unsigned ADDR_WIDTH = 5,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned SUPPORT_BULK_CLEAR = 0
) (
    input  logic                  i_clk,
    input  logic                  i_write_enable,
    input  logic                  i_bulk_clear,
    input  logic [ADDR_WIDTH-1:0] i_write_address,
    input  logic [ADDR_WIDTH-1:0] i_read_address,
    input  logic [DATA_WIDTH-1:0] i_write_data,
    output logic [DATA_WIDTH-1:0] o_read_data
);
  (* anyseq *) logic [DATA_WIDTH-1:0] free_read;
  assign o_read_data = free_read;
endmodule

// Proves that if_stage holds i_btb_invalidate active for exactly four cycles,
// wires that held clear and the registered update pipe directly to
// fetch_btb_2w, clears both even and odd valid-bit banks on each of those
// cycles, and drops any in-flight BTB updates arriving before or during the
// hold.
module btb_invalidate_hold_formal #(
    localparam int unsigned XLEN = riscv_pkg::XLEN,
    localparam int unsigned BtbIndexBits = 2,
    localparam int unsigned BankEntries = 1 << (BtbIndexBits - 1)
) (
    input logic            i_clk,
    input logic            i_reset,
    input logic            i_btb_invalidate,
    input logic [XLEN-1:0] i_pc,
    input logic            i_fetch_translation_active,
    input logic            i_btb_update,
    input logic [XLEN-1:0] i_btb_update_pc,
    input logic [XLEN-1:0] i_btb_update_target,
    input logic            i_btb_update_taken,
    input logic            i_btb_update_compressed,
    input logic            i_btb_update_call,
    input logic            i_btb_update_return,
    input logic            i_btb_early_update_active,
    input logic [XLEN-1:0] i_btb_early_update_pc,
    input logic            i_btb_early_update_taken,
    input logic [XLEN-1:0] i_btb_late_update_pc,
    input logic            i_btb_late_update_taken
);
  riscv_pkg::pipeline_ctrl_t pipeline_ctrl;
  riscv_pkg::from_ex_comb_t  from_ex_comb;
  always_comb begin
    pipeline_ctrl = '0;
    pipeline_ctrl.reset = i_reset;
    from_ex_comb = '0;
    from_ex_comb.btb_update = i_btb_update;
    from_ex_comb.btb_update_pc = i_btb_update_pc;
    from_ex_comb.btb_update_target = i_btb_update_target;
    from_ex_comb.btb_update_taken = i_btb_update_taken;
    from_ex_comb.btb_update_compressed = i_btb_update_compressed;
    from_ex_comb.btb_update_call = i_btb_update_call;
    from_ex_comb.btb_update_return = i_btb_update_return;
  end

  if_stage #(
      .XLEN(XLEN)
  ) u_if (
      .i_clk,
      .i_boot_addr('0),
      .i_from_ex_comb(from_ex_comb),
      .i_btb_early_update_active,
      .i_btb_early_update_pc,
      .i_btb_early_update_taken,
      .i_btb_late_update_pc,
      .i_btb_late_update_taken,
      .i_instr('0),
      .i_instr_low_by_parity('0),
      .i_instr_high('0),
      .i_instr_window_high(1'b0),
      .i_instr_sideband('0),
      .i_instr_pc_metadata('0),
      .i_instr_pc_metadata_by_provider_parity('0),
      .i_pc_pairability_by_provider_parity('0),
      .i_slot2_start_valid_lo_by_provider_parity('0),
      .i_instr_pc_metadata_served_high(1'b0),
      .i_instr_bank_sel_r(1'b0),
      .i_served_word_low('0),
      .i_served_last_word_low('0),
      .i_served_prev_word_low('0),
      .i_served_prev_word_valid_low(1'b0),
      .i_served_word_high('0),
      .i_served_last_word_high('0),
      .i_served_prev_word_high('0),
      .i_served_prev_word_valid_high(1'b0),
      .i_instr_valid(1'b0),
      .i_instr_fault0(1'b0),
      .i_instr_fault0_page(1'b0),
      .i_instr_fault1(1'b0),
      .i_instr_fault1_page(1'b0),
      .i_served_high(1'b0),
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_trap_ctrl('0),
      .i_frontend_state_flush(1'b0),
      .i_flush_all(1'b0),
      .i_fence_i_flush(1'b0),
      .i_fence_i_target('0),
      .i_btb_invalidate,
      .i_disable_branch_prediction(1'b0),
      .i_fetch_trap_hold(1'b0),
      .i_dir_update_valid(1'b0),
      .i_dir_update_idx('0),
      .i_dir_update_taken(1'b0),
      .i_pd_redirect(1'b0),
      .i_pd_redirect_taken(1'b0),
      .i_pd_redirect_target('0),
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
      .i_fetch_priv_u(1'b0),
      .i_fetch_asid('0),
      .i_tlb_invalidate(1'b0),
      .i_tlb_flush('0),
      .o_walk_req_valid(),
      .i_walk_req_ready(1'b0),
      .o_walk_vpn(),
      .i_walk_resp_valid(1'b0),
      .i_walk_resp('0),
      .o_from_if_to_pd(),
      .o_from_if_to_pd_2(),
      .o_backing_hit(),
      .o_backing_compressed(),
      .o_backing_return(),
      .o_backing_target(),
      .o_backing_slot2_return_by_size(),
      .o_backing_slot2_target_by_size(),
      .o_slot1_has_control_flow(),
      .o_slot1_is_indirect(),
      .o_width_events(),
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
      .o_tage_hist_restore_arm(),
      .o_tage_fetch_path_bits(),
      .o_tage_slot_valid(),
      .o_tage_slot_lookup(),
      .o_tage_slot_lookup_2(),
      .o_tage_lookup_hist()
  );

  // Instantiate the production fetch_btb_2w at BTB_INDEX_BITS=2 driven by
  // u_if's registered update staging pipe and four-cycle invalidate hold,
  // while also asserting u_if's internal wiring to u_fetch_btb_2w.
  logic btb_taken_small;
  logic btb_w0_hit_small;
  logic btb_w1_hit_small;
  logic [BtbIndexBits-2:0] pc_even_idx_small;
  assign pc_even_idx_small = i_pc[BtbIndexBits+1:3] + (BtbIndexBits - 1)'(i_pc[2]);

  fetch_btb_2w #(
      .XLEN(XLEN),
      .BTB_INDEX_BITS(BtbIndexBits),
      .BIM_BITS(riscv_pkg::BpDirIdxBits)
  ) u_btb (
      .i_clk,
      .i_rst(i_reset),
      .i_pc,
      .i_pc_even_idx(pc_even_idx_small),
      .i_fetch_translation_active,
      .i_pc_is_cached(riscv_pkg::pma_cached_ok(i_pc)),
      .i_ras_nonempty(1'b0),
      .i_ras_top_is_cached(1'b0),
      .i_ras_top('0),
      .i_ras_even_dir_idx('0),
      .o_taken(btb_taken_small),
      .o_taken_steer(),
      .o_taken_pos(),
      .o_target(),
      .o_target_even_dir_idx(),
      .o_compressed(),
      .o_is_call(),
      .o_is_return(),
      .o_is_span(),
      .o_target_is_cached(),
      .o_w0_hit(btb_w0_hit_small),
      .o_w1_hit(btb_w1_hit_small),
      .o_w0_taken(),
      .o_w0_link_inc(),
      .o_w1_link_inc(),
      .o_w0_link_hw(),
      .o_w1_link_hw(),
      .i_update(u_if.btb_update_q),
      .i_update_pc(u_if.btb_update_pc_q),
      .i_update_target(u_if.btb_update_target_q),
      .i_update_taken(u_if.btb_update_taken_q),
      .i_update_compressed(u_if.btb_update_compressed_q),
      .i_update_call(u_if.btb_update_call_q),
      .i_update_return(u_if.btb_update_return_q),
      .i_early_update_active(u_if.btb_early_update_active_q),
      .i_early_update_pc(u_if.btb_early_update_pc_q),
      .i_early_update_taken(u_if.btb_early_update_taken_q),
      .i_late_update_pc(u_if.btb_late_update_pc_q),
      .i_late_update_taken(u_if.btb_late_update_taken_q),
      .i_invalidate_all(u_if.btb_invalidate_active)
  );

  // Track the exact 4-cycle invalidate window from the past 4 non-reset edges.
  // Because the window is a pure function of the last 4 cycles of (i_reset,
  // i_btb_invalidate), both the hold duration and the valid-clear assertions
  // are k-inductive without assumptions.
  logic [3:0] hist_valid_q = 4'b0000;
  logic [2:0] inv_hist_q = 3'b000;
  logic       prev_active_q = 1'b0;
  logic       prev_update_q = 1'b0;
  logic       reset_seen_q = 1'b0;

  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      reset_seen_q  <= 1'b1;
      hist_valid_q  <= 4'b1111;
      inv_hist_q    <= 3'b000;
      prev_active_q <= 1'b0;
      prev_update_q <= 1'b0;
    end else begin
      hist_valid_q  <= {hist_valid_q[2:0], 1'b1};
      inv_hist_q    <= {inv_hist_q[1:0], i_btb_invalidate};
      prev_active_q <= u_if.btb_invalidate_active;
      prev_update_q <= u_if.btb_update_q;
    end
  end

  logic [BankEntries-1:0] valid_bank0;
  logic [BankEntries-1:0] valid_bank1;
  for (genvar i = 0; i < BankEntries; i++) begin : gen_valid_pack
    assign valid_bank0[i] = u_btb.btb_valid[0][i];
    assign valid_bank1[i] = u_btb.btb_valid[1][i];
  end

  logic all_valid_banks_clear;
  assign all_valid_banks_clear = (valid_bank0 == '0) && (valid_bank1 == '0);

  logic [1:0] expected_hold_q;
  assign expected_hold_q =
      inv_hist_q[0] ? 2'd3 :
      inv_hist_q[1] ? 2'd2 :
      inv_hist_q[2] ? 2'd1 : 2'd0;

  logic expected_hold_active;
  assign expected_hold_active = i_btb_invalidate || (expected_hold_q != 2'd0);

  always_ff @(posedge i_clk) begin
    p_if_wires_btb_invalidate_and_update :
    assert ((u_if.u_fetch_btb_2w.i_invalidate_all == u_if.btb_invalidate_active) &&
            (u_if.u_fetch_btb_2w.i_update == u_if.btb_update_q));
    if (!i_reset && (&hist_valid_q)) begin
      p_invalidate_hold_exact :
      assert ((u_if.btb_invalidate_hold_q == expected_hold_q) &&
              (u_if.btb_invalidate_active == expected_hold_active));
    end
    if (!i_reset && hist_valid_q[0] && prev_active_q) begin
      p_invalidate_clears_all_valid_banks : assert (all_valid_banks_clear);
      p_invalidate_blocks_all_btb_hits :
      assert (!btb_w0_hit_small && !btb_w1_hit_small && !btb_taken_small);
    end
    if (reset_seen_q && !i_reset && (&hist_valid_q)) begin
      c_drop_on_pulse :
      cover (prev_active_q && prev_update_q && (inv_hist_q == 3'b001) && all_valid_banks_clear);
      c_drop_on_hold_1 :
      cover (prev_active_q && prev_update_q && (inv_hist_q == 3'b010) && all_valid_banks_clear);
      c_drop_on_hold_2 :
      cover (prev_active_q && prev_update_q && (inv_hist_q == 3'b100) && all_valid_banks_clear);
      c_drop_on_hold_3 :
      cover (prev_active_q && prev_update_q && (inv_hist_q == 3'b000) && !i_btb_invalidate &&
             all_valid_banks_clear);
      c_update_after_hold_installs :
      cover (!prev_active_q && prev_update_q && !expected_hold_active &&
             ((valid_bank0 != '0) || (valid_bank1 != '0)));
    end
  end
endmodule
