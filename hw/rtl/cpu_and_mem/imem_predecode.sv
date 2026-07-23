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
 * is-compressed, small opcode-class predecode, and word-local bundle
 * eligibility qualifiers for each halfword start, letting IF avoid rebuilding
 * those decisions from raw instruction bits on the PC timing path.
 * The bit definitions live in riscv_pkg (imem_make_sideband and helpers),
 * shared with the L1I fill path and mirrored by the offline generator
 * sw/common/generate_imem_predecode_init.py.
 *
 * BRAM resource impact: the two half-depth banks occupy the same total BRAM
 * as the original single bank. On X3, synthesis intentionally prunes raw data
 * lanes 31, 29, and 28 from each bank because the exact LUTRAM replicas below
 * provide those architectural bits to the fetch port.
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
    parameter bit [191:0] INIT_FILE_ODD_SIDEBAND = "sw_imem_odd_sideband.mem",
    parameter bit [255:0] INIT_FILE_EVEN_COMPRESSED = "sw_imem_even_compressed.mem",
    parameter bit [255:0] INIT_FILE_ODD_COMPRESSED = "sw_imem_odd_compressed.mem",
    parameter bit [319:0] INIT_FILE_EVEN_SLOT2_START_VALID_LO =
        "sw_imem_even_slot2_start_valid_lo.mem",
    parameter bit [319:0] INIT_FILE_ODD_SLOT2_START_VALID_LO =
        "sw_imem_odd_slot2_start_valid_lo.mem"
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
    // Per-word high-parcel predicate, ordered like o_port_b_read_data:
    // {next_word[27:23] == x2, current_word[27:23] == x2}.
    output logic [1:0] o_port_b_hi_rd_is_x2,
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
  // Keep the predecode sideband in BRAM.  LUTRAM looked attractive for size,
  // but on X3 it spreads the sideband arrays across fabric and puts pc_reg on
  // a long distributed-memory address route in the low-BRAM fetch path.
  (* ram_style = "block" *) logic [SidebandWidth-1:0] memory_even_sideband[HalfDepth];
  (* ram_style = "block" *) logic [SidebandWidth-1:0] memory_odd_sideband[HalfDepth];
  // Mirror the high-parcel allows-slot-2 predicate, the two instruction-size bits,
  // the high-parcel RVC rd==x2 predicate, and raw high-parcel bits C[15],
  // C[13], and C[12] (word[31], word[29], and word[28]) in LUTRAM. The
  // asynchronous reads are captured at the same fetch edge as the BRAM
  // outputs, preserving the interface latency while replacing timing-facing
  // RAMB36 launches with fabric-FF launches.
  // The legacy *_compressed.mem filenames contain the packed seven-bit value
  // {allows_slot2_after_hi, word[29], word[28], word[31],
  //  word[27:23] == 5'd2, is_compressed_hi, is_compressed_lo}. Seven is the
  // full independent-read width of RAM64M8: its eighth lane shares the write
  // address and cannot serve this dual-port programming/fetch memory shape.
  (* ram_style = "distributed", keep = "true", dont_touch = "yes" *)
  logic [6:0] memory_even_compressed[HalfDepth];
  (* ram_style = "distributed", keep = "true", dont_touch = "yes" *)
  logic [6:0] memory_odd_compressed[HalfDepth];
  // Slot2StartValidLo is the remaining BRAM-launched sideband bit on the
  // low-instruction-memory PC path. Keep it in a distinct one-bit LUTRAM: the
  // seven independent-read lanes of RAM64M8 above are already occupied, while
  // RAM64M8's eighth lane shares the write address and cannot use the fetch
  // address required by this programming/fetch dual-port shape.
  (* ram_style = "distributed", keep = "true", dont_touch = "yes" *)
  logic memory_even_slot2_start_valid_lo[HalfDepth];
  (* ram_style = "distributed", keep = "true", dont_touch = "yes" *)
  logic memory_odd_slot2_start_valid_lo[HalfDepth];
  /* verilator lint_on MULTIDRIVEN */

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
      $readmemh(INIT_FILE_EVEN_COMPRESSED, memory_even_compressed);
      $readmemh(INIT_FILE_ODD_COMPRESSED, memory_odd_compressed);
      $readmemh(INIT_FILE_EVEN_SLOT2_START_VALID_LO, memory_even_slot2_start_valid_lo);
      $readmemh(INIT_FILE_ODD_SLOT2_START_VALID_LO, memory_odd_slot2_start_valid_lo);
`else
      $readmemh(INIT_FILE, init_mem);
      // Distribute to even/odd banks
      for (int i = 0; i < FullDepth; i++) begin
        if (i[0] == 1'b0) begin
          memory_even[i>>1] = init_mem[i];
          memory_even_sideband[i>>1] = riscv_pkg::imem_make_sideband(init_mem[i]);
          memory_even_compressed[i>>1] = {
            memory_even_sideband[i>>1][riscv_pkg::ImemSbAllowsSlot2AfterHi],
            init_mem[i][29:28],
            init_mem[i][31],
            init_mem[i][27:23] == 5'd2,
            memory_even_sideband[i>>1][1:0]
          };
          memory_even_slot2_start_valid_lo[i>>1] =
              memory_even_sideband[i>>1][riscv_pkg::ImemSbSlot2StartValidLo];
        end else begin
          memory_odd[i>>1] = init_mem[i];
          memory_odd_sideband[i>>1] = riscv_pkg::imem_make_sideband(init_mem[i]);
          memory_odd_compressed[i>>1] = {
            memory_odd_sideband[i>>1][riscv_pkg::ImemSbAllowsSlot2AfterHi],
            init_mem[i][29:28],
            init_mem[i][31],
            init_mem[i][27:23] == 5'd2,
            memory_odd_sideband[i>>1][1:0]
          };
          memory_odd_slot2_start_valid_lo[i>>1] =
              memory_odd_sideband[i>>1][riscv_pkg::ImemSbSlot2StartValidLo];
        end
      end
`endif
    end else begin
      for (int i = 0; i < HalfDepth; i++) begin
        memory_even[i] = DataWidth'(2 * i);
        memory_odd[i] = DataWidth'(2 * i + 1);
        memory_even_sideband[i] = riscv_pkg::imem_make_sideband(memory_even[i]);
        memory_odd_sideband[i] = riscv_pkg::imem_make_sideband(memory_odd[i]);
        memory_even_compressed[i] = {
          memory_even_sideband[i][riscv_pkg::ImemSbAllowsSlot2AfterHi],
          memory_even[i][29:28],
          memory_even[i][31],
          memory_even[i][27:23] == 5'd2,
          memory_even_sideband[i][1:0]
        };
        memory_odd_compressed[i] = {
          memory_odd_sideband[i][riscv_pkg::ImemSbAllowsSlot2AfterHi],
          memory_odd[i][29:28],
          memory_odd[i][31],
          memory_odd[i][27:23] == 5'd2,
          memory_odd_sideband[i][1:0]
        };
        memory_even_slot2_start_valid_lo[i] =
            memory_even_sideband[i][riscv_pkg::ImemSbSlot2StartValidLo];
        memory_odd_slot2_start_valid_lo[i] =
            memory_odd_sideband[i][riscv_pkg::ImemSbSlot2StartValidLo];
      end
    end
  end
`endif  // YOSYS

  // =========================================================================
  // Port A: Programming interface (write to one bank per cycle)
  // =========================================================================
  // Same-address programming/fetch collisions are intentionally unspecified.
  // The supported Xilinx load flow arms image_load_reset on every programming
  // write and keeps rearming it through the transfer; only execution after the
  // reset release is valid. This port therefore does not provide live-patching
  // coherence between its BRAM and LUTRAM replicas.
  logic [ADDR_WIDTH-1:0] port_a_word_address;
  logic [ADDR_WIDTH-2:0] port_a_half_address;
  logic                  port_a_bank_sel;  // 0 = even, 1 = odd

  assign port_a_word_address = i_port_a_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_a_half_address = port_a_word_address[ADDR_WIDTH-1:1];
  assign port_a_bank_sel     = port_a_word_address[0];

  // Compute sideband from write data at write time.
  logic [SidebandWidth-1:0] write_sideband;
  assign write_sideband = riscv_pkg::imem_make_sideband(i_port_a_write_data);

  // Port A — even bank
  always_ff @(posedge i_port_a_clk) begin
    if (i_port_a_enable) begin
      if (i_port_a_write_enable && !port_a_bank_sel) begin
        memory_even[port_a_half_address] <= i_port_a_write_data;
        memory_even_sideband[port_a_half_address] <= write_sideband;
        memory_even_compressed[port_a_half_address] <= {
          write_sideband[riscv_pkg::ImemSbAllowsSlot2AfterHi],
          i_port_a_write_data[29:28],
          i_port_a_write_data[31],
          i_port_a_write_data[27:23] == 5'd2,
          write_sideband[1:0]
        };
        memory_even_slot2_start_valid_lo[port_a_half_address] <=
            write_sideband[riscv_pkg::ImemSbSlot2StartValidLo];
      end
    end
  end

  // Port A — odd bank
  always_ff @(posedge i_port_a_clk) begin
    if (i_port_a_enable) begin
      if (i_port_a_write_enable && port_a_bank_sel) begin
        memory_odd[port_a_half_address] <= i_port_a_write_data;
        memory_odd_sideband[port_a_half_address] <= write_sideband;
        memory_odd_compressed[port_a_half_address] <= {
          write_sideband[riscv_pkg::ImemSbAllowsSlot2AfterHi],
          i_port_a_write_data[29:28],
          i_port_a_write_data[31],
          i_port_a_write_data[27:23] == 5'd2,
          write_sideband[1:0]
        };
        memory_odd_slot2_start_valid_lo[port_a_half_address] <=
            write_sideband[riscv_pkg::ImemSbSlot2StartValidLo];
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
  (* keep = "true", dont_touch = "yes" *) logic [6:0] even_compressed;
  (* keep = "true", dont_touch = "yes" *) logic [6:0] odd_compressed;
  (* keep = "true", dont_touch = "yes" *) logic even_slot2_start_valid_lo;
  (* keep = "true", dont_touch = "yes" *) logic odd_slot2_start_valid_lo;

  always_ff @(posedge i_port_b_clk) begin
    if (i_port_b_enable) begin
      even_read_data <= memory_even[even_read_addr];
      odd_read_data <= memory_odd[odd_read_addr];
      even_sideband <= memory_even_sideband[even_read_addr];
      odd_sideband <= memory_odd_sideband[odd_read_addr];
      even_compressed <= memory_even_compressed[even_read_addr];
      odd_compressed <= memory_odd_compressed[odd_read_addr];
      even_slot2_start_valid_lo <= memory_even_slot2_start_valid_lo[even_read_addr];
      odd_slot2_start_valid_lo <= memory_odd_slot2_start_valid_lo[odd_read_addr];
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
  logic [DataWidth-1:0] even_read_data_with_fast_rvc_fields;
  logic [DataWidth-1:0] odd_read_data_with_fast_rvc_fields;
  logic [SidebandWidth-1:0] current_sideband, next_sideband;
  logic [SidebandWidth-1:0] even_sideband_with_fast_compressed;
  logic [SidebandWidth-1:0] odd_sideband_with_fast_compressed;
  always_comb begin
    even_read_data_with_fast_rvc_fields = even_read_data;
    odd_read_data_with_fast_rvc_fields = odd_read_data;
    even_read_data_with_fast_rvc_fields[31] = even_compressed[3];
    odd_read_data_with_fast_rvc_fields[31] = odd_compressed[3];
    even_read_data_with_fast_rvc_fields[29:28] = even_compressed[5:4];
    odd_read_data_with_fast_rvc_fields[29:28] = odd_compressed[5:4];
    even_sideband_with_fast_compressed = even_sideband;
    odd_sideband_with_fast_compressed = odd_sideband;
    even_sideband_with_fast_compressed[1:0] = even_compressed[1:0];
    odd_sideband_with_fast_compressed[1:0] = odd_compressed[1:0];
    // The replicated high-parcel size and allows bits are the two inputs to
    // both pairability predicates. Rebuild both here so neither public
    // predicate depends on the timing-facing sideband BRAM launch.
    even_sideband_with_fast_compressed[riscv_pkg::ImemSbAllowsSlot2AfterHi] = even_compressed[6];
    odd_sideband_with_fast_compressed[riscv_pkg::ImemSbAllowsSlot2AfterHi] = odd_compressed[6];
    even_sideband_with_fast_compressed[riscv_pkg::ImemSbPairableCompressedHi] =
        even_compressed[1] && even_compressed[6];
    odd_sideband_with_fast_compressed[riscv_pkg::ImemSbPairableCompressedHi] =
        odd_compressed[1] && odd_compressed[6];
    even_sideband_with_fast_compressed[riscv_pkg::ImemSbPairableNativeHi] =
        !even_compressed[1] && even_compressed[6];
    odd_sideband_with_fast_compressed[riscv_pkg::ImemSbPairableNativeHi] =
        !odd_compressed[1] && odd_compressed[6];
    even_sideband_with_fast_compressed[riscv_pkg::ImemSbSlot2StartValidLo] =
        even_slot2_start_valid_lo;
    odd_sideband_with_fast_compressed[riscv_pkg::ImemSbSlot2StartValidLo] =
        odd_slot2_start_valid_lo;
  end
  assign current_word_wide   = bank_sel_r ? odd_read_data_with_fast_rvc_fields :
                                           even_read_data_with_fast_rvc_fields;
  assign next_word_wide = bank_sel_r ? even_read_data_with_fast_rvc_fields :
                                       odd_read_data_with_fast_rvc_fields;
  assign current_sideband    = bank_sel_r ? odd_sideband_with_fast_compressed :
                                           even_sideband_with_fast_compressed;
  assign next_sideband       = bank_sel_r ? even_sideband_with_fast_compressed :
                                           odd_sideband_with_fast_compressed;

  assign o_port_b_read_data = {next_word_wide, current_word_wide};
  assign o_port_b_sideband = {next_sideband, current_sideband};
  assign o_port_b_hi_rd_is_x2 = bank_sel_r ? {even_compressed[2], odd_compressed[2]} :
                                             {odd_compressed[2], even_compressed[2]};
  assign o_port_b_bank_sel_r = bank_sel_r;

`ifndef SYNTHESIS
  // Both replicas are written and fetched with their parent instruction word.
  // Keep a local oracle so future init/write-path changes cannot silently let
  // the timing replica diverge from the architectural BRAM data.
  always_comb begin
    if (!$isunknown(
            {
              even_read_data,
              odd_read_data,
              even_sideband,
              odd_sideband,
              even_compressed,
              odd_compressed,
              even_slot2_start_valid_lo,
              odd_slot2_start_valid_lo
            }
        )) begin
      p_even_fast_c15_matches_bram : assert (even_compressed[3] == even_read_data[31]);
      p_odd_fast_c15_matches_bram : assert (odd_compressed[3] == odd_read_data[31]);
      p_even_fast_c13_c12_matches_bram : assert (even_compressed[5:4] == even_read_data[29:28]);
      p_odd_fast_c13_c12_matches_bram : assert (odd_compressed[5:4] == odd_read_data[29:28]);
      p_even_fast_hi_rd_is_x2_matches_bram :
      assert (even_compressed[2] == (even_read_data[27:23] == 5'd2));
      p_odd_fast_hi_rd_is_x2_matches_bram :
      assert (odd_compressed[2] == (odd_read_data[27:23] == 5'd2));
      p_even_fast_compressed_matches_bram : assert (even_compressed[1:0] == even_sideband[1:0]);
      p_odd_fast_compressed_matches_bram : assert (odd_compressed[1:0] == odd_sideband[1:0]);
      p_even_fast_allows_slot2_after_hi_matches_bram :
      assert (even_compressed[6] == even_sideband[riscv_pkg::ImemSbAllowsSlot2AfterHi]);
      p_odd_fast_allows_slot2_after_hi_matches_bram :
      assert (odd_compressed[6] == odd_sideband[riscv_pkg::ImemSbAllowsSlot2AfterHi]);
      p_even_rebuilt_pairable_compressed_hi_matches_bram :
      assert ((even_compressed[1] && even_compressed[6]) ==
              even_sideband[riscv_pkg::ImemSbPairableCompressedHi]);
      p_odd_rebuilt_pairable_compressed_hi_matches_bram :
      assert ((odd_compressed[1] && odd_compressed[6]) ==
              odd_sideband[riscv_pkg::ImemSbPairableCompressedHi]);
      p_even_rebuilt_pairable_native_hi_matches_bram :
      assert ((!even_compressed[1] && even_compressed[6]) ==
              even_sideband[riscv_pkg::ImemSbPairableNativeHi]);
      p_odd_rebuilt_pairable_native_hi_matches_bram :
      assert ((!odd_compressed[1] && odd_compressed[6]) ==
              odd_sideband[riscv_pkg::ImemSbPairableNativeHi]);
      p_even_fast_slot2_start_valid_lo_matches_bram :
      assert (even_slot2_start_valid_lo == even_sideband[riscv_pkg::ImemSbSlot2StartValidLo]);
      p_odd_fast_slot2_start_valid_lo_matches_bram :
      assert (odd_slot2_start_valid_lo == odd_sideband[riscv_pkg::ImemSbSlot2StartValidLo]);
    end
  end
`endif

endmodule : imem_predecode
