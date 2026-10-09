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
 * Register alias table: maps INT and FP architectural registers to the ROB
 * tags of their in-flight producers. Ten source lookups serve the two
 * dispatch slots (two INT and three FP each). x0 is never renamed and always
 * reads zero. Commit clears a mapping only if its tag still matches; a full
 * flush clears all rename state.
 *
 * Slot 2 can rename without slot 1, which may have no destination. A slot-2
 * ROB allocation still requires slot 1. Dispatch resolves same-bundle RAW
 * dependencies; RAT lookups read the current state.
 *
 * Eight checkpoints each save both RATs and the RAS state; a misprediction
 * restores one in a single cycle. The active RATs are flip-flops, for
 * parallel lookup, per-entry commit clear, and bulk restore; snapshots live
 * in sdp_dist_ram. Struct arrays are avoided for Yosys compatibility.
 */

module register_alias_table (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Source Lookup Interface (combinational reads, from Dispatch)
    // =========================================================================
    // INT source lookups - slot 1
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src1_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src2_addr,
    output riscv_pkg::rat_lookup_t                               o_int_src1,
    output riscv_pkg::rat_lookup_t                               o_int_src2,

    // FP source lookups - slot 1
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src1_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src2_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src3_addr,
    output riscv_pkg::rat_lookup_t                               o_fp_src1,
    output riscv_pkg::rat_lookup_t                               o_fp_src2,
    output riscv_pkg::rat_lookup_t                               o_fp_src3,

    // INT source lookups - slot 2 (2-wide dispatch)
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src1_addr_2,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src2_addr_2,
    output riscv_pkg::rat_lookup_t                               o_int_src1_2,
    output riscv_pkg::rat_lookup_t                               o_int_src2_2,

    // FP source lookups - slot 2 (2-wide dispatch)
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src1_addr_2,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src2_addr_2,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src3_addr_2,
    output riscv_pkg::rat_lookup_t                               o_fp_src1_2,
    output riscv_pkg::rat_lookup_t                               o_fp_src2_2,
    output riscv_pkg::rat_lookup_t                               o_fp_src3_2,

    // Regfile read data - slot 1 (for value passthrough)
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data1,
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data1,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data3,

    // Regfile read data - slot 2 (for value passthrough)
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data1_2,
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data2_2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data1_2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data2_2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data3_2,

    // =========================================================================
    // Rename Write Interface (from Dispatch, synchronous)
    // =========================================================================
    // Slot 1 alloc (primary).
    input logic                                        i_alloc_valid,
    input logic                                        i_alloc_dest_rf,   // 0=INT, 1=FP
    input logic [         riscv_pkg::RegAddrWidth-1:0] i_alloc_dest_reg,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_alloc_rob_tag,

    // Slot 2 allocates when it has a destination, even if slot 1 has none.
    // Same-register writes take slot 2's tag, the newer producer.
    input logic                                        i_alloc_valid_2,
    input logic                                        i_alloc_dest_rf_2,
    input logic [         riscv_pkg::RegAddrWidth-1:0] i_alloc_dest_reg_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_alloc_rob_tag_2,

    // =========================================================================
    // Commit Interface (ROB commits delayed one cycle by the wrapper)
    // =========================================================================
    input logic                                        i_commit_valid,
    input logic                                        i_commit_dest_valid,
    input logic                                        i_commit_dest_rf,
    input logic [         riscv_pkg::RegAddrWidth-1:0] i_commit_dest_reg,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_tag,

    // Second retirement of the pair. The ROB excludes mispredicted branches
    // and serial ops from 2-wide commit. If both commits target one register,
    // only slot 2 can still match: it renamed later.
    input logic                                        i_commit_valid_2,
    input logic                                        i_commit_dest_valid_2,
    input logic                                        i_commit_dest_rf_2,
    input logic [         riscv_pkg::RegAddrWidth-1:0] i_commit_dest_reg_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_tag_2,

    // =========================================================================
    // Checkpoint Save Interface (from Dispatch on branch allocation)
    // =========================================================================
    input logic                                        i_checkpoint_save,
    input logic [    riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_id,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_checkpoint_branch_tag,
    input logic [           riscv_pkg::RasPtrBits-1:0] i_ras_tos,
    input logic [             riscv_pkg::RasPtrBits:0] i_ras_valid_count,
    input logic [                 riscv_pkg::XLEN-1:0] i_ras_top,
    // The saving branch is in slot 2; include slot 1's same-cycle rename.
    input logic                                        i_checkpoint_save_for_slot2,

    // Dispatch candidates and bundle fire (dispatch.sv o_alloc_*):
    // i_alloc_valid == i_alloc_fire && i_alloc_has_dest, likewise for slot 2.
    // A save requires fire and i_checkpoint_save_for_slot2 ==
    // i_checkpoint_slot2_candidate. Candidates select rename and snapshot
    // data; fire gates the writes.
    input logic i_alloc_fire,
    input logic i_alloc_has_dest,
    input logic i_alloc_has_dest_2,
    input logic i_checkpoint_slot2_candidate,

    // =========================================================================
    // Checkpoint Restore Interface (from flush controller on misprediction)
    // =========================================================================
    input logic i_checkpoint_restore,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_restore_id,
    input logic i_checkpoint_restore_reclaim_all,
    output logic [riscv_pkg::RasPtrBits-1:0] o_ras_tos,
    output logic [riscv_pkg::RasPtrBits:0] o_ras_valid_count,
    output logic [riscv_pkg::XLEN-1:0] o_ras_top,

    // =========================================================================
    // Checkpoint Free Interface (from flush controller on branch commit or early recovery)
    // =========================================================================
    input logic                                    i_checkpoint_free,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_free_id,
    // Free a correctly predicted slot-2 branch's checkpoint at retirement,
    // independently of a slot-1 free in the same cycle.
    input logic                                    i_checkpoint_free_2,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_free_id_2,

    // Bulk free mask for flushed younger branches, registered by the flush
    // controller. It applies on its own, not gated by restore or free.
    input logic [riscv_pkg::NumCheckpoints-1:0] i_checkpoint_flush_free_mask,

    // =========================================================================
    // ROB Entry Valid Vector (for stale rename detection)
    // =========================================================================
    input logic [riscv_pkg::ReorderBufferDepth-1:0] i_rob_entry_valid,
    input logic [riscv_pkg::ReorderBufferDepth-1:0] i_rob_entry_epoch,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,

    // =========================================================================
    // Full Flush (trap, xRET, FENCE-class recovery)
    // =========================================================================
    input logic i_flush_all,

    // =========================================================================
    // Checkpoint Availability (to Dispatch)
    // =========================================================================
    output logic                                    o_checkpoint_available,
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_alloc_id
);

  // ===========================================================================
  // Local Parameters (from package)
  // ===========================================================================
  localparam int unsigned NumIntRegs = riscv_pkg::NumIntRegs;  // 32
  localparam int unsigned NumFpRegs = riscv_pkg::NumFpRegs;  // 32
  localparam int unsigned RegAddrWidth = riscv_pkg::RegAddrWidth;  // 5
  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;  // 5
  localparam int unsigned NumCheckpoints = riscv_pkg::NumCheckpoints;  // 8
  localparam int unsigned CheckpointIdWidth = riscv_pkg::CheckpointIdWidth;  // 3
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned RasPtrBits = riscv_pkg::RasPtrBits;  // 3

  // Checkpoint snapshot entry width: valid (1) + alloc generation (1) + tag.
  // The active RATs store only {valid, tag}; the generation bit is captured
  // only in checkpoints so restore can reject recycled ROB tags.
  localparam int unsigned RatEntryWidth = 2 + ReorderBufferTagWidth;  // 7

  // Checkpoint RAM data widths
  // INT RAT snapshot: 32 entries x 7 bits = 224 bits
  localparam int unsigned IntRatSnapshotWidth = NumIntRegs * RatEntryWidth;
  // FP RAT snapshot: 32 entries x 7 bits = 224 bits
  localparam int unsigned FpRatSnapshotWidth = NumFpRegs * RatEntryWidth;
  // Combined RAT snapshot for single wide RAM
  localparam int unsigned RatSnapshotWidth = IntRatSnapshotWidth + FpRatSnapshotWidth;
  // Metadata: branch_tag(5) + branch_epoch(1) + ras_tos(3) + ras_valid_count(4)
  // + ras_top(64) = 77
  localparam int unsigned CheckpointMetaWidth =
      ReorderBufferTagWidth + 1 + RasPtrBits + (RasPtrBits + 1) + XLEN;

  // ===========================================================================
  // Active RAT Storage (FF-based, plain arrays for Yosys compatibility)
  // ===========================================================================

  // INT RAT: separate valid and tag arrays. Avoid max_fanout here because
  // forced replication adds buffers to the lookup path.
  logic [           NumIntRegs-1:0] int_rat_valid;
  logic [ReorderBufferTagWidth-1:0] int_rat_tag               [NumIntRegs];

  // FP RAT: separate valid and tag arrays
  logic [            NumFpRegs-1:0] fp_rat_valid;
  logic [ReorderBufferTagWidth-1:0] fp_rat_tag                [ NumFpRegs];

  // Same-register collision used to qualify the slot-1 formal checks.
  logic                             slot1_collides_with_slot2;
  assign slot1_collides_with_slot2 = i_alloc_valid_2 &&
                                     (i_alloc_dest_rf == i_alloc_dest_rf_2) &&
                                     (i_alloc_dest_reg == i_alloc_dest_reg_2);

`ifndef SYNTHESIS
  // x10 (a0) rename-state taps, read by the FROST_TARGET_PC_TRACE diagnostics
  // in test_real_program.py.
  logic dbg_int_a0_valid  /* verilator public_flat_rd */;
  logic [ReorderBufferTagWidth-1:0] dbg_int_a0_tag  /* verilator public_flat_rd */;
  logic dbg_int_a0_commit_hit  /* verilator public_flat_rd */;
  logic dbg_int_a0_commit_tag_match  /* verilator public_flat_rd */;
  logic dbg_int_a0_alloc_hit  /* verilator public_flat_rd */;

  assign dbg_int_a0_valid = int_rat_valid[10];
  assign dbg_int_a0_tag = int_rat_tag[10];
  assign dbg_int_a0_commit_hit = i_commit_valid && i_commit_dest_valid && !i_commit_dest_rf &&
                                 (i_commit_dest_reg == RegAddrWidth'(10));
  assign dbg_int_a0_commit_tag_match = dbg_int_a0_commit_hit &&
                                       int_rat_valid[10] &&
                                       (int_rat_tag[10] == i_commit_tag);
  assign dbg_int_a0_alloc_hit = i_alloc_valid && !i_alloc_dest_rf &&
                                (i_alloc_dest_reg == RegAddrWidth'(10));
`endif

  // ===========================================================================
  // Checkpoint Storage
  // ===========================================================================

  // Checkpoint valid bits stay in FFs: they need per-entry clear and bulk flush.
  logic [   NumCheckpoints-1:0] checkpoint_valid;

  // Checkpoint RAT snapshots in distributed RAM: one combined INT + FP image,
  // 448 bits wide, 3-bit address.
  logic                         ckpt_rat_wr_en;
  logic [CheckpointIdWidth-1:0] ckpt_rat_wr_addr;
  logic [ RatSnapshotWidth-1:0] ckpt_rat_wr_data;
  logic [CheckpointIdWidth-1:0] ckpt_rat_rd_addr;
  logic [ RatSnapshotWidth-1:0] ckpt_rat_rd_data;

  sdp_dist_ram #(
      .ADDR_WIDTH(CheckpointIdWidth),
      .DATA_WIDTH(RatSnapshotWidth)
  ) u_ckpt_rat_snapshot (
      .i_clk,
      .i_write_enable (ckpt_rat_wr_en),
      .i_write_address(ckpt_rat_wr_addr),
      .i_write_data   (ckpt_rat_wr_data),
      .i_read_address (ckpt_rat_rd_addr),
      .o_read_data    (ckpt_rat_rd_data)
  );

  // Branch tag, allocation epoch, and RAS metadata in distributed RAM.
  logic                           ckpt_meta_wr_en;
  logic [  CheckpointIdWidth-1:0] ckpt_meta_wr_addr;
  logic [CheckpointMetaWidth-1:0] ckpt_meta_wr_data;
  logic [  CheckpointIdWidth-1:0] ckpt_meta_rd_addr;
  logic [CheckpointMetaWidth-1:0] ckpt_meta_rd_data;

  sdp_dist_ram #(
      .ADDR_WIDTH(CheckpointIdWidth),
      .DATA_WIDTH(CheckpointMetaWidth)
  ) u_ckpt_metadata (
      .i_clk,
      .i_write_enable (ckpt_meta_wr_en),
      .i_write_address(ckpt_meta_wr_addr),
      .i_write_data   (ckpt_meta_wr_data),
      .i_read_address (ckpt_meta_rd_addr),
      .o_read_data    (ckpt_meta_rd_data)
  );

  // ===========================================================================
  // Checkpoint RAM Interface Wiring
  // ===========================================================================

  // A full flush suppresses snapshot writes.
  assign ckpt_rat_wr_en = i_checkpoint_save && !i_flush_all;
  assign ckpt_rat_wr_addr = i_checkpoint_id;
  assign ckpt_meta_wr_en = ckpt_rat_wr_en;
  assign ckpt_meta_wr_addr = i_checkpoint_id;

  // Snapshot entries are {valid, alloc_epoch, tag}, INT below FP.
  //
  // A slot-2 branch needs the state after slot 1 but before its own rename.
  // Overlay slot 1's same-cycle tag and post-allocation epoch if it has a
  // destination. The active RAT still holds the state before these writes.
  // Early candidates are safe here: a save implies fire, so they equal
  // i_checkpoint_save_for_slot2 and i_alloc_valid whenever RAM is written.
  logic                             slot2_overlay_int;
  logic                             slot2_overlay_fp;
  logic [ReorderBufferTagWidth-1:0] slot2_overlay_tag;
  logic                             slot2_overlay_epoch_next;
  assign slot2_overlay_int = i_checkpoint_slot2_candidate && i_alloc_has_dest &&
                             !i_alloc_dest_rf && (i_alloc_dest_reg != '0);
  assign slot2_overlay_fp = i_checkpoint_slot2_candidate && i_alloc_has_dest && i_alloc_dest_rf;
  assign slot2_overlay_tag = i_alloc_rob_tag;
  // cpu_ooo toggles the epoch when slot 1 allocates at this edge.
  assign slot2_overlay_epoch_next = ~i_rob_entry_epoch[i_alloc_rob_tag];

  always_comb begin
    for (int i = 0; i < NumIntRegs; i++) begin
      if (slot2_overlay_int && (i_alloc_dest_reg == RegAddrWidth'(i))) begin
        ckpt_rat_wr_data[i*RatEntryWidth+:RatEntryWidth] = {
          1'b1, slot2_overlay_epoch_next, slot2_overlay_tag
        };
      end else begin
        ckpt_rat_wr_data[i*RatEntryWidth+:RatEntryWidth] = {
          int_rat_valid[i], i_rob_entry_epoch[int_rat_tag[i]], int_rat_tag[i]
        };
      end
    end
    for (int i = 0; i < NumFpRegs; i++) begin
      if (slot2_overlay_fp && (i_alloc_dest_reg == RegAddrWidth'(i))) begin
        ckpt_rat_wr_data[IntRatSnapshotWidth+i*RatEntryWidth+:RatEntryWidth] = {
          1'b1, slot2_overlay_epoch_next, slot2_overlay_tag
        };
      end else begin
        ckpt_rat_wr_data[IntRatSnapshotWidth+i*RatEntryWidth+:RatEntryWidth] = {
          fp_rat_valid[i], i_rob_entry_epoch[fp_rat_tag[i]], fp_rat_tag[i]
        };
      end
    end
  end

  // The branch allocates with the checkpoint; save its post-allocation epoch.
  logic checkpoint_branch_epoch_next;
  assign checkpoint_branch_epoch_next = ~i_rob_entry_epoch[i_checkpoint_branch_tag];
  assign ckpt_meta_wr_data = {
    i_ras_top, i_ras_valid_count, i_ras_tos, checkpoint_branch_epoch_next, i_checkpoint_branch_tag
  };

  // Read side: checkpoint restore
  assign ckpt_rat_rd_addr = i_checkpoint_restore_id;
  assign ckpt_meta_rd_addr = i_checkpoint_restore_id;

  // Unpack restored RAT state
  logic [           NumIntRegs-1:0] restored_int_valid;
  logic [           NumIntRegs-1:0] restored_int_epoch;
  logic [ReorderBufferTagWidth-1:0] restored_int_tag   [NumIntRegs];
  logic [            NumFpRegs-1:0] restored_fp_valid;
  logic [            NumFpRegs-1:0] restored_fp_epoch;
  logic [ReorderBufferTagWidth-1:0] restored_fp_tag    [ NumFpRegs];

  always_comb begin
    for (int i = 0; i < NumIntRegs; i++) begin
      restored_int_valid[i] = ckpt_rat_rd_data[i*RatEntryWidth+ReorderBufferTagWidth+1];
      restored_int_epoch[i] = ckpt_rat_rd_data[i*RatEntryWidth+ReorderBufferTagWidth];
      restored_int_tag[i]   = ckpt_rat_rd_data[i*RatEntryWidth+:ReorderBufferTagWidth];
    end
    for (int i = 0; i < NumFpRegs; i++) begin
      restored_fp_valid[i] =
          ckpt_rat_rd_data[IntRatSnapshotWidth+i*RatEntryWidth+ReorderBufferTagWidth+1];
      restored_fp_epoch[i] =
          ckpt_rat_rd_data[IntRatSnapshotWidth+i*RatEntryWidth+ReorderBufferTagWidth];
      restored_fp_tag[i] =
          ckpt_rat_rd_data[IntRatSnapshotWidth+i*RatEntryWidth+:ReorderBufferTagWidth];
    end
  end

  // Unpack restored metadata
  logic [ReorderBufferTagWidth-1:0] restored_branch_tag;
  logic                             restored_branch_epoch;
  logic [           RasPtrBits-1:0] restored_ras_tos;
  logic [             RasPtrBits:0] restored_ras_valid_count;
  logic [                 XLEN-1:0] restored_ras_top;

  assign restored_branch_tag = ckpt_meta_rd_data[0+:ReorderBufferTagWidth];
  assign restored_branch_epoch = ckpt_meta_rd_data[ReorderBufferTagWidth];
  assign restored_ras_tos = ckpt_meta_rd_data[ReorderBufferTagWidth+1+:RasPtrBits];
  assign restored_ras_valid_count =
      ckpt_meta_rd_data[ReorderBufferTagWidth+1+RasPtrBits+:(RasPtrBits+1)];
  assign restored_ras_top =
      ckpt_meta_rd_data[ReorderBufferTagWidth+1+RasPtrBits+(RasPtrBits+1)+:XLEN];

  function automatic logic restored_tag_still_live(
      input logic [ReorderBufferTagWidth-1:0] restored_tag, input logic restored_epoch);
    logic [ReorderBufferTagWidth:0] tag_age;
    logic [ReorderBufferTagWidth:0] branch_age;
    logic                           branch_still_live;
    begin
      tag_age = {1'b0, restored_tag} - {1'b0, i_rob_head_tag};
      branch_age = {1'b0, restored_branch_tag} - {1'b0, i_rob_head_tag};
      branch_still_live =
          i_rob_entry_valid[restored_branch_tag] &&
          (i_rob_entry_epoch[restored_branch_tag] == restored_branch_epoch);
      // Restore only live producers with matching epochs, strictly older than
      // a live branch with its saved epoch. Otherwise ROB tag reuse could
      // revive a stale mapping after the branch retires or the ROB wraps.
      restored_tag_still_live =
          branch_still_live &&
          i_rob_entry_valid[restored_tag] &&
          (i_rob_entry_epoch[restored_tag] == restored_epoch) &&
          (tag_age < branch_age);
    end
  endfunction

  // Restored RAS state, meaningful only during the restore cycle.
  assign o_ras_tos = restored_ras_tos;
  assign o_ras_valid_count = restored_ras_valid_count;
  assign o_ras_top = restored_ras_top;

  // ===========================================================================
  // Source Lookup (Combinational)
  // ===========================================================================

  // x0 is never renamed. A constant {valid=0, tag=0} at entry 0 avoids
  // separate x0 qualification after lookup.
  logic [NumIntRegs-1:0] int_lookup_valid;
  logic [ReorderBufferTagWidth-1:0] int_lookup_tag[NumIntRegs];
  always_comb begin
    int_lookup_valid    = int_rat_valid;
    int_lookup_valid[0] = 1'b0;
    for (int i = 0; i < NumIntRegs; i++) int_lookup_tag[i] = int_rat_tag[i];
    int_lookup_tag[0] = '0;
  end

  // INT source 1
  // rat_lookup_t = {renamed, tag[4:0], value[63:0]}. Tags are meaningful only
  // when renamed is set; otherwise they may be stale or uninitialized.
  // Readiness/repair-valid must qualify tag comparisons. x0 returns all zero.
  // Renamed means the producer is live in the ROB. For INT and FP, a done
  // producer's value is supplied by done repair after dispatch.
  always_comb begin
    o_int_src1.renamed = int_lookup_valid[i_int_src1_addr] &&
                         i_rob_entry_valid[int_lookup_tag[i_int_src1_addr]];
    o_int_src1.tag = int_lookup_tag[i_int_src1_addr];
    o_int_src1.value = (i_int_src1_addr == '0) ? '0 : {{(FLEN - XLEN) {1'b0}}, i_int_regfile_data1};
  end

  // INT source 2
  always_comb begin
    o_int_src2.renamed = int_lookup_valid[i_int_src2_addr] &&
                         i_rob_entry_valid[int_lookup_tag[i_int_src2_addr]];
    o_int_src2.tag = int_lookup_tag[i_int_src2_addr];
    o_int_src2.value = (i_int_src2_addr == '0) ? '0 : {{(FLEN - XLEN) {1'b0}}, i_int_regfile_data2};
  end

  // FP source 1
  always_comb begin
    if (fp_rat_valid[i_fp_src1_addr] && i_rob_entry_valid[fp_rat_tag[i_fp_src1_addr]]) begin
      o_fp_src1 = {1'b1, fp_rat_tag[i_fp_src1_addr], i_fp_regfile_data1};
    end else begin
      o_fp_src1 = {1'b0, fp_rat_tag[i_fp_src1_addr], i_fp_regfile_data1};
    end
  end

  // FP source 2
  always_comb begin
    if (fp_rat_valid[i_fp_src2_addr] && i_rob_entry_valid[fp_rat_tag[i_fp_src2_addr]]) begin
      o_fp_src2 = {1'b1, fp_rat_tag[i_fp_src2_addr], i_fp_regfile_data2};
    end else begin
      o_fp_src2 = {1'b0, fp_rat_tag[i_fp_src2_addr], i_fp_regfile_data2};
    end
  end

  // FP source 3 (for FMA)
  always_comb begin
    if (fp_rat_valid[i_fp_src3_addr] && i_rob_entry_valid[fp_rat_tag[i_fp_src3_addr]]) begin
      o_fp_src3 = {1'b1, fp_rat_tag[i_fp_src3_addr], i_fp_regfile_data3};
    end else begin
      o_fp_src3 = {1'b0, fp_rat_tag[i_fp_src3_addr], i_fp_regfile_data3};
    end
  end

  // ---------------------------------------------------------------------------
  // Slot-2 source lookups, before dispatch's same-bundle RAW bypass.
  // ---------------------------------------------------------------------------

  // INT source 1 (slot 2)
  always_comb begin
    o_int_src1_2.renamed = int_lookup_valid[i_int_src1_addr_2] &&
                           i_rob_entry_valid[int_lookup_tag[i_int_src1_addr_2]];
    o_int_src1_2.tag = int_lookup_tag[i_int_src1_addr_2];
    o_int_src1_2.value = (i_int_src1_addr_2 == '0) ? '0 :
        {{(FLEN - XLEN) {1'b0}}, i_int_regfile_data1_2};
  end

  // INT source 2 (slot 2)
  always_comb begin
    o_int_src2_2.renamed = int_lookup_valid[i_int_src2_addr_2] &&
                           i_rob_entry_valid[int_lookup_tag[i_int_src2_addr_2]];
    o_int_src2_2.tag = int_lookup_tag[i_int_src2_addr_2];
    o_int_src2_2.value = (i_int_src2_addr_2 == '0) ? '0 :
        {{(FLEN - XLEN) {1'b0}}, i_int_regfile_data2_2};
  end

  // FP source 1 (slot 2)
  always_comb begin
    if (fp_rat_valid[i_fp_src1_addr_2] && i_rob_entry_valid[fp_rat_tag[i_fp_src1_addr_2]]) begin
      o_fp_src1_2 = {1'b1, fp_rat_tag[i_fp_src1_addr_2], i_fp_regfile_data1_2};
    end else begin
      o_fp_src1_2 = {1'b0, fp_rat_tag[i_fp_src1_addr_2], i_fp_regfile_data1_2};
    end
  end

  // FP source 2 (slot 2)
  always_comb begin
    if (fp_rat_valid[i_fp_src2_addr_2] && i_rob_entry_valid[fp_rat_tag[i_fp_src2_addr_2]]) begin
      o_fp_src2_2 = {1'b1, fp_rat_tag[i_fp_src2_addr_2], i_fp_regfile_data2_2};
    end else begin
      o_fp_src2_2 = {1'b0, fp_rat_tag[i_fp_src2_addr_2], i_fp_regfile_data2_2};
    end
  end

  // FP source 3 (slot 2, for FMA)
  always_comb begin
    if (fp_rat_valid[i_fp_src3_addr_2] && i_rob_entry_valid[fp_rat_tag[i_fp_src3_addr_2]]) begin
      o_fp_src3_2 = {1'b1, fp_rat_tag[i_fp_src3_addr_2], i_fp_regfile_data3_2};
    end else begin
      o_fp_src3_2 = {1'b0, fp_rat_tag[i_fp_src3_addr_2], i_fp_regfile_data3_2};
    end
  end

  // ===========================================================================
  // Sequential Logic: Active RAT Updates
  // ===========================================================================

  // Decode candidate destinations per register. With the input contract above,
  // gating these selects by i_alloc_fire equals using i_alloc_valid{,_2}.
  logic [NumIntRegs-1:0] int_rename_sel_1, int_rename_sel_2;
  logic [NumFpRegs-1:0] fp_rename_sel_1, fp_rename_sel_2;
  always_comb begin
    for (int i = 0; i < NumIntRegs; i++) begin
      int_rename_sel_1[i] = (i != 0) && i_alloc_has_dest && !i_alloc_dest_rf &&
          (i_alloc_dest_reg == RegAddrWidth'(i));
      int_rename_sel_2[i] = (i != 0) && i_alloc_has_dest_2 && !i_alloc_dest_rf_2 &&
          (i_alloc_dest_reg_2 == RegAddrWidth'(i));
    end
    for (int i = 0; i < NumFpRegs; i++) begin
      fp_rename_sel_1[i] = i_alloc_has_dest && i_alloc_dest_rf &&
          (i_alloc_dest_reg == RegAddrWidth'(i));
      fp_rename_sel_2[i] = i_alloc_has_dest_2 && i_alloc_dest_rf_2 &&
          (i_alloc_dest_reg_2 == RegAddrWidth'(i));
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // Check dispatch's rename/save candidate contract; formal assumes it.
  always_ff @(posedge i_clk) begin
    if (i_rst_n) begin
      p_alloc_candidates_contract :
      assert ((i_alloc_valid == (i_alloc_fire && i_alloc_has_dest)) &&
              (i_alloc_valid_2 == (i_alloc_fire && i_alloc_has_dest_2)) &&
              (!i_checkpoint_save ||
               (i_alloc_fire && (i_checkpoint_save_for_slot2 == i_checkpoint_slot2_candidate))));
    end
  end
`endif
`endif

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      int_rat_valid <= '0;
      fp_rat_valid  <= '0;
    end else if (i_checkpoint_restore) begin
      // Restore takes priority over flush_all. The flush controller prevents
      // them from coinciding in the core. Filter stale snapshot mappings with
      // restored_tag_still_live before making them visible.
      for (int i = 0; i < NumIntRegs; i++) begin
        int_rat_valid[i] <= restored_int_valid[i] && restored_tag_still_live(
            restored_int_tag[i], restored_int_epoch[i]
        );
        int_rat_tag[i] <= restored_int_tag[i];
      end
      for (int i = 0; i < NumFpRegs; i++) begin
        fp_rat_valid[i] <= restored_fp_valid[i] && restored_tag_still_live(
            restored_fp_tag[i], restored_fp_epoch[i]
        );
        fp_rat_tag[i] <= restored_fp_tag[i];
      end
    end else if (i_flush_all) begin
      int_rat_valid <= '0;
      fp_rat_valid  <= '0;
    end else begin
      // ---------------------------------------------------------------
      // Commit clears a matching mapping; the architectural regfile has its value.
      // ---------------------------------------------------------------
      if (i_commit_valid && i_commit_dest_valid) begin
        if (!i_commit_dest_rf) begin
          if (i_commit_dest_reg != '0 &&
              int_rat_valid[i_commit_dest_reg] &&
              int_rat_tag[i_commit_dest_reg] == i_commit_tag) begin
            int_rat_valid[i_commit_dest_reg] <= 1'b0;
          end
        end else begin
          if (fp_rat_valid[i_commit_dest_reg] &&
              fp_rat_tag[i_commit_dest_reg] == i_commit_tag) begin
            fp_rat_valid[i_commit_dest_reg] <= 1'b0;
          end
        end
      end

      // ---------------------------------------------------------------
      // Slot-2 commit clear (head+1).
      // ---------------------------------------------------------------
      if (i_commit_valid_2 && i_commit_dest_valid_2) begin
        if (!i_commit_dest_rf_2) begin
          if (i_commit_dest_reg_2 != '0 &&
              int_rat_valid[i_commit_dest_reg_2] &&
              int_rat_tag[i_commit_dest_reg_2] == i_commit_tag_2) begin
            int_rat_valid[i_commit_dest_reg_2] <= 1'b0;
          end
        end else begin
          if (fp_rat_valid[i_commit_dest_reg_2] &&
              fp_rat_tag[i_commit_dest_reg_2] == i_commit_tag_2) begin
            fp_rat_valid[i_commit_dest_reg_2] <= 1'b0;
          end
        end
      end

      // ---------------------------------------------------------------
      // Rename wins over commit; slot 2 wins over slot 1.
      // ---------------------------------------------------------------
      for (int i = 0; i < NumIntRegs; i++) begin
        if (i_alloc_fire && (int_rename_sel_1[i] || int_rename_sel_2[i])) begin
          int_rat_valid[i] <= 1'b1;
          int_rat_tag[i]   <= int_rename_sel_2[i] ? i_alloc_rob_tag_2 : i_alloc_rob_tag;
        end
      end
      for (int i = 0; i < NumFpRegs; i++) begin
        if (i_alloc_fire && (fp_rename_sel_1[i] || fp_rename_sel_2[i])) begin
          fp_rat_valid[i] <= 1'b1;
          fp_rat_tag[i]   <= fp_rename_sel_2[i] ? i_alloc_rob_tag_2 : i_alloc_rob_tag;
        end
      end
    end
  end

  // ===========================================================================
  // Sequential Logic: Checkpoint Valid Bits
  // ===========================================================================

  // Combine checkpoint updates before the nonblocking assignment to preserve
  // same-cycle updates to different slots.
  logic [   NumCheckpoints-1:0] checkpoint_valid_next;
  logic                         checkpoint_available_next;
  logic [CheckpointIdWidth-1:0] checkpoint_alloc_id_next;

  always_comb begin
    if (!i_rst_n || i_flush_all) begin
      checkpoint_valid_next = '0;
    end else if (i_checkpoint_restore_reclaim_all) begin
      checkpoint_valid_next = '0;
    end else begin
      checkpoint_valid_next = checkpoint_valid;
      // Bulk flush clear (younger branches on misprediction)
      checkpoint_valid_next = checkpoint_valid_next & ~i_checkpoint_flush_free_mask;
      // Individual frees (branch commit or early recovery)
      if (i_checkpoint_free) checkpoint_valid_next[i_checkpoint_free_id] = 1'b0;
      if (i_checkpoint_free_2) checkpoint_valid_next[i_checkpoint_free_id_2] = 1'b0;
      // Save wins over individual and masked frees, but not reset/flush/reclaim.
      if (i_checkpoint_save) checkpoint_valid_next[i_checkpoint_id] = 1'b1;
    end
  end

  always_comb begin
    checkpoint_available_next = 1'b0;
    checkpoint_alloc_id_next  = '0;
    for (int i = NumCheckpoints - 1; i >= 0; i--) begin
      if (!checkpoint_valid_next[i]) begin
        checkpoint_available_next = 1'b1;
        checkpoint_alloc_id_next  = i[CheckpointIdWidth-1:0];
      end
    end
  end

  always_ff @(posedge i_clk) begin
    checkpoint_valid       <= checkpoint_valid_next;
    o_checkpoint_available <= checkpoint_available_next;
    o_checkpoint_alloc_id  <= checkpoint_alloc_id_next;
  end

  // ===========================================================================
  // Assertions (Simulation Only)
  // ===========================================================================

`ifndef SYNTHESIS
`ifndef FORMAL
  // No rename during flush_all
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_valid && i_flush_all) begin
      $error("RAT: Rename attempted during flush_all!");
    end
  end

  // No rename during checkpoint_restore
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_valid && i_checkpoint_restore) begin
      $error("RAT: Rename attempted during checkpoint restore!");
    end
  end

  // No slot-2 rename during flush_all
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_valid_2 && i_flush_all) begin
      $error("RAT: Slot-2 rename attempted during flush_all!");
    end
  end

  // No slot-2 rename during checkpoint_restore
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_valid_2 && i_checkpoint_restore) begin
      $error("RAT: Slot-2 rename attempted during checkpoint restore!");
    end
  end

  // Checkpoint save should target a free slot
  always @(posedge i_clk) begin
    if (i_rst_n && i_checkpoint_save && checkpoint_valid[i_checkpoint_id]) begin
      $error("RAT: Checkpoint save to already-valid slot %0d!", i_checkpoint_id);
    end
  end

  // Checkpoint restore should target a valid slot
  always @(posedge i_clk) begin
    if (i_rst_n && i_checkpoint_restore && !checkpoint_valid[i_checkpoint_restore_id]) begin
      $error("RAT: Checkpoint restore from invalid slot %0d!", i_checkpoint_restore_id);
    end
  end

  // No INT rename to x0 (slot 1)
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_valid && !i_alloc_dest_rf && i_alloc_dest_reg == '0) begin
      $error("RAT: Rename write to INT x0 attempted (slot 1)!");
    end
  end

  // No INT rename to x0 (slot 2)
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_valid_2 && !i_alloc_dest_rf_2 && i_alloc_dest_reg_2 == '0) begin
      $error("RAT: Rename write to INT x0 attempted (slot 2)!");
    end
  end

  // Checkpoint save and restore should not happen simultaneously
  always @(posedge i_clk) begin
    if (i_rst_n && i_checkpoint_save && i_checkpoint_restore) begin
      $error("RAT: Simultaneous checkpoint save and restore!");
    end
  end

  always @(posedge i_clk) begin
    if (i_rst_n && i_checkpoint_restore_reclaim_all && !i_checkpoint_restore) begin
      $error("RAT: reclaim_all asserted without checkpoint restore!");
    end
  end
`endif  // FORMAL
`endif  // SYNTHESIS

  // ===========================================================================
  // Formal Verification
  // ===========================================================================

`ifdef FORMAL

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // Force reset to deassert after the initial cycle
  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  logic                    f_commit_int_active;
  logic [RegAddrWidth-1:0] f_commit_int_dest_reg;
  logic                    f_commit_int_was_valid;
  logic                    f_commit_int_tag_match;
  logic                    f_commit2_int_clears_same_dest;

  always @(posedge i_clk) begin
    f_commit_int_active <= i_commit_valid &&
                           i_commit_dest_valid &&
                           !i_commit_dest_rf &&
                           i_commit_dest_reg != '0 &&
                           !i_flush_all &&
                           !i_checkpoint_restore &&
                           !(i_alloc_valid &&
                             !i_alloc_dest_rf &&
                             i_alloc_dest_reg == i_commit_dest_reg) &&
                           !(i_alloc_valid_2 &&
                             !i_alloc_dest_rf_2 &&
                             i_alloc_dest_reg_2 == i_commit_dest_reg);
    f_commit_int_dest_reg <= i_commit_dest_reg;
    f_commit_int_was_valid <= int_rat_valid[i_commit_dest_reg];
    f_commit_int_tag_match <= int_rat_tag[i_commit_dest_reg] == i_commit_tag;
    f_commit2_int_clears_same_dest <= i_commit_valid_2 &&
                                      i_commit_dest_valid_2 &&
                                      !i_commit_dest_rf_2 &&
                                      i_commit_dest_reg_2 != '0 &&
                                      i_commit_dest_reg_2 == i_commit_dest_reg &&
                                      int_rat_valid[i_commit_dest_reg_2] &&
                                      int_rat_tag[i_commit_dest_reg_2] == i_commit_tag_2;
  end

  // -------------------------------------------------------------------------
  // Structural constraints (assumes)
  // -------------------------------------------------------------------------

  // No rename during flush_all or checkpoint_restore (slot 1)
  always_comb begin
    assume (!(i_alloc_valid && i_flush_all));
    assume (!(i_alloc_valid && i_checkpoint_restore));
  end

  // No rename during flush_all or checkpoint_restore (slot 2)
  always_comb begin
    assume (!(i_alloc_valid_2 && i_flush_all));
    assume (!(i_alloc_valid_2 && i_checkpoint_restore));
  end

  // Dispatch's rename/save candidate contract.
  always_comb begin
    assume (i_alloc_valid == (i_alloc_fire && i_alloc_has_dest));
    assume (i_alloc_valid_2 == (i_alloc_fire && i_alloc_has_dest_2));
    if (i_checkpoint_save) begin
      assume (i_alloc_fire);
      assume (i_checkpoint_save_for_slot2 == i_checkpoint_slot2_candidate);
    end
  end

  // Checkpoint save and restore not simultaneous
  always_comb begin
    assume (!(i_checkpoint_save && i_checkpoint_restore));
  end

  always_comb begin
    if (i_checkpoint_restore_reclaim_all) begin
      assume (i_checkpoint_restore);
    end
  end

  // Checkpoint restore targets a valid checkpoint
  always_comb begin
    if (i_checkpoint_restore) begin
      assume (checkpoint_valid[i_checkpoint_restore_id]);
    end
  end

  // Dispatch never renames x0 (INT) on either slot
  always_comb begin
    if (i_alloc_valid && !i_alloc_dest_rf) begin
      assume (i_alloc_dest_reg != '0);
    end
    if (i_alloc_valid_2 && !i_alloc_dest_rf_2) begin
      assume (i_alloc_dest_reg_2 != '0);
    end
  end

  // -------------------------------------------------------------------------
  // Combinational properties (asserts, active when i_rst_n)
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // INT RAT x0 is never valid (hardwired zero invariant)
      p_x0_never_valid : assert (!int_rat_valid[0]);

      // Source lookup for x0 always returns renamed=0, value=0
      p_x0_src1_not_renamed : assert (i_int_src1_addr != '0 || !o_int_src1.renamed);

      p_x0_src2_not_renamed : assert (i_int_src2_addr != '0 || !o_int_src2.renamed);

      p_x0_src1_value_zero : assert (i_int_src1_addr != '0 || o_int_src1.value == '0);

      p_x0_src2_value_zero : assert (i_int_src2_addr != '0 || o_int_src2.value == '0);

      // Checkpoint availability consistent with valid bits
      p_ckpt_avail_consistent :
      assert (o_checkpoint_available == (checkpoint_valid != {NumCheckpoints{1'b1}}));
    end
  end

  // -------------------------------------------------------------------------
  // Sequential properties (asserts, require f_past_valid)
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin
      // Restore outranks full flush for the active RAT, but checkpoints clear
      // on every full flush.
      if ($past(i_flush_all) && !$past(i_checkpoint_restore)) begin
        p_flush_clears_int : assert (int_rat_valid == '0);
        p_flush_clears_fp : assert (fp_rat_valid == '0);
      end
      if ($past(i_flush_all)) begin
        p_flush_clears_ckpts : assert (checkpoint_valid == '0);
      end

      if ($past(i_checkpoint_restore_reclaim_all) && !$past(i_flush_all)) begin
        p_restore_reclaims_ckpts : assert (checkpoint_valid == '0);
      end

      // INT rename sets valid and tag, unless slot 2 writes the same register.
      if ($past(
              i_alloc_valid
          ) && !$past(
              i_alloc_dest_rf
          ) && $past(
              i_alloc_dest_reg
          ) != '0 && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          ) && !$past(
              slot1_collides_with_slot2
          )) begin
        p_rename_sets_int :
        assert (int_rat_valid[$past(
            i_alloc_dest_reg
        )] && int_rat_tag[$past(
            i_alloc_dest_reg
        )] == $past(
            i_alloc_rob_tag
        ));
      end

      // FP rename sets valid and tag, unless slot 2 writes the same register.
      if ($past(
              i_alloc_valid
          ) && $past(
              i_alloc_dest_rf
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          ) && !$past(
              slot1_collides_with_slot2
          )) begin
        p_rename_sets_fp :
        assert (fp_rat_valid[$past(
            i_alloc_dest_reg
        )] && fp_rat_tag[$past(
            i_alloc_dest_reg
        )] == $past(
            i_alloc_rob_tag
        ));
      end

      // Slot-2 INT rename wins even if slot 1 writes the same register.
      if ($past(
              i_alloc_valid_2
          ) && !$past(
              i_alloc_dest_rf_2
          ) && $past(
              i_alloc_dest_reg_2
          ) != '0 && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          )) begin
        p_rename_sets_int_slot2 :
        assert (int_rat_valid[$past(
            i_alloc_dest_reg_2
        )] && int_rat_tag[$past(
            i_alloc_dest_reg_2
        )] == $past(
            i_alloc_rob_tag_2
        ));
      end

      // Slot-2 FP rename: entry is valid with slot-2's tag.
      if ($past(
              i_alloc_valid_2
          ) && $past(
              i_alloc_dest_rf_2
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          )) begin
        p_rename_sets_fp_slot2 :
        assert (fp_rat_valid[$past(
            i_alloc_dest_reg_2
        )] && fp_rat_tag[$past(
            i_alloc_dest_reg_2
        )] == $past(
            i_alloc_rob_tag_2
        ));
      end

      // INT commit clears only a matching tag. Sampled helpers avoid nested
      // $past(dynamic_index) for Yosys compatibility.
      if (f_commit_int_active && f_commit_int_was_valid) begin
        if (f_commit_int_tag_match) begin
          p_commit_clears_int : assert (!int_rat_valid[f_commit_int_dest_reg]);
        end else if (!f_commit2_int_clears_same_dest) begin
          p_commit_preserves_int : assert (int_rat_valid[f_commit_int_dest_reg]);
        end
      end
    end

    // Reset properties
    if (f_past_valid && i_rst_n && !$past(i_rst_n)) begin
      p_reset_clears_int : assert (int_rat_valid == '0);
      p_reset_clears_fp : assert (fp_rat_valid == '0);
      p_reset_clears_ckpts : assert (checkpoint_valid == '0);
    end
  end

  // -------------------------------------------------------------------------
  // Cover properties
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // Simultaneous rename + commit to same register
      cover_rename_and_commit_same_reg :
      cover (
        i_alloc_valid && i_commit_valid && i_commit_dest_valid &&
        i_alloc_dest_rf == i_commit_dest_rf &&
        i_alloc_dest_reg == i_commit_dest_reg
      );

      // All checkpoints in use (exhaustion)
      cover_ckpt_exhaustion : cover (checkpoint_valid == {NumCheckpoints{1'b1}});

      cover_ckpt_save : cover (i_checkpoint_save);

      cover_ckpt_restore : cover (i_checkpoint_restore);

      // Full flush from non-empty state
      cover_flush_nonempty : cover (i_flush_all && (int_rat_valid[1] || fp_rat_valid[0]));
    end
  end

`endif  // FORMAL

endmodule : register_alias_table
