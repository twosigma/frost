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
// P+1; this module resolves that predicate directly from this provider's
// parity-ordered upper-half compressed bits (i_hi_compressed_by_parity) and
// the shared override select and value (i_override_sel, i_override_val)
// carrying the aligner's saved-size and buffered-size branches. With the
// buffer, a packet that starts in the upper half of P always needs P+1: a
// 32-bit slot 1 spans into it, and a compressed slot 1 can pair with a slot 2
// in its lower half.
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
    input  logic [          1:0] i_hi_compressed_by_parity,
    input  logic                 i_override_sel,
    input  logic                 i_override_val,
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

  // Per-provider served-last predicate: low-half packets always fit in S+1;
  // high-half packets fit iff compressed (using the shared saved/buffer
  // override when active, otherwise this provider's parity-selected bit).
  logic no_buffer_accepts_served_last;
`ifdef FROST_XILINX_PRIMS
  (* dont_touch = "true" *)
  LUT6 #(
      .INIT(64'hF7F7F7D5D5F7D5D5)
  ) u_no_buffer_accepts_served_last (
      .O (no_buffer_accepts_served_last),
      .I0(i_pc_high),
      .I1(i_override_sel),
      .I2(i_override_val),
      .I3(i_pc_word[0]),
      .I4(i_hi_compressed_by_parity[0]),
      .I5(i_hi_compressed_by_parity[1])
  );
`else
  assign no_buffer_accepts_served_last =
      !i_pc_high ||
      (i_override_sel ? i_override_val :
       (i_pc_word[0] ? i_hi_compressed_by_parity[1] : i_hi_compressed_by_parity[0]));
`endif

  // Combine the three tag equalities with the buffer and served-last checks:
  // S always covers; S+1 needs no successor; S-1 needs the buffer.
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
      .I5(no_buffer_accepts_served_last)
  );
`else
  assign o_covers = same_word ||
      (last_word && (i_use_instr_buffer ? !i_pc_high : no_buffer_accepts_served_last)) ||
      (prev_word_valid && i_use_instr_buffer);
`endif

endmodule : served_window_coverage

// Six-input served-window guard combining both providers' coverage verdicts
// with response validity, walk-past squash, and low-provider replay masking.
(* keep_hierarchy = "yes" *)
// verilog_lint: waive module-filename
module served_window_guard (
    input  logic i_instr_valid,
    input  logic i_served_high,
    input  logic i_covers_high,
    input  logic i_covers_low,
    input  logic i_walk_past,
    input  logic i_replay_saved,
    output logic o_cannot_serve
);

`ifdef FROST_XILINX_PRIMS
  (* dont_touch = "true" *)
  LUT6 #(
      .INIT(64'h88880808AAAA082A)
  ) u_window_cannot_serve (
      .O (o_cannot_serve),
      .I0(i_instr_valid),
      .I1(i_served_high),
      .I2(i_covers_high),
      .I3(i_covers_low),
      .I4(i_walk_past),
      .I5(i_replay_saved)
  );
`else
  assign o_cannot_serve = i_instr_valid &&
      (!(i_served_high ? i_covers_high : i_covers_low) || i_walk_past) &&
      (i_served_high || !i_replay_saved);
`endif

endmodule : served_window_guard
