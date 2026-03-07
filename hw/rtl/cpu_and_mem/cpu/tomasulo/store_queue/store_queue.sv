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
  wire                  [             IdxWidth-1:0] tail_idx = tail_ptr[IdxWidth-1:0];

  // Per-entry 1-bit flags (packed vectors for bulk operations)
  logic                 [                DEPTH-1:0] sq_valid;
  logic                 [                DEPTH-1:0] sq_is_fp;
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

  logic full;
  logic empty;
  logic [CountWidth-1:0] count;

  // Memory write tracking
  logic write_outstanding;  // One outstanding write at a time

  // Head entry readiness
  logic head_ready;  // Head entry committed + addr_valid + data_valid

  // Head advancement target
  logic [PtrWidth-1:0] head_advance_target;

  // ===========================================================================
  // Count, Full, Empty
  // ===========================================================================
  always_comb begin
    count = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      count = count + CountWidth'(sq_valid[i]);
    end
  end

  assign full  = (head_ptr[IdxWidth-1:0] == tail_ptr[IdxWidth-1:0]) &&
                 (head_ptr[PtrWidth-1] != tail_ptr[PtrWidth-1]);
  assign empty = (head_ptr == tail_ptr);

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
  //   - match (stall) when: word-aligned address overlaps (including DOUBLE +4)
  //   - all_older_addrs_known: all older valid entries have addr_valid

  // Pre-computed circular scan indices (head-relative order, oldest first)
  logic [IdxWidth-1:0] scan_idx[DEPTH];
  always_comb begin
    for (int unsigned j = 0; j < DEPTH; j++)
    scan_idx[j] = IdxWidth'(({{(32 - IdxWidth) {1'b0}}, head_idx} + j) % DEPTH);
  end

  // Forwarding extract type: which slice of sq_data to forward
  logic [1:0] fwd_extract_type;  // 0=EXACT, 1=LO_WORD, 2=HI_WORD

  // Forwarding scan results — promoted to module scope so a separate
  // always_comb can consume sq_data_fwd_rd without creating UNOPTFLAT
  // circular combinational logic through the LUTRAM.
  logic fwd_all_older_known;
  logic fwd_found_match;
  logic fwd_can_fwd;

  // Block 1: CAM scan — computes fwd_match_idx, fwd_extract_type, and
  // forwarding status from FF-based fields only (no LUTRAM read).
  always_comb begin
    logic [IdxWidth-1:0] idx;
    logic base_match;
    logic double_hi_match;
    logic load_double_hi;

    fwd_all_older_known = 1'b1;
    fwd_found_match     = 1'b0;
    fwd_can_fwd         = 1'b0;
    fwd_match_idx       = '0;
    fwd_extract_type    = 2'd0;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      idx             = scan_idx[i];
      base_match      = 1'b0;
      double_hi_match = 1'b0;
      load_double_hi  = 1'b0;

      if (sq_valid[idx] && (sq_committed[idx] || is_older_than(
              sq_rob_tag[idx], i_sq_check_rob_tag, i_rob_head_tag
          ))) begin

        // Check if this older store has its address resolved
        if (!sq_addr_valid[idx]) begin
          fwd_all_older_known = 1'b0;
        end

        // Check for address overlap
        if (sq_addr_valid[idx]) begin
          // Word-aligned match: same 32-bit word
          base_match = (sq_address[idx][XLEN-1:2] == i_sq_check_addr[XLEN-1:2]);

          // DOUBLE store: also overlaps at word addr+4
          double_hi_match =
              (sq_size[idx] == riscv_pkg::MEM_SIZE_DOUBLE) &&
              ((sq_address[idx][XLEN-1:2] + 30'(1)) == i_sq_check_addr[XLEN-1:2]);

          // DOUBLE load: check if store is at the +4 word
          load_double_hi =
              (i_sq_check_size == riscv_pkg::MEM_SIZE_DOUBLE) &&
              (sq_address[idx][XLEN-1:2] == (i_sq_check_addr[XLEN-1:2] + 30'(1)));

          if (base_match || double_hi_match || load_double_hi) begin
            // Address conflict detected (newest match overwrites older)
            fwd_found_match = 1'b1;
            fwd_match_idx   = idx;

            // Forwarding: only non-MMIO stores with valid data
            if (sq_data_valid[idx] && !sq_is_mmio[idx]) begin
              // Case 1: exact address, same size, WORD or DOUBLE
              if (base_match &&
                  (sq_address[idx] == i_sq_check_addr) &&
                  (sq_size[idx] == riscv_pkg::mem_size_e'(i_sq_check_size)) &&
                  (i_sq_check_size >= riscv_pkg::MEM_SIZE_WORD)) begin
                fwd_can_fwd      = 1'b1;
                fwd_extract_type = 2'd0;  // EXACT
                // Case 2: FLW at FSD base address → forward low word
              end else if (base_match &&
                  (i_sq_check_size == riscv_pkg::MEM_SIZE_WORD) &&
                  (sq_size[idx] == riscv_pkg::MEM_SIZE_DOUBLE)) begin
                fwd_can_fwd      = 1'b1;
                fwd_extract_type = 2'd1;  // LO_WORD
                // Case 3: FLW at FSD addr+4 → forward high word
              end else if (double_hi_match && (i_sq_check_size == riscv_pkg::MEM_SIZE_WORD)) begin
                fwd_can_fwd      = 1'b1;
                fwd_extract_type = 2'd2;  // HI_WORD
              end else begin
                // Match but can't forward — load must wait
                fwd_can_fwd = 1'b0;
              end
            end else begin
              // MMIO or no data — load must wait
              fwd_can_fwd = 1'b0;
            end
          end
        end
      end
    end
  end

  // Block 2: Drive forwarding outputs using LUTRAM data at fwd_match_idx.
  // Separated so Verilator does not see a circular dependency through the
  // async LUTRAM read (fwd_match_idx → sq_data_fwd_rd → output).
  always_comb begin
    o_sq_all_older_addrs_known = i_sq_check_valid ? fwd_all_older_known : 1'b1;
    o_sq_forward.match         = i_sq_check_valid ? fwd_found_match : 1'b0;
    o_sq_forward.can_forward   = i_sq_check_valid ? (fwd_found_match && fwd_can_fwd) : 1'b0;
    case (fwd_extract_type)
      2'd1:    o_sq_forward.data = {{(FLEN - XLEN) {1'b0}}, sq_data_fwd_rd[31:0]};
      2'd2:    o_sq_forward.data = {{(FLEN - XLEN) {1'b0}}, sq_data_fwd_rd[63:32]};
      default: o_sq_forward.data = sq_data_fwd_rd;
    endcase
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
    end
  end

  // ===========================================================================
  // L0 Cache Invalidation (on memory write completion)
  // ===========================================================================
  // Invalidate the LQ's L0 cache at the written address when a store
  // completes its memory write. This prevents the LQ from serving stale data.
  assign o_cache_invalidate_valid = i_mem_write_done && write_outstanding;
  assign o_cache_invalidate_addr  =
      (sq_size[head_idx] == riscv_pkg::MEM_SIZE_DOUBLE && sq_fp64_phase[head_idx])
          ? (sq_address[head_idx] + 32'd4)
          : sq_address[head_idx];

  // ===========================================================================
  // Tail Retraction (combinational scan for partial flush)
  // ===========================================================================
  // After partial flush, retract tail backwards past consecutive invalid
  // entries at the tail end so that pointer-based full is accurate.

  // Pre-compute post-flush validity per entry:
  logic [DEPTH-1:0] post_flush_valid;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      post_flush_valid[i] = sq_valid[i] && !(
          i_flush_en && !sq_committed[i] && is_younger(sq_rob_tag[i], i_flush_tag, i_rob_head_tag));
    end
  end

  logic [PtrWidth-1:0] flush_tail_target;

  always_comb begin
    flush_tail_target = tail_ptr;
    for (int s = 0; s < DEPTH; s++) begin
      if (flush_tail_target != head_ptr
          && !post_flush_valid[flush_tail_target[IdxWidth-1:0] - IdxWidth'(1)])
        flush_tail_target = flush_tail_target - PtrWidth'(1);
    end
  end

  // ===========================================================================
  // Head Advancement (combinational scan past contiguous freed entries)
  // ===========================================================================
  // Advance head past all freed (sent && !valid) entries.

  always_comb begin
    head_advance_target = head_ptr;
    for (int unsigned s = 0; s < DEPTH; s++) begin
      if (head_advance_target != tail_ptr && !sq_valid[head_advance_target[IdxWidth-1:0]])
        head_advance_target = head_advance_target + PtrWidth'(1);
    end
  end

  // ===========================================================================
  // Sequential Logic
  // ===========================================================================

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      head_ptr          <= '0;
      tail_ptr          <= '0;
      sq_valid          <= '0;
      sq_is_fp          <= '0;
      sq_addr_valid     <= '0;
      sq_data_valid     <= '0;
      sq_is_mmio        <= '0;
      sq_fp64_phase     <= '0;
      sq_committed      <= '0;
      sq_sent           <= '0;
      sq_is_sc          <= '0;
      write_outstanding <= 1'b0;
    end else if (i_flush_all) begin
      // Full flush: reset everything
      head_ptr          <= '0;
      tail_ptr          <= '0;
      sq_valid          <= '0;
      sq_is_fp          <= '0;
      sq_addr_valid     <= '0;
      sq_data_valid     <= '0;
      sq_is_mmio        <= '0;
      sq_fp64_phase     <= '0;
      sq_committed      <= '0;
      sq_sent           <= '0;
      sq_is_sc          <= '0;
      write_outstanding <= 1'b0;
    end else begin

      // -----------------------------------------------------------------
      // Partial flush: invalidate UNCOMMITTED entries younger than flush_tag
      // Committed entries are never flushed (they must complete to memory).
      // -----------------------------------------------------------------
      if (i_flush_en) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (sq_valid[i] && !sq_committed[i] && is_younger(
                  sq_rob_tag[i], i_flush_tag, i_rob_head_tag
              )) begin
            sq_valid[i] <= 1'b0;
          end
        end
        // Retract tail
        tail_ptr <= flush_tail_target;
      end

      // -----------------------------------------------------------------
      // Allocation: write new entry at tail
      // -----------------------------------------------------------------
      if (i_alloc.valid && !full) begin
        sq_valid[tail_idx]      <= 1'b1;
        sq_rob_tag[tail_idx]    <= i_alloc.rob_tag;
        sq_is_fp[tail_idx]      <= i_alloc.is_fp;
        sq_addr_valid[tail_idx] <= 1'b0;
        sq_address[tail_idx]    <= '0;
        sq_data_valid[tail_idx] <= 1'b0;
        sq_size[tail_idx]       <= i_alloc.size;
        sq_is_mmio[tail_idx]    <= 1'b0;
        sq_fp64_phase[tail_idx] <= 1'b0;
        sq_committed[tail_idx]  <= 1'b0;
        sq_sent[tail_idx]       <= 1'b0;
        sq_is_sc[tail_idx]      <= i_alloc.is_sc;
        tail_ptr                <= tail_ptr + PtrWidth'(1);
      end

      // -----------------------------------------------------------------
      // Address Update: CAM search for matching rob_tag
      // -----------------------------------------------------------------
      if (i_addr_update.valid) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (sq_valid[i] && !sq_addr_valid[i] && sq_rob_tag[i] == i_addr_update.rob_tag) begin
            sq_addr_valid[i] <= 1'b1;
            sq_address[i]    <= i_addr_update.address;
            sq_is_mmio[i]    <= i_addr_update.is_mmio;
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

      // -----------------------------------------------------------------
      // SC Discard: failed SC invalidates its uncommitted SQ entry
      // -----------------------------------------------------------------
      if (i_sc_discard) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (sq_valid[i] && sq_is_sc[i] && !sq_committed[i]
              && sq_rob_tag[i] == i_sc_discard_rob_tag) begin
            sq_valid[i] <= 1'b0;
          end
        end
      end

      // -----------------------------------------------------------------
      // Memory Write Initiation
      // -----------------------------------------------------------------
      if (o_mem_write_en) begin
        write_outstanding <= 1'b1;
      end

      // -----------------------------------------------------------------
      // Memory Write Completion
      // -----------------------------------------------------------------
      if (i_mem_write_done && write_outstanding) begin
        if (sq_size[head_idx] == riscv_pkg::MEM_SIZE_DOUBLE && !sq_fp64_phase[head_idx]) begin
          // FSD phase 0 complete: advance to phase 1, allow next write
          sq_fp64_phase[head_idx] <= 1'b1;
          write_outstanding       <= 1'b0;
        end else begin
          // Single-phase complete or FSD phase 1 complete: free entry
          sq_valid[head_idx] <= 1'b0;
          sq_sent[head_idx]  <= 1'b1;
          write_outstanding  <= 1'b0;
        end
      end

      // -----------------------------------------------------------------
      // Head Advancement
      // -----------------------------------------------------------------
      head_ptr <= head_advance_target;

    end  // !flush_all
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

  // No address/data update during flush
  always_comb begin
    if (i_flush_all || i_flush_en) assume (!i_addr_update.valid);
    if (i_flush_all || i_flush_en) assume (!i_data_update.valid);
  end

  // No allocation when full
  always_comb begin
    if (full) assume (!i_alloc.valid);
  end

  // Memory write done only when outstanding
  always_comb begin
    assume (!i_mem_write_done || write_outstanding);
  end

  // No commit during flush
  always_comb begin
    if (i_flush_all || i_flush_en) assume (!i_commit_valid);
  end

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

  // If all entries are valid, must be pointer-full
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
        p_alloc_advances_tail : assert (sq_valid[$past(tail_idx)]);
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
