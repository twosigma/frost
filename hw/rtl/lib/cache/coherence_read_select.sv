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
// Preserve the bounded arbitration cone when composing its native interface.
// verilog_format: off
`ifdef FROST_XILINX_PRIMS
(* keep_hierarchy = "yes" *)
`endif
// verilog_format: on
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
  logic [7:0] reference_eligible, missed_load;
  (* keep = "true" *) wire [7:0] slot_ready;
  localparam logic [63:0] Dot3Init = 64'hfefcfaf0eeccaa00;
  function automatic logic [7:0] predecessor_init(
      input int unsigned current, input int unsigned rival
  );
    for (int unsigned pointer = 0; pointer < 8; pointer++)
      predecessor_init[pointer] = ((rival + 8 - pointer) % 8) <
          ((current + 8 - pointer) % 8);
  endfunction

  (* keep = "true" *) logic [7:0] stored_candidate, write_candidate;
  (* keep = "true" *) logic write_found;
  (* keep = "true" *) logic [2:0] stored_found, stored_load_miss;
  (* keep = "true" *) logic write_load_miss;
  // Six holders: four acquisitions and the two live writeback slots.
  wire [5:0] holder_valid = {i_wb_live, i_block_valid};
  wire [6*ADDR_WIDTH-1:0] holder_address = {i_wb_addr, i_block_addr};
  (* keep = "true" *) wire [1:0] blocked_parts[9];
  logic write_blocked;
  // Compare stored and buffered addresses separately. Each equality has six
  // three-bit chunks, followed by two halves. The valid half and the other
  // half meet only in a bounded reduction of three holders.
  for (genvar entry_index = 0; entry_index < 9; entry_index++) begin : gen_blocking
    wire [ADDR_WIDTH-1:0] address;
    if (entry_index == 8) assign address = i_write_addr;
    else assign address = i_stored_addr[entry_index*ADDR_WIDTH+:ADDR_WIDTH];
    (* keep = "true" *) wire [5:0] match_low, match_high;
    for (genvar holder = 0; holder < 6; holder++) begin : gen_holder
      (* keep = "true" *) wire [5:0] equal_chunk;
      for (genvar chunk = 0; chunk < 6; chunk++) begin : gen_chunk
`ifdef FROST_XILINX_PRIMS
        (* dont_touch = "true" *) LUT6 #(.INIT(64'h9009000000009009)) u_equal (
            .I0(address[5+3*chunk]), .I1(holder_address[holder*ADDR_WIDTH+5+3*chunk]),
            .I2(address[6+3*chunk]), .I3(holder_address[holder*ADDR_WIDTH+6+3*chunk]),
            .I4(address[7+3*chunk]), .I5(holder_address[holder*ADDR_WIDTH+7+3*chunk]),
            .O(equal_chunk[chunk])
        );
`else
        assign equal_chunk[chunk] = address[5+3*chunk+:3] ==
            holder_address[holder*ADDR_WIDTH+5+3*chunk+:3];
`endif
      end
`ifdef FROST_XILINX_PRIMS
      (* dont_touch = "true" *) LUT4 #(.INIT(16'h8000)) u_low (
          .I0(equal_chunk[0]), .I1(equal_chunk[1]), .I2(equal_chunk[2]),
          .I3(holder_valid[holder]), .O(match_low[holder])
      );
      (* dont_touch = "true" *) LUT3 #(.INIT(8'h80)) u_high (
          .I0(equal_chunk[3]), .I1(equal_chunk[4]), .I2(equal_chunk[5]),
          .O(match_high[holder])
      );
`else
      assign match_low[holder] = holder_valid[holder] && (&equal_chunk[2:0]);
      assign match_high[holder] = &equal_chunk[5:3];
`endif
    end
    for (genvar group_index = 0; group_index < 2; group_index++) begin : gen_group
`ifdef FROST_XILINX_PRIMS
      (* dont_touch = "true" *) LUT6 #(.INIT(64'hfffff888f888f888)) u_blocked (
          .I0(match_low[3*group_index]), .I1(match_high[3*group_index]),
          .I2(match_low[3*group_index+1]), .I3(match_high[3*group_index+1]),
          .I4(match_low[3*group_index+2]), .I5(match_high[3*group_index+2]),
          .O(blocked_parts[entry_index][group_index])
      );
`else
      assign blocked_parts[entry_index][group_index] =
          |(match_low[3*group_index+:3] & match_high[3*group_index+:3]);
`endif
    end
  end
  assign write_blocked = |blocked_parts[8];
  for (genvar index = 0; index < 8; index++) begin : gen_entry
    wire [ADDR_WIDTH-1:0] address = i_stored_addr[index*ADDR_WIDTH+:ADDR_WIDTH];
    wire stored_blocked = |blocked_parts[index];
    wire reference_blocked = i_write_mask[index] ? write_blocked : stored_blocked;
    wire qualified = i_valid[index] && !i_ready[index] &&
        (i_kind[2*index+:2] != 2'd2 || i_atomic_protected) &&
        !i_owned[index] && !i_waiting[index] && (!i_miss[index] || i_miss_retry[index]);
    assign reference_eligible[index] = qualified && !reference_blocked;
    assign slot_ready[index] = i_valid[index] && !i_ready[index] &&
        (i_kind[2*index+:2] != 2'd2 || i_atomic_protected) &&
        (!i_miss[index] || i_miss_retry[index]);
`ifdef FROST_XILINX_PRIMS
    (* dont_touch = "true" *) LUT6 #(.INIT(64'h0000000000000002)) u_stored_candidate (
        .I0(slot_ready[index]), .I1(i_write_mask[index]), .I2(i_waiting[index]),
        .I3(blocked_parts[index][0]), .I4(blocked_parts[index][1]), .I5(i_owned[index]),
        .O(stored_candidate[index])
    );
    (* dont_touch = "true" *) LUT4 #(.INIT(16'h0008)) u_write_candidate (
        .I0(slot_ready[index]), .I1(i_write_mask[index]),
        .I2(i_waiting[index]), .I3(i_owned[index]), .O(write_candidate[index])
    );
`else
    assign stored_candidate[index] = slot_ready[index] && !i_owned[index] &&
        !i_waiting[index] && !i_write_mask[index] && !(|blocked_parts[index]);
    assign write_candidate[index] = slot_ready[index] && !i_owned[index] &&
        !i_waiting[index] && i_write_mask[index];
`endif
    assign missed_load[index] = i_miss[index] && i_kind[2*index+:2] == 2'd0;
  end
  // Status and retry qualification precede the address decision. Each stored
  // presence group is an OR of three candidates; each miss group is an OR of
  // three candidate/missed-load pairs.
  for (genvar group_index = 0; group_index < 3; group_index++) begin : gen_presence
    wire [2:0] candidate, missed;
    for (genvar offset = 0; offset < 3; offset++) begin : gen_slot
      if (3*group_index+offset < 8) begin : gen_live
        assign candidate[offset] = stored_candidate[3*group_index+offset];
        assign missed[offset] = missed_load[3*group_index+offset];
      end else begin : gen_unused
        assign candidate[offset] = 1'b0;
        assign missed[offset] = 1'b0;
      end
    end
    assign stored_found[group_index] = |candidate;
`ifdef FROST_XILINX_PRIMS
    (* dont_touch = "true" *) LUT6 #(.INIT(Dot3Init)) u_miss (
        .I0(missed[0]), .I1(missed[1]), .I2(missed[2]),
        .I3(candidate[0]), .I4(candidate[1]), .I5(candidate[2]),
        .O(stored_load_miss[group_index])
    );
`else
    assign stored_load_miss[group_index] = |(candidate & missed);
`endif
  end
  assign write_found = |write_candidate;
  assign write_load_miss = |(write_candidate & missed_load);
`ifdef FROST_XILINX_PRIMS
  (* dont_touch = "true" *) LUT5 #(.INIT(32'hfefefffe)) u_found (
      .I0(stored_found[0]), .I1(stored_found[1]), .I2(stored_found[2]),
      .I3(write_found), .I4(write_blocked), .O(o_found)
  );
  (* dont_touch = "true" *) LUT5 #(.INIT(32'hfefefffe)) u_load_miss (
      .I0(stored_load_miss[0]), .I1(stored_load_miss[1]), .I2(stored_load_miss[2]),
      .I3(write_load_miss), .I4(write_blocked), .O(o_load_miss)
  );
`else
  assign o_found = |stored_found || (write_found && !write_blocked);
  assign o_load_miss = |stored_load_miss || (write_load_miss && !write_blocked);
`endif
  // Prepare circular selection for both buffered-address blocking outcomes.
  // The late shared comparison selects the index and data after priority.
  (* keep = "true" *) logic [2:0] index_choice[2];
  (* keep = "true" *) logic [ADDR_WIDTH-1:0] address_choice[2];
  for (genvar choice = 0; choice < 2; choice++) begin : gen_priority_choice
    localparam bit WriteBlocked = choice != 0;
    localparam logic [63:0] CandidateInit =
        WriteBlocked ? 64'h0000000000000002 : 64'h000000000808080a;
    (* keep = "true" *) wire [7:0] choice_eligible, first;
    for (genvar index = 0; index < 8; index++) begin : gen_eligible
`ifdef FROST_XILINX_PRIMS
      (* dont_touch = "true" *) LUT6 #(.INIT(CandidateInit)) u_candidate (
          .I0(slot_ready[index]), .I1(i_write_mask[index]), .I2(i_waiting[index]),
          .I3(blocked_parts[index][0]), .I4(blocked_parts[index][1]),
          .I5(i_owned[index]), .O(choice_eligible[index])
      );
`else
      assign choice_eligible[index] = slot_ready[index] && !i_owned[index] &&
          !i_waiting[index] && (i_write_mask[index] ? !WriteBlocked :
          !(|blocked_parts[index]));
`endif
    end
    for (genvar index = 0; index < 8; index++) begin : gen_ranked_winner
      (* keep = "true" *) wire [2:0] blockers;
      for (genvar group_index = 0; group_index < 3; group_index++) begin : gen_group
        wire [2:0] before_current, eligible_rival;
        for (genvar offset = 0; offset < 3; offset++) begin : gen_rival
          localparam int unsigned Position = 3 * group_index + offset;
          if (Position < 7) begin : gen_live
            localparam int unsigned Rival = Position >= index ? Position + 1 : Position;
            localparam logic [7:0] PredecessorInit = predecessor_init(index, Rival);
`ifdef FROST_XILINX_PRIMS
            (* dont_touch = "true" *) LUT3 #(.INIT(PredecessorInit)) u_rank (
                .I0(i_round_robin[0]), .I1(i_round_robin[1]), .I2(i_round_robin[2]),
                .O(before_current[offset])
            );
`else
            wire [2:0] current_distance = 3'(index) - i_round_robin;
            wire [2:0] rival_distance = 3'(Rival) - i_round_robin;
            assign before_current[offset] = rival_distance < current_distance;
`endif
            assign eligible_rival[offset] = choice_eligible[Rival];
          end else begin : gen_unused
            assign before_current[offset] = 1'b0;
            assign eligible_rival[offset] = 1'b0;
          end
        end
`ifdef FROST_XILINX_PRIMS
        (* dont_touch = "true" *) LUT6 #(.INIT(Dot3Init)) u_blockers (
            .I0(before_current[0]), .I1(before_current[1]), .I2(before_current[2]),
            .I3(eligible_rival[0]), .I4(eligible_rival[1]), .I5(eligible_rival[2]),
            .O(blockers[group_index])
        );
`else
        assign blockers[group_index] = |(before_current & eligible_rival);
`endif
      end
`ifdef FROST_XILINX_PRIMS
      (* dont_touch = "true" *) LUT4 #(.INIT(16'h0002)) u_ranked_winner (
          .I0(choice_eligible[index]), .I1(blockers[0]), .I2(blockers[1]),
          .I3(blockers[2]), .O(first[index])
      );
`else
      assign first[index] = choice_eligible[index] && !(|blockers);
`endif
    end
    for (genvar bit_index = 0; bit_index < 3; bit_index++) begin : gen_index
      wire [3:0] selected;
      for (genvar offset = 0; offset < 4; offset++) begin : gen_slot
        if (bit_index == 0) assign selected[offset] = first[2*offset+1];
        else if (bit_index == 1)
          assign selected[offset] = first[4*(offset/2)+2+(offset%2)];
        else assign selected[offset] = first[offset+4];
      end
`ifdef FROST_XILINX_PRIMS
      (* dont_touch = "true" *) LUT4 #(.INIT(16'hfffe)) u_index (
          .I0(selected[0]), .I1(selected[1]), .I2(selected[2]), .I3(selected[3]),
          .O(index_choice[choice][bit_index])
      );
`else
      assign index_choice[choice][bit_index] = |selected;
`endif
    end
    for (genvar bit_index = 0; bit_index < ADDR_WIDTH; bit_index++) begin : gen_address
      (* keep = "true" *) wire [2:0] address_group;
      for (genvar group_index = 0; group_index < 3; group_index++) begin : gen_group
        wire [2:0] data_bits, selected;
        for (genvar offset = 0; offset < 3; offset++) begin : gen_slot
          if (3*group_index+offset < 8) begin : gen_live
            assign data_bits[offset] = i_addr[(3*group_index+offset)*ADDR_WIDTH+bit_index];
            assign selected[offset] = first[3*group_index+offset];
          end else begin : gen_unused
            assign data_bits[offset] = 1'b0;
            assign selected[offset] = 1'b0;
          end
        end
`ifdef FROST_XILINX_PRIMS
        (* dont_touch = "true" *) LUT6 #(.INIT(Dot3Init)) u_address (
            .I0(data_bits[0]), .I1(data_bits[1]), .I2(data_bits[2]),
            .I3(selected[0]), .I4(selected[1]), .I5(selected[2]),
            .O(address_group[group_index])
        );
`else
        assign address_group[group_index] = |(data_bits & selected);
`endif
      end
`ifdef FROST_XILINX_PRIMS
      (* dont_touch = "true" *) LUT3 #(.INIT(8'hfe)) u_address_any (
          .I0(address_group[0]), .I1(address_group[1]), .I2(address_group[2]),
          .O(address_choice[choice][bit_index])
      );
`else
      assign address_choice[choice][bit_index] = |address_group;
`endif
    end
  end
  for (genvar bit_index = 0; bit_index < ADDR_WIDTH + 3; bit_index++) begin : gen_priority_select
    wire first_bit, second_bit, selected_bit;
    if (bit_index < 3) begin : gen_index
      assign first_bit = index_choice[0][bit_index];
      assign second_bit = index_choice[1][bit_index];
      assign o_index[bit_index] = selected_bit;
    end else begin : gen_address
      assign first_bit = address_choice[0][bit_index-3];
      assign second_bit = address_choice[1][bit_index-3];
      assign o_address[bit_index-3] = selected_bit;
    end
`ifdef FROST_XILINX_PRIMS
    (* dont_touch = "true" *) LUT3 #(.INIT(8'hca)) u_select (
        .I0(first_bit), .I1(second_bit), .I2(write_blocked), .O(selected_bit)
    );
`else
    assign selected_bit = write_blocked ? second_bit : first_bit;
`endif
  end
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
    p_read_available_exact : assert (o_found == |reference_eligible);
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
