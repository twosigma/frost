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
 * The tagged predictor's training write-back (tage_predictor.sv). A provider
 * whose entry in the training copy does not hold the branch has that entry
 * written back as read. The reference write enable below is the one without
 * the write-back: (provider && owned) || allocate || usefulness decrement.
 *
 * Inputs are free. The watched entry is any bank and index (the same for every
 * table), and the properties hold for each table's entry there.
 *
 * EQUAL_START = 1: the watched entry's two copies are equal at the start.
 *   - The copies stay equal: every write goes to both.
 *   - Every reference write is made, with the same data (one data net feeds
 *     both).
 *   - Where only the write-back writes the watched entry, it writes the value
 *     both copies hold, so the next contents of both copies equal the next
 *     contents under the reference write enable.
 *   - A training whose saved lookup names the table as provider writes the
 *     provider's entry.
 *   - The training read, which the next cycle's training registers take, equals
 *     the read under the reference write enable (its write-through compares
 *     the write enable).
 * Together: while the copies are equal, every table entry follows the same
 * next-state function as with the reference write enable, and so do the
 * training registers; the write data, the lookup path and every other
 * register are unchanged logic, so the predictor's state and outputs match
 * the predictor without the write-back cycle for cycle.
 *
 * EQUAL_START = 0: the watched entry's copies differ at the start. Once the
 * predictor writes the entry, its copies are equal. The table contents and
 * the training registers are arbitrary when the first write can come, so a
 * short bounded check covers that write from every state; equal copies then
 * stay equal by the EQUAL_START = 1 proof.
 */
module tage_copy_convergence_formal #(
    parameter bit EQUAL_START = 1'b1
) (
    input logic                                                     i_clk,
    input logic                    [  riscv_pkg::TageLookupHiBit:2] i_lookup_word,
    input logic                    [riscv_pkg::TageDirHistBits-1:0] i_lookup_hist,
    input logic                                                     i_lookup_capture,
    input logic                                                     i_train_valid,
    input riscv_pkg::tage_lookup_t                                  i_train_lookup,
    input logic                                                     i_train_bank,
    input logic                                                     i_train_alt_taken,
    input logic                                                     i_train_taken,
    input logic                                                     i_train_mispredicted,
    // The watched entry: free on the first cycle, then held.
    input logic                                                     i_watch_bank,
    input logic                    [  riscv_pkg::TageIndexBits-1:0] i_watch_index
);

  localparam int unsigned IndexBits = riscv_pkg::TageIndexBits;
  localparam int unsigned Tables = riscv_pkg::TageTables;
  // {valid, tag, 3-bit counter, 2-bit usefulness}, as tage_predictor's entry_t.
  localparam int unsigned EntryBits = 1 + riscv_pkg::TageTagBits + 3 + 2;

  tage_predictor dut (
      .i_clk,
      .i_lookup_word,
      .i_lookup_hist,
      .i_lookup_capture,
      .o_lookup_word(),
      .o_lookup_word_next(),
      .o_lookup_hist(),
      .o_bank0(),
      .o_bank1(),
      .i_train_valid,
      .i_train_lookup,
      .i_train_bank,
      .i_train_alt_taken,
      .i_train_taken,
      .i_train_mispredicted
  );

  logic f_bank;
  logic [IndexBits-1:0] f_index;
  logic f_bank_q;
  logic [IndexBits-1:0] f_index_q;
  assign f_bank  = i_watch_bank;
  assign f_index = i_watch_index;
  always_ff @(posedge i_clk) begin
    f_bank_q  <= i_watch_bank;
    f_index_q <= i_watch_index;
  end

  // The watched entry of each table, in the lookup copy and the training copy,
  // the reference write enable, and whether a write lands on the watched entry.
  logic [Tables-1:0][EntryBits-1:0] f_lookup;
  logic [Tables-1:0][EntryBits-1:0] f_train;
  logic [Tables-1:0] f_reference_write;
  logic [Tables-1:0] f_provider;
  logic [Tables-1:0] f_at_watched;
  for (genvar t = 0; t < Tables; t++) begin : gen_watch
    assign f_lookup[t] = f_bank ? dut.gen_bank[1].gen_table[t].u_lookup_copy.ram[f_index] :
                                  dut.gen_bank[0].gen_table[t].u_lookup_copy.ram[f_index];
    assign f_train[t] = f_bank ? dut.gen_bank[1].gen_table[t].u_train_copy.ram[f_index] :
                                 dut.gen_bank[0].gen_table[t].u_train_copy.ram[f_index];
    assign f_reference_write[t] = dut.train_valid_q &&
        ((dut.provider[t] && dut.owned[t]) || dut.alloc[t] ||
         (dut.useful_down[t] && (dut.gen_write[t].entry.useful != '0)));
    assign f_at_watched[t] = (dut.write_bank == f_bank) && (dut.write_index[t] == f_index);
  end
  assign f_provider = dut.provider;

  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;

  always_comb begin
    if (!f_past_valid) begin
      if (EQUAL_START) begin
        assume (f_lookup == f_train);
      end else begin
        assume (f_lookup != f_train);
      end
    end else begin
      assume (f_bank == f_bank_q && f_index == f_index_q);
    end
  end

  for (genvar t = 0; t < Tables; t++) begin : gen_table
    logic write_watched;
    logic reference_write_watched;
    logic written_q = 1'b0;
    logic [IndexBits-1:0] train_read_index;
    logic [EntryBits-1:0] training_read;
    logic [EntryBits-1:0] reference_read;
    assign write_watched = dut.write_any[t] && f_at_watched[t];
    assign reference_write_watched = f_reference_write[t] && f_at_watched[t];
    always_ff @(posedge i_clk) if (write_watched) written_q <= 1'b1;
    assign train_read_index = i_train_lookup.index[t];
    assign training_read = dut.read_entry[t];
    assign reference_read = (f_reference_write[t] && (dut.write_bank == i_train_bank) &&
                             (dut.write_index[t] == train_read_index)) ? dut.write_entry[t] :
        i_train_bank ? dut.train_entry[t][1] : dut.train_entry[t][0];

    always_comb begin
      if (f_past_valid) begin
        p_write_we_matches_bank : assert (!dut.write_we_q[t][!dut.write_bank]);
        p_reference_write_kept : assert (!f_reference_write[t] || dut.write_any[t]);
        p_provider_written : assert (!(dut.train_valid_q && f_provider[t]) || dut.write_any[t]);
      end
      if (EQUAL_START) begin
        p_copies_equal : assert (f_lookup[t] == f_train[t]);
        // The training registers hold what the previous edge read, so the
        // first cycle (any register state) is excluded.
        if (f_past_valid) begin
          p_next_train_matches_reference :
          assert ((write_watched ? dut.write_entry[t] : f_train[t]) ==
                  (reference_write_watched ? dut.write_entry[t] : f_train[t]));
          p_next_lookup_matches_reference :
          assert ((write_watched ? dut.write_entry[t] : f_lookup[t]) ==
                  (reference_write_watched ? dut.write_entry[t] : f_lookup[t]));
          p_training_read_matches_reference : assert (training_read == reference_read);
          // Non-vacuity: a write-back the reference does not make, with equal copies.
          c_writeback_equal_copies : cover (write_watched && !reference_write_watched);
        end
      end else begin
        p_written_copies_equal : assert (!written_q || (f_lookup[t] == f_train[t]));
        // A lookup-only entry replaced by the write-back.
        c_writeback_converges :
        cover (write_watched && !reference_write_watched && (f_lookup[t] != f_train[t]));
      end
    end
  end

endmodule : tage_copy_convergence_formal
