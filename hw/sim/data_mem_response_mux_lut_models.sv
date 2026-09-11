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

// Test-only primitive truth tables. The separate formal proof uses the pinned
// toolchain's installed Xilinx model; these models make the cocotb seam portable.
// Primitive module names are fixed by the production instantiations.
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

// The actual request router also uses an existing terminal MMIO-accept LUT4.
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
