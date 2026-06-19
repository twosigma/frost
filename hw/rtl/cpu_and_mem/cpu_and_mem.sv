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
  CPU and Memory integration module that combines the RISC-V processor core with
  dual-port RAM and memory-mapped I/O peripherals. This module serves as the main
  compute and storage subsystem, managing the instruction fetch interface, data memory
  access, and MMIO peripherals including UART, FIFO, and timer interfaces. The module
  instantiates the Tomasulo OOO RISC-V CPU alongside two separate dual-port RAMs:
  one for instruction fetch and one for data access. Both memories use Port A on the
  divided clock (i_clk_div4) for instruction programming writes, and Port B on the main
  clock (i_clk) for runtime operations - instruction fetch from memory 0 and data
  loads/stores from memory 1. This dual-clock architecture eliminates clock domain
  crossing logic while ensuring all slow programming operations use Port A and all fast
  runtime operations use Port B. Timer functionality is provided by memory-mapped
  mtime/mtimecmp registers that generate machine timer interrupts for RTOS scheduling.
  Software interrupts (msip) support inter-processor communication and kernel-to-kernel
  signaling. The UART interface provides console output, and two general-purpose FIFOs
  support peripheral communication. The memory architecture supports byte-level write
  granularity.
*/
module cpu_and_mem #(
    parameter int unsigned MEM_SIZE_BYTES = 2 ** 17,
    // Timer speedup for simulation - multiplies mtime increment rate
    // Set to 1 for synthesis (normal behavior), higher for faster simulation
    // Example: 1000 makes FreeRTOS timers run 1000x faster in simulation
    parameter int unsigned SIM_TIMER_SPEEDUP = 1,
    // Cached memory tier parameters (see frost.sv). High-address region backed
    // by the cache hierarchy (L1 BRAM, optional L2 URAM) over main memory;
    // accesses there have handshake (variable) latency while the low BRAM
    // range + MMIO stay 1-cycle.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter int unsigned CACHED_SIZE_BYTES = 32'h4000_0000,  // 1 GiB
    parameter int unsigned ENABLE_CACHED_TIER = 1,
    parameter int unsigned CACHED_HAS_L2 = 1,
    parameter int unsigned L1_CACHE_BYTES = 128 * 1024,
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    parameter int unsigned L2_CACHE_BYTES = 2 * 1024 * 1024,
    // Behavioral main-memory model (simulation only; hardware integration
    // replaces it with the DDR controller behind the same AXI port).
    parameter int unsigned DDR_MODEL_BYTES = 64 * 1024 * 1024,
    parameter int unsigned DDR_MODEL_LATENCY = 30,
    // 1 = cached tier ends in the behavioral DDR model; 0 = it ends at the
    // o_ddr_axi_*/i_ddr_axi_* ports (hardware DDR controller).
    parameter int unsigned USE_BEHAVIORAL_DDR = 1,
    // Simulation-only fetch-latency fuzz: emulate a variable-latency fetch
    // provider over the 1-cycle instruction BRAM (LFSR-gated i_instr_valid +
    // owed-ask tracking).  Exercises the core's fetch-invalid machinery
    // before a real I-cache sits behind it; hardware keeps 0.
    parameter int unsigned FETCH_VALID_FUZZ = 0
) (
    input logic i_clk,
    input logic i_clk_div4,  // Divided clock for instruction memory programming
    input logic i_rst,

    // Instruction memory programming interface (directly on div4 clock domain)
    input  logic        i_instr_mem_en,
    input  logic [ 3:0] i_instr_mem_we,
    input  logic [31:0] i_instr_mem_addr,
    input  logic [31:0] i_instr_mem_wrdata,
    output logic [31:0] o_instr_mem_rddata,

    output logic       o_uart_wr_en,
    output logic [7:0] o_uart_wr_data,
    input  logic       i_uart_tx_ready,

    // UART RX interface - received data from UART
    input  logic [7:0] i_uart_rx_data,
    input  logic       i_uart_rx_valid,
    output logic       o_uart_rx_ready,

    // FIFO interfaces
    output logic        o_fifo0_wr_en,
    output logic [31:0] o_fifo0_wr_data,
    input  logic [31:0] i_fifo0_rd_data,
    input  logic        i_fifo0_empty,
    output logic        o_fifo0_rd_en,

    output logic        o_fifo1_wr_en,
    output logic [31:0] o_fifo1_wr_data,
    input  logic [31:0] i_fifo1_rd_data,
    input  logic        i_fifo1_empty,
    output logic        o_fifo1_rd_en,

    // External interrupt input (directly triggers MEIP when high)
    input logic i_external_interrupt,

    // DDR AXI master (cache-hierarchy bridge). Quiescent when
    // USE_BEHAVIORAL_DDR=1 or the cached tier is disabled.
    output logic         o_ddr_axi_awvalid,
    input  logic         i_ddr_axi_awready,
    output logic [ 31:0] o_ddr_axi_awaddr,
    output logic [  7:0] o_ddr_axi_awlen,
    output logic [  2:0] o_ddr_axi_awsize,
    output logic [  1:0] o_ddr_axi_awburst,
    output logic         o_ddr_axi_wvalid,
    input  logic         i_ddr_axi_wready,
    output logic [255:0] o_ddr_axi_wdata,
    output logic [ 31:0] o_ddr_axi_wstrb,
    output logic         o_ddr_axi_wlast,
    input  logic         i_ddr_axi_bvalid,
    output logic         o_ddr_axi_bready,
    input  logic [  1:0] i_ddr_axi_bresp,
    output logic         o_ddr_axi_arvalid,
    input  logic         i_ddr_axi_arready,
    output logic [ 31:0] o_ddr_axi_araddr,
    output logic [  7:0] o_ddr_axi_arlen,
    output logic [  2:0] o_ddr_axi_arsize,
    output logic [  1:0] o_ddr_axi_arburst,
    input  logic         i_ddr_axi_rvalid,
    output logic         o_ddr_axi_rready,
    input  logic [255:0] i_ddr_axi_rdata,
    input  logic [  1:0] i_ddr_axi_rresp,
    input  logic         i_ddr_axi_rlast
);

  // Memory addressing parameters
  localparam int unsigned MemByteAddrWidth = $clog2(MEM_SIZE_BYTES);
  // ((128 KiB total memory)/(4 bytes per word)) = 32k words = 2^15 word address bits
  localparam int unsigned MemWordAddrWidth = MemByteAddrWidth - 2;

  // Memory-mapped I/O addresses for peripherals
  // IMPORTANT: If these addresses are changed, they must also be updated in:
  // - sw/common/link.ld (MMIO memory region and PROVIDE statements)
  // - cpu module parameters
  localparam int unsigned MmioAddr = 32'h4000_0000;
  localparam int unsigned MmioSizeBytes = 32'h2C;
  localparam int unsigned UartMmioAddr = 32'h4000_0000;  // UART TX (write-only)
  localparam int unsigned UartRxDataMmioAddr = 32'h4000_0004;  // UART RX data (read consumes byte)
  localparam int unsigned UartRxStatusMmioAddr = 32'h4000_0024;  // RX status (bit0: data available)
  localparam int unsigned UartTxStatusMmioAddr = 32'h4000_0028; // TX status (bit0: can accept byte)
  localparam int unsigned Fifo0MmioAddr = 32'h4000_0008;
  localparam int unsigned Fifo1MmioAddr = 32'h4000_000C;
  // Timer registers (CLINT-compatible layout)
  localparam int unsigned MtimeLowMmioAddr = 32'h4000_0010;  // mtime[31:0]
  localparam int unsigned MtimeHighMmioAddr = 32'h4000_0014;  // mtime[63:32]
  localparam int unsigned MtimecmpLowMmioAddr = 32'h4000_0018;  // mtimecmp[31:0]
  localparam int unsigned MtimecmpHighMmioAddr = 32'h4000_001C;  // mtimecmp[63:32]
  // Software interrupt register
  localparam int unsigned MsipMmioAddr = 32'h4000_0020;

  // Timer register defaults
  // Default mtimecmp to max value so no timer interrupt fires until software configures it
  localparam logic [63:0] MtimecmpDefault = 64'hFFFF_FFFF_FFFF_FFFF;

  // CPU interface signals
  logic [31:0] program_counter;
  logic [31:0] fetch_address;  // imem port B address (the presented fetch ask)
  logic [63:0] instruction;  // 64-bit fetch: {next_word, current_word}
  logic [riscv_pkg::ImemFetchSidebandWidth-1:0] instruction_sideband;
  logic instruction_bank_sel_r;  // Fetch-word parity (for spanning select)
  logic instruction_valid;  // Fetch window valid
  logic fetch_replay_consume;  // CPU consumed the stall-replay bundle this cycle
  logic pipeline_stall;  // front-end pipeline stall (gates fetch publish-valid)
  logic fence_i_sync_req;  // ROB serializer holding commit for a fence.i cache sync
  logic fence_i_sync_done;  // hierarchy finished L1D writeback-all + L1I invalidate-all
  logic fence_i_flush;  // committed fence.i pipeline-flush pulse (provider invalidate)

  // Low instruction BRAM window (imem_predecode port B outputs).  In hardware
  // cached-tier builds, imem port B stays on the direct o_pc fast path and the
  // fetch generate below muxes these registered outputs against the high DDR
  // provider outputs.
  logic [63:0] bram_fetch_instr;
  logic [riscv_pkg::ImemFetchSidebandWidth-1:0] bram_fetch_sideband;
  logic bram_fetch_bank_sel_r;
  (* keep = "true", max_fanout = 16 *) logic bram_fetch_bank_sel_cpu_r;

  // Instruction-side line port into the cache hierarchy: driven by the fetch
  // provider when the cached tier is enabled, tied off otherwise.
  logic iup_req_valid, iup_req_ready, iup_req_write;
  logic [31:0] iup_req_addr;
  logic [255:0] iup_req_wdata;
  logic [31:0] iup_req_wstrb;
  logic iup_resp_valid;
  logic [255:0] iup_resp_rdata;
  logic [31:0] data_memory_address, data_memory_write_data, data_memory_write_data_registered;
  logic [31:0] data_memory_or_peripheral_read_data;  // Muxed from RAM or MMIO
  logic [31:0] mmio_read_data_comb;
  logic [31:0] mmio_read_data_reg;
  logic        mmio_read_data_valid;
  logic [31:0] mmio_load_addr;
  logic        mmio_load_valid;
  logic        mmio_read_capture;
  logic [31:0] data_memory_read_data;  // From RAM only
  logic [31:0] data_memory_address_registered;  // Delayed for read data alignment
  logic [ 3:0] data_memory_byte_write_enable;
  // MMIO-pre-masked copy routed straight to the BRAM WEA pins. Generated in
  // cpu_ooo using the SQ/AMO-side registered is_mmio flags so the BRAM
  // write-enable no longer depends on the late combinational
  // data_memory_address-range test.
  logic [ 3:0] data_memory_bram_byte_write_enable;
  logic        data_memory_read_enable;
  // Cached tier (high-address region). The router drives these tier-routed
  // requests (already qualified by is_cached); the cached_tier_adapter
  // completes them with handshake pulses. The BRAM keeps reading/writing the
  // low range unchanged.
  logic [ 3:0] data_memory_cached_byte_write_enable;
  logic        data_memory_cached_read_enable;
  logic [31:0] data_memory_cached_read_data;
  logic        data_memory_cached_read_valid;
  logic        data_memory_cached_write_done;
  logic        data_memory_cached_write_inflight;
  // Cached-tier write data: SQ-store drain data, or the AMO new value on the
  // cycle a cached AMO read-modify-write launches (the router muxes the two).
  // Kept separate from data_memory_write_data so the cached write path stays
  // off the wide BRAM write-data cascade.
  logic [31:0] data_memory_cached_write_data;
  logic        mmio_read_pulse;
  logic        mmio_fifo0_read_pulse;
  logic        mmio_fifo1_read_pulse;
  logic        mmio_uart_rx_ready_pulse;
`ifndef SYNTHESIS
  logic [31:0] data_memory_store_last_addr;
  localparam logic [31:0] CoremarkListNodeLo = 32'h0001_f810;
  localparam logic [31:0] CoremarkListNodeHi = 32'h0001_f910;
`endif

  // Timer registers (CLINT-style)
  logic                  [63:0] mtime;  // Machine time counter
  logic                  [63:0] mtimecmp;  // Machine timer compare register
  logic                         msip;  // Machine software interrupt pending

  // Interrupt signals to CPU
  riscv_pkg::interrupt_t        interrupts;
  // Clamp unknown external interrupt values to 0 for simulation stability.
  // This avoids X-propagation into mip when the top-level input is left un-driven.
  assign interrupts.meip = (i_external_interrupt === 1'b1);
  assign interrupts.msip = msip;

  // Timer interrupt: register the 64-bit comparison result to break critical timing path.
  // The 1-cycle delay is acceptable for timer interrupts - they don't need cycle-accurate detection.
  logic mtip_comparison;
  logic mtip_registered;
  assign mtip_comparison = (mtime >= mtimecmp);
  always_ff @(posedge i_clk) begin
    if (i_rst) mtip_registered <= 1'b0;
    else mtip_registered <= mtip_comparison;
  end
  assign interrupts.mtip = mtip_registered;

  // RISC-V OOO CPU core - Tomasulo out-of-order with RV32IMACBFD + Zicsr + Machine/User-mode
  cpu_ooo #(
      .MEM_BYTE_ADDR_WIDTH(MemByteAddrWidth),
      .MMIO_ADDR(MmioAddr),
      .MMIO_SIZE_BYTES(MmioSizeBytes),
      .CACHED_BASE(CACHED_BASE),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES)
  ) cpu_inst (
      .i_clk,
      .i_rst,
      .o_pc(program_counter),
      .i_instr(instruction),
      .i_instr_sideband(instruction_sideband),
      .i_instr_bank_sel_r(instruction_bank_sel_r),
      .i_instr_valid(instruction_valid),
      .o_fetch_replay_consume(fetch_replay_consume),
      .o_pipeline_stall(pipeline_stall),
      .o_fence_i_sync_req(fence_i_sync_req),
      .i_fence_i_sync_done(fence_i_sync_done),
      .o_fence_i_flush(fence_i_flush),
      .o_data_mem_addr(data_memory_address),
      .o_data_mem_wr_data(data_memory_write_data),
      .o_data_mem_per_byte_wr_en(data_memory_byte_write_enable),
      .o_data_mem_bram_byte_wr_en(data_memory_bram_byte_write_enable),
      .o_data_mem_read_enable(data_memory_read_enable),
      // Cached tier ports (high-address region).
      .o_data_mem_cached_byte_wr_en(data_memory_cached_byte_write_enable),
      .o_data_mem_cached_wr_data(data_memory_cached_write_data),
      .o_data_mem_cached_read_enable(data_memory_cached_read_enable),
      .i_cached_read_data(data_memory_cached_read_data),
      .i_cached_read_valid(data_memory_cached_read_valid),
      .i_cached_write_done(data_memory_cached_write_done),
      .i_cached_write_inflight(data_memory_cached_write_inflight),
      .o_mmio_read_pulse(mmio_read_pulse),
      .o_mmio_load_addr(mmio_load_addr),
      .o_mmio_load_valid(mmio_load_valid),
      .o_mmio_fifo0_read_pulse(mmio_fifo0_read_pulse),
      .o_mmio_fifo1_read_pulse(mmio_fifo1_read_pulse),
      .o_mmio_uart_rx_ready_pulse(mmio_uart_rx_ready_pulse),
      .i_data_mem_rd_data(data_memory_or_peripheral_read_data),
      .o_rst_done(/*not connected*/),
      .o_vld   (/*not connected*/),
      .o_pc_vld(/*not connected*/),
      // Interrupt and timer interface
      .i_interrupts(interrupts),
      .i_mtime(mtime),
      // Branch prediction enabled by default in production
      .i_disable_branch_prediction(1'b0)
  );

  // MMIO mask now lives in cpu_ooo at the SQ/AMO source; the BRAM consumes
  // data_memory_bram_byte_write_enable directly. The old address-range check
  // pulled the full data_memory_address mux (and therefore the LQ issue
  // cone) onto the BRAM WEA pin (-1.045 ns WNS path).

  // Dual memory architecture with separate instruction and data memories
  // Both memories receive instruction writes (fan out) on Port A (div4 clock)
  // Memory 0: Port A = instruction programming (div4), Port B = instruction fetch (main clk)
  // Memory 1: Port A = instruction programming (div4), Port B = data access (main clk)

  // ===========================================================================
  // Fetch provider: 1-cycle BRAM (valid tied 1) or the simulation fuzz wrapper
  // ===========================================================================
  // Fetch contract (see if_stage.i_instr_valid): each cycle's window must
  // correspond to the OWED fetch address -- the o_pc value of the last served
  // cycle, retargeted when o_pc moves during an invalid period (only backend
  // redirects move it then; the core holds o_pc while invalid). A variable-
  // latency provider therefore owns a 1-deep owed-ask register and keeps
  // serving it. The fuzz wrapper emulates such a provider over the always-
  // ready BRAM with LFSR-chosen gaps; it exercises the core's fetch-invalid
  // machinery end to end and is the reference model for the L1I front end.
  if (FETCH_VALID_FUZZ != 0) begin : gen_fetch_fuzz
    logic [31:0] fuzz_ask_q;  // owed fetch address
    logic [31:0] pc_prev_q;  // detects o_pc movement
    logic [31:0] served_addr_q;  // address the BRAM output corresponds to
    logic        served_prev_q;  // classifies o_pc movement (flow vs redirect)
    logic [15:0] lfsr_q;
    logic [ 2:0] gap_cnt_q;  // forced multi-cycle gaps
    logic        pipeline_stall_q;  // registered stall (mirror real-provider lag)

    logic        lfsr_feedback;
    logic        fuzz_window_ready;
    logic        fuzz_ok;
    logic        fuzz_accepted;  // valid AND not stalled (decode consumed it)
    assign lfsr_feedback = lfsr_q[15] ^ lfsr_q[13] ^ lfsr_q[12] ^ lfsr_q[10];
    assign fuzz_window_ready = (served_addr_q == fuzz_ask_q);
    assign fuzz_ok = (gap_cnt_q == '0) && (lfsr_q[1:0] != 2'b00);

    // Mirror the real fetch_provider contract: withhold publish-valid while the
    // decode is stalled.  Gate on the REGISTERED stall so the first stall cycle
    // still carries valid (preserving the IF first-cycle capture); the real
    // provider's registered stall produces the same 1-cycle lag.
    assign instruction_valid = fuzz_ok && fuzz_window_ready && !pipeline_stall_q;
    assign fuzz_accepted = instruction_valid && !pipeline_stall;
    // The BRAM chases the owed ask while unserved and the live PC once
    // serving (the 1-cycle BRAM then keeps the window contract-aligned).
    assign fetch_address = instruction_valid ? program_counter : fuzz_ask_q;
    assign instruction = bram_fetch_instr;
    assign instruction_sideband = bram_fetch_sideband;
    assign instruction_bank_sel_r = bram_fetch_bank_sel_cpu_r;

    // No instruction-side cache traffic in fuzz mode (low-BRAM programs).
    assign iup_req_valid = 1'b0;
    assign iup_req_write = 1'b0;
    assign iup_req_addr = '0;
    assign iup_req_wdata = '0;
    assign iup_req_wstrb = '0;

    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        fuzz_ask_q       <= '0;
        pc_prev_q        <= '0;
        served_addr_q    <= '0;
        served_prev_q    <= 1'b0;
        lfsr_q           <= 16'hACE1;
        gap_cnt_q        <= '0;
        pipeline_stall_q <= 1'b0;
      end else begin
        pc_prev_q        <= program_counter;
        served_addr_q    <= fetch_address;
        served_prev_q    <= fuzz_accepted;
        pipeline_stall_q <= pipeline_stall;
        lfsr_q           <= {lfsr_q[14:0], lfsr_feedback};
        if (gap_cnt_q != '0) gap_cnt_q <= gap_cnt_q - 1'b1;
        else if (lfsr_q[7:3] == 5'b00000) gap_cnt_q <= {1'b1, lfsr_q[9:8]};
        if (instruction_valid) begin
          // Served: the current presentation becomes the owed ask.
          fuzz_ask_q <= program_counter;
        end else if (!served_prev_q && !fetch_replay_consume &&
                     (program_counter != pc_prev_q)) begin
          // o_pc moved between two invalid cycles and it was not the
          // (registered) stall-replay consumption advance: that is a
          // backend redirect (the core holds o_pc on invalid cycles
          // otherwise); abandon the old ask and chase the target.
          // Movement at a valid->invalid boundary is normal flow whose ask
          // was already latched on the valid cycle. A replay consumption
          // needs no ask update at all: o_pc sat frozen at the owed ask
          // through the stall, so the held ask is already correct.
          fuzz_ask_q <= program_counter;
        end
      end
    end
  end else if (ENABLE_CACHED_TIER != 0) begin : gen_fetch_provider
    // Hardware fast path: keep low instruction BRAM fetches cycle-equivalent
    // to the direct build.  The source select is registered from the address
    // presented last cycle, matching imem_predecode's registered read latency;
    // low windows remain always-valid, while high windows wait for the L1I
    // provider.
    (* keep = "true", max_fanout = 16 *) logic fetch_high_valid_q;
    (* keep = "true", max_fanout = 16 *) logic fetch_high_instr_q;
    (* keep = "true", max_fanout = 16 *) logic fetch_high_sideband_q;
    logic fetch_high_transition;
    logic [63:0] cached_fetch_instr;
    logic [riscv_pkg::ImemFetchSidebandWidth-1:0] cached_fetch_sideband;
    logic cached_fetch_bank_sel_r;
    logic cached_fetch_valid;

    assign fetch_address = program_counter;

    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        fetch_high_valid_q    <= 1'b0;
        fetch_high_instr_q    <= 1'b0;
        fetch_high_sideband_q <= 1'b0;
      end else begin
        fetch_high_valid_q    <= program_counter[31];
        fetch_high_instr_q    <= program_counter[31];
        fetch_high_sideband_q <= program_counter[31];
      end
    end

    // The source select is registered to match the fetch payload latency.  On
    // low<->high tier crossings, suppress one delivery cycle until the select
    // matches the live PC; otherwise a stale low-BRAM valid can advance the
    // front end while the high-cache provider still owes the branch target.
    assign fetch_high_transition = fetch_high_valid_q ^ program_counter[31];
    assign instruction_valid = fetch_high_transition ? 1'b0 :
                               (fetch_high_valid_q ? cached_fetch_valid : 1'b1);
    assign instruction = fetch_high_instr_q ? cached_fetch_instr : bram_fetch_instr;
    assign instruction_sideband = fetch_high_sideband_q ? cached_fetch_sideband :
                                  bram_fetch_sideband;
    assign instruction_bank_sel_r = fetch_high_valid_q ? cached_fetch_bank_sel_r :
                                                         bram_fetch_bank_sel_cpu_r;

    // High-address provider: two-line L1I fetch buffer for cached/DDR code.
    // It no longer drives the low-BRAM address pins; that path stays direct
    // above for timing and IPC.
    fetch_provider #(
        .LINE_BYTES(32)
    ) u_fetch_provider (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_pc(program_counter),
        .i_fetch_replay_consume(fetch_replay_consume),
        .i_pipeline_stall(pipeline_stall),
        .o_instr(cached_fetch_instr),
        .o_instr_sideband(cached_fetch_sideband),
        .o_instr_bank_sel_r(cached_fetch_bank_sel_r),
        .o_instr_valid(cached_fetch_valid),
        .o_line_req_valid(iup_req_valid),
        .i_line_req_ready(iup_req_ready),
        .o_line_req_write(iup_req_write),
        .o_line_req_addr(iup_req_addr),
        .o_line_req_wdata(iup_req_wdata),
        .o_line_req_wstrb(iup_req_wstrb),
        .i_line_resp_valid(iup_resp_valid),
        .i_line_resp_rdata(iup_resp_rdata),
        // Committed fence.i: drop both buffer lines (and any landing fill)
        // the same cycle the pipeline flushes, before the refetch arrives.
        .i_invalidate(fence_i_flush)
    );
  end else begin : gen_fetch_direct
    assign instruction_valid = 1'b1;
    assign fetch_address = program_counter;
    assign instruction = bram_fetch_instr;
    assign instruction_sideband = bram_fetch_sideband;
    assign instruction_bank_sel_r = bram_fetch_bank_sel_cpu_r;
    assign iup_req_valid = 1'b0;
    assign iup_req_write = 1'b0;
    assign iup_req_addr = '0;
    assign iup_req_wdata = '0;
    assign iup_req_wstrb = '0;
  end

  // Memory 0: Instruction memory with predecode sideband
  // Stores 32-bit instruction data plus a small predecode sideband per word.
  // Sideband bits are computed at write time and keep common IF classification
  // checks off the raw instruction-data -> PC critical path.
  // Port A: Instruction programming only (div4 clock, write only)
  // Port B: Instruction fetch (main clock, read only)
  imem_predecode #(
      .ADDR_WIDTH(MemWordAddrWidth),
      .USE_INIT_FILE(1'b1),
      .INIT_FILE("sw.mem")
  ) instruction_memory (
      .i_port_a_clk(i_clk_div4),
      .i_port_a_enable(1'b1),
      // Port A: Instruction programming (div4 clock, write only)
      .i_port_a_byte_address(i_instr_mem_addr),
      .i_port_a_write_data(i_instr_mem_wrdata),
      .i_port_a_write_enable(i_instr_mem_en),
      .o_port_a_read_data(  /* unused - write only */),
      // Port B: Instruction fetch (main clock, read only)
      .i_port_b_clk(i_clk),
      .i_port_b_enable(1'b1),
      .i_port_b_byte_address(fetch_address),
      .o_port_b_read_data(bram_fetch_instr),
      .o_port_b_sideband(bram_fetch_sideband),
      .o_port_b_bank_sel_r(bram_fetch_bank_sel_r)
  );

  // CPU-local copy of the low-BRAM fetch-word parity.  It samples the same
  // fetch address bit, on the same edge, as imem_predecode.bank_sel_r but
  // avoids using the instruction-memory mux control as a long-distance IF
  // control net.
  always_ff @(posedge i_clk) begin
    bram_fetch_bank_sel_cpu_r <= fetch_address[2];
  end

`ifndef SYNTHESIS
  logic bram_fetch_bank_sel_compare_valid;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      bram_fetch_bank_sel_compare_valid <= 1'b0;
    end else begin
      if (bram_fetch_bank_sel_compare_valid) begin
        assert (bram_fetch_bank_sel_cpu_r == bram_fetch_bank_sel_r)
        else $error("BRAM fetch bank-select CPU copy diverged from imem_predecode");
      end
      bram_fetch_bank_sel_compare_valid <= 1'b1;
    end
  end
`endif

  // Memory 1: Data memory
  // Port A: Instruction programming (div4 clock, write only - fan out)
  // Port B: Data access (main clock, loads/stores from CPU)
  tdp_bram_dc_byte_en #(
      .DATA_WIDTH(32),
      .ADDR_WIDTH(MemWordAddrWidth),
      .USE_INIT_FILE(1'b1),
      .INIT_FILE("sw.mem")  // Software initialization file
  ) data_memory (
      .i_port_a_clk(i_clk_div4),
      .i_port_b_clk(i_clk),
      // Port A: Instruction programming (div4 clock, write only)
      .i_port_a_byte_address(i_instr_mem_addr),
      .i_port_a_write_data(i_instr_mem_wrdata),
      .i_port_a_byte_write_enable(i_instr_mem_we & {4{i_instr_mem_en}}),
      .o_port_a_read_data(  /* unused - write only */),
      // Port B: Data memory for loads and stores
      .i_port_b_byte_address(data_memory_address),
      .i_port_b_write_data(data_memory_write_data),
      .i_port_b_byte_write_enable(data_memory_bram_byte_write_enable),
      .o_port_b_read_data(data_memory_read_data)
  );
  assign o_instr_mem_rddata = instruction[31:0];  // Current word only for programming readback

  // Cached tier: high-address region behind the cache hierarchy. The router
  // only asserts the cached read/write requests for addresses inside the
  // cached range; the adapter serializes them into line transactions through
  // frost_cache_hierarchy (L1 BRAM, optional L2 URAM) and the AXI bridge into
  // main memory. In simulation the main memory is the behavioral DDR model
  // (initialized from sw_ddr.mem, persistent across CPU resets like real
  // DDR); board builds export the bridge's AXI port to the DDR controller
  // instead. A new board can keep ENABLE_CACHED_TIER=0 until its DDR
  // controller is wired up.
  if (ENABLE_CACHED_TIER != 0) begin : gen_cached_tier
    logic line_req_valid, line_req_ready, line_req_write;
    logic [31:0] line_req_addr;
    logic [255:0] line_req_wdata;
    logic [31:0] line_req_wstrb;
    logic line_resp_valid;
    logic [255:0] line_resp_rdata;

    cached_tier_adapter #(
        .XLEN(32),
        .LINE_BYTES(32)
    ) cached_adapter (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_read_req(data_memory_cached_read_enable),
        .i_req_addr(data_memory_address),
        .i_write_byte_en(data_memory_cached_byte_write_enable),
        .i_write_data(data_memory_cached_write_data),
        .o_read_data(data_memory_cached_read_data),
        .o_read_valid(data_memory_cached_read_valid),
        .o_write_done(data_memory_cached_write_done),
        .o_write_inflight(data_memory_cached_write_inflight),
        .o_line_req_valid(line_req_valid),
        .i_line_req_ready(line_req_ready),
        .o_line_req_write(line_req_write),
        .o_line_req_addr(line_req_addr),
        .o_line_req_wdata(line_req_wdata),
        .o_line_req_wstrb(line_req_wstrb),
        .i_line_resp_valid(line_resp_valid),
        .i_line_resp_rdata(line_resp_rdata)
    );

    logic down_req_valid, down_req_ready, down_req_write;
    logic [31:0] down_req_addr;
    logic [255:0] down_req_wdata;
    logic [31:0] down_req_wstrb;
    logic down_resp_valid;
    logic [255:0] down_resp_rdata;

    frost_cache_hierarchy #(
        .ADDR_WIDTH(32),
        .LINE_BYTES(32),
        .HAS_L2(CACHED_HAS_L2),
        .L1_CACHE_BYTES(L1_CACHE_BYTES),
        .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
        .L2_CACHE_BYTES(L2_CACHE_BYTES)
    ) cache_hierarchy (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_up_req_valid(line_req_valid),
        .o_up_req_ready(line_req_ready),
        .i_up_req_write(line_req_write),
        .i_up_req_addr(line_req_addr),
        .i_up_req_wdata(line_req_wdata),
        .i_up_req_wstrb(line_req_wstrb),
        .o_up_resp_valid(line_resp_valid),
        .o_up_resp_rdata(line_resp_rdata),
        .i_iup_req_valid(iup_req_valid),
        .o_iup_req_ready(iup_req_ready),
        .i_iup_req_write(iup_req_write),
        .i_iup_req_addr(iup_req_addr),
        .i_iup_req_wdata(iup_req_wdata),
        .i_iup_req_wstrb(iup_req_wstrb),
        .o_iup_resp_valid(iup_resp_valid),
        .o_iup_resp_rdata(iup_resp_rdata),
        .i_fence_sync(fence_i_sync_req),
        .o_fence_done(fence_i_sync_done),
        .o_down_req_valid(down_req_valid),
        .i_down_req_ready(down_req_ready),
        .o_down_req_write(down_req_write),
        .o_down_req_addr(down_req_addr),
        .o_down_req_wdata(down_req_wdata),
        .o_down_req_wstrb(down_req_wstrb),
        .i_down_resp_valid(down_resp_valid),
        .i_down_resp_rdata(down_resp_rdata)
    );

    logic axi_awvalid, axi_awready, axi_wvalid, axi_wready, axi_bvalid, axi_bready;
    logic axi_arvalid, axi_arready, axi_rvalid, axi_rready, axi_rlast, axi_wlast;
    logic [31:0] axi_awaddr, axi_araddr;
    logic [7:0] axi_awlen, axi_arlen;
    logic [2:0] axi_awsize, axi_arsize;
    logic [1:0] axi_awburst, axi_arburst, axi_bresp, axi_rresp;
    logic [255:0] axi_wdata, axi_rdata;
    logic [31:0] axi_wstrb;

    line_port_axi_bridge #(
        .ADDR_WIDTH(32),
        .LINE_BYTES(32),
        .BASE_ADDR (CACHED_BASE)
    ) ddr_bridge (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_req_valid(down_req_valid),
        .o_req_ready(down_req_ready),
        .i_req_write(down_req_write),
        .i_req_addr(down_req_addr),
        .i_req_wdata(down_req_wdata),
        .i_req_wstrb(down_req_wstrb),
        .o_resp_valid(down_resp_valid),
        .o_resp_rdata(down_resp_rdata),
        .o_axi_awvalid(axi_awvalid),
        .i_axi_awready(axi_awready),
        .o_axi_awaddr(axi_awaddr),
        .o_axi_awlen(axi_awlen),
        .o_axi_awsize(axi_awsize),
        .o_axi_awburst(axi_awburst),
        .o_axi_wvalid(axi_wvalid),
        .i_axi_wready(axi_wready),
        .o_axi_wdata(axi_wdata),
        .o_axi_wstrb(axi_wstrb),
        .o_axi_wlast(axi_wlast),
        .i_axi_bvalid(axi_bvalid),
        .o_axi_bready(axi_bready),
        .i_axi_bresp(axi_bresp),
        .o_axi_arvalid(axi_arvalid),
        .i_axi_arready(axi_arready),
        .o_axi_araddr(axi_araddr),
        .o_axi_arlen(axi_arlen),
        .o_axi_arsize(axi_arsize),
        .o_axi_arburst(axi_arburst),
        .i_axi_rvalid(axi_rvalid),
        .o_axi_rready(axi_rready),
        .i_axi_rdata(axi_rdata),
        .i_axi_rresp(axi_rresp),
        .i_axi_rlast(axi_rlast)
    );

    if (USE_BEHAVIORAL_DDR != 0) begin : gen_behavioral_ddr
      // SIMULATION-ONLY main memory; hardware sets USE_BEHAVIORAL_DDR=0 and
      // takes the bridge's AXI out through the o_ddr_axi_* ports instead.
      axi_behavioral_memory #(
          .LINE_BYTES(32),
          .MEM_BYTES(DDR_MODEL_BYTES),
          .LATENCY(DDR_MODEL_LATENCY),
          .USE_INIT_FILE(1'b1),
          .INIT_FILE("sw_ddr.mem")
      ) ddr_model (
          .i_clk(i_clk),
          .i_rst(i_rst),
          .i_axi_awvalid(axi_awvalid),
          .o_axi_awready(axi_awready),
          .i_axi_awaddr(axi_awaddr),
          .i_axi_awlen(axi_awlen),
          .i_axi_wvalid(axi_wvalid),
          .o_axi_wready(axi_wready),
          .i_axi_wdata(axi_wdata),
          .i_axi_wstrb(axi_wstrb),
          .o_axi_bvalid(axi_bvalid),
          .i_axi_bready(axi_bready),
          .o_axi_bresp(axi_bresp),
          .i_axi_arvalid(axi_arvalid),
          .o_axi_arready(axi_arready),
          .i_axi_araddr(axi_araddr),
          .i_axi_arlen(axi_arlen),
          .o_axi_rvalid(axi_rvalid),
          .i_axi_rready(axi_rready),
          .o_axi_rdata(axi_rdata),
          .o_axi_rresp(axi_rresp),
          .o_axi_rlast(axi_rlast)
      );
      assign o_ddr_axi_awvalid = 1'b0;
      assign o_ddr_axi_awaddr  = '0;
      assign o_ddr_axi_awlen   = '0;
      assign o_ddr_axi_awsize  = '0;
      assign o_ddr_axi_awburst = '0;
      assign o_ddr_axi_wvalid  = 1'b0;
      assign o_ddr_axi_wdata   = '0;
      assign o_ddr_axi_wstrb   = '0;
      assign o_ddr_axi_wlast   = 1'b0;
      assign o_ddr_axi_bready  = 1'b0;
      assign o_ddr_axi_arvalid = 1'b0;
      assign o_ddr_axi_araddr  = '0;
      assign o_ddr_axi_arlen   = '0;
      assign o_ddr_axi_arsize  = '0;
      assign o_ddr_axi_arburst = '0;
      assign o_ddr_axi_rready  = 1'b0;
    end else begin : gen_ddr_axi_export
      // Hardware: the bridge's AXI master goes out to the board's DDR
      // controller subsystem.
      assign o_ddr_axi_awvalid = axi_awvalid;
      assign axi_awready = i_ddr_axi_awready;
      assign o_ddr_axi_awaddr = axi_awaddr;
      assign o_ddr_axi_awlen = axi_awlen;
      assign o_ddr_axi_awsize = axi_awsize;
      assign o_ddr_axi_awburst = axi_awburst;
      assign o_ddr_axi_wvalid = axi_wvalid;
      assign axi_wready = i_ddr_axi_wready;
      assign o_ddr_axi_wdata = axi_wdata;
      assign o_ddr_axi_wstrb = axi_wstrb;
      assign o_ddr_axi_wlast = axi_wlast;
      assign axi_bvalid = i_ddr_axi_bvalid;
      assign o_ddr_axi_bready = axi_bready;
      assign axi_bresp = i_ddr_axi_bresp;
      assign o_ddr_axi_arvalid = axi_arvalid;
      assign axi_arready = i_ddr_axi_arready;
      assign o_ddr_axi_araddr = axi_araddr;
      assign o_ddr_axi_arlen = axi_arlen;
      assign o_ddr_axi_arsize = axi_arsize;
      assign o_ddr_axi_arburst = axi_arburst;
      assign axi_rvalid = i_ddr_axi_rvalid;
      assign o_ddr_axi_rready = axi_rready;
      assign axi_rdata = i_ddr_axi_rdata;
      assign axi_rresp = i_ddr_axi_rresp;
      assign axi_rlast = i_ddr_axi_rlast;
    end
  end else begin : gen_no_cached_tier
    // No hierarchy: the instruction-side line port has no slave.
    assign iup_req_ready = 1'b0;
    assign iup_resp_valid = 1'b0;
    assign iup_resp_rdata = '0;
    // No caches to sync: fence.i completes immediately.
    assign fence_i_sync_done = fence_i_sync_req;
    // Tier disabled (FPGA builds until their DDR controller lands): complete
    // cached-region accesses immediately with zero data so stray software
    // cannot hang the LQ/SQ.
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        data_memory_cached_read_valid <= 1'b0;
        data_memory_cached_write_done <= 1'b0;
      end else begin
        data_memory_cached_read_valid <= data_memory_cached_read_enable;
        data_memory_cached_write_done <= |data_memory_cached_byte_write_enable;
      end
    end
    assign data_memory_cached_read_data = '0;
    assign data_memory_cached_write_inflight = 1'b0;
    assign o_ddr_axi_awvalid = 1'b0;
    assign o_ddr_axi_awaddr = '0;
    assign o_ddr_axi_awlen = '0;
    assign o_ddr_axi_awsize = '0;
    assign o_ddr_axi_awburst = '0;
    assign o_ddr_axi_wvalid = 1'b0;
    assign o_ddr_axi_wdata = '0;
    assign o_ddr_axi_wstrb = '0;
    assign o_ddr_axi_wlast = 1'b0;
    assign o_ddr_axi_bready = 1'b0;
    assign o_ddr_axi_arvalid = 1'b0;
    assign o_ddr_axi_araddr = '0;
    assign o_ddr_axi_arlen = '0;
    assign o_ddr_axi_arsize = '0;
    assign o_ddr_axi_arburst = '0;
    assign o_ddr_axi_rready = 1'b0;
  end

  // Pipeline registers for memory access signals (accounts for RAM read latency)
  logic [3:0] data_memory_byte_write_enable_registered;
  logic       data_memory_read_enable_registered;
  always_ff @(posedge i_clk) begin
    data_memory_address_registered <= data_memory_address;
    data_memory_read_enable_registered <= i_rst ? 1'b0 : data_memory_read_enable;
    data_memory_byte_write_enable_registered <= i_rst ? '0 : data_memory_byte_write_enable;
    data_memory_write_data_registered <= data_memory_write_data;
  end

  // mmio_read_pulse is already range-qualified by cpu_ooo using the same
  // MMIO bounds. Avoid repeating that late address compare here because this
  // signal directly drives the high-fanout MMIO read-data capture enables.
  assign mmio_read_capture = mmio_read_pulse;

  // MMIO read data selection (combinational, captured on mmio_read_pulse)
  always_comb begin
    mmio_read_data_comb = '0;
    // Use MA-stage address captured from CPU for MMIO reads
    unique case (mmio_load_addr)
      // UART RX data - returns received byte in lower 8 bits (reading consumes byte)
      UartRxDataMmioAddr:   mmio_read_data_comb = {24'b0, i_uart_rx_data};
      // UART RX status - bit 0 indicates data available (non-destructive read)
      UartRxStatusMmioAddr: mmio_read_data_comb = {31'b0, i_uart_rx_valid};
      // UART TX status - bit 0 indicates the TX FIFO can accept at least one byte.
      UartTxStatusMmioAddr: mmio_read_data_comb = {31'b0, i_uart_tx_ready};
      Fifo0MmioAddr:        mmio_read_data_comb = i_fifo0_rd_data;
      Fifo1MmioAddr:        mmio_read_data_comb = i_fifo1_rd_data;
      MtimeLowMmioAddr:     mmio_read_data_comb = mtime[31:0];
      MtimeHighMmioAddr:    mmio_read_data_comb = mtime[63:32];
      MtimecmpLowMmioAddr:  mmio_read_data_comb = mtimecmp[31:0];
      MtimecmpHighMmioAddr: mmio_read_data_comb = mtimecmp[63:32];
      MsipMmioAddr:         mmio_read_data_comb = {31'b0, msip};
      default:              ;
    endcase
  end

  // Register MMIO read data so the CPU sees a stable response after the
  // side-effect pulse fires.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      mmio_read_data_valid <= 1'b0;
    end else begin
      if (mmio_read_capture) begin
        mmio_read_data_valid <= 1'b1;
      end else if (mmio_read_data_valid && !mmio_load_valid) begin
        mmio_read_data_valid <= 1'b0;
      end
    end
  end

`ifdef FROST_XILINX_PRIMS
  // Xilinx-specific timing steering: make the MMIO data capture flops explicit
  // so Vivado cannot encode zero-valued read cases as synchronous reset pins.
  for (
      genvar g_mmio_read_data = 0; g_mmio_read_data < 32; g_mmio_read_data++
  ) begin : gen_mmio_read_data_ff
    FDRE #(
        .INIT(1'b0)
    ) mmio_read_data_ff (
        .C (i_clk),
        .CE(mmio_read_capture),
        .D (mmio_read_data_comb[g_mmio_read_data]),
        .Q (mmio_read_data_reg[g_mmio_read_data]),
        .R (1'b0)
    );
  end
`else
  always_ff @(posedge i_clk) begin
    if (mmio_read_capture) begin
      mmio_read_data_reg <= mmio_read_data_comb;
    end
  end
`endif

  // Destructive MMIO read side effects are decoded and registered inside the
  // memory router; keep this boundary as direct routing to the peripherals.

  // Multiplexer for read data - selects between RAM and registered MMIO data
  always_comb begin
    data_memory_or_peripheral_read_data = data_memory_read_data;  // Default: use RAM data
    if (mmio_read_data_valid) data_memory_or_peripheral_read_data = mmio_read_data_reg;
  end

  // write to UART
  always_ff @(posedge i_clk) begin
    o_uart_wr_data <= data_memory_write_data_registered[7:0];  // UART uses only lower byte
    o_uart_wr_en   <= |data_memory_byte_write_enable_registered &&
                       data_memory_address_registered == UartMmioAddr;
  end

  // FIFO write logic - write to FIFOs when CPU writes to FIFO MMIO addresses
  assign o_fifo0_wr_data = data_memory_write_data_registered;
  assign o_fifo0_wr_en   = |data_memory_byte_write_enable_registered &&
                            data_memory_address_registered == Fifo0MmioAddr;
  assign o_fifo1_wr_data = data_memory_write_data_registered;
  assign o_fifo1_wr_en   = |data_memory_byte_write_enable_registered &&
                            data_memory_address_registered == Fifo1MmioAddr;

  // FIFO/UART consume pulses fire one cycle after the MMIO read request is
  // accepted. The response data itself was already captured above.
  assign o_fifo0_rd_en = mmio_fifo0_read_pulse;
  assign o_fifo1_rd_en = mmio_fifo1_read_pulse;
  assign o_uart_rx_ready = mmio_uart_rx_ready_pulse;

  // Timer register updates
  // mtime increments every clock cycle (provides wall-clock time)
  // mtimecmp and msip are memory-mapped writable registers
  //
  // Note: When writing to mtime, we must NOT also increment it in the same cycle.
  // SystemVerilog partial assignments (mtime[31:0] <= ...) only override those bits,
  // leaving other bits to take the value from the full assignment (mtime <= mtime + N).
  // This would cause the non-written half to increment during a write, which is wrong.
  logic writing_mtime_low, writing_mtime_high;
  assign writing_mtime_low = |data_memory_byte_write_enable_registered &&
                             (data_memory_address_registered == MtimeLowMmioAddr);
  assign writing_mtime_high = |data_memory_byte_write_enable_registered &&
                              (data_memory_address_registered == MtimeHighMmioAddr);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      mtime <= 64'd0;
      mtimecmp <= MtimecmpDefault;
      msip <= 1'b0;
    end else begin
      // mtime update: either write from CPU or increment (not both)
      if (writing_mtime_low) begin
        mtime[31:0] <= data_memory_write_data_registered;
        // High bits: don't increment, just hold value
      end else if (writing_mtime_high) begin
        mtime[63:32] <= data_memory_write_data_registered;
        // Low bits: don't increment, just hold value
      end else begin
        // Normal operation: increment mtime (speedup factor for simulation)
        mtime <= mtime + 64'(SIM_TIMER_SPEEDUP);
      end

      // mtimecmp and msip writes
      if (|data_memory_byte_write_enable_registered) begin
        unique case (data_memory_address_registered)
          // mtimecmp controls timer interrupt threshold
          MtimecmpLowMmioAddr:  mtimecmp[31:0] <= data_memory_write_data_registered;
          MtimecmpHighMmioAddr: mtimecmp[63:32] <= data_memory_write_data_registered;
          // msip controls software interrupt (only bit 0 is writable)
          MsipMmioAddr:         msip <= data_memory_write_data_registered[0];
          default:              ;
        endcase
      end
    end
  end

endmodule : cpu_and_mem
