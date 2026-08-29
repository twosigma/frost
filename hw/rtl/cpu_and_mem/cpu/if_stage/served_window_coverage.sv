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
// It is the latest-arriving input (the prediction-holdoff cone), so it enters
// no equality LUT: both verdict candidates -- with and without the
// preceding-word arm -- are functions of registered tags only, and the
// qualification selects between them in the final 2:1 mux. The tag paths
// keep exactly three LUT levels plus that mux; the qualification path is the
// mux alone.
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
  (* keep = "true" *) logic prev_lo_valid, prev_hi;

  assign same_lo = &same_chunk[4:0];
  assign same_hi = &same_chunk[9:5];
  assign last_lo = &last_chunk[4:0];
  assign last_hi = &last_chunk[9:5];
  // Five equality chunks plus the registered validity fit exactly in one LUT6.
  assign prev_lo_valid = (&prev_chunk[4:0]) && i_served_prev_word_valid;
  assign prev_hi = &prev_chunk[9:5];

  // Both candidates are one LUT of the six half-terms (LUT4 / LUT6). The
  // late instruction-buffer qualification is the select of the final mux.
  (* keep = "true" *) logic covers_without_prev, covers_with_prev;
  assign covers_without_prev = (same_lo && same_hi) || (last_lo && last_hi);
  assign covers_with_prev = (same_lo && same_hi) || (last_lo && last_hi) ||
      (prev_lo_valid && prev_hi);
  // The final select is a dedicated MUXF7 in the Xilinx flow: the two
  // candidate LUTs and the mux pack into one slice, so the tag paths keep
  // exactly three LUT levels and the qualification path is the mux alone.
  // Inference maps this ternary to a LUT3 instead (a fourth level on every
  // tag path), hence the explicit primitive.
`ifdef FROST_XILINX_PRIMS
  MUXF7 u_covers_mux (
      .O (o_covers),
      .I0(covers_without_prev),
      .I1(covers_with_prev),
      .S (i_use_instr_buffer)
  );
`else
  assign o_covers = i_use_instr_buffer ? covers_with_prev : covers_without_prev;
`endif

endmodule
