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
    output logic o_use_instr_buffer,  // Using buffered instruction

    // ===========================================================================
    // Slot-2 outputs (2-wide dispatch, Session F)
    // ===========================================================================
    // Slot-2 raw_parcel: 16-bit parcel for PD slot-2 decompression
    output logic [15:0] o_raw_parcel_2,
    // Slot-2 effective 32-bit instruction (assembled if slot-2 is 32-bit at a
    // spanning position in the 64-bit fetch).  Don't-care when slot-2 is RVC.
    output logic [31:0] o_effective_instr_2,
    // Slot-2 is compressed (RVC).
    output logic o_is_compressed_2,
    // Slot-2 is invalid this cycle (NOP through PD).  Asserted when slot-1 is
    // a NOP, when slot-1 is a branch (decision #1), when slot-2 doesn't fit
    // in the current 64-bit fetch, or when the buffer is in an unsupported
    // state for slot-2.
    output logic o_sel_nop_2,
    // Slot-2 RVC select for PD's instruction-mux (mirror of slot-1).
    output logic o_sel_compressed_2,
    // Slot-1 is a branch (BRANCH/JAL/JALR or compressed equivalent).  Used by
    // pc_controller to terminate the bundle and by upstream consumers (e.g.,
    // c_ext_state) that need to know the bundle terminated early.
    output logic o_slot1_is_branch
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

  // ===========================================================================
  // Slot-2 Parcel Selection (2-wide dispatch — Session F)
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
  // The pair-shape table (per design doc) maps (use_buffer, pc_reg[1],
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
  assign bram_next_word = fetch_word_swapped ? i_instr[31:0] : i_instr[63:32];

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
      Slot2AtCurrentHi: o_is_compressed_2 = aligned_current_sb[1];
      Slot2AtNextLo:    o_is_compressed_2 = aligned_next_sb[0];
      Slot2AtNextHi:    o_is_compressed_2 = aligned_next_sb[1];
      default:          o_is_compressed_2 = 1'b0;
    endcase
  end

  // Slot-2 effective 32-bit instruction.  Only consumed when slot-2 is
  // 32-bit (PD picks decompressed_instr for the RVC case).  For Slot2AtNextHi
  // 32-bit, the instruction would span beyond the 64-bit fetch; emit NOP and
  // leave slot-2 forced invalid below.
  always_comb begin
    if (o_is_compressed_2) begin
      // RVC: PD decompresses; the field is don't-care.  Keep raw bits in the
      // low half so the slot-2 cone is X-free in simulation.
      o_effective_instr_2 = {16'd0, o_raw_parcel_2};
    end else begin
      unique case (slot2_pos)
        Slot2AtCurrentHi: o_effective_instr_2 = {bram_next_word[15:0], bram_current_word[31:16]};
        Slot2AtNextLo: o_effective_instr_2 = bram_next_word;
        // 32-bit at NEXT_HI doesn't fit; slot-2 will be NOP'd.
        default: o_effective_instr_2 = riscv_pkg::NOP;
      endcase
    end
  end

  // Slot-2 fits in this cycle's fetch.
  logic slot2_fits_in_fetch;
  assign slot2_fits_in_fetch = (slot2_pos != Slot2InvalidPos) &&
                               (o_is_compressed_2 || (slot2_pos != Slot2AtNextHi));

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
  assign slot1_branch_compressed =
      ((s1_c_op == 2'b01) &&
       ((s1_c_funct3 == 3'b001) ||  // C.JAL (RV32)
      (s1_c_funct3 == 3'b101) ||  // C.J
      (s1_c_funct3 == 3'b110) ||  // C.BEQZ
      (s1_c_funct3 == 3'b111))) ||  // C.BNEZ
      ((s1_c_op == 2'b10) &&
       (s1_c_rs2 == 5'b00000) &&
       (s1_c_rs1 != 5'b00000) &&
       ((s1_c_funct4 == 4'b1000) ||  // C.JR
      (s1_c_funct4 == 4'b1001)));  // C.JALR
  assign o_slot1_is_branch = !o_sel_nop &&
                             (o_is_compressed ? slot1_branch_compressed : slot1_branch_native);

  // Slot-2 is invalid when:
  //   - slot-1 itself is a NOP/bubble (sel_nop), OR
  //   - slot-1 is a branch (decision #1 — bundle terminates), OR
  //   - slot-2 does not fit in the 64-bit fetch (NEXT_HI 32-bit), OR
  //   - slot-2 needs bram_next_word but the BRAM is in the !buf+swap state
  //     (transient — see Session J gate below), OR
  //   - slot-2 is a compressed branch (Session G placeholder — see below).
  //
  // 64-bit fetch supplies up to 4 halfwords per cycle: the two halves of
  // bram_current_word and the two halves of bram_next_word.  The CURRENT_HI
  // case (slot-1 RVC at lo of W) reads slot-2 entirely from
  // bram_current_word's high half — no bram_next_word dependency.  The
  // NEXT_LO case (slot-1 RVC at hi, no buffer; or slot-1 RVC at hi via
  // buffer) needs bram_next_word to hold word(W+1).  See the Session J gate
  // comment below for when that's reliable and when it isn't.  RVC+32 and
  // 32+RVC and 32+32 bundles need PC advances > 4; those are still gated by
  // the !o_is_compressed / !o_is_compressed_2 arms below pending follow-up.
  //
  // Slot-2 BRAM-bandwidth gate (Session J): allow slot-2 firing whenever
  // bram_next_word reliably holds word(pc_reg's word + 1).  CURRENT_HI never
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
  // but the explicit gate documents the invariant and protects against any
  // future case that lets a non-NOP cycle land in !buf+swap.
  logic slot2_bram_unsafe;
  assign slot2_bram_unsafe = !o_use_instr_buffer && fetch_word_swapped;
  // Slot-2 compressed-branch detector — kept in the gate because slot-2 with a
  // RAS-eligible compressed branch (c.j/c.jal/c.jr/c.jalr/c.beqz/c.bnez)
  // didn't wake up correctly in Session G runtime tests.  Single-port BTB and
  // RAS lookup (decision #3) only handle slot-1, so a compressed branch in
  // slot-2 is always a misprediction relative to fetch — measure first
  // before opening that path.
  logic [2:0] s2_c_funct3;
  logic [3:0] s2_c_funct4;
  logic [4:0] s2_c_rs1;
  logic [4:0] s2_c_rs2;
  logic [1:0] s2_c_op;
  assign s2_c_funct3 = o_raw_parcel_2[15:13];
  assign s2_c_funct4 = o_raw_parcel_2[15:12];
  assign s2_c_rs1    = o_raw_parcel_2[11:7];
  assign s2_c_rs2    = o_raw_parcel_2[6:2];
  assign s2_c_op     = o_raw_parcel_2[1:0];
  logic slot2_is_compressed_branch;
  assign slot2_is_compressed_branch =
      ((s2_c_op == 2'b01) &&
       ((s2_c_funct3 == 3'b001) ||
        (s2_c_funct3 == 3'b101) ||
        (s2_c_funct3 == 3'b110) ||
        (s2_c_funct3 == 3'b111))) ||
      ((s2_c_op == 2'b10) &&
       (s2_c_rs2 == 5'b00000) &&
       (s2_c_rs1 != 5'b00000) &&
       ((s2_c_funct4 == 4'b1000) ||
        (s2_c_funct4 == 4'b1001)));
  // Session K: slot-2 native-branch detector — same defensive rationale as the
  // compressed-branch gate above.  Slot-2 native BRANCH/JAL/JALR shares the
  // same un-root-caused source-tag-wakeup / RAT-update-ordering risk that
  // motivated slot2_is_compressed_branch.  Was a no-op while !o_is_compressed_2
  // gated all 32-bit slot-2 firing; now that Session K drops that arm, this
  // gate keeps slot-2 native branches off the live path until the underlying
  // slot-2-branch bug is root-caused.  Slot-2's 32-bit opcode is always at
  // o_effective_instr_2[6:0]: Slot2AtCurrentHi 32b assembles
  // {bram_next_word[15:0], bram_current_word[31:16]} (opcode lives in the
  // low half of the assembled instruction); Slot2AtNextLo 32b is just
  // bram_next_word with the opcode at [6:0].
  logic [6:0] slot2_native_opcode;
  assign slot2_native_opcode = o_effective_instr_2[6:0];
  logic slot2_is_native_branch;
  assign slot2_is_native_branch = !o_is_compressed_2 &&
      ((slot2_native_opcode == riscv_pkg::OPC_BRANCH) ||
       (slot2_native_opcode == riscv_pkg::OPC_JAL) ||
       (slot2_native_opcode == riscv_pkg::OPC_JALR));
  // Session K: slot-2 "serialize op" detector — defensive gate for CSR /
  // SYSTEM (ECALL/EBREAK/MRET/WFI) / FENCE / FENCE.I / atomic (LR/SC/AMO*)
  // 32-bit opcodes in slot-2.  These all need head-only retire serialization
  // in the ROB (see reorder_buffer.sv head_ok_2wide gate at lines 552-560).
  // The ROB's 2-wide commit gate already blocks slot-2 commit when slot-1 is
  // one of these, but at ALLOC time slot-2 still enters the RS and the FU may
  // issue speculatively before the slot-1 serialize op commits.  In
  // particular, CSR results don't broadcast on the CDB at issue (they execute
  // at commit), so a slot-2 source renamed to a slot-1 CSR's ROB tag would
  // never wake.  Symptoms when this gate is absent: isa_test F/D fail at
  // frm-readback / fcsr sequences and MachMode CSR sequences (the entire
  // bundle is `csrw frm, x; csrr y, frm; TEST(...)` style — exactly the
  // pattern that exposes slot-2-in-CSR-cone hazards).  Was a no-op while
  // !o_is_compressed_2 gated all 32-bit slot-2 firing; needed now that
  // Session K opens slot-2 32b.  RVC has no encodings in these classes, so
  // gating only on !o_is_compressed_2 is sufficient.
  logic slot2_is_serialize_op;
  assign slot2_is_serialize_op = !o_is_compressed_2 &&
      ((slot2_native_opcode == riscv_pkg::OPC_CSR) ||
       (slot2_native_opcode == riscv_pkg::OPC_MISC_MEM) ||
       (slot2_native_opcode == riscv_pkg::OPC_AMO));
  // Session K: slot-2 STORE detector (INT STORE / FP STORE) — formerly gated
  // slot-2 STOREs because the tomasulo_wrapper's pipelined early-addr path
  // was slot-1-only and slot-2 STOREs holding SQ entries with addr_valid=0
  // caused -6% CoreMark IPC via SQ-disambig back-pressure.
  // Session L: tomasulo_wrapper.sv:~2414-2570 now dual-ports the early-addr
  // pipeline (slot-2 has its own {valid,base,imm,rob_tag,repair}_2_q register
  // set, its own adder, and SQ accepts both i_early_addr_update packets in
  // parallel via store_queue.sv's matched pair of CAM loops).  Slot-2 STOREs
  // get dispatch-cycle address resolution just like slot-1, so the gate is
  // dropped.  Detector retained as documentation; not used in the OR chain.
  logic slot2_is_store_op;
  assign slot2_is_store_op = !o_is_compressed_2 &&
      ((slot2_native_opcode == riscv_pkg::OPC_STORE) ||
       (slot2_native_opcode == riscv_pkg::OPC_STORE_FP));
  // Session K: drop the !o_is_compressed_2 arm — slot-2 32-bit can fire when
  // bram_next_word is reliable.  Widen the bram-unsafe arm so the only
  // bram_next_word-free combination is CURRENT_HI + slot-2 RVC; everything
  // else (NEXT_LO RVC/32b and CURRENT_HI 32b — the latter spans
  // bram_current_word[31:16] into bram_next_word[15:0]) requires
  // !slot2_bram_unsafe to fire.  Mirrors Session J's analysis but extends
  // the bram-reliability requirement to CURRENT_HI 32-bit slot-2.
  // NEXT_HI is still unreachable here (gated by !o_is_compressed = slot-1 RVC
  // requirement; NEXT_HI only arises when slot-1 is 32-bit).
  // Session L: dropped slot2_is_store_op from the OR chain (see detector
  // comment above).
  // Session M: 6-channel done-repair (added) covers slot-2 source-tag
  // wakeup for the missed-CDB-at-dispatch case.
  // Session N: root-caused the slot-2 branch hazard to a latent
  // checkpoint_owner_tag bug at cpu_ooo.sv:1480 (slot-1's alloc tag was
  // stored even when slot-2 held the checkpoint).  Fix landed there.
  // Session Q: dual-port BTB now provides slot-2 prediction (per
  // `branch_prediction_controller`), so the broad slot-2-branch gates
  // can be dropped.  One residual gate is kept: native (32-bit) slot-2
  // branches at Slot2AtCurrentHi sit at a halfword PC (slot-1 RVC at
  // pc_reg[1]=0 → slot-2 PC = pc_reg + 2 with [1]=1).  The BTB blocks
  // halfword-PC predictions unless its entry is marked compressed
  // (decision in `branch_prediction_controller.sv:slot2_prediction_allowed`),
  // so a native slot-2 branch at this position is never predicted and
  // every taken occurrence triggers a full mispredict-recovery.  Session Q
  // measured -4.6% CoreMark with this case allowed; blocking it (and
  // letting the branch retry as slot-1 of the next bundle, where its PC
  // is word-aligned) restores the win to +5.4%.  Compressed slot-2
  // branches at CURRENT_HI work fine — BTB entry is marked compressed
  // and prediction proceeds.
  logic slot2_native_branch_at_halfword;
  assign slot2_native_branch_at_halfword = slot2_is_native_branch &&
                                           (slot2_pos == Slot2AtCurrentHi);
  logic slot2_sel_nop_when_enabled;
  assign slot2_sel_nop_when_enabled = o_sel_nop || o_slot1_is_branch ||
                                      !slot2_fits_in_fetch ||
                                      !o_is_compressed ||
                                      ((!(slot2_pos == Slot2AtCurrentHi &&
                                          o_is_compressed_2)) &&
                                       slot2_bram_unsafe) ||
                                      slot2_native_branch_at_halfword ||
                                      slot2_is_serialize_op;
  // SESSION I: slot-2 firing is now enabled.  if_stage.sv adds two correctness
  // gates around the aligner's view of slot2_sel_nop_when_enabled before it
  // becomes the OUTPUT slot-2 sel_nop:
  //   1. OR with if_stage's full sel_nop, so slot-2 NOPs whenever slot-1 NOPs
  //      (covers control_flow_holdoff, pending-prediction holdoffs, reset
  //      holdoff, and flush — none of which are in this aligner's o_sel_nop).
  //   2. Drive the slot2_valid going to pc_increment_calculator and
  //      c_ext_state from the OUTPUT slot-2 sel_nop, not the live aligner
  //      value, so that PC inc and the c-ext state machine see the same slot-2
  //      decision the dispatcher sees during stall replay.  Same idea applied
  //      to is_compressed_2 → use o_from_if_to_pd_2.sel_compressed (already
  //      replay-aware via stall_capture_reg).
  // Together these prevent the slot-2 path from corrupting the front-end after
  // a stall starts during a holdoff cycle (where pc / pc_reg diverge by more
  // than one fetch word and the aligner's parity adjustment ends up reading
  // the wrong word in a way that looked locally consistent).  See Session I
  // entry in 2wide_dispatch_design.md.
  assign o_sel_nop_2 = slot2_sel_nop_when_enabled;

  // Slot-2 sel_compressed: mirror slot-1.
  assign o_sel_compressed_2 = o_is_compressed_2;

endmodule : instruction_aligner
