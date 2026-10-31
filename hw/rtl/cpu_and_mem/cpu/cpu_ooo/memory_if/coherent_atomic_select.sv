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

module coherent_atomic_select #(
    parameter int unsigned TAG_BITS = 5
) (
    input logic i_sc_valid,
    input logic [TAG_BITS-1:0] i_sc_tag,
    input logic i_amo_valid,
    input logic [TAG_BITS-1:0] i_amo_tag,
    input logic [TAG_BITS-1:0] i_head_tag,
    output logic o_arm_valid,
    output logic [TAG_BITS-1:0] o_arm_tag
);
  assign o_arm_valid = i_sc_valid ? (i_sc_tag == i_head_tag) :
      (i_amo_valid && i_amo_tag == i_head_tag);
  assign o_arm_tag = i_head_tag;
`ifdef FORMAL
  wire reference_valid = i_sc_valid || i_amo_valid;
  wire [TAG_BITS-1:0] reference_tag = i_sc_valid ? i_sc_tag : i_amo_tag;
  always_comb begin
    p_arm_qualification_exact :
    assert (o_arm_valid == (reference_valid && reference_tag == i_head_tag));
    if (o_arm_valid) p_arm_tag_exact : assert (o_arm_tag == reference_tag);
  end
`endif
endmodule
