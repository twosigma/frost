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

// Over-approximating RAM stubs: tag, payload, direction, and RAS memories
// return arbitrary unconstrained words each cycle, so only the real valid-bit
// flip-flops and staged slot-2 valid registers can keep lookups from hitting.
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

// Proves that branch_prediction_controller holds i_btb_invalidate active for
// exactly four cycles, wires that held clear and the registered update pipe
// directly to branch_predictor, clears every slot-1 and slot-2 valid bit and
// staged slot-2 valid register on each of those cycles, and drops any
// in-flight BTB updates arriving before or during the hold.
module btb_invalidate_hold_formal #(
    localparam int unsigned XLEN = riscv_pkg::XLEN,
    localparam int unsigned BtbIndexBits = 2,
    localparam int unsigned BtbEntries = 1 << BtbIndexBits
) (
    input logic            i_clk,
    input logic            i_reset,
    input logic            i_btb_invalidate,
    input logic [XLEN-1:0] i_pc,
    input logic [XLEN-1:0] i_pc_2_base,
    input logic            i_slot2_plus2_candidate_valid,
    input logic            i_slot2_plus4_candidate_valid,
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
  logic [XLEN-1:0] pc_plus2;
  logic [XLEN-1:0] pc_plus4;
  assign pc_plus2 = i_pc_2_base + riscv_pkg::PcIncrementCompressed;
  assign pc_plus4 = i_pc_2_base + riscv_pkg::PcIncrement32bit;

  branch_prediction_controller u_ctrl (
      .i_clk,
      .i_reset,
      .i_btb_invalidate,
      .i_stall(1'b0),
      .i_stall_registered(1'b0),
      .i_fetch_progress(1'b1),
      .i_flush(1'b0),
      .i_pd_redirect(1'b0),
      .i_pd_redirect_taken(1'b0),
      .i_pd_redirect_target('0),
      .i_pc,
      .i_pc_2(pc_plus2),
      .i_pc_2_alt(pc_plus4),
      .i_pc_2_base,
      .i_lookup_lead_collapsed(1'b0),
      .i_pending_prediction_pc('0),
      .i_pending_prediction_prev_pc('0),
      .i_pending_prediction_prev_native_pc('0),
      .i_slot2_plus2_candidate_valid,
      .i_slot2_plus4_candidate_valid,
      .i_slot2_valid(1'b1),
      .i_slot2_valid_wcs0(1'b1),
      .i_slot2_is_compressed_plus2(1'b1),
      .i_slot2_is_compressed_plus4(1'b0),
      .i_slot2_is_compressed(1'b0),
      .i_trap_taken(1'b0),
      .i_mret_taken(1'b0),
      .i_branch_taken(1'b0),
      .i_any_holdoff_safe(1'b0),
      .i_use_instr_buffer(1'b0),
      .i_disable_branch_prediction(1'b0),
      .i_disable_branch_prediction_wcs0(1'b0),
      .i_disable_branch_prediction_wcs(1'b0),
      .i_window_cannot_serve_raw(1'b0),
      .i_fetch_lookup_is_lower_parcel(1'b0),
      .i_pending_prediction_blocks_slot1(1'b0),
      .i_btb_update,
      .i_btb_update_pc,
      .i_btb_update_target,
      .i_btb_update_taken,
      .i_btb_update_compressed,
      .i_btb_update_call,
      .i_btb_update_return,
      .i_btb_early_update_active,
      .i_btb_early_update_pc,
      .i_btb_early_update_taken,
      .i_btb_late_update_pc,
      .i_btb_late_update_taken,
      .i_dir_update_valid(1'b0),
      .i_dir_update_idx('0),
      .i_dir_update_taken(1'b0),
      .i_ras_push(1'b0),
      .i_ras_pop(1'b0),
      .i_ras_push_address('0),
      .i_ras_misprediction(1'b0),
      .i_ras_restore_tos('0),
      .i_ras_restore_valid_count('0),
      .i_ras_restore_top('0),
      .i_ras_pop_after_restore(1'b0),
      .i_ras_push_after_restore(1'b0),
      .i_ras_push_address_after_restore('0),
      .o_predicted_target(),
      .o_predicted_is_call(),
      .o_predicted_is_return(),
      .o_prediction_used_r(),
      .o_predicted_target_r(),
      .o_predicted_is_call_r(),
      .o_predicted_is_return_r(),
      .o_prediction_used(),
      .o_prediction_used_for_pc(),
      .o_prediction_used_live_cofactor(),
      .o_prediction_holdoff(),
      .o_sel_prediction_r(),
      .o_prediction_requires_pc_reg_handoff(),
      .o_control_flow_to_halfword_pred(),
      .o_slot2_prediction_used(),
      .o_slot2_prediction_used_for_pc(),
      .o_slot2_prediction_used_for_fetch_mux(),
      .o_slot2_staged_prediction_used_for_pc(),
      .o_slot2_staged_prediction_used_for_capture(),
      .o_slot1_aliases_slot2_candidate(),
      .o_slot2_live_target_used_for_pc_cofactor(),
      .o_slot2_live_target_used_for_pc(),
      .o_slot2_staged_pc_without_valid(),
      .o_slot2_live_pc_without_valid(),
      .o_slot2_predicted_taken(),
      .o_slot2_predicted_target(),
      .o_slot2_predicted_target_for_pc(),
      .o_slot2_staged_predicted_target(),
      .o_slot2_live_predicted_target(),
      .o_slot2_predicted_is_call(),
      .o_slot2_predicted_is_return(),
      .o_slot2_staged_target_rel_pending(),
      .o_slot2_live_target_rel_pending(),
      .o_ras_checkpoint_tos(),
      .o_ras_checkpoint_valid_count(),
      .o_ras_checkpoint_top(),
      .o_dir_predicted_taken(),
      .o_dir_predicted_taken_live(),
      .o_dir_predicted_taken_live_cofactor(),
      .o_dir_idx(),
      .o_dir_idx_live(),
      .o_dir_idx_2()
  );

  // Instantiate the production branch_predictor at BTB_INDEX_BITS=2 driven by
  // u_ctrl's registered update staging pipe and four-cycle invalidate hold,
  // while also asserting u_ctrl's internal wiring to branch_predictor_inst.
  logic btb_hit_small;
  logic btb_hit_2_small;
  branch_predictor #(
      .XLEN(XLEN),
      .BTB_INDEX_BITS(BtbIndexBits)
  ) u_btb (
      .i_clk,
      .i_rst(i_reset),
      .i_pc,
      .o_btb_hit(btb_hit_small),
      .o_predicted_taken(),
      .o_predicted_target(),
      .o_btb_compressed(),
      .o_btb_is_call(),
      .o_btb_is_return(),
      .i_pc_2_lookup_base(i_pc),
      .i_pc_2_base,
      .i_pc_2_use_alt(i_slot2_plus4_candidate_valid),
      .o_predicted_taken_2_plus2(),
      .o_predicted_taken_2_plus4(),
      .o_btb_compressed_2_plus2(),
      .o_btb_compressed_2_plus4(),
      .o_btb_hit_2(btb_hit_2_small),
      .o_btb_hit_2_plus2(),
      .o_btb_hit_2_plus4(),
      .o_predicted_taken_2(),
      .o_predicted_target_2(),
      .o_btb_compressed_2(),
      .o_btb_is_call_2(),
      .o_btb_is_return_2(),
      .o_btb_entry_is_return_2(),
      .o_predicted_target_2_plus2(),
      .o_predicted_target_2_plus4(),
      .o_btb_entry_is_return_2_plus2(),
      .o_btb_entry_is_return_2_plus4(),
      .i_pending_prediction_pc('0),
      .i_pending_prediction_prev_pc('0),
      .i_pending_prediction_prev_native_pc('0),
      .o_slot2_plus2_covered_rel_pending(),
      .o_slot2_plus2_zero_rel_pending(),
      .o_slot2_plus4_rel_pending(),
      .i_update(u_ctrl.btb_update_q),
      .i_update_pc(u_ctrl.btb_update_pc_q),
      .i_update_target(u_ctrl.btb_update_target_q),
      .i_update_taken(u_ctrl.btb_update_taken_q),
      .i_update_compressed(u_ctrl.btb_update_compressed_q),
      .i_update_call(u_ctrl.btb_update_call_q),
      .i_update_return(u_ctrl.btb_update_return_q),
      .i_early_update_active(u_ctrl.btb_early_update_active_q),
      .i_early_update_pc(u_ctrl.btb_early_update_pc_q),
      .i_early_update_taken(u_ctrl.btb_early_update_taken_q),
      .i_late_update_pc(u_ctrl.btb_late_update_pc_q),
      .i_late_update_taken(u_ctrl.btb_late_update_taken_q),
      .i_invalidate_all(u_ctrl.btb_invalidate_active)
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
      prev_active_q <= u_ctrl.btb_invalidate_active;
      prev_update_q <= u_ctrl.btb_update_q;
    end
  end

  logic [BtbEntries-1:0] valid_s1;
  logic [BtbEntries-1:0] valid_s2;
  logic [BtbEntries-1:0] valid_s2_alt;
  logic [BtbEntries-1:0] valid_s2_rot;
  for (genvar i = 0; i < BtbEntries; i++) begin : gen_valid_pack
    assign valid_s1[i]     = u_btb.btb_valid[i];
    assign valid_s2[i]     = u_btb.btb_valid_2[i];
    assign valid_s2_alt[i] = u_btb.btb_valid_2_alt[i];
    assign valid_s2_rot[i] = u_btb.btb_valid_2_rot[i];
  end

  logic all_valid_arrays_clear;
  assign all_valid_arrays_clear =
      (valid_s1 == '0) && (valid_s2 == '0) && (valid_s2_alt == '0) && (valid_s2_rot == '0);

  logic staged_slot2_valids_clear;
  assign staged_slot2_valids_clear =
      !u_btb.slot2_valid_2_q &&
      !u_btb.slot2_valid_2_alt_q &&
      !u_btb.slot2_valid_2_rot_q;

  logic [1:0] expected_hold_q;
  assign expected_hold_q =
      inv_hist_q[0] ? 2'd3 :
      inv_hist_q[1] ? 2'd2 :
      inv_hist_q[2] ? 2'd1 : 2'd0;

  logic expected_hold_active;
  assign expected_hold_active = i_btb_invalidate || (expected_hold_q != 2'd0);

  always_ff @(posedge i_clk) begin
    p_controller_wires_btb_invalidate_and_update :
    assert ((u_ctrl.branch_predictor_inst.i_invalidate_all == u_ctrl.btb_invalidate_active) &&
            (u_ctrl.branch_predictor_inst.i_update == u_ctrl.btb_update_q));
    if (!i_reset && (&hist_valid_q)) begin
      p_invalidate_hold_exact :
      assert ((u_ctrl.btb_invalidate_hold_q == expected_hold_q) &&
              (u_ctrl.btb_invalidate_active == expected_hold_active));
    end
    if (!i_reset && hist_valid_q[0] && prev_active_q) begin
      p_invalidate_clears_all_valid_arrays : assert (all_valid_arrays_clear);
      p_invalidate_clears_staged_slot2_valids : assert (staged_slot2_valids_clear);
      p_invalidate_blocks_all_btb_hits : assert (!btb_hit_small && !btb_hit_2_small);
    end
    if (reset_seen_q && !i_reset && (&hist_valid_q)) begin
      c_drop_on_pulse :
      cover (prev_active_q && prev_update_q && (inv_hist_q == 3'b001) && all_valid_arrays_clear);
      c_drop_on_hold_1 :
      cover (prev_active_q && prev_update_q && (inv_hist_q == 3'b010) && all_valid_arrays_clear);
      c_drop_on_hold_2 :
      cover (prev_active_q && prev_update_q && (inv_hist_q == 3'b100) && all_valid_arrays_clear);
      c_drop_on_hold_3 :
      cover (prev_active_q && prev_update_q && (inv_hist_q == 3'b000) && !i_btb_invalidate &&
             all_valid_arrays_clear);
      c_update_after_hold_installs :
      cover (!prev_active_q && prev_update_q && !expected_hold_active && (valid_s1 != '0));
    end
  end
endmodule
