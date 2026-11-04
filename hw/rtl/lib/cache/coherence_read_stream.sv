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

// Three adjacent demand misses confirm an ascending stream of 32-byte sectors.
// The cursor stays within eight sectors and within the demand's 4 KiB page.
module coherence_read_stream #(
    parameter int unsigned ADDR_WIDTH = 32
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_cancel,
    input logic i_demand_valid,
    input logic i_demand_miss,
    input logic [ADDR_WIDTH-1:0] i_demand_addr,
    input logic i_consume,
    output logic o_valid,
    output logic [ADDR_WIDTH-1:0] o_addr,
    output logic o_confirmed,
    output logic [ADDR_WIDTH-1:0] o_frontier,
    output logic o_replace
);
  logic seeded_q, pair_seen_q, confirmed_q;
  logic [ADDR_WIDTH-1:12] page_q;
  logic [6:0] frontier_q;
  logic [7:0] cursor_q, cursor_next;
  logic same_sector, adjacent, advance;

  assign same_sector = seeded_q && i_demand_addr[ADDR_WIDTH-1:12] == page_q &&
      i_demand_addr[11:5] == frontier_q;
  assign adjacent = seeded_q && i_demand_addr[ADDR_WIDTH-1:12] == page_q &&
      {1'b0, i_demand_addr[11:5]} == {1'b0, frontier_q} + 8'd1;
  assign advance = i_demand_valid && adjacent && (confirmed_q || i_demand_miss);
  assign o_replace = i_demand_valid && i_demand_miss && !same_sector && !adjacent;
  assign o_confirmed = confirmed_q;
  assign o_frontier = {page_q, frontier_q, 5'b0};
  assign o_addr = {page_q, cursor_q[6:0], 5'b0};
  assign o_valid = confirmed_q && !cursor_q[7] &&
      cursor_q > {1'b0, frontier_q} && cursor_q <= {1'b0, frontier_q} + 8'd8;

  always_comb begin
    cursor_next = cursor_q;
    if (i_consume && o_valid) cursor_next = cursor_q + 8'd1;
    if (advance && (!confirmed_q || cursor_next <= {1'b0, i_demand_addr[11:5]}))
      cursor_next = {1'b0, i_demand_addr[11:5]} + 8'd1;
  end
  always_ff @(posedge i_clk) begin
    if (i_rst || i_cancel) begin
      seeded_q <= 1'b0;
      pair_seen_q <= 1'b0;
      confirmed_q <= 1'b0;
      page_q <= '0;
      frontier_q <= '0;
      cursor_q <= '0;
    end else if (o_replace) begin
      seeded_q <= 1'b1;
      pair_seen_q <= 1'b0;
      confirmed_q <= 1'b0;
      page_q <= i_demand_addr[ADDR_WIDTH-1:12];
      frontier_q <= i_demand_addr[11:5];
      cursor_q <= {1'b0, i_demand_addr[11:5]} + 8'd1;
    end else begin
      cursor_q <= cursor_next;
      if (advance) begin
        confirmed_q <= confirmed_q || pair_seen_q;
        pair_seen_q <= 1'b1;
        frontier_q  <= i_demand_addr[11:5];
      end
    end
  end

`ifdef FORMAL
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid) begin
      assert (!confirmed_q || pair_seen_q);
      assert (!pair_seen_q || seeded_q);
      if (o_valid) begin
        assert (o_confirmed);
        assert (o_addr[ADDR_WIDTH-1:12] == o_frontier[ADDR_WIDTH-1:12]);
        assert (o_addr > o_frontier && o_addr - o_frontier <= ADDR_WIDTH'(256));
        assert (o_addr[4:0] == 0);
      end
      if ($past(i_rst || i_cancel)) begin
        assert (!seeded_q && !pair_seen_q && !o_valid && !o_confirmed);
      end else if ($past(o_replace)) begin
        assert (seeded_q && !pair_seen_q && !o_confirmed);
        assert (o_frontier == {$past(i_demand_addr[ADDR_WIDTH-1:5]), 5'b0});
      end else begin
        if (o_confirmed && !$past(o_confirmed))
          assert ($past(advance && i_demand_miss && seeded_q && pair_seen_q));
        if ($past(advance)) begin
          assert (o_frontier == {$past(i_demand_addr[ADDR_WIDTH-1:5]), 5'b0});
          assert (pair_seen_q);
          assert (confirmed_q == $past(confirmed_q || pair_seen_q));
        end else begin
          assert ($stable(o_frontier));
          assert ($stable(pair_seen_q) && $stable(confirmed_q));
        end
        if (!$past(advance || (i_consume && o_valid))) assert ($stable(cursor_q));
        if ($past(i_consume && o_valid) && !$past(advance))
          assert (cursor_q == $past(cursor_q) + 8'd1);
      end
      cover (o_valid && i_consume && advance);
      cover (confirmed_q && cursor_q == 128);
    end
  end
`endif
endmodule
