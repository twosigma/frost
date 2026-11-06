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

// Four ordered sector records. Only the youngest unsealed record combines.
// Readiness reserves a record for the following cycle's registered write.
module coherence_store_buffer #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned TAG_BITS = 7,
    parameter int unsigned EP_BITS = 3
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_push,
    input logic [ADDR_WIDTH-1:0] i_addr,
    input logic [63:0] i_data,
    input logic [7:0] i_mask,
    input logic [TAG_BITS-1:0] i_tag,
    input logic i_pop,
    input logic i_seal,
    input logic [1:0] i_seal_index,
    input logic i_acquire,
    input logic [1:0] i_acquire_index,
    input logic [EP_BITS-1:0] i_acquire_ep,
    output logic o_ready,
    output logic o_done,
    output logic o_combined,
    output logic [2:0] o_count,
    output logic [1:0] o_head,
    output logic [3:0] o_valid,
    output logic [3:0] o_sealed,
    output logic [3:0] o_acquired,
    output logic [3:0][ADDR_WIDTH-1:0] o_addr,
    output logic [3:0][255:0] o_data,
    output logic [3:0][31:0] o_mask,
    output logic [3:0][TAG_BITS-1:0] o_tag,
    output logic [3:0][5:0] o_contributors,
    output logic [3:0][EP_BITS-1:0] o_ep
);
  logic [1:0] next_q, youngest, write_index;
  logic merge, allocate;
  assign youngest = next_q - 2'd1;
  assign merge = o_count != 0 && !o_sealed[youngest] &&
      o_addr[youngest][ADDR_WIDTH-1:5] == i_addr[ADDR_WIDTH-1:5];
  assign allocate = i_push && !merge;
  assign o_combined = i_push && merge;
  assign write_index = merge ? youngest : next_q;
  // Credit reserves for an arriving write without comparing its address.
  // A pop supplies no speculative credit.
  assign o_ready = o_count < 4 && !(o_count == 3 && i_push);
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_count <= '0;
      o_head  <= '0;
      next_q  <= '0;
      o_done  <= 1'b0;
    end else begin
      o_done  <= i_push;
      o_count <= o_count + 3'(allocate) - 3'(i_pop);
      if (i_pop) o_head <= o_head + 2'd1;
      if (allocate) next_q <= next_q + 2'd1;
    end
  end
  for (genvar slot = 0; slot < 4; slot++) begin : gen_record
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        o_valid[slot] <= 1'b0;
        o_sealed[slot] <= 1'b0;
        o_acquired[slot] <= 1'b0;
        o_addr[slot] <= '0;
        o_data[slot] <= '0;
        o_mask[slot] <= '0;
        o_tag[slot] <= '0;
        o_contributors[slot] <= '0;
        o_ep[slot] <= '0;
      end else begin
        if (i_pop && o_head == 2'(slot)) o_valid[slot] <= 1'b0;
        if (i_push && write_index == 2'(slot)) begin
          if (!merge) begin
            o_valid[slot] <= 1'b1;
            o_sealed[slot] <= 1'b0;
            o_acquired[slot] <= 1'b0;
            o_ep[slot] <= '0;
            o_addr[slot] <= {i_addr[ADDR_WIDTH-1:5], 5'b0};
            o_tag[slot] <= i_tag;
            o_mask[slot] <= 32'(i_mask) << {i_addr[4:3], 3'b000};
            o_contributors[slot] <= 6'd1;
          end else begin
            o_mask[slot] <= o_mask[slot] | (32'(i_mask) << {i_addr[4:3], 3'b000});
            o_contributors[slot] <= o_contributors[slot] + 6'd1;
            if (o_contributors[slot] == 31) o_sealed[slot] <= 1'b1;
          end
          for (int byte_index = 0; byte_index < 32; byte_index++)
          if (i_addr[4:3] == 2'(byte_index / 8) && i_mask[byte_index%8])
            o_data[slot][8*byte_index+:8] <= i_data[8*(byte_index%8)+:8];
        end
        // A simultaneous contributor is included before sealing.
        if (i_seal && i_seal_index == 2'(slot)) o_sealed[slot] <= 1'b1;
        if (i_acquire && i_acquire_index == 2'(slot)) begin
          o_acquired[slot] <= 1'b1;
          o_ep[slot] <= i_acquire_ep;
        end
      end
    end
  end
`ifdef FORMAL
  logic f_past_valid = 1'b0;
  logic [7:0] f_outstanding_q;
  logic [7:0] f_total;
  (* anyconst *) logic [4:0] f_byte;
  logic [3:0][7:0] f_byte_value_q;
  logic [3:0] f_byte_valid_q;
  always_comb begin
    f_total = '0;
    for (int slot = 0; slot < 4; slot++) if (o_valid[slot]) f_total += 8'(o_contributors[slot]);
  end
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (i_rst) begin
      f_outstanding_q <= '0;
      f_byte_value_q  <= '0;
      f_byte_valid_q  <= '0;
    end else begin
      if (i_push) assume (f_past_valid && !$past(i_rst) && $past(o_ready));
      if (i_pop) assume (o_valid[o_head] && o_sealed[o_head]);
      if (i_seal) assume (o_valid[i_seal_index]);
      if (i_acquire) assume (o_valid[i_acquire_index] && !o_acquired[i_acquire_index]);
      assume (!(i_pop && i_acquire && i_acquire_index == o_head));
      assume (!(i_pop && i_seal && i_seal_index == o_head));
      f_outstanding_q <= f_outstanding_q + 8'(i_push) - (i_pop ? 8'(o_contributors[o_head]) : 8'd0);
      if (i_push) begin
        if (!merge) f_byte_valid_q[write_index] <= 1'b0;
        if (i_addr[4:3] == f_byte[4:3] && i_mask[f_byte[2:0]]) begin
          f_byte_value_q[write_index] <= i_data[8*f_byte[2:0]+:8];
          f_byte_valid_q[write_index] <= 1'b1;
        end
      end
      assert (o_count <= 4);
      assert (next_q == 2'(o_head + 2'(o_count)));
      assert (f_total == f_outstanding_q && f_total <= 128);
      assert (!i_push || o_count < 4);
      for (int age = 0; age < 4; age++) begin
        assert (o_valid[2'(o_head+2'(age))] == (age < o_count));
        if (o_valid[age]) begin
          assert (o_contributors[age] >= 1 && o_contributors[age] <= 32);
          if (o_contributors[age] == 32) assert (o_sealed[age]);
          assert (o_mask[age][f_byte] == f_byte_valid_q[age]);
          if (o_mask[age][f_byte]) assert (o_data[age][8*f_byte+:8] == f_byte_value_q[age]);
        end
      end
      if (f_past_valid && !$past(i_rst)) begin
        assert (o_done == $past(i_push));
        for (int slot = 0; slot < 4; slot++)
        if ($past(o_valid[slot] && o_sealed[slot] && !(i_pop && o_head == 2'(slot)))) begin
          assert (o_valid[slot] && o_sealed[slot]);
          assert (o_data[slot] == $past(256'(o_data[slot])));
          assert (o_mask[slot] == $past(32'(o_mask[slot])));
          assert (o_tag[slot] == $past(TAG_BITS'(o_tag[slot])));
        end
      end
      cover (o_count == 4);
      cover (i_pop && i_push && merge);
      cover (i_seal && i_push && merge && i_seal_index == write_index);
      cover (o_acquired[o_head] && !o_sealed[o_head] && i_push && merge);
    end
  end
`endif
endmodule
