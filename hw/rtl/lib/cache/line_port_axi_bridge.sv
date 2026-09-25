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
 * line_port_axi_bridge: tagged line-port slave to AXI4 master.
 *
 * The bottom of the cache hierarchy: converts line transactions into
 * single-beat AXI4 bursts (AxLEN=0, AxSIZE=log2(LINE_BYTES)) with the line
 * id carried as the AXI id. Any number of transactions may be in flight, up
 * to one per id value, and the memory controller may complete different ids
 * in any order. Writes drive AW and W and complete on B; reads complete on R.
 * Responses are assumed OKAY (checked in simulation). The bridge never orders
 * a read against a write: the caches above keep same-line ordering ("Line
 * protocol" in hw/rtl/lib/cache/README.md).
 *
 * Issue path: one read issue register (AR) and one write issue register
 * (AW+W), each held until its AXI handshake completes. A read request is
 * accepted when AR is free, a write when both AW and W are, so a read can be
 * accepted while a write's AW/W are still waiting. Ready therefore depends on
 * the presented request's write bit, which the protocol allows.
 *
 * Reset does not withdraw a presented beat. The bridge resets with the CPU,
 * while the memory controller and its interconnect keep running (through
 * the image-load reset and the debug ndmreset), so a VALID must stay
 * asserted until its handshake. A write whose AW was accepted and whose W
 * was not would otherwise leave the interconnect pairing the next write's
 * data with the old address. The issue valids therefore take no reset: a
 * beat presented at a reset stays presented, payload unchanged, until the
 * slave takes it, and ready stays low through the reset. The declaration
 * initializers are the power-up state. On hardware the level below is reset
 * only at power-up, while nothing is presented. In simulation the DDR model
 * shares the bridge's reset: its queues clear at the first reset edge and
 * its readies rise, so a reset longer than one cycle lets it take and
 * discard the held beats.
 *
 * Response path: R and B land in one-entry output registers. R has priority
 * onto the single line response port and is always accepted, since its
 * register drains the next cycle unconditionally. A held B drains in the
 * first cycle without an R response and holds off the B channel until then.
 *
 * A response whose id is not in flight is dropped. That drains the responses
 * to transactions the memory controller accepted before or during a CPU
 * reset: the controller keeps running and answers them after the reset has
 * cleared the in-flight bitmap. This relies on the caches' reset tag sweeps
 * (thousands of cycles on hardware) outlasting any response still in flight,
 * so no new request reuses its id first. A write held across an image-load
 * reset lands long before the JTAG loader writes the new image into DDR.
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
  // The valids clear only on their handshakes, never on reset (see the
  // header); the initializers are the power-up state.
  logic                    ar_valid_q = 1'b0;
  logic [            31:0] ar_addr_q;
  logic [     ID_BITS-1:0] ar_id_q;
  logic                    aw_valid_q = 1'b0;
  logic                    w_valid_q = 1'b0;
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

  // req_fire is low through reset (o_req_ready), so a reset only lets the
  // presented beats finish their handshakes.
  always_ff @(posedge i_clk) begin
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
  // Stall watchdog (simulation only: under formal the counter's free initial
  // value would fire it spuriously). A request refused for 1024 cycles means
  // an issue register or the AXI side wedged. Dump the handshake so the log
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
  // response; the simulation check above flags a reuse).
  always_comb begin
    if (!i_rst && i_req_valid) begin
      a_unique_inflight_id : assume (!inflight_q[i_req_id]);
    end
  end

  // AXI master obligations: a presented address/data beat stays valid and
  // stable until it is accepted, through a reset as well (on hardware the
  // slave is not reset with the bridge).
  always @(posedge i_clk) begin
    if (f_past_valid) begin
      if ($past(o_axi_arvalid && !i_axi_arready)) begin
        p_ar_held : assert (o_axi_arvalid && $stable(o_axi_araddr) && $stable(o_axi_arid));
      end
      if ($past(o_axi_awvalid && !i_axi_awready)) begin
        p_aw_held : assert (o_axi_awvalid && $stable(o_axi_awaddr) && $stable(o_axi_awid));
      end
      if ($past(o_axi_wvalid && !i_axi_wready)) begin
        p_w_held : assert (o_axi_wvalid && $stable(o_axi_wdata) && $stable(o_axi_wstrb));
      end
    end
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      // An R response for an id in flight reaches the line port the next
      // cycle with that id.
      if ($past(r_accept && r_known)) begin
        p_r_forwarded : assert (o_resp_valid && o_resp_id == $past(i_axi_rid[ID_BITS-1:0]));
      end
      // A stale response (id not in flight) never reaches the line port.
      if ($past(r_accept && !r_known) && !$past(b_q_valid) && !$past(b_accept && b_known)) begin
        p_stale_r_dropped : assert (!o_resp_valid);
      end
    end
  end

  // In-flight bitmap: a fire sets its id's bit, and nothing else sets a bit.
  // (Unlabeled: Yosys does not uniquify assertion labels across generate
  // iterations.)
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
      // A reset lands between a write's AW and W handshakes.
      cover_reset_between_aw_and_w : cover ($past(i_rst) && w_valid_q && !aw_valid_q);
      cover_r_and_b_same_cycle : cover (r_accept && r_known && b_accept && b_known);
      cover_two_reads_in_flight : cover ($countones(inflight_q) >= 2);
    end
  end
`endif

endmodule : line_port_axi_bridge
