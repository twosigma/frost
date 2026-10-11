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
 * Tagged direction predictor for conditional branches, after TAGE. Two tagged
 * tables are indexed by a hash of a branch's word address and the global path
 * history: T1 hashes the newest T1_HIST_BITS of history and T2 all
 * HIST_BITS. An entry holds a valid bit, a partial tag, a 3-bit counter whose
 * top bit predicts taken, and a usefulness bit. The longer-history table whose
 * tag matches provides the direction. With no match there is no prediction,
 * and the BTB and bimodal directions stand.
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
 *     matches. Its usefulness bit sets when the provider was right and the
 *     alternate wrong, and clears in the opposite case.
 *   - A mispredicted branch whose provider was not T2 allocates a weak entry
 *     in the shortest table above its provider whose entry is not useful and
 *     does not already hold the branch. If every candidate is useful, their
 *     usefulness bits clear instead.
 * Each training writes each table at most once.
 */
module tage_predictor #(
    parameter int unsigned HIST_BITS = riscv_pkg::TageHistBits,
    parameter int unsigned T1_HIST_BITS = riscv_pkg::TageT1HistBits,
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
  localparam int unsigned EntryBits = 1 + TAG_BITS + CtrBits + 1;
  localparam logic [CtrBits-1:0] CtrWeakTaken = {1'b1, {(CtrBits - 1) {1'b0}}};
  localparam logic [CtrBits-1:0] CtrWeakNotTaken = {1'b0, {(CtrBits - 1) {1'b1}}};
  // T1 hashes only the newest T1_HIST_BITS of history.
  localparam logic [HIST_BITS-1:0] T1HistMask = {
    {(HIST_BITS - T1_HIST_BITS) {1'b0}}, {T1_HIST_BITS{1'b1}}
  };

  typedef struct packed {
    logic                valid;
    logic [TAG_BITS-1:0] tag;
    logic [CtrBits-1:0]  ctr;
    logic                useful;
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
  logic [  LOOKUP_HI:2] word0;  // the lookup word
  logic [  LOOKUP_HI:2] word1;  // the lookup word + 1
  logic [HIST_BITS-1:0] lookup_hist_t1;
  assign word0 = i_lookup_word;
  assign word1 = word0 + 1'b1;
  assign lookup_hist_t1 = i_lookup_hist & T1HistMask;

  // [table][bank]
  logic [1:0][1:0][INDEX_BITS-1:0] lookup_index;
  logic [1:0][1:0][TAG_BITS-1:0] lookup_tag;
  logic [1:0][1:0][EntryBits-1:0] lookup_entry;

  // ===========================================================================
  // Tables: per table and bank, a lookup read copy and a training read copy
  // sharing the training write.
  // ===========================================================================
  logic [1:0][INDEX_BITS-1:0] train_read_index;  // [table]
  logic [1:0][1:0][EntryBits-1:0] train_entry;  // [table][bank]
  logic [1:0] write_any;  // [table]
  logic write_bank;
  logic [1:0][INDEX_BITS-1:0] write_index;  // [table]
  logic [1:0][EntryBits-1:0] write_entry;  // [table]
  assign train_read_index[0] = i_train_lookup.index1;
  assign train_read_index[1] = i_train_lookup.index2;

  for (genvar b = 0; b < 2; b++) begin : gen_bank
    logic [LOOKUP_HI:2] bank_word;
    assign bank_word = (word0[2] == 1'(b)) ? word0 : word1;
    assign lookup_index[0][b] = hash_index(bank_word, lookup_hist_t1);
    assign lookup_index[1][b] = hash_index(bank_word, i_lookup_hist);
    assign lookup_tag[0][b] = hash_tag(bank_word, lookup_hist_t1);
    assign lookup_tag[1][b] = hash_tag(bank_word, i_lookup_hist);

    for (genvar t = 0; t < 2; t++) begin : gen_table
      logic write_enable;
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
      4 * (EntryBits + INDEX_BITS + TAG_BITS);
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

  logic [1:0][1:0][ EntryBits-1:0] lookup_entry_q;
  logic [1:0][1:0][INDEX_BITS-1:0] lookup_index_q;
  logic [1:0][1:0][  TAG_BITS-1:0] lookup_tag_q;
  assign {o_lookup_word, o_lookup_word_next, o_lookup_hist, lookup_entry_q, lookup_index_q,
          lookup_tag_q} = lookup_presented;

  // ===========================================================================
  // Prediction (cycle after the lookup)
  // ===========================================================================
  for (genvar b = 0; b < 2; b++) begin : gen_predict
    entry_t entry1;
    entry_t entry2;
    logic hit1;
    logic hit2;
    riscv_pkg::tage_lookup_t result;
    assign entry1 = lookup_entry_q[0][b];
    assign entry2 = lookup_entry_q[1][b];
    assign hit1   = entry1.valid && (entry1.tag == lookup_tag_q[0][b]);
    assign hit2   = entry2.valid && (entry2.tag == lookup_tag_q[1][b]);
    always_comb begin
      result = '0;
      result.index1 = lookup_index_q[0][b];
      result.index2 = lookup_index_q[1][b];
      result.tag1 = lookup_tag_q[0][b];
      result.tag2 = lookup_tag_q[1][b];
      result.hit1 = hit1;
      result.hit2 = hit2;
      result.taken = hit2 ? entry2.ctr[CtrBits-1] : entry1.ctr[CtrBits-1];
      // T1 is the alternate only behind a T2 provider; otherwise the BTB and
      // bimodal direction is (the consumer supplies it).
      result.alt_tagged = hit1 && hit2;
      result.alt_tagged_taken = entry1.ctr[CtrBits-1];
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
  // entry the write stage is writing this cycle.
  entry_t read1;
  entry_t read2;
  entry_t write1;
  entry_t write2;
  assign read1 = (write_any[0] && (write_bank == i_train_bank) &&
                  (write_index[0] == i_train_lookup.index1)) ? write1 :
                 i_train_bank ? train_entry[0][1] : train_entry[0][0];
  assign read2 = (write_any[1] && (write_bank == i_train_bank) &&
                  (write_index[1] == i_train_lookup.index2)) ? write2 :
                 i_train_bank ? train_entry[1][1] : train_entry[1][0];

  // The write stage's registers. The valid has an initial value instead of a
  // reset because this module has none; the training port is idle in reset.
  logic train_valid_q = 1'b0;
  riscv_pkg::tage_lookup_t train_lookup_q;
  logic train_alt_taken_q;
  logic train_taken_q;
  logic train_mispredicted_q;
  entry_t cur1;  // the saved T1 and T2 entries
  entry_t cur2;
  always_ff @(posedge i_clk) begin
    train_valid_q        <= i_train_valid;
    train_lookup_q       <= i_train_lookup;
    write_bank           <= i_train_bank;
    train_alt_taken_q    <= i_train_alt_taken;
    train_taken_q        <= i_train_taken;
    train_mispredicted_q <= i_train_mispredicted;
    cur1                 <= read1;
    cur2                 <= read2;
  end
  assign write_index[0] = train_lookup_q.index1;
  assign write_index[1] = train_lookup_q.index2;

  // Write stage
  logic provider1, provider2;  // which table provided
  logic owned1, owned2;  // the saved entry still holds the branch
  logic useful_update;
  logic useful_value;
  logic candidate1, candidate2;
  logic alloc1, alloc2;
  logic useful_clear1, useful_clear2;

  assign provider2 = train_lookup_q.hit2;
  assign provider1 = train_lookup_q.hit1 && !train_lookup_q.hit2;
  assign owned1 = cur1.valid && (cur1.tag == train_lookup_q.tag1);
  assign owned2 = cur2.valid && (cur2.tag == train_lookup_q.tag2);
  assign useful_update = train_lookup_q.taken != train_alt_taken_q;
  assign useful_value = train_lookup_q.taken == train_taken_q;

  // Allocation above the provider: T1 only without a provider, T2 unless T2
  // provided.
  assign candidate1 = train_mispredicted_q && !provider1 && !provider2;
  assign candidate2 = train_mispredicted_q && !provider2;
  assign alloc1 = candidate1 && !owned1 && !cur1.useful;
  assign alloc2 = candidate2 && !alloc1 && !owned2 && !cur2.useful;
  assign useful_clear1 = candidate1 && !alloc1 && !alloc2;
  assign useful_clear2 = candidate2 && !alloc1 && !alloc2;

  always_comb begin
    write1 = cur1;
    if (provider1 && owned1) begin
      write1.ctr = counter_step(cur1.ctr, train_taken_q);
      if (useful_update) write1.useful = useful_value;
    end else if (alloc1) begin
      write1.valid = 1'b1;
      write1.tag = train_lookup_q.tag1;
      write1.ctr = train_taken_q ? CtrWeakTaken : CtrWeakNotTaken;
      write1.useful = 1'b0;
    end else if (useful_clear1) begin
      write1.useful = 1'b0;
    end
  end
  always_comb begin
    write2 = cur2;
    if (provider2 && owned2) begin
      write2.ctr = counter_step(cur2.ctr, train_taken_q);
      if (useful_update) write2.useful = useful_value;
    end else if (alloc2) begin
      write2.valid = 1'b1;
      write2.tag = train_lookup_q.tag2;
      write2.ctr = train_taken_q ? CtrWeakTaken : CtrWeakNotTaken;
      write2.useful = 1'b0;
    end else if (useful_clear2) begin
      write2.useful = 1'b0;
    end
  end
  assign write_entry[0] = write1;
  assign write_entry[1] = write2;
  assign write_any[0]   = train_valid_q && ((provider1 && owned1) || alloc1 || useful_clear1);
  assign write_any[1]   = train_valid_q && ((provider2 && owned2) || alloc2 || useful_clear2);

endmodule : tage_predictor
