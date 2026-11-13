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
  The vector register file as a standalone block: DEPTH entries of WIDTH bits
  (one element group each, so DEPTH = registers x VLEN / WIDTH), NR read ports
  and NW write ports, each write with a byte enable per byte. Reads are
  registered: a read address taken on an edge returns the entry as it was
  before any write on that edge. When two write ports write the same byte of
  the same entry on one edge, the higher-numbered port wins.

  Every (write port, read port) pair has its own copy of the storage, written
  only by its write port, and a live-value table holds, for every byte of
  every entry, which write port wrote it last; each read port selects each
  byte from the copy that table names. With NW = 1 the table is left out.
*/
module vec_vrf #(
    parameter int unsigned DEPTH = 32,
    parameter int unsigned WIDTH = 256,
    parameter int unsigned NR = 4,
    parameter int unsigned NW = 2,
    localparam int unsigned AddrBits = $clog2(DEPTH),
    localparam int unsigned Bytes = WIDTH / 8,
    localparam int unsigned PortBits = (NW > 1) ? $clog2(NW) : 1
) (
    input  logic                        i_clk,
    input  logic [NW-1:0]               i_we,
    input  logic [NW-1:0][AddrBits-1:0] i_waddr,
    input  logic [NW-1:0][   WIDTH-1:0] i_wdata,
    input  logic [NW-1:0][   Bytes-1:0] i_wbe,
    input  logic [NR-1:0][AddrBits-1:0] i_raddr,
    output logic [NR-1:0][   WIDTH-1:0] o_rdata
);

  // Storage copies: copy (w, r) holds what write port w wrote, for read port r.
  logic [NW-1:0][NR-1:0][WIDTH-1:0] copy_q;
  for (genvar w = 0; w < NW; w++) begin : gen_w
    for (genvar r = 0; r < NR; r++) begin : gen_r
      logic [WIDTH-1:0] mem[DEPTH];
      logic [WIDTH-1:0] q;
      always_ff @(posedge i_clk) begin
        for (int b = 0; b < int'(Bytes); b++)
        if (i_we[w] && i_wbe[w][b]) mem[i_waddr[w]][8*b+:8] <= i_wdata[w][8*b+:8];
        q <= mem[i_raddr[r]];
      end
      assign copy_q[w][r] = q;
    end
  end

  // The last writer of every byte of every entry, and its registered read
  // (used only with NW > 1).
  logic [Bytes*PortBits-1:0] lvt[DEPTH];
  logic [NR-1:0][Bytes*PortBits-1:0] sel_q;
  if (NW > 1) begin : gen_lvt
    always_ff @(posedge i_clk) begin
      for (int w = 0; w < int'(NW); w++)
      for (int b = 0; b < int'(Bytes); b++)
      if (i_we[w] && i_wbe[w][b]) lvt[i_waddr[w]][PortBits*b+:PortBits] <= PortBits'(w);
      for (int r = 0; r < int'(NR); r++) sel_q[r] <= lvt[i_raddr[r]];
    end
    always_comb begin
      for (int r = 0; r < int'(NR); r++)
      for (int b = 0; b < int'(Bytes); b++)
      o_rdata[r][8*b+:8] = copy_q[sel_q[r][PortBits*b+:PortBits]][r][8*b+:8];
    end
  end else begin : gen_single
    always_comb for (int r = 0; r < int'(NR); r++) o_rdata[r] = copy_q[0][r];
  end

endmodule
