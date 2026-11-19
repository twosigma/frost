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

package predictor_table_twin_pkg;
`ifdef PREDICTOR_TWIN_DIRECTION
  localparam int unsigned Tables = riscv_pkg::TageTables;
  localparam int unsigned IndexBits = riscv_pkg::TageIndexBits;
  localparam int unsigned TagBits = riscv_pkg::TageTagBits;
  localparam int unsigned HistBits = riscv_pkg::TageDirHistBits;
  localparam int unsigned EntryBits = 1 + TagBits + 3 + 2;
  localparam int unsigned WordRegBits = 2 * (riscv_pkg::TageLookupHiBit - 1);
  typedef riscv_pkg::tage_lookup_t lookup_t;
`else
  localparam int unsigned Tables = 3;
  localparam int unsigned IndexBits = riscv_pkg::IttIndexBits;
  localparam int unsigned TagBits = riscv_pkg::IttTagBits;
  localparam int unsigned HistBits = riscv_pkg::TageHistBits;
  localparam int unsigned EntryBits = TagBits + riscv_pkg::PhysAddrBits + 3;
  localparam int unsigned WordRegBits = 0;
  typedef riscv_pkg::itt_lookup_t lookup_t;
`endif
  localparam int unsigned LookupRegBits =
      WordRegBits + HistBits + 2 * Tables * (EntryBits + IndexBits + TagBits);
  typedef logic [Tables-1:0][1:0][1:0][EntryBits-1:0] ram_rows_t;
  typedef logic [Tables-1:0][1:0][1:0][IndexBits-1:0] ram_indices_t;
  typedef struct packed {
    logic [riscv_pkg::TageLookupHiBit:2] lookup_word;
    logic [HistBits-1:0] lookup_hist;
    logic lookup_capture;
    logic train_valid;
    lookup_t train_lookup;
    logic train_bank;
    logic train_mispredicted;
`ifdef PREDICTOR_TWIN_DIRECTION
    logic train_alt_taken;
    logic train_taken;
`else
    logic [riscv_pkg::PhysAddrBits-2:0] train_target;
`endif
    ram_rows_t read_rows;
  } inputs_t;
  typedef struct packed {
    logic [HistBits-1:0] lookup_hist;
    lookup_t bank0;
    lookup_t bank1;
`ifdef PREDICTOR_TWIN_DIRECTION
    logic [riscv_pkg::TageLookupHiBit:2] lookup_word, lookup_word_next;
`else
    logic [1:0] hit;
    logic [1:0][riscv_pkg::PhysAddrBits-2:0] target;
`endif
    logic [Tables-1:0][1:0][1:0] write_enable;
    ram_indices_t read_index, write_index;
    ram_rows_t write_data;
  } outputs_t;
  typedef struct packed {
    logic capture;
    logic [LookupRegBits-1:0] fresh, held;
    logic [Tables-1:0][EntryBits-1:0] current_rows;
    logic train_valid, write_bank, mispredicted;
    lookup_t train_lookup;
    logic [Tables-1:0] provider, above, owned;
`ifdef PREDICTOR_TWIN_DIRECTION
    logic taken, useful_update, useful_value;
`else
    logic [riscv_pkg::PhysAddrBits-2:0] target;
    logic [Tables-1:0] correct;
`endif
  } state_t;
endpackage
