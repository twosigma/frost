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
 * Four-bank bimodal direction predictor: 1024 two-bit saturating counters
 * split into four banks by PC[2:1], returning direction predictions for all
 * four halfwords of a 64-bit fetch window {W+1:hi, W+1:lo, W:hi, W:lo} in a
 * single combinational lookup.
 *
 * Even-word banks (PC[2]=0) read the caller's precomputed row index
 * i_pc_even_dir_idx; odd-word banks (PC[2]=1) read i_pc[BIM_BITS:3]. Commit
 * training writes one bank per cycle at i_update_idx. As in
 * direction_predictor, reset does not clear the counter RAMs.
 */
module fetch_dir_4b #(
    parameter int unsigned XLEN     = riscv_pkg::XLEN,
    parameter int unsigned BIM_BITS = riscv_pkg::BpDirIdxBits  // 10 -> 1024 entries (4 x 256)
) (
    input logic i_clk,
    input logic i_rst,

    // F0 lookup covering words W and W+1
    input logic [XLEN-1:0] i_pc,
    // Precomputed even-word row index: i_pc[BIM_BITS:3] + i_pc[2].
    input logic [BIM_BITS-3:0] i_pc_even_dir_idx,
    // Direction predictions in window halfword order:
    //   [0]=W:lo, [1]=W:hi, [2]=W+1:lo, [3]=W+1:hi
    output logic [3:0] o_taken,

    // Commit-time training (conditional branches)
    input logic                i_update_valid,
    input logic [BIM_BITS-1:0] i_update_idx,
    input logic                i_update_taken
);

  localparam int unsigned BankAddrBits = BIM_BITS - 2;

  function automatic logic [1:0] sat_update(input logic [1:0] c, input logic taken);
    if (taken) sat_update = (c == 2'b11) ? 2'b11 : (c + 2'b01);
    else sat_update = (c == 2'b00) ? 2'b00 : (c - 2'b01);
  endfunction

  logic [1:0] upd_bank;
  logic [BankAddrBits-1:0] upd_row;
  assign upd_bank = i_update_idx[1:0];
  assign upd_row  = i_update_idx[BIM_BITS-1:2];

  logic [BankAddrBits-1:0] odd_row;
  assign odd_row = i_pc[BIM_BITS:3];

  logic [1:0] bank_rd_pred[4];
  logic [1:0] bank_rd_upd [4];

  for (genvar b = 0; b < 4; b++) begin : gen_bank
    logic [BankAddrBits-1:0] pred_row;
    logic bank_we;
    logic [1:0] bank_next;

    // Banks 0,1 are even word (PC[2]=0); banks 2,3 are odd word (PC[2]=1).
    assign pred_row  = (b < 2) ? i_pc_even_dir_idx : odd_row;
    assign bank_we   = i_update_valid && (upd_bank == 2'(b));
    assign bank_next = sat_update(bank_rd_upd[b], i_update_taken);

    sdp_dist_ram #(
        .ADDR_WIDTH(BankAddrBits),
        .DATA_WIDTH(2)
    ) u_pred_ram (
        .i_clk,
        .i_write_enable(bank_we),
        .i_write_address(upd_row),
        .i_write_data(bank_next),
        .i_read_address(pred_row),
        .o_read_data(bank_rd_pred[b])
    );

    sdp_dist_ram #(
        .ADDR_WIDTH(BankAddrBits),
        .DATA_WIDTH(2)
    ) u_upd_ram (
        .i_clk,
        .i_write_enable(bank_we),
        .i_write_address(upd_row),
        .i_write_data(bank_next),
        .i_read_address(upd_row),
        .o_read_data(bank_rd_upd[b])
    );
  end

  // Order banks into {W+1:hi, W+1:lo, W:hi, W:lo} by W's parity i_pc[2].
  assign o_taken = i_pc[2] ?
      {bank_rd_pred[1][1], bank_rd_pred[0][1], bank_rd_pred[3][1], bank_rd_pred[2][1]} :
      {bank_rd_pred[3][1], bank_rd_pred[2][1], bank_rd_pred[1][1], bank_rd_pred[0][1]};

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) reset_seen_q <= 1'b1;
    if (reset_seen_q && !i_rst && !$isunknown({i_pc, i_pc_even_dir_idx})) begin
      p_even_dir_idx_matches_pc :
      assert (i_pc_even_dir_idx == (i_pc[BIM_BITS:3] + BankAddrBits'(i_pc[2])));
    end
  end
`endif

  wire _unused = &{1'b0, i_rst, i_pc[XLEN-1:BIM_BITS+1], i_pc[1:0]};

endmodule : fetch_dir_4b
