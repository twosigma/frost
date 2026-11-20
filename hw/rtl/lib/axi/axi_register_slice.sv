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
 * axi_register_slice: full five-channel AXI4 register slice.
 *
 * Places a two-entry skid buffer on each AXI4 channel (AW, W, AR forward;
 * B, R reverse) so every VALID, payload, and READY output comes directly
 * from a register. There are zero combinational paths between slave and
 * master ports, and each channel sustains one beat per cycle when the
 * consumer is ready. Reset is synchronous active-high at the flops only.
 */
module axi_register_slice #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 256,
    parameter int unsigned ID_WIDTH   = 3
) (
    input logic i_clk,
    input logic i_rst,

    // Upstream AXI4 slave port (from master).
    input  logic                    i_s_awvalid,
    output logic                    o_s_awready,
    input  logic [    ID_WIDTH-1:0] i_s_awid,
    input  logic [  ADDR_WIDTH-1:0] i_s_awaddr,
    input  logic [             7:0] i_s_awlen,
    input  logic [             2:0] i_s_awsize,
    input  logic [             1:0] i_s_awburst,
    input  logic                    i_s_awlock,
    input  logic [             3:0] i_s_awcache,
    input  logic [             2:0] i_s_awprot,
    input  logic [             3:0] i_s_awqos,
    input  logic                    i_s_wvalid,
    output logic                    o_s_wready,
    input  logic [  DATA_WIDTH-1:0] i_s_wdata,
    input  logic [DATA_WIDTH/8-1:0] i_s_wstrb,
    input  logic                    i_s_wlast,
    output logic                    o_s_bvalid,
    input  logic                    i_s_bready,
    output logic [    ID_WIDTH-1:0] o_s_bid,
    output logic [             1:0] o_s_bresp,
    input  logic                    i_s_arvalid,
    output logic                    o_s_arready,
    input  logic [    ID_WIDTH-1:0] i_s_arid,
    input  logic [  ADDR_WIDTH-1:0] i_s_araddr,
    input  logic [             7:0] i_s_arlen,
    input  logic [             2:0] i_s_arsize,
    input  logic [             1:0] i_s_arburst,
    input  logic                    i_s_arlock,
    input  logic [             3:0] i_s_arcache,
    input  logic [             2:0] i_s_arprot,
    input  logic [             3:0] i_s_arqos,
    output logic                    o_s_rvalid,
    input  logic                    i_s_rready,
    output logic [    ID_WIDTH-1:0] o_s_rid,
    output logic [  DATA_WIDTH-1:0] o_s_rdata,
    output logic [             1:0] o_s_rresp,
    output logic                    o_s_rlast,

    // Downstream AXI4 master port (toward slave).
    output logic                    o_m_awvalid,
    input  logic                    i_m_awready,
    output logic [    ID_WIDTH-1:0] o_m_awid,
    output logic [  ADDR_WIDTH-1:0] o_m_awaddr,
    output logic [             7:0] o_m_awlen,
    output logic [             2:0] o_m_awsize,
    output logic [             1:0] o_m_awburst,
    output logic                    o_m_awlock,
    output logic [             3:0] o_m_awcache,
    output logic [             2:0] o_m_awprot,
    output logic [             3:0] o_m_awqos,
    output logic                    o_m_wvalid,
    input  logic                    i_m_wready,
    output logic [  DATA_WIDTH-1:0] o_m_wdata,
    output logic [DATA_WIDTH/8-1:0] o_m_wstrb,
    output logic                    o_m_wlast,
    input  logic                    i_m_bvalid,
    output logic                    o_m_bready,
    input  logic [    ID_WIDTH-1:0] i_m_bid,
    input  logic [             1:0] i_m_bresp,
    output logic                    o_m_arvalid,
    input  logic                    i_m_arready,
    output logic [    ID_WIDTH-1:0] o_m_arid,
    output logic [  ADDR_WIDTH-1:0] o_m_araddr,
    output logic [             7:0] o_m_arlen,
    output logic [             2:0] o_m_arsize,
    output logic [             1:0] o_m_arburst,
    output logic                    o_m_arlock,
    output logic [             3:0] o_m_arcache,
    output logic [             2:0] o_m_arprot,
    output logic [             3:0] o_m_arqos,
    input  logic                    i_m_rvalid,
    output logic                    o_m_rready,
    input  logic [    ID_WIDTH-1:0] i_m_rid,
    input  logic [  DATA_WIDTH-1:0] i_m_rdata,
    input  logic [             1:0] i_m_rresp,
    input  logic                    i_m_rlast
);
  localparam int unsigned AxPayBits = ID_WIDTH + ADDR_WIDTH + 8 + 3 + 2 + 1 + 4 + 3 + 4;
  localparam int unsigned WPayBits  = DATA_WIDTH + (DATA_WIDTH / 8) + 1;
  localparam int unsigned BPayBits  = ID_WIDTH + 2;
  localparam int unsigned RPayBits  = ID_WIDTH + DATA_WIDTH + 2 + 1;

  // ---- AW channel (slave -> master) ---------------------------------------
  logic aw_v0_q, aw_v1_q, aw_ready_q;
  logic [AxPayBits-1:0] aw_d0_q, aw_d1_q;
  wire [AxPayBits-1:0] aw_in = {
    i_s_awid,
    i_s_awaddr,
    i_s_awlen,
    i_s_awsize,
    i_s_awburst,
    i_s_awlock,
    i_s_awcache,
    i_s_awprot,
    i_s_awqos
  };
  wire aw_push = i_s_awvalid && aw_ready_q;
  wire aw_pop = aw_v0_q && i_m_awready;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      aw_v0_q    <= 1'b0;
      aw_v1_q    <= 1'b0;
      aw_ready_q <= 1'b0;
    end else begin
      case ({
        aw_push, aw_pop
      })
        2'b10: begin
          if (!aw_v0_q) begin
            aw_v0_q    <= 1'b1;
            aw_d0_q    <= aw_in;
            aw_ready_q <= 1'b1;
          end else begin
            aw_v1_q    <= 1'b1;
            aw_d1_q    <= aw_in;
            aw_ready_q <= 1'b0;
          end
        end
        2'b01: begin
          if (aw_v1_q) begin
            aw_v0_q    <= 1'b1;
            aw_d0_q    <= aw_d1_q;
            aw_v1_q    <= 1'b0;
            aw_ready_q <= 1'b1;
          end else begin
            aw_v0_q    <= 1'b0;
            aw_ready_q <= 1'b1;
          end
        end
        2'b11: begin
          aw_v0_q    <= 1'b1;
          aw_d0_q    <= aw_in;
          aw_ready_q <= 1'b1;
        end
        default: begin
          aw_ready_q <= !aw_v1_q;
        end
      endcase
    end
  end
  assign o_s_awready = aw_ready_q;
  assign o_m_awvalid = aw_v0_q;
  assign {
    o_m_awid,
    o_m_awaddr,
    o_m_awlen,
    o_m_awsize,
    o_m_awburst,
    o_m_awlock,
    o_m_awcache,
    o_m_awprot,
    o_m_awqos
  } = aw_d0_q;

  // ---- W channel (slave -> master) ----------------------------------------
  logic w_v0_q, w_v1_q, w_ready_q;
  logic [WPayBits-1:0] w_d0_q, w_d1_q;
  wire [WPayBits-1:0] w_in = {i_s_wdata, i_s_wstrb, i_s_wlast};
  wire w_push = i_s_wvalid && w_ready_q;
  wire w_pop = w_v0_q && i_m_wready;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      w_v0_q    <= 1'b0;
      w_v1_q    <= 1'b0;
      w_ready_q <= 1'b0;
    end else begin
      case ({
        w_push, w_pop
      })
        2'b10: begin
          if (!w_v0_q) begin
            w_v0_q    <= 1'b1;
            w_d0_q    <= w_in;
            w_ready_q <= 1'b1;
          end else begin
            w_v1_q    <= 1'b1;
            w_d1_q    <= w_in;
            w_ready_q <= 1'b0;
          end
        end
        2'b01: begin
          if (w_v1_q) begin
            w_v0_q    <= 1'b1;
            w_d0_q    <= w_d1_q;
            w_v1_q    <= 1'b0;
            w_ready_q <= 1'b1;
          end else begin
            w_v0_q    <= 1'b0;
            w_ready_q <= 1'b1;
          end
        end
        2'b11: begin
          w_v0_q    <= 1'b1;
          w_d0_q    <= w_in;
          w_ready_q <= 1'b1;
        end
        default: begin
          w_ready_q <= !w_v1_q;
        end
      endcase
    end
  end
  assign o_s_wready = w_ready_q;
  assign o_m_wvalid = w_v0_q;
  assign {o_m_wdata, o_m_wstrb, o_m_wlast} = w_d0_q;

  // ---- B channel (master -> slave) ----------------------------------------
  logic b_v0_q, b_v1_q, b_ready_q;
  logic [BPayBits-1:0] b_d0_q, b_d1_q;
  wire [BPayBits-1:0] b_in = {i_m_bid, i_m_bresp};
  wire b_push = i_m_bvalid && b_ready_q;
  wire b_pop = b_v0_q && i_s_bready;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      b_v0_q    <= 1'b0;
      b_v1_q    <= 1'b0;
      b_ready_q <= 1'b0;
    end else begin
      case ({
        b_push, b_pop
      })
        2'b10: begin
          if (!b_v0_q) begin
            b_v0_q    <= 1'b1;
            b_d0_q    <= b_in;
            b_ready_q <= 1'b1;
          end else begin
            b_v1_q    <= 1'b1;
            b_d1_q    <= b_in;
            b_ready_q <= 1'b0;
          end
        end
        2'b01: begin
          if (b_v1_q) begin
            b_v0_q    <= 1'b1;
            b_d0_q    <= b_d1_q;
            b_v1_q    <= 1'b0;
            b_ready_q <= 1'b1;
          end else begin
            b_v0_q    <= 1'b0;
            b_ready_q <= 1'b1;
          end
        end
        2'b11: begin
          b_v0_q    <= 1'b1;
          b_d0_q    <= b_in;
          b_ready_q <= 1'b1;
        end
        default: begin
          b_ready_q <= !b_v1_q;
        end
      endcase
    end
  end
  assign o_m_bready = b_ready_q;
  assign o_s_bvalid = b_v0_q;
  assign {o_s_bid, o_s_bresp} = b_d0_q;

  // ---- AR channel (slave -> master) ---------------------------------------
  logic ar_v0_q, ar_v1_q, ar_ready_q;
  logic [AxPayBits-1:0] ar_d0_q, ar_d1_q;
  wire [AxPayBits-1:0] ar_in = {
    i_s_arid,
    i_s_araddr,
    i_s_arlen,
    i_s_arsize,
    i_s_arburst,
    i_s_arlock,
    i_s_arcache,
    i_s_arprot,
    i_s_arqos
  };
  wire ar_push = i_s_arvalid && ar_ready_q;
  wire ar_pop = ar_v0_q && i_m_arready;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ar_v0_q    <= 1'b0;
      ar_v1_q    <= 1'b0;
      ar_ready_q <= 1'b0;
    end else begin
      case ({
        ar_push, ar_pop
      })
        2'b10: begin
          if (!ar_v0_q) begin
            ar_v0_q    <= 1'b1;
            ar_d0_q    <= ar_in;
            ar_ready_q <= 1'b1;
          end else begin
            ar_v1_q    <= 1'b1;
            ar_d1_q    <= ar_in;
            ar_ready_q <= 1'b0;
          end
        end
        2'b01: begin
          if (ar_v1_q) begin
            ar_v0_q    <= 1'b1;
            ar_d0_q    <= ar_d1_q;
            ar_v1_q    <= 1'b0;
            ar_ready_q <= 1'b1;
          end else begin
            ar_v0_q    <= 1'b0;
            ar_ready_q <= 1'b1;
          end
        end
        2'b11: begin
          ar_v0_q    <= 1'b1;
          ar_d0_q    <= ar_in;
          ar_ready_q <= 1'b1;
        end
        default: begin
          ar_ready_q <= !ar_v1_q;
        end
      endcase
    end
  end
  assign o_s_arready = ar_ready_q;
  assign o_m_arvalid = ar_v0_q;
  assign {
    o_m_arid,
    o_m_araddr,
    o_m_arlen,
    o_m_arsize,
    o_m_arburst,
    o_m_arlock,
    o_m_arcache,
    o_m_arprot,
    o_m_arqos
  } = ar_d0_q;

  // ---- R channel (master -> slave) ----------------------------------------
  logic r_v0_q, r_v1_q, r_ready_q;
  logic [RPayBits-1:0] r_d0_q, r_d1_q;
  wire [RPayBits-1:0] r_in = {i_m_rid, i_m_rdata, i_m_rresp, i_m_rlast};
  wire r_push = i_m_rvalid && r_ready_q;
  wire r_pop = r_v0_q && i_s_rready;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      r_v0_q    <= 1'b0;
      r_v1_q    <= 1'b0;
      r_ready_q <= 1'b0;
    end else begin
      case ({
        r_push, r_pop
      })
        2'b10: begin
          if (!r_v0_q) begin
            r_v0_q    <= 1'b1;
            r_d0_q    <= r_in;
            r_ready_q <= 1'b1;
          end else begin
            r_v1_q    <= 1'b1;
            r_d1_q    <= r_in;
            r_ready_q <= 1'b0;
          end
        end
        2'b01: begin
          if (r_v1_q) begin
            r_v0_q    <= 1'b1;
            r_d0_q    <= r_d1_q;
            r_v1_q    <= 1'b0;
            r_ready_q <= 1'b1;
          end else begin
            r_v0_q    <= 1'b0;
            r_ready_q <= 1'b1;
          end
        end
        2'b11: begin
          r_v0_q    <= 1'b1;
          r_d0_q    <= r_in;
          r_ready_q <= 1'b1;
        end
        default: begin
          r_ready_q <= !r_v1_q;
        end
      endcase
    end
  end
  assign o_m_rready = r_ready_q;
  assign o_s_rvalid = r_v0_q;
  assign {o_s_rid, o_s_rdata, o_s_rresp, o_s_rlast} = r_d0_q;
endmodule : axi_register_slice
