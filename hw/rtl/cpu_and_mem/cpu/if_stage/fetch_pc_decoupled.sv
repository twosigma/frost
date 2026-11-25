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
 * Decoupled F0 fetch PC controller.
 *
 * Drives the live fetch PC (o_pc), dedicated predictor lookup copies
 * (o_pc_tage_lookup, o_pc_even_btb_idx, o_pc_even_dir_idx), tagged path-history
 * events, and registered provider retarget pulses.
 *
 * Next-PC priority keeps the same arm positions as pc_controller so testbench
 * and RVFI observers see uniform redirect encodings:
 *   arm 1: trap or xRET
 *   arm 2: FENCE-class flush
 *   arm 3: execute misprediction recovery
 *   arm 4: PD redirect
 *   arm 5: F1 validation resteer (false BTB hit or served-word mismatch)
 *   arm 6: keep PC when neither F0 launch nor collapsed accept fires
 *   arm 7: spanning-branch BTB target completion
 *   arm 8: F0 fast-BTB taken prediction
 *   arm 13: sequential next 64-bit window ({o_pc[XLEN-1:2] + 2, 2'b00})
 *
 * Reset loads o_pc from i_boot_addr at the flop only.
 */
module fetch_pc_decoupled #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned BTB_INDEX_BITS = 8,
    parameter int unsigned BIM_BITS = riscv_pkg::BpDirIdxBits
) (
    input logic i_clk,
    input logic [XLEN-1:0] i_boot_addr = '0,
    input logic i_reset,

    // Redirects (highest priority first, matching pc_controller arms 1..5)
    input logic            i_trap_taken,
    input logic            i_mret_taken,
    input logic [XLEN-1:0] i_trap_target,

    input logic            i_fence_i_flush,
    input logic [XLEN-1:0] i_fence_i_target,

    input logic            i_branch_taken,
    input logic [XLEN-1:0] i_branch_target,

    input logic            i_pd_redirect,
    input logic [XLEN-1:0] i_pd_redirect_target,

    // Combined redirect or flush gate suppressing F0/F1 arms when arms 1..4 are inactive
    input logic i_any_redirect,

    // Redirect-free F1 resteer and F0/collapsed launch qualifiers
    input logic            i_f1_resteer,
    input logic [XLEN-1:0] i_f1_resteer_target,

    input logic i_f0_launch,
    input logic i_f1_collapsed_accept,

    // F0 and collapsed-lead predicted-taken arms (with precomputed even dir indices)
    input logic                i_span_btb_fire,
    input logic [    XLEN-1:0] i_span_btb_target,
    input logic [BIM_BITS-3:0] i_span_btb_even_dir_idx,
    input logic                i_collapsed_btb_taken,
    input logic [    XLEN-1:0] i_collapsed_btb_target,
    input logic [BIM_BITS-3:0] i_collapsed_btb_even_dir_idx,
    input logic                i_btb_taken,
    input logic [    XLEN-1:0] i_btb_target,
    input logic [BIM_BITS-3:0] i_btb_even_dir_idx,

    // Registered fetch PC and dedicated lookup address copies
    output logic [XLEN-1:0] o_pc,
    output logic [riscv_pkg::TageLookupHiBit:2] o_pc_tage_lookup,
    output logic [BTB_INDEX_BITS-2:0] o_pc_even_btb_idx,
    output logic [BIM_BITS-3:0] o_pc_even_dir_idx,

    // Combinational next-PC and self-loop indicator
    output logic [XLEN-1:0] o_next_pc,
    output logic            o_pc_update_en,
    output logic            o_f0_self_loop,

    // Registered path-history events for tage_history
    output logic       o_tage_hist_push,
    output logic [4:1] o_tage_hist_restore_arm,

    // Registered provider retarget pulses (set after arms 1..5)
    output logic o_fetch_redirect,
    output logic o_fetch_cached_retarget,

    // Observation arms matching pc_controller's encoding
    output logic [riscv_pkg::PcNextArms-1:0] o_npc_sel,
    output logic [riscv_pkg::PcNextArms-1:0][XLEN-1:0] o_npc_val
);

  localparam int unsigned NPcArms = riscv_pkg::PcNextArms;
  localparam int unsigned EvenBtbBits = BTB_INDEX_BITS - 1;
  localparam int unsigned EvenDirBits = BIM_BITS - 2;

  logic [XLEN-1:0] pc_q;
  logic [riscv_pkg::TageLookupHiBit:2] pc_tage_lookup_q;
  (* keep = "true", max_fanout = 48 *) logic [EvenBtbBits-1:0] pc_even_btb_idx_q;
  logic [EvenDirBits-1:0] pc_even_dir_idx_q;

  logic [XLEN-1:0] seq_next_pc;
  assign seq_next_pc = {pc_q[XLEN-1:2] + (XLEN - 2)'(2), 2'b00};

  logic trap_or_mret;
  assign trap_or_mret = i_trap_taken || i_mret_taken;

  logic f0_step_raw;
  logic f1_resteer_qual;
  logic f0_step_qual;
  assign f0_step_raw     = i_f0_launch || i_f1_collapsed_accept;
  assign f1_resteer_qual = !i_any_redirect && i_f1_resteer;
  assign f0_step_qual    = !i_any_redirect && !i_f1_resteer && f0_step_raw;

  // Keep internal signal names npc_sel, pc_update_en, and npc_val aligned
  // with RVFI and testbench hierarchical probes.
  logic [NPcArms-1:0] npc_cond;
  logic [NPcArms-1:0] npc_sel;
  logic [XLEN-1:0] npc_val[NPcArms];
  logic pc_update_en;
  logic [XLEN-1:0] next_pc;

  always_comb begin
    npc_cond     = '0;
    npc_cond[1]  = trap_or_mret;
    npc_cond[2]  = i_fence_i_flush;
    npc_cond[3]  = i_branch_taken;
    npc_cond[4]  = i_pd_redirect;
    npc_cond[5]  = f1_resteer_qual;
    npc_cond[6]  = !f0_step_qual;
    npc_cond[7]  = f0_step_qual && i_span_btb_fire;
    npc_cond[8]  = f0_step_qual && (i_f1_collapsed_accept ? i_collapsed_btb_taken : i_btb_taken);
    npc_cond[13] = 1'b1;

    for (int unsigned k = 0; k < NPcArms; k++) npc_val[k] = pc_q;
    npc_val[0]  = i_boot_addr;
    npc_val[1]  = i_trap_target;
    npc_val[2]  = i_fence_i_target;
    npc_val[3]  = i_branch_target;
    npc_val[4]  = i_pd_redirect_target;
    npc_val[5]  = i_f1_resteer_target;
    npc_val[6]  = pc_q;
    npc_val[7]  = i_span_btb_target;
    npc_val[8]  = i_f1_collapsed_accept ? i_collapsed_btb_target : i_btb_target;
    npc_val[13] = seq_next_pc;

    npc_sel = '0;
    for (int unsigned k = 0; k < NPcArms; k++) begin
      npc_sel[k] = npc_cond[k] && !(|(npc_cond & ((NPcArms'(1) << k) - NPcArms'(1))));
    end
  end

  assign pc_update_en = (|npc_cond[4:1]) || f1_resteer_qual || f0_step_qual;

  // Precompute per-arm even direction/BTB indices before the final PC mux so
  // no +next_pc[2] adder sits in series behind the priority select.
  function automatic logic [EvenDirBits-1:0] calc_even_dir(input logic [XLEN-1:0] addr);
    calc_even_dir = addr[BIM_BITS:3] + EvenDirBits'(addr[2]);
  endfunction

  logic [EvenDirBits-1:0] arm1_dir;
  logic [EvenDirBits-1:0] arm2_dir;
  logic [EvenDirBits-1:0] arm3_dir;
  logic [EvenDirBits-1:0] arm4_dir;
  logic [EvenDirBits-1:0] arm5_dir;
  logic [EvenDirBits-1:0] arm13_dir;
  assign arm1_dir  = calc_even_dir(i_trap_target);
  assign arm2_dir  = calc_even_dir(i_fence_i_target);
  assign arm3_dir  = calc_even_dir(i_branch_target);
  assign arm4_dir  = calc_even_dir(i_pd_redirect_target);
  assign arm5_dir  = calc_even_dir(i_f1_resteer_target);
  // seq_next_pc adds 8 bytes (bit 3 += 1, bit 2 unchanged).
  assign arm13_dir = pc_even_dir_idx_q + EvenDirBits'(1);

  // Resolve every non-BTB arm (redirects, F1 resteer, spanning target,
  // collapsed-lead target, and sequential next window) in parallel with the
  // live F0 BTB lookup so only one 2:1 mux sits after i_btb_target.
  logic [XLEN-1:0] early_next_pc_comb;
  logic [EvenDirBits-1:0] early_even_dir_comb;
  always_comb begin
    if (trap_or_mret) begin
      early_next_pc_comb  = i_trap_target;
      early_even_dir_comb = arm1_dir;
    end else if (i_fence_i_flush) begin
      early_next_pc_comb  = i_fence_i_target;
      early_even_dir_comb = arm2_dir;
    end else if (i_branch_taken) begin
      early_next_pc_comb  = i_branch_target;
      early_even_dir_comb = arm3_dir;
    end else if (i_pd_redirect) begin
      early_next_pc_comb  = i_pd_redirect_target;
      early_even_dir_comb = arm4_dir;
    end else if (i_f1_resteer) begin
      early_next_pc_comb  = i_f1_resteer_target;
      early_even_dir_comb = arm5_dir;
    end else if (i_span_btb_fire) begin
      early_next_pc_comb  = i_span_btb_target;
      early_even_dir_comb = i_span_btb_even_dir_idx;
    end else if (i_f1_collapsed_accept && i_collapsed_btb_taken) begin
      early_next_pc_comb  = i_collapsed_btb_target;
      early_even_dir_comb = i_collapsed_btb_even_dir_idx;
    end else begin
      early_next_pc_comb  = seq_next_pc;
      early_even_dir_comb = arm13_dir;
    end
  end

  (* keep = "true" *) logic [XLEN-1:0] early_next_pc;
  (* keep = "true" *) logic [EvenDirBits-1:0] early_even_dir;
  assign early_next_pc  = early_next_pc_comb;
  assign early_even_dir = early_even_dir_comb;

  logic use_f0_btb;
  assign use_f0_btb = !i_any_redirect && !i_f1_resteer && !i_f1_collapsed_accept &&
                      !i_span_btb_fire && i_btb_taken;

  logic [XLEN-1:0] next_pc_load;
  logic [EvenDirBits-1:0] next_even_dir_idx;
  assign next_pc_load      = use_f0_btb ? i_btb_target : early_next_pc;
  assign next_even_dir_idx = use_f0_btb ? i_btb_even_dir_idx : early_even_dir;

  assign next_pc = pc_update_en ? next_pc_load : pc_q;

  logic [EvenBtbBits-1:0] next_even_btb_idx;
  generate
    if (EvenBtbBits <= EvenDirBits) begin : gen_btb_slice
      assign next_even_btb_idx = next_even_dir_idx[EvenBtbBits-1:0];
    end else begin : gen_btb_calc
      assign next_even_btb_idx =
          next_pc_load[BTB_INDEX_BITS+1:3] + EvenBtbBits'(next_pc_load[2]);
    end
  endgenerate

  logic [EvenBtbBits-1:0] boot_even_btb_idx;
  logic [EvenDirBits-1:0] boot_even_dir_idx;
  assign boot_even_btb_idx = i_boot_addr[BTB_INDEX_BITS+1:3] + EvenBtbBits'(i_boot_addr[2]);
  assign boot_even_dir_idx = i_boot_addr[BIM_BITS:3] + EvenDirBits'(i_boot_addr[2]);

  always_ff @(posedge i_clk) begin
    if (i_reset) begin
      pc_q                    <= i_boot_addr;
      pc_tage_lookup_q        <= i_boot_addr[riscv_pkg::TageLookupHiBit:2];
      pc_even_btb_idx_q       <= boot_even_btb_idx;
      pc_even_dir_idx_q       <= boot_even_dir_idx;
      o_tage_hist_push        <= 1'b0;
      o_tage_hist_restore_arm <= '0;
      o_fetch_redirect        <= 1'b0;
      o_fetch_cached_retarget <= 1'b0;
    end else begin
      if (pc_update_en) begin
        pc_q              <= next_pc_load;
        pc_tage_lookup_q  <= next_pc_load[riscv_pkg::TageLookupHiBit:2];
        pc_even_btb_idx_q <= next_even_btb_idx;
        pc_even_dir_idx_q <= next_even_dir_idx;
      end
      o_tage_hist_push        <= pc_update_en && (npc_sel[7] || npc_sel[8]);
      o_tage_hist_restore_arm <= {4{pc_update_en}} & npc_sel[4:1];
      o_fetch_redirect        <= |npc_sel[5:1];
      o_fetch_cached_retarget <= |npc_sel[5:1];
    end
  end

  assign o_pc              = pc_q;
  assign o_pc_tage_lookup  = pc_tage_lookup_q;
  assign o_pc_even_btb_idx = pc_even_btb_idx_q;
  assign o_pc_even_dir_idx = pc_even_dir_idx_q;
  assign o_next_pc         = next_pc;
  assign o_pc_update_en    = pc_update_en;
  assign o_f0_self_loop    = f0_step_qual &&
                             (npc_sel[7] || npc_sel[8]) && (next_pc_load == pc_q);
  assign o_npc_sel         = npc_sel;
  always_comb begin
    for (int unsigned k = 0; k < NPcArms; k++) o_npc_val[k] = npc_val[k];
  end

endmodule : fetch_pc_decoupled
