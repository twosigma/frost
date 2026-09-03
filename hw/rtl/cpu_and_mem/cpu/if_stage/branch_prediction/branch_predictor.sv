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
 * Direct-mapped BTB with two-bit saturating counters. Default geometry:
 *   - 256 entries indexed by PC[9:2] (8 bits). Sized up from 128 because
 *     CoreMark's branch working set overflows 128 entries. The extra capacity
 *     raises BTB hit rate and cuts front-end redirect bubbles, the dominant
 *     measured branch cost, without changing the prediction policy.
 *   - Each entry: valid (1) + tag (55 bits in RV64) + target-low (32) +
 *     counter (2) + compressed (1) + requires_pc_reg_handoff (1). A valid
 *     entry's target is in the branch PC's 4-GiB region, so lookup restores
 *     the target's upper bits from the matching PC rather than zero-extending.
 *   - Tag includes PC[1] to distinguish halfword-aligned addresses (C extension)
 *   - Counter encoding:
 *       00 = Strongly Not-Taken, 01 = Weakly Not-Taken
 *       10 = Weakly Taken,       11 = Strongly Taken
 * Slot-1 lookup is combinational. Slot-2 launches one synchronous payload
 * block-RAM read per shifted image from the current fetch request, then
 * qualifies the registered rows for the served instruction one cycle later.
 * Tags use the same response boundary and are staged from single-address
 * distributed-RAM copies, keeping their wide comparisons off the block-RAM
 * clock-to-output path. A rotated copy of the +2 image covers the adjacent-word
 * case without an A+1 read-address network. EX updates tag, target, and the
 * saturated counter synchronously. A hit predicts taken when counter[1] is set.
 *
 * Parallel update timing:
 *   - Early-recovery and lower-priority counter RMW candidates are calculated
 *     in parallel from independent canonical update-read RAM replicas. Neither
 *     read address depends on early_active. Both replicas receive every
 *     selected write; early_active selects only the final counter value.
 *   - A lookup of the updated PC sees the old entry before the write edge and
 *     the new entry after it, including on back-to-back same-index updates.
 */
module branch_predictor #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned BTB_INDEX_BITS = 8  // 256 entries
) (
    input logic i_clk,
    input logic i_rst,

    // Slot-1 prediction interface (IF stage)
    input  logic [XLEN-1:0] i_pc,                          // Current PC for lookup
    output logic            o_btb_hit,                     // BTB entry hit
    output logic            o_predicted_taken,             // Predict taken
    output logic [XLEN-1:0] o_predicted_target,            // Predicted target address
    output logic            o_btb_compressed,              // Entry is for compressed instruction
    // Predicted op must still execute in IF/PD/ID
    output logic            o_btb_requires_pc_reg_handoff,

    // Slot-2 prediction interface. Separate shifted replicas hold the
    // current-base+2 and current-base+4 entries under predecessor keys. The
    // live fetch PC launches the synchronous row reads one cycle ahead; the
    // served pc_reg base then selects and re-tags the registered response.
    // A rotated +2 replica covers an adjacent word without a second read port.
    input  logic [XLEN-1:0] i_pc_2_lookup_base,
    input  logic [XLEN-1:0] i_pc_2_base,
    input  logic            i_pc_2_use_alt,
    // Fixed-candidate direction/size results.  The controller qualifies and
    // valid-gates these in parallel, then ORs the one-hot one-bit results.
    output logic            o_predicted_taken_2_plus2,
    output logic            o_predicted_taken_2_plus4,
    output logic            o_btb_compressed_2_plus2,
    output logic            o_btb_compressed_2_plus4,
    // Legacy selected bundle.  Target and metadata retain the same selector
    // identity while the timing-critical safety/taken decision uses the fixed
    // outputs above.
    output logic            o_btb_hit_2,
    output logic            o_predicted_taken_2,
    output logic [XLEN-1:0] o_predicted_target_2,
    output logic            o_btb_compressed_2,
    output logic            o_btb_requires_pc_reg_handoff_2,

    // Update interface (from EX stage)
    input logic            i_update,                         // Update BTB entry
    input logic [XLEN-1:0] i_update_pc,                      // PC of branch instruction
    input logic [XLEN-1:0] i_update_target,                  // Actual branch target
    input logic            i_update_taken,                   // Actual branch outcome
    input logic            i_update_compressed,              // Branch was compressed (16-bit)
    input logic            i_update_requires_pc_reg_handoff,

    // Direct early-recovery RMW candidate. When active, the selected update
    // transaction above carries this same PC and outcome. The separate
    // sideband keeps the early candidate's LUTRAM address independent of the
    // higher-level early/late update-priority mux.
    input logic            i_early_update_active,
    input logic [XLEN-1:0] i_early_update_pc,
    input logic            i_early_update_taken,

    // Lower-priority RMW candidate, formed without an early-active dependency.
    // The selected update interface above remains the sole source of writes.
    input logic [XLEN-1:0] i_late_update_pc,
    input logic            i_late_update_taken
);

  // BTB parameters
  localparam int unsigned BtbEntries = 1 << BTB_INDEX_BITS;
  // Tag includes PC[1] to distinguish halfword-aligned addresses under the C
  // extension. Without PC[1], 0x100 and 0x102 would alias to the same entry.
  localparam int unsigned TagBits = XLEN - BTB_INDEX_BITS - 1;  // 55 bits in RV64
  localparam int unsigned TargetBits = riscv_pkg::PhysAddrBits;
  // Yosys 0.64 cannot parse $bits on this module-local typedef in a parameter
  // override. The simulation check below pins the spelled width to the struct.
  localparam int unsigned Slot2PayloadBits = TargetBits + 4;

  typedef struct packed {
    logic [TargetBits-1:0] target;
    logic [1:0]            counter;
    logic                  compressed;
    logic                  requires_pc_reg_handoff;
  } slot2_payload_t;

  // 2-bit saturating counter states
  localparam logic [1:0] StronglyNotTaken = 2'b00;
  localparam logic [1:0] WeaklyNotTaken = 2'b01;
  localparam logic [1:0] WeaklyTaken = 2'b10;
  localparam logic [1:0] StronglyTaken = 2'b11;

  // BTB storage
  // Keep valid bits in FFs so reset can clear them. Slot-1 payload stays in
  // LUTRAM; the staged slot-2 payloads use block RAM.
  logic btb_valid[BtbEntries];
  // Each shifted slot-2 replica keeps validity under its physical key. The
  // rotated copy duplicates these 256 resettable bits so the live fetch PC
  // never addresses a second FF-array mux through A+1.
  logic btb_valid_2[BtbEntries];
  logic btb_valid_2_alt[BtbEntries];
  logic btb_valid_2_rot[BtbEntries];
  logic [TagBits-1:0] btb_tag_lookup;
  logic [TagBits-1:0] btb_tag_update_late;
  logic [TagBits-1:0] btb_tag_update_early;
  logic [TargetBits-1:0] btb_target_lookup;
  logic [1:0] btb_counter_lookup;
  logic [1:0] btb_counter_update_late;
  logic [1:0] btb_counter_update_early;

  logic [TagBits-1:0] slot2_tag_2_async, slot2_tag_2_alt_async, slot2_tag_2_rot_async;
  logic [TagBits-1:0] slot2_tag_2_raw, slot2_tag_2_alt_raw, slot2_tag_2_rot_raw;
  logic [TagBits-1:0] slot2_tag_2, slot2_tag_2_alt, slot2_tag_2_rot;
  logic [TagBits-1:0] slot2_tag_2_forward_q, slot2_tag_2_alt_forward_q;
  slot2_payload_t slot2_payload_2_raw, slot2_payload_2_alt_raw, slot2_payload_2_rot_raw;
  slot2_payload_t slot2_payload_2, slot2_payload_2_alt, slot2_payload_2_rot;
  slot2_payload_t slot2_payload_forward_q;
  logic slot2_forward_2_q, slot2_forward_2_alt_q, slot2_forward_2_rot_q;
  logic slot2_valid_2_q, slot2_valid_2_alt_q, slot2_valid_2_rot_q;
  logic slot2_stage_ready_q;
  logic [BTB_INDEX_BITS-1:0] slot2_lookup_index_q;
  logic [BTB_INDEX_BITS-1:0] slot2_lookup_index_next_q;

  logic [1:0] next_counter;
  // The keep attributes preserve the candidate boundary so synthesis cannot
  // fold the early result back through the selected-PC RMW cone.
  (* keep = "true" *) logic [1:0] early_next_counter;
  (* keep = "true" *) logic [1:0] late_next_counter;

  // Slot-1 index is PC[9:2], selecting one of the 256 entries. The tag is
  // PC[63:10] with PC[1] appended, so halfword addresses do not alias.
  wire [BTB_INDEX_BITS-1:0] lookup_index = i_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] lookup_tag = {i_pc[XLEN-1:BTB_INDEX_BITS+2], i_pc[1]};

  // Normal one-cycle fetch service gives the live address one cycle of lead
  // over the served pc_reg. A repeated slow response can collapse that lead;
  // IF then supplies the served address as this live lookup base. All three
  // slot-2 images read the resulting word index. The rotated +2 image moves
  // its address rotation to the update side, avoiding an A+1 address/decode
  // network on the live fetch PC.
  wire [BTB_INDEX_BITS-1:0] slot2_lookup_index = i_pc_2_lookup_base[BTB_INDEX_BITS+1:2];
  wire [BTB_INDEX_BITS-1:0] slot2_lookup_index_next = slot2_lookup_index + BTB_INDEX_BITS'(1);
  wire [BTB_INDEX_BITS-1:0] lookup_index_2 = i_pc_2_base[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] lookup_tag_2 = {i_pc_2_base[XLEN-1:BTB_INDEX_BITS+2], i_pc_2_base[1]};
  wire [BTB_INDEX_BITS-1:0] lookup_index_2_alt = lookup_index_2;
  wire [TagBits-1:0] lookup_tag_2_alt = lookup_tag_2;

  // Index and tag extraction for update
  wire [BTB_INDEX_BITS-1:0] update_index = i_update_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] update_tag = {i_update_pc[XLEN-1:BTB_INDEX_BITS+2], i_update_pc[1]};

  // The early candidate is addressed directly by the captured early-recovery
  // PC.  It must not be derived from the selected update PC: doing so would
  // reconstruct the original early_active -> priority mux -> LUTRAM RMW path.
  wire [BTB_INDEX_BITS-1:0] early_update_index = i_early_update_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] early_update_tag = {
    i_early_update_pc[XLEN-1:BTB_INDEX_BITS+2], i_early_update_pc[1]
  };

  wire [BTB_INDEX_BITS-1:0] late_update_index = i_late_update_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] late_update_tag = {
    i_late_update_pc[XLEN-1:BTB_INDEX_BITS+2], i_late_update_pc[1]
  };

  // Replicate every update at the predecessor keys used by each slot-2
  // candidate.  These subtractors are update-side only and are not part of the
  // fetch-PC recurrence.
  wire [XLEN-1:0] update_pc_2_key = i_update_pc - XLEN'(2);
  wire [BTB_INDEX_BITS-1:0] update_index_2 = update_pc_2_key[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] update_tag_2 = {update_pc_2_key[XLEN-1:BTB_INDEX_BITS+2], update_pc_2_key[1]};
  wire [XLEN-1:0] update_pc_2_alt_key = i_update_pc - XLEN'(4);
  wire [BTB_INDEX_BITS-1:0] update_index_2_alt = update_pc_2_alt_key[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] update_tag_2_alt = {
    update_pc_2_alt_key[XLEN-1:BTB_INDEX_BITS+2], update_pc_2_alt_key[1]
  };
  // Rotating every +2 predecessor index by one is a bijection, so this copy
  // retains the authoritative +2 table's exact collision history. Store the
  // unrotated +2 tag so the response compares directly with i_pc_2_base.
  wire [BTB_INDEX_BITS-1:0] update_index_2_rot = update_index_2 - BTB_INDEX_BITS'(1);

  // Canonical tag RAMs for slot-1 lookup and the two update-read candidates.
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_lookup (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index),
      .i_write_data(update_tag),
      .i_read_address(lookup_index),
      .o_read_data(btb_tag_lookup)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_update (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index),
      .i_write_data(update_tag),
      .i_read_address(late_update_index),
      .o_read_data(btb_tag_update_late)
  );

  // Canonical early-update state replica. dont_touch stays confined to the two
  // early-update RMW RAMs: without it, synthesis may merge the identical write
  // state and reconstruct a single selected-PC read address.
  (* dont_touch = "yes" *)
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_early_update (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index),
      .i_write_data(update_tag),
      .i_read_address(early_update_index),
      .o_read_data(btb_tag_update_early)
  );

  // Keep target storage at the measured 32-bit FPGA geometry without turning
  // high-canonical Sv39 targets into low, zero-extended addresses. A BTB row
  // is target-valid only when the resolved target and branch PC occupy the
  // same 4-GiB region. On a hit, the exact matching lookup PC restores those
  // upper bits. Cross-region control flow still updates the RMW state below
  // but leaves the target row invalid, so the next lookup takes a harmless
  // miss. The controller's separate direction predictor keeps its independent
  // commit-time training; only target-valid BTB allocation is suppressed.
  // A direct branch meets the region check except at a 4-GiB boundary, so an
  // arbitrary cross-region JALR costs prediction coverage. Correctness holds,
  // and the three slot-2 block RAMs stay narrow.
  wire update_target_region_predictable =
      i_update_target[XLEN-1:TargetBits] == i_update_pc[XLEN-1:TargetBits];
  wire [TargetBits-1:0] update_target_stored = i_update_target[TargetBits-1:0];

  // A shifted slot-2 key must stay in the branch's region too, because the
  // response restores target upper bits directly from i_pc_2_base. These are
  // update-side-only boundary checks and do not touch the lookup recurrence.
  wire update_slot2_plus2_key_same_region = i_update_pc[TargetBits-1:0] >= TargetBits'(2);
  wire update_slot2_plus4_key_same_region = i_update_pc[TargetBits-1:0] >= TargetBits'(4);
  wire update_slot2_plus2_target_valid =
      update_target_region_predictable && update_slot2_plus2_key_same_region;
  wire update_slot2_plus4_target_valid =
      update_target_region_predictable && update_slot2_plus4_key_same_region;

  // Store each shifted slot-2 image in separate tag and payload memories. Each
  // exact 55-bit tag uses a single-address distributed RAM plus a response FF,
  // keeping all wide comparisons off block-RAM clock-to-output paths. Each
  // 36-bit payload fits one RAMB18. It stores the target's low 32-bit image;
  // a valid row restores the branch region above it, preserving high-canonical
  // virtual targets without widening the RAM.
  // T2 handles same-word +2 candidates, T4 handles +4 candidates, and RT2 is
  // a one-index rotation of T2 for adjacent-word +2.
  slot2_payload_t slot2_payload_write;
  assign slot2_payload_write = {
    update_target_stored, next_counter, i_update_compressed, i_update_requires_pc_reg_handoff
  };

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_lookup_2 (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index_2),
      .i_write_data(update_tag_2),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_tag_2_async)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_lookup_2_alt (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index_2_alt),
      .i_write_data(update_tag_2_alt),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_tag_2_alt_async)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_lookup_2_rot (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index_2_rot),
      .i_write_data(update_tag_2),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_tag_2_rot_async)
  );

  sdp_block_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(Slot2PayloadBits)
  ) btb_payload_ram_lookup_2 (
      .i_clk,
      .i_write_enable(i_update),
      .i_bulk_clear(1'b0),
      .i_write_address(update_index_2),
      .i_write_data(slot2_payload_write),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_payload_2_raw)
  );

  sdp_block_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(Slot2PayloadBits)
  ) btb_payload_ram_lookup_2_alt (
      .i_clk,
      .i_write_enable(i_update),
      .i_bulk_clear(1'b0),
      .i_write_address(update_index_2_alt),
      .i_write_data(slot2_payload_write),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_payload_2_alt_raw)
  );

  sdp_block_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(Slot2PayloadBits)
  ) btb_payload_ram_lookup_2_rot (
      .i_clk,
      .i_write_enable(i_update),
      .i_bulk_clear(1'b0),
      .i_write_address(update_index_2_rot),
      .i_write_data(slot2_payload_write),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_payload_2_rot_raw)
  );

  // Low target RAM for slot-1 lookup; the matching PC supplies upper bits.
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TargetBits)
  ) btb_target_ram (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index),
      .i_write_data(update_target_stored),
      .i_read_address(lookup_index),
      .o_read_data(btb_target_lookup)
  );

  // Canonical counter RAMs for slot-1 lookup and update reads.
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(2)
  ) btb_counter_ram_lookup (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index),
      .i_write_data(next_counter),
      .i_read_address(lookup_index),
      .o_read_data(btb_counter_lookup)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(2)
  ) btb_counter_ram_update (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index),
      .i_write_data(next_counter),
      .i_read_address(late_update_index),
      .o_read_data(btb_counter_update_late)
  );

  (* dont_touch = "yes" *)
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(2)
  ) btb_counter_ram_early_update (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index),
      .i_write_data(next_counter),
      .i_read_address(early_update_index),
      .o_read_data(btb_counter_update_early)
  );

  // Canonical compressed/handoff RAMs for slot-1 lookup.
  logic btb_compressed_lookup;
  logic btb_requires_pc_reg_handoff_lookup;
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(1)
  ) btb_compressed_ram (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index),
      .i_write_data(i_update_compressed),
      .i_read_address(lookup_index),
      .o_read_data(btb_compressed_lookup)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(1)
  ) btb_requires_pc_reg_handoff_ram (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index),
      .i_write_data(i_update_requires_pc_reg_handoff),
      .i_read_address(lookup_index),
      .o_read_data(btb_requires_pc_reg_handoff_lookup)
  );

  // Combinational slot-1 lookup
  wire lookup_valid = btb_valid[lookup_index];
  wire [TagBits-1:0] lookup_tag_stored = btb_tag_lookup;
  wire [XLEN-1:0] lookup_target = {i_pc[XLEN-1:TargetBits], btb_target_lookup};
  wire [1:0] lookup_counter = btb_counter_lookup;

  assign o_btb_hit = lookup_valid && (lookup_tag_stored == lookup_tag);

  assign o_predicted_taken = o_btb_hit && lookup_counter[1];
  assign o_predicted_target = lookup_target;
  assign o_btb_compressed = o_btb_hit && btb_compressed_lookup;
  assign o_btb_requires_pc_reg_handoff = o_btb_hit && btb_requires_pc_reg_handoff_lookup;

  // The block RAMs are read-first, and the distributed-RAM tag FFs sample their
  // pre-write values at the edge, so register the current write payload and
  // per-image collision flags alongside the returned rows. T2 and RT2 share a
  // payload because the rotated copy stores the authoritative T2 tag. Forwarding
  // the complete row preserves the former asynchronous post-edge view even for
  // a different-tag eviction.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      slot2_tag_2_raw           <= '0;
      slot2_tag_2_alt_raw       <= '0;
      slot2_tag_2_rot_raw       <= '0;
      slot2_lookup_index_q      <= '0;
      slot2_lookup_index_next_q <= '0;
      slot2_forward_2_q         <= 1'b0;
      slot2_forward_2_alt_q     <= 1'b0;
      slot2_forward_2_rot_q     <= 1'b0;
      slot2_valid_2_q           <= 1'b0;
      slot2_valid_2_alt_q       <= 1'b0;
      slot2_valid_2_rot_q       <= 1'b0;
      slot2_stage_ready_q       <= 1'b0;
    end else begin
      slot2_tag_2_raw           <= slot2_tag_2_async;
      slot2_tag_2_alt_raw       <= slot2_tag_2_alt_async;
      slot2_tag_2_rot_raw       <= slot2_tag_2_rot_async;
      slot2_lookup_index_q      <= slot2_lookup_index;
      slot2_lookup_index_next_q <= slot2_lookup_index_next;
      slot2_stage_ready_q       <= 1'b1;

      slot2_forward_2_q         <= i_update && (update_index_2 == slot2_lookup_index);
      slot2_forward_2_alt_q     <= i_update && (update_index_2_alt == slot2_lookup_index);
      slot2_forward_2_rot_q     <= i_update && (update_index_2_rot == slot2_lookup_index);

      if (i_update) begin
        slot2_tag_2_forward_q     <= update_tag_2;
        slot2_tag_2_alt_forward_q <= update_tag_2_alt;
        slot2_payload_forward_q   <= slot2_payload_write;
      end

      slot2_valid_2_q <=
          (i_update && (update_index_2 == slot2_lookup_index)) ?
          update_slot2_plus2_target_valid : btb_valid_2[slot2_lookup_index];
      slot2_valid_2_alt_q <=
          (i_update && (update_index_2_alt == slot2_lookup_index)) ?
          update_slot2_plus4_target_valid : btb_valid_2_alt[slot2_lookup_index];
      slot2_valid_2_rot_q <=
          (i_update && (update_index_2_rot == slot2_lookup_index)) ?
          update_slot2_plus2_target_valid : btb_valid_2_rot[slot2_lookup_index];
    end
  end

  assign slot2_tag_2 = slot2_forward_2_q ? slot2_tag_2_forward_q : slot2_tag_2_raw;
  assign slot2_tag_2_alt = slot2_forward_2_alt_q ? slot2_tag_2_alt_forward_q : slot2_tag_2_alt_raw;
  assign slot2_tag_2_rot = slot2_forward_2_rot_q ? slot2_tag_2_forward_q : slot2_tag_2_rot_raw;
  assign slot2_payload_2 = slot2_forward_2_q ? slot2_payload_forward_q : slot2_payload_2_raw;
  assign slot2_payload_2_alt =
      slot2_forward_2_alt_q ? slot2_payload_forward_q : slot2_payload_2_alt_raw;
  assign slot2_payload_2_rot =
      slot2_forward_2_rot_q ? slot2_payload_forward_q : slot2_payload_2_rot_raw;

  // T2 serves a current base in the early request's word. RT2 serves the next
  // word, with its write address rotated so the stored tag remains the current
  // base's authoritative T2 tag. T4 is needed only for the same-word case.
  // Full tags reject aliases; any uncovered relationship is a benign BTB miss.
  slot2_payload_t lookup_payload_2, lookup_payload_2_alt;
  logic slot2_stage_base_index_covered;
  logic slot2_stage_next_index_covered;
  logic slot2_hit_2_base, slot2_hit_2_rot, slot2_hit_2_alt;
  // Keep forwarding selection after the wide comparisons. A tag-wide mux in
  // front of equality adds a LUT level to the slot-2 redirect recurrence.
  (* keep = "true" *)logic slot2_tag_2_raw_matches;
  (* keep = "true" *)logic slot2_tag_2_alt_raw_matches;
  (* keep = "true" *)logic slot2_tag_2_rot_raw_matches;
  logic slot2_tag_2_forward_matches, slot2_tag_2_alt_forward_matches;
  always_comb begin
    lookup_payload_2 = '0;
    lookup_payload_2_alt = '0;
    slot2_stage_base_index_covered =
        slot2_stage_ready_q && (lookup_index_2 == slot2_lookup_index_q);
    slot2_stage_next_index_covered =
        slot2_stage_ready_q && (lookup_index_2 == slot2_lookup_index_next_q);

    if (slot2_stage_base_index_covered) begin
      lookup_payload_2     = slot2_payload_2;
      lookup_payload_2_alt = slot2_payload_2_alt;
    end else if (slot2_stage_next_index_covered) begin
      lookup_payload_2 = slot2_payload_2_rot;
    end
  end

  assign slot2_tag_2_raw_matches = slot2_tag_2_raw == lookup_tag_2;
  assign slot2_tag_2_alt_raw_matches = slot2_tag_2_alt_raw == lookup_tag_2_alt;
  assign slot2_tag_2_rot_raw_matches = slot2_tag_2_rot_raw == lookup_tag_2;
  assign slot2_tag_2_forward_matches = slot2_tag_2_forward_q == lookup_tag_2;
  assign slot2_tag_2_alt_forward_matches = slot2_tag_2_alt_forward_q == lookup_tag_2_alt;
  assign slot2_hit_2_base =
      slot2_valid_2_q &&
      (slot2_forward_2_q ? slot2_tag_2_forward_matches : slot2_tag_2_raw_matches);
  assign slot2_hit_2_rot =
      slot2_valid_2_rot_q &&
      (slot2_forward_2_rot_q ? slot2_tag_2_forward_matches : slot2_tag_2_rot_raw_matches);
  assign slot2_hit_2_alt =
      slot2_valid_2_alt_q &&
      (slot2_forward_2_alt_q ? slot2_tag_2_alt_forward_matches : slot2_tag_2_alt_raw_matches);
  wire btb_hit_2 = (slot2_stage_base_index_covered && slot2_hit_2_base) ||
      (slot2_stage_next_index_covered && slot2_hit_2_rot);
  wire btb_hit_2_alt = slot2_stage_base_index_covered && slot2_hit_2_alt;
  wire selected_btb_hit_2 = i_pc_2_use_alt ? btb_hit_2_alt : btb_hit_2;
  assign o_predicted_taken_2_plus2 = btb_hit_2 && lookup_payload_2.counter[1];
  assign o_predicted_taken_2_plus4 = btb_hit_2_alt && lookup_payload_2_alt.counter[1];
  assign o_btb_compressed_2_plus2 = btb_hit_2 && lookup_payload_2.compressed;
  assign o_btb_compressed_2_plus4 = btb_hit_2_alt && lookup_payload_2_alt.compressed;
  assign o_btb_hit_2 = selected_btb_hit_2;
  assign o_predicted_taken_2 = i_pc_2_use_alt ?
      o_predicted_taken_2_plus4 : o_predicted_taken_2_plus2;
  // Every valid shifted row was allocated only when its predecessor key,
  // branch PC, and resolved target shared this upper region. Reattaching the
  // served predecessor's upper bits is therefore exact for both candidates.
  assign o_predicted_target_2 = {
    i_pc_2_base[XLEN-1:TargetBits],
    i_pc_2_use_alt ? lookup_payload_2_alt.target : lookup_payload_2.target
  };
  assign o_btb_compressed_2 = i_pc_2_use_alt ? o_btb_compressed_2_plus4 : o_btb_compressed_2_plus2;
  assign o_btb_requires_pc_reg_handoff_2 =
      selected_btb_hit_2 &&
      (i_pc_2_use_alt ? lookup_payload_2_alt.requires_pc_reg_handoff :
                        lookup_payload_2.requires_pc_reg_handoff);

  // Calculate the early candidate directly from the captured early PC/outcome.
  // The early canonical replica receives every actual selected write, not only
  // early writes, so it stays cycle-for-cycle equal to the late canonical RAM.
  wire early_tag_matches =
      btb_valid[early_update_index] && (btb_tag_update_early == early_update_tag);
  always_comb begin
    if (!early_tag_matches) begin
      early_next_counter = i_early_update_taken ? WeaklyTaken : WeaklyNotTaken;
    end else if (i_early_update_taken) begin
      early_next_counter = (btb_counter_update_early == StronglyTaken) ?
          StronglyTaken : btb_counter_update_early + 2'b01;
    end else begin
      early_next_counter = (btb_counter_update_early == StronglyNotTaken) ?
          StronglyNotTaken : btb_counter_update_early - 2'b01;
    end
  end

  // Calculate the lower-priority candidate from a PC/outcome selector whose
  // fan-in excludes early_update_active.  The canonical replica still receives
  // every actual selected write, including early writes.
  wire late_tag_matches = btb_valid[late_update_index] && (btb_tag_update_late == late_update_tag);
  always_comb begin
    if (!late_tag_matches) begin
      late_next_counter = i_late_update_taken ? WeaklyTaken : WeaklyNotTaken;
    end else if (i_late_update_taken) begin
      late_next_counter = (btb_counter_update_late == StronglyTaken) ?
          StronglyTaken : btb_counter_update_late + 2'b01;
    end else begin
      late_next_counter = (btb_counter_update_late == StronglyNotTaken) ?
          StronglyNotTaken : btb_counter_update_late - 2'b01;
    end
  end

  // The only early/late selection in the counter RMW is this final 2-bit mux.
  assign next_counter = i_early_update_active ? early_next_counter : late_next_counter;

  // Synchronous update and reset
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int i = 0; i < BtbEntries; i++) begin
        btb_valid[i]       <= 1'b0;
        btb_valid_2[i]     <= 1'b0;
        btb_valid_2_alt[i] <= 1'b0;
        btb_valid_2_rot[i] <= 1'b0;
      end
    end else if (i_update) begin
      btb_valid[update_index]             <= update_target_region_predictable;
      btb_valid_2[update_index_2]         <= update_slot2_plus2_target_valid;
      btb_valid_2_alt[update_index_2_alt] <= update_slot2_plus4_target_valid;
      btb_valid_2_rot[update_index_2_rot] <= update_slot2_plus2_target_valid;
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (Slot2PayloadBits != $bits(slot2_payload_t)) begin
      $error("branch_predictor: Slot2PayloadBits does not match slot2_payload_t");
    end
  end

  // These assertions check that the externally selected slot-2 bundle matches,
  // bit for bit, the +2/+4 candidate i_pc_2_use_alt picks. Safety/taken and
  // candidate-valid qualification happen ahead of this selector, in
  // branch_prediction_controller.
  always_comb begin
    if (!$isunknown(
            {
              i_pc_2_use_alt,
              btb_hit_2,
              btb_hit_2_alt,
              lookup_payload_2,
              lookup_payload_2_alt,
              o_btb_hit_2,
              o_predicted_taken_2,
              o_predicted_target_2,
              o_btb_compressed_2
            }
        )) begin
      p_slot2_hit_selector_identity :
      assert (o_btb_hit_2 == (i_pc_2_use_alt ? btb_hit_2_alt : btb_hit_2));
      p_slot2_taken_selector_identity :
      assert (o_predicted_taken_2 ==
              (i_pc_2_use_alt ? (btb_hit_2_alt && lookup_payload_2_alt.counter[1]) :
                                  (btb_hit_2 && lookup_payload_2.counter[1])));
      p_slot2_target_selector_identity :
      assert (o_predicted_target_2 ==
              {i_pc_2_base[XLEN-1:TargetBits],
               i_pc_2_use_alt ? lookup_payload_2_alt.target : lookup_payload_2.target});
      p_slot2_size_selector_identity :
      assert (o_btb_compressed_2 ==
              (i_pc_2_use_alt ? (btb_hit_2_alt && lookup_payload_2_alt.compressed) :
                                  (btb_hit_2 && lookup_payload_2.compressed)));
    end
  end

  // An independent model of the update state checks both the physical replica
  // invariant and the selected update's exact counter semantics. The reference
  // counter comes from its own saturating calculation, never from next_counter.
  logic reference_update_valid[BtbEntries];
  logic [TagBits-1:0] reference_update_tag[BtbEntries];
  logic [1:0] reference_update_counter[BtbEntries];
  logic [1:0] reference_selected_next_counter;

  wire reference_selected_tag_matches =
      reference_update_valid[update_index] &&
      (reference_update_tag[update_index] == update_tag);

  always_comb begin
    if (!reference_selected_tag_matches) begin
      reference_selected_next_counter = i_update_taken ? WeaklyTaken : WeaklyNotTaken;
    end else if (i_update_taken) begin
      reference_selected_next_counter =
          (reference_update_counter[update_index] == StronglyTaken) ?
          StronglyTaken : reference_update_counter[update_index] + 2'b01;
    end else begin
      reference_selected_next_counter =
          (reference_update_counter[update_index] == StronglyNotTaken) ?
          StronglyNotTaken : reference_update_counter[update_index] - 2'b01;
    end
  end

  initial begin
    for (int i = 0; i < BtbEntries; i++) begin
      reference_update_valid[i]   = 1'b0;
      reference_update_tag[i]     = '0;
      reference_update_counter[i] = '0;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int i = 0; i < BtbEntries; i++) begin
        reference_update_valid[i] <= 1'b0;
      end
    end else if (i_update) begin
      reference_update_valid[update_index] <= update_target_region_predictable;
    end

    if (i_update) begin
      reference_update_tag[update_index]     <= update_tag;
      reference_update_counter[update_index] <= reference_selected_next_counter;
    end
  end

  always_ff @(posedge i_clk) begin
    if (!$isunknown({late_update_index, early_update_index})) begin
      p_late_update_tag_state_equivalent :
      assert (btb_tag_update_late == reference_update_tag[late_update_index]);
      p_late_update_counter_state_equivalent :
      assert (btb_counter_update_late == reference_update_counter[late_update_index]);
      p_early_update_tag_state_equivalent :
      assert (btb_tag_update_early == reference_update_tag[early_update_index]);
      p_early_update_counter_state_equivalent :
      assert (btb_counter_update_early == reference_update_counter[early_update_index]);
    end

    if (!i_rst && i_update && !$isunknown(
            {update_index, update_tag, i_update_taken,
                     reference_selected_next_counter, next_counter}
        )) begin
      p_selected_counter_matches_legacy : assert (next_counter == reference_selected_next_counter);
    end

    if (!i_rst && i_early_update_active && !$isunknown(
            {i_update, i_update_pc, i_update_taken, i_early_update_pc, i_early_update_taken}
        )) begin
      p_early_update_is_selected : assert (i_update);
      p_early_update_pc_is_selected : assert (i_update_pc == i_early_update_pc);
      p_early_update_outcome_is_selected : assert (i_update_taken == i_early_update_taken);
    end

    if (!i_rst && i_update && !i_early_update_active && !$isunknown(
            {i_update_pc, i_update_taken, i_late_update_pc, i_late_update_taken}
        )) begin
      p_late_update_pc_is_selected : assert (i_update_pc == i_late_update_pc);
      p_late_update_outcome_is_selected : assert (i_update_taken == i_late_update_taken);
    end
  end

  // Independent reference models for the three shifted slot-2 images. RT2
  // uses the rotated physical address but stores the authoritative T2 tag.
  // These checks cover replacement topology, synchronous capture, and the
  // read-first write forwarding.
  typedef struct packed {
    logic [TagBits-1:0] tag;
    slot2_payload_t     payload;
  } slot2_reference_row_t;
  logic shifted_reference_valid_2[BtbEntries];
  slot2_reference_row_t shifted_reference_row_2[BtbEntries];
  logic shifted_reference_valid_2_alt[BtbEntries];
  slot2_reference_row_t shifted_reference_row_2_alt[BtbEntries];
  logic shifted_reference_valid_2_rot[BtbEntries];
  slot2_reference_row_t shifted_reference_row_2_rot[BtbEntries];

  wire shifted_reference_hit_2 = shifted_reference_valid_2[lookup_index_2] &&
      (shifted_reference_row_2[lookup_index_2].tag == lookup_tag_2);
  wire shifted_reference_hit_2_alt = shifted_reference_valid_2_alt[lookup_index_2_alt] &&
      (shifted_reference_row_2_alt[lookup_index_2_alt].tag == lookup_tag_2_alt);
  wire [BTB_INDEX_BITS-1:0] shifted_reference_index_2_rot = lookup_index_2 - BTB_INDEX_BITS'(1);
  wire shifted_reference_hit_2_rot =
      shifted_reference_valid_2_rot[shifted_reference_index_2_rot] &&
      (shifted_reference_row_2_rot[shifted_reference_index_2_rot].tag == lookup_tag_2);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int i = 0; i < BtbEntries; i++) begin
        shifted_reference_valid_2[i]     <= 1'b0;
        shifted_reference_valid_2_alt[i] <= 1'b0;
        shifted_reference_valid_2_rot[i] <= 1'b0;
      end
    end else if (i_update) begin
      shifted_reference_valid_2[update_index_2] <= update_slot2_plus2_target_valid;
      shifted_reference_row_2[update_index_2] <= {
        update_tag_2,
        update_target_stored,
        reference_selected_next_counter,
        i_update_compressed,
        i_update_requires_pc_reg_handoff
      };
      shifted_reference_valid_2_alt[update_index_2_alt] <= update_slot2_plus4_target_valid;
      shifted_reference_row_2_alt[update_index_2_alt] <= {
        update_tag_2_alt,
        update_target_stored,
        reference_selected_next_counter,
        i_update_compressed,
        i_update_requires_pc_reg_handoff
      };
      shifted_reference_valid_2_rot[update_index_2_rot] <= update_slot2_plus2_target_valid;
      shifted_reference_row_2_rot[update_index_2_rot] <= {
        update_tag_2,
        update_target_stored,
        reference_selected_next_counter,
        i_update_compressed,
        i_update_requires_pc_reg_handoff
      };
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst && !$isunknown({i_pc_2_base, slot2_lookup_index_q, slot2_lookup_index_next_q})) begin
      p_slot2_valid_capture_exact :
      assert (slot2_valid_2_q == shifted_reference_valid_2[slot2_lookup_index_q]);
      p_slot2_alt_valid_capture_exact :
      assert (slot2_valid_2_alt_q == shifted_reference_valid_2_alt[slot2_lookup_index_q]);
      p_slot2_rot_valid_capture_exact :
      assert (slot2_valid_2_rot_q == shifted_reference_valid_2_rot[slot2_lookup_index_q]);

      if (slot2_valid_2_q) begin
        p_slot2_tag_capture_exact :
        assert (slot2_tag_2 == shifted_reference_row_2[slot2_lookup_index_q].tag);
        p_slot2_payload_capture_exact :
        assert (slot2_payload_2 == shifted_reference_row_2[slot2_lookup_index_q].payload);
      end
      if (slot2_valid_2_alt_q) begin
        p_slot2_alt_tag_capture_exact :
        assert (slot2_tag_2_alt == shifted_reference_row_2_alt[slot2_lookup_index_q].tag);
        p_slot2_alt_payload_capture_exact :
        assert (slot2_payload_2_alt == shifted_reference_row_2_alt[slot2_lookup_index_q].payload);
      end
      if (slot2_valid_2_rot_q) begin
        p_slot2_rot_tag_capture_exact :
        assert (slot2_tag_2_rot == shifted_reference_row_2_rot[slot2_lookup_index_q].tag);
        p_slot2_rot_payload_capture_exact :
        assert (slot2_payload_2_rot == shifted_reference_row_2_rot[slot2_lookup_index_q].payload);
      end

      p_slot2_shift_hit_equivalent :
      assert (btb_hit_2 ==
              ((slot2_stage_base_index_covered && shifted_reference_hit_2) ||
               (slot2_stage_next_index_covered && shifted_reference_hit_2_rot)));
      p_slot2_alt_shift_hit_equivalent :
      assert (btb_hit_2_alt == (slot2_stage_base_index_covered && shifted_reference_hit_2_alt));
      if (slot2_stage_base_index_covered && shifted_reference_hit_2) begin
        p_slot2_shift_payload_equivalent :
        assert (lookup_payload_2 == shifted_reference_row_2[lookup_index_2].payload);
      end
      if (slot2_stage_next_index_covered && shifted_reference_hit_2_rot) begin
        p_slot2_rot_shift_payload_equivalent :
        assert (lookup_payload_2 ==
                shifted_reference_row_2_rot[shifted_reference_index_2_rot].payload);
      end
      if (slot2_stage_base_index_covered && shifted_reference_hit_2_alt) begin
        p_slot2_alt_shift_payload_equivalent :
        assert (lookup_payload_2_alt == shifted_reference_row_2_alt[lookup_index_2_alt].payload);
      end
    end
  end
`endif

endmodule : branch_predictor
