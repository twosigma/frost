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
  Head-executed legality, span calculation, and DMMU translation for vector
  loads and stores: unit-stride, whole-register and mask forms as one span,
  strided, indexed and segment forms element by element.

  A VLOAD or VSTORE dispatches with RS_NONE and waits for the ROB head. Once at
  the head with older vector and CSR work settled, this unit:
    1. Reads architectural vl, vtype, vstart, integer base rs1 (via the extra
       integer RF read port; a strided form's stride rs2 follows on the same
       port), and mask register v0 (via the VRF read port).
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

  Strided and indexed forms run their active elements in order at the head
  instead. For each element the unit forms the address, rs1 + i * rs2 for a
  strided form (a running sum stepped once per element) or rs1 plus the
  zero-extended index element i of vs2 for an indexed form (read through the
  VRF port in the cycle before), translates the one or two pages of the
  element's bytes, and then hands vec_vmu a descriptor for that element alone,
  waiting for its completion before the next element. Ordered and unordered
  indexed forms both run in element order. An indexed form's data EEW is SEW
  and its data EMUL is LMUL; the width field gives the index EEW and EMUL. A
  segment form (nf > 0, any addressing) treats each segment as the element:
  its NF fields are contiguous in memory from the segment's address (a
  unit-stride segment's stride is NF * EEW), the segment's one or two pages
  are translated first, and field f then gets its own descriptor with
  destination register group vd + f * EMUL. A fault on a segment is reported
  before any of its fields is accessed. A fault-only-first load runs as a
  unit-stride (segment) form; a fault on element i > 0 ends the run before
  element i without an exception, and the instruction's retirement sets vl
  to i (o_vl_trim); a fault on element 0 traps. The
  first access waits for committed scalar stores to drain and raises the
  interrupt shield, which stays up until the instruction traps or retires:
  once an element has been performed the run is never abandoned. A fault on
  element i traps with vstart = i after elements vstart..i-1 are performed.
  The VMT range is never written for these instructions, so younger scalar
  loads and stores wait for the whole instruction; the VMT entry is freed when
  the instruction retires.

  Element addresses take the Ssnpm pointer-masking transform of the data mode
  sampled with the translation state (riscv_pkg::pm_tval, sign extension under
  Sv39 and zero extension under Bare) before translation, and a fault's xtval
  is the transformed address. A load whose head-executed part (Case C or an
  element of a run) writes the VRF reports it on o_vmem_vs_dirty, so
  mstatus.VS becomes Dirty even when the following fault does not trap (Debug
  Mode).
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
    // Data pointer-masking mode (Ssnpm), registered in csr_file
    input  riscv_pkg::pm_mode_t                               i_pm_mode,
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
    // A head-executed load part wrote the VRF (registered pulse)
    output logic        o_vmem_vs_dirty,
    // A fault-only-first load retires with vl trimmed to o_vl_trim
    output logic        o_vl_trim_valid,
    output logic [15:0] o_vl_trim,

    // Command launch to vec_unit / vec_vmu (retired, Case-C partial Page-0, or
    // one element of a strided or indexed run)
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

    // Case-C partial Page-0 and run element completion from vec_vmu
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

  typedef enum logic [5:0] {
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
    HM_FATAL,
    // Strided and indexed forms: the stride read, then the element run
    HM_STRIDE_RD,
    HM_STRIDE_CAP,
    HM_RUN_SEEK,
    HM_RUN_ADDR,
    HM_RUN_SPLIT,
    HM_RUN_ARM,
    HM_RUN_SETTLE,
    HM_RUN_LAUNCH,
    HM_RUN_WAIT,
    // An indexed element's index: the VRF read, then the address
    HM_RUN_IDX,
    HM_RUN_IDX_CAP,
    // A fault-only-first load that stops before a faulting element > 0
    HM_RUN_TRIM,
    HM_RUN_TRIM_SETTLE
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
  riscv_pkg::pm_mode_t pm_mode_q;
  logic [XLEN-1:0] rs1_q;

  // Element run (strided and indexed forms): the current element, its
  // untransformed address, the stride, and whether the run has raised the
  // shield for its first access; for an indexed form, the index group and
  // the index EEW
  logic run_q, run_started_q, idx_q;
  logic [4:0] vs2_q;
  logic [1:0] ieew_log2_q;
  // Segment forms: fields minus one, the field in progress, log2 of the
  // registers per field, and the segment's last byte offset (EEW - 1 when
  // nf = 0)
  logic [2:0] nf_q, field_q;
  // Fault-only-first: the form, whether the run stopped at a fault, and the
  // element it stopped at (the new vl)
  logic ff_q, trim_q;
  logic [15:0] trim_vl_q;
  logic [1:0] emul_regs_log2_q;
  logic [XLEN-1:0] seg_last_q;
  logic [15:0] run_elem_q;
  logic [XLEN-1:0] run_addr_q, stride_q;
  logic vs_dirty_q;

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
  logic dec_is_store, dec_vm, dec_is_whole, dec_is_mask, dec_strided, dec_indexed;
  logic dec_seg, dec_unit_seg, dec_ff;
  logic [4:0] dec_vd_vs3, dec_rs1, dec_umop;
  logic [2:0] dec_width, dec_nf;
  // The width field's EEW (an indexed form's index EEW) and the data EEW
  logic [1:0] dec_weew_log2, dec_eew_log2, dec_mop;

  assign dec_is_store = insn_q[5];
  assign dec_vd_vs3   = insn_q[11:7];
  assign dec_width    = insn_q[14:12];
  assign dec_rs1      = insn_q[19:15];
  // lumop/sumop for unit-stride addressing, rs2 (the stride) for strided,
  // vs2 (the index group) for indexed
  assign dec_umop     = insn_q[24:20];
  assign dec_vm       = insn_q[25];
  assign dec_mop      = insn_q[27:26];
  assign dec_nf       = insn_q[31:29];
  assign dec_strided  = (dec_mop == 2'b10);
  assign dec_indexed  = dec_mop[0];
  // A segment form: nf > 0 on any addressing but whole-register (nf counts
  // registers there); mask forms have nf = 0.
  assign dec_seg      = (dec_nf != 3'd0) && !dec_is_whole;
  // Fault-only-first (lumop 10000) runs as a unit-stride segment form,
  // with one field when nf = 0.
  assign dec_ff       = (dec_mop == 2'b00) && (dec_umop == 5'b10000);
  assign dec_unit_seg = (dec_seg || dec_ff) && (dec_mop == 2'b00);
  assign dec_is_whole = (dec_mop == 2'b00) && (dec_umop == 5'b01000);
  assign dec_is_mask  = (dec_mop == 2'b00) && (dec_umop == 5'b01011);

  always_comb begin
    if (dec_is_mask) begin
      dec_weew_log2 = 2'd0;
    end else begin
      unique case (dec_width)
        3'b000:  dec_weew_log2 = 2'd0;
        3'b101:  dec_weew_log2 = 2'd1;
        3'b110:  dec_weew_log2 = 2'd2;
        default: dec_weew_log2 = 2'd3;
      endcase
    end
  end

  logic dec_vill;
  logic [2:0] dec_vsew, dec_vlmul;
  logic signed [4:0] dec_lmul_log2, dec_emul_log2;
  logic [4:0] dec_align_mask, dec_lmul_align_mask;
  // Indexed loads: the destination group (EEW SEW, EMUL LMUL) against the
  // index group (index EEW and EMUL), as register ranges
  logic [5:0] dec_d_hi, dec_i_hi;
  logic dec_idx_overlap, dec_idx_overlap_ok;
  // Segment forms: the data EMUL, registers per field (log2), the fields'
  // total registers and last register, and an indexed segment load's
  // overlap with the index group (always reserved)
  logic signed [4:0] dec_data_emul_log2;
  logic [1:0] dec_emul_regs_log2;
  logic [6:0] dec_seg_regs, dec_seg_hi, dec_seg_bytes;
  logic dec_seg_bad, dec_seg_idx_overlap;
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
    // Data EEW: SEW for an indexed form, else the width field's. EMUL from
    // the width field's EEW: the data EMUL, or an indexed form's index EMUL.
    dec_eew_log2 = dec_indexed ? dec_vsew[1:0] : dec_weew_log2;
    dec_emul_log2 = dec_lmul_log2 + $signed({3'b000, dec_weew_log2}) -
        $signed({3'b000, dec_vsew[1:0]});
    unique case (dec_emul_log2)
      5'sd1:   dec_align_mask = 5'b00001;
      5'sd2:   dec_align_mask = 5'b00011;
      5'sd3:   dec_align_mask = 5'b00111;
      default: dec_align_mask = 5'b00000;
    endcase
    unique case (dec_lmul_log2)
      5'sd1:   dec_lmul_align_mask = 5'b00001;
      5'sd2:   dec_lmul_align_mask = 5'b00011;
      5'sd3:   dec_lmul_align_mask = 5'b00111;
      default: dec_lmul_align_mask = 5'b00000;
    endcase
    // A destination group may overlap the index group only with equal EEWs,
    // at the index group's lowest register when the destination EEW is
    // smaller, or at the destination group's highest register when it is
    // larger and the index EMUL is at least 1.
    dec_d_hi = {1'b0, dec_vd_vs3} + {1'b0, dec_lmul_align_mask};
    dec_i_hi = {1'b0, dec_umop} + {1'b0, dec_align_mask};
    dec_idx_overlap = ({1'b0, dec_vd_vs3} <= dec_i_hi) && ({1'b0, dec_umop} <= dec_d_hi);
    dec_data_emul_log2 = dec_indexed ? dec_lmul_log2 : dec_emul_log2;
    dec_emul_regs_log2 = (dec_data_emul_log2 > 5'sd0) ? dec_data_emul_log2[1:0] : 2'd0;
    dec_seg_regs = 7'({1'b0, dec_nf} + 4'd1) << dec_emul_regs_log2;
    // A segment's bytes: NF * EEW (EEW when nf = 0), at most 64.
    dec_seg_bytes = 7'({1'b0, dec_seg ? dec_nf : 3'd0} + 4'd1) << dec_eew_log2;
    dec_seg_hi = {2'b00, dec_vd_vs3} + dec_seg_regs - 7'd1;
    dec_seg_bad = dec_seg && ((dec_seg_regs > 7'd8) || (dec_seg_hi > 7'd31));
    dec_seg_idx_overlap = ({2'b00, dec_vd_vs3} <= {1'b0, dec_i_hi}) &&
                          ({2'b00, dec_umop} <= dec_seg_hi);
    dec_idx_overlap_ok = (dec_weew_log2 == dec_vsew[1:0]) ||
        ((dec_vsew[1:0] < dec_weew_log2) && (dec_vd_vs3 == dec_umop)) ||
        ((dec_vsew[1:0] > dec_weew_log2) && (dec_emul_log2 >= 5'sd0) && (dec_i_hi == dec_d_hi));

    if (dec_is_whole) begin
      dec_illegal = ((dec_vd_vs3 & {2'b00, dec_nf}) != 5'd0);
      dec_evl     = (({12'd0, dec_nf} + 16'd1) * 16'(VlenBytes)) >> dec_eew_log2;
    end else if (dec_is_mask) begin
      dec_illegal = dec_vill || dec_vsew[2] || (dec_vlmul == 3'b100);
      dec_evl     = (vl_q + 16'd7) >> 3;
    end else if (dec_indexed) begin
      dec_illegal = dec_vill || dec_vsew[2] || (dec_vlmul == 3'b100) ||
                    (dec_emul_log2 < -5'sd3) || (dec_emul_log2 > 5'sd3) ||
                    ((dec_vd_vs3 & dec_lmul_align_mask) != 5'd0) ||
                    ((dec_umop & dec_align_mask) != 5'd0) ||
                    (!dec_vm && !dec_is_store && (dec_vd_vs3 == 5'd0)) || dec_seg_bad ||
                    (!dec_is_store && (dec_seg ? dec_seg_idx_overlap :
                                                 (dec_idx_overlap && !dec_idx_overlap_ok)));
      dec_evl = vl_q;
    end else begin
      dec_illegal = dec_vill || dec_vsew[2] || (dec_vlmul == 3'b100) ||
                    (dec_emul_log2 < -5'sd3) || (dec_emul_log2 > 5'sd3) ||
                    ((dec_vd_vs3 & dec_align_mask) != 5'd0) ||
                    (!dec_vm && !dec_is_store && (dec_vd_vs3 == 5'd0)) || dec_seg_bad;
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

  // Registered: set on the edge into HM_P1_SPAN0, so no state decode
  // reaches the encoders' VLEN-wide source muxes.
  logic span_p1_q;
  assign span_use_p1_masks = span_p1_q;
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
  logic [15:0] cand_p1, cand_p1_q;
  logic [VLEN-1:0] p1_mask_d, p0_only_mask_d;
  logic [XLEN-1:0] va_first_p1_d, va_last_p0_only_end_d;

  assign eew_last_byte_mask = {
    61'd0, (eew_log2_q == 2'd3), (eew_log2_q >= 2'd2), (eew_log2_q >= 2'd1)
  };
  assign span_va_first = rs1_q + (64'(first_p0_elem_q) << eew_log2_q);
  assign span_va_last_end = rs1_q + ((64'(last_active_elem_q) << eew_log2_q) | eew_last_byte_mask);
  assign span_has_p1 = (va_first_q[XLEN-1:12] != va_last_end_q[XLEN-1:12]);
  // The first element on page 1, taken in HM_SPAN1_ADD from the
  // untransformed first address: pointer masking changes no bit below 12.
  assign bytes_rem_p0 = 13'd4096 - {1'b0, span_va_first[11:0]};
  assign cand_p1 = cand_p1_q;

  always_comb begin
    for (int i = 0; i < VLEN; i++) begin
      p1_mask_d[i]      = active_mask_q[i] && (16'(i) >= cand_p1);
      p0_only_mask_d[i] = active_mask_q[i] && (16'(i) < cand_p1);
    end
  end

  assign va_first_p1_d = rs1_q + (64'(first_p1_elem_q) << eew_log2_q);
  assign va_last_p0_only_end_d = rs1_q +
      ((64'(last_p0_only_elem_q) << eew_log2_q) | eew_last_byte_mask);

  // A run element's first and last byte addresses after pointer masking.
  // The transform keeps bits [11:0], so page offsets and the page split are
  // those of the effective address.
  localparam int unsigned ElemIdxW = $clog2(VLEN);
  logic [XLEN-1:0] run_va_d, run_va_last_d;
  assign run_va_d = riscv_pkg::pm_tval(run_addr_q, pm_mode_q, translate_q);
  assign run_va_last_d = riscv_pkg::pm_tval(run_addr_q + seg_last_q, pm_mode_q, translate_q);

  // Field f of a segment: its page offset from the segment's first byte, and
  // whether it starts on the segment's second page.
  logic [12:0] field_off;
  assign field_off = {1'b0, va_first_q[11:0]} + (13'(field_q) << eew_log2_q);

  // An indexed element's index: byte offset i * EEW_index into the index
  // group, the register it lies in, its 64-bit word (an index never crosses
  // one), and the zero-extended value from the VRF read of the cycle before.
  localparam int unsigned Log2VlenBytes = $clog2(VlenBytes);
  logic [15:0] idx_byte;
  logic [ 4:0] idx_reg;
  logic [63:0] idx_word, idx_shifted;
  logic [XLEN-1:0] idx_value;
  assign idx_byte = run_elem_q << ieew_log2_q;
  assign idx_reg  = vs2_q + {2'b00, idx_byte[Log2VlenBytes+:3]};
  always_comb begin
    idx_word = '0;
    for (int w = 0; w < VLEN / 64; w++) begin
      if (idx_byte[Log2VlenBytes-1:3] == (Log2VlenBytes - 3)'(w)) begin
        idx_word = i_vrf_read_data[64*w+:64];
      end
    end
    idx_shifted = idx_word >> {idx_byte[2:0], 3'b000};
    unique case (ieew_log2_q)
      2'd0:    idx_value = {56'd0, idx_shifted[7:0]};
      2'd1:    idx_value = {48'd0, idx_shifted[15:0]};
      2'd2:    idx_value = {32'd0, idx_shifted[31:0]};
      default: idx_value = idx_shifted;
    endcase
  end

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

  // After the pages of the span (or of one run element) are translated.
  hm_state_e translated_next;
  assign translated_next = run_q ? HM_RUN_ARM : HM_COMMIT_ARM;

  // A fault-only-first run's fault on an element above 0 ends the run.
  logic ff_trim;
  assign ff_trim = run_q && ff_q && (run_elem_q != 16'd0);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q               <= HM_IDLE;
      wait_q                <= 1'b0;
      walk_reissue_q        <= 1'b0;
      shield_q              <= 1'b0;
      fault_vstart_en_q     <= 1'b0;
      zero_vmt_done_valid_q <= 1'b0;
      zero_vmt_done_idx_q   <= '0;
      vs_dirty_q            <= 1'b0;
      span_p1_q             <= 1'b0;
    end else begin
      zero_vmt_done_valid_q <= 1'b0;
      span_p1_q <= 1'b0;
      // Case C's partial run and every run element of a load write the
      // VRF before the instruction retires or traps.
      vs_dirty_q <= !is_store_q && i_vmu_done &&
                    ((state_q == HM_PARTIAL_RUN) || (state_q == HM_RUN_WAIT));

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
              pm_mode_q    <= i_pm_mode;
              state_q      <= HM_DECODE;
            end
          end

          HM_DECODE: begin
            // The illegal-instruction cause and value are loaded whatever the
            // checks say: they are read only with a fault, and every later
            // fault writes its own.
            fault_cause_q <= riscv_pkg::ExcCauseWidth'(riscv_pkg::ExcIllegalInstr);
            fault_tval_q  <= XLEN'(insn_q);
            if (!head_matches_q || i_int_take_armed) begin
              state_q <= HM_IDLE;
            end else begin
              rs1_q            <= (dec_rs1 == 5'd0) ? '0 : i_rf_read_data;
              is_store_q       <= dec_is_store;
              is_whole_q       <= dec_is_whole;
              is_mask_q        <= dec_is_mask;
              vm_q             <= dec_vm;
              vd_vs3_q         <= dec_vd_vs3;
              eew_log2_q       <= dec_eew_log2;
              evl_q            <= dec_evl;
              active_mask_q    <= dec_active_mask;
              run_q            <= dec_strided || dec_indexed || dec_unit_seg;
              run_started_q    <= 1'b0;
              idx_q            <= dec_indexed;
              ff_q             <= dec_ff;
              trim_q           <= 1'b0;
              vs2_q            <= dec_umop;
              ieew_log2_q      <= dec_weew_log2;
              nf_q             <= dec_seg ? dec_nf : 3'd0;
              emul_regs_log2_q <= dec_emul_regs_log2;
              seg_last_q       <= XLEN'(dec_seg_bytes - 7'd1);
              // A unit-stride segment steps by one segment; a strided form
              // reads its stride below.
              stride_q         <= dec_unit_seg ? XLEN'(dec_seg_bytes) : '0;
              if (dec_illegal) begin
                fault_vstart_en_q <= 1'b0;
                state_q           <= HM_FAULT_ARM;
              end else begin
                state_q <= dec_strided ? HM_STRIDE_RD : HM_SPAN0;
              end
            end
          end

          // The extra read port presents rs2 (o_rf_read_addr) in both
          // states; the stride is taken at the end of the second.
          HM_STRIDE_RD: state_q <= HM_STRIDE_CAP;

          HM_STRIDE_CAP: begin
            stride_q <= (dec_umop == 5'd0) ? '0 : i_rf_read_data;
            state_q  <= HM_SPAN0;
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
              // A run steps from element 0; a strided address starts at rs1.
              run_elem_q         <= '0;
              run_addr_q         <= rs1_q;
              state_q            <= run_q ? HM_RUN_SEEK : HM_SPAN1_ADD;
            end
          end

          HM_SPAN1_ADD: begin
            va_first_q    <= riscv_pkg::pm_tval(span_va_first, pm_mode_q, translate_q);
            va_last_end_q <= riscv_pkg::pm_tval(span_va_last_end, pm_mode_q, translate_q);
            cand_p1_q     <= first_p0_elem_q + 16'(bytes_rem_p0 >> eew_log2_q);
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
              span_p1_q <= 1'b1;
              state_q   <= HM_P1_SPAN0;
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
            va_first_p1_q <= riscv_pkg::pm_tval(va_first_p1_d, pm_mode_q, translate_q);
            va_last_p0_only_end_q <= riscv_pkg::pm_tval(
                va_last_p0_only_end_d, pm_mode_q, translate_q
            );
            state_q <= HM_P1_SPAN1_TVAL;
          end

          HM_P1_SPAN1_TVAL: begin
            p1_tval_q <= (va_first_p1_q[XLEN-1:12] == va_first_q[XLEN-1:12]) ?
                         {va_last_end_q[XLEN-1:12], 12'h000} : va_first_p1_q;
            state_q <= HM_CHECK_P0;
          end

          HM_CHECK_P0: begin
            // The element this page check reports as vstart if it faults;
            // it is read only with fault_vstart_en_q.
            fault_vstart_q <= first_p0_elem_q;
            if (!translate_q) begin
              if (bare_cached_ok) begin
                ppn0_q  <= cur_check_va[12+:riscv_pkg::VmtPpnBits];
                state_q <= has_p1_q ? HM_CHECK_P1 : translated_next;
              end else begin
                fault_cause_q     <= access_fault_cause;
                fault_tval_q      <= va_first_q;
                fault_vstart_en_q <= 1'b1;
                state_q           <= ff_trim ? HM_RUN_TRIM : HM_FAULT_ARM;
              end
            end else if (!cur_va_canonical) begin
              fault_cause_q     <= page_fault_cause;
              fault_tval_q      <= va_first_q;
              fault_vstart_en_q <= 1'b1;
              state_q           <= ff_trim ? HM_RUN_TRIM : HM_FAULT_ARM;
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
            fault_vstart_q <= first_p0_elem_q;
            if (walk_reissue_q || i_tlb_invalidate) begin
              walk_reissue_q <= 1'b0;
              state_q        <= HM_WALK_REQ_P0;
            end else if (walk_resp_match) begin
              if (walk_verdict == ma_pkg::MaPartOk) begin
                ppn0_q  <= walk_pa[12+:riscv_pkg::VmtPpnBits];
                state_q <= has_p1_q ? HM_CHECK_P1 : translated_next;
              end else begin
                fault_cause_q     <= (walk_verdict == ma_pkg::MaPartPage) ?
                                     page_fault_cause : access_fault_cause;
                fault_tval_q <= va_first_q;
                fault_vstart_en_q <= 1'b1;
                state_q <= ff_trim ? HM_RUN_TRIM : HM_FAULT_ARM;
              end
            end
          end

          HM_CHECK_P1: begin
            fault_vstart_q <= first_p1_elem_q;
            if (!translate_q) begin
              if (bare_cached_ok) begin
                ppn1_q  <= cur_check_va[12+:riscv_pkg::VmtPpnBits];
                state_q <= translated_next;
              end else begin
                fault_cause_q <= access_fault_cause;
                fault_tval_q <= p1_tval_q;
                fault_vstart_en_q <= 1'b1;
                state_q           <= ff_trim ? HM_RUN_TRIM :
                                   has_p0_only_elems_q ? HM_PARTIAL_ARM : HM_FAULT_ARM;
              end
            end else if (!cur_va_canonical) begin
              fault_cause_q <= page_fault_cause;
              fault_tval_q <= p1_tval_q;
              fault_vstart_en_q <= 1'b1;
              state_q           <= ff_trim ? HM_RUN_TRIM :
                                   has_p0_only_elems_q ? HM_PARTIAL_ARM : HM_FAULT_ARM;
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
            fault_vstart_q <= first_p1_elem_q;
            if (walk_reissue_q || i_tlb_invalidate) begin
              walk_reissue_q <= 1'b0;
              state_q        <= HM_WALK_REQ_P1;
            end else if (walk_resp_match) begin
              if (walk_verdict == ma_pkg::MaPartOk) begin
                ppn1_q  <= walk_pa[12+:riscv_pkg::VmtPpnBits];
                state_q <= translated_next;
              end else begin
                fault_cause_q     <= (walk_verdict == ma_pkg::MaPartPage) ?
                                     page_fault_cause : access_fault_cause;
                fault_tval_q <= p1_tval_q;
                fault_vstart_en_q <= 1'b1;
                state_q <= ff_trim ? HM_RUN_TRIM :
                         has_p0_only_elems_q ? HM_PARTIAL_ARM : HM_FAULT_ARM;
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

          // Head fault with no memory bytes accessed by this attempt. A
          // run that has performed elements already holds the
          // shield and reports the fault without giving the head up.
          HM_FAULT_ARM: begin
            if (!run_started_q && (!head_matches_q || i_int_take_armed)) begin
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
              // Nothing follows retirement for an instruction without
              // active elements or for a completed run.
              if (zero_active_q || run_q) begin
                zero_vmt_done_valid_q <= 1'b1;
                zero_vmt_done_idx_q   <= vmt_idx_q;
              end
            end
          end

          // Element run. Skip elements that are not active; an indexed
          // element reads its index first.
          HM_RUN_SEEK: begin
            if (active_mask_q[run_elem_q[ElemIdxW-1:0]]) begin
              state_q <= idx_q ? HM_RUN_IDX : HM_RUN_ADDR;
            end else begin
              run_elem_q <= run_elem_q + 16'd1;
              run_addr_q <= run_addr_q + stride_q;
            end
          end

          // The element's bytes as the span of one element: faults report
          // vstart = this element, and a fault of the second page reports
          // that page's base.
          HM_RUN_ADDR: begin
            field_q             <= '0;
            va_first_q          <= run_va_d;
            va_last_end_q       <= run_va_last_d;
            first_p0_elem_q     <= run_elem_q;
            first_p1_elem_q     <= run_elem_q;
            has_p0_only_elems_q <= 1'b0;
            state_q             <= HM_RUN_SPLIT;
          end

          HM_RUN_SPLIT: begin
            has_p1_q  <= span_has_p1;
            p1_tval_q <= {va_last_end_q[XLEN-1:12], 12'h000};
            state_q   <= HM_CHECK_P0;
          end

          // Both pages of the element are translated. The first access waits
          // for committed scalar stores and raises the shield; later elements
          // keep it.
          HM_RUN_ARM: begin
            if (run_started_q) begin
              seg0_q  <= full_seg0_d;
              seg1_q  <= full_seg1_d;
              state_q <= HM_RUN_LAUNCH;
            end else if (!head_matches_q || i_int_take_armed) begin
              state_q <= HM_IDLE;
            end else if (i_sq_committed_empty) begin
              seg0_q   <= full_seg0_d;
              seg1_q   <= full_seg1_d;
              shield_q <= 1'b1;
              state_q  <= HM_RUN_SETTLE;
            end
          end

          HM_RUN_SETTLE: begin
            state_q <= head_matches_q ? HM_RUN_LAUNCH : HM_IDLE;
            if (!head_matches_q) shield_q <= 1'b0;
          end

          HM_RUN_LAUNCH: begin
            run_started_q <= 1'b1;
            state_q       <= HM_RUN_WAIT;
          end

          HM_RUN_WAIT: begin
            if (i_vmu_done && (field_q != nf_q)) begin
              // The segment's next field, under the shield already up.
              field_q <= field_q + 3'd1;
              state_q <= HM_RUN_LAUNCH;
            end else if (i_vmu_done) begin
              if (run_elem_q == last_active_elem_q) begin
                state_q <= HM_CDB_OK;
              end else begin
                run_elem_q <= run_elem_q + 16'd1;
                run_addr_q <= run_addr_q + stride_q;
                state_q    <= HM_RUN_SEEK;
              end
            end
          end

          // o_vrf_read_addr presents the index register in this cycle.
          HM_RUN_IDX: state_q <= HM_RUN_IDX_CAP;

          // The run stops at a faulting element above 0 and completes; vl
          // becomes that element at retirement. Without an access yet, the
          // shield rises first, as for any completion.
          HM_RUN_TRIM: begin
            trim_q    <= 1'b1;
            trim_vl_q <= run_elem_q;
            if (run_started_q) begin
              state_q <= HM_CDB_OK;
            end else if (!head_matches_q || i_int_take_armed) begin
              state_q <= HM_IDLE;
            end else begin
              shield_q <= 1'b1;
              state_q  <= HM_RUN_TRIM_SETTLE;
            end
          end

          HM_RUN_TRIM_SETTLE: begin
            state_q <= head_matches_q ? HM_CDB_OK : HM_IDLE;
            if (!head_matches_q) shield_q <= 1'b0;
          end

          HM_RUN_IDX_CAP: begin
            run_addr_q <= rs1_q + idx_value;
            state_q    <= HM_RUN_ADDR;
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

  logic read_stride_now;
  assign read_stride_now = !cancel_outputs &&
                           ((state_q == HM_STRIDE_RD) || (state_q == HM_STRIDE_CAP));
  assign o_rf_read_en = read_regs_now || read_stride_now;
  assign o_rf_read_addr = read_stride_now ? dec_umop : dec_rs1;
  logic read_index_now;
  assign read_index_now = !cancel_outputs && (state_q == HM_RUN_IDX);
  assign o_vrf_read_en = read_regs_now || read_index_now;
  assign o_vrf_read_addr = read_index_now ? idx_reg : 5'd0;

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
  assign o_vmem_vs_dirty = vs_dirty_q;
  assign o_vl_trim_valid = commit_hit && trim_q;
  assign o_vl_trim = trim_vl_q;

  logic partial_launch, retire_launch, run_launch;
  assign partial_launch = !cancel_outputs && head_matches_q && (state_q == HM_PARTIAL_SETTLE);
  assign retire_launch = !cancel_outputs && commit_hit && !zero_active_q && !run_q;
  assign run_launch = !cancel_outputs && head_matches_q && (state_q == HM_RUN_LAUNCH);

  // A run element's descriptor covers that element alone; its segments
  // bound the requests for vec_vmu's check and are not written to the VMT.
  assign o_desc_valid = partial_launch || retire_launch || run_launch;
  assign o_desc_ppn0 = (run_q && field_off[12]) ? ppn1_q : ppn0_q;
  assign o_desc_ppn1 = ppn1_q;
  assign o_desc_page_offset = run_q ? field_off[11:0] : va_first_q[11:0];
  assign o_desc_first_elem = first_p0_elem_q;
  assign o_desc_last_elem = run_q ? run_elem_q :
                            partial_launch ? last_p0_only_elem_q : last_active_elem_q;
  assign o_desc_eew_log2 = eew_log2_q;
  assign o_desc_active_mask = active_mask_q;
  assign o_desc_is_store = is_store_q;
  assign o_desc_vd_vs3 = run_q ? (vd_vs3_q + (5'(field_q) << emul_regs_log2_q)) : vd_vs3_q;
  assign o_desc_vmt_idx = vmt_idx_q;
  assign o_desc_free_vmt_on_done = !partial_launch && !run_q;
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
      // The registered commit of the instruction arrives in HM_WAIT_RETIRE,
      // never in HM_CDB_OK, where commit_hit would miss it. The CDB is
      // registered before the ROB and the commit bus is registered again.
      assert (!(i_commit_valid && (i_commit_tag == tag_q) && (state_q == HM_CDB_OK)));
      // Case-C partial launch always stays inside Page 0.
      assert (!partial_launch || (last_p0_only_elem_q < first_p1_elem_q));
      // A run element launches under the shield, from the ROB head, for
      // an active element, and the run never takes Case C's partial path.
      assert (!run_launch || (shield_q && active_mask_q[run_elem_q[ElemIdxW-1:0]]));
      assert (!(state_q == HM_RUN_LAUNCH && !cancel_outputs) || head_matches_q);
      assert (!(run_q && (state_q == HM_PARTIAL_ARM)));
      // The VMT range is written only for a span.
      assert (!(o_vmt_range_valid && run_q && !zero_active_q));
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
      p_commit_not_early :
      assert (!(i_commit_valid && (i_commit_tag == tag_q) && (state_q == HM_CDB_OK)));
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

`ifdef VEC_HEAD_MMU_STRIDE_PROOF
  // vlse32.v v8, (x10), x11 (or vsse32.v) with vl = 3: x10 = 0x400ffe (with a
  // tag in bits 63:57 when pointer masking is on) and x11 = 0x800, so the
  // elements are at 0x400ffe (pages 0x400 and 0x401), 0x4017fe (0x401) and
  // 0x401ffe (0x401 and 0x402). One page may fault. The indexed variant,
  // vluxei32.v or vloxei32.v (or the stores) with v16 = {0, 0x800, 0x1000},
  // reaches the same elements through its index reads. The walker accepts every
  // request and answers in the next cycle, and the memory unit completes an
  // element in the cycle after its launch; the order, translation, fault and
  // shield properties do not depend on those latencies.
  logic f_past_valid = 1'b0;
  logic f_cdb_accepted = 1'b0;
  logic f_cdb_registered = 1'b0;
  logic f_retired = 1'b0;
  logic f_walk_pending = 1'b0;
  logic [riscv_pkg::Sv39VpnBits-1:0] f_pending_vpn;
  logic [2:0] f_ok_since = '0;  // pages 0x400..0x402 translated since the last launch
  logic [2:0] f_launches = '0;
  logic f_vmu_busy = 1'b0;
  logic [2:0] f_dones = '0;
  logic [2:0] f_dirties = '0;
  logic f_drained = 1'b0;
  (* anyconst *) logic f_store;
  (* anyconst *) logic f_indexed;
  (* anyconst *) logic f_ordered;
  logic [4:0] f_vrf_addr_q = '0;
  (* anyconst *) logic [1:0] f_fault_page;  // 0..2: that page faults; 3: none
  (* anyconst *) logic [6:0] f_tag;
  (* anyconst *) riscv_pkg::pm_mode_t f_pm;
  // The indexed variant is its own task (VEC_HEAD_MMU_INDEXED).
`ifdef VEC_HEAD_MMU_INDEXED
  // Pointer masking is the same logic for both forms; the strided task
  // covers it.
  always_comb assume (f_indexed && f_pm == riscv_pkg::EnvcfgPmmOff);
`else
  always_comb assume (!f_indexed);
`endif
  // The first element touching the faulting page, and the fault's xtval.
  logic [2:0] f_fault_elem;
  logic [XLEN-1:0] f_fault_tval;
  always_comb begin
    unique case (f_fault_page)
      2'd0: begin
        f_fault_elem = 3'd0;
        f_fault_tval = 64'h400ffe;
      end
      2'd1: begin
        f_fault_elem = 3'd0;
        f_fault_tval = 64'h401000;
      end
      2'd2: begin
        f_fault_elem = 3'd2;
        f_fault_tval = 64'h402000;
      end
      default: begin
        f_fault_elem = 3'd3;
        f_fault_tval = '0;
      end
    endcase
  end
  // Element k's first page and whether it straddles into the next one.
  function automatic logic [1:0] f_first_page(input logic [2:0] k);
    f_first_page = (k == 3'd0) ? 2'd0 : 2'd1;
  endfunction
  function automatic logic f_straddles(input logic [2:0] k);
    f_straddles = (k == 3'd0) || (k == 3'd2);
  endfunction
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid)
      assume (i_rst);
      else assume (!i_rst);
    assume (!i_flush_all && !i_fatal_stop && !i_vmu_fatal);
    assume (i_head_tag == 3 && !i_rob_empty && i_head_safe);
    assume (i_head_is_vmem == !f_cdb_accepted &&
            i_head_insn == (f_indexed ? ((f_ordered ? 32'h0f056407 : 32'h07056407) |
                                         (f_store ? 32'h20 : 32'h0)) :
                                        (f_store ? 32'h0ab56427 : 32'h0ab56407)));
    assume (i_head_vmt_idx == 0 && i_vec_idle && !i_csr_wb_pending && !i_int_take_armed);
    assume (i_vl == 3 && i_vtype == 9'h10 && i_vstart == 0);
    // The VRF read port answers the previous cycle's address: v16 holds the
    // indices, v0 (the mask) is all ones.
    assume (i_vrf_read_data == ((f_vrf_addr_q == 5'd16) ? VLEN'(96'h00001000_00000800_00000000) :
                                                         '1));
    assume (f_pm != riscv_pkg::EnvcfgPmmOff || f_tag == 0);
    assume (f_pm != 2'b01 && i_pm_mode == f_pm);
    assume (i_rf_read_data == ((o_rf_read_addr == 5'd10) ? {f_tag, 57'h400ffe} :
                               (o_rf_read_addr == 5'd11) ? 64'h800 : 64'h0));
    assume (i_translate && !i_eff_priv_u && !i_sum && !i_mxr && !i_tlb_invalidate);
    assume (!i_commit_valid || (f_cdb_registered && f_fault_page == 2'd3 && !f_retired));
    assume (i_commit_tag == 3 && !i_commit_exception);
    assume (i_vmu_done == f_vmu_busy && i_walk_req_ready);
    assume (i_walk_resp_valid == f_walk_pending);
    if (i_walk_resp_valid) begin
      assume (f_walk_pending);
      assume (i_walk_resp.vpn == f_pending_vpn);
      assume (i_walk_resp.ppn == 44'h83000 + 44'(f_pending_vpn[1:0]) * 44'h100);
      assume (i_walk_resp.level == 0 && i_walk_resp.pbmt == 0);
      assume (i_walk_resp.perm_r && i_walk_resp.perm_w && i_walk_resp.perm_d);
      assume (!i_walk_resp.perm_u);
      assume (i_walk_resp.fault_kind == ((f_pending_vpn == 27'h400 + 27'(f_fault_page)) ?
          riscv_pkg::DFAULT_PAGE : riscv_pkg::DFAULT_NONE));
    end
    f_vrf_addr_q <= o_vrf_read_addr;
    if (i_rst) begin
      f_cdb_accepted <= 1'b0;
      f_cdb_registered <= 1'b0;
      f_retired <= 1'b0;
      f_walk_pending <= 1'b0;
      f_pending_vpn <= '0;
      f_ok_since <= '0;
      f_launches <= '0;
      f_vmu_busy <= 1'b0;
      f_dones <= '0;
      f_dirties <= '0;
      f_drained <= 1'b0;
    end else begin
      if (o_walk_req_valid && i_walk_req_ready) begin
        f_walk_pending <= 1'b1;
        f_pending_vpn  <= o_walk_vpn;
        // Pointer masking removed the tag before translation.
        p_walk_masked : assert (o_walk_vpn >= 27'h400 && o_walk_vpn <= 27'h402);
      end
      if (i_walk_resp_valid) begin
        f_walk_pending <= 1'b0;
        if (i_walk_resp.fault_kind == riscv_pkg::DFAULT_NONE)
          f_ok_since[f_pending_vpn[1:0]] <= 1'b1;
      end
      if (o_desc_valid) begin
        f_launches <= f_launches + 3'd1;
        f_ok_since <= '0;
        f_vmu_busy <= 1'b1;
        // One element per descriptor, in element order, never before the
        // element's pages are translated, never at or after a faulting one.
        p_order :
        assert (o_desc_first_elem == 16'(f_launches) && o_desc_last_elem == 16'(f_launches));
        p_before_fault : assert (f_launches < f_fault_elem);
        p_pages_translated :
        assert (f_ok_since[f_first_page(
            f_launches
        )] && (!f_straddles(
            f_launches
        ) || f_ok_since[f_first_page(
            f_launches
        )+2'd1]));
        p_descriptor :
        assert (o_desc_ppn0 == 20'h83000 + 20'(f_first_page(
            f_launches
        )) * 20'h100 && o_desc_page_offset == ((f_launches[0]) ? 12'h7fe : 12'hffe) &&
            (!f_straddles(
            f_launches
        ) || o_desc_ppn1 == 20'h83100 + 20'(f_first_page(
            f_launches
        )) * 20'h100) && o_desc_is_store == f_store && !o_desc_free_vmt_on_done);
        p_launch_shield : assert (o_vmem_head_shield);
        p_one_at_a_time : assert (!f_vmu_busy);
      end
      if (i_vmu_done) begin
        f_vmu_busy <= 1'b0;
        f_dones <= f_dones + 3'd1;
      end
      if (o_vmem_vs_dirty) f_dirties <= f_dirties + 3'd1;
      if (o_vmem_vs_dirty) p_dirty_load_only : assert (!f_store);
      if (o_cdb_done) begin
        f_cdb_accepted <= 1'b1;
        p_single_completion : assert (!f_cdb_accepted);
        if (f_fault_page == 2'd3) begin
          p_complete_all :
          assert (f_launches == 3'd3 && f_dones == 3'd3 && !o_vhead_complete.exception);
        end else begin
          // Precise: every element before the faulting one is performed.
          p_fault_precise :
          assert (o_vhead_complete.exception && f_launches == f_fault_elem &&
                  f_dones == f_fault_elem && o_vmem_fault_vstart_valid &&
                  o_vmem_fault_vstart == 16'(f_fault_elem) &&
                  o_vhead_complete.value == riscv_pkg::FLEN'(f_fault_tval));
        end
      end
      if (f_cdb_accepted) f_cdb_registered <= 1'b1;
      if (i_commit_valid) f_retired <= 1'b1;
      // Nothing launches at retirement; the entry is freed instead.
      if (i_commit_valid) p_commit_no_launch : assert (!o_desc_valid && o_retire_vload != f_store);
      if (f_past_valid && $past(i_commit_valid)) p_commit_frees : assert (o_zero_vmt_done_valid);
      p_no_range : assert (!o_vmt_range_valid);
      if (o_vhead_complete.valid) begin
        p_commit_shield : assert (o_vmem_head_shield && $past(o_vmem_head_shield));
      end
      // No element is accessed before older committed stores have drained
      // (none can be added while the instruction is at the head).
      if (i_sq_committed_empty) f_drained <= 1'b1;
      if (o_desc_valid) p_store_drain : assert (f_drained);
      if (f_past_valid && !$past(
              i_rst
          ) && $past(
              o_vmem_head_shield
          ) && $past(
              f_launches
          ) != 0 && !$past(
              i_commit_valid
          ))
        p_shield_held : assert (o_vmem_head_shield);
      // Loads report each VRF write by the completion (the pulse is
      // registered one cycle after the element's completion).
      if (o_cdb_done && !f_store)
        p_dirty_count : assert (f_dirties + 3'(o_vmem_vs_dirty) == f_dones);
      c_stride_retired : cover (i_commit_valid);
      c_stride_mid_fault : cover (o_cdb_done && f_launches == 3'd2);
`ifdef VEC_HEAD_MMU_INDEXED
      c_indexed_retired : cover (i_commit_valid && f_indexed);
      c_indexed_mid_fault : cover (o_cdb_done && f_launches == 3'd2 && f_indexed);
`else
      // The indexed tasks fix pointer masking off.
      c_stride_tagged : cover (i_commit_valid && f_tag != 0);
`endif
    end
  end
`endif

endmodule : vec_head_mmu
