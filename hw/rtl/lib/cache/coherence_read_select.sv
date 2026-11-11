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
    input logic [3:0] i_block_valid,
    input logic [4*ADDR_WIDTH-1:0] i_block_addr,
    input logic [1:0] i_wb_live,
    input logic [2*ADDR_WIDTH-1:0] i_wb_addr,
    input logic i_atomic_protected,
    // Slots an acquisition owns, slots waiting for another slot's acquisition
    // of their line, and, per slot, whether a missed slot may look up again.
    input logic [7:0] i_owned,
    input logic [7:0] i_waiting,
    input logic [7:0] i_miss_retry,
    output logic o_found,
    output logic o_load_miss,
    output logic [2:0] o_index,
    output logic [ADDR_WIDTH-1:0] o_address
);
  // Blocking compares 18 sector index bits. An alias with a held sector waits
  // for the holder like a match, and the holders do not wait for reads.
  localparam int unsigned BlockBits = 18;
  logic [7:0] eligible, first;
`ifndef FROST_XILINX_PRIMS
  logic [7:0] upper;
  (* keep = "true" *) logic [7:0] first_upper, first_any;
`endif
  (* keep = "true" *) logic [7:0] stored_candidates, write_candidates;
  (* keep = "true" *) logic [7:0] stored_miss_candidates, write_miss_candidates;
  (* keep = "true" *) logic [7:0] stored_blocked_mask;
  (* keep = "true" *) logic [3:0] stored_found, stored_miss_found;
  (* keep = "true" *) logic [2:0] write_found_groups, write_miss_groups;
  (* keep = "true" *) logic write_found, write_miss_found;
  // i_addr is each slot's address after the buffered write forwards to it.
  // The comparisons use the stored addresses and the buffered write's address
  // separately, so the forwarding selection follows them.
  (* keep = "true" *) logic write_blocked;
`ifdef FROST_XILINX_PRIMS
  // Keep the sector comparison and holder reduction balanced. Each equality
  // has six independent three-bit comparisons followed by one conjunction.
  for (genvar address_index = 0; address_index < 9; address_index++) begin : gen_block_compare
    wire [BlockBits-1:0] address;
    wire [5:0] holder_valid = {i_wb_live, i_block_valid};
    wire [5:0] equal;
    wire [2:0] blocked_pair;
    wire blocked;
    if (address_index == 8) begin : gen_forwarded_address
      assign address = i_write_addr[5+:BlockBits];
    end else begin : gen_stored_address
      assign address = i_stored_addr[address_index*ADDR_WIDTH+5+:BlockBits];
    end
    for (genvar holder = 0; holder < 6; holder++) begin : gen_holder
      wire [BlockBits-1:0] held_address;
      wire [5:0] equal_chunk;
      if (holder < 4) begin : gen_block
        assign held_address = i_block_addr[holder*ADDR_WIDTH+5+:BlockBits];
      end else begin : gen_writeback
        assign held_address = i_wb_addr[(holder-4)*ADDR_WIDTH+5+:BlockBits];
      end
      for (genvar chunk = 0; chunk < 6; chunk++) begin : gen_chunk
        (* dont_touch = "true" *) LUT6 #(.INIT(64'h8040201008040201)) u_equal (
            .I0(address[3*chunk]), .I1(address[3*chunk+1]), .I2(address[3*chunk+2]),
            .I3(held_address[3*chunk]), .I4(held_address[3*chunk+1]),
            .I5(held_address[3*chunk+2]), .O(equal_chunk[chunk])
        );
      end
      (* dont_touch = "true" *) LUT6 #(.INIT(64'h8000000000000000)) u_all_equal (
          .I0(equal_chunk[0]), .I1(equal_chunk[1]), .I2(equal_chunk[2]),
          .I3(equal_chunk[3]), .I4(equal_chunk[4]), .I5(equal_chunk[5]), .O(equal[holder])
      );
    end
    for (genvar pair_index = 0; pair_index < 3; pair_index++) begin : gen_pair
      (* dont_touch = "true" *) LUT4 #(.INIT(16'hf888)) u_blocked (
          .I0(equal[2*pair_index]), .I1(holder_valid[2*pair_index]),
          .I2(equal[2*pair_index+1]), .I3(holder_valid[2*pair_index+1]),
          .O(blocked_pair[pair_index])
      );
    end
    (* dont_touch = "true" *) LUT3 #(.INIT(8'hfe)) u_any_blocked (
        .I0(blocked_pair[0]), .I1(blocked_pair[1]), .I2(blocked_pair[2]), .O(blocked)
    );
    if (address_index == 8) begin : gen_write
      assign write_blocked = blocked;
    end else begin : gen_stored
      assign stored_blocked_mask[address_index] = blocked;
    end
  end
`else
  always_comb begin
    write_blocked = 1'b0;
    for (int holder = 0; holder < 4; holder++)
      write_blocked |= i_block_valid[holder] && i_write_addr[5+:BlockBits] ==
          i_block_addr[holder*ADDR_WIDTH+5+:BlockBits];
    for (int slot = 0; slot < 2; slot++)
      write_blocked |= i_wb_live[slot] && i_write_addr[5+:BlockBits] ==
          i_wb_addr[slot*ADDR_WIDTH+5+:BlockBits];
  end
`endif
  for (genvar index = 0; index < 8; index++) begin : gen_entry
    wire [ADDR_WIDTH-1:0] address = i_stored_addr[index*ADDR_WIDTH+:ADDR_WIDTH];
    logic stored_blocked, blocked;
`ifdef FROST_XILINX_PRIMS
    assign stored_blocked = stored_blocked_mask[index];
`else
    always_comb begin
      stored_blocked = 1'b0;
      for (int holder = 0; holder < 4; holder++)
        stored_blocked |= i_block_valid[holder] && address[5+:BlockBits] ==
            i_block_addr[holder*ADDR_WIDTH+5+:BlockBits];
      for (int slot = 0; slot < 2; slot++)
        stored_blocked |= i_wb_live[slot] && address[5+:BlockBits] ==
            i_wb_addr[slot*ADDR_WIDTH+5+:BlockBits];
    end
    assign stored_blocked_mask[index] = stored_blocked;
`endif
    assign blocked = i_write_mask[index] ? write_blocked : stored_blocked;
    wire qualified = i_valid[index] && !i_ready[index] &&
        (i_kind[2*index+:2] != 2'd2 || i_atomic_protected) &&
        !i_owned[index] && !i_waiting[index] && (!i_miss[index] || i_miss_retry[index]);
    assign eligible[index] = qualified && !blocked;
    wire available = i_valid[index] && !i_ready[index] &&
        (i_kind[2*index+:2] != 2'd2 || i_atomic_protected);
    wire before_owner = available && !i_waiting[index] &&
        (!i_miss[index] || i_miss_retry[index]);
    assign stored_candidates[index] = before_owner && !i_write_mask[index];
    assign write_candidates[index] = before_owner && i_write_mask[index];
`ifdef FROST_XILINX_PRIMS
    // A load miss has kind zero, so it never needs AMO protection. Keep that
    // shared permission out of the miss decision entirely.
    wire load_miss_candidate = i_valid[index] && !i_ready[index] && !i_waiting[index] &&
        (!i_miss[index] || i_miss_retry[index]) && i_miss[index] &&
        i_kind[2*index+:2] == 2'd0;
    assign stored_miss_candidates[index] = load_miss_candidate && !i_write_mask[index];
    assign write_miss_candidates[index] = load_miss_candidate && i_write_mask[index];
`else
    assign stored_miss_candidates[index] = stored_candidates[index] &&
        i_miss[index] && i_kind[2*index+:2] == 2'd0;
    assign write_miss_candidates[index] = write_candidates[index] &&
        i_miss[index] && i_kind[2*index+:2] == 2'd0;
`endif
`ifndef FROST_XILINX_PRIMS
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
`endif
  end
`ifdef FROST_XILINX_PRIMS
  // Prepare stored and forwarded contenders separately. Only the stored
  // contenders depend on their individual sector comparisons; the forwarded
  // contenders share the buffered address exclusion at the final winner LUT.
  (* keep = "true" *) logic [7:0] prior_mask[8];
  (* keep = "true" *) logic [7:0] stored_qualified, write_qualified;
  for (genvar index = 0; index < 8; index++) begin : gen_qualified
    (* keep = "true" *) wire status_ready = i_valid[index] && !i_ready[index] &&
        !i_owned[index] && !i_waiting[index] && (!i_miss[index] || i_miss_retry[index]);
    (* keep = "true" *) wire kind_ready = i_kind[2*index+:2] != 2'd2 || i_atomic_protected;
    assign stored_qualified[index] = status_ready && kind_ready && !i_write_mask[index];
    assign write_qualified[index] = status_ready && kind_ready && i_write_mask[index];
  end
  for (genvar winner = 0; winner < 8; winner++) begin : gen_prior_mask
    for (genvar contender = 0; contender < 8; contender++) begin : gen_contender
      if (contender < winner) begin : gen_lower
        assign prior_mask[winner][contender] =
            i_round_robin <= 3'(contender) || i_round_robin > 3'(winner);
      end else if (contender > winner) begin : gen_higher
        assign prior_mask[winner][contender] =
            i_round_robin > 3'(winner) && i_round_robin <= 3'(contender);
      end else begin : gen_self
        assign prior_mask[winner][contender] = 1'b0;
      end
    end
  end
  for (genvar winner = 0; winner < 8; winner++) begin : gen_winner
    (* keep = "true" *) wire [7:0] stored_prior = stored_qualified & prior_mask[winner];
    wire [2:0] stored_earlier_groups, write_earlier_groups;
    wire stored_earlier, write_earlier;
    for (genvar group_index = 0; group_index < 3; group_index++) begin : gen_group
      wire [2:0] stored_term, write_term, precedes, unblocked;
      for (genvar offset = 0; offset < 3; offset++) begin : gen_term
        if (3*group_index+offset < 8) begin : gen_present
          assign stored_term[offset] = stored_prior[3*group_index+offset];
          assign write_term[offset] = write_qualified[3*group_index+offset];
          assign precedes[offset] = prior_mask[winner][3*group_index+offset];
          assign unblocked[offset] = !stored_blocked_mask[3*group_index+offset];
        end else begin : gen_padding
          assign stored_term[offset] = 1'b0;
          assign write_term[offset] = 1'b0;
          assign precedes[offset] = 1'b0;
          assign unblocked[offset] = 1'b0;
        end
      end
      (* dont_touch = "true" *) LUT6 #(.INIT(64'hfffff888f888f888)) u_stored_earlier (
          .I0(stored_term[0]), .I1(unblocked[0]), .I2(stored_term[1]),
          .I3(unblocked[1]), .I4(stored_term[2]), .I5(unblocked[2]),
          .O(stored_earlier_groups[group_index])
      );
      (* dont_touch = "true" *) LUT6 #(.INIT(64'hfffff888f888f888)) u_write_earlier (
          .I0(write_term[0]), .I1(precedes[0]), .I2(write_term[1]),
          .I3(precedes[1]), .I4(write_term[2]), .I5(precedes[2]),
          .O(write_earlier_groups[group_index])
      );
    end
    (* dont_touch = "true" *) LUT3 #(.INIT(8'hfe)) u_stored_any (
        .I0(stored_earlier_groups[0]), .I1(stored_earlier_groups[1]),
        .I2(stored_earlier_groups[2]), .O(stored_earlier)
    );
    (* dont_touch = "true" *) LUT3 #(.INIT(8'hfe)) u_write_any (
        .I0(write_earlier_groups[0]), .I1(write_earlier_groups[1]),
        .I2(write_earlier_groups[2]), .O(write_earlier)
    );
    (* dont_touch = "true" *) LUT6 #(.INIT(64'h0101450100004500)) u_first (
        .I0(stored_earlier), .I1(write_blocked), .I2(write_earlier),
        .I3(stored_qualified[winner]), .I4(stored_blocked_mask[winner]),
        .I5(write_qualified[winner]), .O(first[winner])
    );
  end
`else
  assign first = (|upper) ? first_upper : first_any;
`endif
  // Apply ownership and stored-address exclusion together. Two slots have
  // six inputs, so each group fits one LUT. The final reduction has four
  // stored groups and the two shared buffered-write terms.
  for (genvar group = 0; group < 4; group++) begin : gen_stored_group
    assign stored_found[group] = |(stored_candidates[2*group+:2] &
        ~i_owned[2*group+:2] & ~stored_blocked_mask[2*group+:2]);
    assign stored_miss_found[group] = |(stored_miss_candidates[2*group+:2] &
        ~i_owned[2*group+:2] & ~stored_blocked_mask[2*group+:2]);
  end
  // Every forwarded slot shares the buffered address. Its exclusion applies
  // once, after ownership qualifies the per-slot candidates.
  assign write_found_groups[0] = |(write_candidates[2:0] & ~i_owned[2:0]);
  assign write_found_groups[1] = |(write_candidates[5:3] & ~i_owned[5:3]);
  assign write_found_groups[2] = |(write_candidates[7:6] & ~i_owned[7:6]);
  assign write_miss_groups[0] = |(write_miss_candidates[2:0] & ~i_owned[2:0]);
  assign write_miss_groups[1] = |(write_miss_candidates[5:3] & ~i_owned[5:3]);
  assign write_miss_groups[2] = |(write_miss_candidates[7:6] & ~i_owned[7:6]);
  assign write_found = |write_found_groups;
  assign write_miss_found = |write_miss_groups;
  assign o_found = |stored_found || (write_found && !write_blocked);
  assign o_load_miss = |stored_miss_found || (write_miss_found && !write_blocked);
`ifdef FROST_XILINX_PRIMS
  // A selected address is an eight-way one-hot OR. Pin its two-level
  // reduction so a wide address does not become a serial mux chain.
  assign o_index = ({3{first[1]}} & 3'd1) | ({3{first[2]}} & 3'd2) |
      ({3{first[3]}} & 3'd3) | ({3{first[4]}} & 3'd4) |
      ({3{first[5]}} & 3'd5) | ({3{first[6]}} & 3'd6) | ({3{first[7]}} & 3'd7);
  for (genvar bit_index = 0; bit_index < ADDR_WIDTH; bit_index++) begin : gen_address
    wire [2:0] selected_groups;
    for (genvar group_index = 0; group_index < 3; group_index++) begin : gen_group
      wire [2:0] selected, value;
      for (genvar offset = 0; offset < 3; offset++) begin : gen_term
        if (3*group_index+offset < 8) begin : gen_present
          assign selected[offset] = first[3*group_index+offset];
          assign value[offset] = i_addr[(3*group_index+offset)*ADDR_WIDTH+bit_index];
        end else begin : gen_padding
          assign selected[offset] = 1'b0;
          assign value[offset] = 1'b0;
        end
      end
      (* dont_touch = "true" *) LUT6 #(.INIT(64'hfffff888f888f888)) u_selected (
          .I0(selected[0]), .I1(value[0]), .I2(selected[1]), .I3(value[1]),
          .I4(selected[2]), .I5(value[2]), .O(selected_groups[group_index])
      );
    end
    (* dont_touch = "true" *) LUT3 #(.INIT(8'hfe)) u_any (
        .I0(selected_groups[0]), .I1(selected_groups[1]), .I2(selected_groups[2]),
        .O(o_address[bit_index])
    );
  end
`else
  always_comb begin
    o_index = '0;
    o_address = '0;
    for (int index = 0; index < 8; index++) begin
      o_index |= 3'(index) & {3{first[index]}};
      o_address |= i_addr[index*ADDR_WIDTH+:ADDR_WIDTH] & {ADDR_WIDTH{first[index]}};
    end
  end
`endif
`ifndef SYNTHESIS
  logic ref_found, ref_blocked, ref_load_miss;
  logic [2:0] ref_index, ref_scan;
  logic [ADDR_WIDTH-1:0] ref_address, ref_selected_address;
  always_comb begin
    ref_found = 1'b0;
    ref_load_miss = 1'b0;
    ref_index = '0;
    ref_scan = '0;
    ref_address = '0;
    ref_blocked = 1'b0;
    for (int index = 7; index >= 0; index--) begin
      ref_scan = 3'(i_round_robin + 3'(index));
      ref_address = i_addr[ref_scan*ADDR_WIDTH+:ADDR_WIDTH];
      ref_blocked = 1'b0;
      for (int holder = 0; holder < 4; holder++)
        ref_blocked |= i_block_valid[holder] && ref_address[5+:BlockBits] ==
            i_block_addr[holder*ADDR_WIDTH+5+:BlockBits];
      for (int slot = 0; slot < 2; slot++)
        ref_blocked |= i_wb_live[slot] && i_wb_addr[slot*ADDR_WIDTH+5+:BlockBits] ==
            ref_address[5+:BlockBits];
      if (i_valid[ref_scan] && !i_ready[ref_scan] && !ref_blocked &&
          (i_kind[ref_scan*2+:2] != 2'd2 || i_atomic_protected) &&
          !i_owned[ref_scan] && !i_waiting[ref_scan] &&
          (!i_miss[ref_scan] || i_miss_retry[ref_scan])) begin
        ref_found = 1'b1;
        ref_index = ref_scan;
        if (i_miss[ref_scan] && i_kind[ref_scan*2+:2] == 2'd0) ref_load_miss = 1'b1;
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
    p_read_available_exact : assert (o_found == |eligible);
    p_read_select_exact : assert (o_found == ref_found && o_index == ref_index);
    p_load_miss_exact : assert (o_load_miss == ref_load_miss);
    if (o_found) p_read_address_exact : assert (o_address == ref_selected_address);
    // The forwarded addresses the reference uses match the compared ones.
    if (!FORMAL_STANDALONE_ENV)
      for (int index = 0; index < 8; index++)
      assert (i_addr[index*ADDR_WIDTH+:ADDR_WIDTH] == (i_write_mask[index] ? i_write_addr :
          i_stored_addr[index*ADDR_WIDTH+:ADDR_WIDTH]));
  end
`endif
endmodule
