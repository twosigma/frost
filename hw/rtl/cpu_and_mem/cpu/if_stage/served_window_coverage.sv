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

// Fixed-depth served-window coverage comparator for one fetch provider.
//
// All tags are 30-bit words in the 32-bit fetch seam.  A provider registers
// S, S+1, S-1, and S!=0 beside its payload.  The three accepted positions are:
//   P == S
//   P == S+1
//   P == S-1, when the instruction buffer owns the preceding parcel
//
// The equality chunks deliberately use no more than six LUT inputs, as do the
// two reduction levels.  Keeping the provider instances separate prevents the
// source selector from being absorbed into a serial cross-provider compare.
// The caller supplies one already-combined instruction-buffer qualification.
// Keeping its constituent controls outside this hierarchy
// prevents them from being absorbed into the address comparator while still
// allowing the preceding-word arm to join five equality chunks and its
// prequalified enable in one LUT6. The final function remains exactly three
// pairs-of-halves in one LUT6 instead of adding a fourth comparison level.
(* keep_hierarchy = "yes" *)
module served_window_coverage (
    input  logic [29:0] i_pc_word,
    input  logic [29:0] i_served_word,
    input  logic [29:0] i_served_last_word,
    input  logic [29:0] i_served_prev_word,
    input  logic        i_served_prev_word_valid,
    input  logic        i_use_instr_buffer,
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
  (* keep = "true" *) logic prev_enable;
  (* keep = "true" *) logic prev_lo_qualified, prev_hi;

  assign same_lo = &same_chunk[4:0];
  assign same_hi = &same_chunk[9:5];
  assign last_lo = &last_chunk[4:0];
  assign last_hi = &last_chunk[9:5];
  // Preserve the caller's one-bit qualification boundary. Absorbing its
  // normal-buffer and prediction-release controls here transfers criticality
  // into the mispredict-recovery address cone.
  assign prev_enable = i_served_prev_word_valid && i_use_instr_buffer;
  // Five equality chunks plus the prequalified arm fit exactly in one LUT6.
  assign prev_lo_qualified = (&prev_chunk[4:0]) && prev_enable;
  assign prev_hi = &prev_chunk[9:5];

  assign o_covers = (same_lo && same_hi) || (last_lo && last_hi) || (prev_lo_qualified && prev_hi);

endmodule
