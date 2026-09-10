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
 * dma_coherence_sequencer: makes a DMA agent's line traffic coherent with the
 * L1D and the load queue before it reaches the L2, the ordering point ("home")
 * for every L2-bound port.
 *
 * The DMA port is an ordinary tagged line port (hw/rtl/lib/cache/README.md).
 * Each accepted request mans one lock entry and walks these phases:
 *
 *   write:  ADMIT      the load queue admits the line: no AMO or SC on it is
 *                      between its read and its write, and from now until
 *                      RELEASE the queue starts no AMO/LR/SC on it;
 *           PROBE      PROBE_INVAL to the L1D: a dirty copy is written back
 *                      (accepted by the L2 before the acknowledgement) and
 *                      every copy is invalidated. From the probe's decision
 *                      until this entry's release the L1D issues no fill of
 *                      the line: the L1D holds no copy, so a miss that fetched
 *                      before the write is ordered would carry the pre-write
 *                      line back into it;
 *           INVAL      the load queue drops its dword (L0) copies of the
 *                      line, flags executed-but-unretired loads of it for
 *                      replay, marks in-flight loads of it as not-to-fill and
 *                      in-flight LRs as reservation-suppressed, and clears a
 *                      matching reservation;
 *           ISSUE      the write is presented downstream through a request
 *                      register; its acceptance by the L2 orders it,
 *                      releases the L1D probe slot (the withheld fills now
 *                      fetch the post-write line) and pulses o_coh_release
 *                      for the queue's mirror;
 *           RESP       the L2's completion is forwarded to the DMA port.
 *   read:   PROBE      PROBE_CLEAN to the L1D: a dirty copy is written back
 *                      (accepted by the L2 before the acknowledgement) and
 *                      stays valid and clean;
 *           ISSUE/RESP as above, with the read data forwarded; the probe slot
 *                      is released at the L2's acceptance as well.
 *
 * Contract toward the DMA agent. A write's response means the write is
 * ordered at the home: every CPU load that observes memory after it sees the
 * new bytes, and the L1D held no copy from the probe until the write was
 * ordered. A load that observed memory before the write may still return its
 * old value afterwards; that is legal in coherence order, and the load
 * queue's replay of executed-but-unretired loads keeps program-order
 * consequences correct. A read's response carries the line as ordered at the
 * home behind any dirty L1D data. Requests to different lines are NOT ordered
 * with respect to each other (an agent orders dependent writes by waiting for
 * responses); requests to the same line serialize in acceptance order because
 * the second one waits for the first one's entry to retire.
 *
 * Progress. A probe waits only on L1D transients that resolve through the L2
 * and DDR: a fill of the probed line in flight before the probe's decision is
 * never withheld, and the withholding that starts at the decision ends at
 * this entry's release, which depends on the load queue and the L2 alone.
 * Nothing below waits on the DMA port. Ready for a new request depends on the
 * presented address (a free entry and no active entry on the same line),
 * which the line protocol permits.
 *
 * Timing. The admit and inval handshakes present a latched entry until it
 * fires, so the core may pipeline its answer; the probe is captured by a
 * register stage in the hierarchy; the downstream request is a register
 * loaded from the issuing entry; the release pulses are registered.
 */
module dma_coherence_sequencer #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    // DMA-port ids; forwarded downstream unchanged (unique among admitted
    // requests because every admitted request holds an entry).
    parameter int unsigned ID_BITS = 3,
    // Lock entries: DMA requests in flight between acceptance and response.
    parameter int unsigned NUM_LOCK = 3,
    // L1D upstream id width and the ids the probes carry: entry k probes with
    // id PROBE_ID_BASE + k, above the ids the CPU adapter uses.
    parameter int unsigned PROBE_ID_BITS = 3,
    parameter int unsigned PROBE_ID_BASE = 5,
    localparam int unsigned LockBits = (NUM_LOCK > 1) ? $clog2(NUM_LOCK) : 1
) (
    input logic i_clk,
    input logic i_rst,

    // DMA port (slave side of the line protocol).
    input  logic                    i_dma_req_valid,
    output logic                    o_dma_req_ready,
    input  logic                    i_dma_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_dma_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_dma_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_dma_req_wstrb,
    input  logic [     ID_BITS-1:0] i_dma_req_id,
    output logic                    o_dma_resp_valid,
    output logic [     ID_BITS-1:0] o_dma_resp_id,
    output logic [LINE_BYTES*8-1:0] o_dma_resp_rdata,

    // Probes into the L1D (master): a request fires on valid && ready; the
    // acknowledgement is the L1D response pulse carrying the probe's id; the
    // release pulse frees the L1D's probe slot (ends the fill withholding).
    output logic                     o_probe_req_valid,
    input  logic                     i_probe_req_ready,
    output logic [   ADDR_WIDTH-1:0] o_probe_req_addr,
    output logic                     o_probe_req_inval,
    output logic [PROBE_ID_BITS-1:0] o_probe_req_id,
    input  logic                     i_probe_ack_valid,
    input  logic [PROBE_ID_BITS-1:0] i_probe_ack_id,
    output logic                     o_probe_release_valid,
    output logic [PROBE_ID_BITS-1:0] o_probe_release_id,

    // Load-queue handshake. Admit: level with a latched entry, fires on
    // ready. Inval: level with a latched entry, fires on done. Release:
    // one-cycle pulse after the write is ordered.
    output logic                  o_coh_admit_valid,
    output logic [  LockBits-1:0] o_coh_admit_slot,
    output logic [ADDR_WIDTH-1:0] o_coh_admit_addr,
    input  logic                  i_coh_admit_ready,
    output logic                  o_coh_inval_valid,
    output logic [  LockBits-1:0] o_coh_inval_slot,
    input  logic                  i_coh_inval_done,
    output logic                  o_coh_release_valid,
    output logic [  LockBits-1:0] o_coh_release_slot,

    // Downstream line port (master) into the arbiter above the L2.
    output logic                    o_down_req_valid,
    input  logic                    i_down_req_ready,
    output logic                    o_down_req_write,
    output logic [  ADDR_WIDTH-1:0] o_down_req_addr,
    output logic [LINE_BYTES*8-1:0] o_down_req_wdata,
    output logic [  LINE_BYTES-1:0] o_down_req_wstrb,
    output logic [     ID_BITS-1:0] o_down_req_id,
    input  logic                    i_down_resp_valid,
    input  logic [     ID_BITS-1:0] i_down_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_down_resp_rdata
);
  localparam int unsigned LineBits = LINE_BYTES * 8;
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam int unsigned LineAddrBits = ADDR_WIDTH - OffsetBits;

  initial begin
    if (NUM_LOCK < 1) $fatal(1, "dma_coherence_sequencer: NUM_LOCK must be >= 1");
    if (PROBE_ID_BASE + NUM_LOCK > (1 << PROBE_ID_BITS))
      $fatal(1, "dma_coherence_sequencer: probe ids exceed the L1D id space");
  end

  typedef enum logic [2:0] {
    E_FREE,
    E_ADMIT,       // waiting for the load queue to admit the line (writes)
    E_PROBE,       // presenting the probe to the L1D
    E_PROBE_WAIT,  // probe in flight, waiting for its acknowledgement
    E_INVAL,       // load-queue invalidation (writes)
    E_ISSUE,       // presenting the request downstream
    E_RESP         // waiting for the downstream response
  } entry_state_e;

  entry_state_e state_q[NUM_LOCK];
  logic [LineAddrBits-1:0] line_q[NUM_LOCK];
  logic [NUM_LOCK-1:0] write_q;
  logic [LineBits-1:0] wdata_q[NUM_LOCK];
  logic [LINE_BYTES-1:0] wstrb_q[NUM_LOCK];
  logic [ID_BITS-1:0] id_q[NUM_LOCK];

  logic [NUM_LOCK-1:0] entry_valid;
  always_comb begin
    for (int k = 0; k < int'(NUM_LOCK); k++) entry_valid[k] = (state_q[k] != E_FREE);
  end

  function automatic logic [PROBE_ID_BITS-1:0] probe_id_of(input logic [LockBits-1:0] k);
    probe_id_of = PROBE_ID_BITS'(PROBE_ID_BASE) + PROBE_ID_BITS'(k);
  endfunction

  // ---------------------------------------------------------------------------
  // Acceptance: a free entry and no active entry on the same line.
  // ---------------------------------------------------------------------------
  logic [LineAddrBits-1:0] in_line;
  assign in_line = i_dma_req_addr[ADDR_WIDTH-1:OffsetBits];

  logic free_any, same_line_active;
  logic [LockBits-1:0] free_idx;
  always_comb begin
    free_any = 1'b0;
    free_idx = '0;
    same_line_active = 1'b0;
    for (int k = int'(NUM_LOCK) - 1; k >= 0; k--) begin
      if (!entry_valid[k]) begin
        free_any = 1'b1;
        free_idx = LockBits'(k);
      end
      if (entry_valid[k] && (line_q[k] == in_line)) same_line_active = 1'b1;
    end
  end
  assign o_dma_req_ready = free_any && !same_line_active;
  logic dma_req_fire;
  assign dma_req_fire = i_dma_req_valid && o_dma_req_ready;

  // ---------------------------------------------------------------------------
  // Per-phase selection. Probe presents the lowest entry each cycle (its
  // payload is consistent at the fire); issue copies the lowest entry into
  // the request register below. Admit and inval latch their entry until it
  // fires, so the core's pipelined answer names the entry it was computed
  // for.
  // ---------------------------------------------------------------------------
  logic admit_any, probe_any, inval_any, issue_any;
  logic [LockBits-1:0] admit_sel, probe_sel, inval_sel, issue_sel;
  always_comb begin
    admit_any = 1'b0;
    admit_sel = '0;
    probe_any = 1'b0;
    probe_sel = '0;
    inval_any = 1'b0;
    inval_sel = '0;
    issue_any = 1'b0;
    issue_sel = '0;
    for (int k = int'(NUM_LOCK) - 1; k >= 0; k--) begin
      if (state_q[k] == E_ADMIT) begin
        admit_any = 1'b1;
        admit_sel = LockBits'(k);
      end
      if (state_q[k] == E_PROBE) begin
        probe_any = 1'b1;
        probe_sel = LockBits'(k);
      end
      if (state_q[k] == E_INVAL) begin
        inval_any = 1'b1;
        inval_sel = LockBits'(k);
      end
      if (state_q[k] == E_ISSUE) begin
        issue_any = 1'b1;
        issue_sel = LockBits'(k);
      end
    end
  end

  logic admit_active_q, inval_active_q;
  logic [LockBits-1:0] admit_slot_q, inval_slot_q;
  assign o_coh_admit_valid = admit_active_q;
  assign o_coh_admit_slot  = admit_slot_q;
  assign o_coh_admit_addr  = {line_q[admit_slot_q], {OffsetBits{1'b0}}};
  logic admit_fire;
  assign admit_fire = admit_active_q && i_coh_admit_ready;

  assign o_coh_inval_valid = inval_active_q;
  assign o_coh_inval_slot = inval_slot_q;
  logic inval_fire;
  assign inval_fire = inval_active_q && i_coh_inval_done;

  assign o_probe_req_valid = probe_any;
  assign o_probe_req_addr  = {line_q[probe_sel], {OffsetBits{1'b0}}};
  assign o_probe_req_inval = write_q[probe_sel];
  assign o_probe_req_id    = probe_id_of(probe_sel);
  logic probe_fire;
  assign probe_fire = probe_any && i_probe_req_ready;

  // Probe acknowledgement decode: the id names the entry.
  logic ack_hit;
  logic [LockBits-1:0] ack_sel;
  always_comb begin
    ack_hit = 1'b0;
    ack_sel = '0;
    for (int k = 0; k < int'(NUM_LOCK); k++) begin
      if (i_probe_ack_valid && (state_q[k] == E_PROBE_WAIT) && (i_probe_ack_id == probe_id_of(
              LockBits'(k)
          ))) begin
        ack_hit = 1'b1;
        ack_sel = LockBits'(k);
      end
    end
  end

  // Registered downstream request. The lowest entry in E_ISSUE is copied
  // here when the register is free and moves to E_RESP at the copy; the
  // register presents the request until the arbiter accepts it, and the
  // release pulses fire at that acceptance (the L2's ordering point). This
  // keeps the entry state decode and the payload mux off the arbiter's
  // select and the L2's accept path.
  logic out_valid_q, out_write_q;
  logic [LockBits-1:0] out_slot_q;
  logic [LineAddrBits-1:0] out_line_q;
  logic [LineBits-1:0] out_wdata_q;
  logic [LINE_BYTES-1:0] out_wstrb_q;
  logic [ID_BITS-1:0] out_id_q;
  logic issue_load, out_fire;
  assign issue_load = issue_any && !out_valid_q;
  assign out_fire = out_valid_q && i_down_req_ready;
  assign o_down_req_valid = out_valid_q;
  assign o_down_req_write = out_write_q;
  assign o_down_req_addr  = {out_line_q, {OffsetBits{1'b0}}};
  assign o_down_req_wdata = out_wdata_q;
  assign o_down_req_wstrb = out_wstrb_q;
  assign o_down_req_id    = out_id_q;

  // Downstream response decode: the DMA id names the entry in E_RESP.
  logic resp_hit;
  logic [LockBits-1:0] resp_sel;
  always_comb begin
    resp_hit = 1'b0;
    resp_sel = '0;
    for (int k = 0; k < int'(NUM_LOCK); k++) begin
      if (i_down_resp_valid && (state_q[k] == E_RESP) && (id_q[k] == i_down_resp_id)) begin
        resp_hit = 1'b1;
        resp_sel = LockBits'(k);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Entry state
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int k = 0; k < int'(NUM_LOCK); k++) state_q[k] <= E_FREE;
      admit_active_q        <= 1'b0;
      inval_active_q        <= 1'b0;
      o_dma_resp_valid      <= 1'b0;
      o_coh_release_valid   <= 1'b0;
      o_probe_release_valid <= 1'b0;
      out_valid_q           <= 1'b0;
    end else begin
      o_dma_resp_valid      <= 1'b0;
      o_coh_release_valid   <= 1'b0;
      o_probe_release_valid <= 1'b0;

      // Latch the admit and inval presentations until they fire.
      if (admit_fire) begin
        admit_active_q        <= 1'b0;
        state_q[admit_slot_q] <= E_PROBE;
      end else if (!admit_active_q && admit_any) begin
        admit_active_q <= 1'b1;
        admit_slot_q   <= admit_sel;
      end
      if (inval_fire) begin
        inval_active_q        <= 1'b0;
        state_q[inval_slot_q] <= E_ISSUE;
      end else if (!inval_active_q && inval_any) begin
        inval_active_q <= 1'b1;
        inval_slot_q   <= inval_sel;
      end

      if (probe_fire) state_q[probe_sel] <= E_PROBE_WAIT;
      if (ack_hit) state_q[ack_sel] <= write_q[ack_sel] ? E_INVAL : E_ISSUE;
      if (out_fire) begin
        out_valid_q           <= 1'b0;
        o_probe_release_valid <= 1'b1;
        o_probe_release_id    <= probe_id_of(out_slot_q);
        if (out_write_q) begin
          o_coh_release_valid <= 1'b1;
          o_coh_release_slot  <= out_slot_q;
        end
      end
      if (issue_load) begin
        state_q[issue_sel] <= E_RESP;
        out_valid_q        <= 1'b1;
        out_slot_q         <= issue_sel;
        out_write_q        <= write_q[issue_sel];
        out_line_q         <= line_q[issue_sel];
        out_wdata_q        <= wdata_q[issue_sel];
        out_wstrb_q        <= write_q[issue_sel] ? wstrb_q[issue_sel] : '0;
        out_id_q           <= id_q[issue_sel];
      end
      if (resp_hit) begin
        state_q[resp_sel] <= E_FREE;
        o_dma_resp_valid  <= 1'b1;
        o_dma_resp_id     <= id_q[resp_sel];
        o_dma_resp_rdata  <= i_down_resp_rdata;
      end
      if (dma_req_fire) begin
        state_q[free_idx] <= i_dma_req_write ? E_ADMIT : E_PROBE;
        line_q[free_idx]  <= in_line;
        write_q[free_idx] <= i_dma_req_write;
        wdata_q[free_idx] <= i_dma_req_wdata;
        wstrb_q[free_idx] <= i_dma_req_wstrb;
        id_q[free_idx]    <= i_dma_req_id;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (i_probe_ack_valid && !ack_hit)
        $error(
            "dma_coherence_sequencer: probe acknowledgement %0d for no pending probe",
            i_probe_ack_id
        );
      if (i_down_resp_valid && !resp_hit)
        $error(
            "dma_coherence_sequencer: downstream response id %0d for no waiting entry",
            i_down_resp_id
        );
      if (dma_req_fire && i_dma_req_write && (i_dma_req_wstrb == '0))
        $error("dma_coherence_sequencer: DMA write with empty strobes");
      if (admit_active_q && (state_q[admit_slot_q] != E_ADMIT))
        $error("dma_coherence_sequencer: admit presented for an entry not in E_ADMIT");
      if (inval_active_q && (state_q[inval_slot_q] != E_INVAL))
        $error("dma_coherence_sequencer: inval presented for an entry not in E_INVAL");
      for (int k = 0; k < int'(NUM_LOCK); k++) begin
        if (dma_req_fire && entry_valid[k] && (id_q[k] == i_dma_req_id))
          $error("dma_coherence_sequencer: DMA id %0d reused while in flight", i_dma_req_id);
      end
    end
  end
`endif

endmodule : dma_coherence_sequencer
