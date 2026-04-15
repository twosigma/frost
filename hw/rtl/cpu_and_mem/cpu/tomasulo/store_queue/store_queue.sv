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
 *   - Parameterized depth (8 entries, FF-based)
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
    parameter int unsigned DEPTH = riscv_pkg::SqDepth  // 8
) (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Allocation (from Dispatch, parallel with MEM_RS dispatch)
    // =========================================================================
    input  riscv_pkg::sq_alloc_req_t i_alloc,
    output logic                     o_full,

    // =========================================================================
    // Early Address Update (from pipelined dispatch-time address computation)
    // =========================================================================
    input riscv_pkg::sq_addr_update_t i_early_addr_update,

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
    output logic                       o_committed_empty,  // No committed entries pending write
    output logic [$clog2(DEPTH+1)-1:0] o_count
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
  logic                  empty;
  logic [CountWidth-1:0] count;

  // Memory write tracking
  logic                  write_outstanding;  // One outstanding write at a time
  logic [  IdxWidth-1:0] write_entry_idx;
  logic                  write_completes_entry;
  logic [      XLEN-1:0] write_invalidate_addr;

  // Head entry readiness
  logic                  head_ready;  // Head entry committed + addr_valid + data_valid

  // Head/tail search targets for the sparse valid-bit queue.
  logic [  PtrWidth-1:0] head_advance_target;
  logic [  PtrWidth-1:0] alloc_target;
  logic                  flush_all_uncommitted;

  // ===========================================================================
  // Count, Full, Empty
  // ===========================================================================
  always_comb begin
    count = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      count = count + CountWidth'(sq_valid[i]);
    end
  end

  assign full = (count == CountWidth'(DEPTH));
  assign empty = (count == CountWidth'(0));

  assign o_full = full;
  assign o_empty = empty;
  assign o_count = count;

  // Committed-empty: no committed-but-unwritten entries
  logic any_committed;
  always_comb begin
    any_committed = 1'b0;
    for (int i = 0; i < DEPTH; i++) if (sq_valid[i] && sq_committed[i]) any_committed = 1'b1;
  end
  assign o_committed_empty = ~any_committed;

  // ===========================================================================
  // Store-to-Load Forwarding (combinational scan)
  // ===========================================================================
  // For each valid SQ entry that is OLDER than the load (check_rob_tag):
  //   1. Check if all older stores have addr_valid (conservative disambiguation)
  //   2. Find newest matching store (scan oldest→newest, last match wins)
  //   3. Determine if forwarding is possible (data_valid + compatible sizes)
  //
  // Forwarding rules (conservative):
  //   - can_forward when: exact address match, same size, WORD or DOUBLE, data_valid
  //   - match (stall) when: accessed byte lanes overlap within a word
  //     (including DOUBLE +4 overlap)
  //   - all_older_addrs_known: all older valid entries have addr_valid

  // Forwarding extract type: which slice of sq_data to forward
  logic [1:0] fwd_extract_type;  // 0=EXACT, 1=LO_WORD, 2=HI_WORD

  // Forwarding scan results — promoted to module scope so the per-entry
  // qualification mask, winner select, and sq_data_fwd_rd consumption stay in
  // separate blocks and avoid UNOPTFLAT circular combinational logic through
  // the LUTRAM.
  logic fwd_all_older_known;
  logic fwd_found_match;
  logic fwd_can_fwd;
  logic [3:0] fwd_load_byte_mask;
  logic [DEPTH-1:0] fwd_addr_unknown_mask;
  logic [DEPTH-1:0] fwd_conflict_mask;
  logic [DEPTH-1:0] fwd_can_forward_mask;
  logic [ReorderBufferTagWidth:0] fwd_load_age;
  logic [ReorderBufferTagWidth:0] fwd_entry_age[DEPTH];
  logic [1:0] fwd_entry_extract_type[DEPTH];

  assign fwd_load_byte_mask = gen_byte_en(i_sq_check_addr[1:0], i_sq_check_size);
  assign fwd_load_age = {1'b0, i_sq_check_rob_tag} - {1'b0, i_rob_head_tag};

  // Block 1: per-entry forwarding qualification from FF-based fields only
  // (no LUTRAM read, no inter-entry "last match wins" dependency).
  // Select older stores by ROB age directly so the forwarding path does not
  // need a head-relative barrel rotation over sq_valid/sq_addr_valid.
  always_comb begin
    logic same_word;
    logic base_match;
    logic double_hi_match;
    logic load_double_hi;
    logic older_store;
    logic store_committed;
    logic [3:0] store_byte_mask;
    logic [3:0] load_byte_mask;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      same_word = 1'b0;
      base_match = 1'b0;
      double_hi_match = 1'b0;
      load_double_hi = 1'b0;
      older_store = 1'b0;
      store_committed = 1'b0;
      store_byte_mask = 4'b0000;
      load_byte_mask = fwd_load_byte_mask;
      fwd_entry_age[i] = {1'b0, sq_rob_tag[i]} - {1'b0, i_rob_head_tag};
      fwd_addr_unknown_mask[i] = 1'b0;
      fwd_conflict_mask[i] = 1'b0;
      fwd_can_forward_mask[i] = 1'b0;
      fwd_entry_extract_type[i] = 2'd0;

      // Stores retire from the ROB before they drain from the SQ.  Keep a
      // store visible to younger-load disambiguation in the cycle its commit
      // arrives so the load cannot slip through the one-cycle sq_committed lag.
      // Widen-commit extends the same guard to slot 2.
      store_committed = sq_committed[i] ||
                        (i_commit_valid && (sq_rob_tag[i] == i_commit_rob_tag)) ||
                        (i_commit_valid_2 && (sq_rob_tag[i] == i_commit_rob_tag_2));
      older_store = sq_valid[i] && (store_committed || (fwd_entry_age[i] < fwd_load_age));

      if (older_store) begin
        // Check if this older store has its address resolved
        if (!sq_addr_valid[i]) begin
          fwd_addr_unknown_mask[i] = 1'b1;
        end

        // Check for address overlap
        if (sq_addr_valid[i]) begin
          same_word = (sq_address[i][XLEN-1:2] == i_sq_check_addr[XLEN-1:2]);
          store_byte_mask = gen_byte_en(sq_address[i][1:0], riscv_pkg::mem_size_e'(sq_size[i]));

          // Non-double accesses only conflict when their byte ranges overlap.
          base_match = same_word && ((sq_size[i] == riscv_pkg::MEM_SIZE_DOUBLE) ||
                       (i_sq_check_size == riscv_pkg::MEM_SIZE_DOUBLE) ||
                       (|(store_byte_mask & load_byte_mask)));

          // DOUBLE store: also overlaps at word addr+4
          double_hi_match =
              (sq_size[i] == riscv_pkg::MEM_SIZE_DOUBLE) &&
              ((sq_address[i][XLEN-1:2] + 30'(1)) == i_sq_check_addr[XLEN-1:2]);

          // DOUBLE load: check if store is at the +4 word
          load_double_hi =
              (i_sq_check_size == riscv_pkg::MEM_SIZE_DOUBLE) &&
              (sq_address[i][XLEN-1:2] == (i_sq_check_addr[XLEN-1:2] + 30'(1)));

          if (base_match || double_hi_match || load_double_hi) begin
            fwd_conflict_mask[i] = 1'b1;

            // Forwarding: only non-MMIO stores with valid data
            if (sq_data_valid[i] && !sq_is_mmio[i]) begin
              // Case 1: exact address, same size, WORD or DOUBLE
              if (base_match &&
                  (sq_address[i] == i_sq_check_addr) &&
                  (sq_size[i] == riscv_pkg::mem_size_e'(i_sq_check_size)) &&
                  (i_sq_check_size >= riscv_pkg::MEM_SIZE_WORD)) begin
                fwd_can_forward_mask[i]   = 1'b1;
                fwd_entry_extract_type[i] = 2'd0;  // EXACT
                // Case 2: FLW at FSD base address → forward low word
              end else if (base_match &&
                  (i_sq_check_size == riscv_pkg::MEM_SIZE_WORD) &&
                  (sq_size[i] == riscv_pkg::MEM_SIZE_DOUBLE)) begin
                fwd_can_forward_mask[i]   = 1'b1;
                fwd_entry_extract_type[i] = 2'd1;  // LO_WORD
                // Case 3: FLW at FSD addr+4 → forward high word
              end else if (double_hi_match && (i_sq_check_size == riscv_pkg::MEM_SIZE_WORD)) begin
                fwd_can_forward_mask[i]   = 1'b1;
                fwd_entry_extract_type[i] = 2'd2;  // HI_WORD
              end
            end
          end
        end
      end
    end
  end

  assign fwd_all_older_known = ~(|fwd_addr_unknown_mask);
  assign fwd_found_match     = |fwd_conflict_mask;

  // Block 2: newest conflicting store wins for data/extract selection. The
  // heavy address/age qualification is already parallelized above, so this
  // block only prioritizes 1-bit match results and their precomputed metadata.
  always_comb begin
    logic have_winner;
    logic [ReorderBufferTagWidth:0] winner_age;

    have_winner      = 1'b0;
    winner_age       = '0;
    fwd_can_fwd      = 1'b0;
    fwd_match_idx    = '0;
    fwd_extract_type = 2'd0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (fwd_conflict_mask[i] && (!have_winner || (fwd_entry_age[i] >= winner_age))) begin
        have_winner      = 1'b1;
        winner_age       = fwd_entry_age[i];
        fwd_can_fwd      = fwd_can_forward_mask[i];
        fwd_match_idx    = IdxWidth'(i);
        fwd_extract_type = fwd_entry_extract_type[i];
      end
    end
  end

  // Block 3: Registered forwarding outputs.
  // Keep the SQ compare/forwarding result behind a register so the LQ sees it
  // one cycle later; this breaks the MEM_RS -> SQ scan -> LQ -> BRAM path.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      o_sq_all_older_addrs_known <= 1'b0;
      o_sq_forward               <= '0;
    end else begin
      o_sq_all_older_addrs_known <= i_sq_check_valid ? fwd_all_older_known : 1'b0;
      o_sq_forward.match         <= i_sq_check_valid ? fwd_found_match : 1'b0;
      o_sq_forward.can_forward   <= i_sq_check_valid ? (fwd_found_match && fwd_can_fwd) : 1'b0;
      case (fwd_extract_type)
        2'd1:    o_sq_forward.data <= {{(FLEN - XLEN) {1'b0}}, sq_data_fwd_rd[31:0]};
        2'd2:    o_sq_forward.data <= {{(FLEN - XLEN) {1'b0}}, sq_data_fwd_rd[63:32]};
        default: o_sq_forward.data <= sq_data_fwd_rd;
      endcase
    end
  end

  // ===========================================================================
  // Memory Write Logic (combinational)
  // ===========================================================================
  // Head entry writes to memory when committed, addr_valid, data_valid.
  // One outstanding write at a time. FSD uses two phases.

  assign head_ready = sq_valid[head_idx] && sq_committed[head_idx] &&
                      sq_addr_valid[head_idx] && sq_data_valid[head_idx] &&
                      !sq_sent[head_idx];

  always_comb begin
    o_mem_write_en      = 1'b0;
    o_mem_write_addr    = '0;
    o_mem_write_data    = '0;
    o_mem_write_byte_en = '0;
    o_mem_write_is_mmio = 1'b0;

    if (head_ready && !write_outstanding) begin
      o_mem_write_en = 1'b1;

      // FSD phase 1: write upper word at addr+4
      if (sq_size[head_idx] == riscv_pkg::MEM_SIZE_DOUBLE && sq_fp64_phase[head_idx]) begin
        o_mem_write_addr = sq_address[head_idx] + 32'd4;
      end else begin
        o_mem_write_addr = sq_address[head_idx];
      end

      o_mem_write_data = gen_write_data(sq_data_head_rd, riscv_pkg::mem_size_e'(sq_size[head_idx]),
                                        sq_fp64_phase[head_idx]);
      o_mem_write_byte_en =
          gen_byte_en(o_mem_write_addr[1:0], riscv_pkg::mem_size_e'(sq_size[head_idx]));
      o_mem_write_is_mmio = sq_is_mmio[head_idx];
    end
  end

  // ===========================================================================
  // L0 Cache Invalidation (on memory write completion)
  // ===========================================================================
  // Invalidate the LQ's L0 cache at the written address when a store
  // completes its memory write. This prevents the LQ from serving stale data.
  assign o_cache_invalidate_valid = i_mem_write_done && write_outstanding;
  assign o_cache_invalidate_addr = write_invalidate_addr;

  // ===========================================================================
  // Allocation Search
  // ===========================================================================
  // Keep sparse holes after partial flush/free and search forward from tail_ptr
  // to find the next invalid slot instead of compacting the tail on flush.
  assign flush_all_uncommitted = i_flush_after_head_commit;
  // Tree-based free-entry search: find first invalid entry starting from
  // tail_ptr using rotate → tree-priority-encode → add-back, replacing
  // the O(DEPTH) serial scan with O(log2(DEPTH)) logic levels.
  logic [DEPTH-1:0] sq_free_mask;
  logic [DEPTH-1:0] sq_free_rotated;
  logic [IdxWidth-1:0] sq_first_free_offset;
  logic sq_first_free_found;

  assign sq_free_mask = ~sq_valid;

  // Barrel-rotate free mask so tail_ptr maps to index 0
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      sq_free_rotated[i] = sq_free_mask[(32'(i)+32'(tail_ptr[IdxWidth-1:0]))%DEPTH];
    end
  end

  // Tree priority encoder: find lowest-index set bit in rotated mask
  always_comb begin
    sq_first_free_offset = '0;
    sq_first_free_found  = 1'b0;
    for (int i = 0; i < DEPTH; i++) begin
      if (sq_free_rotated[i] && !sq_first_free_found) begin
        sq_first_free_offset = IdxWidth'(i);
        sq_first_free_found  = 1'b1;
      end
    end
  end

  // Add offset back to tail_ptr to get absolute alloc target
  assign alloc_target = tail_ptr + PtrWidth'({1'b0, sq_first_free_offset});

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

  // Add offset back to head_ptr (when empty: offset=0, head stays put)
  assign head_advance_target = head_ptr + PtrWidth'({1'b0, sq_head_first_valid_offset});

  // ===========================================================================
  // Sequential Logic
  // ===========================================================================

  // -------------------------------------------------------------------
  // Control-signal always_ff (with reset and flush_all sensitivity)
  // -------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      head_ptr              <= '0;
      tail_ptr              <= '0;
      sq_addr_valid         <= '0;
      sq_data_valid         <= '0;
      sq_committed          <= '0;
      sq_sent               <= '0;
      write_outstanding     <= 1'b0;
      write_entry_idx       <= '0;
      write_completes_entry <= 1'b0;
      write_invalidate_addr <= '0;
    end else if (i_flush_all) begin
      // Full flush: reset control signals
      head_ptr              <= '0;
      tail_ptr              <= '0;
      sq_addr_valid         <= '0;
      sq_data_valid         <= '0;
      sq_committed          <= '0;
      sq_sent               <= '0;
      write_outstanding     <= 1'b0;
      write_entry_idx       <= '0;
      write_completes_entry <= 1'b0;
      write_invalidate_addr <= '0;
    end else begin

      // -----------------------------------------------------------------
      // Allocation: write control signals for new entry at tail
      // -----------------------------------------------------------------
      if (i_alloc.valid && !full) begin
        sq_addr_valid[alloc_target[IdxWidth-1:0]] <= i_alloc.addr_valid;
        sq_data_valid[alloc_target[IdxWidth-1:0]] <= 1'b0;
        sq_committed[alloc_target[IdxWidth-1:0]]  <= 1'b0;
        sq_sent[alloc_target[IdxWidth-1:0]]       <= 1'b0;
        tail_ptr                                  <= alloc_target + PtrWidth'(1);
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
      // Memory Write Initiation
      // -----------------------------------------------------------------
      if (o_mem_write_en) begin
        write_outstanding <= 1'b1;
        write_entry_idx <= head_idx;
        write_completes_entry <= !(sq_size[head_idx] == riscv_pkg::MEM_SIZE_DOUBLE &&
                                   !sq_fp64_phase[head_idx]);
        write_invalidate_addr <= o_mem_write_addr;
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
      head_ptr <= head_advance_target;

    end  // !flush_all
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
              // Guard: don't flush a store the ROB is committing or just committed.
              // sq_committed has a 2-cycle pipeline lag from the ROB's commit_en:
              //   Cycle K:   ROB commit_en → commit_bus (comb)
              //   Cycle K+1: commit_bus_q → i_commit_valid (registered)
              //   Cycle K+2: sq_committed set (from K+1's NBA)
              // A partial flush on K or K+1 would see sq_committed=0. Guard both,
              // and extend the same guard to widen-commit slot 2.
              !(i_commit_valid_comb && sq_rob_tag[i] == i_commit_rob_tag_comb) &&
              !(i_commit_valid_comb_2 && sq_rob_tag[i] == i_commit_rob_tag_comb_2) &&
              !(i_commit_valid && sq_rob_tag[i] == i_commit_rob_tag) &&
              !(i_commit_valid_2 && sq_rob_tag[i] == i_commit_rob_tag_2) &&
              (flush_all_uncommitted || is_younger(
                  sq_rob_tag[i], i_flush_tag, i_rob_head_tag
              ))) begin
            sq_valid[i] <= 1'b0;
          end
        end
        // Leave tail_ptr unchanged. alloc_target will reuse reclaimed holes
        // after the flush instead of compacting the tail in this cycle.
      end

      if (i_alloc.valid && !full) begin
        sq_valid[alloc_target[IdxWidth-1:0]] <= 1'b1;
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
    if (i_alloc.valid && !full) begin
      sq_rob_tag[alloc_target[IdxWidth-1:0]]    <= i_alloc.rob_tag;
      sq_size[alloc_target[IdxWidth-1:0]]       <= i_alloc.size;
      sq_fp64_phase[alloc_target[IdxWidth-1:0]] <= 1'b0;
      sq_is_sc[alloc_target[IdxWidth-1:0]]      <= i_alloc.is_sc;
      sq_address[alloc_target[IdxWidth-1:0]]    <= i_alloc.address;
      sq_is_mmio[alloc_target[IdxWidth-1:0]]    <= i_alloc.is_mmio;
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
      if (i_alloc.valid && (i_flush_all || i_flush_en))
        $warning("SQ: allocation attempted during flush");
    end
  end
`endif

  // Debug: trace SQ drains + flush events (disabled for clean logs)
  // always @(posedge i_clk) begin
  //   if (i_rst_n && o_mem_write_en && o_mem_write_addr[31:16] == 16'h0001)
  //     $display("[SQ_DRAIN] t=%0t addr=%08x data=%08x", $time, o_mem_write_addr, o_mem_write_data);
  //   if (i_rst_n && i_flush_en) begin
  //     for (int i = 0; i < DEPTH; i++) begin
  //       if (sq_valid[i] && !sq_committed[i] &&
  //           !(i_commit_valid_comb && sq_rob_tag[i] == i_commit_rob_tag_comb) &&
  //           !(i_commit_valid      && sq_rob_tag[i] == i_commit_rob_tag) &&
  //           (flush_all_uncommitted || is_younger(sq_rob_tag[i], i_flush_tag, i_rob_head_tag)) &&
  //           sq_addr_valid[i] && sq_address[i][31:16] == 16'h0001)
  //         $display("[SQ_ACTUALLY_FLUSHED] t=%0t idx=%0d tag=%0d addr=%08x flush_tag=%0d head=%0d",
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

  // No allocation during flush
  always_comb begin
    if (i_flush_all || i_flush_en) assume (!i_alloc.valid);
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

  // full and empty are mutually exclusive
  always_comb begin
    if (i_rst_n) begin
      p_full_empty_mutex : assert (!(o_full && o_empty));
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

  // Forwarding only when check is valid
  always_comb begin
    if (i_rst_n && !i_sq_check_valid) begin
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

endmodule
