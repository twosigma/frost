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
 * Reservation Station - Generic, Parameterized Module
 *
 * Tracks source operand readiness and issues instructions to functional
 * units when all operands are available. The same module is instantiated
 * for each RS type with different depths:
 *   INT_RS=8, MUL_RS=4, MEM_RS=8, FP_RS=6, FMUL_RS=4, FDIV_RS=2
 *
 * Features:
 *   - Parameterized depth (2-8 entries, all FF-based)
 *   - Up to 3 source operands (for FMA instructions)
 *   - CDB snoop for operand wakeup with same-cycle dispatch bypass
 *   - Priority-encoder issue selection (lowest index first)
 *   - Immediate bypass: use_imm skips src2 readiness check
 *   - Partial flush (age-based) and full flush support
 *
 * Storage Strategy:
 *   All fields in FFs (not LUTRAM). RS entries are small (depth 2-8) and
 *   require parallel content-addressable access for CDB tag comparison
 *   across all entries. LUTRAM only provides single-address reads, which
 *   doesn't suit the RS broadcast-match access pattern.
 *
 * Icarus VPI Workaround:
 *   Icarus Verilog 12.0 crashes (vvp event.cc assertion) on very wide
 *   packed struct VPI-facing ports. Internal signals of any width are
 *   fine; only ports that cocotb drives/reads via VPI are affected. Ports
 *   up to 187 bits work; 352+ bits crash. When ICARUS is defined, the
 *   module exposes dispatch and issue fields as individual ports. Internal
 *   wire aliases ensure the core logic is identical for both paths.
 */

module reservation_station #(
    parameter int unsigned DEPTH = 8
) (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Dispatch Interface (from Dispatch Unit)
    // =========================================================================
`ifdef ICARUS
    // Flattened ports -- avoids wide packed struct signals in Icarus VVP.
    input logic i_dispatch_valid,
    input logic [2:0] i_dispatch_rs_type,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_dispatch_rob_tag,
    input logic [31:0] i_dispatch_op,
    input logic i_dispatch_src1_ready,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_dispatch_src1_tag,
    input logic [riscv_pkg::FLEN-1:0] i_dispatch_src1_value,
    input logic i_dispatch_src2_ready,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_dispatch_src2_tag,
    input logic [riscv_pkg::FLEN-1:0] i_dispatch_src2_value,
    input logic i_dispatch_src3_ready,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_dispatch_src3_tag,
    input logic [riscv_pkg::FLEN-1:0] i_dispatch_src3_value,
    input logic [riscv_pkg::XLEN-1:0] i_dispatch_imm,
    input logic i_dispatch_use_imm,
    input logic [2:0] i_dispatch_rm,
    input logic [riscv_pkg::XLEN-1:0] i_dispatch_branch_target,
    input logic i_dispatch_predicted_taken,
    input logic [riscv_pkg::XLEN-1:0] i_dispatch_predicted_target,
    input logic i_dispatch_is_fp_mem,
    input logic [1:0] i_dispatch_mem_size,
    input logic i_dispatch_mem_signed,
    input logic [11:0] i_dispatch_csr_addr,
    input logic [4:0] i_dispatch_csr_imm,
`else
    input riscv_pkg::rs_dispatch_t i_dispatch,
`endif
    output logic o_full,

    // =========================================================================
    // CDB Snoop / Wakeup (84 bits -- small enough for all simulators)
    // =========================================================================
    input riscv_pkg::cdb_broadcast_t i_cdb,

    // =========================================================================
    // Issue Interface (to Functional Unit)
    // =========================================================================
`ifdef ICARUS
    output logic                                                        o_issue_valid,
    output logic                 [riscv_pkg::ReorderBufferTagWidth-1:0] o_issue_rob_tag,
    output logic                 [                                31:0] o_issue_op,
    output logic                 [                 riscv_pkg::FLEN-1:0] o_issue_src1_value,
    output logic                 [                 riscv_pkg::FLEN-1:0] o_issue_src2_value,
    output logic                 [                 riscv_pkg::FLEN-1:0] o_issue_src3_value,
    output logic                 [                 riscv_pkg::XLEN-1:0] o_issue_imm,
    output logic                                                        o_issue_use_imm,
    output logic                 [                                 2:0] o_issue_rm,
    output logic                 [                 riscv_pkg::XLEN-1:0] o_issue_branch_target,
    output logic                                                        o_issue_predicted_taken,
    output logic                 [                 riscv_pkg::XLEN-1:0] o_issue_predicted_target,
    output logic                                                        o_issue_is_fp_mem,
    output logic                 [                                 1:0] o_issue_mem_size,
    output logic                                                        o_issue_mem_signed,
    output logic                 [                                11:0] o_issue_csr_addr,
    output logic                 [                                 4:0] o_issue_csr_imm,
`else
    output riscv_pkg::rs_issue_t                                        o_issue,
`endif
    input  logic                                                        i_fu_ready,

    // =========================================================================
    // Flush Control
    // =========================================================================
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,
    input logic                                        i_flush_all,

    // =========================================================================
    // Status / Debug
    // =========================================================================
    output logic                       o_empty,
    output logic [$clog2(DEPTH+1)-1:0] o_count
);

  // ===========================================================================
  // Local Parameters
  // ===========================================================================
  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned CountWidth = $clog2(DEPTH + 1);

  // ===========================================================================
  // Helper Functions
  // ===========================================================================

  // Check if entry_tag is younger than flush_tag (relative to rob_head)
  function automatic logic should_flush_entry(input logic [ReorderBufferTagWidth-1:0] entry_tag,
                                              input logic [ReorderBufferTagWidth-1:0] flush_tag,
                                              input logic [ReorderBufferTagWidth-1:0] head);
    logic [ReorderBufferTagWidth:0] entry_age;
    logic [ReorderBufferTagWidth:0] flush_age;
    begin
      entry_age = {1'b0, entry_tag} - {1'b0, head};
      flush_age = {1'b0, flush_tag} - {1'b0, head};
      should_flush_entry = entry_age > flush_age;
    end
  endfunction

  // ===========================================================================
  // Dispatch Field Extraction
  // ===========================================================================
  // Wire aliases allow the module body to work identically regardless of
  // whether the dispatch input is a packed struct port or individual signals.

`ifdef ICARUS
  wire                                              dispatch_valid = i_dispatch_valid;
  wire                  [ReorderBufferTagWidth-1:0] dispatch_rob_tag = i_dispatch_rob_tag;
  riscv_pkg::instr_op_e                             dispatch_op;
  assign dispatch_op = riscv_pkg::instr_op_e'(i_dispatch_op);
  wire dispatch_src1_ready = i_dispatch_src1_ready;
  wire [ReorderBufferTagWidth-1:0] dispatch_src1_tag = i_dispatch_src1_tag;
  wire [FLEN-1:0] dispatch_src1_value = i_dispatch_src1_value;
  wire dispatch_src2_ready = i_dispatch_src2_ready;
  wire [ReorderBufferTagWidth-1:0] dispatch_src2_tag = i_dispatch_src2_tag;
  wire [FLEN-1:0] dispatch_src2_value = i_dispatch_src2_value;
  wire dispatch_src3_ready = i_dispatch_src3_ready;
  wire [ReorderBufferTagWidth-1:0] dispatch_src3_tag = i_dispatch_src3_tag;
  wire [FLEN-1:0] dispatch_src3_value = i_dispatch_src3_value;
  wire [XLEN-1:0] dispatch_imm = i_dispatch_imm;
  wire dispatch_use_imm = i_dispatch_use_imm;
  wire [2:0] dispatch_rm = i_dispatch_rm;
  wire [XLEN-1:0] dispatch_branch_target = i_dispatch_branch_target;
  wire dispatch_predicted_taken = i_dispatch_predicted_taken;
  wire [XLEN-1:0] dispatch_predicted_target = i_dispatch_predicted_target;
  wire dispatch_is_fp_mem = i_dispatch_is_fp_mem;
  riscv_pkg::mem_size_e dispatch_mem_size;
  assign dispatch_mem_size = riscv_pkg::mem_size_e'(i_dispatch_mem_size);
  wire        dispatch_mem_signed = i_dispatch_mem_signed;
  wire [11:0] dispatch_csr_addr = i_dispatch_csr_addr;
  wire [ 4:0] dispatch_csr_imm = i_dispatch_csr_imm;
`else
  wire                                              dispatch_valid = i_dispatch.valid;
  wire                  [ReorderBufferTagWidth-1:0] dispatch_rob_tag = i_dispatch.rob_tag;
  riscv_pkg::instr_op_e                             dispatch_op;
  assign dispatch_op = i_dispatch.op;
  wire dispatch_src1_ready = i_dispatch.src1_ready;
  wire [ReorderBufferTagWidth-1:0] dispatch_src1_tag = i_dispatch.src1_tag;
  wire [FLEN-1:0] dispatch_src1_value = i_dispatch.src1_value;
  wire dispatch_src2_ready = i_dispatch.src2_ready;
  wire [ReorderBufferTagWidth-1:0] dispatch_src2_tag = i_dispatch.src2_tag;
  wire [FLEN-1:0] dispatch_src2_value = i_dispatch.src2_value;
  wire dispatch_src3_ready = i_dispatch.src3_ready;
  wire [ReorderBufferTagWidth-1:0] dispatch_src3_tag = i_dispatch.src3_tag;
  wire [FLEN-1:0] dispatch_src3_value = i_dispatch.src3_value;
  wire [XLEN-1:0] dispatch_imm = i_dispatch.imm;
  wire dispatch_use_imm = i_dispatch.use_imm;
  wire [2:0] dispatch_rm = i_dispatch.rm;
  wire [XLEN-1:0] dispatch_branch_target = i_dispatch.branch_target;
  wire dispatch_predicted_taken = i_dispatch.predicted_taken;
  wire [XLEN-1:0] dispatch_predicted_target = i_dispatch.predicted_target;
  wire dispatch_is_fp_mem = i_dispatch.is_fp_mem;
  riscv_pkg::mem_size_e dispatch_mem_size;
  assign dispatch_mem_size = i_dispatch.mem_size;
  wire        dispatch_mem_signed = i_dispatch.mem_signed;
  wire [11:0] dispatch_csr_addr = i_dispatch.csr_addr;
  wire [ 4:0] dispatch_csr_imm = i_dispatch.csr_imm;
`endif

  // ===========================================================================
  // Issue Output Intermediates
  // ===========================================================================
  // Set in the always_comb block below; assigned to output ports via
  // simulator-specific logic (ifdef ICARUS assigns / else struct pack).

  logic                             issue_out_valid;
  logic [ReorderBufferTagWidth-1:0] issue_out_rob_tag;
`ifdef ICARUS
  logic [31:0] issue_out_op;
`else
  riscv_pkg::instr_op_e issue_out_op;
`endif
  logic [FLEN-1:0] issue_out_src1_value;
  logic [FLEN-1:0] issue_out_src2_value;
  logic [FLEN-1:0] issue_out_src3_value;
  logic [XLEN-1:0] issue_out_imm;
  logic            issue_out_use_imm;
  logic [     2:0] issue_out_rm;
  logic [XLEN-1:0] issue_out_branch_target;
  logic            issue_out_predicted_taken;
  logic [XLEN-1:0] issue_out_predicted_target;
  logic            issue_out_is_fp_mem;
`ifdef ICARUS
  logic [1:0] issue_out_mem_size;
`else
  riscv_pkg::mem_size_e issue_out_mem_size;
`endif
  logic        issue_out_mem_signed;
  logic [11:0] issue_out_csr_addr;
  logic [ 4:0] issue_out_csr_imm;

  // ===========================================================================
  // Debug Signals (for verification -- Verilator only)
  // ===========================================================================
`ifdef VERILATOR
  logic dbg_dispatch_valid  /* verilator public_flat_rd */;
  assign dbg_dispatch_valid = dispatch_valid;

  logic dbg_issue_valid  /* verilator public_flat_rd */;
  assign dbg_issue_valid = issue_out_valid;

  logic dbg_full  /* verilator public_flat_rd */;
  assign dbg_full = full;
`endif

  // ===========================================================================
  // Storage -- Per-entry FF arrays
  // ===========================================================================

  // 1-bit packed vectors (for bulk operations)
  logic [                DEPTH-1:0] rs_valid;
  logic [                DEPTH-1:0] rs_src1_ready;
  logic [                DEPTH-1:0] rs_src2_ready;
  logic [                DEPTH-1:0] rs_src3_ready;
  logic [                DEPTH-1:0] rs_use_imm;

  // Multi-bit field arrays
  logic [ReorderBufferTagWidth-1:0] rs_rob_tag    [DEPTH];
`ifdef ICARUS
  logic [31:0] rs_op[DEPTH];
`else
  riscv_pkg::instr_op_e rs_op[DEPTH];
`endif

  logic [ReorderBufferTagWidth-1:0] rs_src1_tag        [DEPTH];
  logic [                 FLEN-1:0] rs_src1_value      [DEPTH];

  logic [ReorderBufferTagWidth-1:0] rs_src2_tag        [DEPTH];
  logic [                 FLEN-1:0] rs_src2_value      [DEPTH];

  logic [ReorderBufferTagWidth-1:0] rs_src3_tag        [DEPTH];
  logic [                 FLEN-1:0] rs_src3_value      [DEPTH];

  logic [                 XLEN-1:0] rs_imm             [DEPTH];
  logic [                      2:0] rs_rm              [DEPTH];

  // Branch fields
  logic [                 XLEN-1:0] rs_branch_target   [DEPTH];
  logic [                DEPTH-1:0] rs_predicted_taken;
  logic [                 XLEN-1:0] rs_predicted_target[DEPTH];

  // Memory fields
  logic [                DEPTH-1:0] rs_is_fp_mem;
`ifdef ICARUS
  logic [1:0] rs_mem_size[DEPTH];
`else
  riscv_pkg::mem_size_e rs_mem_size[DEPTH];
`endif
  logic [        DEPTH-1:0] rs_mem_signed;

  // CSR fields
  logic [             11:0] rs_csr_addr   [DEPTH];
  logic [              4:0] rs_csr_imm    [DEPTH];

  // ===========================================================================
  // Internal Signals
  // ===========================================================================

  logic                     full;
  logic                     empty;
  logic [   CountWidth-1:0] count;

  // Free entry selection
  logic [$clog2(DEPTH)-1:0] free_idx;
  logic                     free_found;

  // Issue selection
  logic [        DEPTH-1:0] entry_ready;
  logic [$clog2(DEPTH)-1:0] issue_idx;
  logic                     any_ready;
  logic                     issue_fire;

  // Dispatch condition
  logic                     dispatch_fire;

  // ===========================================================================
  // Combinational Logic
  // ===========================================================================

  // --- Count, full, empty ---
  always_comb begin
    count = '0;
    for (int i = 0; i < DEPTH; i++) begin
      count = count + {{(CountWidth - 1) {1'b0}}, rs_valid[i]};
    end
  end

  assign full  = (count == CountWidth'(DEPTH));
  assign empty = (count == '0);

  // --- Free entry selection (priority encoder: lowest free index) ---
  always_comb begin
    free_idx   = '0;
    free_found = 1'b0;
    for (int i = 0; i < DEPTH; i++) begin
      if (!rs_valid[i] && !free_found) begin
        free_idx   = $clog2(DEPTH)'(i);
        free_found = 1'b1;
      end
    end
  end

  // --- Dispatch fire condition ---
  assign dispatch_fire = dispatch_valid && !full && !i_flush_all && !i_flush_en;

  // --- Ready check per entry ---
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      entry_ready[i] = rs_valid[i]
                     && rs_src1_ready[i]
                     && (rs_src2_ready[i] || rs_use_imm[i])
                     && rs_src3_ready[i];
    end
  end

  // --- Issue selection (priority encoder: lowest ready index) ---
  always_comb begin
    issue_idx = '0;
    any_ready = 1'b0;
    for (int i = 0; i < DEPTH; i++) begin
      if (entry_ready[i] && !any_ready) begin
        issue_idx = $clog2(DEPTH)'(i);
        any_ready = 1'b1;
      end
    end
  end

  assign issue_fire = any_ready && i_fu_ready;

  // --- Issue output ---
  always_comb begin
    issue_out_valid            = 1'b0;
    issue_out_rob_tag          = '0;
    issue_out_op               = riscv_pkg::instr_op_e'(0);
    issue_out_src1_value       = '0;
    issue_out_src2_value       = '0;
    issue_out_src3_value       = '0;
    issue_out_imm              = '0;
    issue_out_use_imm          = 1'b0;
    issue_out_rm               = '0;
    issue_out_branch_target    = '0;
    issue_out_predicted_taken  = 1'b0;
    issue_out_predicted_target = '0;
    issue_out_is_fp_mem        = 1'b0;
    issue_out_mem_size         = riscv_pkg::mem_size_e'(0);
    issue_out_mem_signed       = 1'b0;
    issue_out_csr_addr         = '0;
    issue_out_csr_imm          = '0;
    if (issue_fire) begin
      issue_out_valid            = 1'b1;
      issue_out_rob_tag          = rs_rob_tag[issue_idx];
      issue_out_op               = rs_op[issue_idx];
      issue_out_src1_value       = rs_src1_value[issue_idx];
      issue_out_src2_value       = rs_src2_value[issue_idx];
      issue_out_src3_value       = rs_src3_value[issue_idx];
      issue_out_imm              = rs_imm[issue_idx];
      issue_out_use_imm          = rs_use_imm[issue_idx];
      issue_out_rm               = rs_rm[issue_idx];
      issue_out_branch_target    = rs_branch_target[issue_idx];
      issue_out_predicted_taken  = rs_predicted_taken[issue_idx];
      issue_out_predicted_target = rs_predicted_target[issue_idx];
      issue_out_is_fp_mem        = rs_is_fp_mem[issue_idx];
      issue_out_mem_size         = rs_mem_size[issue_idx];
      issue_out_mem_signed       = rs_mem_signed[issue_idx];
      issue_out_csr_addr         = rs_csr_addr[issue_idx];
      issue_out_csr_imm          = rs_csr_imm[issue_idx];
    end
  end

  // --- Issue port assignment ---
`ifdef ICARUS
  assign o_issue_valid            = issue_out_valid;
  assign o_issue_rob_tag          = issue_out_rob_tag;
  assign o_issue_op               = issue_out_op;
  assign o_issue_src1_value       = issue_out_src1_value;
  assign o_issue_src2_value       = issue_out_src2_value;
  assign o_issue_src3_value       = issue_out_src3_value;
  assign o_issue_imm              = issue_out_imm;
  assign o_issue_use_imm          = issue_out_use_imm;
  assign o_issue_rm               = issue_out_rm;
  assign o_issue_branch_target    = issue_out_branch_target;
  assign o_issue_predicted_taken  = issue_out_predicted_taken;
  assign o_issue_predicted_target = issue_out_predicted_target;
  assign o_issue_is_fp_mem        = issue_out_is_fp_mem;
  assign o_issue_mem_size         = issue_out_mem_size;
  assign o_issue_mem_signed       = issue_out_mem_signed;
  assign o_issue_csr_addr         = issue_out_csr_addr;
  assign o_issue_csr_imm          = issue_out_csr_imm;
`else
  always_comb begin
    o_issue.valid            = issue_out_valid;
    o_issue.rob_tag          = issue_out_rob_tag;
    o_issue.op               = issue_out_op;
    o_issue.src1_value       = issue_out_src1_value;
    o_issue.src2_value       = issue_out_src2_value;
    o_issue.src3_value       = issue_out_src3_value;
    o_issue.imm              = issue_out_imm;
    o_issue.use_imm          = issue_out_use_imm;
    o_issue.rm               = issue_out_rm;
    o_issue.branch_target    = issue_out_branch_target;
    o_issue.predicted_taken  = issue_out_predicted_taken;
    o_issue.predicted_target = issue_out_predicted_target;
    o_issue.is_fp_mem        = issue_out_is_fp_mem;
    o_issue.mem_size         = issue_out_mem_size;
    o_issue.mem_signed       = issue_out_mem_signed;
    o_issue.csr_addr         = issue_out_csr_addr;
    o_issue.csr_imm          = issue_out_csr_imm;
  end
`endif

  // --- Status outputs ---
  assign o_full  = full;
  assign o_empty = empty;
  assign o_count = count;

  // ===========================================================================
  // Sequential Logic
  // ===========================================================================

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      // Reset: clear all valid bits
      rs_valid           <= '0;
      rs_src1_ready      <= '0;
      rs_src2_ready      <= '0;
      rs_src3_ready      <= '0;
      rs_use_imm         <= '0;
      rs_predicted_taken <= '0;
      rs_is_fp_mem       <= '0;
      rs_mem_signed      <= '0;
    end else begin

      // -----------------------------------------------------------------
      // Flush logic (highest priority for rs_valid)
      // -----------------------------------------------------------------
      if (i_flush_all) begin
        rs_valid <= '0;
      end else if (i_flush_en) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (rs_valid[i] && should_flush_entry(rs_rob_tag[i], i_flush_tag, i_rob_head_tag)) begin
            rs_valid[i] <= 1'b0;
          end
        end
      end else begin

        // -----------------------------------------------------------------
        // Issue: invalidate issued entry
        // -----------------------------------------------------------------
        if (issue_fire) begin
          rs_valid[issue_idx] <= 1'b0;
        end

        // -----------------------------------------------------------------
        // Dispatch: write new entry at free index
        // -----------------------------------------------------------------
        if (dispatch_fire) begin
          rs_valid[free_idx]   <= 1'b1;
          rs_rob_tag[free_idx] <= dispatch_rob_tag;
          rs_op[free_idx]      <= dispatch_op;

          // Source 1 -- CDB bypass: if CDB matches src1 tag, capture value
          if (!dispatch_src1_ready && i_cdb.valid && dispatch_src1_tag == i_cdb.tag) begin
            rs_src1_ready[free_idx] <= 1'b1;
            rs_src1_tag[free_idx]   <= dispatch_src1_tag;
            rs_src1_value[free_idx] <= i_cdb.value;
          end else begin
            rs_src1_ready[free_idx] <= dispatch_src1_ready;
            rs_src1_tag[free_idx]   <= dispatch_src1_tag;
            rs_src1_value[free_idx] <= dispatch_src1_value;
          end

          // Source 2 -- CDB bypass
          if (!dispatch_src2_ready && i_cdb.valid && dispatch_src2_tag == i_cdb.tag) begin
            rs_src2_ready[free_idx] <= 1'b1;
            rs_src2_tag[free_idx]   <= dispatch_src2_tag;
            rs_src2_value[free_idx] <= i_cdb.value;
          end else begin
            rs_src2_ready[free_idx] <= dispatch_src2_ready;
            rs_src2_tag[free_idx]   <= dispatch_src2_tag;
            rs_src2_value[free_idx] <= dispatch_src2_value;
          end

          // Source 3 -- CDB bypass
          if (!dispatch_src3_ready && i_cdb.valid && dispatch_src3_tag == i_cdb.tag) begin
            rs_src3_ready[free_idx] <= 1'b1;
            rs_src3_tag[free_idx]   <= dispatch_src3_tag;
            rs_src3_value[free_idx] <= i_cdb.value;
          end else begin
            rs_src3_ready[free_idx] <= dispatch_src3_ready;
            rs_src3_tag[free_idx]   <= dispatch_src3_tag;
            rs_src3_value[free_idx] <= dispatch_src3_value;
          end

          rs_imm[free_idx]              <= dispatch_imm;
          rs_use_imm[free_idx]          <= dispatch_use_imm;
          rs_rm[free_idx]               <= dispatch_rm;
          rs_branch_target[free_idx]    <= dispatch_branch_target;
          rs_predicted_taken[free_idx]  <= dispatch_predicted_taken;
          rs_predicted_target[free_idx] <= dispatch_predicted_target;
          rs_is_fp_mem[free_idx]        <= dispatch_is_fp_mem;
          rs_mem_size[free_idx]         <= dispatch_mem_size;
          rs_mem_signed[free_idx]       <= dispatch_mem_signed;
          rs_csr_addr[free_idx]         <= dispatch_csr_addr;
          rs_csr_imm[free_idx]          <= dispatch_csr_imm;
        end

      end  // !flush

      // -----------------------------------------------------------------
      // CDB snoop (wakeup): update pending sources across all entries.
      // Runs independently of flush/dispatch so surviving entries are
      // woken even when partial flush coincides with a CDB broadcast.
      // -----------------------------------------------------------------
      if (i_cdb.valid) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (rs_valid[i]) begin
            // Source 1 wakeup
            if (!rs_src1_ready[i] && rs_src1_tag[i] == i_cdb.tag) begin
              rs_src1_ready[i] <= 1'b1;
              rs_src1_value[i] <= i_cdb.value;
            end
            // Source 2 wakeup
            if (!rs_src2_ready[i] && rs_src2_tag[i] == i_cdb.tag) begin
              rs_src2_ready[i] <= 1'b1;
              rs_src2_value[i] <= i_cdb.value;
            end
            // Source 3 wakeup
            if (!rs_src3_ready[i] && rs_src3_tag[i] == i_cdb.tag) begin
              rs_src3_ready[i] <= 1'b1;
              rs_src3_value[i] <= i_cdb.value;
            end
          end
        end
      end

    end  // !reset
  end

  // ===========================================================================
  // Simulation Assertions
  // ===========================================================================
`ifndef SYNTHESIS
`ifndef FORMAL
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // Warn on unusual dispatch conditions (non-fatal: tests exercise these)
      if (dispatch_valid && full) $warning("RS: dispatch attempted when full");

      if (dispatch_valid && (i_flush_all || i_flush_en))
        $warning("RS: dispatch attempted during flush");

      // Issue fires only for ready entries (fatal: indicates RTL bug)
      if (issue_out_valid && !entry_ready[issue_idx])
        $error("RS: issue fired for non-ready entry %0d", issue_idx);
    end
  end
`endif
`endif

  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // Force reset to deassert after initial cycle
  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  // -------------------------------------------------------------------------
  // Assumptions
  // -------------------------------------------------------------------------

  // No dispatch during flush
  always_comb begin
    if (i_flush_all || i_flush_en) assume (!dispatch_valid);
  end

  // No dispatch when full
  always_comb begin
    if (full) assume (!dispatch_valid);
  end

  // -------------------------------------------------------------------------
  // Combinational assertions
  // -------------------------------------------------------------------------

  // full iff all valid
  always_comb begin
    if (i_rst_n) begin
      p_full_iff_all_valid : assert (full == (&rs_valid));
    end
  end

  // empty iff none valid
  always_comb begin
    if (i_rst_n) begin
      p_empty_iff_none_valid : assert (empty == (rs_valid == '0));
    end
  end

  // count matches popcount of valid bits
  // Note: Yosys does not support 'automatic' inside always_comb, so the
  // intermediate variable is declared outside the block.
  logic [CountWidth-1:0] f_expected_count;
  always_comb begin
    f_expected_count = '0;
    for (int i = 0; i < DEPTH; i++) begin
      f_expected_count = f_expected_count + {{(CountWidth - 1) {1'b0}}, rs_valid[i]};
    end
  end
  always_comb begin
    if (i_rst_n) begin
      p_count_matches_popcount : assert (count == f_expected_count);
    end
  end

  // Issue output valid implies the entry was valid and ready
  always_comb begin
    if (i_rst_n && issue_out_valid) begin
      p_issue_entry_was_valid : assert (rs_valid[issue_idx]);
      p_issue_entry_was_ready : assert (entry_ready[issue_idx]);
    end
  end

  // -------------------------------------------------------------------------
  // Sequential assertions
  // -------------------------------------------------------------------------

  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin

      // Dispatch sets valid
      if ($past(dispatch_fire)) begin
        p_dispatch_sets_valid : assert (rs_valid[$past(free_idx)]);
      end

      // Issue clears valid
      if ($past(issue_fire) && !$past(i_flush_all) && !$past(i_flush_en)) begin
        p_issue_clears_valid : assert (!rs_valid[$past(issue_idx)]);
      end

      // flush_all empties RS
      if ($past(i_flush_all)) begin
        p_flush_all_empties : assert (rs_valid == '0);
      end

      // CDB snoop sets ready bit when tag matches (all entries checked).
      // Labels omitted: Yosys rejects duplicate names from loop unrolling.
      for (int i = 0; i < DEPTH; i++) begin
        if ($past(
                i_cdb.valid
            ) && $past(
                rs_valid[i]
            ) && !$past(
                i_flush_all
            ) && !$past(
                i_flush_en
            )) begin
          if (!$past(rs_src1_ready[i]) && $past(rs_src1_tag[i]) == $past(i_cdb.tag))
            assert (rs_src1_ready[i]);
          if (!$past(rs_src2_ready[i]) && $past(rs_src2_tag[i]) == $past(i_cdb.tag))
            assert (rs_src2_ready[i]);
          if (!$past(rs_src3_ready[i]) && $past(rs_src3_tag[i]) == $past(i_cdb.tag))
            assert (rs_src3_ready[i]);
        end
      end

      // Partial flush only invalidates younger entries
      if ($past(i_flush_en) && !$past(i_flush_all)) begin
        for (int i = 0; i < DEPTH; i++) begin
          if ($past(
                  rs_valid[i]
              ) && !should_flush_entry(
                  $past(rs_rob_tag[i]), $past(i_flush_tag), $past(i_rob_head_tag)
              )) begin
            assert (rs_valid[i]);
          end
        end
      end

    end

    // Reset clears all entries
    if (f_past_valid && i_rst_n && !$past(i_rst_n)) begin
      p_reset_clears_all : assert (rs_valid == '0);
    end
  end

  // -------------------------------------------------------------------------
  // Cover properties
  // -------------------------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst_n) begin
      // Dispatch and issue in the same cycle
      cover_dispatch_and_issue : cover (dispatch_fire && issue_fire);

      // CDB wakeup makes entry ready
      cover_cdb_wakeup : cover (i_cdb.valid && |rs_valid);

      // RS is full
      cover_full : cover (full);

      // Partial flush
      cover_partial_flush : cover (i_flush_en && |rs_valid);

      // Entry dispatched with CDB bypass
      cover_cdb_bypass_at_dispatch :
      cover (dispatch_fire && i_cdb.valid && !dispatch_src1_ready
             && dispatch_src1_tag == i_cdb.tag);
    end
  end

`endif  // FORMAL

endmodule
