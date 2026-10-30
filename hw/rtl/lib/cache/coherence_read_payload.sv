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

// A buffered write forwards its payload to the addressed read slot.
module coherence_read_payload #(
    parameter int unsigned WIDTH = 42
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_allocate,
    input logic [2:0] i_allocate_id,
    input logic [WIDTH-1:0] i_payload,
    output logic [8*WIDTH-1:0] o_payload
);
  logic [WIDTH-1:0] write_payload_q;
  // The allocation arrives late; keep it in the data input rather than a
  // synchronous reset pin.
  (* extract_reset = "no" *) logic [7:0] write_mask_q;
  wire [7:0] write_mask = write_mask_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      write_payload_q <= '0;
      write_mask_q <= '0;
    end else begin
      write_payload_q <= i_payload;
      write_mask_q <= i_allocate ? (8'h01 << i_allocate_id) : 8'b0;
    end
  end
  for (genvar slot = 0; slot < 8; slot++) begin : gen_slot
    logic [WIDTH-1:0] payload_q;
    always_ff @(posedge i_clk) begin
      if (i_rst) payload_q <= '0;
      else if (write_mask[slot]) payload_q <= write_payload_q;
    end
    assign o_payload[slot*WIDTH+:WIDTH] = write_mask[slot] ? write_payload_q : payload_q;
`ifndef SYNTHESIS
    logic [WIDTH-1:0] reference_payload;
    logic reference_seen = 1'b0;
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        reference_payload <= '0;
        reference_seen <= 1'b1;
      end else if (i_allocate && i_allocate_id == 3'(slot)) begin
        reference_payload <= i_payload;
      end
      if (reference_seen) assert (o_payload[slot*WIDTH+:WIDTH] == reference_payload);
    end
`endif
  end
endmodule
