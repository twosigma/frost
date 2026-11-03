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

// Pointwise capture, release, allocation and launch with arbitrary current state.
module lq_capture_equiv #(
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
    input logic [1:0] i_coherent_block_valid,
    input logic [1:0][riscv_pkg::XLEN-1:0] i_coherent_block_addr,
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
  (* anyseq *) logic [riscv_pkg::XLEN-1:0] p_stage_address;
  riscv_pkg::fu_complete_t p_fu_complete;
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
`ifdef FROST_XILINX_PRIMS
      // Evaluate primitive control state on its active clock edge.
      .i_clk(1'b1),
`else
      .i_clk(i_clk),
`endif
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
      .i_coh_query_addr(i_coh_query_addr),
      .o_fu_complete(p_fu_complete)
  );
  (* anyseq *) logic p_hold;
  (* anyseq *) logic p_hold_valid;
  (* anyseq *) logic p_pending;
  (* anyseq *) logic [2:0] p_pending_copy;
  (* anyseq *) logic p_phase2;
  (* anyseq *) logic p_no_older;
  (* anyseq *) logic p_is_lr;
  (* anyseq *) logic p_is_amo;
  (* anyseq *) logic p_is_mmio;
  (* anyseq *) logic p_is_cached;
  (* anyseq *) logic p_cacheable;
  (* anyseq *) logic p_at_head;
  (* anyseq *) logic p_address_fault;
  (* anyseq *) logic p_protected;
  (* anyseq *) logic p_local_hold;
  (* anyseq *) logic p_sector_hold;
  (* anyseq *) logic p_older_amo;
  (* anyseq *) logic p_resp_bypass_ok;
  (* anyseq *) logic p_cdb_available;
  (* anyseq *) logic p_issue_cdb_fire;
  (* anyseq *) logic p_cached_hold;
  (* anyseq *) logic p_gate_early;
  (* anyseq *) logic p_found;
  (* anyseq *) logic p_replace_with;
  (* anyseq *) logic p_replace_without;
  (* anyseq *) logic p_hit;
  (* anyseq *) logic p_hit_fast;
  (* anyseq *) logic p_hit_bypass;
  (* anyseq *) logic [3:0] p_take;
  (* anyseq *) logic p_clear;
  (* anyseq *) logic [2:0][3:0] p_take_basis;
  (* anyseq *) logic [2:0] p_clear_basis;
  (* anyseq *) logic p_flushed;
  (* anyseq *) logic p_probe_ok;
  (* anyseq *) logic p_drop_pending;
  (* anyseq *) logic p_commit_block;
  (* anyseq *) logic [DEPTH-1:0] p_inflight;
  (* anyseq *) logic [DEPTH-1:0] p_issue_onehot;
  (* anyseq *) logic [DEPTH-1:0] p_first_room;
  (* anyseq *) logic [DEPTH-1:0] p_second_room;
  (* anyseq *) logic [DEPTH-1:0] p_alloc;
  (* anyseq *) logic [DEPTH-1:0] p_data_valid;
  (* anyseq *) logic [DEPTH-1:0] p_data_next;
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
  (* anyseq *) logic p_hit_eligible;
  (* anyseq *) logic p_cdb_valid;
  (* anyseq *) logic p_cdb_result_flushed;
  (* anyseq *) logic p_issue_cdb_found;
  (* anyseq *) logic p_response_bypass;
  (* anyseq *) logic [1:0] p_issue_by_drain;
  (* anyseq *) logic p_entry_valid;
  (* anyseq *) logic p_commit_interlock;
  (* anyseq *) logic p_launch;
  (* anyseq *) logic p_launch_hit_blocks;
  (* anyseq *) logic p_read_en;
  (* anyseq *) logic p_bypass_fire;
  (* anyseq *) logic p_misaligned;
  (* anyseq *) logic [IdxWidth-1:0] p_issue_idx;
  (* anyseq *) logic [DEPTH-1:0] p_free_entry;
  (* anyseq *) logic p_pending_d;
  (* anyseq *) logic [2:0] p_pending_copy_d;
  (* anyseq *) logic p_no_older_d;
  (* anyseq *) logic p_phase2_d;
  (* anyseq *) logic [DEPTH-1:0] p_inflight_d;

  wire reference_ordinary = !p_is_lr && !p_is_amo && !p_hold;
  wire reference_head = !p_hold && !((p_is_lr || p_is_amo) && (i_coh_admit_pulse || !p_hold_valid));
  wire reference_disambiguated = p_no_older || i_sq_empty ||
      (i_sq_all_older_addrs_known && !i_sq_forward.match);
  wire reference_release = p_at_head ?
      (i_sq_committed_empty ? (reference_head && (reference_disambiguated || p_is_amo)) :
       (reference_ordinary && reference_disambiguated)) :
      (reference_ordinary && reference_disambiguated && !p_is_mmio);
  wire reference_eligible = p_at_head ?
      (i_sq_committed_empty ? reference_head : reference_ordinary) :
      (reference_ordinary && !p_is_mmio);
  wire reference_interlock = i_sq_commit_pending && p_is_cached && p_phase2;
  wire reference_forward = ENABLE_SQ_FORWARD_FAST_PATH && !p_hold && !p_no_older &&
      !i_sq_empty && i_sq_all_older_addrs_known && i_sq_forward.can_forward &&
      !p_is_mmio && !p_is_lr && !p_is_amo;
  wire reference_memory = reference_release && !reference_interlock &&
      ((!i_mem_bus_busy && !p_cached_hold) ||
       (ENABLE_L0_FAST_PATH && p_cacheable && (!i_mem_bus_busy || i_l0_hit_allowed) &&
        p_hit && !p_is_mmio && !p_is_lr && !p_is_amo));
  wire reference_clear_choice = (i_flush_all || i_flush_en) ?
      (reference_forward && !reference_interlock) :
      (reference_memory || (reference_forward && !reference_interlock));
  wire reference_ready = p_phase2 && !p_address_fault && p_protected &&
      !i_coherent_cut_hold && reference_clear_choice;
  wire reference_fault = !p_local_hold && !p_resp_bypass_ok && reference_eligible &&
      p_address_fault && !i_flush_en && p_cdb_available && !p_issue_cdb_fire;
  wire reference_for_take = reference_ready || p_sector_hold || p_older_amo || reference_fault;
  wire reference_for_clear = (!p_sector_hold && reference_ready) || p_older_amo || reference_fault;
  wire reference_clear = p_pending && reference_for_clear;
  wire [3:0] pending_copies = {p_pending_copy, p_pending};
  logic [3:0] reference_take;
  for (genvar copy_index = 0; copy_index < 4; copy_index++) begin : gen_take
    assign reference_take[copy_index] =
        (p_gate_early && ((!pending_copies[copy_index] && p_found) ||
         (p_pending && reference_for_take && p_found))) ||
        (p_gate_early && p_pending && (i_addr_update.valid ? p_replace_with : p_replace_without));
  end
  wire reference_probe = p_probe_ok && !p_local_hold && !i_flush_all && !i_flush_en &&
      !p_drop_pending && !p_commit_block;
  wire reference_pending_next = reference_take[0] || (p_pending && !p_flushed && !reference_clear);
  wire reference_no_older_next = reference_take[0] ? i_sq_empty : (p_no_older && !p_flushed);
  wire reference_phase2_next = reference_take[0] ? i_sq_empty :
      (!p_flushed && (p_phase2 || (!reference_clear &&
       ((p_pending && i_sq_empty && !p_commit_block) || reference_probe))));
  wire [DEPTH-1:0] reference_inflight_next = reference_take[0] ? p_issue_onehot :
      (p_inflight & {DEPTH{!p_flushed && !reference_clear}});
  wire reset_stage = !i_rst_n || i_flush_all;

  wire [DEPTH-1:0] reference_alloc =
      (p_first_room & {DEPTH{i_alloc.valid || i_alloc_2.valid}}) |
      (p_second_room & {DEPTH{i_alloc.valid && i_alloc_2.valid}});
  logic [DEPTH-1:0] reference_data_next;
  for (genvar entry = 0; entry < DEPTH; entry++) begin : gen_data
    assign reference_data_next[entry] = i_rst_n && !i_flush_all && !reference_alloc[entry] &&
        (p_data_valid[entry] ||
         (p_hit_fast && !p_hit_bypass && p_check_idx == IdxWidth'(entry)) ||
         (p_forward && !p_fwd_bypass && p_check_idx == IdxWidth'(entry)) ||
         (!p_drop_response && p_accept_response && p_issued_idx == IdxWidth'(entry) &&
          (p_response_error || (!p_issued_amo && !p_resp_bypass))) ||
         (p_amo_state == 2'd1 && i_amo_mem_write_done && p_amo_idx == IdxWidth'(entry)));
  end
  logic [1:0] reference_launch_choice;
  for (genvar drained = 0; drained < 2; drained++) begin : gen_launch
    assign reference_launch_choice[drained] = !i_flush_en && !i_flush_all &&
        p_issue_by_drain[drained] && !p_cached_hold && p_entry_valid &&
        !p_older_amo && !p_commit_interlock;
  end
  wire reference_launch = !p_local_hold && reference_launch_choice[i_sq_committed_empty];
  wire reference_issue_fire = p_cdb_available && p_issue_cdb_found && !i_flush_en;
  wire reference_response_fire = p_cdb_available && !reference_issue_fire &&
      !i_flush_all && p_response_bypass && !i_flush_en;
  wire reference_misalign_fire = p_cdb_available && !reference_issue_fire &&
      !reference_response_fire && p_misaligned && !i_flush_en;
  wire reference_hit_fire = p_cdb_available && !reference_issue_fire &&
      !reference_response_fire && !reference_misalign_fire && p_hit_fast;
  wire reference_forward_fire = p_cdb_available && !reference_issue_fire &&
      !reference_response_fire && !reference_misalign_fire && p_forward && !i_flush_en;
  wire reference_bypass_fire = reference_response_fire || reference_misalign_fire ||
      reference_hit_fire || reference_forward_fire;
  logic [DEPTH-1:0] reference_free_entry;
  for (genvar entry = 0; entry < DEPTH; entry++) begin : gen_free
    assign reference_free_entry[entry] = reference_issue_fire ?
        (p_issue_idx == IdxWidth'(entry)) :
        (reference_bypass_fire && (p_response_bypass ?
         (p_issued_idx == IdxWidth'(entry)) : (p_check_idx == IdxWidth'(entry))));
  end
  always_comb begin
    assert (p_bypass_fire == reference_bypass_fire);
    assert (p_free_entry == reference_free_entry);
    assert (p_sector_hold ==
        ((i_coherent_block_valid[0] &&
          p_stage_address[riscv_pkg::XLEN-1:5] == i_coherent_block_addr[0][riscv_pkg::XLEN-1:5]) ||
         (i_coherent_block_valid[1] &&
          p_stage_address[riscv_pkg::XLEN-1:5] == i_coherent_block_addr[1][riscv_pkg::XLEN-1:5])));
    assert (((p_take_basis[2] & ~p_take_basis[0]) == 0) &&
        ((p_take_basis[0] & ~p_take_basis[1]) == 0) &&
        (!p_clear_basis[2] || p_clear_basis[0]) &&
        (!p_clear_basis[0] || p_clear_basis[1]));
    assert (p_fu_complete.valid == (p_cdb_valid && !i_flush_en && !p_cdb_result_flushed));
    assert (p_take == reference_take);
    assert (p_clear == reference_clear);
    assert (p_pending_d == (!reset_stage && reference_pending_next));
    assert (p_pending_copy_d == {3{!reset_stage && reference_pending_next}});
    assert (p_no_older_d == (!reset_stage && reference_no_older_next));
    assert (p_phase2_d == (!reset_stage && reference_phase2_next));
    assert (p_inflight_d == (reset_stage ? '0 : reference_inflight_next));
    assert (p_alloc == reference_alloc);
    assert (p_data_next == reference_data_next);
    assert (p_launch == reference_launch);
    assert (p_read_en == (!i_mem_bus_busy && reference_launch && !(p_hit && p_launch_hit_blocks)));
  end
endmodule
