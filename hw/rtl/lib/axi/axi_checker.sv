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
 * axi_checker: simulation-only AXI4 protocol checks on one interface.
 *
 * Every port is an input, so it watches an interface without driving it.
 * On each channel a VALID that is not accepted must stay high with the same
 * payload; a W burst must end with WLAST on beat AWLEN + 1 of its AW; and AW
 * and AR must carry a legal AxSIZE and burst (no reserved type, FIXED up to 16
 * beats, WRAP of 2, 4, 8 or 16 beats from an aligned address, INCR within one
 * 4 KiB page). These report $error. The WLAST check takes each W beat to
 * follow its AW or come with it, and stops at the first beat that leads its
 * AW, which AXI4 allows. An exclusive access (AxLOCK set) reports a
 * $warning: FROST's coherent bridge performs it as a normal access. PORT
 * numbers the interface in messages. The body is empty in synthesis and
 * formal builds.
 */
module axi_checker #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 256,
    parameter int unsigned ID_WIDTH = 4,
    parameter int unsigned PORT = 0
) (
    input logic i_clk,
    input logic i_rst,

    input logic                    i_awvalid,
    input logic                    i_awready,
    input logic [    ID_WIDTH-1:0] i_awid,
    input logic [  ADDR_WIDTH-1:0] i_awaddr,
    input logic [             7:0] i_awlen,
    input logic [             2:0] i_awsize,
    input logic [             1:0] i_awburst,
    input logic                    i_awlock,
    input logic                    i_wvalid,
    input logic                    i_wready,
    input logic [  DATA_WIDTH-1:0] i_wdata,
    input logic [DATA_WIDTH/8-1:0] i_wstrb,
    input logic                    i_wlast,
    input logic                    i_bvalid,
    input logic                    i_bready,
    input logic [    ID_WIDTH-1:0] i_bid,
    input logic [             1:0] i_bresp,
    input logic                    i_arvalid,
    input logic                    i_arready,
    input logic [    ID_WIDTH-1:0] i_arid,
    input logic [  ADDR_WIDTH-1:0] i_araddr,
    input logic [             7:0] i_arlen,
    input logic [             2:0] i_arsize,
    input logic [             1:0] i_arburst,
    input logic                    i_arlock,
    input logic                    i_rvalid,
    input logic                    i_rready,
    input logic [    ID_WIDTH-1:0] i_rid,
    input logic [  DATA_WIDTH-1:0] i_rdata,
    input logic [             1:0] i_rresp,
    input logic                    i_rlast
);
`ifndef SYNTHESIS
`ifndef FORMAL
  localparam int unsigned BusSize = $clog2(DATA_WIDTH / 8);
  localparam int unsigned AwQueue = 16;

  // Whether an AW or AR form is legal AXI4 for this bus.
  function automatic logic legal_burst(input logic [11:0] addr, input logic [7:0] len,
                                       input logic [2:0] size, input logic [1:0] burst);
    logic [15:0] page_end;
    logic [11:0] start;
    start = addr & ~12'((32'd1 << size) - 32'd1);
    page_end = 16'(start) + ((16'(len) + 16'd1) << size);
    legal_burst = (32'(size) <= BusSize) && (burst != 2'b11) &&
        ((burst != 2'b00) || (len <= 8'd15)) &&
        ((burst != 2'b10) ||
         (((len == 8'd1) || (len == 8'd3) || (len == 8'd7) || (len == 8'd15)) &&
          ((addr & 12'((32'd1 << size) - 32'd1)) == 12'd0))) &&
        ((burst != 2'b01) || (page_end <= 16'd4096));
  endfunction

  // The previous cycle's handshake state and payloads.
  logic aw_wait_q, w_wait_q, b_wait_q, ar_wait_q, r_wait_q;
  logic [ID_WIDTH+ADDR_WIDTH+13:0] aw_q, ar_q;
  logic [DATA_WIDTH+DATA_WIDTH/8:0] w_q;
  logic [ID_WIDTH+1:0] b_q;
  logic [ID_WIDTH+DATA_WIDTH+2:0] r_q;

  // AWLENs of accepted AWs whose W bursts have not ended, and the beats seen
  // of the oldest one. W data that leads its AW is legal but ends the WLAST
  // checks, which assume W follows AW.
  logic [7:0] aw_len_q[AwQueue];
  int unsigned aw_head, aw_count, w_beats;
  logic w_led_q;
  // This cycle's handshakes, and the AWLEN the W beat belongs to: the oldest
  // waiting AW, or one accepted in the same cycle.
  logic aw_push, w_take, w_counted, w_ends;
  logic [7:0] head_len;
  always_comb begin
    aw_push = i_awvalid && i_awready;
    w_take = i_wvalid && i_wready;
    head_len = (aw_count == 0) ? i_awlen : aw_len_q[aw_head];
    w_counted = w_take && ((aw_count != 0) || aw_push);
    w_ends = w_beats == 32'(head_len);
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      aw_wait_q <= 1'b0;
      w_wait_q  <= 1'b0;
      b_wait_q  <= 1'b0;
      ar_wait_q <= 1'b0;
      r_wait_q  <= 1'b0;
      aw_head   <= 0;
      aw_count  <= 0;
      w_beats   <= 0;
      w_led_q   <= 1'b0;
    end else begin
      if (aw_wait_q && !(i_awvalid && (aw_q == {i_awid, i_awaddr, i_awlen, i_awsize, i_awburst,
                                                  i_awlock})))
        $error("axi_checker %0d: AW withdrawn or changed before AWREADY", PORT);
      if (w_wait_q && !(i_wvalid && (w_q == {i_wdata, i_wstrb, i_wlast})))
        $error("axi_checker %0d: W withdrawn or changed before WREADY", PORT);
      if (b_wait_q && !(i_bvalid && (b_q == {i_bid, i_bresp})))
        $error("axi_checker %0d: B withdrawn or changed before BREADY", PORT);
      if (ar_wait_q && !(i_arvalid && (ar_q == {i_arid, i_araddr, i_arlen, i_arsize, i_arburst,
                                                  i_arlock})))
        $error("axi_checker %0d: AR withdrawn or changed before ARREADY", PORT);
      if (r_wait_q && !(i_rvalid && (r_q == {i_rid, i_rdata, i_rresp, i_rlast})))
        $error("axi_checker %0d: R withdrawn or changed before RREADY", PORT);
      aw_wait_q <= i_awvalid && !i_awready;
      w_wait_q  <= i_wvalid && !i_wready;
      b_wait_q  <= i_bvalid && !i_bready;
      ar_wait_q <= i_arvalid && !i_arready;
      r_wait_q  <= i_rvalid && !i_rready;
      aw_q      <= {i_awid, i_awaddr, i_awlen, i_awsize, i_awburst, i_awlock};
      w_q       <= {i_wdata, i_wstrb, i_wlast};
      b_q       <= {i_bid, i_bresp};
      ar_q      <= {i_arid, i_araddr, i_arlen, i_arsize, i_arburst, i_arlock};
      r_q       <= {i_rid, i_rdata, i_rresp, i_rlast};

      if (i_awvalid && i_awready) begin
        if (!legal_burst(i_awaddr[11:0], i_awlen, i_awsize, i_awburst))
          $error(
              "axi_checker %0d: illegal AW addr %h len %0d size %0d burst %0d",
              PORT,
              i_awaddr,
              i_awlen,
              i_awsize,
              i_awburst
          );
        if (i_awlock) $warning("axi_checker %0d: exclusive AW performed as a normal write", PORT);
      end
      if (i_arvalid && i_arready) begin
        if (!legal_burst(i_araddr[11:0], i_arlen, i_arsize, i_arburst))
          $error(
              "axi_checker %0d: illegal AR addr %h len %0d size %0d burst %0d",
              PORT,
              i_araddr,
              i_arlen,
              i_arsize,
              i_arburst
          );
        if (i_arlock) $warning("axi_checker %0d: exclusive AR performed as a normal read", PORT);
      end

      // WLAST against AWLEN, while W has always followed its AW (or come
      // with it).
      if (w_take && (aw_count == 0) && !aw_push) w_led_q <= 1'b1;
      if (!w_led_q) begin
        if (aw_push) begin
          if (aw_count == AwQueue)
            $error("axi_checker %0d: more than %0d AWs await W", PORT, AwQueue);
          else aw_len_q[(aw_head+aw_count)%AwQueue] <= i_awlen;
        end
        if (w_counted) begin
          if (i_wlast != w_ends)
            $error(
                "axi_checker %0d: WLAST %0d on beat %0d of %0d",
                PORT,
                i_wlast,
                w_beats,
                32'(head_len) + 1
            );
          if (w_ends) begin
            w_beats <= 0;
            aw_head <= (aw_head + 1) % AwQueue;
          end else begin
            w_beats <= w_beats + 1;
          end
        end
        aw_count <= aw_count + (aw_push ? 1 : 0) - ((w_counted && w_ends) ? 1 : 0);
      end
    end
  end
`else
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign unused = ^{i_clk, i_rst};
`endif
`else
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign unused = ^{i_clk, i_rst};
`endif

endmodule : axi_checker
