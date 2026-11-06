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

module coherence_read_payload_formal #(
    parameter int unsigned WIDTH = 42
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_allocate,
    input logic [2:0] i_allocate_id,
    input logic [WIDTH-1:0] i_payload
);
  logic past_valid = 1'b0;
  logic [8*WIDTH-1:0] payload, stored_payload, reference_stored;
  logic [WIDTH-1:0] write_payload, reference_write;
  logic [7:0] write_mask, reference_mask;
  always_ff @(posedge i_clk) begin
    past_valid <= 1'b1;
    if (!past_valid) assume (i_rst);
    if (i_rst) begin
      reference_write <= '0;
      reference_mask  <= '0;
    end else begin
      reference_write <= i_payload;
      reference_mask  <= i_allocate ? (8'h01 << i_allocate_id) : '0;
    end
    if (past_valid) begin
      assert (stored_payload == reference_stored);
      assert (write_payload == reference_write);
      assert (write_mask == reference_mask);
    end
  end
  for (genvar slot = 0; slot < 8; slot++) begin : gen_reference
    always_ff @(posedge i_clk) begin
      if (i_rst) reference_stored[slot*WIDTH+:WIDTH] <= '0;
      else if (reference_mask[slot]) reference_stored[slot*WIDTH+:WIDTH] <= reference_write;
      if (past_valid)
        assert (payload[slot*WIDTH+:WIDTH] == (reference_mask[slot] ? reference_write :
            reference_stored[slot*WIDTH+:WIDTH]));
    end
  end
  coherence_read_payload #(
      .WIDTH(WIDTH)
  ) dut (
      .i_clk,
      .i_rst,
      .i_allocate,
      .i_allocate_id,
      .i_payload,
      .o_payload(payload),
      .o_stored_payload(stored_payload),
      .o_write_payload(write_payload),
      .o_write_mask(write_mask)
  );
endmodule
