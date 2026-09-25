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
  Parcel selection for IF's 64-bit fetch window. Picks slot 1's raw parcel
  and size, and decides whether a second instruction (slot 2) fits in the
  window and may pair with it. pc_reg's word comes from the window or from
  the instruction buffer.

  Slot 1 is not assembled here: PD builds a compressed slot 1 from the
  predecoded expansion fields selected below, and IF assembles a native
  slot 1 that spans two words. Slot 2 is built here for each of its three
  fixed start positions, so the late position select chooses among finished
  values instead of running a parcel mux, expander, and mux in series. The
  module is combinational.
*/
module instruction_aligner #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    // 64-bit instruction fetch: {next_word[31:0], current_word[31:0]}
    input logic [63:0] i_instr,
    input logic [riscv_pkg::ImemFetchSidebandWidth-1:0] i_instr_sideband,
    // Timing copies of the predecode bits that the PC and pairing logic read,
    // per word in {provider, word parity} order:
    // {cached odd[3:0], cached even[3:0], BRAM odd[3:0], BRAM even[3:0]}.
    // Each nibble is {pairable_native_hi, pairable_compressed_hi,
    // compressed_hi, compressed_lo}. Both providers deliver registered lanes
    // already in parity order (the cached provider reorders them on the edge
    // that captures its payload), so provider and pc_reg[2] are the only
    // selects here.
    input logic [15:0] i_instr_pc_metadata_by_provider_parity,
    // Same order: {pairable_native_lo, even_local_pair_valid} per word, and
    // one slot2_start_valid_lo bit per word.
    input logic [7:0] i_pc_pairability_by_provider_parity,
    input logic [3:0] i_slot2_start_valid_lo_by_provider_parity,
    // The window came from the cached provider: select the cached lanes above.
    input logic i_instr_pc_metadata_served_high,
    // Ordered like i_instr: {next-word high-parcel rd==x2,
    // current-word high-parcel rd==x2}.
    input logic [1:0] i_instr_hi_rd_is_x2,
    input logic i_instr_bank_sel_r,  // Registered parity of the fetched word (address bit 2)
    input logic [31:0] i_instr_buffer,  // Buffered instruction word
    input logic [riscv_pkg::ImemSidebandWidth-1:0] i_instr_buffer_sideband,
    input logic [XLEN-1:0] i_pc_reg,  // Registered PC
    // Copy of i_pc_reg[1] for the fast size selects and
    // o_no_buffer_accepts_served_last only; if_stage asserts that it equals
    // i_pc_reg[1].
    input logic i_pc_reg_high_for_coverage,

    // C-extension state
    input logic i_prev_was_compressed_at_lo,  // Previous was compressed at lo

    // Control signals
    input logic i_prediction_holdoff,  // Stale cycle after RAS prediction
    input logic i_prediction_from_buffer_holdoff,  // Stale cycle after predicting from buffer

    // Stall handling.  Only the registered stall is taken, so the mux selects
    // stay off the combinational stall path.
    input logic i_stall_registered,
    input logic i_prev_was_compressed_at_lo_saved,
    input logic i_is_compressed_saved,  // Saved is_compressed from stall start
    input logic i_saved_values_valid,  // Saved values are valid (not invalidated by control flow)

    // Outputs
    output logic [15:0] o_raw_parcel,  // Raw 16-bit parcel for PD decompression
    output logic [31:0] o_effective_instr,  // pc_reg's word, from the buffer or the window
    output logic o_is_compressed,  // Current parcel is compressed
    output logic o_is_compressed_fast,  // Fast path for PC-critical path (registered selects only)
    output logic o_is_compressed_for_pc_advance,  // Size-only replica path to advance selector
    // For the served-window check: may a packet that does not use the buffer
    // take a window that ends at pc_reg's word? Always at a low-half PC; at a
    // high-half PC only if that parcel is compressed. IF applies the buffer
    // select in the coverage module's final buffer-arm mux.
    output logic o_no_buffer_accepts_served_last,
    output logic o_sel_nop,  // Outputting NOP
    output logic o_sel_compressed,  // Outputting decompressed instruction
    output logic o_use_instr_buffer,  // Using buffered instruction
    // Exact {rs2[1], rs1[2:1]} of the selected parcel's RVC expansion.
    output logic [2:0] o_rvc_source_hot,
    // Slot 1's RVC-expanded instruction bits [24:20], selected like
    // o_rvc_source_hot.
    output logic [4:0] o_rvc_bits24_20,
    // The rest of the selected parcel's predecoded expansion: {rs1[4:3],
    // rs1[0]}, and {illegal, bits [31:25], bits [14:0]}.
    output logic [2:0] o_rvc_rs1_rest,
    output logic [22:0] o_rvc_extra,

    // ===========================================================================
    // Slot-2 outputs for two-wide dispatch.
    // ===========================================================================
    // Slot-2 raw_parcel: 16-bit parcel (observation/replay; PD consumes the
    // pre-decompressed o_effective_instr_2 instead)
    output logic [15:0] o_raw_parcel_2,
    // Slot-2 effective 32-bit instruction: the RVC expansion when slot-2 is
    // compressed, or the native (possibly spanning-assembled) 32-bit word.
    output logic [31:0] o_effective_instr_2,
    // Slot-2 illegal-RVC flag for the selected candidate (PD masks with
    // sel_nop; 0 when slot-2 is a native 32-bit instruction).
    output logic o_slot2_decomp_illegal,
    // Slot-2 is compressed (RVC).
    output logic o_is_compressed_2,
    // No slot 2 this cycle: slot 1 is a NOP, control flow, or serializing; or
    // slot 2 extends past the next word, cannot start a pair, or would read a
    // stale next word. IF adds its own slot-1 NOP and pending-prediction
    // conditions before the packet reaches PD.
    output logic o_sel_nop_2,
    // Slot-2 compressed flag for the IF-to-PD packet (equals o_is_compressed_2).
    output logic o_sel_compressed_2,
    // Exact {rs2[1], rs1[2:1]} of the selected final instruction.  RVC
    // candidates use IMEM sideband metadata; native candidates use their
    // already-fixed instruction bits before the late position select.
    output logic [2:0] o_source_hot_2,
    // Slot 2's instruction bits [24:20] and {rs1[4:3], rs1[0]}, resolved like
    // o_source_hot_2.
    output logic [4:0] o_bits24_20_2,
    output logic [2:0] o_rs1_rest_2,
    // Early slot-2 metadata for the PC increment path.  This is equivalent to
    // the live, non-replay slot-2 decision below, but avoids routing the PC
    // path through the final IF->PD packet mux.
    output logic o_slot2_valid_for_pc,
    output logic o_slot2_is_compressed_for_pc,
    // Sizes of the slot-2 candidates at pc_reg + 2 and pc_reg + 4, for the
    // slot-2 BTB lookup's halfword size check. They depend only on pc_reg[1]
    // and the sideband, not on slot 1's size (which picks the real candidate),
    // so both candidates are checked in parallel.
    output logic o_slot2_is_compressed_plus2_for_btb,
    output logic o_slot2_is_compressed_plus4_for_btb,
    // Which slot-2 BTB lookup (pc_reg + 2 or pc_reg + 4) holds the real slot
    // 2, if any; at most one is set. Built from the same terms as
    // o_slot2_valid_for_pc.
    output logic o_slot2_plus2_candidate_valid,
    output logic o_slot2_plus4_candidate_valid,
    // Slot 1 is control flow (branch, JAL, JALR, or a compressed form). Bundles
    // end at control flow through the sideband's AllowsSlot2After bits, not
    // through this output.
    output logic o_slot1_is_branch,

    // Slot-2 kill-cause classification (not on the PC path). The native and
    // compressed slot-1 control bits also feed the frontend validity tracker;
    // all six feed profiling. Mutually exclusive; meaningful only on cycles
    // where slot-1 is real (!o_sel_nop) and slot-2 is killed (o_sel_nop_2).
    output logic o_slot2_kill_s1_native_ctrl,  // Slot-1 is native 32-bit control flow
    output logic o_slot2_kill_s1_native_serialize,  // Slot-1 is a native serializing-class op
    output logic o_slot2_kill_slot1_ctrl,  // Slot-1 is compressed control flow
    output logic o_slot2_kill_class,  // Slot-2 start is a serialize/FP-compute class op
    output logic o_slot2_kill_window_limit,  // 32-bit slot-2 at NEXT_HI, which never pairs
    output logic o_slot2_kill_transient  // Buffer/BRAM transient state
);

  // ===========================================================================
  // Instruction Buffer Selection
  // ===========================================================================
  // The buffer supplies the current word when the previous instruction was
  // compressed at lo and the PC is now at hi. Coming out of a stall, the saved
  // copy of prev_was_compressed_at_lo stands in for the live one.

  // The mux select uses registered signals only, to break the critical path
  // from stall_for_trap_check -> is_compressed -> PC.
  logic use_saved_prev;
  assign use_saved_prev = i_stall_registered && i_saved_values_valid;

  logic prev_was_compressed_at_lo_for_use;
  assign prev_was_compressed_at_lo_for_use = use_saved_prev ?
      i_prev_was_compressed_at_lo_saved : i_prev_was_compressed_at_lo;

  assign o_use_instr_buffer = prev_was_compressed_at_lo_for_use && i_pc_reg[1];

  // ===========================================================================
  // Current Word and Next Word Selection
  // ===========================================================================
  // The window is {word(F+1), word(F)}, where F is the registered fetch word
  // address. Normally F is pc_reg's word address W, but the fetch lead can
  // leave F one word off, depending on instruction mix and prediction timing.
  //
  // bank_sel_r (F[0]) against pc_reg[2] (W[0]) tells the halves apart:
  //   same parity: F = W; word(W) is i_instr[31:0], word(W+1) i_instr[63:32]
  //   different parity: the halves swap. Without the buffer this is taken as
  //     F = W-1, so word(W) is i_instr[63:32]; behind the buffer as F = W+1,
  //     so word(W+1) is i_instr[31:0].
  // In the other off-by-one case the served-window check NOPs the packet,
  // unless slot 1 is buffered at a low-half PC and needs nothing from the
  // window.
  //
  // When the instruction buffer is active, the buffer provides word(W)
  // directly and the window alignment doesn't matter for the current word.
  //
  // Each consumer group gets its own kept copy of the swap select.
  (* keep = "true", max_fanout = 16 *)logic fetch_word_swapped_word;
  (* keep = "true", max_fanout = 16 *)logic fetch_word_swapped_sideband;
  (* keep = "true", max_fanout = 16 *)logic fetch_word_swapped_fast;
  (* keep = "true", max_fanout = 16 *)logic fetch_word_swapped_slot2;
  assign fetch_word_swapped_word = i_instr_bank_sel_r ^ i_pc_reg[2];
  assign fetch_word_swapped_sideband = i_instr_bank_sel_r ^ i_pc_reg[2];
  assign fetch_word_swapped_fast = i_instr_bank_sel_r ^ i_pc_reg[2];
  assign fetch_word_swapped_slot2 = i_instr_bank_sel_r ^ i_pc_reg[2];

  logic [31:0] bram_current_word;  // Window word aligned to pc_reg
  assign bram_current_word = fetch_word_swapped_word ? i_instr[63:32] : i_instr[31:0];

  logic [31:0] current_word;
  assign current_word = o_use_instr_buffer ? i_instr_buffer : bram_current_word;

  // The C-extension state machine, the buffer capture, and IF's spanning
  // assembly all read this word.
  assign o_effective_instr = current_word;

  // ===========================================================================
  // Parcel Selection and Type Detection
  // ===========================================================================
  logic [15:0] current_parcel;
  assign current_parcel = i_pc_reg[1] ? current_word[31:16] : current_word[15:0];

  assign o_raw_parcel   = current_parcel;

  // ===========================================================================
  // is_compressed Detection - Predecode Sideband
  // ===========================================================================
  // The size bits come from the IMEM predecode sideband.  For buffered
  // instructions the sideband was captured when the buffer was written.
  // Sideband words align the same way as instruction words: the bus arrives as
  // {next_sb, current_sb}, and when fetch_word_swapped the "current" sideband
  // is in the upper sideband word.
  localparam int unsigned SbWidth = riscv_pkg::ImemSidebandWidth;

  logic [SbWidth-1:0] aligned_current_sb, aligned_next_sb;
  logic [SbWidth-1:0] aligned_current_sb_fast;
  logic [3:0] aligned_current_pc_metadata;
  logic [3:0] aligned_next_pc_metadata;
  logic [1:0] aligned_current_pc_pairability;
  logic selected_next_lo_start_valid;
  assign aligned_current_sb = fetch_word_swapped_sideband ?
                              i_instr_sideband[(2*SbWidth)-1:SbWidth] :
                              i_instr_sideband[SbWidth-1:0];
  assign aligned_next_sb    = fetch_word_swapped_sideband ?
                              i_instr_sideband[SbWidth-1:0] :
                              i_instr_sideband[(2*SbWidth)-1:SbWidth];
  assign aligned_current_sb_fast = fetch_word_swapped_fast ?
                                   i_instr_sideband[(2*SbWidth)-1:SbWidth] :
                                   i_instr_sideband[SbWidth-1:0];
  // With the lanes already in parity order, provider and pc_reg[2] are the
  // only selects, so each metadata bit maps to one LUT6 (four data lanes plus
  // two selects).
  always_comb begin
    unique case ({
      i_instr_pc_metadata_served_high, i_pc_reg[2]
    })
      2'b00: begin
        aligned_current_pc_metadata    = i_instr_pc_metadata_by_provider_parity[3:0];
        aligned_next_pc_metadata       = i_instr_pc_metadata_by_provider_parity[7:4];
        aligned_current_pc_pairability = i_pc_pairability_by_provider_parity[1:0];
        selected_next_lo_start_valid   = i_slot2_start_valid_lo_by_provider_parity[1];
      end
      2'b01: begin
        aligned_current_pc_metadata    = i_instr_pc_metadata_by_provider_parity[7:4];
        aligned_next_pc_metadata       = i_instr_pc_metadata_by_provider_parity[3:0];
        aligned_current_pc_pairability = i_pc_pairability_by_provider_parity[3:2];
        selected_next_lo_start_valid   = i_slot2_start_valid_lo_by_provider_parity[0];
      end
      2'b10: begin
        aligned_current_pc_metadata    = i_instr_pc_metadata_by_provider_parity[11:8];
        aligned_next_pc_metadata       = i_instr_pc_metadata_by_provider_parity[15:12];
        aligned_current_pc_pairability = i_pc_pairability_by_provider_parity[5:4];
        selected_next_lo_start_valid   = i_slot2_start_valid_lo_by_provider_parity[3];
      end
      2'b11: begin
        aligned_current_pc_metadata    = i_instr_pc_metadata_by_provider_parity[15:12];
        aligned_next_pc_metadata       = i_instr_pc_metadata_by_provider_parity[11:8];
        aligned_current_pc_pairability = i_pc_pairability_by_provider_parity[7:6];
        selected_next_lo_start_valid   = i_slot2_start_valid_lo_by_provider_parity[2];
      end
      default: begin
        aligned_current_pc_metadata    = 'x;
        aligned_next_pc_metadata       = 'x;
        aligned_current_pc_pairability = 'x;
        selected_next_lo_start_valid   = 1'bx;
      end
    endcase
  end

  logic is_comp_instr_lo, is_comp_instr_hi, is_comp_buf_lo, is_comp_buf_hi;
  logic is_comp_instr_lo_fast, is_comp_instr_hi_fast;
  logic is_comp_instr_lo_for_pc_advance, is_comp_instr_hi_for_pc_advance;
  assign is_comp_instr_lo = aligned_current_sb[riscv_pkg::ImemSbIsCompressedLo];
  assign is_comp_instr_hi = aligned_current_sb[riscv_pkg::ImemSbIsCompressedHi];
  assign is_comp_instr_lo_fast = aligned_current_sb_fast[riscv_pkg::ImemSbIsCompressedLo];
  assign is_comp_instr_hi_fast = aligned_current_sb_fast[riscv_pkg::ImemSbIsCompressedHi];
  assign is_comp_instr_lo_for_pc_advance = aligned_current_pc_metadata[0];
  assign is_comp_instr_hi_for_pc_advance = aligned_current_pc_metadata[1];
  assign is_comp_buf_lo = i_instr_buffer_sideband[riscv_pkg::ImemSbIsCompressedLo];
  assign is_comp_buf_hi = i_instr_buffer_sideband[riscv_pkg::ImemSbIsCompressedHi];

  logic [2:0] rvc_source_hot_instr_lo;
  logic [2:0] rvc_source_hot_instr_hi;
  logic [2:0] rvc_source_hot_next_lo;
  logic [2:0] rvc_source_hot_next_hi;
  logic [2:0] rvc_source_hot_buf_lo;
  logic [2:0] rvc_source_hot_buf_hi;
  assign rvc_source_hot_instr_lo = {
    aligned_current_sb[riscv_pkg::ImemSbRvcBits24To20LoLsb+1],
    aligned_current_sb[riscv_pkg::ImemSbRvcSourceHotLoLsb+:2]
  };
  assign rvc_source_hot_instr_hi = {
    aligned_current_sb[riscv_pkg::ImemSbRvcBits24To20HiLsb+1],
    aligned_current_sb[riscv_pkg::ImemSbRvcSourceHotHiLsb+:2]
  };
  assign rvc_source_hot_next_lo = {
    aligned_next_sb[riscv_pkg::ImemSbRvcBits24To20LoLsb+1],
    aligned_next_sb[riscv_pkg::ImemSbRvcSourceHotLoLsb+:2]
  };
  assign rvc_source_hot_next_hi = {
    aligned_next_sb[riscv_pkg::ImemSbRvcBits24To20HiLsb+1],
    aligned_next_sb[riscv_pkg::ImemSbRvcSourceHotHiLsb+:2]
  };
  assign rvc_source_hot_buf_lo = {
    i_instr_buffer_sideband[riscv_pkg::ImemSbRvcBits24To20LoLsb+1],
    i_instr_buffer_sideband[riscv_pkg::ImemSbRvcSourceHotLoLsb+:2]
  };
  assign rvc_source_hot_buf_hi = {
    i_instr_buffer_sideband[riscv_pkg::ImemSbRvcBits24To20HiLsb+1],
    i_instr_buffer_sideband[riscv_pkg::ImemSbRvcSourceHotHiLsb+:2]
  };

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

  // The selected parcel's predecoded fields, chosen by the same
  // {buffer, pc_reg[1]} select as the parcel. They come straight from the
  // registered sideband instead of being decoded from the selected parcel.
  always_comb begin
    unique case ({
      o_use_instr_buffer, i_pc_reg[1]
    })
      2'b00:   o_rvc_source_hot = rvc_source_hot_instr_lo;
      2'b01:   o_rvc_source_hot = rvc_source_hot_instr_hi;
      2'b10:   o_rvc_source_hot = rvc_source_hot_buf_lo;
      2'b11:   o_rvc_source_hot = rvc_source_hot_buf_hi;
      default: o_rvc_source_hot = 3'd0;
    endcase
  end

  always_comb begin
    unique case ({
      o_use_instr_buffer, i_pc_reg[1]
    })
      2'b00:   o_rvc_bits24_20 = aligned_current_sb[riscv_pkg::ImemSbRvcBits24To20LoLsb+:5];
      2'b01:   o_rvc_bits24_20 = aligned_current_sb[riscv_pkg::ImemSbRvcBits24To20HiLsb+:5];
      2'b10:   o_rvc_bits24_20 = i_instr_buffer_sideband[riscv_pkg::ImemSbRvcBits24To20LoLsb+:5];
      2'b11:   o_rvc_bits24_20 = i_instr_buffer_sideband[riscv_pkg::ImemSbRvcBits24To20HiLsb+:5];
      default: o_rvc_bits24_20 = 5'd0;
    endcase
  end

  always_comb begin
    unique case ({
      o_use_instr_buffer, i_pc_reg[1]
    })
      2'b00:   o_rvc_extra = aligned_current_sb[riscv_pkg::ImemSbRvcExtraLoLsb+:23];
      2'b01:   o_rvc_extra = aligned_current_sb[riscv_pkg::ImemSbRvcExtraHiLsb+:23];
      2'b10:   o_rvc_extra = i_instr_buffer_sideband[riscv_pkg::ImemSbRvcExtraLoLsb+:23];
      2'b11:   o_rvc_extra = i_instr_buffer_sideband[riscv_pkg::ImemSbRvcExtraHiLsb+:23];
      default: o_rvc_extra = 23'd0;
    endcase
  end

  always_comb begin
    unique case ({
      o_use_instr_buffer, i_pc_reg[1]
    })
      2'b00:   o_rvc_rs1_rest = aligned_current_sb[riscv_pkg::ImemSbRvcRs1RestLoLsb+:3];
      2'b01:   o_rvc_rs1_rest = aligned_current_sb[riscv_pkg::ImemSbRvcRs1RestHiLsb+:3];
      2'b10:   o_rvc_rs1_rest = i_instr_buffer_sideband[riscv_pkg::ImemSbRvcRs1RestLoLsb+:3];
      2'b11:   o_rvc_rs1_rest = i_instr_buffer_sideband[riscv_pkg::ImemSbRvcRs1RestHiLsb+:3];
      default: o_rvc_rs1_rest = 3'd0;
    endcase
  end

  // ===========================================================================
  // Fast is_compressed for PC-Critical Path
  // ===========================================================================
  // The selects come from registered inputs, so they resolve before the fetch
  // data arrives.
  logic use_saved_is_compressed;
  assign use_saved_is_compressed = i_stall_registered && i_saved_values_valid;

  logic prev_was_compressed_at_lo_fast;
  assign prev_was_compressed_at_lo_fast = i_stall_registered ?
      i_prev_was_compressed_at_lo_saved : i_prev_was_compressed_at_lo;

  // The size mux is Shannon-expanded on H = pc_reg[1]: the low- and
  // high-parcel results are built in parallel from early registered selects,
  // and the pc_reg[1] copy picks one with a final 2:1 select. Only the
  // high-parcel result can come from the buffer. This equals
  // need_buffer = prev & H followed by one saved/buffer/window mux (the
  // reference below), with need_buffer and a select level removed from the
  // pc_reg[1] -> served-window -> next-PC path.
  logic is_compressed_fast_low;
  logic is_compressed_fast_high;
  logic is_compressed_for_pc_advance_low;
  logic is_compressed_for_pc_advance_high;
  assign is_compressed_fast_low = use_saved_is_compressed ? i_is_compressed_saved :
      is_comp_instr_lo_fast;
  assign is_compressed_fast_high = use_saved_is_compressed ? i_is_compressed_saved :
      (prev_was_compressed_at_lo_fast ? is_comp_buf_hi : is_comp_instr_hi_fast);
  assign is_compressed_for_pc_advance_low =
      use_saved_is_compressed ? i_is_compressed_saved : is_comp_instr_lo_for_pc_advance;
  assign is_compressed_for_pc_advance_high =
      use_saved_is_compressed ? i_is_compressed_saved :
      (prev_was_compressed_at_lo_fast ? is_comp_buf_hi : is_comp_instr_hi_for_pc_advance);

  assign o_is_compressed_fast = i_pc_reg_high_for_coverage ?
      is_compressed_fast_high : is_compressed_fast_low;
  assign o_is_compressed_for_pc_advance = i_pc_reg_high_for_coverage ?
      is_compressed_for_pc_advance_high : is_compressed_for_pc_advance_low;
  // At a low-half PC slot 1 fits in a window whose last word is the PC word,
  // native or compressed; at a high-half PC only a compressed slot 1 does.
  // Writing that directly keeps low-parcel metadata out of the coverage path.
  assign o_no_buffer_accepts_served_last =
      !i_pc_reg_high_for_coverage || is_compressed_for_pc_advance_high;

`ifndef SYNTHESIS
  // Reference: the same selects without the Shannon expansion, checked
  // whenever the pc_reg[1] copy matches.
  logic need_buffer_fast_reference;
  logic is_compressed_fast_reference;
  logic is_compressed_for_pc_advance_reference;
  logic no_buffer_accepts_served_last_reference;
  assign need_buffer_fast_reference = prev_was_compressed_at_lo_fast && i_pc_reg[1];
  assign is_compressed_fast_reference = use_saved_is_compressed ? i_is_compressed_saved :
      (need_buffer_fast_reference ?
       (i_pc_reg[1] ? is_comp_buf_hi : is_comp_buf_lo) :
       (i_pc_reg[1] ? is_comp_instr_hi_fast : is_comp_instr_lo_fast));
  assign is_compressed_for_pc_advance_reference =
      use_saved_is_compressed ? i_is_compressed_saved :
      (need_buffer_fast_reference ?
       (i_pc_reg[1] ? is_comp_buf_hi : is_comp_buf_lo) :
       (i_pc_reg[1] ? is_comp_instr_hi_for_pc_advance :
                      is_comp_instr_lo_for_pc_advance));
  // Reference: select the size by H, then apply its one use. The low-parcel
  // size drops out: !H || (H ? C_hi : C_lo) is exactly !H || C_hi.
  assign no_buffer_accepts_served_last_reference =
      !i_pc_reg[1] ||
      (use_saved_is_compressed ? i_is_compressed_saved :
       (prev_was_compressed_at_lo_fast ? is_comp_buf_hi :
                                         is_comp_instr_hi_for_pc_advance));

  always_comb begin
    if (!$isunknown(
            {i_pc_reg[1],
             i_pc_reg_high_for_coverage,
             o_is_compressed_fast,
             o_is_compressed_for_pc_advance,
             o_no_buffer_accepts_served_last,
             is_compressed_fast_reference,
             is_compressed_for_pc_advance_reference,
             no_buffer_accepts_served_last_reference}
        ) && (i_pc_reg_high_for_coverage == i_pc_reg[1])) begin
      p_fast_size_shannon_expansion_exact :
      assert (o_is_compressed_fast == is_compressed_fast_reference);
      p_pc_advance_size_shannon_expansion_exact :
      assert (o_is_compressed_for_pc_advance == is_compressed_for_pc_advance_reference);
      p_no_buffer_accepts_served_last_exact :
      assert (o_no_buffer_accepts_served_last == no_buffer_accepts_served_last_reference);
    end
  end
`endif

  // ===========================================================================
  // Instruction Selection Signals
  // ===========================================================================
  // A spanning instruction is assembled in the same cycle, so only the holdoff
  // cases NOP slot 1 here. IF adds its other bubble conditions.
  assign o_sel_nop = i_prediction_holdoff || i_prediction_from_buffer_holdoff;

  // The size bit is not qualified with o_sel_nop: PD selects the final
  // instruction with the priority NOP > compressed > 32-bit.
  assign o_sel_compressed = o_is_compressed;

  // ===========================================================================
  // Slot-2 parcel selection.
  // ===========================================================================
  // The 64-bit fetch (i_instr) provides up to 4 halfwords of decoder data:
  //
  //   bram_current_word[15:0]  | bram_current_word[31:16]
  //   bram_next_word[15:0]     | bram_next_word[31:16]
  //
  // When use_instr_buffer is active, two halfwords from i_instr_buffer (the
  // previously-fetched word) replace bram_current_word for slot-1's parcel.
  // bram_current_word and bram_next_word still come from the fetch window.
  // Slot 2 starts right after slot 1 and must come from data already in hand
  // this cycle.
  //
  // The pair-shape table below maps (use_buffer, pc_reg[1],
  // slot-1 size) onto slot-2's start position within the same fetch:
  //
  //   !buf, !hi, RVC   -> slot-2 at current_word[31:16]   (CURRENT_HI)
  //   !buf, !hi, 32b   -> slot-2 at next_word[15:0]       (NEXT_LO)
  //   !buf,  hi, RVC   -> slot-2 at next_word[15:0]       (NEXT_LO)
  //   !buf,  hi, 32b   -> slot-2 at next_word[31:16]      (NEXT_HI)  span pair
  //    buf,  hi, RVC   -> slot-2 at next_word[15:0]       (NEXT_LO)
  //    buf,  hi, 32b   -> slot-2 at next_word[31:16]      (NEXT_HI)  span pair
  //
  // The buffer serves only a high-half pc_reg, so the (buf, !hi) cases do not
  // occur; the default arm marks slot 2 invalid for them.
  //
  // Slot-2 32-bit at NEXT_HI would end in word(W+2), so slot-2 is forced
  // invalid in that case (slot-2 RVC at NEXT_HI is fine). This holds even
  // behind the buffer when F = W+1 puts word(W+2) in the window.
  // ---------------------------------------------------------------------------
  localparam logic [1:0] Slot2AtCurrentHi = 2'd0;
  localparam logic [1:0] Slot2AtNextLo = 2'd1;
  localparam logic [1:0] Slot2AtNextHi = 2'd2;
  localparam logic [1:0] Slot2InvalidPos = 2'd3;

  // Next window word: the other 32 bits of i_instr, the half bram_current_word
  // does not select.  In the buffer case where fetch_word_swapped=1 this
  // resolves to word(W+1), the word after the buffer.
  logic [31:0] bram_next_word;
  assign bram_next_word = fetch_word_swapped_word ? i_instr[31:0] : i_instr[63:32];

  // Align the fast high-parcel predicates with the same fetch-lead correction
  // used for the two instruction words. The bus arrives as {next,current} for
  // the served fetch address; a parity mismatch swaps both word identities.
  logic aligned_current_hi_rd_is_x2;
  logic aligned_next_hi_rd_is_x2;
  assign aligned_current_hi_rd_is_x2 = fetch_word_swapped_slot2 ?
      i_instr_hi_rd_is_x2[1] : i_instr_hi_rd_is_x2[0];
  assign aligned_next_hi_rd_is_x2 = fetch_word_swapped_slot2 ?
      i_instr_hi_rd_is_x2[0] : i_instr_hi_rd_is_x2[1];

  logic [1:0] slot2_pos;
  always_comb begin
    unique case ({
      o_use_instr_buffer, i_pc_reg[1], o_is_compressed
    })
      3'b001:  slot2_pos = Slot2AtCurrentHi;  // !buf, !hi, RVC
      3'b000:  slot2_pos = Slot2AtNextLo;  // !buf, !hi, 32b
      3'b011:  slot2_pos = Slot2AtNextLo;  // !buf,  hi, RVC
      3'b010:  slot2_pos = Slot2AtNextHi;  // !buf,  hi, 32b (span pair)
      3'b111:  slot2_pos = Slot2AtNextLo;  //  buf,  hi, RVC
      3'b110:  slot2_pos = Slot2AtNextHi;  //  buf,  hi, 32b (span pair)
      default: slot2_pos = Slot2InvalidPos;  //  buf, !hi, * (does not occur)
    endcase
  end

  // Slot-2 raw 16-bit parcel.  PD reads o_effective_instr_2 instead; this copy
  // rides the packet for observation and replay.
  always_comb begin
    unique case (slot2_pos)
      Slot2AtCurrentHi: o_raw_parcel_2 = bram_current_word[31:16];
      Slot2AtNextLo:    o_raw_parcel_2 = bram_next_word[15:0];
      Slot2AtNextHi:    o_raw_parcel_2 = bram_next_word[31:16];
      default:          o_raw_parcel_2 = '0;
    endcase
  end

  // Slot-2 sideband-derived is_compressed.
  always_comb begin
    unique case (slot2_pos)
      Slot2AtCurrentHi: o_is_compressed_2 = aligned_current_sb[riscv_pkg::ImemSbIsCompressedHi];
      Slot2AtNextLo:    o_is_compressed_2 = aligned_next_sb[riscv_pkg::ImemSbIsCompressedLo];
      Slot2AtNextHi:    o_is_compressed_2 = aligned_next_sb[riscv_pkg::ImemSbIsCompressedHi];
      default:          o_is_compressed_2 = 1'b0;
    endcase
  end

  // A +2 slot 2 starts at CURRENT_HI when pc_reg[1] = 0 and at NEXT_LO when
  // pc_reg[1] = 1. A +4 slot 2 starts at NEXT_LO and NEXT_HI respectively.
  // Neither depends on slot-1 size, so the two BTB candidates run their size
  // checks in parallel.
  assign o_slot2_is_compressed_plus2_for_btb = i_pc_reg[1] ?
      aligned_next_sb[riscv_pkg::ImemSbIsCompressedLo] :
      aligned_current_sb[riscv_pkg::ImemSbIsCompressedHi];
  assign o_slot2_is_compressed_plus4_for_btb = i_pc_reg[1] ?
      aligned_next_sb[riscv_pkg::ImemSbIsCompressedHi] :
      aligned_next_sb[riscv_pkg::ImemSbIsCompressedLo];

  // Slot-2 effective 32-bit instruction, finished for each fixed candidate
  // position (RVC-expanded or native, chosen by the candidate's own sideband
  // compressed bit) so the late slot2_pos select is a single level. PD builds
  // slot 2's source fields from o_source_hot_2, o_bits24_20_2 and o_rs1_rest_2,
  // and in simulation checks bits [24:15] of this instruction against them.
  //
  // Per-candidate is-compressed uses the sideband bits, which are
  // bit-identical to the parcel encoding test: imem_make_sideband stores
  // parcel[1:0] != 2'b11 per halfword, for low BRAM and for L1I fills.
  // o_is_compressed_2 relies on the same equivalence.
  logic [31:0] slot2_decomp_cur_hi;
  logic [31:0] slot2_decomp_next_lo;
  logic [31:0] slot2_decomp_next_hi;
  logic slot2_decomp_cur_hi_bit8_fast;
  logic slot2_decomp_next_lo_bit8_fast;
  logic slot2_decomp_next_hi_bit8_fast;
  logic slot2_decomp_cur_hi_bit15_fast;
  logic slot2_decomp_next_lo_bit15_fast;
  logic slot2_decomp_next_hi_bit15_fast;
  logic [1:0] slot2_decomp_cur_hi_bits20_9_fast;
  logic [1:0] slot2_decomp_next_lo_bits20_9_fast;
  logic [1:0] slot2_decomp_next_hi_bits20_9_fast;
  logic [1:0] slot2_decomp_cur_hi_bits27_25_fast;
  logic [1:0] slot2_decomp_next_lo_bits27_25_fast;
  logic [1:0] slot2_decomp_next_hi_bits27_25_fast;
  logic slot2_raw_illegal_cur_hi;
  logic slot2_raw_illegal_cur_hi_reference;
  assign slot2_raw_illegal_cur_hi = aligned_current_sb[riscv_pkg::ImemSbRvcExtraHiLsb+22];
  logic slot2_raw_illegal_next_lo;
  logic slot2_raw_illegal_next_lo_reference;
  assign slot2_raw_illegal_next_lo = aligned_next_sb[riscv_pkg::ImemSbRvcExtraLoLsb+22];
  logic slot2_raw_illegal_next_hi;
  logic slot2_raw_illegal_next_hi_reference;
  assign slot2_raw_illegal_next_hi = aligned_next_sb[riscv_pkg::ImemSbRvcExtraHiLsb+22];

  rvc_decompressor u_slot2_decomp_cur_hi (
      .i_instr_compressed(bram_current_word[31:16]),
      .i_rd_is_x2(aligned_current_hi_rd_is_x2),
      .o_instr_expanded(slot2_decomp_cur_hi),
      .o_instr_expanded_bit8_fast(slot2_decomp_cur_hi_bit8_fast),
      .o_instr_expanded_bit15_fast(slot2_decomp_cur_hi_bit15_fast),
      .o_instr_expanded_bits20_9_fast(slot2_decomp_cur_hi_bits20_9_fast),
      .o_instr_expanded_bits27_25_fast(slot2_decomp_cur_hi_bits27_25_fast),
      .o_instr_expanded_bits31_28_fast(),
      .o_instr_expanded_bit26_fast(),
      .o_instr_expanded_bits19_18_fast(),
      .o_instr_expanded_bits14_12_fast(),
      .o_instr_expanded_bits24_20_fast(),
      .o_is_compressed(),
      .o_illegal(),
      .o_illegal_fast(slot2_raw_illegal_cur_hi_reference)
  );
  rvc_decompressor u_slot2_decomp_next_lo (
      .i_instr_compressed(bram_next_word[15:0]),
      .i_rd_is_x2(bram_next_word[11:7] == 5'd2),
      .o_instr_expanded(slot2_decomp_next_lo),
      .o_instr_expanded_bit8_fast(slot2_decomp_next_lo_bit8_fast),
      .o_instr_expanded_bit15_fast(slot2_decomp_next_lo_bit15_fast),
      .o_instr_expanded_bits20_9_fast(slot2_decomp_next_lo_bits20_9_fast),
      .o_instr_expanded_bits27_25_fast(slot2_decomp_next_lo_bits27_25_fast),
      .o_instr_expanded_bits31_28_fast(),
      .o_instr_expanded_bit26_fast(),
      .o_instr_expanded_bits19_18_fast(),
      .o_instr_expanded_bits14_12_fast(),
      .o_instr_expanded_bits24_20_fast(),
      .o_is_compressed(),
      .o_illegal(),
      .o_illegal_fast(slot2_raw_illegal_next_lo_reference)
  );
  rvc_decompressor u_slot2_decomp_next_hi (
      .i_instr_compressed(bram_next_word[31:16]),
      .i_rd_is_x2(aligned_next_hi_rd_is_x2),
      .o_instr_expanded(slot2_decomp_next_hi),
      .o_instr_expanded_bit8_fast(slot2_decomp_next_hi_bit8_fast),
      .o_instr_expanded_bit15_fast(slot2_decomp_next_hi_bit15_fast),
      .o_instr_expanded_bits20_9_fast(slot2_decomp_next_hi_bits20_9_fast),
      .o_instr_expanded_bits27_25_fast(slot2_decomp_next_hi_bits27_25_fast),
      .o_instr_expanded_bits31_28_fast(),
      .o_instr_expanded_bit26_fast(),
      .o_instr_expanded_bits19_18_fast(),
      .o_instr_expanded_bits14_12_fast(),
      .o_instr_expanded_bits24_20_fast(),
      .o_is_compressed(),
      .o_illegal(),
      .o_illegal_fast(slot2_raw_illegal_next_hi_reference)
  );

  // Per-candidate final instruction: the native word (assembled across both
  // words at CURRENT_HI), or for a compressed candidate the sideband's
  // predecoded expansion in bits [31:25] and [14:0] and the local
  // decompressor in bits [24:15], with bits 20 and 15 from its *_fast
  // outputs. A native NEXT_HI candidate would extend into word(W+2), so it
  // is a NOP and slot 2 is forced invalid below.
  logic [31:0] slot2_final_cur_hi;
  logic [31:0] slot2_final_next_lo;
  logic [31:0] slot2_final_next_hi;
  always_comb begin
    slot2_final_cur_hi = {bram_next_word[15:0], bram_current_word[31:16]};
    if (aligned_current_sb[riscv_pkg::ImemSbIsCompressedHi]) begin
      slot2_final_cur_hi = slot2_decomp_cur_hi;
      slot2_final_cur_hi[31:25] = aligned_current_sb[riscv_pkg::ImemSbRvcExtraHiLsb+15+:7];
      slot2_final_cur_hi[14:0] = aligned_current_sb[riscv_pkg::ImemSbRvcExtraHiLsb+:15];
      slot2_final_cur_hi[20] = slot2_decomp_cur_hi_bits20_9_fast[1];
      slot2_final_cur_hi[15] = slot2_decomp_cur_hi_bit15_fast;
    end
  end
  always_comb begin
    slot2_final_next_lo = bram_next_word;
    if (aligned_next_sb[riscv_pkg::ImemSbIsCompressedLo]) begin
      slot2_final_next_lo = slot2_decomp_next_lo;
      slot2_final_next_lo[31:25] = aligned_next_sb[riscv_pkg::ImemSbRvcExtraLoLsb+15+:7];
      slot2_final_next_lo[14:0] = aligned_next_sb[riscv_pkg::ImemSbRvcExtraLoLsb+:15];
      slot2_final_next_lo[20] = slot2_decomp_next_lo_bits20_9_fast[1];
      slot2_final_next_lo[15] = slot2_decomp_next_lo_bit15_fast;
    end
  end
  always_comb begin
    slot2_final_next_hi = riscv_pkg::NOP;
    if (aligned_next_sb[riscv_pkg::ImemSbIsCompressedHi]) begin
      slot2_final_next_hi = slot2_decomp_next_hi;
      slot2_final_next_hi[31:25] = aligned_next_sb[riscv_pkg::ImemSbRvcExtraHiLsb+15+:7];
      slot2_final_next_hi[14:0] = aligned_next_sb[riscv_pkg::ImemSbRvcExtraHiLsb+:15];
      slot2_final_next_hi[20] = slot2_decomp_next_hi_bits20_9_fast[1];
      slot2_final_next_hi[15] = slot2_decomp_next_hi_bit15_fast;
    end
  end

  // Resolve the three source-hot bits beside each fixed final-instruction
  // candidate, so the late slot2_pos mux is the only operation after
  // candidate selection.
  //
  // CURRENT_HI native is {next[15:0], current[31:16]}, so final bits
  // {21,17:16} are next-word bits {5,1:0}. NEXT_LO native is next_word.
  // NEXT_HI native is always invalid and its final instruction is NOP.
  logic [2:0] slot2_source_hot_cur_hi;
  logic [2:0] slot2_source_hot_next_lo;
  logic [2:0] slot2_source_hot_next_hi;
  assign slot2_source_hot_cur_hi = aligned_current_sb[riscv_pkg::ImemSbIsCompressedHi] ?
      rvc_source_hot_instr_hi : {bram_next_word[5], bram_next_word[1:0]};
  assign slot2_source_hot_next_lo = aligned_next_sb[riscv_pkg::ImemSbIsCompressedLo] ?
      rvc_source_hot_next_lo : {bram_next_word[21], bram_next_word[17:16]};
  assign slot2_source_hot_next_hi = aligned_next_sb[riscv_pkg::ImemSbIsCompressedHi] ?
      rvc_source_hot_next_hi : 3'd0;

  always_comb begin
    unique case (slot2_pos)
      Slot2AtCurrentHi: o_effective_instr_2 = slot2_final_cur_hi;
      Slot2AtNextLo:    o_effective_instr_2 = slot2_final_next_lo;
      Slot2AtNextHi:    o_effective_instr_2 = slot2_final_next_hi;
      default:          o_effective_instr_2 = riscv_pkg::NOP;
    endcase
  end

  // Bits [24:20] the same way: the sideband's RVC expansion or the native
  // candidate's own bits (CURRENT_HI native: next-word bits [8:4]).
  logic [4:0] slot2_bits24_20_cur_hi;
  logic [4:0] slot2_bits24_20_next_lo;
  logic [4:0] slot2_bits24_20_next_hi;
  assign slot2_bits24_20_cur_hi = aligned_current_sb[riscv_pkg::ImemSbIsCompressedHi] ?
      aligned_current_sb[riscv_pkg::ImemSbRvcBits24To20HiLsb+:5] : bram_next_word[8:4];
  assign slot2_bits24_20_next_lo = aligned_next_sb[riscv_pkg::ImemSbIsCompressedLo] ?
      aligned_next_sb[riscv_pkg::ImemSbRvcBits24To20LoLsb+:5] : bram_next_word[24:20];
  assign slot2_bits24_20_next_hi = aligned_next_sb[riscv_pkg::ImemSbIsCompressedHi] ?
      aligned_next_sb[riscv_pkg::ImemSbRvcBits24To20HiLsb+:5] : 5'd0;

  always_comb begin
    unique case (slot2_pos)
      Slot2AtCurrentHi: o_bits24_20_2 = slot2_bits24_20_cur_hi;
      Slot2AtNextLo:    o_bits24_20_2 = slot2_bits24_20_next_lo;
      Slot2AtNextHi:    o_bits24_20_2 = slot2_bits24_20_next_hi;
      default:          o_bits24_20_2 = 5'd0;
    endcase
  end

  // Remaining rs1 bits use the same candidate identity, before slot2_pos.
  logic [2:0] slot2_rs1_rest_cur_hi;
  logic [2:0] slot2_rs1_rest_next_lo;
  logic [2:0] slot2_rs1_rest_next_hi;
  assign slot2_rs1_rest_cur_hi = aligned_current_sb[riscv_pkg::ImemSbIsCompressedHi] ?
      aligned_current_sb[riscv_pkg::ImemSbRvcRs1RestHiLsb+:3] :
      {bram_next_word[3:2], bram_current_word[31]};
  assign slot2_rs1_rest_next_lo = aligned_next_sb[riscv_pkg::ImemSbIsCompressedLo] ?
      aligned_next_sb[riscv_pkg::ImemSbRvcRs1RestLoLsb+:3] :
      {bram_next_word[19:18], bram_next_word[15]};
  assign slot2_rs1_rest_next_hi = aligned_next_sb[riscv_pkg::ImemSbIsCompressedHi] ?
      aligned_next_sb[riscv_pkg::ImemSbRvcRs1RestHiLsb+:3] : 3'd0;

  always_comb begin
    unique case (slot2_pos)
      Slot2AtCurrentHi: o_rs1_rest_2 = slot2_rs1_rest_cur_hi;
      Slot2AtNextLo:    o_rs1_rest_2 = slot2_rs1_rest_next_lo;
      Slot2AtNextHi:    o_rs1_rest_2 = slot2_rs1_rest_next_hi;
      default:          o_rs1_rest_2 = 3'd0;
    endcase
  end

  always_comb begin
    unique case (slot2_pos)
      Slot2AtCurrentHi: o_source_hot_2 = slot2_source_hot_cur_hi;
      Slot2AtNextLo:    o_source_hot_2 = slot2_source_hot_next_lo;
      Slot2AtNextHi:    o_source_hot_2 = slot2_source_hot_next_hi;
      default:          o_source_hot_2 = 3'd0;
    endcase
  end

`ifndef SYNTHESIS
  // Reference: select the RVC sideband field by slot2_pos, then choose it or
  // the selected instruction's own bits by o_is_compressed_2. Both forms read
  // the same sideband size bits, so the checks hold without assuming that the
  // instruction words and the sideband agree.
  logic [2:0] slot2_rvc_source_hot_legacy;
  logic [2:0] slot2_source_hot_legacy;
  logic slot2_candidate_compressed_selected;
  always_comb begin
    unique case (slot2_pos)
      Slot2AtCurrentHi: slot2_rvc_source_hot_legacy = rvc_source_hot_instr_hi;
      Slot2AtNextLo:    slot2_rvc_source_hot_legacy = rvc_source_hot_next_lo;
      Slot2AtNextHi:    slot2_rvc_source_hot_legacy = rvc_source_hot_next_hi;
      default:          slot2_rvc_source_hot_legacy = 3'd0;
    endcase
  end
  assign slot2_source_hot_legacy = o_is_compressed_2 ?
      slot2_rvc_source_hot_legacy : {o_effective_instr_2[21], o_effective_instr_2[17:16]};
  // Same reference for bits [24:20]: the selected RVC sideband field, or the
  // selected native instruction's own bits.
  logic [4:0] slot2_rvc_bits24_20_legacy;
  logic [4:0] slot2_bits24_20_legacy;
  always_comb begin
    unique case (slot2_pos)
      Slot2AtCurrentHi:
      slot2_rvc_bits24_20_legacy = aligned_current_sb[riscv_pkg::ImemSbRvcBits24To20HiLsb+:5];
      Slot2AtNextLo:
      slot2_rvc_bits24_20_legacy = aligned_next_sb[riscv_pkg::ImemSbRvcBits24To20LoLsb+:5];
      Slot2AtNextHi:
      slot2_rvc_bits24_20_legacy = aligned_next_sb[riscv_pkg::ImemSbRvcBits24To20HiLsb+:5];
      default: slot2_rvc_bits24_20_legacy = 5'd0;
    endcase
  end
  assign slot2_bits24_20_legacy = o_is_compressed_2 ?
      slot2_rvc_bits24_20_legacy : o_effective_instr_2[24:20];
  assign slot2_candidate_compressed_selected = o_is_compressed ?
      o_slot2_is_compressed_plus2_for_btb : o_slot2_is_compressed_plus4_for_btb;

  always_comb begin
    if (!$isunknown({o_source_hot_2, slot2_source_hot_legacy})) begin
      p_slot2_source_hot_matches_legacy : assert (o_source_hot_2 == slot2_source_hot_legacy);
    end
    if (!$isunknown({o_bits24_20_2, slot2_bits24_20_legacy})) begin
      p_slot2_bits24_20_matches_legacy : assert (o_bits24_20_2 == slot2_bits24_20_legacy);
    end
    if ((slot2_pos != Slot2InvalidPos) && !$isunknown(
            {o_is_compressed_2, slot2_candidate_compressed_selected}
        )) begin
      p_slot2_candidate_size_matches_selected :
      assert (o_is_compressed_2 == slot2_candidate_compressed_selected);
    end
  end
`endif

  // Slot-2 illegal-RVC flag: the selected candidate's predecoded illegal bit,
  // gated by its sideband compressed bit. PD masks it with sel_nop.
  always_comb begin
    unique case (slot2_pos)
      Slot2AtCurrentHi:
      o_slot2_decomp_illegal = aligned_current_sb[riscv_pkg::ImemSbIsCompressedHi] &&
          slot2_raw_illegal_cur_hi;
      Slot2AtNextLo:
      o_slot2_decomp_illegal = aligned_next_sb[riscv_pkg::ImemSbIsCompressedLo] &&
          slot2_raw_illegal_next_lo;
      Slot2AtNextHi:
      o_slot2_decomp_illegal = aligned_next_sb[riscv_pkg::ImemSbIsCompressedHi] &&
          slot2_raw_illegal_next_hi;
      default: o_slot2_decomp_illegal = 1'b0;
    endcase
  end

  // Slot-1 control-flow detection for o_slot1_is_branch. Matches riscv_pkg's
  // imem_native_control and imem_compressed_control classes, applied to the
  // selected raw parcel and word.
  logic [2:0] s1_c_funct3;
  logic [3:0] s1_c_funct4;
  logic [4:0] s1_c_rs1;
  logic [4:0] s1_c_rs2;
  logic [1:0] s1_c_op;
  assign s1_c_funct3 = o_raw_parcel[15:13];
  assign s1_c_funct4 = o_raw_parcel[15:12];
  assign s1_c_rs1    = o_raw_parcel[11:7];
  assign s1_c_rs2    = o_raw_parcel[6:2];
  assign s1_c_op     = o_raw_parcel[1:0];

  logic slot1_branch_native;
  logic slot1_branch_compressed;
  // A native slot 1 at pc_reg[1]=1 spans two words, and its opcode is in the
  // upper half of the current word (o_effective_instr[22:16]); otherwise it is
  // o_effective_instr[6:0].
  logic [6:0] slot1_native_opcode;
  assign slot1_native_opcode = i_pc_reg[1] ? o_effective_instr[22:16] : o_effective_instr[6:0];
  assign slot1_branch_native =
      (slot1_native_opcode == riscv_pkg::OPC_BRANCH) ||
      (slot1_native_opcode == riscv_pkg::OPC_JAL) ||
      (slot1_native_opcode == riscv_pkg::OPC_JALR);
  assign slot1_branch_compressed = ((s1_c_op == 2'b01) && ((s1_c_funct3 == 3'b101) ||  // C.J
      (s1_c_funct3 == 3'b110) ||  // C.BEQZ
      (s1_c_funct3 == 3'b111))) ||  // C.BNEZ
      ((s1_c_op == 2'b10) &&
       (s1_c_rs2 == 5'b00000) &&
       (s1_c_rs1 != 5'b00000) &&
       ((s1_c_funct4 == 4'b1000) ||  // C.JR
      (s1_c_funct4 == 4'b1001)));  // C.JALR
  logic slot1_branch_any;
  assign slot1_branch_any  = o_is_compressed ? slot1_branch_compressed : slot1_branch_native;
  assign o_slot1_is_branch = !o_sel_nop && slot1_branch_any;

  // Slot 2 is invalid when slot 1 is a bubble, control flow, or serializing;
  // when slot 2 extends past the next word or cannot start a pair; or when it
  // needs a next word that the window does not hold.
  //
  // Only a compressed CURRENT_HI slot 2 lies wholly in pc_reg's word W. Every
  // other shape reads bram_next_word, which is word(W+1) when the parities
  // match (F = W) or, behind the buffer, when they differ (F = W+1). Without
  // the buffer, different parity means F = W-1 and bram_next_word is
  // word(W-1): slot2_bram_unsafe. The served-window check NOPs that packet
  // when slot 1 itself needs word(W+1) (a native slot 1 at the high half);
  // otherwise slot 1 still goes out one-wide, and this gate keeps slot 2 off
  // the stale word.
  logic slot2_bram_unsafe;
  assign slot2_bram_unsafe = !o_use_instr_buffer && fetch_word_swapped_slot2;
  // Slot 1 leads a pair only when its AllowsSlot2After bit is set: it is
  // neither control flow nor a native serializing instruction (SYSTEM,
  // MISC-MEM, or AMO opcode). A CSR instruction broadcasts only its write
  // operand on the CDB; the value it reads reaches the register file through
  // the delayed writeback at commit, and younger instructions are held out of
  // dispatch until then. A slot-2 partner would slip past that hold.
  //
  // Slot 2 starts a pair only when its Slot2StartValid bit is set. That
  // excludes native serializing instructions, which retire alone at the ROB
  // head, and FP compute (OP-FP and the fused multiply-adds; see
  // riscv_pkg::imem_native_fp_compute), which stays out of slot 2 to keep FP
  // reservation-station back-pressure off the slot-1 dispatch path. The PC
  // then advances past slot 1 only, and the FP instruction comes back as the
  // next slot 1. Stores and branches may be slot 2: the store early-address
  // pipeline serves both dispatch slots, and the slot-2 BTB lookup predicts
  // slot-2 branches.
  //
  // For the PC path the sideband precombines slot 1's size and
  // AllowsSlot2After for each shape (PairableNativeLo, PairableCompressedHi,
  // PairableNativeHi, and EvenLocalPairValid, which also includes the
  // CURRENT_HI start validity because that start is in the same word). The
  // slot-2 start's size or start validity, and slot2_bram_unsafe, join below.
  //
  // slot1_allows_slot2_for_pc and slot1_compressed_for_pc select slot 1's own
  // AllowsSlot2After and size bits. Despite the names, only the kill-cause
  // classification reads them.
  logic slot1_allows_slot2_for_pc;
  always_comb begin
    unique case ({
      o_use_instr_buffer, i_pc_reg[1]
    })
      2'b00: slot1_allows_slot2_for_pc = aligned_current_sb[riscv_pkg::ImemSbAllowsSlot2AfterLo];
      2'b01: slot1_allows_slot2_for_pc = aligned_current_sb[riscv_pkg::ImemSbAllowsSlot2AfterHi];
      2'b10:
      slot1_allows_slot2_for_pc = i_instr_buffer_sideband[riscv_pkg::ImemSbAllowsSlot2AfterLo];
      2'b11:
      slot1_allows_slot2_for_pc = i_instr_buffer_sideband[riscv_pkg::ImemSbAllowsSlot2AfterHi];
      default: slot1_allows_slot2_for_pc = 1'b0;
    endcase
  end

  // Slot-1 size, by the same select as o_is_compressed.
  logic slot1_compressed_for_pc;
  always_comb begin
    unique case ({
      o_use_instr_buffer, i_pc_reg[1]
    })
      2'b00:   slot1_compressed_for_pc = aligned_current_sb[riscv_pkg::ImemSbIsCompressedLo];
      2'b01:   slot1_compressed_for_pc = aligned_current_sb[riscv_pkg::ImemSbIsCompressedHi];
      2'b10:   slot1_compressed_for_pc = i_instr_buffer_sideband[riscv_pkg::ImemSbIsCompressedLo];
      2'b11:   slot1_compressed_for_pc = i_instr_buffer_sideband[riscv_pkg::ImemSbIsCompressedHi];
      default: slot1_compressed_for_pc = 1'b0;
    endcase
  end

  // High-half slot-1 shape qualifiers from whichever word supplies slot-1.
  // Live provider words use the timing metadata replicas; buffered
  // instructions use the sideband captured in the instruction-buffer register.
  // The buffer serves only a high-half slot 1, so the low-half candidates
  // below read only the window's bits.
  logic slot1_pairable_compressed_hi_for_pc;
  logic slot1_pairable_native_hi_for_pc;
  assign slot1_pairable_compressed_hi_for_pc = o_use_instr_buffer ?
      i_instr_buffer_sideband[riscv_pkg::ImemSbPairableCompressedHi] :
      aligned_current_pc_metadata[2];
  assign slot1_pairable_native_hi_for_pc = o_use_instr_buffer ?
      i_instr_buffer_sideband[riscv_pkg::ImemSbPairableNativeHi] :
      aligned_current_pc_metadata[3];

  // Shape candidates for the kill-cause classification below. They leave out
  // slot-2 start validity, so a blocked slot 2 is classified by its cause
  // instead of falling into the no-pair bucket.
  logic slot2_current_hi_candidate;
  logic slot2_next_lo_candidate;
  logic slot2_next_hi_candidate;
  // RVC slot-1 at lo: slot-2 at CURRENT_HI.
  assign slot2_current_hi_candidate = !o_sel_nop && !o_use_instr_buffer && !i_pc_reg[1] &&
                                      aligned_current_sb[riscv_pkg::ImemSbAllowsSlot2AfterLo] &&
                                      aligned_current_sb[riscv_pkg::ImemSbIsCompressedLo];
  // NEXT_LO from either shape: 32b slot-1 at lo, or RVC slot-1 at hi
  // (buffered or not).
  assign slot2_next_lo_candidate =
      (!o_sel_nop && !o_use_instr_buffer && !i_pc_reg[1] &&
       aligned_current_sb[riscv_pkg::ImemSbAllowsSlot2AfterLo] &&
       !aligned_current_sb[riscv_pkg::ImemSbIsCompressedLo]) ||
      (!o_sel_nop && i_pc_reg[1] && slot1_allows_slot2_for_pc && slot1_compressed_for_pc);
  // 32b slot-1 at hi: slot-2 at NEXT_HI (RVC slot-2 only).
  assign slot2_next_hi_candidate = !o_sel_nop && i_pc_reg[1] && slot1_allows_slot2_for_pc &&
                                   !slot1_compressed_for_pc;

  // Shape candidates for packet validity and PC advance, from the precombined
  // pairing bits. The slot-2 terms that this word cannot supply join below.
  logic slot2_current_hi_candidate_for_pc;
  logic slot2_next_lo_candidate_for_pc;
  logic slot2_next_hi_candidate_for_pc;
  assign slot2_current_hi_candidate_for_pc =
      !o_sel_nop && !o_use_instr_buffer && !i_pc_reg[1] &&
      aligned_current_pc_pairability[0];
  assign slot2_next_lo_candidate_for_pc =
      (!o_sel_nop && !o_use_instr_buffer && !i_pc_reg[1] &&
       aligned_current_pc_pairability[1]) ||
      (!o_sel_nop && i_pc_reg[1] && slot1_pairable_compressed_hi_for_pc);
  assign slot2_next_hi_candidate_for_pc =
      !o_sel_nop && i_pc_reg[1] && slot1_pairable_native_hi_for_pc;

  logic slot2_current_hi_compressed;
  logic slot2_next_lo_compressed;
  logic slot2_next_hi_compressed;
  logic slot2_current_hi_compressed_for_pc_advance;
  logic slot2_next_lo_compressed_for_pc_advance;
  logic slot2_next_hi_compressed_for_pc_advance;
  logic slot2_current_hi_start_valid;
  logic slot2_next_lo_start_valid;
  logic slot2_next_hi_start_valid;
  assign slot2_current_hi_compressed = aligned_current_sb[riscv_pkg::ImemSbIsCompressedHi];
  assign slot2_next_lo_compressed = aligned_next_sb[riscv_pkg::ImemSbIsCompressedLo];
  assign slot2_next_hi_compressed = aligned_next_sb[riscv_pkg::ImemSbIsCompressedHi];
  assign slot2_current_hi_compressed_for_pc_advance = aligned_current_pc_metadata[1];
  assign slot2_next_lo_compressed_for_pc_advance = aligned_next_pc_metadata[0];
  assign slot2_next_hi_compressed_for_pc_advance = aligned_next_pc_metadata[1];
  assign slot2_current_hi_start_valid = aligned_current_sb[riscv_pkg::ImemSbSlot2StartValidHi];
  assign slot2_next_lo_start_valid = selected_next_lo_start_valid;
  assign slot2_next_hi_start_valid = aligned_next_sb[riscv_pkg::ImemSbSlot2StartValidHi];

  logic slot2_current_hi_invalid;
  logic slot2_next_lo_invalid;
  logic slot2_next_hi_invalid;
  logic slot2_current_hi_invalid_for_pc_advance;
  logic slot2_next_hi_invalid_for_pc_advance;
  // EvenLocalPairValid already includes current-hi start validity.  A native
  // CURRENT_HI slot-2 still needs the next BRAM word to assemble its upper
  // half, whereas a compressed one is wholly local.
  assign slot2_current_hi_invalid = slot2_bram_unsafe && !slot2_current_hi_compressed;
  assign slot2_next_lo_invalid = slot2_bram_unsafe || !slot2_next_lo_start_valid;
  // A compressed NEXT_HI start is intrinsically start-valid.  Native NEXT_HI
  // would end in word(W+2) and is always invalid.
  assign slot2_next_hi_invalid = slot2_bram_unsafe || !slot2_next_hi_compressed;
  assign slot2_current_hi_invalid_for_pc_advance =
      slot2_bram_unsafe && !slot2_current_hi_compressed_for_pc_advance;
  assign slot2_next_hi_invalid_for_pc_advance =
      slot2_bram_unsafe || !slot2_next_hi_compressed_for_pc_advance;

  logic slot2_current_hi_valid_for_pc;
  logic slot2_next_lo_valid_for_pc;
  logic slot2_next_hi_valid_for_pc;
  assign slot2_current_hi_valid_for_pc =
      slot2_current_hi_candidate_for_pc && !slot2_current_hi_invalid;
  assign slot2_next_lo_valid_for_pc = slot2_next_lo_candidate_for_pc && !slot2_next_lo_invalid;
  assign slot2_next_hi_valid_for_pc = slot2_next_hi_candidate_for_pc && !slot2_next_hi_invalid;

  logic slot2_valid_when_enabled;
  assign slot2_valid_when_enabled = slot2_current_hi_valid_for_pc ||
      slot2_next_lo_valid_for_pc || slot2_next_hi_valid_for_pc;
  logic slot2_current_hi_valid_for_pc_advance;
  logic slot2_next_hi_valid_for_pc_advance;
  logic slot2_valid_for_pc_advance;
  assign slot2_current_hi_valid_for_pc_advance =
      slot2_current_hi_candidate_for_pc && !slot2_current_hi_invalid_for_pc_advance;
  assign slot2_next_hi_valid_for_pc_advance =
      slot2_next_hi_candidate_for_pc && !slot2_next_hi_invalid_for_pc_advance;
  // Which of pc_reg + 2 and pc_reg + 4 is slot 2, from the qualified shape
  // arms that PC advance also uses. NEXT_LO is +4 behind a native slot 1 at
  // lo and +2 behind a compressed slot 1 at hi; CURRENT_HI is always +2 and
  // NEXT_HI always +4.
  assign o_slot2_plus2_candidate_valid = slot2_current_hi_valid_for_pc_advance ||
      (i_pc_reg[1] && slot2_next_lo_valid_for_pc);
  assign o_slot2_plus4_candidate_valid = slot2_next_hi_valid_for_pc_advance ||
      (!i_pc_reg[1] && slot2_next_lo_valid_for_pc);
  assign slot2_valid_for_pc_advance = slot2_current_hi_valid_for_pc_advance ||
      slot2_next_lo_valid_for_pc || slot2_next_hi_valid_for_pc_advance;
  assign o_slot2_valid_for_pc = slot2_valid_for_pc_advance;

`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown({o_slot2_plus2_candidate_valid, o_slot2_plus4_candidate_valid})) begin
      p_slot2_candidates_are_onehot :
      assert ($onehot0({o_slot2_plus4_candidate_valid, o_slot2_plus2_candidate_valid}));
    end
  end
`endif

  // Consumers only inspect the compression bit when slot-2 is valid.  Keep the
  // valid predicate out of this high-fanout select so the sideband "allows
  // slot-2" bit does not also drive the slot-2-size mux cone.  The candidates
  // are mutually exclusive by construction (pc_reg[1], slot-1 size).
  assign o_slot2_is_compressed_for_pc =
      slot2_current_hi_candidate_for_pc ? slot2_current_hi_compressed_for_pc_advance :
      slot2_next_hi_candidate_for_pc    ? slot2_next_hi_compressed_for_pc_advance    :
                                           slot2_next_lo_compressed_for_pc_advance;

  logic slot2_sel_nop_when_enabled;
  assign slot2_sel_nop_when_enabled = !slot2_valid_when_enabled;
  // This is the live pairing decision only. if_stage also NOPs slot 2
  // whenever its full slot-1 sel_nop is set (for example the control-flow,
  // pending-prediction, and reset holdoffs and flushes, none of which are in
  // this module's o_sel_nop) and when the bundle holds a pending prediction's
  // branch, which must go out one-wide as slot 1. pc_controller and c_ext_state
  // take if_stage's replay-aware slot-2 valid, not this output, so PC advance,
  // buffer state, and dispatch agree on slot 2 during stall replay.
  assign o_sel_nop_2 = slot2_sel_nop_when_enabled;

  // Slot-2 sel_compressed: mirror slot-1.
  assign o_sel_compressed_2 = o_is_compressed_2;

  // ===========================================================================
  // Slot-2 Kill-Cause Classification
  // ===========================================================================
  // Taps off existing nets for the width-funnel perf counters; the native and
  // compressed slot-1 control taps also classify control flow for the frontend
  // validity tracker. Nothing here feeds the PC or packet paths. Priority makes
  // the causes mutually exclusive, highest first:
  //   1. native slot 1 is control flow or serializing (split by its
  //      NativeSerialize bit)
  //   2. compressed slot 1 is control flow
  //   3. slot 2 cannot start a pair (Slot2StartValid = 0: a native SYSTEM,
  //      MISC-MEM, AMO, or FP-compute instruction)
  //   4. a start-valid native slot 2 at NEXT_HI, which never pairs (a fixed
  //      limit, not a transient)
  //   5. transient: slot2_bram_unsafe
  // When slot 2 is valid, all six outputs are 0 by construction.
  logic slot2_kill_start_invalid;
  assign slot2_kill_start_invalid =
      slot2_current_hi_candidate ? !slot2_current_hi_start_valid :
      slot2_next_lo_candidate    ? !slot2_next_lo_start_valid    :
      slot2_next_hi_candidate    ? !slot2_next_hi_start_valid    : 1'b0;

  // Slot-1's NativeSerialize sideband bit, muxed like slot1_allows_slot2_for_pc.
  //
  // The keep here and on slot2_next_hi_native32 below holds these two taps
  // out of the sideband and slot-2 select logic. Without it, synthesis merges
  // them into that logic and restructures the instruction-memory-to-fetch-PC
  // path, making it slower. Each keep costs one LUT.
  (* keep = "true" *) logic slot1_native_serialize_for_pc;
  always_comb begin
    unique case ({
      o_use_instr_buffer, i_pc_reg[1]
    })
      2'b00: slot1_native_serialize_for_pc = aligned_current_sb[riscv_pkg::ImemSbNativeSerializeLo];
      2'b01: slot1_native_serialize_for_pc = aligned_current_sb[riscv_pkg::ImemSbNativeSerializeHi];
      2'b10:
      slot1_native_serialize_for_pc = i_instr_buffer_sideband[riscv_pkg::ImemSbNativeSerializeLo];
      2'b11:
      slot1_native_serialize_for_pc = i_instr_buffer_sideband[riscv_pkg::ImemSbNativeSerializeHi];
      default: slot1_native_serialize_for_pc = 1'b0;
    endcase
  end

  // For a native slot 1, !allows means control flow or serializing; the
  // NativeSerialize bit splits the two (they are disjoint opcode classes).
  assign o_slot2_kill_s1_native_ctrl = !slot1_allows_slot2_for_pc && !o_is_compressed &&
                                       !slot1_native_serialize_for_pc;
  assign o_slot2_kill_s1_native_serialize = !slot1_allows_slot2_for_pc && !o_is_compressed &&
                                            slot1_native_serialize_for_pc;
  assign o_slot2_kill_slot1_ctrl = !slot1_allows_slot2_for_pc && o_is_compressed;
  assign o_slot2_kill_class = slot1_allows_slot2_for_pc && slot2_kill_start_invalid;

  // The remaining no-pair cases, split in two. A native slot 2 at NEXT_HI
  // (behind a 32b slot-1 at hi) never pairs, whatever the fetch state, since
  // the NEXT_HI candidate is RVC-only. The rest are transient parity-unsafe
  // reads.
  logic slot2_kill_no_pair;
  // Keep-pinned for the same reason as slot1_native_serialize_for_pc.
  (* keep = "true" *)logic slot2_next_hi_native32;
  assign slot2_kill_no_pair = slot1_allows_slot2_for_pc && !slot2_kill_start_invalid &&
                              !slot2_valid_when_enabled;
  assign slot2_next_hi_native32 = slot2_next_hi_candidate && !slot2_next_hi_compressed;
  assign o_slot2_kill_window_limit = slot2_kill_no_pair && slot2_next_hi_native32;
  assign o_slot2_kill_transient = slot2_kill_no_pair && !slot2_next_hi_native32;

endmodule : instruction_aligner
