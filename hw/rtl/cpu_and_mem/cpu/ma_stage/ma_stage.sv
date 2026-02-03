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
  Memory Access (MA) stage - Fifth stage of the 6-stage RISC-V pipeline.
  This module completes memory load operations by processing data read from memory
  or cache. It contains a load unit that handles different data sizes (byte, halfword,
  word) and sign/zero extension based on the instruction type. The stage receives
  ALU results and memory data from the EX stage, processes loads through the load unit,
  and forwards either the load result or ALU result to the Write Back stage. The pipeline
  register at the end of this stage prepares the final result for register file writeback.

  F Extension support:
  - FLW (FP load word) uses the same memory path as LW, but writes to FP register file
  - FSW (FP store word) is handled entirely in EX stage (store unit)
  - FP computation results and flags are passed through to WB stage
*/
module ma_stage #(
    parameter int unsigned XLEN = 32,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000,
    parameter int unsigned MMIO_SIZE_BYTES = 32'h28
) (
    input logic i_clk,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input logic [XLEN-1:0] i_data_mem_rd_data,
    input riscv_pkg::from_ex_to_ma_t i_from_ex_to_ma,
    // A extension: AMO result (old value) from AMO unit
    input logic [XLEN-1:0] i_amo_result,
    input logic i_amo_write_enable,
    output riscv_pkg::from_ma_comb_t o_from_ma_comb,
    output riscv_pkg::from_ma_to_wb_t o_from_ma_to_wb,
    // Delayed AMO write enable signal for regfile bypass
    output logic o_amo_write_enable_delayed,
    // FP64 load/store sequencing (FLD/FSD)
    output logic o_stall_for_fp_mem,
    output logic o_fp_mem_addr_override,
    output logic [XLEN-1:0] o_fp_mem_address,
    output logic [XLEN-1:0] o_fp_mem_write_data,
    output logic [3:0] o_fp_mem_byte_write_enable
);

  localparam int unsigned FpWidth = riscv_pkg::FpWidth;

  // Memory read data handling with block RAM latency compensation
  logic [XLEN-1:0] data_memory_read_data;
  logic [XLEN-1:0] data_memory_read_data_registered;

  // MMIO loads use registered data from cpu_and_mem, so bypass local stall capture.
  logic is_mmio_load;
  assign is_mmio_load =
      (i_from_ex_to_ma.is_load_instruction | i_from_ex_to_ma.is_lr |
       i_from_ex_to_ma.is_fp_load) &&
      (i_from_ex_to_ma.data_memory_address >= MMIO_ADDR) &&
      (i_from_ex_to_ma.data_memory_address < (MMIO_ADDR + MMIO_SIZE_BYTES));

  /*
    Handle memory read data with block RAM latency.
    Data is delayed by 1 cycle, so we must preserve it during stalls
    to ensure the same data is available throughout a stalled cycle.
  */
  always_ff @(posedge i_clk)
    if (i_pipeline_ctrl.stall & ~i_pipeline_ctrl.stall_registered & ~is_mmio_load)
      data_memory_read_data_registered <= i_data_mem_rd_data;

  // ===========================================================================
  // FP64 Load/Store Sequencing (FLD/FSD)
  // ===========================================================================
  // 32-bit memory interface requires two accesses for 64-bit FP loads/stores.
  // - FLD: capture low word, issue high-word read (addr+4) with a one-cycle stall
  // - FSD: write low word, then high word (addr+4) with a two-cycle stall

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

  logic use_direct_mem_data;
  // For FLD low/high-word reads, bypass the stall-held data to capture fresh words.
  assign use_direct_mem_data = is_mmio_load | fp_load_start | (fp_mem_state == FP_MEM_LOAD_HI);
  assign data_memory_read_data = use_direct_mem_data ? i_data_mem_rd_data :
                                 (i_pipeline_ctrl.stall_registered ?
                                  data_memory_read_data_registered :
                                  i_data_mem_rd_data);

  // Only start when pipeline is advancing and address is 8-byte aligned
  assign fp_mem_block = fp_mem_processed && i_pipeline_ctrl.stall_registered;

  assign fp_load_start = (fp_mem_state == FP_MEM_IDLE) &&
                         i_from_ex_to_ma.is_fp_load_double &&
                         !fp_mem_block &&
                         (i_from_ex_to_ma.data_memory_address[2:0] == 3'b000);

  assign fp_store_start = (fp_mem_state == FP_MEM_IDLE) &&
                          i_from_ex_to_ma.is_fp_store_double &&
                          !fp_mem_block &&
                          (i_from_ex_to_ma.data_memory_address[2:0] == 3'b000);

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
    if (i_pipeline_ctrl.reset || i_pipeline_ctrl.flush) begin
      fp_mem_state <= FP_MEM_IDLE;
    end else begin
      fp_mem_state <= fp_mem_state_next;
    end
  end

  // Capture base address and low word for FLD, and store data for FSD
  always_ff @(posedge i_clk) begin
    if (fp_load_start) begin
      fp_mem_base_addr <= i_from_ex_to_ma.data_memory_address;
      fp_load_low_word <= data_memory_read_data;
    end else if (fp_store_start) begin
      fp_mem_base_addr  <= i_from_ex_to_ma.data_memory_address;
      fp_store_data_reg <= i_from_ex_to_ma.fp_store_data;
    end
  end

  // Prevent re-triggering during stalls (same pattern as AMO)
  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset || i_pipeline_ctrl.flush) begin
      fp_mem_processed <= 1'b0;
    end else if (fp_load_start || fp_store_start) begin
      fp_mem_processed <= 1'b1;
    end else if (!o_stall_for_fp_mem && !i_pipeline_ctrl.stall) begin
      fp_mem_processed <= 1'b0;
    end
  end

  // Stall generation: FLD/FSD stall until the high word completes
  assign o_stall_for_fp_mem = fp_load_start | fp_store_start |
                              (fp_mem_state == FP_MEM_LOAD_HI) |
                              (fp_mem_state == FP_MEM_STORE_HI);

  // Memory interface override for FP64 access
  always_comb begin
    o_fp_mem_addr_override = 1'b0;
    o_fp_mem_address = '0;
    o_fp_mem_write_data = '0;
    o_fp_mem_byte_write_enable = 4'b0000;

    if (fp_load_start) begin
      // Issue high-word read (addr + 4) for FLD
      o_fp_mem_addr_override = 1'b1;
      o_fp_mem_address = i_from_ex_to_ma.data_memory_address + 32'd4;
    end else if (fp_store_start) begin
      // Write low word for FSD
      o_fp_mem_addr_override = 1'b1;
      o_fp_mem_address = i_from_ex_to_ma.data_memory_address;
      o_fp_mem_write_data = i_from_ex_to_ma.fp_store_data[31:0];
      o_fp_mem_byte_write_enable = 4'b1111;
    end else if (fp_mem_state == FP_MEM_STORE_HI) begin
      // Write high word for FSD
      o_fp_mem_addr_override = 1'b1;
      o_fp_mem_address = fp_mem_base_addr + 32'd4;
      o_fp_mem_write_data = fp_store_data_reg[FpWidth-1:32];
      o_fp_mem_byte_write_enable = 4'b1111;
    end
  end

  // FP load data assembly (boxed for FLW)
  logic [FpWidth-1:0] fp_load_data;
  logic [FpWidth-1:0] fp_load_data_direct;
  logic fp_load_data_valid;
  logic [FpWidth-1:0] fp_load_data_latched;

  // Latch full 64-bit load data when high word arrives so it stays stable
  // across later stalls (e.g., FPU pipeline stalls).
  always_ff @(posedge i_clk) begin
    if (fp_mem_state == FP_MEM_LOAD_HI) begin
      fp_load_data_latched <= {data_memory_read_data, fp_load_low_word};
    end
  end

  assign fp_load_data = i_from_ex_to_ma.is_fp_load_double ?
                        ((fp_mem_state == FP_MEM_LOAD_HI) ?
                         {data_memory_read_data, fp_load_low_word} :
                         fp_load_data_latched) :
                        {{(FpWidth-32){1'b1}}, data_memory_read_data};

  assign fp_load_data_direct = i_from_ex_to_ma.is_fp_load_double ?
                               ((fp_mem_state == FP_MEM_LOAD_HI) ?
                                {i_data_mem_rd_data, fp_load_low_word} :
                                fp_load_data_latched) :
                               {{(FpWidth-32){1'b1}}, i_data_mem_rd_data};

  assign fp_load_data_valid = i_from_ex_to_ma.is_fp_load_double ?
                              (fp_mem_state == FP_MEM_LOAD_HI) :
                              i_from_ex_to_ma.is_fp_load;

  // Load unit extracts and sign/zero-extends the appropriate bytes
  load_unit #(
      .XLEN(XLEN)
  ) load_unit_inst (
      .i_is_load_halfword(i_from_ex_to_ma.is_load_halfword),
      .i_is_load_byte(i_from_ex_to_ma.is_load_byte),
      .i_is_load_unsigned(i_from_ex_to_ma.is_load_unsigned),
      .i_data_memory_address(i_from_ex_to_ma.data_memory_address),
      .i_data_memory_read_data(data_memory_read_data),
      .o_data_loaded_from_memory(o_from_ma_comb.data_loaded_from_memory)
  );

  // Delayed AMO write enable - used to update MA->WB one cycle after WRITE stall ends
  // This allows the pre-AMO instruction in WB to retire before we update MA->WB
  logic amo_write_enable_delayed;
  always_ff @(posedge i_clk)
    if (i_pipeline_ctrl.reset) amo_write_enable_delayed <= 1'b0;
    else amo_write_enable_delayed <= i_amo_write_enable;

  // Track pending AMO update when AMO completes during another stall (e.g., multiply/divide)
  // We can't update from_ma_to_wb immediately or we'd destroy the pending instruction
  logic amo_update_pending;
  logic [XLEN-1:0] saved_amo_result;
  riscv_pkg::instr_t saved_amo_instruction;
  logic saved_amo_regfile_write_enable;

  always_ff @(posedge i_clk) begin
    if (i_pipeline_ctrl.reset) begin
      amo_update_pending <= 1'b0;
    end else if (amo_write_enable_delayed) begin
      if (i_pipeline_ctrl.stall) begin
        // AMO completed but another stall is active - save for later
        amo_update_pending <= 1'b1;
      end
      // If not stalled, we'll update directly (handled below), no pending needed
    end else if (~i_pipeline_ctrl.stall && amo_update_pending) begin
      // Stall ended and we have a pending AMO update - clear the flag
      // (the actual update happens in the pipeline register block below)
      amo_update_pending <= 1'b0;
    end
  end
  always_ff @(posedge i_clk) begin
    if (amo_write_enable_delayed && i_pipeline_ctrl.stall) begin
      saved_amo_result <= i_amo_result;
      saved_amo_instruction <= i_from_ex_to_ma.instruction;
      saved_amo_regfile_write_enable <= i_from_ex_to_ma.regfile_write_enable;
    end
  end

  // Signal to trigger AMO update: either immediate (stall=0) or deferred (pending cleared)
  logic do_amo_update;
  assign do_amo_update = (amo_write_enable_delayed && ~i_pipeline_ctrl.stall) ||
                         (amo_update_pending && ~i_pipeline_ctrl.stall);

  // Pipeline register to Write Back stage
  always_ff @(posedge i_clk) begin
    // Reset control signals (instruction and write enable)
    if (i_pipeline_ctrl.reset) begin
      o_from_ma_to_wb.instruction <= riscv_pkg::NOP;
      o_from_ma_to_wb.regfile_write_enable <= 1'b0;
      // F extension
      o_from_ma_to_wb.fp_regfile_write_enable <= 1'b0;
      o_from_ma_to_wb.fp_regfile_write_data <= '0;
      o_from_ma_to_wb.fp_flags <= '0;
      o_from_ma_to_wb.fp_dest_reg <= 5'b0;
    end else if (do_amo_update) begin
      // AMO update: either immediate or deferred from pending
      if (amo_update_pending) begin
        // Use saved values from when AMO completed during another stall
        o_from_ma_to_wb.instruction <= saved_amo_instruction;
        o_from_ma_to_wb.regfile_write_enable <= saved_amo_regfile_write_enable;
      end else begin
        // Immediate update - AMO just completed and pipeline not stalled
        o_from_ma_to_wb.instruction <= i_from_ex_to_ma.instruction;
        o_from_ma_to_wb.regfile_write_enable <= i_from_ex_to_ma.regfile_write_enable;
      end
    end else if (~i_pipeline_ctrl.stall) begin
      o_from_ma_to_wb.instruction <= i_from_ex_to_ma.instruction;
      o_from_ma_to_wb.regfile_write_enable <= i_from_ex_to_ma.regfile_write_enable;
    end
    // Datapath signals are not reset (only affected by stall)
    if (do_amo_update) begin
      // AMO update - use appropriate result based on source
      if (amo_update_pending) begin
        o_from_ma_to_wb.regfile_write_data <= saved_amo_result;
      end else begin
        o_from_ma_to_wb.regfile_write_data <= i_amo_result;
      end
    end else if (~i_pipeline_ctrl.stall) begin
      // Select write data based on instruction type:
      // - Load instructions (LW, LH, LB, etc.): use loaded/sign-extended data
      // - LR.W (load-reserved): use loaded data (like a load)
      // - SC.W (store-conditional): use sc_success result (0=success, 1=fail)
      // - FP-to-int (FMV.X.W, FCVT.W.S, etc.): use FP result
      // - Other instructions: use ALU result
      if (i_from_ex_to_ma.is_load_instruction || i_from_ex_to_ma.is_lr) begin
        o_from_ma_to_wb.regfile_write_data <= o_from_ma_comb.data_loaded_from_memory;
      end else if (i_from_ex_to_ma.is_sc) begin
        // SC.W: write 0 if success, 1 if fail
        o_from_ma_to_wb.regfile_write_data <= {31'b0, ~i_from_ex_to_ma.sc_success};
      end else if (i_from_ex_to_ma.is_fp_to_int) begin
        // FP-to-int: use FP result for integer regfile write
        o_from_ma_to_wb.regfile_write_data <= i_from_ex_to_ma.fp_result[XLEN-1:0];
      end else begin
        o_from_ma_to_wb.regfile_write_data <= i_from_ex_to_ma.alu_result;
      end
      // F extension: FP write data and flags
      // FLW/FLD: use memory data (boxed/assembled), FP compute: use fp_result from EX stage
      if (i_from_ex_to_ma.is_fp_load) begin
        o_from_ma_to_wb.fp_regfile_write_data <= fp_load_data;
      end else begin
        o_from_ma_to_wb.fp_regfile_write_data <= i_from_ex_to_ma.fp_result;
      end
      o_from_ma_to_wb.fp_regfile_write_enable <= i_from_ex_to_ma.fp_regfile_write_enable;
      o_from_ma_to_wb.fp_flags <= i_from_ex_to_ma.fp_flags;
      o_from_ma_to_wb.fp_dest_reg <= i_from_ex_to_ma.fp_dest_reg;
    end
  end

  // Signals for L0 cache updates and data forwarding
  assign o_from_ma_comb.data_memory_read_data = data_memory_read_data;
  // F extension: Direct BRAM output for FP load forwarding (bypasses stall_registered mux)
  assign o_from_ma_comb.data_memory_read_data_direct = i_data_mem_rd_data;
  assign o_from_ma_comb.fp_load_data = fp_load_data;
  assign o_from_ma_comb.fp_load_data_direct = fp_load_data_direct;
  assign o_from_ma_comb.fp_load_data_valid = fp_load_data_valid;

  // Output the delayed AMO write enable for regfile bypass
  assign o_amo_write_enable_delayed = amo_write_enable_delayed;

endmodule : ma_stage
