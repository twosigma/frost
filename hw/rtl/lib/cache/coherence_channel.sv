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

module coherence_channel #(
    parameter int unsigned WIDTH = 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_valid,
    output logic o_ready,
    input logic [WIDTH-1:0] i_payload,
    output logic o_valid,
    input logic i_ready,
    output logic [WIDTH-1:0] o_payload
);
  if (WIDTH < 1) begin : gen_invalid_config
    initial $fatal(1, "coherence_channel: invalid parameters");
  end
  assign o_ready = !o_valid && !i_rst;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_valid   <= 1'b0;
      o_payload <= '0;
    end else begin
      if (o_valid && i_ready) o_valid <= 1'b0;
      if (i_valid && o_ready) begin
        o_valid   <= 1'b1;
        o_payload <= i_payload;
      end
    end
  end
`ifdef FORMAL
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid && !$past(i_rst) && !i_rst) begin
      if ($past(o_valid && !i_ready)) begin
        assert (o_valid);
        assert (o_payload == $past(o_payload));
      end
      cover (o_valid && i_ready);
      if ($past(i_valid && o_ready)) begin
        assert (o_valid);
        assert (o_payload == $past(i_payload));
      end
    end
  end
`endif
endmodule
