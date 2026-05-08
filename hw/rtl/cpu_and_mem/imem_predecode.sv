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
 * Instruction Memory with Predecode Sideband — 64-bit Fetch
 *
 * Provides two consecutive 32-bit instruction words per fetch cycle using
 * even/odd interleaved BRAM banks.  This eliminates the C-extension
 * spanning penalty: when a 32-bit instruction straddles a word boundary
 * (PC[1]=1), both halves are available in a single read.
 *
 * Architecture:
 *   memory_even — stores words at even word indices (0, 2, 4, …)
 *   memory_odd  — stores words at odd  word indices (1, 3, 5, …)
 *
 * For any fetch address, both banks are read in parallel.  The bank
 * addresses differ by at most 1 depending on whether the fetch word
 * index is even or odd:
 *
 *   W = fetch_byte_addr[31:2]            (word index)
 *   W is even (PC[2]=0):
 *     BRAM_EVEN addr = W >> 1            → word[W]
 *     BRAM_ODD  addr = W >> 1            → word[W+1]
 *   W is odd  (PC[2]=1):
 *     BRAM_ODD  addr = W >> 1            → word[W]
 *     BRAM_EVEN addr = (W >> 1) + 1      → word[W+1]
 *
 * The registered mux-select (PC[2] from the fetch cycle) swaps the
 * bank outputs so that port_b_read_data always delivers:
 *     [31:0]  = word at W   (current word)
 *     [63:32] = word at W+1 (next word)
 *
 * Sideband bits are stored alongside each 32-bit word.  The sideband carries
 * is-compressed and small opcode-class predecode for each halfword start,
 * letting IF avoid re-decoding raw instruction bits on the PC timing path.
 *
 * BRAM resource impact: the two half-depth banks occupy the same total
 * BRAM as the original single bank — no additional cost.
 *
 * Port A: Instruction programming (slow clock domain, write + read)
 * Port B: Instruction fetch (fast clock domain, read only)
 */
module imem_predecode #(
    parameter int unsigned ADDR_WIDTH = 14,
    parameter bit USE_INIT_FILE = 1'b1,
    parameter bit [47:0] INIT_FILE = "sw.mem",
    parameter bit [127:0] INIT_FILE_EVEN = "sw_imem_even.mem",
    parameter bit [119:0] INIT_FILE_ODD = "sw_imem_odd.mem",
    parameter bit [199:0] INIT_FILE_EVEN_SIDEBAND = "sw_imem_even_sideband.mem",
    parameter bit [191:0] INIT_FILE_ODD_SIDEBAND = "sw_imem_odd_sideband.mem"
) (
    // Port A: Programming interface (slow clock)
    input  logic        i_port_a_clk,
    input  logic        i_port_a_enable,
    input  logic [31:0] i_port_a_byte_address,
    input  logic [31:0] i_port_a_write_data,
    input  logic        i_port_a_write_enable,
    output logic [31:0] o_port_a_read_data,

    // Port B: Instruction fetch (fast clock) — 64-bit output
    input logic i_port_b_clk,
    input logic i_port_b_enable,
    input logic [31:0] i_port_b_byte_address,
    output logic [63:0] o_port_b_read_data,  // {next_word, current_word}
    output logic [riscv_pkg::ImemFetchSidebandWidth-1:0] o_port_b_sideband,
    output logic o_port_b_bank_sel_r  // Registered fetch-word parity (PC[2] from fetch cycle)
);

  localparam int unsigned DataWidth = 32;
  localparam int unsigned SidebandWidth = riscv_pkg::ImemSidebandWidth;
  localparam int unsigned HalfDepth = 2 ** (ADDR_WIDTH - 1);
  localparam int unsigned FullDepth = 2 ** ADDR_WIDTH;
  localparam int unsigned ByteAddrBits = 2;  // 32-bit word alignment

  // =========================================================================
  // Even/odd interleaved memory banks
  // =========================================================================
  // memory_even[k] holds the word whose full word-index is 2*k   (even)
  // memory_odd [k] holds the word whose full word-index is 2*k+1 (odd)
  /* verilator lint_off MULTIDRIVEN */
  (* ram_style = "block" *) logic [DataWidth-1:0] memory_even[HalfDepth];
  (* ram_style = "block" *) logic [DataWidth-1:0] memory_odd[HalfDepth];
  // Keep the small predecode sideband out of the instruction BRAM output path.
  // It is read and registered with the same fetch address/clock as the data.
  (* ram_style = "distributed" *) logic [SidebandWidth-1:0] memory_even_sideband[HalfDepth];
  (* ram_style = "distributed" *) logic [SidebandWidth-1:0] memory_odd_sideband[HalfDepth];
  /* verilator lint_on MULTIDRIVEN */

  function automatic logic compressed_control(input logic [15:0] parcel);
    logic [2:0] funct3;
    logic [3:0] funct4;
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [1:0] op;
    begin
      funct3 = parcel[15:13];
      funct4 = parcel[15:12];
      rs1 = parcel[11:7];
      rs2 = parcel[6:2];
      op = parcel[1:0];
      compressed_control =
          ((op == 2'b01) &&
           ((funct3 == 3'b001) || (funct3 == 3'b101) ||
            (funct3 == 3'b110) || (funct3 == 3'b111))) ||
          ((op == 2'b10) &&
           (rs2 == 5'b00000) &&
           (rs1 != 5'b00000) &&
           ((funct4 == 4'b1000) || (funct4 == 4'b1001)));
    end
  endfunction

  function automatic logic native_serialize(input logic [6:0] opcode);
    begin
      native_serialize = (opcode == riscv_pkg::OPC_CSR) ||
                         (opcode == riscv_pkg::OPC_MISC_MEM) ||
                         (opcode == riscv_pkg::OPC_AMO);
    end
  endfunction

  function automatic logic native_fp_compute(input logic [6:0] opcode);
    begin
      native_fp_compute = (opcode == riscv_pkg::OPC_OP_FP) ||
                          (opcode == riscv_pkg::OPC_FMADD) ||
                          (opcode == riscv_pkg::OPC_FMSUB) ||
                          (opcode == riscv_pkg::OPC_FNMSUB) ||
                          (opcode == riscv_pkg::OPC_FNMADD);
    end
  endfunction

  function automatic logic [SidebandWidth-1:0] make_sideband(input logic [31:0] word);
    logic [SidebandWidth-1:0] sb;
    begin
      sb = '0;
      sb[riscv_pkg::ImemSbIsCompressedLo] = (word[1:0] != 2'b11);
      sb[riscv_pkg::ImemSbIsCompressedHi] = (word[17:16] != 2'b11);
      sb[riscv_pkg::ImemSbCompressedControlLo] = compressed_control(word[15:0]);
      sb[riscv_pkg::ImemSbCompressedControlHi] = compressed_control(word[31:16]);
      sb[riscv_pkg::ImemSbNativeSerializeLo] = native_serialize(word[6:0]);
      sb[riscv_pkg::ImemSbNativeSerializeHi] = native_serialize(word[22:16]);
      sb[riscv_pkg::ImemSbNativeFpComputeLo] = native_fp_compute(word[6:0]);
      sb[riscv_pkg::ImemSbNativeFpComputeHi] = native_fp_compute(word[22:16]);
      make_sideband = sb;
    end
  endfunction

  // =========================================================================
  // Initialization — split sw.mem into even/odd banks
  // =========================================================================
`ifndef YOSYS
  // Keep the preload split out of Yosys: it expands the temporary init_mem
  // array into registers during frontend elaboration. Vivado reads the already
  // split init files directly so every synthesized memory has an explicit
  // power-up image.
`ifndef FROST_VIVADO_SYNTH
  logic [DataWidth-1:0] init_mem[FullDepth];
`endif

  initial begin
    if (USE_INIT_FILE) begin
`ifdef FROST_VIVADO_SYNTH
      $readmemh(INIT_FILE_EVEN, memory_even);
      $readmemh(INIT_FILE_ODD, memory_odd);
      $readmemh(INIT_FILE_EVEN_SIDEBAND, memory_even_sideband);
      $readmemh(INIT_FILE_ODD_SIDEBAND, memory_odd_sideband);
`else
      $readmemh(INIT_FILE, init_mem);
      // Distribute to even/odd banks
      for (int i = 0; i < FullDepth; i++) begin
        if (i[0] == 1'b0) begin
          memory_even[i>>1] = init_mem[i];
          memory_even_sideband[i>>1] = make_sideband(init_mem[i]);
        end else begin
          memory_odd[i>>1] = init_mem[i];
          memory_odd_sideband[i>>1] = make_sideband(init_mem[i]);
        end
      end
`endif
    end else begin
      for (int i = 0; i < HalfDepth; i++) begin
        memory_even[i] = DataWidth'(2 * i);
        memory_odd[i] = DataWidth'(2 * i + 1);
        memory_even_sideband[i] = make_sideband(memory_even[i]);
        memory_odd_sideband[i] = make_sideband(memory_odd[i]);
      end
    end
  end
`endif  // YOSYS

  // =========================================================================
  // Port A: Programming interface (write to one bank per cycle)
  // =========================================================================
  logic [ADDR_WIDTH-1:0] port_a_word_address;
  logic [ADDR_WIDTH-2:0] port_a_half_address;
  logic                  port_a_bank_sel;  // 0 = even, 1 = odd

  assign port_a_word_address = i_port_a_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_a_half_address = port_a_word_address[ADDR_WIDTH-1:1];
  assign port_a_bank_sel     = port_a_word_address[0];

  // Compute sideband from write data at write time.
  logic [SidebandWidth-1:0] write_sideband;
  assign write_sideband = make_sideband(i_port_a_write_data);

  // Port A — even bank
  always_ff @(posedge i_port_a_clk) begin
    if (i_port_a_enable) begin
      if (i_port_a_write_enable && !port_a_bank_sel) begin
        memory_even[port_a_half_address] <= i_port_a_write_data;
        memory_even_sideband[port_a_half_address] <= write_sideband;
      end
    end
  end

  // Port A — odd bank
  always_ff @(posedge i_port_a_clk) begin
    if (i_port_a_enable) begin
      if (i_port_a_write_enable && port_a_bank_sel) begin
        memory_odd[port_a_half_address] <= i_port_a_write_data;
        memory_odd_sideband[port_a_half_address] <= write_sideband;
      end
    end
  end

`ifndef SYNTHESIS
  // Port A read (write-first): read back from whichever bank was addressed
  always_ff @(posedge i_port_a_clk) begin
    if (i_port_a_enable) begin
      if (i_port_a_write_enable) begin
        o_port_a_read_data <= i_port_a_write_data;
      end else begin
        o_port_a_read_data <= port_a_bank_sel ?
            memory_odd[port_a_half_address] : memory_even[port_a_half_address];
      end
    end
  end
`else
  // The programming-side readback is unused by the core. Removing this BRAM
  // read port under synthesis keeps the two-bank memory in a Xilinx-mappable
  // one-write/one-read shape.
  assign o_port_a_read_data = i_port_a_write_data;
`endif

  // =========================================================================
  // Port B: 64-bit instruction fetch (read both banks every cycle)
  // =========================================================================
  logic [ADDR_WIDTH-1:0] port_b_word_address;
  logic [ADDR_WIDTH-2:0] port_b_half_address;  // = word_address >> 1
  logic                  port_b_bank_sel;  // = word_address[0] = PC[2]

  assign port_b_word_address = i_port_b_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_b_half_address = port_b_word_address[ADDR_WIDTH-1:1];
  assign port_b_bank_sel     = port_b_word_address[0];

  // BRAM_EVEN address: when PC[2]=0, same half-addr; when PC[2]=1, half-addr+1
  // BRAM_ODD  address: always half-addr
  logic [ADDR_WIDTH-2:0] even_read_addr, odd_read_addr;
  assign even_read_addr = port_b_bank_sel ? (port_b_half_address + 1'd1) : port_b_half_address;
  assign odd_read_addr  = port_b_half_address;

  logic [DataWidth-1:0] even_read_data, odd_read_data;
  logic [SidebandWidth-1:0] even_sideband, odd_sideband;

  always_ff @(posedge i_port_b_clk) begin
    if (i_port_b_enable) begin
      even_read_data <= memory_even[even_read_addr];
      odd_read_data  <= memory_odd[odd_read_addr];
      even_sideband  <= memory_even_sideband[even_read_addr];
      odd_sideband   <= memory_odd_sideband[odd_read_addr];
    end
  end

  // Register the bank select alongside the BRAM outputs so the swap mux
  // is aligned with the data (both registered on the same clock edge).
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
  logic [SidebandWidth-1:0] current_sideband, next_sideband;
  assign current_word_wide   = bank_sel_r ? odd_read_data : even_read_data;
  assign next_word_wide      = bank_sel_r ? even_read_data : odd_read_data;
  assign current_sideband    = bank_sel_r ? odd_sideband : even_sideband;
  assign next_sideband       = bank_sel_r ? even_sideband : odd_sideband;

  assign o_port_b_read_data  = {next_word_wide, current_word_wide};
  assign o_port_b_sideband   = {next_sideband, current_sideband};
  assign o_port_b_bank_sel_r = bank_sel_r;

endmodule : imem_predecode
