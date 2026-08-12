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
// Pipelines the store effective-address computation: registers the dispatch
// base+imm for one cycle, then runs the XLEN-wide adder off the dispatch
// critical path (breaks the RAT -> ROB bypass -> dispatch -> adder -> SQ
// path).  Dual-ported (slot-1 / slot-2): each slot has its own register set,
// adders, repair snoop, and update packet to the store queue.
//
// PERSISTENT REPAIR: a store whose base register is not ready at dispatch
// becomes a repair candidate that WAITS for its base tag to complete — on
// the six dispatch-scoped done-repair channels (the already-done-at-dispatch
// case; matched one cycle after the channels pulse via the captured-channel
// registers below, i.e. the repair fires at dispatch+2 — see the TIMING
// comment at the capture) or on either live CDB lane (any later
// completion).  A matched
// candidate emits its SQ update combinationally when the slot's port is
// free, otherwise latches the repaired base and drains on the next free
// cycle.  Candidates are evicted by a newer un-ready store on the same
// slot (that store falls back to the MEM_RS address path, as all missed
// stores did before persistence), killed when MEM_RS issues their store
// (the issue delivers the address anyway, and the kill closes the
// ROB-tag-reuse window: a store cannot drain, and its tag cannot be
// reused, before MEM_RS issue delivers its data), and cleared on flush.
// =============================================================================
module sq_early_addr_pipeline (
    input logic i_clk,
    input logic i_rst_n,

    // Flush controls
    input logic i_flush_all,
    input logic i_flush_en,

    // Live CDB lanes (registered wrapper copies).  A HELD repair candidate's
    // base tag can complete any number of cycles after dispatch; the
    // dispatch-scoped done-repair channels below only pulse for
    // just-dispatched tags, so persistence needs the real completion buses.
    input riscv_pkg::cdb_broadcast_t i_cdb,
    input riscv_pkg::cdb_broadcast_t i_cdb_2,

    // MEM_RS issue tap: kills a candidate whose store is being issued (its
    // address arrives via i_addr_update, making the candidate redundant) —
    // and, critically, closes the ROB-tag-reuse window: a store cannot
    // drain (and its tag cannot be reused) before MEM_RS issue delivers its
    // data, so clearing here guarantees a stale candidate can never fire an
    // old address into a new same-tag store's entry.
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
    output riscv_pkg::sq_addr_update_t o_sq_early_addr_update_2
);

  // MMIO base (mirrors the tomasulo_wrapper localparam; identical constant).
  localparam logic [riscv_pkg::XLEN-1:0] MmioBase = 32'h4000_0000;

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
  // Breaks the 20-level RAT → ROB bypass → dispatch value → CARRY8 adder → SQ
  // critical path by deferring the XLEN-wide addition by one cycle.
  // Dual-ported.  Slot-1 and slot-2 each have their own
  // {valid, rob_tag, base, imm, repair_*}_q register set, their own adders, and
  // their own update packet to the SQ; SQ accepts both updates per cycle on
  // distinct rob_tags so there is no NBA collision.  Removes the slot-2 STORE
  // back-pressure that motivated `slot2_is_store_op` in instruction_aligner.sv.
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
  // TIMING: captured done-repair channels (x3 post-opt -0.118 rob_done -> SQ
  // address/is_mmio CE cone, 231 endpoints). done_repair_valid_N is a 32:1
  // read of the design-wide rob_entry_done fanout; resolving it, the priority
  // chain, the wrapper->SQ net AND the SQ's 8-entry CAM in one cycle was the
  // whole failing path. Capture each channel (valid+tag+base value) into
  // local registers the cycle the channels pulse, and match the candidates
  // against the CAPTURED copies one cycle later: the rob_done mux half now
  // ends at a local flop, and the priority/net/CAM half starts from local
  // flops. Functional cost: the base-already-done-at-dispatch repair fires at
  // dispatch+2 instead of dispatch+1 -- a one-cycle delay on the rare repair
  // fallback only. NO coverage gap: a base completing in (or after) the gap
  // cycle broadcasts on the live CDB lanes, which the match chains below
  // already snoop every cycle. Tag-pairing note: the captured tags travel
  // WITH their valid bits, so the one-cycle-later compare still pairs each
  // candidate with its own dispatch bundle's channels; a stale captured tag
  // cannot alias a new candidate (ROB tags cannot be reused within 2 cycles).
  // Channels captured during a flush cycle are zeroed for hygiene (their
  // candidate dies in the same flush anyway).
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
  always_comb begin
    sq_early_addr_repair_match = 1'b0;
    sq_early_addr_repair_base  = '0;
    if (done_repair_valid_1_q && sq_early_addr_repair_src1_tag_q == done_repair_tag_1_q) begin
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = done_repair_base_1_q;
    end else if (done_repair_valid_2_q &&
                 sq_early_addr_repair_src1_tag_q == done_repair_tag_2_q) begin
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = done_repair_base_2_q;
    end else if (done_repair_valid_3_q &&
                 sq_early_addr_repair_src1_tag_q == done_repair_tag_3_q) begin
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = done_repair_base_3_q;
    end else if (done_repair_valid_4_q &&
                 sq_early_addr_repair_src1_tag_q == done_repair_tag_4_q) begin
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = done_repair_base_4_q;
    end else if (done_repair_valid_5_q &&
                 sq_early_addr_repair_src1_tag_q == done_repair_tag_5_q) begin
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = done_repair_base_5_q;
    end else if (done_repair_valid_6_q &&
                 sq_early_addr_repair_src1_tag_q == done_repair_tag_6_q) begin
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = done_repair_base_6_q;
    end else if (i_cdb.valid && sq_early_addr_repair_src1_tag_q == i_cdb.tag) begin
      // Live-lane snoop: the held candidate's base completing on the CDB,
      // any number of cycles after dispatch (the captured channels above only
      // cover the already-done-at-dispatch case, one cycle later).
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = i_cdb.value[riscv_pkg::XLEN-1:0];
    end else if (i_cdb_2.valid && sq_early_addr_repair_src1_tag_q == i_cdb_2.tag) begin
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = i_cdb_2.value[riscv_pkg::XLEN-1:0];
    end
  end

  assign sq_early_addr_repair_fire = sq_early_addr_repair_valid_q &&
                                     sq_early_addr_repair_match &&
                                     !i_flush_all && !i_flush_en;

  // Slot-2 repair match — snoops the same six done-repair channels and
  // both live CDB lanes.  Both
  // slots can independently match on the same broadcast tag in the rare case
  // where both stores rename to the same source tag (e.g. both stores read the
  // same arch reg with no intervening write); each computes its own address
  // because base is shared but imm differs.
  logic sq_early_addr_repair_match_2;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_repair_base_2;
  logic sq_early_addr_repair_fire_2;
  always_comb begin
    sq_early_addr_repair_match_2 = 1'b0;
    sq_early_addr_repair_base_2  = '0;
    if (done_repair_valid_1_q && sq_early_addr_repair_src1_tag_2_q == done_repair_tag_1_q) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = done_repair_base_1_q;
    end else if (done_repair_valid_2_q &&
                 sq_early_addr_repair_src1_tag_2_q == done_repair_tag_2_q) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = done_repair_base_2_q;
    end else if (done_repair_valid_3_q &&
                 sq_early_addr_repair_src1_tag_2_q == done_repair_tag_3_q) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = done_repair_base_3_q;
    end else if (done_repair_valid_4_q &&
                 sq_early_addr_repair_src1_tag_2_q == done_repair_tag_4_q) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = done_repair_base_4_q;
    end else if (done_repair_valid_5_q &&
                 sq_early_addr_repair_src1_tag_2_q == done_repair_tag_5_q) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = done_repair_base_5_q;
    end else if (done_repair_valid_6_q &&
                 sq_early_addr_repair_src1_tag_2_q == done_repair_tag_6_q) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = done_repair_base_6_q;
    end else if (i_cdb.valid && sq_early_addr_repair_src1_tag_2_q == i_cdb.tag) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = i_cdb.value[riscv_pkg::XLEN-1:0];
    end else if (i_cdb_2.valid && sq_early_addr_repair_src1_tag_2_q == i_cdb_2.tag) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = i_cdb_2.value[riscv_pkg::XLEN-1:0];
    end
  end

  assign sq_early_addr_repair_fire_2 = sq_early_addr_repair_valid_2_q &&
                                       sq_early_addr_repair_match_2 &&
                                       !i_flush_all && !i_flush_en;

  // Slot-2 alloc-accepted gate mirrors store_queue.sv slot2_alloc_en logic:
  //   slot2 alloc fires iff i_alloc_2.valid && (slot1_alloc_en ? !full_for_2 : !full)
  //   where slot1_alloc_en = i_alloc.valid && !full.
  // The SQ-full propagation through dispatch is already conservative, so this
  // mirrors the slot-1 belt-and-suspenders pattern; it ensures we never stamp
  // an early-addr update for an entry the SQ refused to allocate.
  logic slot2_sq_alloc_accepted;
  assign slot2_sq_alloc_accepted = sq_alloc_req_2.valid &&
                                   ((sq_alloc_req.valid && !o_sq_full) ?
                                    !o_sq_full_for_2 : !o_sq_full);

  // Persistent-repair state (Session: early-addr coverage).  A repair
  // candidate now WAITS until its base tag completes (dispatch channels or
  // live CDB lanes), is evicted by a newer un-ready store on the same slot,
  // is killed by MEM_RS issuing its store, or is flushed.  A matched
  // candidate whose SQ update port is taken by a fresh (ready-base) update
  // latches its repaired base and drains on the next free-port cycle.
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

      // Slot-2 — same structure.
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

  // Adder now runs on registered inputs — off the dispatch critical path.
  // All six store-AGU adder outputs are canonicalized to the physical
  // address space (identity at XLEN=32 - plan decision D3).
  logic [riscv_pkg::XLEN-1:0] sq_early_effective_addr;
  logic [riscv_pkg::XLEN-1:0] sq_early_repair_effective_addr;
  assign sq_early_effective_addr = riscv_pkg::canonical_paddr(
      sq_early_addr_base_q + sq_early_addr_imm_q
  );
  assign sq_early_repair_effective_addr = riscv_pkg::canonical_paddr(
      sq_early_addr_repair_base + sq_early_addr_repair_imm_q
  );

  // Slot-2 adder
  logic [riscv_pkg::XLEN-1:0] sq_early_effective_addr_2;
  logic [riscv_pkg::XLEN-1:0] sq_early_repair_effective_addr_2;
  assign sq_early_effective_addr_2 = riscv_pkg::canonical_paddr(
      sq_early_addr_base_2_q + sq_early_addr_imm_2_q
  );
  assign sq_early_repair_effective_addr_2 = riscv_pkg::canonical_paddr(
      sq_early_addr_repair_base_2 + sq_early_addr_repair_imm_2_q
  );

  // Held-candidate adders: run on the latched repaired base (registered), so
  // the drain path stays off the CDB/bypass comb cone.
  logic [riscv_pkg::XLEN-1:0] sq_early_hold_effective_addr;
  logic [riscv_pkg::XLEN-1:0] sq_early_hold_effective_addr_2;
  assign sq_early_hold_effective_addr = riscv_pkg::canonical_paddr(
      sq_early_addr_repair_base_hold_q + sq_early_addr_repair_imm_q
  );
  assign sq_early_hold_effective_addr_2 = riscv_pkg::canonical_paddr(
      sq_early_addr_repair_base_hold_2_q + sq_early_addr_repair_imm_2_q
  );

  // Port arbitration: a fresh (ready-base) update is single-cycle perishable
  // and always wins; a just-matched candidate emits combinationally only on
  // a free cycle (otherwise it latches into the hold registers); a held
  // candidate drains on the next free cycle.  ready and waiting are
  // exclusive states, so the last two arms never contend.
  riscv_pkg::sq_addr_update_t sq_early_addr_update;
  always_comb begin
    sq_early_addr_update = '0;
    if (sq_early_addr_valid_q) begin
      sq_early_addr_update.valid   = 1'b1;
      sq_early_addr_update.rob_tag = sq_early_addr_rob_tag_q;
      sq_early_addr_update.address = sq_early_effective_addr;
      // MMIO = the 01 address quadrant [0x4000_0000, 0x8000_0000). The cached
      // (DDR) region is the 10 quadrant and must NOT be flagged -- the old
      // ">= MmioBase" shortcut predates the cached tier.
      sq_early_addr_update.is_mmio = (sq_early_effective_addr[31:30] == 2'b01);
    end else if (sq_early_addr_repair_ready_q) begin
      sq_early_addr_update.valid   = 1'b1;
      sq_early_addr_update.rob_tag = sq_early_addr_repair_rob_tag_q;
      sq_early_addr_update.address = sq_early_hold_effective_addr;
      sq_early_addr_update.is_mmio = (sq_early_hold_effective_addr[31:30] == 2'b01);
    end else if (sq_early_addr_repair_fire) begin
      sq_early_addr_update.valid   = 1'b1;
      sq_early_addr_update.rob_tag = sq_early_addr_repair_rob_tag_q;
      sq_early_addr_update.address = sq_early_repair_effective_addr;
      sq_early_addr_update.is_mmio = (sq_early_repair_effective_addr[31:30] == 2'b01);
    end
  end

  // Slot-2 packet — same arbitration.
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
    end else if (sq_early_addr_repair_fire_2) begin
      sq_early_addr_update_2.valid   = 1'b1;
      sq_early_addr_update_2.rob_tag = sq_early_addr_repair_rob_tag_2_q;
      sq_early_addr_update_2.address = sq_early_repair_effective_addr_2;
      sq_early_addr_update_2.is_mmio = (sq_early_repair_effective_addr_2[31:30] == 2'b01);
    end
  end

  // Drive the output ports from the body's local update packets.
  assign o_sq_early_addr_update   = sq_early_addr_update;
  assign o_sq_early_addr_update_2 = sq_early_addr_update_2;

endmodule
