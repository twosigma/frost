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
// Tags are 30-bit word addresses, bits [31:2] of the fetch PC the window was
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
// Each equality chunk and both reduction levels fit in a 6-input LUT, so a tag
// path is three LUT levels plus dedicated muxes. The buffer qualification
// (i_use_instr_buffer) enters no equality LUT and selects only at the final
// MUXF8. One instance per provider keeps synthesis from merging the provider
// select into a serial compare across providers.
(* keep_hierarchy = "yes" *)
module served_window_coverage (
    input  logic [29:0] i_pc_word,
    input  logic [29:0] i_served_word,
    input  logic [29:0] i_served_last_word,
    input  logic [29:0] i_served_prev_word,
    input  logic        i_served_prev_word_valid,
    input  logic        i_use_instr_buffer,
    input  logic        i_no_buffer_accepts_served_last,
    input  logic        i_pc_high,
    output logic        o_covers
);

  (* keep = "true" *)logic [9:0] same_chunk;
  (* keep = "true" *)logic [9:0] last_chunk;
  (* keep = "true" *)logic [9:0] prev_chunk;

  for (genvar k = 0; k < 10; k++) begin : gen_eq_chunks
    assign same_chunk[k] = ~|(i_pc_word[3*k+:3] ^ i_served_word[3*k+:3]);
    assign last_chunk[k] = ~|(i_pc_word[3*k+:3] ^ i_served_last_word[3*k+:3]);
    assign prev_chunk[k] = ~|(i_pc_word[3*k+:3] ^ i_served_prev_word[3*k+:3]);
  end

  (* keep = "true" *) logic same_lo, same_hi;
  (* keep = "true" *) logic last_lo, last_hi;
  (* keep = "true" *) logic prev_lo_valid, prev_hi;

  assign same_lo = &same_chunk[4:0];
  assign same_hi = &same_chunk[9:5];
  assign last_lo = &last_chunk[4:0];
  assign last_hi = &last_chunk[9:5];
  // Five equality chunks plus the registered validity fit exactly in one LUT6.
  assign prev_lo_valid = (&prev_chunk[4:0]) && i_served_prev_word_valid;
  assign prev_hi = &prev_chunk[9:5];

  // One candidate per combination of buffer use and whether P+1 is needed,
  // each one LUT of at most the six half-terms (LUT2/LUT4/LUT6).
  // i_no_buffer_accepts_served_last, i_pc_high, and the late buffer
  // qualification are mux selects and stay out of the equality logic.
  (* keep = "true" *) logic no_buffer_covers_same_only, no_buffer_covers_served_last;
  (* keep = "true" *) logic buffer_covers_base, buffer_covers_successor;
  assign no_buffer_covers_same_only = same_lo && same_hi;
  assign no_buffer_covers_served_last = (same_lo && same_hi) || (last_lo && last_hi);
  assign buffer_covers_base = (same_lo && same_hi) || (last_lo && last_hi) ||
      (prev_lo_valid && prev_hi);
  assign buffer_covers_successor = (same_lo && same_hi) || (prev_lo_valid && prev_hi);

  // Two MUXF7s and one MUXF8 pack the four candidate LUTs into one Xilinx
  // slice: i_no_buffer_accepts_served_last selects within the no-buffer arm,
  // i_pc_high within the buffer arm, and the late buffer select drives only
  // the MUXF8. Inferred logic would map the nested selects to LUTs, adding
  // routed levels on the tag paths, hence the explicit primitives.
`ifdef FROST_XILINX_PRIMS
  (* keep = "true" *)logic covers_without_buffer;
  (* keep = "true" *)logic covers_with_buffer;

  MUXF7 u_covers_without_buffer_mux (
      .O (covers_without_buffer),
      .I0(no_buffer_covers_same_only),
      .I1(no_buffer_covers_served_last),
      .S (i_no_buffer_accepts_served_last)
  );

  MUXF7 u_covers_with_buffer_mux (
      .O (covers_with_buffer),
      .I0(buffer_covers_base),
      .I1(buffer_covers_successor),
      .S (i_pc_high)
  );

  MUXF8 u_covers_buffer_mux (
      .O (o_covers),
      .I0(covers_without_buffer),
      .I1(covers_with_buffer),
      .S (i_use_instr_buffer)
  );
`else
  assign o_covers = i_use_instr_buffer ?
      (i_pc_high ? buffer_covers_successor : buffer_covers_base) :
      (i_no_buffer_accepts_served_last ? no_buffer_covers_served_last :
                                         no_buffer_covers_same_only);
`endif

endmodule
