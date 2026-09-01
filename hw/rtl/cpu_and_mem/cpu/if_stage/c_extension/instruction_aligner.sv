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
  RISC-V C-extension alignment and parcel selection for a 64-bit fetch window.
  Selects the raw slot-1 parcel, assembles spanning native instructions, and
  produces the optional pre-decompressed slot-2 instruction and metadata.
  With two consecutive 32-bit words per cycle, a 32-bit instruction at a halfword boundary
  (PC[1]=1) is assembled combinationally from the two words in a single cycle.

  Slot 1 remains raw and is decompressed in PD. Slot 2 is
  decompressed here from fixed candidate parcels before the late position mux,
  avoiding a serial parcel-mux/decompress/mux path into the pipeline register.
  The module is combinational.
*/
module instruction_aligner #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    // 64-bit instruction fetch: {next_word[31:0], current_word[31:0]}
    input logic [63:0] i_instr,
    input logic [riscv_pkg::ImemFetchSidebandWidth-1:0] i_instr_sideband,
    // Raw PC/bundle-shape timing replicas in physical provider/parity order:
    // {cached odd[3:0], cached even[3:0], BRAM odd[3:0], BRAM even[3:0]}.
    // Each nibble is {pairable_native_hi, pairable_compressed_hi,
    // compressed_hi, compressed_lo}.  BRAM arrives without a positional swap;
    // the cached lanes are reconstructed upstream after their bank mux.
    input logic [15:0] i_instr_pc_metadata_by_provider_parity,
    input logic [7:0] i_pc_pairability_by_provider_parity,
    input logic [3:0] i_slot2_start_valid_lo_by_provider_parity,
    input logic i_instr_pc_metadata_served_high,
    // Ordered like i_instr: {next-word high-parcel rd==x2,
    // current-word high-parcel rd==x2}.
    input logic [1:0] i_instr_hi_rd_is_x2,
    input logic i_instr_bank_sel_r,  // Registered fetch-word parity (PC[2] from BRAM cycle)
    input logic [31:0] i_instr_buffer,  // Buffered instruction word
    input logic [riscv_pkg::ImemSidebandWidth-1:0] i_instr_buffer_sideband,
    input logic [XLEN-1:0] i_pc_reg,  // Registered PC

    // C-extension state
    input logic i_prev_was_compressed_at_lo,  // Previous was compressed at lo
    // Canonical architectural buffer select and its F=0,H=0,R=0 timing
    // cofactor. The latter may differ only while IF independently squashes
    // size-driven PC/prediction consumers.
    input logic i_use_buffer_after_prediction,
    input logic i_use_buffer_after_prediction_timing,

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
    output logic o_is_compressed_for_pc_advance,  // Size-only replica path to advance selector
    output logic o_sel_nop,  // Outputting NOP
    output logic o_sel_compressed,  // Outputting decompressed instruction
    output logic o_use_instr_buffer,  // Using buffered instruction
    // Exact {rs2[1], rs1[2:1]} of the selected parcel's RVC expansion.
    output logic [2:0] o_rvc_source_hot,

    // ===========================================================================
    // Slot-2 outputs for two-wide dispatch.
    // ===========================================================================
    // Slot-2 raw_parcel: 16-bit parcel (observation/replay; PD consumes the
    // pre-decompressed o_effective_instr_2 instead)
    output logic [15:0] o_raw_parcel_2,
    // Slot-2 effective 32-bit instruction: the fully-formed instruction for
    // BOTH cases — the RVC expansion when slot-2 is compressed, or the
    // native (possibly spanning-assembled) 32-bit word.
    output logic [31:0] o_effective_instr_2,
    // Slot-2 illegal-RVC flag for the selected candidate (PD masks with
    // sel_nop; 0 when slot-2 is a native 32-bit instruction).
    output logic o_slot2_decomp_illegal,
    // Slot-2 is compressed (RVC).
    output logic o_is_compressed_2,
    // Slot-2 is invalid this cycle (NOP through PD).  Asserted when slot-1 is
    // a NOP, when slot-1 is a branch (decision #1), when slot-2 doesn't fit
    // in the current 64-bit fetch, or when the buffer is in an unsupported
    // state for slot-2.
    output logic o_sel_nop_2,
    // Slot-2 RVC select for PD's instruction-mux (mirror of slot-1).
    output logic o_sel_compressed_2,
    // Exact {rs2[1], rs1[2:1]} of the selected final instruction.  RVC
    // candidates use IMEM sideband metadata; native candidates use their
    // already-fixed instruction bits before the late position select.
    output logic [2:0] o_source_hot_2,
    // Early slot-2 metadata for the PC increment path.  This is equivalent to
    // the live, non-replay slot-2 decision below, but avoids routing the PC
    // path through the final IF->PD packet mux.
    output logic o_slot2_valid_for_pc,
    output logic o_slot2_is_compressed_for_pc,
    // Fixed +2/+4 candidate sizes for parallel BTB safety qualification.
    // These depend on PC position and aligned sideband only, not on the late
    // slot-1-size choice that selects which candidate is architectural.
    output logic o_slot2_is_compressed_plus2_for_btb,
    output logic o_slot2_is_compressed_plus4_for_btb,
    // One-hot canonical candidate identity for the +2/+4 BTB images.
    // These remain aligned with packet validity and PC advance.
    output logic o_slot2_plus2_candidate_valid,
    output logic o_slot2_plus4_candidate_valid,
    // Exact F=0,H=0,R=0 timing companions used only by BPC. IF proves that
    // they equal the canonical pair whenever a live slot-2 lookup is valid.
    output logic o_slot2_plus2_candidate_valid_timing,
    output logic o_slot2_plus4_candidate_valid_timing,
    // Slot-1 is a branch (BRANCH/JAL/JALR or compressed equivalent).  Used by
    // pc_controller to terminate the bundle and by upstream consumers (e.g.,
    // c_ext_state) that need to know the bundle terminated early.
    output logic o_slot1_is_branch,

    // Slot-2 kill-cause classification (profiling taps only; not on the PC
    // path).  Mutually exclusive; meaningful only on cycles where slot-1 is
    // real (!o_sel_nop) and slot-2 is killed (o_sel_nop_2).
    output logic o_slot2_kill_s1_native_ctrl,  // Slot-1 is native 32-bit control flow
    output logic o_slot2_kill_s1_native_serialize,  // Slot-1 is a native serializing-class op
    output logic o_slot2_kill_slot1_ctrl,  // Slot-1 is compressed control flow
    output logic o_slot2_kill_class,  // Slot-2 start is a serialize/FP-compute class op
    output logic o_slot2_kill_window_limit,  // 32-bit slot-2 at NEXT_HI exceeds the 64-bit window
    output logic o_slot2_kill_transient  // Buffer/BRAM transient state
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

  // Exact F=0,H=0,R=0 cofactor of the buffer select for the two slot-2 BTB
  // candidate bits.  BPC independently blocks prediction under every peeled
  // squash.  Keeping this companion out of packet selection and PC advance
  // severs the registered holdoff -> candidate -> predicted-target path while
  // leaving the architectural slot-2 decision unchanged.
  logic use_instr_buffer_for_slot2_prediction_timing;
  assign use_instr_buffer_for_slot2_prediction_timing =
      (prev_was_compressed_at_lo_for_use && i_pc_reg[1]) ||
      i_use_buffer_after_prediction_timing;

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
  (* keep = "true", max_fanout = 16 *)logic fetch_word_swapped_word;
  (* keep = "true", max_fanout = 16 *)logic fetch_word_swapped_sideband;
  (* keep = "true", max_fanout = 16 *)logic fetch_word_swapped_fast;
  (* keep = "true", max_fanout = 16 *)logic fetch_word_swapped_slot2;
  assign fetch_word_swapped_word = i_instr_bank_sel_r ^ i_pc_reg[2];
  assign fetch_word_swapped_sideband = i_instr_bank_sel_r ^ i_pc_reg[2];
  assign fetch_word_swapped_fast = i_instr_bank_sel_r ^ i_pc_reg[2];
  assign fetch_word_swapped_slot2 = i_instr_bank_sel_r ^ i_pc_reg[2];

  logic [31:0] bram_current_word;  // BRAM word aligned to pc_reg
  assign bram_current_word = fetch_word_swapped_word ? i_instr[63:32] : i_instr[31:0];

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
  // Original order: {next_sb, current_sb}.  When fetch_word_swapped, the
  // "current" sideband is in the upper sideband word.
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
  // Provider and pc_reg parity are the only selects added here.  Each metadata
  // bit therefore maps to one LUT6 (four data lanes plus two selects).  In the
  // low-BRAM case, no fetch-bank XOR or positional swap precedes this selector.
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
  assign rvc_source_hot_instr_lo = aligned_current_sb[riscv_pkg::ImemSbRvcSourceHotLoLsb+:3];
  assign rvc_source_hot_instr_hi = aligned_current_sb[riscv_pkg::ImemSbRvcSourceHotHiLsb+:3];
  assign rvc_source_hot_next_lo  = aligned_next_sb[riscv_pkg::ImemSbRvcSourceHotLoLsb+:3];
  assign rvc_source_hot_next_hi  = aligned_next_sb[riscv_pkg::ImemSbRvcSourceHotHiLsb+:3];
  assign rvc_source_hot_buf_lo   = i_instr_buffer_sideband[riscv_pkg::ImemSbRvcSourceHotLoLsb+:3];
  assign rvc_source_hot_buf_hi   = i_instr_buffer_sideband[riscv_pkg::ImemSbRvcSourceHotHiLsb+:3];

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

  // Use the same word/halfword identity as raw_parcel. The metadata comes
  // directly from the registered sideband BRAM rather than rebuilding the
  // five timing-sensitive source bits from the selected instruction later.
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

  // Use the timing cofactor for the size replicas and, below, a duplicate of
  // the two BPC candidate bits. Raw parcel selection, instruction assembly,
  // canonical slot-2 shape/PC advance, and o_use_instr_buffer all remain on
  // the fully masked architectural signal above.
  logic need_buffer_fast;
  assign need_buffer_fast = (prev_was_compressed_at_lo_fast && i_pc_reg[1]) ||
                            i_use_buffer_after_prediction_timing;

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
      (sel_instr_hi & is_comp_instr_hi_fast) |
      (sel_instr_lo & is_comp_instr_lo_fast);

  // The saved and buffered arms intentionally remain canonical: those values
  // already crossed their state boundary before the live BRAM window moved.
  // Only live instruction-size arms use the consumer-local LUTRAM copy.
  assign o_is_compressed_for_pc_advance =
      (sel_saved    & i_is_compressed_saved) |
      (sel_buf_hi   & is_comp_buf_hi) |
      (sel_buf_lo   & is_comp_buf_lo) |
      (sel_instr_hi & is_comp_instr_hi_for_pc_advance) |
      (sel_instr_lo & is_comp_instr_lo_for_pc_advance);

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

  // ===========================================================================
  // Slot-2 parcel selection.
  // ===========================================================================
  // The 64-bit fetch (i_instr) provides up to 4 halfwords of decoder data:
  //
  //   bram_current_word[15:0]  | bram_current_word[31:16]
  //   bram_next_word[15:0]     | bram_next_word[31:16]
  //
  // Plus, when use_instr_buffer is active, two halfwords from i_instr_buffer
  // (the previously-fetched word) replace bram_current_word for slot-1's
  // parcel — and bram_current_word/bram_next_word still come from BRAM at the
  // fetch lead.  Slot-2 sits one parcel-position past slot-1 and must come
  // from data we already have this cycle.
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
  // The (buf, !hi) cases (slot-1 from buffer at lo) only arise after the rare
  // use_buffer_after_prediction holdoff and slot-2 stays invalid there.
  //
  // Slot-2 32-bit at NEXT_HI would need a halfword from the next fetch, so
  // slot-2 is forced invalid in that case (slot-2 RVC at NEXT_HI is fine).
  // ---------------------------------------------------------------------------
  localparam logic [1:0] Slot2AtCurrentHi = 2'd0;
  localparam logic [1:0] Slot2AtNextLo = 2'd1;
  localparam logic [1:0] Slot2AtNextHi = 2'd2;
  localparam logic [1:0] Slot2InvalidPos = 2'd3;

  // BRAM next word (the OTHER 32 bits of i_instr — what bram_current_word
  // does NOT select).  In the buffer case where fetch_word_swapped=1, this
  // resolves to word(W+1) (= the word AFTER the buffer).
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
      default: slot2_pos = Slot2InvalidPos;  //  buf, !hi, * — punt
    endcase
  end

  // Slot-2 raw 16-bit parcel (the same data PD's RVC decompressor will see).
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

  // A +2 slot starts at CURRENT_HI from an even PC and NEXT_LO from an odd
  // PC.  A +4 slot starts at NEXT_LO from an even PC and NEXT_HI from an odd
  // PC.  Both expressions are independent of slot-1 size, allowing the two
  // BTB candidates to complete their strict size checks in parallel.
  assign o_slot2_is_compressed_plus2_for_btb = i_pc_reg[1] ?
      aligned_next_sb[riscv_pkg::ImemSbIsCompressedLo] :
      aligned_current_sb[riscv_pkg::ImemSbIsCompressedHi];
  assign o_slot2_is_compressed_plus4_for_btb = i_pc_reg[1] ?
      aligned_next_sb[riscv_pkg::ImemSbIsCompressedHi] :
      aligned_next_sb[riscv_pkg::ImemSbIsCompressedLo];

  // Slot-2 effective 32-bit instruction — per-candidate decompress-then-mux.
  //
  // TIMING: the former shape muxed the raw parcel by slot2_pos and let PD
  // decompress it (parcel mux -> RVC expander -> is_compressed mux, all in
  // series BEHIND the sideband -> slot2_pos cone; the o_from_pd_to_id_2
  // instruction/rs2 capture was the post-opt WNS group on x3). Instead,
  // decompress the three FIXED candidate parcels straight off the swap-muxed
  // fetch words — in parallel with the slot2_pos selection — and pre-mux each
  // candidate's final 32-bit form (RVC-expanded or native) using its own
  // FIXED sideband compressed bit. The late slot2_pos then selects among
  // fully-formed instructions in one level, and PD consumes
  // o_effective_instr_2 directly for BOTH the RVC and native cases.
  //
  // Per-candidate is-compressed uses the sideband bits, which are
  // bit-identical to the parcel encoding test (imem_make_sideband stores
  // parcel[1:0] != 2'b11 per halfword, on both the BRAM init and DDR fill
  // paths) — the same equivalence o_is_compressed_2 already relies on.
  logic [31:0] slot2_decomp_cur_hi;
  logic [31:0] slot2_decomp_next_lo;
  logic [31:0] slot2_decomp_next_hi;
  logic slot2_raw_illegal_cur_hi;
  logic slot2_raw_illegal_next_lo;
  logic slot2_raw_illegal_next_hi;

  rvc_decompressor u_slot2_decomp_cur_hi (
      .i_instr_compressed(bram_current_word[31:16]),
      .i_rd_is_x2(aligned_current_hi_rd_is_x2),
      .o_instr_expanded(slot2_decomp_cur_hi),
      .o_is_compressed(),
      .o_illegal(slot2_raw_illegal_cur_hi)
  );
  rvc_decompressor u_slot2_decomp_next_lo (
      .i_instr_compressed(bram_next_word[15:0]),
      .i_rd_is_x2(bram_next_word[11:7] == 5'd2),
      .o_instr_expanded(slot2_decomp_next_lo),
      .o_is_compressed(),
      .o_illegal(slot2_raw_illegal_next_lo)
  );
  rvc_decompressor u_slot2_decomp_next_hi (
      .i_instr_compressed(bram_next_word[31:16]),
      .i_rd_is_x2(aligned_next_hi_rd_is_x2),
      .o_instr_expanded(slot2_decomp_next_hi),
      .o_is_compressed(),
      .o_illegal(slot2_raw_illegal_next_hi)
  );

  // Per-candidate final instruction: RVC expansion or the native assembly.
  // For Slot2AtNextHi 32-bit, the instruction would span beyond the 64-bit
  // fetch; emit NOP and leave slot-2 forced invalid below.
  logic [31:0] slot2_final_cur_hi;
  logic [31:0] slot2_final_next_lo;
  logic [31:0] slot2_final_next_hi;
  assign slot2_final_cur_hi = aligned_current_sb[riscv_pkg::ImemSbIsCompressedHi] ?
      slot2_decomp_cur_hi : {bram_next_word[15:0], bram_current_word[31:16]};
  assign slot2_final_next_lo = aligned_next_sb[riscv_pkg::ImemSbIsCompressedLo] ?
      slot2_decomp_next_lo : bram_next_word;
  assign slot2_final_next_hi = aligned_next_sb[riscv_pkg::ImemSbIsCompressedHi] ?
      slot2_decomp_next_hi : riscv_pkg::NOP;

  // Resolve the three source-hot bits beside each fixed final-instruction
  // candidate.  This keeps the late slot2_pos mux as the only operation after
  // candidate selection; IF no longer needs a second compressed/native join.
  //
  // CURRENT_HI native is {next[15:0], current[31:16]}, so final bits
  // {21,17:16} are next-word bits {5,1:0}. NEXT_LO native is next_word.
  // NEXT_HI native cannot fit and its final instruction is NOP.
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

  always_comb begin
    unique case (slot2_pos)
      Slot2AtCurrentHi: o_source_hot_2 = slot2_source_hot_cur_hi;
      Slot2AtNextLo:    o_source_hot_2 = slot2_source_hot_next_lo;
      Slot2AtNextHi:    o_source_hot_2 = slot2_source_hot_next_hi;
      default:          o_source_hot_2 = 3'd0;
    endcase
  end

`ifndef SYNTHESIS
  // Exact oracle for the former IF-stage compressed/native join.  Keep the
  // old selected-RVC expression here so equivalence does not require an
  // environmental assumption that instruction and sideband inputs agree.
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
  assign slot2_candidate_compressed_selected = o_is_compressed ?
      o_slot2_is_compressed_plus2_for_btb : o_slot2_is_compressed_plus4_for_btb;

  always_comb begin
    if (!$isunknown({o_source_hot_2, slot2_source_hot_legacy})) begin
      p_slot2_source_hot_matches_legacy : assert (o_source_hot_2 == slot2_source_hot_legacy);
    end
    if ((slot2_pos != Slot2InvalidPos) && !$isunknown(
            {o_is_compressed_2, slot2_candidate_compressed_selected}
        )) begin
      p_slot2_candidate_size_matches_selected :
      assert (o_is_compressed_2 == slot2_candidate_compressed_selected);
    end
  end
`endif

  // Slot-2 illegal-RVC flag for the selected candidate (only meaningful when
  // the parcel is compressed; PD masks it with sel_nop). Replaces PD's local
  // decompressor-derived illegal, which sat on the same deep serial cone.
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

  // Slot-1 branch detection (decision #1: terminates the 2-wide bundle).
  // Mirrors cpu_ooo's if_stage_has_control_flow but operates on this stage's
  // raw signals so the signal is available before the IF→PD register.
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
  // For 32-bit slot-1 at pc_reg[1]=1, the instruction spans two words and the
  // opcode lives in the upper half of bram_current_word.  Reconstruct the
  // assembled instruction's opcode bits to detect branches correctly in that
  // case.  (For non-spanning slot-1, the opcode is at o_effective_instr[6:0]
  // anyway since effective_instr == current_word and pc_reg[1]=0 means the
  // instruction starts at the low half.)
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

  // Slot 2 is invalid when slot 1 is a bubble, control-flow instruction, or
  // serializing instruction; slot 2 does not fit in the fetch window; its
  // source word is unreliable; or slot 2 is serializing or FP compute.
  //
  // 64-bit fetch supplies up to 4 halfwords per cycle: the two halves of
  // bram_current_word and the two halves of bram_next_word.  The CURRENT_HI
  // case (slot-1 RVC at lo of W) reads slot-2 entirely from
  // bram_current_word's high half — no bram_next_word dependency.  The
  // NEXT_LO cases (slot-1 RVC at hi, buffered or not; slot-1 32b at even)
  // need bram_next_word to hold word(W+1).  The NEXT_HI case (slot-1 32b at
  // odd) additionally requires an RVC slot-2 — a 32-bit one would span
  // beyond the window and stays 1-wide.
  //
  // Allow slot 2 only when bram_next_word reliably holds word(pc_reg+1).
  // CURRENT_HI never
  // needs bram_next_word (slot-2 reads bram_current_word[31:16]), so it's
  // always safe.  NEXT_LO needs bram_next_word and is safe iff:
  //   (a) !use_instr_buffer && !fetch_word_swapped — BRAM aligned with pc_reg,
  //       so i_instr[63:32] = next_word_wide = word(W+1), or
  //   (b) use_instr_buffer && fetch_word_swapped — buffer state, BRAM 1 word
  //       ahead, after swap bram_next_word = i_instr[31:0] = current_word_wide
  //       = word(pc_T-1's word) = word(buffer's word + 1) = word(W+1).
  // The unsafe case is !use_instr_buffer && fetch_word_swapped, where pc_reg
  // and bank_sel_r disagree without buffer being involved.  In that transient
  // case bram_next_word aliases word(W-1).  Such cycles always also assert
  // o_sel_nop (slot-1 itself isn't trusted) so slot-2 would be NOP'd anyway,
  // The explicit gate protects any future non-NOP use of !buf+swap.
  logic slot2_bram_unsafe;
  assign slot2_bram_unsafe = !o_use_instr_buffer && fetch_word_swapped_slot2;
  logic slot2_bram_unsafe_for_prediction_timing;
  assign slot2_bram_unsafe_for_prediction_timing =
      !use_instr_buffer_for_slot2_prediction_timing && fetch_word_swapped_slot2;
  // Serializing slot-2 instructions are excluded by the predecoded
  // ImemSbSlot2StartValid* sideband (riscv_pkg::imem_native_serialize). CSR,
  // MISC-MEM, and AMO instructions require head-only retirement; allowing a
  // slot-2 consumer of a slot-1 CSR would also leave it waiting for a CDB
  // result that CSR execution never broadcasts.
  // Keep FP compute/FMA ops out of slot-2. They are not CoreMark-critical, and
  // allowing them behind a slot-1 INT/MEM op pulls FP RS backpressure into the
  // slot-1 dispatch-enable cone. Invalidating slot-2 makes the PC advance
  // only past slot-1, so the FP instruction is replayed later as slot-1.  That
  // exclusion is carried by ImemSbSlot2StartValid* through
  // riscv_pkg::imem_native_fp_compute, covering OPC_OP_FP,
  // OPC_FMADD, OPC_FMSUB, OPC_FNMSUB and OPC_FNMADD.
  // Except for CURRENT_HI RVC, every shape reads bram_next_word and requires
  // !slot2_bram_unsafe. The dual-port early-address path permits slot-2 stores;
  // the staged BTB and per-candidate size qualification permit slot-2
  // branches. Six done-repair channels cover missed-CDB source wakeups.
  //
  // Bundles form behind compressed and native 32-bit non-control,
  // non-serializing slot 1 instructions (the sideband's
  // AllowsSlot2After covers both), so all four (slot-1 size x position)
  // shapes are enumerated:
  //   RVC @ even  -> slot-2 at CURRENT_HI
  //   32b @ even  -> slot-2 at NEXT_LO   (RVC = +6, 32b = +8)
  //   RVC @ odd   -> slot-2 at NEXT_LO
  //   32b @ odd   -> slot-2 at NEXT_HI   (RVC only: a 32-bit slot-2 there
  //                                       would span beyond the 64-bit fetch)
  // The per-halfword sideband predecodes the allows-slot-2 predicate, the
  // slot-1 size, and the slot-2 start-valid predicate.  Four otherwise-unused
  // stored class bits additionally collapse the size/allows conjunction for
  // every shape; the same-word RVC-at-even bit also includes slot-2's class
  // validity.  Those PC predicates remain in the compact low 12 bits; the
  // six narrow RVC source bits are independent and do not add another
  // join to the live IMEM-to-PC cone.
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

  // Slot-1 size from the same sideband source as the allows predicate (the
  // fast o_is_compressed mux carries saved-state arms this PC-critical cone
  // must not depend on; during replay the saved selects take over anyway).
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
  // instructions use the sideband already captured in the instruction-buffer register. At
  // a low-half PC the buffer shape is deliberately unsupported, so the
  // low-half PC candidates below read aligned_current_sb directly.
  logic slot1_pairable_compressed_hi_for_pc;
  logic slot1_pairable_native_hi_for_pc;
  assign slot1_pairable_compressed_hi_for_pc = o_use_instr_buffer ?
      i_instr_buffer_sideband[riscv_pkg::ImemSbPairableCompressedHi] :
      aligned_current_pc_metadata[2];
  assign slot1_pairable_native_hi_for_pc = o_use_instr_buffer ?
      i_instr_buffer_sideband[riscv_pkg::ImemSbPairableNativeHi] :
      aligned_current_pc_metadata[3];

  // Candidate-local copies use the timing cofactor above.  The canonical
  // pairability selects remain authoritative for packet validity and PC
  // advance; these copies feed only the two BPC candidate identity bits.
  logic slot1_pairable_compressed_hi_for_prediction_timing;
  logic slot1_pairable_native_hi_for_prediction_timing;
  assign slot1_pairable_compressed_hi_for_prediction_timing =
      use_instr_buffer_for_slot2_prediction_timing ?
      i_instr_buffer_sideband[riscv_pkg::ImemSbPairableCompressedHi] :
      aligned_current_pc_metadata[2];
  assign slot1_pairable_native_hi_for_prediction_timing =
      use_instr_buffer_for_slot2_prediction_timing ?
      i_instr_buffer_sideband[riscv_pkg::ImemSbPairableNativeHi] :
      aligned_current_pc_metadata[3];

  // The original shape candidates remain as the classification view used by
  // the width-funnel kill-cause taps below.  In particular, they intentionally
  // do not include slot-2 start validity, so a blocked slot-2 is still counted
  // as a class kill rather than disappearing into the no-pair bucket.
  logic slot2_current_hi_candidate;
  logic slot2_next_lo_candidate;
  logic slot2_next_hi_candidate;
  // RVC slot-1 at even: slot-2 at CURRENT_HI.
  assign slot2_current_hi_candidate = !o_sel_nop && !o_use_instr_buffer && !i_pc_reg[1] &&
                                      aligned_current_sb[riscv_pkg::ImemSbAllowsSlot2AfterLo] &&
                                      aligned_current_sb[riscv_pkg::ImemSbIsCompressedLo];
  // NEXT_LO from either shape: 32b slot-1 at even (32b-led pair) or RVC
  // slot-1 at odd (buffered or not).  The 32b-led arm keeps the existing
  // buffer-at-even punt (o_use_instr_buffer && !pc_reg[1] stays invalid).
  assign slot2_next_lo_candidate =
      (!o_sel_nop && !o_use_instr_buffer && !i_pc_reg[1] &&
       aligned_current_sb[riscv_pkg::ImemSbAllowsSlot2AfterLo] &&
       !aligned_current_sb[riscv_pkg::ImemSbIsCompressedLo]) ||
      (!o_sel_nop && i_pc_reg[1] && slot1_allows_slot2_for_pc && slot1_compressed_for_pc);
  // 32b slot-1 at odd: slot-2 at NEXT_HI (RVC slot-2 only).
  assign slot2_next_hi_candidate = !o_sel_nop && i_pc_reg[1] && slot1_allows_slot2_for_pc &&
                                   !slot1_compressed_for_pc;

  // PC-functional shape candidates use the write/init-time conjunctions.
  // Only the prospective slot-2 word/class joins that cannot be known from
  // this word remain below.
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

  logic slot2_current_hi_candidate_for_prediction_timing;
  logic slot2_next_lo_candidate_for_prediction_timing;
  logic slot2_next_hi_candidate_for_prediction_timing;
  assign slot2_current_hi_candidate_for_prediction_timing =
      !o_sel_nop && !use_instr_buffer_for_slot2_prediction_timing &&
      !i_pc_reg[1] && aligned_current_pc_pairability[0];
  assign slot2_next_lo_candidate_for_prediction_timing =
      (!o_sel_nop && !use_instr_buffer_for_slot2_prediction_timing &&
       !i_pc_reg[1] && aligned_current_pc_pairability[1]) ||
      (!o_sel_nop && i_pc_reg[1] &&
       slot1_pairable_compressed_hi_for_prediction_timing);
  assign slot2_next_hi_candidate_for_prediction_timing =
      !o_sel_nop && i_pc_reg[1] &&
      slot1_pairable_native_hi_for_prediction_timing;

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
  // cannot fit beyond the 64-bit window and remains invalid.
  assign slot2_next_hi_invalid = slot2_bram_unsafe || !slot2_next_hi_compressed;
  assign slot2_current_hi_invalid_for_pc_advance =
      slot2_bram_unsafe && !slot2_current_hi_compressed_for_pc_advance;
  assign slot2_next_hi_invalid_for_pc_advance =
      slot2_bram_unsafe || !slot2_next_hi_compressed_for_pc_advance;

  logic slot2_current_hi_valid_for_prediction_timing;
  logic slot2_next_lo_valid_for_prediction_timing;
  logic slot2_next_hi_valid_for_prediction_timing;
  assign slot2_current_hi_valid_for_prediction_timing =
      slot2_current_hi_candidate_for_prediction_timing &&
      !(slot2_bram_unsafe_for_prediction_timing &&
        !slot2_current_hi_compressed_for_pc_advance);
  assign slot2_next_lo_valid_for_prediction_timing =
      slot2_next_lo_candidate_for_prediction_timing &&
      !(slot2_bram_unsafe_for_prediction_timing || !slot2_next_lo_start_valid);
  assign slot2_next_hi_valid_for_prediction_timing =
      slot2_next_hi_candidate_for_prediction_timing &&
      !(slot2_bram_unsafe_for_prediction_timing ||
        !slot2_next_hi_compressed_for_pc_advance);

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
  // Resolve canonical slot-2 +2/+4 identity from the already-qualified shape
  // arms for the local equivalence oracle.  Packet validity and PC advance
  // continue to use these canonical terms directly below.
  // NEXT_LO is +4 behind an even-PC native slot 1 and +2 behind an odd-PC
  // compressed slot 1.  CURRENT_HI and NEXT_HI have fixed +2/+4 identities.
  logic slot2_plus2_candidate_valid_canonical;
  logic slot2_plus4_candidate_valid_canonical;
  assign slot2_plus2_candidate_valid_canonical = slot2_current_hi_valid_for_pc_advance ||
      (i_pc_reg[1] && slot2_next_lo_valid_for_pc);
  assign slot2_plus4_candidate_valid_canonical = slot2_next_hi_valid_for_pc_advance ||
      (!i_pc_reg[1] && slot2_next_lo_valid_for_pc);
  // The BPC candidates use the exact F=0,H=0,R=0 cofactor.  They equal the
  // canonical identities in every prediction-enabled cycle and may differ
  // only while IF independently squashes all prediction consumers.
  assign o_slot2_plus2_candidate_valid = slot2_plus2_candidate_valid_canonical;
  assign o_slot2_plus4_candidate_valid = slot2_plus4_candidate_valid_canonical;
  assign o_slot2_plus2_candidate_valid_timing =
      slot2_current_hi_valid_for_prediction_timing ||
      (i_pc_reg[1] && slot2_next_lo_valid_for_prediction_timing);
  assign o_slot2_plus4_candidate_valid_timing =
      slot2_next_hi_valid_for_prediction_timing ||
      (!i_pc_reg[1] && slot2_next_lo_valid_for_prediction_timing);
  assign slot2_valid_for_pc_advance = slot2_current_hi_valid_for_pc_advance ||
      slot2_next_lo_valid_for_pc || slot2_next_hi_valid_for_pc_advance;
  assign o_slot2_valid_for_pc = slot2_valid_for_pc_advance;

`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown(
            {
              i_use_buffer_after_prediction,
              i_use_buffer_after_prediction_timing,
              slot2_plus2_candidate_valid_canonical,
              slot2_plus4_candidate_valid_canonical,
              o_slot2_plus2_candidate_valid_timing,
              o_slot2_plus4_candidate_valid_timing
            }
        )) begin
      p_slot2_prediction_candidates_are_onehot :
      assert ($onehot0(
          {o_slot2_plus4_candidate_valid_timing, o_slot2_plus2_candidate_valid_timing}
      ));
      p_slot2_canonical_candidates_are_onehot :
      assert ($onehot0(
          {slot2_plus4_candidate_valid_canonical, slot2_plus2_candidate_valid_canonical}
      ));
      p_slot2_prediction_candidate_cofactor_exact :
      assert ((i_use_buffer_after_prediction_timing !=
               i_use_buffer_after_prediction) ||
              ({o_slot2_plus4_candidate_valid_timing,
                o_slot2_plus2_candidate_valid_timing} ==
               {slot2_plus4_candidate_valid_canonical,
                slot2_plus2_candidate_valid_canonical}));
    end
  end
`endif

  // Consumers only inspect the compression bit when slot-2 is valid.  Keep the
  // valid predicate out of this high-fanout select so the sideband "allows
  // slot-2" bit does not also drive the slot-2-size mux cone.  The candidates
  // are mutually exclusive by construction (even/odd, slot-1 size).
  assign o_slot2_is_compressed_for_pc =
      slot2_current_hi_candidate_for_pc ? slot2_current_hi_compressed_for_pc_advance :
      slot2_next_hi_candidate_for_pc    ? slot2_next_hi_compressed_for_pc_advance    :
                                           slot2_next_lo_compressed_for_pc_advance;

  logic slot2_sel_nop_when_enabled;
  assign slot2_sel_nop_when_enabled = !slot2_valid_when_enabled;
  // if_stage adds two gates before this becomes the output slot-2 sel_nop:
  //   1. OR with if_stage's full sel_nop, so slot-2 NOPs whenever slot-1 NOPs
  //      (covers control_flow_holdoff, pending-prediction holdoffs, reset
  //      holdoff, and flush — none of which are in this aligner's o_sel_nop).
  //   2. Drive the slot2_valid going to pc_increment_calculator and
  //      c_ext_state from the OUTPUT slot-2 sel_nop, not the live aligner
  //      value, so that PC inc and the c-ext state machine see the same slot-2
  //      decision the dispatcher sees during stall replay.  Same idea applied
  //      to is_compressed_2 → use o_from_if_to_pd_2.sel_compressed (already
  //      replay-aware via stall_capture_reg).
  // This keeps replay, PC advance, and dispatch on the same slot-2 decision
  // when a stall begins during a holdoff cycle.
  assign o_sel_nop_2 = slot2_sel_nop_when_enabled;

  // Slot-2 sel_compressed: mirror slot-1.
  assign o_sel_compressed_2 = o_is_compressed_2;

  // ===========================================================================
  // Slot-2 Kill-Cause Classification (profiling taps)
  // ===========================================================================
  // Pure taps off existing nets for the width-funnel perf counters; nothing
  // here feeds the PC or packet paths.  Priority makes the causes mutually
  // exclusive: native slot-1 (control flow / serializing, split by the
  // NativeSerialize sideband bit) > compressed-control slot-1 > slot-2 class
  // exclusion (Slot2StartValid=0: native CSR/MISC-MEM/AMO/FP-compute) >
  // 64-bit fetch-window limit (a start-valid native 32-bit slot-2 at NEXT_HI
  // cannot fit the window; fundamental, not transient) > buffer/BRAM
  // transient (slot2_bram_unsafe, buffer-at-lo punt).  When slot-2 is
  // actually valid, all six are 0 by construction.
  logic slot2_kill_start_invalid;
  assign slot2_kill_start_invalid =
      slot2_current_hi_candidate ? !slot2_current_hi_start_valid :
      slot2_next_lo_candidate    ? !slot2_next_lo_start_valid    :
      slot2_next_hi_candidate    ? !slot2_next_hi_start_valid    : 1'b0;

  // Slot-1's NativeSerialize sideband bit, muxed like slot1_allows_slot2_for_pc.
  // Profiling-only: feeds nothing but the kill-cause taps below.
  //
  // TIMING (keep-pinned, MEASURED): this read and slot2_next_hi_native32 below
  // are the two profiling-only consumers of the live sideband decode that the
  // width-funnel counters added.  Unpinned, synthesis absorbs them into the
  // functional sideband/slot-2 select cluster and re-clusters the whole
  // imem -> fetch-PC cone: post-opt WNS -0.233 -> -0.300.  Proven by tie-off
  // (both expressions forced to 0 => the cone returns to -0.233 with a
  // byte-identical path); the pins recover it and then some (-0.175), because
  // they also stop a pre-existing fusion.  Cost is one private LUT per tap;
  // the taps still read the same nets in the same cycle, so the kill-cause
  // attribution and its stall-capture replay are untouched.
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

  // With 32b-led pairing, !allows for a native slot-1 means it is a 32-bit
  // control-flow or serializing instruction; the NativeSerialize bit splits
  // the two (they are disjoint opcode classes).
  assign o_slot2_kill_s1_native_ctrl = !slot1_allows_slot2_for_pc && !o_is_compressed &&
                                       !slot1_native_serialize_for_pc;
  assign o_slot2_kill_s1_native_serialize = !slot1_allows_slot2_for_pc && !o_is_compressed &&
                                            slot1_native_serialize_for_pc;
  assign o_slot2_kill_slot1_ctrl = !slot1_allows_slot2_for_pc && o_is_compressed;
  assign o_slot2_kill_class = slot1_allows_slot2_for_pc && slot2_kill_start_invalid;

  // Remainder bucket (the pre-split kill_transient), divided into the
  // fundamental 64-bit fetch-window case — the slot-2 candidate sits at
  // NEXT_HI (32b slot-1 at odd) and is itself native 32-bit, so it can never
  // fit regardless of BRAM state — and the true transients (BRAM
  // parity-unsafe reads, buffer-at-lo punt).
  logic slot2_kill_no_pair;
  // TIMING: keep-pinned for the same reason as slot1_native_serialize_for_pc.
  (* keep = "true" *)logic slot2_next_hi_native32;
  assign slot2_kill_no_pair = slot1_allows_slot2_for_pc && !slot2_kill_start_invalid &&
                              !slot2_valid_when_enabled;
  assign slot2_next_hi_native32 = slot2_next_hi_candidate && !slot2_next_hi_compressed;
  assign o_slot2_kill_window_limit = slot2_kill_no_pair && slot2_next_hi_native32;
  assign o_slot2_kill_transient = slot2_kill_no_pair && !slot2_next_hi_native32;

endmodule : instruction_aligner
