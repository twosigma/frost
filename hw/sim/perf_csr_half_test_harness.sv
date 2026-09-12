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

// Compare the enabled CSR half path with the original full-width CSR port.
// Both use the actual aggregator and commit-bus register, including immediate
// flush masking. The default-off CSR instance receives a deliberately wrong
// hint so equality also checks that the optional input is ignored there.
module perf_csr_half_test_harness (
    input logic i_clk,
    input logic i_rst,
    input logic i_flush,
    input logic i_raw_valid,
    input logic i_raw_is_csr,
    input logic i_raw_exception,
    input logic [11:0] i_raw_address,
    input logic [2:0] i_raw_op,
    input logic [63:0] i_raw_value,
    input logic [63:0] i_wrapper_data,
    input logic i_dispatch_event,
    input logic i_cache_access,
    input logic [4:0] i_fp_flags,
    input logic i_fp_flags_valid,
    input logic [63:0] i_mtime,
    output logic [63:0] o_reference,
    output logic [63:0] o_candidate,
    output logic [63:0] o_reference_comb,
    output logic [63:0] o_candidate_comb,
    output logic [63:0] o_perf_data,
    output logic [31:0] o_perf_half,
    output logic [11:0] o_commit_address,
    output logic o_read_enable,
    output logic [7:0] o_selector,
    output logic o_capture,
    output logic o_previous
);
  riscv_pkg::reorder_buffer_commit_t raw_commit, commit_q;
  riscv_pkg::reorder_buffer_alloc_req_t allocation;
  cache_perf_pkg::cache_perf_events_t cache_events;
  logic commit_valid;
  logic [63:0] read_data[2], read_comb[2];
  logic [7:0] selectors[2];
  logic captures[2], previous[2];
  logic [31:0] counter_count;

  always_comb begin
    raw_commit = '0;
    raw_commit.valid = i_raw_valid;
    raw_commit.is_csr = i_raw_is_csr;
    raw_commit.exception = i_raw_exception;
    raw_commit.csr_addr = i_raw_address;
    raw_commit.csr_op = i_raw_op;
    raw_commit.value = i_raw_value;
    allocation = '0;
    allocation.alloc_valid = i_dispatch_event;
    cache_events = '0;
    cache_events.hierarchy.l1i.access = i_cache_access;
  end
  assign o_read_enable = commit_valid && commit_q.is_csr && !commit_q.exception;
  assign o_commit_address = commit_q.csr_addr;
  assign o_reference = read_data[0];
  assign o_candidate = read_data[1];
  assign o_reference_comb = read_comb[0];
  assign o_candidate_comb = read_comb[1];
  assign o_selector = selectors[0];
  assign o_capture = captures[0];
  assign o_previous = previous[0];
  commit_bus_pipeline u_commit (
      .i_clk(i_clk),
      .i_rst_n(!i_rst),
      .i_flush_all(i_flush),
      .i_commit_bus(raw_commit),
      .i_commit_bus_2('0),
      .o_commit_bus_q(commit_q),
      .o_commit_bus_q_valid(commit_valid),
      .o_commit_bus_q_valid_raw(),
      .o_commit_q_dest_valid(),
      .o_commit_q_dest_rf(),
      .o_commit_q_dest_reg(),
      .o_commit_q_tag(),
      .o_commit_q_is_sc(),
      .o_commit_q_is_store_like(),
      .o_commit_q_sc_failed(),
      .o_commit_bus_2_q(),
      .o_commit_bus_2_q_valid(),
      .o_commit_bus_2_q_valid_raw(),
      .o_commit_q_2_dest_valid(),
      .o_commit_q_2_dest_rf(),
      .o_commit_q_2_dest_reg(),
      .o_commit_q_2_tag(),
      .o_commit_q_2_is_store_like()
  );
  perf_counter_aggregator #(
      .PreselectCsrHalf(1'b1)
  ) u_perf (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_rob_alloc_req(allocation),
      .i_dispatch_fire_2('0),
      .i_if_width_events('0),
      .i_mem_rs_two_ready_one_issued('0),
      .i_cdb_oversubscribed('0),
      .i_dispatch_status('0),
      .i_rob_commit_comb(raw_commit),
      .i_flush_pipeline(i_flush),
      .i_post_flush_holdoff_q('0),
      .i_csr_in_flight('0),
      .i_csr_wb_pending('0),
      .i_serializing_alloc_fire('0),
      .i_front_end_cf_serialize_stall('0),
      .i_rob_empty('0),
      .i_disable_branch_prediction_ooo('0),
      .i_disable_branch_prediction('0),
      .i_prediction_fence_branch('0),
      .i_prediction_fence_jal('0),
      .i_prediction_fence_indirect('0),
      .i_cache_perf_events(cache_events),
      .i_perf_counter_select(selectors[0]),
      .i_perf_snapshot_capture(captures[0]),
      .i_perf_cache_previous_select(previous[0]),
      .i_wrapper_perf_counter_data(i_wrapper_data),
      .o_wrapper_perf_counter_select(),
      .o_perf_counter_data_q(o_perf_data),
      .o_perf_counter_csr_half_q(o_perf_half),
      .o_perf_counter_count(counter_count)
  );
  for (genvar k = 0; k < 2; k++) begin : gen_csr
    csr_file #(
        .UsePerfCsrHalf(k == 1)
    ) u_csr (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_csr_read_enable(o_read_enable),
        .i_csr_address(commit_q.csr_addr),
        .i_csr_op(commit_q.csr_op),
        .i_csr_write_data(commit_q.value),
        .i_csr_write_enable(o_read_enable),
        .o_csr_read_data(read_data[k]),
        .o_csr_read_data_comb(read_comb[k]),
        .i_instruction_retired_count('0),
        .i_interrupts('0),
        .i_mtime(i_mtime),
        .i_seip_line('0),
        .i_trap_taken('0),
        .i_trap_to_s('0),
        .i_trap_pc('0),
        .i_trap_cause('0),
        .i_trap_value('0),
        .i_mret_taken('0),
        .i_sret_taken('0),
        .i_trap_to_d('0),
        .i_trap_dbg_cause('0),
        .i_dret_taken('0),
        .i_dbg_data('0),
        .o_dbg_data_we(),
        .o_dbg_data_wdata(),
        .o_mstatus(),
        .o_mie(),
        .o_mtvec(),
        .o_mtvec_traps_misaligned(),
        .o_mepc(),
        .o_stvec(),
        .o_sepc(),
        .o_mstatus_mie_direct(),
        .o_sstatus_sie_direct(),
        .o_medeleg(),
        .o_mideleg_s(),
        .o_s_pending(),
        .o_priv(),
        .o_mcounteren(),
        .o_scounteren(),
        .o_counter_blocked(),
        .o_stimecmp_blocked(),
        .o_sret_illegal(),
        .o_sfence_illegal(),
        .o_wfi_illegal(),
        .o_priv_is_u(),
        .o_csr_translation_flush_req(),
        .o_translation_active(),
        .o_mmu_sum(),
        .o_mmu_mxr(),
        .o_mmu_eff_priv_u(),
        .o_fetch_translation_active(),
        .o_fetch_priv_u(),
        .o_satp_root_ppn(),
        .o_mstatus_fs_off(),
        .o_debug_mode(),
        .o_dcsr_step(),
        .o_dcsr_ebreak(),
        .o_dpc(),
        .i_fp_flags(riscv_pkg::fp_flags_t'(i_fp_flags)),
        .i_fp_flags_valid(i_fp_flags_valid),
        .i_fp_dest_write('0),
        .i_fp_flags_wb_valid(i_fp_flags_valid),
        .i_fp_flags_ma('0),
        .i_fp_flags_ma_valid('0),
        .o_frm(),
        .o_perf_counter_select(selectors[k]),
        .o_perf_snapshot_capture(captures[k]),
        .o_perf_cache_previous_select(previous[k]),
        .i_perf_counter_data(o_perf_data),
        .i_perf_counter_csr_half((k == 1) ? o_perf_half : ~o_perf_half),
        .i_perf_counter_count(counter_count)
    );
  end

  // Same-cycle combinational equality and the following registered response.
  // Qualification is the real commit-time expression, not a test assumption.
  always @(posedge i_clk) begin
    if (!i_rst) begin
      assert (read_comb[0] == read_comb[1]);
      assert (read_data[0] == read_data[1]);
      assert (selectors[0] == selectors[1]);
      assert (captures[0] == captures[1]);
      assert (previous[0] == previous[1]);
      if (o_read_enable && commit_q.csr_addr == riscv_pkg::CsrMperfData)
        assert (o_perf_half == o_perf_data[31:0]);
      if (o_read_enable && commit_q.csr_addr == riscv_pkg::CsrMperfDataH)
        assert (o_perf_half == o_perf_data[63:32]);
    end
  end
endmodule
