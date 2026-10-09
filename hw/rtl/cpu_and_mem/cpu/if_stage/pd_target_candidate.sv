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
 * One format-specific PC-relative branch-target candidate for the PD
 * redirect, computed in IF and carried to PD in the IF-to-PD packet. The late
 * branch immediate drives only a narrow low add. PD captures the candidate's
 * low result and raw {immediate sign, low-add carry} select in its redirect
 * register, and the next cycle picks the format and decodes that select into
 * a choice among the three precomputed PC-high values. Selecting and decoding
 * after the register keeps logic levels out of the late carry path, and the
 * full-width PC-high values stay outside it.
 *
 * The immediate is selected here, from the two live forms and the
 * stall-captured instruction, instead of arriving already selected:
 *   i_imm_low_lo    the immediate of the live instruction when pc_reg[1] = 0
 *                   (the current word);
 *   i_imm_low_hi    the immediate when pc_reg[1] = 1 (the spanning assembly
 *                   or the upper parcel);
 *   i_imm_low_saved the immediate of the stall-captured instruction, with
 *                   i_pc_low_saved its PC, replayed when i_replay is set.
 * The adder then gets the pc_reg[1] and replay selects inside its propagate
 * function: with the Xilinx primitives below each bit's S input is one LUT6 of
 * {replay, saved PC ^ saved immediate, live PC, pc_reg[1], hi, lo}, so from
 * the instruction memory the carry chain sits two LUTs away (the word
 * select, then this LUT) instead of three. The portable form below computes
 * the same sum from the selected operands (p_target_candidate_exact in
 * pd_stage checks the carried candidates against PC + offset every cycle).
 */
(* keep_hierarchy = "yes" *)
module pd_target_candidate #(
    parameter int unsigned SPLIT = riscv_pkg::PdTargetSplit
) (
    input  logic [SPLIT-1:0] i_pc_low,
    input  logic [SPLIT-1:0] i_pc_low_saved,
    input  logic [SPLIT-1:0] i_imm_low_lo,
    input  logic [SPLIT-1:0] i_imm_low_hi,
    input  logic [SPLIT-1:0] i_imm_low_saved,
    input  logic             i_pc_high,
    input  logic             i_replay,
    output logic [SPLIT-1:0] o_target_low,
    output logic [      1:0] o_high_select
);

  // The raw select rather than a decoded correction. With s the sign-extended
  // immediate's sign bit and c the low-add carry, the target's high part is
  // H+c-s, where H is the PC's high bits: 00 and 11 keep H, 01 selects H+1, and
  // 10 selects H-1. pd_stage decodes {s, c} after the redirect flops.
  logic imm_sign;

`ifdef FROST_XILINX_PRIMS
  localparam int unsigned NumChains = (SPLIT + 7) / 8;
  localparam int unsigned ChainBits = NumChains * 8;
  // Bits above SPLIT are padded with S = 0 and DI = 0; their outputs are
  // unused.
  logic [ChainBits-1:0] carry_s, carry_di, carry_o, carry_co;
  (* keep = "true" *) logic [SPLIT-1:0] saved_xor;
  for (genvar b = 0; b < SPLIT; b++) begin : gen_bit
    (* dont_touch = "true" *)
    LUT2 #(
        .INIT(4'h6)
    ) u_saved_xor (
        .I0(i_pc_low_saved[b]),
        .I1(i_imm_low_saved[b]),
        .O (saved_xor[b])
    );
    // S = replay ? saved_xor : pc ^ (pc_high ? hi : lo).
    (* dont_touch = "true" *)
    LUT6 #(
        .INIT(64'h8d8dd88d8dd8d8d8)
    ) u_s (
        .I0(i_replay),
        .I1(saved_xor[b]),
        .I2(i_pc_low[b]),
        .I3(i_pc_high),
        .I4(i_imm_low_hi[b]),
        .I5(i_imm_low_lo[b]),
        .O (carry_s[b])
    );
    // DI = the PC operand: replay ? saved : live.
    (* dont_touch = "true" *)
    LUT3 #(
        .INIT(8'hd8)
    ) u_di (
        .I0(i_replay),
        .I1(i_pc_low_saved[b]),
        .I2(i_pc_low[b]),
        .O (carry_di[b])
    );
  end
  if (ChainBits > SPLIT) begin : gen_pad
    assign carry_s[ChainBits-1:SPLIT]  = '0;
    assign carry_di[ChainBits-1:SPLIT] = '0;
  end
  for (genvar c = 0; c < NumChains; c++) begin : gen_chain
    logic chain_ci;
    if (c == 0) begin : gen_first
      assign chain_ci = 1'b0;
    end else begin : gen_next
      assign chain_ci = carry_co[8*c-1];
    end
    (* dont_touch = "true" *)
    CARRY8 #(
        .CARRY_TYPE("SINGLE_CY8")
    ) u_carry (
        .CI    (chain_ci),
        .CI_TOP(1'b0),
        .DI    (carry_di[8*c+:8]),
        .S     (carry_s[8*c+:8]),
        .O     (carry_o[8*c+:8]),
        .CO    (carry_co[8*c+:8])
    );
  end
  assign o_target_low = carry_o[SPLIT-1:0];
  (* dont_touch = "true" *)
  LUT5 #(
      .INIT(32'hdd8dd888)
  ) u_sign (
      .I0(i_replay),
      .I1(i_imm_low_saved[SPLIT-1]),
      .I2(i_pc_high),
      .I3(i_imm_low_hi[SPLIT-1]),
      .I4(i_imm_low_lo[SPLIT-1]),
      .O (imm_sign)
  );
  assign o_high_select = {imm_sign, carry_co[SPLIT-1]};
`else
  logic [SPLIT-1:0] pc_low, imm_low;
  (* keep = "true" *) logic [SPLIT:0] low_sum;
  assign pc_low = i_replay ? i_pc_low_saved : i_pc_low;
  assign imm_low = i_replay ? i_imm_low_saved : (i_pc_high ? i_imm_low_hi : i_imm_low_lo);
  assign low_sum = {1'b0, pc_low} + {1'b0, imm_low};
  assign o_target_low = low_sum[SPLIT-1:0];
  assign imm_sign = imm_low[SPLIT-1];
  assign o_high_select = {imm_sign, low_sum[SPLIT]};
`endif

endmodule : pd_target_candidate
