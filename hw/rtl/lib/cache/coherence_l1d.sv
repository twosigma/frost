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

// Eight unmerged CPU reads share one acquisition endpoint. A committed store
// owns its bytes separately from the read queue and from dirty probe replies.
module coherence_l1d #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned CACHE_BYTES = 128 * 1024,
    parameter int unsigned WAYS = 4,
    parameter int unsigned TAG_BITS = 7,
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
    output logic [ADDR_WIDTH-1:0] o_cut_address,
    output logic o_cut_inval_valid,
    input logic i_cut_inval_done,
    output logic o_cut_release,
    output logic o_d_valid,
    input logic i_d_ready,
    output logic [ADDR_WIDTH+311:0] o_d,
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
    output logic o_c_valid,
    output logic o_c_selected,
    input logic i_c_ready,
    output logic [ADDR_WIDTH+17:0] o_c,
    input logic i_u_valid,
    output logic o_u_ready,
    input logic [ADDR_WIDTH+14:0] i_u,
    output logic o_fatal,
    output logic [ADDR_WIDTH-1:0] o_fatal_addr
);
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
    CutAdmit,
    CutInvalidate,
    CutWait
  } phase_t;
  typedef enum logic [2:0] {
    ReadOp,
    StoreOp,
    GrantOp,
    ProbeOp,
    MaintOp,
    AtomicWriteOp
  } operation_t;
  phase_t phase_q;
  operation_t operation_q;
  logic active;
  logic [7:0] rd_valid_q, rd_ready_q, rd_miss_q;
  logic [ADDR_WIDTH-1:0] rd_addr_q[8];
  logic [1:0] rd_kind_q[8];
  logic [2:0] rd_size_q[8];
  logic [TAG_BITS-1:0] rd_tag_q[8];
  localparam int unsigned ReadPayloadWidth = ADDR_WIDTH + TAG_BITS + 5;
  logic [8*ReadPayloadWidth-1:0] rd_payload_flat;
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
  logic probe_valid_q, probe_absorbed_q, probe_put_q;
  coh_p_t probe_in, probe_q;
  coh_r_t  reply_q;
  coh_wa_t ack;
  logic [1:0] wb_live, wb_valid, wb_ready, wb_freeze_ready, wb_absorb_ready;
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
  logic request_ready, request_live, request_valid;
  coh_d_t acquisition_q, acquisition;
  logic acquisition_store_q, acquisition_sc_q;
  logic [2:0] acquisition_read_q;
  logic grant_valid, grant_ready;
  coh_g_t grant, grant_q;
  logic done_q, done_ready, written_q;
  logic [1:0] done_status_q;
  logic pending_blocked;

  assign read_failure = active && phase_q == Idle &&
      !(probe_valid_q && !o_r_valid) && !i_p_valid &&
      grant_valid && (grant.error || grant.opcode == coherence_pkg::GrantFail) &&
      !acquisition_sc_q && !acquisition_store_q;
  assign read_hit = active && phase_q == LookupWait && array_valid &&
      operation_q != ProbeOp && operation_q != GrantOp && operation_q != StoreOp &&
      operation_q != AtomicWriteOp && operation_q != MaintOp &&
      rd_kind_q[selected_read_q] != ReadAMO && array_hit;
  assign read_miss = active && phase_q == LookupWait && array_valid &&
      operation_q != ProbeOp && operation_q != GrantOp && operation_q != StoreOp &&
      operation_q != AtomicWriteOp && operation_q != MaintOp &&
      (rd_kind_q[selected_read_q] == ReadAMO || !array_hit);
  assign read_fill = active && phase_q == UpdateWait && array_ready &&
      operation_q == GrantOp && !acquisition_store_q && !acquisition_sc_q;

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
      .i_acquisition_id(acquisition_read_q),
      .i_failure_error(grant.error),
      .i_hit_valid(read_hit),
      .i_hit_id(selected_read_q),
      .i_fill_valid(read_fill),
      .i_miss_valid(read_miss),
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
      .o_payload(rd_payload_flat)
  );
  for (genvar slot = 0; slot < 8; slot++) begin : gen_unpack_read_payload
    assign {rd_addr_q[slot], rd_kind_q[slot], rd_size_q[slot], rd_tag_q[slot]} =
        rd_payload_flat[slot*ReadPayloadWidth+:ReadPayloadWidth];
  end

  assign active = !i_rst && !i_fatal_stop && !o_fatal;
  assign probe_in = i_p;
  assign ack = i_wa;
  assign maint_eligible = maint_q && !pending_q && !atomic_q && !request_live && wb_free;
  assign o_pending_store = pending_q;
  assign o_atomic_live = atomic_q;
  assign o_sc_write_pending = atomic_q && atomic_sc_q && atomic_granted_q && !atomic_written_q;
  // SQ launch readiness precedes its registered write by one cycle.
  assign o_store_ready = active && !pending_q && !atomic_q && !maint_q && !i_maint_valid;
  assign o_write_inflight = (pending_q && !pending_reported_q) || atomic_write_q;
  assign o_block_valid = {atomic_q, pending_q};
  assign o_block_addr = {atomic_addr_q, pending_addr_q};
  assign o_sc_ready = active && !atomic_q && !pending_q && !request_live &&
      !o_sc_result_valid && i_atomic_protected && phase_q == Idle && wb_free &&
      !probe_valid_q && !i_p_valid;
  assign o_sc_write_tag = atomic_tag_q;
  assign o_p_ready = active && phase_q == Idle && !probe_valid_q && !o_r_valid;
  (* keep = "true" *) wire invalidate_eligible = !i_fatal_stop && !o_fatal &&
      phase_q == Idle && !probe_valid_q && !o_r_valid &&
      probe_in.opcode == coherence_pkg::ProbeInvalidate;
  assign o_cut_hold = (i_p_valid && !i_rst && invalidate_eligible) ||
      (probe_valid_q && probe_q.opcode == coherence_pkg::ProbeInvalidate && phase_q != ProbeReply);
`ifndef SYNTHESIS
`ifdef FORMAL
  always_comb begin
`else
  always @(posedge i_clk) begin
`endif
    p_cut_hold_exact : assert (o_cut_hold ==
        ((i_p_valid && o_p_ready && probe_in.opcode == coherence_pkg::ProbeInvalidate) ||
         (probe_valid_q && probe_q.opcode == coherence_pkg::ProbeInvalidate &&
          phase_q != ProbeReply)));
  end
`endif
  assign o_cut_address = probe_q.addr;
  assign o_cut_admit_valid = active && phase_q == CutAdmit;
  assign o_cut_inval_valid = active && phase_q == CutInvalidate;
  assign o_r = reply_q;
  assign grant_ready = active && phase_q == Idle && !probe_valid_q && !i_p_valid;
  assign request_valid = active && phase_q == Acquire;

  coherence_request_endpoint #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .SOURCE(0),
      .PORT_CLASS(0),
      .SLOT(0)
  ) request (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_epoch(1'b0),
      .i_request_valid(request_valid),
      .o_request_ready(request_ready),
      .i_request(acquisition),
      .o_d_valid(o_d_valid),
      .i_d_ready(i_d_ready),
      .o_d(o_d),
      .i_g_valid(i_g_valid),
      .o_g_ready(o_g_ready),
      .i_g(i_g),
      .o_grant_valid(grant_valid),
      .i_grant_ready(grant_ready),
      .o_grant(grant),
      .i_done_valid(done_q),
      .o_done_ready(done_ready),
      .i_done_status(done_status_q),
      .i_write_done(written_q),
      .i_error_disposed(done_status_q == coherence_pkg::Error),
      .o_c_valid(o_c_valid),
      .o_c_selected(o_c_selected),
      .i_c_ready(i_c_ready),
      .o_c(o_c),
      .i_u_valid(i_u_valid),
      .o_u_ready(o_u_ready),
      .i_u(i_u),
      .o_live(request_live)
  );

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

  logic [8*ADDR_WIDTH-1:0] rd_addr_flat;
  logic [15:0] rd_kind_flat;
  logic [ADDR_WIDTH-1:0] rd_selected_addr;
  for (genvar read_slot = 0; read_slot < 8; read_slot++) begin : gen_read_payload
    assign rd_addr_flat[read_slot*ADDR_WIDTH+:ADDR_WIDTH] = rd_addr_q[read_slot];
    assign rd_kind_flat[read_slot*2+:2] = rd_kind_q[read_slot];
  end
  coherence_read_select #(
      .ADDR_WIDTH(ADDR_WIDTH)
  ) read_select (
      .i_clk(i_clk),
      .i_valid(rd_valid_q),
      .i_ready(rd_ready_q),
      .i_miss(rd_miss_q),
      .i_kind(rd_kind_flat),
      .i_addr(rd_addr_flat),
      .i_round_robin(rd_rr_q),
      .i_pending(pending_q),
      .i_pending_addr(pending_addr_q),
      .i_atomic(atomic_q),
      .i_atomic_addr(atomic_addr_q),
      .i_wb_live(wb_live),
      .i_wb_addr(wb_addr),
      .i_atomic_protected(i_atomic_protected),
      .i_request_live(request_live),
      .i_acquisition_store(acquisition_store_q),
      .i_acquisition_sc(acquisition_sc_q),
      .i_acquisition_read(acquisition_read_q),
      .i_wb_free(wb_free),
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
      if (!wb_live[slot] && !(request_live && reserved_wb_q == 1'(slot))) begin
        wb_free = 1'b1;
        wb_free_slot = 1'(slot);
      end
      if (wb_live[slot] && wb_addr[slot] == probe_q.addr) begin
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
    if (atomic_q && atomic_granted_q && lookup_addr_q[5+:SetBits] == atomic_addr_q[5+:SetBits])
      exclude[atomic_way_q] = 1'b1;
    acquisition = '0;
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
      .i_req_valid(active && phase_q == Lookup),
      .o_req_ready(array_ready),
      .i_req_addr(lookup_addr_q),
      .i_req_exclude(exclude),
      .i_req_visit(operation_q == MaintOp && !maint_line_q),
      .i_req_way(maint_way_q),
      .o_resp_valid(array_valid),
      .i_resp_ready(phase_q == LookupWait),
      .o_resp_hit(array_hit),
      .o_resp_available(array_available),
      .o_resp_way(array_way),
      .o_resp_addr(array_addr),
      .o_resp_state(array_state),
      .o_resp_data(array_data),
      .i_update_valid(active && phase_q == Update),
      .o_update_ready(update_ready),
      .i_update_addr(update_addr_q),
      .i_update_way(way_q),
      .i_update_state(state_q),
      .i_update_insert(operation_q == GrantOp),
      .i_update_mask('1),
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
      if (i_u_valid && o_u_ready && atomic_q) begin
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
      if (o_r_valid && i_r_ready) begin
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
            if (probe_valid_q && !o_r_valid) begin
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
              end else if (probe_q.opcode == coherence_pkg::ProbeInvalidate) phase_q <= CutAdmit;
              else phase_q <= Lookup;
            end else if (i_p_valid) begin
              // Probe capture owns this arbitration edge.
            end else if (grant_valid) begin
              grant_q <= grant;
              operation_q <= GrantOp;
              lookup_addr_q <= acquisition_q.addr;
              if (grant.error || grant.opcode == coherence_pkg::GrantFail) begin
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
              phase_q <= Acquire;
            end else if (pending_q && !pending_blocked &&
                (!pending_miss_q || (!request_live && wb_free)) &&
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
          CutAdmit: if (i_cut_admit_ready) phase_q <= CutInvalidate;
          CutInvalidate: if (i_cut_inval_done) phase_q <= CutWait;
          CutWait: phase_q <= Lookup;
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
                if (array_hit) begin
                  state_q <= probe_q.opcode == coherence_pkg::ProbeInvalidate ?
                      coherence_pkg::Invalid : coherence_pkg::Shared;
                  phase_q <= Update;
                end else phase_q <= probe_absorbed_q ? ProbeAbsorb : ProbeReply;
              end
              GrantOp: begin
                if (array_available) begin
                  update_addr_q <= acquisition_q.addr;
                  image_q <= grant_q.data;
                  state_q <= grant_q.opcode == coherence_pkg::GrantM ?
                      coherence_pkg::Modified : coherence_pkg::Shared;
                  if (acquisition_store_q) begin
                    for (int index = 0; index < 32; index++)
                    if (pending_mask_q[index]) image_q[8*index+:8] <= pending_data_q[8*index+:8];
                  end
                  if (!array_hit && array_state == coherence_pkg::Modified) begin
                    freeze_slot_q <= reserved_wb_q;
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
                  phase_q <= !request_live && wb_free ? Acquire : Idle;
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
                  if (!request_live && !atomic_q && wb_free && i_atomic_protected) begin
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
                end else begin
                  phase_q <= !request_live && wb_free ? Acquire : Idle;
                end
              end
            endcase
          end
          Acquire:
          if (request_ready) begin
            acquisition_q <= acquisition;
            acquisition_store_q <= operation_q == StoreOp;
            acquisition_sc_q <= atomic_q && atomic_sc_q;
            acquisition_read_q <= selected_read_q;
            reserved_wb_q <= wb_free_slot;
            done_q <= 1'b0;
            written_q <= 1'b0;
            done_status_q <= coherence_pkg::Consumed;
            if (operation_q == StoreOp && !pending_reported_q) begin
              pending_reported_q <= 1'b1;
              o_write_done <= 1'b1;
            end
            phase_q <= Idle;
          end
          Freeze: if (wb_freeze_ready[freeze_slot_q]) phase_q <= Update;
          Update: if (update_ready) phase_q <= UpdateWait;
          UpdateWait:
          if (array_ready) begin
            case (operation_q)
              ProbeOp: phase_q <= probe_absorbed_q ? ProbeAbsorb : ProbeReply;
              GrantOp: begin
                if (acquisition_store_q) begin
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
          ProbeAbsorb: if (wb_absorb_ready[probe_put_q]) phase_q <= ProbeReply;
          ProbeReply: begin
            o_r_valid <= 1'b1;
            phase_q   <= Idle;
          end
          default: phase_q <= Idle;
        endcase
      end
    end
  end
`ifndef SYNTHESIS
  logic [7:0] reference_ready_next, reference_error_next, reference_valid_next, reference_miss_next;
  always_ff @(posedge i_clk) begin
    p_grant_live : assert (!grant_valid || request_live);
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
          if (i_p_valid) begin
          end else
          if (i_sc_valid && o_sc_ready) begin
          end else if (grant_valid) begin
            if (grant.error || grant.opcode == coherence_pkg::GrantFail) begin
              if (acquisition_sc_q) begin
              end else if (!acquisition_store_q) begin
                reference_ready_next[acquisition_read_q] = 1'b1;
                reference_error_next[acquisition_read_q] = grant.error;
              end
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
              else reference_miss_next[selected_read_q] = 1'b1;
            end
          endcase
        end
        UpdateWait:
        if (array_ready && operation_q == GrantOp) begin
          if (acquisition_store_q) begin
          end else
          if (acquisition_sc_q) begin
          end else reference_ready_next[acquisition_read_q] = 1'b1;
        end
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
    if (!i_rst) begin
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
      if (o_d_valid && (acquisition_q.opcode == coherence_pkg::Atomic ||
          acquisition_q.opcode == coherence_pkg::StoreConditional))
        assert (i_atomic_protected);
      if (request_valid) assert (wb_free);
      if (grant_valid && grant_ready) assert (request_live);
      if (i_p_valid && o_p_ready && probe_in.opcode == coherence_pkg::ProbeRead &&
          atomic_q && atomic_sc_q && sc_checked_q && probe_in.addr == acquisition_q.addr)
        assert (probe_in.tid == sc_tid_q);
      if (o_c_valid && acquisition_q.opcode == coherence_pkg::StoreConditional && written_q)
        assert (atomic_written_q);
    end
  end
`endif
`ifdef FORMAL
  logic   f_past_valid = 1'b0;
  coh_g_t f_grant;
  assign f_grant = i_g;
  logic [5:0] f_probe_age;
  wire [ADDR_WIDTH+19:0] f_reply_signature = {
    reply_q.opcode,
    reply_q.tid,
    reply_q.addr,
    reply_q.state,
    reply_q.absorbed,
    reply_q.put_id,
    reply_q.data[7:0]
  };
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (!active || !probe_valid_q || o_r_valid) f_probe_age <= '0;
    else f_probe_age <= f_probe_age + 1'b1;
    if (!i_rst) begin
      assume (i_cut_admit_ready && i_cut_inval_done);
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
      if (i_g_valid && o_g_ready && !f_grant.error) begin
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
      if ($past(active && o_r_valid && !i_r_ready) && active) begin
        assert (o_r_valid);
        assert (f_reply_signature == $past(f_reply_signature));
      end
      if (o_cut_admit_valid || o_cut_inval_valid)
        assert (probe_valid_q && probe_q.opcode == coherence_pkg::ProbeInvalidate);
      if (o_cut_release)
        assert ($past(o_r_valid && i_r_ready && probe_q.opcode == coherence_pkg::ProbeInvalidate));
      if (o_sc_write_done) begin
        assert (atomic_written_q && sc_committed_q);
        assert ($past(phase_q == UpdateWait && array_ready && operation_q == AtomicWriteOp));
      end
      if (o_sc_write_pending) assert (atomic_q && atomic_sc_q && !atomic_written_q);
      if (pending_q && pending_reported_q) assert (o_block_valid[0]);
      if ($past(active && grant_valid && grant_ready)) assert (operation_q == GrantOp);
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
