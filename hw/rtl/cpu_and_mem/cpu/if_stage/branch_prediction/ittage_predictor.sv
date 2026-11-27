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
 *    Copyright (c) 2026 John Goodacre.
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
 * Indirect target predictor for JALRs that are not returns, after ITTAGE.
 * Three tagged tables are indexed by a hash of the JALR's word address and
 * the newest HIST1, HIST2 and HIST3 bits of the tagged direction predictor's
 * lookup history. An entry holds a valid bit, a partial tag, the target's
 * bits [TARGET_BITS-1:1] (the upper bits come from the JALR's PC, as in the
 * BTB), a 2-bit confidence counter and a usefulness bit. The longest-history
 * table whose tag matches provides the target.
 *
 * Each table is two banks split by word-address parity (PC[2]), so one lookup
 * reads both words of a fetch window, as in tage_predictor. Lookup: the fetch
 * cycle reads each bank's word at the hashed index; the entries, tags and
 * indices are registered (newest captured lookup, as tage_predictor), and
 * the next cycle compares the tags and selects each bank's provider.
 *
 * Training: a committed JALR's saved lookup (bank, indices, tags, which
 * tables matched) arrives with its target and whether its final prediction
 * was wrong. The tables are read at the saved indices (a separate read copy
 * per bank) and written the next cycle; a read of an entry being written
 * takes the new value. The write:
 *   - The provider's entry, if its tag still matches: a correct target raises
 *     its confidence and sets its usefulness; a wrong one lowers the
 *     confidence, or replaces the target once the confidence is zero. If the
 *     tag has changed, both copies receive the current training row.
 *   - A mispredicted JALR allocates its target with zero confidence in the
 *     shortest table above the provider whose entry is not useful and does
 *     not hold the JALR; each useful entry passed before it loses its
 *     usefulness.
 * Each training writes each table at most once.
 */
module ittage_predictor #(
    parameter int unsigned HIST_BITS = riscv_pkg::TageHistBits,
    parameter int unsigned HIST1 = riscv_pkg::IttHist1Bits,
    parameter int unsigned HIST2 = riscv_pkg::IttHist2Bits,
    parameter int unsigned HIST3 = riscv_pkg::IttHist3Bits,
    parameter int unsigned INDEX_BITS = riscv_pkg::IttIndexBits,
    parameter int unsigned TAG_BITS = riscv_pkg::IttTagBits,
    parameter int unsigned TARGET_BITS = riscv_pkg::PhysAddrBits,
    // The hashes read word-address bits [LOOKUP_HI:2].
    parameter int unsigned LOOKUP_HI = riscv_pkg::TageLookupHiBit
) (
    input logic i_clk,

    // Lookup (fetch cycle)
    input logic [LOOKUP_HI:2] i_lookup_word,
    input logic [HIST_BITS-1:0] i_lookup_hist,
    input logic i_lookup_capture,

    // The newest captured lookup, from the cycle after its capture. Bank b
    // holds the word whose address bit 2 is b: the saved lookup, whether a
    // table matched, and the provider's target bits [TARGET_BITS-1:1]. The
    // caller checks which words were looked up with the tagged direction
    // predictor's registered words, which come from the same lookup.
    output logic [HIST_BITS-1:0] o_lookup_hist,  // the history of the presented lookup
    output riscv_pkg::itt_lookup_t o_bank0,
    output riscv_pkg::itt_lookup_t o_bank1,
    output logic [1:0] o_hit,
    output logic [1:0][TARGET_BITS-2:0] o_target,

    // Training (commit)
    input logic                                     i_train_valid,
    input riscv_pkg::itt_lookup_t                   i_train_lookup,
    input logic                                     i_train_bank,
    input logic                   [TARGET_BITS-2:0] i_train_target,
    input logic                                     i_train_mispredicted
);

  localparam int unsigned Tables = 3;
  localparam int unsigned EntryBits = 1 + TAG_BITS + (TARGET_BITS - 1) + 2 + 1;

  typedef struct packed {
    logic                   valid;
    logic [TAG_BITS-1:0]    tag;
    logic [TARGET_BITS-2:0] target;
    logic [1:0]             conf;
    logic                   useful;
  } entry_t;

  function automatic logic [HIST_BITS-1:0] hist_mask(input int unsigned bits);
    hist_mask = '0;
    for (int b = 0; b < HIST_BITS; b++) if (b < bits) hist_mask[b] = 1'b1;
  endfunction

  function automatic logic [INDEX_BITS-1:0] fold_index(input logic [HIST_BITS-1:0] hist);
    fold_index = '0;
    for (int b = 0; b < HIST_BITS; b++)
    fold_index[b%INDEX_BITS] = fold_index[b%INDEX_BITS] ^ hist[b];
  endfunction
  function automatic logic [TAG_BITS-1:0] fold_tag(input logic [HIST_BITS-1:0] hist);
    fold_tag = '0;
    for (int b = 0; b < HIST_BITS; b++) fold_tag[b%TAG_BITS] = fold_tag[b%TAG_BITS] ^ hist[b];
  endfunction
  function automatic logic [TAG_BITS-2:0] fold_tag_short(input logic [HIST_BITS-1:0] hist);
    fold_tag_short = '0;
    for (int b = 0; b < HIST_BITS; b++)
    fold_tag_short[b%(TAG_BITS-1)] = fold_tag_short[b%(TAG_BITS-1)] ^ hist[b];
  endfunction

  // Index: word bits above the bank bit, a second slice, and the folded
  // history. Tag: the word address from the bank bit up, the folded history,
  // and a second fold shifted by one.
  function automatic logic [INDEX_BITS-1:0] hash_index(input logic [LOOKUP_HI:2] word,
                                                       input logic [HIST_BITS-1:0] hist);
    hash_index = word[3+:INDEX_BITS] ^ word[3+INDEX_BITS+:INDEX_BITS] ^ fold_index(hist);
  endfunction
  function automatic logic [TAG_BITS-1:0] hash_tag(input logic [LOOKUP_HI:2] word,
                                                   input logic [HIST_BITS-1:0] hist);
    hash_tag = word[2+:TAG_BITS] ^ fold_tag(hist) ^ {fold_tag_short(hist), 1'b0};
  endfunction

  // ===========================================================================
  // Lookup
  // ===========================================================================
  logic [LOOKUP_HI:2] word0;
  logic [LOOKUP_HI:2] word1;
  assign word0 = i_lookup_word;
  assign word1 = word0 + 1'b1;

  // [table][bank]
  logic [Tables-1:0][1:0][INDEX_BITS-1:0] lookup_index;
  logic [Tables-1:0][1:0][TAG_BITS-1:0] lookup_tag;
  logic [Tables-1:0][1:0][EntryBits-1:0] lookup_entry;

  logic [Tables-1:0][INDEX_BITS-1:0] train_read_index;
  logic [Tables-1:0][1:0][EntryBits-1:0] train_entry;
  logic [Tables-1:0] write_any;
  logic write_bank;
  logic [Tables-1:0][INDEX_BITS-1:0] write_index;
  logic [Tables-1:0][EntryBits-1:0] write_entry;
  (* max_fanout = 16, equivalent_register_removal = "no" *) logic [Tables-1:0][1:0] write_we_q = '0;
  (* max_fanout = 32 *) logic [Tables-1:0][INDEX_BITS-1:0] write_index_q;
  logic [Tables-1:0][EntryBits-1:0] write_entry_q;
  assign write_index = write_index_q;
  assign write_entry = write_entry_q;
  for (genvar t = 0; t < Tables; t++) begin : gen_write_any_vec
    assign write_any[t] = |write_we_q[t];
  end

  for (genvar b = 0; b < 2; b++) begin : gen_bank
    logic [LOOKUP_HI:2] bank_word;
    assign bank_word = (word0[2] == 1'(b)) ? word0 : word1;
    for (genvar t = 0; t < Tables; t++) begin : gen_table
      localparam logic [HIST_BITS-1:0] HistMask = hist_mask(
          t == 0 ? HIST1 : t == 1 ? HIST2 : HIST3
      );
      logic write_enable;
      assign lookup_index[t][b] = hash_index(bank_word, i_lookup_hist & HistMask);
      assign lookup_tag[t][b] = hash_tag(bank_word, i_lookup_hist & HistMask);
      assign write_enable = write_we_q[t][b];
      sdp_dist_ram #(
          .ADDR_WIDTH(INDEX_BITS),
          .DATA_WIDTH(EntryBits)
      ) u_lookup_copy (
          .i_clk,
          .i_write_enable(write_enable),
          .i_write_address(write_index[t]),
          .i_read_address(lookup_index[t][b]),
          .i_write_data(write_entry[t]),
          .o_read_data(lookup_entry[t][b])
      );
      sdp_dist_ram #(
          .ADDR_WIDTH(INDEX_BITS),
          .DATA_WIDTH(EntryBits)
      ) u_train_copy (
          .i_clk,
          .i_write_enable(write_enable),
          .i_write_address(write_index[t]),
          .i_read_address(train_read_index[t]),
          .i_write_data(write_entry[t]),
          .o_read_data(train_entry[t][b])
      );
    end
  end

  // Register every lookup and keep whether it was captured, as tage_predictor.
  localparam int unsigned LookupRegBits = HIST_BITS +
      2 * Tables * (EntryBits + INDEX_BITS + TAG_BITS);
  logic capture_q;
  logic [LookupRegBits-1:0] lookup_live;
  logic [LookupRegBits-1:0] lookup_fresh_q;
  logic [LookupRegBits-1:0] lookup_held_q;
  logic [LookupRegBits-1:0] lookup_presented;
  assign lookup_live = {i_lookup_hist, lookup_entry, lookup_index, lookup_tag};
  always_ff @(posedge i_clk) begin
    capture_q      <= i_lookup_capture;
    lookup_fresh_q <= lookup_live;
    lookup_held_q  <= lookup_presented;
  end
  assign lookup_presented = capture_q ? lookup_fresh_q : lookup_held_q;

  logic [Tables-1:0][1:0][ EntryBits-1:0] lookup_entry_q;
  logic [Tables-1:0][1:0][INDEX_BITS-1:0] lookup_index_q;
  logic [Tables-1:0][1:0][  TAG_BITS-1:0] lookup_tag_q;
  assign {o_lookup_hist, lookup_entry_q, lookup_index_q, lookup_tag_q} = lookup_presented;

  // ===========================================================================
  // Prediction (cycle after the lookup)
  // ===========================================================================
  // Each bank's table targets ([bank][table]), at module scope.
  logic [1:0][Tables-1:0][TARGET_BITS-2:0] predict_table_target;
  for (genvar b = 0; b < 2; b++) begin : gen_predict
    logic [Tables-1:0] hit;
    riscv_pkg::itt_lookup_t result;
    logic [TARGET_BITS-2:0] target;
    for (genvar t = 0; t < Tables; t++) begin : gen_hit
      // Entry fields by position: {valid, tag, target, conf, useful}.
      assign hit[t] = lookup_entry_q[t][b][EntryBits-1] &&
          (lookup_entry_q[t][b][EntryBits-2-:TAG_BITS] == lookup_tag_q[t][b]);
      assign predict_table_target[b][t] = lookup_entry_q[t][b][3+:TARGET_BITS-1];
    end
    always_comb begin
      target = hit[2] ? predict_table_target[b][2] :
          hit[1] ? predict_table_target[b][1] : predict_table_target[b][0];
      result = '0;
      for (int t = 0; t < Tables; t++) begin
        result.index[t] = lookup_index_q[t][b];
        result.tag[t]   = lookup_tag_q[t][b];
      end
      result.hit = hit;
    end
    if (b == 0) begin : gen_out0
      assign o_bank0 = result;
    end else begin : gen_out1
      assign o_bank1 = result;
    end
    assign o_hit[b] = |hit;
    assign o_target[b] = target;
  end

  // ===========================================================================
  // Training
  // ===========================================================================
  // Read stage: the JALR's bank of each table at the saved indices, or the
  // entry the write stage is writing this cycle. Precompute provider, above,
  // tag ownership, and target match here so the write stage drives the
  // distributed RAM write ports without wide comparators.
  logic [Tables-1:0][EntryBits-1:0] read_entry;
  logic [Tables-1:0][EntryBits-1:0] cur;
  logic [Tables-1:0] read_provider;
  logic [Tables-1:0] read_above;
  logic [Tables-1:0] read_owned;
  logic [Tables-1:0] read_correct;
  for (genvar t = 0; t < Tables; t++) begin : gen_train_read
    entry_t read_entry_s;
    assign train_read_index[t] = i_train_lookup.index[t];
    assign read_entry[t] = (write_any[t] && (write_bank == i_train_bank) &&
                            (write_index[t] == i_train_lookup.index[t])) ? write_entry[t] :
                           i_train_bank ? train_entry[t][1] : train_entry[t][0];
    assign read_entry_s = read_entry[t];
    assign read_owned[t] = read_entry_s.valid && (read_entry_s.tag == i_train_lookup.tag[t]);
    assign read_correct[t] = read_entry_s.target == i_train_target;
  end
  always_comb begin
    read_provider = '0;
    if (i_train_lookup.hit[2]) read_provider[2] = 1'b1;
    else if (i_train_lookup.hit[1]) read_provider[1] = 1'b1;
    else if (i_train_lookup.hit[0]) read_provider[0] = 1'b1;
    read_above[0] = !(|i_train_lookup.hit);
    read_above[1] = !i_train_lookup.hit[1] && !i_train_lookup.hit[2];
    read_above[2] = !i_train_lookup.hit[2];
  end

  // Precompute allocation, usefulness clears, write enables, and updated
  // entries in the read stage so every distributed RAM write port is driven
  // directly from registered flops.
  logic [Tables-1:0] read_useful;
  logic [Tables-1:0] read_alloc;
  logic [Tables-1:0] read_useful_clear;
  logic [Tables-1:0] read_write_any;
  logic [Tables-1:0][1:0] read_write_we;
  logic [Tables-1:0][EntryBits-1:0] read_write_entry;
  for (genvar t = 0; t < Tables; t++) begin : gen_read_useful
    entry_t read_u_s;
    assign read_u_s = read_entry[t];
    assign read_useful[t] = |read_u_s.useful;
  end
  always_comb begin
    read_alloc = '0;
    read_useful_clear = '0;
    for (int t = 0; t < Tables; t++) begin
      if (i_train_mispredicted && read_above[t] && !read_provider[t] && !(|read_alloc)) begin
        if (!read_owned[t] && !read_useful[t]) read_alloc[t] = 1'b1;
        else if (read_useful[t]) read_useful_clear[t] = 1'b1;
      end
    end
  end
  for (genvar t = 0; t < Tables; t++) begin : gen_read_write
    entry_t r_entry;
    entry_t r_updated;
    assign r_entry = read_entry[t];
    always_comb begin
      r_updated = r_entry;
      if (read_provider[t]) begin
        if (read_owned[t]) begin
          if (read_correct[t]) begin
            r_updated.conf   = (&r_entry.conf) ? r_entry.conf : r_entry.conf + 2'd1;
            r_updated.useful = 1'b1;
          end else if (r_entry.conf != 2'd0) begin
            r_updated.conf = r_entry.conf - 2'd1;
          end else begin
            r_updated.target = i_train_target;
          end
        end
      end else if (read_alloc[t]) begin
        r_updated.valid  = 1'b1;
        r_updated.tag    = i_train_lookup.tag[t];
        r_updated.target = i_train_target;
        r_updated.conf   = 2'd0;
        r_updated.useful = 1'b0;
      end else if (read_useful_clear[t]) begin
        r_updated.useful = 1'b0;
      end
    end
    assign read_write_entry[t] = r_updated;
    assign read_write_any[t] = i_train_valid &&
        (read_provider[t] || read_alloc[t] || read_useful_clear[t]);
    assign read_write_we[t][0] = read_write_any[t] && !i_train_bank;
    assign read_write_we[t][1] = read_write_any[t] && i_train_bank;
  end

  logic train_valid_q = 1'b0;
  riscv_pkg::itt_lookup_t train_lookup_q;
  logic [TARGET_BITS-2:0] train_target_q;
  logic train_mispredicted_q;
  logic [Tables-1:0] provider;
  logic [Tables-1:0] above;  // tables above the provider
  logic [Tables-1:0] owned;
  logic [Tables-1:0] correct_q;
  logic [Tables-1:0] alloc;
  logic [Tables-1:0] useful_clear;
  always_ff @(posedge i_clk) begin
    train_valid_q        <= i_train_valid;
    train_lookup_q       <= i_train_lookup;
    write_bank           <= i_train_bank;
    train_target_q       <= i_train_target;
    train_mispredicted_q <= i_train_mispredicted;
    cur                  <= read_entry;
    provider             <= read_provider;
    above                <= read_above;
    owned                <= read_owned;
    correct_q            <= read_correct;
    alloc                <= read_alloc;
    useful_clear         <= read_useful_clear;
    write_we_q           <= read_write_we;
    write_index_q        <= i_train_lookup.index;
    write_entry_q        <= read_write_entry;
  end

`ifdef ITTAGE_TRAINING_PROOF
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (f_past_valid) begin
      p_capture_or_hold :
      assert (lookup_presented == ($past(
          i_lookup_capture
      ) ? $past(
          lookup_live
      ) : $past(
          lookup_presented
      )));
      if (!$past(i_train_valid)) begin
        p_idle_never_writes : assert (write_any == '0);
      end else begin
        p_training_uses_its_bank : assert (write_bank == $past(i_train_bank));
        p_one_allocation : assert ($onehot0(alloc));
        p_correct_prediction_never_allocates : assert ($past(i_train_mispredicted) || alloc == '0);
      end
    end
  end
  for (genvar t = 0; t < Tables; t++) begin : gen_training_check
    logic   higher_hit;
    entry_t f_cur_s;
    if (t == Tables - 1) assign higher_hit = 1'b0;
    else assign higher_hit = |train_lookup_q.hit[Tables-1:t+1];
    assign f_cur_s = cur[t];
    always_ff @(posedge i_clk) begin
      if (f_past_valid && $past(i_train_valid)) begin
        p_saved_lookup : assert (train_lookup_q == $past(i_train_lookup));
        p_write_index : assert (write_index[t] == $past(i_train_lookup.index[t]));
        p_registered_provider_matches_lookup :
        assert (provider[t] == (train_lookup_q.hit[t] && !higher_hit));
        p_registered_above_matches_lookup :
        assert (above[t] == (!train_lookup_q.hit[t] && !higher_hit));
        p_registered_owned_matches_row :
        assert (owned[t] == (f_cur_s.valid && (f_cur_s.tag == train_lookup_q.tag[t])));
        p_registered_correct_matches_row :
        assert (correct_q[t] == (f_cur_s.target == train_target_q));
        if (train_lookup_q.hit[t] && !higher_hit) begin
          p_provider_is_written : assert (write_any[t]);
          if (!owned[t]) begin
            p_unowned_provider_preserves_training_row : assert (write_entry[t] == cur[t]);
          end
        end
        if ($past(
                write_any[t] && write_bank == i_train_bank &&
                  write_index[t] == i_train_lookup.index[t]
            )) begin
          p_consecutive_training_forwards : assert (cur[t] == $past(write_entry[t]));
        end
        cover (train_lookup_q.hit[t] && !higher_hit && !owned[t] && write_any[t]);
        cover (alloc[t] && write_any[t]);
      end
    end
  end
`endif

`ifndef SYNTHESIS
  initial begin
    if (EntryBits != $bits(entry_t)) $error("ittage_predictor: EntryBits does not match entry_t");
    if (HIST1 > HIST_BITS || HIST2 > HIST_BITS || HIST3 > HIST_BITS)
      $error("ittage_predictor: a table's history exceeds HIST_BITS");
  end
  // A training writes each table at most once: the provider is never a
  // candidate above itself, and the allocation and usefulness clears are
  // exclusive per table.
  always_comb begin
    for (int t = 0; t < Tables; t++) begin
      p_itt_one_write_per_table :
      assert (!train_valid_q || ($countones(
          {provider[t] && owned[t], alloc[t], useful_clear[t]}
      ) <= 1));
    end
  end
`ifndef FORMAL
  logic itt_train_qualifiers_armed_q = 1'b0;
  logic [Tables-1:0] sim_itt_provider_ref;
  logic [Tables-1:0] sim_itt_above_ref;
  logic [Tables-1:0] sim_itt_owned_ref;
  logic [Tables-1:0] sim_itt_correct_ref;
  always_comb begin
    for (int t = 0; t < Tables; t++) begin
      entry_t sim_cur_s;
      logic   sim_higher_hit;
      sim_cur_s = cur[t];
      sim_higher_hit = (t == 0) ? (|train_lookup_q.hit[2:1]) :
                       (t == 1) ? train_lookup_q.hit[2] : 1'b0;
      sim_itt_provider_ref[t] = train_lookup_q.hit[t] && !sim_higher_hit;
      sim_itt_above_ref[t] = !train_lookup_q.hit[t] && !sim_higher_hit;
      sim_itt_owned_ref[t] = sim_cur_s.valid && (sim_cur_s.tag == train_lookup_q.tag[t]);
      sim_itt_correct_ref[t] = sim_cur_s.target == train_target_q;
    end
  end
  always @(posedge i_clk) begin
    itt_train_qualifiers_armed_q <= 1'b1;
    if (itt_train_qualifiers_armed_q && train_valid_q && !$isunknown(
            {provider, above, owned, correct_q, sim_itt_provider_ref, sim_itt_above_ref,
             sim_itt_owned_ref, sim_itt_correct_ref}
        )) begin
      p_sim_itt_provider_matches_lookup : assert (provider == sim_itt_provider_ref);
      p_sim_itt_above_matches_lookup : assert (above == sim_itt_above_ref);
      p_sim_itt_owned_matches_row : assert (owned == sim_itt_owned_ref);
      p_sim_itt_correct_matches_row : assert (correct_q == sim_itt_correct_ref);
    end
  end
`endif
`endif

endmodule : ittage_predictor
