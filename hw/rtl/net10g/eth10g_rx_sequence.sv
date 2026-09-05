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

// Clause 49 receive state transitions, including R_TYPE_NEXT at termination.
// The upstream decoder guarantees representable XGMII words or i_bad_block.
// A full block is retained until the next enabled block arrives: a /T/ must
// be followed by C or S before a MAC can commit the frame. Pauses retain this
// lookahead. Reset on loss of PCS readiness to discard any pending frame end.
// Classification follows 49.2.13.2.3: /E/ makes an all-C (0x1e) block class E,
// but /E/ in the C fields of an ordered-set, start or terminate block remains
// representable and is propagated as specified by DECODE.
module eth10g_rx_sequence (
    input  logic        i_clk,
    input  logic        i_rst,
    input  logic        i_enable,
    input  logic [63:0] i_xgmii_data,
    input  logic [ 7:0] i_xgmii_ctrl,
    input  logic        i_bad_block,
    output logic [63:0] o_xgmii_data,
    output logic [ 7:0] o_xgmii_ctrl,
    output logic        o_valid,
    output logic        o_bad_sequence
);
  import eth10g_pcs_pkg::*;
  typedef enum logic [2:0] {
    CLASS_C,
    CLASS_S,
    CLASS_T,
    CLASS_D,
    CLASS_E
  } block_class_t;
  typedef enum logic [1:0] {
    RX_C,
    RX_D,
    RX_T,
    RX_E
  } state_t;
  block_class_t incoming_class, pending_class;
  state_t state, next_state;
  logic [63:0] pending_data;
  logic [ 7:0] pending_ctrl;
  logic pending_valid, sequence_error, has_error;

  always_comb begin
    incoming_class = CLASS_C;
    has_error = 1'b0;
    for (int lane = 0; lane < 8; lane++) begin
      if (i_xgmii_ctrl[lane]) begin
        if (i_xgmii_data[8*lane+:8] == XgmiiStart) incoming_class = CLASS_S;
        if (i_xgmii_data[8*lane+:8] == XgmiiTerm) incoming_class = CLASS_T;
        if (i_xgmii_data[8*lane+:8] == XgmiiError) has_error = 1'b1;
      end
    end
    if (i_xgmii_ctrl == 0) incoming_class = CLASS_D;
    if (i_bad_block || (incoming_class == CLASS_C && i_xgmii_ctrl == 8'hff && has_error))
      incoming_class = CLASS_E;

    next_state = RX_E;
    case (state)
      RX_C, RX_T: begin
        if (pending_class == CLASS_C) next_state = RX_C;
        else if (pending_class == CLASS_S) next_state = RX_D;
      end
      RX_D: begin
        if (pending_class == CLASS_D) next_state = RX_D;
        else if (pending_class == CLASS_T &&
                 (incoming_class == CLASS_C || incoming_class == CLASS_S))
          next_state = RX_T;
      end
      RX_E: begin
        if (pending_class == CLASS_C) next_state = RX_C;
        else if (pending_class == CLASS_D) next_state = RX_D;
        else if (pending_class == CLASS_T &&
                 (incoming_class == CLASS_C || incoming_class == CLASS_S))
          next_state = RX_T;
      end
      default: next_state = RX_E;
    endcase
    sequence_error = next_state == RX_E;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= RX_C;
      pending_valid <= 1'b0;
      pending_data <= '0;
      pending_ctrl <= '0;
      pending_class <= CLASS_E;
      o_xgmii_data <= {8{XgmiiError}};
      o_xgmii_ctrl <= 8'hff;
      o_valid <= 1'b0;
      o_bad_sequence <= 1'b0;
    end else begin
      o_valid <= 1'b0;
      o_bad_sequence <= 1'b0;
      if (i_enable) begin
        pending_valid <= 1'b1;
        pending_data  <= i_xgmii_data;
        pending_ctrl  <= i_xgmii_ctrl;
        pending_class <= incoming_class;
        if (pending_valid) begin
          state <= next_state;
          o_valid <= 1'b1;
          o_bad_sequence <= sequence_error;
          o_xgmii_data <= sequence_error ? {8{XgmiiError}} : pending_data;
          o_xgmii_ctrl <= sequence_error ? 8'hff : pending_ctrl;
        end
      end
    end
  end
endmodule
