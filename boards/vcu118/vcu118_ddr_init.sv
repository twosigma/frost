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

// Copyright (c) 2026 John Goodacre.

// Initialize mapped DDR4 on VCU118 after calibration and before CPU access.
// Initializes mapped memory with 512-bit single-beat AXI writes to establish
// valid ECC across the accessible address range.
module vcu118_ddr_init #(
    parameter int unsigned               ADDR_BITS       = 31,       // 2 GiB address space
    parameter int unsigned               DATA_BITS       = 512,      // 512-bit controller word
    parameter int unsigned               ID_BITS         = 5,
    parameter int unsigned               BEATS_PER_BURST = 1,
    parameter int unsigned               MAX_OUTSTANDING = 16,
    parameter int unsigned               REGION_BYTES    = 1 << 30,  // 1 GiB default active region
    parameter logic        [ID_BITS-1:0] WRITE_ID        = '0
) (
    input logic i_clk,
    input logic i_rst_n,
    input logic i_start,

    output logic o_busy,
    output logic o_done,

    output logic                 o_awvalid,
    input  logic                 i_awready,
    output logic [  ID_BITS-1:0] o_awid,
    output logic [ADDR_BITS-1:0] o_awaddr,
    output logic [          7:0] o_awlen,
    output logic [          2:0] o_awsize,
    output logic [          1:0] o_awburst,

    output logic                   o_wvalid,
    input  logic                   i_wready,
    output logic [  DATA_BITS-1:0] o_wdata,
    output logic [DATA_BITS/8-1:0] o_wstrb,
    output logic                   o_wlast,

    input  logic       i_bvalid,
    output logic       o_bready,
    input  logic [1:0] i_bresp
);

  localparam int unsigned BytesPerBeat = DATA_BITS / 8;
  localparam int unsigned BytesPerBurst = BytesPerBeat * BEATS_PER_BURST;
  localparam int unsigned TotalBursts = REGION_BYTES / BytesPerBurst;
  localparam int unsigned BurstBits = $clog2(TotalBursts + 1);
  localparam int unsigned BeatBits = (BEATS_PER_BURST > 1) ? $clog2(BEATS_PER_BURST) : 1;
  localparam int unsigned OutstandingCap =
      (MAX_OUTSTANDING < TotalBursts) ? MAX_OUTSTANDING : TotalBursts;

  logic [BurstBits-1:0] aw_q, w_q, b_q;
  logic [ADDR_BITS-1:0] addr_q;
  logic [ BeatBits-1:0] beat_q;
  logic                 done_q;
  logic                 resp_error_q;
  logic                 started_q;

  logic running, aw_fire, w_fire, w_burst_last, b_fire;
  assign running = started_q && !done_q;

  // Address and data channels operate independently according to the AXI4 specification.
  // Each is bounded by the region end and outstanding response capability.
  assign o_awvalid = running && (aw_q != BurstBits'(TotalBursts))
      && ((aw_q - b_q) != BurstBits'(OutstandingCap));
  assign o_awid = WRITE_ID;
  assign o_awaddr = addr_q;
  assign o_awlen = 8'(BEATS_PER_BURST - 1);
  assign o_awsize = 3'($clog2(BytesPerBeat));
  assign o_awburst = 2'b01;  // INCR

  assign o_wvalid = running && (w_q != BurstBits'(TotalBursts))
      && ((w_q - b_q) != BurstBits'(OutstandingCap));
  assign o_wdata = '0;
  assign o_wstrb = '1;
  assign o_wlast = beat_q == BeatBits'(BEATS_PER_BURST - 1);

  assign o_bready = running;

  assign aw_fire = o_awvalid && i_awready;
  assign w_fire = o_wvalid && i_wready;
  assign w_burst_last = w_fire && o_wlast;
  assign b_fire = i_bvalid && o_bready;

  assign o_busy = !done_q;
  assign o_done = done_q;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      aw_q         <= '0;
      w_q          <= '0;
      b_q          <= '0;
      addr_q       <= '0;
      beat_q       <= '0;
      done_q       <= 1'b0;
      started_q    <= 1'b0;
      resp_error_q <= 1'b0;
    end else begin
      if (i_start) started_q <= 1'b1;
      if (aw_fire) begin
        aw_q   <= aw_q + 1'b1;
        addr_q <= addr_q + ADDR_BITS'(BytesPerBurst);
      end
      if (w_fire) beat_q <= w_burst_last ? '0 : beat_q + 1'b1;
      if (w_burst_last) w_q <= w_q + 1'b1;
      if (b_fire) begin
        b_q <= b_q + 1'b1;
        if (i_bresp != 2'b00) resp_error_q <= 1'b1;
      end
      if ((w_q == BurstBits'(TotalBursts)) && (b_q == BurstBits'(TotalBursts)) && !resp_error_q)
        done_q <= 1'b1;
    end
  end

endmodule
