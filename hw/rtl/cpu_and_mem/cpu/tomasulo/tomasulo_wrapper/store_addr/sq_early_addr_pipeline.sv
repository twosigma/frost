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

// =============================================================================
// sq_early_addr_pipeline
// =============================================================================
// Pipelines the store effective-address computation. The dispatch base+imm is
// registered for one cycle, so the XLEN-wide adder runs off the dispatch
// critical path, breaking the RAT -> ROB bypass -> dispatch -> adder -> SQ
// path.  Dual-ported (slot-1 / slot-2): each slot has its own register set,
// adders, repair snoop, and update packet to the store queue.
//
// Persistent repair.  A store whose base register is not ready at dispatch
// becomes a repair candidate and waits for its base tag to complete.  It
// matches either on the six dispatch-scoped done-repair channels, which cover
// the already-done-at-dispatch case, or on either live CDB lane, which covers
// any later completion.  The channel match runs one cycle after the channels
// pulse, against the captured-channel registers below, so such a repair fires
// at dispatch+2.  See the timing comment at the capture.  A matched candidate
// emits its SQ update combinationally when the slot's port is free, and
// otherwise latches the repaired base and drains on the next free cycle.
// A candidate is evicted by a newer un-ready store on the same slot, and that
// store falls back to the MEM_RS address path, as all missed stores did before
// persistence.  It is killed when MEM_RS issues its store: the issue delivers
// the address anyway, and the kill closes the ROB-tag-reuse window, because a
// store cannot drain, and its tag cannot be reused, before MEM_RS issue
// delivers its data.  A flush clears it.
// =============================================================================
module sq_early_addr_pipeline (
    input logic i_clk,
    input logic i_rst_n,

    // Flush controls
    input logic i_flush_all,
    input logic i_flush_en,

    // Live CDB lanes (registered wrapper copies).  A held repair candidate's
    // base tag can complete any number of cycles after dispatch, and the
    // dispatch-scoped done-repair channels below pulse only for
    // just-dispatched tags, so persistence needs the real completion buses.
    input riscv_pkg::cdb_broadcast_t i_cdb,
    input riscv_pkg::cdb_broadcast_t i_cdb_2,

    // MEM_RS issue tap: kills a candidate whose store is being issued, since
    // the SQ gets that store's address through i_addr_update instead.  The
    // kill also closes the ROB-tag-reuse window.  A store cannot drain, and
    // its tag cannot be reused, before MEM_RS issue delivers its data, so
    // clearing here keeps a stale candidate from firing an old address into a
    // new same-tag store's entry.
    input logic i_mem_rs_issue_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_mem_rs_issue_rob_tag,

    // CDB repair snoop (done-repair valids, broadcast tags, broadcast values)
    input logic i_done_repair_valid_1,
    input logic i_done_repair_valid_2,
    input logic i_done_repair_valid_3,
    input logic i_done_repair_valid_4,
    input logic i_done_repair_valid_5,
    input logic i_done_repair_valid_6,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_1,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_3,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_4,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_5,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_6,
    input logic [riscv_pkg::FLEN-1:0] i_bypass_value_1,
    input logic [riscv_pkg::FLEN-1:0] i_bypass_value_2,
    input logic [riscv_pkg::FLEN-1:0] i_bypass_value_3,
    input logic [riscv_pkg::FLEN-1:0] i_bypass_value_4,
    input logic [riscv_pkg::FLEN-1:0] i_bypass_value_5,
    input logic [riscv_pkg::FLEN-1:0] i_bypass_value_6,

    // Dispatch packets + SQ alloc requests / full status
    input riscv_pkg::rs_dispatch_t i_mem_rs_dispatch,
    input riscv_pkg::rs_dispatch_t i_mem_rs_dispatch_2,
    input riscv_pkg::sq_alloc_req_t i_sq_alloc_req,
    input riscv_pkg::sq_alloc_req_t i_sq_alloc_req_2,
    input logic i_sq_full,
    input logic i_sq_full_for_2,

    // Early-address update packets to the store queue
    output riscv_pkg::sq_addr_update_t o_sq_early_addr_update,
    output riscv_pkg::sq_addr_update_t o_sq_early_addr_update_2,
    // Payload-only enables.  A waiting repair candidate may refresh its
    // still-hidden SQ address before its source matches; packet.valid remains
    // the sole control that sets sq_addr_valid.
    output logic o_sq_early_addr_capture_valid,
    output logic o_sq_early_addr_capture_valid_2
);

  // MMIO base (mirrors the tomasulo_wrapper localparam; identical constant).
  localparam logic [riscv_pkg::XLEN-1:0] MmioBase = 64'h4000_0000;

  // ---------------------------------------------------------------------------
  // Alias the submodule ports back to the wrapper's local names so the body
  // below is byte-identical to the original tomasulo_wrapper logic.
  // (i_clk/i_rst_n/i_flush_*/i_bypass_tag_* keep their wrapper names already.)
  // ---------------------------------------------------------------------------
  wire done_repair_valid_1 = i_done_repair_valid_1;
  wire done_repair_valid_2 = i_done_repair_valid_2;
  wire done_repair_valid_3 = i_done_repair_valid_3;
  wire done_repair_valid_4 = i_done_repair_valid_4;
  wire done_repair_valid_5 = i_done_repair_valid_5;
  wire done_repair_valid_6 = i_done_repair_valid_6;
  wire [riscv_pkg::FLEN-1:0] bypass_value_1 = i_bypass_value_1;
  wire [riscv_pkg::FLEN-1:0] bypass_value_2 = i_bypass_value_2;
  wire [riscv_pkg::FLEN-1:0] bypass_value_3 = i_bypass_value_3;
  wire [riscv_pkg::FLEN-1:0] bypass_value_4 = i_bypass_value_4;
  wire [riscv_pkg::FLEN-1:0] bypass_value_5 = i_bypass_value_5;
  wire [riscv_pkg::FLEN-1:0] bypass_value_6 = i_bypass_value_6;
  wire o_sq_full = i_sq_full;
  wire o_sq_full_for_2 = i_sq_full_for_2;
  riscv_pkg::rs_dispatch_t mem_rs_dispatch;
  riscv_pkg::rs_dispatch_t mem_rs_dispatch_2;
  riscv_pkg::sq_alloc_req_t sq_alloc_req;
  riscv_pkg::sq_alloc_req_t sq_alloc_req_2;
  assign mem_rs_dispatch   = i_mem_rs_dispatch;
  assign mem_rs_dispatch_2 = i_mem_rs_dispatch_2;
  assign sq_alloc_req      = i_sq_alloc_req;
  assign sq_alloc_req_2    = i_sq_alloc_req_2;

  // ===========================================================================
  // Pipelined early store address: register dispatch base+imm, compute next cycle
  // ===========================================================================
  // Slot-1 and slot-2 each have their own {valid, rob_tag, base, imm,
  // repair_*}_q register set, their own adders, and their own update packet to
  // the SQ.  The SQ accepts both updates in one cycle because their rob_tags
  // differ, so there is no NBA collision.  Deferring the XLEN-wide addition by
  // one cycle breaks the 20-level RAT → ROB bypass → dispatch value → CARRY8
  // adder → SQ critical path, and the second port removed the slot-2 store
  // back-pressure that had motivated the since-deleted `slot2_is_store_op`
  // term in instruction_aligner.sv.
  logic sq_early_addr_valid_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sq_early_addr_rob_tag_q;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_base_q;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_imm_q;
  logic sq_early_addr_repair_valid_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sq_early_addr_repair_rob_tag_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sq_early_addr_repair_src1_tag_q;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_repair_imm_q;

  // Slot-2 mirror
  logic sq_early_addr_valid_2_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sq_early_addr_rob_tag_2_q;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_base_2_q;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_imm_2_q;
  logic sq_early_addr_repair_valid_2_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sq_early_addr_repair_rob_tag_2_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sq_early_addr_repair_src1_tag_2_q;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_repair_imm_2_q;

  // -------------------------------------------------------------------------
  // Captured done-repair channels, worth -0.118 at x3 post-opt on the rob_done
  // -> SQ address/is_mmio CE cone (231 endpoints). done_repair_valid_N is a
  // 32:1 read of the design-wide rob_entry_done fanout, and resolving that
  // read, the priority chain, the wrapper->SQ net and the SQ's 8-entry CAM in
  // one cycle was the whole failing path. Each channel (valid, tag, base
  // value) is captured into local registers the cycle the channels pulse, and
  // the candidates match against the captured copies one cycle later: the
  // rob_done mux half now ends at a local flop, and the priority/net/CAM half
  // starts from local flops. The cost is one cycle on the rare repair
  // fallback, where a base already done at dispatch now repairs at dispatch+2
  // instead of dispatch+1. Coverage is unchanged: a base completing in or
  // after the gap cycle broadcasts on the live CDB lanes, which the match
  // chains below snoop every cycle. The captured tags travel with their valid
  // bits, so the one-cycle-later compare still pairs each candidate with its
  // own dispatch bundle's channels. A stale captured tag cannot alias a new
  // candidate, because ROB tags cannot be reused within 2 cycles. Valid bits
  // captured during a flush cycle are zeroed for hygiene, though their
  // candidate dies in the same flush anyway.
  // -------------------------------------------------------------------------
  logic done_repair_valid_1_q, done_repair_valid_2_q, done_repair_valid_3_q;
  logic done_repair_valid_4_q, done_repair_valid_5_q, done_repair_valid_6_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] done_repair_tag_1_q, done_repair_tag_2_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] done_repair_tag_3_q, done_repair_tag_4_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] done_repair_tag_5_q, done_repair_tag_6_q;
  logic [riscv_pkg::XLEN-1:0] done_repair_base_1_q, done_repair_base_2_q, done_repair_base_3_q;
  logic [riscv_pkg::XLEN-1:0] done_repair_base_4_q, done_repair_base_5_q, done_repair_base_6_q;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all || i_flush_en) begin
      done_repair_valid_1_q <= 1'b0;
      done_repair_valid_2_q <= 1'b0;
      done_repair_valid_3_q <= 1'b0;
      done_repair_valid_4_q <= 1'b0;
      done_repair_valid_5_q <= 1'b0;
      done_repair_valid_6_q <= 1'b0;
    end else begin
      done_repair_valid_1_q <= done_repair_valid_1;
      done_repair_valid_2_q <= done_repair_valid_2;
      done_repair_valid_3_q <= done_repair_valid_3;
      done_repair_valid_4_q <= done_repair_valid_4;
      done_repair_valid_5_q <= done_repair_valid_5;
      done_repair_valid_6_q <= done_repair_valid_6;
    end
    done_repair_tag_1_q  <= i_bypass_tag_1;
    done_repair_tag_2_q  <= i_bypass_tag_2;
    done_repair_tag_3_q  <= i_bypass_tag_3;
    done_repair_tag_4_q  <= i_bypass_tag_4;
    done_repair_tag_5_q  <= i_bypass_tag_5;
    done_repair_tag_6_q  <= i_bypass_tag_6;
    done_repair_base_1_q <= bypass_value_1[riscv_pkg::XLEN-1:0];
    done_repair_base_2_q <= bypass_value_2[riscv_pkg::XLEN-1:0];
    done_repair_base_3_q <= bypass_value_3[riscv_pkg::XLEN-1:0];
    done_repair_base_4_q <= bypass_value_4[riscv_pkg::XLEN-1:0];
    done_repair_base_5_q <= bypass_value_5[riscv_pkg::XLEN-1:0];
    done_repair_base_6_q <= bypass_value_6[riscv_pkg::XLEN-1:0];
  end

  logic sq_early_addr_repair_match;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_repair_base;
  logic sq_early_addr_repair_fire;
  logic [7:0] sq_early_addr_repair_cond;
  logic [7:0] sq_early_addr_repair_sel;
  always_comb begin
    // Same priority as the former if/else chain, expressed as a one-hot
    // winner plus an OR-of-masked-values tree.  Match is a separate shallow
    // reduction, keeping the candidate source tag off the SQ payload enables.
    sq_early_addr_repair_cond[0] = done_repair_valid_1_q &&
        (sq_early_addr_repair_src1_tag_q == done_repair_tag_1_q);
    sq_early_addr_repair_cond[1] = done_repair_valid_2_q &&
        (sq_early_addr_repair_src1_tag_q == done_repair_tag_2_q);
    sq_early_addr_repair_cond[2] = done_repair_valid_3_q &&
        (sq_early_addr_repair_src1_tag_q == done_repair_tag_3_q);
    sq_early_addr_repair_cond[3] = done_repair_valid_4_q &&
        (sq_early_addr_repair_src1_tag_q == done_repair_tag_4_q);
    sq_early_addr_repair_cond[4] = done_repair_valid_5_q &&
        (sq_early_addr_repair_src1_tag_q == done_repair_tag_5_q);
    sq_early_addr_repair_cond[5] = done_repair_valid_6_q &&
        (sq_early_addr_repair_src1_tag_q == done_repair_tag_6_q);
    sq_early_addr_repair_cond[6] = i_cdb.valid && (sq_early_addr_repair_src1_tag_q == i_cdb.tag);
    sq_early_addr_repair_cond[7] = i_cdb_2.valid &&
        (sq_early_addr_repair_src1_tag_q == i_cdb_2.tag);

    sq_early_addr_repair_sel[0] = sq_early_addr_repair_cond[0];
    sq_early_addr_repair_sel[1] = sq_early_addr_repair_cond[1] &&
        !(|sq_early_addr_repair_cond[0:0]);
    sq_early_addr_repair_sel[2] = sq_early_addr_repair_cond[2] &&
        !(|sq_early_addr_repair_cond[1:0]);
    sq_early_addr_repair_sel[3] = sq_early_addr_repair_cond[3] &&
        !(|sq_early_addr_repair_cond[2:0]);
    sq_early_addr_repair_sel[4] = sq_early_addr_repair_cond[4] &&
        !(|sq_early_addr_repair_cond[3:0]);
    sq_early_addr_repair_sel[5] = sq_early_addr_repair_cond[5] &&
        !(|sq_early_addr_repair_cond[4:0]);
    sq_early_addr_repair_sel[6] = sq_early_addr_repair_cond[6] &&
        !(|sq_early_addr_repair_cond[5:0]);
    sq_early_addr_repair_sel[7] = sq_early_addr_repair_cond[7] &&
        !(|sq_early_addr_repair_cond[6:0]);

    sq_early_addr_repair_match = |sq_early_addr_repair_cond;
    sq_early_addr_repair_base =
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel[0]}} & done_repair_base_1_q) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel[1]}} & done_repair_base_2_q) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel[2]}} & done_repair_base_3_q) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel[3]}} & done_repair_base_4_q) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel[4]}} & done_repair_base_5_q) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel[5]}} & done_repair_base_6_q) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel[6]}} & i_cdb.value[riscv_pkg::XLEN-1:0]) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel[7]}} & i_cdb_2.value[riscv_pkg::XLEN-1:0]);
  end

  assign sq_early_addr_repair_fire = sq_early_addr_repair_valid_q &&
                                     sq_early_addr_repair_match &&
                                     !i_flush_all && !i_flush_en;

  // Slot-2 repair match: snoops the same six done-repair channels and both
  // live CDB lanes.  Both slots can match on the same broadcast tag in the
  // rare case where both stores rename to the same source tag, e.g. both read
  // the same arch reg with no intervening write.  Each slot then computes its
  // own address, since the base is shared but the imm differs.
  logic sq_early_addr_repair_match_2;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_repair_base_2;
  logic sq_early_addr_repair_fire_2;
  logic [7:0] sq_early_addr_repair_cond_2;
  logic [7:0] sq_early_addr_repair_sel_2;
  always_comb begin
    sq_early_addr_repair_cond_2[0] = done_repair_valid_1_q &&
        (sq_early_addr_repair_src1_tag_2_q == done_repair_tag_1_q);
    sq_early_addr_repair_cond_2[1] = done_repair_valid_2_q &&
        (sq_early_addr_repair_src1_tag_2_q == done_repair_tag_2_q);
    sq_early_addr_repair_cond_2[2] = done_repair_valid_3_q &&
        (sq_early_addr_repair_src1_tag_2_q == done_repair_tag_3_q);
    sq_early_addr_repair_cond_2[3] = done_repair_valid_4_q &&
        (sq_early_addr_repair_src1_tag_2_q == done_repair_tag_4_q);
    sq_early_addr_repair_cond_2[4] = done_repair_valid_5_q &&
        (sq_early_addr_repair_src1_tag_2_q == done_repair_tag_5_q);
    sq_early_addr_repair_cond_2[5] = done_repair_valid_6_q &&
        (sq_early_addr_repair_src1_tag_2_q == done_repair_tag_6_q);
    sq_early_addr_repair_cond_2[6] = i_cdb.valid &&
        (sq_early_addr_repair_src1_tag_2_q == i_cdb.tag);
    sq_early_addr_repair_cond_2[7] = i_cdb_2.valid &&
        (sq_early_addr_repair_src1_tag_2_q == i_cdb_2.tag);

    sq_early_addr_repair_sel_2[0] = sq_early_addr_repair_cond_2[0];
    sq_early_addr_repair_sel_2[1] = sq_early_addr_repair_cond_2[1] &&
        !(|sq_early_addr_repair_cond_2[0:0]);
    sq_early_addr_repair_sel_2[2] = sq_early_addr_repair_cond_2[2] &&
        !(|sq_early_addr_repair_cond_2[1:0]);
    sq_early_addr_repair_sel_2[3] = sq_early_addr_repair_cond_2[3] &&
        !(|sq_early_addr_repair_cond_2[2:0]);
    sq_early_addr_repair_sel_2[4] = sq_early_addr_repair_cond_2[4] &&
        !(|sq_early_addr_repair_cond_2[3:0]);
    sq_early_addr_repair_sel_2[5] = sq_early_addr_repair_cond_2[5] &&
        !(|sq_early_addr_repair_cond_2[4:0]);
    sq_early_addr_repair_sel_2[6] = sq_early_addr_repair_cond_2[6] &&
        !(|sq_early_addr_repair_cond_2[5:0]);
    sq_early_addr_repair_sel_2[7] = sq_early_addr_repair_cond_2[7] &&
        !(|sq_early_addr_repair_cond_2[6:0]);

    sq_early_addr_repair_match_2 = |sq_early_addr_repair_cond_2;
    sq_early_addr_repair_base_2 =
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel_2[0]}} & done_repair_base_1_q) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel_2[1]}} & done_repair_base_2_q) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel_2[2]}} & done_repair_base_3_q) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel_2[3]}} & done_repair_base_4_q) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel_2[4]}} & done_repair_base_5_q) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel_2[5]}} & done_repair_base_6_q) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel_2[6]}} & i_cdb.value[riscv_pkg::XLEN-1:0]) |
        ({riscv_pkg::XLEN{sq_early_addr_repair_sel_2[7]}} & i_cdb_2.value[riscv_pkg::XLEN-1:0]);
  end

  assign sq_early_addr_repair_fire_2 = sq_early_addr_repair_valid_2_q &&
                                       sq_early_addr_repair_match_2 &&
                                       !i_flush_all && !i_flush_en;

  // Slot-2 alloc-accepted gate mirrors store_queue.sv slot2_alloc_en:
  //   slot2 alloc fires iff i_alloc_2.valid && (slot1_alloc_en ? !full_for_2 : !full)
  //   where slot1_alloc_en = i_alloc.valid && !full.
  // The SQ-full propagation through dispatch is already conservative, so this
  // is a redundant re-check, the same one slot-1 makes.  It keeps an
  // early-addr update from being stamped for an entry the SQ refused to
  // allocate.
  logic slot2_sq_alloc_accepted;
  assign slot2_sq_alloc_accepted = sq_alloc_req_2.valid &&
                                   ((sq_alloc_req.valid && !o_sq_full) ?
                                    !o_sq_full_for_2 : !o_sq_full);

  // Persistent-repair state.  A candidate waits until its base tag completes
  // on the dispatch channels or the live CDB lanes, and it leaves on eviction
  // by a newer un-ready store in the same slot, on MEM_RS issuing its store,
  // or on flush.  A matched candidate whose SQ update port is taken by a fresh
  // (ready-base) update latches its repaired base in the hold registers and
  // drains on the next free-port cycle.
  logic sq_early_addr_repair_ready_q;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_repair_base_hold_q;
  logic sq_early_addr_repair_ready_2_q;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_repair_base_hold_2_q;

  logic slot1_new_ready_store, slot1_new_unready_store;
  logic slot2_new_ready_store, slot2_new_unready_store;
  assign slot1_new_ready_store   = sq_alloc_req.valid && !o_sq_full && mem_rs_dispatch.src1_ready;
  assign slot1_new_unready_store = sq_alloc_req.valid && !o_sq_full && !mem_rs_dispatch.src1_ready;
  assign slot2_new_ready_store   = slot2_sq_alloc_accepted && mem_rs_dispatch_2.src1_ready;
  assign slot2_new_unready_store = slot2_sq_alloc_accepted && !mem_rs_dispatch_2.src1_ready;

  // Fresh updates own the SQ port on their (single) emission cycle.
  logic slot1_port_taken_by_fresh, slot2_port_taken_by_fresh;
  assign slot1_port_taken_by_fresh = sq_early_addr_valid_q;
  assign slot2_port_taken_by_fresh = sq_early_addr_valid_2_q;

  logic slot1_mem_rs_issue_kill, slot2_mem_rs_issue_kill;
  assign slot1_mem_rs_issue_kill = i_mem_rs_issue_valid &&
                                   (i_mem_rs_issue_rob_tag == sq_early_addr_repair_rob_tag_q);
  assign slot2_mem_rs_issue_kill = i_mem_rs_issue_valid &&
                                   (i_mem_rs_issue_rob_tag == sq_early_addr_repair_rob_tag_2_q);

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all || i_flush_en) begin
      sq_early_addr_valid_q <= 1'b0;
      sq_early_addr_repair_valid_q <= 1'b0;
      sq_early_addr_repair_ready_q <= 1'b0;
      sq_early_addr_valid_2_q <= 1'b0;
      sq_early_addr_repair_valid_2_q <= 1'b0;
      sq_early_addr_repair_ready_2_q <= 1'b0;
    end else begin
      sq_early_addr_valid_q <= slot1_new_ready_store;
      sq_early_addr_rob_tag_q <= mem_rs_dispatch.rob_tag;
      sq_early_addr_base_q <= mem_rs_dispatch.src1_value[riscv_pkg::XLEN-1:0];
      sq_early_addr_imm_q <= mem_rs_dispatch.imm;

      // Slot-1 waiting/ready state machine.  Eviction (a newer un-ready
      // store on this slot) wins over everything: the old candidate either
      // emitted combinationally this cycle or falls back to the MEM_RS
      // address path.  The MEM_RS-issue kill must beat a same-cycle match:
      // the issue is already delivering this store's address.
      if (slot1_new_unready_store) begin
        sq_early_addr_repair_valid_q <= 1'b1;
        sq_early_addr_repair_ready_q <= 1'b0;
        sq_early_addr_repair_rob_tag_q <= mem_rs_dispatch.rob_tag;
        sq_early_addr_repair_src1_tag_q <= mem_rs_dispatch.src1_tag;
        sq_early_addr_repair_imm_q <= mem_rs_dispatch.imm;
      end else if (slot1_mem_rs_issue_kill) begin
        sq_early_addr_repair_valid_q <= 1'b0;
        sq_early_addr_repair_ready_q <= 1'b0;
      end else begin
        if (sq_early_addr_repair_fire) begin
          sq_early_addr_repair_valid_q <= 1'b0;
          if (slot1_port_taken_by_fresh) begin
            sq_early_addr_repair_ready_q <= 1'b1;
            sq_early_addr_repair_base_hold_q <= sq_early_addr_repair_base;
          end
        end
        if (sq_early_addr_repair_ready_q && !slot1_port_taken_by_fresh) begin
          sq_early_addr_repair_ready_q <= 1'b0;
        end
      end

      // Slot-2: same structure.
      sq_early_addr_valid_2_q <= slot2_new_ready_store;
      sq_early_addr_rob_tag_2_q <= mem_rs_dispatch_2.rob_tag;
      sq_early_addr_base_2_q <= mem_rs_dispatch_2.src1_value[riscv_pkg::XLEN-1:0];
      sq_early_addr_imm_2_q <= mem_rs_dispatch_2.imm;

      if (slot2_new_unready_store) begin
        sq_early_addr_repair_valid_2_q <= 1'b1;
        sq_early_addr_repair_ready_2_q <= 1'b0;
        sq_early_addr_repair_rob_tag_2_q <= mem_rs_dispatch_2.rob_tag;
        sq_early_addr_repair_src1_tag_2_q <= mem_rs_dispatch_2.src1_tag;
        sq_early_addr_repair_imm_2_q <= mem_rs_dispatch_2.imm;
      end else if (slot2_mem_rs_issue_kill) begin
        sq_early_addr_repair_valid_2_q <= 1'b0;
        sq_early_addr_repair_ready_2_q <= 1'b0;
      end else begin
        if (sq_early_addr_repair_fire_2) begin
          sq_early_addr_repair_valid_2_q <= 1'b0;
          if (slot2_port_taken_by_fresh) begin
            sq_early_addr_repair_ready_2_q <= 1'b1;
            sq_early_addr_repair_base_hold_2_q <= sq_early_addr_repair_base_2;
          end
        end
        if (sq_early_addr_repair_ready_2_q && !slot2_port_taken_by_fresh) begin
          sq_early_addr_repair_ready_2_q <= 1'b0;
        end
      end
    end
  end

  // The adders run on registered inputs, off the dispatch critical path.
  // Phase 3 M2: all six store-AGU adder outputs flow full-width, unmasked.  An
  // out-of-map store faults at the wrapper's issue-time PMA check before its
  // entry can drain, so downstream consumers only ever act on launched,
  // in-map addresses.
  logic [riscv_pkg::XLEN-1:0] sq_early_effective_addr;
  logic [riscv_pkg::XLEN-1:0] sq_early_repair_effective_addr;
  assign sq_early_effective_addr = (sq_early_addr_base_q + sq_early_addr_imm_q);
  assign sq_early_repair_effective_addr = (sq_early_addr_repair_base + sq_early_addr_repair_imm_q);

  // Slot-2 adder
  logic [riscv_pkg::XLEN-1:0] sq_early_effective_addr_2;
  logic [riscv_pkg::XLEN-1:0] sq_early_repair_effective_addr_2;
  assign sq_early_effective_addr_2 = (sq_early_addr_base_2_q + sq_early_addr_imm_2_q);
  assign sq_early_repair_effective_addr_2 = (
      sq_early_addr_repair_base_2 + sq_early_addr_repair_imm_2_q
  );

  // Held-candidate adders: run on the latched repaired base (registered), so
  // the drain path stays off the CDB/bypass comb cone.
  logic [riscv_pkg::XLEN-1:0] sq_early_hold_effective_addr;
  logic [riscv_pkg::XLEN-1:0] sq_early_hold_effective_addr_2;
  assign sq_early_hold_effective_addr = (
      sq_early_addr_repair_base_hold_q + sq_early_addr_repair_imm_q
  );
  assign sq_early_hold_effective_addr_2 = (
      sq_early_addr_repair_base_hold_2_q + sq_early_addr_repair_imm_2_q
  );

  // Port arbitration.  A fresh (ready-base) update lives for one cycle only,
  // so it always wins.  A just-matched candidate emits combinationally on a
  // free cycle and otherwise latches into the hold registers.  A held
  // candidate drains on the next free cycle.  ready and waiting are exclusive
  // states, so the last two arms never contend.
  riscv_pkg::sq_addr_update_t sq_early_addr_update;
  always_comb begin
    sq_early_addr_update = '0;
    if (sq_early_addr_valid_q) begin
      sq_early_addr_update.valid   = 1'b1;
      sq_early_addr_update.rob_tag = sq_early_addr_rob_tag_q;
      sq_early_addr_update.address = sq_early_effective_addr;
      // MMIO is the 01 address quadrant [0x4000_0000, 0x8000_0000). The
      // cached (DDR) region is the 10 quadrant and must not be flagged. The
      // old ">= MmioBase" shortcut predates the cached tier.
      sq_early_addr_update.is_mmio = (sq_early_effective_addr[31:30] == 2'b01);
    end else if (sq_early_addr_repair_ready_q) begin
      sq_early_addr_update.valid   = 1'b1;
      sq_early_addr_update.rob_tag = sq_early_addr_repair_rob_tag_q;
      sq_early_addr_update.address = sq_early_hold_effective_addr;
      sq_early_addr_update.is_mmio = (sq_early_hold_effective_addr[31:30] == 2'b01);
    end else if (sq_early_addr_repair_valid_q) begin
      // While unmatched, only the payload-only sideband below is high, and
      // the provisional value stays hidden behind sq_addr_valid.  On the match
      // edge this same arm carries the selected base, and packet.valid makes
      // it architecturally visible.
      sq_early_addr_update.valid   = sq_early_addr_repair_fire;
      sq_early_addr_update.rob_tag = sq_early_addr_repair_rob_tag_q;
      sq_early_addr_update.address = sq_early_repair_effective_addr;
      sq_early_addr_update.is_mmio = (sq_early_repair_effective_addr[31:30] == 2'b01);
    end
  end

  // Slot-2 packet: same arbitration.
  riscv_pkg::sq_addr_update_t sq_early_addr_update_2;
  always_comb begin
    sq_early_addr_update_2 = '0;
    if (sq_early_addr_valid_2_q) begin
      sq_early_addr_update_2.valid   = 1'b1;
      sq_early_addr_update_2.rob_tag = sq_early_addr_rob_tag_2_q;
      sq_early_addr_update_2.address = sq_early_effective_addr_2;
      sq_early_addr_update_2.is_mmio = (sq_early_effective_addr_2[31:30] == 2'b01);
    end else if (sq_early_addr_repair_ready_2_q) begin
      sq_early_addr_update_2.valid   = 1'b1;
      sq_early_addr_update_2.rob_tag = sq_early_addr_repair_rob_tag_2_q;
      sq_early_addr_update_2.address = sq_early_hold_effective_addr_2;
      sq_early_addr_update_2.is_mmio = (sq_early_hold_effective_addr_2[31:30] == 2'b01);
    end else if (sq_early_addr_repair_valid_2_q) begin
      sq_early_addr_update_2.valid   = sq_early_addr_repair_fire_2;
      sq_early_addr_update_2.rob_tag = sq_early_addr_repair_rob_tag_2_q;
      sq_early_addr_update_2.address = sq_early_repair_effective_addr_2;
      sq_early_addr_update_2.is_mmio = (sq_early_repair_effective_addr_2[31:30] == 2'b01);
    end
  end

  assign o_sq_early_addr_update = sq_early_addr_update;
  assign o_sq_early_addr_update_2 = sq_early_addr_update_2;
  assign o_sq_early_addr_capture_valid = sq_early_addr_valid_q ||
      sq_early_addr_repair_ready_q || sq_early_addr_repair_valid_q;
  assign o_sq_early_addr_capture_valid_2 = sq_early_addr_valid_2_q ||
      sq_early_addr_repair_ready_2_q || sq_early_addr_repair_valid_2_q;

`ifndef SYNTHESIS
  // For known inputs, the explicit one-hot reshape is the exact priority
  // function that it replaces. Multiple simultaneous matches retain lane
  // 1..6, CDB1, CDB2 priority in that order. Reachable valid/tag inputs are
  // known after reset, so the checks below sit under an $isunknown guard and
  // skip four-state X cases.
  logic sq_early_addr_repair_match_reference;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_repair_base_reference;
  logic sq_early_addr_repair_match_2_reference;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_repair_base_2_reference;
  always_comb begin
    sq_early_addr_repair_match_reference = 1'b1;
    if (sq_early_addr_repair_cond[0]) sq_early_addr_repair_base_reference = done_repair_base_1_q;
    else if (sq_early_addr_repair_cond[1])
      sq_early_addr_repair_base_reference = done_repair_base_2_q;
    else if (sq_early_addr_repair_cond[2])
      sq_early_addr_repair_base_reference = done_repair_base_3_q;
    else if (sq_early_addr_repair_cond[3])
      sq_early_addr_repair_base_reference = done_repair_base_4_q;
    else if (sq_early_addr_repair_cond[4])
      sq_early_addr_repair_base_reference = done_repair_base_5_q;
    else if (sq_early_addr_repair_cond[5])
      sq_early_addr_repair_base_reference = done_repair_base_6_q;
    else if (sq_early_addr_repair_cond[6])
      sq_early_addr_repair_base_reference = i_cdb.value[riscv_pkg::XLEN-1:0];
    else if (sq_early_addr_repair_cond[7])
      sq_early_addr_repair_base_reference = i_cdb_2.value[riscv_pkg::XLEN-1:0];
    else begin
      sq_early_addr_repair_match_reference = 1'b0;
      sq_early_addr_repair_base_reference  = '0;
    end

    sq_early_addr_repair_match_2_reference = 1'b1;
    if (sq_early_addr_repair_cond_2[0])
      sq_early_addr_repair_base_2_reference = done_repair_base_1_q;
    else if (sq_early_addr_repair_cond_2[1])
      sq_early_addr_repair_base_2_reference = done_repair_base_2_q;
    else if (sq_early_addr_repair_cond_2[2])
      sq_early_addr_repair_base_2_reference = done_repair_base_3_q;
    else if (sq_early_addr_repair_cond_2[3])
      sq_early_addr_repair_base_2_reference = done_repair_base_4_q;
    else if (sq_early_addr_repair_cond_2[4])
      sq_early_addr_repair_base_2_reference = done_repair_base_5_q;
    else if (sq_early_addr_repair_cond_2[5])
      sq_early_addr_repair_base_2_reference = done_repair_base_6_q;
    else if (sq_early_addr_repair_cond_2[6])
      sq_early_addr_repair_base_2_reference = i_cdb.value[riscv_pkg::XLEN-1:0];
    else if (sq_early_addr_repair_cond_2[7])
      sq_early_addr_repair_base_2_reference = i_cdb_2.value[riscv_pkg::XLEN-1:0];
    else begin
      sq_early_addr_repair_match_2_reference = 1'b0;
      sq_early_addr_repair_base_2_reference  = '0;
    end

    if (!$isunknown({sq_early_addr_repair_cond, sq_early_addr_repair_sel})) begin
      p_repair_select_onehot : assert ($onehot0(sq_early_addr_repair_sel));
      p_repair_select_found_exact :
      assert ((|sq_early_addr_repair_sel) == (|sq_early_addr_repair_cond));
      p_repair_priority_exact :
      assert (sq_early_addr_repair_match == sq_early_addr_repair_match_reference &&
              (sq_early_addr_repair_base === sq_early_addr_repair_base_reference));
    end
    if (!$isunknown({sq_early_addr_repair_cond_2, sq_early_addr_repair_sel_2})) begin
      p_repair_select_2_onehot : assert ($onehot0(sq_early_addr_repair_sel_2));
      p_repair_select_2_found_exact :
      assert ((|sq_early_addr_repair_sel_2) == (|sq_early_addr_repair_cond_2));
      p_repair_priority_2_exact :
      assert (sq_early_addr_repair_match_2 == sq_early_addr_repair_match_2_reference &&
              (sq_early_addr_repair_base_2 === sq_early_addr_repair_base_2_reference));
    end
  end
`endif

endmodule
