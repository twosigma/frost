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
 * x3_ddr_init: write the whole mapped DDR4 region once, after calibration and
 * before anything can read it.
 *
 * The X3's DDR4 is 72 bits wide, so the controller checks ECC on every read.
 * A location not written since power-up has a check code unrelated to its
 * data, so a read of it reports a correctable or uncorrectable error unless
 * the two happen to agree. The controller neither initializes nor scrubs the
 * array (its Microblaze MCS ECC option protects only the calibration
 * processor's block RAM), so this module writes zeros over the region and
 * then raises o_done. It drives the write channels only while o_busy is high.
 * The board top gives it the controller's write channels and holds the
 * subsystem and the JTAG DDR loader in reset until o_done.
 *
 * The controller's word is 512 bits and this port is 256. A single-beat write
 * would cover half a word, and the controller would read the other,
 * uninitialized half to recompute the check code. Each burst is therefore
 * BEATS_PER_BURST beats from an aligned address, which gives the width
 * converter a full word to pass on, so the initializing writes read nothing.
 * BEATS_PER_BURST tracks the controller's word width, and the block design's
 * S00_AXI declares a matching maximum burst length. Several bursts are in
 * flight at once under a single AXI id, so the data channel can move a beat
 * every cycle: 1 GiB takes about 0.1 seconds at 322.265625 MHz.
 *
 * The module is fail-stop, with no timeout and no retry. Any response other
 * than OKAY latches an error that withholds o_done for good: the controller
 * always answers OKAY, but the interconnect answers a request it cannot route
 * with DECERR, and that write did not happen. o_done also never asserts if
 * the level below stops accepting or loses a response it already took (the
 * controller has its own PLL and resets its AXI interface on losing lock,
 * independently of this module's reset). The board then stays in reset
 * instead of running on memory in an unknown state.
 *
 * An acknowledged write can still leave a bad check code. On the board, the
 * controller's ECC error state (read by fpga/ddr_ecc/ddr_ecc_status.py, which
 * the hardware regression runs last) catches a region left unwritten and then
 * read, but says nothing about addresses nobody read.
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
  // The cap is clamped to the number of bursts, which it can never usefully
  // exceed, so that it fits the counter width (BurstBits sizes TotalBursts).
  // An unclamped larger cap would truncate, for a small enough region to
  // zero, which would hold both valids low and start nothing at all.
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
      // Done is read off the counters rather than off the last response, so
      // it needs no assumption about which cycle the level below returns
      // that response in: the region is written when every burst's data has
      // been sent and every burst has been acknowledged. It follows the
      // counters by a cycle, which the board top spends in reset anyway.
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
      // Neither channel passes the region's end. Either may lead the other:
      // the n-th data burst belongs to the n-th address whichever arrives
      // first, so their order between themselves is not a rule.
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
