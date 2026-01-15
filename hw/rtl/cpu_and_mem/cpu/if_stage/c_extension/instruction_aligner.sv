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
  Instruction Aligner

  Handles instruction alignment and parcel selection for RISC-V with C-extension support.
  Responsibilities:
  1. Select correct 16-bit parcel based on PC[1]
  2. Detect compressed vs 32-bit instructions
  3. Manage instruction buffer usage for consecutive compressed instructions
  4. Compute selection signals (NOP, spanning, compressed, or word-aligned 32-bit)
  5. Output raw parcel for PD stage decompression

  TIMING OPTIMIZATION: This module no longer performs decompression. It outputs the
  raw 16-bit parcel and selection signals. The PD stage performs the actual RVC
  decompression, breaking the long combinational path from memory read through
  decompression to pipeline registers.

  This module is purely combinational.
*/
module instruction_aligner #(
    parameter int unsigned XLEN = 32
) (
    // Instruction sources
    input logic [31:0] i_instr,         // Raw instruction from memory
    input logic [31:0] i_instr_buffer,  // Buffered instruction word
    input logic [31:0] i_pc_reg,        // Registered PC

    // C-extension state
    input logic i_prev_was_compressed_at_lo,  // Previous was compressed at lo
    input logic i_spanning_wait_for_fetch,  // Waiting for spanning second word
    input logic i_spanning_in_progress,  // Spanning instruction ready
    input logic [15:0] i_spanning_buffer,  // First half of spanning instr
    input logic [15:0] i_spanning_second_half,  // Second half of spanning instr
    input logic i_spanning_to_halfword_registered,  // Spanning leads to halfword PC
    input logic i_use_buffer_after_spanning,  // Use buffer after spanning_to_halfword holdoff

    // Control signals
    input logic i_mid_32bit_correction,  // Landed mid-instruction
    input logic i_prediction_holdoff,  // Stale cycle after RAS prediction
    input logic i_prediction_from_buffer_holdoff,  // Stale cycle after RAS predicted from buffer

    // Stall handling (only registered signal needed for timing optimization)
    input logic i_stall_registered,
    input logic i_prev_was_compressed_at_lo_saved,

    // Outputs
    output logic [15:0] o_raw_parcel,       // Raw 16-bit parcel for PD decompression
    output logic [31:0] o_effective_instr,  // Effective instruction word (for state)
    output logic [31:0] o_spanning_instr,   // Pre-assembled spanning instruction
    output logic        o_is_compressed,    // Current parcel is compressed
    output logic        o_sel_nop,          // Outputting NOP
    output logic        o_sel_spanning,     // Outputting spanning instruction
    output logic        o_sel_compressed,   // Outputting decompressed instruction
    output logic        o_use_instr_buffer  // Using buffered instruction
);

  // ===========================================================================
  // Instruction Buffer Selection
  // ===========================================================================
  // Use buffer when:
  // 1. Previous was compressed at lo and current is at hi, OR
  // 2. Just came out of spanning_to_halfword holdoff (buffer has correct word, BRAM doesn't)
  // Handle saved value when coming out of stall.

  // TIMING OPTIMIZATION: Use only registered signals for mux select to break
  // the critical path from stall_for_trap_check → is_compressed → PC.
  //
  // The key insight: when stall_registered is true, we use saved values. This covers:
  //   - Currently stalled: value doesn't matter (pipeline not advancing)
  //   - Just unstalled: use saved value (correct behavior)
  //   - Not stalled, wasn't stalled: use live value (correct behavior)
  //
  // During trap/mret (stall goes low but stall_for_trap_check high), flush clears
  // the saved values anyway, so using saved vs live doesn't affect correctness.
  logic use_saved_prev;
  assign use_saved_prev = i_stall_registered;

  logic prev_was_compressed_at_lo_for_use;
  assign prev_was_compressed_at_lo_for_use = use_saved_prev ?
      i_prev_was_compressed_at_lo_saved : i_prev_was_compressed_at_lo;

  // Use buffer when: normal case (compressed at lo -> hi) OR after spanning_to_halfword holdoff
  assign o_use_instr_buffer = (prev_was_compressed_at_lo_for_use && i_pc_reg[1]) ||
                               i_use_buffer_after_spanning;

  // Select effective instruction source
  assign o_effective_instr = o_use_instr_buffer ? i_instr_buffer : i_instr;

  // ===========================================================================
  // Parcel Selection and Type Detection
  // ===========================================================================
  // Flatten to single 4:1 mux for better timing instead of cascaded 2:1 muxes.
  // Select 16-bit parcel based on {use_instr_buffer, PC[1]} simultaneously.

  logic [15:0] current_parcel;
  always_comb begin
    unique case ({
      o_use_instr_buffer, i_pc_reg[1]
    })
      2'b00:   current_parcel = i_instr[15:0];  // Fresh instruction, low half
      2'b01:   current_parcel = i_instr[31:16];  // Fresh instruction, high half
      2'b10:   current_parcel = i_instr_buffer[15:0];  // Buffered instruction, low half
      2'b11:   current_parcel = i_instr_buffer[31:16];  // Buffered instruction, high half
      default: current_parcel = i_instr[15:0];  // X-propagation safety for 4-state simulators
    endcase
  end

  // Output raw parcel for PD stage decompression
  assign o_raw_parcel = current_parcel;

  // ===========================================================================
  // is_compressed Detection - Timing Optimized
  // ===========================================================================
  // TIMING OPTIMIZATION: Compute is_compressed for each parcel source in parallel,
  // then mux the 1-bit result. This is faster than muxing 16 bits then checking 2,
  // because:
  //   - The 2-bit comparisons are very fast (just NAND of bits 0 and 1)
  //   - Muxing 1 bit has less routing congestion than muxing 16 bits
  //   - All 4 checks happen in parallel, then one 4:1 mux for the result
  //
  // Instruction type: bits [1:0] == 2'b11 means 32-bit, otherwise compressed.
  logic is_comp_instr_lo, is_comp_instr_hi, is_comp_buf_lo, is_comp_buf_hi;
  assign is_comp_instr_lo = (i_instr[1:0] != 2'b11);
  assign is_comp_instr_hi = (i_instr[17:16] != 2'b11);
  assign is_comp_buf_lo   = (i_instr_buffer[1:0] != 2'b11);
  assign is_comp_buf_hi   = (i_instr_buffer[17:16] != 2'b11);

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
  // Instruction Selection Signals
  // ===========================================================================
  // Pre-compute select signals in parallel for flat mux structure in PD stage.
  // Decompression has been moved to PD stage for timing.

  // Consolidate all NOP-producing conditions
  // NOTE: prediction_holdoff here is RAS-only. BTB predictions must not suppress
  // the next cycle because that cycle contains the branch instruction itself.
  assign o_sel_nop = i_spanning_to_halfword_registered ||  // Stale after spanning to halfword
      i_mid_32bit_correction ||  // Landed mid-instruction
      i_spanning_wait_for_fetch ||  // Waiting for memory
      i_prediction_holdoff ||  // Stale after RAS prediction
      i_prediction_from_buffer_holdoff ||  // Stale after RAS predicted from buffer
      (i_pc_reg[1] && !o_is_compressed && !i_spanning_in_progress);  // 32-bit spanning first cycle

  assign o_sel_spanning = i_spanning_in_progress && !i_spanning_to_halfword_registered;
  assign o_sel_compressed = o_is_compressed && !o_sel_nop && !o_sel_spanning;

  // Pre-compute spanning instruction once (for PD stage)
  assign o_spanning_instr = {i_spanning_second_half, i_spanning_buffer};

endmodule : instruction_aligner
