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

// Formal harness for nic_dma_front.
// Verifies aperture enforcement, unique DMA ID allocation, per-engine SIDE_CAP
// bounds, same-line read/write ordering exclusion, exact owner/kind/tag routing
// on completions and refusals, response conservation across stop drains
// (including requests presented during raw i_stop), STARVATION_LIMIT TX
// fairness, and HOLD_LIMIT peer-engine backpressure.
module nic_dma_front_formal #(
    parameter int unsigned        ADDR_WIDTH       = 8,
    parameter int unsigned        LINE_BYTES       = 4,
    parameter int unsigned        NUM_ENTRIES      = 4,
    parameter int unsigned        SIDE_CAP         = 3,
    parameter int unsigned        STARVATION_LIMIT = 2,
    parameter int unsigned        HOLD_LIMIT       = 3,
    parameter int unsigned        TAG_BITS         = 3,
    parameter logic        [63:0] APERTURE_BASE    = 64'h0000_0040,
    parameter logic        [63:0] APERTURE_BYTES   = 64'h0000_0080
) (
    input logic                                             i_clk,
    input logic                                             i_rst,
    input logic                                             i_stop,
    input logic [                    1:0]                   i_req_valid,
    input logic [                    1:0]                   i_req_write,
    input logic [                    1:0][  ADDR_WIDTH-1:0] i_req_addr,
    input logic [                    1:0][LINE_BYTES*8-1:0] i_req_wdata,
    input logic [                    1:0][  LINE_BYTES-1:0] i_req_wstrb,
    input logic [                    1:0][             1:0] i_req_kind,
    input logic [                    1:0][    TAG_BITS-1:0] i_req_tag,
    input logic                                             i_dma_req_ready,
    input logic                                             i_dma_resp_valid,
    input logic                                             i_dma_resp_error,
    input logic [$clog2(NUM_ENTRIES)-1:0]                   i_dma_resp_id,
    input logic [       LINE_BYTES*8-1:0]                   i_dma_resp_rdata
);

  localparam int unsigned IdBits     = (NUM_ENTRIES > 1) ? $clog2(NUM_ENTRIES) : 1;
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam int unsigned LineBits   = ADDR_WIDTH - OffsetBits;
  localparam int unsigned CountBits  = $clog2(NUM_ENTRIES + 3);
  localparam int unsigned HoldBits   = $clog2(HOLD_LIMIT + 1);
  localparam int unsigned WaitBits   = $clog2(STARVATION_LIMIT + 1);

  logic                                  o_idle;
  logic [             1:0]               o_req_ready;
  logic [             1:0]               o_resp_valid;
  logic [             1:0][         1:0] o_resp_kind;
  logic [             1:0][TAG_BITS-1:0] o_resp_tag;
  logic [             1:0]               o_resp_error;
  logic [LINE_BYTES*8-1:0]               o_resp_rdata;
  logic                                  o_dma_req_valid;
  logic                                  o_dma_req_write;
  logic [  ADDR_WIDTH-1:0]               o_dma_req_addr;
  logic [LINE_BYTES*8-1:0]               o_dma_req_wdata;
  logic [  LINE_BYTES-1:0]               o_dma_req_wstrb;
  logic [      IdBits-1:0]               o_dma_req_id;
  logic [             1:0]               o_dma_req_kind;

  nic_dma_front #(
      .ADDR_WIDTH      (ADDR_WIDTH),
      .LINE_BYTES      (LINE_BYTES),
      .NUM_ENTRIES     (NUM_ENTRIES),
      .SIDE_CAP        (SIDE_CAP),
      .STARVATION_LIMIT(STARVATION_LIMIT),
      .HOLD_LIMIT      (HOLD_LIMIT),
      .TAG_BITS        (TAG_BITS),
      .APERTURE_BASE   (APERTURE_BASE),
      .APERTURE_BYTES  (APERTURE_BYTES)
  ) dut (
      .i_clk           (i_clk),
      .i_rst           (i_rst),
      .i_stop          (i_stop),
      .o_idle          (o_idle),
      .i_req_valid     (i_req_valid),
      .o_req_ready     (o_req_ready),
      .i_req_write     (i_req_write),
      .i_req_addr      (i_req_addr),
      .i_req_wdata     (i_req_wdata),
      .i_req_wstrb     (i_req_wstrb),
      .i_req_kind      (i_req_kind),
      .i_req_tag       (i_req_tag),
      .o_resp_valid    (o_resp_valid),
      .o_resp_kind     (o_resp_kind),
      .o_resp_tag      (o_resp_tag),
      .o_resp_error    (o_resp_error),
      .o_resp_rdata    (o_resp_rdata),
      .o_dma_req_valid (o_dma_req_valid),
      .i_dma_req_ready (i_dma_req_ready),
      .o_dma_req_write (o_dma_req_write),
      .o_dma_req_addr  (o_dma_req_addr),
      .o_dma_req_wdata (o_dma_req_wdata),
      .o_dma_req_wstrb (o_dma_req_wstrb),
      .o_dma_req_id    (o_dma_req_id),
      .o_dma_req_kind  (o_dma_req_kind),
      .i_dma_resp_valid(i_dma_resp_valid),
      .i_dma_resp_error(i_dma_resp_error),
      .i_dma_resp_id   (i_dma_resp_id),
      .i_dma_resp_rdata(i_dma_resp_rdata)
  );

  // Start in reset on cycle 0; reset may re-assert synchronously on any cycle.
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;
  always_comb begin
    if (!f_past_valid) assume (i_rst);
  end

  // External tracker of outstanding DMA transactions and per-engine requests.
  logic [NUM_ENTRIES-1:0]                 f_dma_live = '0;
  logic [NUM_ENTRIES-1:0]                 f_dma_owner = '0;
  logic [NUM_ENTRIES-1:0]                 f_dma_owner_known = '0;
  logic [NUM_ENTRIES-1:0]                 f_dma_write = '0;
  logic [   LineBits-1:0]                 f_dma_line                    [NUM_ENTRIES];
  logic [            1:0]                 f_dma_kind                    [NUM_ENTRIES];
  logic [   TAG_BITS-1:0]                 f_dma_tag                     [NUM_ENTRIES];

  logic [            1:0]                 f_buf_valid = '0;
  logic                                   f_buf_ambig = 1'b0;
  logic [            1:0][           1:0] f_buf_kind = '0;
  logic [            1:0][  TAG_BITS-1:0] f_buf_tag = '0;
  logic [            1:0][ADDR_WIDTH-1:0] f_buf_addr = '0;
  logic [            1:0]                 f_buf_write = '0;
  logic [            1:0][ CountBits-1:0] f_eng_outstanding = '0;

  // Independent HOLD_LIMIT and STARVATION_LIMIT fairness trackers.
  logic [            1:0]                 f_exact_conflict_q = '0;
  logic [            1:0][  HoldBits-1:0] f_exact_hold_cnt = '0;
  logic                                   tx_definitely_avail_q = 1'b0;
  logic [   WaitBits-1:0]                 f_tx_starve_cnt = '0;
  logic                                   prev_tx_port_refused_q = 1'b0;

  // Documented downstream DMA fabric contract: responses return only for live
  // in-range DMA IDs (nic_dma_front.sv:402-406). Engine i_req_valid is
  // completely unconstrained, including during raw i_stop.
  always_comb begin
    if (!i_rst && i_dma_resp_valid) begin
      assume (32'(i_dma_resp_id) < NUM_ENTRIES);
      assume (f_dma_live[i_dma_resp_id]);
    end
  end

  function automatic logic f_in_aperture(input logic [ADDR_WIDTH-1:0] a);
    f_in_aperture = (65'(a) >= 65'(APERTURE_BASE)) &&
        (65'(a) < (65'(APERTURE_BASE) + 65'(APERTURE_BYTES)));
  endfunction

  wire fire_rx_match = f_buf_valid[0] && (o_dma_req_addr == f_buf_addr[0]) &&
      (o_dma_req_write == f_buf_write[0]) && (o_dma_req_kind == f_buf_kind[0]);
  wire fire_tx_match = f_buf_valid[1] && (o_dma_req_addr == f_buf_addr[1]) &&
      (o_dma_req_write == f_buf_write[1]) && (o_dma_req_kind == f_buf_kind[1]);

  logic stop_d = 1'b0;
  always_ff @(posedge i_clk) stop_d <= i_rst ? 1'b0 : i_stop;

  wire dma_fire = o_dma_req_valid && i_dma_req_ready;
  wire rx_fires = dma_fire && !f_buf_ambig && fire_rx_match && !fire_tx_match;
  wire tx_fires = dma_fire && !f_buf_ambig && fire_tx_match && !fire_rx_match;

  logic [1:0] load_in_ap;
  logic [1:0] f_buf_valid_next;
  logic [1:0][ADDR_WIDTH-1:0] f_buf_addr_next;
  logic [1:0] f_buf_write_next;
  logic [NUM_ENTRIES-1:0] f_dma_live_next;
  logic [NUM_ENTRIES-1:0] f_dma_write_next;
  logic [LineBits-1:0] f_dma_line_next[NUM_ENTRIES];
  logic [1:0] exact_conflict_for_next;
  logic f_buf_ambig_next;
  logic tx_definitely_avail_next;

  always_comb begin
    f_dma_live_next  = f_dma_live;
    f_dma_write_next = f_dma_write;
    for (int k = 0; k < int'(NUM_ENTRIES); k++) begin
      f_dma_line_next[k] = f_dma_line[k];
    end
    if (i_dma_resp_valid) begin
      f_dma_live_next[i_dma_resp_id] = 1'b0;
    end
    if (dma_fire) begin
      f_dma_live_next[o_dma_req_id]  = 1'b1;
      f_dma_write_next[o_dma_req_id] = o_dma_req_write;
      f_dma_line_next[o_dma_req_id]  = o_dma_req_addr[ADDR_WIDTH-1:OffsetBits];
    end

    f_buf_ambig_next = f_buf_ambig;
    if (o_idle || stop_d) f_buf_ambig_next = 1'b0;
    if (dma_fire && !(!f_buf_ambig && (fire_rx_match ^ fire_tx_match))) begin
      if (!stop_d) f_buf_ambig_next = 1'b1;
    end

    for (int e = 0; e < 2; e++) begin
      load_in_ap[e] = i_req_valid[e] && o_req_ready[e] && f_in_aperture(i_req_addr[e]);
      if (stop_d) begin
        f_buf_valid_next[e] = 1'b0;
      end else begin
        f_buf_valid_next[e] =
            (((o_idle || stop_d) ? 1'b0 : f_buf_valid[e]) && !((e == 0) ? rx_fires : tx_fires)) ||
            load_in_ap[e];
      end
      f_buf_addr_next[e] = load_in_ap[e] ? i_req_addr[e] : f_buf_addr[e];
      f_buf_write_next[e] = load_in_ap[e] ? i_req_write[e] : f_buf_write[e];

      exact_conflict_for_next[e] = 1'b0;
      if (!f_buf_ambig_next && f_buf_valid_next[e]) begin
        for (int k = 0; k < int'(NUM_ENTRIES); k++) begin
          if (f_dma_live_next[k] && (f_dma_write_next[k] != f_buf_write_next[e]) &&
              (f_dma_line_next[k] == f_buf_addr_next[e][ADDR_WIDTH-1:OffsetBits])) begin
            exact_conflict_for_next[e] = 1'b1;
          end
        end
      end
    end

    // TX is guaranteed eligible and unvetoed next cycle when already buffered
    // this cycle (not newly loaded), neither stop_d nor raw i_stop is high,
    // at least one DMA entry is free next cycle, and no live entry conflicts
    // on TX's exact cache line.
    tx_definitely_avail_next = !f_buf_ambig_next && !o_idle && f_buf_valid[1] && !tx_fires &&
        !stop_d && !i_stop && !(&f_dma_live_next) && !exact_conflict_for_next[1];
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      f_dma_live             <= '0;
      f_dma_owner            <= '0;
      f_dma_owner_known      <= '0;
      f_dma_write            <= '0;
      f_buf_valid            <= '0;
      f_buf_ambig            <= 1'b0;
      f_eng_outstanding      <= '0;
      f_exact_conflict_q     <= '0;
      f_exact_hold_cnt       <= '0;
      tx_definitely_avail_q  <= 1'b0;
      f_tx_starve_cnt        <= '0;
      prev_tx_port_refused_q <= 1'b0;
    end else begin
      f_buf_ambig           <= f_buf_ambig_next;
      f_exact_conflict_q    <= exact_conflict_for_next;
      tx_definitely_avail_q <= tx_definitely_avail_next;

      for (int e = 0; e < 2; e++) begin
        if (f_buf_ambig || !f_buf_valid[e]) begin
          f_exact_hold_cnt[e] <= '0;
        end else if (f_exact_conflict_q[e] && (f_exact_hold_cnt[e] != HoldBits'(HOLD_LIMIT))) begin
          f_exact_hold_cnt[e] <= f_exact_hold_cnt[e] + HoldBits'(1);
        end
      end

      if (f_buf_ambig_next || tx_fires) begin
        f_tx_starve_cnt <= '0;
      end else if (rx_fires && tx_definitely_avail_q &&
                   (f_tx_starve_cnt != WaitBits'(STARVATION_LIMIT))) begin
        f_tx_starve_cnt <= f_tx_starve_cnt + WaitBits'(1);
      end

      prev_tx_port_refused_q <= o_dma_req_valid && !i_dma_req_ready && fire_tx_match;

      if (i_dma_resp_valid) begin
        f_dma_live[i_dma_resp_id]        <= 1'b0;
        f_dma_owner_known[i_dma_resp_id] <= 1'b0;
      end
      if (dma_fire) begin
        f_dma_live[o_dma_req_id]  <= 1'b1;
        f_dma_write[o_dma_req_id] <= o_dma_req_write;
        f_dma_line[o_dma_req_id]  <= o_dma_req_addr[ADDR_WIDTH-1:OffsetBits];
        f_dma_kind[o_dma_req_id]  <= o_dma_req_kind;
        if (!f_buf_ambig && fire_rx_match && !fire_tx_match) begin
          f_dma_owner_known[o_dma_req_id] <= 1'b1;
          f_dma_owner[o_dma_req_id]       <= 1'b0;
          f_dma_tag[o_dma_req_id]         <= f_buf_tag[0];
        end else if (!f_buf_ambig && fire_tx_match && !fire_rx_match) begin
          f_dma_owner_known[o_dma_req_id] <= 1'b1;
          f_dma_owner[o_dma_req_id]       <= 1'b1;
          f_dma_tag[o_dma_req_id]         <= f_buf_tag[1];
        end else begin
          f_dma_owner_known[o_dma_req_id] <= 1'b0;
        end
      end
      f_buf_valid <= f_buf_valid_next;
      for (int e = 0; e < 2; e++) begin
        if ((i_req_valid[e] && o_req_ready[e]) && !o_resp_valid[e]) begin
          f_eng_outstanding[e] <= f_eng_outstanding[e] + CountBits'(1);
        end else if (!(i_req_valid[e] && o_req_ready[e]) && o_resp_valid[e]) begin
          f_eng_outstanding[e] <= f_eng_outstanding[e] - CountBits'(1);
        end

        if (load_in_ap[e]) begin
          f_buf_addr[e]  <= i_req_addr[e];
          f_buf_write[e] <= i_req_write[e];
          f_buf_kind[e]  <= i_req_kind[e];
          f_buf_tag[e]   <= i_req_tag[e];
        end
      end
    end
  end

  logic same_line_rw_ok;
  always_comb begin
    same_line_rw_ok = 1'b1;
    for (int k = 0; k < int'(NUM_ENTRIES); k++) begin
      if (o_dma_req_valid && f_dma_live[k] && (f_dma_write[k] != o_dma_req_write) &&
          (f_dma_line[k] == o_dma_req_addr[ADDR_WIDTH-1:OffsetBits])) begin
        same_line_rw_ok = 1'b0;
      end
    end
  end

  always_comb begin
    if (f_past_valid && !i_rst) begin
      // Out-of-aperture addresses never reach the coherent DMA port.
      if (o_dma_req_valid) begin
        p_dma_req_in_aperture : assert (f_in_aperture(o_dma_req_addr));

        // Issued DMA IDs are always currently free.
        p_dma_id_not_live : assert (!f_dma_live[o_dma_req_id]);
      end

      // Same-line read/write ordering: no presented DMA request shares a cache line
      // with an unresponded opposite-direction DMA entry in flight.
      p_same_line_rw_ordered : assert (same_line_rw_ok);

      // Returning DMA responses steer back to their owning engine with preserved kind, tag, and error.
      if (i_dma_resp_valid && f_dma_owner_known[i_dma_resp_id]) begin
        p_dma_resp_routed_to_owner :
        assert (o_resp_valid[f_dma_owner[i_dma_resp_id]] &&
                (o_resp_kind[f_dma_owner[i_dma_resp_id]] == f_dma_kind[i_dma_resp_id]) &&
                (o_resp_tag[f_dma_owner[i_dma_resp_id]] == f_dma_tag[i_dma_resp_id]) &&
                (o_resp_error[f_dma_owner[i_dma_resp_id]] == i_dma_resp_error));
      end

      // Registered stop level suppresses both engine acceptance and DMA presentation.
      if (stop_d) begin
        p_stop_gates_port_and_ready : assert (!o_dma_req_valid && (o_req_ready == 2'b00));
      end

      // Neither engine receives a spurious response or is offered ready at SIDE_CAP.
      p_no_spurious_rx_resp : assert (!o_resp_valid[0] || (f_eng_outstanding[0] != '0));
      p_no_spurious_tx_resp : assert (!o_resp_valid[1] || (f_eng_outstanding[1] != '0));
      p_rx_side_cap_respected :
      assert (!(o_req_ready[0] && (f_eng_outstanding[0] >= CountBits'(SIDE_CAP))));
      p_tx_side_cap_respected :
      assert (!(o_req_ready[1] && (f_eng_outstanding[1] >= CountBits'(SIDE_CAP))));

      // HOLD_LIMIT backpressure: once an engine's buffered request has waited
      // HOLD_LIMIT cycles behind an exact same-line opposite-direction DMA
      // entry, the opposite engine is denied o_req_ready until it leaves.
      if (!f_buf_ambig && f_buf_valid[0] && (f_exact_hold_cnt[0] == HoldBits'(HOLD_LIMIT))) begin
        p_rx_hold_limit_blocks_tx_ready : assert (!o_req_ready[1]);
      end
      if (!f_buf_ambig && f_buf_valid[1] && (f_exact_hold_cnt[1] == HoldBits'(HOLD_LIMIT))) begin
        p_tx_hold_limit_blocks_rx_ready : assert (!o_req_ready[0]);
      end

      // STARVATION_LIMIT fairness: when TX is buffered, unstopped, unvetoed,
      // and has watched STARVATION_LIMIT RX grants without just being refused
      // on the DMA port, TX is presented rather than pre-empted by RX.
      if (!f_buf_ambig && tx_definitely_avail_q) begin
        p_tx_avail_drives_dma_valid : assert (o_dma_req_valid);
        if ((f_tx_starve_cnt == WaitBits'(STARVATION_LIMIT)) && !prev_tx_port_refused_q) begin
          p_tx_starvation_bounded : assert (fire_tx_match);
        end
      end

      // o_idle asserts only when all DMA entries and accepted engine requests have completed.
      if (o_idle) begin
        p_idle_means_all_drained :
        assert ((f_dma_live == '0) && (f_eng_outstanding[0] == '0) && (f_eng_outstanding[1] == '0));
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst) begin
      // Reach TX winning arbitration via STARVATION_LIMIT while RX is also buffered.
      c_tx_starvation_grant :
      cover (!f_buf_ambig && f_buf_valid[0] && f_buf_valid[1] &&
             (f_tx_starve_cnt == WaitBits'(STARVATION_LIMIT)) && tx_fires);

      // Reach HOLD_LIMIT saturation blocking the opposite engine's o_req_ready.
      c_hold_limit_blocks_peer :
      cover (!f_buf_ambig && f_buf_valid[0] && (f_exact_hold_cnt[0] == HoldBits'(HOLD_LIMIT)) &&
             !o_req_ready[1]);

      // Reach out-of-aperture local error response delayed behind a same-cycle DMA response.
      c_refusal_queued_behind_resp :
      cover ($past(
          !i_rst && i_req_valid[0] && o_req_ready[0] && !f_in_aperture(
              i_req_addr[0]
          ) && i_dma_resp_valid
      ) && o_resp_valid[0] && o_resp_error[0]);

      // Reach request accepted during raw i_stop (!stop_d) withdrawn and drained to o_idle.
      c_raw_stop_accept_withdraw_to_idle :
      cover ($past(
          !i_rst && i_stop && !stop_d && i_req_valid[0] && o_req_ready[0] && f_in_aperture(
              i_req_addr[0]
          ),
          2
      ) && o_idle);

      // Reach all NUM_ENTRIES DMA slots simultaneously active across both engines.
      c_all_entries_busy : cover (&f_dma_live);
    end
  end

endmodule
