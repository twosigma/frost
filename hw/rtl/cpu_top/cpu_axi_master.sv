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

// One physical-address AXI4 master for cache lines and narrow accesses.
// Requests supply their size and attributes independently of the ID. Payload
// bytes already occupy their AXI byte lanes; this block never widens, merges,
// retries, or splits an access. Every request is a single-beat INCR burst.
//
// i_rst resets the CPU's transaction owners, not the fabric. Presented AXI
// beats remain valid through i_rst; their responses drain without reaching
// the new CPU epoch. New requests wait until all old responses have drained.
// i_axi_rst resets both sides of the AXI connection and may withdraw VALID.
// Both resets are synchronous to i_clk; i_axi_rst also gates VALID/READY low
// combinationally. The integrating wrapper must synchronize their release.
module cpu_axi_master #(
    parameter int unsigned ADDR_WIDTH = 40,
    parameter int unsigned DATA_BYTES = 64,
    parameter int unsigned ID_BITS = 6,
    // USER has no CPU semantics. All outgoing USER bits are zero; incoming
    // USER bits are ignored. A wrapper may omit these sidebands entirely.
    parameter int unsigned USER_BITS = 1,
    // o_resp_valid_id and o_resp_ok_id report a visible response carrying
    // this ID, and one with an OKAY status.
    parameter int unsigned FLAG_RESP_ID = 0
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_axi_rst,

    input logic i_req_valid,
    output logic o_req_ready,
    input logic i_req_write,
    input logic [ADDR_WIDTH-1:0] i_req_addr,
    input logic [2:0] i_req_size,
    input logic [3:0] i_req_cache,
    input logic [2:0] i_req_prot,
    input logic [DATA_BYTES*8-1:0] i_req_wdata,
    input logic [DATA_BYTES-1:0] i_req_wstrb,
    input logic [ID_BITS-1:0] i_req_id,

    output logic o_resp_valid,
    input logic i_resp_ready,
    output logic o_resp_write,
    output logic [ID_BITS-1:0] o_resp_id,
    output logic [DATA_BYTES*8-1:0] o_resp_rdata,
    output logic [1:0] o_resp_status,
    output logic o_resp_valid_id,
    output logic o_resp_ok_id,
    // Read payload taps are consumed only when the selected response is a read.
    output logic o_read_resp_valid,
    output logic [ID_BITS-1:0] o_read_resp_id,
    output logic [DATA_BYTES*8-1:0] o_read_resp_rdata,
    output logic [1:0] o_read_resp_status,
    // Capture edge for payload metadata parallel to the R response buffer.
    output logic o_read_resp_capture,
    // Includes queued requests, fabric transactions, buffered responses, and
    // pre-reset traffic. It is not merely an AXI channel-idle indication.
    output logic o_idle,

    output logic o_axi_awvalid,
    input logic i_axi_awready,
    output logic [ID_BITS-1:0] o_axi_awid,
    output logic [ADDR_WIDTH-1:0] o_axi_awaddr,
    output logic [7:0] o_axi_awlen,
    output logic [2:0] o_axi_awsize,
    output logic [1:0] o_axi_awburst,
    output logic o_axi_awlock,
    output logic [3:0] o_axi_awcache,
    output logic [2:0] o_axi_awprot,
    output logic [3:0] o_axi_awqos,
    output logic [3:0] o_axi_awregion,
    output logic [USER_BITS-1:0] o_axi_awuser,
    output logic o_axi_wvalid,
    input logic i_axi_wready,
    output logic [DATA_BYTES*8-1:0] o_axi_wdata,
    output logic [DATA_BYTES-1:0] o_axi_wstrb,
    output logic o_axi_wlast,
    output logic [USER_BITS-1:0] o_axi_wuser,
    input logic i_axi_bvalid,
    output logic o_axi_bready,
    input logic [ID_BITS-1:0] i_axi_bid,
    input logic [1:0] i_axi_bresp,
    input logic [USER_BITS-1:0] i_axi_buser,
    output logic o_axi_arvalid,
    input logic i_axi_arready,
    output logic [ID_BITS-1:0] o_axi_arid,
    output logic [ADDR_WIDTH-1:0] o_axi_araddr,
    output logic [7:0] o_axi_arlen,
    output logic [2:0] o_axi_arsize,
    output logic [1:0] o_axi_arburst,
    output logic o_axi_arlock,
    output logic [3:0] o_axi_arcache,
    output logic [2:0] o_axi_arprot,
    output logic [3:0] o_axi_arqos,
    output logic [3:0] o_axi_arregion,
    output logic [USER_BITS-1:0] o_axi_aruser,
    input logic i_axi_rvalid,
    output logic o_axi_rready,
    input logic [ID_BITS-1:0] i_axi_rid,
    input logic [DATA_BYTES*8-1:0] i_axi_rdata,
    input logic [1:0] i_axi_rresp,
    input logic i_axi_rlast,
    input logic [USER_BITS-1:0] i_axi_ruser
);

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) reset_seen_q <= 1'b1;
  logic axi_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_axi_rst) axi_reset_seen_q <= 1'b1;
`endif
  localparam int unsigned NumIds = 1 << ID_BITS;

  initial begin
    if (ADDR_WIDTH < $clog2(
            DATA_BYTES
        ) || DATA_BYTES < 8 || DATA_BYTES > 128 || (DATA_BYTES & (DATA_BYTES - 1)) != 0)
      $fatal(1, "cpu_axi_master: data bus must be a power of two, 8..128 bytes");
    if (ID_BITS < 1 || ID_BITS > 8 || USER_BITS < 1)
      $fatal(1, "cpu_axi_master: ID_BITS must be 1..8 and USER_BITS positive");
  end

`ifdef FROST_RANDOM_START
  localparam bit RandomStart = 1'b1;
`else
  localparam bit RandomStart = 1'b0;
`endif

  logic ar_valid_q = RandomStart ? 'x : 1'b0;
  logic aw_valid_q = RandomStart ? 'x : 1'b0;
  logic w_valid_q = RandomStart ? 'x : 1'b0;
  logic [ADDR_WIDTH-1:0] ar_addr_q, aw_addr_q;
  logic [ID_BITS-1:0] ar_id_q, aw_id_q;
  logic [2:0] ar_size_q, aw_size_q, ar_prot_q, aw_prot_q;
  logic [3:0] ar_cache_q, aw_cache_q;
  logic [DATA_BYTES*8-1:0] w_data_q;
  logic [DATA_BYTES-1:0] w_strb_q;

  // Busy IDs include responses buffered for the CPU. Fabric-pending IDs
  // exclude those responses, so a CPU reset never waits twice for one reply.
  logic [NumIds-1:0] busy_q = RandomStart ? 'x : '0;
  logic [NumIds-1:0] pending_q = RandomStart ? 'x : '0;
  // pending_q qualifies this payload and each accepted request sets its bit.
  logic [NumIds-1:0] write_q = RandomStart ? 'x : '0;
  logic [NumIds-1:0] stale_q = RandomStart ? 'x : '0;
  logic [NumIds-1:0] stale_d;
  logic stale_any_q = RandomStart ? 'x : 1'b0;
  logic req_fire, r_fire, b_fire, resp_fire;
  logic r_known, b_known;

  assign o_req_ready = !i_rst && !i_axi_rst && !stale_any_q && !busy_q[i_req_id] &&
      (i_req_write ? (!aw_valid_q && !w_valid_q) : !ar_valid_q);
  assign req_fire = i_req_valid && o_req_ready;

  assign o_axi_awvalid = aw_valid_q && !i_axi_rst;
  assign o_axi_awid = aw_id_q;
  assign o_axi_awaddr = aw_addr_q;
  assign o_axi_awlen = 0;
  assign o_axi_awsize = aw_size_q;
  assign o_axi_awburst = 2'b01;
  assign o_axi_awlock = 1'b0;
  assign o_axi_awcache = aw_cache_q;
  assign o_axi_awprot = aw_prot_q;
  assign o_axi_awqos = '0;
  assign o_axi_awregion = '0;
  assign o_axi_awuser = '0;
  assign o_axi_wvalid = w_valid_q && !i_axi_rst;
  assign o_axi_wdata = w_data_q;
  assign o_axi_wstrb = w_strb_q;
  assign o_axi_wlast = 1'b1;
  assign o_axi_wuser = '0;
  assign o_axi_arvalid = ar_valid_q && !i_axi_rst;
  assign o_axi_arid = ar_id_q;
  assign o_axi_araddr = ar_addr_q;
  assign o_axi_arlen = 0;
  assign o_axi_arsize = ar_size_q;
  assign o_axi_arburst = 2'b01;
  assign o_axi_arlock = 1'b0;
  assign o_axi_arcache = ar_cache_q;
  assign o_axi_arprot = ar_prot_q;
  assign o_axi_arqos = '0;
  assign o_axi_arregion = '0;
  assign o_axi_aruser = '0;

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
        w_valid_q <= 1'b1;
        aw_addr_q <= i_req_addr;
        aw_id_q <= i_req_id;
        aw_size_q <= i_req_size;
        aw_cache_q <= i_req_cache;
        aw_prot_q <= i_req_prot;
        w_data_q <= i_req_wdata;
        w_strb_q <= i_req_wstrb;
      end else begin
        ar_valid_q <= 1'b1;
        ar_addr_q <= i_req_addr;
        ar_id_q <= i_req_id;
        ar_size_q <= i_req_size;
        ar_cache_q <= i_req_cache;
        ar_prot_q <= i_req_prot;
      end
    end
  end

  logic r_valid_q = RandomStart ? 'x : 1'b0;
  logic b_valid_q = RandomStart ? 'x : 1'b0;
  logic [ID_BITS-1:0] r_id_q, b_id_q;
  logic [DATA_BYTES*8-1:0] r_data_q;
  logic [1:0] r_status_q, b_status_q;
  logic prefer_b_q = RandomStart ? 'x : 1'b0;
  logic select_b;
  // Lock the selected response while the CPU applies backpressure. A newly
  // arriving response on the other channel must not change the visible ID.
  logic response_held_q = RandomStart ? 'x : 1'b0;
  logic held_select_b_q;
  assign select_b = response_held_q ? held_select_b_q : (b_valid_q && (!r_valid_q || prefer_b_q));
  assign o_resp_valid = !i_rst && !i_axi_rst && (r_valid_q || b_valid_q);
  assign o_resp_write = select_b;
  assign o_resp_id = select_b ? b_id_q : r_id_q;
  assign o_resp_rdata = select_b ? '0 : r_data_q;
  assign o_resp_status = select_b ? b_status_q : r_status_q;
  // Factor read publication before the shared payload mux. A held response
  // uses its saved channel; otherwise a read wins unless B has priority.
  assign o_read_resp_valid = !i_rst && !i_axi_rst &&
      (response_held_q ? ((r_valid_q || b_valid_q) && !held_select_b_q) :
                        (r_valid_q && (!b_valid_q || !prefer_b_q)));
  assign o_read_resp_id = r_id_q;
  assign o_read_resp_rdata = r_data_q;
  assign o_read_resp_status = r_status_q;
  assign o_read_resp_capture = !i_rst && !i_axi_rst && r_fire && r_known;
  // The same functions as o_resp_valid && o_resp_id == FLAG_RESP_ID, and
  // that with o_resp_status == OKAY, compared per channel before the select
  // and kept apart from the widely loaded response valid.
  (* keep = "true" *) logic resp_valid_id, resp_ok_id;
  assign resp_valid_id = !i_rst && !i_axi_rst && (r_valid_q || b_valid_q) &&
      (select_b ? (b_id_q == ID_BITS'(FLAG_RESP_ID)) : (r_id_q == ID_BITS'(FLAG_RESP_ID)));
  assign resp_ok_id = !i_rst && !i_axi_rst && (r_valid_q || b_valid_q) &&
      (select_b ? (b_id_q == ID_BITS'(FLAG_RESP_ID)) && (b_status_q == 2'b00) :
                  (r_id_q == ID_BITS'(FLAG_RESP_ID)) && (r_status_q == 2'b00));
  assign o_resp_valid_id = resp_valid_id;
  assign o_resp_ok_id = resp_ok_id;
  assign resp_fire = o_resp_valid && i_resp_ready;
  assign o_axi_rready = !i_axi_rst && (i_rst || !r_valid_q || (resp_fire && !select_b));
  assign o_axi_bready = !i_axi_rst && (i_rst || !b_valid_q || (resp_fire && select_b));
  assign r_fire = i_axi_rvalid && o_axi_rready;
  assign b_fire = i_axi_bvalid && o_axi_bready;
  assign r_known = pending_q[i_axi_rid] && !write_q[i_axi_rid];
  assign b_known = pending_q[i_axi_bid] && write_q[i_axi_bid];
  assign o_idle = !(|busy_q) && !stale_any_q && !ar_valid_q && !aw_valid_q &&
      !w_valid_q && !r_valid_q && !b_valid_q;

  always_ff @(posedge i_clk) begin
    if (i_rst || i_axi_rst) begin
      busy_q <= '0;
      pending_q <= '0;
      r_valid_q <= 1'b0;
      b_valid_q <= 1'b0;
      prefer_b_q <= 1'b0;
      response_held_q <= 1'b0;
    end else begin
      response_held_q <= o_resp_valid && !i_resp_ready;
      if (o_resp_valid && !i_resp_ready) held_select_b_q <= select_b;
      if (resp_fire) begin
        busy_q[o_resp_id] <= 1'b0;
        prefer_b_q <= !select_b;
        if (select_b) b_valid_q <= 1'b0;
        else r_valid_q <= 1'b0;
      end
      if (req_fire) begin
        busy_q[i_req_id] <= 1'b1;
        pending_q[i_req_id] <= 1'b1;
        write_q[i_req_id] <= i_req_write;
      end
      if (r_fire && r_known) begin
        pending_q[i_axi_rid] <= 1'b0;
        r_valid_q <= 1'b1;
        r_id_q <= i_axi_rid;
        r_status_q <= i_axi_rresp;
      end
      if (b_fire && b_known) begin
        pending_q[i_axi_bid] <= 1'b0;
        b_valid_q <= 1'b1;
        b_id_q <= i_axi_bid;
        b_status_q <= i_axi_bresp;
      end
    end
  end

  // Payload writes use buffer vacancy or selected-read readiness. Ownership
  // and reset qualify the valid flag and response publication.
  logic r_payload_write;
  assign r_payload_write = i_axi_rvalid && (!r_valid_q || (i_resp_ready && !select_b));
  always_ff @(posedge i_clk) begin
    if (r_payload_write) r_data_q <= i_axi_rdata;
  end

  always_comb begin
    stale_d = stale_q;
    if (i_rst) stale_d |= pending_q;
    if (r_fire) stale_d[i_axi_rid] = 1'b0;
    if (b_fire) stale_d[i_axi_bid] = 1'b0;
    if (i_axi_rst) stale_d = '0;
  end
  always_ff @(posedge i_clk) begin
    stale_q <= stale_d;
    stale_any_q <= |stale_d;
  end

  // USER inputs are deliberately not interpreted. Transaction status is
  // RRESP/BRESP; incoming USER bits cannot change the CPU's memory semantics.
  logic unused_user;
  assign unused_user = ^{i_axi_ruser, i_axi_buser};

`ifdef CPU_AXI_PAYLOAD_PROOF
  logic f_payload_reset_seen_q = 1'b0;
  logic [DATA_BYTES*8-1:0] f_owned_payload_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || i_axi_rst) f_payload_reset_seen_q <= 1'b1;
    if (!i_rst && !i_axi_rst && r_fire && r_known) f_owned_payload_q <= i_axi_rdata;
    if (f_payload_reset_seen_q) begin
      if (r_valid_q) begin
        p_owned_read_payload : assert (r_data_q == f_owned_payload_q);
      end
      cover_stalled_read : cover (r_valid_q && o_resp_valid && !select_b && !i_resp_ready);
      cover_owned_replacement : cover (r_valid_q && resp_fire && !select_b && r_fire && r_known);
      cover_b_before_read : cover (r_valid_q && b_valid_q && select_b && resp_fire && i_axi_rvalid);
      cover_unowned_read : cover (!i_rst && !i_axi_rst && !r_valid_q && r_fire && !r_known);
      cover_reset_with_read : cover (i_rst && r_valid_q);
    end
  end
`endif

`ifndef SYNTHESIS
  always_comb begin
    p_resp_valid_id_exact :
    assert (o_resp_valid_id == (o_resp_valid && (o_resp_id == ID_BITS'(FLAG_RESP_ID))));
    p_resp_ok_id_exact :
    assert (o_resp_ok_id ==
            (o_resp_valid && (o_resp_id == ID_BITS'(FLAG_RESP_ID)) && (o_resp_status == 2'b00)));
  end
  always @(posedge i_clk) begin
    if (reset_seen_q && axi_reset_seen_q && req_fire) begin
      assert (i_req_size <= 3'($clog2(DATA_BYTES)))
      else $error("cpu_axi_master: transfer exceeds bus width");
      assert ((i_req_addr & ((ADDR_WIDTH'(1) << i_req_size) - 1)) == 0)
      else
        $error(
            "cpu_axi_master: unaligned request id=%0d write=%b addr=%h size=%0d",
            i_req_id,
            i_req_write,
            i_req_addr,
            i_req_size
        );
    end
    if (reset_seen_q && axi_reset_seen_q && !i_rst && !i_axi_rst && r_fire && r_known) begin
      assert (i_axi_rlast)
      else $error("cpu_axi_master: expected single-beat RLAST");
    end
  end
`endif
endmodule
