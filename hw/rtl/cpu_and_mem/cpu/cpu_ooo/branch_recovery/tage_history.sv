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
 * Path history and saved lookups for the tagged direction predictor
 * (if_stage/branch_prediction/tage_predictor.sv).
 *
 * Path history. Every taken control-flow instruction shifts the low two
 * word-address bits of its target, PC[3:2], into a 64-bit history. The
 * lookup history follows the fetch stream: pc_controller registers which
 * arm loaded the fetch PC, and the next cycle
 *   - a predicted-taken arm (slot 1 or slot 2) pushes the new fetch PC's
 *     bits, since the fetch PC now holds the target;
 *   - a redirect arm restores the history: a trap, xRET, or
 *     FENCE-class flush, and a misprediction recovered at commit, take the
 *     retirement history (everything older has retired, the recovered
 *     instruction included); a misprediction recovered early takes the
 *     branch's saved lookup history and pushes the new fetch PC if the branch
 *     was taken; a PD redirect does the same with the PD branch's lookup
 *     history and its new direction. Reset clears the history at its flop.
 * The lookup history is the registered history with that event applied, so
 * each lookup sees every older event, and a lookup never includes its own
 * branch.
 *
 * The retirement history applies the same pushes for retired taken
 * control-flow instructions, from the registered commit bus. The indirect
 * target predictor hashes this path history.
 *
 * Direction history (the tagged direction predictor's). Each conditional
 * branch shifts in its final predicted direction and each jump its predicted
 * target's bit 2, when PD
 * passes its packet to ID; the push is applied to the lookup the cycle after
 * (registered), so a lookup sees every packet PD passed up to two fetches
 * before it. Early recovery restores the branch's saved PD-time direction
 * history and shifts in its outcome; a trap, xRET, FENCE-class flush, or a
 * misprediction recovered at commit takes the retired direction history
 * (each retired branch's outcome and each jump's target bit 2), with the
 * same registered arms as the path history. A PD redirect needs no restore:
 * the redirecting branch was pushed with its new direction, and nothing
 * younger was passed.
 *
 * Saved lookups. When PD passes a packet with a conditional branch or a JALR
 * to ID, the instruction's lookup goes to the next entry of a circular
 * buffer: for a branch, whether the tagged lookup covered its word, the bank,
 * the indices, tags, matches, provider direction, the alternate direction,
 * and the lookup history; for a JALR that is not a return, the indirect
 * target predictor's lookup (indices, tags, matches); a return keeps only its
 * place. Dispatch
 * gives the branch the same index from a pointer of its own, since both see
 * the branches in program order, and records it by ROB tag. Early recovery
 * reads the branch's history from the entry; retirement trains the tagged
 * predictor, or for a JALR the indirect target predictor with its target,
 * from it, one instruction per cycle, holding a slot-2 branch for a cycle in which
 * slot 1 does not train (a newer one replaces it, and it is dropped if its
 * entry is reused first). Both pointers rewind past the recovered branch on
 * early recovery, and to the entry after the youngest retired branch on any
 * other pipeline flush, so live entries never exceed the branches in flight.
 */
module tage_history #(
    parameter int unsigned HIST_BITS = riscv_pkg::TageHistBits,
    parameter int unsigned PATH_BITS = riscv_pkg::TagePathBits,
    parameter int unsigned FTQ_IDX_BITS = riscv_pkg::TageFtqIdxBits,
    parameter int unsigned DIR_BITS = riscv_pkg::TageDirHistBits
) (
    input logic i_clk,
    input logic i_rst,

    // Fetch-side events registered in pc_controller, and the fetch PC's
    // [3:2] for a push.
    input  logic                 i_hist_push,
    input  logic [          4:1] i_hist_restore_arm,
    input  logic [PATH_BITS-1:0] i_fetch_pc_path_bits,
    output logic [HIST_BITS-1:0] o_lookup_hist,

    // PD passes a packet to ID (the PD-to-ID register loads a real packet).
    // Bit s of each per-slot vector is slot s + 1. A slot's flag marks a real
    // conditional branch; at most one is set.
    input  logic                                    i_pd_accept,
    input  logic                    [          1:0] i_pd_cond_branch,
    input  logic                    [          1:0] i_tage_slot_valid,
    input  riscv_pkg::tage_lookup_t                 i_tage_slot_lookup,
    input  riscv_pkg::tage_lookup_t                 i_tage_slot_lookup_2,
    input  logic                    [          1:0] i_tage_slot_bank,
    // The BTB and bimodal direction each slot's branch had before PD.
    input  logic                    [          1:0] i_base_taken,
    input  logic                    [HIST_BITS-1:0] i_tage_lookup_hist,
    // A slot's flag marks a real JALR (at most one per packet, never with a
    // conditional branch), and its lookup is saved when the indirect target
    // lookup covered it and it is not a return.
    input  logic                    [          1:0] i_pd_jalr,
    // A slot's flag marks a real conditional branch or jump (at most one per
    // packet), with the conditional branch's final predicted direction.
    input  logic                    [          1:0] i_pd_cf,
    input  logic                    [          1:0] i_pd_pred_taken,
    // The direction history for the tagged predictor's lookup.
    output logic                    [ DIR_BITS-1:0] o_lookup_dir_hist,
    input  logic                    [          1:0] i_itt_slot_valid,
    input  riscv_pkg::itt_lookup_t                  i_itt_slot_lookup,
    input  riscv_pkg::itt_lookup_t                  i_itt_slot_lookup_2,

    // The PD redirect's direction, sampled in its redirect cycle.
    input logic i_pd_redirect_taken,

    // Early recovery in its redirect cycle: the branch's ROB tag and outcome.
    input logic                                        i_early_active,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_early_tag,
    input logic                                        i_early_taken,
    // A flush of every in-flight instruction: a trap, xRET, or FENCE-class
    // flush, or a misprediction recovered at commit.
    input logic                                        i_flush_full,

    // Dispatch: each slot's ROB tag and whether it is a conditional branch
    // (at most one per bundle), and, registered a cycle later, which slots
    // were allocated.
    input logic [1:0][riscv_pkg::ReorderBufferTagWidth-1:0] i_alloc_tag,
    input logic [1:0]                                       i_alloc_cond_branch,
    input logic [1:0]                                       i_alloc_jalr,
    input logic [1:0]                                       i_alloc_q,

    // Registered commit bus, per slot.
    input logic [1:0]                                       i_commit_valid,
    input logic [1:0][riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_tag,
    input logic [1:0]                                       i_commit_cond_branch,
    input logic [1:0]                                       i_commit_taken_cf,
    input logic [1:0]                                       i_commit_taken,
    input logic [1:0]                                       i_commit_mispredicted,
    input logic [1:0][                       PATH_BITS-1:0] i_commit_target_bits,
    input logic [1:0]                                       i_commit_jalr,
    input logic [1:0]                                       i_commit_cf,
    input logic [1:0][         riscv_pkg::PhysAddrBits-2:0] i_commit_target,

    // Training port (tage_predictor).
    output logic                    o_train_valid,
    output riscv_pkg::tage_lookup_t o_train_lookup,
    output logic                    o_train_bank,
    output logic                    o_train_alt_taken,
    output logic                    o_train_taken,
    output logic                    o_train_mispredicted,

    // Indirect target training port (ittage_predictor).
    output logic                                                 o_itt_train_valid,
    output riscv_pkg::itt_lookup_t                               o_itt_train_lookup,
    output logic                                                 o_itt_train_bank,
    output logic                   [riscv_pkg::PhysAddrBits-2:0] o_itt_train_target,
    output logic                                                 o_itt_train_mispredicted
);

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) reset_seen_q <= 1'b1;
`endif

  localparam int unsigned RobDepth = riscv_pkg::ReorderBufferDepth;

  typedef struct packed {
    logic                    lookup_valid;
    logic                    bank;
    riscv_pkg::tage_lookup_t lookup;
    logic                    alt_taken;
    logic [HIST_BITS-1:0]    hist;
    logic                    is_jalr;
    logic                    itt_valid;
    riscv_pkg::itt_lookup_t  itt_lookup;
    logic [DIR_BITS-1:0]     dir_hist;
  } ftq_entry_t;
  localparam int unsigned FtqEntryBits = 5 + riscv_pkg::TageLookupBits + HIST_BITS +
      riscv_pkg::IttLookupBits + DIR_BITS;

  function automatic logic [DIR_BITS-1:0] push_dir(input logic [DIR_BITS-1:0] hist,
                                                   input logic bit_in);
    push_dir = {hist[DIR_BITS-2:0], bit_in};
  endfunction

  function automatic logic [HIST_BITS-1:0] push(input logic [HIST_BITS-1:0] hist,
                                                input logic [PATH_BITS-1:0] bits);
    push = {hist[HIST_BITS-PATH_BITS-1:0], bits};
  endfunction

  // ===========================================================================
  // Retirement history
  // ===========================================================================
  logic [HIST_BITS-1:0] retired_hist;
  logic [HIST_BITS-1:0] retired_hist_after_slot1;
  assign retired_hist_after_slot1 = (i_commit_valid[0] && i_commit_taken_cf[0]) ? push(
      retired_hist, i_commit_target_bits[0]
  ) : retired_hist;
  always_ff @(posedge i_clk) begin
    if (i_rst) retired_hist <= '0;
    else if (i_commit_valid[1] && i_commit_taken_cf[1])
      retired_hist <= push(retired_hist_after_slot1, i_commit_target_bits[1]);
    else retired_hist <= retired_hist_after_slot1;
  end

  // ===========================================================================
  // Saved lookups
  // ===========================================================================
  logic [FTQ_IDX_BITS-1:0] ftq_write_ptr;
  logic [FTQ_IDX_BITS-1:0] ftq_commit_ptr;
  logic [FTQ_IDX_BITS-1:0] ftq_idx_by_tag[RobDepth];

  // PD's accepted packet is registered as it is: its branch flags and both
  // slots' lookups. The next cycle the branch's entry is written at the write
  // pointer and the pointer advances, so the late branch decode of slot 2
  // never reaches the pointer.
  logic pd_accept_q;
  logic [1:0] pd_cond_branch_q;
  logic [1:0] pd_slot_valid_q;
  logic [1:0] pd_slot_bank_q;
  logic [1:0] pd_base_taken_q;
  riscv_pkg::tage_lookup_t pd_lookup_q;
  riscv_pkg::tage_lookup_t pd_lookup_2_q;
  logic [HIST_BITS-1:0] pd_lookup_hist_q;
  logic [1:0] pd_jalr_q;
  logic [DIR_BITS-1:0] dir_hist_q;  // speculative direction history (below)
  logic [1:0] pd_cf_q;
  logic [1:0] pd_pred_taken_q;
  logic [1:0] pd_itt_valid_q;
  riscv_pkg::itt_lookup_t pd_itt_lookup_q;
  riscv_pkg::itt_lookup_t pd_itt_lookup_2_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) pd_accept_q <= 1'b0;
    else pd_accept_q <= i_pd_accept;
    if (i_pd_accept) begin
      pd_jalr_q         <= i_pd_jalr;
      pd_cf_q           <= i_pd_cf;
      pd_pred_taken_q   <= i_pd_pred_taken;
      pd_itt_valid_q    <= i_itt_slot_valid;
      pd_itt_lookup_q   <= i_itt_slot_lookup;
      pd_itt_lookup_2_q <= i_itt_slot_lookup_2;
      pd_cond_branch_q  <= i_pd_cond_branch;
      pd_slot_valid_q   <= i_tage_slot_valid;
      pd_slot_bank_q    <= i_tage_slot_bank;
      pd_base_taken_q   <= i_base_taken;
      pd_lookup_q       <= i_tage_slot_lookup;
      pd_lookup_2_q     <= i_tage_slot_lookup_2;
      pd_lookup_hist_q  <= i_tage_lookup_hist;
    end
  end

  logic pd_entry_pending;
  logic pd_branch_slot;
  riscv_pkg::tage_lookup_t pd_branch_lookup;
  ftq_entry_t pd_entry;
  assign pd_entry_pending = pd_accept_q && (pd_cond_branch_q[0] || pd_cond_branch_q[1] ||
                                             pd_jalr_q[0] || pd_jalr_q[1]);
  assign pd_branch_slot = !(pd_cond_branch_q[0] || pd_jalr_q[0]);
  assign pd_branch_lookup = pd_branch_slot ? pd_lookup_2_q : pd_lookup_q;
  always_comb begin
    pd_entry = '0;
    pd_entry.lookup_valid = pd_slot_valid_q[pd_branch_slot];
    pd_entry.bank = pd_slot_bank_q[pd_branch_slot];
    pd_entry.lookup = pd_branch_lookup;
    pd_entry.alt_taken = pd_branch_lookup.alt_tagged ? pd_branch_lookup.alt_tagged_taken :
                                                       pd_base_taken_q[pd_branch_slot];
    pd_entry.hist = pd_lookup_hist_q;
    pd_entry.is_jalr = pd_jalr_q[pd_branch_slot];
    pd_entry.itt_valid = pd_itt_valid_q[pd_branch_slot];
    pd_entry.itt_lookup = pd_branch_slot ? pd_itt_lookup_2_q : pd_itt_lookup_q;
    pd_entry.dir_hist = dir_hist_q;
  end

  logic [FtqEntryBits-1:0] ftq_read_early_raw;
  logic [FtqEntryBits-1:0] ftq_read_train_raw;
  logic [FTQ_IDX_BITS-1:0] early_ftq_idx;
  logic [FTQ_IDX_BITS-1:0] train_read_idx;
  assign early_ftq_idx = ftq_idx_by_tag[i_early_tag];
  sdp_dist_ram #(
      .ADDR_WIDTH(FTQ_IDX_BITS),
      .DATA_WIDTH(FtqEntryBits)
  ) u_ftq_early (
      .i_clk,
      .i_write_enable(pd_entry_pending),
      .i_write_address(ftq_write_ptr),
      .i_read_address(early_ftq_idx),
      .i_write_data(pd_entry),
      .o_read_data(ftq_read_early_raw)
  );
  sdp_dist_ram #(
      .ADDR_WIDTH(FTQ_IDX_BITS),
      .DATA_WIDTH(FtqEntryBits)
  ) u_ftq_train (
      .i_clk,
      .i_write_enable(pd_entry_pending),
      .i_write_address(ftq_write_ptr),
      .i_read_address(train_read_idx),
      .i_write_data(pd_entry),
      .o_read_data(ftq_read_train_raw)
  );

  // Dispatch gives each conditional branch the next index from its own
  // pointer and records it by ROB tag. PD and dispatch see the same branches
  // in the same order, and every flush that drops branches between them
  // rewinds both pointers to the same entry (below). Dispatch's data is
  // registered and acts the next cycle with the registered allocation, which
  // keeps the dispatch decision out of this logic; the first read of a tag,
  // its early recovery, comes two or more cycles after dispatch.
  logic [FTQ_IDX_BITS-1:0] ftq_dispatch_ptr;
  logic [1:0] alloc_cond_branch_q;
  logic [1:0][riscv_pkg::ReorderBufferTagWidth-1:0] alloc_tag_q;
  logic alloc_branch;
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] alloc_branch_tag;
  always_ff @(posedge i_clk) begin
    // A JALR takes an entry like a conditional branch.
    alloc_cond_branch_q <= i_alloc_cond_branch | i_alloc_jalr;
    alloc_tag_q         <= i_alloc_tag;
  end
  assign alloc_branch = (i_alloc_q[0] && alloc_cond_branch_q[0]) ||
                        (i_alloc_q[1] && alloc_cond_branch_q[1]);
  assign alloc_branch_tag = (i_alloc_q[0] && alloc_cond_branch_q[0]) ? alloc_tag_q[0] :
                                                                       alloc_tag_q[1];
  always_ff @(posedge i_clk) begin
    if (alloc_branch) ftq_idx_by_tag[alloc_branch_tag] <= ftq_dispatch_ptr;
  end
`ifndef SYNTHESIS
  always @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && alloc_branch) begin
      p_early_read_after_index_write : assert (!i_early_active || alloc_branch_tag != i_early_tag);
      p_commit_read_after_index_write :
      assert (!(i_commit_valid[0] && alloc_branch_tag == i_commit_tag[0]) &&
              !(i_commit_valid[1] && alloc_branch_tag == i_commit_tag[1]));
    end
  end
`endif

  // The youngest retired branch's entry and every older one are free.
  logic [1:0] commit_branch;
  logic [1:0][FTQ_IDX_BITS-1:0] commit_ftq_idx;
  assign commit_branch[0]  = i_commit_valid[0] && (i_commit_cond_branch[0] || i_commit_jalr[0]);
  assign commit_branch[1]  = i_commit_valid[1] && (i_commit_cond_branch[1] || i_commit_jalr[1]);
  assign commit_ftq_idx[0] = ftq_idx_by_tag[i_commit_tag[0]];
  assign commit_ftq_idx[1] = ftq_idx_by_tag[i_commit_tag[1]];
  always_ff @(posedge i_clk) begin
    if (i_rst) ftq_commit_ptr <= '0;
    else if (commit_branch[1]) ftq_commit_ptr <= commit_ftq_idx[1] + 1'b1;
    else if (commit_branch[0]) ftq_commit_ptr <= commit_ftq_idx[0] + 1'b1;
  end

  // A rewind also flushes the packet or dispatch whose advance is pending,
  // so it drops that advance. A full flush removes every in-flight branch, so
  // it wins over a simultaneous early recovery.
  always_ff @(posedge i_clk) begin
    if (i_rst) ftq_write_ptr <= '0;
    else if (i_flush_full) ftq_write_ptr <= ftq_commit_ptr;
    else if (i_early_active) ftq_write_ptr <= early_ftq_idx + 1'b1;
    else if (pd_entry_pending) ftq_write_ptr <= ftq_write_ptr + 1'b1;
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) ftq_dispatch_ptr <= '0;
    else if (i_flush_full) ftq_dispatch_ptr <= ftq_commit_ptr;
    else if (i_early_active) ftq_dispatch_ptr <= early_ftq_idx + 1'b1;
    else if (alloc_branch) ftq_dispatch_ptr <= ftq_dispatch_ptr + 1'b1;
  end

  // ===========================================================================
  // Lookup history
  // ===========================================================================
  // Restore sources sampled in the redirect cycle, used the cycle after it
  // with the registered arm.
  logic [HIST_BITS-1:0] hist_q;
  logic [HIST_BITS-1:0] pd_hist_q;
  logic pd_taken_q;
  logic [HIST_BITS-1:0] early_hist_q;
  logic [DIR_BITS-1:0] early_dir_hist_q;
  logic early_q;
  logic early_taken_q;
  ftq_entry_t ftq_read_early;
  assign ftq_read_early = ftq_read_early_raw;
  always_ff @(posedge i_clk) begin
    pd_hist_q        <= pd_lookup_hist_q;
    pd_taken_q       <= i_pd_redirect_taken;
    early_hist_q     <= ftq_read_early.hist;
    early_dir_hist_q <= ftq_read_early.dir_hist;
    early_q          <= i_early_active;
    early_taken_q    <= i_early_taken;
  end

  // Arms, highest priority first: 1 trap or xRET, 2 FENCE-class flush,
  // 3 misprediction recovery, 4 PD redirect. At most one is set.
  logic [HIST_BITS-1:0] restore_base;
  logic restore_push;
  always_comb begin
    restore_base = hist_q;
    restore_push = i_hist_push;
    if (i_hist_restore_arm[1] || i_hist_restore_arm[2]) begin
      restore_base = retired_hist;
      restore_push = 1'b0;
    end else if (i_hist_restore_arm[3]) begin
      restore_base = early_q ? early_hist_q : retired_hist;
      restore_push = early_q && early_taken_q;
    end else if (i_hist_restore_arm[4]) begin
      restore_base = pd_hist_q;
      restore_push = pd_taken_q;
    end
  end
  assign o_lookup_hist = restore_push ? push(restore_base, i_fetch_pc_path_bits) : restore_base;
  always_ff @(posedge i_clk) begin
    if (i_rst) hist_q <= '0;
    else hist_q <= o_lookup_hist;
  end

  // ===========================================================================
  // Direction history
  // ===========================================================================
  // Retired: each retired conditional branch's outcome and each jump's
  // target bit 2, slot 1 then slot 2.
  logic [DIR_BITS-1:0] retired_dir_hist;
  logic [DIR_BITS-1:0] retired_dir_after_slot1;
  logic [1:0] retired_dir_bit;
  assign retired_dir_bit[0] = i_commit_cond_branch[0] ? i_commit_taken[0] :
                                                         i_commit_target_bits[0][0];
  assign retired_dir_bit[1] = i_commit_cond_branch[1] ? i_commit_taken[1] :
                                                         i_commit_target_bits[1][0];
  assign retired_dir_after_slot1 = (i_commit_valid[0] && i_commit_cf[0]) ? push_dir(
      retired_dir_hist, retired_dir_bit[0]
  ) : retired_dir_hist;
  always_ff @(posedge i_clk) begin
    if (i_rst) retired_dir_hist <= '0;
    else if (i_commit_valid[1] && i_commit_cf[1])
      retired_dir_hist <= push_dir(retired_dir_after_slot1, retired_dir_bit[1]);
    else retired_dir_hist <= retired_dir_after_slot1;
  end

  // Speculative: the packet PD passed, registered (pd_*_q), pushes its
  // control-flow instruction's bit; the restore arms override it.
  logic pd_dir_push;
  logic pd_dir_bit;
  logic [DIR_BITS-1:0] dir_base;
  logic dir_push;
  assign pd_dir_push = pd_accept_q && (pd_cf_q[0] || pd_cf_q[1]);
  assign pd_dir_bit  = pd_cf_q[0] ? pd_pred_taken_q[0] : pd_pred_taken_q[1];
  always_comb begin
    dir_base = dir_hist_q;
    dir_push = pd_dir_push;
    if (i_hist_restore_arm[1] || i_hist_restore_arm[2]) begin
      dir_base = retired_dir_hist;
      dir_push = 1'b0;
    end else if (i_hist_restore_arm[3]) begin
      dir_base = early_q ? push_dir(early_dir_hist_q, early_taken_q) : retired_dir_hist;
      dir_push = 1'b0;
    end
  end
  assign o_lookup_dir_hist = dir_push ? push_dir(dir_base, pd_dir_bit) : dir_base;
  always_ff @(posedge i_clk) begin
    if (i_rst) dir_hist_q <= '0;
    else dir_hist_q <= o_lookup_dir_hist;
  end

  // ===========================================================================
  // Training
  // ===========================================================================
  // Slot 1 trains first; a slot-2 branch waits in a one-deep hold for a cycle
  // without slot-1 training, and a newer one replaces it. Its entry is free
  // once it retires, so the hold is dropped when a new branch's entry is
  // written over it.
  logic held_valid;
  logic [FTQ_IDX_BITS-1:0] held_idx;
  logic held_taken;
  logic held_mispredicted;
  logic [riscv_pkg::PhysAddrBits-2:0] held_target;
  logic train_sel_valid;
  logic [FTQ_IDX_BITS-1:0] train_sel_idx;
  logic train_sel_taken;
  logic train_sel_mispredicted;
  logic [riscv_pkg::PhysAddrBits-2:0] train_sel_target;
  always_comb begin
    train_sel_valid = 1'b0;
    train_sel_idx = commit_ftq_idx[0];
    train_sel_taken = i_commit_taken[0];
    train_sel_mispredicted = i_commit_mispredicted[0];
    train_sel_target = i_commit_target[0];
    if (commit_branch[0]) begin
      train_sel_valid = 1'b1;
    end else if (held_valid) begin
      train_sel_valid = 1'b1;
      train_sel_idx = held_idx;
      train_sel_taken = held_taken;
      train_sel_mispredicted = held_mispredicted;
      train_sel_target = held_target;
    end else if (commit_branch[1]) begin
      train_sel_valid = 1'b1;
      train_sel_idx = commit_ftq_idx[1];
      train_sel_taken = i_commit_taken[1];
      train_sel_mispredicted = i_commit_mispredicted[1];
      train_sel_target = i_commit_target[1];
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      held_valid <= 1'b0;
    end else if (commit_branch[1] && (commit_branch[0] || held_valid)) begin
      held_valid <= 1'b1;
      held_idx <= commit_ftq_idx[1];
      held_taken <= i_commit_taken[1];
      held_mispredicted <= i_commit_mispredicted[1];
      held_target <= i_commit_target[1];
    end else if (held_valid && !commit_branch[0]) begin
      held_valid <= 1'b0;
    end else if (pd_entry_pending && (ftq_write_ptr == held_idx)) begin
      held_valid <= 1'b0;
    end
  end

  // Read the entry, then train the next cycle from registers.
  assign train_read_idx = train_sel_idx;
  ftq_entry_t ftq_read_train;
  assign ftq_read_train = ftq_read_train_raw;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_train_valid     <= 1'b0;
      o_itt_train_valid <= 1'b0;
    end else begin
      o_train_valid <= train_sel_valid && ftq_read_train.lookup_valid && !ftq_read_train.is_jalr;
      o_itt_train_valid <= train_sel_valid && ftq_read_train.itt_valid && ftq_read_train.is_jalr;
    end
    o_itt_train_lookup       <= ftq_read_train.itt_lookup;
    o_itt_train_bank         <= ftq_read_train.bank;
    o_itt_train_target       <= train_sel_target;
    o_itt_train_mispredicted <= train_sel_mispredicted;
    o_train_lookup           <= ftq_read_train.lookup;
    o_train_bank             <= ftq_read_train.bank;
    o_train_alt_taken        <= ftq_read_train.alt_taken;
    o_train_taken            <= train_sel_taken;
    o_train_mispredicted     <= train_sel_mispredicted;
  end

`ifdef TAGE_HISTORY_RECOVERY_PROOF
  // Retirement is a two-slot fold in program order. Keep an independent
  // reference so a restore checks every bit, including older retirements.
  logic f_past_valid = 1'b0;
  logic [HIST_BITS-1:0] f_path, f_path_next;
  logic [DIR_BITS-1:0] f_dir, f_dir_next;
  always_comb begin
    f_path_next = f_path;
    f_dir_next  = f_dir;
    for (int s = 0; s < 2; s++) begin
      if (i_commit_valid[s] && i_commit_taken_cf[s])
        f_path_next = {f_path_next[HIST_BITS-PATH_BITS-1:0], i_commit_target_bits[s]};
      if (i_commit_valid[s] && i_commit_cf[s])
        f_dir_next = {
          f_dir_next[DIR_BITS-2:0],
          i_commit_cond_branch[s] ? i_commit_taken[s] : i_commit_target_bits[s][0]
        };
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      f_path <= '0;
      f_dir  <= '0;
    end else begin
      f_path <= f_path_next;
      f_dir  <= f_dir_next;
    end
  end

  // Record the PD input independently. The direction bit enters the lookup
  // one edge after acceptance; the path on a PD redirect is the captured
  // lookup history a further edge later.
  logic [HIST_BITS-1:0] f_accepted_path, f_pd_path;
  logic f_accepted = 1'b0;
  logic f_pd_path_known = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_pd_accept) f_accepted_path <= i_tage_lookup_hist;
    if (i_rst) f_accepted <= 1'b0;
    else if (i_pd_accept) f_accepted <= 1'b1;
    f_pd_path <= f_accepted_path;
    f_pd_path_known <= f_accepted;
  end

  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (f_past_valid) begin
      p_retired_path : assert (retired_hist == f_path);
      p_retired_direction : assert (retired_dir_hist == f_dir);
      if (f_accepted) begin
        p_pd_input_snapshot : assert (f_accepted_path == pd_lookup_hist_q);
      end
      if (f_pd_path_known) begin
        p_pd_redirect_snapshot : assert (f_pd_path == pd_hist_q);
      end
      if (i_hist_restore_arm[1] || i_hist_restore_arm[2] || (i_hist_restore_arm[3] && !$past(
              i_early_active
          ))) begin
        p_full_restore : assert ({o_lookup_hist, o_lookup_dir_hist} == {f_path, f_dir});
      end else if (i_hist_restore_arm[3]) begin
        if ($past(i_early_taken)) begin
          p_early_taken_path :
          assert (o_lookup_hist == {$past(
              ftq_read_early.hist[HIST_BITS-PATH_BITS-1:0]
          ), i_fetch_pc_path_bits});
        end else begin
          p_early_not_taken_path : assert (o_lookup_hist == $past(ftq_read_early.hist));
        end
        p_early_direction :
        assert (o_lookup_dir_hist == {$past(
            ftq_read_early.dir_hist[DIR_BITS-2:0]
        ), $past(
            i_early_taken
        )});
      end else begin
        if ($past(!i_rst && i_pd_accept && (|i_pd_cf))) begin
          p_accepted_direction :
          assert (o_lookup_dir_hist == {$past(
              o_lookup_dir_hist[DIR_BITS-2:0]
          ), $past(
              i_pd_cf[0] ? i_pd_pred_taken[0] : i_pd_pred_taken[1]
          )});
        end else begin
          p_idle_direction :
          assert (o_lookup_dir_hist == ($past(i_rst) ? '0 : $past(o_lookup_dir_hist)));
        end
        if (i_hist_restore_arm[4]) begin
          if (f_pd_path_known) begin
            p_pd_path :
            assert (o_lookup_hist == ($past(
                i_pd_redirect_taken
            ) ? {f_pd_path[HIST_BITS-PATH_BITS-1:0], i_fetch_pc_path_bits} : f_pd_path));
          end
        end else if (i_hist_push) begin
          p_predicted_path :
          assert (o_lookup_hist == {($past(
              i_rst
          ) ? {(HIST_BITS - PATH_BITS) {1'b0}} : $past(
              o_lookup_hist[HIST_BITS-PATH_BITS-1:0]
          )), i_fetch_pc_path_bits});
        end else begin
          p_idle_path : assert (o_lookup_hist == ($past(i_rst) ? '0 : $past(o_lookup_hist)));
        end
      end
      if (pd_entry_pending) begin
        p_save_accepted_path : assert (pd_entry.hist == $past(i_tage_lookup_hist));
        p_save_prebranch_direction : assert (pd_entry.dir_hist == $past(o_lookup_dir_hist));
      end
      cover (i_hist_restore_arm == 4'b0001 && f_dir != '0 && f_path != '0);
      cover (i_hist_restore_arm == 4'b0010 && f_dir != '0 && f_path != '0);
      cover (i_hist_restore_arm == 4'b0100 && !$past(i_early_active) && f_dir != '0);
      cover (i_hist_restore_arm == 4'b0100 && $past(i_early_active && i_early_taken));
      cover (i_hist_restore_arm == 4'b0100 && $past(i_early_active && !i_early_taken));
      cover (i_hist_restore_arm == 4'b1000 && f_pd_path_known && $past(i_pd_redirect_taken));
      cover ($past(i_commit_valid == 2'b11 && i_commit_cf == 2'b11) && f_dir[1:0] == 2'b10);
      cover ($past(!i_rst && i_pd_accept && i_pd_cf == 2'b10) && o_lookup_dir_hist[0]);
    end
  end
`endif

endmodule : tage_history
