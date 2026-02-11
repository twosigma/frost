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
 * Register Alias Table (RAT) - Unified INT + FP with Checkpoint Support
 *
 * Maps architectural registers to in-flight ROB tags for register renaming
 * in the FROST Tomasulo out-of-order execution engine.
 *
 * Features:
 *   - Separate INT (x0-x31) and FP (f0-f31) rename tables
 *   - x0 hardwired: always returns {renamed=0, value=0}, writes ignored
 *   - 5 source lookups: 2 INT, 3 FP (third for FMA src3)
 *   - Single rename write port (from dispatch)
 *   - Commit clear (from ROB) with tag match guard
 *   - 4-slot checkpoint storage for branch speculation recovery
 *   - Checkpoint save/restore/free for misprediction recovery
 *   - RAS state capture in checkpoints
 *   - Full flush (exception) clears all rename state
 *
 * Storage:
 *   Active INT/FP RATs use flip-flops for bulk parallel write on checkpoint
 *   restore and per-entry conditional commit clear. Checkpoint snapshots
 *   use distributed RAM (sdp_dist_ram) — one write port for save, one
 *   async read port for restore. Checkpoint valid bits remain in FFs for
 *   per-entry clear and bulk flush.
 *
 * Note: Struct arrays are avoided for Yosys synthesis compatibility.
 *   Instead, valid bits are stored as packed vectors and tags as
 *   unpacked arrays of logic vectors.
 */

module register_alias_table (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Source Lookup Interface (combinational reads, from Dispatch)
    // =========================================================================
    // INT source lookups
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src1_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src2_addr,
    output riscv_pkg::rat_lookup_t                               o_int_src1,
    output riscv_pkg::rat_lookup_t                               o_int_src2,

    // FP source lookups
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src1_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src2_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src3_addr,
    output riscv_pkg::rat_lookup_t                               o_fp_src1,
    output riscv_pkg::rat_lookup_t                               o_fp_src2,
    output riscv_pkg::rat_lookup_t                               o_fp_src3,

    // Regfile read data (from register files, for value passthrough)
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data1,
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data1,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data3,

    // =========================================================================
    // Rename Write Interface (from Dispatch, synchronous)
    // =========================================================================
    input logic                                        i_alloc_valid,
    input logic                                        i_alloc_dest_rf,   // 0=INT, 1=FP
    input logic [         riscv_pkg::RegAddrWidth-1:0] i_alloc_dest_reg,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_alloc_rob_tag,

    // =========================================================================
    // Commit Interface (from ROB commit output, synchronous)
    // =========================================================================
    /* verilator lint_off UNUSEDSIGNAL */  // RAT uses only a few commit fields
    input riscv_pkg::reorder_buffer_commit_t i_commit,
    /* verilator lint_on UNUSEDSIGNAL */

    // =========================================================================
    // Checkpoint Save Interface (from Dispatch on branch allocation)
    // =========================================================================
    input logic                                        i_checkpoint_save,
    input logic [    riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_id,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_checkpoint_branch_tag,
    input logic [           riscv_pkg::RasPtrBits-1:0] i_ras_tos,
    input logic [             riscv_pkg::RasPtrBits:0] i_ras_valid_count,

    // =========================================================================
    // Checkpoint Restore Interface (from flush controller on misprediction)
    // =========================================================================
    input  logic                                    i_checkpoint_restore,
    input  logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_restore_id,
    output logic [       riscv_pkg::RasPtrBits-1:0] o_ras_tos,
    output logic [         riscv_pkg::RasPtrBits:0] o_ras_valid_count,

    // =========================================================================
    // Checkpoint Free Interface (from ROB on correct branch commit)
    // =========================================================================
    input logic                                    i_checkpoint_free,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_free_id,

    // =========================================================================
    // Flush All (exception)
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
  localparam int unsigned NumCheckpoints = riscv_pkg::NumCheckpoints;  // 4
  localparam int unsigned CheckpointIdWidth = riscv_pkg::CheckpointIdWidth;  // 2
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned RasPtrBits = riscv_pkg::RasPtrBits;  // 3

  // RAT entry width: valid (1) + tag (ReorderBufferTagWidth)
  localparam int unsigned RatEntryWidth = 1 + ReorderBufferTagWidth;  // 6

  // Checkpoint RAM data widths
  // INT RAT snapshot: 32 entries x 6 bits = 192 bits
  localparam int unsigned IntRatSnapshotWidth = NumIntRegs * RatEntryWidth;
  // FP RAT snapshot: 32 entries x 6 bits = 192 bits
  localparam int unsigned FpRatSnapshotWidth = NumFpRegs * RatEntryWidth;
  // Combined RAT snapshot for single wide RAM
  localparam int unsigned RatSnapshotWidth = IntRatSnapshotWidth + FpRatSnapshotWidth;
  // Metadata: branch_tag(5) + ras_tos(3) + ras_valid_count(4) = 12
  localparam int unsigned CheckpointMetaWidth =
      ReorderBufferTagWidth + RasPtrBits + (RasPtrBits + 1);

  // ===========================================================================
  // Debug Signals (for verification)
  // ===========================================================================
  logic dbg_alloc_valid  /* verilator public_flat_rd */;
  assign dbg_alloc_valid = i_alloc_valid;

  logic dbg_alloc_dest_rf  /* verilator public_flat_rd */;
  assign dbg_alloc_dest_rf = i_alloc_dest_rf;

  logic [RegAddrWidth-1:0] dbg_alloc_dest_reg  /* verilator public_flat_rd */;
  assign dbg_alloc_dest_reg = i_alloc_dest_reg;

  logic [ReorderBufferTagWidth-1:0]
      dbg_alloc_rob_tag
/* verilator public_flat_rd */;
  assign dbg_alloc_rob_tag = i_alloc_rob_tag;

  logic dbg_commit_valid  /* verilator public_flat_rd */;
  assign dbg_commit_valid = i_commit.valid;

  logic dbg_checkpoint_save  /* verilator public_flat_rd */;
  assign dbg_checkpoint_save = i_checkpoint_save;

  logic dbg_checkpoint_restore  /* verilator public_flat_rd */;
  assign dbg_checkpoint_restore = i_checkpoint_restore;

  logic dbg_flush_all  /* verilator public_flat_rd */;
  assign dbg_flush_all = i_flush_all;

  // ===========================================================================
  // Active RAT Storage (FF-based, plain arrays for Yosys compatibility)
  // ===========================================================================

  // INT RAT: separate valid and tag arrays
  logic [           NumIntRegs-1:0] int_rat_valid;
  logic [ReorderBufferTagWidth-1:0] int_rat_tag      [NumIntRegs];

  // FP RAT: separate valid and tag arrays
  logic [            NumFpRegs-1:0] fp_rat_valid;
  logic [ReorderBufferTagWidth-1:0] fp_rat_tag       [ NumFpRegs];

  // ===========================================================================
  // Checkpoint Storage
  // ===========================================================================

  // Checkpoint valid bits (FF — need per-entry clear and bulk flush)
  logic [       NumCheckpoints-1:0] checkpoint_valid;

  // Checkpoint RAT snapshots — distributed RAM
  // Combined INT + FP snapshot (384 bits wide, 2-bit address)
  logic                             ckpt_rat_wr_en;
  logic [    CheckpointIdWidth-1:0] ckpt_rat_wr_addr;
  logic [     RatSnapshotWidth-1:0] ckpt_rat_wr_data;
  logic [    CheckpointIdWidth-1:0] ckpt_rat_rd_addr;
  logic [     RatSnapshotWidth-1:0] ckpt_rat_rd_data;

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

  // Checkpoint metadata — distributed RAM
  // branch_tag(5) + ras_tos(3) + ras_valid_count(4) = 12 bits
  logic                           ckpt_meta_wr_en;
  logic [  CheckpointIdWidth-1:0] ckpt_meta_wr_addr;
  logic [CheckpointMetaWidth-1:0] ckpt_meta_wr_data;
  logic [  CheckpointIdWidth-1:0] ckpt_meta_rd_addr;
  /* verilator lint_off UNUSEDSIGNAL */  // branch_tag stored but read externally
  logic [CheckpointMetaWidth-1:0] ckpt_meta_rd_data;
  /* verilator lint_on UNUSEDSIGNAL */

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

  // Write side: checkpoint save
  assign ckpt_rat_wr_en = i_checkpoint_save && !i_flush_all;
  assign ckpt_rat_wr_addr = i_checkpoint_id;
  assign ckpt_meta_wr_en = ckpt_rat_wr_en;
  assign ckpt_meta_wr_addr = i_checkpoint_id;

  // Pack current RAT state for checkpoint save
  // Each entry = {valid, tag} packed into RatEntryWidth bits
  // INT entries at [IntRatSnapshotWidth-1:0],
  // FP entries at [RatSnapshotWidth-1:IntRatSnapshotWidth]
  always_comb begin
    for (int i = 0; i < NumIntRegs; i++) begin
      ckpt_rat_wr_data[i*RatEntryWidth+:RatEntryWidth] = {int_rat_valid[i], int_rat_tag[i]};
    end
    for (int i = 0; i < NumFpRegs; i++) begin
      ckpt_rat_wr_data[IntRatSnapshotWidth+i*RatEntryWidth+:RatEntryWidth] = {
        fp_rat_valid[i], fp_rat_tag[i]
      };
    end
  end

  // Pack metadata for checkpoint save
  assign ckpt_meta_wr_data = {i_ras_valid_count, i_ras_tos, i_checkpoint_branch_tag};

  // Read side: checkpoint restore
  assign ckpt_rat_rd_addr  = i_checkpoint_restore_id;
  assign ckpt_meta_rd_addr = i_checkpoint_restore_id;

  // Unpack restored RAT state
  logic [           NumIntRegs-1:0] restored_int_valid;
  logic [ReorderBufferTagWidth-1:0] restored_int_tag   [NumIntRegs];
  logic [            NumFpRegs-1:0] restored_fp_valid;
  logic [ReorderBufferTagWidth-1:0] restored_fp_tag    [ NumFpRegs];

  always_comb begin
    for (int i = 0; i < NumIntRegs; i++) begin
      restored_int_valid[i] = ckpt_rat_rd_data[i*RatEntryWidth+ReorderBufferTagWidth];
      restored_int_tag[i]   = ckpt_rat_rd_data[i*RatEntryWidth+:ReorderBufferTagWidth];
    end
    for (int i = 0; i < NumFpRegs; i++) begin
      restored_fp_valid[i] =
          ckpt_rat_rd_data[IntRatSnapshotWidth+i*RatEntryWidth+ReorderBufferTagWidth];
      restored_fp_tag[i] =
          ckpt_rat_rd_data[IntRatSnapshotWidth+i*RatEntryWidth+:ReorderBufferTagWidth];
    end
  end

  // Unpack restored metadata
  logic [RasPtrBits-1:0] restored_ras_tos;
  logic [  RasPtrBits:0] restored_ras_valid_count;

  assign restored_ras_tos = ckpt_meta_rd_data[ReorderBufferTagWidth+:RasPtrBits];
  assign restored_ras_valid_count =
      ckpt_meta_rd_data[ReorderBufferTagWidth+RasPtrBits+:(RasPtrBits+1)];

  // Output restored RAS state (active during restore cycle)
  assign o_ras_tos = restored_ras_tos;
  assign o_ras_valid_count = restored_ras_valid_count;

  // ===========================================================================
  // Checkpoint Availability (Priority Encoder)
  // ===========================================================================

  always_comb begin
    o_checkpoint_available = 1'b0;
    o_checkpoint_alloc_id  = '0;
    for (int i = NumCheckpoints - 1; i >= 0; i--) begin
      if (!checkpoint_valid[i]) begin
        o_checkpoint_available = 1'b1;
        o_checkpoint_alloc_id  = i[CheckpointIdWidth-1:0];
      end
    end
  end

  // ===========================================================================
  // Source Lookup (Combinational)
  // ===========================================================================

  // INT source 1
  // rat_lookup_t = {renamed, tag[4:0], value[63:0]}
  always_comb begin
    if (i_int_src1_addr == '0) begin
      // x0 hardwired to zero
      o_int_src1 = {1'b0, {ReorderBufferTagWidth{1'b0}}, {FLEN{1'b0}}};
    end else if (int_rat_valid[i_int_src1_addr]) begin
      o_int_src1 = {
        1'b1, int_rat_tag[i_int_src1_addr], {{(FLEN - XLEN) {1'b0}}, i_int_regfile_data1}
      };
    end else begin
      o_int_src1 = {
        1'b0, {ReorderBufferTagWidth{1'b0}}, {{(FLEN - XLEN) {1'b0}}, i_int_regfile_data1}
      };
    end
  end

  // INT source 2
  always_comb begin
    if (i_int_src2_addr == '0) begin
      o_int_src2 = {1'b0, {ReorderBufferTagWidth{1'b0}}, {FLEN{1'b0}}};
    end else if (int_rat_valid[i_int_src2_addr]) begin
      o_int_src2 = {
        1'b1, int_rat_tag[i_int_src2_addr], {{(FLEN - XLEN) {1'b0}}, i_int_regfile_data2}
      };
    end else begin
      o_int_src2 = {
        1'b0, {ReorderBufferTagWidth{1'b0}}, {{(FLEN - XLEN) {1'b0}}, i_int_regfile_data2}
      };
    end
  end

  // FP source 1
  always_comb begin
    if (fp_rat_valid[i_fp_src1_addr]) begin
      o_fp_src1 = {1'b1, fp_rat_tag[i_fp_src1_addr], i_fp_regfile_data1};
    end else begin
      o_fp_src1 = {1'b0, {ReorderBufferTagWidth{1'b0}}, i_fp_regfile_data1};
    end
  end

  // FP source 2
  always_comb begin
    if (fp_rat_valid[i_fp_src2_addr]) begin
      o_fp_src2 = {1'b1, fp_rat_tag[i_fp_src2_addr], i_fp_regfile_data2};
    end else begin
      o_fp_src2 = {1'b0, {ReorderBufferTagWidth{1'b0}}, i_fp_regfile_data2};
    end
  end

  // FP source 3 (for FMA)
  always_comb begin
    if (fp_rat_valid[i_fp_src3_addr]) begin
      o_fp_src3 = {1'b1, fp_rat_tag[i_fp_src3_addr], i_fp_regfile_data3};
    end else begin
      o_fp_src3 = {1'b0, {ReorderBufferTagWidth{1'b0}}, i_fp_regfile_data3};
    end
  end

  // ===========================================================================
  // Sequential Logic: Active RAT Updates
  // ===========================================================================

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      // Reset: all entries not renamed
      int_rat_valid <= '0;
      fp_rat_valid  <= '0;
      for (int i = 0; i < NumIntRegs; i++) begin
        int_rat_tag[i] <= '0;
      end
      for (int i = 0; i < NumFpRegs; i++) begin
        fp_rat_tag[i] <= '0;
      end
    end else if (i_flush_all) begin
      // Full flush: clear all valid bits (tags don't matter)
      int_rat_valid <= '0;
      fp_rat_valid  <= '0;
    end else if (i_checkpoint_restore) begin
      // Checkpoint restore: bulk overwrite from checkpoint RAM
      int_rat_valid <= restored_int_valid;
      fp_rat_valid  <= restored_fp_valid;
      for (int i = 0; i < NumIntRegs; i++) begin
        int_rat_tag[i] <= restored_int_tag[i];
      end
      for (int i = 0; i < NumFpRegs; i++) begin
        fp_rat_tag[i] <= restored_fp_tag[i];
      end
    end else begin
      // ---------------------------------------------------------------
      // Commit clear: if committing tag matches current RAT entry,
      // clear it (arch regfile now holds the committed value)
      // ---------------------------------------------------------------
      if (i_commit.valid && i_commit.dest_valid) begin
        if (!i_commit.dest_rf) begin
          // INT commit
          if (i_commit.dest_reg != '0 &&
              int_rat_valid[i_commit.dest_reg] &&
              int_rat_tag[i_commit.dest_reg] == i_commit.tag) begin
            int_rat_valid[i_commit.dest_reg] <= 1'b0;
          end
        end else begin
          // FP commit
          if (fp_rat_valid[i_commit.dest_reg] &&
              fp_rat_tag[i_commit.dest_reg] == i_commit.tag) begin
            fp_rat_valid[i_commit.dest_reg] <= 1'b0;
          end
        end
      end

      // ---------------------------------------------------------------
      // Rename write: new instruction's destination mapping
      // Rename takes priority over commit to the same register
      // ---------------------------------------------------------------
      if (i_alloc_valid) begin
        if (!i_alloc_dest_rf) begin
          // INT rename (x0 writes are ignored)
          if (i_alloc_dest_reg != '0) begin
            int_rat_valid[i_alloc_dest_reg] <= 1'b1;
            int_rat_tag[i_alloc_dest_reg]   <= i_alloc_rob_tag;
          end
        end else begin
          // FP rename
          fp_rat_valid[i_alloc_dest_reg] <= 1'b1;
          fp_rat_tag[i_alloc_dest_reg]   <= i_alloc_rob_tag;
        end
      end
    end
  end

  // ===========================================================================
  // Sequential Logic: Checkpoint Valid Bits
  // ===========================================================================

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      checkpoint_valid <= '0;
    end else if (i_flush_all) begin
      checkpoint_valid <= '0;
    end else begin
      // Checkpoint save: mark slot valid
      if (i_checkpoint_save) begin
        checkpoint_valid[i_checkpoint_id] <= 1'b1;
      end

      // Checkpoint free: mark slot invalid
      if (i_checkpoint_free) begin
        checkpoint_valid[i_checkpoint_free_id] <= 1'b0;
      end
    end
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

  // No INT rename to x0
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_valid && !i_alloc_dest_rf && i_alloc_dest_reg == '0) begin
      $error("RAT: Rename write to INT x0 attempted!");
    end
  end

  // Checkpoint save and restore should not happen simultaneously
  always @(posedge i_clk) begin
    if (i_rst_n && i_checkpoint_save && i_checkpoint_restore) begin
      $error("RAT: Simultaneous checkpoint save and restore!");
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

  // -------------------------------------------------------------------------
  // Structural constraints (assumes)
  // -------------------------------------------------------------------------

  // No rename during flush_all or checkpoint_restore
  always_comb begin
    assume (!(i_alloc_valid && i_flush_all));
    assume (!(i_alloc_valid && i_checkpoint_restore));
  end

  // Checkpoint save and restore not simultaneous
  always_comb begin
    assume (!(i_checkpoint_save && i_checkpoint_restore));
  end

  // Checkpoint restore targets a valid checkpoint
  always_comb begin
    if (i_checkpoint_restore) begin
      assume (checkpoint_valid[i_checkpoint_restore_id]);
    end
  end

  // Dispatch never renames x0 (INT)
  always_comb begin
    if (i_alloc_valid && !i_alloc_dest_rf) begin
      assume (i_alloc_dest_reg != '0);
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
      // After flush_all, all valid bits are 0
      if ($past(i_flush_all)) begin
        p_flush_clears_int : assert (int_rat_valid == '0);
        p_flush_clears_fp : assert (fp_rat_valid == '0);
        p_flush_clears_ckpts : assert (checkpoint_valid == '0);
      end

      // After INT rename (non-x0), entry is valid with correct tag
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

      // After FP rename, entry is valid with correct tag
      if ($past(
              i_alloc_valid
          ) && $past(
              i_alloc_dest_rf
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
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

      // Commit clears entry when tag matches (INT)
      if ($past(
              i_commit.valid
          ) && $past(
              i_commit.dest_valid
          ) && !$past(
              i_commit.dest_rf
          ) && $past(
              i_commit.dest_reg
          ) != '0 && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          ) && !$past(
              i_alloc_valid && !i_alloc_dest_rf && i_alloc_dest_reg == i_commit.dest_reg
          )) begin
        if ($past(
                int_rat_valid[i_commit.dest_reg]
            ) && $past(
                int_rat_tag[i_commit.dest_reg]
            ) == $past(
                i_commit.tag
            )) begin
          p_commit_clears_int : assert (!int_rat_valid[$past(i_commit.dest_reg)]);
        end
        if ($past(
                int_rat_valid[i_commit.dest_reg]
            ) && $past(
                int_rat_tag[i_commit.dest_reg]
            ) != $past(
                i_commit.tag
            )) begin
          p_commit_preserves_int : assert (int_rat_valid[$past(i_commit.dest_reg)]);
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
        i_alloc_valid && i_commit.valid && i_commit.dest_valid &&
        i_alloc_dest_rf == i_commit.dest_rf &&
        i_alloc_dest_reg == i_commit.dest_reg
      );

      // All 4 checkpoints in use (exhaustion)
      cover_ckpt_exhaustion : cover (checkpoint_valid == {NumCheckpoints{1'b1}});

      // Checkpoint save
      cover_ckpt_save : cover (i_checkpoint_save);

      // Checkpoint restore
      cover_ckpt_restore : cover (i_checkpoint_restore);

      // Full flush from non-empty state
      cover_flush_nonempty : cover (i_flush_all && (int_rat_valid[1] || fp_rat_valid[0]));
    end
  end

`endif  // FORMAL

endmodule : register_alias_table
