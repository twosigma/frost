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
 * Tagged direction predictor for conditional branches, after TAGE.
 * riscv_pkg::TageTables (four) tagged tables are indexed by a hash of a
 * branch's word address and the global direction history: table t hashes the
 * newest riscv_pkg::TageHist<t+1>Bits bits of history, a geometric series. An entry
 * holds a valid bit, a partial tag, a 3-bit counter whose top bit predicts
 * taken, and a 2-bit usefulness counter. The longest-history table whose tag
 * matches provides the direction, and the next shorter match is the
 * alternate. With no match there is no prediction, and the BTB and bimodal
 * directions stand.
 *
 * Each table is two banks split by word-address parity (PC[2]), so one lookup
 * reads both words of a fetch window, word(PC) and word(PC) + 1. Those hold a
 * 32-bit slot 1 and slot 2 in either window alignment.
 *
 * Lookup: in the fetch cycle each bank reads its word's entry at the hashed
 * index. The entries, the computed tags and indices, the lookup word, and the
 * history are registered, and the outputs show the newest lookup made in a
 * cycle with i_lookup_capture set. Prediction: the next cycle compares the
 * tags and selects each bank's provider from those registers.
 *
 * Training: a committed branch's saved lookup (bank, indices, tags, which
 * tables matched, the provider's direction, and the alternate direction it
 * would otherwise have had) arrives with the outcome and whether the final
 * prediction was wrong. The tables are read at the saved indices, each bank
 * keeping a separate read copy for this, and written the next cycle; a read
 * of an entry being written takes the new value, so trainings in consecutive
 * cycles see each other. The write:
 *   - The provider's counter moves toward the outcome if its tag still
 *     matches. Its usefulness counts up when the provider was right and the
 *     alternate wrong, and down in the opposite case.
 *   - A provider whose entry in the training copy does not hold the branch has
 *     that entry written back as read. Both copies of a bank take every
 *     write, so while they hold equal contents this rewrites the value both
 *     already hold. Copies that power up with different contents can differ
 *     at an entry no training writes; the write-back gives the lookup copy
 *     the training copy's entry, so no prediction keeps coming from an entry
 *     that training does not see.
 *   - A mispredicted branch whose provider was not the longest table
 *     allocates a weak entry in the shortest table above its provider whose
 *     entry is not useful and does not already hold the branch. If every
 *     candidate is useful, their usefulness counts down instead, so entries
 *     that stop being useful age out.
 * Each training writes each table at most once.
 */
module tage_predictor #(
    parameter int unsigned HIST_BITS = riscv_pkg::TageDirHistBits,
    parameter int unsigned TABLES = riscv_pkg::TageTables,
    parameter int unsigned INDEX_BITS = riscv_pkg::TageIndexBits,
    parameter int unsigned TAG_BITS = riscv_pkg::TageTagBits,
    // The hashes read word-address bits [LOOKUP_HI:2].
    parameter int unsigned LOOKUP_HI = 2 + 2 * INDEX_BITS
) (
    input logic i_clk,

    // Lookup (fetch cycle): the lookup PC's word-address bits.
    input logic [LOOKUP_HI:2] i_lookup_word,
    input logic [HIST_BITS-1:0] i_lookup_hist,
    input logic i_lookup_capture,

    // The newest captured lookup, from the cycle after its capture. Bank b
    // holds the word whose address bit 2 is b.
    output logic [LOOKUP_HI:2] o_lookup_word,  // the lookup word
    output logic [LOOKUP_HI:2] o_lookup_word_next,  // the lookup word + 1
    output logic [HIST_BITS-1:0] o_lookup_hist,
    output riscv_pkg::tage_lookup_t o_bank0,
    output riscv_pkg::tage_lookup_t o_bank1,

    // Training (commit)
    input logic                    i_train_valid,
    input riscv_pkg::tage_lookup_t i_train_lookup,
    input logic                    i_train_bank,
    input logic                    i_train_alt_taken,
    input logic                    i_train_taken,
    input logic                    i_train_mispredicted
);

  localparam int unsigned CtrBits = 3;
  localparam int unsigned UsefulBits = 2;
  localparam int unsigned EntryBits = 1 + TAG_BITS + CtrBits + UsefulBits;
  localparam logic [CtrBits-1:0] CtrWeakTaken = {1'b1, {(CtrBits - 1) {1'b0}}};
  localparam logic [CtrBits-1:0] CtrWeakNotTaken = {1'b0, {(CtrBits - 1) {1'b1}}};

  typedef struct packed {
    logic                  valid;
    logic [TAG_BITS-1:0]   tag;
    logic [CtrBits-1:0]    ctr;
    logic [UsefulBits-1:0] useful;
  } entry_t;

  // XOR-fold the history into an index-wide, tag-wide, or one-bit-narrower
  // value.
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

  // Index: word bits above the bank bit, a second slice of the word address,
  // and the folded history. Tag: the word address from the bank bit up, the
  // folded history, and a second fold shifted by one for diffusion.
  function automatic logic [INDEX_BITS-1:0] hash_index(input logic [LOOKUP_HI:2] word,
                                                       input logic [HIST_BITS-1:0] hist);
    hash_index = word[3+:INDEX_BITS] ^ word[3+INDEX_BITS+:INDEX_BITS] ^ fold_index(hist);
  endfunction
  function automatic logic [TAG_BITS-1:0] hash_tag(input logic [LOOKUP_HI:2] word,
                                                   input logic [HIST_BITS-1:0] hist);
    hash_tag = word[2+:TAG_BITS] ^ fold_tag(hist) ^ {fold_tag_short(hist), 1'b0};
  endfunction

  function automatic logic [CtrBits-1:0] counter_step(input logic [CtrBits-1:0] ctr,
                                                      input logic taken);
    if (taken) counter_step = (&ctr) ? ctr : ctr + 1'b1;
    else counter_step = (ctr == '0) ? ctr : ctr - 1'b1;
  endfunction

  // ===========================================================================
  // Lookup
  // ===========================================================================
  logic [LOOKUP_HI:2] word0;  // the lookup word
  logic [LOOKUP_HI:2] word1;  // the lookup word + 1
  assign word0 = i_lookup_word;
  assign word1 = word0 + 1'b1;

  // [table][bank]
  logic [TABLES-1:0][1:0][INDEX_BITS-1:0] lookup_index;
  logic [TABLES-1:0][1:0][TAG_BITS-1:0] lookup_tag;
  logic [TABLES-1:0][1:0][EntryBits-1:0] lookup_entry;

  // ===========================================================================
  // Tables: per table and bank, a lookup read copy and a training read copy
  // sharing the training write.
  // ===========================================================================
  logic [TABLES-1:0][INDEX_BITS-1:0] train_read_index;
  logic [TABLES-1:0][1:0][EntryBits-1:0] train_entry;
  logic [TABLES-1:0] write_any;
  logic write_bank;
  logic [TABLES-1:0][INDEX_BITS-1:0] write_index;
  logic [TABLES-1:0][EntryBits-1:0] write_entry;
  assign train_read_index = i_train_lookup.index;

  for (genvar b = 0; b < 2; b++) begin : gen_bank
    logic [LOOKUP_HI:2] bank_word;
    assign bank_word = (word0[2] == 1'(b)) ? word0 : word1;

    for (genvar t = 0; t < TABLES; t++) begin : gen_table
      // Table t hashes only the newest riscv_pkg::TageHist<t+1>Bits bits.
      localparam int unsigned TableHist = (t == 0) ? riscv_pkg::TageHist1Bits :
          (t == 1) ? riscv_pkg::TageHist2Bits : (t == 2) ? riscv_pkg::TageHist3Bits :
          riscv_pkg::TageHist4Bits;
      localparam logic [HIST_BITS-1:0] Mask = (TableHist >= HIST_BITS) ? '1 :
          ((HIST_BITS'(1) << TableHist) - HIST_BITS'(1));
      logic write_enable;
      assign lookup_index[t][b] = hash_index(bank_word, i_lookup_hist & Mask);
      assign lookup_tag[t][b] = hash_tag(bank_word, i_lookup_hist & Mask);
      assign write_enable = write_any[t] && (write_bank == 1'(b));
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

  // Register the lookup. i_lookup_capture is late, so instead of enabling
  // the registers with it, every lookup is registered and one register keeps
  // whether it was captured: the presented lookup is the fresh one after a
  // capture and otherwise the one presented the cycle before.
  localparam int unsigned LookupRegBits = 2 * (LOOKUP_HI - 1) + HIST_BITS +
      2 * TABLES * (EntryBits + INDEX_BITS + TAG_BITS);
  logic capture_q;
  logic [LookupRegBits-1:0] lookup_live;
  logic [LookupRegBits-1:0] lookup_fresh_q;
  logic [LookupRegBits-1:0] lookup_held_q;
  logic [LookupRegBits-1:0] lookup_presented;
  assign lookup_live = {word0, word1, i_lookup_hist, lookup_entry, lookup_index, lookup_tag};
  always_ff @(posedge i_clk) begin
    capture_q      <= i_lookup_capture;
    lookup_fresh_q <= lookup_live;
    lookup_held_q  <= lookup_presented;
  end
  assign lookup_presented = capture_q ? lookup_fresh_q : lookup_held_q;

  logic [TABLES-1:0][1:0][ EntryBits-1:0] lookup_entry_q;
  logic [TABLES-1:0][1:0][INDEX_BITS-1:0] lookup_index_q;
  logic [TABLES-1:0][1:0][  TAG_BITS-1:0] lookup_tag_q;
  assign {o_lookup_word, o_lookup_word_next, o_lookup_hist, lookup_entry_q, lookup_index_q,
          lookup_tag_q} = lookup_presented;

  // ===========================================================================
  // Prediction (cycle after the lookup)
  // ===========================================================================
  for (genvar b = 0; b < 2; b++) begin : gen_predict
    logic [TABLES-1:0] hit;
    logic [TABLES-1:0] ctr_taken;
    riscv_pkg::tage_lookup_t result;
    for (genvar t = 0; t < TABLES; t++) begin : gen_hit
      entry_t entry;
      assign entry = lookup_entry_q[t][b];
      assign hit[t] = entry.valid && (entry.tag == lookup_tag_q[t][b]);
      assign ctr_taken[t] = entry.ctr[CtrBits-1];
    end
    // The provider is the longest matching table and the alternate the next
    // shorter match; with no shorter match the consumer supplies the BTB and
    // bimodal direction as the alternate.
    logic provider_found;
    always_comb begin
      result = '0;
      for (int t = 0; t < TABLES; t++) begin
        result.index[t] = lookup_index_q[t][b];
        result.tag[t]   = lookup_tag_q[t][b];
      end
      result.hit = hit;
      provider_found = 1'b0;
      for (int t = TABLES - 1; t >= 0; t--) begin
        if (hit[t]) begin
          if (!provider_found) begin
            provider_found = 1'b1;
            result.taken   = ctr_taken[t];
          end else if (!result.alt_tagged) begin
            result.alt_tagged       = 1'b1;
            result.alt_tagged_taken = ctr_taken[t];
          end
        end
      end
    end
    if (b == 0) begin : gen_out0
      assign o_bank0 = result;
    end else begin : gen_out1
      assign o_bank1 = result;
    end
  end

  // ===========================================================================
  // Training
  // ===========================================================================
  // Read stage: the branch's bank of each table at the saved indices, or the
  // entry the write stage is writing this cycle. Precompute provider, above,
  // tag ownership, and usefulness-update qualifiers here so the write stage
  // feeds the distributed RAM write ports with minimal logic.
  logic [TABLES-1:0][EntryBits-1:0] read_entry;
  logic [TABLES-1:0][EntryBits-1:0] cur;  // the saved entries
  logic [TABLES-1:0] read_provider;
  logic [TABLES-1:0] read_above;
  logic [TABLES-1:0] read_owned;
  logic read_useful_update;
  logic read_useful_value;
  logic read_found;
  for (genvar t = 0; t < TABLES; t++) begin : gen_train_read
    entry_t read_entry_s;
    assign read_entry[t] = (write_any[t] && (write_bank == i_train_bank) &&
                            (write_index[t] == i_train_lookup.index[t])) ? write_entry[t] :
                           i_train_bank ? train_entry[t][1] : train_entry[t][0];
    assign read_entry_s = read_entry[t];
    assign read_owned[t] = read_entry_s.valid && (read_entry_s.tag == i_train_lookup.tag[t]);
  end
  assign read_useful_update = i_train_lookup.taken != i_train_alt_taken;
  assign read_useful_value  = i_train_lookup.taken == i_train_taken;
  always_comb begin
    read_provider = '0;
    read_above    = '0;
    read_found    = 1'b0;
    for (int t = TABLES - 1; t >= 0; t--) begin
      if (!read_found && i_train_lookup.hit[t]) begin
        read_provider[t] = 1'b1;
        read_found       = 1'b1;
      end else if (!read_found) begin
        read_above[t] = 1'b1;
      end
    end
  end

  // Training is idle during reset. A power-up write can only change
  // speculative predictions; branch resolution corrects any wrong prediction.
`ifdef FROST_RANDOM_START
  localparam bit RandomStart = 1'b1;
`else
  localparam bit RandomStart = 1'b0;
`endif

  logic train_valid_q = RandomStart ? 'x : 1'b0;
  riscv_pkg::tage_lookup_t train_lookup_q;
  logic train_taken_q;
  logic train_mispredicted_q;
  logic [TABLES-1:0] provider;
  logic [TABLES-1:0] above;
  logic [TABLES-1:0] owned;  // the saved entry still holds the branch
  logic useful_update;
  logic useful_value;
  always_ff @(posedge i_clk) begin
    train_valid_q        <= i_train_valid;
    train_lookup_q       <= i_train_lookup;
    write_bank           <= i_train_bank;
    train_taken_q        <= i_train_taken;
    train_mispredicted_q <= i_train_mispredicted;
    cur                  <= read_entry;
    provider             <= read_provider;
    above                <= read_above;
    owned                <= read_owned;
    useful_update        <= read_useful_update;
    useful_value         <= read_useful_value;
  end
  assign write_index = train_lookup_q.index;

  // Write stage: allocation and update from the registered qualifiers.
  logic [TABLES-1:0] useful;
  logic [TABLES-1:0] alloc;
  logic [TABLES-1:0] useful_down;
  always_comb begin
    // The shortest free table above the provider; if none, every candidate
    // counts its usefulness down.
    alloc = '0;
    for (int t = 0; t < TABLES; t++) begin
      if (train_mispredicted_q && above[t] && !provider[t] && !owned[t] && !useful[t] &&
          (alloc == '0))
        alloc[t] = 1'b1;
    end
    useful_down = '0;
    if (alloc == '0) begin
      for (int t = 0; t < TABLES; t++)
      useful_down[t] = train_mispredicted_q && above[t] && !provider[t];
    end
  end

  for (genvar t = 0; t < TABLES; t++) begin : gen_write
    entry_t entry;
    entry_t updated;
    assign entry = cur[t];
    assign useful[t] = |entry.useful;
    always_comb begin
      updated = entry;
      if (provider[t]) begin
        if (owned[t]) begin
          updated.ctr = counter_step(entry.ctr, train_taken_q);
          if (useful_update) begin
            if (useful_value) updated.useful = (&entry.useful) ? entry.useful : entry.useful + 1'b1;
            else updated.useful = (entry.useful == '0) ? entry.useful : entry.useful - 1'b1;
          end
        end
      end else if (alloc[t]) begin
        updated.valid  = 1'b1;
        updated.tag    = train_lookup_q.tag[t];
        updated.ctr    = train_taken_q ? CtrWeakTaken : CtrWeakNotTaken;
        updated.useful = '0;
      end else if (useful_down[t] && (entry.useful != '0)) begin
        updated.useful = entry.useful - 1'b1;
      end
    end
    assign write_entry[t] = updated;
    // A provider that does not own its entry writes the entry back as read
    // (next keeps cur then: no allocation or usefulness change happens in a
    // table that provided).
    assign write_any[t] = train_valid_q && (provider[t] || alloc[t] ||
                                            (useful_down[t] && (entry.useful != '0)));
  end

`ifndef SYNTHESIS
  initial begin
    if (EntryBits != $bits(entry_t)) $error("tage_predictor: EntryBits does not match entry_t");
    if (TABLES != 4 || riscv_pkg::TageHist4Bits > HIST_BITS)
      $error("tage_predictor: expects four tables within HIST_BITS of history");
  end
`endif

endmodule : tage_predictor
