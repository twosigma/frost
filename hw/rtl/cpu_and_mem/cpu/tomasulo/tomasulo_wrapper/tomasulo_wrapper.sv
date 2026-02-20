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
 * Tomasulo Integration Wrapper
 *
 * Verification wrapper that instantiates ROB + RAT + one RS (INT_RS, depth 8)
 * and hardwires the internal commit bus and shared CDB/flush signals.
 *
 * Replaces the previous rob_rat_wrapper as the integration test vehicle.
 * This wrapper will grow as CDB arbiter, LQ, SQ, ALUs, and FPUs are added.
 *
 * Internal wiring:
 *   ROB.o_commit --> commit_bus --> RAT.i_commit
 *                               --> o_commit (exposed for testbench observation)
 *   i_cdb_write  --> ROB.i_cdb_write
 *   i_cdb        --> RS.i_cdb (broadcast format for wakeup)
 *   Flush --> all three modules
 *   ROB.o_head_tag --> RS.i_rob_head_tag (for age-based partial flush)
 */

module tomasulo_wrapper (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // ROB Allocation Interface (from Dispatch)
    // =========================================================================
    input  riscv_pkg::reorder_buffer_alloc_req_t  i_alloc_req,
    output riscv_pkg::reorder_buffer_alloc_resp_t o_alloc_resp,

    // =========================================================================
    // ROB CDB Write Interface (from Functional Units via CDB)
    // =========================================================================
    input riscv_pkg::reorder_buffer_cdb_write_t i_cdb_write,

    // =========================================================================
    // CDB Broadcast for RS Wakeup
    // =========================================================================
    input riscv_pkg::cdb_broadcast_t i_cdb,

    // =========================================================================
    // ROB Branch Update Interface (from Branch Unit)
    // =========================================================================
    input riscv_pkg::reorder_buffer_branch_update_t i_branch_update,

    // =========================================================================
    // ROB Checkpoint Recording (from Dispatch)
    // =========================================================================
    input logic                                    i_rob_checkpoint_valid,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_rob_checkpoint_id,

    // =========================================================================
    // Commit Observation (tapped from internal commit bus)
    // =========================================================================
    output riscv_pkg::reorder_buffer_commit_t o_commit,

    // =========================================================================
    // ROB External Coordination
    // =========================================================================
    input  logic                                        i_sq_empty,
    output logic                                        o_csr_start,
    input  logic                                        i_csr_done,
    output logic                                        o_trap_pending,
    output logic                  [riscv_pkg::XLEN-1:0] o_trap_pc,
    output riscv_pkg::exc_cause_t                       o_trap_cause,
    input  logic                                        i_trap_taken,
    output logic                                        o_mret_start,
    input  logic                                        i_mret_done,
    input  logic                  [riscv_pkg::XLEN-1:0] i_mepc,
    input  logic                                        i_interrupt_pending,

    // =========================================================================
    // Flush
    // =========================================================================
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic                                        i_flush_all,

    // =========================================================================
    // ROB Status
    // =========================================================================
    output logic                                        o_fence_i_flush,
    output logic                                        o_rob_full,
    output logic                                        o_rob_empty,
    output logic [  riscv_pkg::ReorderBufferTagWidth:0] o_rob_count,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_head_tag,
    output logic                                        o_head_valid,
    output logic                                        o_head_done,

    // =========================================================================
    // ROB Bypass Read
    // =========================================================================
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_read_tag,
    output logic                                        o_read_done,
    output logic [                 riscv_pkg::FLEN-1:0] o_read_value,

    // =========================================================================
    // RAT Source Lookups (combinational)
    // =========================================================================
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src1_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_int_src2_addr,
    output riscv_pkg::rat_lookup_t                               o_int_src1,
    output riscv_pkg::rat_lookup_t                               o_int_src2,

    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src1_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src2_addr,
    input  logic                   [riscv_pkg::RegAddrWidth-1:0] i_fp_src3_addr,
    output riscv_pkg::rat_lookup_t                               o_fp_src1,
    output riscv_pkg::rat_lookup_t                               o_fp_src2,
    output riscv_pkg::rat_lookup_t                               o_fp_src3,

    // RAT Regfile data
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data1,
    input logic [riscv_pkg::XLEN-1:0] i_int_regfile_data2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data1,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data2,
    input logic [riscv_pkg::FLEN-1:0] i_fp_regfile_data3,

    // =========================================================================
    // RAT Rename (from Dispatch)
    // =========================================================================
    input logic                                        i_rat_alloc_valid,
    input logic                                        i_rat_alloc_dest_rf,
    input logic [         riscv_pkg::RegAddrWidth-1:0] i_rat_alloc_dest_reg,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rat_alloc_rob_tag,

    // =========================================================================
    // RAT Checkpoint Save (from Dispatch on branch allocation)
    // =========================================================================
    input logic                                        i_checkpoint_save,
    input logic [    riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_id,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_checkpoint_branch_tag,
    input logic [           riscv_pkg::RasPtrBits-1:0] i_ras_tos,
    input logic [             riscv_pkg::RasPtrBits:0] i_ras_valid_count,

    // =========================================================================
    // RAT Checkpoint Restore (from flush controller on misprediction)
    // =========================================================================
    input  logic                                    i_checkpoint_restore,
    input  logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_restore_id,
    output logic [       riscv_pkg::RasPtrBits-1:0] o_ras_tos,
    output logic [         riscv_pkg::RasPtrBits:0] o_ras_valid_count,

    // =========================================================================
    // RAT Checkpoint Free (from ROB on correct branch commit)
    // =========================================================================
    input logic                                    i_checkpoint_free,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_free_id,

    // =========================================================================
    // RAT Checkpoint Availability
    // =========================================================================
    output logic                                    o_checkpoint_available,
    output logic [riscv_pkg::CheckpointIdWidth-1:0] o_checkpoint_alloc_id,

    // =========================================================================
    // RS Dispatch (from Dispatch)
    // =========================================================================
`ifdef ICARUS
    input logic i_rs_dispatch_valid,
    input logic [2:0] i_rs_dispatch_rs_type,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rs_dispatch_rob_tag,
    input logic [31:0] i_rs_dispatch_op,
    input logic i_rs_dispatch_src1_ready,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rs_dispatch_src1_tag,
    input logic [riscv_pkg::FLEN-1:0] i_rs_dispatch_src1_value,
    input logic i_rs_dispatch_src2_ready,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rs_dispatch_src2_tag,
    input logic [riscv_pkg::FLEN-1:0] i_rs_dispatch_src2_value,
    input logic i_rs_dispatch_src3_ready,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rs_dispatch_src3_tag,
    input logic [riscv_pkg::FLEN-1:0] i_rs_dispatch_src3_value,
    input logic [riscv_pkg::XLEN-1:0] i_rs_dispatch_imm,
    input logic i_rs_dispatch_use_imm,
    input logic [2:0] i_rs_dispatch_rm,
    input logic [riscv_pkg::XLEN-1:0] i_rs_dispatch_branch_target,
    input logic i_rs_dispatch_predicted_taken,
    input logic [riscv_pkg::XLEN-1:0] i_rs_dispatch_predicted_target,
    input logic i_rs_dispatch_is_fp_mem,
    input logic [1:0] i_rs_dispatch_mem_size,
    input logic i_rs_dispatch_mem_signed,
    input logic [11:0] i_rs_dispatch_csr_addr,
    input logic [4:0] i_rs_dispatch_csr_imm,
`else
    input riscv_pkg::rs_dispatch_t i_rs_dispatch,
`endif
    output logic o_rs_full,

    // =========================================================================
    // RS Issue (to Functional Unit)
    // =========================================================================
`ifdef ICARUS
    output logic                                                        o_rs_issue_valid,
    output logic                 [riscv_pkg::ReorderBufferTagWidth-1:0] o_rs_issue_rob_tag,
    output logic                 [                                31:0] o_rs_issue_op,
    output logic                 [                 riscv_pkg::FLEN-1:0] o_rs_issue_src1_value,
    output logic                 [                 riscv_pkg::FLEN-1:0] o_rs_issue_src2_value,
    output logic                 [                 riscv_pkg::FLEN-1:0] o_rs_issue_src3_value,
    output logic                 [                 riscv_pkg::XLEN-1:0] o_rs_issue_imm,
    output logic                                                        o_rs_issue_use_imm,
    output logic                 [                                 2:0] o_rs_issue_rm,
    output logic                 [                 riscv_pkg::XLEN-1:0] o_rs_issue_branch_target,
    output logic                                                        o_rs_issue_predicted_taken,
    output logic                 [                 riscv_pkg::XLEN-1:0] o_rs_issue_predicted_target,
    output logic                                                        o_rs_issue_is_fp_mem,
    output logic                 [                                 1:0] o_rs_issue_mem_size,
    output logic                                                        o_rs_issue_mem_signed,
    output logic                 [                                11:0] o_rs_issue_csr_addr,
    output logic                 [                                 4:0] o_rs_issue_csr_imm,
`else
    output riscv_pkg::rs_issue_t                                        o_rs_issue,
`endif
    input  logic                                                        i_rs_fu_ready,

    // =========================================================================
    // RS Status
    // =========================================================================
    output logic       o_rs_empty,
    output logic [3:0] o_rs_count
);

  // ===========================================================================
  // Internal commit bus: ROB -> RAT
  // ===========================================================================
  riscv_pkg::reorder_buffer_commit_t commit_bus;

  // Expose commit bus to testbench
  assign o_commit = commit_bus;

  // Head tag for RS partial flush
  logic [riscv_pkg::ReorderBufferTagWidth-1:0] head_tag;
  assign head_tag = o_head_tag;

  // ===========================================================================
  // Reorder Buffer Instance
  // ===========================================================================
  reorder_buffer u_rob (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Allocation
      .i_alloc_req (i_alloc_req),
      .o_alloc_resp(o_alloc_resp),

      // CDB
      .i_cdb_write(i_cdb_write),

      // Branch
      .i_branch_update(i_branch_update),

      // Checkpoint recording
      .i_checkpoint_valid(i_rob_checkpoint_valid),
      .i_checkpoint_id   (i_rob_checkpoint_id),

      // Commit output -> internal bus
      .o_commit(commit_bus),

      // External coordination
      .i_sq_empty         (i_sq_empty),
      .o_csr_start        (o_csr_start),
      .i_csr_done         (i_csr_done),
      .o_trap_pending     (o_trap_pending),
      .o_trap_pc          (o_trap_pc),
      .o_trap_cause       (o_trap_cause),
      .i_trap_taken       (i_trap_taken),
      .o_mret_start       (o_mret_start),
      .i_mret_done        (i_mret_done),
      .i_mepc             (i_mepc),
      .i_interrupt_pending(i_interrupt_pending),

      // Flush
      .i_flush_en (i_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_flush_all(i_flush_all),

      // Status
      .o_fence_i_flush(o_fence_i_flush),
      .o_full         (o_rob_full),
      .o_empty        (o_rob_empty),
      .o_count        (o_rob_count),
      .o_head_tag     (o_head_tag),
      .o_head_valid   (o_head_valid),
      .o_head_done    (o_head_done),

      // Bypass read
      .i_read_tag  (i_read_tag),
      .o_read_done (o_read_done),
      .o_read_value(o_read_value)
  );

  // ===========================================================================
  // Register Alias Table Instance
  // ===========================================================================
  register_alias_table u_rat (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Source lookups
      .i_int_src1_addr(i_int_src1_addr),
      .i_int_src2_addr(i_int_src2_addr),
      .o_int_src1     (o_int_src1),
      .o_int_src2     (o_int_src2),
      .i_fp_src1_addr (i_fp_src1_addr),
      .i_fp_src2_addr (i_fp_src2_addr),
      .i_fp_src3_addr (i_fp_src3_addr),
      .o_fp_src1      (o_fp_src1),
      .o_fp_src2      (o_fp_src2),
      .o_fp_src3      (o_fp_src3),

      // Regfile data
      .i_int_regfile_data1(i_int_regfile_data1),
      .i_int_regfile_data2(i_int_regfile_data2),
      .i_fp_regfile_data1 (i_fp_regfile_data1),
      .i_fp_regfile_data2 (i_fp_regfile_data2),
      .i_fp_regfile_data3 (i_fp_regfile_data3),

      // Rename
      .i_alloc_valid   (i_rat_alloc_valid),
      .i_alloc_dest_rf (i_rat_alloc_dest_rf),
      .i_alloc_dest_reg(i_rat_alloc_dest_reg),
      .i_alloc_rob_tag (i_rat_alloc_rob_tag),

      // Commit (from internal bus)
      .i_commit(commit_bus),

      // Checkpoint save
      .i_checkpoint_save      (i_checkpoint_save),
      .i_checkpoint_id        (i_checkpoint_id),
      .i_checkpoint_branch_tag(i_checkpoint_branch_tag),
      .i_ras_tos              (i_ras_tos),
      .i_ras_valid_count      (i_ras_valid_count),

      // Checkpoint restore
      .i_checkpoint_restore   (i_checkpoint_restore),
      .i_checkpoint_restore_id(i_checkpoint_restore_id),
      .o_ras_tos              (o_ras_tos),
      .o_ras_valid_count      (o_ras_valid_count),

      // Checkpoint free
      .i_checkpoint_free   (i_checkpoint_free),
      .i_checkpoint_free_id(i_checkpoint_free_id),

      // Flush
      .i_flush_all(i_flush_all),

      // Checkpoint availability
      .o_checkpoint_available(o_checkpoint_available),
      .o_checkpoint_alloc_id (o_checkpoint_alloc_id)
  );

  // ===========================================================================
  // Reservation Station Instance (INT_RS, depth 8)
  // ===========================================================================
`ifdef ICARUS
  // Individual port connections -- avoids wide packed struct VPI-facing ports
  // (Icarus VPI crashes on 352+ bit struct ports; see reservation_station.sv).
  reservation_station #(
      .DEPTH(riscv_pkg::IntRsDepth)
  ) u_rs (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Dispatch (individual ports)
      .i_dispatch_valid           (i_rs_dispatch_valid),
      .i_dispatch_rs_type         (i_rs_dispatch_rs_type),
      .i_dispatch_rob_tag         (i_rs_dispatch_rob_tag),
      .i_dispatch_op              (i_rs_dispatch_op),
      .i_dispatch_src1_ready      (i_rs_dispatch_src1_ready),
      .i_dispatch_src1_tag        (i_rs_dispatch_src1_tag),
      .i_dispatch_src1_value      (i_rs_dispatch_src1_value),
      .i_dispatch_src2_ready      (i_rs_dispatch_src2_ready),
      .i_dispatch_src2_tag        (i_rs_dispatch_src2_tag),
      .i_dispatch_src2_value      (i_rs_dispatch_src2_value),
      .i_dispatch_src3_ready      (i_rs_dispatch_src3_ready),
      .i_dispatch_src3_tag        (i_rs_dispatch_src3_tag),
      .i_dispatch_src3_value      (i_rs_dispatch_src3_value),
      .i_dispatch_imm             (i_rs_dispatch_imm),
      .i_dispatch_use_imm         (i_rs_dispatch_use_imm),
      .i_dispatch_rm              (i_rs_dispatch_rm),
      .i_dispatch_branch_target   (i_rs_dispatch_branch_target),
      .i_dispatch_predicted_taken (i_rs_dispatch_predicted_taken),
      .i_dispatch_predicted_target(i_rs_dispatch_predicted_target),
      .i_dispatch_is_fp_mem       (i_rs_dispatch_is_fp_mem),
      .i_dispatch_mem_size        (i_rs_dispatch_mem_size),
      .i_dispatch_mem_signed      (i_rs_dispatch_mem_signed),
      .i_dispatch_csr_addr        (i_rs_dispatch_csr_addr),
      .i_dispatch_csr_imm         (i_rs_dispatch_csr_imm),
      .o_full                     (o_rs_full),

      // CDB snoop
      .i_cdb(i_cdb),

      // Issue (individual ports)
      .o_issue_valid           (o_rs_issue_valid),
      .o_issue_rob_tag         (o_rs_issue_rob_tag),
      .o_issue_op              (o_rs_issue_op),
      .o_issue_src1_value      (o_rs_issue_src1_value),
      .o_issue_src2_value      (o_rs_issue_src2_value),
      .o_issue_src3_value      (o_rs_issue_src3_value),
      .o_issue_imm             (o_rs_issue_imm),
      .o_issue_use_imm         (o_rs_issue_use_imm),
      .o_issue_rm              (o_rs_issue_rm),
      .o_issue_branch_target   (o_rs_issue_branch_target),
      .o_issue_predicted_taken (o_rs_issue_predicted_taken),
      .o_issue_predicted_target(o_rs_issue_predicted_target),
      .o_issue_is_fp_mem       (o_rs_issue_is_fp_mem),
      .o_issue_mem_size        (o_rs_issue_mem_size),
      .o_issue_mem_signed      (o_rs_issue_mem_signed),
      .o_issue_csr_addr        (o_rs_issue_csr_addr),
      .o_issue_csr_imm         (o_rs_issue_csr_imm),
      .i_fu_ready              (i_rs_fu_ready),

      // Flush (shared with ROB)
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all   (i_flush_all),

      // Status
      .o_empty(o_rs_empty),
      .o_count(o_rs_count)
  );
`else
  // Packed struct port connections (Verilator, synthesis, formal).
  reservation_station #(
      .DEPTH(riscv_pkg::IntRsDepth)
  ) u_rs (
      .i_clk  (i_clk),
      .i_rst_n(i_rst_n),

      // Dispatch
      .i_dispatch(i_rs_dispatch),
      .o_full    (o_rs_full),

      // CDB snoop
      .i_cdb(i_cdb),

      // Issue
      .o_issue(o_rs_issue),
      .i_fu_ready(i_rs_fu_ready),

      // Flush (shared with ROB)
      .i_flush_en    (i_flush_en),
      .i_flush_tag   (i_flush_tag),
      .i_rob_head_tag(head_tag),
      .i_flush_all   (i_flush_all),

      // Status
      .o_empty(o_rs_empty),
      .o_count(o_rs_count)
  );
`endif

  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // -------------------------------------------------------------------------
  // Structural constraints (from rob_rat_wrapper)
  // -------------------------------------------------------------------------

  // CDB write and branch update cannot target same tag simultaneously
  always_comb begin
    assume (!(i_cdb_write.valid && i_branch_update.valid &&
              i_cdb_write.tag == i_branch_update.tag));
  end

  // No allocation during flush
  always_comb begin
    assume (!(i_alloc_req.alloc_valid && (i_flush_en || i_flush_all)));
  end

  // No rename during full flush
  always_comb assume (!(i_rat_alloc_valid && i_flush_all));

  // No rename during checkpoint restore
  always_comb assume (!(i_rat_alloc_valid && i_checkpoint_restore));

  // Checkpoint save and restore are mutually exclusive
  always_comb assume (!(i_checkpoint_save && i_checkpoint_restore));

  // Shadow-track checkpoint validity
  reg [riscv_pkg::NumCheckpoints-1:0] f_cp_valid;

  initial f_cp_valid = '0;

  always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      f_cp_valid <= '0;
    end else if (i_flush_all) begin
      f_cp_valid <= '0;
    end else begin
      if (i_checkpoint_save) f_cp_valid[i_checkpoint_id] <= 1'b1;
      if (i_checkpoint_free) f_cp_valid[i_checkpoint_free_id] <= 1'b0;
    end
  end

  always_comb begin
    if (i_checkpoint_restore) assume (f_cp_valid[i_checkpoint_restore_id]);
  end

  // Dispatch never renames x0 to INT
  always_comb begin
    if (i_rat_alloc_valid && !i_rat_alloc_dest_rf) assume (i_rat_alloc_dest_reg != '0);
  end

  // Dispatch tag coordination
  always_comb begin
    if (i_alloc_req.alloc_valid && i_rat_alloc_valid) begin
      assume (i_rat_alloc_rob_tag == o_alloc_resp.alloc_tag);
    end
  end

  // Checkpoint ID coordination
  always_comb begin
    if (i_rob_checkpoint_valid && i_checkpoint_save) begin
      assume (i_rob_checkpoint_id == i_checkpoint_id);
    end
  end

  // No RS dispatch during flush
  always_comb begin
    assume (!(i_rs_dispatch.valid && (i_flush_en || i_flush_all)));
  end

  // No RS dispatch when full
  always_comb begin
    if (o_rs_full) assume (!i_rs_dispatch.valid);
  end

  // -------------------------------------------------------------------------
  // Observation: track an arbitrary INT register via lookups
  // -------------------------------------------------------------------------
  (* anyconst *)reg [riscv_pkg::RegAddrWidth-1:0] f_int_track;
  (* anyconst *)reg [riscv_pkg::RegAddrWidth-1:0] f_fp_track;

  always_comb begin
    assume (f_int_track != '0);
    assume (i_int_src1_addr == f_int_track);
    assume (i_fp_src1_addr == f_fp_track);
  end

  // -------------------------------------------------------------------------
  // Commit bus assertions (from rob_rat_wrapper)
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      p_commit_output_identity : assert (o_commit == commit_bus);
      p_commit_requires_head_ready : assert (!commit_bus.valid || (o_head_valid && o_head_done));
      p_commit_tag_is_head : assert (!commit_bus.valid || (commit_bus.tag == o_head_tag));
    end
  end

  // -------------------------------------------------------------------------
  // Sequential: commit propagation and flush
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin

      // INT commit clears RAT entry when tag matches
      if ($past(
              commit_bus.valid
          ) && $past(
              commit_bus.dest_valid
          ) && !$past(
              commit_bus.dest_rf
          ) && $past(
              commit_bus.dest_reg
          ) == f_int_track && $past(
              o_int_src1.renamed
          ) && $past(
              o_int_src1.tag
          ) == $past(
              commit_bus.tag
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          ) && !($past(
              i_rat_alloc_valid
          ) && !$past(
              i_rat_alloc_dest_rf
          ) && $past(
              i_rat_alloc_dest_reg
          ) == f_int_track)) begin
        p_commit_clears_int_via_bus : assert (!o_int_src1.renamed);
      end

      // INT WAW: commit does NOT clear when tag mismatches (newer rename)
      if ($past(
              commit_bus.valid
          ) && $past(
              commit_bus.dest_valid
          ) && !$past(
              commit_bus.dest_rf
          ) && $past(
              commit_bus.dest_reg
          ) == f_int_track && $past(
              o_int_src1.renamed
          ) && $past(
              o_int_src1.tag
          ) != $past(
              commit_bus.tag
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          ) && !($past(
              i_rat_alloc_valid
          ) && !$past(
              i_rat_alloc_dest_rf
          ) && $past(
              i_rat_alloc_dest_reg
          ) == f_int_track)) begin
        p_waw_preserves_newer_int : assert (o_int_src1.renamed);
      end

      // FP commit clears RAT entry when tag matches
      if ($past(
              commit_bus.valid
          ) && $past(
              commit_bus.dest_valid
          ) && $past(
              commit_bus.dest_rf
          ) && $past(
              commit_bus.dest_reg
          ) == f_fp_track && $past(
              o_fp_src1.renamed
          ) && $past(
              o_fp_src1.tag
          ) == $past(
              commit_bus.tag
          ) && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          ) && !($past(
              i_rat_alloc_valid
          ) && $past(
              i_rat_alloc_dest_rf
          ) && $past(
              i_rat_alloc_dest_reg
          ) == f_fp_track)) begin
        p_commit_clears_fp_via_bus : assert (!o_fp_src1.renamed);
      end

    end
  end

  // -------------------------------------------------------------------------
  // Sequential: rename-vs-commit same-cycle precedence
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin
      if ($past(
              i_rat_alloc_valid
          ) && !$past(
              i_rat_alloc_dest_rf
          ) && $past(
              i_rat_alloc_dest_reg
          ) == f_int_track && $past(
              commit_bus.valid
          ) && $past(
              commit_bus.dest_valid
          ) && !$past(
              commit_bus.dest_rf
          ) && $past(
              commit_bus.dest_reg
          ) == f_int_track && !$past(
              i_flush_all
          ) && !$past(
              i_checkpoint_restore
          )) begin
        p_rename_wins_over_commit :
        assert (o_int_src1.renamed && o_int_src1.tag == $past(i_rat_alloc_rob_tag));
      end
    end
  end

  // -------------------------------------------------------------------------
  // Sequential: flush / recovery composition
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin
      // flush_all empties ROB
      if ($past(i_flush_all)) begin
        p_flush_all_empties_rob : assert (o_rob_empty);
      end

      // flush_all empties RS
      if ($past(i_flush_all)) begin
        p_flush_all_empties_rs : assert (o_rs_empty);
      end

      // flush_all frees all checkpoints
      if ($past(i_flush_all)) begin
        p_flush_all_frees_checkpoints : assert (o_checkpoint_available);
      end

      // flush_all clears INT rename
      if ($past(i_flush_all)) begin
        p_flush_all_clears_int_rename : assert (!o_int_src1.renamed);
      end

      // flush_all clears FP rename
      if ($past(i_flush_all)) begin
        p_flush_all_clears_fp_rename : assert (!o_fp_src1.renamed);
      end
    end

    // Reset properties
    if (f_past_valid && i_rst_n && !$past(i_rst_n)) begin
      p_reset_rob_empty : assert (o_rob_empty);
      p_reset_rs_empty : assert (o_rs_empty);
      p_reset_checkpoints_available : assert (o_checkpoint_available);
      p_reset_int_not_renamed : assert (!o_int_src1.renamed);
      p_reset_fp_not_renamed : assert (!o_fp_src1.renamed);
    end
  end

  // -------------------------------------------------------------------------
  // Cover properties
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // RS issue fires
      cover_rs_issue : cover (o_rs_issue.valid);

      // CDB simultaneously present with RS dispatch
      cover_cdb_and_rs_dispatch : cover (i_cdb.valid && i_rs_dispatch.valid);

      // flush_all while RS non-empty
      cover_flush_while_rs_nonempty : cover (i_flush_all && !o_rs_empty);

      // Commit fires
      cover_commit : cover (commit_bus.valid);

      // RS full: removed -- needs 9+ steps (8 dispatches + reset) but wrapper
      // cover depth is 8.  Covered by reservation_station.sby at depth 20.

      // Commit clears tracked INT register
      cover_commit_clears_int :
      cover (
        commit_bus.valid && commit_bus.dest_valid && !commit_bus.dest_rf &&
        commit_bus.dest_reg == f_int_track &&
        o_int_src1.renamed && o_int_src1.tag == commit_bus.tag
      );

      // Rename and commit target same INT register in same cycle
      cover_rename_commit_same_cycle :
      cover (
        i_rat_alloc_valid && !i_rat_alloc_dest_rf &&
        i_rat_alloc_dest_reg == f_int_track &&
        commit_bus.valid && commit_bus.dest_valid &&
        !commit_bus.dest_rf && commit_bus.dest_reg == f_int_track
      );

      // WAW: commit for tracked register with tag mismatch
      cover_waw_tag_mismatch :
      cover (
        commit_bus.valid && commit_bus.dest_valid && !commit_bus.dest_rf &&
        commit_bus.dest_reg == f_int_track &&
        o_int_src1.renamed && o_int_src1.tag != commit_bus.tag
      );

      // flush_all while tracked INT register is renamed
      cover_flush_while_renamed : cover (i_flush_all && o_int_src1.renamed);

      // Checkpoint save + ROB checkpoint recording in same cycle
      cover_checkpoint_save : cover (i_checkpoint_save && i_rob_checkpoint_valid);

      // Checkpoint restore (misprediction recovery)
      cover_checkpoint_restore : cover (i_checkpoint_restore);

      // FP commit via internal bus
      cover_fp_commit_via_bus :
      cover (commit_bus.valid && commit_bus.dest_valid && commit_bus.dest_rf);
    end
  end

`endif  // FORMAL

endmodule
