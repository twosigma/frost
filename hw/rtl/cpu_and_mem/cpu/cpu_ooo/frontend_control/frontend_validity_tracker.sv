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
 * Front-end instruction-validity + control-flow tracker.
 *
 * Two jobs, both about the shared in-order IF/PD/ID front-end feeding the OOO
 * back-end:
 *   1. Valid tracking: a staged if_valid_q/pd_valid_q chain (plus the post-flush
 *      holdoff) so NOP bubbles inserted on flush/reset are never dispatched, and
 *      the id_valid / id_valid_2 dispatch-enables for the 2-wide bundle.
 *   2. Control-flow detection: classify IF/PD/ID instructions as
 *      (indirect) control flow and whether they are *unpredicted*, producing the
 *      front-end serialization / prediction-fence hints consumed by the pipeline
 *      control logic and the perf counters.
 *
 * Extracted verbatim from cpu_ooo (no functional change): the body below is the
 * former "Instruction Validity" section, with the parent's signals presented as
 * ports and aliased back to their original names. The dbg_* mirror assigns stay
 * in cpu_ooo (they tap the if_valid_q/pd_valid_q/id_valid outputs).
 */

module frontend_validity_tracker (
    input logic i_clk,
    input logic i_rst,

    input riscv_pkg::pipeline_ctrl_t       i_pipeline_ctrl,
    input riscv_pkg::from_if_to_pd_t       i_from_if_to_pd,
    input riscv_pkg::from_pd_to_id_t       i_from_pd_to_id,
    input riscv_pkg::from_id_to_ex_t       i_from_id_to_ex,
    input riscv_pkg::from_id_to_ex_t       i_from_id_to_ex_2,
    input logic                      [1:0] i_post_flush_holdoff_q,
    input logic                            i_dispatch_flush,
    input logic                            i_csr_in_flight,
    input logic                            i_id_stall_q,
    input logic                            i_replay_after_dispatch_stall_q,
    input logic                            i_flush_pipeline,

    output logic o_if_valid_q,
    output logic o_pd_valid_q,
    output logic o_id_valid,
    output logic o_id_valid_2,
    output logic o_pd_unpredicted_control_flow,
    output logic o_id_unpredicted_control_flow,
    output logic o_front_end_indirect_control_flow_pending,
    output logic o_prediction_fence_branch,
    output logic o_prediction_fence_jal,
    output logic o_prediction_fence_indirect
);

  // --- Port aliases: keep the extracted body identical to the cpu_ooo original.
  riscv_pkg::pipeline_ctrl_t       pipeline_ctrl;
  riscv_pkg::from_if_to_pd_t       from_if_to_pd;
  riscv_pkg::from_pd_to_id_t       from_pd_to_id;
  riscv_pkg::from_id_to_ex_t       from_id_to_ex;
  riscv_pkg::from_id_to_ex_t       from_id_to_ex_2;
  logic                      [1:0] post_flush_holdoff_q;
  logic                            dispatch_flush;
  logic                            csr_in_flight;
  logic                            id_stall_q;
  logic                            replay_after_dispatch_stall_q;
  logic                            flush_pipeline;
  assign pipeline_ctrl                 = i_pipeline_ctrl;
  assign from_if_to_pd                 = i_from_if_to_pd;
  assign from_pd_to_id                 = i_from_pd_to_id;
  assign from_id_to_ex                 = i_from_id_to_ex;
  assign from_id_to_ex_2               = i_from_id_to_ex_2;
  assign post_flush_holdoff_q          = i_post_flush_holdoff_q;
  assign dispatch_flush                = i_dispatch_flush;
  assign csr_in_flight                 = i_csr_in_flight;
  assign id_stall_q                    = i_id_stall_q;
  assign replay_after_dispatch_stall_q = i_replay_after_dispatch_stall_q;
  assign flush_pipeline                = i_flush_pipeline;

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

  // id_valid: reads dispatch_flush/id_stall_q directly instead of
  // pipeline_ctrl fields.  This breaks a false Verilator UNOPTFLAT cycle
  // (pipeline_ctrl.stall depends on dispatch_stall which depends on
  // id_valid, but id_valid only needs the registered stall plus the
  // commit-mispredict dispatch kill, which are independent of dispatch_stall).
  // Reset clears pd_valid_q in the IF/PD valid tracker and has priority in the
  // stateful consumers, so keep i_rst out of the dispatch allocation cone.
  logic id_valid;
  // 2-wide: NOP-filter must consider both slots.  A bundle whose slot-1 is a
  // user-written c.nop (decompressed to `addi x0, x0, 0`) but whose slot-2
  // carries a real instruction must still dispatch — otherwise the front-end
  // has already advanced PC by +4 (because slot2_valid was 1 in IF) and the
  // slot-2 instruction is silently dropped.  Treat the bundle as valid when
  // EITHER slot has a non-NOP instruction; dispatch handles slot-1 c.nop
  // harmlessly (alloc to ROB, no dest, no rename, silent retire).
  // The NOP-presence check uses the registered `is_not_nop` flag computed in
  // id_stage instead of a 32-bit instruction-vs-NOP compare here.  Without
  // this, `instruction.source_reg_1[*]` of slot-2 had fanout-364 into
  // dispatch_stall and the RS-write CE cone (post-synth WNS=-1.523ns).
  logic id_valid_base;
  assign id_valid_base = pd_valid_q && !dispatch_flush && !csr_in_flight &&
      // Re-dispatch the held ID image after real backpressure stalls,
      // and after CSR serialization fences. The CSR itself has already
      // allocated before csr_in_flight rises; the held ID image during the
      // fence is the younger blocked instruction that still needs exactly
      // one valid replay cycle after the fence drops. CSR-release replay is
      // encoded by clearing id_stall_q one cycle early above; dispatch-stall
      // replay still needs an explicit pulse because the resource stall's
      // release cannot be known until this cycle.
      (!id_stall_q || replay_after_dispatch_stall_q);
  assign id_valid = id_valid_base && (from_id_to_ex.is_not_nop || from_id_to_ex_2.is_not_nop);

  // Slot-2 valid: piggybacks on id_valid (slot-2 always requires slot-1 to
  // also be valid this cycle — bundle constraint, decision #2 monolithic
  // stall).  The is_not_nop check gates id_valid_2 to '1 whenever IF supplied
  // a real second instruction; it stays '0 only when the bundle has no valid
  // slot-2 this cycle (the slot-2 path then carries a NOP).
  logic id_valid_2;
  assign id_valid_2 = id_valid_base && from_id_to_ex_2.is_not_nop;

  logic if_has_control_flow;
  logic if_has_indirect_control_flow;
  logic pd_has_control_flow;
  logic pd_has_indirect_control_flow;
  logic id_has_control_flow;
  logic id_has_indirect_control_flow;

  function automatic logic if_stage_has_control_flow(input riscv_pkg::from_if_to_pd_t if_pkt);
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

  function automatic logic if_stage_has_indirect_control_flow(
      input riscv_pkg::from_if_to_pd_t if_pkt);
    logic [15:0] c_instr;
    logic [ 1:0] c_op;
    logic [ 3:0] c_funct4;
    logic [4:0] c_rs1, c_rs2;
    begin
      if_stage_has_indirect_control_flow = 1'b0;
      if (!if_pkt.sel_nop) begin
        if (if_pkt.sel_compressed) begin
          c_instr = if_pkt.effective_instr[15:0];
          c_op = c_instr[1:0];
          c_funct4 = c_instr[15:12];
          c_rs1 = c_instr[11:7];
          c_rs2 = c_instr[6:2];
          if_stage_has_indirect_control_flow = ((c_op == 2'b10) &&
                                                (c_rs2 == 5'b00000) &&
                                                (c_rs1 != 5'b00000) &&
                                                ((c_funct4 == 4'b1000) ||
                                                 (c_funct4 == 4'b1001)));
        end else begin
          if_stage_has_indirect_control_flow = (if_pkt.effective_instr[6:0] == riscv_pkg::OPC_JALR);
        end
      end
    end
  endfunction

  assign if_has_control_flow = if_stage_has_control_flow(from_if_to_pd);
  assign if_has_indirect_control_flow = if_stage_has_indirect_control_flow(from_if_to_pd);
  assign pd_has_control_flow = if_valid_q &&
                               ((from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_BRANCH) ||
                                (from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_JAL) ||
                                (from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_JALR));
  assign pd_has_indirect_control_flow = if_valid_q &&
                                        (from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_JALR);
  assign id_has_control_flow = pd_valid_q && (
      from_id_to_ex.instruction_operation == riscv_pkg::BEQ ||
      from_id_to_ex.instruction_operation == riscv_pkg::BNE ||
      from_id_to_ex.instruction_operation == riscv_pkg::BLT ||
      from_id_to_ex.instruction_operation == riscv_pkg::BGE ||
      from_id_to_ex.instruction_operation == riscv_pkg::BLTU ||
      from_id_to_ex.instruction_operation == riscv_pkg::BGEU ||
      from_id_to_ex.instruction_operation == riscv_pkg::JAL ||
      from_id_to_ex.instruction_operation == riscv_pkg::JALR
  );
  assign id_has_indirect_control_flow = pd_valid_q &&
                                        (from_id_to_ex.instruction_operation == riscv_pkg::JALR);

  // Only unpredicted front-end control flow needs the extra prediction fence.
  // Once an older branch/return has already redirected fetch onto its predicted
  // path, later predictions on that same path are expected and required for
  // tight loops. Treating already-predicted IF/PD/ID control-flow ops as
  // "pending" shuts prediction back off and creates a second unpredicted copy
  // of the same branch, which is exactly what breaks compressed back-edge loops.
  // IF-stage control flow detection is registered to break a combinational
  // loop: pipeline_ctrl.stall → IF stage (c_ext_state, aligner, prediction
  // metadata) → from_if_to_pd → front_end_control_flow_pending →
  // front_end_cf_serialize_stall → pipeline_ctrl.stall.  One cycle of
  // latency is harmless — the serialization fence is a performance hint.
  logic if_unpredicted_control_flow_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) if_unpredicted_control_flow_q <= 1'b0;
    else
      if_unpredicted_control_flow_q <= if_has_control_flow &&
                                       !(from_if_to_pd.btb_predicted_taken ||
                                         from_if_to_pd.ras_predicted);
  end
  logic if_unpredicted_control_flow;
  logic if_unpredicted_indirect_control_flow;
  logic pd_unpredicted_control_flow;
  logic pd_unpredicted_indirect_control_flow;
  logic pd_unpredicted_branch;
  logic pd_unpredicted_jal;
  logic id_unpredicted_control_flow;
  logic id_unpredicted_indirect_control_flow;
  logic id_unpredicted_branch;
  logic id_unpredicted_jal;
  logic front_end_control_flow_pending;
  logic front_end_indirect_control_flow_pending;
  logic prediction_fence_branch;
  logic prediction_fence_jal;
  logic prediction_fence_indirect;
  assign if_unpredicted_control_flow = if_unpredicted_control_flow_q;
  assign if_unpredicted_indirect_control_flow = if_unpredicted_control_flow_q &&
                                                if_has_indirect_control_flow;
  assign pd_unpredicted_control_flow = pd_has_control_flow &&
                                       !(from_pd_to_id.btb_predicted_taken ||
                                         from_pd_to_id.ras_predicted);
  assign pd_unpredicted_indirect_control_flow = pd_has_indirect_control_flow &&
                                                !(from_pd_to_id.btb_predicted_taken ||
                                                  from_pd_to_id.ras_predicted);
  assign pd_unpredicted_branch = pd_unpredicted_control_flow &&
                                 (from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_BRANCH);
  assign pd_unpredicted_jal = pd_unpredicted_control_flow &&
                              (from_pd_to_id.instruction[6:0] == riscv_pkg::OPC_JAL);
  assign id_unpredicted_control_flow = id_has_control_flow &&
                                       !(from_id_to_ex.btb_predicted_taken ||
                                         from_id_to_ex.ras_predicted);
  assign id_unpredicted_indirect_control_flow = id_has_indirect_control_flow &&
                                                !(from_id_to_ex.btb_predicted_taken ||
                                                  from_id_to_ex.ras_predicted);
  assign id_unpredicted_branch = id_unpredicted_control_flow && (
      from_id_to_ex.instruction_operation == riscv_pkg::BEQ ||
      from_id_to_ex.instruction_operation == riscv_pkg::BNE ||
      from_id_to_ex.instruction_operation == riscv_pkg::BLT ||
      from_id_to_ex.instruction_operation == riscv_pkg::BGE ||
      from_id_to_ex.instruction_operation == riscv_pkg::BLTU ||
      from_id_to_ex.instruction_operation == riscv_pkg::BGEU
  );
  assign id_unpredicted_jal = id_unpredicted_control_flow &&
                              (from_id_to_ex.instruction_operation == riscv_pkg::JAL);
  assign front_end_control_flow_pending = if_unpredicted_control_flow ||
                                          pd_unpredicted_control_flow ||
                                          id_unpredicted_control_flow;
  assign front_end_indirect_control_flow_pending = if_unpredicted_indirect_control_flow ||
                                                   pd_unpredicted_indirect_control_flow ||
                                                   id_unpredicted_indirect_control_flow;
  always_comb begin
    prediction_fence_branch = 1'b0;
    prediction_fence_jal = 1'b0;
    prediction_fence_indirect = 1'b0;
    if (id_unpredicted_indirect_control_flow) begin
      prediction_fence_indirect = 1'b1;
    end else if (id_unpredicted_jal) begin
      prediction_fence_jal = 1'b1;
    end else if (id_unpredicted_branch) begin
      prediction_fence_branch = 1'b1;
    end else if (pd_unpredicted_indirect_control_flow) begin
      prediction_fence_indirect = 1'b1;
    end else if (pd_unpredicted_jal) begin
      prediction_fence_jal = 1'b1;
    end else if (pd_unpredicted_branch) begin
      prediction_fence_branch = 1'b1;
    end
  end

  // --- Output wiring.
  assign o_if_valid_q                              = if_valid_q;
  assign o_pd_valid_q                              = pd_valid_q;
  assign o_id_valid                                = id_valid;
  assign o_id_valid_2                              = id_valid_2;
  assign o_pd_unpredicted_control_flow             = pd_unpredicted_control_flow;
  assign o_id_unpredicted_control_flow             = id_unpredicted_control_flow;
  assign o_front_end_indirect_control_flow_pending = front_end_indirect_control_flow_pending;
  assign o_prediction_fence_branch                 = prediction_fence_branch;
  assign o_prediction_fence_jal                    = prediction_fence_jal;
  assign o_prediction_fence_indirect               = prediction_fence_indirect;

endmodule : frontend_validity_tracker
