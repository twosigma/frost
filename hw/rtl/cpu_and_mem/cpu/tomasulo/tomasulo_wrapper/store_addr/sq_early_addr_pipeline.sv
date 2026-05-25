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
// Extracted verbatim from tomasulo_wrapper.sv (pure RTL boundary move, zero
// functional change).  Pipelines the store effective-address computation:
// registers the dispatch base+imm for one cycle, then runs the 32-bit adder off
// the dispatch critical path (breaks the RAT -> ROB bypass -> dispatch -> adder
// -> SQ path).  Dual-ported (slot-1 / slot-2): each slot has its own register
// set, adders, CDB repair snoop, and update packet to the store queue.
// =============================================================================
module sq_early_addr_pipeline (
    input logic i_clk,
    input logic i_rst_n,

    // Flush controls
    input logic i_flush_all,
    input logic i_flush_en,

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
  // critical path by deferring the 32-bit addition by one cycle.
  // Session L: dual-ported.  Slot-1 and slot-2 each have their own
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

  // Slot-2 mirror (Session L)
  logic sq_early_addr_valid_2_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sq_early_addr_rob_tag_2_q;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_base_2_q;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_imm_2_q;
  logic sq_early_addr_repair_valid_2_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sq_early_addr_repair_rob_tag_2_q;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] sq_early_addr_repair_src1_tag_2_q;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_repair_imm_2_q;

  logic sq_early_addr_repair_match;
  logic [riscv_pkg::XLEN-1:0] sq_early_addr_repair_base;
  logic sq_early_addr_repair_fire;
  always_comb begin
    sq_early_addr_repair_match = 1'b0;
    sq_early_addr_repair_base  = '0;
    if (done_repair_valid_1 && sq_early_addr_repair_src1_tag_q == i_bypass_tag_1) begin
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = bypass_value_1[riscv_pkg::XLEN-1:0];
    end else if (done_repair_valid_2 && sq_early_addr_repair_src1_tag_q == i_bypass_tag_2) begin
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = bypass_value_2[riscv_pkg::XLEN-1:0];
    end else if (done_repair_valid_3 && sq_early_addr_repair_src1_tag_q == i_bypass_tag_3) begin
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = bypass_value_3[riscv_pkg::XLEN-1:0];
    end else if (done_repair_valid_4 && sq_early_addr_repair_src1_tag_q == i_bypass_tag_4) begin
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = bypass_value_4[riscv_pkg::XLEN-1:0];
    end else if (done_repair_valid_5 && sq_early_addr_repair_src1_tag_q == i_bypass_tag_5) begin
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = bypass_value_5[riscv_pkg::XLEN-1:0];
    end else if (done_repair_valid_6 && sq_early_addr_repair_src1_tag_q == i_bypass_tag_6) begin
      sq_early_addr_repair_match = 1'b1;
      sq_early_addr_repair_base  = bypass_value_6[riscv_pkg::XLEN-1:0];
    end
  end

  assign sq_early_addr_repair_fire = sq_early_addr_repair_valid_q &&
                                     sq_early_addr_repair_match &&
                                     !i_flush_all && !i_flush_en;

  // Slot-2 repair match — snoops the same 3 CDB channels (Session L).  Both
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
    if (done_repair_valid_1 && sq_early_addr_repair_src1_tag_2_q == i_bypass_tag_1) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = bypass_value_1[riscv_pkg::XLEN-1:0];
    end else if (done_repair_valid_2 && sq_early_addr_repair_src1_tag_2_q == i_bypass_tag_2) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = bypass_value_2[riscv_pkg::XLEN-1:0];
    end else if (done_repair_valid_3 && sq_early_addr_repair_src1_tag_2_q == i_bypass_tag_3) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = bypass_value_3[riscv_pkg::XLEN-1:0];
    end else if (done_repair_valid_4 && sq_early_addr_repair_src1_tag_2_q == i_bypass_tag_4) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = bypass_value_4[riscv_pkg::XLEN-1:0];
    end else if (done_repair_valid_5 && sq_early_addr_repair_src1_tag_2_q == i_bypass_tag_5) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = bypass_value_5[riscv_pkg::XLEN-1:0];
    end else if (done_repair_valid_6 && sq_early_addr_repair_src1_tag_2_q == i_bypass_tag_6) begin
      sq_early_addr_repair_match_2 = 1'b1;
      sq_early_addr_repair_base_2  = bypass_value_6[riscv_pkg::XLEN-1:0];
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

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all || i_flush_en) begin
      sq_early_addr_valid_q <= 1'b0;
      sq_early_addr_repair_valid_q <= 1'b0;
      sq_early_addr_valid_2_q <= 1'b0;
      sq_early_addr_repair_valid_2_q <= 1'b0;
    end else begin
      sq_early_addr_valid_q <= sq_alloc_req.valid && !o_sq_full && mem_rs_dispatch.src1_ready;
      sq_early_addr_rob_tag_q <= mem_rs_dispatch.rob_tag;
      sq_early_addr_base_q <= mem_rs_dispatch.src1_value[riscv_pkg::XLEN-1:0];
      sq_early_addr_imm_q <= mem_rs_dispatch.imm;

      sq_early_addr_repair_valid_q <= sq_alloc_req.valid &&
                                      !o_sq_full &&
                                      !mem_rs_dispatch.src1_ready;
      sq_early_addr_repair_rob_tag_q <= mem_rs_dispatch.rob_tag;
      sq_early_addr_repair_src1_tag_q <= mem_rs_dispatch.src1_tag;
      sq_early_addr_repair_imm_q <= mem_rs_dispatch.imm;

      // Slot-2 (Session L)
      sq_early_addr_valid_2_q <= slot2_sq_alloc_accepted && mem_rs_dispatch_2.src1_ready;
      sq_early_addr_rob_tag_2_q <= mem_rs_dispatch_2.rob_tag;
      sq_early_addr_base_2_q <= mem_rs_dispatch_2.src1_value[riscv_pkg::XLEN-1:0];
      sq_early_addr_imm_2_q <= mem_rs_dispatch_2.imm;

      sq_early_addr_repair_valid_2_q <= slot2_sq_alloc_accepted && !mem_rs_dispatch_2.src1_ready;
      sq_early_addr_repair_rob_tag_2_q <= mem_rs_dispatch_2.rob_tag;
      sq_early_addr_repair_src1_tag_2_q <= mem_rs_dispatch_2.src1_tag;
      sq_early_addr_repair_imm_2_q <= mem_rs_dispatch_2.imm;
    end
  end

  // Adder now runs on registered inputs — off the dispatch critical path
  logic [riscv_pkg::XLEN-1:0] sq_early_effective_addr;
  logic [riscv_pkg::XLEN-1:0] sq_early_repair_effective_addr;
  assign sq_early_effective_addr = sq_early_addr_base_q + sq_early_addr_imm_q;
  assign sq_early_repair_effective_addr = sq_early_addr_repair_base + sq_early_addr_repair_imm_q;

  // Slot-2 adder (Session L)
  logic [riscv_pkg::XLEN-1:0] sq_early_effective_addr_2;
  logic [riscv_pkg::XLEN-1:0] sq_early_repair_effective_addr_2;
  assign sq_early_effective_addr_2 = sq_early_addr_base_2_q + sq_early_addr_imm_2_q;
  assign sq_early_repair_effective_addr_2 = sq_early_addr_repair_base_2 +
                                            sq_early_addr_repair_imm_2_q;

  riscv_pkg::sq_addr_update_t sq_early_addr_update;
  always_comb begin
    sq_early_addr_update = '0;
    if (sq_early_addr_repair_fire) begin
      sq_early_addr_update.valid   = 1'b1;
      sq_early_addr_update.rob_tag = sq_early_addr_repair_rob_tag_q;
      sq_early_addr_update.address = sq_early_repair_effective_addr;
      sq_early_addr_update.is_mmio = (sq_early_repair_effective_addr >= MmioBase);
    end else begin
      sq_early_addr_update.valid   = sq_early_addr_valid_q;
      sq_early_addr_update.rob_tag = sq_early_addr_rob_tag_q;
      sq_early_addr_update.address = sq_early_effective_addr;
      sq_early_addr_update.is_mmio = (sq_early_effective_addr >= MmioBase);
    end
  end

  // Slot-2 packet (Session L)
  riscv_pkg::sq_addr_update_t sq_early_addr_update_2;
  always_comb begin
    sq_early_addr_update_2 = '0;
    if (sq_early_addr_repair_fire_2) begin
      sq_early_addr_update_2.valid   = 1'b1;
      sq_early_addr_update_2.rob_tag = sq_early_addr_repair_rob_tag_2_q;
      sq_early_addr_update_2.address = sq_early_repair_effective_addr_2;
      sq_early_addr_update_2.is_mmio = (sq_early_repair_effective_addr_2 >= MmioBase);
    end else begin
      sq_early_addr_update_2.valid   = sq_early_addr_valid_2_q;
      sq_early_addr_update_2.rob_tag = sq_early_addr_rob_tag_2_q;
      sq_early_addr_update_2.address = sq_early_effective_addr_2;
      sq_early_addr_update_2.is_mmio = (sq_early_effective_addr_2 >= MmioBase);
    end
  end

  // Drive the output ports from the body's local update packets.
  assign o_sq_early_addr_update   = sq_early_addr_update;
  assign o_sq_early_addr_update_2 = sq_early_addr_update_2;

endmodule
