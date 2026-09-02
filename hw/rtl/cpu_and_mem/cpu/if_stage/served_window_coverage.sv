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
// S, S+1, S-1, and S!=0 beside its payload.  The accepted positions are:
//   P == S
//   P == S+1, unless the emitted packet needs word P+1
//   P == S-1, when the instruction buffer owns P and the fetch window owns P+1
// A no-buffer packet needs the successor only for a native instruction at
// P[1]. A buffer-backed packet needs it for every P[1] shape: a native slot 1
// spans into P+1, while an RVC slot 1 can permit slot 2 at P+1's low parcel.
//
// The equality chunks deliberately use no more than six LUT inputs, as do the
// two reduction levels.  Keeping the provider instances separate prevents the
// source selector from being absorbed into a serial cross-provider compare.
// The caller supplies one already-combined instruction-buffer qualification.
// It is the latest-arriving input (the prediction-holdoff cone), so it enters
// no equality LUT. Four verdict candidates cover the Cartesian product of
// buffer/no-buffer and packet shape. The instruction-size bit selects within
// the no-buffer arm; P[1] selects within the buffer arm. The late buffer
// qualification then selects those arms through one MUXF8. The tag paths keep
// exactly three LUT levels plus those dedicated muxes; the late buffer
// qualification enters only the MUXF8.
(* keep_hierarchy = "yes" *)
module served_window_coverage (
    input  logic [29:0] i_pc_word,
    input  logic [29:0] i_served_word,
    input  logic [29:0] i_served_last_word,
    input  logic [29:0] i_served_prev_word,
    input  logic        i_served_prev_word_valid,
    input  logic        i_use_instr_buffer,
    input  logic        i_is_compressed,
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

  // Each candidate is one LUT of at most the six half-terms (LUT2/LUT4/LUT6).
  // Instruction size, pc-high, and the late instruction-buffer qualification
  // remain dedicated mux selects rather than entering the equality cones.
  (* keep = "true" *) logic no_buffer_covers_native, no_buffer_covers_compressed;
  (* keep = "true" *) logic buffer_covers_base, buffer_covers_successor;
  // A native high-parcel instruction needs P+1; native at P-low and every RVC
  // shape need only P itself when no instruction buffer is active.
  assign no_buffer_covers_native = (same_lo && same_hi) || (!i_pc_high && last_lo && last_hi);
  assign no_buffer_covers_compressed = (same_lo && same_hi) || (last_lo && last_hi);
  assign buffer_covers_base = (same_lo && same_hi) || (last_lo && last_hi) ||
      (prev_lo_valid && prev_hi);
  assign buffer_covers_successor = (same_lo && same_hi) || (prev_lo_valid && prev_hi);

  // Two MUXF7s and one MUXF8 pack the four candidate LUTs into one Xilinx
  // slice. The earlier instruction-size / pc-high selects choose within each
  // fixed buffer arm; the late buffer select owns the final MUXF8 only.
  // Inference maps the nested selects to LUTs instead (adding general routing
  // levels on the tag paths), hence the explicit primitives.
`ifdef FROST_XILINX_PRIMS
  (* keep = "true" *)logic covers_without_buffer;
  (* keep = "true" *)logic covers_with_buffer;

  MUXF7 u_covers_without_buffer_mux (
      .O (covers_without_buffer),
      .I0(no_buffer_covers_native),
      .I1(no_buffer_covers_compressed),
      .S (i_is_compressed)
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
      (i_is_compressed ? no_buffer_covers_compressed : no_buffer_covers_native);
`endif

endmodule
