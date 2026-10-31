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

// Eight unmerged CPU reads share MISSES request endpoints: endpoint 0 serves
// every acquisition kind when MISSES is one. With multiple endpoints,
// endpoint 0 serves stores, LR, SC and AMOs; endpoints 1 to MISSES-1 serve
// ordinary load misses. A committed store owns its bytes separately from
// the read queue and from dirty probe replies.
module coherence_l1d #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned CACHE_BYTES = 128 * 1024,
    parameter int unsigned WAYS = 4,
    parameter int unsigned TAG_BITS = 7,
    // Request endpoints. With one endpoint, endpoint 0 serves every acquisition.
    // With multiple endpoints, ordinary loads use only endpoints 1 to MISSES-1.
    parameter int unsigned MISSES = 1,
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
    output logic [1:0] o_block_valid,
    output logic [1:0][ADDR_WIDTH-1:0] o_block_addr,
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
    output logic [MISSES-1:0] o_c_selected,
    input logic [MISSES-1:0] i_c_ready,
    output logic [MISSES-1:0][ADDR_WIDTH+17:0] o_c,
    input logic i_u_valid,
    output logic o_u_ready,
    input logic [ADDR_WIDTH+14:0] i_u,
    output cache_perf_pkg::cache_instance_perf_events_t o_perf_events,
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
    ProbeReply
  } phase_t;
  typedef enum logic [2:0] {
    CutIdle,
    CutAdmit,
    CutInvalidate,
    CutWait,
    CutDone
  } cut_phase_t;
  typedef enum logic [2:0] {
    ReadOp,
    StoreOp,
    GrantOp,
    ProbeOp,
    MaintOp,
    AtomicWriteOp
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
  logic [7:0] rd_error_q, rd_ready_next, rd_error_next, rd_valid_next, rd_miss_next;
  logic read_miss;
  logic read_failure, read_hit, read_fill;
  logic rd_candidate, rd_response;
  logic [2:0] rd_pick, rd_result, rd_rr_q, rd_response_rr_q, selected_read_q;
  logic pending_q, pending_reported_q, pending_miss_q;
  logic [ADDR_WIDTH-1:0] pending_addr_q;
  logic [255:0] pending_data_q;
  logic [31:0] pending_mask_q;
  logic atomic_q, atomic_sc_q, atomic_granted_q, atomic_written_q;
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
  // per endpoint; endpoint 0 keeps the store, SC and atomic registers.
  localparam bit Multi = MISSES > 1;
  localparam int unsigned EpBits = MISSES > 1 ? $clog2(MISSES) : 1;
  // Per-endpoint state is padded to every index EpBits can name; unused
  // entries are idle constants.
  localparam int unsigned EpSlots = 1 << EpBits;
  logic [EpSlots-1:0] live, ep_request_ready, ep_request_valid, ep_grant_valid, ep_grant_ready;
  logic [EpSlots-1:0] ep_done_valid, ep_write_done, ep_g_ready, ep_u_ready;
  logic [EpSlots-1:0][1:0] ep_done_status;
  coh_g_t [EpSlots-1:0] ep_grant;
  logic [EpBits-1:0] acq_ep_q, grant_ep_q, grant_pick;
  logic any_live;
  // Load endpoint bookkeeping, used only when MISSES > 1.
  logic [ADDR_WIDTH-6:0] ld_line_q[EpSlots];
  logic [2:0] ld_read_q[EpSlots];
  logic [EpSlots-1:0] ld_done_q, installed_q, same_line_q;
  logic [1:0] ld_status_q[EpSlots];
  logic same_line, store_same_line_q, load_ep_free, load_block, amo_waiting, wait_attach;
  logic load_grant_waiting, ep0_wb_ok, drain_q;
  logic [EpBits-1:0] same_line_ep, load_ep_index;
  logic [7:0] rd_wait_q, rd_wait_release_q, rd_waiting, rd_owned, rd_miss_retry;
  logic [EpBits-1:0] rd_wait_ep_q[8];
  logic [2:0] fill_read_slot, failure_read_slot;
  // The selected grant as a one-hot, and each endpoint's failing-read and
  // error bits, so a failure reaches read status without the wide grant
  // multiplexer.
  logic [EpSlots-1:0] pick_onehot, ep_read_fail, ep_fail, ep_fail_error;
  logic acquisition_store_q, acquisition_sc_q;
  logic [2:0] acquisition_read_q;
  logic grant_valid, grant_ready;
  coh_g_t grant, grant_q;
  logic done_q, done_ready, written_q;
  logic [1:0] done_status_q;
  logic pending_blocked;

  assign read_failure = active && phase_q == Idle &&
      !probe_valid_q && !probe_priority && grant_valid && |(pick_onehot & ep_read_fail);
  assign read_hit = active && phase_q == LookupWait && array_valid &&
      operation_q != ProbeOp && operation_q != GrantOp && operation_q != StoreOp &&
      operation_q != AtomicWriteOp && operation_q != MaintOp &&
      rd_kind_q[selected_read_q] != ReadAMO && array_hit;
  assign read_miss = active && phase_q == LookupWait && array_valid &&
      operation_q != ProbeOp && operation_q != GrantOp && operation_q != StoreOp &&
      operation_q != AtomicWriteOp && operation_q != MaintOp &&
      (rd_kind_q[selected_read_q] == ReadAMO || !array_hit);
  assign read_fill = active && phase_q == UpdateWait && array_ready &&
      operation_q == GrantOp &&
      (grant_ep_q != '0 || (!acquisition_store_q && !acquisition_sc_q));

  coherence_read_flags read_flags (
      .i_valid(rd_valid_q),
      .i_miss(rd_miss_q),
      .i_ready(rd_ready_q),
      .i_error(rd_error_q),
      .i_allocate_valid(i_read_valid),
      .i_allocate_id(i_read_id),
      .i_response_valid((!o_read_valid || i_read_ready) && rd_response),
      .i_response_id(rd_result),
      .i_failure_valid(read_failure),
      .i_acquisition_id(read_fill ? fill_read_slot : failure_read_slot),
      .i_failure_error(|(pick_onehot & ep_fail_error)),
      .i_hit_valid(read_hit),
      .i_hit_id(selected_read_q),
      .i_fill_valid(read_fill),
      .i_miss_valid(read_miss && !wait_attach),
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

  assign active = !i_rst && !i_fatal_stop && !o_fatal;
  assign probe_in = i_p;
  assign ack = i_wa;
  // Each CPU request contributes one lookup decision. Retries, probe traffic
  // and maintenance do not contribute demand events.
  logic [7:0] perf_read_seen_q, perf_read_miss_q;
  logic perf_lookup, perf_access, perf_hit, perf_sc;
  logic [cache_perf_pkg::MissOutstandingBits-1:0] perf_outstanding;
  assign perf_lookup = active && phase_q == LookupWait && array_valid &&
      ((operation_q == ReadOp && !perf_read_seen_q[selected_read_q]) ||
       (operation_q == StoreOp && !pending_miss_q));
  assign perf_sc = i_sc_valid && o_sc_ready;
  assign perf_access = perf_lookup || perf_sc;
  assign perf_hit = perf_lookup && array_hit &&
      (operation_q == StoreOp ? array_state == coherence_pkg::Modified :
       rd_kind_q[selected_read_q] != ReadAMO);
  always_comb begin
    perf_outstanding = cache_perf_pkg::MissOutstandingBits'(pending_q && pending_miss_q);
    for (int slot = 0; slot < 8; slot++)
      perf_outstanding += cache_perf_pkg::MissOutstandingBits'(
          rd_valid_q[slot] && !rd_ready_q[slot] && perf_read_miss_q[slot]);
    perf_outstanding += cache_perf_pkg::MissOutstandingBits'(
        atomic_q && atomic_sc_q && !atomic_granted_q && !o_sc_result_valid);
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      perf_read_seen_q <= '0;
      perf_read_miss_q <= '0;
      o_perf_events <= '0;
    end else begin
      if (perf_lookup && operation_q == ReadOp) begin
        perf_read_seen_q[selected_read_q] <= 1'b1;
        perf_read_miss_q[selected_read_q] <= !perf_hit;
      end
      if (i_read_valid) begin
        perf_read_seen_q[i_read_id] <= 1'b0;
        perf_read_miss_q[i_read_id] <= 1'b0;
      end
      o_perf_events <= '0;
      o_perf_events.access <= perf_access;
      o_perf_events.hit <= perf_hit;
      o_perf_events.miss <= perf_access && !perf_hit;
      o_perf_events.miss_outstanding <= perf_outstanding;
      o_perf_events.hit_under_miss <= perf_hit && perf_outstanding != 0;
      o_perf_events.writeback <= active && phase_q == Freeze &&
          wb_freeze_ready[freeze_slot_q] && !freeze_maintenance_q;
      o_perf_events.slot_full_stall <= active && phase_q == LookupWait && array_valid &&
          (operation_q == StoreOp || operation_q == ReadOp) && !array_hit &&
          (!Multi ? (request_live || !wb_free) : operation_q == StoreOp ?
           (request_live || !ep0_wb_ok || store_same_line_q) :
           rd_kind_q[selected_read_q] == ReadLR ?
           (same_line || request_live || !ep0_wb_ok || load_block) :
           rd_kind_q[selected_read_q] == ReadAMO ? (any_live || !wb_free) :
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
      assert (o_perf_events.miss_outstanding <= 10);
      if ($past(i_rst)) assert (o_perf_events == '0);
      if (o_perf_events.hit_under_miss) begin
        assert (o_perf_events.hit);
        assert (o_perf_events.miss_outstanding != 0);
      end
    end
  end
`endif

  assign maint_eligible = maint_q && !pending_q && !atomic_q && !any_live && wb_free;
  assign o_pending_store = pending_q;
  assign o_atomic_live = atomic_q;
  assign o_sc_write_pending = atomic_q && atomic_sc_q && atomic_granted_q && !atomic_written_q;
  // SQ launch readiness precedes its registered write by one cycle.
  assign o_store_ready = active && !pending_q && !atomic_q && !maint_q && !i_maint_valid;
  assign o_write_inflight = (pending_q && !pending_reported_q) || atomic_write_q;
  assign o_block_valid = {atomic_q, pending_q};
  assign o_block_addr = {atomic_addr_q, pending_addr_q};
  assign o_sc_ready = active && !atomic_q && !pending_q && !any_live &&
      !o_sc_result_valid && i_atomic_protected && phase_q == Idle && wb_free &&
      !probe_valid_q && !probe_priority;
  assign o_sc_write_tag = atomic_tag_q;
  assign local_ready = grant_valid || atomic_write_q ||
      (atomic_q && atomic_sc_q && !request_live) ||
      (pending_q && !pending_blocked &&
       (!pending_miss_q || (!request_live && ep0_wb_ok && !store_same_line_q)) &&
       !(request_live && acquisition_store_q)) ||
      (rd_candidate && &read_probe_count_q) || maint_eligible ||
      (i_sc_valid && !atomic_q && !pending_q && !any_live &&
       !o_sc_result_valid && i_atomic_protected && wb_free);
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
  // The early cut hold reads the stop condition one cycle late. Both stop
  // inputs stay set until reset, so the late copy only adds a hold in the
  // stop's first cycle, when no probe can be captured.
  logic cut_stop_q;
  always_ff @(posedge i_clk) cut_stop_q <= !i_rst && (i_fatal_stop || o_fatal);
  (* keep = "true" *) wire invalidate_eligible = !cut_stop_q &&
      phase_q == Idle && !probe_valid_q && !o_r_valid && !local_turn_q &&
      probe_in.opcode == coherence_pkg::ProbeInvalidate;
  assign o_cut_hold = (i_p_valid && !i_rst && invalidate_eligible) ||
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
  begin
    p_absorb_go_exact : assert (absorb_go == wb_absorb_ready[probe_put_q]);
    // The hold covers every invalidating capture and active cut. It is exact
    // except in the stop's first cycle, when it may also hold for an offer.
    p_cut_hold_covers : assert (o_cut_hold || !(
        (i_p_valid && o_p_ready && probe_in.opcode == coherence_pkg::ProbeInvalidate) ||
        (cut_phase_q != CutIdle && cut_phase_q != CutDone)));
    p_cut_hold_exact : assert (o_cut_hold ==
        ((i_p_valid && o_p_ready && probe_in.opcode == coherence_pkg::ProbeInvalidate) ||
         (cut_phase_q != CutIdle && cut_phase_q != CutDone)) ||
        ((i_fatal_stop || o_fatal) && !cut_stop_q));
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
  assign grant_ready = active && phase_q == Idle && !probe_valid_q && !probe_priority;
  // Data-class request identities 0 to 7 are legal.
  if (MISSES < 1 || MISSES > 8) begin : gen_invalid_misses
    initial $fatal(1, "coherence_l1d: MISSES must be 1 to 8");
  end
  assign request_live = live[0];
  assign any_live = |live;
  assign o_g_ready = |ep_g_ready;
  assign o_u_ready = |ep_u_ready;
  assign ep_done_valid[0] = done_q;
  assign ep_done_status[0] = done_status_q;
  assign ep_write_done[0] = written_q;
  for (genvar ep = 0; ep < MISSES; ep++) begin : gen_request
    assign ep_request_valid[ep] = active && phase_q == Acquire && acq_ep_q == EpBits'(ep);
    assign ep_grant_ready[ep] = grant_ready && grant_valid && grant_pick == EpBits'(ep);
    if (ep > 0) begin : gen_load_done
      assign ep_done_valid[ep] = ld_done_q[ep];
      assign ep_done_status[ep] = ld_status_q[ep];
      assign ep_write_done[ep] = 1'b0;
    end
    coh_g_t endpoint_grant;
    assign ep_grant[ep] = endpoint_grant;
    assign ep_fail[ep] = endpoint_grant.error || endpoint_grant.opcode == coherence_pkg::GrantFail;
    assign ep_fail_error[ep] = endpoint_grant.error;
    coherence_request_endpoint #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .SOURCE(0),
        .PORT_CLASS(0),
        .SLOT(ep)
    ) request (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_epoch(1'b0),
        .i_request_valid(ep_request_valid[ep]),
        .o_request_ready(ep_request_ready[ep]),
        .i_request(acquisition),
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
        .o_c_selected(o_c_selected[ep]),
        .i_c_ready(i_c_ready[ep]),
        .o_c(o_c[ep]),
        .i_u_valid(i_u_valid),
        .o_u_ready(ep_u_ready[ep]),
        .i_u(i_u),
        .o_live(live[ep])
    );
  end
  // A load endpoint's grant installs only while a WB slot is free for a
  // modified victim; endpoint 0 reserved its slot at Acquire.
  for (genvar ep = MISSES; ep < EpSlots; ep++) begin : gen_unused_endpoint
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
    assign ep_write_done[ep] = 1'b0;
  end
  // Endpoint 0's grant goes first, then the lowest-numbered load grant. No new
  // acquisition starts while a grant is selectable, so each waits only for the
  // grants already present. A load grant also needs a free WB slot.
  always_comb begin
    grant_pick = '0;
    for (int ep = EpSlots - 1; ep >= 0; ep--) if (ep_grant_valid[ep]) grant_pick = EpBits'(ep);
  end
  assign grant_valid = ep_grant_valid[0] || (|(ep_grant_valid & ~EpSlots'(1)) && wb_free);
  assign grant = ep_grant[grant_pick];
  always_comb begin
    for (int ep = 0; ep < EpSlots; ep++) begin
      pick_onehot[ep] = ep_grant_valid[ep];
      for (int lower = 0; lower < ep; lower++) if (ep_grant_valid[lower]) pick_onehot[ep] = 1'b0;
      ep_read_fail[ep] = ep_fail[ep] && (ep != 0 || (!acquisition_sc_q && !acquisition_store_q));
    end
    failure_read_slot = '0;
    for (int ep = 0; ep < EpSlots; ep++)
    if (pick_onehot[ep]) failure_read_slot |= ep == 0 ? acquisition_read_q : ld_read_q[ep];
  end
  assign fill_read_slot = grant_ep_q == '0 ? acquisition_read_q : ld_read_q[grant_ep_q];
  // Load endpoints. A miss on a line some live endpoint holds waits for that
  // endpoint: for its installation if it has not installed, otherwise for its
  // release. New load acquisitions stop while an atomic, an AMO read, an SC or
  // maintenance waits for every endpoint to drain.
  always_comb begin
    amo_waiting = 1'b0;
    for (int slot = 0; slot < 8; slot++)
    amo_waiting |= rd_valid_q[slot] && !rd_ready_q[slot] && rd_kind_q[slot] == ReadAMO;
    load_ep_free = 1'b0;
    load_ep_index = '0;
    for (int ep = MISSES - 1; ep >= 1; ep--)
    if (!live[ep]) begin
      load_ep_free = 1'b1;
      load_ep_index = EpBits'(ep);
    end
    same_line_ep = '0;
    for (int ep = 0; ep < MISSES; ep++) if (same_line_q[ep]) same_line_ep = EpBits'(ep);
    rd_owned = '0;
    rd_waiting = '0;
    if (request_live && !acquisition_store_q && !acquisition_sc_q)
      rd_owned[acquisition_read_q] = 1'b1;
    if (Multi)
      for (int ep = 1; ep < MISSES; ep++)
      if (live[ep] && !installed_q[ep]) rd_owned[ld_read_q[ep]] = 1'b1;
    for (int slot = 0; slot < 8; slot++) begin
      rd_waiting[slot] = Multi && rd_wait_q[slot] && live[rd_wait_ep_q[slot]] &&
          !(installed_q[rd_wait_ep_q[slot]] && !rd_wait_release_q[slot]);
      if (!Multi) rd_miss_retry[slot] = !request_live && wb_free;
      else if (rd_kind_q[slot] == ReadLoad) rd_miss_retry[slot] = load_ep_free && !load_block;
      else if (rd_kind_q[slot] == ReadLR)
        rd_miss_retry[slot] = !request_live && ep0_wb_ok && !load_block;
      else rd_miss_retry[slot] = !any_live && wb_free;
    end
  end
  assign same_line = Multi && |same_line_q;
  // A load grant waits only for a WB slot. Endpoint 0 does not take the last
  // free slot from it, so stores and LR cannot keep a load grant waiting.
  assign load_grant_waiting = Multi && |(ep_grant_valid & ~EpSlots'(1));
  assign ep0_wb_ok = wb_free && !(load_grant_waiting && !(&(~wb_live)));
  assign load_block = Multi && (atomic_q || drain_q);
  assign wait_attach = Multi && read_miss && rd_kind_q[selected_read_q] != ReadAMO && same_line;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ld_done_q <= '0;
      drain_q <= 1'b0;
      installed_q <= '0;
      same_line_q <= '0;
      store_same_line_q <= 1'b0;
      rd_wait_q <= '0;
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
        if (ep > 0 && live[ep] && ld_line_q[ep] == pending_addr_q[ADDR_WIDTH-1:5])
          store_same_line_q <= 1'b1;
        if (active && phase_q == Acquire && acq_ep_q == EpBits'(ep) && ep_request_ready[ep]) begin
          installed_q[ep] <= 1'b0;
          if (ep > 0) begin
            ld_line_q[ep] <= lookup_addr_q[ADDR_WIDTH-1:5];
            ld_read_q[ep] <= selected_read_q;
            ld_done_q[ep] <= 1'b0;
            ld_status_q[ep] <= coherence_pkg::Consumed;
          end
        end
        if (grant_ready && grant_valid && grant_pick == EpBits'(ep) &&
            (grant.error || grant.opcode == coherence_pkg::GrantFail)) begin
          installed_q[ep] <= 1'b1;
          if (ep > 0) begin
            ld_done_q[ep] <= 1'b1;
            ld_status_q[ep] <= grant.error ? coherence_pkg::Error : coherence_pkg::Consumed;
          end
        end
        if (active && phase_q == UpdateWait && array_ready && operation_q == GrantOp &&
            grant_ep_q == EpBits'(ep)) begin
          installed_q[ep] <= 1'b1;
          if (ep > 0) ld_done_q[ep] <= 1'b1;
        end
      end
      for (int slot = 0; slot < 8; slot++) begin
        if (rd_wait_q[slot] && !rd_waiting[slot]) rd_wait_q[slot] <= 1'b0;
        if (wait_attach && selected_read_q == 3'(slot)) begin
          rd_wait_q[slot] <= 1'b1;
          rd_wait_ep_q[slot] <= same_line_ep;
          rd_wait_release_q[slot] <= installed_q[same_line_ep];
        end
        if (i_read_valid && i_read_id == 3'(slot)) rd_wait_q[slot] <= 1'b0;
      end
    end
  end
`ifndef SYNTHESIS
  // At most one live endpoint holds a line; no load endpoint lives beside an
  // atomic; a load grant installs with a free WB slot.
  always_ff @(posedge i_clk)
    if (sim_reset_seen_q && !i_rst && Multi) begin
      for (int ep = 0; ep < MISSES; ep++)
      for (int other = 0; other < MISSES; other++)
      if (ep < other && live[ep] && live[other])
        assert ((ep == 0 ? acquisition_q.addr[ADDR_WIDTH-1:5] : ld_line_q[ep]) != ld_line_q[other]);
      if (atomic_q && atomic_granted_q)
        for (int ep = 1; ep < MISSES; ep++) assert (!live[ep]);
      if (grant_ready && grant_valid && grant_pick != '0) assert (wb_free);
      if (active && phase_q == LookupWait && array_valid && operation_q == GrantOp &&
          grant_ep_q != '0 && !array_hit && array_state == coherence_pkg::Modified)
        assert (wb_free);
    end
`endif
`ifndef SYNTHESIS
  always_comb
    if (grant_valid) begin
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
      .i_pending(pending_q),
      .i_pending_addr(pending_addr_q),
      .i_atomic(atomic_q),
      .i_atomic_addr(atomic_addr_q),
      .i_wb_live(wb_live),
      .i_wb_addr(wb_addr),
      .i_atomic_protected(i_atomic_protected),
      .i_owned(rd_owned),
      .i_waiting(rd_waiting),
      .i_miss_retry(rd_miss_retry),
      .o_found(rd_candidate),
      .o_index(rd_pick),
      .o_address(rd_selected_addr)
  );

  always_comb begin
    wb_free = 1'b0;
    wb_free_slot = 1'b0;
    wb_match = 1'b0;
    wb_match_slot = 1'b0;
    pending_blocked = 1'b0;
    for (int slot = 1; slot >= 0; slot--) begin
      if (!wb_live[slot] && !(live[0] && reserved_wb_q == 1'(slot))) begin
        wb_free = 1'b1;
        wb_free_slot = 1'(slot);
      end
      if (wb_live[slot] && wb_addr[slot] == (probe_capture ? probe_in.addr : probe_q.addr)) begin
        wb_match = 1'b1;
        wb_match_slot = 1'(slot);
      end
      if (wb_live[slot] && wb_addr[slot][ADDR_WIDTH-1:5] == pending_addr_q[ADDR_WIDTH-1:5])
        pending_blocked = 1'b1;
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
    if (operation_q == StoreOp) begin
      acquisition.opcode = coherence_pkg::GetM;
      acquisition.mask   = pending_mask_q;
    end else if (atomic_q && atomic_sc_q) begin
      acquisition.opcode = coherence_pkg::StoreConditional;
      acquisition.size   = atomic_size_q;
    end else begin
      acquisition.size = rd_size_q[selected_read_q];
      if (rd_kind_q[selected_read_q] == ReadLR) acquisition.opcode = coherence_pkg::LoadReserved;
      if (rd_kind_q[selected_read_q] == ReadAMO) acquisition.opcode = coherence_pkg::Atomic;
    end
  end

  coherence_array #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(32),
      .CACHE_BYTES(CACHE_BYTES),
      .WAYS(WAYS),
      .BIMODAL_INSERT(1'b1)
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
      .i_req_skip_data_on_hit(1'b0),
      .i_req_data_if_modified(probe_launch || operation_q == ProbeOp),
      .o_resp_valid(array_valid),
      .i_resp_ready(phase_q == LookupWait),
      .o_resp_hit(array_hit),
      .o_resp_available(array_available),
      .o_resp_way(array_way),
      .o_resp_addr(array_addr),
      .o_resp_state(array_state),
      .o_resp_data_valid(),
      .o_resp_data(array_data),
      .i_update_valid(active && phase_q == Update),
      .o_update_ready(update_ready),
      .i_update_addr(update_addr_q),
      .i_update_way(way_q),
      .i_update_state(state_q),
      .i_update_insert(operation_q == GrantOp),
      .i_update_mask({32{operation_q != ProbeOp}}),
      .i_update_data(image_q)
  );

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
      selected_read_q <= '0;
      o_read_valid <= 1'b0;
      o_read_id <= '0;
      o_read_data <= '0;
      o_read_error <= 1'b0;
      pending_q <= 1'b0;
      pending_reported_q <= 1'b0;
      pending_miss_q <= 1'b0;
      pending_addr_q <= '0;
      pending_data_q <= '0;
      pending_mask_q <= '0;
      atomic_q <= 1'b0;
      atomic_sc_q <= 1'b0;
      atomic_granted_q <= 1'b0;
      atomic_written_q <= 1'b0;
      sc_committed_q <= 1'b0;
      atomic_addr_q <= '0;
      atomic_size_q <= '0;
      atomic_tag_q <= '0;
      atomic_write_q <= 1'b0;
      atomic_data_q <= '0;
      atomic_mask_q <= '0;
      atomic_way_q <= '0;
      sc_checked_q <= 1'b0;
      sc_tid_q <= '0;
      o_write_done <= 1'b0;
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
      lookup_addr_q <= '0;
      image_q <= '0;
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
      grant_ep_q <= '0;
      grant_q <= '0;
      done_q <= 1'b0;
      written_q <= 1'b0;
      done_status_q <= coherence_pkg::Consumed;
      o_fatal <= 1'b0;
      o_fatal_addr <= '0;
      for (int index = 0; index < 8; index++) begin
        rd_data_q[index] <= '0;
      end
    end else begin
      rd_valid_q <= rd_valid_next;
      rd_miss_q <= rd_miss_next;
      rd_ready_q <= rd_ready_next;
      rd_error_q <= rd_error_next;
      o_write_done <= 1'b0;
      o_sc_write_done <= 1'b0;
      o_cut_release <= 1'b0;
      if (i_sc_commit) sc_committed_q <= 1'b1;
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
      if (i_u_valid && ep_u_ready[0] && atomic_q) begin
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
        end else begin
          pending_q <= 1'b1;
          pending_reported_q <= 1'b0;
          pending_miss_q <= 1'b0;
          pending_addr_q <= i_address;
          pending_data_q <= {4{i_write_data}};
          pending_mask_q <= 32'(i_write_mask) << {i_address[4:3], 3'b000};
        end
      end
      if (i_sc_valid && o_sc_ready) begin
        atomic_q <= 1'b1;
        atomic_sc_q <= 1'b1;
        atomic_granted_q <= 1'b0;
        atomic_written_q <= 1'b0;
        sc_committed_q <= 1'b0;
        atomic_addr_q <= i_sc_address;
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
              lookup_addr_q <= probe_in.addr;
              operation_q <= ProbeOp;
              phase_q <= probe_launch ? LookupWait : Lookup;
            end else if (probe_valid_q && !o_r_valid) begin
              reply_q <= '0;
              reply_q.tid <= probe_q.tid;
              reply_q.epoch <= probe_q.epoch;
              reply_q.addr <= probe_q.addr;
              probe_absorbed_q <= wb_match;
              probe_put_q <= wb_match_slot;
              lookup_addr_q <= probe_q.addr;
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
            end else if (grant_valid) begin
              grant_q <= grant;
              grant_ep_q <= grant_pick;
              operation_q <= GrantOp;
              lookup_addr_q <= grant.addr;
              if (grant.error || grant.opcode == coherence_pkg::GrantFail) begin
                if (grant_pick != '0) rd_data_q[ld_read_q[grant_pick]] <= '0;
                else begin
                done_q <= 1'b1;
                done_status_q <= grant.error ? coherence_pkg::Error : coherence_pkg::Consumed;
                if (acquisition_sc_q) begin
                  o_sc_result_valid <= 1'b1;
                  o_sc_success <= 1'b0;
                  o_sc_error <= grant.error;
                end else if (!acquisition_store_q) begin
                  rd_data_q[acquisition_read_q] <= '0;
                end else begin
                  o_fatal <= 1'b1;
                  o_fatal_addr <= acquisition_q.addr;
                end
                end
              end else phase_q <= Lookup;
            end else if (i_sc_valid && o_sc_ready) begin
              // The selected SC owns the following acquisition.
            end else if (atomic_write_q) begin
              operation_q <= AtomicWriteOp;
              lookup_addr_q <= atomic_addr_q;
              phase_q <= Lookup;
            end else if (atomic_q && atomic_sc_q && !request_live) begin
              operation_q <= ReadOp;
              lookup_addr_q <= atomic_addr_q;
              acq_ep_q <= '0;
              phase_q <= Acquire;
            end else if (pending_q && !pending_blocked &&
                (!pending_miss_q || (!request_live && ep0_wb_ok && !store_same_line_q)) &&
                !(request_live && acquisition_store_q)) begin
              operation_q <= StoreOp;
              lookup_addr_q <= pending_addr_q;
              phase_q <= Lookup;
            end else if (rd_candidate && !(maint_eligible && maint_turn_q)) begin
              maint_turn_q <= 1'b1;
              operation_q <= ReadOp;
              selected_read_q <= rd_pick;
              lookup_addr_q <= rd_selected_addr;
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
                lookup_addr_q <= maint_line_q ? maint_addr_q : ADDR_WIDTH'(maint_set_q) << 5;
                phase_q <= Lookup;
              end
            end
          end
          Lookup: if (array_ready) phase_q <= LookupWait;
          LookupWait:
          if (array_valid) begin
            way_q <= array_way;
            update_addr_q <= array_addr;
            image_q <= array_data;
            state_q <= array_state;
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
                  if (grant_ep_q == '0 && acquisition_store_q) begin
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
                  for (int index = 0; index < 32; index++)
                  if (pending_mask_q[index]) image_q[8*index+:8] <= pending_data_q[8*index+:8];
                  phase_q <= Update;
                end else begin
                  pending_miss_q <= 1'b1;
                  acq_ep_q <= '0;
                  phase_q <= !request_live && ep0_wb_ok && !store_same_line_q ? Acquire : Idle;
                end
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
              default: begin
                if (rd_kind_q[selected_read_q] == ReadAMO) begin
                  if (!any_live && !atomic_q && wb_free && i_atomic_protected) begin
                    acq_ep_q <= '0;
                    atomic_q <= 1'b1;
                    atomic_sc_q <= 1'b0;
                    atomic_granted_q <= 1'b0;
                    atomic_written_q <= 1'b0;
                    atomic_addr_q <= lookup_addr_q;
                    atomic_size_q <= rd_size_q[selected_read_q];
                    atomic_tag_q <= rd_tag_q[selected_read_q];
                    phase_q <= Acquire;
                  end else phase_q <= Idle;
                end else if (array_hit) begin
                  rd_data_q[selected_read_q] <= array_data[64*rd_addr_q[selected_read_q][4:3]+:64];
                  phase_q <= Idle;
                end else if (!Multi) begin
                  phase_q <= !request_live && wb_free ? Acquire : Idle;
                end else if (same_line) begin
                  // Wait for the endpoint already acquiring this line.
                  phase_q <= Idle;
                end else if (rd_kind_q[selected_read_q] == ReadLR) begin
                  acq_ep_q <= '0;
                  phase_q <= !request_live && ep0_wb_ok && !load_block ? Acquire : Idle;
                end else if (load_ep_free && !load_block) begin
                  acq_ep_q <= load_ep_index;
                  phase_q <= Acquire;
                end else phase_q <= Idle;
              end
            endcase
          end
          Acquire:
          if (ep_request_ready[acq_ep_q]) begin
            if (acq_ep_q == '0) begin
            acquisition_q <= acquisition;
            acquisition_store_q <= operation_q == StoreOp;
            acquisition_sc_q <= atomic_q && atomic_sc_q;
            acquisition_read_q <= selected_read_q;
            reserved_wb_q <= wb_free_slot;
            done_q <= 1'b0;
            written_q <= 1'b0;
            done_status_q <= coherence_pkg::Consumed;
            end
            if (operation_q == StoreOp && !pending_reported_q) begin
              pending_reported_q <= 1'b1;
              o_write_done <= 1'b1;
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
                if (grant_ep_q != '0) begin
                  rd_data_q[ld_read_q[grant_ep_q]] <=
                      grant_q.data[64*rd_addr_q[ld_read_q[grant_ep_q]][4:3]+:64];
                end else if (acquisition_store_q) begin
                  pending_q <= 1'b0;
                  done_q <= 1'b1;
                  written_q <= 1'b1;
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
                pending_q <= 1'b0;
                if (!pending_reported_q) o_write_done <= 1'b1;
                phase_q <= Idle;
              end
              AtomicWriteOp: begin
                atomic_write_q <= 1'b0;
                atomic_written_q <= 1'b1;
                o_write_done <= 1'b1;
                o_sc_write_done <= atomic_sc_q;
                done_q <= 1'b1;
                written_q <= 1'b1;
                phase_q <= Idle;
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
  always_ff @(posedge i_clk) begin
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
    if (active) begin
      case (phase_q)
        Idle: begin
          if (probe_valid_q && !o_r_valid) begin
          end else
          if (probe_priority || probe_valid_q) begin
          end else
          if (i_sc_valid && o_sc_ready) begin
          end else if (grant_valid) begin
            if ((grant.error || grant.opcode == coherence_pkg::GrantFail) &&
                (grant_pick != '0 || (!acquisition_sc_q && !acquisition_store_q))) begin
              reference_ready_next[failure_read_slot] = 1'b1;
              reference_error_next[failure_read_slot] = grant.error;
            end
          end
        end
        LookupWait:
        if (array_valid) begin
          case (operation_q)
            ProbeOp, GrantOp, StoreOp, AtomicWriteOp, MaintOp: begin
            end
            default: begin
              if (rd_kind_q[selected_read_q] != ReadAMO && array_hit)
                reference_ready_next[selected_read_q] = 1'b1;
              else if (!(Multi && rd_kind_q[selected_read_q] != ReadAMO && same_line))
                reference_miss_next[selected_read_q] = 1'b1;
            end
          endcase
        end
        UpdateWait:
        if (array_ready && operation_q == GrantOp &&
            (grant_ep_q != '0 || (!acquisition_store_q && !acquisition_sc_q)))
          reference_ready_next[fill_read_slot] = 1'b1;
        default: begin
        end
      endcase
    end
    p_read_status_exact :
    assert ({rd_valid_next, rd_miss_next, rd_ready_next, rd_error_next} ==
        {reference_valid_next, reference_miss_next, reference_ready_next, reference_error_next});
  end
  logic store_launch_ready_q;
  always_ff @(posedge i_clk) begin
    store_launch_ready_q <= !i_rst && o_store_ready;
  end
  always_ff @(posedge i_clk) begin
    if (sim_reset_seen_q && !i_rst) begin
      if (i_read_valid) assert (!rd_valid_q[i_read_id]);
      if (|i_write_mask) begin
        if (i_write_atomic) begin
          assert (atomic_q && atomic_granted_q && !atomic_written_q && !atomic_write_q);
          assert (i_address == atomic_addr_q && i_write_sc == atomic_sc_q);
          assert (i_write_tag == atomic_tag_q);
          if (i_write_sc) assert (sc_committed_q);
        end else begin
          assert (active && !pending_q && !atomic_q);
          assert (o_store_ready || store_launch_ready_q);
        end
      end
      if (o_d_valid[0] && (acquisition_q.opcode == coherence_pkg::Atomic ||
          acquisition_q.opcode == coherence_pkg::StoreConditional))
        assert (i_atomic_protected);
      if (ep_request_valid[0]) assert (wb_free);
      if (grant_valid && grant_ready) assert (live[grant_pick]);
      if (i_p_valid && o_p_ready && probe_in.opcode == coherence_pkg::ProbeRead &&
          atomic_q && atomic_sc_q && sc_checked_q && probe_in.addr == acquisition_q.addr)
        assert (probe_in.tid == sc_tid_q);
      if (o_c_valid[0] && acquisition_q.opcode == coherence_pkg::StoreConditional && written_q)
        assert (atomic_written_q);
    end
  end
`endif
`ifdef FORMAL
  logic   f_past_valid = 1'b0;
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
      end
      if (|i_write_mask) begin
        if (i_write_atomic) begin
          assume (atomic_q && atomic_granted_q && !atomic_written_q && !atomic_write_q);
          assume (i_address == atomic_addr_q && i_write_sc == atomic_sc_q);
          assume (i_write_tag == atomic_tag_q);
          if (i_write_sc) assume (sc_committed_q);
        end else begin
          assume (active && !pending_q && !atomic_q);
          assume (o_store_ready || store_launch_ready_q);
        end
      end
      if (i_sc_commit) assume (atomic_q && atomic_sc_q && atomic_granted_q);
      if (atomic_q || (request_live && acquisition_q.opcode == coherence_pkg::Atomic))
        assume (i_atomic_protected);
      if (i_p_valid) begin
        assume (probe_in.addr[4:0] == 0 && probe_in.epoch == 0 && probe_in.opcode <=
            coherence_pkg::CheckSC);
        assume (!(atomic_q && atomic_granted_q && probe_in.addr == acquisition_q.addr));
        if (probe_in.opcode == coherence_pkg::ProbeRead && atomic_q && atomic_sc_q &&
            sc_checked_q &&
            probe_in.addr == acquisition_q.addr)
          assume (probe_in.tid == sc_tid_q);
      end
      // Load endpoints request GetS only.
      for (int ep = 1; ep < MISSES; ep++)
      if (i_g_valid && ep_g_ready[ep] && !f_grant.error)
        assume (f_grant.opcode == coherence_pkg::GrantS);
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
      if (active) assert (f_probe_age < 32);
      if (local_turn_q) assert (phase_q == Idle && !probe_valid_q && !o_r_valid);
      if ($past(o_r_valid && i_r_ready)) assert (local_turn_q == $past(local_ready));
      if ($past(local_turn_q)) assert (!local_turn_q);
      if (local_turn_q && grant_valid && active) assert (grant_ready);
      if (rd_candidate && &read_probe_count_q) assert (local_ready);
      if ($past(local_turn_q && active && !grant_valid && atomic_write_q))
        assert (phase_q == Lookup && operation_q == AtomicWriteOp);
      if ($past(active && o_r_valid && !i_r_ready) && active) begin
        assert (o_r_valid);
        assert (f_reply_signature == $past(f_reply_signature));
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
        assert (atomic_written_q && sc_committed_q);
        assert ($past(phase_q == UpdateWait && array_ready && operation_q == AtomicWriteOp));
      end
      if (o_sc_write_pending) assert (atomic_q && atomic_sc_q && !atomic_written_q);
      if (pending_q && pending_reported_q) assert (o_block_valid[0]);
      if ($past(active && grant_valid && grant_ready)) assert (operation_q == GrantOp);
      if ($past(active && phase_q == Idle) && phase_q == Lookup && operation_q == GrantOp)
        assert ($past(grant_valid && grant_ready));
      if (active && phase_q == LookupWait && array_valid && operation_q == GrantOp)
        assert (array_available);
      if (o_r_valid && probe_q.opcode == coherence_pkg::ProbeInvalidate)
        assert (reply_q.state == coherence_pkg::Invalid);
      cover (o_cut_release);
      cover (o_sc_write_done);
    end
  end
`endif
endmodule
