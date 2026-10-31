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

// Physical entries qualify before circular read selection.
module coherence_read_select #(
    parameter int unsigned ADDR_WIDTH = 32,
    // A standalone proof assumes i_addr is the forwarded address; the L1D
    // asserts it.
    parameter bit FORMAL_STANDALONE_ENV = 1'b1
) (
    input logic i_clk,
    input logic [7:0] i_valid,
    input logic [7:0] i_ready,
    input logic [7:0] i_miss,
    input logic [15:0] i_kind,
    input logic [8*ADDR_WIDTH-1:0] i_addr,
    input logic [8*ADDR_WIDTH-1:0] i_stored_addr,
    input logic [ADDR_WIDTH-1:0] i_write_addr,
    input logic [7:0] i_write_mask,
    input logic [2:0] i_round_robin,
    input logic i_pending,
    input logic [ADDR_WIDTH-1:0] i_pending_addr,
    input logic i_atomic,
    input logic [ADDR_WIDTH-1:0] i_atomic_addr,
    input logic [1:0] i_wb_live,
    input logic [2*ADDR_WIDTH-1:0] i_wb_addr,
    input logic i_atomic_protected,
    // Slots an acquisition owns, slots waiting for another slot's acquisition
    // of their line, and, per slot, whether a missed slot may look up again.
    input logic [7:0] i_owned,
    input logic [7:0] i_waiting,
    input logic [7:0] i_miss_retry,
    output logic o_found,
    output logic [2:0] o_index,
    output logic [ADDR_WIDTH-1:0] o_address
);
  logic [7:0] eligible, upper, first;
  (* keep = "true" *) logic [7:0] first_upper, first_any;
  // i_addr is each slot's address after the buffered write forwards to it.
  // The comparisons use the stored addresses and the buffered write's address
  // separately, so the forwarding selection follows them.
  logic write_blocked;
  always_comb begin
    write_blocked = (i_pending && i_write_addr[ADDR_WIDTH-1:5] == i_pending_addr[ADDR_WIDTH-1:5]) ||
        (i_atomic && i_write_addr[ADDR_WIDTH-1:5] == i_atomic_addr[ADDR_WIDTH-1:5]);
    for (int slot = 0; slot < 2; slot++)
      write_blocked |= i_wb_live[slot] && i_write_addr[ADDR_WIDTH-1:5] ==
          i_wb_addr[slot*ADDR_WIDTH+5+:ADDR_WIDTH-5];
  end
  for (genvar index = 0; index < 8; index++) begin : gen_entry
    wire [ADDR_WIDTH-1:0] address = i_stored_addr[index*ADDR_WIDTH+:ADDR_WIDTH];
    logic stored_blocked, blocked;
    always_comb begin
      stored_blocked = (i_pending &&
          address[ADDR_WIDTH-1:5] == i_pending_addr[ADDR_WIDTH-1:5]) ||
          (i_atomic && address[ADDR_WIDTH-1:5] == i_atomic_addr[ADDR_WIDTH-1:5]);
      for (int slot = 0; slot < 2; slot++)
        stored_blocked |= i_wb_live[slot] && address[ADDR_WIDTH-1:5] ==
            i_wb_addr[slot*ADDR_WIDTH+5+:ADDR_WIDTH-5];
    end
    assign blocked = i_write_mask[index] ? write_blocked : stored_blocked;
    assign eligible[index] = i_valid[index] && !i_ready[index] && !blocked &&
        (i_kind[2*index+:2] != 2'd2 || i_atomic_protected) &&
        !i_owned[index] && !i_waiting[index] && (!i_miss[index] || i_miss_retry[index]);
    if (index == 7) begin : gen_last
      assign upper[index] = eligible[index];
    end else begin : gen_before_last
      assign upper[index] = eligible[index] && 3'(index) >= i_round_robin;
    end
    if (index == 0) begin : gen_zero
      assign first_upper[index] = upper[index];
      assign first_any[index] = eligible[index];
    end else begin : gen_later
      assign first_upper[index] = upper[index] && !(|upper[index-1:0]);
      assign first_any[index] = eligible[index] && !(|eligible[index-1:0]);
    end
  end
  assign first = (|upper) ? first_upper : first_any;
  assign o_found = |eligible;
  always_comb begin
    o_index = '0;
    o_address = '0;
    for (int index = 0; index < 8; index++) begin
      o_index |= 3'(index) & {3{first[index]}};
      o_address |= i_addr[index*ADDR_WIDTH+:ADDR_WIDTH] & {ADDR_WIDTH{first[index]}};
    end
  end
`ifndef SYNTHESIS
  logic ref_found, ref_blocked;
  logic [2:0] ref_index, ref_scan;
  logic [ADDR_WIDTH-1:0] ref_address, ref_selected_address;
  always_comb begin
    ref_found = 1'b0;
    ref_index = '0;
    ref_scan = '0;
    ref_address = '0;
    ref_blocked = 1'b0;
    for (int index = 7; index >= 0; index--) begin
      ref_scan = 3'(i_round_robin + 3'(index));
      ref_address = i_addr[ref_scan*ADDR_WIDTH+:ADDR_WIDTH];
      ref_blocked = (i_pending && ref_address[ADDR_WIDTH-1:5] ==
          i_pending_addr[ADDR_WIDTH-1:5]) ||
          (i_atomic && ref_address[ADDR_WIDTH-1:5] == i_atomic_addr[ADDR_WIDTH-1:5]);
      for (int slot = 0; slot < 2; slot++)
        ref_blocked |= i_wb_live[slot] && i_wb_addr[slot*ADDR_WIDTH+5+:ADDR_WIDTH-5] ==
            ref_address[ADDR_WIDTH-1:5];
      if (i_valid[ref_scan] && !i_ready[ref_scan] && !ref_blocked &&
          (i_kind[ref_scan*2+:2] != 2'd2 || i_atomic_protected) &&
          !i_owned[ref_scan] && !i_waiting[ref_scan] &&
          (!i_miss[ref_scan] || i_miss_retry[ref_scan])) begin
        ref_found = 1'b1;
        ref_index = ref_scan;
      end
    end
    ref_selected_address = i_addr[ref_index*ADDR_WIDTH+:ADDR_WIDTH];
  end
`ifdef FORMAL
  always_comb
    if (FORMAL_STANDALONE_ENV)
      for (int index = 0; index < 8; index++)
      assume (i_addr[index*ADDR_WIDTH+:ADDR_WIDTH] == (i_write_mask[index] ? i_write_addr :
          i_stored_addr[index*ADDR_WIDTH+:ADDR_WIDTH]));
  always_comb
`else
  always @(posedge i_clk)
`endif
  begin
    p_read_select_exact : assert (o_found == ref_found && o_index == ref_index);
    if (o_found) p_read_address_exact : assert (o_address == ref_selected_address);
    // The forwarded addresses the reference uses match the compared ones.
    if (!FORMAL_STANDALONE_ENV)
      for (int index = 0; index < 8; index++)
      assert (i_addr[index*ADDR_WIDTH+:ADDR_WIDTH] == (i_write_mask[index] ? i_write_addr :
          i_stored_addr[index*ADDR_WIDTH+:ADDR_WIDTH]));
  end
`endif
endmodule
