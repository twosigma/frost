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
 * Store Queue - Commit-ordered store buffer with forwarding
 *
 * Circular buffer of DEPTH entries (8), allocated in program order at
 * dispatch time. Stores write to memory only AFTER the ROB commits
 * them (non-speculative writes). Supports store-to-load forwarding.
 *
 * Features:
 *   - Parameterized depth (8 entries, hybrid FF + LUTRAM; see Storage Strategy)
 *   - CAM-style tag search for address/data update (all entries in parallel)
 *   - In-order commit: head entry writes to memory when committed + ready
 *   - Store-to-load forwarding: combinational scan for LQ disambiguation
 *   - Two-phase FSD support (64-bit double → two 32-bit writes)
 *   - MMIO store handling (cache bypass on commit)
 *   - Partial flush: only uncommitted entries younger than flush_tag
 *   - Full flush support
 *   - L0 cache invalidation output on memory writes
 *
 * Storage Strategy:
 *   Hybrid FF + LUTRAM.  Control / scan fields (valid, addr_valid,
 *   data_valid, committed, rob_tag, address, size, etc.) remain in FFs
 *   for CAM-style parallel tag search, per-entry invalidation, and
 *   forwarding address scan.  sq_data (store payload) lives in
 *   distributed RAM (duplicated sdp_dist_ram for 2 read ports:
 *   forwarding result + head writeback).  The forwarding scan uses
 *   FF-based fields to find the match index, then reads sq_data from
 *   LUTRAM at that single address.  Valid bits gate all reads.
 *
 * Key Principle: Stores commit IN-ORDER
 *   1. Store dispatches → allocate SQ entry at tail
 *   2. Address calculates (MEM_RS issue) → addr_valid = 1
 *   3. Data available (MEM_RS issue) → data_valid = 1
 *   4. ROB commits store → committed = 1
 *   5. SQ writes to memory → sent = 1, free entry at head
 */

module store_queue #(
    parameter int unsigned DEPTH = riscv_pkg::SqDepth,  // 8
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
    // Slot-2 allocation port for 2-wide dispatch (Session C plumbing).  Slot-2
    // valid does NOT require slot-1 valid: dispatch derives each from its own
    // slot's mem_needs_sq, so it is legal for only slot-2 to be a store.  When
    // both fire, slot-1 is older than slot-2 in program order and must be
    // allocated to a lower physical position so the in-order commit/drain at
    // head_idx delivers stores to memory in program order.
    input  riscv_pkg::sq_alloc_req_t i_alloc_2,
    output logic                     o_full,
    // Asserted when there is room for at most 1 more entry (a 2-wide bundle of
    // two stores would not fit).  Distinct from o_full so dispatch can
    // independently gate slot-2.
    output logic                     o_full_for_2,
    // Registered back-pressure for the CPU dispatch path.
    // Exact o_full/o_full_for_2 remain available for local visibility and
    // direct queue allocation; these outputs are exact after the same edge
    // that updates the valid mask.
    output logic                     o_dispatch_full,
    output logic                     o_dispatch_full_for_2,

    // =========================================================================
    // Early Address Update (from pipelined dispatch-time address computation)
    // =========================================================================
    // Session L: dual-ported.  Slot-1 and slot-2 each have their own
    // pipelined-early-addr stage in tomasulo_wrapper, so two distinct
    // rob_tags can update sq_addr_valid + sq_address in the same cycle.
    // The CAM scans below run independently — each finds at most one
    // match by rob_tag, and rob_tags across the two updates are always
    // distinct (different ROB entries), so the NBA writes never collide
    // on a bit.
    input riscv_pkg::sq_addr_update_t i_early_addr_update,
    input riscv_pkg::sq_addr_update_t i_early_addr_update_2,

    // =========================================================================
    // Address Update (from MEM_RS issue path: base + imm, pre-computed)
    // =========================================================================
    input riscv_pkg::sq_addr_update_t i_addr_update,

    // =========================================================================
    // Data Update (from MEM_RS issue path: src2_value)
    // =========================================================================
    input riscv_pkg::sq_data_update_t i_data_update,

    // =========================================================================
    // Commit (from ROB commit bus, filtered for stores)
    // =========================================================================
    input logic                                        i_commit_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag,

    // Same-cycle commit guard: combinational commit_valid from ROB (unregistered).
    // When ROB commit and partial flush fire on the same cycle, the registered
    // i_commit_valid is still for the PREVIOUS cycle's commit. This signal
    // catches stores being committed THIS cycle so they aren't lost to the flush.
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

    // =========================================================================
    // Store-to-Load Forwarding (from LQ disambiguation)
    // =========================================================================
    input logic i_sq_check_valid,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr,
    // Second copy of the same address driven by a dont_touch'd LQ-side
    // replica register.  Used for the upper-half of the SQ CAM (entries
    // DEPTH/2..DEPTH-1) so the per-entry CARRY8 compare chains can split
    // across two physical anchor points instead of all routing from a
    // single source FF.  Functionally identical to i_sq_check_addr.
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_b,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_sq_check_rob_tag,
    input riscv_pkg::mem_size_e i_sq_check_size,
    output logic o_sq_all_older_addrs_known,
    output riscv_pkg::sq_forward_result_t o_sq_forward,

    // =========================================================================
    // Memory Write Interface (to data memory bus)
    // =========================================================================
    output logic                       o_mem_write_en,
    output logic [riscv_pkg::XLEN-1:0] o_mem_write_addr,
    output logic [riscv_pkg::XLEN-1:0] o_mem_write_data,
    output logic [                3:0] o_mem_write_byte_en,
    // Registered MMIO flag for the current head entry. Consumers at the
    // top level use this to gate the BRAM byte-write-enable at the SQ source
    // rather than recomputing an address-range check combinationally on the
    // muxed data memory address (which drags the LQ issue cone onto WEA).
    output logic                       o_mem_write_is_mmio,
    // Registered cached-tier flag for the current head entry (parallels is_mmio).
    // The router steers the store's byte-write enables to the cached tier when set.
    output logic                       o_mem_write_is_cached,
    input  logic                       i_mem_write_done,

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
  localparam int unsigned WordAddrWidth = XLEN - 2;
  localparam int unsigned MemSizeWidth = 2;

`ifndef SYNTHESIS
  localparam logic [XLEN-1:0] CoremarkListNodeLo = 32'h0001_f810;
  localparam logic [XLEN-1:0] CoremarkListNodeHi = 32'h0001_f910;
`endif

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

  // Check if store_tag is OLDER than load_tag (relative to rob_head)
  // i.e., the store was dispatched before the load in program order.
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

  function automatic logic word_addr_eq(input logic [WordAddrWidth-1:0] lhs,
                                        input logic [WordAddrWidth-1:0] rhs);
    logic [WordAddrWidth-1:0] diff;
    logic [5:0] group_has_diff;
    begin
      diff = lhs ^ rhs;
      group_has_diff[0] = |diff[4:0];
      group_has_diff[1] = |diff[9:5];
      group_has_diff[2] = |diff[14:10];
      group_has_diff[3] = |diff[19:15];
      group_has_diff[4] = |diff[24:20];
      group_has_diff[5] = |diff[29:25];
      word_addr_eq = ~(|group_has_diff);
    end
  endfunction

  function automatic logic full_addr_eq(input logic [XLEN-1:0] lhs, input logic [XLEN-1:0] rhs);
    logic [XLEN-1:0] diff;
    logic [6:0] group_has_diff;
    begin
      diff = lhs ^ rhs;
      group_has_diff[0] = |diff[4:0];
      group_has_diff[1] = |diff[9:5];
      group_has_diff[2] = |diff[14:10];
      group_has_diff[3] = |diff[19:15];
      group_has_diff[4] = |diff[24:20];
      group_has_diff[5] = |diff[29:25];
      group_has_diff[6] = |diff[31:30];
      full_addr_eq = ~(|group_has_diff);
    end
  endfunction

  function automatic logic [4:0] inc5(input logic [4:0] value, input logic carry_in);
    logic carry1;
    logic carry2;
    logic carry3;
    logic carry4;
    begin
      carry1 = carry_in & value[0];
      carry2 = carry1 & value[1];
      carry3 = carry2 & value[2];
      carry4 = carry3 & value[3];
      inc5   = value ^ {carry4, carry3, carry2, carry1, carry_in};
    end
  endfunction

  function automatic logic word_addr_inc_eq(input logic [WordAddrWidth-1:0] base,
                                            input logic [WordAddrWidth-1:0] target);
    logic [5:0] group_all_ones;
    logic [5:0] carry_in;
    logic [5:0] group_has_diff;
    begin
      group_all_ones[0] = &base[4:0];
      group_all_ones[1] = &base[9:5];
      group_all_ones[2] = &base[14:10];
      group_all_ones[3] = &base[19:15];
      group_all_ones[4] = &base[24:20];
      group_all_ones[5] = &base[29:25];

      carry_in[0] = 1'b1;
      carry_in[1] = group_all_ones[0];
      carry_in[2] = group_all_ones[0] & group_all_ones[1];
      carry_in[3] = group_all_ones[0] & group_all_ones[1] & group_all_ones[2];
      carry_in[4] = group_all_ones[0] & group_all_ones[1] & group_all_ones[2] & group_all_ones[3];
      carry_in[5] = group_all_ones[0] & group_all_ones[1] & group_all_ones[2] &
                    group_all_ones[3] & group_all_ones[4];

      group_has_diff[0] = |(target[4:0] ^ inc5(base[4:0], carry_in[0]));
      group_has_diff[1] = |(target[9:5] ^ inc5(base[9:5], carry_in[1]));
      group_has_diff[2] = |(target[14:10] ^ inc5(base[14:10], carry_in[2]));
      group_has_diff[3] = |(target[19:15] ^ inc5(base[19:15], carry_in[3]));
      group_has_diff[4] = |(target[24:20] ^ inc5(base[24:20], carry_in[4]));
      group_has_diff[5] = |(target[29:25] ^ inc5(base[29:25], carry_in[5]));

      word_addr_inc_eq = ~(|group_has_diff);
    end
  endfunction

  // Generate byte-enable mask from address offset and size
  function automatic logic [3:0] gen_byte_en(input logic [1:0] addr_offset,
                                             input riscv_pkg::mem_size_e size);
    begin
      case (size)
        riscv_pkg::MEM_SIZE_BYTE:   gen_byte_en = 4'b0001 << addr_offset;
        riscv_pkg::MEM_SIZE_HALF:   gen_byte_en = addr_offset[1] ? 4'b1100 : 4'b0011;
        riscv_pkg::MEM_SIZE_WORD:   gen_byte_en = 4'b1111;
        riscv_pkg::MEM_SIZE_DOUBLE: gen_byte_en = 4'b1111;  // Each phase is word-width
        default:                    gen_byte_en = 4'b0000;
      endcase
    end
  endfunction

  // Generate write data with correct byte-lane positioning
  function automatic logic [XLEN-1:0] gen_write_data(
      input logic [FLEN-1:0] data, input riscv_pkg::mem_size_e size, input logic fp64_phase);
    begin
      case (size)
        riscv_pkg::MEM_SIZE_BYTE:   gen_write_data = {4{data[7:0]}};
        riscv_pkg::MEM_SIZE_HALF:   gen_write_data = {2{data[15:0]}};
        riscv_pkg::MEM_SIZE_WORD:   gen_write_data = data[31:0];
        riscv_pkg::MEM_SIZE_DOUBLE: gen_write_data = fp64_phase ? data[63:32] : data[31:0];
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
  logic                 [                DEPTH-1:0] sq_fp64_phase;
  logic                 [                DEPTH-1:0] sq_committed;
  logic                 [                DEPTH-1:0] sq_sent;
  logic                 [                DEPTH-1:0] sq_is_sc;

  // Per-entry multi-bit fields
  logic                 [ReorderBufferTagWidth-1:0] sq_rob_tag                        [DEPTH];
  logic                 [                 XLEN-1:0] sq_address                        [DEPTH];
  riscv_pkg::mem_size_e                             sq_size                           [DEPTH];

  // ===========================================================================
  // sq_data LUTRAM — duplicated for 2 read ports
  // ===========================================================================
  // sq_data is written once (data_update CAM match) and read at two
  // independent addresses: fwd_match_idx (forwarding scan result) and
  // head_idx (memory write).  Duplicate sdp_dist_ram instances receive
  // identical writes; each provides one async read port.
  // Valid bits in FFs gate all reads; alloc-time zeroing is unnecessary.

  // Write port: resolved CAM match index from data_update
  logic                                             sq_data_we;
  logic                 [             IdxWidth-1:0] sq_data_wr_idx;

  always_comb begin
    sq_data_we     = 1'b0;
    sq_data_wr_idx = '0;
    if (i_data_update.valid && i_rst_n && !i_flush_all) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (sq_valid[i] && !sq_data_valid[i] && sq_rob_tag[i] == i_data_update.rob_tag) begin
          sq_data_we     = 1'b1;
          sq_data_wr_idx = IdxWidth'(i);
        end
      end
    end
  end

  // Forwarding scan result index (set by forwarding always_comb below)
  logic [IdxWidth-1:0] fwd_match_idx;

  // Read outputs
  logic [FLEN-1:0] sq_data_fwd_rd;  // at fwd_match_idx
  logic [FLEN-1:0] sq_data_head_rd;  // at head_idx

  sdp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH(FLEN)
  ) u_sq_data_fwd (
      .i_clk,
      .i_write_enable (sq_data_we),
      .i_write_address(sq_data_wr_idx),
      .i_write_data   (i_data_update.data),
      .i_read_address (fwd_match_idx),
      .o_read_data    (sq_data_fwd_rd)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH(FLEN)
  ) u_sq_data_head (
      .i_clk,
      .i_write_enable (sq_data_we),
      .i_write_address(sq_data_wr_idx),
      .i_write_data   (i_data_update.data),
      .i_read_address (head_idx),
      .o_read_data    (sq_data_head_rd)
  );

  // ===========================================================================
  // Internal Signals
  // ===========================================================================

  logic                  full;
  logic                  full_for_2;
  logic                  empty;
  logic                  dispatch_full_q;
  logic                  dispatch_full_for_2_q;
  logic [CountWidth-1:0] count;
  logic [CountWidth-1:0] dispatch_count_next;
  logic                  committed_empty_q;

  // Slot-1 / slot-2 alloc targets and write enables (declared early so they
  // are available to LUTRAM port lists if needed; assignments come below).
  logic [  PtrWidth-1:0] alloc_target_2;
  logic                  slot1_alloc_en;
  logic                  slot2_alloc_en;
  logic [  IdxWidth-1:0] slot2_alloc_idx;

  // Memory write tracking
  logic                  write_outstanding;  // One outstanding write at a time
  logic [  IdxWidth-1:0] write_entry_idx;
  logic                  write_completes_entry;

  // Head entry readiness
  logic                  head_ready;  // Head entry committed + addr_valid + data_valid

  // Head/tail search targets for the sparse valid-bit queue.
  logic [  PtrWidth-1:0] head_advance_target;
  logic [  PtrWidth-1:0] alloc_target;
  logic                  flush_all_uncommitted;

  // ===========================================================================
  // Count, Full, Empty
  // ===========================================================================
  // Capacity is the ring WINDOW (tail - head), not the live popcount: with
  // pure tail allocation, a slot is reusable only once the head has passed
  // it, so holes inside the window (rare sc_discard frees) still consume
  // capacity until the head skip-advance walks over them. Window-based full
  // is conservative in exactly those cases and exact otherwise. The popcount
  // is kept for o_count/empty/visibility consumers.
  logic [  PtrWidth-1:0] window_occupancy;
  assign window_occupancy = tail_ptr - head_ptr;

  always_comb begin
    count = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      count = count + CountWidth'(sq_valid[i]);
    end
  end

  assign full = (window_occupancy >= PtrWidth'(DEPTH));
  // full_for_2: room for at most 1 more entry, so a 2-wide bundle of two
  // stores would not fit even if neither slot has been allocated yet.
  assign full_for_2 = (window_occupancy >= PtrWidth'(DEPTH - 1));
  assign empty = (count == CountWidth'(0));

  assign o_full = full;
  assign o_full_for_2 = full_for_2;
  assign o_dispatch_full = dispatch_full_q;
  assign o_dispatch_full_for_2 = dispatch_full_for_2_q;
  assign o_empty = empty;
  assign o_dispatch_empty = empty;
  assign o_count = count;
  assign o_dispatch_count = count;

  // Slot-1 / slot-2 allocation enables.  Slot-2 valid does not require slot-1
  // valid; if both fire, slot-1 (older) takes the first free slot from
  // tail_ptr and slot-2 (younger) takes the second so the SQ's in-order
  // commit/drain at head_idx writes stores to memory in program order.
  assign slot1_alloc_en = i_alloc.valid && !full;
  assign slot2_alloc_en = i_alloc_2.valid && (slot1_alloc_en ? !full_for_2 : !full);
  assign slot2_alloc_idx = slot1_alloc_en ? alloc_target_2[IdxWidth-1:0]
                                          : alloc_target[IdxWidth-1:0];


  // Registered dispatch back-pressure mirrors the window math: allocations
  // grow the window this cycle; every reclaim (drain completion, head
  // skip-advance over sc holes, partial-flush tail pullback) is picked up
  // from the live window_occupancy one cycle later. Deliberately NO
  // same-cycle drain decrement: the head advances the cycle AFTER a drain
  // completes, so decrementing early deasserts back-pressure one cycle
  // before the slot is actually reusable — dispatch then sends an alloc the
  // SQ refuses (a silently lost store). Back-pressure is therefore only
  // ever conservatively long, never short.
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
  // Store-to-Load Forwarding -> sq_forwarding_unit.sv (pure boundary move).
  // The SQ data-RAM forwarding read (addressed by fwd_match_idx) stays here.
  // ===========================================================================
  sq_forwarding_unit #(
      .DEPTH(DEPTH)
  ) sq_forwarding_unit_inst (
      .i_clk                     (i_clk),
      .i_rst_n                   (i_rst_n),
      .i_flush_all               (i_flush_all),
      .i_sq_check_valid          (i_sq_check_valid),
      .i_sq_check_addr           (i_sq_check_addr),
      .i_sq_check_addr_b         (i_sq_check_addr_b),
      .i_sq_check_size           (i_sq_check_size),
      .i_sq_check_rob_tag        (i_sq_check_rob_tag),
      .i_rob_head_tag            (i_rob_head_tag),
      .i_commit_valid            (i_commit_valid),
      .i_commit_rob_tag          (i_commit_rob_tag),
      .i_commit_valid_2          (i_commit_valid_2),
      .i_commit_rob_tag_2        (i_commit_rob_tag_2),
      .sq_valid                  (sq_valid),
      .sq_addr_valid             (sq_addr_valid),
      .sq_data_valid             (sq_data_valid),
      .sq_is_mmio                (sq_is_mmio),
      .sq_committed              (sq_committed),
      .sq_rob_tag_flat           (sq_rob_tag_flat),
      .sq_address_flat           (sq_address_flat),
      .sq_size_flat              (sq_size_flat),
      .sq_data_fwd_rd            (sq_data_fwd_rd),
      .o_sq_all_older_addrs_known(o_sq_all_older_addrs_known),
      .o_sq_forward              (o_sq_forward),
      .o_fwd_match_idx           (fwd_match_idx)
  );

  // ===========================================================================
  // Memory Write Logic (combinational)
  // ===========================================================================
  // Head entry writes to memory when committed, addr_valid, data_valid.
  // One outstanding write at a time. FSD uses two phases.
  //
  // TIMING: The write interface is registered to break the head_ptr →
  // head_ready → o_mem_write_en combinational cone that was the critical
  // path (-1.059 ns WNS).  head_ready feeds the combinational next-state
  // of a pipeline register; the actual o_mem_write_en output is a flop.
  // This adds one cycle to each committed-store drain (2 → 3 cycles per
  // store) but the SQ's write_outstanding already serialises drains, and
  // SQ-full dispatch stalls are < 0.2% in CoreMark.

  assign head_ready = sq_valid[head_idx] && sq_committed[head_idx] &&
                      sq_addr_valid[head_idx] && sq_data_valid[head_idx] &&
                      !sq_sent[head_idx];

  logic                       mem_write_fire_next;
  logic [riscv_pkg::XLEN-1:0] mem_write_addr_next;
  logic [riscv_pkg::XLEN-1:0] mem_write_data_next;
  logic [                3:0] mem_write_byte_en_next;
  logic                       mem_write_is_mmio_next;
  logic                       mem_write_is_cached_next;

  always_comb begin
    mem_write_fire_next    = 1'b0;
    mem_write_addr_next    = '0;
    mem_write_data_next    = '0;
    mem_write_byte_en_next = '0;
    mem_write_is_mmio_next = 1'b0;
    mem_write_is_cached_next = 1'b0;

    if (head_ready && !write_outstanding && !o_mem_write_en) begin
      mem_write_fire_next = 1'b1;

      // FSD phase 1: write upper word at addr+4
      if (sq_size[head_idx] == riscv_pkg::MEM_SIZE_DOUBLE && sq_fp64_phase[head_idx]) begin
        mem_write_addr_next = sq_address[head_idx] + 32'd4;
      end else begin
        mem_write_addr_next = sq_address[head_idx];
      end

      mem_write_data_next = gen_write_data(
          sq_data_head_rd, riscv_pkg::mem_size_e'(sq_size[head_idx]), sq_fp64_phase[head_idx]);
      mem_write_byte_en_next =
          gen_byte_en(mem_write_addr_next[1:0], riscv_pkg::mem_size_e'(sq_size[head_idx]));
      mem_write_is_mmio_next = sq_is_mmio[head_idx];
      // cached-tier decode of the actual write address. Registered below into
      // o_mem_write_is_cached (parallel to is_mmio), so the comparator stays in
      // the addr->register cone and never reaches the BRAM WEA pin.
      mem_write_is_cached_next =
          (mem_write_addr_next >= CACHED_BASE[riscv_pkg::XLEN-1:0]) &&
          (mem_write_addr_next <  (CACHED_BASE[riscv_pkg::XLEN-1:0] +
                                   CACHED_SIZE_BYTES[riscv_pkg::XLEN-1:0]));
    end
  end

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
      mem_write_entry_idx_stg <= head_idx;
      mem_write_completes_stg <= !(sq_size[head_idx] == riscv_pkg::MEM_SIZE_DOUBLE &&
                                   !sq_fp64_phase[head_idx]);
    end
  end

  // ===========================================================================
  // L0 Cache Invalidation (at memory write LAUNCH)
  // ===========================================================================
  // Invalidate the LQ's L0 cache at the written address in the same cycle
  // the write fires. Invalidating at launch instead of at write-done closes
  // the stale-L0-hit window for ANY write latency with no extra gating:
  // between launch and done nobody can read the old memory word either (the
  // router owns the shared port and queues/replays reads behind the write
  // flight), so the only reachable outcomes are an L0 miss plus a
  // correctly-ordered memory read. Early invalidation is always safe -- at
  // worst it costs one refill miss. The previous done-time pulse left the
  // L0 line live during a multi-cycle cached write flight; papering over that
  // with a busy-stretch in the LQ taxed every BRAM store drain (~2%
  // CoreMark), and routing the cached-flight signal into the LQ's busy
  // instead pushed the L0-hit/CDB cone past timing. Both outputs come
  // straight from SQ output registers, adding no new logic levels anywhere.
  // FSD fires one invalidate per phase (addr, then addr+4). MMIO stores
  // also pulse harmlessly (the L0 never caches MMIO).
  assign o_cache_invalidate_valid = o_mem_write_en;
  assign o_cache_invalidate_addr = o_mem_write_addr;

  // ===========================================================================
  // Allocation (pure ring tail)
  // ===========================================================================
  // Allocate strictly at the ring tail. Ring position must encode program
  // order for the head-ordered drain to deliver stores to memory in program
  // order; the previous policy ("keep sparse holes after partial flush and
  // search forward from tail_ptr for the next invalid slot") let younger
  // stores land in flush holes at ring positions the head reaches BEFORE
  // older live entries. Committed older stores then stranded behind a
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
  // Flush Tail Pullback (retimed: applies the cycle AFTER the flush)
  // ===========================================================================
  // A partial flush kills a program-order SUFFIX of the live window (all
  // uncommitted entries younger than flush_tag), so the window is rebuilt as
  // [head_ptr, youngest_survivor + 1).
  //
  // TIMING: the pullback used to be computed in the flush cycle from a
  // survivor mask that mirrored the kill predicate — i.e. from i_flush_en,
  // i_flush_tag and the same-cycle ROB commit pulses, all of which arrive
  // late out of the ROB-head commit cone. Survivor mask → rotate →
  // priority-encode → adder then converged on the tail_ptr D and head_ptr CE
  // pins: an 18-LUT-level path (post-opt WNS -1.36 at 300 MHz). Instead the
  // flush cycle now only clears per-entry valid bits (short, per-entry
  // endpoints) while both pointers HOLD; one cycle later, while
  // flush_pullback_pending is set, the tail is rebuilt from the REGISTERED
  // post-kill valid mask and head_ptr — a full-cycle path from FF outputs.
  //
  // The deferred cycle is safe because:
  //  - dispatch cannot allocate in the flush cycle or the cycle after (the
  //    front-end redirect/refill takes several cycles; asserted below), so
  //    nothing consumes the stale tail for allocation;
  //  - window_occupancy reads stale-HIGH (killed suffix still inside the
  //    window) so full/dispatch back-pressure is conservative, never short;
  //  - the head is held for the same two cycles, so its empty-collapse arm
  //    (head <= tail) never samples the stale tail;
  //  - a second flush arriving in the pending cycle (back-to-back EX-side
  //    mispredicts) just re-kills valid bits and extends pending one cycle:
  //    the rebuild only ever reads registered state, so it is idempotent.
  //
  // The youngest surviving entry is the highest set offset in the
  // head-rotated valid mask (sq_head_valid_rotated, shared with the head
  // advance logic): entries outside [head, tail) are never valid, killed
  // entries were just cleared, and pre-existing sc_discard holes are
  // valid=0, exactly as the old survivor mask treated them. With no valid
  // entry left the window collapses to the held head pointer. Trailing
  // sc_discard holes (no live entry younger than them) are reclaimed by the
  // pullback, which is safe: only reclaiming a hole with live entries BEYOND
  // it would break the ring-order invariant.
  // (The pullback encoder lives just below the Head Advancement section so it
  // can share sq_head_valid_rotated.)

  // ===========================================================================
  // Head Advancement (tree-based find-first-valid from head)
  // ===========================================================================
  // TIMING: Replaced O(DEPTH) serial scan with rotate → tree-priority-encode →
  // add-back (O(log2(DEPTH)) logic levels).  The serial scan created a 16-level
  // chain from sq_valid through the popcount-based empty check and cascaded
  // pointer increments; this tree form cuts it to ~4-5 levels.

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

  // Pullback encoder (see Flush Tail Pullback above): the HIGHEST set offset
  // in the head-rotated registered valid mask is the youngest surviving
  // entry's window position. Mirror of the first-valid encoder above.
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
      head_ptr          <= '0;
      tail_ptr          <= '0;
      sq_addr_valid     <= '0;
      sq_data_valid     <= '0;
      sq_committed      <= '0;
      sq_sent           <= '0;
      write_outstanding <= 1'b0;
    end else if (i_flush_all) begin
      // Full flush: reset control signals
      head_ptr          <= '0;
      tail_ptr          <= '0;
      sq_addr_valid     <= '0;
      sq_data_valid     <= '0;
      sq_committed      <= '0;
      sq_sent           <= '0;
      write_outstanding <= 1'b0;
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

      // Slot-2 alloc — fires when a slot-2 store allocates this cycle.
      if (slot2_alloc_en) begin
        sq_addr_valid[slot2_alloc_idx] <= i_alloc_2.addr_valid;
        sq_data_valid[slot2_alloc_idx] <= 1'b0;
        sq_committed[slot2_alloc_idx]  <= 1'b0;
        sq_sent[slot2_alloc_idx]       <= 1'b0;
      end

      // tail_ptr advances past the highest slot consumed this cycle (when
      // only slot-2 fires it took alloc_target, so tail advances to
      // alloc_target+1). A partial flush HOLDS the tail for one cycle while
      // the per-entry kills land, then the pending arm pulls it back over
      // the killed program-order suffix from the registered valid mask (see
      // Flush Tail Pullback) so flush holes never persist and ring position
      // keeps encoding program order. Dispatch never allocates in a flush
      // or pullback cycle (asserted below), so the arms are mutually
      // exclusive.
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

      // Session L: slot-2 early addr update (control).  rob_tags across the
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
      // cycle.  The two loops are independent — each slot scans the whole
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
      // Memory Write Initiation (from registered write interface)
      // -----------------------------------------------------------------
      // o_mem_write_en is now a registered output; use the staging
      // registers captured alongside it for entry_idx and completes_entry.
      if (o_mem_write_en) begin
        write_outstanding <= 1'b1;
      end

      // -----------------------------------------------------------------
      // Memory Write Completion
      // -----------------------------------------------------------------
      if (i_mem_write_done && write_outstanding) begin
        if (!write_completes_entry) begin
          // FSD phase 0 complete: advance to phase 1, allow next write
          write_outstanding <= 1'b0;
        end else begin
          // Single-phase complete or FSD phase 1 complete: free entry
          sq_sent[write_entry_idx] <= 1'b1;
          write_outstanding <= 1'b0;
        end
      end

      // -----------------------------------------------------------------
      // Head Advancement
      // -----------------------------------------------------------------
      // Skip-advance to the first valid entry. Held during the flush cycle
      // (head_advance_target is computed from the pre-flush valid mask and
      // could step into the just-killed region) and during the pullback
      // cycle (its empty-collapse arm reads tail_ptr, which is stale until
      // the pullback lands). Holding merely delays a drain advance by up to
      // two cycles; the scan recomputes from valid bits every cycle.
      if (!i_flush_en && !flush_pullback_pending) begin
        head_ptr <= head_advance_target;
      end

    end  // !flush_all

    if (o_mem_write_en) begin
      write_entry_idx <= mem_write_entry_idx_stg;
      write_completes_entry <= mem_write_completes_stg;
    end
  end

  // Keep sq_valid separate so full-flush and partial-flush invalidation do not
  // share one next-state cone with the other SQ control fields.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      sq_valid <= '0;
    end else if (i_flush_all) begin
      sq_valid <= '0;
    end else begin
      // Partial flush: invalidate UNCOMMITTED entries younger than flush_tag.
      // Committed entries are never flushed (they must complete to memory).
      if (i_flush_en) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (sq_valid[i] && !sq_committed[i] &&
              // Guard the registered commit cycle while sq_committed is still
              // one NBA behind.
              !(i_commit_valid && sq_rob_tag[i] == i_commit_rob_tag) &&
              !(i_commit_valid_2 && sq_rob_tag[i] == i_commit_rob_tag_2) &&
              // Same-cycle combinational commit guard: when a ROB commit and
              // the partial flush fire in the SAME cycle, the registered
              // i_commit_valid still reflects the previous cycle and
              // sq_committed has not set yet. flush_all_uncommitted bypasses
              // the age check, so without these terms a store committing in
              // the flush cycle (e.g. widen-commit slot 2 retiring alongside
              // a delayed-recovery branch at the head) is invalidated and its
              // memory write silently lost (dropped UART chars / corrupted
              // cjpeg output bytes in the system runs).
              !(i_commit_valid_comb && sq_rob_tag[i] == i_commit_rob_tag_comb) &&
              !(i_commit_valid_comb_2 && sq_rob_tag[i] == i_commit_rob_tag_comb_2) &&
              (flush_all_uncommitted || is_younger(
                  sq_rob_tag[i], i_flush_tag, i_rob_head_tag
              ))) begin
            sq_valid[i] <= 1'b0;
          end
        end
        // tail_ptr is pulled back over the killed suffix in the control
        // always_ff (see Flush Tail Pullback).
      end

      if (slot1_alloc_en) begin
        sq_valid[alloc_target[IdxWidth-1:0]] <= 1'b1;
      end
      // Slot-2 alloc — fires when a slot-2 store allocates this cycle.
      if (slot2_alloc_en) begin
        sq_valid[slot2_alloc_idx] <= 1'b1;
      end

      // Failed SC invalidates its uncommitted SQ entry.
      if (i_sc_discard) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (sq_valid[i] && sq_is_sc[i] && !sq_committed[i]
              && sq_rob_tag[i] == i_sc_discard_rob_tag) begin
            sq_valid[i] <= 1'b0;
          end
        end
      end

      // Single-phase completion or FSD phase 1 completion frees the head entry.
      if (i_mem_write_done && write_outstanding && write_completes_entry) begin
        sq_valid[write_entry_idx] <= 1'b0;
      end
    end
  end

  // -------------------------------------------------------------------
  // Data-signal always_ff (no reset, no flush_all — self-gated writes)
  // -------------------------------------------------------------------
  // These per-entry data fields are only consumed when paired control
  // flags (sq_valid, sq_addr_valid, sq_data_valid) are set.  The control
  // block above clears those flags on reset/flush, so the data values
  // are inherently don't-care and need no reset.
  // -------------------------------------------------------------------

  always_ff @(posedge i_clk) begin

    // -----------------------------------------------------------------
    // Allocation: write per-entry data for new entry at tail
    // -----------------------------------------------------------------
    if (slot1_alloc_en) begin
      sq_rob_tag[alloc_target[IdxWidth-1:0]]    <= i_alloc.rob_tag;
      sq_size[alloc_target[IdxWidth-1:0]]       <= i_alloc.size;
      sq_fp64_phase[alloc_target[IdxWidth-1:0]] <= 1'b0;
      sq_is_sc[alloc_target[IdxWidth-1:0]]      <= i_alloc.is_sc;
      if (i_alloc.addr_valid) begin
        sq_address[alloc_target[IdxWidth-1:0]] <= i_alloc.address;
        sq_is_mmio[alloc_target[IdxWidth-1:0]] <= i_alloc.is_mmio;
      end
    end

    // Slot-2 alloc — fires when a slot-2 store allocates this cycle.
    if (slot2_alloc_en) begin
      sq_rob_tag[slot2_alloc_idx]    <= i_alloc_2.rob_tag;
      sq_size[slot2_alloc_idx]       <= i_alloc_2.size;
      sq_fp64_phase[slot2_alloc_idx] <= 1'b0;
      sq_is_sc[slot2_alloc_idx]      <= i_alloc_2.is_sc;
      if (i_alloc_2.addr_valid) begin
        sq_address[slot2_alloc_idx] <= i_alloc_2.address;
        sq_is_mmio[slot2_alloc_idx] <= i_alloc_2.is_mmio;
      end
    end

    // -----------------------------------------------------------------
    // Early Address Update: pipelined dispatch-time addr (data only)
    // -----------------------------------------------------------------
    if (i_early_addr_update.valid) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (sq_valid[i] && !sq_addr_valid[i] && sq_rob_tag[i] == i_early_addr_update.rob_tag) begin
          sq_address[i] <= i_early_addr_update.address;
          sq_is_mmio[i] <= i_early_addr_update.is_mmio;
        end
      end
    end

    // Session L: slot-2 early addr update (data).  Distinct-rob_tag invariant
    // again guarantees no collision with the slot-1 loop above.
    if (i_early_addr_update_2.valid) begin
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
    if (i_addr_update.valid) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (sq_valid[i] && !sq_addr_valid[i] && sq_rob_tag[i] == i_addr_update.rob_tag) begin
          sq_address[i] <= i_addr_update.address;
          sq_is_mmio[i] <= i_addr_update.is_mmio;
        end
      end
    end

    // -----------------------------------------------------------------
    // Memory Write Completion: FSD phase advance (data only)
    // -----------------------------------------------------------------
    if (i_mem_write_done && write_outstanding) begin
      if (!write_completes_entry) begin
        sq_fp64_phase[write_entry_idx] <= 1'b1;
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
      // Only PARTIAL flush (i_flush_en) is dangerous: there the alloc block in
      // the !flush_all else-branch actually LANDS (sets sq_valid, line ~1060).
      // i_flush_all is intentionally excluded — its priority else-if branches
      // (lines ~859, ~1027) structurally squash the alloc (sq_valid <= '0), a
      // documented-safe, formally-proven (p_alloc_slot_free) handshake that the
      // RS issues un-flush-gated for timing closure (see note ~line 1263). The
      // old (i_flush_all||i_flush_en) form fired ~1178x/run on the benign
      // flush_all handshake, burying the genuinely-unsafe flush_en case.
      if (i_alloc.valid && i_flush_en && !i_flush_all)
        $warning("SQ: allocation attempted during partial flush");
      if (i_alloc_2.valid && i_alloc.valid && full_for_2)
        $warning("SQ: slot-2 alloc attempted when full_for_2 (and slot-1 firing)");
      if (i_alloc_2.valid && !i_alloc.valid && full)
        $warning("SQ: slot-2 alloc attempted alone when full");
      if (i_alloc_2.valid && i_flush_en && !i_flush_all)
        $warning("SQ: slot-2 alloc attempted during partial flush");
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

  // No allocation during flush, nor during the deferred tail-pullback cycle
  // that follows a partial flush (the tail is stale until the pullback
  // lands). The front-end redirect/refill latency guarantees both with
  // cycles to spare; the simulation assertion block (ifndef FORMAL, below)
  // checks the same contract against the real dispatcher.
  always_comb begin
    if (i_flush_all || i_flush_en) assume (!i_alloc.valid);
    if (i_flush_all || i_flush_en) assume (!i_alloc_2.valid);
    if (flush_pullback_pending) assume (!i_alloc.valid);
    if (flush_pullback_pending) assume (!i_alloc_2.valid);
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

  // Address/data updates MAY arrive during flush (RS stage2 issues without
  // same-cycle flush gating for timing closure).  This is safe:
  //   - flush_all: the else-if branch resets all state; update code in the
  //     else branch is unreachable.
  //   - flush_en: CAM matches only entries with sq_valid[i]==1; entries
  //     whose valid is being cleared on the same edge get a harmless
  //     write into a dead slot.
  // (assumption removed — was: no addr/data update during flush)

  // No allocation when full
  always_comb begin
    if (full) assume (!i_alloc.valid);
  end

  // Memory write done only when outstanding
  always_comb begin
    assume (!i_mem_write_done || write_outstanding);
  end

  // Commit MAY overlap with flush due to commit bus pipelining.  This is
  // safe: flush_all resets all SQ state (else-if priority over commit
  // processing), and flush_en only flushes younger entries while the
  // committed head is always older than the flush boundary.
  // (assumption removed — was: no commit during flush)

  // -------------------------------------------------------------------------
  // Combinational assertions
  // -------------------------------------------------------------------------

  // Window sanity. Capacity is the ring window (tail - head), which may
  // exceed the live popcount when the window holds dead slots (killed
  // entries awaiting the retimed tail pullback, or sc_discard holes the
  // head has not passed) — so full && empty is a legal TRANSIENT, unlike
  // the old popcount-full design. The invariants that do hold:
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
    end
  end

  // If all entries are valid, the queue must report full.
  always_comb begin
    if (i_rst_n) begin
      p_all_valid_implies_full : assert (f_valid_count < CountWidth'(DEPTH) || o_full);
    end
  end

  // Memory write only from head when committed + addr_valid + data_valid
  always_comb begin
    if (i_rst_n && o_mem_write_en) begin
      p_write_needs_committed : assert (sq_committed[head_idx]);
      p_write_needs_addr : assert (sq_addr_valid[head_idx]);
      p_write_needs_data : assert (sq_data_valid[head_idx]);
      p_write_from_valid : assert (sq_valid[head_idx]);
    end
  end

  // No memory write when already outstanding
  always_comb begin
    if (i_rst_n && write_outstanding) begin
      p_no_double_write : assert (!o_mem_write_en);
    end
  end

  // Forwarding outputs are driven from staged SQ CAM results, so they reflect
  // the previous check.
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(
            i_rst_n
        ) && !$past(
            i_flush_all
        ) && !$past(
            i_sq_check_valid
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

  // Committed entries are never flushed (partial flush safety)
  // Track: after partial flush, all previously committed entries remain valid
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
      cover_mem_done : cover (i_mem_write_done && write_outstanding);
      cover_forward_match : cover (o_sq_forward.match);
      cover_forward_data : cover (o_sq_forward.can_forward);
      cover_full : cover (full);
      cover_flush_nonempty : cover (i_flush_en && |sq_valid);

      // Committed entry survives partial flush
      cover_committed_survives : cover (i_flush_en && |(sq_valid & sq_committed));

      // FSD two-phase memory write
      cover_fsd_phase1 : cover (o_mem_write_en && sq_fp64_phase[head_idx]);

      // Cache invalidation on write completion
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
