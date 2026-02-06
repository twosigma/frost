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

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

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

    // =========================================================================
    // Store Queue Coordination
    // =========================================================================
    input logic i_sq_empty,  // Store queue is empty (for FENCE, AMO ordering)

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

    // FENCE.I triggers pipeline and icache flush after commit
    output logic o_fence_i_flush,  // FENCE.I committed, flush pipeline/icache

    // =========================================================================
    // Status Outputs
    // =========================================================================
    output logic                                      o_full,
    output logic                                      o_empty,
    output logic [riscv_pkg::ReorderBufferTagWidth:0] o_count,  // Number of valid entries

    // Head entry information (for external commit coordination)
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_head_tag,
    output logic                                        o_head_valid,
    output logic                                        o_head_done,

    // =========================================================================
    // Reorder Buffer Entry Read Interface (for RAT lookup of in-flight values)
    // =========================================================================
    // Allows RAT to check if a Reorder Buffer entry has completed (for bypass)
    input  logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_read_tag,
    output logic                                        o_read_done,
    output logic [                 riscv_pkg::FLEN-1:0] o_read_value
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
  localparam int unsigned FpFlagsWidth = $bits(riscv_pkg::fp_flags_t);
  localparam int unsigned RegAddrWidth = riscv_pkg::RegAddrWidth;

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

  // ===========================================================================
  // Debug Signals (for verification)
  // ===========================================================================
  // Expose internal struct field values for debug
  logic dbg_alloc_valid  /* verilator public_flat_rd */;
  assign dbg_alloc_valid = i_alloc_req.alloc_valid;

  logic [XLEN-1:0] dbg_alloc_pc  /* verilator public_flat_rd */;
  assign dbg_alloc_pc = i_alloc_req.pc;

  logic dbg_alloc_is_branch  /* verilator public_flat_rd */;
  assign dbg_alloc_is_branch = i_alloc_req.is_branch;

  // Allocation condition components
  logic dbg_alloc_condition  /* verilator public_flat_rd */;
  assign dbg_alloc_condition = i_alloc_req.alloc_valid && !full && !i_flush_all && !i_flush_en;

  // Raw packed struct debug
  logic [119:0] dbg_raw_alloc_req  /* verilator public_flat_rd */;
  assign dbg_raw_alloc_req = i_alloc_req;

  logic dbg_full_signal  /* verilator public_flat_rd */;
  assign dbg_full_signal = full;

  logic dbg_flush_all  /* verilator public_flat_rd */;
  assign dbg_flush_all = i_flush_all;

  logic dbg_flush_en  /* verilator public_flat_rd */;
  assign dbg_flush_en = i_flush_en;

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
  logic [ReorderBufferDepth-1:0] rob_dest_rf;
  logic [ReorderBufferDepth-1:0] rob_dest_valid;
  logic [ReorderBufferDepth-1:0] rob_is_store;
  logic [ReorderBufferDepth-1:0] rob_is_fp_store;
  logic [ReorderBufferDepth-1:0] rob_is_branch;
  logic [ReorderBufferDepth-1:0] rob_branch_taken;
  logic [ReorderBufferDepth-1:0] rob_predicted_taken;
  logic [ReorderBufferDepth-1:0] rob_mispredicted;
  logic [ReorderBufferDepth-1:0] rob_is_call;
  logic [ReorderBufferDepth-1:0] rob_is_return;
  logic [ReorderBufferDepth-1:0] rob_is_jal;
  logic [ReorderBufferDepth-1:0] rob_is_jalr;
  logic [ReorderBufferDepth-1:0] rob_has_checkpoint;
  logic [ReorderBufferDepth-1:0] rob_is_csr;
  logic [ReorderBufferDepth-1:0] rob_is_fence;
  logic [ReorderBufferDepth-1:0] rob_is_fence_i;
  logic [ReorderBufferDepth-1:0] rob_is_wfi;
  logic [ReorderBufferDepth-1:0] rob_is_mret;
  logic [ReorderBufferDepth-1:0] rob_is_amo;
  logic [ReorderBufferDepth-1:0] rob_is_lr;
  logic [ReorderBufferDepth-1:0] rob_is_sc;

  // Head and tail pointers (with extra bit for full/empty detection)
  logic [ReorderBufferTagWidth:0] head_ptr;
  logic [ReorderBufferTagWidth:0] tail_ptr;

  // Derived pointer values (without wrap bit)
  logic [ReorderBufferTagWidth-1:0] head_idx;
  logic [ReorderBufferTagWidth-1:0] tail_idx;

  // Status signals
  logic full;
  logic empty;
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
  logic [XLEN-1:0] head_branch_target;  // from RAM
  logic head_predicted_taken;
  logic [XLEN-1:0] head_predicted_target;  // from RAM
  logic head_mispredicted;
  logic head_is_call;
  logic head_is_return;
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

  // Head entry fields from FF-backed packed vectors
  assign head_valid = rob_valid[head_idx];
  assign head_done = rob_done[head_idx];
  assign head_exception = rob_exception[head_idx];
  assign head_dest_rf = rob_dest_rf[head_idx];
  assign head_dest_valid = rob_dest_valid[head_idx];
  assign head_is_store = rob_is_store[head_idx];
  assign head_is_fp_store = rob_is_fp_store[head_idx];
  assign head_is_branch = rob_is_branch[head_idx];
  assign head_branch_taken = rob_branch_taken[head_idx];
  assign head_predicted_taken = rob_predicted_taken[head_idx];
  assign head_mispredicted = rob_mispredicted[head_idx];
  assign head_is_call = rob_is_call[head_idx];
  assign head_is_return = rob_is_return[head_idx];
  assign head_is_jal = rob_is_jal[head_idx];
  assign head_is_jalr = rob_is_jalr[head_idx];
  assign head_has_checkpoint = rob_has_checkpoint[head_idx];
  assign head_is_csr = rob_is_csr[head_idx];
  assign head_is_fence = rob_is_fence[head_idx];
  assign head_is_fence_i = rob_is_fence_i[head_idx];
  assign head_is_wfi = rob_is_wfi[head_idx];
  assign head_is_mret = rob_is_mret[head_idx];
  assign head_is_amo = rob_is_amo[head_idx];
  assign head_is_lr = rob_is_lr[head_idx];
  assign head_is_sc = rob_is_sc[head_idx];

  // Head is ready to potentially commit
  assign head_ready = head_valid && head_done;

  // ===========================================================================
  // Distributed RAM Write Enables and Data
  // ===========================================================================

  logic alloc_en;
  assign alloc_en = i_alloc_req.alloc_valid && !full && !i_flush_all && !i_flush_en;

  logic cdb_wr_en;
  assign cdb_wr_en = i_cdb_write.valid && !i_flush_all && rob_valid[i_cdb_write.tag];

  logic branch_wr_en;
  assign branch_wr_en = i_branch_update.valid && !i_flush_all && rob_valid[i_branch_update.tag];

  // Allocation data precomputation for fields with instruction-type-dependent values
  logic [FLEN-1:0] alloc_value_data;
  always_comb begin
    if (i_alloc_req.is_jal || i_alloc_req.is_jalr)
      alloc_value_data = {{(FLEN - XLEN) {1'b0}}, i_alloc_req.link_addr};
    else alloc_value_data = '0;
  end

  logic [XLEN-1:0] alloc_branch_target_data;
  assign alloc_branch_target_data = i_alloc_req.is_jal ? i_alloc_req.predicted_target : '0;

  logic [CheckpointIdWidth-1:0] alloc_checkpoint_id_data;
  assign alloc_checkpoint_id_data = (i_checkpoint_valid && i_alloc_req.is_branch) ?
                                     i_checkpoint_id : '0;

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
      .i_write_enable ({cdb_wr_en, alloc_en}),
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
      .i_write_enable ({cdb_wr_en, alloc_en}),
      .i_write_address({i_cdb_write.tag, tail_idx}),
      .i_write_data   ({i_cdb_write.value, alloc_value_data}),
      .i_read_address (i_read_tag),
      .o_read_data    (o_read_value)
  );

  // rob_exc_cause: 2 write ports (alloc='0 + CDB), 1 read port (head)
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (ExcCauseWidth),
      .NUM_WRITE_PORTS(2)
  ) u_rob_exc_cause (
      .i_clk,
      .i_write_enable ({cdb_wr_en, alloc_en}),
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
      .i_write_enable ({cdb_wr_en, alloc_en}),
      .i_write_address({i_cdb_write.tag, tail_idx}),
      .i_write_data   ({i_cdb_write.fp_flags, FpFlagsWidth'(0)}),
      .i_read_address (head_idx),
      .o_read_data    (head_fp_flags)
  );

  // rob_branch_target: 2 write ports (alloc + branch update), 1 read port (head)
  mwp_dist_ram #(
      .ADDR_WIDTH     (ReorderBufferTagWidth),
      .DATA_WIDTH     (XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_rob_branch_target (
      .i_clk,
      .i_write_enable ({branch_wr_en, alloc_en}),
      .i_write_address({i_branch_update.tag, tail_idx}),
      .i_write_data   ({i_branch_update.target, alloc_branch_target_data}),
      .i_read_address (head_idx),
      .o_read_data    (head_branch_target)
  );

  // ===========================================================================
  // Allocation Logic
  // ===========================================================================

  // Allocation response
  assign o_alloc_resp.alloc_ready = !full;
  assign o_alloc_resp.alloc_tag = tail_idx;
  assign o_alloc_resp.full = full;

  // Flush age calculation for partial flush (computed combinationally)
  // flush_age = flush_tag - head_idx (mod depth, wraps naturally in 5-bit arithmetic)
  logic [ReorderBufferTagWidth-1:0] flush_age;
  assign flush_age = i_flush_tag - head_idx;

  // Allocation write - tail pointer management
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      tail_ptr <= '0;
    end else if (i_flush_all) begin
      // Full flush: reset tail to head
      tail_ptr <= head_ptr;
    end else if (i_flush_en && !i_flush_all) begin
      // Partial flush: set tail to flush_tag + 1
      // Use age-based arithmetic to handle wrap correctly (extend 5-bit age to 6-bit)
      tail_ptr <= head_ptr + {1'b0, flush_age} + 1'b1;
    end else if (i_alloc_req.alloc_valid && !full && !i_flush_all && !i_flush_en) begin
      // Normal allocation: advance tail
      tail_ptr <= tail_ptr + 1'b1;
    end
  end

  // ===========================================================================
  // Reorder Buffer FF Storage (1-bit packed vectors)
  // ===========================================================================

  // Handle allocation, CDB writes, branch updates, and flush for FF-backed fields.
  // Multi-bit fields (pc, dest_reg, value, branch_target, predicted_target,
  // checkpoint_id, exc_cause, fp_flags) are handled by distributed RAM above.
  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      // Reset all entries to invalid
      rob_valid           <= '0;
      rob_done            <= '0;
      rob_exception       <= '0;
      rob_dest_rf         <= '0;
      rob_dest_valid      <= '0;
      rob_is_store        <= '0;
      rob_is_fp_store     <= '0;
      rob_is_branch       <= '0;
      rob_branch_taken    <= '0;
      rob_predicted_taken <= '0;
      rob_mispredicted    <= '0;
      rob_is_call         <= '0;
      rob_is_return       <= '0;
      rob_is_jal          <= '0;
      rob_is_jalr         <= '0;
      rob_has_checkpoint  <= '0;
      rob_is_csr          <= '0;
      rob_is_fence        <= '0;
      rob_is_fence_i      <= '0;
      rob_is_wfi          <= '0;
      rob_is_mret         <= '0;
      rob_is_amo          <= '0;
      rob_is_lr           <= '0;
      rob_is_sc           <= '0;
    end else begin
      // ---------------------------------------------------------------------
      // Flush Logic
      // ---------------------------------------------------------------------
      if (i_flush_all) begin
        // Full flush: invalidate all entries
        rob_valid <= '0;
      end else if (i_flush_en) begin
        // Partial flush: invalidate entries after flush_tag
        for (int i = 0; i < ReorderBufferDepth; i++) begin
          // Invalidate if entry is younger than flush point
          if (rob_valid[i] && should_flush_entry(
                  i[ReorderBufferTagWidth-1:0], i_flush_tag, head_idx
              )) begin
            rob_valid[i] <= 1'b0;
          end
        end
      end

      // ---------------------------------------------------------------------
      // Allocation Write (FF-backed fields only)
      // ---------------------------------------------------------------------
      if (alloc_en) begin
        rob_valid[tail_idx]           <= 1'b1;
        rob_dest_rf[tail_idx]         <= i_alloc_req.dest_rf;
        rob_dest_valid[tail_idx]      <= i_alloc_req.dest_valid;
        rob_is_store[tail_idx]        <= i_alloc_req.is_store;
        rob_is_fp_store[tail_idx]     <= i_alloc_req.is_fp_store;
        rob_is_branch[tail_idx]       <= i_alloc_req.is_branch;
        rob_predicted_taken[tail_idx] <= i_alloc_req.predicted_taken;
        rob_is_call[tail_idx]         <= i_alloc_req.is_call;
        rob_is_return[tail_idx]       <= i_alloc_req.is_return;
        rob_is_jal[tail_idx]          <= i_alloc_req.is_jal;
        rob_is_jalr[tail_idx]         <= i_alloc_req.is_jalr;
        rob_is_csr[tail_idx]          <= i_alloc_req.is_csr;
        rob_is_fence[tail_idx]        <= i_alloc_req.is_fence;
        rob_is_fence_i[tail_idx]      <= i_alloc_req.is_fence_i;
        rob_is_wfi[tail_idx]          <= i_alloc_req.is_wfi;
        rob_is_mret[tail_idx]         <= i_alloc_req.is_mret;
        rob_is_amo[tail_idx]          <= i_alloc_req.is_amo;
        rob_is_lr[tail_idx]           <= i_alloc_req.is_lr;
        rob_is_sc[tail_idx]           <= i_alloc_req.is_sc;

        // Initialize done/exception/checkpoint/misprediction fields
        rob_exception[tail_idx]       <= 1'b0;
        rob_has_checkpoint[tail_idx]  <= 1'b0;
        rob_branch_taken[tail_idx]    <= 1'b0;
        rob_mispredicted[tail_idx]    <= 1'b0;

        // JAL: target is known at dispatch, mark done immediately
        // Value is link address (PC+2 or PC+4), zero-extended to FLEN
        if (i_alloc_req.is_jal) begin
          rob_done[tail_idx]         <= 1'b1;
          // For JAL, branch is always taken with known target
          rob_branch_taken[tail_idx] <= 1'b1;
        end else if (i_alloc_req.is_jalr) begin
          // JALR: target unknown until execute, but link addr is known
          rob_done[tail_idx] <= 1'b0;
        end else if (i_alloc_req.is_wfi || i_alloc_req.is_fence ||
                     i_alloc_req.is_fence_i || i_alloc_req.is_mret) begin
          // These instructions are "done" from execution perspective at dispatch
          // but commit is gated by serialization logic
          rob_done[tail_idx] <= 1'b1;
        end else begin
          rob_done[tail_idx] <= 1'b0;
        end
      end

      // ---------------------------------------------------------------------
      // Checkpoint Assignment (same cycle as allocation for branches)
      // ---------------------------------------------------------------------
      // When dispatch allocates a branch and checkpoint unit provides an ID
      if (i_checkpoint_valid && i_alloc_req.alloc_valid && i_alloc_req.is_branch &&
          !full && !i_flush_all && !i_flush_en) begin
        rob_has_checkpoint[tail_idx] <= 1'b1;
      end

      // ---------------------------------------------------------------------
      // CDB Write (mark entry done with result)
      // ---------------------------------------------------------------------
      // For non-branch instructions (ALU, MUL, DIV, MEM, FP)
      // Value, exc_cause, fp_flags are written via distributed RAM.
      if (i_cdb_write.valid && !i_flush_all) begin
        if (rob_valid[i_cdb_write.tag]) begin
          rob_done[i_cdb_write.tag]      <= 1'b1;
          rob_exception[i_cdb_write.tag] <= i_cdb_write.exception;
        end
      end

      // ---------------------------------------------------------------------
      // Branch Update (mark branch done with resolution)
      // ---------------------------------------------------------------------
      // For branch/jump instructions only.
      // The mispredicted field from branch unit is authoritative - it knows about
      // RAS/indirect predictor specifics that the ROB doesn't track.
      // branch_target is written via distributed RAM.
      if (i_branch_update.valid && !i_flush_all) begin
        if (rob_valid[i_branch_update.tag]) begin
          // Record branch resolution
          rob_branch_taken[i_branch_update.tag] <= i_branch_update.taken;
          rob_mispredicted[i_branch_update.tag] <= i_branch_update.mispredicted;

          // For JALR and conditional branches: mark done now
          // JAL was already marked done at dispatch
          if (!rob_is_jal[i_branch_update.tag]) begin
            rob_done[i_branch_update.tag] <= 1'b1;
          end
        end
      end

      // ---------------------------------------------------------------------
      // Commit Deallocation
      // ---------------------------------------------------------------------
      // Invalidate the committed entry (head pointer advanced separately)
      if (commit_en && !i_flush_all && !i_flush_en) begin
        rob_valid[head_idx] <= 1'b0;
      end
    end
  end

  // ===========================================================================
  // Head Pointer Management
  // ===========================================================================

  always_ff @(posedge i_clk or negedge i_rst_n) begin
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

  always_ff @(posedge i_clk or negedge i_rst_n) begin
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
        if (head_ready && !i_flush_en && !i_flush_all) begin
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
            // FENCE/FENCE.I: wait for SQ to drain
            if (i_sq_empty) begin
              // SQ already empty, can commit
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
          end else if (head_is_amo || head_is_lr || head_is_sc) begin
            // AMO/LR/SC: need SQ empty before commit
            // Note: actual AMO execution happens in memory unit
            if (!i_sq_empty) begin
              serial_state_next = SERIAL_WAIT_SQ;
              commit_stall = 1'b1;
            end
            // If SQ empty, commit proceeds normally
          end
          // Non-serializing instructions: no stall
        end
      end

      SERIAL_WAIT_SQ: begin
        commit_stall = 1'b1;
        if (i_sq_empty) begin
          // SQ drained, can commit
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

  // Commit when head is ready, no stall, and no flush in progress
  assign commit_en = head_ready && !commit_stall && !i_flush_en && !i_flush_all;

  // Misprediction at commit - use the authoritative flag from branch unit
  // The branch unit knows about RAS, indirect predictor, and other specifics
  assign commit_misprediction = head_is_branch && head_mispredicted;

  // ===========================================================================
  // External Coordination Outputs
  // ===========================================================================

  // CSR execution signal - asserted when entering CSR_EXEC state
  assign o_csr_start = (serial_state == SERIAL_IDLE) && head_ready &&
                       head_is_csr && !head_exception &&
                       !i_flush_en && !i_flush_all;

  // MRET execution signal - asserted when entering MRET_EXEC state
  assign o_mret_start = (serial_state == SERIAL_IDLE) && head_ready &&
                        head_is_mret && !head_exception &&
                        !i_flush_en && !i_flush_all;

  // Trap pending signal - asserted when exception at head
  assign o_trap_pending = (serial_state == SERIAL_TRAP_WAIT) ||
                          (head_ready && head_exception && !i_flush_all);
  assign o_trap_pc = head_pc;
  assign o_trap_cause = head_exc_cause;

  // FENCE.I flush signal - pulse when FENCE.I commits
  always_ff @(posedge i_clk or negedge i_rst_n) begin
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
    o_commit = '0;

    if (commit_en) begin
      o_commit.valid          = 1'b1;
      o_commit.tag            = head_idx;
      o_commit.dest_rf        = head_dest_rf;
      o_commit.dest_reg       = head_dest_reg;
      o_commit.dest_valid     = head_dest_valid;
      o_commit.value          = head_value;
      o_commit.is_store       = head_is_store;
      o_commit.is_fp_store    = head_is_fp_store;
      o_commit.exception      = head_exception;
      o_commit.pc             = head_pc;
      o_commit.exc_cause      = head_exc_cause;
      o_commit.fp_flags       = head_fp_flags;

      // Branch misprediction recovery
      o_commit.misprediction  = commit_misprediction;
      o_commit.has_checkpoint = head_has_checkpoint;
      o_commit.checkpoint_id  = head_checkpoint_id;
      // Redirect PC:
      // - MRET: redirect to mepc
      // - Mispredicted taken: redirect to branch_target (actual taken target)
      // - Mispredicted not-taken: redirect to pc+4 (fall-through)
      if (head_is_mret) begin
        o_commit.redirect_pc = i_mepc;
      end else if (head_branch_taken) begin
        // Mispredicted as not-taken but actually taken -> go to taken target
        o_commit.redirect_pc = head_branch_target;
      end else begin
        // Mispredicted as taken but actually not-taken -> go to pc+4
        o_commit.redirect_pc = head_pc + 32'd4;
      end

      // Serializing instruction flags (for external units)
      o_commit.is_csr     = head_is_csr;
      o_commit.is_fence   = head_is_fence;
      o_commit.is_fence_i = head_is_fence_i;
      o_commit.is_wfi     = head_is_wfi;
      o_commit.is_mret    = head_is_mret;
      o_commit.is_amo     = head_is_amo;
      o_commit.is_lr      = head_is_lr;
      o_commit.is_sc      = head_is_sc;
    end
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

  // ===========================================================================
  // Reorder Buffer Entry Read Interface (for RAT bypass)
  // ===========================================================================

  assign o_read_done = rob_valid[i_read_tag] && rob_done[i_read_tag];
  // o_read_value is driven by u_rob_value_rat distributed RAM instance

  // ===========================================================================
  // Assertions (Simulation Only)
  // ===========================================================================

`ifndef SYNTHESIS
  // Check that we don't allocate when full
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_req.alloc_valid && full) begin
      $error("Reorder Buffer: Allocation attempted when full!");
    end
  end

  // Check that dispatch doesn't allocate during flush (invariant: dispatch must be stalled)
  // Note: alloc_ready doesn't gate on flush, so this assertion documents the required behavior
  always @(posedge i_clk) begin
    if (i_rst_n && i_alloc_req.alloc_valid && (i_flush_en || i_flush_all)) begin
      $error("Reorder Buffer: Allocation attempted during flush!");
    end
  end

  // Check that CDB writes target valid entries
  always @(posedge i_clk) begin
    if (i_rst_n && i_cdb_write.valid && !rob_valid[i_cdb_write.tag]) begin
      $error("Reorder Buffer: CDB write to invalid entry tag=%0d", i_cdb_write.tag);
    end
  end

  // Check that branch updates target valid entries
  always @(posedge i_clk) begin
    if (i_rst_n && i_branch_update.valid && !rob_valid[i_branch_update.tag]) begin
      $error("Reorder Buffer: Branch update to invalid entry tag=%0d", i_branch_update.tag);
    end
  end

  // Check serialization state transitions are valid
  always @(posedge i_clk) begin
    if (i_rst_n && serial_state != SERIAL_IDLE && !head_ready) begin
      $warning("Reorder Buffer: Serialization state %0d but head not ready", serial_state);
    end
  end
`endif

endmodule : reorder_buffer
