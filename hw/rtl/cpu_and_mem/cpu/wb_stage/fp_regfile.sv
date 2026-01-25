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
  RISC-V F extension floating-point register file with 32 registers (f0-f31).
  Implements a quad-ported register file with three simultaneous read ports
  and one write port. Three read ports are needed for FMA instructions which
  use fs1, fs2, and fs3 as source operands.

  Unlike the integer register file, there is no hardwired zero register -
  all 32 FP registers are read/write. NaN-boxing is not implemented here;
  F and D instructions operate directly on the stored bit patterns.

  Read addresses come from PD stage (early source registers) so the regfile
  read happens in ID stage. The read data is then registered at the ID->EX
  boundary, moving the RAM read out of the EX stage critical path.
*/
module fp_regfile #(
    parameter int unsigned DEPTH = 32,  // Number of registers (32 for RV32F/RV32D)
    parameter int unsigned DATA_WIDTH = riscv_pkg::FpWidth  // Register width in bits
) (
    input logic i_clk,
    input riscv_pkg::pipeline_ctrl_t i_pipeline_ctrl,
    input riscv_pkg::from_pd_to_id_t i_from_pd_to_id,  // Read addresses from PD stage
    input riscv_pkg::from_ma_to_wb_t i_from_ma_to_wb,  // Write data from WB stage
    output riscv_pkg::fp_rf_to_fwd_t o_fp_rf_to_fwd
);

  // Write enable logic - FP regfile writes when fp_regfile_write_enable is set
  // No x0 check needed since all FP registers are writable
  logic write_enable;
  assign write_enable = i_from_ma_to_wb.fp_regfile_write_enable & ~i_pipeline_ctrl.stall;

  // First RAM instance: provides fs1 read port
  // Note: Write address uses tracked fp_dest_reg from FPU pipeline, not instruction.dest_reg
  // This is necessary because pipelined FPU operations complete cycles after the instruction
  // has moved through the pipeline, so the tracked dest_reg ensures we write to the correct register.
  sdp_dist_ram #(
      .ADDR_WIDTH($clog2(DEPTH)),
      .DATA_WIDTH(DATA_WIDTH)
  ) fp_source_reg_1_ram (
      .i_clk,
      .i_write_enable(write_enable),
      .i_write_address(i_from_ma_to_wb.fp_dest_reg),
      .i_write_data(i_from_ma_to_wb.fp_regfile_write_data),
      .i_read_address(i_from_pd_to_id.source_reg_1_early),
      .o_read_data(o_fp_rf_to_fwd.fp_source_reg_1_data)
  );

  // Second RAM instance: provides fs2 read port
  sdp_dist_ram #(
      .ADDR_WIDTH($clog2(DEPTH)),
      .DATA_WIDTH(DATA_WIDTH)
  ) fp_source_reg_2_ram (
      .i_clk,
      .i_write_enable(write_enable),
      .i_write_address(i_from_ma_to_wb.fp_dest_reg),
      .i_write_data(i_from_ma_to_wb.fp_regfile_write_data),
      .i_read_address(i_from_pd_to_id.source_reg_2_early),
      .o_read_data(o_fp_rf_to_fwd.fp_source_reg_2_data)
  );

  // Third RAM instance: provides fs3 read port (for FMA instructions)
  // fs3 is encoded in funct7[6:2] of the R4-type instruction format
  sdp_dist_ram #(
      .ADDR_WIDTH($clog2(DEPTH)),
      .DATA_WIDTH(DATA_WIDTH)
  ) fp_source_reg_3_ram (
      .i_clk,
      .i_write_enable(write_enable),
      .i_write_address(i_from_ma_to_wb.fp_dest_reg),
      .i_write_data(i_from_ma_to_wb.fp_regfile_write_data),
      .i_read_address(i_from_pd_to_id.fp_source_reg_3_early),
      .o_read_data(o_fp_rf_to_fwd.fp_source_reg_3_data)
  );

endmodule : fp_regfile
