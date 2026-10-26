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
 *   - a redirect arm restores the history: reset clears it; a trap, xRET, or
 *     FENCE-class flush, and a misprediction recovered at commit, take the
 *     retirement history (everything older has retired, the recovered
 *     instruction included); a misprediction recovered early takes the
 *     branch's saved lookup history and pushes the new fetch PC if the branch
 *     was taken; a PD redirect does the same with the PD branch's lookup
 *     history and its new direction.
 * The lookup history is the registered history with that event applied, so
 * each lookup sees every older event, and a lookup never includes its own
 * branch.
 *
 * The retirement history applies the same pushes for retired taken
 * control-flow instructions, from the registered commit bus.
 *
 * Saved lookups. When PD passes a packet with a conditional branch to ID,
 * the branch's lookup (whether it covered the branch's word, the bank, the
 * indices, tags, matches, provider direction, the alternate direction, and
 * the lookup history) goes to the next entry of a circular buffer. Dispatch
 * gives the branch the same index from a pointer of its own, since both see
 * the branches in program order, and records it by ROB tag. Early recovery
 * reads the branch's history from the entry; retirement trains the predictor
 * from it, one branch per cycle, holding a slot-2 branch for a cycle in which
 * slot 1 does not train (a newer one replaces it, and it is dropped if its
 * entry is reused first). Both pointers rewind past the recovered branch on
 * early recovery, and to the entry after the youngest retired branch on any
 * other pipeline flush, so live entries never exceed the branches in flight.
 */
module tage_history #(
    parameter int unsigned HIST_BITS = riscv_pkg::TageHistBits,
    parameter int unsigned PATH_BITS = riscv_pkg::TagePathBits,
    parameter int unsigned FTQ_IDX_BITS = riscv_pkg::TageFtqIdxBits
) (
    input logic i_clk,
    input logic i_rst,

    // Fetch-side events registered in pc_controller, and the fetch PC's
    // [3:2] for a push.
    input  logic                 i_hist_push,
    input  logic [          4:0] i_hist_restore_arm,
    input  logic [PATH_BITS-1:0] i_fetch_pc_path_bits,
    output logic [HIST_BITS-1:0] o_lookup_hist,

    // PD passes a packet to ID (the PD-to-ID register loads a real packet).
    // Bit s of each per-slot vector is slot s + 1. A slot's flag marks a real
    // conditional branch; at most one is set.
    input logic                                    i_pd_accept,
    input logic                    [          1:0] i_pd_cond_branch,
    input logic                    [          1:0] i_tage_slot_valid,
    input riscv_pkg::tage_lookup_t                 i_tage_slot_lookup,
    input riscv_pkg::tage_lookup_t                 i_tage_slot_lookup_2,
    input logic                    [          1:0] i_tage_slot_bank,
    // The BTB and bimodal direction each slot's branch had before PD.
    input logic                    [          1:0] i_base_taken,
    input logic                    [HIST_BITS-1:0] i_tage_lookup_hist,

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
    input logic [1:0]                                       i_alloc_q,

    // Registered commit bus, per slot.
    input logic [1:0]                                       i_commit_valid,
    input logic [1:0][riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_tag,
    input logic [1:0]                                       i_commit_cond_branch,
    input logic [1:0]                                       i_commit_taken_cf,
    input logic [1:0]                                       i_commit_taken,
    input logic [1:0]                                       i_commit_mispredicted,
    input logic [1:0][                       PATH_BITS-1:0] i_commit_target_bits,

    // Training port (tage_predictor).
    output logic                    o_train_valid,
    output riscv_pkg::tage_lookup_t o_train_lookup,
    output logic                    o_train_bank,
    output logic                    o_train_alt_taken,
    output logic                    o_train_taken,
    output logic                    o_train_mispredicted
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
  } ftq_entry_t;
  localparam int unsigned FtqEntryBits = 3 + riscv_pkg::TageLookupBits + HIST_BITS;

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
  always_ff @(posedge i_clk) begin
    if (i_rst) pd_accept_q <= 1'b0;
    else pd_accept_q <= i_pd_accept;
    if (i_pd_accept) begin
      pd_cond_branch_q <= i_pd_cond_branch;
      pd_slot_valid_q  <= i_tage_slot_valid;
      pd_slot_bank_q   <= i_tage_slot_bank;
      pd_base_taken_q  <= i_base_taken;
      pd_lookup_q      <= i_tage_slot_lookup;
      pd_lookup_2_q    <= i_tage_slot_lookup_2;
      pd_lookup_hist_q <= i_tage_lookup_hist;
    end
  end

  logic pd_entry_pending;
  logic pd_branch_slot;
  riscv_pkg::tage_lookup_t pd_branch_lookup;
  ftq_entry_t pd_entry;
  assign pd_entry_pending = pd_accept_q && (pd_cond_branch_q[0] || pd_cond_branch_q[1]);
  assign pd_branch_slot   = !pd_cond_branch_q[0];
  assign pd_branch_lookup = pd_branch_slot ? pd_lookup_2_q : pd_lookup_q;
  always_comb begin
    pd_entry = '0;
    pd_entry.lookup_valid = pd_slot_valid_q[pd_branch_slot];
    pd_entry.bank = pd_slot_bank_q[pd_branch_slot];
    pd_entry.lookup = pd_branch_lookup;
    pd_entry.alt_taken = pd_branch_lookup.alt_tagged ? pd_branch_lookup.alt_tagged_taken :
                                                       pd_base_taken_q[pd_branch_slot];
    pd_entry.hist = pd_lookup_hist_q;
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
    alloc_cond_branch_q <= i_alloc_cond_branch;
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
  assign commit_branch[0]  = i_commit_valid[0] && i_commit_cond_branch[0];
  assign commit_branch[1]  = i_commit_valid[1] && i_commit_cond_branch[1];
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
  logic early_q;
  logic early_taken_q;
  ftq_entry_t ftq_read_early;
  assign ftq_read_early = ftq_read_early_raw;
  always_ff @(posedge i_clk) begin
    pd_hist_q     <= pd_lookup_hist_q;
    pd_taken_q    <= i_pd_redirect_taken;
    early_hist_q  <= ftq_read_early.hist;
    early_q       <= i_early_active;
    early_taken_q <= i_early_taken;
  end

  // Arms, highest priority first: 0 reset, 1 trap or xRET, 2 FENCE-class
  // flush, 3 misprediction recovery, 4 PD redirect. At most one is set.
  logic [HIST_BITS-1:0] restore_base;
  logic restore_push;
  always_comb begin
    restore_base = hist_q;
    restore_push = i_hist_push;
    if (i_hist_restore_arm[0]) begin
      restore_base = '0;
      restore_push = 1'b0;
    end else if (i_hist_restore_arm[1] || i_hist_restore_arm[2]) begin
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
  logic train_sel_valid;
  logic [FTQ_IDX_BITS-1:0] train_sel_idx;
  logic train_sel_taken;
  logic train_sel_mispredicted;
  always_comb begin
    train_sel_valid = 1'b0;
    train_sel_idx = commit_ftq_idx[0];
    train_sel_taken = i_commit_taken[0];
    train_sel_mispredicted = i_commit_mispredicted[0];
    if (commit_branch[0]) begin
      train_sel_valid = 1'b1;
    end else if (held_valid) begin
      train_sel_valid = 1'b1;
      train_sel_idx = held_idx;
      train_sel_taken = held_taken;
      train_sel_mispredicted = held_mispredicted;
    end else if (commit_branch[1]) begin
      train_sel_valid = 1'b1;
      train_sel_idx = commit_ftq_idx[1];
      train_sel_taken = i_commit_taken[1];
      train_sel_mispredicted = i_commit_mispredicted[1];
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
    if (i_rst) o_train_valid <= 1'b0;
    else o_train_valid <= train_sel_valid && ftq_read_train.lookup_valid;
    o_train_lookup       <= ftq_read_train.lookup;
    o_train_bank         <= ftq_read_train.bank;
    o_train_alt_taken    <= ftq_read_train.alt_taken;
    o_train_taken        <= train_sel_taken;
    o_train_mispredicted <= train_sel_mispredicted;
  end

endmodule : tage_history
