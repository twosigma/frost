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
 * Consumer-local LUTRAM overlay for one predecode sideband predicate and one
 * IMEM parity. The canonical full-depth sideband block RAM remains the source
 * for noncritical lanes and the simulation equivalence oracle. This pinned
 * low-address overlay lets the default low-memory program launch the
 * fetch-seam IF PC cone from a fabric flop instead of a RAMB36E2
 * clock-to-output, without replicating the metadata for the whole 256 KiB IMEM
 * in LUTRAM. The asynchronous distributed-RAM read lands in a local output
 * register with the same one-cycle latency and read-enable hold as the
 * block-RAM banks it mirrors. Outside the overlay a ready handshake withholds
 * the first raw response and redecodes each predicate into that same output
 * FF, so the canonical predicate BRAM lanes never reconnect to the PC.
 *
 * The keep_hierarchy attribute keeps every copy independently placeable and
 * stops Vivado from sharing its storage with the canonical bank. Programming
 * writes arrive from the same staged port-A registers as every other bank, so
 * a copy can never diverge from the word it mirrors. The parent quarantines
 * fetch readiness around those writes because the registered slow fallback is
 * one response behind the canonical block RAM while live debug code is
 * rewritten.
 */
(* keep_hierarchy = "yes" *)
module imem_sideband_scalar_bank #(
    parameter int unsigned SIDEBAND_BIT = riscv_pkg::ImemSbIsCompressedLo,
    // Width of the parent parity-bank address presented at the ports.
    parameter int unsigned ADDR_WIDTH = 13,
    // Width of the address the pinned low-address overlay stores.
    parameter int unsigned STORAGE_ADDR_WIDTH = ADDR_WIDTH,
    parameter bit USE_INIT_FILE = 1'b1,
    parameter bit [47:0] INIT_FILE = "sw.mem",
    parameter bit [319:0] BANK_INIT_FILE = "sw_imem_even_is_compressed_lo.mem",
    parameter bit IS_ODD_BANK = 1'b0
) (
    input logic i_write_clk,
    input logic i_write_enable,
    input logic [ADDR_WIDTH-1:0] i_write_address,
    input logic i_write_data,
    input logic i_read_clk,
    input logic i_read_enable,
    input logic [ADDR_WIDTH-1:0] i_read_address,
    input logic i_read_overlay_hit,
    input logic i_slow_read_data,
    output logic o_read_data
);

  localparam int unsigned BankDepth = 2 ** STORAGE_ADDR_WIDTH;
  // Simulation's combined init file may contain sparse addresses anywhere in
  // the parent IMEM, so retain the full temporary image even though only the
  // low overlay prefix is copied into this bank.
  localparam int unsigned FullDepth = 2 ** (ADDR_WIDTH + 1);

  function automatic logic sideband_bit_from_word(input logic [31:0] word);
    logic [riscv_pkg::ImemSidebandWidth-1:0] sideband;
    sideband = riscv_pkg::imem_make_sideband(word);
    sideband_bit_from_word = sideband[SIDEBAND_BIT];
  endfunction

  // Declare the element as a packed [0:0] vector rather than a scalar: Vivado
  // rejects $readmemh on a memory of unpacked scalar elements.
  /* verilator lint_off MULTIDRIVEN */
  (* ram_style = "distributed" *) logic [0:0] memory[BankDepth];
  /* verilator lint_on MULTIDRIVEN */

`ifndef YOSYS
`ifndef FROST_VIVADO_SYNTH
  logic [31:0] init_mem[FullDepth];
`endif
  initial begin
    if (USE_INIT_FILE) begin
`ifdef FROST_VIVADO_SYNTH
      $readmemh(BANK_INIT_FILE, memory, 0, BankDepth - 1);
`else
      $readmemh(INIT_FILE, init_mem);
      for (int i = 0; i < BankDepth; i++) begin
        memory[i][0] = sideband_bit_from_word(init_mem[2*i+IS_ODD_BANK]);
      end
`endif
    end else begin
      for (int i = 0; i < BankDepth; i++) begin
        logic [31:0] default_word;
        default_word = 32'(2 * i + IS_ODD_BANK);
        memory[i][0] = sideband_bit_from_word(default_word);
      end
    end
  end
`endif  // YOSYS

  always_ff @(posedge i_write_clk) begin
    if (i_write_enable && ((i_write_address >> STORAGE_ADDR_WIDTH) == '0)) begin
      memory[i_write_address[STORAGE_ADDR_WIDTH-1:0]][0] <= i_write_data;
    end
  end

  // Read the LUTRAM asynchronously into a named wire, then register it locally
  // so this bank has the same output latency and read-enable hold as the
  // block-RAM banks.
  logic [0:0] memory_read_data;
  (* keep = "true" *) logic read_q;
  assign memory_read_data = memory[i_read_address[STORAGE_ADDR_WIDTH-1:0]];

  always_ff @(posedge i_read_clk) begin
    if (i_read_enable) begin
      // Select with the request captured on this edge. On a miss the flop takes
      // the predicate redecoded from the previous raw BRAM response, so a
      // request repeated for a second cycle publishes its own value on the
      // next edge.
      read_q <= i_read_overlay_hit ? memory_read_data[0] : i_slow_read_data;
    end
  end
  assign o_read_data = read_q;

endmodule : imem_sideband_scalar_bank

/*
 * Instruction memory and predecode sideband for a 64-bit fetch window.
 * Two interleaved banks provide consecutive 32-bit words, eliminating the
 * C-extension spanning penalty for PC[1]=1.
 *
 * Banks:
 *   memory_even_{cold,frontend_hot}: words 0, 2, 4, ...
 *   memory_odd_{cold,frontend_hot}:  words 1, 3, 5, ...
 *
 * Both banks read in parallel. For word index W:
 *   even W: EVEN[W>>1] = W,   ODD[W>>1] = W+1
 *   odd W:  ODD[W>>1] = W,    EVEN[(W>>1)+1] = W+1
 * Registered PC[2] swaps the outputs into {W+1, W}.
 *
 * Sideband bits stored with each word carry compression, opcode-class and
 * bundle qualifiers, plus {rs2[1], rs1[2:1]} for each RVC halfword. Definitions
 * live in riscv_pkg::imem_make_sideband, shared by L1I fill and the offline
 * generator sw/common/generate_imem_predecode_init.py.
 *
 * Each 32-bit half-depth data bank is split into 28 cold bits and four
 * frontend-hot bits {15,10,7,6}. At 32K entries per parity this remains 32
 * RAMB36 while making the four timing lanes independently placeable. A
 * five-lane block-RAM replica per parity carries the raw high-parcel bits
 * C[15], C[13], C[12], the rd==x2 predicate, and AllowsSlot2AfterHi. Every
 * sideband predicate on the IF PC feedback cone (IsCompressedLo/Hi,
 * EvenLocalPairValid, PairableNativeLo, PairableCompressedHi,
 * PairableNativeHi, and Slot2StartValidLo) has a pinned [0,16 KiB)
 * per-parity distributed-RAM overlay with an output flop, so default
 * low-memory execution avoids a RAMB36E2 clock-to-output at the head of that
 * cone. The canonical full-depth sideband block RAM remains the same-edge
 * equivalence oracle. Non-overlay windows repeat once while this module
 * redecodes their predicates into the scalar banks' existing output FFs,
 * allowing Vivado to trim canonical predicate lanes that have no hardware
 * consumer.
 *
 * Port A programs and reads on the slow clock. Its write path is registered,
 * so writes commit one port-A cycle after presentation. Port B is the
 * read-only fast-clock fetch port. Keeping fetch live during a Port-A write
 * relies on the production phase-related div4 clock: at least three Port-B
 * edges separate the staged write enable from the array commit, allowing the
 * two-flop quarantine synchronizer to land first. A different clock ratio
 * requires holding fetch externally or adding a write handshake.
 */
module imem_predecode #(
    parameter int unsigned ADDR_WIDTH = 14,
    // Per-parity word-address width of the pinned PC-metadata overlay. Eleven
    // bits per parity cover byte addresses [0, 16 KiB). Small unit-test IMEMs
    // default to full coverage and may override this parameter to exercise the
    // registered fallback.
    parameter int unsigned PC_METADATA_OVERLAY_ADDR_WIDTH = (ADDR_WIDTH > 12) ? 11 : ADDR_WIDTH - 1,
    parameter bit USE_INIT_FILE = 1'b1,
    parameter bit [47:0] INIT_FILE = "sw.mem",
    parameter bit [255:0] INIT_FILE_EVEN_COLD = "sw_imem_even_cold.mem",
    parameter bit [255:0] INIT_FILE_ODD_COLD = "sw_imem_odd_cold.mem",
    parameter bit [255:0] INIT_FILE_EVEN_FRONTEND_HOT = "sw_imem_even_frontend_hot.mem",
    parameter bit [255:0] INIT_FILE_ODD_FRONTEND_HOT = "sw_imem_odd_frontend_hot.mem",
    parameter bit [199:0] INIT_FILE_EVEN_SIDEBAND = "sw_imem_even_sideband.mem",
    parameter bit [191:0] INIT_FILE_ODD_SIDEBAND = "sw_imem_odd_sideband.mem",
    parameter bit [255:0] INIT_FILE_EVEN_COMPRESSED = "sw_imem_even_compressed.mem",
    parameter bit [255:0] INIT_FILE_ODD_COMPRESSED = "sw_imem_odd_compressed.mem",
    // One scalar LUTRAM overlay image per sideband predicate and parity bank.
    parameter bit [319:0] INIT_FILE_EVEN_IS_COMPRESSED_LO = "sw_imem_even_is_compressed_lo.mem",
    parameter bit [319:0] INIT_FILE_ODD_IS_COMPRESSED_LO = "sw_imem_odd_is_compressed_lo.mem",
    parameter bit [319:0] INIT_FILE_EVEN_IS_COMPRESSED_HI = "sw_imem_even_is_compressed_hi.mem",
    parameter bit [319:0] INIT_FILE_ODD_IS_COMPRESSED_HI = "sw_imem_odd_is_compressed_hi.mem",
    parameter bit [319:0] INIT_FILE_EVEN_EVEN_LOCAL_PAIR_VALID =
        "sw_imem_even_even_local_pair_valid.mem",
    parameter bit [319:0] INIT_FILE_ODD_EVEN_LOCAL_PAIR_VALID =
        "sw_imem_odd_even_local_pair_valid.mem",
    parameter bit [319:0] INIT_FILE_EVEN_PAIRABLE_NATIVE_LO = "sw_imem_even_pairable_native_lo.mem",
    parameter bit [319:0] INIT_FILE_ODD_PAIRABLE_NATIVE_LO = "sw_imem_odd_pairable_native_lo.mem",
    parameter bit [319:0] INIT_FILE_EVEN_PAIRABLE_COMPRESSED_HI =
        "sw_imem_even_pairable_compressed_hi.mem",
    parameter bit [319:0] INIT_FILE_ODD_PAIRABLE_COMPRESSED_HI =
        "sw_imem_odd_pairable_compressed_hi.mem",
    parameter bit [319:0] INIT_FILE_EVEN_PAIRABLE_NATIVE_HI = "sw_imem_even_pairable_native_hi.mem",
    parameter bit [319:0] INIT_FILE_ODD_PAIRABLE_NATIVE_HI = "sw_imem_odd_pairable_native_hi.mem",
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

    // Port B: Instruction fetch (fast clock), 64-bit output
    input logic i_port_b_clk,
    input logic i_port_b_enable,
    input logic [31:0] i_port_b_byte_address,
    // Byte address of the window's second aligned word (Phase 3 M5): the
    // aligned successor of word 0 with translation off or inside a page, and
    // the mapped next page's base across a page boundary. Replaces the even
    // bank's +1 address increment, so the second word can come from anywhere
    // and the address pins see no adder.
    input logic [31:0] i_port_b_next_byte_address,
    output logic [63:0] o_port_b_read_data,  // {next_word, current_word}
    output logic [riscv_pkg::ImemFetchSidebandWidth-1:0] o_port_b_sideband,
    // Consumer-local PC-advance copy, ordered like o_port_b_read_data. Each
    // word is {pairable_native_hi, pairable_compressed_hi,
    //          compressed_hi, compressed_lo}, so the complete window is
    // {next_word[3:0], current_word[3:0]}.
    output logic [7:0] o_port_b_pc_metadata,
    // Raw low-BRAM timing copies, kept in physical bank order instead of
    // passing through the {next,current} swap above. The IF PC consumer can
    // select the architectural current/next words directly from pc_reg[2],
    // eliminating two cancelling parity muxes from the IMEM-to-PC path.
    // These ports are meaningful for this low-BRAM provider only and launch
    // from the scalar banks' output flops, fed by overlay or slow redecode.
    // The response-ready flag tells the parent when these lanes align with the
    // raw payload; the companion overlay-hit flag distinguishes their latency.
    output logic [7:0] o_port_b_pc_metadata_by_parity,  // {odd[3:0], even[3:0]}
    // The two remaining word-local pairability predicates used by live PC
    // advance, in {odd[native-lo,even-local], even[native-lo,even-local]}
    // order.
    output logic [3:0] o_port_b_pc_pairability_by_parity,
    output logic [1:0] o_port_b_slot2_start_valid_lo_by_parity,  // {odd, even}
    // Registered with the raw BRAM response. Both physical word addresses
    // must lie in the pinned overlay; mixed boundary windows are slow.
    output logic o_port_b_window_overlay_hit,
    // A hit is ready after the normal one-cycle memory read. A miss becomes
    // ready only after the same complete physical-address pair is presented
    // for a second cycle, aligning the raw payload with slow predicate FFs.
    output logic o_port_b_response_ready,
    // Per-word high-parcel predicate, ordered like o_port_b_read_data:
    // {next_word[27:23] == x2, current_word[27:23] == x2}.
    output logic [1:0] o_port_b_hi_rd_is_x2,
    output logic o_port_b_bank_sel_r  // Registered fetch-word parity (PC[2] from fetch cycle)
);

  localparam int unsigned DataWidth = 32;
  localparam int unsigned ColdDataWidth = 28;
  localparam int unsigned FrontendHotWidth = 4;
  localparam int unsigned SidebandWidth = riscv_pkg::ImemSidebandWidth;
  localparam int unsigned HalfDepth = 2 ** (ADDR_WIDTH - 1);
  localparam int unsigned FullDepth = 2 ** ADDR_WIDTH;
  localparam int unsigned ByteAddrBits = 2;  // 32-bit word alignment
  // Lane order of the narrow high-parcel block RAM (the legacy *_compressed
  // name predates the move of the size bits to the scalar LUTRAM overlay).
  localparam int unsigned FastLaneHiRdIsX2 = 0;  // word[27:23] == 5'd2
  localparam int unsigned FastLaneC15 = 1;  // word[31]
  localparam int unsigned FastLaneC12 = 2;  // word[28]
  localparam int unsigned FastLaneC13 = 3;  // word[29]
  localparam int unsigned FastLaneAllowsSlot2AfterHi = 4;
  localparam int unsigned FastLaneWidth = 5;

  function automatic logic pc_metadata_overlay_contains(input logic [31:0] byte_address);
    // One parity row covers two 32-bit words, hence the three low byte-address
    // bits below the scalar bank's stored row index.
    pc_metadata_overlay_contains = (byte_address >> (PC_METADATA_OVERLAY_ADDR_WIDTH + 3)) == '0;
  endfunction

`ifndef SYNTHESIS
  initial begin
    p_pc_metadata_overlay_width_valid :
    assert (PC_METADATA_OVERLAY_ADDR_WIDTH > 0 && PC_METADATA_OVERLAY_ADDR_WIDTH <= ADDR_WIDTH - 1);
  end
`endif

  // The hot order is fixed end-to-end, including the offline init files:
  //   hot[3:0] = {word[15], word[10], word[7], word[6]}.
  // Cold packs the remaining bits in architectural order. These are pure
  // rewires, so splitting/rejoining adds no logic level or interface latency.
  // Assign to the function name instead of using `return`: yosys 0.64's
  // Verilog frontend does not parse return statements (same convention as
  // riscv_pkg::imem_make_sideband and the rest of the RTL).
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

  function automatic logic [FastLaneWidth-1:0] pack_fast_lanes(
      input logic [DataWidth-1:0] word, input logic [SidebandWidth-1:0] sideband);
    pack_fast_lanes = {
      sideband[riscv_pkg::ImemSbAllowsSlot2AfterHi], word[29:28], word[31], word[27:23] == 5'd2
    };
  endfunction

  // =========================================================================
  // Even/odd interleaved memory banks
  // =========================================================================
  // The even pair holds the word whose full word-index is 2*k.
  // The odd pair holds the word whose full word-index is 2*k+1.
  /* verilator lint_off MULTIDRIVEN */
  (* ram_style = "block" *) logic [ColdDataWidth-1:0] memory_even_cold[HalfDepth];
  (* ram_style = "block" *) logic [ColdDataWidth-1:0] memory_odd_cold[HalfDepth];
  // Keep the timing-facing four-bit slices distinct from the cold arrays.
  // Their 32Kx4 shape maps to four RAMB36 per parity bank (32K depth caps a
  // RAMB36 at 32Kx1).
  (* ram_style = "block", keep = "true", dont_touch = "yes" *)
  logic [FrontendHotWidth-1:0] memory_even_frontend_hot[HalfDepth];
  (* ram_style = "block", keep = "true", dont_touch = "yes" *)
  logic [FrontendHotWidth-1:0] memory_odd_frontend_hot[HalfDepth];
  // Keep the full-depth predecode sideband in BRAM. LUTRAM looked attractive for size,
  // but on X3 it spreads the sideband arrays across fabric and puts pc_reg on
  // a long distributed-memory address route in the low-BRAM fetch path. The
  // six source-hot bits widen these arrays without adding another memory read
  // or pipeline stage.
  (* ram_style = "block" *) logic [SidebandWidth-1:0] memory_even_sideband[HalfDepth];
  (* ram_style = "block" *) logic [SidebandWidth-1:0] memory_odd_sideband[HalfDepth];
  // Mirror the high-parcel allows-slot-2 predicate, the high-parcel RVC
  // rd==x2 predicate, and raw high-parcel bits C[15], C[13], and C[12]
  // (word[31], word[29], and word[28]) in dedicated block-RAM banks. They are
  // read at the same fetch edge as the other BRAM banks, so the interface
  // latency is unchanged. Keeping them distinct preserves independent
  // placement of these timing-facing launches. The legacy *_compressed.mem
  // filenames contain the packed five-bit value {allows_slot2_after_hi,
  // word[29], word[28], word[31], word[27:23] == 5'd2}; the instruction-size
  // bits moved to the pinned scalar LUTRAM overlay below. At the current 32K
  // entries per parity bank, each bit maps to one RAMB36.
  (* ram_style = "block", keep = "true", dont_touch = "yes" *)
  logic [FastLaneWidth-1:0] memory_even_compressed[HalfDepth];
  (* ram_style = "block", keep = "true", dont_touch = "yes" *)
  logic [FastLaneWidth-1:0] memory_odd_compressed[HalfDepth];
  /* verilator lint_on MULTIDRIVEN */

  // =========================================================================
  // Initialization: split sw.mem into even/odd banks
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
      $readmemh(INIT_FILE_EVEN_COLD, memory_even_cold);
      $readmemh(INIT_FILE_ODD_COLD, memory_odd_cold);
      $readmemh(INIT_FILE_EVEN_FRONTEND_HOT, memory_even_frontend_hot);
      $readmemh(INIT_FILE_ODD_FRONTEND_HOT, memory_odd_frontend_hot);
      $readmemh(INIT_FILE_EVEN_SIDEBAND, memory_even_sideband);
      $readmemh(INIT_FILE_ODD_SIDEBAND, memory_odd_sideband);
      $readmemh(INIT_FILE_EVEN_COMPRESSED, memory_even_compressed);
      $readmemh(INIT_FILE_ODD_COMPRESSED, memory_odd_compressed);
`else
      $readmemh(INIT_FILE, init_mem);
      for (int i = 0; i < FullDepth; i++) begin
        if (i[0] == 1'b0) begin
          memory_even_cold[i>>1] = pack_cold_data(init_mem[i]);
          memory_even_frontend_hot[i>>1] = pack_frontend_hot(init_mem[i]);
          memory_even_sideband[i>>1] = riscv_pkg::imem_make_sideband(init_mem[i]);
          memory_even_compressed[i>>1] = pack_fast_lanes(init_mem[i], memory_even_sideband[i>>1]);
        end else begin
          memory_odd_cold[i>>1] = pack_cold_data(init_mem[i]);
          memory_odd_frontend_hot[i>>1] = pack_frontend_hot(init_mem[i]);
          memory_odd_sideband[i>>1] = riscv_pkg::imem_make_sideband(init_mem[i]);
          memory_odd_compressed[i>>1] = pack_fast_lanes(init_mem[i], memory_odd_sideband[i>>1]);
        end
      end
`endif
    end else begin
      for (int i = 0; i < HalfDepth; i++) begin
        logic [DataWidth-1:0] even_default_word;
        logic [DataWidth-1:0] odd_default_word;
        even_default_word = DataWidth'(2 * i);
        odd_default_word = DataWidth'(2 * i + 1);
        memory_even_cold[i] = pack_cold_data(even_default_word);
        memory_odd_cold[i] = pack_cold_data(odd_default_word);
        memory_even_frontend_hot[i] = pack_frontend_hot(even_default_word);
        memory_odd_frontend_hot[i] = pack_frontend_hot(odd_default_word);
        memory_even_sideband[i] = riscv_pkg::imem_make_sideband(even_default_word);
        memory_odd_sideband[i] = riscv_pkg::imem_make_sideband(odd_default_word);
        memory_even_compressed[i] = pack_fast_lanes(even_default_word, memory_even_sideband[i]);
        memory_odd_compressed[i] = pack_fast_lanes(odd_default_word, memory_odd_sideband[i]);
      end
    end
  end
`endif  // YOSYS

  // =========================================================================
  // Port A: Programming interface (write to one bank per cycle)
  // =========================================================================
  // The value a fetch reads when it collides with a programming write to the
  // same address is unspecified. The supported Xilinx load flow arms
  // image_load_reset on every bulk programming write and keeps rearming it
  // through the transfer. Live debug-slice rewrites are also safe to fetch:
  // the response-ready quarantine below hides the collision and the
  // bank-realignment interval that follows it, then forces a fresh post-write
  // response.
  //
  // For routability the write side is registered once before it fans out to
  // the independent memory banks. The staged copies below keep their
  // max_fanout shaping and the programming-side contract of one extra
  // div4-clock cycle of write latency on a JTAG-paced port. The synthesized
  // readback is a pass-through, so the read-latency contract is unchanged.
  logic [ADDR_WIDTH-1:0] port_a_word_address;
  logic [ADDR_WIDTH-2:0] port_a_half_address;
  logic                  port_a_bank_sel;  // 0 = even, 1 = odd

  assign port_a_word_address = i_port_a_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_a_half_address = port_a_word_address[ADDR_WIDTH-1:1];
  assign port_a_bank_sel     = port_a_word_address[0];

  (* max_fanout = 512 *) logic [ADDR_WIDTH-2:0] port_a_half_address_q;
  (* max_fanout = 512 *) logic [DataWidth-1:0] port_a_write_data_q;
  (* max_fanout = 512 *) logic port_a_write_even_q = 1'b0;
  (* max_fanout = 512 *) logic port_a_write_odd_q = 1'b0;

  // The debug module can rewrite its out-of-overlay execution slice while the
  // fetch port keeps presenting that same address. The canonical BRAM response
  // observes the new word one read before the registered slow scalar fallback,
  // so the repeated-address history must be invalidated across every live
  // programming write. The staged write enables rise a complete div4 cycle
  // before their arrays commit, which gives this two-flop fetch-clock
  // synchronizer time to quarantine readiness before any bank can change.
  (* ASYNC_REG = "TRUE" *) logic [1:0] port_a_write_active_sync_q = 2'b00;
  logic port_a_write_quarantine;
  always_ff @(posedge i_port_b_clk) begin
    port_a_write_active_sync_q <= {
      port_a_write_active_sync_q[0], port_a_write_even_q || port_a_write_odd_q
    };
  end
  // Only the second stage drives functional logic; stage 0 is the
  // metastability-catching flop.
  assign port_a_write_quarantine = port_a_write_active_sync_q[1];

  always_ff @(posedge i_port_a_clk) begin
    port_a_half_address_q <= port_a_half_address;
    port_a_write_data_q   <= i_port_a_write_data;
    port_a_write_even_q   <= i_port_a_enable && i_port_a_write_enable && !port_a_bank_sel;
    port_a_write_odd_q    <= i_port_a_enable && i_port_a_write_enable && port_a_bank_sel;
  end

  // Compute sideband from the staged write data at write time.
  logic [SidebandWidth-1:0] write_sideband;
  assign write_sideband = riscv_pkg::imem_make_sideband(port_a_write_data_q);

  // Port A: even bank
  always_ff @(posedge i_port_a_clk) begin
    if (port_a_write_even_q) begin
      memory_even_cold[port_a_half_address_q] <= pack_cold_data(port_a_write_data_q);
      memory_even_frontend_hot[port_a_half_address_q] <= pack_frontend_hot(port_a_write_data_q);
      memory_even_sideband[port_a_half_address_q] <= write_sideband;
      memory_even_compressed[port_a_half_address_q] <= pack_fast_lanes(
          port_a_write_data_q, write_sideband
      );
    end
  end

  // Port A: odd bank
  always_ff @(posedge i_port_a_clk) begin
    if (port_a_write_odd_q) begin
      memory_odd_cold[port_a_half_address_q] <= pack_cold_data(port_a_write_data_q);
      memory_odd_frontend_hot[port_a_half_address_q] <= pack_frontend_hot(port_a_write_data_q);
      memory_odd_sideband[port_a_half_address_q] <= write_sideband;
      memory_odd_compressed[port_a_half_address_q] <= pack_fast_lanes(
          port_a_write_data_q, write_sideband
      );
    end
  end

`ifndef SYNTHESIS
  // Port A read (write-first): read back from whichever bank was addressed
  always_ff @(posedge i_port_a_clk) begin
    if (i_port_a_enable) begin
      if (i_port_a_write_enable) begin
        o_port_a_read_data <= i_port_a_write_data;
      end else begin
        o_port_a_read_data <= port_a_bank_sel ? join_data_banks(
            memory_odd_cold[port_a_half_address], memory_odd_frontend_hot[port_a_half_address]) :
            join_data_banks(memory_even_cold[port_a_half_address],
                            memory_even_frontend_hot[port_a_half_address]);
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
  logic [SidebandWidth-1:0] even_sideband, odd_sideband;
  logic [FastLaneWidth-1:0] even_compressed;
  logic [FastLaneWidth-1:0] odd_compressed;
  // Timing metadata launches only from the scalar banks' fabric FFs. Each FF
  // captures its overlay bit on a hit or a reconstructed slow bit on a miss.
  logic even_is_compressed_lo, odd_is_compressed_lo;
  logic even_is_compressed_hi, odd_is_compressed_hi;
  logic even_even_local_pair_valid, odd_even_local_pair_valid;
  logic even_pairable_native_lo, odd_pairable_native_lo;
  logic even_pairable_compressed_hi, odd_pairable_compressed_hi;
  logic even_pairable_native_hi, odd_pairable_native_hi;
  logic even_slot2_start_valid_lo, odd_slot2_start_valid_lo;
  logic [SidebandWidth-1:0] even_sideband_redecoded;
  logic [SidebandWidth-1:0] odd_sideband_redecoded;
  logic pc_metadata_overlay_window_hit;
  logic pc_metadata_overlay_window_hit_q = 1'b0;
  logic pc_metadata_response_ready_q = 1'b0;
  logic pc_metadata_response_history_valid_q = 1'b0;
  logic [31:0] pc_metadata_response_address_q;
  logic [31:0] pc_metadata_response_next_address_q;
  logic [3:0] even_pc_metadata;
  logic [3:0] odd_pc_metadata;

  assign pc_metadata_overlay_window_hit = pc_metadata_overlay_contains(
      i_port_b_byte_address
  ) && pc_metadata_overlay_contains(
      i_port_b_next_byte_address
  );

  // Every scalar overlay bank shares the low slice of its parity's staged
  // programming write and fetch address. Writes outside the pinned region are
  // ignored. Two instances per predicate keep odd and even launches
  // independently placeable.
  (* dont_touch = "yes" *)
  imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbIsCompressedLo),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_EVEN_IS_COMPRESSED_LO),
      .IS_ODD_BANK(1'b0)
  ) u_even_is_compressed_lo_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbIsCompressedLo]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(even_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(even_sideband_redecoded[riscv_pkg::ImemSbIsCompressedLo]),
      .o_read_data(even_is_compressed_lo)
  );

  (* dont_touch = "yes" *) imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbIsCompressedLo),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_ODD_IS_COMPRESSED_LO),
      .IS_ODD_BANK(1'b1)
  ) u_odd_is_compressed_lo_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbIsCompressedLo]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(odd_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(odd_sideband_redecoded[riscv_pkg::ImemSbIsCompressedLo]),
      .o_read_data(odd_is_compressed_lo)
  );

  (* dont_touch = "yes" *) imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbIsCompressedHi),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_EVEN_IS_COMPRESSED_HI),
      .IS_ODD_BANK(1'b0)
  ) u_even_is_compressed_hi_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbIsCompressedHi]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(even_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(even_sideband_redecoded[riscv_pkg::ImemSbIsCompressedHi]),
      .o_read_data(even_is_compressed_hi)
  );

  (* dont_touch = "yes" *) imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbIsCompressedHi),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_ODD_IS_COMPRESSED_HI),
      .IS_ODD_BANK(1'b1)
  ) u_odd_is_compressed_hi_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbIsCompressedHi]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(odd_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(odd_sideband_redecoded[riscv_pkg::ImemSbIsCompressedHi]),
      .o_read_data(odd_is_compressed_hi)
  );

  (* dont_touch = "yes" *) imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbEvenLocalPairValid),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_EVEN_EVEN_LOCAL_PAIR_VALID),
      .IS_ODD_BANK(1'b0)
  ) u_even_even_local_pair_valid_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbEvenLocalPairValid]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(even_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(even_sideband_redecoded[riscv_pkg::ImemSbEvenLocalPairValid]),
      .o_read_data(even_even_local_pair_valid)
  );

  (* dont_touch = "yes" *) imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbEvenLocalPairValid),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_ODD_EVEN_LOCAL_PAIR_VALID),
      .IS_ODD_BANK(1'b1)
  ) u_odd_even_local_pair_valid_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbEvenLocalPairValid]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(odd_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(odd_sideband_redecoded[riscv_pkg::ImemSbEvenLocalPairValid]),
      .o_read_data(odd_even_local_pair_valid)
  );

  (* dont_touch = "yes" *) imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbPairableNativeLo),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_EVEN_PAIRABLE_NATIVE_LO),
      .IS_ODD_BANK(1'b0)
  ) u_even_pairable_native_lo_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbPairableNativeLo]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(even_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(even_sideband_redecoded[riscv_pkg::ImemSbPairableNativeLo]),
      .o_read_data(even_pairable_native_lo)
  );

  (* dont_touch = "yes" *) imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbPairableNativeLo),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_ODD_PAIRABLE_NATIVE_LO),
      .IS_ODD_BANK(1'b1)
  ) u_odd_pairable_native_lo_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbPairableNativeLo]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(odd_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(odd_sideband_redecoded[riscv_pkg::ImemSbPairableNativeLo]),
      .o_read_data(odd_pairable_native_lo)
  );

  (* dont_touch = "yes" *) imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbPairableCompressedHi),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_EVEN_PAIRABLE_COMPRESSED_HI),
      .IS_ODD_BANK(1'b0)
  ) u_even_pairable_compressed_hi_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbPairableCompressedHi]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(even_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(even_sideband_redecoded[riscv_pkg::ImemSbPairableCompressedHi]),
      .o_read_data(even_pairable_compressed_hi)
  );

  (* dont_touch = "yes" *) imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbPairableCompressedHi),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_ODD_PAIRABLE_COMPRESSED_HI),
      .IS_ODD_BANK(1'b1)
  ) u_odd_pairable_compressed_hi_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbPairableCompressedHi]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(odd_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(odd_sideband_redecoded[riscv_pkg::ImemSbPairableCompressedHi]),
      .o_read_data(odd_pairable_compressed_hi)
  );

  (* dont_touch = "yes" *) imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbPairableNativeHi),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_EVEN_PAIRABLE_NATIVE_HI),
      .IS_ODD_BANK(1'b0)
  ) u_even_pairable_native_hi_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbPairableNativeHi]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(even_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(even_sideband_redecoded[riscv_pkg::ImemSbPairableNativeHi]),
      .o_read_data(even_pairable_native_hi)
  );

  (* dont_touch = "yes" *) imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbPairableNativeHi),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_ODD_PAIRABLE_NATIVE_HI),
      .IS_ODD_BANK(1'b1)
  ) u_odd_pairable_native_hi_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbPairableNativeHi]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(odd_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(odd_sideband_redecoded[riscv_pkg::ImemSbPairableNativeHi]),
      .o_read_data(odd_pairable_native_hi)
  );

  (* dont_touch = "yes" *) imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbSlot2StartValidLo),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_EVEN_SLOT2_START_VALID_LO),
      .IS_ODD_BANK(1'b0)
  ) u_even_slot2_start_valid_lo_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbSlot2StartValidLo]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(even_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(even_sideband_redecoded[riscv_pkg::ImemSbSlot2StartValidLo]),
      .o_read_data(even_slot2_start_valid_lo)
  );

  (* dont_touch = "yes" *) imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbSlot2StartValidLo),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .BANK_INIT_FILE(INIT_FILE_ODD_SLOT2_START_VALID_LO),
      .IS_ODD_BANK(1'b1)
  ) u_odd_slot2_start_valid_lo_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd_q),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband[riscv_pkg::ImemSbSlot2StartValidLo]),
      .i_read_clk(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(odd_read_addr),
      .i_read_overlay_hit(pc_metadata_overlay_window_hit),
      .i_slow_read_data(odd_sideband_redecoded[riscv_pkg::ImemSbSlot2StartValidLo]),
      .o_read_data(odd_slot2_start_valid_lo)
  );

  assign even_pc_metadata = {
    even_pairable_native_hi,
    even_pairable_compressed_hi,
    even_is_compressed_hi,
    even_is_compressed_lo
  };
  assign odd_pc_metadata = {
    odd_pairable_native_hi, odd_pairable_compressed_hi, odd_is_compressed_hi, odd_is_compressed_lo
  };

  always_ff @(posedge i_port_b_clk) begin
    if (i_port_b_enable) begin
      even_read_data_cold <= memory_even_cold[even_read_addr];
      odd_read_data_cold <= memory_odd_cold[odd_read_addr];
      even_read_data_frontend_hot <= memory_even_frontend_hot[even_read_addr];
      odd_read_data_frontend_hot <= memory_odd_frontend_hot[odd_read_addr];
      even_sideband <= memory_even_sideband[even_read_addr];
      odd_sideband <= memory_odd_sideband[odd_read_addr];
      even_compressed <= memory_even_compressed[even_read_addr];
      odd_compressed <= memory_odd_compressed[odd_read_addr];
    end
  end

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
  logic [SidebandWidth-1:0] current_sideband, next_sideband;
  logic [SidebandWidth-1:0] even_sideband_with_fast_metadata;
  logic [SidebandWidth-1:0] odd_sideband_with_fast_metadata;
  always_comb begin
    even_read_data_with_fast_rvc_fields = even_read_data;
    odd_read_data_with_fast_rvc_fields = odd_read_data;
    even_read_data_with_fast_rvc_fields[31] = even_compressed[FastLaneC15];
    odd_read_data_with_fast_rvc_fields[31] = odd_compressed[FastLaneC15];
    even_read_data_with_fast_rvc_fields[29:28] = even_compressed[FastLaneC13:FastLaneC12];
    odd_read_data_with_fast_rvc_fields[29:28] = odd_compressed[FastLaneC13:FastLaneC12];
    // The public sideband lanes on the IF PC feedback cone always take the
    // scalar banks' overlay/slow output FFs. The pairability predicates are
    // fully evaluated at init/write time before they are stored in the
    // overlay, so no post-read conjunction enters the fast IF PC cone.
    even_sideband_with_fast_metadata = even_sideband;
    odd_sideband_with_fast_metadata = odd_sideband;
    even_sideband_with_fast_metadata[1:0] = even_pc_metadata[1:0];
    odd_sideband_with_fast_metadata[1:0] = odd_pc_metadata[1:0];
    even_sideband_with_fast_metadata[riscv_pkg::ImemSbEvenLocalPairValid] =
        even_even_local_pair_valid;
    odd_sideband_with_fast_metadata[riscv_pkg::ImemSbEvenLocalPairValid] =
        odd_even_local_pair_valid;
    even_sideband_with_fast_metadata[riscv_pkg::ImemSbPairableNativeLo] = even_pairable_native_lo;
    odd_sideband_with_fast_metadata[riscv_pkg::ImemSbPairableNativeLo] = odd_pairable_native_lo;
    even_sideband_with_fast_metadata[riscv_pkg::ImemSbAllowsSlot2AfterHi] =
        even_compressed[FastLaneAllowsSlot2AfterHi];
    odd_sideband_with_fast_metadata[riscv_pkg::ImemSbAllowsSlot2AfterHi] =
        odd_compressed[FastLaneAllowsSlot2AfterHi];
    even_sideband_with_fast_metadata[riscv_pkg::ImemSbPairableCompressedHi] = even_pc_metadata[2];
    odd_sideband_with_fast_metadata[riscv_pkg::ImemSbPairableCompressedHi] = odd_pc_metadata[2];
    even_sideband_with_fast_metadata[riscv_pkg::ImemSbPairableNativeHi] = even_pc_metadata[3];
    odd_sideband_with_fast_metadata[riscv_pkg::ImemSbPairableNativeHi] = odd_pc_metadata[3];
    even_sideband_with_fast_metadata[riscv_pkg::ImemSbSlot2StartValidLo] =
        even_slot2_start_valid_lo;
    odd_sideband_with_fast_metadata[riscv_pkg::ImemSbSlot2StartValidLo] = odd_slot2_start_valid_lo;
  end

  // The slow fallback never reads the seven canonical predicate lanes. It
  // redecodes them from the fully reconstructed words, then each scalar bank
  // captures its predicate in the same output FF used by the overlay. The
  // next presentation of the same ordered physical-address pair aligns those
  // FFs with the ordinary raw BRAM payload and noncritical sideband. Decode
  // from the reconstructed words so that C[15], C[13], and C[12] keep coming
  // from their narrow timing banks instead of reviving the cold-data lanes.
  assign even_sideband_redecoded = riscv_pkg::imem_make_sideband(
      even_read_data_with_fast_rvc_fields
  );
  assign odd_sideband_redecoded = riscv_pkg::imem_make_sideband(odd_read_data_with_fast_rvc_fields);

  // Qualify the pinned overlay by the complete physical byte addresses
  // captured for this response. Requiring both words makes a boundary window
  // entirely slow and also prevents high addresses that alias the finite IMEM
  // address pins from being mistaken for overlay hits. The wide equality is
  // captured here; publish-valid sees only response_ready_q.
  always_ff @(posedge i_port_b_clk) begin
    if (port_a_write_quarantine) begin
      // A live instruction-memory rewrite invalidates both the raw payload and
      // the slow scalar fallback associated with the repeated address. Withhold
      // every response until the write has committed and a fresh post-write
      // address history has been rebuilt.
      pc_metadata_overlay_window_hit_q <= 1'b0;
      pc_metadata_response_ready_q <= 1'b0;
      pc_metadata_response_history_valid_q <= 1'b0;
    end else if (i_port_b_enable) begin
      pc_metadata_overlay_window_hit_q <= pc_metadata_overlay_window_hit;
      pc_metadata_response_ready_q <= pc_metadata_overlay_window_hit ||
          (pc_metadata_response_history_valid_q &&
             i_port_b_byte_address == pc_metadata_response_address_q &&
             i_port_b_next_byte_address == pc_metadata_response_next_address_q);
      pc_metadata_response_history_valid_q <= 1'b1;
      pc_metadata_response_address_q <= i_port_b_byte_address;
      pc_metadata_response_next_address_q <= i_port_b_next_byte_address;
    end else begin
      // A disabled read can bracket programming or another discontinuity.
      // Force the next miss to rebuild its fallback predicates instead of
      // accepting a stale same-address comparison.
      pc_metadata_response_history_valid_q <= 1'b0;
    end
  end

  assign current_word_wide   = bank_sel_r ? odd_read_data_with_fast_rvc_fields :
                                           even_read_data_with_fast_rvc_fields;
  assign next_word_wide = bank_sel_r ? even_read_data_with_fast_rvc_fields :
                                       odd_read_data_with_fast_rvc_fields;
  assign current_sideband    = bank_sel_r ? odd_sideband_with_fast_metadata :
                                           even_sideband_with_fast_metadata;
  assign next_sideband       = bank_sel_r ? even_sideband_with_fast_metadata :
                                           odd_sideband_with_fast_metadata;

  assign o_port_b_read_data = {next_word_wide, current_word_wide};
  assign o_port_b_sideband = {next_sideband, current_sideband};
  assign o_port_b_pc_metadata = bank_sel_r ?
      {even_pc_metadata, odd_pc_metadata} : {odd_pc_metadata, even_pc_metadata};
  assign o_port_b_pc_metadata_by_parity = {odd_pc_metadata, even_pc_metadata};
  assign o_port_b_pc_pairability_by_parity = {
    odd_pairable_native_lo,
    odd_even_local_pair_valid,
    even_pairable_native_lo,
    even_even_local_pair_valid
  };
  assign o_port_b_slot2_start_valid_lo_by_parity = {
    odd_slot2_start_valid_lo, even_slot2_start_valid_lo
  };
  assign o_port_b_window_overlay_hit = pc_metadata_overlay_window_hit_q;
  assign o_port_b_response_ready = pc_metadata_response_ready_q;
  assign o_port_b_hi_rd_is_x2 = bank_sel_r ?
      {even_compressed[FastLaneHiRdIsX2], odd_compressed[FastLaneHiRdIsX2]} :
      {odd_compressed[FastLaneHiRdIsX2], even_compressed[FastLaneHiRdIsX2]};
  assign o_port_b_bank_sel_r = bank_sel_r;

`ifndef SYNTHESIS
  // Every overlay row is written and fetched with its parent instruction word.
  // On every ready response the canonical sideband and data banks are
  // same-edge oracles, so an init/write-path change cannot let either the
  // fast overlay or the slow registered view diverge unnoticed. An unready
  // miss may hold stale slow predicates, so the compare skips it.
  logic pc_metadata_compare_valid_q = 1'b0;
  always_ff @(posedge i_port_b_clk) begin
    pc_metadata_compare_valid_q <= i_port_b_enable;
  end

  always_comb begin
    if (pc_metadata_compare_valid_q && pc_metadata_response_ready_q && !$isunknown(
            {
              even_read_data,
              odd_read_data,
              even_sideband,
              odd_sideband,
              even_compressed,
              odd_compressed,
              even_pc_metadata,
              odd_pc_metadata,
              even_even_local_pair_valid,
              odd_even_local_pair_valid,
              even_pairable_native_lo,
              odd_pairable_native_lo,
              even_slot2_start_valid_lo,
              odd_slot2_start_valid_lo
            }
        )) begin
      p_even_fast_c15_matches_bram : assert (even_compressed[FastLaneC15] == even_read_data[31]);
      p_odd_fast_c15_matches_bram : assert (odd_compressed[FastLaneC15] == odd_read_data[31]);
      p_even_fast_c13_c12_matches_bram :
      assert (even_compressed[FastLaneC13:FastLaneC12] == even_read_data[29:28]);
      p_odd_fast_c13_c12_matches_bram :
      assert (odd_compressed[FastLaneC13:FastLaneC12] == odd_read_data[29:28]);
      p_even_fast_hi_rd_is_x2_matches_bram :
      assert (even_compressed[FastLaneHiRdIsX2] == (even_read_data[27:23] == 5'd2));
      p_odd_fast_hi_rd_is_x2_matches_bram :
      assert (odd_compressed[FastLaneHiRdIsX2] == (odd_read_data[27:23] == 5'd2));
      p_even_fast_allows_slot2_after_hi_matches_bram :
      assert (even_compressed[FastLaneAllowsSlot2AfterHi] ==
              even_sideband[riscv_pkg::ImemSbAllowsSlot2AfterHi]);
      p_odd_fast_allows_slot2_after_hi_matches_bram :
      assert (odd_compressed[FastLaneAllowsSlot2AfterHi] ==
              odd_sideband[riscv_pkg::ImemSbAllowsSlot2AfterHi]);
      p_even_pc_metadata_matches_canonical :
      assert (even_pc_metadata == {
        even_sideband[riscv_pkg::ImemSbPairableNativeHi],
        even_sideband[riscv_pkg::ImemSbPairableCompressedHi],
        even_sideband[riscv_pkg::ImemSbIsCompressedHi],
        even_sideband[riscv_pkg::ImemSbIsCompressedLo]
      });
      p_odd_pc_metadata_matches_canonical :
      assert (odd_pc_metadata == {
        odd_sideband[riscv_pkg::ImemSbPairableNativeHi],
        odd_sideband[riscv_pkg::ImemSbPairableCompressedHi],
        odd_sideband[riscv_pkg::ImemSbIsCompressedHi],
        odd_sideband[riscv_pkg::ImemSbIsCompressedLo]
      });
      p_even_pc_pairable_compressed_hi_matches_fast_fields :
      assert ((even_pc_metadata[1] && even_compressed[FastLaneAllowsSlot2AfterHi]) ==
              even_pc_metadata[2]);
      p_odd_pc_pairable_compressed_hi_matches_fast_fields :
      assert ((odd_pc_metadata[1] && odd_compressed[FastLaneAllowsSlot2AfterHi]) ==
              odd_pc_metadata[2]);
      p_even_pc_pairable_native_hi_matches_fast_fields :
      assert ((!even_pc_metadata[1] && even_compressed[FastLaneAllowsSlot2AfterHi]) ==
              even_pc_metadata[3]);
      p_odd_pc_pairable_native_hi_matches_fast_fields :
      assert ((!odd_pc_metadata[1] && odd_compressed[FastLaneAllowsSlot2AfterHi]) ==
              odd_pc_metadata[3]);
      p_even_even_local_pair_valid_matches_bram :
      assert (even_even_local_pair_valid == even_sideband[riscv_pkg::ImemSbEvenLocalPairValid]);
      p_odd_even_local_pair_valid_matches_bram :
      assert (odd_even_local_pair_valid == odd_sideband[riscv_pkg::ImemSbEvenLocalPairValid]);
      p_even_pairable_native_lo_matches_bram :
      assert (even_pairable_native_lo == even_sideband[riscv_pkg::ImemSbPairableNativeLo]);
      p_odd_pairable_native_lo_matches_bram :
      assert (odd_pairable_native_lo == odd_sideband[riscv_pkg::ImemSbPairableNativeLo]);
      p_even_slot2_start_valid_lo_matches_bram :
      assert (even_slot2_start_valid_lo == even_sideband[riscv_pkg::ImemSbSlot2StartValidLo]);
      p_odd_slot2_start_valid_lo_matches_bram :
      assert (odd_slot2_start_valid_lo == odd_sideband[riscv_pkg::ImemSbSlot2StartValidLo]);
      p_pc_metadata_parity_port_matches_banks :
      assert (o_port_b_pc_metadata_by_parity == {odd_pc_metadata, even_pc_metadata});
      p_pc_pairability_parity_port_matches_banks :
      assert (o_port_b_pc_pairability_by_parity == {
        odd_pairable_native_lo,
        odd_even_local_pair_valid,
        even_pairable_native_lo,
        even_even_local_pair_valid
      });
      p_slot2_start_valid_lo_parity_port_matches_banks :
      assert (o_port_b_slot2_start_valid_lo_by_parity == {
        odd_slot2_start_valid_lo, even_slot2_start_valid_lo
      });
    end
  end
`endif

endmodule : imem_predecode
