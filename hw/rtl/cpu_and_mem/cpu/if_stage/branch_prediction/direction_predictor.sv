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
 * Direction Predictor - PC-indexed bimodal (2-bit saturating counters).
 *
 * Supplies a taken/not-taken DIRECTION prediction that is decoupled from the
 * 256-entry BTB, so that a conditional branch which MISSES the BTB still has a
 * trained direction to act on.  Its only consumer is the PD computed-target
 * redirect (carried to PD as bp_dir_taken): when a conditional branch misses the
 * BTB and this predicts taken, PD computes PC+imm and redirects instead of
 * stalling to an EX-stage misprediction.  The BTB still supplies both the target
 * and the direction for branches that HIT it.
 *
 * Why bimodal (not gshare/tournament): a correlating gshare + chooser variant was
 * implemented and measured on CoreMark.  Decoupling direction from the BTB is what
 * matters here; gshare added only ~1% over plain bimodal for this redirect use,
 * not worth its global-history register, extra RAM, and fetch->commit carry
 * plumbing.  See BRANCH_PREDICTION_FINDINGS.md.
 *
 * Indexing: the prediction reads bim_idx(i_pc) = i_pc[BIM_BITS:1] at fetch.
 * Training must update the SAME entry the prediction read, so the predict-time
 * index is carried with the branch through the pipeline and handed back at commit
 * as i_update_idx.  (Training from the commit PC instead would misalign the ~5% of
 * branches whose predict-time fetch PC differs from the commit PC -- front-end
 * stall/replay/halfword edge cases -- costing ~2.7% CoreMark.)  PC[0] dropped
 * (>=2-byte aligned); PC[1] kept to distinguish halfword (compressed) addresses.
 * Training fires only for committed conditional branches.  Lookups combinational;
 * update synchronous.  Two read ports (predict, update-read) are separate RAM
 * copies sharing one write, since sdp_dist_ram is 1R1W.  RAMs zero-initialize
 * (counters start weakly-NT).
 */
module direction_predictor #(
    parameter int unsigned XLEN     = 32,
    parameter int unsigned BIM_BITS = 10   // bimodal index bits (1024 entries)
) (
    input logic i_clk,
    input logic i_rst,

    // Slot-1 lookup (live fetch PC)
    input  logic [    XLEN-1:0] i_pc,
    output logic                o_taken,
    output logic [BIM_BITS-1:0] o_pred_idx, // predict-time index (carry for training)

    // Commit-time training (one committed CONDITIONAL branch per assert).
    // i_update_idx is the predict-time index this branch carried from fetch, so
    // the entry trained is exactly the entry the prediction read.
    input logic                i_update_valid,
    input logic [BIM_BITS-1:0] i_update_idx,
    input logic                i_update_taken
);

  function automatic logic [BIM_BITS-1:0] bim_idx(input logic [XLEN-1:0] pc);
    bim_idx = pc[BIM_BITS:1];
  endfunction

  function automatic logic [1:0] sat_update(input logic [1:0] c, input logic taken);
    if (taken) sat_update = (c == 2'b11) ? 2'b11 : c + 2'b01;
    else sat_update = (c == 2'b00) ? 2'b00 : c - 2'b01;
  endfunction

  wire [BIM_BITS-1:0] bim_i1 = bim_idx(i_pc);
  assign o_pred_idx = bim_i1;

  // Update (read-modify-write) at the carried predict-time index.
  wire [BIM_BITS-1:0] bim_iu = i_update_idx;

  logic [1:0] bim_rd1;  // predict-side read
  logic [1:0] bim_rd_u;  // update-side read (for read-modify-write)
  logic [1:0] bim_next;
  assign bim_next = sat_update(bim_rd_u, i_update_taken);

  // Predict-read copy
  sdp_dist_ram #(
      .ADDR_WIDTH(BIM_BITS),
      .DATA_WIDTH(2)
  ) bim_ram_l1 (
      .i_clk,
      .i_write_enable(i_update_valid),
      .i_write_address(bim_iu),
      .i_write_data(bim_next),
      .i_read_address(bim_i1),
      .o_read_data(bim_rd1)
  );
  // Update-read copy (same contents, separate read port for the RMW)
  sdp_dist_ram #(
      .ADDR_WIDTH(BIM_BITS),
      .DATA_WIDTH(2)
  ) bim_ram_u (
      .i_clk,
      .i_write_enable(i_update_valid),
      .i_write_address(bim_iu),
      .i_write_data(bim_next),
      .i_read_address(bim_iu),
      .o_read_data(bim_rd_u)
  );

  assign o_taken = bim_rd1[1];

  // i_rst retained for interface uniformity; the distributed-RAM counters
  // zero-initialize, so no explicit reset is needed.
  wire _unused = &{1'b0, i_rst};

endmodule : direction_predictor
