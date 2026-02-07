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
 * Stall Capture Register
 *
 * Captures a data value on the rising edge of a stall (stall asserted while
 * stall_registered is low) and holds it for the duration of the stall.
 * The output selects the saved value when stall_registered is high,
 * otherwise passes through the live input data.
 *
 * This pattern recurs throughout the pipeline wherever BRAM outputs or
 * combinational results must be preserved across stall cycles.
 */
module stall_capture_reg #(
    parameter int unsigned WIDTH = 1
) (
    input  logic             i_clk,
    input  logic             i_reset,
    input  logic             i_flush,
    input  logic             i_stall,
    input  logic             i_stall_registered,
    input  logic [WIDTH-1:0] i_data,
    output logic [WIDTH-1:0] o_data
);
  logic [WIDTH-1:0] saved;

  always_ff @(posedge i_clk) begin
    if (i_reset || i_flush) saved <= '0;
    else if (i_stall & ~i_stall_registered) saved <= i_data;
  end

  assign o_data = i_stall_registered ? saved : i_data;
endmodule
