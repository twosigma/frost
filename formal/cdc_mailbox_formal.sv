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

// Multiclock formal harness for cdc_mailbox coupled to cdc_reset_pair.
// Checks two-phase toggle handshake alternation, destination valid/payload
// hold-until-ready, cross-domain glitch immunity, and bit-exact payload
// delivery under genuinely free source and destination clocks (arbitrary phase,
// ratio, and stopped-clock intervals during reset) as well as staggered reset
// release and runtime reset re-assertion after traffic.
module cdc_mailbox_formal #(
    parameter int unsigned WIDTH = 16
) (
    (* gclk *) input logic gclk,
    input logic i_arst,
    input logic i_src_clk,
    input logic [WIDTH-1:0] i_src_data,
    input logic i_src_valid,
    input logic i_dst_clk,
    input logic i_dst_ready
);

  // Symbolic mode selector covering direct cdc_reset_pair wiring (as in
  // soc_top's gen_debug_slice_cdc.requests) and a 1-source-clock-delayed
  // cdc_reset_pair launch. nic_mac_cdc's nic_domain_reset (HOLD_CYCLES release
  // and soft per-domain resets) is not modelled here.
  (* anyconst *)logic use_nic_rst_skew;

  logic f_init_done = 1'b0;
  logic prev_src_clk = 1'b0;
  logic prev_dst_clk = 1'b0;
  logic prev_arst = 1'b1;

  always_ff @(posedge gclk) begin
    f_init_done  <= 1'b1;
    prev_src_clk <= i_src_clk;
    prev_dst_clk <= i_dst_clk;
    prev_arst    <= i_arst;
  end

  wire  src_clk_rose = !prev_src_clk && i_src_clk;
  wire  dst_clk_rose = !prev_dst_clk && i_dst_clk;

  // Optional 1-source-clock-delayed reset launch into cdc_reset_pair while
  // i_arst gates i_src_rst immediately.
  logic rst_for_dst_q = 1'b1;
  always_ff @(posedge i_src_clk) begin
    rst_for_dst_q <= i_arst;
  end

  wire  pair_arst = use_nic_rst_skew ? (!f_init_done ? 1'b1 : rst_for_dst_q) : i_arst;
  logic pair_a_rst;
  logic pair_b_rst;

  cdc_reset_pair u_reset_pair (
      .i_arst (pair_arst),
      .i_a_clk(i_src_clk),
      .i_b_clk(i_dst_clk),
      .o_a_rst(pair_a_rst),
      .o_b_rst(pair_b_rst)
  );

  wire  src_rst = use_nic_rst_skew ? (i_arst || pair_a_rst) : pair_a_rst;
  wire  dst_rst = pair_b_rst;

  logic prev_src_rst = 1'b1;
  logic prev_dst_rst = 1'b1;
  always_ff @(posedge gclk) begin
    prev_src_rst <= src_rst;
    prev_dst_rst <= dst_rst;
  end

  always_comb begin
    if (!f_init_done) begin
      assume (i_arst);
    end else if (use_nic_rst_skew && !src_clk_rose) begin
      // Core-synchronous reset source changes only on i_src_clk rising edges.
      assume (i_arst == prev_arst);
    end
    // Documented cdc_mailbox caller contract (cdc_mailbox.sv:18):
    // overlapping resets complete without new source traffic.
    if (src_rst || dst_rst) begin
      assume (!i_src_valid);
    end
  end

  logic             o_src_ready;
  logic             o_src_idle;
  logic [WIDTH-1:0] o_dst_data;
  logic             o_dst_valid;

  cdc_mailbox #(
      .WIDTH(WIDTH)
  ) dut (
      .i_src_clk  (i_src_clk),
      .i_src_rst  (src_rst),
      .i_src_data (i_src_data),
      .i_src_valid(i_src_valid),
      .o_src_ready(o_src_ready),
      .o_src_idle (o_src_idle),
      .i_dst_clk  (i_dst_clk),
      .i_dst_rst  (dst_rst),
      .o_dst_data (o_dst_data),
      .o_dst_valid(o_dst_valid),
      .i_dst_ready(i_dst_ready)
  );

  logic [      3:0] src_sent_cnt = '0;
  logic [      3:0] dst_rcvd_cnt = '0;
  logic [WIDTH-1:0] last_sent_data = '0;

  always_ff @(posedge i_src_clk) begin
    if (src_rst) begin
      src_sent_cnt <= '0;
    end else if (i_src_valid && o_src_ready) begin
      src_sent_cnt   <= src_sent_cnt + 4'd1;
      last_sent_data <= i_src_data;
    end
  end

  always_ff @(posedge i_dst_clk) begin
    if (dst_rst) begin
      dst_rcvd_cnt <= '0;
    end else if (o_dst_valid && i_dst_ready) begin
      dst_rcvd_cnt <= dst_rcvd_cnt + 4'd1;
      // Destination consumes only an in-flight transfer with intact payload.
      if (!src_rst) begin
        p_consume_matches_sent : assert (o_dst_data == last_sent_data);
      end
    end
  end

  logic             prev_dst_valid = 1'b0;
  logic             prev_dst_ready = 1'b0;
  logic [WIDTH-1:0] prev_dst_data = '0;

  // Track post-traffic runtime reset recovery for reachability covers.
  logic             saw_pre_rst_delivery = 1'b0;
  logic             saw_post_traffic_rst = 1'b0;

  always_ff @(posedge gclk) begin
    prev_dst_valid <= o_dst_valid;
    prev_dst_ready <= i_dst_ready;
    prev_dst_data  <= o_dst_data;
    if (f_init_done) begin
      if (!src_rst && !dst_rst && (dst_rcvd_cnt != '0)) begin
        saw_pre_rst_delivery <= 1'b1;
      end
      if (saw_pre_rst_delivery && i_arst) begin
        saw_post_traffic_rst <= 1'b1;
      end
    end
  end

  always_comb begin
    if (f_init_done && !use_nic_rst_skew && i_arst) begin
      // Asynchronous reset request immediately asserts both domain resets.
      p_reset_pair_async_assert : assert (src_rst && dst_rst);
    end

    if (f_init_done && !src_rst && !dst_rst) begin
      // At most one message is in flight; destination never leads source.
      p_at_most_one_inflight : assert ((src_sent_cnt - dst_rcvd_cnt) <= 4'd1);

      // Source never reports idle while an unconsumed transfer is in flight.
      if (o_src_idle) begin
        p_idle_only_after_delivery : assert (src_sent_cnt == dst_rcvd_cnt);
      end

      // Whenever destination valid is asserted, an unconsumed message is in
      // flight and o_dst_data equals its captured source payload.
      if (o_dst_valid) begin
        p_valid_implies_inflight : assert ((src_sent_cnt - dst_rcvd_cnt) == 4'd1);
        p_valid_payload_intact : assert (o_dst_data == last_sent_data);
      end

      // Destination valid and data hold steady across non-edge ticks and
      // unready destination clock edges.
      if (!prev_dst_rst && prev_dst_valid && !(dst_clk_rose && prev_dst_ready)) begin
        p_dst_hold_until_ready : assert (o_dst_valid && (o_dst_data == prev_dst_data));
      end
    end
  end

  always_ff @(posedge gclk) begin
    if (f_init_done && !src_rst && !dst_rst) begin
      // Reach two complete back-to-back toggle cycles (0->1 and 1->0) with backpressure.
      c_two_round_trips : cover ((dst_rcvd_cnt == 4'd2) && o_src_ready);

      // Reach destination holding valid across an unready destination clock edge.
      c_dst_backpressure_hold :
      cover (!prev_dst_rst && prev_dst_valid && !prev_dst_ready && dst_clk_rose);

      // Reach runtime reset re-assertion after traffic followed by a fresh post-reset round trip.
      c_post_traffic_reset_recovery :
      cover (saw_post_traffic_rst && (dst_rcvd_cnt == 4'd1) && o_src_ready);
    end
  end

endmodule
