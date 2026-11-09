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

`include "coherence_types.svh"

// Eight CPU read slots and four ordered store records share request endpoints.
// Endpoint 0 serves the head store, LR, SC and AMOs. Nonzero endpoints serve
// ordinary load misses and optional speculative GetS requests. At most one is
// lent to a younger store; every store installs at the head.
module coherence_l1d #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned CACHE_BYTES = 128 * 1024,
    parameter int unsigned WAYS = 4,
    parameter int unsigned TAG_BITS = 7,
    // Request endpoints. With one endpoint, endpoint 0 serves every acquisition.
    // Ordinary loads use endpoints 1 to MISSES-1; stores can borrow one when MISSES >= 3.
    parameter int unsigned MISSES = 1,
    parameter int unsigned HOME_CACHE_BYTES = 2 * 1024 * 1024,
    parameter int unsigned HOME_WAYS = 4,
    parameter int unsigned HOME_LINE_BYTES = 64,
    parameter bit STREAM_PREFETCH = 1'b0,
    parameter int unsigned SIM_FAST_MAINT = 0,
    localparam int unsigned WayBits = WAYS > 1 ? $clog2(WAYS) : 1,
    localparam int unsigned Sets = CACHE_BYTES / (32 * WAYS),
    localparam int unsigned SetBits = $clog2(Sets)
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,
    input logic i_read_valid,
    input logic [2:0] i_read_id,
    input logic [1:0] i_read_kind,
    input logic [2:0] i_read_size,
    input logic [TAG_BITS-1:0] i_read_tag,
    input logic [ADDR_WIDTH-1:0] i_address,
    output logic o_read_valid,
    input logic i_read_ready,
    output logic [2:0] o_read_id,
    output logic [63:0] o_read_data,
    output logic o_read_error,
    input logic [7:0] i_write_mask,
    input logic [63:0] i_write_data,
    input logic i_write_atomic,
    input logic i_write_sc,
    input logic [TAG_BITS-1:0] i_write_tag,
    output logic o_write_done,
    output logic o_write_inflight,
    output logic o_store_ready,
    output logic o_pending_store,
    output logic o_sc_write_pending,
    output logic o_atomic_live,
    output logic [3:0] o_block_valid,
    output logic [3:0][ADDR_WIDTH-1:0] o_block_addr,
    // Protection covers request presentation as well as acceptance.
    input logic i_atomic_protected,
    input logic i_sc_valid,
    output logic o_sc_ready,
    input logic [ADDR_WIDTH-1:0] i_sc_address,
    input logic [2:0] i_sc_size,
    input logic [TAG_BITS-1:0] i_sc_tag,
    input logic i_sc_commit,
    output logic o_sc_result_valid,
    input logic i_sc_result_ready,
    output logic o_sc_success,
    output logic o_sc_error,
    output logic o_sc_write_done,
    output logic [TAG_BITS-1:0] o_sc_write_tag,
    input logic i_reservation_valid,
    input logic [ADDR_WIDTH-1:0] i_reservation_addr,
    input logic [2:0] i_reservation_size,
    input logic i_maint_valid,
    input logic i_maint_line,
    input logic [ADDR_WIDTH-1:0] i_maint_address,
    output logic o_maint_done,
    output logic o_cut_hold,
    output logic o_cut_admit_valid,
    input logic i_cut_admit_ready,
    // With i_cut_admit_ready: the CPU holds nothing for the line, so the cut
    // skips the CPU invalidation and its wait.
    input logic i_cut_admit_clean = 1'b0,
    output logic [ADDR_WIDTH-1:0] o_cut_address,
    output logic o_cut_inval_valid,
    input logic i_cut_inval_done,
    output logic o_cut_release,
    output logic [MISSES-1:0] o_d_valid,
    input logic [MISSES-1:0] i_d_ready,
    output logic [MISSES-1:0][ADDR_WIDTH+311:0] o_d,
    input logic i_p_valid,
    output logic o_p_ready,
    input logic [ADDR_WIDTH+29:0] i_p,
    output logic o_r_valid,
    input logic i_r_ready,
    output logic [ADDR_WIDTH+274:0] o_r,
    output logic o_w_valid,
    input logic i_w_ready,
    output logic [ADDR_WIDTH+259:0] o_w,
    input logic i_wa_valid,
    output logic o_wa_ready,
    input logic [ADDR_WIDTH+10:0] i_wa,
    input logic i_g_valid,
    output logic o_g_ready,
    input logic [ADDR_WIDTH+274:0] i_g,
    output logic [MISSES-1:0] o_c_valid,
    input logic [MISSES-1:0] i_c_ready,
    output logic [MISSES-1:0][ADDR_WIDTH+17:0] o_c,
    input logic i_u_valid,
    output logic o_u_ready,
    input logic [ADDR_WIDTH+14:0] i_u,
    output cache_perf_pkg::cache_instance_perf_events_t o_perf_events,
`ifdef LOCAL_ATOMIC_DEPENDENCY
    output wire o_formal_local,
    output wire [3:0] o_formal_phase,
    output wire o_formal_home_write,
`endif
    output logic o_fatal,
    output logic [ADDR_WIDTH-1:0] o_fatal_addr
);
`ifndef SYNTHESIS
  // Registers power up arbitrary and the reset can reach this module a few
  // cycles after the first edge, so the simulation checks begin at the first
  // reset.
`ifdef FORMAL
  // Formal tasks start from a reset or from an induction state; the checks
  // apply in both.
  wire sim_reset_seen_q = 1'b1;
`else
  logic sim_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) sim_reset_seen_q <= 1'b1;
`endif
`endif
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  localparam logic [1:0] ReadLoad = 0, ReadLR = 1, ReadAMO = 2;
  typedef enum logic [3:0] {
    Idle,
    Lookup,
    LookupWait,
    Acquire,
    Freeze,
    Update,
    UpdateWait,
    ProbeAbsorb,
    ProbeReply,
    LocalCheck,
    LocalReadReady,
    LocalWaitWrite,
    LocalMerge,
    LocalRelease,
    LocalFail
  } phase_t;
  typedef enum logic [2:0] {
    CutIdle,
    CutAdmit,
    CutInvalidate,
    CutWait,
    CutDone
  } cut_phase_t;
  typedef enum logic [3:0] {
    ReadOp,
    StoreOp,
    GrantOp,
    ProbeOp,
    MaintOp,
    AtomicWriteOp,
    SCOp,
    PrefetchOp,
    LookaheadOp
  } operation_t;
  // One-hot state keeps each transition, including the W-dependent probe
  // absorption, to a single term of its next state.
  (* fsm_encoding = "one_hot" *) phase_t phase_q;
  cut_phase_t cut_phase_q;
  operation_t operation_q;
  logic active;
  logic [7:0] rd_valid_q, rd_ready_q, rd_miss_q;
  logic [ADDR_WIDTH-1:0] rd_addr_q[8];
  logic [1:0] rd_kind_q[8];
  logic [2:0] rd_size_q[8];
  logic [TAG_BITS-1:0] rd_tag_q[8];
  localparam int unsigned ReadPayloadWidth = ADDR_WIDTH + TAG_BITS + 5;
  logic [8*ReadPayloadWidth-1:0] rd_payload_flat, rd_stored_payload_flat;
  logic [ReadPayloadWidth-1:0] rd_write_payload;
  logic [7:0] rd_write_mask;
  logic [63:0] rd_data_q[8];
  // A failed read returns zero data. Its data register clears and its status
  // sets on the cycle after the failure, from these registers, so neither
  // reads the grant selection.
  logic fail_clear_q, fail_error_q;
  logic [2:0] fail_clear_slot_q;
  logic [7:0] rd_error_q, rd_ready_next, rd_error_next, rd_valid_next, rd_miss_next, rd_complete;
  logic read_miss;
  logic read_failure, read_hit, read_fill;
  // A load endpoint's grant answers its read once, in the grant's first
  // Lookup cycle, from grant_q; installation follows.
  logic grant_answer, grant_answered_q;
  logic rd_candidate, rd_response, rd_load_miss;
  logic [2:0] rd_pick, rd_result, rd_rr_q, rd_response_rr_q, selected_read_q;
  logic pending_q, pending_miss_q;
  logic store_push, store_pop, store_credit, store_ack, tail_q;
  localparam int unsigned EpBits = MISSES > 1 ? $clog2(MISSES) : 1;
  localparam int unsigned HomeOffset = $clog2(HOME_LINE_BYTES);
  localparam int unsigned HomeSets = HOME_CACHE_BYTES / (HOME_LINE_BYTES * HOME_WAYS);
  localparam int unsigned HomeSetBits = HomeSets > 1 ? $clog2(HomeSets) : 1;
  logic [2:0] store_count;
  logic [1:0] store_head_index, store_next_index, store_selected_q;
  logic [3:0] store_valid, store_sealed, store_acquired, store_checked_q;
  logic [3:0][ADDR_WIDTH-1:0] store_addr;
  logic [3:0][255:0] store_data;
  logic [3:0][31:0] store_mask;
  logic [3:0][TAG_BITS-1:0] store_tag;
  logic [3:0][5:0] store_contributors;
  logic [3:0][EpBits-1:0] store_ep;
  logic store_seal, store_acquire, store_head_ready;
  logic look_found, look_valid_q, look_available, look_ready, borrowed_live, look_read_turn_q;
  logic look_priority_q, read_yield_look, look_retry;
  logic [1:0] look_priority_index_q;
  logic [1:0] look_index, look_index_q;
  logic [ADDR_WIDTH-1:0] look_addr_q;
  logic [3:0] look_blocked;
  logic [3:0][3:0] look_pair_conflict_q;
  logic [3:0] look_owner_conflict, look_owner_conflict_q, look_other_row_q;
  logic look_snapshot_valid_q;
  logic [TAG_BITS-1:0] pending_tag;
  logic [ADDR_WIDTH-1:0] tail_addr;
  logic tail_wb_blocked, tail_wb_blocked_q, tail_checked_q;
  logic store_continue, atomic_done_q;
  logic store_read_turn_q, read_waiting_q;
  logic read_service_waiting, load_grant_eligible;
  logic [31:0] update_mask_q;
  logic array_skip_data, array_data_valid;
  logic [ADDR_WIDTH-1:0] pending_addr_q;
  logic [255:0] pending_data_q;
  logic [31:0] pending_mask_q;
  logic atomic_q, atomic_sc_q, atomic_granted_q, atomic_written_q;
  logic atomic_local_q, sc_home_q, local_hit_q, local_conflict_q;
  logic local_admit, local_decision, local_sc_match, lookup_wb_conflict;
  logic [2:0] atomic_read_q;
  logic [7:0] rd_local_retry_q;
  logic sc_committed_q;
  logic [ADDR_WIDTH-1:0] atomic_addr_q;
  logic [2:0] atomic_size_q;
  logic [TAG_BITS-1:0] atomic_tag_q;
  logic atomic_write_q;
  logic [255:0] atomic_data_q;
  logic [31:0] atomic_mask_q;
  logic [WayBits-1:0] atomic_way_q;
  logic sc_checked_q;
  logic [5:0] sc_tid_q;
  logic maint_q, maint_turn_q, maint_eligible;
  logic maint_line_q;
  logic [ADDR_WIDTH-1:0] maint_addr_q;
  logic [SetBits-1:0] maint_set_q;
  logic [WayBits-1:0] maint_way_q;
  logic maint_last_q;
  // probe_valid_q selects the cut address on its way to the load queue's
  // fill checks; replicas keep each copy's load small.
  (* max_fanout = 32 *) logic probe_valid_q;
  logic probe_absorbed_q, probe_put_q;
  logic probe_capture, probe_launch, probe_reply_eligible;
  logic local_ready, local_turn_q, probe_priority;
  logic [1:0] read_probe_count_q;
  logic [ADDR_WIDTH-1:0] array_request_addr;
  coh_p_t probe_in, probe_q;
  coh_r_t  reply_q;
  coh_wa_t ack;
  logic [1:0] wb_live, wb_valid, wb_ready, wb_freeze_ready, wb_absorb_ready, wb_absorb_offer;
  logic [1:0] wb_wa_ready, wb_fatal, wb_absorbed;
  logic [1:0][ADDR_WIDTH+259:0] wb;
  logic [1:0][  ADDR_WIDTH-1:0] wb_addr;
  coh_w_t fatal_put, probe_put;
  assign fatal_put = wb[wb_fatal[0] ? 0 : 1];
  assign probe_put = wb[probe_put_q];
  coh_w_t freeze;
  logic wb_free, wb_free_slot, wb_match, wb_match_slot;
  logic wb_selected_q, wb_select_q, wb_next_q, reserved_wb_q;
  logic [ADDR_WIDTH-1:0] lookup_addr_q;
  logic [255:0] image_q;
  logic [1:0] state_q;
  logic [WayBits-1:0] way_q;
  logic [ADDR_WIDTH-1:0] update_addr_q, freeze_addr_q;
  logic [255:0] freeze_data_q;
  logic freeze_slot_q, freeze_maintenance_q;
  logic array_ready, array_valid, array_hit, array_available, update_ready;
  logic [WayBits-1:0] array_way;
  logic [ADDR_WIDTH-1:0] array_addr;
  logic [255:0] array_data;
  logic [1:0] array_state;
  logic [WAYS-1:0] exclude;
  logic request_live;
  coh_d_t acquisition_q, acquisition;
  // Endpoint k's identity carries SLOT k. live, grants and done handshakes are
  // per endpoint; endpoint 0 also keeps the SC and atomic registers.
  localparam bit Multi = MISSES > 1;
  // Per-endpoint state is padded to every index EpBits can name; unused
  // entries are idle constants.
  localparam int unsigned EpSlots = 1 << EpBits;
  logic [EpSlots-1:0] live, ep_request_ready, ep_request_valid, ep_grant_valid, ep_grant_ready;
`ifdef READ_OWNER_PROOF
  logic [6:0] f_ep_phase[EpSlots];
`endif
  logic [EpSlots-1:0] ep_done_valid, ep_write_done, ep_g_ready, ep_u_ready;
  logic [EpSlots-1:0][1:0] ep_done_status;
  logic [EpSlots-1:0][ADDR_WIDTH+274:0] ep_grant;
  logic [EpBits-1:0] acq_ep_q, grant_ep_q, grant_pick;
  logic any_live;
  logic [EpSlots-1:0] ep_store, ld_store_q, grant_offer;
  logic [EpSlots-1:0] store_grant_head_q;
  logic [1:0] store_grant_index;
  logic grant_is_store, selected_grant_store;
  logic [EpSlots-1:1] grant_other_first;
  (* keep = "true" *) logic grant_failure, grant_error;
  logic store_zero_alloc;
  logic [ADDR_WIDTH-1:0] block_zero_addr_q;
  logic wb_reserved_q;
  // Nonzero endpoint identity and completion state, used when MISSES > 1.
  logic [ADDR_WIDTH-6:0] ld_line_q[EpSlots];
  logic [2:0] ld_read_q[EpSlots];
  logic [EpSlots-1:0] ld_done_q, installed_q, same_line_q, ld_prefetch_q;
  logic grant_prefetch_q;
  logic [1:0] ld_status_q[EpSlots];
  logic same_line, store_same_line_q, load_ep_free, load_block, amo_waiting, wait_attach;
  logic load_grant_waiting, ep0_wb_ok, drain_q;
  logic load_ep_free_next, grant_install, wait_attach_live;
  logic [EpSlots-1:0] ep_release, ep_failed, ep_failed_q, ep_install, ep_wait_install, ep_accept;
  logic [3:0] retry_credit;
  logic [EpBits-1:0] same_line_ep, load_ep_index;
  logic [7:0] rd_wait_q, rd_wait_release_q, rd_waiting, rd_owned, rd_ep_owned, rd_miss_retry;
  logic [7:0] rd_atomic_retry_q, rd_owned_q, rd_owner_set, rd_owner_clear;
  logic fail_owner_q;
  logic [EpBits-1:0] rd_wait_ep_q[8];
  logic [2:0] fill_read_slot, failure_read_slot;
  // The selected grant as a one-hot, and each endpoint's failing-read and
  // error bits, so a failure reaches read status without the wide grant
  // multiplexer.
  logic [EpSlots-1:0] pick_onehot, ep_read_fail, ep_fail, ep_fail_error;
  logic acquisition_store_q, acquisition_sc_q;
  logic [2:0] acquisition_read_q;
  logic grant_valid, grant_ready, grant_read_failure, zero_grant_failed;
  logic grant_read_turn_q, grant_retry_q, grant_read_hold, grant_read_yield, load_acquire_block;
  logic atomic_sc_selected, read_selected, acquire_ready;
  logic [ADDR_WIDTH-1:0] lookup_other;
  (* keep = "true" *) logic lookup_other_valid;
  logic grant_demand_waiter, grant_touch_q;
  coh_g_t grant, grant_q;
  logic done_q, done_ready, written_q;
  logic [1:0] done_status_q;
  logic pending_blocked;
  // The selected read's kind, registered in Lookup, so the lookup's decisions
  // in LookupWait start at a flop. A slot is not reallocated while it is
  // looked up.
  logic [1:0] selected_kind_q;
  // The hit path (see its section below the array).
  logic path_req_q, path_offer, path_ready, path_take, path_blocked, path_hit;
  logic [2:0] path_id_q;
  logic [ADDR_WIDTH-1:0] path_addr_q;
  logic s2_valid_q, s3_valid_q, s4_valid_q;
  logic [2:0] s2_slot_q, s3_slot_q, s4_slot_q;
  logic [ADDR_WIDTH-1:5] s2_line_q, s3_line_q;
  logic [7:0] path_owned, path_select_owned;
  logic [63:0] path_data;
  logic prev_idle_q, first_lookup, shadow_now, shadow_q, path_hit_q, shadow_req, shadow_skip;
  logic demand_report, path_queue_push, path_queue_pop;
  logic [1:0] path_queue_valid_q, path_queue_valid_next;
  logic [1:0][ADDR_WIDTH-6:0] path_queue_q, path_queue_next;

  assign read_failure = grant_ready && grant_read_failure;
  // A shadow lookup answers nothing when the hit path or the tags hit.
  assign shadow_skip = shadow_q && (path_hit_q || array_hit);
  assign read_hit = active && ((phase_q == LookupWait && array_valid &&
      operation_q == ReadOp && selected_kind_q != ReadAMO && array_hit && !shadow_q) ||
      phase_q == LocalReadReady);
  assign read_miss = active && phase_q == LookupWait && array_valid &&
      operation_q == ReadOp && !(shadow_q && path_hit_q) &&
      (selected_kind_q == ReadAMO || !array_hit);
  // Endpoint 0's reads (LR, AMO, and loads with one endpoint) answer after
  // installation.
  assign grant_answer = active && phase_q == Lookup && operation_q == GrantOp &&
      grant_ep_q != '0 && !selected_grant_store && !grant_prefetch_q && !grant_answered_q;
  assign read_fill = grant_answer || (active && phase_q == UpdateWait && array_ready &&
      operation_q == GrantOp && grant_ep_q == '0 && !selected_grant_store &&
      !acquisition_sc_q);

  coherence_read_flags read_flags (
      .i_valid(rd_valid_q),
      .i_miss(rd_miss_q),
      .i_ready(rd_ready_q),
      .i_error(rd_error_q),
      .i_allocate_valid(i_read_valid),
      .i_allocate_id(i_read_id),
      .i_response_valid((!o_read_valid || i_read_ready) && rd_response),
      .i_response_id(rd_result),
      .i_failure_valid(fail_clear_q),
      .i_failure_id(fail_clear_slot_q),
      .i_failure_error(fail_error_q),
      .i_hit_valid(read_hit),
      .i_hit_id(phase_q == LocalReadReady ? atomic_read_q : selected_read_q),
      .i_fill_valid(read_fill),
      .i_fill_id(fill_read_slot),
      .i_miss_valid(read_miss && !wait_attach),
      .i_path_valid(s4_valid_q),
      .i_path_id(s4_slot_q),
      .o_complete(rd_complete),
      .o_valid(rd_valid_next),
      .o_miss(rd_miss_next),
      .o_ready(rd_ready_next),
      .o_error(rd_error_next)
  );

  coherence_read_payload #(
      .WIDTH(ReadPayloadWidth)
  ) read_payload (
      .i_clk,
      .i_rst,
      .i_allocate(i_read_valid),
      .i_allocate_id(i_read_id),
      .i_payload({i_address, i_read_kind, i_read_size, i_read_tag}),
      .o_payload(rd_payload_flat),
      .o_stored_payload(rd_stored_payload_flat),
      .o_write_payload(rd_write_payload),
      .o_write_mask(rd_write_mask)
  );
  for (genvar slot = 0; slot < 8; slot++) begin : gen_unpack_read_payload
    assign {rd_addr_q[slot], rd_kind_q[slot], rd_size_q[slot], rd_tag_q[slot]} =
        rd_payload_flat[slot*ReadPayloadWidth+:ReadPayloadWidth];
  end
  always_ff @(posedge i_clk) if (phase_q == Lookup) selected_kind_q <= rd_kind_q[selected_read_q];

  // Reset clears the controller at its flops. A fatal stop reaches the
  // controller through this flop, so no selection or capture enable starts at
  // the fatal logic. Both stop inputs stay set until reset, and a stop takes
  // effect on the cycle after it rises.
  always_ff @(posedge i_clk) begin
    if (i_rst) active <= 1'b1;
    else active <= !i_fatal_stop && !o_fatal;
  end
  assign probe_in = i_p;
  assign ack = i_wa;
  // The first scalar in a store record contributes a lookup decision. Each
  // combined scalar contributes a buffer hit, including during a tag event.
  // Retries, probes and maintenance do not contribute demand events.
  logic [7:0] perf_read_seen_q, perf_read_miss_q;
  logic [3:0] perf_store_seen_q;
  logic perf_lookup, perf_access, perf_hit, perf_sc, store_combined;
  logic [cache_perf_pkg::MissOutstandingBits-1:0] perf_outstanding;
  assign perf_lookup = (active && phase_q == LookupWait && array_valid &&
      ((operation_q == ReadOp && selected_kind_q != ReadAMO &&
        !perf_read_seen_q[selected_read_q] && !shadow_skip) ||
       (operation_q == StoreOp && !pending_miss_q && !perf_store_seen_q[store_head_index]) ||
       (operation_q == LookaheadOp && !perf_store_seen_q[store_selected_q]))) ||
      (local_decision && operation_q == ReadOp && !perf_read_seen_q[selected_read_q]);
  assign perf_sc = local_decision && operation_q == SCOp;
  assign perf_access = perf_lookup || perf_sc;
  assign perf_hit = (local_decision && local_hit_q && (perf_lookup || perf_sc)) ||
      (perf_lookup && phase_q == LookupWait && array_hit &&
       ((operation_q != StoreOp && operation_q != LookaheadOp) ||
        array_state == coherence_pkg::Modified));
  always_comb begin
    perf_outstanding = cache_perf_pkg::MissOutstandingBits'(
        pending_q && pending_miss_q && !store_acquired[store_head_index]);
    for (int record = 0; record < 4; record++)
      perf_outstanding += cache_perf_pkg::MissOutstandingBits'(
          store_valid[record] && store_acquired[record]);
    for (int slot = 0; slot < 8; slot++)
      perf_outstanding += cache_perf_pkg::MissOutstandingBits'(
          rd_valid_q[slot] && !rd_ready_q[slot] && perf_read_miss_q[slot]);
    perf_outstanding += cache_perf_pkg::MissOutstandingBits'(
        atomic_q && atomic_sc_q && sc_home_q && !atomic_granted_q && !o_sc_result_valid);
  end
  // Allocation clears a slot's lookup history after its lookup update.
  for (genvar slot = 0; slot < 8; slot++) begin : gen_perf_read_flags
    wire lookup = perf_lookup && operation_q == ReadOp && selected_read_q == 3'(slot);
    (* keep = "true" *) logic [1:0] seen_choice, miss_choice;
    for (genvar allocated = 0; allocated < 2; allocated++) begin : gen_allocate_choice
      wire clear_slot = allocated != 0 && i_read_id == 3'(slot);
      assign seen_choice[allocated] = !clear_slot && (perf_read_seen_q[slot] || lookup);
      assign miss_choice[allocated] = !clear_slot &&
          (lookup ? !perf_hit : perf_read_miss_q[slot]);
    end
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        perf_read_seen_q[slot] <= 1'b0;
        perf_read_miss_q[slot] <= 1'b0;
      end else begin
        perf_read_seen_q[slot] <= seen_choice[i_read_valid];
        perf_read_miss_q[slot] <= miss_choice[i_read_valid];
      end
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      perf_store_seen_q <= '0;
      o_perf_events <= '0;
    end else begin
      for (int slot = 0; slot < 4; slot++)
        if (!store_valid[slot] || (store_pop && store_head_index == 2'(slot)))
          perf_store_seen_q[slot] <= 1'b0;
      if (perf_lookup && (operation_q == StoreOp || operation_q == LookaheadOp))
        perf_store_seen_q[store_selected_q] <= 1'b1;
      o_perf_events <= '0;
      o_perf_events.store_combined <= store_combined;
      o_perf_events.store_combined_under_miss <= store_combined && perf_outstanding != 0;
      o_perf_events.access <= perf_access;
      o_perf_events.hit <= perf_hit;
      o_perf_events.miss <= perf_access && !perf_hit;
      o_perf_events.miss_outstanding <= perf_outstanding;
      o_perf_events.hit_under_miss <= perf_hit && perf_outstanding != 0;
      o_perf_events.path_hit <= s4_valid_q;
      o_perf_events.path_hit_under_miss <= s4_valid_q && perf_outstanding != 0;
      o_perf_events.writeback <= active && phase_q == Freeze &&
          wb_freeze_ready[freeze_slot_q] && !freeze_maintenance_q;
      o_perf_events.slot_full_stall <= active && phase_q == LookupWait && array_valid &&
          (operation_q == StoreOp || operation_q == ReadOp) && !array_hit &&
          !(shadow_q && path_hit_q) &&
          (!Multi ? (request_live || !wb_free) : operation_q == StoreOp ?
           (request_live || !ep0_wb_ok || store_same_line_q) :
           selected_kind_q == ReadLR ?
           (same_line || request_live || !ep0_wb_ok || load_block) :
           selected_kind_q == ReadAMO ? (any_live || !wb_free) :
           (same_line || !load_ep_free || load_block));
      o_perf_events.conflict_stall <= active && phase_q == Idle &&
          !probe_valid_q && !probe_priority && !grant_valid && !atomic_write_q &&
          pending_q && pending_blocked;
    end
  end
`ifdef FORMAL
  always @(posedge i_clk) begin
    if (f_past_valid) begin
      assert (o_perf_events.access == (o_perf_events.hit || o_perf_events.miss));
      assert (!(o_perf_events.hit && o_perf_events.miss));
      p_bounded_miss_outstanding : assert (o_perf_events.miss_outstanding <= 12);
      if ($past(i_rst)) assert (o_perf_events == '0);
      if (o_perf_events.hit_under_miss) begin
        assert (o_perf_events.hit);
        assert (o_perf_events.miss_outstanding != 0);
      end
      if (o_perf_events.store_combined_under_miss) begin
        assert (o_perf_events.store_combined);
        assert (o_perf_events.miss_outstanding != 0);
      end
      if (o_perf_events.path_hit_under_miss) begin
        assert (o_perf_events.path_hit);
        assert (o_perf_events.miss_outstanding != 0);
      end
    end
  end
  for (genvar slot = 0; slot < 8; slot++) begin : gen_read_flag_proof
    always @(posedge i_clk) begin
      if (f_past_valid) begin
        assert (perf_read_seen_q[slot] == $past(
            !i_rst && !(i_read_valid && i_read_id == 3'(slot)) &&
            (perf_read_seen_q[slot] ||
             (perf_lookup && operation_q == ReadOp && selected_read_q == 3'(slot)))));
        assert (perf_read_miss_q[slot] == $past(
            !i_rst && !(i_read_valid && i_read_id == 3'(slot)) &&
            ((perf_lookup && operation_q == ReadOp && selected_read_q == 3'(slot)) ?
             !perf_hit : perf_read_miss_q[slot])));
      end
    end
  end
`endif

  // Speculative ownership is confined to the highest load endpoints and
  // lasts through U. At least one load endpoint remains demand-only.
  localparam int unsigned PrefetchCount = MISSES >= 4 ? 2 : MISSES == 3 ? 1 : 0;
  localparam bit StreamEnabled = STREAM_PREFETCH && PrefetchCount != 0;
  logic stream_valid, stream_confirmed, stream_replace, stream_consume;
  logic [ADDR_WIDTH-1:0] stream_addr, stream_frontier;
  logic hint_valid_q, hint_checked_q, hint_eligible_q;
  logic [ADDR_WIDTH-1:0] hint_addr_q, prefetch_check_addr;
  logic prefetch_cancel, atomic_read_waiting, prefetch_busy;
  logic prefetch_conflict, hint_conflict, lookup_conflict, lookup_conflict_q;
  logic prefetch_accept, prefetch_acquire_ok, prefetch_ep_free;
  logic [MISSES+5:0] hint_conflicts, lookup_conflicts;
  logic hint_in_window, lookup_in_window;
  logic [EpBits-1:0] prefetch_ep_index;
  // LR and AMO reads waiting for completion, registered from allocation and
  // completion. A slot has no read to replace when it allocates. The flags
  // count LR and AMO reads only, so their completions leave out the hit
  // path's answers, which complete loads. A shadow lookup completes nothing,
  // as read_hit has it, whatever its slot holds by then.
  // A cycle completes at most one read by a hit and one by a fill, each in a
  // slot that registers name. The flags are computed without either, without
  // each and without both, and the late hit and fill events pick among them.
  logic amo_held, atomic_read_held;
  logic [7:0] held_amo, held_atomic, held_hit_slot, held_fill_slot;
  (* keep = "true" *) logic [3:0] amo_held_choice, atomic_read_held_choice;
  wire held_hit = active && ((phase_q == LookupWait && array_valid && operation_q == ReadOp &&
      selected_kind_q != ReadAMO && array_hit && !shadow_q) || phase_q == LocalReadReady);
  assign held_hit_slot = 8'd1 << (phase_q == LocalReadReady ? atomic_read_q : selected_read_q);
  assign held_fill_slot = 8'd1 << fill_read_slot;
  always_comb begin
    for (int slot = 0; slot < 8; slot++) begin
      held_amo[slot] = rd_valid_q[slot] && !rd_ready_q[slot] &&
          !(fail_clear_q && fail_clear_slot_q == 3'(slot)) && rd_kind_q[slot] == ReadAMO;
      held_atomic[slot] = rd_valid_q[slot] && !rd_ready_q[slot] &&
          !(fail_clear_q && fail_clear_slot_q == 3'(slot)) && rd_kind_q[slot] != ReadLoad;
    end
  end
  // Indexed by {hit, fill}.
  assign amo_held_choice = {
    |(held_amo & ~held_hit_slot & ~held_fill_slot), |(held_amo & ~held_hit_slot),
    |(held_amo & ~held_fill_slot), |held_amo
  };
  assign atomic_read_held_choice = {
    |(held_atomic & ~held_hit_slot & ~held_fill_slot), |(held_atomic & ~held_hit_slot),
    |(held_atomic & ~held_fill_slot), |held_atomic
  };
  assign amo_held = amo_held_choice[{held_hit, read_fill}];
  assign atomic_read_held = atomic_read_held_choice[{held_hit, read_fill}];
  // Read validity, which settles last, selects each flag's outcome with or
  // without the allocated read.
  (* keep = "true" *) logic [1:0] amo_waiting_choice, atomic_read_waiting_choice;
  assign amo_waiting_choice = {amo_held || i_read_kind == ReadAMO, amo_held};
  assign atomic_read_waiting_choice = {
    atomic_read_held || i_read_kind != ReadLoad, atomic_read_held
  };
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      amo_waiting <= 1'b0;
      atomic_read_waiting <= 1'b0;
    end else begin
      amo_waiting <= amo_waiting_choice[i_read_valid];
      atomic_read_waiting <= atomic_read_waiting_choice[i_read_valid];
    end
  end
`ifndef SYNTHESIS
`ifndef FORMAL
  logic amo_waiting_ref, atomic_read_waiting_ref;
  always_comb begin
    amo_waiting_ref = 1'b0;
    atomic_read_waiting_ref = 1'b0;
    for (int slot = 0; slot < 8; slot++) begin
      amo_waiting_ref |= rd_valid_q[slot] && !rd_ready_q[slot] && rd_kind_q[slot] == ReadAMO;
      atomic_read_waiting_ref |= rd_valid_q[slot] && !rd_ready_q[slot] &&
          rd_kind_q[slot] != ReadLoad;
    end
  end
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst) begin
      p_amo_waiting_exact : assert (amo_waiting == amo_waiting_ref);
      p_atomic_read_waiting_exact : assert (atomic_read_waiting == atomic_read_waiting_ref);
    end
`endif
`endif
  always_comb begin
    prefetch_ep_free = 1'b0;
    prefetch_ep_index = '0;
    for (int ep = 1; ep < MISSES; ep++)
      if (ep >= MISSES - PrefetchCount && !live[ep]) begin
        prefetch_ep_free = 1'b1;
        prefetch_ep_index = EpBits'(ep);
      end
  end
  assign prefetch_cancel = !StreamEnabled || !active || atomic_q || atomic_read_waiting ||
      i_sc_valid || maint_q || i_maint_valid;
  coherence_read_stream #(
      .ADDR_WIDTH(ADDR_WIDTH)
  ) read_stream (
      .i_clk,
      .i_rst,
      .i_cancel(prefetch_cancel),
      .i_demand_valid(demand_report),
      .i_demand_miss(!array_hit),
      .i_demand_addr(lookup_addr_q),
      .i_hit_valid(path_queue_valid_q[0]),
      .i_hit_addr({path_queue_q[0], 5'b0}),
      .i_consume(stream_consume),
      .o_valid(stream_valid),
      .o_addr(stream_addr),
      .o_confirmed(stream_confirmed),
      .o_frontier(stream_frontier),
      .o_replace(stream_replace)
  );
  assign hint_in_window = stream_confirmed &&
      hint_addr_q[ADDR_WIDTH-1:12] == stream_frontier[ADDR_WIDTH-1:12] &&
      hint_addr_q[11:5] > stream_frontier[11:5] &&
      {1'b0, hint_addr_q[11:5]} <= {1'b0, stream_frontier[11:5]} + 8'd8;
  assign lookup_in_window = stream_confirmed &&
      lookup_addr_q[ADDR_WIDTH-1:12] == stream_frontier[ADDR_WIDTH-1:12] &&
      lookup_addr_q[11:5] > stream_frontier[11:5] &&
      {1'b0, lookup_addr_q[11:5]} <= {1'b0, stream_frontier[11:5]} + 8'd8;
  assign prefetch_busy = operation_q == PrefetchOp && phase_q != Idle;
  assign prefetch_check_addr = prefetch_busy ? lookup_addr_q : hint_addr_q;
  // The hint and selected lookup compare against live ownership independently.
  // Frozen dirty data excludes GetS even after its private tag is evicted.
  assign hint_conflicts[0] = atomic_q || probe_valid_q || cut_phase_q != CutIdle;
  assign lookup_conflicts[0] = hint_conflicts[0];
  for (genvar ep = 0; ep < MISSES; ep++) begin : gen_prefetch_conflict
    assign hint_conflicts[ep+1] = live[ep] && hint_addr_q[ADDR_WIDTH-1:5] ==
        (ep == 0 ? acquisition_q.addr[ADDR_WIDTH-1:5] : ld_line_q[ep]);
    assign lookup_conflicts[ep+1] = live[ep] && lookup_addr_q[ADDR_WIDTH-1:5] ==
        (ep == 0 ? acquisition_q.addr[ADDR_WIDTH-1:5] : ld_line_q[ep]);
  end
  for (genvar slot = 0; slot < 2; slot++) begin : gen_prefetch_wb_conflict
    assign hint_conflicts[MISSES+1+slot] = wb_live[slot] &&
        wb_addr[slot][ADDR_WIDTH-1:5] == hint_addr_q[ADDR_WIDTH-1:5];
    assign lookup_conflicts[MISSES+1+slot] = wb_live[slot] &&
        wb_addr[slot][ADDR_WIDTH-1:5] == lookup_addr_q[ADDR_WIDTH-1:5];
  end
  assign hint_conflicts[MISSES+3] = pending_q &&
      pending_addr_q[ADDR_WIDTH-1:5] == hint_addr_q[ADDR_WIDTH-1:5];
  assign lookup_conflicts[MISSES+3] = pending_q &&
      pending_addr_q[ADDR_WIDTH-1:5] == lookup_addr_q[ADDR_WIDTH-1:5];
  assign hint_conflicts[MISSES+4] = tail_q &&
      tail_addr[ADDR_WIDTH-1:5] == hint_addr_q[ADDR_WIDTH-1:5];
  assign lookup_conflicts[MISSES+4] = tail_q &&
      tail_addr[ADDR_WIDTH-1:5] == lookup_addr_q[ADDR_WIDTH-1:5];
  assign hint_conflicts[MISSES+5] = i_p_valid &&
      probe_in.addr[ADDR_WIDTH-1:5] == hint_addr_q[ADDR_WIDTH-1:5];
  assign lookup_conflicts[MISSES+5] = i_p_valid &&
      probe_in.addr[ADDR_WIDTH-1:5] == lookup_addr_q[ADDR_WIDTH-1:5];
  assign hint_conflict = |hint_conflicts;
  assign lookup_conflict = |lookup_conflicts;
  assign prefetch_conflict = prefetch_busy ? lookup_conflict : hint_conflict;
  // The controller reads the lookup's conflict comparison from a flop, and
  // any offered probe excludes the prefetch. Only this operation can start an
  // acquisition or a write-back while it runs, so the flop differs from the
  // comparison only for a store of the line that arrived a cycle earlier,
  // which orders like a store just after acceptance.
  always_ff @(posedge i_clk) lookup_conflict_q <= lookup_conflict;
  assign prefetch_accept = !prefetch_cancel && !stream_replace && lookup_in_window &&
      !lookup_conflict_q && !i_p_valid && !load_acquire_block;
  // The selected address and demand frontier stay fixed through Acquire.
  // Cancellation is checked on its acceptance edge.
  assign prefetch_acquire_ok = !prefetch_cancel && !lookup_conflict_q && !i_p_valid &&
      !load_acquire_block;
  assign stream_consume = !hint_valid_q && stream_valid && !prefetch_cancel && !stream_replace;
  always_ff @(posedge i_clk) begin
    if (i_rst || prefetch_cancel || stream_replace) begin
      hint_valid_q <= 1'b0;
      hint_checked_q <= 1'b0;
      hint_eligible_q <= 1'b0;
      hint_addr_q <= '0;
    end else begin
      if (stream_consume) begin
        hint_valid_q <= 1'b1;
        hint_addr_q <= stream_addr;
        hint_checked_q <= 1'b0;
      end
      if (hint_valid_q && !hint_checked_q && !prefetch_busy) begin
        hint_checked_q <= 1'b1;
        hint_eligible_q <= !hint_conflict;
      end
      if (hint_valid_q && (!hint_in_window ||
          (hint_checked_q && !hint_eligible_q) ||
          (prefetch_busy && lookup_addr_q == hint_addr_q))) hint_valid_q <= 1'b0;
    end
  end

`ifndef SYNTHESIS
  logic prefetch_conflict_ref;
  always_comb begin
    prefetch_conflict_ref = atomic_q || probe_valid_q || cut_phase_q != CutIdle;
    for (int ep = 0; ep < MISSES; ep++)
      prefetch_conflict_ref |= live[ep] && prefetch_check_addr[ADDR_WIDTH-1:5] ==
          (ep == 0 ? acquisition_q.addr[ADDR_WIDTH-1:5] : ld_line_q[ep]);
    for (int slot = 0; slot < 2; slot++)
      prefetch_conflict_ref |= wb_live[slot] &&
          wb_addr[slot][ADDR_WIDTH-1:5] == prefetch_check_addr[ADDR_WIDTH-1:5];
    prefetch_conflict_ref |= pending_q && pending_addr_q[ADDR_WIDTH-1:5] ==
        prefetch_check_addr[ADDR_WIDTH-1:5];
    prefetch_conflict_ref |= tail_q &&
        tail_addr[ADDR_WIDTH-1:5] == prefetch_check_addr[ADDR_WIDTH-1:5];
    prefetch_conflict_ref |= i_p_valid && probe_in.addr[ADDR_WIDTH-1:5] ==
        prefetch_check_addr[ADDR_WIDTH-1:5];
  end
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst && active) begin
      p_prefetch_conflict_split : assert (prefetch_conflict == prefetch_conflict_ref);
      if (hint_valid_q && !hint_checked_q && !prefetch_busy)
        p_prefetch_hint_conflict : assert (hint_conflict == prefetch_conflict_ref);
      if (phase_q == Acquire && operation_q == PrefetchOp) begin
        p_prefetch_acquire_pool : assert (StreamEnabled && acq_ep_q != 0 &&
            int'(acq_ep_q) >= MISSES - PrefetchCount && int'(acq_ep_q) < MISSES);
      end
      // Ownership, write-back and probe conflicts cannot begin during the
      // prefetch, so the registered comparison covers them on its acceptance.
      if (prefetch_busy && (phase_q == LookupWait || phase_q == Acquire) &&
          !lookup_conflict_q)
        p_prefetch_owner_conflict : assert (!(|lookup_conflicts[MISSES+2:0]));
    end
`endif

  // A demand installation with an attached reader gives an ordinary read
  // one turn before another load grant. Probes and atomics keep priority.
  always_comb begin
    grant_demand_waiter = 1'b0;
    for (int slot = 0; slot < 8; slot++)
      grant_demand_waiter |= rd_wait_q[slot] && !rd_wait_release_q[slot] &&
          rd_wait_ep_q[slot] == grant_ep_q;
  end
  // Bimodal insertion usually leaves a filled sector its set's next victim
  // until a hit moves it, and the next installation in the set can come
  // before that hit. A fill with a read attached to its endpoint is about to
  // be hit, and a fill with another miss of its set not yet installed can be
  // replaced by that miss's installation, so such a fill updates replacement
  // state at installation. Any other fill keeps bimodal insertion. Only the
  // replacement write reads this flag, at the update, and the grant's lookup
  // address and endpoint have held for at least three cycles by then.
  logic [EpSlots-1:0] set_ep;
  always_comb begin
    set_ep = '0;
    for (int ep = 0; ep < MISSES; ep++)
      set_ep[ep] = live[ep] && !installed_q[ep] && EpBits'(ep) != grant_ep_q &&
          lookup_addr_q[5+:SetBits] ==
          (ep == 0 ? acquisition_q.addr[5+:SetBits] : ld_line_q[ep][SetBits-1:0]);
  end
  always_ff @(posedge i_clk) grant_touch_q <= grant_demand_waiter || |set_ep;
  assign grant_read_hold = StreamEnabled && grant_read_turn_q &&
      grant_valid && !ep_grant_valid[0] && !local_turn_q;
  assign grant_read_yield = grant_read_hold && rd_candidate && !prefetch_cancel;
  assign load_acquire_block = StreamEnabled && grant_retry_q && grant_valid;
  always_ff @(posedge i_clk) begin
    if (i_rst || prefetch_cancel) grant_read_turn_q <= 1'b0;
    else begin
      if ((grant_valid && grant_ready) ||
          (active && phase_q == Idle && !probe_valid_q && !probe_priority && grant_read_hold) ||
          (active && phase_q == Lookup && operation_q == ReadOp)) grant_read_turn_q <= 1'b0;
      if (active && phase_q == UpdateWait && array_ready &&
          operation_q == GrantOp && grant_ep_q != '0)
        grant_read_turn_q <= !grant_prefetch_q && grant_demand_waiter;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) grant_retry_q <= 1'b0;
    else if (active && phase_q == Idle)
      grant_retry_q <= grant_read_yield && !probe_valid_q && !probe_priority;
  end

  // Idle clears the flag before each accepted grant enters Lookup.
  always_ff @(posedge i_clk) begin
    if (i_rst || phase_q == Idle) grant_answered_q <= 1'b0;
    else if (grant_answer) grant_answered_q <= 1'b1;
  end

  assign maint_eligible = maint_q && !pending_q && !atomic_q && !any_live && wb_free;
  assign store_push = |i_write_mask && !i_write_atomic;
  assign store_pop = active && phase_q == UpdateWait && array_ready &&
      (operation_q == StoreOp || (operation_q == GrantOp && selected_grant_store));
  assign store_seal = active && ((phase_q == Idle && !probe_valid_q && !probe_priority &&
      ((grant_valid && grant_ready && grant_is_store) ||
       (!grant_valid && !atomic_write_q && store_head_ready))) ||
      (store_pop && operation_q == StoreOp && store_continue));
  assign store_acquire = active && phase_q == Acquire &&
      (operation_q == StoreOp || operation_q == LookaheadOp) && acquire_ready;
  coherence_store_buffer #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .TAG_BITS(TAG_BITS),
      .EP_BITS(EpBits)
  ) store_buffer (
      .i_clk,
      .i_rst,
      .i_push(store_push),
      .o_combined(store_combined),
      .i_addr(i_address),
      .i_data(i_write_data),
      .i_mask(i_write_mask),
      .i_tag(i_write_tag),
      .i_pop(store_pop),
      .i_seal(store_seal),
      .i_seal_index(store_pop ? store_next_index : store_head_index),
      .i_acquire(store_acquire),
      .i_acquire_index(store_selected_q),
      .i_acquire_ep(acq_ep_q),
      .o_ready(store_credit),
      .o_done(store_ack),
      .o_count(store_count),
      .o_head(store_head_index),
      .o_valid(store_valid),
      .o_sealed(store_sealed),
      .o_acquired(store_acquired),
      .o_addr(store_addr),
      .o_data(store_data),
      .o_mask(store_mask),
      .o_tag(store_tag),
      .o_contributors(store_contributors),
      .o_ep(store_ep)
  );
  assign pending_q = store_count != 0;
  assign tail_q = store_count > 1;
  assign store_next_index = store_head_index + 2'd1;
  // Head promotion and empty insertion capture the sector address directly.
  always_ff @(posedge i_clk) begin
    if (i_rst) pending_addr_q <= '0;
    else if (store_push && (store_count == 0 || (store_count == 1 && store_pop)))
      pending_addr_q <= {i_address[ADDR_WIDTH-1:5], 5'b0};
    else if (store_pop) pending_addr_q <= store_addr[store_next_index];
  end
`ifndef SYNTHESIS
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst && pending_q)
      p_store_head_address : assert (pending_addr_q == store_addr[store_head_index]);
`endif
  assign pending_data_q = store_data[store_head_index];
  assign pending_mask_q = store_mask[store_head_index];
  assign pending_tag = store_tag[store_head_index];
  assign tail_addr = store_addr[store_next_index];
  assign o_pending_store = pending_q;
  assign o_atomic_live = atomic_q;
  assign o_sc_write_pending = atomic_q && atomic_sc_q && atomic_granted_q && !atomic_written_q;
  // SQ launch readiness precedes its registered write by one cycle. The CPU
  // presents an atomic only after its committed stores drain, so no store
  // arrives beside SC acceptance or local atomic admission.
  assign o_store_ready = active && store_credit && !atomic_q && !maint_q && !i_maint_valid;
  assign o_write_inflight = store_ack || atomic_write_q;
  assign o_write_done = store_ack || atomic_done_q;
  assign o_block_valid = atomic_q ? 4'b0001 : store_valid;
  // Holder zero captures its address on each store or atomic ownership change.
  // Record 0 allocates when it is next and the store does not combine with
  // record 3, the youngest then. Combining into record 0 keeps its address.
  assign store_zero_alloc = 2'(store_head_index + 2'(store_count)) == 2'd0 &&
      !(store_count != 0 && !store_sealed[3] &&
        store_addr[3][ADDR_WIDTH-1:5] == i_address[ADDR_WIDTH-1:5]);
  assign o_block_addr = {store_addr[3:1], block_zero_addr_q};
  assign store_head_ready = pending_q && !look_priority_q && !store_acquired[store_head_index] &&
      !pending_blocked && !(store_read_turn_q && read_waiting_q) &&
      (!pending_miss_q || (!request_live && ep0_wb_ok && !store_same_line_q));
  assign o_sc_ready = active && !atomic_q && !pending_q && !request_live &&
      !o_sc_result_valid && i_atomic_protected && phase_q == Idle && !grant_valid &&
      !probe_valid_q && !probe_priority;
  assign o_sc_write_tag = atomic_tag_q;
  assign local_ready = grant_valid || atomic_write_q ||
      (atomic_q && atomic_sc_q && !request_live && (!sc_home_q || (!any_live && wb_free))) ||
      store_head_ready || look_ready ||
      (rd_candidate && &read_probe_count_q) || maint_eligible ||
      (i_sc_valid && !atomic_q && !pending_q && !request_live &&
       !o_sc_result_valid && i_atomic_protected && !store_push);
  assign probe_priority = i_p_valid && !local_turn_q;
  assign o_p_ready = active && phase_q == Idle && !probe_valid_q && !o_r_valid && !local_turn_q;
  assign probe_capture = i_p_valid && o_p_ready;
  assign probe_launch = probe_capture && probe_in.opcode != coherence_pkg::CheckSC && array_ready;
  assign array_request_addr = probe_launch ? probe_in.addr : lookup_addr_q;
  // Both candidate request addresses are compared with the atomic's set, so
  // a probe launch selects a finished comparison.
  (* keep = "true" *) wire probe_atomic_set =
      probe_in.addr[5+:SetBits] == atomic_addr_q[5+:SetBits];
  (* keep = "true" *) wire lookup_atomic_set =
      lookup_addr_q[5+:SetBits] == atomic_addr_q[5+:SetBits];
  assign probe_reply_eligible = probe_q.opcode != coherence_pkg::ProbeInvalidate ||
      cut_phase_q == CutDone;
  (* keep = "true" *) wire invalidate_eligible = active &&
      phase_q == Idle && !probe_valid_q && !o_r_valid && !local_turn_q &&
      probe_in.opcode == coherence_pkg::ProbeInvalidate;
  assign o_cut_hold = (i_p_valid && invalidate_eligible) ||
      (cut_phase_q != CutIdle && cut_phase_q != CutDone);
  // The absorption claim for the probed slot, with a simultaneous W
  // acceptance of that slot applied last: W acceptance wins.
  (* keep = "true" *) logic absorb_take;
  logic absorb_go;
  assign absorb_take = wb_absorb_offer[probe_put_q];
  assign absorb_go = absorb_take && !(wb_selected_q && wb_select_q == probe_put_q && i_w_ready);
`ifndef SYNTHESIS
`ifdef FORMAL
  always_comb
`else
  always @(posedge i_clk)
`endif
  if (sim_reset_seen_q && !i_rst) begin
    p_absorb_go_exact : assert (absorb_go == wb_absorb_ready[probe_put_q]);
    // The hold covers every invalidating capture and active cut.
    p_cut_hold_exact : assert (o_cut_hold ==
        ((i_p_valid && o_p_ready && probe_in.opcode == coherence_pkg::ProbeInvalidate) ||
         (cut_phase_q != CutIdle && cut_phase_q != CutDone)));
  end
`endif
  assign o_cut_address = probe_valid_q ? probe_q.addr : probe_in.addr;
  assign o_cut_admit_valid = active && (cut_phase_q == CutAdmit ||
      (probe_capture && probe_in.opcode == coherence_pkg::ProbeInvalidate));
  assign o_cut_inval_valid = active && cut_phase_q == CutInvalidate;
  always_ff @(posedge i_clk) begin
    if (i_rst) cut_phase_q <= CutIdle;
    else if (cut_phase_q == CutDone && o_r_valid && i_r_ready) cut_phase_q <= CutIdle;
    else if (active) begin
      case (cut_phase_q)
        CutIdle:
        if (i_p_valid && o_p_ready && probe_in.opcode == coherence_pkg::ProbeInvalidate)
          cut_phase_q <= CutAdmit;
        CutAdmit: if (i_cut_admit_ready) cut_phase_q <= i_cut_admit_clean ? CutDone : CutInvalidate;
        CutInvalidate: if (i_cut_inval_done) cut_phase_q <= CutWait;
        CutWait: cut_phase_q <= CutDone;
        CutDone: begin
        end
        default: cut_phase_q <= CutIdle;
      endcase
    end
  end
  assign o_r = reply_q;
  assign grant_ready = active && phase_q == Idle && !probe_valid_q && !probe_priority &&
      !grant_read_hold;
  // Endpoint 0 is never held for a read's turn.
  assign zero_grant_failed = active && phase_q == Idle && !probe_valid_q && !probe_priority &&
      pick_onehot[0] && ep_fail[0] && !ep_store[0];
  // Data-class request identities 0 to 7 are legal.
  if (MISSES < 1 || MISSES > 8) begin : gen_invalid_misses
    initial $fatal(1, "coherence_l1d: MISSES must be 1 to 8");
  end
  assign request_live = live[0];
  // Every acquisition is a legal request, so an idle endpoint accepts it.
  assign acquire_ready = !live[acq_ep_q];
  assign any_live = |live;
  assign o_g_ready = |ep_g_ready;
  assign o_u_ready = |ep_u_ready;
  assign ep_store = {ld_store_q[EpSlots-1:1], acquisition_store_q};
  assign ep_done_valid[0] = done_q;
  assign ep_done_status[0] = done_status_q;
  assign ep_write_done[0] = written_q;
`ifndef SYNTHESIS
  logic [EpSlots-1:0] request_payload_match, load_payload_held;
`endif
  for (genvar ep = 0; ep < MISSES; ep++) begin : gen_request
    coh_d_t endpoint_acquisition;
    if (ep == 0) begin : gen_atomic_payload
      assign endpoint_acquisition = acquisition;
    end else begin : gen_read_payload
      always_comb begin
        endpoint_acquisition = acquisition;
        if (operation_q != LookaheadOp) begin
          endpoint_acquisition.opcode = coherence_pkg::GetS;
          endpoint_acquisition.mask = '0;
        end
      end
    end
`ifndef SYNTHESIS
    coh_d_t held_request;
    assign held_request = o_d[ep];
    assign request_payload_match[ep] = endpoint_acquisition == acquisition;
    assign load_payload_held[ep] = ep == 0 || !live[ep] ||
        ld_store_q[ep] || (held_request.opcode == coherence_pkg::GetS &&
        held_request.mask == 0);
`endif
    if (StreamEnabled && ep >= MISSES - PrefetchCount) begin : gen_stream_admission
      assign ep_request_valid[ep] = active && phase_q == Acquire && acq_ep_q == EpBits'(ep) &&
          (operation_q != PrefetchOp || prefetch_acquire_ok) && !load_acquire_block;
    end else begin : gen_demand_admission
      assign ep_request_valid[ep] = active && phase_q == Acquire && acq_ep_q == EpBits'(ep) &&
          (ep == 0 || !load_acquire_block);
    end
    assign ep_grant_ready[ep] = grant_ready && pick_onehot[ep];
    if (ep > 0) begin : gen_load_done
      assign ep_done_valid[ep] = ld_done_q[ep];
      assign ep_done_status[ep] = ld_status_q[ep];
      assign ep_write_done[ep] = ld_store_q[ep] && ld_done_q[ep];
    end
    coh_g_t endpoint_grant;
    assign ep_grant[ep] = endpoint_grant;
    assign ep_fail[ep] = endpoint_grant.error || endpoint_grant.opcode == coherence_pkg::GrantFail;
    assign ep_fail_error[ep] = endpoint_grant.error;
`ifdef READ_OWNER_PROOF
    logic [6:0] f_endpoint_phase;
    assign f_ep_phase[ep] = f_endpoint_phase;
`endif
    coherence_request_endpoint #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .SOURCE(0),
        .PORT_CLASS(0),
        .SLOT(ep),
        .LOCAL_PHASE_UPDATES(StreamEnabled && ep != 0)
    ) request (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_epoch(1'b0),
        .i_request_valid(ep_request_valid[ep]),
        .o_request_ready(ep_request_ready[ep]),
        .i_request(endpoint_acquisition),
        .o_d_valid(o_d_valid[ep]),
        .i_d_ready(i_d_ready[ep]),
        .o_d(o_d[ep]),
        .i_g_valid(i_g_valid),
        .o_g_ready(ep_g_ready[ep]),
        .i_g(i_g),
        .o_grant_valid(ep_grant_valid[ep]),
        .i_grant_ready(ep_grant_ready[ep]),
        .o_grant(endpoint_grant),
        .i_done_valid(ep_done_valid[ep]),
        .o_done_ready(),
        .i_done_status(ep_done_status[ep]),
        .i_write_done(ep_write_done[ep]),
        .i_error_disposed(ep_done_status[ep] == coherence_pkg::Error),
        .o_c_valid(o_c_valid[ep]),
        .i_c_ready(i_c_ready[ep]),
        .o_c(o_c[ep]),
        .i_u_valid(i_u_valid),
        .o_u_ready(ep_u_ready[ep]),
        .i_u(i_u),
`ifdef READ_OWNER_PROOF
        .o_phase(f_endpoint_phase),
`endif
        .o_live(live[ep])
    );
  end
`ifndef SYNTHESIS
  logic [EpSlots-1:0] request_valid_ref, request_ready_ref;
  always_comb begin
    request_valid_ref = '0;
    request_ready_ref = '0;
    for (int ep = 0; ep < MISSES; ep++) begin
      request_valid_ref[ep] = active && phase_q == Acquire && acq_ep_q == EpBits'(ep) &&
          (operation_q != PrefetchOp || prefetch_acquire_ok) && (ep == 0 || !load_acquire_block);
      request_ready_ref[ep] = !live[ep] &&
          acquisition.q == {2'b00, 2'b00, 4'(ep), 1'b0} &&
          coherence_pkg::legal_q(acquisition.q) &&
          coherence_pkg::legal_opcode(acquisition.q, acquisition.opcode) &&
          acquisition.addr[4:0] == 0;
    end
  end
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst) begin
      p_request_ready_payload : assert (ep_request_ready == request_ready_ref);
      p_request_payload : assert ((ep_request_valid & ~request_payload_match) == 0);
      p_load_payload_held : assert (&load_payload_held);
      p_acquire_index : assert (int'(acq_ep_q) < MISSES);
      // A home atomic acquires only after the load endpoints drain, and they
      // stay idle while it owns endpoint 0. A local atomic excludes only its
      // sector, and an accepted SC can wait for the drain.
      p_atomic_no_load_endpoint : assert (!(atomic_q && !atomic_local_q &&
          (!atomic_sc_q || request_live || atomic_granted_q)) || !(|live[EpSlots-1:1]));
      if (active) begin
        p_request_admission : assert (ep_request_valid == request_valid_ref);
        if (phase_q == Acquire) begin
          p_acquire_ready_exact : assert (ep_request_ready[acq_ep_q] == acquire_ready);
          if (acq_ep_q != 0) begin
            p_acquire_read_role : assert (!atomic_q &&
                ((operation_q == ReadOp && rd_valid_q[selected_read_q] &&
                  !rd_ready_q[selected_read_q] && rd_kind_q[selected_read_q] == ReadLoad) ||
                 operation_q == LookaheadOp ||
                 (operation_q == PrefetchOp && StreamEnabled &&
                  int'(acq_ep_q) >= MISSES - PrefetchCount)));
            p_acquire_read_payload : assert (operation_q == LookaheadOp ||
                (acquisition.opcode == coherence_pkg::GetS && acquisition.mask == 0));
          end
          if (!((acq_ep_q != 0 && load_acquire_block) ||
              (operation_q == PrefetchOp && !prefetch_acquire_ok)))
            p_acquire_request_valid : assert (ep_request_valid[acq_ep_q]);
        end
      end
    end
`endif
  // A nonzero endpoint installs only with a free WB slot for a modified
  // victim. Endpoint 0 reserves its slot from acquisition through installation.
  for (genvar ep = MISSES; ep < EpSlots; ep++) begin : gen_unused_endpoint
`ifndef SYNTHESIS
    assign request_payload_match[ep] = 1'b1;
    assign load_payload_held[ep] = 1'b1;
`endif
    assign live[ep] = 1'b0;
    assign ep_request_ready[ep] = 1'b0;
    assign ep_request_valid[ep] = 1'b0;
    assign ep_grant_valid[ep] = 1'b0;
    assign ep_grant_ready[ep] = 1'b0;
    assign ep_grant[ep] = '0;
    assign ep_fail[ep] = 1'b0;
    assign ep_fail_error[ep] = 1'b0;
    assign ep_g_ready[ep] = 1'b0;
    assign ep_u_ready[ep] = 1'b0;
    assign ep_done_valid[ep] = 1'b0;
    assign ep_done_status[ep] = coherence_pkg::Consumed;
    assign ep_write_done[ep] = ld_store_q[ep] && ld_done_q[ep];
  end
  // Endpoint 0's grant goes first, then the lowest-numbered load grant.
  // A credited read cannot acquire while a grant is selectable.
  // A load grant also needs a free WB slot.
  // An endpoint's store kind changes only at acquisition, when it holds no grant.
  assign load_grant_waiting = Multi && |(ep_grant_valid[EpSlots-1:1] & ~ep_store[EpSlots-1:1]);
  // Eligibility precedes priority. A held younger store grant cannot block
  // the head's lookup or a load grant that can install.
  // The owner mask follows a pop and includes an accepted acquisition.
  assign store_grant_index = store_pop ? store_next_index : store_head_index;
  always_ff @(posedge i_clk) begin
    if (i_rst) store_grant_head_q <= '0;
    else begin
      for (int ep = 0; ep < EpSlots; ep++)
        store_grant_head_q[ep] <= store_valid[store_grant_index] &&
            store_acquired[store_grant_index] && store_ep[store_grant_index] == EpBits'(ep);
      if (store_acquire && store_selected_q == store_grant_index)
        store_grant_head_q <= EpSlots'(1) << acq_ep_q;
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst)
      p_store_grant_head_exact : assert (store_grant_head_q ==
          ((pending_q && store_acquired[store_head_index]) ?
           (EpSlots'(1) << store_ep[store_head_index]) : '0));
`endif
  always_comb begin
    load_grant_eligible = 1'b0;
    for (int ep = 0; ep < EpSlots; ep++)
      if (ep_grant_valid[ep] && !ep_store[ep] &&
          (ep == 0 ? wb_reserved_q : wb_free)) load_grant_eligible = 1'b1;
  end
  always_comb begin
    for (int ep = 0; ep < EpSlots; ep++) begin
      grant_offer[ep] = ep_grant_valid[ep];
      if (ep_store[ep])
        grant_offer[ep] &= store_grant_head_q[ep] &&
            !(store_read_turn_q && read_waiting_q);
    end
  end
  coherence_grant_select #(
      .SLOTS(EpSlots)
  ) grant_select (
      .i_offer(grant_offer),
      .i_failure(ep_read_fail),
      .i_owner_store(ep_store),
      .i_grant_failure(ep_fail),
      .i_grant_error(ep_fail_error),
      .i_zero_credit(wb_reserved_q),
      .i_other_credit(wb_free),
      .o_valid(grant_valid),
      .o_index(grant_pick),
      .o_onehot(pick_onehot),
      .o_other_first(grant_other_first),
      .o_failure(grant_read_failure),
      .o_owner_store(grant_is_store),
      .o_grant_failure(grant_failure),
      .o_grant_error(grant_error)
  );
  assign read_service_waiting = rd_candidate || load_grant_eligible;
  // The payload selection leaves out write-back credit: a selection without
  // credit is no selection, and its payload goes unread.
  always_comb begin
    grant = '0;
    for (int ep = 1; ep < EpSlots; ep++)
      grant |= ep_grant[ep] & {(ADDR_WIDTH + 275) {grant_other_first[ep]}};
    if (pick_onehot[0]) grant = ep_grant[0];
  end
  assign selected_grant_store = ep_store[grant_ep_q];
`ifndef SYNTHESIS
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst) begin
      if (grant_valid) begin
        p_grant_mux_exact : assert (grant == ep_grant[grant_pick]);
        p_grant_failure_exact : assert (grant_failure ==
            (grant.error || grant.opcode == coherence_pkg::GrantFail));
        p_grant_error_exact : assert (grant_error == grant.error);
      end
      p_grant_owner_exact : assert (grant_is_store == ep_store[grant_pick]);
      p_block_zero_exact : assert (block_zero_addr_q ==
          (atomic_q ? atomic_addr_q : store_addr[0]));
    end
`endif
  always_comb begin
    for (int ep = 0; ep < EpSlots; ep++) begin
      ep_read_fail[ep] = ep_fail[ep] && !ep_store[ep] && !ld_prefetch_q[ep] &&
          (ep != 0 || !acquisition_sc_q);
    end
    failure_read_slot = '0;
    for (int ep = 0; ep < EpSlots; ep++)
    if (pick_onehot[ep]) failure_read_slot |= ep == 0 ? acquisition_read_q : ld_read_q[ep];
  end
  assign fill_read_slot = grant_ep_q == '0 ? acquisition_read_q : ld_read_q[grant_ep_q];
  // Load endpoints. A miss on a line some live endpoint holds waits for that
  // endpoint: for its installation if it has not installed, otherwise for its
  // release. Load acquisitions pause for an AMO, SC or maintenance operation.
  // Home atomics and maintenance require every endpoint to drain.
  always_comb begin
    load_ep_index = '0;
    for (int ep = MISSES - 1; ep >= 1; ep--) if (!live[ep]) load_ep_index = EpBits'(ep);
    same_line_ep = '0;
    for (int ep = 0; ep < MISSES; ep++) if (same_line_q[ep]) same_line_ep = EpBits'(ep);
    for (int slot = 0; slot < 8; slot++) begin
      rd_miss_retry[slot] = rd_atomic_retry_q[slot] || (retry_credit[0] && (Multi ?
          rd_kind_q[slot] == ReadLoad : !(rd_kind_q[slot] == ReadAMO && rd_local_retry_q[slot])));
    end
  end
  // Load retries read their credit directly. LR and AMO retries read a flop
  // per slot, and their lookups recheck the credit before they acquire.
  always_ff @(posedge i_clk) begin
    for (int slot = 0; slot < 8; slot++) begin
      if (i_rst) rd_atomic_retry_q[slot] <= 1'b0;
      else if (rd_kind_q[slot] == ReadAMO && rd_local_retry_q[slot])
        rd_atomic_retry_q[slot] <= !request_live && !pending_q;
      else if (!Multi || rd_kind_q[slot] == ReadLoad) rd_atomic_retry_q[slot] <= 1'b0;
      else if (rd_kind_q[slot] == ReadLR) rd_atomic_retry_q[slot] <= retry_credit[1];
      else rd_atomic_retry_q[slot] <= retry_credit[2];
    end
  end
  logic [3*MISSES-1:0] read_owner_slots;
  assign read_owner_slots[0+:3] = acquisition_read_q;
  for (genvar ep = 1; ep < MISSES; ep++) begin : gen_read_owner_slot
    assign read_owner_slots[3*ep+:3] = ld_read_q[ep];
  end
  // Read ownership registers from its events, so read selection does not
  // start at the endpoints. A read owns its slot from acquisition: through U
  // on endpoint 0, and through installation or failure on the others.
  always_comb begin
    rd_owner_set = '0;
    rd_owner_clear = '0;
    if (ep_request_valid[acq_ep_q] && acquire_ready && operation_q == ReadOp &&
        (acq_ep_q != '0 || !(atomic_q && atomic_sc_q)))
      rd_owner_set[selected_read_q] = 1'b1;
    if (i_u_valid && ep_u_ready[0] && !ep_store[0] && !acquisition_sc_q)
      rd_owner_clear[acquisition_read_q] = 1'b1;
    if (fail_owner_q) rd_owner_clear[fail_clear_slot_q] = 1'b1;
    for (int ep = 1; ep < MISSES; ep++)
    if (!ep_store[ep] && !ld_prefetch_q[ep] && active && phase_q == UpdateWait && array_ready &&
        operation_q == GrantOp && grant_ep_q == EpBits'(ep))
      rd_owner_clear[ld_read_q[ep]] = 1'b1;
  end
  // A failed read on a nonzero endpoint clears a cycle later, on the edge its
  // ready flag sets.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      rd_owned_q <= '0;
      fail_owner_q <= 1'b0;
    end else begin
      rd_owned_q <= (rd_owned_q & ~rd_owner_clear) | rd_owner_set;
      fail_owner_q <= read_failure && !pick_onehot[0];
    end
  end
`ifndef SYNTHESIS
  coherence_read_owners #(
      .SLOTS(MISSES)
  ) read_owners (
      .i_clk(i_clk),
      .i_live(live[MISSES-1:0]),
      .i_store(ep_store[MISSES-1:0] | ld_prefetch_q[MISSES-1:0]),
      .i_installed(installed_q[MISSES-1:0]),
      .i_zero_sc(acquisition_sc_q),
      .i_read_slot(read_owner_slots),
      .o_owned(rd_ep_owned)
  );
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst) p_read_owned_exact : assert (rd_owned_q ==
        (rd_ep_owned | (fail_owner_q ? 8'd1 << fail_clear_slot_q : 8'd0)));
`endif
  // A local AMO owns its read slot until it releases its sector.
  assign rd_owned = rd_owned_q |
      ((atomic_q && atomic_local_q && !atomic_sc_q) ? 8'd1 << atomic_read_q : 8'd0);
  assign same_line = Multi && |same_line_q;
  // Endpoint events that a waiting read and the free-endpoint flag follow: U
  // ends an acquisition, and installation or a failed grant installs it. A
  // failed grant ends waits a cycle later, from a flop, so the waits do not
  // read the grant selection.
  assign grant_install = active && phase_q == UpdateWait && array_ready && operation_q == GrantOp;
  always_comb begin
    ep_release = '0;
    ep_failed = '0;
    ep_install = '0;
    ep_wait_install = '0;
    ep_accept = '0;
    for (int ep = 0; ep < MISSES; ep++) begin
      ep_release[ep] = i_u_valid && ep_u_ready[ep];
      ep_failed[ep] = ep_grant_ready[ep] && ep_fail[ep] && !ep_store[ep];
      ep_install[ep] = ep_failed[ep] || (grant_install && grant_ep_q == EpBits'(ep));
      ep_wait_install[ep] = ep_failed_q[ep] || (grant_install && grant_ep_q == EpBits'(ep));
      ep_accept[ep] = ep_request_valid[ep] && !live[ep];
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) ep_failed_q <= '0;
    else ep_failed_q <= ep_failed;
  end
  // The flag follows the endpoints' events, so read selection and the load
  // credit do not start at the endpoints.
  always_comb begin
    load_ep_free_next = 1'b0;
    for (int ep = 1; ep < MISSES; ep++)
    if (ep_release[ep] || !(live[ep] || ep_accept[ep])) load_ep_free_next = 1'b1;
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) load_ep_free <= Multi;
    else load_ep_free <= load_ep_free_next;
  end
  // A read attaching on a lookup cannot meet its endpoint's installation,
  // which needs the controller.
  always_comb begin
    wait_attach_live = 1'b0;
    for (int ep = 0; ep < MISSES; ep++)
      wait_attach_live |= same_line_q[ep] && live[ep] && !ep_release[ep];
  end
  // A load grant waits only for a WB slot. Endpoint 0 does not take the last
  // free slot from it, so stores and LR cannot keep a load grant waiting.
  coherence_miss_credit #(
      .SLOTS(MISSES)
  ) miss_credit (
      .i_clk(i_clk),
      .i_load_grant_waiting(load_grant_waiting),
      .i_wb_live(wb_live),
      .i_wb_free(wb_free),
      .i_request_live(request_live),
      .i_any_live(any_live),
      .i_load_ep_free(load_ep_free),
      .i_atomic(atomic_q),
      .i_drain(drain_q),
      .o_zero_wb_ok(ep0_wb_ok),
      .o_retry(retry_credit)
  );
  assign load_block = Multi && (atomic_q || drain_q);
  assign wait_attach = Multi && read_miss && selected_kind_q != ReadAMO && same_line;
  // A wait lasts while its endpoint is live, and until installation for a
  // read that attached before it. rd_wait_q holds that from the endpoint's
  // events. Read validity selects between the allocation and hold/update
  // outcomes.
  for (genvar slot = 0; slot < 8; slot++) begin : gen_read_wait_flags
    (* keep = "true" *) logic [1:0] wait_choice;
    wire wait_ended = ep_release[rd_wait_ep_q[slot]] ||
        (ep_wait_install[rd_wait_ep_q[slot]] && !rd_wait_release_q[slot]);
    for (genvar allocated = 0; allocated < 2; allocated++) begin : gen_allocate_choice
      wire clear_slot = allocated != 0 && i_read_id == 3'(slot);
      assign wait_choice[allocated] = Multi ? !clear_slot &&
          ((rd_wait_q[slot] && !wait_ended) ||
           (wait_attach && wait_attach_live && selected_read_q == 3'(slot))) : rd_wait_q[slot];
    end
    always_ff @(posedge i_clk) begin
      if (i_rst) rd_wait_q[slot] <= 1'b0;
      else rd_wait_q[slot] <= wait_choice[i_read_valid];
    end
  end
  assign rd_waiting = rd_wait_q;
`ifndef SYNTHESIS
`ifndef FORMAL
  // The state each flag follows: a read waits from its attachment while its
  // endpoint is live, and until installation if it attached before it, or a
  // cycle past a failed grant. The control BMCs cannot afford these checks, so
  // they run in simulation.
  logic [7:0] rd_wait_ref_q, rd_wait_ref;
  logic load_ep_free_ref;
  always_comb begin
    load_ep_free_ref = 1'b0;
    for (int ep = 1; ep < MISSES; ep++) load_ep_free_ref |= !live[ep];
    for (int slot = 0; slot < 8; slot++)
    rd_wait_ref[slot] = Multi && rd_wait_ref_q[slot] && live[rd_wait_ep_q[slot]] &&
        !(installed_q[rd_wait_ep_q[slot]] && !ep_failed_q[rd_wait_ep_q[slot]] &&
          !rd_wait_release_q[slot]);
  end
  always_ff @(posedge i_clk) begin
    for (int slot = 0; slot < 8; slot++)
    if (i_rst) rd_wait_ref_q[slot] <= 1'b0;
    else rd_wait_ref_q[slot] <= !(i_read_valid && i_read_id == 3'(slot)) &&
        (rd_wait_ref[slot] || (Multi && wait_attach && selected_read_q == 3'(slot)));
    if (sim_reset_seen_q && !i_rst) begin
      p_read_wait_exact : assert (rd_wait_q == rd_wait_ref);
      p_load_ep_free_exact : assert (load_ep_free == load_ep_free_ref);
    end
  end
`endif
`endif
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ld_done_q <= '0;
      ld_store_q <= '0;
      ld_prefetch_q <= '0;
      drain_q <= 1'b0;
      installed_q <= '0;
      same_line_q <= '0;
      store_same_line_q <= 1'b0;
      rd_wait_release_q <= '0;
      for (int ep = 0; ep < EpSlots; ep++) begin
        ld_line_q[ep] <= '0;
        ld_read_q[ep] <= '0;
        ld_status_q[ep] <= coherence_pkg::Consumed;
      end
      for (int slot = 0; slot < 8; slot++) rd_wait_ep_q[slot] <= '0;
    end else if (Multi) begin
      store_same_line_q <= 1'b0;
      drain_q <= amo_waiting || i_sc_valid || maint_q;
      for (int ep = 0; ep < MISSES; ep++) begin
        same_line_q[ep] <= live[ep] && lookup_addr_q[ADDR_WIDTH-1:5] ==
            (ep == 0 ? acquisition_q.addr[ADDR_WIDTH-1:5] : ld_line_q[ep]);
        if (ep > 0 && live[ep] && (ld_line_q[ep] == pending_addr_q[ADDR_WIDTH-1:5] ||
            (ep_store[ep] && (HomeSets == 1 ||
             ld_line_q[ep][HomeOffset-5+:HomeSetBits] == pending_addr_q[HomeOffset+:HomeSetBits]) &&
             ld_line_q[ep][ADDR_WIDTH-6:HomeOffset-5] != pending_addr_q[ADDR_WIDTH-1:HomeOffset])))
          store_same_line_q <= 1'b1;
        if (ep_request_valid[ep] && !live[ep]) begin
          installed_q[ep] <= 1'b0;
          if (ep > 0) begin
            ld_prefetch_q[ep] <= StreamEnabled && operation_q == PrefetchOp;
            ld_line_q[ep] <= lookup_addr_q[ADDR_WIDTH-1:5];
            // A speculative acceptance leaves an unrelated read slot here;
            // every use of ld_read_q tests ld_prefetch_q.
            ld_read_q[ep] <= selected_read_q;
            ld_done_q[ep] <= 1'b0;
            ld_store_q[ep] <= operation_q == LookaheadOp;
            ld_status_q[ep] <= coherence_pkg::Consumed;
          end
        end
        if (ep_install[ep]) installed_q[ep] <= 1'b1;
        if (ep_failed[ep] && ep > 0) begin
          ld_done_q[ep] <= 1'b1;
          ld_status_q[ep] <= ep_fail_error[ep] ? coherence_pkg::Error : coherence_pkg::Consumed;
        end
        if (grant_install && grant_ep_q == EpBits'(ep) && ep > 0) ld_done_q[ep] <= 1'b1;
      end
      for (int slot = 0; slot < 8; slot++) begin
        if (wait_attach && selected_read_q == 3'(slot)) begin
          rd_wait_ep_q[slot] <= same_line_ep;
          rd_wait_release_q[slot] <= installed_q[same_line_ep];
        end
      end
    end
  end
`ifndef SYNTHESIS
  // The answer flag is clear when a grant enters Lookup, so a load endpoint's
  // answer falls in that cycle.
  logic lookup_seen_q;
  always_ff @(posedge i_clk) begin
    lookup_seen_q <= phase_q == Lookup;
    if (sim_reset_seen_q && !i_rst && Multi && phase_q == Lookup && !lookup_seen_q &&
        operation_q == GrantOp)
      p_grant_answer_fresh : assert (!grant_answered_q);
  end
`ifndef FORMAL
  // Endpoints whose current acquisition has answered its read. A load endpoint
  // answers the ordinary load it acquired for, once per acquisition; its
  // installation completes no read. The control BMCs cannot afford these
  // checks, so they run in simulation.
  logic [EpSlots-1:0] answered_q;
  always_ff @(posedge i_clk) begin
    for (int ep = 0; ep < EpSlots; ep++)
      if (i_rst || (ep_request_valid[ep] && ep_request_ready[ep])) answered_q[ep] <= 1'b0;
      else if (grant_answer && grant_ep_q == EpBits'(ep)) answered_q[ep] <= 1'b1;
    if (sim_reset_seen_q && !i_rst && Multi) begin
      if (phase_q == Lookup && operation_q == GrantOp && grant_ep_q != '0)
        p_grant_answer_flag : assert (grant_answered_q == answered_q[grant_ep_q]);
      if (grant_answer) begin
        p_grant_answer_once : assert (!answered_q[grant_ep_q]);
        p_grant_answer_read : assert (live[grant_ep_q] && !ld_prefetch_q[grant_ep_q] &&
            rd_valid_q[ld_read_q[grant_ep_q]] && !rd_ready_q[ld_read_q[grant_ep_q]] &&
            rd_kind_q[ld_read_q[grant_ep_q]] == ReadLoad);
      end
    end
  end
`endif
  // Live endpoints hold distinct lines. Home atomics drain load endpoints.
  // Local atomics exclude only their sector and endpoint 0, while holding
  // service through installation. The unbounded stream proof defines
  // STREAM_UNBOUNDED_PROOF to leave out the checks it does not close; the
  // stream BMCs check them to their depth.
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst && Multi) begin
`ifndef STREAM_UNBOUNDED_PROOF
      for (int ep = 0; ep < MISSES; ep++)
      for (int other = 0; other < MISSES; other++)
      if (ep < other && live[ep] && live[other])
        assert ((ep == 0 ? acquisition_q.addr[ADDR_WIDTH-1:5] : ld_line_q[ep]) != ld_line_q[other]);
`endif
      for (int ep = 0; ep < MISSES; ep++) begin
        if (live[ep] && ld_prefetch_q[ep]) begin
          assert (StreamEnabled && ep >= MISSES - PrefetchCount && ep != 0);
          assert (!ep_read_fail[ep]);
        end
        if (ep_request_valid[ep] && operation_q == PrefetchOp) begin
          assert (acquisition.opcode == coherence_pkg::GetS &&
              acquisition.size == 3 && acquisition.offset == 0 && acquisition.mask == 0);
`ifndef STREAM_UNBOUNDED_PROOF
          assert (lookup_in_window && !prefetch_cancel && !lookup_conflict_q && !i_p_valid);
`endif
          assert (ep >= MISSES - PrefetchCount && ep != 0);
        end
      end
      if (grant_prefetch_q) p_prefetch_fill_isolation : assert (!read_fill);
      // Grant service reads ld_read_q only through the captured flag, which
      // matches the live endpoint's own flag.
      if (operation_q == GrantOp && phase_q != Idle && grant_ep_q != '0)
        p_grant_prefetch_flag : assert (live[grant_ep_q] &&
            grant_prefetch_q == ld_prefetch_q[grant_ep_q]);
      if (read_failure && grant_pick != '0)
        p_failure_read_demand : assert (!ld_prefetch_q[grant_pick]);
      if (operation_q == PrefetchOp) p_prefetch_lookup_isolation : assert (!read_hit && !read_miss);
      if (active && phase_q == Acquire && operation_q == PrefetchOp) begin
        p_prefetch_acquire_guard : assert (prefetch_acquire_ok ==
            (!prefetch_cancel && !lookup_conflict_q && !i_p_valid && !load_acquire_block));
        if (!prefetch_cancel)
          p_bounded_prefetch_acquire_window : assert (lookup_in_window && !stream_replace);
      end
      if (grant_read_hold) assert (!grant_ready && !read_failure && !ep_grant_valid[0]);
      if (grant_read_yield) begin
        assert (!grant_ready && !read_failure && !ep_grant_valid[0]);
        assert (!prefetch_cancel && !local_turn_q);
      end
      if (load_acquire_block) assert (ep_request_valid[EpSlots-1:1] == 0);
`ifndef STREAM_UNBOUNDED_PROOF
      if (atomic_q && atomic_granted_q)
        for (int ep = 1; ep < MISSES; ep++)
        if (atomic_local_q) assert (!live[ep] || ld_line_q[ep] != atomic_addr_q[ADDR_WIDTH-1:5]);
        else assert (!live[ep]);
`endif
      if (grant_ready && grant_valid && grant_pick != '0) assert (wb_free);
      if (active && phase_q == LookupWait && array_valid && operation_q == GrantOp &&
          grant_ep_q != '0 && !array_hit && array_state == coherence_pkg::Modified)
        p_bounded_wb_free_lookup : assert (wb_free);
    end
`endif
`ifndef SYNTHESIS
  always_comb
    if (sim_reset_seen_q && !i_rst && grant_valid) begin
      assert (pick_onehot == EpSlots'(1) << grant_pick);
      assert (failure_read_slot == (grant_pick == '0 ? acquisition_read_q : ld_read_q[grant_pick]));
    end
`endif

  for (genvar slot = 0; slot < 2; slot++) begin : gen_put
    coh_w_t put_message;
    assign put_message   = wb[slot];
    assign wb_addr[slot] = put_message.addr;
    coherence_put_endpoint #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .HART(0),
        .SLOT(slot)
    ) put (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_epoch(1'b0),
        .i_freeze_valid(active && phase_q == Freeze && freeze_slot_q == 1'(slot)),
        .o_freeze_ready(wb_freeze_ready[slot]),
        .i_freeze(freeze),
        .o_w_valid(wb_valid[slot]),
        .i_w_ready(wb_ready[slot]),
        .o_w(wb[slot]),
        .i_absorb_valid(active && phase_q == ProbeAbsorb && probe_put_q == 1'(slot)),
        .o_absorb_ready(wb_absorb_ready[slot]),
        .o_absorb_offer(wb_absorb_offer[slot]),
        .i_absorb_tid(probe_q.tid),
        .i_absorb_addr(probe_q.addr),
        .i_absorb_epoch(probe_q.epoch),
        .o_absorbed(wb_absorbed[slot]),
        .i_wa_valid(i_wa_valid),
        .o_wa_ready(wb_wa_ready[slot]),
        .i_wa(i_wa),
        .o_cancel_valid(),
        .o_live(wb_live[slot]),
        .o_fatal(wb_fatal[slot])
    );
    assign wb_ready[slot] = wb_selected_q && wb_select_q == 1'(slot) && i_w_ready;
  end
  assign o_w_valid = active && wb_selected_q && wb_valid[wb_select_q];
  assign o_w = wb[wb_select_q];
  assign o_wa_ready = |wb_wa_ready;
  assign freeze = {1'b0, freeze_slot_q, 1'b0, freeze_addr_q, freeze_data_q, freeze_maintenance_q};

  logic [8*ADDR_WIDTH-1:0] rd_addr_flat, rd_stored_addr_flat;
  logic [15:0] rd_kind_flat;
  logic [ADDR_WIDTH-1:0] rd_selected_addr;
  for (genvar read_slot = 0; read_slot < 8; read_slot++) begin : gen_read_payload
    assign rd_addr_flat[read_slot*ADDR_WIDTH+:ADDR_WIDTH] = rd_addr_q[read_slot];
    assign rd_stored_addr_flat[read_slot*ADDR_WIDTH+:ADDR_WIDTH] =
        rd_stored_payload_flat[read_slot*ReadPayloadWidth+ReadPayloadWidth-ADDR_WIDTH+:ADDR_WIDTH];
    assign rd_kind_flat[read_slot*2+:2] = rd_kind_q[read_slot];
  end
  coherence_read_select #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .FORMAL_STANDALONE_ENV(1'b0)
  ) read_select (
      .i_clk(i_clk),
      .i_valid(rd_valid_q),
      .i_ready(rd_ready_q),
      .i_miss(rd_miss_q),
      .i_kind(rd_kind_flat),
      .i_addr(rd_addr_flat),
      .i_stored_addr(rd_stored_addr_flat),
      .i_write_addr(rd_write_payload[ReadPayloadWidth-ADDR_WIDTH+:ADDR_WIDTH]),
      .i_write_mask(rd_write_mask),
      .i_round_robin(rd_rr_q),
      .i_block_valid(o_block_valid),
      .i_block_addr(o_block_addr),
      .i_wb_live(wb_live),
      .i_wb_addr(wb_addr),
      .i_atomic_protected(i_atomic_protected),
      .i_owned(rd_owned | path_select_owned),
      .i_waiting(rd_waiting),
      .i_miss_retry(rd_miss_retry),
      .o_found(rd_candidate),
      .o_load_miss(rd_load_miss),
      .o_index(rd_pick),
      .o_address(rd_selected_addr)
  );

  always_comb begin
    wb_free = 1'b0;
    wb_free_slot = 1'b0;
    wb_match = 1'b0;
    wb_match_slot = 1'b0;
    pending_blocked = 1'b0;
    tail_wb_blocked = 1'b0;
    lookup_wb_conflict = 1'b0;
    for (int slot = 1; slot >= 0; slot--) begin
      if (!wb_live[slot] && !(wb_reserved_q && reserved_wb_q == 1'(slot))) begin
        wb_free = 1'b1;
        wb_free_slot = 1'(slot);
      end
      if (wb_live[slot] && wb_addr[slot] == (probe_capture ? probe_in.addr : probe_q.addr)) begin
        wb_match = 1'b1;
        wb_match_slot = 1'(slot);
      end
      if (wb_live[slot] && wb_addr[slot][ADDR_WIDTH-1:5] == pending_addr_q[ADDR_WIDTH-1:5])
        pending_blocked = 1'b1;
      if (wb_live[slot] && wb_addr[slot][ADDR_WIDTH-1:5] == tail_addr[ADDR_WIDTH-1:5])
        tail_wb_blocked = 1'b1;
      if (wb_live[slot] && wb_addr[slot][ADDR_WIDTH-1:5] == lookup_addr_q[ADDR_WIDTH-1:5])
        lookup_wb_conflict = 1'b1;
    end
    rd_response = 1'b0;
    rd_result   = '0;
    for (int index = 7; index >= 0; index--) begin
      if (rd_ready_q[3'(rd_response_rr_q+3'(index))]) begin
        rd_response = 1'b1;
        rd_result   = 3'(rd_response_rr_q + 3'(index));
      end
    end
    exclude = '0;
    if (atomic_q && atomic_granted_q && (probe_launch ? probe_atomic_set : lookup_atomic_set))
      exclude[atomic_way_q] = 1'b1;
    acquisition = '0;
    acquisition.q.id = 4'(acq_ep_q);
    acquisition.size = 3'd3;
    acquisition.opcode = coherence_pkg::GetS;
    acquisition.addr = {lookup_addr_q[ADDR_WIDTH-1:5], 5'b0};
    acquisition.offset = lookup_addr_q[4:0];
    if (operation_q == StoreOp || operation_q == LookaheadOp) begin
      acquisition.opcode = coherence_pkg::GetM;
      acquisition.mask   = store_mask[store_selected_q];
    end else if (StreamEnabled && operation_q == PrefetchOp) begin
      acquisition.offset = '0;
    end else if (atomic_q && atomic_sc_q) begin
      acquisition.opcode = coherence_pkg::StoreConditional;
      acquisition.size   = atomic_size_q;
    end else begin
      acquisition.size = rd_size_q[selected_read_q];
      if (rd_kind_q[selected_read_q] == ReadLR) acquisition.opcode = coherence_pkg::LoadReserved;
      if (rd_kind_q[selected_read_q] == ReadAMO) acquisition.opcode = coherence_pkg::Atomic;
    end
  end

  // Physical record comparisons are sampled before ordered selection.
  // A conflicting home set cannot pin a younger row ahead of an older store.
  // A resident lookahead is only a scheduling hint; the head rechecks tags.
  always_comb begin
    look_owner_conflict = '0;
    for (int slot = 0; slot < 4; slot++) begin
      for (int ep = 0; ep < MISSES; ep++)
      if (live[ep] &&
          (store_addr[slot][ADDR_WIDTH-1:5] ==
           (ep == 0 ? acquisition_q.addr[ADDR_WIDTH-1:5] : ld_line_q[ep]) ||
           (ep_store[ep] && (HomeSets == 1 ||
            store_addr[slot][HomeOffset+:HomeSetBits] ==
            (ep == 0 ? acquisition_q.addr[HomeOffset+:HomeSetBits] :
             ld_line_q[ep][HomeOffset-5+:HomeSetBits])) &&
            store_addr[slot][ADDR_WIDTH-1:HomeOffset] !=
            (ep == 0 ? acquisition_q.addr[ADDR_WIDTH-1:HomeOffset] :
             ld_line_q[ep][ADDR_WIDTH-6:HomeOffset-5])))) look_owner_conflict[slot] = 1'b1;
      for (int wb_slot = 0; wb_slot < 2; wb_slot++)
      if (wb_live[wb_slot] && wb_addr[wb_slot][ADDR_WIDTH-1:5] ==
          store_addr[slot][ADDR_WIDTH-1:5]) look_owner_conflict[slot] = 1'b1;
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      look_pair_conflict_q <= '0;
      look_owner_conflict_q <= '0;
      look_other_row_q <= '0;
      look_snapshot_valid_q <= 1'b0;
    end else begin
      look_owner_conflict_q <= look_owner_conflict;
      look_snapshot_valid_q <= !store_pop && !store_push;
      for (int slot = 0; slot < 4; slot++) begin
        look_other_row_q[slot] <= store_addr[slot][ADDR_WIDTH-1:HomeOffset] !=
            pending_addr_q[ADDR_WIDTH-1:HomeOffset];
        for (int older = 0; older < 4; older++)
          look_pair_conflict_q[slot][older] <=
              store_addr[slot][ADDR_WIDTH-1:5] == store_addr[older][ADDR_WIDTH-1:5] ||
              ((HomeSets == 1 || store_addr[slot][HomeOffset+:HomeSetBits] ==
                store_addr[older][HomeOffset+:HomeSetBits]) &&
               store_addr[slot][ADDR_WIDTH-1:HomeOffset] !=
               store_addr[older][ADDR_WIDTH-1:HomeOffset]);
      end
    end
  end
  always_comb begin
    borrowed_live = |(live[EpSlots-1:1] & ep_store[EpSlots-1:1]);
    look_blocked = store_acquired | store_checked_q | ~store_valid | look_owner_conflict_q;
    if (!look_snapshot_valid_q) look_blocked = '1;
    for (int slot = 0; slot < 4; slot++) begin
      for (int older = 0; older < 4; older++)
      if (store_valid[older] && 2'(2'(older) - store_head_index) <
          2'(2'(slot) - store_head_index) && look_pair_conflict_q[slot][older])
        look_blocked[slot] = 1'b1;
    end
    look_found = 1'b0;
    look_index = '0;
    for (int age = 3; age >= 1; age--)
    if (!look_blocked[2'(store_head_index+2'(age))]) begin
      look_found = 1'b1;
      look_index = 2'(store_head_index + 2'(age));
    end
    for (int age = 3; age >= 1; age--)
    if (!look_blocked[2'(store_head_index+2'(age))] &&
        look_other_row_q[2'(store_head_index+2'(age))]) begin
      look_found = 1'b1;
      look_index = 2'(store_head_index + 2'(age));
    end
  end
  assign look_available = MISSES >= 3 && look_valid_q && !borrowed_live && load_ep_free &&
      !load_block && !i_sc_valid && !i_maint_valid && !amo_waiting &&
      store_valid[look_index_q] && !store_acquired[look_index_q] &&
      !store_checked_q[look_index_q] && look_index_q != store_head_index;
  assign look_ready = look_available && !(read_waiting_q && store_read_turn_q);
  assign look_retry = look_read_turn_q && rd_load_miss &&
      (!array_hit || array_state != coherence_pkg::Modified);
  assign read_yield_look = active && phase_q == LookupWait && array_valid &&
      operation_q == ReadOp && selected_kind_q == ReadLoad && !(shadow_q && path_hit_q) &&
      !array_hit && !same_line && look_available && !look_read_turn_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      look_valid_q <= 1'b0;
      look_index_q <= '0;
      look_addr_q <= '0;
      look_read_turn_q <= 1'b0;
      look_priority_q <= 1'b0;
      look_priority_index_q <= '0;
      store_checked_q <= '0;
    end else begin
      look_valid_q <= look_found && !store_pop && !store_push;
      look_index_q <= look_index;
      look_addr_q <= store_addr[look_index];
      if (look_priority_q && (!store_valid[look_priority_index_q] ||
          look_priority_index_q == store_head_index || store_acquired[look_priority_index_q] ||
          store_checked_q[look_priority_index_q] || i_sc_valid || i_maint_valid ||
          amo_waiting || load_block)) look_priority_q <= 1'b0;
      for (int slot = 0; slot < 4; slot++)
        if (!store_valid[slot] || (store_pop && store_head_index == 2'(slot)))
          store_checked_q[slot] <= 1'b0;
      if (active && phase_q == LookupWait && array_valid && operation_q == LookaheadOp) begin
        if (!look_retry) store_checked_q[store_selected_q] <= 1'b1;
        // A lookahead hit consumes no endpoint and yields the allocation turn.
        look_read_turn_q <= 1'b1;
        look_priority_q <= 1'b0;
      end
      if (active && phase_q == Acquire && acquire_ready && acq_ep_q != '0) begin
        look_read_turn_q <= operation_q == LookaheadOp;
        look_priority_q <= 1'b0;
      end
      // A yielded miss reserves lookahead service ahead of head-store hits.
      if (read_yield_look) begin
        look_priority_q <= 1'b1;
        look_priority_index_q <= look_index_q;
      end
    end
  end

  // Eligible read lookups and grants receive a turn between store selections.
  // Read demand is registered before store selection and continuation.
  // A continuation uses a resident tail and a comparison from the preceding
  // cycle. Freeze and probe service cannot run beside a StoreOp update.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      tail_wb_blocked_q <= 1'b0;
      store_read_turn_q <= 1'b0;
      read_waiting_q <= 1'b0;
      tail_checked_q <= 1'b0;
    end else begin
      tail_wb_blocked_q <= tail_wb_blocked;
      read_waiting_q <= read_service_waiting;
      if (active && phase_q == LookupWait && array_valid && operation_q == StoreOp)
        store_read_turn_q <= 1'b1;
      if (active && phase_q == LookupWait && array_valid && operation_q == LookaheadOp)
        store_read_turn_q <= 1'b1;
      if (store_pop && operation_q == GrantOp) store_read_turn_q <= 1'b1;
      if (active && phase_q == Lookup && (operation_q == ReadOp ||
          (operation_q == GrantOp && !selected_grant_store && !grant_prefetch_q)))
        store_read_turn_q <= 1'b0;
      tail_checked_q <= tail_q && !store_pop;
    end
  end
  assign store_continue = tail_q && tail_checked_q && !tail_wb_blocked_q &&
      !(store_read_turn_q && read_waiting_q) &&
      !i_p_valid && !probe_valid_q && !o_r_valid && !grant_valid &&
      !store_acquired[store_next_index];
  assign array_skip_data = active && phase_q == Lookup &&
      (operation_q == StoreOp || operation_q == LookaheadOp) &&
      !probe_launch;

  // Classification consumes registered lookup results. A conflicting
  // endpoint or frozen sector requires a fresh lookup.
  assign local_admit = !local_conflict_q && !request_live && !pending_q &&
      !probe_valid_q && cut_phase_q == CutIdle && i_atomic_protected;
  assign local_decision = active && phase_q == LocalCheck &&
      (local_hit_q ? local_admit :
       (operation_q == SCOp || (!any_live && wb_free && !pending_q && i_atomic_protected)));
  assign local_sc_match = i_reservation_valid && i_reservation_addr == atomic_addr_q &&
      i_reservation_size == atomic_size_q;
`ifdef LOCAL_ATOMIC_DEPENDENCY
  assign o_formal_local = atomic_local_q;
  assign o_formal_phase = phase_q;
  assign o_formal_home_write = active && phase_q == LookupWait && array_valid &&
      operation_q == AtomicWriteOp && atomic_q && !atomic_sc_q && !atomic_local_q;
`endif
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      local_hit_q <= 1'b0;
      local_conflict_q <= 1'b0;
      rd_local_retry_q <= '0;
    end else begin
      if (phase_q == LookupWait && array_valid) begin
        local_hit_q <= array_hit && array_state == coherence_pkg::Modified;
        local_conflict_q <= request_live || same_line || lookup_wb_conflict ||
            pending_q || store_push;
        if (operation_q == ReadOp && selected_kind_q == ReadAMO && !(shadow_q && path_hit_q))
          rd_local_retry_q[selected_read_q] <= array_hit && array_state == coherence_pkg::Modified;
      end
      // A new read clears its slot's flag from the buffered write's mask, a
      // cycle before the read can reach a lookup or use its retry.
      for (int slot = 0; slot < 8; slot++) if (rd_write_mask[slot]) rd_local_retry_q[slot] <= 1'b0;
    end
  end

  coherence_array #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(32),
      .CACHE_BYTES(CACHE_BYTES),
      .WAYS(WAYS),
      .BIMODAL_INSERT(1'b1),
      .SIM_FAST_MAINT(SIM_FAST_MAINT),
      .HIT_PORT(1'b1)
  ) array (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .o_init_done(),
      .i_req_valid((active && phase_q == Lookup) || probe_launch),
      .o_req_ready(array_ready),
      .i_req_addr(array_request_addr),
      .i_req_exclude(exclude),
      .i_req_visit(!probe_launch && operation_q == MaintOp && !maint_line_q),
      .i_req_way(maint_way_q),
      .i_req_skip_data_on_hit(array_skip_data),
      .i_req_data_if_modified(probe_launch || operation_q == ProbeOp),
      // A CPU read uses data only on a hit; its miss decision follows the
      // tag result. A grant needs the replaced line's data only to freeze a
      // Modified victim.
      .i_req_data_if_hit(!probe_launch && operation_q == ReadOp),
      .i_req_data_if_victim_modified(!probe_launch && operation_q == GrantOp),
      // A resident hint is not a CPU access and keeps the line's age, and a
      // shadow lookup leaves the age to the hit path.
      .i_req_no_touch((StreamEnabled && !probe_launch && operation_q == PrefetchOp) ||
          shadow_req),
      .i_req_tags_only(shadow_req),
      .o_resp_valid(array_valid),
      .i_resp_ready(phase_q == LookupWait),
      .o_resp_hit(array_hit),
      .o_resp_available(array_available),
      .o_resp_way(array_way),
      .o_resp_addr(array_addr),
      .o_resp_state(array_state),
      .o_resp_data_valid(array_data_valid),
      .o_resp_data(array_data),
      .i_update_valid(active && phase_q == Update),
      .o_update_ready(update_ready),
      .i_update_addr(update_addr_q),
      .i_update_way(way_q),
      .i_update_state(state_q),
      .i_update_insert(operation_q == GrantOp),
      .i_update_touch(grant_touch_q),
      .i_update_mask(update_mask_q),
      .i_update_data(image_q),
      .i_hp_valid(path_offer),
      .i_hp_addr(path_addr_q),
      .o_hp_ready(path_ready),
      .o_hp_hit(path_hit),
      .o_hp_data(path_data)
  );

  // ===========================================================================
  // Hit path
  // ===========================================================================
  // A new load is offered to the array's hit port in the cycle after it
  // arrives (stage 1), from registers. The port reads a copy of the tags and
  // every way's row of the load's set on one edge, so a hit answers from one
  // image of the array: stage 2 compares the tags, stage 3 selects the dword,
  // and stage 4 completes the read's slot, whose response then leaves like
  // any other. The controller keeps every other job. A read that it selects
  // while the hit path holds it gets a shadow lookup, which reads tags only
  // and answers nothing when either lookup hits; a read that misses both
  // takes the miss path from that lookup.
  always_ff @(posedge i_clk) begin
    if (i_rst) path_req_q <= 1'b0;
    else path_req_q <= i_read_valid && i_read_kind == ReadLoad;
    path_id_q <= i_read_id;
    path_addr_q <= i_address;
  end
  // Stage 1 takes a load that read selection could take in the same cycle:
  // no probe in service, no owner of its slot, and no holder of its sector by
  // read_select's rule for the buffered write.
  always_comb begin
    path_blocked = 1'b0;
    for (int holder = 0; holder < 4; holder++)
      path_blocked |= o_block_valid[holder] &&
          path_addr_q[5+:18] == o_block_addr[holder][5+:18];
    for (int slot = 0; slot < 2; slot++)
      path_blocked |= wb_live[slot] && path_addr_q[5+:18] == wb_addr[slot][5+:18];
  end
  assign path_offer = path_req_q && active && !probe_valid_q && !rd_owned[path_id_q] &&
      !path_blocked;
  assign path_take = path_offer && path_ready;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      s2_valid_q <= 1'b0;
      s3_valid_q <= 1'b0;
      s4_valid_q <= 1'b0;
    end else begin
      s2_valid_q <= path_take;
      s3_valid_q <= s2_valid_q;
      s4_valid_q <= s3_valid_q && path_hit;
    end
    s2_slot_q <= path_id_q;
    s2_line_q <= path_addr_q[ADDR_WIDTH-1:5];
    s3_slot_q <= s2_slot_q;
    s3_line_q <= s2_line_q;
    s4_slot_q <= s3_slot_q;
  end
  // The hit path holds a slot from its stage-3 hit until its answer. Read
  // selection leaves out only the stage-4 slot, from the stage registers, so a
  // read selected in its stage-3 cycle reaches its first lookup in stage 4
  // after a hit, or out of the hit path after a miss.
  assign path_owned = (s3_valid_q && path_hit ? 8'd1 << s3_slot_q : 8'd0) |
      (s4_valid_q ? 8'd1 << s4_slot_q : 8'd0);
  assign path_select_owned = s4_valid_q ? 8'd1 << s4_slot_q : 8'd0;
  // A read's first Lookup cycle decides from the stage registers whether its
  // lookup is a shadow, since the array takes the request flags in that cycle.
  assign first_lookup = phase_q == Lookup && prev_idle_q && operation_q == ReadOp;
  assign shadow_now = first_lookup && ((s2_valid_q && s2_slot_q == selected_read_q) ||
      (s3_valid_q && path_hit && s3_slot_q == selected_read_q) ||
      (s4_valid_q && s4_slot_q == selected_read_q));
  assign shadow_req = first_lookup ? shadow_now :
      shadow_q && phase_q == Lookup && operation_q == ReadOp;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      prev_idle_q <= 1'b0;
      shadow_q <= 1'b0;
      path_hit_q <= 1'b0;
    end else begin
      prev_idle_q <= phase_q == Idle;
      if (phase_q == Idle) begin
        shadow_q <= 1'b0;
        path_hit_q <= 1'b0;
      end else if (first_lookup) begin
        shadow_q <= shadow_now;
        path_hit_q <= (s3_valid_q && path_hit && s3_slot_q == selected_read_q) ||
            (s4_valid_q && s4_slot_q == selected_read_q);
      end else if (shadow_q && s3_valid_q && path_hit && s3_slot_q == selected_read_q) begin
        path_hit_q <= 1'b1;
      end
    end
  end
  // Hit-path hits train the stream detector through two entries, on its
  // second input, which it compares separately and takes in cycles without a
  // controller report. A hit that finds both entries full is dropped, which
  // can only delay a confirmed stream's advance.
  assign demand_report = active && phase_q == LookupWait && array_valid &&
      operation_q == ReadOp && selected_kind_q == ReadLoad &&
      !perf_read_seen_q[selected_read_q] && !shadow_skip;
  assign path_queue_pop = path_queue_valid_q[0] && !demand_report;
  // A hit of the line just queued adds nothing.
  assign path_queue_push = StreamEnabled && s3_valid_q && path_hit &&
      !(path_queue_valid_q[1] ? path_queue_q[1] == s3_line_q :
        path_queue_valid_q[0] && path_queue_q[0] == s3_line_q);
  always_comb begin
    path_queue_valid_next = path_queue_valid_q;
    path_queue_next = path_queue_q;
    if (path_queue_pop) begin
      path_queue_valid_next = {1'b0, path_queue_valid_q[1]};
      path_queue_next[0] = path_queue_q[1];
    end
    if (path_queue_push) begin
      if (!path_queue_valid_next[0]) begin
        path_queue_valid_next[0] = 1'b1;
        path_queue_next[0] = s3_line_q;
      end else if (!path_queue_valid_next[1]) begin
        path_queue_valid_next[1] = 1'b1;
        path_queue_next[1] = s3_line_q;
      end
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst || prefetch_cancel) path_queue_valid_q <= '0;
    else path_queue_valid_q <= path_queue_valid_next;
    path_queue_q <= path_queue_next;
  end
`ifdef FORMAL
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      c_path_answer : cover (s4_valid_q);
      c_path_shadow_skip : cover (active && phase_q == LookupWait && array_valid &&
          operation_q == ReadOp && shadow_skip);
      c_path_shadow_miss : cover (active && phase_q == Acquire && shadow_q);
      c_path_block_refusal : cover (path_req_q && path_blocked);
      c_path_probe_refusal : cover (path_req_q && probe_valid_q);
      c_path_array_refusal : cover (path_offer && !path_ready);
    end
  end
`endif
`ifndef SYNTHESIS
`ifndef FORMAL
  // Simulation counters for the hit path, and for stream hints that hold the
  // controller while a demand read is eligible, printed at the end of a run.
  int unsigned sim_path_offers, sim_path_takes, sim_path_hits, sim_path_refused;
  int unsigned sim_shadows, sim_shadow_skips, sim_path_queue_drops;
  int unsigned sim_hints, sim_hint_waits;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      sim_path_offers <= 0;
      sim_path_takes <= 0;
      sim_path_hits <= 0;
      sim_path_refused <= 0;
      sim_shadows <= 0;
      sim_shadow_skips <= 0;
      sim_path_queue_drops <= 0;
      sim_hints <= 0;
      sim_hint_waits <= 0;
    end else begin
      if (path_req_q) sim_path_offers <= sim_path_offers + 1;
      if (path_take) sim_path_takes <= sim_path_takes + 1;
      if (s4_valid_q) sim_path_hits <= sim_path_hits + 1;
      if (path_offer && !path_ready) sim_path_refused <= sim_path_refused + 1;
      if (first_lookup && shadow_now) sim_shadows <= sim_shadows + 1;
      if (active && phase_q == LookupWait && array_valid && operation_q == ReadOp && shadow_skip)
        sim_shadow_skips <= sim_shadow_skips + 1;
      if (path_queue_push && path_queue_valid_q[1] && !path_queue_pop)
        sim_path_queue_drops <= sim_path_queue_drops + 1;
      if (phase_q == Lookup && prev_idle_q && operation_q == PrefetchOp)
        sim_hints <= sim_hints + 1;
      if (operation_q == PrefetchOp && phase_q != Idle && rd_candidate)
        sim_hint_waits <= sim_hint_waits + 1;
    end
  end
  final begin
    if (sim_reset_seen_q && sim_path_offers != 0) begin
      $write("L1D hit path: offers %0d takes %0d hits %0d refused %0d shadows %0d skips %0d",
             sim_path_offers, sim_path_takes, sim_path_hits, sim_path_refused, sim_shadows,
             sim_shadow_skips);
      $display(" stream drops %0d hints %0d hint waits %0d", sim_path_queue_drops, sim_hints,
               sim_hint_waits);
    end
  end
`endif
`endif

  // Idle selections shared by the controller and the lookup address.
  assign atomic_sc_selected = atomic_q && atomic_sc_q && !request_live &&
      (!sc_home_q || (!any_live && wb_free));
  assign read_selected = rd_candidate && !(maint_eligible && maint_turn_q);
  // The selected request's address, in the controller's Idle priority. A read
  // joins last because its address settles last. A cycle that selects nothing
  // captures a value no one reads.
  always_comb begin
    lookup_other = hint_addr_q;
    lookup_other_valid = 1'b1;
    if (probe_valid_q) lookup_other = probe_q.addr;
    else if (probe_priority) lookup_other = probe_in.addr;
    else if (grant_read_hold) lookup_other_valid = 1'b0;
    else if (grant_valid) lookup_other = grant.addr;
    else if (i_sc_valid && o_sc_ready) lookup_other = i_sc_address;
    else if (atomic_write_q || atomic_sc_selected) lookup_other = atomic_addr_q;
    else if (store_head_ready) lookup_other = pending_addr_q;
    else if (look_ready) lookup_other = look_addr_q;
    else if (read_selected) lookup_other_valid = 1'b0;
    else if (maint_eligible)
      lookup_other = maint_line_q ? maint_addr_q : ADDR_WIDTH'(maint_set_q) << 5;
  end
  // Lookup and grant payloads are read only after Idle hands them to the
  // controller, so they have no reset or stop term and capture every Idle
  // cycle.
  always_ff @(posedge i_clk) begin
    if (phase_q == Idle) begin
      lookup_addr_q <= lookup_other_valid ? lookup_other : rd_selected_addr;
      selected_read_q <= rd_pick;
      grant_q <= grant;
      grant_ep_q <= grant_pick;
      grant_prefetch_q <= StreamEnabled && ld_prefetch_q[grant_pick];
    end else if (phase_q == UpdateWait && operation_q == StoreOp) lookup_addr_q <= tail_addr;
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      phase_q <= Idle;
      operation_q <= ReadOp;
      rd_valid_q <= '0;
      rd_ready_q <= '0;
      rd_miss_q <= '0;
      rd_error_q <= '0;
      rd_rr_q <= '0;
      rd_response_rr_q <= '0;
      o_read_valid <= 1'b0;
      o_read_id <= '0;
      o_read_data <= '0;
      o_read_error <= 1'b0;
      pending_miss_q <= 1'b0;
      atomic_q <= 1'b0;
      atomic_local_q <= 1'b0;
      atomic_read_q <= '0;
      sc_home_q <= 1'b0;
      atomic_sc_q <= 1'b0;
      atomic_granted_q <= 1'b0;
      atomic_written_q <= 1'b0;
      sc_committed_q <= 1'b0;
      atomic_addr_q <= '0;
      block_zero_addr_q <= '0;
      atomic_size_q <= '0;
      atomic_tag_q <= '0;
      atomic_write_q <= 1'b0;
      atomic_data_q <= '0;
      atomic_mask_q <= '0;
      atomic_way_q <= '0;
      sc_checked_q <= 1'b0;
      sc_tid_q <= '0;
      atomic_done_q <= 1'b0;
      o_sc_write_done <= 1'b0;
      o_sc_result_valid <= 1'b0;
      o_sc_success <= 1'b0;
      o_sc_error <= 1'b0;
      maint_q <= 1'b0;
      maint_turn_q <= 1'b0;
      maint_line_q <= 1'b0;
      maint_addr_q <= '0;
      maint_set_q <= '0;
      maint_way_q <= '0;
      maint_last_q <= 1'b0;
      o_maint_done <= 1'b0;
      probe_valid_q <= 1'b0;
      local_turn_q <= 1'b0;
      read_probe_count_q <= '0;
      probe_absorbed_q <= 1'b0;
      probe_put_q <= 1'b0;
      probe_q <= '0;
      reply_q <= '0;
      o_r_valid <= 1'b0;
      o_cut_release <= 1'b0;
      wb_selected_q <= 1'b0;
      wb_next_q <= 1'b0;
      wb_select_q <= 1'b0;
      reserved_wb_q <= 1'b0;
      wb_reserved_q <= 1'b0;
      store_selected_q <= '0;
      image_q <= '0;
      update_mask_q <= '0;
      state_q <= '0;
      way_q <= '0;
      update_addr_q <= '0;
      freeze_addr_q <= '0;
      freeze_data_q <= '0;
      freeze_slot_q <= 1'b0;
      freeze_maintenance_q <= 1'b0;
      acquisition_q <= '0;
      acquisition_store_q <= 1'b0;
      acquisition_sc_q <= 1'b0;
      acquisition_read_q <= '0;
      acq_ep_q <= '0;
      done_q <= 1'b0;
      written_q <= 1'b0;
      done_status_q <= coherence_pkg::Consumed;
      o_fatal <= 1'b0;
      o_fatal_addr <= '0;
      for (int index = 0; index < 8; index++) begin
        rd_data_q[index] <= '0;
      end
      fail_clear_q <= 1'b0;
      fail_error_q <= 1'b0;
      fail_clear_slot_q <= '0;
    end else begin
      rd_valid_q <= rd_valid_next;
      rd_miss_q <= rd_miss_next;
      rd_ready_q <= rd_ready_next;
      rd_error_q <= rd_error_next;
      fail_clear_q <= read_failure;
      fail_error_q <= |(pick_onehot & ep_fail_error);
      fail_clear_slot_q <= failure_read_slot;
      if (fail_clear_q) rd_data_q[fail_clear_slot_q] <= '0;
      if (s4_valid_q) rd_data_q[s4_slot_q] <= path_data;
      atomic_done_q <= 1'b0;
      o_sc_write_done <= 1'b0;
      o_cut_release <= 1'b0;
      if (i_sc_commit) sc_committed_q <= 1'b1;
      if (!atomic_q && store_push && store_zero_alloc)
        block_zero_addr_q <= {i_address[ADDR_WIDTH-1:5], 5'b0};
      if (active && phase_q == UpdateWait && array_ready && operation_q == GrantOp &&
          grant_ep_q == '0) wb_reserved_q <= 1'b0;
      if (o_sc_result_valid && i_sc_result_ready) o_sc_result_valid <= 1'b0;
      if (!wb_selected_q) begin
        if (|wb_valid) begin
          wb_selected_q <= 1'b1;
          wb_select_q   <= wb_valid[wb_next_q] ? wb_next_q : !wb_next_q;
        end
      end else if ((o_w_valid && i_w_ready) ||
          (i_wa_valid && o_wa_ready && ack.absorbed && ack.put_id == wb_select_q)) begin
        wb_selected_q <= 1'b0;
        wb_next_q <= !wb_select_q;
      end
      if (|wb_fatal) begin
        o_fatal <= 1'b1;
        o_fatal_addr <= fatal_put.addr;
      end
      if (i_u_valid && ep_u_ready[0] && atomic_q && !atomic_local_q) begin
        block_zero_addr_q <= store_push && store_zero_alloc ?
            {i_address[ADDR_WIDTH-1:5], 5'b0} : store_addr[0];
        atomic_q <= 1'b0;
        atomic_granted_q <= 1'b0;
      end
      if (!o_read_valid || i_read_ready) begin
        o_read_valid <= rd_response;
        if (rd_response) begin
          o_read_id <= rd_result;
          o_read_data <= rd_data_q[rd_result];
          o_read_error <= rd_error_q[rd_result];
          rd_response_rr_q <= rd_result + 1'b1;
        end
      end
      if (|i_write_mask) begin
        if (i_write_atomic) begin
          atomic_write_q <= 1'b1;
          atomic_data_q  <= {4{i_write_data}};
          atomic_mask_q  <= 32'(i_write_mask) << {i_address[4:3], 3'b000};
        end
      end
      if (store_pop || (store_push && !pending_q)) begin
        pending_miss_q <= 1'b0;
      end
      if (i_sc_valid && o_sc_ready) begin
        atomic_q <= 1'b1;
        atomic_local_q <= 1'b0;
        sc_home_q <= 1'b0;
        atomic_sc_q <= 1'b1;
        atomic_granted_q <= 1'b0;
        atomic_written_q <= 1'b0;
        sc_committed_q <= 1'b0;
        atomic_addr_q <= i_sc_address;
        block_zero_addr_q <= i_sc_address;
        atomic_size_q <= i_sc_size;
        atomic_tag_q <= i_sc_tag;
        sc_checked_q <= 1'b0;
      end
      if (i_p_valid && o_p_ready) begin
        probe_valid_q <= 1'b1;
        probe_q <= probe_in;
      end
      if (!rd_candidate || (phase_q == Lookup && operation_q == ReadOp))
        read_probe_count_q <= '0;
      else if (o_r_valid && i_r_ready && !(&read_probe_count_q))
        read_probe_count_q <= read_probe_count_q + 1'b1;
      if (phase_q == Idle && !probe_valid_q) local_turn_q <= 1'b0;
      if (o_r_valid && i_r_ready) begin
        local_turn_q <= local_ready;
        o_r_valid <= 1'b0;
        probe_valid_q <= 1'b0;
        if (probe_q.opcode == coherence_pkg::ProbeInvalidate) o_cut_release <= 1'b1;
      end
      if (!i_maint_valid) o_maint_done <= 1'b0;
      if (i_maint_valid && !maint_q && !o_maint_done) begin
        maint_q <= 1'b1;
        maint_set_q <= '0;
        maint_way_q <= '0;
        maint_last_q <= 1'b0;
        maint_line_q <= i_maint_line;
        maint_addr_q <= i_maint_address;
      end
      // Endpoint 0's failed load or SC, from that endpoint's own grant.
      if (zero_grant_failed) begin
        done_q <= 1'b1;
        done_status_q <= ep_fail_error[0] ? coherence_pkg::Error : coherence_pkg::Consumed;
        wb_reserved_q <= 1'b0;
        if (acquisition_sc_q) begin
          o_sc_result_valid <= 1'b1;
          o_sc_success <= 1'b0;
          o_sc_error <= ep_fail_error[0];
        end
      end
      if (active) begin
        case (phase_q)
          Idle: begin
            if (probe_capture && probe_in.opcode != coherence_pkg::CheckSC) begin
              reply_q <= '0;
              reply_q.tid <= probe_in.tid;
              reply_q.epoch <= probe_in.epoch;
              reply_q.addr <= probe_in.addr;
              probe_absorbed_q <= wb_match;
              probe_put_q <= wb_match_slot;
              operation_q <= ProbeOp;
              phase_q <= probe_launch ? LookupWait : Lookup;
            end else if (probe_valid_q && !o_r_valid) begin
              reply_q <= '0;
              reply_q.tid <= probe_q.tid;
              reply_q.epoch <= probe_q.epoch;
              reply_q.addr <= probe_q.addr;
              probe_absorbed_q <= wb_match;
              probe_put_q <= wb_match_slot;
              operation_q <= ProbeOp;
              if (probe_q.opcode == coherence_pkg::CheckSC) begin
                reply_q.opcode <= coherence_pkg::CheckAck;
                reply_q.sc_valid <= atomic_q && atomic_sc_q && request_live &&
                    probe_q.check_q == acquisition_q.q &&
                    probe_q.addr == acquisition_q.addr && i_reservation_valid &&
                    i_reservation_addr == atomic_addr_q && i_reservation_size == atomic_size_q;
                sc_checked_q <= 1'b1;
                sc_tid_q <= probe_q.tid;
                phase_q <= ProbeReply;
              end else phase_q <= Lookup;
            end else if (probe_priority || probe_valid_q) begin
              // Probe ownership excludes local selection through R acceptance.
            end else if (grant_read_hold) begin
              // The credited turn leaves the circular pointer in place, so a
              // read that misses and cannot acquire keeps its next turn.
              if (grant_read_yield) begin
                maint_turn_q <= 1'b1;
                operation_q <= ReadOp;
                phase_q <= Lookup;
              end
            end else if (grant_valid && grant_ready) begin
              operation_q <= GrantOp;
              // A failed read completes from fail_clear_q a cycle later.
              if (grant_failure) begin
                if (grant_is_store) begin
                  o_fatal <= 1'b1;
                  o_fatal_addr <= grant.addr;
                end
              end else phase_q <= Lookup;
            end else if (i_sc_valid && o_sc_ready) begin
              operation_q <= SCOp;
              phase_q <= Lookup;
            end else if (atomic_write_q) begin
              operation_q <= AtomicWriteOp;
              phase_q <= Lookup;
            end else if (atomic_sc_selected) begin
              operation_q <= SCOp;
              acq_ep_q <= '0;
              phase_q <= sc_home_q ? Acquire : Lookup;
            end else if (store_head_ready) begin
              operation_q <= StoreOp;
              store_selected_q <= store_head_index;
              phase_q <= Lookup;
            end else if (look_ready) begin
              operation_q <= LookaheadOp;
              store_selected_q <= look_index_q;
              acq_ep_q <= load_ep_index;
              phase_q <= Lookup;
            end else if (read_selected) begin
              maint_turn_q <= 1'b1;
              operation_q <= ReadOp;
              rd_rr_q <= rd_pick + 1'b1;
              phase_q <= Lookup;
            end else if (maint_eligible) begin
              maint_turn_q <= 1'b0;
              if (maint_last_q) begin
                if (wb_live == 0) begin
                  maint_q <= 1'b0;
                  o_maint_done <= 1'b1;
                end
              end else begin
                operation_q <= MaintOp;
                phase_q <= Lookup;
              end
            end else if (hint_valid_q && hint_checked_q && hint_eligible_q &&
                prefetch_ep_free && !prefetch_cancel && !stream_replace && hint_in_window) begin
              operation_q <= PrefetchOp;
              phase_q <= Lookup;
            end
          end
          Lookup: begin
            if (grant_answer)
              rd_data_q[ld_read_q[grant_ep_q]] <=
                  grant_q.data[64*rd_addr_q[ld_read_q[grant_ep_q]][4:3]+:64];
            if (array_ready) phase_q <= LookupWait;
          end
          LookupWait:
          if (array_valid) begin
            way_q <= array_way;
            update_addr_q <= array_addr;
            image_q <= array_data;
            state_q <= array_state;
            update_mask_q <= operation_q == ProbeOp ? '0 : '1;
            case (operation_q)
              ProbeOp: begin
                reply_q.state <= array_hit && probe_q.opcode == coherence_pkg::ProbeRead ?
                    coherence_pkg::Shared : coherence_pkg::Invalid;
                reply_q.opcode <= ((array_hit && array_state ==
                    coherence_pkg::Modified) || probe_absorbed_q) ?
                    coherence_pkg::ProbeData : coherence_pkg::ProbeAck;
                reply_q.data_valid <= (array_hit && array_state ==
                    coherence_pkg::Modified) || probe_absorbed_q;
                reply_q.data <= probe_absorbed_q ? probe_put.data : array_data;
                reply_q.absorbed <= probe_absorbed_q;
                reply_q.put_id <= probe_put_q;
                reply_q.put_epoch <= probe_q.epoch;
                if (array_hit && !(array_state == coherence_pkg::Shared &&
                    probe_q.opcode == coherence_pkg::ProbeRead)) begin
                  state_q <= probe_q.opcode == coherence_pkg::ProbeInvalidate ?
                      coherence_pkg::Invalid : coherence_pkg::Shared;
                  phase_q <= Update;
                end else if (probe_absorbed_q) phase_q <= ProbeAbsorb;
                else if (probe_reply_eligible) begin
                  o_r_valid <= 1'b1;
                  phase_q <= Idle;
                end else phase_q <= ProbeReply;
              end
              GrantOp: begin
                if (array_available) begin
                  update_addr_q <= grant_q.addr;
                  image_q <= grant_q.data;
                  state_q <= grant_q.opcode == coherence_pkg::GrantM ?
                      coherence_pkg::Modified : coherence_pkg::Shared;
                  if (selected_grant_store) begin
                    for (int index = 0; index < 32; index++)
                    if (pending_mask_q[index]) image_q[8*index+:8] <= pending_data_q[8*index+:8];
                  end
                  if (!array_hit && array_state == coherence_pkg::Modified) begin
                    freeze_slot_q <= grant_ep_q == '0 ? reserved_wb_q : wb_free_slot;
                    freeze_addr_q <= array_addr;
                    freeze_data_q <= array_data;
                    freeze_maintenance_q <= 1'b0;
                    phase_q <= Freeze;
                  end else phase_q <= Update;
                end else phase_q <= Idle;
              end
              StoreOp: begin
                if (array_hit && array_state == coherence_pkg::Modified) begin
                  image_q <= pending_data_q;
                  update_mask_q <= pending_mask_q;
                  phase_q <= Update;
                end else begin
                  pending_miss_q <= 1'b1;
                  acq_ep_q <= '0;
                  phase_q <= !request_live && ep0_wb_ok && !store_same_line_q ? Acquire : Idle;
                end
              end
              LookaheadOp: begin
                phase_q <= (!array_hit || array_state != coherence_pkg::Modified) &&
                    acquire_ready && !same_line && !look_retry ? Acquire : Idle;
              end
              PrefetchOp: begin
                if (!array_hit && prefetch_ep_free && prefetch_accept) begin
                  acq_ep_q <= prefetch_ep_index;
                  phase_q <= Acquire;
                end else phase_q <= Idle;
              end
              AtomicWriteOp: begin
                if (!array_hit || array_state != coherence_pkg::Modified ||
                    (atomic_sc_q && (!i_reservation_valid || i_reservation_addr != atomic_addr_q ||
                     i_reservation_size != atomic_size_q))) begin
                  o_fatal <= 1'b1;
                  o_fatal_addr <= atomic_addr_q;
                end else begin
                  for (int index = 0; index < 32; index++)
                  if (atomic_mask_q[index]) image_q[8*index+:8] <= atomic_data_q[8*index+:8];
                  phase_q <= Update;
                end
              end
              MaintOp: begin
                if (array_state == coherence_pkg::Modified && (!maint_line_q || array_hit)) begin
                  freeze_slot_q <= wb_free_slot;
                  freeze_addr_q <= array_addr;
                  freeze_data_q <= array_data;
                  freeze_maintenance_q <= 1'b1;
                  state_q <= coherence_pkg::Shared;
                  phase_q <= Freeze;
                end else phase_q <= UpdateWait;
              end
              SCOp: phase_q <= LocalCheck;
              default: begin
                // A shadow lookup whose read the hit path holds answers
                // nothing and decides nothing from its kind: the hit path
                // answers, and the slot may hold a new read by now.
                if (shadow_q && path_hit_q) begin
                  phase_q <= Idle;
                end else if (selected_kind_q == ReadAMO) begin
                  phase_q <= LocalCheck;
                end else if (array_hit) begin
                  // A shadow lookup whose tags hit answers nothing either: a
                  // later lookup does.
                  if (!shadow_q)
                    rd_data_q[selected_read_q] <=
                        array_data[64*rd_addr_q[selected_read_q][4:3]+:64];
                  phase_q <= Idle;
                end else if (!Multi) begin
                  phase_q <= !request_live && wb_free ? Acquire : Idle;
                end else if (same_line) begin
                  // Wait for the endpoint already acquiring this line.
                  phase_q <= Idle;
                end else if (selected_kind_q == ReadLR) begin
                  acq_ep_q <= '0;
                  phase_q <= !request_live && ep0_wb_ok && !load_block ? Acquire : Idle;
                end else if (load_ep_free && !load_block && !load_acquire_block &&
                    !(look_available && !look_read_turn_q)) begin
                  acq_ep_q <= load_ep_index;
                  phase_q <= Acquire;
                end else phase_q <= Idle;
              end
            endcase
          end
          LocalCheck: begin
            if (local_decision) begin
              if (local_hit_q) begin
                atomic_q <= 1'b1;
                atomic_local_q <= 1'b1;
                atomic_granted_q <= operation_q != SCOp || local_sc_match;
                atomic_written_q <= 1'b0;
                atomic_way_q <= way_q;
                if (operation_q == SCOp) begin
                  o_sc_result_valid <= 1'b1;
                  o_sc_success <= local_sc_match;
                  o_sc_error <= 1'b0;
                  phase_q <= local_sc_match ? LocalWaitWrite : LocalFail;
                end else begin
                  atomic_sc_q <= 1'b0;
                  atomic_addr_q <= lookup_addr_q;
                  block_zero_addr_q <= lookup_addr_q;
                  atomic_size_q <= rd_size_q[selected_read_q];
                  atomic_tag_q <= rd_tag_q[selected_read_q];
                  atomic_read_q <= selected_read_q;
                  phase_q <= LocalReadReady;
                end
              end else if (operation_q == SCOp) begin
                sc_home_q <= 1'b1;
                phase_q <= Idle;
              end else begin
                acq_ep_q <= '0;
                atomic_q <= 1'b1;
                atomic_local_q <= 1'b0;
                atomic_sc_q <= 1'b0;
                atomic_granted_q <= 1'b0;
                atomic_written_q <= 1'b0;
                atomic_addr_q <= lookup_addr_q;
                block_zero_addr_q <= lookup_addr_q;
                atomic_size_q <= rd_size_q[selected_read_q];
                atomic_tag_q <= rd_tag_q[selected_read_q];
                phase_q <= Acquire;
              end
            end else phase_q <= Idle;
          end
          LocalReadReady: begin
            rd_data_q[atomic_read_q] <= image_q[64*atomic_addr_q[4:3]+:64];
            phase_q <= LocalWaitWrite;
          end
          LocalWaitWrite: if (atomic_write_q) phase_q <= LocalMerge;
          LocalMerge: begin
            if (atomic_sc_q && !local_sc_match) begin
              o_fatal <= 1'b1;
              o_fatal_addr <= atomic_addr_q;
            end else begin
              for (int index = 0; index < 32; index++)
              if (atomic_mask_q[index]) image_q[8*index+:8] <= atomic_data_q[8*index+:8];
              operation_q <= AtomicWriteOp;
              phase_q <= Update;
            end
          end
          LocalFail: if (o_sc_result_valid && i_sc_result_ready) phase_q <= LocalRelease;
          LocalRelease: begin
            block_zero_addr_q <= store_push && store_zero_alloc ?
                {i_address[ADDR_WIDTH-1:5], 5'b0} : store_addr[0];
            atomic_q <= 1'b0;
            atomic_local_q <= 1'b0;
            atomic_granted_q <= 1'b0;
            phase_q <= Idle;
          end
          Acquire:
          if ((acq_ep_q != '0 && load_acquire_block) ||
              (StreamEnabled && operation_q == PrefetchOp && !prefetch_acquire_ok)) phase_q <= Idle;
          else if (acquire_ready) begin
            if (acq_ep_q == '0) begin
            acquisition_q <= acquisition;
            acquisition_store_q <= operation_q == StoreOp;
            acquisition_sc_q <= atomic_q && atomic_sc_q;
            acquisition_read_q <= selected_read_q;
            reserved_wb_q <= wb_free_slot;
            wb_reserved_q <= 1'b1;
            done_q <= 1'b0;
            written_q <= 1'b0;
            done_status_q <= coherence_pkg::Consumed;
            end
            phase_q <= Idle;
          end
          Freeze: if (wb_freeze_ready[freeze_slot_q]) phase_q <= Update;
          // A probe's update changes only tag state, which every later
          // lookup sees, so its reply forms on the update edge itself.
          Update:
          if (update_ready) begin
            if (operation_q != ProbeOp) phase_q <= UpdateWait;
            else if (probe_absorbed_q) phase_q <= ProbeAbsorb;
            else if (probe_reply_eligible) begin
              o_r_valid <= 1'b1;
              phase_q <= Idle;
            end else phase_q <= ProbeReply;
          end
          UpdateWait:
          if (array_ready) begin
            case (operation_q)
              GrantOp: begin
                // A load endpoint's read was answered in Lookup; its slot may
                // hold a later read.
                if (selected_grant_store) begin
                  if (grant_ep_q == '0) begin
                    done_q <= 1'b1;
                    written_q <= 1'b1;
                  end
                end else if (grant_ep_q != '0) begin
                end else if (acquisition_sc_q) begin
                  atomic_granted_q <= 1'b1;
                  atomic_way_q <= way_q;
                  o_sc_result_valid <= 1'b1;
                  o_sc_success <= 1'b1;
                  o_sc_error <= 1'b0;
                end else begin
                  rd_data_q[acquisition_read_q] <=
                      grant_q.data[64*rd_addr_q[acquisition_read_q][4:3]+:64];
                  if (acquisition_q.opcode == coherence_pkg::Atomic) begin
                    atomic_granted_q <= 1'b1;
                    atomic_way_q <= way_q;
                  end else done_q <= 1'b1;
                end
                phase_q <= Idle;
              end
              StoreOp: begin
                phase_q <= store_continue ? Lookup : Idle;
                if (store_continue) store_selected_q <= store_next_index;
              end
              AtomicWriteOp: begin
                atomic_write_q <= 1'b0;
                atomic_written_q <= 1'b1;
                atomic_done_q <= 1'b1;
                o_sc_write_done <= atomic_sc_q;
                if (!atomic_local_q) begin
                  done_q <= 1'b1;
                  written_q <= 1'b1;
                end
                phase_q <= atomic_local_q ? LocalRelease : Idle;
              end
              MaintOp: begin
                if (maint_line_q) maint_last_q <= 1'b1;
                else if (maint_way_q == WayBits'(WAYS - 1)) begin
                  maint_way_q <= '0;
                  maint_set_q <= maint_set_q + 1'b1;
                  if (&maint_set_q) maint_last_q <= 1'b1;
                end else maint_way_q <= maint_way_q + 1'b1;
                phase_q <= Idle;
              end
              default: phase_q <= Idle;
            endcase
          end
          ProbeAbsorb:
          if (absorb_go) begin
            if (probe_reply_eligible) begin
              o_r_valid <= 1'b1;
              phase_q <= Idle;
            end else phase_q <= ProbeReply;
          end
          ProbeReply: begin
            if (probe_reply_eligible) begin
              o_r_valid <= 1'b1;
              phase_q   <= Idle;
            end
          end
          default: phase_q <= Idle;
        endcase
      end
    end
  end
`ifndef SYNTHESIS
  logic [7:0] reference_ready_next, reference_error_next, reference_valid_next, reference_miss_next;
  always_ff @(posedge i_clk) if (sim_reset_seen_q && !i_rst) begin
    p_grant_live : assert (!grant_valid || live[grant_pick]);
    p_grant_sc_exclusive : assert (!(grant_valid && o_sc_ready));
  end
  always_comb begin
    reference_valid_next = rd_valid_q;
    reference_miss_next  = rd_miss_q;
    reference_ready_next = rd_ready_q;
    reference_error_next = rd_error_q;
    if ((!o_read_valid || i_read_ready) && rd_response) begin
      reference_ready_next[rd_result] = 1'b0;
      reference_valid_next[rd_result] = 1'b0;
    end
    if (i_read_valid) begin
      reference_valid_next[i_read_id] = 1'b1;
      reference_miss_next[i_read_id]  = 1'b0;
      reference_ready_next[i_read_id] = 1'b0;
      reference_error_next[i_read_id] = 1'b0;
    end
    if (fail_clear_q) begin
      reference_ready_next[fail_clear_slot_q] = 1'b1;
      reference_error_next[fail_clear_slot_q] = fail_error_q;
    end
    if (s4_valid_q) reference_ready_next[s4_slot_q] = 1'b1;
    if (active) begin
      case (phase_q)
        LookupWait:
        if (array_valid) begin
          case (operation_q)
            ProbeOp, GrantOp, StoreOp, AtomicWriteOp, MaintOp, SCOp, LookaheadOp, PrefetchOp: begin
            end
            default: begin
              if (shadow_skip) begin
              end else if (rd_kind_q[selected_read_q] != ReadAMO && array_hit)
                reference_ready_next[selected_read_q] = 1'b1;
              else if (!(Multi && rd_kind_q[selected_read_q] != ReadAMO && same_line))
                reference_miss_next[selected_read_q] = 1'b1;
            end
          endcase
        end
        LocalReadReady: reference_ready_next[atomic_read_q] = 1'b1;
        Lookup:
        if (operation_q == GrantOp && grant_ep_q != '0 && !selected_grant_store &&
            !ld_prefetch_q[grant_ep_q] && !grant_answered_q)
          reference_ready_next[ld_read_q[grant_ep_q]] = 1'b1;
        UpdateWait:
        if (array_ready && operation_q == GrantOp && grant_ep_q == '0 &&
            !selected_grant_store && !acquisition_sc_q)
          reference_ready_next[acquisition_read_q] = 1'b1;
        default: begin
        end
      endcase
    end
    if (sim_reset_seen_q && !i_rst) p_read_status_exact :
    assert ({rd_valid_next, rd_miss_next, rd_ready_next, rd_error_next} ==
        {reference_valid_next, reference_miss_next, reference_ready_next, reference_error_next});
  end
  logic f_path_slots_ok, f_path_other;
  always_comb begin
    f_path_slots_ok = 1'b1;
    if (s2_valid_q && !(rd_valid_q[s2_slot_q] && !rd_ready_q[s2_slot_q] &&
        rd_kind_q[s2_slot_q] == ReadLoad)) f_path_slots_ok = 1'b0;
    if (s3_valid_q && !(rd_valid_q[s3_slot_q] && !rd_ready_q[s3_slot_q] &&
        rd_kind_q[s3_slot_q] == ReadLoad)) f_path_slots_ok = 1'b0;
    if (s4_valid_q && !(rd_valid_q[s4_slot_q] && !rd_ready_q[s4_slot_q] &&
        rd_kind_q[s4_slot_q] == ReadLoad)) f_path_slots_ok = 1'b0;
    if (s2_valid_q && s3_valid_q && s2_slot_q == s3_slot_q) f_path_slots_ok = 1'b0;
    if (s2_valid_q && s4_valid_q && s2_slot_q == s4_slot_q) f_path_slots_ok = 1'b0;
    if (s3_valid_q && s4_valid_q && s3_slot_q == s4_slot_q) f_path_slots_ok = 1'b0;
    f_path_other = (read_hit &&
        (phase_q == LocalReadReady ? atomic_read_q : selected_read_q) == s4_slot_q) ||
        (read_miss && selected_read_q == s4_slot_q) ||
        (read_fill && fill_read_slot == s4_slot_q) ||
        (fail_clear_q && fail_clear_slot_q == s4_slot_q);
  end
  always_ff @(posedge i_clk) begin
    if (sim_reset_seen_q && !i_rst) begin
      p_store_endpoint_limit : assert ($countones(live & ep_store) <= 2);
      p_borrowed_store_limit : assert ($countones(live[EpSlots-1:1] & ep_store[EpSlots-1:1]) <= 1);
      if (store_pop || (active && phase_q == Update &&
          (operation_q == StoreOp || (operation_q == GrantOp && selected_grant_store)))) begin
        p_store_head_valid : assert (store_valid[store_head_index] &&
            store_sealed[store_head_index]);
        p_store_probe_exclusion : assert (!probe_valid_q);
        p_store_install_address : assert (update_addr_q == pending_addr_q);
      end
      if (grant_ready && grant_valid && grant_is_store)
        p_store_grant_head : assert (store_acquired[store_head_index] &&
            store_ep[store_head_index] == grant_pick && grant.addr == pending_addr_q);
`ifndef STREAM_UNBOUNDED_PROOF
      for (int slot = 0; slot < 4; slot++)
      if (store_valid[slot] && store_acquired[slot]) begin
        assert (live[store_ep[slot]] && ep_store[store_ep[slot]]);
        assert (store_addr[slot][ADDR_WIDTH-1:5] ==
            (store_ep[slot] == '0 ? acquisition_q.addr[ADDR_WIDTH-1:5] :
             ld_line_q[store_ep[slot]]));
      end
`endif
      if (store_acquire) begin
        p_store_acquire_once : assert (!store_acquired[store_selected_q]);
`ifndef STREAM_UNBOUNDED_PROOF
        for (int ep = 0; ep < MISSES; ep++)
        if (live[ep]) assert (lookup_addr_q[ADDR_WIDTH-1:5] !=
            (ep == 0 ? acquisition_q.addr[ADDR_WIDTH-1:5] : ld_line_q[ep]));
        for (int age = 0; age < 4; age++)
        if (2'(store_head_index+2'(age)) == store_selected_q)
          for (int older = 0; older < age; older++) begin
            assert (lookup_addr_q[ADDR_WIDTH-1:5] !=
                store_addr[2'(store_head_index+2'(older))][ADDR_WIDTH-1:5]);
            assert (lookup_addr_q[ADDR_WIDTH-1:HomeOffset] ==
                store_addr[2'(store_head_index+2'(older))][ADDR_WIDTH-1:HomeOffset] ||
                (HomeSets > 1 && lookup_addr_q[HomeOffset+:HomeSetBits] !=
                 store_addr[2'(store_head_index+2'(older))][HomeOffset+:HomeSetBits]));
          end
`endif
      end
    end
  end
  logic store_launch_ready_q;
  logic [1:0] waiting_store_selections_q;
  wire completed_store_selection = active &&
      ((phase_q == LookupWait && array_valid &&
        (operation_q == StoreOp || operation_q == LookaheadOp)) ||
       (store_pop && operation_q == GrantOp));
  wire completed_read_selection = active &&
      ((phase_q == LookupWait && array_valid && operation_q == ReadOp) ||
       (phase_q == UpdateWait && array_ready && operation_q == GrantOp &&
        !selected_grant_store));
  always_ff @(posedge i_clk) begin
    if (i_rst || !read_service_waiting || completed_read_selection)
      waiting_store_selections_q <= '0;
    else if (completed_store_selection)
      waiting_store_selections_q <= waiting_store_selections_q + 2'd1;
    if (sim_reset_seen_q && !i_rst)
      p_store_read_service_bound : assert (waiting_store_selections_q <= 2);
  end
  logic insert_lookup_valid_q;
  logic read_owed_q;
  logic [SetBits-1:0] insert_lookup_set_q;
  logic [WayBits-1:0] insert_lookup_way_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      store_launch_ready_q <= 1'b0;
      read_owed_q <= 1'b0;
      insert_lookup_valid_q <= 1'b0;
      insert_lookup_set_q <= '0;
      insert_lookup_way_q <= '0;
    end else begin
      store_launch_ready_q <= o_store_ready;
      // Read lookups and completed read grants discharge the service debt.
      if (!rd_candidate || (phase_q == Lookup && operation_q == ReadOp) ||
          read_fill) read_owed_q <= 1'b0;
      if (store_pop && operation_q == StoreOp && read_waiting_q && rd_candidate)
        read_owed_q <= 1'b1;
      if (active && phase_q == LookupWait && array_valid) begin
        insert_lookup_valid_q <= 1'b1;
        insert_lookup_set_q <= array_addr[5+:SetBits];
        insert_lookup_way_q <= array_way;
      end
      if (active && phase_q == Update && update_ready && operation_q == GrantOp)
        insert_lookup_valid_q <= 1'b0;
    end
  end
  logic [ADDR_WIDTH-1:0] reference_atomic_addr_q;
  logic [2:0] reference_atomic_size_q, reference_atomic_read_q;
  logic [TAG_BITS-1:0] reference_atomic_tag_q;
  always_ff @(posedge i_clk) begin
    if (i_sc_valid && o_sc_ready) begin
      reference_atomic_addr_q <= i_sc_address;
      reference_atomic_size_q <= i_sc_size;
      reference_atomic_tag_q <= i_sc_tag;
    end
    if (local_decision && operation_q == ReadOp) begin
      reference_atomic_addr_q <= lookup_addr_q;
      reference_atomic_size_q <= rd_size_q[selected_read_q];
      reference_atomic_tag_q <= rd_tag_q[selected_read_q];
      reference_atomic_read_q <= selected_read_q;
    end
    if (sim_reset_seen_q && !i_rst) begin
      // The CPU presents one selected atomic until its ownership ends.
      if (local_decision && operation_q == ReadOp)
        p_atomic_single_owner : assert (!atomic_q);
      if (atomic_q) begin
        p_atomic_context_identity : assert ({atomic_addr_q, atomic_size_q, atomic_tag_q} ==
            {reference_atomic_addr_q, reference_atomic_size_q, reference_atomic_tag_q});
        if (atomic_local_q && !atomic_sc_q)
          p_atomic_read_identity : assert (atomic_read_q == reference_atomic_read_q);
      end
      if (read_owed_q && rd_candidate && active && phase_q == Lookup)
        p_store_yields_read : assert (operation_q != StoreOp);
      if (store_pop && operation_q == StoreOp && read_waiting_q)
        p_store_yield_stops_continuation : assert (!store_continue);
      if (active && phase_q == Update && update_ready && operation_q == GrantOp) begin
        p_insert_lookup_valid : assert (insert_lookup_valid_q);
        p_insert_lookup_set : assert (update_addr_q[5+:SetBits] == insert_lookup_set_q);
        p_insert_lookup_way : assert (way_q == insert_lookup_way_q);
      end
      if (i_read_valid) assert (!rd_valid_q[i_read_id]);
      if (array_skip_data) assert (!probe_launch &&
          (operation_q == StoreOp || operation_q == LookaheadOp));
      if (active && phase_q == LookupWait && array_valid && operation_q == ProbeOp &&
          array_hit && array_state == coherence_pkg::Modified) assert (array_data_valid);
      if (active && phase_q == LookupWait && array_valid && operation_q == GrantOp &&
          !array_hit && array_state == coherence_pkg::Modified)
        p_grant_victim_data : assert (array_data_valid);
      // A shadow lookup whose read the hit path holds decides nothing from the
      // kind, and the hit path may have answered and freed the slot by then.
      if (active && phase_q == LookupWait && operation_q == ReadOp && !(shadow_q && path_hit_q))
        p_selected_kind : assert (selected_kind_q == rd_kind_q[selected_read_q]);
      // A shadow lookup reads tags only; every other read hit has its data.
      if (active && phase_q == LookupWait && array_valid && operation_q == ReadOp && array_hit &&
          !shadow_q)
        p_read_hit_data : assert (array_data_valid);
      if (active && phase_q == LookupWait && array_valid && operation_q == ReadOp && shadow_q)
        p_shadow_tags_only : assert (!array_data_valid);
      if (active && phase_q == LookupWait && array_valid && !array_data_valid) begin
        p_skipped_array_data_unused : assert (
            ((operation_q == StoreOp || operation_q == LookaheadOp) && array_hit) ||
            (operation_q == ReadOp && (!array_hit || shadow_q)) ||
            (operation_q == GrantOp && (array_hit || array_state != coherence_pkg::Modified)) ||
            (operation_q == ProbeOp && (!array_hit || array_state != coherence_pkg::Modified)));
      end
      // The hit path holds valid, unanswered load slots, one per stage. Its
      // answer is the slot's only completion, and a lookup of a slot whose
      // hit it holds is a shadow, which agrees with it.
      p_bounded_path_slots : assert (f_path_slots_ok);
      if (s4_valid_q)
        p_bounded_path_answer_once : assert (!rd_ready_q[s4_slot_q] && !f_path_other);
      if (active && operation_q == ReadOp && (phase_q == Lookup || phase_q == LookupWait) &&
          path_owned[selected_read_q])
        p_path_shadowed : assert (first_lookup ? shadow_now : shadow_q);
      if (active && phase_q == LookupWait && array_valid && operation_q == ReadOp && shadow_q)
        p_bounded_shadow_agreement : assert (array_hit == path_hit_q);
      if (store_pop) p_bounded_store_pop_pending : assert (pending_q && !probe_valid_q);
      if (tail_q) assert (pending_q);
      p_bounded_pending_atomic : assert (!(pending_q && atomic_q));
      if ((i_sc_valid && o_sc_ready) || phase_q == LocalCheck)
        p_atomic_store_exclusive : assert (!store_push);
      if (atomic_q && atomic_local_q) begin
        p_bounded_local_atomic_idle : assert (!request_live && !pending_q && !store_push);
        assert (!probe_valid_q && !o_p_ready && !o_cut_hold);
        assert (!grant_ready && !ep_request_valid[0]);
        assert (phase_q != Idle && phase_q != Lookup && phase_q != LookupWait);
        assert (i_atomic_protected);
        if (atomic_granted_q && !atomic_written_q && atomic_sc_q) assert (local_sc_match);
      end
      if (|i_write_mask) begin
        if (i_write_atomic) begin
          assert (atomic_q && atomic_granted_q && !atomic_written_q && !atomic_write_q);
          assert (i_address == atomic_addr_q && i_write_sc == atomic_sc_q);
          assert (i_write_tag == atomic_tag_q);
          if (i_write_sc) assert (sc_committed_q);
        end else begin
          p_bounded_store_launch : assert (active && store_count < 4 && !atomic_q);
          assert (o_store_ready || store_launch_ready_q);
        end
      end
      if (o_d_valid[0] && (acquisition_q.opcode == coherence_pkg::Atomic ||
          acquisition_q.opcode == coherence_pkg::StoreConditional))
        assert (i_atomic_protected);
      if (ep_request_valid[0]) p_bounded_wb_free_request : assert (wb_free);
      if (grant_valid && grant_ready) p_bounded_grant_pick_live : assert (live[grant_pick]);
      if (i_p_valid && o_p_ready && probe_in.opcode == coherence_pkg::ProbeRead &&
          atomic_q && !atomic_local_q && atomic_sc_q && sc_checked_q &&
          probe_in.addr == acquisition_q.addr)
        assert (probe_in.tid == sc_tid_q);
      if (o_c_valid[0] && acquisition_q.opcode == coherence_pkg::StoreConditional && written_q)
        assert (atomic_written_q);
    end
  end
`endif
`ifdef FORMAL
`ifdef STORE_DATA_PROOF
  initial assert ($bits(ep_grant) == EpSlots * (ADDR_WIDTH + 275));
  (* anyconst *) logic [ADDR_WIDTH-6:0] f_sector;
`ifdef STORE_BYTE_WORD
  (* anyconst *) logic [2:0] f_byte_lane;
  wire [4:0] f_byte = {2'(`STORE_BYTE_WORD), f_byte_lane};
`else
  (* anyconst *) logic [4:0] f_byte;
`endif
  logic f_byte_known_q;
  logic [7:0] f_byte_q;
  logic [ADDR_WIDTH-1:0] f_acquired_store_q;
  // Hit-path reads of the watched dword, through the stages.
  logic f_path2_q, f_path3_q, f_path4_q, f_path4_any_q, f_path4_known_q;
  logic f_path2_known_q, f_path3_known_q;
  logic [7:0] f_path2_byte_q, f_path3_byte_q, f_path4_byte_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      f_path2_q <= 1'b0;
      f_path3_q <= 1'b0;
      f_path4_q <= 1'b0;
      f_path4_any_q <= 1'b0;
    end else begin
      f_path2_q <= path_take && path_addr_q[ADDR_WIDTH-1:5] == f_sector &&
          path_addr_q[4:3] == f_byte[4:3];
      f_path3_q <= f_path2_q;
      f_path4_any_q <= f_path3_q && path_hit;
      f_path4_q <= f_path3_q && path_hit && f_path3_known_q;
    end
    f_path2_known_q <= f_byte_known_q;
    f_path2_byte_q <= f_byte_q;
    f_path3_known_q <= f_path2_known_q;
    f_path3_byte_q <= f_path2_byte_q;
    f_path4_known_q <= f_path3_known_q;
    f_path4_byte_q <= f_path3_byte_q;
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      f_byte_known_q <= 1'b0;
      f_byte_q <= '0;
      f_acquired_store_q <= '0;
    end else begin
      if (active && phase_q == Acquire && operation_q == StoreOp && ep_request_ready[0])
        f_acquired_store_q <= pending_addr_q;
      if (request_live && acquisition_store_q && !written_q)
        p_store_data_1 : assert (pending_addr_q == f_acquired_store_q);
      if (active && phase_q == Update && update_ready) begin
        if (operation_q == StoreOp) begin
          p_store_data_2 : assert (pending_q && !probe_valid_q);
          p_store_data_3 : assert (update_addr_q[ADDR_WIDTH-1:5] == pending_addr_q[ADDR_WIDTH-1:5]);
          p_store_data_4 : assert (update_mask_q == pending_mask_q);
          if (pending_mask_q[f_byte])
            p_store_data_5 : assert (image_q[8*f_byte+:8] == pending_data_q[8*f_byte+:8]);
        end
        if (operation_q == GrantOp && selected_grant_store) begin
          p_store_data_8 : assert (pending_q && update_mask_q == '1);
          p_store_data_9 : assert (update_addr_q[ADDR_WIDTH-1:5] == pending_addr_q[ADDR_WIDTH-1:5]);
          p_store_data_10 : assert (image_q[8*f_byte+:8] ==
              (pending_mask_q[f_byte] ? pending_data_q[8*f_byte+:8] : grant_q.data[8*f_byte+:8]));
        end
        if (update_addr_q[ADDR_WIDTH-1:5] == f_sector && update_mask_q[f_byte]) begin
          f_byte_known_q <= 1'b1;
          f_byte_q <= image_q[8*f_byte+:8];
        end
      end
      if (f_byte_known_q && array_valid && array_data_valid && array_hit &&
          array_addr[ADDR_WIDTH-1:5] == f_sector)
        p_store_data_6 : assert (array_data[8*f_byte+:8] == f_byte_q);
      if (f_byte_known_q && o_r_valid && reply_q.data_valid &&
          reply_q.addr[ADDR_WIDTH-1:5] == f_sector)
        p_store_data_7 : assert (reply_q.data[8*f_byte+:8] == f_byte_q);
      // A hit-path answer for the sector holds the byte as of its stage-1
      // edge, which writes nothing to its set; the line was installed by then.
      if (f_path4_q) p_store_data_path : assert (path_data[8*f_byte[2:0]+:8] == f_path4_byte_q);
      if (f_path4_any_q) p_store_data_path_known : assert (f_path4_known_q);
      cover (tail_q && probe_capture && probe_in.addr[ADDR_WIDTH-1:5] == tail_addr[ADDR_WIDTH-1:5]);
      cover (tail_q && o_fatal && o_fatal_addr == acquisition_q.addr);
    end
  end
`endif
`ifdef LOCAL_ATOMIC_PROOF
  // A failed read completes a cycle after its grant. A lookup keeps its read
  // valid and unready only if that slot stays out of selection until then, so
  // the slot stays owned. The owner tasks assume this; the owned tasks prove it.
  always_ff @(posedge i_clk)
    if (!i_rst && fail_clear_q) p_local_failed_owned : assert (rd_owned_q[fail_clear_slot_q]);
  // The owner tasks also assume these facts about the atomic in service, and
  // the owned tasks prove them. An atomic's write data is pending only for a
  // granted atomic that has not written.
  always_ff @(posedge i_clk)
    if (!i_rst && atomic_write_q)
      p_local_write_pending : assert (atomic_q && atomic_granted_q && !atomic_written_q);
  // An atomic write's update runs while its data waits.
  always_ff @(posedge i_clk)
    if (!i_rst && operation_q == AtomicWriteOp &&
        (phase_q == Lookup || phase_q == LookupWait || phase_q == Freeze ||
         phase_q == Update || phase_q == UpdateWait))
      p_local_write_op : assert (atomic_write_q);
  // A remote AMO's acquisition starts with the AMO in service.
  always_ff @(posedge i_clk)
    if (!i_rst && active && operation_q == ReadOp && phase_q == Acquire &&
        rd_kind_q[selected_read_q] == ReadAMO)
      p_local_amo_acquire : assert (atomic_q && !atomic_sc_q && !atomic_local_q && !live[0]);
  // Endpoint 0's AMO acquisition belongs to the remote AMO in service.
  always_ff @(posedge i_clk)
    if (!i_rst && live[0] && acquisition_q.opcode == coherence_pkg::Atomic)
      p_local_acquired_amo : assert (atomic_q && !atomic_sc_q && !atomic_local_q);
  // The local phases serve a local atomic.
  always_ff @(posedge i_clk)
    if (!i_rst && (phase_q == LocalReadReady || phase_q == LocalWaitWrite ||
                   phase_q == LocalMerge || phase_q == LocalRelease || phase_q == LocalFail))
      p_local_phase : assert (atomic_q && atomic_local_q);
  // A grant belongs to the atomic in service.
  always_ff @(posedge i_clk)
    if (!i_rst && atomic_granted_q) p_local_granted : assert (atomic_q);
  // Endpoint 0's SC acquisition belongs to the remote SC in service.
  always_ff @(posedge i_clk)
    if (!i_rst && live[0] && acquisition_sc_q)
      p_local_acquired_sc : assert (atomic_q && atomic_sc_q && !atomic_local_q);
`endif
  // The local owned tasks and the stream ownership task read these lemmas.
`ifdef READ_OWNER_PROOF
  // f_owner[ep] marks an endpoint that owns a read's slot, endpoint 0 through
  // U and the others until the read installs or fails, and f_owner_slot[ep]
  // names that slot. An owner's slot flag is set and owners hold distinct
  // slots, so one owner's clear leaves the others'.
  logic [MISSES-1:0] f_owner;
  logic [2:0] f_owner_slot[MISSES];
  logic f_owner_phase, f_owner_flag, f_owner_distinct, f_owner_fail, f_owner_pending;
  logic f_owner_free;
  always_comb begin
    for (int ep = 0; ep < MISSES; ep++) begin
      f_owner_slot[ep] = ep == 0 ? acquisition_read_q : ld_read_q[ep];
      f_owner[ep] = live[ep] && !ep_store[ep] &&
          (ep == 0 ? !acquisition_sc_q : !ld_prefetch_q[ep] && !installed_q[ep]);
    end
    f_owner_phase = 1'b1;
    f_owner_flag = 1'b1;
    f_owner_distinct = 1'b1;
    f_owner_fail = 1'b1;
    f_owner_pending = 1'b1;
    f_owner_free = 1'b0;
    for (int ep = 0; ep < MISSES; ep++) begin
      if (ep != 0 && !live[ep]) f_owner_free = 1'b1;
      if (!$onehot(f_ep_phase[ep])) f_owner_phase = 1'b0;
      if (f_owner[ep] && !rd_owned_q[f_owner_slot[ep]]) f_owner_flag = 1'b0;
      for (int other = ep + 1; other < MISSES; other++)
      if (f_owner[ep] && f_owner[other] && f_owner_slot[ep] == f_owner_slot[other])
        f_owner_distinct = 1'b0;
      if (fail_owner_q && f_owner[ep] && f_owner_slot[ep] == fail_clear_slot_q)
        f_owner_fail = 1'b0;
      // Phase bits 1 to 3 are SendD, WaitG and Grant: a grant is still to
      // come. An endpoint is done only after it installs or fails.
      if (ep != 0 && |f_ep_phase[ep][3:1] && installed_q[ep]) f_owner_pending = 1'b0;
      if (ep != 0 && ld_done_q[ep] && !installed_q[ep]) f_owner_pending = 1'b0;
    end
  end
  always_ff @(posedge i_clk)
    if (!i_rst) begin
      p_owned_phase : assert (f_owner_phase);
      p_owned_flag : assert (f_owner_flag);
      p_owned_distinct : assert (f_owner_distinct);
      p_owned_fail : assert (f_owner_fail);
      p_owned_pending : assert (f_owner_pending);
      p_owned_operation : assert (operation_q <= LookaheadOp &&
          (StreamEnabled || operation_q != PrefetchOp));
      p_owned_free : assert (!load_ep_free || f_owner_free);
      if (operation_q == LookaheadOp &&
          (phase_q == Lookup || phase_q == LookupWait || phase_q == Acquire))
        p_owned_lookahead : assert (acq_ep_q != '0);
      // An acquisition for anything but a read marks its endpoint as a store
      // or a prefetch, or is the SC on endpoint 0.
      if (active && phase_q == Acquire) begin
        p_owned_acquire : assert (operation_q == ReadOp ||
            (operation_q == StoreOp && acq_ep_q == '0) ||
            (operation_q == LookaheadOp && acq_ep_q != '0) ||
            (operation_q == SCOp && atomic_q && atomic_sc_q && acq_ep_q == '0 && !request_live) ||
            (operation_q == PrefetchOp && StreamEnabled && acq_ep_q != '0));
      end
      // Phase bit 4 is Done: an installing grant's endpoint waits there.
      if (operation_q == GrantOp && grant_ep_q != '0 &&
          (phase_q == Lookup || phase_q == LookupWait || phase_q == Freeze ||
           phase_q == Update || phase_q == UpdateWait))
        p_owned_install : assert (int'(grant_ep_q) < MISSES && f_ep_phase[grant_ep_q][4] &&
            !installed_q[grant_ep_q]);
`ifdef LOCAL_ATOMIC_PROOF
      // A remote atomic's grant leaves endpoint 0 in its Done phase until the
      // write completes, and endpoint 0 waits there while its grant installs.
      if (atomic_granted_q && !atomic_local_q && !atomic_written_q)
        p_owned_atomic_done : assert (f_ep_phase[0][4] && !done_q);
      if (atomic_granted_q && !atomic_local_q)
        p_owned_atomic_granted : assert (|f_ep_phase[0][6:4]);
      if (operation_q == GrantOp && grant_ep_q == '0 &&
          (phase_q == Lookup || phase_q == LookupWait || phase_q == Freeze ||
           phase_q == Update || phase_q == UpdateWait))
        p_owned_install0 : assert (f_ep_phase[0][4] && !done_q && !atomic_granted_q);
      // An acquisition clears endpoint 0's done flag, so its request phases
      // find it clear.
      if (|f_ep_phase[0][3:1]) p_owned_done0 : assert (!done_q);
      // A read under lookup or acquisition stays valid and unready.
      if (active && operation_q == ReadOp && (phase_q == Lookup || phase_q == LookupWait ||
                                              phase_q == LocalCheck || phase_q == Acquire))
        p_owned_read_live : assert (rd_valid_q[selected_read_q] &&
            !rd_ready_q[selected_read_q]);
`endif
      // A read under lookup has no owner, so a new owner's slot is free.
      if (operation_q == ReadOp && (phase_q == Lookup || phase_q == LookupWait ||
                                    phase_q == LocalCheck || phase_q == Acquire))
        p_owned_selected : assert (!rd_owned_q[selected_read_q]);
`ifdef STREAM_UNBOUNDED_PROOF
      // The stream tasks have no local atomic proof, so they state its failed
      // read ownership here. A read lookup's read also stays valid and unready,
      // so its slot is not reallocated before LookupWait ends. The hit path may
      // answer a shadow lookup's read once it hits, and holds the hit from
      // stage 4 on.
      if (fail_clear_q) p_owned_failed_read : assert (rd_owned_q[fail_clear_slot_q]);
      if (active && operation_q == ReadOp && (phase_q == Lookup || phase_q == LookupWait) &&
          !(first_lookup ? shadow_now : shadow_q))
        p_owned_lookup_read : assert (rd_valid_q[selected_read_q] &&
            !rd_ready_q[selected_read_q]);
      if (active && operation_q == ReadOp && (phase_q == Lookup || phase_q == LookupWait) &&
          shadow_q && !path_hit_q)
        p_owned_shadow_read : assert (rd_valid_q[selected_read_q] &&
            !rd_ready_q[selected_read_q]);
      if (active && operation_q == ReadOp && (phase_q == Lookup || phase_q == LookupWait) &&
          shadow_q && s4_valid_q && s4_slot_q == selected_read_q)
        p_owned_shadow_hit : assert (path_hit_q);
`endif
    end
`endif
`ifdef LOCAL_ATOMIC_PROOF
  (* anyconst *) logic [4:0] f_local_byte;
  logic [7:0] f_local_saved_q;
  logic [ADDR_WIDTH-6:0] f_local_sector_q;
  logic f_local_seen_q = 0, f_local_written_q = 0;
  logic f_local_sector_clear, f_local_lookup_clear;
  always_comb begin
    f_local_sector_clear = 1'b1;
    f_local_lookup_clear = 1'b1;
    for (int ep = 1; ep < MISSES; ep++) begin
      f_local_sector_clear &= !live[ep] || ld_line_q[ep] != atomic_addr_q[ADDR_WIDTH-1:5];
      f_local_lookup_clear &= !live[ep] || ld_line_q[ep] != lookup_addr_q[ADDR_WIDTH-1:5];
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      f_local_seen_q <= 0;
      f_local_written_q <= 0;
      f_local_saved_q <= 0;
      f_local_sector_q <= 0;
    end else begin
      if (operation_q == SCOp &&
          (phase_q == Lookup || phase_q == LookupWait || phase_q == LocalCheck))
        p_local_sc_lookup: assert (lookup_addr_q == atomic_addr_q);
      if ((phase_q == LookupWait || phase_q == LocalCheck) &&
          (operation_q == SCOp || (operation_q == ReadOp &&
           rd_kind_q[selected_read_q] == ReadAMO))) begin
        p_local_lookup_stable: assert (lookup_addr_q == $past(lookup_addr_q));
        p_local_conflict_sample: assert (same_line || f_local_lookup_clear);
      end
      if (phase_q == LocalCheck && !local_conflict_q)
        p_local_admit_sector: assert (f_local_lookup_clear);
      if (local_decision && local_hit_q) begin
        f_local_seen_q <= 1;
        f_local_written_q <= 0;
        f_local_saved_q <= image_q[8*f_local_byte+:8];
        f_local_sector_q <= lookup_addr_q[ADDR_WIDTH-1:5];
      end
      if (atomic_local_q && phase_q == LocalMerge && active) begin
        if (atomic_mask_q[f_local_byte]) f_local_saved_q <= atomic_data_q[8*f_local_byte+:8];
      end
      if (atomic_local_q && atomic_done_q) f_local_written_q <= 1;
      if (atomic_local_q) begin
        p_local_active: assert (atomic_q);
        p_local_lookup_owner: assert (lookup_addr_q == atomic_addr_q);
        p_local_image: assert (image_q[8*f_local_byte+:8] == f_local_saved_q);
        p_local_exclusion: assert (!request_live && !pending_q && !store_push &&
            !probe_valid_q && !o_p_ready && !o_cut_hold && !grant_ready && !ep_request_valid[0]);
        p_local_service: assert (phase_q == LocalReadReady || phase_q == LocalWaitWrite ||
            phase_q == LocalMerge || phase_q == LocalFail || phase_q == LocalRelease ||
            ((phase_q == Update || phase_q == UpdateWait) && operation_q == AtomicWriteOp));
        p_local_protected: assert (i_atomic_protected);
        p_local_permission: assert (state_q == coherence_pkg::Modified);
        p_local_sector: assert (f_local_sector_clear);
        if (phase_q == LocalRelease && atomic_granted_q)
          p_local_release: assert (atomic_written_q && (atomic_done_q || f_local_written_q));
        if (phase_q == LocalFail)
          p_local_failure: assert (!atomic_granted_q && !atomic_write_q && !o_sc_write_pending);
        if (phase_q == LocalReadReady)
          p_local_read: assert (rd_valid_q[atomic_read_q] && !rd_ready_q[atomic_read_q]);
      end
      if (f_local_seen_q && o_r_valid && reply_q.addr[ADDR_WIDTH-1:5] == f_local_sector_q
          && reply_q.data_valid && f_local_written_q)
        p_local_probe_data: assert (reply_q.data[8*f_local_byte+:8] == f_local_saved_q);
      // A subsequent update or replacement starts a separate observation.
      if (phase_q == Update && !atomic_local_q && operation_q != ProbeOp &&
          update_addr_q[ADDR_WIDTH-1:5] == f_local_sector_q) f_local_seen_q <= 0;
      p_local_probe_cover: cover (f_local_seen_q && f_local_written_q && o_r_valid);
      p_local_fail_cover: cover (atomic_local_q && phase_q == LocalFail && i_sc_result_ready);
      p_local_live_cover: cover (atomic_local_q && any_live && atomic_done_q);
      p_local_release_cover: cover (atomic_local_q && phase_q == LocalRelease && i_p_valid);
    end
  end
`endif
`ifdef LOCAL_ATOMIC_COVER
  (* anyconst *) logic f_local_sc;
  (* anyconst *) logic f_local_reservation;
  (* anyconst *) logic [7:0] f_local_initial, f_local_replacement;
  logic [7:0] f_local_cycle_q = 0;
  logic f_local_store_q = 0, f_local_start_q = 0, f_local_probe_q = 0;
  logic f_local_offer_q = 0;
  coh_g_t f_local_grant;
  coh_u_t f_local_u;
  coh_p_t f_local_p;
  always_comb begin
    f_local_grant = '0;
    f_local_grant.q = acquisition_q.q;
    f_local_grant.addr = acquisition_q.addr;
    f_local_grant.opcode = coherence_pkg::GrantM;
    f_local_grant.data = {32{f_local_initial}};
    f_local_u = '0;
    f_local_u.q = acquisition_q.q;
    f_local_u.addr = acquisition_q.addr;
    f_local_p = '0;
    f_local_p.addr = ADDR_WIDTH'(32'h80000000);
    f_local_p.opcode = coherence_pkg::ProbeInvalidate;
  end
  wire f_local_start = f_local_store_q && !pending_q && !request_live && !f_local_start_q;
  always_ff @(posedge i_clk) begin
    f_local_cycle_q <= f_local_cycle_q + 1'b1;
    assume (i_rst == !f_past_valid);
    assume (!i_fatal_stop && !i_maint_valid && !i_wa_valid);
    assume (i_address == ADDR_WIDTH'(32'h80000000));
    assume (i_read_valid == (f_local_start && !f_local_sc));
    assume (i_read_kind == ReadAMO && i_read_size == 3 && i_read_tag == 0 && i_read_id == 0);
    assume (i_sc_valid == (f_local_start && f_local_sc));
    assume (i_sc_address == ADDR_WIDTH'(32'h80000000) && i_sc_size == 3 && i_sc_tag == 0);
    assume (i_reservation_valid == f_local_reservation);
    assume (i_reservation_addr == ADDR_WIDTH'(32'h80000000) && i_reservation_size == 3);
    assume (i_atomic_protected);
    assume (i_sc_commit == (atomic_sc_q && atomic_granted_q));
    assume (i_write_atomic == f_local_start_q && i_write_sc == f_local_sc);
    assume (i_write_data == {8{f_local_replacement}} && i_write_tag == 0);
    assume (i_write_mask == ((f_local_cycle_q == 4 ||
        (atomic_local_q && atomic_granted_q && !atomic_written_q && !atomic_write_q &&
         (!f_local_sc || sc_committed_q))) ? 8'hff : 0));
    assume (i_d_ready == '1 && i_c_ready == '1 && i_read_ready && i_r_ready && i_w_ready);
    assume (i_sc_result_ready && i_cut_admit_ready && i_cut_admit_clean && i_cut_inval_done);
    assume (i_g_valid && i_g == f_local_grant && i_u_valid && i_u == f_local_u);
    assume (i_p_valid == (f_local_offer_q && !f_local_probe_q));
    if (atomic_local_q) f_local_offer_q <= 1;
    assume (i_p == f_local_p);
    if (probe_capture) f_local_probe_q <= 1;
    if (store_push) f_local_store_q <= 1;
    if (f_local_start) f_local_start_q <= 1;
  end
`endif
`ifdef STORE_COVER
  // Cover-only traffic schedules leave the safety environments unconstrained.
  (* anyconst *) logic [2:0] f_scenario;
  logic [7:0] f_cycle_q = 0;
  logic [3:0] f_stores_q = 0, f_installs_q = 0;
  logic f_probe_after_install_q = 0, f_reacquired_q = 0;
  logic f_store_offer_q = 0, f_probe_sent_q = 0, f_read_sent_q = 0;
  coh_g_t f_cover_grant;
  coh_u_t f_cover_release;
  coh_p_t f_cover_probe;
  always_comb begin
    f_cover_grant = '0;
    f_cover_grant.q = acquisition_q.q;
    f_cover_grant.addr = acquisition_q.addr;
    f_cover_grant.opcode = f_scenario == 5 && !acquisition_store_q ?
        coherence_pkg::GrantS : coherence_pkg::GrantM;
    f_cover_grant.error = f_scenario == 4;
    f_cover_release = '0;
    f_cover_release.q = acquisition_q.q;
    f_cover_release.addr = acquisition_q.addr;
    f_cover_probe = '0;
    f_cover_probe.addr = ADDR_WIDTH'(32'h80000000);
    f_cover_probe.opcode = f_scenario == 2 ? coherence_pkg::CheckSC :
        f_scenario == 1 ? coherence_pkg::ProbeInvalidate : coherence_pkg::ProbeRead;
    f_cover_probe.check_q = acquisition_q.q;
    f_cover_probe.size = 3'd3;
  end
  always_ff @(posedge i_clk) begin
    if (f_cycle_q != 255) f_cycle_q <= f_cycle_q + 1'b1;
    assume (f_scenario <= 5);
    assume (i_rst == !f_past_valid);
    assume (!i_fatal_stop && !i_maint_valid);
    assume (i_read_valid == (f_scenario == 5 && f_installs_q != 0 &&
        phase_q == Lookup && operation_q == StoreOp && !f_read_sent_q && !f_store_offer_q));
    assume (i_read_kind == ReadLoad && i_read_id == 0);
    if (i_read_valid) f_read_sent_q <= 1'b1;
    assume (i_address == ADDR_WIDTH'(i_read_valid ? 32'h80000020 : 32'h80000000));
    assume (i_write_data == 64'h123456789abcdef0 && i_write_tag == 0);
    assume (i_atomic_protected == (f_scenario == 2));
    assume (i_sc_valid == (f_scenario == 2 && f_cycle_q == 4));
    assume (i_sc_address == ADDR_WIDTH'(32'h80000000) && i_sc_size == 3 && i_sc_tag == 0);
    assume (i_reservation_valid && i_reservation_addr == ADDR_WIDTH'(32'h80000000) &&
        i_reservation_size == 3);
    assume (i_sc_commit == (atomic_q && atomic_granted_q));
    assume (i_write_atomic == (f_scenario == 2));
    assume (i_write_sc == (f_scenario == 2));
    assume (i_write_mask == (f_scenario == 2 ?
        (sc_committed_q && atomic_granted_q && !atomic_written_q && !atomic_write_q ? 8'hff : 0) :
        (f_store_offer_q ? 8'hff : 0)));
    f_store_offer_q <= f_scenario != 2 && o_store_ready &&
        (f_stores_q < 6 || (f_scenario == 5 && f_read_sent_q && f_stores_q < 8));
    if (store_push) f_stores_q <= f_stores_q + 1'b1;
    if (store_pop) f_installs_q <= f_installs_q + 1'b1;
    if (probe_capture && f_installs_q != 0) f_probe_after_install_q <= 1;
    if (f_probe_after_install_q && ep_request_valid[0] && ep_request_ready[0])
      f_reacquired_q <= 1;
    cover (store_pop && f_reacquired_q && f_probe_after_install_q);
    assume (i_d_ready == '1 && i_c_ready == '1 && i_read_ready && i_r_ready && i_w_ready);
    assume (i_sc_result_ready && i_cut_admit_ready && i_cut_admit_clean && i_cut_inval_done);
    assume (i_g_valid && i_g == f_cover_grant && i_u_valid && i_u == f_cover_release);
    assume (!i_wa_valid);
    assume (i_p == f_cover_probe);
    assume (i_p_valid == (!f_probe_sent_q && ((f_scenario == 1 && f_cycle_q >= 4) ||
        (f_scenario == 2 && request_live && !atomic_granted_q) ||
        (f_scenario == 3 && pending_q && f_installs_q != 0))));
    if (probe_capture) f_probe_sent_q <= 1;
  end
`endif
`ifdef STREAM_COVER
  // The environment answers nothing for the first STREAM_PASSIVE_CYCLES
  // cycles and is free afterwards.
`ifndef STREAM_PASSIVE_CYCLES
`define STREAM_PASSIVE_CYCLES 127
`endif
  logic [6:0] f_stream_cycle_q = 0;
  (* anyconst *) logic [1:0] f_stream_atomic;
  logic f_stream_atomic_sent_q = 0;
  wire f_stream_admit = f_stream_atomic != 0 && !f_stream_atomic_sent_q &&
      phase_q == Acquire && operation_q == PrefetchOp &&
      |(ep_request_valid & ep_request_ready);
  always_ff @(posedge i_clk) begin
    if (f_stream_cycle_q != 127) f_stream_cycle_q <= f_stream_cycle_q + 1'b1;
    assume (i_rst == !f_past_valid);
    assume (!i_fatal_stop && !i_maint_valid && !i_sc_valid && !i_sc_commit);
    assume (i_write_mask == 0);
    if (f_stream_cycle_q < `STREAM_PASSIVE_CYCLES)
      assume (!i_p_valid && !i_wa_valid && !i_g_valid && !i_u_valid);
    assume (f_stream_atomic <= 2);
    if (f_stream_admit) f_stream_atomic_sent_q <= 1;
    assume (i_read_valid == (f_stream_cycle_q == 4 || f_stream_cycle_q == 5 ||
        f_stream_cycle_q == 6 || (f_stream_atomic == 0 && f_stream_cycle_q == 48) ||
        f_stream_admit));
    assume (i_read_id == (f_stream_cycle_q == 4 ? 0 : f_stream_cycle_q == 5 ? 1 :
        f_stream_cycle_q == 6 ? 2 : 3));
    assume (i_address == (f_stream_admit ? lookup_addr_q :
        ADDR_WIDTH'(32'h80000000 + (f_stream_cycle_q == 4 ? 0 :
        f_stream_cycle_q == 5 ? 32 : f_stream_cycle_q == 6 ? 64 : 96))));
    assume (i_read_kind == (f_stream_admit ? f_stream_atomic : ReadLoad));
    assume (i_read_size == 3 && i_read_tag == 0);
    if (f_stream_cycle_q < `STREAM_PASSIVE_CYCLES)
      assume (i_d_ready == 0 && i_c_ready == 0 && !i_read_ready);
  end
`endif
`ifdef STREAM_TURN_COVER
  logic [6:0] f_turn_cycle_q = 0;
  logic [1:0] f_turn_sent_q = 0;
  (* anyconst *) logic [1:0] f_turn_scenario;
  logic f_turn_store_sent_q = 0, f_turn_probe_sent_q = 0;
  logic [3:0] f_turn_reply_age_q = 0;
  wire f_turn_store = f_turn_scenario == 1 && f_turn_sent_q == 2 && !f_turn_store_sent_q;
  coh_p_t f_turn_probe;
  coh_d_t f_turn_first_q, f_turn_second_q;
  coh_g_t f_turn_grant;
  always_comb begin
    f_turn_probe = '0;
    f_turn_probe.opcode = coherence_pkg::ProbeRead;
    f_turn_probe.addr = ADDR_WIDTH'(32'h80000800);
    f_turn_grant = '0;
    f_turn_grant.opcode = coherence_pkg::GrantS;
    f_turn_grant.q = f_turn_sent_q == 0 ? f_turn_first_q.q : f_turn_second_q.q;
    f_turn_grant.addr = f_turn_sent_q == 0 ? f_turn_first_q.addr : f_turn_second_q.addr;
    f_turn_grant.tid = f_turn_sent_q == 0 ? 1 : 2;
  end
  always_ff @(posedge i_clk) begin
    if (f_turn_cycle_q != 127) f_turn_cycle_q <= f_turn_cycle_q + 1'b1;
    if (i_g_valid && o_g_ready) f_turn_sent_q <= f_turn_sent_q + 1'b1;
    if (f_turn_store) f_turn_store_sent_q <= 1;
    if (probe_capture) f_turn_probe_sent_q <= 1;
    if (o_r_valid && f_turn_reply_age_q < 12) f_turn_reply_age_q <= f_turn_reply_age_q + 1'b1;
    assume (f_turn_scenario <= 3);
    assume (i_write_atomic == 0 && i_write_mask == (f_turn_store ? 8'hff : 0));
    assume (i_p_valid == (f_turn_scenario == 2 && !f_turn_probe_sent_q &&
        grant_read_turn_q && phase_q == Idle));
    assume (i_p == f_turn_probe && i_r_ready == (f_turn_reply_age_q == 12));
    if (o_d_valid[1] && i_d_ready[1]) f_turn_first_q <= o_d[1];
    if (o_d_valid[2] && i_d_ready[2]) f_turn_second_q <= o_d[2];
    assume (i_rst == !f_past_valid);
    assume (!i_fatal_stop && !i_sc_valid && !i_sc_commit);
    assume (i_maint_valid == (f_turn_scenario == 3 && grant_read_turn_q && phase_q == Idle));
    assume (!i_wa_valid && !i_u_valid);
    assume (i_read_valid == (f_turn_cycle_q == 4 || f_turn_cycle_q == 5 ||
        f_turn_cycle_q == 6));
    assume (i_read_id == (f_turn_cycle_q == 4 ? 0 : f_turn_cycle_q == 5 ? 1 : 2));
    assume (i_address == ADDR_WIDTH'(32'h80000000 + (f_turn_store || f_turn_cycle_q == 4 ? 0 :
        f_turn_cycle_q == 5 ? 64 : 8)));
    assume (i_read_kind == ReadLoad && i_read_size == 3 && i_read_tag == 0);
    assume (i_d_ready == '1 && i_c_ready == 0 && !i_read_ready);
    assume (i_g_valid == (f_turn_cycle_q >= 35 && f_turn_sent_q < 2));
    assume (i_g == f_turn_grant);
    p_stream_read_turn : cover (phase_q == Idle && grant_read_yield && rd_pick == 2);
    p_stream_cancel_turn : cover (phase_q == Idle && grant_read_hold &&
        prefetch_cancel && rd_candidate && !probe_priority && !probe_valid_q);
    p_stream_empty_turn : cover (phase_q == Idle && grant_read_hold &&
        !prefetch_cancel && !rd_candidate && !probe_priority && !probe_valid_q);
    p_stream_probe_turn : cover (local_turn_q && grant_read_turn_q &&
        grant_valid && grant_ready && f_turn_reply_age_q == 12);
  end
`endif
  logic   f_past_valid = 1'b0;
  // The covers skip the first sample, taken before the reset has acted.
  if (StreamEnabled) begin : gen_stream_covers
    always_ff @(posedge i_clk) begin
      p_stream_attach : cover (f_past_valid && !i_rst && wait_attach &&
          ld_prefetch_q[same_line_ep]);
      p_stream_lr_admit : cover (f_past_valid && !i_rst && i_read_valid &&
          i_read_kind == ReadLR && phase_q == Acquire && operation_q == PrefetchOp &&
          |(ep_request_valid & ep_request_ready));
      p_stream_amo_admit : cover (f_past_valid && !i_rst && i_read_valid &&
          i_read_kind == ReadAMO && phase_q == Acquire && operation_q == PrefetchOp &&
          |(ep_request_valid & ep_request_ready));
      if (PrefetchCount == 2)
        p_stream_two : cover (f_past_valid && !i_rst && live[MISSES-1] &&
            ld_prefetch_q[MISSES-1] && live[MISSES-2] && ld_prefetch_q[MISSES-2]);
    end
  end
  coh_g_t f_grant;
  assign f_grant = i_g;
  logic [5:0] f_probe_age;
  logic [2:0] f_admit_age, f_inval_age;
  wire [ADDR_WIDTH+26:0] f_reply_signature = {
    reply_q.opcode, reply_q.tid, reply_q.epoch, reply_q.hart, reply_q.addr,
    reply_q.state, reply_q.sc_valid, reply_q.data_valid, reply_q.data[7:0],
    reply_q.absorbed, reply_q.put_id, reply_q.put_epoch, reply_q.clear, reply_q.error
  };
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    // The hart's stop input stays set until reset, as cpu_top forms it.
    if (f_past_valid && !i_rst && $past(i_fatal_stop && !i_rst)) assume (i_fatal_stop);
    if (!active || !probe_valid_q || o_r_valid) f_probe_age <= '0;
    else f_probe_age <= f_probe_age + 1'b1;
    if (!active || cut_phase_q != CutAdmit) f_admit_age <= '0;
    else f_admit_age <= f_admit_age + 1'b1;
    if (!active || cut_phase_q != CutInvalidate) f_inval_age <= '0;
    else f_inval_age <= f_inval_age + 1'b1;
    if (!i_rst) begin
      if (f_admit_age >= 3) assume (i_cut_admit_ready);
      if (f_inval_age >= 4) assume (i_cut_inval_done);
      if (i_read_valid) begin
        assume (!rd_valid_q[i_read_id]);
        assume (!o_read_valid || o_read_id != i_read_id);
        assume (i_read_kind <= ReadAMO);
        if (i_read_kind == ReadAMO) begin
          assume (!pending_q && !store_push);
          assume (!atomic_q && !amo_waiting && !i_sc_valid);
        end
      end
      if (|i_write_mask) begin
        if (i_write_atomic) begin
          assume (atomic_q && atomic_granted_q && !atomic_written_q && !atomic_write_q);
          assume (i_address == atomic_addr_q && i_write_sc == atomic_sc_q);
          assume (i_write_tag == atomic_tag_q);
          if (i_write_sc) assume (sc_committed_q);
        end else begin
          assume (active && !atomic_q && !amo_waiting);
          assume (store_launch_ready_q);
        end
      end
      // The CPU's selected context serializes AMO and SC presentation.
      if (i_sc_valid) assume (!atomic_q && !amo_waiting);
      if (i_sc_valid && o_sc_ready) assume (!store_push);
      if (i_sc_commit) assume (atomic_q && atomic_sc_q && atomic_granted_q);
      // The selected-SC contract keeps the reservation through installation.
      // CPU reservation clearing is outside this component proof.
      if (atomic_local_q && atomic_sc_q && atomic_granted_q && !atomic_written_q)
        assume (local_sc_match);
      if (atomic_q || (request_live && acquisition_q.opcode == coherence_pkg::Atomic))
        assume (i_atomic_protected);
      if (i_p_valid) begin
        assume (probe_in.addr[4:0] == 0 && probe_in.epoch == 0 && probe_in.opcode <=
            coherence_pkg::CheckSC);
        assume (!(atomic_q && !atomic_local_q && atomic_granted_q &&
                  probe_in.addr == acquisition_q.addr));
        if (probe_in.opcode == coherence_pkg::ProbeRead && atomic_q && !atomic_local_q &&
            atomic_sc_q && sc_checked_q &&
            probe_in.addr == acquisition_q.addr)
          assume (probe_in.tid == sc_tid_q);
      end
      // The grant opcode follows each endpoint's captured owner.
      for (int ep = 1; ep < MISSES; ep++)
      if (i_g_valid && ep_g_ready[ep] && !f_grant.error)
        assume (f_grant.opcode == (ep_store[ep] ? coherence_pkg::GrantM : coherence_pkg::GrantS));
      if (i_g_valid && ep_g_ready[0] && !f_grant.error) begin
        if (acquisition_q.opcode == coherence_pkg::GetM || acquisition_q.opcode ==
            coherence_pkg::Atomic)
          assume (f_grant.opcode == coherence_pkg::GrantM);
          else if (acquisition_q.opcode == coherence_pkg::StoreConditional)
            assume (f_grant.opcode == coherence_pkg::GrantM || f_grant.opcode ==
                coherence_pkg::GrantFail);
            else assume (f_grant.opcode == coherence_pkg::GrantS);
      end
    end
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(active && i_read_valid && i_read_kind != ReadLoad &&
          phase_q == Acquire && operation_q == PrefetchOp &&
          |(ep_request_valid & ep_request_ready))) begin
        assert (atomic_read_waiting && prefetch_cancel);
        assert (rd_valid_q[$past(i_read_id)]);
        assert (rd_kind_q[$past(i_read_id)] == $past(i_read_kind));
        p_bounded_prefetch_live : assert (|(live & ld_prefetch_q));
      end
      if ($past(active && probe_valid_q && grant_read_turn_q && !prefetch_cancel))
        assert (grant_read_turn_q);
      if (active) p_bounded_probe_age : assert (f_probe_age < 32);
      if (local_turn_q) assert (phase_q == Idle && !probe_valid_q && !o_r_valid);
      if ($past(o_r_valid && i_r_ready)) assert (local_turn_q == $past(local_ready));
      if ($past(local_turn_q)) assert (!local_turn_q);
      if ($past(grant_read_yield && active && phase_q == Idle &&
          !probe_valid_q && !probe_priority)) begin
        assert (phase_q == Lookup && operation_q == ReadOp);
        assert (selected_read_q == $past(rd_pick));
        p_read_turn_pointer : assert (rd_rr_q == $past(rd_rr_q));
      end
      if ($past(grant_read_hold && !grant_read_yield && active && phase_q == Idle &&
          !probe_valid_q && !probe_priority)) begin
        assert (phase_q == Idle && !grant_read_turn_q);
        assert ($stable(rd_ready_q) ||
            $past(i_read_valid || ((!o_read_valid || i_read_ready) && rd_response) ||
                  s4_valid_q));
      end
      if ($past(active && phase_q == Idle))
        assert (grant_retry_q == $past(grant_read_yield && !probe_valid_q && !probe_priority));
      else assert ($stable(grant_retry_q));
      if ($past(read_miss && grant_retry_q && grant_valid &&
          rd_kind_q[selected_read_q] == ReadLoad)) assert (phase_q == Idle);
      if ($past(prefetch_cancel)) assert (!grant_read_turn_q);
      else if ($past(active && phase_q == UpdateWait && array_ready &&
          operation_q == GrantOp && grant_ep_q != '0))
        assert (grant_read_turn_q == $past(!grant_prefetch_q && grant_demand_waiter));
      else if ($past((grant_valid && grant_ready) ||
          (active && phase_q == Idle && !probe_valid_q && !probe_priority && grant_read_hold) ||
          (active && phase_q == Lookup && operation_q == ReadOp))) assert (!grant_read_turn_q);
      else assert ($stable(grant_read_turn_q));
      if (local_turn_q && grant_valid && active) assert (grant_ready);
      if (rd_candidate && &read_probe_count_q) assert (local_ready);
      if ($past(local_turn_q && active && !grant_valid && atomic_write_q))
        p_bounded_atomic_write_phase : assert (phase_q == Lookup && operation_q == AtomicWriteOp);
      if ($past(active && o_r_valid && !i_r_ready) && active) begin
        assert (o_r_valid);
        p_reply_hold : assert (f_reply_signature == $past(f_reply_signature));
      end
      if (o_cut_admit_valid || o_cut_inval_valid)
        assert (probe_valid_q ? probe_q.opcode == coherence_pkg::ProbeInvalidate :
            probe_capture && probe_in.opcode == coherence_pkg::ProbeInvalidate);
      if (cut_phase_q != CutIdle)
        assert (probe_valid_q && probe_q.opcode == coherence_pkg::ProbeInvalidate);
      if (o_r_valid && probe_q.opcode == coherence_pkg::ProbeInvalidate)
        assert (cut_phase_q == CutDone);
      if ($past(active && cut_phase_q == CutWait)) assert (cut_phase_q == CutDone);
      cover (active && cut_phase_q == CutAdmit && i_cut_admit_ready && i_cut_admit_clean);
      if (o_cut_release)
        assert ($past(o_r_valid && i_r_ready && probe_q.opcode == coherence_pkg::ProbeInvalidate));
      if (o_sc_write_done) begin
        p_bounded_sc_write_done : assert (atomic_written_q && sc_committed_q);
        assert ($past(phase_q == UpdateWait && array_ready && operation_q == AtomicWriteOp));
      end
      if ($past(atomic_q && atomic_local_q) && !atomic_q) begin
        assert ($past(phase_q == LocalRelease));
        assert ($past(atomic_written_q || !atomic_granted_q));
      end
      if (atomic_local_q && $past(atomic_local_q)) begin
        p_local_addr_stable: assert (atomic_addr_q == $past(atomic_addr_q));
        p_local_tag_stable: assert (atomic_tag_q == $past(atomic_tag_q));
        p_local_size_stable: assert (atomic_size_q == $past(atomic_size_q));
        p_local_way_stable: assert (atomic_way_q == $past(atomic_way_q));
        p_local_read_stable: assert (atomic_read_q == $past(atomic_read_q));
        if ($past(phase_q != LocalMerge))
          p_local_image_stable: assert (image_q == $past(image_q));
      end
      if (o_sc_write_pending) assert (atomic_q && atomic_sc_q && !atomic_written_q);
      assert (o_block_valid == (atomic_q ? 4'b0001 : store_valid));
`ifndef STREAM_UNBOUNDED_PROOF
      for (int holder = 0; holder < 4; holder++)
        if (store_valid[holder]) assert (o_block_addr[holder] == store_addr[holder]);
`endif
      if (atomic_q) assert (o_block_addr[0] == atomic_addr_q);
      if ($past(store_pop && tail_q)) assert (o_pending_store);
      assert (store_ack == $past(store_push));
      cover (tail_q && pending_q);
      cover (store_pop && tail_q && store_continue);
      cover (read_owed_q && pending_q && phase_q == Lookup && operation_q == ReadOp);
      if ($past(active && grant_valid && grant_ready)) assert (operation_q == GrantOp);
      if ($past(active && phase_q == Idle) && phase_q == Lookup && operation_q == GrantOp)
        assert ($past(grant_valid && grant_ready));
      if (active && phase_q == LookupWait && array_valid && operation_q == GrantOp)
        p_bounded_array_available : assert (array_available);
      if (o_r_valid && probe_q.opcode == coherence_pkg::ProbeInvalidate)
        assert (reply_q.state == coherence_pkg::Invalid);
      cover (o_cut_release);
      cover (o_sc_write_done);
    end
  end
`endif
endmodule
