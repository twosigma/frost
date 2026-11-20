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

// Compare the two operand write decoders used by the memory station.
module rs_mem_broadcast_formal #(
    parameter bit COVER_TRACES = 1'b0
) (
    input logic i_clk,
    input logic i_rst_n,
    input riscv_pkg::rs_dispatch_t i_dispatch,
    input riscv_pkg::rs_dispatch_t i_dispatch_2,
    input logic i_intent_1,
    input riscv_pkg::cdb_broadcast_t i_cdb,
    input riscv_pkg::cdb_broadcast_t i_cdb_2,
    input logic i_issue_cdb_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_issue_cdb_tag,
    input logic i_issue_cdb_2_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_issue_cdb_2_tag,
    input logic [0:0][riscv_pkg::ReorderBufferTagWidth-1:0] i_issue_cdb_tag_bank,
    input logic [0:0][riscv_pkg::ReorderBufferTagWidth-1:0] i_issue_cdb_2_tag_bank,
    input logic i_repair_valid_1,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_repair_tag_1,
    input logic [riscv_pkg::FLEN-1:0] i_repair_value_1,
    input logic i_repair_valid_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_repair_tag_2,
    input logic [riscv_pkg::FLEN-1:0] i_repair_value_2,
    input logic i_repair_valid_3,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_repair_tag_3,
    input logic [riscv_pkg::FLEN-1:0] i_repair_value_3,
    input logic i_repair_valid_4,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_repair_tag_4,
    input logic [riscv_pkg::FLEN-1:0] i_repair_value_4,
    input logic i_repair_valid_5,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_repair_tag_5,
    input logic [riscv_pkg::FLEN-1:0] i_repair_value_5,
    input logic i_repair_valid_6,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_repair_tag_6,
    input logic [riscv_pkg::FLEN-1:0] i_repair_value_6,
    input logic i_fu_ready,
    input logic i_divider_busy,
    input logic i_fwd_wake_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_fwd_wake_tag,
    input logic [riscv_pkg::FLEN-1:0] i_fwd_value,
    input logic i_fu_ready_2,
    input logic [2:0] i_pre_issue_raw_valid,
    input logic [3*riscv_pkg::ReorderBufferTagWidth-1:0] i_pre_issue_raw_tags,
    input logic i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,
    input logic i_flush_all,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_head_query_tag
);

  localparam int unsigned Depth = riscv_pkg::MemRsDepth;
  localparam bit Early = riscv_pkg::EarlyLoadWakeup;

  for (genvar broadcast = 0; broadcast < 2; broadcast++) begin : gen_station
    // Keep these parameters with tomasulo_wrapper.u_mem_rs. Both dispatch
    // packets and all three raw wakeup candidates are independent inputs.
    reservation_station #(
        .DEPTH(Depth),
        .PREISSUE_VALID_COFACTOR(Early),
        .PREISSUE_RAW_WAKEUP(1'b1),
        .PREISSUE_READY_EXPORT(Early),
        .HAS_SRC3(1'b0),
        .DISPATCH_REPAIR_BYPASS(1'b0),
        .ISSUE_REPAIR_BYPASS(1'b0),
        .ALLOC_INDEXED_REPAIR(1'b1),
        .SPECULATIVE_DATA_WRITES(1'b1),
        .BROADCAST_FREE_SOURCE_VALUES(broadcast != 0),
        .FORMAL_STANDALONE_ENV(1'b0),
        .TRUST_DISPATCH_VALID(1'b1)
    ) dut (
        .o_full(),
        .o_full_for_2(),
        .o_issue(),
        .o_issue_writes_cdb_hint(),
        .o_branch_predicate_tag(),
        .o_issue_is_jalr(),
        .o_issue_staged(),
        .o_issue_2(),
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
        .o_pre_issue_needs_lq(),
        .o_empty(),
        .o_count(),
        .o_head_query_in_rs(),
        .o_head_query_rs_ready(),
        .o_head_query_in_stage2(),
        .o_perf_two_ready_one_issued(),
        .*
    );
  end


  // Compare a register or port of the two real instances at its declared width.
  `define MEM_RS_SAME(field) (gen_station[0].dut.field == gen_station[1].dut.field)
  `define MEM_RS_RAM gen_primary_payload_binary.u_payload_ram

  // verilog_format: off
  wire control_equal =
      `MEM_RS_SAME(rs_valid) && `MEM_RS_SAME(count) &&
      `MEM_RS_SAME(dispatch_full_q) && `MEM_RS_SAME(dispatch_full_for_2_q) &&
      `MEM_RS_SAME(rs_src1_ready) && `MEM_RS_SAME(rs_src2_ready) &&
      `MEM_RS_SAME(rs_use_imm) && `MEM_RS_SAME(perf_two_ready_one_issued_q) &&
      `MEM_RS_SAME(repair_slot1_target_q) && `MEM_RS_SAME(repair_slot2_target_q) &&
      `MEM_RS_SAME(src1_cdb_pend) && `MEM_RS_SAME(src2_cdb_pend) &&
      `MEM_RS_SAME(src1_cdb_pend_lane) && `MEM_RS_SAME(src2_cdb_pend_lane) &&
      `MEM_RS_SAME(src1_fwd_pend) && `MEM_RS_SAME(src2_fwd_pend) &&
      `MEM_RS_SAME(cdb0_value_q) && `MEM_RS_SAME(cdb1_value_q) &&
      `MEM_RS_SAME(`MEM_RS_RAM.staged_lvt_we_q) && `MEM_RS_SAME(`MEM_RS_RAM.staged_lvt_addr_q);

  wire [Depth-1:0] row_equal;
  for (genvar row = 0; row < Depth; row++) begin : gen_compare_row
    wire sources_equal = `MEM_RS_SAME(rs_src1_value[row]) && `MEM_RS_SAME(rs_src2_value[row]);
    assign row_equal[row] = (!gen_station[0].dut.rs_valid[row] || sources_equal) &&
        `MEM_RS_SAME(rs_rob_tag[row]) && `MEM_RS_SAME(rs_src1_tag[row]) &&
        `MEM_RS_SAME(rs_src2_tag[row]) && `MEM_RS_SAME(`MEM_RS_RAM.lvt[row]) &&
        `MEM_RS_SAME(`MEM_RS_RAM.g_banks[0].u_bank.ram[row]) &&
        `MEM_RS_SAME(`MEM_RS_RAM.g_banks[1].u_bank.ram[row]);
  end

  wire stage_equal =
      `MEM_RS_SAME(stage2_valid) &&
      (!gen_station[0].dut.stage2_valid ||
       (`MEM_RS_SAME(stage2_src1_value) && `MEM_RS_SAME(stage2_src2_value))) &&
      `MEM_RS_SAME(stage2_op) && `MEM_RS_SAME(stage2_rob_tag) &&
      `MEM_RS_SAME(stage2_writes_cdb_hint) && `MEM_RS_SAME(stage2_use_imm) &&
      `MEM_RS_SAME(stage2_imm) && `MEM_RS_SAME(stage2_rm) &&
      `MEM_RS_SAME(stage2_csr_addr) && `MEM_RS_SAME(stage2_csr_imm) &&
      `MEM_RS_SAME(stage2_branch_op) && `MEM_RS_SAME(stage2_checkpoint_id) &&
      `MEM_RS_SAME(stage2_has_checkpoint) && `MEM_RS_SAME(stage2_is_branch_class) &&
      `MEM_RS_SAME(stage2_is_call) && `MEM_RS_SAME(stage2_is_compressed) &&
      `MEM_RS_SAME(stage2_is_jal) && `MEM_RS_SAME(stage2_is_jalr) &&
      `MEM_RS_SAME(stage2_jalr_imm) && `MEM_RS_SAME(stage2_is_return) &&
      `MEM_RS_SAME(stage2_predicted_taken) && `MEM_RS_SAME(stage2_predicted_target_ok) &&
      `MEM_RS_SAME(stage2_is_sc) && `MEM_RS_SAME(stage2_is_fp_mem) &&
      `MEM_RS_SAME(stage2_mem_needs_lq) && `MEM_RS_SAME(stage2_mem_needs_sq) &&
      `MEM_RS_SAME(stage2_mem_signed) && `MEM_RS_SAME(stage2_mem_size) &&
      `MEM_RS_SAME(stage2_cdb_value) && `MEM_RS_SAME(stage2_cdb_value_l1) &&
      `MEM_RS_SAME(stage2_src1_bypass_mask) && `MEM_RS_SAME(stage2_src2_bypass_mask) &&
      `MEM_RS_SAME(stage2_src1_bypass_mask_l1) && `MEM_RS_SAME(stage2_src2_bypass_mask_l1) &&
      `MEM_RS_SAME(stage2_fwd_first_q) && `MEM_RS_SAME(stage2_fwd_value_q) &&
      `MEM_RS_SAME(stage2_src1_fwd_mask) && `MEM_RS_SAME(stage2_src2_fwd_mask);

  // verilog_format: on

  wire related = control_equal && (&row_equal) && stage_equal;
  wire population_correct = gen_station[0].dut.count == $countones(gen_station[0].dut.rs_valid);
  logic sampled = 1'b0;
  logic after_reset = 1'b0;
  always_ff @(posedge i_clk) begin
    sampled <= 1'b1;
    after_reset <= !i_rst_n;
  end

  // Only the first frame couples the two stations' initial state. Free rows
  // and an empty stage may start with independent operand values. An active
  // station starts with its occupancy invariant, which each edge preserves.
  always_comb begin
    if (!sampled) begin
      assume (related);
      if (i_rst_n) assume (population_correct);
    end else begin
      assert (related);
      assert (population_correct);
    end

    // Dispatch admits the entire bundle and accounts for slot 1's intent
    // before selecting slot 2's row. A flush or reset overrides allocation.
    if (i_rst_n && !i_flush_all && !i_flush_en) begin
      if (i_dispatch.valid || i_dispatch_2.valid) assume (gen_station[0].dut.count < Depth);
      if (i_dispatch.valid && i_dispatch_2.valid) assume (gen_station[0].dut.count < Depth - 1);
      if (i_dispatch_2.valid) assume (i_intent_1 == i_dispatch.valid);
    end
  end

  for (genvar side = 0; side < 2; side++) begin : gen_interface
    riscv_pkg::rs_issue_t packet;
    always_comb begin
      packet = gen_station[side].dut.o_issue;
      if (!gen_station[side].dut.o_issue_staged) begin
        packet.src1_value = '0;
        packet.src2_value = '0;
      end
    end
    always_comb begin
      if (after_reset) begin
        assert (gen_station[side].dut.count == 0);
        assert (gen_station[side].dut.rs_valid == '0);
        assert (!gen_station[side].dut.stage2_valid);
      end
    end
  end

  // A held packet is observable even with i_fu_ready low. The LQ samples
  // the full raw-wakeup candidate set, independently of packet validity.
  always_comb begin
    assert (gen_interface[0].packet == gen_interface[1].packet);
    assert (`MEM_RS_SAME(o_full));
    assert (`MEM_RS_SAME(o_full_for_2));
    assert (`MEM_RS_SAME(o_issue_writes_cdb_hint));
    assert (`MEM_RS_SAME(o_branch_predicate_tag));
    assert (`MEM_RS_SAME(o_issue_is_jalr));
    assert (`MEM_RS_SAME(o_issue_staged));
    assert (`MEM_RS_SAME(o_issue_2));
    assert (`MEM_RS_SAME(o_issue_2_staged));
    assert (`MEM_RS_SAME(o_issue_writes_cdb_hint_2));
    assert (`MEM_RS_SAME(o_issue_shift_amount_2));
    assert (`MEM_RS_SAME(o_next_issue_valid));
    assert (`MEM_RS_SAME(o_next_issue_is_sc));
    assert (`MEM_RS_SAME(o_next_issue_needs_lq));
    assert (`MEM_RS_SAME(o_pre_issue_rob_tag));
    assert (`MEM_RS_SAME(o_pre_issue_rob_tags));
    assert (`MEM_RS_SAME(o_pre_issue_sel));
    assert (`MEM_RS_SAME(o_pre_issue_ready));
    assert (`MEM_RS_SAME(o_pre_issue_entry_tags));
    assert (`MEM_RS_SAME(o_pre_issue_needs_lq));
    assert (`MEM_RS_SAME(o_empty));
    assert (`MEM_RS_SAME(o_count));
    assert (`MEM_RS_SAME(o_head_query_in_rs));
    assert (`MEM_RS_SAME(o_head_query_rs_ready));
    assert (`MEM_RS_SAME(o_head_query_in_stage2));
    assert (`MEM_RS_SAME(o_perf_two_ready_one_issued));
  end

  if (COVER_TRACES) begin : gen_traces
    // Row 1 can receive a surplus slot-1 write while row 0 is allocated,
    // then receive either dispatch slot on a later edge.
    localparam int Row = 1;
    wire active = i_rst_n && !i_flush_all && !i_flush_en;
    wire allocate = active && gen_station[0].dut.rs_valid_alloc[Row];
    wire same_operand = `MEM_RS_SAME(rs_src1_value[Row]);
    wire surplus_write = active && i_dispatch.valid && !gen_station[0].dut.rs_valid[Row] &&
        !allocate && same_operand && gen_station[1].dut.indexed_src1_write_sel[Row][0] &&
        !gen_station[0].dut.indexed_src1_write_sel[Row][0];
    wire issue_row = gen_station[0].dut.issue_fire && gen_station[0].dut.issue_idx == Row;
    wire killed_row = |(gen_station[0].dut.rs_valid & ~gen_station[0].dut.rs_valid_next);

    logic wrote, waiting, full_flush, partial_flush, allocated, issued;
    wire saw_difference = waiting || (wrote && !same_operand);

    always_comb if (!sampled) assume (!i_rst_n);
    for (genvar row = 0; row < Depth; row++) begin : gen_start_together
      always_comb
        if (!sampled) begin
          assume (`MEM_RS_SAME(rs_src1_value[row]));
          assume (`MEM_RS_SAME(rs_src2_value[row]));
        end
    end
    always_comb
      if (!sampled) begin
        assume (`MEM_RS_SAME(stage2_src1_value));
        assume (`MEM_RS_SAME(stage2_src2_value));
      end

    always_ff @(posedge i_clk) begin
      if (!i_rst_n) begin
        wrote <= 1'b0;
        waiting <= 1'b0;
        full_flush <= 1'b0;
        partial_flush <= 1'b0;
        allocated <= 1'b0;
        issued <= 1'b0;
      end else begin
        wrote <= surplus_write;
        waiting <= saw_difference && !allocate;
        full_flush <= !allocate && (full_flush || (saw_difference && i_flush_all && killed_row));
        partial_flush <= !allocate && (partial_flush ||
            (saw_difference && !i_flush_all && i_flush_en && killed_row));
        allocated <= allocate ? (saw_difference && !same_operand) :
            (allocated && gen_station[0].dut.rs_valid_next[Row]);
        issued <= allocated && issue_row;

        if (sampled) begin
          c_alloc_and_issue : cover (issued && gen_station[0].dut.o_issue.valid);
          c_full_flush_then_alloc : cover (full_flush && allocate && !same_operand);
          c_partial_flush_then_alloc : cover (partial_flush && allocate && !same_operand);
          c_dual_dispatch :
          cover (saw_difference && !same_operand && allocate &&
              gen_station[0].dut.dispatch_fire && gen_station[0].dut.dispatch_fire_2);
          c_dispatch_during_issue :
          cover (allocated && issue_row &&
              (gen_station[0].dut.dispatch_fire || gen_station[0].dut.dispatch_fire_2));
        end
      end
    end
  end

  `undef MEM_RS_RAM
  `undef MEM_RS_SAME
endmodule
