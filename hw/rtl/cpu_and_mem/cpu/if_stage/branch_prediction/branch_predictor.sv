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
 *   - 256 entries indexed by PC[9:2] (8 bits) by default.  Sized up from 128:
 *     CoreMark's branch working set overflows 128 entries, so the extra
 *     capacity raises BTB hit rate and cuts front-end redirect bubbles (the
 *     dominant measured branch cost) with no change to the prediction policy.
 *   - Each entry: valid (1) + tag (23 bits) + target (32) + counter (2) +
 *     compressed (1) + requires_pc_reg_handoff (1)
 *   - Tag includes PC[1] to distinguish halfword-aligned addresses (C extension)
 *   - Counter encoding:
 *       00 = Strongly Not-Taken, 01 = Weakly Not-Taken
 *       10 = Weakly Taken,       11 = Strongly Taken
 * Lookup is combinational; EX updates tag, target, and the saturated counter
 * synchronously. A hit predicts taken when counter[1] is set.
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

    // Slot-2 prediction interface.  Separate replicas hold the pc_reg+2 and
    // pc_reg+4 entries under predecessor keys pc_reg.  Both asynchronous RAM
    // addresses therefore use the unmodified base PC; the late slot-1 size bit
    // selects only after both lookups have completed.
    input  logic [XLEN-1:0] i_pc_2_base,
    input  logic            i_pc_2_use_alt,
    // Fixed-candidate direction/size results.  The controller qualifies these
    // in parallel, then applies i_pc_2_use_alt only to the final one-bit result.
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

    // Direct early-recovery RMW candidate.  When active, the selected update
    // transaction above is guaranteed to carry this same PC and outcome.  The
    // separate sideband keeps the early candidate's LUTRAM address independent
    // of the higher-level early/late update-priority mux.
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
  // Tag includes PC[1] to distinguish halfword-aligned addresses (important for C extension).
  // Without PC[1], addresses like 0x100 and 0x102 would alias to the same entry.
  localparam int unsigned TagBits = XLEN - BTB_INDEX_BITS - 1;  // 23 bits (includes PC[1])

  // 2-bit saturating counter states
  localparam logic [1:0] StronglyNotTaken = 2'b00;
  localparam logic [1:0] WeaklyNotTaken = 2'b01;
  localparam logic [1:0] WeaklyTaken = 2'b10;
  localparam logic [1:0] StronglyTaken = 2'b11;

  // BTB storage
  // Keep valid bits in FFs for explicit reset. Move tag/target/counter to LUTRAM.
  logic btb_valid[BtbEntries];
  // Each shifted slot-2 replica needs validity stored under its own key.
  logic btb_valid_2[BtbEntries];
  logic btb_valid_2_alt[BtbEntries];
  logic [TagBits-1:0] btb_tag_lookup;
  logic [TagBits-1:0] btb_tag_lookup_2;  // slot-2 read port
  logic [TagBits-1:0] btb_tag_lookup_2_alt;
  logic [TagBits-1:0] btb_tag_update_late;
  logic [TagBits-1:0] btb_tag_update_early;
  logic [XLEN-1:0] btb_target_lookup;
  logic [XLEN-1:0] btb_target_lookup_2;
  logic [XLEN-1:0] btb_target_lookup_2_alt;
  logic [1:0] btb_counter_lookup;
  logic [1:0] btb_counter_lookup_2;
  logic [1:0] btb_counter_lookup_2_alt;
  logic [1:0] btb_counter_update_late;
  logic [1:0] btb_counter_update_early;

  logic [1:0] next_counter;
  // Keep the candidate boundary explicit so synthesis cannot fold the early
  // result back through the selected-PC RMW cone.
  (* keep = "true" *) logic [1:0] early_next_counter;
  (* keep = "true" *) logic [1:0] late_next_counter;

  // Index and tag extraction for slot-1 lookup
  // Index: PC[9:2] (8 bits) - selects which of 256 entries
  // Tag: PC[31:10] concatenated with PC[1] (23 bits) - distinguishes halfword addresses
  wire [BTB_INDEX_BITS-1:0] lookup_index = i_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] lookup_tag = {i_pc[XLEN-1:BTB_INDEX_BITS+2], i_pc[1]};

  // Both shifted slot-2 arrays are read with the same unmodified pc_reg key.
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

  // Tag RAMs (replicated for slot-1 lookup, slot-2 lookup, and update reads)
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
  ) btb_tag_ram_lookup_2 (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index_2),
      .i_write_data(update_tag_2),
      .i_read_address(lookup_index_2),
      .o_read_data(btb_tag_lookup_2)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_lookup_2_alt (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index_2_alt),
      .i_write_data(update_tag_2_alt),
      .i_read_address(lookup_index_2_alt),
      .o_read_data(btb_tag_lookup_2_alt)
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

  // Canonical early-update state replica.  DONT_TOUCH is deliberately local
  // to these two new RMW RAMs: without it, synthesis may merge the identical
  // write state and reconstruct a single selected-PC read address.
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

  // Target RAMs (slot-1 + slot-2 read ports)
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(XLEN)
  ) btb_target_ram (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index),
      .i_write_data(i_update_target),
      .i_read_address(lookup_index),
      .o_read_data(btb_target_lookup)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(XLEN)
  ) btb_target_ram_2 (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index_2),
      .i_write_data(i_update_target),
      .i_read_address(lookup_index_2),
      .o_read_data(btb_target_lookup_2)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(XLEN)
  ) btb_target_ram_2_alt (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index_2_alt),
      .i_write_data(i_update_target),
      .i_read_address(lookup_index_2_alt),
      .o_read_data(btb_target_lookup_2_alt)
  );

  // Counter RAMs (replicated for slot-1 lookup, slot-2 lookup, update reads)
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
  ) btb_counter_ram_lookup_2 (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index_2),
      .i_write_data(next_counter),
      .i_read_address(lookup_index_2),
      .o_read_data(btb_counter_lookup_2)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(2)
  ) btb_counter_ram_lookup_2_alt (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index_2_alt),
      .i_write_data(next_counter),
      .i_read_address(lookup_index_2_alt),
      .o_read_data(btb_counter_lookup_2_alt)
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

  // Compressed flag RAM (slot-1 + slot-2 read ports)
  logic btb_compressed_lookup;
  logic btb_compressed_lookup_2;
  logic btb_compressed_lookup_2_alt;
  logic btb_requires_pc_reg_handoff_lookup;
  logic btb_requires_pc_reg_handoff_lookup_2;
  logic btb_requires_pc_reg_handoff_lookup_2_alt;
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
  ) btb_compressed_ram_2 (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index_2),
      .i_write_data(i_update_compressed),
      .i_read_address(lookup_index_2),
      .o_read_data(btb_compressed_lookup_2)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(1)
  ) btb_compressed_ram_2_alt (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index_2_alt),
      .i_write_data(i_update_compressed),
      .i_read_address(lookup_index_2_alt),
      .o_read_data(btb_compressed_lookup_2_alt)
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

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(1)
  ) btb_requires_pc_reg_handoff_ram_2 (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index_2),
      .i_write_data(i_update_requires_pc_reg_handoff),
      .i_read_address(lookup_index_2),
      .o_read_data(btb_requires_pc_reg_handoff_lookup_2)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(1)
  ) btb_requires_pc_reg_handoff_ram_2_alt (
      .i_clk,
      .i_write_enable(i_update),
      .i_write_address(update_index_2_alt),
      .i_write_data(i_update_requires_pc_reg_handoff),
      .i_read_address(lookup_index_2_alt),
      .o_read_data(btb_requires_pc_reg_handoff_lookup_2_alt)
  );

  // Combinational slot-1 lookup
  wire lookup_valid = btb_valid[lookup_index];
  wire [TagBits-1:0] lookup_tag_stored = btb_tag_lookup;
  wire [XLEN-1:0] lookup_target = btb_target_lookup;
  wire [1:0] lookup_counter = btb_counter_lookup;

  // Hit detection: valid entry with matching tag
  assign o_btb_hit = lookup_valid && (lookup_tag_stored == lookup_tag);

  // Prediction output: predict taken when counter[1] == 1 (value >= 2)
  assign o_predicted_taken = o_btb_hit && lookup_counter[1];
  assign o_predicted_target = lookup_target;
  assign o_btb_compressed = o_btb_hit && btb_compressed_lookup;
  assign o_btb_requires_pc_reg_handoff = o_btb_hit && btb_requires_pc_reg_handoff_lookup;

  // Combinational slot-2 lookup.
  wire lookup_valid_2 = btb_valid_2[lookup_index_2];
  wire [TagBits-1:0] lookup_tag_stored_2 = btb_tag_lookup_2;
  wire [XLEN-1:0] lookup_target_2 = btb_target_lookup_2;
  wire [1:0] lookup_counter_2 = btb_counter_lookup_2;
  wire lookup_valid_2_alt = btb_valid_2_alt[lookup_index_2_alt];
  wire [TagBits-1:0] lookup_tag_stored_2_alt = btb_tag_lookup_2_alt;
  wire [XLEN-1:0] lookup_target_2_alt = btb_target_lookup_2_alt;
  wire [1:0] lookup_counter_2_alt = btb_counter_lookup_2_alt;

  wire btb_hit_2 = lookup_valid_2 && (lookup_tag_stored_2 == lookup_tag_2);
  wire btb_hit_2_alt = lookup_valid_2_alt && (lookup_tag_stored_2_alt == lookup_tag_2_alt);
  wire selected_btb_hit_2 = i_pc_2_use_alt ? btb_hit_2_alt : btb_hit_2;
  assign o_predicted_taken_2_plus2 = btb_hit_2 && lookup_counter_2[1];
  assign o_predicted_taken_2_plus4 = btb_hit_2_alt && lookup_counter_2_alt[1];
  assign o_btb_compressed_2_plus2 = btb_hit_2 && btb_compressed_lookup_2;
  assign o_btb_compressed_2_plus4 = btb_hit_2_alt && btb_compressed_lookup_2_alt;
  assign o_btb_hit_2 = selected_btb_hit_2;
  assign o_predicted_taken_2 = i_pc_2_use_alt ?
      o_predicted_taken_2_plus4 : o_predicted_taken_2_plus2;
  assign o_predicted_target_2 = i_pc_2_use_alt ? lookup_target_2_alt : lookup_target_2;
  assign o_btb_compressed_2 = i_pc_2_use_alt ? o_btb_compressed_2_plus4 : o_btb_compressed_2_plus2;
  assign o_btb_requires_pc_reg_handoff_2 =
      selected_btb_hit_2 &&
      (i_pc_2_use_alt ? btb_requires_pc_reg_handoff_lookup_2_alt :
                        btb_requires_pc_reg_handoff_lookup_2);

  // Calculate the early candidate directly from the captured early PC/outcome.
  // The early canonical replica receives every actual selected write, not only
  // early writes, so it stays cycle-for-cycle equal to the late canonical RAM.
  wire early_tag_matches =
      btb_valid[early_update_index] && (btb_tag_update_early == early_update_tag);
  always_comb begin
    if (!early_tag_matches) begin
      // New entry or tag mismatch: initialize counter based on outcome
      early_next_counter = i_early_update_taken ? WeaklyTaken : WeaklyNotTaken;
    end else if (i_early_update_taken) begin
      // Taken: saturating increment (max 3)
      early_next_counter = (btb_counter_update_early == StronglyTaken) ?
          StronglyTaken : btb_counter_update_early + 2'b01;
    end else begin
      // Not taken: saturating decrement (min 0)
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
      // Clear all valid bits on reset
      for (int i = 0; i < BtbEntries; i++) begin
        btb_valid[i]       <= 1'b0;
        btb_valid_2[i]     <= 1'b0;
        btb_valid_2_alt[i] <= 1'b0;
      end
    end else if (i_update) begin
      // Update BTB entry on branch resolution
      btb_valid[update_index]             <= 1'b1;
      btb_valid_2[update_index_2]         <= 1'b1;
      btb_valid_2_alt[update_index_2_alt] <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  // Keep the externally selected slot-2 bundle bit-for-bit tied to the same
  // +2/+4 candidate as before.  Only the safety/taken qualification moves in
  // front of this selector in branch_prediction_controller.
  always_comb begin
    if (!$isunknown(
            {
              i_pc_2_use_alt,
              btb_hit_2,
              btb_hit_2_alt,
              lookup_counter_2,
              lookup_counter_2_alt,
              lookup_target_2,
              lookup_target_2_alt,
              btb_compressed_lookup_2,
              btb_compressed_lookup_2_alt,
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
              (i_pc_2_use_alt ? (btb_hit_2_alt && lookup_counter_2_alt[1]) :
                                  (btb_hit_2 && lookup_counter_2[1])));
      p_slot2_target_selector_identity :
      assert (o_predicted_target_2 == (i_pc_2_use_alt ? lookup_target_2_alt : lookup_target_2));
      p_slot2_size_selector_identity :
      assert (o_btb_compressed_2 ==
              (i_pc_2_use_alt ? (btb_hit_2_alt && btb_compressed_lookup_2_alt) :
                                  (btb_hit_2 && btb_compressed_lookup_2)));
    end
  end

  // Independent legacy state checks both the physical replica invariant and
  // the selected update's exact counter semantics.  The reference counter is
  // updated from its own saturating calculation, never from next_counter.
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
      reference_update_valid[update_index] <= 1'b1;
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

  // Independent reference models for the shifted slot-2 replicas. The normal
  // U-2 replica is direct-mapped by its predecessor key. Subtracting two moves
  // entries across the RAM-index boundary according to U[1], so its collision
  // topology intentionally differs from the canonical table and must be
  // modeled under that shifted key. The alternate U-4 mapping shifts every
  // canonical index uniformly and therefore can retain a conventional-key
  // reference that also checks exact replacement behavior.
  logic shifted_reference_valid_2[BtbEntries];
  logic [TagBits-1:0] shifted_reference_tag_2[BtbEntries];
  logic [XLEN-1:0] shifted_reference_target_2[BtbEntries];
  logic [1:0] shifted_reference_counter_2[BtbEntries];
  logic shifted_reference_compressed_2[BtbEntries];
  logic shifted_reference_handoff_2[BtbEntries];
  logic reference_valid_2_alt[BtbEntries];
  logic [TagBits-1:0] reference_tag_2_alt[BtbEntries];
  logic [XLEN-1:0] reference_target_2_alt[BtbEntries];
  logic [1:0] reference_counter_2_alt[BtbEntries];
  logic reference_compressed_2_alt[BtbEntries];
  logic reference_handoff_2_alt[BtbEntries];

  wire [XLEN-1:0] reference_pc_2_alt = i_pc_2_base + XLEN'(4);
  wire [BTB_INDEX_BITS-1:0] reference_index_2_alt = reference_pc_2_alt[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] reference_lookup_tag_2_alt = {
    reference_pc_2_alt[XLEN-1:BTB_INDEX_BITS+2], reference_pc_2_alt[1]
  };
  wire shifted_reference_hit_2 = shifted_reference_valid_2[lookup_index_2] &&
      (shifted_reference_tag_2[lookup_index_2] == lookup_tag_2);
  wire reference_hit_2_alt = reference_valid_2_alt[reference_index_2_alt] &&
      (reference_tag_2_alt[reference_index_2_alt] == reference_lookup_tag_2_alt);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int i = 0; i < BtbEntries; i++) begin
        shifted_reference_valid_2[i] <= 1'b0;
        reference_valid_2_alt[i]     <= 1'b0;
      end
    end else if (i_update) begin
      shifted_reference_valid_2[update_index_2]      <= 1'b1;
      shifted_reference_tag_2[update_index_2]        <= update_tag_2;
      shifted_reference_target_2[update_index_2]     <= i_update_target;
      shifted_reference_counter_2[update_index_2]    <= reference_selected_next_counter;
      shifted_reference_compressed_2[update_index_2] <= i_update_compressed;
      shifted_reference_handoff_2[update_index_2]    <= i_update_requires_pc_reg_handoff;
      reference_valid_2_alt[update_index]            <= 1'b1;
      reference_tag_2_alt[update_index]              <= update_tag;
      reference_target_2_alt[update_index]           <= i_update_target;
      reference_counter_2_alt[update_index]          <= reference_selected_next_counter;
      reference_compressed_2_alt[update_index]       <= i_update_compressed;
      reference_handoff_2_alt[update_index]          <= i_update_requires_pc_reg_handoff;
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst && !$isunknown(i_pc_2_base)) begin
      p_slot2_shift_hit_equivalent : assert (btb_hit_2 == shifted_reference_hit_2);
      p_slot2_alt_shift_hit_equivalent : assert (btb_hit_2_alt == reference_hit_2_alt);
      if (shifted_reference_hit_2) begin
        p_slot2_shift_target_equivalent :
        assert (lookup_target_2 == shifted_reference_target_2[lookup_index_2]);
        p_slot2_shift_counter_equivalent :
        assert (lookup_counter_2 == shifted_reference_counter_2[lookup_index_2]);
        p_slot2_shift_compressed_equivalent :
        assert (btb_compressed_lookup_2 == shifted_reference_compressed_2[lookup_index_2]);
        p_slot2_shift_handoff_equivalent :
        assert (btb_requires_pc_reg_handoff_lookup_2 ==
                shifted_reference_handoff_2[lookup_index_2]);
      end
      if (reference_hit_2_alt) begin
        p_slot2_alt_shift_target_equivalent :
        assert (lookup_target_2_alt == reference_target_2_alt[reference_index_2_alt]);
        p_slot2_alt_shift_counter_equivalent :
        assert (lookup_counter_2_alt == reference_counter_2_alt[reference_index_2_alt]);
        p_slot2_alt_shift_compressed_equivalent :
        assert (btb_compressed_lookup_2_alt == reference_compressed_2_alt[reference_index_2_alt]);
        p_slot2_alt_shift_handoff_equivalent :
        assert (btb_requires_pc_reg_handoff_lookup_2_alt ==
                reference_handoff_2_alt[reference_index_2_alt]);
      end
    end
  end
`endif

endmodule : branch_predictor
