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
  The vector unit's byte permutation block for one DLEN-wide element group.
  The crossbar output byte i is input byte i_idx[i], or zero when
  i_idx_valid[i] is clear; the sequencer turns vrgather indices, slide
  offsets and vcompress positions into these byte indices and, for a group
  wider than one source, steps through the source groups. The rotator output
  byte i is input byte (i + i_rot) mod BYTES, which aligns unit-stride data to
  and from memory and serves slides by a whole number of bytes. Both outputs
  appear a fixed one cycle after the cycle that takes the input.
*/
module vec_xbar #(
    parameter  int unsigned BYTES   = 32,
    localparam int unsigned IdxBits = $clog2(BYTES)
) (
    input  logic                            i_clk,
    input  logic                            i_rst,
    input  logic                            i_valid,
    input  logic [  BYTES-1:0][        7:0] i_data,
    input  logic [  BYTES-1:0][IdxBits-1:0] i_idx,
    input  logic [  BYTES-1:0]              i_idx_valid,
    input  logic [IdxBits-1:0]              i_rot,
    output logic                            o_valid,
    output logic [  BYTES-1:0][        7:0] o_gather,
    output logic [  BYTES-1:0][        7:0] o_rotate
);

  logic s0_valid;
  logic [BYTES-1:0][7:0] s0_data;
  logic [BYTES-1:0][IdxBits-1:0] s0_idx;
  logic [BYTES-1:0] s0_idx_valid;
  logic [IdxBits-1:0] s0_rot;
  always_ff @(posedge i_clk) begin
    if (i_rst) s0_valid <= 1'b0;
    else s0_valid <= i_valid;
    s0_data <= i_data;
    s0_idx <= i_idx;
    s0_idx_valid <= i_idx_valid;
    s0_rot <= i_rot;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) o_valid <= 1'b0;
    else o_valid <= s0_valid;
    for (int i = 0; i < int'(BYTES); i++) begin
      o_gather[i] <= s0_idx_valid[i] ? s0_data[s0_idx[i]] : 8'h00;
      o_rotate[i] <= s0_data[IdxBits'(IdxBits'(i)+s0_rot)];
    end
  end

endmodule
