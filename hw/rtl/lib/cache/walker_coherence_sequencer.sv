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
 * walker_coherence_sequencer: makes the page-table walker's line reads
 * coherent with the L1D before they reach the L2. The walker port is a
 * read-only tagged line port with one read in flight, so this is the
 * read-only, one-entry counterpart of dma_coherence_sequencer. Each accepted
 * read goes through:
 *
 *   PROBE       PROBE_CLEAN to the L1D: a dirty copy is written back and
 *               stays valid and clean.
 *   PROBE_WAIT  the probe's acknowledgement, which the L1D sends once the
 *               level below has acknowledged any writeback the probe caused.
 *   ISSUE       the read is presented downstream from a request register.
 *               Its acceptance releases the L1D probe slot.
 *   RESP        the L2's response passes straight through to the walker
 *               port.
 *
 * A read therefore returns the line as ordered behind any dirty L1D copy
 * present at the probe's decision. Once accepted, it completes on its own: no
 * step waits on the walker, the pipeline, commit, or the store queue, and
 * walks cannot deadlock with cache maintenance. "The page-table walker port"
 * in hw/rtl/lib/cache/README.md explains why this is enough for coherence
 * (stores still in the store queue need not be covered) and why progress
 * holds.
 *
 * Timing: ready, the probe request, and the downstream request are flops that
 * track the state register, so the walker, the hierarchy's probe capture, and
 * the arbiter tree each see one flop. The release is a registered pulse. The
 * response is not registered, so the sequencer adds nothing to the walker's
 * PTE capture path.
 */
module walker_coherence_sequencer #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    // Walker-port ids, forwarded downstream unchanged.
    parameter int unsigned ID_BITS = 2,
    // L1D upstream id width and the id this port's probes carry, above the
    // ids the CPU adapter and the DMA sequencer use.
    parameter int unsigned PROBE_ID_BITS = 4,
    parameter int unsigned PROBE_ID = 11
) (
    input logic i_clk,
    input logic i_rst,

    // Walker port (slave side of the line protocol; reads only).
    input  logic                    i_walk_req_valid,
    output logic                    o_walk_req_ready,
    input  logic [  ADDR_WIDTH-1:0] i_walk_req_addr,
    input  logic [     ID_BITS-1:0] i_walk_req_id,
    output logic                    o_walk_resp_valid,
    output logic [     ID_BITS-1:0] o_walk_resp_id,
    output logic [LINE_BYTES*8-1:0] o_walk_resp_rdata,

    // Probe into the L1D (master): PROBE_CLEAN under PROBE_ID, firing on
    // valid && ready; the acknowledgement is this port's share of the L1D
    // response pulses (demultiplexed by id in the hierarchy); the release is
    // a one-cycle pulse that frees the probe slot.
    output logic                     o_probe_req_valid,
    input  logic                     i_probe_req_ready,
    output logic [   ADDR_WIDTH-1:0] o_probe_req_addr,
    output logic [PROBE_ID_BITS-1:0] o_probe_req_id,
    input  logic                     i_probe_ack_valid,
    output logic                     o_probe_release_valid,

    // Downstream line port (master, reads only) into the arbiter tree.
    output logic                    o_down_req_valid,
    input  logic                    i_down_req_ready,
    output logic [  ADDR_WIDTH-1:0] o_down_req_addr,
    output logic [     ID_BITS-1:0] o_down_req_id,
    input  logic                    i_down_resp_valid,
    input  logic [     ID_BITS-1:0] i_down_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_down_resp_rdata
);
  localparam int unsigned OffsetBits   = $clog2(LINE_BYTES);
  localparam int unsigned LineAddrBits = ADDR_WIDTH - OffsetBits;

  initial begin
    if (PROBE_ID >= (1 << PROBE_ID_BITS))
      $fatal(1, "walker_coherence_sequencer: probe id exceeds the L1D id space");
  end

  typedef enum logic [2:0] {
    S_IDLE,        // no read in flight; accept one
    S_PROBE,       // presenting PROBE_CLEAN to the L1D
    S_PROBE_WAIT,  // probe in flight, waiting for its acknowledgement
    S_ISSUE,       // presenting the read downstream
    S_RESP         // read accepted; waiting for the L2's response
  } state_e;

  state_e state_q;
  logic [LineAddrBits-1:0] line_q;
  logic [ID_BITS-1:0] id_q;
  // The three request-side outputs as flops (see the header on timing).
  // Ready is kept as its inverse so every flop here, like the state, is zero
  // out of reset.
  logic busy_q, probe_valid_q, down_valid_q;

  assign o_walk_req_ready = !busy_q;
  logic walk_req_fire;
  assign walk_req_fire = i_walk_req_valid && !busy_q;

  assign o_probe_req_valid = probe_valid_q;
  assign o_probe_req_addr = {line_q, {OffsetBits{1'b0}}};
  assign o_probe_req_id = PROBE_ID_BITS'(PROBE_ID);
  logic probe_fire;
  assign probe_fire = probe_valid_q && i_probe_req_ready;

  assign o_down_req_valid = down_valid_q;
  assign o_down_req_addr = {line_q, {OffsetBits{1'b0}}};
  assign o_down_req_id = id_q;
  logic down_fire;
  assign down_fire = down_valid_q && i_down_req_ready;

  // One read in flight, so every response on the port is this read's; the
  // arbiter tree echoes the id it was given.
  assign o_walk_resp_valid = i_down_resp_valid;
  assign o_walk_resp_id = i_down_resp_id;
  assign o_walk_resp_rdata = i_down_resp_rdata;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q               <= S_IDLE;
      busy_q                <= 1'b0;
      probe_valid_q         <= 1'b0;
      down_valid_q          <= 1'b0;
      o_probe_release_valid <= 1'b0;
    end else begin
      o_probe_release_valid <= 1'b0;
      unique case (state_q)
        S_IDLE: begin
          if (walk_req_fire) begin
            state_q       <= S_PROBE;
            busy_q        <= 1'b1;
            probe_valid_q <= 1'b1;
            line_q        <= i_walk_req_addr[ADDR_WIDTH-1:OffsetBits];
            id_q          <= i_walk_req_id;
          end
        end
        S_PROBE: begin
          if (probe_fire) begin
            state_q       <= S_PROBE_WAIT;
            probe_valid_q <= 1'b0;
          end
        end
        S_PROBE_WAIT: begin
          if (i_probe_ack_valid) begin
            state_q      <= S_ISSUE;
            down_valid_q <= 1'b1;
          end
        end
        S_ISSUE: begin
          if (down_fire) begin
            state_q               <= S_RESP;
            down_valid_q          <= 1'b0;
            o_probe_release_valid <= 1'b1;
          end
        end
        S_RESP: begin
          if (i_down_resp_valid) begin
            state_q <= S_IDLE;
            busy_q  <= 1'b0;
          end
        end
        default: begin
          state_q       <= S_IDLE;
          busy_q        <= 1'b0;
          probe_valid_q <= 1'b0;
          down_valid_q  <= 1'b0;
        end
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      // The output flops are exact twins of the state register.
      if (busy_q != (state_q != S_IDLE))
        $error("walker_coherence_sequencer: busy flop disagrees with the state");
      if (probe_valid_q != (state_q == S_PROBE))
        $error("walker_coherence_sequencer: probe-valid flop disagrees with the state");
      if (down_valid_q != (state_q == S_ISSUE))
        $error("walker_coherence_sequencer: down-valid flop disagrees with the state");
      if (i_probe_ack_valid && (state_q != S_PROBE_WAIT))
        $error("walker_coherence_sequencer: probe acknowledgement with no probe in flight");
      if (i_down_resp_valid && (state_q != S_RESP))
        $error("walker_coherence_sequencer: downstream response with no read outstanding");
      if (i_down_resp_valid && (i_down_resp_id != id_q))
        $error(
            "walker_coherence_sequencer: downstream response id %0d, read carried %0d",
            i_down_resp_id,
            id_q
        );
    end
  end
`endif

endmodule : walker_coherence_sequencer
