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
// Early store addresses for both dispatch slots. A store dispatched with its
// base ready has base and immediate registered for one cycle, so the
// XLEN-wide adder runs off the RAT -> ROB bypass -> dispatch -> SQ path. Each
// slot has its own registers, adders, repair match, and update packet to the
// store queue.
//
// A store whose base register is not ready at dispatch becomes the slot's
// repair candidate and waits for its base tag. It matches on the six
// done-repair channels, which cover a base already done at dispatch, or on
// either live CDB lane, which covers any later completion. The channel match
// runs one cycle after the channels pulse, against captured copies, so such a
// repair fires at dispatch+2 (see the capture below). A matched candidate
// sends its SQ update in the same cycle if the slot's port is free, and
// otherwise holds the repaired base and sends it on the next free cycle.
//
// A newer unready store on the same slot replaces the candidate; the old
// store then gets its address at MEM_RS issue. A candidate is cancelled when
// MEM_RS issues its store, which delivers the address anyway. Cancelling at
// issue also keeps a stale candidate from writing into a later store that
// reuses the ROB tag: a store cannot drain, and so its tag cannot be reused,
// before MEM_RS issue delivers its data. Any flush clears the candidate.
// =============================================================================
module sq_early_addr_pipeline (
    input logic i_clk,
    input logic i_rst_n,

    // Flush controls
    input logic i_flush_all,
    input logic i_flush_en,

    // Live CDB lanes (the wrapper's registered copies). A candidate's base
    // can complete any number of cycles after dispatch, but the done-repair
    // channels below answer only the just-dispatched bundle's queries.
    input riscv_pkg::cdb_broadcast_t i_cdb,
    input riscv_pkg::cdb_broadcast_t i_cdb_2,

    // MEM_RS issue of an SQ-bound op: cancels the candidate with that ROB tag,
    // since the issue delivers the store's address to the SQ (i_addr_update).
    input logic i_mem_rs_issue_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_mem_rs_issue_rob_tag,

    // Done-repair channels (1-3: slot-1 sources, 4-6: slot-2 sources): valid,
    // queried tag, and value
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
    // Payload-only enables. A waiting repair candidate may refresh its
    // still-hidden SQ address before its source matches; packet.valid alone
    // sets sq_addr_valid.
    output logic o_sq_early_addr_capture_valid,
    output logic o_sq_early_addr_capture_valid_2
);

  // ---------------------------------------------------------------------------
  // Input aliases with the wrapper's signal names (i_clk, i_rst_n, i_flush_*,
  // and i_bypass_tag_* already match).
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
  // the SQ. The SQ accepts both updates in one cycle because their rob_tags
  // differ, so there is no NBA collision. Deferring the XLEN-wide addition by
  // one cycle keeps the CARRY8 adder off the RAT -> ROB bypass -> dispatch
  // value -> SQ critical path.
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
  // Captured done-repair channels. done_repair_valid_N is a 32:1 read of the
  // ROB's rob_entry_done bits, and that read, the priority tree, the
  // wrapper -> SQ net, and the SQ's 8-entry CAM do not fit in one cycle.
  // Each channel (valid, tag, base value) is captured into local registers in
  // the cycle the channels pulse, and the candidates match against the
  // captured copies one cycle later, so the ROB read ends at a local register
  // and the priority/net/CAM path starts from one. The cost is one cycle on
  // the repair path: a base already done at dispatch repairs at dispatch+2. A
  // base that completes in or after the gap cycle broadcasts on the live CDB
  // lanes, which the match snoops every cycle. The captured tags travel with
  // their valid bits, so the one-cycle-later compare pairs each candidate with
  // its own dispatch bundle's channels. A stale captured tag cannot alias a
  // new candidate, because ROB tags cannot be reused within 2 cycles. A flush
  // clears the captured valid bits, though their candidate dies in the same
  // flush anyway.
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
  logic [3:0] sq_early_addr_repair_pair_match;
  logic [3:0][riscv_pkg::XLEN-1:0] sq_early_addr_repair_pair_base;
  logic [1:0] sq_early_addr_repair_half_match;
  logic [1:0][riscv_pkg::XLEN-1:0] sq_early_addr_repair_half_base;
  always_comb begin
    // Lowest-index priority (channels 1-6, then i_cdb, then i_cdb_2) as a
    // balanced three-level tree. Every node carries {match, base}; the left
    // child wins whenever it contains a match. It covers all six dispatch
    // channels and both live CDB lanes, including the legal early match of a
    // new candidate whose tag occurs in the preceding dispatch bundle's
    // channels.
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

    sq_early_addr_repair_pair_match[0] = |sq_early_addr_repair_cond[1:0];
    sq_early_addr_repair_pair_match[1] = |sq_early_addr_repair_cond[3:2];
    sq_early_addr_repair_pair_match[2] = |sq_early_addr_repair_cond[5:4];
    sq_early_addr_repair_pair_match[3] = |sq_early_addr_repair_cond[7:6];
    sq_early_addr_repair_pair_base[0] = sq_early_addr_repair_cond[0] ?
        done_repair_base_1_q : done_repair_base_2_q;
    sq_early_addr_repair_pair_base[1] = sq_early_addr_repair_cond[2] ?
        done_repair_base_3_q : done_repair_base_4_q;
    sq_early_addr_repair_pair_base[2] = sq_early_addr_repair_cond[4] ?
        done_repair_base_5_q : done_repair_base_6_q;
    sq_early_addr_repair_pair_base[3] = sq_early_addr_repair_cond[6] ?
        i_cdb.value[riscv_pkg::XLEN-1:0] :
        sq_early_addr_repair_cond[7] ? i_cdb_2.value[riscv_pkg::XLEN-1:0] : '0;

    sq_early_addr_repair_half_match[0] = |sq_early_addr_repair_pair_match[1:0];
    sq_early_addr_repair_half_match[1] = |sq_early_addr_repair_pair_match[3:2];
    sq_early_addr_repair_half_base[0] = sq_early_addr_repair_pair_match[0] ?
        sq_early_addr_repair_pair_base[0] : sq_early_addr_repair_pair_base[1];
    sq_early_addr_repair_half_base[1] = sq_early_addr_repair_pair_match[2] ?
        sq_early_addr_repair_pair_base[2] : sq_early_addr_repair_pair_base[3];

    sq_early_addr_repair_match = |sq_early_addr_repair_half_match;
    sq_early_addr_repair_base = sq_early_addr_repair_half_match[0] ?
        sq_early_addr_repair_half_base[0] : sq_early_addr_repair_half_base[1];
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
  logic [3:0] sq_early_addr_repair_pair_match_2;
  logic [3:0][riscv_pkg::XLEN-1:0] sq_early_addr_repair_pair_base_2;
  logic [1:0] sq_early_addr_repair_half_match_2;
  logic [1:0][riscv_pkg::XLEN-1:0] sq_early_addr_repair_half_base_2;
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

    sq_early_addr_repair_pair_match_2[0] = |sq_early_addr_repair_cond_2[1:0];
    sq_early_addr_repair_pair_match_2[1] = |sq_early_addr_repair_cond_2[3:2];
    sq_early_addr_repair_pair_match_2[2] = |sq_early_addr_repair_cond_2[5:4];
    sq_early_addr_repair_pair_match_2[3] = |sq_early_addr_repair_cond_2[7:6];
    sq_early_addr_repair_pair_base_2[0] = sq_early_addr_repair_cond_2[0] ?
        done_repair_base_1_q : done_repair_base_2_q;
    sq_early_addr_repair_pair_base_2[1] = sq_early_addr_repair_cond_2[2] ?
        done_repair_base_3_q : done_repair_base_4_q;
    sq_early_addr_repair_pair_base_2[2] = sq_early_addr_repair_cond_2[4] ?
        done_repair_base_5_q : done_repair_base_6_q;
    sq_early_addr_repair_pair_base_2[3] = sq_early_addr_repair_cond_2[6] ?
        i_cdb.value[riscv_pkg::XLEN-1:0] :
        sq_early_addr_repair_cond_2[7] ? i_cdb_2.value[riscv_pkg::XLEN-1:0] : '0;

    sq_early_addr_repair_half_match_2[0] = |sq_early_addr_repair_pair_match_2[1:0];
    sq_early_addr_repair_half_match_2[1] = |sq_early_addr_repair_pair_match_2[3:2];
    sq_early_addr_repair_half_base_2[0] = sq_early_addr_repair_pair_match_2[0] ?
        sq_early_addr_repair_pair_base_2[0] : sq_early_addr_repair_pair_base_2[1];
    sq_early_addr_repair_half_base_2[1] = sq_early_addr_repair_pair_match_2[2] ?
        sq_early_addr_repair_pair_base_2[2] : sq_early_addr_repair_pair_base_2[3];

    sq_early_addr_repair_match_2 = |sq_early_addr_repair_half_match_2;
    sq_early_addr_repair_base_2 = sq_early_addr_repair_half_match_2[0] ?
        sq_early_addr_repair_half_base_2[0] : sq_early_addr_repair_half_base_2[1];
  end

  assign sq_early_addr_repair_fire_2 = sq_early_addr_repair_valid_2_q &&
                                       sq_early_addr_repair_match_2 &&
                                       !i_flush_all && !i_flush_en;

  // Slot-2 alloc-accepted gate, the room check of store_queue.sv's
  // slot2_alloc_en:
  //   slot2 alloc fires iff i_alloc_2.valid && (slot1_alloc_en ? !full_for_2 : !full)
  //   where slot1_alloc_en = i_alloc.valid && !full.
  // The SQ-full propagation through dispatch is already conservative, so this
  // is a redundant re-check, the same one slot-1 makes. It keeps an
  // early-addr update from being stamped for an entry the SQ refused to
  // allocate.
  logic slot2_sq_alloc_accepted;
  assign slot2_sq_alloc_accepted = sq_alloc_req_2.valid &&
                                   ((sq_alloc_req.valid && !o_sq_full) ?
                                    !o_sq_full_for_2 : !o_sq_full);

  // Repair hold state. A matched candidate whose SQ update port is taken by a
  // fresh (ready-base) update latches its repaired base in these registers and
  // sends it on the next free-port cycle.
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

  // A fresh update takes the slot's SQ port in its single emission cycle.
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

  // The adders run on registered inputs, off the dispatch critical path. The
  // six XLEN-wide address sums below are full width and unmasked. An
  // out-of-map store faults once MEM_RS issues it (at the wrapper's issue-time
  // PMA check, or from the data MMU under translation), so its entry never
  // drains, and downstream consumers only ever act on launched, in-map
  // addresses.
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

  // Classify each repair source in parallel with tag matching. Only bits
  // [31:30] select the MMIO quadrant, so each candidate needs a 32-bit sum.
  // The selected address remains full width; the kept flags prevent late
  // match/priority selection from moving back ahead of these adders.
  logic [7:0][31:0] repair_bases_low;
  logic [1:0][31:0] repair_immediates_low;
  logic [1:0][7:0] repair_conditions;
  logic [1:0][3:0] repair_pair_matches;
  logic [1:0][1:0] repair_half_matches;
  (* keep = "true" *) logic [1:0][7:0] repair_mmio_candidates;
  logic [1:0][3:0] repair_mmio_pairs;
  logic [1:0][1:0] repair_mmio_halves;
  logic [1:0] repair_is_mmio;
  assign repair_bases_low = {
    i_cdb_2.value[31:0],
    i_cdb.value[31:0],
    done_repair_base_6_q[31:0],
    done_repair_base_5_q[31:0],
    done_repair_base_4_q[31:0],
    done_repair_base_3_q[31:0],
    done_repair_base_2_q[31:0],
    done_repair_base_1_q[31:0]
  };
  assign repair_immediates_low = {
    sq_early_addr_repair_imm_2_q[31:0], sq_early_addr_repair_imm_q[31:0]
  };
  assign repair_conditions = {sq_early_addr_repair_cond_2, sq_early_addr_repair_cond};
  assign repair_pair_matches = {sq_early_addr_repair_pair_match_2, sq_early_addr_repair_pair_match};
  assign repair_half_matches = {sq_early_addr_repair_half_match_2, sq_early_addr_repair_half_match};
  for (genvar slot = 0; slot < 2; slot++) begin : gen_repair_mmio
    for (genvar source = 0; source < 8; source++) begin : gen_source
      logic [31:0] candidate_sum;
      assign candidate_sum = repair_bases_low[source] + repair_immediates_low[slot];
      assign repair_mmio_candidates[slot][source] = (candidate_sum[31:30] == 2'b01);
    end
    for (genvar pair = 0; pair < 3; pair++) begin : gen_pair
      assign repair_mmio_pairs[slot][pair] = repair_conditions[slot][2*pair] ?
          repair_mmio_candidates[slot][2*pair] : repair_mmio_candidates[slot][2*pair+1];
    end
    // With no matching source the base is zero, as in the address priority tree.
    assign repair_mmio_pairs[slot][3] = repair_conditions[slot][6] ?
        repair_mmio_candidates[slot][6] : repair_conditions[slot][7] ?
        repair_mmio_candidates[slot][7] : (repair_immediates_low[slot][31:30] == 2'b01);
    assign repair_mmio_halves[slot][0] = repair_pair_matches[slot][0] ?
        repair_mmio_pairs[slot][0] : repair_mmio_pairs[slot][1];
    assign repair_mmio_halves[slot][1] = repair_pair_matches[slot][2] ?
        repair_mmio_pairs[slot][2] : repair_mmio_pairs[slot][3];
    assign repair_is_mmio[slot] = repair_half_matches[slot][0] ?
        repair_mmio_halves[slot][0] : repair_mmio_halves[slot][1];
  end
`ifdef SQ_REPAIR_MMIO_LOCAL_PROOF
  always_comb begin
    p_repair_mmio_exact :
    assert (repair_is_mmio[0] == (sq_early_repair_effective_addr[31:30] == 2'b01));
    p_repair_mmio_2_exact :
    assert (repair_is_mmio[1] == (sq_early_repair_effective_addr_2[31:30] == 2'b01));
  end
`endif

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
      // cached (DDR) region is the 10 quadrant and must not be flagged.
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
      sq_early_addr_update.is_mmio = repair_is_mmio[0];
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
      sq_early_addr_update_2.is_mmio = repair_is_mmio[1];
    end
  end

  assign o_sq_early_addr_update = sq_early_addr_update;
  assign o_sq_early_addr_update_2 = sq_early_addr_update_2;
  assign o_sq_early_addr_capture_valid = sq_early_addr_valid_q ||
      sq_early_addr_repair_ready_q || sq_early_addr_repair_valid_q;
  assign o_sq_early_addr_capture_valid_2 = sq_early_addr_valid_2_q ||
      sq_early_addr_repair_ready_2_q || sq_early_addr_repair_valid_2_q;

`ifndef SYNTHESIS
  // For known inputs, the balanced tree equals the serial priority chain
  // below (the reference): simultaneous matches resolve as channel 1..6,
  // i_cdb, i_cdb_2, in that order. Reachable valid/tag inputs are known after
  // reset, so the checks sit under an $isunknown guard and skip four-state X
  // cases.
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

    if (!$isunknown(sq_early_addr_repair_cond)) begin
      p_repair_priority_exact :
      assert (sq_early_addr_repair_match == sq_early_addr_repair_match_reference &&
              (sq_early_addr_repair_base === sq_early_addr_repair_base_reference));
    end
    if (!$isunknown(sq_early_addr_repair_cond_2)) begin
      p_repair_priority_2_exact :
      assert (sq_early_addr_repair_match_2 == sq_early_addr_repair_match_2_reference &&
              (sq_early_addr_repair_base_2 === sq_early_addr_repair_base_2_reference));
    end
  end
`endif

endmodule
