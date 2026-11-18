/*
 * Copyright (c) 2026 John Goodacre.
 */

// Formal stand-in for dsp_tiled_multiplier_unsigned in the fp_launch_squash
// miter. fp_engine registers the multiplier operands in ST_DEC1, holds them
// until the next operation's ST_DEC1, and reads the product only in ST_MUL,
// MulStages cycles after the multiply starts, when the real multiplier's
// output is a function of those held operands alone. Any function of the
// current operands therefore gives both engine copies the same control
// behaviour; the concatenation keeps the miter free of a 53 x 53 multiply.
// fp_engine_equiv checks the real product against SoftFloat.
// verilog_lint: waive module-filename
module dsp_tiled_multiplier_unsigned #(
    parameter int unsigned A_WIDTH = 33,
    parameter int unsigned B_WIDTH = 33,
    parameter int unsigned A_TILE_WIDTH = 27,
    parameter int unsigned B_TILE_WIDTH = 35,
    parameter int unsigned ADD_CHUNK_WIDTH = 32,
    parameter bit INPUT_REGISTER = 1'b0
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid_input,
    input logic [A_WIDTH-1:0] i_operand_a,
    input logic [B_WIDTH-1:0] i_operand_b,
    output logic [A_WIDTH+B_WIDTH-1:0] o_product_result,
    output logic o_valid_output,
    output logic o_completing_next_cycle
);
  assign o_product_result = {i_operand_a, i_operand_b};
  assign o_valid_output = i_valid_input;
  assign o_completing_next_cycle = i_valid_input;
endmodule : dsp_tiled_multiplier_unsigned
