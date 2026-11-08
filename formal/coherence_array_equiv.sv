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

// coherence_array and coherence_array_reference take the same inputs and
// must produce the same outputs on every cycle. Inputs are arbitrary except
// that an insertion names the way of the last lookup response, as the L1D
// asserts for every grant installation (p_insert_lookup_way). With DATA_BYTE
// set, response data is compared in that byte lane, in rows written since
// the first reset (the data RAMs have no initial contents); every lane has
// the same logic, so a lane keeps only its own data in the proof.
module coherence_array_equiv #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned CACHE_BYTES = 64,
    parameter int unsigned WAYS = 1,
    parameter bit BIMODAL_INSERT = 1'b0,
    parameter bit ULTRA = 1'b0,
    // The compared byte lane of the response data, or -1 for none.
    parameter int DATA_BYTE = -1,
    localparam int unsigned LineBytes = 32,
    localparam int unsigned WayBits = WAYS > 1 ? $clog2(WAYS) : 1,
    localparam int unsigned Sets = CACHE_BYTES / (LineBytes * WAYS),
    localparam int unsigned SetBits = $clog2(Sets),
    localparam int unsigned Rows = Sets * WAYS
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_req_valid,
    input logic [ADDR_WIDTH-1:0] i_req_addr,
    input logic [WAYS-1:0] i_req_exclude,
    input logic i_req_visit,
    input logic [WayBits-1:0] i_req_way,
    input logic i_req_skip_data_on_hit,
    input logic i_req_data_if_modified,
    input logic i_req_data_if_hit,
    input logic i_req_data_if_victim_modified,
    input logic i_req_no_touch,
    input logic i_resp_ready,
    input logic i_update_valid,
    input logic [ADDR_WIDTH-1:0] i_update_addr,
    input logic [WayBits-1:0] i_update_way,
    input logic [1:0] i_update_state,
    input logic i_update_insert,
    input logic i_update_touch,
    input logic [LineBytes-1:0] i_update_mask,
    input logic [8*LineBytes-1:0] i_update_data
);
  logic f_past_valid = 1'b0;
  logic init_done[2], req_ready[2], update_ready[2], resp_valid[2], resp_hit[2];
  logic resp_available[2], resp_data_valid[2];
  logic [WayBits-1:0] resp_way[2];
  logic [ADDR_WIDTH-1:0] resp_addr[2];
  logic [1:0] resp_state[2];
  logic [8*LineBytes-1:0] resp_data[2];

  coherence_array #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LineBytes),
      .CACHE_BYTES(CACHE_BYTES),
      .WAYS(WAYS),
      .BIMODAL_INSERT(BIMODAL_INSERT),
      .ULTRA(ULTRA)
  ) array (
      .i_clk,
      .i_rst,
      .o_init_done(init_done[0]),
      .i_req_valid,
      .o_req_ready(req_ready[0]),
      .i_req_addr,
      .i_req_exclude,
      .i_req_visit,
      .i_req_way,
      .i_req_skip_data_on_hit,
      .i_req_data_if_modified,
      .i_req_data_if_hit,
      .i_req_data_if_victim_modified,
      .i_req_no_touch,
      .o_resp_valid(resp_valid[0]),
      .i_resp_ready,
      .o_resp_hit(resp_hit[0]),
      .o_resp_available(resp_available[0]),
      .o_resp_way(resp_way[0]),
      .o_resp_addr(resp_addr[0]),
      .o_resp_state(resp_state[0]),
      .o_resp_data_valid(resp_data_valid[0]),
      .o_resp_data(resp_data[0]),
      .i_update_valid,
      .o_update_ready(update_ready[0]),
      .i_update_addr,
      .i_update_way,
      .i_update_state,
      .i_update_insert,
      .i_update_touch,
      .i_update_mask,
      .i_update_data
  );

  coherence_array_reference #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LineBytes),
      .CACHE_BYTES(CACHE_BYTES),
      .WAYS(WAYS),
      .BIMODAL_INSERT(BIMODAL_INSERT),
      .ULTRA(ULTRA)
  ) reference (
      .i_clk,
      .i_rst,
      .o_init_done(init_done[1]),
      .i_req_valid,
      .o_req_ready(req_ready[1]),
      .i_req_addr,
      .i_req_exclude,
      .i_req_visit,
      .i_req_way,
      .i_req_skip_data_on_hit,
      .i_req_data_if_modified,
      .i_req_data_if_hit,
      .i_req_data_if_victim_modified,
      .i_req_no_touch,
      .o_resp_valid(resp_valid[1]),
      .i_resp_ready,
      .o_resp_hit(resp_hit[1]),
      .o_resp_available(resp_available[1]),
      .o_resp_way(resp_way[1]),
      .o_resp_addr(resp_addr[1]),
      .o_resp_state(resp_state[1]),
      .o_resp_data_valid(resp_data_valid[1]),
      .o_resp_data(resp_data[1]),
      .i_update_valid,
      .o_update_ready(update_ready[1]),
      .i_update_addr,
      .i_update_way,
      .i_update_state,
      .i_update_insert,
      .i_update_touch,
      .i_update_mask,
      .i_update_data
  );

  // Rows whose compared byte was written since the first reset, by {way, set}.
  localparam int unsigned Lane = DATA_BYTE < 0 ? 0 : DATA_BYTE;
  logic [Rows-1:0] written_q;
  logic [WayBits-1:0] lookup_way_q;
  wire [SetBits-1:0] update_set = i_update_addr[5+:SetBits];
  wire [SetBits-1:0] response_set = resp_addr[1][5+:SetBits];
  wire [$clog2(
Rows
)-1:0] response_row = WAYS > 1 ? $clog2(
      Rows
  )'({resp_way[1], response_set}) : $clog2(
      Rows
  )'(response_set);
  wire [$clog2(
Rows
)-1:0] update_row = WAYS > 1 ? $clog2(
      Rows
  )'({i_update_way, update_set}) : $clog2(
      Rows
  )'(update_set);
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) begin
      written_q <= '0;
      lookup_way_q <= '0;
    end else begin
      if (i_update_valid && update_ready[1] && i_update_mask[Lane]) written_q[update_row] <= 1'b1;
      if (resp_valid[1] && i_resp_ready) lookup_way_q <= resp_way[1];
    end
  end
  always_comb begin
    if (!f_past_valid) assume (i_rst);
    if (i_update_valid && i_update_insert) assume (i_update_way == lookup_way_q);
  end

  wire data_mismatch = DATA_BYTE >= 0 && written_q[response_row] &&
      resp_data[0][8*Lane+:8] != resp_data[1][8*Lane+:8];
  always_ff @(posedge i_clk) begin
    if (f_past_valid) begin
      p_equiv_ready :
      assert (init_done[0] == init_done[1] && req_ready[0] == req_ready[1] &&
          update_ready[0] == update_ready[1]);
      p_equiv_response :
      assert (resp_valid[0] == resp_valid[1] &&
          resp_hit[0] == resp_hit[1] && resp_available[0] == resp_available[1] &&
          resp_way[0] == resp_way[1] && resp_addr[0] == resp_addr[1] &&
          resp_state[0] == resp_state[1] && resp_data_valid[0] == resp_data_valid[1]);
      if (resp_valid[1] && resp_data_valid[1]) p_equiv_data : assert (!data_mismatch);
      c_equiv_data_hit :
      cover (resp_valid[1] && resp_data_valid[1] && resp_hit[1] && written_q[response_row]);
      c_equiv_insert : cover (i_update_valid && update_ready[1] && i_update_insert);
    end
  end
endmodule
