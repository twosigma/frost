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
 * Direct-mapped BTB with 2-bit saturating counters: 256 entries by default,
 * indexed by PC[9:2]. Tags include PC[1], so a lookup at one halfword of a
 * word never hits an entry trained for the other. A hit predicts taken when
 * counter[1] is set.
 *
 * An entry stores the target's low 32 bits and is valid only if the branch and
 * its target share a 4-GiB region; a hit takes the upper bits from the lookup
 * PC (hw/rtl/cpu_and_mem/cpu/README.md, "4 GiB target limit").
 *
 * Slot 1 reads combinationally at the fetch PC. Slot 2 reads three shifted
 * images (+2, +4, and a +2 copy rotated by one index for the next word) at the
 * fetch PC and checks the registered rows against the served pc_reg one cycle
 * later. Updates write synchronously: a lookup sees the old entry before the
 * write edge and the new entry after it, including on back-to-back updates to
 * one index.
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

    // Slot-2 prediction interface. The shifted images store each branch under
    // the PC 2 or 4 bytes before it, so a lookup at base pc_reg finds a slot 2
    // at pc_reg+2 or pc_reg+4. The live fetch PC (i_pc_2_lookup_base) launches
    // the synchronous row reads one cycle ahead; the served base (i_pc_2_base)
    // then selects a registered row and checks its tag. The rotated +2 image
    // covers a base in the next word without a second read address.
    input  logic [XLEN-1:0] i_pc_2_lookup_base,
    input  logic [XLEN-1:0] i_pc_2_base,
    input  logic            i_pc_2_use_alt,
    // Per-candidate taken and size results. The controller qualifies and
    // valid-gates each in parallel, then ORs the one-hot one-bit results.
    output logic            o_predicted_taken_2_plus2,
    output logic            o_predicted_taken_2_plus4,
    output logic            o_btb_compressed_2_plus2,
    output logic            o_btb_compressed_2_plus4,
    // Per-candidate hits, then the candidate i_pc_2_use_alt selects (+4 when
    // set, else +2). The controller's timing-critical taken decision uses the
    // per-candidate outputs above instead of the selected ones.
    output logic            o_btb_hit_2_plus2,
    output logic            o_btb_hit_2_plus4,
    output logic            o_btb_hit_2,
    output logic            o_predicted_taken_2,
    output logic [XLEN-1:0] o_predicted_target_2,
    output logic            o_btb_compressed_2,
    output logic            o_btb_requires_pc_reg_handoff_2,

    // Update interface: at most one selected training write per cycle
    input logic            i_update,                         // Update BTB entry
    input logic [XLEN-1:0] i_update_pc,                      // PC of branch instruction
    input logic [XLEN-1:0] i_update_target,                  // Actual branch target
    input logic            i_update_taken,                   // Actual branch outcome
    input logic            i_update_compressed,              // Branch was compressed (16-bit)
    input logic            i_update_requires_pc_reg_handoff,

    // Early-recovery counter RMW candidate. When active, the selected update
    // above carries this same PC and outcome. This separate input keeps the
    // early candidate's LUTRAM read address independent of the upstream
    // early/late update-priority mux.
    input logic            i_early_update_active,
    input logic [XLEN-1:0] i_early_update_pc,
    input logic            i_early_update_taken,

    // Late (lower-priority) counter RMW candidate, formed without depending on
    // early-active. An update with no early candidate carries this PC and
    // outcome. All writes come from the selected update interface above.
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
  // Each slot-2 image has its own valid bits, indexed like its RAM. The
  // rotated image's copy lets the live fetch PC read all three at one index,
  // with no A+1 read into a second FF array.
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

  // Slot-1 lookup index and tag
  wire [BTB_INDEX_BITS-1:0] lookup_index = i_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] lookup_tag = {i_pc[XLEN-1:BTB_INDEX_BITS+2], i_pc[1]};

  // Slot-2 read index. The live fetch PC normally leads the served pc_reg by
  // one cycle; when a slow response collapses that lead, the live PC is the
  // served address itself. All three images read this one word index. The
  // rotated +2 image applies its rotation on the write side, so no read address
  // needs an A+1 adder; slot2_lookup_index_next only feeds the registered
  // next-index coverage check.
  wire [BTB_INDEX_BITS-1:0] slot2_lookup_index = i_pc_2_lookup_base[BTB_INDEX_BITS+1:2];
  wire [BTB_INDEX_BITS-1:0] slot2_lookup_index_next = slot2_lookup_index + BTB_INDEX_BITS'(1);
  wire [BTB_INDEX_BITS-1:0] lookup_index_2 = i_pc_2_base[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] lookup_tag_2 = {i_pc_2_base[XLEN-1:BTB_INDEX_BITS+2], i_pc_2_base[1]};
  wire [BTB_INDEX_BITS-1:0] lookup_index_2_alt = lookup_index_2;
  wire [TagBits-1:0] lookup_tag_2_alt = lookup_tag_2;

  // Index and tag extraction for update
  wire [BTB_INDEX_BITS-1:0] update_index = i_update_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] update_tag = {i_update_pc[XLEN-1:BTB_INDEX_BITS+2], i_update_pc[1]};

  // The early candidate is addressed directly by i_early_update_pc. Deriving
  // it from the selected update PC would put the early_active priority mux in
  // front of the LUTRAM read address.
  wire [BTB_INDEX_BITS-1:0] early_update_index = i_early_update_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] early_update_tag = {
    i_early_update_pc[XLEN-1:BTB_INDEX_BITS+2], i_early_update_pc[1]
  };

  wire [BTB_INDEX_BITS-1:0] late_update_index = i_late_update_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] late_update_tag = {
    i_late_update_pc[XLEN-1:BTB_INDEX_BITS+2], i_late_update_pc[1]
  };

  // Every update is also written to the slot-2 images, keyed by the branch PC
  // minus 2 (T2) and minus 4 (T4). These subtractors are on the update side
  // only, off the fetch-PC recurrence.
  wire [XLEN-1:0] update_pc_2_key = i_update_pc - XLEN'(2);
  wire [BTB_INDEX_BITS-1:0] update_index_2 = update_pc_2_key[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] update_tag_2 = {update_pc_2_key[XLEN-1:BTB_INDEX_BITS+2], update_pc_2_key[1]};
  wire [XLEN-1:0] update_pc_2_alt_key = i_update_pc - XLEN'(4);
  wire [BTB_INDEX_BITS-1:0] update_index_2_alt = update_pc_2_alt_key[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] update_tag_2_alt = {
    update_pc_2_alt_key[XLEN-1:BTB_INDEX_BITS+2], update_pc_2_alt_key[1]
  };
  // RT2 writes each T2 row one index lower. The shift is a bijection, so
  // RT2[i-1] always equals T2[i]. RT2 keeps the unshifted T2 tag so its
  // response compares directly with i_pc_2_base.
  wire [BTB_INDEX_BITS-1:0] update_index_2_rot = update_index_2 - BTB_INDEX_BITS'(1);

  // Tag RAM copies, all written by every update: one read by the slot-1
  // lookup, one by the late update candidate, and one (below) by the early
  // candidate.
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

  // Early-candidate copy. dont_touch is on the two early-candidate RAMs only:
  // without it, synthesis may merge the identical copies and reconstruct a
  // single selected-PC read address.
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

  // Targets are stored as their low 32 bits, which keeps the three slot-2
  // block RAMs narrow. So that high-canonical Sv39 targets do not become low,
  // zero-extended addresses, a row is valid only when the target and the
  // branch PC share a 4-GiB region, and a hit restores the upper bits from the
  // matching lookup PC. A cross-region update still writes the RAMs but clears
  // the row's valid bit, so the next lookup misses; the direction predictor
  // trains separately and is unaffected. Conditional branches and JALs, the
  // only instructions that train the BTB, cross a region only near a 4-GiB
  // boundary.
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

  // Each slot-2 image keeps its tag and payload in separate memories. The
  // 55-bit tag is a distributed RAM read at one address plus a response
  // register, keeping the wide comparisons off block-RAM clock-to-output
  // paths. The 36-bit payload (the target's low 32 bits, counter, compressed,
  // and handoff flags) fits one RAMB18. T2 and T4 cover a served base in the
  // word that was read; RT2 covers the +2 candidate of a base in the next word.
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

  // Counter RAM copies for the slot-1 lookup and the late and early update
  // reads.
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

  // Compressed and handoff flags for the slot-1 lookup.
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

  // Compare the full tag in 14-bit groups and keep the partial matches, so the
  // async lookup does not feed one long carry-chain equality. The default
  // 55-bit tag gives four groups, leaving LUT6 inputs for the valid and taken
  // bits.
  localparam int unsigned TagCompareChunkBits = 14;
  localparam int unsigned TagCompareChunks =
      (TagBits + TagCompareChunkBits - 1) / TagCompareChunkBits;
  (* keep = "true" *) logic [TagCompareChunks-1:0] lookup_tag_equal_chunks;
  for (genvar chunk = 0; chunk < TagCompareChunks; chunk++) begin : gen_lookup_tag_compare
    localparam int unsigned FirstBit = chunk * TagCompareChunkBits;
    localparam int unsigned ChunkWidth =
        (TagBits - FirstBit < TagCompareChunkBits) ? TagBits - FirstBit : TagCompareChunkBits;
    assign lookup_tag_equal_chunks[chunk] =
        lookup_tag_stored[FirstBit+:ChunkWidth] == lookup_tag[FirstBit+:ChunkWidth];
  end
  assign o_btb_hit = lookup_valid && (&lookup_tag_equal_chunks);

`ifdef BTB_TAG_COMPARE_LOCAL_PROOF
  // The btb_tag_compare formal target makes the RAM outputs arbitrary and
  // proves the grouped comparison equals the full-width reference, with no
  // assumption about reset, valid bits, reachable addresses, or table contents.
  always_comb begin
    p_lookup_tag_comparison_exact :
    assert ((&lookup_tag_equal_chunks) == (lookup_tag_stored == lookup_tag));
  end
`endif

  assign o_predicted_taken = o_btb_hit && lookup_counter[1];
  assign o_predicted_target = lookup_target;
  assign o_btb_compressed = o_btb_hit && btb_compressed_lookup;
  assign o_btb_requires_pc_reg_handoff = o_btb_hit && btb_requires_pc_reg_handoff_lookup;

  // Slot-2 response registers. The block RAMs are read-first and the tag
  // registers sample the distributed RAMs before the write edge, so a write to
  // the row being read would be missed. Register the write's tag, payload, and
  // per-image collision flags beside the returned rows and forward the whole
  // row, so the response shows the post-write contents even when the write
  // evicts a different tag. All images write the same payload, so one
  // forwarded payload serves all three; RT2 stores the T2 tag, so T2 and RT2
  // share a forwarded tag.
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

  // Pick the rows for the served base: T2 and T4 when its index is the one
  // that was read, RT2 (+2 only) when its index is the next one; any other
  // served base misses. Comparing indices is enough because a row depends
  // only on its index, and the full tag rejects aliases.
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

  // As for slot 1, keep grouped partial matches so no wide comparison becomes a
  // long carry chain on the served-PC -> prediction loop. Each raw and forwarded
  // tag is compared separately, ahead of the forwarding muxes.
  (* keep = "true" *) logic [4:0][TagCompareChunks-1:0] slot2_tag_equal_chunks;
  for (genvar chunk = 0; chunk < TagCompareChunks; chunk++) begin : gen_slot2_tag_compare
    localparam int unsigned FirstBit = chunk * TagCompareChunkBits;
    localparam int unsigned Bits =
        (TagBits - FirstBit < TagCompareChunkBits) ? TagBits - FirstBit : TagCompareChunkBits;
    assign slot2_tag_equal_chunks[0][chunk] =
        slot2_tag_2_raw[FirstBit+:Bits] == lookup_tag_2[FirstBit+:Bits];
    assign slot2_tag_equal_chunks[1][chunk] =
        slot2_tag_2_alt_raw[FirstBit+:Bits] == lookup_tag_2[FirstBit+:Bits];
    assign slot2_tag_equal_chunks[2][chunk] =
        slot2_tag_2_rot_raw[FirstBit+:Bits] == lookup_tag_2[FirstBit+:Bits];
    assign slot2_tag_equal_chunks[3][chunk] =
        slot2_tag_2_forward_q[FirstBit+:Bits] == lookup_tag_2[FirstBit+:Bits];
    assign slot2_tag_equal_chunks[4][chunk] =
        slot2_tag_2_alt_forward_q[FirstBit+:Bits] == lookup_tag_2[FirstBit+:Bits];
  end
  assign slot2_tag_2_raw_matches = &slot2_tag_equal_chunks[0];
  assign slot2_tag_2_alt_raw_matches = &slot2_tag_equal_chunks[1];
  assign slot2_tag_2_rot_raw_matches = &slot2_tag_equal_chunks[2];
  assign slot2_tag_2_forward_matches = &slot2_tag_equal_chunks[3];
  assign slot2_tag_2_alt_forward_matches = &slot2_tag_equal_chunks[4];
`ifdef BTB_TAG_COMPARE_LOCAL_PROOF
  always_comb begin
    assert (slot2_tag_2_raw_matches == (slot2_tag_2_raw == lookup_tag_2));
    assert (slot2_tag_2_alt_raw_matches == (slot2_tag_2_alt_raw == lookup_tag_2));
    assert (slot2_tag_2_rot_raw_matches == (slot2_tag_2_rot_raw == lookup_tag_2));
    assert (slot2_tag_2_forward_matches == (slot2_tag_2_forward_q == lookup_tag_2));
    assert (slot2_tag_2_alt_forward_matches == (slot2_tag_2_alt_forward_q == lookup_tag_2));
  end
`endif
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
  assign o_btb_hit_2_plus2 = btb_hit_2;
  assign o_btb_hit_2_plus4 = btb_hit_2_alt;
  assign o_btb_hit_2 = selected_btb_hit_2;
  assign o_predicted_taken_2 = i_pc_2_use_alt ?
      o_predicted_taken_2_plus4 : o_predicted_taken_2_plus2;
  // A valid slot-2 row was written only when its key, the branch PC, and the
  // target share one 4-GiB region, so i_pc_2_base supplies the exact upper
  // bits for either candidate.
  assign o_predicted_target_2 = {
    i_pc_2_base[XLEN-1:TargetBits],
    i_pc_2_use_alt ? lookup_payload_2_alt.target : lookup_payload_2.target
  };
  assign o_btb_compressed_2 = i_pc_2_use_alt ? o_btb_compressed_2_plus4 : o_btb_compressed_2_plus2;
  assign o_btb_requires_pc_reg_handoff_2 =
      selected_btb_hit_2 &&
      (i_pc_2_use_alt ? lookup_payload_2_alt.requires_pc_reg_handoff :
                        lookup_payload_2.requires_pc_reg_handoff);

  // Early candidate, from the early PC and outcome. Its RAM copies take every
  // selected write, not only early ones, so they always hold the same state as
  // the late copies.
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

  // Late candidate, from a PC and outcome that do not depend on
  // i_early_update_active. Its RAM copies also take every selected write,
  // including early ones.
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

  // Check that the selected slot-2 bundle equals, bit for bit, the +2 or +4
  // candidate that i_pc_2_use_alt picks. branch_prediction_controller does the
  // safety and candidate-valid qualification on the per-candidate outputs.
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

  // A reference model of the tag and counter state checks that the early and
  // late RAM copies both match it, and that next_counter follows the
  // saturating-counter rule. The model computes its own next counter and never
  // reads next_counter.
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

  // Reference models of the three slot-2 images (RT2 at the rotated index,
  // with the T2 tag). The checks cover which rows each update replaces, the
  // registered capture, and the forwarding around the read-first RAMs.
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
