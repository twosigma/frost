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

module coherence_c_payload #(
    parameter int unsigned WIDTH = 50
) (
    input logic i_rst,
    input logic [2:0] i_selected,
    input logic [3*WIDTH-1:0] i_payload,
    output logic [WIDTH-1:0] o_payload
);
  assign o_payload = (i_payload[0+:WIDTH] & {WIDTH{i_selected[0]}}) |
      (i_payload[WIDTH+:WIDTH] & {WIDTH{i_selected[1]}}) |
      (i_payload[2*WIDTH+:WIDTH] & {WIDTH{i_selected[2]}});
`ifdef FORMAL
  logic [WIDTH-1:0] reference_payload;
  always_comb begin
    reference_payload = '0;
    for (int source = 0; source < 3; source++)
    reference_payload |= i_payload[source*WIDTH+:WIDTH] & {WIDTH{!i_rst && i_selected[source]}};
    if (!i_rst) p_c_payload_exact : assert (o_payload == reference_payload);
  end
`endif
endmodule
