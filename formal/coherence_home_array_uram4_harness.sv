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

// Four-way banked UltraRAM formal harness for coherence_home_array.
// Checks watched-byte preservation across explicit and kept parallel reads,
// array hazard and response invariants, held tag responses, tag-update
// service bounds, and bounded read/write service for a held contended row.
module coherence_home_array_uram4_harness #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 64,
    parameter int unsigned CACHE_BYTES = 512,
    parameter int unsigned WAYS = 4,
    parameter int unsigned TOKEN_BITS = 4,
    parameter bit ULTRA = 1'b1,
    parameter int unsigned TAG_READ_LATENCY = ULTRA ? 3 : 1,
    parameter int unsigned DATA_READ_LATENCY = ULTRA ? 6 : 2,
    parameter int unsigned DATA_WRITE_LATENCY = ULTRA ? 2 : 1,
    localparam int unsigned OffsetBits = $clog2(LINE_BYTES),
    localparam int unsigned Sets = CACHE_BYTES / (LINE_BYTES * WAYS),
    localparam int unsigned SetBits = $clog2(Sets),
    localparam int unsigned WayBits = WAYS > 1 ? $clog2(WAYS) : 1,
    localparam int unsigned WaySelBits = $clog2(WAYS),
    localparam int unsigned RowBits = SetBits + WaySelBits
) (
    input logic i_clk,
    input logic i_rst,
    output logic o_init_done,
    input logic i_req_valid,
    output logic o_req_ready,
    input logic [ADDR_WIDTH-1:0] i_req_addr,
    input logic [TOKEN_BITS-1:0] i_req_token,
    input logic i_req_spec,
    output logic [ADDR_WIDTH-1:0] o_query_addr,
    output logic [TOKEN_BITS-1:0] o_query_token,
    input logic [WAYS-1:0] i_exclude,
    output logic o_resp_valid,
    input logic i_resp_ready,
    input logic i_resp_claim,
    output logic [TOKEN_BITS-1:0] o_resp_token,
    output logic [(1 << TOKEN_BITS)-1:0] o_resp_token_onehot,
    output logic o_resp_hit,
    output logic o_resp_available,
    output logic o_resp_two_available,
    output logic [WayBits-1:0] o_resp_way,
    output logic [ADDR_WIDTH-1:0] o_resp_addr,
    output logic [1:0] o_resp_state,
    output logic [WAYS-1:0][ADDR_WIDTH-SetBits-OffsetBits-1:0] o_resp_tags,
    output logic o_resp_spec,
    input logic i_resp_keep,
    input logic i_read_valid,
    input logic i_read_offer,
    output logic o_read_ready,
    input logic [ADDR_WIDTH-1:0] i_read_addr,
    input logic [WayBits-1:0] i_read_way,
    input logic [TOKEN_BITS-1:0] i_read_token,
    output logic o_read_valid,
    output logic [TOKEN_BITS-1:0] o_read_token,
    output logic [8*LINE_BYTES-1:0] o_read_data,
    input logic i_update_valid,
    output logic o_update_ready,
    input logic [ADDR_WIDTH-1:0] i_update_addr,
    input logic [WayBits-1:0] i_update_way,
    input logic i_update_tag,
    input logic [1:0] i_update_state,
    input logic i_update_has_data,
    input logic [LINE_BYTES-1:0] i_update_mask,
    input logic [8*LINE_BYTES-1:0] i_update_data,
    input logic [TOKEN_BITS-1:0] i_update_token,
    output logic o_updated,
    output logic [TOKEN_BITS-1:0] o_updated_token,
    input logic [RowBits-1:0] i_watch_row
);
  coherence_home_array #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .CACHE_BYTES(CACHE_BYTES),
      .WAYS(WAYS),
      .TOKEN_BITS(TOKEN_BITS),
      .ULTRA(ULTRA),
      .TAG_READ_LATENCY(TAG_READ_LATENCY),
      .DATA_READ_LATENCY(DATA_READ_LATENCY),
      .DATA_WRITE_LATENCY(DATA_WRITE_LATENCY)
  ) dut (
      .i_clk,
      .i_rst,
      .o_init_done,
      .i_req_valid,
      .o_req_ready,
      .i_req_addr,
      .i_req_token,
      .i_req_spec,
      .o_query_addr,
      .o_query_token,
      .i_exclude,
      .o_resp_valid,
      .i_resp_ready,
      .i_resp_claim,
      .o_resp_token,
      .o_resp_token_onehot,
      .o_resp_hit,
      .o_resp_available,
      .o_resp_two_available,
      .o_resp_way,
      .o_resp_addr,
      .o_resp_state,
      .o_resp_tags,
      .o_resp_spec,
      .i_resp_keep,
      .i_read_valid,
      .i_read_offer,
      .o_read_ready,
      .i_read_addr,
      .i_read_way,
      .i_read_token,
      .o_read_valid,
      .o_read_token,
      .o_read_data,
      .i_update_valid,
      .o_update_ready,
      .i_update_addr,
      .i_update_way,
      .i_update_tag,
      .i_update_state,
      .i_update_has_data,
      .i_update_mask,
      .i_update_data,
      .i_update_token,
      .o_updated,
      .o_updated_token
  );

  logic f_past_valid = 1'b0;
  logic f_resp_stalled_q = 1'b0;
  // Latch an arbitrary watched row on the initial reset edge and hold it constant.
  logic [RowBits-1:0] f_row;
`ifdef COHERENCE_ARRAY_BYTE
  wire [OffsetBits-1:0] f_byte = OffsetBits'(`COHERENCE_ARRAY_BYTE);
`else
  (* anyconst *) logic [OffsetBits-1:0] f_byte;
`endif
  logic f_known_q = 1'b0;
  logic [7:0] f_value_q;
  logic [DATA_READ_LATENCY:0] f_check_q, f_open_q;
  logic [7:0] f_expected_q[DATA_READ_LATENCY+1];
  wire [SetBits-1:0] f_set = f_row[SetBits-1:0];
  wire [WayBits-1:0] f_way = WayBits'(f_row >> SetBits);
  localparam int unsigned ServiceBound = DATA_READ_LATENCY + DATA_WRITE_LATENCY + 5;
  logic [$clog2(ServiceBound+1)-1:0] f_read_wait_q, f_write_wait_q;
  localparam int unsigned TagServiceBound = TAG_READ_LATENCY + 4;
  logic [$clog2(TagServiceBound+1)-1:0] f_tag_wait_q;
  wire [DATA_READ_LATENCY:0] f_open_set_match = {
    dut.read_valid_q[6] && dut.read_open_q[6] && dut.read_set_q[6] == dut.write_set,
    dut.read_valid_q[5] && dut.read_open_q[5] && dut.read_set_q[5] == dut.write_set,
    dut.read_valid_q[4] && dut.read_open_q[4] && dut.read_set_q[4] == dut.write_set,
    dut.read_valid_q[3] && dut.read_open_q[3] && dut.read_set_q[3] == dut.write_set,
    dut.read_valid_q[2] && dut.read_open_q[2] && dut.read_set_q[2] == dut.write_set,
    dut.read_valid_q[1] && dut.read_open_q[1] && dut.read_set_q[1] == dut.write_set,
    dut.read_valid_q[0] && dut.read_open_q[0] && dut.read_set_q[0] == dut.write_set
  };

  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) begin
      assume (i_rst);
      f_row <= i_watch_row;
    end
    if (i_read_valid) assume (int'(i_read_way) < WAYS);
    if (i_update_valid) assume (int'(i_update_way) < WAYS);
    if (i_update_valid) assume (i_read_offer == i_read_valid);
    if (i_update_valid) assume (i_update_has_data == |i_update_mask);
    if (o_resp_valid && i_resp_ready && i_resp_claim) assume (o_resp_available);

    if (i_rst) f_resp_stalled_q <= 1'b0;
    else f_resp_stalled_q <= o_resp_valid && !i_resp_ready;

    if (f_past_valid && !i_rst) begin
      if (o_resp_valid) begin
        p_uram4_tag_hold0 : assert (dut.tag_rdata[0] == dut.tags_q[0]);
        p_uram4_tag_hold1 : assert (dut.tag_rdata[1] == dut.tags_q[1]);
        p_uram4_tag_hold2 : assert (dut.tag_rdata[2] == dut.tags_q[2]);
        p_uram4_tag_hold3 : assert (dut.tag_rdata[3] == dut.tags_q[3]);
      end
      p_uram4_token_onehot : assert (o_resp_token_onehot == (1 << TOKEN_BITS)'(1) << o_resp_token);
      if (o_resp_valid)
        p_uram4_resp_addr :
        assert (o_resp_addr == {o_resp_tags[o_resp_way], dut.set_q, {OffsetBits{1'b0}}});
      p_uram4_no_rw_collision :
      assert (!(dut.read_fire && dut.update_fire && |i_update_mask &&
                dut.read_row == dut.write_row));
      if (dut.update_fire && i_update_tag) p_uram4_no_tag_hazard : assert (!dut.tag_hazard);
      if (dut.spec_cycle) p_uram4_spec_no_read : assert (!dut.read_fire);
      if (dut.spec_fire)
        p_uram4_spec_no_write :
        assert (!(dut.update_fire && i_update_has_data && dut.write_set == dut.set_q));
      if (dut.update_fire && i_update_has_data)
        p_uram4_open_no_write : assert (f_open_set_match == '0);
      p_uram4_one_open : assert ($countones(dut.read_open_q) <= 1);
      p_uram4_open_valid : assert ((dut.read_open_q & ~dut.read_valid_q) == '0);
      p_uram4_final_open_after_stall :
      assert (!dut.read_open_q[DATA_READ_LATENCY] || f_resp_stalled_q);
      p_uram4_resp_spec_excludes_final :
      assert (!(o_resp_spec && dut.read_open_q[DATA_READ_LATENCY]));
    end

    if (i_rst) begin
      f_known_q <= 1'b0;
      f_check_q <= '0;
      f_open_q  <= '0;
    end else begin
      if (dut.update_fire && dut.write_row == f_row && i_update_mask[f_byte]) begin
        f_known_q <= 1'b1;
        f_value_q <= i_update_data[8*f_byte+:8];
      end
      f_check_q[0] <= f_known_q &&
          ((dut.read_fire && dut.read_row == f_row) || (dut.spec_fire && dut.set_q == f_set));
      f_open_q[0] <= dut.spec_fire;
      f_expected_q[0] <= f_value_q;
      for (int stage = 1; stage <= DATA_READ_LATENCY; stage++) begin
        f_check_q[stage] <= f_check_q[stage-1] && !(f_open_q[stage-1] && dut.resolve &&
            !(i_resp_keep && o_resp_way == f_way));
        f_open_q[stage] <= f_open_q[stage-1] && !dut.resolve;
        f_expected_q[stage] <= f_expected_q[stage-1];
      end
      if (f_known_q && dut.resolve && o_resp_spec && dut.set_q == f_set)
        p_uram4_open_spec :
        assert (|(f_check_q[DATA_READ_LATENCY-1:0] & f_open_q[DATA_READ_LATENCY-1:0]));
      if (f_check_q[DATA_READ_LATENCY] &&
          (!f_open_q[DATA_READ_LATENCY] ||
           (dut.resolve && o_resp_spec && i_resp_keep && o_resp_way == f_way))) begin
        p_uram4_read_valid : assert (o_read_valid);
        p_uram4_read_byte : assert (o_read_data[8*f_byte+:8] == f_expected_q[DATA_READ_LATENCY]);
      end
    end

    if (i_rst || !o_init_done || !dut.row_contended || i_update_tag ||
        (f_past_valid && dut.read_row != $past(
            dut.read_row
        ))) begin
      f_read_wait_q  <= '0;
      f_write_wait_q <= '0;
    end else begin
      f_read_wait_q  <= dut.read_fire ? '0 : f_read_wait_q + 1'b1;
      f_write_wait_q <= dut.update_fire ? '0 : f_write_wait_q + 1'b1;
      p_uram4_read_wait : assert (int'(f_read_wait_q) < ServiceBound);
      p_uram4_write_wait : assert (int'(f_write_wait_q) < ServiceBound);
    end

    if (i_rst || !o_init_done || !i_update_valid || !i_update_tag ||
        |i_update_mask || !i_resp_ready ||
        (f_past_valid && i_update_addr != $past(
            i_update_addr
        )))
      f_tag_wait_q <= '0;
    else begin
      f_tag_wait_q <= dut.update_fire ? '0 : f_tag_wait_q + 1'b1;
      p_uram4_tag_wait : assert (int'(f_tag_wait_q) < TagServiceBound);
    end

    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(o_resp_valid && !i_resp_ready)) begin
        p_uram4_resp_valid_held : assert (o_resp_valid);
        p_uram4_resp_payload_held :
        assert ({o_resp_token, o_resp_hit, o_resp_available, o_resp_two_available, o_resp_way,
            o_resp_addr, o_resp_state} == $past(
            {o_resp_token, o_resp_hit, o_resp_available, o_resp_two_available, o_resp_way,
             o_resp_addr, o_resp_state}
        ));
      end
    end
  end
endmodule
