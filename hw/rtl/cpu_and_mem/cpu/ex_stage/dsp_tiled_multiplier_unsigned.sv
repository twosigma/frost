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
 * DSP-tiled unsigned multiplier.
 *
 * Decomposes a wide unsigned multiply into {27x35} tile multiplies so synthesis can
 * infer DSP48E2-friendly cascaded implementations (27x(18+17) decomposition).
 *
 * Partial products are reduced with 32-bit chunked pairwise additions:
 *   - Each adder operation is exactly 32-bit (plus carry-in)
 *   - Carry is registered between chunks
 *   - Reduction depth scales with term count: ceil(log2(num_terms))
 *
 * This bounds per-cycle carry-propagation depth while preserving exact arithmetic.
 *
 * Interface contract:
 *   - o_valid_output pulses when product is ready
 *   - o_completing_next_cycle pulses one cycle before o_valid_output when possible
 */
module dsp_tiled_multiplier_unsigned #(
    parameter int unsigned A_WIDTH = 33,
    parameter int unsigned B_WIDTH = 33,
    parameter int unsigned A_TILE_WIDTH = 27,
    parameter int unsigned B_TILE_WIDTH = 35,
    parameter int unsigned ADD_CHUNK_WIDTH = 32
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

  localparam int unsigned ProductWidth = A_WIDTH + B_WIDTH;
  localparam int unsigned NumATiles = (A_WIDTH + A_TILE_WIDTH - 1) / A_TILE_WIDTH;
  localparam int unsigned NumBTiles = (B_WIDTH + B_TILE_WIDTH - 1) / B_TILE_WIDTH;
  localparam int unsigned NumTerms = NumATiles * NumBTiles;
  localparam int unsigned NumReduceStages = (NumTerms <= 1) ? 0 : $clog2(NumTerms);
  localparam int unsigned NumChunks = (ProductWidth + ADD_CHUNK_WIDTH - 1) / ADD_CHUNK_WIDTH;
  localparam int unsigned PaddedWidth = NumChunks * ADD_CHUNK_WIDTH;
  localparam int unsigned PartialWidth = A_TILE_WIDTH + B_TILE_WIDTH;

  // Keep the FP S/D multiply latency matched.  SP has only one tile, but it
  // still flows through padding registers so single- and double-precision
  // results retire in issue order when a wrapper alternates between them.
  localparam int unsigned MinPipelineStages = 3;
  localparam int unsigned ReducePipelineStages = NumReduceStages + 1;
  localparam int unsigned PipelineStages =
      (ReducePipelineStages < MinPipelineStages) ? MinPipelineStages : ReducePipelineStages;

  logic [PaddedWidth-1:0] aligned_term_comb[NumTerms];
  logic [PaddedWidth-1:0] pipe_terms[PipelineStages][NumTerms];
  logic [PipelineStages-1:0] valid_pipe;

  function automatic int unsigned terms_at_stage(input int unsigned stage);
    terms_at_stage = (NumTerms + (1 << stage) - 1) >> stage;
  endfunction

  // ---------------------------------------------------------------------------
  // Combinational: slice wide operands into {27,35}-bit tiles and align terms.
  // ---------------------------------------------------------------------------
  generate
    for (genvar a = 0; a < NumATiles; a++) begin : gen_a_tiles
      localparam int unsigned AOffset = a * A_TILE_WIDTH;
      localparam int unsigned AWidthThis =
          ((AOffset + A_TILE_WIDTH) <= A_WIDTH) ? A_TILE_WIDTH : (A_WIDTH - AOffset);
      logic [A_TILE_WIDTH-1:0] a_tile;
      assign a_tile = {{(A_TILE_WIDTH - AWidthThis) {1'b0}}, i_operand_a[AOffset+:AWidthThis]};

      for (genvar b = 0; b < NumBTiles; b++) begin : gen_b_tiles
        localparam int unsigned BOffset = b * B_TILE_WIDTH;
        localparam int unsigned BWidthThis =
            ((BOffset + B_TILE_WIDTH) <= B_WIDTH) ? B_TILE_WIDTH : (B_WIDTH - BOffset);
        localparam int unsigned TermIndex = (a * NumBTiles) + b;
        logic [B_TILE_WIDTH-1:0] b_tile;
        (* use_dsp = "yes" *)logic [PartialWidth-1:0] tiled_partial_product;
        logic [ PaddedWidth-1:0] aligned_term;

        assign b_tile = {{(B_TILE_WIDTH - BWidthThis) {1'b0}}, i_operand_b[BOffset+:BWidthThis]};
        assign tiled_partial_product = PartialWidth'(a_tile * b_tile);
        assign aligned_term = PaddedWidth'(tiled_partial_product) << (AOffset + BOffset);
        assign aligned_term_comb[TermIndex] = aligned_term;
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Pipelined pairwise reduction tree.
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      valid_pipe <= '0;
    end else begin
      valid_pipe[0] <= i_valid_input;
      for (int s = 1; s < PipelineStages; s++) begin
        valid_pipe[s] <= valid_pipe[s-1];
      end
    end
  end

  always_ff @(posedge i_clk) begin
    for (int t = 0; t < NumTerms; t++) begin
      pipe_terms[0][t] <= aligned_term_comb[t];
    end

    for (int s = 1; s < PipelineStages; s++) begin
      for (int t = 0; t < NumTerms; t++) begin
        if (t < terms_at_stage(s)) begin
          if (((2 * t) + 1) < terms_at_stage(s - 1)) begin
            pipe_terms[s][t] <= pipe_terms[s-1][2*t] + pipe_terms[s-1][(2*t)+1];
          end else begin
            pipe_terms[s][t] <= pipe_terms[s-1][2*t];
          end
        end else begin
          pipe_terms[s][t] <= '0;
        end
      end
    end
  end

  generate
    if (PipelineStages > 1) begin : gen_completing_next
      assign o_completing_next_cycle = valid_pipe[PipelineStages-2];
    end else begin : gen_completing_next_single_chunk
      assign o_completing_next_cycle = i_valid_input;
    end
  endgenerate

  assign o_product_result = pipe_terms[PipelineStages-1][0][ProductWidth-1:0];
  assign o_valid_output   = valid_pipe[PipelineStages-1];

endmodule : dsp_tiled_multiplier_unsigned
