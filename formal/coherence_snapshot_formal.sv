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

// A CPU rewrites a byte after the first DMA snapshot's R transfers. Its G
// waits for the second installation. The subsequent reads and masked DMA
// write all use the same address through the production L1D and home.
module coherence_snapshot_formal (
    input logic i_clk
);
  localparam int unsigned AddrWidth = 32;
  `FROST_COHERENCE_TYPES(AddrWidth)
  localparam logic [31:0] Address  = 32'h80000000;
  localparam logic [ 8:0] AgentKey = {2'd2, 2'd3, 4'd9, 1'b0};
  typedef enum logic [2:0] {
    WaitStores,
    Demand,
    Grant,
    Complete,
    Release,
    Finished
  } phase_t;
  phase_t phase_q;
  logic past_q = 0;
  wire rst = !past_q;
  logic [8:0] cycle_q;
  (* anyconst *) logic [7:0] first_byte, second_byte;
  logic [2:0] transaction_q;
  logic [1:0] sent_q, done_q;
  logic probe_seen_q, reply_seen_q, cut_seen_q, getm_seen_q;
  logic first_held_q, store_offer_q;
  logic [5:0] tid_q;
  logic ready, done, pending, fatal;
  logic agent_ready, agent_g_valid, agent_c_ready, agent_u_valid;
  logic mem_valid, mem_write, response_valid_q;
  logic [4:0] mem_id, response_id_q;
  logic probe_taken, reply_taken, reply_has_data, getm_taken, cut_valid;
  logic [1:0] probe_opcode, reply_state;
  logic [255:0] reply_image;
  coh_d_t agent_request;
  coh_g_t agent_grant;
  coh_c_t agent_completion;
  coh_u_t agent_release;
  wire store = !rst && store_offer_q;
  wire [7:0] write_mask = {7'd0, store};
  wire [63:0] write_data = {56'd0, sent_q == 0 ? first_byte : second_byte};
  wire installed_second = sent_q == 2 && done_q == 2 && !pending;
  wire agent_valid = phase_q == Demand;
  wire grant_ready = phase_q == Grant && (transaction_q != 0 || installed_second);
  wire dma_write = transaction_q == 3;
  wire [255:0] expected = {
    240'd0, transaction_q == 4 ? 8'ha5 : 8'd0, transaction_q == 0 ? first_byte : second_byte
  };
  always_comb begin
    agent_request = '0;
    agent_request.addr = Address;
    agent_request.q = AgentKey;
    agent_request.size = 5;
    agent_request.opcode = dma_write ? coherence_pkg::DMAWrite : coherence_pkg::DMARead;
    agent_request.mask = dma_write ? 32'h2 : 0;
    agent_request.wdata = dma_write ? 256'ha500 : 0;
    agent_completion = '0;
    agent_completion.q = AgentKey;
    agent_completion.addr = Address;
    agent_completion.tid = tid_q;
    agent_completion.status = coherence_pkg::Consumed;
  end
  always_ff @(posedge i_clk) begin
    past_q <= 1;
    if (rst) begin
      cycle_q <= 0;
      phase_q <= WaitStores;
      transaction_q <= 0;
      sent_q <= 0;
      done_q <= 0;
      probe_seen_q <= 0;
      reply_seen_q <= 0;
      cut_seen_q <= 0;
      getm_seen_q <= 0;
      first_held_q <= 0;
      store_offer_q <= 0;
      response_valid_q <= 0;
      tid_q <= 0;
    end else begin
      if (!(&cycle_q)) cycle_q <= cycle_q + 1'b1;
      // The CPU samples a launch credit on the preceding edge.
      store_offer_q <= !store && ready &&
          ((sent_q == 0 && cycle_q > 6) || (sent_q == 1 && first_held_q));
      response_valid_q <= mem_valid;
      if (mem_valid) begin
        assert (!mem_write);
        response_id_q <= mem_id;
      end
      if (store) sent_q <= sent_q + 1'b1;
      if (done) done_q <= done_q + 1'b1;
      if (getm_taken) begin
        p_single_getm : assert (!getm_seen_q && transaction_q == 0 && phase_q == WaitStores);
        getm_seen_q <= 1;
      end
      if (cut_valid) begin
        assert (dma_write);
        cut_seen_q <= 1;
      end
      if (probe_taken) begin
        assert (phase_q == Grant && !probe_seen_q);
        p_probe_kind :
        assert (probe_opcode == (dma_write ? coherence_pkg::ProbeInvalidate :
            coherence_pkg::ProbeSnapshot));
        probe_seen_q <= 1;
      end
      if (reply_taken) begin
        assert (phase_q == Grant && probe_seen_q && !reply_seen_q);
        p_reply_state :
        assert (reply_state == (transaction_q < 3 ? coherence_pkg::Modified :
            coherence_pkg::Invalid));
        p_reply_data : assert (reply_has_data == (transaction_q < 2 || dma_write));
        if (reply_has_data) p_snapshot_bytes : assert (reply_image == expected);
        reply_seen_q <= 1;
      end
      if (agent_g_valid) begin
        assert (phase_q == Grant && reply_seen_q && !agent_grant.error);
        assert (agent_grant.addr == Address && agent_grant.q == AgentKey);
        if (dma_write) begin
          assert (agent_grant.opcode == coherence_pkg::GrantAck && cut_seen_q);
        end else begin
          p_snapshot_result :
          assert (agent_grant.opcode == coherence_pkg::GrantData && agent_grant.data == expected);
        end
        if (transaction_q == 0 && !grant_ready) first_held_q <= 1;
      end
      if (!$past(rst) && $past(agent_g_valid && !grant_ready))
        p_snapshot_held : assert (agent_g_valid && agent_grant == $past(agent_grant));
      if (phase_q == WaitStores && getm_seen_q && done_q == 1 && !pending) phase_q <= Demand;
      if (agent_valid && agent_ready) phase_q <= Grant;
      if (agent_g_valid && grant_ready) begin
        tid_q   <= agent_grant.tid;
        phase_q <= Complete;
      end
      if (phase_q == Complete && agent_c_ready) phase_q <= Release;
      if (agent_u_valid) begin
        assert (phase_q == Release && agent_release.q == AgentKey &&
            agent_release.tid == tid_q && agent_release.addr == Address);
        phase_q <= transaction_q == 4 ? Finished : Demand;
        transaction_q <= transaction_q + 1'b1;
        probe_seen_q <= 0;
        reply_seen_q <= 0;
        cut_seen_q <= 0;
      end
      assert (!fatal && done_q <= sent_q);
      p_snapshot_progress : assert (cycle_q < 280 || (phase_q == Finished && installed_second));
      c_snapshot_versions :
      cover (phase_q == Finished && first_held_q && first_byte != second_byte);
    end
  end
  coherence_cluster_test_harness #(
      .L1D_MISSES(1),
      .L1D_CACHE_BYTES(256),
      .L1D_WAYS(4),
      .HOME_CACHE_BYTES(128),
      .HOME_WAYS(1),
      .HOME_COMPLETIONS(4),
      .HOME_RESULTS(2),
      .HOME_FILLS(1),
      .HOME_PREFETCH_SLOTS(0)
  ) cluster (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_cmo_valid(1'b0),
      .i_cmo_kind(2'd1),
      .i_cmo_addr('0),
      .o_cmo_ready(),
      .o_cmo_done(),
      .i_fatal_stop('0),
      .i_read_valid(1'b0),
      .i_read_id('0),
      .i_read_kind('0),
      .i_read_size(3'd3),
      .i_read_tag('0),
      .i_address(Address),
      .o_read_valid(),
      .i_read_ready(1'b1),
      .o_read_id(),
      .o_read_data(),
      .o_read_error(),
      .i_write_mask(write_mask),
      .i_write_data(write_data),
      .i_write_atomic('0),
      .i_write_sc('0),
      .i_write_zero(1'b0),
      .i_write_more(1'b0),
      .i_next_same(1'b0),
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
      .o_cut_inval_valid(cut_valid),
      .i_cut_inval_done(1'b1),
      .o_cut_release(),
      .i_hold_grant('0),
      .i_hold_wa(1'b0),
      .i_hold_release(1'b0),
      .i_agent_valid(agent_valid),
      .o_agent_ready(agent_ready),
      .i_agent_d(agent_request),
      .o_agent_g_valid(agent_g_valid),
      .i_agent_g_ready(grant_ready),
      .o_agent_g(agent_grant),
      .i_agent_c_valid(phase_q == Complete),
      .o_agent_c_ready(agent_c_ready),
      .i_agent_c(agent_completion),
      .o_agent_u_valid(agent_u_valid),
      .i_agent_u_ready(1'b1),
      .o_agent_u(agent_release),
      .o_mem_req_valid(mem_valid),
      .i_mem_req_ready(1'b1),
      .o_mem_req_write(mem_write),
      .o_mem_req_addr(),
      .o_mem_req_data(),
      .o_mem_req_mask(),
      .o_mem_req_id(mem_id),
      .i_mem_resp_valid(response_valid_q),
      .i_mem_resp_id(response_id_q),
      .i_mem_resp_data('0),
      .i_mem_resp_error('0),
      .o_probe_taken(probe_taken),
      .o_probe_opcode(probe_opcode),
      .o_reply_taken(reply_taken),
      .o_reply_state(reply_state),
      .o_reply_data_valid(reply_has_data),
      .o_reply_data(reply_image),
      .o_getm_taken(getm_taken),
      .o_l1d_perf(),
      .o_l2_perf(),
      .o_l2_write_perf(),
      .o_live_stores(),
      .o_held_puts(),
      .o_load_grant(),
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
