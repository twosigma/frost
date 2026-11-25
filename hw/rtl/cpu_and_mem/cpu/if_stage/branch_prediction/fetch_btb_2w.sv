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
 * Two-bank direct-mapped branch target buffer for decoupled 64-bit fetch
 * windows: 256 entries by default, split into even (PC[2]=0) and odd (PC[2]=1)
 * word banks of 128 entries each.
 *
 * A single lookup inspects both adjacent words W = i_pc[XLEN-1:2] and W+1 in
 * parallel: the odd bank reads i_pc[BTB_INDEX_BITS+1:3] and the even bank
 * reads the caller's precomputed even-word row index i_pc_even_idx, avoiding
 * an incrementer on the lookup address path. Tags include PC[1] so lower and
 * upper halfwords never alias. Hits in W require tag_hw >= i_pc[1]; hits in
 * W+1 are suppressed at the wrap boundary where (W+1) enters a new tag block,
 * allowing both words to compare against i_pc's upper tag bits and reconstruct
 * their target's upper region from i_pc.
 *
 * Word W has priority over W+1 when both predict taken. A predicted-taken
 * non-compressed entry at W+1's upper halfword (position 3) flags o_is_span so
 * the fetch stage can fetch W+2 for its upper halfword before steering to the
 * predicted target.
 *
 * Training updates one bank per cycle using parallel early and late counter
 * read-modify-write paths, matching branch_predictor's saturating-counter
 * rules and 4-GiB target region restriction. Reset or i_invalidate_all clears
 * all valid bits synchronously.
 */
module fetch_btb_2w #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned BTB_INDEX_BITS = 8,  // 256 total entries (128 per bank)
    parameter int unsigned BIM_BITS = riscv_pkg::BpDirIdxBits
) (
    input logic i_clk,
    input logic i_rst,

    // F0 dual-word lookup
    input logic [XLEN-1:0] i_pc,
    // Precomputed even-bank index: i_pc[BTB_INDEX_BITS+1:3] + i_pc[2].
    input logic [BTB_INDEX_BITS-2:0] i_pc_even_idx,
    // Parallel tier-check and RAS target inputs evaluated alongside tag compare.
    input logic i_fetch_translation_active,
    input logic i_pc_is_cached,
    input logic i_ras_nonempty,
    input logic i_ras_top_is_cached,
    input logic [XLEN-1:0] i_ras_top,
    input logic [BIM_BITS-3:0] i_ras_even_dir_idx,

    // Winning predicted-taken result across words W and W+1 (W has priority)
    output logic                o_taken,
    output logic                o_taken_steer,          // o_taken && !o_is_span
    output logic [         1:0] o_taken_pos,            // {word_in_win, halfword}: 0..3
    output logic [    XLEN-1:0] o_target,
    output logic [BIM_BITS-3:0] o_target_even_dir_idx,
    output logic                o_compressed,
    output logic                o_is_call,
    output logic                o_is_return,
    output logic                o_is_span,              // 32-bit taken branch at W+1 upper halfword (pos 3)
    output logic                o_target_is_cached,
    output logic                o_w0_hit,
    output logic                o_w1_hit,

    // Selected training update (at most one per cycle)
    input logic            i_update,
    input logic [XLEN-1:0] i_update_pc,
    input logic [XLEN-1:0] i_update_target,
    input logic            i_update_taken,
    input logic            i_update_compressed,
    input logic            i_update_call,
    input logic            i_update_return,

    // Parallel early/late counter RMW candidates
    input logic            i_early_update_active,
    input logic [XLEN-1:0] i_early_update_pc,
    input logic            i_early_update_taken,
    input logic [XLEN-1:0] i_late_update_pc,
    input logic            i_late_update_taken,

    // Invalidate every entry (wins over same-cycle update)
    input logic i_invalidate_all
);

  localparam int unsigned BankIndexBits = BTB_INDEX_BITS - 1;
  localparam int unsigned BankEntries = 1 << BankIndexBits;
  localparam int unsigned EvenDirBits = BIM_BITS - 2;
  localparam int unsigned UpperTagBits = XLEN - BTB_INDEX_BITS - 2;  // PC[63:10] = 54b
  localparam int unsigned TagBits = UpperTagBits + 1;  // {upper, PC[1]} = 55b
  localparam int unsigned TargetBits = riscv_pkg::PhysAddrBits;
  // {target[TargetBits-1:1], target_even_dir_idx, target_is_cached, comp, call, ret}
  localparam int unsigned PayloadBits = (TargetBits - 1) + EvenDirBits + 4;

  localparam logic [1:0] StronglyNotTaken = 2'b00;
  localparam logic [1:0] WeaklyNotTaken = 2'b01;
  localparam logic [1:0] WeaklyTaken = 2'b10;
  localparam logic [1:0] StronglyTaken = 2'b11;

  // Per-bank valid bits in FFs for single-cycle reset and invalidation.
  logic btb_valid[2][BankEntries];

  // Lookup indices and upper tag
  logic [BankIndexBits-1:0] bank_lookup_idx[2];
  logic [UpperTagBits-1:0] lookup_upper_tag;
  assign bank_lookup_idx[0] = i_pc_even_idx;
  assign bank_lookup_idx[1] = i_pc[BTB_INDEX_BITS+1:3];
  assign lookup_upper_tag   = i_pc[XLEN-1:BTB_INDEX_BITS+2];

  // Update indices, banks, and tags
  logic update_bank;
  logic [BankIndexBits-1:0] update_idx;
  logic [TagBits-1:0] update_tag;
  assign update_bank = i_update_pc[2];
  assign update_idx  = i_update_pc[BTB_INDEX_BITS+1:3];
  assign update_tag  = {i_update_pc[XLEN-1:BTB_INDEX_BITS+2], i_update_pc[1]};

  logic early_bank;
  logic [BankIndexBits-1:0] early_idx;
  logic [TagBits-1:0] early_tag;
  assign early_bank = i_early_update_pc[2];
  assign early_idx  = i_early_update_pc[BTB_INDEX_BITS+1:3];
  assign early_tag  = {i_early_update_pc[XLEN-1:BTB_INDEX_BITS+2], i_early_update_pc[1]};

  logic late_bank;
  logic [BankIndexBits-1:0] late_idx;
  logic [TagBits-1:0] late_tag;
  assign late_bank = i_late_update_pc[2];
  assign late_idx  = i_late_update_pc[BTB_INDEX_BITS+1:3];
  assign late_tag  = {i_late_update_pc[XLEN-1:BTB_INDEX_BITS+2], i_late_update_pc[1]};

  logic update_region_ok;
  logic [PayloadBits-1:0] update_payload;
  assign update_region_ok =
      i_update_target[XLEN-1:TargetBits] == i_update_pc[XLEN-1:TargetBits];

  // Counter next-state wires (declared before RAM instances)
  logic [1:0] next_counter;
  logic [1:0] early_next_counter;
  (* keep = "true" *) logic [1:0] late_next_counter;

  logic update_target_is_cached;
  logic [EvenDirBits-1:0] update_target_even_dir_idx;
  assign update_target_is_cached = riscv_pkg::pma_cached_ok(i_update_target);
  assign update_target_even_dir_idx =
      i_update_target[BIM_BITS:3] + EvenDirBits'(i_update_target[2]);

  assign update_payload = {
    i_update_target[TargetBits-1:1],
    update_target_even_dir_idx,
    update_target_is_cached,
    i_update_compressed,
    i_update_call,
    i_update_return
  };

  // Per-bank RAM read outputs
  logic [TagBits-1:0] bank_tag_lookup[2];
  logic [TagBits-1:0] bank_tag_late[2];
  logic [TagBits-1:0] bank_tag_early[2];
  logic [PayloadBits-1:0] bank_payload_lookup[2];
  logic [1:0] bank_counter_lookup[2];
  logic [1:0] bank_counter_late[2];
  logic [1:0] bank_counter_early[2];

  for (genvar b = 0; b < 2; b++) begin : gen_bank
    logic bank_we;
    assign bank_we = i_update && (update_bank == 1'(b));

    sdp_dist_ram #(
        .ADDR_WIDTH(BankIndexBits),
        .DATA_WIDTH(TagBits)
    ) u_tag_lookup (
        .i_clk,
        .i_write_enable(bank_we),
        .i_write_address(update_idx),
        .i_write_data(update_tag),
        .i_read_address(bank_lookup_idx[b]),
        .o_read_data(bank_tag_lookup[b])
    );

    sdp_dist_ram #(
        .ADDR_WIDTH(BankIndexBits),
        .DATA_WIDTH(TagBits)
    ) u_tag_late (
        .i_clk,
        .i_write_enable(bank_we),
        .i_write_address(update_idx),
        .i_write_data(update_tag),
        .i_read_address(late_idx),
        .o_read_data(bank_tag_late[b])
    );

    (* dont_touch = "yes" *)
    sdp_dist_ram #(
        .ADDR_WIDTH(BankIndexBits),
        .DATA_WIDTH(TagBits)
    ) u_tag_early (
        .i_clk,
        .i_write_enable(bank_we),
        .i_write_address(update_idx),
        .i_write_data(update_tag),
        .i_read_address(early_idx),
        .o_read_data(bank_tag_early[b])
    );

    sdp_dist_ram #(
        .ADDR_WIDTH(BankIndexBits),
        .DATA_WIDTH(PayloadBits)
    ) u_payload_lookup (
        .i_clk,
        .i_write_enable(bank_we),
        .i_write_address(update_idx),
        .i_write_data(update_payload),
        .i_read_address(bank_lookup_idx[b]),
        .o_read_data(bank_payload_lookup[b])
    );

    sdp_dist_ram #(
        .ADDR_WIDTH(BankIndexBits),
        .DATA_WIDTH(2)
    ) u_counter_lookup (
        .i_clk,
        .i_write_enable(bank_we),
        .i_write_address(update_idx),
        .i_write_data(next_counter),
        .i_read_address(bank_lookup_idx[b]),
        .o_read_data(bank_counter_lookup[b])
    );

    sdp_dist_ram #(
        .ADDR_WIDTH(BankIndexBits),
        .DATA_WIDTH(2)
    ) u_counter_late (
        .i_clk,
        .i_write_enable(bank_we),
        .i_write_address(update_idx),
        .i_write_data(next_counter),
        .i_read_address(late_idx),
        .o_read_data(bank_counter_late[b])
    );

    (* dont_touch = "yes" *)
    sdp_dist_ram #(
        .ADDR_WIDTH(BankIndexBits),
        .DATA_WIDTH(2)
    ) u_counter_early (
        .i_clk,
        .i_write_enable(bank_we),
        .i_write_address(update_idx),
        .i_write_data(next_counter),
        .i_read_address(early_idx),
        .o_read_data(bank_counter_early[b])
    );
  end

  // ===========================================================================
  // Combinational Dual-Word Lookup
  // ===========================================================================
  // Compare each bank's upper tag in 3-bit groups (6 inputs per leaf) reduced
  // in a balanced two-level tree to keep lookup depth shallow.
  localparam int unsigned TagCompareChunkBits = 3;
  localparam int unsigned UpperCompareChunks =
      (UpperTagBits + TagCompareChunkBits - 1) / TagCompareChunkBits;
  localparam int unsigned UpperReduceGroupBits = 6;
  localparam int unsigned UpperReduceGroups =
      (UpperCompareChunks + UpperReduceGroupBits - 1) / UpperReduceGroupBits;
  (* keep = "true" *) logic [1:0][UpperCompareChunks-1:0] bank_upper_eq_l1;
  (* keep = "true" *) logic [1:0][UpperReduceGroups-1:0] bank_upper_eq_l2;
  for (genvar b = 0; b < 2; b++) begin : gen_bank_cmp
    for (genvar chunk = 0; chunk < UpperCompareChunks; chunk++) begin : gen_chunk
      localparam int unsigned FirstBit = chunk * TagCompareChunkBits;
      localparam int unsigned ChunkWidth =
          (UpperTagBits - FirstBit < TagCompareChunkBits) ?
          (UpperTagBits - FirstBit) : TagCompareChunkBits;
      assign bank_upper_eq_l1[b][chunk] =
          bank_tag_lookup[b][1+FirstBit+:ChunkWidth] == lookup_upper_tag[FirstBit+:ChunkWidth];
    end
    for (genvar grp = 0; grp < UpperReduceGroups; grp++) begin : gen_grp
      localparam int unsigned FirstChunk = grp * UpperReduceGroupBits;
      localparam int unsigned GroupWidth =
          (UpperCompareChunks - FirstChunk < UpperReduceGroupBits) ?
          (UpperCompareChunks - FirstChunk) : UpperReduceGroupBits;
      assign bank_upper_eq_l2[b][grp] = &bank_upper_eq_l1[b][FirstChunk+:GroupWidth];
    end
  end

  logic [1:0] bank_valid_lookup;
  logic [1:0] bank_hw_lookup;
  logic [1:0] bank_is_ret;
  logic [1:0] bank_is_call;
  logic [1:0] bank_is_comp;
  logic [1:0] bank_tgt_cached;
  logic [1:0] bank_use_ras;
  logic [1:0] bank_eff_cached;
  logic [1:0] bank_same_tier;
  logic [1:0] bank_w0_elig;
  logic [1:0] bank_is_span;
  logic [XLEN-1:0] bank_eff_target[2];
  logic [EvenDirBits-1:0] bank_eff_even_dir[2];

  for (genvar b = 0; b < 2; b++) begin : gen_bank_meta
    assign bank_valid_lookup[b] = btb_valid[b][bank_lookup_idx[b]];
    assign bank_hw_lookup[b]    = bank_tag_lookup[b][0];
    assign bank_is_ret[b]       = bank_payload_lookup[b][0];
    assign bank_is_call[b]      = bank_payload_lookup[b][1];
    assign bank_is_comp[b]      = bank_payload_lookup[b][2];
    assign bank_tgt_cached[b]   = bank_payload_lookup[b][3];
    assign bank_use_ras[b]      = bank_is_ret[b] && i_ras_nonempty;
    assign bank_eff_cached[b]   = bank_use_ras[b] ? i_ras_top_is_cached : bank_tgt_cached[b];
    assign bank_same_tier[b]    = i_fetch_translation_active || (bank_eff_cached[b] == i_pc_is_cached);
    assign bank_w0_elig[b]      = !i_pc[1] || bank_hw_lookup[b];
    assign bank_is_span[b]      = bank_hw_lookup[b] && !bank_is_comp[b];
    assign bank_eff_target[b]   = bank_use_ras[b] ?
        i_ras_top : {i_pc[XLEN-1:TargetBits], bank_payload_lookup[b][PayloadBits-1:4+EvenDirBits], 1'b0};
    assign bank_eff_even_dir[b] = bank_use_ras[b] ?
        i_ras_even_dir_idx : bank_payload_lookup[b][4+:EvenDirBits];
  end

  // Fold valid, upper-tag match, direction counter bit, and same-tier check
  // into one 6-input LUT per bank so W0/W1 resolution stays shallow.
  (* keep = "true" *) logic [1:0] bank_raw_taken;
  (* keep = "true" *) logic [1:0] bank_taken_ok;
  for (genvar b = 0; b < 2; b++) begin : gen_bank_taken
    assign bank_raw_taken[b] = bank_valid_lookup[b] && (&bank_upper_eq_l2[b]) &&
        bank_counter_lookup[b][1];
    assign bank_taken_ok[b] = bank_valid_lookup[b] && (&bank_upper_eq_l2[b]) &&
        bank_counter_lookup[b][1] && bank_same_tier[b];
  end

  logic w0_is_odd;
  logic w1_wraps_block;
  assign w0_is_odd      = i_pc[2];
  assign w1_wraps_block = &i_pc[BTB_INDEX_BITS+1:2];

  // W hit must lie at or after the entry halfword i_pc[1].
  // W+1 hit is suppressed when W+1 wraps into the next tag block.
  logic w0_hit;
  logic w1_hit;
  logic w0_raw_taken;
  logic w0_taken;
  logic w1_taken_cand;
  logic w1_steer_cand;
  logic w1_taken;
  logic w0_hw;
  logic w1_hw;
  assign w0_hw = w0_is_odd ? bank_hw_lookup[1] : bank_hw_lookup[0];
  assign w1_hw = w0_is_odd ? bank_hw_lookup[0] : bank_hw_lookup[1];

  assign w0_hit = (w0_is_odd ? (bank_valid_lookup[1] && (&bank_upper_eq_l2[1])) :
                               (bank_valid_lookup[0] && (&bank_upper_eq_l2[0]))) &&
                  (!i_pc[1] || w0_hw);
  assign w1_hit = (w0_is_odd ? (bank_valid_lookup[0] && (&bank_upper_eq_l2[0])) :
                               (bank_valid_lookup[1] && (&bank_upper_eq_l2[1]))) &&
                  !w1_wraps_block;

  assign w0_raw_taken = w0_is_odd ?
      (bank_raw_taken[1] && bank_w0_elig[1]) : (bank_raw_taken[0] && bank_w0_elig[0]);
  assign w0_taken = w0_is_odd ?
      (bank_taken_ok[1] && bank_w0_elig[1]) : (bank_taken_ok[0] && bank_w0_elig[0]);
  assign w1_taken_cand = (w0_is_odd ? bank_taken_ok[0] : bank_taken_ok[1]) && !w1_wraps_block;
  assign w1_steer_cand = (w0_is_odd ? (bank_taken_ok[0] && !bank_is_span[0]) :
                                      (bank_taken_ok[1] && !bank_is_span[1])) && !w1_wraps_block;
  // W0 keeps strict priority even if W0 crosses tiers (w0_raw_taken blocks W1).
  assign w1_taken = !w0_raw_taken && w1_taken_cand;

  logic sel_bank1;
  // When o_taken is high, w0_taken and w1_taken are mutually exclusive, so
  // sel_bank1 simplifies to w0_is_odd ^ w1_taken.
  assign sel_bank1 = w0_is_odd ^ w1_taken;

  assign o_w0_hit              = w0_hit;
  assign o_w1_hit              = w1_hit;
  assign o_taken               = w0_taken || w1_taken;
  assign o_taken_steer         = w0_taken || (!w0_raw_taken && w1_steer_cand);
  assign o_taken_pos           = w1_taken ? {1'b1, w1_hw} : {1'b0, w0_hw};
  assign o_target              = sel_bank1 ? bank_eff_target[1] : bank_eff_target[0];
  assign o_target_even_dir_idx = sel_bank1 ? bank_eff_even_dir[1] : bank_eff_even_dir[0];
  assign o_target_is_cached    = sel_bank1 ? bank_eff_cached[1] : bank_eff_cached[0];
  assign o_compressed          = sel_bank1 ? bank_is_comp[1] : bank_is_comp[0];
  assign o_is_call             = o_taken && (sel_bank1 ? bank_is_call[1] : bank_is_call[0]);
  assign o_is_return           = o_taken && (sel_bank1 ? bank_is_ret[1] : bank_is_ret[0]);
  assign o_is_span             = w1_taken && (w0_is_odd ? bank_is_span[0] : bank_is_span[1]);

  // ===========================================================================
  // Parallel Early/Late Counter RMW
  // ===========================================================================
  localparam int unsigned FullTagChunks = (TagBits + TagCompareChunkBits - 1) / TagCompareChunkBits;
  logic [TagBits-1:0] early_tag_rd;
  logic [TagBits-1:0] late_tag_rd;
  logic [1:0] early_cnt_rd;
  logic [1:0] late_cnt_rd;
  assign early_tag_rd = early_bank ? bank_tag_early[1] : bank_tag_early[0];
  assign late_tag_rd  = late_bank ? bank_tag_late[1] : bank_tag_late[0];
  assign early_cnt_rd = early_bank ? bank_counter_early[1] : bank_counter_early[0];
  assign late_cnt_rd  = late_bank ? bank_counter_late[1] : bank_counter_late[0];

  (* keep = "true" *) logic [1:0][FullTagChunks-1:0] update_tag_eq_chunks;
  for (genvar chunk = 0; chunk < FullTagChunks; chunk++) begin : gen_upd_cmp
    localparam int unsigned FirstBit = chunk * TagCompareChunkBits;
    localparam int unsigned ChunkWidth =
        (TagBits - FirstBit < TagCompareChunkBits) ?
        (TagBits - FirstBit) : TagCompareChunkBits;
    assign update_tag_eq_chunks[0][chunk] =
        early_tag_rd[FirstBit+:ChunkWidth] == early_tag[FirstBit+:ChunkWidth];
    assign update_tag_eq_chunks[1][chunk] =
        late_tag_rd[FirstBit+:ChunkWidth] == late_tag[FirstBit+:ChunkWidth];
  end

  logic early_tag_matches;
  logic late_tag_matches;
  assign early_tag_matches = btb_valid[early_bank][early_idx] && (&update_tag_eq_chunks[0]);
  assign late_tag_matches  = btb_valid[late_bank][late_idx] && (&update_tag_eq_chunks[1]);

  always_comb begin
    if (!early_tag_matches) begin
      early_next_counter = i_early_update_taken ? WeaklyTaken : WeaklyNotTaken;
    end else if (i_early_update_taken) begin
      early_next_counter = (early_cnt_rd == StronglyTaken) ? StronglyTaken : (early_cnt_rd + 2'b01);
    end else begin
      early_next_counter =
          (early_cnt_rd == StronglyNotTaken) ? StronglyNotTaken : (early_cnt_rd - 2'b01);
    end
  end

  always_comb begin
    if (!late_tag_matches) begin
      late_next_counter = i_late_update_taken ? WeaklyTaken : WeaklyNotTaken;
    end else if (i_late_update_taken) begin
      late_next_counter = (late_cnt_rd == StronglyTaken) ? StronglyTaken : (late_cnt_rd + 2'b01);
    end else begin
      late_next_counter =
          (late_cnt_rd == StronglyNotTaken) ? StronglyNotTaken : (late_cnt_rd - 2'b01);
    end
  end

  assign next_counter = i_early_update_active ? early_next_counter : late_next_counter;

  // Synchronous valid array update / clear
  always_ff @(posedge i_clk) begin
    if (i_rst || i_invalidate_all) begin
      for (int b = 0; b < 2; b++) begin
        for (int i = 0; i < BankEntries; i++) begin
          btb_valid[b][i] <= 1'b0;
        end
      end
    end else if (i_update) begin
      btb_valid[update_bank][update_idx] <= update_region_ok;
    end
  end

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  logic ref_valid[2][BankEntries];
  logic [TagBits-1:0] ref_tag[2][BankEntries];
  logic [1:0] ref_cnt[2][BankEntries];
  logic [1:0] ref_next_cnt;
  logic ref_match;

  assign ref_match = ref_valid[update_bank][update_idx] &&
      (ref_tag[update_bank][update_idx] == update_tag);
  always_comb begin
    if (!ref_match) begin
      ref_next_cnt = i_update_taken ? WeaklyTaken : WeaklyNotTaken;
    end else if (i_update_taken) begin
      ref_next_cnt = (ref_cnt[update_bank][update_idx] == StronglyTaken) ?
          StronglyTaken : (ref_cnt[update_bank][update_idx] + 2'b01);
    end else begin
      ref_next_cnt = (ref_cnt[update_bank][update_idx] == StronglyNotTaken) ?
          StronglyNotTaken : (ref_cnt[update_bank][update_idx] - 2'b01);
    end
  end

  initial begin
    for (int b = 0; b < 2; b++) begin
      for (int i = 0; i < BankEntries; i++) begin
        ref_valid[b][i] = 1'b0;
        ref_tag[b][i]   = '0;
        ref_cnt[b][i]   = '0;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      reset_seen_q <= 1'b1;
      for (int b = 0; b < 2; b++) begin
        for (int i = 0; i < BankEntries; i++) ref_valid[b][i] <= 1'b0;
      end
    end else if (i_invalidate_all) begin
      for (int b = 0; b < 2; b++) begin
        for (int i = 0; i < BankEntries; i++) ref_valid[b][i] <= 1'b0;
      end
    end else if (i_update) begin
      ref_valid[update_bank][update_idx] <= update_region_ok;
    end
    if (i_update) begin
      ref_tag[update_bank][update_idx] <= update_tag;
      ref_cnt[update_bank][update_idx] <= ref_next_cnt;
    end

    if (reset_seen_q && !i_rst) begin
      if (!$isunknown({i_pc, i_pc_even_idx})) begin
        p_even_idx_matches_pc :
        assert (i_pc_even_idx ==
                (i_pc[BTB_INDEX_BITS+1:3] + BankIndexBits'(i_pc[2])));
      end
      if (i_update && !$isunknown(i_update_target[0])) begin
        p_update_target_halfword_aligned : assert (!i_update_target[0]);
      end
      if (i_update && !$isunknown({update_bank, update_idx, next_counter, ref_next_cnt})) begin
        p_selected_counter_matches_ref : assert (next_counter == ref_next_cnt);
      end
    end
  end
`endif

endmodule : fetch_btb_2w
