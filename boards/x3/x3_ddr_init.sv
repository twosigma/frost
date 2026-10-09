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
 * Initialize mapped DDR4 after calibration and before any other access.
 *
 * The X3's 72-bit DDR4 interface checks ECC on reads. Unwritten memory has
 * unrelated data and check bits, so reads may report ECC errors. The
 * controller does not initialize or scrub the array; its Microblaze MCS ECC
 * protects only calibration-processor BRAM. Write zeros, then raise o_done.
 * While o_busy is high, the board gives this block the write channels and
 * holds FROST and the JTAG DDR loader in reset.
 *
 * The controller's word is 512 bits; this port is 256 bits. Partial-word
 * writes would read uninitialized data to recompute ECC. Use aligned bursts
 * with DATA_BITS * BEATS_PER_BURST matching the controller word, so the width
 * converter can issue a full write without a read. S00_AXI in the block
 * design must allow that burst length. Multiple bursts share one AXI ID.
 *
 * No timeout or retry: any non-OKAY response permanently withholds o_done.
 * The controller returns OKAY; the interconnect returns DECERR for unroutable
 * requests. Missing ready or responses also prevent completion, leaving the
 * board in reset. The controller has an independent PLL and resets its AXI
 * interface on lock loss.
 *
 * Acknowledgement does not prove ECC correctness. The controller's ECC state,
 * read by fpga/ddr_ecc/ddr_ecc_status.py, detects errors only at addresses
 * subsequently read.
 *
 * REGION_BYTES exists so a bench can cover the whole region in a short run.
 */
module x3_ddr_init #(
    parameter int unsigned ADDR_BITS = 30,
    parameter int unsigned DATA_BITS = 256,
    parameter int unsigned ID_BITS = 5,
    // Beats per burst: DATA_BITS * BEATS_PER_BURST is the controller's word.
    parameter int unsigned BEATS_PER_BURST = 2,
    parameter int unsigned MAX_OUTSTANDING = 16,
    parameter int unsigned REGION_BYTES = 1 << 30,
    parameter logic [ID_BITS-1:0] WRITE_ID = '0
) (
    input logic i_clk,
    input logic i_rst_n,  // board clock generation is locked
    input logic i_start,  // DDR4 calibration reported, in this clock domain

    output logic o_busy,  // the write channels below are this module's
    output logic o_done,  // the region has been written and acknowledged

    // AXI4 write channels (master).
    output logic                   o_awvalid,
    input  logic                   i_awready,
    output logic [    ID_BITS-1:0] o_awid,
    output logic [  ADDR_BITS-1:0] o_awaddr,
    output logic [            7:0] o_awlen,
    output logic [            2:0] o_awsize,
    output logic [            1:0] o_awburst,
    output logic                   o_wvalid,
    input  logic                   i_wready,
    output logic [  DATA_BITS-1:0] o_wdata,
    output logic [DATA_BITS/8-1:0] o_wstrb,
    output logic                   o_wlast,
    input  logic                   i_bvalid,
    output logic                   o_bready,
    input  logic [            1:0] i_bresp
);

  localparam int unsigned BytesPerBeat = DATA_BITS / 8;
  localparam int unsigned BytesPerBurst = BytesPerBeat * BEATS_PER_BURST;
  localparam int unsigned TotalBursts = REGION_BYTES / BytesPerBurst;
  localparam int unsigned BurstBits = $clog2(TotalBursts + 1);
  localparam int unsigned BeatBits = (BEATS_PER_BURST > 1) ? $clog2(BEATS_PER_BURST) : 1;
  // Clamp to TotalBursts so the cap fits BurstBits. Truncation to zero would
  // prevent either channel from starting on a small region.
  localparam int unsigned OutstandingCap =
      (MAX_OUTSTANDING < TotalBursts) ? MAX_OUTSTANDING : TotalBursts;

  // Bursts whose address has been accepted, whose data has been sent in full,
  // and whose response has arrived. The first two are independent of each
  // other and run ahead of the third by at most OutstandingCap; all three
  // reach TotalBursts exactly once.
  logic [BurstBits-1:0] aw_q, w_q, b_q;
  logic [ADDR_BITS-1:0] addr_q;
  logic [ BeatBits-1:0] beat_q;
  logic                 done_q;
  // A response other than OKAY means some of the region was not written.
  logic                 resp_error_q;

  // i_start is latched rather than used directly: every valid below is
  // qualified by it, and a valid may not drop before its handshake, so a
  // calibration level that fell again mid-burst must not reach them.
  logic                 started_q;

  logic running, aw_fire, w_fire, w_burst_last, b_fire;
  assign running = started_q && !done_q;

  // Address and data are independent. Each is bounded by the region's end and
  // by the outstanding cap against the responses, and neither looks at the
  // other's ready: WVALID that waited for AWREADY would deadlock against a
  // slave that waits for WVALID before AWREADY, which the protocol allows.
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
      // Complete one cycle after all data and responses are counted, regardless
      // of response latency.
      if ((w_q == BurstBits'(TotalBursts)) && (b_q == BurstBits'(TotalBursts)) && !resp_error_q)
        done_q <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  initial begin
    if ((REGION_BYTES % BytesPerBurst) != 0)
      $fatal(
          1,
          "x3_ddr_init: %0d bytes is not a whole number of %0d-byte bursts",
          REGION_BYTES,
          BytesPerBurst
      );
    if (OutstandingCap == 0) $fatal(1, "x3_ddr_init: the outstanding cap is zero");
  end

  always_ff @(posedge i_clk) begin
    if (i_rst_n) begin
      // A response other than OKAY is handled rather than asserted against:
      // it latches the error above, which withholds completion for good.
      if (resp_error_q && done_q) $error("x3_ddr_init: completed although a write was refused");
      if ((aw_q - b_q) > BurstBits'(OutstandingCap))
        $error(
            "x3_ddr_init: %0d writes outstanding, above the %0d cap", aw_q - b_q, OutstandingCap
        );
      // Neither channel may pass the region's end. The n-th data burst belongs
      // to the n-th address, regardless of which channel arrives first.
      if (aw_q > BurstBits'(TotalBursts))
        $error("x3_ddr_init: address ran past the region at burst %0d", aw_q);
      if (w_q > BurstBits'(TotalBursts))
        $error("x3_ddr_init: data ran past the region at burst %0d", w_q);
      if (done_q && (o_awvalid || o_wvalid))
        $error("x3_ddr_init: still driving the write channels after o_done");
    end
  end
`endif

endmodule
