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
 * nic_dma_front: the NIC's face on the cache hierarchy's coherent DMA port.
 *
 * Two engines (index 0 = RX, 1 = TX) present tagged line requests; the
 * front-end owns NUM_ENTRIES outstanding entries (the port id is the entry
 * index), so every request the port accepted has a home for its response,
 * and steers each response back to its owner with the kind and tag the
 * owner gave it. Each engine has one request register (its ready is that
 * register free and the engine below its share of the entries, SIDE_CAP,
 * so the other engine always finds an entry once responses return); the
 * registered requests are muxed onto the port every cycle: RX first, TX
 * once it has watched STARVATION_LIMIT grants go to RX while presenting
 * (a free entry is not a grant), and a request the port refuses in a cycle
 * (the sequencer holds its line) lets the other engine's request be
 * presented in the next one, so a locked line never blocks the other
 * engine's traffic to a different line. The sequencer acts only on the
 * fire, so re-presenting a different request is legal.
 *
 * Sinks are the engines' business: a read is issued only with its
 * destination reserved (the descriptor cache line, the reorder slot), a
 * write holds nothing but its entry. Responses carry no backpressure.
 *
 * An address outside the cached-DDR aperture is refused locally: the
 * request is not loaded, and the engine gets a response with o_resp_error
 * set for that kind and tag (delayed behind a real response of the same
 * cycle, the engine's ready staying low meanwhile). i_stop (the RESET
 * drain) withdraws the registered requests, which cannot have fired in
 * that cycle because valid toward the port is gated by it, answers each
 * with an error response, accepts nothing, and lets the fired ones drain;
 * o_idle then says every entry is free. Every request accepted here gets
 * exactly one response.
 */
module nic_dma_front #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned NUM_ENTRIES = 4,
    parameter int unsigned SIDE_CAP = 3,
    parameter int unsigned STARVATION_LIMIT = 8,
    parameter int unsigned TAG_BITS = 4,
    parameter logic [31:0] APERTURE_BASE = 32'h8000_0000,
    parameter logic [31:0] APERTURE_BYTES = 32'h4000_0000,
    localparam int unsigned IdBits = (NUM_ENTRIES > 1) ? $clog2(NUM_ENTRIES) : 1
) (
    input  logic i_clk,
    input  logic i_rst,
    input  logic i_stop,
    output logic o_idle,

    // Engine request ports (0 = RX, 1 = TX).
    input  logic [             1:0]                   i_req_valid,
    output logic [             1:0]                   o_req_ready,
    input  logic [             1:0]                   i_req_write,
    input  logic [             1:0][  ADDR_WIDTH-1:0] i_req_addr,
    input  logic [             1:0][LINE_BYTES*8-1:0] i_req_wdata,
    input  logic [             1:0][  LINE_BYTES-1:0] i_req_wstrb,
    input  logic [             1:0][             1:0] i_req_kind,
    input  logic [             1:0][    TAG_BITS-1:0] i_req_tag,
    // Engine response ports; rdata is broadcast, qualified by valid.
    output logic [             1:0]                   o_resp_valid,
    output logic [             1:0][             1:0] o_resp_kind,
    output logic [             1:0][    TAG_BITS-1:0] o_resp_tag,
    output logic [             1:0]                   o_resp_error,
    output logic [LINE_BYTES*8-1:0]                   o_resp_rdata,

    // DMA line port (master).
    output logic                    o_dma_req_valid,
    input  logic                    i_dma_req_ready,
    output logic                    o_dma_req_write,
    output logic [  ADDR_WIDTH-1:0] o_dma_req_addr,
    output logic [LINE_BYTES*8-1:0] o_dma_req_wdata,
    output logic [  LINE_BYTES-1:0] o_dma_req_wstrb,
    output logic [      IdBits-1:0] o_dma_req_id,
    input  logic                    i_dma_resp_valid,
    input  logic [      IdBits-1:0] i_dma_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_dma_resp_rdata
);
  localparam int unsigned CountBits = $clog2(NUM_ENTRIES + 2);
  localparam int unsigned WaitBits = $clog2(STARVATION_LIMIT + 1);

  initial begin
    if (SIDE_CAP >= NUM_ENTRIES)
      $fatal(1, "nic_dma_front: SIDE_CAP must leave an entry to the other side");
    if (SIDE_CAP < 1) $fatal(1, "nic_dma_front: SIDE_CAP must be >= 1");
  end

  function automatic logic in_aperture(input logic [ADDR_WIDTH-1:0] a);
    in_aperture = (a >= APERTURE_BASE) && (a < (APERTURE_BASE + APERTURE_BYTES));
  endfunction

  // ---- entries -----------------------------------------------------------------
  logic [NUM_ENTRIES-1:0] ent_valid_q;
  logic [NUM_ENTRIES-1:0] ent_owner_q;  // 0 RX, 1 TX
  logic [1:0] ent_kind_q[NUM_ENTRIES];
  logic [TAG_BITS-1:0] ent_tag_q[NUM_ENTRIES];
  logic free_any;
  logic [IdBits-1:0] free_idx;
  always_comb begin
    free_any = 1'b0;
    free_idx = '0;
    for (int k = int'(NUM_ENTRIES) - 1; k >= 0; k--) begin
      if (!ent_valid_q[k]) begin
        free_any = 1'b1;
        free_idx = IdBits'(k);
      end
    end
  end
  logic [1:0][CountBits-1:0] held;  // entries owned per engine
  always_comb begin
    held = '0;
    for (int k = 0; k < int'(NUM_ENTRIES); k++) begin
      if (ent_valid_q[k]) held[ent_owner_q[k]] = held[ent_owner_q[k]] + 1'b1;
    end
  end

  // ---- per-engine request registers and aperture refusals ---------------------
  logic [1:0] rq_valid_q, rq_write_q;
  logic [1:0][ADDR_WIDTH-1:0] rq_addr_q;
  logic [1:0][LINE_BYTES*8-1:0] rq_wdata_q;
  logic [1:0][LINE_BYTES-1:0] rq_wstrb_q;
  logic [1:0][1:0] rq_kind_q;
  logic [1:0][TAG_BITS-1:0] rq_tag_q;
  logic [1:0] err_pending_q;
  logic [1:0][1:0] err_kind_q;
  logic [1:0][TAG_BITS-1:0] err_tag_q;

  logic [1:0] load, refuse;
  always_comb begin
    for (int e = 0; e < 2; e++) begin
      o_req_ready[e] = !rq_valid_q[e] && !err_pending_q[e] && !i_stop &&
          ((held[e] + CountBits'(rq_valid_q[e])) < CountBits'(SIDE_CAP));
      load[e] = i_req_valid[e] && o_req_ready[e] && in_aperture(i_req_addr[e]);
      refuse[e] = i_req_valid[e] && o_req_ready[e] && !in_aperture(i_req_addr[e]);
    end
  end

  // ---- arbitration toward the port ----------------------------------------------
  logic [1:0] present;  // registered requests that could fire
  assign present = rq_valid_q & {2{free_any && !i_stop}};
  logic [WaitBits-1:0] tx_wait_q;
  logic tx_starved, prefer_tx_q, prefer_rx_q;
  assign tx_starved = present[1] && (tx_wait_q == WaitBits'(STARVATION_LIMIT));
  // RX first; TX when it has watched STARVATION_LIMIT RX grants or RX was
  // just refused; and a refused TX presentation hands the next turn to RX
  // even while TX's priority is saturated, so a TX request to a locked line
  // never blocks RX for longer than a cycle at a time.
  logic sel;  // 0 RX, 1 TX
  always_comb begin
    if (present[1] && (!present[0] || ((tx_starved || prefer_tx_q) && !prefer_rx_q))) sel = 1'b1;
    else sel = 1'b0;
  end
  logic fire;
  assign o_dma_req_valid = |present;
  assign o_dma_req_write = rq_write_q[sel];
  assign o_dma_req_addr  = rq_addr_q[sel];
  assign o_dma_req_wdata = rq_wdata_q[sel];
  assign o_dma_req_wstrb = rq_wstrb_q[sel];
  assign o_dma_req_id    = free_idx;
  assign fire = o_dma_req_valid && i_dma_req_ready;

  // ---- responses ---------------------------------------------------------------
  logic resp_owner;
  assign resp_owner = ent_owner_q[i_dma_resp_id];
  always_comb begin
    o_resp_valid = '0;
    o_resp_error = '0;
    for (int e = 0; e < 2; e++) begin
      o_resp_kind[e] = ent_kind_q[i_dma_resp_id];
      o_resp_tag[e]  = ent_tag_q[i_dma_resp_id];
    end
    if (i_dma_resp_valid) begin
      o_resp_valid[resp_owner] = 1'b1;
    end
    // A refusal answers on a cycle with no real response for that engine.
    for (int e = 0; e < 2; e++) begin
      if (err_pending_q[e] && !(i_dma_resp_valid && (resp_owner == 1'(e)))) begin
        o_resp_valid[e] = 1'b1;
        o_resp_error[e] = 1'b1;
        o_resp_kind[e]  = err_kind_q[e];
        o_resp_tag[e]   = err_tag_q[e];
      end
    end
  end
  assign o_resp_rdata = i_dma_resp_rdata;

  assign o_idle = !(|ent_valid_q) && !(|rq_valid_q) && !(|err_pending_q);

  // ---- state -------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ent_valid_q   <= '0;
      ent_owner_q   <= '0;
      rq_valid_q    <= '0;
      err_pending_q <= '0;
      tx_wait_q     <= '0;
      prefer_tx_q   <= 1'b0;
      prefer_rx_q   <= 1'b0;
    end else begin
      // Responses free their entries.
      if (i_dma_resp_valid) ent_valid_q[i_dma_resp_id] <= 1'b0;
      // Refusals answered.
      for (int e = 0; e < 2; e++) begin
        if (o_resp_valid[e] && o_resp_error[e]) err_pending_q[e] <= 1'b0;
      end
      // Loads and refusals.
      for (int e = 0; e < 2; e++) begin
        if (load[e]) begin
          rq_valid_q[e] <= 1'b1;
          rq_write_q[e] <= i_req_write[e];
          rq_addr_q[e]  <= i_req_addr[e];
          rq_wdata_q[e] <= i_req_wdata[e];
          rq_wstrb_q[e] <= i_req_wstrb[e];
          rq_kind_q[e]  <= i_req_kind[e];
          rq_tag_q[e]   <= i_req_tag[e];
        end
        if (refuse[e]) begin
          err_pending_q[e] <= 1'b1;
          err_kind_q[e]    <= i_req_kind[e];
          err_tag_q[e]     <= i_req_tag[e];
        end
      end
      // The fire allocates the entry and drains the register.
      if (fire) begin
        ent_valid_q[free_idx] <= 1'b1;
        ent_owner_q[free_idx] <= sel;
        ent_kind_q[free_idx]  <= rq_kind_q[sel];
        ent_tag_q[free_idx]   <= rq_tag_q[sel];
        rq_valid_q[sel]       <= 1'b0;
      end
      // Fairness: TX counts RX grants it watched; a refused presentation
      // hands the next cycle to the other engine.
      if (fire && (sel == 1'b0) && present[1]) begin
        if (tx_wait_q != WaitBits'(STARVATION_LIMIT)) tx_wait_q <= tx_wait_q + 1'b1;
      end else if (fire && (sel == 1'b1)) begin
        tx_wait_q <= '0;
      end
      prefer_tx_q <= o_dma_req_valid && !i_dma_req_ready && (sel == 1'b0) && present[1];
      prefer_rx_q <= o_dma_req_valid && !i_dma_req_ready && (sel == 1'b1) && present[0];
      // The drain withdraws every registered request (none fired: valid
      // toward the port is gated by i_stop) and answers it with an error,
      // so every request an engine had accepted gets exactly one response.
      for (int e = 0; e < 2; e++) begin
        if (i_stop && rq_valid_q[e]) begin
          rq_valid_q[e]    <= 1'b0;
          err_pending_q[e] <= 1'b1;
          err_kind_q[e]    <= rq_kind_q[e];
          err_tag_q[e]     <= rq_tag_q[e];
        end
      end
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  always_ff @(posedge i_clk) begin
    if (!i_rst && i_dma_resp_valid && !ent_valid_q[i_dma_resp_id])
      $error("nic_dma_front: response for a free entry %0d", i_dma_resp_id);
  end
`endif
`endif
endmodule : nic_dma_front
