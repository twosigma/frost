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

// Prove that FP_RS's engine-gate opcode classification (rs_is_divide_op with
// FP_ENGINE_GATE=1) and fp_shim's pipelined opcode classification
// (!fp_op_pipelined with PIPELINE=1) agree for every instr_op_e bit pattern.
module fp_engine_op_formal (
    input logic i_clk,
    input logic i_rst_n,
    input logic [$bits(riscv_pkg::instr_op_e)-1:0] i_op_bits
);
  riscv_pkg::instr_op_e op;
  assign op = riscv_pkg::instr_op_e'(i_op_bits);

  riscv_pkg::rs_dispatch_t rs_disp, rs_disp_2;
  riscv_pkg::rs_issue_t shim_issue;
  always_comb begin
    rs_disp = '0;
    rs_disp.op = op;
    rs_disp_2 = '0;
    rs_disp_2.op = op;
    shim_issue = '0;
    shim_issue.valid = 1'b1;
    shim_issue.op = op;
  end

  reservation_station #(
      .DEPTH(riscv_pkg::FpRsDepth),
      .HAS_SRC3(1'b1),
      .FORMAL_STANDALONE_ENV(1'b0),
      .ISSUE_REPAIR_BYPASS(1'b0),
      .DIVIDE_ISSUE_GATE(1'b1),
      .FP_ENGINE_GATE(1'b1),
      .FWD_WAKE(1'b1)
  ) u_fp_rs (
      .i_clk(i_clk),
      .i_rst_n(i_rst_n),
      .i_dispatch(rs_disp),
      .i_dispatch_2(rs_disp_2),
      .i_intent_1(1'b0),
      .o_full(),
      .o_full_for_2(),
      .i_cdb('0),
      .i_cdb_2('0),
      .i_issue_cdb_valid(1'b0),
      .i_issue_cdb_tag('0),
      .i_issue_cdb_2_valid(1'b0),
      .i_issue_cdb_2_tag('0),
      .i_repair_valid_1(1'b0),
      .i_repair_tag_1('0),
      .i_repair_value_1('0),
      .i_repair_valid_2(1'b0),
      .i_repair_tag_2('0),
      .i_repair_value_2('0),
      .i_repair_valid_3(1'b0),
      .i_repair_tag_3('0),
      .i_repair_value_3('0),
      .i_repair_valid_4(1'b0),
      .i_repair_tag_4('0),
      .i_repair_value_4('0),
      .i_repair_valid_5(1'b0),
      .i_repair_tag_5('0),
      .i_repair_value_5('0),
      .i_repair_valid_6(1'b0),
      .i_repair_tag_6('0),
      .i_repair_value_6('0),
      .o_issue(),
      .i_fu_ready(1'b1),
      .i_divider_busy(1'b0),
      .o_issue_writes_cdb_hint(),
      .o_branch_predicate_tag(),
      .o_issue_is_jalr(),
      .o_issue_staged(),
      .o_issue_2(),
      .i_fu_ready_2(1'b1),
      .o_issue_2_staged(),
      .o_issue_writes_cdb_hint_2(),
      .o_issue_shift_amount_2(),
      .o_next_issue_valid(),
      .o_next_issue_is_sc(),
      .o_next_issue_needs_lq(),
      .o_pre_issue_rob_tag(),
      .o_pre_issue_rob_tags(),
      .o_pre_issue_sel(),
      .o_pre_issue_ready(),
      .o_pre_issue_entry_tags(),
      .i_pre_issue_raw_valid('0),
      .i_pre_issue_raw_tags('0),
      .o_pre_issue_needs_lq(),
      .i_flush_en(1'b0),
      .i_flush_tag('0),
      .i_rob_head_tag('0),
      .i_flush_all(1'b0),
      .o_empty(),
      .o_count(),
      .i_head_query_tag('0),
      .o_head_query_in_rs(),
      .o_head_query_rs_ready(),
      .o_head_query_in_stage2(),
      .o_perf_two_ready_one_issued()
  );

  fp_shim #(
      .LAUNCH_SQUASH(1'b1),
      .PIPELINE(1'b1)
  ) u_fp_shim (
      .i_clk(i_clk),
      .i_rst_n(i_rst_n),
      .i_rs_issue(shim_issue),
      .o_fu_complete(),
      .o_fu_busy(),
      .o_pipe_complete(),
      .i_pipe_accepted(1'b1),
      .o_pipe_busy(),
      .o_fwd_wake_valid(),
      .o_fwd_wake_tag(),
      .o_fwd_value(),
      .i_flush(1'b0),
      .i_flush_en(1'b0),
      .i_flush_tag('0),
      .i_rob_head_tag('0)
  );

  always_comb begin
    p_fp_engine_op_agree : assert (u_fp_rs.dispatch_is_divide == u_fp_shim.eng_issue);
    p_fp_engine_op_slot2_agree : assert (u_fp_rs.dispatch_is_divide_2 == u_fp_shim.eng_issue);
    p_fp_pipe_op_disjoint : assert (u_fp_rs.dispatch_is_divide == !u_fp_shim.is_pipe_op);
    c_pipelined_op : cover (!u_fp_rs.dispatch_is_divide && u_fp_shim.is_pipe_op);
    c_engine_op : cover (u_fp_rs.dispatch_is_divide && u_fp_shim.eng_issue);
    c_fdiv_d : cover (op == riscv_pkg::FDIV_D && u_fp_rs.dispatch_is_divide);
    c_fmadd_d : cover (op == riscv_pkg::FMADD_D && u_fp_shim.is_pipe_op);
  end
endmodule : fp_engine_op_formal
