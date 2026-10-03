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

// Test-only truth-table models of the Xilinx LUT primitives, so the
// FROST_XILINX_PRIMS build of the data_mem_response_mux cocotb test needs no
// vendor library. The data_mem_response_mux formal target uses Yosys's Xilinx
// cell models instead. The module names must match the primitives the RTL
// instantiates.
// verilog_lint: waive-start module-filename
`ifdef FROST_XILINX_PRIMS
module LUT5 #(
    parameter logic [31:0] INIT = '0
) (
    input  logic I0,
    input  logic I1,
    input  logic I2,
    input  logic I3,
    input  logic I4,
    output logic O
);
  assign O = INIT[{I4, I3, I2, I1, I0}];
endmodule : LUT5

// data_mem_request_router also instantiates a LUT4 (its MMIO drain-accept gate).
module LUT4 #(
    parameter logic [15:0] INIT = '0
) (
    input  logic I0,
    input  logic I1,
    input  logic I2,
    input  logic I3,
    output logic O
);
  assign O = INIT[{I3, I2, I1, I0}];
endmodule : LUT4
`endif
// verilog_lint: waive-stop module-filename
