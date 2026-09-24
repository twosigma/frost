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
 * x3_ddr_init: write the DDR4 region once, before anything can read it.
 *
 * The X3's DDR4 is 72 bits wide, so the controller checks ECC on every read.
 * A location nothing has written since power-up holds whatever the array came
 * up with, and its check code is unrelated to its data, so a read of it is
 * reported as a correctable or uncorrectable error unless the two happen to
 * agree. Nothing writes the array at
 * power-up: the controller has no initialization or scrubbing of its own (its
 * only other ECC option, Microblaze MCS ECC, protects the calibration
 * processor's own block RAM, not the DRAM). So this does it: after
 * calibration, and before the rest of the design leaves reset, it writes zeros
 * over the whole mapped region and reports when that is finished.
 *
 * Only the write channels exist. The module owns them while o_busy is high --
 * the board top gives it the controller's write port and holds the subsystem
 * and the JTAG image loader in reset until o_done -- and drives nothing after.
 *
 * Burst shape is the point, not a performance tweak. The controller's word is
 * 512 bits and this port is 256, so a single-beat write covers half a word and
 * the controller must read the other half to recompute the check code -- a
 * read of exactly the uninitialized data being fixed. Two beats per burst from
 * an aligned address give the width converter a full word to pass on, so the
 * initializing writes read nothing. BEATS_PER_BURST therefore tracks the
 * controller's word width, and the block design's S00_AXI declares a matching
 * maximum burst length.
 *
 * Several bursts are in flight at once, ordered by a single AXI id, so the
 * write data channel runs at a beat a cycle rather than a burst per round
 * trip. Address and data advance independently, each bounded only by the
 * outstanding cap against the responses: a master may not wait for AWREADY
 * before asserting WVALID, since a slave is allowed to wait for WVALID before
 * asserting AWREADY, and the two together would deadlock. The n-th data burst
 * still belongs to the n-th address, which is what the single id and the
 * in-order counters give. At 256 bits and 322.265625 MHz a gibibyte takes about
 * 0.1 seconds, once, before the first instruction.
 *
 * A write that is refused never counts as one that happened. The memory
 * controller's own B channel reports OKAY unconditionally, but it is not the
 * only thing on this path: the interconnect answers a request it cannot route
 * with DECERR, and a run that took one of those has not written what it
 * thinks it has. Any response other than OKAY therefore latches an error that
 * withholds o_done for good, which stops the board in the same way as a write
 * that never came back.
 *
 * A response says nothing about the check code left behind, though: a write
 * can be acknowledged and still leave a bad one. What the counters afterwards
 * show is the complement of that:
 * they report the reads that did happen, so they catch a region left
 * unwritten and then read, and they cannot speak for an address nobody read
 * (fpga/ddr_ecc/ddr_ecc_status.py, and the hardware regression's last
 * stage). Coverage is the counters here. Simulation checks the responses.
 *
 * This is fail-stop, with no timeout and no retry. If the level below stops
 * accepting, or loses a response it had already taken -- the controller has
 * its own PLL and resets its AXI interface on losing lock, independently of
 * the board clock that resets this module -- the counters keep a debt that
 * never retires, o_done never asserts, and the board stays held in reset.
 * That is deliberate: the alternative to a stopped board is a running one on
 * memory whose state nobody established. It is also indistinguishable from
 * the memory not working, which it very likely means.
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
  // exceed, so that it stays representable in the counter width. BurstBits
  // sizes TotalBursts; an unclamped larger cap would truncate against the
  // counters, and for a small enough region truncate to zero, which would
  // hold the address channel low and start nothing at all.
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

  // i_start is latched rather than used directly. A request channel may not
  // drop its valid before the handshake, and every valid below is qualified
  // by this; taking i_start straight would make a calibration line that fell
  // again mid-burst a protocol violation rather than a stall.
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
