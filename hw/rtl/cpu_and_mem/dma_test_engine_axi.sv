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
 * dma_test_engine_axi: the DMA test engine with an AXI4 master.
 *
 * dma_test_engine has one line request in flight at a time. This wrapper
 * carries each one over AXI4 and returns its response, with the error flag
 * from RRESP[1] or BRESP[1]. A line moves as one 32-byte beat (AxLEN 0,
 * AxSIZE 5, INCR), or, while the transfer's MODE has BURST set, as four 8-byte
 * beats on the same bus (AxLEN 3, AxSIZE 3): a write as an INCR burst from
 * the line's first byte, each beat strobing its own 8 bytes of the line's
 * strobes; a read as a WRAP burst starting at the line's dword number
 * (line index mod 4), each beat filling its dword. Addresses are full
 * physical addresses, zero-extended; ids are the engine's (1 to 3); AxCACHE
 * is 0011, AxPROT 010 and AxLOCK 0, and B and R are always accepted. The
 * wrapper resets with the engine.
 */
module dma_test_engine_axi #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned ID_BITS = 2,
    parameter logic [63:0] APERTURE_BASE = 64'h8000_0000,
    parameter logic [63:0] APERTURE_BYTES = 64'h4000_0000,
    parameter int unsigned DMA_AXI_ADDR_BITS = 64,
    parameter int unsigned DMA_AXI_ID_BITS = 2
) (
    input logic i_clk,
    input logic i_rst,

    // Register interface (dma_test_engine).
    input  logic        i_wr_en,
    input  logic [ 7:0] i_wr_offset,
    input  logic [31:0] i_wr_data,
    input  logic        i_wr64_en,
    input  logic [63:0] i_wr64_data,
    input  logic [ 7:0] i_rd_offset,
    output logic [63:0] o_rd_pair,
    output logic        o_irq,

    // DMA AXI4 master.
    output logic                         o_dma_axi_awvalid,
    input  logic                         i_dma_axi_awready,
    output logic [  DMA_AXI_ID_BITS-1:0] o_dma_axi_awid,
    output logic [DMA_AXI_ADDR_BITS-1:0] o_dma_axi_awaddr,
    output logic [                  7:0] o_dma_axi_awlen,
    output logic [                  2:0] o_dma_axi_awsize,
    output logic [                  1:0] o_dma_axi_awburst,
    output logic                         o_dma_axi_awlock,
    output logic [                  3:0] o_dma_axi_awcache,
    output logic [                  2:0] o_dma_axi_awprot,
    output logic [                  3:0] o_dma_axi_awqos,
    output logic                         o_dma_axi_wvalid,
    input  logic                         i_dma_axi_wready,
    output logic [     LINE_BYTES*8-1:0] o_dma_axi_wdata,
    output logic [       LINE_BYTES-1:0] o_dma_axi_wstrb,
    output logic                         o_dma_axi_wlast,
    input  logic                         i_dma_axi_bvalid,
    output logic                         o_dma_axi_bready,
    input  logic [  DMA_AXI_ID_BITS-1:0] i_dma_axi_bid,
    input  logic [                  1:0] i_dma_axi_bresp,
    output logic                         o_dma_axi_arvalid,
    input  logic                         i_dma_axi_arready,
    output logic [  DMA_AXI_ID_BITS-1:0] o_dma_axi_arid,
    output logic [DMA_AXI_ADDR_BITS-1:0] o_dma_axi_araddr,
    output logic [                  7:0] o_dma_axi_arlen,
    output logic [                  2:0] o_dma_axi_arsize,
    output logic [                  1:0] o_dma_axi_arburst,
    output logic                         o_dma_axi_arlock,
    output logic [                  3:0] o_dma_axi_arcache,
    output logic [                  2:0] o_dma_axi_arprot,
    output logic [                  3:0] o_dma_axi_arqos,
    input  logic                         i_dma_axi_rvalid,
    output logic                         o_dma_axi_rready,
    input  logic [  DMA_AXI_ID_BITS-1:0] i_dma_axi_rid,
    input  logic [     LINE_BYTES*8-1:0] i_dma_axi_rdata,
    input  logic [                  1:0] i_dma_axi_rresp,
    input  logic                         i_dma_axi_rlast
);
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);

  initial begin
    if (LINE_BYTES != 32) $fatal(1, "dma_test_engine_axi: LINE_BYTES must be 32");
    if (DMA_AXI_ID_BITS < ID_BITS) $fatal(1, "dma_test_engine_axi: DMA_AXI_ID_BITS < ID_BITS");
    if (DMA_AXI_ADDR_BITS < ADDR_WIDTH)
      $fatal(1, "dma_test_engine_axi: DMA_AXI_ADDR_BITS below ADDR_WIDTH");
  end

  logic req_valid, req_ready, req_write, resp_valid_q, resp_error_q, burst;
  logic [ADDR_WIDTH-1:0] req_addr;
  logic [LINE_BYTES*8-1:0] req_wdata, resp_rdata_q;
  logic [LINE_BYTES-1:0] req_wstrb;
  logic [ID_BITS-1:0] req_id, resp_id_q;

  dma_test_engine #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .ID_BITS(ID_BITS),
      .APERTURE_BASE(APERTURE_BASE),
      .APERTURE_BYTES(APERTURE_BYTES)
  ) engine (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_wr_en(i_wr_en),
      .i_wr_offset(i_wr_offset),
      .i_wr_data(i_wr_data),
      .i_wr64_en(i_wr64_en),
      .i_wr64_data(i_wr64_data),
      .i_rd_offset(i_rd_offset),
      .o_rd_pair(o_rd_pair),
      .o_irq(o_irq),
      .o_burst(burst),
      .o_dma_req_valid(req_valid),
      .i_dma_req_ready(req_ready),
      .o_dma_req_write(req_write),
      .o_dma_req_addr(req_addr),
      .o_dma_req_wdata(req_wdata),
      .o_dma_req_wstrb(req_wstrb),
      .o_dma_req_id(req_id),
      .i_dma_resp_valid(resp_valid_q),
      .i_dma_resp_error(resp_error_q),
      .i_dma_resp_id(resp_id_q),
      .i_dma_resp_rdata(resp_rdata_q)
  );

  // ---- the request in flight ---------------------------------------------------------------
  logic busy_q, write_q, burst_q, aw_valid_q, w_valid_q, ar_valid_q;
  logic [ADDR_WIDTH-OffsetBits-1:0] line_q;
  logic [LINE_BYTES*8-1:0] wdata_q;
  logic [LINE_BYTES-1:0] wstrb_q;
  logic [ID_BITS-1:0] id_q;
  logic [1:0] beat_q;  // the W or R beat of a burst-form transfer
  logic r_error_q;

  assign req_ready = !i_rst && !busy_q;
  logic req_fire;
  assign req_fire = req_valid && req_ready;

  // A WRAP read starts at the line's dword number; beat k carries dword
  // start + k (mod 4).
  logic [1:0] start_dword;
  assign start_dword = line_q[1:0];
  logic [1:0] r_dword;
  assign r_dword = start_dword + beat_q;

  logic [DMA_AXI_ADDR_BITS-1:0] line_addr;
  assign line_addr = DMA_AXI_ADDR_BITS'({line_q, {OffsetBits{1'b0}}});

  assign o_dma_axi_awvalid = aw_valid_q;
  assign o_dma_axi_awid = DMA_AXI_ID_BITS'(id_q);
  assign o_dma_axi_awaddr = line_addr;
  assign o_dma_axi_awlen = burst_q ? 8'd3 : 8'd0;
  assign o_dma_axi_awsize = burst_q ? 3'd3 : 3'd5;
  assign o_dma_axi_awburst = 2'b01;
  assign o_dma_axi_wvalid = w_valid_q;
  assign o_dma_axi_wdata = wdata_q;
  assign o_dma_axi_wstrb = burst_q ? (wstrb_q & (LINE_BYTES'(8'hff) << {beat_q, 3'b000})) : wstrb_q;
  assign o_dma_axi_wlast = !burst_q || (beat_q == 2'd3);
  assign o_dma_axi_bready = 1'b1;
  assign o_dma_axi_arvalid = ar_valid_q;
  assign o_dma_axi_arid = DMA_AXI_ID_BITS'(id_q);
  assign o_dma_axi_araddr = line_addr | (burst_q ? DMA_AXI_ADDR_BITS'({start_dword, 3'b000}) : '0);
  assign o_dma_axi_arlen = burst_q ? 8'd3 : 8'd0;
  assign o_dma_axi_arsize = burst_q ? 3'd3 : 3'd5;
  assign o_dma_axi_arburst = burst_q ? 2'b10 : 2'b01;
  assign o_dma_axi_rready = 1'b1;
  assign o_dma_axi_awlock = 1'b0;
  assign o_dma_axi_arlock = 1'b0;
  assign o_dma_axi_awcache = 4'b0011;
  assign o_dma_axi_arcache = 4'b0011;
  assign o_dma_axi_awprot = 3'b010;
  assign o_dma_axi_arprot = 3'b010;
  assign o_dma_axi_awqos = 4'd0;
  assign o_dma_axi_arqos = 4'd0;

  logic w_fire, b_fire, r_fire;
  assign w_fire = w_valid_q && i_dma_axi_wready;
  assign b_fire = i_dma_axi_bvalid && busy_q && write_q;
  assign r_fire = i_dma_axi_rvalid && busy_q && !write_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      busy_q       <= 1'b0;
      aw_valid_q   <= 1'b0;
      w_valid_q    <= 1'b0;
      ar_valid_q   <= 1'b0;
      resp_valid_q <= 1'b0;
    end else begin
      resp_valid_q <= 1'b0;
      if (req_fire) begin
        busy_q     <= 1'b1;
        write_q    <= req_write;
        burst_q    <= burst;
        line_q     <= req_addr[ADDR_WIDTH-1:OffsetBits];
        wdata_q    <= req_wdata;
        wstrb_q    <= req_wstrb;
        id_q       <= req_id;
        beat_q     <= '0;
        r_error_q  <= 1'b0;
        aw_valid_q <= req_write;
        w_valid_q  <= req_write;
        ar_valid_q <= !req_write;
      end
      if (aw_valid_q && i_dma_axi_awready) aw_valid_q <= 1'b0;
      if (ar_valid_q && i_dma_axi_arready) ar_valid_q <= 1'b0;
      if (w_fire) begin
        if (o_dma_axi_wlast) w_valid_q <= 1'b0;
        else beat_q <= beat_q + 1'b1;
      end
      if (b_fire) begin
        busy_q       <= 1'b0;
        resp_valid_q <= 1'b1;
        resp_id_q    <= id_q;
        resp_error_q <= i_dma_axi_bresp[1];
      end
      if (r_fire) begin
        if (burst_q) resp_rdata_q[64*r_dword+:64] <= i_dma_axi_rdata[64*r_dword+:64];
        else resp_rdata_q <= i_dma_axi_rdata;
        if (i_dma_axi_rlast) begin
          busy_q       <= 1'b0;
          resp_valid_q <= 1'b1;
          resp_id_q    <= id_q;
          resp_error_q <= r_error_q || i_dma_axi_rresp[1];
        end else begin
          beat_q    <= beat_q + 1'b1;
          r_error_q <= r_error_q || i_dma_axi_rresp[1];
        end
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic resp_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign resp_unused = ^{
      i_dma_axi_bid, i_dma_axi_rid, i_dma_axi_bresp[0], i_dma_axi_rresp[0], req_addr[OffsetBits-1:0]
  };

`ifndef SYNTHESIS
`ifndef FORMAL
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (i_dma_axi_bvalid && !(busy_q && write_q && !aw_valid_q && !w_valid_q))
        $error("dma_test_engine_axi: B with no write awaiting one");
      if (i_dma_axi_rvalid && !(busy_q && !write_q && !ar_valid_q))
        $error("dma_test_engine_axi: R with no read awaiting one");
      if (r_fire && (i_dma_axi_rlast != (!burst_q || (beat_q == 2'd3))))
        $error("dma_test_engine_axi: RLAST on the wrong beat");
    end
  end
`endif
`endif

endmodule : dma_test_engine_axi
