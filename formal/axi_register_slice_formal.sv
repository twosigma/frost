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
 * Unbounded formal proof for axi_register_slice and axil_register_slice.
 *
 * Checks every channel (all five AXI4 channels and all five AXI4-Lite
 * channels) against an independent two-entry FIFO reference:
 * - Reset clears VALID and READY on the next edge.
 * - Held VALID and payload stability across stalled edges.
 * - Bit-exact FIFO payload ordering and beat conservation.
 * - Full one-beat-per-cycle throughput whenever occupancy <= 1 after reset.
 * - Unconstrained runtime resets and arbitrary upstream/downstream stalls.
 */
module axi_register_slice_formal (
    input logic        i_clk,
    input logic        i_rst,
    // AXI4 slave-side inputs (reduced widths)
    input logic        i_axi_s_awvalid,
    input logic [ 1:0] i_axi_s_awid,
    input logic [ 7:0] i_axi_s_awaddr,
    input logic [ 7:0] i_axi_s_awlen,
    input logic [ 2:0] i_axi_s_awsize,
    input logic [ 1:0] i_axi_s_awburst,
    input logic        i_axi_s_awlock,
    input logic [ 3:0] i_axi_s_awcache,
    input logic [ 2:0] i_axi_s_awprot,
    input logic [ 3:0] i_axi_s_awqos,
    input logic        i_axi_s_wvalid,
    input logic [15:0] i_axi_s_wdata,
    input logic [ 1:0] i_axi_s_wstrb,
    input logic        i_axi_s_wlast,
    input logic        i_axi_s_bready,
    input logic        i_axi_s_arvalid,
    input logic [ 1:0] i_axi_s_arid,
    input logic [ 7:0] i_axi_s_araddr,
    input logic [ 7:0] i_axi_s_arlen,
    input logic [ 2:0] i_axi_s_arsize,
    input logic [ 1:0] i_axi_s_arburst,
    input logic        i_axi_s_arlock,
    input logic [ 3:0] i_axi_s_arcache,
    input logic [ 2:0] i_axi_s_arprot,
    input logic [ 3:0] i_axi_s_arqos,
    input logic        i_axi_s_rready,
    // AXI4 master-side inputs
    input logic        i_axi_m_awready,
    input logic        i_axi_m_wready,
    input logic        i_axi_m_bvalid,
    input logic [ 1:0] i_axi_m_bid,
    input logic [ 1:0] i_axi_m_bresp,
    input logic        i_axi_m_arready,
    input logic        i_axi_m_rvalid,
    input logic [ 1:0] i_axi_m_rid,
    input logic [15:0] i_axi_m_rdata,
    input logic [ 1:0] i_axi_m_rresp,
    input logic        i_axi_m_rlast,
    // AXI4-Lite slave-side inputs
    input logic        i_axil_s_awvalid,
    input logic [ 7:0] i_axil_s_awaddr,
    input logic [ 2:0] i_axil_s_awprot,
    input logic        i_axil_s_wvalid,
    input logic [15:0] i_axil_s_wdata,
    input logic [ 1:0] i_axil_s_wstrb,
    input logic        i_axil_s_bready,
    input logic        i_axil_s_arvalid,
    input logic [ 7:0] i_axil_s_araddr,
    input logic [ 2:0] i_axil_s_arprot,
    input logic        i_axil_s_rready,
    // AXI4-Lite master-side inputs
    input logic        i_axil_m_awready,
    input logic        i_axil_m_wready,
    input logic        i_axil_m_bvalid,
    input logic [ 1:0] i_axil_m_bresp,
    input logic        i_axil_m_arready,
    input logic        i_axil_m_rvalid,
    input logic [15:0] i_axil_m_rdata,
    input logic [ 1:0] i_axil_m_rresp
);
  // AXI4 outputs
  logic axi_s_awready, axi_s_wready, axi_s_bvalid, axi_s_arready, axi_s_rvalid, axi_s_rlast;
  logic [1:0] axi_s_bid, axi_s_bresp, axi_s_rid, axi_s_rresp;
  logic [15:0] axi_s_rdata;
  logic axi_m_awvalid, axi_m_wvalid, axi_m_bready, axi_m_arvalid, axi_m_rready;
  logic axi_m_awlock, axi_m_wlast, axi_m_arlock;
  logic [1:0] axi_m_awid, axi_m_awburst, axi_m_arid, axi_m_arburst, axi_m_wstrb;
  logic [2:0] axi_m_awsize, axi_m_awprot, axi_m_arsize, axi_m_arprot;
  logic [3:0] axi_m_awcache, axi_m_awqos, axi_m_arcache, axi_m_arqos;
  logic [7:0] axi_m_awaddr, axi_m_awlen, axi_m_araddr, axi_m_arlen;
  logic [15:0] axi_m_wdata;

  axi_register_slice #(
      .ADDR_WIDTH(8),
      .DATA_WIDTH(16),
      .ID_WIDTH  (2)
  ) u_axi (
      .i_clk      (i_clk),
      .i_rst      (i_rst),
      .i_s_awvalid(i_axi_s_awvalid),
      .o_s_awready(axi_s_awready),
      .i_s_awid   (i_axi_s_awid),
      .i_s_awaddr (i_axi_s_awaddr),
      .i_s_awlen  (i_axi_s_awlen),
      .i_s_awsize (i_axi_s_awsize),
      .i_s_awburst(i_axi_s_awburst),
      .i_s_awlock (i_axi_s_awlock),
      .i_s_awcache(i_axi_s_awcache),
      .i_s_awprot (i_axi_s_awprot),
      .i_s_awqos  (i_axi_s_awqos),
      .i_s_wvalid (i_axi_s_wvalid),
      .o_s_wready (axi_s_wready),
      .i_s_wdata  (i_axi_s_wdata),
      .i_s_wstrb  (i_axi_s_wstrb),
      .i_s_wlast  (i_axi_s_wlast),
      .o_s_bvalid (axi_s_bvalid),
      .i_s_bready (i_axi_s_bready),
      .o_s_bid    (axi_s_bid),
      .o_s_bresp  (axi_s_bresp),
      .i_s_arvalid(i_axi_s_arvalid),
      .o_s_arready(axi_s_arready),
      .i_s_arid   (i_axi_s_arid),
      .i_s_araddr (i_axi_s_araddr),
      .i_s_arlen  (i_axi_s_arlen),
      .i_s_arsize (i_axi_s_arsize),
      .i_s_arburst(i_axi_s_arburst),
      .i_s_arlock (i_axi_s_arlock),
      .i_s_arcache(i_axi_s_arcache),
      .i_s_arprot (i_axi_s_arprot),
      .i_s_arqos  (i_axi_s_arqos),
      .o_s_rvalid (axi_s_rvalid),
      .i_s_rready (i_axi_s_rready),
      .o_s_rid    (axi_s_rid),
      .o_s_rdata  (axi_s_rdata),
      .o_s_rresp  (axi_s_rresp),
      .o_s_rlast  (axi_s_rlast),
      .o_m_awvalid(axi_m_awvalid),
      .i_m_awready(i_axi_m_awready),
      .o_m_awid   (axi_m_awid),
      .o_m_awaddr (axi_m_awaddr),
      .o_m_awlen  (axi_m_awlen),
      .o_m_awsize (axi_m_awsize),
      .o_m_awburst(axi_m_awburst),
      .o_m_awlock (axi_m_awlock),
      .o_m_awcache(axi_m_awcache),
      .o_m_awprot (axi_m_awprot),
      .o_m_awqos  (axi_m_awqos),
      .o_m_wvalid (axi_m_wvalid),
      .i_m_wready (i_axi_m_wready),
      .o_m_wdata  (axi_m_wdata),
      .o_m_wstrb  (axi_m_wstrb),
      .o_m_wlast  (axi_m_wlast),
      .i_m_bvalid (i_axi_m_bvalid),
      .o_m_bready (axi_m_bready),
      .i_m_bid    (i_axi_m_bid),
      .i_m_bresp  (i_axi_m_bresp),
      .o_m_arvalid(axi_m_arvalid),
      .i_m_arready(i_axi_m_arready),
      .o_m_arid   (axi_m_arid),
      .o_m_araddr (axi_m_araddr),
      .o_m_arlen  (axi_m_arlen),
      .o_m_arsize (axi_m_arsize),
      .o_m_arburst(axi_m_arburst),
      .o_m_arlock (axi_m_arlock),
      .o_m_arcache(axi_m_arcache),
      .o_m_arprot (axi_m_arprot),
      .o_m_arqos  (axi_m_arqos),
      .i_m_rvalid (i_axi_m_rvalid),
      .o_m_rready (axi_m_rready),
      .i_m_rid    (i_axi_m_rid),
      .i_m_rdata  (i_axi_m_rdata),
      .i_m_rresp  (i_axi_m_rresp),
      .i_m_rlast  (i_axi_m_rlast)
  );

  // AXI4-Lite outputs
  logic axil_s_awready, axil_s_wready, axil_s_bvalid, axil_s_arready, axil_s_rvalid;
  logic [1:0] axil_s_bresp, axil_s_rresp;
  logic [15:0] axil_s_rdata;
  logic axil_m_awvalid, axil_m_wvalid, axil_m_bready, axil_m_arvalid, axil_m_rready;
  logic [7:0] axil_m_awaddr, axil_m_araddr;
  logic [2:0] axil_m_awprot, axil_m_arprot;
  logic [15:0] axil_m_wdata;
  logic [ 1:0] axil_m_wstrb;

  axil_register_slice #(
      .ADDR_WIDTH(8),
      .DATA_WIDTH(16)
  ) u_axil (
      .i_clk      (i_clk),
      .i_rst      (i_rst),
      .i_s_awvalid(i_axil_s_awvalid),
      .o_s_awready(axil_s_awready),
      .i_s_awaddr (i_axil_s_awaddr),
      .i_s_awprot (i_axil_s_awprot),
      .i_s_wvalid (i_axil_s_wvalid),
      .o_s_wready (axil_s_wready),
      .i_s_wdata  (i_axil_s_wdata),
      .i_s_wstrb  (i_axil_s_wstrb),
      .o_s_bvalid (axil_s_bvalid),
      .i_s_bready (i_axil_s_bready),
      .o_s_bresp  (axil_s_bresp),
      .i_s_arvalid(i_axil_s_arvalid),
      .o_s_arready(axil_s_arready),
      .i_s_araddr (i_axil_s_araddr),
      .i_s_arprot (i_axil_s_arprot),
      .o_s_rvalid (axil_s_rvalid),
      .i_s_rready (i_axil_s_rready),
      .o_s_rdata  (axil_s_rdata),
      .o_s_rresp  (axil_s_rresp),
      .o_m_awvalid(axil_m_awvalid),
      .i_m_awready(i_axil_m_awready),
      .o_m_awaddr (axil_m_awaddr),
      .o_m_awprot (axil_m_awprot),
      .o_m_wvalid (axil_m_wvalid),
      .i_m_wready (i_axil_m_wready),
      .o_m_wdata  (axil_m_wdata),
      .o_m_wstrb  (axil_m_wstrb),
      .i_m_bvalid (i_axil_m_bvalid),
      .o_m_bready (axil_m_bready),
      .i_m_bresp  (i_axil_m_bresp),
      .o_m_arvalid(axil_m_arvalid),
      .i_m_arready(i_axil_m_arready),
      .o_m_araddr (axil_m_araddr),
      .o_m_arprot (axil_m_arprot),
      .i_m_rvalid (i_axil_m_rvalid),
      .o_m_rready (axil_m_rready),
      .i_m_rdata  (i_axil_m_rdata),
      .i_m_rresp  (i_axil_m_rresp)
  );

`ifdef FORMAL
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
  end

  // Helper macro: checks one 2-entry registered channel against an
  // independent reference FIFO scoreboard with zero input assumptions.
  `define CHECK_SLICE_CHAN(N, W, IV, IR, ID, OV, OR, OD, V0, V1, RQ, D0, D1) \
    logic [1:0] N``_cnt_q; \
    logic [W-1:0] N``_q0_q, N``_q1_q; \
    logic N``_just_rst_q, N``_held_q; \
    logic [W-1:0] N``_held_d_q; \
    wire N``_push = (IV) && (IR); \
    wire N``_pop  = (OV) && (OR); \
    always_ff @(posedge i_clk) begin \
      if (i_rst) begin \
        N``_cnt_q      <= 2'd0; \
        N``_just_rst_q <= 1'b1; \
        N``_held_q     <= 1'b0; \
      end else begin \
        N``_just_rst_q <= 1'b0; \
        N``_held_q     <= (OV) && !(OR); \
        N``_held_d_q   <= (OD); \
        case ({N``_push, N``_pop}) \
          2'b10: begin \
            if (N``_cnt_q == 2'd0) N``_q0_q <= (ID); \
            else N``_q1_q <= (ID); \
            N``_cnt_q <= N``_cnt_q + 2'd1; \
          end \
          2'b01: begin \
            N``_q0_q  <= N``_q1_q; \
            N``_cnt_q <= N``_cnt_q - 2'd1; \
          end \
          2'b11: begin \
            if (N``_cnt_q == 2'd1) N``_q0_q <= (ID); \
            else begin \
              N``_q0_q <= N``_q1_q; \
              N``_q1_q <= (ID); \
            end \
          end \
          default: ; \
        endcase \
      end \
    end \
    always_comb begin \
      if (f_past_valid) begin \
        assert (N``_cnt_q <= 2'd2); \
        assert ((OV) == (N``_cnt_q != 2'd0)); \
        if (N``_cnt_q != 2'd0) assert ((OD) == N``_q0_q); \
        if (N``_just_rst_q) begin \
          assert (!(OV)); \
          assert (!(IR)); \
        end else begin \
          assert ((IR) == (N``_cnt_q != 2'd2)); \
        end \
        if (N``_held_q) begin \
          assert (OV); \
          assert ((OD) == N``_held_d_q); \
        end \
        /* Inductive invariant tying internal skid storage to reference. */ \
        assert ((V0) == (N``_cnt_q >= 2'd1)); \
        assert ((V1) == (N``_cnt_q == 2'd2)); \
        assert ((RQ) == (!N``_just_rst_q && (N``_cnt_q != 2'd2))); \
        if (N``_cnt_q >= 2'd1) assert ((D0) == N``_q0_q); \
        if (N``_cnt_q == 2'd2) assert ((D1) == N``_q1_q); \
      end \
    end

  `CHECK_SLICE_CHAN(axi_aw, 35, i_axi_s_awvalid, axi_s_awready, {
                    i_axi_s_awid, i_axi_s_awaddr, i_axi_s_awlen, i_axi_s_awsize, i_axi_s_awburst,
                    i_axi_s_awlock, i_axi_s_awcache, i_axi_s_awprot, i_axi_s_awqos}, axi_m_awvalid,
                    i_axi_m_awready, {axi_m_awid, axi_m_awaddr, axi_m_awlen, axi_m_awsize,
                                      axi_m_awburst, axi_m_awlock, axi_m_awcache, axi_m_awprot,
                                      axi_m_awqos}, u_axi.aw_v0_q, u_axi.aw_v1_q, u_axi.aw_ready_q,
                    u_axi.aw_d0_q, u_axi.aw_d1_q)

  `CHECK_SLICE_CHAN(axi_w, 19, i_axi_s_wvalid, axi_s_wready, {i_axi_s_wdata, i_axi_s_wstrb,
                                                              i_axi_s_wlast}, axi_m_wvalid,
                    i_axi_m_wready, {axi_m_wdata, axi_m_wstrb, axi_m_wlast}, u_axi.w_v0_q,
                    u_axi.w_v1_q, u_axi.w_ready_q, u_axi.w_d0_q, u_axi.w_d1_q)

  `CHECK_SLICE_CHAN(axi_b, 4, i_axi_m_bvalid, axi_m_bready, {i_axi_m_bid, i_axi_m_bresp},
                    axi_s_bvalid, i_axi_s_bready, {axi_s_bid, axi_s_bresp}, u_axi.b_v0_q,
                    u_axi.b_v1_q, u_axi.b_ready_q, u_axi.b_d0_q, u_axi.b_d1_q)

  `CHECK_SLICE_CHAN(axi_ar, 35, i_axi_s_arvalid, axi_s_arready, {
                    i_axi_s_arid, i_axi_s_araddr, i_axi_s_arlen, i_axi_s_arsize, i_axi_s_arburst,
                    i_axi_s_arlock, i_axi_s_arcache, i_axi_s_arprot, i_axi_s_arqos}, axi_m_arvalid,
                    i_axi_m_arready, {axi_m_arid, axi_m_araddr, axi_m_arlen, axi_m_arsize,
                                      axi_m_arburst, axi_m_arlock, axi_m_arcache, axi_m_arprot,
                                      axi_m_arqos}, u_axi.ar_v0_q, u_axi.ar_v1_q, u_axi.ar_ready_q,
                    u_axi.ar_d0_q, u_axi.ar_d1_q)

  `CHECK_SLICE_CHAN(axi_r, 21, i_axi_m_rvalid, axi_m_rready, {i_axi_m_rid, i_axi_m_rdata,
                                                              i_axi_m_rresp, i_axi_m_rlast},
                    axi_s_rvalid, i_axi_s_rready, {axi_s_rid, axi_s_rdata, axi_s_rresp, axi_s_rlast
                    }, u_axi.r_v0_q, u_axi.r_v1_q, u_axi.r_ready_q, u_axi.r_d0_q, u_axi.r_d1_q)

  `CHECK_SLICE_CHAN(axil_aw, 11, i_axil_s_awvalid, axil_s_awready, {
                    i_axil_s_awaddr, i_axil_s_awprot}, axil_m_awvalid, i_axil_m_awready, {
                    axil_m_awaddr, axil_m_awprot}, u_axil.aw_v0_q, u_axil.aw_v1_q,
                    u_axil.aw_ready_q, u_axil.aw_d0_q, u_axil.aw_d1_q)

  `CHECK_SLICE_CHAN(axil_w, 18, i_axil_s_wvalid, axil_s_wready, {i_axil_s_wdata, i_axil_s_wstrb},
                    axil_m_wvalid, i_axil_m_wready, {axil_m_wdata, axil_m_wstrb}, u_axil.w_v0_q,
                    u_axil.w_v1_q, u_axil.w_ready_q, u_axil.w_d0_q, u_axil.w_d1_q)

  `CHECK_SLICE_CHAN(axil_b, 2, i_axil_m_bvalid, axil_m_bready, i_axil_m_bresp, axil_s_bvalid,
                    i_axil_s_bready, axil_s_bresp, u_axil.b_v0_q, u_axil.b_v1_q, u_axil.b_ready_q,
                    u_axil.b_d0_q, u_axil.b_d1_q)

  `CHECK_SLICE_CHAN(axil_ar, 11, i_axil_s_arvalid, axil_s_arready, {
                    i_axil_s_araddr, i_axil_s_arprot}, axil_m_arvalid, i_axil_m_arready, {
                    axil_m_araddr, axil_m_arprot}, u_axil.ar_v0_q, u_axil.ar_v1_q,
                    u_axil.ar_ready_q, u_axil.ar_d0_q, u_axil.ar_d1_q)

  `CHECK_SLICE_CHAN(axil_r, 18, i_axil_m_rvalid, axil_m_rready, {i_axil_m_rdata, i_axil_m_rresp},
                    axil_s_rvalid, i_axil_s_rready, {axil_s_rdata, axil_s_rresp}, u_axil.r_v0_q,
                    u_axil.r_v1_q, u_axil.r_ready_q, u_axil.r_d0_q, u_axil.r_d1_q)

  `undef CHECK_SLICE_CHAN

  // Covers: streaming throughput, full skid occupancy and drain, mid-flight reset.
  logic c_seen_full_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) c_seen_full_q <= 1'b0;
    else if (axi_aw_cnt_q == 2'd2) c_seen_full_q <= 1'b1;

    if (f_past_valid && !i_rst) begin
      cover (axi_w_push && axi_w_pop);
      cover (c_seen_full_q && (axi_aw_cnt_q == 2'd0));
      cover (axi_r_cnt_q == 2'd2);
      cover (axil_aw_cnt_q == 2'd2 && axil_r_push && axil_r_pop);
    end
    if (f_past_valid && i_rst) begin
      cover (axi_aw_cnt_q == 2'd2);
    end
  end
`endif
endmodule : axi_register_slice_formal
