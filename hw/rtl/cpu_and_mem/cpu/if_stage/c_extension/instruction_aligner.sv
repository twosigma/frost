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
  Instruction Aligner — 64-bit Fetch

  Handles instruction alignment and parcel selection for RISC-V with C-extension
  support.  With 64-bit instruction fetch (two consecutive 32-bit words per
  cycle), spanning is eliminated: a 32-bit instruction at a halfword boundary
  (PC[1]=1) is assembled combinationally from the two words in a single cycle.

  Responsibilities:
  1. Select correct 16-bit parcel based on PC[1]
  2. Detect compressed vs 32-bit instructions via predecode sideband
  3. Manage instruction buffer usage for consecutive compressed instructions
  4. Assemble spanning instructions from the 64-bit fetch window
  5. Compute selection signals (NOP, compressed, or 32-bit)
  6. Output raw parcel for PD stage decompression

  TIMING OPTIMIZATION: This module no longer performs decompression. It outputs
  the raw 16-bit parcel and selection signals. The PD stage performs the actual
  RVC decompression, breaking the long combinational path from memory read
  through decompression to pipeline registers.

  This module is purely combinational.
*/
module instruction_aligner #(
    parameter int unsigned XLEN = 32
) (
    // 64-bit instruction fetch: {next_word[31:0], current_word[31:0]}
    input logic [63:0] i_instr,
    input logic [3:0] i_instr_sideband,  // {next_sb[1:0], current_sb[1:0]}
    input logic i_instr_bank_sel_r,  // Registered fetch-word parity (PC[2] from BRAM cycle)
    input logic [31:0] i_instr_buffer,  // Buffered instruction word
    input logic [1:0] i_instr_buffer_sideband,  // Predecode sideband for buffered word
    input logic [31:0] i_pc_reg,  // Registered PC

    // C-extension state
    input logic i_prev_was_compressed_at_lo,   // Previous was compressed at lo
    input logic i_use_buffer_after_prediction, // Use buffer after prediction-from-buffer holdoff

    // Control signals
    input logic i_mid_32bit_correction,  // Landed mid-instruction
    input logic i_prediction_holdoff,  // Stale cycle after RAS prediction
    input logic i_prediction_from_buffer_holdoff,  // Stale cycle after RAS predicted from buffer

    // Stall handling (only registered signal needed for timing optimization)
    input logic i_stall_registered,
    input logic i_prev_was_compressed_at_lo_saved,
    input logic i_is_compressed_saved,  // Saved is_compressed from stall start
    input logic i_saved_values_valid,  // Saved values are valid (not invalidated by control flow)

    // Outputs
    output logic [15:0] o_raw_parcel,  // Raw 16-bit parcel for PD decompression
    output logic [31:0] o_effective_instr,  // Effective instruction word (assembled for spanning)
    output logic o_is_compressed,  // Current parcel is compressed
    output logic o_is_compressed_fast,  // Fast path for PC-critical path (registered selects only)
    output logic o_sel_nop,  // Outputting NOP
    output logic o_sel_compressed,  // Outputting decompressed instruction
    output logic o_use_instr_buffer  // Using buffered instruction
);

  // ===========================================================================
  // Instruction Buffer Selection
  // ===========================================================================
  // Use buffer when:
  // 1. Previous was compressed at lo and current is at hi, OR
  // 2. After prediction-from-buffer holdoff
  // Handle saved value when coming out of stall.

  // TIMING OPTIMIZATION: Use only registered signals for mux select to break
  // the critical path from stall_for_trap_check -> is_compressed -> PC.
  logic use_saved_prev;
  assign use_saved_prev = i_stall_registered && i_saved_values_valid;

  logic prev_was_compressed_at_lo_for_use;
  assign prev_was_compressed_at_lo_for_use = use_saved_prev ?
      i_prev_was_compressed_at_lo_saved : i_prev_was_compressed_at_lo;

  // Use buffer when: normal case (compressed at lo -> hi) OR after prediction holdoff
  assign o_use_instr_buffer = (prev_was_compressed_at_lo_for_use && i_pc_reg[1]) ||
                               i_use_buffer_after_prediction;

  // ===========================================================================
  // Current Word and Next Word Selection
  // ===========================================================================
  // The BRAM outputs {word(F+1), word(F)} where F is the registered fetch word
  // address.  Normally F == pc_reg's word address W, but the fetch lead can
  // shift F by ±1 depending on instruction mix and branch prediction timing.
  //
  // Use bank_sel_r (= F[0]) vs pc_reg[2] (= W[0]) to detect the shift:
  //   same parity  → word(W) is at i_instr[31:0]   (normal ordering)
  //   diff parity  → word(W) is at i_instr[63:32]  (fetch is ±1 word off)
  //
  // When the instruction buffer is active, the buffer provides word(W)
  // directly and the BRAM alignment doesn't matter for the current word.
  logic fetch_word_swapped;
  assign fetch_word_swapped = i_instr_bank_sel_r ^ i_pc_reg[2];

  logic [31:0] bram_current_word;  // BRAM word aligned to pc_reg
  assign bram_current_word = fetch_word_swapped ? i_instr[63:32] : i_instr[31:0];

  logic [31:0] current_word;
  assign current_word = o_use_instr_buffer ? i_instr_buffer : bram_current_word;

  // Select effective instruction source (for state machine, buffer capture, etc.)
  assign o_effective_instr = current_word;

  // ===========================================================================
  // Parcel Selection and Type Detection
  // ===========================================================================
  // Select 16-bit parcel based on PC[1].
  logic [15:0] current_parcel;
  assign current_parcel = i_pc_reg[1] ? current_word[31:16] : current_word[15:0];

  // Output raw parcel for PD stage decompression
  assign o_raw_parcel   = current_parcel;

  // ===========================================================================
  // is_compressed Detection - Predecode Sideband
  // ===========================================================================
  // Use predecode sideband bits from IMEM BRAM. For buffered instructions,
  // the sideband was captured when the buffer was written.
  // Align sideband bits the same way as the instruction word.
  // Original order: {next_sb[1:0], current_sb[1:0]}.  When fetch_word_swapped,
  // the "current" sideband is in the upper two bits.
  logic [1:0] aligned_current_sb, aligned_next_sb;
  assign aligned_current_sb = fetch_word_swapped ? i_instr_sideband[3:2] : i_instr_sideband[1:0];
  assign aligned_next_sb    = fetch_word_swapped ? i_instr_sideband[1:0] : i_instr_sideband[3:2];

  logic is_comp_instr_lo, is_comp_instr_hi, is_comp_buf_lo, is_comp_buf_hi;
  assign is_comp_instr_lo = aligned_current_sb[0];
  assign is_comp_instr_hi = aligned_current_sb[1];
  assign is_comp_buf_lo   = i_instr_buffer_sideband[0];
  assign is_comp_buf_hi   = i_instr_buffer_sideband[1];

  // 4:1 mux for the 1-bit is_compressed result
  always_comb begin
    unique case ({
      o_use_instr_buffer, i_pc_reg[1]
    })
      2'b00:   o_is_compressed = is_comp_instr_lo;
      2'b01:   o_is_compressed = is_comp_instr_hi;
      2'b10:   o_is_compressed = is_comp_buf_lo;
      2'b11:   o_is_compressed = is_comp_buf_hi;
      default: o_is_compressed = 1'b0;
    endcase
  end

  // ===========================================================================
  // Fast is_compressed for PC-Critical Path
  // ===========================================================================
  // TIMING OPTIMIZATION: Flatten the mux cascade to a one-hot parallel structure.

  // Compute select signals from registered inputs (available early, not on BRAM path)
  logic use_saved_is_compressed;
  assign use_saved_is_compressed = i_stall_registered && i_saved_values_valid;

  logic prev_was_compressed_at_lo_fast;
  assign prev_was_compressed_at_lo_fast = i_stall_registered ?
      i_prev_was_compressed_at_lo_saved : i_prev_was_compressed_at_lo;

  logic need_buffer_fast;
  assign need_buffer_fast = (prev_was_compressed_at_lo_fast && i_pc_reg[1]) ||
                            i_use_buffer_after_prediction;

  // One-hot select signals (computed from registered inputs, not on BRAM path)
  logic sel_saved, sel_buf_hi, sel_buf_lo, sel_instr_hi, sel_instr_lo;
  assign sel_saved = use_saved_is_compressed;
  assign sel_buf_hi = !use_saved_is_compressed && need_buffer_fast && i_pc_reg[1];
  assign sel_buf_lo = !use_saved_is_compressed && need_buffer_fast && !i_pc_reg[1];
  assign sel_instr_hi = !use_saved_is_compressed && !need_buffer_fast && i_pc_reg[1];
  assign sel_instr_lo = !use_saved_is_compressed && !need_buffer_fast && !i_pc_reg[1];

  // One-hot mux: AND each data input with its select, then OR together
  assign o_is_compressed_fast =
      (sel_saved    & i_is_compressed_saved) |
      (sel_buf_hi   & is_comp_buf_hi) |
      (sel_buf_lo   & is_comp_buf_lo) |
      (sel_instr_hi & is_comp_instr_hi) |
      (sel_instr_lo & is_comp_instr_lo);

  // ===========================================================================
  // Instruction Selection Signals
  // ===========================================================================
  // With 64-bit fetch, spanning is assembled immediately — no NOP for spanning.
  // The NOP conditions are reduced to holdoff/correction cases only.
  assign o_sel_nop = i_mid_32bit_correction ||
      i_prediction_holdoff ||
      i_prediction_from_buffer_holdoff;

  // sel_compressed: compressed instruction (not a NOP cycle)
  // PD stage applies priority (NOP > compressed > 32-bit).
  assign o_sel_compressed = o_is_compressed;

endmodule : instruction_aligner
