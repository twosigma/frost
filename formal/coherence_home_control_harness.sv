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

// Control interleavings span four cache capacities and three completion identities.
// The four-way configurations let prefetches allocate and meet the fill
// reserve, the last available way and the last write-back slot.
module coherence_home_control_harness #(
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned WAYS = 1,
    parameter int unsigned FILLS = 2,
    parameter int unsigned PREFETCH_RESERVE = FILLS / 4,
    parameter bit ULTRA = 1'b0,
    parameter int unsigned PREFETCH_SLOTS = 0,
    parameter bit FAST_TAG_LAUNCH = 1'b0,
    localparam int unsigned AddressBits = $clog2(8 * LINE_BYTES * WAYS)
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_stop,
    input logic i_d_valid,
    input logic [343:0] i_d,
    input logic i_p_ready,
    input logic i_r_valid,
    input logic [306:0] i_r,
    input logic i_w_valid,
    input logic [291:0] i_w,
    input logic i_wa_ready,
    input logic i_g_ready,
    input logic i_c_valid,
    input logic [49:0] i_c,
    input logic i_u_ready,
    input logic i_mem_ready,
    input logic i_mem_valid,
    input logic [4:0] i_mem_id,
    input logic i_mem_error
);
  `FROST_COHERENCE_TYPES(32)
  coh_d_t demand;
  coh_r_t reply;
  coh_w_t put;
  coh_c_t completion;
  always_comb begin
    demand = i_d;
    demand.addr[31:AddressBits] = '0;
    demand.wdata = '0;
    reply = i_r;
    reply.addr[31:AddressBits] = '0;
    reply.data = '0;
    put = i_w;
    put.addr[31:AddressBits] = '0;
    put.data = '0;
    completion = i_c;
    completion.addr[31:AddressBits] = '0;
  end
`ifdef COHERENCE_HOME_CMO_WITNESS
  `define FROST_CMO_OBSERVE(signal) signal
  logic witness_d_ready, witness_p_valid, witness_r_ready;
  logic witness_g_valid, witness_c_ready, witness_u_valid, witness_mem_req;
  logic [4:0] witness_mem_req_id;
  coh_p_t witness_p;
  coh_g_t witness_g;

  typedef enum logic [1:0] {
    AbsentClean,
    ResidentClean,
    DirtyFlush,
    DirtyInval
  } witness_case_t;
  (* anyconst *) witness_case_t witness_case;
  logic witness_reset_seen = 1'b0;
  logic [1:0] witness_demands;
  logic [1:0] witness_releases;
  logic witness_initial;
  coh_d_t witness_d;
  coh_r_t witness_r;
  coh_c_t witness_c;
  logic witness_r_valid, witness_c_valid, witness_mem_valid;
  logic [4:0] witness_mem_id;

  // A GetS installs clean data. GetMZero installs a modified copy.
  always_comb begin
    witness_initial = witness_case != AbsentClean && witness_demands == 0;
    witness_d = '0;
    witness_d.size = 3'd3;
    if (witness_initial) begin
      if (witness_case == ResidentClean) witness_d.opcode = coherence_pkg::GetS;
      else witness_d.opcode = coherence_pkg::GetMZero;
    end else begin
      case (witness_case)
        DirtyInval: witness_d.opcode = coherence_pkg::InvalBlock;
        DirtyFlush: witness_d.opcode = coherence_pkg::FlushBlock;
        default:    witness_d.opcode = coherence_pkg::CleanBlock;
      endcase
      witness_d.q.port_class = 2'd3;
      witness_d.q.id = 4'(coherence_pkg::CmoId);
    end
  end

  // Reply to the home's accepted probes, grants and memory commands.
  always_ff @(posedge i_clk) begin
    witness_reset_seen <= 1'b1;
    assume (i_rst == !witness_reset_seen);
    if (i_rst) begin
      witness_demands <= 0;
      witness_releases <= 0;
      witness_r_valid <= 0;
      witness_c_valid <= 0;
      witness_mem_valid <= 0;
      witness_mem_id <= 0;
      witness_r <= '0;
      witness_c <= '0;
    end else begin
      assume (!i_stop && !i_w_valid && i_wa_ready && i_u_ready && i_mem_ready && !i_mem_error);
      assume (i_d_valid == (witness_demands == 0 ||
          (witness_case != AbsentClean && witness_demands == 1 &&
           (!FAST_TAG_LAUNCH || witness_releases != 0))));
      assume (i_d == witness_d);
      assume (i_p_ready == !witness_r_valid && i_r_valid == witness_r_valid);
      assume (i_r == witness_r);
      assume (i_g_ready == !witness_c_valid && i_c_valid == witness_c_valid);
      assume (i_c == witness_c);
      assume (i_mem_valid == witness_mem_valid && i_mem_id == witness_mem_id);
      if (i_d_valid && witness_d_ready) witness_demands <= witness_demands + 1'b1;
      if (witness_u_valid && i_u_ready) witness_releases <= witness_releases + 1'b1;
      if (witness_p_valid && i_p_ready) begin
        witness_r_valid <= 1'b1;
        witness_r <= '0;
        witness_r.tid <= witness_p.tid;
        witness_r.addr <= witness_p.addr;
        witness_r.clear <= 1'b1;
      end else if (i_r_valid && witness_r_ready) witness_r_valid <= 1'b0;
      if (witness_g_valid && i_g_ready) begin
        witness_c_valid <= 1'b1;
        witness_c <= '0;
        witness_c.q <= witness_g.q;
        witness_c.tid <= witness_g.tid;
        witness_c.addr <= witness_g.addr;
        witness_c.status <= coherence_pkg::Consumed;
        witness_c.write_done <= 1'b1;
      end else if (i_c_valid && witness_c_ready) witness_c_valid <= 1'b0;
      witness_mem_valid <= witness_mem_req && i_mem_ready;
      if (witness_mem_req && i_mem_ready) witness_mem_id <= witness_mem_req_id;
    end
  end
`else
  `define FROST_CMO_OBSERVE(signal)
`endif

  coherence_home #(
      .COMPLETIONS(3),
      .RESULTS(2),
      .PREFETCH_SLOTS(PREFETCH_SLOTS),
      .FILLS(FILLS),
      .PREFETCH_RESERVE(PREFETCH_RESERVE),
      .LINE_BYTES(LINE_BYTES),
      .CACHE_BYTES(2 * LINE_BYTES * WAYS),
      .WAYS(WAYS),
      .ULTRA(ULTRA),
      .FAST_TAG_LAUNCH(FAST_TAG_LAUNCH)
  ) home (
      .i_clk,
      .i_rst,
      .i_fatal_stop(i_stop),
      .i_d_valid,
      .o_d_ready(`FROST_CMO_OBSERVE(witness_d_ready)),
      .i_d(demand),
      .o_p_valid(`FROST_CMO_OBSERVE(witness_p_valid)),
      .i_p_ready,
      .o_p(`FROST_CMO_OBSERVE(witness_p)),
      .i_r_valid,
      .o_r_ready(`FROST_CMO_OBSERVE(witness_r_ready)),
      .i_r(reply),
      .i_w_valid,
      .o_w_ready(),
      .i_w(put),
      .o_wa_valid(),
      .i_wa_ready,
      .o_wa(),
      .o_g_valid(`FROST_CMO_OBSERVE(witness_g_valid)),
      .i_g_ready,
      .o_g(`FROST_CMO_OBSERVE(witness_g)),
      .i_c_valid,
      .o_c_ready(`FROST_CMO_OBSERVE(witness_c_ready)),
      .i_c(completion),
      .o_u_valid(`FROST_CMO_OBSERVE(witness_u_valid)),
      .i_u_ready,
      .o_u(),
      .o_prefetch_room(),
      .o_accepted(),
      .o_accepted_opcode(),
      .o_accepted_q(),
      .o_accepted_addr(),
      .o_mem_req_valid(`FROST_CMO_OBSERVE(witness_mem_req)),
      .i_mem_req_ready(i_mem_ready),
      .o_mem_req_write(),
      .o_mem_req_addr(),
      .o_mem_req_data(),
      .o_mem_req_mask(),
      .o_mem_req_id(`FROST_CMO_OBSERVE(witness_mem_req_id)),
      .i_mem_resp_valid(i_mem_valid),
      .i_mem_resp_id(i_mem_id),
      .i_mem_resp_data('0),
      .i_mem_resp_error(i_mem_error),
      .o_perf_events(),
      .o_write_perf_events(),
      .o_fatal(),
      .o_fatal_addr()
  );
  `undef FROST_CMO_OBSERVE

`ifdef COHERENCE_HOME_CMO_FAST_COVER
  // Track a CleanBlock or FlushBlock that enters through FAST_TAG_LAUNCH
  // direct admission selection and direct tag launch without a parallel read,
  // allocates fill 0 on a dirty block, writes it back, and reaches GrantAck.
  localparam logic [3:0] CmoFillFree = 4'd0;
  localparam logic [3:0] CmoFillCmoGrant = 4'd11;
  logic f_cmo_direct_d_q;
  logic f_cmo_direct_lookup_q;
  logic f_cmo_fill0_fast_q;
  wire f_cmo_direct_d_clean_or_flush = home.completions.gen_fast_state.direct_d_select &&
      (demand.opcode == coherence_pkg::CleanBlock || demand.opcode == coherence_pkg::FlushBlock);
  wire f_cmo_direct_tag_clean_or_flush = home.direct_tag_valid && home.work_cmo &&
      !home.array_req_spec &&
      (home.work.opcode == coherence_pkg::CleanBlock ||
       home.work.opcode == coherence_pkg::FlushBlock);
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      f_cmo_direct_d_q <= 1'b0;
      f_cmo_direct_lookup_q <= 1'b0;
      f_cmo_fill0_fast_q <= 1'b0;
    end else begin
      if (f_cmo_direct_d_clean_or_flush) f_cmo_direct_d_q <= 1'b1;
      else if (home.completions.accept_work || !home.completions.work_selected_q)
        f_cmo_direct_d_q <= 1'b0;

      if (f_cmo_direct_tag_clean_or_flush && f_cmo_direct_d_q) f_cmo_direct_lookup_q <= 1'b1;
      else if (home.run && ((home.tag_request_valid && home.tag_request_ready) ||
                            home.direct_tag_valid || home.array_response))
        f_cmo_direct_lookup_q <= 1'b0;

      if (home.run && home.array_response && home.decision_fill && home.fill_free_index == '0)
        f_cmo_fill0_fast_q <= f_cmo_direct_lookup_q;
      else if (home.fill_phase_q[0] == CmoFillFree ||
               (home.run && home.forward_accept && home.forward_pick[0]))
        f_cmo_fill0_fast_q <= 1'b0;

      c_cmo_fast_dirty_grant :
      cover (home.run && home.forward_accept && home.forward_pick[0] &&
             home.fill_phase_q[0] == CmoFillCmoGrant && home.fill_dirty_q[0] &&
             !home.fill_cmo_inval_q[0] && f_cmo_fill0_fast_q);
    end
  end
`endif

`ifdef COHERENCE_HOME_ULTRA_PROOF
  // Inductive strengthening for the unbounded UltraRAM home control proof:
  // link the packed tag RAM's read pipeline, open parallel-read stages and
  // each engine's taken-parallel-read wait counter to the array's pipeline.
  localparam int unsigned UltraTagLatency = 3;
  localparam int unsigned UltraDataLatency = 6;
  localparam logic [2:0] PhaseTags = 3'd3;
  localparam logic [2:0] PhaseSelect = 3'd4;
  localparam logic [2:0] PhaseReply = 3'd5;
  wire [1:0] f_ultra_tag_pipe = {
    home.array.gen_tag_ultra.tags.read_valid_pipe[1],
    home.array.gen_tag_ultra.tags.read_valid_pipe[0]
  };
  wire [UltraDataLatency:0] f_ultra_stage_valid = home.array.read_valid_q & ~home.array.read_open_q;
  wire [3:0][2:0] f_ultra_stage_token = {
    home.array.read_token_q[6],
    home.array.read_token_q[5],
    home.array.read_token_q[4],
    home.array.read_token_q[3]
  };
  wire [1:0][3:0] f_ultra_spec_wait = {home.f_spec_wait_q[1], home.f_spec_wait_q[0]};
  wire [2:0][1:0] f_ultra_comp_buf = {
    home.completions.buffer_index_q[2],
    home.completions.buffer_index_q[1],
    home.completions.buffer_index_q[0]
  };
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (home.array.phase_q == PhaseTags) begin
        p_ultra_tag_count_range :
        assert (home.array.count_q != '0 && int'(home.array.count_q) <= UltraTagLatency);
        if (int'(home.array.count_q) < UltraTagLatency) begin
          p_ultra_tag_pipe0_clear : assert (!f_ultra_tag_pipe[0]);
          if (int'(home.array.count_q) == 1)
            p_ultra_tag_pipe1_clear : assert (!f_ultra_tag_pipe[1]);
        end
      end
      if (home.array.phase_q == PhaseSelect || home.array.phase_q == PhaseReply)
        p_ultra_tag_pipe_idle : assert (f_ultra_tag_pipe == '0);
      if (home.array.o_resp_valid)
        p_ultra_resp_way_range : assert (int'(home.array.o_resp_way) < WAYS);
      if (home.read_arbiter.selected_q)
        p_ultra_row_way_range : assert (int'(home.row_request.way) < WAYS);
      if (home.update_arbiter.selected_q)
        p_ultra_update_way_range : assert (int'(home.update_request.way) < WAYS);
      for (int engine = 0; engine < 2; engine++) assert (int'(home.engine_way[engine]) < WAYS);
      for (int put = 0; put < 2; put++) assert (int'(home.put_way_q[put]) < WAYS);
      if (home.run && home.array.FoldSelect)
        p_ultra_open_before_reply :
        assert (home.array.read_open_q[UltraDataLatency:UltraTagLatency] == '0);
      p_ultra_grant_next_range : assert (int'(home.completions.grant_next_q) < 3);
      if (home.completions.grant_selected_q) begin
        p_ultra_grant_slot_range : assert (int'(home.completions.grant_slot_q) < 3);
        p_ultra_grant_buf_range : assert (int'(home.completions.grant_buffer_q) < 3);
      end
      if (home.completions.work_selected_q)
        p_ultra_work_slot_range : assert (int'(home.completions.work_slot_q) < 3);
      for (int slot = 0; slot < 3; slot++)
      if (home.completions.buffer_owned_q[slot]) assert (int'(f_ultra_comp_buf[slot]) < 3);
      for (int engine = 0; engine < 2; engine++) begin
        if (home.f_spec_wait_valid_q[engine]) begin
          assert (int'(f_ultra_spec_wait[engine]) <= 3);
          assert (f_ultra_stage_valid[3+int'(f_ultra_spec_wait[engine])] &&
              f_ultra_stage_token[f_ultra_spec_wait[engine][1:0]] == 3'(engine));
        end
      end
    end
  end
`endif
endmodule
