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

// verilog_lint: waive-start module-filename
// Typed interfaces for the primitives used by the checked views.
// These declarations check ports and parameters; they do not model the cells.
(* blackbox *)
module LUT1 #(
    parameter logic [1:0] INIT = 0
) (
    output wire O,
    input  wire I0
);
endmodule
(* blackbox *) module LUT2 #(
    parameter logic [3:0] INIT = 0
) (
    output wire O,
    input  wire I0,
    input  wire I1
);
endmodule
(* blackbox *) module LUT3 #(
    parameter logic [7:0] INIT = 0
) (
    output wire O,
    input  wire I0,
    input  wire I1,
    input  wire I2
);
endmodule
(* blackbox *) module LUT4 #(
    parameter logic [15:0] INIT = 0
) (
    output wire O,
    input  wire I0,
    input  wire I1,
    input  wire I2,
    input  wire I3
);
endmodule
(* blackbox *) module LUT5 #(
    parameter logic [31:0] INIT = 0
) (
    output wire O,
    input  wire I0,
    input  wire I1,
    input  wire I2,
    input  wire I3,
    input  wire I4
);
endmodule
(* blackbox *) module LUT6 #(
    parameter logic [63:0] INIT = 0
) (
    output wire O,
    input  wire I0,
    input  wire I1,
    input  wire I2,
    input  wire I3,
    input  wire I4,
    input  wire I5
);
endmodule
(* blackbox *) module LUT6_2 #(
    parameter logic [63:0] INIT = 0
) (
    output wire O5,
    O6,
    input  wire I0,
    I1,
    I2,
    I3,
    I4,
    I5
);
endmodule
(* blackbox *) module FDRE #(
    parameter bit INIT = 0,
    parameter bit IS_C_INVERTED = 0,
    parameter bit IS_D_INVERTED = 0,
    parameter bit IS_R_INVERTED = 0
) (
    output wire Q,
    input  wire C,
    CE,
    D,
    R
);
endmodule
(* blackbox *) module MUXF7 (
    output wire O,
    input  wire I0,
    I1,
    S
);
endmodule
(* blackbox *) module MUXF8 (
    output wire O,
    input  wire I0,
    I1,
    S
);
endmodule
(* blackbox *) module MUXF9 (
    output wire O,
    input  wire I0,
    I1,
    S
);
endmodule
(* blackbox *) module CARRY8 #(
    parameter string CARRY_TYPE = "SINGLE_CY8"
) (
    output wire [7:0] CO,
    O,
    input wire CI,
    CI_TOP,
    input wire [7:0] DI,
    S
);
endmodule
// verilog_lint: waive-stop module-filename
