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
 *   Hybrid FF + LUTRAM.  Control / scan fields (valid, addr_valid,
 *   data_valid, issued, is_lr, is_amo, rob_tag, address, size, etc.)
 *   remain in FFs for CAM-style parallel tag search, per-entry
 *   invalidation, and oldest-first priority scan.
 *   lq_data (load result payload) lives in distributed RAM
 *   (mwp_dist_ram, split lo/hi for FLD partial writes, 2 write ports
 *   for primary + AMO overlap).  Valid bits in FFs gate all reads;
 *   stale LUTRAM data behind flushed entries is harmless.
 *
 * Internal load_unit instance:
 *   Byte/halfword extraction and sign extension for LB/LBU/LH/LHU.
 *   Driven by completing entry's size flags and raw memory data.
 */

module load_queue #(
    parameter int unsigned DEPTH = riscv_pkg::LqDepth,  // 8
    parameter bit ENABLE_L0_FAST_PATH = 1'b0,
    parameter bit ENABLE_SQ_FORWARD_FAST_PATH = 1'b0
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
    input  logic                                       i_mem_bus_busy,

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
    // Reservation Register (LR/SC support)
    // =========================================================================
    output logic                       o_reservation_valid,
    output logic [riscv_pkg::XLEN-1:0] o_reservation_addr,
    input  logic                       i_sc_clear_reservation,
    input  logic                       i_reservation_snoop_invalidate,

    // =========================================================================
    // SQ Committed-Empty (for LR/AMO issue gating)
    // =========================================================================
    input logic i_sq_committed_empty,

    // =========================================================================
    // AMO Memory Write Interface
    // =========================================================================
    output logic                       o_amo_mem_write_en,
    output logic [riscv_pkg::XLEN-1:0] o_amo_mem_write_addr,
    output logic [riscv_pkg::XLEN-1:0] o_amo_mem_write_data,
    input  logic                       i_amo_mem_write_done,

    // =========================================================================
    // Flush
    // =========================================================================
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic                                        i_flush_all,

    // =========================================================================
    // L0 Cache Invalidation (from SQ, future)
    // =========================================================================
    input logic                       i_cache_invalidate_valid,
    input logic [riscv_pkg::XLEN-1:0] i_cache_invalidate_addr,

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
  logic [DEPTH-1:0] lq_is_lr;
  logic [DEPTH-1:0] lq_is_amo;

  // Per-entry multi-bit fields
  logic [ReorderBufferTagWidth-1:0] lq_rob_tag[DEPTH];
  logic [XLEN-1:0] lq_address[DEPTH];
  riscv_pkg::mem_size_e lq_size[DEPTH];
  riscv_pkg::instr_op_e lq_amo_op[DEPTH];
  logic [XLEN-1:0] lq_amo_rs2[DEPTH];

  // Reservation register (LR/SC)
  logic reservation_valid;
  logic [XLEN-1:0] reservation_addr;
  assign o_reservation_valid = reservation_valid;
  assign o_reservation_addr  = reservation_addr;

  // AMO FSM
  typedef enum logic {
    AMO_IDLE,
    AMO_WRITE_ACTIVE
  } amo_state_e;
  amo_state_e                              amo_state;
  logic       [    XLEN-1:0]               amo_old_value;
  logic       [IdxWidth-1:0]               amo_entry_idx;

  // ===========================================================================
  // lq_data LUTRAM — split lo/hi for FLD partial-word writes
  // ===========================================================================
  // lq_data payload is only read at issue_cdb_idx (CDB broadcast).
  // Writes come from two independent sources that can overlap:
  //   Port 0 (primary): cache hit / store forward / memory response
  //   Port 1 (AMO):     AMO write completion
  // Split into 32-bit lo and hi halves so FLD can write each phase
  // independently without read-modify-write.

  // Forward declaration (used as LUTRAM read address)
  logic       [IdxWidth-1:0]               issue_cdb_idx;

  logic       [    XLEN-1:0]               lq_data_lo_rd;  // LUTRAM async read at issue_cdb_idx
  logic       [    XLEN-1:0]               lq_data_hi_rd;

  // Write port signals (2 ports each for lo and hi)
  logic       [         1:0]               lq_data_lo_we;
  logic       [         1:0]               lq_data_hi_we;
  logic       [         1:0][IdxWidth-1:0] lq_data_wr_addr;
  logic       [         1:0][    XLEN-1:0] lq_data_lo_wd;
  logic       [         1:0][    XLEN-1:0] lq_data_hi_wd;

  mwp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH(XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_lq_data_lo (
      .i_clk,
      .i_write_enable (lq_data_lo_we),
      .i_write_address(lq_data_wr_addr),
      .i_write_data   (lq_data_lo_wd),
      .i_read_address (issue_cdb_idx),
      .o_read_data    (lq_data_lo_rd)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH(XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_lq_data_hi (
      .i_clk,
      .i_write_enable (lq_data_hi_we),
      .i_write_address(lq_data_wr_addr),
      .i_write_data   (lq_data_hi_wd),
      .i_read_address (issue_cdb_idx),
      .o_read_data    (lq_data_hi_rd)
  );

  // ===========================================================================
  // Internal Signals
  // ===========================================================================

  logic full;
  logic empty;
  logic [CountWidth-1:0] count;

  // Issue selection
  logic issue_cdb_found;  // Phase A: entry with data_valid
  // issue_cdb_idx declared above (before LUTRAM instances)
  logic issue_mem_found;  // Phase B: entry ready for memory
  logic [IdxWidth-1:0] issue_mem_idx;
  logic block_younger_mem;

  // Memory issued entry tracking
  logic mem_outstanding;  // One outstanding read at a time
  logic [IdxWidth-1:0] issued_idx;  // Which entry is awaiting mem response
  logic drop_mem_response_pending;  // Drop the next 1-cycle-latency response after flush

  // Load unit wires
  logic [XLEN-1:0] lu_data_out;

  // Response acceptance/drain control
  logic issued_entry_flushed;
  logic accept_mem_response;
  logic drop_mem_response_now;

  // Entry freeing
  logic free_entry_en;
  logic [IdxWidth-1:0] free_entry_idx;

  // Head advancement target (scans past all contiguous invalid entries)
  logic [PtrWidth-1:0] head_advance_target;

  // ===========================================================================
  // AMO ALU (combinational)
  // ===========================================================================
  function automatic logic [XLEN-1:0] amo_compute(
      input riscv_pkg::instr_op_e op, input logic [XLEN-1:0] old_val, input logic [XLEN-1:0] rs2);
    case (op)
      riscv_pkg::AMOSWAP_W: amo_compute = rs2;
      riscv_pkg::AMOADD_W:  amo_compute = old_val + rs2;
      riscv_pkg::AMOXOR_W:  amo_compute = old_val ^ rs2;
      riscv_pkg::AMOAND_W:  amo_compute = old_val & rs2;
      riscv_pkg::AMOOR_W:   amo_compute = old_val | rs2;
      riscv_pkg::AMOMIN_W:  amo_compute = ($signed(old_val) < $signed(rs2)) ? old_val : rs2;
      riscv_pkg::AMOMAX_W:  amo_compute = ($signed(old_val) > $signed(rs2)) ? old_val : rs2;
      riscv_pkg::AMOMINU_W: amo_compute = (old_val < rs2) ? old_val : rs2;
      riscv_pkg::AMOMAXU_W: amo_compute = (old_val > rs2) ? old_val : rs2;
      default:              amo_compute = old_val;
    endcase
  endfunction

  // AMO write interface signals
  logic amo_write_pending;
  logic [XLEN-1:0] amo_new_value;

  // AMO cache invalidation: invalidate L0 cache when AMO write completes
  logic amo_cache_inv;
  assign amo_cache_inv = (amo_state == AMO_WRITE_ACTIVE) && i_amo_mem_write_done;

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
    issue_cdb_idx = '0;
    issue_mem_found = 1'b0;
    issue_mem_idx = '0;
    block_younger_mem = 1'b0;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      // Walk from head toward tail in circular order
      if (lq_valid[scan_idx[i]]) begin
        // Phase A: CDB broadcast candidate
        if (!issue_cdb_found && lq_data_valid[scan_idx[i]]) begin
          issue_cdb_found = 1'b1;
          issue_cdb_idx   = scan_idx[i];
        end
        // Phase B: Memory issue candidate
        // LR/AMO require ROB head (like MMIO); AMO also needs SQ committed-empty
        if (!issue_mem_found && !block_younger_mem && lq_addr_valid[scan_idx[i]]
            && !lq_issued[scan_idx[i]]
            && !lq_data_valid[scan_idx[i]]
            && (!lq_is_lr[scan_idx[i]] || (lq_rob_tag[scan_idx[i]] == i_rob_head_tag))
            && (!lq_is_amo[scan_idx[i]]
                || (lq_rob_tag[scan_idx[i]] == i_rob_head_tag && i_sq_committed_empty))
        ) begin
          issue_mem_found = 1'b1;
          issue_mem_idx   = scan_idx[i];
        end

        // A pending older AMO must block younger memory ops until its write
        // phase completes and the slot becomes data-valid. Otherwise a younger
        // reload can observe the pre-AMO value even though the AMO itself is
        // already underway.
        if (!issue_mem_found && lq_is_amo[scan_idx[i]] && !lq_data_valid[scan_idx[i]]) begin
          block_younger_mem = 1'b1;
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

    if (issue_mem_found && !mem_outstanding && !drop_mem_response_pending && !i_mem_bus_busy) begin
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
  logic flush_all_entries;

  assign sq_can_issue = o_sq_check_valid && i_sq_all_older_addrs_known && !i_sq_forward.match;
  assign sq_do_forward = ENABLE_SQ_FORWARD_FAST_PATH
      && o_sq_check_valid && i_sq_forward.can_forward
      && !lq_is_mmio[issue_mem_idx] && !lq_is_lr[issue_mem_idx] && !lq_is_amo[issue_mem_idx];
  assign flush_all_entries = i_flush_en &&
      (i_rob_head_tag == (i_flush_tag + ReorderBufferTagWidth'(1)));

  // Data memory has fixed 1-cycle latency in this design. If a partial flush
  // kills the outstanding load, drop that next response explicitly so the slot
  // can be safely reused before the stale data returns.
  assign issued_entry_flushed = i_flush_en && mem_outstanding && lq_valid[issued_idx] &&
      (flush_all_entries || is_younger(
      lq_rob_tag[issued_idx], i_flush_tag, i_rob_head_tag
  ));
  assign accept_mem_response = i_mem_read_valid && mem_outstanding &&
                               !drop_mem_response_pending && !issued_entry_flushed &&
                               lq_valid[issued_idx];
  assign drop_mem_response_now = i_mem_read_valid &&
                                 (drop_mem_response_pending || issued_entry_flushed ||
                                  (mem_outstanding && !lq_valid[issued_idx]));

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

  // ===========================================================================
  // L0 Cache Instance
  // ===========================================================================
  logic            cache_lookup_hit;
  logic [XLEN-1:0] cache_lookup_data;
  logic            cache_fill_valid;
  logic [XLEN-1:0] cache_fill_addr;
  logic [XLEN-1:0] cache_fill_data;

  lq_l0_cache #(
      .DEPTH    (128),
      .XLEN     (XLEN),
      .MMIO_ADDR(32'h4000_0000)
  ) u_l0_cache (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Lookup: candidate address from Phase B
      .i_lookup_addr(issue_mem_found ? lq_address[issue_mem_idx] : '0),
      .o_lookup_hit (cache_lookup_hit),
      .o_lookup_data(cache_lookup_data),

      // Fill: on memory response
      .i_fill_valid(cache_fill_valid),
      .i_fill_addr (cache_fill_addr),
      .i_fill_data (cache_fill_data),

      // Invalidation (from SQ or AMO write completion)
      .i_invalidate_valid(i_cache_invalidate_valid || amo_cache_inv),
      .i_invalidate_addr (amo_cache_inv ? lq_address[amo_entry_idx] : i_cache_invalidate_addr),

      // Flush
      .i_flush_all(i_flush_all)
  );

  // AMO serialization (ROB head + SQ committed-empty) guarantees these
  // two invalidation sources are mutually exclusive.
`ifndef SYNTHESIS
  assert property (@(posedge i_clk) disable iff (!i_rst_n)
      !(i_cache_invalidate_valid && amo_cache_inv))
  else $error("BUG: SQ and AMO cache invalidation fired simultaneously");
`endif

  // Cache-hit fast path signal: Phase B candidate hits L0 cache, SQ
  // disambiguation confirms no conflicting store, and the consumer is a
  // simple word-sized non-FP load. Subword loads and FLD stay on the memory
  // path to keep cache-hit semantics conservative around partial-word and
  // two-phase operations.
  logic cache_hit_fast_path;
  assign cache_hit_fast_path = ENABLE_L0_FAST_PATH
      && !i_flush_all && !i_flush_en
      && sq_can_issue
      && cache_lookup_hit
      && (lq_size[issue_mem_idx] == riscv_pkg::MEM_SIZE_WORD)
      && !lq_is_fp[issue_mem_idx]
      && !lq_is_mmio[issue_mem_idx]
      && !lq_is_lr[issue_mem_idx]
      && !lq_is_amo[issue_mem_idx];

  // Memory issue (placed after cache_hit_fast_path for Icarus compatibility)
  always_comb begin
    o_mem_read_en   = 1'b0;
    o_mem_read_addr = '0;
    o_mem_read_size = riscv_pkg::MEM_SIZE_WORD;

    if (!i_flush_all && !i_flush_en && sq_can_issue && !cache_hit_fast_path) begin
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

  // Load unit for cache hit path: feed cache data through load unit
  // for byte/half extraction.
  logic [XLEN-1:0] lu_cache_out;
  logic lu_cache_is_byte;
  logic lu_cache_is_half;
  logic lu_cache_is_unsigned;

  load_unit u_cache_load_unit (
      .i_is_load_byte           (lu_cache_is_byte),
      .i_is_load_halfword       (lu_cache_is_half),
      .i_is_load_unsigned       (lu_cache_is_unsigned),
      .i_data_memory_address    (lq_address[issue_mem_idx]),
      .i_data_memory_read_data  (cache_lookup_data),
      .o_data_loaded_from_memory(lu_cache_out)
  );

  always_comb begin
    lu_cache_is_byte     = (lq_size[issue_mem_idx] == riscv_pkg::MEM_SIZE_BYTE);
    lu_cache_is_half     = (lq_size[issue_mem_idx] == riscv_pkg::MEM_SIZE_HALF);
    lu_cache_is_unsigned = !lq_sign_ext[issue_mem_idx];
  end

  // ===========================================================================
  // lq_data LUTRAM Write Logic (combinational)
  // ===========================================================================
  // Placed after all signal declarations it references (cache_hit_fast_path,
  // sq_do_forward, lu_cache_out, lu_data_out, etc.) for Icarus compatibility.

  always_comb begin
    lq_data_lo_we   = '0;
    lq_data_hi_we   = '0;
    lq_data_wr_addr = '0;
    lq_data_lo_wd   = '0;
    lq_data_hi_wd   = '0;

    // ---------------------------------------------------------------
    // Port 0: primary (cache hit / forward / mem response)
    //         These sources are mutually exclusive (cache hit and
    //         forward require !mem_outstanding; mem response requires
    //         mem_outstanding).
    // ---------------------------------------------------------------
    if (i_rst_n && !i_flush_all) begin
      if (cache_hit_fast_path) begin
        lq_data_lo_we[0]   = 1'b1;
        lq_data_hi_we[0]   = 1'b1;
        lq_data_wr_addr[0] = issue_mem_idx;
        lq_data_lo_wd[0]   = lq_is_fp[issue_mem_idx] ? cache_lookup_data : lu_cache_out;
        lq_data_hi_wd[0]   = '0;
      end else if (sq_do_forward) begin
        lq_data_lo_we[0]   = 1'b1;
        lq_data_hi_we[0]   = 1'b1;
        lq_data_wr_addr[0] = issue_mem_idx;
        lq_data_lo_wd[0]   = i_sq_forward.data[XLEN-1:0];
        lq_data_hi_wd[0]   = i_sq_forward.data[FLEN-1:XLEN];
      end else if (accept_mem_response) begin
        lq_data_wr_addr[0] = issued_idx;
        if (lq_is_amo[issued_idx]) begin
          // AMO read: don't write data yet (port 1 handles after AMO write)
        end else if (lq_is_fp[issued_idx]
                     && lq_size[issued_idx] == riscv_pkg::MEM_SIZE_DOUBLE
                     && !lq_fp64_phase[issued_idx]) begin
          // FLD phase 0: write lo only
          lq_data_lo_we[0] = 1'b1;
          lq_data_lo_wd[0] = lu_data_out;
        end else if (lq_is_fp[issued_idx]
                     && lq_size[issued_idx] == riscv_pkg::MEM_SIZE_DOUBLE
                     && lq_fp64_phase[issued_idx]) begin
          // FLD phase 1: write hi only
          lq_data_hi_we[0] = 1'b1;
          lq_data_hi_wd[0] = i_mem_read_data;
        end else begin
          // LR / Non-FLD: write lo, clear hi
          lq_data_lo_we[0] = 1'b1;
          lq_data_hi_we[0] = 1'b1;
          lq_data_lo_wd[0] = lu_data_out;
          lq_data_hi_wd[0] = '0;
        end
      end
    end

    // ---------------------------------------------------------------
    // Port 1: AMO write completion (can overlap with port 0)
    // ---------------------------------------------------------------
    if (i_rst_n && !i_flush_all && amo_state == AMO_WRITE_ACTIVE && i_amo_mem_write_done) begin
      lq_data_lo_we[1]   = 1'b1;
      lq_data_hi_we[1]   = 1'b1;
      lq_data_wr_addr[1] = amo_entry_idx;
      lq_data_lo_wd[1]   = amo_old_value;
      lq_data_hi_wd[1]   = '0;
    end
  end

  // Cache fill: fill L0 cache on valid memory response (not for drained/flushed).
  // For FLD phase 1 the actual read address is base+4, so fill at that address
  // to avoid poisoning the cache entry for the base address.
  logic [XLEN-1:0] cache_fill_actual_addr;
  always_comb begin
    if (lq_is_fp[issued_idx] &&
        lq_size[issued_idx] == riscv_pkg::MEM_SIZE_DOUBLE &&
        lq_fp64_phase[issued_idx]) begin
      cache_fill_actual_addr = lq_address[issued_idx] + 32'd4;
    end else begin
      cache_fill_actual_addr = lq_address[issued_idx];
    end
  end

  assign cache_fill_valid = accept_mem_response
      && !lq_is_mmio[issued_idx] && !lq_is_lr[issued_idx] && !lq_is_amo[issued_idx];
  assign cache_fill_addr = cache_fill_actual_addr;
  assign cache_fill_data = i_mem_read_data;

  // AMO write interface: compute new value combinationally from outstanding AMO read
  always_comb begin
    amo_write_pending = 1'b0;
    amo_new_value = '0;
    o_amo_mem_write_en = 1'b0;
    o_amo_mem_write_addr = '0;
    o_amo_mem_write_data = '0;

    if (amo_state == AMO_WRITE_ACTIVE) begin
      // Maintain write request until done
      o_amo_mem_write_en = 1'b1;
      o_amo_mem_write_addr = lq_address[amo_entry_idx];
      o_amo_mem_write_data =
          amo_compute(lq_amo_op[amo_entry_idx], amo_old_value, lq_amo_rs2[amo_entry_idx]);
    end else if (accept_mem_response && lq_is_amo[issued_idx]) begin
      // AMO read just arrived: start write in the same cycle
      amo_write_pending = 1'b1;
      amo_new_value = amo_compute(lq_amo_op[issued_idx], i_mem_read_data, lq_amo_rs2[issued_idx]);
      o_amo_mem_write_en = 1'b1;
      o_amo_mem_write_addr = lq_address[issued_idx];
      o_amo_mem_write_data = amo_new_value;
    end
  end

  // Drive load unit inputs from the entry awaiting response (memory path)
  always_comb begin
    lu_is_byte     = 1'b0;
    lu_is_half     = 1'b0;
    lu_is_unsigned = 1'b0;
    lu_addr        = '0;
    lu_raw_data    = i_mem_read_data;

    if (accept_mem_response) begin
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

    if (issue_cdb_found && !i_adapter_result_pending && !i_flush_all && !i_flush_en) begin
      o_fu_complete.valid = 1'b1;
      o_fu_complete.tag   = lq_rob_tag[issue_cdb_idx];

      if (lq_is_fp[issue_cdb_idx]) begin
        if (lq_size[issue_cdb_idx] == riscv_pkg::MEM_SIZE_DOUBLE) begin
          // FLD: raw 64-bit data (lo + hi from LUTRAM)
          o_fu_complete.value = {lq_data_hi_rd, lq_data_lo_rd};
        end else begin
          // FLW: NaN-box 32-bit to 64-bit
          o_fu_complete.value = {32'hFFFF_FFFF, lq_data_lo_rd};
        end
      end else begin
        // INT load: zero-extend XLEN to FLEN
        o_fu_complete.value = {{(FLEN - XLEN) {1'b0}}, lq_data_lo_rd};
      end
    end
  end

  // Entry freeing: when CDB is presenting a valid result (will be captured by adapter)
  assign free_entry_en  = o_fu_complete.valid;
  assign free_entry_idx = issue_cdb_idx;

  // ===========================================================================
  // Tail Retraction (combinational scan for partial flush)
  // ===========================================================================
  // After partial flush, retract tail backwards past consecutive invalid
  // entries at the tail end so that pointer-based full is accurate.
  // Uses the *current* (pre-flush) lq_valid together with the partial flush
  // invalidation predicate to see the post-flush validity.

  // Pre-compute post-flush validity per entry (combinational):
  // An entry will be invalid after flush if it is currently invalid
  // OR it is being flushed (younger than flush_tag).
  logic [DEPTH-1:0] post_flush_valid;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      post_flush_valid[i] = lq_valid[i] &&
          !(i_flush_en &&
            (flush_all_entries || is_younger(lq_rob_tag[i], i_flush_tag, i_rob_head_tag)));
    end
  end

  logic [PtrWidth-1:0] flush_tail_target;

  // Retract tail past contiguous invalid entries at the tail end.
  // Mirrors head_advance_target: recompute check index from the current
  // flush_tail_target each iteration so we stop at the first valid entry
  // and never skip over non-contiguous gaps.
  always_comb begin
    flush_tail_target = tail_ptr;
    for (int s = 0; s < DEPTH; s++) begin
      if (flush_tail_target != head_ptr
          && !post_flush_valid[flush_tail_target[IdxWidth-1:0] - IdxWidth'(1)])
        flush_tail_target = flush_tail_target - PtrWidth'(1);
    end
  end

  // ===========================================================================
  // Head Advancement (combinational scan past contiguous invalid entries)
  // ===========================================================================
  // Advance head past all currently-invalid entries.
  //
  // Do not fold the same-cycle CDB free into this scan. Letting issue/CDB
  // selection feed head_ptr directly creates a long MEM_RS -> LQ head advance
  // cone in post-synthesis timing. A one-cycle lag before the head pointer
  // catches up to a newly-freed slot is architecturally harmless: the entry is
  // already invalid in lq_valid, so the next cycle's scans naturally skip it.
  // At DEPTH=8 this remaining chain is still trivial.

  always_comb begin
    head_advance_target = head_ptr;
    for (int unsigned s = 0; s < DEPTH; s++) begin
      if (head_advance_target != tail_ptr && !lq_valid[head_advance_target[IdxWidth-1:0]])
        head_advance_target = head_advance_target + PtrWidth'(1);
    end
  end

  // ===========================================================================
  // Sequential Logic
  // ===========================================================================

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      head_ptr                  <= '0;
      tail_ptr                  <= '0;
      lq_valid                  <= '0;
      lq_is_fp                  <= '0;
      lq_addr_valid             <= '0;
      lq_sign_ext               <= '0;
      lq_is_mmio                <= '0;
      lq_fp64_phase             <= '0;
      lq_issued                 <= '0;
      lq_data_valid             <= '0;
      lq_forwarded              <= '0;
      lq_is_lr                  <= '0;
      lq_is_amo                 <= '0;
      mem_outstanding           <= 1'b0;
      issued_idx                <= '0;
      drop_mem_response_pending <= 1'b0;
      reservation_valid         <= 1'b0;
      reservation_addr          <= '0;
      amo_state                 <= AMO_IDLE;
      amo_old_value             <= '0;
      amo_entry_idx             <= '0;
    end else if (i_flush_all) begin
      // Full flush: reset everything
      head_ptr                  <= '0;
      tail_ptr                  <= '0;
      lq_valid                  <= '0;
      lq_is_fp                  <= '0;
      lq_addr_valid             <= '0;
      lq_sign_ext               <= '0;
      lq_is_mmio                <= '0;
      lq_fp64_phase             <= '0;
      lq_issued                 <= '0;
      lq_data_valid             <= '0;
      lq_forwarded              <= '0;
      lq_is_lr                  <= '0;
      lq_is_amo                 <= '0;
      mem_outstanding           <= 1'b0;
      issued_idx                <= '0;
      drop_mem_response_pending <= 1'b0;
      reservation_valid         <= 1'b0;
      reservation_addr          <= '0;
      amo_state                 <= AMO_IDLE;
      amo_old_value             <= '0;
      amo_entry_idx             <= '0;
    end else begin
      // -----------------------------------------------------------------
      // Partial flush: invalidate entries younger than flush_tag
      // -----------------------------------------------------------------
      if (i_flush_en) begin
        if (flush_all_entries) begin
          lq_valid <= '0;
        end else begin
          for (int i = 0; i < DEPTH; i++) begin
            if (lq_valid[i] && is_younger(lq_rob_tag[i], i_flush_tag, i_rob_head_tag)) begin
              lq_valid[i] <= 1'b0;
            end
          end
        end
        // If the outstanding load was flushed, drop the next fixed-latency
        // memory response explicitly so the recycled slot cannot see stale data.
        if (issued_entry_flushed) begin
          mem_outstanding <= 1'b0;
          lq_issued[issued_idx] <= 1'b0;
          if (!i_mem_read_valid) begin
            drop_mem_response_pending <= 1'b1;
          end
        end
        // Retract tail: computed combinationally (see flush_tail_target)
        tail_ptr <= flush_tail_target;
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
        lq_forwarded[tail_idx]  <= 1'b0;
        lq_is_lr[tail_idx]      <= i_alloc.is_lr;
        lq_is_amo[tail_idx]     <= i_alloc.is_amo;
        lq_amo_op[tail_idx]     <= i_alloc.amo_op;
        lq_amo_rs2[tail_idx]    <= '0;
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
            lq_amo_rs2[i]    <= i_addr_update.amo_rs2;
          end
        end
      end

      // -----------------------------------------------------------------
      // L0 Cache Hit Fast Path: SQ confirmed no conflict, use cached data
      // -----------------------------------------------------------------
      if (cache_hit_fast_path) begin
        lq_data_valid[issue_mem_idx] <= 1'b1;
      end

      // -----------------------------------------------------------------
      // Store forwarding: write data directly, skip memory
      // -----------------------------------------------------------------
      if (sq_do_forward) begin
        lq_data_valid[issue_mem_idx] <= 1'b1;
        lq_forwarded[issue_mem_idx]  <= 1'b1;
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
      // Stale response drain: partial flushes can kill an outstanding load one
      // cycle before the data returns. Drop that response explicitly.
      if (drop_mem_response_now) begin
        mem_outstanding <= 1'b0;
        drop_mem_response_pending <= 1'b0;
      end else if (accept_mem_response) begin
        if (lq_is_amo[issued_idx]) begin
          // AMO: latch old value, start write phase (don't set data_valid yet)
          amo_old_value   <= i_mem_read_data;
          amo_entry_idx   <= issued_idx;
          amo_state       <= AMO_WRITE_ACTIVE;
          mem_outstanding <= 1'b0;
        end else if (lq_is_lr[issued_idx]) begin
          // LR: data captured by LUTRAM write logic
          lq_data_valid[issued_idx] <= 1'b1;
          mem_outstanding           <= 1'b0;
          reservation_valid         <= 1'b1;
          reservation_addr          <= lq_address[issued_idx];
        end else if (lq_is_fp[issued_idx] &&
            lq_size[issued_idx] == riscv_pkg::MEM_SIZE_DOUBLE &&
            !lq_fp64_phase[issued_idx]) begin
          // FLD phase 0: advance to phase 1, data captured by LUTRAM
          lq_fp64_phase[issued_idx] <= 1'b1;
          lq_issued[issued_idx]     <= 1'b0;  // Re-issue for phase 1
          mem_outstanding           <= 1'b0;
        end else if (lq_is_fp[issued_idx] &&
                     lq_size[issued_idx] == riscv_pkg::MEM_SIZE_DOUBLE &&
                     lq_fp64_phase[issued_idx]) begin
          // FLD phase 1: data captured by LUTRAM
          lq_data_valid[issued_idx] <= 1'b1;
          mem_outstanding           <= 1'b0;
        end else begin
          // Non-FLD: data captured by LUTRAM
          lq_data_valid[issued_idx] <= 1'b1;
          mem_outstanding           <= 1'b0;
        end
      end

      // -----------------------------------------------------------------
      // AMO Write Completion: latch old value as result, invalidate cache
      // -----------------------------------------------------------------
      if (amo_state == AMO_WRITE_ACTIVE && i_amo_mem_write_done) begin
        lq_data_valid[amo_entry_idx] <= 1'b1;
        amo_state                    <= AMO_IDLE;
      end

      // -----------------------------------------------------------------
      // Reservation clear (priority: clear wins over set)
      // -----------------------------------------------------------------
      if (i_sc_clear_reservation || i_reservation_snoop_invalidate) begin
        reservation_valid <= 1'b0;
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

  // i_mem_read_valid only asserts when we have an outstanding read.
  // The drain approach keeps mem_outstanding set after partial flush of
  // the issued entry, so a late response is allowed (and discarded).
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

  // Cache-hit fast path must always have SQ disambiguation confirmed
  always_comb begin
    if (i_rst_n && cache_hit_fast_path) begin
      p_cache_hit_needs_sq :
      assert (o_sq_check_valid && i_sq_all_older_addrs_known && !i_sq_forward.match);
    end
  end

  // -------------------------------------------------------------------------
  // Sequential assertions
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin

      // Allocation writes a valid entry at the pre-alloc tail index.
      // Guard: no concurrent flush (which resets pointers / invalidates).
      if ($past(
              i_alloc.valid
          ) && !$past(
              full
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_flush_en
          ) && !i_flush_all && !i_flush_en) begin
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

      // Stale response drain: mem response arrives for a flushed entry
      cover_stale_drain : cover (i_mem_read_valid && mem_outstanding && !lq_valid[issued_idx]);

      // Partial flush followed by successful allocation (tail reclamation)
      cover_partial_flush_reclaims : cover ($past(i_flush_en) && i_alloc.valid && !full);

      // L0 cache hit fast path delivers data without memory issue
      cover_cache_hit : cover (cache_hit_fast_path);

      // L0 cache fill on memory response
      cover_cache_fill : cover (cache_fill_valid);
    end
  end

`endif  // FORMAL

endmodule : load_queue
