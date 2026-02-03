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
  instantiates a 6-stage pipelined RISC-V CPU alongside two separate dual-port RAMs:
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
    parameter int unsigned SIM_TIMER_SPEEDUP = 1
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
    input logic i_external_interrupt
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
  localparam int unsigned MmioSizeBytes = 32'h28;
  localparam int unsigned UartMmioAddr = 32'h4000_0000;  // UART TX (write-only)
  localparam int unsigned UartRxDataMmioAddr = 32'h4000_0004;  // UART RX data (read consumes byte)
  localparam int unsigned UartRxStatusMmioAddr = 32'h4000_0024; // RX status (bit0 = data available)
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
  logic [31:0] program_counter, instruction;
  logic [31:0] data_memory_address, data_memory_write_data, data_memory_write_data_registered;
  logic                  [31:0] data_memory_or_peripheral_read_data;  // Muxed from RAM or MMIO
  logic                  [31:0] mmio_read_data_comb;
  logic                  [31:0] mmio_read_data_reg;
  logic                         is_mmio_registered;
  logic                  [31:0] mmio_load_addr;
  logic                         mmio_load_valid;
  logic                  [31:0] data_memory_read_data;  // From RAM only
  logic                  [31:0] data_memory_address_registered;  // Delayed for read data alignment
  logic                  [ 3:0] data_memory_byte_write_enable;
  logic                         data_memory_read_enable;
  logic                         mmio_read_pulse;

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

  // RISC-V CPU core - 6-stage pipeline with RV32IMAB + Zicsr + Machine-mode
  // Note: B = Zba + Zbb + Zbs (full bit manipulation extension)
  cpu #(
      .MEM_BYTE_ADDR_WIDTH(MemByteAddrWidth),
      .MMIO_ADDR(MmioAddr),
      .MMIO_SIZE_BYTES(MmioSizeBytes)
  ) cpu_inst (
      .i_clk,
      .i_rst,
      .o_pc(program_counter),
      .i_instr(instruction),
      .o_data_mem_addr(data_memory_address),
      .o_data_mem_wr_data(data_memory_write_data),
      .o_data_mem_per_byte_wr_en(data_memory_byte_write_enable),
      .o_data_mem_read_enable(data_memory_read_enable),
      .o_mmio_read_pulse(mmio_read_pulse),
      .o_mmio_load_addr(mmio_load_addr),
      .o_mmio_load_valid(mmio_load_valid),
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

  logic is_mmio;
  assign is_mmio = (data_memory_address >= MmioAddr) &&
                   (data_memory_address < (MmioAddr + MmioSizeBytes));

  // Dual memory architecture with separate instruction and data memories
  // Both memories receive instruction writes (fan out) on Port A (div4 clock)
  // Memory 0: Port A = instruction programming (div4), Port B = instruction fetch (main clk)
  // Memory 1: Port A = instruction programming (div4), Port B = data access (main clk)

  // Memory 0: Instruction memory (uses simpler BRAM without byte enables or write-first)
  // Port A: Instruction programming only (div4 clock, write only)
  // Port B: Instruction fetch (main clock, read only)
  tdp_bram_dc #(
      .DATA_WIDTH(32),
      .ADDR_WIDTH(MemWordAddrWidth),
      .USE_INIT_FILE(1'b1),
      .INIT_FILE("sw.mem")  // Software initialization file
  ) instruction_memory (
      .i_port_a_clk(i_clk_div4),
      .i_port_a_enable(1'b1),
      .i_port_b_clk(i_clk),
      .i_port_b_enable(1'b1),
      // Port A: Instruction programming (div4 clock, write only)
      .i_port_a_byte_address(i_instr_mem_addr),
      .i_port_a_write_data(i_instr_mem_wrdata),
      .i_port_a_write_enable(i_instr_mem_en),
      .o_port_a_read_data(  /* unused - write only */),
      // Port B: Instruction fetch (main clock, read only)
      .i_port_b_byte_address(program_counter),
      .i_port_b_write_data('0),
      .i_port_b_write_enable(1'b0),
      .o_port_b_read_data(instruction)
  );

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
      .i_port_b_byte_write_enable(data_memory_byte_write_enable & {4{~is_mmio}}),
      .o_port_b_read_data(data_memory_read_data)
  );
  assign o_instr_mem_rddata = instruction;

  // Pipeline registers for memory access signals (accounts for RAM read latency)
  logic [3:0] data_memory_byte_write_enable_registered;
  always_ff @(posedge i_clk) begin
    data_memory_address_registered <= data_memory_address;
    data_memory_byte_write_enable_registered <= i_rst ? '0 : data_memory_byte_write_enable;
    data_memory_write_data_registered <= data_memory_write_data;
  end

  assign is_mmio_registered = mmio_load_valid &&
                              (mmio_load_addr >= MmioAddr) &&
                              (mmio_load_addr < (MmioAddr + MmioSizeBytes));

  // MMIO read data selection (combinational, captured on mmio_read_pulse)
  always_comb begin
    mmio_read_data_comb = '0;
    // Use MA-stage address captured from CPU for MMIO reads
    unique case (mmio_load_addr)
      // UART RX data - returns received byte in lower 8 bits (reading consumes byte)
      UartRxDataMmioAddr:   mmio_read_data_comb = {24'b0, i_uart_rx_data};
      // UART RX status - bit 0 indicates data available (non-destructive read)
      UartRxStatusMmioAddr: mmio_read_data_comb = {31'b0, i_uart_rx_valid};
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

  // Register MMIO read data to break combinational FIFO/UART paths into the core.
  always_ff @(posedge i_clk) begin
    if (i_rst) mmio_read_data_reg <= '0;
    else if (mmio_read_pulse && is_mmio_registered) mmio_read_data_reg <= mmio_read_data_comb;
  end

  // Multiplexer for read data - selects between RAM and registered MMIO data
  always_comb begin
    data_memory_or_peripheral_read_data = data_memory_read_data;  // Default: use RAM data
    if (is_mmio_registered) data_memory_or_peripheral_read_data = mmio_read_data_reg;
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

  // FIFO read enable generation - pulse on MMIO load (two-cycle bubble in CPU)
  assign o_fifo0_rd_en = (data_memory_address_registered == Fifo0MmioAddr) && mmio_read_pulse;
  assign o_fifo1_rd_en = (data_memory_address_registered == Fifo1MmioAddr) && mmio_read_pulse;

  // UART RX ready generation - pulses on load from UART RX data address
  // This consumes the byte from the RX FIFO
  assign o_uart_rx_ready = (data_memory_address_registered == UartRxDataMmioAddr) &&
                           mmio_read_pulse;

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
