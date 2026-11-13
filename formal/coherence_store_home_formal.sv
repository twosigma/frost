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

// Directed composition of the production L1D and home with reordered memory
// responses. The selected byte survives private and home replacement.
module coherence_store_home_formal #(
    parameter int unsigned SECTOR_CASE = 0,
    parameter bit PRESSURE = 1'b0,
    parameter bit COVER_MODE = 1'b0,
    // Register stages between the L1D and the home; each stage adds a few
    // cycles to every round trip, so the progress bound grows with it.
    parameter int unsigned LINK_STAGES = 0
) (
    input logic i_clk
);
  logic requested_q, granted_q, completed_q, completion_sent_q, finished_q;
  localparam int unsigned AddrWidth = 32;
  `FROST_COHERENCE_TYPES(AddrWidth)
  logic past_q = 0;
  wire rst = !past_q;
  logic [8:0] cycle_q = 0;
  always_ff @(posedge i_clk) begin
    past_q <= 1;
    if (cycle_q != 511) cycle_q <= cycle_q + 1'b1;
  end
  localparam logic [31:0] First  = 32'h80000000;
  localparam logic [31:0] Second = First + (SECTOR_CASE == 0 ? 32 : SECTOR_CASE == 1 ? 64 : 128);
  (* anyconst *) logic watch_second;
  (* anyconst *) logic [7:0] first_byte, second_byte;
  wire [31:0] watched = PRESSURE ? First + (watch_second ? 192 : 128) :
      watch_second ? Second : First;
  wire [7:0] expected_byte = watch_second ? second_byte : first_byte;
  logic [7:0] write_mask;
  logic [63:0] write_data;
  logic [31:0] address;
  logic ready, pending, done, fatal;
  logic [2:0] sent_q, acknowledged_q;
  logic [2:0] live_stores;
  logic overlap_q, primed_q, pressure_armed_q, pressure_seen_q;
  logic [1:0] held_puts;
  logic load_grant, load_grant_q, read_started_q, read_valid_q, read_done_q;
  logic read_response, read_error;
  logic [63:0] read_data;
  wire bootstrap = !PRESSURE && SECTOR_CASE == 2 && !primed_q;
  wire hold_wa = PRESSURE && pressure_armed_q && !finished_q;
  wire hold_release = PRESSURE && pressure_armed_q && !load_grant_q;
  always_ff @(posedge i_clk) begin
    if (rst) begin
      write_mask <= 0;
      write_data <= 0;
      address <= 0;
      sent_q <= 0;
      acknowledged_q <= 0;
      overlap_q <= 0;
      pressure_armed_q <= 0;
      pressure_seen_q <= 0;
      load_grant_q <= 0;
      read_started_q <= 0;
      read_valid_q <= 0;
      read_done_q <= 0;
    end else begin
      write_mask   <= 0;
      read_valid_q <= 0;
      if (PRESSURE && sent_q == 2 && !pending && !(|live_stores) && acknowledged_q == 2)
        pressure_armed_q <= 1;
      if (ready && sent_q < (PRESSURE ? 4 : 2) && cycle_q >= 8 &&
          cycle_q[1:0] == 0 && !bootstrap &&
          (!PRESSURE || (sent_q < 2 ? (!pending && !(|live_stores) && sent_q == acknowledged_q) :
           pressure_armed_q))) begin
        write_mask <= 1;
        address <= PRESSURE ? First + (32'(sent_q) << 6) : sent_q == 0 ? First : Second;
        write_data <= {
          56'b0, (sent_q[0] ? second_byte : first_byte) ^ (PRESSURE && sent_q < 2 ? 8'hff : 8'h00)
        };
        sent_q <= sent_q + 1'b1;
      end
      if (PRESSURE && &held_puts && !pending && acknowledged_q == 4 && !read_started_q) begin
        read_started_q <= 1;
        read_valid_q <= 1;
        pressure_seen_q <= 1;
      end
      if (load_grant) load_grant_q <= 1;
      if (read_response) begin
        assert (read_started_q && !read_done_q);
        assert (!read_error && read_data == 0 && !hold_wa);
        read_done_q <= 1;
      end
      if (done) acknowledged_q <= acknowledged_q + 1'b1;
      if ($countones(live_stores) == 2) overlap_q <= 1;
      assert (!fatal);
      assert ($countones(live_stores) <= 2);
      assert (acknowledged_q <= sent_q);
      if (!PRESSURE && SECTOR_CASE == 2) assert ($countones(live_stores) <= 1);
      p_home_store_bounded_progress :
      assert (cycle_q < (PRESSURE || SECTOR_CASE == 2 ? 340 : 220) + 60 * LINK_STAGES ||
          (finished_q && (!PRESSURE || (read_done_q && pressure_seen_q && load_grant_q))));
    end
  end
  logic mem_valid, mem_write;
  logic [ 31:0] mem_addr;
  logic [511:0] mem_data;
  logic [ 63:0] mem_mask;
  logic [  4:0] mem_id;
  logic [31:0] memory_pending_q, memory_watched_q;
  logic [7:0] memory_byte_q;
  logic response_valid;
  logic [4:0] response_id;
  logic [511:0] response_data;
  always_comb begin
    response_id = 0;
    for (int id = 0; id < 32; id++) if (memory_pending_q[id]) response_id = 5'(id);
    response_valid = |memory_pending_q && cycle_q >= 48 && cycle_q[1:0] == 3;
    response_data  = '0;
    if (memory_watched_q[response_id]) response_data[8*watched[5:0]+:8] = memory_byte_q;
  end
  always_ff @(posedge i_clk) begin
    if (rst) begin
      memory_pending_q <= 0;
      memory_watched_q <= 0;
      memory_byte_q <= 0;
    end else begin
      if (response_valid) memory_pending_q[response_id] <= 0;
      if (mem_valid) begin
        assert (!memory_pending_q[mem_id]);
        memory_pending_q[mem_id] <= 1;
        memory_watched_q[mem_id] <= mem_addr[31:6] == watched[31:6];
        if (mem_write && mem_addr[31:6] == watched[31:6] && mem_mask[watched[5:0]])
          memory_byte_q <= mem_data[8*watched[5:0]+:8];
      end
    end
  end
  coh_d_t agent_request, accepted_request_q;
  coh_g_t agent_grant;
  coh_c_t agent_completion;
  coh_u_t agent_release;
  logic [5:0] agent_tid_q;
  logic agent_valid, agent_ready, agent_g_valid, agent_c_valid, agent_c_ready, agent_u_valid;
  always_comb begin
    agent_request = '0;
    agent_request.opcode = bootstrap ? coherence_pkg::DMAWrite : coherence_pkg::DMARead;
    agent_request.q = {2'd2, 2'd3, 3'd0, primed_q, 1'b0};
    agent_request.addr = bootstrap ? Second : watched;
    agent_request.size = 3;
    agent_request.mask = bootstrap ? '1 : '0;
    agent_valid = !requested_q && !finished_q && (bootstrap ? cycle_q >= 8 :
        PRESSURE ? load_grant_q : acknowledged_q == 2 && !pending);
  end
  assign agent_c_valid = completed_q;
  always_ff @(posedge i_clk) begin
    if (rst) begin
      requested_q <= 0;
      granted_q <= 0;
      completed_q <= 0;
      completion_sent_q <= 0;
      finished_q <= 0;
      primed_q <= 0;
      accepted_request_q <= '0;
      agent_tid_q <= '0;
      agent_completion <= '0;
    end else begin
      if (agent_valid && agent_ready) begin
        assert (!requested_q && !granted_q && !completed_q && !completion_sent_q);
        requested_q <= 1;
        accepted_request_q <= agent_request;
      end
      if (agent_g_valid) begin
        assert (requested_q && !granted_q && !completion_sent_q && !finished_q);
        assert (agent_grant.q == accepted_request_q.q &&
            agent_grant.addr == accepted_request_q.addr);
        assert (agent_grant.opcode == (accepted_request_q.opcode == coherence_pkg::DMAWrite ?
            coherence_pkg::GrantAck : coherence_pkg::GrantData));
        p_home_store_byte :
        assert (!agent_grant.error && (bootstrap || agent_grant.data[7:0] == expected_byte));
        granted_q <= 1;
        agent_tid_q <= agent_grant.tid;
        completed_q <= 1;
        agent_completion <= {
          accepted_request_q.q,
          agent_grant.tid,
          accepted_request_q.addr,
          coherence_pkg::Consumed,
          1'b0
        };
      end
      if (agent_c_valid && agent_c_ready) begin
        assert (requested_q && granted_q && !completion_sent_q && !finished_q);
        assert (agent_completion == {accepted_request_q.q, agent_tid_q,
            accepted_request_q.addr, coherence_pkg::Consumed, 1'b0});
        completed_q <= 0;
        completion_sent_q <= 1;
      end
      if (agent_u_valid) begin
        assert (requested_q && granted_q && completion_sent_q && !completed_q && !finished_q);
        assert (agent_release == {accepted_request_q.q, agent_tid_q, accepted_request_q.addr});
        if (accepted_request_q.opcode == coherence_pkg::DMAWrite) begin
          primed_q <= 1;
          requested_q <= 0;
          granted_q <= 0;
          completion_sent_q <= 0;
        end else finished_q <= 1;
      end
      if (COVER_MODE) begin
        assume (first_byte == 8'h11 && second_byte == 8'h22);
        p_home_store_progress :
        cover (finished_q && (SECTOR_CASE == 2 || overlap_q) &&
            (!PRESSURE || (read_done_q && pressure_seen_q && load_grant_q)));
      end
    end
  end
  coherence_cluster_test_harness #(
      .L1D_MISSES(3),
      .L1D_CACHE_BYTES(PRESSURE ? 128 : 64),
      .L1D_WAYS(1),
      .HOME_CACHE_BYTES(PRESSURE ? 512 : 128),
      .HOME_WAYS(PRESSURE ? 4 : 1),
      .HOME_COMPLETIONS(4),
      .HOME_RESULTS(2),
      .HOME_FILLS(2),
      .HOME_PREFETCH_SLOTS(0),
      .LINK_STAGES(LINK_STAGES)
  ) cluster (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_fatal_stop('0),
      .i_read_valid(read_valid_q),
      .i_read_id('0),
      .i_read_kind('0),
      .i_read_size(3'd3),
      .i_read_tag('0),
      .i_address(read_valid_q ? First + 256 : address),
      .o_read_valid(read_response),
      .i_read_ready(1'b1),
      .o_read_id(),
      .o_read_data(read_data),
      .o_read_error(read_error),
      .i_write_mask(write_mask),
      .i_write_data(write_data),
      .i_write_atomic('0),
      .i_write_sc('0),
      .i_write_zero(1'b0),
      .i_write_tag('0),
      .o_write_done(done),
      .o_write_inflight(),
      .o_store_ready(ready),
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
      .i_maint_valid('0),
      .i_maint_line('0),
      .i_maint_address('0),
      .o_maint_done(),
      .o_cut_hold(),
      .o_cut_admit_valid(),
      .i_cut_admit_ready(1'b1),
      .o_cut_address(),
      .o_cut_inval_valid(),
      .i_cut_inval_done(1'b1),
      .o_cut_release(),
      .i_hold_grant('0),
      .i_hold_wa(hold_wa),
      .i_hold_release(hold_release),
      .i_agent_valid(agent_valid),
      .o_agent_ready(agent_ready),
      .i_agent_d(agent_request),
      .o_agent_g_valid(agent_g_valid),
      .i_agent_g_ready(1'b1),
      .o_agent_g(agent_grant),
      .i_agent_c_valid(agent_c_valid),
      .o_agent_c_ready(agent_c_ready),
      .i_agent_c(agent_completion),
      .o_agent_u_valid(agent_u_valid),
      .i_agent_u_ready(1'b1),
      .o_agent_u(agent_release),
      .o_mem_req_valid(mem_valid),
      .i_mem_req_ready(1'b1),
      .o_mem_req_write(mem_write),
      .o_mem_req_addr(mem_addr),
      .o_mem_req_data(mem_data),
      .o_mem_req_mask(mem_mask),
      .o_mem_req_id(mem_id),
      .i_mem_resp_valid(response_valid),
      .i_mem_resp_id(response_id),
      .i_mem_resp_data(response_data),
      .i_mem_resp_error('0),
      .o_l1d_perf(),
      .o_l2_perf(),
      .o_l2_write_perf(),
      .o_live_stores(live_stores),
      .o_held_puts(held_puts),
      .o_load_grant(load_grant),
      .o_fatal(fatal),
      .o_fatal_addr(),
      // The line client stays idle in these proofs.
      .i_line_req_valid(1'b0),
      .o_line_req_ready(),
      .i_line_req_write(1'b0),
      .i_line_req_addr('0),
      .i_line_req_data('0),
      .i_line_req_mask('0),
      .i_line_req_id('0),
      .o_line_resp_valid(),
      .o_line_resp_id(),
      .o_line_resp_data(),
      .o_line_resp_error()
  );
endmodule
