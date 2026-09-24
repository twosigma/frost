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
 * Validity and control-flow tracker for the in-order IF/PD/ID front end.
 *
 * Valid tracking: the if_valid_q/pd_valid_q chain follows IF's sel_nop and
 * the post-flush holdoff, so the NOP bubbles inserted on flush and reset are
 * never dispatched. It yields the preflush two-wide dispatch candidates, which
 * carry no recovery kill (dispatch applies it), and flush-qualified copies
 * (o_id_valid, o_id_valid_2) for debug and assertions. cpu_ooo uses these
 * four outputs only without a decoded queue (DECODED_QUEUE_DEPTH = 0); the
 * queued build derives dispatch validity from o_pd_valid_q and the queue.
 *
 * Control-flow detection: finds unpredicted control flow in IF, PD, and ID.
 * An unpredicted indirect jump feeds ooo_pipeline_control's control-flow
 * serialization stall; the prediction-fence classes feed the perf counters.
 * PD bubbles arrive as from_pd_to_id.inject_nop, not as a rewritten
 * instruction.
 */

module frontend_validity_tracker (
    input logic i_clk,
    input logic i_rst,

    input riscv_pkg::pipeline_ctrl_t       i_pipeline_ctrl,
    input riscv_pkg::from_if_to_pd_t       i_from_if_to_pd,
    // Slot-1 control-flow class from IF's native/compressed predecode, gated
    // by bubbles and aligned with stall replay.
    input logic                            i_if_has_control_flow,
    input riscv_pkg::from_pd_to_id_t       i_from_pd_to_id,
    input riscv_pkg::from_id_to_ex_t       i_from_id_to_ex,
    input riscv_pkg::from_id_to_ex_t       i_from_id_to_ex_2,
    input logic                      [1:0] i_post_flush_holdoff_q,
    input logic                            i_dispatch_flush,
    input logic                            i_id_stall_q,
    input logic                            i_replay_after_dispatch_stall_q,
    input logic                            i_flush_pipeline,
    // Debug Mode single step: allocate user NOP bundles too, so
    // a step over a nop retires exactly that nop. Outside stepping FROST
    // drops all-NOP bundles at ID and never retires them.
    input logic                            i_keep_nops,

    output logic o_if_valid_q,
    output logic o_pd_valid_q,
    output logic o_id_valid_preflush,
    output logic o_id_valid_2_preflush,
    output logic o_id_valid,
    output logic o_id_valid_2,
    output logic o_pd_unpredicted_control_flow,
    output logic o_id_unpredicted_control_flow,
    output logic o_front_end_indirect_control_flow_pending,
    output logic o_prediction_fence_branch,
    output logic o_prediction_fence_jal,
    output logic o_prediction_fence_indirect
);

  // --- Port aliases: local names for the inputs.
  riscv_pkg::pipeline_ctrl_t       pipeline_ctrl;
  riscv_pkg::from_if_to_pd_t       from_if_to_pd;
  riscv_pkg::from_pd_to_id_t       from_pd_to_id;
  riscv_pkg::from_id_to_ex_t       from_id_to_ex;
  riscv_pkg::from_id_to_ex_t       from_id_to_ex_2;
  logic                      [1:0] post_flush_holdoff_q;
  logic                            dispatch_flush;
  logic                            id_stall_q;
  logic                            replay_after_dispatch_stall_q;
  logic                            flush_pipeline;
  assign pipeline_ctrl = i_pipeline_ctrl;
  assign from_if_to_pd = i_from_if_to_pd;
  assign from_pd_to_id = i_from_pd_to_id;
  // TIMING: pd_stage does not rewrite a bubble's instruction into a NOP; it
  // passes a registered inject_nop marker. Substitute the NOP opcode (OP_IMM)
  // for bubbles so the control-flow detection below treats them as NOPs.
  wire [6:0] pd_effective_opcode =
      from_pd_to_id.inject_nop ? riscv_pkg::OPC_OP_IMM : from_pd_to_id.instruction[6:0];
  assign from_id_to_ex                 = i_from_id_to_ex;
  assign from_id_to_ex_2               = i_from_id_to_ex_2;
  assign post_flush_holdoff_q          = i_post_flush_holdoff_q;
  assign dispatch_flush                = i_dispatch_flush;
  assign id_stall_q                    = i_id_stall_q;
  assign replay_after_dispatch_stall_q = i_replay_after_dispatch_stall_q;
  assign flush_pipeline                = i_flush_pipeline;

  logic if_valid_q;  // tracks valid at IF→PD boundary
  logic pd_valid_q;  // tracks valid at PD→ID boundary

  // Track IF stage's sel_nop through the pipeline to know when from_id_to_ex
  // contains a real instruction vs a NOP bubble (holdoff/flush/reset).
  // 2-stage chain: if_valid_q captures at PD register edge, pd_valid_q
  // captures at ID register edge, which is when from_id_to_ex is updated.
  always_ff @(posedge i_clk) begin
    if (i_rst || pipeline_ctrl.flush) begin
      if_valid_q <= 1'b0;
      pd_valid_q <= 1'b0;
    end else if (!pipeline_ctrl.stall) begin
      if_valid_q <= !from_if_to_pd.sel_nop && (post_flush_holdoff_q == 2'd0);
      pd_valid_q <= if_valid_q;
    end
  end

  // The preflush candidates read the registered stall directly instead of
  // pipeline_ctrl fields. This breaks a false Verilator UNOPTFLAT cycle
  // (pipeline_ctrl.stall depends on dispatch_stall, which depends on these
  // candidates). Dispatch applies the recovery kill itself (its i_flush);
  // id_valid and id_valid_2 below are flush-qualified copies for debug and
  // assertions. Reset clears pd_valid_q above and has priority in the
  // stateful consumers, so i_rst stays out of the dispatch allocation logic.
  logic id_valid_preflush;
  logic id_valid_2_preflush;
  logic id_valid;
  logic id_valid_2;
  // 2-wide: the NOP filter must consider both slots. A bundle whose slot 1 is
  // a user NOP (such as a c.nop, which expands to `addi x0, x0, 0`) but whose
  // slot 2 carries a real instruction must still dispatch: IF has already
  // moved past both, so dropping the bundle would lose the slot-2
  // instruction. Treat the bundle as valid when either slot has a non-NOP
  // instruction. Dispatch handles a slot-1 NOP harmlessly: alloc to ROB, no
  // dest, no rename, silent retire.
  // TIMING: the check uses id_stage's registered `is_not_nop` flags rather
  // than a 32-bit compare against the NOP encoding here, which would put
  // slot 2's instruction bits into dispatch_stall and the RS write-enable
  // logic.
  logic id_valid_base_preflush;
  // id_stall_q covers the whole CSR serialization window for the dispatch
  // valid: pipeline control sets it on the edge where a CSR allocates, and the
  // registered front-end stall keeps it high until the release. This keeps
  // the live csr_in_flight bit out of every allocation enable;
  // ooo_pipeline_control asserts that the result equals gating on
  // csr_in_flight directly.
  assign id_valid_base_preflush = pd_valid_q &&
      // Re-dispatch the held ID image after real backpressure stalls,
      // and after CSR serialization fences. The CSR itself has already
      // allocated before the registered front-end stall rises; the held ID
      // image during the fence is the younger blocked instruction that still
      // needs exactly one valid replay cycle after the fence drops. CSR-release
      // replay is normally encoded by clearing id_stall_q one cycle early. If an
      // independent front-end stall prevented ID from advancing on the CSR's
      // allocation cycle, pipeline control instead keeps id_stall_q high for
      // one advance-only release cycle so the held CSR cannot re-dispatch.
      // Dispatch-stall replay still needs an explicit pulse because the
      // resource stall's release cannot be known until this cycle.
      (!id_stall_q || replay_after_dispatch_stall_q);
  // i_keep_nops (single step) keeps a real all-NOP bundle: the base has already
  // excluded injected bubbles, so only user NOPs get through.
  assign id_valid_preflush = id_valid_base_preflush &&
      (from_id_to_ex.is_not_nop || from_id_to_ex_2.is_not_nop || i_keep_nops);

  // Slot 2 is a candidate only when the bundle's base candidate is (the
  // bundle stalls and dispatches as a unit) and slot 2 holds a non-NOP
  // instruction. The recovery kill is applied separately, by dispatch and in
  // id_valid_2 below.
  assign id_valid_2_preflush = id_valid_base_preflush && from_id_to_ex_2.is_not_nop;

  assign id_valid = id_valid_preflush && !dispatch_flush;
  assign id_valid_2 = id_valid_2_preflush && !dispatch_flush;

`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown(
            {id_valid_preflush, id_valid_2_preflush, dispatch_flush, id_valid, id_valid_2}
        )) begin
      p_id_valid_recovery_qualification_exact :
      assert (id_valid == (id_valid_preflush && !dispatch_flush));
      p_id_valid_2_recovery_qualification_exact :
      assert (id_valid_2 == (id_valid_2_preflush && !dispatch_flush));
    end
  end
`endif

  logic if_has_control_flow;
  logic if_has_indirect_control_flow;
  logic pd_has_control_flow;
  logic pd_has_indirect_control_flow;
  logic id_has_control_flow;
  logic id_has_indirect_control_flow;

  // JALR, or C.JR/C.JALR (quadrant 2, funct4 100x, rs1 != 0, rs2 = 0), from
  // IF's raw slot-1 parcel; never for a bubble.
  function automatic logic if_stage_has_indirect_control_flow(
      input riscv_pkg::from_if_to_pd_t if_pkt);
    logic [15:0] parcel;
    logic [ 1:0] c_op;
    logic [ 3:0] c_funct4;
    logic [4:0] c_rs1, c_rs2;
    begin
      parcel = if_pkt.raw_parcel;
      c_op = parcel[1:0];
      c_funct4 = parcel[15:12];
      c_rs1 = parcel[11:7];
      c_rs2 = parcel[6:2];

      if_stage_has_indirect_control_flow = 1'b0;
      if (!if_pkt.sel_nop) begin
        if_stage_has_indirect_control_flow =
            (parcel[6:0] == riscv_pkg::OPC_JALR) ||
            ((c_op == 2'b10) &&
             (c_rs2 == 5'b00000) &&
             (c_rs1 != 5'b00000) &&
             ((c_funct4 == 4'b1000) || (c_funct4 == 4'b1001)));
      end
    end
  endfunction

  assign if_has_control_flow = i_if_has_control_flow;
  assign if_has_indirect_control_flow = if_stage_has_indirect_control_flow(from_if_to_pd);
  assign pd_has_control_flow = if_valid_q &&
                               ((pd_effective_opcode == riscv_pkg::OPC_BRANCH) ||
                                (pd_effective_opcode == riscv_pkg::OPC_JAL) ||
                                (pd_effective_opcode == riscv_pkg::OPC_JALR));
  assign pd_has_indirect_control_flow = if_valid_q && (pd_effective_opcode == riscv_pkg::OPC_JALR);
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

  // Only unpredicted control flow is flagged: control flow for which fetch did
  // not follow a taken prediction (btb_predicted_taken and ras_predicted both
  // clear). A branch predicted not taken is therefore flagged. An unpredicted
  // indirect jump feeds the control-flow serialization stall, and the
  // prediction-fence classes below (unpredicted branch, JAL, or indirect jump
  // in PD or ID) feed the perf counters.
  // The IF-stage flag, if_unpredicted_control_flow_q, is registered, so it
  // trails IF by one cycle. That is harmless: the serialization fence is a
  // performance hint.
  // TIMING: the late BTB-prediction bit is registered separately, off the
  // control-flow qualifier's D input. Both registers load every edge, so
  // their conjunction equals a single register of the whole predicate,
  // including reset/flush and stalled cycles (checked below). The qualifier
  // clears on reset/flush; the BTB register needs no reset because it is
  // masked while the qualifier is clear. Only synchronous pipeline control
  // consumes the result.
  (* keep = "true" *)logic if_control_flow_without_btb_q;
  (* keep = "true" *)logic if_btb_predicted_taken_q;
  logic if_unpredicted_control_flow_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) if_control_flow_without_btb_q <= 1'b0;
    else if_control_flow_without_btb_q <= if_has_control_flow && !from_if_to_pd.ras_predicted;
    if_btb_predicted_taken_q <= from_if_to_pd.btb_predicted_taken;
  end
  assign if_unpredicted_control_flow_q = if_control_flow_without_btb_q && !if_btb_predicted_taken_q;

`ifndef SYNTHESIS
  // Reference: the whole predicate in one register, compared with the split
  // form on every edge.
  logic if_unpredicted_control_flow_legacy_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) if_unpredicted_control_flow_legacy_q <= 1'b0;
    else
      if_unpredicted_control_flow_legacy_q <= if_has_control_flow &&
          !(from_if_to_pd.btb_predicted_taken || from_if_to_pd.ras_predicted);
    if (!$isunknown({if_unpredicted_control_flow_q, if_unpredicted_control_flow_legacy_q})) begin
      p_split_unpredicted_control_flow_matches_original :
      assert (if_unpredicted_control_flow_q == if_unpredicted_control_flow_legacy_q);
    end
  end
`endif
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
                                 (pd_effective_opcode == riscv_pkg::OPC_BRANCH);
  assign pd_unpredicted_jal = pd_unpredicted_control_flow &&
                              (pd_effective_opcode == riscv_pkg::OPC_JAL);
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
  assign o_id_valid_preflush                       = id_valid_preflush;
  assign o_id_valid_2_preflush                     = id_valid_2_preflush;
  assign o_id_valid                                = id_valid;
  assign o_id_valid_2                              = id_valid_2;
  assign o_pd_unpredicted_control_flow             = pd_unpredicted_control_flow;
  assign o_id_unpredicted_control_flow             = id_unpredicted_control_flow;
  assign o_front_end_indirect_control_flow_pending = front_end_indirect_control_flow_pending;
  assign o_prediction_fence_branch                 = prediction_fence_branch;
  assign o_prediction_fence_jal                    = prediction_fence_jal;
  assign o_prediction_fence_indirect               = prediction_fence_indirect;

endmodule : frontend_validity_tracker
