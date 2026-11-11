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
// A zero write (cbo.zero) allocates its block's lower sector as a sealed zero
// record, then, on the next cycle with a free record, the upper sector as the
// lower record's twin, and only then sends its done. Readiness stays low
// while the twin waits, so no write falls between them.
module coherence_store_buffer #(
    // 0 removes the cbo.zero records: a build that issues no zero writes.
    parameter bit ZERO_LINE = 1'b1,
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
    // With i_push: a cbo.zero of the 64-byte block at i_addr.
    input logic i_zero = 1'b0,
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
    // Allocation clears ownership before a later acquire can replace it.
    // Keep this priority on the data input instead of a combined enable.
    (* extract_reset = "no", extract_enable = "no" *) output logic [3:0] o_acquired,
    output logic [3:0][ADDR_WIDTH-1:0] o_addr,
    output logic [3:0][255:0] o_data,
    output logic [3:0][31:0] o_mask,
    output logic [3:0][TAG_BITS-1:0] o_tag,
    output logic [3:0][5:0] o_contributors,
    (* extract_reset = "no", extract_enable = "no" *) output logic [3:0][EP_BITS-1:0] o_ep,
    // A record of a cbo.zero block: every byte zero and masked, sealed.
    output logic [3:0] o_zero,
    // The upper record of a cbo.zero block, the twin of the record before it.
    // It counts no contributor: the lower record carries the write's.
    output logic [3:0] o_twin,
    // The twin waits for a record, and allocates on this cycle.
    output logic o_twin_pending,
    output logic o_twin_alloc,
    output logic [1:0] o_twin_index,
    output logic [ADDR_WIDTH-1:0] o_twin_addr
);
  logic [1:0] next_q, youngest, write_index;
  logic merge, allocate;
  logic twin_pending_q;
  logic [3:0] zero_q, twin_q;
  wire twin_pending = ZERO_LINE && twin_pending_q;
  wire zero_in = ZERO_LINE && i_zero;
  assign o_zero = ZERO_LINE ? zero_q : '0;
  assign o_twin = ZERO_LINE ? twin_q : '0;
  logic [ADDR_WIDTH-1:0] twin_addr_q;
  logic [  TAG_BITS-1:0] twin_tag_q;
  assign youngest = next_q - 2'd1;
  assign merge = !zero_in && o_count != 0 && !o_sealed[youngest] &&
      o_addr[youngest][ADDR_WIDTH-1:5] == i_addr[ADDR_WIDTH-1:5];
  assign allocate = i_push && !merge;
  assign o_combined = i_push && merge;
  assign write_index = merge ? youngest : next_q;
  // The twin takes the next record once one is free. No write arrives while
  // it waits; a pop on the same cycle supplies no record.
  assign o_twin_pending = twin_pending;
  assign o_twin_alloc = twin_pending && o_count < 4;
  assign o_twin_index = next_q;
  assign o_twin_addr = twin_addr_q;
  // Credit reserves for an arriving write without comparing its address.
  // A pop supplies no speculative credit. A zero write's twin holds the
  // credit until it allocates.
  assign o_ready = o_count < 4 && !(o_count == 3 && i_push) && !twin_pending &&
      !(i_push && zero_in);
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_count <= '0;
      o_head <= '0;
      next_q <= '0;
      o_done <= 1'b0;
      twin_pending_q <= 1'b0;
      twin_addr_q <= '0;
      twin_tag_q <= '0;
    end else begin
      o_done  <= (i_push && !zero_in) || o_twin_alloc;
      o_count <= o_count + 3'(allocate || o_twin_alloc) - 3'(i_pop);
      if (i_pop) o_head <= o_head + 2'd1;
      if (allocate || o_twin_alloc) next_q <= next_q + 2'd1;
      if (o_twin_alloc) twin_pending_q <= 1'b0;
      if (i_push && zero_in) begin
        twin_pending_q <= 1'b1;
        twin_addr_q <= {i_addr[ADDR_WIDTH-1:6], 6'b100000};
        twin_tag_q <= i_tag;
      end
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
        zero_q[slot] <= 1'b0;
        twin_q[slot] <= 1'b0;
      end else begin
        if (i_pop && o_head == 2'(slot)) o_valid[slot] <= 1'b0;
        // Allocation always targets next_q. Decode it directly, independently
        // of the combining record's address and the zero-write choice.
        if (allocate && next_q == 2'(slot)) begin
          o_valid[slot] <= 1'b1;
          o_sealed[slot] <= zero_in;
          o_acquired[slot] <= 1'b0;
          o_ep[slot] <= '0;
          o_addr[slot] <= {i_addr[ADDR_WIDTH-1:6], i_addr[5] && !zero_in, 5'b0};
          o_tag[slot] <= i_tag;
          o_mask[slot] <= zero_in ? '1 : 32'(i_mask) << {i_addr[4:3], 3'b000};
          o_contributors[slot] <= 6'd1;
          zero_q[slot] <= zero_in;
          twin_q[slot] <= 1'b0;
        end
        if (i_push && write_index == 2'(slot)) begin
          if (zero_in) begin
            o_data[slot] <= '0;
          end else begin
            if (merge) begin
              o_mask[slot] <= o_mask[slot] | (32'(i_mask) << {i_addr[4:3], 3'b000});
              o_contributors[slot] <= o_contributors[slot] + 6'd1;
              if (o_contributors[slot] == 31) o_sealed[slot] <= 1'b1;
            end
            for (int byte_index = 0; byte_index < 32; byte_index++)
            if (i_addr[4:3] == 2'(byte_index / 8) && i_mask[byte_index%8])
              o_data[slot][8*byte_index+:8] <= i_data[8*(byte_index%8)+:8];
          end
        end
        if (o_twin_alloc && next_q == 2'(slot)) begin
          o_valid[slot] <= 1'b1;
          o_sealed[slot] <= 1'b1;
          o_acquired[slot] <= 1'b0;
          o_ep[slot] <= '0;
          o_addr[slot] <= twin_addr_q;
          o_tag[slot] <= twin_tag_q;
          o_mask[slot] <= '1;
          o_data[slot] <= '0;
          o_contributors[slot] <= 6'd0;
          zero_q[slot] <= 1'b1;
          twin_q[slot] <= 1'b1;
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
  logic [3:0] f_lower_ok, f_twin_ok;
  always_comb begin
    f_total = '0;
    for (int slot = 0; slot < 4; slot++) if (o_valid[slot]) f_total += 8'(o_contributors[slot]);
  end
  for (genvar slot = 0; slot < 4; slot++) begin : gen_f_lower
    localparam int Next = (slot + 1) % 4;
    assign f_lower_ok[slot] = !(o_valid[slot] && o_zero[slot] && !o_twin[slot]) ||
        (youngest == slot[1:0] ? twin_pending_q : o_valid[Next] && o_twin[Next] &&
         o_addr[Next][ADDR_WIDTH-1:6] == o_addr[slot][ADDR_WIDTH-1:6]);
  end
  for (genvar slot = 0; slot < 4; slot++) begin : gen_f_twin
    localparam int Prev = (slot + 3) % 4;
    assign f_twin_ok[slot] = !(o_valid[slot] && o_twin[slot]) ||
        (o_head == slot[1:0] ? 1'b1 :
         o_valid[Prev] && o_zero[Prev] && !o_twin[Prev] &&
         o_addr[Prev][ADDR_WIDTH-1:6] == o_addr[slot][ADDR_WIDTH-1:6]);
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
      if (i_zero) assume (i_push);
      if (i_pop) assume (o_valid[o_head] && o_sealed[o_head]);
      // A lower zero record installs only after its twin allocates.
      if (i_pop && twin_pending_q) assume (o_head != youngest);
      if (i_seal) assume (o_valid[i_seal_index]);
      if (i_acquire) assume (o_valid[i_acquire_index] && !o_acquired[i_acquire_index]);
      assume (!(i_pop && i_acquire && i_acquire_index == o_head));
      assume (!(i_pop && i_seal && i_seal_index == o_head));
      f_outstanding_q <= f_outstanding_q + 8'(i_push) - (i_pop ? 8'(o_contributors[o_head]) : 8'd0);
      if (i_push) begin
        if (!merge) f_byte_valid_q[write_index] <= 1'b0;
        if (i_zero) begin
          f_byte_value_q[write_index] <= '0;
          f_byte_valid_q[write_index] <= 1'b1;
        end else if (i_addr[4:3] == f_byte[4:3] && i_mask[f_byte[2:0]]) begin
          f_byte_value_q[write_index] <= i_data[8*f_byte[2:0]+:8];
          f_byte_valid_q[write_index] <= 1'b1;
        end
      end
      if (o_twin_alloc) begin
        f_byte_value_q[next_q] <= '0;
        f_byte_valid_q[next_q] <= 1'b1;
      end
      assert (o_count <= 4);
      assert (next_q == 2'(o_head + 2'(o_count)));
      assert (f_total == f_outstanding_q && f_total <= 128);
      assert (!i_push || o_count < 4);
      // No write arrives while a twin waits, and the waiting twin belongs to
      // the youngest record, its block's lower zero record.
      assert (!(i_push && twin_pending_q));
      if (twin_pending_q) begin
        assert (o_count != 0 && o_zero[youngest] && !o_twin[youngest] && !o_ready);
        assert (twin_addr_q == {o_addr[youngest][ADDR_WIDTH-1:6], 6'b100000});
        assert (twin_tag_q == o_tag[youngest]);
      end
      for (int age = 0; age < 4; age++) begin
        assert (o_valid[2'(o_head+2'(age))] == (age < o_count));
        if (o_valid[age]) begin
          if (!o_twin[age]) assert (o_contributors[age] >= 1 && o_contributors[age] <= 32);
          if (o_contributors[age] == 32) assert (o_sealed[age]);
          assert (o_mask[age][f_byte] == f_byte_valid_q[age]);
          if (o_mask[age][f_byte]) assert (o_data[age][8*f_byte+:8] == f_byte_value_q[age]);
          // A zero record is sealed, fully masked and zero, and holds one
          // block sector: the lower one, or the upper one of a twin.
          if (o_zero[age]) begin
            assert (o_sealed[age] && o_mask[age] == '1 && o_data[age] == '0);
            assert (o_addr[age][5] == o_twin[age] && o_addr[age][4:0] == 0);
            assert (o_contributors[age] == (o_twin[age] ? 6'd0 : 6'd1));
          end
          if (o_twin[age]) assert (o_zero[age]);
        end
      end
      // A lower zero record is the youngest with its twin waiting, or its
      // twin follows it. A twin follows its lower record unless that record
      // has popped.
      assert (f_lower_ok == '1);
      assert (f_twin_ok == '1);
      if (f_past_valid && !$past(i_rst)) begin
        assert (o_done == $past((i_push && !i_zero) || o_twin_alloc));
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
      // A twin allocates beside a pop, waits for a full buffer to drain, and
      // reaches the head.
      cover (o_twin_alloc && i_pop);
      cover (twin_pending_q && o_count == 4);
      cover (o_valid[o_head] && o_twin[o_head]);
    end
  end
`endif
`ifdef COH_MAINT_OWNED
  logic f_maint_records;
  always_comb begin
    f_maint_records = 1;
    for (int age = 0; age < 4; age++) begin
      if (o_valid[2'(o_head+2'(age))] != (age < o_count)) f_maint_records = 0;
      if (o_valid[age] &&
          (o_contributors[age] == 0 ||
          o_contributors[age] > 32 ||
          (o_contributors[age] == 32 &&
          !o_sealed[age])))
        f_maint_records = 0;
    end
  end
  always_ff @(posedge i_clk)
    if (!i_rst) begin
      p_maint_owned_store_count : assert (o_count <= 4 && next_q == 2'(o_head + 2'(o_count)));
      p_maint_owned_store_records : assert (f_maint_records);
      if (i_push) p_maint_owned_store_credit : assert (!$past(i_rst) && $past(o_ready));
      if (i_pop) p_maint_owned_store_pop : assert (o_valid[o_head] && o_sealed[o_head]);
      if (i_seal) p_maint_owned_store_seal : assert (o_valid[i_seal_index]);
      p_maint_owned_store_no_acquire :
      assert (!i_acquire && !(i_pop && i_seal && i_seal_index == o_head));
    end
`endif
endmodule
