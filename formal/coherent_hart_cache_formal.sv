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

module coherent_hart_cache_formal #(
    parameter bit COVER_MODE = 0
) (
    input logic i_clk
);
  localparam int unsigned AddrWidth = riscv_pkg::PhysAddrBits;
  `FROST_COHERENCE_TYPES(AddrWidth)
  logic past_valid = 0;
  wire  rst = !past_valid;
  always_ff @(posedge i_clk) past_valid <= 1;
  (* anyseq *) logic start_store, request_fence, imem_done, fetch, walk, discard;
  (* anyseq *) logic permit_lookup, permit_data, permit_update, permit_g, permit_c, permit_u;
  (* anyseq *) logic read_error;
  // The two RSW bits distinguish the installed PTE from its stale home copy.
  // The service-engine target proves the merge independently for every byte.
  (* anyconst *) logic [1:0] stored_bits;
  // Cover schedules select acceptance/error discard, publication without a
  // fence, competing traffic, or a post-fence walk.
  (* anyconst *) logic [2:0] cover_scenario;
  logic [6:0] cover_cycle_q = 0;
  always_ff @(posedge i_clk) if (cover_cycle_q != 127) cover_cycle_q <= cover_cycle_q + 1;
  if (COVER_MODE) begin : gen_cover_schedule
    logic before_fetch_q = 0, after_fetch_q = 0, walked_q = 0;
    always_ff @(posedge i_clk) begin
      assume (stored_bits != 0);
      assume (cover_scenario <= 4);
      assume (start_store == (cover_cycle_q == 3));
      assume (request_fence == (cover_scenario != 2 && !fence_seen_q));
      assume (permit_lookup && permit_data && permit_update);
      assume (permit_g == cover_cycle_q[0]);
      assume (permit_c == cover_cycle_q[0]);
      assume (permit_u == cover_cycle_q[0]);
      assume (fetch == (!fence_sync && (!before_fetch_q ||
          (fence_seen_q && !after_fetch_q && cover_scenario != 4))));
      assume (walk == (!walked_q && !fence_sync && (cover_scenario == 0 ||
          fence_seen_q || (cover_scenario == 2 && store_sent_q && !pending))));
      assume (read_error == (cover_scenario == 1));
      assume (discard == ((cover_scenario == 0 && line_valid && line_ready) ||
          (cover_scenario == 1 && line_resp && line_error)));
      if (fetch && if_ready) begin
        before_fetch_q <= 1;
        if (fence_seen_q) after_fetch_q <= 1;
      end
      if (walk && walk_ready) walked_q <= 1;
    end
  end
  wire [63:0] stored_pte = 64'h200000cf | (64'(stored_bits) << 8);
  logic store_sent_q, fence_seen_q, fence_sync, fence_done, pending, store_ready;
  wire [7:0] store_mask = !rst && start_store && !store_sent_q && store_ready ? 8'hff : 0;
  assign fence_sync = request_fence && store_sent_q && !pending;
  logic if_ready, if_resp, if_error, if_after_q;
  logic [255:0] if_data;
  logic walk_ready, walk_resp, line_valid, line_ready, line_resp, line_error;
  logic [AddrWidth-1:0] line_addr;
  logic [2:0] line_id, response_id;
  logic [255:0] line_data;
  logic walk_after_q, poisoned_q, line_live_q;
  logic drain_pending_q;
  logic [1:0] drain_age_q;
  riscv_pkg::ptw_resp_t translation;
  logic [2:0] d_valid, d_ready, c_valid, c_ready, c_selected;
  logic [2:0] g_ready, u_ready;
  logic [2:0][AddrWidth+311:0] demands;
  logic [2:0][ AddrWidth+17:0] completions;
  logic home_d_valid, home_d_ready, home_c_valid, home_c_ready;
  coh_d_t demand;
  coh_c_t completion;
  coh_g_t grant;
  coh_u_t release_message;
  logic g_valid, u_valid;
  logic p_valid, p_ready, r_valid, r_ready, wa_valid, wa_ready;
  logic [AddrWidth+29:0] probe;
  coh_r_t reply;
  logic [AddrWidth+10:0] ack;
  logic put_valid, put_ready;
  logic [AddrWidth+259:0] put;
  coherent_hart_cache #(
      .ADDR_WIDTH(AddrWidth),
      .CACHE_BYTES(64),
      .WAYS(1),
      .L1D_MISSES(1),
      .L1I_CACHE_BYTES(64),
      .L1I_WAYS(1)
  ) dut (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_fatal_stop('0),
      .i_read_valid('0),
      .i_read_id('0),
      .i_read_kind('0),
      .i_read_size('0),
      .i_read_tag('0),
      .i_address(32'h80000000),
      .o_read_valid(),
      .i_read_ready(1'b1),
      .o_read_id(),
      .o_read_data(),
      .o_read_error(),
      .i_write_mask(store_mask),
      .i_write_data(stored_pte),
      .i_write_atomic('0),
      .i_write_sc('0),
      .i_write_tag('0),
      .o_write_done(),
      .o_write_inflight(),
      .o_store_ready(store_ready),
      .o_pending_store(pending),
      .o_sc_write_pending(),
      .o_atomic_live(),
      .o_block_valid(),
      .o_block_addr(),
      .i_atomic_protected('0),
      .i_sc_valid('0),
      .o_sc_ready(),
      .i_sc_address('0),
      .i_sc_size('0),
      .i_sc_tag('0),
      .i_sc_commit('0),
      .o_sc_result_valid(),
      .i_sc_result_ready(1'b1),
      .o_sc_success(),
      .o_sc_error(),
      .o_sc_write_done(),
      .o_sc_write_tag(),
      .i_reservation_valid('0),
      .i_reservation_addr('0),
      .i_reservation_size('0),
      .o_cut_hold(),
      .o_cut_admit_valid(),
      .i_cut_admit_ready(1'b1),
      .i_cut_admit_clean(1'b1),
      .o_cut_address(),
      .o_cut_inval_valid(),
      .i_cut_inval_done(1'b1),
      .o_cut_release(),
      .o_d_valid(d_valid[0]),
      .i_d_ready(d_ready[0]),
      .o_d(demands[0]),
      .i_p_valid(p_valid),
      .o_p_ready(p_ready),
      .i_p(probe),
      .o_r_valid(r_valid),
      .i_r_ready(r_ready),
      .o_r(reply),
      .o_w_valid(put_valid),
      .i_w_ready(put_ready),
      .o_w(put),
      .i_wa_valid(wa_valid),
      .o_wa_ready(wa_ready),
      .i_wa(ack),
      .i_g_valid(g_valid && grant.q[8:7] == 0),
      .o_g_ready(g_ready[0]),
      .i_g(grant),
      .o_c_valid(c_valid[0]),
      .i_c_ready(c_ready[0]),
      .o_c(completions[0]),
      .i_u_valid(u_valid && release_message.q[8:7] == 0),
      .o_u_ready(u_ready[0]),
      .i_u(release_message),
      .i_iup_req_valid(fetch),
      .o_iup_req_ready(if_ready),
      .i_iup_req_addr(32'h80000000),
      .i_iup_req_id('0),
      .o_iup_resp_valid(if_resp),
      .o_iup_resp_id(),
      .o_iup_resp_data(if_data),
      .o_iup_resp_error(if_error),
      .i_walk_req_valid(line_valid),
      .o_walk_req_ready(line_ready),
      .i_walk_req_addr(line_addr),
      .i_walk_req_id(line_id),
      .o_walk_resp_valid(line_resp),
      .o_walk_resp_id(response_id),
      .o_walk_resp_data(line_data),
      .o_walk_resp_error(line_error),
      .i_fence_sync(fence_sync),
      .i_imem_sync_done(imem_done),
      .o_fence_done(fence_done),
      .o_l1i_perf_events(),
      .o_l1d_perf_events(),
      .o_fatal(),
      .o_fatal_addr()
  );
  ptw #(
      .ENABLE_RESPONSE_ERRORS(1'b1),
      .WALK_ID_BITS(3)
  ) walker (
      .i_clk,
      .i_rst(rst),
      .i_root_ppn(44'h80000),
      .i_req_valid(walk),
      .o_req_ready(walk_ready),
      .i_req_vpn('0),
      .i_discard(discard),
      .o_resp_valid(walk_resp),
      .o_resp(translation),
      .o_line_req_valid(line_valid),
      .i_line_req_ready(line_ready),
      .o_line_req_addr(line_addr),
      .o_line_req_id(line_id),
      .i_line_resp_valid(line_resp),
      .i_line_resp_error(line_error),
      .i_line_resp_id(response_id),
      .i_line_resp_rdata(line_data)
  );
  for (genvar source = 1; source < 3; source++) begin : gen_dma
    (* anyseq *)logic request;
    logic requester_ready;
    if (COVER_MODE) begin : gen_cover_request
      logic sent_q = 0;
      always_ff @(posedge i_clk) begin
        assume (request == (cover_scenario == 3 && !sent_q));
        if (request && requester_ready) sent_q <= 1;
      end
    end
    coherence_line_bridge #(
        .ADDR_WIDTH(AddrWidth),
        .SOURCE(2),
        .PORT_CLASS(3),
        .ID_BITS(4),
        .CLEAN(1'b0)
    ) bridge (
        .i_clk,
        .i_rst(rst),
        .i_fatal_stop(1'b0),
        .i_req_valid(request),
        .o_req_ready(requester_ready),
        .i_req_write(1'b0),
        .i_req_addr(AddrWidth'(32'h80000020)),
        .i_req_data('0),
        .i_req_mask('0),
        .i_req_id(4'(source)),
        .o_resp_valid(),
        .o_resp_id(),
        .o_resp_data(),
        .o_resp_error(),
        .o_clean_valid(),
        .o_clean_addr(),
        .i_clean_done(1'b0),
        .o_d_valid(d_valid[source]),
        .i_d_ready(d_ready[source]),
        .o_d(demands[source]),
        .i_g_valid(g_valid && grant.q[8:7] == 2 && grant.q[4:1] == 4'(source)),
        .o_g_ready(g_ready[source]),
        .i_g(grant),
        .o_c_valid(c_valid[source]),
        .o_c_selected(c_selected[source]),
        .i_c_ready(c_ready[source]),
        .o_c(completions[source]),
        .i_u_valid(u_valid && release_message.q[8:7] == 2 && release_message.q[4:1] == 4'(source)),
        .o_u_ready(u_ready[source]),
        .i_u(release_message)
    );
  end
  coherence_d_arbiter #(
      .WIDTH(AddrWidth + 312),
      .PORTS(3)
  ) demand_arbiter (
      .i_clk,
      .i_rst(rst),
      .i_valid(d_valid),
      .o_ready(d_ready),
      .i_payload(demands),
      .o_valid(home_d_valid),
      .o_offer(),
      .o_selected(),
      .i_ready(home_d_ready),
      .o_payload(demand)
  );
  coherence_d_arbiter #(
      .WIDTH(AddrWidth + 18),
      .PORTS(3),
      .HOLD_VALID(1)
  ) complete_arbiter (
      .i_clk,
      .i_rst(rst),
      .i_valid(c_valid),
      .o_ready(c_ready),
      .i_payload(completions),
      .o_valid(home_c_valid),
      .o_offer(),
      .o_selected(),
      .i_ready(home_c_ready),
      .o_payload(completion)
  );

  // The home keeps one transaction through U. Its real service engine probes
  // the private data image and merges dirty replies before producing G.
  logic home_live_q, grant_sent_q, complete_q, engine_idle;
  logic lookup, decision_q, read_valid, read_pending_q, update_valid, update_pending_q;
  logic result_valid, result_ready;
  wire updated = update_pending_q && permit_update;
  logic [AddrWidth-1:0] address;
  logic [255:0] home_data_q, read_data_q, update_data;
  logic [31:0] update_mask;
  coh_g_t result, grant_q;
  logic error_q, result_after_q;
  (* anyseq *) logic accept_put, finish_put;
  logic put_pending_q, put_ack_q, put_seen_q;
  coh_w_t pending_put_q;
  coh_wa_t put_ack;
  logic engine_wa_valid;
  logic [AddrWidth+10:0] engine_wa;
  assign put_ready = !rst && !home_live_q && engine_idle && !put_pending_q &&
      !put_ack_q && accept_put;
  always_comb begin
    put_ack = '0;
    put_ack.hart = pending_put_q.hart;
    put_ack.put_id = pending_put_q.put_id;
    put_ack.epoch = pending_put_q.epoch;
    put_ack.addr = pending_put_q.addr;
  end
  assign wa_valid = engine_wa_valid || put_ack_q;
  assign ack = put_ack_q ? put_ack : engine_wa;
  // Accepted PutM owns its sector until the home update and acknowledgement.
  assign home_d_ready = !rst && !home_live_q && engine_idle && !put_pending_q &&
      !put_ack_q && !(put_valid && put_ready);
  assign g_valid = !rst && result_valid && permit_g;
  assign grant = result;
  assign result_ready = permit_g && (|g_ready);
  assign home_c_ready = !rst && home_live_q && grant_sent_q && !complete_q && permit_c;
  assign u_valid = !rst && home_live_q && complete_q && permit_u;
  assign release_message = {grant_q.q, grant_q.tid, grant_q.addr};
  coherence_home_engine #(
      .ADDR_WIDTH(AddrWidth),
      .LINE_BYTES(32),
      .WAYS(1)
  ) home (
      .i_clk,
      .i_rst(rst),
      .i_stop(1'b0),
      .i_work_valid(home_d_valid && home_d_ready),
      .i_work(demand),
      .i_tid(6'd0),
      .i_work_error(read_error && demand.opcode == coherence_pkg::ReadOncePTW),
      .o_idle(engine_idle),
      .o_lookup_valid(lookup),
      .i_lookup_ready(permit_lookup),
      .o_addr(address),
      .o_tid(),
      .o_opcode(),
      .o_maintenance(),
      .i_decision_valid(decision_q),
      .i_decision_resident(1'b1),
      .i_decision_way(1'b0),
      .i_decision_state(coherence_pkg::Shared),
      .o_read_valid(read_valid),
      .o_read_offer(),
      .i_read_ready(!read_pending_q),
      .o_way(),
      .i_data_valid(read_pending_q && permit_data),
      .i_data(read_data_q),
      .o_p_valid(p_valid),
      .i_p_ready(p_ready),
      .o_p(probe),
      .i_r_valid(r_valid),
      .o_r_ready(r_ready),
      .i_r(reply),
      .o_wa_valid(engine_wa_valid),
      .i_wa_ready(wa_ready),
      .o_wa(engine_wa),
      .o_update_valid(update_valid),
      .i_update_ready(!update_pending_q),
      .o_update_mask(update_mask),
      .o_update_data(update_data),
      .i_updated(updated),
      .o_result_valid(result_valid),
      .i_result_ready(result_ready),
      .o_result(result),
      .o_image(),
      .o_fatal()
  );
  logic [1:0] competitors_q;
  logic delayed_g_q, delayed_c_q, delayed_u_q, absorbed_q;
  always_ff @(posedge i_clk) begin
    if (rst) begin
      store_sent_q <= 0;
      fence_seen_q <= 0;
      if_after_q <= 0;
      walk_after_q <= 0;
      poisoned_q <= 0;
      line_live_q <= 0;
      drain_pending_q <= 0;
      drain_age_q <= 0;
      home_live_q <= 0;
      grant_sent_q <= 0;
      complete_q <= 0;
      decision_q <= 0;
      read_pending_q <= 0;
      update_pending_q <= 0;
      home_data_q <= {4{64'h200000cf}};
      read_data_q <= 0;
      grant_q <= '0;
      error_q <= 0;
      result_after_q <= 0;
      put_pending_q <= 0;
      put_ack_q <= 0;
      put_seen_q <= 0;
      pending_put_q <= '0;
      competitors_q <= 0;
      delayed_g_q <= 0;
      delayed_c_q <= 0;
      delayed_u_q <= 0;
      absorbed_q <= 0;
    end else begin
      if (|store_mask) store_sent_q <= 1;
      if (fence_done) begin
        fence_seen_q <= 1;
        assert (store_sent_q && !pending);
      end
      if (fetch && if_ready) if_after_q <= fence_seen_q;
      if (if_resp && if_after_q && !if_error) assert (if_data[9:8] == stored_bits);
      if (line_valid && line_ready) begin
        line_live_q  <= 1;
        walk_after_q <= store_sent_q && !pending;
      end
      if (line_resp) begin
        assert (line_live_q);
        line_live_q <= 0;
        if (walk_after_q && !line_error) assert (line_data[9:8] == stored_bits);
      end
      if (walk && walk_ready) poisoned_q <= 0;
      if (discard) poisoned_q <= 1;
      if (poisoned_q || discard) assert (!walk_resp);
      if (poisoned_q && line_live_q) assert (!walk_ready);
      // A discarded response drains decode/response stages within three cycles.
      // A held discard masks ready; releasing it must expose the idle walker.
      if (line_resp && (poisoned_q || discard)) begin
        drain_pending_q <= 1;
        drain_age_q <= 0;
      end else if (drain_pending_q) begin
        if (walk_ready) drain_pending_q <= 0;
        if (drain_age_q != 3) drain_age_q <= drain_age_q + 1;
      end
      if (drain_pending_q && drain_age_q >= 2 && !discard) assert (walk_ready);
      cover (drain_pending_q && walk_ready);
      cover (discard && line_valid && line_ready);
      cover (discard && line_resp && line_error);
      cover (poisoned_q && line_resp);
      cover (line_resp && walk_after_q && !line_error && !fence_seen_q);
      cover (fence_seen_q && if_resp && if_after_q && !if_error);
      cover (fence_seen_q && line_resp && walk_after_q && !line_error && absorbed_q);
      cover (fence_done && &competitors_q && delayed_g_q && delayed_c_q && delayed_u_q);

      if (put_valid && put_ready) begin
        put_pending_q <= 1;
        pending_put_q <= put;
      end
      if (put_pending_q && finish_put) begin
        home_data_q <= pending_put_q.data;
        put_pending_q <= 0;
        put_ack_q <= 1;
        put_seen_q <= 1;
      end
      if (put_ack_q && wa_ready) put_ack_q <= 0;
      cover (put_pending_q && home_d_valid && demand.addr == pending_put_q.addr && !finish_put);
      cover (line_resp && walk_after_q && !line_error && put_seen_q);
      decision_q <= lookup && permit_lookup;
      if (read_valid && !read_pending_q) begin
        read_pending_q <= 1;
        read_data_q <= home_data_q;
      end
      if (read_pending_q && permit_data) read_pending_q <= 0;
      if (update_valid && !update_pending_q) begin
        update_pending_q <= 1;
        if (address == 32'h80000000) home_data_q <= update_data;
      end
      if (updated) update_pending_q <= 0;
      if (home_d_valid && home_d_ready) begin
        home_live_q <= 1;
        result_after_q <= fence_seen_q;
        error_q <= read_error && demand.opcode == coherence_pkg::ReadOncePTW;
        if (demand.q[8:7] == 2) competitors_q[demand.q[2:1]-1'b1] <= 1;
      end
      if (result_valid && result_after_q && !result.error && result.q[8:7] == 0 &&
          result.q[6:5] != 0)
        assert (result.data[9:8] == stored_bits);
      if (result_valid && result_ready) begin
        grant_sent_q <= 1;
        grant_q <= result;
      end
      if (home_c_valid && home_c_ready) begin
        assert (completion.q == grant_q.q && completion.addr == grant_q.addr);
        complete_q <= 1;
      end
      if (u_valid && (|u_ready)) begin
        home_live_q  <= 0;
        grant_sent_q <= 0;
        complete_q   <= 0;
      end
      if (result_valid && !permit_g) delayed_g_q <= 1;
      if (home_c_valid && !permit_c) delayed_c_q <= 1;
      if (complete_q && !permit_u) delayed_u_q <= 1;
      if (r_valid && r_ready && reply.absorbed) absorbed_q <= 1;
    end
  end
endmodule
