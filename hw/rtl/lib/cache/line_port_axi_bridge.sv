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
 * line_port_axi_bridge -- line-port slave to AXI4 master.
 *
 * The bottom of the cache hierarchy: converts single-outstanding line
 * transactions into single-beat AXI4 bursts (AxLEN=0, AxSIZE=log2(LINE_BYTES),
 * 256-bit data). Writes drive AW and W concurrently and complete on B; reads
 * complete on R. IDs are constant 0; responses are assumed OKAY (checked in
 * simulation). One transaction in flight, matching the line protocol.
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
    output logic                    o_resp_valid,
    output logic [LINE_BYTES*8-1:0] o_resp_rdata,

    // AXI4 master (single-beat bursts).
    output logic                    o_axi_awvalid,
    input  logic                    i_axi_awready,
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
    input  logic [             1:0] i_axi_bresp,
    output logic                    o_axi_arvalid,
    input  logic                    i_axi_arready,
    output logic [            31:0] o_axi_araddr,
    output logic [             7:0] o_axi_arlen,
    output logic [             2:0] o_axi_arsize,
    output logic [             1:0] o_axi_arburst,
    input  logic                    i_axi_rvalid,
    output logic                    o_axi_rready,
    input  logic [LINE_BYTES*8-1:0] i_axi_rdata,
    input  logic [             1:0] i_axi_rresp,
    input  logic                    i_axi_rlast
);

  typedef enum logic [2:0] {
    B_IDLE,
    B_WRITE,   // AW/W handshakes in progress
    B_BRESP,   // waiting for the write response
    B_READ,    // AR handshake in progress
    B_RRESP,   // waiting for read data
    B_RESPOND  // pulse the line-port response
  } state_e;

  state_e state_q;

  logic [31:0] addr_q;
  logic [LINE_BYTES*8-1:0] wdata_q;
  logic [LINE_BYTES-1:0] wstrb_q;
  logic aw_done_q, w_done_q;
  logic [LINE_BYTES*8-1:0] rdata_q;

  assign o_req_ready   = (state_q == B_IDLE);

  // Constant burst geometry: one beat of LINE_BYTES.
  assign o_axi_awlen   = 8'd0;
  assign o_axi_awsize  = 3'($clog2(LINE_BYTES));
  assign o_axi_awburst = 2'b01;  // INCR
  assign o_axi_arlen   = 8'd0;
  assign o_axi_arsize  = 3'($clog2(LINE_BYTES));
  assign o_axi_arburst = 2'b01;  // INCR

  assign o_axi_awvalid = (state_q == B_WRITE) && !aw_done_q;
  assign o_axi_wvalid  = (state_q == B_WRITE) && !w_done_q;
  assign o_axi_awaddr  = addr_q;
  assign o_axi_wdata   = wdata_q;
  assign o_axi_wstrb   = wstrb_q;
  assign o_axi_wlast   = 1'b1;
  // Always ready for responses: the single-outstanding master can always
  // accept, and -- critically -- an image-load CPU reset that interrupts an
  // in-flight transaction must still drain the controller's response instead
  // of wedging the interconnect (stale data/acks are discarded by the reset
  // state machine).
  assign o_axi_bready  = 1'b1;

  assign o_axi_arvalid = (state_q == B_READ);
  assign o_axi_araddr  = addr_q;
  assign o_axi_rready  = 1'b1;  // see o_axi_bready

  assign o_resp_valid  = (state_q == B_RESPOND);
  assign o_resp_rdata  = rdata_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q   <= B_IDLE;
      aw_done_q <= 1'b0;
      w_done_q  <= 1'b0;
    end else begin
      unique case (state_q)
        B_IDLE: begin
          if (i_req_valid) begin
            addr_q    <= i_req_addr - BASE_ADDR;
            wdata_q   <= i_req_wdata;
            wstrb_q   <= i_req_wstrb;
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
            state_q   <= i_req_write ? B_WRITE : B_READ;
          end
        end

        B_WRITE: begin
          if (o_axi_awvalid && i_axi_awready) aw_done_q <= 1'b1;
          if (o_axi_wvalid && i_axi_wready) w_done_q <= 1'b1;
          if ((aw_done_q || (o_axi_awvalid && i_axi_awready)) &&
              (w_done_q || (o_axi_wvalid && i_axi_wready))) begin
            state_q <= B_BRESP;
          end
        end

        B_BRESP: if (i_axi_bvalid) state_q <= B_RESPOND;


        B_READ: if (i_axi_arready) state_q <= B_RRESP;

        B_RRESP: begin
          if (i_axi_rvalid) begin
            rdata_q <= i_axi_rdata;
            state_q <= B_RESPOND;
          end
        end

        B_RESPOND: state_q <= B_IDLE;

        default: state_q <= B_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (i_axi_bvalid && o_axi_bready && i_axi_bresp != 2'b00)
        $error("line_port_axi_bridge: write response error (bresp=%0d)", i_axi_bresp);
      if (i_axi_rvalid && o_axi_rready && i_axi_rresp != 2'b00)
        $error("line_port_axi_bridge: read response error (rresp=%0d)", i_axi_rresp);
      if (i_axi_rvalid && o_axi_rready && !i_axi_rlast)
        $error("line_port_axi_bridge: multi-beat read response (expected single beat)");
    end
  end
`endif

endmodule : line_port_axi_bridge
