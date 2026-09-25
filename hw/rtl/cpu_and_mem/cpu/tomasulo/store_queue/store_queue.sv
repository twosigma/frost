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
 * Store queue with store-to-load forwarding. DEPTH ring entries allocate at the
 * tail in program order. An entry receives its address and data, commits with
 * the ROB, writes memory as one 64-bit beat, and frees when the write completes.
 * Writes launch in program order and only after commit, and each launch
 * invalidates the store's line in the LQ's L0 cache. A partial flush removes
 * uncommitted entries younger than the flush point. A full flush empties the
 * queue, committed entries included, so its sources first wait for
 * o_committed_empty.
 */

module store_queue #(
    parameter int unsigned DEPTH = riscv_pkg::SqDepth,  // 8
    // Trust dispatch's alloc valids to already include SQ room.  Dispatch gates
    // its per-slot mem valids on the registered conservative flags
    // (o_dispatch_full/_for_2), which give no credit for a slot freed in the
    // same cycle, so !dispatch_full_q implies live !full.  The local
    // !full/!full_for_2 re-checks below are then redundant and only lengthen
    // the allocation cones into live_count_q and sq_valid.
    parameter bit TRUST_DISPATCH_VALID = 1'b0,
    // Cached memory tier (high-address region). A committed store whose address
    // falls in [CACHED_BASE, CACHED_BASE+CACHED_SIZE_BYTES) is tagged so the router
    // steers its byte-write enables to the cached tier (and masks them off the
    // BRAM). The flag is registered alongside o_mem_write_en, mirroring is_mmio,
    // so the late address-range test never reaches the BRAM WEA cone.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter int unsigned CACHED_SIZE_BYTES = 32'h4000_0000
) (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Allocation (from Dispatch, parallel with MEM_RS dispatch)
    // =========================================================================
    input  riscv_pkg::sq_alloc_req_t i_alloc,
    // Slot-2 allocation port for 2-wide dispatch.  Slot-2 valid does not
    // require slot-1 valid: dispatch derives each from its own slot's
    // mem_needs_sq, so a bundle whose only store is slot-2 is legal.  When
    // both fire, slot-1 is older and takes the earlier ring position, so the
    // in-order drain writes the two stores to memory in program order.
    input  riscv_pkg::sq_alloc_req_t i_alloc_2,
    output logic                     o_full,
    // Asserted when there is room for at most 1 more entry (a 2-wide bundle of
    // two stores would not fit).  Distinct from o_full so dispatch can
    // independently gate slot-2.
    output logic                     o_full_for_2,
    // Registered back-pressure for the CPU dispatch path.  Both update on
    // the same edge as the valid mask and are conservative: a reclaim that
    // lands on that edge is reflected one cycle later (see the dispatch
    // back-pressure register below).  The exact o_full/o_full_for_2 remain
    // available for local visibility and direct queue allocation.
    output logic                     o_dispatch_full,
    output logic                     o_dispatch_full_for_2,

    // =========================================================================
    // Early Address Update (from pipelined dispatch-time address computation)
    // =========================================================================
    // Dual-ported.  Slot-1 and slot-2 each have their own
    // pipelined-early-addr stage in tomasulo_wrapper, so two distinct
    // rob_tags can update sq_addr_valid + sq_address in the same cycle.
    // The CAM scans below run independently: each finds at most one match
    // by rob_tag, and the two updates always carry distinct rob_tags
    // (different ROB entries), so the NBA writes never collide on a bit.
    input riscv_pkg::sq_addr_update_t i_early_addr_update,
    input riscv_pkg::sq_addr_update_t i_early_addr_update_2,
    // Payload-only enables for persistent early-address repair. They may
    // refresh address/is_mmio while packet.valid is low; sq_addr_valid remains
    // the visibility control and is set only by packet.valid below.
    input logic i_early_addr_capture_valid,
    input logic i_early_addr_capture_valid_2,

    // =========================================================================
    // Address Update (from MEM_RS issue path: base + imm, pre-computed)
    // =========================================================================
    input riscv_pkg::sq_addr_update_t i_addr_update,
    // Payload-only capture enable.  This may remain asserted for a faulted
    // store whose i_addr_update.valid is clear: sq_addr_valid is the
    // architectural visibility bit, so writing the still-hidden address is
    // harmless and keeps fault classification off the wide payload enables.
    input logic i_addr_update_capture_valid,

    // =========================================================================
    // Data Update (from MEM_RS issue path: src2_value)
    // =========================================================================
    input riscv_pkg::sq_data_update_t i_data_update,
    // Payload counterpart of i_addr_update_capture_valid.  The control block
    // below sets sq_data_valid only from i_data_update.valid.
    input logic i_data_update_capture_valid,

    // =========================================================================
    // Commit (from ROB commit bus, filtered for stores)
    // =========================================================================
    input logic                                        i_commit_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag,

    // Combinational store-commit pulses straight from the ROB (unregistered).
    // They only clear committed_empty early (see Committed-empty below).  The
    // ROB never raises them in a flush cycle (asserted below), so the
    // partial-flush kill needs no guard for them.
    input logic i_commit_valid_comb,

    // Commit slot 2 (2-wide commit): a second store retiring in the same
    // cycle.  The ROB retires SC/AMO/LR/fence only alone from the head, so
    // the SC-discard path is not shared with slot 2.  Both a registered and
    // a combinational variant parallel slot 1's.
    input logic                                        i_commit_valid_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag_2,
    input logic                                        i_commit_valid_comb_2,

    // Trap-cone-free commit pulses for the forwarding scan only (same tags as
    // i_commit_valid/_2).  They are i_commit_valid/_2 with the full-flush
    // mask (the registered trap/MRET/FENCE-class pulse) omitted, which keeps
    // the trap cone off the o_sq_forward capture D-pins.  They differ from
    // the architectural pulses only on the full-flush cycle, where the
    // captured probe result can never be consumed (capture-then-kill:
    // o_sq_check_valid is flush-gated, sq_check_phase2 clears, and every
    // consumer requires phase 2).  The architectural consumers (sq_committed,
    // committed_empty, flush_kill exemption) use the masked pulses: a
    // squashed store must not latch committed state.
    input logic i_commit_valid_scan,
    input logic i_commit_valid_scan_2,

    // =========================================================================
    // Store-to-Load Forwarding (from LQ disambiguation)
    // =========================================================================
    // The LQ's probe valid without its flush and commit-block terms; it
    // enables only the forwarding unit's output register (see
    // load_queue.o_sq_check_capture_valid).
    input logic i_sq_check_capture_valid,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr,
    // Three copies of the same address driven by dont_touch'd LQ-side
    // replica registers. Together with the primary, these feed entries
    // 0..1 / 2..3 / 4..5 / 6..7 so each two-entry CAM quarter has its own
    // physical anchor. All four values are functionally identical.
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_b,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_c,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_d,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_sq_check_rob_tag,
    input riscv_pkg::mem_size_e i_sq_check_size,
    output logic o_sq_all_older_addrs_known,
    output riscv_pkg::sq_forward_result_t o_sq_forward,

    // =========================================================================
    // Memory Write Interface (to data memory bus)
    // =========================================================================
    output logic                              o_mem_write_en,
    output logic [       riscv_pkg::XLEN-1:0] o_mem_write_addr,
    output logic [riscv_pkg::MemDataBits-1:0] o_mem_write_data,
    output logic [riscv_pkg::MemStrbBits-1:0] o_mem_write_byte_en,
    // Registered MMIO flag of the write on the bus. Consumers at the
    // top level use this to gate the BRAM byte-write-enable at the SQ source
    // rather than recomputing an address-range check combinationally on the
    // muxed data memory address (which drags the LQ issue cone onto WEA).
    output logic                              o_mem_write_is_mmio,
    // Registered cached-tier flag of the write on the bus (parallels is_mmio).
    // The router steers the store's byte-write enables to the cached tier when set.
    output logic                              o_mem_write_is_cached,
    input  logic                              i_mem_write_done,

    // =========================================================================
    // L0 Cache Invalidation (to LQ)
    // =========================================================================
    output logic                       o_cache_invalidate_valid,
    output logic [riscv_pkg::XLEN-1:0] o_cache_invalidate_addr,

    // =========================================================================
    // ROB Head Tag (for age comparisons)
    // =========================================================================
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,

    // =========================================================================
    // Flush
    // =========================================================================
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic                                        i_flush_all,
    input logic                                        i_flush_after_head_commit,

    // =========================================================================
    // SC Discard (from ROB commit: failed SC invalidates its SQ entry)
    // =========================================================================
    input logic                                        i_sc_discard,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_sc_discard_rob_tag,

    // =========================================================================
    // Status
    // =========================================================================
    // Exact registered live status. Both change on the same edge as sq_valid;
    // the dispatch aliases exist for interface symmetry with registered full.
    output logic                       o_empty,
    output logic                       o_dispatch_empty,
    output logic                       o_committed_empty,  // No committed entries pending write
    output logic [$clog2(DEPTH+1)-1:0] o_count,
    output logic [$clog2(DEPTH+1)-1:0] o_dispatch_count
);

  // ===========================================================================
  // Local Parameters
  // ===========================================================================
  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned IdxWidth = $clog2(DEPTH);
  localparam int unsigned PtrWidth = IdxWidth + 1;  // Extra MSB for full/empty
  localparam int unsigned CountWidth = $clog2(DEPTH + 1);
  localparam int unsigned MemSizeWidth = 2;

  // ===========================================================================
  // Helper Functions
  // ===========================================================================

  // Check if entry_tag is younger than flush_tag (relative to rob_head)
  function automatic logic is_younger(input logic [ReorderBufferTagWidth-1:0] entry_tag,
                                      input logic [ReorderBufferTagWidth-1:0] flush_tag,
                                      input logic [ReorderBufferTagWidth-1:0] head);
    logic [ReorderBufferTagWidth:0] entry_age;
    logic [ReorderBufferTagWidth:0] flush_age;
    begin
      entry_age  = {1'b0, entry_tag} - {1'b0, head};
      flush_age  = {1'b0, flush_tag} - {1'b0, head};
      is_younger = entry_age > flush_age;
    end
  endfunction

  // Check if store_tag is older than load_tag (relative to rob_head),
  // i.e. the store precedes the load in program order.
  function automatic logic is_older_than(input logic [ReorderBufferTagWidth-1:0] store_tag,
                                         input logic [ReorderBufferTagWidth-1:0] load_tag,
                                         input logic [ReorderBufferTagWidth-1:0] head);
    logic [ReorderBufferTagWidth:0] store_age;
    logic [ReorderBufferTagWidth:0] load_age;
    begin
      store_age     = {1'b0, store_tag} - {1'b0, head};
      load_age      = {1'b0, load_tag} - {1'b0, head};
      is_older_than = store_age < load_age;
    end
  endfunction

  // Generate byte-enable mask from address offset and size
  function automatic logic [riscv_pkg::MemStrbBits-1:0] gen_byte_en(
      input logic [2:0] addr_offset, input riscv_pkg::mem_size_e size);
    begin
      // 8-lane strobes on the aligned-dword beat (hw/rtl/README.md, "Data-tier bus contract");
      // the mem_size_e encoding matches the helper's 2-bit size argument.
      gen_byte_en = riscv_pkg::mem_strobe_for(2'(size), addr_offset);
    end
  endfunction

  // Generate write data with correct byte-lane positioning: sub-beat sizes
  // replicate across the beat (the strobes select the addressed lanes),
  // doubles pass through single-beat.
  function automatic logic [riscv_pkg::MemDataBits-1:0] gen_write_data(
      input logic [FLEN-1:0] data, input riscv_pkg::mem_size_e size);
    begin
      case (size)
        riscv_pkg::MEM_SIZE_BYTE:   gen_write_data = {8{data[7:0]}};
        riscv_pkg::MEM_SIZE_HALF:   gen_write_data = {4{data[15:0]}};
        riscv_pkg::MEM_SIZE_WORD:   gen_write_data = {2{data[31:0]}};
        riscv_pkg::MEM_SIZE_DOUBLE: gen_write_data = data[63:0];
        default:                    gen_write_data = '0;
      endcase
    end
  endfunction

  // ===========================================================================
  // Storage -- Circular buffer with FF-based arrays
  // ===========================================================================

  // Head and tail pointers (extra MSB for full/empty distinction)
  logic                 [             PtrWidth-1:0] head_ptr;
  logic                 [             PtrWidth-1:0] tail_ptr;

  // Index extraction (lower bits)
  wire                  [             IdxWidth-1:0] head_idx = head_ptr[IdxWidth-1:0];
  // Per-entry 1-bit flags (packed vectors for bulk operations)
  logic                 [                DEPTH-1:0] sq_valid;
  logic                 [                DEPTH-1:0] sq_addr_valid;
  logic                 [                DEPTH-1:0] sq_data_valid;
  logic                 [                DEPTH-1:0] sq_is_mmio;
  logic                 [                DEPTH-1:0] sq_committed;
  logic                 [                DEPTH-1:0] sq_sent;
  logic                 [                DEPTH-1:0] sq_is_sc;

  // Per-entry multi-bit fields
  logic                 [ReorderBufferTagWidth-1:0] sq_rob_tag                        [DEPTH];
  logic                 [                 XLEN-1:0] sq_address                        [DEPTH];
  riscv_pkg::mem_size_e                             sq_size                           [DEPTH];

  // ===========================================================================
  // sq_data storage
  // ===========================================================================
  // sq_data is written on a data_update CAM match only while the entry's
  // sq_data_valid is clear, so a visible payload never changes.  The drain
  // side reads it at drain_idx_q.  Store-to-load forwarding mirrors the same
  // payload into per-entry registers.  The forwarding unit registers the
  // winning index and selects this mirror during the following LQ consume
  // cycle, so the CAM / winner tree does not drive 64 output-register D-pins.
  // Valid bits in FFs gate all reads; alloc-time zeroing is unnecessary.

  // Write port: resolved CAM match index from data_update
  logic                                             sq_data_we;
  logic                 [             IdxWidth-1:0] sq_data_wr_idx;

  always_comb begin
    sq_data_we     = 1'b0;
    sq_data_wr_idx = '0;
    // A full flush clears the entry-valid state in the control array on this
    // edge.  Let a coincident completion update the now-dead payload anyway;
    // keeping i_flush_all out of this wide mirror/RAM write enable removes
    // the global recovery net without changing any observable queue state.
    if (i_data_update_capture_valid && i_rst_n) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (sq_valid[i] && !sq_data_valid[i] && sq_rob_tag[i] == i_data_update.rob_tag) begin
          sq_data_we     = 1'b1;
          sq_data_wr_idx = IdxWidth'(i);
        end
      end
    end
  end

  // Read outputs
  logic [IdxWidth-1:0] drain_idx_q;  // drain cursor (see Drain Cursor below)
  logic [FLEN-1:0] sq_data_drain_rd;  // read at drain_idx_q (drain cursor)

  logic [FLEN-1:0] sq_data_fwd_entry[DEPTH];
  logic [(DEPTH*FLEN)-1:0] sq_data_fwd_flat;

  initial for (int i = 0; i < DEPTH; i++) sq_data_fwd_entry[i] = '0;

  always_ff @(posedge i_clk) begin
    if (sq_data_we) begin
      sq_data_fwd_entry[sq_data_wr_idx] <= i_data_update.data;
    end
  end

  for (genvar i = 0; i < DEPTH; i++) begin : gen_sq_data_fwd_flat
    assign sq_data_fwd_flat[i*FLEN+:FLEN] = sq_data_fwd_entry[i];
  end

  sdp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH(FLEN)
  ) u_sq_data_drain (
      .i_clk,
      .i_write_enable (sq_data_we),
      .i_write_address(sq_data_wr_idx),
      .i_write_data   (i_data_update.data),
      // Drain-side read: addressed by the drain cursor (the entry the next
      // memory write will launch from), not the freed-at-done head.
      .i_read_address (drain_idx_q),
      .o_read_data    (sq_data_drain_rd)
  );

  // ===========================================================================
  // Internal Signals
  // ===========================================================================

  logic                  full;
  logic                  full_for_2;
  logic                  empty;
  // Same fanout cap as the reservation stations' dispatch_full_q: the
  // registered backpressure bit rides the dispatch stall tree into
  // RAT/ROB/front-end write gating across the die.
  (* max_fanout = 32 *)logic                  dispatch_full_q;
  (* max_fanout = 32 *)logic                  dispatch_full_for_2_q;
  // Exact live-entry count, maintained from the same accepted allocation and
  // removal events that update sq_valid, on the same edge, so empty adds no
  // queue or issue cycle.  It is a timing boundary: LQ issue consumes empty,
  // and deriving empty from the sq_valid popcount would put every SQ valid
  // bit in the cache-read launch cone.
  (* keep = "true" *)logic [CountWidth-1:0] live_count_q;
  logic [CountWidth-1:0] live_count_next;
  logic [CountWidth-1:0] live_remove_count;
  logic [     DEPTH-1:0] live_remove_mask;
  logic [     DEPTH-1:0] sc_discard_remove_mask;
  logic                  drain_remove_valid;
  logic                  committed_empty_q;
  // TIMING: the two dispatch valids arrive last, through the dispatch fire
  // tree (queue valid -> bundle_fire_ok -> mem_rs_dispatch_valid), so they
  // must not be adder operands ahead of the live_count_q / dispatch_full*_q
  // D pins.  Each counter is instead evaluated once per allocation outcome
  // from request-independent terms (the window or live count, the removal
  // count, and the room terms), and the pair of valids is the final select.
  // Exactly one request takes alloc_room_1 whichever slot carries it; a pair
  // adds alloc_room_2, the slot-1-present arm of slot2_alloc_en.  Kept as
  // nets so the select stays the last level.  Simulation and formal compare
  // the selected value with a reference adder form.
  (* keep = "true" *)logic [CountWidth-1:0] live_count_if_none;
  (* keep = "true" *)logic [CountWidth-1:0] live_count_if_one;
  (* keep = "true" *)logic [CountWidth-1:0] live_count_if_both;
  (* keep = "true" *)logic [CountWidth-1:0] live_count_alloc_one;
  (* keep = "true" *)logic [CountWidth-1:0] live_count_alloc_both;

  logic [CountWidth-1:0] dispatch_count_if_none;
  logic [CountWidth-1:0] dispatch_count_if_one;
  logic [CountWidth-1:0] dispatch_count_if_both;
  (* keep = "true" *)logic                  dispatch_full_if_none;
  (* keep = "true" *)logic                  dispatch_full_if_one;
  (* keep = "true" *)logic                  dispatch_full_if_both;
  (* keep = "true" *)logic                  dispatch_full_for_2_if_none;
  (* keep = "true" *)logic                  dispatch_full_for_2_if_one;
  (* keep = "true" *)logic                  dispatch_full_for_2_if_both;
  logic                  dispatch_full_next;
  logic                  dispatch_full_for_2_next;

  // Slot-1 / slot-2 alloc targets and write enables (assigned below).
  logic [  PtrWidth-1:0] alloc_target_2;
  logic                  slot1_alloc_en;
  logic                  slot2_alloc_en;
  logic [  IdxWidth-1:0] slot2_alloc_idx;
  // Per-entry allocation pulses, expanded over the two late dispatch valids
  // (they arrive through the dispatch fire tree).  first_room_oh (the first
  // target, if there is room for one entry) and second_room_oh (the second
  // target, if there is room for two) do not depend on the requests and are
  // kept as nets, so each pulse is one gate of the valids against them.
  // Slot 1 takes the first target when present; slot 2 takes the first
  // target when alone and the second in a pair.
  logic [     DEPTH-1:0] first_target_oh;
  logic [     DEPTH-1:0] second_target_oh;
  (* keep = "true", max_fanout = 16 *)logic [     DEPTH-1:0] first_room_oh;
  (* keep = "true", max_fanout = 16 *)logic [     DEPTH-1:0] second_room_oh;
  (* keep = "true", max_fanout = 16 *)logic [     DEPTH-1:0] slot1_alloc_oh;
  (* keep = "true", max_fanout = 16 *)logic [     DEPTH-1:0] slot2_alloc_oh;
  (* keep = "true", max_fanout = 16 *)logic [     DEPTH-1:0] alloc_oh;

  // Memory write tracking.  Plain fast-tier drains (BRAM, non-MMIO) are
  // pipelined: up to two writes may be in flight (one on the bus, one
  // awaiting its 1-cycle done), tracked by write_inflight_cnt plus a 2-deep
  // in-order metadata FIFO (entry index + completes flag, popped one per
  // done).  Cached / MMIO writes are strictly single-outstanding
  // (write_inflight_special): the cached adapter keeps one store in flight
  // and MMIO dispatch is serialized.
  logic [           1:0] write_inflight_cnt;
  logic                  write_inflight_special;
  logic [  IdxWidth-1:0] write_fifo_idx0;
  logic [  IdxWidth-1:0] write_fifo_idx1;
  logic                  write_fifo_completes0;
  logic                  write_fifo_completes1;
  // FIFO-head aliases: every done-side consumer reads slot 0 (dones arrive
  // in launch order on the single write port).
  logic [  IdxWidth-1:0] write_entry_idx;
  logic                  write_completes_entry;
  assign write_entry_idx       = write_fifo_idx0;
  assign write_completes_entry = write_fifo_completes0;

  // Drain-cursor entry readiness (committed + addr_valid + data_valid)
  logic                drain_ready;

  // Head skip-advance and tail allocation targets.
  logic [PtrWidth-1:0] head_advance_target;
  logic [PtrWidth-1:0] alloc_target;
  logic                flush_all_uncommitted;

  // ===========================================================================
  // Count, Full, Empty
  // ===========================================================================
  // Capacity is the ring window (tail - head), not the live popcount: with
  // pure tail allocation, a freed slot is reusable only once the head has
  // passed it or a flush has reclaimed it.  Dead slots inside the
  // window (sc_discard holes, a drained entry the head has not yet passed, a
  // killed suffix before the tail pullback) therefore still consume
  // capacity, and window-based full is conservative while they last.  The
  // live count is separate event-maintained state so that empty does not
  // put the sq_valid reduction tree in the LQ/cache issue cone.
  logic [PtrWidth-1:0] window_occupancy;
  assign window_occupancy = tail_ptr - head_ptr;

  assign full = (window_occupancy >= PtrWidth'(DEPTH));
  // full_for_2: room for at most 1 more entry, so a 2-wide bundle of two
  // stores would not fit even if neither slot has been allocated yet.
  assign full_for_2 = (window_occupancy >= PtrWidth'(DEPTH - 1));
  assign empty = (live_count_q == CountWidth'(0));

  assign o_full = full;
  assign o_full_for_2 = full_for_2;
  assign o_dispatch_full = dispatch_full_q;
  assign o_dispatch_full_for_2 = dispatch_full_for_2_q;
  assign o_empty = empty;
  assign o_dispatch_empty = empty;
  assign o_count = live_count_q;
  assign o_dispatch_count = live_count_q;

  // Slot-1 / slot-2 allocation enables.  Slot-2 valid does not require slot-1
  // valid; if both fire, slot-1 (older) takes tail_ptr and slot-2 (younger)
  // takes tail_ptr + 1, so ring order stays program order.
  //
  // Flush gating matches the ROB's alloc_en (!i_flush_all && !i_flush_en).
  // Dispatch presents alloc requests without flush gating, because the
  // dispatch-fire cone must not absorb the flush broadcast.  On trap/MRET/
  // FENCE-class flush cycles the front-end kill arrives a cycle late, so a
  // request can still arrive here: a wrong-path instruction, or the
  // FENCE-class instruction's successor, which will be refetched.  The SQ
  // must drop it exactly when the ROB does; a request accepted in a
  // partial-flush cycle would leave an SQ entry for a ROB tag that was never
  // allocated.  On full-flush cycles the gate also keeps the request out of
  // the unreset payload flops.
  logic alloc_flush_ok;
  assign alloc_flush_ok = !i_flush_all && !i_flush_en;
  // Room for a lone request (first target) and for a pair (first and second
  // targets); the trusted variant relies on dispatch back-pressure for both.
  // full implies full_for_2 (room for two implies room for one), so a slot-1
  // request without room leaves slot 2 without room as well, and the valids
  // select the room terms directly.
  logic alloc_room_1;
  logic alloc_room_2;
  assign alloc_room_1   = alloc_flush_ok && (TRUST_DISPATCH_VALID || !full);
  assign alloc_room_2   = alloc_flush_ok && (TRUST_DISPATCH_VALID || !full_for_2);
  assign slot1_alloc_en = i_alloc.valid && alloc_room_1;
  assign slot2_alloc_en = i_alloc_2.valid && (i_alloc.valid ? alloc_room_2 : alloc_room_1);

`ifndef SYNTHESIS
  // TRUST_DISPATCH_VALID drops the local room re-checks from the alloc
  // enables; check bit-exact equivalence with the untrusted computation so a
  // contract break (an alloc valid while the window is full) fails in
  // simulation instead of silently overwriting an occupied slot.
  // Edge-sampled: all alloc_en consumers (live_count/tail/sq_valid/payload
  // writes) are clocked, so the contract binds at the capture edge only.
  // Bench pacing may leave a refused valid high for a harmless half-cycle
  // after the fill edge.
  always_ff @(posedge i_clk) begin
    if (TRUST_DISPATCH_VALID && i_rst_n && !$isunknown(
            {i_alloc.valid, i_alloc_2.valid, full, full_for_2, alloc_flush_ok}
        )) begin
      p_trusted_sq_alloc_exact :
      assert (slot1_alloc_en == (i_alloc.valid && !full && alloc_flush_ok));
      p_trusted_sq_alloc_2_exact :
      assert (slot2_alloc_en ==
              (i_alloc_2.valid &&
               ((i_alloc.valid && !full && alloc_flush_ok) ? !full_for_2 : !full) &&
               alloc_flush_ok));
    end
    // The registered dispatch back-pressure must stay conservative w.r.t.
    // the live window (no same-cycle reclaim ever shrinks it early); the
    // trusted alloc enables depend on this invariant.
    if (TRUST_DISPATCH_VALID && i_rst_n && !$isunknown(
            {full, full_for_2, dispatch_full_q, dispatch_full_for_2_q}
        )) begin
      p_trusted_sq_status_conservative : assert (!full || dispatch_full_q);
      p_trusted_sq_status_for_2_conservative : assert (!full_for_2 || dispatch_full_for_2_q);
    end
  end
`endif
  assign slot2_alloc_idx = slot1_alloc_en ? alloc_target_2[IdxWidth-1:0]
                                          : alloc_target[IdxWidth-1:0];


  // Registered dispatch back-pressure mirrors the window math: allocations
  // grow the window this cycle; every reclaim (drain completion, head
  // skip-advance over sc holes, partial-flush tail pullback) is picked up
  // from the live window_occupancy one cycle later.  There is no same-cycle
  // drain decrement: the head advances the cycle after a drain completes, so
  // an early decrement would deassert back-pressure one cycle before the
  // slot is reusable, and dispatch could send a store the SQ cannot accept.
  // Back-pressure is therefore only ever conservatively long, never short.
  //
  // Per-outcome window counts and their comparisons are evaluated ahead of
  // the dispatch valids (see the candidate declarations); the valids then
  // select a comparison result, not a count, so no adder or compare sits
  // between them and the back-pressure flops.
  assign dispatch_count_if_none = CountWidth'(window_occupancy);
  assign dispatch_count_if_one = dispatch_count_if_none + CountWidth'(alloc_room_1);
  assign dispatch_count_if_both = dispatch_count_if_one + CountWidth'(alloc_room_2);
  assign dispatch_full_if_none = dispatch_count_if_none == CountWidth'(DEPTH);
  assign dispatch_full_if_one = dispatch_count_if_one == CountWidth'(DEPTH);
  assign dispatch_full_if_both = dispatch_count_if_both == CountWidth'(DEPTH);
  assign dispatch_full_for_2_if_none = dispatch_count_if_none >= CountWidth'(DEPTH - 1);
  assign dispatch_full_for_2_if_one = dispatch_count_if_one >= CountWidth'(DEPTH - 1);
  assign dispatch_full_for_2_if_both = dispatch_count_if_both >= CountWidth'(DEPTH - 1);
  always_comb begin
    case ({
      i_alloc.valid, i_alloc_2.valid
    })
      2'b11: begin
        dispatch_full_next = dispatch_full_if_both;
        dispatch_full_for_2_next = dispatch_full_for_2_if_both;
      end
      2'b10, 2'b01: begin
        dispatch_full_next = dispatch_full_if_one;
        dispatch_full_for_2_next = dispatch_full_for_2_if_one;
      end
      default: begin
        dispatch_full_next = dispatch_full_if_none;
        dispatch_full_for_2_next = dispatch_full_for_2_if_none;
      end
    endcase
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      dispatch_full_q <= 1'b0;
      dispatch_full_for_2_q <= 1'b0;
    end else begin
      dispatch_full_q <= dispatch_full_next;
      dispatch_full_for_2_q <= dispatch_full_for_2_next;
    end
  end

`ifndef SYNTHESIS
  // Adder form of the registered back-pressure, compared in simulation and
  // formal with the selected per-outcome comparisons above.
  logic [CountWidth-1:0] dispatch_count_next_reference;
  logic                  dispatch_full_next_reference;
  logic                  dispatch_full_for_2_next_reference;
  assign dispatch_count_next_reference = CountWidth'(window_occupancy) +
      CountWidth'(slot1_alloc_en) + CountWidth'(slot2_alloc_en);
  assign dispatch_full_next_reference = dispatch_count_next_reference == CountWidth'(DEPTH);
  assign dispatch_full_for_2_next_reference =
      dispatch_count_next_reference >= CountWidth'(DEPTH - 1);
`endif

  // Committed-empty: no committed-but-unwritten entries. Register this status
  // for consumers that feed MEM issue/CDB arbitration. Raw same-cycle commit
  // pulses pessimistically clear the bit so fences/SCs cannot observe stale
  // empty while a store commit is entering the SQ pipeline.
  logic any_committed;
  always_comb begin
    any_committed = 1'b0;
    for (int i = 0; i < DEPTH; i++) if (sq_valid[i] && sq_committed[i]) any_committed = 1'b1;
  end

  // Complete registered-state/registered-commit qualification before the
  // late ROB combinational commit strobes. They then enter one final gate
  // together with reset/full-flush.
  (* keep = "true" *)logic no_registered_committed_work;
  logic committed_empty_next;
  assign no_registered_committed_work = !any_committed && !i_commit_valid && !i_commit_valid_2;
  assign committed_empty_next = !i_rst_n || i_flush_all ||
      (no_registered_committed_work && !i_commit_valid_comb && !i_commit_valid_comb_2);
  always_ff @(posedge i_clk) begin
    committed_empty_q <= committed_empty_next;
  end

`ifdef SQ_COMMITTED_EMPTY_LOCAL_PROOF
  always_comb begin
    assert (committed_empty_next == ((!i_rst_n || i_flush_all) ? 1'b1 :
        (!any_committed && !i_commit_valid && !i_commit_valid_2 &&
         !i_commit_valid_comb && !i_commit_valid_comb_2)));
  end
`endif

  assign o_committed_empty = committed_empty_q;

  logic [DEPTH*ReorderBufferTagWidth-1:0] sq_rob_tag_flat;
  logic [DEPTH*XLEN-1:0] sq_address_flat;
  logic [DEPTH*MemSizeWidth-1:0] sq_size_flat;

  for (genvar g_sq_flat = 0; g_sq_flat < DEPTH; g_sq_flat++) begin : gen_sq_flat
    assign sq_rob_tag_flat[g_sq_flat*ReorderBufferTagWidth +: ReorderBufferTagWidth] =
        sq_rob_tag[g_sq_flat];
    assign sq_address_flat[g_sq_flat*XLEN+:XLEN] = sq_address[g_sq_flat];
    assign sq_size_flat[g_sq_flat*MemSizeWidth+:MemSizeWidth] = sq_size[g_sq_flat];
  end

  // ===========================================================================
  // Store-to-load forwarding -> sq_forwarding_unit.sv.
  // The SQ forwarding data mirror stays here.
  // ===========================================================================
  sq_forwarding_unit #(
      .DEPTH(DEPTH)
  ) sq_forwarding_unit_inst (
      .i_clk                     (i_clk),
      .i_rst_n                   (i_rst_n),
      .i_flush_all               (i_flush_all),
      .i_sq_check_capture_valid  (i_sq_check_capture_valid),
      .i_sq_check_addr           (i_sq_check_addr),
      .i_sq_check_addr_b         (i_sq_check_addr_b),
      .i_sq_check_addr_c         (i_sq_check_addr_c),
      .i_sq_check_addr_d         (i_sq_check_addr_d),
      .i_sq_check_size           (i_sq_check_size),
      .i_sq_check_rob_tag        (i_sq_check_rob_tag),
      .i_rob_head_tag            (i_rob_head_tag),
      // Scan-only trap-cone-free commit pulses (tags shared with the
      // architectural ports; see the i_commit_valid_scan port comment).
      .i_commit_valid            (i_commit_valid_scan),
      .i_commit_rob_tag          (i_commit_rob_tag),
      .i_commit_valid_2          (i_commit_valid_scan_2),
      .i_commit_rob_tag_2        (i_commit_rob_tag_2),
      .i_sq_head_idx             (head_idx),
      .sq_valid                  (sq_valid),
      .sq_addr_valid             (sq_addr_valid),
      .sq_data_valid             (sq_data_valid),
      .sq_is_mmio                (sq_is_mmio),
      .sq_is_sc                  (sq_is_sc),
      .sq_committed              (sq_committed),
      .sq_rob_tag_flat           (sq_rob_tag_flat),
      .sq_address_flat           (sq_address_flat),
      .sq_size_flat              (sq_size_flat),
      .sq_data_fwd_flat          (sq_data_fwd_flat),
      .o_sq_all_older_addrs_known(o_sq_all_older_addrs_known),
      .o_sq_forward              (o_sq_forward)
  );

  // ===========================================================================
  // Drain Cursor (oldest undrained entry; pipelined store drain)
  // ===========================================================================
  // head_ptr must keep its freed-at-done semantics: the ring window
  // (tail - head) is the capacity model, so the head may only pass entries
  // whose writes have fully completed.  The drain side therefore tracks its
  // own cursor: the first entry in ring order from head_ptr that is
  // valid && !sent, with the entry launching this cycle folded in
  // combinationally so back-to-back fires select consecutive entries.  The
  // cursor is registered (drain_idx_q), keeping the drain data/flag reads
  // register-addressed.  Program order is preserved by construction: the
  // cursor is the oldest undrained entry, and nothing fires while that entry
  // is not drain-ready.
  logic [   DEPTH-1:0] drain_mask_base;
  logic [   DEPTH-1:0] drain_mask_post_fire;

  logic                mem_write_fire_next;
  logic                mem_write_completes_next;
  logic                mem_write_plain_fast_next;
  logic                drain_complete_fire_next;

  // drain_complete_fire_next carries the selected entry's late address/tier
  // classification, so feeding it into every mask bit before the above-head
  // and absolute priority scans would put both encoders in that late path.
  // Instead, the F=0 base mask and the F=1 post-fire mask are computed in
  // parallel, each with its complete ring-priority scan, and only a final
  // three-bit mux depends on the late fire decision.  This is the exact
  // Shannon expansion of M[i] = base[i] && !(fire && drain_idx_q == i); the
  // reference below evaluates that expression directly.
  logic [   DEPTH-1:0] drain_mask_base_above_head;
  logic [   DEPTH-1:0] drain_mask_post_fire_above_head;
  logic [IdxWidth-1:0] drain_base_first_above_idx;
  logic                drain_base_first_above_found;
  logic [IdxWidth-1:0] drain_base_first_any_idx;
  logic                drain_base_first_any_found;
  logic [IdxWidth-1:0] drain_post_fire_first_above_idx;
  logic                drain_post_fire_first_above_found;
  logic [IdxWidth-1:0] drain_post_fire_first_any_idx;
  logic                drain_post_fire_first_any_found;
  (* keep = "true" *)logic [IdxWidth-1:0] drain_base_idx_d;
  (* keep = "true" *)logic [IdxWidth-1:0] drain_post_fire_idx_d;
  logic [IdxWidth-1:0] drain_idx_d;

  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      drain_mask_base[i] = sq_valid[i] && !sq_sent[i];
      drain_mask_post_fire[i] = drain_mask_base[i] && (drain_idx_q != IdxWidth'(i));
      drain_mask_base_above_head[i] =
          drain_mask_base[i] && (IdxWidth'(i) >= head_ptr[IdxWidth-1:0]);
      drain_mask_post_fire_above_head[i] =
          drain_mask_post_fire[i] && (IdxWidth'(i) >= head_ptr[IdxWidth-1:0]);
    end

    drain_base_first_above_idx   = '0;
    drain_base_first_above_found = 1'b0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (drain_mask_base_above_head[i] && !drain_base_first_above_found) begin
        drain_base_first_above_idx   = IdxWidth'(i);
        drain_base_first_above_found = 1'b1;
      end
    end

    drain_base_first_any_idx   = '0;
    drain_base_first_any_found = 1'b0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (drain_mask_base[i] && !drain_base_first_any_found) begin
        drain_base_first_any_idx   = IdxWidth'(i);
        drain_base_first_any_found = 1'b1;
      end
    end

    drain_post_fire_first_above_idx   = '0;
    drain_post_fire_first_above_found = 1'b0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (drain_mask_post_fire_above_head[i] && !drain_post_fire_first_above_found) begin
        drain_post_fire_first_above_idx   = IdxWidth'(i);
        drain_post_fire_first_above_found = 1'b1;
      end
    end

    drain_post_fire_first_any_idx   = '0;
    drain_post_fire_first_any_found = 1'b0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (drain_mask_post_fire[i] && !drain_post_fire_first_any_found) begin
        drain_post_fire_first_any_idx   = IdxWidth'(i);
        drain_post_fire_first_any_found = 1'b1;
      end
    end

    drain_base_idx_d = !drain_base_first_any_found ? head_idx :
        (drain_base_first_above_found ? drain_base_first_above_idx : drain_base_first_any_idx);
    drain_post_fire_idx_d = !drain_post_fire_first_any_found ? head_idx :
        (drain_post_fire_first_above_found ?
         drain_post_fire_first_above_idx : drain_post_fire_first_any_idx);
  end

  assign drain_idx_d = drain_complete_fire_next ? drain_post_fire_idx_d : drain_base_idx_d;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      drain_idx_q <= '0;
    end else begin
      drain_idx_q <= drain_idx_d;
    end
  end

`ifndef SYNTHESIS
  // Reference for the parallel scans: the fire-in-mask form scanned by
  // rotate, priority-encode, and add-back, with the same empty-mask head
  // fallback.
  logic [   DEPTH-1:0] drain_mask_legacy;
  logic [   DEPTH-1:0] drain_mask_rotated;
  logic [IdxWidth-1:0] drain_first_offset;
  logic [IdxWidth-1:0] drain_idx_legacy;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      drain_mask_legacy[i] = drain_mask_base[i] &&
          !(drain_complete_fire_next && (drain_idx_q == IdxWidth'(i)));
    end
    drain_mask_rotated = '0;
    drain_first_offset = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      drain_mask_rotated[i] = drain_mask_legacy[(32'(i)+32'(head_ptr[IdxWidth-1:0]))%DEPTH];
    end
    begin
      logic ref_found;
      ref_found = 1'b0;
      for (int unsigned i = 0; i < DEPTH; i++) begin
        if (drain_mask_rotated[i] && !ref_found) begin
          drain_first_offset = IdxWidth'(i);
          ref_found = 1'b1;
        end
      end
      drain_idx_legacy = ref_found ?
          IdxWidth'((32'(head_ptr[IdxWidth-1:0]) + 32'(drain_first_offset)) % DEPTH) :
          head_idx;
      if (!$isunknown(
              {drain_mask_base, drain_complete_fire_next, drain_idx_q, head_ptr, drain_idx_d}
          )) begin
        p_parallel_drain_scans_match_legacy : assert (drain_idx_d == drain_idx_legacy);
        if (drain_complete_fire_next) begin
          p_drain_fire_entry_is_in_base_mask : assert (drain_mask_base[drain_idx_q]);
        end
        if (drain_post_fire_first_any_found) begin
          p_post_fire_scan_excludes_current : assert (drain_post_fire_idx_d != drain_idx_q);
        end
      end
    end
  end
`endif

  // ===========================================================================
  // Memory Write Logic (combinational)
  // ===========================================================================
  // The drain-cursor entry writes to memory when committed, addr_valid,
  // data_valid.  Every size drains in a single beat.
  //
  // The write interface is registered so the queue-state -> drain_ready
  // decode never drives the memory bus combinationally: drain_ready feeds
  // the next state of a pipeline register, and the o_mem_write_en output
  // itself is a flop.
  //
  // Drain pipelining: plain fast-tier stores (BRAM, non-MMIO) complete
  // exactly one cycle after their bus cycle (the router's sq_write_done_fast
  // is the write-enable delayed one cycle), so consecutive plain drains
  // overlap: a new launch is allowed while the previous write's done is
  // still in flight, bounded to two in-flight by the metadata FIFO.
  // Cached / MMIO writes keep the strict one-at-a-time gate
  // (write_inflight_cnt == 0 && !o_mem_write_en).

  assign drain_ready = sq_valid[drain_idx_q] && sq_committed[drain_idx_q] &&
                       sq_addr_valid[drain_idx_q] && sq_data_valid[drain_idx_q] &&
                       !sq_sent[drain_idx_q];

  logic [       riscv_pkg::XLEN-1:0] mem_write_addr_next;
  logic [riscv_pkg::MemDataBits-1:0] mem_write_data_next;
  logic [riscv_pkg::MemStrbBits-1:0] mem_write_byte_en_next;
  logic                              mem_write_is_mmio_next;
  logic                              mem_write_is_cached_next;
  logic                              mem_write_launch_serial_next;
  logic                              mem_write_launch_pipelined_next;
  logic                              mem_write_addr_cached_for_plain_next;
  logic [                       2:0] write_fifo_occupancy_after_current_bus;

  always_comb begin
    // Single-beat drains at every size (hw/rtl/README.md, "Data-tier bus contract"): doubles
    // are one 64-bit write.
    mem_write_addr_next = sq_address[drain_idx_q];

    mem_write_data_next =
        gen_write_data(sq_data_drain_rd, riscv_pkg::mem_size_e'(sq_size[drain_idx_q]));
    mem_write_byte_en_next =
        gen_byte_en(mem_write_addr_next[2:0], riscv_pkg::mem_size_e'(sq_size[drain_idx_q]));
    mem_write_is_mmio_next = sq_is_mmio[drain_idx_q];
    // Cached-tier decode of the write address.  Registered below into
    // o_mem_write_is_cached (parallel to is_mmio), so the comparator stays in
    // the addr->register cone and never reaches the BRAM WEA pin.
    // XLEN'() casts, not [XLEN-1:0] part-selects: the parameters are 32-bit
    // ints, so a 64-bit part-select would be out of range.
    mem_write_is_cached_next =
        (mem_write_addr_next >= XLEN'(CACHED_BASE)) &&
        (mem_write_addr_next <  (XLEN'(CACHED_BASE) + XLEN'(CACHED_SIZE_BYTES)));
  end

  assign mem_write_addr_cached_for_plain_next =
      (sq_address[drain_idx_q] >= XLEN'(CACHED_BASE)) &&
      (sq_address[drain_idx_q] <  (XLEN'(CACHED_BASE) + XLEN'(CACHED_SIZE_BYTES)));
  // Every store is one beat, so every launch completes its entry and a plain
  // fast-tier DOUBLE pipelines like any other size.  The write-FIFO completes
  // flag is therefore constant-true; synthesis sweeps it.
  assign mem_write_completes_next = 1'b1;
  assign mem_write_plain_fast_next = !sq_is_mmio[drain_idx_q] &&
                                     !mem_write_addr_cached_for_plain_next;

  // Launch gate: the serial arm for any write type, plus the pipelined
  // arm for plain fast-tier stores.  The registered in-flight count has not
  // yet absorbed the write currently on the bus, so compute the FIFO
  // occupancy after that push and any coincident oldest-write completion.
  // Crediting the done here is what permits sustained one-write-per-cycle
  // traffic; omitting it inserts a bubble after every two launches even
  // though the simultaneous push/pop FIFO arm has made a slot available.
  // A stalled done still self-throttles the drain before the 2-deep FIFO can
  // overflow.
  assign write_fifo_occupancy_after_current_bus =
      {1'b0, write_inflight_cnt} + {2'b0, o_mem_write_en} -
      {2'b0, (i_mem_write_done && (write_inflight_cnt != 2'd0))};
  assign mem_write_launch_serial_next = (write_inflight_cnt == 2'd0) && !o_mem_write_en;
  assign mem_write_launch_pipelined_next =
      mem_write_plain_fast_next && !write_inflight_special &&
      (write_fifo_occupancy_after_current_bus < 3'd2);
  assign mem_write_fire_next =
      drain_ready && (mem_write_launch_serial_next || mem_write_launch_pipelined_next);
  assign drain_complete_fire_next = drain_ready && mem_write_completes_next &&
                                    (mem_write_launch_serial_next ||
                                     mem_write_launch_pipelined_next);

  // Staging register for write_entry_idx and write_completes_entry, captured
  // alongside the write interface so they stay aligned with o_mem_write_en.
  logic [IdxWidth-1:0] mem_write_entry_idx_stg;
  logic                mem_write_completes_stg;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      o_mem_write_en <= 1'b0;
    end else begin
      o_mem_write_en <= mem_write_fire_next;
    end

    o_mem_write_addr    <= mem_write_addr_next;
    o_mem_write_data    <= mem_write_data_next;
    o_mem_write_byte_en <= mem_write_byte_en_next;
    o_mem_write_is_mmio <= mem_write_is_mmio_next;
    o_mem_write_is_cached <= mem_write_is_cached_next;

    if (mem_write_fire_next) begin
      mem_write_entry_idx_stg <= drain_idx_q;
      mem_write_completes_stg <= mem_write_completes_next;
    end
  end

  // ===========================================================================
  // L0 Cache Invalidation (at memory write launch)
  // ===========================================================================
  // Invalidate the LQ's L0 cache at the written address in the write's bus
  // cycle.  Invalidating at launch instead of at write-done closes the
  // stale-L0-hit window for any write latency, including a multi-cycle
  // cached write, with no extra gating: between launch and done nobody can
  // read the old memory word either (the router controls the shared port
  // and queues/replays reads behind the write flight), so the only reachable
  // outcomes are an L0 miss plus a memory read ordered behind the write.
  // Early invalidation is always safe; at worst it costs one refill miss.
  // Both outputs come straight from SQ output registers.
  // One pulse covers any store, since no store crosses a dword (the LQ's L0
  // is dword-granule, and the wrapper's reservation snoop compares dword
  // addresses).  MMIO stores also pulse harmlessly (the L0 never caches MMIO).
  assign o_cache_invalidate_valid = o_mem_write_en;
  assign o_cache_invalidate_addr = o_mem_write_addr;

  // ===========================================================================
  // Allocation (pure ring tail)
  // ===========================================================================
  // Allocate strictly at the ring tail. Ring position must encode program
  // order for the head-ordered drain to deliver stores to memory in program
  // order.  A younger store placed in a hole that the drain reaches before
  // older live entries would strand committed older stores behind an
  // uncommitted one (an LQ/SQ deadlock if a load older than that store waits
  // for them to drain), and same-address stores could reach memory out of
  // program order.  Partial flush therefore pulls tail_ptr back over the
  // killed suffix (see Flush Tail Pullback), so flush holes never persist;
  // the only lasting holes are sc_discard frees, which the head skip-advance
  // walks over without reuse.
  assign flush_all_uncommitted = i_flush_after_head_commit;
  assign alloc_target = tail_ptr;
  assign alloc_target_2 = tail_ptr + PtrWidth'(1);

  always_comb begin
    first_target_oh                                = '0;
    second_target_oh                               = '0;
    first_target_oh[alloc_target[IdxWidth-1:0]]    = 1'b1;
    second_target_oh[alloc_target_2[IdxWidth-1:0]] = 1'b1;
  end
  assign first_room_oh = first_target_oh & {DEPTH{alloc_room_1}};
  assign second_room_oh = second_target_oh & {DEPTH{alloc_room_2}};
  assign slot1_alloc_oh = first_room_oh & {DEPTH{i_alloc.valid}};
  assign slot2_alloc_oh = i_alloc.valid ? (second_room_oh & {DEPTH{i_alloc_2.valid}})
                                        : (first_room_oh & {DEPTH{i_alloc_2.valid}});
  assign alloc_oh = (first_room_oh & {DEPTH{i_alloc.valid || i_alloc_2.valid}}) |
                    (second_room_oh & {DEPTH{i_alloc.valid && i_alloc_2.valid}});

`ifndef SYNTHESIS
  // Enable-then-steer reference for the expanded pulses: the slot-2 enable
  // chooses its room behind the slot-1 enable and the slot-2 pulse is
  // steered by that enable.  Simulation and formal compare both forms.
  logic             slot2_alloc_en_reference;
  logic [DEPTH-1:0] slot2_alloc_oh_reference;
  assign slot2_alloc_en_reference = TRUST_DISPATCH_VALID ?
      (i_alloc_2.valid && alloc_flush_ok) :
      (i_alloc_2.valid && (slot1_alloc_en ? !full_for_2 : !full) && alloc_flush_ok);
  always_comb begin
    slot2_alloc_oh_reference = '0;
    slot2_alloc_oh_reference[slot1_alloc_en ? alloc_target_2[IdxWidth-1:0]
                                            : alloc_target[IdxWidth-1:0]] =
        slot2_alloc_en_reference;
  end
`endif

  // ===========================================================================
  // Flush Tail Pullback (applies the cycle after the flush)
  // ===========================================================================
  // A partial flush kills a program-order suffix of the live window (all
  // uncommitted entries younger than flush_tag, or all uncommitted entries
  // when flush_all_uncommitted), so the window is rebuilt as
  // [head_ptr, youngest_survivor + 1).
  //
  // Rebuilding in the flush cycle would need a survivor mask that mirrors
  // the kill predicate, followed by rotate → priority-encode → adder, all
  // ahead of the tail_ptr D and head_ptr CE pins: too deep for one cycle.
  // The flush cycle therefore only clears per-entry valid bits (short,
  // per-entry endpoints) while both pointers hold.  One cycle later, while
  // flush_pullback_pending is set, the tail is rebuilt from the registered
  // post-kill valid mask and head_ptr, a full-cycle path from FF outputs.
  //
  // The deferred cycle is safe because:
  //  - nothing allocates in the flush cycle (alloc_flush_ok) or the cycle
  //    after (a dispatch-side contract: the front-end redirect/refill takes
  //    several cycles; checked below), so the stale tail is never an
  //    allocation target;
  //  - window_occupancy reads stale-high (killed suffix still inside the
  //    window) so full/dispatch back-pressure is conservative, never short;
  //  - the head is held for the same two cycles, so its empty-collapse arm
  //    (head <= tail) never samples the stale tail;
  //  - a second flush arriving in the pending cycle (back-to-back EX-side
  //    mispredicts) re-kills valid bits and extends pending one cycle: the
  //    rebuild only ever reads registered state, so it is idempotent.
  //
  // The youngest surviving entry is the highest set offset in the
  // head-rotated valid mask (sq_head_valid_rotated, shared with the head
  // advance logic): entries outside [head, tail) are never valid, killed
  // entries were just cleared, and pre-existing sc_discard holes are
  // valid=0.  With no valid entry left the window collapses to the held head
  // pointer.  Trailing sc_discard holes (no live entry younger than them)
  // are reclaimed by the pullback, which is safe: only reclaiming a hole
  // with live entries beyond it would break the ring-order invariant.
  // (The pullback encoder lives just below the Head Advancement section so it
  // can share sq_head_valid_rotated.)

  // ===========================================================================
  // Head Advancement (tree-based find-first-valid from head)
  // ===========================================================================
  // The scan is rotate → tree-priority-encode → add-back, O(log2(DEPTH))
  // logic levels.  Empty visibility has its own live_count_q timing
  // boundary (above), so this scan cannot leak into LQ issue through o_empty.

  logic [DEPTH-1:0] sq_head_valid_rotated;
  logic [IdxWidth-1:0] sq_head_first_valid_offset;
  logic sq_head_first_valid_found;

  // Barrel-rotate valid mask so head_ptr maps to index 0
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      sq_head_valid_rotated[i] = sq_valid[(32'(i)+32'(head_ptr[IdxWidth-1:0]))%DEPTH];
    end
  end

  // Tree priority encoder: find lowest-index set bit (first valid entry)
  always_comb begin
    sq_head_first_valid_offset = '0;
    sq_head_first_valid_found  = 1'b0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (sq_head_valid_rotated[i] && !sq_head_first_valid_found) begin
        sq_head_first_valid_offset = IdxWidth'(i);
        sq_head_first_valid_found  = 1'b1;
      end
    end
  end

  // Add offset back to head_ptr. With no valid entry the window has fully
  // drained: collapse head onto tail so window-based occupancy reads zero
  // (otherwise the head parks one slot short of tail after the final drain
  // and the window leaks a phantom slot).
  assign head_advance_target = sq_head_first_valid_found ?
      head_ptr + PtrWidth'({1'b0, sq_head_first_valid_offset}) : tail_ptr;

  // Pullback encoder (see Flush Tail Pullback above): the highest set offset
  // in the head-rotated registered valid mask is the youngest surviving
  // entry's window position.  Mirror of the first-valid encoder above.
  logic flush_pullback_pending;
  logic [IdxWidth-1:0] sq_last_valid_offset;
  logic sq_any_valid_entry;
  always_comb begin
    sq_last_valid_offset = '0;
    sq_any_valid_entry   = 1'b0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (sq_head_valid_rotated[i]) begin
        sq_last_valid_offset = IdxWidth'(i);
        sq_any_valid_entry   = 1'b1;
      end
    end
  end

  logic [PtrWidth-1:0] flush_tail_pullback;
  assign flush_tail_pullback = sq_any_valid_entry ?
      (head_ptr + PtrWidth'({1'b0, sq_last_valid_offset}) + PtrWidth'(1)) : head_ptr;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      flush_pullback_pending <= 1'b0;
    end else if (i_flush_en) begin
      flush_pullback_pending <= 1'b1;
    end else begin
      flush_pullback_pending <= 1'b0;
    end
  end

  // ===========================================================================
  // Sequential Logic
  // ===========================================================================

  // -------------------------------------------------------------------
  // Control-signal always_ff (with reset and flush_all sensitivity)
  // -------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      head_ptr               <= '0;
      tail_ptr               <= '0;
      sq_addr_valid          <= '0;
      sq_data_valid          <= '0;
      sq_committed           <= '0;
      sq_sent                <= '0;
      write_inflight_cnt     <= '0;
      write_inflight_special <= 1'b0;
    end else if (i_flush_all) begin
      // Full flush: reset control signals
      head_ptr               <= '0;
      tail_ptr               <= '0;
      sq_addr_valid          <= '0;
      sq_data_valid          <= '0;
      sq_committed           <= '0;
      sq_sent                <= '0;
      write_inflight_cnt     <= '0;
      write_inflight_special <= 1'b0;
    end else begin

      // -----------------------------------------------------------------
      // Allocation: write control signals for new entry at tail
      // -----------------------------------------------------------------
      // The merged pulse is the write enable; slot 1's pulse selects the
      // request (an allocated entry that slot 1 did not take is slot 2's).
      for (int i = 0; i < DEPTH; i++) begin
        if (alloc_oh[i]) begin
          sq_addr_valid[i] <= slot1_alloc_oh[i] ? i_alloc.addr_valid : i_alloc_2.addr_valid;
          sq_data_valid[i] <= 1'b0;
          sq_committed[i]  <= 1'b0;
          sq_sent[i]       <= 1'b0;
        end
      end

      // tail_ptr advances past the highest slot consumed this cycle (when
      // only slot-2 fires it took alloc_target, so tail advances to
      // alloc_target+1).  A partial flush holds the tail for one cycle while
      // the per-entry kills land, then the pending arm pulls it back over
      // the killed program-order suffix from the registered valid mask (see
      // Flush Tail Pullback) so flush holes never persist and ring position
      // keeps encoding program order.  The arms are mutually exclusive:
      // flush-cycle allocs are suppressed structurally (alloc_flush_ok in
      // the slot enables), and dispatch never allocates in the pullback
      // cycle.  The latter is a dispatch-side contract, checked by $error in
      // the sim-assertion block and assumed in the FORMAL section; the
      // front-end redirect/refill latency after any partial flush keeps
      // dispatch quiet well past that cycle.
      if (i_flush_en) begin
        // Hold: pullback applies next cycle from registered state.
      end else if (flush_pullback_pending) begin
        tail_ptr <= flush_tail_pullback;
      end else if (slot1_alloc_en && slot2_alloc_en) begin
        tail_ptr <= alloc_target_2 + PtrWidth'(1);
      end else if (slot1_alloc_en || slot2_alloc_en) begin
        tail_ptr <= alloc_target + PtrWidth'(1);
      end

      // -----------------------------------------------------------------
      // Early Address Update: pipelined dispatch-time addr (control only)
      // -----------------------------------------------------------------
      if (i_early_addr_update.valid) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (sq_valid[i] && !sq_addr_valid[i] &&
              sq_rob_tag[i] == i_early_addr_update.rob_tag) begin
            sq_addr_valid[i] <= 1'b1;
          end
        end
      end

      // Slot-2 early addr update (control).  rob_tags across the
      // two updates are always distinct (different ROB entries) so this
      // independent loop cannot collide with the slot-1 loop above.
      if (i_early_addr_update_2.valid) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (sq_valid[i] && !sq_addr_valid[i] &&
              sq_rob_tag[i] == i_early_addr_update_2.rob_tag) begin
            sq_addr_valid[i] <= 1'b1;
          end
        end
      end

      // -----------------------------------------------------------------
      // Address Update: CAM search for matching rob_tag (control only)
      // -----------------------------------------------------------------
      if (i_addr_update.valid) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (sq_valid[i] && !sq_addr_valid[i] && sq_rob_tag[i] == i_addr_update.rob_tag) begin
            sq_addr_valid[i] <= 1'b1;
          end
        end
      end

      // -----------------------------------------------------------------
      // Data Update: CAM search for matching rob_tag
      // -----------------------------------------------------------------
      if (i_data_update.valid) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (sq_valid[i] && !sq_data_valid[i] && sq_rob_tag[i] == i_data_update.rob_tag) begin
            sq_data_valid[i] <= 1'b1;
          end
        end
      end

      // -----------------------------------------------------------------
      // Commit: mark entry as committed when ROB commits a store
      // -----------------------------------------------------------------
      if (i_commit_valid) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (sq_valid[i] && !sq_committed[i] && sq_rob_tag[i] == i_commit_rob_tag) begin
            sq_committed[i] <= 1'b1;
          end
        end
      end

      // Widen-commit slot 2: mark a second store as committed in the same
      // cycle.  The two loops are independent: each slot scans the whole
      // SQ and marks the entry whose rob_tag matches.  Slot 2 cannot be an
      // SC by construction, so no SC-discard interaction.
      if (i_commit_valid_2) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (sq_valid[i] && !sq_committed[i] && sq_rob_tag[i] == i_commit_rob_tag_2) begin
            sq_committed[i] <= 1'b1;
          end
        end
      end

      // -----------------------------------------------------------------
      // Memory Write Initiation / Completion (in-flight counter)
      // -----------------------------------------------------------------
      // The counter tracks writes between their bus cycle (o_mem_write_en)
      // and their done pulse; the metadata FIFO below carries entry index
      // and completes flag per in-flight write.  sq_sent is set at launch
      // (fire cycle) for completing writes so the drain cursor can move on
      // immediately; the done side only frees entries.
      write_inflight_cnt <= write_inflight_cnt
          + (o_mem_write_en ? 2'd1 : 2'd0)
          - ((i_mem_write_done && (write_inflight_cnt != 2'd0)) ? 2'd1 : 2'd0);

      if (mem_write_fire_next) begin
        // A special cached or MMIO write flies alone: it only launches
        // through the serial arm, and its in-flight window blocks all further
        // launches until completion.
        write_inflight_special <= !mem_write_plain_fast_next;
        if (mem_write_completes_next) begin
          sq_sent[drain_idx_q] <= 1'b1;
        end
      end else if (i_mem_write_done && (write_inflight_cnt == 2'd1) && !o_mem_write_en) begin
        write_inflight_special <= 1'b0;
      end

      // -----------------------------------------------------------------
      // Head Advancement
      // -----------------------------------------------------------------
      // Skip-advance to the first valid entry. Held during the flush cycle
      // (head_advance_target is computed from the pre-flush valid mask and
      // could step into the just-killed region) and during the pullback
      // cycle (its empty-collapse arm reads tail_ptr, which is stale until
      // the pullback lands).  Holding delays a drain advance by at most two
      // cycles; the scan recomputes from valid bits every cycle.
      if (!i_flush_en && !flush_pullback_pending) begin
        head_ptr <= head_advance_target;
      end

    end  // !flush_all

    // In-flight metadata FIFO: push at the bus cycle, pop at done.  Dones
    // arrive in launch order (single in-order write port), so slot 0 is
    // always the oldest in-flight write.  Depth 2 matches the launch-gate
    // occupancy bound.  Not flushed: entries are consumed strictly per
    // done, and the counter (which is flushed) gates every consumer.
    if (o_mem_write_en && i_mem_write_done && (write_inflight_cnt != 2'd0)) begin
      // Simultaneous push + pop.
      if (write_inflight_cnt == 2'd1) begin
        write_fifo_idx0       <= mem_write_entry_idx_stg;
        write_fifo_completes0 <= mem_write_completes_stg;
      end else begin
        write_fifo_idx0       <= write_fifo_idx1;
        write_fifo_completes0 <= write_fifo_completes1;
        write_fifo_idx1       <= mem_write_entry_idx_stg;
        write_fifo_completes1 <= mem_write_completes_stg;
      end
    end else if (o_mem_write_en) begin
      if (write_inflight_cnt == 2'd0) begin
        write_fifo_idx0       <= mem_write_entry_idx_stg;
        write_fifo_completes0 <= mem_write_completes_stg;
      end else begin
        write_fifo_idx1       <= mem_write_entry_idx_stg;
        write_fifo_completes1 <= mem_write_completes_stg;
      end
    end else if (i_mem_write_done && (write_inflight_cnt != 2'd0)) begin
      write_fifo_idx0       <= write_fifo_idx1;
      write_fifo_completes0 <= write_fifo_completes1;
    end
  end

  // Partial-flush kill predicate.  Every conjunct is register-sourced this
  // cycle: valid/committed flags, the registered commit-cycle guards
  // (sq_committed is one NBA behind i_commit_valid), and the age check
  // (i_flush_en / i_flush_tag / flush_all_uncommitted all come from the
  // flush controller's registers, i_rob_head_tag from the ROB head pointer).
  //
  // A store the ROB has committed must not be killed, even before its
  // sq_committed bit is set, or its memory write is lost.  The registered
  // guards above cover a commit arriving on the pipelined commit bus in the
  // flush cycle.  The ROB itself never commits in a flush cycle: it gates
  // commit_ready_early (and therefore o_commit_store_like_raw /
  // o_commit_2_store_like_raw, the drivers of i_commit_valid_comb/_comb_2)
  // with !i_flush_en && !i_flush_all on the same flush nets this kill branch
  // runs under, so the combinational commit pulses are 0 in every cycle the
  // kill can execute.  Leaving them out keeps the ROB head-commit cone out of
  // the sq_valid write path; the assertion below (and the matching formal
  // assume) check the invariant.
  logic [DEPTH-1:0] flush_kill_base;
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      flush_kill_base[i] =
          sq_valid[i] && !sq_committed[i] &&
          !(i_commit_valid && sq_rob_tag[i] == i_commit_rob_tag) &&
          !(i_commit_valid_2 && sq_rob_tag[i] == i_commit_rob_tag_2) &&
          (flush_all_uncommitted || is_younger(sq_rob_tag[i], i_flush_tag, i_rob_head_tag));
    end
  end

  // Share the failed-SC match with sq_valid's clear arm and the live counter.
  // Keeping one predicate makes their same-edge state transitions identical
  // by construction rather than relying only on duplicated CAM expressions.
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      sc_discard_remove_mask[i] =
          i_sc_discard && sq_valid[i] && sq_is_sc[i] && !sq_committed[i] &&
          (sq_rob_tag[i] == i_sc_discard_rob_tag);
    end
  end

  assign drain_remove_valid = i_mem_write_done && (write_inflight_cnt != 2'd0) &&
                              write_completes_entry && sq_valid[write_entry_idx];

  // Exact live-count next state.  Build one removal mask before counting so
  // coincident causes never subtract the same entry twice: a failed SC may
  // also be in a partial-flush suffix, while drain completion is disjoint in
  // legal operation but is harmlessly idempotent here.  Accepted allocation
  // targets are free by the ring invariant, so each slot contributes exactly
  // one new live entry and cannot overlap this mask.
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      live_remove_mask[i] = (i_flush_en && flush_kill_base[i]) ||
                            sc_discard_remove_mask[i] ||
                            (drain_remove_valid && (write_entry_idx == IdxWidth'(i)));
    end
  end

  // Complete allocation increments before subtracting the late removal
  // count. This keeps the commit-tag/flush CAM and population count from
  // traversing two more adders; the dispatch valids select among the three
  // exact modular-arithmetic outcomes at the final mux.
  assign live_count_alloc_one = live_count_q + CountWidth'(alloc_room_1);
  assign live_count_alloc_both = live_count_q + CountWidth'(alloc_room_1) +
      CountWidth'(alloc_room_2);
  always_comb begin
    live_remove_count = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      live_remove_count = live_remove_count + CountWidth'(live_remove_mask[i]);
    end

    live_count_if_none = live_count_q - live_remove_count;
    live_count_if_one  = live_count_alloc_one - live_remove_count;
    live_count_if_both = live_count_alloc_both - live_remove_count;
    case ({
      i_alloc.valid, i_alloc_2.valid
    })
      2'b11: live_count_next = live_count_if_both;
      2'b10, 2'b01: live_count_next = live_count_if_one;
      default: live_count_next = live_count_if_none;
    endcase
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      live_count_q <= '0;
    end else begin
      live_count_q <= live_count_next;
    end
  end

`ifndef SYNTHESIS
  // Adder form of the live count, compared in simulation and formal with
  // the selected per-outcome candidate above.
  logic [CountWidth-1:0] live_count_next_reference;
  assign live_count_next_reference = live_count_q + CountWidth'(slot1_alloc_en) +
      CountWidth'(slot2_alloc_en) - live_remove_count;
`endif

  // Simulation-only cross-check against the real ROB; under formal the same
  // invariant is an input assume in the FORMAL section below (and Yosys'
  // frontend rejects the assert-else action block anyway).
`ifndef SYNTHESIS
`ifndef FORMAL
  always_ff @(posedge i_clk) begin
    if (i_rst_n) begin
      assert (!(i_flush_en && (i_commit_valid_comb || i_commit_valid_comb_2)))
      else $error("store_queue: combinational store commit in a partial-flush cycle");
    end
  end
`endif
`endif

  // Keep sq_valid separate so full-flush and partial-flush invalidation do not
  // share one next-state cone with the other SQ control fields.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      sq_valid <= '0;
    end else if (i_flush_all) begin
      sq_valid <= '0;
    end else begin
      // Partial flush: invalidate uncommitted entries younger than flush_tag
      // (all uncommitted entries when flush_all_uncommitted is set).
      // Committed entries are never flushed (they must complete to memory).
      if (i_flush_en) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (flush_kill_base[i]) begin
            sq_valid[i] <= 1'b0;
          end
        end
        // tail_ptr is pulled back over the killed suffix in the control
        // always_ff (see Flush Tail Pullback).
      end

      for (int i = 0; i < DEPTH; i++) begin
        if (alloc_oh[i]) begin
          sq_valid[i] <= 1'b1;
        end
      end

      // Failed SC invalidates its uncommitted SQ entry.
      if (i_sc_discard) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (sc_discard_remove_mask[i]) begin
            sq_valid[i] <= 1'b0;
          end
        end
      end

      // A completed write frees its SQ entry identified by the in-flight
      // metadata FIFO head.
      if (i_mem_write_done && (write_inflight_cnt != 2'd0) && write_completes_entry) begin
        sq_valid[write_entry_idx] <= 1'b0;
      end
    end
  end

  // -------------------------------------------------------------------
  // Data-signal always_ff (no reset, no flush_all: self-gated writes)
  // -------------------------------------------------------------------
  // These per-entry data fields are only consumed when paired control
  // flags (sq_valid, sq_addr_valid, sq_data_valid) are set.  The control
  // block above clears those flags on reset/flush, so the data values
  // are don't-care and need no reset.
  // -------------------------------------------------------------------

  always_ff @(posedge i_clk) begin

    // -----------------------------------------------------------------
    // Allocation: write per-entry data for new entry at tail
    // -----------------------------------------------------------------
    for (int i = 0; i < DEPTH; i++) begin
      if (alloc_oh[i]) begin
        sq_rob_tag[i] <= slot1_alloc_oh[i] ? i_alloc.rob_tag : i_alloc_2.rob_tag;
        sq_size[i]    <= slot1_alloc_oh[i] ? i_alloc.size : i_alloc_2.size;
        sq_is_sc[i]   <= slot1_alloc_oh[i] ? i_alloc.is_sc : i_alloc_2.is_sc;
        if (slot1_alloc_oh[i] ? i_alloc.addr_valid : i_alloc_2.addr_valid) begin
          sq_address[i] <= slot1_alloc_oh[i] ? i_alloc.address : i_alloc_2.address;
          sq_is_mmio[i] <= slot1_alloc_oh[i] ? i_alloc.is_mmio : i_alloc_2.is_mmio;
        end
      end
    end

    // -----------------------------------------------------------------
    // Early Address Update: pipelined dispatch-time addr (data only)
    // -----------------------------------------------------------------
    if (i_early_addr_capture_valid) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (sq_valid[i] && !sq_addr_valid[i] && sq_rob_tag[i] == i_early_addr_update.rob_tag) begin
          sq_address[i] <= i_early_addr_update.address;
          sq_is_mmio[i] <= i_early_addr_update.is_mmio;
        end
      end
    end

    // Slot-2 early addr update (data).  Distinct-rob_tag invariant
    // again guarantees no collision with the slot-1 loop above.
    if (i_early_addr_capture_valid_2) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (sq_valid[i] && !sq_addr_valid[i] &&
            sq_rob_tag[i] == i_early_addr_update_2.rob_tag) begin
          sq_address[i] <= i_early_addr_update_2.address;
          sq_is_mmio[i] <= i_early_addr_update_2.is_mmio;
        end
      end
    end

    // -----------------------------------------------------------------
    // Address Update: CAM search for matching rob_tag (data only)
    // -----------------------------------------------------------------
    // Written after the early-address loops, so a same-cycle MEM_RS update
    // to the same entry wins.
    if (i_addr_update_capture_valid) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (sq_valid[i] && !sq_addr_valid[i] && sq_rob_tag[i] == i_addr_update.rob_tag) begin
          sq_address[i] <= i_addr_update.address;
          sq_is_mmio[i] <= i_addr_update.is_mmio;
        end
      end
    end

  end

  // ===========================================================================
  // Simulation Assertions
  // ===========================================================================
`ifndef SYNTHESIS
`ifndef FORMAL
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      if (i_alloc.valid && full) $warning("SQ: allocation attempted when full");
      // No warning for alloc-during-flush: dispatch presents requests on
      // trap/MRET/FENCE-class flush cycles by design (the front-end kill
      // arrives a cycle late), and the alloc enables drop them exactly like
      // the ROB's alloc_en, for both flush_all and flush_en.  The FORMAL
      // section asserts the suppression.
      if (i_alloc_2.valid && i_alloc.valid && full_for_2)
        $warning("SQ: slot-2 alloc attempted when full_for_2 (and slot-1 firing)");
      if (i_alloc_2.valid && !i_alloc.valid && full)
        $warning("SQ: slot-2 alloc attempted alone when full");
      // Dispatch must never allocate in the deferred tail-pullback cycle:
      // the tail is stale until the pullback lands, so an accepted alloc
      // would write sq_valid outside the post-pullback ring window.  The
      // alloc enables gate only on the flush pulse itself (as the ROB does);
      // this cycle is a dispatch-side contract: the front-end
      // redirect/refill latency after any partial flush keeps dispatch
      // quiet for several cycles (the FORMAL section assumes the same).
      if ((i_alloc.valid || i_alloc_2.valid) && flush_pullback_pending)
        $error("SQ: allocation attempted during flush tail-pullback cycle");
      if (slot1_alloc_en && slot2_alloc_en && (alloc_target[IdxWidth-1:0] == slot2_alloc_idx))
        $error("SQ: slot-1 and slot-2 alloc collide on entry %0d", alloc_target[IdxWidth-1:0]);
      if (slot2_alloc_en != slot2_alloc_en_reference)
        $error("SQ: expanded slot-2 allocation enable differs from the reference");
      if (slot2_alloc_oh != slot2_alloc_oh_reference)
        $error("SQ: expanded slot-2 allocation pulses differ from the reference");
      if ((|slot1_alloc_oh) != slot1_alloc_en || !$onehot0(slot1_alloc_oh))
        $error("SQ: slot-1 allocation pulse lost or invented an accepted request");
      if (alloc_oh != (slot1_alloc_oh | slot2_alloc_oh) || (|(slot1_alloc_oh & slot2_alloc_oh)))
        $error("SQ: merged allocation pulses differ from the slot pulses");
      if (live_count_next != live_count_next_reference)
        $error("SQ: selected live-count candidate differs from the adder form");
      if (dispatch_full_next != dispatch_full_next_reference ||
          dispatch_full_for_2_next != dispatch_full_for_2_next_reference)
        $error("SQ: selected dispatch back-pressure differs from the adder form");
    end
  end
`endif
`endif


  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef SQ_LIVE_COUNT_LOCAL_PROOF
  logic [CountWidth-1:0] f_count_none, f_count_one, f_count_both;
  assign f_count_none = live_count_q - live_remove_count;
  assign f_count_one  = f_count_none + CountWidth'(alloc_room_1);
  assign f_count_both = f_count_one + CountWidth'(alloc_room_2);
  always_comb begin
    assert (live_count_if_none == f_count_none);
    assert (live_count_if_one == f_count_one);
    assert (live_count_if_both == f_count_both);
    assert (live_count_next == live_count_q + CountWidth'(slot1_alloc_en) +
        CountWidth'(slot2_alloc_en) - live_remove_count);
  end
`endif

`ifdef FORMAL
`ifndef SQ_LIVE_COUNT_LOCAL_PROOF
`ifndef SQ_COMMITTED_EMPTY_LOCAL_PROOF

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // -------------------------------------------------------------------------
  // Structural constraints (assumes)
  // -------------------------------------------------------------------------

  // Alloc requests may arrive during flush (dispatch presents without flush
  // gating for timing, and does so on trap/MRET/FENCE-class flush cycles in
  // the real core).  The alloc enables carry the same
  // !i_flush_all && !i_flush_en gate as the ROB's alloc_en, so a flush-cycle
  // request must never write queue state.
  always_comb begin
    if (i_rst_n && (i_flush_all || i_flush_en)) begin
      p_no_alloc_during_flush : assert (!slot1_alloc_en && !slot2_alloc_en);
    end
  end

  // The expanded allocation pulses are exactly the enable-then-steer form.
  always_comb begin
    if (i_rst_n) begin
`ifndef SYNTHESIS
      // The enable-then-steer references are declared outside synthesis.
      p_slot2_alloc_en_reference : assert (slot2_alloc_en == slot2_alloc_en_reference);
      p_slot2_alloc_oh_reference : assert (slot2_alloc_oh == slot2_alloc_oh_reference);
      // The per-outcome count candidates selected by the valids equal the
      // reference adder forms.
      p_live_count_next_reference : assert (live_count_next == live_count_next_reference);
      p_dispatch_full_next_reference : assert (dispatch_full_next == dispatch_full_next_reference);
      p_dispatch_full_for_2_next_reference :
      assert (dispatch_full_for_2_next == dispatch_full_for_2_next_reference);
`endif
      p_slot1_alloc_onehot0 : assert ($onehot0(slot1_alloc_oh));
      p_slot1_alloc_preserved : assert ((|slot1_alloc_oh) == slot1_alloc_en);
      p_alloc_onehots_disjoint : assert (!(|(slot1_alloc_oh & slot2_alloc_oh)));
      p_alloc_oh_is_slot_union : assert (alloc_oh == (slot1_alloc_oh | slot2_alloc_oh));
    end
  end

  // No allocation during the deferred tail-pullback cycle that follows a
  // partial flush: the tail is stale until the pullback lands, so an
  // accepted alloc would land outside the post-pullback ring window.  This
  // is a dispatch-side contract (the front-end redirect/refill latency after
  // any partial flush keeps dispatch quiet well past this cycle); the
  // simulation assertion block (ifndef FORMAL, above) checks it against the
  // real dispatcher with an $error.
  always_comb begin
    if (flush_pullback_pending) assume (!i_alloc.valid);
    if (flush_pullback_pending) assume (!i_alloc_2.valid);
  end

  // No combinational commit pulse during a flush: the ROB gates
  // commit_ready_early (source of i_commit_valid_comb/_comb_2) with
  // !i_flush_en && !i_flush_all, so the flush-kill needs no same-cycle
  // commit guard. The simulation assertion block checks the partial-flush
  // half of this contract against the real ROB.
  always_comb begin
    if (i_flush_en || i_flush_all) begin
      assume (!i_commit_valid_comb);
      assume (!i_commit_valid_comb_2);
    end
  end

  // Pure-tail allocation must always land on a free slot (ring position ==
  // program order among live entries).
  always_comb begin
    if (i_rst_n && slot1_alloc_en) begin
      p_alloc_slot_free : assert (!sq_valid[alloc_target[IdxWidth-1:0]]);
    end
    if (i_rst_n && slot2_alloc_en) begin
      p_alloc2_slot_free : assert (!sq_valid[slot2_alloc_idx]);
    end
  end

  // Slot-2 must respect capacity given whether slot-1 is also firing.
  always_comb begin
    if (i_alloc.valid && full_for_2) assume (!i_alloc_2.valid);
    if (!i_alloc.valid && full) assume (!i_alloc_2.valid);
    if (i_alloc.valid && i_alloc_2.valid) assume (i_alloc.rob_tag != i_alloc_2.rob_tag);
  end

  // Address/data updates may arrive during flush (RS stage2 issues without
  // same-cycle flush gating for timing closure).  This is safe:
  //   - flush_all: the else-if branch resets all control state; update code
  //     in the else branch is unreachable, and payload writes land in dead
  //     slots.
  //   - flush_en: CAM matches only entries with sq_valid[i]==1; entries
  //     whose valid is being cleared on the same edge get a harmless
  //     write into a dead slot.

  // No allocation when full
  always_comb begin
    if (full) assume (!i_alloc.valid);
  end

  // Memory write done only when at least one write is in flight
  always_comb begin
    assume (!i_mem_write_done || (write_inflight_cnt != 2'd0));
  end

  // Registered commits may overlap with flush due to commit bus pipelining.
  // This is safe: flush_all resets all SQ state (else-if priority over
  // commit processing), and the partial-flush kill spares any entry whose
  // registered commit pulse arrives in the flush cycle.

  // Scan-variant commit pulses: identical to the architectural pulses off
  // full-flush cycles (the wrapper omits only the full-flush mask term).
  // On i_flush_all cycles they are left free: the architectural pulses are
  // then 0 and the scan pulses may assert for the squashed commit, which is
  // the over-approximation the capture-then-kill contract tolerates.
  always_comb begin
    if (!i_flush_all) begin
      assume (i_commit_valid_scan == i_commit_valid);
      assume (i_commit_valid_scan_2 == i_commit_valid_2);
    end
  end

  // -------------------------------------------------------------------------
  // Combinational assertions
  // -------------------------------------------------------------------------

  // Number of valid entries.
  logic [CountWidth-1:0] f_valid_count;
  always_comb begin
    f_valid_count = '0;
    for (int i = 0; i < DEPTH; i++) begin
      f_valid_count = f_valid_count + {{(CountWidth - 1) {1'b0}}, sq_valid[i]};
    end
  end

  // Window sanity.  Capacity is the ring window (tail - head), which may
  // exceed the live popcount when the window holds dead slots (killed
  // entries awaiting the tail pullback, or freed entries and sc_discard
  // holes the head has not passed), so full && empty is a legal transient.
  // The invariants that do hold:
  //   - the window never exceeds DEPTH;
  //   - live entries never exceed the window (ring integrity);
  //   - a fully-dead window self-heals: with no flush activity in the way,
  //     the head collapses onto the tail on the next edge.
  always_comb begin
    if (i_rst_n) begin
      p_window_sane : assert (window_occupancy <= PtrWidth'(DEPTH));
      p_count_le_window : assert ({1'b0, f_valid_count} <= {1'b0, window_occupancy});
    end
  end

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && !i_flush_all && $past(
            i_rst_n
        ) && !$past(
            i_flush_all
        ) && $past(
            o_full && o_empty && !i_flush_en && !flush_pullback_pending
        )) begin
      p_dead_window_collapses : assert (head_ptr == tail_ptr);
    end
  end

  // count consistent with valid entries
  always_comb begin
    if (i_rst_n) begin
      p_count_consistent : assert (o_count == f_valid_count);
      p_empty_matches_valid : assert (o_empty == (f_valid_count == CountWidth'(0)));
      p_dispatch_count_exact : assert (o_dispatch_count == f_valid_count);
      p_dispatch_empty_exact : assert (o_dispatch_empty == o_empty);
      p_live_remove_bounded : assert (live_remove_count <= live_count_q);
      if (!i_flush_all) begin
        p_live_count_next_bounded : assert (live_count_next <= CountWidth'(DEPTH));
      end
    end
  end

  // If all entries are valid, the queue must report full.
  always_comb begin
    if (i_rst_n) begin
      p_all_valid_implies_full : assert (f_valid_count < CountWidth'(DEPTH) || o_full);
    end
  end

  // Memory write only for an entry that is committed + addr_valid +
  // data_valid + still valid.  The on-bus write's entry index is the staging
  // register captured at its fire cycle (entries stay valid until done, so
  // these hold under drain pipelining).
  always_comb begin
    if (i_rst_n && o_mem_write_en) begin
      p_write_needs_committed : assert (sq_committed[mem_write_entry_idx_stg]);
      p_write_needs_addr : assert (sq_addr_valid[mem_write_entry_idx_stg]);
      p_write_needs_data : assert (sq_data_valid[mem_write_entry_idx_stg]);
      p_write_from_valid : assert (sq_valid[mem_write_entry_idx_stg]);
    end
  end

  // In-flight discipline: never more than the 2-deep metadata FIFO can
  // hold, and a special (cached / MMIO) write flies alone.
  always_comb begin
    if (i_rst_n) begin
      p_inflight_bound : assert (write_inflight_cnt <= 2'd2);
      p_special_alone :
      assert (!write_inflight_special ||
                                (({1'b0, write_inflight_cnt} + {2'b0, o_mem_write_en}) <= 3'd1));
    end
  end

  // Forwarding outputs are driven from staged SQ CAM results, so they reflect
  // the previous check.
  always @(posedge i_clk) begin
    // The forwarding output register's write condition is the capture
    // enable (flush-free; see load_queue.o_sq_check_capture_valid), so the
    // no-result-without-check property tracks that signal.
    if (f_past_valid && i_rst_n && $past(
            i_rst_n
        ) && !$past(
            i_flush_all
        ) && !$past(
            i_sq_check_capture_valid
        )) begin
      p_no_fwd_without_check : assert (!o_sq_forward.match);
    end
  end

  // can_forward implies match
  always_comb begin
    if (i_rst_n) begin
      p_can_fwd_implies_match : assert (!o_sq_forward.can_forward || o_sq_forward.match);
    end
  end

  // Committed entries are never flushed: after a partial flush, every entry
  // that was committed and valid before it is still valid or already sent.
  logic [DEPTH-1:0] f_committed_before;
  always @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      f_committed_before <= '0;
    end else begin
      f_committed_before <= sq_committed & sq_valid;
    end
  end

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n) && !$past(i_flush_all)) begin
      if ($past(i_flush_en)) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (f_committed_before[i])
            assert (sq_valid[i] || sq_sent[i]);  // p_committed_survives_flush
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // Sequential assertions
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin

      // Allocation writes a valid entry at the pre-alloc tail index
      if ($past(
              i_alloc.valid
          ) && !$past(
              full
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_flush_en
          ) && !i_flush_all && !i_flush_en) begin
        p_alloc_advances_tail : assert (sq_valid[$past(alloc_target[IdxWidth-1:0])]);
      end

      // flush_all empties SQ
      if ($past(i_flush_all)) begin
        p_flush_all_empties : assert (o_empty && o_count == '0);
        p_flush_all_clears_visibility :
        assert (sq_valid == '0 && sq_addr_valid == '0 && sq_data_valid == '0 &&
                sq_committed == '0 && sq_sent == '0 && o_committed_empty);
        p_flush_all_suppresses_memory_write :
        assert (!o_mem_write_en && !o_cache_invalidate_valid && write_inflight_cnt == '0);
      end
    end

    // Reset properties
    if (f_past_valid && i_rst_n && !$past(i_rst_n)) begin
      p_reset_empty : assert (o_empty);
      p_reset_count_zero : assert (o_count == '0);
    end
  end

  // -------------------------------------------------------------------------
  // Cover properties
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_alloc : cover (i_alloc.valid && !full);
      cover_addr_update : cover (i_addr_update.valid);
      cover_data_update : cover (i_data_update.valid);
      cover_commit : cover (i_commit_valid);
      cover_mem_write : cover (o_mem_write_en);
      cover_mem_done : cover (i_mem_write_done && (write_inflight_cnt != 2'd0));
      cover_forward_match : cover (o_sq_forward.match);
      cover_forward_data : cover (o_sq_forward.can_forward);
      cover_full : cover (full);
      cover_flush_nonempty : cover (i_flush_en && |sq_valid);

      // Committed entry survives partial flush
      cover_committed_survives : cover (i_flush_en && |(sq_valid & sq_committed));

      // Pipelined drain: two plain fast-tier writes in flight at once.
      cover_pipelined_drain : cover (o_mem_write_en && (write_inflight_cnt != 2'd0));
      // Exercise the event counter's widest update: two accepted stores while
      // an older completed store is removed on the same edge.
      cover_dual_alloc_with_drain_remove :
      cover (slot1_alloc_en && slot2_alloc_en && drain_remove_valid);
      // The union mask must count an SC only once when discard and partial
      // flush both remove it.
      cover_sc_discard_in_flush :
      cover (i_flush_en && (|(flush_kill_base & sc_discard_remove_mask)));

      // Cache invalidation at memory write launch
      cover_cache_invalidate : cover (o_cache_invalidate_valid);
    end
  end

`endif  // SQ_COMMITTED_EMPTY_LOCAL_PROOF
`endif  // SQ_LIVE_COUNT_LOCAL_PROOF
`endif  // FORMAL

`ifndef SYNTHESIS
`ifndef FORMAL
  // Ring-order invariants for the pure-tail allocator: no allocation is
  // accepted in a partial-flush cycle or the pullback cycle after it (the
  // tail-pullback and tail-advance arms are mutually exclusive), and tail
  // allocation must always land on a free slot (ring position == program
  // order among live entries).
  //
  // Simulation-only flavor: Yosys's SV frontend does not parse the
  // `assert ... else $error(...)` action blocks, so this block is hidden
  // from the formal flow.  The FORMAL section above asserts the flush-cycle
  // and free-slot invariants and assumes the pullback-cycle contract.
  always_ff @(posedge i_clk) begin
    if (i_rst_n && !i_flush_all) begin
      a_no_alloc_during_flush :
      assert (!(i_flush_en && (slot1_alloc_en || slot2_alloc_en)))
      else $error("SQ allocation during partial flush conflicts with tail pullback");
      // The pullback lands one cycle after the flush; the tail is stale
      // until then, so dispatch must not allocate in that cycle either.
      // The front-end redirect/refill latency guarantees this with cycles to
      // spare; this assertion checks the contract.
      a_no_alloc_during_pullback :
      assert (!(flush_pullback_pending && (slot1_alloc_en || slot2_alloc_en)))
      else $error("SQ allocation during deferred tail pullback cycle");
      if (slot1_alloc_en) begin
        a_alloc_slot_free :
        assert (!sq_valid[alloc_target[IdxWidth-1:0]])
        else $error("SQ tail allocation hit a valid entry");
      end
      if (slot2_alloc_en) begin
        a_alloc2_slot_free :
        assert (!sq_valid[slot2_alloc_idx])
        else $error("SQ slot-2 tail allocation hit a valid entry");
      end
    end
  end
`endif  // FORMAL
`endif  // SYNTHESIS


endmodule
