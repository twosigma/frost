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
 * Load Queue - Tracks in-flight load instructions
 *
 * Circular buffer of DEPTH entries (8), allocated in program order at
 * dispatch time, freed when the load result is broadcast on the CDB.
 *
 * Features:
 *   - Parameterized depth (8 entries, FF-based)
 *   - CAM-style tag search for address update (all entries in parallel)
 *   - Oldest-first priority scan for issue selection
 *   - Two-phase FLD support (64-bit double on 32-bit bus)
 *   - Store-to-load forwarding via SQ disambiguation interface
 *   - MMIO loads execute only at ROB head (non-speculative)
 *   - Partial flush (age-based) and full flush support
 *   - CDB back-pressure via i_adapter_result_pending
 *
 * Storage Strategy:
 *   All fields in FFs (not LUTRAM/BRAM). 8 entries at 116 bits each
 *   (~928 bits total) is trivial for FFs. The LQ requires CAM-style
 *   parallel tag search for address update, per-entry invalidation for
 *   partial flush, and parallel read for oldest-first priority scan --
 *   none of which are supported by RAM primitives.
 *
 * Internal load_unit instance:
 *   Byte/halfword extraction and sign extension for LB/LBU/LH/LHU.
 *   Driven by completing entry's size flags and raw memory data.
 */

module load_queue #(
    parameter int unsigned DEPTH = riscv_pkg::LqDepth  // 8
) (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Allocation (from Dispatch, parallel with MEM_RS dispatch)
    // =========================================================================
    input  riscv_pkg::lq_alloc_req_t i_alloc,
    output logic                     o_full,

    // =========================================================================
    // Address Update (from MEM_RS issue path: base + imm, pre-computed)
    // =========================================================================
    input riscv_pkg::lq_addr_update_t i_addr_update,

    // =========================================================================
    // Store Queue Disambiguation (combinational handshake)
    // =========================================================================
    output logic o_sq_check_valid,
    output logic [riscv_pkg::XLEN-1:0] o_sq_check_addr,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_sq_check_rob_tag,
    output riscv_pkg::mem_size_e o_sq_check_size,
    input logic i_sq_all_older_addrs_known,
    input riscv_pkg::sq_forward_result_t i_sq_forward,

    // =========================================================================
    // Memory Interface (to data memory bus)
    // =========================================================================
    output logic                                       o_mem_read_en,
    output logic                 [riscv_pkg::XLEN-1:0] o_mem_read_addr,
    output riscv_pkg::mem_size_e                       o_mem_read_size,
    input  logic                 [riscv_pkg::XLEN-1:0] i_mem_read_data,
    input  logic                                       i_mem_read_valid,

    // =========================================================================
    // CDB Result (to fu_cdb_adapter, FU_MEM slot)
    // =========================================================================
    output riscv_pkg::fu_complete_t o_fu_complete,
    input  logic                    i_adapter_result_pending, // back-pressure

    // =========================================================================
    // ROB Head Tag (MMIO: must be at head to issue)
    // =========================================================================
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,

    // =========================================================================
    // Flush
    // =========================================================================
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic                                        i_flush_all,

    // =========================================================================
    // Status
    // =========================================================================
    output logic                       o_empty,
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

  // ===========================================================================
  // Storage -- Circular buffer with FF-based arrays
  // ===========================================================================

  // Head and tail pointers (extra MSB for full/empty distinction)
  logic [PtrWidth-1:0] head_ptr;
  logic [PtrWidth-1:0] tail_ptr;

  // Index extraction (lower bits)
  wire [IdxWidth-1:0] head_idx = head_ptr[IdxWidth-1:0];
  wire [IdxWidth-1:0] tail_idx = tail_ptr[IdxWidth-1:0];

  // Per-entry 1-bit flags (packed vectors for bulk operations)
  logic [DEPTH-1:0] lq_valid;
  logic [DEPTH-1:0] lq_is_fp;
  logic [DEPTH-1:0] lq_addr_valid;
  logic [DEPTH-1:0] lq_sign_ext;
  logic [DEPTH-1:0] lq_is_mmio;
  logic [DEPTH-1:0] lq_fp64_phase;
  logic [DEPTH-1:0] lq_issued;
  logic [DEPTH-1:0] lq_data_valid;
  logic [DEPTH-1:0] lq_forwarded;

  // Per-entry multi-bit fields
  logic [ReorderBufferTagWidth-1:0] lq_rob_tag[DEPTH];
  logic [XLEN-1:0] lq_address[DEPTH];
  riscv_pkg::mem_size_e lq_size[DEPTH];
  logic [FLEN-1:0] lq_data[DEPTH];

  // ===========================================================================
  // Internal Signals
  // ===========================================================================

  logic full;
  logic empty;
  logic [CountWidth-1:0] count;

  // Issue selection
  logic issue_cdb_found;  // Phase A: entry with data_valid
  logic [IdxWidth-1:0] issue_cdb_idx;
  logic issue_mem_found;  // Phase B: entry ready for memory
  logic [IdxWidth-1:0] issue_mem_idx;

  // Memory issued entry tracking
  logic mem_outstanding;  // One outstanding read at a time
  logic [IdxWidth-1:0] issued_idx;  // Which entry is awaiting mem response

  // Load unit wires
  logic [XLEN-1:0] lu_data_out;

  // Entry freeing
  logic free_entry_en;
  logic [IdxWidth-1:0] free_entry_idx;

  // Head advancement target (scans past all contiguous invalid entries)
  logic [PtrWidth-1:0] head_advance_target;

  // ===========================================================================
  // Count, Full, Empty
  // ===========================================================================
  // Count valid entries (not pointer distance, since partial flush can
  // invalidate entries in the middle of the buffer)
  always_comb begin
    count = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      count = count + CountWidth'(lq_valid[i]);
    end
  end

  assign full  = (head_ptr[IdxWidth-1:0] == tail_ptr[IdxWidth-1:0]) &&
                 (head_ptr[PtrWidth-1] != tail_ptr[PtrWidth-1]);
  assign empty = (head_ptr == tail_ptr);

  assign o_full = full;
  assign o_empty = empty;
  assign o_count = count;

  // ===========================================================================
  // Issue Selection (combinational priority scan, head to tail)
  // ===========================================================================
  //
  // Phase A: Oldest entry with data_valid (ready for CDB broadcast).
  //          FLD: both phases must be complete (data_valid=1).
  // Phase B: Oldest entry with addr_valid && !issued && !data_valid,
  //          ready for SQ disambiguation and potential memory issue.

  // Pre-computed circular scan indices (head-relative order)
  logic [IdxWidth-1:0] scan_idx[DEPTH];
  always_comb begin
    for (int unsigned j = 0; j < DEPTH; j++)
    scan_idx[j] = IdxWidth'(({{(32 - IdxWidth) {1'b0}}, head_idx} + j) % DEPTH);
  end

  always_comb begin
    issue_cdb_found = 1'b0;
    issue_cdb_idx   = '0;
    issue_mem_found = 1'b0;
    issue_mem_idx   = '0;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      // Walk from head toward tail in circular order
      if (lq_valid[scan_idx[i]]) begin
        // Phase A: CDB broadcast candidate
        if (!issue_cdb_found && lq_data_valid[scan_idx[i]]) begin
          issue_cdb_found = 1'b1;
          issue_cdb_idx   = scan_idx[i];
        end
        // Phase B: Memory issue candidate
        if (!issue_mem_found && lq_addr_valid[scan_idx[i]]
            && !lq_issued[scan_idx[i]]
            && !lq_data_valid[scan_idx[i]]) begin
          issue_mem_found = 1'b1;
          issue_mem_idx   = scan_idx[i];
        end
      end
    end
  end

  // ===========================================================================
  // SQ Disambiguation Interface (combinational)
  // ===========================================================================
  // For Phase B candidate: drive SQ check ports

  always_comb begin
    o_sq_check_valid   = 1'b0;
    o_sq_check_addr    = '0;
    o_sq_check_rob_tag = '0;
    o_sq_check_size    = riscv_pkg::MEM_SIZE_WORD;

    if (issue_mem_found && !mem_outstanding) begin
      // MMIO check: only issue if at ROB head
      if (!lq_is_mmio[issue_mem_idx] || (lq_rob_tag[issue_mem_idx] == i_rob_head_tag)) begin
        o_sq_check_valid   = 1'b1;
        o_sq_check_addr    = lq_address[issue_mem_idx];
        o_sq_check_rob_tag = lq_rob_tag[issue_mem_idx];
        o_sq_check_size    = riscv_pkg::mem_size_e'(lq_size[issue_mem_idx]);
      end
    end
  end

  // ===========================================================================
  // Memory Issue Logic (combinational)
  // ===========================================================================
  // Issue to memory when:
  //   - SQ check is active
  //   - SQ says all older addresses are known
  //   - SQ says no match (or match but can't forward)
  //   - If SQ can forward, skip memory and write forwarded data instead

  logic sq_can_issue;
  logic sq_do_forward;

  assign sq_can_issue  = o_sq_check_valid && i_sq_all_older_addrs_known && !i_sq_forward.match;
  assign sq_do_forward = o_sq_check_valid && i_sq_forward.can_forward;

  always_comb begin
    o_mem_read_en   = 1'b0;
    o_mem_read_addr = '0;
    o_mem_read_size = riscv_pkg::MEM_SIZE_WORD;

    if (sq_can_issue) begin
      o_mem_read_en = 1'b1;
      // FLD phase 1: read address+4 for upper word
      if (lq_is_fp[issue_mem_idx] && lq_size[issue_mem_idx] == riscv_pkg::MEM_SIZE_DOUBLE
          && lq_fp64_phase[issue_mem_idx]) begin
        o_mem_read_addr = lq_address[issue_mem_idx] + 32'd4;
      end else begin
        o_mem_read_addr = lq_address[issue_mem_idx];
      end
      o_mem_read_size = riscv_pkg::mem_size_e'(lq_size[issue_mem_idx]);
    end
  end

  // ===========================================================================
  // Load Unit Instance (byte/halfword extraction + sign extension)
  // ===========================================================================
  // Driven by the entry that is receiving memory response data.

  logic lu_is_byte;
  logic lu_is_half;
  logic lu_is_unsigned;
  logic [XLEN-1:0] lu_addr;
  logic [XLEN-1:0] lu_raw_data;

  load_unit u_load_unit (
      .i_is_load_byte           (lu_is_byte),
      .i_is_load_halfword       (lu_is_half),
      .i_is_load_unsigned       (lu_is_unsigned),
      .i_data_memory_address    (lu_addr),
      .i_data_memory_read_data  (lu_raw_data),
      .o_data_loaded_from_memory(lu_data_out)
  );

  // Drive load unit inputs from the entry awaiting response
  always_comb begin
    lu_is_byte     = 1'b0;
    lu_is_half     = 1'b0;
    lu_is_unsigned = 1'b0;
    lu_addr        = '0;
    lu_raw_data    = i_mem_read_data;

    if (i_mem_read_valid && mem_outstanding) begin
      lu_is_byte     = (lq_size[issued_idx] == riscv_pkg::MEM_SIZE_BYTE);
      lu_is_half     = (lq_size[issued_idx] == riscv_pkg::MEM_SIZE_HALF);
      lu_is_unsigned = !lq_sign_ext[issued_idx];
      lu_addr        = lq_address[issued_idx];
    end
  end

  // ===========================================================================
  // CDB Broadcast Logic (combinational)
  // ===========================================================================
  // Phase A candidate broadcasts to CDB when not back-pressured.

  always_comb begin
    o_fu_complete.valid     = 1'b0;
    o_fu_complete.tag       = '0;
    o_fu_complete.value     = '0;
    o_fu_complete.exception = 1'b0;
    o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'(0);
    o_fu_complete.fp_flags  = '0;

    if (issue_cdb_found && !i_adapter_result_pending) begin
      o_fu_complete.valid = 1'b1;
      o_fu_complete.tag   = lq_rob_tag[issue_cdb_idx];

      if (lq_is_fp[issue_cdb_idx]) begin
        if (lq_size[issue_cdb_idx] == riscv_pkg::MEM_SIZE_DOUBLE) begin
          // FLD: raw 64-bit data
          o_fu_complete.value = lq_data[issue_cdb_idx];
        end else begin
          // FLW: NaN-box 32-bit to 64-bit
          o_fu_complete.value = {32'hFFFF_FFFF, lq_data[issue_cdb_idx][31:0]};
        end
      end else begin
        // INT load: zero-extend XLEN to FLEN
        o_fu_complete.value = {{(FLEN - XLEN) {1'b0}}, lq_data[issue_cdb_idx][XLEN-1:0]};
      end
    end
  end

  // Entry freeing: when CDB is presenting a valid result (will be captured by adapter)
  assign free_entry_en  = o_fu_complete.valid;
  assign free_entry_idx = issue_cdb_idx;

  // ===========================================================================
  // Head Advancement (combinational scan past contiguous invalid entries)
  // ===========================================================================
  // Advance head past all invalid entries (including one being freed this cycle).
  // At DEPTH=8 this is a trivial combinational chain.

  always_comb begin
    head_advance_target = head_ptr;
    for (int unsigned s = 0; s < DEPTH; s++) begin
      // Entry is effectively invalid if currently invalid OR being freed this cycle
      if (head_advance_target != tail_ptr &&
          !(lq_valid[head_advance_target[IdxWidth-1:0]] &&
            !(free_entry_en && (free_entry_idx == head_advance_target[IdxWidth-1:0]))))
        head_advance_target = head_advance_target + PtrWidth'(1);
    end
  end

  // ===========================================================================
  // Sequential Logic
  // ===========================================================================

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      head_ptr        <= '0;
      tail_ptr        <= '0;
      lq_valid        <= '0;
      lq_is_fp        <= '0;
      lq_addr_valid   <= '0;
      lq_sign_ext     <= '0;
      lq_is_mmio      <= '0;
      lq_fp64_phase   <= '0;
      lq_issued       <= '0;
      lq_data_valid   <= '0;
      lq_forwarded    <= '0;
      mem_outstanding <= 1'b0;
      issued_idx      <= '0;
    end else if (i_flush_all) begin
      // Full flush: reset everything
      head_ptr        <= '0;
      tail_ptr        <= '0;
      lq_valid        <= '0;
      lq_is_fp        <= '0;
      lq_addr_valid   <= '0;
      lq_sign_ext     <= '0;
      lq_is_mmio      <= '0;
      lq_fp64_phase   <= '0;
      lq_issued       <= '0;
      lq_data_valid   <= '0;
      lq_forwarded    <= '0;
      mem_outstanding <= 1'b0;
      issued_idx      <= '0;
    end else begin

      // -----------------------------------------------------------------
      // Partial flush: invalidate entries younger than flush_tag
      // -----------------------------------------------------------------
      if (i_flush_en) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (lq_valid[i] && is_younger(lq_rob_tag[i], i_flush_tag, i_rob_head_tag)) begin
            lq_valid[i] <= 1'b0;
          end
        end
        // If outstanding memory read belongs to a flushed entry, cancel it
        if (mem_outstanding && lq_valid[issued_idx] && is_younger(
                lq_rob_tag[issued_idx], i_flush_tag, i_rob_head_tag
            )) begin
          mem_outstanding <= 1'b0;
        end
        // Retract tail to remove flushed tail entries
        // (simplified: just invalidate, head advancement handles gaps)
      end

      // -----------------------------------------------------------------
      // Allocation: write new entry at tail
      // -----------------------------------------------------------------
      if (i_alloc.valid && !full) begin
        lq_valid[tail_idx]      <= 1'b1;
        lq_rob_tag[tail_idx]    <= i_alloc.rob_tag;
        lq_is_fp[tail_idx]      <= i_alloc.is_fp;
        lq_addr_valid[tail_idx] <= 1'b0;
        lq_address[tail_idx]    <= '0;
        lq_size[tail_idx]       <= i_alloc.size;
        lq_sign_ext[tail_idx]   <= i_alloc.sign_ext;
        lq_is_mmio[tail_idx]    <= 1'b0;
        lq_fp64_phase[tail_idx] <= 1'b0;
        lq_issued[tail_idx]     <= 1'b0;
        lq_data_valid[tail_idx] <= 1'b0;
        lq_data[tail_idx]       <= '0;
        lq_forwarded[tail_idx]  <= 1'b0;
        tail_ptr                <= tail_ptr + PtrWidth'(1);
      end

      // -----------------------------------------------------------------
      // Address Update: CAM search for matching rob_tag
      // -----------------------------------------------------------------
      if (i_addr_update.valid) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (lq_valid[i] && !lq_addr_valid[i] && lq_rob_tag[i] == i_addr_update.rob_tag) begin
            lq_addr_valid[i] <= 1'b1;
            lq_address[i]    <= i_addr_update.address;
            lq_is_mmio[i]    <= i_addr_update.is_mmio;
          end
        end
      end

      // -----------------------------------------------------------------
      // Store forwarding: write data directly, skip memory
      // -----------------------------------------------------------------
      if (sq_do_forward) begin
        lq_data_valid[issue_mem_idx] <= 1'b1;
        lq_forwarded[issue_mem_idx]  <= 1'b1;
        // Store forwarded data (already extracted by SQ)
        lq_data[issue_mem_idx]       <= i_sq_forward.data;
      end

      // -----------------------------------------------------------------
      // Memory Issue: mark entry as issued, track for response routing
      // -----------------------------------------------------------------
      if (o_mem_read_en) begin
        lq_issued[issue_mem_idx] <= 1'b1;
        mem_outstanding          <= 1'b1;
        issued_idx               <= issue_mem_idx;
      end

      // -----------------------------------------------------------------
      // Memory Response: capture data from memory bus
      // -----------------------------------------------------------------
      if (i_mem_read_valid && mem_outstanding) begin
        if (lq_is_fp[issued_idx] &&
            lq_size[issued_idx] == riscv_pkg::MEM_SIZE_DOUBLE &&
            !lq_fp64_phase[issued_idx]) begin
          // FLD phase 0: store low word, reset issued, advance to phase 1
          lq_data[issued_idx][31:0] <= lu_data_out;
          lq_fp64_phase[issued_idx] <= 1'b1;
          lq_issued[issued_idx]     <= 1'b0;  // Re-issue for phase 1
          mem_outstanding           <= 1'b0;
        end else if (lq_is_fp[issued_idx] &&
                     lq_size[issued_idx] == riscv_pkg::MEM_SIZE_DOUBLE &&
                     lq_fp64_phase[issued_idx]) begin
          // FLD phase 1: store high word, mark data valid
          lq_data[issued_idx][63:32] <= i_mem_read_data;
          lq_data_valid[issued_idx]  <= 1'b1;
          mem_outstanding            <= 1'b0;
        end else begin
          // Non-FLD: single-phase, run through load unit
          lq_data[issued_idx][XLEN-1:0] <= lu_data_out;
          if (FLEN > XLEN) begin
            lq_data[issued_idx][FLEN-1:XLEN] <= '0;
          end
          lq_data_valid[issued_idx] <= 1'b1;
          mem_outstanding           <= 1'b0;
        end
      end

      // -----------------------------------------------------------------
      // Entry Freeing + Head Advancement
      // -----------------------------------------------------------------
      if (free_entry_en) begin
        lq_valid[free_entry_idx] <= 1'b0;
      end

      // Advance head past all contiguous invalid entries (including freed)
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
      if (i_alloc.valid && full) $warning("LQ: allocation attempted when full");
      if (i_alloc.valid && (i_flush_all || i_flush_en))
        $warning("LQ: allocation attempted during flush");
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

  // No address update during flush
  always_comb begin
    if (i_flush_all || i_flush_en) assume (!i_addr_update.valid);
  end

  // No allocation when full
  always_comb begin
    if (full) assume (!i_alloc.valid);
  end

  // i_mem_read_valid only asserts when we have an outstanding read
  always_comb begin
    assume (!i_mem_read_valid || mem_outstanding);
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

  // count consistent with pointer difference
  logic [CountWidth-1:0] f_valid_count;
  always_comb begin
    f_valid_count = '0;
    for (int i = 0; i < DEPTH; i++) begin
      f_valid_count = f_valid_count + {{(CountWidth - 1) {1'b0}}, lq_valid[i]};
    end
  end

  always_comb begin
    if (i_rst_n) begin
      p_count_consistent : assert (o_count == f_valid_count);
    end
  end

  // If all entries are valid, the buffer must be pointer-full.
  // Note: o_full (pointer-based) can be true with f_valid_count < DEPTH
  // after partial flush, since head advancement happens on the next posedge.
  always_comb begin
    if (i_rst_n) begin
      p_all_valid_implies_full : assert (f_valid_count < CountWidth'(DEPTH) || o_full);
    end
  end

  // No memory issue without addr_valid
  always_comb begin
    if (i_rst_n && o_mem_read_en) begin
      p_no_mem_issue_without_addr : assert (lq_addr_valid[issue_mem_idx]);
    end
  end

  // No memory issue for already-issued entries
  always_comb begin
    if (i_rst_n && o_mem_read_en) begin
      p_no_mem_issue_when_issued : assert (!lq_issued[issue_mem_idx]);
    end
  end

  // MMIO entries only issue when rob_tag == i_rob_head_tag
  always_comb begin
    if (i_rst_n && o_sq_check_valid && lq_is_mmio[issue_mem_idx]) begin
      p_mmio_only_at_head : assert (lq_rob_tag[issue_mem_idx] == i_rob_head_tag);
    end
  end

  // SQ check valid implies valid address on check ports
  always_comb begin
    if (i_rst_n && o_sq_check_valid) begin
      p_sq_check_valid_has_addr : assert (lq_addr_valid[issue_mem_idx]);
    end
  end

  // fu_complete tag matches a valid entry's rob_tag
  always_comb begin
    if (i_rst_n && o_fu_complete.valid) begin
      p_fu_complete_tag_matches : assert (o_fu_complete.tag == lq_rob_tag[issue_cdb_idx]);
    end
  end

  // fu_complete valid only when entry has data_valid
  always_comb begin
    if (i_rst_n && o_fu_complete.valid) begin
      p_fu_complete_needs_data : assert (lq_data_valid[issue_cdb_idx]);
    end
  end

  // CDB back-pressure: fu_complete deasserted when adapter pending
  always_comb begin
    if (i_rst_n && i_adapter_result_pending) begin
      p_cdb_backpressure : assert (!o_fu_complete.valid);
    end
  end

  // No tail advance when full (allocation blocked)
  always_comb begin
    if (full) begin
      p_no_alloc_when_full : assert (!i_alloc.valid);
    end
  end

  // -------------------------------------------------------------------------
  // Sequential assertions
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin

      // Allocation advances tail (count increments)
      if ($past(i_alloc.valid) && !$past(full) && !$past(i_flush_all) && !$past(i_flush_en)) begin
        p_alloc_advances_tail : assert (lq_valid[$past(tail_idx)]);
      end

      // flush_all empties LQ
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
      cover_mem_issue : cover (o_mem_read_en);
      cover_cdb_broadcast : cover (o_fu_complete.valid);
      cover_sq_forward : cover (sq_do_forward);
      cover_full : cover (full);
      cover_flush_nonempty : cover (i_flush_en && |lq_valid);
    end
  end

`endif  // FORMAL

endmodule
