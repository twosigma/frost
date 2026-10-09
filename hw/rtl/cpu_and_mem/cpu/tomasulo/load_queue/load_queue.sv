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
 * Load queue. Each load, LR and AMO holds an entry from dispatch until its
 * result enters cdb_stage, the one-entry register in front of the MEM CDB
 * adapter (advanced by i_result_accepted). Completed and flushed entries
 * leave holes that allocation reuses, so ring order is not age order: age
 * comes from ROB tags, and the ROB-head load has issue priority. Ordinary
 * loads issue out of order once the SQ check allows; device loads, LRs and
 * AMOs leave only from the ROB head, and the data-memory router holds a
 * device read until every committed store has drained.
 */

module load_queue #(
    parameter int unsigned DEPTH = riscv_pkg::LqDepth,  // 8
    parameter bit ENABLE_L0_FAST_PATH = 1'b1,
    parameter bit PREISSUE_CANDIDATES = 1'b0,
    parameter int unsigned PREISSUE_SEL_WIDTH = 2,
    // With PREISSUE_CANDIDATES, select matches from MEM_RS ready vectors and
    // entry tags, or the direct MMU tag. This equals comparing candidate tags.
    parameter bit PREISSUE_READY_PICK = 1'b0,
    parameter int unsigned PREISSUE_RS_DEPTH = riscv_pkg::MemRsDepth,
    parameter int unsigned L0_CACHE_DEPTH = riscv_pkg::LqL0Depth,
    parameter bit PREPARE_LOAD_WHILE_BUSY = riscv_pkg::PrepareLoadWhileBusy,
    parameter bit ENABLE_SQ_FORWARD_FAST_PATH = 1'b0,
    // Loads in [CACHED_BASE, CACHED_BASE+CACHED_SIZE_BYTES) have variable
    // latency. Each uses a cs_* slot whose ID tags the request and response.
    // AMOs launch only at ROB head and block younger loads until their write
    // completes, so cached AMOs need no extra exclusivity. BRAM/device responses
    // arrive one cycle after router acceptance and share the fast_* tracker.
    // Device requests first wait in the router's pending register, which
    // blocks later handoffs through i_mem_bus_busy.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter int unsigned CACHED_SIZE_BYTES = 32'h4000_0000
) (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Allocation (from Dispatch, parallel with MEM_RS dispatch)
    // =========================================================================
    input  riscv_pkg::lq_alloc_req_t i_alloc,
    // Slot 2 may allocate alone; each slot has its own mem_needs_lq.
    input  riscv_pkg::lq_alloc_req_t i_alloc_2,
    output logic                     o_full,
    // Asserted when fewer than two entries fit; dispatch gates slot 2 separately.
    output logic                     o_full_for_2,
    // Conservative dispatch status counts current requests, even if a partial
    // flush rejects them, but credits frees and partial flushes a cycle later.
    // It never advertises more room than o_full and o_full_for_2.
    output logic                     o_dispatch_full,
    output logic                     o_dispatch_full_for_2,

    // =========================================================================
    // Address Update (from MEM_RS issue path: base + imm, pre-computed)
    // =========================================================================
    input riscv_pkg::lq_addr_update_t i_addr_update,

    // MEM_RS look-ahead one cycle before i_addr_update, used to register the
    // address CAM match for timing.
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_pre_issue_rob_tag,
    input logic [(1 << PREISSUE_SEL_WIDTH)*riscv_pkg::ReorderBufferTagWidth-1:0]
        i_pre_issue_rob_tags,
    input logic [PREISSUE_SEL_WIDTH-1:0] i_pre_issue_sel,
    input logic i_pre_issue_needs_lq,
    // PREISSUE_READY_PICK: candidate c's MEM_RS ready vector at
    // [c*PREISSUE_RS_DEPTH +: PREISSUE_RS_DEPTH] and MEM_RS entry e's ROB tag
    // at [e*ReorderBufferTagWidth +: ReorderBufferTagWidth]. Candidate c's
    // tag is the tag of the lowest set bit's entry, or of entry 0 when no bit
    // is set. While i_pre_issue_direct is high every candidate's tag is
    // i_pre_issue_direct_tag instead (the data MMU's look-ahead under
    // translation). Unused otherwise.
    input logic [(1 << PREISSUE_SEL_WIDTH)*PREISSUE_RS_DEPTH-1:0] i_pre_issue_ready,
    input logic [PREISSUE_RS_DEPTH*riscv_pkg::ReorderBufferTagWidth-1:0] i_pre_issue_entry_tags,
    input logic i_pre_issue_direct,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_pre_issue_direct_tag,

    // =========================================================================
    // Store Queue Disambiguation (combinational handshake)
    // =========================================================================
    output logic o_sq_check_valid,
    // Forwarding capture omits flush and commit-block gates for timing.
    // Consumers require sq_check_phase2, which resets on full flush and clears
    // when partial flush kills the staged load. sq_commit_interlock reapplies
    // the commit block (load queue README, "Forwarding results captured on a
    // flush cycle").
    output logic o_sq_check_capture_valid,
    output logic [riscv_pkg::XLEN-1:0] o_sq_check_addr,
    // Identical registered address copies, one per SQ CAM quarter, for fanout.
    // Preserve them through synthesis.
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
    output logic                                                     o_mem_read_en,
    output logic                                                     o_mem_addr_valid,
    output logic                 [              riscv_pkg::XLEN-1:0] o_mem_read_addr,
    output riscv_pkg::mem_size_e                                     o_mem_read_size,
    // Cached-tier slot of the launching load (don't-care for the fast tier):
    // up to riscv_pkg::CachedLoadSlots cached loads are in flight at once and
    // their responses come back tagged with it.
    output logic                 [riscv_pkg::CachedLoadSlotBits-1:0] o_mem_read_id,
    // Aligned MemDataBits beat carrying the dword at addr[31:3]
    // (hw/rtl/README.md, "Data-tier bus contract"); consumers extract by addr[2:0].
    input  logic                 [       riscv_pkg::MemDataBits-1:0] i_mem_read_data,
    input  logic                                                     i_mem_read_valid,
    // Response tracker: a tagged cached slot or the single fast-tier request.
    input  logic                                                     i_mem_read_is_cached,
    input  logic                 [riscv_pkg::CachedLoadSlotBits-1:0] i_mem_read_id,
    input  logic                                                     i_mem_bus_busy,
    // The router's pending bit, separate from the composite i_mem_bus_busy.
    // On a full flush it marks a request the router cancels before accepting
    // it, so the LQ owes no response for that request.
    input  logic                                                     i_mem_request_pending,
    // The router is holding a cached response behind the fast tier's beat
    // this cycle: registered into the cached launch hold so the next launch
    // is skipped and the response gets the port (bounded wait).
    input  logic                                                     i_cached_resp_held,

    // =========================================================================
    // CDB Result (to fu_cdb_adapter, FU_MEM slot)
    // =========================================================================
    output riscv_pkg::fu_complete_t o_fu_complete,
    // Registered CDB-stage occupancy without o_fu_complete's partial-flush
    // qualification. It observes a final staged result (tag/value/exception
    // in o_fu_complete) that recovery may still discard this cycle.
    output logic o_fu_complete_staged,
    // Unused input retained for Vivado mapping stability. Removing it and its
    // wrapper driver requires synthesis and optimization timing validation.
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
    // Cached-tier flag captured and gated with o_amo_mem_write_addr for router
    // timing. PMA excludes device AMOs, so it selects cached memory or BRAM.
    output logic                              o_amo_mem_write_is_cached,
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
    input logic i_cache_invalidate_valid,
    input logic [riscv_pkg::XLEN-1:0] i_cache_invalidate_addr,
    // =========================================================================
    // DMA coherence (from the wrapper's lq_coherence_port)
    // =========================================================================
    // Line invalidation for an admitted DMA write, applied on this edge: drop
    // the L0's dword copies of the line, mark in-flight loads of it
    // not-to-fill and in-flight LRs reservation-suppressed, clear a matching
    // reservation.
    input logic i_coh_inval_valid,
    input logic [riscv_pkg::XLEN-1:0] i_coh_inval_addr,
    // Admitted lines: an AMO or LR staged on one of them does not launch
    // until the line is released. i_coh_admit_pulse holds every staged AMO/LR
    // launch while an admission answer is presented and for a cycle after it
    // fires, until the registered line compare catches up.
    input logic [riscv_pkg::DmaCoherenceLocks-1:0] i_coh_block_valid,
    input logic [riscv_pkg::DmaCoherenceLocks-1:0][riscv_pkg::XLEN-1:0] i_coh_block_addr,
    input logic i_coh_admit_pulse,
    // Admission query: an AMO or LR on this line is staged, in flight, or
    // in its write phase, so the line cannot be admitted yet.
    input logic [riscv_pkg::XLEN-1:0] i_coh_query_addr,
    output logic o_coh_query_busy,
    // Memory observation: a cached-region load hit the L0, forwarded from the
    // SQ, or launched this cycle (the validation table's write; AMOs
    // excluded).
    output logic o_coh_observe_valid,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_coh_observe_rob_tag,
    output logic [riscv_pkg::XLEN-1:0] o_coh_observe_addr,

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
    // Head-load sub-bucket diagnostics (split HEAD_WAIT_LOAD_NO_OUTSTANDING)
    // =========================================================================
    // Combinational indicators describing the state of the LQ entry matching
    // i_rob_head_tag (if any). They are mutually exclusive; the wrapper's
    // perf counters AND each with (head_wait_mem_load && !o_mem_outstanding)
    // to get the sub-bucket counters.
    output logic o_head_load_addr_pending,  // matches head_tag, addr not yet computed
    output logic o_head_load_sq_disambig,   // ready, blocked on SQ disambig
    output logic o_head_load_bus_blocked,   // ready, blocked on bus / arbitration / pipeline
    output logic o_head_load_cdb_wait,      // data ready in LQ, waiting to enter cdb_stage
    output logic o_head_load_post_lq,       // LQ entry already freed, CDB pipeline to ROB

    // =========================================================================
    // Bus-blocked sub-bucket diagnostics
    // =========================================================================
    // Partition o_head_load_bus_blocked in priority order. With the same external
    // head_wait_mem_load && !o_mem_outstanding gate, their sum equals the parent.
    output logic o_head_load_bb_bus_busy,  // i_mem_bus_busy = 1
    output logic o_head_load_bb_sq_wait,  // in sq_check stage but !sq_check_phase2
    output logic o_head_load_bb_staging,  // catch-all (pre-sq_check capture, drop-pending, etc.)
    // Staging catch-all sub-decomposition (partitions o_head_load_bb_staging):
    output logic o_head_load_bbs_other_in_staging,  // sq_check busy with a DIFFERENT load
    output logic o_head_load_bbs_launch_gated,  // head staged, phase2 armed, not complete
    output logic o_head_load_bbs_capture_gap  // staging free; head not captured yet
);

  // ===========================================================================
  // Local Parameters
  // ===========================================================================
  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned IdxWidth = $clog2(DEPTH);
  localparam int unsigned PtrWidth = IdxWidth + 1;  // MSB unused; see head_ptr
  localparam int unsigned CountWidth = $clog2(DEPTH + 1);
  // Keep this literal for Yosys, which does not parse $bits(package::enum)
  // reliably. mem_size_e is logic [1:0].
  localparam int unsigned MemSizeWidth = 2;

  // The eighteen W/D opcodes reduce to nine semantic AMO operations stored
  // per entry. INVALID returns the old value for malformed input.
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

  // Order tags relative to head: tags below head follow tags at or above it.
  // Within each range, numeric order holds. Comparisons implement the order
  // of unsigned extended subtraction.
  function automatic logic is_younger(input logic [ReorderBufferTagWidth-1:0] entry_tag,
                                      input logic [ReorderBufferTagWidth-1:0] flush_tag,
                                      input logic [ReorderBufferTagWidth-1:0] head);
    is_younger = (entry_tag > flush_tag) ^ ((entry_tag < head) ^ (flush_tag < head));
  endfunction

  // Compare live ROB tags relative to the allocation bundle's saved head.
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

  // Exception cause for a staged-entry fault completion (the misalign
  // bypass). Priority: a translation fault parked on the entry, then a
  // recomputed PMA access fault (access outranks misalignment), then bare
  // misalignment. An AMO's cause is always the store/AMO-family one,
  // misalignment included (cause 6, matching Spike and the privileged spec);
  // LR stays load-family.
  function automatic riscv_pkg::exc_cause_t lq_bypass_cause(
      input riscv_pkg::data_fault_kind_e parked, input logic pma_fault, input logic is_amo);
    unique case (parked)
      riscv_pkg::DFAULT_MISALIGN:
      lq_bypass_cause = riscv_pkg::exc_cause_t'(
          is_amo ? riscv_pkg::ExcStoreAddrMisalign[riscv_pkg::ExcCauseWidth-1:0] :
              riscv_pkg::ExcLoadAddrMisalign[riscv_pkg::ExcCauseWidth-1:0]);
      riscv_pkg::DFAULT_PAGE:
      lq_bypass_cause = riscv_pkg::exc_cause_t'(
          is_amo ? riscv_pkg::ExcStorePageFault[riscv_pkg::ExcCauseWidth-1:0] :
              riscv_pkg::ExcLoadPageFault[riscv_pkg::ExcCauseWidth-1:0]);
      riscv_pkg::DFAULT_ACCESS:
      lq_bypass_cause = riscv_pkg::exc_cause_t'(
          is_amo ? riscv_pkg::ExcStoreAccessFault[riscv_pkg::ExcCauseWidth-1:0] :
              riscv_pkg::ExcLoadAccessFault[riscv_pkg::ExcCauseWidth-1:0]);
      default:
      lq_bypass_cause = pma_fault ?
          riscv_pkg::exc_cause_t'(
          is_amo ? riscv_pkg::ExcStoreAccessFault[riscv_pkg::ExcCauseWidth-1:0] :
              riscv_pkg::ExcLoadAccessFault[riscv_pkg::ExcCauseWidth-1:0]) :
          riscv_pkg::exc_cause_t'(
          is_amo ? riscv_pkg::ExcStoreAddrMisalign[riscv_pkg::ExcCauseWidth-1:0] :
              riscv_pkg::ExcLoadAddrMisalign[riscv_pkg::ExcCauseWidth-1:0]);
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
  // Storage: sparse queue with FF-based control plus LUTRAM payloads
  // ===========================================================================

  // Ring cursors: head_ptr starts the issue scans, tail_ptr the free-entry
  // search. Only their low IdxWidth bits are used; full and empty come from
  // lq_valid.
  logic [PtrWidth-1:0] head_ptr;
  logic [PtrWidth-1:0] tail_ptr;

  wire [IdxWidth-1:0] head_idx = head_ptr[IdxWidth-1:0];
  // Per-entry 1-bit flags (packed vectors for bulk operations)
  logic [DEPTH-1:0] lq_valid;
  logic [DEPTH-1:0] lq_is_fp;
  logic [DEPTH-1:0] lq_addr_valid;
  logic [DEPTH-1:0] lq_sign_ext;
  logic [DEPTH-1:0] lq_is_mmio;
  logic [DEPTH-1:0] lq_issued;
  logic [DEPTH-1:0] lq_data_valid;
  logic [DEPTH-1:0] lq_forwarded;
  logic [DEPTH-1:0] lq_is_lr;
  logic [DEPTH-1:0] lq_is_amo;

  // Per-entry multi-bit fields
  // Translation-stage fault kind: parked by the addr update
  // for an op the data MMU refused; the entry's address is then the VA
  // (xtval) and the staged check completes it through the misalign bypass
  // with the kind-derived cause. DFAULT_NONE for every untranslated entry.
  riscv_pkg::data_fault_kind_e lq_fault_kind[DEPTH];
  logic [ReorderBufferTagWidth-1:0] lq_rob_tag[DEPTH];
  // Distinct allocation indices allow two writes to the per-entry FF array.
  (* ram_style = "registers" *)
  amo_kind_e lq_amo_kind[DEPTH];
  (* ram_style = "registers" *)
  logic [MemSizeWidth-1:0] lq_size[DEPTH];
  logic [MemSizeWidth-1:0] lq_size_issue_cdb_rd;
  logic [XLEN-1:0] lq_address_issue_mem_rd;
  logic [XLEN-1:0] lq_amo_rs2_rd;
  logic [IdxWidth-1:0] amo_entry_idx;
  logic full;
  logic full_for_2;

  // alloc_target and alloc_target_2 are the first two free slots from tail.
  // A lone slot-2 request uses alloc_target.
  logic [PtrWidth-1:0] alloc_target_2;
  logic slot1_alloc_en;
  logic slot2_alloc_en;
  logic dispatch_slot1_reserve;
  logic dispatch_slot2_reserve;
  logic [IdxWidth-1:0] slot2_alloc_idx;
  logic [DEPTH-1:0] first_target_oh;
  logic [DEPTH-1:0] second_target_oh;
  // Precompute room-qualified allocation targets, then gate with dispatch
  // valids for timing.
  (* keep = "true", max_fanout = 16 *)
  logic [DEPTH-1:0] first_room_oh;
  (* keep = "true", max_fanout = 16 *)
  logic [DEPTH-1:0] second_room_oh;
  // Preserve per-entry steering for timing.
  (* keep = "true", max_fanout = 16 *)
  logic [DEPTH-1:0] slot1_alloc_oh;
  (* keep = "true", max_fanout = 16 *)
  logic [DEPTH-1:0] slot2_alloc_oh;
  // Either slot allocates entry i: the control/payload write enable.
  (* keep = "true", max_fanout = 16 *)
  logic [DEPTH-1:0] alloc_oh;

  // Delay AMO-kind writes one edge for timing. A new entry must receive an
  // address and pass SQ staging before launching, so the payload arrives
  // before use. Registered accepted-request bits qualify these writes.
  logic [1:0] amo_kind_alloc_present_q;
  logic [1:0][IdxWidth-1:0] amo_kind_alloc_idx_q;
  amo_kind_e amo_kind_alloc_data_q[2];

  // Row i records unfinished AMOs older than entry i (see dependency masks
  // below). A killed row can remain high for its first invalid cycle, but
  // clears before reuse. Register each row's reduction for issue selection.
  logic [DEPTH-1:0] older_amo_dep_q[DEPTH];
  logic [DEPTH-1:0] older_amo_dep_d[DEPTH];
  logic [DEPTH-1:0] older_amo_block_q;
  logic [DEPTH-1:0] older_amo_block_d;
  logic [DEPTH-1:0] pending_amo_phys;
  logic [DEPTH-1:0] dep_done_oh;
  logic [DEPTH-1:0] dep_live_src;
  logic [DEPTH-1:0] dep_replaced_oh;
  logic [DEPTH-1:0] dep_new_amo_src;
  logic [DEPTH-1:0] dep_identity_valid_q;
  logic [ReorderBufferTagWidth-1:0] dep_head_q;

  // Reservation register (LR/SC)
  logic reservation_valid;
  logic [XLEN-1:0] reservation_addr;
  assign o_reservation_valid = reservation_valid;
  assign o_reservation_addr  = reservation_addr;

  // AMO FSM
  typedef enum logic [1:0] {
    AMO_IDLE,
    AMO_WRITE_ACTIVE,
    AMO_COMPUTE
  } amo_state_e;
  amo_state_e                              amo_state;
  amo_kind_e                               amo_kind_q;
  logic                                    amo_compute_owner_killed;
  logic                                    amo_compute_commit;
  logic                                    amo_response_capture;
  logic                                    amo_response_is_minmax;
  logic       [    XLEN-1:0]               amo_old_value;
  logic       [    XLEN-1:0]               amo_write_addr_q;
  // Tier flag of amo_write_addr_q, captured beside it (see the port note).
  logic                                    amo_write_is_cached_q;
  logic       [    XLEN-1:0]               amo_write_data_q;
  logic       [    XLEN-1:0]               amo_minmax_rs2_q;
  logic                                    amo_is_d_q;
  logic                                    amo_is_minmax_q;
  // Capture independent .D and .W unsigned relations for timing.
  // Encoding is {equal, old_less_than_rs2}: GT=00, LT=01, EQ=10.
  (* keep = "true", equivalent_register_removal = "no" *)
  logic       [         1:0]               amo_minmax_relation_d_q;
  (* keep = "true", equivalent_register_removal = "no" *)
  logic       [         1:0]               amo_minmax_relation_w_q;
  (* keep = "true", equivalent_register_removal = "no" *)
  logic                                    amo_minmax_is_unsigned_q;
  (* keep = "true", equivalent_register_removal = "no" *)
  logic                                    amo_minmax_is_max_q;
  logic       [         1:0]               amo_minmax_selected_relation;
  logic                                    amo_minmax_old_sign;
  logic                                    amo_minmax_rs2_sign;
  logic                                    amo_minmax_select_old_active;
  logic       [    XLEN-1:0]               amo_write_value;

  // ===========================================================================
  // lq_data LUTRAM: FLEN-wide single-beat payloads
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
  // Limit fanout to dispatch and front-end stall logic.
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
  // Keep zero causes on D rather than inferring synchronous reset, for timing.
  (* extract_reset = "no" *) riscv_pkg::fu_complete_t cdb_stage_data;
  // Hold a candidate stable while the SQ resolves it. Stage the next load
  // while a read is outstanding so it can launch when memory becomes available.
  logic sq_check_pending;
  // Identical copies of sq_check_pending for the address-copy enables,
  // with the same reset and next state. Preserve separate flops for fanout.
  (* dont_touch = "true" *) logic [2:0] sq_check_pending_copy;
  logic [IdxWidth-1:0] sq_check_idx;
  logic [ReorderBufferTagWidth-1:0] sq_check_rob_tag_q;
  // The primary address feeds local LQ logic and one SQ CAM quarter.
  // Allow replication for fanout; all address copies load on the same edge.
  (* max_fanout = 16 *) logic [XLEN-1:0] sq_check_addr_q;
  // Identical address copies with the same data and enable, for SQ fanout.
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
  // Base-type copy of the staged data_fault_kind_e (bit-addressable for the
  // FDRE branch); compared against the enum encodings via cast.
  logic [1:0] sq_check_fault_kind_q;
  logic sq_check_no_older_store_q;
  logic [DEPTH-1:0] sq_check_in_flight_mask;
  logic [DEPTH-1:0] sq_check_in_flight_mask_next;
  logic sq_check_capture;
  logic sq_check_replace;
  logic sq_check_entry_valid;
  logic sq_check_entry_issueable;
  logic sq_check_phase2;

  // BRAM/MMIO responses arrive one cycle after router acceptance. The fast_*
  // tracker supports consecutive BRAM loads; MMIO pending feedback blocks
  // later handoffs until acceptance. Cached requests hold cs_* slots until
  // response. issued_idx selects the answering cached slot or fast tracker.
  // A simultaneous launch overrides response clearing of mem_outstanding.
  logic mem_outstanding;  // fast tier: a BRAM/MMIO response is owed
  logic [IdxWidth-1:0] issued_idx;  // Entry for this cycle's response
  // Capture fast-tier attributes at launch and hold them until response.
  // Each cached slot holds its own snapshot. The issued_* mux selects the
  // answering slot's snapshot for cached responses, otherwise the fast one.
  logic [IdxWidth-1:0] fast_idx;
  logic [XLEN-1:0] fast_addr;
  logic [MemSizeWidth-1:0] fast_size;
  logic fast_is_fp;
  logic fast_is_lr;
  logic fast_is_amo;
  logic fast_is_mmio;
  logic fast_sign_ext;
  logic [ReorderBufferTagWidth-1:0] fast_rob_tag;
  amo_kind_e fast_amo_kind;
  logic [XLEN-1:0] fast_amo_rs2;

  localparam int unsigned CachedSlots = riscv_pkg::CachedLoadSlots;
  localparam int unsigned CachedSlotBits = riscv_pkg::CachedLoadSlotBits;
  logic [CachedSlots-1:0] cs_valid;  // Slot tracks an outstanding cached load
  logic [CachedSlots-1:0] cs_drop;  // its response is to be drained (flushed)
  logic [CachedSlots-1:0] cs_inval;  // Store or DMA invalidated the in-flight line
  // Leave per-slot storage to inference. Vivado maps response-only reads
  // (size, amo_kind, amo_rs2) to LUTRAM, reducing launch fanout.
  logic [IdxWidth-1:0] cs_idx[CachedSlots];
  logic [XLEN-1:0] cs_addr[CachedSlots];
  logic [MemSizeWidth-1:0] cs_size[CachedSlots];
  logic [CachedSlots-1:0] cs_is_fp;
  logic [CachedSlots-1:0] cs_is_lr;
  logic [CachedSlots-1:0] cs_is_amo;
  logic [CachedSlots-1:0] cs_sign_ext;
  logic [ReorderBufferTagWidth-1:0] cs_rob_tag[CachedSlots];
  amo_kind_e cs_amo_kind[CachedSlots];
  logic [XLEN-1:0] cs_amo_rs2[CachedSlots];
  logic cached_launch_hold_q;  // registered: every slot busy, or a cached response held
  logic cs_any_q;  // some cached load in flight (registered; diagnostics only)

  // Snapshot selected for this cycle's response.
  logic resp_from_slot;
  logic [CachedSlotBits-1:0] resp_slot;
  logic resp_outstanding;  // A tracker still awaits this response
  logic resp_drop;  // ... but it was flushed: drain it
  logic [XLEN-1:0] issued_addr;
  logic [MemSizeWidth-1:0] issued_size;
  logic issued_is_fp;
  logic issued_is_lr;
  logic issued_is_amo;
  logic issued_is_mmio;
  logic issued_is_cached;
  logic issued_sign_ext;
  logic [ReorderBufferTagWidth-1:0] issued_rob_tag;
  amo_kind_e issued_amo_kind;
  logic [XLEN-1:0] issued_amo_rs2;
  logic drop_mem_response_pending;  // fast tier: drop the next owed response after flush
  logic issued_cached_line_invalidated;
  logic issued_cached_line_invalidate_now;
  logic [CachedSlots-1:0] cs_inval_now;

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

  // Keep lq_size in FFs for SQ-check timing.
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
  // MIN/MAX captures raw comparison relations, then selects between held
  // operands in the write phase. It writes the cycle after the response.
  // Other operations use these functions during AMO_COMPUTE.
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

`ifdef FORMAL
  // Strict-comparison reference functions for the registered relation proof.
  // These do not participate in the synthesized response datapath.
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

  // The .W reference compares exactly the low word, including signedness.
  // rs2[63:32] is architecturally irrelevant, and the returned word's sign
  // extension is an rd semantic rather than a widening of the memory operation.
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
`endif

  // AMO cache invalidation: invalidate L0 cache when AMO write completes
  logic amo_cache_inv;
  assign amo_cache_inv = (amo_state == AMO_WRITE_ACTIVE) && i_amo_mem_write_done;
  // Dword granule: the response beat fills a full L0 dword line, so a store
  // landing in either word of an in-flight dword must suppress that fill.
  // One comparator per cached slot; the fast tier never fills from a line a
  // store could touch (its response lands the cycle after launch).
  always_comb begin
    for (int sl = 0; sl < int'(CachedSlots); sl++) begin
      cs_inval_now[sl] = cs_valid[sl] && i_cache_invalidate_valid &&
          (i_cache_invalidate_addr[XLEN-1:3] == cs_addr[sl][XLEN-1:3]);
    end
  end

  // Compare DMA invalidations with cached slots and the reservation by 32-byte
  // line. Register holds for staged AMO/LR requests; their second-cycle launch
  // rule gives the comparison time to complete.
  localparam int unsigned CohLineLsb = riscv_pkg::DmaCoherenceLineLsb;
  logic [CachedSlots-1:0] cs_coh_inval_now;
  logic [CachedSlots-1:0] cs_lr_suppress;  // in-flight LR: set no reservation
  logic coh_launch_hold_q;
  logic coh_hold_valid_q;  // Hold matches the staged entry
  logic coh_staged_amo_lr;
  logic coh_block_hit;
  logic coh_reservation_inval;
  logic issued_lr_suppressed;
  assign coh_staged_amo_lr = sq_check_pending && (sq_check_is_amo_q || sq_check_is_lr_q);
  always_comb begin
    for (int sl = 0; sl < int'(CachedSlots); sl++) begin
      cs_coh_inval_now[sl] = cs_valid[sl] && i_coh_inval_valid &&
          (i_coh_inval_addr[XLEN-1:CohLineLsb] == cs_addr[sl][XLEN-1:CohLineLsb]);
    end
    coh_block_hit = 1'b0;
    for (int k = 0; k < int'(riscv_pkg::DmaCoherenceLocks); k++) begin
      if (i_coh_block_valid[k] &&
          (i_coh_block_addr[k][XLEN-1:CohLineLsb] == sq_check_addr_q[XLEN-1:CohLineLsb])) begin
        coh_block_hit = 1'b1;
      end
    end
    o_coh_query_busy = coh_staged_amo_lr &&
        (sq_check_addr_q[XLEN-1:CohLineLsb] == i_coh_query_addr[XLEN-1:CohLineLsb]);
    for (int sl = 0; sl < int'(CachedSlots); sl++) begin
      if (cs_valid[sl] && (cs_is_amo[sl] || cs_is_lr[sl]) &&
          (cs_addr[sl][XLEN-1:CohLineLsb] == i_coh_query_addr[XLEN-1:CohLineLsb])) begin
        o_coh_query_busy = 1'b1;
      end
    end
    if (((amo_state == AMO_COMPUTE) || (amo_state == AMO_WRITE_ACTIVE)) &&
        (amo_write_addr_q[XLEN-1:CohLineLsb] == i_coh_query_addr[XLEN-1:CohLineLsb])) begin
      o_coh_query_busy = 1'b1;
    end
  end
  assign coh_reservation_inval = i_coh_inval_valid && reservation_valid &&
      (i_coh_inval_addr[XLEN-1:CohLineLsb] == reservation_addr[XLEN-1:CohLineLsb]);
  // The hold is a registered compare of the staged atomic's line against the
  // mirror. A newly captured or replaced atomic has no compare of its own
  // yet, so it waits one cycle before its first launch (coh_hold_valid_q);
  // that closes the window in which an atomic staged on the admission
  // decision edge could launch ahead of the port's holds.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      coh_launch_hold_q <= 1'b0;
      coh_hold_valid_q  <= 1'b0;
    end else begin
      coh_launch_hold_q <= coh_staged_amo_lr && coh_block_hit;
      coh_hold_valid_q  <= coh_staged_amo_lr && !sq_check_capture && !sq_check_replace;
    end
  end

  // Select this cycle's response tracker.
  assign resp_from_slot = i_mem_read_valid && i_mem_read_is_cached;
  assign resp_slot = i_mem_read_id;
  assign resp_outstanding = resp_from_slot ? cs_valid[resp_slot] : mem_outstanding;
  assign resp_drop = resp_from_slot ? cs_drop[resp_slot] : drop_mem_response_pending;
  assign issued_idx = resp_from_slot ? cs_idx[resp_slot] : fast_idx;
  assign issued_addr = resp_from_slot ? cs_addr[resp_slot] : fast_addr;
  assign issued_size = resp_from_slot ? cs_size[resp_slot] : fast_size;
  assign issued_is_fp = resp_from_slot ? cs_is_fp[resp_slot] : fast_is_fp;
  assign issued_is_lr = resp_from_slot ? cs_is_lr[resp_slot] : fast_is_lr;
  assign issued_is_amo = resp_from_slot ? cs_is_amo[resp_slot] : fast_is_amo;
  assign issued_is_mmio = resp_from_slot ? 1'b0 : fast_is_mmio;
  assign issued_is_cached = resp_from_slot;
  assign issued_sign_ext = resp_from_slot ? cs_sign_ext[resp_slot] : fast_sign_ext;
  assign issued_rob_tag = resp_from_slot ? cs_rob_tag[resp_slot] : fast_rob_tag;
  assign issued_amo_kind = resp_from_slot ? cs_amo_kind[resp_slot] : fast_amo_kind;
  assign issued_amo_rs2 = resp_from_slot ? cs_amo_rs2[resp_slot] : fast_amo_rs2;
  assign issued_cached_line_invalidated = resp_from_slot && cs_inval[resp_slot];
  assign issued_cached_line_invalidate_now =
      resp_from_slot && (cs_inval_now[resp_slot] || cs_coh_inval_now[resp_slot]);
  // Including the invalidation applied this very cycle: an LR whose response
  // lands on that edge would otherwise set its reservation while the clear
  // below only sees reservations that already exist.
  assign issued_lr_suppressed =
      resp_from_slot && (cs_lr_suppress[resp_slot] || cs_coh_inval_now[resp_slot]);

  // ===========================================================================
  // Count, Full, Empty
  // ===========================================================================
  // Local occupancy counts lq_valid for immediate reuse of sparse holes.
  // Dispatch status includes allocation requests but credits frees and partial
  // flushes a cycle later, conservatively simplifying timing.
  always_comb begin
    count = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      count = count + CountWidth'(lq_valid[i]);
    end
  end

  // Group free entries to detect room for one or two without a full popcount
  // on allocation controls. The exact count remains available for status.
  localparam int FreeGroups = (DEPTH + 3) / 4;
  (* keep = "true" *) logic [FreeGroups-1:0] group_has_free, group_has_two_free;
  logic [FreeGroups-1:0] two_free_groups;
  for (genvar group = 0; group < FreeGroups; group++) begin : gen_capacity_group
    logic [3:0] free_bits;
    for (genvar lane = 0; lane < 4; lane++) begin : gen_lane
      if (4 * group + lane < DEPTH) assign free_bits[lane] = !lq_valid[4*group+lane];
      else assign free_bits[lane] = 1'b0;
    end
    assign group_has_free[group] = |free_bits;
    assign group_has_two_free[group] =
        (free_bits[0] && (|free_bits[3:1])) ||
        (free_bits[1] && (|free_bits[3:2])) || (free_bits[2] && free_bits[3]);
    if (group == 0) assign two_free_groups[group] = 1'b0;
    else assign two_free_groups[group] = group_has_free[group] && (|group_has_free[group-1:0]);
  end
  assign full = &lq_valid;
  assign full_for_2 = !(|group_has_two_free) && !(|two_free_groups);
`ifdef F_LQ_CAPACITY_PROOF
  always_comb begin
    assert (full == (count == CountWidth'(DEPTH)));
    assert (full_for_2 == ((count == CountWidth'(DEPTH)) || (count == CountWidth'(DEPTH - 1))));
  end
`endif
  assign empty = (count == CountWidth'(0));

  assign o_full = full;
  assign o_full_for_2 = full_for_2;
  assign o_dispatch_full = dispatch_full_q;
  assign o_dispatch_full_for_2 = dispatch_full_for_2_q;
  assign o_empty = empty;
  assign o_dispatch_empty = empty;
  assign o_count = count;
  assign o_dispatch_count = count;

  // Slot 1 takes the first free entry. Slot 2 takes the second when paired,
  // or the first when alone. Reject requests during either flush, matching
  // the ROB. Dispatch can still present requests before the front-end kill
  // arrives; accepting one would create an entry for an unallocated ROB tag.
  logic alloc_flush_ok;
  assign alloc_flush_ok = !i_flush_all && !i_flush_en;
  // full implies full_for_2: a refused slot-1 request leaves no room for
  // slot 2. Request valids can therefore select the room terms directly.
  logic alloc_room_1;
  logic alloc_room_2;
  assign alloc_room_1 = alloc_flush_ok && !full;
  assign alloc_room_2 = alloc_flush_ok && !full_for_2;
  assign slot1_alloc_en = i_alloc.valid && alloc_room_1;
  assign slot2_alloc_en = i_alloc_2.valid && (i_alloc.valid ? alloc_room_2 : alloc_room_1);
  assign slot2_alloc_idx = slot1_alloc_en ? alloc_target_2[IdxWidth-1:0]
                                          : alloc_target[IdxWidth-1:0];

  // Reserve room from raw requests for timing. Flush may reject a reserved
  // allocation, causing one conservative stall cycle. Capacity gates bound
  // the prediction at DEPTH.
  assign dispatch_slot1_reserve = i_alloc.valid && !full;
  assign dispatch_slot2_reserve = i_alloc_2.valid && (dispatch_slot1_reserve ? !full_for_2 : !full);

  always_comb begin
    dispatch_count_next = count + CountWidth'(dispatch_slot1_reserve) +
                          CountWidth'(dispatch_slot2_reserve);
  end

  // Precompute occupancy comparisons before request selection for timing.
  // A request reserves one entry if it fits; a pair reserves two, one, or
  // none, as room allows. dispatch_count_next is the reference count.
  logic count_is_depth_m1;
  logic count_is_depth_m2;
  logic count_is_depth_m3;
  logic dispatch_any_request;
  logic dispatch_pair_request;
  logic dispatch_full_next;
  logic dispatch_full_for_2_next;
  assign count_is_depth_m1 = (count == CountWidth'(DEPTH - 1));
  assign count_is_depth_m2 = (count == CountWidth'(DEPTH - 2));
  assign count_is_depth_m3 = (DEPTH >= 3) && (count == CountWidth'(DEPTH - 3));
  assign dispatch_any_request = i_alloc.valid || i_alloc_2.valid;
  assign dispatch_pair_request = i_alloc.valid && i_alloc_2.valid;
  assign dispatch_full_next = full || (dispatch_any_request && count_is_depth_m1) ||
                              (dispatch_pair_request && count_is_depth_m2);
  assign dispatch_full_for_2_next = full || count_is_depth_m1 ||
                                    (dispatch_any_request && count_is_depth_m2) ||
                                    (dispatch_pair_request && count_is_depth_m3);

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      dispatch_full_q <= 1'b0;
      dispatch_full_for_2_q <= 1'b0;
    end else begin
      dispatch_full_q <= dispatch_full_next;
      dispatch_full_for_2_q <= dispatch_full_for_2_next;
    end
  end

  // ---------------------------------------------------------------------------
  // Address-update CAM: current-cycle entry writes and a registered
  // pre-match for same-cycle issue bypass.
  //
  // Register the CAM match from MEM_RS look-ahead at T-1. At issue cycle T,
  // qualify it with issue valid and combine it with stored lq_addr_valid.
  // ---------------------------------------------------------------------------

  // Current-cycle match for address-valid and payload writes.
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

  // Register tag matches and issue-valid separately for timing. Their shared
  // edge and reset/flush make the post-register AND equal a qualified match.
  logic [DEPTH-1:0] addr_update_pre_match;
  logic [DEPTH-1:0] addr_update_pre_match_tags_q;
  logic addr_update_pre_issue_valid_q;
  logic [DEPTH-1:0] addr_update_pre_match_q;
`ifdef FORMAL
  // PREISSUE_READY_PICK reference tags: the direct tag, or the tag of each
  // candidate's lowest ready MEM_RS entry (entry 0 when none is ready).
  localparam int FNumCandidates = 1 << PREISSUE_SEL_WIDTH;
  logic [ReorderBufferTagWidth-1:0] f_pick_tag[FNumCandidates];
  always_comb begin
    for (int c = 0; c < FNumCandidates; c++) begin
      f_pick_tag[c] = i_pre_issue_entry_tags[0+:ReorderBufferTagWidth];
      for (int rs_entry = PREISSUE_RS_DEPTH - 1; rs_entry >= 0; rs_entry--) begin
        if (i_pre_issue_ready[c*PREISSUE_RS_DEPTH+rs_entry]) begin
          f_pick_tag[c] =
              i_pre_issue_entry_tags[rs_entry*ReorderBufferTagWidth +: ReorderBufferTagWidth];
        end
      end
      if (i_pre_issue_direct) f_pick_tag[c] = i_pre_issue_direct_tag;
    end
  end
`endif

  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      addr_update_pre_match[i] = lq_valid[i] &&
                                 !lq_addr_valid[i] &&
                                 (lq_rob_tag[i] == i_pre_issue_rob_tag);
    end
  end

  if (PREISSUE_CANDIDATES) begin : gen_pre_match_candidates
    localparam int NumCandidates = 1 << PREISSUE_SEL_WIDTH;
    logic [DEPTH-1:0] candidate_match[NumCandidates];
    logic [DEPTH-1:0] candidate_match_q[NumCandidates];
    logic [PREISSUE_SEL_WIDTH-1:0] select_q;
    if (PREISSUE_READY_PICK) begin : gen_ready_pick
      // Compare LQ tags with each MEM_RS tag before selection for timing. Picking
      // the lowest ready entry's match equals comparing with its tag. With no
      // ready entry, both paths select entry 0.
      (* keep = "true" *) logic [PREISSUE_RS_DEPTH-1:0] pre_tag_eq[DEPTH];
      logic [DEPTH-1:0] pre_live, pre_direct_match;
      for (genvar entry = 0; entry < DEPTH; entry++) begin : gen_entry_compare
        assign pre_live[entry] = lq_valid[entry] && !lq_addr_valid[entry];
        assign pre_direct_match[entry] = pre_live[entry] &&
            (lq_rob_tag[entry] == i_pre_issue_direct_tag);
        for (genvar rs_entry = 0; rs_entry < PREISSUE_RS_DEPTH; rs_entry++) begin : gen_rs_entry
          assign pre_tag_eq[entry][rs_entry] = lq_rob_tag[entry] ==
              i_pre_issue_entry_tags[rs_entry*ReorderBufferTagWidth +: ReorderBufferTagWidth];
        end
      end
      for (genvar candidate = 0; candidate < NumCandidates; candidate++) begin : gen_candidate
        wire [PREISSUE_RS_DEPTH-1:0] ready =
            i_pre_issue_ready[candidate*PREISSUE_RS_DEPTH +: PREISSUE_RS_DEPTH];
        logic [DEPTH-1:0] picked;
        if (PREISSUE_RS_DEPTH == 8) begin : gen_pick8
          // Prefer the lowest ready entry in the low half, then the high half.
          // With none ready, use entry 0.
          wire any_low = |ready[3:0];
          for (genvar entry = 0; entry < DEPTH; entry++) begin : gen_entry
            wire [7:0] eq = pre_tag_eq[entry];
            wire pick23 = ready[2] ? eq[2] : (ready[3] && eq[3]);
            wire pick_low = ready[0] ? eq[0] : ready[1] ? eq[1] : pick23;
            wire pick67 = ready[6] ? eq[6] : ready[7] ? eq[7] : eq[0];
            wire pick_high = ready[4] ? eq[4] : ready[5] ? eq[5] : pick67;
            assign picked[entry] = any_low ? pick_low : pick_high;
          end
        end else begin : gen_pick
          always_comb begin
            for (int entry = 0; entry < DEPTH; entry++) begin
              picked[entry] = pre_tag_eq[entry][0];
              for (int rs_entry = PREISSUE_RS_DEPTH - 1; rs_entry >= 0; rs_entry--) begin
                if (ready[rs_entry]) picked[entry] = pre_tag_eq[entry][rs_entry];
              end
            end
          end
        end
        assign candidate_match[candidate] = i_pre_issue_direct ? pre_direct_match :
            (pre_live & picked);
      end
`ifndef SYNTHESIS
      always @(posedge i_clk) begin
        if (i_rst_n && i_pre_issue_needs_lq) begin
          assert (candidate_match[i_pre_issue_sel] == addr_update_pre_match);
        end
      end
`endif
`ifdef FORMAL
`ifdef F_LQ_PREMATCH_COFACTORS
      // Every candidate's match equals the CAM of its reference tag.
      for (genvar f_c = 0; f_c < NumCandidates; f_c++) begin : gen_f_pick
        for (genvar f_entry = 0; f_entry < DEPTH; f_entry++) begin : gen_f_entry
          always_comb begin
            assert (candidate_match[f_c][f_entry] == (lq_valid[f_entry] &&
                !lq_addr_valid[f_entry] && (lq_rob_tag[f_entry] == f_pick_tag[f_c])));
          end
        end
      end
`endif
`ifdef F_LQ_PREMATCH_PAIR
      // Composed with MEM_RS and the wrapper's translation mux: identical to
      // the CAM of the candidate tags those drive.
      for (genvar f_c = 0; f_c < NumCandidates; f_c++) begin : gen_f_pair
        for (genvar f_entry = 0; f_entry < DEPTH; f_entry++) begin : gen_f_entry
          always_comb begin
            assert (candidate_match[f_c][f_entry] == (lq_valid[f_entry] &&
                !lq_addr_valid[f_entry] && (lq_rob_tag[f_entry] ==
                i_pre_issue_rob_tags[f_c*ReorderBufferTagWidth +: ReorderBufferTagWidth])));
          end
        end
      end
`endif
`endif
    end else begin : gen_tag_compare
      for (genvar candidate = 0; candidate < NumCandidates; candidate++) begin : gen_candidate
        for (genvar entry = 0; entry < DEPTH; entry++) begin : gen_entry
          assign candidate_match[candidate][entry] = lq_valid[entry] &&
              !lq_addr_valid[entry] &&
              (lq_rob_tag[entry] == i_pre_issue_rob_tags[
                  candidate*ReorderBufferTagWidth +: ReorderBufferTagWidth]);
        end
      end
    end
    for (genvar candidate = 0; candidate < NumCandidates; candidate++) begin : gen_candidate_q
      always_ff @(posedge i_clk) begin
        if (!i_rst_n || i_flush_all) candidate_match_q[candidate] <= '0;
        else candidate_match_q[candidate] <= candidate_match[candidate];
      end
    end
    always_ff @(posedge i_clk) begin
      select_q <= i_pre_issue_sel;
    end
    // Select among registered candidates for timing. Reset and full flush
    // zero every candidate, so the selector is then irrelevant.
    wire [DEPTH-1:0] select_tree[2*NumCandidates];
    for (genvar leaf = 0; leaf < NumCandidates; leaf++) begin : gen_leaf
      assign select_tree[NumCandidates+leaf] = candidate_match_q[leaf];
    end
    for (genvar level = 0; level < PREISSUE_SEL_WIDTH; level++) begin : gen_level
      for (genvar node = (1 << level); node < (2 << level); node++) begin : gen_node
        assign select_tree[node] = select_q[PREISSUE_SEL_WIDTH-1-level] ?
            select_tree[2*node+1] : select_tree[2*node];
      end
    end
    assign addr_update_pre_match_tags_q = select_tree[1];
`ifndef SYNTHESIS
    always @(posedge i_clk) begin
      if (i_rst_n && i_pre_issue_needs_lq) begin
        assert (i_pre_issue_rob_tag ==
                i_pre_issue_rob_tags[i_pre_issue_sel*ReorderBufferTagWidth +:
                                    ReorderBufferTagWidth]);
      end
    end
`endif
  end else begin : gen_pre_match_direct
    always_ff @(posedge i_clk) begin
      if (!i_rst_n || i_flush_all) addr_update_pre_match_tags_q <= '0;
      else addr_update_pre_match_tags_q <= addr_update_pre_match;
    end
  end
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) addr_update_pre_issue_valid_q <= 1'b0;
    else addr_update_pre_issue_valid_q <= i_pre_issue_needs_lq;
  end
  assign addr_update_pre_match_q = addr_update_pre_match_tags_q &
      {DEPTH{addr_update_pre_issue_valid_q}};

`ifdef FORMAL
`ifndef F_LQ_RAM_PAYLOAD_PROOF
  // Compare against an unsplit qualified match for arbitrary tag, valid,
  // reset, and full-flush inputs, including illegal issue sequences.
  logic [DEPTH-1:0] f_pre_match_unsplit_q;
  logic f_pre_match_initialized = 1'b0;
`ifdef F_LQ_PREMATCH_COFACTORS
  logic [ReorderBufferTagWidth-1:0] f_selected_tag;
  logic [DEPTH-1:0] f_pre_match_direct;
  if (PREISSUE_READY_PICK) begin : gen_f_selected_pick
    assign f_selected_tag = f_pick_tag[i_pre_issue_sel];
  end else begin : gen_f_selected_tag
    assign f_selected_tag =
        i_pre_issue_rob_tags[i_pre_issue_sel*ReorderBufferTagWidth +: ReorderBufferTagWidth];
  end
  for (genvar f_entry = 0; f_entry < DEPTH; f_entry++) begin : gen_f_pre_match
    assign f_pre_match_direct[f_entry] = lq_valid[f_entry] && !lq_addr_valid[f_entry] &&
        (lq_rob_tag[f_entry] == f_selected_tag);
  end
`else
  wire [DEPTH-1:0] f_pre_match_direct = addr_update_pre_match;
`endif
  always @(posedge i_clk) begin
    f_pre_match_initialized <= 1'b1;
    if (!i_rst_n || i_flush_all) f_pre_match_unsplit_q <= '0;
    else f_pre_match_unsplit_q <= f_pre_match_direct & {DEPTH{i_pre_issue_needs_lq}};
    if (f_pre_match_initialized) assert (addr_update_pre_match_q == f_pre_match_unsplit_q);
  end
`endif
`endif  // F_LQ_RAM_PAYLOAD_PROOF

  // Register ROB-head matching for timing. Head priority prevents starvation
  // behind a staged load waiting on a younger store (load queue README,
  // "ROB-head priority"). A new head gains priority one cycle later. A stale
  // match can name only a freed or flushed entry, masked by lq_valid, because
  // a load frees its LQ entry before retiring. sq_check_entry_issueable checks
  // the live ROB head for MMIO, LR, and AMO.
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

  // Qualify the registered address pre-match with current issue valid.
  logic [DEPTH-1:0] entry_addr_valid_now;
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      entry_addr_valid_now[i] = lq_addr_valid[i] ||
                                (addr_update_pre_match_q[i] && i_addr_update.valid);
    end
  end

  // ===========================================================================
  // Issue selection (lq_issue_selector.sv). issue_cdb_idx is the read
  // address of the lq_data LUTRAM, which lives in this module.
  // ===========================================================================
  logic [DEPTH-1:0] merged_scan_onehot;
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
      .o_merged_scan_onehot(merged_scan_onehot),
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
  // Describe the entry matching ROB head. Perf counters apply
  // head_wait_mem_load && !o_mem_outstanding.
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

  // The head is blocked on SQ disambiguation when it is staged and the SQ
  // has unresolved older stores. This follows registered sq_check state.
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
  // blocker is not an SQ disambig.  Covers bus-busy stalls, pre-sq_check
  // staging cycles, the cached-region commit interlock, and drop-response
  // edge cases.
  assign o_head_load_bus_blocked  = head_entry_found && head_entry_addr_valid &&
                                    !head_entry_data_valid && !head_sq_disambig_hit;
  assign o_head_load_cdb_wait = head_entry_found && head_entry_data_valid;
  // "post-LQ" means the head's LQ entry has freed but the ROB still waits
  // for completion through cdb_stage, the MEM adapter, and CDB arbitration.
  assign o_head_load_post_lq = !head_entry_found;

  // -------------------------------------------------------------------------
  // Bus-blocked sub-bucket classification
  // -------------------------------------------------------------------------
  // Priority-ordered, so the three terms partition head_entry_bb_base:
  //   1. bus_busy: i_mem_bus_busy
  //   2. sq_wait:  entry is currently staged in sq_check but !sq_check_phase2
  //                (sq_check_phase2 takes a cycle to arm after the SQ sees
  //                the staged request).
  //   3. staging:  everything else (one-cycle addr_valid -> sq_check_capture
  //                delay, drop_mem_response_pending, and so on)
  // A launched plain load owes a response until its data is valid (checked in
  // simulation below), so the counters' !o_mem_outstanding gate already
  // excludes a launched head load. Every AMO still in the LQ is younger than
  // a load at the ROB head and cannot hold it up.

  logic head_entry_bb_base;
  assign head_entry_bb_base = head_entry_found && head_entry_addr_valid &&
                              !head_entry_data_valid && !head_sq_disambig_hit;

  logic head_entry_in_sq_wait;
  assign head_entry_in_sq_wait = sq_check_pending &&
                                 (sq_check_idx == head_entry_idx) &&
                                 !sq_check_phase2;

  assign o_head_load_bb_bus_busy = head_entry_bb_base && i_mem_bus_busy;
  assign o_head_load_bb_sq_wait = head_entry_bb_base && !i_mem_bus_busy && head_entry_in_sq_wait;
  assign o_head_load_bb_staging = head_entry_bb_base && !i_mem_bus_busy && !head_entry_in_sq_wait;

  // Staging sub-decomposition (priority-ordered, mutually exclusive; the three
  // terms partition o_head_load_bb_staging exactly):
  //   other_in_staging: the single sq_check staging register is occupied by
  //                     a different load (the serialization cost of one
  //                     staging pipe);
  //   launch_gated:     the head load is staged with phase2 armed and has not
  //                     completed: the cycle it launches, hits the L0 or
  //                     forwards, and any cycle its launch is gated
  //                     (drop-response window, sq_can_issue qualifiers,
  //                     other launch gates);
  //   capture_gap:      staging free: the head load has not been captured
  //                     yet (selector / capture-recycle bubble).
  logic head_bbs_base;
  assign head_bbs_base = o_head_load_bb_staging;
  assign o_head_load_bbs_other_in_staging = head_bbs_base && sq_check_pending &&
                                            (sq_check_idx != head_entry_idx);
  assign o_head_load_bbs_launch_gated = head_bbs_base && sq_check_pending &&
                                        (sq_check_idx == head_entry_idx) && sq_check_phase2;
  assign o_head_load_bbs_capture_gap = head_bbs_base && !sq_check_pending;

  // Select the Phase B tag alongside the index for timing.
  logic [ReorderBufferTagWidth-1:0] issue_mem_rob_tag;

  logic [IdxWidth-1:0] stored_issue_idx;
  logic [ReorderBufferTagWidth-1:0] stored_issue_rob_tag;
  logic [ReorderBufferTagWidth-1:0] update_issue_rob_tag;
  logic [DEPTH-1:0] issue_mem_onehot;
  logic update_scan_older_than_stored_scan;
  logic update_scan_issueable;
  logic update_scan_wins;

  // An arriving MMIO address may stage before ROB head. sq_check_is_mmio_q
  // blocks its SQ probe and memory issue until it reaches head.
  assign update_scan_issueable = update_scan_found;
  assign update_scan_older_than_stored_scan =
      update_scan_issueable && (!stored_scan_found || (update_scan_pos < stored_scan_pos));
  assign update_scan_wins = i_addr_update.valid && update_scan_older_than_stored_scan;

  // Phase B: prefer an eligible ROB-head load, then ring order. Select stored
  // and arriving-address candidates separately for address RAM timing.
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
      // Preserve the selector's one-hot identity for timing.
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
      (!sq_check_is_mmio_q || (sq_check_rob_tag_q == i_rob_head_tag)) &&
      !coh_launch_hold_q && !(coh_staged_amo_lr && (i_coh_admit_pulse || !coh_hold_valid_q));

  // A departing staged load permits same-cycle capture of its replacement.
  // Keep this predicate aligned with sq_check_stage_clears below.
  logic sq_check_will_clear;
  logic cache_hit_fast_path;
  logic sq_do_forward;
  logic launch_mem_issue;
  logic older_amo_write_pending;
  logic sq_check_misaligned;
  logic misalign_bypass_fire;
  logic sq_check_is_cached_region;
  logic sq_commit_check_block;
  // PMA faults use the staged fault path and block hits, forwarding, and
  // launches regardless of i_trap_misaligned_accesses. Access faults outrank
  // misalignment (either priority is allowed by the privileged spec). AMOs
  // use store/AMO causes. The atomic map excludes device addresses for LR/AMO.
  logic sq_check_pma_fault;
  // A parked translation fault outranks PMA and alignment checks: the saved
  // address is a VA for xtval. Use the saved kind to select its cause.
  logic sq_check_parked_fault;
  assign sq_check_parked_fault = sq_check_entry_valid && sq_check_entry_issueable &&
      (riscv_pkg::data_fault_kind_e'(sq_check_fault_kind_q) != riscv_pkg::DFAULT_NONE);
  logic sq_check_pma_ok;
  assign sq_check_pma_ok = (sq_check_is_amo_q || sq_check_is_lr_q) ? riscv_pkg::pma_atomic_ok(
      sq_check_addr_q
  ) : riscv_pkg::pma_data_ok(
      sq_check_addr_q
  );
  assign sq_check_pma_fault = !sq_check_parked_fault &&
      sq_check_entry_valid && sq_check_entry_issueable && !sq_check_pma_ok;
  assign sq_check_misaligned = sq_check_parked_fault || sq_check_pma_fault ||
      (i_trap_misaligned_accesses &&
       sq_check_entry_valid && sq_check_entry_issueable &&
       is_load_misaligned(
      sq_check_size_q, sq_check_addr_q
  ));
  assign sq_check_is_cached_region = is_cached_addr(sq_check_addr_q);
  assign sq_commit_check_block =
      i_sq_commit_pending && sq_check_entry_valid && sq_check_is_cached_region;
  // older_amo_write_pending releases the staged entry: a load fenced behind
  // an older AMO that has not written would otherwise hold staging until the
  // AMO's write completes.  Released entries stay valid and unissued and
  // re-enter the scan after the AMO completes; once the AMO itself is
  // eligible it is at the ROB head, so head priority selects it.
  assign sq_check_will_clear = sq_check_pending &&
      (!sq_check_entry_valid || cache_hit_fast_path || sq_do_forward ||
       launch_mem_issue || misalign_bypass_fire || older_amo_write_pending);

  // Stored MMIO at ROB head is eligible in both scans; head priority wins.
  // The router enforces committed-store drain before device acceptance.
  //
  // Apply the SQ-commit interlock after capture for timing. Full flush needs
  // no capture veto: it clears every LQ valid and SQ-check control bit on the
  // edge, hiding any payload write. Partial flush must veto capture because
  // it preserves older entries and their staged controls.
  logic sq_check_gate_early;
  // Preparing an address has no externally visible effect. SQ probe/capture,
  // L0 hits and memory handoff retain their independent bus-ownership gates.
  assign sq_check_gate_early = !drop_mem_response_pending &&
      (PREPARE_LOAD_WHILE_BUSY || !i_mem_bus_busy) && !i_flush_en;

  assign sq_check_capture = (!sq_check_pending || sq_check_will_clear) &&
      issue_mem_found && sq_check_gate_early;

  // Compare the staged tag with each entry before selection for timing.
  // issue_mem_onehot selects exactly one age result, or zero when no
  // candidate exists.
  logic [DEPTH-1:0] staged_younger_than_entry;
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      staged_younger_than_entry[i] = is_younger(sq_check_rob_tag_q, lq_rob_tag[i], i_rob_head_tag);
    end
  end
  logic staged_younger_than_candidate;
  assign staged_younger_than_candidate = |(staged_younger_than_entry & issue_mem_onehot);

  // Precompute replacement with and without an address update for timing.
  // The first entry in the union is the earlier scan winner. Preserve head
  // priority, then select with address valid. A zero winner means no candidate;
  // sq_check_entry_valid equals sq_check_pending.
  logic replace_stored_head, replace_update_head, replace_stored_scan, replace_merged_scan;
  logic replace_without_update, replace_with_update;
  assign replace_stored_head = |(staged_younger_than_entry & head_mem_stored_onehot);
  assign replace_update_head = |(staged_younger_than_entry & head_mem_update_onehot);
  assign replace_stored_scan = |(staged_younger_than_entry & stored_scan_onehot);
  assign replace_merged_scan = |(staged_younger_than_entry & merged_scan_onehot);
  assign replace_without_update = head_mem_stored_found ? replace_stored_head : replace_stored_scan;
  assign replace_with_update = head_mem_stored_found ? replace_stored_head :
      (head_mem_update_found ? replace_update_head : replace_merged_scan);
  assign sq_check_replace = sq_check_pending && sq_check_gate_early &&
      (i_addr_update.valid ? replace_with_update : replace_without_update);
`ifdef F_LQ_MERGED_REPLACE_LOCAL_PROOF
  always_comb
    assert (sq_check_replace ==
      (sq_check_pending && issue_mem_found && sq_check_gate_early &&
       (!sq_check_entry_valid || staged_younger_than_candidate)));
`endif

  // Drive registered check payloads even when invalid; the SQ's capture enable
  // qualifies use. All address copies are identical and canonical_paddr keeps
  // only physical bits [31:0]. This is safe because faulting loads never probe.
  // SQ addresses remain full width, so out-of-map stores cannot match.
  assign o_sq_check_addr_b = riscv_pkg::canonical_paddr(sq_check_addr_q_b);
  assign o_sq_check_addr_c = riscv_pkg::canonical_paddr(sq_check_addr_q_c);
  assign o_sq_check_addr_d = riscv_pkg::canonical_paddr(sq_check_addr_q_d);

  always_comb begin
    o_sq_check_valid   = 1'b0;
    o_sq_check_addr    = riscv_pkg::canonical_paddr(sq_check_addr_q);  // see the _b/_c/_d note
    o_sq_check_rob_tag = sq_check_rob_tag_q;
    o_sq_check_size    = sq_check_size_q;

    if (!i_flush_all && !i_flush_en && !drop_mem_response_pending &&
        !i_mem_bus_busy && !sq_commit_check_block && sq_check_entry_issueable &&
        !sq_check_misaligned &&
        !(sq_check_no_older_store_q || i_sq_empty)) begin
      o_sq_check_valid = 1'b1;
    end

    // Capture omits flush and commit-block gates for timing. Consumers reapply
    // the commit interlock, and enabled probes refresh the result every cycle
    // while blocked.
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
  // A staged load may read memory (or hit the L0) once phase 2 of its SQ
  // check shows no older store in the SQ, or every older store address
  // known and none overlapping.  If an older store overlaps, the load waits
  // and probes again, unless sq_do_forward lets it take its data from the
  // newest overlapping store (which requires that store to cover the whole
  // load).

  logic sq_can_issue;
  logic stage_mem_issue;
  logic [IdxWidth-1:0] launch_mem_issue_idx;
  logic [XLEN-1:0] launch_mem_issue_addr;
  riscv_pkg::mem_size_e launch_mem_issue_size;
  logic [XLEN-1:0] stage_mem_issue_addr;
  riscv_pkg::mem_size_e stage_mem_issue_size;
  logic sq_no_older_store;
  logic sq_commit_interlock;
  assign sq_no_older_store = sq_check_no_older_store_q || i_sq_empty;
  assign sq_commit_interlock = sq_commit_check_block && sq_check_phase2;

  // SQ disambiguation cannot see AMO writes held in the LQ. Select the staged
  // entry's registered older-AMO block bit. Program-order allocation prevents
  // an older AMO from appearing after the entry stages.
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
  // Forwarding also requires all older addresses known: an unresolved store
  // could overlap the load and be newer than the selected store, making its
  // data stale. Address-known and forwarding results come from the same scan.
  assign sq_do_forward = ENABLE_SQ_FORWARD_FAST_PATH
      && sq_check_phase2 && sq_check_entry_issueable && !sq_no_older_store &&
      !sq_check_misaligned &&
      !sq_commit_interlock &&
      !older_amo_write_pending &&
      i_sq_all_older_addrs_known &&
      i_sq_forward.can_forward
      && !sq_check_is_mmio_q && !sq_check_is_lr_q && !sq_check_is_amo_q;


  assign flush_all_entries = i_flush_en && !i_early_recovery_flush &&
      (i_flush_tag == (i_rob_head_tag - ReorderBufferTagWidth'(1)));

`ifdef F_LQ_TAG_ORDER_PROOF
  logic [ReorderBufferTagWidth:0] f_entry_age, f_flush_age;
  assign f_entry_age = {1'b0, i_pre_issue_rob_tag} - {1'b0, i_rob_head_tag};
  assign f_flush_age = {1'b0, i_flush_tag} - {1'b0, i_rob_head_tag};
  always_comb begin
    assert (is_younger(
        i_pre_issue_rob_tag, i_flush_tag, i_rob_head_tag
    ) == (f_entry_age > f_flush_age));
    assert ((i_flush_tag == (i_rob_head_tag - ReorderBufferTagWidth'(1))) ==
            (i_rob_head_tag == (i_flush_tag + ReorderBufferTagWidth'(1))));
  end
`endif

  // A killed load's response must drain before its tracker is reused, even
  // though its LQ entry may be reused sooner. Full-flush responses cannot
  // complete loads or fill L0. Partial flush drains the answering killed slot
  // immediately and marks other killed slots for later drain.
  //
  // Never age-check a slot already marked cs_drop: its index may name a new
  // load. Clearing that load's lq_issued could launch it twice and let its
  // second response complete a later occupant. The stale slot's saved tag no
  // longer belongs to the live ROB window.
  logic [CachedSlots-1:0] cs_flushed;
  always_comb begin
    for (int sl = 0; sl < int'(CachedSlots); sl++) begin
      cs_flushed[sl] = i_flush_en && cs_valid[sl] && !cs_drop[sl] && lq_valid[cs_idx[sl]] &&
          (flush_all_entries || is_younger(cs_rob_tag[sl], i_flush_tag, i_rob_head_tag));
    end
  end
  // Check fast-tier flush age from its own snapshot; a concurrent cached
  // response selects different issued_* fields.
  logic fast_entry_flushed;
  assign fast_entry_flushed = i_flush_en && mem_outstanding && lq_valid[fast_idx] &&
      (flush_all_entries || is_younger(
      fast_rob_tag, i_flush_tag, i_rob_head_tag
  ));
  // Use the responding tracker for accept/drop; check other cached slots
  // separately.
  assign issued_entry_flushed = resp_from_slot ? cs_flushed[resp_slot] : fast_entry_flushed;
  assign full_flush_response_drain = i_flush_all && i_mem_read_valid && resp_outstanding;
  assign accept_mem_response = i_mem_read_valid && resp_outstanding &&
                               !i_flush_all && !resp_drop &&
                               !issued_entry_flushed && lq_valid[issued_idx];
  assign drop_mem_response_now = i_mem_read_valid &&
                                 (full_flush_response_drain ||
                                  resp_drop || issued_entry_flushed ||
                                  (resp_outstanding && !lq_valid[issued_idx]));

  // COMPUTE has released the response slot. Check the retained LQ index for
  // recovery before writing; a live entry cannot be reallocated.
  assign amo_compute_owner_killed = !lq_valid[amo_entry_idx] ||
      (i_flush_en && (flush_all_entries || is_younger(
      lq_rob_tag[amo_entry_idx], i_flush_tag, i_rob_head_tag
  )));
  assign amo_compute_commit = (amo_state == AMO_COMPUTE) && i_rst_n &&
      !i_flush_all && !amo_compute_owner_killed;

  logic fast_resp_now;
  assign fast_resp_now = i_mem_read_valid && !i_mem_read_is_cached;

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
      .DEPTH(L0_CACHE_DEPTH),
      .XLEN (XLEN)
  ) u_l0_cache (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // sq_can_issue qualifies hits, so stale lookup addresses are harmless.
      .i_lookup_addr(sq_check_addr_q),
      .o_lookup_hit (cache_lookup_hit),
      .o_lookup_data(cache_lookup_data),

      // Fill: on memory response
      .i_fill_valid(cache_fill_valid),
      .i_fill_addr (cache_fill_addr),
      .i_fill_data (cache_fill_data),

      // SQ launch and AMO completion use separate invalidate ports for timing.
      // AMO serialization makes them exclusive; the cache does not require it.
      .i_invalidate_valid (i_cache_invalidate_valid),
      .i_invalidate_addr  (i_cache_invalidate_addr),
      .i_invalidate2_valid(amo_cache_inv),
      .i_invalidate2_addr (amo_write_addr_q),

      // SQ writes suppress same-cycle hits. AMO completion needs only sequential
      // invalidation because head serialization blocks younger loads.
      .i_lookup_invalidate_valid(i_cache_invalidate_valid),
      .i_lookup_invalidate_addr (i_cache_invalidate_addr),

      // L0 survives pipeline flushes. Stores and DMA invalidate stale lines,
      // and response filtering prevents stale fills.
      .i_flush_all(1'b0),

      // Line invalidate: a DMA write to the line (lq_coherence_port).
      .i_invalidate_line_valid(i_coh_inval_valid),
      .i_invalidate_line_addr (i_coh_inval_addr)
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

  // Use an L0 hit after SQ disambiguation for ordinary loads. Block even hits
  // while the bus is busy: a store or AMO may hold it a cycle before its L0
  // invalidation is visible. load_unit extracts sub-dword results.
  assign cache_hit_fast_path = ENABLE_L0_FAST_PATH
      && !i_flush_all && !i_flush_en
      && !i_mem_bus_busy
      && sq_can_issue
      && cache_lookup_hit
      && !sq_check_is_mmio_q
      && !sq_check_is_lr_q
      && !sq_check_is_amo_q;

  assign stage_mem_issue_addr = sq_check_addr_q;

  assign stage_mem_issue = !i_flush_en && !i_flush_all && sq_can_issue && !cache_hit_fast_path;
  assign stage_mem_issue_size = sq_check_size_q;

  // BRAM's fixed response pipeline permits a launch each cycle without a
  // !mem_outstanding gate. Bus-busy prevents collisions with writes or the
  // router's single pending request. MMIO first enters that pending register,
  // which blocks later handoffs through acceptance.
  //
  // Launch uses the staged payload directly; stalls keep sq_check_pending
  // armed until launch. Both flush gates are required: a full flush alone
  // can squash a head MMIO load, whose device read cannot be undone.
  //
  // cached_launch_hold_q blocks all launches when cached slots are full or
  // for one cycle after a cached response loses the port to a fast beat. This
  // prevents fast loads from starving cached responses. AMOs launch at head
  // and fence younger loads until write completion.
  //
  // On full flush, a router-pending request is canceled without a response.
  // Release its cached slot if applicable. Accepted fast and cached requests
  // retain trackers until their responses drain.
  assign launch_mem_issue = !i_flush_en && !i_flush_all && !i_mem_bus_busy && stage_mem_issue &&
      !cached_launch_hold_q;
  assign launch_mem_issue_idx = sq_check_idx;
  assign launch_mem_issue_addr = stage_mem_issue_addr;
  assign launch_mem_issue_size = stage_mem_issue_size;

  // Decode the staged address for slot allocation, snapshots, and DMA
  // observation. This decode does not gate launch.
  logic launching_is_cached;
  assign launching_is_cached = is_cached_addr(launch_mem_issue_addr);

  // DMA coherence: the memory observation of the staged load, for the
  // validation table. A cached L0 hit, a store-queue forward (the load binds
  // to a store's value, which a DMA write to the line may precede in
  // coherence order) or a cached launch, never an AMO (its window is
  // protected by admission instead). The forward is reported even in a
  // partial flush cycle: a load older than the flush point keeps its
  // forwarded value and must stay validated, while the port drops the
  // observation of a load the same-cycle flush kills.
  assign o_coh_observe_valid = (cache_hit_fast_path || sq_do_forward ||
                                (o_mem_read_en && launching_is_cached && !sq_check_is_amo_q)) &&
      is_cached_addr(
      sq_check_addr_q
  );
  assign o_coh_observe_rob_tag = sq_check_rob_tag_q;
  assign o_coh_observe_addr = sq_check_addr_q;

  // Cached slot allocation: the lowest free slot (a slot freed by this
  // cycle's response is not reused until next cycle).
  logic [CachedSlotBits-1:0] cs_alloc_idx;
  logic [CachedSlots-1:0] cs_valid_next;
  // The most recent launch, the only request the router can still be
  // holding unaccepted (its pending bit blocks every later launch through
  // i_mem_bus_busy). A full flush cancels such a request inside the router,
  // so its cached slot is freed outright rather than left waiting for a
  // response that will never come.
  logic last_launch_cached_q;
  logic [CachedSlotBits-1:0] last_launch_slot_q;
  logic [CachedSlots-1:0] cs_router_canceled;
  always_ff @(posedge i_clk) begin
    if (o_mem_read_en) begin
      last_launch_cached_q <= launching_is_cached;
      last_launch_slot_q   <= cs_alloc_idx;
    end
  end
  assign cs_router_canceled = (i_flush_all && i_mem_request_pending && last_launch_cached_q) ?
      (CachedSlots'(1) << last_launch_slot_q) : '0;
  always_comb begin
    cs_alloc_idx = '0;
    for (int sl = int'(CachedSlots) - 1; sl >= 0; sl--) begin
      if (!cs_valid[sl]) cs_alloc_idx = CachedSlotBits'(sl);
    end
    cs_valid_next = cs_valid;
    if (i_mem_read_valid && i_mem_read_is_cached) cs_valid_next[resp_slot] = 1'b0;
    if (o_mem_read_en && launching_is_cached) cs_valid_next[cs_alloc_idx] = 1'b1;
    if (i_flush_all) begin
      cs_valid_next = cs_valid & ~(resp_from_slot ? (CachedSlots'(1) << resp_slot) : '0) &
          ~cs_router_canceled;
    end
  end

  // Precompute slot occupancy with and without a launch, then select for timing.
  logic [CachedSlots-1:0] cs_after_response, cs_if_launch;
  logic [CachedSlots-1:0] cs_if_flush;
  (* keep = "true" *) logic cached_hold_if_launch, cached_hold_if_idle;
  logic cached_launch_hold_next;
  assign cs_after_response = cs_valid &
      ~((i_mem_read_valid && i_mem_read_is_cached) ? (CachedSlots'(1) << resp_slot) : '0);
  assign cs_if_launch = cs_after_response | (CachedSlots'(1) << cs_alloc_idx);
  assign cs_if_flush = cs_valid &
      ~(resp_from_slot ? (CachedSlots'(1) << resp_slot) : '0) & ~cs_router_canceled;
  assign cached_hold_if_launch = (&cs_if_launch) || i_cached_resp_held;
  assign cached_hold_if_idle = (&cs_after_response) || i_cached_resp_held;
  assign cached_launch_hold_next = i_flush_all ? ((&cs_if_flush) || i_cached_resp_held) :
      ((o_mem_read_en && launching_is_cached) ? cached_hold_if_launch : cached_hold_if_idle);
`ifdef F_LQ_CACHED_HOLD_PROOF
  always_comb assert (cached_launch_hold_next == ((&cs_valid_next) || i_cached_resp_held));
`endif

  // Memory issue port: driven straight from the launch terms (no second-deep
  // staging register, see above).
  always_comb begin
    o_mem_read_en   = launch_mem_issue;
    o_mem_read_addr = launch_mem_issue_addr;
    o_mem_read_size = launch_mem_issue_size;
    o_mem_read_id   = cs_alloc_idx;
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
  // flags/address are shared with u_cache_load_unit: same staged load, and
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

  // A payload needs to equal the architectural write only when its port fires.
  // Keep response acceptance and SQ age/issue guards on the write enables,
  // rather than using them to zero every address and data bit while idle.
  logic ram_cache_payload_select;
  logic [FLEN-1:0] ram_sq_payload;
  // sq_head_amo_clear implies sq_check_is_amo_q, which excludes both
  // cache and forward writes. Its ROB-head comparison is not a data select.
  assign ram_cache_payload_select = ENABLE_L0_FAST_PATH && !i_flush_all &&
      !i_flush_en && !i_mem_bus_busy && cache_lookup_hit &&
      (sq_no_older_store || (i_sq_all_older_addrs_known && !i_sq_forward.match));
  assign ram_sq_payload = ram_cache_payload_select ?
      ((sq_check_size_q == riscv_pkg::MEM_SIZE_DOUBLE) ?
       cache_lookup_data : FLEN'(lu_cache_out)) :
      ((sq_check_size_q == riscv_pkg::MEM_SIZE_DOUBLE) ?
       i_sq_forward.data : FLEN'(lu_fwd_out));

  always_comb begin
    lq_data_we[0] = i_rst_n && !i_flush_all && accept_mem_response && !issued_is_amo;
    lq_data_wr_addr[0] = issued_idx;
    lq_data_wd[0] = (riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_DOUBLE) ?
        i_mem_read_data : FLEN'(lu_data_out);

    lq_data_we[1] = i_rst_n && !i_flush_all &&
        (cache_hit_fast_path || sq_do_forward ||
         (amo_state == AMO_WRITE_ACTIVE && i_amo_mem_write_done));
    lq_data_wr_addr[1] = (cache_hit_fast_path || sq_do_forward) ? sq_check_idx : amo_entry_idx;
    lq_data_wd[1] = (cache_hit_fast_path || sq_do_forward) ? ram_sq_payload : FLEN'(amo_old_value);
  end

`ifdef F_LQ_RAM_PAYLOAD_PROOF
  logic [1:0] f_ram_we;
  logic [1:0][IdxWidth-1:0] f_ram_addr;
  logic [1:0][FLEN-1:0] f_ram_data;
  always_comb begin
    f_ram_we   = '0;
    f_ram_addr = '0;
    f_ram_data = '0;

    // ---------------------------------------------------------------
    // Port 0: memory response, independent of simultaneous local completions.
    // ---------------------------------------------------------------
    if (i_rst_n && !i_flush_all && accept_mem_response) begin
      f_ram_addr[0] = issued_idx;
      if (issued_is_amo) begin
        // AMO read: don't write data yet (port 1 handles after AMO write)
      end else if (riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_DOUBLE) begin
        // FLD/RV64 LD: the full aligned beat in one write
        f_ram_we[0]   = 1'b1;
        f_ram_data[0] = i_mem_read_data;
      end else begin
        // LR / FLW / INT: extracted result (FLW's word arm is its addressed
        // raw word), zero-extended into FLEN
        f_ram_we[0]   = 1'b1;
        f_ram_data[0] = FLEN'(lu_data_out);
      end
    end

    // ---------------------------------------------------------------
    // Port 1: L0 hit, SQ forward, or AMO write completion.
    // AMO serialization blocks younger hits and forwards until write completion.
    // Forwarding requires a matching store; a hit requires either no older store
    // or no match. Thus the three sources cannot collide.
    // ---------------------------------------------------------------
    if (i_rst_n && !i_flush_all) begin
      if (cache_hit_fast_path) begin
        f_ram_we[1] = 1'b1;
        f_ram_addr[1] = sq_check_idx;
        // FLD takes the full cached dword line; FLW/INT extract from it
        // (FLW's word arm is its addressed raw word).
        f_ram_data[1]      = (sq_check_size_q == riscv_pkg::MEM_SIZE_DOUBLE)
            ? cache_lookup_data : FLEN'(lu_cache_out);
      end else if (sq_do_forward) begin
        f_ram_we[1] = 1'b1;
        f_ram_addr[1] = sq_check_idx;
        // FLD takes the forwarded dword image raw; FLW/INT extract their
        // addressed word/half/byte from the image beat.
        f_ram_data[1]      = (sq_check_size_q == riscv_pkg::MEM_SIZE_DOUBLE)
            ? i_sq_forward.data : FLEN'(lu_fwd_out);
      end else if (amo_state == AMO_WRITE_ACTIVE && i_amo_mem_write_done) begin
        f_ram_we[1]   = 1'b1;
        f_ram_addr[1] = amo_entry_idx;
        f_ram_data[1] = FLEN'(amo_old_value);
      end
    end
  end

  always_comb begin
    assert (!cache_hit_fast_path || !sq_head_amo_clear);
    cover (lq_data_we[0]);
    cover (lq_data_we[1] && cache_hit_fast_path);
    cover (lq_data_we[1] && !cache_hit_fast_path && sq_do_forward);
    cover (lq_data_we[1] && !cache_hit_fast_path && !sq_do_forward);
    for (int port_idx = 0; port_idx < 2; port_idx++) begin
      assert (lq_data_we[port_idx] == f_ram_we[port_idx]);
      assert (!lq_data_we[port_idx] ||
              (lq_data_wr_addr[port_idx] == f_ram_addr[port_idx] &&
               lq_data_wd[port_idx] == f_ram_data[port_idx]));
    end
  end
`endif

  // An ordinary response coincident with the partial flush that kills its
  // load may still fill persistent L0: recovery does not change memory. Keep
  // age checks out of fill qualification for timing.
  //
  // Never fill on full flush or from a previously drop-marked response. MMIO,
  // LR, AMO, and cached responses invalidated by a store or DMA also cannot
  // fill. Use the launch-time issued_addr snapshot.
  assign cache_fill_response_valid = i_mem_read_valid && resp_outstanding &&
      !i_flush_all && !resp_drop && lq_valid[issued_idx];
  assign cache_fill_valid = cache_fill_response_valid
      && !issued_is_mmio && !issued_is_lr && !issued_is_amo
      && !(issued_is_cached &&
           (issued_cached_line_invalidated || issued_cached_line_invalidate_now));
  assign cache_fill_addr = issued_addr;
  assign cache_fill_data = i_mem_read_data;

  // L0 cache profile pulses (one cycle when the event fires)
  assign o_l0_hit = cache_hit_fast_path;
  assign o_l0_fill = cache_fill_valid;
  // Exposed for diagnostics: the wrapper partitions head wait cycles into
  // "load in flight" vs "load stuck on something else" with it.
  assign o_mem_outstanding = mem_outstanding || cs_any_q;

  // Capture AMO operands, address, and operation on response. Ordinary AMOs
  // spend one cycle in COMPUTE before writing. MIN/MAX captures .D and .W
  // unsigned relations and mode bits, then writes in the next cycle. Width
  // and signedness select from registered state.
  assign amo_minmax_selected_relation =
      amo_is_d_q ? amo_minmax_relation_d_q : amo_minmax_relation_w_q;
  assign amo_minmax_old_sign = amo_is_d_q ? amo_old_value[XLEN-1] : amo_old_value[31];
  assign amo_minmax_rs2_sign = amo_is_d_q ? amo_minmax_rs2_q[XLEN-1] : amo_minmax_rs2_q[31];

  // Signed values with different signs are ordered by the old operand's sign.
  // Otherwise unsigned ordering applies. For MAX, relation 00 alone is GT;
  // including the equality bit prevents !LT from selecting old on a tie.
  assign amo_minmax_select_old_active =
      (!amo_minmax_is_unsigned_q && (amo_minmax_old_sign != amo_minmax_rs2_sign)) ?
      (amo_minmax_old_sign ^ amo_minmax_is_max_q) :
      (amo_minmax_is_max_q ? ~|amo_minmax_selected_relation :
       amo_minmax_selected_relation[0]);

  always_comb begin
    amo_write_value = amo_write_data_q;
    if (amo_is_minmax_q) begin
      amo_write_value = amo_minmax_select_old_active ? amo_old_value : amo_minmax_rs2_q;
    end

    o_amo_mem_write_en        = 1'b0;
    o_amo_mem_write_addr      = '0;
    o_amo_mem_write_data      = '0;
    o_amo_mem_write_is_dword  = 1'b0;
    o_amo_mem_write_is_cached = 1'b0;

    if (amo_state == AMO_WRITE_ACTIVE) begin
      o_amo_mem_write_en = 1'b1;
      o_amo_mem_write_addr = amo_write_addr_q;
      // .W: word result replicated across the beat; the router's word-lane
      // strobes (from addr[2] + the is_dword flag) select the addressed half.
      // .D: the full doubleword with full-beat strobes.
      o_amo_mem_write_data = amo_is_d_q ? riscv_pkg::MemDataBits'(amo_write_value) :
          {(riscv_pkg::MemDataBits / 32) {amo_write_value[31:0]}};
      o_amo_mem_write_is_dword = amo_is_d_q;
      // Gated like the address: idle presents zero, active presents the
      // decode of the held address (the router qualifies every use with en).
      o_amo_mem_write_is_cached = amo_write_is_cached_q;
    end
  end

  // Drive load unit inputs from the entry awaiting response (memory path)
  always_comb begin
    // Use issued_* controls without response qualification for timing.
    // Consumers qualify extracted results with their write/capture enables.
    lu_is_byte     = (riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_BYTE);
    lu_is_half     = (riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_HALF);
    lu_is_unsigned = !issued_sign_ext;
    lu_addr        = issued_addr;
    lu_raw_data    = i_mem_read_data;
  end

  // ===========================================================================
  // CDB Broadcast Logic
  // ===========================================================================
  // Register the Phase A result before the MEM adapter for timing.

  // Qualify valid and capture enable, leaving invalid payloads unspecified.
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

  // The wrapper's cdb_kill and MEM adapter flush suppress full-flush results.
  // Omit that gate here for payload timing.
  always_comb begin
    o_fu_complete       = cdb_stage_data;
    o_fu_complete.valid = cdb_stage_valid && !i_flush_en && !cdb_stage_result_flushed;
  end
  assign o_fu_complete_staged = cdb_stage_valid;

  // ===========================================================================
  // Completion Fast-Path Bypass
  // ===========================================================================
  // Complete directly into an available cdb_stage when Phase A is idle.
  // Responses, hits, and forwards otherwise use the data-valid path; faults
  // wait in staging. Nonfaulting AMOs complete through data RAM after writing.
  // All load sizes, including LD, FLD, and LR.D, can bypass.
  logic resp_bypass_ok;
  logic resp_bypass_fire;
  logic cache_hit_bypass_fire;
  logic bypass_fire;
  logic [IdxWidth-1:0] bypass_idx;
  logic [ReorderBufferTagWidth-1:0] bypass_tag;
  logic [FLEN-1:0] bypass_value;
  logic [FLEN-1:0] resp_bypass_value;
  logic [FLEN-1:0] cache_hit_bypass_value;

  // A bypass cannot fire during a partial flush. Its response predicate
  // therefore does not need the age-dependent issued_entry_flushed term,
  // which itself implies i_flush_en. Full-flush, stale-response and live-tracker
  // checks remain in cache_fill_response_valid, exactly as in acceptance.
  assign resp_bypass_ok = cache_fill_response_valid && !issued_is_amo;

  assign resp_bypass_fire = cdb_stage_slot_available && !issue_cdb_fire &&
                            resp_bypass_ok && !i_flush_en;

`ifdef F_LQ_RESPONSE_BYPASS_PROOF
  always_comb begin
    p_response_bypass_flush_factoring :
    assert (resp_bypass_fire ==
        (cdb_stage_slot_available && !issue_cdb_fire && accept_mem_response &&
         !issued_is_amo && !i_flush_en));
  end
`endif

  assign misalign_bypass_fire = cdb_stage_slot_available && !issue_cdb_fire &&
                                !resp_bypass_fire && sq_check_misaligned && !i_flush_en;

  // Payload selects omit grant and flush terms implied by the capture enable.
  // A bypass capture requires an available stage, no Phase-A result, and no
  // partial flush. Full flush clears cdb_stage_valid on the capture edge, so
  // response data selection may omit it too. Outside capture, data is unused.
  // State transitions still use fully qualified fires.
  logic resp_bypass_data_sel;
  logic misalign_bypass_data_sel;
  assign resp_bypass_data_sel = i_mem_read_valid && resp_outstanding &&
      !resp_drop && lq_valid[issued_idx] && !issued_is_amo;
  assign misalign_bypass_data_sel = !resp_bypass_data_sel && sq_check_misaligned;

  // cache_hit_fast_path is already flush-gated at its own assign.
  assign cache_hit_bypass_fire = cdb_stage_slot_available && !issue_cdb_fire &&
                                 !resp_bypass_fire && !misalign_bypass_fire &&
                                 cache_hit_fast_path;

  // Forward directly into cdb_stage, including FLD's full beat. Forwarding
  // and an L0 hit are exclusive: forwarding needs an older store and a
  // forwardable match, while an L0 hit needs no older store or no match.
  // Partial flush disables bypass; surviving entries use the data-valid path.
  logic fwd_bypass_fire;
  assign fwd_bypass_fire = cdb_stage_slot_available && !issue_cdb_fire &&
                           !resp_bypass_fire && !misalign_bypass_fire &&
                           sq_do_forward && !i_flush_en;

  assign bypass_fire = resp_bypass_fire || misalign_bypass_fire || cache_hit_bypass_fire ||
                       fwd_bypass_fire;

  // Mirror issue_cdb_result formatting, but sourced from the response-side
  // signals (lu_data_out / lu_cache_out / image beat) instead of the LUTRAM.
  always_comb begin
    if (riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_DOUBLE) begin
      // LD / FLD / LR.D: preserve all 64 response bits, including FP payloads.
      resp_bypass_value = i_mem_read_data;
    end else if (issued_is_fp) begin
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
  // above): identical to the fire-based selects whenever a capture happens,
  // don't-care otherwise.
  assign bypass_idx = resp_bypass_data_sel ? issued_idx : sq_check_idx;
  assign bypass_tag = resp_bypass_data_sel ? issued_rob_tag : sq_check_rob_tag_q;
  // A faulting load (misaligned, outside the physical map, or with a parked
  // translation fault) raises an exception instead of producing a register
  // result, so its CDB value slot is free to carry the faulting address.
  // The ROB forwards this as the trap value (xtval) at trap entry.
  // sq_do_forward is fully qualified at its own assign and disjoint from
  // cache_hit_fast_path, so it distinguishes the two sq_check-sourced arms.
  assign bypass_value =
      misalign_bypass_data_sel ? {{(FLEN - XLEN) {1'b0}}, sq_check_addr_q} :
      resp_bypass_data_sel ? resp_bypass_value :
      sq_do_forward ? fwd_bypass_value :
      cache_hit_bypass_value;

  // Select response data last for timing. Preserve priority:
  // issue > fault/response > forward/cache.
  (* keep = "true" *) logic [FLEN-1:0] cdb_value_nonresponse;
  (* keep = "true" *) logic cdb_value_select_response;
  logic [FLEN-1:0] cdb_value_next;
  assign cdb_value_nonresponse = issue_cdb_found ? issue_cdb_result.value :
      misalign_bypass_data_sel ? {{(FLEN - XLEN) {1'b0}}, sq_check_addr_q} :
      sq_do_forward ? fwd_bypass_value : cache_hit_bypass_value;
  assign cdb_value_select_response = !issue_cdb_found &&
      !misalign_bypass_data_sel && resp_bypass_data_sel;
  assign cdb_value_next = cdb_value_select_response ? resp_bypass_value : cdb_value_nonresponse;

`ifdef F_LQ_RESPONSE_FINAL_PROOF
  always_comb begin
    p_response_final_mux_exact :
    assert (cdb_value_next == (issue_cdb_found ? issue_cdb_result.value : bypass_value));
  end
`endif

  // Free the entry when cdb_stage captures its result. Bypass frees it without
  // an intervening data_valid cycle.
  assign free_entry_en  = issue_cdb_fire || bypass_fire;
  assign free_entry_idx = issue_cdb_fire ? issue_cdb_idx : bypass_idx;

  // ===========================================================================
  // Allocation Search
  // ===========================================================================
  // Reuse holes by searching from tail_ptr. Rotate the free mask, merge the
  // first two free offsets in a balanced tree, then add them back to tail.
  logic [DEPTH-1:0] lq_free_mask;
  logic [DEPTH-1:0] lq_free_rotated;
  logic [IdxWidth-1:0] lq_first_free_offset;
  logic lq_first_free_found;

  assign lq_free_mask = ~lq_valid;

  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      lq_free_rotated[i] = lq_free_mask[(32'(i)+32'(tail_ptr[IdxWidth-1:0]))%DEPTH];
    end
  end

  // Heap layout: root [0], children of node n at [2*n+1]/[2*n+2], and padded
  // leaves at [AllocTreeLeaves-1 .. 2*AllocTreeLeaves-2]. A merge takes the
  // left subtree's first two entries when available, otherwise fills from the
  // right subtree. This preserves ascending tail-relative order exactly in
  // ceil(log2(DEPTH)) merge levels.
  localparam int unsigned AllocTreeLeaves = 1 << $clog2(DEPTH);
  localparam int unsigned AllocTreeNodes  = 2 * AllocTreeLeaves - 1;
  logic [AllocTreeNodes-1:0] lq_free_tree_any;
  logic [AllocTreeNodes-1:0] lq_free_tree_second_found;
  logic [      IdxWidth-1:0] lq_free_tree_first_idx    [AllocTreeNodes];
  logic [      IdxWidth-1:0] lq_free_tree_second_idx   [AllocTreeNodes];
  logic [      IdxWidth-1:0] lq_second_free_offset;
  logic                      lq_second_free_found;

  for (genvar leaf = 0; leaf < AllocTreeLeaves; leaf++) begin : gen_lq_free_leaf
    localparam int unsigned LeafNode = AllocTreeLeaves - 1 + leaf;
    if (leaf < DEPTH) begin : gen_real_leaf
      assign lq_free_tree_any[LeafNode] = lq_free_rotated[leaf];
      assign lq_free_tree_first_idx[LeafNode] = lq_free_rotated[leaf] ? IdxWidth'(leaf) : '0;
    end else begin : gen_padding_leaf
      assign lq_free_tree_any[LeafNode] = 1'b0;
      assign lq_free_tree_first_idx[LeafNode] = '0;
    end
    assign lq_free_tree_second_found[LeafNode] = 1'b0;
    assign lq_free_tree_second_idx[LeafNode]   = '0;
  end

  for (genvar node = 0; node < AllocTreeLeaves - 1; node++) begin : gen_lq_free_merge
    localparam int unsigned LeftNode  = 2 * node + 1;
    localparam int unsigned RightNode = 2 * node + 2;

    assign lq_free_tree_any[node] = lq_free_tree_any[LeftNode] || lq_free_tree_any[RightNode];
    assign lq_free_tree_first_idx[node] =
        lq_free_tree_any[LeftNode] ? lq_free_tree_first_idx[LeftNode] :
        lq_free_tree_first_idx[RightNode];
    assign lq_free_tree_second_found[node] =
        lq_free_tree_second_found[LeftNode] ||
        (lq_free_tree_any[LeftNode] && lq_free_tree_any[RightNode]) ||
        lq_free_tree_second_found[RightNode];
    assign lq_free_tree_second_idx[node] =
        lq_free_tree_second_found[LeftNode] ? lq_free_tree_second_idx[LeftNode] :
        lq_free_tree_any[LeftNode] ? lq_free_tree_first_idx[RightNode] :
        lq_free_tree_second_idx[RightNode];
  end

  assign lq_first_free_found   = lq_free_tree_any[0];
  assign lq_first_free_offset  = lq_free_tree_first_idx[0];
  assign lq_second_free_found  = lq_free_tree_second_found[0];
  assign lq_second_free_offset = lq_free_tree_second_idx[0];

`ifndef SYNTHESIS
  // Compare both tree outputs with a serial scan for any free-mask pattern.
  logic [IdxWidth-1:0] lq_first_free_offset_reference;
  logic [IdxWidth-1:0] lq_second_free_offset_reference;
  logic lq_first_free_found_reference;
  logic lq_second_free_found_reference;
  always_comb begin
    lq_first_free_offset_reference  = '0;
    lq_first_free_found_reference   = 1'b0;
    lq_second_free_offset_reference = '0;
    lq_second_free_found_reference  = 1'b0;
    for (int i = 0; i < DEPTH; i++) begin
      if (lq_free_rotated[i]) begin
        if (!lq_first_free_found_reference) begin
          lq_first_free_offset_reference = IdxWidth'(i);
          lq_first_free_found_reference  = 1'b1;
        end else if (!lq_second_free_found_reference) begin
          lq_second_free_offset_reference = IdxWidth'(i);
          lq_second_free_found_reference  = 1'b1;
        end
      end
    end

  end

  // Sample on the clock edge to avoid intermediate delta-cycle tree values.
  always_ff @(posedge i_clk) begin
    if (!$isunknown(lq_free_rotated)) begin
      p_lq_first_free_tree_found_exact :
      assert (lq_first_free_found == lq_first_free_found_reference);
      p_lq_second_free_tree_found_exact :
      assert (lq_second_free_found == lq_second_free_found_reference);
      if (lq_first_free_found_reference) begin
        p_lq_first_free_tree_offset_exact :
        assert (lq_first_free_offset == lq_first_free_offset_reference);
      end
      if (lq_second_free_found_reference) begin
        p_lq_second_free_tree_offset_exact :
        assert (lq_second_free_offset == lq_second_free_offset_reference);
      end
    end
  end
`endif

  assign alloc_target   = tail_ptr + PtrWidth'({1'b0, lq_first_free_offset});
  assign alloc_target_2 = tail_ptr + PtrWidth'({1'b0, lq_second_free_offset});

  // Precompute allocation masks for each search origin, then select with the
  // cursor for timing. The tree supplies binary indices. Masks exist only
  // when enough free entries exist, so they include room qualification.
  function automatic logic [DEPTH-1:0] cyclic_before_mask(input int start, input int stop);
    cyclic_before_mask = '0;
    for (int step = 0; step < DEPTH; step++) begin
      if (step < ((stop + DEPTH - start) % DEPTH)) cyclic_before_mask[(start+step)%DEPTH] = 1'b1;
    end
  endfunction
  (* keep = "true" *) logic [DEPTH-1:0][DEPTH-1:0] first_free_by_start, second_free_by_start;
  for (genvar start = 0; start < DEPTH; start++) begin : gen_alloc_origin
    for (genvar entry = 0; entry < DEPTH; entry++) begin : gen_entry
      localparam logic [DEPTH-1:0] BeforeMask = cyclic_before_mask(start, entry);
      logic [DEPTH-1:0] one_free_terms;
      for (genvar lower = 0; lower < DEPTH; lower++) begin : gen_lower
        if (BeforeMask[lower]) begin : gen_preceding
          assign one_free_terms[lower] = !lq_valid[lower] &&
              (&(lq_valid | ~BeforeMask | (DEPTH'(1) << lower)));
        end else begin : gen_other
          assign one_free_terms[lower] = 1'b0;
        end
      end
      assign first_free_by_start[start][entry]  = !lq_valid[entry] && (&(lq_valid | ~BeforeMask));
      assign second_free_by_start[start][entry] = !lq_valid[entry] && (|one_free_terms);
    end
  end

  // One-hot decodes of the tree search: the reference the parallel masks are
  // checked against. Only the masks below drive the allocation pulses.
  always_comb begin
    first_target_oh                                = '0;
    second_target_oh                               = '0;
    first_target_oh[alloc_target[IdxWidth-1:0]]    = 1'b1;
    second_target_oh[alloc_target_2[IdxWidth-1:0]] = 1'b1;
  end
  assign first_room_oh  = first_free_by_start[tail_ptr[IdxWidth-1:0]] & {DEPTH{alloc_flush_ok}};
  assign second_room_oh = second_free_by_start[tail_ptr[IdxWidth-1:0]] & {DEPTH{alloc_flush_ok}};
`ifdef F_LQ_ALLOC_MASK_PROOF
  always_comb begin
    p_first_room_exact : assert (first_room_oh == (first_target_oh & {DEPTH{alloc_room_1}}));
    p_second_room_exact : assert (second_room_oh == (second_target_oh & {DEPTH{alloc_room_2}}));
  end
`endif
  assign slot1_alloc_oh = first_room_oh & {DEPTH{i_alloc.valid}};
  assign slot2_alloc_oh = i_alloc.valid ? (second_room_oh & {DEPTH{i_alloc_2.valid}})
                                        : (first_room_oh & {DEPTH{i_alloc_2.valid}});
  assign alloc_oh = (first_room_oh & {DEPTH{i_alloc.valid || i_alloc_2.valid}}) |
                    (second_room_oh & {DEPTH{i_alloc.valid && i_alloc_2.valid}});

`ifndef SYNTHESIS
  // Enable-then-steer reference for the expanded pulses above: the slot-2
  // enable chooses its room behind the slot-1 enable, and the slot-2 pulse is
  // steered by that enable.  Simulation and formal compare both forms.
  logic slot2_alloc_en_reference;
  logic [DEPTH-1:0] slot2_alloc_oh_reference;
  assign slot2_alloc_en_reference = i_alloc_2.valid && alloc_flush_ok &&
                                    (slot1_alloc_en ? !full_for_2 : !full);
  assign slot2_alloc_oh_reference = (slot1_alloc_en ? second_target_oh : first_target_oh) &
                                    {DEPTH{slot2_alloc_en_reference}};
`endif

  // ===========================================================================
  // Head Advancement (find-first-valid from head)
  // ===========================================================================
  // Rotate from head_ptr, select the first valid offset, and add it to head
  // to skip holes in one cycle.

  logic [DEPTH-1:0] lq_head_valid_rotated;
  logic [IdxWidth-1:0] lq_head_first_valid_offset;
  logic lq_head_first_valid_found;

  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      lq_head_valid_rotated[i] = lq_valid[IdxWidth'(head_idx+IdxWidth'(i))];
    end
  end

  // Priority encoder: find lowest-index set bit (first valid entry)
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

  // Update control flops each cycle for timing. sq_check_pending qualifies
  // sideband state; completion clears it and the next capture replaces the
  // stale sideband values.
  logic sq_check_pending_next;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) sq_check_pending_copy <= '0;
    else sq_check_pending_copy <= {3{sq_check_pending_next}};
  end
`ifndef SYNTHESIS
  // The copies share next state and agree after the first edge.
  logic sq_check_pending_copies_armed_q = 1'b0;
  always_ff @(posedge i_clk) begin
    sq_check_pending_copies_armed_q <= 1'b1;
    if (sq_check_pending_copies_armed_q) begin
      p_sq_check_pending_copies_match : assert (sq_check_pending_copy == {3{sq_check_pending}});
      p_sq_check_payload_en_copies_match :
      assert ({sq_check_payload_en_b, sq_check_payload_en_c, sq_check_payload_en_d} ==
              {3{sq_check_payload_en}});
    end
  end
`endif
  logic sq_check_no_older_store_next;
  logic sq_check_phase2_next;
  logic sq_check_flushed;
  assign sq_check_flushed = i_flush_en && sq_check_pending && (flush_all_entries || is_younger(
      sq_check_rob_tag_q, i_flush_tag, i_rob_head_tag
  ));

  // Capture/replace and partial-flush clear cannot coincide because capture
  // requires !i_flush_en. Full flush may allow payload capture but resets all
  // SQ-check control bits on the edge. Use independent next-state expressions
  // for timing.
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
  // Tie CE high for control-flop timing.
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
  // Each row records unfinished AMOs older than its LQ entry. Only allocation
  // introduces dependencies; AMO write completion clears its column on that
  // edge. Free and partial flush clear lq_valid first. The following invalid
  // cycle clears the dead row and column before reuse, so blocking cannot end
  // early. A one-cycle valid mirror detects each new entry and uses its saved
  // allocation-time ROB head for age comparison.
  always_comb begin
    for (int unsigned j = 0; j < DEPTH; j++) begin
      pending_amo_phys[j] = lq_valid[j] && lq_is_amo[j] && !lq_data_valid[j];
      dep_done_oh[j] = (amo_state == AMO_WRITE_ACTIVE) && i_amo_mem_write_done &&
                       (amo_entry_idx == IdxWidth'(j));
      dep_live_src[j] = pending_amo_phys[j] && !dep_done_oh[j];
    end

    // Allocation uses the pre-edge valid mask and is flush-gated. Every reused
    // slot therefore has a full invalid cycle and a detectable 0-to-1 transition,
    // including dual allocations.
    dep_replaced_oh = lq_valid & ~dep_identity_valid_q;
    dep_new_amo_src = dep_replaced_oh & pending_amo_phys;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      older_amo_dep_d[i] = '0;

      // A newly-live generation rebuilds its destination row from current
      // source identities. Comparing tags (rather than assuming physical or
      // request order) preserves sparse and dual-allocation behavior.
      if (!lq_valid[i]) begin
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
      // Both are pre-edge snapshots. After an allocation edge, lq_valid
      // contains the new generation while this mirror still contains zero,
      // and dep_head_q contains that allocation edge's age origin.
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
      cs_valid                  <= '0;
      cs_drop                   <= '0;
      cached_launch_hold_q      <= 1'b0;
      cs_any_q                  <= 1'b0;
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
      // On full flush, retain response debt for accepted fast requests unless
      // this edge drains it. Router-pending requests are unaccepted and canceled.
      // Use the separate pending bit: composite busy also includes unrelated
      // write and recovery blockers.
      drop_mem_response_pending <=
          (drop_mem_response_pending || (mem_outstanding && !i_mem_request_pending)) &&
          !fast_resp_now;
      // Keep cached slots until their responses drain. cs_valid_next frees the
      // answering slot and any unaccepted request canceled by the router.
      cs_valid <= cs_valid_next;
      cs_drop <= cs_valid_next;
      cached_launch_hold_q <= cached_launch_hold_next;
      cs_any_q <= |cs_valid_next;
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
        // If the outstanding fast-tier load was flushed, drop the next memory
        // response so the recycled slot cannot see stale data.
        if (fast_entry_flushed) begin
          mem_outstanding <= 1'b0;
          lq_issued[fast_idx] <= 1'b0;
          if (!fast_resp_now) begin
            drop_mem_response_pending <= 1'b1;
          end
        end
        // Cached slots killed by the flush drain their later response; the
        // slot answering now is drained by drop_mem_response_now below.
        for (int sl = 0; sl < int'(CachedSlots); sl++) begin
          if (cs_flushed[sl] && !(resp_from_slot && (resp_slot == CachedSlotBits'(sl)))) begin
            cs_drop[sl] <= 1'b1;
            lq_issued[cs_idx[sl]] <= 1'b0;
          end
        end
        // No current-cycle allocation can advance the search cursor. It may
        // still consume the prior bundle's registered generation pulse below;
        // either origin reuses reclaimed holes because the free search is
        // driven by the updated valid mask.
      end

      // tail_ptr is only a search origin. Advance it after detecting the prior
      // bundle's allocations for timing. Back-to-back searches skip those entries
      // because they are already valid; occupancy and age do not depend on tail.
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
      // cache hit directly into cdb_stage. The entry is already freed via
      // free_entry_en.
      if (cache_hit_fast_path && !cache_hit_bypass_fire) begin
        lq_data_valid[sq_check_idx] <= 1'b1;
      end

      // -----------------------------------------------------------------
      // Store forwarding: write data directly, skip memory
      // -----------------------------------------------------------------
      // Skip the data_valid step when the completion bypass captured the
      // forward directly into cdb_stage. The entry is already freed via
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
      // Drain responses for flushed entries. Keep this before launch handling so
      // a simultaneous fast launch overrides response clearing of mem_outstanding.
      if (drop_mem_response_now) begin
        if (!resp_from_slot) begin
          mem_outstanding <= 1'b0;
          drop_mem_response_pending <= 1'b0;
        end
      end else if (accept_mem_response) begin
        if (!resp_from_slot) mem_outstanding <= 1'b0;
        if (issued_is_amo) begin
          // MIN/MAX writes the next cycle; ordinary AMOs first use COMPUTE. The IDLE
          // guard prevents an overlapping response from replacing an active AMO.
          if (amo_response_capture)
            amo_state <= amo_response_is_minmax ? AMO_WRITE_ACTIVE : AMO_COMPUTE;
        end else begin
          // A bypassed result frees its entry, so skip data_valid; the response RAM
          // write is harmless. LR sets its reservation on either completion path
          // unless coherence suppresses it.
          if (issued_is_lr && !issued_lr_suppressed) reservation_valid <= 1'b1;
          if (!resp_bypass_fire) begin
            // Standard path: let the priority encoder pick next cycle.
            lq_data_valid[issued_idx] <= 1'b1;
          end
        end
      end

      // A cached response, accepted or drained, frees its slot.
      if (resp_from_slot) begin
        cs_valid[resp_slot] <= 1'b0;
        cs_drop[resp_slot]  <= 1'b0;
      end

      // -----------------------------------------------------------------
      // Memory Issue: mark entry as issued, track for response routing
      // -----------------------------------------------------------------
      // Launch follows response handling so a simultaneous fast launch leaves
      // mem_outstanding set and installs the next snapshot. An accepted
      // response and a launch use distinct LQ entries; a dropped response may
      // name an index already reused, and its branch leaves that entry alone.
      // Cached launches use separate slots.
      if (o_mem_read_en) begin
        lq_issued[launch_mem_issue_idx] <= 1'b1;
        if (launching_is_cached) begin
          cs_valid[cs_alloc_idx] <= 1'b1;
          cs_drop[cs_alloc_idx]  <= 1'b0;
        end else begin
          mem_outstanding <= 1'b1;
        end
      end
      // Launch hold: every slot busy, or the router holding a cached response
      // behind a fast beat (one skipped launch opens the response port).
      cached_launch_hold_q <= cached_launch_hold_next;
      cs_any_q             <= |cs_valid_next;

      // -----------------------------------------------------------------
      // Compute from response-captured operands. A killed AMO can cancel before
      // launch; ignore write_done until AMO_WRITE_ACTIVE.
      // -----------------------------------------------------------------
      if (amo_state == AMO_COMPUTE) begin
        amo_state <= amo_compute_owner_killed ? AMO_IDLE : AMO_WRITE_ACTIVE;
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
      if (i_sc_clear_reservation || i_reservation_snoop_invalidate || coh_reservation_inval) begin
        reservation_valid <= 1'b0;
      end

      // -----------------------------------------------------------------
      // Entry Freeing + Head Advancement
      // -----------------------------------------------------------------
      if (free_entry_en) begin
        lq_valid[free_entry_idx] <= 1'b0;
      end

      // -----------------------------------------------------------------
      // Allocation: initialize a new physical generation (control signals
      // only; data payloads use dedicated no-reset always_ff blocks).
      // -----------------------------------------------------------------
      // Initialize after old-entry updates so allocation has final priority.
      // Legal allocations cannot overlap a completing entry, and the two slot
      // vectors are disjoint.
      for (int unsigned i = 0; i < DEPTH; i++) begin
        if (alloc_oh[i]) begin
          lq_valid[i]      <= 1'b1;
          lq_addr_valid[i] <= 1'b0;
          lq_issued[i]     <= 1'b0;
          lq_data_valid[i] <= 1'b0;
          lq_forwarded[i]  <= 1'b0;
        end
      end

      // Advance head past all contiguous invalid entries (including freed)
      head_ptr <= head_advance_target;

    end  // !flush_all
  end

  // ===========================================================================
  // Data-Payload Sequential Logic
  // ===========================================================================
  // Reset valid/control state to hide unreset payloads. The staged AMO-kind
  // write resets only its request-valid bits; indices and data remain unreset.

  // -----------------------------------------------------------------
  // Per-entry data: allocation writes
  // -----------------------------------------------------------------
  // The merged pulse enables writes; slot 1's pulse selects its payload.
  // Any other allocated entry uses slot 2's payload.
  always_ff @(posedge i_clk) begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (alloc_oh[i]) begin
        lq_rob_tag[i]  <= slot1_alloc_oh[i] ? i_alloc.rob_tag : i_alloc_2.rob_tag;
        lq_size[i]     <= slot1_alloc_oh[i] ? i_alloc.size : i_alloc_2.size;
        lq_is_fp[i]    <= slot1_alloc_oh[i] ? i_alloc.is_fp : i_alloc_2.is_fp;
        lq_sign_ext[i] <= slot1_alloc_oh[i] ? i_alloc.sign_ext : i_alloc_2.sign_ext;
        lq_is_lr[i]    <= slot1_alloc_oh[i] ? i_alloc.is_lr : i_alloc_2.is_lr;
        lq_is_amo[i]   <= slot1_alloc_oh[i] ? i_alloc.is_amo : i_alloc_2.is_amo;
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
      lq_fault_kind[lq_addr_update_idx] <= i_addr_update.fault_kind;
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
  riscv_pkg::data_fault_kind_e issue_mem_fault_kind;
  // Give each address copy its own enable for fanout. Separate, identical
  // sq_check_pending_copy flops keep these enables distinct while preserving
  // capture/replace behavior.
  logic sq_check_payload_en;
  logic sq_check_payload_en_b;
  logic sq_check_payload_en_c;
  logic sq_check_payload_en_d;
  logic [IdxWidth-1:0] sq_check_idx_next;
  logic [ReorderBufferTagWidth-1:0] sq_check_rob_tag_next;
  logic [XLEN-1:0] sq_check_addr_next;
  riscv_pkg::mem_size_e sq_check_size_next;
  logic sq_check_is_fp_next;
  logic sq_check_sign_ext_next;
  logic sq_check_is_mmio_next;
  logic sq_check_is_lr_next;
  logic sq_check_is_amo_next;
  logic [1:0] sq_check_fault_kind_next;
  assign sq_check_payload_en = sq_check_capture || sq_check_replace;
  // sq_check_capture with the pending bit taken from one copy.
  function automatic logic sq_check_capture_on(input logic pending);
    sq_check_capture_on = (!pending || sq_check_will_clear) && issue_mem_found &&
        sq_check_gate_early;
  endfunction
  assign sq_check_payload_en_b = sq_check_capture_on(sq_check_pending_copy[0]) || sq_check_replace;
  assign sq_check_payload_en_c = sq_check_capture_on(sq_check_pending_copy[1]) || sq_check_replace;
  assign sq_check_payload_en_d = sq_check_capture_on(sq_check_pending_copy[2]) || sq_check_replace;
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
  assign issue_mem_fault_kind = issue_mem_from_update ? i_addr_update.fault_kind
                                                      : lq_fault_kind[issue_mem_stored_idx];

  // Use CE for capture/replace and drive D from the candidate for timing.
  assign sq_check_idx_next = issue_mem_idx;
  assign sq_check_rob_tag_next = issue_mem_rob_tag;
  assign sq_check_addr_next = issue_mem_addr;
  assign sq_check_size_next = riscv_pkg::mem_size_e'(issue_mem_size_bits);
  assign sq_check_is_fp_next = issue_mem_is_fp;
  assign sq_check_sign_ext_next = issue_mem_sign_ext;
  assign sq_check_is_mmio_next = issue_mem_is_mmio;
  assign sq_check_is_lr_next = issue_mem_is_lr;
  assign sq_check_is_amo_next = issue_mem_is_amo;
  assign sq_check_fault_kind_next = 2'(issue_mem_fault_kind);

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

  // Use always_ff for sq_check_addr_q so Vivado can replicate it for fanout.
  // Explicit FDRE instances prevent that replication.
  always_ff @(posedge i_clk) begin
    if (sq_check_payload_en) sq_check_addr_q <= sq_check_addr_next;
  end

  // Address copies share data and equivalent enables. Preserve them for fanout.
  always_ff @(posedge i_clk) begin
    if (sq_check_payload_en_b) sq_check_addr_q_b <= sq_check_addr_next;
  end

  always_ff @(posedge i_clk) begin
    if (sq_check_payload_en_c) sq_check_addr_q_c <= sq_check_addr_next;
  end

  always_ff @(posedge i_clk) begin
    if (sq_check_payload_en_d) sq_check_addr_q_d <= sq_check_addr_next;
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

  for (genvar g_sq_fk = 0; g_sq_fk < 2; g_sq_fk++) begin : gen_sq_check_fault_kind_ff
    FDRE #(
        .INIT(1'b0)
    ) sq_check_fault_kind_ff (
        .C (i_clk),
        .CE(sq_check_payload_en),
        .D (sq_check_fault_kind_next[g_sq_fk]),
        .Q (sq_check_fault_kind_q[g_sq_fk]),
        .R (1'b0)
    );
  end
`else
  always_ff @(posedge i_clk) begin
    if (sq_check_payload_en) sq_check_addr_q <= sq_check_addr_next;
    if (sq_check_payload_en_b) sq_check_addr_q_b <= sq_check_addr_next;
    if (sq_check_payload_en_c) sq_check_addr_q_c <= sq_check_addr_next;
    if (sq_check_payload_en_d) sq_check_addr_q_d <= sq_check_addr_next;
    if (sq_check_payload_en) begin
      sq_check_idx          <= sq_check_idx_next;
      sq_check_rob_tag_q    <= sq_check_rob_tag_next;
      sq_check_size_q       <= sq_check_size_next;
      sq_check_is_fp_q      <= sq_check_is_fp_next;
      sq_check_sign_ext_q   <= sq_check_sign_ext_next;
      sq_check_is_mmio_q    <= sq_check_is_mmio_next;
      sq_check_is_lr_q      <= sq_check_is_lr_next;
      sq_check_is_amo_q     <= sq_check_is_amo_next;
      sq_check_fault_kind_q <= sq_check_fault_kind_next;
    end
  end
`endif

  // -----------------------------------------------------------------
  // Internal data: issued entry tracker + flat snapshot
  // -----------------------------------------------------------------
  // Response handling reads stable launch snapshots rather than entry arrays.
  // Invalidation and LR-suppression bits accumulate hits until slot relaunch,
  // which clears them. Keep launch on D for timing.
  logic [CachedSlots-1:0] cs_inval_next, cs_lr_suppress_next;
  for (genvar sl = 0; sl < CachedSlots; sl++) begin : gen_cached_inval
    logic launch_slot;
    assign launch_slot = o_mem_read_en && launching_is_cached &&
        (cs_alloc_idx == CachedSlotBits'(sl));
    assign cs_inval_next[sl] = !launch_slot &&
        (cs_inval[sl] || cs_inval_now[sl] || cs_coh_inval_now[sl]);
    assign cs_lr_suppress_next[sl] = !launch_slot &&
        (cs_lr_suppress[sl] || (cs_coh_inval_now[sl] && cs_is_lr[sl]));
`ifdef FROST_XILINX_PRIMS
    FDRE #(
        .INIT(1'b0)
    ) cs_inval_ff (
        .C (i_clk),
        .CE(1'b1),
        .R (!i_rst_n),
        .D (cs_inval_next[sl]),
        .Q (cs_inval[sl])
    );
    FDRE #(
        .INIT(1'b0)
    ) cs_lr_suppress_ff (
        .C (i_clk),
        .CE(1'b1),
        .R (!i_rst_n),
        .D (cs_lr_suppress_next[sl]),
        .Q (cs_lr_suppress[sl])
    );
`else
    always_ff @(posedge i_clk) begin
      if (!i_rst_n) begin
        cs_inval[sl] <= 1'b0;
        cs_lr_suppress[sl] <= 1'b0;
      end else begin
        cs_inval[sl] <= cs_inval_next[sl];
        cs_lr_suppress[sl] <= cs_lr_suppress_next[sl];
      end
    end
`endif
`ifdef F_LQ_CACHED_FLAGS_PROOF
    logic f_inval_next, f_lr_next;
    always_comb begin
      f_inval_next = cs_inval[sl];
      f_lr_next = cs_lr_suppress[sl];
      if (o_mem_read_en && launching_is_cached && (cs_alloc_idx == CachedSlotBits'(sl))) begin
        f_inval_next = 1'b0;
        f_lr_next = 1'b0;
      end else begin
        if (cs_inval_now[sl] || cs_coh_inval_now[sl]) f_inval_next = 1'b1;
        if (cs_coh_inval_now[sl] && cs_is_lr[sl]) f_lr_next = 1'b1;
      end
      assert (cs_inval_next[sl] == f_inval_next);
      assert (cs_lr_suppress_next[sl] == f_lr_next);
    end
`endif
  end

  // AMOs cannot hit L0. Omit its lookup from the AMO snapshot enable for timing;
  // amo_launch equals o_mem_read_en && sq_check_is_amo_q.
  logic amo_launch;
  assign amo_launch = sq_check_is_amo_q && !i_flush_en && !i_flush_all && !i_mem_bus_busy &&
                      sq_can_issue && !cached_launch_hold_q;

  always_ff @(posedge i_clk) begin
    // Snapshot every request handed to the router: a fast-tier (BRAM/MMIO)
    // launch into the single fast snapshot, a cached launch into its slot.
    // An MMIO handoff keeps the fast snapshot to itself: the router's pending
    // bit, part of the wrapper's i_mem_bus_busy, blocks every later launch
    // through the router's accept cycle.
    if (o_mem_read_en && !launching_is_cached) begin
      fast_idx      <= launch_mem_issue_idx;
      fast_addr     <= launch_mem_issue_addr;
      fast_size     <= launch_mem_issue_size;
      fast_is_fp    <= sq_check_is_fp_q;
      fast_is_lr    <= sq_check_is_lr_q;
      fast_is_amo   <= sq_check_is_amo_q;
      fast_is_mmio  <= sq_check_is_mmio_q;
      fast_sign_ext <= sq_check_sign_ext_q;
      fast_rob_tag  <= sq_check_rob_tag_q;
    end
    if (amo_launch && !launching_is_cached) begin
      fast_amo_kind <= lq_amo_kind[launch_mem_issue_idx];
      fast_amo_rs2  <= lq_amo_rs2_rd;
    end
    if (o_mem_read_en && launching_is_cached) begin
      cs_idx[cs_alloc_idx]      <= launch_mem_issue_idx;
      cs_addr[cs_alloc_idx]     <= launch_mem_issue_addr;
      cs_size[cs_alloc_idx]     <= launch_mem_issue_size;
      cs_is_fp[cs_alloc_idx]    <= sq_check_is_fp_q;
      cs_is_lr[cs_alloc_idx]    <= sq_check_is_lr_q;
      cs_is_amo[cs_alloc_idx]   <= sq_check_is_amo_q;
      cs_sign_ext[cs_alloc_idx] <= sq_check_sign_ext_q;
      cs_rob_tag[cs_alloc_idx]  <= sq_check_rob_tag_q;
    end
    if (amo_launch && launching_is_cached) begin
      cs_amo_kind[cs_alloc_idx] <= lq_amo_kind[launch_mem_issue_idx];
      cs_amo_rs2[cs_alloc_idx]  <= lq_amo_rs2_rd;
    end
  end
`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown({amo_launch, o_mem_read_en, sq_check_is_amo_q})) begin
      p_amo_launch_is_the_amo_launch : assert (amo_launch == (o_mem_read_en && sq_check_is_amo_q));
    end
  end
`endif

  // -----------------------------------------------------------------
  // Internal data: registered AMO write payload and completion identity.
  // AMO operation and rs2 come from launch snapshots. With simultaneous
  // response and launch, nonblocking assignments consume the responding
  // request's snapshot before installing the next one.
  // -----------------------------------------------------------------
  // AMO operand width: .W forms select the addressed word of the response
  // beat by addr[2] and compute at 32 bits (the rd old value sign-extends at
  // XLEN=64, the RV64A semantic); .D forms use the full beat (XLEN=64 only,
  // enforced by decode).
  logic [XLEN-1:0] amo_beat_word;
  assign amo_beat_word = XLEN'(i_mem_read_data[issued_addr[2]*32+:32]);
  logic issued_amo_is_d;
  assign issued_amo_is_d = (riscv_pkg::mem_size_e'(issued_size) == riscv_pkg::MEM_SIZE_DOUBLE);
  logic [XLEN-1:0] amo_old_word_sext;
  assign amo_old_word_sext = {{(XLEN - 32) {amo_beat_word[31]}}, amo_beat_word[31:0]};
  logic [XLEN-1:0] amo_response_old_value;
  logic [XLEN-1:0] amo_compute_result;
  logic [1:0] amo_response_minmax_relation_d;
  logic [1:0] amo_response_minmax_relation_w;
  logic amo_response_minmax_is_unsigned;
  logic amo_response_minmax_is_max;
  // AMO ordering permits responses only in IDLE. Guard capture locally so
  // even an invalid overlap cannot overwrite a stalled write's payload.
  assign amo_response_capture = accept_mem_response && issued_is_amo && (amo_state == AMO_IDLE);
  assign amo_response_old_value = issued_amo_is_d ? XLEN'(i_mem_read_data) : amo_old_word_sext;
  // Reuse the old-value and rs2 capture registers for normal arithmetic.
  // .W's architectural old-value sign extension does not affect its low32
  // result; .W computes with the 32-bit function and zero-extends.
  assign amo_compute_result = amo_is_d_q ? amo_non_minmax_compute(
      amo_kind_q, amo_old_value, amo_minmax_rs2_q
  ) : XLEN'(amo_non_minmax_compute32(
      amo_kind_q, amo_old_value[31:0], amo_minmax_rs2_q[31:0]
  ));
  assign amo_response_is_minmax = is_amo_minmax_kind(issued_amo_kind);
  // Capture raw relations independently for timing, before width or mode selection.
  assign amo_response_minmax_relation_d[1] = (XLEN'(i_mem_read_data) == issued_amo_rs2);
  assign amo_response_minmax_relation_d[0] = (XLEN'(i_mem_read_data) < issued_amo_rs2);
  // .W compares both beat words before selecting with issued_addr[2], for timing.
  logic [1:0] amo_response_minmax_relation_w_lo;
  logic [1:0] amo_response_minmax_relation_w_hi;
  assign amo_response_minmax_relation_w_lo[1] = (i_mem_read_data[31:0] == issued_amo_rs2[31:0]);
  assign amo_response_minmax_relation_w_lo[0] = (i_mem_read_data[31:0] < issued_amo_rs2[31:0]);
  assign amo_response_minmax_relation_w_hi[1] = (i_mem_read_data[63:32] == issued_amo_rs2[31:0]);
  assign amo_response_minmax_relation_w_hi[0] = (i_mem_read_data[63:32] < issued_amo_rs2[31:0]);
  assign amo_response_minmax_relation_w = issued_addr[2] ? amo_response_minmax_relation_w_hi :
                                                           amo_response_minmax_relation_w_lo;
`ifndef SYNTHESIS
  // The selected relation equals comparing the addressed word itself.
  always_ff @(posedge i_clk) begin
    if (amo_response_capture && !$isunknown(
            {i_mem_read_data, issued_amo_rs2[31:0], issued_addr[2]}
        )) begin
      p_amo_relation_w_select_exact :
      assert (amo_response_minmax_relation_w ==
              {amo_beat_word[31:0] == issued_amo_rs2[31:0],
               amo_beat_word[31:0] < issued_amo_rs2[31:0]});
    end
  end
`endif
  assign amo_response_minmax_is_unsigned =
      (issued_amo_kind == AMO_KIND_MINU) || (issued_amo_kind == AMO_KIND_MAXU);
  assign amo_response_minmax_is_max =
      (issued_amo_kind == AMO_KIND_MAX) || (issued_amo_kind == AMO_KIND_MAXU);

  always_ff @(posedge i_clk) begin
    if (amo_response_capture) begin
      amo_old_value <= amo_response_old_value;
      amo_entry_idx <= issued_idx;
      amo_write_addr_q <= issued_addr;
      // Same source, same edge, same enable as the address: the flag is its
      // decode for as long as it is held (the write-active hold included).
      amo_write_is_cached_q <= is_cached_addr(issued_addr);
      amo_kind_q <= issued_amo_kind;
      amo_minmax_rs2_q <= issued_amo_rs2;
      amo_is_d_q <= issued_amo_is_d;
      amo_is_minmax_q <= amo_response_is_minmax;
      amo_minmax_relation_d_q <= amo_response_minmax_relation_d;
      amo_minmax_relation_w_q <= amo_response_minmax_relation_w;
      amo_minmax_is_unsigned_q <= amo_response_minmax_is_unsigned;
      amo_minmax_is_max_q <= amo_response_minmax_is_max;
    end
    // A killed COMPUTE may write hidden data. Reset/recovery cancels control,
    // and each later ordinary AMO replaces the data before ACTIVE. Omit flush
    // and age gates from the payload enable for timing.
    if (amo_state == AMO_COMPUTE) amo_write_data_q <= amo_compute_result;
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

  // Capture implies an available slot and no partial flush, so issue_cdb_found
  // equals issue_cdb_fire. The reduced bypass selects are likewise equivalent
  // under capture; omit flush and grant from payload selection for timing.
  always_ff @(posedge i_clk) begin
    if (issue_cdb_fire || bypass_fire) begin
      cdb_stage_data.value <= cdb_value_next;
      if (issue_cdb_found) begin
        cdb_stage_data.tag       <= issue_cdb_result.tag;
        cdb_stage_data.exception <= issue_cdb_result.exception;
        cdb_stage_data.exc_cause <= issue_cdb_result.exc_cause;
        cdb_stage_data.fp_flags  <= issue_cdb_result.fp_flags;
      end else begin
        cdb_stage_data.tag <= bypass_tag;
        cdb_stage_data.exception <= misalign_bypass_data_sel;
        // Parked MISALIGN/PAGE/ACCESS select load causes 4/13/5 or AMO causes 6/15/7
        // (Spike and the privileged spec). Otherwise PMA access faults outrank
        // misalignment; see lq_bypass_cause.
        cdb_stage_data.exc_cause <= !misalign_bypass_data_sel ? riscv_pkg::exc_cause_t'('0) :
            lq_bypass_cause(
            riscv_pkg::data_fault_kind_e'(sq_check_fault_kind_q),
            sq_check_pma_fault,
            sq_check_is_amo_q
        );
        cdb_stage_data.fp_flags <= '0;
      end
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // Check Phase A against the first valid, data-ready entry in ring order.
  logic sim_issue_cdb_found_ref;
  logic [IdxWidth-1:0] sim_issue_cdb_idx_ref;
  always_comb begin
    sim_issue_cdb_found_ref = 1'b0;
    sim_issue_cdb_idx_ref   = '0;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (lq_valid[IdxWidth'(head_idx + IdxWidth'(i))] &&
          lq_data_valid[IdxWidth'(head_idx + IdxWidth'(i))] && !sim_issue_cdb_found_ref) begin
        sim_issue_cdb_found_ref = 1'b1;
        sim_issue_cdb_idx_ref   = IdxWidth'(head_idx + IdxWidth'(i));
      end
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst_n && !$isunknown({lq_valid, lq_data_valid, head_idx})) begin
      p_issue_cdb_physical_select_exact :
      assert (issue_cdb_found == sim_issue_cdb_found_ref && issue_cdb_idx == sim_issue_cdb_idx_ref);
    end
  end
`endif
`endif

  // ===========================================================================
  // Simulation Assertions
  // ===========================================================================
`ifndef SYNTHESIS
`ifndef FORMAL
  // Entries named by the fast tracker or a live cached slot.
  logic [DEPTH-1:0] sim_resp_owned;
  always_comb begin
    sim_resp_owned = '0;
    if (mem_outstanding) sim_resp_owned[fast_idx] = 1'b1;
    for (int sl = 0; sl < int'(CachedSlots); sl++) begin
      if (cs_valid[sl] && !cs_drop[sl]) sim_resp_owned[cs_idx[sl]] = 1'b1;
    end
  end

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      if (i_alloc.valid && full) $warning("LQ: allocation attempted when full");
      if (sq_check_pending &&
          ((sq_check_addr_q !== sq_check_addr_q_b) ||
           (sq_check_addr_q !== sq_check_addr_q_c) ||
           (sq_check_addr_q !== sq_check_addr_q_d)))
        $error("LQ: phase-identical SQ address anchors diverged");
      // Flush-cycle requests are legal; allocation gates reject them like the ROB.
      if (i_alloc_2.valid && i_alloc.valid && full_for_2)
        $warning("LQ: slot-2 alloc attempted when full_for_2 (and slot-1 firing)");
      if (i_alloc_2.valid && !i_alloc.valid && full)
        $warning("LQ: slot-2 alloc attempted alone when full");
      if (i_flush_all && accept_mem_response)
        $error("LQ: accepted memory response during full flush");
      if (i_flush_all && cache_fill_valid) $error("LQ: filled L0 cache during full flush");
      // Never full-flush an active AMO write: memory could change after its
      // instruction is squashed, then trap recovery could execute it again. The
      // trap unit's AMO interrupt shield prevents this. COMPUTE may cancel
      // because it has not launched a write (load queue README, "AMO sequence").
      if (i_flush_all && (amo_state == AMO_WRITE_ACTIVE || o_amo_mem_write_en))
        $error("LQ: full flush while an AMO memory write is in flight (orphaned write)");
      // Only one AMO may await computation or write completion. AMO_IDLE capture
      // gating also protects the payload against invalid overlapping responses.
      if (accept_mem_response && issued_is_amo && (amo_state != AMO_IDLE))
        $error("LQ: overlapping AMO response arrived while an owner was active");
      // Each live cached slot must name its launched entry: valid, issued, and
      // holding the saved ROB tag. Live slots and new launches cannot share an
      // entry. A response must complete only its initiating load. Never recheck a
      // drop-marked slot's stale tag against later flushes; see cs_flushed.
      for (int sl = 0; sl < int'(CachedSlots); sl++) begin
        if (cs_valid[sl] && !cs_drop[sl] &&
            !(lq_valid[cs_idx[sl]] && lq_issued[cs_idx[sl]] &&
              (lq_rob_tag[cs_idx[sl]] == cs_rob_tag[sl])))
          $error(
              "LQ: live cached slot %0d (tag %0d) names entry %0d (valid %0d issued %0d tag %0d)",
              sl,
              cs_rob_tag[sl],
              cs_idx[sl],
              lq_valid[cs_idx[sl]],
              lq_issued[cs_idx[sl]],
              lq_rob_tag[cs_idx[sl]]
          );
        for (int sl2 = sl + 1; sl2 < int'(CachedSlots); sl2++) begin
          if (cs_valid[sl] && !cs_drop[sl] && cs_valid[sl2] && !cs_drop[sl2] &&
              (cs_idx[sl] == cs_idx[sl2]))
            $error("LQ: live cached slots %0d and %0d both name entry %0d", sl, sl2, cs_idx[sl]);
        end
        if (o_mem_read_en && cs_valid[sl] && !cs_drop[sl] && (cs_idx[sl] == launch_mem_issue_idx))
          $error(
              "LQ: launch of entry %0d while live cached slot %0d still names it",
              launch_mem_issue_idx,
              sl
          );
      end
      if (o_mem_read_en &&
          !(lq_valid[launch_mem_issue_idx] && !lq_issued[launch_mem_issue_idx] &&
            (lq_rob_tag[launch_mem_issue_idx] == sq_check_rob_tag_q)))
        $error(
            "LQ: launch of entry %0d (valid %0d issued %0d tag %0d) from a staged copy tagged %0d",
            launch_mem_issue_idx,
            lq_valid[launch_mem_issue_idx],
            lq_issued[launch_mem_issue_idx],
            lq_rob_tag[launch_mem_issue_idx],
            sq_check_rob_tag_q
        );
      if (accept_mem_response && resp_from_slot &&
          (cs_rob_tag[resp_slot] != lq_rob_tag[issued_idx]))
        $error(
            "LQ: cached response of slot %0d (tag %0d) accepted by entry %0d holding tag %0d",
            resp_slot,
            cs_rob_tag[resp_slot],
            issued_idx,
            lq_rob_tag[issued_idx]
        );
      if (accept_mem_response && !resp_from_slot && (fast_rob_tag != lq_rob_tag[fast_idx]))
        $error(
            "LQ: fast-tier response (tag %0d) accepted by entry %0d holding tag %0d",
            fast_rob_tag,
            fast_idx,
            lq_rob_tag[fast_idx]
        );
      // Until a launched ordinary load has data, a fast tracker or live cached
      // slot must name it. A new fast launch replaces the snapshot only when the
      // prior response arrives, one cycle after acceptance. Head-load counters
      // rely on this timing.
      for (int unsigned i = 0; i < DEPTH; i++) begin
        if (lq_valid[i] && lq_issued[i] && !lq_data_valid[i] && !lq_is_amo[i] && !sim_resp_owned[i])
          $error(
              "LQ: launched load in entry %0d (tag %0d) owes a response but has no owner",
              i,
              lq_rob_tag[i]
          );
      end
      // Slot-1 and slot-2 must never target the same physical entry.
      if (slot1_alloc_en && slot2_alloc_en && (alloc_target[IdxWidth-1:0] == slot2_alloc_idx))
        $error("LQ: slot-1 and slot-2 alloc collide on entry %0d", alloc_target[IdxWidth-1:0]);
      if (!$onehot0(slot1_alloc_oh) || !$onehot0(slot2_alloc_oh))
        $error("LQ: allocation steering is not onehot-or-zero");
      if ((|slot1_alloc_oh) != slot1_alloc_en || (|slot2_alloc_oh) != slot2_alloc_en)
        $error("LQ: allocation steering lost or invented an accepted request");
      if (|(slot1_alloc_oh & slot2_alloc_oh))
        $error("LQ: slot-1 and slot-2 onehot allocation pulses overlap");
      if (slot2_alloc_en != slot2_alloc_en_reference)
        $error("LQ: expanded slot-2 allocation enable differs from the reference");
      if (slot2_alloc_oh != slot2_alloc_oh_reference)
        $error("LQ: expanded slot-2 allocation pulses differ from the reference");
      if (alloc_oh != (slot1_alloc_oh | slot2_alloc_oh))
        $error("LQ: merged allocation pulses differ from the slot pulses");
      if (dispatch_full_next != (dispatch_count_next == CountWidth'(DEPTH)))
        $error("LQ: expanded dispatch-full prediction differs from the count reference");
      if (dispatch_full_for_2_next != (dispatch_count_next >= CountWidth'(DEPTH - 1)))
        $error("LQ: expanded dispatch-full-for-2 prediction differs from the count reference");
      if (accept_mem_response && dep_replaced_oh[issued_idx])
        $error("LQ: memory response collided with a new physical generation");
      // COMPUTE retains only amo_entry_idx after releasing its response slot.
      // Reallocation could make its validity check pass for another instruction.
      // A live slot cannot be reallocated; check that invariant here.
      if ((amo_state == AMO_COMPUTE) && dep_replaced_oh[amo_entry_idx])
        $error("LQ: AMO compute owner's entry %0d was reallocated under it", amo_entry_idx);
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
          (amo_minmax_selected_relation === 2'b11))
        $error("LQ: active AMO MIN/MAX has an impossible {equal, less-than} relation");
      if (amo_state == AMO_WRITE_ACTIVE && amo_is_minmax_q &&
          amo_minmax_selected_relation[1] && amo_minmax_select_old_active)
        $error("LQ: active AMO MIN/MAX selected old on equality");
      if (amo_state == AMO_WRITE_ACTIVE && amo_is_minmax_q &&
          (amo_write_value !==
           (amo_minmax_select_old_active ? amo_old_value : amo_minmax_rs2_q)))
        $error("LQ: active AMO MIN/MAX write no longer matches its captured relation");
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
      amo_kind_q
  ) && $stable(
      amo_is_d_q
  ) && $stable(
      amo_is_minmax_q
  ) && $stable(
      amo_minmax_relation_d_q
  ) && $stable(
      amo_minmax_relation_w_q
  ) && $stable(
      amo_minmax_is_unsigned_q
  ) && $stable(
      amo_minmax_is_max_q
  ) && $stable(
      amo_minmax_select_old_active
  ) && $stable(
      o_amo_mem_write_en
  ) && $stable(
      o_amo_mem_write_addr
  ) && $stable(
      o_amo_mem_write_data
  ) && $stable(
      o_amo_mem_write_is_dword
  ) && $stable(
      o_amo_mem_write_is_cached
  ))))
  else $error("LQ: AMO write payload changed while memory withheld write_done");

  // The registered tier flag is, on every write-active cycle, the decode of
  // the address presented beside it. Idle forces it low with the address; the
  // check is enable-qualified so a cached region that starts at address zero
  // cannot trip it.
  assert property (@(posedge i_clk) disable iff (!i_rst_n)
      o_amo_mem_write_en |-> (o_amo_mem_write_is_cached == is_cached_addr(
      o_amo_mem_write_addr
  )))
  else $error("LQ: AMO write tier flag disagrees with the presented address");

  // The staged PMA check faults an AMO outside BRAM and the cached tier, so
  // no AMO write reaches a device.
  assert property (@(posedge i_clk) disable iff (!i_rst_n)
      o_amo_mem_write_en |-> riscv_pkg::pma_atomic_ok(
      o_amo_mem_write_addr
  ))
  else $error("LQ: AMO write outside the atomic PMA map");

  // MIN/MAX keep next-cycle write activation; normal AMOs spend exactly one
  // intervening COMPUTE cycle with no write, completion, or dependency release.
  assert property (@(posedge i_clk) disable iff (!i_rst_n || i_flush_all)
      (amo_response_capture && amo_response_is_minmax)
      |=> (amo_state == AMO_WRITE_ACTIVE && o_amo_mem_write_en))
  else $error("LQ: MIN/MAX response-to-write latency changed");
  assert property (@(posedge i_clk) disable iff (!i_rst_n || i_flush_all)
      (amo_response_capture && !amo_response_is_minmax)
      |=> (amo_state == AMO_COMPUTE && !o_amo_mem_write_en))
  else $error("LQ: normal AMO did not capture before computing");
  assert property (@(posedge i_clk) disable iff (!i_rst_n || i_flush_all)
      amo_compute_commit |=> (amo_state == AMO_WRITE_ACTIVE &&
                             amo_write_data_q == $past(
      amo_compute_result
  )))
  else $error("LQ: normal AMO compute/result boundary changed");
  assert property (@(posedge i_clk) disable iff (!i_rst_n || i_flush_all)
      (amo_state == AMO_COMPUTE && amo_compute_owner_killed) |=> (amo_state == AMO_IDLE))
  else $error("LQ: killed compute owner launched an AMO write");
`endif
`endif

  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL
`ifndef F_LQ_PREMATCH_ONLY
`ifdef LQ_AMO_COMPUTE_LOCAL_PROOF
  // Check AMO transitions with unrestricted inputs, including unreachable
  // state combinations. Properties start at response or compute boundaries.
  reg [1:0] f_amo_past_valid = 2'b00;
  always @(posedge i_clk) f_amo_past_valid <= {f_amo_past_valid[0], 1'b1};
  wire f_amo_response_tier = is_cached_addr(issued_addr);
  wire [XLEN-1:0] f_amo_response_result = issued_amo_is_d ? amo_non_minmax_compute(
      issued_amo_kind, XLEN'(i_mem_read_data), issued_amo_rs2
  ) : XLEN'(amo_non_minmax_compute32(
      issued_amo_kind, amo_beat_word[31:0], issued_amo_rs2[31:0]
  ));

  always @(posedge i_clk) begin
    if (amo_state == AMO_COMPUTE) begin
      p_local_no_compute_write : assert (!o_amo_mem_write_en);
      p_local_no_compute_invalidate : assert (!amo_cache_inv);
      p_local_no_compute_done : assert (dep_done_oh == '0);
      p_local_no_compute_overwrite : assert (!amo_response_capture);
    end
    if ((amo_state == AMO_COMPUTE || amo_state == AMO_WRITE_ACTIVE) &&
        amo_write_addr_q[XLEN-1:CohLineLsb] == i_coh_query_addr[XLEN-1:CohLineLsb]) begin
      p_local_retained_line_busy : assert (o_coh_query_busy);
    end
    if (f_amo_past_valid[0]) begin
      if ($past(!i_rst_n || i_flush_all)) begin
        p_local_reset_kill : assert (amo_state == AMO_IDLE && !o_amo_mem_write_en);
      end
      if ($past(amo_state == AMO_COMPUTE)) begin
        // Dead payload capture is intentional even on reset/recovery.
        p_local_compute_payload : assert (amo_write_data_q == $past(amo_compute_result));
      end
      if ($past(i_rst_n && !i_flush_all)) begin
        if ($past(amo_response_capture)) begin
          p_local_capture_old : assert (amo_old_value == $past(amo_response_old_value));
          p_local_capture_rs2 : assert (amo_minmax_rs2_q == $past(issued_amo_rs2));
          p_local_capture_kind : assert (amo_kind_q == $past(issued_amo_kind));
          p_local_capture_width : assert (amo_is_d_q == $past(issued_amo_is_d));
          p_local_capture_addr : assert (amo_write_addr_q == $past(issued_addr));
          p_local_capture_tier : assert (amo_write_is_cached_q == $past(f_amo_response_tier));
          p_local_capture_index : assert (amo_entry_idx == $past(issued_idx));
          p_local_capture_mode : assert (amo_is_minmax_q == $past(amo_response_is_minmax));
          if ($past(amo_response_is_minmax)) begin
            p_local_minmax_latency : assert (amo_state == AMO_WRITE_ACTIVE && o_amo_mem_write_en);
          end else begin
            p_local_normal_latency : assert (amo_state == AMO_COMPUTE && !o_amo_mem_write_en);
          end
        end
        if ($past(amo_state == AMO_COMPUTE)) begin
          p_local_compute_owner_hold :
          assert ({amo_old_value, amo_minmax_rs2_q,
              amo_kind_q, amo_is_d_q, amo_is_minmax_q, amo_write_addr_q,
               amo_write_is_cached_q, amo_entry_idx} ==
              $past(
              {amo_old_value, amo_minmax_rs2_q, amo_kind_q, amo_is_d_q,
              amo_is_minmax_q, amo_write_addr_q,
               amo_write_is_cached_q, amo_entry_idx}
          ));
          if ($past(amo_compute_owner_killed)) begin
            p_local_compute_kill : assert (amo_state == AMO_IDLE && !o_amo_mem_write_en);
          end else begin
            p_local_compute_activate : assert (amo_state == AMO_WRITE_ACTIVE && o_amo_mem_write_en);
          end
        end
        if ($past(amo_state == AMO_WRITE_ACTIVE && !i_amo_mem_write_done)) begin
          p_local_active_hold :
          assert (amo_state == AMO_WRITE_ACTIVE &&
              {amo_old_value, amo_write_data_q, amo_minmax_rs2_q, amo_kind_q,
               amo_is_d_q, amo_is_minmax_q, amo_write_addr_q,
               amo_write_is_cached_q, amo_entry_idx,
               amo_minmax_relation_d_q, amo_minmax_relation_w_q,
               amo_minmax_is_unsigned_q, amo_minmax_is_max_q} ==
              $past(
              {amo_old_value, amo_write_data_q, amo_minmax_rs2_q, amo_kind_q,
               amo_is_d_q, amo_is_minmax_q, amo_write_addr_q,
               amo_write_is_cached_q, amo_entry_idx,
               amo_minmax_relation_d_q, amo_minmax_relation_w_q,
               amo_minmax_is_unsigned_q, amo_minmax_is_max_q}
          ));
        end
      end
    end
    if (f_amo_past_valid[1] && $past(
            amo_response_capture && !amo_response_is_minmax, 2
        ) && $past(
            amo_compute_commit
        )) begin
      p_local_original_result : assert (amo_write_data_q == $past(f_amo_response_result, 2));
      cover_local_normal_active : cover (amo_state == AMO_WRITE_ACTIVE && o_amo_mem_write_en);
    end
  end
`else
  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  logic [DEPTH-1:0] f_lq_valid_q;
  logic             f_rst_n_q;
  logic             f_dispatch_exact_q;
  always @(posedge i_clk) begin
    f_lq_valid_q       <= lq_valid;
    f_rst_n_q          <= i_rst_n;
    f_dispatch_exact_q <= !free_entry_en && !i_flush_en && !i_flush_all;
  end

  logic [ReorderBufferTagWidth-1:0] f_pre_issue_rob_tag_q;
  logic                             f_pre_issue_needs_lq_q;
  always @(posedge i_clk) begin
    f_pre_issue_rob_tag_q  <= i_pre_issue_rob_tag;
    f_pre_issue_needs_lq_q <= i_pre_issue_needs_lq;
  end

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // Every SQ quarter must see the same address for a live staged probe.
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

  // Flush-cycle requests are legal but must not allocate, matching the ROB.
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
      p_slot1_dispatch_reservation_covers_alloc :
      assert (!slot1_alloc_en || dispatch_slot1_reserve);
      p_slot2_dispatch_reservation_covers_alloc :
      assert (!slot2_alloc_en || dispatch_slot2_reserve);
      p_dispatch_reservation_bounded : assert (dispatch_count_next <= CountWidth'(DEPTH));
      p_slot1_alloc_onehot0 : assert ($onehot0(slot1_alloc_oh));
      p_slot2_alloc_onehot0 : assert ($onehot0(slot2_alloc_oh));
      p_slot1_alloc_preserved : assert ((|slot1_alloc_oh) == slot1_alloc_en);
      p_slot2_alloc_preserved : assert ((|slot2_alloc_oh) == slot2_alloc_en);
      p_alloc_onehots_disjoint : assert (!(|(slot1_alloc_oh & slot2_alloc_oh)));
      p_alloc_oh_is_slot_union : assert (alloc_oh == (slot1_alloc_oh | slot2_alloc_oh));
      p_dispatch_full_next_reference :
      assert (dispatch_full_next == (dispatch_count_next == CountWidth'(DEPTH)));
      p_dispatch_full_for_2_next_reference :
      assert (dispatch_full_for_2_next == (dispatch_count_next >= CountWidth'(DEPTH - 1)));
`ifndef SYNTHESIS
      // The enable-then-steer references are declared outside synthesis.
      p_slot2_alloc_en_reference : assert (slot2_alloc_en == slot2_alloc_en_reference);
      p_slot2_alloc_oh_reference : assert (slot2_alloc_oh == slot2_alloc_oh_reference);
`endif
      if (free_entry_en && lq_valid[free_entry_idx]) begin
        p_freed_entry_not_slot1_alloc_target : assert (!slot1_alloc_oh[free_entry_idx]);
        p_freed_entry_not_slot2_alloc_target : assert (!slot2_alloc_oh[free_entry_idx]);
      end
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

  // Address updates may overlap flush. The CAM reads pre-edge validity, so a
  // killed entry may receive a payload write. Full flush clears control state;
  // partial flush clears killed entries' validity. Those writes stay hidden.

  // The registered address-update pre-match is driven by MEM_RS look-ahead one
  // cycle before the matching address update arrives.
  always_comb begin
    if (i_rst_n && i_addr_update.valid) begin
      assume (f_pre_issue_needs_lq_q);
      assume (i_addr_update.rob_tag == f_pre_issue_rob_tag_q);
    end
  end

  // The ROB allocates a unique tag per in-flight instruction, so two live LQ
  // entries cannot have the same producer tag.
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

  // A fast-tier response belongs either to the live outstanding read or to
  // the armed stale-response drain. A partial flush moves a killed request
  // from mem_outstanding to drop_mem_response_pending, so allowing the latter
  // case is necessary for formal to explore the late-drain behavior.
  // A cached response names a slot that was launched and not yet answered
  // (live or drop-marked): the router never answers a slot it canceled.
  always_comb begin
    if (i_mem_read_valid) begin
      if (i_mem_read_is_cached)
        assume (cs_valid[i_mem_read_id]);
        else assume (mem_outstanding || drop_mem_response_pending);
    end
  end

  // -------------------------------------------------------------------------
  // Combinational assertions
  // -------------------------------------------------------------------------

  // Capture raw .D/.W unsigned relations before width or mode selection for
  // timing. Explicit equality lets MAX distinguish GT from EQ afterward.
  always_comb begin
    if (i_rst_n && accept_mem_response && issued_is_amo) begin
      p_amo_relation_d_exact :
      assert (amo_response_minmax_relation_d == {
        XLEN'(i_mem_read_data) == issued_amo_rs2,
        XLEN'(i_mem_read_data) < issued_amo_rs2
      });
      p_amo_relation_w_exact :
      assert (amo_response_minmax_relation_w == {
        amo_beat_word[31:0] == issued_amo_rs2[31:0],
        amo_beat_word[31:0] < issued_amo_rs2[31:0]
      });
      p_amo_relation_d_legal : assert (amo_response_minmax_relation_d != 2'b11);
      p_amo_relation_w_legal : assert (amo_response_minmax_relation_w != 2'b11);

      case (issued_amo_kind)
        AMO_KIND_MIN: begin
          p_amo_min_is_minmax : assert (amo_response_is_minmax);
          p_amo_min_is_signed : assert (!amo_response_minmax_is_unsigned);
          p_amo_min_is_min : assert (!amo_response_minmax_is_max);
        end
        AMO_KIND_MAX: begin
          p_amo_max_is_minmax : assert (amo_response_is_minmax);
          p_amo_max_is_signed : assert (!amo_response_minmax_is_unsigned);
          p_amo_max_is_max : assert (amo_response_minmax_is_max);
        end
        AMO_KIND_MINU: begin
          p_amo_minu_is_minmax : assert (amo_response_is_minmax);
          p_amo_minu_is_unsigned : assert (amo_response_minmax_is_unsigned);
          p_amo_minu_is_min : assert (!amo_response_minmax_is_max);
        end
        AMO_KIND_MAXU: begin
          p_amo_maxu_is_minmax : assert (amo_response_is_minmax);
          p_amo_maxu_is_unsigned : assert (amo_response_minmax_is_unsigned);
          p_amo_maxu_is_max : assert (amo_response_minmax_is_max);
        end
        default: begin
          p_amo_non_minmax_identity : assert (!amo_response_is_minmax);
          p_amo_non_minmax_not_unsigned : assert (!amo_response_minmax_is_unsigned);
          p_amo_non_minmax_not_max : assert (!amo_response_minmax_is_max);
        end
      endcase
    end
  end

  // Once active, MIN/MAX derives the exact old-vs-rs2 selection only from
  // registered relations, mode, width, and operands. The reference functions
  // above use strict comparisons, so equality selects rs2 for both MIN and
  // MAX.
  always_comb begin
    if (i_rst_n && (amo_state == AMO_WRITE_ACTIVE)) begin
      p_amo_write_enabled : assert (o_amo_mem_write_en);
      if (amo_is_minmax_q) begin
        p_amo_active_relation_legal : assert (amo_minmax_selected_relation != 2'b11);
        if (amo_minmax_selected_relation[1]) begin
          p_amo_equality_selects_rs2 : assert (!amo_minmax_select_old_active);
        end
        unique case ({
          amo_minmax_is_unsigned_q, amo_minmax_is_max_q
        })
          2'b00: begin
            if (amo_is_d_q) begin
              p_amo_min_d_selection :
              assert (amo_minmax_select_old_active == amo_minmax_select_old(
                  AMO_KIND_MIN, amo_old_value, amo_minmax_rs2_q
              ));
            end else begin
              p_amo_min_w_selection :
              assert (amo_minmax_select_old_active == amo_minmax_select_old32(
                  AMO_KIND_MIN, amo_old_value[31:0], amo_minmax_rs2_q[31:0]
              ));
            end
          end
          2'b01: begin
            if (amo_is_d_q) begin
              p_amo_max_d_selection :
              assert (amo_minmax_select_old_active == amo_minmax_select_old(
                  AMO_KIND_MAX, amo_old_value, amo_minmax_rs2_q
              ));
            end else begin
              p_amo_max_w_selection :
              assert (amo_minmax_select_old_active == amo_minmax_select_old32(
                  AMO_KIND_MAX, amo_old_value[31:0], amo_minmax_rs2_q[31:0]
              ));
            end
          end
          2'b10: begin
            if (amo_is_d_q) begin
              p_amo_minu_d_selection :
              assert (amo_minmax_select_old_active == amo_minmax_select_old(
                  AMO_KIND_MINU, amo_old_value, amo_minmax_rs2_q
              ));
            end else begin
              p_amo_minu_w_selection :
              assert (amo_minmax_select_old_active == amo_minmax_select_old32(
                  AMO_KIND_MINU, amo_old_value[31:0], amo_minmax_rs2_q[31:0]
              ));
            end
          end
          2'b11: begin
            if (amo_is_d_q) begin
              p_amo_maxu_d_selection :
              assert (amo_minmax_select_old_active == amo_minmax_select_old(
                  AMO_KIND_MAXU, amo_old_value, amo_minmax_rs2_q
              ));
            end else begin
              p_amo_maxu_w_selection :
              assert (amo_minmax_select_old_active == amo_minmax_select_old32(
                  AMO_KIND_MAXU, amo_old_value[31:0], amo_minmax_rs2_q[31:0]
              ));
            end
          end
        endcase
        p_amo_minmax_write_mux :
        assert (amo_write_value ==
                (amo_minmax_select_old_active ? amo_old_value : amo_minmax_rs2_q));
        if (amo_is_d_q) begin
          p_amo_minmax_write_data_d :
          assert (o_amo_mem_write_data == riscv_pkg::MemDataBits'(amo_write_value));
        end else begin
          p_amo_minmax_write_data_w :
          assert (o_amo_mem_write_data == {(riscv_pkg::MemDataBits / 32) {amo_write_value[31:0]}});
        end
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

  // The registered dispatch flags may lag frees and partial flushes, but
  // they must never advertise more capacity than the exact valid mask.
  // The reset-history guard excludes only the unconstrained initial state.
  always_comb begin
    if (f_past_valid && i_rst_n && f_rst_n_q) begin
      p_dispatch_full_never_understates : assert (!full || dispatch_full_q);
      p_dispatch_full_for_2_never_understates : assert (!full_for_2 || dispatch_full_for_2_q);
      if (f_dispatch_exact_q) begin
        p_dispatch_full_exact_without_clear : assert (dispatch_full_q == full);
        p_dispatch_full_for_2_exact_without_clear : assert (dispatch_full_for_2_q == full_for_2);
      end
    end
  end

  // Unique live ROB tags make the registered head identity at most one-hot.
  always_comb begin
    if (i_rst_n) begin
      p_rob_head_match_onehot : assert ($onehot0(rob_head_match_q));
    end
  end

  // Aggregate the row-wise invariants before asserting them: Yosys flattens
  // procedural assertion labels inside loops, whereas each aggregate below
  // becomes one stable formal cell independent of DEPTH.
  logic f_older_amo_blocks_match_rows;
  logic f_invalid_dep_state_drained;
  always_comb begin
    f_older_amo_blocks_match_rows = 1'b1;
    f_invalid_dep_state_drained   = 1'b1;
    for (int unsigned i = 0; i < DEPTH; i++) begin
      f_older_amo_blocks_match_rows &= older_amo_block_q[i] == (|older_amo_dep_q[i]);
      if (!f_lq_valid_q[i]) begin
        f_invalid_dep_state_drained &= (older_amo_dep_q[i] == '0) && !older_amo_block_q[i];
      end
      f_invalid_dep_state_drained &= (older_amo_dep_q[i] & ~f_lq_valid_q) == '0;
    end
  end

  // The direct selector bits remain exact row reductions, including during
  // the one invalid cleanup cycle permitted after a partial flush.
  always_comb begin
    if (i_rst_n) begin
      p_older_amo_blocks_match_rows : assert (f_older_amo_blocks_match_rows);
    end
  end

  // An invalid pre-edge identity cannot carry dependency state across this
  // edge. This permits the first stale-high cycle after a partial flush (the
  // pre-edge identity was still valid), but proves both destination rows and
  // source columns drain during the complete invalid gap before reuse.
  always_comb begin
    if (f_past_valid && i_rst_n && f_rst_n_q) begin
      p_invalid_dep_state_drained : assert (f_invalid_dep_state_drained);
      p_replaced_dep_address_not_stored : assert ((dep_replaced_oh & lq_addr_valid) == '0);
      p_replaced_dep_address_not_pre_matched :
      assert ((dep_replaced_oh & addr_update_pre_match_q) == '0);
      p_replaced_dep_not_issued : assert ((dep_replaced_oh & lq_issued) == '0);
      p_replaced_dep_has_no_data : assert ((dep_replaced_oh & lq_data_valid) == '0);
      p_replaced_dep_not_in_sq_check : assert ((dep_replaced_oh & sq_check_in_flight_mask) == '0);
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

  // o_count matches an independent popcount of lq_valid
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

  // Memory launch uses the staged address, whose validity is sq_check_pending.
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

  // MMIO handoff requires ROB head. The router drains committed stores
  // before accepting the device read.
  always_comb begin
    if (i_rst_n && launch_mem_issue && sq_check_is_mmio_q) begin
      p_mmio_handoff_only_when_head : assert (sq_check_rob_tag_q == i_rob_head_tag);
    end
  end

  // A cached launch requires a free slot. AMOs capture the responding slot's
  // snapshot and fence younger loads through older_amo_block. The ROB must
  // have retired all older loads before an AMO reaches head; an unconstrained
  // i_rob_head_tag cannot establish that guarantee here.
  always_comb begin
    if (i_rst_n && cached_launch_hold_q) begin
      p_launch_hold_blocks_mem_handoff : assert (!o_mem_read_en);
    end
    if (i_rst_n && o_mem_read_en && launching_is_cached) begin
      p_cached_handoff_takes_free_slot : assert (!cs_valid[cs_alloc_idx]);
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
  // consume a staged result that the LQ is presenting.
  always_comb begin
    if (i_rst_n && !o_fu_complete.valid) begin
      a_result_accept_needs_valid : assume (!i_result_accepted);
    end
  end

  // No allocation request when full (the same condition assumed above)
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

  // A response may fill persistent L0 during the partial flush that kills its
  // load, but must not complete the killed entry.
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

  // The partial-flush kill above is the only condition removed from the
  // response-accept predicate. Every other L0 fill must still be an
  // architecturally accepted LQ response.
  always_comb begin
    if (i_rst_n && cache_fill_valid) begin
      p_fill_diverges_from_accept_only_for_kill :
      assert (issued_entry_flushed || accept_mem_response);
    end
  end

  // A drop-marked response must not change LQ or persistent-cache state.
  // The fast drop flag applies only to fast responses; cached slots have
  // their own flags.
  always_comb begin
    if (i_rst_n && drop_mem_response_pending && !resp_from_slot) begin
      p_pending_drain_not_accepted : assert (!accept_mem_response);
      p_pending_drain_does_not_fill_l0 : assert (!cache_fill_valid);
    end
    if (i_rst_n && resp_from_slot && cs_drop[resp_slot]) begin
      p_slot_drain_not_accepted : assert (!accept_mem_response);
      p_slot_drain_does_not_fill_l0 : assert (!cache_fill_valid);
    end
  end

  // -------------------------------------------------------------------------
  // Sequential assertions
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin

      // A cached launch reserves its slot and captures its snapshot together.
      // Only its response normally releases the slot.
      if ($past(o_mem_read_en && launching_is_cached)) begin
        p_cached_handoff_sets_slot : assert (cs_valid[$past(cs_alloc_idx)]);
      end
      if ($past(
              (accept_mem_response || drop_mem_response_now) && resp_from_slot
          ) && !$past(
              o_mem_read_en && launching_is_cached && (cs_alloc_idx == resp_slot)
          )) begin
        p_cached_response_frees_slot : assert (!cs_valid[$past(resp_slot)]);
      end

      // Response capture retains the LQ index and operands. Ordinary arithmetic
      // uses one COMPUTE cycle; MIN/MAX activates writing in the next cycle.
      if ($past(amo_response_capture)) begin
        p_amo_old_capture : assert (amo_old_value == $past(amo_response_old_value));
        p_amo_entry_capture : assert (amo_entry_idx == $past(issued_idx));
        p_amo_addr_capture : assert (amo_write_addr_q == $past(issued_addr));
        p_amo_operation_capture : assert (amo_kind_q == $past(issued_amo_kind));
        p_amo_rs2_capture : assert (amo_minmax_rs2_q == $past(issued_amo_rs2));
        p_amo_width_capture : assert (amo_is_d_q == $past(issued_amo_is_d));
        p_amo_kind_capture : assert (amo_is_minmax_q == $past(amo_response_is_minmax));
        p_amo_relation_d_capture :
        assert (amo_minmax_relation_d_q == $past(amo_response_minmax_relation_d));
        p_amo_relation_w_capture :
        assert (amo_minmax_relation_w_q == $past(amo_response_minmax_relation_w));
        p_amo_unsigned_mode_capture :
        assert (amo_minmax_is_unsigned_q == $past(amo_response_minmax_is_unsigned));
        p_amo_max_mode_capture : assert (amo_minmax_is_max_q == $past(amo_response_minmax_is_max));
        if ($past(amo_state == AMO_IDLE) && !i_flush_all) begin
          if ($past(amo_response_is_minmax)) begin
            p_amo_minmax_enters_write_active :
            assert ((amo_state == AMO_WRITE_ACTIVE) && o_amo_mem_write_en);
          end else begin
            p_amo_normal_enters_compute :
            assert ((amo_state == AMO_COMPUTE) && !o_amo_mem_write_en);
          end
        end
      end

      if ($past(amo_compute_commit) && !i_flush_all) begin
        p_amo_compute_enters_write_active : assert (amo_state == AMO_WRITE_ACTIVE);
        p_amo_compute_result_capture : assert (amo_write_data_q == $past(amo_compute_result));
      end
      if ($past(amo_state == AMO_COMPUTE && amo_compute_owner_killed && !i_flush_all)) begin
        p_amo_compute_kill_cancels : assert (amo_state == AMO_IDLE);
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
        p_amo_stall_operation_stable : assert (amo_kind_q == $past(amo_kind_q));
        p_amo_stall_width_stable : assert (amo_is_d_q == $past(amo_is_d_q));
        p_amo_stall_kind_stable : assert (amo_is_minmax_q == $past(amo_is_minmax_q));
        p_amo_stall_relation_d_stable :
        assert (amo_minmax_relation_d_q == $past(amo_minmax_relation_d_q));
        p_amo_stall_relation_w_stable :
        assert (amo_minmax_relation_w_q == $past(amo_minmax_relation_w_q));
        p_amo_stall_unsigned_mode_stable :
        assert (amo_minmax_is_unsigned_q == $past(amo_minmax_is_unsigned_q));
        p_amo_stall_max_mode_stable : assert (amo_minmax_is_max_q == $past(amo_minmax_is_max_q));
        p_amo_stall_selection_stable :
        assert (amo_minmax_select_old_active == $past(amo_minmax_select_old_active));
        p_amo_stall_write_en_stable : assert (o_amo_mem_write_en == $past(o_amo_mem_write_en));
        p_amo_stall_write_addr_stable :
        assert (o_amo_mem_write_addr == $past(o_amo_mem_write_addr));
        p_amo_stall_write_data_stable :
        assert (o_amo_mem_write_data == $past(o_amo_mem_write_data));
        p_amo_stall_write_width_stable :
        assert (o_amo_mem_write_is_dword == $past(o_amo_mem_write_is_dword));
        p_amo_stall_write_tier_stable :
        assert (o_amo_mem_write_is_cached == $past(o_amo_mem_write_is_cached));
      end

      // The registered tier flag never disagrees with the presented address
      // while the write is active: it captures from issued_addr on the same
      // edge, under the same enable, and is gated by the same state as
      // o_amo_mem_write_addr (idle forces it low). The staged PMA check keeps
      // every AMO write inside BRAM and the cached tier.
      if (o_amo_mem_write_en) begin
        p_amo_write_tier_flags_match_addr :
        assert (o_amo_mem_write_is_cached == is_cached_addr(o_amo_mem_write_addr));
        p_amo_write_atomic_map : assert (riscv_pkg::pma_atomic_ok(o_amo_mem_write_addr));
      end
      if (!o_amo_mem_write_en) begin
        p_amo_write_tier_flags_idle_low : assert (!o_amo_mem_write_is_cached);
      end

      // Allocation writes a valid entry at the target the free search chose.
      // A flush on either cycle is excluded: a full flush resets the pointers
      // and a partial flush invalidates entries.
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
        // The fast tier's pending drop is cleared only by the fast tier's own
        // response on the flush edge; a cached slot's response that cycle is
        // unrelated.
        p_flush_all_response_debt_equivalent :
        assert (drop_mem_response_pending == (($past(
            drop_mem_response_pending
        ) || ($past(
            mem_outstanding
        ) && !$past(
            i_mem_request_pending
        ))) && !$past(
            fast_resp_now
        )));
      end
      if ($past(
              i_flush_all && mem_outstanding && i_mem_request_pending &&
                !drop_mem_response_pending && !i_mem_read_valid
          )) begin
        p_flush_canceled_router_pending_has_no_response_debt : assert (!drop_mem_response_pending);
      end
      if ($past(
              i_flush_all && mem_outstanding && !i_mem_request_pending && !i_mem_read_valid
          )) begin
        p_flush_accepted_read_keeps_response_debt : assert (drop_mem_response_pending);
      end
      // A cached slot whose request the router still held (and canceled) is
      // freed by the full flush; every other live slot stays, drop-marked.
      if ($past(i_flush_all && i_mem_request_pending && last_launch_cached_q)) begin
        p_flush_canceled_cached_slot_freed : assert (!cs_valid[$past(last_launch_slot_q)]);
      end
      if ($past(i_flush_all)) begin
        p_flush_all_drops_every_live_slot : assert (cs_drop == cs_valid);
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
      cover_flush_cancels_router_pending :
      cover (i_flush_all && mem_outstanding && i_mem_request_pending);
      cover (i_flush_all && i_mem_request_pending && last_launch_cached_q &&
             cs_valid[last_launch_slot_q]);
      cover_flush_keeps_accepted_response_debt :
      cover (i_flush_all && mem_outstanding && !i_mem_request_pending && !i_mem_read_valid);

      // Cover a partial flush that kills an outstanding load. Stop before the
      // response arrives to limit solver complexity.
      cover_stale_drain : cover (issued_entry_flushed);

      cover_partial_flush_reclaims : cover ($past(i_flush_en) && i_alloc.valid && !full);

      // L0 cache hit fast path delivers data without memory issue
      cover_cache_hit : cover (cache_hit_fast_path);

      // L0 cache fill on memory response
      cover_cache_fill : cover (cache_fill_valid);

      // Exercise split response relations, exact equality, and a held write.
      cover_amo_minmax_response : cover (amo_response_capture && amo_response_is_minmax);
      cover_amo_minmax_equal_w :
      cover (amo_response_capture && amo_response_is_minmax && !issued_amo_is_d &&
             amo_response_minmax_relation_w[1]);
      cover_amo_minmax_equal_d :
      cover (amo_response_capture && amo_response_is_minmax && issued_amo_is_d &&
             amo_response_minmax_relation_d[1]);
      cover_amo_minmax_stall :
      cover ((amo_state == AMO_WRITE_ACTIVE) && amo_is_minmax_q && !i_amo_mem_write_done);
    end
  end

`endif  // LQ_AMO_COMPUTE_LOCAL_PROOF
`endif  // F_LQ_PREMATCH_ONLY
`endif  // FORMAL

endmodule : load_queue
