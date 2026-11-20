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

// Fetch data and bank-select cone of imem_predecode at 1ee9df0e6.
// Metadata storage, recovery and decoding are outside this cone. The spare
// fourth fast lane has a constant write value; its read bit stays independent
// of the three instruction bits. The boundary uses the no-image synth view.

module imem_predecode_reference #(
    parameter int unsigned ADDR_WIDTH = 14,
    parameter bit USE_INIT_FILE = 1'b1,
    // One block-RAM image per bank, as wide as the wrappers' INIT_FILE.
    parameter bit [319:0] INIT_FILE_EVEN_COLD = "sw_imem_even_cold.mem",
    parameter bit [319:0] INIT_FILE_ODD_COLD = "sw_imem_odd_cold.mem",
    parameter bit [319:0] INIT_FILE_EVEN_FRONTEND_HOT = "sw_imem_even_frontend_hot.mem",
    parameter bit [319:0] INIT_FILE_ODD_FRONTEND_HOT = "sw_imem_odd_frontend_hot.mem",
    parameter bit [319:0] INIT_FILE_EVEN_COMPRESSED = "sw_imem_even_compressed.mem",
    parameter bit [319:0] INIT_FILE_ODD_COMPRESSED = "sw_imem_odd_compressed.mem"
) (
    // Port A: Programming interface (slow clock)
    input  logic        i_port_a_clk,
    input  logic        i_port_a_rst,
    input  logic        i_port_a_enable,
    input  logic [31:0] i_port_a_byte_address,
    input  logic [31:0] i_port_a_write_data,
    input  logic        i_port_a_write_enable,
    output logic [31:0] o_port_a_read_data,

    // Port B: Instruction fetch (fast clock), 64-bit output
    input logic i_port_b_clk,
    input logic i_port_b_rst,
    input logic i_port_b_enable,
    input logic [31:0] i_port_b_byte_address,
    // Physical address of aligned word 1. It follows word 0 within a page,
    // but may be in a noncontiguous physical page across a translated boundary.
    input logic [31:0] i_port_b_next_byte_address,
    output logic [63:0] o_port_b_read_data,  // {next_word, current_word}
    // Physical {odd, even} order; IF selects the current word by pc_reg[2].
    output logic [63:0] o_port_b_read_data_by_parity,
    output logic o_port_b_bank_sel_r  // Registered fetch-word parity (PC[2] from fetch cycle)
);

  localparam int unsigned DataWidth = 32;
  localparam int unsigned ColdDataWidth = 28;
  localparam int unsigned FrontendHotWidth = 4;
  localparam int unsigned ByteAddrBits = 2;  // 32-bit word alignment
  // Lane order of the narrow high-parcel block RAM (u_*_compressed; despite
  // the name it holds no instruction-size bits, which live in the scalar
  // LUTRAM overlay).
  localparam int unsigned FastLaneC15 = 0;  // word[31]
  localparam int unsigned FastLaneC12 = 1;  // word[28]
  localparam int unsigned FastLaneC13 = 2;  // word[29]
  localparam int unsigned FastLaneWidth = 4;

  // Lane order must match the offline init files:
  //   hot[3:0] = {word[15], word[10], word[7], word[6]}.
  // Cold packs the remaining bits in architectural order; both are rewires.
  function automatic logic [FrontendHotWidth-1:0] pack_frontend_hot(
      input logic [DataWidth-1:0] word);
    pack_frontend_hot = {word[15], word[10], word[7], word[6]};
  endfunction

  function automatic logic [ColdDataWidth-1:0] pack_cold_data(input logic [DataWidth-1:0] word);
    pack_cold_data = {word[31:16], word[14:11], word[9:8], word[5:0]};
  endfunction

  function automatic logic [DataWidth-1:0] join_data_banks(
      input logic [ColdDataWidth-1:0] cold, input logic [FrontendHotWidth-1:0] frontend_hot);
    join_data_banks = {
      cold[27:12],
      frontend_hot[3],
      cold[11:8],
      frontend_hot[2],
      cold[7:6],
      frontend_hot[1:0],
      cold[5:0]
    };
  endfunction


  localparam bit LoadBankImages = USE_INIT_FILE;

  logic [ADDR_WIDTH-1:0] port_a_word_address;
  logic [ADDR_WIDTH-2:0] port_a_half_address;
  logic                  port_a_bank_sel;  // 0 = even, 1 = odd

  assign port_a_word_address = i_port_a_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_a_half_address = port_a_word_address[ADDR_WIDTH-1:1];
  assign port_a_bank_sel     = port_a_word_address[0];

  (* max_fanout = 512 *) logic [ADDR_WIDTH-2:0] port_a_half_address_q;
  (* max_fanout = 512 *) logic [DataWidth-1:0] port_a_write_data_q;
  // The comparison supplies arbitrary paired starting values.
  (* max_fanout = 512 *) logic port_a_write_even_q;
  (* max_fanout = 512 *) logic port_a_write_odd_q;

  always_ff @(posedge i_port_a_clk) begin
    port_a_half_address_q <= port_a_half_address;
    port_a_write_data_q   <= i_port_a_write_data;
    if (i_port_a_rst) begin
      port_a_write_even_q <= 1'b0;
      port_a_write_odd_q  <= 1'b0;
    end else begin
      port_a_write_even_q <= i_port_a_enable && i_port_a_write_enable && !port_a_bank_sel;
      port_a_write_odd_q  <= i_port_a_enable && i_port_a_write_enable && port_a_bank_sel;
    end
  end

  // Qualify the first edge too: the staged enables have not seen reset yet.
  // Programming reset is independent of the reset held while loading an image.
  logic port_a_write_even, port_a_write_odd;
  assign port_a_write_even = port_a_write_even_q && !i_port_a_rst;
  assign port_a_write_odd  = port_a_write_odd_q && !i_port_a_rst;

  logic [ColdDataWidth-1:0] write_cold;
  logic [FrontendHotWidth-1:0] write_frontend_hot;
  logic [FastLaneWidth-1:0] write_fast_lanes;
  assign write_cold = pack_cold_data(port_a_write_data_q);
  assign write_frontend_hot = pack_frontend_hot(port_a_write_data_q);
  // The first three lanes contain the original instruction bits.
  assign write_fast_lanes = {1'b0, port_a_write_data_q[29:28], port_a_write_data_q[31]};

  assign o_port_a_read_data = i_port_a_write_data;

  // =========================================================================
  // Port B: 64-bit instruction fetch (read both banks every cycle)
  // =========================================================================
  logic [ADDR_WIDTH-1:0] port_b_word_address;
  logic [ADDR_WIDTH-2:0] port_b_half_address;  // = word_address >> 1
  logic                  port_b_bank_sel;  // = word_address[0] = PC[2]
  logic [ADDR_WIDTH-1:0] port_b_next_word_address;
  logic [ADDR_WIDTH-2:0] port_b_next_half_address;

  assign port_b_word_address = i_port_b_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_b_half_address = port_b_word_address[ADDR_WIDTH-1:1];
  assign port_b_bank_sel = port_b_word_address[0];
  assign port_b_next_word_address =
      i_port_b_next_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_b_next_half_address = port_b_next_word_address[ADDR_WIDTH-1:1];

  // Even bank address: with PC[2]=0 the current half-address (word 1 shares
  // the dword); with PC[2]=1 word 1's own half-address, the caller's second
  // word address (half-address+1 when contiguous).
  // Odd bank address: always the current half-address.
  logic [ADDR_WIDTH-2:0] even_read_addr, odd_read_addr;
  assign even_read_addr = port_b_bank_sel ? port_b_next_half_address : port_b_half_address;
  assign odd_read_addr  = port_b_half_address;

  logic [ColdDataWidth-1:0] even_read_data_cold, odd_read_data_cold;
  logic [FrontendHotWidth-1:0] even_read_data_frontend_hot;
  logic [FrontendHotWidth-1:0] odd_read_data_frontend_hot;
  logic [DataWidth-1:0] even_read_data, odd_read_data;
  logic [FastLaneWidth-1:0] even_compressed;
  logic [FastLaneWidth-1:0] odd_compressed;

`ifdef FROST_VIVADO_SYNTH
  localparam int unsigned ColdBankWidth = ColdDataWidth - 1;
`else
  localparam int unsigned ColdBankWidth = ColdDataWidth;
`endif
  sdp_block_ram_dc_init #(
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .DATA_WIDTH(ColdBankWidth),
      .USE_INIT_FILE(LoadBankImages),
      .SIM_EXTERNAL_INIT(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE_EVEN_COLD)
  ) u_even_cold (
      .i_write_clock(i_port_a_clk),
      .i_write_enable(port_a_write_even),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_cold[ColdBankWidth-1:0]),
      .i_read_clock(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(even_read_addr),
      .o_read_data(even_read_data_cold[ColdBankWidth-1:0])
  );

  sdp_block_ram_dc_init #(
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .DATA_WIDTH(ColdBankWidth),
      .USE_INIT_FILE(LoadBankImages),
      .SIM_EXTERNAL_INIT(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE_ODD_COLD)
  ) u_odd_cold (
      .i_write_clock(i_port_a_clk),
      .i_write_enable(port_a_write_odd),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_cold[ColdBankWidth-1:0]),
      .i_read_clock(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(odd_read_addr),
      .o_read_data(odd_read_data_cold[ColdBankWidth-1:0])
  );

  if (ColdBankWidth < ColdDataWidth) begin : gen_cold_word31_from_c15_lane
    assign even_read_data_cold[ColdDataWidth-1] = even_compressed[FastLaneC15];
    assign odd_read_data_cold[ColdDataWidth-1]  = odd_compressed[FastLaneC15];
  end

  // Separate four-bit banks for timing; at 16K depth each uses two RAMB36s.
  sdp_block_ram_dc_init #(
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .DATA_WIDTH(FrontendHotWidth),
      .USE_INIT_FILE(LoadBankImages),
      .SIM_EXTERNAL_INIT(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE_EVEN_FRONTEND_HOT)
  ) u_even_frontend_hot (
      .i_write_clock(i_port_a_clk),
      .i_write_enable(port_a_write_even),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_frontend_hot),
      .i_read_clock(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(even_read_addr),
      .o_read_data(even_read_data_frontend_hot)
  );

  sdp_block_ram_dc_init #(
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .DATA_WIDTH(FrontendHotWidth),
      .USE_INIT_FILE(LoadBankImages),
      .SIM_EXTERNAL_INIT(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE_ODD_FRONTEND_HOT)
  ) u_odd_frontend_hot (
      .i_write_clock(i_port_a_clk),
      .i_write_enable(port_a_write_odd),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_frontend_hot),
      .i_read_clock(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(odd_read_addr),
      .o_read_data(odd_read_data_frontend_hot)
  );

  sdp_block_ram_dc_init #(
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .DATA_WIDTH(FastLaneWidth),
      .USE_INIT_FILE(LoadBankImages),
      .SIM_EXTERNAL_INIT(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE_EVEN_COMPRESSED)
  ) u_even_compressed (
      .i_write_clock(i_port_a_clk),
      .i_write_enable(port_a_write_even),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_fast_lanes),
      .i_read_clock(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(even_read_addr),
      .o_read_data(even_compressed)
  );

  sdp_block_ram_dc_init #(
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .DATA_WIDTH(FastLaneWidth),
      .USE_INIT_FILE(LoadBankImages),
      .SIM_EXTERNAL_INIT(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE_ODD_COMPRESSED)
  ) u_odd_compressed (
      .i_write_clock(i_port_a_clk),
      .i_write_enable(port_a_write_odd),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_fast_lanes),
      .i_read_clock(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(odd_read_addr),
      .o_read_data(odd_compressed)
  );

  assign even_read_data = join_data_banks(even_read_data_cold, even_read_data_frontend_hot);
  assign odd_read_data  = join_data_banks(odd_read_data_cold, odd_read_data_frontend_hot);

  // Register the bank select on the same edge as the BRAM outputs so the swap
  // mux is aligned with the data it selects.
  logic bank_sel_r;
  always_ff @(posedge i_port_b_clk) begin
    if (i_port_b_enable) begin
      bank_sel_r <= port_b_bank_sel;
    end
  end

  // Swap mux: produce {next_word, current_word}
  //   PC[2]=0 (even word first): current = EVEN, next = ODD
  //   PC[2]=1 (odd  word first): current = ODD,  next = EVEN
  logic [DataWidth-1:0] current_word_wide, next_word_wide;
  logic [DataWidth-1:0] even_read_data_with_fast_rvc_fields;
  logic [DataWidth-1:0] odd_read_data_with_fast_rvc_fields;
  always_comb begin
    even_read_data_with_fast_rvc_fields = even_read_data;
    odd_read_data_with_fast_rvc_fields = odd_read_data;
    even_read_data_with_fast_rvc_fields[31] = even_compressed[FastLaneC15];
    odd_read_data_with_fast_rvc_fields[31] = odd_compressed[FastLaneC15];
    even_read_data_with_fast_rvc_fields[29:28] = even_compressed[FastLaneC13:FastLaneC12];
    odd_read_data_with_fast_rvc_fields[29:28] = odd_compressed[FastLaneC13:FastLaneC12];
  end

  assign current_word_wide   = bank_sel_r ? odd_read_data_with_fast_rvc_fields :
                                           even_read_data_with_fast_rvc_fields;
  assign next_word_wide = bank_sel_r ? even_read_data_with_fast_rvc_fields :
                                       odd_read_data_with_fast_rvc_fields;
  assign o_port_b_read_data = {next_word_wide, current_word_wide};
  assign o_port_b_read_data_by_parity = {
    odd_read_data_with_fast_rvc_fields, even_read_data_with_fast_rvc_fields
  };
  assign o_port_b_bank_sel_r = bank_sel_r;

endmodule : imem_predecode_reference
