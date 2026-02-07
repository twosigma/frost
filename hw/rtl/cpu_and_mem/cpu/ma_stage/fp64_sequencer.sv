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
 * FP64 Load/Store Sequencer
 *
 * Handles double-precision (64-bit) FP load and store operations on a 32-bit
 * memory interface. Each FLD or FSD requires two 32-bit memory accesses:
 *
 *   FLD: Read low word at addr, then read high word at addr+4. Assemble into
 *        a single 64-bit value. One-cycle stall while the high word is read.
 *
 *   FSD: Write low word at addr, then write high word at addr+4. Two-cycle
 *        stall for the two writes.
 *
 * The sequencer also produces:
 *   - use_direct_mem_data: control for the memory-data mux (bypasses stall-held
 *     registered data during FLD reads and MMIO loads)
 *   - fp_load_data / fp_load_data_direct / fp_load_data_valid: assembled 64-bit
 *     load result for the FP register file (handles NaN-boxing for FLW as well)
 *
 * Related Modules:
 *   - ma_stage.sv: Instantiates this module
 *   - load_unit.sv: Integer load byte/halfword extraction (parallel path)
 */
module fp64_sequencer #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,

    // Pipeline control
    input logic i_reset,
    input logic i_flush,
    input logic i_stall,
    input logic i_stall_registered,

    // Raw memory read data (direct from BRAM / memory)
    input logic [XLEN-1:0] i_data_mem_rd_data,

    // Muxed memory read data (after stall-hold logic in ma_stage)
    input logic [XLEN-1:0] i_data_memory_read_data,

    // MMIO load indicator (from ma_stage)
    input logic i_is_mmio_load,

    // Relevant fields from EX->MA pipeline register
    input logic                          i_is_fp_load,
    input logic                          i_is_fp_load_double,
    input logic                          i_is_fp_store_double,
    input logic [              XLEN-1:0] i_data_memory_address,
    input logic [riscv_pkg::FpWidth-1:0] i_fp_store_data,

    // Stall request to pipeline
    output logic o_stall_for_fp_mem,

    // Memory interface override for FP64 second-word access
    output logic            o_fp_mem_addr_override,
    output logic [XLEN-1:0] o_fp_mem_address,
    output logic [XLEN-1:0] o_fp_mem_write_data,
    output logic [     3:0] o_fp_mem_byte_write_enable,

    // Memory data mux control: when high, ma_stage should use i_data_mem_rd_data
    // directly instead of the stall-held registered path.
    output logic o_use_direct_mem_data,

    // Assembled FP load data for the register file
    output logic [riscv_pkg::FpWidth-1:0] o_fp_load_data,
    output logic [riscv_pkg::FpWidth-1:0] o_fp_load_data_direct,
    output logic                          o_fp_load_data_valid
);

  localparam int unsigned FpWidth = riscv_pkg::FpWidth;

  // ===========================================================================
  // State Machine
  // ===========================================================================

  typedef enum logic [1:0] {
    FP_MEM_IDLE,
    FP_MEM_LOAD_HI,
    FP_MEM_STORE_HI
  } fp_mem_state_e;

  fp_mem_state_e fp_mem_state, fp_mem_state_next;
  logic fp_mem_processed;
  logic fp_load_start;
  logic fp_store_start;
  logic fp_mem_block;

  logic [XLEN-1:0] fp_mem_base_addr;
  logic [XLEN-1:0] fp_load_low_word;
  logic [FpWidth-1:0] fp_store_data_reg;

  // For FLD low/high-word reads, bypass the stall-held data to capture fresh words.
  assign o_use_direct_mem_data = i_is_mmio_load | fp_load_start | (fp_mem_state == FP_MEM_LOAD_HI);

  // Only start when pipeline is advancing and address is 8-byte aligned
  assign fp_mem_block = fp_mem_processed && i_stall_registered;

  assign fp_load_start = (fp_mem_state == FP_MEM_IDLE) &&
                         i_is_fp_load_double &&
                         !fp_mem_block &&
                         (i_data_memory_address[2:0] == 3'b000);

  assign fp_store_start = (fp_mem_state == FP_MEM_IDLE) &&
                          i_is_fp_store_double &&
                          !fp_mem_block &&
                          (i_data_memory_address[2:0] == 3'b000);

  // State transitions
  always_comb begin
    fp_mem_state_next = fp_mem_state;
    unique case (fp_mem_state)
      FP_MEM_IDLE: begin
        if (fp_load_start) fp_mem_state_next = FP_MEM_LOAD_HI;
        else if (fp_store_start) fp_mem_state_next = FP_MEM_STORE_HI;
      end
      FP_MEM_LOAD_HI: begin
        fp_mem_state_next = FP_MEM_IDLE;
      end
      FP_MEM_STORE_HI: begin
        fp_mem_state_next = FP_MEM_IDLE;
      end
      default: fp_mem_state_next = FP_MEM_IDLE;
    endcase
  end

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush) begin
      fp_mem_state <= FP_MEM_IDLE;
    end else begin
      fp_mem_state <= fp_mem_state_next;
    end
  end

  // Capture base address and low word for FLD, and store data for FSD
  always_ff @(posedge i_clk) begin
    if (fp_load_start) begin
      fp_mem_base_addr <= i_data_memory_address;
      fp_load_low_word <= i_data_memory_read_data;
    end else if (fp_store_start) begin
      fp_mem_base_addr  <= i_data_memory_address;
      fp_store_data_reg <= i_fp_store_data;
    end
  end

  // Prevent re-triggering during stalls (same pattern as AMO)
  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush) begin
      fp_mem_processed <= 1'b0;
    end else if (fp_load_start || fp_store_start) begin
      fp_mem_processed <= 1'b1;
    end else if (!o_stall_for_fp_mem && !i_stall) begin
      fp_mem_processed <= 1'b0;
    end
  end

  // Stall generation: FLD/FSD stall until the high word completes
  assign o_stall_for_fp_mem = fp_load_start | fp_store_start |
                              (fp_mem_state == FP_MEM_LOAD_HI) |
                              (fp_mem_state == FP_MEM_STORE_HI);

  // ===========================================================================
  // Memory Interface Override for FP64 Access
  // ===========================================================================

  always_comb begin
    o_fp_mem_addr_override = 1'b0;
    o_fp_mem_address = '0;
    o_fp_mem_write_data = '0;
    o_fp_mem_byte_write_enable = 4'b0000;

    if (fp_load_start) begin
      // Issue high-word read (addr + 4) for FLD
      o_fp_mem_addr_override = 1'b1;
      o_fp_mem_address = i_data_memory_address + 32'd4;
    end else if (fp_store_start) begin
      // Write low word for FSD
      o_fp_mem_addr_override = 1'b1;
      o_fp_mem_address = i_data_memory_address;
      o_fp_mem_write_data = i_fp_store_data[31:0];
      o_fp_mem_byte_write_enable = 4'b1111;
    end else if (fp_mem_state == FP_MEM_STORE_HI) begin
      // Write high word for FSD
      o_fp_mem_addr_override = 1'b1;
      o_fp_mem_address = fp_mem_base_addr + 32'd4;
      o_fp_mem_write_data = fp_store_data_reg[FpWidth-1:32];
      o_fp_mem_byte_write_enable = 4'b1111;
    end
  end

  // ===========================================================================
  // FP Load Data Assembly (boxed for FLW)
  // ===========================================================================

  logic [FpWidth-1:0] fp_load_data_latched;

  // Latch full 64-bit load data when high word arrives so it stays stable
  // across later stalls (e.g., FPU pipeline stalls).
  always_ff @(posedge i_clk) begin
    if (fp_mem_state == FP_MEM_LOAD_HI) begin
      fp_load_data_latched <= {i_data_memory_read_data, fp_load_low_word};
    end
  end

  assign o_fp_load_data = i_is_fp_load_double ?
                          ((fp_mem_state == FP_MEM_LOAD_HI) ?
                           {i_data_memory_read_data, fp_load_low_word} :
                           fp_load_data_latched) :
                          {{(FpWidth-32){1'b1}}, i_data_memory_read_data};

  assign o_fp_load_data_direct = i_is_fp_load_double ?
                                 ((fp_mem_state == FP_MEM_LOAD_HI) ?
                                  {i_data_mem_rd_data, fp_load_low_word} :
                                  fp_load_data_latched) :
                                 {{(FpWidth-32){1'b1}}, i_data_mem_rd_data};

  assign o_fp_load_data_valid = i_is_fp_load_double ?
                                (fp_mem_state == FP_MEM_LOAD_HI) :
                                i_is_fp_load;

endmodule : fp64_sequencer
