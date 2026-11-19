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

// The environment supplies dispatch and memory, the two sides of the wrapper.
// Tags always come from an accepted ROB allocation. Ready operands and all
// three dependencies may vary independently. A dependency names an older
// resident instruction; dequeue, issue, both CDBs and flush are the DUT's.
module fp_forward_wake_formal (
    input logic clk
);
  localparam int TagWidth = riscv_pkg::ReorderBufferTagWidth;
  typedef logic [TagWidth-1:0] tag_t;
  // The delivery task includes every witness schedule. Only program inputs
  // are scheduled. The DUT allocates tags, issues, arbitrates and squashes.
`ifdef FP_FORWARD_WITNESS
  `define FP_FORWARD_PROGRAM_PROOF
`elsif FP_FORWARD_DELIVERY
  `define FP_FORWARD_PROGRAM_PROOF
`endif
`ifdef FP_FORWARD_PROGRAM_PROOF
  logic [4:0] cycle = '0;
  always @(posedge clk) if (!(&cycle)) cycle <= cycle + 1'b1;
  (* anyseq *)logic [1:0] delay_choice;
  logic [1:0] delay_producer;
  always @(posedge clk) if (cycle == 0) delay_producer <= delay_choice;
  wire [4:0] producer_at = 5'd2 + 5'(delay_producer);
  wire load_op = cycle == 1;
  wire dual = cycle == producer_at;
  wire consumer = cycle == producer_at + 1;
  wire [TagWidth-1:0] src1 = TagWidth'(1), src2 = TagWidth'(1), src3 = TagWidth'(1);
`ifdef FP_FORWARD_WITNESS
  (* anyseq *) logic [17:0] schedule_choice;
  logic [4:0] response_at, release_at, flush_at;
  logic kill_producer, send_recovery, recover_all;
  always @(posedge clk)
    if (cycle == 0)
      {response_at, release_at, flush_at, kill_producer, send_recovery, recover_all} <=
          schedule_choice;
  wire engine_op = 1'b0;
  wire return_memory = cycle == response_at;
  wire release_external = cycle >= release_at;
  wire full = recover_all && send_recovery && cycle == flush_at;
  wire partial = !recover_all && send_recovery && cycle == flush_at;
  wire hold_commit = 1'b1;
  wire fp_ready = 1'b1;
  wire [2:0] dependencies = consumer ? 3'b111 : '0;
  wire [TagWidth-1:0] target = kill_producer ? '0 : TagWidth'(1);
`else
  (* anyseq *) logic send_engine, return_memory, release_external, partial, full, hold_commit;
  (* anyseq *) logic fp_ready;
  (* anyseq *) tag_t target;
  (* anyseq *) logic [2:0] waits_for_producer;
  wire engine_op = send_engine && cycle == producer_at + 2;
  wire [2:0] dependencies = consumer ? waits_for_producer : '0;
`endif
  wire dispatch = load_op || dual || consumer || engine_op || cycle == 18;
`else
  (* anyseq *) logic dispatch, load_op, engine_op, dual, release_external;
  (* anyseq *) logic partial, full, hold_commit, fp_ready;
  (* anyseq *) tag_t target, src1, src2, src3;
  (* anyseq *) logic [2:0] dependencies;
`endif
  (* anyseq *) logic [riscv_pkg::FLEN-1:0] external_value;
  logic rst_n = 1'b0;
  always @(posedge clk) rst_n <= 1'b1;

  tag_t head;
  logic [TagWidth:0] count;
  logic [riscv_pkg::ReorderBufferDepth-1:0] done;
  logic fp_full, mem_full, lq_full;
  riscv_pkg::reorder_buffer_alloc_req_t alloc, second;
  riscv_pkg::reorder_buffer_alloc_resp_t resp, resp2;
  riscv_pkg::rs_dispatch_t fp, mem;
  function automatic logic resident(input tag_t tag);
    resident = {1'b0, tag_t'(tag - head)} < count;
  endfunction
  wire flush = partial && resident(target);
  wire fire = rst_n && dispatch && !flush && !full && resp.alloc_ready &&
              (load_op ? !mem_full && !lq_full : !fp_full);
  always_comb begin
    alloc = '0;
    alloc.link_addr = 4;
    alloc.alloc_valid = fire;
    alloc.rs_type = load_op ? riscv_pkg::RS_MEM : riscv_pkg::RS_FP;
    alloc.dest_valid = 1'b1;
    alloc.dest_rf = 1'b1;
    alloc.is_fp_instruction = 1'b1;
    alloc.has_fp_flags = !load_op;
    fp = '0;
    fp.valid = fire && !load_op;
    fp.rob_tag = resp.alloc_tag;
    fp.rs_type = riscv_pkg::RS_FP;
    fp.op = engine_op ? riscv_pkg::FDIV_D : riscv_pkg::FMADD_D;
    fp.src1_ready = !(dependencies[0] && resident(src1) && !done[src1]);
    fp.src2_ready = !(dependencies[1] && resident(src2) && !done[src2]);
    fp.src3_ready = !(dependencies[2] && resident(src3) && !done[src3]);
    fp.src1_tag = src1;
    fp.src2_tag = src2;
    fp.src3_tag = src3;

    mem = '0;
    mem.valid = fire && load_op;
    mem.rob_tag = resp.alloc_tag;
    mem.rs_type = riscv_pkg::RS_MEM;
    mem.op = riscv_pkg::LOAD_FP;
    mem.src1_ready = 1'b1;
    mem.src2_ready = 1'b1;
    mem.src3_ready = 1'b1;
    mem.src1_value = riscv_pkg::FLEN'(32'h1000);
    mem.use_imm = 1'b1;
    mem.mem_needs_lq = 1'b1;
    mem.is_fp_mem = 1'b1;
    mem.mem_size = riscv_pkg::MEM_SIZE_DOUBLE;
  end

  // A second allocation can drive a competing completion on slot 1 or slot
  // 6. Hold its tag until grant or recovery. No FP producer tag is assumed
  // fresh and no restriction is placed on either station wakeup lane.
  (* anyseq *) logic pick_vector;
  logic pending, vector_q;
  tag_t other_tag;
  logic [riscv_pkg::NumFus-1:0] grant;
  riscv_pkg::fu_complete_t other, high_priority, vector_result;
  wire killed = full || (flush && tag_t'(other_tag - head) > tag_t'(target - head));
  always_comb begin
    second = '0;
    second.pc = 4;
    second.link_addr = 8;
    second.alloc_valid = fire && dual && resp2.alloc_ready && !pending;
    other = '0;
    other.valid = pending && release_external && !killed;
    other.tag = other_tag;
    other.value = external_value;
    high_priority = vector_q ? '0 : other;
    vector_result = vector_q ? other : '0;
  end
  always @(posedge clk) begin
    if (!rst_n || killed) pending <= 1'b0;
    else if (second.alloc_valid) begin
      pending   <= 1'b1;
      other_tag <= resp2.alloc_tag;
      vector_q  <= pick_vector;
    end else if (other.valid && (vector_q ? grant[6] : grant[1])) pending <= 1'b0;
  end

  logic read_en, read_valid, read_cached_q;
  logic [riscv_pkg::XLEN-1:0] read_addr;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] read_id, read_id_q;
`ifdef FP_FORWARD_PROGRAM_PROOF
  // Hold the real request identity and memory type until the chosen return.
  logic read_pending, pending_cached;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] pending_id;
  wire respond = read_pending && return_memory;
  always @(posedge clk) begin
    if (!rst_n) begin
      read_pending <= 1'b0;
      read_valid   <= 1'b0;
    end else begin
      read_valid <= respond;
      if (respond) begin
        read_pending <= 1'b0;
        read_id_q <= pending_id;
        read_cached_q <= pending_cached;
      end
      if (read_en && (!read_pending || respond)) begin
        read_pending <= 1'b1;
        pending_id <= read_id;
        pending_cached <= riscv_pkg::pma_cached_ok(read_addr);
      end
    end
  end
  `undef FP_FORWARD_PROGRAM_PROOF
`else
  always @(posedge clk) begin
    read_valid <= rst_n && read_en;
    if (read_en) begin
      read_id_q <= read_id;
      read_cached_q <= riscv_pkg::pma_cached_ok(read_addr);
    end
  end
`endif

  tomasulo_wrapper #(
      .SPLIT_RS_DISPATCH(1'b1),
      .ENABLE_DISPATCH_DONE_REPAIR(1'b1),
      .EARLY_LOAD_WAKEUP(1'b1),
      .PERF_COUNTERS(0)
  ) dut (
      .i_clk(clk),
      .i_rst_n(rst_n),
      .i_alloc_req(alloc),
      .i_alloc_req_2(second),
      .i_fp_rs_dispatch(fp),
      .i_mem_rs_dispatch(mem),
      .i_fp_rs_fu_ready(fp_ready),
      .i_mem_rs_fu_ready(1'b1),
      .i_rs_fu_ready(1'b1),
      .i_mul_rs_fu_ready(1'b1),
      .i_flush_all(full),
      .i_flush_en(flush),
      .i_flush_tag(target),
      .i_early_recovery_flush(flush),
      .i_early_recovery_en(flush),
      .i_early_recovery_tag(target),
      .i_commit_hold(hold_commit),
      .i_fu_complete_1(high_priority),
      .i_fu_complete_6(vector_result),
      .i_lq_mem_read_valid(read_valid),
      .i_lq_mem_read_id(read_id_q),
      .i_lq_mem_read_is_cached(read_cached_q),
      .i_widen_commit_ok(1'b1),
      .o_alloc_resp(resp),
      .o_alloc_resp_2(resp2),
      .o_rob_count(count),
      .o_head_tag(head),
      .o_rob_entry_done_vec(done),
      .o_fp_rs_full(fp_full),
      .o_mem_rs_full(mem_full),
      .o_lq_full(lq_full),
      .o_cdb_grant(grant),
      .o_lq_mem_read_en(read_en),
      .o_lq_mem_read_addr(read_addr),
      .o_lq_mem_read_id(read_id),
      // Other inputs without declaration defaults are inactive.
      .i_frm_csr('0),
      .i_fu_complete_0('0),
      .i_fu_complete_2('0),
      .i_fu_complete_3('0),
      .i_fu_complete_4('0),
      .i_fu_complete_5('0),
      .i_fu_complete_7('0),
      .i_branch_update('0),
      .i_rob_checkpoint_valid('0),
      .i_rob_checkpoint_id('0),
      .i_csr_done('0),
      .i_trap_taken('0),
      .i_mret_done('0),
      .i_mepc('0),
      .i_sepc('0),
      .i_dpc('0),
      .i_interrupt_pending('0),
      .i_priv('0),
      .i_counter_blocked('0),
      .i_stimecmp_blocked('0),
      .i_sret_illegal('0),
      .i_sfence_illegal('0),
      .i_wfi_illegal('0),
      .i_priv_is_u('0),
      .i_debug_mode('0),
      .i_mcounteren('0),
      .i_mstatus_fs_off('0),
      .i_trap_misaligned_accesses('0),
      .i_translation_active('0),
      .i_mmu_sum('0),
      .i_mmu_mxr('0),
      .i_mmu_eff_priv_u('0),
      .i_mmu_pm_mode('0),
      .i_csr_translation_flush_req('0),
      .i_csr_tlb_flush_all_req('0),
      .i_mmu_asid('0),
      .i_walk_req_ready('0),
      .i_walk_resp_valid('0),
      .i_walk_resp('0),
      .i_flush_after_head_commit('0),
      .i_backend_recovery_hold('0),
      .i_slow_write_inflight('0),
      .i_cached_read_held('0),
      .i_lq_mem_request_pending('0),
      .i_coh_admit_valid('0),
      .i_coh_admit_slot('0),
      .i_coh_admit_addr('0),
      .i_coh_inval_valid('0),
      .i_coh_inval_slot('0),
      .i_coh_release_valid('0),
      .i_coh_release_slot('0),
      .i_fence_i_sync_done('0),
      .i_rob_entry_epoch('0),
      .i_bypass_valid_1('0),
      .i_bypass_tag_1('0),
      .i_bypass_valid_2('0),
      .i_bypass_tag_2('0),
      .i_bypass_valid_3('0),
      .i_bypass_tag_3('0),
      .i_bypass_valid_4('0),
      .i_bypass_tag_4('0),
      .i_bypass_valid_5('0),
      .i_bypass_tag_5('0),
      .i_bypass_valid_6('0),
      .i_bypass_tag_6('0),
      .i_int_src1_addr('0),
      .i_int_src2_addr('0),
      .i_fp_src1_addr('0),
      .i_fp_src2_addr('0),
      .i_fp_src3_addr('0),
      .i_int_src1_addr_2('0),
      .i_int_src2_addr_2('0),
      .i_fp_src1_addr_2('0),
      .i_fp_src2_addr_2('0),
      .i_fp_src3_addr_2('0),
      .i_int_regfile_data1('0),
      .i_int_regfile_data2('0),
      .i_fp_regfile_data1('0),
      .i_fp_regfile_data2('0),
      .i_fp_regfile_data3('0),
      .i_int_regfile_data1_2('0),
      .i_int_regfile_data2_2('0),
      .i_fp_regfile_data1_2('0),
      .i_fp_regfile_data2_2('0),
      .i_fp_regfile_data3_2('0),
      .i_rat_alloc_valid('0),
      .i_rat_alloc_dest_rf('0),
      .i_rat_alloc_dest_reg('0),
      .i_rat_alloc_rob_tag('0),
      .i_rat_alloc_valid_2('0),
      .i_rat_alloc_dest_rf_2('0),
      .i_rat_alloc_dest_reg_2('0),
      .i_rat_alloc_rob_tag_2('0),
      .i_checkpoint_save('0),
      .i_checkpoint_id('0),
      .i_checkpoint_branch_tag('0),
      .i_ras_tos('0),
      .i_ras_valid_count('0),
      .i_ras_top('0),
      .i_checkpoint_save_for_slot2('0),
      .i_alloc_has_dest_2('0),
      .i_checkpoint_slot2_candidate('0),
      .i_checkpoint_restore('0),
      .i_checkpoint_restore_id('0),
      .i_checkpoint_restore_reclaim_all('0),
      .i_checkpoint_flush_free_mask('0),
      .i_checkpoint_free('0),
      .i_checkpoint_free_id('0),
      .i_checkpoint_free_2('0),
      .i_checkpoint_free_id_2('0),
      .i_rs_dispatch('0),
      .i_int_rs_dispatch('0),
      .i_mul_rs_dispatch('0),
      .i_int_rs_dispatch_2('0),
      .i_mul_rs_dispatch_2('0),
      .i_mem_rs_dispatch_2('0),
      .i_fp_rs_dispatch_2('0),
      .i_sq_mem_write_done('0),
      .i_lq_mem_read_data('0),
      .i_amo_mem_write_done('0),
      .i_perf_snapshot_capture('0),
      .i_perf_counter_select('0)
  );
endmodule
