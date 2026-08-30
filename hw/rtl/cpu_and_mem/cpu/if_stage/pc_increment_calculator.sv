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
    // TIMING: the i_sel_nop=0 ("run") and i_sel_nop=1 ("nop") cofactors of
    // the two selects above. Every candidate mux below is steered by both,
    // and i_sel_nop -- the latest-arriving control in the front end -- picks
    // between the two finished results as the last 2:1. The merged selects
    // above only feed the simulation reference of the former single chain.
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_run,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_fetch_advance_sel_nop,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_run,
    input logic [riscv_pkg::PcAdvanceSelWidth-1:0] i_pc_reg_advance_sel_nop,

    // Holdoff and control signals
    input logic i_any_holdoff_safe,
    input logic i_prediction_holdoff,
    input logic i_prediction_from_buffer_holdoff,  // RAS predicted from buffer, stale cycle
    input logic i_control_flow_to_halfword_r,
    input logic i_stall_registered,

    // Mid-32bit correction (from pc_controller)
    input logic i_mid_32bit_correction,

    // Outputs for final PC mux in pc_controller
    output logic [XLEN-1:0] o_seq_next_pc,  // Sequential PC for fetch
    output logic [XLEN-1:0] o_seq_next_pc_plus_2,
    // riscv_pkg::fetch_verdict of the two sequential PCs above, predecoded
    // per candidate beside the adders and steered by the same selects, so a
    // consumer (the immu) has them WITH the sequential PC, not after it.
    output riscv_pkg::fetch_verdict_t o_seq_next_pc_verdict,
    output riscv_pkg::fetch_verdict_t o_seq_next_pc_plus_2_verdict,
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
  // Cofactor index: 0 = i_sel_nop=0 ("run"), 1 = i_sel_nop=1 ("nop").
  localparam int unsigned NCof = 2;
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] fetch_advance_sel_cof[NCof];
  logic [riscv_pkg::PcAdvanceSelWidth-1:0] reg_advance_sel_cof  [NCof];
  assign fetch_advance_sel_cof[0] = i_pc_fetch_advance_sel_run;
  assign fetch_advance_sel_cof[1] = i_pc_fetch_advance_sel_nop;
  assign reg_advance_sel_cof[0]   = i_pc_reg_advance_sel_run;
  assign reg_advance_sel_cof[1]   = i_pc_reg_advance_sel_nop;

  logic [XLEN-1:0] fetch_seq_next_pc_cof[NCof];
  logic [XLEN-1:0] fetch_seq_next_pc_plus_2_cof[NCof];
  for (genvar c = 0; c < NCof; c++) begin : gen_fetch_advance_cof
    pc_fetch_advance_mux #(
        .XLEN(XLEN)
    ) u_pc_fetch_advance_mux (
        .i_next_pc_plus_2(next_pc_plus_2),
        .i_next_pc_plus_4(next_pc_plus_4),
        .i_next_pc_plus_6(next_pc_plus_6),
        .i_next_pc_plus_8(next_pc_plus_8),
        .i_next_pc_plus_10(next_pc_plus_10),
        .i_advance_sel(fetch_advance_sel_cof[c]),
        .o_fetch_seq_next_pc(fetch_seq_next_pc_cof[c]),
        .o_fetch_seq_next_pc_plus_2(fetch_seq_next_pc_plus_2_cof[c])
    );
  end

  // The candidates' fetch verdicts (from the registered pc, off the late
  // select path) and their copy of the advance mux.
  localparam int unsigned VerdictBits = riscv_pkg::FetchVerdictBits;
  riscv_pkg::fetch_verdict_t verdict_plus_2, verdict_plus_4, verdict_plus_6, verdict_plus_8;
  riscv_pkg::fetch_verdict_t verdict_plus_10;
  assign verdict_plus_2  = riscv_pkg::fetch_verdict(next_pc_plus_2);
  assign verdict_plus_4  = riscv_pkg::fetch_verdict(next_pc_plus_4);
  assign verdict_plus_6  = riscv_pkg::fetch_verdict(next_pc_plus_6);
  assign verdict_plus_8  = riscv_pkg::fetch_verdict(next_pc_plus_8);
  assign verdict_plus_10 = riscv_pkg::fetch_verdict(next_pc_plus_10);
  riscv_pkg::fetch_verdict_t fetch_seq_verdict_cof[NCof];
  riscv_pkg::fetch_verdict_t fetch_seq_verdict_plus_2_cof[NCof];
  for (genvar c = 0; c < NCof; c++) begin : gen_fetch_advance_verdict_cof
    pc_fetch_advance_mux #(
        .XLEN(VerdictBits)
    ) u_pc_fetch_advance_verdict_mux (
        .i_next_pc_plus_2(verdict_plus_2),
        .i_next_pc_plus_4(verdict_plus_4),
        .i_next_pc_plus_6(verdict_plus_6),
        .i_next_pc_plus_8(verdict_plus_8),
        .i_next_pc_plus_10(verdict_plus_10),
        .i_advance_sel(fetch_advance_sel_cof[c]),
        .o_fetch_seq_next_pc(fetch_seq_verdict_cof[c]),
        .o_fetch_seq_next_pc_plus_2(fetch_seq_verdict_plus_2_cof[c])
    );
  end

  // Compute next_sequential_pc (raw sequential PC before corrections), per
  // cofactor. The holdoff arms use registered selects and the same
  // candidates, so only the default arm differs between the cofactors.
  logic [XLEN-1:0] next_sequential_pc_cof[NCof];
  logic [XLEN-1:0] next_sequential_pc_plus_2_cof[NCof];
  riscv_pkg::fetch_verdict_t next_sequential_verdict_cof[NCof];
  riscv_pkg::fetch_verdict_t next_sequential_verdict_plus_2_cof[NCof];
  always_comb begin
    for (int unsigned c = 0; c < NCof; c++) begin
      casez ({
        pc_inc_sel_redirect_holdoff, pc_inc_sel_prediction_holdoff, pc_inc_sel_2
      })
        3'b1??: begin
          next_sequential_pc_cof[c]             = next_pc_plus_4;
          next_sequential_pc_plus_2_cof[c]      = next_pc_plus_6;
          next_sequential_verdict_cof[c]        = verdict_plus_4;
          next_sequential_verdict_plus_2_cof[c] = verdict_plus_6;
        end
        3'b01?: begin
          next_sequential_pc_cof[c]             = !i_pc[1] ? next_pc_plus_4 : next_pc_plus_2;
          next_sequential_pc_plus_2_cof[c]      = !i_pc[1] ? next_pc_plus_6 : next_pc_plus_4;
          next_sequential_verdict_cof[c]        = !i_pc[1] ? verdict_plus_4 : verdict_plus_2;
          next_sequential_verdict_plus_2_cof[c] = !i_pc[1] ? verdict_plus_6 : verdict_plus_4;
        end
        3'b001: begin
          next_sequential_pc_cof[c]             = next_pc_plus_2;  // halfword: +2
          next_sequential_pc_plus_2_cof[c]      = next_pc_plus_4;
          next_sequential_verdict_cof[c]        = verdict_plus_2;
          next_sequential_verdict_plus_2_cof[c] = verdict_plus_4;
        end
        default: begin
          next_sequential_pc_cof[c]             = fetch_seq_next_pc_cof[c];
          next_sequential_pc_plus_2_cof[c]      = fetch_seq_next_pc_plus_2_cof[c];
          next_sequential_verdict_cof[c]        = fetch_seq_verdict_cof[c];
          next_sequential_verdict_plus_2_cof[c] = fetch_seq_verdict_plus_2_cof[c];
        end
      endcase
    end
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
  // Prediction-from-buffer hold is applied after the bundle-advance mux below.
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
  // dissolve the boundary, so the fixed candidate adders stay inside the
  // submodule while the bundle-advance MUX stays outside.
  (* keep = "true" *)logic [XLEN-1:0] pc_reg_if_compressed;
  (* keep = "true" *)logic [XLEN-1:0] pc_reg_if_32bit;
  (* keep = "true" *)logic [XLEN-1:0] pc_reg_plus_6;
  (* keep = "true" *)logic [XLEN-1:0] pc_reg_plus_8;

  (* dont_touch = "yes" *) pc_reg_precompute #(
      .XLEN(XLEN)
  ) u_pc_reg_precompute (
      .i_pc_reg              (i_pc_reg),
      .o_pc_reg_if_compressed(pc_reg_if_compressed),
      .o_pc_reg_if_32bit     (pc_reg_if_32bit),
      .o_pc_reg_plus_6       (pc_reg_plus_6),
      .o_pc_reg_plus_8       (pc_reg_plus_8)
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
  logic [XLEN-1:0] pc_reg_normal_cof[NCof];
  for (genvar c = 0; c < NCof; c++) begin : gen_pc_reg_advance_cof
    pc_reg_advance_mux #(
        .XLEN(XLEN)
    ) u_pc_reg_advance_mux (
        .i_pc_reg_if_compressed(pc_reg_if_compressed),
        .i_pc_reg_if_32bit(pc_reg_if_32bit),
        .i_pc_reg_plus_6(pc_reg_plus_6),
        .i_pc_reg_plus_8(pc_reg_plus_8),
        .i_advance_sel(reg_advance_sel_cof[c]),
        .o_pc_reg_normal(pc_reg_normal_cof[c])
    );
  end

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
  logic seq_sel_pc_reg_hold;
  assign seq_sel_holdoff = i_any_holdoff_safe;
  assign seq_sel_mid_32bit = !i_any_holdoff_safe && i_mid_32bit_correction;
  assign seq_sel_spanning_hw = 1'b0;
  // Mid-instruction correction outranks the prediction-buffer hold, matching
  // the old precompute-hold feeding the holdoff/mid/normal final mux.
  assign seq_sel_pc_reg_hold =
      seq_sel_holdoff || (i_prediction_from_buffer_holdoff && !seq_sel_mid_32bit);

  logic [XLEN-1:0] seq_next_pc_cof[NCof];
  logic [XLEN-1:0] seq_next_pc_plus_2_cof[NCof];
  riscv_pkg::fetch_verdict_t seq_next_pc_verdict_cof[NCof];
  riscv_pkg::fetch_verdict_t seq_next_pc_plus_2_verdict_cof[NCof];
  logic [XLEN-1:0] seq_next_pc_reg_cof[NCof];
  always_comb begin
    for (int unsigned c = 0; c < NCof; c++) begin
      if (seq_sel_holdoff) begin
        seq_next_pc_cof[c] = next_sequential_pc_cof[c];
        seq_next_pc_plus_2_cof[c] = next_sequential_pc_plus_2_cof[c];
        seq_next_pc_verdict_cof[c] = next_sequential_verdict_cof[c];
        seq_next_pc_plus_2_verdict_cof[c] = next_sequential_verdict_plus_2_cof[c];
      end else if (seq_sel_mid_32bit) begin
        seq_next_pc_cof[c] = pc_mid_32bit_correction;
        seq_next_pc_plus_2_cof[c] = pc_mid_32bit_correction_plus_2;
        seq_next_pc_verdict_cof[c] = riscv_pkg::fetch_verdict(pc_mid_32bit_correction);
        seq_next_pc_plus_2_verdict_cof[c] =
            riscv_pkg::fetch_verdict(pc_mid_32bit_correction_plus_2);
      end else if (seq_sel_spanning_hw) begin
        seq_next_pc_cof[c] = pc_spanning_to_halfword;
        seq_next_pc_plus_2_cof[c] = pc_spanning_to_halfword_plus_2;
        seq_next_pc_verdict_cof[c] = riscv_pkg::fetch_verdict(pc_spanning_to_halfword);
        seq_next_pc_plus_2_verdict_cof[c] =
            riscv_pkg::fetch_verdict(pc_spanning_to_halfword_plus_2);
      end else begin
        seq_next_pc_cof[c] = next_sequential_pc_cof[c];
        seq_next_pc_plus_2_cof[c] = next_sequential_pc_plus_2_cof[c];
        seq_next_pc_verdict_cof[c] = next_sequential_verdict_cof[c];
        seq_next_pc_plus_2_verdict_cof[c] = next_sequential_verdict_plus_2_cof[c];
      end
      if (seq_sel_pc_reg_hold) seq_next_pc_reg_cof[c] = i_pc_reg;
      else if (seq_sel_mid_32bit) seq_next_pc_reg_cof[c] = pc_reg_mid_32bit_correction;
      else seq_next_pc_reg_cof[c] = pc_reg_normal_cof[c];
    end
  end

  // i_sel_nop picks between the two finished cofactors: the last 2:1 of the
  // sequential value path.
  assign o_seq_next_pc = i_sel_nop ? seq_next_pc_cof[1] : seq_next_pc_cof[0];
  assign o_seq_next_pc_plus_2 = i_sel_nop ? seq_next_pc_plus_2_cof[1] : seq_next_pc_plus_2_cof[0];
  assign o_seq_next_pc_verdict = i_sel_nop ? seq_next_pc_verdict_cof[1] :
                                             seq_next_pc_verdict_cof[0];
  assign o_seq_next_pc_plus_2_verdict = i_sel_nop ? seq_next_pc_plus_2_verdict_cof[1] :
                                                    seq_next_pc_plus_2_verdict_cof[0];
  assign o_seq_next_pc_reg = i_sel_nop ? seq_next_pc_reg_cof[1] : seq_next_pc_reg_cof[0];

`ifndef SYNTHESIS
  // Reference: the former single chain steered by the merged selects.
  logic [XLEN-1:0] fetch_seq_next_pc_ref, fetch_seq_next_pc_plus_2_ref;
  logic [XLEN-1:0] next_sequential_pc_ref, seq_next_pc_ref, seq_next_pc_reg_ref;
  logic [XLEN-1:0] pc_reg_normal_ref;
  pc_fetch_advance_mux #(
      .XLEN(XLEN)
  ) u_pc_fetch_advance_mux_ref (
      .i_next_pc_plus_2(next_pc_plus_2),
      .i_next_pc_plus_4(next_pc_plus_4),
      .i_next_pc_plus_6(next_pc_plus_6),
      .i_next_pc_plus_8(next_pc_plus_8),
      .i_next_pc_plus_10(next_pc_plus_10),
      .i_advance_sel(i_pc_fetch_advance_sel),
      .o_fetch_seq_next_pc(fetch_seq_next_pc_ref),
      .o_fetch_seq_next_pc_plus_2(fetch_seq_next_pc_plus_2_ref)
  );
  pc_reg_advance_mux #(
      .XLEN(XLEN)
  ) u_pc_reg_advance_mux_ref (
      .i_pc_reg_if_compressed(pc_reg_if_compressed),
      .i_pc_reg_if_32bit(pc_reg_if_32bit),
      .i_pc_reg_plus_6(pc_reg_plus_6),
      .i_pc_reg_plus_8(pc_reg_plus_8),
      .i_advance_sel(i_pc_reg_advance_sel),
      .o_pc_reg_normal(pc_reg_normal_ref)
  );
  always_comb begin
    casez ({
      pc_inc_sel_redirect_holdoff, pc_inc_sel_prediction_holdoff, pc_inc_sel_2
    })
      3'b1??:  next_sequential_pc_ref = next_pc_plus_4;
      3'b01?:  next_sequential_pc_ref = !i_pc[1] ? next_pc_plus_4 : next_pc_plus_2;
      3'b001:  next_sequential_pc_ref = next_pc_plus_2;
      default: next_sequential_pc_ref = fetch_seq_next_pc_ref;
    endcase
    if (seq_sel_holdoff) seq_next_pc_ref = next_sequential_pc_ref;
    else if (seq_sel_mid_32bit) seq_next_pc_ref = pc_mid_32bit_correction;
    else if (seq_sel_spanning_hw) seq_next_pc_ref = pc_spanning_to_halfword;
    else seq_next_pc_ref = next_sequential_pc_ref;
    if (seq_sel_pc_reg_hold) seq_next_pc_reg_ref = i_pc_reg;
    else if (seq_sel_mid_32bit) seq_next_pc_reg_ref = pc_reg_mid_32bit_correction;
    else seq_next_pc_reg_ref = pc_reg_normal_ref;
    if (!$isunknown(
            {
              i_sel_nop,
              i_pc_fetch_advance_sel,
              i_pc_fetch_advance_sel_run,
              i_pc_fetch_advance_sel_nop,
              i_pc_reg_advance_sel,
              i_pc_reg_advance_sel_run,
              i_pc_reg_advance_sel_nop
            }
        )) begin
      // The cofactors are what if_stage says they are ...
      p_advance_sel_cofactors_exact :
      assert ((i_pc_fetch_advance_sel ==
               (i_sel_nop ? i_pc_fetch_advance_sel_nop : i_pc_fetch_advance_sel_run)) &&
              (i_pc_reg_advance_sel ==
               (i_sel_nop ? i_pc_reg_advance_sel_nop : i_pc_reg_advance_sel_run)));
      // ... and the split chain equals the former single chain every cycle.
      p_seq_next_pc_split_exact :
      assert ((o_seq_next_pc == seq_next_pc_ref) && (o_seq_next_pc_reg == seq_next_pc_reg_ref));
    end
  end
`endif

`ifndef SYNTHESIS
  // The steered verdicts are exactly the verdicts of the steered PCs.
  always_comb begin
    if (!$isunknown({o_seq_next_pc, o_seq_next_pc_plus_2})) begin
      p_seq_next_pc_verdict_exact :
      assert (o_seq_next_pc_verdict == riscv_pkg::fetch_verdict(o_seq_next_pc));
      p_seq_next_pc_plus_2_verdict_exact :
      assert (o_seq_next_pc_plus_2_verdict == riscv_pkg::fetch_verdict(o_seq_next_pc_plus_2));
    end
  end
`endif

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
  // Same cofactor split as o_seq_next_pc_reg: i_sel_nop picks last.
  logic neq_advance_sel_cof[NCof];
  always_comb begin
    for (int unsigned c = 0; c < NCof; c++) begin
      unique case (reg_advance_sel_cof[c])
        riscv_pkg::PcAdvancePlus2: neq_advance_sel_cof[c] = neq_plus2;
        riscv_pkg::PcAdvancePlus4: neq_advance_sel_cof[c] = neq_plus4;
        riscv_pkg::PcAdvancePlus6: neq_advance_sel_cof[c] = neq_plus6;
        riscv_pkg::PcAdvancePlus8: neq_advance_sel_cof[c] = neq_plus8;
        default:                   neq_advance_sel_cof[c] = neq_plus2;
      endcase
    end
    neq_advance_sel = i_sel_nop ? neq_advance_sel_cof[1] : neq_advance_sel_cof[0];
  end
  always_comb begin
    if (seq_sel_pc_reg_hold) o_seq_next_pc_reg_neq_pc = neq_hold;
    else if (seq_sel_mid_32bit) o_seq_next_pc_reg_neq_pc = neq_mid;
    else o_seq_next_pc_reg_neq_pc = neq_advance_sel;
  end

`ifndef SYNTHESIS
  initial begin
    if (VerdictBits != $bits(riscv_pkg::fetch_verdict_t)) begin
      $error("pc_increment_calculator: riscv_pkg::FetchVerdictBits does not match fetch_verdict_t");
    end
  end

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
