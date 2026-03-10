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
 * FROST OOO CPU Core - Tomasulo Out-of-Order RISC-V Processor (RV32IMACBFD)
 *
 * Replaces the in-order EX/MA/WB stages with Tomasulo-based out-of-order
 * execution. Preserves the existing IF/PD/ID front-end.
 *
 * Pipeline structure:
 *   IF → PD → ID → DISPATCH → [OOO execution via Tomasulo] → COMMIT
 *
 * Key changes from in-order cpu.sv:
 *   - REMOVED: EX/MA/WB stages, forwarding_unit, fp_forwarding_unit,
 *              hazard_resolution_unit (in-order versions)
 *   - ADDED: dispatch module, tomasulo_wrapper (ROB+RAT+RS+CDB+LQ+SQ+FU shims)
 *   - CHANGED: Regfile writes come from ROB commit, not WB stage
 *   - CHANGED: CSR writes happen at ROB commit (serialized)
 *   - CHANGED: Branch/BTB/RAS updates come from ROB commit, not EX stage
 *   - CHANGED: Pipeline stalls come from dispatch back-pressure
 */

module cpu_ooo #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned MEM_BYTE_ADDR_WIDTH = 16,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000,
    parameter int unsigned MMIO_SIZE_BYTES = 32'h28
) (
    input logic i_clk,
    input logic i_rst,
    // Instruction memory interface
    output logic [XLEN-1:0] o_pc,
    input logic [31:0] i_instr,
    // Data memory interface
    input logic [XLEN-1:0] i_data_mem_rd_data,
    output logic [XLEN-1:0] o_data_mem_addr,
    output logic [XLEN-1:0] o_data_mem_wr_data,
    output logic [3:0] o_data_mem_per_byte_wr_en,
    output logic o_data_mem_read_enable,
    output logic o_mmio_read_pulse,
    output logic [XLEN-1:0] o_mmio_load_addr,
    output logic o_mmio_load_valid,
    // Status
    output logic o_rst_done,
    output logic o_vld,
    output logic o_pc_vld,
    // Interrupts
    input riscv_pkg::interrupt_t i_interrupts,
    input logic [63:0] i_mtime,
    // Debug
    input logic i_disable_branch_prediction
);

  import riscv_pkg::*;

  // Active-low reset for Tomasulo modules
  logic rst_n;
  assign rst_n = ~i_rst;

  // ===========================================================================
  // Pipeline Control
  // ===========================================================================
  // Simplified pipeline control for OOO: only stall/flush from dispatch
  // and commit-time events (traps, mispredictions).

  pipeline_ctrl_t pipeline_ctrl;
  logic dispatch_stall;
  logic flush_pipeline;
  logic flush_for_trap;
  logic flush_for_mret;

  // CSR dispatch fence: the CDB carries rs1 (write operand) for CSR ops,
  // not the CSR read result (which is only available at commit). Stall
  // dispatch after a CSR until it commits so no dependent instruction
  // picks up the wrong CDB value.
  logic csr_in_flight;
  logic branch_in_flight;
  localparam int unsigned BranchInFlightCountWidth = $clog2(riscv_pkg::ReorderBufferDepth + 1);
  logic [BranchInFlightCountWidth-1:0] branch_in_flight_count;
  logic front_end_control_flow_pending;
  logic disable_branch_prediction_ooo;
  logic serializing_alloc_fire;
  logic csr_commit_fire;  // forward declaration; driven below in CSR section
  logic branch_alloc_fire;
  logic branch_commit_fire;

  // CSR results are only architecturally available at commit, so hold the
  // front-end after dispatching a CSR until it completes.
  assign serializing_alloc_fire = rob_alloc_req.alloc_valid && rob_alloc_req.is_csr;
  assign branch_alloc_fire = rob_alloc_req.alloc_valid && rob_alloc_req.is_branch;
  assign branch_commit_fire = rob_commit.valid && rob_commit.has_checkpoint;

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) csr_in_flight <= 1'b0;
    else if (csr_commit_fire) csr_in_flight <= 1'b0;
    else if (rob_alloc_req.alloc_valid && rob_alloc_req.is_csr) csr_in_flight <= 1'b1;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) begin
      branch_in_flight_count <= '0;
    end else begin
      case ({
        branch_alloc_fire, branch_commit_fire
      })
        2'b10:   branch_in_flight_count <= branch_in_flight_count + 1'b1;
        2'b01:   branch_in_flight_count <= branch_in_flight_count - 1'b1;
        default: branch_in_flight_count <= branch_in_flight_count;
      endcase
    end
  end

  assign branch_in_flight = (branch_in_flight_count != '0);

  // The existing in-order front-end prediction machinery is not robust to a
  // younger predicted redirect arriving behind an older unresolved branch/jump.
  // In OOO mode, keep fetch flowing but suppress new predictions until the
  // oldest in-flight or front-end-pending control-flow op commits. Waiting
  // until ROB allocation is too late: a younger BTB hit can still redirect
  // fetch while an older branch is sitting in PD/ID, which is exactly how the
  // memcpy ladder was skipping `0x33b8` after `0x33b6`.
  assign disable_branch_prediction_ooo = i_disable_branch_prediction ||
                                         front_end_control_flow_pending ||
                                         branch_in_flight ||
                                         csr_in_flight ||
                                         serializing_alloc_fire;

  // Registered stall for IF stage stall-capture registers.
  // The IF stage saves combinational outputs (BRAM data, is_compressed, etc.)
  // on the rising edge of stall and restores them via stall_registered.
  logic stall_q;
  logic replay_after_dispatch_stall_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) stall_q <= 1'b0;
    else stall_q <= (dispatch_stall || csr_in_flight || serializing_alloc_fire) && !flush_pipeline;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) replay_after_dispatch_stall_q <= 1'b0;
    else replay_after_dispatch_stall_q <= dispatch_stall && !flush_pipeline;
  end

  // Post-flush holdoff: BRAM has 1-cycle read latency, so i_instr is stale
  // for one cycle after a flush/redirect. Suppress the valid tracker during
  // this cycle to prevent stale instructions from being dispatched.
  logic [1:0] post_flush_holdoff_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) post_flush_holdoff_q <= '0;
    else if (!pipeline_ctrl.stall)
      if (flush_pipeline)
        // One cycle is sufficient here: PD/ID are explicitly flushed in the
        // redirect cycle, and the next cycle is the only stale BRAM return.
        // Holding longer drops real target instructions after control-flow
        // redirects, especially at compressed function entries.
        post_flush_holdoff_q <= 2'd1;
      else if (post_flush_holdoff_q != 2'd0) post_flush_holdoff_q <= post_flush_holdoff_q - 2'd1;
  end

  // Registered trap/mret for IF stage flush_for_c_ext_safe timing optimization.
  logic trap_taken_reg, mret_taken_reg;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      trap_taken_reg <= 1'b0;
      mret_taken_reg <= 1'b0;
    end else begin
      trap_taken_reg <= trap_taken;
      mret_taken_reg <= mret_taken;
    end
  end

  // Front-end stall: dispatch back-pressure or CSR serialization
  // Front-end flush: misprediction or trap at commit
  always_comb begin
    pipeline_ctrl = '0;
    pipeline_ctrl.reset = i_rst;
    pipeline_ctrl.stall = (dispatch_stall || csr_in_flight || serializing_alloc_fire) &&
                          !flush_pipeline;
    pipeline_ctrl.stall_registered = stall_q;
    // Only true execution/backpressure stalls belong in stall_for_trap_check.
    // Front-end CSR serialization fences must not suppress IF-stage
    // control-flow cleanup on redirects, or stale C-extension state can
    // survive a branch/return flush.
    pipeline_ctrl.stall_for_trap_check = dispatch_stall;
    pipeline_ctrl.flush = flush_pipeline;
    pipeline_ctrl.trap_taken_registered = trap_taken_reg;
    pipeline_ctrl.mret_taken_registered = mret_taken_reg;
  end

  // ===========================================================================
  // Inter-stage signals
  // ===========================================================================
  from_if_to_pd_t from_if_to_pd;
  from_pd_to_id_t from_pd_to_id;
  from_id_to_ex_t from_id_to_ex;

  // Synthesized from_ex_comb for IF stage (branch redirect, BTB update, RAS restore)
  from_ex_comb_t from_ex_comb_synth;

  // Trap control
  trap_ctrl_t trap_ctrl;
  logic trap_taken, mret_taken;
  logic [XLEN-1:0] trap_target;

  assign trap_ctrl.trap_taken  = trap_taken;
  assign trap_ctrl.mret_taken  = mret_taken;
  assign trap_ctrl.trap_target = trap_target;

  // ===========================================================================
  // Stage 1: Instruction Fetch (IF) — UNCHANGED
  // ===========================================================================

  if_stage #(
      .XLEN(XLEN)
  ) if_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_instr,
      .i_from_ex_comb(from_ex_comb_synth),
      .i_trap_ctrl(trap_ctrl),
      .i_disable_branch_prediction(disable_branch_prediction_ooo),
      .o_pc,
      .o_from_if_to_pd(from_if_to_pd)
  );

  // ===========================================================================
  // Stage 2: Pre-Decode (PD) — UNCHANGED
  // ===========================================================================

  pd_stage #(
      .XLEN(XLEN)
  ) pd_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_if_to_pd(from_if_to_pd),
      .o_from_pd_to_id(from_pd_to_id)
  );

  // ===========================================================================
  // Register Files (read in ID, write from ROB commit)
  // ===========================================================================

  // Integer register file
  logic           [4*XLEN-1:0] int_rf_read_data;
  logic                        int_rf_write_enable;
  logic           [       4:0] int_rf_write_addr;
  logic           [  XLEN-1:0] int_rf_write_data;
  logic                        int_rf_wb_bypass_id_rs1;
  logic                        int_rf_wb_bypass_id_rs2;
  logic                        int_rf_wb_bypass_dispatch_rs1;
  logic                        int_rf_wb_bypass_dispatch_rs2;
  logic           [  XLEN-1:0] int_rf_dispatch_rs1_data;
  logic           [  XLEN-1:0] int_rf_dispatch_rs2_data;

  rf_to_fwd_t                  rf_to_fwd;
  from_ma_to_wb_t              from_ma_to_wb_commit;

  generic_regfile #(
      .DATA_WIDTH(XLEN),
      .NUM_READ_PORTS(4),
      .HARDWIRE_ZERO(1)
  ) regfile_inst (
      .i_clk,
      .i_write_enable(int_rf_write_enable),
      .i_write_addr(int_rf_write_addr),
      .i_write_data(int_rf_write_data),
      .i_stall(1'b0),  // OOO: commit writes must not be blocked by front-end stall
      .i_read_addr({
        from_id_to_ex.instruction.source_reg_2,
        from_id_to_ex.instruction.source_reg_1,
        from_pd_to_id.source_reg_2_early,
        from_pd_to_id.source_reg_1_early
      }),
      .o_read_data(int_rf_read_data)
  );

  assign int_rf_wb_bypass_id_rs1 = int_rf_write_enable &&
                                   |int_rf_write_addr &&
                                   (int_rf_write_addr == from_pd_to_id.source_reg_1_early);
  assign int_rf_wb_bypass_id_rs2 = int_rf_write_enable &&
                                   |int_rf_write_addr &&
                                   (int_rf_write_addr == from_pd_to_id.source_reg_2_early);
  assign int_rf_wb_bypass_dispatch_rs1 = int_rf_write_enable &&
                                         |int_rf_write_addr &&
                                         (int_rf_write_addr ==
                                          from_id_to_ex.instruction.source_reg_1);
  assign int_rf_wb_bypass_dispatch_rs2 = int_rf_write_enable &&
                                         |int_rf_write_addr &&
                                         (int_rf_write_addr ==
                                          from_id_to_ex.instruction.source_reg_2);

  assign rf_to_fwd.source_reg_1_data = int_rf_wb_bypass_id_rs1 ? int_rf_write_data :
                                       int_rf_read_data[XLEN-1:0];
  assign rf_to_fwd.source_reg_2_data = int_rf_wb_bypass_id_rs2 ? int_rf_write_data :
                                       int_rf_read_data[2*XLEN-1:XLEN];
  assign int_rf_dispatch_rs1_data = int_rf_wb_bypass_dispatch_rs1 ? int_rf_write_data :
                                    int_rf_read_data[3*XLEN-1:2*XLEN];
  assign int_rf_dispatch_rs2_data = int_rf_wb_bypass_dispatch_rs2 ? int_rf_write_data :
                                    int_rf_read_data[4*XLEN-1:3*XLEN];

  // FP register file
  localparam int unsigned FpW = riscv_pkg::FpWidth;
  logic          [6*FpW-1:0] fp_rf_read_data;
  logic                      fp_rf_write_enable;
  logic          [      4:0] fp_rf_write_addr;
  logic          [  FpW-1:0] fp_rf_write_data;
  logic                      fp_rf_wb_bypass_id_rs1;
  logic                      fp_rf_wb_bypass_id_rs2;
  logic                      fp_rf_wb_bypass_id_rs3;
  logic                      fp_rf_wb_bypass_dispatch_rs1;
  logic                      fp_rf_wb_bypass_dispatch_rs2;
  logic                      fp_rf_wb_bypass_dispatch_rs3;
  logic          [  FpW-1:0] fp_rf_dispatch_rs1_data;
  logic          [  FpW-1:0] fp_rf_dispatch_rs2_data;
  logic          [  FpW-1:0] fp_rf_dispatch_rs3_data;

  fp_rf_to_fwd_t             fp_rf_to_fwd;

  generic_regfile #(
      .DATA_WIDTH(FpW),
      .NUM_READ_PORTS(6),
      .HARDWIRE_ZERO(0)
  ) fp_regfile_inst (
      .i_clk,
      .i_write_enable(fp_rf_write_enable),
      .i_write_addr(fp_rf_write_addr),
      .i_write_data(fp_rf_write_data),
      .i_stall(1'b0),  // OOO: commit writes must not be blocked by front-end stall
      .i_read_addr({
        from_id_to_ex.instruction.funct7[6:2],
        from_id_to_ex.instruction.source_reg_2,
        from_id_to_ex.instruction.source_reg_1,
        from_pd_to_id.fp_source_reg_3_early,
        from_pd_to_id.source_reg_2_early,
        from_pd_to_id.source_reg_1_early
      }),
      .o_read_data(fp_rf_read_data)
  );

  assign fp_rf_wb_bypass_id_rs1 = fp_rf_write_enable &&
                                  (fp_rf_write_addr == from_pd_to_id.source_reg_1_early);
  assign fp_rf_wb_bypass_id_rs2 = fp_rf_write_enable &&
                                  (fp_rf_write_addr == from_pd_to_id.source_reg_2_early);
  assign fp_rf_wb_bypass_id_rs3 = fp_rf_write_enable &&
                                  (fp_rf_write_addr == from_pd_to_id.fp_source_reg_3_early);
  assign fp_rf_wb_bypass_dispatch_rs1 = fp_rf_write_enable &&
                                        (fp_rf_write_addr ==
                                         from_id_to_ex.instruction.source_reg_1);
  assign fp_rf_wb_bypass_dispatch_rs2 = fp_rf_write_enable &&
                                        (fp_rf_write_addr ==
                                         from_id_to_ex.instruction.source_reg_2);
  assign fp_rf_wb_bypass_dispatch_rs3 = fp_rf_write_enable &&
                                        (fp_rf_write_addr == from_id_to_ex.instruction.funct7[6:2]);

  assign fp_rf_to_fwd.fp_source_reg_1_data = fp_rf_wb_bypass_id_rs1 ? fp_rf_write_data :
                                             fp_rf_read_data[FpW-1:0];
  assign fp_rf_to_fwd.fp_source_reg_2_data = fp_rf_wb_bypass_id_rs2 ? fp_rf_write_data :
                                             fp_rf_read_data[2*FpW-1:FpW];
  assign fp_rf_to_fwd.fp_source_reg_3_data = fp_rf_wb_bypass_id_rs3 ? fp_rf_write_data :
                                             fp_rf_read_data[3*FpW-1:2*FpW];
  assign fp_rf_dispatch_rs1_data = fp_rf_wb_bypass_dispatch_rs1 ? fp_rf_write_data :
                                   fp_rf_read_data[4*FpW-1:3*FpW];
  assign fp_rf_dispatch_rs2_data = fp_rf_wb_bypass_dispatch_rs2 ? fp_rf_write_data :
                                   fp_rf_read_data[5*FpW-1:4*FpW];
  assign fp_rf_dispatch_rs3_data = fp_rf_wb_bypass_dispatch_rs3 ? fp_rf_write_data :
                                   fp_rf_read_data[6*FpW-1:5*FpW];

  // ===========================================================================
  // Stage 3: Instruction Decode (ID)
  // ===========================================================================
  // ROB commit writes are architectural WB for the OOO core. Decode still needs
  // same-cycle bypass when it reads a source register that is being committed.
  always_comb begin
    from_ma_to_wb_commit                         = '0;
    from_ma_to_wb_commit.regfile_write_enable    = int_rf_write_enable;
    from_ma_to_wb_commit.regfile_write_data      = int_rf_write_data;
    from_ma_to_wb_commit.instruction.dest_reg    = int_rf_write_addr;
    from_ma_to_wb_commit.fp_regfile_write_enable = fp_rf_write_enable;
    from_ma_to_wb_commit.fp_dest_reg             = fp_rf_write_addr;
    from_ma_to_wb_commit.fp_regfile_write_data   = fp_rf_write_data;
  end

  id_stage #(
      .XLEN(XLEN)
  ) id_stage_inst (
      .i_clk,
      .i_pipeline_ctrl(pipeline_ctrl),
      .i_from_pd_to_id(from_pd_to_id),
      .i_rf_to_id(rf_to_fwd),
      .i_fp_rf_to_id(fp_rf_to_fwd),
      .i_from_ma_to_wb(from_ma_to_wb_commit),
      .o_from_id_to_ex(from_id_to_ex)
  );

  // ===========================================================================
  // Instruction Validity (pipeline valid tracking)
  // ===========================================================================
  // After a flush/reset, the pipeline inserts NOP bubbles:
  //   T=0: PD/ID flush to NOP
  //   T=1: IF holdoff NOP (stale i_instr from 1-cycle memory latency)
  //   T=2: First real instruction reaches PD
  //   T=3: First real instruction reaches ID (from_id_to_ex valid)
  // A 3-stage valid tracker matches this IF→PD→ID latency plus the holdoff
  // cycle, ensuring NOP bubbles are never dispatched.

  logic if_valid_q;  // tracks valid at IF→PD boundary
  logic pd_valid_q;  // tracks valid at PD→ID boundary

  // Track IF stage's sel_nop through the pipeline to know when from_id_to_ex
  // contains a real instruction vs a NOP bubble (holdoff/flush/reset).
  // 2-stage chain: if_valid_q captures at PD register edge, pd_valid_q
  // captures at ID register edge — matching when from_id_to_ex is updated.
  always_ff @(posedge i_clk) begin
    if (i_rst || pipeline_ctrl.flush) begin
      if_valid_q <= 1'b0;
      pd_valid_q <= 1'b0;
    end else if (!pipeline_ctrl.stall) begin
      if_valid_q <= !from_if_to_pd.sel_nop && (post_flush_holdoff_q == 2'd0);
      pd_valid_q <= if_valid_q;
    end
  end

  logic id_valid;
  assign id_valid = pd_valid_q && !pipeline_ctrl.flush && !pipeline_ctrl.reset &&
                    !from_id_to_ex.is_illegal_instruction &&
                    !csr_in_flight &&
      // Re-dispatch the held ID image after real backpressure stalls,
      // but keep suppressing replay after self-induced serialization
      // stalls (e.g. CSR commit fencing), where the instruction has
      // already allocated once and must not be re-issued.
      (!pipeline_ctrl.stall_registered || replay_after_dispatch_stall_q);

  logic if_has_control_flow;
  logic pd_has_control_flow;
  logic id_has_control_flow;

  function automatic logic if_stage_has_control_flow(input from_if_to_pd_t if_pkt);
    logic [2:0] c_funct3;
    logic [3:0] c_funct4;
    logic [4:0] c_rs1;
    logic [4:0] c_rs2;
    logic [1:0] c_op;
    begin
      c_funct3 = if_pkt.raw_parcel[15:13];
      c_funct4 = if_pkt.raw_parcel[15:12];
      c_rs1 = if_pkt.raw_parcel[11:7];
      c_rs2 = if_pkt.raw_parcel[6:2];
      c_op = if_pkt.raw_parcel[1:0];

      if_stage_has_control_flow = 1'b0;
      if (!if_pkt.sel_nop) begin
        if (if_pkt.sel_compressed) begin
          // IF stage carries raw compressed parcels, not decompressed opcodes.
          // Recognize compressed control-flow directly so younger BTB lookups
          // cannot run ahead of an older unresolved c.branch/c.jump.
          if_stage_has_control_flow = ((c_op == 2'b01) && ((c_funct3 == 3'b001) ||  // C.JAL (RV32)
          (c_funct3 == 3'b101) ||  // C.J
          (c_funct3 == 3'b110) ||  // C.BEQZ
          (c_funct3 == 3'b111))) ||  // C.BNEZ
          ((c_op == 2'b10) &&
               (c_rs2 == 5'b00000) &&
               (c_rs1 != 5'b00000) &&
               ((c_funct4 == 4'b1000) ||  // C.JR
          (c_funct4 == 4'b1001)));  // C.JALR
        end else begin
          if_stage_has_control_flow =
              (if_pkt.effective_instr[6:0] == riscv_pkg::OPC_BRANCH) ||
              (if_pkt.effective_instr[6:0] == riscv_pkg::OPC_JAL) ||
              (if_pkt.effective_instr[6:0] == riscv_pkg::OPC_JALR);
        end
      end
    end
  endfunction

  assign if_has_control_flow = if_stage_has_control_flow(from_if_to_pd);
  assign pd_has_control_flow = if_valid_q &&
                               ((from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_BRANCH) ||
                                (from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_JAL) ||
                                (from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_JALR));
  assign id_has_control_flow = pd_valid_q && is_branch_or_jump_op(
      from_id_to_ex.instruction_operation
  );
  assign front_end_control_flow_pending = if_has_control_flow ||
                                          pd_has_control_flow ||
                                          id_has_control_flow;

  // ===========================================================================
  // Tomasulo Wrapper Instance
  // ===========================================================================

  // ROB interface
  reorder_buffer_alloc_req_t  rob_alloc_req;
  reorder_buffer_alloc_resp_t rob_alloc_resp;
  reorder_buffer_commit_t     rob_commit;

  // RAT lookup
  logic [RegAddrWidth-1:0] int_src1_addr, int_src2_addr;
  logic [RegAddrWidth-1:0] fp_src1_addr, fp_src2_addr, fp_src3_addr;
  rat_lookup_t int_src1_lookup, int_src2_lookup;
  rat_lookup_t fp_src1_lookup, fp_src2_lookup, fp_src3_lookup;

  // RAT rename
  logic                                     rat_alloc_valid;
  logic                                     rat_alloc_dest_rf;
  logic         [         RegAddrWidth-1:0] rat_alloc_dest_reg;
  logic         [ReorderBufferTagWidth-1:0] rat_alloc_rob_tag;

  // RS dispatch
  rs_dispatch_t                             rs_dispatch;

  // Checkpoint
  logic                                     checkpoint_available;
  logic         [    CheckpointIdWidth-1:0] checkpoint_alloc_id;
  logic                                     checkpoint_save;
  logic         [    CheckpointIdWidth-1:0] checkpoint_id;
  logic         [ReorderBufferTagWidth-1:0] checkpoint_branch_tag;
  logic         [           RasPtrBits-1:0] dispatch_ras_tos;
  logic         [             RasPtrBits:0] dispatch_ras_valid_count;
  logic                                     rob_checkpoint_valid;
  logic         [    CheckpointIdWidth-1:0] rob_checkpoint_id;

  // Resource status
  logic rob_full, rob_empty;
  logic int_rs_full, mul_rs_full, mem_rs_full;
  logic fp_rs_full, fmul_rs_full, fdiv_rs_full;
  logic lq_full, sq_full;

  // Branch update
  reorder_buffer_branch_update_t                             branch_update;

  // Flush
  logic                                                      flush_en;
  logic                          [ReorderBufferTagWidth-1:0] flush_tag;
  logic                                                      flush_all;

  // CDB
  cdb_broadcast_t                                            cdb_out;
  logic                          [               NumFus-1:0] cdb_grant;

  // ROB status
  logic                          [  ReorderBufferTagWidth:0] rob_count;
  logic                          [ReorderBufferTagWidth-1:0] head_tag;
  logic head_valid, head_done;
  logic fence_i_flush;

  // CSR coordination
  logic csr_start, csr_done_ack;
  logic trap_pending;
  logic [XLEN-1:0] rob_trap_pc;
  exc_cause_t rob_trap_cause;
  logic rob_trap_taken_ack;
  logic mret_start, mret_done_ack;
  logic [XLEN-1:0] mepc_value;
  logic interrupt_pending;

  // Memory interfaces
  logic sq_mem_write_en;
  logic [XLEN-1:0] sq_mem_write_addr, sq_mem_write_data;
  logic [3:0] sq_mem_write_byte_en;
  logic sq_mem_write_done, sq_mem_write_done_comb;

  logic lq_mem_read_en;
  logic [XLEN-1:0] lq_mem_read_addr;
  mem_size_e lq_mem_read_size;
  logic [XLEN-1:0] lq_mem_read_data;
  logic lq_mem_read_valid;

  // AMO memory interface
  logic amo_mem_write_en;
  logic [XLEN-1:0] amo_mem_write_addr, amo_mem_write_data;
  logic amo_mem_write_done;

  // RS issue (exposed but not externally driven — FU shims are inside wrapper)
  rs_issue_t rs_issue_int, rs_issue_mul, rs_issue_mem;
  rs_issue_t rs_issue_fp, rs_issue_fmul, rs_issue_fdiv;

  // ROB bypass read
  logic [ReorderBufferTagWidth-1:0] rob_read_tag;
  logic rob_read_done;
  logic [FLEN-1:0] rob_read_value;
  logic [riscv_pkg::ReorderBufferDepth-1:0] rob_entry_done_dispatch;
  logic [ReorderBufferTagWidth-1:0]
      dispatch_bypass_tag_1, dispatch_bypass_tag_2, dispatch_bypass_tag_3;
  logic [FLEN-1:0] dispatch_bypass_value_1, dispatch_bypass_value_2, dispatch_bypass_value_3;

  // Checkpoint restore (from flush controller)
  logic checkpoint_restore;
  logic [CheckpointIdWidth-1:0] checkpoint_restore_id;
  logic [RasPtrBits-1:0] restored_ras_tos;
  logic [RasPtrBits:0] restored_ras_valid_count;

  // Checkpoint free (from commit)
  logic checkpoint_free;
  logic [CheckpointIdWidth-1:0] checkpoint_free_id;

  // LQ/SQ status
  logic lq_empty, sq_empty;
  logic [$clog2(riscv_pkg::LqDepth+1)-1:0] lq_count;
  logic [$clog2(riscv_pkg::SqDepth+1)-1:0] sq_count;
  logic rs_empty;
  logic [3:0] rs_count;

  // FU completion (external injection not used — FU shims are inside wrapper)
`ifdef VERILATOR
  fu_complete_t fu_complete_ext[NumFus];
  always_comb begin
    for (int i = 0; i < NumFus; i++) begin
      fu_complete_ext[i] = '0;
    end
  end
`endif

  // FRM CSR
  logic [     2:0] frm_csr;

  // CSR read data
  logic [XLEN-1:0] csr_read_data;  // registered (1-cycle latency)
  logic [XLEN-1:0] csr_read_data_comb;  // combinational (same cycle, for rd write)

  tomasulo_wrapper u_tomasulo (
      .i_clk,
      .i_rst_n(rst_n),

      .i_frm_csr(frm_csr),

      // ROB allocation
      .i_alloc_req (rob_alloc_req),
      .o_alloc_resp(rob_alloc_resp),

      // FU completion (not externally driven)
`ifdef VERILATOR
      .i_fu_complete  (fu_complete_ext),
`else
      .i_fu_complete_0('0),
      .i_fu_complete_1('0),
      .i_fu_complete_2('0),
      .i_fu_complete_3('0),
      .i_fu_complete_4('0),
      .i_fu_complete_5('0),
      .i_fu_complete_6('0),
`endif

      .o_cdb_grant(cdb_grant),
      .o_cdb(cdb_out),

      // Branch update
      .i_branch_update(branch_update),

      // ROB checkpoint recording
      .i_rob_checkpoint_valid(rob_checkpoint_valid),
      .i_rob_checkpoint_id(rob_checkpoint_id),

      // Commit
      .o_commit(rob_commit),

      // ROB external coordination
      .o_csr_start(csr_start),
      .i_csr_done(csr_done_ack),
      .o_trap_pending(trap_pending),
      .o_trap_pc(rob_trap_pc),
      .o_trap_cause(rob_trap_cause),
      .i_trap_taken(rob_trap_taken_ack),
      .o_mret_start(mret_start),
      .i_mret_done(mret_done_ack),
      .i_mepc(mepc_value),
      .i_interrupt_pending(interrupt_pending),

      // Flush
      .i_flush_en (flush_en),
      .i_flush_tag(flush_tag),
      .i_flush_all(flush_all),

      // ROB status
      .o_fence_i_flush(fence_i_flush),
      .o_rob_full(rob_full),
      .o_rob_empty(rob_empty),
      .o_rob_count(rob_count),
      .o_head_tag(head_tag),
      .o_head_valid(head_valid),
      .o_head_done(head_done),

      // ROB bypass read
      .i_read_tag(rob_read_tag),
      .o_read_done(rob_read_done),
      .o_read_value(rob_read_value),
      .o_rob_entry_done_vec(rob_entry_done_dispatch),
      .i_bypass_tag_1(dispatch_bypass_tag_1),
      .o_bypass_value_1(dispatch_bypass_value_1),
      .i_bypass_tag_2(dispatch_bypass_tag_2),
      .o_bypass_value_2(dispatch_bypass_value_2),
      .i_bypass_tag_3(dispatch_bypass_tag_3),
      .o_bypass_value_3(dispatch_bypass_value_3),

      // RAT source lookups
      .i_int_src1_addr(int_src1_addr),
      .i_int_src2_addr(int_src2_addr),
      .o_int_src1(int_src1_lookup),
      .o_int_src2(int_src2_lookup),
      .i_fp_src1_addr(fp_src1_addr),
      .i_fp_src2_addr(fp_src2_addr),
      .i_fp_src3_addr(fp_src3_addr),
      .o_fp_src1(fp_src1_lookup),
      .o_fp_src2(fp_src2_lookup),
      .o_fp_src3(fp_src3_lookup),

      // RAT regfile data
      .i_int_regfile_data1(int_rf_dispatch_rs1_data),
      .i_int_regfile_data2(int_rf_dispatch_rs2_data),
      .i_fp_regfile_data1 (fp_rf_dispatch_rs1_data),
      .i_fp_regfile_data2 (fp_rf_dispatch_rs2_data),
      .i_fp_regfile_data3 (fp_rf_dispatch_rs3_data),

      // RAT rename
      .i_rat_alloc_valid(rat_alloc_valid),
      .i_rat_alloc_dest_rf(rat_alloc_dest_rf),
      .i_rat_alloc_dest_reg(rat_alloc_dest_reg),
      .i_rat_alloc_rob_tag(rat_alloc_rob_tag),

      // RAT checkpoint save
      .i_checkpoint_save(checkpoint_save),
      .i_checkpoint_id(checkpoint_id),
      .i_checkpoint_branch_tag(checkpoint_branch_tag),
      .i_ras_tos(dispatch_ras_tos),
      .i_ras_valid_count(dispatch_ras_valid_count),

      // RAT checkpoint restore
      .i_checkpoint_restore(checkpoint_restore),
      .i_checkpoint_restore_id(checkpoint_restore_id),
      .o_ras_tos(restored_ras_tos),
      .o_ras_valid_count(restored_ras_valid_count),

      // RAT checkpoint free
      .i_checkpoint_free(checkpoint_free),
      .i_checkpoint_free_id(checkpoint_free_id),

      // RAT checkpoint availability
      .o_checkpoint_available(checkpoint_available),
      .o_checkpoint_alloc_id (checkpoint_alloc_id),

      // RS dispatch
`ifdef VERILATOR
      .i_rs_dispatch(rs_dispatch),
`else
      .i_rs_dispatch_valid(rs_dispatch.valid),
      .i_rs_dispatch_rs_type(rs_dispatch.rs_type),
      .i_rs_dispatch_rob_tag(rs_dispatch.rob_tag),
      .i_rs_dispatch_op(rs_dispatch.op),
      .i_rs_dispatch_src1_ready(rs_dispatch.src1_ready),
      .i_rs_dispatch_src1_tag(rs_dispatch.src1_tag),
      .i_rs_dispatch_src1_value(rs_dispatch.src1_value),
      .i_rs_dispatch_src2_ready(rs_dispatch.src2_ready),
      .i_rs_dispatch_src2_tag(rs_dispatch.src2_tag),
      .i_rs_dispatch_src2_value(rs_dispatch.src2_value),
      .i_rs_dispatch_src3_ready(rs_dispatch.src3_ready),
      .i_rs_dispatch_src3_tag(rs_dispatch.src3_tag),
      .i_rs_dispatch_src3_value(rs_dispatch.src3_value),
      .i_rs_dispatch_imm(rs_dispatch.imm),
      .i_rs_dispatch_use_imm(rs_dispatch.use_imm),
      .i_rs_dispatch_rm(rs_dispatch.rm),
      .i_rs_dispatch_branch_target(rs_dispatch.branch_target),
      .i_rs_dispatch_predicted_taken(rs_dispatch.predicted_taken),
      .i_rs_dispatch_predicted_target(rs_dispatch.predicted_target),
      .i_rs_dispatch_is_fp_mem(rs_dispatch.is_fp_mem),
      .i_rs_dispatch_mem_size(rs_dispatch.mem_size),
      .i_rs_dispatch_mem_signed(rs_dispatch.mem_signed),
      .i_rs_dispatch_csr_addr(rs_dispatch.csr_addr),
      .i_rs_dispatch_csr_imm(rs_dispatch.csr_imm),
      .i_rs_dispatch_pc(rs_dispatch.pc),
`endif
      .o_rs_full(),

      // RS issue + status (INT_RS)
`ifdef VERILATOR
      .o_rs_issue(rs_issue_int),
`else
      .o_rs_issue_valid(),
      .o_rs_issue_rob_tag(),
      .o_rs_issue_op(),
      .o_rs_issue_src1_value(),
      .o_rs_issue_src2_value(),
      .o_rs_issue_src3_value(),
      .o_rs_issue_imm(),
      .o_rs_issue_use_imm(),
      .o_rs_issue_rm(),
      .o_rs_issue_branch_target(),
      .o_rs_issue_predicted_taken(),
      .o_rs_issue_predicted_target(),
      .o_rs_issue_is_fp_mem(),
      .o_rs_issue_mem_size(),
      .o_rs_issue_mem_signed(),
      .o_rs_issue_csr_addr(),
      .o_rs_issue_csr_imm(),
      .o_rs_issue_pc(),
`endif
      .i_rs_fu_ready(1'b1),
      .o_int_rs_full(int_rs_full),
      .o_rs_empty(rs_empty),
      .o_rs_count(rs_count),

      // MUL_RS
      .o_mul_rs_issue(rs_issue_mul),
      .i_mul_rs_fu_ready(1'b1),
      .o_mul_rs_full(mul_rs_full),
      .o_mul_rs_empty(),
      .o_mul_rs_count(),

      // MEM_RS
      .o_mem_rs_issue(rs_issue_mem),
      .i_mem_rs_fu_ready(1'b1),
      .o_mem_rs_full(mem_rs_full),
      .o_mem_rs_empty(),
      .o_mem_rs_count(),

      // FP_RS
      .o_fp_rs_issue(rs_issue_fp),
      .i_fp_rs_fu_ready(1'b1),
      .o_fp_rs_full(fp_rs_full),
      .o_fp_rs_empty(),
      .o_fp_rs_count(),

      // FMUL_RS
      .o_fmul_rs_issue(rs_issue_fmul),
      .i_fmul_rs_fu_ready(1'b1),
      .o_fmul_rs_full(fmul_rs_full),
      .o_fmul_rs_empty(),
      .o_fmul_rs_count(),

      // FDIV_RS
      .o_fdiv_rs_issue(rs_issue_fdiv),
      .i_fdiv_rs_fu_ready(1'b1),
      .o_fdiv_rs_full(fdiv_rs_full),
      .o_fdiv_rs_empty(),
      .o_fdiv_rs_count(),

      // CSR read data
      .i_csr_read_data(csr_read_data),

      // Store queue memory interface
      .o_sq_mem_write_en(sq_mem_write_en),
      .o_sq_mem_write_addr(sq_mem_write_addr),
      .o_sq_mem_write_data(sq_mem_write_data),
      .o_sq_mem_write_byte_en(sq_mem_write_byte_en),
      .i_sq_mem_write_done(sq_mem_write_done),

      // Load queue memory interface
      .o_lq_mem_read_en(lq_mem_read_en),
      .o_lq_mem_read_addr(lq_mem_read_addr),
      .o_lq_mem_read_size(lq_mem_read_size),
      .i_lq_mem_read_data(lq_mem_read_data),
      .i_lq_mem_read_valid(lq_mem_read_valid),

      // LQ/SQ status
      .o_lq_full (lq_full),
      .o_lq_empty(lq_empty),
      .o_lq_count(lq_count),
      .o_sq_full (sq_full),
      .o_sq_empty(sq_empty),
      .o_sq_count(sq_count),

      // AMO memory interface
      .o_amo_mem_write_en  (amo_mem_write_en),
      .o_amo_mem_write_addr(amo_mem_write_addr),
      .o_amo_mem_write_data(amo_mem_write_data),
      .i_amo_mem_write_done(amo_mem_write_done)
  );

  // ===========================================================================
  // Dispatch Unit
  // ===========================================================================

  dispatch u_dispatch (
      .i_clk,
      .i_rst_n(rst_n),

      .i_from_id_to_ex(from_id_to_ex),
      .i_valid(id_valid),

      .i_rs1_addr(from_id_to_ex.instruction.source_reg_1),
      .i_rs2_addr(from_id_to_ex.instruction.source_reg_2),
      .i_fp_rs3_addr(from_id_to_ex.instruction.funct7[6:2]),

      .i_frm_csr(frm_csr),

      // ROB
      .o_rob_alloc_req (rob_alloc_req),
      .i_rob_alloc_resp(rob_alloc_resp),

      // RAT lookups
      .o_int_src1_addr(int_src1_addr),
      .o_int_src2_addr(int_src2_addr),
      .o_fp_src1_addr (fp_src1_addr),
      .o_fp_src2_addr (fp_src2_addr),
      .o_fp_src3_addr (fp_src3_addr),

      .i_int_src1(int_src1_lookup),
      .i_int_src2(int_src2_lookup),
      .i_fp_src1 (fp_src1_lookup),
      .i_fp_src2 (fp_src2_lookup),
      .i_fp_src3 (fp_src3_lookup),

      // RAT rename
      .o_rat_alloc_valid(rat_alloc_valid),
      .o_rat_alloc_dest_rf(rat_alloc_dest_rf),
      .o_rat_alloc_dest_reg(rat_alloc_dest_reg),
      .o_rat_alloc_rob_tag(rat_alloc_rob_tag),

      // ROB done-entry bypass
      .i_rob_entry_done(rob_entry_done_dispatch),
      .o_bypass_tag_1  (dispatch_bypass_tag_1),
      .i_bypass_value_1(dispatch_bypass_value_1),
      .o_bypass_tag_2  (dispatch_bypass_tag_2),
      .i_bypass_value_2(dispatch_bypass_value_2),
      .o_bypass_tag_3  (dispatch_bypass_tag_3),
      .i_bypass_value_3(dispatch_bypass_value_3),

      // RS dispatch
      .o_rs_dispatch(rs_dispatch),

      // Checkpoint management
      .i_checkpoint_available(checkpoint_available),
      .i_checkpoint_alloc_id(checkpoint_alloc_id),
      .o_checkpoint_save(checkpoint_save),
      .o_checkpoint_id(checkpoint_id),
      .o_checkpoint_branch_tag(checkpoint_branch_tag),
      .i_ras_tos(from_if_to_pd.ras_checkpoint_tos),
      .i_ras_valid_count(from_if_to_pd.ras_checkpoint_valid_count),
      .o_ras_tos(dispatch_ras_tos),
      .o_ras_valid_count(dispatch_ras_valid_count),
      .o_rob_checkpoint_valid(rob_checkpoint_valid),
      .o_rob_checkpoint_id(rob_checkpoint_id),

      // Resource status
      .i_rob_full(rob_full),
      .i_int_rs_full(int_rs_full),
      .i_mul_rs_full(mul_rs_full),
      .i_mem_rs_full(mem_rs_full),
      .i_fp_rs_full(fp_rs_full),
      .i_fmul_rs_full(fmul_rs_full),
      .i_fdiv_rs_full(fdiv_rs_full),
      .i_lq_full(lq_full),
      .i_sq_full(sq_full),

      // Flush
      .i_flush(flush_pipeline),

      // Stall output
      .o_stall(dispatch_stall)
  );

  // ===========================================================================
  // ROB Bypass Read — read head entry value for CSR write data
  // ===========================================================================
  assign rob_read_tag = head_tag;

  // ===========================================================================
  // Branch Resolution Unit
  // ===========================================================================
  // Branch/jump instructions issue from INT_RS. The ALU shim suppresses CDB
  // broadcast for these ops. Instead, we resolve them here and generate
  // a reorder_buffer_branch_update_t that goes to the ROB.

  logic is_branch_issue;
  assign is_branch_issue = rs_issue_int.valid && is_branch_or_jump_op(rs_issue_int.op);

  logic is_jal_issue, is_jalr_issue;
  assign is_jal_issue  = rs_issue_int.valid && is_jal_op(rs_issue_int.op);
  assign is_jalr_issue = rs_issue_int.valid && is_jalr_op(rs_issue_int.op);

  // Map instr_op_e → branch_taken_op_e for branch_jump_unit
  branch_taken_op_e branch_op_resolved;
  always_comb begin
    case (rs_issue_int.op)
      BEQ:       branch_op_resolved = BREQ;
      BNE:       branch_op_resolved = BRNE;
      BLT:       branch_op_resolved = BRLT;
      BGE:       branch_op_resolved = BRGE;
      BLTU:      branch_op_resolved = BRLTU;
      BGEU:      branch_op_resolved = BRGEU;
      JAL, JALR: branch_op_resolved = JUMP;
      default:   branch_op_resolved = NULL;
    endcase
  end

  // Branch/jump condition evaluation and target computation
  logic            branch_taken_resolved;
  logic [XLEN-1:0] branch_target_resolved;

  branch_jump_unit #(
      .XLEN(XLEN)
  ) u_branch_resolve (
      .i_branch_operation         (branch_op_resolved),
      .i_is_jump_and_link         (is_jal_issue),
      .i_is_jump_and_link_register(is_jalr_issue),
      .i_operand_a                (rs_issue_int.src1_value[XLEN-1:0]),
      .i_operand_b                (rs_issue_int.src2_value[XLEN-1:0]),
      // Dispatch stores the correct pre-computed target in branch_target
      // (jal_target_precomputed for JAL, branch_target_precomputed for branches)
      .i_branch_target_precomputed(rs_issue_int.branch_target),
      .i_jal_target_precomputed   (rs_issue_int.branch_target),
      .i_immediate_i_type         (rs_issue_int.imm),
      .o_branch_taken             (branch_taken_resolved),
      .o_branch_target_address    (branch_target_resolved)
  );

  // Misprediction detection (authoritative — the ROB trusts this flag)
  logic branch_mispredicted;
  always_comb begin
    if (!is_branch_issue) begin
      branch_mispredicted = 1'b0;
    end else if (branch_taken_resolved != rs_issue_int.predicted_taken) begin
      // Direction misprediction (taken vs not-taken)
      branch_mispredicted = 1'b1;
    end else if (branch_taken_resolved && rs_issue_int.predicted_taken &&
                 branch_target_resolved != rs_issue_int.predicted_target) begin
      // Target misprediction (both taken but different targets)
      branch_mispredicted = 1'b1;
    end else begin
      branch_mispredicted = 1'b0;
    end
  end

  // Generate branch_update for the ROB
  always_comb begin
    branch_update              = '0;
    branch_update.valid        = is_branch_issue;
    branch_update.tag          = rs_issue_int.rob_tag;
    branch_update.taken        = branch_taken_resolved;
    branch_update.target       = branch_target_resolved;
    branch_update.mispredicted = branch_mispredicted;
  end

  // ===========================================================================
  // Commit-Time Actions
  // ===========================================================================

  // --- Regfile writes from ROB commit ---
  // CSR instructions use o_csr_read_data_comb (combinational, same cycle) so
  // the rd write can happen on the same commit cycle as non-CSR instructions.
  always_comb begin
    int_rf_write_enable = 1'b0;
    int_rf_write_addr   = '0;
    int_rf_write_data   = '0;
    fp_rf_write_enable  = 1'b0;
    fp_rf_write_addr    = '0;
    fp_rf_write_data    = '0;

    if (rob_commit.valid && rob_commit.dest_valid && !rob_commit.exception) begin
      if (rob_commit.is_csr) begin
        // CSR: write old CSR value (combinational read) to rd
        int_rf_write_enable = 1'b1;
        int_rf_write_addr   = rob_commit.dest_reg;
        int_rf_write_data   = csr_read_data_comb;
      end else if (rob_commit.dest_rf == 1'b0) begin
        // INT destination
        int_rf_write_enable = 1'b1;
        int_rf_write_addr   = rob_commit.dest_reg;
        int_rf_write_data   = rob_commit.value[XLEN-1:0];
      end else begin
        // FP destination
        fp_rf_write_enable = 1'b1;
        fp_rf_write_addr   = rob_commit.dest_reg;
        fp_rf_write_data   = rob_commit.value;
      end
    end
  end

  // --- Instruction retire signal ---
  assign o_vld = rob_commit.valid && !rob_commit.exception;

  // --- PC validity ---
  assign o_pc_vld = o_vld;

  // ===========================================================================
  // Misprediction & Flush Controller
  // ===========================================================================
  // On ROB commit of a mispredicted branch:
  //   1. Flush all younger entries in ROB (flush_en + flush_tag)
  //   2. Restore RAT from checkpoint
  //   3. Redirect IF stage to correct target
  //   4. Flush front-end pipeline (IF/PD/ID)

  logic commit_is_misprediction;
  assign commit_is_misprediction = rob_commit.valid && rob_commit.misprediction;

  // The correct redirect PC for misprediction is computed by the ROB:
  //   - For taken branches/jumps: the actual target from branch resolution
  //   - For not-taken branches: PC + 4 (or PC + 2 for compressed)
  //   - For MRET: mepc
  logic [XLEN-1:0] misprediction_redirect_pc;
  assign misprediction_redirect_pc = rob_commit.redirect_pc;

  // Flush pipeline on misprediction, trap, MRET, or FENCE.I
  always_comb begin
    // fence_i_flush is already a registered 1-cycle pulse from the ROB, one
    // cycle after FENCE.I commits. Gate the front-end flush directly from that
    // pulse so dispatch cannot allocate into the same cycle as a full flush.
    flush_pipeline = commit_is_misprediction || flush_for_trap || flush_for_mret || fence_i_flush;
  end

  // ROB flush: partial flush on misprediction (younger than branch),
  // full flush on trap/MRET/FENCE.I
  always_comb begin
    flush_en  = 1'b0;
    flush_tag = '0;
    flush_all = 1'b0;

    if (flush_for_trap || flush_for_mret) begin
      flush_en  = 1'b1;
      flush_all = 1'b1;
    end else if (commit_is_misprediction) begin
      // Flush everything after the mispredicted branch's ROB tag
      flush_en  = 1'b1;
      flush_tag = rob_commit.tag;
      flush_all = 1'b0;
    end else if (fence_i_flush) begin
      // fence_i_flush is a registered 1-cycle pulse from ROB (fires cycle after
      // FENCE.I commit). No need to gate with rob_commit.valid — doing so
      // creates a combinational loop (flush_all -> commit_en -> rob_commit.valid).
      flush_en  = 1'b1;
      flush_all = 1'b1;
    end
  end

  // Checkpoint restore on misprediction
  always_comb begin
    // Restore RAT state for every mispredicted control-flow instruction.
    // The current RAT restore path clears speculative rename state rather than
    // replaying a checkpoint image, so skipping restore on calls leaves flushed
    // younger mappings for caller fall-through instructions live into the
    // callee after redirect.
    checkpoint_restore    = commit_is_misprediction && rob_commit.has_checkpoint;
    checkpoint_restore_id = rob_commit.checkpoint_id;
  end

  // Checkpoint free on any branch commit (correct or mispredicted)
  always_comb begin
    checkpoint_free    = rob_commit.valid && rob_commit.has_checkpoint;
    checkpoint_free_id = rob_commit.checkpoint_id;
  end

  // ===========================================================================
  // Synthesize from_ex_comb for IF Stage
  // ===========================================================================
  // The IF stage expects from_ex_comb_t for branch redirect, BTB update,
  // and RAS restore. In OOO mode, these come from ROB commit.

  always_comb begin
    from_ex_comb_synth = '0;

    if (commit_is_misprediction) begin
      // Misprediction: redirect PC and update BTB
      from_ex_comb_synth.branch_taken          = 1'b1;
      from_ex_comb_synth.branch_target_address = misprediction_redirect_pc;

      if (!rob_commit.is_return) begin
        from_ex_comb_synth.btb_update            = 1'b1;
        from_ex_comb_synth.btb_update_pc         = rob_commit.pc;
        from_ex_comb_synth.btb_update_target     = rob_commit.branch_target;
        from_ex_comb_synth.btb_update_taken      = rob_commit.branch_taken;
        from_ex_comb_synth.btb_update_compressed = rob_commit.is_compressed;
      end

      // RAS restore on misprediction (if branch had a checkpoint)
      if (rob_commit.is_return) begin
        from_ex_comb_synth.ras_misprediction       = 1'b1;
        from_ex_comb_synth.ras_restore_tos         = restored_ras_tos;
        from_ex_comb_synth.ras_restore_valid_count = restored_ras_valid_count;
        from_ex_comb_synth.ras_pop_after_restore   = 1'b1;
      end
    end else if (rob_commit.valid && rob_commit.has_checkpoint && !rob_commit.misprediction) begin
      // Correctly-predicted branch commit: update BTB (no PC redirect)
      if (!rob_commit.is_return) begin
        from_ex_comb_synth.btb_update            = 1'b1;
        from_ex_comb_synth.btb_update_pc         = rob_commit.pc;
        from_ex_comb_synth.btb_update_target     = rob_commit.branch_target;
        from_ex_comb_synth.btb_update_taken      = rob_commit.branch_taken;
        from_ex_comb_synth.btb_update_compressed = rob_commit.is_compressed;
      end
    end
  end

  // ===========================================================================
  // Memory Interface
  // ===========================================================================
  // Route LQ/SQ memory requests to the external data memory port.
  // Priority: SQ writes > LQ reads > AMO writes
  // The L0 cache is inside the tomasulo_wrapper (lq_l0_cache).

  always_comb begin
    o_data_mem_addr           = '0;
    o_data_mem_wr_data        = '0;
    o_data_mem_per_byte_wr_en = '0;
    o_data_mem_read_enable    = 1'b0;
    o_mmio_load_addr          = '0;
    o_mmio_load_valid         = 1'b0;
    sq_mem_write_done_comb    = 1'b0;
    amo_mem_write_done        = 1'b0;

    if (sq_mem_write_en) begin
      // Store queue memory write
      o_data_mem_addr           = sq_mem_write_addr;
      o_data_mem_wr_data        = sq_mem_write_data;
      o_data_mem_per_byte_wr_en = sq_mem_write_byte_en;
      sq_mem_write_done_comb    = 1'b1;  // Single-cycle write
    end else if (amo_mem_write_en) begin
      // AMO memory write
      o_data_mem_addr           = amo_mem_write_addr;
      o_data_mem_wr_data        = amo_mem_write_data;
      o_data_mem_per_byte_wr_en = 4'b1111;
      amo_mem_write_done        = 1'b1;
    end else if (lq_mem_read_en) begin
      // Load queue memory read
      o_data_mem_addr        = lq_mem_read_addr;
      o_data_mem_read_enable = 1'b1;
      // MMIO detection
      if (lq_mem_read_addr >= MMIO_ADDR[XLEN-1:0] &&
          lq_mem_read_addr < (MMIO_ADDR[XLEN-1:0] + MMIO_SIZE_BYTES[XLEN-1:0])) begin
        o_mmio_load_addr  = lq_mem_read_addr;
        o_mmio_load_valid = 1'b1;
      end
    end
  end

  // SQ write done: register to align with write_outstanding in the SQ
  always_ff @(posedge i_clk) begin
    if (i_rst) sq_mem_write_done <= 1'b0;
    else sq_mem_write_done <= sq_mem_write_done_comb;
  end

  // Load data always comes from external memory
  assign lq_mem_read_data = i_data_mem_rd_data;

  // Memory read valid: 1-cycle latency from read enable
  logic mem_read_pending;
  logic lq_mem_read_accepted;
  assign lq_mem_read_accepted = o_data_mem_read_enable;
  always_ff @(posedge i_clk) begin
    if (i_rst) mem_read_pending <= 1'b0;
    else mem_read_pending <= lq_mem_read_accepted;
  end
  assign lq_mem_read_valid = mem_read_pending;

  // MMIO read pulse
  assign o_mmio_read_pulse = lq_mem_read_accepted &&
                             (o_data_mem_addr >= MMIO_ADDR[XLEN-1:0]) &&
                             (o_data_mem_addr < (MMIO_ADDR[XLEN-1:0] + MMIO_SIZE_BYTES[XLEN-1:0]));

  // ===========================================================================
  // CSR File
  // ===========================================================================
  // CSR operations are serialized: the ROB waits for the CSR at head,
  // then signals csr_start. The CSR file performs the read/write,
  // then signals csr_done.

  logic [XLEN-1:0] csr_mstatus, csr_mie, csr_mtvec, csr_mepc;
  logic csr_mstatus_mie_direct;

  // CSR execution happens at commit time (serialized by ROB).
  // The ALU shim passes through the rs1/imm value as the CDB result.
  // At commit, the value is available in rob_commit.value.
  assign csr_commit_fire = rob_commit.valid && rob_commit.is_csr && !rob_commit.exception;

  // CSR write data: for register ops (CSRRW/CSRRS/CSRRC), the ALU shim
  // stored rs1 in rob_commit.value. For immediate ops (CSRRWI/CSRRSI/CSRRCI),
  // the ALU shim stored zero_extend(csr_imm) in rob_commit.value.
  logic [XLEN-1:0] csr_write_data_from_commit;
  assign csr_write_data_from_commit = rob_commit.value[XLEN-1:0];

  csr_file #(
      .XLEN(XLEN)
  ) csr_file_inst (
      .i_clk,
      .i_rst,
      .i_csr_read_enable(csr_commit_fire),
      .i_csr_address(rob_commit.csr_addr),
      .i_csr_op(rob_commit.csr_op),
      .i_csr_write_data(csr_write_data_from_commit),
      .i_csr_write_enable(csr_commit_fire),
      .o_csr_read_data(csr_read_data),
      .o_csr_read_data_comb(csr_read_data_comb),
      .i_instruction_retired(o_vld && !trap_taken),
      .i_interrupts(i_interrupts),
      .i_mtime(i_mtime),
      .i_trap_taken(trap_taken),
      .i_trap_pc(rob_trap_pc),
      .i_trap_cause({{(XLEN - $bits(rob_trap_cause)) {1'b0}}, rob_trap_cause}),
      .i_trap_value('0),
      .i_mret_taken(mret_taken),
      .o_mstatus(csr_mstatus),
      .o_mie(csr_mie),
      .o_mtvec(csr_mtvec),
      .o_mepc(csr_mepc),
      .o_mstatus_mie_direct(csr_mstatus_mie_direct),
      // FP flags: accumulated from ROB commit
      .i_fp_flags(rob_commit.fp_flags),
      .i_fp_flags_valid(rob_commit.valid && rob_commit.has_fp_flags && !rob_commit.exception),
      .i_fp_flags_wb_valid(rob_commit.valid && rob_commit.has_fp_flags),
      .i_fp_flags_ma('0),
      .i_fp_flags_ma_valid(1'b0),
      .o_frm(frm_csr)
  );

  // CSR done acknowledgment — 1-cycle delay to match CSR file read latency.
  // csr_start fires on cycle N (ROB enters SERIAL_CSR_EXEC), csr_done_ack
  // fires on cycle N+1, allowing the ROB to commit.
  logic csr_done_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) csr_done_q <= 1'b0;
    else csr_done_q <= csr_start;
  end
  assign csr_done_ack = csr_done_q;

  // MEPC for MRET
  assign mepc_value = csr_mepc;

  // ===========================================================================
  // Trap Unit
  // ===========================================================================
  // Handles exceptions from ROB commit and external interrupts.

  // Interrupt pending signal — raw pending without MIE gate.
  // Per RISC-V spec, WFI wakes on ANY pending interrupt, even if masked.
  // The trap unit separately checks MIE to decide whether to take the trap.
  assign interrupt_pending = i_interrupts.meip || i_interrupts.mtip || i_interrupts.msip;

  logic [XLEN-1:0] trap_target_internal, trap_pc_internal;
  logic [XLEN-1:0] trap_cause_internal, trap_value_internal;

  trap_unit #(
      .XLEN(XLEN)
  ) trap_unit_inst (
      .i_clk,
      .i_rst,
      .i_pipeline_stall(1'b0),  // OOO: no stall for trap check
      .i_mstatus(csr_mstatus),
      .i_mie(csr_mie),
      .i_mtvec(csr_mtvec),
      .i_mepc(csr_mepc),
      .i_mstatus_mie_direct(csr_mstatus_mie_direct),
      .i_interrupts(i_interrupts),
      // Exception from ROB commit
      .i_exception_valid(trap_pending),
      .i_exception_cause({{(XLEN - $bits(rob_trap_cause)) {1'b0}}, rob_trap_cause}),
      .i_exception_tval('0),
      .i_exception_pc(rob_trap_pc),
      .i_mret_in_ex(mret_start),
      .i_wfi_in_ex(1'b0),  // WFI handled by ROB serialization
      .o_trap_taken(trap_taken),
      .o_mret_taken(mret_taken),
      .o_trap_target(trap_target),
      .o_trap_pc(trap_pc_internal),
      .o_trap_cause(trap_cause_internal),
      .o_trap_value(trap_value_internal),
      .o_stall_for_wfi()  // WFI stall handled at ROB head
  );

  assign flush_for_trap = trap_taken;
  assign flush_for_mret = mret_taken;

  // Acknowledge trap/mret to ROB
  assign rob_trap_taken_ack = trap_taken;
  assign mret_done_ack = mret_taken;

  // ===========================================================================
  // Reset Done
  // ===========================================================================
  // Reset done when L0 cache (inside tomasulo_wrapper) finishes clearing.
  // For now, use a simple counter.
  logic [7:0] rst_counter;
  always_ff @(posedge i_clk) begin
    if (i_rst) rst_counter <= '0;
    else if (!o_rst_done) rst_counter <= rst_counter + 8'd1;
  end
  assign o_rst_done = (rst_counter == 8'hFF);


endmodule : cpu_ooo
