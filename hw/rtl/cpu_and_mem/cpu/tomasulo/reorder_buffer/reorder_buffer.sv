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
 * Reorder Buffer - Complete Implementation
 *
 * Implements a circular buffer for in-order instruction commit in the
 * Tomasulo out-of-order execution engine. Supports unified INT/FP entries.
 *
 * Features:
 *   - 32-entry circular buffer with head/tail pointers
 *   - Allocation interface for dispatch unit
 *   - CDB write interface for functional unit results
 *   - Branch update interface for branch resolution
 *   - In-order commit with INT/FP destination writeback
 *   - Exception handling with trap signaling
 *   - Serializing instruction support:
 *       * WFI: stall at head until interrupt pending
 *       * CSR: reads execute speculatively, side effects applied at commit
 *       * FENCE: wait for store queue to drain
 *       * FENCE.I: drain SQ + signal pipeline/icache flush
 *       * MRET: signal trap unit, redirect to mepc
 *   - Atomic instruction ordering (AMO/LR/SC at head with SQ empty)
 *   - Branch misprediction detection and flush
 *   - FP exception flag propagation for fcsr accumulation
 *
 * Storage:
 *   Multi-bit fields use distributed RAM (LUTRAM) to reduce FF usage.
 *   Single-write-port fields (written only at allocation) use sdp_dist_ram.
 *   Multi-write-port fields (allocation + CDB/branch) use mwp_dist_ram
 *   with a Live Value Table. 1-bit packed vectors that need per-entry
 *   flush/reset remain in flip-flops.
 *
 * External Coordination:
 *   The Reorder Buffer coordinates with several external units via handshake signals:
 *   - Store Queue: i_sq_empty for FENCE/AMO ordering
 *   - CSR Unit: o_csr_start/i_csr_done for CSR side effects at commit
 *   - Trap Unit: o_trap_pending/i_trap_taken for exception handling
 *   - Interrupt Controller: i_interrupt_pending for WFI
 */

module reorder_buffer (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Allocation Interface (from Dispatch)
    // =========================================================================
    input  riscv_pkg::reorder_buffer_alloc_req_t  i_alloc_req,
    output riscv_pkg::reorder_buffer_alloc_resp_t o_alloc_resp,

    // =========================================================================
    // CDB Write Interface (from Functional Units via CDB)
    // =========================================================================
    // For non-branch results (ALU, MUL, DIV, MEM, FP)
    input riscv_pkg::reorder_buffer_cdb_write_t i_cdb_write,

    // Direct non-CDB completion for plain stores. Stores do not need wakeup or
    // a CDB value broadcast; the ROB only needs to know the entry is done.
    input logic                                        i_store_complete_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_store_complete_tag,

    // =========================================================================
    // Branch Update Interface (from Branch Unit)
    // =========================================================================
    // Separate from CDB - only for branch/jump resolution
    input riscv_pkg::reorder_buffer_branch_update_t i_branch_update,

    // =========================================================================
    // Checkpoint Interface (from/to RAT Checkpoint Unit)
    // =========================================================================
    // When a branch is allocated and needs a checkpoint
    input logic                                    i_checkpoint_valid,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_checkpoint_id,

    // =========================================================================
    // Commit Output (to Regfiles, SQ, Trap Unit)
    // =========================================================================
    output riscv_pkg::reorder_buffer_commit_t o_commit,
    output riscv_pkg::reorder_buffer_commit_t o_commit_comb,
    output logic                              o_commit_valid_raw,
    output logic                              o_commit_store_like_raw,
    output logic                              o_commit_misprediction_raw,
    output logic                              o_commit_correct_branch_raw,
    output logic                              o_head_commit_misprediction_candidate,

    // =========================================================================
    // Store Queue Coordination
    // =========================================================================
    input logic i_sq_empty,           // Store queue has no entries at all
    input logic i_sq_committed_empty, // No committed entries pending write (for FENCE)

    // =========================================================================
    // CSR Unit Coordination
    // =========================================================================
    // CSR reads execute speculatively; o_csr_start triggers side effects at commit
    output logic o_csr_start,  // Signal CSR unit to apply side effects at commit
    input  logic i_csr_done,   // CSR unit has completed

    // =========================================================================
    // Trap/Exception Handling
    // =========================================================================
    // Exception detected at head - signal trap unit
    output logic o_trap_pending,  // Exception needs handling
    output logic [riscv_pkg::XLEN-1:0] o_trap_pc,  // PC of excepting instruction
    output riscv_pkg::exc_cause_t o_trap_cause,  // Exception cause
    input logic i_trap_taken,  // Trap unit has taken the trap

    // MRET coordination
    output logic                       o_mret_start,  // Signal trap unit to handle MRET
    input  logic                       i_mret_done,   // MRET handling complete
    input  logic [riscv_pkg::XLEN-1:0] i_mepc,        // Return PC from trap unit

    // =========================================================================
    // Interrupt Interface (for WFI)
    // =========================================================================
    input logic i_interrupt_pending,  // Interrupt is pending (wake from WFI)

    // =========================================================================
    // Pipeline Flush Control
    // =========================================================================
    // Flush requests can come from:
    // 1. Branch misprediction (partial flush via i_flush_en)
    // 2. Exception (full flush via i_flush_all)
    // 3. FENCE.I (full flush after commit)
    input logic i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,  // Flush entries after this tag
    input logic i_flush_all,  // Flush entire Reorder Buffer (exception)
    input logic i_flush_after_head_commit,

    // FENCE.I triggers pipeline and icache flush after commit
    output logic o_fence_i_flush,  // FENCE.I committed, flush pipeline/icache

    // =========================================================================
    // Early Misprediction Recovery
    // =========================================================================
    // Qualifies the current partial flush as an execute-time early recovery
    input logic                                        i_early_recovery_flush,
    // Marks the entry as early-recovered so commit skips re-triggering flush
    input logic                                        i_early_recovery_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_early_recovery_tag,

    // =========================================================================
    // Status Outputs
    // =========================================================================
    output logic                                      o_full,
    output logic                                      o_empty,
    output logic [riscv_pkg::ReorderBufferTagWidth:0] o_count,  // Number of valid entries

    // Head entry information (for external commit coordination)
    output logic                        [riscv_pkg::ReorderBufferTagWidth-1:0] o_head_tag,
    output logic                                                               o_head_valid,
    output logic                                                               o_head_done,
    output logic                        [   riscv_pkg::ReorderBufferDepth-1:0] o_entry_valid,
    output logic                        [   riscv_pkg::ReorderBufferDepth-1:0] o_entry_done,
    output riscv_pkg::rob_perf_events_t                                        o_perf_events,

    // =========================================================================
    // Reorder Buffer Entry Read Interface (for RAT lookup of in-flight values)
    // =========================================================================
    // Allows RAT to check if a Reorder Buffer entry has completed (for bypass)
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_read_tag,
    output logic                                        o_read_done,
    output logic [                 riscv_pkg::FLEN-1:0] o_read_value,

    // =========================================================================
    // Dispatch Bypass Read Ports (async value read for renamed-but-done sources)
    // =========================================================================
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_1,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_1,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_2,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_2,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_bypass_tag_3,
    output logic [                 riscv_pkg::FLEN-1:0] o_bypass_value_3,

    // Buffered FMUL dispatch repair ports (wrapper-local async reads)
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_fmul_pending_bypass_tag_1,
    output logic [                 riscv_pkg::FLEN-1:0] o_fmul_pending_bypass_value_1,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_fmul_pending_bypass_tag_2,
    output logic [                 riscv_pkg::FLEN-1:0] o_fmul_pending_bypass_value_2,
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_fmul_pending_bypass_tag_3,
    output logic [                 riscv_pkg::FLEN-1:0] o_fmul_pending_bypass_value_3
);

  // ===========================================================================
  // Local Parameters (from package)
  // ===========================================================================
  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned ReorderBufferDepth = riscv_pkg::ReorderBufferDepth;
  localparam int unsigned CheckpointIdWidth = riscv_pkg::CheckpointIdWidth;
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned ExcCauseWidth = riscv_pkg::ExcCauseWidth;
  localparam int unsigned FpFlagsWidth = 5;  // $bits(riscv_pkg::fp_flags_t) — nv,dz,of,uf,nx
  localparam int unsigned RegAddrWidth = riscv_pkg::RegAddrWidth;
  localparam int unsigned RsTypeWidth = 3;
  localparam int unsigned HeadMetaWidth = 21 + RsTypeWidth;

  // ===========================================================================
  // Helper Functions
  // ===========================================================================

  // Check if entry_idx is younger than flush_tag (relative to head)
  function automatic logic should_flush_entry(input logic [ReorderBufferTagWidth-1:0] entry_idx,
                                              input logic [ReorderBufferTagWidth-1:0] flush_tag,
                                              input logic [ReorderBufferTagWidth-1:0] head);
    logic [ReorderBufferTagWidth:0] entry_age;
    logic [ReorderBufferTagWidth:0] flush_age;
    begin
      entry_age = {1'b0, entry_idx} - {1'b0, head};
      flush_age = {1'b0, flush_tag} - {1'b0, head};
      should_flush_entry = entry_age > flush_age;
    end
  endfunction

  // Forward declarations (used in debug assigns before main decl)
  logic [ReorderBufferTagWidth:0] head_ptr;
  logic [ReorderBufferTagWidth:0] tail_ptr;
  logic full;
  logic empty;

  // ===========================================================================
  // Debug Signals (for verification)
  // ===========================================================================
  logic [ReorderBufferTagWidth:0] dbg_tail_ptr  /* verilator public_flat_rd */;
  assign dbg_tail_ptr = tail_ptr;

  logic [ReorderBufferTagWidth:0] dbg_head_ptr  /* verilator public_flat_rd */;
  assign dbg_head_ptr = head_ptr;

  // ===========================================================================
  // Internal Signals
  // ===========================================================================

  // Reorder Buffer storage — 1-bit packed vectors remain in FFs for
  // per-entry flush/reset.  Multi-bit fields are in distributed RAM below.
  logic [ReorderBufferDepth-1:0] rob_valid;
  logic [ReorderBufferDepth-1:0] rob_done;
  logic [ReorderBufferDepth-1:0] rob_exception;
  logic [ReorderBufferDepth-1:0] rob_branch_taken;
  logic [ReorderBufferDepth-1:0] rob_mispredicted;
  logic [ReorderBufferDepth-1:0] rob_early_recovered;

  // Head and tail pointers (declared above for forward ref)

  // Derived pointer values (without wrap bit)
  logic [ReorderBufferTagWidth-1:0] head_idx;
  logic [ReorderBufferTagWidth-1:0] tail_idx;

  // Status signals (full and empty declared above for forward ref)
  logic [ReorderBufferTagWidth:0] count;

  // Head entry fields for commit — RAM-backed fields are driven by RAM
  // read ports directly; FF-backed fields are assigned from packed vectors.
  logic head_valid;
  logic head_done;
  logic head_exception;
  riscv_pkg::exc_cause_t head_exc_cause;  // from RAM
  logic [XLEN-1:0] head_pc;  // from RAM
  logic head_dest_rf;
  logic [RegAddrWidth-1:0] head_dest_reg;  // from RAM
  logic head_dest_valid;
  logic [FLEN-1:0] head_value;  // from RAM
  logic head_is_store;
  logic head_is_fp_store;
  logic head_is_branch;
  logic head_branch_taken;
  logic [XLEN-1:0] head_branch_target;
  logic [XLEN-1:0] head_branch_target_jal;  // JAL target written at allocation
  logic [XLEN-1:0] head_branch_target_resolved;  // branch/JALR target written at resolution
  logic head_predicted_taken;
  logic [XLEN-1:0] head_predicted_target;  // from RAM
  logic head_mispredicted;
  logic head_early_recovered;
  logic head_is_call;  // TODO: wire to BPU update at commit
  logic head_is_return;  // TODO: wire to BPU update at commit
  logic head_is_jal;
  logic head_is_jalr;
  logic head_has_checkpoint;
  logic [CheckpointIdWidth-1:0] head_checkpoint_id;  // from RAM
  riscv_pkg::fp_flags_t head_fp_flags;  // from RAM
  logic head_is_csr;
  logic head_is_fence;
  logic head_is_fence_i;
  logic head_is_wfi;
  logic head_is_mret;
  logic head_is_amo;
  logic head_is_lr;
  logic head_is_sc;
  logic head_is_compressed;
  logic head_has_fp_flags;
  riscv_pkg::rs_type_e head_rs_type;
  logic [RsTypeWidth-1:0] head_rs_type_bits;
  logic [HeadMetaWidth-1:0] head_meta_rd_data;
  // CSR fields (from RAM)
  logic [11:0] head_csr_addr;
  logic [2:0] head_csr_op;
  logic [XLEN-1:0] head_csr_write_data;
  logic [XLEN-1:0] head_fallthrough_pc;

  // Commit control signals
  logic head_ready;  // Head is valid and done
  logic commit_stall;  // Stall commit for serializing instructions
  logic commit_en;  // Actually commit this cycle

  // Serializing instruction state machine
  typedef enum logic [2:0] {
    SERIAL_IDLE,       // No serializing instruction at head
    SERIAL_WAIT_SQ,    // Waiting for SQ to drain (FENCE/AMO)
    SERIAL_CSR_EXEC,   // CSR executing
    SERIAL_MRET_EXEC,  // MRET executing
    SERIAL_WFI_WAIT,   // WFI waiting for interrupt
    SERIAL_TRAP_WAIT   // Exception waiting for trap unit
  } serial_state_e;

  serial_state_e serial_state, serial_state_next;

  // Misprediction detection at commit
  logic commit_misprediction;

  // FENCE.I commit tracking
  logic fence_i_committed;

  // ===========================================================================
  // Pointer Logic
  // ===========================================================================

  assign head_idx = head_ptr[ReorderBufferTagWidth-1:0];
  assign tail_idx = tail_ptr[ReorderBufferTagWidth-1:0];

  // Full when pointers are equal except for MSB (wrap bit differs)
  assign full = (head_ptr[ReorderBufferTagWidth] != tail_ptr[ReorderBufferTagWidth]) &&
                (head_idx == tail_idx);

  // Empty when pointers are exactly equal (including wrap bit)
  assign empty = (head_ptr == tail_ptr);

  // Count of valid entries
  assign count = tail_ptr - head_ptr;

  // Head entry fields from FF-backed packed vectors / distributed RAM
  assign head_valid = rob_valid[head_idx];
  assign head_done = rob_done[head_idx];
  assign head_exception = rob_exception[head_idx];
  assign head_branch_taken = rob_branch_taken[head_idx];
  assign head_mispredicted = rob_mispredicted[head_idx];
  assign head_early_recovered = rob_early_recovered[head_idx];
  assign {
    head_dest_rf,
    head_dest_valid,
    head_is_store,
    head_is_fp_store,
    head_is_branch,
    head_predicted_taken,
    head_is_call,
    head_is_return,
    head_is_jal,
    head_is_jalr,
    head_has_checkpoint,
    head_is_csr,
    head_is_fence,
    head_is_fence_i,
    head_is_wfi,
    head_is_mret,
    head_is_amo,
    head_is_lr,
    head_is_sc,
    head_is_compressed,
    head_has_fp_flags,
    head_rs_type_bits
  } = head_meta_rd_data;
  assign head_rs_type = riscv_pkg::rs_type_e'(head_rs_type_bits);
  assign head_branch_target = head_is_jal ? head_branch_target_jal : head_branch_target_resolved;
  logic head_link_is_compressed;
  assign head_link_is_compressed = (head_value[XLEN-1:0] == (head_pc + 32'd2));
  assign head_fallthrough_pc = head_pc + (head_is_compressed ? 32'd2 : 32'd4);

  // Head is ready to potentially commit
  assign head_ready = head_valid && head_done;

  // ===========================================================================
  // Distributed RAM Write Enables and Data
  // ===========================================================================

  logic alloc_en;
  assign alloc_en = i_alloc_req.alloc_valid && !full && !i_flush_all && !i_flush_en;

  logic cdb_ram_wr_en;
  logic cdb_state_wr_en;
  assign cdb_ram_wr_en   = i_cdb_write.valid && !i_flush_all;
  assign cdb_state_wr_en = cdb_ram_wr_en && rob_valid[i_cdb_write.tag];

  logic branch_wr_en;
  assign branch_wr_en = i_branch_update.valid && !i_flush_all && rob_valid[i_branch_update.tag];

  // Allocation data precomputation for fields with instruction-type-dependent values
  logic [FLEN-1:0] alloc_value_data;
  always_comb begin
    // Save the sequential fall-through/link address for all branches and jumps.
    // Commit-time redirect can then use the exact saved address instead of
    // recomputing from compressed-length metadata.
    if (i_alloc_req.is_branch) alloc_value_data = {{(FLEN - XLEN) {1'b0}}, i_alloc_req.link_addr};
    else alloc_value_data = '0;
  end

  logic [XLEN-1:0] alloc_branch_target_data;
  assign alloc_branch_target_data = i_alloc_req.is_jal ? i_alloc_req.branch_target : '0;

  logic [CheckpointIdWidth-1:0] alloc_checkpoint_id_data;
  assign alloc_checkpoint_id_data = (i_checkpoint_valid && i_alloc_req.is_branch) ?
                                     i_checkpoint_id : '0;
  logic alloc_has_checkpoint_data;
  assign alloc_has_checkpoint_data = i_checkpoint_valid && i_alloc_req.is_branch;

  logic [HeadMetaWidth-1:0] alloc_head_meta_data;
  assign alloc_head_meta_data = {
    i_alloc_req.dest_rf,
    i_alloc_req.dest_valid,
    i_alloc_req.is_store,
    i_alloc_req.is_fp_store,
    i_alloc_req.is_branch,
    i_alloc_req.predicted_taken,
    i_alloc_req.is_call,
    i_alloc_req.is_return,
    i_alloc_req.is_jal,
    i_alloc_req.is_jalr,
    alloc_has_checkpoint_data,
    i_alloc_req.is_csr,
    i_alloc_req.is_fence,
    i_alloc_req.is_fence_i,
    i_alloc_req.is_wfi,
    i_alloc_req.is_mret,
    i_alloc_req.is_amo,
    i_alloc_req.is_lr,
    i_alloc_req.is_sc,
    i_alloc_req.is_compressed,
    i_alloc_req.has_fp_flags,
    RsTypeWidth'(i_alloc_req.rs_type)
  };

  // ===========================================================================
  // Distributed RAM Instances
  // ===========================================================================
  // Single-write-port fields (written only at allocation, read at head).
  // These use sdp_dist_ram — one write port, one async read port.
  // ---------------------------------------------------------------------------

  sdp_dist_ram #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(XLEN)
  ) u_rob_pc (
      .i_clk,
      .i_write_enable (alloc_en),
      .i_write_address(tail_idx),
      .i_write_data   (i_alloc_req.pc),
      .i_read_address (head_idx),
      .o_read_data    (head_pc)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(RegAddrWidth)
  ) u_rob_dest_reg (
      .i_clk,
      .i_write_enable (alloc_en),
      .i_write_address(tail_idx),
      .i_write_data   (i_alloc_req.dest_reg),
      .i_read_address (head_idx),
      .o_read_data    (head_dest_reg)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(XLEN)
  ) u_rob_predicted_target (
      .i_clk,
      .i_write_enable (alloc_en),
      .i_write_address(tail_idx),
      .i_write_data   (i_alloc_req.predicted_target),
      .i_read_address (head_idx),
      .o_read_data    (head_predicted_target)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(CheckpointIdWidth)
  ) u_rob_checkpoint_id (
      .i_clk,
      .i_write_enable (alloc_en),
      .i_write_address(tail_idx),
      .i_write_data   (alloc_checkpoint_id_data),
      .i_read_address (head_idx),
      .o_read_data    (head_checkpoint_id)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(HeadMetaWidth)
  ) u_rob_head_meta (
      .i_clk,
      .i_write_enable (alloc_en),
      .i_write_address(tail_idx),
      .i_write_data   (alloc_head_meta_data),
      .i_read_address (head_idx),
      .o_read_data    (head_meta_rd_data)
  );

  // ---------------------------------------------------------------------------
  // Multi-write-port fields (allocation + CDB or branch update).
  // These use mwp_dist_ram with 2 write ports.
  // Port 0 = allocation (lower priority), Port 1 = CDB/branch (higher priority).
  // ---------------------------------------------------------------------------

  // rob_value: 2 write ports (alloc + CDB), 2 read ports (head + RAT bypass).
  // Two instances with identical writes, different read addresses.
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_value_head (
      .i_clk,
      .i_write_enable ({cdb_ram_wr_en, alloc_en}),
      .i_write_address({i_cdb_write.tag, tail_idx}),
      .i_write_data   ({i_cdb_write.value, alloc_value_data}),
      .i_read_address (head_idx),
      .o_read_data    (head_value)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_value_rat (
      .i_clk,
      .i_write_enable ({cdb_ram_wr_en, alloc_en}),
      .i_write_address({i_cdb_write.tag, tail_idx}),
      .i_write_data   ({i_cdb_write.value, alloc_value_data}),
      .i_read_address (i_read_tag),
      .o_read_data    (o_read_value)
  );

  // Dispatch bypass value read ports (same write data as above, different read addresses)
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_value_bypass_1 (
      .i_clk,
      .i_write_enable ({cdb_ram_wr_en, alloc_en}),
      .i_write_address({i_cdb_write.tag, tail_idx}),
      .i_write_data   ({i_cdb_write.value, alloc_value_data}),
      .i_read_address (i_bypass_tag_1),
      .o_read_data    (o_bypass_value_1)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_value_bypass_2 (
      .i_clk,
      .i_write_enable ({cdb_ram_wr_en, alloc_en}),
      .i_write_address({i_cdb_write.tag, tail_idx}),
      .i_write_data   ({i_cdb_write.value, alloc_value_data}),
      .i_read_address (i_bypass_tag_2),
      .o_read_data    (o_bypass_value_2)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_value_bypass_3 (
      .i_clk,
      .i_write_enable ({cdb_ram_wr_en, alloc_en}),
      .i_write_address({i_cdb_write.tag, tail_idx}),
      .i_write_data   ({i_cdb_write.value, alloc_value_data}),
      .i_read_address (i_bypass_tag_3),
      .o_read_data    (o_bypass_value_3)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_value_fmul_pending_1 (
      .i_clk,
      .i_write_enable ({cdb_ram_wr_en, alloc_en}),
      .i_write_address({i_cdb_write.tag, tail_idx}),
      .i_write_data   ({i_cdb_write.value, alloc_value_data}),
      .i_read_address (i_fmul_pending_bypass_tag_1),
      .o_read_data    (o_fmul_pending_bypass_value_1)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_value_fmul_pending_2 (
      .i_clk,
      .i_write_enable ({cdb_ram_wr_en, alloc_en}),
      .i_write_address({i_cdb_write.tag, tail_idx}),
      .i_write_data   ({i_cdb_write.value, alloc_value_data}),
      .i_read_address (i_fmul_pending_bypass_tag_2),
      .o_read_data    (o_fmul_pending_bypass_value_2)
  );

  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_value_fmul_pending_3 (
      .i_clk,
      .i_write_enable ({cdb_ram_wr_en, alloc_en}),
      .i_write_address({i_cdb_write.tag, tail_idx}),
      .i_write_data   ({i_cdb_write.value, alloc_value_data}),
      .i_read_address (i_fmul_pending_bypass_tag_3),
      .o_read_data    (o_fmul_pending_bypass_value_3)
  );

  // rob_exc_cause: 2 write ports (alloc='0 + CDB), 1 read port (head)
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (ExcCauseWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_exc_cause (
      .i_clk,
      .i_write_enable ({cdb_ram_wr_en, alloc_en}),
      .i_write_address({i_cdb_write.tag, tail_idx}),
      .i_write_data   ({i_cdb_write.exc_cause, ExcCauseWidth'(0)}),
      .i_read_address (head_idx),
      .o_read_data    (head_exc_cause)
  );

  // rob_fp_flags: 2 write ports (alloc='0 + CDB), 1 read port (head)
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (FpFlagsWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_fp_flags (
      .i_clk,
      .i_write_enable ({cdb_ram_wr_en, alloc_en}),
      .i_write_address({i_cdb_write.tag, tail_idx}),
      .i_write_data   ({i_cdb_write.fp_flags, FpFlagsWidth'(0)}),
      .i_read_address (head_idx),
      .o_read_data    (head_fp_flags)
  );

  // Branch target storage only needs one writer per producer class:
  // JAL writes its architectural target at allocation, while conditional
  // branches/JALR write their resolved target on branch update. Split the
  // field across two single-write memories and select at the head instead of
  // paying the timing cost of a 2-write-port LVT RAM here.
  sdp_dist_ram #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(XLEN)
  ) u_rob_branch_target_jal (
      .i_clk,
      .i_write_enable (alloc_en && i_alloc_req.is_jal),
      .i_write_address(tail_idx),
      .i_write_data   (alloc_branch_target_data),
      .i_read_address (head_idx),
      .o_read_data    (head_branch_target_jal)
  );

  sdp_dist_ram #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(XLEN)
  ) u_rob_branch_target_resolved (
      .i_clk,
      .i_write_enable (branch_wr_en),
      .i_write_address(i_branch_update.tag),
      .i_write_data   (i_branch_update.target),
      .i_read_address (head_idx),
      .o_read_data    (head_branch_target_resolved)
  );

  // CSR address RAM (12-bit, written at allocation)
  sdp_dist_ram #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(12)
  ) u_rob_csr_addr (
      .i_clk,
      .i_write_enable (alloc_en),
      .i_write_address(tail_idx),
      .i_write_data   (i_alloc_req.csr_addr),
      .i_read_address (head_idx),
      .o_read_data    (head_csr_addr)
  );

  // CSR op RAM (3-bit funct3, written at allocation)
  sdp_dist_ram #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(3)
  ) u_rob_csr_op (
      .i_clk,
      .i_write_enable (alloc_en),
      .i_write_address(tail_idx),
      .i_write_data   (i_alloc_req.csr_op),
      .i_read_address (head_idx),
      .o_read_data    (head_csr_op)
  );

  // CSR write data RAM (32-bit, written at allocation)
  sdp_dist_ram #(
      .ADDR_WIDTH(ReorderBufferTagWidth),
      .DATA_WIDTH(XLEN)
  ) u_rob_csr_write_data (
      .i_clk,
      .i_write_enable (alloc_en),
      .i_write_address(tail_idx),
      .i_write_data   (i_alloc_req.csr_write_data),
      .i_read_address (head_idx),
      .o_read_data    (head_csr_write_data)
  );

  // ===========================================================================
  // Allocation Logic
  // ===========================================================================

  // Allocation response
  assign o_alloc_resp.alloc_ready = !full && !i_flush_all && !i_flush_en;
  assign o_alloc_resp.alloc_tag = tail_idx;
  assign o_alloc_resp.full = full;

  // Flush age calculation for generic partial flush (computed combinationally).
  logic [ReorderBufferTagWidth-1:0] flush_age;
  assign flush_age = i_flush_tag - head_idx;

  logic flush_after_head_commit;
  assign flush_after_head_commit = i_flush_after_head_commit;

  // Allocation write - tail pointer management
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      tail_ptr <= '0;
    end else if (i_flush_all) begin
      // Full flush: reset tail to head
      tail_ptr <= head_ptr;
    end else if (i_flush_en) begin
      if (flush_after_head_commit) begin
        // Delayed recovery: the mispredicted head already retired last cycle,
        // so every remaining live entry is younger and the ROB becomes empty.
        tail_ptr <= head_ptr;
      end else begin
        // Generic partial flush: set tail to flush_tag + 1
        // Use age-based arithmetic to handle wrap correctly (extend 5-bit age to 6-bit)
        tail_ptr <= head_ptr + {1'b0, flush_age} + 1'b1;
      end
    end else if (alloc_en) begin
      // Normal allocation: advance tail
      tail_ptr <= tail_ptr + 1'b1;
    end
  end

  // ===========================================================================
  // Reorder Buffer FF Storage (1-bit packed vectors)
  // ===========================================================================

  // Handle allocation, CDB writes, branch updates, and flush for FF-backed fields.
  // Multi-bit fields (pc, dest_reg, value, branch_target, predicted_target,
  // checkpoint_id, exc_cause, fp_flags, head-only metadata) are handled by
  // distributed RAM above.
  // -------------------------------------------------------------------------
  // Control signals (rob_valid, rob_done, rob_exception) -- need reset
  // -------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      rob_done      <= '0;
      rob_exception <= '0;
    end else begin
      // ---------------------------------------------------------------------
      // Allocation Write (control fields only)
      // ---------------------------------------------------------------------
      if (alloc_en) begin
        // Initialize control fields for new entry
        rob_exception[tail_idx] <= 1'b0;

        // JAL has fully known link/target information at allocation time.
        // JALR and conditional branches still wait for branch resolution.
        if (i_alloc_req.is_jal) begin
          rob_done[tail_idx] <= 1'b1;
        end else if (i_alloc_req.is_jalr) begin
          // JALR: target unknown until execute, but link addr is known
          rob_done[tail_idx] <= 1'b0;
        end else if (i_alloc_req.is_wfi || i_alloc_req.is_fence ||
                     i_alloc_req.is_fence_i || i_alloc_req.is_mret) begin
          // These instructions are "done" from execution perspective at dispatch
          // but commit is gated by serialization logic.
          rob_done[tail_idx] <= 1'b1;
        end else begin
          rob_done[tail_idx] <= 1'b0;
        end
      end

      // ---------------------------------------------------------------------
      // CDB Write (mark entry done with result)
      // ---------------------------------------------------------------------
      // For non-branch instructions (ALU, MUL, DIV, MEM, FP)
      // Value, exc_cause, fp_flags are written via distributed RAM.
      if (cdb_state_wr_en) begin
        rob_done[i_cdb_write.tag]      <= 1'b1;
        rob_exception[i_cdb_write.tag] <= i_cdb_write.exception;
      end

      // ---------------------------------------------------------------------
      // Direct store completion (mark plain store entry done)
      // ---------------------------------------------------------------------
      if (i_store_complete_valid && !i_flush_all && rob_valid[i_store_complete_tag]) begin
        rob_done[i_store_complete_tag] <= 1'b1;
      end

      // ---------------------------------------------------------------------
      // Branch Update (mark branch done)
      // ---------------------------------------------------------------------
      if (branch_wr_en) begin
        rob_done[i_branch_update.tag] <= 1'b1;
      end
    end
  end

  // Keep rob_valid separate so full-flush does not share a single next-state
  // cone with unrelated ROB done/exception updates.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      rob_valid <= '0;
    end else begin
      if (i_flush_all) begin
        // Full flush: invalidate all entries
        rob_valid <= '0;
      end else if (i_flush_en) begin
        if (flush_after_head_commit) begin
          // Head-driven recovery leaves no architecturally-live entries in the
          // ROB after the branch boundary.
          rob_valid <= '0;
        end else begin
          // Partial flush: invalidate entries after flush_tag
          for (int i = 0; i < ReorderBufferDepth; i++) begin
            if (rob_valid[i] && should_flush_entry(
                    i[ReorderBufferTagWidth-1:0], i_flush_tag, head_idx
                )) begin
              rob_valid[i] <= 1'b0;
            end
          end
        end
      end

      if (alloc_en) begin
        rob_valid[tail_idx] <= 1'b1;
      end

      // Commit deallocation: invalidate the committed entry (head pointer
      // advances separately).
      if (commit_en && !i_flush_all) begin
        rob_valid[head_idx] <= 1'b0;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Data signals -- no reset needed, gated by alloc_en / branch_wr_en
  // -------------------------------------------------------------------------
  always_ff @(posedge i_clk) begin
    // -------------------------------------------------------------------
    // Allocation Write (multi-write/head-independent data fields)
    // -------------------------------------------------------------------
    if (alloc_en) begin
      rob_branch_taken[tail_idx]    <= 1'b0;
      rob_mispredicted[tail_idx]    <= 1'b0;
      rob_early_recovered[tail_idx] <= 1'b0;

      // JAL has fully known link/target information at allocation time.
      if (i_alloc_req.is_jal) begin
        // For JAL, branch is always taken with known target
        rob_branch_taken[tail_idx] <= 1'b1;
        rob_mispredicted[tail_idx] <= !i_alloc_req.predicted_taken ||
                                      (i_alloc_req.predicted_target != i_alloc_req.branch_target);
      end
    end

    // -------------------------------------------------------------------
    // Branch Update (record branch resolution data)
    // -------------------------------------------------------------------
    // For branch/jump instructions only.
    // The mispredicted field from branch unit is authoritative - it knows about
    // RAS/indirect predictor specifics that the ROB doesn't track.
    // branch_target is written via distributed RAM.
    if (branch_wr_en) begin
      rob_branch_taken[i_branch_update.tag] <= i_branch_update.taken;
      rob_mispredicted[i_branch_update.tag] <= i_branch_update.mispredicted;
    end

    // Mark entry as early-recovered (suppresses commit-time re-trigger)
    if (i_early_recovery_en) rob_early_recovered[i_early_recovery_tag] <= 1'b1;
  end

  // ===========================================================================
  // Head Pointer Management
  // ===========================================================================

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      head_ptr <= '0;
    end else if (i_flush_all) begin
      // Full flush: head stays (tail resets to head)
    end else if (commit_en) begin
      // Normal commit: advance head
      head_ptr <= head_ptr + 1'b1;
    end
  end

  // ===========================================================================
  // Serializing Instruction State Machine
  // ===========================================================================
  // Handles WFI, CSR, FENCE, FENCE.I, MRET, and exceptions at Reorder Buffer head

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      serial_state <= SERIAL_IDLE;
    end else if (i_flush_all) begin
      serial_state <= SERIAL_IDLE;
    end else begin
      serial_state <= serial_state_next;
    end
  end

  always_comb begin
    serial_state_next = serial_state;
    commit_stall = 1'b0;

    case (serial_state)
      SERIAL_IDLE: begin
        if (head_ready && !i_early_recovery_en && !i_flush_en && !i_flush_all) begin
          // Check for serializing instructions at head
          if (head_exception) begin
            // Exception: wait for trap unit
            serial_state_next = SERIAL_TRAP_WAIT;
            commit_stall = 1'b1;
          end else if (head_is_wfi) begin
            // WFI: wait for interrupt
            if (i_interrupt_pending) begin
              // Interrupt pending, WFI can commit immediately
              serial_state_next = SERIAL_IDLE;
              commit_stall = 1'b0;
            end else begin
              serial_state_next = SERIAL_WFI_WAIT;
              commit_stall = 1'b1;
            end
          end else if (head_is_csr) begin
            // CSR: need to execute at commit
            serial_state_next = SERIAL_CSR_EXEC;
            commit_stall = 1'b1;
          end else if (head_is_fence || head_is_fence_i) begin
            // FENCE/FENCE.I: wait for committed SQ entries to drain
            if (i_sq_committed_empty) begin
              // No committed entries pending write, can commit
              serial_state_next = SERIAL_IDLE;
              commit_stall = 1'b0;
            end else begin
              serial_state_next = SERIAL_WAIT_SQ;
              commit_stall = 1'b1;
            end
          end else if (head_is_mret) begin
            // MRET: signal trap unit
            serial_state_next = SERIAL_MRET_EXEC;
            commit_stall = 1'b1;
          end else if (head_is_amo || head_is_lr) begin
            // AMO/LR: ordering enforced at LQ issue time (waits for ROB head +
            // SQ committed-empty). Once CDB arrives (head_done=1), commit normally.
            // No SQ check here (would deadlock with younger uncommitted SQ entries).
          end
          // Non-serializing instructions: no stall
        end
      end

      SERIAL_WAIT_SQ: begin
        commit_stall = 1'b1;
        if (i_sq_committed_empty) begin
          // Committed SQ entries drained, can commit
          serial_state_next = SERIAL_IDLE;
          commit_stall = 1'b0;
        end
      end

      SERIAL_CSR_EXEC: begin
        commit_stall = 1'b1;
        if (i_csr_done) begin
          // CSR complete, can commit
          serial_state_next = SERIAL_IDLE;
          commit_stall = 1'b0;
        end
      end

      SERIAL_MRET_EXEC: begin
        commit_stall = 1'b1;
        if (i_mret_done) begin
          // MRET complete, can commit
          serial_state_next = SERIAL_IDLE;
          commit_stall = 1'b0;
        end
      end

      SERIAL_WFI_WAIT: begin
        commit_stall = 1'b1;
        if (i_interrupt_pending) begin
          // Interrupt arrived, WFI can commit
          serial_state_next = SERIAL_IDLE;
          commit_stall = 1'b0;
        end
      end

      SERIAL_TRAP_WAIT: begin
        commit_stall = 1'b1;
        if (i_trap_taken) begin
          // Trap unit has taken the exception, flush will follow
          serial_state_next = SERIAL_IDLE;
          // Note: i_flush_all will reset state machine
        end
      end

      default: begin
        serial_state_next = SERIAL_IDLE;
      end
    endcase
  end

  // ===========================================================================
  // Commit Enable Logic
  // ===========================================================================

  // Commit when head is ready, no stall, and no flush in progress.
  // The old branch_update collision guard (which delayed commit when a
  // mispredicted branch resolved via CDB in the same cycle as commit) is
  // removed: (a) JAL — the stated motivation — never produces branch_update
  // (is_jal_issue is excluded); (b) for conditional branches, the
  // rob_head_commit_misprediction_candidate check in early_mispredict_fire
  // already blocks the early-recovery race; (c) removing the guard breaks
  // the commit_en ↔ branch_update critical path (19 LUT levels through the
  // CARRY8 branch-target comparison).
  assign commit_en = head_ready && !commit_stall && !i_early_recovery_en && !i_flush_all &&
                     !flush_after_head_commit;

  // Raw misprediction at commit (early_recovered handled externally by cpu_ooo)
  assign commit_misprediction = head_is_branch && head_mispredicted;
  assign o_commit_valid_raw = commit_en;
  assign o_commit_store_like_raw = commit_en && (head_is_store || head_is_fp_store || head_is_sc);
  assign o_commit_misprediction_raw = commit_en && commit_misprediction && !head_early_recovered;
  assign o_commit_correct_branch_raw = commit_en && head_has_checkpoint &&
                                       !commit_misprediction && !head_early_recovered;
  // Same-cycle head-mispredict indicator without the branch_update collision
  // term. Outer control logic uses this to suppress younger branch resolution
  // without feeding branch_update back into commit_en.
  assign o_head_commit_misprediction_candidate =
      head_ready && !commit_stall && !i_early_recovery_en &&
      !i_flush_all && !flush_after_head_commit &&
      commit_misprediction && !head_early_recovered;

  // ===========================================================================
  // External Coordination Outputs
  // ===========================================================================

  // CSR execution signal - asserted when entering CSR_EXEC state
  assign o_csr_start = (serial_state == SERIAL_IDLE) && head_ready &&
                       !i_early_recovery_en &&
                       head_is_csr && !head_exception &&
                       !i_flush_en && !i_flush_all;

  // MRET execution signal - asserted when entering MRET_EXEC state.
  // Note: !i_flush_en/!i_flush_all intentionally omitted — flush signals are
  // derived from mret_taken which is derived from o_mret_start, so gating
  // by them creates an oscillating combinational loop.
  assign o_mret_start = (serial_state == SERIAL_IDLE) && head_ready &&
                        !i_early_recovery_en &&
                        head_is_mret && !head_exception;

  // Trap pending signal - asserted when exception at head.
  // Note: during the IDLE->TRAP_WAIT transition, both the state check and the
  // combinational path assert o_trap_pending simultaneously. This overlap is
  // intentional and benign (result is still 1'b1); the state check sustains
  // the signal while the combinational term covers the initial detection cycle.
  // Note: !i_flush_all intentionally omitted from the combinational term.
  // flush_all is derived from trap_taken which is derived from o_trap_pending;
  // gating by !i_flush_all creates an oscillating combinational loop.
  // The registered term (serial_state == SERIAL_TRAP_WAIT) sustains the signal
  // across clock edges; the combinational term provides same-cycle detection.
  assign o_trap_pending =
      (serial_state == SERIAL_TRAP_WAIT) ||
      (head_ready && !i_early_recovery_en && head_exception);
  assign o_trap_pc = head_pc;
  assign o_trap_cause = head_exc_cause;

  // FENCE.I flush signal - pulse when FENCE.I commits
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      fence_i_committed <= 1'b0;
    end else begin
      fence_i_committed <= commit_en && head_is_fence_i;
    end
  end
  assign o_fence_i_flush = fence_i_committed;

  // ===========================================================================
  // Commit Output
  // ===========================================================================

  always_comb begin
    o_commit_comb = '0;

    if (commit_en) begin
      o_commit_comb.valid = 1'b1;
      o_commit_comb.tag = head_idx;
      o_commit_comb.dest_rf = head_dest_rf;
      o_commit_comb.dest_reg = head_dest_reg;
      o_commit_comb.dest_valid = head_dest_valid;
      o_commit_comb.value = head_value;
      o_commit_comb.is_store = head_is_store;
      o_commit_comb.is_fp_store = head_is_fp_store;
      o_commit_comb.exception = head_exception;
      o_commit_comb.pc = head_pc;
      o_commit_comb.exc_cause = head_exc_cause;
      o_commit_comb.fp_flags = head_fp_flags;
      o_commit_comb.has_fp_flags = head_has_fp_flags;

      // Branch misprediction recovery
      o_commit_comb.misprediction = commit_misprediction;
      o_commit_comb.early_recovered = head_early_recovered;
      o_commit_comb.has_checkpoint = head_has_checkpoint;
      o_commit_comb.checkpoint_id = head_checkpoint_id;
      // Redirect PC:
      // - MRET: redirect to mepc
      // - Taken branch/jump: redirect to resolved target
      // - Not-taken branch: redirect to architectural fall-through
      if (head_is_mret) begin
        // i_mepc is guaranteed stable here: the MRET handshake
        // (o_mret_start/i_mret_done) completes before commit_en asserts,
        // so the trap unit has finished updating mepc by this point.
        o_commit_comb.redirect_pc = i_mepc;
      end else if (head_is_branch) begin
        if (head_branch_taken) begin
          o_commit_comb.redirect_pc = head_branch_target;
        end else begin
          o_commit_comb.redirect_pc = head_fallthrough_pc;
        end
      end

      // Branch info (for BTB update and RAS restore at commit)
      o_commit_comb.predicted_taken = head_predicted_taken;
      o_commit_comb.branch_taken    = head_branch_taken;
      o_commit_comb.branch_target   = head_branch_target;
      o_commit_comb.is_branch       = head_is_branch;
      o_commit_comb.is_call         = head_is_call;
      o_commit_comb.is_return       = head_is_return;
      o_commit_comb.is_jal          = head_is_jal;
      o_commit_comb.is_jalr         = head_is_jalr;

      // CSR info (for commit-time serialized CSR execution)
      o_commit_comb.csr_addr        = head_csr_addr;
      o_commit_comb.csr_op          = head_csr_op;
      o_commit_comb.csr_write_data  = head_csr_write_data;

      // Serializing instruction flags (for external units)
      o_commit_comb.is_csr          = head_is_csr;
      o_commit_comb.is_fence        = head_is_fence;
      o_commit_comb.is_fence_i      = head_is_fence_i;
      o_commit_comb.is_wfi          = head_is_wfi;
      o_commit_comb.is_mret         = head_is_mret;
      o_commit_comb.is_amo          = head_is_amo;
      o_commit_comb.is_lr           = head_is_lr;
      o_commit_comb.is_sc           = head_is_sc;
      o_commit_comb.is_compressed   = head_is_branch ? head_link_is_compressed : head_is_compressed;
    end
  end

  // Keep commit visible for a full cycle after the retiring edge so external
  // observers can sample it after the head pointer advances.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) o_commit <= '0;
    else o_commit <= o_commit_comb;
  end

  // ===========================================================================
  // Status Outputs
  // ===========================================================================

  assign o_full = full;
  assign o_empty = empty;
  assign o_count = count;

  // Head entry information for external coordination
  assign o_head_tag = head_idx;
  assign o_head_valid = head_valid;
  assign o_head_done = head_valid && head_done;
  assign o_entry_valid = rob_valid;
  assign o_entry_done = rob_done;

  always_comb begin
    o_perf_events = '0;

    o_perf_events.rob_empty = empty;

    if (head_valid && !head_done && !i_flush_all) begin
      o_perf_events.head_wait_total = 1'b1;

      if (head_is_branch) begin
        o_perf_events.head_wait_branch = 1'b1;
      end else if (head_is_amo || head_is_lr) begin
        o_perf_events.head_wait_mem_amo = 1'b1;
      end else if (head_is_store || head_is_fp_store || head_is_sc) begin
        o_perf_events.head_wait_mem_store = 1'b1;
      end else begin
        unique case (head_rs_type)
          riscv_pkg::RS_INT: o_perf_events.head_wait_int = 1'b1;
          riscv_pkg::RS_MUL: o_perf_events.head_wait_mul = 1'b1;
          riscv_pkg::RS_MEM: o_perf_events.head_wait_mem_load = 1'b1;
          riscv_pkg::RS_FP: o_perf_events.head_wait_fp = 1'b1;
          riscv_pkg::RS_FMUL: o_perf_events.head_wait_fmul = 1'b1;
          riscv_pkg::RS_FDIV: o_perf_events.head_wait_fdiv = 1'b1;
          default: ;
        endcase
      end
    end

    if (head_ready && commit_stall && !i_flush_all) begin
      o_perf_events.commit_blocked_csr = head_is_csr || (serial_state == SERIAL_CSR_EXEC);
      o_perf_events.commit_blocked_fence =
          head_is_fence || head_is_fence_i || (serial_state == SERIAL_WAIT_SQ);
      o_perf_events.commit_blocked_wfi = head_is_wfi || (serial_state == SERIAL_WFI_WAIT);
      o_perf_events.commit_blocked_mret = head_is_mret || (serial_state == SERIAL_MRET_EXEC);
      o_perf_events.commit_blocked_trap = head_exception || (serial_state == SERIAL_TRAP_WAIT);
    end
  end

  // ===========================================================================
  // Reorder Buffer Entry Read Interface (for RAT bypass)
  // ===========================================================================

  assign o_read_done = rob_valid[i_read_tag] && rob_done[i_read_tag];
  // o_read_value is driven by u_rob_value_rat distributed RAM instance

  // ===========================================================================
  // Assertions (Simulation Only)
  // ===========================================================================

`ifndef SYNTHESIS
`ifndef FORMAL

  // Retire trace: log every committed instruction (for debugging)
  integer retire_trace_fd;
  initial begin
    retire_trace_fd = $fopen("retire_trace.log", "w");
  end
  always @(posedge i_clk) begin
    if (i_rst_n && commit_en) begin
      if (head_dest_valid && !head_dest_rf && head_dest_reg != 5'd0)
        $fwrite(
            retire_trace_fd,
            "%0t pc=%08x rd=x%0d val=%08x\n",
            $time,
            head_pc,
            head_dest_reg,
            head_value[31:0]
        );
      else $fwrite(retire_trace_fd, "%0t pc=%08x\n", $time, head_pc);
    end
  end

  // Check that we don't allocate when full
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_req.alloc_valid && full) begin
      $error("Reorder Buffer: Allocation attempted when full!");
    end
  end

  // Check that dispatch doesn't allocate during flush (invariant: dispatch must be stalled)
  // Note: alloc_ready also deasserts during flush, but dispatch should be independently stalled
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_req.alloc_valid && (i_flush_en || i_flush_all)) begin
      $error("Reorder Buffer: Allocation attempted during flush!");
    end
  end

  // Check that CDB writes target valid entries (unless a flush just happened).
  // The CDB is pipelined (registered in tomasulo_wrapper), so the CDB may
  // present results for entries that were flushed between capture and delivery.
  // This is harmless: cdb_state_wr_en gates all FF/RAM writes on rob_valid.
  logic dbg_flush_prev_cycle;
  always @(posedge i_clk) begin
    if (!i_rst_n) dbg_flush_prev_cycle <= 1'b0;
    else dbg_flush_prev_cycle <= i_flush_all || i_flush_en || dbg_flush_prev_cycle;
  end
  // With age-based partial flush, stale CDB results from younger-flushed
  // instructions can arrive 2+ cycles after flush. The actual write is
  // gated by rob_valid, so this is functionally harmless.
  always @(posedge i_clk) begin
    if (i_rst_n && i_cdb_write.valid && !rob_valid[i_cdb_write.tag] &&
        !dbg_flush_prev_cycle && !i_flush_all && !i_flush_en) begin
      $warning("Reorder Buffer: CDB write to invalid entry tag=%0d (ignored)", i_cdb_write.tag);
    end
  end

  // Check that branch updates target valid entries
  always @(posedge i_clk) begin
    if (i_rst_n && i_branch_update.valid && !rob_valid[i_branch_update.tag] &&
        !dbg_flush_prev_cycle && !i_flush_all && !i_flush_en) begin
      $warning("Reorder Buffer: Branch update to invalid entry tag=%0d (ignored)",
               i_branch_update.tag);
    end
  end

  // Check serialization state transitions are valid
  always @(posedge i_clk) begin
    if (i_rst_n && serial_state != SERIAL_IDLE && !head_ready) begin
      $warning("Reorder Buffer: Serialization state %0d but head not ready", serial_state);
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

  // Force reset to deassert after the initial cycle and stay deasserted.
  // Without this, the solver can hold i_rst_n low forever, making all
  // i_rst_n-gated asserts vacuously true.
  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // -------------------------------------------------------------------------
  // Structural constraints (assumes)
  // -------------------------------------------------------------------------
  // These are interface contracts — the upstream dispatch/CDB/branch units
  // guarantee these conditions. They are intentionally kept as assumes
  // (not relaxed) because the ROB's correctness depends on them.

  // CDB write and branch update cannot target the same tag simultaneously
  always_comb begin
  end

  // alloc_valid not asserted during flush (matches existing simulation assertion)
  always_comb begin
    assume (!(i_alloc_req.alloc_valid && (i_flush_en || i_flush_all)));
  end

  // -------------------------------------------------------------------------
  // Combinational properties (asserts, active when i_rst_n)
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // full and empty cannot both be true
      p_full_empty_mutex : assert (!(full && empty));

      // count == tail_ptr - head_ptr
      p_count_consistent : assert (count == (tail_ptr - head_ptr));

      // full iff pointers match with different MSB
      p_full_matches_ptrs :
      assert (full ==
        ((head_ptr[ReorderBufferTagWidth] != tail_ptr[ReorderBufferTagWidth]) &&
         (head_idx == tail_idx)));

      // empty iff pointers exactly equal
      p_empty_matches_ptrs : assert (empty == (head_ptr == tail_ptr));

      // alloc_en implies !full
      p_alloc_not_when_full : assert (!alloc_en || !full);

      // commit_en implies head_valid && head_done
      p_commit_requires_valid_done : assert (!commit_en || (head_valid && head_done));

      // commit output tag equals head_idx
      p_commit_only_at_head : assert (!commit_en || (o_commit_comb.tag == head_idx));

      // commit_stall implies !commit_en
      p_serial_stall_blocks_commit : assert (!commit_stall || !commit_en);
    end
  end

  // -------------------------------------------------------------------------
  // Sequential properties (asserts, require f_past_valid)
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin
      // After allocation, rob_valid at $past(tail_idx) is set
      if ($past(alloc_en)) begin
        p_alloc_sets_valid : assert (rob_valid[$past(tail_idx)]);
      end

      // After commit, rob_valid at $past(head_idx) is cleared
      if ($past(commit_en) && !$past(i_flush_all)) begin
        p_commit_clears_valid : assert (!rob_valid[$past(head_idx)]);
      end

      // After flush_all, buffer is empty
      if ($past(i_flush_all)) begin
        p_flush_all_empties : assert (empty);
      end

      // o_csr_start only in IDLE with CSR at head
      if ($past(o_csr_start)) begin
        p_csr_start_contract : assert ($past(serial_state) == SERIAL_IDLE && $past(head_is_csr));
      end

      // o_mret_start only in IDLE with MRET at head
      if ($past(o_mret_start)) begin
        p_mret_start_contract : assert ($past(serial_state) == SERIAL_IDLE && $past(head_is_mret));
      end

      // o_fence_i_flush is registered (one cycle after commit of FENCE.I)
      p_fence_i_flush_delayed :
      assert (o_fence_i_flush == ($past(commit_en) && $past(head_is_fence_i)));
    end

    // Reset properties (check state after reset deasserts)
    if (f_past_valid && i_rst_n && !$past(i_rst_n)) begin
      // After reset, all rob_valid bits are 0
      p_reset_clears_valid : assert (rob_valid == '0);

      // After reset, head_ptr and tail_ptr are 0
      p_reset_clears_ptrs : assert (head_ptr == '0 && tail_ptr == '0);

      // After reset, serial_state is IDLE
      p_reset_serial_idle : assert (serial_state == SERIAL_IDLE);
    end
  end

  // -------------------------------------------------------------------------
  // Cover properties
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // Allocation and commit in same cycle
      cover_alloc_and_commit : cover (alloc_en && commit_en);

      // Buffer reaches full state
      cover_buffer_full : cover (full);

      // Partial flush occurs
      cover_partial_flush : cover (i_flush_en);

      // CSR serialization completes
      cover_csr_serialize : cover (serial_state == SERIAL_CSR_EXEC && i_csr_done);

      // WFI wakes on interrupt
      cover_wfi_wakeup : cover (serial_state == SERIAL_WFI_WAIT && i_interrupt_pending);

      // MRET completes
      cover_mret_complete : cover (serial_state == SERIAL_MRET_EXEC && i_mret_done);

      // Exception triggers trap
      cover_exception_trap : cover (serial_state == SERIAL_TRAP_WAIT);

      // FENCE.I commit generates flush pulse
      cover_fence_i_flush : cover (o_fence_i_flush);
    end
  end

`endif  // FORMAL

endmodule : reorder_buffer
