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
 * Control-flow detection: finds unpredicted indirect jumps in slot 1 of IF,
 * PD, and ID for ooo_pipeline_control's control-flow serialization stall, and
 * classifies unpredicted control flow in PD and ID for the perf counters. PD
 * bubbles arrive as from_pd_to_id.inject_nop, not as a rewritten instruction.
 */

module frontend_validity_tracker (
    input logic i_clk,
    input logic i_rst,

    input riscv_pkg::pipeline_ctrl_t       i_pipeline_ctrl,
    input riscv_pkg::from_if_to_pd_t       i_from_if_to_pd,
    // Slot-1 control-flow class from IF's native/compressed predecode, gated
    // by bubbles and aligned with stall replay.
    input logic                            i_if_has_control_flow,
    // Slot-1 indirect-jump class (JALR, C.JR, C.JALR) from IF's predecode
    // sideband, aligned with stall replay; not gated by bubbles.
    input logic                            i_if_is_indirect,
    input riscv_pkg::from_pd_to_id_t       i_from_pd_to_id,
    input riscv_pkg::from_id_to_ex_t       i_from_id_to_ex,
    input riscv_pkg::from_id_to_ex_t       i_from_id_to_ex_2,
    input logic                      [1:0] i_post_flush_holdoff_q,
    input logic                            i_dispatch_flush,
    input logic                            i_id_stall_q,
    input logic                            i_replay_after_dispatch_stall_q,
    input logic                            i_flush_pipeline,

    output logic o_if_valid_q,
    output logic o_pd_valid_q,
    output logic o_id_valid_preflush,
    output logic o_id_valid_2_preflush,
    output logic o_id_valid,
    output logic o_id_valid_2,
    output logic o_front_end_indirect_control_flow_pending,
    output logic o_prediction_fence_branch,
    output logic o_prediction_fence_jal,
    output logic o_prediction_fence_indirect
);

  // Port aliases.
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
  // PD marks bubbles with inject_nop without rewriting the instruction.
  // Substitute OP_IMM so control-flow detection treats them as NOPs.
  wire [6:0] pd_effective_opcode =
      from_pd_to_id.inject_nop ? riscv_pkg::OPC_OP_IMM : from_pd_to_id.instruction[6:0];
  assign from_id_to_ex                 = i_from_id_to_ex;
  assign from_id_to_ex_2               = i_from_id_to_ex_2;
  assign post_flush_holdoff_q          = i_post_flush_holdoff_q;
  assign dispatch_flush                = i_dispatch_flush;
  assign id_stall_q                    = i_id_stall_q;
  assign replay_after_dispatch_stall_q = i_replay_after_dispatch_stall_q;
  assign flush_pipeline                = i_flush_pipeline;

  logic if_valid_q;  // Valid at the IF-to-PD boundary
  logic pd_valid_q;  // Valid at the PD-to-ID boundary

  // Track real instructions through PD and ID; reset and flush clear both
  // valid bits. if_valid_q loads with PD and pd_valid_q loads with ID.
  always_ff @(posedge i_clk) begin
    if (i_rst || pipeline_ctrl.flush) begin
      if_valid_q <= 1'b0;
      pd_valid_q <= 1'b0;
    end else if (!pipeline_ctrl.stall) begin
      if_valid_q <= !from_if_to_pd.sel_nop && (post_flush_holdoff_q == 2'd0);
      pd_valid_q <= if_valid_q;
    end
  end

  // Use registered stall directly to avoid a false Verilator UNOPTFLAT loop
  // through pipeline_ctrl.stall and dispatch_stall. Dispatch applies recovery
  // kill; id_valid and id_valid_2 are flush-qualified debug copies. Reset
  // clears pd_valid_q and takes priority in stateful consumers.
  logic id_valid_preflush;
  logic id_valid_2_preflush;
  logic id_valid;
  logic id_valid_2;
  // Either real slot makes the atomic bundle valid. is_real excludes PD
  // redirect bubbles; the base excludes flush, reset, and sel_nop bubbles.
  // A program NOP is real and must dispatch, retire, and increment instret.
  logic id_valid_base_preflush;
  // id_stall_q spans CSR serialization: it sets when a CSR allocates and
  // stays high until release, so validity needs no live csr_in_flight gate.
  assign id_valid_base_preflush = pd_valid_q &&
      // Replay a held younger instruction after backpressure or a CSR fence.
      // CSR release normally clears id_stall_q one cycle early. If another
      // stall held ID on CSR allocation, keep id_stall_q high for one
      // advance-only cycle to avoid redispatching that CSR. Resource-stall
      // release needs an explicit replay pulse.
      (!id_stall_q || replay_after_dispatch_stall_q);
  assign id_valid_preflush = id_valid_base_preflush &&
      (from_id_to_ex.is_real || from_id_to_ex_2.is_real);

  // Slot 2 shares the bundle's base validity and must also be real. Dispatch
  // applies recovery kill; id_valid_2 is the flush-qualified copy.
  assign id_valid_2_preflush = id_valid_base_preflush && from_id_to_ex_2.is_real;

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

`ifndef SYNTHESIS
  // JALR, or C.JR/C.JALR (quadrant 2, funct4 100x, rs1 != 0, rs2 = 0), from
  // IF's raw slot-1 parcel; never for a bubble. Simulation reference for the
  // predecoded i_if_is_indirect.
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
`endif

  assign if_has_control_flow = i_if_has_control_flow;
  assign if_has_indirect_control_flow = !from_if_to_pd.sel_nop && i_if_is_indirect;
`ifndef SYNTHESIS
  // Sampled at the clock so the check sees settled values.
  always_ff @(posedge i_clk) begin
    if (!i_rst && !$isunknown(
            {from_if_to_pd.sel_nop, from_if_to_pd.raw_parcel, i_if_is_indirect}
        )) begin
      p_if_indirect_predecode_exact :
      assert (if_has_indirect_control_flow == if_stage_has_indirect_control_flow(from_if_to_pd));
    end
  end
`endif
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

  // Flag control flow without a taken prediction, including branches
  // predicted not taken. Unpredicted slot-1 indirect jumps stall serialization;
  // PD and ID classes also feed the performance counters.
  //
  // Register the IF term for timing. After an unstalled edge, PD covers that
  // packet, so use the IF term only when stall_registered is set. Register
  // class and prediction separately on the same edge; their conjunction equals
  // the registered predicate. Clearing the class on reset or flush masks the
  // unreset prediction bit. Only synchronous pipeline control uses the result.
  (* keep = "true" *)logic if_indirect_q;
  (* keep = "true" *)logic if_btb_predicted_taken_q;
  logic if_unpredicted_indirect_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) if_indirect_q <= 1'b0;
    else if_indirect_q <= if_has_control_flow && if_has_indirect_control_flow;
    if_btb_predicted_taken_q <= from_if_to_pd.btb_predicted_taken;
  end
  assign if_unpredicted_indirect_q = if_indirect_q && !if_btb_predicted_taken_q;

`ifndef SYNTHESIS
  // Reference: the whole predicate in one register, compared with the split
  // form on every edge.
  logic if_unpredicted_indirect_reference_q;
  always_ff @(posedge i_clk) begin
    if (i_rst || flush_pipeline) if_unpredicted_indirect_reference_q <= 1'b0;
    else
      if_unpredicted_indirect_reference_q <= if_has_control_flow && if_has_indirect_control_flow &&
          !from_if_to_pd.btb_predicted_taken;
    if (!$isunknown({if_unpredicted_indirect_q, if_unpredicted_indirect_reference_q})) begin
      p_split_if_unpredicted_indirect_matches_reference :
      assert (if_unpredicted_indirect_q == if_unpredicted_indirect_reference_q);
    end
  end
`endif
  logic if_unpredicted_indirect_control_flow;
  logic pd_unpredicted_control_flow;
  logic pd_unpredicted_indirect_control_flow;
  logic pd_unpredicted_branch;
  logic pd_unpredicted_jal;
  logic id_unpredicted_control_flow;
  logic id_unpredicted_indirect_control_flow;
  logic id_unpredicted_branch;
  logic id_unpredicted_jal;
  logic front_end_indirect_control_flow_pending;
  logic prediction_fence_branch;
  logic prediction_fence_jal;
  logic prediction_fence_indirect;
  assign if_unpredicted_indirect_control_flow = if_unpredicted_indirect_q &&
                                                pipeline_ctrl.stall_registered;
  assign pd_unpredicted_control_flow = pd_has_control_flow && !from_pd_to_id.btb_predicted_taken;
  assign pd_unpredicted_indirect_control_flow = pd_has_indirect_control_flow &&
                                                !from_pd_to_id.btb_predicted_taken;
  assign pd_unpredicted_branch = pd_unpredicted_control_flow &&
                                 (pd_effective_opcode == riscv_pkg::OPC_BRANCH);
  assign pd_unpredicted_jal = pd_unpredicted_control_flow &&
                              (pd_effective_opcode == riscv_pkg::OPC_JAL);
  assign id_unpredicted_control_flow = id_has_control_flow && !from_id_to_ex.btb_predicted_taken;
  assign id_unpredicted_indirect_control_flow = id_has_indirect_control_flow &&
                                                !from_id_to_ex.btb_predicted_taken;
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
  assign o_front_end_indirect_control_flow_pending = front_end_indirect_control_flow_pending;
  assign o_prediction_fence_branch                 = prediction_fence_branch;
  assign o_prediction_fence_jal                    = prediction_fence_jal;
  assign o_prediction_fence_indirect               = prediction_fence_indirect;

endmodule : frontend_validity_tracker
