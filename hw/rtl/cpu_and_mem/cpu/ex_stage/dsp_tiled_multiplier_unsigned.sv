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
  localparam int unsigned NumReduceStages = (NumTerms <= 1) ? 1 : $clog2(NumTerms);
  localparam int unsigned NumChunks = (ProductWidth + ADD_CHUNK_WIDTH - 1) / ADD_CHUNK_WIDTH;
  localparam int unsigned PaddedWidth = NumChunks * ADD_CHUNK_WIDTH;
  localparam int unsigned PartialWidth = A_TILE_WIDTH + B_TILE_WIDTH;

  localparam int unsigned LevelBits = (NumReduceStages <= 1) ? 1 : $clog2(NumReduceStages);
  localparam int unsigned ChunkBits = (NumChunks <= 1) ? 1 : $clog2(NumChunks);

  logic [PaddedWidth-1:0] aligned_term_comb[NumTerms];

  logic [NumTerms-1:0][PaddedWidth-1:0] work_terms_reg;
  logic [NumTerms-1:0][PaddedWidth-1:0] partial_terms_reg;
  logic [NumTerms-1:0][PaddedWidth-1:0] partial_terms_next;
  logic [NumTerms-1:0] carry_reg;
  logic [NumTerms-1:0] carry_next;

  logic [A_WIDTH-1:0] operand_a_reg;
  logic [B_WIDTH-1:0] operand_b_reg;

  logic busy;
  logic load_terms_pending;
  logic [LevelBits-1:0] level_reg;
  logic [ChunkBits-1:0] chunk_reg;

  localparam logic [LevelBits-1:0] LastLevel = LevelBits'(NumReduceStages - 1);
  localparam logic [ChunkBits-1:0] LastChunk = ChunkBits'(NumChunks - 1);
  localparam logic [ChunkBits-1:0] PenultimateChunk =
      (NumChunks > 1) ? ChunkBits'(NumChunks - 2) : '0;

  int unsigned prev_terms_current;
  int unsigned next_terms_current;

  function automatic int unsigned terms_at_level(input int unsigned level);
    terms_at_level = (NumTerms + (1 << level) - 1) >> level;
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
      assign a_tile = {{(A_TILE_WIDTH - AWidthThis) {1'b0}}, operand_a_reg[AOffset+:AWidthThis]};

      for (genvar b = 0; b < NumBTiles; b++) begin : gen_b_tiles
        localparam int unsigned BOffset = b * B_TILE_WIDTH;
        localparam int unsigned BWidthThis =
            ((BOffset + B_TILE_WIDTH) <= B_WIDTH) ? B_TILE_WIDTH : (B_WIDTH - BOffset);
        localparam int unsigned TermIndex = (a * NumBTiles) + b;
        logic [B_TILE_WIDTH-1:0] b_tile;
        (* use_dsp = "yes" *)logic [PartialWidth-1:0] tiled_partial_product;
        logic [ PaddedWidth-1:0] aligned_term;

        assign b_tile = {{(B_TILE_WIDTH - BWidthThis) {1'b0}}, operand_b_reg[BOffset+:BWidthThis]};
        assign tiled_partial_product = PartialWidth'(a_tile * b_tile);
        assign aligned_term = PaddedWidth'(tiled_partial_product) << (AOffset + BOffset);
        assign aligned_term_comb[TermIndex] = aligned_term;
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Combinational: current reduction bookkeeping and 32-bit chunk add step.
  // ---------------------------------------------------------------------------
  always_comb begin
    prev_terms_current = terms_at_level(int'(level_reg));
    next_terms_current = terms_at_level(int'(level_reg) + 1);

    partial_terms_next = partial_terms_reg;
    carry_next = carry_reg;

    for (int t = 0; t < NumTerms; t++) begin
      logic [ADD_CHUNK_WIDTH-1:0] chunk_a;
      logic [ADD_CHUNK_WIDTH-1:0] chunk_b;
      logic [  ADD_CHUNK_WIDTH:0] chunk_sum;

      chunk_a   = '0;
      chunk_b   = '0;
      chunk_sum = '0;

      if (t < next_terms_current) begin
        chunk_a = ((2 * t) < prev_terms_current) ?
            work_terms_reg[2 * t][int'(chunk_reg)*ADD_CHUNK_WIDTH+:ADD_CHUNK_WIDTH] : '0;
        chunk_b = (((2 * t) + 1) < prev_terms_current) ?
            work_terms_reg[(2 * t) + 1][int'(chunk_reg)*ADD_CHUNK_WIDTH+:ADD_CHUNK_WIDTH] : '0;

        chunk_sum = {1'b0, chunk_a} + {1'b0, chunk_b} + {{ADD_CHUNK_WIDTH{1'b0}}, carry_reg[t]};
        partial_terms_next[t][int'(chunk_reg)*ADD_CHUNK_WIDTH+:ADD_CHUNK_WIDTH] =
            chunk_sum[ADD_CHUNK_WIDTH-1:0];
        carry_next[t] = chunk_sum[ADD_CHUNK_WIDTH];
      end else begin
        carry_next[t] = 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Sequential control.
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_product_result <= '0;
      o_valid_output <= 1'b0;
      operand_a_reg <= '0;
      operand_b_reg <= '0;
      busy <= 1'b0;
      load_terms_pending <= 1'b0;
      level_reg <= '0;
      chunk_reg <= '0;
      work_terms_reg <= '0;
      partial_terms_reg <= '0;
      carry_reg <= '0;
    end else begin
      o_valid_output <= 1'b0;

      if (!busy) begin
        if (load_terms_pending) begin
          busy <= 1'b1;
          level_reg <= '0;
          chunk_reg <= '0;
          partial_terms_reg <= '0;
          carry_reg <= '0;
          load_terms_pending <= 1'b0;
          for (int t = 0; t < NumTerms; t++) begin
            work_terms_reg[t] <= aligned_term_comb[t];
          end
        end else if (i_valid_input) begin
          operand_a_reg <= i_operand_a;
          operand_b_reg <= i_operand_b;
          load_terms_pending <= 1'b1;
        end
      end else begin
        // Apply one 32-bit chunk add across all active term pairs.
        partial_terms_reg <= partial_terms_next;
        carry_reg <= carry_next;

        if (chunk_reg == LastChunk) begin
          // Completed all chunks for this reduction level.
          if (level_reg == LastLevel) begin
            // Final reduction complete.
            o_product_result <= partial_terms_next[0][ProductWidth-1:0];
            o_valid_output <= 1'b1;
            busy <= 1'b0;
          end else begin
            // Move reduced terms to next level and reset chunk accumulator.
            for (int t = 0; t < NumTerms; t++) begin
              if (t < next_terms_current) work_terms_reg[t] <= partial_terms_next[t];
              else work_terms_reg[t] <= '0;
            end
            partial_terms_reg <= '0;
            carry_reg <= '0;
            level_reg <= level_reg + 1'b1;
            chunk_reg <= '0;
          end
        end else begin
          // Continue current reduction level with next 32-bit chunk.
          chunk_reg <= chunk_reg + 1'b1;
        end
      end
    end
  end

  generate
    if (NumChunks > 1) begin : gen_completing_next
      assign o_completing_next_cycle = busy &&
                                       (level_reg == LastLevel) &&
                                       (chunk_reg == PenultimateChunk);
    end else begin : gen_completing_next_single_chunk
      assign o_completing_next_cycle = busy &&
                                       (level_reg == LastLevel) &&
                                       (chunk_reg == ChunkBits'(0));
    end
  endgenerate

endmodule : dsp_tiled_multiplier_unsigned
