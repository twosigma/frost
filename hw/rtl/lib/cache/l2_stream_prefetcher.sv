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

/*
 * l2_stream_prefetcher reads ahead of ascending line streams into the L2.
 * The cache hierarchy trains it on accepted L1D read misses. The coherent
 * wrapper trains it on accepted hart data GetS and GetM requests, including
 * home hits. Observations enter the stream table one cycle later.
 *
 * A table of STREAMS entries holds the last training line of each stream.
 * An observation on the line after an entry's confirms and advances it;
 * an observation on an entry's own line leaves it unchanged. With
 * IGNORE_BACKWARD, an observation up to 2 * DISTANCE - 1 lines behind an
 * entry in the same page also leaves the entries in place. Other lines
 * replace entries in rotation. Each confirmed entry requests up to DISTANCE
 * lines ahead, within the PAGE_BYTES page of its last training address.
 *
 * Each entry keeps its last line, that line plus one (so a successor is an
 * equality match), and how many lines after the last line it has requested.
 * An advance shifts that count down by one. The address of the next read is
 * the only wide addition, and it feeds the request register.
 *
 * The cache hierarchy serves requests as ordinary line reads. The coherent
 * wrapper sends protocol Prefetch requests and releases each identity on U.
 * Both paths discard returned data; the L2 fill serves later demands.
 * A registered request holds until acceptance. At most MAX_INFLIGHT reads
 * are outstanding, each under its own id. A new request loads only while
 * i_enable is set; one already loaded still goes out.
 */
module l2_stream_prefetcher #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned L2_LINE_BYTES = 64,
    parameter int unsigned STREAMS = 4,
    parameter int unsigned DISTANCE = 8,
    parameter int unsigned MAX_INFLIGHT = 4,
    parameter int unsigned ID_BITS = 3,
    parameter int unsigned PAGE_BYTES = 4096,
    parameter bit IGNORE_BACKWARD = 0
) (
    input logic i_clk,
    input logic i_rst,

    // A training address, on the cycle the caller accepts its request.
    input logic                  i_miss_valid,
    input logic [ADDR_WIDTH-1:0] i_miss_addr,
    // Loads a new request while set.
    input logic                  i_enable,

    // Line-port master: reads only.
    output logic                  o_req_valid,
    input  logic                  i_req_ready,
    output logic [ADDR_WIDTH-1:0] o_req_addr,
    output logic [   ID_BITS-1:0] o_req_id,
    input  logic                  i_resp_valid,
    input  logic [   ID_BITS-1:0] i_resp_id
`ifdef FORMAL
    , output logic [(1<<ID_BITS)-1:0] o_formal_busy
`endif
);

  localparam int unsigned LineOffBits = $clog2(L2_LINE_BYTES);
  localparam int unsigned LineBits = ADDR_WIDTH - LineOffBits;
  localparam int unsigned PageLineBits = $clog2(PAGE_BYTES / L2_LINE_BYTES);
  localparam int unsigned BackwardDistance =
      DISTANCE > (PAGE_BYTES / L2_LINE_BYTES) / 2 ?
      PAGE_BYTES / L2_LINE_BYTES - 1 : 2 * DISTANCE - 1;
  localparam int unsigned StreamBits = (STREAMS > 1) ? $clog2(STREAMS) : 1;
  localparam int unsigned AheadBits = $clog2(DISTANCE + 1);
  localparam int unsigned NumIds = 1 << ID_BITS;
  localparam int unsigned InflightBits = $clog2(NumIds + 1);

  initial begin
    if (MAX_INFLIGHT < 1 || MAX_INFLIGHT > NumIds)
      $fatal(1, "l2_stream_prefetcher: MAX_INFLIGHT must be 1..2**ID_BITS");
    if (DISTANCE < 1 || DISTANCE >= (PAGE_BYTES / L2_LINE_BYTES))
      $fatal(1, "l2_stream_prefetcher: DISTANCE must be 1..lines per page - 1");
    if ((1 << StreamBits) != STREAMS)
      $fatal(1, "l2_stream_prefetcher: STREAMS must be a power of two");
  end

  // ---- Observation, registered ------------------------------------------------
  // The offset within an L2 line does not matter.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [LineOffBits-1:0] miss_offset_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign miss_offset_unused = i_miss_addr[LineOffBits-1:0];

  logic                  obs_valid_q;
  logic [  LineBits-1:0] obs_line_q;
  logic [  LineBits-1:0] obs_line_p1_q;  // obs_line_q + 1
  logic [PageLineBits:0] obs_line_limit_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) obs_valid_q <= 1'b0;
    else obs_valid_q <= i_miss_valid;
    obs_line_q <= i_miss_addr[ADDR_WIDTH-1:LineOffBits];
    obs_line_p1_q <= i_miss_addr[ADDR_WIDTH-1:LineOffBits] + LineBits'(1);
    obs_line_limit_q <= (PageLineBits + 1)'(i_miss_addr[LineOffBits+:PageLineBits]) +
        (PageLineBits + 1)'(BackwardDistance);
  end

  // ---- Stream table -------------------------------------------------------------
  logic [STREAMS-1:0] st_valid_q;
  logic [STREAMS-1:0] st_conf_q;
  logic [LineBits-1:0] st_line_q[STREAMS];  // the stream's last missed line
  logic [LineBits-1:0] st_line_p1_q[STREAMS];  // st_line_q + 1
  logic [AheadBits-1:0] st_ahead_q[STREAMS];  // lines after it already read
  logic [StreamBits-1:0] st_victim_q;  // replaced next, in rotation

  logic [STREAMS-1:0] obs_succ, obs_same, obs_behind;
  logic [STREAMS-1:0] obs_preserved;
  always_comb begin
    for (int e = 0; e < int'(STREAMS); e++) begin
      obs_succ[e] = st_valid_q[e] && (obs_line_q == st_line_p1_q[e]);
      obs_same[e] = st_valid_q[e] && (obs_line_q == st_line_q[e]);
    end
  end
  for (genvar e = 0; e < STREAMS; e++) begin : gen_backward
    if (IGNORE_BACKWARD && BackwardDistance > 0 &&
        ((BackwardDistance + 1) & BackwardDistance) == 0) begin : gen_grouped
      localparam int unsigned OffsetBits = $clog2(BackwardDistance + 1);
      // A power-of-two window uses one offset-order comparison.
      (* keep = "true" *) logic lower_or_equal, preserved, valid_page;
      assign valid_page = st_valid_q[e] &&
          (obs_line_q >> PageLineBits) == (st_line_q[e] >> PageLineBits);
      assign lower_or_equal = obs_line_q[OffsetBits-1:0] <= st_line_q[e][OffsetBits-1:0];
      if (OffsetBits < PageLineBits) begin : gen_partial_page
        logic same_group, next_group;
        assign same_group = obs_line_q[PageLineBits-1:OffsetBits] ==
            st_line_q[e][PageLineBits-1:OffsetBits];
        assign next_group = {1'b0, st_line_q[e][PageLineBits-1:OffsetBits]} ==
            ({1'b0, obs_line_q[PageLineBits-1:OffsetBits]} +
             (PageLineBits - OffsetBits + 1)'(1));
        assign preserved = valid_page &&
            ((same_group && lower_or_equal) || (next_group && !lower_or_equal));
      end else begin : gen_full_page
        assign preserved = valid_page && lower_or_equal;
      end
      assign obs_preserved[e] = preserved;
      assign obs_behind[e] = preserved && !obs_same[e];
    end else begin : gen_general
      assign obs_behind[e] = IGNORE_BACKWARD && st_valid_q[e] &&
          (obs_line_q >> PageLineBits) == (st_line_q[e] >> PageLineBits) &&
          obs_line_q[PageLineBits-1:0] < st_line_q[e][PageLineBits-1:0] &&
          obs_line_limit_q >= (PageLineBits + 1)'(st_line_q[e][PageLineBits-1:0]);
      assign obs_preserved[e] = obs_same[e] | obs_behind[e];
    end
  end

  // ---- Request register ---------------------------------------------------------
  logic                    req_valid_q;
  logic [    LineBits-1:0] req_line_q;
  logic [     ID_BITS-1:0] req_id_q;
  logic [      NumIds-1:0] id_busy_q;  // loaded, response not yet back
  logic [InflightBits-1:0] inflight_q;

  assign o_req_valid = req_valid_q;
  assign o_req_addr  = {req_line_q, {LineOffBits{1'b0}}};
  assign o_req_id    = req_id_q;

`ifdef FORMAL
  assign o_formal_busy = id_busy_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      assert (inflight_q <= InflightBits'(MAX_INFLIGHT));
      assert ((id_busy_q >> MAX_INFLIGHT) == '0);
      if (req_valid_q) assert (id_busy_q[req_id_q]);
    end
  end
`endif

  logic req_fire;
  assign req_fire = req_valid_q && i_req_ready;

  // A confirmed entry with fewer than DISTANCE lines read ahead, whose next
  // line stays in the page of its last miss: the line's index within the page
  // plus the lines ahead plus one must stay below the page's line count.
  logic [STREAMS-1:0] cand;
  logic cand_any;
  logic [StreamBits-1:0] cand_sel;
  always_comb begin
    cand_any = 1'b0;
    cand_sel = '0;
    for (int e = 0; e < int'(STREAMS); e++) begin
      cand[e] = st_valid_q[e] && st_conf_q[e] && (st_ahead_q[e] < AheadBits'(DISTANCE)) &&
          ((PageLineBits + 1)'(st_line_q[e][PageLineBits-1:0]) +
           (PageLineBits + 1)'(st_ahead_q[e]) + (PageLineBits + 1)'(1) <
           (PageLineBits + 1)'(1 << PageLineBits));
    end
    for (int e = int'(STREAMS) - 1; e >= 0; e--) begin
      if (cand[e]) begin
        cand_any = 1'b1;
        cand_sel = StreamBits'(e);
      end
    end
  end

  // The lowest free id.
  logic [ID_BITS-1:0] free_id;
  always_comb begin
    free_id = '0;
    for (int n = int'(NumIds) - 1; n >= 0; n--) begin
      if (!id_busy_q[n]) free_id = ID_BITS'(n);
    end
  end

  // Load the register when it is empty or emptying, a stream has a line to
  // read, loads are enabled, and fewer than MAX_INFLIGHT reads are
  // outstanding. An observation that replaces the chosen entry this cycle
  // wins: nothing loads.
  logic load;
  logic obs_allocates;
  assign obs_allocates = obs_valid_q && !(|obs_succ) && !(|obs_preserved);
  assign load = (!req_valid_q || req_fire) && cand_any && i_enable &&
      !(obs_allocates && (st_victim_q == cand_sel)) &&
      (inflight_q < InflightBits'(MAX_INFLIGHT));

  // Per entry: a load adds one line ahead, and an advance moves the last line
  // up by one, so the lines ahead count one fewer.
  logic [STREAMS-1:0] st_loaded, st_advanced;
  always_comb begin
    for (int e = 0; e < int'(STREAMS); e++) begin
      st_loaded[e]   = load && (cand_sel == StreamBits'(e));
      st_advanced[e] = obs_valid_q && obs_succ[e];
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      st_valid_q  <= '0;
      st_conf_q   <= '0;
      st_victim_q <= '0;
      req_valid_q <= 1'b0;
      id_busy_q   <= '0;
      inflight_q  <= '0;
    end else begin
      for (int e = 0; e < int'(STREAMS); e++) begin
        if (st_advanced[e]) begin
          st_line_q[e]    <= obs_line_q;
          st_line_p1_q[e] <= obs_line_p1_q;
          st_conf_q[e]    <= 1'b1;
          if (!st_loaded[e] && (st_ahead_q[e] != '0))
            st_ahead_q[e] <= st_ahead_q[e] - AheadBits'(1);
        end else if (st_loaded[e]) begin
          st_ahead_q[e] <= st_ahead_q[e] + AheadBits'(1);
        end
      end
      if (obs_allocates) begin
        st_valid_q[st_victim_q]   <= 1'b1;
        st_conf_q[st_victim_q]    <= 1'b0;
        st_line_q[st_victim_q]    <= obs_line_q;
        st_line_p1_q[st_victim_q] <= obs_line_p1_q;
        st_ahead_q[st_victim_q]   <= '0;
        st_victim_q               <= st_victim_q + StreamBits'(1);
      end

      // Request register and ids.
      if (req_fire && !load) req_valid_q <= 1'b0;
      if (load) begin
        req_valid_q        <= 1'b1;
        req_line_q         <= st_line_q[cand_sel] + LineBits'(st_ahead_q[cand_sel]) + LineBits'(1);
        req_id_q           <= free_id;
        id_busy_q[free_id] <= 1'b1;
      end
      if (i_resp_valid) id_busy_q[i_resp_id] <= 1'b0;
      inflight_q <= inflight_q + InflightBits'(load) - InflightBits'(i_resp_valid);
    end
  end

`ifdef FORMAL
  // The backward window has strict lower and inclusive upper bounds.
  for (genvar e = 0; e < STREAMS; e++) begin : gen_window_check
    always_ff @(posedge i_clk)
      if (!i_rst && obs_valid_q) begin
        assert (obs_preserved[e] == (obs_same[e] | obs_behind[e]));
        assert (obs_behind[e] == (IGNORE_BACKWARD && st_valid_q[e] &&
            (obs_line_q >> PageLineBits) == (st_line_q[e] >> PageLineBits) &&
            obs_line_q[PageLineBits-1:0] < st_line_q[e][PageLineBits-1:0] &&
            (PageLineBits + 1)'(obs_line_q[PageLineBits-1:0]) +
            (PageLineBits + 1)'(BackwardDistance) >=
            (PageLineBits + 1)'(st_line_q[e][PageLineBits-1:0])));
      end
  end
  // A request stays in the page of the stream line it was loaded from.
  logic [LineBits-PageLineBits-1:0] f_req_page_q;
  always_ff @(posedge i_clk) begin
    if (load) f_req_page_q <= st_line_q[cand_sel][LineBits-1:PageLineBits];
    if (!i_rst && req_valid_q) assert (req_line_q[LineBits-1:PageLineBits] == f_req_page_q);
  end
`ifdef L2_STREAM_PREFETCHER_IDS
  // The parent returns only ids that are out, so the count follows them.
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (i_resp_valid) assert (id_busy_q[i_resp_id]);
      assert (inflight_q == InflightBits'($countones(id_busy_q)));
      if (req_valid_q) assert (id_busy_q[req_id_q]);
    end
  end
`endif
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      assert (!i_resp_valid || id_busy_q[i_resp_id]);
      assert (!load || !id_busy_q[free_id]);
      assert (inflight_q == InflightBits'($countones(id_busy_q)));
      for (int e = 0; e < int'(STREAMS); e++) begin
        if (st_valid_q[e]) assert (st_line_p1_q[e] == st_line_q[e] + LineBits'(1));
      end
    end
  end
`endif

`ifndef SYNTHESIS
`ifndef FORMAL
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) reset_seen_q <= 1'b1;
    if (reset_seen_q && !i_rst) begin
      if (i_resp_valid && !id_busy_q[i_resp_id])
        $error("l2_stream_prefetcher: response for id %0d with no read out", i_resp_id);
      if (load && id_busy_q[free_id]) $error("l2_stream_prefetcher: no free id for a load");
      if (inflight_q != InflightBits'($countones(id_busy_q)))
        $error("l2_stream_prefetcher: in-flight count %0d disagrees with ids", inflight_q);
      for (int e = 0; e < int'(STREAMS); e++) begin
        if (st_valid_q[e] && (st_line_p1_q[e] != st_line_q[e] + LineBits'(1)))
          $error("l2_stream_prefetcher: entry %0d's line plus one is stale", e);
      end
    end
  end
`endif
`endif

endmodule : l2_stream_prefetcher
