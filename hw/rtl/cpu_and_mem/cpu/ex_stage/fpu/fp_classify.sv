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
  Floating-point classify operation (FCLASS.{S,D}).
  Returns a 10-bit mask indicating the class of the input value.
  Result is written to an integer register (rd), not an FP register.

  Output bit encoding (exactly one bit is set):
    bit 0: rs1 is -infinity
    bit 1: rs1 is a negative normal number
    bit 2: rs1 is a negative subnormal number
    bit 3: rs1 is -0
    bit 4: rs1 is +0
    bit 5: rs1 is a positive subnormal number
    bit 6: rs1 is a positive normal number
    bit 7: rs1 is +infinity
    bit 8: rs1 is a signaling NaN
    bit 9: rs1 is a quiet NaN

  Latency: 2 cycles (registered output to break timing path through FP forwarding)
*/
module fp_classify #(
    parameter int unsigned FP_WIDTH = 32
) (
    input  logic                i_clk,
    input  logic                i_rst,
    input  logic                i_valid,    // Start operation
    input  logic [FP_WIDTH-1:0] i_operand,
    output logic [        31:0] o_result,
    output logic                o_valid,    // Result ready
    output logic                o_busy      // Operation in progress
);

  // Extract fields
  localparam int unsigned ExpBits = (FP_WIDTH == 32) ? 8 : 11;
  localparam int unsigned FracBits = (FP_WIDTH == 32) ? 23 : 52;
  localparam logic [ExpBits-1:0] ExpMax = {ExpBits{1'b1}};

  logic                sign;
  logic [ ExpBits-1:0] exponent;
  logic [FracBits-1:0] mantissa;

  assign sign = i_operand[FP_WIDTH-1];
  assign exponent = i_operand[FP_WIDTH-2-:ExpBits];
  assign mantissa = i_operand[FracBits-1:0];

  // Classify conditions
  logic is_zero;
  logic is_subnormal;
  logic is_normal;
  logic is_infinity;
  logic is_nan;
  logic is_signaling_nan;
  logic is_quiet_nan;

  assign is_zero          = (exponent == '0) && (mantissa == '0);
  assign is_subnormal     = (exponent == '0) && (mantissa != '0);
  assign is_infinity      = (exponent == ExpMax) && (mantissa == '0);
  assign is_nan           = (exponent == ExpMax) && (mantissa != '0);
  assign is_normal        = (exponent != '0) && (exponent != ExpMax);

  // For NaNs: bit 22 of mantissa distinguishes quiet (1) from signaling (0)
  assign is_quiet_nan     = is_nan && mantissa[FracBits-1];
  assign is_signaling_nan = is_nan && ~mantissa[FracBits-1];

  // Generate output mask (combinational)
  logic [9:0] class_mask;

  always_comb begin
    class_mask = 10'b0;

    if (is_quiet_nan) class_mask[9] = 1'b1;  // Quiet NaN
    else if (is_signaling_nan) class_mask[8] = 1'b1;  // Signaling NaN
    else if (is_infinity) begin
      if (sign) class_mask[0] = 1'b1;  // -infinity
      else class_mask[7] = 1'b1;  // +infinity
    end else if (is_zero) begin
      if (sign) class_mask[3] = 1'b1;  // -0
      else class_mask[4] = 1'b1;  // +0
    end else if (is_subnormal) begin
      if (sign) class_mask[2] = 1'b1;  // Negative subnormal
      else class_mask[5] = 1'b1;  // Positive subnormal
    end else begin  // Normal
      if (sign) class_mask[1] = 1'b1;  // Negative normal
      else class_mask[6] = 1'b1;  // Positive normal
    end
  end

  // Pipeline register - adds 1 cycle latency
  logic started;
  logic [31:0] result_reg;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      started <= 1'b0;
      result_reg <= 32'b0;
    end else if (i_valid && !started) begin
      // Capture result on start
      started <= 1'b1;
      result_reg <= {22'b0, class_mask};
    end else if (started) begin
      // Output cycle - clear started
      started <= 1'b0;
    end
  end

  // Output valid one cycle after start
  // Busy only on the starting cycle (i_valid=1), not on output cycle (started=1)
  assign o_valid  = started;
  assign o_result = result_reg;
  assign o_busy   = i_valid;

endmodule : fp_classify
