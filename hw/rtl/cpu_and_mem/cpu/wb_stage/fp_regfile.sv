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

  // Three RAM instances sharing the same write port, with independent read ports for fs1, fs2, fs3.
  // fs3 is needed for FMA instructions (R4-type format, encoded in funct7[6:2]).
  // Note: Write address uses tracked fp_dest_reg from FPU pipeline, not instruction.dest_reg.
  // This is necessary because pipelined FPU operations complete cycles after the instruction
  // has moved through the pipeline, so the tracked dest_reg ensures we write to the correct register.
  logic [4:0] read_addresses[3];
  assign read_addresses[0] = i_from_pd_to_id.source_reg_1_early;
  assign read_addresses[1] = i_from_pd_to_id.source_reg_2_early;
  assign read_addresses[2] = i_from_pd_to_id.fp_source_reg_3_early;

  logic [DATA_WIDTH-1:0] read_data[3];

  for (genvar i = 0; i < 3; i++) begin : gen_fp_source_ram
    sdp_dist_ram #(
        .ADDR_WIDTH($clog2(DEPTH)),
        .DATA_WIDTH(DATA_WIDTH)
    ) fp_source_reg_ram (
        .i_clk,
        .i_write_enable(write_enable),
        .i_write_address(i_from_ma_to_wb.fp_dest_reg),
        .i_write_data(i_from_ma_to_wb.fp_regfile_write_data),
        .i_read_address(read_addresses[i]),
        .o_read_data(read_data[i])
    );
  end

  assign o_fp_rf_to_fwd.fp_source_reg_1_data = read_data[0];
  assign o_fp_rf_to_fwd.fp_source_reg_2_data = read_data[1];
  assign o_fp_rf_to_fwd.fp_source_reg_3_data = read_data[2];

endmodule : fp_regfile
