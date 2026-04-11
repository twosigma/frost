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
 *   - Dispatch pre-marks truly-unused src2 operands ready
 *   - Partial flush (age-based) and full flush support
 *
 * Storage Strategy:
 *   Hybrid FF + LUTRAM.  Control fields (valid, src_ready, src_tag,
 *   src_value, use_imm, rob_tag) remain in FFs because they need
 *   parallel CDB tag comparison, broadcast-write, and flush scan.
 *   Payload fields (op, imm, rm, branch/prediction/mem/csr/pc) live
 *   in a single-port distributed RAM (sdp_dist_ram): written once at
 *   dispatch, read once at issue.  Valid bits in FFs gate all reads,
 *   so stale LUTRAM data behind flushed entries is harmless.
 */

module reservation_station #(
    parameter int unsigned DEPTH = 8,
    parameter bit TRACK_INT_WRITEBACK_HINT = 1'b0,
    parameter bit BYPASS_STAGE2 = 1'b0
) (
    input logic i_clk,
    input logic i_rst_n,

    // =========================================================================
    // Dispatch Interface (from Dispatch Unit)
    // =========================================================================
    input riscv_pkg::rs_dispatch_t i_dispatch,
    output logic o_full,

    // =========================================================================
    // CDB Snoop / Wakeup
    // =========================================================================
    input riscv_pkg::cdb_broadcast_t i_cdb,

    // =========================================================================
    // Issue Interface (to Functional Unit)
    // =========================================================================
    output riscv_pkg::rs_issue_t o_issue,
    input  logic                 i_fu_ready,
    output logic                 o_issue_writes_cdb_hint,

    // =========================================================================
    // SC Issue Peek (combinational, independent of i_fu_ready)
    // =========================================================================
    output logic o_next_issue_is_sc,

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
  localparam int unsigned CheckpointIdWidth = riscv_pkg::CheckpointIdWidth;
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

  function automatic logic int_rs_writes_cdb(input riscv_pkg::instr_op_e op);
    begin
      case (op)
        riscv_pkg::BEQ,
        riscv_pkg::BNE,
        riscv_pkg::BLT,
        riscv_pkg::BGE,
        riscv_pkg::BLTU,
        riscv_pkg::BGEU:
        int_rs_writes_cdb = 1'b0;
        default: int_rs_writes_cdb = 1'b1;
      endcase
    end
  endfunction

  // ===========================================================================
  // Dispatch Field Extraction
  // ===========================================================================
  // Wire aliases allow the module body to use short names for struct fields.

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
  wire dispatch_mem_signed = i_dispatch.mem_signed;
  wire [11:0] dispatch_csr_addr = i_dispatch.csr_addr;
  wire [4:0] dispatch_csr_imm = i_dispatch.csr_imm;
  wire [XLEN-1:0] dispatch_pc = i_dispatch.pc;
  wire [XLEN-1:0] dispatch_link_addr = i_dispatch.link_addr;
  wire dispatch_has_checkpoint = i_dispatch.has_checkpoint;
  wire [CheckpointIdWidth-1:0] dispatch_checkpoint_id = i_dispatch.checkpoint_id;
  wire dispatch_is_call = i_dispatch.is_call;
  wire dispatch_is_return = i_dispatch.is_return;

  // ===========================================================================
  // Stage 2 Pipeline Register
  // ===========================================================================
  // Issue output is registered to break the combinational path from RS
  // entry arrays (priority encoder + LUTRAM read + operand mux) to
  // downstream consumers (FU shims, LQ/SQ address computation, CDB).
  // The stage2 register holds a full copy of the issued instruction's data,
  // presented to downstream with one-shot valid when i_fu_ready is asserted.

  logic stage2_valid;
  logic [ReorderBufferTagWidth-1:0] stage2_rob_tag;
  riscv_pkg::instr_op_e stage2_op;
  logic [FLEN-1:0] stage2_src1_value;
  logic [FLEN-1:0] stage2_src2_value;
  logic [FLEN-1:0] stage2_src3_value;
  logic [XLEN-1:0] stage2_imm;
  logic stage2_use_imm;
  logic stage2_writes_cdb_hint;
  logic [2:0] stage2_rm;
  logic [XLEN-1:0] stage2_branch_target;
  logic stage2_predicted_taken;
  logic [XLEN-1:0] stage2_predicted_target;
  logic stage2_is_fp_mem;
  riscv_pkg::mem_size_e stage2_mem_size;
  logic stage2_mem_signed;
  logic [11:0] stage2_csr_addr;
  logic [4:0] stage2_csr_imm;
  logic [XLEN-1:0] stage2_pc;
  logic [XLEN-1:0] stage2_link_addr;
  logic stage2_has_checkpoint;
  logic [CheckpointIdWidth-1:0] stage2_checkpoint_id;
  logic stage2_is_call;
  logic stage2_is_return;

  // CDB bypass flags: set when an issued instruction's source was woken by
  // same-cycle CDB bypass.  The output MUX substitutes stage2_cdb_value for
  // these sources, breaking the timing-critical data path from CDB through
  // the issue-select priority encoder to the stage2 register input.
  logic stage2_src1_bypassed;
  logic stage2_src2_bypassed;
  logic stage2_src3_bypassed;
  logic [FLEN-1:0] stage2_cdb_value;  // CDB value captured at issue time

  // Stage 2 control signals
  logic stage2_should_flush;  // Stage2 holds instruction younger than flush boundary
  logic stage2_accept;  // Stage2 content consumed by FU this cycle
  logic can_issue_to_stage2;  // Stage2 is empty or being consumed — RS may load it
  riscv_pkg::rs_issue_t bypass_issue;
  logic bypass_issue_writes_cdb_hint;
  logic bypass_next_issue_is_sc;

  // ===========================================================================
  // Storage -- FF-based control + LUTRAM-based payload
  // ===========================================================================
  //
  // Control fields (FFs): rs_valid, rs_src*_ready/tag/value, rs_use_imm,
  //   rs_rob_tag — need parallel CDB tag compare/write and flush scan.
  // Payload fields (LUTRAM): op, imm, rm, branch/prediction/mem/csr/pc —
  //   written once at dispatch, read once at issue (single port each).

  // 1-bit packed vectors (for bulk operations)
  logic [DEPTH-1:0] rs_valid;
  logic [DEPTH-1:0] rs_src1_ready;
  logic [DEPTH-1:0] rs_src2_ready;
  logic [DEPTH-1:0] rs_src3_ready;
  logic [DEPTH-1:0] rs_use_imm;
  logic [DEPTH-1:0] rs_writes_cdb_hint;

  // Multi-bit FF arrays (need parallel CDB snoop / flush compare)
  logic [ReorderBufferTagWidth-1:0] rs_rob_tag[DEPTH];

  logic [ReorderBufferTagWidth-1:0] rs_src1_tag[DEPTH];
  logic [FLEN-1:0] rs_src1_value[DEPTH];

  logic [ReorderBufferTagWidth-1:0] rs_src2_tag[DEPTH];
  logic [FLEN-1:0] rs_src2_value[DEPTH];

  logic [ReorderBufferTagWidth-1:0] rs_src3_tag[DEPTH];
  logic [FLEN-1:0] rs_src3_value[DEPTH];

  // ===========================================================================
  // Internal Signals
  // ===========================================================================

  logic full;
  logic empty;
  logic [CountWidth-1:0] count;

  // Free entry selection
  logic [$clog2(DEPTH)-1:0] free_idx;
  logic free_found;

  // Issue selection
  logic [DEPTH-1:0] entry_ready;
  logic [$clog2(DEPTH)-1:0] issue_idx;
  logic any_ready;
  logic issue_fire;

  // Dispatch condition
  (* max_fanout = 32 *) logic dispatch_fire;

  // ===========================================================================
  // Payload LUTRAM — dispatch-only fields, read at issue
  // ===========================================================================
  // Written exactly once (at dispatch into free_idx) and read exactly once
  // (at issue from issue_idx).  No parallel access needed, so they live in
  // distributed RAM rather than flip-flops.  Valid bits in FFs gate all reads;
  // stale payload data behind an invalid entry is harmless.

  localparam int unsigned PayloadWidth =
      32 + XLEN + 3 + XLEN + 1 + XLEN + 1 + 2 + 1 + 12 + 5 + XLEN + XLEN +
      1 + CheckpointIdWidth + 1 + 1;

  logic [PayloadWidth-1:0] payload_wr_data;
  logic [PayloadWidth-1:0] payload_rd_data;

  assign payload_wr_data = {
    32'(dispatch_op),  // 32  op
    dispatch_imm,  // 32  imm
    dispatch_rm,  //  3  rm
    dispatch_branch_target,  // 32  branch_target
    dispatch_predicted_taken,  //  1  predicted_taken
    dispatch_predicted_target,  // 32  predicted_target
    dispatch_is_fp_mem,  //  1  is_fp_mem
    2'(dispatch_mem_size),  //  2  mem_size
    dispatch_mem_signed,  //  1  mem_signed
    dispatch_csr_addr,  // 12  csr_addr
    dispatch_csr_imm,  //  5  csr_imm
    dispatch_pc,  // 32  pc
    dispatch_link_addr,  // 32  link_addr
    dispatch_has_checkpoint,  //  1  has_checkpoint
    dispatch_checkpoint_id,  //  CheckpointIdWidth  checkpoint_id
    dispatch_is_call,  //  1  is_call
    dispatch_is_return  //  1  is_return
  };

  sdp_dist_ram #(
      .ADDR_WIDTH($clog2(DEPTH)),
      .DATA_WIDTH(PayloadWidth)
  ) u_payload_ram (
      .i_clk,
      .i_write_enable (dispatch_fire),
      .i_write_address(free_idx),
      .i_read_address (issue_idx),
      .i_write_data   (payload_wr_data),
      .o_read_data    (payload_rd_data)
  );

  // Unpack LUTRAM read data (at issue_idx, combinational / zero-latency)
  logic [                 31:0] pl_op_bits;
  logic [             XLEN-1:0] pl_imm;
  logic [                  2:0] pl_rm;
  logic [             XLEN-1:0] pl_branch_target;
  logic                         pl_predicted_taken;
  logic [             XLEN-1:0] pl_predicted_target;
  logic                         pl_is_fp_mem;
  logic [                  1:0] pl_mem_size_bits;
  logic                         pl_mem_signed;
  logic [                 11:0] pl_csr_addr;
  logic [                  4:0] pl_csr_imm;
  logic [             XLEN-1:0] pl_pc;
  logic [             XLEN-1:0] pl_link_addr;
  logic                         pl_has_checkpoint;
  logic [CheckpointIdWidth-1:0] pl_checkpoint_id;
  logic                         pl_is_call;
  logic                         pl_is_return;

  assign {pl_op_bits, pl_imm, pl_rm, pl_branch_target, pl_predicted_taken,
          pl_predicted_target, pl_is_fp_mem, pl_mem_size_bits, pl_mem_signed,
          pl_csr_addr, pl_csr_imm, pl_pc, pl_link_addr,
          pl_has_checkpoint, pl_checkpoint_id, pl_is_call, pl_is_return} = payload_rd_data;

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

  // --- CDB bypass wakeup per entry ---
  // Same-cycle CDB tag match: if the CDB is broadcasting a result this cycle
  // and an entry's pending source tag matches, treat that source as ready
  // immediately (combinationally) rather than waiting for the next clock edge.
  // This reduces dependent chain latency by 1 cycle.
  logic [DEPTH-1:0] src1_cdb_bypass;
  logic [DEPTH-1:0] src2_cdb_bypass;
  logic [DEPTH-1:0] src3_cdb_bypass;

  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      src1_cdb_bypass[i] = i_cdb.valid && !rs_src1_ready[i] && rs_src1_tag[i] == i_cdb.tag;
      src2_cdb_bypass[i] = i_cdb.valid && !rs_src2_ready[i] && rs_src2_tag[i] == i_cdb.tag;
      src3_cdb_bypass[i] = i_cdb.valid && !rs_src3_ready[i] && rs_src3_tag[i] == i_cdb.tag;
    end
  end

  // --- Ready check per entry ---
  always_comb begin
    for (int i = 0; i < DEPTH; i++) begin
      entry_ready[i] = rs_valid[i] && (rs_src1_ready[i] || src1_cdb_bypass[i])
      // Even when an instruction uses an immediate, issue still
      // requires src2 to be ready if the opcode actually has a
      // second source (for example stores: base+imm address and
      // rs2 store data). Dispatch marks truly-unused src2
      // operands ready, so a plain src2_ready check is correct.
      && (rs_src2_ready[i] || src2_cdb_bypass[i]) && (rs_src3_ready[i] || src3_cdb_bypass[i]);
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

  // --- Stage 2 control ---
  // Flush squash: stage2 holds an instruction younger than the flush boundary.
  assign stage2_should_flush = !BYPASS_STAGE2 && stage2_valid && (i_flush_all ||
      (i_flush_en && should_flush_entry(
      stage2_rob_tag, i_flush_tag, i_rob_head_tag
  )));

  // Stage2 content consumed by downstream FU this cycle (one-shot pulse).
  assign stage2_accept = !BYPASS_STAGE2 && stage2_valid && i_fu_ready && !stage2_should_flush;

  // RS may load stage2 when it is empty or being consumed this cycle.
  assign can_issue_to_stage2 = !stage2_valid || stage2_accept;

  // Issue from RS entry arrays into stage2. i_fu_ready is retained so that
  // entries only move to stage2 when the FU can accept — preserving the same
  // count/full/empty semantics as the old combinational design. The timing
  // benefit comes from registering the DATA path in stage2, not from decoupling
  // the control path.
  // A partial/full flush invalidates younger entries on the clock edge, but the
  // ready scan above still sees pre-flush state combinationally in the same
  // cycle. Suppress issue so wrong-path ops cannot leak into stage2 during the
  // misprediction/trap flush cycle.
  assign issue_fire = any_ready && i_fu_ready &&
                      (BYPASS_STAGE2 || can_issue_to_stage2) &&
                      !i_flush_all && !i_flush_en;

  always_comb begin
    bypass_issue                 = '0;
    bypass_issue_writes_cdb_hint = 1'b0;
    if (BYPASS_STAGE2) begin
      bypass_issue.valid = any_ready && i_fu_ready && !i_flush_all && !i_flush_en;
      bypass_issue.rob_tag = rs_rob_tag[issue_idx];
      bypass_issue.op = riscv_pkg::instr_op_e'(pl_op_bits);
      bypass_issue.src1_value = src1_cdb_bypass[issue_idx] ? i_cdb.value : rs_src1_value[issue_idx];
      bypass_issue.src2_value = src2_cdb_bypass[issue_idx] ? i_cdb.value : rs_src2_value[issue_idx];
      bypass_issue.src3_value = src3_cdb_bypass[issue_idx] ? i_cdb.value : rs_src3_value[issue_idx];
      bypass_issue.imm = pl_imm;
      bypass_issue.use_imm = rs_use_imm[issue_idx];
      bypass_issue.rm = pl_rm;
      bypass_issue.branch_target = pl_branch_target;
      bypass_issue.predicted_taken = pl_predicted_taken;
      bypass_issue.predicted_target = pl_predicted_target;
      bypass_issue.is_fp_mem = pl_is_fp_mem;
      bypass_issue.mem_size = riscv_pkg::mem_size_e'(pl_mem_size_bits);
      bypass_issue.mem_signed = pl_mem_signed;
      bypass_issue.csr_addr = pl_csr_addr;
      bypass_issue.csr_imm = pl_csr_imm;
      bypass_issue.pc = pl_pc;
      bypass_issue.link_addr = pl_link_addr;
      bypass_issue.has_checkpoint = pl_has_checkpoint;
      bypass_issue.checkpoint_id = pl_checkpoint_id;
      bypass_issue.is_call = pl_is_call;
      bypass_issue.is_return = pl_is_return;
      bypass_issue_writes_cdb_hint  = TRACK_INT_WRITEBACK_HINT ?
                                      rs_writes_cdb_hint[issue_idx] : 1'b0;
    end
  end

  // --- SC issue peek ---
  // The generic RS reads this from stage2. MEM_RS can opt into the direct
  // issue path and peek the ready entry combinationally instead.
  assign bypass_next_issue_is_sc = BYPASS_STAGE2 && any_ready &&
                                   (riscv_pkg::instr_op_e'(pl_op_bits) == riscv_pkg::SC_W);
  assign o_next_issue_is_sc = BYPASS_STAGE2 ? bypass_next_issue_is_sc
                                            : (stage2_valid && (stage2_op == riscv_pkg::SC_W));

  // --- Issue port assignment (driven from stage2 pipeline register) ---
  // Data fields are driven unconditionally from stage2 FFs.
  // Valid depends only on registered stage2_valid and the FU ready signal
  // (itself derived from registered adapter/shim state).  The same-cycle
  // flush is intentionally NOT checked here: removing stage2_should_flush
  // from the output breaks the critical timing path
  //   trap_taken → flush → stage2_should_flush → o_issue.valid → downstream
  // which was the longest combinational chain in the design (-1.28 ns WNS).
  // A "phantom issue" can escape during a flush cycle, but it is harmless:
  //   - Full flush (flush_all): LQ/SQ reset all state, ignoring the update.
  //   - Partial flush (flush_en): LQ/SQ CAM-match on rob_tag; the flushed
  //     entry's valid bit is cleared on the same edge, so the address update
  //     writes into a dead entry that is never observed.
  //   - CDB results for flushed tags are discarded by the ROB/RS flush logic.
  // The internal stage2_accept signal still checks stage2_should_flush so
  // that the stage2 pipeline register is correctly cleared on the next edge.
  assign o_issue.valid = BYPASS_STAGE2 ? bypass_issue.valid : (stage2_valid && i_fu_ready);
  assign o_issue.rob_tag = BYPASS_STAGE2 ? bypass_issue.rob_tag : stage2_rob_tag;
  assign o_issue.op = BYPASS_STAGE2 ? bypass_issue.op : stage2_op;
  // For CDB-bypassed sources, substitute the CDB value captured at issue
  // time.  All inputs are registered, so this MUX is off the critical path.
  assign o_issue.src1_value = BYPASS_STAGE2 ? bypass_issue.src1_value
                              : (stage2_src1_bypassed ? stage2_cdb_value : stage2_src1_value);
  assign o_issue.src2_value = BYPASS_STAGE2 ? bypass_issue.src2_value
                              : (stage2_src2_bypassed ? stage2_cdb_value : stage2_src2_value);
  assign o_issue.src3_value = BYPASS_STAGE2 ? bypass_issue.src3_value
                              : (stage2_src3_bypassed ? stage2_cdb_value : stage2_src3_value);
  assign o_issue.imm = BYPASS_STAGE2 ? bypass_issue.imm : stage2_imm;
  assign o_issue.use_imm = BYPASS_STAGE2 ? bypass_issue.use_imm : stage2_use_imm;
  assign o_issue.rm = BYPASS_STAGE2 ? bypass_issue.rm : stage2_rm;
  assign o_issue.branch_target = BYPASS_STAGE2 ? bypass_issue.branch_target : stage2_branch_target;
  assign o_issue.predicted_taken = BYPASS_STAGE2 ? bypass_issue.predicted_taken :
                                                   stage2_predicted_taken;
  assign o_issue.predicted_target = BYPASS_STAGE2 ? bypass_issue.predicted_target :
                                                    stage2_predicted_target;
  assign o_issue.is_fp_mem = BYPASS_STAGE2 ? bypass_issue.is_fp_mem : stage2_is_fp_mem;
  assign o_issue.mem_size = BYPASS_STAGE2 ? bypass_issue.mem_size : stage2_mem_size;
  assign o_issue.mem_signed = BYPASS_STAGE2 ? bypass_issue.mem_signed : stage2_mem_signed;
  assign o_issue.csr_addr = BYPASS_STAGE2 ? bypass_issue.csr_addr : stage2_csr_addr;
  assign o_issue.csr_imm = BYPASS_STAGE2 ? bypass_issue.csr_imm : stage2_csr_imm;
  assign o_issue.pc = BYPASS_STAGE2 ? bypass_issue.pc : stage2_pc;
  assign o_issue.link_addr = BYPASS_STAGE2 ? bypass_issue.link_addr : stage2_link_addr;
  assign o_issue.has_checkpoint = BYPASS_STAGE2 ? bypass_issue.has_checkpoint :
                                                  stage2_has_checkpoint;
  assign o_issue.checkpoint_id = BYPASS_STAGE2 ? bypass_issue.checkpoint_id : stage2_checkpoint_id;
  assign o_issue.is_call = BYPASS_STAGE2 ? bypass_issue.is_call : stage2_is_call;
  assign o_issue.is_return = BYPASS_STAGE2 ? bypass_issue.is_return : stage2_is_return;

  assign o_issue_writes_cdb_hint = BYPASS_STAGE2 ? bypass_issue_writes_cdb_hint
                                                 : stage2_writes_cdb_hint;

  // --- Status outputs ---
  assign o_full = full;
  assign o_empty = empty;
  assign o_count = count;

  // ===========================================================================
  // Sequential Logic
  // ===========================================================================

  // --- Control signals (with reset) ---
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      rs_valid           <= '0;
      rs_src1_ready      <= '0;
      rs_src2_ready      <= '0;
      rs_src3_ready      <= '0;
      rs_use_imm         <= '0;
      rs_writes_cdb_hint <= '0;
    end else begin

      // Flush logic (highest priority for rs_valid)
      if (i_flush_all) begin
        rs_valid <= '0;
      end else if (i_flush_en) begin
        // Partial flush: invalidate entries younger than flush_tag.
        // The old head==flush_tag+1 full-clear is now handled by
        // speculative_flush_all (passed as i_flush_all) from the wrapper.
        for (int i = 0; i < DEPTH; i++) begin
          if (rs_valid[i] && should_flush_entry(rs_rob_tag[i], i_flush_tag, i_rob_head_tag)) begin
            rs_valid[i] <= 1'b0;
          end
        end
      end else begin
        if (issue_fire) rs_valid[issue_idx] <= 1'b0;

        if (dispatch_fire) begin
          rs_valid[free_idx] <= 1'b1;
          if (TRACK_INT_WRITEBACK_HINT)
            rs_writes_cdb_hint[free_idx] <= int_rs_writes_cdb(dispatch_op);

          // Source ready bits (dispatch + CDB bypass)
          rs_src1_ready[free_idx] <= dispatch_src1_ready ||
              (!dispatch_src1_ready && i_cdb.valid && dispatch_src1_tag == i_cdb.tag);
          rs_src2_ready[free_idx] <= dispatch_src2_ready ||
              (!dispatch_src2_ready && i_cdb.valid && dispatch_src2_tag == i_cdb.tag);
          rs_src3_ready[free_idx] <= dispatch_src3_ready ||
              (!dispatch_src3_ready && i_cdb.valid && dispatch_src3_tag == i_cdb.tag);
          rs_use_imm[free_idx] <= dispatch_use_imm;
        end
      end

      // CDB snoop wakeup (control: ready bits only)
      if (i_cdb.valid) begin
        for (int i = 0; i < DEPTH; i++) begin
          if (rs_valid[i]) begin
            if (!rs_src1_ready[i] && rs_src1_tag[i] == i_cdb.tag) rs_src1_ready[i] <= 1'b1;
            if (!rs_src2_ready[i] && rs_src2_tag[i] == i_cdb.tag) rs_src2_ready[i] <= 1'b1;
            if (!rs_src3_ready[i] && rs_src3_tag[i] == i_cdb.tag) rs_src3_ready[i] <= 1'b1;
          end
        end
      end

    end
  end

  // --- Data signals (no reset) ---
  always_ff @(posedge i_clk) begin
    // Dispatch: capture tags and values at free index
    if (dispatch_fire) begin
      rs_rob_tag[free_idx]  <= dispatch_rob_tag;

      // Source 1 (CDB bypass or dispatch value)
      rs_src1_tag[free_idx] <= dispatch_src1_tag;
      if (!dispatch_src1_ready && i_cdb.valid && dispatch_src1_tag == i_cdb.tag)
        rs_src1_value[free_idx] <= i_cdb.value;
      else rs_src1_value[free_idx] <= dispatch_src1_value;

      // Source 2
      rs_src2_tag[free_idx] <= dispatch_src2_tag;
      if (!dispatch_src2_ready && i_cdb.valid && dispatch_src2_tag == i_cdb.tag)
        rs_src2_value[free_idx] <= i_cdb.value;
      else rs_src2_value[free_idx] <= dispatch_src2_value;

      // Source 3
      rs_src3_tag[free_idx] <= dispatch_src3_tag;
      if (!dispatch_src3_ready && i_cdb.valid && dispatch_src3_tag == i_cdb.tag)
        rs_src3_value[free_idx] <= i_cdb.value;
      else rs_src3_value[free_idx] <= dispatch_src3_value;
    end

    // CDB snoop wakeup (data: capture values)
    if (i_cdb.valid) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (rs_valid[i]) begin
          if (!rs_src1_ready[i] && rs_src1_tag[i] == i_cdb.tag) rs_src1_value[i] <= i_cdb.value;
          if (!rs_src2_ready[i] && rs_src2_tag[i] == i_cdb.tag) rs_src2_value[i] <= i_cdb.value;
          if (!rs_src3_ready[i] && rs_src3_tag[i] == i_cdb.tag) rs_src3_value[i] <= i_cdb.value;
        end
      end
    end
  end

  // ===========================================================================
  // Stage 2 Pipeline Register — Sequential Logic
  // ===========================================================================
  // Captures the issued instruction's data on issue_fire and holds it until
  // consumed by the downstream FU (stage2_accept) or flushed.

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      stage2_valid <= 1'b0;
    end else if (BYPASS_STAGE2) begin
      stage2_valid <= 1'b0;
    end else if (stage2_should_flush) begin
      // Flush squash: clear stage2. No refill is possible here because
      // issue_fire is suppressed during flush (!i_flush_all && !i_flush_en).
      stage2_valid <= 1'b0;
    end else if (issue_fire) begin
      // Load stage2 from the RS entry selected by the priority encoder.
      // This covers both the empty-fill and back-to-back (accept + refill) cases.
      // For CDB-bypassed sources, store the stale rs_src_value here and set the
      // bypass flag; the output MUX substitutes cdb_value_q.  This breaks the
      // timing-critical path CDB → tag match → issue select → FLEN MUX → stage2.
      stage2_valid <= 1'b1;
      stage2_rob_tag <= rs_rob_tag[issue_idx];
      stage2_op <= riscv_pkg::instr_op_e'(pl_op_bits);
      stage2_src1_value <= rs_src1_value[issue_idx];
      stage2_src2_value <= rs_src2_value[issue_idx];
      stage2_src3_value <= rs_src3_value[issue_idx];
      stage2_src1_bypassed <= src1_cdb_bypass[issue_idx];
      stage2_src2_bypassed <= src2_cdb_bypass[issue_idx];
      stage2_src3_bypassed <= src3_cdb_bypass[issue_idx];
      stage2_cdb_value <= i_cdb.value;
      stage2_imm <= pl_imm;
      stage2_use_imm <= rs_use_imm[issue_idx];
      stage2_writes_cdb_hint <= TRACK_INT_WRITEBACK_HINT ? rs_writes_cdb_hint[issue_idx] : 1'b0;
      stage2_rm <= pl_rm;
      stage2_branch_target <= pl_branch_target;
      stage2_predicted_taken <= pl_predicted_taken;
      stage2_predicted_target <= pl_predicted_target;
      stage2_is_fp_mem <= pl_is_fp_mem;
      stage2_mem_size <= riscv_pkg::mem_size_e'(pl_mem_size_bits);
      stage2_mem_signed <= pl_mem_signed;
      stage2_csr_addr <= pl_csr_addr;
      stage2_csr_imm <= pl_csr_imm;
      stage2_pc <= pl_pc;
      stage2_link_addr <= pl_link_addr;
      stage2_has_checkpoint <= pl_has_checkpoint;
      stage2_checkpoint_id <= pl_checkpoint_id;
      stage2_is_call <= pl_is_call;
      stage2_is_return <= pl_is_return;
    end else if (stage2_accept) begin
      // Consumed by FU, no new entry ready — go empty.
      stage2_valid <= 1'b0;
    end
    // else: stage2_valid && !stage2_accept && !stage2_should_flush — hold (blocked)
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
      // Checks stage1 issue_fire (RS→stage2), not stage2 output.
      if (issue_fire && !entry_ready[issue_idx])
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

  // Stage1 issue_fire implies the selected entry was valid and ready
  always_comb begin
    if (i_rst_n && issue_fire) begin
      p_issue_entry_was_valid : assert (rs_valid[issue_idx]);
      p_issue_entry_was_ready : assert (entry_ready[issue_idx]);
    end
  end

  // Stage2 output valid implies stage2 is occupied
  always_comb begin
    if (i_rst_n && o_issue.valid && !BYPASS_STAGE2) begin
      p_stage2_output_coherent : assert (stage2_valid);
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

      // flush_all empties RS and stage2
      if ($past(i_flush_all)) begin
        p_flush_all_empties : assert (rs_valid == '0);
        p_flush_all_empties_stage2 : assert (!stage2_valid);
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

      // Stage2 back-to-back: consumed and refilled in the same cycle
      if (!BYPASS_STAGE2) cover_stage2_back_to_back : cover (stage2_accept && issue_fire);

      // Stage2 flush squash
      if (!BYPASS_STAGE2) cover_stage2_flush : cover (stage2_should_flush);

      // Stage2 blocked (FU not ready)
      if (!BYPASS_STAGE2)
        cover_stage2_blocked : cover (stage2_valid && !i_fu_ready && !stage2_should_flush);
    end
  end

`endif  // FORMAL

endmodule
