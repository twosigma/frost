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

package pd_history_twin_pkg;
  localparam int unsigned FtqEntryBits = 5 + riscv_pkg::TageLookupBits + riscv_pkg::TageHistBits +
                                        riscv_pkg::IttLookupBits + riscv_pkg::TageDirHistBits;

  typedef struct packed {
    riscv_pkg::pipeline_ctrl_t pipeline_ctrl;
    riscv_pkg::from_if_to_pd_t from_if_to_pd;
    riscv_pkg::from_if_to_pd_t from_if_to_pd_2;
    logic [1:0] backing_hit;
    logic [1:0] backing_compressed;
    logic [1:0] backing_return;
    logic [1:0][riscv_pkg::PhysAddrBits-2:0] backing_target;
    logic [1:0] backing_slot2_return_by_size;
    logic [1:0][riscv_pkg::PhysAddrBits-2:0] backing_slot2_target_by_size;
    logic [1:0] itt_hit;
    logic [1:0][riscv_pkg::PhysAddrBits-2:0] itt_target;
    logic hist_push;
    logic [4:1] hist_restore_arm;
    logic [riscv_pkg::TagePathBits-1:0] fetch_pc_path_bits;
    logic [1:0] tage_slot_valid;
    riscv_pkg::tage_lookup_t tage_slot_lookup;
    riscv_pkg::tage_lookup_t tage_slot_lookup_2;
    logic [riscv_pkg::TageHistBits-1:0] tage_lookup_hist;
    riscv_pkg::itt_lookup_t itt_slot_lookup;
    riscv_pkg::itt_lookup_t itt_slot_lookup_2;
    logic early_active;
    logic [riscv_pkg::ReorderBufferTagWidth-1:0] early_tag;
    logic early_taken;
    logic flush_full;
    logic [1:0][riscv_pkg::ReorderBufferTagWidth-1:0] alloc_tag;
    logic [1:0] alloc_cond_branch;
    logic [1:0] alloc_jalr;
    logic [1:0] alloc_q;
    logic [1:0] commit_valid;
    logic [1:0][riscv_pkg::ReorderBufferTagWidth-1:0] commit_tag;
    logic [1:0] commit_cond_branch;
    logic [1:0] commit_taken_cf;
    logic [1:0] commit_taken;
    logic [1:0] commit_mispredicted;
    logic [1:0][riscv_pkg::TagePathBits-1:0] commit_target_bits;
    logic [1:0] commit_jalr;
    logic [1:0] commit_cf;
    logic [1:0][riscv_pkg::PhysAddrBits-2:0] commit_target;
    logic [1:0][FtqEntryBits-1:0] ftq_read;
  } inputs_t;

  typedef struct packed {
    riscv_pkg::from_pd_to_id_t from_pd_to_id;
    riscv_pkg::from_pd_to_id_t from_pd_to_id_2;
    logic pd_redirect;
    logic pd_redirect_taken;
    logic [riscv_pkg::XLEN-1:0] pd_redirect_target;
    logic pd_redirect_slot2;
    logic pd_redirect_ras_push;
    logic pd_redirect_ras_pop;
    logic [riscv_pkg::XLEN-1:0] pd_redirect_ras_link;
    logic pd_backing_refresh;
    logic [riscv_pkg::XLEN-1:0] pd_backing_refresh_pc;
    logic [riscv_pkg::TageHistBits-1:0] lookup_hist;
    logic [riscv_pkg::TageDirHistBits-1:0] lookup_dir_hist;
    logic train_valid;
    riscv_pkg::tage_lookup_t train_lookup;
    logic train_bank;
    logic train_alt_taken;
    logic train_taken;
    logic train_mispredicted;
    logic itt_train_valid;
    riscv_pkg::itt_lookup_t itt_train_lookup;
    logic itt_train_bank;
    logic [riscv_pkg::PhysAddrBits-2:0] itt_train_target;
    logic itt_train_mispredicted;
    logic [riscv_pkg::TageTables-1:0][riscv_pkg::TageIndexBits-1:0] lookup_dir_fold;
    logic [1:0] write_enable;
    logic [1:0][riscv_pkg::TageFtqIdxBits-1:0] write_index;
    logic [1:0][riscv_pkg::TageFtqIdxBits-1:0] read_index;
    logic [1:0][FtqEntryBits-1:0] write_data;
  } outputs_t;

  typedef struct packed {
    logic pd_accept_q;
    logic [1:0] pd_slot_valid_q;
    logic [1:0] pd_slot_bank_q;
    logic [1:0] pd_base_taken_q;
    riscv_pkg::tage_lookup_t pd_lookup_q;
    riscv_pkg::tage_lookup_t pd_lookup_2_q;
    riscv_pkg::itt_lookup_t pd_itt_lookup_q;
    riscv_pkg::itt_lookup_t pd_itt_lookup_2_q;
    logic [riscv_pkg::TageHistBits-1:0] pd_lookup_hist_q;
    logic [riscv_pkg::TageFtqIdxBits-1:0] ftq_write_ptr;
    logic [riscv_pkg::TageFtqIdxBits-1:0] ftq_dispatch_ptr;
    logic [riscv_pkg::TageFtqIdxBits-1:0] ftq_commit_ptr;
    logic [1:0] alloc_cond_branch_q;
    logic [1:0][riscv_pkg::ReorderBufferTagWidth-1:0] alloc_tag_q;
    logic [riscv_pkg::TageHistBits-1:0] hist_q;
    logic [riscv_pkg::TageHistBits-1:0] retired_hist;
    logic [riscv_pkg::TageDirHistBits-1:0] dir_hist_q;
    logic [riscv_pkg::TageDirHistBits-1:0] retired_dir_hist;
    logic [riscv_pkg::TageHistBits-1:0] pd_hist_q;
    logic [riscv_pkg::TageHistBits-1:0] early_hist_q;
    logic [riscv_pkg::TageDirHistBits-1:0] early_dir_hist_q;
    logic early_q;
    logic early_taken_q;
    logic held_valid;
    logic [riscv_pkg::TageFtqIdxBits-1:0] held_idx;
    logic held_taken;
    logic held_mispredicted;
    logic [riscv_pkg::PhysAddrBits-2:0] held_target;
    logic [riscv_pkg::ReorderBufferDepth-1:0][riscv_pkg::TageFtqIdxBits-1:0] tag_indices;
    logic [1:0] accepted_cond;
    logic [1:0] accepted_jalr;
    logic [1:0] accepted_itt_valid;
    logic [1:0] accepted_cf;
    logic [1:0] accepted_taken;
    logic [riscv_pkg::TageTables-1:0][riscv_pkg::TageIndexBits-1:0] spec_fold;
    logic [riscv_pkg::TageTables-1:0][riscv_pkg::TageIndexBits-1:0] retired_fold;
    logic [riscv_pkg::TageTables-1:0][riscv_pkg::TageIndexBits-1:0] early_fold;
  } state_t;

endpackage
