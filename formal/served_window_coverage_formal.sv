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

// Formal harness for served_window_coverage and served_window_guard.
//
// Proves four combinational properties over arbitrary word tags, provider
// parity metadata, stall/saved/fence/buffer controls, and guard inputs:
//   1. Standalone served_window_coverage equals the full-width address
//      reference over unconstrained override and buffer inputs.
//   2. Standalone served_window_guard equals the six-input
//      window_cannot_serve_pc_reg expression over unconstrained inputs.
//   3. The per-provider coverage pair driven by if_stage's shared override
//      matches instruction_aligner's exact o_no_buffer_accepts_served_last
//      expression (including fence.i gating and stall-selected prev_fast).
//   4. End-to-end served_window_guard over the per-provider pair equals the
//      aligner-based window_cannot_serve_pc_reg expression for all inputs.
// Also exports outputs for direct portable-versus-primitive checking across
// all three LUT6 instances.
module served_window_coverage_formal #(
    parameter int unsigned WORD_BITS = 30
) (
    input  logic [WORD_BITS-1:0] i_pc_word,
    input  logic [WORD_BITS-1:0] i_served_word_low,
    input  logic [WORD_BITS-1:0] i_served_last_word_low,
    input  logic [WORD_BITS-1:0] i_served_prev_word_low,
    input  logic                 i_served_prev_word_valid_low,
    input  logic [WORD_BITS-1:0] i_served_word_high,
    input  logic [WORD_BITS-1:0] i_served_last_word_high,
    input  logic [WORD_BITS-1:0] i_served_prev_word_high,
    input  logic                 i_served_prev_word_valid_high,
    input  logic                 i_use_instr_buffer_free,
    input  logic [          1:0] i_hi_compressed_free,
    input  logic                 i_override_sel_free,
    input  logic                 i_override_val_free,
    input  logic                 i_covers_high_free,
    input  logic                 i_covers_low_free,
    input  logic [         15:0] i_instr_pc_metadata_by_provider_parity,
    input  logic                 i_instr_pc_metadata_served_high,
    input  logic                 i_stall_registered,
    input  logic                 i_saved_values_valid,
    input  logic                 i_fence_i_flush,
    input  logic                 i_prev_live,
    input  logic                 i_prev_saved,
    input  logic                 i_is_compressed_saved,
    input  logic                 i_is_comp_buf_hi,
    input  logic                 i_pc_high,
    input  logic                 i_instr_valid,
    input  logic                 i_walk_past,
    input  logic                 i_replay_saved,
    output logic                 o_covers_free,
    output logic                 o_cannot_serve_free,
    output logic                 o_covers_selected,
    output logic                 o_cannot_serve
);

  // Free-input instances checking all three LUT6s across every minterm.
  served_window_coverage #(
      .WORD_BITS(WORD_BITS)
  ) u_cov_free (
      .i_pc_word                (i_pc_word),
      .i_served_word            (i_served_word_low),
      .i_served_last_word       (i_served_last_word_low),
      .i_served_prev_word       (i_served_prev_word_low),
      .i_served_prev_word_valid (i_served_prev_word_valid_low),
      .i_use_instr_buffer       (i_use_instr_buffer_free),
      .i_hi_compressed_by_parity(i_hi_compressed_free),
      .i_override_sel           (i_override_sel_free),
      .i_override_val           (i_override_val_free),
      .i_pc_high                (i_pc_high),
      .o_covers                 (o_covers_free)
  );

  served_window_guard u_guard_free (
      .i_instr_valid (i_instr_valid),
      .i_served_high (i_instr_pc_metadata_served_high),
      .i_covers_high (i_covers_high_free),
      .i_covers_low  (i_covers_low_free),
      .i_walk_past   (i_walk_past),
      .i_replay_saved(i_replay_saved),
      .o_cannot_serve(o_cannot_serve_free)
  );

  // Per-provider candidate matching if_stage.sv.
  logic use_saved_values;
  logic prev_for_coverage;
  logic use_instr_buffer_for_coverage;
  logic coverage_use_saved_size;
  logic coverage_prev_fast;
  logic coverage_override_sel;
  logic coverage_override_val;
  logic covers_low;
  logic covers_high;

  assign use_saved_values = i_stall_registered && i_saved_values_valid;
  assign prev_for_coverage = use_saved_values ? i_prev_saved : i_prev_live;
  assign use_instr_buffer_for_coverage = prev_for_coverage && i_pc_high;

  assign coverage_use_saved_size = i_stall_registered && i_saved_values_valid && !i_fence_i_flush;
  assign coverage_prev_fast = i_stall_registered ? i_prev_saved : i_prev_live;
  assign coverage_override_sel = coverage_use_saved_size || coverage_prev_fast;
  assign coverage_override_val = coverage_use_saved_size ? i_is_compressed_saved : i_is_comp_buf_hi;

  served_window_coverage #(
      .WORD_BITS(WORD_BITS)
  ) u_cov_low (
      .i_pc_word(i_pc_word),
      .i_served_word(i_served_word_low),
      .i_served_last_word(i_served_last_word_low),
      .i_served_prev_word(i_served_prev_word_low),
      .i_served_prev_word_valid(i_served_prev_word_valid_low),
      .i_use_instr_buffer(use_instr_buffer_for_coverage),
      .i_hi_compressed_by_parity({
        i_instr_pc_metadata_by_provider_parity[5], i_instr_pc_metadata_by_provider_parity[1]
      }),
      .i_override_sel(coverage_override_sel),
      .i_override_val(coverage_override_val),
      .i_pc_high(i_pc_high),
      .o_covers(covers_low)
  );

  served_window_coverage #(
      .WORD_BITS(WORD_BITS)
  ) u_cov_high (
      .i_pc_word(i_pc_word),
      .i_served_word(i_served_word_high),
      .i_served_last_word(i_served_last_word_high),
      .i_served_prev_word(i_served_prev_word_high),
      .i_served_prev_word_valid(i_served_prev_word_valid_high),
      .i_use_instr_buffer(use_instr_buffer_for_coverage),
      .i_hi_compressed_by_parity({
        i_instr_pc_metadata_by_provider_parity[13], i_instr_pc_metadata_by_provider_parity[9]
      }),
      .i_override_sel(coverage_override_sel),
      .i_override_val(coverage_override_val),
      .i_pc_high(i_pc_high),
      .o_covers(covers_high)
  );

  assign o_covers_selected = i_instr_pc_metadata_served_high ? covers_high : covers_low;

  served_window_guard u_guard (
      .i_instr_valid (i_instr_valid),
      .i_served_high (i_instr_pc_metadata_served_high),
      .i_covers_high (covers_high),
      .i_covers_low  (covers_low),
      .i_walk_past   (i_walk_past),
      .i_replay_saved(i_replay_saved),
      .o_cannot_serve(o_cannot_serve)
  );

`ifdef FORMAL
  // Standalone references for u_cov_free and u_guard_free.
  logic no_buffer_free_ref;
  logic covers_free_ref;
  logic guard_free_ref;

  assign no_buffer_free_ref = !i_pc_high ||
      (i_override_sel_free ? i_override_val_free :
       (i_pc_word[0] ? i_hi_compressed_free[1] : i_hi_compressed_free[0]));
  assign covers_free_ref = (i_pc_word == i_served_word_low) ||
      ((i_pc_word == i_served_last_word_low) &&
       (i_use_instr_buffer_free ? !i_pc_high : no_buffer_free_ref)) ||
      ((i_pc_word == i_served_prev_word_low) && i_served_prev_word_valid_low &&
       i_use_instr_buffer_free);
  assign guard_free_ref = i_instr_valid &&
      (!(i_instr_pc_metadata_served_high ? i_covers_high_free : i_covers_low_free) ||
       i_walk_past) &&
      (i_instr_pc_metadata_served_high || !i_replay_saved);

  // Verbatim reference copied from instruction_aligner.sv and pre-change
  // if_stage.sv (o_no_buffer_accepts_served_last -> served_window_coverage ->
  // window_cannot_serve_pc_reg).
  logic [3:0] aligner_current_pc_metadata;
  always_comb begin
    case ({
      i_instr_pc_metadata_served_high, i_pc_word[0]
    })
      2'b00:   aligner_current_pc_metadata = i_instr_pc_metadata_by_provider_parity[3:0];
      2'b01:   aligner_current_pc_metadata = i_instr_pc_metadata_by_provider_parity[7:4];
      2'b10:   aligner_current_pc_metadata = i_instr_pc_metadata_by_provider_parity[11:8];
      2'b11:   aligner_current_pc_metadata = i_instr_pc_metadata_by_provider_parity[15:12];
      default: aligner_current_pc_metadata = 4'b0000;
    endcase
  end
  logic aligner_is_comp_instr_hi_for_pc_advance;
  logic aligner_use_saved_is_compressed;
  logic aligner_prev_was_compressed_at_lo_fast;
  logic aligner_is_compressed_for_pc_advance_high;
  logic aligner_no_buffer_accepts_served_last;
  logic aligner_covers_low;
  logic aligner_covers_high;
  logic aligner_covers_selected;
  logic aligner_cannot_serve;

  assign aligner_is_comp_instr_hi_for_pc_advance = aligner_current_pc_metadata[1];
  assign aligner_use_saved_is_compressed =
      i_stall_registered && (i_saved_values_valid && !i_fence_i_flush);
  assign aligner_prev_was_compressed_at_lo_fast = i_stall_registered ? i_prev_saved : i_prev_live;
  assign aligner_is_compressed_for_pc_advance_high =
      aligner_use_saved_is_compressed ? i_is_compressed_saved :
      (aligner_prev_was_compressed_at_lo_fast ? i_is_comp_buf_hi :
       aligner_is_comp_instr_hi_for_pc_advance);
  assign aligner_no_buffer_accepts_served_last =
      !i_pc_high || aligner_is_compressed_for_pc_advance_high;

  assign aligner_covers_low = (i_pc_word == i_served_word_low) ||
      ((i_pc_word == i_served_last_word_low) &&
       (use_instr_buffer_for_coverage ? !i_pc_high : aligner_no_buffer_accepts_served_last)) ||
      ((i_pc_word == i_served_prev_word_low) && i_served_prev_word_valid_low &&
       use_instr_buffer_for_coverage);
  assign aligner_covers_high = (i_pc_word == i_served_word_high) ||
      ((i_pc_word == i_served_last_word_high) &&
       (use_instr_buffer_for_coverage ? !i_pc_high : aligner_no_buffer_accepts_served_last)) ||
      ((i_pc_word == i_served_prev_word_high) && i_served_prev_word_valid_high &&
       use_instr_buffer_for_coverage);
  assign aligner_covers_selected =
      i_instr_pc_metadata_served_high ? aligner_covers_high : aligner_covers_low;
  assign aligner_cannot_serve = i_instr_valid &&
      (!aligner_covers_selected || i_walk_past) &&
      (i_instr_pc_metadata_served_high || !i_replay_saved);

  always_comb begin
    p_coverage_matches_full_address_reference : assert (o_covers_free == covers_free_ref);
    p_guard_matches_reference : assert (o_cannot_serve_free == guard_free_ref);
    p_selected_coverage_matches_aligner : assert (o_covers_selected == aligner_covers_selected);
    p_guard_matches_aligner_end_to_end : assert (o_cannot_serve == aligner_cannot_serve);
`ifdef SERVED_WINDOW_COVER
    c_fence_i_stall_saved_override :
    cover (i_fence_i_flush && i_stall_registered && i_saved_values_valid &&
           !use_instr_buffer_for_coverage && i_pc_high &&
           (i_pc_word ==
            (i_instr_pc_metadata_served_high ? i_served_last_word_high : i_served_last_word_low)) &&
           (i_pc_word !=
            (i_instr_pc_metadata_served_high ? i_served_word_high : i_served_word_low)) &&
           (i_is_compressed_saved != aligner_no_buffer_accepts_served_last));
    c_stall_unsaved_prev_saved_override :
    cover (i_stall_registered && !i_saved_values_valid && i_prev_saved && !i_prev_live &&
           i_pc_high && !use_instr_buffer_for_coverage &&
           (i_pc_word ==
            (i_instr_pc_metadata_served_high ? i_served_last_word_high : i_served_last_word_low)) &&
           (i_pc_word !=
            (i_instr_pc_metadata_served_high ? i_served_word_high : i_served_word_low)) &&
           (i_is_comp_buf_hi != aligner_is_comp_instr_hi_for_pc_advance));
    c_guard_fires_low :
    cover (o_cannot_serve && !i_instr_pc_metadata_served_high && !o_covers_selected &&
           !i_walk_past && !i_replay_saved);
    c_guard_fires_high :
    cover (o_cannot_serve && i_instr_pc_metadata_served_high && !o_covers_selected &&
           !i_walk_past && i_replay_saved);
`endif
  end
`endif

endmodule : served_window_coverage_formal
