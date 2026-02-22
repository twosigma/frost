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
  // Extracted into fp64_sequencer module. See fp64_sequencer.sv for details.

  logic use_direct_mem_data;
  logic [FpWidth-1:0] fp_load_data;
  logic [FpWidth-1:0] fp_load_data_direct;
  logic fp_load_data_valid;

  fp64_sequencer #(
      .XLEN(XLEN)
  ) fp64_sequencer_inst (
      .i_clk                     (i_clk),
      .i_reset                   (i_pipeline_ctrl.reset),
      .i_flush                   (i_pipeline_ctrl.flush),
      .i_stall                   (i_pipeline_ctrl.stall),
      .i_stall_registered        (i_pipeline_ctrl.stall_registered),
      .i_data_mem_rd_data        (i_data_mem_rd_data),
      .i_data_memory_read_data   (data_memory_read_data),
      .i_is_mmio_load            (is_mmio_load),
      .i_is_fp_load              (i_from_ex_to_ma.is_fp_load),
      .i_is_fp_load_double       (i_from_ex_to_ma.is_fp_load_double),
      .i_is_fp_store_double      (i_from_ex_to_ma.is_fp_store_double),
      .i_data_memory_address     (i_from_ex_to_ma.data_memory_address),
      .i_fp_store_data           (i_from_ex_to_ma.fp_store_data),
      .o_stall_for_fp_mem        (o_stall_for_fp_mem),
      .o_fp_mem_addr_override    (o_fp_mem_addr_override),
      .o_fp_mem_address          (o_fp_mem_address),
      .o_fp_mem_write_data       (o_fp_mem_write_data),
      .o_fp_mem_byte_write_enable(o_fp_mem_byte_write_enable),
      .o_use_direct_mem_data     (use_direct_mem_data),
      .o_fp_load_data            (fp_load_data),
      .o_fp_load_data_direct     (fp_load_data_direct),
      .o_fp_load_data_valid      (fp_load_data_valid)
  );

  assign data_memory_read_data = use_direct_mem_data ? i_data_mem_rd_data :
                                 (i_pipeline_ctrl.stall_registered ?
                                  data_memory_read_data_registered :
                                  i_data_mem_rd_data);

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
      o_from_ma_to_wb.is_fp_to_int <= 1'b0;
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
      o_from_ma_to_wb.is_fp_load <= i_from_ex_to_ma.is_fp_load || i_from_ex_to_ma.is_fp_load_double;
      o_from_ma_to_wb.is_fp_to_int <= i_from_ex_to_ma.is_fp_to_int;
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
