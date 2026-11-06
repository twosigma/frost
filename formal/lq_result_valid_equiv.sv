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

// Result-valid next state for arbitrary current state and input values.
module lq_result_valid_equiv #(
    parameter bit CACHE_NORMAL_MEMORY = 1'b0,
    parameter int unsigned DEPTH = riscv_pkg::LqDepth,
    parameter bit ENABLE_L0_FAST_PATH = 1'b1,
    parameter bit PREISSUE_CANDIDATES = 1'b0,
    parameter int unsigned PREISSUE_SEL_WIDTH = 2,

    parameter bit PREISSUE_READY_PICK = 1'b0,
    parameter int unsigned PREISSUE_RS_DEPTH = riscv_pkg::MemRsDepth,
    parameter int unsigned L0_CACHE_DEPTH = riscv_pkg::LqL0Depth,
    parameter bit PREPARE_LOAD_WHILE_BUSY = riscv_pkg::PrepareLoadWhileBusy,
    parameter bit ENABLE_SQ_FORWARD_FAST_PATH = 1'b0,
    parameter bit MEM_RESPONSE_ERRORS = 1'b0,

    parameter bit CACHE_UNCACHED_DATA = 1'b1,

    parameter longint unsigned CACHED_BASE = riscv_pkg::DdrBase,
    parameter longint unsigned CACHED_SIZE_BYTES = riscv_pkg::DdrCapacityBytes
) (
    input logic i_coherent_cut_hold,
    input logic [riscv_pkg::XLEN-1:0] i_coherent_cut_addr,
    input logic [3:0] i_coherent_block_valid,
    input logic [3:0][riscv_pkg::XLEN-1:0] i_coherent_block_addr,
    input logic i_coherent_atomic_protected,
    input logic i_clk,
    input logic i_rst_n,
    input riscv_pkg::lq_alloc_req_t i_alloc,
    input riscv_pkg::lq_alloc_req_t i_alloc_2,
    input riscv_pkg::lq_addr_update_t i_addr_update,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_pre_issue_rob_tag,
    input logic [(1 << PREISSUE_SEL_WIDTH)*riscv_pkg::ReorderBufferTagWidth-1:0]
        i_pre_issue_rob_tags,
    input logic [PREISSUE_SEL_WIDTH-1:0] i_pre_issue_sel,
    input logic i_pre_issue_needs_lq,
    input logic [(1 << PREISSUE_SEL_WIDTH)*PREISSUE_RS_DEPTH-1:0] i_pre_issue_ready,
    input logic [PREISSUE_RS_DEPTH*riscv_pkg::ReorderBufferTagWidth-1:0] i_pre_issue_entry_tags,
    input logic i_pre_issue_direct,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_pre_issue_direct_tag,
    input logic i_sq_all_older_addrs_known,
    input riscv_pkg::sq_forward_result_t i_sq_forward,
    input logic i_sq_commit_pending,
    input logic [riscv_pkg::MemDataBits-1:0] i_mem_read_data,
    input logic i_mem_read_valid,
    input logic i_mem_read_error,
    input logic i_mem_read_is_cached,
    input logic [riscv_pkg::CachedLoadSlotBits-1:0] i_mem_read_id,
    input logic i_mem_bus_busy,
    input logic i_mem_request_pending,
    input logic i_cached_resp_held,
    input logic i_adapter_result_pending,
    input logic i_result_accepted,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,
    input logic i_sc_clear_reservation,
    input logic i_reservation_snoop_invalidate,
    input logic i_sq_empty,
    input logic i_sq_committed_empty,
    input logic i_trap_misaligned_accesses,
    input logic i_amo_mem_write_done,
    input logic i_amo_mem_write_error,
    input logic i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic i_flush_all,
    input logic i_full_flush,
    input logic i_early_recovery_flush,
    input logic i_cache_invalidate_valid,
    input logic [riscv_pkg::XLEN-1:0] i_cache_invalidate_addr,
    input logic [63:0] i_cache_store_data,
    input logic [7:0] i_cache_store_strb,
    input logic i_l0_hit_allowed,
    input logic i_coh_inval_valid,
    input logic [riscv_pkg::XLEN-1:0] i_coh_inval_addr,
    input logic [riscv_pkg::DmaCoherenceLocks-1:0] i_coh_block_valid,
    input logic [riscv_pkg::DmaCoherenceLocks-1:0][riscv_pkg::XLEN-1:0] i_coh_block_addr,
    input logic i_coh_admit_pulse,
    input logic [riscv_pkg::XLEN-1:0] i_coh_query_addr
);
  localparam int unsigned IdxWidth = $clog2(DEPTH);
  load_queue #(
      .CACHE_NORMAL_MEMORY(CACHE_NORMAL_MEMORY),
      .DEPTH(DEPTH),
      .ENABLE_L0_FAST_PATH(ENABLE_L0_FAST_PATH),
      .PREISSUE_CANDIDATES(PREISSUE_CANDIDATES),
      .PREISSUE_SEL_WIDTH(PREISSUE_SEL_WIDTH),
      .PREISSUE_READY_PICK(PREISSUE_READY_PICK),
      .PREISSUE_RS_DEPTH(PREISSUE_RS_DEPTH),
      .L0_CACHE_DEPTH(L0_CACHE_DEPTH),
      .PREPARE_LOAD_WHILE_BUSY(PREPARE_LOAD_WHILE_BUSY),
      .ENABLE_SQ_FORWARD_FAST_PATH(ENABLE_SQ_FORWARD_FAST_PATH),
      .MEM_RESPONSE_ERRORS(MEM_RESPONSE_ERRORS),
      .CACHE_UNCACHED_DATA(CACHE_UNCACHED_DATA),
      .CACHED_BASE(CACHED_BASE),
      .CACHED_SIZE_BYTES(CACHED_SIZE_BYTES)
  ) dut (
      .i_coherent_cut_hold(i_coherent_cut_hold),
      .i_coherent_cut_addr(i_coherent_cut_addr),
      .i_coherent_block_valid(i_coherent_block_valid),
      .i_coherent_block_addr(i_coherent_block_addr),
      .i_coherent_atomic_protected(i_coherent_atomic_protected),
      .i_clk(i_clk),
      .i_rst_n(i_rst_n),
      .i_alloc(i_alloc),
      .i_alloc_2(i_alloc_2),
      .i_addr_update(i_addr_update),
      .i_pre_issue_rob_tag(i_pre_issue_rob_tag),
      .i_pre_issue_rob_tags(i_pre_issue_rob_tags),
      .i_pre_issue_sel(i_pre_issue_sel),
      .i_pre_issue_needs_lq(i_pre_issue_needs_lq),
      .i_pre_issue_ready(i_pre_issue_ready),
      .i_pre_issue_entry_tags(i_pre_issue_entry_tags),
      .i_pre_issue_direct(i_pre_issue_direct),
      .i_pre_issue_direct_tag(i_pre_issue_direct_tag),
      .i_sq_all_older_addrs_known(i_sq_all_older_addrs_known),
      .i_sq_forward(i_sq_forward),
      .i_sq_commit_pending(i_sq_commit_pending),
      .i_mem_read_data(i_mem_read_data),
      .i_mem_read_valid(i_mem_read_valid),
      .i_mem_read_error(i_mem_read_error),
      .i_mem_read_is_cached(i_mem_read_is_cached),
      .i_mem_read_id(i_mem_read_id),
      .i_mem_bus_busy(i_mem_bus_busy),
      .i_mem_request_pending(i_mem_request_pending),
      .i_cached_resp_held(i_cached_resp_held),
      .i_adapter_result_pending(i_adapter_result_pending),
      .i_result_accepted(i_result_accepted),
      .i_rob_head_tag(i_rob_head_tag),
      .i_sc_clear_reservation(i_sc_clear_reservation),
      .i_reservation_snoop_invalidate(i_reservation_snoop_invalidate),
      .i_sq_empty(i_sq_empty),
      .i_sq_committed_empty(i_sq_committed_empty),
      .i_trap_misaligned_accesses(i_trap_misaligned_accesses),
      .i_amo_mem_write_done(i_amo_mem_write_done),
      .i_amo_mem_write_error(i_amo_mem_write_error),
      .i_flush_en(i_flush_en),
      .i_flush_tag(i_flush_tag),
      .i_flush_all(i_flush_all),
      .i_full_flush(i_full_flush),
      .i_early_recovery_flush(i_early_recovery_flush),
      .i_cache_invalidate_valid(i_cache_invalidate_valid),
      .i_cache_invalidate_addr(i_cache_invalidate_addr),
      .i_cache_store_data(i_cache_store_data),
      .i_cache_store_strb(i_cache_store_strb),
      .i_l0_hit_allowed(i_l0_hit_allowed),
      .i_coh_inval_valid(i_coh_inval_valid),
      .i_coh_inval_addr(i_coh_inval_addr),
      .i_coh_block_valid(i_coh_block_valid),
      .i_coh_block_addr(i_coh_block_addr),
      .i_coh_admit_pulse(i_coh_admit_pulse),
      .i_coh_query_addr(i_coh_query_addr)
  );
  (* anyseq *) logic [DEPTH-1:0] p_alloc;
  (* anyseq *) logic [DEPTH-1:0] p_data_valid;
  (* anyseq *) logic [DEPTH-1:0] p_data_next;
  (* anyseq *) logic [DEPTH-1:0] p_data_d;
  (* anyseq *) logic p_hit;
  (* anyseq *) logic p_hit_fast;
  (* anyseq *) logic p_hit_bypass;
  (* anyseq *) logic p_hit_eligible;
  (* anyseq *) logic p_forward;
  (* anyseq *) logic p_fwd_bypass;
  (* anyseq *) logic [IdxWidth-1:0] p_check_idx;
  (* anyseq *) logic p_drop_response;
  (* anyseq *) logic p_accept_response;
  (* anyseq *) logic [IdxWidth-1:0] p_issued_idx;
  (* anyseq *) logic p_response_error;
  (* anyseq *) logic p_issued_amo;
  (* anyseq *) logic p_resp_bypass;
  (* anyseq *) logic [1:0] p_amo_state;
  (* anyseq *) logic [IdxWidth-1:0] p_amo_idx;
  (* anyseq *) logic p_cdb_valid;
  (* anyseq *) logic p_issue_cdb_found;
  (* anyseq *) logic p_response_bypass;

  logic [DEPTH-1:0] reference_data_next;
  for (genvar entry = 0; entry < DEPTH; entry++) begin : gen_data
    assign reference_data_next[entry] = !i_flush_all && !p_alloc[entry] &&
        (p_data_valid[entry] ||
         (p_hit_fast && !p_hit_bypass && p_check_idx == IdxWidth'(entry)) ||
         (p_forward && !p_fwd_bypass && p_check_idx == IdxWidth'(entry)) ||
         (!p_drop_response && p_accept_response && p_issued_idx == IdxWidth'(entry) &&
          (p_response_error || (!p_issued_amo && !p_resp_bypass))) ||
         (p_amo_state == 2'd1 && i_amo_mem_write_done && p_amo_idx == IdxWidth'(entry)));
  end
  always_comb begin
    assert (!p_accept_response || !p_drop_response);
    assert (p_data_next == reference_data_next);
    assert (p_data_d == (i_rst_n ? reference_data_next : '0));
  end
endmodule
