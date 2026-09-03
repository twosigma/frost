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
 * Commit-ordered store queue with forwarding. DEPTH circular entries allocate
 * in program order; stores reach memory only after ROB commit. The ready
 * drain-cursor entry writes in order, approaching one per cycle for plain
 * fast-tier stores, and frees when the write completes.
 *
 * Address/data updates use a parallel tag CAM. Control and forwarding fields
 * remain in FFs; the drain payload uses sdp_dist_ram plus a per-entry FF mirror
 * for forwarding. The forwarding tree carries only its winning index and
 * extraction metadata across the LQ boundary. Valid bits gate stale payload.
 *
 * All sizes, including doubles, drain as one 64-bit beat. MMIO stores bypass
 * the cache; writes also invalidate the LQ L0. Partial flush removes only
 * uncommitted entries younger than flush_tag; full flush removes all.
 * Lifecycle: allocate → address/data ready → ROB commit → memory done.
 */

module store_queue #(
    parameter int unsigned DEPTH = riscv_pkg::SqDepth,  // 8
    // Trust dispatch's alloc valids to already embed SQ room.  Dispatch gates
    // its per-slot mem valids on the registered conservative flags
    // (o_dispatch_full/_for_2), and the window math never reclaims a slot in
    // the same cycle it frees, so !dispatch_full_q implies live !full.  The
    // local !full/!full_for_2 re-checks below are then redundant and only
    // lengthen the dispatch -> live_count/sq_valid commit cones.
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
    // both fire, slot-1 is older than slot-2 in program order and must be
    // allocated to a lower physical position so the in-order commit/drain at
    // head_idx delivers stores to memory in program order.
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
    // below continues to set sq_data_valid only from i_data_update.valid.
    input logic i_data_update_capture_valid,

    // =========================================================================
    // Commit (from ROB commit bus, filtered for stores)
    // =========================================================================
    input logic                                        i_commit_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag,

    // Combinational commit view from ROB (unregistered).  No longer a flush
    // guard: the ROB gates commit_ready_early (the driver of these pulses)
    // with !i_flush_en && !i_flush_all, so a comb commit can never overlap a
    // flush (asserted below).  These ports now only pessimistically clear
    // committed_empty so fences/SCs cannot observe stale empty while a
    // store commit is entering the SQ pipeline.
    input logic                                        i_commit_valid_comb,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag_comb,

    // Widen-commit slot 2: second simultaneous store retire.  Slot 2 is
    // mutually exclusive with SC/AMO/LR/fence by the ROB hazard gate, so
    // the SC-discard path is not shared with slot 2.  Both a registered
    // and a combinational variant are plumbed in parallel to slot 1.
    input logic                                        i_commit_valid_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag_2,
    input logic                                        i_commit_valid_comb_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag_comb_2,

    // Trap-cone-free commit pulses for the forwarding scan only (same tags as
    // i_commit_valid/_2).  They are i_commit_valid/_2 with the full-flush
    // mask (the registered trap/MRET/FENCE-class pulse) omitted, which keeps
    // the trap cone off the o_sq_forward capture D-pins (x3 post-opt -0.138,
    // 65 endpoints).  They differ from the architectural pulses only on the
    // full-flush cycle, where the captured probe result is structurally
    // unconsumable (capture-then-kill: o_sq_check_valid is flush-gated,
    // sq_check_phase2 clears, consumers require phase-2 lineage).  The
    // architectural consumers (sq_committed, committed_empty, flush_kill
    // exemption) keep the masked pulses: a squashed store must not latch
    // committed state.
    input logic i_commit_valid_scan,
    input logic i_commit_valid_scan_2,

    // =========================================================================
    // Store-to-Load Forwarding (from LQ disambiguation)
    // =========================================================================
    input logic i_sq_check_valid,
    // Flush-free capture-enable variant for the forwarding unit's output
    // register only (see load_queue.o_sq_check_capture_valid).
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
    // Registered MMIO flag for the current head entry. Consumers at the
    // top level use this to gate the BRAM byte-write-enable at the SQ source
    // rather than recomputing an address-range check combinationally on the
    // muxed data memory address (which drags the LQ issue cone onto WEA).
    output logic                              o_mem_write_is_mmio,
    // Registered cached-tier flag for the current head entry (parallels is_mmio).
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
    input logic                                        i_early_recovery_flush,

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
  // sq_data is written once (data_update CAM match) and read by the drain side
  // at drain_idx_q.  Store-to-load forwarding mirrors the same payload into
  // per-entry registers.  The forwarding unit registers the winning index and
  // selects this mirror during the following LQ consume cycle, so the CAM /
  // winner tree does not drive 64 output-register D-pins.  Valid bits in FFs
  // gate all reads; alloc-time zeroing is unnecessary.

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
  // removal events that update sq_valid.  It is a timing boundary: LQ issue
  // consumes empty, so deriving empty directly from the sq_valid popcount put
  // every SQ valid bit in the cache-read launch cone.  The counter changes on
  // the same edge as sq_valid and therefore preserves the old post-edge
  // visibility without adding a queue or issue cycle.
  (* keep = "true" *)logic [CountWidth-1:0] live_count_q;
  logic [CountWidth-1:0] live_count_next;
  logic [CountWidth-1:0] live_remove_count;
  logic [     DEPTH-1:0] live_remove_mask;
  logic [     DEPTH-1:0] sc_discard_remove_mask;
  logic                  drain_remove_valid;
  logic [CountWidth-1:0] dispatch_count_next;
  logic                  committed_empty_q;

  // Slot-1 / slot-2 alloc targets and write enables (assigned below).
  logic [  PtrWidth-1:0] alloc_target_2;
  logic                  slot1_alloc_en;
  logic                  slot2_alloc_en;
  logic [  IdxWidth-1:0] slot2_alloc_idx;

  // Memory write tracking.  Plain fast-tier drains (BRAM, non-MMIO,
  // single-beat FSD included) are pipelined: up to two writes may be in
  // flight (one on the bus, one awaiting its 1-cycle done), tracked by
  // write_inflight_cnt plus a 2-deep in-order metadata FIFO (entry index +
  // completes flag, popped one per done).  Cached / MMIO writes stay
  // strictly single-outstanding (write_inflight_special): the cached
  // adapter keeps one store in flight and MMIO dispatch is serialized.
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

  // Head/tail search targets for the sparse valid-bit queue.
  logic [PtrWidth-1:0] head_advance_target;
  logic [PtrWidth-1:0] alloc_target;
  logic                flush_all_uncommitted;

  // ===========================================================================
  // Count, Full, Empty
  // ===========================================================================
  // Capacity is the ring window (tail - head), not the live popcount: with
  // pure tail allocation, a slot is reusable only once the head has passed
  // it, so holes inside the window (rare sc_discard frees) still consume
  // capacity until the head skip-advance walks over them.  Window-based full
  // is conservative in exactly those cases and exact otherwise.  The live
  // count is separate event-maintained state so that empty does not put the
  // sq_valid reduction tree in the LQ/cache issue cone.
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
  // valid; if both fire, slot-1 (older) takes the first free slot from
  // tail_ptr and slot-2 (younger) takes the second so the SQ's in-order
  // commit/drain at head_idx writes stores to memory in program order.
  //
  // Flush gating mirrors the ROB's alloc_en (!i_flush_all && !i_flush_en).
  // Dispatch presents alloc requests without flush gating, because the
  // dispatch-fire cone must not absorb the flush broadcast.  On trap/MRET/
  // FENCE-class pulse cycles the frontend kill is edge-delayed, so a
  // straggler can present here: a wrong-path instruction, or the FENCE-class
  // owner's to-be-refetched successor.  Every allocation target therefore
  // decides locally and must reach the same verdict as the ROB on the same
  // cycle.  The ROB rejects; without these terms a flush_en-cycle alloc
  // wrote a ghost entry.  The sq_valid alloc arm runs after the
  // partial-flush kill loop (last-write-wins) while the tail arm gives the
  // flush priority, so the ghost sat valid with the tail never advanced:
  // outside the ring window, with a tag the ROB never allocated, waiting for
  // a later real alloc to land on top of it (p_alloc_slot_free violation).
  // flush_all cycles were already benign (priority else-if branch) but still
  // wrote the no-reset payload flops; the gate silences those too.
  logic alloc_flush_ok;
  assign alloc_flush_ok = !i_flush_all && !i_flush_en;
  assign slot1_alloc_en = TRUST_DISPATCH_VALID ? (i_alloc.valid && alloc_flush_ok)
                                               : (i_alloc.valid && !full && alloc_flush_ok);
  assign slot2_alloc_en = TRUST_DISPATCH_VALID ?
      (i_alloc_2.valid && alloc_flush_ok) :
      (i_alloc_2.valid && (slot1_alloc_en ? !full_for_2 : !full) && alloc_flush_ok);

`ifndef SYNTHESIS
  // TRUST_DISPATCH_VALID drops the local room re-checks from the alloc
  // enables; pin bit-exact equivalence with the untrusted computation so any
  // contract break (an alloc valid while the window is full) fails loudly in
  // simulation instead of ghost-writing an occupied slot.  Edge-sampled: all
  // alloc_en consumers (live_count/tail/sq_valid/payload writes) are clocked,
  // so the contract binds at the capture edge only.  Bench pacing may leave a
  // refused valid high for a harmless half-cycle after the fill edge.
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
    // the live window (no same-cycle reclaim ever shrinks it early); this is
    // the invariant the trusted alloc enables ride on.
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
  // slot is reusable, and dispatch would send an alloc the SQ refuses (a
  // silently lost store).  Back-pressure is therefore only ever
  // conservatively long, never short.
  always_comb begin
    dispatch_count_next = CountWidth'(window_occupancy) + CountWidth'(slot1_alloc_en) +
                          CountWidth'(slot2_alloc_en);
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      dispatch_full_q <= 1'b0;
      dispatch_full_for_2_q <= 1'b0;
    end else begin
      dispatch_full_q <= dispatch_count_next == CountWidth'(DEPTH);
      dispatch_full_for_2_q <= dispatch_count_next >= CountWidth'(DEPTH - 1);
    end
  end

  // Committed-empty: no committed-but-unwritten entries. Register this status
  // for consumers that feed MEM issue/CDB arbitration. Raw same-cycle commit
  // pulses pessimistically clear the bit so fences/SCs cannot observe stale
  // empty while a store commit is entering the SQ pipeline.
  logic any_committed;
  always_comb begin
    any_committed = 1'b0;
    for (int i = 0; i < DEPTH; i++) if (sq_valid[i] && sq_committed[i]) any_committed = 1'b1;
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      committed_empty_q <= 1'b1;
    end else begin
      committed_empty_q <= !any_committed &&
                           !i_commit_valid &&
                           !i_commit_valid_2 &&
                           !i_commit_valid_comb &&
                           !i_commit_valid_comb_2;
    end
  end

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
      .i_sq_check_valid          (i_sq_check_valid),
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
  // register-addressed exactly like the old head_idx.  Program order is
  // preserved by construction: the cursor is the oldest undrained entry,
  // and nothing fires while that entry is not drain-ready.
  logic [   DEPTH-1:0] drain_mask_base;
  logic [   DEPTH-1:0] drain_mask_post_fire;
  logic [IdxWidth-1:0] drain_idx_q;

  logic                mem_write_fire_next;
  logic                mem_write_completes_next;
  logic                mem_write_plain_fast_next;
  logic                drain_complete_fire_next;

  // drain_complete_fire_next carries the selected entry's late address/tier
  // classification, so feeding it into every mask bit before the above-head
  // and absolute priority scans put both encoders in that late path.
  // Instead, the F=0 base mask and the F=1 post-fire mask are computed in
  // parallel, each with its complete ring-priority scan, and only a final
  // three-bit mux depends on the late fire decision.  This is the exact
  // Shannon expansion of M[i] = base[i] && !(fire && drain_idx_q == i); the
  // oracle below retains that original expression.
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
  // Equivalence oracle for the original fire-in-mask implementation, including
  // its empty-mask head fallback and retired rotate-encode-add scan.
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
  // data_valid.  Every size drains in a single beat (FSD included).
  //
  // The write interface is registered to break the head_ptr → drain_ready →
  // o_mem_write_en combinational cone that was the critical path (-1.059 ns
  // WNS).  drain_ready feeds the combinational next-state of a pipeline
  // register; the o_mem_write_en output itself is a flop.
  //
  // Drain pipelining: plain fast-tier stores (BRAM, non-MMIO, single-beat
  // FSD included) complete exactly one cycle after their bus cycle (the
  // router's sq_write_done_fast is the write-enable delayed one cycle), so
  // consecutive plain drains overlap: a new launch is allowed while the
  // previous write's done is still in flight, bounded to two in-flight by
  // the metadata FIFO.  Cached / MMIO writes keep the strict
  // one-at-a-time gate (write_inflight_cnt == 0 && !o_mem_write_en).

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
    // are one 64-bit write, so no phase legs and no +4 second beat.
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
  // Single-beat doubles: every launch completes its entry, and DOUBLE joins
  // the pipelined plain fast-tier drain (the old two-phase FSD flew alone).
  // The write-FIFO completes plumbing is kept constant-true rather than
  // excised; synthesis sweeps it.
  assign mem_write_completes_next = 1'b1;
  assign mem_write_plain_fast_next = !sq_is_mmio[drain_idx_q] &&
                                     !mem_write_addr_cached_for_plain_next;

  // Launch gate: legacy serial arm for any write type, plus the pipelined
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
  // Invalidate the LQ's L0 cache at the written address in the same cycle
  // the write fires.  Invalidating at launch instead of at write-done closes
  // the stale-L0-hit window for any write latency with no extra gating:
  // between launch and done nobody can read the old memory word either (the
  // router owns the shared port and queues/replays reads behind the write
  // flight), so the only reachable outcomes are an L0 miss plus a memory
  // read ordered behind the write.  Early invalidation is always safe; at
  // worst it costs one refill miss.  The previous done-time pulse left the
  // L0 line live during a multi-cycle cached write flight.  Papering over
  // that with a busy-stretch in the LQ taxed every BRAM store drain (~2%
  // CoreMark), and routing the cached-flight signal into the LQ's busy
  // instead pushed the L0-hit/CDB cone past timing.  Both outputs come straight from SQ output
  // registers, adding no new logic levels anywhere.
  // A single-beat FSD covers its whole dword with one pulse (the LQ's L0 is
  // dword-granule, and the wrapper reservation snoop widens on is_dword).
  // MMIO stores also pulse harmlessly (the L0 never caches MMIO).
  assign o_cache_invalidate_valid = o_mem_write_en;
  assign o_cache_invalidate_addr = o_mem_write_addr;

  // ===========================================================================
  // Allocation (pure ring tail)
  // ===========================================================================
  // Allocate strictly at the ring tail. Ring position must encode program
  // order for the head-ordered drain to deliver stores to memory in program
  // order; the previous policy ("keep sparse holes after partial flush and
  // search forward from tail_ptr for the next invalid slot") let younger
  // stores land in flush holes at ring positions the head reaches before
  // older live entries.  Committed older stores then stranded behind a
  // younger uncommitted hole-filler (the linear_alg LQ/SQ deadlock), and
  // same-address stores could drain out of program order, leaving stale
  // data in memory (the cjpeg output corruption). Partial flush now pulls
  // tail_ptr back over the killed suffix instead (see Flush Tail Pullback),
  // so flush holes never persist; the only remaining holes are rare
  // sc_discard frees, which the head skip-advance walks over without reuse.
  assign flush_all_uncommitted = i_flush_after_head_commit;
  assign alloc_target = tail_ptr;
  assign alloc_target_2 = tail_ptr + PtrWidth'(1);

  // ===========================================================================
  // Flush Tail Pullback (retimed: applies the cycle after the flush)
  // ===========================================================================
  // A partial flush kills a program-order suffix of the live window (all
  // uncommitted entries younger than flush_tag), so the window is rebuilt as
  // [head_ptr, youngest_survivor + 1).
  //
  // The pullback used to be computed in the flush cycle from a survivor mask
  // that mirrored the kill predicate, i.e. from i_flush_en, i_flush_tag and
  // the same-cycle ROB commit pulses, all of which arrive late out of the
  // ROB-head commit cone.  Survivor mask → rotate → priority-encode → adder
  // then converged on the tail_ptr D and head_ptr CE pins: an 18-LUT-level
  // path (post-opt WNS -1.36 at 300 MHz).  Now the flush cycle only clears
  // per-entry valid bits (short, per-entry endpoints) while both pointers
  // hold.  One cycle later, while flush_pullback_pending is set, the tail is
  // rebuilt from the registered post-kill valid mask and head_ptr, a
  // full-cycle path from FF outputs.
  //
  // The deferred cycle is safe because:
  //  - dispatch cannot allocate in the flush cycle or the cycle after (the
  //    front-end redirect/refill takes several cycles; asserted below), so
  //    nothing consumes the stale tail for allocation;
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
  // valid=0, exactly as the old survivor mask treated them.  With no valid
  // entry left the window collapses to the held head pointer.  Trailing
  // sc_discard holes (no live entry younger than them) are reclaimed by the
  // pullback, which is safe: only reclaiming a hole with live entries beyond
  // it would break the ring-order invariant.
  // (The pullback encoder lives just below the Head Advancement section so it
  // can share sq_head_valid_rotated.)

  // ===========================================================================
  // Head Advancement (tree-based find-first-valid from head)
  // ===========================================================================
  // The scan is rotate → tree-priority-encode → add-back, O(log2(DEPTH))
  // logic levels.  The O(DEPTH) serial scan it replaced created a 16-level
  // chain through cascaded pointer increments; the tree form is ~4-5 levels.
  // Empty visibility has its own live_count_q timing boundary (above), so
  // this scan cannot leak into LQ issue through o_empty.

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
      // Slot-1 alloc.  Slot-2 alloc (below) writes a different physical entry,
      // so the non-blocking writes never collide on a bit.
      if (slot1_alloc_en) begin
        sq_addr_valid[alloc_target[IdxWidth-1:0]] <= i_alloc.addr_valid;
        sq_data_valid[alloc_target[IdxWidth-1:0]] <= 1'b0;
        sq_committed[alloc_target[IdxWidth-1:0]]  <= 1'b0;
        sq_sent[alloc_target[IdxWidth-1:0]]       <= 1'b0;
      end

      // Slot-2 alloc.
      if (slot2_alloc_en) begin
        sq_addr_valid[slot2_alloc_idx] <= i_alloc_2.addr_valid;
        sq_data_valid[slot2_alloc_idx] <= 1'b0;
        sq_committed[slot2_alloc_idx]  <= 1'b0;
        sq_sent[slot2_alloc_idx]       <= 1'b0;
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
      // cycle.  The latter is a dispatch-side contract, enforced by the
      // $error tripwire in the sim-assertion block and assumed in the FORMAL
      // section; the front-end redirect/refill latency after any partial
      // flush keeps dispatch quiet well past that cycle.
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
        // launches until completion. Single-beat FSD uses the plain fast arm.
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
  // A same-cycle combinational commit guard (i_commit_valid_comb/_comb_2
  // tag-match "protect" terms) used to sit on this kill for the
  // commit-overlaps-flush race: without it a store committing in the flush
  // cycle was invalidated and its memory write silently lost (dropped UART
  // chars / corrupted cjpeg output bytes in the system runs).  That race is
  // now structurally impossible.  The ROB gates commit_ready_early (and
  // therefore o_commit_store_like_raw / o_commit_2_store_like_raw, the
  // drivers of i_commit_valid_comb/_comb_2) with !i_flush_en && !i_flush_all
  // on the same flush nets this kill branch runs under, so the combinational
  // commit pulses are 0 in every cycle the kill can execute.  Dropping the
  // dead guard keeps the ROB head-commit cone (head_clear_mask onehot read)
  // out of the sq_valid write path; the assertion below (and the matching
  // formal assume) pin the invariant.
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

  always_comb begin
    live_remove_count = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      live_remove_count = live_remove_count + CountWidth'(live_remove_mask[i]);
    end

    live_count_next = live_count_q + CountWidth'(slot1_alloc_en) +
                      CountWidth'(slot2_alloc_en) - live_remove_count;
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      live_count_q <= '0;
    end else begin
      live_count_q <= live_count_next;
    end
  end

  // Simulation-only cross-check against the real ROB; under formal the same
  // invariant is an input assume in the FORMAL section below (and Yosys'
  // frontend rejects the assert-else action block anyway).
`ifndef SYNTHESIS
`ifndef FORMAL
  always_ff @(posedge i_clk) begin
    if (i_rst_n) begin
      assert (!(i_flush_en && (i_commit_valid_comb || i_commit_valid_comb_2)))
      else
        $error(
            "store_queue: combinational commit overlapped a partial flush; the flush-kill no longer guards this race"
        );
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
      // Partial flush: invalidate uncommitted entries younger than flush_tag.
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

      if (slot1_alloc_en) begin
        sq_valid[alloc_target[IdxWidth-1:0]] <= 1'b1;
      end
      // Slot-2 alloc.
      if (slot2_alloc_en) begin
        sq_valid[slot2_alloc_idx] <= 1'b1;
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
      // metadata FIFO head. Every size, including FSD, is single-beat.
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
    if (slot1_alloc_en) begin
      sq_rob_tag[alloc_target[IdxWidth-1:0]] <= i_alloc.rob_tag;
      sq_size[alloc_target[IdxWidth-1:0]]    <= i_alloc.size;
      sq_is_sc[alloc_target[IdxWidth-1:0]]   <= i_alloc.is_sc;
      if (i_alloc.addr_valid) begin
        sq_address[alloc_target[IdxWidth-1:0]] <= i_alloc.address;
        sq_is_mmio[alloc_target[IdxWidth-1:0]] <= i_alloc.is_mmio;
      end
    end

    // Slot-2 alloc.
    if (slot2_alloc_en) begin
      sq_rob_tag[slot2_alloc_idx] <= i_alloc_2.rob_tag;
      sq_size[slot2_alloc_idx]    <= i_alloc_2.size;
      sq_is_sc[slot2_alloc_idx]   <= i_alloc_2.is_sc;
      if (i_alloc_2.addr_valid) begin
        sq_address[slot2_alloc_idx] <= i_alloc_2.address;
        sq_is_mmio[slot2_alloc_idx] <= i_alloc_2.is_mmio;
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
      // No advisory for alloc-during-flush: dispatch presents on
      // trap/MRET/FENCE-class pulse cycles by design (edge-delayed frontend
      // kill; it fired ~1178x/run as the old advisory's benign flush_all
      // handshake), and the alloc enables now suppress the request exactly
      // like the ROB's alloc_en, including the formerly-unsafe flush_en
      // case.  The FORMAL section asserts the suppression.
      if (i_alloc_2.valid && i_alloc.valid && full_for_2)
        $warning("SQ: slot-2 alloc attempted when full_for_2 (and slot-1 firing)");
      if (i_alloc_2.valid && !i_alloc.valid && full)
        $warning("SQ: slot-2 alloc attempted alone when full");
      // Dispatch must never allocate in the deferred tail-pullback cycle:
      // the tail is stale until the pullback lands, so an accepted alloc
      // would write sq_valid outside the post-pullback ring window.  The
      // alloc enables gate only on the flush pulse itself (ROB parity);
      // this cycle is a dispatch-side contract: the front-end
      // redirect/refill latency after any partial flush keeps dispatch
      // quiet for several cycles (the FORMAL section assumes the same).
      if ((i_alloc.valid || i_alloc_2.valid) && flush_pullback_pending)
        $error("SQ: allocation attempted during flush tail-pullback cycle");
      if (slot1_alloc_en && slot2_alloc_en && (alloc_target[IdxWidth-1:0] == slot2_alloc_idx))
        $error("SQ: slot-1 and slot-2 alloc collide on entry %0d", alloc_target[IdxWidth-1:0]);
    end
  end
`endif

  // Debug: trace SQ drains + flush events (disabled for clean logs)
  // always @(posedge i_clk) begin
  //   if (i_rst_n && o_mem_write_en && o_mem_write_addr[31:16] == 16'h0001)
  //     $display("[SQ_DRAIN] t=%0t addr=%08x data=%08x",
  //              $time, o_mem_write_addr, o_mem_write_data);
  //   if (i_rst_n && i_flush_en) begin
  //     for (int i = 0; i < DEPTH; i++) begin
  //       if (sq_valid[i] && !sq_committed[i] &&
  //           !(i_commit_valid_comb && sq_rob_tag[i] == i_commit_rob_tag_comb) &&
  //           !(i_commit_valid      && sq_rob_tag[i] == i_commit_rob_tag) &&
  //           (flush_all_uncommitted ||
  //            is_younger(sq_rob_tag[i], i_flush_tag, i_rob_head_tag)) &&
  //           sq_addr_valid[i] && sq_address[i][31:16] == 16'h0001)
  //         $display("[SQ_ACTUALLY_FLUSHED] t=%0t idx=%0d tag=%0d addr=%08x "
  //                  "flush_tag=%0d head=%0d",
  //             $time, i, sq_rob_tag[i], sq_address[i], i_flush_tag, i_rob_head_tag);
  //     end
  //   end
  // end

`endif


  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL

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
  // gating for timing; the trap-cycle straggler handshake does exactly this
  // in the real core).  The alloc enables carry the same
  // !i_flush_all && !i_flush_en gate as the ROB's alloc_en, so a flush-cycle
  // request must never write queue state.
  // (The old assume that no allocation arrives during flush was removed.)
  always_comb begin
    if (i_rst_n && (i_flush_all || i_flush_en)) begin
      p_no_alloc_during_flush : assert (!slot1_alloc_en && !slot2_alloc_en);
    end
  end

  // No allocation during the deferred tail-pullback cycle that follows a
  // partial flush: the tail is stale until the pullback lands, so an
  // accepted alloc would land outside the post-pullback ring window.  This
  // remains a dispatch-side contract (the front-end redirect/refill latency
  // after any partial flush keeps dispatch quiet well past this cycle); the
  // simulation assertion block (ifndef FORMAL, above) checks it against the
  // real dispatcher with an $error tripwire.
  always_comb begin
    if (flush_pullback_pending) assume (!i_alloc.valid);
    if (flush_pullback_pending) assume (!i_alloc_2.valid);
  end

  // No combinational commit pulse during a flush: the ROB gates
  // commit_ready_early (source of i_commit_valid_comb/_comb_2) with
  // !i_flush_en && !i_flush_all, so the flush-kill needs no same-cycle
  // commit protect. The simulation assertion block checks the same contract
  // against the real ROB.
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
  //   - flush_all: the else-if branch resets all state; update code in the
  //     else branch is unreachable.
  //   - flush_en: CAM matches only entries with sq_valid[i]==1; entries
  //     whose valid is being cleared on the same edge get a harmless
  //     write into a dead slot.
  // (The old assume that no addr/data update arrives during flush was
  // removed.)

  // No allocation when full
  always_comb begin
    if (full) assume (!i_alloc.valid);
  end

  // Memory write done only when at least one write is in flight
  always_comb begin
    assume (!i_mem_write_done || (write_inflight_cnt != 2'd0));
  end

  // Commit may overlap with flush due to commit bus pipelining.  This is
  // safe: flush_all resets all SQ state (else-if priority over commit
  // processing), and flush_en only flushes younger entries while the
  // committed head is always older than the flush boundary.
  // (The old assume that no commit arrives during flush was removed.)

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

  // Window sanity.  Capacity is the ring window (tail - head), which may
  // exceed the live popcount when the window holds dead slots (killed
  // entries awaiting the retimed tail pullback, or sc_discard holes the
  // head has not passed), so full && empty is a legal transient, unlike
  // the old popcount-full design.  The invariants that do hold:
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
  logic [CountWidth-1:0] f_valid_count;
  always_comb begin
    f_valid_count = '0;
    for (int i = 0; i < DEPTH; i++) begin
      f_valid_count = f_valid_count + {{(CountWidth - 1) {1'b0}}, sq_valid[i]};
    end
  end

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

`endif  // FORMAL

`ifndef SYNTHESIS
`ifndef FORMAL
  // Ring-order invariants for the pure-tail allocator: dispatch must not
  // allocate in a partial-flush cycle (the tail-pullback and tail-advance
  // arms are mutually exclusive), and tail allocation must always land on a
  // free slot (ring position == program order among live entries).
  //
  // Simulation-only flavor: Yosys's SV frontend does not parse the
  // `assert ... else $error(...)` action blocks, so this block is hidden
  // from the formal flow; the FORMAL section above carries the same
  // contract as assumes (no alloc during flush or the pullback cycle) and
  // asserts the resulting invariants.
  always_ff @(posedge i_clk) begin
    if (i_rst_n && !i_flush_all) begin
      a_no_alloc_during_flush :
      assert (!(i_flush_en && (slot1_alloc_en || slot2_alloc_en)))
      else $error("SQ allocation during partial flush conflicts with tail pullback");
      // The pullback is retimed one cycle after the flush; the tail is stale
      // until it lands, so dispatch must not allocate in that cycle either.
      // The front-end redirect/refill latency guarantees this with cycles to
      // spare; this assertion is the contract.
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
