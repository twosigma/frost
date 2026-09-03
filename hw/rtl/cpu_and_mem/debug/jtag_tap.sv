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
 * Generic IEEE 1149.1 test access port for the RISC-V debug transport module
 * (Phase 3 M3, plan D14). Five-bit instruction register with the standard
 * DTM encodings (IDCODE 0x01, DTMCS 0x10, DMI 0x11, BYPASS 0x1F; every other
 * code selects BYPASS), so any RISC-V-aware JTAG debugger drives it without
 * configuration. This TAP is what simulation and the portable synthesis
 * targets use (frost's i_jtag_* pins); on the Xilinx boards the same
 * downstream bundle comes from two BSCANE2 primitives on the FPGA's own TAP
 * instead (boards/xilinx_frost_subsystem.sv), which is why the interface to
 * dtm_core is expressed in BSCAN terms: TAP-state levels (capture / shift /
 * update / test-logic-reset) plus one select per DTM register.
 *
 * Timing follows the standard: the state machine and shift registers advance
 * on the rising edge of TCK, TDO changes on the falling edge. The instruction
 * register updates on the falling edge of TCK in Update-IR so the next
 * Capture-DR already sees the new selection; it resets to IDCODE in
 * Test-Logic-Reset. The data-register levels are exported as the current
 * state, so a consumer clocking on the rising edge of TCK sees "capture" on
 * the edge that leaves Capture-DR, one "shift" per bit clocked through
 * Shift-DR, and "update" on the edge that leaves Update-DR. That is exactly
 * the BSCANE2 contract dtm_core is written against.
 */
module jtag_tap #(
    parameter logic [31:0] IDCODE = 32'h1F05_7001
) (
    input  logic i_tck,
    input  logic i_tms,
    input  logic i_tdi,
    input  logic i_trst_n,
    output logic o_tdo,

    // BSCAN-style bundle to dtm_core (TCK domain)
    output logic o_tlr,        // TAP in Test-Logic-Reset
    output logic o_capture,    // TAP in Capture-DR
    output logic o_shift,      // TAP in Shift-DR
    output logic o_update,     // TAP in Update-DR
    output logic o_sel_dtmcs,  // IR == DTMCS
    output logic o_sel_dmi,    // IR == DMI
    input  logic i_tdo_dtmcs,  // dtm_core shift-register LSBs
    input  logic i_tdo_dmi
);

  localparam logic [4:0] IrIdcode = 5'h01;
  localparam logic [4:0] IrDtmcs = 5'h10;
  localparam logic [4:0] IrDmi = 5'h11;  // every other code (incl. 0x1F) is BYPASS

  typedef enum logic [3:0] {
    TestLogicReset,
    RunTestIdle,
    SelectDrScan,
    CaptureDr,
    ShiftDr,
    Exit1Dr,
    PauseDr,
    Exit2Dr,
    UpdateDr,
    SelectIrScan,
    CaptureIr,
    ShiftIr,
    Exit1Ir,
    PauseIr,
    Exit2Ir,
    UpdateIr
  } tap_state_e;

  tap_state_e state, state_next;

  always_comb begin
    unique case (state)
      TestLogicReset: state_next = i_tms ? TestLogicReset : RunTestIdle;
      RunTestIdle:    state_next = i_tms ? SelectDrScan : RunTestIdle;
      SelectDrScan:   state_next = i_tms ? SelectIrScan : CaptureDr;
      CaptureDr:      state_next = i_tms ? Exit1Dr : ShiftDr;
      ShiftDr:        state_next = i_tms ? Exit1Dr : ShiftDr;
      Exit1Dr:        state_next = i_tms ? UpdateDr : PauseDr;
      PauseDr:        state_next = i_tms ? Exit2Dr : PauseDr;
      Exit2Dr:        state_next = i_tms ? UpdateDr : ShiftDr;
      UpdateDr:       state_next = i_tms ? SelectDrScan : RunTestIdle;
      SelectIrScan:   state_next = i_tms ? TestLogicReset : CaptureIr;
      CaptureIr:      state_next = i_tms ? Exit1Ir : ShiftIr;
      ShiftIr:        state_next = i_tms ? Exit1Ir : ShiftIr;
      Exit1Ir:        state_next = i_tms ? UpdateIr : PauseIr;
      PauseIr:        state_next = i_tms ? Exit2Ir : PauseIr;
      Exit2Ir:        state_next = i_tms ? UpdateIr : ShiftIr;
      UpdateIr:       state_next = i_tms ? SelectDrScan : RunTestIdle;
      default:        state_next = TestLogicReset;
    endcase
  end

  always_ff @(posedge i_tck or negedge i_trst_n) begin
    if (!i_trst_n) state <= TestLogicReset;
    else state <= state_next;
  end

  // Instruction register: Capture-IR loads the mandatory ...01 pattern,
  // Shift-IR shifts LSB-first, Update-IR installs the new instruction on the
  // falling edge; Test-Logic-Reset selects IDCODE.
  logic [4:0] ir_shift;
  logic [4:0] ir = IrIdcode;
  always_ff @(posedge i_tck) begin
    if (state == CaptureIr) ir_shift <= 5'b00001;
    else if (state == ShiftIr) ir_shift <= {i_tdi, ir_shift[4:1]};
  end
  always_ff @(negedge i_tck or negedge i_trst_n) begin
    if (!i_trst_n) ir <= IrIdcode;
    else if (state == TestLogicReset) ir <= IrIdcode;
    else if (state == UpdateIr) ir <= ir_shift;
  end

  // Local data registers: IDCODE (32 bits, read-only) and BYPASS (1 bit).
  logic [31:0] idcode_shift;
  logic bypass_shift;
  logic sel_idcode;
  assign o_sel_dtmcs = (ir == IrDtmcs);
  assign o_sel_dmi   = (ir == IrDmi);
  assign sel_idcode  = (ir == IrIdcode);
  always_ff @(posedge i_tck) begin
    if (state == CaptureDr) begin
      idcode_shift <= IDCODE;
      bypass_shift <= 1'b0;
    end else if (state == ShiftDr) begin
      idcode_shift <= {i_tdi, idcode_shift[31:1]};
      bypass_shift <= i_tdi;
    end
  end

  assign o_tlr = (state == TestLogicReset);
  assign o_capture = (state == CaptureDr);
  assign o_shift = (state == ShiftDr);
  assign o_update = (state == UpdateDr);

  // TDO: the selected register's LSB during Shift-DR, the IR's during
  // Shift-IR; launched on the falling edge per the standard.
  logic tdo_next;
  always_comb begin
    if (state == ShiftIr) tdo_next = ir_shift[0];
    else if (o_sel_dmi) tdo_next = i_tdo_dmi;
    else if (o_sel_dtmcs) tdo_next = i_tdo_dtmcs;
    else if (sel_idcode) tdo_next = idcode_shift[0];
    else tdo_next = bypass_shift;
  end
  always_ff @(negedge i_tck) o_tdo <= tdo_next;

endmodule : jtag_tap
