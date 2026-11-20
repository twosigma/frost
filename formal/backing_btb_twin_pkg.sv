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

package backing_btb_twin_pkg;
  localparam int unsigned Ways = riscv_pkg::BackingBtbWays;
  localparam int unsigned IndexBits = $clog2(riscv_pkg::BackingBtbEntries / Ways);
  localparam int unsigned UpperBits = riscv_pkg::XLEN - IndexBits - 2;
  typedef logic [IndexBits-1:0] index_t;
  typedef logic [riscv_pkg::XLEN-1:0] pc_t;
  typedef logic [riscv_pkg::PhysAddrBits-2:0] target_t;
  typedef logic [Ways*(UpperBits+4)-1:0] tags_t;
  typedef logic [Ways*$bits(target_t)-1:0] payload_t;
  typedef logic [Ways-1+$bits(tags_t)+$bits(payload_t)-1:0] set_t;

  typedef struct packed {
    set_t update_row;
    tags_t [1:0] tags;
    payload_t [1:0] payloads;
  } rows_t;
  typedef struct packed {
    logic reset, redirect;
    index_t lookup_index;
    pc_t packet_pc;
    logic packet_compressed, update;
    pc_t update_pc, update_target;
    logic update_compressed, update_return, refresh;
    pc_t refresh_pc;
    rows_t read_rows;
  } inputs_t;
  typedef struct packed {
    logic [1:0] hit, compressed, is_return, slot2_return_by_size;
    target_t [1:0] target, slot2_target_by_size;
  } predictions_t;
  typedef struct packed {
    logic [4:0] write_enable;
    logic [2:0] bulk_clear;
    index_t [4:0] read_index, write_index;
    rows_t write_data;
  } ram_pins_t;
  typedef struct packed {
    logic valid, refresh;
    index_t index;
    logic [UpperBits-1:0] upper_bits;
    logic halfword;
    target_t target;
    logic region_ok, compressed, is_return;
  } request_t;
  typedef struct packed {
    logic sweep_active;
    index_t sweep_index;
    request_t a, b, c;
    set_t c_set, forward_set;
    logic c_hit, b_forward;
    logic [$clog2(Ways)-1:0] c_way;
    logic request_valid, held_valid;
    index_t request_index, held_index;
    tags_t [1:0] tags, held_tags;
    payload_t [1:0] held_payloads;
  } state_t;
endpackage
