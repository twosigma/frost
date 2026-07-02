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
 * Priority-based multiplexer that selects up to two functional unit results
 * per cycle (2-wide CDB: primary o_cdb + secondary o_cdb_2) for broadcast on
 * the Common Data Bus (CDB). Ties FU completions back to:
 *   - ROB (mark done + store value)
 *   - All RS instances (operand wakeup)
 *
 * Priority order favors integer traffic without putting FP/div valid cones
 * ahead of the CoreMark-critical grants:
 *   1. MUL   (1) — integer multiply
 *   2. MEM   (3) — load/SC results
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

    // Second CDB broadcast lane (secondary winner). Same semantics as o_cdb;
    // carries the highest-priority FU result that lane 0 did not take this
    // cycle. valid=0 when fewer than two FUs request the CDB.
    output riscv_pkg::cdb_broadcast_t o_cdb_2,

    // Per-FU grant signals (back-pressure: FU can clear result when granted).
    // 2-wide CDB: up to two bits may be set (lane-0 + lane-1 winners).
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

  // Valid vector for convenience (used by formal assertions)
  logic                    [riscv_pkg::NumFus-1:0] valid_vec;

  // Fixed-priority encoder, lane 0 (primary).
  // Priority: MUL > MEM > ALU > DIV > FP_DIV > FP_MUL > FP_ADD
  logic                                            found;
  logic                    [                  2:0] winner_idx;
  riscv_pkg::fu_complete_t                         winner_data;
  logic                    [riscv_pkg::NumFus-1:0] g0_raw;

  // Lane 1 (secondary): highest-priority requester lane 0 did not take.
  logic                                            found2;
  logic                    [                  2:0] winner2_idx;
  riscv_pkg::fu_complete_t                         winner2_data;
  logic                    [riscv_pkg::NumFus-1:0] g1_raw;
  // Per-FU "valid and not granted by lane 0", input to the lane-1 encoder.
  logic                    [riscv_pkg::NumFus-1:0] avail1;

  always_comb begin
    valid_vec[riscv_pkg::FU_ALU]    = i_fu_complete_0.valid;
    valid_vec[riscv_pkg::FU_MUL]    = i_fu_complete_1.valid;
    valid_vec[riscv_pkg::FU_DIV]    = i_fu_complete_2.valid;
    valid_vec[riscv_pkg::FU_MEM]    = i_fu_complete_3.valid;
    valid_vec[riscv_pkg::FU_FP_ADD] = i_fu_complete_4.valid;
    valid_vec[riscv_pkg::FU_FP_MUL] = i_fu_complete_5.valid;
    valid_vec[riscv_pkg::FU_FP_DIV] = i_fu_complete_6.valid;
  end

  always_comb begin
    found       = 1'b0;
    winner_idx  = 3'd0;
    winner_data = '0;
    g0_raw      = '0;

    if (i_fu_complete_1.valid) begin
      found                     = 1'b1;
      winner_idx                = riscv_pkg::FU_MUL;
      winner_data               = i_fu_complete_1;
      g0_raw[riscv_pkg::FU_MUL] = 1'b1;
    end else if (i_fu_complete_3.valid) begin
      found                     = 1'b1;
      winner_idx                = riscv_pkg::FU_MEM;
      winner_data               = i_fu_complete_3;
      g0_raw[riscv_pkg::FU_MEM] = 1'b1;
    end else if (i_fu_complete_0.valid) begin
      found                     = 1'b1;
      winner_idx                = riscv_pkg::FU_ALU;
      winner_data               = i_fu_complete_0;
      g0_raw[riscv_pkg::FU_ALU] = 1'b1;
    end else if (i_fu_complete_2.valid) begin
      found                     = 1'b1;
      winner_idx                = riscv_pkg::FU_DIV;
      winner_data               = i_fu_complete_2;
      g0_raw[riscv_pkg::FU_DIV] = 1'b1;
    end else if (i_fu_complete_6.valid) begin
      found                        = 1'b1;
      winner_idx                   = riscv_pkg::FU_FP_DIV;
      winner_data                  = i_fu_complete_6;
      g0_raw[riscv_pkg::FU_FP_DIV] = 1'b1;
    end else if (i_fu_complete_5.valid) begin
      found                        = 1'b1;
      winner_idx                   = riscv_pkg::FU_FP_MUL;
      winner_data                  = i_fu_complete_5;
      g0_raw[riscv_pkg::FU_FP_MUL] = 1'b1;
    end else if (i_fu_complete_4.valid) begin
      found                        = 1'b1;
      winner_idx                   = riscv_pkg::FU_FP_ADD;
      winner_data                  = i_fu_complete_4;
      g0_raw[riscv_pkg::FU_FP_ADD] = 1'b1;
    end
  end

  // Lane-1 candidates: each FU's valid minus whatever lane 0 granted.
  always_comb begin
    avail1[riscv_pkg::FU_ALU]    = i_fu_complete_0.valid && !g0_raw[riscv_pkg::FU_ALU];
    avail1[riscv_pkg::FU_MUL]    = i_fu_complete_1.valid && !g0_raw[riscv_pkg::FU_MUL];
    avail1[riscv_pkg::FU_DIV]    = i_fu_complete_2.valid && !g0_raw[riscv_pkg::FU_DIV];
    avail1[riscv_pkg::FU_MEM]    = i_fu_complete_3.valid && !g0_raw[riscv_pkg::FU_MEM];
    avail1[riscv_pkg::FU_FP_ADD] = i_fu_complete_4.valid && !g0_raw[riscv_pkg::FU_FP_ADD];
    avail1[riscv_pkg::FU_FP_MUL] = i_fu_complete_5.valid && !g0_raw[riscv_pkg::FU_FP_MUL];
    avail1[riscv_pkg::FU_FP_DIV] = i_fu_complete_6.valid && !g0_raw[riscv_pkg::FU_FP_DIV];
  end

  // Lane-1 priority encoder (same priority order as lane 0, over avail1).
  always_comb begin
    found2       = 1'b0;
    winner2_idx  = 3'd0;
    winner2_data = '0;
    g1_raw       = '0;

    if (avail1[riscv_pkg::FU_MUL]) begin
      found2                    = 1'b1;
      winner2_idx               = riscv_pkg::FU_MUL;
      winner2_data              = i_fu_complete_1;
      g1_raw[riscv_pkg::FU_MUL] = 1'b1;
    end else if (avail1[riscv_pkg::FU_MEM]) begin
      found2                    = 1'b1;
      winner2_idx               = riscv_pkg::FU_MEM;
      winner2_data              = i_fu_complete_3;
      g1_raw[riscv_pkg::FU_MEM] = 1'b1;
    end else if (avail1[riscv_pkg::FU_ALU]) begin
      found2                    = 1'b1;
      winner2_idx               = riscv_pkg::FU_ALU;
      winner2_data              = i_fu_complete_0;
      g1_raw[riscv_pkg::FU_ALU] = 1'b1;
    end else if (avail1[riscv_pkg::FU_DIV]) begin
      found2                    = 1'b1;
      winner2_idx               = riscv_pkg::FU_DIV;
      winner2_data              = i_fu_complete_2;
      g1_raw[riscv_pkg::FU_DIV] = 1'b1;
    end else if (avail1[riscv_pkg::FU_FP_DIV]) begin
      found2                       = 1'b1;
      winner2_idx                  = riscv_pkg::FU_FP_DIV;
      winner2_data                 = i_fu_complete_6;
      g1_raw[riscv_pkg::FU_FP_DIV] = 1'b1;
    end else if (avail1[riscv_pkg::FU_FP_MUL]) begin
      found2                       = 1'b1;
      winner2_idx                  = riscv_pkg::FU_FP_MUL;
      winner2_data                 = i_fu_complete_5;
      g1_raw[riscv_pkg::FU_FP_MUL] = 1'b1;
    end else if (avail1[riscv_pkg::FU_FP_ADD]) begin
      found2                       = 1'b1;
      winner2_idx                  = riscv_pkg::FU_FP_ADD;
      winner2_data                 = i_fu_complete_4;
      g1_raw[riscv_pkg::FU_FP_ADD] = 1'b1;
    end
  end

  // Pre-kill grant (both lanes). 2-hot when two FUs are granted this cycle.
  assign o_grant_raw = g0_raw | g1_raw;

  // Kill-gated grant: suppress CDB broadcast and adapter grant when in
  // speculative full-flush recovery. o_grant_raw is the pre-kill version.
  always_comb begin
    if (i_kill) begin
      o_grant = '0;
    end else begin
      o_grant = g0_raw | g1_raw;
    end
  end

  // Pack lane-0 CDB output. Suppressed during kill (speculative full-flush).
  always_comb begin
    o_cdb.valid     = found && !i_kill;
    o_cdb.tag       = winner_data.tag;
    o_cdb.value     = winner_data.value;
    o_cdb.exception = winner_data.exception;
    o_cdb.exc_cause = winner_data.exc_cause;
    o_cdb.fp_flags  = winner_data.fp_flags;
    o_cdb.fu_type   = riscv_pkg::fu_type_e'(winner_idx);
  end

  // Pack lane-1 CDB output. Suppressed during kill.
  always_comb begin
    o_cdb_2.valid     = found2 && !i_kill;
    o_cdb_2.tag       = winner2_data.tag;
    o_cdb_2.value     = winner2_data.value;
    o_cdb_2.exception = winner2_data.exception;
    o_cdb_2.exc_cause = winner2_data.exc_cause;
    o_cdb_2.fp_flags  = winner2_data.fp_flags;
    o_cdb_2.fu_type   = riscv_pkg::fu_type_e'(winner2_idx);
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

  // 2-wide CDB: up to two FUs (lane-0 primary + lane-1 secondary) granted
  // per cycle.  Each lane is independently one-hot-or-zero, the two lanes are
  // disjoint, and lane-1 only grants when lane-0 also grants (the secondary
  // encoder picks from the FUs lane-0 left ungranted).
  always_comb begin
    p_grant_at_most_two : assert ($countones(o_grant) <= 2);
    p_grant_lane0_onehot0 : assert ($onehot0(g0_raw));
    p_grant_lane1_onehot0 : assert ($onehot0(g1_raw));
    p_grant_lanes_disjoint : assert ((g0_raw & g1_raw) == '0);
    p_grant_lane1_implies_lane0 : assert (!(|g1_raw) || (|g0_raw));
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
    if (o_grant[riscv_pkg::FU_ALU]) p_cdb_tag_alu : assert (o_cdb.tag == winner_data.tag);
    if (o_grant[riscv_pkg::FU_MUL]) p_cdb_tag_mul : assert (o_cdb.tag == winner_data.tag);
    if (o_grant[riscv_pkg::FU_DIV]) p_cdb_tag_div : assert (o_cdb.tag == winner_data.tag);
    if (o_grant[riscv_pkg::FU_MEM]) p_cdb_tag_mem : assert (o_cdb.tag == winner_data.tag);
    if (o_grant[riscv_pkg::FU_FP_ADD]) p_cdb_tag_fp_add : assert (o_cdb.tag == winner_data.tag);
    if (o_grant[riscv_pkg::FU_FP_MUL]) p_cdb_tag_fp_mul : assert (o_cdb.tag == winner_data.tag);
    if (o_grant[riscv_pkg::FU_FP_DIV]) p_cdb_tag_fp_div : assert (o_cdb.tag == winner_data.tag);
  end

  // CDB value matches granted FU
  always_comb begin
    if (o_grant[riscv_pkg::FU_ALU]) p_cdb_value_alu : assert (o_cdb.value == winner_data.value);
    if (o_grant[riscv_pkg::FU_MUL]) p_cdb_value_mul : assert (o_cdb.value == winner_data.value);
    if (o_grant[riscv_pkg::FU_DIV]) p_cdb_value_div : assert (o_cdb.value == winner_data.value);
    if (o_grant[riscv_pkg::FU_MEM]) p_cdb_value_mem : assert (o_cdb.value == winner_data.value);
    if (o_grant[riscv_pkg::FU_FP_ADD])
      p_cdb_value_fp_add : assert (o_cdb.value == winner_data.value);
    if (o_grant[riscv_pkg::FU_FP_MUL])
      p_cdb_value_fp_mul : assert (o_cdb.value == winner_data.value);
    if (o_grant[riscv_pkg::FU_FP_DIV])
      p_cdb_value_fp_div : assert (o_cdb.value == winner_data.value);
  end

  // CDB exception fields match granted FU
  always_comb begin
    if (o_grant[riscv_pkg::FU_ALU])
      p_cdb_exc_alu :
      assert (
        o_cdb.exception == winner_data.exception &&
        o_cdb.exc_cause == winner_data.exc_cause &&
        o_cdb.fp_flags  == winner_data.fp_flags);
    if (o_grant[riscv_pkg::FU_MUL])
      p_cdb_exc_mul :
      assert (
        o_cdb.exception == winner_data.exception &&
        o_cdb.exc_cause == winner_data.exc_cause &&
        o_cdb.fp_flags  == winner_data.fp_flags);
    if (o_grant[riscv_pkg::FU_DIV])
      p_cdb_exc_div :
      assert (
        o_cdb.exception == winner_data.exception &&
        o_cdb.exc_cause == winner_data.exc_cause &&
        o_cdb.fp_flags  == winner_data.fp_flags);
    if (o_grant[riscv_pkg::FU_MEM])
      p_cdb_exc_mem :
      assert (
        o_cdb.exception == winner_data.exception &&
        o_cdb.exc_cause == winner_data.exc_cause &&
        o_cdb.fp_flags  == winner_data.fp_flags);
    if (o_grant[riscv_pkg::FU_FP_ADD])
      p_cdb_exc_fp_add :
      assert (
        o_cdb.exception == winner_data.exception &&
        o_cdb.exc_cause == winner_data.exc_cause &&
        o_cdb.fp_flags  == winner_data.fp_flags);
    if (o_grant[riscv_pkg::FU_FP_MUL])
      p_cdb_exc_fp_mul :
      assert (
        o_cdb.exception == winner_data.exception &&
        o_cdb.exc_cause == winner_data.exc_cause &&
        o_cdb.fp_flags  == winner_data.fp_flags);
    if (o_grant[riscv_pkg::FU_FP_DIV])
      p_cdb_exc_fp_div :
      assert (
        o_cdb.exception == winner_data.exception &&
        o_cdb.exc_cause == winner_data.exc_cause &&
        o_cdb.fp_flags  == winner_data.fp_flags);
  end

  // CDB fu_type matches the granted FU index (unrolled for unique Yosys labels).
  // 2-wide CDB: a granted FU is broadcasting on lane-0 OR lane-1 this cycle, so
  // its fu_type must match on whichever lane carries it (not solely lane-0).
  function automatic logic fu_on_a_lane(input riscv_pkg::fu_type_e fu);
    fu_on_a_lane = (o_cdb.valid && o_cdb.fu_type == fu) || (o_cdb_2.valid && o_cdb_2.fu_type == fu);
  endfunction
  always_comb begin
    if (o_grant[riscv_pkg::FU_ALU]) p_cdb_fu_type_alu : assert (fu_on_a_lane(riscv_pkg::FU_ALU));
    if (o_grant[riscv_pkg::FU_MUL]) p_cdb_fu_type_mul : assert (fu_on_a_lane(riscv_pkg::FU_MUL));
    if (o_grant[riscv_pkg::FU_DIV]) p_cdb_fu_type_div : assert (fu_on_a_lane(riscv_pkg::FU_DIV));
    if (o_grant[riscv_pkg::FU_MEM]) p_cdb_fu_type_mem : assert (fu_on_a_lane(riscv_pkg::FU_MEM));
    if (o_grant[riscv_pkg::FU_FP_ADD])
      p_cdb_fu_type_fp_add : assert (fu_on_a_lane(riscv_pkg::FU_FP_ADD));
    if (o_grant[riscv_pkg::FU_FP_MUL])
      p_cdb_fu_type_fp_mul : assert (fu_on_a_lane(riscv_pkg::FU_FP_MUL));
    if (o_grant[riscv_pkg::FU_FP_DIV])
      p_cdb_fu_type_fp_div : assert (fu_on_a_lane(riscv_pkg::FU_FP_DIV));
  end

  // Lane-1 broadcast is consistent: when valid it carries its selected
  // secondary winner's payload and a distinct FU from lane 0.
  always_comb begin
    if (o_cdb_2.valid) begin
      p_cdb2_fu_type : assert (o_cdb_2.fu_type == riscv_pkg::fu_type_e'(winner2_idx));
      p_cdb2_tag : assert (o_cdb_2.tag == winner2_data.tag);
      p_cdb2_value : assert (o_cdb_2.value == winner2_data.value);
      p_cdb2_distinct_from_lane0 : assert (!o_cdb.valid || (winner2_idx != winner_idx));
      p_cdb2_implies_lane0 : assert (o_cdb.valid);
    end
  end

  // -------------------------------------------------------------------------
  // Priority assertions (uses valid_vec, no array port access)
  // -------------------------------------------------------------------------

  // MUL (highest) always wins when valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_MUL]) begin
      p_priority_mul_wins : assert (o_grant_raw[riscv_pkg::FU_MUL]);
    end
  end

  // MEM wins when valid and MUL not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_MEM] && !valid_vec[riscv_pkg::FU_MUL]) begin
      p_priority_mem_over_lower : assert (o_grant_raw[riscv_pkg::FU_MEM]);
    end
  end

  // ALU wins when valid and MUL/MEM are not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_ALU] &&
        !valid_vec[riscv_pkg::FU_MUL] &&
        !valid_vec[riscv_pkg::FU_MEM]) begin
      p_priority_alu_over_lower : assert (o_grant_raw[riscv_pkg::FU_ALU]);
    end
  end

  // DIV wins when valid and CoreMark-priority FUs are not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_DIV] &&
        !valid_vec[riscv_pkg::FU_MUL] &&
        !valid_vec[riscv_pkg::FU_MEM] &&
        !valid_vec[riscv_pkg::FU_ALU]) begin
      p_priority_div_over_lower : assert (o_grant_raw[riscv_pkg::FU_DIV]);
    end
  end

  // FP_DIV wins when valid and higher-priority FUs are not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_FP_DIV] &&
        !valid_vec[riscv_pkg::FU_MUL] &&
        !valid_vec[riscv_pkg::FU_MEM] &&
        !valid_vec[riscv_pkg::FU_ALU] &&
        !valid_vec[riscv_pkg::FU_DIV]) begin
      p_priority_fp_div_over_lower : assert (o_grant_raw[riscv_pkg::FU_FP_DIV]);
    end
  end

  // FP_MUL wins when valid and higher-priority FUs are not valid
  always_comb begin
    if (valid_vec[riscv_pkg::FU_FP_MUL] &&
        !valid_vec[riscv_pkg::FU_MUL] &&
        !valid_vec[riscv_pkg::FU_MEM] &&
        !valid_vec[riscv_pkg::FU_ALU] &&
        !valid_vec[riscv_pkg::FU_DIV] &&
        !valid_vec[riscv_pkg::FU_FP_DIV]) begin
      p_priority_fp_mul_over_lower : assert (o_grant_raw[riscv_pkg::FU_FP_MUL]);
    end
  end

  // FP_ADD wins only when it is the highest remaining valid FU
  always_comb begin
    if (valid_vec[riscv_pkg::FU_FP_ADD] &&
        !valid_vec[riscv_pkg::FU_MUL] &&
        !valid_vec[riscv_pkg::FU_MEM] &&
        !valid_vec[riscv_pkg::FU_ALU] &&
        !valid_vec[riscv_pkg::FU_DIV] &&
        !valid_vec[riscv_pkg::FU_FP_DIV] &&
        !valid_vec[riscv_pkg::FU_FP_MUL]) begin
      p_priority_fp_add_lowest : assert (o_grant_raw[riscv_pkg::FU_FP_ADD]);
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
