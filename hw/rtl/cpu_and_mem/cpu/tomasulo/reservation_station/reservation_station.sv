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
 * Parameterized reservation station. Instances use these depths:
 *   INT_RS=8, MUL_RS=4, MEM_RS=8, FP_RS=6, FMUL_RS=4, FDIV_RS=2
 *
 * Sources wake from CDB or done-repair. Dispatch-cycle CDB matches defer
 * registered lane values by one cycle, keeping live CDB data and compares off
 * dispatch writes. Optional allocation-indexed repair avoids resident-entry
 * tag broadcast. Issue normally chooses the lowest ready index; DUAL_ISSUE
 * adds an isolated non-branch second winner and payload bank for INT_RS.
 * Optional src3 supports FMA. Partial and full flushes clear validity.
 *
 * Control/source fields remain in FFs for parallel wakeup and flush scans.
 * Dispatch payloads use two-write-port distributed RAM and are read at issue;
 * FF valid bits make stale RAM contents harmless. The INT instance keeps the
 * XLEN-wide pc, link address and predicted target in a ROB-tag-indexed side
 * RAM read behind its port-0 stage2 tag (TAG_INDEXED_BRANCH_PAYLOAD), so the
 * per-entry payload and both stage2 banks carry no XLEN branch words.
 */

module reservation_station #(
    parameter int unsigned DEPTH = 8,
    parameter bit HAS_SRC3 = 1'b1,
    // Precompute lookahead winners for both CDB lane-valid bits.
    parameter bit PREISSUE_VALID_COFACTOR = 1'b0,
    parameter bit DISPATCH_REPAIR_BYPASS = 1'b1,
    parameter bit ISSUE_REPAIR_BYPASS = 1'b1,
    // The registered done-repair responses normally carry tags and CAM-snoop
    // every resident entry.  Immediate-dispatch RSes can instead remember the
    // exact entries allocated by the two dispatch slots and, one cycle later,
    // write channels 1/2/3 directly to slot 1's src1/src2/src3 and channels
    // 4/5/6 to slot 2's.  This is cycle-identical to the registered snoop but
    // removes the global dispatch-tag repair fabric.  It cannot be combined
    // with the two same-cycle repair bypass parameters above.
    parameter bit ALLOC_INDEXED_REPAIR = 1'b0,
    parameter bit TRACK_INT_WRITEBACK_HINT = 1'b0,
    parameter bit SPECULATIVE_DATA_WRITES = 1'b0,
    // With speculative writes, prefill every currently-free entry with the
    // slot-1 source values and override the slot-2 allocation target with the
    // slot-2 values.  Only rs_valid commits an entry, so the extra writes are
    // architecturally invisible.  This changes the wide source-value flops'
    // dispatch CE from a priority-decoded free index to the entry-local
    // !rs_valid bit; their D-input data select is a per-entry one-hot
    // (alloc_sel_2) computed from rs_valid at fixed depth, equal to the
    // alloc_idx_2 decode without the free-index priority sweep.
    parameter bit BROADCAST_FREE_SOURCE_VALUES = 1'b0,
    // Optional src1/src2 tag shadows used only by the same-cycle CDB issue
    // bypass compares.  With speculative writes enabled, the shadows retain
    // the architectural bank's indexed writes but complement a slot's tag
    // when that slot does not target this RS.  They are then non-equivalent
    // while invalid, so synthesis cannot merge them, but every committed slot
    // writes the normal tag and the banks must match for every valid entry.
    // This isolates issue-time matches from the identical high-fanout
    // comparisons that control sequential source-value capture.
    parameter bit ISSUE_CDB_TAG_SHADOW = 1'b0,
    // Optional phase-identical valid/tag inputs used only by the combinational
    // same-cycle issue bypass.  Sequential resident wakeup/value capture and
    // dispatch-defer logic always use the complete i_cdb packets.  Keeping
    // this default off leaves every ordinary RS on the legacy inputs.
    parameter bit ISSUE_CDB_META_ANCHORS = 1'b0,
    // INT port 0 can capture the exact effective src1/src2 values directly at
    // the existing stage2 boundary, matching the DUAL_ISSUE port-1 scheme.
    // This mode is valid only for HAS_SRC3=0 and defaults off so every other
    // station retains its legacy post-Q bypass masks and CDB value banks.
    parameter bit CAPTURE_PRIMARY_EFFECTIVE_OPERANDS = 1'b0,
    // Optional INT-only physical twin of stage2_rob_tag.  It captures the same
    // selected tag under the same issue_fire enable, but is exported only to
    // branch-resolution checkpoint/age predicates.  Keeping ROB addressing,
    // recovery capture, and FU tags on stage2_rob_tag splits the long branch
    // predicate cone from the architectural tag's broad fanout without adding
    // a pipeline stage.
    parameter bit BRANCH_PREDICATE_TAG_ANCHOR = 1'b0,
    parameter bit TRUST_DISPATCH_VALID = 1'b0,
    // Optional reserve for exported dispatch back-pressure.  A non-zero value
    // lets timing-sensitive RS instances publish conservative registered full
    // flags from the previous occupancy instead of exact flags from count_next,
    // keeping current-cycle dispatch valid off the exported-status flop D path.
    parameter int unsigned DISPATCH_STATUS_RESERVE = 0,
    // Second issue port (INT_RS only): an isolated balanced select for the
    // lowest ready nonbranch other than port 0's canonical lowest-ready winner
    // (branches stay on port 0, which owns the single branch_resolution path),
    // a second payload-RAM copy, and a full second stage2 bank feeding
    // o_issue_2 / i_fu_ready_2.
    parameter bit DUAL_ISSUE = 1'b0,
    // DUAL_ISSUE port 1 selects only among entries [0, ISSUE2_WINDOW); 0
    // means the whole station. Port 0 still sees every entry. Allocation
    // takes the lowest free index, so the window holds the oldest-resident
    // work; it shortens the port-1 selector and operand/payload muxes.
    parameter int unsigned ISSUE2_WINDOW = 0,
    // Symmetric lane-1 wakeup: include i_cdb_2 in the combinational
    // same-cycle issue-bypass cone (readiness + issue-time value
    // substitution), so lane-1 results wake dependents in the same cycle,
    // like lane 0.  It defaults on because with two ALU pipes dual
    // completions are common and the old one-cycle lane-1 penalty costs
    // more.  Disable it per instance if the wakeup cone becomes the WNS
    // limiter again.
    parameter bit LANE1_ISSUE_BYPASS = 1'b1,
    // INT only: keep pc, link_addr and predicted_target in a ROB-tag-indexed
    // side RAM written at dispatch and read behind port 0's stage2 tag, so the
    // per-entry payload RAM, the issue-index fanout and both stage2 banks
    // carry none of those XLEN words.  Their consumers (branch resolution's
    // JALR target compare, early recovery's redirect/BTB capture) see the
    // same values in the same cycle.  Off, port 0 drives zeros for the three
    // fields.  Contract: a dispatched ROB tag is never live in the station
    // (resident or in stage2), as ROB allocation guarantees.
    parameter bit TAG_INDEXED_BRANCH_PAYLOAD = 1'b0,
    // The standalone formal top (formal/reservation_station.sby) drives this
    // station's inputs freely, so its `ifdef FORMAL` block assumes the
    // dispatch contract the core guarantees and carries the station's own
    // cover set.  formal/tomasulo_wrapper.sby also reads this file with
    // `-formal` and sets this to 0 on every instance: there the routing,
    // occupancy and flush logic that produces these inputs is present, so a
    // submodule assumption would weaken that proof instead of constraining a
    // free environment, and the station's covers belong to its own run.  With
    // it off, the ROB-tag ownership contract the branch-payload side RAM needs
    // becomes an assertion checked against the real allocator (see
    // cdb_arbiter's FORMAL_ASSUME_VALUE_SOURCE_CONTRACT for the same split).
    parameter bit FORMAL_STANDALONE_ENV = 1'b1
) (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Dispatch Interface (from Dispatch Unit)
    // =========================================================================
    input riscv_pkg::rs_dispatch_t i_dispatch,
    // Slot-2 dispatch port for 2-wide dispatch.  The dispatch unit routes
    // slot-2 to the correct RS based on its rs_type, so each RS only sees a
    // slot-2 packet with .valid=1 when slot-2 targets it.
    input riscv_pkg::rs_dispatch_t i_dispatch_2,
    // Fast "slot-1 wants this RS" intent, driven from the registered rs_type
    // field of the per-RS dispatch packet.  It does not include bundle_fire_ok
    // or any other RS's full check.  Two uses:
    //   1. alloc_idx_2 selection always uses i_intent_1, regardless of
    //      SPECULATIVE_DATA_WRITES, so the rs_valid commit and LUTRAM-address
    //      cone (used whenever slot-2 commits) sees a registered rs_type input
    //      rather than the slow dispatch_fire chain, which gathers every
    //      i_*_rs_full bit through the bundle_fire_ok mux.  This is safe:
    //      whenever the strict slot-2 commit dispatch_fire_2 fires, the bundle
    //      is atomic and i_intent_1 == dispatch_fire by construction, so the
    //      chosen entry index is the one a dispatch_fire-based mux would have
    //      picked.
    //   2. With SPECULATIVE_DATA_WRITES, the data CE on rs_*_value/rs_*_tag/
    //      rs_rob_tag gates on i_intent_1 instead of the slow dispatch_fire,
    //      so the per-entry CE does not inherit the same long cone.  The
    //      architectural commit (rs_valid set) still uses the slow
    //      dispatch_fire, so a wrong intent only causes a harmless speculative
    //      write into a free entry whose rs_valid bit stays 0.
    input logic i_intent_1,
    output logic o_full,
    // Asserted when there is room for at most 1 more entry (a 2-wide dispatch
    // bundle would not fit).  Distinct from o_full so dispatch can
    // independently gate slot-2 while still allowing slot-1 to fire.
    output logic o_full_for_2,

    // =========================================================================
    // CDB Snoop / Wakeup
    // =========================================================================
    input riscv_pkg::cdb_broadcast_t i_cdb,

    // Second CDB lane (2-wide CDB). With LANE1_ISSUE_BYPASS (default on, used
    // by all instances), lane-1 results also feed the combinational
    // entry_ready/stage2 issue-bypass cone, so a lane-1 result wakes its
    // consumers in the same cycle, like lane 0.  The registered snoop +
    // dispatch-capture paths below remain the only wakeup paths when
    // LANE1_ISSUE_BYPASS is disabled per instance as a timing fallback.
    input riscv_pkg::cdb_broadcast_t i_cdb_2,

    // Optional narrow issue-only CDB views.  When ISSUE_CDB_META_ANCHORS=1,
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
    output logic                                                        o_issue_writes_cdb_hint,
    // Phase-identical physical twin used only by branch-resolution predicates.
    // The default mode aliases the architectural stage2 tag without adding FFs.
    output logic                 [riscv_pkg::ReorderBufferTagWidth-1:0] o_branch_predicate_tag,

    // Second issue port (DUAL_ISSUE only; tied off otherwise).
    output riscv_pkg::rs_issue_t       o_issue_2,
    input  logic                       i_fu_ready_2,
    output logic                       o_issue_writes_cdb_hint_2,
    // Effective barrel amount captured on the same edge as port-2 operands.
    output logic                 [5:0] o_issue_shift_amount_2,

    // =========================================================================
    // Current Issue Payload Peek (combinational, independent of i_fu_ready)
    // =========================================================================
    output logic o_next_issue_valid,
    output logic o_next_issue_is_sc,
    output logic o_next_issue_needs_lq,

    // =========================================================================
    // Pre-issue look-ahead (1 cycle before o_issue fires). For MEM_RS, these
    // expose the rob_tag and mem_needs_lq of the entry being captured into
    // stage2 this cycle, so the LQ can pre-compute the addr_update CAM match
    // and register it before the issue fires.
    // =========================================================================
    output logic [  riscv_pkg::ReorderBufferTagWidth-1:0] o_pre_issue_rob_tag,
    // Four CDB-valid outcomes and their actual selector. The LQ can register
    // the CAM outcomes and selector independently on the same edge.
    output logic [4*riscv_pkg::ReorderBufferTagWidth-1:0] o_pre_issue_rob_tags,
    output logic [                                   1:0] o_pre_issue_sel,
    output logic                                          o_pre_issue_needs_lq,

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
    // Given a query rob_tag (typically the ROB head tag), expose whether this
    // RS currently holds that tag and what state it is in. Used to decompose
    // head_wait_int into sub-buckets at the wrapper level. Drives no
    // functional logic; synthesis optimizes these away if unconnected.
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_head_query_tag,
    output logic                                        o_head_query_in_rs,
    output logic                                        o_head_query_rs_ready,
    output logic                                        o_head_query_in_stage2,

    // Width-funnel perf observer (registered, profiling only): the stage-1
    // issue port fired while at least one more entry was also ready, so the
    // single issue port was the limiter that cycle.  Meaningful for
    // single-issue-port instances (lane-1 issue is not subtracted); drives
    // no functional logic.
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
  // Wire aliases allow the module body to use short names for struct fields.

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

  // Deferred dispatch-cycle CDB capture: a source whose CDB broadcast lands
  // in the dispatch cycle is not resolved into the value write here, because
  // that would put the tag-match cone and the raw CDB value nets in front of
  // every entry's wide value mux on the dispatch path.  Dispatch instead
  // registers a per-source {pend, lane} pair, and the value is delivered on
  // the next cycle from the central registered lane copies
  // (cdb0_value_q / cdb1_value_q), together with the deferred ready set.
  // The entry cannot issue in the delivery cycle (the source still reads
  // not-ready), so the deferred wake costs one cycle in this rare window.
  // The done-repair dispatch bypass is excluded: it already resolved the
  // value into the stored-value mux above and set ready at dispatch.
  wire dispatch_src1_cdb_defer =
      (dispatch_src1_cdb0_match || dispatch_src1_cdb1_match) && !dispatch_src1_repair_match;
  wire dispatch_src2_cdb_defer =
      (dispatch_src2_cdb0_match || dispatch_src2_cdb1_match) && !dispatch_src2_repair_match;
  wire dispatch_src3_cdb_defer =
      (dispatch_src3_cdb0_match || dispatch_src3_cdb1_match) && !dispatch_src3_repair_match;
  // Delivery lane select (0 = i_cdb, 1 = i_cdb_2).  The two lanes never
  // broadcast the same tag, so at most one match term is set; the !cdb0
  // guard keeps lane-0 priority if that contract is ever violated.
  wire dispatch_src1_cdb_defer_lane = dispatch_src1_cdb1_match && !dispatch_src1_cdb0_match;
  wire dispatch_src2_cdb_defer_lane = dispatch_src2_cdb1_match && !dispatch_src2_cdb0_match;
  wire dispatch_src3_cdb_defer_lane = dispatch_src3_cdb1_match && !dispatch_src3_cdb0_match;

  // Slot-2 dispatch field aliases (mirror of slot-1).  Slot-2 only fires when
  // the dispatch unit has steered slot-2 to this RS instance.
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

  // Slot-2 twins of the deferred dispatch-CDB capture controls above.
  wire dispatch_src1_cdb_defer_2 =
      (dispatch_src1_cdb0_match_2 || dispatch_src1_cdb1_match_2) &&
      !dispatch_src1_repair_match_2;
  wire dispatch_src2_cdb_defer_2 =
      (dispatch_src2_cdb0_match_2 || dispatch_src2_cdb1_match_2) &&
      !dispatch_src2_repair_match_2;
  wire dispatch_src3_cdb_defer_2 =
      (dispatch_src3_cdb0_match_2 || dispatch_src3_cdb1_match_2) &&
      !dispatch_src3_repair_match_2;
  wire dispatch_src1_cdb_defer_lane_2 = dispatch_src1_cdb1_match_2 && !dispatch_src1_cdb0_match_2;
  wire dispatch_src2_cdb_defer_lane_2 = dispatch_src2_cdb1_match_2 && !dispatch_src2_cdb0_match_2;
  wire dispatch_src3_cdb_defer_lane_2 = dispatch_src3_cdb1_match_2 && !dispatch_src3_cdb0_match_2;

  // ===========================================================================
  // Stage 2 Pipeline Register
  // ===========================================================================
  // Issue output is registered to break the combinational path from RS
  // entry arrays (priority encoder + LUTRAM read + operand mux) to
  // downstream consumers (FU shims, LQ/SQ address computation, CDB).
  // The stage2 register holds a full copy of the issued instruction's data,
  // presented to downstream with one-shot valid when i_fu_ready is asserted.

  logic stage2_valid;
  logic [ReorderBufferTagWidth-1:0] stage2_rob_tag;
  // The issued op broadcasts into the FU shim's operation decode (measured
  // post-place: fp_rs's stage2_op -> fp_add_shim convert setup was a
  // 1131-path failing family, ~160-fanout nets).  The cap makes synthesis
  // replicate the narrow op bits per region.
  (* max_fanout = 48 *) riscv_pkg::instr_op_e stage2_op;
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

  // CDB bypass flags: set when an issued instruction's source was woken by
  // the same-cycle CDB bypass.  The output mux substitutes stage2_cdb_value
  // for these sources, which keeps the CDB value off the data path through
  // the issue-select priority encoder into the stage2 register input.
  // The select is replicated per bit.  Synthesis merges the 64 identical
  // flops back into one, and the survivor lands on the stage2 operand mux ->
  // ALU -> CDB cone with fanout >150; max_fanout makes it re-replicate so the
  // operand-mux selects stay local.
  // All six masks carry the cap: the src2_l1/src3/src3_l1 stragglers measured
  // as merged single survivors on the post-place wall (src2_l1 at -1.096).
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
  // Simulation-only legacy-value oracle for the optional INT port-0 boundary
  // move.  It tracks stage2 lifetime and records the former late-mux result
  // independently on every issue edge.
  logic primary_operand_oracle_valid_q;
  logic [FLEN-1:0] primary_src1_value_oracle_q;
  logic [FLEN-1:0] primary_src2_value_oracle_q;
`endif
`endif

  // Stage 2 control signals
  logic stage2_should_flush;  // Stage2 holds instruction younger than flush boundary
  logic stage2_accept;  // Stage2 content consumed by FU this cycle
  logic can_issue_to_stage2;  // Stage2 is empty or being consumed, so the RS may load it

  // ===========================================================================
  // Storage: FF-based control, LUTRAM-based payload
  // ===========================================================================
  //
  // Control fields (FFs): rs_valid, rs_src*_ready/tag/value, rs_use_imm,
  //   rs_rob_tag.  These need parallel CDB tag compare/write and flush scan.
  // Payload fields (LUTRAM): op, imm, rm, branch/prediction/mem/csr/pc.
  //   Written once at dispatch, read once at issue (single port each).

  // 1-bit packed vectors (for bulk operations)
  logic [DEPTH-1:0] rs_valid;
  logic [DEPTH-1:0] rs_src1_ready;
  logic [DEPTH-1:0] rs_src2_ready;
  logic [DEPTH-1:0] rs_src3_ready_q;
  logic [DEPTH-1:0] rs_src3_ready;
  logic [DEPTH-1:0] rs_use_imm;
  // DUAL_ISSUE port 1 only: the stage2b shift amount's payload inputs, kept
  // per entry so that endpoint reads flops through the one-hot select rather
  // than the payload LUTRAM behind the late selector.
  logic [DEPTH-1:0] rs_shift_uses_imm;
  logic [5:0] rs_shift_imm[DEPTH];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [6:0] dispatch_shift_controls, dispatch_shift_controls_2;  // bit 0 only
  /* verilator lint_on UNUSEDSIGNAL */
  assign dispatch_shift_controls   = riscv_pkg::projected_shift_controls(i_dispatch.op);
  assign dispatch_shift_controls_2 = riscv_pkg::projected_shift_controls(i_dispatch_2.op);
  logic [DEPTH-1:0] rs_writes_cdb_hint;
  // Branch-class pre-decode in FFs (also stored in the payload RAM): the
  // DUAL_ISSUE port-1 select must skip branch-class entries before the
  // payload read, so the class bit needs a parallel-scan copy.
  logic [DEPTH-1:0] rs_is_branch_class;

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

  // Non-FMA reservation stations do not have a third operand.  Drive src3
  // ready as a constant so synthesis can remove src3 tag/value/wakeup logic
  // from those instances.
  assign rs_src3_ready = HAS_SRC3 ? rs_src3_ready_q : {DEPTH{1'b1}};

  // Deferred dispatch-cycle CDB capture state: per-source {pend, lane} flags
  // (control side, pend reset) plus the central registered CDB lane values
  // that feed the next-cycle delivery (data side, no reset).  The pend flags
  // have the same narrow shape as the retired per-entry dispatch-CDB select
  // flags, but their only consumers are the next-cycle delivery write
  // enables.  Nothing on the issue path reads them.
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
  // The registered full/for-2 backpressure bits fan from here through the
  // dispatch stall tree into RAT/ROB/LVT/front-end write gating (int_rs's
  // was the second-largest post-place failing-path family by TNS, en-route
  // nets >1200 fanout).  The cap makes synthesis replicate the flops per
  // consumer region; the D-cone is one small count compare.
  (* max_fanout = 32 *) logic dispatch_full_q;
  (* max_fanout = 32 *) logic dispatch_full_for_2_q;

  // Free entry selection: first and second free entries, in priority order.
  // free_idx_2 only resolves when at least 2 entries are free.  The dispatch
  // gate lets slot-2 fire only when free_found_2 is set, or when slot-1 is
  // invalid and free_found is set, in which case slot-2 takes free_idx.
  logic [$clog2(DEPTH)-1:0] free_idx;
  logic free_found;
  logic [$clog2(DEPTH)-1:0] free_idx_2;
  logic free_found_2;
  // Effective slot-2 alloc index: free_idx_2 when slot-1 is also firing
  // (consumes free_idx), else free_idx.
  logic [$clog2(DEPTH)-1:0] alloc_idx_2;
  logic data_write_1_en;
  logic data_write_2_en;

  // One-cycle allocation tokens for ALLOC_INDEXED_REPAIR.  These identify
  // the exact resident entry owned by each dispatch slot's registered ROB
  // lookup response; no source-tag CAM is needed on the return cycle.
  logic [DEPTH-1:0] repair_slot1_target_q;
  logic [DEPTH-1:0] repair_slot2_target_q;
  logic [DEPTH-1:0] indexed_src1_repair;
  logic [DEPTH-1:0] indexed_src2_repair;
  logic [DEPTH-1:0] indexed_src3_repair;

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
  // Second issue port (DUAL_ISSUE). Declared unconditionally so the shared
  // count/valid bookkeeping can reference them; driven inside the generate
  // block below and tied off when DUAL_ISSUE is disabled.
  logic [$clog2(DEPTH)-1:0] issue_idx_2;
  logic [DEPTH-1:0] issue_sel_2;
  logic any_ready_2;
  logic issue_fire_2;
  logic stage2b_valid;
  logic stage2b_head_query_match;
  logic [(2**$clog2(DEPTH))-1:0] issue_sel_2_ohread;

  // Dispatch condition
  (* max_fanout = 32 *) logic dispatch_fire;
  // Slot-2 dispatch fire condition.  Slot-2 needs room for itself, considering
  // whether slot-1 is also consuming a slot this cycle.
  (* max_fanout = 32 *) logic dispatch_fire_2;

  // ===========================================================================
  // Payload LUTRAM: dispatch-only fields, read at issue
  // ===========================================================================
  // Written once per entry at dispatch (free_idx / alloc_idx_2) and read once
  // per issue port (issue_idx here; DUAL_ISSUE reads a second replicated copy
  // at issue_idx_2), so they live in distributed RAM rather than flip-flops.
  // Valid bits in FFs gate all reads, so stale payload data behind an invalid
  // entry is harmless.

  localparam int unsigned PayloadWidth =
      riscv_pkg::InstrOpWidth + XLEN + 12 + 3 + 1 + 1 + 1 + 1 + 1 + 1 + 2 + 1 + 12 +
      5 + 1 + CheckpointIdWidth + 1 + 1 + 1 + 1 + 1 + 3;

  // Dispatch-time branch-class pre-decode. Stored in the payload RAM so the
  // instr_op_e decode happens once at dispatch instead of in the
  // issue/branch-resolution cycle (see rs_issue_t.is_branch_class).
  // The riscv_pkg classification helpers are `ifndef SYNTHESIS because Yosys
  // cannot resolve enum values inside package functions, so the equivalent
  // logic is inlined here with fully-qualified enum references, as the
  // package convention requires. The sets mirror
  // riscv_pkg::is_branch_or_jump_op / is_jal_op / is_jalr_op and the
  // branch_taken_op_e case formerly inlined in branch_resolution.
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

  // 2-write port: slot-1 dispatch (port 0) + slot-2 dispatch (port 1).
  // Port 1 writes whenever slot-2 dispatches into this RS, with or without
  // slot-1 firing in the same cycle.
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
  // Keep occupancy registered so dispatch back-pressure does not depend on a
  // live popcount of all rs_valid bits. Flushes still recompute the exact
  // post-flush count because they may invalidate multiple arbitrary entries.
  //
  // Late-side factoring: dispatch_fire/dispatch_fire_2 arrive through the
  // whole id_valid → dispatch → RS-router cone, long after issue_fire (ready
  // regs) and count (a FF). Precompute the three possible next counts off
  // the early side and let the late dispatch pulses only steer a final
  // select. This is bit-identical to the flat add chain; only the small
  // modular adds are re-associated.
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
      // Net occupancy delta: +1 per dispatch (0/1/2 of slot-1/slot-2 firing)
      // and -1 per issue port that fires (0/1/2 of port-0/port-1).
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

  // Same trick for the registered full flags (DISPATCH_STATUS_RESERVE == 0
  // form): the ==DEPTH / >=DEPTH-1 compares are precomputed per possible
  // dispatch outcome off the early count_after_issue, then selected by the
  // late dispatch pulses. Flush cycles fall back to the popcount-based
  // count_next (early inputs; the flush selects come from controller FFs).
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

  // Effective slot-2 alloc target: skip slot-1's pick when slot-1 also fires.
  // The select uses the fast i_intent_1 (slot-1 wants this RS) rather than
  // the slow dispatch_fire, which keeps the rs_valid commit cone and the
  // LUTRAM write-address cone off the bundle_fire_ok / cross-RS-full chain.
  // Whenever the strict slot-2 commit dispatch_fire_2 fires, the bundle is
  // atomic and i_intent_1 == dispatch_fire by construction, so the chosen
  // entry index is identical to the original mux's choice.  Free indices are
  // computed combinationally from rs_valid (registered) and so are also fast.
  assign alloc_idx_2 = i_intent_1 ? free_idx_2 : free_idx;

  // --- Dispatch fire conditions ---
  // Flush priority is handled in the sequential control block below.  Leave
  // full/partial flush pulses out of the data/payload write-enable cone; any
  // writes that coincide with a flush land in entries whose valid bits/count
  // are being cleared or selectively recomputed on that same edge.
  assign dispatch_fire = TRUST_DISPATCH_VALID ? dispatch_valid : (dispatch_valid && !full);
  // Slot-2 fires when there is room for it given whether slot-1 also fires.
  // Reduces to: (slot-1 firing → !full_for_2) OR (slot-1 not firing → !full).
  assign dispatch_fire_2 = TRUST_DISPATCH_VALID ?
                           dispatch_valid_2 :
                           (dispatch_valid_2 && (dispatch_fire ? !full_for_2 : !full));

`ifndef SYNTHESIS
  // TRUST_DISPATCH_VALID removes the local !full/!full_for_2 re-checks from
  // the fire terms, so the dispatcher's per-RS valid bits must already embed
  // the exact room checks (dispatch.sv gates slot-1 valid on !i_*_rs_full and
  // slot-2 valid on bundle_fire_ok, whose rs_full_for_slot2 mux picks
  // full_for_2 when both slots target this RS and plain full otherwise).
  // Pin bit-exact equivalence with the untrusted computation so any contract
  // break fails loudly in simulation instead of corrupting a live entry.
  // Edge-sampled: every dispatch_fire consumer (count/full updates, rs_valid
  // commits, payload CEs) is clocked, so the contract binds at the capture
  // edge only.  Benches may deassert a refused valid between edges, which a
  // combinational check would flag as a harmless mid-cycle transient.
  // A full flush is exempt: the station documents that a stale dispatch packet
  // may ride one (the flush branch wins in the valid array and the count), so
  // on that edge the trusted and untrusted fire terms are allowed to disagree
  // on a result nothing keeps.
  always_ff @(posedge i_clk) begin
    if (TRUST_DISPATCH_VALID && i_rst_n && !i_flush_all && !$isunknown(
            {dispatch_valid, dispatch_valid_2, full, full_for_2}
        )) begin
      p_trusted_dispatch_fire_exact : assert (dispatch_fire == (dispatch_valid && !full));
      p_trusted_dispatch_fire_2_exact :
      assert (dispatch_fire_2 ==
              (dispatch_valid_2 && ((dispatch_valid && !full) ? !full_for_2 : !full)));
    end
    // The exported status flags the dispatcher consults must be conservative
    // w.r.t. live occupancy, or a trusted valid could arrive while full.
    // DISPATCH_STATUS_RESERVE==1 would break this, and the tripwire fires if
    // trust is ever paired with such a config.
    if (TRUST_DISPATCH_VALID && i_rst_n && !$isunknown(
            {full, full_for_2, dispatch_full_q, dispatch_full_for_2_q}
        )) begin
      p_trusted_status_conservative : assert (!full || dispatch_full_q);
      p_trusted_status_for_2_conservative : assert (!full_for_2 || dispatch_full_for_2_q);
    end
  end
`endif

  // MEM_RS source-value flops otherwise inherit the full dispatch backpressure
  // cone as a clock-enable.  When enabled, write invalid/free entries even if
  // dispatch is blocked; rs_valid remains the architectural commit point.
  // For SPECULATIVE_DATA_WRITES the slot-2 enable also avoids dispatch_fire
  // (slow) and uses i_intent_1 (fast) to pick between !full / !full_for_2.
  assign data_write_1_en = SPECULATIVE_DATA_WRITES ? !full : dispatch_fire;
  assign data_write_2_en = SPECULATIVE_DATA_WRITES ?
                           (i_intent_1 ? !full_for_2 : !full) : dispatch_fire_2;

  // --- One-hot slot-2 allocation select for the broadcast value writes ---
  // TIMING: with BROADCAST_FREE_SOURCE_VALUES every free entry's
  // rs_src*_value D mux picks slot 2's values iff
  // data_write_2_en && alloc_idx_2 == i.  Decoding the binary index there put
  // the whole free_idx/free_idx_2 sweep (a ripple through rs_valid, six LUT
  // levels at DEPTH=16) plus a decoder in front of the 64-bit value muxes;
  // rs_valid_reg -> rs_src1_value_reg was the INT RS 322 MHz post-opt
  // limiter.  alloc_sel_2 is that predicate computed directly from rs_valid
  // at fixed depth: entry i is slot 2's target iff it is free and, counting
  // free entries below it, there is exactly one (i_intent_1: slot 1 consumes
  // the lowest) or none (slot 2 alone takes the lowest).  rs_valid is split
  // into nibbles, so the cone is one LUT of nibble free-counts, one LUT of
  // prefix-over-nibbles and one LUT per entry, for any DEPTH up to 32.
  // Bit-exact with the indexed form including its not-found fallbacks:
  // free_idx_2 is 0 when fewer than two entries are free, so under
  // i_intent_1 entry 0 is slot 2's target iff it is the only free entry,
  // and free_idx is 0 when nothing is free, which the !rs_valid[0] term
  // already excludes. The binary indices for payload/tag/control writes are
  // encoded from these same masks, avoiding a separate serial search. Keep
  // the nibble boundaries so sharing with downstream index decoders cannot
  // reconstruct that search on the wide value selects.
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

  // Constant-folded loop masks: every index below is a literal after
  // unrolling, so each masked reduction is one flat AND, not a chain.
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
  // Same-cycle CDB tag match: if the CDB is broadcasting a result this cycle
  // and an entry's pending source tag matches, treat that source as ready
  // combinationally instead of waiting for the registered wakeup on the next
  // edge.  This saves one cycle on dependent chains.
  logic [DEPTH-1:0] src1_cdb_bypass;
  logic [DEPTH-1:0] src2_cdb_bypass;
  logic [DEPTH-1:0] src3_cdb_bypass;
  // Lane-1 (i_cdb_2) same-cycle bypass masks (LANE1_ISSUE_BYPASS).  A tag
  // broadcasts on exactly one lane per cycle, so the lane-0 and lane-1
  // masks are mutually exclusive per source.
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

  // The !src*_cdb_pend terms close a one-cycle tag-reuse (ABA) hole: during
  // a deferred dispatch-CDB delivery cycle the source still reads not-ready,
  // and a hypothetical rebroadcast of the same tag by a recycled producer
  // must not issue-bypass a foreign value into the entry.  Unreachable by
  // pipeline depth today (tag reuse needs a retire + full ROB wrap + a
  // dispatch-to-broadcast latency, all inside the 1-cycle pend window), but
  // the registered pend flag makes it structural.
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

  // --- Ready check per entry ---
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      entry_ready[i] = rs_valid[i] &&
          (rs_src1_ready[i] || src1_cdb_bypass[i] || src1_cdb_bypass_l1[i] ||
           (src1_repair_sel[i] != 3'd0))
      // Even when an instruction uses an immediate, issue still
      // requires src2 to be ready if the opcode has a second
      // source (for example stores: base+imm address and rs2
      // store data). Dispatch marks unused src2 operands ready,
      // so a plain src2_ready check suffices.
      && (rs_src2_ready[i] || src2_cdb_bypass[i] || src2_cdb_bypass_l1[i] ||
          (src2_repair_sel[i] != 3'd0)) &&
          (rs_src3_ready[i] || src3_cdb_bypass[i] || src3_cdb_bypass_l1[i] ||
           (src3_repair_sel[i] != 3'd0));
    end
  end

  // --- Issue selection (priority encoder: lowest ready index) ---
  always_comb begin
    issue_idx = '0;
    any_ready = 1'b0;
    for (int i = 0; i < DEPTH; i++) begin
      if (entry_ready[i] && !any_ready) begin
        issue_idx = $clog2(DEPTH)'(i);
        any_ready = 1'b1;
      end
    end
  end

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
  // Flush squash: stage2 holds an instruction younger than the flush boundary.
  assign stage2_should_flush = stage2_valid && (i_flush_all || (i_flush_en && should_flush_entry(
      stage2_rob_tag, i_flush_tag, i_rob_head_tag
  )));

  // Stage2 content consumed by downstream FU this cycle (one-shot pulse).
  assign stage2_accept = stage2_valid && i_fu_ready && !stage2_should_flush;

  // RS may load stage2 when it is empty or being consumed this cycle.
  assign can_issue_to_stage2 = !stage2_valid || stage2_accept;

  // Issue from RS entry arrays into stage2. i_fu_ready is retained so that
  // entries only move to stage2 when the FU can accept, which preserves the
  // count/full/empty semantics of the old combinational design. The timing
  // benefit comes from registering the data path in stage2, not from
  // decoupling the control path.
  // A partial/full flush invalidates younger entries on the clock edge, but the
  // ready scan above still sees pre-flush state combinationally in the same
  // cycle. Suppress issue so wrong-path ops cannot leak into stage2 during the
  // misprediction/trap flush cycle.
  assign issue_fire = any_ready && i_fu_ready && can_issue_to_stage2 && !i_flush_all && !i_flush_en;

  // The branch-resolution tag predicates and the architectural issue/ROB tag
  // have very different placement neighborhoods.  The INT instance therefore
  // gives the predicate cone its own five same-edge FFs.  The protected twin
  // has no max_fanout constraint because its only consumers are the
  // checkpoint-owner comparisons and head-relative age calculation.
  generate
    if (BRANCH_PREDICATE_TAG_ANCHOR) begin : gen_branch_predicate_tag_anchor
      (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
      logic [ReorderBufferTagWidth-1:0] stage2_branch_predicate_tag;

      always_ff @(posedge i_clk) begin
        // stage2_rob_tag is held by the enclosing reset branch, so include
        // i_rst_n here to preserve its exact effective clock enable.
        if (i_rst_n && issue_fire) stage2_branch_predicate_tag <= rs_rob_tag[issue_idx];
      end

      assign o_branch_predicate_tag = stage2_branch_predicate_tag;

`ifndef SYNTHESIS
`ifndef FORMAL
      // Both banks have identical D/enable/hold behavior.  stage2_valid gates
      // the comparison because neither payload tag needs reset initialization.
      always_ff @(posedge i_clk) begin
        if (i_rst_n && stage2_valid) begin
          assert (stage2_branch_predicate_tag == stage2_rob_tag)
          else $error("reservation_station: branch predicate tag lost phase identity");
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
  // Port-0 consumers of these three XLEN words are early recovery's
  // redirect/BTB image capture registers and branch resolution's JALR target
  // compare behind its adder (JALR's link result rides imm, so no CDB
  // completion path starts here), so they need not ride the per-entry
  // payload RAM behind the issue-index select.  Both dispatch
  // slots write them at their ROB tag; port 0 reads the row of its stage2 tag
  // through a protected same-edge twin (the predicate-anchor pattern), which
  // leaves the architectural tag's fanout unchanged.  A row is read only
  // through a valid stage2 packet whose own dispatch wrote it, and its tag
  // cannot be reallocated while that packet is live (commit needs completion;
  // a flush clears stage2_valid on the same edge), so stale rows are never
  // observed.  The other stations, and port 1, never consume these fields.
  generate
    if (TAG_INDEXED_BRANCH_PAYLOAD) begin : gen_tag_indexed_branch_payload
      localparam int unsigned BranchPayloadWidth = 3 * XLEN;

      (* keep = "true", dont_touch = "true", equivalent_register_removal = "no" *)
      logic [ReorderBufferTagWidth-1:0] stage2_branch_payload_tag;

      always_ff @(posedge i_clk) begin
        // Same effective enable as stage2_rob_tag (see the predicate anchor).
        if (i_rst_n && issue_fire) stage2_branch_payload_tag <= rs_rob_tag[issue_idx];
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
      // Row ownership.  Rows are keyed by ROB tag, so the core relies on ROB
      // allocation never handing out a tag that is still live here (a valid
      // resident entry or the stage2 packet).  Formal runs assume exactly that.
      // Simulation checks the property the RAM needs, which also tolerates
      // benches that hold a dispatch packet valid for more than one cycle: a
      // live row is never rewritten with different contents, and two slots
      // naming one tag carry the same contents.  Flush cycles are exempt (the
      // core never dispatches into a flush; the killed entries leave on that
      // edge).
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
      // Row ownership as a formal property.  The standalone top has no
      // allocator to derive it from, so it assumes it; the wrapper proof
      // (FORMAL_STANDALONE_ENV=0) contains the real ROB and asserts exactly
      // the same three conjuncts instead.
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
        // i_rst_n qualifies the live scan the same way the station's other
        // state properties do: rs_valid and stage2_valid are reset-cleared, so
        // only their post-reset contents mean anything.
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
          else $error("reservation_station: branch payload tag lost phase identity");
        end
      end

      // Row-identity oracle: every packet also carries its own three words
      // beside it in simulation (per entry at dispatch, then through stage2),
      // and the RAM read behind the stage2 tag must reproduce exactly them.
      // This is the direct check that a stage2 packet never sees another
      // instruction's row, in every bench and every system simulation.
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

  // --- Width-funnel perf observer (profiling only) ---
  // The stage-1 issue port fired while >=2 entries were ready: the single
  // issue port, not operand readiness, limited throughput this cycle.
  // x & (x-1) clears the lowest set bit, so it is nonzero iff popcount >= 2.
  // Registered so the tap adds no load to the issue-select cone.
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

  // Pre-issue look-ahead: expose the selected entry's rob_tag and
  // mem_needs_lq during the cycle it fires into stage2 (T-1), so the LQ
  // can register a CAM pre-match and avoid a 5-level combinational chain
  // at issue time (T).
  if (PREISSUE_VALID_COFACTOR) begin : gen_preissue_cofactor
    // The early-wakeup eligibility reaches the valid bits later than tags.
    // Build the four exact ready/priority/tag outcomes independently and use
    // those two bits only for the final narrow tag selection.
    (* keep = "true" *) logic [ReorderBufferTagWidth-1:0] candidate_tag[4];
    for (genvar valids = 0; valids < 4; valids++) begin : gen_candidate
      logic [DEPTH-1:0] ready;
      logic [$clog2(DEPTH)-1:0] index;
      logic found;
      always_comb begin
        for (int entry = 0; entry < DEPTH; entry++) begin
          ready[entry] = rs_valid[entry] &&
              (rs_src1_ready[entry] || (src1_repair_sel[entry] != 3'd0) ||
               (((valids & 1) != 0) && !rs_src1_ready[entry] && !src1_cdb_pend[entry] &&
                (ISSUE_CDB_TAG_SHADOW ? rs_src1_issue_tag[entry] : rs_src1_tag[entry]) ==
                    issue_cdb_tag) ||
               (LANE1_ISSUE_BYPASS && ((valids & 2) != 0) &&
                !rs_src1_ready[entry] && !src1_cdb_pend[entry] &&
                (ISSUE_CDB_TAG_SHADOW ? rs_src1_issue_tag[entry] : rs_src1_tag[entry]) ==
                    issue_cdb_2_tag)) &&
              (rs_src2_ready[entry] || (src2_repair_sel[entry] != 3'd0) ||
               (((valids & 1) != 0) && !rs_src2_ready[entry] && !src2_cdb_pend[entry] &&
                (ISSUE_CDB_TAG_SHADOW ? rs_src2_issue_tag[entry] : rs_src2_tag[entry]) ==
                    issue_cdb_tag) ||
               (LANE1_ISSUE_BYPASS && ((valids & 2) != 0) &&
                !rs_src2_ready[entry] && !src2_cdb_pend[entry] &&
                (ISSUE_CDB_TAG_SHADOW ? rs_src2_issue_tag[entry] : rs_src2_tag[entry]) ==
                    issue_cdb_2_tag)) &&
              (rs_src3_ready[entry] || (src3_repair_sel[entry] != 3'd0) ||
               (HAS_SRC3 && ((valids & 1) != 0) && !rs_src3_ready[entry] && !src3_cdb_pend[entry] &&
                rs_src3_tag[entry] == issue_cdb_tag) ||
               (HAS_SRC3 && LANE1_ISSUE_BYPASS && ((valids & 2) != 0) &&
                !rs_src3_ready[entry] && !src3_cdb_pend[entry] &&
                rs_src3_tag[entry] == issue_cdb_2_tag));
        end
        index = '0;
        found = 1'b0;
        for (int entry = 0; entry < DEPTH; entry++) begin
          if (ready[entry] && !found) begin
            index = $clog2(DEPTH)'(entry);
            found = 1'b1;
          end
        end
        candidate_tag[valids] = rs_rob_tag[index];
      end
      assign o_pre_issue_rob_tags[valids*ReorderBufferTagWidth +: ReorderBufferTagWidth] =
          candidate_tag[valids];
    end
    assign o_pre_issue_sel = {issue_cdb_2_valid, issue_cdb_valid};
    assign o_pre_issue_rob_tag = issue_cdb_2_valid ?
        (issue_cdb_valid ? candidate_tag[3] : candidate_tag[2]) :
        (issue_cdb_valid ? candidate_tag[1] : candidate_tag[0]);
  end else begin : gen_preissue_direct
    assign o_pre_issue_rob_tag = rs_rob_tag[issue_idx];
    assign o_pre_issue_rob_tags = {4{o_pre_issue_rob_tag}};
    assign o_pre_issue_sel = '0;
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

  // --- Issue port assignment (driven from stage2 pipeline register) ---
  // Data fields are driven unconditionally from stage2 FFs.
  // Valid depends only on registered stage2_valid and the FU ready signal
  // (itself derived from registered adapter/shim state).  The same-cycle
  // flush is not checked here: checking stage2_should_flush on the output
  // recreates the critical timing path
  //   trap_taken → flush → stage2_should_flush → o_issue.valid → downstream
  // which was the longest combinational chain in the design (-1.28 ns WNS).
  // A "phantom issue" can escape during a flush cycle, but it is harmless:
  //   - Full flush (flush_all): LQ/SQ reset all state, ignoring the update.
  //   - Partial flush (flush_en): LQ/SQ CAM-match on rob_tag; the flushed
  //     entry's valid bit is cleared on the same edge, so the address update
  //     writes into a dead entry that is never observed.
  //   - CDB results for flushed tags are discarded by the ROB/RS flush logic.
  //   - The translation stage (dmmu) registers memory ops instead of
  //     delivering them on the issue edge, so it drops a phantom by the
  //     flush-age rule itself (its iss_killed); without that, the op's late
  //     fault or address landed on the correct-path op that reused the tag.
  // The internal stage2_accept signal still checks stage2_should_flush so
  // that the stage2 pipeline register is cleared on the next edge.
  assign o_issue.valid = stage2_valid && i_fu_ready;
  assign o_issue.rob_tag = stage2_rob_tag;
  assign o_issue.op = stage2_op;
  // INT port 0 captures its effective src1/src2 operands on the issue edge,
  // so its ALU/CDB launch is direct from stage2 Q.  Every default-mode RS
  // retains the legacy post-Q three-arm bypass expressions byte-for-byte.
  generate
    if (CAPTURE_PRIMARY_EFFECTIVE_OPERANDS) begin : gen_primary_effective_operand_outputs
      assign o_issue.src1_value = stage2_src1_value;
      assign o_issue.src2_value = stage2_src2_value;
    end else begin : gen_primary_legacy_operand_outputs
      // For CDB-bypassed sources, substitute the CDB value captured at issue
      // time. Replicate the bypass control per bit so one scalar flag does not
      // drive the full FLEN-wide operand mux into the FU/CDB path. Keep the final
      // expressions direct on the issue ports: named keep/max_fanout effective
      // vectors were measured at 15 to 22 levels and -0.455 ns post-opt across
      // the replicated CDB value endpoints.
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
  // (generate block below), not from the payload RAM or stage2.
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
      // The helper computes only port 1. Port 0 keeps the serial issue_idx /
      // any_ready encoder above, and none of its consumers depend on this
      // tree. The helper tracks the global first ready entry inside its own
      // tree, so its result stays the exact legacy "lowest ready nonbranch
      // excluding port 0's winner" under backpressure.
      // With a window, the selector's own first-ready exclusion still equals
      // port 0's winner whenever the window holds a ready entry (port 0 picks
      // the lowest ready index overall), and port 1 is idle otherwise.
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

      // Second payload-RAM copy: identical writes, read at issue_idx_2
      // (LUTRAM replication, the same pattern as the duplicated SQ data RAMs).
      // Port 1 already computes a one-hot select. Feed that to the LVT read
      // side so the bank-select lookup does not add another binary-address mux
      // behind the issue2 priority encoder.
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

      // stage2b pipeline register bank. Unlike port 0, its operand FFs capture
      // the issue-time CDB-selected values directly; there is no operand mux
      // after these registers.
      logic [ReorderBufferTagWidth-1:0] stage2b_rob_tag;
      // Port-1 twin of stage2_op's cap (see that declaration).
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
      // Simulation-only legacy-value oracle. It follows the stage2b valid
      // lifetime and independently records the old late-mux result on each
      // issue edge, so the register-boundary move remains checked across
      // stalls, flushes, and back-to-back refill.
      logic stage2b_operand_oracle_valid_q;
      logic [FLEN-1:0] stage2b_src1_value_oracle_q;
      logic [FLEN-1:0] stage2b_src2_value_oracle_q;
      logic [FLEN-1:0] stage2b_src3_value_oracle_q;
`endif
`endif

      // TIMING: each entry's operand is resolved (live CDB lane over the
      // resident or done-repair value) before the one-hot issue select, so
      // the late selector drives only the final AND-OR. The *_selected
      // bypass bits below remain for the simulation oracle. At most one live
      // lane matches a source, so the per-entry priority is immaterial.
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

      // One expression feeds both the existing wide operand FFs and the six
      // amount FFs. Live CDB selection and the capture/hold lifetime are exact.

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
          // Fold the live CDB selection into the existing operand FF D inputs.
          // These are the exact former post-Q bypass-mask expressions moved to
          // the capture edge. The CDB lanes carry distinct tags, so at most one
          // live term is selected; either live lane overrides the resident /
          // done-repair-selected value.
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
            else $error("RS: issue-2 src1 effective capture differs from legacy bypass");
            assert (stage2b_src2_value == stage2b_src2_value_oracle_q)
            else $error("RS: issue-2 src2 effective capture differs from legacy bypass");
            if (HAS_SRC3) begin
              assert (stage2b_src3_value == stage2b_src3_value_oracle_q)
              else $error("RS: issue-2 src3 effective capture differs from legacy bypass");
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

      // o_issue_2 assembly (mirror of o_issue, with the same phantom-issue-
      // on-flush reasoning: a flushed tag's CDB result is discarded by ROB/RS).
      assign o_issue_2.valid = stage2b_valid && i_fu_ready_2;
      assign o_issue_2.rob_tag = stage2b_rob_tag;
      assign o_issue_2.op = stage2b_op;
      // The effective operands were selected on the issue edge. Keep the
      // timing-critical ALU2/SQ/CDB launch path as direct stage2b register Q.
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

  // Dispatch and the ROB done/value query launch together.  Remember the
  // exact local allocation for one cycle so the returning response can write
  // that entry directly.  A flush wins over dispatch in the architectural
  // valid array, so it must also discard these otherwise-stale targets.
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
        // Partial flush: invalidate entries younger than flush_tag.
        // The old head==flush_tag+1 full-clear is now handled by
        // speculative_flush_all (passed as i_flush_all) from the wrapper.
        for (int i = 0; i < DEPTH; i++) begin
          if (rs_valid[i] && should_flush_entry(rs_rob_tag[i], i_flush_tag, i_rob_head_tag)) begin
            rs_valid[i] <= 1'b0;
          end
        end
      end else begin
        if (issue_fire) rs_valid[issue_idx] <= 1'b0;
        if (issue_fire_2) rs_valid[issue_idx_2] <= 1'b0;

        if (dispatch_fire) begin
          rs_valid[free_idx] <= 1'b1;
          if (TRACK_INT_WRITEBACK_HINT)
            rs_writes_cdb_hint[free_idx] <= int_rs_writes_cdb(dispatch_op);

          // Source ready bits: dispatch-time ready, plus the insertion-time
          // done-repair bypass where enabled.  The timing-critical immediate
          // stations use the indexed post-insertion response below instead.
          // A same-cycle CDB match does not fold in here: it registers a
          // pend flag and the deferred delivery sets ready one cycle later.
          rs_src1_ready[free_idx] <= dispatch_src1_ready || dispatch_src1_repair_match;
          rs_src2_ready[free_idx] <= dispatch_src2_ready || dispatch_src2_repair_match;
          if (HAS_SRC3) begin
            rs_src3_ready_q[free_idx] <= dispatch_src3_ready || dispatch_src3_repair_match;
          end
          rs_use_imm[free_idx] <= dispatch_use_imm;
          rs_shift_uses_imm[free_idx] <= dispatch_shift_controls[0];
          rs_shift_imm[free_idx] <= dispatch_imm[5:0];
          // Deferred dispatch-CDB capture flags.  Written on every committed
          // dispatch (0 when no match) so a re-allocation of this index can
          // never inherit a stale pend.
          src1_cdb_pend[free_idx] <= dispatch_src1_cdb_defer;
          src1_cdb_pend_lane[free_idx] <= dispatch_src1_cdb_defer_lane;
          src2_cdb_pend[free_idx] <= dispatch_src2_cdb_defer;
          src2_cdb_pend_lane[free_idx] <= dispatch_src2_cdb_defer_lane;
          if (HAS_SRC3) begin
            src3_cdb_pend[free_idx] <= dispatch_src3_cdb_defer;
            src3_cdb_pend_lane[free_idx] <= dispatch_src3_cdb_defer_lane;
          end
        end

        // Slot-2 dispatch write (independent index from slot-1, so the
        // non-blocking writes never collide on a bit).  Fires when slot-2
        // dispatches into this RS.
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

      // CDB and done-repair wakeup (control: ready bits only).
      // i_cdb_2 is the 2-wide CDB lane-1 (registered wakeup; distinct tag).
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

      // Deferred dispatch-CDB delivery (control side): one cycle after a
      // dispatch-cycle CDB match, set the source ready and retire the pend
      // flag.  Runs unconditionally: a flush arriving in the delivery cycle
      // clears rs_valid on this same edge, making these writes dead state,
      // and the pend clear keeps stale flags out of future re-allocations.
      // The pended entry is necessarily still resident here (its source
      // reads not-ready this cycle, so it cannot have issued), so these
      // indices can never collide with this cycle's dispatch writes above.
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

  // --- Data signals (no reset) ---
  always_ff @(posedge i_clk) begin
    // Keep a physically distinct issue-only tag bank without adding loads to
    // the free-entry/rs_valid clock-enable cone.  These use the same indexed
    // speculative writes as the architectural tags below.  On a speculative
    // write for a slot that does not target this RS, complement the shadow D
    // value so the two banks are not equivalent while invalid.  A committed
    // slot always selects the normal tag.  Slot 2 comes last: for slot-2-only
    // dispatch alloc_idx_2 == free_idx, so its normal tag replaces slot 1's
    // complemented speculative value before the entry becomes valid.
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

    // In broadcast mode, the wide source-value arrays use only the entry's
    // local valid bit as their dispatch write enable.  Every free entry gets
    // slot 1's values; the exact slot-2 target gets slot 2's values instead.
    // The selected allocation indices below still receive their tags and
    // narrow dispatch-bypass flags normally.  Since rs_valid is the sole
    // architectural commit, values written to the other free entries are
    // don't-care prefill and cannot be observed by issue.  alloc_sel_2[i] is
    // data_write_2_en && alloc_idx_2 == i for every free entry, computed at
    // fixed depth from rs_valid (see its TIMING note); the value D select
    // must not see the binary index decode.
    if (BROADCAST_FREE_SOURCE_VALUES) begin
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

    // Dispatch: capture tags and values at free index
    if (data_write_1_en) begin
      rs_rob_tag[free_idx] <= dispatch_rob_tag;
      rs_is_branch_class[free_idx] <= dispatch_is_branch_class;

      // Source 1
      rs_src1_tag[free_idx] <= dispatch_src1_tag;
      if (!BROADCAST_FREE_SOURCE_VALUES) rs_src1_value[free_idx] <= dispatch_src1_stored_value;

      // Source 2
      rs_src2_tag[free_idx] <= dispatch_src2_tag;
      if (!BROADCAST_FREE_SOURCE_VALUES) rs_src2_value[free_idx] <= dispatch_src2_stored_value;

      // Source 3 (FMA only)
      if (HAS_SRC3) begin
        rs_src3_tag[free_idx] <= dispatch_src3_tag;
        if (!BROADCAST_FREE_SOURCE_VALUES) rs_src3_value[free_idx] <= dispatch_src3_stored_value;
      end
    end

    // Slot-2 dispatch: capture tags and values at alloc_idx_2.  Intra-bundle
    // RAW (slot-2 src reads slot-1 dest) is resolved upstream in dispatch.sv
    // before reaching the RS.
    if (data_write_2_en) begin
      rs_rob_tag[alloc_idx_2] <= dispatch_rob_tag_2;
      rs_is_branch_class[alloc_idx_2] <= dispatch_is_branch_class_2;

      rs_src1_tag[alloc_idx_2] <= dispatch_src1_tag_2;
      if (!BROADCAST_FREE_SOURCE_VALUES) rs_src1_value[alloc_idx_2] <= dispatch_src1_stored_value_2;

      rs_src2_tag[alloc_idx_2] <= dispatch_src2_tag_2;
      if (!BROADCAST_FREE_SOURCE_VALUES) rs_src2_value[alloc_idx_2] <= dispatch_src2_stored_value_2;

      if (HAS_SRC3) begin
        rs_src3_tag[alloc_idx_2] <= dispatch_src3_tag_2;
        if (!BROADCAST_FREE_SOURCE_VALUES)
          rs_src3_value[alloc_idx_2] <= dispatch_src3_stored_value_2;
      end
    end

    // CDB and done-repair wakeup (data: capture values).
    // i_cdb_2 = 2-wide CDB lane-1 (registered; distinct tag from lane 0).
    if (i_cdb.valid || i_cdb_2.valid || i_repair_valid_1 || i_repair_valid_2 ||
        i_repair_valid_3 || i_repair_valid_4 || i_repair_valid_5 || i_repair_valid_6) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (rs_valid[i]) begin
          if (!rs_src1_ready[i] && i_cdb.valid && rs_src1_tag[i] == i_cdb.tag) begin
            rs_src1_value[i] <= i_cdb.value;
          end else if (!rs_src1_ready[i] && i_cdb_2.valid && rs_src1_tag[i] == i_cdb_2.tag) begin
            rs_src1_value[i] <= i_cdb_2.value;
          end else if (!rs_src1_ready[i] && ALLOC_INDEXED_REPAIR &&
                       repair_slot1_target_q[i] && i_repair_valid_1) begin
            rs_src1_value[i] <= i_repair_value_1;
          end else if (!rs_src1_ready[i] && ALLOC_INDEXED_REPAIR &&
                       repair_slot2_target_q[i] && i_repair_valid_4) begin
            rs_src1_value[i] <= i_repair_value_4;
          end else if (!rs_src1_ready[i] && done_repair_match(rs_src1_tag[i])) begin
            rs_src1_value[i] <= done_repair_value(rs_src1_tag[i]);
          end

          if (!rs_src2_ready[i] && i_cdb.valid && rs_src2_tag[i] == i_cdb.tag) begin
            rs_src2_value[i] <= i_cdb.value;
          end else if (!rs_src2_ready[i] && i_cdb_2.valid && rs_src2_tag[i] == i_cdb_2.tag) begin
            rs_src2_value[i] <= i_cdb_2.value;
          end else if (!rs_src2_ready[i] && ALLOC_INDEXED_REPAIR &&
                       repair_slot1_target_q[i] && i_repair_valid_2) begin
            rs_src2_value[i] <= i_repair_value_2;
          end else if (!rs_src2_ready[i] && ALLOC_INDEXED_REPAIR &&
                       repair_slot2_target_q[i] && i_repair_valid_5) begin
            rs_src2_value[i] <= i_repair_value_5;
          end else if (!rs_src2_ready[i] && done_repair_match(rs_src2_tag[i])) begin
            rs_src2_value[i] <= done_repair_value(rs_src2_tag[i]);
          end

          if (HAS_SRC3 && !rs_src3_ready[i] && i_cdb.valid && rs_src3_tag[i] == i_cdb.tag) begin
            rs_src3_value[i] <= i_cdb.value;
          end else if (HAS_SRC3 && !rs_src3_ready[i] && i_cdb_2.valid &&
                       rs_src3_tag[i] == i_cdb_2.tag) begin
            rs_src3_value[i] <= i_cdb_2.value;
          end else if (HAS_SRC3 && !rs_src3_ready[i] && ALLOC_INDEXED_REPAIR &&
                       repair_slot1_target_q[i] && i_repair_valid_3) begin
            rs_src3_value[i] <= i_repair_value_3;
          end else if (HAS_SRC3 && !rs_src3_ready[i] && ALLOC_INDEXED_REPAIR &&
                       repair_slot2_target_q[i] && i_repair_valid_6) begin
            rs_src3_value[i] <= i_repair_value_6;
          end else if (HAS_SRC3 && !rs_src3_ready[i] && done_repair_match(rs_src3_tag[i])) begin
            rs_src3_value[i] <= done_repair_value(rs_src3_tag[i]);
          end
        end
      end
    end

    // Central CDB lane value copies for the deferred dispatch-CDB delivery.
    // Captured every cycle; qualified only by the pend flags below, so the
    // dispatch side of the value arrays never sees the live CDB value nets.
    cdb0_value_q <= i_cdb.value;
    cdb1_value_q <= i_cdb_2.value;

    // Deferred dispatch-CDB delivery (data side): deliver the value the
    // dispatch cycle matched, from the lane copies registered on that edge
    // (non-blocking reads above see the previous-cycle capture).  Placed
    // last in this block: if a done-repair response for the same source
    // lands on this same edge (the ROB query saw the completing producer),
    // both writes carry the same producer's result and the delivery wins
    // harmlessly.
    for (int i = 0; i < DEPTH; i++) begin
      if (src1_cdb_pend[i]) begin
        rs_src1_value[i] <= src1_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q;
      end
      if (src2_cdb_pend[i]) begin
        rs_src2_value[i] <= src2_cdb_pend_lane[i] ? cdb1_value_q : cdb0_value_q;
      end
      if (HAS_SRC3 && src3_cdb_pend[i]) begin
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
      // Load stage2 from the RS entry selected by the priority encoder.
      // This covers both the empty-fill and back-to-back (accept + refill) cases.
      stage2_valid <= 1'b1;
      stage2_rob_tag <= rs_rob_tag[issue_idx];
      stage2_op <= riscv_pkg::instr_op_e'(pl_op_bits);
      if (CAPTURE_PRIMARY_EFFECTIVE_OPERANDS) begin
        // Fold the former post-Q three-arm muxes into the existing operand
        // FF D inputs.  Values still come from the complete CDB packets; the
        // optional issue-only inputs contribute valid/tag comparisons only.
        stage2_src1_value <= (((src1_repair_sel[issue_idx] != 3'd0) ? repair_value_for_sel(
            src1_repair_sel[issue_idx]
        ) : rs_src1_value[issue_idx]) &
            {FLEN{!src1_cdb_bypass[issue_idx] && !src1_cdb_bypass_l1[issue_idx]}}) |
            (i_cdb.value & {FLEN{src1_cdb_bypass[issue_idx]}}) |
            (i_cdb_2.value & {FLEN{src1_cdb_bypass_l1[issue_idx]}});
        stage2_src2_value <= (((src2_repair_sel[issue_idx] != 3'd0) ? repair_value_for_sel(
            src2_repair_sel[issue_idx]
        ) : rs_src2_value[issue_idx]) &
            {FLEN{!src2_cdb_bypass[issue_idx] && !src2_cdb_bypass_l1[issue_idx]}}) |
            (i_cdb.value & {FLEN{src2_cdb_bypass[issue_idx]}}) |
            (i_cdb_2.value & {FLEN{src2_cdb_bypass_l1[issue_idx]}});
      end else begin
        // For CDB-bypassed sources, store the stale rs_src_value here and set the
        // bypass flag; the output mux substitutes stage2_cdb_value /
        // stage2_cdb_value_l1.  This breaks the timing-critical path
        // CDB → tag match → issue select → FLEN mux → stage2.
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
      stage2_use_imm <= rs_use_imm[issue_idx];
      stage2_writes_cdb_hint <= TRACK_INT_WRITEBACK_HINT ? rs_writes_cdb_hint[issue_idx] : 1'b0;
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
            else $error("RS: primary src1 effective capture differs from legacy bypass");
            assert (stage2_src2_value == primary_src2_value_oracle_q)
            else $error("RS: primary src2 effective capture differs from legacy bypass");
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
  end

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // Warn on unusual dispatch conditions (non-fatal: tests exercise these)
      if (dispatch_valid && full && !i_flush_all && !i_flush_en)
        $warning("RS: dispatch attempted when full");

      if (dispatch_valid_2 && dispatch_fire && full_for_2 && !i_flush_all && !i_flush_en)
        $warning("RS: slot-2 dispatch attempted when full_for_2 (and slot-1 firing)");

      // Slot-1 and slot-2 must never target the same physical entry.
      if (dispatch_fire && dispatch_fire_2 && !i_flush_all && !i_flush_en &&
          (free_idx == alloc_idx_2))
        $error("RS: slot-1 and slot-2 alloc collide on entry %0d", free_idx);

      // The fixed-depth one-hot slot-2 select must equal the indexed decode
      // it replaces on every free entry (fatal: the two would diverge only
      // through a bug in the nibble tree, and the value D mux trusts it).
      if (!$isunknown({rs_valid, i_intent_1, data_write_2_en})) begin
        assert (alloc_sel_2 == (data_write_2_en ? (index_to_onehot(alloc_idx_2) & ~rs_valid) : '0))
        else $error("RS: alloc_sel_2 %b disagrees with alloc_idx_2 %0d", alloc_sel_2, alloc_idx_2);
      end

      // Issue fires only for ready entries (fatal: indicates RTL bug)
      // Checks stage1 issue_fire (RS→stage2), not stage2 output.
      if (issue_fire && !entry_ready[issue_idx])
        $error("RS: issue fired for non-ready entry %0d", issue_idx);

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

      // Deferred dispatch-CDB delivery invariants.  A pend flag lives for
      // exactly one cycle on a committed (hence resident) entry whose source
      // nothing else has satisfied; if a done-repair response for the same
      // source lands in the delivery cycle, it must carry the same
      // producer's value as the registered lane copy (coalesce contract).
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
  // Standalone only: these constrain a free environment.  In the wrapper proof
  // the dispatch unit drives these inputs, so assuming them there would hide
  // the very dispatch bugs that proof exists to find.

  generate
    if (FORMAL_STANDALONE_ENV) begin : gen_formal_dispatch_contract
      // Dispatch must not coincide with a partial flush.  Full flushes may
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
      // produces i_dispatch.valid.  The slot-2 alloc index relies on that
      // contract to choose the second free entry when both slots target this RS.
      always_comb begin
        assume (i_intent_1 == dispatch_valid);
      end
    end
  endgenerate

  // -------------------------------------------------------------------------
  // Combinational assertions
  // -------------------------------------------------------------------------

  always_comb begin
    if (ALLOC_INDEXED_REPAIR) begin
      p_indexed_repair_mode_exclusive : assert (!DISPATCH_REPAIR_BYPASS && !ISSUE_REPAIR_BYPASS);
      // The targets are reset- and flush-cleared, so like every other state
      // property here they are claimed only from the first post-reset cycle;
      // the pre-reset register contents are arbitrary.
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

  // full iff all valid
  always_comb begin
    if (i_rst_n) begin
      p_full_iff_all_valid : assert (full == (&rs_valid));
    end
  end

  // empty iff none valid
  always_comb begin
    if (i_rst_n) begin
      p_empty_iff_none_valid : assert (empty == (rs_valid == '0));
    end
  end

  // count matches popcount of valid bits
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

  // The fixed-depth one-hot slot-2 allocation select equals the indexed
  // decode it replaces on every free entry, for every rs_valid pattern.
  always_comb begin
    if (i_rst_n) begin
      p_alloc_sel_2_matches_index :
      assert (alloc_sel_2 == (data_write_2_en ? (index_to_onehot(alloc_idx_2) & ~rs_valid) : '0));
    end
  end

  // Stage1 issue_fire implies the selected entry was valid and ready
  always_comb begin
    if (i_rst_n && issue_fire) begin
      p_issue_entry_was_valid : assert (rs_valid[issue_idx]);
      p_issue_entry_was_ready : assert (entry_ready[issue_idx]);
    end
  end

  // Stage2 output valid implies stage2 is occupied
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

      // Free-entry broadcast is an implementation-only write-policy change:
      // a committed dispatch must still observe the exact source values from
      // its own packet at the selected entry on the following cycle.  The
      // timing-targeted mode has dispatch repair bypass disabled; a CDB
      // match in the dispatch cycle leaves the packet value in place here
      // (this samples one cycle after dispatch, before the deferred
      // delivery overwrites the source with the broadcast value).
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

      // Dispatch sets valid
      if ($past(dispatch_fire) && !$past(i_flush_all) && !$past(i_flush_en)) begin
        p_dispatch_sets_valid : assert (rs_valid[$past(free_idx)]);
      end

      // Slot-2 dispatch sets valid at alloc_idx_2.
      if ($past(dispatch_fire_2) && !$past(i_flush_all) && !$past(i_flush_en)) begin
        p_dispatch_2_sets_valid : assert (rs_valid[$past(alloc_idx_2)]);
      end

      // Issue clears valid
      if ($past(issue_fire) && !$past(i_flush_all) && !$past(i_flush_en)) begin
        p_issue_clears_valid : assert (!rs_valid[$past(issue_idx)]);
      end

      // flush_all empties RS and stage2
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

    // Reset clears all entries
    if (f_past_valid && i_rst_n && !$past(i_rst_n)) begin
      p_reset_clears_all : assert (rs_valid == '0);
    end
  end

  // Deferred dispatch-CDB delivery, decomposed into single-edge steps.
  // Together they give the end-to-end guarantee that a dispatch-cycle CDB
  // match delivers the matched lane's broadcast value and the ready bit two
  // cycles after dispatch: the match registers the pend pair at the
  // allocated entry, the central lane copies register the broadcast, and
  // delivery sets ready and retires the pend.  The final copy-into-array
  // value handoff is not asserted here.  This harness config compiles out
  // every property that observes rs_src*_value (the broadcast-exact checks
  // above are guarded off).  The first such assert drags the value arrays'
  // done-repair CAM mux cones into the live SMT model, and boolector then
  // stalls on step 5 for 15+ minutes in every encoding tried: $past form,
  // explicit delay registers, even a single-entry witness.  That handoff is
  // a single uniform delivery statement checked bit-exactly by the directed
  // cocotb unit tests and the sim-side coalesce assertions.
  // Labels omitted inside the loop: Yosys rejects duplicate names from
  // loop unrolling.
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
  // Standalone only.  These describe traffic the station's own top can drive
  // directly; inside the wrapper proof the same traces would have to come
  // through the whole front end, and its shallower cover depth cannot reach
  // most of them.
  generate
    if (FORMAL_STANDALONE_ENV) begin : gen_formal_covers
      always @(posedge i_clk) begin
        if (i_rst_n) begin
          // Dispatch and issue in the same cycle
          cover_dispatch_and_issue : cover (dispatch_fire && issue_fire);

          // CDB wakeup makes entry ready
          cover_cdb_wakeup : cover (i_cdb.valid && |rs_valid);

          // RS is full
          cover_full : cover (full);

          // Partial flush
          cover_partial_flush : cover (i_flush_en && |rs_valid);

          // Entry dispatched with CDB bypass
          cover_cdb_bypass_at_dispatch :
          cover (dispatch_fire && i_cdb.valid && !dispatch_src1_ready
                 && dispatch_src1_tag == i_cdb.tag);

          // Deferred dispatch-CDB delivery cycle in flight
          cover_deferred_cdb_delivery : cover (|src1_cdb_pend);

          // 2-wide dispatch fires both slots in the same cycle.
          cover_dispatch_2_wide : cover (dispatch_fire && dispatch_fire_2);

          // Slot-2 fires alone (slot-1 not valid this cycle).
          cover_dispatch_2_only : cover (dispatch_fire_2 && !dispatch_fire);

          // Stage2 back-to-back: consumed and refilled in the same cycle
          cover_stage2_back_to_back : cover (stage2_accept && issue_fire);

          // Stage2 flush squash
          cover_stage2_flush : cover (stage2_should_flush);

          // Stage2 blocked (FU not ready)
          cover_stage2_blocked : cover (stage2_valid && !i_fu_ready && !stage2_should_flush);
        end
      end
    end
  endgenerate

`endif  // RS_PRETAG_LOCAL_PROOF
`endif  // FORMAL

endmodule
