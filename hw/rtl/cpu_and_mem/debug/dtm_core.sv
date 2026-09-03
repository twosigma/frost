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
 * RISC-V Debug Transport Module core (Debug Spec 0.13.2 §6.1, Phase 3 M3):
 * the dtmcs and dmi JTAG data registers, and the clock-domain crossing that
 * turns a dmi Update-DR into one request on the core-side Debug Module
 * Interface. The JTAG side is a BSCAN-style pin bundle in the TCK domain
 * (TAP-state levels plus one select per register), driven either by the
 * generic jtag_tap (simulation, portable synthesis) or by two BSCANE2
 * primitives on the FPGA's own TAP (boards; USER3 = dtmcs, USER4 = dmi, with
 * OpenOCD's `riscv set_ir` pointing the three DTM registers at the FPGA's
 * IDCODE and USER instructions).
 *
 * dtmcs: version 1 (0.13), abits 7, idle 3 (the Run-Test/Idle hint),
 * dmistat = the sticky status, dmireset (W1) clears it, dmihardreset (W1)
 * additionally re-synchronizes the request handshake (the debugger's escape
 * when it believes an in-flight request will never complete, e.g. after a
 * reset). dmi: {address[6:0], data[31:0], op[1:0]}. Update-DR with op = read
 * or write starts a request unless the status is sticky or a request is
 * still in flight; a scan that captures or attempts an operation while a
 * request is in flight makes the status sticky-busy (op = 3) until dmireset,
 * which is the spec's rule for batched scans. Capture-DR returns the last
 * response's data with op = the current status.
 *
 * CDC: two-phase toggle handshakes through ASYNC_REG two-flop synchronizers.
 * The request payload is written by the TCK domain together with its toggle
 * and does not change until the response has returned; the response payload
 * likewise sits still in the core domain until the next request. Neither
 * toggle is ever reset (both domains initialize to 0), so a core-side reset
 * cannot desynchronize the pair; dmihardreset re-aligns the TCK-side toggle
 * to the last acknowledged value. The TCK side latches the response payload
 * and clears busy on the same edge (one edge after the synchronized ack), so
 * a scan that captures busy=0 can never capture stale data.
 */
module dtm_core (
    // JTAG side (TCK domain, BSCAN-style bundle)
    input  logic i_tck,
    input  logic i_tlr,        // TAP in Test-Logic-Reset
    input  logic i_capture,    // TAP in Capture-DR
    input  logic i_shift,      // TAP in Shift-DR
    input  logic i_update,     // TAP in Update-DR
    input  logic i_sel_dtmcs,
    input  logic i_sel_dmi,
    input  logic i_tdi,
    output logic o_tdo_dtmcs,  // LSB of the dtmcs shift register
    output logic o_tdo_dmi,    // LSB of the dmi shift register

    // Core side: one DMI request at a time, answered by the debug module
    input  logic        i_clk,
    output logic        o_dmi_req_valid,   // one-cycle pulse
    output logic [ 1:0] o_dmi_req_op,      // 1 = read, 2 = write
    output logic [ 6:0] o_dmi_req_addr,
    output logic [31:0] o_dmi_req_data,
    input  logic        i_dmi_resp_valid,  // one-cycle pulse, in order
    input  logic [31:0] i_dmi_resp_data,
    input  logic [ 1:0] i_dmi_resp_op      // 0 = ok, 2 = failed
);

  localparam int unsigned Abits = 7;
  localparam int unsigned DmiWidth = Abits + 32 + 2;
  localparam logic [3:0] DtmVersion = 4'd1;
  localparam logic [2:0] DtmIdleHint = 3'd3;

  // ---------------------------------------------------------------------------
  // Declarations (both domains). The handshake flops carry power-up initial
  // values and no reset, as the header explains.
  // ---------------------------------------------------------------------------
  // TCK domain
  logic [        31:0] dtmcs_shift;
  logic [DmiWidth-1:0] dmi_shift;
  logic [         1:0] sticky_q = 2'd0;  // 0 none, 2 failed, 3 busy
  logic                req_toggle_q = 1'b0;
  logic [         1:0] req_op_q = 2'd0;
  logic [   Abits-1:0] req_addr_q = '0;
  logic [        31:0] req_data_q = '0;
  (* ASYNC_REG = "TRUE" *)logic                ack_sync1 = 1'b0;
  (* ASYNC_REG = "TRUE" *)logic                ack_sync2 = 1'b0;
  logic                ack_seen_q = 1'b0;  // last ack consumed (data latched)
  logic                resp_arrived;
  logic [        31:0] resp_data_tck = '0;
  logic [         1:0] resp_op_tck = 2'd0;
  logic                busy;
  logic [         1:0] dmi_status;
  logic [        31:0] dtmcs_value;
  // Core domain
  (* ASYNC_REG = "TRUE" *)logic                req_sync1 = 1'b0;
  (* ASYNC_REG = "TRUE" *)logic                req_sync2 = 1'b0;
  logic                req_seen_q = 1'b0;  // last request toggle serviced
  logic                ack_toggle_q = 1'b0;
  logic [        31:0] resp_data_q = '0;
  logic [         1:0] resp_op_q = 2'd0;

  // ---------------------------------------------------------------------------
  // TCK domain
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_tck) begin
    ack_sync1 <= ack_toggle_q;
    ack_sync2 <= ack_sync1;
  end
  // Busy clears only once the response payload has been latched below, so
  // a Capture-DR that sees busy=0 always captures the new data (the two are
  // updated on the same TCK edge, one edge after the synchronized ack).
  assign busy = (req_toggle_q != ack_seen_q);
  assign dmi_status = (sticky_q != 2'd0) ? sticky_q : (busy ? 2'd3 : 2'd0);
  // [17] dmihardreset / [16] dmireset read 0, [15] reserved.
  assign dtmcs_value = {14'b0, 3'b000, DtmIdleHint, dmi_status, 6'(Abits), DtmVersion};

  // Latch the response payload when the synchronized ack toggles (the core
  // wrote it before toggling; the synchronizer delay orders the read).
  assign resp_arrived = (ack_sync2 != ack_seen_q);
  always_ff @(posedge i_tck) begin
    if (resp_arrived) begin
      ack_seen_q    <= ack_sync2;
      resp_data_tck <= resp_data_q;
      resp_op_tck   <= resp_op_q;
    end
  end

  always_ff @(posedge i_tck) begin
    if (i_tlr) begin
      sticky_q <= 2'd0;
    end else begin
      // dtmcs
      if (i_sel_dtmcs) begin
        if (i_capture) dtmcs_shift <= dtmcs_value;
        else if (i_shift) dtmcs_shift <= {i_tdi, dtmcs_shift[31:1]};
        else if (i_update) begin
          if (dtmcs_shift[16] || dtmcs_shift[17]) sticky_q <= 2'd0;  // dmireset / dmihardreset
          if (dtmcs_shift[17]) req_toggle_q <= ack_seen_q;  // dmihardreset: forget in-flight
        end
      end
      // dmi
      if (i_sel_dmi) begin
        if (i_capture) begin
          dmi_shift <= {req_addr_q, resp_data_tck, dmi_status};
          if (busy && (sticky_q == 2'd0)) sticky_q <= 2'd3;
        end else if (i_shift) begin
          dmi_shift <= {i_tdi, dmi_shift[DmiWidth-1:1]};
        end else if (i_update) begin
          if ((sticky_q == 2'd0) && (dmi_shift[1:0] != 2'd0) && (dmi_shift[1:0] != 2'd3)) begin
            if (busy) begin
              sticky_q <= 2'd3;
            end else begin
              req_op_q     <= dmi_shift[1:0];
              req_addr_q   <= dmi_shift[DmiWidth-1:34];
              req_data_q   <= dmi_shift[33:2];
              req_toggle_q <= ~req_toggle_q;
            end
          end
        end
      end
      // A failed response is sticky like busy.
      if (resp_arrived && (resp_op_q == 2'd2) && (sticky_q == 2'd0)) sticky_q <= 2'd2;
    end
  end

  assign o_tdo_dtmcs = dtmcs_shift[0];
  assign o_tdo_dmi   = dmi_shift[0];

  // ---------------------------------------------------------------------------
  // Core domain
  // ---------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    req_sync1 <= req_toggle_q;
    req_sync2 <= req_sync1;
  end

  // One request pulse per toggle; the payload is stable by construction.
  assign o_dmi_req_valid = (req_sync2 != req_seen_q);
  assign o_dmi_req_op = req_op_q;
  assign o_dmi_req_addr = req_addr_q;
  assign o_dmi_req_data = req_data_q;

  always_ff @(posedge i_clk) begin
    if (o_dmi_req_valid) req_seen_q <= req_sync2;
    if (i_dmi_resp_valid) begin
      resp_data_q  <= i_dmi_resp_data;
      resp_op_q    <= i_dmi_resp_op;
      ack_toggle_q <= ~ack_toggle_q;
    end
  end

`ifndef SYNTHESIS
  // Every request must be answered exactly once before the next one starts.
  logic dmi_outstanding_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (o_dmi_req_valid && dmi_outstanding_q && !i_dmi_resp_valid)
      $error("dtm_core: DMI request issued while one is outstanding");
    if (i_dmi_resp_valid && !dmi_outstanding_q && !o_dmi_req_valid)
      $error("dtm_core: DMI response without a request");
    if (o_dmi_req_valid) dmi_outstanding_q <= 1'b1;
    else if (i_dmi_resp_valid) dmi_outstanding_q <= 1'b0;
  end
`endif

endmodule : dtm_core
