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
 * CDB Arbiter
 *
 * Priority-based multiplexer that selects one functional unit result per cycle
 * for broadcast on the Common Data Bus (CDB). Ties FU completions back to:
 *   - ROB (mark done + store value)
 *   - All RS instances (operand wakeup)
 *
 * Priority order favors CoreMark-relevant traffic and keeps FP/div valid cones
 * out of the grants for ALU/MEM/MUL:
 *   1. MEM   (3) — load/SC results
 *   2. MUL   (1) — integer multiply
 *   3. ALU   (0) — common integer path
 *   4. DIV   (2) — integer divide
 *   5. FP_DIV (6)
 *   6. FP_MUL (5)
 *   7. FP_ADD (4)
 *
 * Purely combinational — no output register. Matches how i_cdb currently
 * feeds RS/ROB on the same cycle edge.
 *
 * i_clk/i_rst_n ports included for formal verification infrastructure.
 */

module cdb_arbiter (
    input logic i_clk,
    input logic i_rst_n,

    // FU completion requests (one per functional unit)
    input riscv_pkg::fu_complete_t i_fu_complete_0,  // ALU
    input riscv_pkg::fu_complete_t i_fu_complete_1,  // MUL
    input riscv_pkg::fu_complete_t i_fu_complete_2,  // DIV
    input riscv_pkg::fu_complete_t i_fu_complete_3,  // MEM
    input riscv_pkg::fu_complete_t i_fu_complete_4,  // FP_ADD
    input riscv_pkg::fu_complete_t i_fu_complete_5,  // FP_MUL
    input riscv_pkg::fu_complete_t i_fu_complete_6,  // FP_DIV

    // Suppress CDB broadcast/grants during speculative full-flush recovery.
    input logic i_kill,

    // CDB broadcast output (to RS wakeup + ROB write)
    output riscv_pkg::cdb_broadcast_t o_cdb,

    // Per-FU grant signals (back-pressure: FU can clear result when granted)
    output logic [riscv_pkg::NumFus-1:0] o_grant,

    // Pre-kill grant vector. Identical to o_grant when !i_kill; during kill,
    // still reflects the priority-encoder result (not zero). Used by shims
    // that need a flush-independent "would be granted" signal for pop
    // decisions — during kill the shim is clearing its own FIFO via i_flush,
    // so popping a "would-grant" entry is harmless (cleared at same edge).
    // Keeps the cdb_kill → shim→fifo_regs combinational cone off the
    // critical path.
    output logic [riscv_pkg::NumFus-1:0] o_grant_raw
);

  // Build internal array from individual ports
  riscv_pkg::fu_complete_t i_fu_complete[riscv_pkg::NumFus];
  assign i_fu_complete[0] = i_fu_complete_0;
  assign i_fu_complete[1] = i_fu_complete_1;
  assign i_fu_complete[2] = i_fu_complete_2;
  assign i_fu_complete[3] = i_fu_complete_3;
  assign i_fu_complete[4] = i_fu_complete_4;
  assign i_fu_complete[5] = i_fu_complete_5;
  assign i_fu_complete[6] = i_fu_complete_6;

  // Valid vector for convenience (used by formal assertions)
  logic                    [riscv_pkg::NumFus-1:0] valid_vec;

  // Fixed-priority encoder: CoreMark-relevant FUs win before FP/div traffic.
  // Priority: MEM > MUL > ALU > DIV > FP_DIV > FP_MUL > FP_ADD
  logic                                            found;
  logic                    [                  2:0] winner_idx;
  riscv_pkg::fu_complete_t                         winner_data;

  always_comb begin
    for (int i = 0; i < riscv_pkg::NumFus; i++) begin
      valid_vec[i] = i_fu_complete[i].valid;
    end
  end

  always_comb begin
    found       = 1'b0;
    winner_idx  = 3'd0;
    winner_data = '0;
    o_grant_raw = '0;

    if (i_fu_complete[riscv_pkg::FU_MEM].valid) begin
      found                          = 1'b1;
      winner_idx                     = riscv_pkg::FU_MEM;
      winner_data                    = i_fu_complete[riscv_pkg::FU_MEM];
      o_grant_raw[riscv_pkg::FU_MEM] = 1'b1;
    end else if (i_fu_complete[riscv_pkg::FU_MUL].valid) begin
      found                          = 1'b1;
      winner_idx                     = riscv_pkg::FU_MUL;
      winner_data                    = i_fu_complete[riscv_pkg::FU_MUL];
      o_grant_raw[riscv_pkg::FU_MUL] = 1'b1;
    end else if (i_fu_complete[riscv_pkg::FU_ALU].valid) begin
      found                          = 1'b1;
      winner_idx                     = riscv_pkg::FU_ALU;
      winner_data                    = i_fu_complete[riscv_pkg::FU_ALU];
      o_grant_raw[riscv_pkg::FU_ALU] = 1'b1;
    end else if (i_fu_complete[riscv_pkg::FU_DIV].valid) begin
      found                          = 1'b1;
      winner_idx                     = riscv_pkg::FU_DIV;
      winner_data                    = i_fu_complete[riscv_pkg::FU_DIV];
      o_grant_raw[riscv_pkg::FU_DIV] = 1'b1;
    end else if (i_fu_complete[riscv_pkg::FU_FP_DIV].valid) begin
      found                             = 1'b1;
      winner_idx                        = riscv_pkg::FU_FP_DIV;
      winner_data                       = i_fu_complete[riscv_pkg::FU_FP_DIV];
      o_grant_raw[riscv_pkg::FU_FP_DIV] = 1'b1;
    end else if (i_fu_complete[riscv_pkg::FU_FP_MUL].valid) begin
      found                             = 1'b1;
      winner_idx                        = riscv_pkg::FU_FP_MUL;
      winner_data                       = i_fu_complete[riscv_pkg::FU_FP_MUL];
      o_grant_raw[riscv_pkg::FU_FP_MUL] = 1'b1;
    end else if (i_fu_complete[riscv_pkg::FU_FP_ADD].valid) begin
      found                             = 1'b1;
      winner_idx                        = riscv_pkg::FU_FP_ADD;
      winner_data                       = i_fu_complete[riscv_pkg::FU_FP_ADD];
      o_grant_raw[riscv_pkg::FU_FP_ADD] = 1'b1;
    end
  end

  // Kill-gated grant: suppress CDB broadcast and adapter grant when in
  // speculative full-flush recovery. o_grant_raw is the pre-kill version.
  always_comb begin
    if (i_kill) begin
      o_grant = '0;
    end else begin
      o_grant = o_grant_raw;
    end
  end

  // Pack CDB output. Suppressed during kill (speculative full-flush).
  always_comb begin
    o_cdb.valid     = found && !i_kill;
    o_cdb.tag       = winner_data.tag;
    o_cdb.value     = winner_data.value;
    o_cdb.exception = winner_data.exception;
    o_cdb.exc_cause = winner_data.exc_cause;
    o_cdb.fp_flags  = winner_data.fp_flags;
    o_cdb.fu_type   = riscv_pkg::fu_type_e'(winner_idx);
  end

  // ===========================================================================
  // Formal Verification
  // ===========================================================================
  // Formal runs under Yosys (SymbiYosys), which takes the non-VERILATOR path
  // with flattened individual ports. All assertions use valid_vec and
  // individual port names — no i_fu_complete[i] array references.
  // ===========================================================================
`ifdef FORMAL

  // Standard formal preamble
  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // -------------------------------------------------------------------------
  // Combinational assertions (module is purely combinational)
  // -------------------------------------------------------------------------

  // At most one FU granted per cycle
  always_comb begin
    p_grant_at_most_one : assert ($onehot0(o_grant));
  end

  always_comb begin
    if (i_kill) begin
      p_kill_blocks_cdb : assert (!o_cdb.valid && o_grant == '0);
    end
  end

  // Grant and CDB valid are equivalent
  always_comb begin
    p_grant_implies_cdb_valid : assert ((|o_grant) == o_cdb.valid);
  end

  // Only valid FUs can be granted (unrolled for unique Yosys labels)
  always_comb begin
    if (o_grant[riscv_pkg::FU_ALU]) p_grant_only_valid_alu : assert (valid_vec[riscv_pkg::FU_ALU]);
    if (o_grant[riscv_pkg::FU_MUL]) p_grant_only_valid_mul : assert (valid_vec[riscv_pkg::FU_MUL]);
    if (o_grant[riscv_pkg::FU_DIV]) p_grant_only_valid_div : assert (valid_vec[riscv_pkg::FU_DIV]);
    if (o_grant[riscv_pkg::FU_MEM]) p_grant_only_valid_mem : assert (valid_vec[riscv_pkg::FU_MEM]);
    if (o_grant[riscv_pkg::FU_FP_ADD])
      p_grant_only_valid_fp_add : assert (valid_vec[riscv_pkg::FU_FP_ADD]);
    if (o_grant[riscv_pkg::FU_FP_MUL])
      p_grant_only_valid_fp_mul : assert (valid_vec[riscv_pkg::FU_FP_MUL]);
    if (o_grant[riscv_pkg::FU_FP_DIV])
      p_grant_only_valid_fp_div : assert (valid_vec[riscv_pkg::FU_FP_DIV]);
  end

  // No valid FU -> no CDB output and no grants
  always_comb begin
    if (!(|valid_vec)) begin
      p_no_valid_no_grant : assert (!o_cdb.valid && o_grant == '0);
    end
  end

  // CDB tag matches granted FU
  always_comb begin
    if (o_grant[riscv_pkg::FU_ALU])
      p_cdb_tag_alu : assert (o_cdb.tag == i_fu_complete[riscv_pkg::FU_ALU].tag);
    if (o_grant[riscv_pkg::FU_MUL])
      p_cdb_tag_mul : assert (o_cdb.tag == i_fu_complete[riscv_pkg::FU_MUL].tag);
    if (o_grant[riscv_pkg::FU_DIV])
      p_cdb_tag_div : assert (o_cdb.tag == i_fu_complete[riscv_pkg::FU_DIV].tag);
    if (o_grant[riscv_pkg::FU_MEM])
      p_cdb_tag_mem : assert (o_cdb.tag == i_fu_complete[riscv_pkg::FU_MEM].tag);
    if (o_grant[riscv_pkg::FU_FP_ADD])
      p_cdb_tag_fp_add : assert (o_cdb.tag == i_fu_complete[riscv_pkg::FU_FP_ADD].tag);
    if (o_grant[riscv_pkg::FU_FP_MUL])
      p_cdb_tag_fp_mul : assert (o_cdb.tag == i_fu_complete[riscv_pkg::FU_FP_MUL].tag);
    if (o_grant[riscv_pkg::FU_FP_DIV])
      p_cdb_tag_fp_div : assert (o_cdb.tag == i_fu_complete[riscv_pkg::FU_FP_DIV].tag);
  end

  // CDB value matches granted FU
  always_comb begin
    if (o_grant[riscv_pkg::FU_ALU])
      p_cdb_value_alu : assert (o_cdb.value == i_fu_complete[riscv_pkg::FU_ALU].value);
    if (o_grant[riscv_pkg::FU_MUL])
      p_cdb_value_mul : assert (o_cdb.value == i_fu_complete[riscv_pkg::FU_MUL].value);
    if (o_grant[riscv_pkg::FU_DIV])
      p_cdb_value_div : assert (o_cdb.value == i_fu_complete[riscv_pkg::FU_DIV].value);
    if (o_grant[riscv_pkg::FU_MEM])
      p_cdb_value_mem : assert (o_cdb.value == i_fu_complete[riscv_pkg::FU_MEM].value);
    if (o_grant[riscv_pkg::FU_FP_ADD])
      p_cdb_value_fp_add : assert (o_cdb.value == i_fu_complete[riscv_pkg::FU_FP_ADD].value);
    if (o_grant[riscv_pkg::FU_FP_MUL])
      p_cdb_value_fp_mul : assert (o_cdb.value == i_fu_complete[riscv_pkg::FU_FP_MUL].value);
    if (o_grant[riscv_pkg::FU_FP_DIV])
      p_cdb_value_fp_div : assert (o_cdb.value == i_fu_complete[riscv_pkg::FU_FP_DIV].value);
  end

  // CDB exception fields match granted FU
  always_comb begin
    if (o_grant[riscv_pkg::FU_ALU])
      p_cdb_exc_alu :
      assert (
        o_cdb.exception == i_fu_complete[riscv_pkg::FU_ALU].exception &&
        o_cdb.exc_cause == i_fu_complete[riscv_pkg::FU_ALU].exc_cause &&
        o_cdb.fp_flags  == i_fu_complete[riscv_pkg::FU_ALU].fp_flags);
    if (o_grant[riscv_pkg::FU_MUL])
      p_cdb_exc_mul :
      assert (
        o_cdb.exception == i_fu_complete[riscv_pkg::FU_MUL].exception &&
        o_cdb.exc_cause == i_fu_complete[riscv_pkg::FU_MUL].exc_cause &&
        o_cdb.fp_flags  == i_fu_complete[riscv_pkg::FU_MUL].fp_flags);
    if (o_grant[riscv_pkg::FU_DIV])
      p_cdb_exc_div :
      assert (
        o_cdb.exception == i_fu_complete[riscv_pkg::FU_DIV].exception &&
        o_cdb.exc_cause == i_fu_complete[riscv_pkg::FU_DIV].exc_cause &&
        o_cdb.fp_flags  == i_fu_complete[riscv_pkg::FU_DIV].fp_flags);
    if (o_grant[riscv_pkg::FU_MEM])
      p_cdb_exc_mem :
      assert (
        o_cdb.exception == i_fu_complete[riscv_pkg::FU_MEM].exception &&
        o_cdb.exc_cause == i_fu_complete[riscv_pkg::FU_MEM].exc_cause &&
        o_cdb.fp_flags  == i_fu_complete[riscv_pkg::FU_MEM].fp_flags);
    if (o_grant[riscv_pkg::FU_FP_ADD])
      p_cdb_exc_fp_add :
      assert (
        o_cdb.exception == i_fu_complete[riscv_pkg::FU_FP_ADD].exception &&
        o_cdb.exc_cause == i_fu_complete[riscv_pkg::FU_FP_ADD].exc_cause &&
        o_cdb.fp_flags  == i_fu_complete[riscv_pkg::FU_FP_ADD].fp_flags);
    if (o_grant[riscv_pkg::FU_FP_MUL])
      p_cdb_exc_fp_mul :
      assert (
        o_cdb.exception == i_fu_complete[riscv_pkg::FU_FP_MUL].exception &&
        o_cdb.exc_cause == i_fu_complete[riscv_pkg::FU_FP_MUL].exc_cause &&
        o_cdb.fp_flags  == i_fu_complete[riscv_pkg::FU_FP_MUL].fp_flags);
    if (o_grant[riscv_pkg::FU_FP_DIV])
      p_cdb_exc_fp_div :
      assert (
        o_cdb.exception == i_fu_complete[riscv_pkg::FU_FP_DIV].exception &&
        o_cdb.exc_cause == i_fu_complete[riscv_pkg::FU_FP_DIV].exc_cause &&
        o_cdb.fp_flags  == i_fu_complete[riscv_pkg::FU_FP_DIV].fp_flags);
  end

  // CDB fu_type matches the granted FU index (unrolled for unique Yosys labels)
  always_comb begin
    if (o_grant[riscv_pkg::FU_ALU]) p_cdb_fu_type_alu : assert (o_cdb.fu_type == riscv_pkg::FU_ALU);
    if (o_grant[riscv_pkg::FU_MUL]) p_cdb_fu_type_mul : assert (o_cdb.fu_type == riscv_pkg::FU_MUL);
    if (o_grant[riscv_pkg::FU_DIV]) p_cdb_fu_type_div : assert (o_cdb.fu_type == riscv_pkg::FU_DIV);
    if (o_grant[riscv_pkg::FU_MEM]) p_cdb_fu_type_mem : assert (o_cdb.fu_type == riscv_pkg::FU_MEM);
    if (o_grant[riscv_pkg::FU_FP_ADD])
      p_cdb_fu_type_fp_add : assert (o_cdb.fu_type == riscv_pkg::FU_FP_ADD);
    if (o_grant[riscv_pkg::FU_FP_MUL])
      p_cdb_fu_type_fp_mul : assert (o_cdb.fu_type == riscv_pkg::FU_FP_MUL);
    if (o_grant[riscv_pkg::FU_FP_DIV])
      p_cdb_fu_type_fp_div : assert (o_cdb.fu_type == riscv_pkg::FU_FP_DIV);
  end

  // -------------------------------------------------------------------------
  // Priority assertions (uses valid_vec, no array port access)
  // -------------------------------------------------------------------------

  // MEM (highest) always wins when valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_MEM]) begin
      p_priority_mem_wins : assert (o_grant[riscv_pkg::FU_MEM]);
    end
  end

  // MUL wins when valid and MEM not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_MUL] && !valid_vec[riscv_pkg::FU_MEM]) begin
      p_priority_mul_over_lower : assert (o_grant[riscv_pkg::FU_MUL]);
    end
  end

  // ALU wins when valid and MEM/MUL are not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_ALU] &&
        !valid_vec[riscv_pkg::FU_MEM] &&
        !valid_vec[riscv_pkg::FU_MUL]) begin
      p_priority_alu_over_lower : assert (o_grant[riscv_pkg::FU_ALU]);
    end
  end

  // DIV wins when valid and CoreMark-priority FUs are not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_DIV] &&
        !valid_vec[riscv_pkg::FU_MEM] &&
        !valid_vec[riscv_pkg::FU_MUL] &&
        !valid_vec[riscv_pkg::FU_ALU]) begin
      p_priority_div_over_lower : assert (o_grant[riscv_pkg::FU_DIV]);
    end
  end

  // FP_DIV wins when valid and higher-priority FUs are not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_FP_DIV] &&
        !valid_vec[riscv_pkg::FU_MEM] &&
        !valid_vec[riscv_pkg::FU_MUL] &&
        !valid_vec[riscv_pkg::FU_ALU] &&
        !valid_vec[riscv_pkg::FU_DIV]) begin
      p_priority_fp_div_over_lower : assert (o_grant[riscv_pkg::FU_FP_DIV]);
    end
  end

  // FP_MUL wins when valid and higher-priority FUs are not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_FP_MUL] &&
        !valid_vec[riscv_pkg::FU_MEM] &&
        !valid_vec[riscv_pkg::FU_MUL] &&
        !valid_vec[riscv_pkg::FU_ALU] &&
        !valid_vec[riscv_pkg::FU_DIV] &&
        !valid_vec[riscv_pkg::FU_FP_DIV]) begin
      p_priority_fp_mul_over_lower : assert (o_grant[riscv_pkg::FU_FP_MUL]);
    end
  end

  // FP_ADD wins only when it is the highest remaining valid FU
  always_comb begin
    if (valid_vec[riscv_pkg::FU_FP_ADD] &&
        !valid_vec[riscv_pkg::FU_MEM] &&
        !valid_vec[riscv_pkg::FU_MUL] &&
        !valid_vec[riscv_pkg::FU_ALU] &&
        !valid_vec[riscv_pkg::FU_DIV] &&
        !valid_vec[riscv_pkg::FU_FP_DIV] &&
        !valid_vec[riscv_pkg::FU_FP_MUL]) begin
      p_priority_fp_add_lowest : assert (o_grant[riscv_pkg::FU_FP_ADD]);
    end
  end

  // -------------------------------------------------------------------------
  // Cover properties
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // Exactly one FU valid and granted
      cover_single_fu : cover (o_cdb.valid && $onehot(o_grant));

      // All 7 FUs valid simultaneously
      cover_all_valid : cover (&valid_vec);

      // At least 2 FUs valid, lower priority loses
      cover_contention_2 : cover ($countones(valid_vec) >= 2 && o_cdb.valid);

      // No FU valid, CDB idle
      cover_no_valid : cover (!o_cdb.valid && o_grant == '0);

      // Each FU type wins at least once
      cover_grant_alu : cover (o_grant[riscv_pkg::FU_ALU]);
      cover_grant_mul : cover (o_grant[riscv_pkg::FU_MUL]);
      cover_grant_div : cover (o_grant[riscv_pkg::FU_DIV]);
      cover_grant_mem : cover (o_grant[riscv_pkg::FU_MEM]);
      cover_grant_fp_add : cover (o_grant[riscv_pkg::FU_FP_ADD]);
      cover_grant_fp_mul : cover (o_grant[riscv_pkg::FU_FP_MUL]);
      cover_grant_fp_div : cover (o_grant[riscv_pkg::FU_FP_DIV]);
    end
  end

`endif  // FORMAL

endmodule
