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

// Served-window check for one fetch provider: does the window it presents
// hold every word that pc_reg's packet needs?
//
// Tags are WORD_BITS-wide word addresses of the fetch PC the window was
// fetched for and of pc_reg. With S the window's first word, the provider
// registers S, S+1, S-1, and S != 0 beside its payload. pc_reg's word P is
// covered when:
//   P == S;
//   P == S+1 (the window ends at P), unless the packet needs word P+1;
//   P == S-1, when the instruction buffer supplies P and the window P+1.
// Without the buffer, only a 32-bit instruction in the upper half of P needs
// P+1; the caller passes that decision as i_no_buffer_accepts_served_last
// (always set when pc_reg is in the lower half, and in the upper half only
// for a compressed instruction). With the buffer, a packet that starts in the
// upper half of P always needs P+1: a 32-bit slot 1 spans into it, and a
// compressed slot 1 can pair with a slot 2 in its lower half.
//
// Separate provider instances and balanced equality trees are used for timing.
(* keep_hierarchy = "yes" *)
module served_window_coverage #(
    parameter int unsigned WORD_BITS = 30
) (
    input  logic [WORD_BITS-1:0] i_pc_word,
    input  logic [WORD_BITS-1:0] i_served_word,
    input  logic [WORD_BITS-1:0] i_served_last_word,
    input  logic [WORD_BITS-1:0] i_served_prev_word,
    input  logic                 i_served_prev_word_valid,
    input  logic                 i_use_instr_buffer,
    input  logic                 i_no_buffer_accepts_served_last,
    input  logic                 i_pc_high,
    output logic                 o_covers
);

  // Apply the same three-bit comparisons to the entire virtual address.
  // A separate wide upper equality inferred carry chains on the PC path.
  localparam int unsigned ChunkCount = (WORD_BITS + 2) / 3;
  localparam int unsigned GroupCount = (ChunkCount + 5) / 6;
  (* keep = "true" *) logic [ChunkCount-1:0] same_chunk, last_chunk, prev_chunk;
  (* keep = "true" *) logic [GroupCount-1:0] same_group, last_group, prev_group;
  for (genvar k = 0; k < ChunkCount; k++) begin : gen_eq_chunks
    localparam int unsigned Width = WORD_BITS - 3 * k < 3 ? WORD_BITS - 3 * k : 3;
    assign same_chunk[k] = ~|(i_pc_word[3*k+:Width] ^ i_served_word[3*k+:Width]);
    assign last_chunk[k] = ~|(i_pc_word[3*k+:Width] ^ i_served_last_word[3*k+:Width]);
    assign prev_chunk[k] = ~|(i_pc_word[3*k+:Width] ^ i_served_prev_word[3*k+:Width]);
  end
  for (genvar k = 0; k < GroupCount; k++) begin : gen_eq_groups
    localparam int unsigned Width = ChunkCount - 6 * k < 6 ? ChunkCount - 6 * k : 6;
    assign same_group[k] = &same_chunk[6*k+:Width];
    assign last_group[k] = &last_chunk[6*k+:Width];
    assign prev_group[k] = &prev_chunk[6*k+:Width];
  end
  (* keep = "true" *) logic same_word, last_word, prev_word_valid;
  assign same_word = &same_group;
  assign last_word = &last_group;
  assign prev_word_valid = (&prev_group) && i_served_prev_word_valid;

  // Once the three equalities are available, all buffer/packet cases fit in
  // one LUT: S always covers; S+1 needs no successor; S-1 needs the buffer.
`ifdef FROST_XILINX_PRIMS
  (* dont_touch = "true" *)
  LUT6 #(
      .INIT(64'hFAEEFEEEFAAAFEAA)
  ) u_covers (
      .O (o_covers),
      .I0(same_word),
      .I1(last_word),
      .I2(prev_word_valid),
      .I3(i_use_instr_buffer),
      .I4(i_pc_high),
      .I5(i_no_buffer_accepts_served_last)
  );
`else
  assign o_covers = same_word ||
      (last_word && (i_use_instr_buffer ? !i_pc_high : i_no_buffer_accepts_served_last)) ||
      (prev_word_valid && i_use_instr_buffer);
`endif

`ifdef FORMAL
  // Check the complete word address and every combination of packet shape
  // and buffer state, without assuming relationships between the tags.
  always_comb begin
    p_coverage_matches_full_address_reference :
    assert (o_covers == ((i_pc_word == i_served_word) ||
            ((i_pc_word == i_served_last_word) &&
             (i_use_instr_buffer ? !i_pc_high : i_no_buffer_accepts_served_last)) ||
            ((i_pc_word == i_served_prev_word) && i_served_prev_word_valid &&
             i_use_instr_buffer)));
  end
`endif

endmodule
