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
 * 2-way set-associative BTB with 2-bit saturating counters: 1024 entries by
 * default (512 sets x 2 ways), indexed by PC[10:2]. Tags include PC[1], so a
 * lookup at one halfword of a word never hits an entry trained for the other.
 * A hit predicts taken when counter[1] is set.
 *
 * Replacement within each set uses a 1-bit pseudo-LRU. An update hitting Way 0
 * marks Way 0 as MRU (setting PLRU to 0); a hit on Way 1 marks Way 1 as MRU
 * (setting PLRU to 1). A miss allocates into an invalid way first, or replaces
 * the LRU way.
 *
 * An entry stores the target's low 32 bits and is valid only if the branch and
 * its target share a 4-GiB region; a hit takes the upper bits from the lookup
 * PC (hw/rtl/cpu_and_mem/cpu/README.md, "4 GiB target limit").
 *
 * An entry is typed as a call, a return, or both (a coroutine swap), from the
 * commit that trained it. Return-typed hits use the RAS target when the
 * stack is nonempty. Call and return types determine the stack operation
 * when the predicted instruction is accepted.
 *
 * Slot 1 reads combinationally at the fetch PC across both ways in parallel.
 * Slot 2 reads three shifted images (+2, +4, and a +2 copy rotated by one index
 * for the next word) across both ways at the fetch PC and checks the registered
 * rows against the served pc_reg one cycle later. Updates write synchronously.
 */
module branch_predictor #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned BTB_INDEX_BITS = 9  // 512 sets * 2 ways = 1024 entries
) (
    input logic i_clk,
    input logic i_rst,

    // Slot-1 prediction interface (IF stage)
    input  logic [XLEN-1:0] i_pc,                // Current PC for lookup
    output logic            o_btb_hit,           // BTB entry hit
    output logic            o_predicted_taken,   // Predict taken
    output logic [XLEN-1:0] o_predicted_target,  // Predicted target address
    output logic            o_btb_compressed,    // Entry is for compressed instruction
    // The hit entry is typed as a call or a return (both for a coroutine swap).
    output logic            o_btb_is_call,
    output logic            o_btb_is_return,

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
    // The selected candidate's entry is typed as a call or a return.
    output logic            o_btb_is_call_2,
    output logic            o_btb_is_return_2,
    // The selected candidate's row return flag without the hit: equal to
    // o_btb_is_return_2 whenever the selected candidate hits.
    output logic            o_btb_entry_is_return_2,
    // Each candidate's target and row return flag, before i_pc_2_use_alt
    // selects o_predicted_target_2 and o_btb_entry_is_return_2 from them.
    output logic [XLEN-1:0] o_predicted_target_2_plus2,
    output logic [XLEN-1:0] o_predicted_target_2_plus4,
    output logic            o_btb_entry_is_return_2_plus2,
    output logic            o_btb_entry_is_return_2_plus4,

    // Update interface: at most one selected training write per cycle
    input logic            i_update,             // Update BTB entry
    input logic [XLEN-1:0] i_update_pc,          // PC of branch instruction
    input logic [XLEN-1:0] i_update_target,      // Actual branch target
    input logic            i_update_taken,       // Actual branch outcome
    input logic            i_update_compressed,  // Branch was compressed (16-bit)
    input logic            i_update_call,        // Branch is a call (types the entry)
    input logic            i_update_return,      // Branch is a return (types the entry)

    // Early-recovery counter RMW candidate, with an independent read for
    // timing. When active, the selected update must carry this PC and outcome.
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
  localparam int unsigned BtbSets = 1 << BTB_INDEX_BITS;
  localparam int unsigned BtbWays = 2;
  localparam int unsigned BtbEntries = BtbSets * BtbWays;
  // Tag includes PC[1] to distinguish halfword-aligned addresses under the C
  // extension. Without PC[1], 0x100 and 0x102 would alias to the same entry.
  localparam int unsigned TagBits = XLEN - BTB_INDEX_BITS - 1;  // 54 bits in RV64
  localparam int unsigned TargetBits = riscv_pkg::PhysAddrBits;
  // Yosys 0.64 cannot parse $bits on this module-local typedef in a parameter
  // override. The simulation check below pins the spelled width to the struct.
  localparam int unsigned Slot2PayloadBits = TargetBits + 4;

  // A target's bit 0 is always 0 (instructions are halfword aligned, and a
  // JALR target has bit 0 cleared), so the payload keeps bits [TargetBits-1:1].
  // That leaves room for the call and return types in one RAMB18 (36 bits).
  typedef struct packed {
    logic [TargetBits-2:0] target_hi;   // target bits [TargetBits-1:1]
    logic [1:0]            counter;
    logic                  compressed;
    logic                  is_call;
    logic                  is_return;
  } slot2_payload_t;

  // 2-bit saturating counter states
  localparam logic [1:0] StronglyNotTaken = 2'b00;
  localparam logic [1:0] WeaklyNotTaken = 2'b01;
  localparam logic [1:0] WeaklyTaken = 2'b10;
  localparam logic [1:0] StronglyTaken = 2'b11;

  // BTB storage
  // Keep valid bits and 1-bit pseudo-LRU per set in FFs so reset can clear them.
  // btb_plru: 0 = Way 0 is MRU (Way 1 is LRU victim); 1 = Way 1 is MRU (Way 0 is LRU victim).
  logic btb_valid_w0[BtbSets];
  logic btb_valid_w1[BtbSets];
  logic btb_plru[BtbSets];

  // Slot-2 valid bits (Way 0 and Way 1)
  logic btb_valid_2_w0[BtbSets], btb_valid_2_w1[BtbSets];
  logic btb_valid_2_alt_w0[BtbSets], btb_valid_2_alt_w1[BtbSets];
  logic btb_valid_2_rot_w0[BtbSets], btb_valid_2_rot_w1[BtbSets];

  logic [TagBits-1:0] btb_tag_lookup_w0, btb_tag_lookup_w1;
  logic [TagBits-1:0] btb_tag_update_late_w0, btb_tag_update_late_w1;
  logic [TagBits-1:0] btb_tag_update_early_w0, btb_tag_update_early_w1;
  logic [TargetBits-1:0] btb_target_lookup_w0, btb_target_lookup_w1;
  logic [1:0] btb_counter_lookup_w0, btb_counter_lookup_w1;
  logic [1:0] btb_counter_update_late_w0, btb_counter_update_late_w1;
  logic [1:0] btb_counter_update_early_w0, btb_counter_update_early_w1;
  logic btb_compressed_lookup_w0, btb_compressed_lookup_w1;
  logic [1:0] btb_kind_lookup_w0, btb_kind_lookup_w1;

  // Slot-2 RAM signals
  logic [TagBits-1:0] slot2_tag_2_async_w0, slot2_tag_2_async_w1;
  logic [TagBits-1:0] slot2_tag_2_alt_async_w0, slot2_tag_2_alt_async_w1;
  logic [TagBits-1:0] slot2_tag_2_rot_async_w0, slot2_tag_2_rot_async_w1;
  logic [TagBits-1:0] slot2_tag_2_raw_w0, slot2_tag_2_raw_w1;
  logic [TagBits-1:0] slot2_tag_2_alt_raw_w0, slot2_tag_2_alt_raw_w1;
  logic [TagBits-1:0] slot2_tag_2_rot_raw_w0, slot2_tag_2_rot_raw_w1;
  logic [TagBits-1:0] slot2_tag_2_w0, slot2_tag_2_w1;
  logic [TagBits-1:0] slot2_tag_2_alt_w0, slot2_tag_2_alt_w1;
  logic [TagBits-1:0] slot2_tag_2_rot_w0, slot2_tag_2_rot_w1;
  logic [TagBits-1:0] slot2_tag_2_forward_q, slot2_tag_2_alt_forward_q;
  slot2_payload_t slot2_payload_2_raw_w0, slot2_payload_2_raw_w1;
  slot2_payload_t slot2_payload_2_alt_raw_w0, slot2_payload_2_alt_raw_w1;
  slot2_payload_t slot2_payload_2_rot_raw_w0, slot2_payload_2_rot_raw_w1;
  slot2_payload_t slot2_payload_2_w0, slot2_payload_2_w1;
  slot2_payload_t slot2_payload_2_alt_w0, slot2_payload_2_alt_w1;
  slot2_payload_t slot2_payload_2_rot_w0, slot2_payload_2_rot_w1;
  slot2_payload_t slot2_payload_forward_q;
  logic slot2_forward_2_w0_q, slot2_forward_2_w1_q;
  logic slot2_forward_2_alt_w0_q, slot2_forward_2_alt_w1_q;
  logic slot2_forward_2_rot_w0_q, slot2_forward_2_rot_w1_q;
  logic slot2_valid_2_w0_q, slot2_valid_2_w1_q;
  logic slot2_valid_2_alt_w0_q, slot2_valid_2_alt_w1_q;
  logic slot2_valid_2_rot_w0_q, slot2_valid_2_rot_w1_q;
  logic slot2_stage_ready_q;
  logic [BTB_INDEX_BITS-1:0] slot2_lookup_index_q;
  logic [BTB_INDEX_BITS-1:0] slot2_lookup_index_next_q;

  logic selected_way;
  logic [1:0] next_counter;
  logic early_target_way;
  logic [1:0] early_next_counter;
  (* keep = "true" *) logic late_target_way;
  (* keep = "true" *) logic [1:0] late_next_counter;

  // Slot-1 lookup index and tag
  wire [BTB_INDEX_BITS-1:0] lookup_index = i_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] lookup_tag = {i_pc[XLEN-1:BTB_INDEX_BITS+2], i_pc[1]};

  // Slot-2 read index. The live fetch PC normally leads the served pc_reg by
  // one cycle; when a slow response collapses that lead, the live PC is the
  // served address itself. All images read this one word index. The rotated +2
  // image applies its rotation on the write side, so no read address needs an
  // A+1 adder.
  wire [BTB_INDEX_BITS-1:0] slot2_lookup_index = i_pc_2_lookup_base[BTB_INDEX_BITS+1:2];
  wire [BTB_INDEX_BITS-1:0] slot2_lookup_index_next = slot2_lookup_index + BTB_INDEX_BITS'(1);
  wire [BTB_INDEX_BITS-1:0] lookup_index_2 = i_pc_2_base[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] lookup_tag_2 = {i_pc_2_base[XLEN-1:BTB_INDEX_BITS+2], i_pc_2_base[1]};
  wire [BTB_INDEX_BITS-1:0] lookup_index_2_alt = lookup_index_2;
  wire [TagBits-1:0] lookup_tag_2_alt = lookup_tag_2;

  // Two-stage update. Stage 1 (this cycle) reads the update-side copies,
  // compares tags and picks the way and next counter from the early or late
  // candidate. Stage 2 (next cycle) writes every RAM and valid/PLRU bit from
  // the registered bundle below, so the way select no longer fans out to the
  // write enables of the lookup copies in the same cycle. The whole update
  // becomes visible to lookups one cycle later, as one unit. Stage 1 forwards
  // the bundle still in flight, so back-to-back updates to one set read the
  // state the earlier update writes.
  logic p_update;
  logic p_way;
  logic [1:0] p_counter;
  logic [XLEN-1:0] p_update_pc;
  logic [XLEN-1:0] p_update_target;
  logic p_update_compressed;
  logic p_update_call;
  logic p_update_return;

  always_ff @(posedge i_clk) begin
    if (i_rst) p_update <= 1'b0;
    else p_update <= i_update;
    p_way               <= selected_way;
    p_counter           <= next_counter;
    p_update_pc         <= i_update_pc;
    p_update_target     <= i_update_target;
    p_update_compressed <= i_update_compressed;
    p_update_call       <= i_update_call;
    p_update_return     <= i_update_return;
  end

  // Index and tag extraction for update
  wire [BTB_INDEX_BITS-1:0] update_index = p_update_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] update_tag = {p_update_pc[XLEN-1:BTB_INDEX_BITS+2], p_update_pc[1]};

  wire [BTB_INDEX_BITS-1:0] early_update_index = i_early_update_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] early_update_tag = {
    i_early_update_pc[XLEN-1:BTB_INDEX_BITS+2], i_early_update_pc[1]
  };

  wire [BTB_INDEX_BITS-1:0] late_update_index = i_late_update_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] late_update_tag = {
    i_late_update_pc[XLEN-1:BTB_INDEX_BITS+2], i_late_update_pc[1]
  };

  // Slot-2 images store each update under branch PC minus 2 (T2) or 4 (T4).
  wire [XLEN-1:0] update_pc_2_key = p_update_pc - XLEN'(2);
  wire [BTB_INDEX_BITS-1:0] update_index_2 = update_pc_2_key[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] update_tag_2 = {update_pc_2_key[XLEN-1:BTB_INDEX_BITS+2], update_pc_2_key[1]};
  wire [XLEN-1:0] update_pc_2_alt_key = p_update_pc - XLEN'(4);
  wire [BTB_INDEX_BITS-1:0] update_index_2_alt = update_pc_2_alt_key[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] update_tag_2_alt = {
    update_pc_2_alt_key[XLEN-1:BTB_INDEX_BITS+2], update_pc_2_alt_key[1]
  };
  // RT2 writes each T2 row one index lower. The shift is a bijection, so
  // RT2[i-1] always equals T2[i].
  wire [BTB_INDEX_BITS-1:0] update_index_2_rot = update_index_2 - BTB_INDEX_BITS'(1);

  // Write enables for Way 0 and Way 1
  wire update_we_w0 = p_update && (p_way == 1'b0);
  wire update_we_w1 = p_update && (p_way == 1'b1);

  // =========================================================================
  // Tag RAM copies (Way 0 and Way 1)
  // =========================================================================
  // Way 0
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_lookup_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_write_address(update_index),
      .i_write_data(update_tag),
      .i_read_address(lookup_index),
      .o_read_data(btb_tag_lookup_w0)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_update_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_write_address(update_index),
      .i_write_data(update_tag),
      .i_read_address(late_update_index),
      .o_read_data(btb_tag_update_late_w0)
  );

  (* dont_touch = "yes" *)
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_early_update_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_write_address(update_index),
      .i_write_data(update_tag),
      .i_read_address(early_update_index),
      .o_read_data(btb_tag_update_early_w0)
  );

  // Way 1
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_lookup_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_write_address(update_index),
      .i_write_data(update_tag),
      .i_read_address(lookup_index),
      .o_read_data(btb_tag_lookup_w1)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_update_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_write_address(update_index),
      .i_write_data(update_tag),
      .i_read_address(late_update_index),
      .o_read_data(btb_tag_update_late_w1)
  );

  (* dont_touch = "yes" *)
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_early_update_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_write_address(update_index),
      .i_write_data(update_tag),
      .i_read_address(early_update_index),
      .o_read_data(btb_tag_update_early_w1)
  );

  // Store low 32-bit targets and restore upper bits from the lookup PC.
  wire update_target_region_predictable =
      p_update_target[XLEN-1:TargetBits] == p_update_pc[XLEN-1:TargetBits];
  wire [TargetBits-1:0] update_target_stored = p_update_target[TargetBits-1:0];

  wire update_slot2_plus2_key_same_region = p_update_pc[TargetBits-1:0] >= TargetBits'(2);
  wire update_slot2_plus4_key_same_region = p_update_pc[TargetBits-1:0] >= TargetBits'(4);
  wire update_slot2_plus2_target_valid =
      update_target_region_predictable && update_slot2_plus2_key_same_region;
  wire update_slot2_plus4_target_valid =
      update_target_region_predictable && update_slot2_plus4_key_same_region;

  // Slot-2 payload
  slot2_payload_t slot2_payload_write;
  assign slot2_payload_write = {
    update_target_stored[TargetBits-1:1],
    p_counter,
    p_update_compressed,
    p_update_call,
    p_update_return
  };

  // =========================================================================
  // Slot-2 Tag and Payload RAMs (Way 0 and Way 1)
  // =========================================================================
  // Way 0
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_lookup_2_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_write_address(update_index_2),
      .i_write_data(update_tag_2),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_tag_2_async_w0)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_lookup_2_alt_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_write_address(update_index_2_alt),
      .i_write_data(update_tag_2_alt),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_tag_2_alt_async_w0)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_lookup_2_rot_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_write_address(update_index_2_rot),
      .i_write_data(update_tag_2),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_tag_2_rot_async_w0)
  );

  sdp_block_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(Slot2PayloadBits)
  ) btb_payload_ram_lookup_2_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_bulk_clear(1'b0),
      .i_write_address(update_index_2),
      .i_write_data(slot2_payload_write),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_payload_2_raw_w0)
  );

  sdp_block_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(Slot2PayloadBits)
  ) btb_payload_ram_lookup_2_alt_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_bulk_clear(1'b0),
      .i_write_address(update_index_2_alt),
      .i_write_data(slot2_payload_write),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_payload_2_alt_raw_w0)
  );

  sdp_block_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(Slot2PayloadBits)
  ) btb_payload_ram_lookup_2_rot_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_bulk_clear(1'b0),
      .i_write_address(update_index_2_rot),
      .i_write_data(slot2_payload_write),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_payload_2_rot_raw_w0)
  );

  // Way 1
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_lookup_2_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_write_address(update_index_2),
      .i_write_data(update_tag_2),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_tag_2_async_w1)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_lookup_2_alt_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_write_address(update_index_2_alt),
      .i_write_data(update_tag_2_alt),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_tag_2_alt_async_w1)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TagBits)
  ) btb_tag_ram_lookup_2_rot_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_write_address(update_index_2_rot),
      .i_write_data(update_tag_2),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_tag_2_rot_async_w1)
  );

  sdp_block_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(Slot2PayloadBits)
  ) btb_payload_ram_lookup_2_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_bulk_clear(1'b0),
      .i_write_address(update_index_2),
      .i_write_data(slot2_payload_write),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_payload_2_raw_w1)
  );

  sdp_block_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(Slot2PayloadBits)
  ) btb_payload_ram_lookup_2_alt_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_bulk_clear(1'b0),
      .i_write_address(update_index_2_alt),
      .i_write_data(slot2_payload_write),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_payload_2_alt_raw_w1)
  );

  sdp_block_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(Slot2PayloadBits)
  ) btb_payload_ram_lookup_2_rot_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_bulk_clear(1'b0),
      .i_write_address(update_index_2_rot),
      .i_write_data(slot2_payload_write),
      .i_read_address(slot2_lookup_index),
      .o_read_data(slot2_payload_2_rot_raw_w1)
  );

  // =========================================================================
  // Target, Counter, Compressed, Kind RAMs for Slot 1 (Way 0 and Way 1)
  // =========================================================================
  // Target RAM
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TargetBits)
  ) btb_target_ram_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_write_address(update_index),
      .i_write_data(update_target_stored),
      .i_read_address(lookup_index),
      .o_read_data(btb_target_lookup_w0)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(TargetBits)
  ) btb_target_ram_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_write_address(update_index),
      .i_write_data(update_target_stored),
      .i_read_address(lookup_index),
      .o_read_data(btb_target_lookup_w1)
  );

  // Counter RAMs
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(2)
  ) btb_counter_ram_lookup_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_write_address(update_index),
      .i_write_data(p_counter),
      .i_read_address(lookup_index),
      .o_read_data(btb_counter_lookup_w0)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(2)
  ) btb_counter_ram_lookup_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_write_address(update_index),
      .i_write_data(p_counter),
      .i_read_address(lookup_index),
      .o_read_data(btb_counter_lookup_w1)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(2)
  ) btb_counter_ram_update_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_write_address(update_index),
      .i_write_data(p_counter),
      .i_read_address(late_update_index),
      .o_read_data(btb_counter_update_late_w0)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(2)
  ) btb_counter_ram_update_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_write_address(update_index),
      .i_write_data(p_counter),
      .i_read_address(late_update_index),
      .o_read_data(btb_counter_update_late_w1)
  );

  (* dont_touch = "yes" *)
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(2)
  ) btb_counter_ram_early_update_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_write_address(update_index),
      .i_write_data(p_counter),
      .i_read_address(early_update_index),
      .o_read_data(btb_counter_update_early_w0)
  );

  (* dont_touch = "yes" *)
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(2)
  ) btb_counter_ram_early_update_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_write_address(update_index),
      .i_write_data(p_counter),
      .i_read_address(early_update_index),
      .o_read_data(btb_counter_update_early_w1)
  );

  // Compressed RAM
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(1)
  ) btb_compressed_ram_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_write_address(update_index),
      .i_write_data(p_update_compressed),
      .i_read_address(lookup_index),
      .o_read_data(btb_compressed_lookup_w0)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(1)
  ) btb_compressed_ram_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_write_address(update_index),
      .i_write_data(p_update_compressed),
      .i_read_address(lookup_index),
      .o_read_data(btb_compressed_lookup_w1)
  );

  // Kind (Call/Return) RAM
  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(2)
  ) btb_kind_ram_w0 (
      .i_clk,
      .i_write_enable(update_we_w0),
      .i_write_address(update_index),
      .i_write_data({p_update_call, p_update_return}),
      .i_read_address(lookup_index),
      .o_read_data(btb_kind_lookup_w0)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(BTB_INDEX_BITS),
      .DATA_WIDTH(2)
  ) btb_kind_ram_w1 (
      .i_clk,
      .i_write_enable(update_we_w1),
      .i_write_address(update_index),
      .i_write_data({p_update_call, p_update_return}),
      .i_read_address(lookup_index),
      .o_read_data(btb_kind_lookup_w1)
  );

  // =========================================================================
  // Combinational Slot-1 Lookup (Way 0 and Way 1 in parallel)
  // =========================================================================
  localparam int unsigned TagCompareChunkBits = 14;
  localparam int unsigned TagCompareChunks =
      (TagBits + TagCompareChunkBits - 1) / TagCompareChunkBits;

  (* keep = "true" *)logic [TagCompareChunks-1:0] lookup_tag_equal_chunks_w0;
  (* keep = "true" *)logic [TagCompareChunks-1:0] lookup_tag_equal_chunks_w1;
  for (genvar chunk = 0; chunk < TagCompareChunks; chunk++) begin : gen_lookup_tag_compare
    localparam int unsigned FirstBit = chunk * TagCompareChunkBits;
    localparam int unsigned ChunkWidth =
        (TagBits - FirstBit < TagCompareChunkBits) ? TagBits - FirstBit : TagCompareChunkBits;
    assign lookup_tag_equal_chunks_w0[chunk] =
        btb_tag_lookup_w0[FirstBit+:ChunkWidth] == lookup_tag[FirstBit+:ChunkWidth];
    assign lookup_tag_equal_chunks_w1[chunk] =
        btb_tag_lookup_w1[FirstBit+:ChunkWidth] == lookup_tag[FirstBit+:ChunkWidth];
  end

  wire way0_hit = btb_valid_w0[lookup_index] && (&lookup_tag_equal_chunks_w0);
  wire way1_hit = btb_valid_w1[lookup_index] && (&lookup_tag_equal_chunks_w1);

  assign o_btb_hit = way0_hit || way1_hit;

`ifdef BTB_TAG_COMPARE_LOCAL_PROOF
  always_comb begin
    p_lookup_tag_comparison_exact_w0 :
    assert ((&lookup_tag_equal_chunks_w0) == (btb_tag_lookup_w0 == lookup_tag));
    p_lookup_tag_comparison_exact_w1 :
    assert ((&lookup_tag_equal_chunks_w1) == (btb_tag_lookup_w1 == lookup_tag));
  end
`endif

  wire [TargetBits-1:0] hit_target_stored = way1_hit ? btb_target_lookup_w1 : btb_target_lookup_w0;
  wire [1:0] hit_counter = way1_hit ? btb_counter_lookup_w1 : btb_counter_lookup_w0;
  wire hit_compressed = way1_hit ? btb_compressed_lookup_w1 : btb_compressed_lookup_w0;
  wire [1:0] hit_kind = way1_hit ? btb_kind_lookup_w1 : btb_kind_lookup_w0;

  assign o_predicted_taken  = o_btb_hit && hit_counter[1];
  assign o_predicted_target = {i_pc[XLEN-1:TargetBits], hit_target_stored};
  assign o_btb_compressed   = o_btb_hit && hit_compressed;
  assign o_btb_is_call      = o_btb_hit && hit_kind[1];
  assign o_btb_is_return    = o_btb_hit && hit_kind[0];

  // =========================================================================
  // Slot-2 Registered Lookahead & Forwarding (Way 0 and Way 1)
  // =========================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      slot2_tag_2_raw_w0        <= '0;
      slot2_tag_2_raw_w1        <= '0;
      slot2_tag_2_alt_raw_w0    <= '0;
      slot2_tag_2_alt_raw_w1    <= '0;
      slot2_tag_2_rot_raw_w0    <= '0;
      slot2_tag_2_rot_raw_w1    <= '0;
      slot2_lookup_index_q      <= '0;
      slot2_lookup_index_next_q <= '0;
      slot2_forward_2_w0_q      <= 1'b0;
      slot2_forward_2_w1_q      <= 1'b0;
      slot2_forward_2_alt_w0_q  <= 1'b0;
      slot2_forward_2_alt_w1_q  <= 1'b0;
      slot2_forward_2_rot_w0_q  <= 1'b0;
      slot2_forward_2_rot_w1_q  <= 1'b0;
      slot2_valid_2_w0_q        <= 1'b0;
      slot2_valid_2_w1_q        <= 1'b0;
      slot2_valid_2_alt_w0_q    <= 1'b0;
      slot2_valid_2_alt_w1_q    <= 1'b0;
      slot2_valid_2_rot_w0_q    <= 1'b0;
      slot2_valid_2_rot_w1_q    <= 1'b0;
      slot2_stage_ready_q       <= 1'b0;
    end else begin
      slot2_tag_2_raw_w0 <= slot2_tag_2_async_w0;
      slot2_tag_2_raw_w1 <= slot2_tag_2_async_w1;
      slot2_tag_2_alt_raw_w0 <= slot2_tag_2_alt_async_w0;
      slot2_tag_2_alt_raw_w1 <= slot2_tag_2_alt_async_w1;
      slot2_tag_2_rot_raw_w0 <= slot2_tag_2_rot_async_w0;
      slot2_tag_2_rot_raw_w1 <= slot2_tag_2_rot_async_w1;
      slot2_lookup_index_q <= slot2_lookup_index;
      slot2_lookup_index_next_q <= slot2_lookup_index_next;
      slot2_stage_ready_q <= 1'b1;

      slot2_forward_2_w0_q <= p_update && (p_way == 1'b0) && (update_index_2 == slot2_lookup_index);
      slot2_forward_2_w1_q <= p_update && (p_way == 1'b1) && (update_index_2 == slot2_lookup_index);
      slot2_forward_2_alt_w0_q <=
          p_update && (p_way == 1'b0) && (update_index_2_alt == slot2_lookup_index);
      slot2_forward_2_alt_w1_q <=
          p_update && (p_way == 1'b1) && (update_index_2_alt == slot2_lookup_index);
      slot2_forward_2_rot_w0_q <=
          p_update && (p_way == 1'b0) && (update_index_2_rot == slot2_lookup_index);
      slot2_forward_2_rot_w1_q <=
          p_update && (p_way == 1'b1) && (update_index_2_rot == slot2_lookup_index);

      if (p_update) begin
        slot2_tag_2_forward_q     <= update_tag_2;
        slot2_tag_2_alt_forward_q <= update_tag_2_alt;
        slot2_payload_forward_q   <= slot2_payload_write;
      end

      slot2_valid_2_w0_q <=
          (p_update && (p_way == 1'b0) && (update_index_2 == slot2_lookup_index)) ?
          update_slot2_plus2_target_valid : btb_valid_2_w0[slot2_lookup_index];
      slot2_valid_2_w1_q <=
          (p_update && (p_way == 1'b1) && (update_index_2 == slot2_lookup_index)) ?
          update_slot2_plus2_target_valid : btb_valid_2_w1[slot2_lookup_index];

      slot2_valid_2_alt_w0_q <=
          (p_update && (p_way == 1'b0) && (update_index_2_alt == slot2_lookup_index)) ?
          update_slot2_plus4_target_valid : btb_valid_2_alt_w0[slot2_lookup_index];
      slot2_valid_2_alt_w1_q <=
          (p_update && (p_way == 1'b1) && (update_index_2_alt == slot2_lookup_index)) ?
          update_slot2_plus4_target_valid : btb_valid_2_alt_w1[slot2_lookup_index];

      slot2_valid_2_rot_w0_q <=
          (p_update && (p_way == 1'b0) && (update_index_2_rot == slot2_lookup_index)) ?
          update_slot2_plus2_target_valid : btb_valid_2_rot_w0[slot2_lookup_index];
      slot2_valid_2_rot_w1_q <=
          (p_update && (p_way == 1'b1) && (update_index_2_rot == slot2_lookup_index)) ?
          update_slot2_plus2_target_valid : btb_valid_2_rot_w1[slot2_lookup_index];
    end
  end

  assign slot2_tag_2_w0 = slot2_forward_2_w0_q ? slot2_tag_2_forward_q : slot2_tag_2_raw_w0;
  assign slot2_tag_2_w1 = slot2_forward_2_w1_q ? slot2_tag_2_forward_q : slot2_tag_2_raw_w1;

  assign slot2_tag_2_alt_w0 =
      slot2_forward_2_alt_w0_q ? slot2_tag_2_alt_forward_q : slot2_tag_2_alt_raw_w0;
  assign slot2_tag_2_alt_w1 =
      slot2_forward_2_alt_w1_q ? slot2_tag_2_alt_forward_q : slot2_tag_2_alt_raw_w1;

  assign slot2_tag_2_rot_w0 =
      slot2_forward_2_rot_w0_q ? slot2_tag_2_forward_q : slot2_tag_2_rot_raw_w0;
  assign slot2_tag_2_rot_w1 =
      slot2_forward_2_rot_w1_q ? slot2_tag_2_forward_q : slot2_tag_2_rot_raw_w1;

  assign slot2_payload_2_w0 =
      slot2_forward_2_w0_q ? slot2_payload_forward_q : slot2_payload_2_raw_w0;
  assign slot2_payload_2_w1 =
      slot2_forward_2_w1_q ? slot2_payload_forward_q : slot2_payload_2_raw_w1;

  assign slot2_payload_2_alt_w0 =
      slot2_forward_2_alt_w0_q ? slot2_payload_forward_q : slot2_payload_2_alt_raw_w0;
  assign slot2_payload_2_alt_w1 =
      slot2_forward_2_alt_w1_q ? slot2_payload_forward_q : slot2_payload_2_alt_raw_w1;

  assign slot2_payload_2_rot_w0 =
      slot2_forward_2_rot_w0_q ? slot2_payload_forward_q : slot2_payload_2_rot_raw_w0;
  assign slot2_payload_2_rot_w1 =
      slot2_forward_2_rot_w1_q ? slot2_payload_forward_q : slot2_payload_2_rot_raw_w1;

  // Compare Slot-2 tags for Way 0 and Way 1
  (* keep = "true" *) logic [7:0][TagCompareChunks-1:0] slot2_tag_equal_chunks;
  for (genvar chunk = 0; chunk < TagCompareChunks; chunk++) begin : gen_slot2_tag_compare
    localparam int unsigned FirstBit = chunk * TagCompareChunkBits;
    localparam int unsigned Bits =
        (TagBits - FirstBit < TagCompareChunkBits) ? TagBits - FirstBit : TagCompareChunkBits;
    assign slot2_tag_equal_chunks[0][chunk] =
        slot2_tag_2_raw_w0[FirstBit+:Bits] == lookup_tag_2[FirstBit+:Bits];
    assign slot2_tag_equal_chunks[1][chunk] =
        slot2_tag_2_raw_w1[FirstBit+:Bits] == lookup_tag_2[FirstBit+:Bits];
    assign slot2_tag_equal_chunks[2][chunk] =
        slot2_tag_2_alt_raw_w0[FirstBit+:Bits] == lookup_tag_2[FirstBit+:Bits];
    assign slot2_tag_equal_chunks[3][chunk] =
        slot2_tag_2_alt_raw_w1[FirstBit+:Bits] == lookup_tag_2[FirstBit+:Bits];
    assign slot2_tag_equal_chunks[4][chunk] =
        slot2_tag_2_rot_raw_w0[FirstBit+:Bits] == lookup_tag_2[FirstBit+:Bits];
    assign slot2_tag_equal_chunks[5][chunk] =
        slot2_tag_2_rot_raw_w1[FirstBit+:Bits] == lookup_tag_2[FirstBit+:Bits];
    assign slot2_tag_equal_chunks[6][chunk] =
        slot2_tag_2_forward_q[FirstBit+:Bits] == lookup_tag_2[FirstBit+:Bits];
    assign slot2_tag_equal_chunks[7][chunk] =
        slot2_tag_2_alt_forward_q[FirstBit+:Bits] == lookup_tag_2[FirstBit+:Bits];
  end

  wire slot2_tag_2_raw_w0_matches = &slot2_tag_equal_chunks[0];
  wire slot2_tag_2_raw_w1_matches = &slot2_tag_equal_chunks[1];
  wire slot2_tag_2_alt_raw_w0_matches = &slot2_tag_equal_chunks[2];
  wire slot2_tag_2_alt_raw_w1_matches = &slot2_tag_equal_chunks[3];
  wire slot2_tag_2_rot_raw_w0_matches = &slot2_tag_equal_chunks[4];
  wire slot2_tag_2_rot_raw_w1_matches = &slot2_tag_equal_chunks[5];
  wire slot2_tag_2_forward_matches = &slot2_tag_equal_chunks[6];
  wire slot2_tag_2_alt_forward_matches = &slot2_tag_equal_chunks[7];

  wire slot2_hit_2_base_w0 = slot2_valid_2_w0_q &&
      (slot2_forward_2_w0_q ? slot2_tag_2_forward_matches : slot2_tag_2_raw_w0_matches);
  wire slot2_hit_2_base_w1 = slot2_valid_2_w1_q &&
      (slot2_forward_2_w1_q ? slot2_tag_2_forward_matches : slot2_tag_2_raw_w1_matches);
  wire slot2_hit_2_base = slot2_hit_2_base_w0 || slot2_hit_2_base_w1;

  wire slot2_hit_2_rot_w0 = slot2_valid_2_rot_w0_q &&
      (slot2_forward_2_rot_w0_q ? slot2_tag_2_forward_matches : slot2_tag_2_rot_raw_w0_matches);
  wire slot2_hit_2_rot_w1 = slot2_valid_2_rot_w1_q &&
      (slot2_forward_2_rot_w1_q ? slot2_tag_2_forward_matches : slot2_tag_2_rot_raw_w1_matches);
  wire slot2_hit_2_rot = slot2_hit_2_rot_w0 || slot2_hit_2_rot_w1;

  wire slot2_hit_2_alt_w0 = slot2_valid_2_alt_w0_q &&
      (slot2_forward_2_alt_w0_q ? slot2_tag_2_alt_forward_matches : slot2_tag_2_alt_raw_w0_matches);
  wire slot2_hit_2_alt_w1 = slot2_valid_2_alt_w1_q &&
      (slot2_forward_2_alt_w1_q ? slot2_tag_2_alt_forward_matches : slot2_tag_2_alt_raw_w1_matches);
  wire slot2_hit_2_alt = slot2_hit_2_alt_w0 || slot2_hit_2_alt_w1;

  slot2_payload_t slot2_payload_2;
  slot2_payload_t slot2_payload_2_rot;
  slot2_payload_t slot2_payload_2_alt;

  assign slot2_payload_2 = slot2_hit_2_base_w1 ? slot2_payload_2_w1 : slot2_payload_2_w0;
  assign slot2_payload_2_rot = slot2_hit_2_rot_w1 ? slot2_payload_2_rot_w1 : slot2_payload_2_rot_w0;
  assign slot2_payload_2_alt = slot2_hit_2_alt_w1 ? slot2_payload_2_alt_w1 : slot2_payload_2_alt_w0;

  slot2_payload_t lookup_payload_2, lookup_payload_2_alt;
  logic slot2_stage_base_index_covered;
  logic slot2_stage_next_index_covered;

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

  assign o_predicted_target_2 = {
    i_pc_2_base[XLEN-1:TargetBits],
    i_pc_2_use_alt ? lookup_payload_2_alt.target_hi : lookup_payload_2.target_hi,
    1'b0
  };
  assign o_btb_compressed_2 = i_pc_2_use_alt ? o_btb_compressed_2_plus4 : o_btb_compressed_2_plus2;
  assign o_btb_is_call_2 = i_pc_2_use_alt ? (btb_hit_2_alt && lookup_payload_2_alt.is_call) :
                                            (btb_hit_2 && lookup_payload_2.is_call);
  assign o_btb_is_return_2 = i_pc_2_use_alt ?
      (btb_hit_2_alt && lookup_payload_2_alt.is_return) : (btb_hit_2 && lookup_payload_2.is_return);
  assign o_btb_entry_is_return_2 =
      i_pc_2_use_alt ? lookup_payload_2_alt.is_return : lookup_payload_2.is_return;
  assign o_predicted_target_2_plus2 = {
    i_pc_2_base[XLEN-1:TargetBits], lookup_payload_2.target_hi, 1'b0
  };
  assign o_predicted_target_2_plus4 = {
    i_pc_2_base[XLEN-1:TargetBits], lookup_payload_2_alt.target_hi, 1'b0
  };
  assign o_btb_entry_is_return_2_plus2 = lookup_payload_2.is_return;
  assign o_btb_entry_is_return_2_plus4 = lookup_payload_2_alt.is_return;

  // =========================================================================
  // Early and Late Counter Update Candidates & Way Selection
  // =========================================================================
  (* keep = "true" *) logic [3:0][TagCompareChunks-1:0] update_tag_equal_chunks;
  // Stage-1 view of the update-side state: the registered bundle overrides the
  // RAM copies and valid/PLRU flops for the one set it is writing.
  wire early_fwd = p_update && (update_index == early_update_index);
  wire late_fwd = p_update && (update_index == late_update_index);
  wire early_fwd_w0 = early_fwd && (p_way == 1'b0);
  wire early_fwd_w1 = early_fwd && (p_way == 1'b1);
  wire late_fwd_w0 = late_fwd && (p_way == 1'b0);
  wire late_fwd_w1 = late_fwd && (p_way == 1'b1);

  wire [TagBits-1:0] fwd_tag_early_w0 = early_fwd_w0 ? update_tag : btb_tag_update_early_w0;
  wire [TagBits-1:0] fwd_tag_early_w1 = early_fwd_w1 ? update_tag : btb_tag_update_early_w1;
  wire [TagBits-1:0] fwd_tag_late_w0 = late_fwd_w0 ? update_tag : btb_tag_update_late_w0;
  wire [TagBits-1:0] fwd_tag_late_w1 = late_fwd_w1 ? update_tag : btb_tag_update_late_w1;
  wire [1:0] fwd_counter_early_w0 = early_fwd_w0 ? p_counter : btb_counter_update_early_w0;
  wire [1:0] fwd_counter_early_w1 = early_fwd_w1 ? p_counter : btb_counter_update_early_w1;
  wire [1:0] fwd_counter_late_w0 = late_fwd_w0 ? p_counter : btb_counter_update_late_w0;
  wire [1:0] fwd_counter_late_w1 = late_fwd_w1 ? p_counter : btb_counter_update_late_w1;
  wire early_valid_w0 =
      early_fwd_w0 ? update_target_region_predictable : btb_valid_w0[early_update_index];
  wire early_valid_w1 =
      early_fwd_w1 ? update_target_region_predictable : btb_valid_w1[early_update_index];
  wire late_valid_w0 =
      late_fwd_w0 ? update_target_region_predictable : btb_valid_w0[late_update_index];
  wire late_valid_w1 =
      late_fwd_w1 ? update_target_region_predictable : btb_valid_w1[late_update_index];
  wire early_plru = early_fwd ? p_way : btb_plru[early_update_index];
  wire late_plru = late_fwd ? p_way : btb_plru[late_update_index];

  for (genvar chunk = 0; chunk < TagCompareChunks; chunk++) begin : gen_update_tag_compare
    localparam int unsigned FirstBit = chunk * TagCompareChunkBits;
    localparam int unsigned Bits =
        (TagBits - FirstBit < TagCompareChunkBits) ? TagBits - FirstBit : TagCompareChunkBits;
    assign update_tag_equal_chunks[0][chunk] =
        fwd_tag_early_w0[FirstBit+:Bits] == early_update_tag[FirstBit+:Bits];
    assign update_tag_equal_chunks[1][chunk] =
        fwd_tag_early_w1[FirstBit+:Bits] == early_update_tag[FirstBit+:Bits];
    assign update_tag_equal_chunks[2][chunk] =
        fwd_tag_late_w0[FirstBit+:Bits] == late_update_tag[FirstBit+:Bits];
    assign update_tag_equal_chunks[3][chunk] =
        fwd_tag_late_w1[FirstBit+:Bits] == late_update_tag[FirstBit+:Bits];
  end

  wire early_tag_matches_w0 = early_valid_w0 && (&update_tag_equal_chunks[0]);
  wire early_tag_matches_w1 = early_valid_w1 && (&update_tag_equal_chunks[1]);
  wire early_target_hit = early_tag_matches_w0 || early_tag_matches_w1;

  always_comb begin
    if (early_tag_matches_w0) begin
      early_target_way = 1'b0;
    end else if (early_tag_matches_w1) begin
      early_target_way = 1'b1;
    end else begin
      // Allocation: fill invalid way first, else replace LRU (1: Way 1 MRU -> victim Way 0; 0: victim Way 1)
      if (!early_valid_w0) early_target_way = 1'b0;
      else if (!early_valid_w1) early_target_way = 1'b1;
      else early_target_way = early_plru ? 1'b0 : 1'b1;
    end
  end

  always_comb begin
    logic [1:0] cur_counter;
    cur_counter = early_target_way ? fwd_counter_early_w1 : fwd_counter_early_w0;
    if (!early_target_hit) begin
      early_next_counter = i_early_update_taken ? WeaklyTaken : WeaklyNotTaken;
    end else if (i_early_update_taken) begin
      early_next_counter = (cur_counter == StronglyTaken) ? StronglyTaken : cur_counter + 2'b01;
    end else begin
      early_next_counter =
          (cur_counter == StronglyNotTaken) ? StronglyNotTaken : cur_counter - 2'b01;
    end
  end

  wire late_tag_matches_w0 = late_valid_w0 && (&update_tag_equal_chunks[2]);
  wire late_tag_matches_w1 = late_valid_w1 && (&update_tag_equal_chunks[3]);
  wire late_target_hit = late_tag_matches_w0 || late_tag_matches_w1;

  always_comb begin
    if (late_tag_matches_w0) begin
      late_target_way = 1'b0;
    end else if (late_tag_matches_w1) begin
      late_target_way = 1'b1;
    end else begin
      if (!late_valid_w0) late_target_way = 1'b0;
      else if (!late_valid_w1) late_target_way = 1'b1;
      else late_target_way = late_plru ? 1'b0 : 1'b1;
    end
  end

  always_comb begin
    logic [1:0] cur_counter;
    cur_counter = late_target_way ? fwd_counter_late_w1 : fwd_counter_late_w0;
    if (!late_target_hit) begin
      late_next_counter = i_late_update_taken ? WeaklyTaken : WeaklyNotTaken;
    end else if (i_late_update_taken) begin
      late_next_counter = (cur_counter == StronglyTaken) ? StronglyTaken : cur_counter + 2'b01;
    end else begin
      late_next_counter =
          (cur_counter == StronglyNotTaken) ? StronglyNotTaken : cur_counter - 2'b01;
    end
  end

  assign selected_way = i_early_update_active ? early_target_way : late_target_way;
  assign next_counter = i_early_update_active ? early_next_counter : late_next_counter;

  // =========================================================================
  // Synchronous State Update and Reset
  // =========================================================================
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int i = 0; i < BtbSets; i++) begin
        btb_valid_w0[i]       <= 1'b0;
        btb_valid_w1[i]       <= 1'b0;
        btb_plru[i]           <= 1'b0;
        btb_valid_2_w0[i]     <= 1'b0;
        btb_valid_2_w1[i]     <= 1'b0;
        btb_valid_2_alt_w0[i] <= 1'b0;
        btb_valid_2_alt_w1[i] <= 1'b0;
        btb_valid_2_rot_w0[i] <= 1'b0;
        btb_valid_2_rot_w1[i] <= 1'b0;
      end
    end else if (p_update) begin
      if (p_way == 1'b0) begin
        btb_valid_w0[update_index]             <= update_target_region_predictable;
        btb_plru[update_index]                 <= 1'b0;  // Way 0 is now MRU
        btb_valid_2_w0[update_index_2]         <= update_slot2_plus2_target_valid;
        btb_valid_2_alt_w0[update_index_2_alt] <= update_slot2_plus4_target_valid;
        btb_valid_2_rot_w0[update_index_2_rot] <= update_slot2_plus2_target_valid;
      end else begin
        btb_valid_w1[update_index]             <= update_target_region_predictable;
        btb_plru[update_index]                 <= 1'b1;  // Way 1 is now MRU
        btb_valid_2_w1[update_index_2]         <= update_slot2_plus2_target_valid;
        btb_valid_2_alt_w1[update_index_2_alt] <= update_slot2_plus4_target_valid;
        btb_valid_2_rot_w1[update_index_2_rot] <= update_slot2_plus2_target_valid;
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (Slot2PayloadBits != $bits(slot2_payload_t)) begin
      $error("branch_predictor: Slot2PayloadBits does not match slot2_payload_t");
    end
  end

  logic update_reset_seen_q = 1'b0;

  always_ff @(posedge i_clk) begin
    if (i_rst) update_reset_seen_q <= 1'b1;
  end

  // The slot-2 payload drops target bit 0, so every trained target must have
  // it clear.
  always_ff @(posedge i_clk) begin
    if (update_reset_seen_q && !i_rst && i_update && !$isunknown(i_update_target[0])) begin
      p_update_target_is_halfword_aligned : assert (!i_update_target[0]);
    end
  end

  // Reference model of the 2-way tag, counter, and PLRU state
  logic reference_update_valid_w0[BtbSets];
  logic reference_update_valid_w1[BtbSets];
  logic [TagBits-1:0] reference_update_tag_w0[BtbSets];
  logic [TagBits-1:0] reference_update_tag_w1[BtbSets];
  logic [1:0] reference_update_counter_w0[BtbSets];
  logic [1:0] reference_update_counter_w1[BtbSets];
  logic reference_plru[BtbSets];

  logic reference_selected_way;
  logic [1:0] reference_selected_next_counter;

  wire [BTB_INDEX_BITS-1:0] ref_index = i_update_pc[BTB_INDEX_BITS+1:2];
  wire [TagBits-1:0] ref_tag = {i_update_pc[XLEN-1:BTB_INDEX_BITS+2], i_update_pc[1]};
  wire ref_region_predictable =
      i_update_target[XLEN-1:TargetBits] == i_update_pc[XLEN-1:TargetBits];

  wire reference_tag_matches_w0 =
      reference_update_valid_w0[ref_index] &&
      (reference_update_tag_w0[ref_index] == ref_tag);
  wire reference_tag_matches_w1 =
      reference_update_valid_w1[ref_index] &&
      (reference_update_tag_w1[ref_index] == ref_tag);
  wire reference_tag_matches = reference_tag_matches_w0 || reference_tag_matches_w1;

  always_comb begin
    if (reference_tag_matches_w0) begin
      reference_selected_way = 1'b0;
    end else if (reference_tag_matches_w1) begin
      reference_selected_way = 1'b1;
    end else begin
      if (!reference_update_valid_w0[ref_index]) reference_selected_way = 1'b0;
      else if (!reference_update_valid_w1[ref_index]) reference_selected_way = 1'b1;
      else reference_selected_way = reference_plru[ref_index] ? 1'b0 : 1'b1;
    end
  end

  always_comb begin
    logic [1:0] cur_ref_counter;
    cur_ref_counter = reference_selected_way ?
        reference_update_counter_w1[ref_index] : reference_update_counter_w0[ref_index];
    if (!reference_tag_matches) begin
      reference_selected_next_counter = i_update_taken ? WeaklyTaken : WeaklyNotTaken;
    end else if (i_update_taken) begin
      reference_selected_next_counter =
          (cur_ref_counter == StronglyTaken) ? StronglyTaken : cur_ref_counter + 2'b01;
    end else begin
      reference_selected_next_counter =
          (cur_ref_counter == StronglyNotTaken) ? StronglyNotTaken : cur_ref_counter - 2'b01;
    end
  end

  initial begin
    for (int i = 0; i < BtbSets; i++) begin
      reference_update_valid_w0[i]   = 1'b0;
      reference_update_valid_w1[i]   = 1'b0;
      reference_update_tag_w0[i]     = '0;
      reference_update_tag_w1[i]     = '0;
      reference_update_counter_w0[i] = '0;
      reference_update_counter_w1[i] = '0;
      reference_plru[i]              = 1'b0;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int i = 0; i < BtbSets; i++) begin
        reference_update_valid_w0[i] <= 1'b0;
        reference_update_valid_w1[i] <= 1'b0;
        reference_plru[i]            <= 1'b0;
      end
    end else if (i_update) begin
      if (reference_selected_way == 1'b0) begin
        reference_update_valid_w0[ref_index]   <= ref_region_predictable;
        reference_update_tag_w0[ref_index]     <= ref_tag;
        reference_update_counter_w0[ref_index] <= reference_selected_next_counter;
        reference_plru[ref_index]              <= 1'b0;
      end else begin
        reference_update_valid_w1[ref_index]   <= ref_region_predictable;
        reference_update_tag_w1[ref_index]     <= ref_tag;
        reference_update_counter_w1[ref_index] <= reference_selected_next_counter;
        reference_plru[ref_index]              <= 1'b1;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (update_reset_seen_q && !i_rst && i_update && !$isunknown(
            {update_index, update_tag, i_update_taken,
             reference_selected_next_counter, next_counter,
             reference_selected_way, selected_way}
        )) begin
      p_selected_way_matches_ref : assert (selected_way == reference_selected_way);
      p_selected_counter_matches_ref : assert (next_counter == reference_selected_next_counter);
    end

    if (update_reset_seen_q && !i_rst && i_early_update_active && !$isunknown(
            {i_update, i_update_pc, i_update_taken, i_early_update_pc, i_early_update_taken}
        )) begin
      p_early_update_is_selected : assert (i_update);
      p_early_update_pc_is_selected : assert (i_update_pc == i_early_update_pc);
      p_early_update_outcome_is_selected : assert (i_update_taken == i_early_update_taken);
    end

    if (update_reset_seen_q && !i_rst && i_update && !i_early_update_active && !$isunknown(
            {i_update_pc, i_update_taken, i_late_update_pc, i_late_update_taken}
        )) begin
      p_late_update_pc_is_selected : assert (i_update_pc == i_late_update_pc);
      p_late_update_outcome_is_selected : assert (i_update_taken == i_late_update_taken);
    end
  end

  // Reference models of slot-2 images
  typedef struct packed {
    logic [TagBits-1:0] tag;
    slot2_payload_t     payload;
  } slot2_reference_row_t;

  logic shifted_reference_valid_2_w0[BtbSets], shifted_reference_valid_2_w1[BtbSets];
  slot2_reference_row_t shifted_reference_row_2_w0[BtbSets], shifted_reference_row_2_w1[BtbSets];

  logic shifted_reference_valid_2_alt_w0[BtbSets], shifted_reference_valid_2_alt_w1[BtbSets];
  slot2_reference_row_t
      shifted_reference_row_2_alt_w0[BtbSets], shifted_reference_row_2_alt_w1[BtbSets];

  logic shifted_reference_valid_2_rot_w0[BtbSets], shifted_reference_valid_2_rot_w1[BtbSets];
  slot2_reference_row_t
      shifted_reference_row_2_rot_w0[BtbSets], shifted_reference_row_2_rot_w1[BtbSets];

  slot2_payload_t reference_update_payload;
  assign reference_update_payload = {
    update_target_stored[TargetBits-1:1],
    p_counter,
    p_update_compressed,
    p_update_call,
    p_update_return
  };

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      for (int i = 0; i < BtbSets; i++) begin
        shifted_reference_valid_2_w0[i]     <= 1'b0;
        shifted_reference_valid_2_w1[i]     <= 1'b0;
        shifted_reference_valid_2_alt_w0[i] <= 1'b0;
        shifted_reference_valid_2_alt_w1[i] <= 1'b0;
        shifted_reference_valid_2_rot_w0[i] <= 1'b0;
        shifted_reference_valid_2_rot_w1[i] <= 1'b0;
      end
    end else if (p_update) begin
      if (p_way == 1'b0) begin
        shifted_reference_valid_2_w0[update_index_2] <= update_slot2_plus2_target_valid;
        shifted_reference_row_2_w0[update_index_2] <= {update_tag_2, reference_update_payload};
        shifted_reference_valid_2_alt_w0[update_index_2_alt] <= update_slot2_plus4_target_valid;
        shifted_reference_row_2_alt_w0[update_index_2_alt] <= {
          update_tag_2_alt, reference_update_payload
        };
        shifted_reference_valid_2_rot_w0[update_index_2_rot] <= update_slot2_plus2_target_valid;
        shifted_reference_row_2_rot_w0[update_index_2_rot] <= {
          update_tag_2, reference_update_payload
        };
      end else begin
        shifted_reference_valid_2_w1[update_index_2] <= update_slot2_plus2_target_valid;
        shifted_reference_row_2_w1[update_index_2] <= {update_tag_2, reference_update_payload};
        shifted_reference_valid_2_alt_w1[update_index_2_alt] <= update_slot2_plus4_target_valid;
        shifted_reference_row_2_alt_w1[update_index_2_alt] <= {
          update_tag_2_alt, reference_update_payload
        };
        shifted_reference_valid_2_rot_w1[update_index_2_rot] <= update_slot2_plus2_target_valid;
        shifted_reference_row_2_rot_w1[update_index_2_rot] <= {
          update_tag_2, reference_update_payload
        };
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (update_reset_seen_q && !i_rst && !$isunknown(
            {i_pc_2_base, slot2_lookup_index_q, slot2_lookup_index_next_q}
        )) begin
      p_slot2_valid_capture_exact_w0 :
      assert (slot2_valid_2_w0_q == shifted_reference_valid_2_w0[slot2_lookup_index_q]);
      p_slot2_valid_capture_exact_w1 :
      assert (slot2_valid_2_w1_q == shifted_reference_valid_2_w1[slot2_lookup_index_q]);

      p_slot2_alt_valid_capture_exact_w0 :
      assert (slot2_valid_2_alt_w0_q == shifted_reference_valid_2_alt_w0[slot2_lookup_index_q]);
      p_slot2_alt_valid_capture_exact_w1 :
      assert (slot2_valid_2_alt_w1_q == shifted_reference_valid_2_alt_w1[slot2_lookup_index_q]);

      p_slot2_rot_valid_capture_exact_w0 :
      assert (slot2_valid_2_rot_w0_q == shifted_reference_valid_2_rot_w0[slot2_lookup_index_q]);
      p_slot2_rot_valid_capture_exact_w1 :
      assert (slot2_valid_2_rot_w1_q == shifted_reference_valid_2_rot_w1[slot2_lookup_index_q]);
    end
  end
`endif

endmodule : branch_predictor
