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
 * CDB Arbiter Testbench Wrapper -- Flattened Ports for Icarus VPI
 *
 * Icarus Verilog does not support unpacked arrays of packed structs. This
 * wrapper exposes the i_fu_complete[7] as 7 individual packed struct ports
 * (each 81 bits, within the safe VPI range) and connects them directly to the
 * cdb_arbiter's flattened individual ports (the non-VERILATOR default path).
 *
 * Used automatically when SIM=icarus via Makefile TOPLEVEL override.
 */

module cdb_arbiter_tb (
    input logic i_clk,
    input logic i_rst_n,

    // FU completion requests -- flattened from i_fu_complete[7]
    input riscv_pkg::fu_complete_t i_fu_complete_0,
    input riscv_pkg::fu_complete_t i_fu_complete_1,
    input riscv_pkg::fu_complete_t i_fu_complete_2,
    input riscv_pkg::fu_complete_t i_fu_complete_3,
    input riscv_pkg::fu_complete_t i_fu_complete_4,
    input riscv_pkg::fu_complete_t i_fu_complete_5,
    input riscv_pkg::fu_complete_t i_fu_complete_6,

    // CDB broadcast output -- pass through (84 bits)
    output riscv_pkg::cdb_broadcast_t o_cdb,

    // Per-FU grant signals -- pass through (7 bits)
    output logic [riscv_pkg::NumFus-1:0] o_grant
);

  // Connect individual ports directly (no unpacked arrays — Icarus can't handle them)
  cdb_arbiter u_dut (
      .i_clk          (i_clk),
      .i_rst_n        (i_rst_n),
      .i_fu_complete_0(i_fu_complete_0),
      .i_fu_complete_1(i_fu_complete_1),
      .i_fu_complete_2(i_fu_complete_2),
      .i_fu_complete_3(i_fu_complete_3),
      .i_fu_complete_4(i_fu_complete_4),
      .i_fu_complete_5(i_fu_complete_5),
      .i_fu_complete_6(i_fu_complete_6),
      .o_cdb          (o_cdb),
      .o_grant        (o_grant)
  );

endmodule
