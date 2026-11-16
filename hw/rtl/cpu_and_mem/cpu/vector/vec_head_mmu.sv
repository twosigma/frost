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
  Head-executed legality, span calculation, and DMMU translation for unit-stride,
  whole-register, and mask vector loads and stores.

  A VLOAD or VSTORE dispatches with RS_NONE and waits for the ROB head. Once at
  the head with older vector and CSR work settled, this unit:
    1. Reads architectural vl, vtype, vstart, integer base rs1 (via the extra
       integer RF read port), and mask register v0 (via the VRF read port).
    2. Checks register-group legality from architectural vtype (vill except on
       whole-register forms, EMUL in [1/8, 8], register-group alignment, and
       masked load destination overlap with v0).
    3. Computes the active element mask [vstart, evl) & v0.t and reduces the
       lowest and highest active element indices across shallow 16-bit stages.
       Zero-active-element instructions perform no translation or memory check,
       record an empty VMT range, complete on CDB slot 6, and free their VMT
       entry on retirement.
    4. Translates up to two 4 KiB pages on the DMMU page-walker port and checks
       cached-DDR region legality. Page-0 faults trap with zero memory accesses
       and vstart = first_p0_elem. Page-1 faults with no Page-0-only elements
       (including when first_p0_elem straddles the page boundary) also trap with
       zero memory accesses. When Page 0 is valid and active elements lie wholly
       in Page 0 before a faulting Page 1, those Page-0-only elements execute
       on vec_vmu first (after committed scalar stores drain and under the
       interrupt shield), and the Page-1 fault then reports vstart = first_p1_elem.
    5. When all touched pages succeed, waits for committed scalar stores to
       drain, raises the head interrupt shield, writes the physical VMT segments,
       completes on CDB slot 6, and upon registered retirement hands the
       translated command to vec_unit for vec_vmu execution.
*/
module vec_head_mmu #(
    parameter int unsigned VLEN = 256,
    parameter bit CACHED_TIER_EN = 1'b1,
    localparam int unsigned XLEN = riscv_pkg::XLEN,
    localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth,
    localparam int unsigned VmtIdxW = $clog2(riscv_pkg::VmtDepth),
    localparam int unsigned SegW = 1 + riscv_pkg::VmtPpnBits + 14
) (
    input logic i_clk,
    input logic i_rst,

    // ROB head tracking and retirement
    input logic [   TagW-1:0] i_head_tag,
    input logic               i_rob_empty,
    input logic               i_head_safe,
    input logic               i_head_is_vmem,
    input logic [       31:0] i_head_insn,
    input logic [VmtIdxW-1:0] i_head_vmt_idx,
    input logic               i_flush_all,
    input logic               i_fatal_stop,

    // Registered commit bus (1 cycle after ROB head retirement)
    input logic            i_commit_valid,
    input logic [TagW-1:0] i_commit_tag,
    input logic            i_commit_exception,

    // Ordering & quiescence inputs
    input logic i_vec_idle,
    input logic i_csr_wb_pending,
    input logic i_sq_committed_empty,
    input logic i_int_take_armed,

    // Architectural vector CSRs
    input logic [15:0] i_vl,
    input logic [ 8:0] i_vtype,
    input logic [15:0] i_vstart,

    // Integer RF extra read port (rs1)
    output logic            o_rf_read_en,
    output logic [     4:0] o_rf_read_addr,
    input  logic [XLEN-1:0] i_rf_read_data,

    // VRF read port (v0)
    output logic            o_vrf_read_en,
    output logic [     4:0] o_vrf_read_addr,
    input  logic [VLEN-1:0] i_vrf_read_data,

    // Registered data-translation state & walker port
    input  logic                                              i_translate,
    input  logic                                              i_eff_priv_u,
    input  logic                                              i_sum,
    input  logic                                              i_mxr,
    input  logic                                              i_tlb_invalidate,
    output logic                                              o_walk_req_valid,
    input  logic                                              i_walk_req_ready,
    output logic                 [riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,
    input  logic                                              i_walk_resp_valid,
    input  riscv_pkg::ptw_resp_t                              i_walk_resp,

    // VMT range write & zero-element completion
    output logic               o_vmt_range_valid,
    output logic [VmtIdxW-1:0] o_vmt_range_idx,
    output logic [   SegW-1:0] o_vmt_range_seg0,
    output logic [   SegW-1:0] o_vmt_range_seg1,
    output logic               o_zero_vmt_done_valid,
    output logic [VmtIdxW-1:0] o_zero_vmt_done_idx,

    // Arbitrated CDB slot-6 completion
    input  logic                               i_grant,
    output riscv_pkg::fu_complete_t            o_vhead_complete,
    output logic                               o_cdb_done,
    output logic                    [TagW-1:0] o_cdb_done_tag,

    // Trap & CSR sideband
    output logic        o_vmem_head_shield,
    output logic        o_vmem_fault_vstart_valid,
    output logic [15:0] o_vmem_fault_vstart,
    output logic        o_retire_vload,
    output logic        o_retire_vstore,

    // Command launch to vec_unit / vec_vmu (retired or Case-C partial Page-0)
    output logic                             o_desc_valid,
    output logic [riscv_pkg::VmtPpnBits-1:0] o_desc_ppn0,
    output logic [riscv_pkg::VmtPpnBits-1:0] o_desc_ppn1,
    output logic [                     11:0] o_desc_page_offset,
    output logic [                     15:0] o_desc_first_elem,
    output logic [                     15:0] o_desc_last_elem,
    output logic [                      1:0] o_desc_eew_log2,
    output logic [                 VLEN-1:0] o_desc_active_mask,
    output logic                             o_desc_is_store,
    output logic [                      4:0] o_desc_vd_vs3,
    output logic [              VmtIdxW-1:0] o_desc_vmt_idx,
    output logic                             o_desc_free_vmt_on_done,
    output logic [                 SegW-1:0] o_desc_seg0,
    output logic [                 SegW-1:0] o_desc_seg1,

    // Case-C partial Page-0 completion from vec_vmu
    input logic i_vmu_done,
    input logic i_vmu_fatal
);

  initial begin
    if (VLEN != 128 && VLEN != 256 && VLEN != 512)
      $fatal(1, "vec_head_mmu: VLEN must be 128, 256 or 512");
  end

  localparam int unsigned VlenBytes = VLEN / 8;
  localparam int unsigned NumGroups16 = VLEN / 16;
  localparam int unsigned ElemBits = 10;  // Covers 0..511 across VLEN <= 512

  typedef enum logic [4:0] {
    HM_IDLE,
    HM_WAIT,
    HM_DECODE,
    HM_SPAN0,
    HM_SPAN1,
    HM_SPAN1_ADD,
    HM_SPAN2,
    HM_P1_SPAN0,
    HM_P1_SPAN1,
    HM_P1_SPAN1_ADD,
    HM_P1_SPAN1_TVAL,
    HM_CHECK_P0,
    HM_WALK_REQ_P0,
    HM_WALK_WAIT_P0,
    HM_CHECK_P1,
    HM_WALK_REQ_P1,
    HM_WALK_WAIT_P1,
    HM_PARTIAL_ARM,
    HM_PARTIAL_SETTLE,
    HM_PARTIAL_RUN,
    HM_FAULT_ARM,
    HM_FAULT_SETTLE,
    HM_CDB_FAULT,
    HM_WAIT_TRAP,
    HM_COMMIT_ARM,
    HM_COMMIT_SETTLE,
    HM_CDB_OK,
    HM_WAIT_RETIRE,
    HM_FATAL
  } hm_state_e;

  hm_state_e state_q;
  logic wait_q;
  logic [TagW-1:0] tag_q;
  logic [31:0] insn_q;
  logic [VmtIdxW-1:0] vmt_idx_q;

  // Sampled CSR & translation state
  logic [15:0] vl_q, vstart_q;
  logic [8:0] vtype_q;
  logic translate_q, eff_priv_u_q, sum_q, mxr_q;
  logic [XLEN-1:0] rs1_q;

  // Decoded instruction attributes & active mask
  logic is_store_q, is_whole_q, is_mask_q, vm_q;
  logic [4:0] vd_vs3_q;
  logic [1:0] eew_log2_q;
  logic [15:0] evl_q;
  logic [VLEN-1:0] active_mask_q;
  logic zero_active_q;

  // Priority-encoder intermediate per-16b group registers
  logic [NumGroups16-1:0] grp_lo_any_q, grp_hi_any_q;
  logic [NumGroups16-1:0][3:0] grp_lo_idx_q, grp_hi_idx_q;
  logic [VLEN-1:0] p1_mask_q, p0_only_mask_q;

  // Span & page split registers
  logic [15:0] first_p0_elem_q, last_active_elem_q;
  logic [15:0] first_p1_elem_q, last_p0_only_elem_q;
  logic has_p1_q, has_p0_only_elems_q;
  logic [XLEN-1:0] va_first_q, va_last_end_q, va_first_p1_q, va_last_p0_only_end_q;
  logic [XLEN-1:0] p1_tval_q;

  // Walk & verdict registers
  logic [riscv_pkg::Sv39VpnBits-1:0] walk_vpn_q;
  logic walk_reissue_q;
  logic [riscv_pkg::VmtPpnBits-1:0] ppn0_q, ppn1_q;
  riscv_pkg::vmt_seg_t seg0_q, seg1_q;

  // Fault & shield registers
  riscv_pkg::exc_cause_t fault_cause_q;
  logic [XLEN-1:0] fault_tval_q;
  logic fault_vstart_en_q;
  logic [15:0] fault_vstart_q;
  logic shield_q;
  logic zero_vmt_done_valid_q;
  logic [VmtIdxW-1:0] zero_vmt_done_idx_q;

  // --------------------------------------------------------------------------
  // Instruction field extraction & HM_DECODE legality/mask calculation
  // --------------------------------------------------------------------------
  logic dec_is_store, dec_vm, dec_is_whole, dec_is_mask;
  logic [4:0] dec_vd_vs3, dec_rs1, dec_umop;
  logic [2:0] dec_width, dec_nf;
  logic [1:0] dec_eew_log2;

  assign dec_is_store = insn_q[5];
  assign dec_vd_vs3   = insn_q[11:7];
  assign dec_width    = insn_q[14:12];
  assign dec_rs1      = insn_q[19:15];
  assign dec_umop     = insn_q[24:20];
  assign dec_vm       = insn_q[25];
  assign dec_nf       = insn_q[31:29];
  assign dec_is_whole = (dec_umop == 5'b01000);
  assign dec_is_mask  = (dec_umop == 5'b01011);

  always_comb begin
    if (dec_is_mask) begin
      dec_eew_log2 = 2'd0;
    end else begin
      unique case (dec_width)
        3'b000:  dec_eew_log2 = 2'd0;
        3'b101:  dec_eew_log2 = 2'd1;
        3'b110:  dec_eew_log2 = 2'd2;
        default: dec_eew_log2 = 2'd3;
      endcase
    end
  end

  logic dec_vill;
  logic [2:0] dec_vsew, dec_vlmul;
  logic signed [4:0] dec_lmul_log2, dec_emul_log2;
  logic [4:0] dec_align_mask;
  logic dec_illegal;
  logic [15:0] dec_evl;
  logic [VLEN-1:0] dec_active_mask;

  assign dec_vill  = vtype_q[8];
  assign dec_vsew  = vtype_q[5:3];
  assign dec_vlmul = vtype_q[2:0];

  always_comb begin
    unique case (dec_vlmul)
      3'b000:  dec_lmul_log2 = 5'sd0;
      3'b001:  dec_lmul_log2 = 5'sd1;
      3'b010:  dec_lmul_log2 = 5'sd2;
      3'b011:  dec_lmul_log2 = 5'sd3;
      3'b101:  dec_lmul_log2 = -5'sd3;
      3'b110:  dec_lmul_log2 = -5'sd2;
      default: dec_lmul_log2 = -5'sd1;
    endcase
    dec_emul_log2 = dec_lmul_log2 + $signed({3'b000, dec_eew_log2}) -
        $signed({3'b000, dec_vsew[1:0]});
    unique case (dec_emul_log2)
      5'sd1:   dec_align_mask = 5'b00001;
      5'sd2:   dec_align_mask = 5'b00011;
      5'sd3:   dec_align_mask = 5'b00111;
      default: dec_align_mask = 5'b00000;
    endcase

    if (dec_is_whole) begin
      dec_illegal = ((dec_vd_vs3 & {2'b00, dec_nf}) != 5'd0);
      dec_evl     = (({12'd0, dec_nf} + 16'd1) * 16'(VlenBytes)) >> dec_eew_log2;
    end else if (dec_is_mask) begin
      dec_illegal = dec_vill || dec_vsew[2] || (dec_vlmul == 3'b100);
      dec_evl     = (vl_q + 16'd7) >> 3;
    end else begin
      dec_illegal = dec_vill || dec_vsew[2] || (dec_vlmul == 3'b100) ||
                    (dec_emul_log2 < -5'sd3) || (dec_emul_log2 > 5'sd3) ||
                    ((dec_vd_vs3 & dec_align_mask) != 5'd0) ||
                    (!dec_vm && !dec_is_store && (dec_vd_vs3 == 5'd0));
      dec_evl = vl_q;
    end

    for (int i = 0; i < VLEN; i++) begin
      dec_active_mask[i] = (16'(i) >= vstart_q) && (16'(i) < dec_evl) &&
                           ((dec_vm || dec_is_whole || dec_is_mask) ? 1'b1 : i_vrf_read_data[i]);
    end
  end

  // --------------------------------------------------------------------------
  // Two-stage 16-bit group priority encoders (shared by HM_SPAN0/1 and HM_P1_SPAN0/1)
  // --------------------------------------------------------------------------
  logic span_use_p1_masks;
  logic [VLEN-1:0] enc_lo_src, enc_hi_src;
  logic [NumGroups16-1:0] grp_lo_any_d, grp_hi_any_d;
  logic [NumGroups16-1:0][3:0] grp_lo_idx_d, grp_hi_idx_d;
  logic red_lo_any, red_hi_any;
  logic [ElemBits-1:0] red_lo_elem, red_hi_elem;

  assign span_use_p1_masks = (state_q == HM_P1_SPAN0);
  assign enc_lo_src        = span_use_p1_masks ? p1_mask_q : active_mask_q;
  assign enc_hi_src        = span_use_p1_masks ? p0_only_mask_q : active_mask_q;

  always_comb begin
    for (int g = 0; g < NumGroups16; g++) begin
      logic [15:0] gl, gh;
      logic found_l;
      gl = enc_lo_src[16*g+:16];
      gh = enc_hi_src[16*g+:16];
      grp_lo_any_d[g] = |gl;
      grp_hi_any_d[g] = |gh;
      grp_lo_idx_d[g] = '0;
      grp_hi_idx_d[g] = '0;
      found_l = 1'b0;
      for (int k = 0; k < 16; k++) begin
        if (!found_l && gl[k]) begin
          grp_lo_idx_d[g] = 4'(k);
          found_l = 1'b1;
        end
        if (gh[k]) begin
          grp_hi_idx_d[g] = 4'(k);
        end
      end
    end

    red_lo_any  = 1'b0;
    red_hi_any  = 1'b0;
    red_lo_elem = '0;
    red_hi_elem = '0;
    for (int g = 0; g < NumGroups16; g++) begin
      if (!red_lo_any && grp_lo_any_q[g]) begin
        red_lo_any  = 1'b1;
        red_lo_elem = (ElemBits'(g) << 4) | ElemBits'(grp_lo_idx_q[g]);
      end
      if (grp_hi_any_q[g]) begin
        red_hi_any  = 1'b1;
        red_hi_elem = (ElemBits'(g) << 4) | ElemBits'(grp_hi_idx_q[g]);
      end
    end
  end

  // Span addresses & Page-1 candidate calculation (from registered element indices)
  logic [XLEN-1:0] eew_last_byte_mask;
  logic [XLEN-1:0] span_va_first, span_va_last_end;
  logic span_has_p1;
  logic [12:0] bytes_rem_p0;
  logic [15:0] cand_p1;
  logic [VLEN-1:0] p1_mask_d, p0_only_mask_d;
  logic [XLEN-1:0] va_first_p1_d, va_last_p0_only_end_d;

  assign eew_last_byte_mask = {
    61'd0, (eew_log2_q == 2'd3), (eew_log2_q >= 2'd2), (eew_log2_q >= 2'd1)
  };
  assign span_va_first = rs1_q + (64'(first_p0_elem_q) << eew_log2_q);
  assign span_va_last_end = rs1_q + ((64'(last_active_elem_q) << eew_log2_q) | eew_last_byte_mask);
  assign span_has_p1 = (va_first_q[XLEN-1:12] != va_last_end_q[XLEN-1:12]);
  assign bytes_rem_p0 = 13'd4096 - {1'b0, va_first_q[11:0]};
  assign cand_p1 = first_p0_elem_q + 16'(bytes_rem_p0 >> eew_log2_q);

  always_comb begin
    for (int i = 0; i < VLEN; i++) begin
      p1_mask_d[i]      = active_mask_q[i] && (16'(i) >= cand_p1);
      p0_only_mask_d[i] = active_mask_q[i] && (16'(i) < cand_p1);
    end
  end

  assign va_first_p1_d = rs1_q + (64'(first_p1_elem_q) << eew_log2_q);
  assign va_last_p0_only_end_d = rs1_q +
      ((64'(last_p0_only_elem_q) << eew_log2_q) | eew_last_byte_mask);

  // --------------------------------------------------------------------------
  // Translation & region checks (Bare and Sv39 walk responses)
  // --------------------------------------------------------------------------
  logic checking_p1;
  logic [XLEN-1:0] cur_check_va, walk_pa;
  logic cur_va_canonical, bare_cached_ok, walk_resp_match;
  ma_pkg::ma_part_e walk_verdict;
  riscv_pkg::exc_cause_t page_fault_cause, access_fault_cause;

  assign checking_p1 = (state_q == HM_CHECK_P1) || (state_q == HM_WALK_REQ_P1) ||
                       (state_q == HM_WALK_WAIT_P1);
  assign cur_check_va = checking_p1 ? {va_last_end_q[XLEN-1:12], 12'h000} : va_first_q;
  assign cur_va_canonical = riscv_pkg::sv39_va_canonical(cur_check_va);
  assign bare_cached_ok = CACHED_TIER_EN && riscv_pkg::pma_cached_ok(cur_check_va);
  assign walk_resp_match = i_walk_resp_valid && (i_walk_resp.vpn == walk_vpn_q);
  assign walk_pa = ma_pkg::leaf_pa(i_walk_resp.ppn, i_walk_resp.level, cur_check_va);

  assign page_fault_cause = is_store_q ?
      riscv_pkg::ExcCauseWidth'(riscv_pkg::ExcStorePageFault) :
      riscv_pkg::ExcCauseWidth'(riscv_pkg::ExcLoadPageFault);
  assign access_fault_cause = is_store_q ?
      riscv_pkg::ExcCauseWidth'(riscv_pkg::ExcStoreAccessFault) :
      riscv_pkg::ExcCauseWidth'(riscv_pkg::ExcLoadAccessFault);

  logic walk_perm_ok;
  assign walk_perm_ok = ma_pkg::leaf_perm_ok(
      is_store_q,
      i_walk_resp.perm_r,
      i_walk_resp.perm_w,
      i_walk_resp.perm_x,
      i_walk_resp.perm_u,
      i_walk_resp.perm_d,
      eff_priv_u_q,
      sum_q,
      mxr_q
  );

  always_comb begin
    unique case (i_walk_resp.fault_kind)
      riscv_pkg::DFAULT_PAGE: walk_verdict = ma_pkg::MaPartPage;
      riscv_pkg::DFAULT_ACCESS: begin
        // A no-alias Svpbmt leaf carries permissions; its page fault wins.
        walk_verdict = ((i_walk_resp.pbmt != riscv_pkg::PbmtPma) && !walk_perm_ok) ?
            ma_pkg::MaPartPage : ma_pkg::MaPartAccess;
      end
      default: begin
        if (!walk_perm_ok) begin
          walk_verdict = ma_pkg::MaPartPage;
        end else if ((i_walk_resp.pbmt != riscv_pkg::PbmtPma) || ma_pkg::leaf_ppn_out_of_range(
                i_walk_resp.ppn
            )) begin
          walk_verdict = ma_pkg::MaPartAccess;
        end else if (!CACHED_TIER_EN || !riscv_pkg::pma_cached_ok(walk_pa)) begin
          walk_verdict = ma_pkg::MaPartAccess;
        end else begin
          walk_verdict = ma_pkg::MaPartOk;
        end
      end
    endcase
  end

  // VMT segment builders
  riscv_pkg::vmt_seg_t full_seg0_d, full_seg1_d, partial_seg0_d;
  always_comb begin
    full_seg0_d    = '0;
    full_seg1_d    = '0;
    partial_seg0_d = '0;
    if (!zero_active_q) begin
      full_seg0_d.valid = 1'b1;
      full_seg0_d.ppn   = ppn0_q;
      full_seg0_d.s_lo  = va_first_q[11:5];
      full_seg0_d.s_hi  = has_p1_q ? 7'd127 : va_last_end_q[11:5];
      if (has_p1_q) begin
        full_seg1_d.valid = 1'b1;
        full_seg1_d.ppn   = ppn1_q;
        full_seg1_d.s_lo  = 7'd0;
        full_seg1_d.s_hi  = va_last_end_q[11:5];
      end
    end
    partial_seg0_d.valid = 1'b1;
    partial_seg0_d.ppn   = ppn0_q;
    partial_seg0_d.s_lo  = va_first_q[11:5];
    partial_seg0_d.s_hi  = va_last_p0_only_end_q[11:5];
  end

  // --------------------------------------------------------------------------
  // Control & datapath state machine
  // --------------------------------------------------------------------------
  // Head metadata and cancellation are sampled locally. The first HM_WAIT
  // cycle lets the tag comparison catch up with the captured instruction.
  logic head_matches_q;
  logic head_vmem_q, flush_q, fatal_q;
  logic [TagW-1:0] head_tag_q;
  logic [31:0] head_insn_q;
  logic [VmtIdxW-1:0] head_vmt_idx_q;
  logic cancel_outputs;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      head_vmem_q <= 1'b0;
      head_matches_q <= 1'b0;
      flush_q <= 1'b0;
      fatal_q <= 1'b0;
    end else begin
      head_vmem_q <= !i_rob_empty && i_head_is_vmem && i_head_safe;
      head_matches_q <= !i_rob_empty && (i_head_tag == tag_q) && i_head_safe;
      flush_q <= i_flush_all;
      fatal_q <= i_fatal_stop || i_vmu_fatal;
    end
    head_tag_q <= i_head_tag;
    head_insn_q <= i_head_insn;
    head_vmt_idx_q <= i_head_vmt_idx;
  end

  // Suppress requests and publications immediately and throughout cleanup.
  // The fault-vstart sideband remains available on the trap-taking edge.
  assign cancel_outputs = i_flush_all || flush_q || i_fatal_stop || i_vmu_fatal || fatal_q;
  logic commit_hit;
  logic cdb_accepted_q;

  // A granted packet enters the registered CDB on this edge. Suppress its
  // valid while the state machine consumes the local acknowledgement;
  // the registered retirement bus cannot arrive before HM_WAIT_RETIRE.
  always_ff @(posedge i_clk) begin
    if (i_rst) cdb_accepted_q <= 1'b0;
    else cdb_accepted_q <= o_cdb_done;
  end

  assign commit_hit = (state_q == HM_WAIT_RETIRE) && i_commit_valid &&
                      (i_commit_tag == tag_q) && !i_commit_exception;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q               <= HM_IDLE;
      wait_q                <= 1'b0;
      walk_reissue_q        <= 1'b0;
      shield_q              <= 1'b0;
      fault_vstart_en_q     <= 1'b0;
      zero_vmt_done_valid_q <= 1'b0;
      zero_vmt_done_idx_q   <= '0;
    end else begin
      zero_vmt_done_valid_q <= 1'b0;

      if (fatal_q) begin
        state_q           <= HM_FATAL;
        shield_q          <= 1'b1;
        fault_vstart_en_q <= 1'b0;
      end else if (flush_q) begin
        // Outputs are inhibited from the flush cycle through this cleanup
        // edge. Retired memory work is owned by the VMU and is not cancelled.
        state_q           <= HM_IDLE;
        wait_q            <= 1'b0;
        walk_reissue_q    <= 1'b0;
        shield_q          <= 1'b0;
        fault_vstart_en_q <= 1'b0;
      end else begin
        if (i_tlb_invalidate && ((state_q == HM_WALK_REQ_P0) || (state_q == HM_WALK_WAIT_P0) ||
                                 (state_q == HM_WALK_REQ_P1) || (state_q == HM_WALK_WAIT_P1))) begin
          walk_reissue_q <= 1'b1;
        end

        unique case (state_q)
          HM_IDLE: begin
            shield_q          <= 1'b0;
            fault_vstart_en_q <= 1'b0;
            if (head_vmem_q && i_vec_idle && !i_csr_wb_pending && !i_int_take_armed) begin
              tag_q     <= head_tag_q;
              insn_q    <= head_insn_q;
              vmt_idx_q <= head_vmt_idx_q;
              wait_q    <= 1'b0;
              state_q   <= HM_WAIT;
            end
          end

          HM_WAIT: begin
            if (!wait_q) begin
              wait_q <= 1'b1;
            end else if (!head_matches_q || i_int_take_armed) begin
              state_q <= HM_IDLE;
              wait_q  <= 1'b0;
            end else if (i_vec_idle && !i_csr_wb_pending) begin
              // Older registered commits have landed in csr_file, VIQ, VRF,
              // and integer RF; o_rf_read_en and o_vrf_read_en sample rs1 and v0
              // on this clock edge.
              vl_q         <= i_vl;
              vtype_q      <= i_vtype;
              vstart_q     <= i_vstart;
              translate_q  <= i_translate;
              eff_priv_u_q <= i_eff_priv_u;
              sum_q        <= i_sum;
              mxr_q        <= i_mxr;
              state_q      <= HM_DECODE;
            end
          end

          HM_DECODE: begin
            if (!head_matches_q || i_int_take_armed) begin
              state_q <= HM_IDLE;
            end else begin
              rs1_q         <= (dec_rs1 == 5'd0) ? '0 : i_rf_read_data;
              is_store_q    <= dec_is_store;
              is_whole_q    <= dec_is_whole;
              is_mask_q     <= dec_is_mask;
              vm_q          <= dec_vm;
              vd_vs3_q      <= dec_vd_vs3;
              eew_log2_q    <= dec_eew_log2;
              evl_q         <= dec_evl;
              active_mask_q <= dec_active_mask;
              if (dec_illegal) begin
                fault_cause_q     <= riscv_pkg::ExcCauseWidth'(riscv_pkg::ExcIllegalInstr);
                fault_tval_q      <= XLEN'(insn_q);
                fault_vstart_en_q <= 1'b0;
                state_q           <= HM_FAULT_ARM;
              end else begin
                state_q <= HM_SPAN0;
              end
            end
          end

          HM_SPAN0: begin
            grp_lo_any_q <= grp_lo_any_d;
            grp_hi_any_q <= grp_hi_any_d;
            grp_lo_idx_q <= grp_lo_idx_d;
            grp_hi_idx_q <= grp_hi_idx_d;
            state_q      <= HM_SPAN1;
          end

          HM_SPAN1: begin
            if (!red_lo_any) begin
              zero_active_q <= 1'b1;
              has_p1_q      <= 1'b0;
              seg0_q        <= '0;
              seg1_q        <= '0;
              state_q       <= HM_COMMIT_ARM;
            end else begin
              zero_active_q      <= 1'b0;
              first_p0_elem_q    <= 16'(red_lo_elem);
              last_active_elem_q <= 16'(red_hi_elem);
              state_q            <= HM_SPAN1_ADD;
            end
          end

          HM_SPAN1_ADD: begin
            va_first_q    <= span_va_first;
            va_last_end_q <= span_va_last_end;
            state_q       <= HM_SPAN2;
          end

          HM_SPAN2: begin
            has_p1_q       <= span_has_p1;
            p1_mask_q      <= p1_mask_d;
            p0_only_mask_q <= p0_only_mask_d;
            if (!span_has_p1) begin
              has_p0_only_elems_q <= 1'b0;
              state_q             <= HM_CHECK_P0;
            end else begin
              state_q <= HM_P1_SPAN0;
            end
          end

          HM_P1_SPAN0: begin
            grp_lo_any_q <= grp_lo_any_d;
            grp_hi_any_q <= grp_hi_any_d;
            grp_lo_idx_q <= grp_lo_idx_d;
            grp_hi_idx_q <= grp_hi_idx_d;
            state_q      <= HM_P1_SPAN1;
          end

          HM_P1_SPAN1: begin
            first_p1_elem_q     <= 16'(red_lo_elem);
            last_p0_only_elem_q <= 16'(red_hi_elem);
            has_p0_only_elems_q <= red_hi_any;
            state_q             <= HM_P1_SPAN1_ADD;
          end

          HM_P1_SPAN1_ADD: begin
            va_first_p1_q         <= va_first_p1_d;
            va_last_p0_only_end_q <= va_last_p0_only_end_d;
            state_q               <= HM_P1_SPAN1_TVAL;
          end

          HM_P1_SPAN1_TVAL: begin
            p1_tval_q <= (va_first_p1_q[XLEN-1:12] == va_first_q[XLEN-1:12]) ?
                         {va_last_end_q[XLEN-1:12], 12'h000} : va_first_p1_q;
            state_q <= HM_CHECK_P0;
          end

          HM_CHECK_P0: begin
            if (!translate_q) begin
              if (bare_cached_ok) begin
                ppn0_q  <= cur_check_va[12+:riscv_pkg::VmtPpnBits];
                state_q <= has_p1_q ? HM_CHECK_P1 : HM_COMMIT_ARM;
              end else begin
                fault_cause_q     <= access_fault_cause;
                fault_tval_q      <= va_first_q;
                fault_vstart_en_q <= 1'b1;
                fault_vstart_q    <= first_p0_elem_q;
                state_q           <= HM_FAULT_ARM;
              end
            end else if (!cur_va_canonical) begin
              fault_cause_q     <= page_fault_cause;
              fault_tval_q      <= va_first_q;
              fault_vstart_en_q <= 1'b1;
              fault_vstart_q    <= first_p0_elem_q;
              state_q           <= HM_FAULT_ARM;
            end else begin
              walk_vpn_q     <= cur_check_va[38:12];
              walk_reissue_q <= 1'b0;
              state_q        <= HM_WALK_REQ_P0;
            end
          end

          HM_WALK_REQ_P0: begin
            if (i_tlb_invalidate) begin
              walk_reissue_q <= 1'b0;
            end else if (i_walk_req_ready) begin
              walk_reissue_q <= 1'b0;
              state_q        <= HM_WALK_WAIT_P0;
            end
          end

          HM_WALK_WAIT_P0: begin
            if (walk_reissue_q || i_tlb_invalidate) begin
              walk_reissue_q <= 1'b0;
              state_q        <= HM_WALK_REQ_P0;
            end else if (walk_resp_match) begin
              if (walk_verdict == ma_pkg::MaPartOk) begin
                ppn0_q  <= walk_pa[12+:riscv_pkg::VmtPpnBits];
                state_q <= has_p1_q ? HM_CHECK_P1 : HM_COMMIT_ARM;
              end else begin
                fault_cause_q     <= (walk_verdict == ma_pkg::MaPartPage) ?
                                     page_fault_cause : access_fault_cause;
                fault_tval_q <= va_first_q;
                fault_vstart_en_q <= 1'b1;
                fault_vstart_q <= first_p0_elem_q;
                state_q <= HM_FAULT_ARM;
              end
            end
          end

          HM_CHECK_P1: begin
            if (!translate_q) begin
              if (bare_cached_ok) begin
                ppn1_q  <= cur_check_va[12+:riscv_pkg::VmtPpnBits];
                state_q <= HM_COMMIT_ARM;
              end else begin
                fault_cause_q     <= access_fault_cause;
                fault_tval_q      <= p1_tval_q;
                fault_vstart_en_q <= 1'b1;
                fault_vstart_q    <= first_p1_elem_q;
                state_q           <= has_p0_only_elems_q ? HM_PARTIAL_ARM : HM_FAULT_ARM;
              end
            end else if (!cur_va_canonical) begin
              fault_cause_q     <= page_fault_cause;
              fault_tval_q      <= p1_tval_q;
              fault_vstart_en_q <= 1'b1;
              fault_vstart_q    <= first_p1_elem_q;
              state_q           <= has_p0_only_elems_q ? HM_PARTIAL_ARM : HM_FAULT_ARM;
            end else begin
              walk_vpn_q     <= cur_check_va[38:12];
              walk_reissue_q <= 1'b0;
              state_q        <= HM_WALK_REQ_P1;
            end
          end

          HM_WALK_REQ_P1: begin
            if (i_tlb_invalidate) begin
              walk_reissue_q <= 1'b0;
            end else if (i_walk_req_ready) begin
              walk_reissue_q <= 1'b0;
              state_q        <= HM_WALK_WAIT_P1;
            end
          end

          HM_WALK_WAIT_P1: begin
            if (walk_reissue_q || i_tlb_invalidate) begin
              walk_reissue_q <= 1'b0;
              state_q        <= HM_WALK_REQ_P1;
            end else if (walk_resp_match) begin
              if (walk_verdict == ma_pkg::MaPartOk) begin
                ppn1_q  <= walk_pa[12+:riscv_pkg::VmtPpnBits];
                state_q <= HM_COMMIT_ARM;
              end else begin
                fault_cause_q     <= (walk_verdict == ma_pkg::MaPartPage) ?
                                     page_fault_cause : access_fault_cause;
                fault_tval_q <= p1_tval_q;
                fault_vstart_en_q <= 1'b1;
                fault_vstart_q <= first_p1_elem_q;
                state_q <= has_p0_only_elems_q ? HM_PARTIAL_ARM : HM_FAULT_ARM;
              end
            end
          end

          // Case C: Page 0 valid with Page-0-only elements, Page 1 faults.
          HM_PARTIAL_ARM: begin
            if (!head_matches_q || i_int_take_armed) begin
              state_q           <= HM_IDLE;
              fault_vstart_en_q <= 1'b0;
            end else if (i_sq_committed_empty) begin
              seg0_q   <= partial_seg0_d;
              seg1_q   <= '0;
              shield_q <= 1'b1;
              state_q  <= HM_PARTIAL_SETTLE;
            end
          end

          HM_PARTIAL_SETTLE: begin
            // The shield and head check have settled before the launch.
            state_q <= head_matches_q ? HM_PARTIAL_RUN : HM_IDLE;
            if (!head_matches_q) shield_q <= 1'b0;
          end

          HM_PARTIAL_RUN: begin
            if (i_vmu_done) begin
              state_q <= HM_CDB_FAULT;
            end
          end

          // Pure head fault (zero memory bytes accessed).
          HM_FAULT_ARM: begin
            if (!head_matches_q || i_int_take_armed) begin
              state_q           <= HM_IDLE;
              fault_vstart_en_q <= 1'b0;
            end else begin
              shield_q <= 1'b1;
              state_q  <= HM_FAULT_SETTLE;
            end
          end

          HM_FAULT_SETTLE: begin
            state_q <= head_matches_q ? HM_CDB_FAULT : HM_IDLE;
            if (!head_matches_q) shield_q <= 1'b0;
          end

          HM_CDB_FAULT: begin
            if (cdb_accepted_q) begin
              state_q <= HM_WAIT_TRAP;
            end
          end

          HM_WAIT_TRAP: begin
            // Hold fault_vstart and shield_q until the synchronous trap takes
            // and asserts i_flush_all.
          end

          // Non-faulting completion & retirement.
          HM_COMMIT_ARM: begin
            if (!head_matches_q || i_int_take_armed) begin
              state_q <= HM_IDLE;
            end else if (i_sq_committed_empty) begin
              seg0_q   <= full_seg0_d;
              seg1_q   <= full_seg1_d;
              shield_q <= 1'b1;
              state_q  <= HM_COMMIT_SETTLE;
            end
          end

          HM_COMMIT_SETTLE: begin
            state_q <= head_matches_q ? HM_CDB_OK : HM_IDLE;
            if (!head_matches_q) shield_q <= 1'b0;
          end

          HM_CDB_OK: begin
            if (cdb_accepted_q) begin
              state_q <= HM_WAIT_RETIRE;
            end
          end

          HM_WAIT_RETIRE: begin
            if (commit_hit) begin
              shield_q <= 1'b0;
              state_q  <= HM_IDLE;
              if (zero_active_q) begin
                zero_vmt_done_valid_q <= 1'b1;
                zero_vmt_done_idx_q   <= vmt_idx_q;
              end
            end
          end

          default: ;  // HM_FATAL holds until reset
        endcase
      end
    end
  end

  // --------------------------------------------------------------------------
  // Outputs
  // --------------------------------------------------------------------------
  logic read_regs_now;
  assign read_regs_now = !cancel_outputs && (state_q == HM_WAIT) && wait_q &&
                         head_matches_q && !i_int_take_armed &&
                         i_vec_idle && !i_csr_wb_pending;

  assign o_rf_read_en = read_regs_now;
  assign o_rf_read_addr = dec_rs1;
  assign o_vrf_read_en = read_regs_now;
  assign o_vrf_read_addr = 5'd0;

  assign o_walk_req_valid = !cancel_outputs && head_matches_q &&
                            ((state_q == HM_WALK_REQ_P0) || (state_q == HM_WALK_REQ_P1));
  assign o_walk_vpn = walk_vpn_q;

  assign o_vmt_range_valid = !cancel_outputs && head_matches_q &&
                             ((state_q == HM_COMMIT_SETTLE) || (state_q == HM_PARTIAL_SETTLE));
  assign o_vmt_range_idx = vmt_idx_q;
  assign o_vmt_range_seg0 = seg0_q;
  assign o_vmt_range_seg1 = seg1_q;

  assign o_zero_vmt_done_valid = zero_vmt_done_valid_q;
  assign o_zero_vmt_done_idx = zero_vmt_done_idx_q;

  always_comb begin
    o_vhead_complete = '0;
    if (!cancel_outputs && head_matches_q && !cdb_accepted_q) begin
      if (state_q == HM_CDB_OK) begin
        o_vhead_complete.valid = 1'b1;
        o_vhead_complete.tag   = tag_q;
      end else if (state_q == HM_CDB_FAULT) begin
        o_vhead_complete.valid     = 1'b1;
        o_vhead_complete.tag       = tag_q;
        o_vhead_complete.exception = 1'b1;
        o_vhead_complete.exc_cause = fault_cause_q;
        o_vhead_complete.value     = riscv_pkg::FLEN'(fault_tval_q);
      end
    end
  end

  assign o_cdb_done = o_vhead_complete.valid && i_grant;
  assign o_cdb_done_tag = tag_q;

  assign o_vmem_head_shield = shield_q;
  assign o_vmem_fault_vstart_valid = fault_vstart_en_q &&
                                     ((state_q == HM_CDB_FAULT) || (state_q == HM_WAIT_TRAP));
  assign o_vmem_fault_vstart = fault_vstart_q;

  assign o_retire_vload = commit_hit && !is_store_q;
  assign o_retire_vstore = commit_hit && is_store_q;

  logic partial_launch, retire_launch;
  assign partial_launch = !cancel_outputs && head_matches_q && (state_q == HM_PARTIAL_SETTLE);
  assign retire_launch = !cancel_outputs && commit_hit && !zero_active_q;

  assign o_desc_valid = partial_launch || retire_launch;
  assign o_desc_ppn0 = ppn0_q;
  assign o_desc_ppn1 = ppn1_q;
  assign o_desc_page_offset = va_first_q[11:0];
  assign o_desc_first_elem = first_p0_elem_q;
  assign o_desc_last_elem = partial_launch ? last_p0_only_elem_q : last_active_elem_q;
  assign o_desc_eew_log2 = eew_log2_q;
  assign o_desc_active_mask = active_mask_q;
  assign o_desc_is_store = is_store_q;
  assign o_desc_vd_vs3 = vd_vs3_q;
  assign o_desc_vmt_idx = vmt_idx_q;
  assign o_desc_free_vmt_on_done = !partial_launch;
  assign o_desc_seg0 = seg0_q;
  assign o_desc_seg1 = seg1_q;

`ifndef SYNTHESIS
`ifndef FORMAL
  logic hm_reset_seen_q = 1'b0;
  always @(posedge i_clk) begin
    if (i_rst) hm_reset_seen_q <= 1'b1;
    if (hm_reset_seen_q && !i_rst) begin
      // Completion is presented only while tag_q is the ROB head.
      assert (!o_vhead_complete.valid || (!i_rob_empty && (i_head_tag == tag_q)));
      // A retired non-faulting op waiting in HM_WAIT_RETIRE must never be flushed.
      assert (!((state_q == HM_WAIT_RETIRE) && i_flush_all));
      // Case-C partial launch always stays inside Page 0.
      assert (!partial_launch || (last_p0_only_elem_q < first_p1_elem_q));
    end
  end
`endif
`endif


`ifdef VEC_HEAD_MMU_PROOF
  logic f_past_valid = 1'b0;
  logic f_cdb_accepted = 1'b0;
  logic f_cdb_registered = 1'b0;
  logic f_launched = 1'b0;
  logic f_retired = 1'b0;
  logic [1:0] f_walks = '0;
  logic f_walk_pending = 1'b0;
  logic [riscv_pkg::Sv39VpnBits-1:0] f_pending_vpn;
  logic [1:0] f_pages_checked = '0;
  (* anyconst *) logic f_page1_fault;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid)
      assume (i_rst);
      else assume (!i_rst);
    assume (!i_flush_all && !i_fatal_stop && !i_vmu_fatal);
    assume (i_head_tag == 3 && !i_rob_empty && i_head_safe);
    // vec_unit clears the head's vector memory flag on the edge that accepts
    // its CDB completion.
    assume (i_head_is_vmem == !f_cdb_accepted && i_head_insn == 32'h02056407);
    assume (i_head_vmt_idx == 0 && i_vec_idle && !i_csr_wb_pending && !i_int_take_armed);
    assume (i_vl == 4 && i_vtype == 9'h10 && i_vstart == 0);
    assume (i_rf_read_data == 64'h400ff8 && i_vrf_read_data == '1);
    assume (i_translate && !i_eff_priv_u && !i_sum && !i_mxr && !i_tlb_invalidate);
    // The CDB is registered before the ROB, whose earliest (bypass) commit
    // follows in the next cycle, and the commit bus is registered again: the
    // registered commit arrives at least two cycles after the acceptance.
    assume (!i_commit_valid || (f_cdb_registered && !f_page1_fault && !f_retired));
    assume (i_commit_tag == 3 && !i_commit_exception);
    assume (!i_vmu_done || f_launched);
    if (i_walk_resp_valid) begin
      assume (f_walk_pending);
      assume (i_walk_resp.vpn == f_pending_vpn);
      assume (i_walk_resp.ppn == (f_pending_vpn == 27'h400 ? 44'h83000 : 44'h83100));
      assume (i_walk_resp.level == 0 && i_walk_resp.pbmt == 0);
      assume (i_walk_resp.perm_r && i_walk_resp.perm_w && i_walk_resp.perm_d);
      assume (!i_walk_resp.perm_u);
      assume (i_walk_resp.fault_kind == ((f_pending_vpn == 27'h401 && f_page1_fault) ?
          riscv_pkg::DFAULT_PAGE : riscv_pkg::DFAULT_NONE));
    end
    if (i_rst) begin
      f_cdb_accepted <= 1'b0;
      f_cdb_registered <= 1'b0;
      f_launched <= 1'b0;
      f_retired <= 1'b0;
      f_walks <= '0;
      f_walk_pending <= 1'b0;
      f_pending_vpn <= '0;
      f_pages_checked <= '0;
    end else begin
      if (o_walk_req_valid && i_walk_req_ready) begin
        f_walk_pending <= 1'b1;
        f_pending_vpn  <= o_walk_vpn;
      end
      if (i_walk_resp_valid) begin
        f_walk_pending <= 1'b0;
        f_walks <= f_walks + 1'b1;
        if (f_pending_vpn == 27'h400) f_pages_checked[0] <= 1'b1;
        if (f_pending_vpn == 27'h401) f_pages_checked[1] <= 1'b1;
      end
      if (o_cdb_done) begin
        f_cdb_accepted <= 1'b1;
        p_single_completion : assert (!f_cdb_accepted);
      end
      if (f_cdb_accepted) f_cdb_registered <= 1'b1;
      if (i_commit_valid) f_retired <= 1'b1;
      // Every commit of the instruction is consumed: it retires the load and
      // launches its descriptor.
      if (i_commit_valid) p_commit_consumed : assert (o_desc_valid && o_retire_vload);
      if (o_desc_valid) begin
        f_launched <= 1'b1;
        p_translate_before_access : assert (f_walks == 2 && f_pages_checked == 2'b11);
        p_single_launch : assert (!f_launched);
        if (f_page1_fault) begin
          p_fault_boundary :
          assert (o_desc_first_elem == 0 && o_desc_last_elem == 1 && o_desc_seg1 == 0);
        end else begin
          p_retirement : assert (i_commit_valid);
        end
      end
      if (o_desc_valid) begin
        p_launch_shield : assert (o_vmem_head_shield);
      end
      if (o_vhead_complete.valid) begin
        p_commit_shield : assert (o_vmem_head_shield && $past(o_vmem_head_shield));
      end
      if ($rose(o_vmem_head_shield)) begin
        p_store_drain : assert ($past(i_sq_committed_empty));
      end
      c_partial : cover (o_desc_valid && f_page1_fault);
      c_retired : cover (o_desc_valid && !f_page1_fault);
      // The commit at the earliest cycle the registered buses allow.
      c_earliest_commit : cover (i_commit_valid && !$past(f_cdb_registered));
    end
  end
`endif

endmodule : vec_head_mmu
