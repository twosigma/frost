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

`include "store_completion_cofactor_cone.svh"

module store_completion_cofactor_cover #(
    localparam int unsigned XLEN = riscv_pkg::XLEN,
    localparam int unsigned TagWidth = riscv_pkg::ReorderBufferTagWidth
) (
    input logic i_clk,
    input logic i_rs_offer,
    input logic i_fu_ready,
    input logic [XLEN-1:0] i_rs_addr,
    input logic [1:0] i_rs_kind,
    input logic i_flush_all,
    input logic i_flush_en,
    input logic i_flush_older,
    input logic i_walk_respond,
    input logic i_walk_page_fault,
    input logic [riscv_pkg::PtePpnBits-1:0] i_walk_ppn
);
  localparam logic [1:0] Cmo = 2'd1;
  localparam logic [1:0] Sc  = 2'd2;

  wire  rst_n = !$initstate;
  (* anyconst *)logic translation_active;

  // MEM_RS stage 2 receives ready, allocated SQ operations on odd tags.
  // The ROB head is zero. A partial flush resolves either the branch at
  // the head or the branch allocated between the first two stores.
  // i_fu_ready supplies the wrapper's other readiness terms.
  logic rs_valid_q, recovery_seen_q;
  logic [TagWidth-1:0] rs_tag_q, next_tag_q;
  logic [XLEN-1:0] rs_addr_q;
  logic [1:0] rs_kind_q;
  logic dmmu_stall;
  wire [TagWidth-1:0] flush_tag = i_flush_older ? TagWidth'(0) : TagWidth'(2);
  wire flush_en = i_flush_en && !i_flush_all && !recovery_seen_q &&
      (i_flush_older || next_tag_q > TagWidth'(1));
  wire no_recovery = !i_flush_all && !flush_en && !recovery_seen_q;
  wire rs_ready = i_fu_ready && !dmmu_stall;
  wire rs_killed = rs_valid_q && (i_flush_all || (flush_en && rs_tag_q > flush_tag));
  wire rs_present = rs_valid_q && rs_ready;
  wire rs_accept = rs_present && !rs_killed;
  wire rs_fill = i_rs_offer && rs_ready && (!rs_valid_q || rs_accept) && !i_flush_all && !flush_en;
  always_ff @(posedge i_clk) begin
    if (!rst_n) begin
      recovery_seen_q <= 1'b0;
    end else if (i_flush_all || flush_en) begin
      recovery_seen_q <= 1'b1;
    end
    if (!rst_n) begin
      rs_valid_q <= 1'b0;
      next_tag_q <= 1;
    end else if (rs_fill) begin
      rs_valid_q <= 1'b1;
      next_tag_q <= next_tag_q + TagWidth'(2);
    end else if (rs_killed || rs_accept) begin
      rs_valid_q <= 1'b0;
    end
    if (rs_fill) begin
      rs_tag_q  <= next_tag_q;
      rs_addr_q <= i_rs_addr;
      rs_kind_q <= i_rs_kind;
    end
  end

  wire rs_is_cmo = rs_kind_q == Cmo;
  wire rs_is_sc = rs_kind_q == Sc;
  wire rs_misaligned = !rs_is_cmo && (|rs_addr_q[2:0]);
  wire rs_pma_ok = rs_is_sc ? riscv_pkg::pma_atomic_ok(
      rs_addr_q
  ) : riscv_pkg::pma_store_ok(
      rs_addr_q
  );

  // One outstanding 4 KiB walk, with an echoed VPN and a response at
  // least one cycle after acceptance. Leaves use S-mode PMA permissions.
  logic walk_req, walk_pending_q;
  logic [riscv_pkg::Sv39VpnBits-1:0] walk_vpn, walk_vpn_q;
  wire walk_resp_valid = walk_pending_q && i_walk_respond && !i_flush_all;
  riscv_pkg::ptw_resp_t walk_resp;
  always_comb begin
    walk_resp = '0;
    walk_resp.vpn = walk_vpn_q;
    walk_resp.fault_kind = i_walk_page_fault ? riscv_pkg::DFAULT_PAGE : riscv_pkg::DFAULT_NONE;
    walk_resp.ppn = i_walk_ppn;
    walk_resp.perm_r = 1'b1;
    walk_resp.perm_w = 1'b1;
    walk_resp.perm_d = 1'b1;
  end
  always_ff @(posedge i_clk) begin
    if (!rst_n || i_flush_all || walk_resp_valid) begin
      walk_pending_q <= 1'b0;
    end else if (walk_req && !walk_pending_q) begin
      walk_pending_q <= 1'b1;
    end
    if (walk_req && !walk_pending_q) walk_vpn_q <= walk_vpn;
  end

  logic dmmu_out_valid, dmmu_out_sq_capture_valid, dmmu_out_needs_sq;
  logic dmmu_out_is_sc, dmmu_out_is_cmo;
  logic [TagWidth-1:0] dmmu_out_tag;
  logic [XLEN-1:0] dmmu_out_addr;
  riscv_pkg::data_fault_kind_e dmmu_out_fault;
  dmmu u_dmmu (
      .i_clk(i_clk),
      .i_rst_n(rst_n),
      .i_active(translation_active),
      .i_sum(1'b0),
      .i_mxr(1'b0),
      .i_eff_priv_u(1'b0),
      .i_trap_misaligned(1'b1),
      .i_tlb_invalidate(1'b0),
      .i_tlb_flush('0),
      .i_asid('0),
      .i_flush_all(i_flush_all),
      .i_flush_en(flush_en),
      .i_flush_tag(flush_tag),
      .i_head_tag('0),
      .i_iss_valid(translation_active && rs_present),
      .i_iss_rob_tag(rs_tag_q),
      .i_iss_va(rs_addr_q),
      .i_iss_size(rs_is_cmo ? riscv_pkg::MEM_SIZE_BYTE : riscv_pkg::MEM_SIZE_DOUBLE),
      .i_iss_needs_sq(1'b1),
      .i_iss_store_perms(!rs_is_cmo),
      .i_iss_is_sc(rs_is_sc),
      .i_iss_is_cmo(rs_is_cmo),
      .i_iss_atomic(rs_is_sc),
      .i_iss_store_data('0),
      .i_iss_amo_rs2('0),
      .o_iss_out_valid(dmmu_out_valid),
      .o_iss_out_lq_capture_valid(),
      .o_iss_out_sq_capture_valid(dmmu_out_sq_capture_valid),
      .o_iss_out_rob_tag(dmmu_out_tag),
      .o_iss_out_addr(dmmu_out_addr),
      .o_iss_out_is_mmio(),
      .o_iss_out_fault(dmmu_out_fault),
      .o_iss_out_needs_sq(dmmu_out_needs_sq),
      .o_iss_out_is_sc(dmmu_out_is_sc),
      .o_iss_out_is_cmo(dmmu_out_is_cmo),
      .o_iss_out_store_data(),
      .o_iss_out_amo_rs2(),
      .o_pre_rob_tag(),
      .o_pre_needs_lq(),
      .o_stall(dmmu_stall),
      .i_early_valid(1'b0),
      .i_early_va('0),
      .i_early2_valid(1'b0),
      .i_early2_va('0),
      .o_early_ok(),
      .o_early_pa(),
      .o_early_is_mmio(),
      .o_early2_ok(),
      .o_early2_pa(),
      .o_early2_is_mmio(),
      .o_walk_req_valid(walk_req),
      .i_walk_req_ready(!walk_pending_q),
      .o_walk_vpn(walk_vpn),
      .o_walk_hold(),
      .i_walk_resp_valid(walk_resp_valid),
      .i_walk_resp(walk_resp)
  );

  wire translated_store = dmmu_out_valid && dmmu_out_needs_sq;
  wire dmmu_fault_free = dmmu_out_fault == riscv_pkg::DFAULT_NONE;
  wire translated_ok = translated_store && dmmu_fault_free;
  riscv_pkg::rs_issue_t mem_rs_issue;
  always_comb begin
    mem_rs_issue = '0;
    mem_rs_issue.src1_value = riscv_pkg::FLEN'(rs_addr_q);
  end
  logic complete;
  store_completion_cofactor dut (
      .MEM_RESPONSE_ERRORS(1'b1),
      .CACHE_NORMAL_MEMORY(1'b1),
      .CACHED_BASE(riscv_pkg::DdrBase),
      .CACHED_SIZE_BYTES(riscv_pkg::DdrCapacityBytes),
      .i_translation_active(translation_active),
      .store_issue_translated(translated_ok && !dmmu_out_is_sc),
      .store_issue_untranslated_without_pma(rs_present && !rs_is_sc && !rs_misaligned),
      .cut_pma_ok(rs_pma_ok),
      .dmmu_out_is_cmo(dmmu_out_is_cmo),
      .mem_rs_issue_is_cmo(rs_is_cmo),
      .mem_rs_issue_atomic_pma(rs_is_sc),
      .i_mmu_pm_mode(riscv_pkg::EnvcfgPmmOff),
      .o_mem_rs_issue(mem_rs_issue),
      .dmmu_out_addr(dmmu_out_addr),
      .store_complete_valid(complete)
  );

  wire rs_plain_store = !rs_is_cmo && !rs_is_sc;
  wire dmmu_plain_store = !dmmu_out_is_cmo && !dmmu_out_is_sc;
  wire overlapping_issue = rs_accept && rs_tag_q > dmmu_out_tag && rs_plain_store;
  wire dmmu_at_ddr_base = dmmu_out_addr == riscv_pkg::DdrBase;
  wire killed_cached_result = dmmu_out_sq_capture_valid && !dmmu_out_valid && dmmu_fault_free &&
      dmmu_plain_store && dmmu_at_ddr_base && !complete;

  always_ff @(posedge i_clk) begin
    if (rst_n && !translation_active) begin
      if (rs_accept && rs_pma_ok && !rs_misaligned) begin
        c_bypass_cached : cover (rs_plain_store && rs_addr_q == riscv_pkg::DdrBase && complete);
        c_bypass_writethrough :
        cover (rs_plain_store && rs_addr_q == riscv_pkg::PmaUncachedBase && complete);
        c_bypass_cmo_device :
        cover (rs_is_cmo && rs_addr_q == riscv_pkg::PmaDevice0Base && complete);
        c_bypass_device_defers :
        cover (rs_plain_store && rs_addr_q == riscv_pkg::PmaDevice0Base && !complete);
        c_bypass_sc_excluded : cover (rs_is_sc && rs_addr_q == riscv_pkg::DdrBase && !complete);
      end
      c_bypass_pma_fault : cover (rs_accept && rs_is_cmo && !rs_pma_ok && !complete);
      c_bypass_misaligned :
      cover (rs_accept && !rs_is_sc && rs_misaligned && rs_pma_ok && riscv_pkg::pma_cached_ok(
          rs_addr_q
      ) && !complete);
      c_bypass_held_then_complete :
      cover ($past(
          rst_n && rs_valid_q && !rs_ready && !rs_killed && !complete
      ) && no_recovery && rs_accept && rs_plain_store && complete);
      // The outgoing RS valid is raw on the flush edge. Clearing the RS and
      // ROB entries discards the younger operation, even if both predicates fire.
      c_bypass_partial_kill :
      cover ($past(
          rst_n && flush_en && rs_killed && rs_plain_store && complete
      ) && !i_flush_all && !rs_valid_q && !complete);
      c_bypass_consume_and_refill : cover (rs_accept && rs_fill && complete);
    end
    if (rst_n && translation_active) begin
      if (translated_ok) begin
        c_translated_cached : cover (dmmu_plain_store && dmmu_at_ddr_base && complete);
        c_translated_writethrough :
        cover (dmmu_plain_store && dmmu_out_addr == riscv_pkg::PmaUncachedBase && complete);
        c_translated_cmo_device :
        cover (dmmu_out_is_cmo && dmmu_out_addr == riscv_pkg::PmaDevice0Base && complete);
        c_translated_device_defers :
        cover (dmmu_plain_store && dmmu_out_addr == riscv_pkg::PmaDevice0Base && !complete);
        c_translated_sc_excluded : cover (dmmu_out_is_sc && dmmu_at_ddr_base && !complete);
      end
      c_translated_walk_fault :
      cover ($past(
          walk_resp_valid && i_walk_page_fault
      ) && translated_store && dmmu_out_fault == riscv_pkg::DFAULT_PAGE &&
          dmmu_out_addr == riscv_pkg::DdrBase && !dmmu_out_is_sc && !complete);
      c_translated_walk_held_then_complete :
      cover ($past(
          walk_pending_q && !walk_resp_valid && !complete, 2
      ) && $past(
          walk_resp_valid
      ) && no_recovery && translated_ok && complete);
      c_translated_partial_kill : cover (flush_en && killed_cached_result);
      c_translated_full_kill : cover (i_flush_all && killed_cached_result);
      c_translated_older_survives_flush : cover (flush_en && translated_ok && complete);
      c_translated_result_and_issue :
      cover (no_recovery && translated_ok && dmmu_plain_store && dmmu_at_ddr_base && complete &&
             overlapping_issue && rs_addr_q == riscv_pkg::PmaDevice0Base);
      c_translated_deferred_and_issue :
      cover (no_recovery && translated_ok && dmmu_plain_store && !complete &&
             dmmu_out_addr == riscv_pkg::PmaDevice0Base && overlapping_issue &&
             rs_addr_q == riscv_pkg::DdrBase);
    end
  end
endmodule
