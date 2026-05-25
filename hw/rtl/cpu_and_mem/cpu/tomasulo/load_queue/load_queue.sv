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
 *   data_valid, issued, is_lr, is_amo, rob_tag, size, etc.) remain in
 *   FFs for CAM-style parallel tag search (matched on rob_tag), per-entry
 *   invalidation, and oldest-first priority scan.
 *   The load address (sdp_dist_ram) and load-result payload lq_data
 *   (mwp_dist_ram, split lo/hi for FLD partial writes, 2 write ports
 *   for primary + AMO overlap) live in distributed RAM.  Valid bits in
 *   FFs gate all reads; stale LUTRAM data behind flushed entries is harmless.
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
    // Slot-2 allocation port for 2-wide dispatch.  Slot-2 valid does NOT
    // require slot-1 valid: the dispatch unit derives each from its own slot's
    // mem_needs_lq, so it is legal for only slot-2 to be a load.
    input  riscv_pkg::lq_alloc_req_t i_alloc_2,
    output logic                     o_full,
    // Asserted when there is room for at most 1 more entry (a 2-wide dispatch
    // bundle of two loads would not fit).  Distinct from o_full so dispatch can
    // independently gate slot-2.
    output logic                     o_full_for_2,
    // Registered back-pressure for the CPU dispatch path.
    // Exact o_full/o_full_for_2 stay available for local visibility and direct
    // queue allocation; these outputs are exact after the same edge that
    // updates the valid mask.
    output logic                     o_dispatch_full,
    output logic                     o_dispatch_full_for_2,

    // =========================================================================
    // Address Update (from MEM_RS issue path: base + imm, pre-computed)
    // =========================================================================
    input riscv_pkg::lq_addr_update_t i_addr_update,

    // Pre-issue look-ahead from MEM_RS (1 cycle before i_addr_update fires).
    // Used to pre-compute the addr_update CAM match and register it, so
    // entry_addr_valid_now is only 2 LUT levels deep at issue time.
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_pre_issue_rob_tag,
    input logic                                        i_pre_issue_needs_lq,

    // =========================================================================
    // Store Queue Disambiguation (combinational handshake)
    // =========================================================================
    output logic o_sq_check_valid,
    output logic [riscv_pkg::XLEN-1:0] o_sq_check_addr,
    // Second replica of o_sq_check_addr — drives the upper half of the SQ
    // disambiguation CAM (entries 4..7).  Splitting the address broadcast
    // across two anchor FFs lets the placer spread the per-entry compare
    // CARRY8 chains across two physical regions instead of cramming them
    // all around a single source.  Replica register lives in LQ under a
    // dont_touch attribute so opt_design -merge_equivalent_drivers cannot
    // fold it back into o_sq_check_addr.  Functionally identical value.
    output logic [riscv_pkg::XLEN-1:0] o_sq_check_addr_b,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_sq_check_rob_tag,
    output riscv_pkg::mem_size_e o_sq_check_size,
    input logic i_sq_all_older_addrs_known,
    input riscv_pkg::sq_forward_result_t i_sq_forward,

    // =========================================================================
    // Memory Interface (to data memory bus)
    // =========================================================================
    output logic                                       o_mem_read_en,
    output logic                                       o_mem_addr_valid,
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
    input logic i_trap_misaligned_accesses,

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
    output logic                       o_dispatch_empty,
    output logic [$clog2(DEPTH+1)-1:0] o_count,
    output logic [$clog2(DEPTH+1)-1:0] o_dispatch_count,

    // =========================================================================
    // L0 Cache Profile Pulses (one cycle each, for perf counters)
    // =========================================================================
    output logic o_l0_hit,  // L0 cache fast-path completion
    output logic o_l0_fill,  // L0 cache fill from memory response
    output logic o_mem_outstanding,  // LQ has a memory response in flight

    // =========================================================================
    // Head-load sub-bucket diagnostics (split head_wait_load_no_outstanding)
    // =========================================================================
    // Combinational indicators describing the state of the LQ entry matching
    // i_rob_head_tag (if any). Mutually exclusive — wrapper ANDs each with
    // (head_wait_mem_load && !mem_outstanding) to get the sub-bucket counters.
    output logic o_head_load_addr_pending,  // matches head_tag, addr not yet computed
    output logic o_head_load_sq_disambig,   // ready, blocked on SQ disambig
    output logic o_head_load_bus_blocked,   // ready, blocked on bus / arbitration / pipeline
    output logic o_head_load_cdb_wait,      // data ready in LQ, waiting to enter cdb_stage
    output logic o_head_load_post_lq,       // LQ entry already freed, CDB pipeline to ROB

    // =========================================================================
    // Bus-blocked sub-bucket diagnostics
    // =========================================================================
    // Split `o_head_load_bus_blocked` (the 7.7% remainder bucket) into
    // mutually exclusive sub-causes, picked in priority order so each cycle
    // contributes to exactly one counter.  All five are gated externally by
    // the same `head_wait_mem_load && !mem_outstanding` term the parent
    // counter uses, so the sum across sub-buckets equals `bus_blocked`.
    output logic o_head_load_bb_issued,    // head has been issued, waiting for response
    output logic o_head_load_bb_bus_busy,  // i_mem_bus_busy = 1
    output logic o_head_load_bb_amo,       // older AMO pending (blocked_by_amo prefix OR)
    output logic o_head_load_bb_sq_wait,   // in sq_check stage but !sq_check_phase2
    output logic o_head_load_bb_staging    // catch-all (pre-sq_check capture, drop-pending, etc.)
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
  // Keep these literal for Yosys, which does not parse $bits(package::enum) reliably.
  // instr_op_e is an untyped enum (default int), and mem_size_e is logic [1:0].
  localparam int unsigned InstrOpWidth = 32;
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

  function automatic logic [DEPTH-1:0] rotate_mask_from_head(input logic [DEPTH-1:0] mask,
                                                             input logic [IdxWidth-1:0] start_idx);
    logic [(2*DEPTH)-1:0] doubled;
    logic [(2*DEPTH)-1:0] shifted;
    begin
      doubled = {mask, mask};
      shifted = doubled >> start_idx;
      rotate_mask_from_head = shifted[DEPTH-1:0];
    end
  endfunction

  function automatic logic is_load_misaligned(input riscv_pkg::mem_size_e size,
                                              input logic [XLEN-1:0] addr);
    unique case (size)
      riscv_pkg::MEM_SIZE_HALF:   is_load_misaligned = addr[0];
      riscv_pkg::MEM_SIZE_WORD:   is_load_misaligned = |addr[1:0];
      riscv_pkg::MEM_SIZE_DOUBLE: is_load_misaligned = |addr[2:0];
      default:                    is_load_misaligned = 1'b0;
    endcase
  endfunction

  // ===========================================================================
  // Storage -- Circular buffer with FF-based control plus LUTRAM payloads
  // ===========================================================================

  // Head and tail pointers (extra MSB for full/empty distinction)
  logic [             PtrWidth-1:0] head_ptr;
  logic [             PtrWidth-1:0] tail_ptr;

  // Index extraction (lower bits)
  wire  [             IdxWidth-1:0] head_idx = head_ptr[IdxWidth-1:0];
  // Per-entry 1-bit flags (packed vectors for bulk operations)
  logic [                DEPTH-1:0] lq_valid;
  logic [                DEPTH-1:0] lq_is_fp;
  logic [                DEPTH-1:0] lq_addr_valid;
  logic [                DEPTH-1:0] lq_sign_ext;
  logic [                DEPTH-1:0] lq_is_mmio;
  logic [                DEPTH-1:0] lq_fp64_phase;
  logic [                DEPTH-1:0] lq_issued;
  logic [                DEPTH-1:0] lq_data_valid;
  logic [                DEPTH-1:0] lq_forwarded;
  logic [                DEPTH-1:0] lq_is_lr;
  logic [                DEPTH-1:0] lq_is_amo;

  // Per-entry multi-bit fields
  logic [ReorderBufferTagWidth-1:0] lq_rob_tag                        [DEPTH];
  logic [         InstrOpWidth-1:0] lq_amo_op_rd;
  (* ram_style = "registers" *)
  logic [         MemSizeWidth-1:0] lq_size                           [DEPTH];
  logic [         MemSizeWidth-1:0] lq_size_issue_cdb_rd;
  logic [                 XLEN-1:0] lq_address_issue_mem_rd;
  logic [                 XLEN-1:0] lq_address_amo_rd;
  logic [                 XLEN-1:0] lq_amo_rs2_rd;
  logic [             IdxWidth-1:0] amo_entry_idx;
  logic                             full;
  logic                             full_for_2;

  // Slot-1 / slot-2 alloc targets and write enables.  alloc_target points at
  // the first free slot from tail_ptr; alloc_target_2 points at the second
  // free slot.  When slot-1 is invalid but slot-2 is, slot-2 takes alloc_target.
  logic [             PtrWidth-1:0] alloc_target_2;
  logic                             slot1_alloc_en;
  logic                             slot2_alloc_en;
  logic [             IdxWidth-1:0] slot2_alloc_idx;

  // Forward declarations: slot1_alloc_en / slot2_alloc_en assignments come
  // after alloc_target_2 / full_for_2 are computed; the LUTRAM block needs
  // both write enables here.
  // AMO op is written once at allocation and only read back for AMO execution.
  // 2 write ports: slot-1 alloc (port 0) + slot-2 alloc (port 1).  Port 1
  // writes when a slot-2 load allocates in the same cycle as slot-1.
  mwp_dist_ram #(
      .ADDR_WIDTH     (IdxWidth),
      .DATA_WIDTH     (InstrOpWidth),
      .NUM_WRITE_PORTS(2)
  ) u_lq_amo_op (
      .i_clk,
      .i_write_enable ({slot2_alloc_en, slot1_alloc_en}),
      .i_write_address({slot2_alloc_idx, alloc_target[IdxWidth-1:0]}),
      .i_write_data   ({i_alloc_2.amo_op, i_alloc.amo_op}),
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
  logic dispatch_full_q;
  logic dispatch_full_for_2_q;
  logic [CountWidth-1:0] dispatch_count_next;

  // Issue selection
  logic issue_cdb_found;  // Phase A: entry with data_valid
  // issue_cdb_idx declared above (before LUTRAM instances)
  logic issue_mem_found;  // Phase B: entry ready for memory
  logic [IdxWidth-1:0] issue_mem_idx;
  logic [IdxWidth-1:0] issue_mem_stored_idx;
  logic issue_mem_from_update;
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
  // max_fanout: drives ~170 destinations in the SQ disambiguation CAM
  // (per-entry addr compare + byte-mask + age qualification + cross-entry
  // reduction).  Single-source FF was the lone -0.178 ns post-synth path
  // on x3 with ~70% routing dominance.  Replicate per fanout=16 so each
  // copy lives near a small cluster of SQ-side consumers.  Pair with the
  // sq_check_addr_q_b port-split replica (drives entries 4..7 in the SQ);
  // sq_check_addr_q now drives entries 0..3.
  (* max_fanout = 16 *) logic [XLEN-1:0] sq_check_addr_q;
  // Port-split replica: same D/CE as sq_check_addr_q.  dont_touch + keep so
  // opt_design's -merge_equivalent_drivers cannot fold this back into
  // sq_check_addr_q.  Drives the upper-half of the SQ CAM via the
  // o_sq_check_addr_b port, giving the placer a second anchor point for
  // the CARRY8 chains and per-entry compare LUTs.
  (* dont_touch = "true", keep = "true", max_fanout = 16 *)
  logic [XLEN-1:0] sq_check_addr_q_b;
  riscv_pkg::mem_size_e sq_check_size_q;
  logic sq_check_is_fp_q;
  logic sq_check_sign_ext_q;
  logic sq_check_is_mmio_q;
  logic sq_check_fp64_phase_q;
  logic sq_check_is_lr_q;
  logic sq_check_is_amo_q;
  logic sq_check_no_older_store_q;
  logic [DEPTH-1:0] sq_check_in_flight_mask;
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
  // Flat snapshot of the issued entry's per-entry attributes, captured at
  // launch time. Replaces lq_*[issued_idx] reads (and the lq_address_issued /
  // lq_size_issued LUTRAM lookups) in the response handler so the long
  //   issued_idx → lq_*_rd → cache_fill_addr (+4 add) → lq_l0_cache lookup
  //   → cache_hit_fast_path → o_mem_read_en → data_memory ADDRARDADDR
  // cone is broken at its source. The values are stable across all cycles the
  // load is outstanding (allocation-/addr-update-time fields don't change once
  // set; sq_check_*_q already encodes the right phase for FLD).
  logic [XLEN-1:0] issued_addr;
  logic [MemSizeWidth-1:0] issued_size;
  logic issued_is_fp;
  logic issued_is_lr;
  logic issued_is_amo;
  logic issued_is_mmio;
  logic issued_sign_ext;
  logic issued_fp64_phase;
  logic [ReorderBufferTagWidth-1:0] issued_rob_tag;
  logic drop_mem_response_pending;  // Drop the next 1-cycle-latency response after flush

  // Load unit wires
  logic [XLEN-1:0] lu_data_out;

  // Response acceptance/drain control
  logic flush_all_entries;
  logic issued_entry_flushed;
  logic accept_mem_response;
  logic drop_mem_response_now;

  // Entry freeing
  logic free_entry_en;
  logic [IdxWidth-1:0] free_entry_idx;

  // Head/tail search targets for the sparse valid-bit queue.
  logic [PtrWidth-1:0] head_advance_target;
  logic [PtrWidth-1:0] alloc_target;
  logic [DEPTH-1:0] lq_addr_update_match;
  logic lq_addr_update_we;
  logic [IdxWidth-1:0] lq_addr_update_idx;

  // lq_size is tiny and sits on the sq_check staging path, so keep it in FFs
  // instead of adding another LUTRAM read cone.
  assign lq_size_issue_cdb_rd = lq_size[issue_cdb_idx];

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
      .i_read_address (issue_mem_stored_idx),
      .o_read_data    (lq_address_issue_mem_rd)
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
  // Exact local occupancy remains a live popcount so direct queue behavior
  // recovers immediately after sparse partial flushes. Dispatch back-pressure
  // accounts for same-cycle allocation/free as a small count delta instead of
  // rebuilding the whole next valid mask and popcounting it again. Partial
  // flush clears are intentionally not included here: ignoring them can only
  // leave dispatch back-pressure asserted for an extra cycle after recovery,
  // and keeps ROB-head/flush-age logic out of these status flops.
  always_comb begin
    count = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      count = count + CountWidth'(lq_valid[i]);
    end
  end

  assign full = (count == CountWidth'(DEPTH));
  // full_for_2: room for at most 1 more entry, so a 2-wide bundle of two loads
  // would not fit even if neither slot has been allocated yet.
  assign full_for_2 = full || (count == CountWidth'(DEPTH - 1));
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
  // valid (slot-1 might be a non-mem instruction), but if both are valid,
  // slot-1 takes the first free slot and slot-2 takes the second.
  assign slot1_alloc_en = i_alloc.valid && !full;
  assign slot2_alloc_en = i_alloc_2.valid && (slot1_alloc_en ? !full_for_2 : !full);
  assign slot2_alloc_idx = slot1_alloc_en ? alloc_target_2[IdxWidth-1:0]
                                          : alloc_target[IdxWidth-1:0];

  always_comb begin
    dispatch_count_next = count + CountWidth'(slot1_alloc_en) + CountWidth'(slot2_alloc_en) -
                          CountWidth'(free_entry_en);
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

  // ---------------------------------------------------------------------------
  // Address-update CAM match: current-cycle (for flop writes) and
  // pre-computed registered version (for the same-cycle issue bypass).
  //
  // TIMING: The issue scan + sq_check_capture path had a 16-level
  // combinational chain when lq_addr_update_match was computed live at
  // issue time.  The pre-match registers the CAM result one cycle early
  // using the MEM_RS pre-issue look-ahead (rob_tag + needs_lq available
  // at T-1, before stage2 fires at T).  At T, entry_addr_valid_now is
  // only 2 LUT levels deep: registered pre-match AND'd with the actual
  // issue valid, OR'd with the registered lq_addr_valid.
  // ---------------------------------------------------------------------------

  // Current-cycle match: used for lq_addr_valid / lq_address flop writes.
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      lq_addr_update_match[i] = i_addr_update.valid &&
                                lq_valid[i] &&
                                !lq_addr_valid[i] &&
                                (lq_rob_tag[i] == i_addr_update.rob_tag);
    end
  end

  always_comb begin
    lq_addr_update_we  = 1'b0;
    lq_addr_update_idx = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (lq_addr_update_match[i]) begin
        lq_addr_update_we  = 1'b1;
        lq_addr_update_idx = IdxWidth'(i);
      end
    end
  end

  // Pre-computed CAM match: registered 1 cycle early from MEM_RS look-ahead.
  logic [DEPTH-1:0] addr_update_pre_match;
  logic [DEPTH-1:0] addr_update_pre_match_q;

  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      addr_update_pre_match[i] = i_pre_issue_needs_lq &&
                                 lq_valid[i] &&
                                 !lq_addr_valid[i] &&
                                 (lq_rob_tag[i] == i_pre_issue_rob_tag);
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) addr_update_pre_match_q <= '0;
    else addr_update_pre_match_q <= addr_update_pre_match;
  end

  // Head-priority is only a fairness/performance hint for ordinary loads; the
  // exact live ROB-head checks remain in the eligibility masks for MMIO/LR/AMO.
  // Registering the hint keeps lq_rob_tag compares out of the SQ-check payload
  // address capture cone.
  logic [DEPTH-1:0] rob_head_match_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      rob_head_match_q <= '0;
    end else begin
      for (int unsigned i = 0; i < DEPTH; i++) begin
        rob_head_match_q[i] <= lq_valid[i] && (lq_rob_tag[i] == i_rob_head_tag);
      end
    end
  end

  // Same-cycle addr bypass: uses the REGISTERED pre-match gated by the
  // actual issue valid (2 LUT levels from flops).
  logic [DEPTH-1:0] entry_addr_valid_now;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      entry_addr_valid_now[i] = lq_addr_valid[i] ||
                                (addr_update_pre_match_q[i] && i_addr_update.valid);
    end
  end

  // ===========================================================================
  // Issue Selection -> lq_issue_selector.sv (pure boundary move).  issue_cdb_idx
  // still drives the LQ data LUTRAM read below; that RAM stays here.
  // ===========================================================================
  logic [DEPTH-1:0] mem_issue_stored_mask;
  logic [DEPTH-1:0] mem_issue_update_mask;
  logic head_mem_stored_found;
  logic [IdxWidth-1:0] head_mem_stored_idx;
  logic [ReorderBufferTagWidth-1:0] head_mem_stored_rob_tag;
  logic head_mem_update_found;
  logic [IdxWidth-1:0] head_mem_update_idx;
  logic [ReorderBufferTagWidth-1:0] head_mem_update_rob_tag;
  logic [DEPTH*ReorderBufferTagWidth-1:0] lq_rob_tag_flat;

  for (genvar g_lq_tag = 0; g_lq_tag < DEPTH; g_lq_tag++) begin : gen_lq_rob_tag_flat
    assign lq_rob_tag_flat[g_lq_tag*ReorderBufferTagWidth +: ReorderBufferTagWidth] =
        lq_rob_tag[g_lq_tag];
  end

  lq_issue_selector #(
      .DEPTH(DEPTH)
  ) lq_issue_selector_inst (
      .lq_valid(lq_valid),
      .lq_addr_valid(lq_addr_valid),
      .lq_is_mmio(lq_is_mmio),
      .lq_issued(lq_issued),
      .lq_data_valid(lq_data_valid),
      .lq_is_lr(lq_is_lr),
      .lq_is_amo(lq_is_amo),
      .sq_check_in_flight_mask(sq_check_in_flight_mask),
      .addr_update_pre_match_q(addr_update_pre_match_q),
      .rob_head_match_q(rob_head_match_q),
      .lq_rob_tag_flat(lq_rob_tag_flat),
      .head_idx(head_idx),
      .i_sq_committed_empty(i_sq_committed_empty),
      .o_issue_cdb_found(issue_cdb_found),
      .o_issue_cdb_idx(issue_cdb_idx),
      .o_mem_issue_stored_mask(mem_issue_stored_mask),
      .o_mem_issue_update_mask(mem_issue_update_mask),
      .o_head_mem_stored_found(head_mem_stored_found),
      .o_head_mem_stored_idx(head_mem_stored_idx),
      .o_head_mem_stored_rob_tag(head_mem_stored_rob_tag),
      .o_head_mem_update_found(head_mem_update_found),
      .o_head_mem_update_idx(head_mem_update_idx),
      .o_head_mem_update_rob_tag(head_mem_update_rob_tag)
  );

  // scan_idx recomputed locally for the head-load diagnostics below; the
  // selector computes its own identical copy internally (head-relative idx).
  logic [IdxWidth-1:0] scan_idx[DEPTH];
  always_comb begin
    for (int unsigned j = 0; j < DEPTH; j++) begin
      scan_idx[j] = IdxWidth'(head_idx + IdxWidth'(j));
    end
  end

  // ===========================================================================
  // Head-load sub-bucket diagnostics
  // ===========================================================================
  // Locate the LQ entry whose rob_tag matches the ROB head (if any) and
  // describe its state.  tomasulo_wrapper gates each output with the parent
  // `head_wait_mem_load && !mem_outstanding` signal so these only fire during
  // the 27.7% bucket — here we just reflect the LQ-internal state.
  logic head_entry_found;
  logic [IdxWidth-1:0] head_entry_idx;
  always_comb begin
    head_entry_found = 1'b0;
    head_entry_idx   = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (!head_entry_found && lq_valid[i] && (lq_rob_tag[i] == i_rob_head_tag)) begin
        head_entry_found = 1'b1;
        head_entry_idx   = IdxWidth'(i);
      end
    end
  end

  logic head_entry_addr_valid;
  logic head_entry_issued;
  logic head_entry_data_valid;
  assign head_entry_addr_valid = head_entry_found && entry_addr_valid_now[head_entry_idx];
  assign head_entry_issued     = head_entry_found && lq_issued[head_entry_idx];
  assign head_entry_data_valid = head_entry_found && lq_data_valid[head_entry_idx];

  // SQ disambig is blocking the head load when the staged sq_check candidate
  // points at the head entry AND the SQ has unresolved older stores.  The
  // check is against the *registered* sq_check state so this lags the raw
  // issue_mem_found path by one cycle — consistent with how the load would
  // actually progress through the machine.
  logic head_sq_disambig_blocker;
  assign head_sq_disambig_blocker = sq_check_pending &&
                                    (sq_check_rob_tag_q == i_rob_head_tag) &&
                                    o_sq_check_valid &&
                                    !i_sq_all_older_addrs_known;

  logic head_sq_disambig_hit;
  assign head_sq_disambig_hit  = head_entry_found && head_entry_addr_valid &&
                                 !head_entry_data_valid && !head_entry_issued &&
                                 head_sq_disambig_blocker;

  assign o_head_load_addr_pending = head_entry_found && !head_entry_addr_valid;
  assign o_head_load_sq_disambig = head_sq_disambig_hit;
  // "bus blocked" = address is resolved and the data isn't ready yet, but the
  // blocker is NOT an SQ disambig.  Covers bus-busy stalls, pre-sq_check
  // staging cycles, AMO/SQ-committed blockers, and drop-response edge cases.
  assign o_head_load_bus_blocked  = head_entry_found && head_entry_addr_valid &&
                                    !head_entry_data_valid && !head_sq_disambig_hit;
  assign o_head_load_cdb_wait = head_entry_found && head_entry_data_valid;
  // "post-LQ" = head load is still !done in ROB but its LQ entry has already
  // been freed (issue_cdb_fire clears lq_valid the cycle cdb_stage captures
  // the result).  Covers the 2-3 cycles between LQ free and rob_done going
  // high: cdb_stage -> mem_adapter -> cdb_arbiter -> rob_done.  This is a
  // pure pipeline drain — shortening it requires collapsing the CDB path.
  assign o_head_load_post_lq = !head_entry_found;

  // -------------------------------------------------------------------------
  // Bus-blocked sub-bucket classification
  // -------------------------------------------------------------------------
  // Priority-ordered (mutually exclusive per cycle):
  //   1. issued   — head already launched, waiting for mem response but
  //                 mem_outstanding=0 (happens in the edge window where the
  //                 response was accepted but lq_valid hasn't been cleared)
  //   2. bus_busy — i_mem_bus_busy = 1 (SQ/AMO write or backend recovery hold)
  //   3. amo      — older valid AMO in the LQ with !data_valid
  //                 (any_pending_amo is an approximation: we don't check the
  //                 precise scan order, but in practice an AMO older than
  //                 the head load is the only reason it would block).  This
  //                 also catches the SQ-committed-empty gate for AMOs at head.
  //   4. sq_wait  — entry is currently staged in sq_check but !sq_check_phase2
  //                 (sq_check_phase2 takes a cycle to arm after the SQ sees
  //                 an empty committed queue).
  //   5. staging  — everything else (one-cycle addr_valid → sq_check_capture
  //                 delay, drop_mem_response_pending, sq-committed-empty gate
  //                 on non-AMO MMIO loads, etc.)

  logic head_entry_bb_base;
  assign head_entry_bb_base = head_entry_found && head_entry_addr_valid &&
                              !head_entry_data_valid && !head_sq_disambig_hit;

  // Approximation: any pending (valid, AMO, not data-valid) LQ entry.  In
  // practice the AMO would be older than the head load — if it were younger
  // the head load would have already issued.  Good enough for a diagnostic.
  logic any_pending_amo;
  always_comb begin
    any_pending_amo = 1'b0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (lq_valid[i] && lq_is_amo[i] && !lq_data_valid[i]) begin
        any_pending_amo = 1'b1;
      end
    end
  end

  logic head_entry_in_sq_wait;
  assign head_entry_in_sq_wait = sq_check_pending &&
                                 (sq_check_idx == head_entry_idx) &&
                                 !sq_check_phase2;

  assign o_head_load_bb_issued = head_entry_bb_base && head_entry_issued;
  assign o_head_load_bb_bus_busy = head_entry_bb_base && !head_entry_issued && i_mem_bus_busy;
  assign o_head_load_bb_amo      = head_entry_bb_base && !head_entry_issued &&
                                   !i_mem_bus_busy && any_pending_amo;
  assign o_head_load_bb_sq_wait  = head_entry_bb_base && !head_entry_issued &&
                                   !i_mem_bus_busy && !any_pending_amo &&
                                   head_entry_in_sq_wait;
  assign o_head_load_bb_staging  = head_entry_bb_base && !head_entry_issued &&
                                   !i_mem_bus_busy && !any_pending_amo &&
                                   !head_entry_in_sq_wait;

  // ROB tag of the winning Phase B entry (extracted alongside idx to avoid
  // a post-encoder 8-to-1 MUX on lq_rob_tag[issue_mem_idx])
  logic [ReorderBufferTagWidth-1:0] issue_mem_rob_tag;

  logic stored_scan_found;
  logic [IdxWidth-1:0] stored_scan_idx;
  logic [IdxWidth-1:0] stored_scan_pos;
  logic [ReorderBufferTagWidth-1:0] stored_scan_rob_tag;

  logic update_scan_found;
  logic [IdxWidth-1:0] update_scan_idx;
  logic [IdxWidth-1:0] update_scan_pos;
  logic [ReorderBufferTagWidth-1:0] update_scan_rob_tag;

  always_comb begin
    stored_scan_found   = 1'b0;
    stored_scan_idx     = '0;
    stored_scan_pos     = '0;
    stored_scan_rob_tag = '0;
    update_scan_found   = 1'b0;
    update_scan_idx     = '0;
    update_scan_pos     = '0;
    update_scan_rob_tag = '0;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (mem_issue_stored_mask[i] && !stored_scan_found) begin
        stored_scan_found   = 1'b1;
        stored_scan_idx     = scan_idx[i];
        stored_scan_pos     = IdxWidth'(i);
        stored_scan_rob_tag = lq_rob_tag[scan_idx[i]];
      end

      if (mem_issue_update_mask[i] && !update_scan_found) begin
        update_scan_found   = 1'b1;
        update_scan_idx     = scan_idx[i];
        update_scan_pos     = IdxWidth'(i);
        update_scan_rob_tag = lq_rob_tag[scan_idx[i]];
      end
    end
  end

  logic [IdxWidth-1:0] stored_issue_idx;
  logic [ReorderBufferTagWidth-1:0] stored_issue_rob_tag;
  logic [ReorderBufferTagWidth-1:0] update_issue_rob_tag;
  logic update_scan_older_than_stored_scan;
  logic update_scan_issueable;
  logic update_scan_wins;

  // Keep the live address-derived MMIO compare out of the same-cycle capture
  // control. If a rare current-update MMIO load is staged before it reaches
  // ROB head, sq_check_is_mmio_q prevents SQ/memory issue until it is head.
  assign update_scan_issueable = update_scan_found;
  assign update_scan_older_than_stored_scan =
      update_scan_issueable && (!stored_scan_found || (update_scan_pos < stored_scan_pos));
  assign update_scan_wins = i_addr_update.valid && update_scan_older_than_stored_scan;

  // Phase B: select oldest eligible entry.  Stored candidates are encoded
  // independently from the current-cycle address-update candidate so the LQ
  // address RAM read address does not depend on i_addr_update.valid.
  always_comb begin
    stored_issue_idx      = head_mem_stored_found ? head_mem_stored_idx : stored_scan_idx;
    stored_issue_rob_tag  = head_mem_stored_found ? head_mem_stored_rob_tag : stored_scan_rob_tag;

    update_issue_rob_tag  = head_mem_update_found ? head_mem_update_rob_tag : update_scan_rob_tag;

    issue_mem_found       = 1'b0;
    issue_mem_idx         = '0;
    issue_mem_stored_idx  = stored_issue_idx;
    issue_mem_from_update = 1'b0;
    issue_mem_rob_tag     = '0;
    block_younger_mem     = 1'b0;  // kept for interface compat; unused in restructured scan

    if (head_mem_stored_found) begin
      issue_mem_found   = 1'b1;
      issue_mem_idx     = head_mem_stored_idx;
      issue_mem_rob_tag = stored_issue_rob_tag;
    end else if (i_addr_update.valid && head_mem_update_found) begin
      issue_mem_found       = 1'b1;
      issue_mem_idx         = head_mem_update_idx;
      issue_mem_from_update = 1'b1;
      issue_mem_rob_tag     = update_issue_rob_tag;
    end else if (update_scan_wins) begin
      issue_mem_found       = 1'b1;
      issue_mem_idx         = update_scan_idx;
      issue_mem_from_update = 1'b1;
      issue_mem_rob_tag     = update_scan_rob_tag;
    end else if (stored_scan_found) begin
      issue_mem_found   = 1'b1;
      issue_mem_idx     = stored_scan_idx;
      issue_mem_rob_tag = stored_scan_rob_tag;
    end
  end

  // ===========================================================================
  // SQ Disambiguation Interface (combinational)
  // ===========================================================================
  // For Phase B candidate: drive SQ check ports

  assign sq_check_entry_valid = sq_check_pending;
  assign o_mem_addr_valid = sq_check_entry_valid;

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
  logic sq_check_misaligned;
  logic misalign_bypass_fire;
  assign sq_check_misaligned = i_trap_misaligned_accesses &&
      sq_check_entry_valid && sq_check_entry_issueable &&
      is_load_misaligned(
      sq_check_size_q, sq_check_addr_q
  );
  assign sq_check_will_clear = sq_check_pending &&
      (!sq_check_entry_valid || cache_hit_fast_path || sq_do_forward ||
       launch_mem_issue || misalign_bypass_fire);

  // TIMING: MMIO check folded into the Phase B eligibility masks so these
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
  // Port-split replica drives the upper-half of the SQ CAM (entries 4..7).
  // Value is identical to o_sq_check_addr — the split is for placement
  // freedom only, not a functional difference.
  assign o_sq_check_addr_b = sq_check_addr_q_b;

  always_comb begin
    o_sq_check_valid   = 1'b0;
    o_sq_check_addr    = sq_check_addr_q;
    o_sq_check_rob_tag = sq_check_rob_tag_q;
    o_sq_check_size    = sq_check_size_q;

    if (!i_flush_all && !i_flush_en && !drop_mem_response_pending &&
        !i_mem_bus_busy && sq_check_entry_issueable &&
        !sq_check_misaligned &&
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
  logic sq_no_older_store;
  assign sq_no_older_store = sq_check_no_older_store_q || i_sq_empty;
  assign sq_can_issue = sq_check_phase2 && sq_check_entry_issueable &&
      !sq_check_misaligned &&
      (sq_no_older_store || (i_sq_all_older_addrs_known && !i_sq_forward.match));
  assign sq_do_forward = ENABLE_SQ_FORWARD_FAST_PATH
      && sq_check_phase2 && sq_check_entry_issueable && !sq_no_older_store &&
      !sq_check_misaligned &&
      i_sq_forward.can_forward
      && !sq_check_is_mmio_q && !sq_check_is_lr_q && !sq_check_is_amo_q;
  assign flush_all_entries = i_flush_en && !i_early_recovery_flush &&
      (i_rob_head_tag == (i_flush_tag + ReorderBufferTagWidth'(1)));

  // Data memory has fixed 1-cycle latency in this design. If a partial flush
  // kills the outstanding load, drop that next response explicitly so the slot
  // can be safely reused before the stale data returns.
  assign issued_entry_flushed = i_flush_en && mem_outstanding && lq_valid[issued_idx] &&
      (flush_all_entries || is_younger(
      issued_rob_tag, i_flush_tag, i_rob_head_tag
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

      // Lookup: staged SQ-disambiguation candidate. Hits are consumed only
      // when sq_can_issue is true, so stale lookup addresses are harmless and
      // keep sq_check_pending out of the LUTRAM address cone.
      .i_lookup_addr(sq_check_addr_q),
      .o_lookup_hit (cache_lookup_hit),
      .o_lookup_data(cache_lookup_data),

      // Fill: on memory response
      .i_fill_valid(cache_fill_valid),
      .i_fill_addr (cache_fill_addr),
      .i_fill_data (cache_fill_data),

      // Invalidation (from SQ or AMO write completion)
      .i_invalidate_valid(i_cache_invalidate_valid || amo_cache_inv),
      .i_invalidate_addr (amo_cache_inv ? lq_address_amo_rd : i_cache_invalidate_addr),

      // Flush: L0 contents always reflect architectural memory state
      // (stores invalidate matching lines; loads only fill with data the
      // BRAM has already committed). Branch mispredictions do NOT require
      // clearing the cache — tying this to 0 keeps cached lines hot across
      // mispredict recovery. Big CoreMark win: the L0 was otherwise wiped
      // on every branch mispredict, losing ~36 points of steady-state hit
      // rate.
      .i_flush_all(1'b0)
  );

  // AMO serialization (ROB head + SQ committed-empty) guarantees these
  // two invalidation sources are mutually exclusive.
`ifndef SYNTHESIS
`ifndef FORMAL
  assert property (@(posedge i_clk) disable iff (!i_rst_n)
      !(i_cache_invalidate_valid && amo_cache_inv))
  else $error("BUG: SQ and AMO cache invalidation fired simultaneously");
`endif
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

  // Session P fix: gate stage_mem_issue on !i_flush_all too.  See comment on
  // launch_mem_issue below for the full rationale.
  assign stage_mem_issue = !i_flush_en && !i_flush_all && sq_can_issue && !cache_hit_fast_path;
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
  // Session P fix: also gate on !i_flush_all.  During commit-time mispredict
  // recovery the wrapper drives speculative_flush_en=0 but speculative_flush_all=1
  // (commit_recovery_flush_after_head path).  Without the !i_flush_all guard,
  // a speculative wrong-path MMIO load that happens to be at ROB head when the
  // mispredict commits can still issue this cycle and consume the FIFO byte
  // before the next-cycle full flush clears the entry.  packet_parser exposed
  // this race once 2-wide dispatch let speculative loads reach HEAD faster.
  assign launch_mem_issue = !i_flush_en && !i_flush_all && !i_mem_bus_busy && stage_mem_issue;
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
  // sq_do_forward, lu_cache_out, lu_data_out, etc.) for readable tool output.

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
      if (issued_is_amo) begin
        // AMO read: don't write data yet (port 1 handles after AMO write)
      end else if (issued_is_fp
                   && riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_DOUBLE
                   && !issued_fp64_phase) begin
        // FLD phase 0: write lo only
        lq_data_lo_we[0] = 1'b1;
        lq_data_lo_wd[0] = lu_data_out;
      end else if (issued_is_fp
                   && riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_DOUBLE
                   && issued_fp64_phase) begin
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
  // issued_addr already encodes the FLD phase 1 +4 (it was captured from
  // launch_mem_issue_addr, which applied the +4 inside stage_mem_issue_addr),
  // so the fill address is just the snapshot directly. Critically, this path
  // no longer goes through the lq_address_issued LUTRAM read or the +4 carry
  // chain, which were the dominant prefix of the cone reaching the data
  // memory's ADDRARDADDR pin via lq_l0_cache.lookup_fill_bypass.
  assign cache_fill_valid = accept_mem_response
      && !issued_is_mmio && !issued_is_lr && !issued_is_amo;
  assign cache_fill_addr = issued_addr;
  assign cache_fill_data = i_mem_read_data;

  // L0 cache profile pulses (one cycle when the event fires)
  assign o_l0_hit = cache_hit_fast_path;
  assign o_l0_fill = cache_fill_valid;
  // Diagnostic: expose mem_outstanding so the wrapper can partition head
  // wait cycles into "load in flight" vs "load stuck on something else".
  assign o_mem_outstanding = mem_outstanding;

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
      lu_is_byte     = (riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_BYTE);
      lu_is_half     = (riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_HALF);
      lu_is_unsigned = !issued_sign_ext;
      lu_addr        = issued_addr;
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
    if (issue_cdb_found && !i_flush_en) begin
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

  // Full-flush CDB suppression is centralized in the wrapper's cdb_kill and
  // MEM adapter flush.  Keep i_flush_all out of this payload/valid mux so a
  // FENCE.I/trap full flush does not route through CDB data selection.
  always_comb begin
    o_fu_complete       = cdb_stage_data;
    o_fu_complete.valid = cdb_stage_valid && !i_flush_en && !cdb_stage_result_flushed;
  end

  // ===========================================================================
  // Completion Fast-Path Bypass
  // ===========================================================================
  // Skip the data_valid -> issue_cdb_fire -> cdb_stage capture chain on cycles
  // where a mem response or L0 cache hit completes a load AND cdb_stage is
  // otherwise idle.  Drives cdb_stage directly from the response-side formatted
  // result, shaving one head-wait cycle per eligible load.  Falls back to the
  // standard data_valid path when cdb_stage is busy or when an older entry is
  // already firing through issue_cdb_fire.  AMOs (need write phase) and FLDs
  // (two-phase, phase-1 value needs LUTRAM lo read) stay on the standard path.
  logic resp_bypass_ok;
  logic resp_bypass_fire;
  logic cache_hit_bypass_fire;
  logic bypass_fire;
  logic [IdxWidth-1:0] bypass_idx;
  logic [ReorderBufferTagWidth-1:0] bypass_tag;
  logic [FLEN-1:0] bypass_value;
  logic [FLEN-1:0] resp_bypass_value;
  logic [FLEN-1:0] cache_hit_bypass_value;

  assign resp_bypass_ok =
      accept_mem_response && !issued_is_amo &&
      !(issued_is_fp && (riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_DOUBLE));

  assign resp_bypass_fire = cdb_stage_slot_available && !issue_cdb_fire &&
                            resp_bypass_ok && !i_flush_en;

  assign misalign_bypass_fire = cdb_stage_slot_available && !issue_cdb_fire &&
                                !resp_bypass_fire && sq_check_misaligned && !i_flush_en;

  // cache_hit_fast_path is already flush-gated at its own assign.
  assign cache_hit_bypass_fire = cdb_stage_slot_available && !issue_cdb_fire &&
                                 !resp_bypass_fire && !misalign_bypass_fire &&
                                 cache_hit_fast_path;

  assign bypass_fire = resp_bypass_fire || misalign_bypass_fire || cache_hit_bypass_fire;

  // Mirror issue_cdb_result formatting, but sourced from the response-side
  // signals (lu_data_out / lu_cache_out / raw word) instead of the LUTRAM.
  always_comb begin
    if (issued_is_fp) begin
      // FLW: NaN-box raw 32-bit word
      resp_bypass_value = {32'hFFFF_FFFF, lu_data_out};
    end else begin
      // INT / LR: zero-extend byte/half/word extracted value
      resp_bypass_value = {{(FLEN - XLEN) {1'b0}}, lu_data_out};
    end
  end

  always_comb begin
    if (sq_check_is_fp_q) begin
      // FLW from L0: NaN-box raw cache data (L0 fast path gates out FLD)
      cache_hit_bypass_value = {32'hFFFF_FFFF, cache_lookup_data};
    end else begin
      // INT from L0: cache-path load_unit already did byte/half extract
      cache_hit_bypass_value = {{(FLEN - XLEN) {1'b0}}, lu_cache_out};
    end
  end

  assign bypass_idx = resp_bypass_fire ? issued_idx : sq_check_idx;
  assign bypass_tag = resp_bypass_fire ? issued_rob_tag : sq_check_rob_tag_q;
  assign bypass_value =
      misalign_bypass_fire ? '0 :
      resp_bypass_fire ? resp_bypass_value :
      cache_hit_bypass_value;

  // Entry freeing: once the result is captured into the stage, the queue slot
  // can be released. The staged copy now owns the completion payload.  The
  // bypass path frees the entry the same cycle it completes (no intervening
  // data_valid state).
  assign free_entry_en = issue_cdb_fire || bypass_fire;
  assign free_entry_idx = issue_cdb_fire ? issue_cdb_idx : bypass_idx;

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

  // Tree priority encoder: find lowest-index set bit in rotated mask, plus
  // the second-lowest set bit (for slot-2 alloc).  Both offsets are computed
  // in a single sweep; the second offset is invalid when fewer than 2 free
  // slots exist, but slot-2 is gated externally by full_for_2 so the bogus
  // index is not consumed.
  logic [IdxWidth-1:0] lq_second_free_offset;
  logic                lq_second_free_found;
  always_comb begin
    lq_first_free_offset  = '0;
    lq_first_free_found   = 1'b0;
    lq_second_free_offset = '0;
    lq_second_free_found  = 1'b0;
    for (int i = 0; i < DEPTH; i++) begin
      if (lq_free_rotated[i]) begin
        if (!lq_first_free_found) begin
          lq_first_free_offset = IdxWidth'(i);
          lq_first_free_found  = 1'b1;
        end else if (!lq_second_free_found) begin
          lq_second_free_offset = IdxWidth'(i);
          lq_second_free_found  = 1'b1;
        end
      end
    end
  end

  // Add offsets back to tail_ptr to get absolute alloc targets.
  assign alloc_target   = tail_ptr + PtrWidth'({1'b0, lq_first_free_offset});
  assign alloc_target_2 = tail_ptr + PtrWidth'({1'b0, lq_second_free_offset});

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
      lq_head_valid_rotated[i] = lq_valid[IdxWidth'(head_idx+IdxWidth'(i))];
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

  // Keep these as always-updated next-state flops so synthesis does not build
  // a deep clock-enable cone from the LQ issue scan into the SQ-check controls.
  // The sideband bits are consumed only when sq_check_pending is set, so normal
  // completion only needs to clear sq_check_pending; stale sideband values are
  // overwritten on the next capture.
  logic sq_check_pending_next;
  logic sq_check_no_older_store_next;
  logic sq_check_phase2_next;
  logic [DEPTH-1:0] sq_check_in_flight_mask_next;
  logic sq_check_flushed;
  assign sq_check_flushed = i_flush_en && sq_check_pending && (flush_all_entries || is_younger(
      sq_check_rob_tag_q, i_flush_tag, i_rob_head_tag
  ));

  always_comb begin
    sq_check_pending_next        = sq_check_pending;
    sq_check_no_older_store_next = sq_check_no_older_store_q;
    sq_check_phase2_next         = sq_check_phase2;
    sq_check_in_flight_mask_next = sq_check_in_flight_mask;

    if (sq_check_flushed) begin
      sq_check_pending_next        = 1'b0;
      sq_check_no_older_store_next = 1'b0;
      sq_check_phase2_next         = 1'b0;
      sq_check_in_flight_mask_next = '0;
    end else if (sq_check_capture || sq_check_replace) begin
      sq_check_pending_next                           = 1'b1;
      sq_check_no_older_store_next                    = i_sq_empty;
      sq_check_phase2_next                            = i_sq_empty;
      sq_check_in_flight_mask_next                    = '0;
      sq_check_in_flight_mask_next[sq_check_idx_next] = 1'b1;
    end else if (sq_check_pending &&
                 (!sq_check_entry_valid || cache_hit_fast_path || sq_do_forward ||
                  launch_mem_issue || misalign_bypass_fire)) begin
      // launch_mem_issue keeps the slot held through bus_busy stalls.
      sq_check_pending_next        = 1'b0;
      sq_check_in_flight_mask_next = '0;
    end else if (sq_check_pending && !sq_check_phase2 && i_sq_empty) begin
      sq_check_phase2_next = 1'b1;
    end else if (o_sq_check_valid && !sq_check_phase2) begin
      sq_check_phase2_next = 1'b1;
    end
  end

  // ===========================================================================
  // Sequential Logic
  // ===========================================================================

`ifdef FROST_XILINX_PRIMS
  // Xilinx-specific timing steering: keep CE tied high so Vivado cannot put
  // the LQ issue-scan cone on the control-flop CE pins.
  FDRE #(
      .INIT(1'b0)
  ) sq_check_pending_ff (
      .C (i_clk),
      .CE(1'b1),
      .D (sq_check_pending_next),
      .Q (sq_check_pending),
      .R (!i_rst_n || i_flush_all)
  );

  FDRE #(
      .INIT(1'b0)
  ) sq_check_no_older_store_ff (
      .C (i_clk),
      .CE(1'b1),
      .D (sq_check_no_older_store_next),
      .Q (sq_check_no_older_store_q),
      .R (!i_rst_n || i_flush_all)
  );

  FDRE #(
      .INIT(1'b0)
  ) sq_check_phase2_ff (
      .C (i_clk),
      .CE(1'b1),
      .D (sq_check_phase2_next),
      .Q (sq_check_phase2),
      .R (!i_rst_n || i_flush_all)
  );

  for (genvar g_sq_mask = 0; g_sq_mask < DEPTH; g_sq_mask++) begin : gen_sq_check_in_flight_mask_ff
    FDRE #(
        .INIT(1'b0)
    ) sq_check_in_flight_mask_ff (
        .C (i_clk),
        .CE(1'b1),
        .D (sq_check_in_flight_mask_next[g_sq_mask]),
        .Q (sq_check_in_flight_mask[g_sq_mask]),
        .R (!i_rst_n || i_flush_all)
    );
  end
`else
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      sq_check_pending          <= 1'b0;
      sq_check_no_older_store_q <= 1'b0;
      sq_check_phase2           <= 1'b0;
      sq_check_in_flight_mask   <= '0;
    end else begin
      sq_check_pending          <= sq_check_pending_next;
      sq_check_no_older_store_q <= sq_check_no_older_store_next;
      sq_check_phase2           <= sq_check_phase2_next;
      sq_check_in_flight_mask   <= sq_check_in_flight_mask_next;
    end
  end
`endif


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
        // Leave tail_ptr unchanged. alloc_target will reuse reclaimed holes
        // after the flush instead of compacting the tail in this cycle.
      end

      // -----------------------------------------------------------------
      // Allocation: write new entry at tail (control signals only;
      // data signals written in dedicated no-reset always_ff blocks)
      // -----------------------------------------------------------------
      // Slot-1 alloc.  Slot-2 alloc (below) writes a different physical entry,
      // so the non-blocking writes on lq_valid/etc. never collide on a bit.
      if (slot1_alloc_en) begin
        lq_valid[alloc_target[IdxWidth-1:0]]      <= 1'b1;
        lq_addr_valid[alloc_target[IdxWidth-1:0]] <= 1'b0;
        lq_issued[alloc_target[IdxWidth-1:0]]     <= 1'b0;
        lq_data_valid[alloc_target[IdxWidth-1:0]] <= 1'b0;
        lq_forwarded[alloc_target[IdxWidth-1:0]]  <= 1'b0;
      end

      // Slot-2 alloc — fires when a slot-2 load allocates this cycle.
      if (slot2_alloc_en) begin
        lq_valid[slot2_alloc_idx]      <= 1'b1;
        lq_addr_valid[slot2_alloc_idx] <= 1'b0;
        lq_issued[slot2_alloc_idx]     <= 1'b0;
        lq_data_valid[slot2_alloc_idx] <= 1'b0;
        lq_forwarded[slot2_alloc_idx]  <= 1'b0;
      end

      // tail_ptr advances past the highest slot consumed this cycle, so the
      // next free-search starts beyond it.  When only slot-2 fires it took
      // alloc_target (slot1_alloc_idx), so tail still advances to alloc_target+1.
      if (slot1_alloc_en && slot2_alloc_en) begin
        tail_ptr <= alloc_target_2 + PtrWidth'(1);
      end else if (slot1_alloc_en || slot2_alloc_en) begin
        tail_ptr <= alloc_target + PtrWidth'(1);
      end

      // -----------------------------------------------------------------
      // Address Update: CAM search for matching rob_tag (control only;
      // data signals written in dedicated no-reset always_ff blocks)
      // -----------------------------------------------------------------
      if (lq_addr_update_we) begin
        lq_addr_valid[lq_addr_update_idx] <= 1'b1;
      end

      // -----------------------------------------------------------------
      // L0 Cache Hit Fast Path: SQ confirmed no conflict, use cached data
      // -----------------------------------------------------------------
      // Skip the data_valid step when the completion bypass captured the
      // cache hit directly into cdb_stage — the entry is already freed via
      // free_entry_en.
      if (cache_hit_fast_path && !cache_hit_bypass_fire) begin
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
        mem_outstanding <= 1'b0;
        if (issued_is_amo) begin
          // AMO: start write phase (don't set data_valid yet);
          // data signals (amo_old_value, amo_entry_idx) in no-reset block
          amo_state <= AMO_WRITE_ACTIVE;
        end else if (issued_is_fp &&
            riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_DOUBLE &&
            !issued_fp64_phase) begin
          // FLD phase 0: re-issue for phase 1;
          // lq_fp64_phase in no-reset block
          lq_issued[issued_idx] <= 1'b0;  // Re-issue for phase 1
        end else begin
          // Non-AMO, non-FLD-phase-0 (LR, FLW, INT load, FLD phase 1):
          // the completion bypass may have captured this result directly
          // into cdb_stage the same cycle via resp_bypass_fire.  In that
          // case skip the data_valid/LUTRAM write — free_entry_en releases
          // the slot.  LR still arms reservation_valid either way.
          if (issued_is_lr) reservation_valid <= 1'b1;
          if (!resp_bypass_fire) begin
            // Standard path: let the priority encoder pick next cycle.
            lq_data_valid[issued_idx] <= 1'b1;
          end
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
    if (slot1_alloc_en) begin
      lq_rob_tag[alloc_target[IdxWidth-1:0]]    <= i_alloc.rob_tag;
      lq_size[alloc_target[IdxWidth-1:0]]       <= i_alloc.size;
      lq_is_fp[alloc_target[IdxWidth-1:0]]      <= i_alloc.is_fp;
      lq_sign_ext[alloc_target[IdxWidth-1:0]]   <= i_alloc.sign_ext;
      lq_fp64_phase[alloc_target[IdxWidth-1:0]] <= 1'b0;
      lq_is_lr[alloc_target[IdxWidth-1:0]]      <= i_alloc.is_lr;
      lq_is_amo[alloc_target[IdxWidth-1:0]]     <= i_alloc.is_amo;
    end
    // Slot-2 alloc data — fires when a slot-2 load allocates this cycle.
    if (slot2_alloc_en) begin
      lq_rob_tag[slot2_alloc_idx]    <= i_alloc_2.rob_tag;
      lq_size[slot2_alloc_idx]       <= i_alloc_2.size;
      lq_is_fp[slot2_alloc_idx]      <= i_alloc_2.is_fp;
      lq_sign_ext[slot2_alloc_idx]   <= i_alloc_2.sign_ext;
      lq_fp64_phase[slot2_alloc_idx] <= 1'b0;
      lq_is_lr[slot2_alloc_idx]      <= i_alloc_2.is_lr;
      lq_is_amo[slot2_alloc_idx]     <= i_alloc_2.is_amo;
    end
    // FLD phase advance: set phase 1 after phase 0 memory response
    if (accept_mem_response && issued_is_fp &&
        riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_DOUBLE &&
        !issued_fp64_phase) begin
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
  logic issue_mem_uses_addr_update;
  logic [XLEN-1:0] issue_mem_addr;
  logic [IdxWidth-1:0] update_issue_payload_idx;
  logic [MemSizeWidth-1:0] issue_mem_size_bits;
  logic issue_mem_is_fp;
  logic issue_mem_sign_ext;
  logic issue_mem_is_mmio;
  logic issue_mem_fp64_phase;
  logic issue_mem_is_lr;
  logic issue_mem_is_amo;
  logic sq_check_payload_en;
  logic [IdxWidth-1:0] sq_check_idx_next;
  logic [ReorderBufferTagWidth-1:0] sq_check_rob_tag_next;
  logic [XLEN-1:0] sq_check_addr_next;
  riscv_pkg::mem_size_e sq_check_size_next;
  logic sq_check_is_fp_next;
  logic sq_check_sign_ext_next;
  logic sq_check_is_mmio_next;
  logic sq_check_fp64_phase_next;
  logic sq_check_is_lr_next;
  logic sq_check_is_amo_next;
  assign sq_check_payload_en = sq_check_capture || sq_check_replace;
  assign issue_mem_uses_addr_update = issue_mem_from_update;
  assign issue_mem_addr = issue_mem_uses_addr_update ? i_addr_update.address
                                                     : lq_address_issue_mem_rd;
  assign update_issue_payload_idx = head_mem_update_found ? head_mem_update_idx : update_scan_idx;
  assign issue_mem_size_bits = issue_mem_from_update ? lq_size[update_issue_payload_idx]
                                                     : lq_size[issue_mem_stored_idx];
  assign issue_mem_is_fp = issue_mem_from_update ? lq_is_fp[update_issue_payload_idx]
                                                 : lq_is_fp[issue_mem_stored_idx];
  assign issue_mem_sign_ext = issue_mem_from_update ? lq_sign_ext[update_issue_payload_idx]
                                                    : lq_sign_ext[issue_mem_stored_idx];
  assign issue_mem_is_mmio = issue_mem_from_update ? i_addr_update.is_mmio
                                                   : lq_is_mmio[issue_mem_stored_idx];
  assign issue_mem_fp64_phase = issue_mem_from_update ? lq_fp64_phase[update_issue_payload_idx]
                                                      : lq_fp64_phase[issue_mem_stored_idx];
  assign issue_mem_is_lr = issue_mem_from_update ? lq_is_lr[update_issue_payload_idx]
                                                 : lq_is_lr[issue_mem_stored_idx];
  assign issue_mem_is_amo = issue_mem_from_update ? lq_is_amo[update_issue_payload_idx]
                                                  : lq_is_amo[issue_mem_stored_idx];

  // Payload flops only need to update on capture/replace. Keep the enable on
  // the CE pin and drive D directly from the selected candidate; this removes
  // a per-bit hold mux from the SQ-check address path.
  assign sq_check_idx_next = issue_mem_idx;
  assign sq_check_rob_tag_next = issue_mem_rob_tag;
  assign sq_check_addr_next = issue_mem_addr;
  assign sq_check_size_next = riscv_pkg::mem_size_e'(issue_mem_size_bits);
  assign sq_check_is_fp_next = issue_mem_is_fp;
  assign sq_check_sign_ext_next = issue_mem_sign_ext;
  assign sq_check_is_mmio_next = issue_mem_is_mmio;
  assign sq_check_fp64_phase_next = issue_mem_fp64_phase;
  assign sq_check_is_lr_next = issue_mem_is_lr;
  assign sq_check_is_amo_next = issue_mem_is_amo;

`ifdef FROST_XILINX_PRIMS
  for (genvar g_sq_idx = 0; g_sq_idx < IdxWidth; g_sq_idx++) begin : gen_sq_check_idx_ff
    FDRE #(
        .INIT(1'b0)
    ) sq_check_idx_ff (
        .C (i_clk),
        .CE(sq_check_payload_en),
        .D (sq_check_idx_next[g_sq_idx]),
        .Q (sq_check_idx[g_sq_idx]),
        .R (1'b0)
    );
  end

  for (
      genvar g_sq_tag = 0; g_sq_tag < ReorderBufferTagWidth; g_sq_tag++
  ) begin : gen_sq_check_tag_ff
    FDRE #(
        .INIT(1'b0)
    ) sq_check_tag_ff (
        .C (i_clk),
        .CE(sq_check_payload_en),
        .D (sq_check_rob_tag_next[g_sq_tag]),
        .Q (sq_check_rob_tag_q[g_sq_tag]),
        .R (1'b0)
    );
  end

  // sq_check_addr_q: use standard always_ff (NOT explicit FDRE prims) so
  // Vivado can auto-replicate this 32-bit register.  The SQ disambiguation
  // CAM (in u_sq, computing o_sq_forward.match) consumes every bit of
  // sq_check_addr_q across all SQ entries, byte-mask checks, and age
  // qualification — ~170 loads per bit.  Pinning to a single FDRE primitive
  // per bit blocked fanout replication and pushed routing to ~70% of the
  // path delay, producing the lone -0.178 ns post-synth outlier (15 LUT
  // levels, mostly long routes).  Leaving the FDREs for the other sq_check_*
  // fields below — they're narrower and have lower fanout.
  always_ff @(posedge i_clk) begin
    if (sq_check_payload_en) sq_check_addr_q <= sq_check_addr_next;
  end

  // Port-split replica: drives the upper-half of the SQ CAM (entries 4..7).
  // Same D/CE/timing as sq_check_addr_q — dont_touch (on the decl) prevents
  // opt_design from re-merging the two registers.
  always_ff @(posedge i_clk) begin
    if (sq_check_payload_en) sq_check_addr_q_b <= sq_check_addr_next;
  end

  for (genvar g_sq_size = 0; g_sq_size < MemSizeWidth; g_sq_size++) begin : gen_sq_check_size_ff
    FDRE #(
        .INIT(1'b0)
    ) sq_check_size_ff (
        .C (i_clk),
        .CE(sq_check_payload_en),
        .D (sq_check_size_next[g_sq_size]),
        .Q (sq_check_size_q[g_sq_size]),
        .R (1'b0)
    );
  end

  FDRE #(
      .INIT(1'b0)
  ) sq_check_is_fp_ff (
      .C (i_clk),
      .CE(sq_check_payload_en),
      .D (sq_check_is_fp_next),
      .Q (sq_check_is_fp_q),
      .R (1'b0)
  );

  FDRE #(
      .INIT(1'b0)
  ) sq_check_sign_ext_ff (
      .C (i_clk),
      .CE(sq_check_payload_en),
      .D (sq_check_sign_ext_next),
      .Q (sq_check_sign_ext_q),
      .R (1'b0)
  );

  FDRE #(
      .INIT(1'b0)
  ) sq_check_is_mmio_ff (
      .C (i_clk),
      .CE(sq_check_payload_en),
      .D (sq_check_is_mmio_next),
      .Q (sq_check_is_mmio_q),
      .R (1'b0)
  );

  FDRE #(
      .INIT(1'b0)
  ) sq_check_fp64_phase_ff (
      .C (i_clk),
      .CE(sq_check_payload_en),
      .D (sq_check_fp64_phase_next),
      .Q (sq_check_fp64_phase_q),
      .R (1'b0)
  );

  FDRE #(
      .INIT(1'b0)
  ) sq_check_is_lr_ff (
      .C (i_clk),
      .CE(sq_check_payload_en),
      .D (sq_check_is_lr_next),
      .Q (sq_check_is_lr_q),
      .R (1'b0)
  );

  FDRE #(
      .INIT(1'b0)
  ) sq_check_is_amo_ff (
      .C (i_clk),
      .CE(sq_check_payload_en),
      .D (sq_check_is_amo_next),
      .Q (sq_check_is_amo_q),
      .R (1'b0)
  );
`else
  always_ff @(posedge i_clk) begin
    if (sq_check_payload_en) begin
      sq_check_idx          <= sq_check_idx_next;
      sq_check_rob_tag_q    <= sq_check_rob_tag_next;
      sq_check_addr_q       <= sq_check_addr_next;
      sq_check_addr_q_b     <= sq_check_addr_next;
      sq_check_size_q       <= sq_check_size_next;
      sq_check_is_fp_q      <= sq_check_is_fp_next;
      sq_check_sign_ext_q   <= sq_check_sign_ext_next;
      sq_check_is_mmio_q    <= sq_check_is_mmio_next;
      sq_check_fp64_phase_q <= sq_check_fp64_phase_next;
      sq_check_is_lr_q      <= sq_check_is_lr_next;
      sq_check_is_amo_q     <= sq_check_is_amo_next;
    end
  end
`endif

  // -----------------------------------------------------------------
  // Internal data: issued entry tracker + flat snapshot
  // -----------------------------------------------------------------
  // Snapshotting the per-entry attributes here breaks the long
  //   issued_idx → lq_*[issued_idx] → cache_fill_addr → l0_cache lookup
  // cone that fed the data_memory ADDRARDADDR pin via lookup_fill_bypass.
  // The captured fields are stable for the lifetime of the outstanding
  // load (allocation-time fields don't change once written; sq_check_*_q
  // already encodes the active FLD phase at launch time).
  always_ff @(posedge i_clk) begin
    if (o_mem_read_en) begin
      issued_idx        <= launch_mem_issue_idx;
      issued_addr       <= launch_mem_issue_addr;
      issued_size       <= launch_mem_issue_size;
      issued_is_fp      <= sq_check_is_fp_q;
      issued_is_lr      <= sq_check_is_lr_q;
      issued_is_amo     <= sq_check_is_amo_q;
      issued_is_mmio    <= sq_check_is_mmio_q;
      issued_sign_ext   <= sq_check_sign_ext_q;
      issued_fp64_phase <= sq_check_fp64_phase_q;
      issued_rob_tag    <= sq_check_rob_tag_q;
    end
  end

  // -----------------------------------------------------------------
  // Internal data: AMO old value and entry index
  // -----------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (accept_mem_response && issued_is_amo) begin
      amo_old_value <= i_mem_read_data;
      amo_entry_idx <= issued_idx;
    end
  end

  // -----------------------------------------------------------------
  // Internal data: reservation address
  // -----------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (accept_mem_response && issued_is_lr) begin
      reservation_addr <= issued_addr;
    end
  end

  // -----------------------------------------------------------------
  // Internal data: CDB completion stage result
  // -----------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      cdb_stage_valid <= 1'b0;
    end else if (issue_cdb_fire || bypass_fire) begin
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
    end else if (bypass_fire) begin
      cdb_stage_data.tag <= bypass_tag;
      cdb_stage_data.value <= bypass_value;
      cdb_stage_data.exception <= misalign_bypass_fire;
      cdb_stage_data.exc_cause <= misalign_bypass_fire ?
          riscv_pkg::exc_cause_t'(riscv_pkg::ExcLoadAddrMisalign[riscv_pkg::ExcCauseWidth-1:0]) :
          riscv_pkg::exc_cause_t'('0);
      cdb_stage_data.fp_flags <= '0;
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
      if (i_alloc_2.valid && i_alloc.valid && full_for_2)
        $warning("LQ: slot-2 alloc attempted when full_for_2 (and slot-1 firing)");
      if (i_alloc_2.valid && !i_alloc.valid && full)
        $warning("LQ: slot-2 alloc attempted alone when full");
      // Slot-1 and slot-2 must never target the same physical entry.
      if (slot1_alloc_en && slot2_alloc_en && (alloc_target[IdxWidth-1:0] == slot2_alloc_idx))
        $error("LQ: slot-1 and slot-2 alloc collide on entry %0d", alloc_target[IdxWidth-1:0]);
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

  logic [ReorderBufferTagWidth-1:0] f_pre_issue_rob_tag_q;
  logic                             f_pre_issue_needs_lq_q;
  always @(posedge i_clk) begin
    f_pre_issue_rob_tag_q  <= i_pre_issue_rob_tag;
    f_pre_issue_needs_lq_q <= i_pre_issue_needs_lq;
  end

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // -------------------------------------------------------------------------
  // Structural constraints (assumes)
  // -------------------------------------------------------------------------

  // No allocation during flush
  always_comb begin
    if (i_flush_all || i_flush_en) assume (!i_alloc.valid);
    if (i_flush_all || i_flush_en) assume (!i_alloc_2.valid);
  end

  // Slot-2 must respect capacity given whether slot-1 is also firing.
  always_comb begin
    if (i_alloc.valid && full_for_2) assume (!i_alloc_2.valid);
    if (!i_alloc.valid && full) assume (!i_alloc_2.valid);
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

  // The registered address-update pre-match is driven by MEM_RS look-ahead one
  // cycle before the matching address update arrives.
  always_comb begin
    if (i_rst_n && i_addr_update.valid) begin
      assume (f_pre_issue_needs_lq_q);
      assume (i_addr_update.rob_tag == f_pre_issue_rob_tag_q);
    end
  end

  // The ROB allocates a unique tag per in-flight instruction, so two live LQ
  // entries cannot legitimately have the same producer tag.
  always_comb begin
    if (i_rst_n) begin
      for (int i = 0; i < DEPTH; i++) begin
        for (int j = i + 1; j < DEPTH; j++) begin
          assume (!lq_valid[i] || !lq_valid[j] || (lq_rob_tag[i] != lq_rob_tag[j]));
        end
      end
    end
  end

  // No allocation when full
  always_comb begin
    if (full) assume (!i_alloc.valid);
  end

  // The ROB tag uniqueness assumption extends to slot-2 alloc.
  always_comb begin
    if (i_rst_n && i_alloc.valid && i_alloc_2.valid) begin
      assume (i_alloc.rob_tag != i_alloc_2.rob_tag);
    end
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

  // Memory launches from the registered SQ-check request payload.  The backing
  // entry's addr_valid bit may be cleared/reused after capture.
  always_comb begin
    if (i_rst_n && o_mem_read_en) begin
      p_no_mem_issue_without_addr : assert (sq_check_entry_valid && sq_check_entry_issueable);
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

  // SQ check valid implies a staged request is present on check ports.
  always_comb begin
    if (i_rst_n && o_sq_check_valid) begin
      p_sq_check_valid_has_addr : assert (sq_check_entry_valid);
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

  // Result acceptance is a downstream handshake: the wrapper/adapter may only
  // consume a staged result that the LQ is actually presenting.
  always_comb begin
    if (i_rst_n && !o_fu_complete.valid) begin
      a_result_accept_needs_valid : assume (!i_result_accepted);
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
      p_cache_hit_needs_sq : assert (sq_can_issue && (sq_no_older_store || !i_sq_forward.match));
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
      if (ENABLE_SQ_FORWARD_FAST_PATH) begin
        cover_sq_forward : cover (sq_do_forward);
      end
      cover_full : cover (full);
      cover_flush_nonempty : cover (i_flush_en && |lq_valid);

      // Stale response drain setup: partial flush kills an outstanding load.
      // The later response-drain behavior is checked by BMC/cocotb; covering
      // the full response arrival puts Boolector on a CI-only solver cliff.
      cover_stale_drain : cover (issued_entry_flushed);

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
