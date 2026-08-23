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
 * line_port_axi_bridge -- tagged line-port slave to AXI4 master.
 *
 * The bottom of the cache hierarchy: converts line transactions into
 * single-beat AXI4 bursts (AxLEN=0, AxSIZE=log2(LINE_BYTES), 256-bit data)
 * with the line id carried as the AXI id, so any number of transactions may
 * be in flight -- up to one per id value -- and the memory controller is free
 * to complete different ids in any order. Writes drive AW and W and complete
 * on B; reads complete on R. Responses are assumed OKAY (checked in
 * simulation). The bridge never orders a read against a write: the caches
 * above own same-line ordering (hw/rtl/lib/cache/README.md).
 *
 * Issue: one read issue register (AR) and one write issue register (AW+W),
 * each held until its AXI handshake completes. Ready for a read request is
 * the read register being free and likewise for writes, so a read can be
 * accepted while a write's AW/W are still waiting (ready depends on the
 * presented request's write bit, which the protocol allows).
 *
 * Response: R and B land in one-entry output registers; R has priority onto
 * the single line response port and is always accepted (its register drains
 * the next cycle unconditionally), B waits one cycle when both arrive
 * together. A response whose id is not in flight is discarded -- that is the
 * only way a transaction interrupted by an image-load CPU reset can be
 * handled: the AXI side keeps accepting, the in-flight bitmap is cleared, and
 * the stale R/B drains into nothing. The caches' reset tag sweeps (thousands
 * of cycles) guarantee no new request can reach the bridge while a stale
 * response is still outstanding, so an id can never be confused.
 *
 * BASE_ADDR is subtracted from the line address so the AXI side sees a
 * zero-based region offset: in simulation the behavioral DDR indexes from 0,
 * and on hardware the memory controller's address space also starts at 0.
 * For the 1 GiB region at 0x8000_0000 the subtraction reduces to dropping the
 * top address bit.
 */
module line_port_axi_bridge #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned ID_BITS = 4,
    parameter int unsigned AXI_ID_BITS = 4,
    parameter logic [31:0] BASE_ADDR = 32'h8000_0000
) (
    input logic i_clk,
    input logic i_rst,

    // Line port (slave).
    input  logic                    i_req_valid,
    output logic                    o_req_ready,
    input  logic                    i_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_req_wstrb,
    input  logic [     ID_BITS-1:0] i_req_id,
    output logic                    o_resp_valid,
    output logic [     ID_BITS-1:0] o_resp_id,
    output logic [LINE_BYTES*8-1:0] o_resp_rdata,

    // AXI4 master (single-beat bursts).
    output logic                    o_axi_awvalid,
    input  logic                    i_axi_awready,
    output logic [ AXI_ID_BITS-1:0] o_axi_awid,
    output logic [            31:0] o_axi_awaddr,
    output logic [             7:0] o_axi_awlen,
    output logic [             2:0] o_axi_awsize,
    output logic [             1:0] o_axi_awburst,
    output logic                    o_axi_wvalid,
    input  logic                    i_axi_wready,
    output logic [LINE_BYTES*8-1:0] o_axi_wdata,
    output logic [  LINE_BYTES-1:0] o_axi_wstrb,
    output logic                    o_axi_wlast,
    input  logic                    i_axi_bvalid,
    output logic                    o_axi_bready,
    input  logic [ AXI_ID_BITS-1:0] i_axi_bid,
    input  logic [             1:0] i_axi_bresp,
    output logic                    o_axi_arvalid,
    input  logic                    i_axi_arready,
    output logic [ AXI_ID_BITS-1:0] o_axi_arid,
    output logic [            31:0] o_axi_araddr,
    output logic [             7:0] o_axi_arlen,
    output logic [             2:0] o_axi_arsize,
    output logic [             1:0] o_axi_arburst,
    input  logic                    i_axi_rvalid,
    output logic                    o_axi_rready,
    input  logic [ AXI_ID_BITS-1:0] i_axi_rid,
    input  logic [LINE_BYTES*8-1:0] i_axi_rdata,
    input  logic [             1:0] i_axi_rresp,
    input  logic                    i_axi_rlast
);

  localparam int unsigned NumIds = 1 << ID_BITS;

  initial begin
    if (AXI_ID_BITS < ID_BITS) $fatal(1, "line_port_axi_bridge: AXI_ID_BITS must cover ID_BITS");
  end

  // ---- Issue registers ------------------------------------------------------
  logic                    ar_valid_q;
  logic [            31:0] ar_addr_q;
  logic [     ID_BITS-1:0] ar_id_q;
  logic                    aw_valid_q;
  logic                    w_valid_q;
  logic [            31:0] aw_addr_q;
  logic [     ID_BITS-1:0] aw_id_q;
  logic [LINE_BYTES*8-1:0] w_data_q;
  logic [  LINE_BYTES-1:0] w_strb_q;

  // A write is issuable when both its channels are free; a read when AR is.
  logic write_slot_free, read_slot_free;
  assign write_slot_free = !aw_valid_q && !w_valid_q;
  assign read_slot_free  = !ar_valid_q;
  assign o_req_ready     = !i_rst && (i_req_write ? write_slot_free : read_slot_free);

  logic req_fire;
  assign req_fire = i_req_valid && o_req_ready;

  // Constant burst geometry: one beat of LINE_BYTES.
  assign o_axi_awlen   = 8'd0;
  assign o_axi_awsize  = 3'($clog2(LINE_BYTES));
  assign o_axi_awburst = 2'b01;  // INCR
  assign o_axi_arlen   = 8'd0;
  assign o_axi_arsize  = 3'($clog2(LINE_BYTES));
  assign o_axi_arburst = 2'b01;  // INCR

  assign o_axi_awvalid = aw_valid_q;
  assign o_axi_awid    = AXI_ID_BITS'(aw_id_q);
  assign o_axi_awaddr  = aw_addr_q;
  assign o_axi_wvalid  = w_valid_q;
  assign o_axi_wdata   = w_data_q;
  assign o_axi_wstrb   = w_strb_q;
  assign o_axi_wlast   = 1'b1;
  assign o_axi_arvalid = ar_valid_q;
  assign o_axi_arid    = AXI_ID_BITS'(ar_id_q);
  assign o_axi_araddr  = ar_addr_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ar_valid_q <= 1'b0;
      aw_valid_q <= 1'b0;
      w_valid_q  <= 1'b0;
    end else begin
      if (ar_valid_q && i_axi_arready) ar_valid_q <= 1'b0;
      if (aw_valid_q && i_axi_awready) aw_valid_q <= 1'b0;
      if (w_valid_q && i_axi_wready) w_valid_q <= 1'b0;
      if (req_fire) begin
        if (i_req_write) begin
          aw_valid_q <= 1'b1;
          w_valid_q  <= 1'b1;
          aw_addr_q  <= i_req_addr - BASE_ADDR;
          aw_id_q    <= i_req_id;
          w_data_q   <= i_req_wdata;
          w_strb_q   <= i_req_wstrb;
        end else begin
          ar_valid_q <= 1'b1;
          ar_addr_q  <= i_req_addr - BASE_ADDR;
          ar_id_q    <= i_req_id;
        end
      end
    end
  end

  // ---- In-flight bitmap ------------------------------------------------------
  // One bit per id: set at the fire, cleared when the response is accepted
  // toward the line port. A response for a clear id is stale (see header).
  logic [NumIds-1:0] inflight_q;

  logic r_accept, b_accept;
  logic r_known, b_known;
  assign r_accept = i_axi_rvalid && o_axi_rready;
  assign b_accept = i_axi_bvalid && o_axi_bready;
  assign r_known  = inflight_q[i_axi_rid[ID_BITS-1:0]];
  assign b_known  = inflight_q[i_axi_bid[ID_BITS-1:0]];

  // ---- Response registers ---------------------------------------------------
  logic                    r_q_valid;
  logic [     ID_BITS-1:0] r_q_id;
  logic [LINE_BYTES*8-1:0] r_q_data;
  logic                    b_q_valid;
  logic [     ID_BITS-1:0] b_q_id;

  // R always drains the cycle after capture (it has priority on the response
  // port), so the AXI R channel is always ready. B drains when R is absent;
  // its register can take a new B whenever it is empty or draining.
  logic                    b_drain;
  assign b_drain      = b_q_valid && !r_q_valid;
  assign o_axi_rready = 1'b1;
  assign o_axi_bready = !b_q_valid || b_drain;

  assign o_resp_valid = r_q_valid || b_q_valid;
  assign o_resp_id    = r_q_valid ? r_q_id : b_q_id;
  assign o_resp_rdata = r_q_data;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      inflight_q <= '0;
      r_q_valid  <= 1'b0;
      b_q_valid  <= 1'b0;
    end else begin
      if (req_fire) inflight_q[i_req_id] <= 1'b1;

      // R: capture (known id) or discard (stale); the register is free again
      // every cycle because it always drains.
      r_q_valid <= r_accept && r_known;
      if (r_accept && r_known) begin
        r_q_id <= i_axi_rid[ID_BITS-1:0];
        r_q_data <= i_axi_rdata;
        inflight_q[i_axi_rid[ID_BITS-1:0]] <= 1'b0;
      end

      // B: capture when the register is empty or draining this cycle.
      if (b_accept && b_known) begin
        b_q_valid <= 1'b1;
        b_q_id    <= i_axi_bid[ID_BITS-1:0];
        inflight_q[i_axi_bid[ID_BITS-1:0]] <= 1'b0;
      end else if (b_drain) begin
        b_q_valid <= 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // Simulation-only protocol checks (Yosys cannot elaborate $error).
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (req_fire && inflight_q[i_req_id])
        $error("line_port_axi_bridge: request reuses in-flight id %0d", i_req_id);
      if (r_accept && r_known && b_accept && b_known &&
          (i_axi_rid[ID_BITS-1:0] == i_axi_bid[ID_BITS-1:0]))
        $error("line_port_axi_bridge: R and B for the same id %0d", i_axi_rid);
      if (i_axi_bvalid && o_axi_bready && i_axi_bresp != 2'b00)
        $error("line_port_axi_bridge: write response error (bresp=%0d)", i_axi_bresp);
      if (i_axi_rvalid && o_axi_rready && i_axi_rresp != 2'b00)
        $error("line_port_axi_bridge: read response error (rresp=%0d)", i_axi_rresp);
      if (i_axi_rvalid && o_axi_rready && !i_axi_rlast)
        $error("line_port_axi_bridge: multi-beat read response (expected single beat)");
      if (i_axi_rvalid && 32'(i_axi_rid) >= NumIds)
        $error("line_port_axi_bridge: R id %0d outside the line id space", i_axi_rid);
      if (i_axi_bvalid && 32'(i_axi_bid) >= NumIds)
        $error("line_port_axi_bridge: B id %0d outside the line id space", i_axi_bid);
    end
  end
`endif
`endif

`ifndef SYNTHESIS
`ifndef FORMAL
  // Stall watchdog (simulation only; the counter's free initial value would
  // fire it spuriously under formal): a request refused this long means an
  // issue register or the AXI side wedged; dump the handshake so the log
  // alone diagnoses it.
  int unsigned req_stall_cnt;
  always_ff @(posedge i_clk) begin
    if (i_rst || !(i_req_valid && !o_req_ready)) begin
      req_stall_cnt <= 0;
    end else begin
      req_stall_cnt <= req_stall_cnt + 1;
      if (req_stall_cnt == 1024) begin
        $display("line_port_axi_bridge REQ STALL: req{w=%0d id=%0d} ar{v=%0d rdy=%0d}",
                 i_req_write, i_req_id, ar_valid_q, i_axi_arready);
        $display("  aw{v=%0d rdy=%0d} w{v=%0d rdy=%0d} inflight=%b r{v=%0d} b{v=%0d}", aw_valid_q,
                 i_axi_awready, w_valid_q, i_axi_wready, inflight_q, i_axi_rvalid, i_axi_bvalid);
        $error("line_port_axi_bridge: request stalled for 1024 cycles");
      end
    end
  end
`endif
`endif

`ifdef FORMAL
  initial assume (i_rst);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // Line-protocol obligation of the master: an id is unique among its
  // in-flight requests (the caches above never reuse one before its
  // response; the sim check above enforces the same rule).
  always_comb begin
    if (!i_rst && i_req_valid) begin
      a_unique_inflight_id : assume (!inflight_q[i_req_id]);
    end
  end

  // AXI master obligations: a presented address/data beat stays valid and
  // stable until it is accepted.
  always @(posedge i_clk) begin
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(o_axi_arvalid && !i_axi_arready)) begin
        p_ar_held : assert (o_axi_arvalid && $stable(o_axi_araddr) && $stable(o_axi_arid));
      end
      if ($past(o_axi_awvalid && !i_axi_awready)) begin
        p_aw_held : assert (o_axi_awvalid && $stable(o_axi_awaddr) && $stable(o_axi_awid));
      end
      if ($past(o_axi_wvalid && !i_axi_wready)) begin
        p_w_held : assert (o_axi_wvalid && $stable(o_axi_wdata) && $stable(o_axi_wstrb));
      end
      // Every line response names an id that was fired and not yet answered.
      if ($past(r_accept && r_known)) begin
        p_r_forwarded : assert (o_resp_valid && o_resp_id == $past(i_axi_rid[ID_BITS-1:0]));
      end
      // A stale response (id not in flight) never reaches the line port.
      if ($past(r_accept && !r_known) && !$past(b_q_valid) && !$past(b_accept && b_known)) begin
        p_stale_r_dropped : assert (!o_resp_valid);
      end
    end
  end

  // The in-flight bitmap is conserved: set only by a fire, cleared only by a
  // matching known response. (Unlabeled: Yosys does not uniquify assertion
  // labels across generate iterations.)
  for (genvar k = 0; k < int'(NumIds); k++) begin : gen_inflight_props
    always @(posedge i_clk) begin
      if (f_past_valid && !i_rst && !$past(i_rst)) begin
        if ($past(req_fire && i_req_id == ID_BITS'(k))) begin
          assert (inflight_q[k]);
        end
        if (!$past(inflight_q[k]) && !$past(req_fire && i_req_id == ID_BITS'(k))) begin
          assert (!inflight_q[k]);
        end
      end
    end
  end

  always @(posedge i_clk) begin
    if (!i_rst) begin
      cover_read_and_write_in_flight : cover (ar_valid_q && aw_valid_q);
      cover_r_and_b_same_cycle : cover (r_accept && r_known && b_accept && b_known);
      cover_two_reads_in_flight : cover ($countones(inflight_q) >= 2);
    end
  end
`endif

endmodule : line_port_axi_bridge
