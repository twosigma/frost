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
 * Simulation-only AXI4-Lite stability and response-conservation checks.
 * AW and W may arrive in either order. Responses require their accepted
 * request channels; EXOKAY is not an AXI4-Lite response. All ports are
 * observations. The body is empty in synthesis and formal builds.
 */
module axil_checker #(
    parameter int unsigned ADDR_BITS = 12
) (
    input logic i_clk,
    i_rst,
    input logic i_awvalid,
    i_awready,
    input logic [ADDR_BITS-1:0] i_awaddr,
    input logic [2:0] i_awprot,
    input logic i_wvalid,
    i_wready,
    input logic [63:0] i_wdata,
    input logic [7:0] i_wstrb,
    input logic i_bvalid,
    i_bready,
    input logic [1:0] i_bresp,
    input logic i_arvalid,
    i_arready,
    input logic [ADDR_BITS-1:0] i_araddr,
    input logic [2:0] i_arprot,
    input logic i_rvalid,
    i_rready,
    input logic [63:0] i_rdata,
    input logic [1:0] i_rresp
);
`ifndef SYNTHESIS
`ifndef FORMAL
  logic reset_seen_q = 1'b0;
  logic aw_wait_q, w_wait_q, b_wait_q, ar_wait_q, r_wait_q;
  logic [ADDR_BITS+2:0] aw_q, ar_q;
  logic [71:0] w_q;
  logic [ 1:0] b_q;
  logic [65:0] r_q;
  int unsigned aw_count, w_count, ar_count;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      reset_seen_q <= 1'b1;
      aw_wait_q <= 1'b0;
      w_wait_q <= 1'b0;
      b_wait_q <= 1'b0;
      ar_wait_q <= 1'b0;
      r_wait_q <= 1'b0;
      aw_count <= 0;
      w_count <= 0;
      ar_count <= 0;
    end else if (reset_seen_q) begin
      if (aw_wait_q)
        assert (i_awvalid && aw_q == {i_awaddr, i_awprot})
        else $error("axil_checker: AW withdrawn or changed before AWREADY");
      if (w_wait_q)
        assert (i_wvalid && w_q == {i_wdata, i_wstrb})
        else $error("axil_checker: W withdrawn or changed before WREADY");
      if (b_wait_q)
        assert (i_bvalid && b_q == i_bresp)
        else $error("axil_checker: B withdrawn or changed before BREADY");
      if (ar_wait_q)
        assert (i_arvalid && ar_q == {i_araddr, i_arprot})
        else $error("axil_checker: AR withdrawn or changed before ARREADY");
      if (r_wait_q)
        assert (i_rvalid && r_q == {i_rdata, i_rresp})
        else $error("axil_checker: R withdrawn or changed before RREADY");
      if (i_bvalid)
        assert (aw_count != 0 && w_count != 0 && i_bresp != 2'b01)
        else $error("axil_checker: B without AW and W, or EXOKAY");
      if (i_rvalid)
        assert (ar_count != 0 && i_rresp != 2'b01)
        else $error("axil_checker: R without AR, or EXOKAY");
      aw_wait_q <= i_awvalid && !i_awready;
      w_wait_q <= i_wvalid && !i_wready;
      b_wait_q <= i_bvalid && !i_bready;
      ar_wait_q <= i_arvalid && !i_arready;
      r_wait_q <= i_rvalid && !i_rready;
      aw_q <= {i_awaddr, i_awprot};
      w_q <= {i_wdata, i_wstrb};
      b_q <= i_bresp;
      ar_q <= {i_araddr, i_arprot};
      r_q <= {i_rdata, i_rresp};
      aw_count <= aw_count + 32'(i_awvalid && i_awready) - 32'(i_bvalid && i_bready);
      w_count <= w_count + 32'(i_wvalid && i_wready) - 32'(i_bvalid && i_bready);
      ar_count <= ar_count + 32'(i_arvalid && i_arready) - 32'(i_rvalid && i_rready);
    end
  end
`endif
`endif
endmodule
