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
  PC Increment Calculator

  Computes the next sequential PC values using parallel adders for timing optimization.
  This module pre-computes all possible PC increment results (pc+0, pc+2, pc+4) in
  parallel, then selects the correct result based on instruction type and state.

  Key Timing Optimization:
  ========================
  Instead of:  next_pc = pc + mux(select, 0, 2, 4)  [select→mux→CARRY8]
  We do:       next_pc = mux(select, pc+0, pc+2, pc+4)  [CARRY8 in parallel, then mux]

  This moves the late-arriving select signal from BEFORE the CARRY8 chain to
  AFTER it. All three additions compute in parallel, then the mux selects the
  correct result. The critical path from is_compressed to PC now only needs
  to control a mux, not feed into a CARRY8 adder chain.

  Outputs:
  ========
    o_seq_next_pc     - Sequential PC for next fetch (used by final PC mux)
    o_seq_next_pc_reg - Sequential PC_reg (instruction address, used by final PC mux)

  Related Modules:
    - pc_controller.sv: Instantiates this module, uses outputs in final PC mux
    - c_ext_state.sv: Provides spanning and compression state
*/
module pc_increment_calculator #(
    parameter int unsigned XLEN = 32
) (
    // Current PC values (registered outputs from pc_controller)
    input logic [XLEN-1:0] i_pc,
    input logic [XLEN-1:0] i_pc_reg,

    // C-extension state signals
    input logic i_spanning_wait_for_fetch,
    input logic i_spanning_in_progress,
    input logic i_is_32bit_spanning,
    input logic i_spanning_to_halfword,
    input logic i_spanning_to_halfword_registered,
    input logic i_is_compressed,

    // Holdoff and control signals
    input logic i_any_holdoff_safe,
    input logic i_prediction_holdoff,
    input logic i_prediction_from_buffer_holdoff,  // RAS predicted from buffer, stale cycle
    input logic i_control_flow_to_halfword_r,

    // Mid-32bit correction (from pc_controller)
    input logic i_mid_32bit_correction,

    // Outputs for final PC mux in pc_controller
    output logic [XLEN-1:0] o_seq_next_pc,     // Sequential PC for fetch
    output logic [XLEN-1:0] o_seq_next_pc_reg  // Sequential PC for instruction address
);

  // ===========================================================================
  // PC Increment Selection Signals
  // ===========================================================================
  // Combinational select signals for instruction type
  // Priority: sel_0 (spanning wait) > sel_2 (compressed/spanning) > default (32-bit)
  logic pc_inc_comb_sel_0, pc_inc_comb_sel_2;
  assign pc_inc_comb_sel_0 = i_spanning_wait_for_fetch;
  assign pc_inc_comb_sel_2 = i_spanning_in_progress || i_is_compressed || i_is_32bit_spanning;

  // Final PC increment select with priority encoding
  // Priority: sel_4 (holdoff) > sel_0 (spanning wait) > sel_2 (halfword) > default
  // Use i_any_holdoff_safe (registered) to break timing path from branch_taken.
  //
  // CRITICAL: Include i_prediction_holdoff in the holdoff check!
  // After prediction redirects PC to target, instruction data is STALE (BRAM latency).
  // is_compressed is computed from stale data. If we use stale is_compressed
  // to compute pc_increment, we'd get the wrong next PC.
  // During prediction_holdoff, force pc_increment=4 to skip the stale cycle safely.
  logic pc_inc_sel_4, pc_inc_sel_2, pc_inc_sel_0;
  assign pc_inc_sel_4 = i_any_holdoff_safe || i_prediction_holdoff;
  assign pc_inc_sel_0 = !i_any_holdoff_safe && !i_prediction_holdoff && i_spanning_wait_for_fetch;
  assign pc_inc_sel_2 = !i_any_holdoff_safe && !i_prediction_holdoff &&
                        !i_spanning_wait_for_fetch &&
                        (i_control_flow_to_halfword_r || i_spanning_to_halfword_registered ||
                         i_spanning_in_progress || i_is_32bit_spanning);

  // ===========================================================================
  // Parallel Adders for PC (Fetch Address)
  // ===========================================================================
  // Local aliases for readability (PcIncrementCompressed=2, PcIncrement32bit=4)
  localparam int unsigned IncC = riscv_pkg::PcIncrementCompressed;
  localparam int unsigned Inc4 = riscv_pkg::PcIncrement32bit;

  logic [XLEN-1:0] next_pc_plus_0, next_pc_plus_2, next_pc_plus_4;
  assign next_pc_plus_0 = i_pc;
  assign next_pc_plus_2 = i_pc + IncC;
  assign next_pc_plus_4 = i_pc + Inc4;

  // Compute next_sequential_pc (raw sequential PC before corrections)
  logic [XLEN-1:0] next_sequential_pc;
  always_comb begin
    casez ({
      pc_inc_sel_4, pc_inc_sel_0, pc_inc_sel_2
    })
      3'b1??: next_sequential_pc = next_pc_plus_4;  // holdoff: +4
      3'b01?: next_sequential_pc = next_pc_plus_0;  // spanning wait: +0
      3'b001: next_sequential_pc = next_pc_plus_2;  // halfword: +2
      default: begin
        // Normal case: use combinational signals for fine-grained selection
        casez ({
          pc_inc_comb_sel_0, pc_inc_comb_sel_2
        })
          2'b1?:   next_sequential_pc = next_pc_plus_0;  // spanning wait
          2'b01:   next_sequential_pc = next_pc_plus_2;  // compressed/spanning
          default: next_sequential_pc = next_pc_plus_4;  // 32-bit instruction
        endcase
      end
    endcase
  end

  // ===========================================================================
  // Parallel Adders for PC_reg (Instruction Address)
  // ===========================================================================
  // Priority: sel_0 (spanning/wait/holdoff) > sel_2 (compressed) > default (32-bit)
  // CRITICAL: Include spanning_to_halfword_registered to hold pc_reg during the holdoff cycle.
  // During holdoff, we output NOP, so pc_reg must not advance. On the next cycle
  // (use_buffer_after_spanning), instruction_aligner uses pc_reg[1] to select
  // which half of instr_buffer to use. If pc_reg advanced during holdoff,
  // pc_reg[1] would be wrong and we'd select the wrong instruction parcel.
  logic pc_reg_inc_sel_0, pc_reg_inc_sel_2;
  assign pc_reg_inc_sel_0 = i_spanning_wait_for_fetch || i_is_32bit_spanning ||
                            i_spanning_to_halfword_registered ||
                            i_prediction_from_buffer_holdoff;  // Hold during stale cycle
  assign pc_reg_inc_sel_2 = !i_spanning_in_progress && !pc_reg_inc_sel_0 && i_is_compressed;

  logic [XLEN-1:0] pc_reg_plus_0, pc_reg_plus_2, pc_reg_plus_4;
  assign pc_reg_plus_0 = i_pc_reg;
  assign pc_reg_plus_2 = i_pc_reg + IncC;
  assign pc_reg_plus_4 = i_pc_reg + Inc4;

  // Compute pc_reg_normal (normal sequential PC_reg)
  logic [XLEN-1:0] pc_reg_normal;
  always_comb begin
    casez ({
      pc_reg_inc_sel_0, pc_reg_inc_sel_2
    })
      2'b1?:   pc_reg_normal = pc_reg_plus_0;  // spanning/wait/holdoff: +0
      2'b01:   pc_reg_normal = pc_reg_plus_2;  // compressed: +2
      default: pc_reg_normal = pc_reg_plus_4;  // 32-bit: +4
    endcase
  end

  // ===========================================================================
  // Special PC Corrections
  // ===========================================================================
  logic [XLEN-1:0] pc_mid_32bit_correction;
  logic [XLEN-1:0] pc_reg_mid_32bit_correction;
  logic [XLEN-1:0] pc_spanning_to_halfword;

  assign pc_mid_32bit_correction = ((i_pc_reg + IncC) & ~32'd3) + Inc4;
  assign pc_reg_mid_32bit_correction = i_pc_reg + IncC;
  assign pc_spanning_to_halfword = i_pc_reg + Inc4;

  // ===========================================================================
  // Final Sequential PC Selection (used by final PC mux in pc_controller)
  // ===========================================================================
  // Select from pre-computed options based on holdoff/correction state.
  // All conditions use registered signals for timing.
  logic seq_sel_holdoff, seq_sel_mid_32bit, seq_sel_spanning_hw;
  assign seq_sel_holdoff = i_any_holdoff_safe;
  assign seq_sel_mid_32bit = !i_any_holdoff_safe && i_mid_32bit_correction;
  assign seq_sel_spanning_hw = !i_any_holdoff_safe && !i_mid_32bit_correction &&
                               i_spanning_to_halfword;

  always_comb begin
    if (seq_sel_holdoff) begin
      o_seq_next_pc = next_sequential_pc;
      o_seq_next_pc_reg = i_pc_reg;  // holdoff: hold pc_reg
    end else if (seq_sel_mid_32bit) begin
      o_seq_next_pc = pc_mid_32bit_correction;
      o_seq_next_pc_reg = pc_reg_mid_32bit_correction;
    end else if (seq_sel_spanning_hw) begin
      o_seq_next_pc = pc_spanning_to_halfword;
      o_seq_next_pc_reg = pc_reg_normal;
    end else begin
      o_seq_next_pc = next_sequential_pc;
      o_seq_next_pc_reg = pc_reg_normal;
    end
  end

endmodule : pc_increment_calculator
