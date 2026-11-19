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
 * A cbo.zero entry keeps rs1 and writes its naturally aligned 64-byte block.
 * A cached block launches once for the L1D to allocate both sector records; an
 * uncached block uses eight zero beats and completes after the last response.
 * Cached and optional Normal buffered writes launch in order after commit.
 * Cached plain stores (not SC or cbo.zero) overlap like Normal buffered
 * writes: two may be in flight, both to the L1D, whose dones come in order.
 * PRECISE_UNCACHED otherwise waits
 * at the ROB head, launches behind the interrupt/debug shield and reports
 * the real bus completion before retirement. Each launch invalidates or
 * byte-updates the store's dword in the LQ's L0 cache. A partial flush removes
 * uncommitted entries younger than the flush point. A full flush empties the
 * queue, committed entries included, so its sources first wait for
 * o_committed_empty.
 */

module store_queue #(
    parameter bit CACHE_NORMAL_MEMORY = 1'b0,
    parameter int unsigned DEPTH = riscv_pkg::SqDepth,  // 8
    // Rely on dispatch to check SQ room. Its conservative registered full flags
    // give no credit for same-cycle frees, so !dispatch_full_q implies !full.
    // This permits omitting the local room checks.
    parameter bit TRUST_DISPATCH_VALID = 1'b0,
    // Execute precise uncached stores at the ROB head and report their bus
    // response before retirement. Cached and optional ordinary Normal stores
    // retain buffered draining; SC remains precise in either profile.
    parameter bit PRECISE_UNCACHED = 1'b0,
    // Stores in [CACHED_BASE, CACHED_BASE+CACHED_SIZE_BYTES) use the cached tier.
    // Register the tier flag with the write enable for router timing.
    parameter longint unsigned CACHED_BASE = riscv_pkg::DdrBase,
    parameter longint unsigned CACHED_SIZE_BYTES = riscv_pkg::DdrCapacityBytes,
    // Zicbom through the coherent hierarchy: a CMO of a cached DDR block
    // (through a PMA, NC or IO mapping) goes to the hart's Zicbom requester
    // and frees on its done, after the home has written a dirty line to
    // memory (clean, flush) or dropped it (inval). 0 keeps every CMO an
    // ordered no-op, for benches without the hierarchy.
    parameter bit CMO_HOME = 1'b0
) (
    // The Zicbom request: the real 64-byte block, its kind
    // (riscv_pkg::cmo_kind_e), held until i_cmo_ready; i_cmo_done pulses when
    // the hierarchy has finished it.
    output logic o_cmo_valid,
    output riscv_pkg::cmo_kind_e o_cmo_kind,
    output logic [riscv_pkg::XLEN-1:0] o_cmo_addr,
    input logic i_cmo_ready = 1'b0,
    input logic i_cmo_done = 1'b0,
    input logic i_coherent_store_pending = 1'b0,
    input logic i_coherent_store_ready = 1'b1,
    input logic i_coherent_sc_pending = 1'b0,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_coherent_sc_tag = '0,
    output logic o_coherent_write_sc,
    // The cached write is a cbo.zero of the 64-byte block at its address.
    output logic o_coherent_write_zero,
    // Another unsent store (not SC, cbo.zero or Zicbom, committed or not)
    // waits behind this write, so the L1D may keep the write's record open for
    // it (a hint only: an OR over the entries, registered with the write).
    output logic o_coherent_write_more,
    // The store queue's next write is a committed cached plain store to the
    // 32-byte sector of its last write, also a cached plain store, so the L1D
    // may grant credit for it as a combining write. Registered every cycle
    // from the cursor entry after that cycle's launch.
    output logic o_coherent_next_same,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_coherent_write_tag,
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Allocation (from Dispatch, parallel with MEM_RS dispatch)
    // =========================================================================
    input  riscv_pkg::sq_alloc_req_t i_alloc,
    // Slot 2 may allocate alone. When both slots allocate, slot 1 takes the
    // earlier ring position to preserve program-order draining.
    input  riscv_pkg::sq_alloc_req_t i_alloc_2,
    output logic                     o_full,
    // Asserted when fewer than two entries fit; dispatch gates slot 2 separately.
    output logic                     o_full_for_2,
    // Conservative dispatch status: allocations count immediately; reclaimed
    // capacity appears one cycle later. o_full and o_full_for_2 report exact room.
    output logic                     o_dispatch_full,
    output logic                     o_dispatch_full_for_2,

    // =========================================================================
    // Early Address Update (from pipelined dispatch-time address computation)
    // =========================================================================
    // Each dispatch slot supplies an update. Their distinct ROB tags each match
    // at most one SQ entry, so simultaneous writes cannot collide.
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
    // The vector memory table (idle: every entry dead), for range-ordering
    // holds: an entry does not drain while an older live vector memory
    // instruction overlaps it or has an unknown range (vec_hold_rows)
    input riscv_pkg::vmt_view_t i_vmt = '0,
    // Payload capture may remain valid for a faulted store. sq_addr_valid alone
    // exposes the address, so a hidden write is harmless and simplifies timing.
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

    // A second store retiring this cycle. The ROB retires SC, AMO, LR, and fences
    // alone, so slot 2 needs no SC discard.
    input logic                                        i_commit_valid_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag_2,
    input logic                                        i_commit_valid_comb_2,

    // Forwarding-only commit pulses with the full-flush mask omitted for timing.
    // LQ phase-2 state clears on a full flush, so the captured result is unused.
    // Architectural consumers must use masked pulses to avoid committing a
    // squashed store.
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
    // Identical registered address copies, one per CAM quarter, for fanout.
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
    output logic o_mem_write_en,
    output logic [riscv_pkg::XLEN-1:0] o_mem_write_addr,
    output logic [riscv_pkg::MemDataBits-1:0] o_mem_write_data,
    output logic [riscv_pkg::MemStrbBits-1:0] o_mem_write_byte_en,
    output riscv_pkg::mem_size_e o_mem_write_size,
    // Registered MMIO classification used to gate BRAM write enables.
    output logic o_mem_write_buffered,
    output logic o_mem_write_is_mmio,
    // Registered cached-tier flag of the write on the bus (parallels is_mmio).
    // The router steers the store's byte-write enables to the cached tier when set.
    output logic o_mem_write_is_cached,
    input logic i_mem_write_done,
    input logic i_mem_write_error = 1'b0,
    // Raised before any uncached side effect. The core holds its interrupt /
    // Debug Mode shield until retirement or a synchronous fault flush.
    output logic o_uncached_store_pending,
    input logic i_uncached_store_shield = 1'b0,
    input logic i_head_side_effects_allowed = 1'b0,
    // A successful head SC authorizes its store; a failed SC never does.
    input logic i_uncached_sc_success = 1'b0,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_uncached_sc_tag = '0,
    output riscv_pkg::fu_complete_t o_uncached_store_complete,
    input logic i_uncached_store_result_ready = 1'b0,

    // =========================================================================
    // L0 Cache Invalidation (to LQ)
    // =========================================================================
    output logic                       o_cache_invalidate_valid,
    output logic [riscv_pkg::XLEN-1:0] o_cache_invalidate_addr,
    // With o_cache_invalidate_valid: invalidate the 64-byte block at the
    // address, a cached cbo.zero, instead of its dword.
    output logic                       o_cache_invalidate_block,

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
    output logic o_empty,
    output logic o_dispatch_empty,
    output logic o_committed_empty,  // No committed entries pending write
    // Identical copies of o_committed_empty for fanout to the ROB, trap unit,
    // and LQ.
    output logic o_committed_empty_rob,
    output logic o_committed_empty_trap,
    output logic o_committed_empty_lq,
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
  // cbo.zero: write the 64-byte block containing sq_address, through the L1D
  // for cached memory or as eight zero beats for uncached memory.
  logic                 [                DEPTH-1:0] sq_is_zero;
  // cbo.clean/flush/inval name the 64-byte block containing sq_address.
  // The entry supplies the operation and address for any home write-back.
  logic                 [                DEPTH-1:0] sq_is_cmo;
  riscv_pkg::cmo_kind_e                             sq_cmo_kind                       [DEPTH];

  // Per-entry multi-bit fields
  logic                 [ReorderBufferTagWidth-1:0] sq_rob_tag                        [DEPTH];
  logic                 [                 XLEN-1:0] sq_address                        [DEPTH];
  riscv_pkg::mem_size_e                             sq_size                           [DEPTH];

  // ===========================================================================
  // sq_data storage
  // ===========================================================================
  // Write only while sq_data_valid is clear, so visible payloads never change.
  // The drain reads LUTRAM at drain_idx_q. Forwarding reads a per-entry FF
  // mirror after registering the winning index. Valid flags gate reads;
  // allocation need not zero the payload.

  // Write port: resolved CAM match index from data_update
  logic                                             sq_data_we;
  logic                 [             IdxWidth-1:0] sq_data_wr_idx;

  always_comb begin
    sq_data_we     = 1'b0;
    sq_data_wr_idx = '0;
    // Reset and a full flush clear entry validity on this edge, so a
    // coincident payload write remains hidden.
    // A Zicbom entry is never data-valid and frees only when it drains, so
    // after commit it can still hold a ROB tag that a younger store reuses.
    // It takes no payload, as in the control CAM below.
    if (i_data_update_capture_valid) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (sq_valid[i] && !sq_data_valid[i] && !sq_is_cmo[i] &&
            sq_rob_tag[i] == i_data_update.rob_tag) begin
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

`ifdef FROST_RANDOM_START
  initial begin
    for (int row = 0; row < DEPTH; row++)
    for (int chunk = 0; chunk < (FLEN + 31) / 32; chunk++)
    sq_data_fwd_entry[row] = (sq_data_fwd_entry[row] << 32) | FLEN'($urandom);
  end
`else
  initial for (int i = 0; i < DEPTH; i++) sq_data_fwd_entry[i] = '0;
`endif

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
  // Limit fanout to dispatch and front-end stall logic.
  (* max_fanout = 32 *)logic                  dispatch_full_q;
  (* max_fanout = 32 *)logic                  dispatch_full_for_2_q;
  // Update live count on the same edge and events as sq_valid. Register it
  // for timing because LQ issue consumes empty.
  (* keep = "true" *)logic [CountWidth-1:0] live_count_q;
  logic [CountWidth-1:0] live_count_next;
  logic [CountWidth-1:0] live_remove_count;
  // Kept so the removal counts read each entry's mask gate directly (see the
  // staged mask below).
  (* keep = "true" *)logic [     DEPTH-1:0] live_remove_mask;
  logic [     DEPTH-1:0] sc_discard_remove_mask;
  logic                  drain_remove_valid;
  logic                  committed_empty_q;
  // Precompute counts for no request, one request, and a pair, then select
  // with dispatch valids for timing. Either lone slot uses alloc_room_1;
  // a pair also uses alloc_room_2.
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
  // Precompute room-qualified targets for timing. Slot 1 takes the first;
  // slot 2 takes the first when alone and the second in a pair.
  logic [     DEPTH-1:0] first_target_oh;
  logic [     DEPTH-1:0] second_target_oh;
  (* keep = "true", max_fanout = 16 *)logic [     DEPTH-1:0] first_room_oh;
  (* keep = "true", max_fanout = 16 *)logic [     DEPTH-1:0] second_room_oh;
  (* keep = "true", max_fanout = 16 *)logic [     DEPTH-1:0] slot1_alloc_oh;
  (* keep = "true", max_fanout = 16 *)logic [     DEPTH-1:0] slot2_alloc_oh;
  (* keep = "true", max_fanout = 16 *)logic [     DEPTH-1:0] alloc_oh;

  // Track up to two ordinary Normal writes, or two cached plain writes, in
  // completion order. The legacy port and the L1D complete one cycle later;
  // AXI holds each owner until its B response. Cached SC, cached cbo.zero and
  // MMIO writes allow only one outstanding write, and the two writes in flight
  // always share one completion source (write_inflight_cached).
  logic [           1:0] write_inflight_cnt;
  logic                  write_inflight_special;
  logic                  write_inflight_cached;
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

  // Head skip-advance and tail allocation targets.
  logic [PtrWidth-1:0] head_advance_target;
  logic [PtrWidth-1:0] alloc_target;
  logic                flush_all_uncommitted;

  // ===========================================================================
  // Count, Full, Empty
  // ===========================================================================
  // Capacity uses tail minus head. With tail-only allocation, holes remain
  // unavailable until head advancement or flush pullback reclaims them. Live
  // count is separate so empty need not wait for pointer reclamation.
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

  // When both slots allocate, slot 1 takes tail and slot 2 takes tail+1.
  // Either slot alone takes tail.
  //
  // Reject allocation on either flush, matching the ROB. Dispatch may still
  // present requests before the front-end kill arrives. Accepting one would
  // create an SQ entry for a ROB tag that was never allocated.
  logic alloc_flush_ok;
  assign alloc_flush_ok = !i_flush_all && !i_flush_en;
  // The trusted variant relies on dispatch for room. full implies full_for_2,
  // so a refused slot-1 request also leaves no room for slot 2.
  logic alloc_room_1;
  logic alloc_room_2;
  assign alloc_room_1   = alloc_flush_ok && (TRUST_DISPATCH_VALID || !full);
  assign alloc_room_2   = alloc_flush_ok && (TRUST_DISPATCH_VALID || !full_for_2);
  assign slot1_alloc_en = i_alloc.valid && alloc_room_1;
  assign slot2_alloc_en = i_alloc_2.valid && (i_alloc.valid ? alloc_room_2 : alloc_room_1);

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (!i_rst_n) reset_seen_q <= 1'b1;

  // Check trusted allocation against the room-qualified form to prevent live
  // slot overwrites. Sample at the edge, where all allocation consumers act.
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && TRUST_DISPATCH_VALID && i_rst_n && !$isunknown(
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
    if (reset_seen_q && TRUST_DISPATCH_VALID && i_rst_n && !$isunknown(
            {full, full_for_2, dispatch_full_q, dispatch_full_for_2_q}
        )) begin
      p_trusted_sq_status_conservative : assert (!full || dispatch_full_q);
      p_trusted_sq_status_for_2_conservative : assert (!full_for_2 || dispatch_full_for_2_q);
    end
  end
`endif
  assign slot2_alloc_idx = slot1_alloc_en ? alloc_target_2[IdxWidth-1:0]
                                          : alloc_target[IdxWidth-1:0];


  // Count allocations immediately and reclaim only from the updated ring
  // window on the next cycle. A done pulse alone cannot free capacity: head
  // advances after it. Early credit could accept a store into an occupied slot.
  // Precompute each outcome's full flags before selecting with dispatch valids.
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

  // Combine registered work before the live ROB commit strobes for timing.
  (* keep = "true" *)logic no_registered_committed_work;
  logic committed_empty_next;
  assign no_registered_committed_work = !any_committed && !i_commit_valid && !i_commit_valid_2;
  assign committed_empty_next = i_flush_all ||
      (no_registered_committed_work && !i_commit_valid_comb && !i_commit_valid_comb_2);
  // Identical copies of committed_empty_q for fanout. Preserve separate flops.
  (* dont_touch = "true" *)logic committed_empty_rob_q;
  (* dont_touch = "true" *)logic committed_empty_trap_q;
  (* dont_touch = "true" *)logic committed_empty_lq_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      committed_empty_q      <= 1'b1;
      committed_empty_rob_q  <= 1'b1;
      committed_empty_trap_q <= 1'b1;
      committed_empty_lq_q   <= 1'b1;
    end else begin
      committed_empty_q      <= committed_empty_next;
      committed_empty_rob_q  <= committed_empty_next;
      committed_empty_trap_q <= committed_empty_next;
      committed_empty_lq_q   <= committed_empty_next;
    end
  end

`ifdef SQ_COMMITTED_EMPTY_LOCAL_PROOF
  always_comb begin
    assert (committed_empty_next == (i_flush_all ? 1'b1 :
        (!any_committed && !i_commit_valid && !i_commit_valid_2 &&
         !i_commit_valid_comb && !i_commit_valid_comb_2)));
  end
`endif

`ifndef SYNTHESIS
  // Every copy takes the same reset and next state, so they agree from the
  // first edge.
  logic committed_empty_copies_armed_q = 1'b0;
  always_ff @(posedge i_clk) begin
    committed_empty_copies_armed_q <= 1'b1;
    if (committed_empty_copies_armed_q) begin
      p_committed_empty_copies_match :
      assert ({committed_empty_rob_q, committed_empty_trap_q, committed_empty_lq_q} ==
              {3{committed_empty_q}});
    end
  end
`endif

  if (1'b1) begin : gen_coherent_drain
    logic drain_pending;
    assign drain_pending = i_coherent_store_pending || i_coherent_sc_pending ||
        (o_mem_write_en && o_mem_write_is_cached);
    assign o_committed_empty = committed_empty_q && !drain_pending;
    assign o_committed_empty_rob = committed_empty_rob_q && !drain_pending;
    assign o_committed_empty_trap = committed_empty_trap_q && !drain_pending;
    assign o_committed_empty_lq = committed_empty_lq_q && !drain_pending;
`ifdef SQ_COMMITTED_EMPTY_LOCAL_PROOF
    always_comb begin
      assert (o_committed_empty == (committed_empty_q && !i_coherent_store_pending &&
          !i_coherent_sc_pending && !(o_mem_write_en && o_mem_write_is_cached)));
      assert (o_committed_empty_rob == (committed_empty_rob_q && !drain_pending));
      assert (o_committed_empty_trap == (committed_empty_trap_q && !drain_pending));
      assert (o_committed_empty_lq == (committed_empty_lq_q && !drain_pending));
    end
`endif
  end

  logic [DEPTH*ReorderBufferTagWidth-1:0] sq_rob_tag_flat;
  logic [DEPTH*XLEN-1:0] sq_address_flat;
  logic [DEPTH*MemSizeWidth-1:0] sq_size_flat;

  for (genvar g_sq_flat = 0; g_sq_flat < DEPTH; g_sq_flat++) begin : gen_sq_flat
    assign sq_rob_tag_flat[g_sq_flat*ReorderBufferTagWidth +: ReorderBufferTagWidth] =
        sq_rob_tag[g_sq_flat];
    // One alias-decode bit per entry precedes the forwarding comparator and
    // vector range check without an added cycle. The drain uses the bus address.
    wire [XLEN-1:0] raw_addr = sq_address[g_sq_flat];
    assign sq_address_flat[g_sq_flat*XLEN+:XLEN] =
        sq_is_cmo[g_sq_flat] && riscv_pkg::pma_pbmt_alias_ok(raw_addr) ?
        riscv_pkg::pbmt_alias_real(raw_addr) : raw_addr;
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
      // Forwarding uses unmasked scan pulses; see i_commit_valid_scan.
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
      // A Zicbom entry takes the zero entry's block conflict and never
      // forwards, and no newer store forwards past it, so a younger load of
      // its block waits for it to free (cmo.adoc, norm:ppo_overlap_2).
      .sq_is_zero                (sq_is_zero | sq_is_cmo),
      .sq_is_cmo                 (sq_is_cmo),
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
  // head_ptr reclaims capacity only after write completion. A separate drain
  // cursor selects the oldest valid, unsent entry and cannot skip an unready
  // one. Exclude a write launching this cycle when choosing the next cursor,
  // so consecutive stores can launch on consecutive cycles. Register the
  // cursor to address the drain data and flags.
  logic [DEPTH-1:0] drain_mask_base;
  logic [DEPTH-1:0] drain_mask_post_fire;

  logic             mem_write_fire_next;
  logic             mem_write_completes_next;
  logic             mem_write_plain_fast_next;
  logic             drain_complete_fire_next;
  (* keep = "true" *)logic             write_inflight_special_hold;
  logic             write_inflight_special_next;
  (* keep = "true" *)logic [DEPTH-1:0] sq_sent_hold;
  logic [DEPTH-1:0] sq_sent_next;
`ifdef FROST_XILINX_PRIMS
  (* keep = "true" *) logic [DEPTH-1:0] sq_sent_launch_local;
`endif

  // Compute the next cursor both with and without a launch, then select with
  // drain_complete_fire_next for timing. The post-fire mask excludes only
  // drain_idx_q; the reference below checks the combined expression.
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
  // A committed, address-ready, data-ready cursor entry writes one beat.
  // Register the bus interface for timing. The two-entry completion FIFO
  // permits overlapping ordinary Normal writes; the AXI profile holds each
  // entry through B. Cached and MMIO writes wait for an empty pipeline
  // (write_inflight_cnt == 0 && !o_mem_write_en).

  logic uncached_pending_q, uncached_armed_q;
  logic                             uncached_sc_permit_q;
  logic [ReorderBufferTagWidth-1:0] uncached_sc_tag_q;
  logic                             mem_write_precommit_fire_next;
  logic                             mem_write_addr_cached_for_plain_next;
  // Classify stored addresses in parallel with cursor selection. For an
  // aligned power-of-two region, only the address bits outside its mask
  // participate; other maps keep the general half-open range comparison.
  localparam logic [XLEN-1:0] CachedBase = XLEN'(CACHED_BASE);
  localparam logic [XLEN-1:0] CachedSize = XLEN'(CACHED_SIZE_BYTES);
  localparam logic [XLEN-1:0] CachedLimit = CachedBase + CachedSize;
  localparam logic [XLEN-1:0] CachedMask = CachedSize - 1'b1;
  localparam bit CachedRegionAligned = CachedSize != 0 &&
      (CachedSize & CachedMask) == 0 && (CachedBase & CachedMask) == 0 &&
      CachedLimit > CachedBase;
  function automatic logic address_is_cached(input logic [XLEN-1:0] addr);
    if (CachedRegionAligned) address_is_cached = (addr & ~CachedMask) == CachedBase;
    else address_is_cached = (addr >= CachedBase) && (addr < CachedLimit);
  endfunction
  (* keep = "true" *)logic [DEPTH-1:0] sq_cached_class;
  // A cached write other than SC and cbo.zero: one L1D write whose done
  // follows on the next cycle, so it may overlap others of its class.
  (* keep = "true" *)logic [DEPTH-1:0] sq_cached_plain_class;
  (* keep = "true" *) logic [DEPTH-1:0] sq_precise_class, sq_plain_fast_class;
  logic [DEPTH-1:0] drain_entry_ready, drain_sc_order_ok;
  // Range-ordering holds against the vector memory table, registered. An SC
  // waits for every older live vector memory instruction.
  logic [DEPTH-1:0] vec_hold_d, vec_hold_q;
  vec_hold_rows #(
      .DEPTH(DEPTH),
      .DIRECT_ADDR(1'b1),
      .BLOCK_LSB($clog2(riscv_pkg::CboZeroBlockBytes))
  ) u_vec_hold (
      .i_clk       (i_clk),
      .i_rst       (!i_rst_n),
      .i_valid     (sq_valid),
      .i_tag_flat  (sq_rob_tag_flat),
      .i_atomic    (sq_is_sc),
      .i_head_tag  (i_rob_head_tag),
      .i_upd_valid (1'b0),
      .i_upd_idx   ('0),
      .i_upd_addr  ('0),
      .i_upd_size  ('0),
      .i_addr_flat (sq_address_flat),
      .i_size_flat (sq_size_flat),
      .i_addr_valid(sq_addr_valid),
      .i_block_flat(sq_is_zero | sq_is_cmo),
      .i_vmt       (i_vmt),
      .o_hold_d    (vec_hold_d)
  );
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) vec_hold_q <= '0;
    else vec_hold_q <= vec_hold_d;
  end
  (* keep = "true" *) logic [DEPTH-1:0] pending_without_class, precommit_local_ready;
  (* keep = "true" *) logic precommit_shared_ready;
  assign precommit_shared_ready = uncached_armed_q && i_uncached_store_shield &&
      i_head_side_effects_allowed && !i_flush_en && !i_flush_all &&
      !o_uncached_store_complete.valid;
  for (genvar slot = 0; slot < DEPTH; slot++) begin : gen_cached_class
    // Resolve PMA, SC and MMIO qualification before selecting the cursor.
    wire normal_buffered = CACHE_NORMAL_MEMORY && riscv_pkg::pma_writethrough_ok(sq_address[slot]);
    assign sq_cached_class[slot] = address_is_cached(sq_address[slot]);
    assign sq_cached_plain_class[slot] = sq_cached_class[slot] && !sq_is_sc[slot] &&
        !sq_is_zero[slot];
    assign sq_precise_class[slot] = (!normal_buffered || sq_is_sc[slot]) && !sq_cached_class[slot];
    assign sq_plain_fast_class[slot] = (!PRECISE_UNCACHED ||
        (normal_buffered && !sq_is_sc[slot])) && !sq_is_mmio[slot] && !sq_cached_class[slot];
    assign drain_entry_ready[slot] = drain_idx_q == IdxWidth'(slot) && sq_valid[slot] &&
        sq_addr_valid[slot] && sq_data_valid[slot] && !sq_sent[slot] && !vec_hold_q[slot];
    assign drain_sc_order_ok[slot] = !i_coherent_sc_pending ||
        (sq_is_sc[slot] && sq_rob_tag[slot] == i_coherent_sc_tag);
    assign pending_without_class[slot] = PRECISE_UNCACHED && drain_entry_ready[slot] &&
        !sq_committed[slot] && sq_rob_tag[slot] == i_rob_head_tag;
    assign precommit_local_ready[slot] = pending_without_class[slot] &&
        (!sq_is_sc[slot] ||
            (uncached_sc_permit_q && uncached_sc_tag_q == sq_rob_tag[slot]));
  end
  assign o_uncached_store_pending = |(pending_without_class & sq_precise_class);

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all || i_flush_en) begin
      uncached_pending_q <= 1'b0;
      uncached_armed_q   <= 1'b0;
    end else begin
      uncached_pending_q <= o_uncached_store_pending;
      uncached_armed_q <= o_uncached_store_pending && uncached_pending_q && i_uncached_store_shield;
    end
    if (!i_rst_n || i_flush_all) begin
      uncached_sc_permit_q <= 1'b0;
    end else begin
      if (i_uncached_sc_success && !(i_flush_en && flush_all_uncommitted)) begin
        uncached_sc_permit_q <= 1'b1;
        uncached_sc_tag_q <= i_uncached_sc_tag;
      end else if (mem_write_precommit_fire_next ||
          (i_flush_en && (flush_all_uncommitted ||
              is_younger(
              uncached_sc_tag_q, i_flush_tag, i_rob_head_tag
          )))) begin
        uncached_sc_permit_q <= 1'b0;
      end
    end
  end

  // The head cannot retire until this held completion reaches the ROB. The
  // in-order response FIFO identifies the exact store, including failed SC.
  // A precise zero block completes on its last beat's response and reports
  // an error from any of its beats.
  logic uncached_zero_error_q;
  logic uncached_done_precommit;
  logic uncached_done_error;
  assign uncached_done_precommit = PRECISE_UNCACHED && i_mem_write_done &&
      (write_inflight_cnt != 0) && !sq_committed[write_entry_idx];
  assign uncached_done_error = i_mem_write_error || uncached_zero_error_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      o_uncached_store_complete <= '0;
      uncached_zero_error_q <= 1'b0;
    end else begin
      if (i_uncached_store_result_ready) o_uncached_store_complete.valid <= 1'b0;
      if (uncached_done_precommit && !write_completes_entry) begin
        uncached_zero_error_q <= uncached_done_error;
      end
      if (uncached_done_precommit && write_completes_entry) begin
        uncached_zero_error_q <= 1'b0;
        o_uncached_store_complete <= '0;
        o_uncached_store_complete.valid <= 1'b1;
        o_uncached_store_complete.tag <= sq_rob_tag[write_entry_idx];
        o_uncached_store_complete.exception <= uncached_done_error;
        o_uncached_store_complete.exc_cause <= uncached_done_error ?
            riscv_pkg::exc_cause_t'(riscv_pkg::ExcStoreAccessFault) : '0;
      end
    end
  end

  logic coherent_selected_sc, coherent_credit_ok;
  (* keep = "true" *) logic launch_without_store_ready, complete_without_store_ready;
  (* keep = "true" *) logic mem_write_launch_qualified, mem_write_complete_qualified;
  assign coherent_selected_sc = i_coherent_sc_pending && sq_is_sc[drain_idx_q] &&
      sq_rob_tag[drain_idx_q] == i_coherent_sc_tag;
  assign coherent_credit_ok =
      !mem_write_addr_cached_for_plain_next || i_coherent_store_ready || coherent_selected_sc;

  logic                 [       riscv_pkg::XLEN-1:0] mem_write_addr_next;
  logic                 [riscv_pkg::MemDataBits-1:0] mem_write_data_next;
  logic                 [riscv_pkg::MemStrbBits-1:0] mem_write_byte_en_next;
  riscv_pkg::mem_size_e                              mem_write_size_next;
  logic                                              mem_write_is_mmio_next;
  logic                                              mem_write_is_cached_next;
  logic                                              mem_write_launch_serial_next;
  logic                                              mem_write_overlap_ready;
  logic mem_write_cached_overlap_ready, mem_write_uncached_overlap_ready;
  logic mem_write_cached_plain_next, mem_write_overlap_class_next;
  // A plain Normal or cached plain write may share the pipeline.
  assign mem_write_overlap_class_next = mem_write_plain_fast_next || mem_write_cached_plain_next;
  (* keep = "true" *) logic cached_launch_qualified, committed_uncached_launch;
  (* keep = "true" *) logic committed_uncached_complete;
  (* keep = "true" *) logic precise_launch_qualified, precise_complete_qualified;
  (* keep = "true" *) logic [DEPTH-1:0] cached_serial_local, uncached_serial_local;
  (* keep = "true" *) logic [DEPTH-1:0] uncached_overlap_local, precise_entry_local;
  (* keep = "true" *)logic [DEPTH-1:0] uncached_serial_complete_local;
  (* keep = "true" *)logic [DEPTH-1:0] uncached_overlap_complete_local;
  (* keep = "true" *)logic [DEPTH-1:0] precise_entry_complete_local;
  (* keep = "true" *) logic [DEPTH-1:0]
      committed_uncached_launch_terms, committed_uncached_complete_terms;
  logic [2:0] write_fifo_occupancy_after_current_bus;

  // Zero-block drain. A cached cbo.zero entry is one write at its block base,
  // which the L1D turns into the block's two sector records (see the cache
  // README, Line-scope cbo.zero); its done frees the entry. An uncached entry
  // writes eight zero beats: zero_beat_q counts its launched beats, each
  // writes eight zero bytes at the block base plus beat * 8, the entry stays
  // the cursor until its eighth beat launches, and only that beat's done
  // frees it. Each write takes a completion-FIFO slot, so done pulses stay in
  // launch order. Every zero write sets every strobe of its dword.
  localparam int unsigned ZeroBeatBits = $clog2(riscv_pkg::CboZeroBlockBytes / 8);
  localparam int unsigned ZeroBlockLsb = $clog2(riscv_pkg::CboZeroBlockBytes);
  // The write handshake arrives after the drain checks. Keep its hold and
  // restart decisions on the data input, with the increment prepared first.
  (* extract_reset = "no", extract_enable = "no" *) logic [ZeroBeatBits-1:0] zero_beat_q;
  logic drain_is_zero;
  logic drain_zero_cached;
  logic zero_beat_last;
  (* keep = "true" *) logic [ZeroBeatBits-1:0] zero_beat_advance, zero_beat_local_next;
  assign drain_is_zero = sq_is_zero[drain_idx_q];
  assign drain_zero_cached = drain_is_zero && mem_write_addr_cached_for_plain_next;
  assign zero_beat_last = &zero_beat_q;
  // The increment wraps after the last uncached beat. Cached zero writes
  // restart immediately; neither case needs the cursor-completion mux here.
  assign zero_beat_advance = drain_zero_cached ? '0 : zero_beat_q + ZeroBeatBits'(1);
  assign zero_beat_local_next = mem_write_launch_qualified && drain_is_zero ?
      zero_beat_advance : zero_beat_q;

  // Zicbom entries. A committed entry at the drain cursor starts once every
  // older write has completed (empty write pipeline) and the L1D holds no
  // pending store record, so every older store has installed in the L1D or
  // reached memory. With CMO_HOME, a block in cached DDR goes to the hart's
  // Zicbom requester first, and the entry fires only on its done: the home has
  // recalled every L1D copy, written a dirty line to memory and received B
  // (clean, flush) or dropped it (inval). A CMO through an NC or IO mapping
  // names the uncached alias of DDR; it acts on the real block (the CMO ignores
  // PBMT). Every other block (BRAM, device windows, and every block without
  // CMO_HOME) fires one cycle after it starts, as an ordered no-op (DESIGN D1,
  // D4). Younger stores wait behind the cursor and younger loads of the block
  // wait for the entry (the forwarding conflict above); FENCE and device
  // accesses wait for it like any committed store. Flush and inval pulse the
  // block-wide L0 invalidation (BRAM has no coherent invalidation of its own).
  // A Zicbom entry has no data and never sets sq_data_valid, so drain_ready,
  // the write launch and the precise uncached path never select it.
  // The entry is sent and the drain cursor passes it on the cycle it
  // fires; it frees on the next cycle from registered state (cmo_free_q), as
  // a completed write frees from the write FIFO head. A second Zicbom entry
  // fires only after the first has freed.
  logic drain_is_cmo;
  logic cmo_drain_fire;
  logic cmo_inval_pulse_q;
  logic cmo_free_q;
  logic [IdxWidth-1:0] cmo_free_idx_q;
  logic cmo_start_ready;
  logic [XLEN-1:0] cmo_target;
  logic cmo_target_home;
  typedef enum logic [1:0] {
    CmoIdle,
    CmoRequest,
    CmoWait,
    CmoRelease
  } cmo_state_e;
  cmo_state_e cmo_state_q;
  riscv_pkg::cmo_kind_e cmo_kind_q;
  logic [XLEN-1:0] cmo_addr_q;
  assign drain_is_cmo = sq_is_cmo[drain_idx_q];
  assign cmo_start_ready = drain_is_cmo && sq_valid[drain_idx_q] && sq_committed[drain_idx_q] &&
      sq_addr_valid[drain_idx_q] && !sq_sent[drain_idx_q] && !vec_hold_q[drain_idx_q] &&
      (write_inflight_cnt == 2'd0) && !o_mem_write_en &&
      !i_coherent_store_pending && !i_coherent_sc_pending && !cmo_free_q;
  always_comb begin
    cmo_target = sq_address[drain_idx_q];
    if (riscv_pkg::pma_pbmt_alias_ok(cmo_target))
      cmo_target = riscv_pkg::pbmt_alias_real(cmo_target);
    cmo_target[5:0] = '0;
  end
  assign cmo_target_home = CMO_HOME && riscv_pkg::pma_cached_ok(cmo_target);
  assign cmo_drain_fire = cmo_start_ready && cmo_state_q == CmoRelease;
  assign o_cmo_valid = cmo_state_q == CmoRequest;
  assign o_cmo_kind = cmo_kind_q;
  assign o_cmo_addr = cmo_addr_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      cmo_state_q <= CmoIdle;
      cmo_kind_q  <= riscv_pkg::CMO_INVAL;
      cmo_addr_q  <= '0;
    end else begin
      unique case (cmo_state_q)
        CmoIdle:
        if (cmo_start_ready && !i_flush_all) begin
          cmo_kind_q  <= sq_cmo_kind[drain_idx_q];
          cmo_addr_q  <= cmo_target;
          cmo_state_q <= cmo_target_home ? CmoRequest : CmoRelease;
        end
        CmoRequest: if (i_cmo_ready) cmo_state_q <= CmoWait;
        CmoWait: if (i_cmo_done) cmo_state_q <= CmoRelease;
        default: cmo_state_q <= CmoIdle;
      endcase
    end
  end
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      cmo_inval_pulse_q <= 1'b0;
      cmo_free_q <= 1'b0;
    end else begin
      cmo_inval_pulse_q <= cmo_drain_fire && (sq_cmo_kind[drain_idx_q] != riscv_pkg::CMO_CLEAN);
      cmo_free_q <= cmo_drain_fire;
    end
    if (cmo_drain_fire) cmo_free_idx_q <= drain_idx_q;
  end

  always_comb begin
    // Single-beat drains at every size (hw/rtl/README.md, "Data-tier bus contract"): doubles
    // are one 64-bit write. A zero entry's beat is a full double at its block offset.
    mem_write_addr_next = drain_is_zero ?
        {sq_address[drain_idx_q][XLEN-1:ZeroBlockLsb],
         drain_zero_cached ? ZeroBeatBits'(0) : zero_beat_q, 3'b000} :
        sq_address[drain_idx_q];
    mem_write_size_next = drain_is_zero ? riscv_pkg::MEM_SIZE_DOUBLE :
        riscv_pkg::mem_size_e'(sq_size[drain_idx_q]);

    mem_write_data_next = drain_is_zero ? '0 :
        gen_write_data(sq_data_drain_rd, riscv_pkg::mem_size_e'(sq_size[drain_idx_q]));
    mem_write_byte_en_next = drain_is_zero ? '1 :
        gen_byte_en(mem_write_addr_next[2:0], riscv_pkg::mem_size_e'(sq_size[drain_idx_q]));
    mem_write_is_mmio_next = sq_is_mmio[drain_idx_q];
    mem_write_is_cached_next = address_is_cached(mem_write_addr_next);
  end

  assign mem_write_addr_cached_for_plain_next = sq_cached_class[drain_idx_q];
  // Every store is one beat and completes its entry, including DOUBLE. A
  // cached zero entry is one write; an uncached one completes on its eighth
  // beat.
  assign mem_write_completes_next = !drain_is_zero || drain_zero_cached || zero_beat_last;
  assign mem_write_plain_fast_next = sq_plain_fast_class[drain_idx_q];
  assign mem_write_cached_plain_next = sq_cached_plain_class[drain_idx_q];

  // Serial launches require an empty pipeline. Plain BRAM launches may overlap
  // if the two-entry FIFO has room after the current bus push and done pop.
  // Credit a simultaneous done for sustained writes; delayed done throttles
  // launches before the FIFO overflows.
  assign write_fifo_occupancy_after_current_bus =
      {1'b0, write_inflight_cnt} + {2'b0, o_mem_write_en} -
      {2'b0, (i_mem_write_done && (write_inflight_cnt != 2'd0))};
  assign mem_write_launch_serial_next = (write_inflight_cnt == 2'd0) && !o_mem_write_en;
  assign mem_write_overlap_ready = !write_inflight_special &&
      (write_fifo_occupancy_after_current_bus < 3'd2);
  // An overlapping write shares the completion source of the writes in
  // flight: a cached plain write follows only cached plain writes, whose L1D
  // dones arrive in launch order, and an uncached one only uncached ones.
  assign mem_write_cached_overlap_ready = mem_write_overlap_ready && write_inflight_cached;
  assign mem_write_uncached_overlap_ready = mem_write_overlap_ready &&
      (mem_write_launch_serial_next || !write_inflight_cached);
  // Prepare every non-address condition per entry. Cached writes complete in
  // one beat; a cached plain write may also overlap cached plain writes in
  // flight, and a cached SC or cbo.zero uses the serial arm. Precise uncommitted writes are
  // uncached and cannot use the Normal-memory overlap arm. Their class bits
  // select these decisions after local qualification. The shared permission
  // for precise writes applies after their per-entry reduction.
  for (genvar slot = 0; slot < DEPTH; slot++) begin : gen_drain_class_cofactors
    wire committed_ready = drain_entry_ready[slot] && sq_committed[slot] && drain_sc_order_ok[slot];
    wire uncached_last = !sq_is_zero[slot] || zero_beat_last;
    assign cached_serial_local[slot] = committed_ready && (mem_write_launch_serial_next ||
        (sq_cached_plain_class[slot] && mem_write_cached_overlap_ready)) &&
        (!i_coherent_store_pending || !sq_is_sc[slot]);
    assign uncached_serial_local[slot] = committed_ready && mem_write_launch_serial_next &&
        !i_coherent_store_pending;
    assign uncached_overlap_local[slot] = committed_ready && mem_write_uncached_overlap_ready &&
        !i_coherent_store_pending;
    assign precise_entry_local[slot] = precommit_local_ready[slot] &&
        drain_sc_order_ok[slot] && mem_write_launch_serial_next && !i_coherent_store_pending;
    assign uncached_serial_complete_local[slot] = uncached_serial_local[slot] && uncached_last;
    assign uncached_overlap_complete_local[slot] = uncached_overlap_local[slot] && uncached_last;
    assign precise_entry_complete_local[slot] = precise_entry_local[slot] && uncached_last;
    assign committed_uncached_launch_terms[slot] =
        (uncached_serial_local[slot] && !sq_cached_class[slot]) ||
        (uncached_overlap_local[slot] && sq_plain_fast_class[slot]);
    assign committed_uncached_complete_terms[slot] =
        (uncached_serial_complete_local[slot] && !sq_cached_class[slot]) ||
        (uncached_overlap_complete_local[slot] && sq_plain_fast_class[slot]);
  end
  assign cached_launch_qualified = |(cached_serial_local & sq_cached_class);
  assign committed_uncached_launch = |committed_uncached_launch_terms;
  assign committed_uncached_complete = |committed_uncached_complete_terms;
  assign precise_launch_qualified = |(precise_entry_local & sq_precise_class);
  assign precise_complete_qualified = |(precise_entry_complete_local & sq_precise_class);
  assign mem_write_precommit_fire_next = precommit_shared_ready && precise_launch_qualified;
  assign mem_write_launch_qualified = cached_launch_qualified || committed_uncached_launch ||
      mem_write_precommit_fire_next;
  assign mem_write_complete_qualified = cached_launch_qualified || committed_uncached_complete ||
      (precommit_shared_ready && precise_complete_qualified);
  // Coherent credit arrives after local qualification and applies only to
  // the cached arm. The other arms do not depend on that handshake.
  // Head permission likewise qualifies only the precise arm, after its
  // cursor, SC, pipeline and address checks have all been reduced.
  assign launch_without_store_ready = committed_uncached_launch ||
      (cached_launch_qualified && (!mem_write_addr_cached_for_plain_next || coherent_selected_sc));
  // A Zicbom entry completes at the drain cursor without a write
  // (cmo_drain_fire) and frees on the next cycle (cmo_free_q).
  assign complete_without_store_ready = committed_uncached_complete || cmo_drain_fire ||
      (cached_launch_qualified && (!mem_write_addr_cached_for_plain_next || coherent_selected_sc));
`ifdef FROST_XILINX_PRIMS
  // The two shared permissions enter the final five-input selection directly.
  (* dont_touch = "true" *)
  LUT5 #(
      .INIT(32'hfefaeeaa)
  ) u_write_launch_select (
      .I0(launch_without_store_ready),
      .I1(precise_launch_qualified),
      .I2(cached_launch_qualified),
      .I3(precommit_shared_ready),
      .I4(i_coherent_store_ready),
      .O (mem_write_fire_next)
  );
  (* dont_touch = "true" *) LUT5 #(
      .INIT(32'hfefaeeaa)
  ) u_write_complete_select (
      .I0(complete_without_store_ready),
      .I1(precise_complete_qualified),
      .I2(cached_launch_qualified),
      .I3(precommit_shared_ready),
      .I4(i_coherent_store_ready),
      .O (drain_complete_fire_next)
  );
`else
  assign mem_write_fire_next = launch_without_store_ready ||
      (precommit_shared_ready && precise_launch_qualified) ||
      (cached_launch_qualified && i_coherent_store_ready);
  assign drain_complete_fire_next = complete_without_store_ready ||
      (precommit_shared_ready && precise_complete_qualified) ||
      (cached_launch_qualified && i_coherent_store_ready);
`endif

  // Resolve completion of the previous write independently of launch credit.
  // A new launch wins over a simultaneous completion and supplies its class.
  always_comb begin
    write_inflight_special_hold = write_inflight_special;
    if (i_mem_write_done && (write_inflight_cnt == 2'd1) && !o_mem_write_en)
      write_inflight_special_hold = 1'b0;
  end
`ifdef FROST_XILINX_PRIMS
  (* dont_touch = "true" *) LUT3 #(
      .INIT(8'h3a)
  ) u_write_inflight_special_select (
      .I0(write_inflight_special_hold),
      .I1(mem_write_overlap_class_next),
      .I2(mem_write_fire_next),
      .O (write_inflight_special_next)
  );
`else
  always_comb begin
    write_inflight_special_next = write_inflight_special_hold;
    if (mem_write_fire_next) write_inflight_special_next = !mem_write_overlap_class_next;
  end
`endif

  // Allocation clears the previous owner's sent bit. A completing launch
  // takes priority, with its cursor and completion checks prepared first.
  always_comb begin
    sq_sent_hold = sq_sent;
    for (int slot = 0; slot < DEPTH; slot++) if (alloc_oh[slot]) sq_sent_hold[slot] = 1'b0;
  end
`ifdef FROST_XILINX_PRIMS
  for (genvar slot = 0; slot < DEPTH; slot++) begin : gen_sent_select
    assign sq_sent_launch_local[slot] = mem_write_completes_next && drain_idx_q == IdxWidth'(slot);
    (* dont_touch = "true" *) LUT3 #(
        .INIT(8'hea)
    ) u_select (
        .I0(sq_sent_hold[slot]),
        .I1(sq_sent_launch_local[slot]),
        .I2(mem_write_fire_next),
        .O (sq_sent_next[slot])
    );
  end
`else
  always_comb begin
    sq_sent_next = sq_sent_hold;
    if (mem_write_fire_next) if (mem_write_completes_next) sq_sent_next[drain_idx_q] = 1'b1;
  end
`endif

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

    o_mem_write_addr <= mem_write_addr_next;
    o_mem_write_data <= mem_write_data_next;
    o_mem_write_byte_en <= mem_write_byte_en_next;
    o_mem_write_size <= mem_write_size_next;
    o_mem_write_is_mmio <= mem_write_is_mmio_next;
    o_mem_write_buffered <= PRECISE_UNCACHED && CACHE_NORMAL_MEMORY &&
        !sq_is_sc[drain_idx_q] && !mem_write_is_mmio_next &&
        riscv_pkg::pma_writethrough_ok(
        mem_write_addr_next
    );
    o_mem_write_is_cached <= mem_write_is_cached_next;
    o_cache_invalidate_block <= drain_zero_cached || drain_is_cmo;

    if (mem_write_fire_next) begin
      mem_write_entry_idx_stg <= drain_idx_q;
      mem_write_completes_stg <= mem_write_completes_next;
    end
  end

  logic [DEPTH-1:0] flush_kill_base;
  // The beat count restarts after the last beat, a full flush, or a partial
  // flush that removes the cursor entry (a precise entry is uncommitted while
  // it drains); a committed entry survives every partial flush.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all || (i_flush_en && flush_kill_base[drain_idx_q])) begin
      zero_beat_q <= '0;
    end else begin
      zero_beat_q <= coherent_credit_ok ? zero_beat_local_next : zero_beat_q;
    end
  end

  // The last write's sector and class after this cycle's launch, and the
  // same-sector claim: the cursor entry after this cycle's launch is a
  // committed cached plain store to that sector and is unsent after this
  // cycle's allocation, which clears a reused entry's sent mark. Only a
  // cached plain launch leaves a claim, and that launch completes its entry,
  // so the cursor takes the post-fire choice. Without a launch the cursor
  // takes the post-fire choice past a Zicbom entry (cmo_drain_fire) and the
  // base choice otherwise; the base choice is the cursor entry itself or the
  // same entry as the post-fire choice. Each entry's claim is formed from
  // registered state and the room-qualified allocation targets; the cursor
  // choices then select one entry for each launch outcome, the allocation's
  // dispatch valids apply next, and the launch selects last.
  logic [XLEN-6:0] last_write_sector_q;
  logic last_write_plain_q, next_same_d;
  wire [XLEN-6:0] last_write_sector_d = mem_write_fire_next ?
      sq_address[drain_idx_q][XLEN-1:5] : last_write_sector_q;
  wire last_write_plain_d = mem_write_fire_next ?
      sq_cached_plain_class[drain_idx_q] && !drain_is_cmo : last_write_plain_q;
  // Per entry: a valid committed cached plain store with its address, not a
  // Zicbom entry (class); the next write after a cached plain launch from the
  // cursor, in the launching entry's sector (fire); the next write without a
  // launch, in the last write's sector (hold). Each claim is split by the
  // entry's sent mark: unsent, or sent and taken by this cycle's first
  // allocation (sent1) or by a pair's second allocation (sent2).
  logic [DEPTH-1:0] next_same_class, next_same_fire_entry, next_same_hold_entry;
  (* keep = "true" *) logic [DEPTH-1:0] next_same_fire_unsent_e, next_same_fire_sent1_e;
  (* keep = "true" *) logic [DEPTH-1:0] next_same_fire_sent2_e, next_same_hold_unsent_e;
  (* keep = "true" *) logic [DEPTH-1:0] next_same_hold_sent1_e, next_same_hold_sent2_e;
  logic next_same_hold_cursor;
  // The cursor choices then select one bit of each.
  (* keep = "true" *) logic next_same_fire_unsent, next_same_fire_sent1, next_same_fire_sent2;
  (* keep = "true" *) logic next_same_hold_unsent, next_same_hold_sent1, next_same_hold_sent2;
  (* keep = "true" *) logic next_same_if_fire, next_same_if_hold;
  logic next_same_launch;
  always_comb
    for (int i = 0; i < DEPTH; i++) begin
      next_same_class[i] = sq_valid[i] && sq_committed[i] && sq_addr_valid[i] &&
          sq_cached_plain_class[i] && !sq_is_cmo[i];
      next_same_fire_entry[i] = sq_cached_plain_class[drain_idx_q] && !drain_is_cmo &&
          drain_idx_q != IdxWidth'(i) && next_same_class[i] &&
          sq_address[i][XLEN-1:5] == sq_address[drain_idx_q][XLEN-1:5];
      next_same_hold_entry[i] = last_write_plain_q && next_same_class[i] &&
          sq_address[i][XLEN-1:5] == last_write_sector_q;
      next_same_fire_unsent_e[i] = next_same_fire_entry[i] && !sq_sent[i];
      next_same_fire_sent1_e[i] = next_same_fire_entry[i] && sq_sent[i] && first_room_oh[i];
      next_same_fire_sent2_e[i] = next_same_fire_entry[i] && sq_sent[i] && second_room_oh[i];
      next_same_hold_unsent_e[i] = next_same_hold_entry[i] && !sq_sent[i];
      next_same_hold_sent1_e[i] = next_same_hold_entry[i] && sq_sent[i] && first_room_oh[i];
      next_same_hold_sent2_e[i] = next_same_hold_entry[i] && sq_sent[i] && second_room_oh[i];
    end
  // A launch: the post-fire entry. No launch: the cursor entry, or the
  // post-fire entry.
  assign next_same_hold_cursor = drain_base_idx_d == drain_idx_q && !cmo_drain_fire;
  assign next_same_fire_unsent = next_same_fire_unsent_e[drain_post_fire_idx_d];
  assign next_same_fire_sent1 = next_same_fire_sent1_e[drain_post_fire_idx_d];
  assign next_same_fire_sent2 = next_same_fire_sent2_e[drain_post_fire_idx_d];
  assign next_same_hold_unsent = next_same_hold_cursor ? next_same_hold_unsent_e[drain_idx_q] :
      next_same_hold_unsent_e[drain_post_fire_idx_d];
  assign next_same_hold_sent1 = next_same_hold_cursor ? next_same_hold_sent1_e[drain_idx_q] :
      next_same_hold_sent1_e[drain_post_fire_idx_d];
  assign next_same_hold_sent2 = next_same_hold_cursor ? next_same_hold_sent2_e[drain_idx_q] :
      next_same_hold_sent2_e[drain_post_fire_idx_d];
  assign next_same_if_fire = next_same_fire_unsent ||
      (next_same_fire_sent1 && (i_alloc.valid || i_alloc_2.valid)) ||
      (next_same_fire_sent2 && i_alloc.valid && i_alloc_2.valid);
  assign next_same_if_hold = next_same_hold_unsent ||
      (next_same_hold_sent1 && (i_alloc.valid || i_alloc_2.valid)) ||
      (next_same_hold_sent2 && i_alloc.valid && i_alloc_2.valid);
`ifdef FROST_XILINX_PRIMS
  // A copy of the launch selection drives only the claim's final selection,
  // apart from the launch's wide fanout.
  (* dont_touch = "true" *) LUT5 #(
      .INIT(32'hfefaeeaa)
  ) u_next_same_launch_select (
      .I0(launch_without_store_ready),
      .I1(precise_launch_qualified),
      .I2(cached_launch_qualified),
      .I3(precommit_shared_ready),
      .I4(i_coherent_store_ready),
      .O (next_same_launch)
  );
  (* dont_touch = "true" *) LUT3 #(
      .INIT(8'hca)
  ) u_next_same_select (
      .I0(next_same_if_hold),
      .I1(next_same_if_fire),
      .I2(next_same_launch),
      .O (next_same_d)
  );
`else
  assign next_same_launch = mem_write_fire_next;
  assign next_same_d = next_same_launch ? next_same_if_fire : next_same_if_hold;
`endif
`ifndef SYNTHESIS
`define SQ_NEXT_SAME_REFERENCE
`elsif SQ_NEXT_SAME_LOCAL_PROOF
`define SQ_NEXT_SAME_REFERENCE
`endif
`ifdef SQ_NEXT_SAME_REFERENCE
  // Reference: the cursor entry, sent marks and last write after this
  // cycle's launch and allocation, as one expression.
  logic next_same_reference;
  assign next_same_reference = last_write_plain_d && sq_valid[drain_idx_d] &&
      !sq_sent_next[drain_idx_d] && sq_committed[drain_idx_d] && sq_addr_valid[drain_idx_d] &&
      sq_cached_plain_class[drain_idx_d] && !sq_is_cmo[drain_idx_d] &&
      sq_address[drain_idx_d][XLEN-1:5] == last_write_sector_d;
`undef SQ_NEXT_SAME_REFERENCE
`endif
`ifdef SQ_NEXT_SAME_LOCAL_PROOF
  always_comb assert (next_same_d == next_same_reference);
`endif
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      last_write_plain_q   <= 1'b0;
      o_coherent_next_same <= 1'b0;
    end else begin
      last_write_plain_q   <= last_write_plain_d;
      o_coherent_next_same <= next_same_d;
    end
    last_write_sector_q <= last_write_sector_d;
  end
  if (1'b1) begin : gen_coherent_write_metadata
    always_ff @(posedge i_clk) begin
      o_coherent_write_sc   <= sq_is_sc[drain_idx_q];
      o_coherent_write_zero <= drain_zero_cached;
      o_coherent_write_more <= |(drain_mask_post_fire & ~sq_is_sc & ~sq_is_zero & ~sq_is_cmo);
      o_coherent_write_tag  <= sq_rob_tag[drain_idx_q];
    end
  end

  // ===========================================================================
  // L0 Cache Invalidation (at memory write launch)
  // ===========================================================================
  // Invalidate in the write bus cycle to prevent stale L0 hits while the write
  // is pending. The router orders reads behind it, including cached writes.
  // At worst, early invalidation costs a refill miss. One pulse covers every
  // size because stores do not cross dwords; MMIO invalidation is harmless.
  // A cached zero write's pulse covers its whole block (o_cache_invalidate_block).
  // A cbo.flush or cbo.inval pulses the same block invalidation, without a
  // write, on the cycle after it fires, as it frees (o_mem_write_en is low then).
  assign o_cache_invalidate_valid = o_mem_write_en || cmo_inval_pulse_q;
  assign o_cache_invalidate_addr = o_mem_write_addr;

  // ===========================================================================
  // Allocation (pure ring tail)
  // ===========================================================================
  // Allocate only at the tail to preserve program order. Reusing an interior
  // hole could put a younger uncommitted store ahead of older stores, causing
  // LQ/SQ deadlock or out-of-order writes. Flush pulls back the killed suffix;
  // head advancement skips failed-SC holes without reusing them.
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
  // Partial flush kills a suffix: younger uncommitted stores, or all
  // uncommitted stores when flush_all_uncommitted is set. Hold both pointers
  // during the flush, then rebuild [head_ptr, youngest_survivor+1) from the
  // registered valid mask on the next cycle for timing.
  //
  // Dispatch must not allocate during the flush or the pullback cycle, when
  // tail is stale. The stale window overstates occupancy, so back-pressure
  // remains conservative. Holding head also prevents its empty-collapse arm
  // from reading stale tail. A consecutive flush extends the hold and rebuilds
  // from the next registered valid mask.
  //
  // The highest valid offset from head is the youngest survivor. With none,
  // collapse tail to head. Pullback can reclaim trailing failed-SC holes;
  // interior holes must remain to preserve ring order. The encoder below
  // shares sq_head_valid_rotated with head advancement.

  // ===========================================================================
  // Head Advancement (first valid entry from head)
  // ===========================================================================
  // Rotate the valid mask, select the first entry, then add its offset to head.
  // The separate live count supplies empty status.

  logic [DEPTH-1:0] sq_head_valid_rotated;
  logic [IdxWidth-1:0] sq_head_first_valid_offset;
  logic sq_head_first_valid_found;

  // Barrel-rotate valid mask so head_ptr maps to index 0
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      sq_head_valid_rotated[i] = sq_valid[(32'(i)+32'(head_ptr[IdxWidth-1:0]))%DEPTH];
    end
  end

  // Select the lowest set offset in ring order.
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
      write_inflight_cached  <= 1'b0;
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
      write_inflight_cached  <= 1'b0;
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
        end
      end

      // Advance tail by the number of accepted stores, or pull it back after a
      // partial flush. These cases must be exclusive: local gates reject flush-
      // cycle allocations, and dispatch must stay idle during deferred pullback.
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

      // Slot-2 early address update; its tag differs from slot 1's.
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
      // Data Update: CAM search for matching rob_tag. A Zicbom entry has no
      // data and stays data-invalid (see Zicbom entries).
      // -----------------------------------------------------------------
      if (i_data_update.valid) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (sq_valid[i] && !sq_data_valid[i] && !sq_is_cmo[i] &&
              sq_rob_tag[i] == i_data_update.rob_tag) begin
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

      // Commit slot 2 never carries SC, so it needs no discard handling.
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

      // A special cached or MMIO write flies alone: its in-flight window
      // blocks all further launches until completion.
      write_inflight_special <= write_inflight_special_next;
      // The class of the latest launch is the class of every write in flight.
      if (mem_write_fire_next) write_inflight_cached <= mem_write_cached_plain_next;
      sq_sent <= sq_sent_next;
      // A Zicbom entry is sent as it fires (no write follows) and frees on
      // the next cycle.
      if (cmo_drain_fire) sq_sent[drain_idx_q] <= 1'b1;

      // -----------------------------------------------------------------
      // Head Advancement
      // -----------------------------------------------------------------
      // Hold head during flush and pullback: the pre-flush scan could select a
      // killed entry, and empty collapse must not read stale tail. Consecutive
      // flushes extend the hold until pullback completes.
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

  // Preserve committed stores, including those whose registered commit pulse
  // arrives before sq_committed is set; killing one would lose its write.
  // The ROB suppresses combinational commit pulses during flush, so they need
  // no exemption here. Omitting them simplifies timing.
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      flush_kill_base[i] =
          sq_valid[i] && !sq_committed[i] &&
          !(i_commit_valid && sq_rob_tag[i] == i_commit_rob_tag) &&
          !(i_commit_valid_2 && sq_rob_tag[i] == i_commit_rob_tag_2) &&
          (flush_all_uncommitted || is_younger(sq_rob_tag[i], i_flush_tag, i_rob_head_tag));
    end
  end

  // Failed-SC removal for sq_valid. The live count's mask below forms the
  // same terms in stages.
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      sc_discard_remove_mask[i] =
          i_sc_discard && sq_valid[i] && sq_is_sc[i] && !sq_committed[i] &&
          (sq_rob_tag[i] == i_sc_discard_rob_tag);
    end
  end

  assign drain_remove_valid = i_mem_write_done && (write_inflight_cnt != 2'd0) &&
                              write_completes_entry && sq_valid[write_entry_idx];

  // Union removal causes before counting: discard and flush may remove the
  // same SC. Allocations target free slots and cannot overlap removals.
  //
  // Each entry's removal forms in kept stages. The terms that do not read the
  // commit pulses, the SC discard or the write done come first: the
  // partial-flush kill without its commit exemption, each commit port's tag
  // match, the failed-SC candidate, the Zicbom free, and the entry that the
  // oldest in-flight write frees when it completes. The SC discard and the
  // write done apply next, and the registered commit pulses last, in the
  // mask's own gate, so each of these pulses reaches the count through a
  // fixed number of gates.
  (* keep = "true" *)logic [     DEPTH-1:0] live_flush_kill_cand;
  (* keep = "true" *)logic [     DEPTH-1:0] live_commit_match;
  (* keep = "true" *)logic [     DEPTH-1:0] live_commit_match_2;
  (* keep = "true" *)logic [     DEPTH-1:0] live_sc_discard_cand;
  (* keep = "true" *)logic [     DEPTH-1:0] live_cmo_free;
  (* keep = "true" *)logic [     DEPTH-1:0] live_write_done_cand;
  (* keep = "true" *)logic [     DEPTH-1:0] live_other_remove;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      live_flush_kill_cand[i] = i_flush_en && sq_valid[i] && !sq_committed[i] &&
          (flush_all_uncommitted || is_younger(sq_rob_tag[i], i_flush_tag, i_rob_head_tag));
      live_commit_match[i] = sq_rob_tag[i] == i_commit_rob_tag;
      live_commit_match_2[i] = sq_rob_tag[i] == i_commit_rob_tag_2;
      live_sc_discard_cand[i] = sq_valid[i] && sq_is_sc[i] && !sq_committed[i] &&
          (sq_rob_tag[i] == i_sc_discard_rob_tag);
      live_cmo_free[i] = cmo_free_q && (cmo_free_idx_q == IdxWidth'(i));
      live_write_done_cand[i] = (write_inflight_cnt != 2'd0) && write_completes_entry &&
          sq_valid[write_entry_idx] && (write_entry_idx == IdxWidth'(i));
    end
  end
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      live_other_remove[i] = (i_sc_discard && live_sc_discard_cand[i]) ||
          (i_mem_write_done && live_write_done_cand[i]) || live_cmo_free[i];
      live_remove_mask[i] = (live_flush_kill_cand[i] &&
          !(i_commit_valid && live_commit_match[i]) &&
          !(i_commit_valid_2 && live_commit_match_2[i])) || live_other_remove[i];
    end
  end

`ifndef SYNTHESIS
  `define SQ_LIVE_REMOVE_CHECK
`elsif SQ_LIVE_COUNT_LOCAL_PROOF
  `define SQ_LIVE_REMOVE_CHECK
`endif
`ifdef SQ_LIVE_REMOVE_CHECK
  // Reference: each entry's removal causes as one expression, from the
  // partial-flush kill and failed-SC masks that sq_valid uses.
  logic [DEPTH-1:0] live_remove_mask_reference;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      live_remove_mask_reference[i] = (i_flush_en && flush_kill_base[i]) ||
                                      sc_discard_remove_mask[i] ||
                                      (cmo_free_q && (cmo_free_idx_q == IdxWidth'(i))) ||
                                      (drain_remove_valid && (write_entry_idx == IdxWidth'(i)));
    end
  end
`endif
  `undef SQ_LIVE_REMOVE_CHECK

  // Precompute allocation increments before subtracting removals for timing.
  assign live_count_alloc_one = live_count_q + CountWidth'(alloc_room_1);
  assign live_count_alloc_both = live_count_q + CountWidth'(alloc_room_1) +
      CountWidth'(alloc_room_2);
  // Count the removals in kept groups of six entries, each count one gate of
  // its mask bits, so the subtractions below read the group counts directly
  // instead of a serial count of the whole mask.
  localparam int unsigned RemoveGroups = (DEPTH + 5) / 6;
  localparam int unsigned RemovePaddedBits = 6 * RemoveGroups;
  wire [RemovePaddedBits-1:0] live_remove_mask_padded = RemovePaddedBits'(live_remove_mask);
  (* keep = "true" *) logic [RemoveGroups-1:0][2:0] live_remove_group_count;
  always_comb begin
    for (int g = 0; g < int'(RemoveGroups); g++) begin
      live_remove_group_count[g] = '0;
      for (int b = 0; b < 6; b++) begin
        live_remove_group_count[g] = live_remove_group_count[g] +
            3'(live_remove_mask_padded[6*g+b]);
      end
    end
  end
  always_comb begin
    live_remove_count = '0;
    for (int g = 0; g < int'(RemoveGroups); g++) begin
      live_remove_count = live_remove_count + CountWidth'(live_remove_group_count[g]);
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

  // Check that the ROB never commits a store during partial flush. Formal
  // assumes this input rule; Yosys does not parse the assert-else action.
`ifndef SYNTHESIS
`ifndef FORMAL
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && i_rst_n) begin
      assert (!(i_flush_en && (i_commit_valid_comb || i_commit_valid_comb_2)))
      else $error("store_queue: combinational store commit in a partial-flush cycle");
    end
  end
`endif
`endif

  // Keep validity updates separate from other control fields for timing.
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

      // A Zicbom entry frees the cycle after it fires at the drain cursor.
      if (cmo_free_q) sq_valid[cmo_free_idx_q] <= 1'b0;
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
        sq_is_zero[i] <= slot1_alloc_oh[i] ? i_alloc.is_zero : i_alloc_2.is_zero;
        sq_is_cmo[i]  <= slot1_alloc_oh[i] ? i_alloc.is_cmo : i_alloc_2.is_cmo;
        sq_cmo_kind[i] <= slot1_alloc_oh[i] ? i_alloc.cmo_kind : i_alloc_2.cmo_kind;
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

    // Slot-2 early address payload.
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
    if (reset_seen_q && i_rst_n) begin
      if (i_alloc.valid && full) $warning("SQ: allocation attempted when full");
      // Flush-cycle requests are legal; allocation gates reject them like the ROB.
      if (i_alloc_2.valid && i_alloc.valid && full_for_2)
        $warning("SQ: slot-2 alloc attempted when full_for_2 (and slot-1 firing)");
      if (i_alloc_2.valid && !i_alloc.valid && full)
        $warning("SQ: slot-2 alloc attempted alone when full");
      // Dispatch must be idle during deferred pullback: allocating at stale tail
      // would place a valid entry outside the rebuilt window.
      if ((i_alloc.valid || i_alloc_2.valid) && flush_pullback_pending)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0) else
`endif
        $error("SQ: allocation attempted during flush tail-pullback cycle");
      if (slot1_alloc_en && slot2_alloc_en && (alloc_target[IdxWidth-1:0] == slot2_alloc_idx))
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0) else
`endif
        $error("SQ: slot-1 and slot-2 alloc collide on entry %0d", alloc_target[IdxWidth-1:0]);
      if (slot2_alloc_en != slot2_alloc_en_reference)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0) else
`endif
        $error("SQ: expanded slot-2 allocation enable differs from the reference");
      if (slot2_alloc_oh != slot2_alloc_oh_reference)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0) else
`endif
        $error("SQ: expanded slot-2 allocation pulses differ from the reference");
      if ((|slot1_alloc_oh) != slot1_alloc_en || !$onehot0(slot1_alloc_oh))
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0) else
`endif
        $error("SQ: slot-1 allocation pulse lost or invented an accepted request");
      if (alloc_oh != (slot1_alloc_oh | slot2_alloc_oh) || (|(slot1_alloc_oh & slot2_alloc_oh)))
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0) else
`endif
        $error("SQ: merged allocation pulses differ from the slot pulses");
      if (live_count_next != live_count_next_reference)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0) else
`endif
        $error("SQ: selected live-count candidate differs from the adder form");
      if (live_remove_mask != live_remove_mask_reference)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0) else
`endif
        $error("SQ: staged live-count removal mask differs from the reference");
      if (dispatch_full_next != dispatch_full_next_reference ||
          dispatch_full_for_2_next != dispatch_full_for_2_next_reference)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0) else
`endif
        $error("SQ: selected dispatch back-pressure differs from the adder form");
      if (next_same_d != next_same_reference)
`ifdef FROST_SIM_ASSERTIONS
        assert (1'b0) else
`endif
        $error("SQ: selected same-sector claim differs from the reference");
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
  // The reference mask counted one entry at a time.
  logic [CountWidth-1:0] f_remove_count_reference;
  always_comb begin
    f_remove_count_reference = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      f_remove_count_reference = f_remove_count_reference +
          CountWidth'(live_remove_mask_reference[i]);
    end
  end
  always_comb begin
    assert (live_count_if_none == f_count_none);
    assert (live_count_if_one == f_count_one);
    assert (live_count_if_both == f_count_both);
    assert (live_count_next == live_count_q + CountWidth'(slot1_alloc_en) +
        CountWidth'(slot2_alloc_en) - live_remove_count);
    assert (live_remove_mask == live_remove_mask_reference);
    assert (live_count_next == live_count_q + CountWidth'(slot1_alloc_en) +
        CountWidth'(slot2_alloc_en) - f_remove_count_reference);
  end
`endif

`ifdef FORMAL
`ifndef SQ_LIVE_COUNT_LOCAL_PROOF
`ifndef SQ_COMMITTED_EMPTY_LOCAL_PROOF
`ifndef SQ_NEXT_SAME_LOCAL_PROOF

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

  // Flush-cycle requests are legal but must not allocate, matching the ROB.
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

  // Dispatch must stay idle during deferred tail pullback; allocation at
  // stale tail would land outside the rebuilt window. Front-end redirect
  // and refill latency provide this gap.
  always_comb begin
    if (flush_pullback_pending) assume (!i_alloc.valid);
    if (flush_pullback_pending) assume (!i_alloc_2.valid);
  end

  // ROB commit_ready_early rejects both flushes, so combinational store
  // commits need no exemption from the partial-flush kill.
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

  // Address/data updates may overlap flush. A full flush clears control flags;
  // a partial flush clears killed entries' validity. Payload writes to those
  // entries stay hidden.

  // No allocation when full
  always_comb begin
    if (full) assume (!i_alloc.valid);
  end

  // Memory write done only when at least one write is in flight
  always_comb begin
    assume (!i_mem_write_done || (write_inflight_cnt != 2'd0));
  end

  // Registered commits may overlap with flush due to commit bus pipelining.
  // Full flush clears control state before commit processing. Partial flush
  // preserves entries whose registered commit pulse arrives on that edge.

  // Scan pulses equal architectural commits except during full flush, when
  // the captured probe result is unused and scan pulses are unrestricted.
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

  // Dead slots count toward the ring window, so full && empty can be transient.
  // Require live count <= window <= DEPTH. Without flush or pending pullback,
  // a fully dead window collapses on the next edge.
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
      p_write_has_irrevocable_permission :
      assert (sq_committed[mem_write_entry_idx_stg] ||
          (PRECISE_UNCACHED && i_uncached_store_shield &&
           (sq_rob_tag[mem_write_entry_idx_stg] == i_rob_head_tag)));
      p_write_needs_addr : assert (sq_addr_valid[mem_write_entry_idx_stg]);
      p_write_needs_data : assert (sq_data_valid[mem_write_entry_idx_stg]);
      p_write_from_valid : assert (sq_valid[mem_write_entry_idx_stg]);
    end
  end

  // Zero-block drain: a nonzero beat count belongs to the cursor's unsent
  // uncached zero entry, and each zero write on the bus writes eight zero
  // bytes with every strobe inside that entry's block. A cached zero entry
  // is one write at its block base, marked for the L1D and for a block-wide
  // L0 invalidation, which completes it; an uncached one completes on its
  // eighth beat. No other write carries either mark.
  logic f_mem_write_zero_stg, f_mem_write_zero_cached_stg;
  // The claim on the cycle that the next write fired (the write's bus cycle
  // follows it), and the sector of the write before. A full flush empties
  // only an SQ without committed stores.
  logic f_same_q;
  logic [XLEN-1:0] f_same_addr_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) f_same_q <= 1'b0;
    else if (mem_write_fire_next) f_same_q <= o_coherent_next_same;
    if (o_mem_write_en) f_same_addr_q <= o_mem_write_addr;
  end
  logic [ZeroBeatBits-1:0] f_mem_write_beat_stg;
  always_ff @(posedge i_clk) begin
    if (mem_write_fire_next) begin
      f_mem_write_zero_stg <= drain_is_zero;
      f_mem_write_zero_cached_stg <= drain_zero_cached;
      f_mem_write_beat_stg <= zero_beat_q;
    end
  end
  always_comb begin
    if (i_rst_n && (zero_beat_q != '0)) begin
      p_zero_beat_owns_cursor :
      assert (sq_valid[drain_idx_q] && sq_is_zero[drain_idx_q] && !sq_sent[drain_idx_q] &&
              !drain_zero_cached);
    end
    if (i_rst_n && o_mem_write_en) begin
      p_zero_write_marks :
      assert (o_coherent_write_zero == f_mem_write_zero_cached_stg &&
              o_cache_invalidate_block == f_mem_write_zero_cached_stg);
      if (f_mem_write_zero_cached_stg) begin
        p_zero_write_cached : assert (o_mem_write_is_cached && f_mem_write_zero_stg);
        p_zero_write_once : assert (f_mem_write_beat_stg == '0 && mem_write_completes_stg);
      end
    end
    if (i_rst_n && o_mem_write_en && f_mem_write_zero_stg) begin
      p_zero_beat_full_strobe : assert (o_mem_write_byte_en == '1);
      p_zero_beat_zero_data : assert (o_mem_write_data == '0);
      p_zero_beat_double : assert (o_mem_write_size == riscv_pkg::MEM_SIZE_DOUBLE);
      p_zero_beat_in_block :
      assert (o_mem_write_addr ==
              {sq_address[mem_write_entry_idx_stg][XLEN-1:ZeroBlockLsb],
               f_mem_write_beat_stg, 3'b000});
      if (!f_mem_write_zero_cached_stg)
        p_zero_beat_completes_last : assert (mem_write_completes_stg == (&f_mem_write_beat_stg));
    end
    if (i_rst_n && o_mem_write_en && !f_mem_write_zero_stg) begin
      p_scalar_write_completes : assert (mem_write_completes_stg);
    end
    // The claim holds for the next write: a cached plain write to the sector
    // of the write before it.
    if (i_rst_n && o_mem_write_en && f_same_q) begin
      p_write_same_successor :
      assert (o_mem_write_is_cached && !o_coherent_write_zero &&
          !o_coherent_write_sc && o_mem_write_addr[XLEN-1:5] == f_same_addr_q[XLEN-1:5]);
    end
  end

  // Zicbom entries: never data-valid, so never written (p_write_needs_data);
  // one fires only as the committed drain cursor, with no write in flight or
  // on the bus and no sent entry left, so every older store has completed,
  // and the entry it fired frees on the next cycle.
  always_comb begin
    if (i_rst_n) begin
      p_cmo_has_no_data : assert (!(|(sq_valid & sq_is_cmo & sq_data_valid)));
      if (cmo_drain_fire) begin
        p_cmo_frees_committed_cursor :
        assert (sq_valid[drain_idx_q] && sq_is_cmo[drain_idx_q] && sq_committed[drain_idx_q]);
        p_cmo_frees_after_writes : assert (write_inflight_cnt == 2'd0 && !o_mem_write_en);
        p_cmo_frees_oldest : assert (!(|(sq_valid & sq_sent)));
        p_cmo_frees_without_write : assert (!mem_write_fire_next);
        p_cmo_not_vec_held : assert (!vec_hold_q[drain_idx_q]);
      end
      if (cmo_free_q) begin
        p_cmo_free_is_sent_cmo :
        assert (sq_valid[cmo_free_idx_q] && sq_is_cmo[cmo_free_idx_q] && sq_sent[cmo_free_idx_q]);
      end
    end
  end

  // Check the physical address handed to both ordering consumers directly
  // from the defined translated window and the original SQ operand.
  for (genvar slot = 0; slot < DEPTH; slot++) begin : gen_cmo_order_address_check
    wire [XLEN-1:0] raw = sq_address[slot];
    wire alias_window = riscv_pkg::PbmtAliasEnabled &&
        raw >= XLEN'(riscv_pkg::DdrBase + riscv_pkg::PbmtAliasOffset) &&
        raw < XLEN'(riscv_pkg::PbmtAliasCoverLimit + riscv_pkg::PbmtAliasOffset);
    always_comb begin
      if (i_rst_n && sq_valid[slot] && sq_addr_valid[slot]) begin
        assert (sq_address_flat[slot*XLEN+:XLEN] ==
            (sq_is_cmo[slot] && alias_window ? raw - XLEN'(riscv_pkg::PbmtAliasOffset) : raw));
      end
    end
  end

  // Completion source of each write in the pipeline: the staged write on the
  // bus and the two FIFO slots, mirrored from the FIFO's own updates.
  logic f_cached_stg, f_cached0, f_cached1;
  always_ff @(posedge i_clk) begin
    if (mem_write_fire_next) f_cached_stg <= sq_cached_class[drain_idx_q];
    if (o_mem_write_en && i_mem_write_done && (write_inflight_cnt != 2'd0)) begin
      if (write_inflight_cnt == 2'd1) f_cached0 <= f_cached_stg;
      else begin
        f_cached0 <= f_cached1;
        f_cached1 <= f_cached_stg;
      end
    end else if (o_mem_write_en) begin
      if (write_inflight_cnt == 2'd0) f_cached0 <= f_cached_stg;
      else f_cached1 <= f_cached_stg;
    end else if (i_mem_write_done && (write_inflight_cnt != 2'd0)) f_cached0 <= f_cached1;
  end
  // In-flight discipline: never more than the 2-deep metadata FIFO can
  // hold, a special (cached SC, cbo.zero or MMIO) write flies alone, and
  // writes that share the pipeline share one completion source, so their
  // dones arrive in launch order.
  always_comb begin
    if (i_rst_n) begin
      if (write_inflight_cnt == 2'd2) p_overlap_one_source : assert (f_cached0 == f_cached1);
      if (write_inflight_cnt != 2'd0 && o_mem_write_en)
        p_overlap_bus_source :
        assert (f_cached_stg == (write_inflight_cnt == 2'd2 ? f_cached1 : f_cached0));
      p_inflight_bound : assert (write_inflight_cnt <= 2'd2);
      p_special_alone :
      assert (!write_inflight_special ||
                                (({1'b0, write_inflight_cnt} + {2'b0, o_mem_write_en}) <= 3'd1));
    end
  end

  // Forwarding outputs are driven from staged SQ CAM results, so they reflect
  // the previous check.
  always @(posedge i_clk) begin
    // Track the unmasked capture enable used by the forwarding register.
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
                sq_committed == '0 && sq_sent == '0 && committed_empty_q);
        p_flush_all_suppresses_memory_write :
        assert (!o_mem_write_en && !o_cache_invalidate_valid && write_inflight_cnt == '0);
      end
    end

    // Reset properties
    if (f_past_valid && i_rst_n && !$past(i_rst_n)) begin
      p_reset_empty : assert (o_empty);
      p_reset_count_zero : assert (o_count == '0);
      p_reset_committed_empty :
      assert (&{committed_empty_q, committed_empty_rob_q, committed_empty_trap_q,
                committed_empty_lq_q});
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
      // A Zicbom entry frees itself, and a flush or inval pulses the L0 block.
      cover_cmo_frees : cover (cmo_drain_fire);
      cover_cmo_inval_pulse : cover (cmo_inval_pulse_q && o_cache_invalidate_block);
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

      // A zero block frees its entry on the eighth beat's done.
      cover_zero_block_completes : cover (drain_remove_valid && sq_is_zero[write_entry_idx]);
      // A cached zero block leaves as one write.
      cover_zero_block_cached : cover (o_mem_write_en && o_coherent_write_zero);
      cover_write_more : cover (o_mem_write_en && o_mem_write_is_cached && o_coherent_write_more);
      // Two cached plain writes share the pipeline.
      cover_cached_overlap :
      cover (o_mem_write_en && o_mem_write_is_cached &&
          write_inflight_cnt != 2'd0 && write_inflight_cached);
    end
  end

`endif  // SQ_NEXT_SAME_LOCAL_PROOF
`endif  // SQ_COMMITTED_EMPTY_LOCAL_PROOF
`endif  // SQ_LIVE_COUNT_LOCAL_PROOF
`endif  // FORMAL

`ifndef SYNTHESIS
`ifndef FORMAL
  // A full flush waits for this committed entry and its home transaction.
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && i_rst_n) begin
      if (cmo_state_q == CmoRequest || cmo_state_q == CmoWait) begin
        a_cmo_cursor_ready : assert (cmo_start_ready);
        a_cmo_no_full_flush : assert (!i_flush_all);
      end
      if (o_cmo_valid) begin
        a_cmo_home_address : assert (CMO_HOME && riscv_pkg::pma_cached_ok(o_cmo_addr));
      end
    end
  end

  // Check that tail allocations use free slots and never overlap flush or
  // deferred pullback. Yosys does not parse assert-else actions; formal checks
  // flush rejection and free slots above, and assumes dispatch idle at pullback.
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && i_rst_n && !i_flush_all) begin
      a_no_alloc_during_flush :
      assert (!(i_flush_en && (slot1_alloc_en || slot2_alloc_en)))
      else $error("SQ allocation during partial flush conflicts with tail pullback");
      // The tail remains stale until pullback; dispatch must stay idle.
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
