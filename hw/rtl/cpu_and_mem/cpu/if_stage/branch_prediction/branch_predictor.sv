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
 * Branch Target Buffer (BTB) - 2-Bit Saturating Counter Predictor
 *
 * A 32-entry, 2-bit direct-mapped BTB for branch prediction.
 * Reduces the 3-cycle branch penalty for correctly predicted taken branches.
 *
 * Design:
 * =======
 *   - 32 entries indexed by PC[6:2] (5 bits)
 *   - Each entry: valid (1) + tag (26 bits) + target (32) + counter (2)
 *   - Tag includes PC[1] to distinguish halfword-aligned addresses (C extension)
 *   - 2-bit saturating counter (bimodal predictor):
 *       00 = Strongly Not-Taken, 01 = Weakly Not-Taken
 *       10 = Weakly Taken,       11 = Strongly Taken
 *   - Predict taken when counter[1] == 1 (value >= 2)
 *   - Combinational lookup for prediction
 *   - Synchronous update from EX stage
 *
 * Benefits over 1-bit predictor:
 * ==============================
 *   A 1-bit predictor mispredicts twice on loop exits: once when the loop
 *   exits (predicted taken, actually not-taken) and once on re-entry
 *   (predicted not-taken, actually taken). The 2-bit counter tolerates
 *   one "wrong" outcome without changing the prediction direction, reducing
 *   mispredictions for loops and biased branches.
 *
 * Operation:
 * ==========
 *   Prediction (IF stage):
 *     - Index BTB with current PC[6:2]
 *     - Compare tag (PC[31:7] ++ PC[1]) with stored tag
 *     - If hit && counter[1] set → predict taken, use stored target
 *     - Otherwise → predict not-taken (sequential)
 *
 *   Update (from EX stage):
 *     - When branch/jump resolves, update BTB entry
 *     - If taken: saturating increment counter (max 3)
 *     - If not-taken: saturating decrement counter (min 0)
 *     - Always update tag and target on any branch resolution
 *
 * Timing:
 * =======
 *   - Lookup is combinational (parallel with memory fetch)
 *   - Update is synchronous (posedge clock)
 *   - No read-during-write hazard: lookup uses different PC than update
 */
module branch_predictor #(
    parameter int unsigned XLEN = 32,
    parameter int unsigned BTB_INDEX_BITS = 5  // 32 entries
) (
    input logic i_clk,
    input logic i_rst,

    // Prediction interface (IF stage)
    input  logic [XLEN-1:0] i_pc,               // Current PC for lookup
    output logic            o_btb_hit,          // BTB entry hit
    output logic            o_predicted_taken,  // Predict taken
    output logic [XLEN-1:0] o_predicted_target, // Predicted target address

    // Update interface (from EX stage)
    input logic            i_update,         // Update BTB entry
    input logic [XLEN-1:0] i_update_pc,      // PC of branch instruction
    input logic [XLEN-1:0] i_update_target,  // Actual branch target
    input logic            i_update_taken    // Actual branch outcome
);

  // BTB parameters
  localparam int unsigned BtbEntries = 1 << BTB_INDEX_BITS;  // 32
  // Tag includes PC[1] to distinguish halfword-aligned addresses (important for C extension).
  // Without PC[1], addresses like 0x100 and 0x102 would alias to the same entry.
  localparam int unsigned TagBits = XLEN - BTB_INDEX_BITS - 1;  // 26 bits (includes PC[1])

  // 2-bit saturating counter states
  localparam logic [1:0] StronglyNotTaken = 2'b00;
  localparam logic [1:0] WeaklyNotTaken = 2'b01;
  localparam logic [1:0] WeaklyTaken = 2'b10;
  localparam logic [1:0] StronglyTaken = 2'b11;

  // BTB storage
  // Keep valid bits in FFs for explicit reset. Move tag/target/counter to LUTRAM.
  logic btb_valid[BtbEntries];
  logic [TagBits-1:0] btb_tag_lookup;
  logic [TagBits-1:0] btb_tag_update;
  logic [XLEN-1:0] btb_target_lookup;
  logic [1:0] btb_counter_lookup;
  logic [1:0] btb_counter_update;

  logic [1:0] next_counter;

  // Index and tag extraction for lookup
  // Index: PC[6:2] (5 bits) - selects which of 32 entries
  // Tag: PC[31:7] concatenated with PC[1] (26 bits) - distinguishes halfword addresses
  wire [BTB_INDEX_BITS-1:0] lookup_index = i_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] lookup_tag = {i_pc[XLEN-1:BTB_INDEX_BITS+2], i_pc[1]};

  // Index and tag extraction for update
  wire [BTB_INDEX_BITS-1:0] update_index = i_update_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] update_tag = {i_update_pc[XLEN-1:BTB_INDEX_BITS+2], i_update_pc[1]};

  // Tag RAMs (replicated for lookup/update reads)
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
      .i_read_address(update_index),
      .o_read_data(btb_tag_update)
  );

  // Target RAM (lookup read only)
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

  // Counter RAMs (replicated for lookup/update reads)
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
      .i_read_address(update_index),
      .o_read_data(btb_counter_update)
  );

  // Combinational lookup
  wire lookup_valid = btb_valid[lookup_index];
  wire [TagBits-1:0] lookup_tag_stored = btb_tag_lookup;
  wire [XLEN-1:0] lookup_target = btb_target_lookup;
  wire [1:0] lookup_counter = btb_counter_lookup;

  // Hit detection: valid entry with matching tag
  assign o_btb_hit = lookup_valid && (lookup_tag_stored == lookup_tag);

  // Prediction output: predict taken when counter[1] == 1 (value >= 2)
  assign o_predicted_taken = o_btb_hit && lookup_counter[1];
  assign o_predicted_target = lookup_target;

  // Current counter value for the entry being updated
  wire [1:0] current_counter = btb_counter_update;
  wire current_tag_matches = btb_valid[update_index] && (btb_tag_update == update_tag);

  // Calculate next counter value with saturation
  always_comb begin
    if (!current_tag_matches) begin
      // New entry or tag mismatch: initialize counter based on outcome
      next_counter = i_update_taken ? WeaklyTaken : WeaklyNotTaken;
    end else if (i_update_taken) begin
      // Taken: saturating increment (max 3)
      next_counter = (current_counter == StronglyTaken) ? StronglyTaken : current_counter + 2'b01;
    end else begin
      // Not taken: saturating decrement (min 0)
      next_counter = (current_counter == StronglyNotTaken) ? StronglyNotTaken :
                     current_counter - 2'b01;
    end
  end

  // Synchronous update and reset
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      // Clear all valid bits on reset
      for (int i = 0; i < BtbEntries; i++) begin
        btb_valid[i] <= 1'b0;
      end
    end else if (i_update) begin
      // Update BTB entry on branch resolution
      btb_valid[update_index] <= 1'b1;
    end
  end

endmodule : branch_predictor
