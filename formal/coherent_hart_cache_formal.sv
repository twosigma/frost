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
`ifdef COH_MAINT_OWNED
  logic f_seq_ever_pop, f_seq_final;
  logic [2:0] f_seq_pushed, f_seq_popped;
  logic f_if_swept;
  logic [2:0] f_walk_state;
  logic [riscv_pkg::Sv39VpnBits-1:0] f_walk_vpn;
  logic f_walk_error, f_walk_poison;
  // Observation ports and helper state never drive functional inputs.
  // p_maint_fact_* labels select original checks for the induction task.
  logic [8+8+7+3*64-1:0] f_maint_view;
  logic [3:0][AddrWidth+2:0] f_if_read_requests;
  logic [4:0] f_maint_home_state;
`endif
  logic past_valid = 0;
  wire  rst = !past_valid;
  always_ff @(posedge i_clk) past_valid <= 1;
  logic start_store, request_fence, imem_done, fetch, walk, discard;
  logic permit_lookup, permit_data, permit_update, permit_g, permit_c, permit_u;
  logic read_error;
  logic store_sent_q, fence_seen_q, fence_sync, fence_done, pending, store_ready;
`ifdef COH_MAINT_FOUR
  logic [6:0] stores_launched_q;
`else
  logic [2:0] stores_launched_q;
`endif
  logic [3:0] store_holds;
  logic if_ready, if_resp, if_error;
  logic fetch_sector;
  logic walk_ready, walk_resp, line_valid, line_ready, line_resp, line_error;
  logic home_d_valid, home_d_ready, home_c_valid, home_c_ready;
  coh_d_t demand;
  coh_u_t release_message;
  logic put_valid, put_ready;
  logic accept_put, finish_put;
  logic put_pending_q, put_ack_q, put_seen_q;
  coh_w_t pending_put_q;
  logic [1:0] if_owned, if_ungranted, if_tail;
  // The two RSW bits distinguish the installed PTE from its stale home copy.
  // The service-engine target proves the merge independently for every byte.
  (* anyconst *)logic [1:0] arbitrary_stored_bits;
  wire  [1:0] stored_bits = COVER_MODE ? 2'd1 : arbitrary_stored_bits;
  (* anyconst *) logic stored_global, two_stores, four_stores;
`ifdef COH_MAINT_FOUR
  wire [6:0] store_goal = 7'd67;
  logic four_records_seen_q = 0;
  always_ff @(posedge i_clk) if (!rst && &store_holds) four_records_seen_q <= 1;
`else
  wire [2:0] store_goal = four_stores ? 3'd4 : two_stores ? 3'd2 : 3'd1;
`endif
  // Cover schedules select acceptance/error discard, publication without a
  // fence, competing traffic, or a post-fence walk.
  (* anyconst *)logic [3:0] cover_scenario;
  logic [6:0] cover_cycle_q = 0;
  always_ff @(posedge i_clk) if (cover_cycle_q != 127) cover_cycle_q <= cover_cycle_q + 1;
  if (COVER_MODE) begin : gen_cover_schedule
    logic before_fetch_q = 0, after_fetch_q = 0, walked_q = 0;
    logic [2:0] fetch_count_q = 0, walk_count_q = 0;
    logic fetched_q = 0, put_demand_q = 0;
    always_comb begin
`ifdef COH_MAINT_FOUR
      assume (cover_scenario == 0);
      imem_done = 1;
      accept_put = 0;
      finish_put = 1;
      permit_lookup = 1;
      permit_data = 1;
      permit_update = 1;
      permit_c = 1;
      permit_g = 1;
      permit_u = 1;
      start_store = cover_cycle_q >= 3;
      request_fence = !fence_seen_q;
      fetch_sector = 0;
      fetch = fence_seen_q && !after_fetch_q;
      walk = fence_seen_q && !walked_q;
      read_error = 0;
      discard = 0;
`else
      imem_done = (cover_cycle_q > 60);
      accept_put = (cover_scenario == 4 || cover_scenario == 10);
      finish_put = (cover_cycle_q[0] && (cover_scenario != 4 || put_demand_q) &&
          (cover_scenario != 10 || cover_cycle_q > 48));
      assume (cover_scenario <= 11);
      permit_lookup = 1;
      permit_data = 1;
      permit_update = 1;
      permit_c = cover_cycle_q[0];
      permit_g = (cover_cycle_q[0] && (cover_scenario != 5 || cover_cycle_q > 48));
      if (cover_scenario <= 4) begin
        start_store = (cover_cycle_q == 3 || cover_cycle_q == 5 ||
            (four_stores && (cover_cycle_q == 7 || cover_cycle_q == 9)));
        request_fence = (cover_scenario != 2 && !fence_seen_q);
        permit_u = cover_cycle_q[0];
        fetch_sector = 0;
        fetch = (!fence_sync && (!before_fetch_q ||
            (fence_seen_q && !after_fetch_q && cover_scenario != 4)));
        walk = (!walked_q && !fence_sync && (cover_scenario == 0 ||
            fence_seen_q || (cover_scenario == 2 && store_sent_q && !pending)));
        read_error = (cover_scenario == 1);
        discard = ((cover_scenario == 0 && line_valid && line_ready) ||
            (cover_scenario == 1 && line_resp && line_error));
      end else begin
        start_store = ((cover_scenario == 6 || cover_scenario == 9) &&
            (cover_cycle_q == 3 || cover_cycle_q == 5 ||
            (four_stores && (cover_cycle_q == 7 || cover_cycle_q == 9)))) ||
            ((cover_scenario == 10 || cover_scenario == 11) &&
            (cover_cycle_q == 3 || (stores_launched_q == 1 && put_valid)));
        request_fence = ((cover_scenario == 6 && fetch_count_q == 2) ||
            (cover_scenario == 9 && fetch_count_q == 1) ||
            cover_scenario == 10 || cover_scenario == 11) && !fence_seen_q;
        fetch_sector = fetch_count_q[0];
        discard = 0;
        read_error = (cover_scenario == 8);
        if (cover_scenario == 5) begin
          fetch = (fetch_count_q < 2);
          walk = !walked_q;
          permit_u = cover_cycle_q[0];
        end else if (cover_scenario == 6) begin
          fetch = (store_sent_q && !pending && fetch_count_q < 2);
          walk = 0;
          permit_u = (release_message.q[6:5] == 0 || fence_seen_q);
        end else if (cover_scenario == 7) begin
          fetch = (fetch_count_q < 2 && (fetch_count_q == 0 || fetched_q));
          walk = 0;
          permit_u = (&if_owned);
        end else if (cover_scenario == 9) begin
          fetch_sector = 0;
          fetch = (store_sent_q && $countones(store_holds) == 1 && fetch_count_q == 0);
          walk = 0;
          permit_u = cover_cycle_q[0];
        end else if (cover_scenario == 10 || cover_scenario == 11) begin
          fetch_sector = 0;
          fetch = cover_scenario == 10 ?
              (fence_seen_q && fetch_count_q == 0) :
              ((fetch_count_q == 0 && store_sent_q && pending && put_valid &&
              cover_cycle_q > 40) || (fetch_count_q == 1 && fence_seen_q));
          walk = 0;
          permit_u = cover_cycle_q[0];
        end else begin
          fetch = 0;
          walk = (walk_count_q < 2);
          permit_u = (walk_count_q == 2);
        end
      end
`endif
    end
    always_ff @(posedge i_clk) begin
      if (put_pending_q && home_d_valid && demand.addr == pending_put_q.addr) put_demand_q <= 1;
      if (fetch && if_ready) begin
        before_fetch_q <= 1;
        if (fetch_count_q < 7) fetch_count_q <= fetch_count_q + 1;
        if (fence_seen_q) after_fetch_q <= 1;
      end
      if (if_resp) fetched_q <= 1;
      if (walk && walk_ready) begin
        walked_q <= 1;
        if (walk_count_q < 7) walk_count_q <= walk_count_q + 1;
      end
    end
  end else begin : gen_arbitrary_inputs
    (* anyseq *) logic [15:0] inputs;
    assign {start_store, request_fence, imem_done, fetch, walk, discard,
        permit_lookup, permit_data, permit_update, permit_g, permit_c, permit_u,
        read_error, fetch_sector, accept_put, finish_put} = inputs;
  end
  wire  [63:0] stored_pte = 64'h200000cf | (64'(stored_bits) << 8) | (64'(stored_global) << 5);
  wire  [63:0] first_pte = store_goal > 1 ? stored_pte ^ 64'h300 : stored_pte;
  logic [ 7:0] store_mask;
  logic [63:0] store_data_q;
  always_ff @(posedge i_clk) begin
    if (rst) begin
      stores_launched_q <= 0;
      store_mask <= 0;
      store_data_q <= 0;
    end else begin
      store_mask <= 0;
      if (start_store && stores_launched_q < store_goal && store_ready) begin
        stores_launched_q <= stores_launched_q + 1'b1;
        store_mask <= stores_launched_q == 0 ? 8'hff : 8'h02;
`ifdef COH_MAINT_FOUR
        store_data_q <= stores_launched_q == store_goal - 1'b1 ? stored_pte : stored_pte ^ 64'h300;
`else
        store_data_q <= (stores_launched_q == 0 && store_goal > 1) ?
            stored_pte ^ 64'h300 : stored_pte;
`endif
      end
    end
  end
  assign fence_sync = request_fence && store_sent_q && !pending && !(|store_mask);
  logic [1:0] if_after_q;
  logic [3:0] if_response_id;
  wire [AddrWidth-1:0] fetch_addr = 32'h80000000 | (AddrWidth'(fetch_sector) << 5);
  logic [255:0] if_data;
  logic [AddrWidth-1:0] line_addr;
  logic [2:0] line_id, response_id;
  logic [255:0] line_data;
  logic walk_after_q, poisoned_q, line_live_q;
  logic drain_pending_q;
  logic [1:0] drain_age_q;
  (* anyseq *) logic [17:0] arbitrary_walk_vpn;
  wire [17:0] walk_vpn_low = COVER_MODE ? 18'd1 : arbitrary_walk_vpn;
  wire [26:0] walk_vpn = {9'b0, walk_vpn_low};
  logic [26:0] accepted_vpn_q;
  logic expected_error_q, last_error_q;
  riscv_pkg::ptw_resp_t translation;
  logic [2:0] d_valid, d_ready, c_valid, c_ready;
  logic [2:0] g_ready, u_ready;
  logic [2:0][AddrWidth+311:0] demands;
  logic [2:0][AddrWidth+17:0] completions;
  coh_c_t completion;
  coh_g_t grant;
  logic g_valid, u_valid;
  logic p_valid, p_ready, r_valid, r_ready, wa_valid, wa_ready;
  logic [AddrWidth+29:0] probe;
  coh_r_t reply;
  logic [AddrWidth+10:0] ack;
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
      .i_write_data(store_data_q),
      .i_write_atomic('0),
      .i_write_sc('0),
      .i_write_zero(1'b0),
      .i_write_tag('0),
      .o_write_done(),
      .o_write_inflight(),
      .o_store_ready(store_ready),
      .o_twin_push(),
      .o_twin_push_addr(),
      .o_pending_store(pending),
      .o_sc_write_pending(),
      .o_atomic_live(),
      .o_block_valid(store_holds),
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
      .i_iup_req_addr(fetch_addr),
      .i_iup_req_id(4'(fetch_sector)),
      .o_iup_resp_valid(if_resp),
      .o_iup_resp_id(if_response_id),
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
`ifdef COH_MAINT_OWNED
      .i_maint_first(first_pte),
      .i_maint_final(stored_pte),
      .o_maint_view(f_maint_view),
      .o_maint_read_requests(f_if_read_requests),
      .o_maint_swept(f_if_swept),
`endif
      .o_fence_done(fence_done),
      .o_l1i_perf_events(),
      .o_l1d_perf_events(),
      .o_fatal(),
      .o_fatal_addr()
  );
  // The walk cache is left out: this harness checks the walker's line
  // traffic through the hart cache, and ptw.sby checks the walk cache.
  ptw #(
      .ENABLE_RESPONSE_ERRORS(1'b1),
      .WALK_ID_BITS(3),
      .PWC_L1_ENTRIES(0),
      .PWC_ROOT_ENTRIES(0)
  ) walker (
      .i_clk,
      .i_rst(rst),
      .i_root_ppn(44'h80000),
`ifdef COH_MAINT_OWNED
      .o_maint_state(f_walk_state),
      .o_maint_vpn(f_walk_vpn),
      .o_maint_error(f_walk_error),
      .o_maint_poison(f_walk_poison),
`endif
      .i_req_valid(walk),
      .o_req_ready(walk_ready),
      .i_req_vpn(walk_vpn),
      .i_discard(discard),
      .o_busy(),
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
    logic request;
    logic requester_ready;
    if (COVER_MODE) begin : gen_cover_request
      logic sent_q = 0;
      assign request = cover_scenario == 3 && !sent_q;
      always_ff @(posedge i_clk) if (request && requester_ready) sent_q <= 1;
    end else begin : gen_arbitrary_request
      (* anyseq *) logic offer;
      assign request = offer;
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
`ifdef COH_MAINT_OWNED
        .i_maint_final(stored_pte),
        .i_maint_final_seen(f_seq_final),
`endif
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
      .o_selected(),
      .i_ready(home_c_ready),
      .o_payload(completion)
  );
  // IF0 and IF1 have separate completion slots; other classes share a third.
  // Each identity survives through U. The service engine probes the private
  // data image and merges dirty replies before producing G.
  localparam int Slots = 3;
  typedef enum logic [2:0] {
    Free,
    Queued,
    Serving,
    Result,
    Granted,
    Completed
  } entry_state_t;
  logic [Slots-1:0][2:0] state_q;
  logic [Slots-1:0][AddrWidth+311:0] request_q;
  logic [Slots-1:0][AddrWidth+274:0] grant_q;
  logic [Slots-1:0][8:0] request_key, grant_key;
  logic [Slots-1:0][AddrWidth-1:0] request_address, grant_address;
  logic [Slots-1:0][5:0] grant_tid;
`ifdef COH_MAINT_OWNED
  logic [Slots-1:0][3:0] f_request_opcode;
  logic [Slots-1:0][255:0] f_grant_data;
  logic [Slots-1:0] f_grant_error;
`endif
  for (genvar n = 0; n < Slots; n++) begin : gen_entry
    coh_d_t saved_request;
    coh_g_t saved_grant;
    assign saved_request = request_q[n];
    assign saved_grant = grant_q[n];
    assign request_key[n] = saved_request.q;
    assign request_address[n] = saved_request.addr;
    assign grant_key[n] = saved_grant.q;
    assign grant_address[n] = saved_grant.addr;
    assign grant_tid[n] = saved_grant.tid;
`ifdef COH_MAINT_OWNED
    assign f_request_opcode[n] = saved_request.opcode;
    assign f_grant_data[n] = saved_grant.data;
    assign f_grant_error[n] = saved_grant.error;
`endif
  end
  logic [Slots-1:0][Slots-1:0] predecessors_q;
  logic [Slots-1:0] home_live_q, grant_sent_q, complete_q, after_q, error_q;
  logic home_published_q, home_prefix_q, probe_needs_fresh_q;
  logic store_put_complete_q, store_absorbed_q;
  logic engine_idle;
  logic [5:0] engine_tid;
  logic [1:0] service_slot, grant_slot, release_slot;
  logic [1:0] free_slot, completion_slot;
  logic free_valid, duplicate, completion_found, work_valid;
  coh_d_t work;
  logic [Slots-1:0] released;
  always_comb begin
    free_slot = demand.q == 9'h020 ? 2'd0 : demand.q == 9'h022 ? 2'd1 : 2'd2;
    free_valid = state_q[free_slot] == Free;
    duplicate = 0;
    completion_found = 0;
    completion_slot = 0;
    released = 0;
    for (int n = Slots - 1; n >= 0; n--) begin
      home_live_q[n]  = state_q[n] != Free;
      grant_sent_q[n] = state_q[n] == Granted || state_q[n] == Completed;
      complete_q[n]   = state_q[n] == Completed;
      if (state_q[n] != Free && request_key[n] == demand.q) duplicate = 1;
      if (grant_sent_q[n] && completion.q == grant_key[n] &&
          completion.tid == grant_tid[n] && completion.addr == grant_address[n]) begin
        completion_found = 1;
        completion_slot  = 2'(n);
      end
    end
    if (u_valid && (|u_ready)) released[release_slot] = 1;
  end
  if (COVER_MODE) begin : gen_home_schedule
    logic [1:0] next_work, next_grant, next_release;
    always_comb begin
      next_work = 0;
      next_grant = 0;
      next_release = 0;
      for (int n = 0; n < Slots; n++) begin
        if (state_q[n] == Queued && predecessors_q[n] == 0) next_work = 2'(n);
        if (state_q[n] == Result) next_grant = 2'(n);
        if (state_q[n] == Completed) next_release = 2'(n);
      end
      service_slot = next_work;
      grant_slot   = next_grant;
      release_slot = next_release;
    end
  end else begin : gen_arbitrary_schedule
    (* anyseq *) logic [5:0] choices;
    assign {service_slot, grant_slot, release_slot} = choices;
  end
  assign work_valid = !rst && service_slot < Slots && engine_idle &&
      state_q[service_slot] == Queued && predecessors_q[service_slot] == 0;
  logic lookup, decision_q, read_valid, read_pending_q, update_valid, update_pending_q;
  logic result_valid, result_ready;
  wire updated = update_pending_q && permit_update;
  logic [AddrWidth-1:0] address;
  logic [255:0] home_data_q, read_data_q, update_data;
  logic [31:0] update_mask;
  coh_g_t result, released_grant, completed_grant;
  always_comb begin
    work = '0;
    grant = '0;
    released_grant = '0;
    completed_grant = '0;
    for (int n = 0; n < Slots; n++) begin
      if (service_slot == 2'(n)) work = request_q[n];
      if (grant_slot == 2'(n)) grant = grant_q[n];
      if (release_slot == 2'(n)) released_grant = grant_q[n];
      if (completion_slot == 2'(n)) completed_grant = grant_q[n];
    end
  end
  coh_wa_t put_ack;
  logic engine_wa_valid;
  logic [AddrWidth+10:0] engine_wa;
  assign put_ready = !rst && !(|home_live_q) && engine_idle && !put_pending_q &&
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
  assign home_d_ready = !rst && free_valid && !duplicate && !put_pending_q &&
      !put_ack_q && !(put_valid && put_ready);
  assign g_valid = !rst && grant_slot < Slots && state_q[grant_slot] == Result && permit_g;
  assign result_ready = 1;
  assign home_c_ready = !rst && completion_found && state_q[completion_slot] == Granted && permit_c;
  assign u_valid = !rst && release_slot < Slots && state_q[release_slot] == Completed && permit_u;
  assign release_message = {released_grant.q, released_grant.tid, released_grant.addr};
  coherence_home_engine #(
      .ADDR_WIDTH(AddrWidth),
      .LINE_BYTES(32),
      .WAYS(1)
  ) home (
      .i_clk,
      .i_rst(rst),
      .i_stop(1'b0),
      .i_work_valid(work_valid),
      .i_work(work),
      .i_tid(6'(service_slot)),
      .i_work_error(error_q[service_slot]),
      .o_idle(engine_idle),
      .o_lookup_valid(lookup),
      .i_lookup_ready(permit_lookup),
      .o_addr(address),
      .o_tid(engine_tid),
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
`ifdef COH_MAINT_OWNED
      .o_maint_state(f_maint_home_state),
`endif
      .o_image(),
      .o_fatal()
  );
`ifdef COH_MAINT_OWNED
  // The ownership task proves these service-entry facts without assuming any
  // other assertions. The composition proof can then use them as invariants.
  logic f_maint_serving, f_maint_request, f_maint_tid, f_maint_grant;
  always_comb begin
    f_maint_serving = 1;
    f_maint_request = 1;
    f_maint_tid = 1;
    f_maint_grant = 1;
    for (int n = 0; n < Slots; n++) begin
      if (state_q[n] == Serving) begin
        if (engine_idle || engine_tid != 6'(n)) f_maint_serving = 0;
        if (result.q != request_key[n] || result.addr != request_address[n]) f_maint_request = 0;
      end
      if (state_q[n] == Result || state_q[n] == Granted || state_q[n] == Completed) begin
        if (grant_tid[n] != 6'(n)) f_maint_tid = 0;
        if (grant_key[n] != request_key[n] || grant_address[n] != request_address[n])
          f_maint_grant = 0;
      end
    end
  end
  always_ff @(posedge i_clk)
    if (!rst) begin
      if (!engine_idle)
        p_maint_owned_engine : assert (engine_tid < Slots && state_q[2'(engine_tid)] == Serving);
      p_maint_owned_serving : assert (f_maint_serving);
      p_maint_owned_request : assert (f_maint_request);
      p_maint_owned_tid : assert (f_maint_tid);
      p_maint_owned_grant : assert (f_maint_grant);
      if (result_valid && result_ready)
        p_maint_owned_result : assert (result.tid < Slots && state_q[2'(result.tid)] == Serving);
    end
`endif
  always_ff @(posedge i_clk)
    if (!rst) begin
      if (!engine_idle) assert (engine_tid < Slots && state_q[2'(engine_tid)] == Serving);
      for (int n = 0; n < Slots; n++)
      if (state_q[n] == Serving) begin
        assert (!engine_idle && engine_tid == 6'(n));
        assert (result.q == request_key[n] && result.addr == request_address[n]);
      end
      for (int n = 0; n < Slots; n++)
      if (state_q[n] == Result || state_q[n] == Granted || state_q[n] == Completed) begin
        assert (grant_tid[n] == 6'(n));
        assert (grant_key[n] == request_key[n] && grant_address[n] == request_address[n]);
      end
      if (result_valid && !result.error)
`ifdef COH_MAINT_OWNED
        p_maint_fact_result_shape :
        assert ((result.data & {4{result.addr[5] ? 64'hfffffffffffffcff : 64'hfffffffffffffcdf}}) ==
          (result.addr[5] ? {4{64'h200004cf}} : {4{64'h200000cf}}));
`else
        assert ((result.data & {4{result.addr[5] ? 64'hfffffffffffffcff : 64'hfffffffffffffcdf}}) ==
          (result.addr[5] ? {4{64'h200004cf}} : {4{64'h200000cf}}));
`endif
      if (g_valid && !grant.error)
`ifdef COH_MAINT_OWNED
        p_maint_fact_grant_shape :
        assert ((grant.data & {4{grant.addr[5] ? 64'hfffffffffffffcff : 64'hfffffffffffffcdf}}) ==
          (grant.addr[5] ? {4{64'h200004cf}} : {4{64'h200000cf}}));
`else
        assert ((grant.data & {4{grant.addr[5] ? 64'hfffffffffffffcff : 64'hfffffffffffffcdf}}) ==
          (grant.addr[5] ? {4{64'h200004cf}} : {4{64'h200000cf}}));
`endif
    end
  always_ff @(posedge i_clk) begin
    if (rst) begin
      home_published_q <= 0;
      home_prefix_q <= 0;
      probe_needs_fresh_q <= 0;
      store_put_complete_q <= 0;
      store_absorbed_q <= 0;
    end else begin
      if (pending && put_pending_q && finish_put) store_put_complete_q <= 1;
      if (pending && r_valid && r_ready && reply.absorbed) store_absorbed_q <= 1;
      if (update_valid && !update_pending_q && address == 32'h80000000) begin
        home_prefix_q <= 1;
        if (update_data == {4{stored_pte}}) home_published_q <= 1;
      end else if (put_pending_q && finish_put) begin
        home_prefix_q <= 1;
        if (pending_put_q.data == {4{stored_pte}}) home_published_q <= 1;
      end
      if (home_prefix_q)
`ifdef COH_MAINT_OWNED
        p_maint_fact_prefix :
        assert (home_data_q == {4{first_pte}} || home_data_q == {4{stored_pte}});
`else
        assert (home_data_q == {4{first_pte}} || home_data_q == {4{stored_pte}});
`endif
      if (home_published_q)
`ifdef COH_MAINT_OWNED
        p_maint_fact_published : assert (home_data_q == {4{stored_pte}});
`else
        assert (home_data_q == {4{stored_pte}});
`endif
      if (update_valid && address == 32'h80000000)
`ifdef COH_MAINT_OWNED
        p_maint_fact_update :
        assert (update_data == {4{first_pte}} || update_data == {4{stored_pte}});
`else
        assert (update_data == {4{first_pte}} || update_data == {4{stored_pte}});
`endif
      if (p_valid && p_ready)
        probe_needs_fresh_q <= address == 32'h80000000 &&
            store_sent_q && !pending && !home_published_q;
      if (r_valid && probe_needs_fresh_q) begin
`ifdef COH_MAINT_OWNED
        p_maint_fact_probe_valid : assert (reply.data_valid);
`else
        assert (reply.data_valid);
`endif
`ifdef COH_MAINT_OWNED
        p_maint_fact_probe_bits : assert (reply.data[9:8] == stored_bits);
`else
        assert (reply.data[9:8] == stored_bits);
`endif
      end
    end
  end
  logic [1:0] competitors_q;
  logic delayed_g_q, delayed_c_q, delayed_u_q, absorbed_q;
  logic ptw_owned, ptw_tail;
  always_comb begin
    if_owned = 0;
    if_ungranted = 0;
    if_tail = 0;
    ptw_owned = 0;
    ptw_tail = 0;
    for (int n = 0; n < Slots; n++) begin
      if (home_live_q[n] && request_key[n][8:5] == 1) begin
        if_owned[request_key[n][1]] = 1;
        if_ungranted[request_key[n][1]] = !grant_sent_q[n];
        if_tail[request_key[n][1]] = grant_sent_q[n];
      end
      if (home_live_q[n] && request_key[n][8:5] == 2) begin
        ptw_owned = 1;
        ptw_tail  = grant_sent_q[n];
      end
    end
  end
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
      for (int n = 0; n < Slots; n++) begin
        state_q[n] <= Free;
        request_q[n] <= '0;
        grant_q[n] <= '0;
        predecessors_q[n] <= 0;
      end
      after_q <= 0;
      decision_q <= 0;
      read_pending_q <= 0;
      update_pending_q <= 0;
      home_data_q <= {4{64'h200000cf}};
      read_data_q <= 0;
      error_q <= 0;
      put_pending_q <= 0;
      put_ack_q <= 0;
      put_seen_q <= 0;
      pending_put_q <= '0;
      competitors_q <= 0;
      delayed_g_q <= 0;
      delayed_c_q <= 0;
      delayed_u_q <= 0;
      absorbed_q <= 0;
      accepted_vpn_q <= 0;
      expected_error_q <= 0;
      last_error_q <= 0;
    end else begin
      if (|store_mask && stores_launched_q == store_goal) store_sent_q <= 1;
      if (fence_done) begin
        fence_seen_q <= 1;
        assert (store_sent_q && !pending && !(|store_mask));
`ifdef COH_MAINT_FOUR
        assert (four_records_seen_q && stores_launched_q == 67);
`endif
      end
`ifdef COH_MAINT_FOUR
      p_four_records_full : cover (&store_holds && !fence_seen_q);
      p_four_records_fence : cover (four_records_seen_q && fence_done);
      p_four_records_if :
      cover (four_records_seen_q && fence_seen_q && if_resp && if_after_q[0] && !if_error);
      p_four_records_walk :
      cover (four_records_seen_q && fence_seen_q &&
          walk_resp && translation.fault_kind == riscv_pkg::DFAULT_NONE);
`endif
      if (fetch && if_ready) if_after_q[fetch_sector] <= fence_seen_q;
      if (if_resp) assert (if_response_id < 2);
      if (if_resp && if_after_q[if_response_id[0]] && !if_error && !if_response_id[0]) begin
`ifdef COH_MAINT_OWNED
        p_maint_fact_if_bits : assert (if_data[9:8] == stored_bits);
`else
        assert (if_data[9:8] == stored_bits);
`endif
`ifdef COH_MAINT_OWNED
        p_maint_fact_if_global : assert (if_data[5] == stored_global);
`else
        assert (if_data[5] == stored_global);
`endif
      end
      if (if_resp && if_response_id[0] && !if_error)
`ifdef COH_MAINT_OWNED
        p_maint_fact_if_upper : assert (if_data == {4{64'h200004cf}});
`else
        assert (if_data == {4{64'h200004cf}});
`endif
      if (line_valid && line_ready) begin
        line_live_q  <= 1;
        walk_after_q <= store_sent_q && !pending;
      end
      if (line_resp) begin
        assert (line_live_q);
        line_live_q <= 0;
        if (walk_after_q && !line_error) begin
`ifdef COH_MAINT_OWNED
          p_maint_fact_walk_bits_0 : assert (line_data[9:8] == stored_bits);
`else
          assert (line_data[9:8] == stored_bits);
`endif
`ifdef COH_MAINT_OWNED
          p_maint_fact_walk_global_0 : assert (line_data[5] == stored_global);
`else
          assert (line_data[5] == stored_global);
`endif
        end
      end
      if (walk && walk_ready) begin
        poisoned_q <= 0;
        accepted_vpn_q <= walk_vpn;
        last_error_q <= 0;
      end
      expected_error_q <= line_resp && line_error && !poisoned_q && !discard;
      if (line_resp) last_error_q <= line_error;
      if (expected_error_q) begin
        assert (!line_valid);
        if (!discard) begin
          assert (walk_resp);
          assert (translation.fault_kind == riscv_pkg::DFAULT_ACCESS);
`ifdef COH_MAINT_OWNED
          p_maint_fact_vpn_1 : assert (translation.vpn == accepted_vpn_q);
`else
          assert (translation.vpn == accepted_vpn_q);
`endif
        end
      end
      if (walk_resp) begin
`ifdef COH_MAINT_OWNED
        p_maint_fact_vpn_0 : assert (translation.vpn == accepted_vpn_q);
`else
        assert (translation.vpn == accepted_vpn_q);
`endif
        assert (translation.fault_kind == (last_error_q ? riscv_pkg::DFAULT_ACCESS :
            riscv_pkg::DFAULT_NONE));
      end
      cover (&if_ungranted);
      cover (&if_owned && ptw_owned);
      cover (if_ungranted[0] && if_tail[1]);
      cover (u_valid && release_message.q == 9'h022 && if_owned[0]);
      cover (fence_done && (|if_tail) && !permit_u);
      cover (line_resp && line_error && !poisoned_q && !discard);
      cover (walk && walk_ready && ptw_tail);
      cover (line_resp && ptw_tail && !permit_c);
      cover (poisoned_q && ptw_tail && u_valid && release_message.q == 9'h040);
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
      if (drain_pending_q && drain_age_q >= 2 && !discard)
`ifdef COH_MAINT_OWNED
        p_maint_fact_drain : assert (walk_ready);
`else
        assert (walk_ready);
`endif
      cover (drain_pending_q && walk_ready);
      cover (discard && line_valid && line_ready);
      cover (discard && line_resp && line_error);
      cover (poisoned_q && line_resp);
      cover (line_resp && walk_after_q && !line_error && !fence_seen_q);
      cover (fence_seen_q && if_resp && if_after_q[if_response_id[0]] && !if_error);
      cover (fence_seen_q && line_resp && walk_after_q && !line_error && absorbed_q);
      cover (fence_done && store_goal == 1);
      cover (fence_done && store_goal == 2);
      cover (fence_done && store_goal == 4);
      cover (fence_seen_q && if_resp && !if_error && if_after_q[if_response_id[0]] &&
          store_put_complete_q && stored_global);
      cover (fence_seen_q && if_resp && !if_error && if_after_q[if_response_id[0]] &&
          store_absorbed_q && stored_global);
      cover (request_fence && store_sent_q && two_stores && $countones(store_holds) == 1);
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
        read_data_q <= address[5] ? {4{64'h200004cf}} : home_data_q;
      end
      if (read_pending_q && permit_data) read_pending_q <= 0;
      if (update_valid && !update_pending_q) begin
        update_pending_q <= 1;
        if (address == 32'h80000000) home_data_q <= update_data;
      end
      if (updated) update_pending_q <= 0;
      for (int n = 0; n < Slots; n++) begin
        predecessors_q[n] <= predecessors_q[n] & ~released;
        if (released[n]) state_q[n] <= Free;
        if (state_q[n] == Granted || state_q[n] == Completed)
          assert (grant_key[n] == request_key[n] && grant_address[n] == request_address[n]);
        if (home_d_valid && home_d_ready && free_slot == 2'(n)) begin
          state_q[n]   <= Queued;
          request_q[n] <= demand;
          after_q[n]   <= fence_seen_q;
          error_q[n]   <= read_error && demand.opcode == coherence_pkg::ReadOncePTW;
          for (int prior = 0; prior < Slots; prior++)
          predecessors_q[n][prior] <= home_live_q[prior] && !released[prior] &&
                request_address[prior] == demand.addr;
        end
        if (work_valid && service_slot == 2'(n)) state_q[n] <= Serving;
        if (result_valid && result_ready && result.tid == 6'(n)) begin
          state_q[n] <= Result;
          grant_q[n] <= result;
        end
        if (g_valid && (|g_ready) && grant_slot == 2'(n)) state_q[n] <= Granted;
        if (home_c_valid && home_c_ready && completion_slot == 2'(n)) state_q[n] <= Completed;
      end
      if (home_d_valid && home_d_ready && demand.q[8:7] == 2)
        competitors_q[demand.q[2:1]-1'b1] <= 1;
      if (result_valid && after_q[2'(result.tid)] && !result.error && result.q[8:7] == 0 &&
          result.q[6:5] != 0 && result.addr == 32'h80000000)
`ifdef COH_MAINT_OWNED
        p_maint_fact_after_result : assert (result.data[9:8] == stored_bits);
`else
        assert (result.data[9:8] == stored_bits);
`endif
      if (result_valid && result_ready)
        assert (result.tid < Slots && state_q[2'(result.tid)] == Serving);
      if (home_c_valid) begin
        assert (completion_found && state_q[completion_slot] == Granted);
      end
      if (home_c_valid && home_c_ready)
        assert (completion.q == completed_grant.q && completion.addr == completed_grant.addr);
      for (int n = 0; n < Slots; n++) if (state_q[n] == Result && !permit_g) delayed_g_q <= 1;
      if (home_c_valid && !permit_c) delayed_c_q <= 1;
      if ((|complete_q) && !permit_u) delayed_u_q <= 1;
      if (r_valid && r_ready && reply.absorbed) absorbed_q <= 1;
    end
  end
`ifdef COH_MAINT_OWNED
  localparam logic [63:0] ShapeMask = 64'hfffffffffffff8df;
  localparam logic [63:0] ShapeBase = 64'h200000cf;
  logic f_request_types, f_grant_shapes;
  always_comb begin
    f_request_types = 1;
    f_grant_shapes  = 1;
    for (int n = 0; n < Slots; n++) begin
      if (home_live_q[n]) begin
        if (request_key[n] != 9'h000 &&
            request_key[n] != 9'h020 &&
            request_key[n] != 9'h022 &&
            request_key[n] != 9'h040 &&
            request_key[n] != 9'h042 &&
            request_key[n] != 9'h162 &&
            request_key[n] != 9'h164)
          f_request_types = 0;
        if (f_request_opcode[n] != (request_key[n][8:7] == 2 ?
            coherence_pkg::DMARead :
            request_key[n][6:5] == 2 ?
            coherence_pkg::ReadOncePTW :
            request_key[n][6:5] == 1 ?
            coherence_pkg::ReadOnceIF :
            coherence_pkg::GetM))
          f_request_types = 0;
        if (request_key[n][6:5] != 2 && error_q[n]) f_request_types = 0;
      end
      if ((state_q[n] == Result ||
          state_q[n] == Granted ||
          state_q[n] == Completed) &&
          grant_key[n][6:5] != 2 &&
          f_grant_error[n])
        f_grant_shapes = 0;
      if ((state_q[n] == Result || state_q[n] == Granted || state_q[n] == Completed) &&
          !f_grant_error[n] && (f_grant_data[n] & {4{ShapeMask}}) != {4{ShapeBase}})
        f_grant_shapes = 0;
    end
  end
  always_ff @(posedge i_clk)
    if (!rst) begin
      if (result_valid && !result.error)
        p_maint_data_result_shape : assert ((result.data & {4{ShapeMask}}) == {4{ShapeBase}});
      if (g_valid && !grant.error)
        p_maint_data_grant_shape : assert ((grant.data & {4{ShapeMask}}) == {4{ShapeBase}});
      if (update_valid)
        p_maint_data_update_shape : assert ((update_data & {4{ShapeMask}}) == {4{ShapeBase}});
      p_maint_owned_request_types : assert (f_request_types);
      p_maint_owned_grant_shapes : assert (f_grant_shapes);
      if (|store_mask) p_maint_owned_store_shape : assert ((store_data_q & ShapeMask) == ShapeBase);
      p_maint_owned_home_shape : assert ((home_data_q & {4{ShapeMask}}) == {4{ShapeBase}});
      if (read_pending_q)
        p_maint_owned_read_shape : assert ((read_data_q & {4{ShapeMask}}) == {4{ShapeBase}});
      if (put_pending_q)
        p_maint_owned_put_shape : assert ((pending_put_q.data & {4{ShapeMask}}) == {4{ShapeBase}});
    end
`endif
`ifdef COH_MAINT_OWNED
  logic f_maint_states, f_maint_predecessors, f_maint_order, f_maint_serviced, f_maint_serial;
  logic [Slots-1:0] f_maint_advanced;
  always_comb begin
    f_maint_states = 1;
    f_maint_predecessors = 1;
    f_maint_order = 1;
    f_maint_serviced = 1;
    f_maint_serial = 1;
    for (int n = 0; n < Slots; n++) begin
      f_maint_advanced[n] = state_q[n] == Serving || state_q[n] == Result ||
          state_q[n] == Granted || state_q[n] == Completed;
      if (state_q[n] > Completed) f_maint_states = 0;
      if (f_maint_advanced[n] && predecessors_q[n] != 0) f_maint_serviced = 0;
    end
    for (int n = 0; n < Slots; n++) begin
      for (int m = 0; m < Slots; m++) begin
        if (home_live_q[n] && predecessors_q[n][m] &&
            (n == m || !home_live_q[m] || request_address[n] != request_address[m]))
          f_maint_predecessors = 0;
        if (n < m && home_live_q[n] && home_live_q[m] &&
            request_address[n] == request_address[m]) begin
          if (predecessors_q[n][m] == predecessors_q[m][n]) f_maint_order = 0;
          if (f_maint_advanced[n] && f_maint_advanced[m]) f_maint_serial = 0;
        end
      end
    end
  end
  always_ff @(posedge i_clk)
    if (!rst) begin
      p_maint_owned_states : assert (f_maint_states);
      p_maint_owned_predecessors : assert (f_maint_predecessors);
      p_maint_owned_order : assert (f_maint_order);
      p_maint_owned_serviced : assert (f_maint_serviced);
      p_maint_owned_serial : assert (f_maint_serial);
    end
`endif
`ifdef COH_MAINT_OWNED
  // Flags, high to low: pop, grant input, granted, written, resident,
  // put, accepted put, data reply. Phases: WaitU through Idle, high to low.
  logic [7:0] f_cache_flags;
  logic [6:0] f_cache_phase;
  logic [63:0] f_cache_value, f_cache_installed, f_cache_grant;
  coh_g_t f_private_grant;
  assign {
    f_seq_ever_pop, f_seq_final, f_seq_pushed, f_seq_popped,
    f_cache_flags, f_cache_phase, f_cache_value, f_cache_installed, f_cache_grant
  } = f_maint_view;
  assign f_private_grant = grant_q[2];
  wire  f_private_live = home_live_q[2] && request_key[2] == 0;
  wire  f_dirty = f_maint_home_state[2] && address == 32'h80000000;
  logic f_private_context;
  always_comb begin
    f_private_context = 1;
    if ((f_cache_phase[0] || f_cache_phase[1]) && f_private_live) f_private_context = 0;
    if (f_cache_phase[2] &&
        !(f_private_live &&
        (state_q[2] == Queued ||
        state_q[2] == Serving ||
        state_q[2] == Result)))
      f_private_context = 0;
    if ((|f_cache_phase[5:3]) && !(f_private_live && state_q[2] == Granted)) f_private_context = 0;
    if (f_cache_phase[6] && !(f_private_live && state_q[2] == Completed)) f_private_context = 0;
    if ((|f_cache_phase[6:3]) && f_cache_grant != f_private_grant.data[63:0]) f_private_context = 0;
  end
  always_ff @(posedge i_clk)
    if (!rst) begin
      p_maint_ledger_private_context : assert (f_private_context);
      if (f_private_live)
        p_maint_ledger_private_address : assert (request_address[2] == 32'h80000000);
      p_maint_ledger_put_exclusion : assert (!((put_pending_q || put_ack_q) && (|home_live_q)));
      p_maint_ledger_put_phases : assert (!(put_pending_q && put_ack_q));
      if (put_pending_q || put_ack_q)
        p_maint_ledger_put_owner : assert (f_cache_flags[2] && f_cache_flags[1]);
      if (put_pending_q)
        p_maint_ledger_put_data : assert (pending_put_q.data == {4{f_cache_installed}});
      if (put_ack_q) p_maint_ledger_ack_data : assert (home_data_q == {4{f_cache_installed}});
      p_maint_ledger_reply_wait : assert (r_valid == f_maint_home_state[0]);
      if (p_valid || r_valid) p_maint_ledger_no_reply_ack : assert (!wa_valid);
      if (f_dirty) begin
        p_maint_ledger_no_getm : assert (!(f_private_live && f_maint_advanced[2]));
        p_maint_ledger_no_resident : assert (!f_cache_flags[3]);
        p_maint_ledger_no_pop : assert (!f_cache_flags[7]);
        p_maint_ledger_image : assert (update_data == {4{f_cache_installed}});
        if (engine_idle || result_valid || update_pending_q)
          p_maint_ledger_published : assert (home_data_q == {4{f_cache_installed}});
      end
      if (!f_cache_flags[3] && !f_cache_flags[2] && !f_cache_flags[0] && !put_pending_q && !f_dirty)
        p_maint_ledger_home : assert (home_data_q == {4{f_cache_installed}});
      if (read_pending_q && result.q == 0)
        p_maint_ledger_getm_read : assert (read_data_q == {4{f_cache_installed}});
      if (!engine_idle && result.q == 0 && f_maint_home_state[1])
        p_maint_ledger_getm_image : assert (update_data == {4{f_cache_installed}});
      if (f_private_live && (state_q[2] == Result || (state_q[2] == Granted && !f_cache_flags[4])))
        p_maint_ledger_getm_grant : assert (f_private_grant.data == {4{f_cache_installed}});
      if (f_cache_flags[6])
        p_maint_ledger_grant_input : assert (f_cache_grant == f_cache_installed);
    end
`endif
`ifdef COH_MAINT_OWNED
  logic f_maint_keys;
  always_comb begin
    f_maint_keys = 1;
    if (home_live_q[0] && request_key[0] != 9'h020) f_maint_keys = 0;
    if (home_live_q[1] && request_key[1] != 9'h022) f_maint_keys = 0;
    if (home_live_q[2] && (request_key[2] == 9'h020 || request_key[2] == 9'h022)) f_maint_keys = 0;
  end
  always_ff @(posedge i_clk) if (!rst) p_maint_owned_keys : assert (f_maint_keys);
`endif
`ifdef COH_MAINT_OWNED
  always_ff @(posedge i_clk)
    if (!rst) begin
      p_maint_seq_launch_count :
      assert (stores_launched_q <= store_goal &&
          4'(f_seq_pushed) + 4'(|store_mask) == 4'(stores_launched_q));
      if (|store_mask) begin
        p_maint_seq_launch_mask : assert (store_mask == (stores_launched_q == 1 ? 8'hff : 8'h02));
        p_maint_seq_launch_data :
        assert (store_data_q == (stores_launched_q == 1 ? first_pte : stored_pte));
      end
      if (store_sent_q)
        p_maint_seq_sent : assert (stores_launched_q == store_goal && store_mask == 0);
      if (f_dirty || put_pending_q || put_ack_q) p_maint_seq_home_history : assert (f_seq_ever_pop);
      if (store_sent_q && !pending)
        p_maint_seq_store_drained : assert (f_seq_final && f_cache_installed == stored_pte);
      if (home_published_q)
        p_maint_seq_published : assert (f_seq_final && f_cache_installed == stored_pte);
      if (update_valid && address == 32'h80000000)
        p_maint_seq_update :
        assert (update_data == {4{first_pte}} || update_data == {4{stored_pte}});
    end
`endif
`ifdef COH_MAINT_OWNED
  always_ff @(posedge i_clk)
    if (!rst) begin
      p_maint_seq_put_context : assert (f_cache_flags[1] == (put_pending_q || put_ack_q));
      if (f_seq_final && !home_published_q)
        p_maint_seq_latest_owner :
        assert (f_cache_flags[3] ||
            f_cache_flags[2] ||
            f_cache_flags[0] ||
            f_dirty ||
            put_pending_q);
      if (home_prefix_q)
        p_maint_seq_prefix_copy :
        assert (home_data_q == {4{first_pte}} || home_data_q == {4{stored_pte}});
      if (home_published_q) p_maint_seq_final_copy : assert (home_data_q == {4{stored_pte}});
      if (probe_needs_fresh_q && r_valid)
        p_maint_seq_fresh_context :
        assert (f_seq_final && !home_published_q && address == 32'h80000000);
      if (r_valid && address == 32'h80000000 && f_seq_final && !home_published_q)
        p_maint_seq_latest_reply : assert (reply.data_valid && reply.data == {4{stored_pte}});
      if (probe_needs_fresh_q && r_valid)
        p_maint_seq_fresh_reply : assert (reply.data_valid && reply.data[9:8] == stored_bits);
      if (fence_seen_q || fence_done) p_maint_seq_fenced : assert (f_seq_final);
      if ((|after_q) || (|if_after_q) || walk_after_q) p_maint_seq_after : assert (f_seq_final);
      if (read_pending_q && address == 32'h80000000 && home_published_q)
        p_maint_seq_final_read : assert (read_data_q == {4{stored_pte}});
      if (!engine_idle &&
          address == 32'h80000000 &&
          f_maint_home_state[1] &&
          !f_dirty &&
          home_published_q)
        p_maint_seq_final_clean_image : assert (update_data == {4{stored_pte}});
      if (!engine_idle &&
          address == 32'h80000000 &&
          f_maint_home_state[1] &&
          f_maint_home_state[3] &&
          !f_dirty &&
          f_seq_final)
        p_maint_seq_clean_published : assert (home_published_q);
      if (result_valid && !result.error && result.addr == 32'h80000000 && f_seq_final)
        p_maint_seq_final_result : assert (result.data == {4{stored_pte}});
    end
`endif
`ifdef COH_MAINT_OWNED
  always_ff @(posedge i_clk)
    if (!rst && f_seq_final && f_dirty && (engine_idle || result_valid || update_pending_q))
      p_maint_seq_publish_marker : assert (home_published_q);
`endif
`ifdef COH_MAINT_OWNED
  logic f_if_request_context, f_if_upper_grants;
  always_comb begin
    f_if_request_context = 1;
    f_if_upper_grants = 1;
    for (int n = 0; n < 4; n++) begin
      if (f_if_read_requests[n][AddrWidth+:3] >= 3) begin
        if (!home_live_q[n < 2 ? n : 2] ||
            request_address[n < 2 ? n : 2] != f_if_read_requests[n][AddrWidth-1:0] ||
            request_key[n < 2 ? n : 2] != (n < 2 ? 9'h020 | (9'(n) << 1) : 9'h040 | (9'(n-2) << 1)))
          f_if_request_context = 0;
        if (f_if_read_requests[n][AddrWidth+:3] == 3) begin
          if (state_q[n < 2 ? n : 2] != Queued &&
              state_q[n < 2 ? n : 2] != Serving &&
              state_q[n < 2 ? n : 2] != Result)
            f_if_request_context = 0;
        end else if (state_q[n < 2 ? n : 2] != Granted && state_q[n < 2 ? n : 2] != Completed)
          f_if_request_context = 0;
      end
    end
    for (int n = 0; n < Slots; n++)
    if ((state_q[n] == Result ||
        state_q[n] == Granted ||
        state_q[n] == Completed) &&
        grant_address[n][5] &&
        !f_grant_error[n] &&
        f_grant_data[n] != {4{64'h200004cf}})
      f_if_upper_grants = 0;
  end
  always_ff @(posedge i_clk)
    if (!rst) begin
      p_maint_if_request_context : assert (f_if_request_context);
      p_maint_if_upper_grants : assert (f_if_upper_grants);
      if (read_pending_q && address[5])
        p_maint_if_upper_read : assert (read_data_q == {4{64'h200004cf}});
      if (result_valid && result.addr[5] && !result.error)
        p_maint_if_upper_result : assert (result.data == {4{64'h200004cf}});
      if (g_valid && grant.addr[5] && !grant.error)
        p_maint_if_upper_grant : assert (grant.data == {4{64'h200004cf}});
    end
`endif
`ifdef COH_MAINT_OWNED
  always_ff @(posedge i_clk)
    if (!rst &&
        !engine_idle &&
        !f_maint_home_state[4] &&
        !result.error &&
        f_maint_home_state[3] &&
        address == 32'h80000000 &&
        !f_dirty &&
        result.q != 0)
      p_maint_seq_clean_owner :
      assert (!f_cache_flags[3] && !f_cache_flags[2] && !f_cache_flags[5]);
`endif
`ifdef COH_MAINT_OWNED
  logic f_if_no_install, f_if_latest_grants;
  always_comb begin
    f_if_no_install = 1;
    f_if_latest_grants = 1;
    for (int n = 0; n < Slots; n++)
    if ((state_q[n] == Result ||
        state_q[n] == Granted ||
        state_q[n] == Completed) &&
        request_address[n] == 32'h80000000 &&
        request_key[n] != 0 &&
        !f_grant_error[n]) begin
      if (f_cache_flags[3] || f_cache_flags[5] || f_cache_flags[7]) f_if_no_install = 0;
      if (f_seq_final && f_grant_data[n] != {4{stored_pte}}) f_if_latest_grants = 0;
    end
  end
  always_ff @(posedge i_clk)
    if (!rst) begin
      p_maint_if_no_install : assert (f_if_no_install);
      p_maint_if_latest_grants : assert (f_if_latest_grants);
      if (g_valid && grant.q != 0 && grant.addr == 32'h80000000 && !grant.error && f_seq_final)
        p_maint_if_latest_grant : assert (grant.data == {4{stored_pte}});
      if (fence_done || fence_seen_q || (|if_after_q))
        p_maint_if_fenced_epoch : assert (f_if_swept);
    end
`endif
`ifdef COH_MAINT_OWNED
  logic f_ppn_grants;
  always_comb begin
    f_ppn_grants = 1;
    for (int n = 0; n < Slots; n++)
    if ((state_q[n] == Result ||
        state_q[n] == Granted ||
        state_q[n] == Completed) &&
        !f_grant_error[n] &&
        (f_grant_data[n] & {4{64'hfffffffffffffcdf}}) != {4{grant_address[n][5] ?
        64'h200004cf : 64'h200000cf}})
      f_ppn_grants = 0;
  end
  always_ff @(posedge i_clk)
    if (!rst) begin
      p_maint_ppn_home : assert ((home_data_q & {4{64'hfffffffffffffcdf}}) == {4{64'h200000cf}});
      if (read_pending_q)
        p_maint_ppn_read :
        assert ((read_data_q & {4{64'hfffffffffffffcdf}}) == {4{address[5] ?
            64'h200004cf : 64'h200000cf}});
      if (result_valid && !result.error)
        p_maint_ppn_result :
        assert ((result.data & {4{64'hfffffffffffffcdf}}) == {4{result.addr[5] ?
            64'h200004cf : 64'h200000cf}});
      p_maint_ppn_grants : assert (f_ppn_grants);
      if (g_valid && !grant.error)
        p_maint_ppn_grant :
        assert ((grant.data & {4{64'hfffffffffffffcdf}}) == {4{grant.addr[5] ?
            64'h200004cf : 64'h200000cf}});
    end
`endif
`ifdef COH_MAINT_OWNED
  logic f_walk_owners;
  logic [2:0] f_walk_pending;
  always_comb begin
    f_walk_owners  = 1;
    f_walk_pending = 0;
    for (int n = 2; n < 4; n++) begin
      if (f_if_read_requests[n][AddrWidth+:3] == 2 || f_if_read_requests[n][AddrWidth+:3] == 3)
        f_walk_pending += 1'b1;
      if (f_if_read_requests[n][AddrWidth+:3] != 0 &&
          f_if_read_requests[n][AddrWidth-1:0] != 32'h80000000)
        f_walk_owners = 0;
    end
    if (f_walk_pending + 3'(line_resp) > 1) f_walk_owners = 0;
    if (line_live_q != ((f_walk_pending != 0) || line_resp)) f_walk_owners = 0;
  end
  always_ff @(posedge i_clk)
    if (!rst) begin
      p_maint_ptw_owners : assert (f_walk_owners);
      p_maint_ptw_wait : assert (line_live_q == (f_walk_state == 2));
      if (line_valid) p_maint_ptw_address : assert (line_addr == 32'h80000000);
      if (f_walk_state != 0) begin
        p_maint_ptw_vpn_context : assert (f_walk_vpn == accepted_vpn_q);
        p_maint_ptw_error_context : assert (f_walk_error == last_error_q);
        p_maint_ptw_poison_context : assert (f_walk_poison == poisoned_q);
      end
      if (line_resp && !line_error)
        p_maint_ptw_line_image :
        assert ((line_data & {4{64'hfffffffffffffcdf}}) == {4{64'h200000cf}});
      if (drain_pending_q) begin
        p_maint_ptw_drain_enter :
        assert (f_walk_state == 0 || f_walk_state == 3 || f_walk_state == 4);
        if (drain_age_q >= 1)
          p_maint_ptw_drain_response : assert (f_walk_state == 0 || f_walk_state == 4);
        if (drain_age_q >= 2) p_maint_ptw_drain_idle : assert (f_walk_state == 0);
      end
    end
`endif
endmodule
