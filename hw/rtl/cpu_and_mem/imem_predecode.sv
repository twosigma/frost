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
 * LUTRAM overlay of one IMEM predicate for one parity bank, in an
 * sdp_dist_ram_init. The default range is [0, 64 KiB). Its registered output
 * matches the BRAM read latency and enable hold. Outside the overlay, it
 * captures a predicate redecoded from the previous BRAM response; the caller
 * repeats the request (imem_predecode withholds ready until the predicates
 * line up).
 *
 * keep_hierarchy preserves independently placeable copies. All banks use the
 * same staged programming writes. The parent withholds fetch readiness around
 * writes because the slow fallback trails the BRAM response by one cycle.
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
    // Word-address width of INIT_FILE's image (the parent's INIT_ADDR_WIDTH).
    parameter int unsigned INIT_ADDR_WIDTH = ADDR_WIDTH + 1,
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
  // the low BRAM image, so retain the full temporary image even though only
  // the low overlay prefix is copied into this bank.
  localparam int unsigned FullDepth = 2 ** INIT_ADDR_WIDTH;

  function automatic logic sideband_bit_from_word(input logic [31:0] word);
    logic [riscv_pkg::ImemSidebandWidth-1:0] sideband;
    sideband = riscv_pkg::imem_make_sideband(word);
    sideband_bit_from_word = sideband[SIDEBAND_BIT];
  endfunction

  // Vivado loads the bank's image (BANK_INIT_FILE); simulation fills the
  // array from INIT_FILE below, and Yosys leaves it without initial contents.
`ifdef FROST_VIVADO_SYNTH
  localparam bit LoadBankImage = USE_INIT_FILE;
`else
  localparam bit LoadBankImage = 1'b0;
`endif

  // Writes outside the overlay are ignored.
  logic [0:0] memory_read_data;
  sdp_dist_ram_init #(
      .ADDR_WIDTH(STORAGE_ADDR_WIDTH),
      .DATA_WIDTH(1),
      .USE_INIT_FILE(LoadBankImage),
      .INIT_FILE(BANK_INIT_FILE)
  ) u_ram (
      .i_clk(i_write_clk),
      .i_write_enable(i_write_enable && ((i_write_address >> STORAGE_ADDR_WIDTH) == '0)),
      .i_write_address(i_write_address[STORAGE_ADDR_WIDTH-1:0]),
      .i_read_address(i_read_address[STORAGE_ADDR_WIDTH-1:0]),
      .i_write_data(i_write_data),
      .o_read_data(memory_read_data)
  );

`ifndef YOSYS
`ifndef FROST_VIVADO_SYNTH
  logic [31:0] init_mem[FullDepth];
  initial begin
    if (USE_INIT_FILE) begin
      // Image padding agrees across the independently packed banks.
      for (int i = 0; i < FullDepth; i++) init_mem[i] = '0;
      $readmemh(INIT_FILE, init_mem);
      for (int i = 0; i < BankDepth; i++) begin
        u_ram.ram[i][0] = sideband_bit_from_word(init_mem[2*i+IS_ODD_BANK]);
      end
    end else begin
`ifndef FROST_RANDOM_START
      for (int i = 0; i < BankDepth; i++) begin
        logic [31:0] default_word;
        default_word = 32'(2 * i + IS_ODD_BANK);
        u_ram.ram[i][0] = sideband_bit_from_word(default_word);
      end
`endif
    end
  end
`endif
`endif  // YOSYS

  // Register the asynchronous read to match the BRAM latency and enable hold.
  (* keep = "true" *) logic read_q;

  always_ff @(posedge i_read_clk) begin
    if (i_read_enable) begin
      // A miss uses the previous BRAM response; repeating the request aligns it.
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
 * Each parity has four block-RAM banks, cold, frontend_hot, sideband, and
 * compressed, each an sdp_block_ram_dc_init (hw/rtl/lib/ram):
 *   u_even_*: words 0, 2, 4, ...
 *   u_odd_*:  words 1, 3, 5, ...
 *
 * Both banks read in parallel. For word index W:
 *   even W: EVEN[W>>1] = W,   ODD[W>>1] = W+1
 *   odd W:  ODD[W>>1] = W,    EVEN[(W>>1)+1] = W+1
 * Registered PC[2] swaps the outputs into {W+1, W}.
 *
 * Each word is stored with its predecode sideband from
 * riscv_pkg::imem_make_sideband (fetch-control bits and each halfword's RVC
 * expansion), computed on every programming write and at simulation init.
 * Vivado builds load init files written by
 * sw/common/generate_imem_predecode_init.py, which mirrors that function. The
 * L1I fill path uses the same function.
 *
 * Each data bank splits 28 cold bits from four frontend bits {15,10,7,6},
 * for timing. At the production depth of 16K entries per parity (128 KiB),
 * each RAMB36 holds two lanes, so this split adds no BRAM. Four more lanes
 * replicate C[15], C[13], C[12], and AllowsSlot2AfterHi.
 *
 * PC predicates use registered LUTRAM overlays (imem_sideband_scalar_bank),
 * covering [0, 64 KiB) by default. Outside that range, repeat the window
 * while predicates are redecoded into the same output flops. The full-depth
 * sideband is the simulation reference; its unused hardware predicate lanes
 * can be trimmed.
 *
 * Port A programs and reads on the slow clock. Its write path is registered,
 * so writes commit one port-A cycle after presentation. Port B is the
 * read-only fast-clock fetch port. Keeping fetch live during a Port-A write
 * relies on the production phase-related div4 clock: at least three Port-B
 * edges separate the staged write enable from the array commit, allowing the
 * two-flop quarantine synchronizer to land first. A different clock ratio
 * requires holding fetch externally or adding a write handshake. The ASIC
 * flow's SRAM macros complete a write two Port-B cycles after the block RAM
 * does, at the div4 clock's falling edge; the first read that the
 * quarantine lets through comes a cycle and a half after that.
 */
module imem_predecode #(
    parameter int unsigned ADDR_WIDTH = 14,
    // Per-parity word-address width of the pinned PC-metadata overlay. Thirteen
    // bits per parity cover byte addresses [0, 64 KiB). Smaller IMEMs default
    // to full coverage and may override this parameter to exercise the
    // registered fallback. Both words must fit the overlay for a one-cycle hit.
    parameter int unsigned PC_METADATA_OVERLAY_ADDR_WIDTH = (ADDR_WIDTH > 14) ? 13 : ADDR_WIDTH - 1,
    parameter bit USE_INIT_FILE = 1'b1,
    parameter bit [47:0] INIT_FILE = "sw.mem",
    // Word-address width of INIT_FILE's image, the whole low BRAM. This
    // memory takes the image's first 2**ADDR_WIDTH words; the rest belong to
    // the data memory alone. Only simulation reads INIT_FILE.
    parameter int unsigned INIT_ADDR_WIDTH = ADDR_WIDTH,
    // One block-RAM image per bank, as wide as the wrappers' INIT_FILE.
    parameter bit [319:0] INIT_FILE_EVEN_COLD = "sw_imem_even_cold.mem",
    parameter bit [319:0] INIT_FILE_ODD_COLD = "sw_imem_odd_cold.mem",
    parameter bit [319:0] INIT_FILE_EVEN_FRONTEND_HOT = "sw_imem_even_frontend_hot.mem",
    parameter bit [319:0] INIT_FILE_ODD_FRONTEND_HOT = "sw_imem_odd_frontend_hot.mem",
    parameter bit [319:0] INIT_FILE_EVEN_SIDEBAND = "sw_imem_even_sideband.mem",
    parameter bit [319:0] INIT_FILE_ODD_SIDEBAND = "sw_imem_odd_sideband.mem",
    parameter bit [319:0] INIT_FILE_EVEN_COMPRESSED = "sw_imem_even_compressed.mem",
    parameter bit [319:0] INIT_FILE_ODD_COMPRESSED = "sw_imem_odd_compressed.mem",
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
    output logic [riscv_pkg::ImemFetchSidebandWidth-1:0] o_port_b_sideband,
    // Copy of the PC-advance bits, ordered like o_port_b_read_data. Each
    // word is {pairable_native_hi, pairable_compressed_hi,
    //          compressed_hi, compressed_lo}, so the complete window is
    // {next_word[3:0], current_word[3:0]}.
    output logic [7:0] o_port_b_pc_metadata,
    // Physical-parity metadata from the scalar output flops, for timing.
    // response_ready marks alignment with the payload; overlay_hit distinguishes
    // one-cycle overlay reads from the repeated-request fallback.
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
    output logic o_port_b_bank_sel_r  // Registered fetch-word parity (PC[2] from fetch cycle)
);

  localparam int unsigned DataWidth = 32;
  localparam int unsigned ColdDataWidth = 28;
  localparam int unsigned FrontendHotWidth = 4;
  localparam int unsigned SidebandWidth = riscv_pkg::ImemSidebandWidth;
  localparam int unsigned HalfDepth = 2 ** (ADDR_WIDTH - 1);
  localparam int unsigned FullDepth = 2 ** ADDR_WIDTH;
  localparam int unsigned ByteAddrBits = 2;  // 32-bit word alignment
  // Lane order of the narrow high-parcel block RAM (u_*_compressed; despite
  // the name it holds no instruction-size bits, which live in the scalar
  // LUTRAM overlay).
  localparam int unsigned FastLaneC15 = 0;  // word[31]
  localparam int unsigned FastLaneC12 = 1;  // word[28]
  localparam int unsigned FastLaneC13 = 2;  // word[29]
  localparam int unsigned FastLaneAllowsSlot2AfterHi = 3;
  localparam int unsigned FastLaneWidth = 4;

  function automatic logic pc_metadata_overlay_contains(input logic [31:0] byte_address);
    // One parity row covers two 32-bit words, hence the three low byte-address
    // bits below the scalar bank's stored row index.
    pc_metadata_overlay_contains = (byte_address >> (PC_METADATA_OVERLAY_ADDR_WIDTH + 3)) == '0;
  endfunction

`ifndef SYNTHESIS
  initial begin
    p_pc_metadata_overlay_width_valid :
    assert (PC_METADATA_OVERLAY_ADDR_WIDTH > 0 && PC_METADATA_OVERLAY_ADDR_WIDTH <= ADDR_WIDTH - 1);
    p_init_image_covers_memory : assert (INIT_ADDR_WIDTH >= ADDR_WIDTH);
`ifdef FROST_SRAM_MACROS
    // The macros start only from the banks' images.
    p_macro_banks_start_from_images : assert (USE_INIT_FILE);
`endif
  end
`endif

  // Lane order must match the offline init files:
  //   hot[3:0] = {word[15], word[10], word[7], word[6]}.
  // Cold packs the remaining bits in architectural order; both are rewires.
  // Assign to the function name because the Yosys 0.64 frontend rejects return.
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
    pack_fast_lanes = {sideband[riscv_pkg::ImemSbAllowsSlot2AfterHi], word[29:28], word[31]};
  endfunction

  // =========================================================================
  // Initialization: split sw.mem into even/odd banks
  // =========================================================================
  // Vivado loads each bank's already split image (INIT_FILE_*), so every
  // synthesized memory has an explicit power-up image, and simulations of
  // the ASIC flow's SRAM macros (FROST_SRAM_MACROS) start the macros with the
  // same images, which an app build writes for the 128 KiB code region
  // (sw/common/common.mk). Other simulations fill the banks below. Yosys
  // leaves them without initial contents: the preload split would expand the
  // temporary init_mem array into registers during frontend elaboration.
`ifdef FROST_VIVADO_SYNTH
  localparam bit LoadBankImages = USE_INIT_FILE;
`elsif FROST_SRAM_MACROS
  localparam bit LoadBankImages = USE_INIT_FILE;
`else
  localparam bit LoadBankImages = 1'b0;
`endif

`ifndef YOSYS
`ifndef FROST_VIVADO_SYNTH
`ifndef FROST_SRAM_MACROS
  logic [DataWidth-1:0] init_mem[2**INIT_ADDR_WIDTH];

  initial begin
    if (USE_INIT_FILE) begin
      // Image padding agrees across the independently packed banks.
      for (int i = 0; i < FullDepth; i++) init_mem[i] = '0;
      $readmemh(INIT_FILE, init_mem);
      for (int i = 0; i < FullDepth; i++) begin
        if (i[0] == 1'b0) begin
          u_even_cold.ram[i>>1] = pack_cold_data(init_mem[i]);
          u_even_frontend_hot.ram[i>>1] = pack_frontend_hot(init_mem[i]);
          u_even_sideband.ram[i>>1] = riscv_pkg::imem_make_sideband(init_mem[i]);
          u_even_compressed.ram[i>>1] = pack_fast_lanes(init_mem[i], u_even_sideband.ram[i>>1]);
        end else begin
          u_odd_cold.ram[i>>1] = pack_cold_data(init_mem[i]);
          u_odd_frontend_hot.ram[i>>1] = pack_frontend_hot(init_mem[i]);
          u_odd_sideband.ram[i>>1] = riscv_pkg::imem_make_sideband(init_mem[i]);
          u_odd_compressed.ram[i>>1] = pack_fast_lanes(init_mem[i], u_odd_sideband.ram[i>>1]);
        end
      end
    end else begin
`ifndef FROST_RANDOM_START
      for (int i = 0; i < HalfDepth; i++) begin
        logic [DataWidth-1:0] even_default_word;
        logic [DataWidth-1:0] odd_default_word;
        even_default_word = DataWidth'(2 * i);
        odd_default_word = DataWidth'(2 * i + 1);
        u_even_cold.ram[i] = pack_cold_data(even_default_word);
        u_odd_cold.ram[i] = pack_cold_data(odd_default_word);
        u_even_frontend_hot.ram[i] = pack_frontend_hot(even_default_word);
        u_odd_frontend_hot.ram[i] = pack_frontend_hot(odd_default_word);
        u_even_sideband.ram[i] = riscv_pkg::imem_make_sideband(even_default_word);
        u_odd_sideband.ram[i] = riscv_pkg::imem_make_sideband(odd_default_word);
        u_even_compressed.ram[i] = pack_fast_lanes(even_default_word, u_even_sideband.ram[i]);
        u_odd_compressed.ram[i] = pack_fast_lanes(odd_default_word, u_odd_sideband.ram[i]);
      end
`endif
    end
  end
`endif
`endif
`endif  // YOSYS

  // =========================================================================
  // Port A: Programming interface (write to one bank per cycle)
  // =========================================================================
  // Same-address programming/fetch collisions return unspecified data.
  // Bulk loading holds image_load_reset; live debug writes use the readiness
  // quarantine below until the banks realign and a fresh response arrives.
  //
  // Registered programming inputs add one div4 cycle before array writes,
  // for fanout. Synthesized readback is a pass-through.
  logic [ADDR_WIDTH-1:0] port_a_word_address;
  logic [ADDR_WIDTH-2:0] port_a_half_address;
  logic                  port_a_bank_sel;  // 0 = even, 1 = odd

  assign port_a_word_address = i_port_a_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_a_half_address = port_a_word_address[ADDR_WIDTH-1:1];
  assign port_a_bank_sel     = port_a_word_address[0];

  (* max_fanout = 512 *)logic [ADDR_WIDTH-2:0] port_a_half_address_q;
  (* max_fanout = 512 *)logic [ DataWidth-1:0] port_a_write_data_q;
`ifdef FROST_RANDOM_START
  localparam bit RandomStart = 1'b1;
`else
  localparam bit RandomStart = 1'b0;
`endif

  (* max_fanout = 512 *) logic port_a_write_even_q = RandomStart ? 'x : 1'b0;
  (* max_fanout = 512 *) logic port_a_write_odd_q = RandomStart ? 'x : 1'b0;

  // Live writes must invalidate repeated-address history: slow predicates
  // trail the changed BRAM word by one read. Staged write enables precede
  // array commit by a div4 cycle, allowing this synchronizer to block readiness
  // first. This requires the clock relationship documented above.
  (* ASYNC_REG = "TRUE" *) logic [1:0] port_a_write_active_sync_q = RandomStart ? 'x : 2'b00;
  logic port_a_write_quarantine;
  always_ff @(posedge i_port_b_clk) begin
    if (i_port_b_rst) port_a_write_active_sync_q <= '0;
    else
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

  // Compute sideband from the staged write data at write time. The staged
  // enables write one parity's four banks (below) together.
  logic [SidebandWidth-1:0] write_sideband;
  logic [ColdDataWidth-1:0] write_cold;
  logic [FrontendHotWidth-1:0] write_frontend_hot;
  logic [FastLaneWidth-1:0] write_fast_lanes;
  assign write_sideband = riscv_pkg::imem_make_sideband(port_a_write_data_q);
  assign write_cold = pack_cold_data(port_a_write_data_q);
  assign write_frontend_hot = pack_frontend_hot(port_a_write_data_q);
  assign write_fast_lanes = pack_fast_lanes(port_a_write_data_q, write_sideband);

`ifndef SYNTHESIS
`ifndef FROST_SRAM_MACROS
  `define IMEM_PREDECODE_PORT_A_READBACK
`endif
`endif
`ifdef IMEM_PREDECODE_PORT_A_READBACK
  // Port A read (write-first): read back from whichever bank was addressed
  always_ff @(posedge i_port_a_clk) begin
    if (i_port_a_enable) begin
      if (i_port_a_write_enable) begin
        o_port_a_read_data <= i_port_a_write_data;
      end else begin
        o_port_a_read_data <= port_a_bank_sel ? join_data_banks(
            u_odd_cold.ram[port_a_half_address], u_odd_frontend_hot.ram[port_a_half_address]) :
            join_data_banks(u_even_cold.ram[port_a_half_address],
                            u_even_frontend_hot.ram[port_a_half_address]);
      end
    end
  end
  `undef IMEM_PREDECODE_PORT_A_READBACK
`else
  // The programming-side readback is unused by the core. Removing this BRAM
  // read port under synthesis keeps the two-bank memory in a Xilinx-mappable
  // one-write/one-read shape. The ASIC flow's macros have only those two
  // ports, so their simulations pass the write data through as well.
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
  logic pc_metadata_overlay_window_hit_q = RandomStart ? 'x : 1'b0;
  logic pc_metadata_response_ready_q = RandomStart ? 'x : 1'b0;
  logic pc_metadata_response_history_valid_q = RandomStart ? 'x : 1'b0;
  logic [31:0] pc_metadata_response_address_q;
  logic [31:0] pc_metadata_response_next_address_q;
  logic [3:0] even_pc_metadata;
  logic [3:0] odd_pc_metadata;

  assign pc_metadata_overlay_window_hit = pc_metadata_overlay_contains(
      i_port_b_byte_address
  ) && pc_metadata_overlay_contains(
      i_port_b_next_byte_address
  );

  // Scalar banks share their parity's staged write and fetch addresses.
  // Writes outside the overlay are ignored; each parity is independently placed.
  (* dont_touch = "yes" *)
  imem_sideband_scalar_bank #(
      .SIDEBAND_BIT(riscv_pkg::ImemSbIsCompressedLo),
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .STORAGE_ADDR_WIDTH(PC_METADATA_OVERLAY_ADDR_WIDTH),
      .USE_INIT_FILE(USE_INIT_FILE),
      .INIT_FILE(INIT_FILE),
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_EVEN_IS_COMPRESSED_LO),
      .IS_ODD_BANK(1'b0)
  ) u_even_is_compressed_lo_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even),
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
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_ODD_IS_COMPRESSED_LO),
      .IS_ODD_BANK(1'b1)
  ) u_odd_is_compressed_lo_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd),
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
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_EVEN_IS_COMPRESSED_HI),
      .IS_ODD_BANK(1'b0)
  ) u_even_is_compressed_hi_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even),
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
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_ODD_IS_COMPRESSED_HI),
      .IS_ODD_BANK(1'b1)
  ) u_odd_is_compressed_hi_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd),
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
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_EVEN_EVEN_LOCAL_PAIR_VALID),
      .IS_ODD_BANK(1'b0)
  ) u_even_even_local_pair_valid_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even),
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
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_ODD_EVEN_LOCAL_PAIR_VALID),
      .IS_ODD_BANK(1'b1)
  ) u_odd_even_local_pair_valid_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd),
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
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_EVEN_PAIRABLE_NATIVE_LO),
      .IS_ODD_BANK(1'b0)
  ) u_even_pairable_native_lo_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even),
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
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_ODD_PAIRABLE_NATIVE_LO),
      .IS_ODD_BANK(1'b1)
  ) u_odd_pairable_native_lo_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd),
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
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_EVEN_PAIRABLE_COMPRESSED_HI),
      .IS_ODD_BANK(1'b0)
  ) u_even_pairable_compressed_hi_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even),
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
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_ODD_PAIRABLE_COMPRESSED_HI),
      .IS_ODD_BANK(1'b1)
  ) u_odd_pairable_compressed_hi_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd),
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
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_EVEN_PAIRABLE_NATIVE_HI),
      .IS_ODD_BANK(1'b0)
  ) u_even_pairable_native_hi_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even),
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
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_ODD_PAIRABLE_NATIVE_HI),
      .IS_ODD_BANK(1'b1)
  ) u_odd_pairable_native_hi_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd),
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
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_EVEN_SLOT2_START_VALID_LO),
      .IS_ODD_BANK(1'b0)
  ) u_even_slot2_start_valid_lo_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_even),
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
      .INIT_ADDR_WIDTH(INIT_ADDR_WIDTH),
      .BANK_INIT_FILE(INIT_FILE_ODD_SLOT2_START_VALID_LO),
      .IS_ODD_BANK(1'b1)
  ) u_odd_slot2_start_valid_lo_bank (
      .i_write_clk(i_port_a_clk),
      .i_write_enable(port_a_write_odd),
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

  // =========================================================================
  // Even/odd interleaved memory banks
  // =========================================================================
  // The even banks hold the words whose full word index is 2*k, the odd banks
  // those at 2*k+1. The staged port-A enables write one parity's four banks
  // together, and each enabled port-B cycle reads all eight.
  //
  // Fetch takes word[31] from the compressed banks' C15 lane, so only
  // simulation checks read the cold banks' copy of it, their top bit. Read
  // through the bank wrapper's port, Vivado would keep that bit in the block
  // RAM, whose last slice would then take a RAMB36 where a RAMB18 holds the
  // bit below it alone; the FPGA build stores the cold bits below word[31].
`ifdef FROST_VIVADO_SYNTH
  localparam int unsigned ColdBankWidth = ColdDataWidth - 1;
`else
  localparam int unsigned ColdBankWidth = ColdDataWidth;
`endif
  sdp_block_ram_dc_init #(
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .DATA_WIDTH(ColdBankWidth),
      .USE_INIT_FILE(LoadBankImages),
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

  // Full-depth sideband uses BRAM for timing.
  sdp_block_ram_dc_init #(
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .DATA_WIDTH(SidebandWidth),
      .USE_INIT_FILE(LoadBankImages),
      .INIT_FILE(INIT_FILE_EVEN_SIDEBAND)
  ) u_even_sideband (
      .i_write_clock(i_port_a_clk),
      .i_write_enable(port_a_write_even),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband),
      .i_read_clock(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(even_read_addr),
      .o_read_data(even_sideband)
  );

  sdp_block_ram_dc_init #(
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .DATA_WIDTH(SidebandWidth),
      .USE_INIT_FILE(LoadBankImages),
      .INIT_FILE(INIT_FILE_ODD_SIDEBAND)
  ) u_odd_sideband (
      .i_write_clock(i_port_a_clk),
      .i_write_enable(port_a_write_odd),
      .i_write_address(port_a_half_address_q),
      .i_write_data(write_sideband),
      .i_read_clock(i_port_b_clk),
      .i_read_enable(i_port_b_enable),
      .i_read_address(odd_read_addr),
      .o_read_data(odd_sideband)
  );

  // Same-edge high-parcel copies, for timing. The *_compressed.mem images
  // pack {allows_slot2_after_hi, word[29], word[28], word[31]}; instruction-size
  // bits live in the scalar overlay. Each RAMB36 holds two lanes at 16K depth.
  sdp_block_ram_dc_init #(
      .ADDR_WIDTH(ADDR_WIDTH - 1),
      .DATA_WIDTH(FastLaneWidth),
      .USE_INIT_FILE(LoadBankImages),
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
    // PC predicates come from scalar output flops. Overlay pairability is
    // fully evaluated at initialization or write time.
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

  // Repeating the physical word pair aligns redecoded predicates with the
  // raw BRAM payload. Reconstruct the words first so C[15], C[13], and C[12]
  // still come from the narrow banks.
  assign even_sideband_redecoded = riscv_pkg::imem_make_sideband(
      even_read_data_with_fast_rvc_fields
  );
  assign odd_sideband_redecoded = riscv_pkg::imem_make_sideband(odd_read_data_with_fast_rvc_fields);

  // Check both full physical addresses: mixed windows are slow, and high
  // addresses aliasing the finite memory pins must not hit the overlay.
  always_ff @(posedge i_port_b_clk) begin
    if (i_port_b_rst || port_a_write_quarantine) begin
      // Block responses until the write commits and fresh history is captured.
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
  assign o_port_b_read_data_by_parity = {
    odd_read_data_with_fast_rvc_fields, even_read_data_with_fast_rvc_fields
  };
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
  assign o_port_b_bank_sel_r = bank_sel_r;

`ifndef SYNTHESIS
  // Compare ready metadata with the same-edge full-depth banks. Skip
  // unready windows, whose slow predicates may still be stale. The check
  // samples at the clock edge, where the registers that read the banks do:
  // the ASIC flow's SRAM macro models change their read data mid-cycle.
  logic pc_metadata_compare_valid_q = 1'b0;
  always_ff @(posedge i_port_b_clk) begin
    pc_metadata_compare_valid_q <= !i_port_b_rst && i_port_b_enable;
  end

  always @(posedge i_port_b_clk) begin
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
      })
      else
        $error(
            "imem_predecode: odd word %h metadata %h at %h / %h",
            odd_read_data,
            odd_pc_metadata,
            pc_metadata_response_address_q,
            pc_metadata_response_next_address_q
        );
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
