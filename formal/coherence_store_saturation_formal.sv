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

module coherence_store_saturation_formal (
    input logic i_clk
);
  logic [5:0] cycle_q = 0;
  always_ff @(posedge i_clk) if (cycle_q != 47) cycle_q <= cycle_q + 1'b1;
  wire rst = cycle_q == 0;
  wire push = cycle_q >= 2 && cycle_q <= 35;
  wire pop = cycle_q >= 37 && cycle_q <= 39;
  wire seal = cycle_q == 3 || cycle_q == 36;
  wire [1:0] seal_index = cycle_q == 3 ? 2'd0 : 2'd2;
  wire [7:0] address = cycle_q == 2 ? 8'd0 : 8'd32;
  wire [63:0] data = 64'(cycle_q - 6'd2);
  logic ready, done;
  logic [2:0] count;
  logic [1:0] head;
  logic [3:0] valid, sealed;
  logic [3:0][  7:0] addresses;
  logic [3:0][255:0] images;
  logic [3:0][ 31:0] masks;
  logic [3:0][  5:0] contributors;
  logic [6:0] accepted_q = 0, installed_q = 0;
  logic saturated_q = 0, split_q = 0;
  coherence_store_buffer #(
      .ADDR_WIDTH(8),
      .TAG_BITS(2),
      .EP_BITS(2)
  ) dut (
      .i_clk,
      .i_rst(rst),
      .i_push(push),
      .i_addr(address),
      .i_data(data),
      .i_mask(8'd1),
      .i_tag(2'd0),
      .i_pop(pop),
      .i_seal(seal),
      .i_seal_index(seal_index),
      .i_acquire(1'b0),
      .i_acquire_index(2'd0),
      .i_acquire_ep(2'd0),
      .o_ready(ready),
      .o_done(done),
      .o_combined(),
      .o_count(count),
      .o_head(head),
      .o_valid(valid),
      .o_sealed(sealed),
      .o_acquired(),
      .o_addr(addresses),
      .o_data(images),
      .o_mask(masks),
      .o_tag(),
      .o_contributors(contributors),
      .o_ep()
  );
  always_ff @(posedge i_clk) begin
    if (!rst) begin
      if (push) begin
        assert ($past(ready) && !$past(rst));
        accepted_q <= accepted_q + 1'b1;
      end
      if (cycle_q > 1) assert (done == $past(push));
      if (cycle_q >= 3 && cycle_q <= 37) begin
        assert (head == 0 && valid[0] && contributors[0] == 1);
        assert (addresses[0] == 0 && images[0][7:0] == 0 && masks[0] == 1);
      end
      if (cycle_q == 35) begin
        assert (count == 2 && sealed[1] && contributors[1] == 32);
        assert (addresses[1] == 32 && images[1][7:0] == 32 && masks[1] == 1);
        saturated_q <= 1;
      end
      if (cycle_q == 36) begin
        assert (count == 3 && contributors[1] == 32 && contributors[2] == 1);
        assert (addresses[2] == 32 && images[2][7:0] == 33 && masks[2] == 1);
        split_q <= 1;
      end
      if (pop) begin
        assert (valid[head] && sealed[head]);
        assert (images[head][7:0] == (cycle_q == 37 ? 8'd0 : cycle_q == 38 ? 8'd32 : 8'd33));
        installed_q <= installed_q + 7'(contributors[head]);
      end
      if (cycle_q == 40) begin
        assert (count == 0 && accepted_q == 34 && installed_q == 34);
        p_saturation_drain :
        cover (saturated_q && split_q && count == 0 && accepted_q == 34 && installed_q == 34);
      end
    end
  end
endmodule
