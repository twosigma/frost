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
 * RISC-V Debug Transport Module core (Debug Spec 0.13.2 §6.1):
 * the dtmcs and dmi JTAG data registers, and the clock-domain crossing that
 * turns a dmi Update-DR into one request on the core-side Debug Module
 * Interface. The JTAG side is a BSCAN-style pin bundle in the TCK domain
 * (TAP-state levels plus one select per register), driven either by the
 * generic jtag_tap (simulation, portable synthesis) or by two BSCANE2
 * primitives on the FPGA's own TAP (boards; USER3 = dtmcs, USER4 = dmi, with
 * OpenOCD's `riscv set_ir` pointing the three DTM registers at the FPGA's
 * IDCODE and USER instructions).
 *
 * dtmcs: version 1 (0.13), abits 7, idle 3 (the Run-Test/Idle hint), and
 * dmistat, the sticky status alone (0 none, 2 failed, 3 busy). dmireset (W1)
 * clears the sticky status. dmihardreset (W1) also abandons a request in
 * flight: it is not issued again (the debug module may still perform it
 * once), its response is discarded when it arrives, and the DTM stays busy
 * until then. The debug module answers every request, one that arrives
 * during its reset once the reset ends, so no request stays in flight for
 * good.
 *
 * dmi: {address[6:0], data[31:0], op[1:0]}. Update-DR with op = read or write
 * starts a request unless the status is sticky or a request is still in
 * flight. A dmi capture or an attempted operation while a request is in
 * flight sets the sticky busy status (op = 3), the spec's rule for batched
 * scans. A failed response sets the sticky failed status (op = 2). Whichever
 * is set first lasts until dmireset, dmihardreset, or Test-Logic-Reset.
 * Capture-DR returns the last request's address and the data of the last
 * response kept, with op = the current status: the sticky status if set,
 * else 3 while a request is in flight, else 0.
 *
 * CDC: two-phase toggle handshakes through ASYNC_REG two-flop synchronizers.
 * The TCK domain writes the request payload together with its toggle and
 * changes it only after the response has returned; the core domain likewise
 * holds the response payload until the next request. Only a new request
 * moves the request toggle, so the core side never sees a request twice.
 * Neither toggle is ever reset (both domains initialize to 0), so a
 * core-side reset cannot desynchronize the pair.
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
  logic                ack_seen_q = 1'b0;  // last ack consumed
  logic                resp_arrived;
  logic [        31:0] resp_data_tck = '0;
  logic                drop_q = 1'b0;  // the response owed belongs to an abandoned request
  logic                hardreset;
  logic                resp_keep;
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
  // Busy clears on the edge that consumes the synchronized ack, which is the
  // edge that latches a kept response's payload below, so a Capture-DR that
  // sees busy=0 always captures the new data.
  assign busy = (req_toggle_q != ack_seen_q);
  assign dmi_status = (sticky_q != 2'd0) ? sticky_q : (busy ? 2'd3 : 2'd0);
  // dmistat is the sticky status: a request merely in flight is not an error.
  // [17] dmihardreset / [16] dmireset read 0, [15] reserved.
  assign dtmcs_value = {14'b0, 3'b000, DtmIdleHint, sticky_q, 6'(Abits), DtmVersion};

  // Latch the response payload when the synchronized ack toggles (the core
  // wrote it before toggling; the synchronizer delay orders the read). The
  // response owed to a request abandoned by dmihardreset, on this edge or
  // earlier, completes the handshake and is otherwise dropped. Only one
  // request is ever in flight, so the next response is that one.
  assign resp_arrived = (ack_sync2 != ack_seen_q);
  assign hardreset = !i_tlr && i_sel_dtmcs && !i_capture && !i_shift && i_update && dtmcs_shift[17];
  assign resp_keep = resp_arrived && !drop_q && !hardreset;
  always_ff @(posedge i_tck) begin
    if (resp_arrived) ack_seen_q <= ack_sync2;
    if (resp_keep) resp_data_tck <= resp_data_q;
    if (resp_arrived) drop_q <= 1'b0;
    else if (hardreset && busy) drop_q <= 1'b1;
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
      if (resp_keep && (resp_op_q == 2'd2) && (sticky_q == 2'd0)) sticky_q <= 2'd2;
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
