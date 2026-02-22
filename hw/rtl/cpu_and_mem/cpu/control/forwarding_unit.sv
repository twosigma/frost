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
 * Data Forwarding Unit - RAW hazard resolution via register bypass
 *
 * This module eliminates most pipeline stalls due to data dependencies by
 * forwarding results from later pipeline stages to the EX stage inputs.
 *
 * Forwarding Paths:
 * =================
 *                                  +-------------------------------------+
 *                                  |         Forwarding Unit             |
 *   From MA stage ---------------- |  ALU result / Cache hit / AMO data  | --> rs1/rs2
 *   (1 cycle ahead)                |                                     |
 *                                  |  Priority: MA > WB > Regfile        |
 *   From WB stage ---------------- |  Final writeback data               | --> rs1/rs2
 *   (2 cycles ahead)               |                                     |
 *                                  |  Check: dest_reg matches src_reg    |
 *   From Regfile (via ID->EX) ---- |  Normal register read               | --> rs1/rs2
 *   (no hazard)                    +-------------------------------------+
 *
 * Forwarding Selection Logic:
 * ===========================
 *   1. MA stage forward (highest priority):
 *      - Instruction in EX stage writes to rd
 *      - rd matches rs1 or rs2 of instruction in ID
 *      - Forward: ALU result, cache hit data, or load/AMO data
 *
 *   2. WB stage forward (medium priority):
 *      - Instruction in MA stage writes to rd
 *      - rd matches rs1 or rs2 of instruction in ID
 *      - Forward: Final writeback data
 *
 *   3. Register file (lowest priority):
 *      - No forwarding needed
 *      - Use data read in ID stage (registered at ID→EX boundary)
 *
 * Special Cases:
 * ==============
 *   - x0: Always returns 0 (hardwired zero register)
 *   - Cache hit: Forward from cache instead of waiting for memory
 *   - Load-use: After 1-cycle stall, forward load data
 *   - AMO: Forward old memory value during AMO_READ phase
 *
 * Timing Optimization:
 * ====================
 *   - Forward control signals are registered (computed in previous cycle)
 *   - Uses early source registers from PD stage (bypasses instruction mux)
 *   - Regfile read moved to ID stage (not EX stage critical path)
 *
 * Related Modules:
 *   - hazard_resolution_unit.sv: Detects when stall is needed (load-use)
 *   - ex_stage.sv: Receives forwarded operand values
 *   - regfile.sv: Provides base register values
 *   - l0_cache.sv: Provides cache hit data for 0-cycle forwarding
 */
module forwarding_unit #(
    parameter int unsigned XLEN = 32,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000,
    parameter int unsigned MMIO_SIZE_BYTES = 32'h28
) (
    input logic i_clk,
    // control inputs
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    // Data inputs for forwarding decisions
    input riscv_pkg::from_pd_to_id_t i_from_pd_to_id,
    input riscv_pkg::from_id_to_ex_t i_from_id_to_ex,
    input riscv_pkg::from_ex_comb_t i_from_ex_comb,
    input riscv_pkg::from_ex_to_ma_t i_from_ex_to_ma,
    input riscv_pkg::from_ma_comb_t i_from_ma_comb,
    input riscv_pkg::from_ma_to_wb_t i_from_ma_to_wb,
    input riscv_pkg::from_cache_t i_from_cache,
    // A extension: AMO result for forwarding
    input logic i_amo_write_enable,
    input logic [XLEN-1:0] i_amo_result,
    input logic i_amo_read_phase,  // True during READ phase - memory data is available
    // Forwarded register values output to Execute stage
    output riscv_pkg::fwd_to_ex_t o_fwd_to_ex
);

  logic [XLEN-1:0] source_reg_1_raw_value;  // rs1 from register file (registered in ID stage)
  logic [XLEN-1:0] source_reg_2_raw_value;  // rs2 from register file (registered in ID stage)

  // x0 is hardwired to zero, so return 0 if rs1/rs2 is register 0
  // Regfile data is now registered at ID→EX boundary (read in ID stage, not EX stage)
  // TIMING OPTIMIZATION: Use pre-computed x0 flags from ID stage instead of computing
  // ~|source_reg here. This removes the NOR gate from the critical path.
  assign source_reg_1_raw_value = i_from_id_to_ex.source_reg_1_is_x0 ? '0 :
                                    i_from_id_to_ex.source_reg_1_data;
  assign source_reg_2_raw_value = i_from_id_to_ex.source_reg_2_is_x0 ? '0 :
                                    i_from_id_to_ex.source_reg_2_data;

  // Forwarding control signals - indicate when to forward from each stage
  logic forward_source_reg_1_from_ma;
  logic forward_source_reg_2_from_ma;
  logic forward_source_reg_1_from_wb;
  logic forward_source_reg_2_from_wb;

  // Data to forward from Memory Access stage (registered).
  logic [XLEN-1:0] register_write_data_ma;

  // MMIO load detection (used to refresh forward data during MMIO stalls).
  logic mmio_load_in_ma;
  assign mmio_load_in_ma =
      (i_from_ex_to_ma.is_load_instruction | i_from_ex_to_ma.is_lr) &&
      (i_from_ex_to_ma.data_memory_address >= MMIO_ADDR) &&
      (i_from_ex_to_ma.data_memory_address < (MMIO_ADDR + MMIO_SIZE_BYTES));

  // Detect when forwarding is needed (RAW hazard detection)
  // TIMING OPTIMIZATION: Use early source registers from PD stage for better timing.
  // These are extracted in parallel with decompression and bypass the full instruction mux path.
  // Treat FP-to-int ops (FMV.X.W, FCVT.W.S, compares) as integer register writers
  // so back-to-back consumers get forwarded data.
  logic ex_writes_int_reg;
  assign ex_writes_int_reg =
      i_from_ex_comb.regfile_write_enable |
      i_from_id_to_ex.is_load_instruction |
      i_from_id_to_ex.is_amo_instruction |
      i_from_id_to_ex.is_fp_to_int;

  // Int -> FP capture bypass: when a load-use hazard is detected and the
  // current EX instruction is int->fp, feed MA load data directly so the
  // FPU captures the correct operand at the stall edge.
  logic int_capture_bypass_valid;
  logic [XLEN-1:0] int_capture_bypass_data;
  assign int_capture_bypass_valid =
      i_pipeline_ctrl.load_use_hazard_detected &&
      i_from_ex_to_ma.is_load_instruction &&
      i_from_id_to_ex.is_int_to_fp &&
      (i_from_ex_to_ma.instruction.dest_reg != 0) &&
      (i_from_ex_to_ma.instruction.dest_reg ==
       i_from_id_to_ex.instruction.source_reg_1);

  assign int_capture_bypass_data = i_from_ma_comb.data_loaded_from_memory;

  always_ff @(posedge i_clk) begin
    if (~i_pipeline_ctrl.stall) begin
      // Forward from MA stage if instruction in EX writes to register needed in ID
      // Note: AMO instructions also write to rd (the old memory value), so include them
      forward_source_reg_1_from_ma <=
          ex_writes_int_reg &&
          i_from_id_to_ex.instruction.dest_reg != 0 &&
          i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.source_reg_1_early;

      forward_source_reg_2_from_ma <=
          ex_writes_int_reg &&
          i_from_id_to_ex.instruction.dest_reg != 0 &&
          i_from_id_to_ex.instruction.dest_reg == i_from_pd_to_id.source_reg_2_early;

      // Forward from WB stage if instruction in MA writes to register needed in ID
      forward_source_reg_1_from_wb <=
          i_from_ex_to_ma.regfile_write_enable      &&
          i_from_ex_to_ma.instruction.dest_reg != 0 &&
          i_from_ex_to_ma.instruction.dest_reg == i_from_pd_to_id.source_reg_1_early;

      forward_source_reg_2_from_wb <=
          i_from_ex_to_ma.regfile_write_enable      &&
          i_from_ex_to_ma.instruction.dest_reg != 0 &&
          i_from_ex_to_ma.instruction.dest_reg == i_from_pd_to_id.source_reg_2_early;
    end
    if (i_pipeline_ctrl.reset) begin
      forward_source_reg_1_from_ma <= 1'b0;
      forward_source_reg_2_from_ma <= 1'b0;
      forward_source_reg_1_from_wb <= 1'b0;
      forward_source_reg_2_from_wb <= 1'b0;
    end
  end

  // Select data to forward from MA stage
  // Special handling for load-use hazards and AMO-use hazards.
  // Keep an explicit next-value mux and always assign the register to discourage
  // CE inference on this flop (the CE control path was timing-critical).
  logic [XLEN-1:0] register_write_data_ma_next;

  always_comb begin
    register_write_data_ma_next = register_write_data_ma;

    if (i_pipeline_ctrl.stall_for_load_use_hazard ||
        (i_pipeline_ctrl.stall && mmio_load_in_ma)) begin
      // Load-use hazard or MMIO-load stall: use memory data
      // (refresh during MMIO stall so forwarding sees the updated read data).
      if (i_amo_read_phase) register_write_data_ma_next = i_from_ma_comb.data_memory_read_data;
      else register_write_data_ma_next = i_from_ma_comb.data_loaded_from_memory;
    end else if (~i_pipeline_ctrl.stall) begin
      // Normal case: use result from EX stage (cache-hit forwarding uses registered path below)
      // SC.W: the success/fail result (0=success, 1=fail per RISC-V spec) is computed
      // in the store_unit, NOT the ALU. Forward the inverted sc_success flag directly.
      if (i_from_id_to_ex.is_sc)
        register_write_data_ma_next = {{(XLEN - 1) {1'b0}}, ~i_from_ex_comb.sc_success};
      else if (i_from_id_to_ex.is_fp_to_int)
        register_write_data_ma_next = i_from_ex_comb.fp_result[XLEN-1:0];
      else register_write_data_ma_next = i_from_ex_comb.alu_result;
    end
  end

`ifdef FROST_XILINX_PRIMS
  // Xilinx-specific timing steering:
  // Instantiate explicit flops with CE tied high so this register cannot map to a
  // variable CE cone on critical paths.
  for (genvar idx = 0; idx < XLEN; idx++) begin : gen_register_write_data_ma_reg
    FDRE #(
        .INIT(1'b0)
    ) register_write_data_ma_ff (
        .C (i_clk),
        .CE(1'b1),
        .D (register_write_data_ma_next[idx]),
        .Q (register_write_data_ma[idx]),
        .R (1'b0)
    );
  end
`else
  // Generic technology-agnostic flop modeling.
  always_ff @(posedge i_clk) begin
    register_write_data_ma <= register_write_data_ma_next;
  end
`endif

  // Final multiplexing: select forwarded value or register file value
  // Priority order: MA stage forward > WB stage forward > Register file
  logic use_cache_hit_forward;
  logic [XLEN-1:0] forward_data_ma;

  // Only use cache-hit forwarding when the MA stage instruction is a load/LR.
  // Otherwise a cache hit for an unrelated load in EX would incorrectly override
  // MA forwarding data (e.g., AMO result), corrupting source operands.
  assign use_cache_hit_forward =
      i_from_cache.cache_hit_on_load_reg &&
      (i_from_ex_to_ma.is_load_instruction || i_from_ex_to_ma.is_lr);
  assign forward_data_ma = use_cache_hit_forward ?
                            i_from_cache.data_loaded_from_cache_reg :
                            register_write_data_ma;

  // Forwarding priority (highest to lowest):
  //   1. MA stage forward (registered): ALU result or cached data
  //   2. WB stage forward (registered): writeback data
  //   3. Register file raw value: data read in ID stage
  assign o_fwd_to_ex.source_reg_1_value =
      forward_source_reg_1_from_ma ? forward_data_ma :
      forward_source_reg_1_from_wb ? i_from_ma_to_wb.regfile_write_data :
      source_reg_1_raw_value;

  assign o_fwd_to_ex.source_reg_2_value =
      forward_source_reg_2_from_ma ? forward_data_ma :
      forward_source_reg_2_from_wb ? i_from_ma_to_wb.regfile_write_data :
      source_reg_2_raw_value;

  assign o_fwd_to_ex.capture_bypass_int_valid = int_capture_bypass_valid;
  assign o_fwd_to_ex.capture_bypass_int_data = int_capture_bypass_data;

  // ===========================================================================
  // Formal Verification Properties
  // ===========================================================================
`ifdef FORMAL

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    // MA priority over WB: when forwarding from MA, output uses forward_data_ma.
    p_ma_priority_rs1 :
    assert (!forward_source_reg_1_from_ma || (o_fwd_to_ex.source_reg_1_value == forward_data_ma));

    p_ma_priority_rs2 :
    assert (!forward_source_reg_2_from_ma || (o_fwd_to_ex.source_reg_2_value == forward_data_ma));

    // x0 always zero: if source_reg_1 is x0, raw value must be 0.
    p_x0_rs1_zero : assert (!i_from_id_to_ex.source_reg_1_is_x0 || (source_reg_1_raw_value == '0));

    p_x0_rs2_zero : assert (!i_from_id_to_ex.source_reg_2_is_x0 || (source_reg_2_raw_value == '0));

    // No forwarding -> raw value: when no forward active, output is raw value.
    p_no_fwd_rs1 :
    assert (forward_source_reg_1_from_ma ||
        forward_source_reg_1_from_wb ||
        (o_fwd_to_ex.source_reg_1_value == source_reg_1_raw_value));

    p_no_fwd_rs2 :
    assert (forward_source_reg_2_from_ma ||
        forward_source_reg_2_from_wb ||
        (o_fwd_to_ex.source_reg_2_value == source_reg_2_raw_value));

    if (f_past_valid) begin
      // Reset clears forward enables.
      if ($past(i_pipeline_ctrl.reset)) begin
        p_reset_fwd_rs1_ma : assert (!forward_source_reg_1_from_ma);
        p_reset_fwd_rs2_ma : assert (!forward_source_reg_2_from_ma);
        p_reset_fwd_rs1_wb : assert (!forward_source_reg_1_from_wb);
        p_reset_fwd_rs2_wb : assert (!forward_source_reg_2_from_wb);
      end

      // Forward from MA requires write enable and dest != 0.
      // After an unstalled cycle, if MA forward is set, the previous cycle
      // must have had a writing instruction with dest_reg != 0.
      if (!$past(i_pipeline_ctrl.stall) && !$past(i_pipeline_ctrl.reset)) begin
        p_fwd_ma_rs1_needs_write :
        assert (!forward_source_reg_1_from_ma || $past(
            ex_writes_int_reg && i_from_id_to_ex.instruction.dest_reg != 0
        ));

        p_fwd_ma_rs2_needs_write :
        assert (!forward_source_reg_2_from_ma || $past(
            ex_writes_int_reg && i_from_id_to_ex.instruction.dest_reg != 0
        ));
      end
    end
  end

  // Cover properties
  always @(posedge i_clk) begin
    cover_ma_forward : cover (forward_source_reg_1_from_ma);
    cover_wb_forward : cover (forward_source_reg_1_from_wb);
    cover_both_ma_wins : cover (forward_source_reg_1_from_ma && forward_source_reg_1_from_wb);
    cover_cache_hit_fwd : cover (use_cache_hit_forward && forward_source_reg_1_from_ma);
    cover_no_forwarding : cover (!forward_source_reg_1_from_ma && !forward_source_reg_1_from_wb);
  end

`endif  // FORMAL

endmodule : forwarding_unit
