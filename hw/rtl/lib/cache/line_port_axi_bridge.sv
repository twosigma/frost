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
 * An error response (not OKAY) still completes its transaction, so a read
 * returns the response's data; o_resp_error carries RRESP[1] or BRESP[1] with
 * it, and o_rd_err_* or o_wr_err_* report it for the memory error unit.
 * Simulation also flags it unless RESP_ERRORS is set, for a master to which
 * error responses are normal traffic, or the +axi_error_check=0 plusarg turns
 * that off for a test that injects errors.
 * The bridge never orders
 * a read against a write: the caches above keep same-line ordering ("Line
 * protocol" in hw/rtl/lib/cache/README.md).
 *
 * Issue path: one read issue register (AR) and one write issue register
 * (AW+W), each held until its AXI handshake completes. A read request is
 * accepted when AR is free, a write when both AW and W are, so a read can be
 * accepted while a write's AW/W are still waiting. Ready therefore depends on
 * the presented request's write bit, which the protocol allows.
 *
 * i_rst stops acceptance and clears response tracking, but holds presented
 * AXI beats until accepted: the controller keeps running through CPU resets.
 * Withdrawing W after AW was accepted could pair the next data with the old
 * address. i_axi_rst instead gates all issue VALIDs low immediately and
 * clears them on the clock edge. Initializers define power-up state.
 *
 * Response path: R and B land in one-entry output registers. R has priority
 * onto the single line response port and is always accepted, since its
 * register drains the next cycle unconditionally. A held B drains in the
 * first cycle without an R response and holds off the B channel until then.
 *
 * A response whose id is not in flight is dropped. On hardware that drains
 * the transactions the bridge accepted before an image-load reset or an
 * ndmreset: the controller keeps running and completes them after the reset
 * has cleared the in-flight bitmap. A late response would pass for the
 * response to a new request with the same id, so the bridge accepts no
 * request until every transaction it accepted before the reset has completed
 * (held beats taken, response received); i_axi_rst discards them instead. An
 * image load relies on their promptness as well: nothing orders the JTAG
 * loader's DDR writes after the bridge's, so each write the bridge accepted
 * before the reset must land before the loader's first DDR write, at least
 * one JTAG-AXI transaction after the low-BRAM write that raised the reset.
 *
 * BASE_ADDR is subtracted from the line address so the AXI side sees a
 * zero-based region offset: in simulation the behavioral DDR indexes from 0,
 * and on hardware the memory controller's address space also starts at 0.
 * The AXI address width is independently configurable because a physical
 * aperture can start above zero while its zero-based controller offset needs
 * fewer bits. For the default 1 GiB region at 0x8000_0000 the subtraction
 * reduces to dropping the top address bit.
 */
module line_port_axi_bridge #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned AXI_ADDR_WIDTH = ADDR_WIDTH,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned ID_BITS = 4,
    parameter int unsigned AXI_ID_BITS = 4,
    parameter logic [ADDR_WIDTH-1:0] BASE_ADDR = ADDR_WIDTH'(32'h8000_0000),
    // 1: error responses are expected traffic (an I/O master's); no
    // simulation $error for them.
    parameter bit RESP_ERRORS = 1'b0
) (
    input logic i_clk,
    input logic i_rst,
    // The AXI slave below is in reset (see the header).
    input logic i_axi_rst,

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
    // RRESP[1] or BRESP[1] of the response forwarded with o_resp_valid.
    output logic                    o_resp_error,

    // AXI4 master (single-beat bursts).
    output logic                      o_axi_awvalid,
    input  logic                      i_axi_awready,
    output logic [   AXI_ID_BITS-1:0] o_axi_awid,
    output logic [AXI_ADDR_WIDTH-1:0] o_axi_awaddr,
    output logic [               7:0] o_axi_awlen,
    output logic [               2:0] o_axi_awsize,
    output logic [               1:0] o_axi_awburst,
    output logic                      o_axi_wvalid,
    input  logic                      i_axi_wready,
    output logic [  LINE_BYTES*8-1:0] o_axi_wdata,
    output logic [    LINE_BYTES-1:0] o_axi_wstrb,
    output logic                      o_axi_wlast,
    input  logic                      i_axi_bvalid,
    output logic                      o_axi_bready,
    input  logic [   AXI_ID_BITS-1:0] i_axi_bid,
    input  logic [               1:0] i_axi_bresp,
    output logic                      o_axi_arvalid,
    input  logic                      i_axi_arready,
    output logic [   AXI_ID_BITS-1:0] o_axi_arid,
    output logic [AXI_ADDR_WIDTH-1:0] o_axi_araddr,
    output logic [               7:0] o_axi_arlen,
    output logic [               2:0] o_axi_arsize,
    output logic [               1:0] o_axi_arburst,
    input  logic                      i_axi_rvalid,
    output logic                      o_axi_rready,
    input  logic [   AXI_ID_BITS-1:0] i_axi_rid,
    input  logic [  LINE_BYTES*8-1:0] i_axi_rdata,
    input  logic [               1:0] i_axi_rresp,
    input  logic                      i_axi_rlast,

    // Error responses, registered: one pulse per R or B taken that is not
    // OKAY, with its response code and AXI id.
    output logic                   o_rd_err_valid,
    output logic [            1:0] o_rd_err_resp,
    output logic [AXI_ID_BITS-1:0] o_rd_err_id,
    output logic                   o_wr_err_valid,
    output logic [            1:0] o_wr_err_resp,
    output logic [AXI_ID_BITS-1:0] o_wr_err_id
);

  localparam int unsigned NumIds = 1 << ID_BITS;

  initial begin
    if (AXI_ID_BITS < ID_BITS) $fatal(1, "line_port_axi_bridge: AXI_ID_BITS must cover ID_BITS");
    if (AXI_ADDR_WIDTH > ADDR_WIDTH || AXI_ADDR_WIDTH < 1)
      $fatal(1, "line_port_axi_bridge: AXI_ADDR_WIDTH must be in 1..ADDR_WIDTH");
  end

  // ---- Issue registers ------------------------------------------------------
  // The valids clear on their handshakes and on i_axi_rst, never on i_rst
  // (see the header); the initializers are the power-up state.
  logic                      ar_valid_q = 1'b0;
  logic [AXI_ADDR_WIDTH-1:0] ar_addr_q;
  logic [       ID_BITS-1:0] ar_id_q;
  logic                      aw_valid_q = 1'b0;
  logic                      w_valid_q = 1'b0;
  logic [AXI_ADDR_WIDTH-1:0] aw_addr_q;
  logic [       ID_BITS-1:0] aw_id_q;
  logic [  LINE_BYTES*8-1:0] w_data_q;
  logic [    LINE_BYTES-1:0] w_strb_q;

  // Set while a transaction accepted before the last i_rst still owes its
  // response (the stale bitmap below). Registered, so ready gains no logic
  // depth.
  logic                      stale_any_q = 1'b0;

  // A write is issuable when both its channels are free; a read when AR is.
  logic write_slot_free, read_slot_free;
  assign write_slot_free = !aw_valid_q && !w_valid_q;
  assign read_slot_free = !ar_valid_q;
  assign o_req_ready = !i_rst && !i_axi_rst && !stale_any_q &&
      (i_req_write ? write_slot_free : read_slot_free);

  logic req_fire;
  assign req_fire = i_req_valid && o_req_ready;

  // Constant burst geometry: one beat of LINE_BYTES.
  assign o_axi_awlen   = 8'd0;
  assign o_axi_awsize  = 3'($clog2(LINE_BYTES));
  assign o_axi_awburst = 2'b01;  // INCR
  assign o_axi_arlen   = 8'd0;
  assign o_axi_arsize  = 3'($clog2(LINE_BYTES));
  assign o_axi_arburst = 2'b01;  // INCR

  assign o_axi_awvalid = aw_valid_q && !i_axi_rst;
  assign o_axi_awid    = AXI_ID_BITS'(aw_id_q);
  assign o_axi_awaddr  = aw_addr_q;
  assign o_axi_wvalid  = w_valid_q && !i_axi_rst;
  assign o_axi_wdata   = w_data_q;
  assign o_axi_wstrb   = w_strb_q;
  assign o_axi_wlast   = 1'b1;
  assign o_axi_arvalid = ar_valid_q && !i_axi_rst;
  assign o_axi_arid    = AXI_ID_BITS'(ar_id_q);
  assign o_axi_araddr  = ar_addr_q;

  // req_fire is low through either reset (o_req_ready), so i_rst only lets the
  // presented beats finish their handshakes; i_axi_rst drops them.
  always_ff @(posedge i_clk) begin
    if (ar_valid_q && i_axi_arready) ar_valid_q <= 1'b0;
    if (aw_valid_q && i_axi_awready) aw_valid_q <= 1'b0;
    if (w_valid_q && i_axi_wready) w_valid_q <= 1'b0;
    if (i_axi_rst) begin
      ar_valid_q <= 1'b0;
      aw_valid_q <= 1'b0;
      w_valid_q  <= 1'b0;
    end
    if (req_fire) begin
      if (i_req_write) begin
        aw_valid_q <= 1'b1;
        w_valid_q  <= 1'b1;
        aw_addr_q  <= AXI_ADDR_WIDTH'(i_req_addr - BASE_ADDR);
        aw_id_q    <= i_req_id;
        w_data_q   <= i_req_wdata;
        w_strb_q   <= i_req_wstrb;
      end else begin
        ar_valid_q <= 1'b1;
        ar_addr_q  <= AXI_ADDR_WIDTH'(i_req_addr - BASE_ADDR);
        ar_id_q    <= i_req_id;
      end
    end
  end

  // ---- In-flight bitmap ------------------------------------------------------
  // One bit per id: set at the fire, cleared when the response is accepted
  // toward the line port. A response for a clear id is stale (see header).
  // The initializer matters: the first reset moves these bits into the stale
  // bitmap below, which only responses clear.
  logic [NumIds-1:0] inflight_q = '0;

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
  logic                    r_q_error;
  logic                    b_q_valid;
  logic [     ID_BITS-1:0] b_q_id;
  logic                    b_q_error;

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
  assign o_resp_error = r_q_valid ? r_q_error : b_q_error;

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
        r_q_error <= i_axi_rresp[1];
        inflight_q[i_axi_rid[ID_BITS-1:0]] <= 1'b0;
      end

      // B: capture when the register is empty or draining this cycle.
      if (b_accept && b_known) begin
        b_q_valid <= 1'b1;
        b_q_id    <= i_axi_bid[ID_BITS-1:0];
        b_q_error <= i_axi_bresp[1];
        inflight_q[i_axi_bid[ID_BITS-1:0]] <= 1'b0;
      end else if (b_drain) begin
        b_q_valid <= 1'b0;
      end
    end
  end

  // ---- Transactions accepted before a reset ----------------------------------
  // One bit per id. i_rst moves the in-flight bitmap here, since the slave
  // keeps running and still owes those responses. A response for the id
  // clears its bit, and i_axi_rst, which discards the slave's work, clears
  // them all. No request is accepted while any bit is set, so no id is ever
  // owed both from before a reset and from after it.
  logic [NumIds-1:0] stale_q = '0;
  logic [NumIds-1:0] stale_d;
  always_comb begin
    stale_d = stale_q;
    if (i_rst) stale_d = stale_d | inflight_q;
    if (r_accept) stale_d[i_axi_rid[ID_BITS-1:0]] = 1'b0;
    if (b_accept) stale_d[i_axi_bid[ID_BITS-1:0]] = 1'b0;
    if (i_axi_rst) stale_d = '0;
  end
  always_ff @(posedge i_clk) begin
    stale_q     <= stale_d;
    stale_any_q <= |stale_d;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_rd_err_valid <= 1'b0;
      o_wr_err_valid <= 1'b0;
    end else begin
      o_rd_err_valid <= r_accept && (i_axi_rresp != 2'b00);
      o_wr_err_valid <= b_accept && (i_axi_bresp != 2'b00);
    end
    o_rd_err_resp <= i_axi_rresp;
    o_rd_err_id   <= i_axi_rid;
    o_wr_err_resp <= i_axi_bresp;
    o_wr_err_id   <= i_axi_bid;
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // Simulation-only protocol checks (Yosys cannot elaborate $error).
  int axi_error_check;
  initial if (!$value$plusargs("axi_error_check=%d", axi_error_check)) axi_error_check = 1;
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (req_fire && inflight_q[i_req_id])
        $error("line_port_axi_bridge: request reuses in-flight id %0d", i_req_id);
      if (r_accept && r_known && b_accept && b_known &&
          (i_axi_rid[ID_BITS-1:0] == i_axi_bid[ID_BITS-1:0]))
        $error("line_port_axi_bridge: R and B for the same id %0d", i_axi_rid);
      if (!RESP_ERRORS && axi_error_check != 0 && i_axi_bvalid && o_axi_bready &&
          i_axi_bresp != 2'b00)
        $error("line_port_axi_bridge: write response error (bresp=%0d)", i_axi_bresp);
      if (!RESP_ERRORS && axi_error_check != 0 && i_axi_rvalid && o_axi_rready &&
          i_axi_rresp != 2'b00)
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
  // Dump a request blocked for 1024 cycles. Exclude formal: an unconstrained
  // initial counter could trigger the watchdog spuriously.
  int unsigned req_stall_cnt;
  always_ff @(posedge i_clk) begin
    if (i_rst || !(i_req_valid && !o_req_ready)) begin
      req_stall_cnt <= 0;
    end else begin
      req_stall_cnt <= req_stall_cnt + 1;
      if (req_stall_cnt == 1024) begin
        $display("line_port_axi_bridge REQ STALL: req{w=%0d id=%0d} ar{v=%0d rdy=%0d}",
                 i_req_write, i_req_id, ar_valid_q, i_axi_arready);
        $display("  aw{v=%0d rdy=%0d} w{v=%0d rdy=%0d} inflight=%b stale=%b r{v=%0d} b{v=%0d}",
                 aw_valid_q, i_axi_awready, w_valid_q, i_axi_wready, inflight_q, stale_q,
                 i_axi_rvalid, i_axi_bvalid);
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

  // The master must keep IDs unique among in-flight requests.
  always_comb begin
    if (!i_rst && i_req_valid) begin
      a_unique_inflight_id : assume (!inflight_q[i_req_id]);
    end
    if (i_axi_rst) begin
      p_axi_reset_valids_low : assert (!o_axi_arvalid && !o_axi_awvalid && !o_axi_wvalid);
    end
  end

  // AXI master obligations: a presented address/data beat stays valid and
  // stable until it is accepted, through i_rst as well (on hardware the slave
  // is not reset with the bridge); while the slave itself is in reset
  // (i_axi_rst) every VALID is low, and a beat withdrawn by it never returns.
  always @(posedge i_clk) begin
    if (f_past_valid && !i_axi_rst) begin
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
    if (f_past_valid && $past(req_fire)) begin
      // Compare the registered AXI offset with the complete physical-line
      // subtraction, before any narrowing. A 32-bit intermediate would alias
      // a request above 4 GiB and fail the wide formal configurations.
      if ($past(i_req_write)) begin
        p_aw_full_offset : assert (o_axi_awaddr == AXI_ADDR_WIDTH'($past(i_req_addr) - BASE_ADDR));
      end else begin
        p_ar_full_offset : assert (o_axi_araddr == AXI_ADDR_WIDTH'($past(i_req_addr) - BASE_ADDR));
      end
    end
    if (f_past_valid && $past(i_axi_rst)) begin
      p_axi_reset_drops_beats : assert (!ar_valid_q && !aw_valid_q && !w_valid_q);
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
      // A forwarded R carries its own RRESP error bit.
      if ($past(r_accept && r_known)) begin
        p_r_error_forwarded : assert (o_resp_error == $past(i_axi_rresp[1]));
      end
    end
  end

  // A held B keeps the error bit it was taken with while R responses pass it,
  // and reaches the line port with that bit.
  logic f_b_error_q;
  always @(posedge i_clk) begin
    if (b_accept && b_known) f_b_error_q <= i_axi_bresp[1];
    if (f_past_valid && !i_rst && !$past(i_rst) && b_q_valid && !r_q_valid) begin
      p_b_error_forwarded : assert (o_resp_error == f_b_error_q);
    end
  end

  if (ADDR_WIDTH > 32) begin : gen_high_offset_cover
    always @(posedge i_clk) begin
      c_high_physical_request : cover (req_fire && (i_req_addr >= ADDR_WIDTH'(64'h1_0000_0000)));
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

  // Reference for the drain across a reset: the transactions the slave still
  // owes, split by whether the bridge accepted them before the last i_rst
  // (f_pre_q) or after it (f_post_q). A response retires its id's older
  // transaction; a reset makes every current transaction a pre-reset one.
  // i_axi_rst discards the pre-reset ones, as the slave's reset does.
  logic [NumIds-1:0] f_pre_q, f_post_q, f_pre_d, f_post_d;
  initial begin
    f_pre_q  = '0;
    f_post_q = '0;
  end
  always_comb begin
    f_pre_d  = f_pre_q;
    f_post_d = f_post_q;
    if (r_accept) begin
      if (f_pre_d[i_axi_rid[ID_BITS-1:0]]) f_pre_d[i_axi_rid[ID_BITS-1:0]] = 1'b0;
      else f_post_d[i_axi_rid[ID_BITS-1:0]] = 1'b0;
    end
    if (b_accept) begin
      if (f_pre_d[i_axi_bid[ID_BITS-1:0]]) f_pre_d[i_axi_bid[ID_BITS-1:0]] = 1'b0;
      else f_post_d[i_axi_bid[ID_BITS-1:0]] = 1'b0;
    end
    if (i_rst) begin
      f_pre_d  = f_pre_d | f_post_d;
      f_post_d = '0;
    end
    if (req_fire) f_post_d[i_req_id] = 1'b1;
    if (i_axi_rst) f_pre_d = '0;
  end
  always @(posedge i_clk) begin
    f_pre_q  <= f_pre_d;
    f_post_q <= f_post_d;
  end

  always @(posedge i_clk) begin
    if (f_past_valid) begin
      // The stale bitmap is exactly the set of pre-reset transactions still
      // owed, and the in-flight bitmap the set of post-reset ones.
      p_stale_is_pre_reset : assert (stale_q == f_pre_q);
      p_inflight_is_post_reset : assert (inflight_q == f_post_q);
      p_stale_flag : assert (stale_any_q == (stale_q != '0));
      // No id is owed in both epochs, so a response is never ambiguous.
      p_epochs_disjoint : assert ((f_pre_q & f_post_q) == '0);
      // A response forwarded to the line port answers a post-reset request.
      if (r_accept && r_known) begin
        p_r_forward_is_current :
        assert (f_post_q[i_axi_rid[ID_BITS-1:0]] && !f_pre_q[i_axi_rid[ID_BITS-1:0]]);
      end
      if (b_accept && b_known) begin
        p_b_forward_is_current :
        assert (f_post_q[i_axi_bid[ID_BITS-1:0]] && !f_pre_q[i_axi_bid[ID_BITS-1:0]]);
      end
    end
  end

  always @(posedge i_clk) begin
    if (!i_rst) begin
      // A request fires as soon as the last pre-reset transaction drains.
      cover_drain_then_issue : cover ($past(stale_any_q) && !stale_any_q && req_fire);
      cover_read_and_write_in_flight : cover (ar_valid_q && aw_valid_q);
      // A reset lands between a write's AW and W handshakes.
      cover_reset_between_aw_and_w : cover ($past(i_rst) && w_valid_q && !aw_valid_q);
      // The AXI-side reset drops a held beat.
      cover_axi_reset_drops_beat : cover ($past(i_axi_rst && ar_valid_q) && !ar_valid_q);
      cover_r_and_b_same_cycle : cover (r_accept && r_known && b_accept && b_known);
      cover_two_reads_in_flight : cover ($countones(inflight_q) >= 2);
    end
  end
`endif

endmodule : line_port_axi_bridge
