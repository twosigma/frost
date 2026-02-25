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
 * Priority order (longest latency first, to minimize pipeline stalls):
 *   1. FP_DIV (6) — ~32-35 cycles
 *   2. DIV   (2) — 17 cycles
 *   3. FP_MUL (5) — ~8-9 cycles
 *   4. MUL   (1) — 4 cycles
 *   5. FP_ADD (4) — ~4-5 cycles
 *   6. MEM   (3) — variable (cache hit ~1 cycle)
 *   7. ALU   (0) — combinational, can tolerate wait
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
`ifdef VERILATOR
    // Only Verilator supports unpacked arrays of packed structs as ports.
    input riscv_pkg::fu_complete_t i_fu_complete  [riscv_pkg::NumFus],
`else
    // Icarus and Yosys (synthesis/formal) need flattened individual ports.
    input riscv_pkg::fu_complete_t i_fu_complete_0,
    input riscv_pkg::fu_complete_t i_fu_complete_1,
    input riscv_pkg::fu_complete_t i_fu_complete_2,
    input riscv_pkg::fu_complete_t i_fu_complete_3,
    input riscv_pkg::fu_complete_t i_fu_complete_4,
    input riscv_pkg::fu_complete_t i_fu_complete_5,
    input riscv_pkg::fu_complete_t i_fu_complete_6,
`endif

    // CDB broadcast output (to RS wakeup + ROB write)
    output riscv_pkg::cdb_broadcast_t o_cdb,

    // Per-FU grant signals (back-pressure: FU can clear result when granted)
    output logic [riscv_pkg::NumFus-1:0] o_grant
);

  // Valid vector for convenience (used by formal assertions)
  logic                    [riscv_pkg::NumFus-1:0] valid_vec;

  // Fixed-priority encoder: longest-latency FU wins.
  // Priority: FP_DIV > DIV > FP_MUL > MUL > FP_ADD > MEM > ALU
  logic                                            found;
  logic                    [                  2:0] winner_idx;
  riscv_pkg::fu_complete_t                         winner_data;

`ifdef VERILATOR
  // Use unpacked array port directly (this path is active under VERILATOR)
  always_comb begin
    for (int i = 0; i < riscv_pkg::NumFus; i++) begin
      valid_vec[i] = i_fu_complete[i].valid;
    end
  end

  always_comb begin
    found       = 1'b0;
    winner_idx  = 3'd0;
    winner_data = '0;
    o_grant     = '0;

    if (i_fu_complete[riscv_pkg::FU_FP_DIV].valid) begin
      found                         = 1'b1;
      winner_idx                    = riscv_pkg::FU_FP_DIV;
      winner_data                   = i_fu_complete[riscv_pkg::FU_FP_DIV];
      o_grant[riscv_pkg::FU_FP_DIV] = 1'b1;
    end else if (i_fu_complete[riscv_pkg::FU_DIV].valid) begin
      found                      = 1'b1;
      winner_idx                 = riscv_pkg::FU_DIV;
      winner_data                = i_fu_complete[riscv_pkg::FU_DIV];
      o_grant[riscv_pkg::FU_DIV] = 1'b1;
    end else if (i_fu_complete[riscv_pkg::FU_FP_MUL].valid) begin
      found                         = 1'b1;
      winner_idx                    = riscv_pkg::FU_FP_MUL;
      winner_data                   = i_fu_complete[riscv_pkg::FU_FP_MUL];
      o_grant[riscv_pkg::FU_FP_MUL] = 1'b1;
    end else if (i_fu_complete[riscv_pkg::FU_MUL].valid) begin
      found                      = 1'b1;
      winner_idx                 = riscv_pkg::FU_MUL;
      winner_data                = i_fu_complete[riscv_pkg::FU_MUL];
      o_grant[riscv_pkg::FU_MUL] = 1'b1;
    end else if (i_fu_complete[riscv_pkg::FU_FP_ADD].valid) begin
      found                         = 1'b1;
      winner_idx                    = riscv_pkg::FU_FP_ADD;
      winner_data                   = i_fu_complete[riscv_pkg::FU_FP_ADD];
      o_grant[riscv_pkg::FU_FP_ADD] = 1'b1;
    end else if (i_fu_complete[riscv_pkg::FU_MEM].valid) begin
      found                      = 1'b1;
      winner_idx                 = riscv_pkg::FU_MEM;
      winner_data                = i_fu_complete[riscv_pkg::FU_MEM];
      o_grant[riscv_pkg::FU_MEM] = 1'b1;
    end else if (i_fu_complete[riscv_pkg::FU_ALU].valid) begin
      found                      = 1'b1;
      winner_idx                 = riscv_pkg::FU_ALU;
      winner_data                = i_fu_complete[riscv_pkg::FU_ALU];
      o_grant[riscv_pkg::FU_ALU] = 1'b1;
    end
  end
`else
  // Icarus / Yosys (synthesis + formal): reference individual port names
  always_comb begin
    valid_vec[0] = i_fu_complete_0.valid;
    valid_vec[1] = i_fu_complete_1.valid;
    valid_vec[2] = i_fu_complete_2.valid;
    valid_vec[3] = i_fu_complete_3.valid;
    valid_vec[4] = i_fu_complete_4.valid;
    valid_vec[5] = i_fu_complete_5.valid;
    valid_vec[6] = i_fu_complete_6.valid;
  end

  always_comb begin
    found       = 1'b0;
    winner_idx  = 3'd0;
    winner_data = '0;
    o_grant     = '0;

    if (i_fu_complete_6.valid) begin  // FP_DIV
      found                         = 1'b1;
      winner_idx                    = riscv_pkg::FU_FP_DIV;
      winner_data                   = i_fu_complete_6;
      o_grant[riscv_pkg::FU_FP_DIV] = 1'b1;
    end else if (i_fu_complete_2.valid) begin  // DIV
      found                      = 1'b1;
      winner_idx                 = riscv_pkg::FU_DIV;
      winner_data                = i_fu_complete_2;
      o_grant[riscv_pkg::FU_DIV] = 1'b1;
    end else if (i_fu_complete_5.valid) begin  // FP_MUL
      found                         = 1'b1;
      winner_idx                    = riscv_pkg::FU_FP_MUL;
      winner_data                   = i_fu_complete_5;
      o_grant[riscv_pkg::FU_FP_MUL] = 1'b1;
    end else if (i_fu_complete_1.valid) begin  // MUL
      found                      = 1'b1;
      winner_idx                 = riscv_pkg::FU_MUL;
      winner_data                = i_fu_complete_1;
      o_grant[riscv_pkg::FU_MUL] = 1'b1;
    end else if (i_fu_complete_4.valid) begin  // FP_ADD
      found                         = 1'b1;
      winner_idx                    = riscv_pkg::FU_FP_ADD;
      winner_data                   = i_fu_complete_4;
      o_grant[riscv_pkg::FU_FP_ADD] = 1'b1;
    end else if (i_fu_complete_3.valid) begin  // MEM
      found                      = 1'b1;
      winner_idx                 = riscv_pkg::FU_MEM;
      winner_data                = i_fu_complete_3;
      o_grant[riscv_pkg::FU_MEM] = 1'b1;
    end else if (i_fu_complete_0.valid) begin  // ALU
      found                      = 1'b1;
      winner_idx                 = riscv_pkg::FU_ALU;
      winner_data                = i_fu_complete_0;
      o_grant[riscv_pkg::FU_ALU] = 1'b1;
    end
  end
`endif

  // Pack CDB output
  always_comb begin
    o_cdb.valid     = found;
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

  // CDB tag matches granted FU (unrolled for flattened ports)
  always_comb begin
    if (o_grant[riscv_pkg::FU_ALU]) p_cdb_tag_alu : assert (o_cdb.tag == i_fu_complete_0.tag);
    if (o_grant[riscv_pkg::FU_MUL]) p_cdb_tag_mul : assert (o_cdb.tag == i_fu_complete_1.tag);
    if (o_grant[riscv_pkg::FU_DIV]) p_cdb_tag_div : assert (o_cdb.tag == i_fu_complete_2.tag);
    if (o_grant[riscv_pkg::FU_MEM]) p_cdb_tag_mem : assert (o_cdb.tag == i_fu_complete_3.tag);
    if (o_grant[riscv_pkg::FU_FP_ADD]) p_cdb_tag_fp_add : assert (o_cdb.tag == i_fu_complete_4.tag);
    if (o_grant[riscv_pkg::FU_FP_MUL]) p_cdb_tag_fp_mul : assert (o_cdb.tag == i_fu_complete_5.tag);
    if (o_grant[riscv_pkg::FU_FP_DIV]) p_cdb_tag_fp_div : assert (o_cdb.tag == i_fu_complete_6.tag);
  end

  // CDB value matches granted FU (unrolled for flattened ports)
  always_comb begin
    if (o_grant[riscv_pkg::FU_ALU]) p_cdb_value_alu : assert (o_cdb.value == i_fu_complete_0.value);
    if (o_grant[riscv_pkg::FU_MUL]) p_cdb_value_mul : assert (o_cdb.value == i_fu_complete_1.value);
    if (o_grant[riscv_pkg::FU_DIV]) p_cdb_value_div : assert (o_cdb.value == i_fu_complete_2.value);
    if (o_grant[riscv_pkg::FU_MEM]) p_cdb_value_mem : assert (o_cdb.value == i_fu_complete_3.value);
    if (o_grant[riscv_pkg::FU_FP_ADD])
      p_cdb_value_fp_add : assert (o_cdb.value == i_fu_complete_4.value);
    if (o_grant[riscv_pkg::FU_FP_MUL])
      p_cdb_value_fp_mul : assert (o_cdb.value == i_fu_complete_5.value);
    if (o_grant[riscv_pkg::FU_FP_DIV])
      p_cdb_value_fp_div : assert (o_cdb.value == i_fu_complete_6.value);
  end

  // CDB exception fields match granted FU (unrolled for flattened ports)
  always_comb begin
    if (o_grant[riscv_pkg::FU_ALU])
      p_cdb_exc_alu :
      assert (
        o_cdb.exception == i_fu_complete_0.exception &&
        o_cdb.exc_cause == i_fu_complete_0.exc_cause &&
        o_cdb.fp_flags  == i_fu_complete_0.fp_flags);
    if (o_grant[riscv_pkg::FU_MUL])
      p_cdb_exc_mul :
      assert (
        o_cdb.exception == i_fu_complete_1.exception &&
        o_cdb.exc_cause == i_fu_complete_1.exc_cause &&
        o_cdb.fp_flags  == i_fu_complete_1.fp_flags);
    if (o_grant[riscv_pkg::FU_DIV])
      p_cdb_exc_div :
      assert (
        o_cdb.exception == i_fu_complete_2.exception &&
        o_cdb.exc_cause == i_fu_complete_2.exc_cause &&
        o_cdb.fp_flags  == i_fu_complete_2.fp_flags);
    if (o_grant[riscv_pkg::FU_MEM])
      p_cdb_exc_mem :
      assert (
        o_cdb.exception == i_fu_complete_3.exception &&
        o_cdb.exc_cause == i_fu_complete_3.exc_cause &&
        o_cdb.fp_flags  == i_fu_complete_3.fp_flags);
    if (o_grant[riscv_pkg::FU_FP_ADD])
      p_cdb_exc_fp_add :
      assert (
        o_cdb.exception == i_fu_complete_4.exception &&
        o_cdb.exc_cause == i_fu_complete_4.exc_cause &&
        o_cdb.fp_flags  == i_fu_complete_4.fp_flags);
    if (o_grant[riscv_pkg::FU_FP_MUL])
      p_cdb_exc_fp_mul :
      assert (
        o_cdb.exception == i_fu_complete_5.exception &&
        o_cdb.exc_cause == i_fu_complete_5.exc_cause &&
        o_cdb.fp_flags  == i_fu_complete_5.fp_flags);
    if (o_grant[riscv_pkg::FU_FP_DIV])
      p_cdb_exc_fp_div :
      assert (
        o_cdb.exception == i_fu_complete_6.exception &&
        o_cdb.exc_cause == i_fu_complete_6.exc_cause &&
        o_cdb.fp_flags  == i_fu_complete_6.fp_flags);
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

  // FP_DIV (highest) always wins when valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_FP_DIV]) begin
      p_priority_fp_div_wins : assert (o_grant[riscv_pkg::FU_FP_DIV]);
    end
  end

  // DIV wins when valid and FP_DIV not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_DIV] && !valid_vec[riscv_pkg::FU_FP_DIV]) begin
      p_priority_div_over_lower : assert (o_grant[riscv_pkg::FU_DIV]);
    end
  end

  // FP_MUL wins when valid and higher-priority not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_FP_MUL] &&
        !valid_vec[riscv_pkg::FU_FP_DIV] &&
        !valid_vec[riscv_pkg::FU_DIV]) begin
      p_priority_fp_mul_over_lower : assert (o_grant[riscv_pkg::FU_FP_MUL]);
    end
  end

  // MUL wins when valid and higher-priority not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_MUL] &&
        !valid_vec[riscv_pkg::FU_FP_DIV] &&
        !valid_vec[riscv_pkg::FU_DIV] &&
        !valid_vec[riscv_pkg::FU_FP_MUL]) begin
      p_priority_mul_over_lower : assert (o_grant[riscv_pkg::FU_MUL]);
    end
  end

  // FP_ADD wins when valid and higher-priority not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_FP_ADD] &&
        !valid_vec[riscv_pkg::FU_FP_DIV] &&
        !valid_vec[riscv_pkg::FU_DIV] &&
        !valid_vec[riscv_pkg::FU_FP_MUL] &&
        !valid_vec[riscv_pkg::FU_MUL]) begin
      p_priority_fp_add_over_lower : assert (o_grant[riscv_pkg::FU_FP_ADD]);
    end
  end

  // MEM wins when valid and higher-priority not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_MEM] &&
        !valid_vec[riscv_pkg::FU_FP_DIV] &&
        !valid_vec[riscv_pkg::FU_DIV] &&
        !valid_vec[riscv_pkg::FU_FP_MUL] &&
        !valid_vec[riscv_pkg::FU_MUL] &&
        !valid_vec[riscv_pkg::FU_FP_ADD]) begin
      p_priority_mem_over_alu : assert (o_grant[riscv_pkg::FU_MEM]);
    end
  end

  // ALU wins only when it's the sole valid FU
  always_comb begin
    if (valid_vec[riscv_pkg::FU_ALU] &&
        !valid_vec[riscv_pkg::FU_FP_DIV] &&
        !valid_vec[riscv_pkg::FU_DIV] &&
        !valid_vec[riscv_pkg::FU_FP_MUL] &&
        !valid_vec[riscv_pkg::FU_MUL] &&
        !valid_vec[riscv_pkg::FU_FP_ADD] &&
        !valid_vec[riscv_pkg::FU_MEM]) begin
      p_priority_alu_lowest : assert (o_grant[riscv_pkg::FU_ALU]);
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
