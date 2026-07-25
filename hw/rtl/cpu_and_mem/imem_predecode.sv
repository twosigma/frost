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
 *   memory_even_{cold,frontend_hot} — even words (0, 2, 4, …)
 *   memory_odd_{cold,frontend_hot}  — odd words  (1, 3, 5, …)
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
 * is-compressed, small opcode-class predecode, word-local bundle eligibility
 * qualifiers, and {rs2[1], rs1[2:1]} from each halfword's exact RVC expansion.
 * IF therefore avoids rebuilding PC decisions and the four current source-bit
 * timing endpoints from raw instruction data.
 * The bit definitions live in riscv_pkg (imem_make_sideband and helpers),
 * shared with the L1I fill path and mirrored by the offline generator
 * sw/common/generate_imem_predecode_init.py.
 *
 * BRAM resource impact: each 32-bit half-depth data bank is physically split
 * into a 28-bit cold bank plus one 4-bit frontend-hot bank containing word bits
 * {15, 10, 7, 6}. At 8K entries those shapes use seven plus one RAMB36,
 * respectively, so the split is resource-neutral while giving the four current
 * low-IMEM timing lanes one independently placeable block-RAM launch.
 * Synthesis also prunes raw data lanes 31, 29, and 28 from the fetch outputs
 * because the exact LUTRAM replicas below provide those architectural bits.
 *
 * Port A: Instruction programming (slow clock domain, write + read).  The
 *         write side is staged through one register layer (max_fanout-shaped)
 *         before reaching the arrays, so writes commit one port-A cycle after
 *         they are presented; see the routability note at the port-A logic.
 * Port B: Instruction fetch (fast clock domain, read only)
 */
module imem_predecode #(
    parameter int unsigned ADDR_WIDTH = 14,
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
  localparam int unsigned ColdDataWidth = 28;
  localparam int unsigned FrontendHotWidth = 4;
  localparam int unsigned SidebandWidth = riscv_pkg::ImemSidebandWidth;
  localparam int unsigned HalfDepth = 2 ** (ADDR_WIDTH - 1);
  localparam int unsigned FullDepth = 2 ** ADDR_WIDTH;
  localparam int unsigned ByteAddrBits = 2;  // 32-bit word alignment

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

  // =========================================================================
  // Even/odd interleaved memory banks
  // =========================================================================
  // The even pair holds the word whose full word-index is 2*k.
  // The odd pair holds the word whose full word-index is 2*k+1.
  /* verilator lint_off MULTIDRIVEN */
  (* ram_style = "block" *) logic [ColdDataWidth-1:0] memory_even_cold[HalfDepth];
  (* ram_style = "block" *) logic [ColdDataWidth-1:0] memory_odd_cold[HalfDepth];
  // Keep the timing-facing four-bit slices distinct from the cold arrays.
  // Their 8Kx4 shape maps exactly to one RAMB36 per parity bank.
  (* ram_style = "block", keep = "true", dont_touch = "yes" *)
  logic [FrontendHotWidth-1:0] memory_even_frontend_hot[HalfDepth];
  (* ram_style = "block", keep = "true", dont_touch = "yes" *)
  logic [FrontendHotWidth-1:0] memory_odd_frontend_hot[HalfDepth];
  // Keep the predecode sideband in BRAM.  LUTRAM looked attractive for size,
  // but on X3 it spreads the sideband arrays across fabric and puts pc_reg on
  // a long distributed-memory address route in the low-BRAM fetch path. The
  // six source-hot bits widen these arrays without adding another memory read
  // or pipeline stage.
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
      $readmemh(INIT_FILE_EVEN_COLD, memory_even_cold);
      $readmemh(INIT_FILE_ODD_COLD, memory_odd_cold);
      $readmemh(INIT_FILE_EVEN_FRONTEND_HOT, memory_even_frontend_hot);
      $readmemh(INIT_FILE_ODD_FRONTEND_HOT, memory_odd_frontend_hot);
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
          memory_even_cold[i>>1] = pack_cold_data(init_mem[i]);
          memory_even_frontend_hot[i>>1] = pack_frontend_hot(init_mem[i]);
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
          memory_odd_cold[i>>1] = pack_cold_data(init_mem[i]);
          memory_odd_frontend_hot[i>>1] = pack_frontend_hot(init_mem[i]);
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
        memory_even_compressed[i] = {
          memory_even_sideband[i][riscv_pkg::ImemSbAllowsSlot2AfterHi],
          even_default_word[29:28],
          even_default_word[31],
          even_default_word[27:23] == 5'd2,
          memory_even_sideband[i][1:0]
        };
        memory_odd_compressed[i] = {
          memory_odd_sideband[i][riscv_pkg::ImemSbAllowsSlot2AfterHi],
          odd_default_word[29:28],
          odd_default_word[31],
          odd_default_word[27:23] == 5'd2,
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
  //
  // ROUTABILITY — the write side is REGISTERED ONCE before touching the
  // arrays.  The compressed/slot2 LUTRAM mirrors put thousands of RAMD64E
  // write-address/enable pins on this bus; driven straight from the AXI BRAM
  // controller they became half a dozen 12k-load flat nets routed across the
  // X3 core band (timing-clean on the div4 clock, but a first-order consumer
  // of the routing the 300 MHz core needed).  The staged copies below carry
  // max_fanout so synthesis rebuilds them as placeable regional trees.  Cost:
  // one extra div4-clock cycle of write latency on a JTAG-paced programming
  // port (readback under synthesis is a pass-through, so no read-latency
  // contract changes).
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

  always_ff @(posedge i_port_a_clk) begin
    port_a_half_address_q <= port_a_half_address;
    port_a_write_data_q   <= i_port_a_write_data;
    port_a_write_even_q   <= i_port_a_enable && i_port_a_write_enable && !port_a_bank_sel;
    port_a_write_odd_q    <= i_port_a_enable && i_port_a_write_enable && port_a_bank_sel;
  end

  // Compute sideband from the staged write data at write time.
  logic [SidebandWidth-1:0] write_sideband;
  assign write_sideband = riscv_pkg::imem_make_sideband(port_a_write_data_q);

  // Port A — even bank
  always_ff @(posedge i_port_a_clk) begin
    if (port_a_write_even_q) begin
      memory_even_cold[port_a_half_address_q] <= pack_cold_data(port_a_write_data_q);
      memory_even_frontend_hot[port_a_half_address_q] <= pack_frontend_hot(port_a_write_data_q);
      memory_even_sideband[port_a_half_address_q] <= write_sideband;
      memory_even_compressed[port_a_half_address_q] <= {
        write_sideband[riscv_pkg::ImemSbAllowsSlot2AfterHi],
        port_a_write_data_q[29:28],
        port_a_write_data_q[31],
        port_a_write_data_q[27:23] == 5'd2,
        write_sideband[1:0]
      };
      memory_even_slot2_start_valid_lo[port_a_half_address_q] <=
          write_sideband[riscv_pkg::ImemSbSlot2StartValidLo];
    end
  end

  // Port A — odd bank
  always_ff @(posedge i_port_a_clk) begin
    if (port_a_write_odd_q) begin
      memory_odd_cold[port_a_half_address_q] <= pack_cold_data(port_a_write_data_q);
      memory_odd_frontend_hot[port_a_half_address_q] <= pack_frontend_hot(port_a_write_data_q);
      memory_odd_sideband[port_a_half_address_q] <= write_sideband;
      memory_odd_compressed[port_a_half_address_q] <= {
        write_sideband[riscv_pkg::ImemSbAllowsSlot2AfterHi],
        port_a_write_data_q[29:28],
        port_a_write_data_q[31],
        port_a_write_data_q[27:23] == 5'd2,
        write_sideband[1:0]
      };
      memory_odd_slot2_start_valid_lo[port_a_half_address_q] <=
          write_sideband[riscv_pkg::ImemSbSlot2StartValidLo];
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

  assign port_b_word_address = i_port_b_byte_address[ADDR_WIDTH+ByteAddrBits-1:ByteAddrBits];
  assign port_b_half_address = port_b_word_address[ADDR_WIDTH-1:1];
  assign port_b_bank_sel     = port_b_word_address[0];

  // BRAM_EVEN address: when PC[2]=0, same half-addr; when PC[2]=1, half-addr+1
  // BRAM_ODD  address: always half-addr
  logic [ADDR_WIDTH-2:0] even_read_addr, odd_read_addr;
  assign even_read_addr = port_b_bank_sel ? (port_b_half_address + 1'd1) : port_b_half_address;
  assign odd_read_addr  = port_b_half_address;

  logic [ColdDataWidth-1:0] even_read_data_cold, odd_read_data_cold;
  logic [FrontendHotWidth-1:0] even_read_data_frontend_hot;
  logic [FrontendHotWidth-1:0] odd_read_data_frontend_hot;
  logic [DataWidth-1:0] even_read_data, odd_read_data;
  logic [SidebandWidth-1:0] even_sideband, odd_sideband;
  (* keep = "true", dont_touch = "yes" *) logic [6:0] even_compressed;
  (* keep = "true", dont_touch = "yes" *) logic [6:0] odd_compressed;
  (* keep = "true", dont_touch = "yes" *) logic even_slot2_start_valid_lo;
  (* keep = "true", dont_touch = "yes" *) logic odd_slot2_start_valid_lo;

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
      even_slot2_start_valid_lo <= memory_even_slot2_start_valid_lo[even_read_addr];
      odd_slot2_start_valid_lo <= memory_odd_slot2_start_valid_lo[odd_read_addr];
    end
  end

  assign even_read_data = join_data_banks(even_read_data_cold, even_read_data_frontend_hot);
  assign odd_read_data  = join_data_banks(odd_read_data_cold, odd_read_data_frontend_hot);

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
