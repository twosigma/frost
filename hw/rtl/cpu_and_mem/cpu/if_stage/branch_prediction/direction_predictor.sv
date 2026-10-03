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
 * Bimodal direction predictor: 2-bit saturating counters indexed by fetch PC
 * bits [BIM_BITS:1]. Its only consumer is the PD redirect (carried to PD as
 * bp_dir_taken): when a slot-1 conditional branch reaches PD without a taken
 * BTB prediction (a BTB miss or a not-taken hit) and this predicts taken, PD
 * computes PC + offset and redirects fetch. A taken BTB prediction supplies
 * its own target and direction.
 *
 * Training writes the entry at i_update_idx. IF normally carries the
 * predict-time index (o_pred_idx) with the branch to commit, so training
 * updates the entry the prediction read; the branch's own PC would name the
 * wrong entry when the fetch PC that read the predictor differs from it, after
 * a stall replay or at a halfword boundary. For a slot-2 branch, the owner of
 * a pending prediction, and a high-half served-window retry, IF carries the
 * index of the branch's own PC instead. PC[1] is part of the index, so
 * halfword addresses get their own entries.
 *
 * Lookups are combinational and updates synchronous. The predict and
 * update-read ports are separate RAM copies sharing one write, since
 * sdp_dist_ram has one read port. The counters start at 00 (strongly
 * not-taken) from RAM initialization; reset does not clear them.
 */
module direction_predictor #(
    parameter int unsigned XLEN     = riscv_pkg::XLEN,
    parameter int unsigned BIM_BITS = 10                // bimodal index bits (1024 entries)
) (
    input logic i_clk,
    input logic i_rst,

    // Slot-1 lookup (live fetch PC)
    input  logic [    XLEN-1:0] i_pc,
    output logic                o_taken,
    output logic [BIM_BITS-1:0] o_pred_idx, // predict-time index (carry for training)

    // Commit-time training: at most one committed conditional branch per cycle,
    // at the predict-time index it carried from fetch.
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

  // i_rst is unused; it is kept for a uniform interface.
  wire _unused = &{1'b0, i_rst};

endmodule : direction_predictor
