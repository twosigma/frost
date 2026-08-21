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
  Precomputes PC increments in parallel, then selects by instruction and bundle
  size. This places late selects after the carry chains:
  Instead of:  next_pc = pc + mux(select, 0, 2, 4)  [select→mux→CARRY8]
  We do:       next_pc = mux(select, pc+2, pc+4)  [CARRY8 in parallel, then mux]

  For the pc_reg path, the +2/+4/+6/+8 results are pre-computed using
  registered-only select signals. The late bundle-size selector chooses among
  those results before pc_controller's final priority mux. This keeps the
  CARRY8 chains off the BRAM-dependent select path while retaining one
  monolithic priority expression for o_pc_reg.
*/
module pc_increment_calculator #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    // Current PC values (registered outputs from pc_controller)
    input logic [XLEN-1:0] i_pc,
    input logic [XLEN-1:0] i_pc_reg,

    // C-extension state signals
    input logic i_is_compressed,
    input logic i_is_compressed_for_pc,
    input logic i_sel_nop,  // IF outputs NOP (stale BRAM data — is_compressed unreliable)

    // Encoded instruction-bundle advance: +2/+4 one-wide, +4/+6/+8 for
    // two-wide bundles (RVC+RVC, RVC+32b / 32b+RVC, 32b+32b).
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel,

    // Holdoff and control signals
    input logic i_any_holdoff_safe,
    input logic i_prediction_holdoff,
    input logic i_prediction_from_buffer_holdoff,  // RAS predicted from buffer, stale cycle
    input logic i_control_flow_to_halfword_r,
    input logic i_stall_registered,

    // Mid-32bit correction (from pc_controller)
    input logic i_mid_32bit_correction,

    // Outputs for final PC mux in pc_controller
    output logic [XLEN-1:0] o_seq_next_pc,     // Sequential PC for fetch
    output logic [XLEN-1:0] o_seq_next_pc_plus_2,
    output logic [XLEN-1:0] o_seq_next_pc_reg,  // Sequential PC for instruction address
    // 1-bit precomputed (o_seq_next_pc_reg != i_pc) for the pc_controller
    // prediction-pending arm (see the compare block near the end).
    output logic o_seq_next_pc_reg_neq_pc
);

  // ===========================================================================
  // PC Increment Selection Signals
  // ===========================================================================
  // Combinational select signal for instruction type. With 64-bit fetch,
  // fetch-side spanning wait is gone, so the fetch PC never needs a +0
  // sequential increment.
  logic pc_inc_comb_sel_2;
  assign pc_inc_comb_sel_2 = i_is_compressed;

  // Final PC increment select with priority encoding
  // Priority: sel_holdoff (holdoff) > sel_2 (halfword) > default
  // Use i_any_holdoff_safe (registered) to break timing path from branch_taken.
  //
  // Prediction holdoff and redirect/reset holdoff need different
  // treatment for halfword PCs.
  //
  // For prediction holdoff, +2 from a halfword PC is correct: it advances to the
  // next word boundary without letting o_pc get two instructions ahead of pc_reg.
  //
  // For redirect/reset holdoff, +4 is required even from a halfword PC. Using +2
  // there leaves the numeric fetch lead too small, so the BRAM word for the next
  // word-aligned instruction arrives one cycle late after a halfword redirect.
  logic pc_inc_sel_redirect_holdoff, pc_inc_sel_prediction_holdoff, pc_inc_sel_2;
  assign pc_inc_sel_redirect_holdoff = i_any_holdoff_safe;
  assign pc_inc_sel_prediction_holdoff = !i_any_holdoff_safe && i_prediction_holdoff;
  assign pc_inc_sel_2 = !pc_inc_sel_redirect_holdoff &&
                        !pc_inc_sel_prediction_holdoff &&
                        i_control_flow_to_halfword_r;

  // ===========================================================================
  // Parallel Adders for PC (Fetch Address)
  // ===========================================================================
  // Local aliases for readability (PcIncrementCompressed=2, PcIncrement32bit=4)
  localparam logic [riscv_pkg::XLEN-1:0] IncC = riscv_pkg::PcIncrementCompressed;
  localparam logic [riscv_pkg::XLEN-1:0] Inc4 = riscv_pkg::PcIncrement32bit;

  // 1-wide options plus the 2-wide bundle +6/+8 options.
  // Build these from the word index so pc[1] selects between precomputed
  // word increments instead of feeding the full carry chain.
  localparam int unsigned PcWordBits = XLEN - 2;
  localparam logic [PcWordBits-1:0] PcWordInc1 = {{(PcWordBits - 1) {1'b0}}, 1'b1};
  localparam logic [PcWordBits-1:0] PcWordInc2 = {{(PcWordBits - 2) {1'b0}}, 2'b10};
  localparam logic [PcWordBits-1:0] PcWordInc3 = {{(PcWordBits - 2) {1'b0}}, 2'b11};
  logic [PcWordBits-1:0] pc_word;
  logic [PcWordBits-1:0] pc_word_plus_1;
  logic [PcWordBits-1:0] pc_word_plus_2;
  logic [PcWordBits-1:0] pc_word_plus_3;
  logic                  pc_halfword;
  assign pc_word        = i_pc[XLEN-1:2];
  assign pc_halfword    = i_pc[1];
  assign pc_word_plus_1 = pc_word + PcWordInc1;
  assign pc_word_plus_2 = pc_word + PcWordInc2;
  assign pc_word_plus_3 = pc_word + PcWordInc3;

  logic [XLEN-1:0] next_pc_plus_2, next_pc_plus_4, next_pc_plus_6, next_pc_plus_8;
  logic [XLEN-1:0] next_pc_plus_10;
  assign next_pc_plus_2  = {pc_halfword ? pc_word_plus_1 : pc_word, ~pc_halfword, i_pc[0]};
  assign next_pc_plus_4  = {pc_word_plus_1, pc_halfword, i_pc[0]};
  assign next_pc_plus_6  = {pc_halfword ? pc_word_plus_2 : pc_word_plus_1, ~pc_halfword, i_pc[0]};
  assign next_pc_plus_8  = {pc_word_plus_2, pc_halfword, i_pc[0]};
  assign next_pc_plus_10 = {pc_halfword ? pc_word_plus_3 : pc_word_plus_2, ~pc_halfword, i_pc[0]};

  // Default-case bundle advance.  The sideband-heavy work is already collapsed
  // into i_pc_reg_advance_sel in if_stage, so this module only has a narrow
  // encoded select on the wide fetch-PC mux.
  logic [XLEN-1:0] fetch_seq_next_pc;
  logic [XLEN-1:0] fetch_seq_next_pc_plus_2;
  pc_fetch_advance_mux #(
      .XLEN(XLEN)
  ) u_pc_fetch_advance_mux (
      .i_next_pc_plus_2(next_pc_plus_2),
      .i_next_pc_plus_4(next_pc_plus_4),
      .i_next_pc_plus_6(next_pc_plus_6),
      .i_next_pc_plus_8(next_pc_plus_8),
      .i_next_pc_plus_10(next_pc_plus_10),
      .i_advance_sel(i_pc_fetch_advance_sel),
      .o_fetch_seq_next_pc(fetch_seq_next_pc),
      .o_fetch_seq_next_pc_plus_2(fetch_seq_next_pc_plus_2)
  );

  // Compute next_sequential_pc (raw sequential PC before corrections)
  logic [XLEN-1:0] next_sequential_pc;
  logic [XLEN-1:0] next_sequential_pc_plus_2;
  always_comb begin
    casez ({
      pc_inc_sel_redirect_holdoff, pc_inc_sel_prediction_holdoff, pc_inc_sel_2
    })
      3'b1??: begin
        next_sequential_pc        = next_pc_plus_4;
        next_sequential_pc_plus_2 = next_pc_plus_6;
      end
      3'b01?: begin
        next_sequential_pc        = !i_pc[1] ? next_pc_plus_4 : next_pc_plus_2;
        next_sequential_pc_plus_2 = !i_pc[1] ? next_pc_plus_6 : next_pc_plus_4;
      end
      3'b001: begin
        next_sequential_pc        = next_pc_plus_2;  // halfword: +2
        next_sequential_pc_plus_2 = next_pc_plus_4;
      end
      default: begin
        next_sequential_pc        = fetch_seq_next_pc;
        next_sequential_pc_plus_2 = fetch_seq_next_pc_plus_2;
      end
    endcase
  end

  // ===========================================================================
  // Parallel Adders for PC_reg (Instruction Address)
  // ===========================================================================
  // Pre-compute pc_reg +2/+4/+6/+8 using
  // registered inputs. The parallel adders settle from registered i_pc_reg
  // (~0.3 ns) well before BRAM data arrives (~0.9 ns). Only the downstream
  // bundle-advance mux uses the late sideband-derived selector, keeping the
  // CARRY8 chains entirely off that select path.
  //
  // pc_reg_precompute holds pc_reg during i_prediction_from_buffer_holdoff.
  // Advancing while outputting the NOP would corrupt pc_reg[1], which selects
  // the buffered halfword on the following use_buffer_after_prediction cycle.

  // TIMING: The pre-computed results depend ONLY on registered inputs and
  // settle ~0.3 ns into the cycle. The late-arriving bundle-advance selector
  // must only control the downstream 4:1 mux, NOT feed into the CARRY8 adder
  // chains.
  //
  // Without a hard module boundary, Vivado merges the adders with the
  // downstream MUX into a single CARRY8 chain where the S-inputs depend on
  // the bundle-advance selector.
  //
  // The submodule instance with dont_touch prevents this: Vivado cannot
  // dissolve the boundary, so the adders and registered-select MUXes stay
  // inside the submodule while the bundle-advance MUX stays outside.
  (* keep = "true" *)logic [XLEN-1:0] pc_reg_if_compressed;
  (* keep = "true" *)logic [XLEN-1:0] pc_reg_if_32bit;
  (* keep = "true" *)logic [XLEN-1:0] pc_reg_plus_6;
  (* keep = "true" *)logic [XLEN-1:0] pc_reg_plus_8;

  (* dont_touch = "yes" *) pc_reg_precompute #(
      .XLEN(XLEN)
  ) u_pc_reg_precompute (
      .i_pc_reg                        (i_pc_reg),
      .i_prediction_from_buffer_holdoff(i_prediction_from_buffer_holdoff),
      .o_pc_reg_if_compressed          (pc_reg_if_compressed),
      .o_pc_reg_if_32bit               (pc_reg_if_32bit),
      .o_pc_reg_plus_6                 (pc_reg_plus_6),
      .o_pc_reg_plus_8                 (pc_reg_plus_8)
  );

  // Select based on live instruction and slot-2 metadata. Only this mux uses
  // the late bundle-advance selector; the CARRY8 chains settle from registered
  // i_pc_reg well before that selector arrives. The selected sequential result
  // then feeds pc_controller's monolithic final-priority mux.
  //
  // When sel_nop is active, the BRAM data is stale (wrong address after a
  // redirect) so is_compressed/slot-2 are unreliable.  Force +2 (compressed,
  // slot-2 invalid) to prevent pc_reg from overshooting a pending prediction
  // branch PC.
  //
  // 2-wide: when slot-2 is valid this cycle, use the bundle advance:
  //   RVC + RVC = +4 (= pc_reg_if_32bit, semantically identical)
  //   RVC + 32b / 32b + RVC = +6
  //   32b + 32b = +8
  logic [XLEN-1:0] pc_reg_normal;
  pc_reg_advance_mux #(
      .XLEN(XLEN)
  ) u_pc_reg_advance_mux (
      .i_pc_reg_if_compressed(pc_reg_if_compressed),
      .i_pc_reg_if_32bit(pc_reg_if_32bit),
      .i_pc_reg_plus_6(pc_reg_plus_6),
      .i_pc_reg_plus_8(pc_reg_plus_8),
      .i_advance_sel(i_pc_reg_advance_sel),
      .o_pc_reg_normal(pc_reg_normal)
  );

  // ===========================================================================
  // Special PC Corrections
  // ===========================================================================
  logic [XLEN-1:0] pc_mid_32bit_correction;
  logic [XLEN-1:0] pc_mid_32bit_correction_plus_2;
  logic [XLEN-1:0] pc_reg_mid_32bit_correction;
  logic [XLEN-1:0] pc_spanning_to_halfword;
  logic [XLEN-1:0] pc_spanning_to_halfword_plus_2;

  assign pc_mid_32bit_correction = ((i_pc_reg + IncC) & ~64'd3) + Inc4;
  assign pc_mid_32bit_correction_plus_2 = pc_mid_32bit_correction + IncC;
  assign pc_reg_mid_32bit_correction = i_pc_reg + IncC;
  assign pc_spanning_to_halfword = i_pc_reg + Inc4;
  assign pc_spanning_to_halfword_plus_2 = pc_spanning_to_halfword + IncC;

  // ===========================================================================
  // Final Sequential PC Selection (used by final PC mux in pc_controller)
  // ===========================================================================
  // Select from pre-computed options based on holdoff/correction state.
  // All conditions use registered signals for timing.
  logic seq_sel_holdoff, seq_sel_mid_32bit, seq_sel_spanning_hw;
  assign seq_sel_holdoff = i_any_holdoff_safe;
  assign seq_sel_mid_32bit = !i_any_holdoff_safe && i_mid_32bit_correction;
  assign seq_sel_spanning_hw = 1'b0;

  always_comb begin
    if (seq_sel_holdoff) begin
      o_seq_next_pc = next_sequential_pc;
      o_seq_next_pc_plus_2 = next_sequential_pc_plus_2;
      o_seq_next_pc_reg = i_pc_reg;  // holdoff: hold pc_reg
    end else if (seq_sel_mid_32bit) begin
      o_seq_next_pc = pc_mid_32bit_correction;
      o_seq_next_pc_plus_2 = pc_mid_32bit_correction_plus_2;
      o_seq_next_pc_reg = pc_reg_mid_32bit_correction;
    end else if (seq_sel_spanning_hw) begin
      o_seq_next_pc = pc_spanning_to_halfword;
      o_seq_next_pc_plus_2 = pc_spanning_to_halfword_plus_2;
      o_seq_next_pc_reg = pc_reg_normal;
    end else begin
      o_seq_next_pc = next_sequential_pc;
      o_seq_next_pc_plus_2 = next_sequential_pc_plus_2;
      o_seq_next_pc_reg = pc_reg_normal;
    end
  end

  // ===========================================================================
  // Precomputed (o_seq_next_pc_reg != i_pc) — compare-then-mux form
  // ===========================================================================
  // TIMING: pc_controller's prediction-pending arm needs the full
  // seq_next_pc_reg-vs-fetch-PC miss check (the bit1 proxy caused the no-MMU
  // Linux boot hang), but comparing the muxed XLEN-wide value puts the wide NEQ
  // AFTER the late sideband-derived i_pc_reg_advance_sel. Both compare
  // operands of every CANDIDATE are register-sourced (i_pc, i_pc_reg, and the
  // pre-computed increments), so run the six XLEN-wide compares in parallel off
  // the registers and let the late selects pick among 1-bit results. Mirrors
  // the o_seq_next_pc_reg selection above arm-for-arm (including the
  // pc_reg_advance_mux unique-case default mapping to the +2 candidate), so
  // the result is bit-identical to (o_seq_next_pc_reg != i_pc).
  logic neq_hold, neq_mid, neq_plus2, neq_plus4, neq_plus6, neq_plus8;
  logic neq_advance_sel;
  assign neq_hold  = (i_pc_reg != i_pc);
  assign neq_mid   = (pc_reg_mid_32bit_correction != i_pc);
  assign neq_plus2 = (pc_reg_if_compressed != i_pc);
  assign neq_plus4 = (pc_reg_if_32bit != i_pc);
  assign neq_plus6 = (pc_reg_plus_6 != i_pc);
  assign neq_plus8 = (pc_reg_plus_8 != i_pc);
  always_comb begin
    unique case (i_pc_reg_advance_sel)
      riscv_pkg::PcAdvancePlus2: neq_advance_sel = neq_plus2;
      riscv_pkg::PcAdvancePlus4: neq_advance_sel = neq_plus4;
      riscv_pkg::PcAdvancePlus6: neq_advance_sel = neq_plus6;
      riscv_pkg::PcAdvancePlus8: neq_advance_sel = neq_plus8;
      default:                   neq_advance_sel = neq_plus2;
    endcase
  end
  always_comb begin
    if (seq_sel_holdoff) o_seq_next_pc_reg_neq_pc = neq_hold;
    else if (seq_sel_mid_32bit) o_seq_next_pc_reg_neq_pc = neq_mid;
    else o_seq_next_pc_reg_neq_pc = neq_advance_sel;
  end

`ifndef SYNTHESIS
  // The 1-bit precompute must track the wide compare exactly.
  always_comb begin
    if (o_seq_next_pc_reg_neq_pc !== (o_seq_next_pc_reg != i_pc)) begin
      $error("pc_increment_calculator: o_seq_next_pc_reg_neq_pc mismatch");
    end
  end
`endif

endmodule : pc_increment_calculator

module pc_fetch_advance_mux #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic [XLEN-1:0] i_next_pc_plus_2,
    input logic [XLEN-1:0] i_next_pc_plus_4,
    input logic [XLEN-1:0] i_next_pc_plus_6,
    input logic [XLEN-1:0] i_next_pc_plus_8,
    input logic [XLEN-1:0] i_next_pc_plus_10,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_advance_sel,
    output logic [XLEN-1:0] o_fetch_seq_next_pc,
    output logic [XLEN-1:0] o_fetch_seq_next_pc_plus_2
);

  always_comb begin
    unique case (i_advance_sel)
      riscv_pkg::PcAdvancePlus2: begin
        o_fetch_seq_next_pc        = i_next_pc_plus_2;
        o_fetch_seq_next_pc_plus_2 = i_next_pc_plus_4;
      end
      riscv_pkg::PcAdvancePlus4: begin
        o_fetch_seq_next_pc        = i_next_pc_plus_4;
        o_fetch_seq_next_pc_plus_2 = i_next_pc_plus_6;
      end
      riscv_pkg::PcAdvancePlus6: begin
        o_fetch_seq_next_pc        = i_next_pc_plus_6;
        o_fetch_seq_next_pc_plus_2 = i_next_pc_plus_8;
      end
      riscv_pkg::PcAdvancePlus8: begin
        o_fetch_seq_next_pc        = i_next_pc_plus_8;
        o_fetch_seq_next_pc_plus_2 = i_next_pc_plus_10;
      end
      default: begin
        o_fetch_seq_next_pc        = i_next_pc_plus_2;
        o_fetch_seq_next_pc_plus_2 = i_next_pc_plus_4;
      end
    endcase
  end

endmodule : pc_fetch_advance_mux

module pc_reg_advance_mux #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic [XLEN-1:0] i_pc_reg_if_compressed,
    input logic [XLEN-1:0] i_pc_reg_if_32bit,
    input logic [XLEN-1:0] i_pc_reg_plus_6,
    input logic [XLEN-1:0] i_pc_reg_plus_8,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_advance_sel,
    output logic [XLEN-1:0] o_pc_reg_normal
);

  always_comb begin
    unique case (i_advance_sel)
      riscv_pkg::PcAdvancePlus2: o_pc_reg_normal = i_pc_reg_if_compressed;
      riscv_pkg::PcAdvancePlus4: o_pc_reg_normal = i_pc_reg_if_32bit;
      riscv_pkg::PcAdvancePlus6: o_pc_reg_normal = i_pc_reg_plus_6;
      riscv_pkg::PcAdvancePlus8: o_pc_reg_normal = i_pc_reg_plus_8;
      default:                   o_pc_reg_normal = i_pc_reg_if_compressed;
    endcase
  end

endmodule : pc_reg_advance_mux
