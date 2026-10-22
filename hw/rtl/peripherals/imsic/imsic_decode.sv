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

// Decode naturally aligned word stores into registered per-hart MSI ingress.
// A level bit of zero selects the machine file; one selects the supervisor file.
module imsic_decode #(
    parameter int unsigned NUM_HARTS = 1,
    parameter int unsigned NUM_IDS = 63,
    parameter logic [31:0] M_BASE_ADDR = 32'h4800_0000,
    parameter logic [31:0] S_BASE_ADDR = 32'h4810_0000
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_wr_en,
    input logic [31:0] i_wr_addr,
    input logic [31:0] i_wr_data,
    output logic [NUM_HARTS-1:0] o_msi_valid,
    output logic [NUM_HARTS-1:0] o_msi_level,
    output logic [10:0] o_msi_id
);
  localparam int unsigned HartBits = (NUM_HARTS > 1) ? $clog2(NUM_HARTS) : 0;
  // A region holds 2^HartBits pages; its address bits above RegionShift
  // match its base.
  localparam int unsigned RegionShift = 12 + HartBits;
  localparam logic [19:0] PageMask = 20'((1 << HartBits) - 1);

`ifndef SYNTHESIS
  initial begin
    if (NUM_HARTS < 1 || NUM_HARTS > 4096) $fatal(1, "imsic: NUM_HARTS must be 1 to 4096");
    if (((M_BASE_ADDR & 32'((1 << RegionShift) - 1)) != 0) ||
        ((S_BASE_ADDR & 32'((1 << RegionShift) - 1)) != 0))
      $fatal(1, "imsic: M_BASE_ADDR and S_BASE_ADDR must be aligned to their region size");
    if ((M_BASE_ADDR >> RegionShift) == (S_BASE_ADDR >> RegionShift))
      $fatal(1, "imsic: the machine-level and supervisor-level regions overlap");
  end
`endif

  // ---------------------------------------------------------------------------
  // MSI decode: the region, the hart's page, the register, and the identity.
  // ---------------------------------------------------------------------------
  logic wr_m, wr_s, wr_le, wr_be, wr_valid;
  logic [19:0] wr_page;
  logic [31:0] wr_value;
  assign wr_m = i_wr_en && ((i_wr_addr >> RegionShift) == (M_BASE_ADDR >> RegionShift));
  assign wr_s = i_wr_en && ((i_wr_addr >> RegionShift) == (S_BASE_ADDR >> RegionShift));
  assign wr_page = i_wr_addr[31:12] & PageMask;
  assign wr_le = (i_wr_addr[11:2] == 10'h000);
  assign wr_be = (i_wr_addr[11:2] == 10'h001);
  // seteipnum_be holds its identity in big-endian byte order.
  assign wr_value = wr_be ?
      {i_wr_data[7:0], i_wr_data[15:8], i_wr_data[23:16], i_wr_data[31:24]} : i_wr_data;
  assign wr_valid = (wr_le || wr_be) && (wr_value != '0) && (wr_value <= 32'(NUM_IDS));

  // Accesses are whole words, so the byte offset inside the word is unused.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0] byte_offset_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign byte_offset_unused = i_wr_addr[1:0];

  // One registered MSI per cycle: a valid bit per file and the identity.
  logic [NUM_HARTS-1:0] msi_m, msi_s;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      msi_m <= '0;
      msi_s <= '0;
    end else begin
      for (int h = 0; h < int'(NUM_HARTS); h++) begin
        msi_m[h] <= wr_m && wr_valid && (wr_page == 20'(h));
        msi_s[h] <= wr_s && wr_valid && (wr_page == 20'(h));
      end
    end
    o_msi_id <= wr_value[10:0];
  end

  assign o_msi_valid = msi_m | msi_s;
  assign o_msi_level = msi_s;

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // Formal properties of the decode (formal/imsic.sby); the files check their
  // own. Reset is held in the first cycle; inputs are arbitrary afterwards.
  // The page addresses are written from the spec's formula, base + 0x1000 *
  // hart, apart from the decode above.
  // ---------------------------------------------------------------------------
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;
  always_comb if (!f_past_valid) assume (i_rst);

  logic f_rst_p, f_wr_en_p;
  logic [31:0] f_wr_addr_p, f_wr_data_p;
  always_ff @(posedge i_clk) begin
    f_rst_p <= i_rst;
    f_wr_en_p <= i_wr_en;
    f_wr_addr_p <= i_wr_addr;
    f_wr_data_p <= i_wr_data;
  end

  // Last cycle's write: the identity it carried in either byte order, and
  // whether it named an implemented identity at offset 0 or 4 of a page.
  logic [31:0] f_value_p;
  logic f_ok_p;
  assign f_value_p = (f_wr_addr_p[11:2] == 10'd1) ?
      {f_wr_data_p[7:0], f_wr_data_p[15:8], f_wr_data_p[23:16], f_wr_data_p[31:24]} : f_wr_data_p;
  assign f_ok_p = f_wr_en_p && (f_wr_addr_p[11:2] <= 10'd1) && (f_value_p >= 32'd1) &&
      (f_value_p <= 32'(NUM_IDS));

  // Each file receives exactly the valid writes to its own page, with their
  // identity; any other write reaches no file.
  always_comb begin
    if (f_past_valid && !f_rst_p) begin
      for (int h = 0; h < int'(NUM_HARTS); h++) begin
        assert (msi_m[h] == (f_ok_p && (f_wr_addr_p[31:12] == (M_BASE_ADDR[31:12] + 20'(h)))));
        assert (msi_s[h] == (f_ok_p && (f_wr_addr_p[31:12] == (S_BASE_ADDR[31:12] + 20'(h)))));
        if (msi_m[h] || msi_s[h]) assert (o_msi_id == f_value_p[10:0]);
      end
    end
    if (f_past_valid && f_rst_p) assert ((msi_m == '0) && (msi_s == '0));
  end

  // Reachability: each byte order reaches the last hart's files, with the
  // highest identity.
  always_comb begin
    if (f_past_valid && !f_rst_p) begin
      cover (msi_s[NUM_HARTS-1] && (f_wr_addr_p[11:2] == 10'd1));
      cover (msi_m[NUM_HARTS-1] && (f_wr_addr_p[11:2] == 10'd0) && (o_msi_id == 11'(NUM_IDS)));
    end
  end
  if ((1 << HartBits) > NUM_HARTS) begin : gen_unused_page_cover
    // A region with more pages than harts: a write to an unused page.
    always_comb begin
      if (f_past_valid && !f_rst_p) begin
        cover (f_wr_en_p && ((f_wr_addr_p >> RegionShift) == (S_BASE_ADDR >> RegionShift)) &&
               ((f_wr_addr_p[31:12] & PageMask) >= 20'(NUM_HARTS)) &&
               (f_wr_addr_p[11:0] == 12'h0) && (f_wr_data_p == 32'd1));
      end
    end
  end
`endif

endmodule : imsic_decode
