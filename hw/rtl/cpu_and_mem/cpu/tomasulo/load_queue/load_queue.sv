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
 * Sparse queue of DEPTH entries (8), allocated in program order at
 * dispatch time, freed the cycle the result is captured into cdb_stage.
 * Partial flush/free leaves holes that allocation reuses, so physical slot
 * order is not ROB age order; head-priority selection compensates.
 *
 * Features:
 *   - Parameterized depth (8 entries; LUTRAM payload, FF control state)
 *   - CAM-style tag search for address update (all entries in parallel)
 *   - Oldest-first priority scan for issue selection
 *   - Single-beat dword loads on the 64-bit data tier (FLD and RV64 LD share
 *     the same size-keyed paths — docs/rv64/m1_data_tier.md)
 *   - Store-to-load forwarding via SQ disambiguation interface
 *   - MMIO device reads leave the LQ only at ROB head (non-speculative); the
 *     data-memory request router parks that handoff until every committed store
 *     has drained (conservative device read-after-write ordering)
 *   - Partial flush (age-based) and full flush support
 *   - CDB back-pressure via the one-entry cdb_stage and i_result_accepted
 *
 * Storage Strategy:
 *   Hybrid FF + LUTRAM.  Control / scan fields (valid, addr_valid,
 *   data_valid, issued, is_lr, is_amo, rob_tag, size, etc.) remain in
 *   FFs for CAM-style parallel tag search (matched on rob_tag), per-entry
 *   invalidation, and oldest-first priority scan.
 *   The load address (sdp_dist_ram) and load-result payload lq_data
 *   (one FLEN-wide mwp_dist_ram, 2 write ports for primary + AMO overlap)
 *   live in distributed RAM. The AMO operation is
 *   compacted to a 4-bit semantic code in per-entry FFs. Allocation writes are
 *   staged for one cycle (well before an AMO can issue), keeping the late
 *   dispatch/allocation cone local to a tiny request register. The selected
 *   operation and operands are consumed at the memory-response register
 *   boundary, so no queue read-select cone remains on the following AMO
 *   BRAM-write path.
 *   Valid bits in FFs gate all reads; stale payload data behind flushed entries
 *   is harmless.
 *
 * Internal load_unit instance:
 *   Byte/halfword extraction and sign extension for LB/LBU/LH/LHU.
 *   Driven by completing entry's size flags and raw memory data.
 */

module load_queue #(
    parameter int unsigned DEPTH = riscv_pkg::LqDepth,  // 8
    parameter bit ENABLE_L0_FAST_PATH = 1'b1,
    parameter bit ENABLE_SQ_FORWARD_FAST_PATH = 1'b0,
    // Cached memory tier (high-address region). A load whose address falls in
    // [CACHED_BASE, CACHED_BASE+CACHED_SIZE_BYTES) is served by the multi-cycle
    // cached tier. Only while such a load is in flight (slow_outstanding) does
    // the LQ serialize issue to single-outstanding, so the single
    // mem_outstanding / issued_idx tracker stays valid across the longer,
    // possibly-flushed response window. Low-BRAM/MMIO responses remain on the
    // fixed one-cycle fast path after router accept. A pre-accept MMIO park is
    // protected separately by the router's registered pending feedback in the
    // wrapper's i_mem_bus_busy input.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter int unsigned CACHED_SIZE_BYTES = 32'h4000_0000
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
    // Trap-cone-free variant for the SQ forwarding unit's CAPTURE enable
    // only (x3 post-opt -0.135, 65 endpoints). Two late terms of
    // o_sq_check_valid carried the registered trap/MRET pulse into every
    // forward-capture bit's D: the !i_flush_all/!i_flush_en gates, and
    // !sq_commit_check_block (commit_en-derived via the trap unit's
    // combinational o_trap_drain_wait commit-hold). Both are omitted here.
    // On any cycle where this asserts but o_sq_check_valid does not, the
    // capture latches a result that is unconsumable that cycle:
    // sq_check_phase2 advances only from the GATED o_sq_check_valid,
    // sq_check_flushed kills flushed staging, and every consumer of the
    // captured result (sq_can_issue, sq_do_forward) requires phase-2
    // lineage AND !sq_commit_interlock, which re-applies the commit-block
    // at the decision point.
    output logic o_sq_check_capture_valid,
    output logic [riscv_pkg::XLEN-1:0] o_sq_check_addr,
    // Three explicit replicas of o_sq_check_addr. Together with the primary
    // register they give each two-entry quarter of the SQ CAM its own physical
    // anchor: primary -> entries 0..1, _b -> 2..3, _c -> 4..5, _d -> 6..7.
    // The replica registers are dont_touch so opt_design cannot merge these
    // functionally identical values back into one broadcast source.
    output logic [riscv_pkg::XLEN-1:0] o_sq_check_addr_b,
    output logic [riscv_pkg::XLEN-1:0] o_sq_check_addr_c,
    output logic [riscv_pkg::XLEN-1:0] o_sq_check_addr_d,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_sq_check_rob_tag,
    output riscv_pkg::mem_size_e o_sq_check_size,
    input logic i_sq_all_older_addrs_known,
    input riscv_pkg::sq_forward_result_t i_sq_forward,
    input logic i_sq_commit_pending,

    // =========================================================================
    // Memory Interface (to data memory bus)
    // =========================================================================
    output logic                                              o_mem_read_en,
    output logic                                              o_mem_addr_valid,
    output logic                 [       riscv_pkg::XLEN-1:0] o_mem_read_addr,
    output riscv_pkg::mem_size_e                              o_mem_read_size,
    // Aligned MemDataBits beat carrying the dword at addr[31:3]
    // (docs/rv64/m1_data_tier.md); consumers extract by addr[2:0].
    input  logic                 [riscv_pkg::MemDataBits-1:0] i_mem_read_data,
    input  logic                                              i_mem_read_valid,
    input  logic                                              i_mem_bus_busy,

    // =========================================================================
    // CDB Result (to fu_cdb_adapter, FU_MEM slot)
    // =========================================================================
    output riscv_pkg::fu_complete_t o_fu_complete,
    // i_adapter_result_pending is deliberately retained even though nothing in
    // this module reads it. Deleting the port (and its driver expression in
    // tomasulo_wrapper) perturbs Vivado's global synthesis mapping enough to
    // cost the closed x3 build its post-opt WNS (+0.082 -> -0.073 ns, measured
    // 2026-07-25) in an untouched RAT -> int-RS dispatch cone; restoring these
    // four lines verbatim restores +0.082. Remove only with a fresh x3
    // synth+opt run proving post-opt WNS >= 0.
    input logic i_adapter_result_pending,  // unused (back-pressure comes from i_result_accepted)
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
    output logic                              o_amo_mem_write_en,
    output logic [       riscv_pkg::XLEN-1:0] o_amo_mem_write_addr,
    // Word-sized AMO result replicated across the beat ({2{result}}); the
    // router derives the word-lane strobes from o_amo_mem_write_addr[2].
    output logic [riscv_pkg::MemDataBits-1:0] o_amo_mem_write_data,
    output logic                              o_amo_mem_write_is_dword,
    input  logic                              i_amo_mem_write_done,

    // =========================================================================
    // Flush
    // =========================================================================
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic                                        i_flush_all,
    input logic                                        i_early_recovery_flush,

    // =========================================================================
    // L0 Cache Invalidation (from SQ store-write launch)
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
    output logic o_head_load_bb_issued,  // head has been issued, waiting for response
    output logic o_head_load_bb_bus_busy,  // i_mem_bus_busy = 1
    output logic o_head_load_bb_amo,  // older AMO pending (any_pending_amo approximation)
    output logic o_head_load_bb_sq_wait,  // in sq_check stage but !sq_check_phase2
    output logic o_head_load_bb_staging,  // catch-all (pre-sq_check capture, drop-pending, etc.)
    // Staging catch-all sub-decomposition (partitions o_head_load_bb_staging):
    output logic o_head_load_bbs_other_in_staging,  // sq_check busy with a DIFFERENT load
    output logic o_head_load_bbs_launch_gated,  // head staged, phase2 armed, launch still gated
    output logic o_head_load_bbs_slow_outstanding,  // staging free; cached-tier load in flight
    output logic o_head_load_bbs_capture_gap  // staging free; head simply not captured yet
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
  // Keep this literal for Yosys, which does not parse $bits(package::enum)
  // reliably. mem_size_e is logic [1:0].
  localparam int unsigned MemSizeWidth = 2;

  // The eighteen W/D instr_op_e encodings reaching the AMO arithmetic unit
  // collapse to nine semantic operations. Keeping the full 8-bit package enum
  // per entry wastes storage and, with two allocation ports, previously
  // required a banked multi-write RAM plus a live-value table. This compact
  // semantic code reproduces every AMO result; INVALID preserves the old-value
  // default for malformed input.
  typedef enum logic [3:0] {
    AMO_KIND_SWAP    = 4'd0,
    AMO_KIND_ADD     = 4'd1,
    AMO_KIND_XOR     = 4'd2,
    AMO_KIND_AND     = 4'd3,
    AMO_KIND_OR      = 4'd4,
    AMO_KIND_MIN     = 4'd5,
    AMO_KIND_MAX     = 4'd6,
    AMO_KIND_MINU    = 4'd7,
    AMO_KIND_MAXU    = 4'd8,
    AMO_KIND_INVALID = 4'd15
  } amo_kind_e;

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

  // Compare two live ROB tags using one common age origin.  Dependency-mask
  // maintenance snapshots the origin with each allocation bundle, so this
  // arithmetic is confined to the mask-state D cone and never reaches memory
  // issue selection directly.
  function automatic logic is_older_than(input logic [ReorderBufferTagWidth-1:0] source_tag,
                                         input logic [ReorderBufferTagWidth-1:0] dest_tag,
                                         input logic [ReorderBufferTagWidth-1:0] head);
    logic [ReorderBufferTagWidth:0] source_age;
    logic [ReorderBufferTagWidth:0] dest_age;
    begin
      source_age = {1'b0, source_tag} - {1'b0, head};
      dest_age = {1'b0, dest_tag} - {1'b0, head};
      is_older_than = source_age < dest_age;
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

  function automatic logic is_cached_addr(input logic [XLEN-1:0] addr);
    logic [XLEN-1:0] cached_base;
    logic [XLEN-1:0] cached_limit;
    begin
      // XLEN'() casts, not [XLEN-1:0] part-selects: the parameters are
      // 32-bit ints, so a 64-bit part-select would be out of range.
      cached_base = XLEN'(CACHED_BASE);
      cached_limit = XLEN'(CACHED_BASE) + XLEN'(CACHED_SIZE_BYTES);
      is_cached_addr = (addr >= cached_base) && (addr < cached_limit);
    end
  endfunction

  function automatic amo_kind_e encode_amo_kind(input riscv_pkg::instr_op_e op);
    case (op)
      riscv_pkg::AMOSWAP_W: encode_amo_kind = AMO_KIND_SWAP;
      riscv_pkg::AMOADD_W:  encode_amo_kind = AMO_KIND_ADD;
      riscv_pkg::AMOXOR_W:  encode_amo_kind = AMO_KIND_XOR;
      riscv_pkg::AMOAND_W:  encode_amo_kind = AMO_KIND_AND;
      riscv_pkg::AMOOR_W:   encode_amo_kind = AMO_KIND_OR;
      riscv_pkg::AMOMIN_W:  encode_amo_kind = AMO_KIND_MIN;
      riscv_pkg::AMOMAX_W:  encode_amo_kind = AMO_KIND_MAX;
      riscv_pkg::AMOMINU_W: encode_amo_kind = AMO_KIND_MINU;
      riscv_pkg::AMOMAXU_W: encode_amo_kind = AMO_KIND_MAXU;
      riscv_pkg::AMOSWAP_D: encode_amo_kind = AMO_KIND_SWAP;
      riscv_pkg::AMOADD_D:  encode_amo_kind = AMO_KIND_ADD;
      riscv_pkg::AMOXOR_D:  encode_amo_kind = AMO_KIND_XOR;
      riscv_pkg::AMOAND_D:  encode_amo_kind = AMO_KIND_AND;
      riscv_pkg::AMOOR_D:   encode_amo_kind = AMO_KIND_OR;
      riscv_pkg::AMOMIN_D:  encode_amo_kind = AMO_KIND_MIN;
      riscv_pkg::AMOMAX_D:  encode_amo_kind = AMO_KIND_MAX;
      riscv_pkg::AMOMINU_D: encode_amo_kind = AMO_KIND_MINU;
      riscv_pkg::AMOMAXU_D: encode_amo_kind = AMO_KIND_MAXU;
      default:              encode_amo_kind = AMO_KIND_INVALID;
    endcase
  endfunction

  // ===========================================================================
  // Storage -- Sparse queue with FF-based control plus LUTRAM payloads
  // ===========================================================================

  // Head and tail pointers (extra MSB for full/empty distinction)
  logic      [             PtrWidth-1:0]               head_ptr;
  logic      [             PtrWidth-1:0]               tail_ptr;

  // Index extraction (lower bits)
  wire       [             IdxWidth-1:0]               head_idx = head_ptr[IdxWidth-1:0];
  // Per-entry 1-bit flags (packed vectors for bulk operations)
  logic      [                DEPTH-1:0]               lq_valid;
  logic      [                DEPTH-1:0]               lq_is_fp;
  logic      [                DEPTH-1:0]               lq_addr_valid;
  logic      [                DEPTH-1:0]               lq_sign_ext;
  logic      [                DEPTH-1:0]               lq_is_mmio;
  logic      [                DEPTH-1:0]               lq_issued;
  logic      [                DEPTH-1:0]               lq_data_valid;
  logic      [                DEPTH-1:0]               lq_forwarded;
  logic      [                DEPTH-1:0]               lq_is_lr;
  logic      [                DEPTH-1:0]               lq_is_amo;

  // Per-entry multi-bit fields
  logic      [ReorderBufferTagWidth-1:0]               lq_rob_tag                        [DEPTH];
  // Two accepted allocations always target distinct entries, so ordinary
  // per-entry FF writes provide the required two write ports without the
  // bank-select/LVT structure of a multi-write distributed RAM.
  (* ram_style = "registers" *)
  amo_kind_e                                           lq_amo_kind                       [DEPTH];
  (* ram_style = "registers" *)
  logic      [         MemSizeWidth-1:0]               lq_size                           [DEPTH];
  logic      [         MemSizeWidth-1:0]               lq_size_issue_cdb_rd;
  logic      [                 XLEN-1:0]               lq_address_issue_mem_rd;
  logic      [                 XLEN-1:0]               lq_amo_rs2_rd;
  logic      [             IdxWidth-1:0]               amo_entry_idx;
  logic                                                full;
  logic                                                full_for_2;

  // Slot-1 / slot-2 alloc targets and write enables.  alloc_target points at
  // the first free slot from tail_ptr; alloc_target_2 points at the second
  // free slot.  When slot-1 is invalid but slot-2 is, slot-2 takes alloc_target.
  logic      [             PtrWidth-1:0]               alloc_target_2;
  logic                                                slot1_alloc_en;
  logic                                                slot2_alloc_en;
  logic      [             IdxWidth-1:0]               slot2_alloc_idx;
  logic      [                DEPTH-1:0]               first_target_oh;
  logic      [                DEPTH-1:0]               second_target_oh;
  // Preserve the entry-local steering boundary. Without it Vivado can factor
  // all indexed control/metadata writes into serial, high-fanout parity terms.
  (* keep = "true", max_fanout = 16 *)
  logic      [                DEPTH-1:0]               slot1_alloc_oh;
  (* keep = "true", max_fanout = 16 *)
  logic      [                DEPTH-1:0]               slot2_alloc_oh;

  // Compact AMO-kind write staging. A newly allocated LQ entry cannot produce
  // a memory response in the following cycle: an address update must first
  // match the now-live entry, then SQ-check staging/phase-2 must launch its
  // read. Delaying this data-only payload write one edge is therefore invisible
  // architecturally. Registered accepted-request bits qualify the delayed
  // writes without carrying either live allocation request into this stage.
  logic      [                      1:0]               amo_kind_alloc_present_q;
  logic      [                      1:0][IdxWidth-1:0] amo_kind_alloc_idx_q;
  amo_kind_e                                           amo_kind_alloc_data_q             [    2];

  // Exact older-AMO dependencies, stored by physical LQ identity.  Row i is
  // the set of still-pending AMO slots architecturally older than entry i.
  // A one-cycle valid mirror detects each newly-live physical generation;
  // tag-age comparisons terminate at the dependency FFs and dispatch does not
  // drive any dependency-event state.
  // A separate registered reduction gives issue selection one direct bit per
  // entry and removes the old live ROB-head subtract/min/compare network.
  logic      [                DEPTH-1:0]               older_amo_dep_q                   [DEPTH];
  logic      [                DEPTH-1:0]               older_amo_dep_d                   [DEPTH];
  logic      [                DEPTH-1:0]               older_amo_block_q;
  logic      [                DEPTH-1:0]               older_amo_block_d;
  logic      [                DEPTH-1:0]               pending_amo_phys;
  logic      [                DEPTH-1:0]               dep_done_oh;
  logic      [                DEPTH-1:0]               dep_flush_kill;
  logic      [                DEPTH-1:0]               dep_free_oh;
  logic      [                DEPTH-1:0]               dep_live_src;
  logic      [                DEPTH-1:0]               dep_replaced_oh;
  logic      [                DEPTH-1:0]               dep_new_amo_src;
  logic      [                DEPTH-1:0]               dep_identity_valid_q;
  logic      [ReorderBufferTagWidth-1:0]               dep_head_q;

  // Reservation register (LR/SC)
  logic                                                reservation_valid;
  logic      [                 XLEN-1:0]               reservation_addr;
  assign o_reservation_valid = reservation_valid;
  assign o_reservation_addr  = reservation_addr;

  // AMO FSM
  typedef enum logic {
    AMO_IDLE,
    AMO_WRITE_ACTIVE
  } amo_state_e;
  amo_state_e                              amo_state;
  logic       [    XLEN-1:0]               amo_old_value;
  logic       [    XLEN-1:0]               amo_write_addr_q;
  logic       [    XLEN-1:0]               amo_write_data_q;
  logic       [    XLEN-1:0]               amo_minmax_rs2_q;
  logic                                    amo_is_d_q;
  logic                                    amo_is_minmax_q;
  logic                                    amo_minmax_select_old_q;
  logic       [    XLEN-1:0]               amo_write_value;

  // ===========================================================================
  // lq_data LUTRAM — FLEN-wide single-beat payloads
  // ===========================================================================
  // lq_data payload is only read at issue_cdb_idx (CDB broadcast).
  // Writes come from two independent sources that can overlap:
  //   Port 0 (mem resp): memory response (dedicated)
  //   Port 1 (local):    cache hit / SQ forward / AMO write completion
  // Value semantics: DOUBLE loads store the full aligned beat; every other
  // load stores its extracted-int result (or, for FLW, the addressed raw
  // word) zero-extended into FLEN. NaN-boxing happens at CDB broadcast.

  // Forward declaration (used as LUTRAM read address)
  logic       [IdxWidth-1:0]               issue_cdb_idx;

  logic       [    FLEN-1:0]               lq_data_rd;  // LUTRAM async read at issue_cdb_idx

  // Write port signals
  logic       [         1:0]               lq_data_we;
  logic       [         1:0][IdxWidth-1:0] lq_data_wr_addr;
  logic       [         1:0][    FLEN-1:0] lq_data_wd;

  mwp_dist_ram #(
      .ADDR_WIDTH(IdxWidth),
      .DATA_WIDTH(FLEN),
      .NUM_WRITE_PORTS(2)
  ) u_lq_data (
      .i_clk,
      .i_write_enable (lq_data_we),
      .i_write_address(lq_data_wr_addr),
      .i_write_data   (lq_data_wd),
      .i_read_address (issue_cdb_idx),
      .o_read_data    (lq_data_rd)
  );

  // ===========================================================================
  // Internal Signals
  // ===========================================================================

  logic empty;
  logic [CountWidth-1:0] count;
  // TIMING: same cap as the reservation stations' dispatch_full_q — the
  // registered backpressure bit rides the dispatch stall tree into
  // RAT/ROB/front-end write gating across the die.
  (* max_fanout = 32 *) logic dispatch_full_q;
  (* max_fanout = 32 *) logic dispatch_full_for_2_q;
  logic [CountWidth-1:0] dispatch_count_next;

  // Issue selection
  logic issue_cdb_found;  // Phase A: entry with data_valid
  // issue_cdb_idx declared above (before LUTRAM instances)
  logic issue_mem_found;  // Phase B: entry ready for memory
  logic [IdxWidth-1:0] issue_mem_idx;
  logic [IdxWidth-1:0] issue_mem_stored_idx;
  logic issue_mem_from_update;
  logic [XLEN-1:0] issue_mem_addr;
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
  // max_fanout: this staged address has both local LQ consumers and the SQ
  // disambiguation CAM. Keep the primary auto-replicable for those local
  // consumers; the three explicit sister registers below provide four SQ-side
  // physical anchors, two entries per anchor. The earlier two-anchor split
  // still left a measured fo=12, 0.514 ns first route hop on the placed WNS
  // path, so the four-way split targets routing without changing a cycle.
  (* max_fanout = 16 *) logic [XLEN-1:0] sq_check_addr_q;
  // Port-split replicas: exactly the same D/CE as sq_check_addr_q. Keep the
  // banks distinct so entries 2..3, 4..5, and 6..7 can place their compare
  // cones around independent anchors. A fanout cap of eight is above each
  // two-entry bank's expected load while discouraging a new broad net.
  (* dont_touch = "true", keep = "true", max_fanout = 8 *)
  logic [XLEN-1:0] sq_check_addr_q_b;
  (* dont_touch = "true", keep = "true", max_fanout = 8 *)
  logic [XLEN-1:0] sq_check_addr_q_c;
  (* dont_touch = "true", keep = "true", max_fanout = 8 *)
  logic [XLEN-1:0] sq_check_addr_q_d;
  riscv_pkg::mem_size_e sq_check_size_q;
  logic sq_check_is_fp_q;
  logic sq_check_sign_ext_q;
  logic sq_check_is_mmio_q;
  logic sq_check_is_lr_q;
  logic sq_check_is_amo_q;
  logic sq_check_no_older_store_q;
  logic [DEPTH-1:0] sq_check_in_flight_mask;
  logic [DEPTH-1:0] sq_check_in_flight_mask_next;
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

  // Memory issued entry tracking. Fast-BRAM/MMIO responses arrive exactly one
  // cycle after router terminal accept, while cached requests retain this
  // single owner until their variable-latency response. Before a parked MMIO
  // terminally accepts, the router's registered pending feedback blocks every
  // later handoff. mem_outstanding plus issued_idx is therefore sufficient for
  // both back-to-back fast loads and the serialized cached tier; issued_idx
  // names the entry that owns the pending response.
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
  // Snapshot of "the outstanding load targets the cached tier", captured at
  // launch alongside issued_addr. It clears slow_outstanding when the cached
  // response is accepted.
  logic issued_is_cached;
  logic issued_sign_ext;
  logic [ReorderBufferTagWidth-1:0] issued_rob_tag;
  amo_kind_e issued_amo_kind;
  logic [XLEN-1:0] issued_amo_rs2;
  logic drop_mem_response_pending;  // Drop the next owed response after flush
  // Registered "a cached (multi-cycle) load is in flight". Set when a cached
  // load launches; held across the hierarchy and any partial-flush drain until
  // the response is accepted or dropped. It gates ALL memory launches so the
  // single issued-response snapshot cannot be overwritten. Router pending
  // feedback supplies the corresponding pre-accept protection for MMIO.
  logic slow_outstanding;
  logic issued_cached_line_invalidated;
  logic issued_cached_line_invalidate_now;

  // Load unit wires
  logic [XLEN-1:0] lu_data_out;

  // Response acceptance/drain control
  logic flush_all_entries;
  logic issued_entry_flushed;
  logic full_flush_response_drain;
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
  ) u_lq_amo_rs2 (
      .i_clk,
      .i_write_enable (lq_addr_update_we),
      .i_write_address(lq_addr_update_idx),
      .i_write_data   (i_addr_update.amo_rs2),
      // Capture the operand at launch, after the required SQ-check phase has
      // given the address-update write a full edge to become resident.
      .i_read_address (sq_check_idx),
      .o_read_data    (lq_amo_rs2_rd)
  );

  // ===========================================================================
  // AMO ALU (consumed at the memory-response register boundary)
  // ===========================================================================
  // MIN/MAX is deliberately absent from these result functions. Its wide
  // comparison feeds one predicate FF below instead of the XLEN-wide result
  // register. The write-active phase then selects between held old/rs2 values
  // with a shallow mux. This keeps response -> write-active latency unchanged
  // while removing compare-carry -> 64 result-bit D paths.
  function automatic logic [XLEN-1:0] amo_non_minmax_compute(
      input amo_kind_e kind, input logic [XLEN-1:0] old_val, input logic [XLEN-1:0] rs2);
    case (kind)
      AMO_KIND_SWAP: amo_non_minmax_compute = rs2;
      AMO_KIND_ADD:  amo_non_minmax_compute = old_val + rs2;
      AMO_KIND_XOR:  amo_non_minmax_compute = old_val ^ rs2;
      AMO_KIND_AND:  amo_non_minmax_compute = old_val & rs2;
      AMO_KIND_OR:   amo_non_minmax_compute = old_val | rs2;
      default:       amo_non_minmax_compute = old_val;
    endcase
  endfunction

  // Word-width AMO ALU for the non-MIN/MAX .W forms. At XLEN=64 the
  // arithmetic remains a 32-bit operation regardless of register width.
  function automatic logic [31:0] amo_non_minmax_compute32(
      input amo_kind_e kind, input logic [31:0] old_val, input logic [31:0] rs2);
    case (kind)
      AMO_KIND_SWAP: amo_non_minmax_compute32 = rs2;
      AMO_KIND_ADD:  amo_non_minmax_compute32 = old_val + rs2;
      AMO_KIND_XOR:  amo_non_minmax_compute32 = old_val ^ rs2;
      AMO_KIND_AND:  amo_non_minmax_compute32 = old_val & rs2;
      AMO_KIND_OR:   amo_non_minmax_compute32 = old_val | rs2;
      default:       amo_non_minmax_compute32 = old_val;
    endcase
  endfunction

  function automatic logic is_amo_minmax_kind(input amo_kind_e kind);
    case (kind)
      AMO_KIND_MIN, AMO_KIND_MAX, AMO_KIND_MINU, AMO_KIND_MAXU: is_amo_minmax_kind = 1'b1;
      default:                                                  is_amo_minmax_kind = 1'b0;
    endcase
  endfunction

  function automatic logic amo_minmax_select_old(
      input amo_kind_e kind, input logic [XLEN-1:0] old_val, input logic [XLEN-1:0] rs2);
    case (kind)
      AMO_KIND_MIN:  amo_minmax_select_old = ($signed(old_val) < $signed(rs2));
      AMO_KIND_MAX:  amo_minmax_select_old = ($signed(old_val) > $signed(rs2));
      AMO_KIND_MINU: amo_minmax_select_old = (old_val < rs2);
      AMO_KIND_MAXU: amo_minmax_select_old = (old_val > rs2);
      default:       amo_minmax_select_old = 1'b0;
    endcase
  endfunction

  // AMO*.W compares exactly the low word, including signedness. This cannot
  // reuse the XLEN-wide predicate at RV64: rs2[63:32] is architecturally
  // irrelevant and the returned word's sign extension is an rd semantic, not
  // a widening of the memory operation.
  function automatic logic amo_minmax_select_old32(
      input amo_kind_e kind, input logic [31:0] old_val, input logic [31:0] rs2);
    case (kind)
      AMO_KIND_MIN:  amo_minmax_select_old32 = ($signed(old_val) < $signed(rs2));
      AMO_KIND_MAX:  amo_minmax_select_old32 = ($signed(old_val) > $signed(rs2));
      AMO_KIND_MINU: amo_minmax_select_old32 = (old_val < rs2);
      AMO_KIND_MAXU: amo_minmax_select_old32 = (old_val > rs2);
      default:       amo_minmax_select_old32 = 1'b0;
    endcase
  endfunction

  // AMO cache invalidation: invalidate L0 cache when AMO write completes
  logic amo_cache_inv;
  assign amo_cache_inv = (amo_state == AMO_WRITE_ACTIVE) && i_amo_mem_write_done;
  // Dword granule: the response beat fills a full L0 dword line, so a store
  // landing in EITHER word of the in-flight dword must suppress the fill.
  assign issued_cached_line_invalidate_now =
      mem_outstanding && issued_is_cached && i_cache_invalidate_valid &&
      (i_cache_invalidate_addr[XLEN-1:3] == issued_addr[XLEN-1:3]);

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
  //
  // Flush gating mirrors the ROB's alloc_en (!i_flush_all && !i_flush_en):
  // dispatch presents alloc requests un-flush-gated (the dispatch-fire cone
  // must not absorb the flush broadcast — on trap/MRET/FENCE.I pulse cycles
  // the frontend kill is edge-delayed and a straggler — wrong-path, or
  // FENCE.I's to-be-refetched next instruction — legitimately presents here), so every allocation target decides locally
  // and must reach the same verdict on the same cycle.  The ROB rejects;
  // without these terms the LQ accepted, and because the alloc arm runs
  // AFTER the partial-flush invalidate loop in the same always_ff
  // (last-write-wins), a flush_en-cycle alloc wrote a GHOST entry — valid,
  // with a tag the ROB never allocated: a slot leak, then a duplicate-tag
  // pair once the ROB tail re-issues the tag (tag uniqueness is a formal
  // precondition here and in the SQ).  flush_all cycles were already benign
  // for lq_valid (priority else-if branch) but still wrote the no-reset
  // payload RAMs; the gate silences those too.
  logic alloc_flush_ok;
  assign alloc_flush_ok = !i_flush_all && !i_flush_en;
  assign slot1_alloc_en = i_alloc.valid && !full && alloc_flush_ok;
  assign slot2_alloc_en = i_alloc_2.valid && (slot1_alloc_en ? !full_for_2 : !full) &&
                          alloc_flush_ok;
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

  // Head-priority uses the registered match: for ordinary loads it is a
  // fairness/performance hint, and for head MMIO/LR loads it is the
  // staging-slot starvation fix (the head entry stays head, so a 1-cycle-
  // stale match is safe); the exact live ROB-head issue gates for
  // MMIO/LR/AMO are downstream in sq_check_entry_issueable.
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
  logic stored_scan_found;
  logic [IdxWidth-1:0] stored_scan_idx;
  logic [IdxWidth-1:0] stored_scan_pos;
  logic [DEPTH-1:0] stored_scan_onehot;
  logic [ReorderBufferTagWidth-1:0] stored_scan_rob_tag;

  logic update_scan_found;
  logic [IdxWidth-1:0] update_scan_idx;
  logic [IdxWidth-1:0] update_scan_pos;
  logic [DEPTH-1:0] update_scan_onehot;
  logic [ReorderBufferTagWidth-1:0] update_scan_rob_tag;
  logic head_mem_stored_found;
  logic [IdxWidth-1:0] head_mem_stored_idx;
  logic [DEPTH-1:0] head_mem_stored_onehot;
  logic [ReorderBufferTagWidth-1:0] head_mem_stored_rob_tag;
  logic head_mem_update_found;
  logic [IdxWidth-1:0] head_mem_update_idx;
  logic [DEPTH-1:0] head_mem_update_onehot;
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
      .blocked_by_amo_phys_q(older_amo_block_q),
      .head_idx(head_idx),
      .i_sq_committed_empty(i_sq_committed_empty),
      .o_issue_cdb_found(issue_cdb_found),
      .o_issue_cdb_idx(issue_cdb_idx),
      .o_stored_scan_found(stored_scan_found),
      .o_stored_scan_idx(stored_scan_idx),
      .o_stored_scan_pos(stored_scan_pos),
      .o_stored_scan_onehot(stored_scan_onehot),
      .o_stored_scan_rob_tag(stored_scan_rob_tag),
      .o_update_scan_found(update_scan_found),
      .o_update_scan_idx(update_scan_idx),
      .o_update_scan_pos(update_scan_pos),
      .o_update_scan_onehot(update_scan_onehot),
      .o_update_scan_rob_tag(update_scan_rob_tag),
      .o_head_mem_stored_found(head_mem_stored_found),
      .o_head_mem_stored_idx(head_mem_stored_idx),
      .o_head_mem_stored_onehot(head_mem_stored_onehot),
      .o_head_mem_stored_rob_tag(head_mem_stored_rob_tag),
      .o_head_mem_update_found(head_mem_update_found),
      .o_head_mem_update_idx(head_mem_update_idx),
      .o_head_mem_update_onehot(head_mem_update_onehot),
      .o_head_mem_update_rob_tag(head_mem_update_rob_tag)
  );

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
  //   2. bus_busy — i_mem_bus_busy or one-cycle post-busy write holdoff
  //   3. amo      — older valid AMO in the LQ with !data_valid
  //                 (any_pending_amo is an approximation: we don't check the
  //                 precise scan order, but in practice an AMO older than
  //                 the head load is the only reason it would block).  This
  //                 also catches the SQ-committed-empty gate for AMOs at head.
  //   4. sq_wait  — entry is currently staged in sq_check but !sq_check_phase2
  //                 (sq_check_phase2 takes a cycle to arm after the SQ sees
  //                 the staged request).
  //   5. staging  — everything else (one-cycle addr_valid → sq_check_capture
  //                 delay, drop_mem_response_pending, etc.)

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

  // Staging sub-decomposition (priority-ordered, mutually exclusive; the four
  // terms partition o_head_load_bb_staging exactly):
  //   other_in_staging — the single sq_check staging register is occupied by
  //                      a DIFFERENT load (the serialization cost of one
  //                      staging pipe);
  //   launch_gated     — the head load IS staged with phase2 armed but the
  //                      launch is still gated (drop-response window,
  //                      sq_can_issue qualifiers, launch arbitration);
  //   slow_outstanding — staging is free but a cached-tier load in flight
  //                      serializes all memory launches;
  //   capture_gap      — staging free, no cached load in flight: the head
  //                      load just hasn't been captured yet (selector /
  //                      capture-recycle bubble).
  logic head_bbs_base;
  assign head_bbs_base = o_head_load_bb_staging;
  assign o_head_load_bbs_other_in_staging = head_bbs_base && sq_check_pending &&
                                            (sq_check_idx != head_entry_idx);
  assign o_head_load_bbs_launch_gated = head_bbs_base && sq_check_pending &&
                                        (sq_check_idx == head_entry_idx) && sq_check_phase2;
  assign o_head_load_bbs_slow_outstanding = head_bbs_base && !sq_check_pending && slow_outstanding;
  assign o_head_load_bbs_capture_gap = head_bbs_base && !sq_check_pending && !slow_outstanding;

  // ROB tag of the winning Phase B entry (extracted alongside idx to avoid
  // a post-encoder 8-to-1 MUX on lq_rob_tag[issue_mem_idx])
  logic [ReorderBufferTagWidth-1:0] issue_mem_rob_tag;

  logic [IdxWidth-1:0] stored_issue_idx;
  logic [ReorderBufferTagWidth-1:0] stored_issue_rob_tag;
  logic [ReorderBufferTagWidth-1:0] update_issue_rob_tag;
  logic [DEPTH-1:0] issue_mem_onehot;
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
    issue_mem_onehot      = '0;

    if (head_mem_stored_found) begin
      issue_mem_found   = 1'b1;
      issue_mem_idx     = head_mem_stored_idx;
      issue_mem_rob_tag = stored_issue_rob_tag;
      // Preserve the selector's one-hot head identity. Re-decoding
      // head_mem_stored_idx here puts the head-priority cone back onto every
      // sq_check capture/feedback bit.
      issue_mem_onehot  = head_mem_stored_onehot;
    end else if (i_addr_update.valid && head_mem_update_found) begin
      issue_mem_found       = 1'b1;
      issue_mem_idx         = head_mem_update_idx;
      issue_mem_from_update = 1'b1;
      issue_mem_rob_tag     = update_issue_rob_tag;
      issue_mem_onehot      = head_mem_update_onehot;
    end else if (update_scan_wins) begin
      issue_mem_found       = 1'b1;
      issue_mem_idx         = update_scan_idx;
      issue_mem_from_update = 1'b1;
      issue_mem_rob_tag     = update_scan_rob_tag;
      issue_mem_onehot      = update_scan_onehot;
    end else if (stored_scan_found) begin
      issue_mem_found   = 1'b1;
      issue_mem_idx     = stored_scan_idx;
      issue_mem_rob_tag = stored_scan_rob_tag;
      issue_mem_onehot  = stored_scan_onehot;
    end
  end

  // ===========================================================================
  // SQ Disambiguation Interface (combinational)
  // ===========================================================================
  // For Phase B candidate: drive SQ check ports

  assign sq_check_entry_valid = sq_check_pending;
  assign o_mem_addr_valid = sq_check_entry_valid;

  // MMIO loads may probe the SQ once they reach the ROB head, even while an
  // older committed store is still draining. The probe and LQ-to-router
  // handoff are side-effect-free; the router parks the request until
  // i_sq_committed_empty permits the irreversible device read.
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
  logic sq_check_is_cached_region;
  logic sq_commit_check_block;
  assign sq_check_misaligned = i_trap_misaligned_accesses &&
      sq_check_entry_valid && sq_check_entry_issueable &&
      is_load_misaligned(
      sq_check_size_q, sq_check_addr_q
  );
  assign sq_check_is_cached_region = is_cached_addr(sq_check_addr_q);
  assign sq_commit_check_block =
      i_sq_commit_pending && sq_check_entry_valid && sq_check_is_cached_region;
  // older_amo_write_pending releases the staged entry instead of letting it
  // camp: a load fenced behind an un-written older AMO would otherwise hold
  // staging until the AMO's write completes.  Released entries stay
  // valid/un-issued and re-enter the scan after the AMO completes; the
  // oldest-first scan then always prefers the AMO itself once it is eligible.
  assign sq_check_will_clear = sq_check_pending &&
      (!sq_check_entry_valid || cache_hit_fast_path || sq_do_forward ||
       launch_mem_issue || misalign_bypass_fire || older_amo_write_pending);

  // A stored-address MMIO candidate at the ROB head is admitted by both the
  // normal scan and the higher-priority ROB-head path.  The latter always
  // wins, making the normal-scan admission deliberately redundant at the LQ
  // boundary.  The
  // selected candidate's MMIO classification is captured into the registered
  // sq_check payload. The downstream router enforces device-drain ordering at
  // its irreversible read-accept boundary. The is_younger comparison uses
  // issue_mem_rob_tag extracted alongside the priority encoder output to avoid
  // a post-encoder 8-to-1 MUX on lq_rob_tag[issue_mem_idx].
  //
  // The SQ-commit/cache interlock is applied after capture via the registered
  // sq_check_* payload.  Keeping it off the capture gate avoids a same-cycle
  // candidate-address RAM read on the SQ-check control/mask update path.
  // Register/controller-sourced gate terms settle early; factoring them into
  // one product lets the late issue_mem_found / will_clear legs enter the
  // capture/replace products through a single final AND each (pure AND
  // re-association, bit-identical).
  logic sq_check_gate_early;
  assign sq_check_gate_early = !drop_mem_response_pending && !i_mem_bus_busy &&
      !i_flush_all && !i_flush_en;

  assign sq_check_capture = (!sq_check_pending || sq_check_will_clear) &&
      issue_mem_found && sq_check_gate_early;

  // TIMING: the age check "staged entry is younger than the incoming
  // candidate" is precomputed per entry from registered operands
  // (sq_check_rob_tag_q, lq_rob_tag[i], i_rob_head_tag) and the late
  // issue_mem_onehot then just selects one precomputed bit — replacing the
  // post-encoder subtract/compare pair on the sq_check payload clock-enable
  // (the WNS-limiting cone). |(mask & onehot) === is_younger(staged,
  // lq_rob_tag[issue_mem_idx], head) because issue_mem_onehot is one-hot at
  // issue_mem_idx and issue_mem_rob_tag == lq_rob_tag[issue_mem_idx]; the
  // onehot='0 (not-found) case is gated by issue_mem_found.
  logic [DEPTH-1:0] staged_younger_than_entry;
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      staged_younger_than_entry[i] = is_younger(sq_check_rob_tag_q, lq_rob_tag[i], i_rob_head_tag);
    end
  end
  logic staged_younger_than_candidate;
  assign staged_younger_than_candidate = |(staged_younger_than_entry & issue_mem_onehot);

  assign sq_check_replace = sq_check_pending && issue_mem_found && sq_check_gate_early &&
      (!sq_check_entry_valid || staged_younger_than_candidate);

  // Always output registered check parameters regardless of valid.  The SQ
  // gates on i_sq_check_capture_valid at its output register
  // (o_sq_forward.match <= i_sq_check_capture_valid ? fwd_found_match : 1'b0),
  // so stale values are harmless.
  // Removing the addr/tag/size MUX breaks the cross-module timing path:
  //   SQ sq_valid → o_mem_write_en → LQ i_mem_bus_busy → o_sq_check_valid
  //   → addr MUX → SQ i_sq_check_addr → address compare → o_sq_forward_reg
  // Port-split replicas drive entries 2..3, 4..5, and 6..7 respectively;
  // the primary drives entries 0..1. All four values are identical — the
  // split is only a physical placement boundary.
  assign o_sq_check_addr_b = sq_check_addr_q_b;
  assign o_sq_check_addr_c = sq_check_addr_q_c;
  assign o_sq_check_addr_d = sq_check_addr_q_d;

  always_comb begin
    o_sq_check_valid   = 1'b0;
    o_sq_check_addr    = sq_check_addr_q;
    o_sq_check_rob_tag = sq_check_rob_tag_q;
    o_sq_check_size    = sq_check_size_q;

    if (!i_flush_all && !i_flush_en && !drop_mem_response_pending &&
        !i_mem_bus_busy && !sq_commit_check_block && sq_check_entry_issueable &&
        !sq_check_misaligned &&
        !(sq_check_no_older_store_q || i_sq_empty)) begin
      o_sq_check_valid = 1'b1;
    end

    // Capture-enable variant: identical minus the flush terms AND minus
    // !sq_commit_check_block (see port comment). The block term is
    // commit_en-derived (i_sq_commit_pending sits behind the trap unit's
    // combinational o_trap_drain_wait commit-hold), which kept the
    // registered trap pulse on the capture cone; its ordering purpose is
    // enforced at the consumers via sq_commit_interlock (sq_can_issue and
    // sq_do_forward both require !sq_commit_interlock), so a capture during
    // a blocked cycle is architecturally valid data that simply cannot be
    // consumed until the interlock lifts -- and the capture refreshes every
    // enabled cycle, so it can never go stale across the block. Every
    // remaining term is registered/early state.
    o_sq_check_capture_valid = 1'b0;
    if (!drop_mem_response_pending &&
        !i_mem_bus_busy && sq_check_entry_issueable &&
        !sq_check_misaligned &&
        !(sq_check_no_older_store_q || i_sq_empty)) begin
      o_sq_check_capture_valid = 1'b1;
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
  logic sq_commit_interlock;
  assign sq_no_older_store   = sq_check_no_older_store_q || i_sq_empty;
  assign sq_commit_interlock = sq_commit_check_block && sq_check_phase2;

  // AMO write fence: AMOs live in the LQ, not the SQ, so SQ disambiguation
  // cannot see their pending memory writes.  The registered per-entry block
  // vector names the exact dependency row held by SQ-check's registered
  // one-hot identity. Legal ROB-tail allocation cannot introduce a new AMO
  // older than an entry already in SQ-check, so the registered bitmap is the
  // complete fence and no live ROB-head arithmetic remains on this path.
  logic older_amo_write_pending;
  assign older_amo_write_pending = |(older_amo_block_q & sq_check_in_flight_mask);

  // A staged head AMO with the committed queue empty cannot have older SQ
  // stores at all (committed == older-than-head; everything uncommitted is
  // younger), so it need not wait for younger stores' addresses to resolve.
  logic sq_head_amo_clear;
  assign sq_head_amo_clear = sq_check_is_amo_q &&
      (sq_check_rob_tag_q == i_rob_head_tag) && i_sq_committed_empty;

  assign sq_can_issue = sq_check_phase2 && sq_check_entry_issueable &&
      !sq_check_misaligned &&
      !sq_commit_interlock &&
      !older_amo_write_pending &&
      (sq_no_older_store || sq_head_amo_clear ||
       (i_sq_all_older_addrs_known && !i_sq_forward.match));
  // i_sq_all_older_addrs_known is REQUIRED for forwarding, not just for the
  // no-match memory-issue path above: the CAM's can_forward/data reflect only
  // the older stores whose addresses had resolved in the scan cycle.  If an
  // older store's address is still unknown, it may resolve (as early as the
  // cycle this registered result is consumed) to the same address as a store
  // newer than the CAM winner — forwarding the winner's data would then
  // return stale bytes.  all_older_addrs_known is registered from the same
  // scan as can_forward, so the pair is coherent.  (rv64ui/ld_st test 22
  // caught this: lw forwarded a same-address store left over from the
  // previous test macro while the directly-preceding sw's address was one
  // cycle from resolving.)
  assign sq_do_forward = ENABLE_SQ_FORWARD_FAST_PATH
      && sq_check_phase2 && sq_check_entry_issueable && !sq_no_older_store &&
      !sq_check_misaligned &&
      !sq_commit_interlock &&
      !older_amo_write_pending &&
      i_sq_all_older_addrs_known &&
      i_sq_forward.can_forward
      && !sq_check_is_mmio_q && !sq_check_is_lr_q && !sq_check_is_amo_q;


  assign flush_all_entries = i_flush_en && !i_early_recovery_flush &&
      (i_rob_head_tag == (i_flush_tag + ReorderBufferTagWidth'(1)));

  // Only the fast (BRAM/MMIO) tier has fixed 1-cycle latency; the cached tier
  // completes over a handshake with unbounded latency. If a partial flush
  // kills the outstanding load, drop that next response explicitly so the slot
  // can be safely reused before the stale data returns. A full flush clears all
  // entries at the edge; a same-cycle response is therefore drained here rather
  // than accepted, so it cannot complete a killed load or refill the persistent
  // L0 cache from a flushed context.
  assign issued_entry_flushed = i_flush_en && mem_outstanding && lq_valid[issued_idx] &&
      (flush_all_entries || is_younger(
      issued_rob_tag, i_flush_tag, i_rob_head_tag
  ));
  assign full_flush_response_drain = i_flush_all && i_mem_read_valid && mem_outstanding;
  assign accept_mem_response = i_mem_read_valid && mem_outstanding &&
                               !i_flush_all && !drop_mem_response_pending &&
                               !issued_entry_flushed && lq_valid[issued_idx];
  assign drop_mem_response_now = i_mem_read_valid &&
                                 (full_flush_response_drain ||
                                  drop_mem_response_pending || issued_entry_flushed ||
                                  (mem_outstanding && !lq_valid[issued_idx]));

  // ===========================================================================
  // Load Unit Instance (byte/halfword extraction + sign extension)
  // ===========================================================================
  // Driven by the entry that is receiving memory response data.

  logic lu_is_byte;
  logic lu_is_half;
  logic lu_is_unsigned;
  logic [XLEN-1:0] lu_addr;
  logic [riscv_pkg::MemDataBits-1:0] lu_raw_data;

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
  logic                              cache_lookup_hit;
  logic [riscv_pkg::MemDataBits-1:0] cache_lookup_data;
  logic                              cache_fill_response_valid;
  logic                              cache_fill_valid;
  logic [                  XLEN-1:0] cache_fill_addr;
  logic [riscv_pkg::MemDataBits-1:0] cache_fill_data;

  lq_l0_cache #(
      .DEPTH(128),
      .XLEN (XLEN)
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

      // Invalidation: SQ drain on port 1, AMO write completion on port 2.
      // Separate ports so the late AMO write-done acknowledge never muxes
      // in front of the tag read + compare (that mux made amo_state ->
      // valid[] the post-opt WNS pin); each source's cone runs from its own
      // registered address.  The sources stay mutually exclusive by AMO
      // serialization (asserted below), but the cache no longer relies on it.
      .i_invalidate_valid (i_cache_invalidate_valid),
      .i_invalidate_addr  (i_cache_invalidate_addr),
      .i_invalidate2_valid(amo_cache_inv),
      .i_invalidate2_addr (amo_write_addr_q),

      // Only SQ/store invalidation must suppress same-cycle L0 lookup hits.
      // AMO write completion is serialized at ROB head and blocks younger
      // memory candidates, so keeping AMO off this combinational lookup cone
      // avoids the registered AMO-write address on the cache-hit/CDB path.
      .i_lookup_invalidate_valid(i_cache_invalidate_valid),
      .i_lookup_invalidate_addr (i_cache_invalidate_addr),

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
  // cache-safe load. Integer byte/half/word loads extract from the cached
  // beat through the local load_unit; FLW takes its addressed word and FLD
  // the full dword line. The bus-busy gate is required even for
  // cache hits: an SQ/AMO write can own the port one cycle before its L0
  // invalidation is visible, so a phase-2 hit in that window could be stale.
  assign cache_hit_fast_path = ENABLE_L0_FAST_PATH
      && !i_flush_all && !i_flush_en
      && !i_mem_bus_busy
      && sq_can_issue
      && cache_lookup_hit
      && !sq_check_is_mmio_q
      && !sq_check_is_lr_q
      && !sq_check_is_amo_q;

  assign stage_mem_issue_addr = sq_check_addr_q;

  // Gate stage_mem_issue on !i_flush_all too.  See comment on
  // launch_mem_issue below for the full rationale.
  assign stage_mem_issue = !i_flush_en && !i_flush_all && sq_can_issue && !cache_hit_fast_path;
  assign stage_mem_issue_size = sq_check_size_q;

  // PERF: Removed the !mem_outstanding gate so the LQ can launch a new load
  // every cycle (BRAM has 1-cycle latency, so the response from the previous
  // launch arrives the same cycle the new launch is driven). The bus_busy
  // gate ensures an ordinary launch reaches the data-memory port immediately
  // rather than colliding in cpu_ooo's single-deep request hold. A drain-blocked
  // MMIO is the deliberate exception: the router captures that first handoff,
  // then its registered pending Q returns through i_mem_bus_busy before another
  // launch can occur. Loses the rare overlap of one queued launch with a SQ
  // write, but that path was 4.4% of cycles in the baseline profile vs.
  // doubling steady-state load issue rate.
  //
  // TIMING: launch_mem_issue_idx/addr/size now read sq_check_idx /
  // stage_mem_issue_addr / stage_mem_issue_size directly. The previous
  // mem_issue_pending mux fed into the data-memory BRAM ADDR cone and was
  // the dominant -0.911 ns timing-failing path on x3. sq_check_pending
  // already holds the staged candidate stably across bus_busy stalls
  // (sq_check_will_clear keys off launch_mem_issue, not stage_mem_issue),
  // so the mem_issue_pending second-deep stage is redundant.
  // Also gate on !i_flush_all.  During commit-time mispredict
  // recovery the wrapper drives speculative_flush_en=0 but speculative_flush_all=1
  // (commit_recovery_flush_after_head path).  Without the !i_flush_all guard,
  // a speculative wrong-path MMIO load that happens to be at ROB head when the
  // mispredict commits can still issue this cycle and consume the FIFO byte
  // before the next-cycle full flush clears the entry.  packet_parser exposed
  // this race once 2-wide dispatch let speculative loads reach HEAD faster.
  // PER-TIER single-outstanding gate. slow_outstanding is 1 only while a cached
  // request is in the variable-latency hierarchy. When set it blocks EVERY
  // memory launch so the single mem_outstanding/issued_idx tracker cannot be
  // overwritten. Low-BRAM/MMIO loads remain back-to-back on the fixed response
  // pipeline; a pre-accept MMIO park instead holds i_mem_bus_busy through the
  // router's registered pending feedback. The bit is held through a partial
  // stale-response drain; full flush transfers the block to
  // drop_mem_response_pending until response/drop.
  assign launch_mem_issue = !i_flush_en && !i_flush_all && !i_mem_bus_busy && stage_mem_issue &&
      !slow_outstanding;
  assign launch_mem_issue_idx = sq_check_idx;
  assign launch_mem_issue_addr = stage_mem_issue_addr;
  assign launch_mem_issue_size = stage_mem_issue_size;

  // Cached-tier decode of the load being launched this cycle (off the registered
  // staged candidate address, parallel to the issue cone). It feeds only
  // slow_outstanding state and the issued snapshot, never the launch gate itself.
  logic launching_is_cached;
  assign launching_is_cached = is_cached_addr(launch_mem_issue_addr);

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

  // SQ-forward extraction: i_sq_forward.data carries the aligned-dword memory
  // image at the load's dword (the fwd unit shifts store data to its byte
  // lanes), so integer loads extract from it exactly like a memory beat.  The
  // flags/address are shared with u_cache_load_unit — same staged load, and
  // the forward and cache-hit paths are mutually exclusive by construction.
  logic [XLEN-1:0] lu_fwd_out;
  load_unit u_fwd_load_unit (
      .i_is_load_byte           (lu_cache_is_byte),
      .i_is_load_halfword       (lu_cache_is_half),
      .i_is_load_unsigned       (lu_cache_is_unsigned),
      .i_data_memory_address    (sq_check_addr_q),
      .i_data_memory_read_data  (i_sq_forward.data),
      .o_data_loaded_from_memory(lu_fwd_out)
  );

  // ===========================================================================
  // lq_data LUTRAM Write Logic (combinational)
  // ===========================================================================
  // Placed after all signal declarations it references (cache_hit_fast_path,
  // sq_do_forward, lu_cache_out, lu_data_out, etc.) for readable tool output.

  always_comb begin
    lq_data_we      = '0;
    lq_data_wr_addr = '0;
    lq_data_wd      = '0;

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
      end else if (riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_DOUBLE) begin
        // FLD/RV64 LD: the full aligned beat in one write
        lq_data_we[0] = 1'b1;
        lq_data_wd[0] = i_mem_read_data;
      end else begin
        // LR / FLW / INT: extracted result (FLW's word arm is its addressed
        // raw word), zero-extended into FLEN
        lq_data_we[0] = 1'b1;
        lq_data_wd[0] = FLEN'(lu_data_out);
      end
    end

    // ---------------------------------------------------------------
    // Port 1: cache hit / SQ forward / AMO write completion.
    //         These three sources are mutually exclusive in time:
    //           - cache_hit and sq_forward each require sq_check_pending
    //             on a non-AMO entry. While amo_state == AMO_WRITE_ACTIVE
    //             the older-AMO write fence (older_amo_write_pending)
    //             blocks any staged load from hitting or forwarding, so
    //             the AMO write completion never collides with cache_hit
    //             or sq_forward.
    //           - sq_forward requires !sq_no_older_store and can_forward,
    //             which implies i_sq_forward.match; a cache hit with older
    //             stores resident can only pass sq_can_issue via the !match
    //             disjunct, and the sq_no_older_store branch is closed by
    //             sq_forward's own !sq_no_older_store term.  So they cannot
    //             fire together.
    // ---------------------------------------------------------------
    if (i_rst_n && !i_flush_all) begin
      if (cache_hit_fast_path) begin
        lq_data_we[1] = 1'b1;
        lq_data_wr_addr[1] = sq_check_idx;
        // FLD takes the full cached dword line; FLW/INT extract from it
        // (FLW's word arm is its addressed raw word).
        lq_data_wd[1]      = (sq_check_size_q == riscv_pkg::MEM_SIZE_DOUBLE)
            ? cache_lookup_data : FLEN'(lu_cache_out);
      end else if (sq_do_forward) begin
        lq_data_we[1] = 1'b1;
        lq_data_wr_addr[1] = sq_check_idx;
        // FLD takes the forwarded dword image raw; FLW/INT extract their
        // addressed word/half/byte from the image beat.
        lq_data_wd[1]      = (sq_check_size_q == riscv_pkg::MEM_SIZE_DOUBLE)
            ? i_sq_forward.data : FLEN'(lu_fwd_out);
      end else if (amo_state == AMO_WRITE_ACTIVE && i_amo_mem_write_done) begin
        lq_data_we[1]      = 1'b1;
        lq_data_wr_addr[1] = amo_entry_idx;
        lq_data_wd[1]      = FLEN'(amo_old_value);
      end
    end
  end

  // Cache fill uses a response-valid predicate separate from architectural LQ
  // response acceptance.  A partial flush can kill the outstanding LQ entry in
  // the exact cycle its ordinary, side-effect-free memory response arrives.
  // The completion must still be drained, but the returned memory image is safe
  // to install in the persistent L0: branch recovery does not change
  // architectural memory, and the L0 already intentionally survives partial
  // flushes.  Keeping issued_entry_flushed out of this predicate also prevents
  // the early-flush tag/age comparison from feeding all 128 L0 valid-bit Ds.
  //
  // Full-flush-cycle and already-pending stale responses remain ineligible.
  // MMIO/LR/AMO exclusions and the cached-tier store-invalidation guards below
  // are unchanged.
  // The fill address is the issued_addr snapshot directly. Critically, this
  // path does not go through the lq_address_issued LUTRAM read, which was
  // the dominant prefix of the cone reaching the data memory's ADDRARDADDR
  // pin via lq_l0_cache.lookup_fill_bypass.
  assign cache_fill_response_valid = i_mem_read_valid && mem_outstanding &&
      !i_flush_all && !drop_mem_response_pending && lq_valid[issued_idx];
  assign cache_fill_valid = cache_fill_response_valid
      && !issued_is_mmio && !issued_is_lr && !issued_is_amo
      && !(issued_is_cached &&
           (issued_cached_line_invalidated || issued_cached_line_invalidate_now));
  assign cache_fill_addr = issued_addr;
  assign cache_fill_data = i_mem_read_data;

  // L0 cache profile pulses (one cycle when the event fires)
  assign o_l0_hit = cache_hit_fast_path;
  assign o_l0_fill = cache_fill_valid;
  // Diagnostic: expose mem_outstanding so the wrapper can partition head
  // wait cycles into "load in flight" vs "load stuck on something else".
  assign o_mem_outstanding = mem_outstanding;

  // AMO write interface. The memory-response edge captures the address and
  // either a comparator-free result (SWAP/ADD/XOR/AND/OR) or the MIN/MAX
  // selection predicate plus both source operands while it transitions the FSM
  // to AMO_WRITE_ACTIVE. The following cycle's BRAM-write pins therefore see
  // only payload FFs and one shallow mux. This is cycle-identical to the prior
  // registered state machine: response at cycle N, active write at cycle N+1.
  always_comb begin
    amo_write_value = amo_write_data_q;
    if (amo_is_minmax_q) begin
      amo_write_value = amo_minmax_select_old_q ? amo_old_value : amo_minmax_rs2_q;
    end

    o_amo_mem_write_en       = 1'b0;
    o_amo_mem_write_addr     = '0;
    o_amo_mem_write_data     = '0;
    o_amo_mem_write_is_dword = 1'b0;

    if (amo_state == AMO_WRITE_ACTIVE) begin
      o_amo_mem_write_en = 1'b1;
      o_amo_mem_write_addr = amo_write_addr_q;
      // .W: word result replicated across the beat; the router's word-lane
      // strobes (from addr[2] + the is_dword flag) select the addressed half.
      // .D: the full doubleword with full-beat strobes.
      o_amo_mem_write_data = amo_is_d_q ? riscv_pkg::MemDataBits'(amo_write_value) :
          {(riscv_pkg::MemDataBits / 32) {amo_write_value[31:0]}};
      o_amo_mem_write_is_dword = amo_is_d_q;
    end
  end

  // Drive load unit inputs from the entry awaiting response (memory path)
  always_comb begin
    // Extraction controls come straight from the registered issued_* fields
    // with no accept_mem_response qualification: every consumer of the
    // extracted data (LQ data-RAM write, L0 fill, cdb_stage payload capture)
    // is enable-gated on the accept/fire pulses, so the extraction result is
    // don't-care whenever no response is being accepted — and the un-gated
    // form keeps accept_mem_response's flush conjuncts out of the response
    // data cone.
    lu_is_byte     = (riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_BYTE);
    lu_is_half     = (riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_HALF);
    lu_is_unsigned = !issued_sign_ext;
    lu_addr        = issued_addr;
    lu_raw_data    = i_mem_read_data;
  end

  // ===========================================================================
  // CDB Broadcast Logic
  // ===========================================================================
  // Phase A candidate is captured into a one-entry registered stage before it
  // leaves the LQ. That breaks the issue/data-select cone away from the
  // downstream MEM adapter / CDB wakeup path while preserving ordering.

  // Only .valid carries the found/flush qualification; tag/value are formed
  // unconditionally so the flush pulse stays out of the payload data cone.
  // Both consumers qualify them: issue_cdb_fire uses .valid, and the
  // cdb_stage payload capture is enable-gated (tag/value are don't-care when
  // no capture happens).
  always_comb begin
    issue_cdb_result = '0;
    issue_cdb_result.valid = issue_cdb_found && !i_flush_en;
    issue_cdb_result.tag = lq_rob_tag[issue_cdb_idx];

    if (riscv_pkg::mem_size_e'(lq_size_issue_cdb_rd) == riscv_pkg::MEM_SIZE_DOUBLE) begin
      // FLD/RV64 LD: raw 64-bit beat from the LUTRAM
      issue_cdb_result.value = lq_data_rd;
    end else if (lq_is_fp[issue_cdb_idx]) begin
      // FLW: NaN-box the stored 32-bit word
      issue_cdb_result.value = {32'hFFFF_FFFF, lq_data_rd[31:0]};
    end else begin
      // INT load: stored value is already zero-extended into FLEN
      issue_cdb_result.value = lq_data_rd;
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
  // already firing through issue_cdb_fire.  AMOs (need write phase) and
  // DOUBLE-size memory responses stay on the standard path (the L0-hit and
  // SQ-forward bypasses below do carry DOUBLE payloads).
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
      !(riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_DOUBLE);

  assign resp_bypass_fire = cdb_stage_slot_available && !issue_cdb_fire &&
                            resp_bypass_ok && !i_flush_en;

  assign misalign_bypass_fire = cdb_stage_slot_available && !issue_cdb_fire &&
                                !resp_bypass_fire && sq_check_misaligned && !i_flush_en;

  // Data-select forms for the cdb_stage payload D-muxes. Whenever the payload
  // capture enable (issue_cdb_fire || bypass_fire below) is high, the
  // slot-available / !issue / !flush conjuncts of the full *_fire products
  // are all implied — a bypass leg can only capture with the slot free, no
  // Phase-A completion, and no partial flush — so the D-selects reduce to
  // these flush- and grant-free terms. resp_bypass_data_sel is
  // resp_bypass_ok minus accept_mem_response's !i_flush_all /
  // !issued_entry_flushed conjuncts: issued_entry_flushed needs i_flush_en
  // (impossible under the enable) and the only enable leg reachable during
  // i_flush_all is the misalign one, whose capture is discarded by
  // cdb_stage_valid's full-flush reset anyway. Outside a capture the payload
  // D is don't-care. This keeps the recovery flush tag and the CDB grant
  // loop (i_result_accepted) out of the payload data cone; every enable and
  // state transition still uses the fully-gated fires above.
  logic resp_bypass_data_sel;
  logic misalign_bypass_data_sel;
  assign resp_bypass_data_sel = i_mem_read_valid && mem_outstanding &&
      !drop_mem_response_pending && lq_valid[issued_idx] && !issued_is_amo &&
      !(riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_DOUBLE);
  assign misalign_bypass_data_sel = !resp_bypass_data_sel && sq_check_misaligned;

  // cache_hit_fast_path is already flush-gated at its own assign.
  assign cache_hit_bypass_fire = cdb_stage_slot_available && !issue_cdb_fire &&
                                 !resp_bypass_fire && !misalign_bypass_fire &&
                                 cache_hit_fast_path;

  // SQ-forward completion bypass: forwarded loads previously took the
  // standard data_valid -> Phase-A selector -> cdb_stage path (+2 cycles vs
  // the bypassed L0/response completions).  Capture the forward result into
  // cdb_stage the cycle sq_do_forward fires instead.  sq_do_forward and
  // cache_hit_fast_path are mutually exclusive (forward requires
  // !sq_no_older_store and can_forward, hence i_sq_forward.match; a cache hit
  // with older stores resident can only pass sq_can_issue via the !match
  // disjunct), and forwarded FLDs are eligible — the SQ delivers the full
  // 64-bit image in one probe.
  // !i_flush_en keeps a same-cycle partial flush of the staged load off the
  // CDB (falls back to the standard path, where the flush cleans the entry).
  logic fwd_bypass_fire;
  assign fwd_bypass_fire = cdb_stage_slot_available && !issue_cdb_fire &&
                           !resp_bypass_fire && !misalign_bypass_fire &&
                           sq_do_forward && !i_flush_en;

  assign bypass_fire = resp_bypass_fire || misalign_bypass_fire || cache_hit_bypass_fire ||
                       fwd_bypass_fire;

  // Mirror issue_cdb_result formatting, but sourced from the response-side
  // signals (lu_data_out / lu_cache_out / image beat) instead of the LUTRAM.
  // DOUBLE responses never reach this arm (resp_bypass_ok excludes them).
  always_comb begin
    if (issued_is_fp) begin
      // FLW: NaN-box the addressed raw word (lu_data_out's word arm)
      resp_bypass_value = {32'hFFFF_FFFF, lu_data_out[31:0]};
    end else begin
      // INT / LR: zero-extend byte/half/word extracted value
      resp_bypass_value = FLEN'(lu_data_out);
    end
  end

  always_comb begin
    if (sq_check_size_q == riscv_pkg::MEM_SIZE_DOUBLE) begin
      // FLD from L0: the full cached dword line
      cache_hit_bypass_value = cache_lookup_data;
    end else if (sq_check_is_fp_q) begin
      // FLW from L0: NaN-box the addressed word of the cached beat
      cache_hit_bypass_value = {32'hFFFF_FFFF, lu_cache_out[31:0]};
    end else begin
      // INT from L0: cache-path load_unit already did byte/half extract
      cache_hit_bypass_value = FLEN'(lu_cache_out);
    end
  end

  // Forward-bypass payload: mirrors the forward write-port formatting.
  logic [FLEN-1:0] fwd_bypass_value;
  always_comb begin
    if (sq_check_size_q == riscv_pkg::MEM_SIZE_DOUBLE) begin
      // FLD from FSD: full 64-bit image straight from the SQ
      fwd_bypass_value = i_sq_forward.data;
    end else if (sq_check_is_fp_q) begin
      // FLW: NaN-box the addressed word of the forwarded image
      fwd_bypass_value = {32'hFFFF_FFFF, lu_fwd_out[31:0]};
    end else begin
      // INT: fwd-path load_unit already did byte/half extract + extension
      fwd_bypass_value = FLEN'(lu_fwd_out);
    end
  end

  // Payload D-mux selects use the reduced data-select forms (see the comment
  // above): identical to the fire-based selects whenever a capture actually
  // happens, don't-care otherwise.
  assign bypass_idx = resp_bypass_data_sel ? issued_idx : sq_check_idx;
  assign bypass_tag = resp_bypass_data_sel ? issued_rob_tag : sq_check_rob_tag_q;
  // A misaligned load raises an exception instead of producing a register
  // result, so its CDB value slot is free to carry the faulting address.
  // The ROB forwards this as mtval at trap entry (RISC-V requires mtval =
  // the misaligned virtual address for a load-address-misaligned trap).
  // sq_do_forward is fully qualified at its own assign and disjoint from
  // cache_hit_fast_path, so it distinguishes the two sq_check-sourced arms.
  assign bypass_value =
      misalign_bypass_data_sel ? {{(FLEN - XLEN) {1'b0}}, sq_check_addr_q} :
      resp_bypass_data_sel ? resp_bypass_value :
      sq_do_forward ? fwd_bypass_value :
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

  // Convert the two binary targets into explicit entry-local write pulses.
  // Slot 2 takes the first target when slot 1 is absent, and the second target
  // for a dual allocation. Keeping these pulses prevents synthesis from
  // rebuilding one shared indexed-write decoder across every LQ field.
  always_comb begin
    first_target_oh                                = '0;
    second_target_oh                               = '0;
    first_target_oh[alloc_target[IdxWidth-1:0]]    = 1'b1;
    second_target_oh[alloc_target_2[IdxWidth-1:0]] = 1'b1;
  end
  assign slot1_alloc_oh = first_target_oh & {DEPTH{slot1_alloc_en}};
  assign slot2_alloc_oh = (slot1_alloc_en ? second_target_oh : first_target_oh) &
                          {DEPTH{slot2_alloc_en}};

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
  logic sq_check_flushed;
  assign sq_check_flushed = i_flush_en && sq_check_pending && (flush_all_entries || is_younger(
      sq_check_rob_tag_q, i_flush_tag, i_rob_head_tag
  ));

  // Flattened, per-signal form of the old flushed → capture/replace → clear →
  // phase2-arm priority chain. The capture/replace branch (U below) carries
  // !i_flush_en/!i_flush_all inside sq_check_gate_early while sq_check_flushed
  // requires i_flush_en, so U and the flush branch are structurally disjoint
  // and each next-state bit reduces to independent AND-OR terms instead of a
  // serial priority mux behind the kept mask_update_en net. Bit-identical to
  // the original chain for every input combination.
  logic sq_check_stage_clears;
  assign sq_check_stage_clears = sq_check_pending &&
      (!sq_check_entry_valid || cache_hit_fast_path || sq_do_forward ||
       launch_mem_issue || misalign_bypass_fire || older_amo_write_pending);

  always_comb begin
    // U = capture/replace (disjoint from sq_check_flushed, see above).
    // Clear branch: launch_mem_issue remains low through bus_busy stalls.
    sq_check_pending_next = sq_check_capture || sq_check_replace ||
        (sq_check_pending && !sq_check_flushed && !sq_check_stage_clears);

    sq_check_no_older_store_next = ((sq_check_capture || sq_check_replace) && i_sq_empty) ||
        (sq_check_no_older_store_q && !sq_check_flushed &&
         !(sq_check_capture || sq_check_replace));

    sq_check_phase2_next = ((sq_check_capture || sq_check_replace) && i_sq_empty) ||
        (!(sq_check_capture || sq_check_replace) && !sq_check_flushed &&
         (sq_check_phase2 ||
          (!sq_check_stage_clears &&
           ((sq_check_pending && i_sq_empty && !sq_commit_check_block) || o_sq_check_valid))));

    for (int i = 0; i < DEPTH; i++) begin
      sq_check_in_flight_mask_next[i] =
          ((sq_check_capture || sq_check_replace) && issue_mem_onehot[i]) ||
          (sq_check_in_flight_mask[i] && !sq_check_flushed && !sq_check_stage_clears &&
           !(sq_check_capture || sq_check_replace));
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

  for (
      genvar g_sq_check_mask = 0; g_sq_check_mask < DEPTH; g_sq_check_mask++
  ) begin : gen_sq_check_in_flight_mask_ff
    FDRE #(
        .INIT(1'b0)
    ) sq_check_in_flight_mask_ff (
        .C (i_clk),
        .CE(1'b1),
        .D (sq_check_in_flight_mask_next[g_sq_check_mask]),
        .Q (sq_check_in_flight_mask[g_sq_check_mask]),
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

  // ===========================================================================
  // Older-AMO dependency masks
  // ===========================================================================
  // The sparse LQ cannot infer age from physical position.  Instead, each row
  // records the physical identities of unresolved AMOs that are older than
  // that entry.  Allocation is the only event that can introduce a dependency;
  // completion, flush, and reuse permanently prune the corresponding physical
  // generation. A one-cycle mirror of lq_valid detects the 0->1 transition of
  // every physical generation. Tag arithmetic therefore runs only in these
  // state-D cones, never in the issue/SQ-check datapath.
  always_comb begin
    for (int unsigned j = 0; j < DEPTH; j++) begin
      pending_amo_phys[j] = lq_valid[j] && lq_is_amo[j] && !lq_data_valid[j];
      dep_done_oh[j] = (amo_state == AMO_WRITE_ACTIVE) && i_amo_mem_write_done &&
                       (amo_entry_idx == IdxWidth'(j));
      dep_flush_kill[j] = i_flush_en && lq_valid[j] &&
          (flush_all_entries || is_younger(lq_rob_tag[j], i_flush_tag, i_rob_head_tag));
      dep_free_oh[j] = free_entry_en && (free_entry_idx == IdxWidth'(j));
      dep_live_src[j] = pending_amo_phys[j] && !dep_done_oh[j] && !dep_flush_kill[j];
    end

    // Allocation cannot reuse a slot on its free/flush edge: targets are chosen
    // from the pre-edge valid mask, and flush gates allocation. Thus every new
    // physical generation has a complete invalid cycle and an observable 0->1
    // transition here, including both entries of a dual allocation bundle.
    dep_replaced_oh = lq_valid & ~dep_identity_valid_q;
    dep_new_amo_src = dep_replaced_oh & pending_amo_phys;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      older_amo_dep_d[i] = '0;

      // A newly-live generation rebuilds its destination row from current
      // source identities. Comparing tags (rather than assuming physical or
      // request order) preserves sparse and dual-allocation behavior.
      if (!lq_valid[i] || dep_flush_kill[i] || dep_free_oh[i]) begin
        older_amo_dep_d[i] = '0;
      end else if (dep_replaced_oh[i]) begin
        for (int unsigned j = 0; j < DEPTH; j++) begin
          older_amo_dep_d[i][j] = dep_live_src[j] &&
              is_older_than(lq_rob_tag[j], lq_rob_tag[i], dep_head_q);
        end
      end else begin
        for (int unsigned j = 0; j < DEPTH; j++) begin
          older_amo_dep_d[i][j] =
              (older_amo_dep_q[i][j] && dep_live_src[j] && !dep_replaced_oh[j]) ||
              (dep_new_amo_src[j] && dep_live_src[j] &&
               is_older_than(lq_rob_tag[j], lq_rob_tag[i], dep_head_q));
        end
      end

      older_amo_block_d[i] = |older_amo_dep_d[i];
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      dep_identity_valid_q <= '0;
      dep_head_q <= '0;
      older_amo_block_q <= '0;
      for (int unsigned i = 0; i < DEPTH; i++) begin
        older_amo_dep_q[i] <= '0;
      end
    end else begin
      older_amo_block_q <= older_amo_block_d;
      for (int unsigned i = 0; i < DEPTH; i++) begin
        older_amo_dep_q[i] <= older_amo_dep_d[i];
      end
      // Both are intentionally pre-edge snapshots. After an allocation edge,
      // lq_valid contains the new generation while this mirror still contains
      // zero, and dep_head_q contains that allocation edge's age origin.
      dep_identity_valid_q <= lq_valid;
      dep_head_q <= i_rob_head_tag;
    end
  end


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
      slow_outstanding          <= 1'b0;
      reservation_valid         <= 1'b0;
      amo_state                 <= AMO_IDLE;
    end else if (i_flush_all) begin
      // Full flush: reset control signals
      head_ptr <= '0;
      tail_ptr <= '0;
      lq_valid <= '0;
      lq_addr_valid <= '0;
      lq_issued <= '0;
      lq_data_valid <= '0;
      lq_forwarded <= '0;
      mem_outstanding <= 1'b0;
      // Full flush: if a memory response is still owed -- a load accepted by
      // the memory side (or parked in the router's queued-load register), or a
      // drop already armed by an earlier partial flush -- keep/arm the drop so
      // the zombie response is consumed and, via the launch gates, no new load
      // issues until it drains. The pre-cache reasoning ("front-end refill
      // after a full flush outlasts the cached read pipeline") does not hold for
      // the cached tier, whose miss latency is unbounded relative to the
      // refill; an unaccounted zombie response would be misattributed to the
      // next launched load.
      drop_mem_response_pending <= (drop_mem_response_pending || mem_outstanding) &&
                                   !i_mem_read_valid;
      slow_outstanding <= 1'b0;
      reservation_valid <= 1'b0;
      amo_state <= AMO_IDLE;
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
        // If the outstanding load was flushed, drop the next memory response
        // explicitly so the recycled slot cannot see stale data.
        if (issued_entry_flushed) begin
          mem_outstanding <= 1'b0;
          lq_issued[issued_idx] <= 1'b0;
          if (!i_mem_read_valid) begin
            drop_mem_response_pending <= 1'b1;
          end
        end
        // No current-cycle allocation can advance the search cursor. It may
        // still consume the prior bundle's registered generation pulse below;
        // either origin reuses reclaimed holes because the free search is
        // driven by the updated valid mask.
      end

      // -----------------------------------------------------------------
      // Allocation: write new entry at tail (control signals only;
      // data signals written in dedicated no-reset always_ff blocks)
      // -----------------------------------------------------------------
      // Both ports use preserved entry-local pulses. Their vectors are
      // disjoint, so the non-blocking writes never collide on a physical bit.
      for (int unsigned i = 0; i < DEPTH; i++) begin
        if (slot1_alloc_oh[i] || slot2_alloc_oh[i]) begin
          lq_valid[i]      <= 1'b1;
          lq_addr_valid[i] <= 1'b0;
          lq_issued[i]     <= 1'b0;
          lq_data_valid[i] <= 1'b0;
          lq_forwarded[i]  <= 1'b0;
        end
      end

      // tail_ptr is only a free-search cursor: validity, occupancy, and age do
      // not depend on it. Advance it when the registered valid-generation
      // detector observes the previous bundle. The current allocations are
      // already visible in lq_valid, so a back-to-back search from the old
      // cursor skips them and retains full two-wide throughput while dispatch
      // no longer reaches the cursor D cone.
      if (|dep_replaced_oh) begin
        tail_ptr <= tail_ptr + PtrWidth'(1);
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
      // Skip the data_valid step when the completion bypass captured the
      // forward directly into cdb_stage — the entry is already freed via
      // free_entry_en (mirrors the cache-hit bypass above).
      if (sq_do_forward && !fwd_bypass_fire) begin
        lq_data_valid[sq_check_idx] <= 1'b1;
      end
      if (sq_do_forward) begin
        lq_forwarded[sq_check_idx] <= 1'b1;
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
        // A dropped cached response ends the variable-latency ownership
        // window. Clearing here -- rather than at the earlier
        // issued_entry_flushed -- keeps slow_outstanding asserted across the
        // whole drain so no new launch overlaps the stale response.
        slow_outstanding <= 1'b0;
      end else if (accept_mem_response) begin
        mem_outstanding <= 1'b0;
        // Normal completion of the in-flight cached load clears the
        // serialization window. Low-BRAM and MMIO loads never set it.
        if (issued_is_cached) slow_outstanding <= 1'b0;
        if (issued_is_amo) begin
          // AMO: start write phase (don't set data_valid yet);
          // response identity/result and registered write payload are captured
          // in the data-payload block below.
          amo_state <= AMO_WRITE_ACTIVE;
        end else begin
          // Non-AMO (LR, FLW, FLD, INT load): the completion bypass may have
          // captured this result directly into cdb_stage the same cycle via
          // resp_bypass_fire.  In that case skip the data_valid/LUTRAM
          // write — free_entry_en releases the slot.  LR still arms
          // reservation_valid either way.
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
        // Cached requests have variable hierarchy latency, so serialize them
        // until their eventual response/drop protects the single response
        // snapshot. A parked MMIO handoff is protected separately by the
        // router pending Q fed into i_mem_bus_busy.
        if (launching_is_cached) slow_outstanding <= 1'b1;
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
  // Data-Payload Sequential Logic
  // ===========================================================================
  // Most signals here are pure data payloads whose consumers are already gated
  // by control-valid bits (lq_valid, lq_addr_valid, lq_data_valid,
  // sq_check_pending, mem_outstanding, reservation_valid, amo_state, etc.) that
  // ARE reset. Keeping those data FFs out of the reset tree saves area, power,
  // and fanout. The compact AMO write stage below resets only its two request
  // valid bits; its index/data payload and per-entry array remain unreset.

  // -----------------------------------------------------------------
  // Per-entry data: allocation writes
  // -----------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (slot1_alloc_oh[i]) begin
        lq_rob_tag[i]  <= i_alloc.rob_tag;
        lq_size[i]     <= i_alloc.size;
        lq_is_fp[i]    <= i_alloc.is_fp;
        lq_sign_ext[i] <= i_alloc.sign_ext;
        lq_is_lr[i]    <= i_alloc.is_lr;
        lq_is_amo[i]   <= i_alloc.is_amo;
      end else if (slot2_alloc_oh[i]) begin
        lq_rob_tag[i]  <= i_alloc_2.rob_tag;
        lq_size[i]     <= i_alloc_2.size;
        lq_is_fp[i]    <= i_alloc_2.is_fp;
        lq_sign_ext[i] <= i_alloc_2.sign_ext;
        lq_is_lr[i]    <= i_alloc_2.is_lr;
        lq_is_amo[i]   <= i_alloc_2.is_amo;
      end
    end
  end

  // -----------------------------------------------------------------
  // Per-entry compact AMO kind: one-cycle staged allocation writes
  // -----------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      // A full flush invalidates every entry, so any pending data-only write
      // can be discarded. Partial flushes still drain: writing stale payload
      // behind a killed entry is harmless, while a retained entry needs it.
      amo_kind_alloc_present_q <= '0;
    end else begin
      // dep_replaced_oh identifies exactly the physical generations allocated
      // on the prior edge. The accepted-request bits distinguish a real staged
      // write from an unaccepted candidate whose index may alias that generation.
      if (amo_kind_alloc_present_q[0] && dep_replaced_oh[amo_kind_alloc_idx_q[0]]) begin
        lq_amo_kind[amo_kind_alloc_idx_q[0]] <= amo_kind_alloc_data_q[0];
      end
      if (amo_kind_alloc_present_q[1] && dep_replaced_oh[amo_kind_alloc_idx_q[1]]) begin
        lq_amo_kind[amo_kind_alloc_idx_q[1]] <= amo_kind_alloc_data_q[1];
      end

      // Capture candidate payload every cycle, but only accepted allocations
      // may drain it. This matters when a rejected slot-2 candidate aliases an
      // accepted slot-1 target because only one physical entry is free.
      // For non-AMOs encode_amo_kind stores INVALID behind lq_is_amo == 0.
      amo_kind_alloc_present_q[0] <= slot1_alloc_en;
      amo_kind_alloc_present_q[1] <= slot2_alloc_en;
      amo_kind_alloc_idx_q[0]     <= alloc_target[IdxWidth-1:0];
      amo_kind_alloc_idx_q[1]     <= slot2_alloc_idx;
      amo_kind_alloc_data_q[0]    <= encode_amo_kind(i_alloc.amo_op);
      amo_kind_alloc_data_q[1]    <= encode_amo_kind(i_alloc_2.amo_op);
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
  logic [IdxWidth-1:0] update_issue_payload_idx;
  logic [MemSizeWidth-1:0] issue_mem_size_bits;
  logic issue_mem_is_fp;
  logic issue_mem_sign_ext;
  logic issue_mem_is_mmio;
  logic issue_mem_is_lr;
  logic issue_mem_is_amo;
  (* keep = "true", max_fanout = 32 *) logic sq_check_payload_en;
  logic [IdxWidth-1:0] sq_check_idx_next;
  logic [ReorderBufferTagWidth-1:0] sq_check_rob_tag_next;
  logic [XLEN-1:0] sq_check_addr_next;
  riscv_pkg::mem_size_e sq_check_size_next;
  logic sq_check_is_fp_next;
  logic sq_check_sign_ext_next;
  logic sq_check_is_mmio_next;
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

  // Port-split replicas: same D/CE/timing as sq_check_addr_q. dont_touch on
  // their declarations prevents opt_design from re-merging the four anchors.
  always_ff @(posedge i_clk) begin
    if (sq_check_payload_en) sq_check_addr_q_b <= sq_check_addr_next;
  end

  always_ff @(posedge i_clk) begin
    if (sq_check_payload_en) sq_check_addr_q_c <= sq_check_addr_next;
  end

  always_ff @(posedge i_clk) begin
    if (sq_check_payload_en) sq_check_addr_q_d <= sq_check_addr_next;
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
      sq_check_idx        <= sq_check_idx_next;
      sq_check_rob_tag_q  <= sq_check_rob_tag_next;
      sq_check_addr_q     <= sq_check_addr_next;
      sq_check_addr_q_b   <= sq_check_addr_next;
      sq_check_addr_q_c   <= sq_check_addr_next;
      sq_check_addr_q_d   <= sq_check_addr_next;
      sq_check_size_q     <= sq_check_size_next;
      sq_check_is_fp_q    <= sq_check_is_fp_next;
      sq_check_sign_ext_q <= sq_check_sign_ext_next;
      sq_check_is_mmio_q  <= sq_check_is_mmio_next;
      sq_check_is_lr_q    <= sq_check_is_lr_next;
      sq_check_is_amo_q   <= sq_check_is_amo_next;
    end
  end
`endif

  // -----------------------------------------------------------------
  // Internal data: issued entry tracker + flat snapshot
  // -----------------------------------------------------------------
  // Snapshotting the per-entry attributes here breaks the long
  //   issued_idx → lq_*[issued_idx] → cache_fill_addr → lq_l0_cache lookup
  // cone that fed the data_memory ADDRARDADDR pin via lookup_fill_bypass.
  // The captured fields are stable for the lifetime of the outstanding
  // load (allocation-time fields don't change once written).
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      issued_cached_line_invalidated <= 1'b0;
    end else if (o_mem_read_en || drop_mem_response_now || accept_mem_response) begin
      issued_cached_line_invalidated <= 1'b0;
    end else if (issued_cached_line_invalidate_now) begin
      issued_cached_line_invalidated <= 1'b1;
    end
  end

  always_ff @(posedge i_clk) begin
    // Snapshot every request handed to the router. Cached handoffs arm
    // slow_outstanding; a parked MMIO handoff is instead kept single-owner by
    // the router pending Q fed directly into the wrapper's LQ bus-busy gate.
    if (o_mem_read_en) begin
      issued_idx       <= launch_mem_issue_idx;
      issued_addr      <= launch_mem_issue_addr;
      issued_size      <= launch_mem_issue_size;
      issued_is_fp     <= sq_check_is_fp_q;
      issued_is_lr     <= sq_check_is_lr_q;
      issued_is_amo    <= sq_check_is_amo_q;
      issued_is_mmio   <= sq_check_is_mmio_q;
      issued_is_cached <= launching_is_cached;
      issued_sign_ext  <= sq_check_sign_ext_q;
      issued_rob_tag   <= sq_check_rob_tag_q;
      if (sq_check_is_amo_q) begin
        issued_amo_kind <= lq_amo_kind[launch_mem_issue_idx];
        issued_amo_rs2  <= lq_amo_rs2_rd;
      end
    end
  end

  // -----------------------------------------------------------------
  // Internal data: registered AMO write payload and completion identity.
  // The AMO-only operation and rs2 operand were snapshotted at launch.  On a
  // back-to-back response/launch edge, nonblocking-assignment semantics make
  // this block consume the old response owner's snapshots while the launch
  // block above installs the next owner's values.  issued_addr likewise still
  // carries the response owner's exact launch address throughout this edge.
  // -----------------------------------------------------------------
  // AMO operand width: .W forms select the addressed word of the response
  // beat by addr[2] and compute at 32 bits (rd old-value sign-extends at
  // XLEN=64 — the RV64A semantic); .D forms use the full beat (XLEN=64 only,
  // enforced by decode).
  logic [XLEN-1:0] amo_beat_word;
  assign amo_beat_word = XLEN'(i_mem_read_data[issued_addr[2]*32+:32]);
  logic issued_amo_is_d;
  assign issued_amo_is_d = (riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_DOUBLE);
  logic [XLEN-1:0] amo_old_word_sext;
  assign amo_old_word_sext = {{(XLEN - 32) {amo_beat_word[31]}}, amo_beat_word[31:0]};
  logic [XLEN-1:0] amo_response_old_value;
  logic [XLEN-1:0] amo_response_normal_result;
  logic amo_response_capture;
  logic amo_response_is_minmax;
  logic amo_response_minmax_select_old;
  // AMO issue ordering makes an AMO response while WRITE_ACTIVE unreachable,
  // but make the hold contract local: even malformed/overlapped response input
  // cannot overwrite the stalled write owner's payload.
  assign amo_response_capture = accept_mem_response && issued_is_amo && (amo_state == AMO_IDLE);
  assign amo_response_old_value = issued_amo_is_d ? XLEN'(i_mem_read_data) : amo_old_word_sext;
  assign amo_response_normal_result = issued_amo_is_d ? amo_non_minmax_compute(
      issued_amo_kind, XLEN'(i_mem_read_data), issued_amo_rs2
  ) : XLEN'(amo_non_minmax_compute32(
      issued_amo_kind, amo_beat_word[31:0], issued_amo_rs2[31:0]
  ));
  assign amo_response_is_minmax = is_amo_minmax_kind(issued_amo_kind);
  assign amo_response_minmax_select_old = issued_amo_is_d ? amo_minmax_select_old(
      issued_amo_kind, XLEN'(i_mem_read_data), issued_amo_rs2
  ) : amo_minmax_select_old32(
      issued_amo_kind, amo_beat_word[31:0], issued_amo_rs2[31:0]
  );

  always_ff @(posedge i_clk) begin
    if (amo_response_capture) begin
      amo_old_value           <= amo_response_old_value;
      amo_entry_idx           <= issued_idx;
      amo_write_addr_q        <= issued_addr;
      amo_write_data_q        <= amo_response_normal_result;
      amo_minmax_rs2_q        <= issued_amo_rs2;
      amo_is_d_q              <= issued_amo_is_d;
      amo_is_minmax_q         <= amo_response_is_minmax;
      amo_minmax_select_old_q <= amo_response_minmax_select_old;
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

  // Shared capture enable with issue_cdb_found as the D-mux select. Under
  // the enable: the slot is free and there is no partial flush (every fire
  // term requires both), so issue_cdb_fire == issue_cdb_found and the bypass
  // leg's fire-based selects reduce to the flush/grant-free data selects —
  // bit-identical capture behavior with the recovery pulses and the CDB
  // grant loop off the payload D cone.
  always_ff @(posedge i_clk) begin
    if (issue_cdb_fire || bypass_fire) begin
      if (issue_cdb_found) begin
        cdb_stage_data.tag       <= issue_cdb_result.tag;
        cdb_stage_data.value     <= issue_cdb_result.value;
        cdb_stage_data.exception <= issue_cdb_result.exception;
        cdb_stage_data.exc_cause <= issue_cdb_result.exc_cause;
        cdb_stage_data.fp_flags  <= issue_cdb_result.fp_flags;
      end else begin
        cdb_stage_data.tag <= bypass_tag;
        cdb_stage_data.value <= bypass_value;
        cdb_stage_data.exception <= misalign_bypass_data_sel;
        cdb_stage_data.exc_cause <= misalign_bypass_data_sel ?
            riscv_pkg::exc_cause_t'(riscv_pkg::ExcLoadAddrMisalign[riscv_pkg::ExcCauseWidth-1:0]) :
            riscv_pkg::exc_cause_t'('0);
        cdb_stage_data.fp_flags <= '0;
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
      if (i_alloc.valid && full) $warning("LQ: allocation attempted when full");
      if (sq_check_pending &&
          ((sq_check_addr_q !== sq_check_addr_q_b) ||
           (sq_check_addr_q !== sq_check_addr_q_c) ||
           (sq_check_addr_q !== sq_check_addr_q_d)))
        $error("LQ: phase-identical SQ address anchors diverged");
      // No advisory for alloc-during-flush: dispatch legitimately presents on
      // trap/MRET/FENCE.I pulse cycles (edge-delayed frontend kill), and the
      // alloc enables suppress the request exactly like the ROB's alloc_en.
      // The FORMAL section asserts the suppression.
      if (i_alloc_2.valid && i_alloc.valid && full_for_2)
        $warning("LQ: slot-2 alloc attempted when full_for_2 (and slot-1 firing)");
      if (i_alloc_2.valid && !i_alloc.valid && full)
        $warning("LQ: slot-2 alloc attempted alone when full");
      if (i_flush_all && accept_mem_response)
        $error("LQ: accepted memory response during full flush");
      if (i_flush_all && cache_fill_valid) $error("LQ: filled L0 cache during full flush");
      // A full flush must never clip an AMO whose memory write is in flight:
      // the write would complete ownerless (done masked from the SQ by
      // amo_cached_inflight), memory would carry the side effect of a
      // squashed instruction, and mepc would re-execute the AMO. Guarded by
      // the trap unit's AMO interrupt shield (trap_unit.i_amo_at_head) --
      // this tripwire catches any future flush source that bypasses it.
      if (i_flush_all && (amo_state == AMO_WRITE_ACTIVE || o_amo_mem_write_en))
        $error("LQ: full flush while an AMO memory write is in flight (orphaned write)");
      // The integrated scheduler permits only one AMO response/write owner at
      // a time. Keep that contract visible in simulation, while the explicit
      // AMO_IDLE capture guard also prevents an invalid overlapping response
      // from corrupting a stalled write in an unconstrained formal harness.
      if (accept_mem_response && issued_is_amo && (amo_state != AMO_IDLE))
        $error("LQ: overlapping AMO response arrived while a write was active");
      // Slot-1 and slot-2 must never target the same physical entry.
      if (slot1_alloc_en && slot2_alloc_en && (alloc_target[IdxWidth-1:0] == slot2_alloc_idx))
        $error("LQ: slot-1 and slot-2 alloc collide on entry %0d", alloc_target[IdxWidth-1:0]);
      if (!$onehot0(slot1_alloc_oh) || !$onehot0(slot2_alloc_oh))
        $error("LQ: allocation steering is not onehot-or-zero");
      if ((|slot1_alloc_oh) != slot1_alloc_en || (|slot2_alloc_oh) != slot2_alloc_en)
        $error("LQ: allocation steering lost or invented an accepted request");
      if (|(slot1_alloc_oh & slot2_alloc_oh))
        $error("LQ: slot-1 and slot-2 onehot allocation pulses overlap");
      if (accept_mem_response && dep_replaced_oh[issued_idx])
        $error("LQ: memory response collided with a new physical generation");
      // The compact-kind write must have drained before launch snapshots it.
      // This is guaranteed by the intervening address/SQ-check staging edge.
      if (o_mem_read_en && sq_check_is_amo_q) begin
        if (amo_kind_alloc_present_q[0] &&
            dep_replaced_oh[amo_kind_alloc_idx_q[0]] &&
            (amo_kind_alloc_idx_q[0] == launch_mem_issue_idx))
          $error("LQ: slot-1 AMO-kind write had not drained before launch");
        if (amo_kind_alloc_present_q[1] &&
            dep_replaced_oh[amo_kind_alloc_idx_q[1]] &&
            (amo_kind_alloc_idx_q[1] == launch_mem_issue_idx))
          $error("LQ: slot-2 AMO-kind write had not drained before launch");
      end
      if (amo_state == AMO_WRITE_ACTIVE && amo_is_minmax_q &&
          (amo_write_value !==
           (amo_minmax_select_old_q ? amo_old_value : amo_minmax_rs2_q)))
        $error("LQ: active AMO MIN/MAX write no longer matches its captured predicate");
    end
  end

  // A memory-side stall must not alter any part of the active write request.
  // This also catches an accidental dependency on the newer issued_* snapshot
  // while another response/launch sequence is being prepared.
  assert property (@(posedge i_clk) disable iff (!i_rst_n || i_flush_all)
      (amo_state == AMO_WRITE_ACTIVE && !i_amo_mem_write_done) |=> (
          i_amo_mem_write_done ||
          ($stable(
      amo_old_value
  ) && $stable(
      amo_write_addr_q
  ) && $stable(
      amo_write_data_q
  ) && $stable(
      amo_minmax_rs2_q
  ) && $stable(
      amo_is_d_q
  ) && $stable(
      amo_is_minmax_q
  ) && $stable(
      amo_minmax_select_old_q
  ) && $stable(
      o_amo_mem_write_en
  ) && $stable(
      o_amo_mem_write_addr
  ) && $stable(
      o_amo_mem_write_data
  ) && $stable(
      o_amo_mem_write_is_dword
  ))))
  else $error("LQ: AMO write payload changed while memory withheld write_done");

  // The predicate split is not a pipeline stage: an accepted AMO response in
  // IDLE must expose the active write on the immediately following cycle.
  assert property (@(posedge i_clk) disable iff (!i_rst_n || i_flush_all)
      (accept_mem_response && issued_is_amo && (amo_state == AMO_IDLE))
      |=> (amo_state == AMO_WRITE_ACTIVE && o_amo_mem_write_en))
  else $error("LQ: AMO response-to-write latency changed");
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

  // The four physical anchors are a timing-only replication boundary. Once a
  // staged probe is live, every SQ quarter must observe the same address.
  always_comb begin
    if (i_rst_n && sq_check_pending) begin
      p_sq_check_addr_b_phase_identity : assert (sq_check_addr_q_b == sq_check_addr_q);
      p_sq_check_addr_c_phase_identity : assert (sq_check_addr_q_c == sq_check_addr_q);
      p_sq_check_addr_d_phase_identity : assert (sq_check_addr_q_d == sq_check_addr_q);
    end
  end

  // -------------------------------------------------------------------------
  // Structural constraints (assumes)
  // -------------------------------------------------------------------------

  // Alloc requests MAY arrive during flush (dispatch presents un-flush-gated
  // for timing; the trap-cycle straggler handshake does exactly
  // this in the real core).  The alloc enables carry the same
  // !i_flush_all && !i_flush_en gate as the ROB's alloc_en, so a flush-cycle
  // request must never write queue state.
  // (assumption removed — was: no allocation during flush)
  always_comb begin
    if (i_rst_n && (i_flush_all || i_flush_en)) begin
      p_no_alloc_during_flush : assert (!slot1_alloc_en && !slot2_alloc_en);
    end
  end

  // The compact AMO-kind FF array has independent slot-1/slot-2 indexed
  // writes. A dual allocation must preserve the queue allocator's
  // distinct-address contract so neither write can overwrite the other.
  always_comb begin
    if (i_rst_n && slot1_alloc_en && slot2_alloc_en) begin
      p_alloc_ports_distinct : assert (alloc_target[IdxWidth-1:0] != slot2_alloc_idx);
    end
    if (i_rst_n) begin
      p_slot1_alloc_onehot0 : assert ($onehot0(slot1_alloc_oh));
      p_slot2_alloc_onehot0 : assert ($onehot0(slot2_alloc_oh));
      p_slot1_alloc_preserved : assert ((|slot1_alloc_oh) == slot1_alloc_en);
      p_slot2_alloc_preserved : assert ((|slot2_alloc_oh) == slot2_alloc_en);
      p_alloc_onehots_disjoint : assert (!(|(slot1_alloc_oh & slot2_alloc_oh)));
    end
  end

  // The compact operation payload must be resident before an AMO launch
  // snapshots it. Even an address update in the first cycle after allocation
  // only captures SQ-check; phase-2 and launch occur later.
  always_comb begin
    if (i_rst_n && o_mem_read_en && sq_check_is_amo_q) begin
      p_amo_kind_slot1_write_drained :
      assert (!amo_kind_alloc_present_q[0] ||
              !dep_replaced_oh[amo_kind_alloc_idx_q[0]] ||
              (amo_kind_alloc_idx_q[0] != launch_mem_issue_idx));
      p_amo_kind_slot2_write_drained :
      assert (!amo_kind_alloc_present_q[1] ||
              !dep_replaced_oh[amo_kind_alloc_idx_q[1]] ||
              (amo_kind_alloc_idx_q[1] != launch_mem_issue_idx));
    end
  end

  // Generation initialization and an old generation's response must never
  // target the same physical entry on one edge.
  always_comb begin
    if (i_rst_n && accept_mem_response) begin
      p_response_not_new_generation : assert (!dep_replaced_oh[issued_idx]);
    end
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

  // A memory response belongs either to the live outstanding read or to the
  // explicitly armed stale-response drain. A partial flush moves a killed
  // request from mem_outstanding to drop_mem_response_pending, so allowing the
  // latter case is necessary for formal to explore the late-drain behavior.
  always_comb begin
    assume (!i_mem_read_valid || mem_outstanding || drop_mem_response_pending);
  end

  // -------------------------------------------------------------------------
  // Combinational assertions
  // -------------------------------------------------------------------------

  // The response-side split must preserve the exact old-vs-rs2 predicate. .W
  // compares low words even at XLEN=64; .D compares the complete XLEN values.
  // Equality deliberately selects rs2, matching the original ternary result.
  always_comb begin
    if (i_rst_n && accept_mem_response && issued_is_amo) begin
      case (issued_amo_kind)
        AMO_KIND_MIN: begin
          p_amo_min_is_minmax : assert (amo_response_is_minmax);
          if (issued_amo_is_d) begin
            p_amo_min_d_predicate :
            assert (amo_response_minmax_select_old == ($signed(
                XLEN'(i_mem_read_data)
            ) < $signed(
                issued_amo_rs2
            )));
          end else begin
            p_amo_min_w_predicate :
            assert (amo_response_minmax_select_old == ($signed(
                amo_beat_word[31:0]
            ) < $signed(
                issued_amo_rs2[31:0]
            )));
          end
        end
        AMO_KIND_MAX: begin
          p_amo_max_is_minmax : assert (amo_response_is_minmax);
          if (issued_amo_is_d) begin
            p_amo_max_d_predicate :
            assert (amo_response_minmax_select_old == ($signed(
                XLEN'(i_mem_read_data)
            ) > $signed(
                issued_amo_rs2
            )));
          end else begin
            p_amo_max_w_predicate :
            assert (amo_response_minmax_select_old == ($signed(
                amo_beat_word[31:0]
            ) > $signed(
                issued_amo_rs2[31:0]
            )));
          end
        end
        AMO_KIND_MINU: begin
          p_amo_minu_is_minmax : assert (amo_response_is_minmax);
          if (issued_amo_is_d) begin
            p_amo_minu_d_predicate :
            assert (amo_response_minmax_select_old == (XLEN'(i_mem_read_data) < issued_amo_rs2));
          end else begin
            p_amo_minu_w_predicate :
            assert (amo_response_minmax_select_old == (amo_beat_word[31:0] < issued_amo_rs2[31:0]));
          end
        end
        AMO_KIND_MAXU: begin
          p_amo_maxu_is_minmax : assert (amo_response_is_minmax);
          if (issued_amo_is_d) begin
            p_amo_maxu_d_predicate :
            assert (amo_response_minmax_select_old == (XLEN'(i_mem_read_data) > issued_amo_rs2));
          end else begin
            p_amo_maxu_w_predicate :
            assert (amo_response_minmax_select_old == (amo_beat_word[31:0] > issued_amo_rs2[31:0]));
          end
        end
        default: begin
          p_amo_non_minmax_identity : assert (!amo_response_is_minmax);
        end
      endcase
    end
  end

  // Once active, MIN/MAX is purely a register-fed operand mux. Other AMOs use
  // the separately registered comparator-free arithmetic/logic result.
  always_comb begin
    if (i_rst_n && (amo_state == AMO_WRITE_ACTIVE)) begin
      p_amo_write_enabled : assert (o_amo_mem_write_en);
      if (amo_is_minmax_q) begin
        p_amo_minmax_write_mux :
        assert (amo_write_value == (amo_minmax_select_old_q ? amo_old_value : amo_minmax_rs2_q));
      end else begin
        p_amo_normal_write_payload : assert (amo_write_value == amo_write_data_q);
      end
    end
  end

  // full and empty are mutually exclusive
  always_comb begin
    if (i_rst_n) begin
      p_full_empty_mutex : assert (!(o_full && o_empty));
    end
  end

  // The head selector deliberately treats this registered identity as one-hot
  // to avoid rebuilding a physical-entry priority scan on its timing path.
  // This follows from the live-LQ ROB-tag uniqueness assumption above.
  always_comb begin
    if (i_rst_n) begin
      p_rob_head_match_onehot : assert ($onehot0(rob_head_match_q));
    end
  end

  // Whenever a stored MMIO entry is eligible at the ROB head, the dedicated
  // head path must dominate its redundant normal-scan admission and every
  // other candidate presented to the sq_check staging controller.
  always_comb begin
    if (i_rst_n && (|(head_mem_stored_onehot & lq_is_mmio))) begin
      p_head_mmio_priority_wins :
      assert (
          head_mem_stored_found && issue_mem_found && !issue_mem_from_update &&
          (issue_mem_onehot == head_mem_stored_onehot) &&
          (issue_mem_idx == head_mem_stored_idx));
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

  // The LQ-to-router handoff retains the ordinary non-speculative MMIO rule.
  // The router owns the later committed-store drain gate at the irreversible
  // memory-read accept boundary.
  always_comb begin
    if (i_rst_n && launch_mem_issue && sq_check_is_mmio_q) begin
      p_mmio_handoff_only_when_head : assert (sq_check_rob_tag_q == i_rob_head_tag);
    end
  end

  // A cached handoff owns the single response snapshot until its response is
  // accepted or drained; no second memory handoff may overlap it.
  always_comb begin
    if (i_rst_n && slow_outstanding) begin
      p_slow_outstanding_blocks_mem_handoff : assert (!o_mem_read_en);
    end
  end

  // A misalignment can complete before drain because it performs no device
  // access, but it retains the ordinary non-speculative MMIO head rule.
  always_comb begin
    if (i_rst_n && misalign_bypass_fire && sq_check_is_mmio_q) begin
      p_mmio_misalign_only_at_head : assert (sq_check_rob_tag_q == i_rob_head_tag);
    end
  end

  // SQ probing cannot accidentally complete an MMIO load through either
  // data-side bypass; only its router handoff may complete it.
  always_comb begin
    if (i_rst_n && sq_check_is_mmio_q) begin
      p_mmio_has_no_cache_or_forward_bypass : assert (!cache_hit_fast_path && !sq_do_forward);
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

  // Full-flush-cycle responses are drains only. They must not perform any
  // architectural or persistent-cache side effect.
  always_comb begin
    if (i_rst_n && i_flush_all) begin
      p_no_accept_during_full_flush : assert (!accept_mem_response);
      p_no_l0_fill_during_full_flush : assert (!cache_fill_valid);
    end
  end

  // A response coincident with a partial flush may warm the persistent L0,
  // but it remains a drained response for the killed speculative LQ owner.
  // This is the deliberate boundary that keeps the flush-tag age comparator
  // out of the L0 valid-bit write cone without changing architectural
  // completion behavior.
  always_comb begin
    if (i_rst_n && issued_entry_flushed && cache_fill_response_valid &&
        !issued_is_mmio && !issued_is_lr && !issued_is_amo &&
        !(issued_is_cached &&
          (issued_cached_line_invalidated || issued_cached_line_invalidate_now))) begin
      p_partial_flush_response_fills_l0 : assert (cache_fill_valid);
      p_partial_flush_fill_not_accepted : assert (!accept_mem_response);
      p_partial_flush_fill_is_drained : assert (drop_mem_response_now);
      p_partial_flush_fill_skips_lq_data_write : assert (!lq_data_we[0]);
    end
  end

  // The partial-flush kill above is the only condition intentionally removed
  // from the response-accept predicate. Every other L0 fill must still be an
  // architecturally accepted LQ response.
  always_comb begin
    if (i_rst_n && cache_fill_valid) begin
      p_fill_diverges_from_accept_only_for_kill :
      assert (issued_entry_flushed || accept_mem_response);
    end
  end

  // Once a stale drain is armed, its eventual response must have no LQ or
  // persistent-cache side effect.
  always_comb begin
    if (i_rst_n && drop_mem_response_pending) begin
      p_pending_drain_not_accepted : assert (!accept_mem_response);
      p_pending_drain_does_not_fill_l0 : assert (!cache_fill_valid);
    end
  end

  // -------------------------------------------------------------------------
  // Sequential assertions
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin

      // A cached handoff must arm the serialization bit on the same edge that
      // snapshots its response owner. Its accepted/dropped response is the
      // only normal release of that ownership window.
      if ($past(o_mem_read_en && launching_is_cached)) begin
        p_cached_handoff_sets_slow : assert (slow_outstanding);
      end
      if ($past(o_mem_read_en && !launching_is_cached)) begin
        p_fast_handoff_leaves_slow_clear : assert (!slow_outstanding);
      end
      if ($past(accept_mem_response && issued_is_cached)) begin
        p_cached_response_clears_slow : assert (!slow_outstanding);
      end
      if ($past(drop_mem_response_now && !(o_mem_read_en && launching_is_cached))) begin
        p_dropped_response_clears_slow : assert (!slow_outstanding);
      end

      // The response edge is the only AMO-payload capture boundary. It must
      // retain the exact response owner while moving directly into write-active.
      if ($past(amo_response_capture)) begin
        p_amo_old_capture : assert (amo_old_value == $past(amo_response_old_value));
        p_amo_entry_capture : assert (amo_entry_idx == $past(issued_idx));
        p_amo_addr_capture : assert (amo_write_addr_q == $past(issued_addr));
        p_amo_normal_result_capture :
        assert (amo_write_data_q == $past(amo_response_normal_result));
        p_amo_rs2_capture : assert (amo_minmax_rs2_q == $past(issued_amo_rs2));
        p_amo_width_capture : assert (amo_is_d_q == $past(issued_amo_is_d));
        p_amo_kind_capture : assert (amo_is_minmax_q == $past(amo_response_is_minmax));
        p_amo_predicate_capture :
        assert (amo_minmax_select_old_q == $past(amo_response_minmax_select_old));
        if ($past(amo_state == AMO_IDLE) && !i_flush_all) begin
          p_amo_response_enters_write_active :
          assert ((amo_state == AMO_WRITE_ACTIVE) && o_amo_mem_write_en);
        end
      end

      // write_done is the sole normal release from AMO_WRITE_ACTIVE. With it
      // withheld, both the request and every source register remain bit-stable.
      if ($past(
              amo_state == AMO_WRITE_ACTIVE && !i_amo_mem_write_done && !i_flush_all
          ) && !i_amo_mem_write_done && !i_flush_all) begin
        p_amo_stall_remains_active : assert (amo_state == AMO_WRITE_ACTIVE);
        p_amo_stall_old_stable : assert (amo_old_value == $past(amo_old_value));
        p_amo_stall_addr_stable : assert (amo_write_addr_q == $past(amo_write_addr_q));
        p_amo_stall_normal_result_stable : assert (amo_write_data_q == $past(amo_write_data_q));
        p_amo_stall_rs2_stable : assert (amo_minmax_rs2_q == $past(amo_minmax_rs2_q));
        p_amo_stall_width_stable : assert (amo_is_d_q == $past(amo_is_d_q));
        p_amo_stall_kind_stable : assert (amo_is_minmax_q == $past(amo_is_minmax_q));
        p_amo_stall_predicate_stable :
        assert (amo_minmax_select_old_q == $past(amo_minmax_select_old_q));
        p_amo_stall_write_en_stable : assert (o_amo_mem_write_en == $past(o_amo_mem_write_en));
        p_amo_stall_write_addr_stable :
        assert (o_amo_mem_write_addr == $past(o_amo_mem_write_addr));
        p_amo_stall_write_data_stable :
        assert (o_amo_mem_write_data == $past(o_amo_mem_write_data));
        p_amo_stall_write_width_stable :
        assert (o_amo_mem_write_is_dword == $past(o_amo_mem_write_is_dword));
      end

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

      // Exercise the split response predicate and a held active write.
      cover_amo_minmax_response : cover (amo_response_capture && amo_response_is_minmax);
      cover_amo_minmax_stall :
      cover ((amo_state == AMO_WRITE_ACTIVE) && amo_is_minmax_q && !i_amo_mem_write_done);
    end
  end

`endif  // FORMAL

endmodule : load_queue
