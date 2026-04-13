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
    parameter bit ENABLE_L0_FAST_PATH = 1'b1,
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
    input logic i_adapter_result_pending,  // downstream busy hint
    input logic i_result_accepted,  // staged result advanced toward adapter

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
    // SQ empty / committed-empty (for issue gating)
    // =========================================================================
    input logic i_sq_empty,
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
    input logic                                        i_early_recovery_flush,

    // =========================================================================
    // L0 Cache Invalidation (from SQ, future)
    // =========================================================================
    input logic                       i_cache_invalidate_valid,
    input logic [riscv_pkg::XLEN-1:0] i_cache_invalidate_addr,

    // =========================================================================
    // Status
    // =========================================================================
    output logic                       o_empty,
    output logic [$clog2(DEPTH+1)-1:0] o_count,

    // =========================================================================
    // L0 Cache Profile Pulses (one cycle each, for perf counters)
    // =========================================================================
    output logic o_l0_hit,  // L0 cache fast-path completion
    output logic o_l0_fill  // L0 cache fill from memory response
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
  // Storage -- Circular buffer with FF-based control plus LUTRAM payloads
  // ===========================================================================

  // Head and tail pointers (extra MSB for full/empty distinction)
  logic [PtrWidth-1:0] head_ptr;
  logic [PtrWidth-1:0] tail_ptr;

  // Index extraction (lower bits)
  wire [IdxWidth-1:0] head_idx = head_ptr[IdxWidth-1:0];
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
  logic [$bits(riscv_pkg::instr_op_e)-1:0] lq_amo_op_rd;
  logic [$bits(riscv_pkg::mem_size_e)-1:0] lq_size_issue_mem_rd;
  logic [$bits(riscv_pkg::mem_size_e)-1:0] lq_size_issued_rd;
  logic [$bits(riscv_pkg::mem_size_e)-1:0] lq_size_issue_cdb_rd;
  logic [XLEN-1:0] lq_address_issue_mem_rd;
  logic [XLEN-1:0] lq_address_issued_rd;
  logic [XLEN-1:0] lq_address_amo_rd;
  logic [XLEN-1:0] lq_amo_rs2_rd;
  logic [IdxWidth-1:0] amo_entry_idx;
  logic full;

  // AMO op is written once at allocation and only read back for AMO execution.
  sdp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH($bits(riscv_pkg::instr_op_e))
  ) u_lq_amo_op (
      .i_clk,
      .i_write_enable (i_alloc.valid && !full),
      .i_write_address(alloc_target[IdxWidth-1:0]),
      .i_write_data   (i_alloc.amo_op),
      .i_read_address (amo_entry_idx),
      .o_read_data    (lq_amo_op_rd)
  );

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

  logic empty;
  logic [CountWidth-1:0] count;

  // Issue selection
  logic issue_cdb_found;  // Phase A: entry with data_valid
  // issue_cdb_idx declared above (before LUTRAM instances)
  logic issue_mem_found;  // Phase B: entry ready for memory
  logic [IdxWidth-1:0] issue_mem_idx;
  logic block_younger_mem;
  logic issue_cdb_fire;
  logic cdb_stage_slot_available;
  logic cdb_stage_result_flushed;
  riscv_pkg::fu_complete_t issue_cdb_result;
  logic cdb_stage_valid;
  riscv_pkg::fu_complete_t cdb_stage_data;

  // Staged SQ-disambiguation candidate. This breaks the same-cycle
  // issue-scan -> SQ compare -> memory-launch loop by holding one
  // candidate load stable while SQ resolves it. Keep the candidate armed even
  // while an older read is outstanding so the next load can launch as soon as
  // the memory slot opens, instead of paying a fresh capture + SQ phase first.
  logic sq_check_pending;
  logic [IdxWidth-1:0] sq_check_idx;
  logic [ReorderBufferTagWidth-1:0] sq_check_rob_tag_q;
  logic [XLEN-1:0] sq_check_addr_q;
  riscv_pkg::mem_size_e sq_check_size_q;
  logic sq_check_is_fp_q;
  logic sq_check_sign_ext_q;
  logic sq_check_is_mmio_q;
  logic sq_check_fp64_phase_q;
  logic sq_check_is_lr_q;
  logic sq_check_is_amo_q;
  logic sq_check_no_older_store_q;
  logic sq_check_capture;
  logic sq_check_replace;
  logic sq_check_entry_valid;
  logic sq_check_entry_issueable;
  logic sq_check_phase2;

  // (mem_issue_pending / mem_issue_idx / mem_issue_addr / mem_issue_size were
  // a second-deep staging register for the launch path. With sq_check_pending
  // now held through bus_busy stalls via the launch_mem_issue clearing
  // condition, that staging is redundant — sq_check_idx / sq_check_addr_q /
  // sq_check_size_q already hold the exact request stably across the stall.
  // Removing them shrinks the address-mux LUT cone feeding the data-memory
  // BRAM ADDR pin and recovers the timing budget the back-to-back changes
  // had eaten on x3.)

  // Memory issued entry tracking. With BRAM 1-cycle latency the response
  // arrives exactly one cycle after o_mem_read_en is asserted, so a single
  // register pipeline (mem_outstanding + issued_idx) is sufficient even when
  // back-to-back loads are issued every cycle. mem_outstanding is high in the
  // cycle a response is expected; issued_idx names the entry that owns it.
  // The launch path overrides the response-side clear so a same-cycle
  // launch+response keeps mem_outstanding asserted into the next cycle.
  logic mem_outstanding;
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

  // Head/tail search targets for the sparse valid-bit queue.
  logic [PtrWidth-1:0] head_advance_target;
  logic [PtrWidth-1:0] alloc_target;
  logic lq_addr_update_we;
  logic [IdxWidth-1:0] lq_addr_update_idx;

  // lq_size is allocation-written and only read when staging sq_check,
  // handling an issued load, or broadcasting a result on the CDB.
  sdp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH($bits(riscv_pkg::mem_size_e))
  ) u_lq_size_issue_mem (
      .i_clk,
      .i_write_enable (i_alloc.valid && !full),
      .i_write_address(alloc_target[IdxWidth-1:0]),
      .i_write_data   (i_alloc.size),
      .i_read_address (issue_mem_idx),
      .o_read_data    (lq_size_issue_mem_rd)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH($bits(riscv_pkg::mem_size_e))
  ) u_lq_size_issued (
      .i_clk,
      .i_write_enable (i_alloc.valid && !full),
      .i_write_address(alloc_target[IdxWidth-1:0]),
      .i_write_data   (i_alloc.size),
      .i_read_address (issued_idx),
      .o_read_data    (lq_size_issued_rd)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH($bits(riscv_pkg::mem_size_e))
  ) u_lq_size_issue_cdb (
      .i_clk,
      .i_write_enable (i_alloc.valid && !full),
      .i_write_address(alloc_target[IdxWidth-1:0]),
      .i_write_data   (i_alloc.size),
      .i_read_address (issue_cdb_idx),
      .o_read_data    (lq_size_issue_cdb_rd)
  );

  // lq_address and lq_amo_rs2 are only written once the address CAM resolves.
  // Valid bits stay in FFs; stale RAM contents are don't-care until addr_valid.
  sdp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH(XLEN)
  ) u_lq_address_issue_mem (
      .i_clk,
      .i_write_enable (lq_addr_update_we),
      .i_write_address(lq_addr_update_idx),
      .i_write_data   (i_addr_update.address),
      .i_read_address (issue_mem_idx),
      .o_read_data    (lq_address_issue_mem_rd)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH(XLEN)
  ) u_lq_address_issued (
      .i_clk,
      .i_write_enable (lq_addr_update_we),
      .i_write_address(lq_addr_update_idx),
      .i_write_data   (i_addr_update.address),
      .i_read_address (issued_idx),
      .o_read_data    (lq_address_issued_rd)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH(XLEN)
  ) u_lq_address_amo (
      .i_clk,
      .i_write_enable (lq_addr_update_we),
      .i_write_address(lq_addr_update_idx),
      .i_write_data   (i_addr_update.address),
      .i_read_address (amo_entry_idx),
      .o_read_data    (lq_address_amo_rd)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH(XLEN)
  ) u_lq_amo_rs2 (
      .i_clk,
      .i_write_enable (lq_addr_update_we),
      .i_write_address(lq_addr_update_idx),
      .i_write_data   (i_addr_update.amo_rs2),
      .i_read_address (amo_entry_idx),
      .o_read_data    (lq_amo_rs2_rd)
  );

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

  assign full = (count == CountWidth'(DEPTH));
  assign empty = (count == CountWidth'(0));

  assign o_full = full;
  assign o_empty = empty;
  assign o_count = count;

  always_comb begin
    lq_addr_update_we  = 1'b0;
    lq_addr_update_idx = '0;
    if (i_addr_update.valid && i_rst_n && !i_flush_all) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (!lq_addr_update_we && lq_valid[i] && !lq_addr_valid[i] &&
            lq_rob_tag[i] == i_addr_update.rob_tag) begin
          lq_addr_update_we  = 1'b1;
          lq_addr_update_idx = IdxWidth'(i);
        end
      end
    end
  end

  // ===========================================================================
  // Issue Selection (parallel qualification + tree priority encoders)
  // ===========================================================================
  // TIMING: Restructured from a single serial loop (16 logic levels due to
  // inter-iteration dependencies through issue_mem_found/block_younger_mem) into
  // parallel per-entry qualification masks followed by tree-based find-first-one
  // encoders (~7-8 logic levels).
  //
  // Phase A: Oldest entry with data_valid (ready for CDB broadcast).
  //          FLD: both phases must be complete (data_valid=1).
  // Phase B: Oldest entry with addr_valid && !issued && !data_valid,
  //          ready for SQ disambiguation and potential memory issue.
  //          MMIO/LR require ROB head; AMO also needs SQ committed-empty.

  // Pre-computed circular scan indices (head-relative order)
  logic [IdxWidth-1:0] scan_idx[DEPTH];
  always_comb begin
    for (int unsigned j = 0; j < DEPTH; j++)
    scan_idx[j] = IdxWidth'(({{(32 - IdxWidth) {1'b0}}, head_idx} + j) % DEPTH);
  end

  // Phase A: per-entry CDB readiness (parallel, no inter-entry dependency)
  logic [DEPTH-1:0] cdb_ready_mask;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      cdb_ready_mask[i] = lq_valid[scan_idx[i]] && lq_data_valid[scan_idx[i]];
    end
  end

  // Phase A: tree priority encoder — find oldest CDB-ready entry
  always_comb begin
    issue_cdb_found = 1'b0;
    issue_cdb_idx   = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (cdb_ready_mask[i] && !issue_cdb_found) begin
        issue_cdb_found = 1'b1;
        issue_cdb_idx   = scan_idx[i];
      end
    end
  end

  // Mask of the entry already claimed by the sq_check staging register.
  // With back-to-back issue enabled, sq_check_capture can fire in the same
  // cycle that the previous candidate launches, so the priority encoder must
  // avoid re-picking the entry already held in sq_check_idx before
  // lq_issued becomes visible.
  logic [DEPTH-1:0] in_flight_mask;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      in_flight_mask[i] = sq_check_pending && (sq_check_idx == IdxWidth'(i));
    end
  end

  // Phase B: per-entry memory issue eligibility (parallel).
  // Includes MMIO check (MMIO loads only eligible at ROB head) so
  // sq_check_capture/replace no longer need an indexed MMIO lookup.
  logic [DEPTH-1:0] mem_eligible_mask;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      mem_eligible_mask[i] =
          lq_valid[scan_idx[i]] &&
          lq_addr_valid[scan_idx[i]] &&
          !lq_issued[scan_idx[i]] &&
          !lq_data_valid[scan_idx[i]] &&
          !in_flight_mask[scan_idx[i]] &&
          (!lq_is_mmio[scan_idx[i]] || (lq_rob_tag[scan_idx[i]] == i_rob_head_tag)) &&
          (!lq_is_lr[scan_idx[i]]   || (lq_rob_tag[scan_idx[i]] == i_rob_head_tag)) &&
          (!lq_is_amo[scan_idx[i]]  ||
           (lq_rob_tag[scan_idx[i]] == i_rob_head_tag && i_sq_committed_empty));
    end
  end

  // AMO blocking: identify scan positions with pending (unresolved) AMOs.
  // A pending older AMO must block younger memory ops until its write
  // phase completes and the slot becomes data-valid.
  logic [DEPTH-1:0] pending_amo_at;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      pending_amo_at[i] = lq_valid[scan_idx[i]] &&
                          lq_is_amo[scan_idx[i]] &&
                          !lq_data_valid[scan_idx[i]];
    end
  end

  // Prefix-OR: compute "has older pending AMO" for each scan position
  logic [DEPTH-1:0] blocked_by_amo;
  /* verilator lint_off ALWCOMBORDER */
  always_comb begin
    blocked_by_amo[0] = 1'b0;
    for (int unsigned i = 1; i < DEPTH; i++) begin
      blocked_by_amo[i] = blocked_by_amo[i-1] | pending_amo_at[i-1];
    end
  end
  /* verilator lint_on ALWCOMBORDER */

  // Final Phase B mask: eligible AND not blocked by older AMO
  logic [DEPTH-1:0] mem_issue_mask;
  assign mem_issue_mask = mem_eligible_mask & ~blocked_by_amo;

  // The sparse queue can reuse reclaimed holes after flushes, so physical
  // queue order is not always identical to ROB age.  To avoid starving the
  // oldest architectural load behind a younger blocked entry, explicitly
  // prioritize an eligible ROB-head load over the normal physical-order scan.
  logic head_mem_issue_found;
  logic [IdxWidth-1:0] head_mem_issue_idx;
  always_comb begin
    head_mem_issue_found = 1'b0;
    head_mem_issue_idx   = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (!head_mem_issue_found &&
          lq_valid[i] &&
          (lq_rob_tag[i] == i_rob_head_tag) &&
          lq_addr_valid[i] &&
          !lq_issued[i] &&
          !lq_data_valid[i] &&
          !in_flight_mask[i] &&
          !lq_is_mmio[i] &&
          !lq_is_lr[i] &&
          (!lq_is_amo[i] || i_sq_committed_empty)) begin
        head_mem_issue_found = 1'b1;
        head_mem_issue_idx   = IdxWidth'(i);
      end
    end
  end

  // ROB tag of the winning Phase B entry (extracted alongside idx to avoid
  // a post-encoder 8-to-1 MUX on lq_rob_tag[issue_mem_idx])
  logic [ReorderBufferTagWidth-1:0] issue_mem_rob_tag;

  // Phase B: tree priority encoder — find oldest eligible entry
  always_comb begin
    issue_mem_found   = 1'b0;
    issue_mem_idx     = '0;
    issue_mem_rob_tag = '0;
    block_younger_mem = 1'b0;  // kept for interface compat; unused in restructured scan
    if (head_mem_issue_found) begin
      issue_mem_found   = 1'b1;
      issue_mem_idx     = head_mem_issue_idx;
      issue_mem_rob_tag = i_rob_head_tag;
    end else begin
      for (int unsigned i = 0; i < DEPTH; i++) begin
        if (mem_issue_mask[i] && !issue_mem_found) begin
          issue_mem_found   = 1'b1;
          issue_mem_idx     = scan_idx[i];
          issue_mem_rob_tag = lq_rob_tag[scan_idx[i]];
        end
      end
    end
  end

  // ===========================================================================
  // SQ Disambiguation Interface (combinational)
  // ===========================================================================
  // For Phase B candidate: drive SQ check ports

  assign sq_check_entry_valid = sq_check_pending;

  assign sq_check_entry_issueable = sq_check_entry_valid &&
      (!sq_check_is_lr_q || (sq_check_rob_tag_q == i_rob_head_tag)) &&
      (!sq_check_is_amo_q
       || (sq_check_rob_tag_q == i_rob_head_tag && i_sq_committed_empty)) &&
      (!sq_check_is_mmio_q || (sq_check_rob_tag_q == i_rob_head_tag));

  // sq_check_will_clear: the currently-pending sq_check entry will retire at
  // the end of this cycle (cache hit, SQ forward, launch, or invalid). When
  // true the slot is free for a new candidate the same cycle, enabling a
  // back-to-back capture stream that pairs with the relaxed launch_mem_issue
  // gate so the LQ can issue 1 load/cycle in steady state. The launch_mem_issue
  // term mirrors the corresponding clearing branch in the always_ff below.
  logic sq_check_will_clear;
  assign sq_check_will_clear = sq_check_pending &&
      (!sq_check_entry_valid || cache_hit_fast_path || sq_do_forward || launch_mem_issue);

  // TIMING: MMIO check folded into mem_eligible_mask (Phase B scan) so these
  // no longer need an indexed lq_is_mmio[issue_mem_idx] lookup.  The is_younger
  // comparison uses issue_mem_rob_tag extracted alongside the priority encoder
  // output to avoid a post-encoder 8-to-1 MUX on lq_rob_tag[issue_mem_idx].
  assign sq_check_capture = (!sq_check_pending || sq_check_will_clear) &&
      issue_mem_found &&
      !drop_mem_response_pending && !i_mem_bus_busy && !i_flush_all && !i_flush_en;

  assign sq_check_replace = sq_check_pending && issue_mem_found &&
      !drop_mem_response_pending && !i_mem_bus_busy && !i_flush_all && !i_flush_en &&
      (!sq_check_entry_valid || is_younger(
      sq_check_rob_tag_q, issue_mem_rob_tag, i_rob_head_tag
  ));

  // Always output registered check parameters regardless of valid.  The SQ
  // gates on i_sq_check_valid at its output register (o_sq_forward.match <=
  // i_sq_check_valid ? fwd_found_match : 1'b0), so stale values are harmless.
  // Removing the addr/tag/size MUX breaks the cross-module timing path:
  //   SQ sq_valid → o_mem_write_en → LQ i_mem_bus_busy → o_sq_check_valid
  //   → addr MUX → SQ i_sq_check_addr → CARRY8 compare → o_sq_forward_reg
  always_comb begin
    o_sq_check_valid   = 1'b0;
    o_sq_check_addr    = sq_check_addr_q;
    o_sq_check_rob_tag = sq_check_rob_tag_q;
    o_sq_check_size    = sq_check_size_q;

    if (!i_flush_all && !i_flush_en && !drop_mem_response_pending &&
        !i_mem_bus_busy && sq_check_entry_issueable &&
        !(sq_check_no_older_store_q || i_sq_empty)) begin
      o_sq_check_valid = 1'b1;
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
  logic stage_mem_issue;
  logic launch_mem_issue;
  logic [IdxWidth-1:0] launch_mem_issue_idx;
  logic [XLEN-1:0] launch_mem_issue_addr;
  riscv_pkg::mem_size_e launch_mem_issue_size;
  logic cache_hit_fast_path;
  logic [XLEN-1:0] stage_mem_issue_addr;
  riscv_pkg::mem_size_e stage_mem_issue_size;
  logic flush_all_entries;
  logic sq_no_older_store;
  assign sq_no_older_store = sq_check_no_older_store_q || i_sq_empty;
  assign sq_can_issue = sq_check_phase2 && sq_check_entry_issueable &&
      (sq_no_older_store || (i_sq_all_older_addrs_known && !i_sq_forward.match));
  assign sq_do_forward = ENABLE_SQ_FORWARD_FAST_PATH
      && sq_check_phase2 && sq_check_entry_issueable && !sq_no_older_store &&
      i_sq_forward.can_forward
      && !sq_check_is_mmio_q && !sq_check_is_lr_q && !sq_check_is_amo_q;
  assign flush_all_entries = i_flush_en && !i_early_recovery_flush &&
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

      // Lookup: staged SQ-disambiguation candidate
      .i_lookup_addr(sq_check_entry_valid ? sq_check_addr_q : '0),
      .o_lookup_hit (cache_lookup_hit),
      .o_lookup_data(cache_lookup_data),

      // Fill: on memory response
      .i_fill_valid(cache_fill_valid),
      .i_fill_addr (cache_fill_addr),
      .i_fill_data (cache_fill_data),

      // Invalidation (from SQ or AMO write completion)
      .i_invalidate_valid(i_cache_invalidate_valid || amo_cache_inv),
      .i_invalidate_addr (amo_cache_inv ? lq_address_amo_rd : i_cache_invalidate_addr),

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
  // cache-safe load. Integer byte/half/word loads can reuse the cached raw
  // word through the local load_unit. FLW can also reuse the cached word
  // directly. FLD remains on the memory path because it is a two-phase
  // operation on the 32-bit data bus.
  assign cache_hit_fast_path = ENABLE_L0_FAST_PATH
      && !i_flush_all && !i_flush_en
      && sq_can_issue
      && cache_lookup_hit
      && !sq_check_is_mmio_q
      && !sq_check_is_lr_q
      && !sq_check_is_amo_q
      && (!sq_check_is_fp_q || (sq_check_size_q == riscv_pkg::MEM_SIZE_WORD));

  always_comb begin
    stage_mem_issue_addr = sq_check_addr_q;
    if (sq_check_is_fp_q &&
        (sq_check_size_q == riscv_pkg::MEM_SIZE_DOUBLE) &&
        sq_check_fp64_phase_q) begin
      stage_mem_issue_addr = sq_check_addr_q + 32'd4;
    end
  end

  assign stage_mem_issue = !i_flush_en && sq_can_issue && !cache_hit_fast_path;
  assign stage_mem_issue_size = sq_check_size_q;

  // PERF: Removed the !mem_outstanding gate so the LQ can launch a new load
  // every cycle (BRAM has 1-cycle latency, so the response from the previous
  // launch arrives the same cycle the new launch is driven). The bus_busy
  // gate replaces it: it ensures the launch reaches the data-memory port
  // immediately rather than being queued in cpu_ooo's lq_mem_request_valid
  // hold register, which is single-deep and would conflict with back-to-back
  // launches. Loses the rare overlap of one queued launch with a SQ write,
  // but that path was 4.4% of cycles in the baseline profile vs. doubling
  // the steady-state load issue rate.
  //
  // TIMING: launch_mem_issue_idx/addr/size now read sq_check_idx /
  // stage_mem_issue_addr / stage_mem_issue_size directly. The previous
  // mem_issue_pending mux fed into the data-memory BRAM ADDR cone and was
  // the dominant -0.911 ns timing-failing path on x3. sq_check_pending
  // already holds the staged candidate stably across bus_busy stalls
  // (sq_check_will_clear keys off launch_mem_issue, not stage_mem_issue),
  // so the mem_issue_pending second-deep stage is redundant.
  assign launch_mem_issue = !i_flush_en && !i_mem_bus_busy && stage_mem_issue;
  assign launch_mem_issue_idx = sq_check_idx;
  assign launch_mem_issue_addr = stage_mem_issue_addr;
  assign launch_mem_issue_size = stage_mem_issue_size;

  // Memory issue: bypass the staging register when the port is already free.
  always_comb begin
    o_mem_read_en   = launch_mem_issue;
    o_mem_read_addr = launch_mem_issue_addr;
    o_mem_read_size = launch_mem_issue_size;
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
      .i_data_memory_address    (sq_check_addr_q),
      .i_data_memory_read_data  (cache_lookup_data),
      .o_data_loaded_from_memory(lu_cache_out)
  );

  always_comb begin
    lu_cache_is_byte = (sq_check_size_q == riscv_pkg::MEM_SIZE_BYTE);
    lu_cache_is_half = (sq_check_size_q == riscv_pkg::MEM_SIZE_HALF);
    lu_cache_is_unsigned = !sq_check_sign_ext_q;
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
    // Port 0: dedicated to memory response.
    //         With back-to-back launches enabled, mem response can fire
    //         every cycle. It owns its own port so a same-cycle cache hit
    //         (or SQ forward) on a different entry cannot clobber the
    //         response data via if-else priority.
    // ---------------------------------------------------------------
    if (i_rst_n && !i_flush_all && accept_mem_response) begin
      lq_data_wr_addr[0] = issued_idx;
      if (lq_is_amo[issued_idx]) begin
        // AMO read: don't write data yet (port 1 handles after AMO write)
      end else if (lq_is_fp[issued_idx]
                   && riscv_pkg::mem_size_e'(lq_size_issued_rd) == riscv_pkg::MEM_SIZE_DOUBLE
                   && !lq_fp64_phase[issued_idx]) begin
        // FLD phase 0: write lo only
        lq_data_lo_we[0] = 1'b1;
        lq_data_lo_wd[0] = lu_data_out;
      end else if (lq_is_fp[issued_idx]
                   && riscv_pkg::mem_size_e'(lq_size_issued_rd) == riscv_pkg::MEM_SIZE_DOUBLE
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

    // ---------------------------------------------------------------
    // Port 1: cache hit / SQ forward / AMO write completion.
    //         These three sources are mutually exclusive in time:
    //           - cache_hit and sq_forward each require sq_check_pending
    //             on a non-AMO entry. While amo_state == AMO_WRITE_ACTIVE
    //             the blocked_by_amo prefix-OR keeps the LQ from staging
    //             any other entry, so the AMO write completion never
    //             collides with cache_hit or sq_forward.
    //           - cache_hit requires sq_no_older_store while sq_forward
    //             requires the opposite, so they cannot fire together.
    // ---------------------------------------------------------------
    if (i_rst_n && !i_flush_all) begin
      if (cache_hit_fast_path) begin
        lq_data_lo_we[1]   = 1'b1;
        lq_data_hi_we[1]   = 1'b1;
        lq_data_wr_addr[1] = sq_check_idx;
        lq_data_lo_wd[1]   = sq_check_is_fp_q ? cache_lookup_data : lu_cache_out;
        lq_data_hi_wd[1]   = '0;
      end else if (sq_do_forward) begin
        lq_data_lo_we[1]   = 1'b1;
        lq_data_hi_we[1]   = 1'b1;
        lq_data_wr_addr[1] = sq_check_idx;
        lq_data_lo_wd[1]   = i_sq_forward.data[XLEN-1:0];
        lq_data_hi_wd[1]   = i_sq_forward.data[FLEN-1:XLEN];
      end else if (amo_state == AMO_WRITE_ACTIVE && i_amo_mem_write_done) begin
        lq_data_lo_we[1]   = 1'b1;
        lq_data_hi_we[1]   = 1'b1;
        lq_data_wr_addr[1] = amo_entry_idx;
        lq_data_lo_wd[1]   = amo_old_value;
        lq_data_hi_wd[1]   = '0;
      end
    end
  end

  // Cache fill: fill L0 cache on valid memory response (not for drained/flushed).
  // For FLD phase 1 the actual read address is base+4, so fill at that address
  // to avoid poisoning the cache entry for the base address.
  logic [XLEN-1:0] cache_fill_actual_addr;
  always_comb begin
    if (lq_is_fp[issued_idx] &&
        riscv_pkg::mem_size_e'(lq_size_issued_rd) == riscv_pkg::MEM_SIZE_DOUBLE &&
        lq_fp64_phase[issued_idx]) begin
      cache_fill_actual_addr = lq_address_issued_rd + 32'd4;
    end else begin
      cache_fill_actual_addr = lq_address_issued_rd;
    end
  end

  assign cache_fill_valid = accept_mem_response
      && !lq_is_mmio[issued_idx] && !lq_is_lr[issued_idx] && !lq_is_amo[issued_idx];
  assign cache_fill_addr = cache_fill_actual_addr;
  assign cache_fill_data = i_mem_read_data;

  // L0 cache profile pulses (one cycle when the event fires)
  assign o_l0_hit = cache_hit_fast_path;
  assign o_l0_fill = cache_fill_valid;

  // AMO write interface: compute new value combinationally from outstanding AMO read
  // TIMING: Removed same-cycle AMO write fast path (accept_mem_response &&
  // lq_is_amo) that created a BRAM-read → amo_compute → BRAM-write
  // combinational chain (-0.424 ns, 10 logic levels through CARRY8 + LUT6).
  // AMO writes now always go through the registered AMO_WRITE_ACTIVE path:
  // cycle N captures amo_old_value; cycle N+1 computes and writes.
  // Cost: +1 cycle AMO latency.
  always_comb begin
    amo_write_pending = 1'b0;
    amo_new_value = '0;
    o_amo_mem_write_en = 1'b0;
    o_amo_mem_write_addr = '0;
    o_amo_mem_write_data = '0;

    if (amo_state == AMO_WRITE_ACTIVE) begin
      o_amo_mem_write_en = 1'b1;
      o_amo_mem_write_addr = lq_address_amo_rd;
      o_amo_mem_write_data =
          amo_compute(riscv_pkg::instr_op_e'(lq_amo_op_rd), amo_old_value, lq_amo_rs2_rd);
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
      lu_is_byte     = (riscv_pkg::mem_size_e'(lq_size_issued_rd) == riscv_pkg::MEM_SIZE_BYTE);
      lu_is_half     = (riscv_pkg::mem_size_e'(lq_size_issued_rd) == riscv_pkg::MEM_SIZE_HALF);
      lu_is_unsigned = !lq_sign_ext[issued_idx];
      lu_addr        = lq_address_issued_rd;
    end
  end

  // ===========================================================================
  // CDB Broadcast Logic
  // ===========================================================================
  // Phase A candidate is captured into a one-entry registered stage before it
  // leaves the LQ. That breaks the issue/data-select cone away from the
  // downstream MEM adapter / CDB wakeup path while preserving ordering.

  always_comb begin
    issue_cdb_result = '0;
    if (issue_cdb_found && !i_flush_all && !i_flush_en) begin
      issue_cdb_result.valid = 1'b1;
      issue_cdb_result.tag   = lq_rob_tag[issue_cdb_idx];

      if (lq_is_fp[issue_cdb_idx]) begin
        if (riscv_pkg::mem_size_e'(lq_size_issue_cdb_rd) == riscv_pkg::MEM_SIZE_DOUBLE) begin
          // FLD: raw 64-bit data (lo + hi from LUTRAM)
          issue_cdb_result.value = {lq_data_hi_rd, lq_data_lo_rd};
        end else begin
          // FLW: NaN-box 32-bit to 64-bit
          issue_cdb_result.value = {32'hFFFF_FFFF, lq_data_lo_rd};
        end
      end else begin
        // INT load: zero-extend XLEN to FLEN
        issue_cdb_result.value = {{(FLEN - XLEN) {1'b0}}, lq_data_lo_rd};
      end
    end
  end

  assign cdb_stage_result_flushed = i_flush_en && cdb_stage_valid &&
      (flush_all_entries || is_younger(
      cdb_stage_data.tag, i_flush_tag, i_rob_head_tag
  ));
  assign cdb_stage_slot_available = !cdb_stage_valid || i_result_accepted;
  assign issue_cdb_fire = issue_cdb_result.valid && cdb_stage_slot_available;

  always_comb begin
    o_fu_complete = '0;
    if (cdb_stage_valid && !i_flush_all && !i_flush_en && !cdb_stage_result_flushed) begin
      o_fu_complete       = cdb_stage_data;
      o_fu_complete.valid = 1'b1;
    end
  end

  // Entry freeing: once the result is captured into the stage, the queue slot
  // can be released. The staged copy now owns the completion payload.
  assign free_entry_en  = issue_cdb_fire;
  assign free_entry_idx = issue_cdb_idx;

  // ===========================================================================
  // Allocation Search
  // ===========================================================================
  // The queue keeps sparse holes after partial flush/free. Search forward from
  // tail_ptr to the next invalid slot instead of trying to compact the tail in
  // the flush cycle.
  // Tree-based free-entry search: find first invalid entry starting from
  // tail_ptr using rotate → tree-priority-encode → add-back, replacing
  // the O(DEPTH) serial scan with O(log2(DEPTH)) logic levels.
  logic [DEPTH-1:0] lq_free_mask;
  logic [DEPTH-1:0] lq_free_rotated;
  logic [IdxWidth-1:0] lq_first_free_offset;
  logic lq_first_free_found;

  assign lq_free_mask = ~lq_valid;

  // Barrel-rotate free mask so tail_ptr maps to index 0
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      lq_free_rotated[i] = lq_free_mask[(32'(i)+32'(tail_ptr[IdxWidth-1:0]))%DEPTH];
    end
  end

  // Tree priority encoder: find lowest-index set bit in rotated mask
  always_comb begin
    lq_first_free_offset = '0;
    lq_first_free_found  = 1'b0;
    for (int i = 0; i < DEPTH; i++) begin
      if (lq_free_rotated[i] && !lq_first_free_found) begin
        lq_first_free_offset = IdxWidth'(i);
        lq_first_free_found  = 1'b1;
      end
    end
  end

  // Add offset back to tail_ptr to get absolute alloc target
  assign alloc_target = tail_ptr + PtrWidth'({1'b0, lq_first_free_offset});

  // ===========================================================================
  // Head Advancement (tree-based find-first-valid from head)
  // ===========================================================================
  // TIMING: Replaced O(DEPTH) serial scan with rotate → tree-priority-encode →
  // add-back (O(log2(DEPTH)) logic levels).  The serial scan created a 16-level
  // chain from lq_valid through the popcount-based empty check and cascaded
  // pointer increments; this tree form cuts it to ~4-5 levels.

  logic [DEPTH-1:0] lq_head_valid_rotated;
  logic [IdxWidth-1:0] lq_head_first_valid_offset;
  logic lq_head_first_valid_found;

  // Barrel-rotate valid mask so head_ptr maps to index 0
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      lq_head_valid_rotated[i] = lq_valid[(32'(i)+32'(head_ptr[IdxWidth-1:0]))%DEPTH];
    end
  end

  // Tree priority encoder: find lowest-index set bit (first valid entry)
  always_comb begin
    lq_head_first_valid_offset = '0;
    lq_head_first_valid_found  = 1'b0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (lq_head_valid_rotated[i] && !lq_head_first_valid_found) begin
        lq_head_first_valid_offset = IdxWidth'(i);
        lq_head_first_valid_found  = 1'b1;
      end
    end
  end

  // Add offset back to head_ptr (when empty: offset=0, head stays put)
  assign head_advance_target = head_ptr + PtrWidth'({1'b0, lq_head_first_valid_offset});

  // ===========================================================================
  // Sequential Logic
  // ===========================================================================

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      head_ptr                  <= '0;
      tail_ptr                  <= '0;
      lq_valid                  <= '0;
      lq_addr_valid             <= '0;
      lq_issued                 <= '0;
      lq_data_valid             <= '0;
      lq_forwarded              <= '0;
      mem_outstanding           <= 1'b0;
      drop_mem_response_pending <= 1'b0;
      sq_check_pending          <= 1'b0;
      sq_check_no_older_store_q <= 1'b0;
      sq_check_phase2           <= 1'b0;
      reservation_valid         <= 1'b0;
      amo_state                 <= AMO_IDLE;
    end else if (i_flush_all) begin
      // Full flush: reset control signals
      head_ptr                  <= '0;
      tail_ptr                  <= '0;
      lq_valid                  <= '0;
      lq_addr_valid             <= '0;
      lq_issued                 <= '0;
      lq_data_valid             <= '0;
      lq_forwarded              <= '0;
      mem_outstanding           <= 1'b0;
      drop_mem_response_pending <= 1'b0;
      sq_check_pending          <= 1'b0;
      sq_check_no_older_store_q <= 1'b0;
      sq_check_phase2           <= 1'b0;
      reservation_valid         <= 1'b0;
      amo_state                 <= AMO_IDLE;
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
        if (sq_check_pending && (flush_all_entries || is_younger(
                sq_check_rob_tag_q, i_flush_tag, i_rob_head_tag
            ))) begin
          sq_check_pending          <= 1'b0;
          sq_check_no_older_store_q <= 1'b0;
          sq_check_phase2           <= 1'b0;
        end
        // Leave tail_ptr unchanged. alloc_target will reuse reclaimed holes
        // after the flush instead of compacting the tail in this cycle.
      end

      // -----------------------------------------------------------------
      // Allocation: write new entry at tail (control signals only;
      // data signals written in dedicated no-reset always_ff blocks)
      // -----------------------------------------------------------------
      if (i_alloc.valid && !full) begin
        lq_valid[alloc_target[IdxWidth-1:0]]      <= 1'b1;
        lq_addr_valid[alloc_target[IdxWidth-1:0]] <= 1'b0;
        lq_issued[alloc_target[IdxWidth-1:0]]     <= 1'b0;
        lq_data_valid[alloc_target[IdxWidth-1:0]] <= 1'b0;
        lq_forwarded[alloc_target[IdxWidth-1:0]]  <= 1'b0;
        tail_ptr                                  <= alloc_target + PtrWidth'(1);
      end

      // -----------------------------------------------------------------
      // Address Update: CAM search for matching rob_tag (control only;
      // data signals written in dedicated no-reset always_ff blocks)
      // -----------------------------------------------------------------
      if (lq_addr_update_we) begin
        lq_addr_valid[lq_addr_update_idx] <= 1'b1;
      end

      if (sq_check_capture || sq_check_replace) begin
        sq_check_pending          <= 1'b1;
        sq_check_no_older_store_q <= i_sq_empty;
        sq_check_phase2           <= i_sq_empty;
      end else if (sq_check_pending &&
                   (!sq_check_entry_valid || cache_hit_fast_path || sq_do_forward ||
                    launch_mem_issue)) begin
        // launch_mem_issue (was stage_mem_issue) ensures the slot is held
        // through bus_busy stalls so the staged candidate is not lost when
        // stage_mem_issue fires but the launch is gated this cycle.
        sq_check_pending          <= 1'b0;
        sq_check_no_older_store_q <= 1'b0;
        sq_check_phase2           <= 1'b0;
      end else if (sq_check_pending && !sq_check_phase2 && i_sq_empty) begin
        sq_check_phase2 <= 1'b1;
      end else if (o_sq_check_valid && !sq_check_phase2) begin
        sq_check_phase2 <= 1'b1;
      end

      // -----------------------------------------------------------------
      // L0 Cache Hit Fast Path: SQ confirmed no conflict, use cached data
      // -----------------------------------------------------------------
      if (cache_hit_fast_path) begin
        lq_data_valid[sq_check_idx] <= 1'b1;
      end

      // -----------------------------------------------------------------
      // Store forwarding: write data directly, skip memory
      // -----------------------------------------------------------------
      if (sq_do_forward) begin
        lq_data_valid[sq_check_idx] <= 1'b1;
        lq_forwarded[sq_check_idx]  <= 1'b1;
      end

      // -----------------------------------------------------------------
      // Memory Response: capture data from memory bus
      // -----------------------------------------------------------------
      // Stale response drain: partial flushes can kill an outstanding load one
      // cycle before the data returns. Drop that response explicitly.
      // ORDERING: this block runs BEFORE the o_mem_read_en block so a same-
      // cycle launch+response (back-to-back issue) lets the launch override
      // mem_outstanding<=1 instead of being clobbered to 0 by the response.
      if (drop_mem_response_now) begin
        mem_outstanding <= 1'b0;
        drop_mem_response_pending <= 1'b0;
      end else if (accept_mem_response) begin
        if (lq_is_amo[issued_idx]) begin
          // AMO: start write phase (don't set data_valid yet);
          // data signals (amo_old_value, amo_entry_idx) in no-reset block
          amo_state       <= AMO_WRITE_ACTIVE;
          mem_outstanding <= 1'b0;
        end else if (lq_is_lr[issued_idx]) begin
          // LR: data captured by LUTRAM write logic;
          // reservation_addr in no-reset block
          lq_data_valid[issued_idx] <= 1'b1;
          mem_outstanding           <= 1'b0;
          reservation_valid         <= 1'b1;
        end else if (lq_is_fp[issued_idx] &&
            riscv_pkg::mem_size_e'(lq_size_issued_rd) == riscv_pkg::MEM_SIZE_DOUBLE &&
            !lq_fp64_phase[issued_idx]) begin
          // FLD phase 0: re-issue for phase 1;
          // lq_fp64_phase in no-reset block
          lq_issued[issued_idx] <= 1'b0;  // Re-issue for phase 1
          mem_outstanding       <= 1'b0;
        end else if (lq_is_fp[issued_idx] &&
                     riscv_pkg::mem_size_e'(lq_size_issued_rd) == riscv_pkg::MEM_SIZE_DOUBLE &&
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
      // Memory Issue: mark entry as issued, track for response routing
      // -----------------------------------------------------------------
      // Placed AFTER the response block so a same-cycle launch+response
      // (back-to-back issue) sets mem_outstanding=1 (override) and updates
      // issued_idx to point at the freshly-launched entry for next cycle's
      // response. Different lq_issued indices on launch vs. response keep
      // their bit-level writes independent.
      if (o_mem_read_en) begin
        lq_issued[launch_mem_issue_idx] <= 1'b1;
        mem_outstanding                 <= 1'b1;
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
  // Data-Only Sequential Logic (no reset sensitivity)
  // ===========================================================================
  // These signals are pure data payloads whose consumers are already gated by
  // control-valid bits (lq_valid, lq_addr_valid, lq_data_valid, sq_check_pending,
  // mem_outstanding, reservation_valid, amo_state, etc.) that ARE reset.
  // Keeping data FFs out of the reset tree saves area, power, and fanout on
  // the reset net.

  // -----------------------------------------------------------------
  // Per-entry data: allocation writes
  // -----------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (i_alloc.valid && !full) begin
      lq_rob_tag[alloc_target[IdxWidth-1:0]]    <= i_alloc.rob_tag;
      lq_is_fp[alloc_target[IdxWidth-1:0]]      <= i_alloc.is_fp;
      lq_sign_ext[alloc_target[IdxWidth-1:0]]   <= i_alloc.sign_ext;
      lq_fp64_phase[alloc_target[IdxWidth-1:0]] <= 1'b0;
      lq_is_lr[alloc_target[IdxWidth-1:0]]      <= i_alloc.is_lr;
      lq_is_amo[alloc_target[IdxWidth-1:0]]     <= i_alloc.is_amo;
    end
    // FLD phase advance: set phase 1 after phase 0 memory response
    if (accept_mem_response && lq_is_fp[issued_idx] &&
        riscv_pkg::mem_size_e'(lq_size_issued_rd) == riscv_pkg::MEM_SIZE_DOUBLE &&
        !lq_fp64_phase[issued_idx]) begin
      lq_fp64_phase[issued_idx] <= 1'b1;
    end
  end

  // -----------------------------------------------------------------
  // Per-entry data: address update writes
  // -----------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (lq_addr_update_we) begin
      lq_is_mmio[lq_addr_update_idx] <= i_addr_update.is_mmio;
    end
  end

  // -----------------------------------------------------------------
  // Internal data: SQ check candidate index
  // -----------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (sq_check_capture || sq_check_replace) begin
      sq_check_idx          <= issue_mem_idx;
      sq_check_rob_tag_q    <= issue_mem_rob_tag;
      sq_check_addr_q       <= lq_address_issue_mem_rd;
      sq_check_size_q       <= riscv_pkg::mem_size_e'(lq_size_issue_mem_rd);
      sq_check_is_fp_q      <= lq_is_fp[issue_mem_idx];
      sq_check_sign_ext_q   <= lq_sign_ext[issue_mem_idx];
      sq_check_is_mmio_q    <= lq_is_mmio[issue_mem_idx];
      sq_check_fp64_phase_q <= lq_fp64_phase[issue_mem_idx];
      sq_check_is_lr_q      <= lq_is_lr[issue_mem_idx];
      sq_check_is_amo_q     <= lq_is_amo[issue_mem_idx];
    end
  end

  // -----------------------------------------------------------------
  // Internal data: issued entry tracker
  // -----------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (o_mem_read_en) begin
      issued_idx <= launch_mem_issue_idx;
    end
  end

  // -----------------------------------------------------------------
  // Internal data: AMO old value and entry index
  // -----------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (accept_mem_response && lq_is_amo[issued_idx]) begin
      amo_old_value <= i_mem_read_data;
      amo_entry_idx <= issued_idx;
    end
  end

  // -----------------------------------------------------------------
  // Internal data: reservation address
  // -----------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (accept_mem_response && lq_is_lr[issued_idx]) begin
      reservation_addr <= lq_address_issued_rd;
    end
  end

  // -----------------------------------------------------------------
  // Internal data: CDB completion stage result
  // -----------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      cdb_stage_valid <= 1'b0;
    end else if (issue_cdb_fire) begin
      cdb_stage_valid <= 1'b1;
    end else if (i_result_accepted || cdb_stage_result_flushed) begin
      cdb_stage_valid <= 1'b0;
    end
  end

  always_ff @(posedge i_clk) begin
    if (issue_cdb_fire) begin
      cdb_stage_data.tag       <= issue_cdb_result.tag;
      cdb_stage_data.value     <= issue_cdb_result.value;
      cdb_stage_data.exception <= issue_cdb_result.exception;
      cdb_stage_data.exc_cause <= issue_cdb_result.exc_cause;
      cdb_stage_data.fp_flags  <= issue_cdb_result.fp_flags;
    end
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

  // Address updates MAY arrive during flush (RS stage2 issues without
  // same-cycle flush gating for timing closure).  This is safe:
  //   - flush_all: lq_valid is bulk-cleared; the CAM match
  //     (lq_valid[i] && ...) prevents any write to a flushed slot.
  //     Data writes are in a no-reset block but are harmless behind
  //     invalid entries.
  //   - flush_en: CAM matches only entries with lq_valid[i]==1; entries
  //     whose valid is being cleared on the same edge get a harmless
  //     address write into a dead slot.
  // (assumption removed — was: no addr_update during flush)

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

  // If all entries are valid, the buffer must report full.
  always_comb begin
    if (i_rst_n) begin
      p_all_valid_implies_full : assert (f_valid_count < CountWidth'(DEPTH) || o_full);
    end
  end

  // No memory issue without addr_valid
  always_comb begin
    if (i_rst_n && o_mem_read_en) begin
      p_no_mem_issue_without_addr : assert (lq_addr_valid[launch_mem_issue_idx]);
    end
  end

  // No memory issue for already-issued entries
  always_comb begin
    if (i_rst_n && o_mem_read_en) begin
      p_no_mem_issue_when_issued : assert (!lq_issued[launch_mem_issue_idx]);
    end
  end

  // MMIO entries only issue when rob_tag == i_rob_head_tag
  always_comb begin
    if (i_rst_n && o_sq_check_valid && sq_check_is_mmio_q) begin
      p_mmio_only_at_head : assert (sq_check_rob_tag_q == i_rob_head_tag);
    end
  end

  // SQ check valid implies valid address on check ports
  always_comb begin
    if (i_rst_n && o_sq_check_valid) begin
      p_sq_check_valid_has_addr : assert (lq_addr_valid[sq_check_idx]);
    end
  end

  // Captured completion tag matches the selected valid entry's rob_tag
  always_comb begin
    if (i_rst_n && issue_cdb_fire) begin
      p_fu_complete_tag_matches : assert (issue_cdb_result.tag == lq_rob_tag[issue_cdb_idx]);
    end
  end

  // Captured completion requires the selected entry to have data_valid
  always_comb begin
    if (i_rst_n && issue_cdb_fire) begin
      p_fu_complete_needs_data : assert (lq_data_valid[issue_cdb_idx]);
    end
  end

  // A staged result can only be consumed when the wrapper reports acceptance.
  always_comb begin
    if (i_rst_n && i_result_accepted) begin
      p_result_accept_needs_valid : assert (o_fu_complete.valid);
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
        p_alloc_advances_tail : assert (lq_valid[$past(alloc_target[IdxWidth-1:0])]);
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
