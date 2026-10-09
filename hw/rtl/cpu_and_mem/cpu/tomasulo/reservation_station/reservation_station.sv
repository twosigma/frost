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
 * Parameterized reservation station. The wrapper's instances use these depths:
 *   INT_RS=16 (riscv_pkg::IntRsDepth; port 1 considers only the lowest 8),
 *   MUL_RS=4, MEM_RS=8, FP_RS=2 (riscv_pkg::FpRsDepth)
 *
 * Sources wake from either CDB lane or from done repair. A CDB match in the
 * dispatch cycle is delivered one cycle later from registered lane values,
 * keeping live CDB data and compares off the dispatch writes. Optional
 * allocation-indexed repair avoids comparing repair tags against every
 * resident entry. Port 0 issues the lowest ready index; DUAL_ISSUE (INT_RS)
 * adds port 1, which issues the lowest ready non-branch entry other than port
 * 0's pick, with its own payload RAM copy and stage2 register. Optional src3
 * supports FMA. Partial and full flushes clear validity.
 *
 * Control and source fields stay in FFs for parallel wakeup and flush scans.
 * Dispatch payloads use two-write-port distributed RAM and are read at issue;
 * the FF valid bits make stale RAM contents harmless. The INT instance keeps
 * the XLEN-wide pc, link address and predicted target in a ROB-tag-indexed
 * side RAM read behind its port-0 stage2 tag (TAG_INDEXED_BRANCH_PAYLOAD), so
 * the per-entry payload and both stage2 banks carry no XLEN branch words.
 */

module reservation_station #(
    parameter int unsigned DEPTH = 8,
    parameter bit HAS_SRC3 = 1'b1,
    // Precompute lookahead winners for both CDB lane-valid bits.
    parameter bit PREISSUE_VALID_COFACTOR = 1'b0,
    // MEM_RS: precompute the winner for each combination of the two raw CDB
    // lane valids and the early-load token (eight candidates).
    parameter bit PREISSUE_RAW_WAKEUP = 1'b0,
    // With PREISSUE_VALID_COFACTOR, export candidate ready vectors and entry
    // ROB tags so the LQ can match tags before selecting the ready winner.
    parameter bit PREISSUE_READY_EXPORT = 1'b0,
    parameter bit DISPATCH_REPAIR_BYPASS = 1'b1,
    parameter bit ISSUE_REPAIR_BYPASS = 1'b1,
    // Route repair channels 1-3 to slot 1's saved allocation index and
    // channels 4-6 to slot 2's, one cycle after dispatch. This replaces the
    // resident tag scan without changing wakeup timing. Requires both
    // DISPATCH_REPAIR_BYPASS and ISSUE_REPAIR_BYPASS to be disabled.
    parameter bit ALLOC_INDEXED_REPAIR = 1'b0,
    parameter bit TRACK_INT_WRITEBACK_HINT = 1'b0,
    parameter bit SPECULATIVE_DATA_WRITES = 1'b0,
    // With speculative writes, prefill free entries with slot-1 source values
    // and put slot-2 values at its allocation target. Only rs_valid makes
    // these values observable. alloc_sel_2 selects slot 2 directly from
    // rs_valid and must equal the alloc_idx_2 decode for every free entry.
    parameter bit BROADCAST_FREE_SOURCE_VALUES = 1'b0,
    // Duplicate src1/src2 tags for issue-time CDB compares. Speculative writes
    // complement a slot's tags when it does not target this RS, preventing
    // register merging. Committed writes use normal tags, so both banks must
    // match for every valid entry.
    parameter bit ISSUE_CDB_TAG_SHADOW = 1'b0,
    // Use separate registered CDB valid/tag copies for issue bypass. Resident
    // wakeup and deferred capture still use i_cdb and i_cdb_2, as does issue
    // bypass when disabled.
    parameter bit ISSUE_CDB_META_ANCHORS = 1'b0,
    // Capture port 0's final src1/src2 operands in stage2, including CDB and
    // repair bypasses, as port 1 does. Requires HAS_SRC3=0. When disabled,
    // stage2 stores resident or repair values and masks for a later CDB mux.
    parameter bit CAPTURE_PRIMARY_EFFECTIVE_OPERANDS = 1'b0,
    // INT only: duplicate stage2_rob_tag, with the same value and enable,
    // for branch checkpoint and age compares, to reduce fanout.
    parameter bit BRANCH_PREDICATE_TAG_ANCHOR = 1'b0,
    parameter bit TRUST_DISPATCH_VALID = 1'b0,
    // Reserve entries when reporting dispatch capacity from the previous
    // occupancy. Zero uses exact count_next; nonzero values permit
    // conservative registered status without current dispatch inputs.
    parameter int unsigned DISPATCH_STATUS_RESERVE = 0,
    // INT only: add an independent selector, payload RAM and stage2 bank for
    // the lowest ready nonbranch entry other than port 0's pick. Branches
    // stay on port 0, which has the branch-resolution path.
    parameter bit DUAL_ISSUE = 1'b0,
    // Limit port 1 to entries [0, ISSUE2_WINDOW); 0 or a value above DEPTH
    // selects the whole station. Port 0 sees every entry. Lowest-free
    // allocation fills the window first.
    parameter int unsigned ISSUE2_WINDOW = 0,
    // Enable same-cycle issue bypass from CDB lane 1, like lane 0. When
    // disabled, lane 1 wakes dependents through registered capture a cycle later.
    parameter bit LANE1_ISSUE_BYPASS = 1'b1,
    // INT only: store pc, link_addr and predicted_target by ROB tag. Port 0
    // reads them with its stage2 tag in the o_issue cycle. When disabled,
    // those outputs are zero. A dispatched tag must not already be live in
    // the station, including stage2.
    parameter bit TAG_INDEXED_BRANCH_PAYLOAD = 1'b0,
    // MUL_RS only: block divide readiness while the divider or stage2 holds
    // a divide. Every issued divide then finds the divider idle; multiplies
    // can pass waiting divides. Requires DUAL_ISSUE=0.
    parameter bit DIVIDE_ISSUE_GATE = 1'b0,
    // formal/reservation_station.sby uses free inputs and assumes dispatch
    // requirements. formal/tomasulo_wrapper.sby sets this to 0: its real
    // routing, capacity and flush logic must satisfy those requirements.
    // The branch-payload tag constraint becomes an assertion in that mode;
    // station-specific covers run only in the standalone environment.
    parameter bit FORMAL_STANDALONE_ENV = 1'b1
) (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Dispatch Interface (from Dispatch Unit)
    // =========================================================================
    input riscv_pkg::rs_dispatch_t i_dispatch,
    // Slot-2 dispatch packet, valid only when routed to this RS.
    input riscv_pkg::rs_dispatch_t i_dispatch_2,
    // Registered intent that slot 1 targets this RS, before bundle admission.
    //   1. alloc_idx_2 always uses i_intent_1. When dispatch_fire_2 is true,
    //      bundle atomicity requires i_intent_1 == dispatch_fire, so this
    //      chooses the same index as a dispatch_fire-based select.
    //   2. Speculative slot-2 writes use intent to choose capacity. A blocked
    //      dispatch can only write a free entry; rs_valid stays clear.
    //   3. ISSUE_CDB_TAG_SHADOW uses intent to choose slot 1's normal or
    //      complemented tag.
    input logic i_intent_1,
    output logic o_full,
    // Registered: at most one free entry, so a two-slot bundle cannot fit.
    // With DISPATCH_STATUS_RESERVE nonzero it is computed from the previous
    // occupancy with that many entries held back.
    output logic o_full_for_2,

    // =========================================================================
    // CDB Snoop / Wakeup
    // =========================================================================
    input riscv_pkg::cdb_broadcast_t i_cdb,

    // Second CDB lane; LANE1_ISSUE_BYPASS controls same-cycle issue bypass.
    input riscv_pkg::cdb_broadcast_t i_cdb_2,

    // Optional narrow issue-only CDB views. When ISSUE_CDB_META_ANCHORS=1,
    // only these valid/tag fields feed the live issue/readiness compares;
    // operand values still come from i_cdb/i_cdb_2 on the capture edge.
    input logic                                        i_issue_cdb_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_issue_cdb_tag,
    input logic                                        i_issue_cdb_2_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_issue_cdb_2_tag,

    // Registered ROB-done repair wakeups from dispatch. These carry operands
    // whose CDB broadcast happened before the consumer was dispatched.
    // Channels 1-3: slot-1 sources. Channels 4-6: slot-2 sources. In generic
    // mode the tags CAM-snoop resident entries; ALLOC_INDEXED_REPAIR instead
    // uses the saved allocation targets and ignores these tags in synthesis.
    input logic                                        i_repair_valid_1,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_repair_tag_1,
    input logic [                 riscv_pkg::FLEN-1:0] i_repair_value_1,
    input logic                                        i_repair_valid_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_repair_tag_2,
    input logic [                 riscv_pkg::FLEN-1:0] i_repair_value_2,
    input logic                                        i_repair_valid_3,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_repair_tag_3,
    input logic [                 riscv_pkg::FLEN-1:0] i_repair_value_3,
    input logic                                        i_repair_valid_4,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_repair_tag_4,
    input logic [                 riscv_pkg::FLEN-1:0] i_repair_value_4,
    input logic                                        i_repair_valid_5,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_repair_tag_5,
    input logic [                 riscv_pkg::FLEN-1:0] i_repair_value_5,
    input logic                                        i_repair_valid_6,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_repair_tag_6,
    input logic [                 riscv_pkg::FLEN-1:0] i_repair_value_6,

    // =========================================================================
    // Issue Interface (to Functional Unit)
    // =========================================================================
    output riscv_pkg::rs_issue_t                                        o_issue,
    input  logic                                                        i_fu_ready,
    // DIVIDE_ISSUE_GATE only: the divider holds an operation or its result.
    input  logic                                                        i_divider_busy,
    output logic                                                        o_issue_writes_cdb_hint,
    // Same-edge copy of the stage2 ROB tag used only by branch-resolution
    // predicates (BRANCH_PREDICATE_TAG_ANCHOR). Off, it aliases stage2_rob_tag.
    output logic                 [riscv_pkg::ReorderBufferTagWidth-1:0] o_branch_predicate_tag,

    // Second issue port (DUAL_ISSUE only; tied off otherwise).
    output riscv_pkg::rs_issue_t       o_issue_2,
    input  logic                       i_fu_ready_2,
    output logic                       o_issue_writes_cdb_hint_2,
    // Effective barrel amount captured on the same edge as port-1 operands.
    output logic                 [5:0] o_issue_shift_amount_2,

    // =========================================================================
    // Current Issue Payload Peek (combinational, independent of i_fu_ready)
    // =========================================================================
    output logic o_next_issue_valid,
    output logic o_next_issue_is_sc,
    output logic o_next_issue_needs_lq,

    // =========================================================================
    // Pre-issue look-ahead during stage2 capture, one cycle before the earliest
    // o_issue fire. Stage2 may hold while the FU is busy. MEM_RS exposes the
    // selected tag and mem_needs_lq so the LQ can register its address-update
    // match before downstream issue.
    // =========================================================================
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_pre_issue_rob_tag,
    // Four merged-valid or eight raw-wakeup outcomes and their selector. The
    // LQ registers their CAM results and the selector on the same edge.
    output logic [(PREISSUE_RAW_WAKEUP ? 8 : 4)*riscv_pkg::ReorderBufferTagWidth-1:0]
        o_pre_issue_rob_tags,
    output logic [(PREISSUE_RAW_WAKEUP ? 3 : 2)-1:0] o_pre_issue_sel,
    // PREISSUE_READY_EXPORT: candidate c's ready vector at [c*DEPTH +: DEPTH]
    // (its winner is the lowest set bit, entry 0 when none is set) and entry
    // e's ROB tag at [e*ReorderBufferTagWidth +: ReorderBufferTagWidth].
    // Zero otherwise.
    output logic [(PREISSUE_RAW_WAKEUP ? 8 : 4)*DEPTH-1:0] o_pre_issue_ready,
    output logic [DEPTH*riscv_pkg::ReorderBufferTagWidth-1:0] o_pre_issue_entry_tags,
    input logic [2:0] i_pre_issue_raw_valid,
    input logic [3*riscv_pkg::ReorderBufferTagWidth-1:0] i_pre_issue_raw_tags,
    output logic o_pre_issue_needs_lq,

    // =========================================================================
    // Flush Control
    // =========================================================================
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,
    input logic                                        i_flush_all,

    // =========================================================================
    // Status / Debug
    // =========================================================================
    output logic                       o_empty,
    output logic [$clog2(DEPTH+1)-1:0] o_count,

    // =========================================================================
    // Head-wait diagnostic observation (combinational, for perf counters)
    // =========================================================================
    // Report whether the queried ROB tag is resident, ready or in stage2.
    // Used only for head-wait performance counters.
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_head_query_tag,
    output logic                                        o_head_query_in_rs,
    output logic                                        o_head_query_rs_ready,
    output logic                                        o_head_query_in_stage2,

    // Registered performance event: port 0 fires with another ready entry.
    // It measures single-port limits only; port-1 issue is not subtracted.
    output logic o_perf_two_ready_one_issued
);

  // ===========================================================================
  // Local Parameters
  // ===========================================================================
  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned CheckpointIdWidth = riscv_pkg::CheckpointIdWidth;
  localparam int unsigned CountWidth = $clog2(DEPTH + 1);
  localparam int unsigned DispatchFullThreshold =
      (DISPATCH_STATUS_RESERVE >= DEPTH) ? 0 : (DEPTH - DISPATCH_STATUS_RESERVE);
  localparam int unsigned DispatchFullFor2Threshold =
      ((DISPATCH_STATUS_RESERVE + 1) >= DEPTH) ? 0 :
      (DEPTH - DISPATCH_STATUS_RESERVE - 1);

  // ===========================================================================
  // Helper Functions
  // ===========================================================================

  // Check if entry_tag is younger than flush_tag (relative to rob_head)
  function automatic logic should_flush_entry(input logic [ReorderBufferTagWidth-1:0] entry_tag,
                                              input logic [ReorderBufferTagWidth-1:0] flush_tag,
                                              input logic [ReorderBufferTagWidth-1:0] head);
    logic [ReorderBufferTagWidth:0] entry_age;
    logic [ReorderBufferTagWidth:0] flush_age;
    begin
      entry_age = {1'b0, entry_tag} - {1'b0, head};
      flush_age = {1'b0, flush_tag} - {1'b0, head};
      should_flush_entry = entry_age > flush_age;
    end
  endfunction

  function automatic logic [DEPTH-1:0] index_to_onehot(input logic [$clog2(DEPTH)-1:0] index);
    begin
      index_to_onehot = '0;
      index_to_onehot[index] = 1'b1;
    end
  endfunction

  function automatic logic int_rs_writes_cdb(input riscv_pkg::instr_op_e op);
    begin
      case (op)
        riscv_pkg::BEQ,
        riscv_pkg::BNE,
        riscv_pkg::BLT,
        riscv_pkg::BGE,
        riscv_pkg::BLTU,
        riscv_pkg::BGEU:
        int_rs_writes_cdb = 1'b0;
        default: int_rs_writes_cdb = 1'b1;
      endcase
    end
  endfunction

  function automatic logic done_repair_match(input logic [ReorderBufferTagWidth-1:0] tag);
    begin
      if (ALLOC_INDEXED_REPAIR) begin
        done_repair_match = 1'b0;
      end else begin
        done_repair_match =
            (i_repair_valid_1 && tag == i_repair_tag_1) ||
            (i_repair_valid_2 && tag == i_repair_tag_2) ||
            (i_repair_valid_3 && tag == i_repair_tag_3) ||
            (i_repair_valid_4 && tag == i_repair_tag_4) ||
            (i_repair_valid_5 && tag == i_repair_tag_5) ||
            (i_repair_valid_6 && tag == i_repair_tag_6);
      end
    end
  endfunction

  function automatic logic [FLEN-1:0] done_repair_value(
      input logic [ReorderBufferTagWidth-1:0] tag);
    begin
      if (ALLOC_INDEXED_REPAIR) begin
        done_repair_value = '0;
      end else if (i_repair_valid_1 && tag == i_repair_tag_1) begin
        done_repair_value = i_repair_value_1;
      end else if (i_repair_valid_2 && tag == i_repair_tag_2) begin
        done_repair_value = i_repair_value_2;
      end else if (i_repair_valid_3 && tag == i_repair_tag_3) begin
        done_repair_value = i_repair_value_3;
      end else if (i_repair_valid_4 && tag == i_repair_tag_4) begin
        done_repair_value = i_repair_value_4;
      end else if (i_repair_valid_5 && tag == i_repair_tag_5) begin
        done_repair_value = i_repair_value_5;
      end else if (i_repair_valid_6 && tag == i_repair_tag_6) begin
        done_repair_value = i_repair_value_6;
      end else begin
        done_repair_value = '0;
      end
    end
  endfunction

  // ===========================================================================
  // Dispatch Field Extraction
  // ===========================================================================

  wire                                              dispatch_valid = i_dispatch.valid;
  wire                  [ReorderBufferTagWidth-1:0] dispatch_rob_tag = i_dispatch.rob_tag;
  riscv_pkg::instr_op_e                             dispatch_op;
  assign dispatch_op = i_dispatch.op;
  wire dispatch_src1_ready = i_dispatch.src1_ready;
  wire [ReorderBufferTagWidth-1:0] dispatch_src1_tag = i_dispatch.src1_tag;
  wire [FLEN-1:0] dispatch_src1_value = i_dispatch.src1_value;
  wire dispatch_src2_ready = i_dispatch.src2_ready;
  wire [ReorderBufferTagWidth-1:0] dispatch_src2_tag = i_dispatch.src2_tag;
  wire [FLEN-1:0] dispatch_src2_value = i_dispatch.src2_value;
  wire dispatch_src3_ready = i_dispatch.src3_ready;
  wire [ReorderBufferTagWidth-1:0] dispatch_src3_tag = i_dispatch.src3_tag;
  wire [FLEN-1:0] dispatch_src3_value = i_dispatch.src3_value;
  wire [XLEN-1:0] dispatch_imm = i_dispatch.imm;
  wire [11:0] dispatch_jalr_imm = i_dispatch.jalr_imm;
  wire dispatch_use_imm = i_dispatch.use_imm;
  wire [2:0] dispatch_rm = i_dispatch.rm;
  wire dispatch_predicted_target_ok = i_dispatch.predicted_target_ok;
  wire dispatch_is_compressed = i_dispatch.is_compressed;
  wire dispatch_predicted_taken = i_dispatch.predicted_taken;
  wire dispatch_is_fp_mem = i_dispatch.is_fp_mem;
  wire dispatch_mem_needs_lq = i_dispatch.mem_needs_lq;
  wire dispatch_mem_needs_sq = i_dispatch.mem_needs_sq;
  riscv_pkg::mem_size_e dispatch_mem_size;
  assign dispatch_mem_size = i_dispatch.mem_size;
  wire dispatch_mem_signed = i_dispatch.mem_signed;
  wire [11:0] dispatch_csr_addr = i_dispatch.csr_addr;
  wire [4:0] dispatch_csr_imm = i_dispatch.csr_imm;
  wire dispatch_has_checkpoint = i_dispatch.has_checkpoint;
  wire [CheckpointIdWidth-1:0] dispatch_checkpoint_id = i_dispatch.checkpoint_id;
  wire dispatch_is_call = i_dispatch.is_call;
  wire dispatch_is_return = i_dispatch.is_return;
  wire dispatch_src1_repair_match =
      DISPATCH_REPAIR_BYPASS && !dispatch_src1_ready && done_repair_match(
      dispatch_src1_tag
  );
  wire dispatch_src2_repair_match =
      DISPATCH_REPAIR_BYPASS && !dispatch_src2_ready && done_repair_match(
      dispatch_src2_tag
  );
  wire dispatch_src3_repair_match =
      DISPATCH_REPAIR_BYPASS && !dispatch_src3_ready && done_repair_match(
      dispatch_src3_tag
  );
  wire [FLEN-1:0] dispatch_src1_stored_value = dispatch_src1_repair_match ? done_repair_value(
      dispatch_src1_tag
  ) : dispatch_src1_value;
  wire [FLEN-1:0] dispatch_src2_stored_value = dispatch_src2_repair_match ? done_repair_value(
      dispatch_src2_tag
  ) : dispatch_src2_value;
  wire [FLEN-1:0] dispatch_src3_stored_value = dispatch_src3_repair_match ? done_repair_value(
      dispatch_src3_tag
  ) : dispatch_src3_value;
  wire dispatch_src1_cdb0_match =
      !dispatch_src1_ready && i_cdb.valid && dispatch_src1_tag == i_cdb.tag;
  wire dispatch_src2_cdb0_match =
      !dispatch_src2_ready && i_cdb.valid && dispatch_src2_tag == i_cdb.tag;
  wire dispatch_src3_cdb0_match =
      !dispatch_src3_ready && i_cdb.valid && dispatch_src3_tag == i_cdb.tag;
  wire dispatch_src1_cdb1_match =
      !dispatch_src1_ready && i_cdb_2.valid && dispatch_src1_tag == i_cdb_2.tag;
  wire dispatch_src2_cdb1_match =
      !dispatch_src2_ready && i_cdb_2.valid && dispatch_src2_tag == i_cdb_2.tag;
  wire dispatch_src3_cdb1_match =
      !dispatch_src3_ready && i_cdb_2.valid && dispatch_src3_tag == i_cdb_2.tag;

  // Register a dispatch-cycle CDB match as {pend, lane}, then write its
  // saved lane value and set ready at the next edge. Without a repair issue
  // bypass, the source cannot issue during that delivery cycle because its
  // stored ready bit is still clear. A dispatch repair bypass already supplies
  // the value and ready bit, so it needs no deferred capture.
  (* keep = "true" *)
  wire dispatch_src1_cdb_defer_if_unready =
      ((i_cdb.valid && dispatch_src1_tag == i_cdb.tag) ||
       (i_cdb_2.valid && dispatch_src1_tag == i_cdb_2.tag)) &&
      !(DISPATCH_REPAIR_BYPASS && done_repair_match(
      dispatch_src1_tag
  ));
  wire dispatch_src1_cdb_defer = !dispatch_src1_ready && dispatch_src1_cdb_defer_if_unready;
  (* keep = "true" *)
  wire dispatch_src2_cdb_defer_if_unready =
      ((i_cdb.valid && dispatch_src2_tag == i_cdb.tag) ||
       (i_cdb_2.valid && dispatch_src2_tag == i_cdb_2.tag)) &&
      !(DISPATCH_REPAIR_BYPASS && done_repair_match(
      dispatch_src2_tag
  ));
  wire dispatch_src2_cdb_defer = !dispatch_src2_ready && dispatch_src2_cdb_defer_if_unready;
  (* keep = "true" *)
  wire dispatch_src3_cdb_defer_if_unready =
      ((i_cdb.valid && dispatch_src3_tag == i_cdb.tag) ||
       (i_cdb_2.valid && dispatch_src3_tag == i_cdb_2.tag)) &&
      !(DISPATCH_REPAIR_BYPASS && done_repair_match(
      dispatch_src3_tag
  ));
  wire dispatch_src3_cdb_defer = !dispatch_src3_ready && dispatch_src3_cdb_defer_if_unready;
  // Delivery lane: 0 selects i_cdb, 1 selects i_cdb_2. Distinct lane tags
  // permit at most one match; the guard preserves lane-0 priority otherwise.
  wire dispatch_src1_cdb_defer_lane = dispatch_src1_cdb1_match && !dispatch_src1_cdb0_match;
  wire dispatch_src2_cdb_defer_lane = dispatch_src2_cdb1_match && !dispatch_src2_cdb0_match;
  wire dispatch_src3_cdb_defer_lane = dispatch_src3_cdb1_match && !dispatch_src3_cdb0_match;

  // Slot-2 field aliases; valid packets are already routed to this RS.
  wire dispatch_valid_2 = i_dispatch_2.valid;
  wire [ReorderBufferTagWidth-1:0] dispatch_rob_tag_2 = i_dispatch_2.rob_tag;
  riscv_pkg::instr_op_e dispatch_op_2;
  assign dispatch_op_2 = i_dispatch_2.op;
  wire dispatch_src1_ready_2 = i_dispatch_2.src1_ready;
  wire [ReorderBufferTagWidth-1:0] dispatch_src1_tag_2 = i_dispatch_2.src1_tag;
  wire [FLEN-1:0] dispatch_src1_value_2 = i_dispatch_2.src1_value;
  wire dispatch_src2_ready_2 = i_dispatch_2.src2_ready;
  wire [ReorderBufferTagWidth-1:0] dispatch_src2_tag_2 = i_dispatch_2.src2_tag;
  wire [FLEN-1:0] dispatch_src2_value_2 = i_dispatch_2.src2_value;
  wire dispatch_src3_ready_2 = i_dispatch_2.src3_ready;
  wire [ReorderBufferTagWidth-1:0] dispatch_src3_tag_2 = i_dispatch_2.src3_tag;
  wire [FLEN-1:0] dispatch_src3_value_2 = i_dispatch_2.src3_value;
  wire [XLEN-1:0] dispatch_imm_2 = i_dispatch_2.imm;
  wire [11:0] dispatch_jalr_imm_2 = i_dispatch_2.jalr_imm;
  wire dispatch_use_imm_2 = i_dispatch_2.use_imm;
  wire [2:0] dispatch_rm_2 = i_dispatch_2.rm;
  wire dispatch_predicted_target_ok_2 = i_dispatch_2.predicted_target_ok;
  wire dispatch_is_compressed_2 = i_dispatch_2.is_compressed;
  wire dispatch_predicted_taken_2 = i_dispatch_2.predicted_taken;
  wire dispatch_is_fp_mem_2 = i_dispatch_2.is_fp_mem;
  wire dispatch_mem_needs_lq_2 = i_dispatch_2.mem_needs_lq;
  wire dispatch_mem_needs_sq_2 = i_dispatch_2.mem_needs_sq;
  riscv_pkg::mem_size_e dispatch_mem_size_2;
  assign dispatch_mem_size_2 = i_dispatch_2.mem_size;
  wire dispatch_mem_signed_2 = i_dispatch_2.mem_signed;
  wire [11:0] dispatch_csr_addr_2 = i_dispatch_2.csr_addr;
  wire [4:0] dispatch_csr_imm_2 = i_dispatch_2.csr_imm;
  wire dispatch_has_checkpoint_2 = i_dispatch_2.has_checkpoint;
  wire [CheckpointIdWidth-1:0] dispatch_checkpoint_id_2 = i_dispatch_2.checkpoint_id;
  wire dispatch_is_call_2 = i_dispatch_2.is_call;
  wire dispatch_is_return_2 = i_dispatch_2.is_return;
  wire dispatch_src1_repair_match_2 =
      DISPATCH_REPAIR_BYPASS && !dispatch_src1_ready_2 && done_repair_match(
      dispatch_src1_tag_2
  );
  wire dispatch_src2_repair_match_2 =
      DISPATCH_REPAIR_BYPASS && !dispatch_src2_ready_2 && done_repair_match(
      dispatch_src2_tag_2
  );
  wire dispatch_src3_repair_match_2 =
      DISPATCH_REPAIR_BYPASS && !dispatch_src3_ready_2 && done_repair_match(
      dispatch_src3_tag_2
  );
  wire [FLEN-1:0] dispatch_src1_stored_value_2 = dispatch_src1_repair_match_2 ? done_repair_value(
      dispatch_src1_tag_2
  ) : dispatch_src1_value_2;
  wire [FLEN-1:0] dispatch_src2_stored_value_2 = dispatch_src2_repair_match_2 ? done_repair_value(
      dispatch_src2_tag_2
  ) : dispatch_src2_value_2;
  wire [FLEN-1:0] dispatch_src3_stored_value_2 = dispatch_src3_repair_match_2 ? done_repair_value(
      dispatch_src3_tag_2
  ) : dispatch_src3_value_2;
  wire dispatch_src1_cdb0_match_2 =
      !dispatch_src1_ready_2 && i_cdb.valid && dispatch_src1_tag_2 == i_cdb.tag;
  wire dispatch_src2_cdb0_match_2 =
      !dispatch_src2_ready_2 && i_cdb.valid && dispatch_src2_tag_2 == i_cdb.tag;
  wire dispatch_src3_cdb0_match_2 =
      !dispatch_src3_ready_2 && i_cdb.valid && dispatch_src3_tag_2 == i_cdb.tag;
  wire dispatch_src1_cdb1_match_2 =
      !dispatch_src1_ready_2 && i_cdb_2.valid && dispatch_src1_tag_2 == i_cdb_2.tag;
  wire dispatch_src2_cdb1_match_2 =
      !dispatch_src2_ready_2 && i_cdb_2.valid && dispatch_src2_tag_2 == i_cdb_2.tag;
  wire dispatch_src3_cdb1_match_2 =
      !dispatch_src3_ready_2 && i_cdb_2.valid && dispatch_src3_tag_2 == i_cdb_2.tag;

  // Slot-2 deferred CDB capture.
  (* keep = "true" *)
  wire dispatch_src1_cdb_defer_if_unready_2 =
      ((i_cdb.valid && dispatch_src1_tag_2 == i_cdb.tag) ||
       (i_cdb_2.valid && dispatch_src1_tag_2 == i_cdb_2.tag)) &&
      !(DISPATCH_REPAIR_BYPASS && done_repair_match(
      dispatch_src1_tag_2
  ));
  wire dispatch_src1_cdb_defer_2 = !dispatch_src1_ready_2 && dispatch_src1_cdb_defer_if_unready_2;
  (* keep = "true" *)
  wire dispatch_src2_cdb_defer_if_unready_2 =
      ((i_cdb.valid && dispatch_src2_tag_2 == i_cdb.tag) ||
       (i_cdb_2.valid && dispatch_src2_tag_2 == i_cdb_2.tag)) &&
      !(DISPATCH_REPAIR_BYPASS && done_repair_match(
      dispatch_src2_tag_2
  ));
  wire dispatch_src2_cdb_defer_2 = !dispatch_src2_ready_2 && dispatch_src2_cdb_defer_if_unready_2;
  (* keep = "true" *)
  wire dispatch_src3_cdb_defer_if_unready_2 =
      ((i_cdb.valid && dispatch_src3_tag_2 == i_cdb.tag) ||
       (i_cdb_2.valid && dispatch_src3_tag_2 == i_cdb_2.tag)) &&
      !(DISPATCH_REPAIR_BYPASS && done_repair_match(
      dispatch_src3_tag_2
  ));
  wire dispatch_src3_cdb_defer_2 = !dispatch_src3_ready_2 && dispatch_src3_cdb_defer_if_unready_2;
  wire dispatch_src1_cdb_defer_lane_2 = dispatch_src1_cdb1_match_2 && !dispatch_src1_cdb0_match_2;
  wire dispatch_src2_cdb_defer_lane_2 = dispatch_src2_cdb1_match_2 && !dispatch_src2_cdb0_match_2;
  wire dispatch_src3_cdb_defer_lane_2 = dispatch_src3_cdb1_match_2 && !dispatch_src3_cdb0_match_2;

  // ===========================================================================
  // Stage 2 Pipeline Register
  // ===========================================================================
  // Stage2 holds the selected payload and operands for downstream issue.
  // It presents a one-shot valid when i_fu_ready is high; branch words may
  // come from the tag-indexed side RAM.

  logic stage2_valid;
  logic [ReorderBufferTagWidth-1:0] stage2_rob_tag;
  // Limit opcode fanout to the FU decode.
  (* max_fanout = 48 *) riscv_pkg::instr_op_e stage2_op;
  logic stage2_is_divide;  // DIVIDE_ISSUE_GATE: the entry's divide bit, loaded with stage2
  logic stage2_is_sc;
  logic [FLEN-1:0] stage2_src1_value;
  logic [FLEN-1:0] stage2_src2_value;
  logic [FLEN-1:0] stage2_src3_value;
  logic [XLEN-1:0] stage2_imm;
  logic [11:0] stage2_jalr_imm;
  logic stage2_use_imm;
  logic stage2_writes_cdb_hint;
  logic [2:0] stage2_rm;
  logic stage2_predicted_taken;
  logic stage2_predicted_target_ok;
  logic stage2_is_compressed;
  logic stage2_is_fp_mem;
  logic stage2_mem_needs_lq;
  logic stage2_mem_needs_sq;
  riscv_pkg::mem_size_e stage2_mem_size;
  logic stage2_mem_signed;
  logic [11:0] stage2_csr_addr;
  logic [4:0] stage2_csr_imm;
  logic stage2_has_checkpoint;
  logic [CheckpointIdWidth-1:0] stage2_checkpoint_id;
  logic stage2_is_call;
  logic stage2_is_return;
  logic stage2_is_branch_class;
  logic stage2_is_jal;
  logic stage2_is_jalr;
  riscv_pkg::branch_taken_op_e stage2_branch_op;

  // Masks select captured CDB values after stage2 when operands are not
  // captured fully resolved. Replicate mask bits for fanout.
  (* max_fanout = 8 *) logic [FLEN-1:0] stage2_src1_bypass_mask;
  (* max_fanout = 8 *) logic [FLEN-1:0] stage2_src1_bypass_mask_l1;
  (* max_fanout = 8 *) logic [FLEN-1:0] stage2_src2_bypass_mask;
  (* max_fanout = 8 *) logic [FLEN-1:0] stage2_src2_bypass_mask_l1;
  (* max_fanout = 8 *) logic [FLEN-1:0] stage2_src3_bypass_mask;
  (* max_fanout = 8 *) logic [FLEN-1:0] stage2_src3_bypass_mask_l1;
  logic [FLEN-1:0] stage2_cdb_value;  // lane-0 CDB value captured at issue time
  logic [FLEN-1:0] stage2_cdb_value_l1;  // lane-1 CDB value captured at issue time

`ifndef SYNTHESIS
`ifndef FORMAL
  // Simulation-only reference for CAPTURE_PRIMARY_EFFECTIVE_OPERANDS. It
  // tracks stage2 lifetime and independently records the three-arm CDB bypass
  // result on every issue edge.
  logic primary_operand_oracle_valid_q;
  logic [FLEN-1:0] primary_src1_value_oracle_q;
  logic [FLEN-1:0] primary_src2_value_oracle_q;
`endif
`endif

  // Stage 2 control signals
  logic stage2_should_flush;  // Stage2 holds a packet covered by the flush
  logic stage2_accept;  // Stage2 content consumed by FU this cycle
  logic can_issue_to_stage2;  // Stage2 is empty or being consumed, so the RS may load it

  // ===========================================================================
  // Storage: FF-based control, LUTRAM-based payload
  // ===========================================================================
  //
  // Control fields (FFs): rs_valid, rs_src*_ready/tag/value, rs_use_imm,
  //   rs_rob_tag. These need parallel CDB tag compare/write and flush scan.
  // Payload fields (LUTRAM): op, imm, rm, and the branch/prediction/mem/csr
  //   fields. Written once at dispatch, read once at issue (one copy per
  //   issue port).

  // 1-bit packed vectors (for bulk operations)
  logic [DEPTH-1:0] rs_valid;
  logic [DEPTH-1:0] rs_src1_ready;
  logic [DEPTH-1:0] rs_src2_ready;
  logic [DEPTH-1:0] rs_src3_ready_q;
  logic [DEPTH-1:0] rs_src3_ready;
  logic [DEPTH-1:0] rs_use_imm;
  // Port-1 shift controls in FFs, read with the operand one-hot select.
  logic [DEPTH-1:0] rs_shift_uses_imm;
  logic [5:0] rs_shift_imm[DEPTH];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [6:0] dispatch_shift_controls, dispatch_shift_controls_2;  // bit 0 only
  /* verilator lint_on UNUSEDSIGNAL */
  assign dispatch_shift_controls   = riscv_pkg::projected_shift_controls(i_dispatch.op);
  assign dispatch_shift_controls_2 = riscv_pkg::projected_shift_controls(i_dispatch_2.op);
  logic [DEPTH-1:0] rs_writes_cdb_hint;
  // A parallel branch-class bit lets port 1 exclude branches before reading
  // payload RAM.
  logic [DEPTH-1:0] rs_is_branch_class;
  // Integer divide pre-decode in FFs, for the DIVIDE_ISSUE_GATE ready scan.
  logic [DEPTH-1:0] rs_is_divide;

  // Multi-bit FF arrays (need parallel CDB snoop / flush compare)
  logic [ReorderBufferTagWidth-1:0] rs_rob_tag[DEPTH];

  logic [ReorderBufferTagWidth-1:0] rs_src1_tag[DEPTH];
  logic [ReorderBufferTagWidth-1:0] rs_src1_issue_tag[DEPTH];
  logic [FLEN-1:0] rs_src1_value[DEPTH];

  logic [ReorderBufferTagWidth-1:0] rs_src2_tag[DEPTH];
  logic [ReorderBufferTagWidth-1:0] rs_src2_issue_tag[DEPTH];
  logic [FLEN-1:0] rs_src2_value[DEPTH];

  logic [ReorderBufferTagWidth-1:0] rs_src3_tag[DEPTH];
  logic [FLEN-1:0] rs_src3_value[DEPTH];

  // Without src3, tie it ready so synthesis can remove its storage and wakeup.
  assign rs_src3_ready = HAS_SRC3 ? rs_src3_ready_q : {DEPTH{1'b1}};

  // Pending flags reset; saved lane values do not. A pending source blocks
  // live CDB issue bypass until its deferred delivery completes.
  logic [DEPTH-1:0] src1_cdb_pend;
  logic [DEPTH-1:0] src1_cdb_pend_lane;
  logic [DEPTH-1:0] src2_cdb_pend;
  logic [DEPTH-1:0] src2_cdb_pend_lane;
  logic [DEPTH-1:0] src3_cdb_pend;
  logic [DEPTH-1:0] src3_cdb_pend_lane;
  logic [FLEN-1:0] cdb0_value_q;
  logic [FLEN-1:0] cdb1_value_q;

  // ===========================================================================
  // Internal Signals
  // ===========================================================================

  logic full;
  logic full_for_2;
  logic empty;
  logic [CountWidth-1:0] count;
  logic [CountWidth-1:0] count_next;
  // Limit dispatch-status fanout.
  (* max_fanout = 32 *) logic dispatch_full_q;
  (* max_fanout = 32 *) logic dispatch_full_for_2_q;

  // Select the first two free entries. Slot 2 uses the second when slot 1
  // also targets this RS, otherwise the first; capacity checks must agree.
  logic [$clog2(DEPTH)-1:0] free_idx;
  logic free_found;
  logic [$clog2(DEPTH)-1:0] free_idx_2;
  logic free_found_2;
  // Effective slot-2 alloc index: free_idx_2 when slot-1 also targets this
  // RS (i_intent_1; slot-1 takes free_idx), else free_idx.
  logic [$clog2(DEPTH)-1:0] alloc_idx_2;
  logic data_write_1_en;
  logic data_write_2_en;

  // Save each slot's allocation target for its next-cycle repair response.
  logic [DEPTH-1:0] repair_slot1_target_q;
  logic [DEPTH-1:0] repair_slot2_target_q;
  logic [DEPTH-1:0] indexed_src1_repair;
  logic [DEPTH-1:0] indexed_src2_repair;
  logic [DEPTH-1:0] indexed_src3_repair;

  // Each pending delivery belongs to an allocation token. Select its saved
  // CDB value once per slot and source, or use that slot's repair value when
  // no delivery is pending. Preserve write priority even if repair and CDB
  // data differ.
  function automatic logic [FLEN-1:0] deferred_or_repair(
      input logic [DEPTH-1:0] target, input logic [DEPTH-1:0] pending,
      input logic [DEPTH-1:0] pending_lane, input logic [FLEN-1:0] lane0_value,
      input logic [FLEN-1:0] lane1_value, input logic [FLEN-1:0] repair_value);
    deferred_or_repair = (|(target & pending)) ?
        ((|(target & pending & pending_lane)) ? lane1_value : lane0_value) : repair_value;
  endfunction

  logic [FLEN-1:0] indexed_delivery_1;
  logic [FLEN-1:0] indexed_delivery_2;
  logic [FLEN-1:0] indexed_delivery_3;
  logic [FLEN-1:0] indexed_delivery_4;
  logic [FLEN-1:0] indexed_delivery_5;
  logic [FLEN-1:0] indexed_delivery_6;

  assign indexed_delivery_1 = deferred_or_repair(
      repair_slot1_target_q,
      src1_cdb_pend,
      src1_cdb_pend_lane,
      cdb0_value_q,
      cdb1_value_q,
      i_repair_value_1
  );
  assign indexed_delivery_2 = deferred_or_repair(
      repair_slot1_target_q,
      src2_cdb_pend,
      src2_cdb_pend_lane,
      cdb0_value_q,
      cdb1_value_q,
      i_repair_value_2
  );
  assign indexed_delivery_3 = deferred_or_repair(
      repair_slot1_target_q,
      src3_cdb_pend,
      src3_cdb_pend_lane,
      cdb0_value_q,
      cdb1_value_q,
      i_repair_value_3
  );
  assign indexed_delivery_4 = deferred_or_repair(
      repair_slot2_target_q,
      src1_cdb_pend,
      src1_cdb_pend_lane,
      cdb0_value_q,
      cdb1_value_q,
      i_repair_value_4
  );
  assign indexed_delivery_5 = deferred_or_repair(
      repair_slot2_target_q,
      src2_cdb_pend,
      src2_cdb_pend_lane,
      cdb0_value_q,
      cdb1_value_q,
      i_repair_value_5
  );
  assign indexed_delivery_6 = deferred_or_repair(
      repair_slot2_target_q,
      src3_cdb_pend,
      src3_cdb_pend_lane,
      cdb0_value_q,
      cdb1_value_q,
      i_repair_value_6
  );

  assign indexed_src1_repair = ALLOC_INDEXED_REPAIR ?
      ((repair_slot1_target_q & {DEPTH{i_repair_valid_1}}) |
       (repair_slot2_target_q & {DEPTH{i_repair_valid_4}})) : '0;
  assign indexed_src2_repair = ALLOC_INDEXED_REPAIR ?
      ((repair_slot1_target_q & {DEPTH{i_repair_valid_2}}) |
       (repair_slot2_target_q & {DEPTH{i_repair_valid_5}})) : '0;
  assign indexed_src3_repair = (ALLOC_INDEXED_REPAIR && HAS_SRC3) ?
      ((repair_slot1_target_q & {DEPTH{i_repair_valid_3}}) |
       (repair_slot2_target_q & {DEPTH{i_repair_valid_6}})) : '0;

  // Issue selection
  logic [DEPTH-1:0] entry_ready;
  logic [$clog2(DEPTH)-1:0] issue_idx;
  logic any_ready;
  logic issue_fire;
  // Declare port-1 state for shared count and valid logic; tie off when disabled.
  logic [$clog2(DEPTH)-1:0] issue_idx_2;
  logic [DEPTH-1:0] issue_sel_2;
  logic any_ready_2;
  logic issue_fire_2;
  logic stage2b_valid;
  logic stage2b_head_query_match;
  logic [(2**$clog2(DEPTH))-1:0] issue_sel_2_ohread;

  // Dispatch condition
  (* max_fanout = 32 *) logic dispatch_fire;
  // Slot-2 dispatch fire condition. Slot-2 needs room for itself, considering
  // whether slot-1 is also consuming a slot this cycle.
  (* max_fanout = 32 *) logic dispatch_fire_2;

  // ===========================================================================
  // Payload LUTRAM: dispatch-only fields, read at issue
  // ===========================================================================
  // Each issue port reads a RAM copy with common dispatch writes. rs_valid
  // qualifies all uses, making stale payloads harmless.

  localparam int unsigned PayloadWidth =
      riscv_pkg::InstrOpWidth + XLEN + 12 + 3 + 1 + 1 + 1 + 1 + 1 + 1 + 2 + 1 + 12 +
      5 + 1 + CheckpointIdWidth + 1 + 1 + 1 + 1 + 1 + 3;

  // Decode branch class at dispatch. Inline fully qualified enums because
  // Yosys cannot resolve them in package functions. These sets match
  // riscv_pkg::is_branch_or_jump_op, is_jal_op and is_jalr_op;
  // rs_branch_op_of supplies the branch direction operation.
  function automatic logic rs_is_branch_class_op(riscv_pkg::instr_op_e op);
    case (op)
      riscv_pkg::BEQ, riscv_pkg::BNE, riscv_pkg::BLT, riscv_pkg::BGE,
      riscv_pkg::BLTU, riscv_pkg::BGEU, riscv_pkg::JAL, riscv_pkg::JALR:
      rs_is_branch_class_op = 1'b1;
      default: rs_is_branch_class_op = 1'b0;
    endcase
  endfunction

  function automatic riscv_pkg::branch_taken_op_e rs_branch_op_of(riscv_pkg::instr_op_e op);
    case (op)
      riscv_pkg::BEQ:                  rs_branch_op_of = riscv_pkg::BREQ;
      riscv_pkg::BNE:                  rs_branch_op_of = riscv_pkg::BRNE;
      riscv_pkg::BLT:                  rs_branch_op_of = riscv_pkg::BRLT;
      riscv_pkg::BGE:                  rs_branch_op_of = riscv_pkg::BRGE;
      riscv_pkg::BLTU:                 rs_branch_op_of = riscv_pkg::BRLTU;
      riscv_pkg::BGEU:                 rs_branch_op_of = riscv_pkg::BRGEU;
      riscv_pkg::JAL, riscv_pkg::JALR: rs_branch_op_of = riscv_pkg::JUMP;
      default:                         rs_branch_op_of = riscv_pkg::NULL;
    endcase
  endfunction

  function automatic logic rs_is_divide_op(riscv_pkg::instr_op_e op);
    case (op)
      riscv_pkg::DIV, riscv_pkg::DIVU, riscv_pkg::REM, riscv_pkg::REMU,
      riscv_pkg::DIVW, riscv_pkg::DIVUW, riscv_pkg::REMW, riscv_pkg::REMUW:
      rs_is_divide_op = 1'b1;
      default: rs_is_divide_op = 1'b0;
    endcase
  endfunction

  logic dispatch_is_divide, dispatch_is_divide_2;
  assign dispatch_is_divide   = DIVIDE_ISSUE_GATE && rs_is_divide_op(dispatch_op);
  assign dispatch_is_divide_2 = DIVIDE_ISSUE_GATE && rs_is_divide_op(dispatch_op_2);

  logic dispatch_is_branch_class, dispatch_is_branch_class_2;
  logic dispatch_is_jal, dispatch_is_jal_2;
  logic dispatch_is_jalr, dispatch_is_jalr_2;
  riscv_pkg::branch_taken_op_e dispatch_branch_op, dispatch_branch_op_2;
  assign dispatch_is_branch_class = rs_is_branch_class_op(dispatch_op);
  assign dispatch_is_jal = (dispatch_op == riscv_pkg::JAL);
  assign dispatch_is_jalr = (dispatch_op == riscv_pkg::JALR);
  assign dispatch_branch_op = rs_branch_op_of(dispatch_op);
  assign dispatch_is_branch_class_2 = rs_is_branch_class_op(dispatch_op_2);
  assign dispatch_is_jal_2 = (dispatch_op_2 == riscv_pkg::JAL);
  assign dispatch_is_jalr_2 = (dispatch_op_2 == riscv_pkg::JALR);
  assign dispatch_branch_op_2 = rs_branch_op_of(dispatch_op_2);

  logic [PayloadWidth-1:0] payload_wr_data;
  logic [PayloadWidth-1:0] payload_wr_data_2;
  logic [PayloadWidth-1:0] payload_rd_data;

  assign payload_wr_data = {
    dispatch_op,  // InstrOpWidth  op
    dispatch_imm,  // XLEN  imm
    dispatch_jalr_imm,  // 12  jalr_imm
    dispatch_rm,  //  3  rm
    dispatch_predicted_taken,  //  1  predicted_taken
    dispatch_predicted_target_ok,  //  1  predicted_target_ok
    dispatch_is_compressed,  //  1  is_compressed
    dispatch_is_fp_mem,  //  1  is_fp_mem
    dispatch_mem_needs_lq,  //  1  mem_needs_lq
    dispatch_mem_needs_sq,  //  1  mem_needs_sq
    2'(dispatch_mem_size),  //  2  mem_size
    dispatch_mem_signed,  //  1  mem_signed
    dispatch_csr_addr,  // 12  csr_addr
    dispatch_csr_imm,  //  5  csr_imm
    dispatch_has_checkpoint,  //  1  has_checkpoint
    dispatch_checkpoint_id,  //  CheckpointIdWidth  checkpoint_id
    dispatch_is_call,  //  1  is_call
    dispatch_is_return,  //  1  is_return
    dispatch_is_branch_class,  //  1  is_branch_class
    dispatch_is_jal,  //  1  is_jal
    dispatch_is_jalr,  //  1  is_jalr
    3'(dispatch_branch_op)  //  3  branch_op
  };

  assign payload_wr_data_2 = {
    dispatch_op_2,
    dispatch_imm_2,
    dispatch_jalr_imm_2,
    dispatch_rm_2,
    dispatch_predicted_taken_2,
    dispatch_predicted_target_ok_2,
    dispatch_is_compressed_2,
    dispatch_is_fp_mem_2,
    dispatch_mem_needs_lq_2,
    dispatch_mem_needs_sq_2,
    2'(dispatch_mem_size_2),
    dispatch_mem_signed_2,
    dispatch_csr_addr_2,
    dispatch_csr_imm_2,
    dispatch_has_checkpoint_2,
    dispatch_checkpoint_id_2,
    dispatch_is_call_2,
    dispatch_is_return_2,
    dispatch_is_branch_class_2,
    dispatch_is_jal_2,
    dispatch_is_jalr_2,
    3'(dispatch_branch_op_2)
  };

  // Both dispatch slots can write, including slot 2 alone in this RS.
  // INT selects a winner within each four-entry payload group, then selects
  // the winning group. The direct one-hot selection also clears validity.
  // With no ready entry, it selects entry zero and issue_fire stays low.
  localparam int unsigned PayloadDepth = 1 << $clog2(DEPTH);
  localparam int unsigned PayloadGroups = (DEPTH + 3) / 4;
  localparam int unsigned PayloadGroupIdxWidth = (PayloadGroups > 1) ? $clog2(PayloadGroups) : 1;
  logic [1:0] payload_group_pick[PayloadGroups];
  logic [PayloadGroupIdxWidth-1:0] payload_group_idx;
  (* keep = "true" *) logic [PayloadDepth-1:0] primary_issue_onehot;
  if (CAPTURE_PRIMARY_EFFECTIVE_OPERANDS) begin : gen_primary_payload_grouped
    for (genvar entry = 0; entry < int'(PayloadDepth); entry++) begin : gen_select
      if (entry == 0) begin : gen_zero
        assign primary_issue_onehot[entry] = entry_ready[0] || !any_ready;
      end else if (entry < int'(DEPTH)) begin : gen_entry
        assign primary_issue_onehot[entry] = entry_ready[entry] && !(|entry_ready[entry-1:0]);
      end else begin : gen_padding
        assign primary_issue_onehot[entry] = 1'b0;
      end
    end
    (* keep = "true" *) logic [PayloadWidth-1:0] group_payload[PayloadGroups];
    for (genvar g = 0; g < int'(PayloadGroups); g++) begin : gen_payload_group
      mwp_dist_ram #(
          .ADDR_WIDTH(2),
          .DATA_WIDTH(PayloadWidth),
          .NUM_WRITE_PORTS(2)
      ) u_payload_ram (
          .i_clk,
          .i_write_enable({
            dispatch_fire_2 && ((int'(alloc_idx_2) >> 2) == g),
            dispatch_fire && ((int'(free_idx) >> 2) == g)
          }),
          .i_write_address({2'(alloc_idx_2), 2'(free_idx)}),
          .i_read_address(payload_group_pick[g]),
          .i_write_data({payload_wr_data_2, payload_wr_data}),
          .o_read_data(group_payload[g])
      );
    end
    assign payload_rd_data = group_payload[payload_group_idx];
  end else begin : gen_primary_payload_binary
    assign primary_issue_onehot = '0;
    assign payload_group_idx = '0;
    for (genvar g = 0; g < int'(PayloadGroups); g++) assign payload_group_pick[g] = '0;
    mwp_dist_ram #(
        .ADDR_WIDTH     ($clog2(DEPTH)),
        .DATA_WIDTH     (PayloadWidth),
        .NUM_WRITE_PORTS(2)
    ) u_payload_ram (
        .i_clk,
        .i_write_enable ({dispatch_fire_2, dispatch_fire}),
        .i_write_address({alloc_idx_2, free_idx}),
        .i_read_address (issue_idx),
        .i_write_data   ({payload_wr_data_2, payload_wr_data}),
        .o_read_data    (payload_rd_data)
    );
  end

  // Unpack LUTRAM read data (at issue_idx, combinational / zero-latency)
  logic [riscv_pkg::InstrOpWidth-1:0] pl_op_bits;
  logic [                   XLEN-1:0] pl_imm;
  logic [                       11:0] pl_jalr_imm;
  logic [                        2:0] pl_rm;
  logic                               pl_predicted_taken;
  logic                               pl_predicted_target_ok;
  logic                               pl_is_compressed;
  logic                               pl_is_fp_mem;
  logic                               pl_mem_needs_lq;
  logic                               pl_mem_needs_sq;
  logic [                        1:0] pl_mem_size_bits;
  logic                               pl_mem_signed;
  logic [                       11:0] pl_csr_addr;
  logic [                        4:0] pl_csr_imm;
  logic                               pl_has_checkpoint;
  logic [      CheckpointIdWidth-1:0] pl_checkpoint_id;
  logic                               pl_is_call;
  logic                               pl_is_return;
  logic                               pl_is_branch_class;
  logic                               pl_is_jal;
  logic                               pl_is_jalr;
  logic [                        2:0] pl_branch_op_bits;

  assign {pl_op_bits, pl_imm, pl_jalr_imm, pl_rm, pl_predicted_taken,
          pl_predicted_target_ok, pl_is_compressed,
          pl_is_fp_mem, pl_mem_needs_lq, pl_mem_needs_sq,
          pl_mem_size_bits, pl_mem_signed,
          pl_csr_addr, pl_csr_imm,
          pl_has_checkpoint, pl_checkpoint_id, pl_is_call, pl_is_return,
          pl_is_branch_class, pl_is_jal, pl_is_jalr, pl_branch_op_bits} = payload_rd_data;

  // ===========================================================================
  // Combinational Logic
  // ===========================================================================

  // --- Count, full, empty ---
  // Register occupancy, recomputing it from surviving entries on a flush.
  // Otherwise subtract issues, then select among zero, one or two additions
  // for dispatch.
  logic [CountWidth-1:0] count_after_issue;
  logic [CountWidth-1:0] count_after_issue_p1;
  logic [CountWidth-1:0] count_after_issue_p2;
  assign count_after_issue = count - CountWidth'(issue_fire) - CountWidth'(issue_fire_2);
  assign count_after_issue_p1 = count_after_issue + CountWidth'(1);
  assign count_after_issue_p2 = count_after_issue + CountWidth'(2);

  always_comb begin
    count_next = count;
    if (i_flush_all) begin
      count_next = '0;
    end else if (i_flush_en) begin
      count_next = '0;
      for (int i = 0; i < DEPTH; i++) begin
        count_next = count_next +
            {{(CountWidth - 1) {1'b0}},
             (rs_valid[i] && !should_flush_entry(rs_rob_tag[i], i_flush_tag, i_rob_head_tag))};
      end
    end else begin
      unique case ({
        dispatch_fire, dispatch_fire_2
      })
        2'b11:   count_next = count_after_issue_p2;
        2'b10:   count_next = count_after_issue_p1;
        2'b01:   count_next = count_after_issue_p1;
        default: count_next = count_after_issue;
      endcase
    end
  end

  // Without a status reserve, precompute full flags for each dispatch width.
  // Flush uses the count of surviving entries.
  logic dispatch_full_next;
  logic dispatch_full_for_2_next;
  always_comb begin
    if (i_flush_all || i_flush_en) begin
      dispatch_full_next       = count_next == CountWidth'(DEPTH);
      dispatch_full_for_2_next = count_next >= CountWidth'(DEPTH - 1);
    end else begin
      unique case ({
        dispatch_fire, dispatch_fire_2
      })
        2'b11: begin
          dispatch_full_next       = count_after_issue_p2 == CountWidth'(DEPTH);
          dispatch_full_for_2_next = count_after_issue_p2 >= CountWidth'(DEPTH - 1);
        end
        2'b10, 2'b01: begin
          dispatch_full_next       = count_after_issue_p1 == CountWidth'(DEPTH);
          dispatch_full_for_2_next = count_after_issue_p1 >= CountWidth'(DEPTH - 1);
        end
        default: begin
          dispatch_full_next       = count_after_issue == CountWidth'(DEPTH);
          dispatch_full_for_2_next = count_after_issue >= CountWidth'(DEPTH - 1);
        end
      endcase
    end
  end

  assign full = (count == CountWidth'(DEPTH));
  // full_for_2: there is room for at most 1 more entry, so a 2-wide bundle
  // cannot fit even if neither slot has been allocated yet.
  assign full_for_2 = full || (count == CountWidth'(DEPTH - 1));
  assign empty = (count == '0);

  // Free indices are encoded from the parallel first/second-free masks below.
  // Both retain the serial search's index-zero not-found result.

  // Intent selects the first or second free entry; see the i_intent_1
  // requirements above.
  assign alloc_idx_2 = i_intent_1 ? free_idx_2 : free_idx;

  // --- Dispatch fire conditions ---
  // Flush controls validity and count, so payload writes need no flush gate.
  // A coincident write goes to an invalid entry and cannot become visible.
  assign dispatch_fire = TRUST_DISPATCH_VALID ? dispatch_valid : (dispatch_valid && !full);
  // Slot 2 needs two free entries if slot 1 fires here, otherwise one.
  assign dispatch_fire_2 = TRUST_DISPATCH_VALID ?
                           dispatch_valid_2 :
                           (dispatch_valid_2 && (dispatch_fire ? !full_for_2 : !full));

`ifndef SYNTHESIS
  // Trusted valids must already include the appropriate capacity checks.
  // Check at the capture edge, since consumers are clocked and refused
  // valids may change between edges. Full flush is exempt: it clears valid
  // state and count regardless of a stale dispatch packet.
  always_ff @(posedge i_clk) begin
    if (TRUST_DISPATCH_VALID && i_rst_n && !i_flush_all && !$isunknown(
            {dispatch_valid, dispatch_valid_2, full, full_for_2}
        )) begin
      p_trusted_dispatch_fire_exact : assert (dispatch_fire == (dispatch_valid && !full));
      p_trusted_dispatch_fire_2_exact :
      assert (dispatch_fire_2 ==
              (dispatch_valid_2 && ((dispatch_valid && !full) ? !full_for_2 : !full)));
    end
    // Exported status must conservatively cover live occupancy for trusted
    // valids. A reserve of one entry is insufficient for two-slot dispatch.
    if (TRUST_DISPATCH_VALID && i_rst_n && !$isunknown(
            {full, full_for_2, dispatch_full_q, dispatch_full_for_2_q}
        )) begin
      p_trusted_status_conservative : assert (!full || dispatch_full_q);
      p_trusted_status_for_2_conservative : assert (!full_for_2 || dispatch_full_for_2_q);
    end
  end
`endif

  // Speculative writes may fill a free entry while dispatch is blocked; only
  // dispatch_fire or dispatch_fire_2 sets rs_valid. Slot 2 uses intent to
  // select capacity.
  assign data_write_1_en = SPECULATIVE_DATA_WRITES ? !full : dispatch_fire;
  assign data_write_2_en = SPECULATIVE_DATA_WRITES ?
                           (i_intent_1 ? !full_for_2 : !full) : dispatch_fire_2;

  // --- One-hot slot-2 allocation select ---
  // Select a free entry with exactly one lower free entry when slot 1 also
  // targets this RS, or none when slot 2 is alone. Nibble free counts and
  // prefix reductions compute these masks directly from rs_valid.
  //
  // Match the binary selectors' fallbacks: free_idx_2 is zero with fewer than
  // two free entries, so under i_intent_1 only a sole free entry at zero can
  // match. If nothing is free, !rs_valid excludes the index-zero fallback.
  // Encode payload, tag and control indices from the same masks. Preserve
  // nibble boundaries for timing.
  localparam int unsigned AllocNibbles = (DEPTH + 3) / 4;
  logic [4*AllocNibbles-1:0] alloc_valid_padded;
  (* keep = "true" *) logic [AllocNibbles-1:0] nib_all_valid;  // no free entry in this nibble
  (* keep = "true" *)
  logic [AllocNibbles-1:0] nib_one_free;  // exactly one free entry in this nibble
  (* keep = "true" *) logic [AllocNibbles-1:0] nib_pfx_all_valid;  // no free entry in lower nibbles
  (* keep = "true" *)
  logic [AllocNibbles-1:0] nib_pfx_one_free;  // exactly one free entry in lower nibbles
  logic [DEPTH-1:0] ent_first_free_in_nib;  // free, no free entry below it in its nibble
  logic [DEPTH-1:0] ent_second_free_in_nib;  // free, one free entry below it in its nibble
  (* keep = "true" *) logic [DEPTH-1:0] none_free_below;  // free_idx == i (given entry i is free)
  (* keep = "true" *) logic [DEPTH-1:0] one_free_below;  // free_idx_2 == i (given entry i is free)
  logic [DEPTH-1:0] alloc_sel_2;

  // Loop masks become constants on unrolling, permitting flat reductions.
  function automatic logic [3:0] nib_below_mask(input int unsigned r);
    nib_below_mask = 4'((32'd1 << r) - 32'd1);
  endfunction
  function automatic logic [AllocNibbles-1:0] nib_lower_mask(input int unsigned n);
    nib_lower_mask = AllocNibbles'((32'd1 << n) - 32'd1);
  endfunction

  always_comb begin
    // Entries past DEPTH read as valid (never free).
    alloc_valid_padded = '1;
    alloc_valid_padded[DEPTH-1:0] = rs_valid;
    for (int n = 0; n < AllocNibbles; n++) begin
      nib_all_valid[n] = &alloc_valid_padded[4*n+:4];
      nib_one_free[n]  = 1'b0;
      for (int m = 0; m < 4; m++) begin
        nib_one_free[n] |= !alloc_valid_padded[4*n+m] &
            (&(alloc_valid_padded[4*n+:4] | 4'(32'd1 << m)));
      end
    end
    for (int n = 0; n < AllocNibbles; n++) begin
      nib_pfx_all_valid[n] = &(nib_all_valid | ~nib_lower_mask(n));
      nib_pfx_one_free[n]  = 1'b0;
      for (int m = 0; m < n; m++) begin
        nib_pfx_one_free[n] |= nib_one_free[m] &
            (&(nib_all_valid | ~nib_lower_mask(n) | AllocNibbles'(32'd1 << m)));
      end
    end
    for (int i = 0; i < DEPTH; i++) begin
      ent_first_free_in_nib[i] = !rs_valid[i] &
          (&(alloc_valid_padded[(i/4)*4+:4] | ~nib_below_mask(i % 4)));
      ent_second_free_in_nib[i] = 1'b0;
      for (int m = 0; m < i % 4; m++) begin
        ent_second_free_in_nib[i] |= !rs_valid[i] & !alloc_valid_padded[(i/4)*4+m] &
            (&(alloc_valid_padded[(i/4)*4+:4] | ~nib_below_mask(i % 4) | 4'(32'd1 << m)));
      end
      none_free_below[i] = ent_first_free_in_nib[i] & nib_pfx_all_valid[i/4];
      one_free_below[i] = (ent_second_free_in_nib[i] & nib_pfx_all_valid[i/4]) |
          (ent_first_free_in_nib[i] & nib_pfx_one_free[i/4]);
    end
    // free_idx_2 not-found fallback: index 0 when at most one entry is free.
    one_free_below[0] = !rs_valid[0] & (&rs_valid[DEPTH-1:1]);
    for (int i = 0; i < DEPTH; i++) begin
      alloc_sel_2[i] = data_write_2_en & (i_intent_1 ? one_free_below[i] : none_free_below[i]);
    end
  end

  always_comb begin
    free_idx   = '0;
    free_idx_2 = '0;
    for (int i = 0; i < DEPTH; i++) begin
      free_idx |= $clog2(DEPTH)'(i) & {$clog2(DEPTH) {none_free_below[i]}};
      free_idx_2 |= $clog2(DEPTH)'(i) & {$clog2(DEPTH) {one_free_below[i]}};
    end
    free_found   = |none_free_below;
    // Index zero in one_free_below is only the not-found fallback.
    free_found_2 = |one_free_below[DEPTH-1:1];
  end

`ifdef RS_ALLOC_LOCAL_PROOF
  logic [$clog2(DEPTH)-1:0] free_idx_ref, free_idx_2_ref;
  logic free_found_ref, free_found_2_ref;
  always_comb begin
    free_idx_ref = '0;
    free_idx_2_ref = '0;
    free_found_ref = 1'b0;
    free_found_2_ref = 1'b0;
    for (int i = 0; i < DEPTH; i++) begin
      if (!rs_valid[i]) begin
        if (!free_found_ref) begin
          free_idx_ref   = $clog2(DEPTH)'(i);
          free_found_ref = 1'b1;
        end else if (!free_found_2_ref) begin
          free_idx_2_ref   = $clog2(DEPTH)'(i);
          free_found_2_ref = 1'b1;
        end
      end
    end
    p_alloc_first_index : assert (free_idx == free_idx_ref);
    p_alloc_second_index : assert (free_idx_2 == free_idx_2_ref);
    p_alloc_first_found : assert (free_found == free_found_ref);
    p_alloc_second_found : assert (free_found_2 == free_found_2_ref);
  end
`endif

  // --- CDB bypass wakeup per entry ---
  // A matching broadcast makes an unready source eligible this cycle.
  logic [DEPTH-1:0] src1_cdb_bypass;
  logic [DEPTH-1:0] src2_cdb_bypass;
  logic [DEPTH-1:0] src3_cdb_bypass;
  // Distinct CDB tags make the lane bypass masks mutually exclusive per source.
  logic [DEPTH-1:0] src1_cdb_bypass_l1;
  logic [DEPTH-1:0] src2_cdb_bypass_l1;
  logic [DEPTH-1:0] src3_cdb_bypass_l1;
  logic issue_cdb_valid;
  logic [ReorderBufferTagWidth-1:0] issue_cdb_tag;
  logic issue_cdb_2_valid;
  logic [ReorderBufferTagWidth-1:0] issue_cdb_2_tag;
  assign issue_cdb_valid = ISSUE_CDB_META_ANCHORS ? i_issue_cdb_valid : i_cdb.valid;
  assign issue_cdb_tag = ISSUE_CDB_META_ANCHORS ? i_issue_cdb_tag : i_cdb.tag;
  assign issue_cdb_2_valid = ISSUE_CDB_META_ANCHORS ? i_issue_cdb_2_valid : i_cdb_2.valid;
  assign issue_cdb_2_tag = ISSUE_CDB_META_ANCHORS ? i_issue_cdb_2_tag : i_cdb_2.tag;
  // 3-bit selector encodes 0=none, 1..6=repair channel index.
  logic [2:0] src1_repair_sel[DEPTH];
  logic [2:0] src2_repair_sel[DEPTH];
  logic [2:0] src3_repair_sel[DEPTH];

  // A pending dispatch delivery keeps its source unready. Block live CDB
  // bypass so reuse of that tag cannot substitute a different producer's
  // value. Current pipeline latency prevents reuse within this one-cycle
  // window, but the pending bit enforces the rule directly.
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      src1_cdb_bypass[i] = issue_cdb_valid && !rs_src1_ready[i] && !src1_cdb_pend[i] &&
          (ISSUE_CDB_TAG_SHADOW ? rs_src1_issue_tag[i] : rs_src1_tag[i]) == issue_cdb_tag;
      src2_cdb_bypass[i] = issue_cdb_valid && !rs_src2_ready[i] && !src2_cdb_pend[i] &&
          (ISSUE_CDB_TAG_SHADOW ? rs_src2_issue_tag[i] : rs_src2_tag[i]) == issue_cdb_tag;
      src1_cdb_bypass_l1[i] = LANE1_ISSUE_BYPASS && issue_cdb_2_valid && !rs_src1_ready[i] &&
          !src1_cdb_pend[i] &&
          (ISSUE_CDB_TAG_SHADOW ? rs_src1_issue_tag[i] : rs_src1_tag[i]) == issue_cdb_2_tag;
      src2_cdb_bypass_l1[i] = LANE1_ISSUE_BYPASS && issue_cdb_2_valid && !rs_src2_ready[i] &&
          !src2_cdb_pend[i] &&
          (ISSUE_CDB_TAG_SHADOW ? rs_src2_issue_tag[i] : rs_src2_tag[i]) == issue_cdb_2_tag;
      src1_repair_sel[i] = 3'd0;
      src2_repair_sel[i] = 3'd0;
      if (ISSUE_REPAIR_BYPASS && !ALLOC_INDEXED_REPAIR && !rs_src1_ready[i]) begin
        if (i_repair_valid_1 && rs_src1_tag[i] == i_repair_tag_1) begin
          src1_repair_sel[i] = 3'd1;
        end else if (i_repair_valid_2 && rs_src1_tag[i] == i_repair_tag_2) begin
          src1_repair_sel[i] = 3'd2;
        end else if (i_repair_valid_3 && rs_src1_tag[i] == i_repair_tag_3) begin
          src1_repair_sel[i] = 3'd3;
        end else if (i_repair_valid_4 && rs_src1_tag[i] == i_repair_tag_4) begin
          src1_repair_sel[i] = 3'd4;
        end else if (i_repair_valid_5 && rs_src1_tag[i] == i_repair_tag_5) begin
          src1_repair_sel[i] = 3'd5;
        end else if (i_repair_valid_6 && rs_src1_tag[i] == i_repair_tag_6) begin
          src1_repair_sel[i] = 3'd6;
        end
      end
      if (ISSUE_REPAIR_BYPASS && !ALLOC_INDEXED_REPAIR && !rs_src2_ready[i]) begin
        if (i_repair_valid_1 && rs_src2_tag[i] == i_repair_tag_1) begin
          src2_repair_sel[i] = 3'd1;
        end else if (i_repair_valid_2 && rs_src2_tag[i] == i_repair_tag_2) begin
          src2_repair_sel[i] = 3'd2;
        end else if (i_repair_valid_3 && rs_src2_tag[i] == i_repair_tag_3) begin
          src2_repair_sel[i] = 3'd3;
        end else if (i_repair_valid_4 && rs_src2_tag[i] == i_repair_tag_4) begin
          src2_repair_sel[i] = 3'd4;
        end else if (i_repair_valid_5 && rs_src2_tag[i] == i_repair_tag_5) begin
          src2_repair_sel[i] = 3'd5;
        end else if (i_repair_valid_6 && rs_src2_tag[i] == i_repair_tag_6) begin
          src2_repair_sel[i] = 3'd6;
        end
      end
      if (HAS_SRC3) begin
        src3_cdb_bypass[i] = issue_cdb_valid && !rs_src3_ready[i] && !src3_cdb_pend[i] &&
            rs_src3_tag[i] == issue_cdb_tag;
        src3_cdb_bypass_l1[i] = LANE1_ISSUE_BYPASS && issue_cdb_2_valid &&
            !rs_src3_ready[i] && !src3_cdb_pend[i] && rs_src3_tag[i] == issue_cdb_2_tag;
        src3_repair_sel[i] = 3'd0;
        if (ISSUE_REPAIR_BYPASS && !ALLOC_INDEXED_REPAIR && !rs_src3_ready[i]) begin
          if (i_repair_valid_1 && rs_src3_tag[i] == i_repair_tag_1) begin
            src3_repair_sel[i] = 3'd1;
          end else if (i_repair_valid_2 && rs_src3_tag[i] == i_repair_tag_2) begin
            src3_repair_sel[i] = 3'd2;
          end else if (i_repair_valid_3 && rs_src3_tag[i] == i_repair_tag_3) begin
            src3_repair_sel[i] = 3'd3;
          end else if (i_repair_valid_4 && rs_src3_tag[i] == i_repair_tag_4) begin
            src3_repair_sel[i] = 3'd4;
          end else if (i_repair_valid_5 && rs_src3_tag[i] == i_repair_tag_5) begin
            src3_repair_sel[i] = 3'd5;
          end else if (i_repair_valid_6 && rs_src3_tag[i] == i_repair_tag_6) begin
            src3_repair_sel[i] = 3'd6;
          end
        end
      end else begin
        src3_cdb_bypass[i] = 1'b0;
        src3_cdb_bypass_l1[i] = 1'b0;
        src3_repair_sel[i] = 3'd0;
      end
    end
  end

  // --- Divide gate (DIVIDE_ISSUE_GATE) ---
  // Only load a divide into stage2 while both stage2 and the divider are
  // free of divides. Since stage2 is the divider's only source, it remains
  // idle until that divide issues, even across a ready-low hold.
  // stage2_is_divide must match the stage2_op decode.
  logic divide_blocked;
  assign divide_blocked = DIVIDE_ISSUE_GATE &&
      (i_divider_busy || (stage2_valid && stage2_is_divide));

  // --- Ready check per entry ---
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      entry_ready[i] = rs_valid[i] && !(rs_is_divide[i] && divide_blocked) &&
          (rs_src1_ready[i] || src1_cdb_bypass[i] || src1_cdb_bypass_l1[i] ||
           (src1_repair_sel[i] != 3'd0))
      // Stores need src2 data even when the address uses an immediate.
      // Dispatch marks unused operands ready, so always require src2 readiness.
      && (rs_src2_ready[i] || src2_cdb_bypass[i] || src2_cdb_bypass_l1[i] ||
          (src2_repair_sel[i] != 3'd0)) &&
          (rs_src3_ready[i] || src3_cdb_bypass[i] || src3_cdb_bypass_l1[i] ||
           (src3_repair_sel[i] != 3'd0));
    end
  end

  // --- Issue selection (priority encoder: lowest ready index) ---
  // With CAPTURE_PRIMARY_EFFECTIVE_OPERANDS, issue_idx comes from the grouped
  // select below, which equals this scan for every ready vector.
  logic [$clog2(DEPTH)-1:0] issue_idx_scan;
  always_comb begin
    issue_idx_scan = '0;
    any_ready = 1'b0;
    for (int i = 0; i < DEPTH; i++) begin
      if (entry_ready[i] && !any_ready) begin
        issue_idx_scan = $clog2(DEPTH)'(i);
        any_ready = 1'b1;
      end
    end
  end

  // With effective operand capture, select the lowest ready entry within
  // each group of four, then the lowest ready group. Use the same selection
  // for index, metadata, operands and bypass flags. It must match the serial
  // scan; with no ready entry the index is zero.
  logic issue_src1_bypass, issue_src1_bypass_l1, issue_src2_bypass, issue_src2_bypass_l1;
  logic [ReorderBufferTagWidth-1:0] primary_issue_tag;
  logic primary_issue_use_imm, primary_issue_hint, primary_issue_divide;
  logic [FLEN-1:0] issue_src1_resident, issue_src2_resident;
  logic [FLEN-1:0] src1_resident[DEPTH];
  logic [FLEN-1:0] src2_resident[DEPTH];
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      src1_resident[i] = (src1_repair_sel[i] != 3'd0) ? repair_value_for_sel(src1_repair_sel[i]) :
          rs_src1_value[i];
      src2_resident[i] = (src2_repair_sel[i] != 3'd0) ? repair_value_for_sel(src2_repair_sel[i]) :
          rs_src2_value[i];
    end
  end
  if (CAPTURE_PRIMARY_EFFECTIVE_OPERANDS) begin : gen_issue_group_select
    localparam int unsigned NumGroups = (DEPTH + 3) / 4;
    localparam int unsigned GroupIdxWidth = (NumGroups > 1) ? $clog2(NumGroups) : 1;
    localparam int unsigned NumGroupSlots = 1 << GroupIdxWidth;
    logic [3:0] group_ready[NumGroupSlots];
    // Keep group selection independent of the combined index for timing.
    (* keep = "true" *) logic [NumGroupSlots-1:0] group_any;
    (* keep = "true" *) logic [1:0] group_pick[NumGroupSlots];
    (* keep = "true" *) logic [GroupIdxWidth-1:0] group_idx;
    // Preserve per-group results for the second selection step.
    (* keep = "true" *) logic [FLEN-1:0] group_src1_resident[NumGroupSlots];
    (* keep = "true" *) logic [FLEN-1:0] group_src2_resident[NumGroupSlots];
    (* keep = "true" *) logic [3:0] group_bypass[NumGroupSlots];
    (* keep = "true" *) logic [ReorderBufferTagWidth+2:0] group_metadata[NumGroupSlots];
    assign payload_group_idx = PayloadGroupIdxWidth'(group_idx);
    for (genvar g = 0; g < int'(PayloadGroups); g++) begin : gen_payload_pick
      assign payload_group_pick[g] = group_pick[g];
    end
    (* keep = "true" *) logic src1_bypass, src1_bypass_l1, src2_bypass, src2_bypass_l1;
    always_comb begin
      for (int g = 0; g < int'(NumGroupSlots); g++) begin
        group_src1_resident[g] = '0;
        group_src2_resident[g] = '0;
        group_bypass[g] = '0;
        group_metadata[g] = '0;
        for (int j = 0; j < 4; j++) begin
          group_ready[g][j] = ((4 * g + j) < int'(DEPTH)) ? entry_ready[4*g+j] : 1'b0;
        end
        group_any[g] = |group_ready[g];
        // Zero when the group has no ready entry, so the issue index below
        // is zero with no entry ready, like the scan.
        group_pick[g] = group_ready[g][0] ? 2'd0 : group_ready[g][1] ? 2'd1 :
            group_ready[g][2] ? 2'd2 : group_ready[g][3] ? 2'd3 : 2'd0;
        for (int j = 0; j < 4; j++) begin
          if (((4 * g + j) < int'(DEPTH)) && (group_pick[g] == 2'(j))) begin
            group_metadata[g] = {
              rs_rob_tag[4*g+j], rs_use_imm[4*g+j], rs_writes_cdb_hint[4*g+j], rs_is_divide[4*g+j]
            };
            group_src1_resident[g] = src1_resident[4*g+j];
            group_src2_resident[g] = src2_resident[4*g+j];
            group_bypass[g] = {
              src2_cdb_bypass_l1[4*g+j],
              src2_cdb_bypass[4*g+j],
              src1_cdb_bypass_l1[4*g+j],
              src1_cdb_bypass[4*g+j]
            };
          end
        end
      end
      group_idx = '0;
      for (int g = int'(NumGroupSlots) - 1; g >= 0; g--) begin
        if (group_any[g]) group_idx = GroupIdxWidth'(g);
      end
    end
    // Encode the index for indexed consumers. Payload, metadata and validity
    // use the direct group selections.
    assign issue_idx = $clog2(DEPTH)'({group_idx, group_pick[group_idx]});
    assign {primary_issue_tag, primary_issue_use_imm, primary_issue_hint, primary_issue_divide} =
        group_metadata[group_idx];
    assign issue_src1_resident = group_src1_resident[group_idx];
    assign issue_src2_resident = group_src2_resident[group_idx];
    assign {src2_bypass_l1, src2_bypass, src1_bypass_l1, src1_bypass} = group_bypass[group_idx];
    assign issue_src1_bypass = src1_bypass;
    assign issue_src1_bypass_l1 = src1_bypass_l1;
    assign issue_src2_bypass = src2_bypass;
    assign issue_src2_bypass_l1 = src2_bypass_l1;
  end else begin : gen_issue_bypass_indexed
    assign {primary_issue_tag, primary_issue_use_imm, primary_issue_hint, primary_issue_divide} = {
      rs_rob_tag[issue_idx],
      rs_use_imm[issue_idx],
      rs_writes_cdb_hint[issue_idx],
      rs_is_divide[issue_idx]
    };
    assign issue_idx = issue_idx_scan;
    assign issue_src1_bypass = src1_cdb_bypass[issue_idx];
    assign issue_src1_bypass_l1 = src1_cdb_bypass_l1[issue_idx];
    assign issue_src2_bypass = src2_cdb_bypass[issue_idx];
    assign issue_src2_bypass_l1 = src2_cdb_bypass_l1[issue_idx];
    assign issue_src1_resident = src1_resident[issue_idx];
    assign issue_src2_resident = src2_resident[issue_idx];
  end
`ifndef SYNTHESIS
  always_comb begin
    if (any_ready && !$isunknown(
            {
              issue_idx,
              src1_cdb_bypass,
              src1_cdb_bypass_l1,
              src2_cdb_bypass,
              src2_cdb_bypass_l1,
              issue_src1_bypass,
              issue_src1_bypass_l1,
              issue_src2_bypass,
              issue_src2_bypass_l1
            }
        )) begin
      p_issue_bypass_flags_match_index :
      assert (issue_src1_bypass == src1_cdb_bypass[issue_idx] &&
              issue_src1_bypass_l1 == src1_cdb_bypass_l1[issue_idx] &&
              issue_src2_bypass == src2_cdb_bypass[issue_idx] &&
              issue_src2_bypass_l1 == src2_cdb_bypass_l1[issue_idx]);
      // Case equality permits an unknown resident value when CDB supplies the
      // operand. Check only grouped selection; the indexed mode is identical.
      if (CAPTURE_PRIMARY_EFFECTIVE_OPERANDS) begin
        p_issue_resident_values_match_index :
        assert (issue_src1_resident === src1_resident[issue_idx] &&
                issue_src2_resident === src2_resident[issue_idx]);
      end
    end
    if (CAPTURE_PRIMARY_EFFECTIVE_OPERANDS && !$isunknown(entry_ready)) begin
      p_issue_idx_matches_scan : assert (issue_idx == issue_idx_scan);
    end
  end
`endif

  // --- Head-wait diagnostic observation ---
  // Scan for an entry whose rob_tag matches the query tag. At most one entry
  // can match by construction (each in-flight rob_tag is unique).
  logic [DEPTH-1:0] head_query_match;
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      head_query_match[i] = rs_valid[i] && (rs_rob_tag[i] == i_head_query_tag);
    end
  end
  assign o_head_query_in_rs = |head_query_match;
  assign o_head_query_rs_ready = |(head_query_match & entry_ready);
  assign o_head_query_in_stage2 = (stage2_valid && (stage2_rob_tag == i_head_query_tag)) ||
      stage2b_head_query_match;

  // --- Stage 2 control ---
  // Full flushes squash every valid packet; partial flushes squash younger ones.
  assign stage2_should_flush = stage2_valid && (i_flush_all || (i_flush_en && should_flush_entry(
      stage2_rob_tag, i_flush_tag, i_rob_head_tag
  )));

  // Stage2 content consumed by downstream FU this cycle (one-shot pulse).
  assign stage2_accept = stage2_valid && i_fu_ready && !stage2_should_flush;

  // RS may load stage2 when it is empty or being consumed this cycle.
  assign can_issue_to_stage2 = !stage2_valid || stage2_accept;

  // Loading stage2 requires i_fu_ready; this register does not decouple
  // issue from downstream readiness. Block refills during any flush because
  // the ready scan still sees the pre-flush valid bits.
  assign issue_fire = any_ready && i_fu_ready && can_issue_to_stage2 && !i_flush_all && !i_flush_en;

  // Duplicate the stage2 tag for branch checkpoint and age compares.
  generate
    if (BRANCH_PREDICATE_TAG_ANCHOR) begin : gen_branch_predicate_tag_anchor
      (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
      logic [ReorderBufferTagWidth-1:0] stage2_branch_predicate_tag;

      always_ff @(posedge i_clk) begin
        // stage2_rob_tag is held by the enclosing reset branch, so include
        // i_rst_n here to preserve its exact effective clock enable.
        if (i_rst_n && issue_fire) stage2_branch_predicate_tag <= primary_issue_tag;
      end

      assign o_branch_predicate_tag = stage2_branch_predicate_tag;

`ifndef SYNTHESIS
`ifndef FORMAL
      // The tags have identical input and enable behavior but no reset;
      // compare only while stage2_valid is set.
      always_ff @(posedge i_clk) begin
        if (i_rst_n && stage2_valid) begin
          assert (stage2_branch_predicate_tag == stage2_rob_tag)
          else $error("reservation_station: branch predicate tag twin differs from stage2_rob_tag");
        end
      end
`endif
`endif
    end else begin : gen_no_branch_predicate_tag_anchor
      assign o_branch_predicate_tag = stage2_rob_tag;
    end
  endgenerate

  // ===========================================================================
  // Tag-indexed branch payload (INT only): pc, link_addr, predicted_target
  // ===========================================================================
  // Store branch PC, link and predicted target by ROB tag for port 0's
  // recovery and JALR target checks. JALR's CDB link result travels in imm.
  // Both dispatch slots write; a duplicate stage2 tag supplies the read
  // address for fanout. A valid stage2 packet reads only its own dispatch's
  // row: completion is required before tag reuse, and flush clears stage2
  // on the same edge. Other stations and port 1 do not use these fields.
  generate
    if (TAG_INDEXED_BRANCH_PAYLOAD) begin : gen_tag_indexed_branch_payload
      localparam int unsigned BranchPayloadWidth = 3 * XLEN;

      (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
      logic [ReorderBufferTagWidth-1:0] stage2_branch_payload_tag;

      always_ff @(posedge i_clk) begin
        // Use stage2_rob_tag's effective enable, including reset qualification.
        if (i_rst_n && issue_fire) stage2_branch_payload_tag <= primary_issue_tag;
      end

      logic [BranchPayloadWidth-1:0] branch_payload_rd_data;
      mwp_dist_ram #(
          .ADDR_WIDTH     (ReorderBufferTagWidth),
          .DATA_WIDTH     (BranchPayloadWidth),
          .NUM_WRITE_PORTS(2)
      ) u_branch_payload_ram (
          .i_clk,
          .i_write_enable({dispatch_fire_2, dispatch_fire}),
          .i_write_address({dispatch_rob_tag_2, dispatch_rob_tag}),
          .i_read_address(stage2_branch_payload_tag),
          .i_write_data({
            i_dispatch_2.pc,
            i_dispatch_2.link_addr,
            i_dispatch_2.predicted_target,
            i_dispatch.pc,
            i_dispatch.link_addr,
            i_dispatch.predicted_target
          }),
          .o_read_data(branch_payload_rd_data)
      );

      assign o_issue.pc = branch_payload_rd_data[3*XLEN-1:2*XLEN];
      assign o_issue.link_addr = branch_payload_rd_data[2*XLEN-1:XLEN];
      assign o_issue.predicted_target = branch_payload_rd_data[XLEN-1:0];

`ifndef SYNTHESIS
      // A dispatched ROB tag must not be live in a resident entry or stage2.
      // Simulation permits repeated identical payloads: a live row cannot be
      // rewritten with different data, and two slots naming one tag must agree.
      // Flush cycles are exempt; the core does not dispatch then and killed
      // entries leave on that edge.
      function automatic logic branch_payload_tag_live(input logic [ReorderBufferTagWidth-1:0] tag);
        branch_payload_tag_live = stage2_valid && (stage2_rob_tag == tag);
        for (int i = 0; i < DEPTH; i++) begin
          if (rs_valid[i] && (rs_rob_tag[i] == tag)) branch_payload_tag_live = 1'b1;
        end
      endfunction
      wire [BranchPayloadWidth-1:0] branch_payload_wr_data_1 = {
        i_dispatch.pc, i_dispatch.link_addr, i_dispatch.predicted_target
      };
      wire [BranchPayloadWidth-1:0] branch_payload_wr_data_2 = {
        i_dispatch_2.pc, i_dispatch_2.link_addr, i_dispatch_2.predicted_target
      };
`ifdef FORMAL
      // The standalone model assumes tag uniqueness; the wrapper contains the
      // allocator and asserts the same requirements.
      if (FORMAL_STANDALONE_ENV) begin : gen_assume_branch_payload_ownership
        always_comb begin
          if (dispatch_fire && !i_flush_all && !i_flush_en) begin
            assume (!branch_payload_tag_live(dispatch_rob_tag));
          end
          if (dispatch_fire_2 && !i_flush_all && !i_flush_en) begin
            assume (!branch_payload_tag_live(dispatch_rob_tag_2));
          end
          if (dispatch_fire && dispatch_fire_2) assume (dispatch_rob_tag != dispatch_rob_tag_2);
        end
      end else begin : gen_assert_branch_payload_ownership
        // Check live entries only after reset clears rs_valid and stage2_valid.
        always_comb begin
          if (i_rst_n && dispatch_fire && !i_flush_all && !i_flush_en) begin
            p_branch_payload_slot1_tag_not_live :
            assert (!branch_payload_tag_live(dispatch_rob_tag));
          end
          if (i_rst_n && dispatch_fire_2 && !i_flush_all && !i_flush_en) begin
            p_branch_payload_slot2_tag_not_live :
            assert (!branch_payload_tag_live(dispatch_rob_tag_2));
          end
          if (i_rst_n && dispatch_fire && dispatch_fire_2) begin
            p_branch_payload_slot_tags_distinct : assert (dispatch_rob_tag != dispatch_rob_tag_2);
          end
        end
      end
`else
      // Simulation shadow of the RAM, written in the RAM's port order (slot 2
      // wins a same-tag collision, like the live-value table).
      logic [BranchPayloadWidth-1:0] branch_payload_shadow[2**ReorderBufferTagWidth];
      always_ff @(posedge i_clk) begin
        if (dispatch_fire) branch_payload_shadow[dispatch_rob_tag] <= branch_payload_wr_data_1;
        if (dispatch_fire_2) branch_payload_shadow[dispatch_rob_tag_2] <= branch_payload_wr_data_2;
      end
      always_ff @(posedge i_clk) begin
        if (i_rst_n && !i_flush_all && !i_flush_en) begin
          if (dispatch_fire && branch_payload_tag_live(dispatch_rob_tag)) begin
            assert (branch_payload_shadow[dispatch_rob_tag] == branch_payload_wr_data_1)
            else
              $error(
                  "reservation_station: slot-1 dispatch rewrites live ROB tag %0d's row",
                  dispatch_rob_tag
              );
          end
          if (dispatch_fire_2 && branch_payload_tag_live(dispatch_rob_tag_2)) begin
            assert (branch_payload_shadow[dispatch_rob_tag_2] == branch_payload_wr_data_2)
            else
              $error(
                  "reservation_station: slot-2 dispatch rewrites live ROB tag %0d's row",
                  dispatch_rob_tag_2
              );
          end
          if (dispatch_fire && dispatch_fire_2 && (dispatch_rob_tag == dispatch_rob_tag_2)) begin
            assert (branch_payload_wr_data_1 == branch_payload_wr_data_2)
            else
              $error(
                  "reservation_station: both slots dispatch ROB tag %0d with different rows",
                  dispatch_rob_tag
              );
          end
        end
        if (i_rst_n && stage2_valid) begin
          assert (stage2_branch_payload_tag == stage2_rob_tag)
          else $error("reservation_station: branch payload tag twin differs from stage2_rob_tag");
        end
      end

      // Carry each packet's branch words through a separate simulation copy.
      // The tag-indexed RAM must return those same words in stage2.
      logic [BranchPayloadWidth-1:0] branch_payload_entry_shadow  [DEPTH];
      logic [BranchPayloadWidth-1:0] branch_payload_stage2_shadow;
      always_ff @(posedge i_clk) begin
        if (dispatch_fire) branch_payload_entry_shadow[free_idx] <= branch_payload_wr_data_1;
        if (dispatch_fire_2) branch_payload_entry_shadow[alloc_idx_2] <= branch_payload_wr_data_2;
        if (i_rst_n && issue_fire) begin
          branch_payload_stage2_shadow <= branch_payload_entry_shadow[issue_idx];
        end
      end
      always_ff @(posedge i_clk) begin
        if (i_rst_n && stage2_valid) begin
          assert (branch_payload_rd_data == branch_payload_stage2_shadow)
          else
            $error(
                "reservation_station: side RAM row for ROB tag %0d differs from the stage2 packet",
                stage2_rob_tag
            );
        end
      end
`endif
`endif
    end else begin : gen_no_tag_indexed_branch_payload
      assign o_issue.pc = '0;
      assign o_issue.link_addr = '0;
      assign o_issue.predicted_target = '0;
    end
  endgenerate

  // --- Issue-width performance event ---
  // Port 0 fires with at least two ready entries. x & (x-1) clears the lowest
  // set bit, so a nonzero result means at least two were set. Register for
  // counter timing; port-1 issue is not subtracted.
  logic perf_two_ready_one_issued_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      perf_two_ready_one_issued_q <= 1'b0;
    end else begin
      perf_two_ready_one_issued_q <= issue_fire && |(entry_ready & (entry_ready - 1'b1));
    end
  end
  assign o_perf_two_ready_one_issued = perf_two_ready_one_issued_q;

  function automatic logic [FLEN-1:0] repair_value_for_sel(input logic [2:0] sel);
    begin
      case (sel)
        3'd1: repair_value_for_sel = i_repair_value_1;
        3'd2: repair_value_for_sel = i_repair_value_2;
        3'd3: repair_value_for_sel = i_repair_value_3;
        3'd4: repair_value_for_sel = i_repair_value_4;
        3'd5: repair_value_for_sel = i_repair_value_5;
        3'd6: repair_value_for_sel = i_repair_value_6;
        default: repair_value_for_sel = '0;
      endcase
    end
  endfunction

  // --- Current issue payload peek ---
  // The generic RS reads this from stage2.
  assign o_next_issue_valid = stage2_valid;
  assign o_next_issue_is_sc = stage2_valid && stage2_is_sc;
  assign o_next_issue_needs_lq = stage2_valid && stage2_mem_needs_lq;

  // Expose the selected tag and mem_needs_lq while loading stage2 so the
  // LQ can register its address-update match before downstream issue.
  if (PREISSUE_VALID_COFACTOR) begin : gen_preissue_cofactor
    // Use four merged-lane-valid combinations, or eight combinations of raw
    // lane occupancy and early-load eligibility for MEM_RS.
    localparam int NumCandidates = PREISSUE_RAW_WAKEUP ? 8 : 4;
    logic [ReorderBufferTagWidth-1:0] candidate_tag[NumCandidates];
    logic [DEPTH-1:0] candidate_ready[NumCandidates];
    for (genvar valids = 0; valids < NumCandidates; valids++) begin : gen_candidate
      localparam bit Valid0 = PREISSUE_RAW_WAKEUP ?
          (((valids & 1) != 0) || ((valids & 4) != 0)) : ((valids & 1) != 0);
      localparam bit Valid1 = PREISSUE_RAW_WAKEUP ?
          (((valids & 2) != 0) || (((valids & 1) != 0) && ((valids & 4) != 0))) :
          ((valids & 2) != 0);
      wire [ReorderBufferTagWidth-1:0] tag0 = PREISSUE_RAW_WAKEUP ?
          (((valids & 1) != 0) ?
           i_pre_issue_raw_tags[0 +: ReorderBufferTagWidth] :
           i_pre_issue_raw_tags[2*ReorderBufferTagWidth +: ReorderBufferTagWidth]) :
          issue_cdb_tag;
      wire [ReorderBufferTagWidth-1:0] tag1 = PREISSUE_RAW_WAKEUP ?
          ((((valids & 1) != 0) && ((valids & 2) == 0)) ?
           i_pre_issue_raw_tags[2*ReorderBufferTagWidth +: ReorderBufferTagWidth] :
           i_pre_issue_raw_tags[ReorderBufferTagWidth +: ReorderBufferTagWidth]) :
          issue_cdb_2_tag;
      logic [DEPTH-1:0] ready;
      logic [$clog2(DEPTH)-1:0] index;
      logic found;
      always_comb begin
        for (int entry = 0; entry < DEPTH; entry++) begin
          ready[entry] = rs_valid[entry] &&
              (rs_src1_ready[entry] || (src1_repair_sel[entry] != 3'd0) ||
               (Valid0 && !rs_src1_ready[entry] && !src1_cdb_pend[entry] &&
                (ISSUE_CDB_TAG_SHADOW ? rs_src1_issue_tag[entry] : rs_src1_tag[entry]) ==
                    tag0) ||
               (LANE1_ISSUE_BYPASS && Valid1 &&
                !rs_src1_ready[entry] && !src1_cdb_pend[entry] &&
                (ISSUE_CDB_TAG_SHADOW ? rs_src1_issue_tag[entry] : rs_src1_tag[entry]) ==
                    tag1)) &&
              (rs_src2_ready[entry] || (src2_repair_sel[entry] != 3'd0) ||
               (Valid0 && !rs_src2_ready[entry] && !src2_cdb_pend[entry] &&
                (ISSUE_CDB_TAG_SHADOW ? rs_src2_issue_tag[entry] : rs_src2_tag[entry]) ==
                    tag0) ||
               (LANE1_ISSUE_BYPASS && Valid1 &&
                !rs_src2_ready[entry] && !src2_cdb_pend[entry] &&
                (ISSUE_CDB_TAG_SHADOW ? rs_src2_issue_tag[entry] : rs_src2_tag[entry]) ==
                    tag1)) &&
              (rs_src3_ready[entry] || (src3_repair_sel[entry] != 3'd0) ||
               (HAS_SRC3 && Valid0 && !rs_src3_ready[entry] && !src3_cdb_pend[entry] &&
                rs_src3_tag[entry] == tag0) ||
               (HAS_SRC3 && LANE1_ISSUE_BYPASS && Valid1 &&
                !rs_src3_ready[entry] && !src3_cdb_pend[entry] &&
                rs_src3_tag[entry] == tag1));
        end
        index = '0;
        found = 1'b0;
        for (int entry = 0; entry < DEPTH; entry++) begin
          if (ready[entry] && !found) begin
            index = $clog2(DEPTH)'(entry);
            found = 1'b1;
          end
        end
      end
      assign candidate_ready[valids] = ready;
      if (PREISSUE_READY_EXPORT) begin : gen_tag
        // The LQ matches through the exported ready vectors, so this tag
        // feeds only the look-ahead tag outputs and their checks.
        assign candidate_tag[valids] = rs_rob_tag[index];
      end else begin : gen_tag
        (* keep = "true" *) logic [ReorderBufferTagWidth-1:0] kept_tag;
        assign kept_tag = rs_rob_tag[index];
        assign candidate_tag[valids] = kept_tag;
      end
      assign o_pre_issue_rob_tags[valids*ReorderBufferTagWidth +: ReorderBufferTagWidth] =
          candidate_tag[valids];
    end
    if (PREISSUE_READY_EXPORT) begin : gen_ready_export
      // Keep each exported ready vector separate for the LQ's per-entry selection.
      (* keep = "true" *) logic [DEPTH-1:0] export_ready[NumCandidates];
      for (genvar c = 0; c < NumCandidates; c++) begin : gen_export
        // The early-load token fills only an empty lane. With both lanes valid,
        // candidates 7 and 3 therefore have identical tags and ready vectors.
        localparam int Source = (PREISSUE_RAW_WAKEUP && (c == 7)) ? 3 : c;
        assign export_ready[c] = candidate_ready[Source];
        assign o_pre_issue_ready[c*DEPTH+:DEPTH] = export_ready[c];
      end
      for (genvar e = 0; e < DEPTH; e++) begin : gen_export_tag
        assign o_pre_issue_entry_tags[e*ReorderBufferTagWidth +: ReorderBufferTagWidth] =
            rs_rob_tag[e];
      end
`ifdef RS_PRETAG_LOCAL_PROOF
      // Each candidate's lowest ready entry supplies its tag; no ready entry
      // selects zero. The chosen candidate must match issue_idx and any_ready.
      logic [$clog2(DEPTH)-1:0] f_first[NumCandidates];
      always_comb begin
        for (int c = 0; c < NumCandidates; c++) begin
          f_first[c] = '0;
          for (int entry = DEPTH - 1; entry >= 0; entry--) begin
            if (o_pre_issue_ready[c*DEPTH+entry]) f_first[c] = $clog2(DEPTH)'(entry);
          end
        end
      end
      for (genvar c = 0; c < NumCandidates; c++) begin : gen_f_candidate
        always_comb begin
          assert (o_pre_issue_entry_tags[f_first[c]*ReorderBufferTagWidth +:
                                         ReorderBufferTagWidth] ==
                  o_pre_issue_rob_tags[c*ReorderBufferTagWidth +: ReorderBufferTagWidth]);
        end
      end
      always_comb begin
        assert (f_first[o_pre_issue_sel] == issue_idx);
        assert ((|o_pre_issue_ready[o_pre_issue_sel*DEPTH+:DEPTH]) == any_ready);
`ifdef RS_PRETAG_READY_VECTOR_PROOF
        assert (o_pre_issue_ready[o_pre_issue_sel*DEPTH+:DEPTH] == entry_ready);
`endif
      end
`endif
    end else begin : gen_no_ready_export
      assign o_pre_issue_ready = '0;
      assign o_pre_issue_entry_tags = '0;
    end
    if (PREISSUE_RAW_WAKEUP) begin : gen_raw_select
      assign o_pre_issue_sel = i_pre_issue_raw_valid;
      wire [ReorderBufferTagWidth-1:0] low_tag = i_pre_issue_raw_valid[1] ?
          (i_pre_issue_raw_valid[0] ? candidate_tag[3] : candidate_tag[2]) :
          (i_pre_issue_raw_valid[0] ? candidate_tag[1] : candidate_tag[0]);
      wire [ReorderBufferTagWidth-1:0] high_tag = i_pre_issue_raw_valid[1] ?
          (i_pre_issue_raw_valid[0] ? candidate_tag[7] : candidate_tag[6]) :
          (i_pre_issue_raw_valid[0] ? candidate_tag[5] : candidate_tag[4]);
      assign o_pre_issue_rob_tag = i_pre_issue_raw_valid[2] ? high_tag : low_tag;
    end else begin : gen_merged_select
      assign o_pre_issue_sel = {issue_cdb_2_valid, issue_cdb_valid};
      assign o_pre_issue_rob_tag = issue_cdb_2_valid ?
          (issue_cdb_valid ? candidate_tag[3] : candidate_tag[2]) :
          (issue_cdb_valid ? candidate_tag[1] : candidate_tag[0]);
    end
  end else begin : gen_preissue_direct
    assign o_pre_issue_rob_tag = rs_rob_tag[issue_idx];
    assign o_pre_issue_rob_tags = {(PREISSUE_RAW_WAKEUP ? 8 : 4) {o_pre_issue_rob_tag}};
    assign o_pre_issue_sel = '0;
    assign o_pre_issue_ready = '0;
    assign o_pre_issue_entry_tags = '0;
  end
`ifdef RS_PRETAG_LOCAL_PROOF
  always_comb assert (o_pre_issue_rob_tag == rs_rob_tag[issue_idx]);
`endif
`ifndef SYNTHESIS
  always @(posedge i_clk) begin
    if (i_rst_n && any_ready) assert (o_pre_issue_rob_tag == rs_rob_tag[issue_idx]);
  end
`endif
  assign o_pre_issue_needs_lq = issue_fire && pl_mem_needs_lq;

  // --- Issue port assignment ---
  // Payload is driven continuously; valid requires stage2_valid and FU ready.
  // Output valid omits flush for timing. A squashed packet can still issue,
  // so its consumers must discard it:
  //   - LQ/SQ full flush ignores the update. Partial flush clears the matching
  //     entry on the same edge, making any address write unobservable.
  //   - FU shims and CDB adapters discard flushed results; the arbiter also
  //     drops them on full flush.
  //   - dmmu registers memory issues and must apply its iss_killed age check
  //     so a delayed fault or address cannot reach a reused ROB tag.
  // A flushed stage2 packet is not accepted internally and is cleared at the edge.
  assign o_issue.valid = stage2_valid && i_fu_ready;
  assign o_issue.rob_tag = stage2_rob_tag;
  assign o_issue.op = stage2_op;
  // Effective operand capture stores final src1/src2 values. Otherwise,
  // a three-way CDB mux follows stage2.
  generate
    if (CAPTURE_PRIMARY_EFFECTIVE_OPERANDS) begin : gen_primary_effective_operand_outputs
      assign o_issue.src1_value = stage2_src1_value;
      assign o_issue.src2_value = stage2_src2_value;
    end else begin : gen_primary_legacy_operand_outputs
      // Select the CDB value captured at issue. Keep the expressions on the
      // ports and replicate mask bits for fanout.
      assign o_issue.src1_value =
          (stage2_src1_value & ~stage2_src1_bypass_mask & ~stage2_src1_bypass_mask_l1) |
          (stage2_cdb_value & stage2_src1_bypass_mask) |
          (stage2_cdb_value_l1 & stage2_src1_bypass_mask_l1);
      assign o_issue.src2_value =
          (stage2_src2_value & ~stage2_src2_bypass_mask & ~stage2_src2_bypass_mask_l1) |
          (stage2_cdb_value & stage2_src2_bypass_mask) |
          (stage2_cdb_value_l1 & stage2_src2_bypass_mask_l1);
    end
  endgenerate
  assign o_issue.src3_value = HAS_SRC3 ?
      ((stage2_src3_value & ~stage2_src3_bypass_mask & ~stage2_src3_bypass_mask_l1) |
       (stage2_cdb_value & stage2_src3_bypass_mask) |
       (stage2_cdb_value_l1 & stage2_src3_bypass_mask_l1)) : '0;
  assign o_issue.imm = stage2_imm;
  assign o_issue.jalr_imm = stage2_jalr_imm;
  assign o_issue.use_imm = stage2_use_imm;
  assign o_issue.rm = stage2_rm;
  assign o_issue.predicted_taken = stage2_predicted_taken;
  assign o_issue.predicted_target_ok = stage2_predicted_target_ok;
  assign o_issue.is_compressed = stage2_is_compressed;
  // predicted_target, pc and link_addr come from the tag-indexed side RAM
  // (gen_tag_indexed_branch_payload above), not from the payload RAM or stage2.
  assign o_issue.is_fp_mem = stage2_is_fp_mem;
  assign o_issue.mem_needs_lq = stage2_mem_needs_lq;
  assign o_issue.mem_needs_sq = stage2_mem_needs_sq;
  assign o_issue.mem_size = stage2_mem_size;
  assign o_issue.mem_signed = stage2_mem_signed;
  assign o_issue.csr_addr = stage2_csr_addr;
  assign o_issue.csr_imm = stage2_csr_imm;
  assign o_issue.has_checkpoint = stage2_has_checkpoint;
  assign o_issue.checkpoint_id = stage2_checkpoint_id;
  assign o_issue.is_call = stage2_is_call;
  assign o_issue.is_return = stage2_is_return;
  assign o_issue.is_branch_class = stage2_is_branch_class;
  assign o_issue.is_jal = stage2_is_jal;
  assign o_issue.is_jalr = stage2_is_jalr;
  assign o_issue.branch_op = stage2_branch_op;

  assign o_issue_writes_cdb_hint = stage2_writes_cdb_hint;

  // ===========================================================================
  // Second Issue Port (DUAL_ISSUE): select, payload copy, stage2b, o_issue_2
  // ===========================================================================
  generate
    if (DUAL_ISSUE) begin : gen_issue2
      // Port 1 excludes port 0's lowest-ready pick even when port 0 is blocked.
      // If the window contains any ready entry, its lowest is also the global
      // lowest; otherwise port 1 stays idle. Port 0's selector is independent.
      localparam int unsigned Issue2Window =
          (ISSUE2_WINDOW == 0 || ISSUE2_WINDOW > DEPTH) ? DEPTH : ISSUE2_WINDOW;
      logic [$clog2(Issue2Window)-1:0] issue_idx_2_window;
      logic [Issue2Window-1:0] issue_sel_2_window;
      rs_issue2_selector #(
          .DEPTH(Issue2Window)
      ) u_issue2_selector (
          .i_ready         (entry_ready[Issue2Window-1:0]),
          .i_branch_class  (rs_is_branch_class[Issue2Window-1:0]),
          .o_issue_2_valid (any_ready_2),
          .o_issue_2_idx   (issue_idx_2_window),
          .o_issue_2_onehot(issue_sel_2_window)
      );
      assign issue_idx_2 = $clog2(DEPTH)'(issue_idx_2_window);
      always_comb begin
        issue_sel_2 = '0;
        issue_sel_2[Issue2Window-1:0] = issue_sel_2_window;
      end

      always_comb begin
        issue_sel_2_ohread = '0;
        issue_sel_2_ohread[DEPTH-1:0] = issue_sel_2;
      end

      // The second RAM copy shares dispatch writes and uses port 1's one-hot
      // winner for its LVT read.
      logic [PayloadWidth-1:0] payload_rd_data_b;
      mwp_dist_ram_ohread #(
          .ADDR_WIDTH     ($clog2(DEPTH)),
          .DATA_WIDTH     (PayloadWidth),
          .NUM_WRITE_PORTS(2)
      ) u_payload_ram_2 (
          .i_clk,
          .i_write_enable ({dispatch_fire_2, dispatch_fire}),
          .i_write_address({alloc_idx_2, free_idx}),
          .i_read_address (issue_idx_2),
          .i_read_onehot  (issue_sel_2_ohread),
          .i_write_data   ({payload_wr_data_2, payload_wr_data}),
          .o_read_data    (payload_rd_data_b)
      );

      logic [riscv_pkg::InstrOpWidth-1:0] pl2_op_bits;
      logic [                   XLEN-1:0] pl2_imm;
      logic [                       11:0] pl2_jalr_imm;
      logic [                        2:0] pl2_rm;
      logic                               pl2_predicted_taken;
      logic                               pl2_predicted_target_ok;
      logic                               pl2_is_compressed;
      logic                               pl2_is_fp_mem;
      logic                               pl2_mem_needs_lq;
      logic                               pl2_mem_needs_sq;
      logic [                        1:0] pl2_mem_size_bits;
      logic                               pl2_mem_signed;
      logic [                       11:0] pl2_csr_addr;
      logic [                        4:0] pl2_csr_imm;
      logic                               pl2_has_checkpoint;
      logic [      CheckpointIdWidth-1:0] pl2_checkpoint_id;
      logic                               pl2_is_call;
      logic                               pl2_is_return;
      logic                               pl2_is_branch_class;
      logic                               pl2_is_jal;
      logic                               pl2_is_jalr;
      logic [                        2:0] pl2_branch_op_bits;

      assign {pl2_op_bits, pl2_imm, pl2_jalr_imm, pl2_rm, pl2_predicted_taken,
              pl2_predicted_target_ok, pl2_is_compressed,
              pl2_is_fp_mem, pl2_mem_needs_lq, pl2_mem_needs_sq,
              pl2_mem_size_bits, pl2_mem_signed,
              pl2_csr_addr, pl2_csr_imm,
              pl2_has_checkpoint, pl2_checkpoint_id, pl2_is_call, pl2_is_return,
              pl2_is_branch_class, pl2_is_jal, pl2_is_jalr, pl2_branch_op_bits} = payload_rd_data_b;

      // stage2b pipeline register bank. Its operand FFs capture the final
      // issue-time values (live CDB, resident, or repair); there is no
      // operand mux after these registers.
      logic [ReorderBufferTagWidth-1:0] stage2b_rob_tag;
      // Limit port-1 opcode fanout.
      (* max_fanout = 48 *) riscv_pkg::instr_op_e stage2b_op;
      logic [FLEN-1:0] stage2b_src1_value;
      logic [FLEN-1:0] stage2b_src2_value;
      logic [FLEN-1:0] stage2b_src3_value;
      logic [XLEN-1:0] stage2b_imm;
      logic [11:0] stage2b_jalr_imm;
      logic stage2b_use_imm;
      logic [5:0] stage2b_shift_amount;
      logic stage2b_writes_cdb_hint;
      logic [2:0] stage2b_rm;
      logic stage2b_predicted_taken;
      logic stage2b_predicted_target_ok;
      logic stage2b_is_compressed;
      logic stage2b_is_fp_mem;
      logic stage2b_mem_needs_lq;
      logic stage2b_mem_needs_sq;
      riscv_pkg::mem_size_e stage2b_mem_size;
      logic stage2b_mem_signed;
      logic [11:0] stage2b_csr_addr;
      logic [4:0] stage2b_csr_imm;
      logic stage2b_has_checkpoint;
      logic [CheckpointIdWidth-1:0] stage2b_checkpoint_id;
      logic stage2b_is_call;
      logic stage2b_is_return;
      logic stage2b_is_branch_class;
      logic stage2b_is_jal;
      logic stage2b_is_jalr;
      riscv_pkg::branch_taken_op_e stage2b_branch_op;

      logic [ReorderBufferTagWidth-1:0] issue2_rob_tag_selected;
      logic [FLEN-1:0] issue2_src1_value_selected;
      logic [FLEN-1:0] issue2_src2_value_selected;
      logic [FLEN-1:0] issue2_src3_value_selected;
      logic issue2_src1_cdb_bypass_selected;
      logic issue2_src2_cdb_bypass_selected;
      logic issue2_src3_cdb_bypass_selected;
      logic issue2_src1_cdb_bypass_l1_selected;
      logic issue2_src2_cdb_bypass_l1_selected;
      logic issue2_src3_cdb_bypass_l1_selected;
      logic issue2_use_imm_selected;
      logic issue2_writes_cdb_hint_selected;
      logic [FLEN-1:0] issue2_src1_value_effective;
      logic [FLEN-1:0] issue2_src2_value_effective;
      logic [FLEN-1:0] issue2_src3_value_effective;
      logic issue2_shift_uses_imm_selected;
      logic [5:0] issue2_shift_imm_selected;

      logic stage2b_should_flush;
      logic stage2b_accept;
      logic can_issue_to_stage2b;

`ifndef SYNTHESIS
`ifndef FORMAL
      // Simulation-only reference. It follows the stage2b valid lifetime and
      // independently records the three-arm CDB bypass result on each issue
      // edge, so the captured operands are checked across stalls, flushes,
      // and back-to-back refill.
      logic stage2b_operand_oracle_valid_q;
      logic [FLEN-1:0] stage2b_src1_value_oracle_q;
      logic [FLEN-1:0] stage2b_src2_value_oracle_q;
      logic [FLEN-1:0] stage2b_src3_value_oracle_q;
`endif
`endif

      // Resolve each entry's CDB bypass before the one-hot operand read. Lane 0
      // wins duplicate matches. The selected bypass flags serve only the
      // simulation reference.
      always_comb begin
        issue2_src1_value_effective = '0;
        issue2_src2_value_effective = '0;
        issue2_src3_value_effective = '0;
        for (int i = 0; i < DEPTH; i++) begin
          issue2_src1_value_effective |= (src1_cdb_bypass[i] ? i_cdb.value :
              src1_cdb_bypass_l1[i] ? i_cdb_2.value :
              (src1_repair_sel[i] != 3'd0) ? repair_value_for_sel(
              src1_repair_sel[i]
          ) : rs_src1_value[i]) & {FLEN{issue_sel_2[i]}};
          issue2_src2_value_effective |= (src2_cdb_bypass[i] ? i_cdb.value :
              src2_cdb_bypass_l1[i] ? i_cdb_2.value :
              (src2_repair_sel[i] != 3'd0) ? repair_value_for_sel(
              src2_repair_sel[i]
          ) : rs_src2_value[i]) & {FLEN{issue_sel_2[i]}};
          if (HAS_SRC3) begin
            issue2_src3_value_effective |= (src3_cdb_bypass[i] ? i_cdb.value :
                src3_cdb_bypass_l1[i] ? i_cdb_2.value :
                (src3_repair_sel[i] != 3'd0) ? repair_value_for_sel(src3_repair_sel[i]) :
                rs_src3_value[i]) & {FLEN{issue_sel_2[i]}};
          end
        end
      end

      always_comb begin
        issue2_rob_tag_selected = '0;
        issue2_src1_value_selected = '0;
        issue2_src2_value_selected = '0;
        issue2_src3_value_selected = '0;
        issue2_src1_cdb_bypass_selected = 1'b0;
        issue2_src2_cdb_bypass_selected = 1'b0;
        issue2_src3_cdb_bypass_selected = 1'b0;
        issue2_src1_cdb_bypass_l1_selected = 1'b0;
        issue2_src2_cdb_bypass_l1_selected = 1'b0;
        issue2_src3_cdb_bypass_l1_selected = 1'b0;
        issue2_use_imm_selected = 1'b0;
        issue2_writes_cdb_hint_selected = 1'b0;

        issue2_shift_uses_imm_selected = 1'b0;
        issue2_shift_imm_selected = '0;
        for (int i = 0; i < DEPTH; i++) begin
          issue2_rob_tag_selected |= rs_rob_tag[i] & {ReorderBufferTagWidth{issue_sel_2[i]}};
          issue2_shift_uses_imm_selected |= rs_shift_uses_imm[i] & issue_sel_2[i];
          issue2_shift_imm_selected |= rs_shift_imm[i] & {6{issue_sel_2[i]}};
          issue2_src1_value_selected |= ((src1_repair_sel[i] != 3'd0) ? repair_value_for_sel(
              src1_repair_sel[i]
          ) : rs_src1_value[i]) & {FLEN{issue_sel_2[i]}};
          issue2_src2_value_selected |= ((src2_repair_sel[i] != 3'd0) ? repair_value_for_sel(
              src2_repair_sel[i]
          ) : rs_src2_value[i]) & {FLEN{issue_sel_2[i]}};
          issue2_src1_cdb_bypass_selected |= src1_cdb_bypass[i] & issue_sel_2[i];
          issue2_src2_cdb_bypass_selected |= src2_cdb_bypass[i] & issue_sel_2[i];
          issue2_src1_cdb_bypass_l1_selected |= src1_cdb_bypass_l1[i] & issue_sel_2[i];
          issue2_src2_cdb_bypass_l1_selected |= src2_cdb_bypass_l1[i] & issue_sel_2[i];
          issue2_use_imm_selected |= rs_use_imm[i] & issue_sel_2[i];
          issue2_writes_cdb_hint_selected |= rs_writes_cdb_hint[i] & issue_sel_2[i];
          if (HAS_SRC3) begin
            issue2_src3_value_selected |= ((src3_repair_sel[i] != 3'd0) ? repair_value_for_sel(
                src3_repair_sel[i]
            ) : rs_src3_value[i]) & {FLEN{issue_sel_2[i]}};
            issue2_src3_cdb_bypass_selected |= src3_cdb_bypass[i] & issue_sel_2[i];
            issue2_src3_cdb_bypass_l1_selected |= src3_cdb_bypass_l1[i] & issue_sel_2[i];
          end
        end
      end

      // issue2_src2_value_effective feeds both the wide src2 operand FFs and
      // the six shift-amount FFs, so both see the same live CDB selection and
      // capture/hold lifetime.

      assign stage2b_should_flush = stage2b_valid &&
          (i_flush_all || (i_flush_en && should_flush_entry(
          stage2b_rob_tag, i_flush_tag, i_rob_head_tag
      )));
      assign stage2b_accept = stage2b_valid && i_fu_ready_2 && !stage2b_should_flush;
      assign can_issue_to_stage2b = !stage2b_valid || stage2b_accept;
      assign issue_fire_2 = any_ready_2 && i_fu_ready_2 && can_issue_to_stage2b &&
          !i_flush_all && !i_flush_en;

      always_ff @(posedge i_clk) begin
        if (!i_rst_n) begin
          stage2b_valid <= 1'b0;
        end else if (stage2b_should_flush) begin
          stage2b_valid <= 1'b0;
        end else if (issue_fire_2) begin
          stage2b_valid <= 1'b1;
          stage2b_rob_tag <= issue2_rob_tag_selected;
          stage2b_op <= riscv_pkg::instr_op_e'(pl2_op_bits);
          // Live CDB data overrides resident or repair data. Distinct lane tags
          // allow at most one live match.
          stage2b_src1_value <= issue2_src1_value_effective;
          stage2b_src2_value <= issue2_src2_value_effective;
          stage2b_shift_amount <= issue2_shift_uses_imm_selected ? issue2_shift_imm_selected :
              issue2_src2_value_effective[5:0];
          if (HAS_SRC3) begin
            stage2b_src3_value <= issue2_src3_value_effective;
          end
          stage2b_imm <= pl2_imm;
          stage2b_jalr_imm <= pl2_jalr_imm;
          stage2b_use_imm <= issue2_use_imm_selected;
          stage2b_writes_cdb_hint <= TRACK_INT_WRITEBACK_HINT ?
              issue2_writes_cdb_hint_selected : 1'b0;
          stage2b_rm <= pl2_rm;
          stage2b_predicted_taken <= pl2_predicted_taken;
          stage2b_predicted_target_ok <= pl2_predicted_target_ok;
          stage2b_is_compressed <= pl2_is_compressed;
          stage2b_is_fp_mem <= pl2_is_fp_mem;
          stage2b_mem_needs_lq <= pl2_mem_needs_lq;
          stage2b_mem_needs_sq <= pl2_mem_needs_sq;
          stage2b_mem_size <= riscv_pkg::mem_size_e'(pl2_mem_size_bits);
          stage2b_mem_signed <= pl2_mem_signed;
          stage2b_csr_addr <= pl2_csr_addr;
          stage2b_csr_imm <= pl2_csr_imm;
          stage2b_has_checkpoint <= pl2_has_checkpoint;
          stage2b_checkpoint_id <= pl2_checkpoint_id;
          stage2b_is_call <= pl2_is_call;
          stage2b_is_return <= pl2_is_return;
          stage2b_is_branch_class <= pl2_is_branch_class;
          stage2b_is_jal <= pl2_is_jal;
          stage2b_is_jalr <= pl2_is_jalr;
          stage2b_branch_op <= riscv_pkg::branch_taken_op_e'(pl2_branch_op_bits);
        end else if (stage2b_accept) begin
          stage2b_valid <= 1'b0;
        end
      end

`ifndef SYNTHESIS
`ifndef FORMAL
      always_ff @(posedge i_clk) begin
        if (!i_rst_n) begin
          stage2b_operand_oracle_valid_q <= 1'b0;
        end else begin
          assert (stage2b_operand_oracle_valid_q == stage2b_valid)
          else $error("RS: issue-2 operand oracle valid diverged from stage2b");
          if (stage2b_valid) begin
            assert (stage2b_src1_value == stage2b_src1_value_oracle_q)
            else $error("RS: issue-2 src1 effective capture differs from the reference");
            assert (stage2b_src2_value == stage2b_src2_value_oracle_q)
            else $error("RS: issue-2 src2 effective capture differs from the reference");
            if (HAS_SRC3) begin
              assert (stage2b_src3_value == stage2b_src3_value_oracle_q)
              else $error("RS: issue-2 src3 effective capture differs from the reference");
            end
          end

          if (stage2b_should_flush) begin
            stage2b_operand_oracle_valid_q <= 1'b0;
          end else if (issue_fire_2) begin
            stage2b_operand_oracle_valid_q <= 1'b1;
            assert (!(issue2_src1_cdb_bypass_selected && issue2_src1_cdb_bypass_l1_selected))
            else $error("RS: issue-2 src1 matched both CDB lanes");
            assert (!(issue2_src2_cdb_bypass_selected && issue2_src2_cdb_bypass_l1_selected))
            else $error("RS: issue-2 src2 matched both CDB lanes");
            stage2b_src1_value_oracle_q <= issue2_src1_cdb_bypass_selected ? i_cdb.value :
                issue2_src1_cdb_bypass_l1_selected ? i_cdb_2.value : issue2_src1_value_selected;
            stage2b_src2_value_oracle_q <= issue2_src2_cdb_bypass_selected ? i_cdb.value :
                issue2_src2_cdb_bypass_l1_selected ? i_cdb_2.value : issue2_src2_value_selected;
            if (HAS_SRC3) begin
              assert (!(issue2_src3_cdb_bypass_selected && issue2_src3_cdb_bypass_l1_selected))
              else $error("RS: issue-2 src3 matched both CDB lanes");
              stage2b_src3_value_oracle_q <= issue2_src3_cdb_bypass_selected ? i_cdb.value :
                  issue2_src3_cdb_bypass_l1_selected ? i_cdb_2.value : issue2_src3_value_selected;
            end
          end else if (stage2b_accept) begin
            stage2b_operand_oracle_valid_q <= 1'b0;
          end
        end
      end
`endif
`endif

      // Port-1 issue follows the same flush rule: its CDB adapter drops flushed
      // results, and the arbiter also drops them on full flush.
      assign o_issue_2.valid = stage2b_valid && i_fu_ready_2;
      assign o_issue_2.rob_tag = stage2b_rob_tag;
      assign o_issue_2.op = stage2b_op;
      // Drive the captured operands directly from stage2b for timing.
      assign o_issue_2.src1_value = stage2b_src1_value;
      assign o_issue_2.src2_value = stage2b_src2_value;
      assign o_issue_2.src3_value = HAS_SRC3 ? stage2b_src3_value : '0;
      assign o_issue_2.imm = stage2b_imm;
      assign o_issue_2.jalr_imm = stage2b_jalr_imm;
      assign o_issue_2.use_imm = stage2b_use_imm;
      assign o_issue_2.rm = stage2b_rm;
      assign o_issue_2.predicted_taken = stage2b_predicted_taken;
      assign o_issue_2.predicted_target_ok = stage2b_predicted_target_ok;
      assign o_issue_2.is_compressed = stage2b_is_compressed;
      // Branches never issue on port 1, so it carries no predicted target,
      // pc or link address.
      assign o_issue_2.predicted_target = '0;
      assign o_issue_2.is_fp_mem = stage2b_is_fp_mem;
      assign o_issue_2.mem_needs_lq = stage2b_mem_needs_lq;
      assign o_issue_2.mem_needs_sq = stage2b_mem_needs_sq;
      assign o_issue_2.mem_size = stage2b_mem_size;
      assign o_issue_2.mem_signed = stage2b_mem_signed;
      assign o_issue_2.csr_addr = stage2b_csr_addr;
      assign o_issue_2.csr_imm = stage2b_csr_imm;
      assign o_issue_2.pc = '0;
      assign o_issue_2.link_addr = '0;
      assign o_issue_2.has_checkpoint = stage2b_has_checkpoint;
      assign o_issue_2.checkpoint_id = stage2b_checkpoint_id;
      assign o_issue_2.is_call = stage2b_is_call;
      assign o_issue_2.is_return = stage2b_is_return;
      assign o_issue_2.is_branch_class = stage2b_is_branch_class;
      assign o_issue_2.is_jal = stage2b_is_jal;
      assign o_issue_2.is_jalr = stage2b_is_jalr;
      assign o_issue_2.branch_op = stage2b_branch_op;
      assign o_issue_writes_cdb_hint_2 = stage2b_writes_cdb_hint;
      assign o_issue_shift_amount_2 = stage2b_shift_amount;

`ifndef SYNTHESIS
      // Check the captured relationship while occupied, including ready-low
      // holds and the pre-flush cycle. Payload is intentionally unreset.
      logic [6:0] stage2b_shift_controls_check;
      assign stage2b_shift_controls_check = riscv_pkg::projected_shift_controls(stage2b_op);
      always_ff @(posedge i_clk) begin
        if (i_rst_n && stage2b_valid) begin
          p_issue2_shift_amount_matches_payload :
          assert (
              stage2b_shift_amount == (stage2b_shift_controls_check[0] ?
              stage2b_imm[5:0] : stage2b_src2_value[5:0]));
        end
      end
`endif

      assign stage2b_head_query_match = stage2b_valid && (stage2b_rob_tag == i_head_query_tag);

      // No sideband is_sc mirror: SC issues via MEM_RS, never a DUAL_ISSUE
      // (INT) reservation station.

`ifndef SYNTHESIS
`ifndef FORMAL
      // Port-1 discipline: never a branch-class entry, never port 0's entry.
      always_ff @(posedge i_clk) begin
        if (i_rst_n && issue_fire_2) begin
          assert (rs_valid[issue_idx_2] && entry_ready[issue_idx_2])
          else $error("issue2 fired a non-ready entry");
          assert (!rs_is_branch_class[issue_idx_2])
          else $error("issue2 fired a branch-class entry");
          assert (!(issue_fire && (issue_idx == issue_idx_2)))
          else $error("both issue ports fired the same entry");
        end
      end
`endif
`endif
    end else begin : gen_no_issue2
      assign issue_idx_2 = '0;
      assign issue_sel_2 = '0;
      assign any_ready_2 = 1'b0;
      assign issue_fire_2 = 1'b0;
      assign stage2b_valid = 1'b0;
      assign stage2b_head_query_match = 1'b0;
      assign o_issue_2 = '0;
      assign o_issue_writes_cdb_hint_2 = 1'b0;
      assign o_issue_shift_amount_2 = '0;
      logic unused_fu_ready_2;
      assign unused_fu_ready_2 = i_fu_ready_2;
    end
  endgenerate

  // --- Status outputs ---
  assign o_full = dispatch_full_q;
  assign o_full_for_2 = dispatch_full_for_2_q;
  assign o_empty = empty;
  assign o_count = count;

  // ===========================================================================
  // Sequential Logic
  // ===========================================================================

  // Save allocation targets for next-cycle done repair. Flush discards the
  // targets because it also prevents dispatch from setting rs_valid.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all || i_flush_en) begin
      repair_slot1_target_q <= '0;
      repair_slot2_target_q <= '0;
    end else begin
      repair_slot1_target_q <= (ALLOC_INDEXED_REPAIR && dispatch_fire) ? index_to_onehot(
          free_idx
      ) : '0;
      repair_slot2_target_q <= (ALLOC_INDEXED_REPAIR && dispatch_fire_2) ? index_to_onehot(
          alloc_idx_2
      ) : '0;
    end
  end

  // Clear validity with the direct issue masks. A nonfiring port clears
  // nothing; each mask must match its selected entry.
  logic [DEPTH-1:0] issue1_clear_mask;
  assign issue1_clear_mask = {DEPTH{issue_fire}} & primary_issue_onehot[DEPTH-1:0];
  logic [DEPTH-1:0] issue2_clear_mask;
  assign issue2_clear_mask = {DEPTH{issue_fire_2}} & issue_sel_2;

`ifdef RS_ISSUE_CLEAR_LOCAL_PROOF
  logic [DEPTH-1:0] f_issue2_clear_mask;
  always_comb begin
    f_issue2_clear_mask = '0;
    if (issue_fire_2) f_issue2_clear_mask[issue_idx_2] = 1'b1;
    assert (issue2_clear_mask == f_issue2_clear_mask);
  end
`endif

`ifdef RS_DIVIDE_GATE_LOCAL_PROOF
  // Model a divider that becomes busy after a nonflushed divide issue and
  // finishes on an arbitrary later cycle. Payload and other inputs are free.
  // stage2_is_divide represents the opcode decode; its consistency is checked
  // separately. A staged divide must imply an idle divider until it issues.
  initial assume (!i_rst_n);
  logic f_gate_past_valid = 1'b0;
  (* anyseq *)logic f_divider_finish;
  logic f_divider_busy;
  always @(posedge i_clk) begin
    f_gate_past_valid <= 1'b1;
    if (f_gate_past_valid) assume (i_rst_n);
    if (!i_rst_n) f_divider_busy <= 1'b0;
    else if (o_issue.valid && stage2_is_divide && !stage2_should_flush) f_divider_busy <= 1'b1;
    else if (f_divider_finish) f_divider_busy <= 1'b0;
  end
  always_comb begin
    assume (i_divider_busy == f_divider_busy);
    if (i_rst_n) begin
      assert (!(stage2_valid && stage2_is_divide && f_divider_busy));
      assert (!(o_issue.valid && stage2_is_divide && i_divider_busy));
    end
  end
  always @(posedge i_clk) begin
    // A multiply issues while a divide waits behind the busy divider.
    if (i_rst_n)
      cover (i_divider_busy && |(rs_valid & rs_is_divide) && o_issue.valid && !stage2_is_divide);
  end
`endif

  // --- Control signals (with reset) ---
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      rs_valid      <= '0;
      rs_src1_ready <= '0;
      rs_src2_ready <= '0;
      if (HAS_SRC3) rs_src3_ready_q <= '0;
      rs_use_imm            <= '0;
      rs_writes_cdb_hint    <= '0;
      src1_cdb_pend         <= '0;
      src2_cdb_pend         <= '0;
      src3_cdb_pend         <= '0;
      count                 <= '0;
      dispatch_full_q       <= 1'b0;
      dispatch_full_for_2_q <= 1'b0;
    end else begin
      count <= count_next;
      if (DISPATCH_STATUS_RESERVE == 0) begin
        dispatch_full_q       <= dispatch_full_next;
        dispatch_full_for_2_q <= dispatch_full_for_2_next;
      end else begin
        dispatch_full_q       <= count >= CountWidth'(DispatchFullThreshold);
        dispatch_full_for_2_q <= count >= CountWidth'(DispatchFullFor2Threshold);
      end

      // Flush logic (highest priority for rs_valid)
      if (i_flush_all) begin
        rs_valid <= '0;
      end else if (i_flush_en) begin
        // Partial flush: invalidate entries younger than flush_tag. When the
        // flush tag has already retired (head == flush_tag + 1, commit-time
        // recovery) this compare clears nothing, so the wrapper sends that
        // case as i_flush_all (its speculative_flush_all).
        for (int i = 0; i < DEPTH; i++) begin
          if (rs_valid[i] && should_flush_entry(rs_rob_tag[i], i_flush_tag, i_rob_head_tag)) begin
            rs_valid[i] <= 1'b0;
          end
        end
      end else begin
        // Both issue clears commute; later allocation writes take priority.
        if (CAPTURE_PRIMARY_EFFECTIVE_OPERANDS) begin
          rs_valid <= rs_valid & ~issue2_clear_mask & ~issue1_clear_mask;
        end else begin
          rs_valid <= rs_valid & ~issue2_clear_mask;
          if (issue_fire) rs_valid[issue_idx] <= 1'b0;
        end

        if (dispatch_fire) begin
          rs_valid[free_idx] <= 1'b1;
          if (TRACK_INT_WRITEBACK_HINT)
            rs_writes_cdb_hint[free_idx] <= int_rs_writes_cdb(dispatch_op);

          // Capture dispatch readiness, including repair bypass when enabled.
          // Indexed repair and deferred CDB matches set ready one cycle later.
          rs_src1_ready[free_idx] <= dispatch_src1_ready || dispatch_src1_repair_match;
          rs_src2_ready[free_idx] <= dispatch_src2_ready || dispatch_src2_repair_match;
          if (HAS_SRC3) begin
            rs_src3_ready_q[free_idx] <= dispatch_src3_ready || dispatch_src3_repair_match;
          end
          rs_use_imm[free_idx] <= dispatch_use_imm;
          rs_shift_uses_imm[free_idx] <= dispatch_shift_controls[0];
          rs_shift_imm[free_idx] <= dispatch_imm[5:0];
          // Write pending flags on every dispatch, including zero when unmatched,
          // so reallocation cannot inherit a stale delivery.
          src1_cdb_pend[free_idx] <= dispatch_src1_cdb_defer;
          src1_cdb_pend_lane[free_idx] <= dispatch_src1_cdb_defer_lane;
          src2_cdb_pend[free_idx] <= dispatch_src2_cdb_defer;
          src2_cdb_pend_lane[free_idx] <= dispatch_src2_cdb_defer_lane;
          if (HAS_SRC3) begin
            src3_cdb_pend[free_idx] <= dispatch_src3_cdb_defer;
            src3_cdb_pend_lane[free_idx] <= dispatch_src3_cdb_defer_lane;
          end
        end

        // Slot 2 writes a distinct entry, so the allocation writes cannot collide.
        if (dispatch_fire_2) begin
          rs_valid[alloc_idx_2] <= 1'b1;
          if (TRACK_INT_WRITEBACK_HINT)
            rs_writes_cdb_hint[alloc_idx_2] <= int_rs_writes_cdb(dispatch_op_2);

          rs_src1_ready[alloc_idx_2] <= dispatch_src1_ready_2 || dispatch_src1_repair_match_2;
          rs_src2_ready[alloc_idx_2] <= dispatch_src2_ready_2 || dispatch_src2_repair_match_2;
          if (HAS_SRC3) begin
            rs_src3_ready_q[alloc_idx_2] <= dispatch_src3_ready_2 || dispatch_src3_repair_match_2;
          end
          rs_use_imm[alloc_idx_2] <= dispatch_use_imm_2;
          rs_shift_uses_imm[alloc_idx_2] <= dispatch_shift_controls_2[0];
          rs_shift_imm[alloc_idx_2] <= dispatch_imm_2[5:0];
          src1_cdb_pend[alloc_idx_2] <= dispatch_src1_cdb_defer_2;
          src1_cdb_pend_lane[alloc_idx_2] <= dispatch_src1_cdb_defer_lane_2;
          src2_cdb_pend[alloc_idx_2] <= dispatch_src2_cdb_defer_2;
          src2_cdb_pend_lane[alloc_idx_2] <= dispatch_src2_cdb_defer_lane_2;
          if (HAS_SRC3) begin
            src3_cdb_pend[alloc_idx_2] <= dispatch_src3_cdb_defer_2;
            src3_cdb_pend_lane[alloc_idx_2] <= dispatch_src3_cdb_defer_lane_2;
          end
        end
      end

      // CDB and repair wakeup: ready bits.
      if (i_cdb.valid || i_cdb_2.valid || i_repair_valid_1 || i_repair_valid_2 ||
        i_repair_valid_3 || i_repair_valid_4 || i_repair_valid_5 || i_repair_valid_6) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (rs_valid[i]) begin
            if (!rs_src1_ready[i] &&
                ((i_cdb.valid && rs_src1_tag[i] == i_cdb.tag) ||
                 (i_cdb_2.valid && rs_src1_tag[i] == i_cdb_2.tag) ||
                 indexed_src1_repair[i] ||
                 done_repair_match(
                    rs_src1_tag[i]
                ))) begin
              rs_src1_ready[i] <= 1'b1;
            end
            if (!rs_src2_ready[i] &&
                ((i_cdb.valid && rs_src2_tag[i] == i_cdb.tag) ||
                 (i_cdb_2.valid && rs_src2_tag[i] == i_cdb_2.tag) ||
                 indexed_src2_repair[i] ||
                 done_repair_match(
                    rs_src2_tag[i]
                ))) begin
              rs_src2_ready[i] <= 1'b1;
            end
            if (HAS_SRC3 && !rs_src3_ready[i] &&
                ((i_cdb.valid && rs_src3_tag[i] == i_cdb.tag) ||
                 (i_cdb_2.valid && rs_src3_tag[i] == i_cdb_2.tag) ||
                 indexed_src3_repair[i] ||
                 done_repair_match(
                    rs_src3_tag[i]
                ))) begin
              rs_src3_ready_q[i] <= 1'b1;
            end
          end
        end
      end

      // Set ready and clear pending one cycle after a dispatch CDB match.
      // Flush can make these writes unobservable by clearing rs_valid on the
      // same edge. The newly allocated entry is still resident before this
      // edge, so delivery cannot collide with allocation into a free entry.
      for (int i = 0; i < DEPTH; i++) begin
        if (src1_cdb_pend[i]) begin
          rs_src1_ready[i] <= 1'b1;
          src1_cdb_pend[i] <= 1'b0;
        end
        if (src2_cdb_pend[i]) begin
          rs_src2_ready[i] <= 1'b1;
          src2_cdb_pend[i] <= 1'b0;
        end
        if (HAS_SRC3 && src3_cdb_pend[i]) begin
          rs_src3_ready_q[i] <= 1'b1;
          src3_cdb_pend[i]   <= 1'b0;
        end
      end

    end
  end

  // Resolve write priority per source before the wide mux. Deferred CDB
  // delivery and ordinary repair share each slot's data bus.
  function automatic logic [5:0] indexed_write_select(
      input logic dispatch1, input logic dispatch2, input logic resident, input logic ready,
      input logic live0, input logic live1, input logic target1, input logic target2,
      input logic repair1, input logic repair2, input logic pending);
    logic take_c0, take_c1, take_r1, take_r2, any_resident;
    begin
      take_c0 = resident && !ready && live0;
      take_c1 = resident && !ready && !live0 && live1;
      take_r1 = resident && !ready && !live0 && !live1 && target1 && repair1;
      take_r2 = resident && !ready && !live0 && !live1 &&
          !(target1 && repair1) && target2 && repair2;
      any_resident = take_c0 || take_c1 || take_r1 || take_r2;
      indexed_write_select[0] = !pending && !any_resident && !dispatch2 && dispatch1;
      indexed_write_select[1] = !pending && !any_resident && dispatch2;
      indexed_write_select[2] = !pending && take_c0;
      indexed_write_select[3] = !pending && take_c1;
      indexed_write_select[4] = (pending && target1) || (!pending && take_r1);
      indexed_write_select[5] = (pending && !target1) || (!pending && take_r2);
    end
  endfunction

  function automatic logic [FLEN-1:0] indexed_write_value(
      input logic [5:0] select, input logic [FLEN-1:0] dispatch1, input logic [FLEN-1:0] dispatch2,
      input logic [FLEN-1:0] live0, input logic [FLEN-1:0] live1, input logic [FLEN-1:0] delivery1,
      input logic [FLEN-1:0] delivery2);
    indexed_write_value =
        ({FLEN{select[0]}} & dispatch1) | ({FLEN{select[1]}} & dispatch2) |
        ({FLEN{select[2]}} & live0) | ({FLEN{select[3]}} & live1) |
        ({FLEN{select[4]}} & delivery1) | ({FLEN{select[5]}} & delivery2);
  endfunction

  localparam int unsigned EntryIndexWidth = $clog2(DEPTH);
  logic [DEPTH-1:0] indexed_dispatch1_write, indexed_dispatch2_write;
  (* keep = "true" *) logic [5:0] indexed_src1_write_sel[DEPTH];
  logic [FLEN-1:0] indexed_src1_write_data[DEPTH];
  (* keep = "true" *) logic [5:0] indexed_src2_write_sel[DEPTH];
  logic [FLEN-1:0] indexed_src2_write_data[DEPTH];
  (* keep = "true" *) logic [5:0] indexed_src3_write_sel[DEPTH];
  logic [FLEN-1:0] indexed_src3_write_data[DEPTH];
  for (genvar entry = 0; entry < DEPTH; entry++) begin : gen_indexed_value_write
    if (ALLOC_INDEXED_REPAIR) begin : gen_enabled
      assign indexed_dispatch1_write[entry] = BROADCAST_FREE_SOURCE_VALUES ?
        (!rs_valid[entry] && !alloc_sel_2[entry]) :
        (data_write_1_en && free_idx == EntryIndexWidth'(entry));
      assign indexed_dispatch2_write[entry] = BROADCAST_FREE_SOURCE_VALUES ?
        (!rs_valid[entry] && alloc_sel_2[entry]) :
        (data_write_2_en && alloc_idx_2 == EntryIndexWidth'(entry));
      assign indexed_src1_write_sel[entry] = indexed_write_select(
          indexed_dispatch1_write[entry],
          indexed_dispatch2_write[entry],
          rs_valid[entry],
          rs_src1_ready[entry],
          i_cdb.valid && rs_src1_tag[entry] == i_cdb.tag,
          i_cdb_2.valid && rs_src1_tag[entry] == i_cdb_2.tag,
          repair_slot1_target_q[entry],
          repair_slot2_target_q[entry],
          i_repair_valid_1,
          i_repair_valid_4,
          src1_cdb_pend[entry]
      );
      assign indexed_src1_write_data[entry] = indexed_write_value(
          indexed_src1_write_sel[entry],
          dispatch_src1_stored_value,
          dispatch_src1_stored_value_2,
          i_cdb.value,
          i_cdb_2.value,
          indexed_delivery_1,
          indexed_delivery_4
      );
      assign indexed_src2_write_sel[entry] = indexed_write_select(
          indexed_dispatch1_write[entry],
          indexed_dispatch2_write[entry],
          rs_valid[entry],
          rs_src2_ready[entry],
          i_cdb.valid && rs_src2_tag[entry] == i_cdb.tag,
          i_cdb_2.valid && rs_src2_tag[entry] == i_cdb_2.tag,
          repair_slot1_target_q[entry],
          repair_slot2_target_q[entry],
          i_repair_valid_2,
          i_repair_valid_5,
          src2_cdb_pend[entry]
      );
      assign indexed_src2_write_data[entry] = indexed_write_value(
          indexed_src2_write_sel[entry],
          dispatch_src2_stored_value,
          dispatch_src2_stored_value_2,
          i_cdb.value,
          i_cdb_2.value,
          indexed_delivery_2,
          indexed_delivery_5
      );
      if (HAS_SRC3) begin : gen_src3
        assign indexed_src3_write_sel[entry] = indexed_write_select(
            indexed_dispatch1_write[entry],
            indexed_dispatch2_write[entry],
            rs_valid[entry],
            rs_src3_ready[entry],
            i_cdb.valid && rs_src3_tag[entry] == i_cdb.tag,
            i_cdb_2.valid && rs_src3_tag[entry] == i_cdb_2.tag,
            repair_slot1_target_q[entry],
            repair_slot2_target_q[entry],
            i_repair_valid_3,
            i_repair_valid_6,
            src3_cdb_pend[entry]
        );
        assign indexed_src3_write_data[entry] = indexed_write_value(
            indexed_src3_write_sel[entry],
            dispatch_src3_stored_value,
            dispatch_src3_stored_value_2,
            i_cdb.value,
            i_cdb_2.value,
            indexed_delivery_3,
            indexed_delivery_6
        );
      end else begin : gen_no_src3
        assign indexed_src3_write_sel[entry]  = '0;
        assign indexed_src3_write_data[entry] = '0;
      end
    end else begin : gen_disabled
      assign indexed_dispatch1_write[entry] = 1'b0;
      assign indexed_dispatch2_write[entry] = 1'b0;
      assign indexed_src1_write_sel[entry]  = '0;
      assign indexed_src1_write_data[entry] = '0;
      assign indexed_src2_write_sel[entry]  = '0;
      assign indexed_src2_write_data[entry] = '0;
      assign indexed_src3_write_sel[entry]  = '0;
      assign indexed_src3_write_data[entry] = '0;
    end
  end

  // --- Data signals (no reset) ---
  always_ff @(posedge i_clk) begin
    // Speculative issue-tag writes complement tags for slots not targeting
    // this RS, preventing merging with the normal bank. Committed writes
    // always use normal tags. Slot 2 wins when it shares free_idx with a
    // speculative slot-1 write.
    if (ISSUE_CDB_TAG_SHADOW) begin
      if (data_write_1_en) begin
        rs_src1_issue_tag[free_idx] <= i_intent_1 ? dispatch_src1_tag : ~dispatch_src1_tag;
        rs_src2_issue_tag[free_idx] <= i_intent_1 ? dispatch_src2_tag : ~dispatch_src2_tag;
      end
      if (data_write_2_en) begin
        rs_src1_issue_tag[alloc_idx_2] <=
            dispatch_valid_2 ? dispatch_src1_tag_2 : ~dispatch_src1_tag_2;
        rs_src2_issue_tag[alloc_idx_2] <=
            dispatch_valid_2 ? dispatch_src2_tag_2 : ~dispatch_src2_tag_2;
      end
    end

    // Generic and indexed modes apply the same source writes. In broadcast
    // mode, free entries get slot 1's values except at the slot-2 target.
    // Only allocated entries become valid; other prefills remain unobservable.
    // alloc_sel_2 must equal data_write_2_en && alloc_idx_2 == i for every
    // free entry. Use its direct mask for timing.
    if (BROADCAST_FREE_SOURCE_VALUES && !ALLOC_INDEXED_REPAIR) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (!rs_valid[i]) begin
          if (alloc_sel_2[i]) begin
            rs_src1_value[i] <= dispatch_src1_stored_value_2;
            rs_src2_value[i] <= dispatch_src2_stored_value_2;
            if (HAS_SRC3) rs_src3_value[i] <= dispatch_src3_stored_value_2;
          end else begin
            rs_src1_value[i] <= dispatch_src1_stored_value;
            rs_src2_value[i] <= dispatch_src2_stored_value;
            if (HAS_SRC3) rs_src3_value[i] <= dispatch_src3_stored_value;
          end
        end
      end
    end

    if (data_write_1_en) begin
      rs_rob_tag[free_idx] <= dispatch_rob_tag;
      rs_is_branch_class[free_idx] <= dispatch_is_branch_class;
      rs_is_divide[free_idx] <= dispatch_is_divide;

      rs_src1_tag[free_idx] <= dispatch_src1_tag;
      if (!BROADCAST_FREE_SOURCE_VALUES && !ALLOC_INDEXED_REPAIR)
        rs_src1_value[free_idx] <= dispatch_src1_stored_value;

      rs_src2_tag[free_idx] <= dispatch_src2_tag;
      if (!BROADCAST_FREE_SOURCE_VALUES && !ALLOC_INDEXED_REPAIR)
        rs_src2_value[free_idx] <= dispatch_src2_stored_value;

      // Source 3 (FMA only)
      if (HAS_SRC3) begin
        rs_src3_tag[free_idx] <= dispatch_src3_tag;
        if (!BROADCAST_FREE_SOURCE_VALUES && !ALLOC_INDEXED_REPAIR)
          rs_src3_value[free_idx] <= dispatch_src3_stored_value;
      end
    end

    // Dispatch resolves intra-bundle RAW dependencies before either slot
    // reaches the station.
    if (data_write_2_en) begin
      rs_rob_tag[alloc_idx_2] <= dispatch_rob_tag_2;
      rs_is_branch_class[alloc_idx_2] <= dispatch_is_branch_class_2;
      rs_is_divide[alloc_idx_2] <= dispatch_is_divide_2;

      rs_src1_tag[alloc_idx_2] <= dispatch_src1_tag_2;
      if (!BROADCAST_FREE_SOURCE_VALUES && !ALLOC_INDEXED_REPAIR)
        rs_src1_value[alloc_idx_2] <= dispatch_src1_stored_value_2;

      rs_src2_tag[alloc_idx_2] <= dispatch_src2_tag_2;
      if (!BROADCAST_FREE_SOURCE_VALUES && !ALLOC_INDEXED_REPAIR)
        rs_src2_value[alloc_idx_2] <= dispatch_src2_stored_value_2;

      if (HAS_SRC3) begin
        rs_src3_tag[alloc_idx_2] <= dispatch_src3_tag_2;
        if (!BROADCAST_FREE_SOURCE_VALUES && !ALLOC_INDEXED_REPAIR)
          rs_src3_value[alloc_idx_2] <= dispatch_src3_stored_value_2;
      end
    end

    // CDB and repair wakeup: source values.
    if (!ALLOC_INDEXED_REPAIR && (i_cdb.valid || i_cdb_2.valid ||
        i_repair_valid_1 || i_repair_valid_2 || i_repair_valid_3 ||
        i_repair_valid_4 || i_repair_valid_5 || i_repair_valid_6)) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (rs_valid[i]) begin
          if (!rs_src1_ready[i] && i_cdb.valid && rs_src1_tag[i] == i_cdb.tag) begin
            rs_src1_value[i] <= i_cdb.value;
          end else if (!rs_src1_ready[i] && i_cdb_2.valid && rs_src1_tag[i] == i_cdb_2.tag) begin
            rs_src1_value[i] <= i_cdb_2.value;
          end else if (!rs_src1_ready[i] && done_repair_match(rs_src1_tag[i])) begin
            rs_src1_value[i] <= done_repair_value(rs_src1_tag[i]);
          end

          if (!rs_src2_ready[i] && i_cdb.valid && rs_src2_tag[i] == i_cdb.tag) begin
            rs_src2_value[i] <= i_cdb.value;
          end else if (!rs_src2_ready[i] && i_cdb_2.valid && rs_src2_tag[i] == i_cdb_2.tag) begin
            rs_src2_value[i] <= i_cdb_2.value;
          end else if (!rs_src2_ready[i] && done_repair_match(rs_src2_tag[i])) begin
            rs_src2_value[i] <= done_repair_value(rs_src2_tag[i]);
          end

          if (HAS_SRC3 && !rs_src3_ready[i] && i_cdb.valid && rs_src3_tag[i] == i_cdb.tag) begin
            rs_src3_value[i] <= i_cdb.value;
          end else if (HAS_SRC3 && !rs_src3_ready[i] && i_cdb_2.valid &&
                       rs_src3_tag[i] == i_cdb_2.tag) begin
            rs_src3_value[i] <= i_cdb_2.value;
          end else if (HAS_SRC3 && !rs_src3_ready[i] && done_repair_match(rs_src3_tag[i])) begin
            rs_src3_value[i] <= done_repair_value(rs_src3_tag[i]);
          end
        end
      end
    end

    // Capture CDB lane values every cycle; pending flags qualify their use
    // for deferred delivery.
    cdb0_value_q <= i_cdb.value;
    cdb1_value_q <= i_cdb_2.value;

    // Indexed stations use the shared selects; generic stations apply
    // deferred delivery last.
    for (int i = 0; i < DEPTH; i++) begin
      if (ALLOC_INDEXED_REPAIR) begin
        if (|indexed_src1_write_sel[i]) rs_src1_value[i] <= indexed_src1_write_data[i];
        if (|indexed_src2_write_sel[i]) rs_src2_value[i] <= indexed_src2_write_data[i];
        if (HAS_SRC3 && (|indexed_src3_write_sel[i]))
          rs_src3_value[i] <= indexed_src3_write_data[i];
      end else begin
        if (src1_cdb_pend[i])
          rs_src1_value[i] <= src1_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q;
        if (src2_cdb_pend[i])
          rs_src2_value[i] <= src2_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q;
        if (HAS_SRC3 && src3_cdb_pend[i])
          rs_src3_value[i] <= src3_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q;
      end
    end
  end

  // ===========================================================================
  // Stage 2 Pipeline Register: Sequential Logic
  // ===========================================================================
  // Captures the issued instruction's data on issue_fire and holds it until
  // consumed by the downstream FU (stage2_accept) or flushed.

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      stage2_valid <= 1'b0;
    end else if (stage2_should_flush) begin
      // Flush squash: clear stage2. No refill is possible here because
      // issue_fire is suppressed during flush (!i_flush_all && !i_flush_en).
      stage2_valid <= 1'b0;
    end else if (issue_fire) begin
      // Load on empty fill or simultaneous acceptance and refill.
      stage2_valid <= 1'b1;
      stage2_rob_tag <= primary_issue_tag;
      stage2_op <= riscv_pkg::instr_op_e'(pl_op_bits);
      stage2_is_divide <= primary_issue_divide;
      if (CAPTURE_PRIMARY_EFFECTIVE_OPERANDS) begin
        // Capture the final operands from resident, repair or CDB values.
        // Issue-only inputs supply valid and tag; full CDB packets supply data.
        stage2_src1_value <= (issue_src1_resident &
            {FLEN{!issue_src1_bypass && !issue_src1_bypass_l1}}) |
            (i_cdb.value & {FLEN{issue_src1_bypass}}) |
            (i_cdb_2.value & {FLEN{issue_src1_bypass_l1}});
        stage2_src2_value <= (issue_src2_resident &
            {FLEN{!issue_src2_bypass && !issue_src2_bypass_l1}}) |
            (i_cdb.value & {FLEN{issue_src2_bypass}}) |
            (i_cdb_2.value & {FLEN{issue_src2_bypass_l1}});
      end else begin
        // Store resident or repair data and bypass masks. The output mux uses
        // the captured CDB lane value for bypassed sources.
        stage2_src1_value <= (src1_repair_sel[issue_idx] != 3'd0) ? repair_value_for_sel(
            src1_repair_sel[issue_idx]
        ) : rs_src1_value[issue_idx];
        stage2_src2_value <= (src2_repair_sel[issue_idx] != 3'd0) ? repair_value_for_sel(
            src2_repair_sel[issue_idx]
        ) : rs_src2_value[issue_idx];
        stage2_src1_bypass_mask <= {FLEN{src1_cdb_bypass[issue_idx]}};
        stage2_src2_bypass_mask <= {FLEN{src2_cdb_bypass[issue_idx]}};
        stage2_src1_bypass_mask_l1 <= {FLEN{src1_cdb_bypass_l1[issue_idx]}};
        stage2_src2_bypass_mask_l1 <= {FLEN{src2_cdb_bypass_l1[issue_idx]}};
      end
      if (HAS_SRC3) begin
        stage2_src3_value <= (src3_repair_sel[issue_idx] != 3'd0) ? repair_value_for_sel(
            src3_repair_sel[issue_idx]
        ) : rs_src3_value[issue_idx];
        stage2_src3_bypass_mask <= {FLEN{src3_cdb_bypass[issue_idx]}};
        stage2_src3_bypass_mask_l1 <= {FLEN{src3_cdb_bypass_l1[issue_idx]}};
      end
      stage2_cdb_value <= i_cdb.value;
      stage2_cdb_value_l1 <= i_cdb_2.value;
      stage2_imm <= pl_imm;
      stage2_jalr_imm <= pl_jalr_imm;
      stage2_use_imm <= primary_issue_use_imm;
      stage2_writes_cdb_hint <= TRACK_INT_WRITEBACK_HINT ? primary_issue_hint : 1'b0;
      stage2_rm <= pl_rm;
      stage2_predicted_taken <= pl_predicted_taken;
      stage2_predicted_target_ok <= pl_predicted_target_ok;
      stage2_is_compressed <= pl_is_compressed;
      stage2_is_fp_mem <= pl_is_fp_mem;
      stage2_mem_needs_lq <= pl_mem_needs_lq;
      stage2_mem_needs_sq <= pl_mem_needs_sq;
      stage2_mem_size <= riscv_pkg::mem_size_e'(pl_mem_size_bits);
      stage2_mem_signed <= pl_mem_signed;
      stage2_csr_addr <= pl_csr_addr;
      stage2_csr_imm <= pl_csr_imm;
      stage2_has_checkpoint <= pl_has_checkpoint;
      stage2_checkpoint_id <= pl_checkpoint_id;
      stage2_is_call <= pl_is_call;
      stage2_is_return <= pl_is_return;
      stage2_is_branch_class <= pl_is_branch_class;
      stage2_is_jal <= pl_is_jal;
      stage2_is_jalr <= pl_is_jalr;
      stage2_branch_op <= riscv_pkg::branch_taken_op_e'(pl_branch_op_bits);
    end else if (stage2_accept) begin
      // Consumed by FU with no new entry ready: go empty.
      stage2_valid <= 1'b0;
    end
    // else: stage2_valid && !stage2_accept && !stage2_should_flush. Hold (blocked).
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  generate
    if (CAPTURE_PRIMARY_EFFECTIVE_OPERANDS) begin : gen_primary_operand_capture_oracle
      always_ff @(posedge i_clk) begin
        if (!i_rst_n) begin
          primary_operand_oracle_valid_q <= 1'b0;
        end else begin
          assert (primary_operand_oracle_valid_q == stage2_valid)
          else $error("RS: primary operand oracle valid diverged from stage2");
          if (stage2_valid) begin
            assert (stage2_src1_value == primary_src1_value_oracle_q)
            else $error("RS: primary src1 effective capture differs from the reference");
            assert (stage2_src2_value == primary_src2_value_oracle_q)
            else $error("RS: primary src2 effective capture differs from the reference");
          end

          if (stage2_should_flush) begin
            primary_operand_oracle_valid_q <= 1'b0;
          end else if (issue_fire) begin
            primary_operand_oracle_valid_q <= 1'b1;
            primary_src1_value_oracle_q <=
                (((src1_repair_sel[issue_idx] != 3'd0) ? repair_value_for_sel(
                src1_repair_sel[issue_idx]
            ) : rs_src1_value[issue_idx]) &
                {FLEN{!src1_cdb_bypass[issue_idx] && !src1_cdb_bypass_l1[issue_idx]}}) |
                (i_cdb.value & {FLEN{src1_cdb_bypass[issue_idx]}}) |
                (i_cdb_2.value & {FLEN{src1_cdb_bypass_l1[issue_idx]}});
            primary_src2_value_oracle_q <=
                (((src2_repair_sel[issue_idx] != 3'd0) ? repair_value_for_sel(
                src2_repair_sel[issue_idx]
            ) : rs_src2_value[issue_idx]) &
                {FLEN{!src2_cdb_bypass[issue_idx] && !src2_cdb_bypass_l1[issue_idx]}}) |
                (i_cdb.value & {FLEN{src2_cdb_bypass[issue_idx]}}) |
                (i_cdb_2.value & {FLEN{src2_cdb_bypass_l1[issue_idx]}});
          end else if (stage2_accept) begin
            primary_operand_oracle_valid_q <= 1'b0;
          end
        end
      end
    end
  endgenerate
`endif
`endif

  // No reset: this sideband is only observed when stage2_valid is set.
  always_ff @(posedge i_clk) begin
    if (issue_fire) begin
      stage2_is_sc <= (riscv_pkg::instr_op_e'(pl_op_bits) == riscv_pkg::SC_W) ||
          (riscv_pkg::instr_op_e'(pl_op_bits) == riscv_pkg::SC_D);
    end
  end


  // ===========================================================================
  // Simulation Assertions
  // ===========================================================================
`ifndef SYNTHESIS
`ifndef FORMAL
  initial begin
    if (ALLOC_INDEXED_REPAIR && (DISPATCH_REPAIR_BYPASS || ISSUE_REPAIR_BYPASS))
      $error("ALLOC_INDEXED_REPAIR requires both repair bypass parameters disabled");
    if (BROADCAST_FREE_SOURCE_VALUES && !SPECULATIVE_DATA_WRITES)
      $error("BROADCAST_FREE_SOURCE_VALUES requires SPECULATIVE_DATA_WRITES");
    if (CAPTURE_PRIMARY_EFFECTIVE_OPERANDS && HAS_SRC3)
      $error("CAPTURE_PRIMARY_EFFECTIVE_OPERANDS requires HAS_SRC3=0");
    if (DIVIDE_ISSUE_GATE && DUAL_ISSUE) $error("DIVIDE_ISSUE_GATE requires DUAL_ISSUE=0");
  end

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // Warn on refused dispatch requests.
      if (dispatch_valid && full && !i_flush_all && !i_flush_en)
        $warning("RS: dispatch attempted when full");

      if (dispatch_valid_2 && dispatch_fire && full_for_2 && !i_flush_all && !i_flush_en)
        $warning("RS: slot-2 dispatch attempted when full_for_2 (and slot-1 firing)");

      // Slot-1 and slot-2 must never target the same physical entry.
      if (dispatch_fire && dispatch_fire_2 && !i_flush_all && !i_flush_en &&
          (free_idx == alloc_idx_2))
        $error("RS: slot-1 and slot-2 alloc collide on entry %0d", free_idx);

      // The slot-2 value select must equal the binary allocation decode on
      // every free entry.
      if (!$isunknown({rs_valid, i_intent_1, data_write_2_en})) begin
        assert (alloc_sel_2 == (data_write_2_en ? (index_to_onehot(alloc_idx_2) & ~rs_valid) : '0))
        else $error("RS: alloc_sel_2 %b disagrees with alloc_idx_2 %0d", alloc_sel_2, alloc_idx_2);
      end

      // Loading stage2 requires a ready entry.
      if (issue_fire && !entry_ready[issue_idx])
        $error("RS: issue fired for non-ready entry %0d", issue_idx);

      // The divide gate reads stage2's divide bit in place of its opcode.
      if (DIVIDE_ISSUE_GATE && stage2_valid && (stage2_is_divide != rs_is_divide_op(stage2_op)))
        $error("RS: stage2 divide bit %0d disagrees with its opcode", stage2_is_divide);

      if (ALLOC_INDEXED_REPAIR) begin
        assert ($onehot0(repair_slot1_target_q))
        else $error("RS: slot-1 indexed-repair target is not one-hot");
        assert ($onehot0(repair_slot2_target_q))
        else $error("RS: slot-2 indexed-repair target is not one-hot");
        assert ((repair_slot1_target_q & repair_slot2_target_q) == '0)
        else $error("RS: indexed-repair dispatch targets overlap");

        for (int i = 0; i < DEPTH; i++) begin
          if ((repair_slot1_target_q[i] || repair_slot2_target_q[i]) && !rs_valid[i])
            $error("RS: indexed-repair target %0d is not resident", i);

          // The wrapper response channels must remain aligned with the
          // dispatch packet whose local allocation token was captured.
          if (repair_slot1_target_q[i] && i_repair_valid_1)
            assert (rs_src1_tag[i] == i_repair_tag_1)
            else $error("RS: slot-1 src1 repair tag misaligned");
          if (repair_slot1_target_q[i] && i_repair_valid_2)
            assert (rs_src2_tag[i] == i_repair_tag_2)
            else $error("RS: slot-1 src2 repair tag misaligned");
          if (HAS_SRC3 && repair_slot1_target_q[i] && i_repair_valid_3)
            assert (rs_src3_tag[i] == i_repair_tag_3)
            else $error("RS: slot-1 src3 repair tag misaligned");
          if (repair_slot2_target_q[i] && i_repair_valid_4)
            assert (rs_src1_tag[i] == i_repair_tag_4)
            else $error("RS: slot-2 src1 repair tag misaligned");
          if (repair_slot2_target_q[i] && i_repair_valid_5)
            assert (rs_src2_tag[i] == i_repair_tag_5)
            else $error("RS: slot-2 src2 repair tag misaligned");
          if (HAS_SRC3 && repair_slot2_target_q[i] && i_repair_valid_6)
            assert (rs_src3_tag[i] == i_repair_tag_6)
            else $error("RS: slot-2 src3 repair tag misaligned");
        end
      end

      if (ISSUE_CDB_TAG_SHADOW) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (rs_valid[i]) begin
            assert (rs_src1_issue_tag[i] == rs_src1_tag[i])
            else $error("RS: valid entry %0d src1 issue-tag shadow mismatch", i);
            assert (rs_src2_issue_tag[i] == rs_src2_tag[i])
            else $error("RS: valid entry %0d src2 issue-tag shadow mismatch", i);
          end
        end
      end

      // A pending flag lasts one cycle on a resident, unready source. Any
      // simultaneous repair for that source must equal the saved CDB value.
      for (int i = 0; i < DEPTH; i++) begin
        if (src1_cdb_pend[i]) begin
          assert (rs_valid[i])
          else $error("RS: entry %0d src1 pend on an invalid entry", i);
          assert (!rs_src1_ready[i])
          else $error("RS: entry %0d src1 pend with ready already set", i);
          if (done_repair_match(rs_src1_tag[i]))
            assert (done_repair_value(
                rs_src1_tag[i]
            ) == (src1_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q))
            else $error("RS: entry %0d src1 deferred/CAM-repair value mismatch", i);
          if (ALLOC_INDEXED_REPAIR && repair_slot1_target_q[i] && i_repair_valid_1)
            assert (i_repair_value_1 == (src1_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q))
            else $error("RS: entry %0d src1 deferred/indexed-repair value mismatch", i);
          if (ALLOC_INDEXED_REPAIR && repair_slot2_target_q[i] && i_repair_valid_4)
            assert (i_repair_value_4 == (src1_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q))
            else $error("RS: entry %0d src1 deferred/indexed-repair value mismatch", i);
        end
        if (src2_cdb_pend[i]) begin
          assert (rs_valid[i])
          else $error("RS: entry %0d src2 pend on an invalid entry", i);
          assert (!rs_src2_ready[i])
          else $error("RS: entry %0d src2 pend with ready already set", i);
          if (done_repair_match(rs_src2_tag[i]))
            assert (done_repair_value(
                rs_src2_tag[i]
            ) == (src2_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q))
            else $error("RS: entry %0d src2 deferred/CAM-repair value mismatch", i);
          if (ALLOC_INDEXED_REPAIR && repair_slot1_target_q[i] && i_repair_valid_2)
            assert (i_repair_value_2 == (src2_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q))
            else $error("RS: entry %0d src2 deferred/indexed-repair value mismatch", i);
          if (ALLOC_INDEXED_REPAIR && repair_slot2_target_q[i] && i_repair_valid_5)
            assert (i_repair_value_5 == (src2_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q))
            else $error("RS: entry %0d src2 deferred/indexed-repair value mismatch", i);
        end
        if (HAS_SRC3 && src3_cdb_pend[i]) begin
          assert (rs_valid[i])
          else $error("RS: entry %0d src3 pend on an invalid entry", i);
          assert (!rs_src3_ready[i])
          else $error("RS: entry %0d src3 pend with ready already set", i);
          if (done_repair_match(rs_src3_tag[i]))
            assert (done_repair_value(
                rs_src3_tag[i]
            ) == (src3_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q))
            else $error("RS: entry %0d src3 deferred/CAM-repair value mismatch", i);
          if (ALLOC_INDEXED_REPAIR && repair_slot1_target_q[i] && i_repair_valid_3)
            assert (i_repair_value_3 == (src3_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q))
            else $error("RS: entry %0d src3 deferred/indexed-repair value mismatch", i);
          if (ALLOC_INDEXED_REPAIR && repair_slot2_target_q[i] && i_repair_valid_6)
            assert (i_repair_value_6 == (src3_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q))
            else $error("RS: entry %0d src3 deferred/indexed-repair value mismatch", i);
        end
      end

    end
  end
`endif
`endif

  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL
`ifndef RS_PRETAG_LOCAL_PROOF

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // Force reset to deassert after initial cycle
  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // -------------------------------------------------------------------------
  // Assumptions
  // -------------------------------------------------------------------------
  // Constrain free inputs only in the standalone model; the wrapper's real
  // dispatch logic must satisfy these requirements.

  generate
    if (FORMAL_STANDALONE_ENV) begin : gen_formal_dispatch_contract
      // Dispatch must not coincide with a partial flush. Full flushes may
      // coincide with stale dispatch packets; the flush branch below wins and
      // clears valid state, so those packets are ignored.
      always_comb begin
        if (i_flush_en) assume (!dispatch_valid);
      end

      // No dispatch when full
      always_comb begin
        if (full && !i_flush_all && !i_flush_en) assume (!dispatch_valid);
      end

      // Slot-2 dispatch follows the same flush / capacity rules.
      always_comb begin
        if (i_flush_en) assume (!dispatch_valid_2);
        // Slot-2 needs room for itself given whether slot-1 is also firing.
        if (dispatch_valid && full_for_2 && !i_flush_all && !i_flush_en) assume (!dispatch_valid_2);
        if (!dispatch_valid && full && !i_flush_all && !i_flush_en) assume (!dispatch_valid_2);
      end

      // The wrapper drives i_intent_1 from the same per-RS slot-1 decode that
      // produces i_dispatch.valid. The slot-2 alloc index relies on that
      // contract to choose the second free entry when both slots target this RS.
      always_comb begin
        assume (i_intent_1 == dispatch_valid);
      end
    end
  endgenerate

  // The stage2 divide bit must match its opcode. With the real divider
  // connected, a presented divide must find it idle; the shim cannot queue it.
  generate
    if (DIVIDE_ISSUE_GATE) begin : gen_formal_divide_gate
      always_comb begin
        if (i_rst_n) begin
          p_stage2_divide_bit :
          assert (!stage2_valid || (stage2_is_divide == rs_is_divide_op(stage2_op)));
          if (!FORMAL_STANDALONE_ENV) begin
            p_divide_issue_finds_divider_idle :
            assert (!(o_issue.valid && rs_is_divide_op(o_issue.op) && i_divider_busy));
          end
          p_divide_gate_requires_single_issue : assert (!DUAL_ISSUE);
        end
      end
    end
  endgenerate

  // -------------------------------------------------------------------------
  // Combinational assertions
  // -------------------------------------------------------------------------

  always_comb begin
    if (ALLOC_INDEXED_REPAIR) begin
      p_indexed_repair_mode_exclusive : assert (!DISPATCH_REPAIR_BYPASS && !ISSUE_REPAIR_BYPASS);
      // Repair targets are meaningful only after reset clears their registers.
      if (i_rst_n) begin
        p_indexed_repair_slot1_onehot : assert ($onehot0(repair_slot1_target_q));
        p_indexed_repair_slot2_onehot : assert ($onehot0(repair_slot2_target_q));
        p_indexed_repair_targets_disjoint :
        assert ((repair_slot1_target_q & repair_slot2_target_q) == '0);
      end
    end
    if (BROADCAST_FREE_SOURCE_VALUES)
      p_broadcast_free_values_requires_speculation : assert (SPECULATIVE_DATA_WRITES);
    if (i_rst_n && ISSUE_CDB_TAG_SHADOW) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (rs_valid[i]) begin
          // Labels omitted: Yosys rejects duplicate names from loop unrolling.
          assert (rs_src1_issue_tag[i] == rs_src1_tag[i]);
          assert (rs_src2_issue_tag[i] == rs_src2_tag[i]);
        end
      end
    end
  end

  always_comb begin
    if (i_rst_n) begin
      p_full_iff_all_valid : assert (full == (&rs_valid));
    end
  end

  always_comb begin
    if (i_rst_n) begin
      p_empty_iff_none_valid : assert (empty == (rs_valid == '0));
    end
  end

  // Yosys does not support 'automatic' inside always_comb, so the
  // intermediate variable is declared outside the block.
  logic [CountWidth-1:0] f_expected_count;
  always_comb begin
    f_expected_count = '0;
    for (int i = 0; i < DEPTH; i++) begin
      f_expected_count = f_expected_count + {{(CountWidth - 1) {1'b0}}, rs_valid[i]};
    end
  end
  always_comb begin
    if (i_rst_n) begin
      p_count_matches_popcount : assert (count == f_expected_count);
    end
  end

  // The fixed-depth one-hot slot-2 allocation select equals the alloc_idx_2
  // decode on every free entry, for every rs_valid pattern.
  always_comb begin
    if (i_rst_n) begin
      p_alloc_sel_2_matches_index :
      assert (alloc_sel_2 == (data_write_2_en ? (index_to_onehot(alloc_idx_2) & ~rs_valid) : '0));
    end
  end

  always_comb begin
    if (i_rst_n && issue_fire) begin
      p_issue_entry_was_valid : assert (rs_valid[issue_idx]);
      p_issue_entry_was_ready : assert (entry_ready[issue_idx]);
    end
  end

  always_comb begin
    if (i_rst_n && o_issue.valid) begin
      p_stage2_output_coherent : assert (stage2_valid);
    end
  end

  // -------------------------------------------------------------------------
  // Sequential assertions
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin

      if (ALLOC_INDEXED_REPAIR) begin
        if ($past(dispatch_fire) && !$past(i_flush_all) && !$past(i_flush_en)) begin
          p_indexed_repair_slot1_tracks_dispatch :
          assert (repair_slot1_target_q == index_to_onehot($past(free_idx)));
        end else begin
          p_indexed_repair_slot1_clears : assert (repair_slot1_target_q == '0);
        end

        if ($past(dispatch_fire_2) && !$past(i_flush_all) && !$past(i_flush_en)) begin
          p_indexed_repair_slot2_tracks_dispatch :
          assert (repair_slot2_target_q == index_to_onehot($past(alloc_idx_2)));
        end else begin
          p_indexed_repair_slot2_clears : assert (repair_slot2_target_q == '0);
        end
      end

      // Committed dispatch must retain its packet's source values at the next
      // edge. This mode disables dispatch repair bypass; a dispatch-cycle CDB
      // match still leaves the packet value until the deferred delivery edge.
      if (BROADCAST_FREE_SOURCE_VALUES && !DISPATCH_REPAIR_BYPASS && !$past(
              i_flush_all
          ) && !$past(
              i_flush_en
          )) begin
        if ($past(dispatch_fire)) begin
          p_broadcast_slot1_src1_exact :
          assert (rs_src1_value[$past(free_idx)] == $past(dispatch_src1_value));
          p_broadcast_slot1_src2_exact :
          assert (rs_src2_value[$past(free_idx)] == $past(dispatch_src2_value));
          if (HAS_SRC3) begin
            p_broadcast_slot1_src3_exact :
            assert (rs_src3_value[$past(free_idx)] == $past(dispatch_src3_value));
          end
        end
        if ($past(dispatch_fire_2)) begin
          p_broadcast_slot2_src1_exact :
          assert (rs_src1_value[$past(alloc_idx_2)] == $past(dispatch_src1_value_2));
          p_broadcast_slot2_src2_exact :
          assert (rs_src2_value[$past(alloc_idx_2)] == $past(dispatch_src2_value_2));
          if (HAS_SRC3) begin
            p_broadcast_slot2_src3_exact :
            assert (rs_src3_value[$past(alloc_idx_2)] == $past(dispatch_src3_value_2));
          end
        end
      end

      if ($past(dispatch_fire) && !$past(i_flush_all) && !$past(i_flush_en)) begin
        p_dispatch_sets_valid : assert (rs_valid[$past(free_idx)]);
      end

      if ($past(dispatch_fire_2) && !$past(i_flush_all) && !$past(i_flush_en)) begin
        p_dispatch_2_sets_valid : assert (rs_valid[$past(alloc_idx_2)]);
      end

      if ($past(issue_fire) && !$past(i_flush_all) && !$past(i_flush_en)) begin
        p_issue_clears_valid : assert (!rs_valid[$past(issue_idx)]);
      end

      if ($past(i_flush_all)) begin
        p_flush_all_empties : assert (rs_valid == '0);
        p_flush_all_empties_stage2 : assert (!stage2_valid);
      end

      // CDB snoop sets ready bit when tag matches (all entries checked).
      // Labels omitted: Yosys rejects duplicate names from loop unrolling.
      for (int i = 0; i < DEPTH; i++) begin
        if ($past(
                i_cdb.valid
            ) && $past(
                rs_valid[i]
            ) && !$past(
                i_flush_all
            ) && !$past(
                i_flush_en
            )) begin
          if (!$past(rs_src1_ready[i]) && $past(rs_src1_tag[i]) == $past(i_cdb.tag))
            assert (rs_src1_ready[i]);
          if (!$past(rs_src2_ready[i]) && $past(rs_src2_tag[i]) == $past(i_cdb.tag))
            assert (rs_src2_ready[i]);
          if (HAS_SRC3 && !$past(rs_src3_ready[i]) && $past(rs_src3_tag[i]) == $past(i_cdb.tag))
            assert (rs_src3_ready[i]);
        end
      end

      // Partial flush only invalidates younger entries
      if ($past(i_flush_en) && !$past(i_flush_all)) begin
        for (int i = 0; i < DEPTH; i++) begin
          if ($past(
                  rs_valid[i]
              ) && !should_flush_entry(
                  $past(rs_rob_tag[i]), $past(i_flush_tag), $past(i_rob_head_tag)
              )) begin
            assert (rs_valid[i]);
          end
        end
      end

    end

    if (f_past_valid && i_rst_n && !$past(i_rst_n)) begin
      p_reset_clears_all : assert (rs_valid == '0);
    end
  end

  // Check deferred delivery in steps: dispatch captures pending and lane
  // bits plus the broadcast value; the following edge sets ready and clears
  // pending. The final value-array write is not asserted here: observing it
  // adds the done-repair CAM muxes to the standalone solver model. Simulation
  // checks repair and saved CDB values agree. Labels are omitted because
  // Yosys rejects duplicate names from loop unrolling.
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin
      // The central lane copies track the broadcast values one cycle behind.
      p_deferred_lane0_copy : assert (cdb0_value_q == $past(i_cdb.value));
      p_deferred_lane1_copy : assert (cdb1_value_q == $past(i_cdb_2.value));
      for (int i = 0; i < DEPTH; i++) begin
        // A dispatch-cycle CDB match registers the pend pair at the
        // allocated entry (both lane encodings, plus the slot-2 path).
        if ($past(
                dispatch_fire
            ) && !$past(
                i_flush_all
            ) && !$past(
                i_flush_en
            ) && $past(
                free_idx
            ) == $clog2(
                DEPTH
            )'(i)) begin
          if ($past(dispatch_src1_cdb0_match) && !$past(dispatch_src1_repair_match))
            assert (src1_cdb_pend[i] && !src1_cdb_pend_lane[i]);
          if ($past(
                  dispatch_src1_cdb1_match
              ) && !$past(
                  dispatch_src1_cdb0_match
              ) && !$past(
                  dispatch_src1_repair_match
              ))
            assert (src1_cdb_pend[i] && src1_cdb_pend_lane[i]);
        end
        if ($past(
                dispatch_fire_2
            ) && !$past(
                i_flush_all
            ) && !$past(
                i_flush_en
            ) && $past(
                alloc_idx_2
            ) == $clog2(
                DEPTH
            )'(i)) begin
          if ($past(dispatch_src1_cdb0_match_2) && !$past(dispatch_src1_repair_match_2))
            assert (src1_cdb_pend[i] && !src1_cdb_pend_lane[i]);
        end
        // Delivery: one cycle after pend, the source is ready and the pend
        // flag has retired.
        if ($past(src1_cdb_pend[i])) begin
          assert (rs_src1_ready[i]);
          assert (!src1_cdb_pend[i]);
        end
        if ($past(src2_cdb_pend[i])) begin
          assert (rs_src2_ready[i]);
          assert (!src2_cdb_pend[i]);
        end
        if (HAS_SRC3 && $past(src3_cdb_pend[i])) begin
          assert (rs_src3_ready[i]);
          assert (!src3_cdb_pend[i]);
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // Cover properties
  // -------------------------------------------------------------------------
  // Covers use the standalone input environment.
  generate
    if (FORMAL_STANDALONE_ENV) begin : gen_formal_covers
      always @(posedge i_clk) begin
        if (i_rst_n) begin
          cover_dispatch_and_issue : cover (dispatch_fire && issue_fire);

          // A broadcast overlaps a live entry; operand tags need not match.
          cover_cdb_wakeup : cover (i_cdb.valid && |rs_valid);

          cover_full : cover (full);

          cover_partial_flush : cover (i_flush_en && |rs_valid);

          // Entry dispatched in the cycle the CDB broadcasts its src1 tag
          cover_cdb_bypass_at_dispatch :
          cover (dispatch_fire && i_cdb.valid && !dispatch_src1_ready
                 && dispatch_src1_tag == i_cdb.tag);

          cover_deferred_cdb_delivery : cover (|src1_cdb_pend);

          cover_dispatch_2_wide : cover (dispatch_fire && dispatch_fire_2);

          cover_dispatch_2_only : cover (dispatch_fire_2 && !dispatch_fire);

          // Stage2 back-to-back: consumed and refilled in the same cycle
          cover_stage2_back_to_back : cover (stage2_accept && issue_fire);

          cover_stage2_flush : cover (stage2_should_flush);

          cover_stage2_blocked : cover (stage2_valid && !i_fu_ready && !stage2_should_flush);
        end
      end
    end
  endgenerate

`endif  // RS_PRETAG_LOCAL_PROOF
`endif  // FORMAL

`ifdef RS_DISPATCH_DEFER_LOCAL_PROOF
  // Reference equations, with the ready qualification inside both CDB matches.
  always_comb begin
    assert (dispatch_src1_cdb_defer ==
        ((dispatch_src1_cdb0_match || dispatch_src1_cdb1_match) &&
         !dispatch_src1_repair_match));
    assert (dispatch_src2_cdb_defer ==
        ((dispatch_src2_cdb0_match || dispatch_src2_cdb1_match) &&
         !dispatch_src2_repair_match));
    assert (dispatch_src3_cdb_defer ==
        ((dispatch_src3_cdb0_match || dispatch_src3_cdb1_match) &&
         !dispatch_src3_repair_match));
    assert (dispatch_src1_cdb_defer_2 ==
        ((dispatch_src1_cdb0_match_2 || dispatch_src1_cdb1_match_2) &&
         !dispatch_src1_repair_match_2));
    assert (dispatch_src2_cdb_defer_2 ==
        ((dispatch_src2_cdb0_match_2 || dispatch_src2_cdb1_match_2) &&
         !dispatch_src2_repair_match_2));
    assert (dispatch_src3_cdb_defer_2 ==
        ((dispatch_src3_cdb0_match_2 || dispatch_src3_cdb1_match_2) &&
         !dispatch_src3_repair_match_2));
  end
`endif

`ifdef RS_INDEXED_DEFERRED_FOLD_LOCAL_PROOF
  function automatic logic [FLEN:0] f_original_indexed_write(
      input logic dispatch1, input logic dispatch2, input logic resident, input logic ready,
      input logic live0, input logic live1, input logic target1, input logic target2,
      input logic repair1, input logic repair2, input logic pending, input logic lane,
      input logic [FLEN-1:0] d1, input logic [FLEN-1:0] d2, input logic [FLEN-1:0] c0,
      input logic [FLEN-1:0] c1, input logic [FLEN-1:0] r1, input logic [FLEN-1:0] r2,
      input logic [FLEN-1:0] q0, input logic [FLEN-1:0] q1);
    begin
      f_original_indexed_write = '0;
      if (dispatch1) f_original_indexed_write = {1'b1, d1};
      if (dispatch2) f_original_indexed_write = {1'b1, d2};
      if (resident && !ready) begin
        if (live0) f_original_indexed_write = {1'b1, c0};
        else if (live1) f_original_indexed_write = {1'b1, c1};
        else if (target1 && repair1) f_original_indexed_write = {1'b1, r1};
        else if (target2 && repair2) f_original_indexed_write = {1'b1, r2};
      end
      if (pending) f_original_indexed_write = {1'b1, lane ? q1 : q0};
    end
  endfunction

  for (genvar entry = 0; entry < DEPTH; entry++) begin : gen_fold_write_proof
    wire [FLEN:0] reference_src1 = f_original_indexed_write(
        indexed_dispatch1_write[entry],
        indexed_dispatch2_write[entry],
        rs_valid[entry],
        rs_src1_ready[entry],
        i_cdb.valid && rs_src1_tag[entry] == i_cdb.tag,
        i_cdb_2.valid && rs_src1_tag[entry] == i_cdb_2.tag,
        repair_slot1_target_q[entry],
        repair_slot2_target_q[entry],
        i_repair_valid_1,
        i_repair_valid_4,
        src1_cdb_pend[entry],
        src1_cdb_pend_lane[entry],
        dispatch_src1_stored_value,
        dispatch_src1_stored_value_2,
        i_cdb.value,
        i_cdb_2.value,
        i_repair_value_1,
        i_repair_value_4,
        cdb0_value_q,
        cdb1_value_q
    );
    always_comb begin
      if (i_rst_n) begin
        assert ($onehot0(indexed_src1_write_sel[entry]));
        assert ((|indexed_src1_write_sel[entry]) == reference_src1[FLEN]);
        if (reference_src1[FLEN])
          assert (indexed_src1_write_data[entry] == reference_src1[FLEN-1:0]);
      end
    end
    wire [FLEN:0] reference_src2 = f_original_indexed_write(
        indexed_dispatch1_write[entry],
        indexed_dispatch2_write[entry],
        rs_valid[entry],
        rs_src2_ready[entry],
        i_cdb.valid && rs_src2_tag[entry] == i_cdb.tag,
        i_cdb_2.valid && rs_src2_tag[entry] == i_cdb_2.tag,
        repair_slot1_target_q[entry],
        repair_slot2_target_q[entry],
        i_repair_valid_2,
        i_repair_valid_5,
        src2_cdb_pend[entry],
        src2_cdb_pend_lane[entry],
        dispatch_src2_stored_value,
        dispatch_src2_stored_value_2,
        i_cdb.value,
        i_cdb_2.value,
        i_repair_value_2,
        i_repair_value_5,
        cdb0_value_q,
        cdb1_value_q
    );
    always_comb begin
      if (i_rst_n) begin
        assert ($onehot0(indexed_src2_write_sel[entry]));
        assert ((|indexed_src2_write_sel[entry]) == reference_src2[FLEN]);
        if (reference_src2[FLEN])
          assert (indexed_src2_write_data[entry] == reference_src2[FLEN-1:0]);
      end
    end
    if (HAS_SRC3) begin : gen_src3
      wire [FLEN:0] reference_src3 = f_original_indexed_write(
          indexed_dispatch1_write[entry],
          indexed_dispatch2_write[entry],
          rs_valid[entry],
          rs_src3_ready[entry],
          i_cdb.valid && rs_src3_tag[entry] == i_cdb.tag,
          i_cdb_2.valid && rs_src3_tag[entry] == i_cdb_2.tag,
          repair_slot1_target_q[entry],
          repair_slot2_target_q[entry],
          i_repair_valid_3,
          i_repair_valid_6,
          src3_cdb_pend[entry],
          src3_cdb_pend_lane[entry],
          dispatch_src3_stored_value,
          dispatch_src3_stored_value_2,
          i_cdb.value,
          i_cdb_2.value,
          i_repair_value_3,
          i_repair_value_6,
          cdb0_value_q,
          cdb1_value_q
      );
      always_comb begin
        if (i_rst_n) begin
          assert ($onehot0(indexed_src3_write_sel[entry]));
          assert ((|indexed_src3_write_sel[entry]) == reference_src3[FLEN]);
          if (reference_src3[FLEN])
            assert (indexed_src3_write_data[entry] == reference_src3[FLEN-1:0]);
        end
      end
    end
  end

  // Check shared delivery control and values under the standalone dispatch
  // requirements and reset. Repair and CDB values remain arbitrary.
  reg f_fold_past_valid;
  initial f_fold_past_valid = 1'b0;
  always @(posedge i_clk) f_fold_past_valid <= 1'b1;
  initial assume (!i_rst_n);
  always @(posedge i_clk) begin
    if (f_fold_past_valid) assume (i_rst_n);
  end
  always_comb begin
    // Apply the same dispatch requirements as the standalone station.
    if (i_flush_en) begin
      assume (!dispatch_valid);
      assume (!dispatch_valid_2);
    end
    if (full && !i_flush_all && !i_flush_en) assume (!dispatch_valid);
    if (dispatch_valid && full_for_2 && !i_flush_all && !i_flush_en) assume (!dispatch_valid_2);
    if (!dispatch_valid && full && !i_flush_all && !i_flush_en) assume (!dispatch_valid_2);
    assume (i_intent_1 == dispatch_valid);
    if (i_rst_n) begin
      assert ($onehot0(repair_slot1_target_q));
      assert ($onehot0(repair_slot2_target_q));
      assert ((src1_cdb_pend & ~(repair_slot1_target_q | repair_slot2_target_q)) == '0);
      assert ((src2_cdb_pend & ~(repair_slot1_target_q | repair_slot2_target_q)) == '0);
      if (HAS_SRC3)
        assert ((src3_cdb_pend & ~(repair_slot1_target_q | repair_slot2_target_q)) == '0);
      for (int entry = 0; entry < DEPTH; entry++) begin
        if (repair_slot1_target_q[entry] && !src1_cdb_pend[entry])
          assert (indexed_delivery_1 == i_repair_value_1);
        if (repair_slot2_target_q[entry] && !src1_cdb_pend[entry])
          assert (indexed_delivery_4 == i_repair_value_4);
        if (src1_cdb_pend[entry])
          assert ((repair_slot1_target_q[entry] ? indexed_delivery_1 : indexed_delivery_4) ==
                  (src1_cdb_pend_lane[entry] ? cdb1_value_q : cdb0_value_q));
        if (repair_slot1_target_q[entry] && !src2_cdb_pend[entry])
          assert (indexed_delivery_2 == i_repair_value_2);
        if (repair_slot2_target_q[entry] && !src2_cdb_pend[entry])
          assert (indexed_delivery_5 == i_repair_value_5);
        if (src2_cdb_pend[entry])
          assert ((repair_slot1_target_q[entry] ? indexed_delivery_2 : indexed_delivery_5) ==
                  (src2_cdb_pend_lane[entry] ? cdb1_value_q : cdb0_value_q));
        if (HAS_SRC3) begin
          if (repair_slot1_target_q[entry] && !src3_cdb_pend[entry])
            assert (indexed_delivery_3 == i_repair_value_3);
          if (repair_slot2_target_q[entry] && !src3_cdb_pend[entry])
            assert (indexed_delivery_6 == i_repair_value_6);
          if (src3_cdb_pend[entry])
            assert ((repair_slot1_target_q[entry] ? indexed_delivery_3 : indexed_delivery_6) ==
                  (src3_cdb_pend_lane[entry] ? cdb1_value_q : cdb0_value_q));
        end
      end
      cover (dispatch_fire_2 && !dispatch_fire);
      cover ((|src1_cdb_pend) && (|src2_cdb_pend));
      cover ((|src1_cdb_pend) && i_flush_all);
      cover ((|src2_cdb_pend) && i_flush_en);
    end
  end
`endif
`ifdef RS_PRIMARY_PAYLOAD_LOCAL_PROOF
  always_comb begin
    if (CAPTURE_PRIMARY_EFFECTIVE_OPERANDS) begin
      p_primary_payload_select_matches_index :
      assert (primary_issue_onehot == (PayloadDepth'(1) << issue_idx));
    end
  end
`endif
`ifdef RS_PRIMARY_PAYLOAD_LOCAL_PROOF
  always_comb begin
    assert ({primary_issue_tag, primary_issue_use_imm, primary_issue_hint, primary_issue_divide} ==
            {rs_rob_tag[issue_idx], rs_use_imm[issue_idx],
             rs_writes_cdb_hint[issue_idx], rs_is_divide[issue_idx]});
    if (CAPTURE_PRIMARY_EFFECTIVE_OPERANDS) begin
      assert (issue1_clear_mask == ({DEPTH{issue_fire}} & index_to_onehot(issue_idx)));
      assert ($clog2(
          DEPTH
      )'({payload_group_idx, payload_group_pick[payload_group_idx]}) == issue_idx);
    end
  end
`endif

endmodule
