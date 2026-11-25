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
  The vector unit:
    - Per-ROB-tag instruction word, write-range metadata and class flags
      (is_varith_q, head_xs_q, ov_pend_q, is_vmem_q) plus the allocated VMT
      index of each vector memory op.
    - An 8-entry queue (VIQ) filled when a vector arithmetic entry retires,
      feeding vec_engine with pipelined single-width group ALU issue and
      register-independent overlap with vec_vmu.
    - Off-head vector-to-scalar execution (VTOX: vmv.x.s, vcpop.m, vfirst.m;
      VTOF: vfmv.f.s, NaN-boxed) completing on CDB slot 6 once older in-flight
      vector writes to vs2 (and v0 if masked) and older vl updates have
      drained, without waiting for the ROB head or the whole backend to drain.
    - Head-executed scalar-FP operand fetch for OPFVF (VARITH_F) and OP-VE
      element-group alignment checks of architectural vl and vstart.
    - Head-executed legality and translation for vector loads and stores
      (vec_head_mmu) completing on CDB slot 6, paired with the sector memory
      engine (vec_vmu) on the hart's coherence line client, which runs a span
      after retirement and strided, indexed or segment elements one at a
      time at the head.
*/
module vec_unit #(
    parameter  int unsigned VLEN           = 256,
    parameter  bit          CACHED_TIER_EN = 1'b1,
    localparam int unsigned XLEN           = riscv_pkg::XLEN,
    localparam int unsigned TagW           = riscv_pkg::ReorderBufferTagWidth,
    localparam int unsigned VmtIdxW        = $clog2(riscv_pkg::VmtDepth),
    localparam int unsigned SegW           = 1 + riscv_pkg::VmtPpnBits + 14,
    localparam int unsigned PhysAddrBits   = riscv_pkg::PhysAddrBits
) (
    input  logic                                                 i_clk,
    input  logic                                                 i_rst,
    input  logic                                                 i_fatal_stop,
    // Slot-1 allocation
    input  logic                                                 i_alloc,
    input  logic                    [                  TagW-1:0] i_alloc_tag,
    input  logic                                                 i_alloc_is_varith,
    input  logic                                                 i_alloc_is_vtox,
    input  logic                                                 i_alloc_is_vmem,
    input  logic                                                 i_alloc_is_vload,
    input  logic                                                 i_alloc_is_vcfg,
    input  logic                    [                       8:0] i_alloc_vtype,
    input  logic                    [               VmtIdxW-1:0] i_alloc_vmt_idx,
    input  logic                    [                      31:0] i_alloc_insn,
    // Slot-2 allocation (never a vector instruction): clears the flags of its tag
    input  logic                                                 i_alloc_2,
    input  logic                    [                  TagW-1:0] i_alloc_tag_2,
    // Registered commit bus (slot 1; vector ops never retire as slot 2)
    input  logic                                                 i_commit_valid,
    input  logic                    [                  TagW-1:0] i_commit_tag,
    input  logic                                                 i_commit_exception,
    input  logic                    [                      63:0] i_commit_value,
    input  logic                                                 i_vcfg_commit_valid,
    // Architectural vl, vtype ({vill, vtype[7:0]}) and vstart
    input  logic                    [                      15:0] i_vl,
    input  logic                    [                       8:0] i_vtype,
    input  logic                    [                      15:0] i_vstart,
    input  logic                    [                       1:0] i_vxrm,
    output logic                                                 o_vxsat_set,
    output logic                                                 o_vtox_commit,
    // frm for each queued instruction, and the FP exception flags of the
    // active elements, one pulse per instruction that raises any
    input  logic                    [                       2:0] i_frm,
    output logic                                                 o_fp_flags_valid,
    output logic                    [                       4:0] o_fp_flags,
    // An instruction with an f-register scalar operand (OPFVF): read at the
    // ROB head through the register files' extra read port (o_rf_read_addr)
    input  logic                                                 i_alloc_is_vfscalar,
    input  logic                    [                      63:0] i_fp_read_data,
    // ROB head & ordering inputs
    input  logic                    [                  TagW-1:0] i_head_tag,
    input  logic                                                 i_rob_empty,
    input  logic                                                 i_head_safe,
    input  logic                                                 i_flush_all,
    input  logic                                                 i_flush_spec,
    input  logic                                                 i_flush_en,
    input  logic                    [                  TagW-1:0] i_flush_tag,
    input  logic                                                 i_csr_wb_pending,
    input  logic                                                 i_sq_committed_empty,
    input  logic                                                 i_int_take_armed,
    // Register files' extra read port: the integer rs1 of VLOAD/VSTORE, or
    // the f-register scalar of an OPFVF instruction at the head
    output logic                                                 o_rf_read_en,
    output logic                    [                       4:0] o_rf_read_addr,
    input  logic                    [                  XLEN-1:0] i_rf_read_data,
    // Data-translation state & walker port
    input  logic                                                 i_translate,
    input  logic                                                 i_eff_priv_u,
    input  logic                                                 i_sum,
    input  logic                                                 i_mxr,
    input  riscv_pkg::pm_mode_t                                  i_pm_mode,
    input  logic                                                 i_tlb_invalidate,
    output logic                                                 o_walk_req_valid,
    input  logic                                                 i_walk_req_ready,
    output logic                    [riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,
    input  logic                                                 i_walk_resp_valid,
    input  riscv_pkg::ptw_resp_t                                 i_walk_resp,
    // VMT range write & completion
    output logic                                                 o_vmt_range_valid,
    output logic                    [               VmtIdxW-1:0] o_vmt_range_idx,
    output logic                    [                  SegW-1:0] o_vmt_range_seg0,
    output logic                    [                  SegW-1:0] o_vmt_range_seg1,
    output logic                                                 o_vmt_done_valid,
    output logic                    [               VmtIdxW-1:0] o_vmt_done_idx,
    // Coherence line-client port (identities 2..7)
    output logic                                                 o_lc_req_valid,
    input  logic                                                 i_lc_req_ready,
    output logic                                                 o_lc_req_write,
    output logic                    [          PhysAddrBits-1:0] o_lc_req_addr,
    output logic                    [                     255:0] o_lc_req_data,
    output logic                    [                      31:0] o_lc_req_mask,
    output logic                    [                       3:0] o_lc_req_id,
    input  logic                                                 i_lc_resp_valid,
    input  logic                    [                       3:0] i_lc_resp_id,
    input  logic                    [                     255:0] i_lc_resp_data,
    input  logic                                                 i_lc_resp_error,
    // CDB slot 6 & sideband outputs
    input  logic                                                 i_grant,
    output riscv_pkg::fu_complete_t                              o_vtox_complete,
    output logic                                                 o_varith_commit,
    output logic                                                 o_vstore_commit,
    output logic                                                 o_vmem_fault_vstart_valid,
    output logic                    [                      15:0] o_vmem_fault_vstart,
    // A load wrote the VRF at the ROB head (before retiring or trapping)
    output logic                                                 o_vmem_vs_dirty,
    // A fault-only-first load retires with vl trimmed to o_vl_trim
    output logic                                                 o_vl_trim_valid,
    output logic                    [                      15:0] o_vl_trim,
    output logic                                                 o_vmem_head_shield,
    output logic                                                 o_vmu_fatal,
    output logic                    [          PhysAddrBits-1:0] o_vmu_fatal_addr,
    output logic                                                 o_commit_hold,
    output logic                                                 o_idle
);

  localparam int unsigned Depth = 8;
  localparam int unsigned VlenBytes = VLEN / 8;
  localparam int unsigned ByteBits = $clog2(VlenBytes);

  function automatic logic [31:0] vec_grp_mask(input logic [4:0] base, input logic [3:0] cnt);
    logic [31:0] m;
    m = 32'd0;
    for (int i = 0; i < 8; i++) if (4'(i) < cnt) m[5'(base+5'(i))] = 1'b1;
    vec_grp_mask = m;
  endfunction

  function automatic logic [31:0] vec_span_mask(input logic [4:0] base, input logic [2:0] last);
    logic [31:0] m;
    for (int r = 0; r < 32; r++) begin
      logic [4:0] diff;
      diff = 5'(r) - base;
      m[r] = (diff[4:3] == 2'b00) && (diff[2:0] <= last);
    end
    vec_span_mask = m;
  endfunction

  // Pre-decoded register-span and issue-class metadata for a dispatched vector
  // arithmetic instruction under its tracked vtype:
  //   {is_grp_alu, rd_v0, has_vs2, vs2_wlast[2:0], has_vs1, vs1_wlast[2:0], wr_wlast[2:0]}
  function automatic logic [12:0] vec_arith_meta(input logic [31:0] insn, input logic [8:0] vtype);
    logic [6:0] opc;
    logic [5:0] f6;
    logic [2:0] f3, lmul;
    logic [4:0] vs1;
    logic vm, is_opve, is_iv, is_mv, is_fp, is_whole, is_widen, is_awide, is_ei16;
    logic is_int_red, is_fp_red, is_mask_dest, is_smove, no_vs2, has_vs1, is_grp_alu, rd_v0;
    logic [3:0] n_base, n_wide;
    logic [2:0] wr_wlast, vs2_wlast, vs1_wlast;
    opc = insn[6:0];
    f6 = insn[31:26];
    vm = insn[25];
    vs1 = insn[19:15];
    f3 = insn[14:12];
    lmul = vtype[2:0];
    n_base = lmul[2] ? 4'd1 : (4'd1 << lmul[1:0]);
    n_wide = (n_base >= 4'd8) ? 4'd8 : (n_base << 1);
    is_opve = (opc == riscv_pkg::OPC_OP_VE);
    is_iv = !is_opve && ((f3 == 3'd0) || (f3 == 3'd3) || (f3 == 3'd4));
    is_mv = !is_opve && ((f3 == 3'd2) || (f3 == 3'd6));
    is_fp = !is_opve && ((f3 == 3'd1) || (f3 == 3'd5));
    is_whole = !is_opve && (f3 == 3'd3) && (f6 == 6'h27);
    is_widen = (is_mv && (f6 >= 6'h30)) || (is_iv && (f6 == 6'h35)) ||
        (is_fp && ((f6 >= 6'h30) || (f6 == 6'h12 && vs1[4:3] == 2'd1)));
    is_awide = (is_iv && (f6 >= 6'h2c) && (f6 <= 6'h2f)) ||
        (is_mv && (f6 >= 6'h34) && (f6 <= 6'h37)) ||
        (is_fp && ((f6 == 6'h34) || (f6 == 6'h36) || (f6 == 6'h12 && vs1[4:3] == 2'd2)));
    is_ei16 = !is_opve && (f3 == 3'd0) && (f6 == 6'h0e);
    is_int_red = (!is_opve && (f3 == 3'd2) && (f6 < 6'd8)) ||
        (!is_opve && (f3 == 3'd0) && ((f6 == 6'h30) || (f6 == 6'h31)));
    is_fp_red = !is_opve && (f3 == 3'd1) &&
        (f6 == 6'd1 || f6 == 6'd3 || f6 == 6'd5 || f6 == 6'd7 || f6 == 6'h31 || f6 == 6'h33);
    is_mask_dest = (is_iv && ((f6[5:3] == 3'b011) || (f6 == 6'h11) || (f6 == 6'h13))) ||
        (is_mv && (f3 == 3'd2) && ((f6[5:3] == 3'b011) || (f6 == 6'h14 && vs1 < 5'd16))) ||
        (is_fp && (f6 >= 6'h18) && (f6 <= 6'h1f));
    is_smove = (!is_opve && (f3 == 3'd6) && (f6 == 6'h10)) ||
        (!is_opve && (f3 == 3'd5) && (f6 == 6'h10));
    no_vs2 = is_smove || ((is_iv || is_fp) && (f6 == 6'h17) && vm) ||
        (is_mv && (f3 == 3'd2) && (f6 == 6'h14) && (vs1 == 5'd17));
    has_vs1 = is_opve || (f3 == 3'd0) ||
        ((f3 == 3'd1) && (f6 != 6'h12) && (f6 != 6'h13)) ||
        ((f3 == 3'd2) && (f6 != 6'h12) && (f6 != 6'h14));
    is_grp_alu = !riscv_pkg::vector_int_extra_ok(insn) && !riscv_pkg::vector_fp_ok(insn) &&
        !riscv_pkg::vector_crypto_ok(insn);
    rd_v0 = !is_opve && !vm;

    if (is_whole) wr_wlast = vs1[2:0];
    else if (is_int_red || is_fp_red || is_mask_dest || is_smove) wr_wlast = 3'd0;
    else if (is_widen) wr_wlast = 3'(n_wide - 4'd1);
    else wr_wlast = 3'(n_base - 4'd1);

    if (is_whole) vs2_wlast = vs1[2:0];
    else if (is_awide) vs2_wlast = 3'(n_wide - 4'd1);
    else vs2_wlast = 3'(n_base - 4'd1);

    if (is_ei16) vs1_wlast = 3'(n_wide - 4'd1);
    else if (is_int_red || is_fp_red) vs1_wlast = 3'd0;
    else vs1_wlast = 3'(n_base - 4'd1);

    vec_arith_meta = {is_grp_alu, rd_v0, !no_vs2, vs2_wlast, has_vs1, vs1_wlast, wr_wlast};
  endfunction

  localparam int unsigned RobDepth = riscv_pkg::ReorderBufferDepth;

  function automatic logic is_younger(input logic [TagW-1:0] entry_tag,
                                      input logic [TagW-1:0] flush_tag,
                                      input logic [TagW-1:0] head);
    logic [TagW:0] entry_age, flush_age;
    entry_age  = {1'b0, entry_tag} - {1'b0, head};
    flush_age  = {1'b0, flush_tag} - {1'b0, head};
    is_younger = entry_age > flush_age;
  endfunction

  logic [31:0] insn_q[RobDepth];
  logic [VmtIdxW-1:0] vmt_idx_by_tag_q[RobDepth];
  logic [1:0] vtox_sew_q[RobDepth];
  logic [4:0] rob_vd_q[RobDepth];
  logic [2:0] rob_wlast_q[RobDepth];
  // Packed commit-time VIQ metadata per ROB tag (single read port at i_commit_tag):
  //   {vs2[4:0], vs1[4:0], is_grp_alu, rd_v0, has_vs2, vs2_wlast[2:0], has_vs1, vs1_wlast[2:0]}
  logic [19:0] rob_meta_q[RobDepth];
  logic [RobDepth-1:0] is_varith_q, head_xs_q, is_vmem_q;
  logic [RobDepth-1:0] vtox_retire_q, ov_pend_q;
  logic [RobDepth-1:0] rob_vwrite_q, rob_vload_q, rob_wr_v0_q, rob_vl_chg_q;
  logic vtox_done, ov_done, ov_accept;
  logic [TagW-1:0] vtox_tag_q, ov_tag_q, ov_pick_tag;
  logic vhead_cdb_done;
  logic [TagW-1:0] vhead_cdb_done_tag;

  // Registered ROB head tag for off-head tracking and partial-flush table clears.
  logic [TagW-1:0] head_tag_q;
  logic flush_spec_d1_q;

  // One-cycle allocation pipeline for off-head tracking and VIQ metadata decode.
  logic alloc_q_valid, alloc_q_2_valid;
  logic [TagW-1:0] alloc_q_tag, alloc_q_2_tag;
  logic alloc_q_is_varith, alloc_q_is_vtox, alloc_q_is_vload, alloc_q_is_vcfg;
  logic [31:0] alloc_q_insn;
  logic [ 8:0] alloc_q_vtype;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      head_tag_q      <= '0;
      flush_spec_d1_q <= 1'b0;
      alloc_q_valid   <= 1'b0;
      alloc_q_2_valid <= 1'b0;
    end else begin
      head_tag_q      <= i_head_tag;
      flush_spec_d1_q <= i_flush_spec;
      alloc_q_valid   <= i_alloc && !i_flush_spec && !i_flush_en;
      alloc_q_2_valid <= i_alloc_2 && !i_flush_spec;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_alloc) begin
      alloc_q_tag       <= i_alloc_tag;
      alloc_q_is_varith <= i_alloc_is_varith;
      alloc_q_is_vtox   <= i_alloc_is_vtox;
      alloc_q_is_vload  <= i_alloc_is_vload;
      alloc_q_is_vcfg   <= i_alloc_is_vcfg;
      alloc_q_insn      <= i_alloc_insn;
      alloc_q_vtype     <= i_alloc_vtype;
    end
    if (i_alloc_2) alloc_q_2_tag <= i_alloc_tag_2;
  end

  logic [12:0] alloc_meta;
  logic alloc_is_grp_alu, alloc_rd_v0, alloc_has_vs2, alloc_has_vs1, alloc_wr_v0;
  logic [2:0] alloc_vs2_wlast, alloc_vs1_wlast, alloc_wlast;
  logic alloc_q_live;
  assign alloc_meta = vec_arith_meta(alloc_q_insn, alloc_q_vtype);
  assign {alloc_is_grp_alu, alloc_rd_v0, alloc_has_vs2, alloc_vs2_wlast,
          alloc_has_vs1, alloc_vs1_wlast, alloc_wlast} = alloc_meta;
  assign alloc_wr_v0 = (5'd0 - alloc_q_insn[11:7]) <= {2'b00, alloc_wlast};
  assign alloc_q_live = alloc_q_valid && !i_flush_spec && !(i_flush_en && is_younger(
      alloc_q_tag, i_flush_tag, i_head_tag
  ));

  // Direct head-visible per-ROB-tag tables (unchanged from allocation cycle).
  always_ff @(posedge i_clk) begin
    if (i_alloc) begin
      insn_q[i_alloc_tag]           <= i_alloc_insn;
      vmt_idx_by_tag_q[i_alloc_tag] <= i_alloc_vmt_idx;
    end
    // Every allocation of a tag rewrites its flags, so a flag left by a
    // squashed vector instruction never describes a later one.
    if (i_rst) begin
      head_xs_q <= '0;
      is_vmem_q <= '0;
    end else begin
      if (vtox_done) head_xs_q[vtox_tag_q] <= 1'b0;
      if (vhead_cdb_done) is_vmem_q[vhead_cdb_done_tag] <= 1'b0;
      if (i_alloc) begin
        head_xs_q[i_alloc_tag] <= i_alloc_is_vfscalar ||
            (i_alloc_is_varith && (i_alloc_insn[6:0] == riscv_pkg::OPC_OP_VE));
        is_vmem_q[i_alloc_tag] <= i_alloc_is_vmem;
      end
      if (i_alloc_2) begin
        head_xs_q[i_alloc_tag_2] <= 1'b0;
        is_vmem_q[i_alloc_tag_2] <= 1'b0;
      end
    end
  end

  // Pipelined commit-time and off-head metadata tables (populated one cycle
  // after allocation, before earliest registered commit).
  always_ff @(posedge i_clk) begin
    if (alloc_q_valid) begin
      vtox_sew_q[alloc_q_tag] <= alloc_q_vtype[4:3];
      rob_vd_q[alloc_q_tag] <= alloc_q_insn[11:7];
      rob_wlast_q[alloc_q_tag] <= alloc_wlast;
      rob_meta_q[alloc_q_tag] <= {
        alloc_q_insn[24:20],
        alloc_q_insn[19:15],
        alloc_is_grp_alu,
        alloc_rd_v0,
        alloc_has_vs2,
        alloc_vs2_wlast,
        alloc_has_vs1,
        alloc_vs1_wlast
      };
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      is_varith_q   <= '0;
      vtox_retire_q <= '0;
    end else begin
      if (alloc_q_valid) begin
        is_varith_q[alloc_q_tag]   <= alloc_q_is_varith;
        vtox_retire_q[alloc_q_tag] <= alloc_q_is_vtox;
      end
      if (alloc_q_2_valid) begin
        is_varith_q[alloc_q_2_tag]   <= 1'b0;
        vtox_retire_q[alloc_q_2_tag] <= 1'b0;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ov_pend_q    <= '0;
      rob_vwrite_q <= '0;
      rob_vload_q  <= '0;
      rob_wr_v0_q  <= '0;
      rob_vl_chg_q <= '0;
    end else if (i_flush_spec) begin
      ov_pend_q    <= '0;
      rob_vwrite_q <= '0;
      rob_vload_q  <= '0;
      rob_wr_v0_q  <= '0;
      rob_vl_chg_q <= '0;
    end else begin
      if (i_flush_en) begin
        for (int t = 0; t < RobDepth; t++) begin
          if (is_younger(TagW'(t), i_flush_tag, head_tag_q)) begin
            ov_pend_q[t]    <= 1'b0;
            rob_vwrite_q[t] <= 1'b0;
            rob_vload_q[t]  <= 1'b0;
            rob_wr_v0_q[t]  <= 1'b0;
            rob_vl_chg_q[t] <= 1'b0;
          end
        end
      end
      if (ov_accept) ov_pend_q[ov_pick_tag] <= 1'b0;
      if (i_commit_valid) begin
        rob_vwrite_q[i_commit_tag] <= 1'b0;
        rob_vload_q[i_commit_tag]  <= 1'b0;
        rob_wr_v0_q[i_commit_tag]  <= 1'b0;
        rob_vl_chg_q[i_commit_tag] <= 1'b0;
      end
      if (alloc_q_live) begin
        ov_pend_q[alloc_q_tag]    <= alloc_q_is_vtox;
        rob_vwrite_q[alloc_q_tag] <= alloc_q_is_varith;
        rob_vload_q[alloc_q_tag]  <= alloc_q_is_vload;
        rob_wr_v0_q[alloc_q_tag]  <= alloc_q_is_varith && alloc_wr_v0;
        rob_vl_chg_q[alloc_q_tag] <= alloc_q_is_vcfg || alloc_q_is_vload;
      end
      if (alloc_q_2_valid) begin
        ov_pend_q[alloc_q_2_tag]    <= 1'b0;
        rob_vwrite_q[alloc_q_2_tag] <= 1'b0;
        rob_vload_q[alloc_q_2_tag]  <= 1'b0;
        rob_wr_v0_q[alloc_q_2_tag]  <= 1'b0;
        rob_vl_chg_q[alloc_q_2_tag] <= 1'b0;
      end
    end
  end

  assign o_vtox_commit = i_commit_valid && vtox_retire_q[i_commit_tag] && !i_commit_exception;

  logic varith_commit_only;
  logic vhead_retire_vload, vhead_retire_vstore;
  assign varith_commit_only = i_commit_valid && is_varith_q[i_commit_tag] && !i_commit_exception;
  assign o_varith_commit    = varith_commit_only || vhead_retire_vload;
  assign o_vstore_commit    = vhead_retire_vstore;

  // Shared VRF memory-side read & write ports on u_engine
  logic [4:0] xr_addr;
  logic [VLEN-1:0] xr_data;
  logic vmu_xr_en;
  logic [4:0] vmu_xr_addr;
  logic vhead_vrf_read_en;
  logic [4:0] vhead_vrf_read_addr;
  logic vmu_xw_en;
  logic [4:0] vmu_xw_addr;
  logic [VLEN-1:0] vmu_xw_data;
  logic [VlenBytes-1:0] vmu_xw_be;

  // Registered handoff latch between vec_head_mmu and vec_vmu
  logic vmem_desc_valid_q;
  logic [riscv_pkg::VmtPpnBits-1:0] vmem_desc_ppn0_q, vmem_desc_ppn1_q;
  logic [11:0] vmem_desc_page_offset_q;
  logic [15:0] vmem_desc_first_elem_q, vmem_desc_last_elem_q;
  logic [1:0] vmem_desc_eew_log2_q;
  logic [VLEN-1:0] vmem_desc_active_mask_q;
  logic vmem_desc_is_store_q;
  logic [4:0] vmem_desc_vd_vs3_q;
  logic [VmtIdxW-1:0] vmem_desc_vmt_idx_q;
  logic vmem_desc_free_vmt_q;
  logic [SegW-1:0] vmem_desc_seg0_q, vmem_desc_seg1_q;

  logic vmu_idle, vmu_done, vmu_cmd_valid;
  logic vmu_vmt_done_valid;
  logic [VmtIdxW-1:0] vmu_vmt_done_idx;
  logic zero_vmt_done_valid;
  logic [VmtIdxW-1:0] zero_vmt_done_idx;

  // VIQ: {insn, scalar, vl, vtype, vstart, vxrm, frm} plus precomputed class
  // and register masks for pipelined issue and engine-vs-VMU overlap.
  localparam int unsigned EntryW = 32 + 64 + 16 + 9 + 16 + 2 + 3;
  logic [EntryW-1:0] viq_q[Depth];
  logic viq_grp_alu_q[Depth];
  logic [31:0] viq_rd_mask_q[Depth], viq_wr_mask_q[Depth];
  logic [Depth-1:0] viq_valid_q;
  logic [$clog2(Depth)-1:0] head_q, tail_q;
  logic [$clog2(Depth):0] count_q;
  logic push, pop, issued_non_grp_q;
  logic non_grp_busy_q;
  logic [31:0] non_grp_wr_mask_q;
  logic eng_idle, eng_grp_ready;
  logic [31:0] eng_wr_mask;

  // Active VMU register write/read masks (registered on launch, cleared on
  // vmu_done) for engine-alongside-VMU overlap without combinational paths
  // from u_vmu into u_engine issue logic.
  logic [31:0] vmu_wr_mask_q, vmu_rd_mask_q;

  logic [31:0] e_insn;
  logic [63:0] e_scalar;
  logic [15:0] e_vl, e_vstart;
  logic [8:0] e_vtype;
  logic [1:0] e_vxrm;
  logic [2:0] e_frm;
  logic e_is_grp_alu;
  logic [31:0] e_rd_mask, e_wr_mask;
  assign {e_insn, e_scalar, e_vl, e_vtype, e_vstart, e_vxrm, e_frm} = viq_q[head_q];
  assign e_is_grp_alu = viq_grp_alu_q[head_q];
  assign e_rd_mask = viq_rd_mask_q[head_q];
  assign e_wr_mask = viq_wr_mask_q[head_q];

  logic vmu_hazard;
  assign vmu_hazard = |((e_rd_mask | e_wr_mask) & vmu_wr_mask_q) || |(e_wr_mask & vmu_rd_mask_q);

  logic [4:0] push_vs2, push_vs1;
  logic push_is_grp_alu, push_rd_v0, push_has_vs2, push_has_vs1;
  logic [2:0] push_vs2_wlast, push_vs1_wlast;
  logic [31:0] push_wr_mask, push_rd_mask;
  assign {push_vs2, push_vs1, push_is_grp_alu, push_rd_v0, push_has_vs2,
          push_vs2_wlast, push_has_vs1, push_vs1_wlast} = rob_meta_q[i_commit_tag];
  assign push_wr_mask = vec_span_mask(rob_vd_q[i_commit_tag], rob_wlast_q[i_commit_tag]);
  assign push_rd_mask = (push_has_vs2 ? vec_span_mask(
      push_vs2, push_vs2_wlast
  ) : 32'd0) | (push_has_vs1 ? vec_span_mask(
      push_vs1, push_vs1_wlast
  ) : 32'd0) | {31'd0, push_rd_v0};

  logic pop_ready_common, pop_grp, pop_non_grp;
  assign push = varith_commit_only;
  assign pop_ready_common = (count_q != '0) && !vmem_desc_valid_q && !vmu_hazard &&
      !issued_non_grp_q;
  assign pop_grp = pop_ready_common && e_is_grp_alu && eng_grp_ready;
  assign pop_non_grp = pop_ready_common && !e_is_grp_alu && eng_idle;
  assign pop = pop_grp || pop_non_grp;
  always_ff @(posedge i_clk) begin
    if (push) begin
      viq_q[tail_q] <= {
        insn_q[i_commit_tag], i_commit_value, i_vl, i_vtype, i_vstart, i_vxrm, i_frm
      };
      viq_grp_alu_q[tail_q] <= push_is_grp_alu;
      viq_rd_mask_q[tail_q] <= push_rd_mask;
      viq_wr_mask_q[tail_q] <= push_wr_mask;
    end
    if (pop_non_grp) non_grp_wr_mask_q <= e_wr_mask;
    if (i_rst) begin
      viq_valid_q      <= '0;
      head_q           <= '0;
      tail_q           <= '0;
      count_q          <= '0;
      issued_non_grp_q <= 1'b0;
      non_grp_busy_q   <= 1'b0;
      o_commit_hold    <= 1'b0;
    end else begin
      if (pop) viq_valid_q[head_q] <= 1'b0;
      if (push) viq_valid_q[tail_q] <= 1'b1;
      if (push) tail_q <= tail_q + 1'b1;
      if (pop) head_q <= head_q + 1'b1;
      count_q <= count_q + ($clog2(Depth) + 1)'(push) - ($clog2(Depth) + 1)'(pop);
      issued_non_grp_q <= pop_non_grp;
      if (pop_non_grp) non_grp_busy_q <= 1'b1;
      else if (!issued_non_grp_q && eng_idle) non_grp_busy_q <= 1'b0;
      // Two spare entries cover the commit bus's registered delay.
      o_commit_hold <= (count_q + ($clog2(Depth) + 1)'(push)) >= ($clog2(Depth) + 1)'(Depth - 2);
    end
  end

  logic [31:0] viq_all_wr_mask;
  always_comb begin
    viq_all_wr_mask = 32'd0;
    for (int i = 0; i < Depth; i++) begin
      if (viq_valid_q[i]) viq_all_wr_mask = viq_all_wr_mask | viq_wr_mask_q[i];
    end
  end

  vec_engine #(
      .VLEN       (VLEN),
      .SPLIT_ISSUE(1'b1)
  ) u_engine (
      .i_clk        (i_clk),
      .i_rst        (i_rst),
      .i_valid      (pop_grp),
      .i_aux_valid  (pop_non_grp),
      .o_idle       (eng_idle),
      .o_grp_ready  (eng_grp_ready),
      .o_wr_mask    (eng_wr_mask),
      .i_insn       (e_insn),
      .i_vsew       (e_vtype[5:3]),
      .i_vlmul      (e_vtype[2:0]),
      .i_vl         (e_vl),
      .i_vstart     (e_vstart),
      .i_rs1        (e_scalar),
      .o_unsupported(),
      .i_vxrm       (e_vxrm),
      .o_sat        (o_vxsat_set),
      .i_frm        (e_frm),
      .o_flags_valid(o_fp_flags_valid),
      .o_flags      (o_fp_flags),
      .i_xr_addr    (xr_addr),
      .o_xr_data    (xr_data),
      .i_xw_en      (vmu_xw_en),
      .i_xw_addr    (vmu_xw_addr),
      .i_xw_data    (vmu_xw_data),
      .i_xw_be      (vmu_xw_be)
  );

  // --------------------------------------------------------------------------
  // Head-only service (OPFVF f-register scalar read and OP-VE group bounds)
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    X_IDLE,
    X_WAIT,
    X_FP_RD,  // capture f-register scalar operand
    X_OUT  // presented until granted
  } xstate_e;
  xstate_e xs;
  logic [31:0] xi;
  logic [1:0] xwait_q;
  logic [63:0] xres_q;
  logic group_bounds_fault_q;
  // The f-register read of an OPFVF instruction, held from the head check to
  // the grant
  logic fp_read_q;
  logic [4:0] fp_read_addr_q;
  assign xi = insn_q[vtox_tag_q];

  logic desc_launch_valid;
  logic desc_launch_is_store;
  logic vec_backend_idle, vec_backend_idle_q;
  logic vtox_backend_ready;
  assign vec_backend_idle = eng_idle && (count_q == '0) && !issued_non_grp_q &&
                            vmu_idle && !vmem_desc_valid_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) vec_backend_idle_q <= 1'b1;
    else vec_backend_idle_q <= vec_backend_idle && !push && !desc_launch_valid;
  end
  assign vtox_backend_ready = vec_backend_idle_q && !o_vmem_head_shield && !i_csr_wb_pending;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      xs                   <= X_IDLE;
      fp_read_q            <= 1'b0;
      fp_read_addr_q       <= '0;
      group_bounds_fault_q <= 1'b0;
    end else if (i_flush_all) begin
      xs                   <= X_IDLE;
      fp_read_q            <= 1'b0;
      fp_read_addr_q       <= '0;
      group_bounds_fault_q <= 1'b0;
    end else begin
      unique case (xs)
        X_IDLE:
        if (!i_rob_empty && head_xs_q[i_head_tag] && i_head_safe && vtox_backend_ready) begin
          vtox_tag_q     <= i_head_tag;
          fp_read_q      <= insn_q[i_head_tag][14:12] == 3'b101;
          fp_read_addr_q <= insn_q[i_head_tag][19:15];
          xwait_q        <= '0;
          xs             <= X_WAIT;
        end
        X_WAIT: begin
          xwait_q <= xwait_q + 2'd1;
          // The last older instruction's queue push lands a cycle after it
          // retires, so idleness is checked again before completing.
          if (xwait_q == 2'd1) begin
            group_bounds_fault_q <= riscv_pkg::vector_partial_group(
                xi[6:0], i_vl[1:0], i_vstart[1:0]
            );
            xres_q <= 64'(xi);
            if (vtox_backend_ready && !i_rob_empty && i_head_tag == vtox_tag_q && i_head_safe) begin
              // Element groups need only the architectural bounds at the head.
              xs <= (xi[6:0] == riscv_pkg::OPC_OP_VE) ? X_OUT : X_FP_RD;
            end else begin
              xs        <= X_IDLE;
              fp_read_q <= 1'b0;
            end
          end
        end
        X_FP_RD: begin
          xres_q <= i_fp_read_data;
          xs     <= X_OUT;
        end
        X_OUT:
        if (vtox_done) begin
          xs        <= X_IDLE;
          fp_read_q <= 1'b0;
        end
        default: xs <= X_IDLE;
      endcase
    end
  end

  riscv_pkg::fu_complete_t vtox_only_complete, vhead_complete, ov_complete;
  assign vtox_done = (xs == X_OUT) && i_grant && !vhead_complete.valid;
  always_comb begin
    vtox_only_complete           = '0;
    vtox_only_complete.valid     = (xs == X_OUT);
    vtox_only_complete.tag       = vtox_tag_q;
    vtox_only_complete.value     = riscv_pkg::FLEN'(xres_q);
    vtox_only_complete.exception = group_bounds_fault_q;
    vtox_only_complete.exc_cause = riscv_pkg::exc_cause_t'(2);
  end

  // --------------------------------------------------------------------------
  // Off-head vector-to-scalar execution (vmv.x.s, vfmv.f.s, vcpop.m, vfirst.m)
  // --------------------------------------------------------------------------
  localparam int unsigned Blocks = VLEN / 64;
  typedef enum logic [2:0] {
    OV_IDLE,
    OV_CHK,     // check older-ROB and backend hazards; speculatively read vs2
    OV_CAP_MV,  // format vmv.x.s / vfmv.f.s from xr_data
    OV_RD0,     // capture vs2 and read v0 for masked vcpop.m / vfirst.m
    OV_ST1,     // capture active mask
    OV_ST2,     // capture per-block counts and first indices
    OV_REDUCE,  // combine blocks for vcpop.m and vfirst.m
    OV_OUT      // presented on CDB slot 6 until granted
  } ov_state_e;
  ov_state_e ov_state_q;
  logic [31:0] ov_insn_q;
  logic [1:0] ov_sew_q;
  logic [15:0] ov_vl_q;
  logic [VLEN-1:0] ov_s2_q, ov_active_q;
  logic ov_s2_cap_q;
  logic [Blocks-1:0][6:0] ov_blk_cnt_q;
  logic [Blocks-1:0][5:0] ov_blk_first_q;
  logic [Blocks-1:0] ov_blk_any_q;
  logic [63:0] ov_res_q;

  logic [4:0] ov_vs2;
  logic ov_is_fp_mv, ov_is_mv, ov_is_mask_red, ov_is_first, ov_masked;
  assign ov_vs2         = ov_insn_q[24:20];
  assign ov_is_fp_mv    = (ov_insn_q[14:12] == 3'b001);
  assign ov_is_mv       = (ov_insn_q[19:15] == 5'b00000);
  assign ov_is_mask_red = (ov_insn_q[14:12] == 3'b010) && !ov_is_mv;
  assign ov_is_first    = (ov_insn_q[19:15] == 5'b10001);
  assign ov_masked      = ov_is_mask_red && !ov_insn_q[25];

  // Pick the oldest pending VTOX/VTOF tag in circular ROB order.
  logic [2*RobDepth-1:0] ov_pend_dbl;
  logic [  RobDepth-1:0] ov_pend_rot;
  logic [      TagW-1:0] ov_pick_dist;
  assign ov_pend_dbl = {ov_pend_q, ov_pend_q};
  assign ov_pend_rot = ov_pend_dbl[{1'b0, head_tag_q}+:RobDepth];
  always_comb begin
    ov_pick_dist = '0;
    for (int d = RobDepth - 1; d >= 0; d--) begin
      if (ov_pend_rot[d]) ov_pick_dist = TagW'(d);
    end
  end
  assign ov_pick_tag = head_tag_q + ov_pick_dist;
  assign ov_accept = (ov_state_q == OV_IDLE) && !i_rob_empty && !i_flush_spec &&
      !flush_spec_d1_q && !i_flush_en && (|ov_pend_q);

  // Older-ROB hazard check for the selected tag (pure flop inputs).
  logic [TagW-1:0] ov_age;
  logic [RobDepth-1:0] ov_rob_blk;
  logic ov_older_rob_hazard;
  assign ov_age = ov_tag_q - head_tag_q;
  always_comb begin
    for (int j = 0; j < RobDepth; j++) begin
      logic [TagW-1:0] j_age;
      logic j_older;
      logic [4:0] vs2_diff;
      logic hit_vs2, hit_v0, hit_vl;
      j_age = TagW'(j) - head_tag_q;
      j_older = (j_age < ov_age);
      vs2_diff = ov_vs2 - rob_vd_q[j];
      hit_vs2 = rob_vload_q[j] ||
          (rob_vwrite_q[j] && (vs2_diff[4:3] == 2'b00) && (vs2_diff[2:0] <= rob_wlast_q[j]));
      hit_v0 = ov_masked && (rob_vload_q[j] || rob_wr_v0_q[j]);
      hit_vl = ov_is_mask_red && rob_vl_chg_q[j];
      ov_rob_blk[j] = j_older && (hit_vs2 || hit_v0 || hit_vl);
    end
    ov_older_rob_hazard = |ov_rob_blk;
  end

  // Registered committed-backend write mask (VIQ + engine + VMU); any new
  // write entering on the previous or current cycle stalls via the 1-bit
  // push/vload flags so backend_wr_mask_q never misses a live write.
  logic [31:0] backend_wr_mask_live, backend_wr_mask_q;
  logic backend_vload_live, backend_push_d1_q, backend_vload_d1_q;
  assign backend_wr_mask_live = viq_all_wr_mask | eng_wr_mask |
      (non_grp_busy_q ? non_grp_wr_mask_q : 32'd0) | vmu_wr_mask_q;
  assign backend_vload_live = (desc_launch_valid && !desc_launch_is_store) ||
      (vmem_desc_valid_q && !vmem_desc_is_store_q);
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      backend_wr_mask_q  <= 32'd0;
      backend_push_d1_q  <= 1'b0;
      backend_vload_d1_q <= 1'b0;
    end else begin
      backend_wr_mask_q  <= backend_wr_mask_live;
      backend_push_d1_q  <= push;
      backend_vload_d1_q <= backend_vload_live;
    end
  end

  logic ov_backend_hazard, ov_vl_hazard, ov_hazard;
  assign ov_backend_hazard = push || backend_push_d1_q || backend_vload_live ||
      backend_vload_d1_q || backend_wr_mask_q[ov_vs2] || (ov_masked && backend_wr_mask_q[0]);
  assign ov_vl_hazard = ov_is_mask_red &&
      (i_vcfg_commit_valid || o_vl_trim_valid || i_csr_wb_pending);
  assign ov_hazard = ov_older_rob_hazard || ov_backend_hazard || ov_vl_hazard;

  logic ov_killed, ov_port4_busy, ov_xr_en;
  assign ov_killed = (ov_state_q != OV_IDLE) && (i_flush_spec || (i_flush_en && is_younger(
      ov_tag_q, i_flush_tag, i_head_tag
  )));
  assign ov_port4_busy = vmu_xr_en || vhead_vrf_read_en;
  assign ov_xr_en = !ov_port4_busy && !ov_killed &&
      (((ov_state_q == OV_CHK) && !ov_hazard) || (ov_state_q == OV_RD0));
  assign xr_addr = vmu_xr_en         ? vmu_xr_addr :
                   vhead_vrf_read_en ? vhead_vrf_read_addr :
                   (ov_state_q == OV_RD0) ? 5'd0 : ov_vs2;

  assign ov_done = (ov_state_q == OV_OUT) && !ov_killed &&
      i_grant && !vhead_complete.valid && !vtox_only_complete.valid;

  assign o_idle = vec_backend_idle && (xs == X_IDLE) && (ov_state_q == OV_IDLE) &&
      !o_vmem_head_shield;

  // Per-64-bit counts and first set bits of the active mask for vcpop.m/vfirst.m.
  logic [Blocks-1:0][6:0] ov_blk_cnt;
  logic [Blocks-1:0][5:0] ov_blk_first;
  logic [Blocks-1:0] ov_blk_any;
  always_comb begin
    for (int b = 0; b < Blocks; b++) begin
      ov_blk_first[b] = 6'd63;
      for (int j = 63; j >= 0; j--) if (ov_active_q[64*b+j]) ov_blk_first[b] = 6'(j);
      ov_blk_cnt[b] = 7'($countones(ov_active_q[64*b+:64]));
      ov_blk_any[b] = |ov_active_q[64*b+:64];
    end
  end

  logic [VLEN-1:0] ov_body;
  always_comb for (int k = 0; k < VLEN; k++) ov_body[k] = 16'(k) < ov_vl_q;

  logic [63:0] ov_mv_res, ov_red_res;
  always_comb begin
    if (ov_is_fp_mv) begin
      case (ov_sew_q)
        2'd1:    ov_mv_res = {48'hffff_ffff_ffff, xr_data[15:0]};
        2'd2:    ov_mv_res = {32'hffff_ffff, xr_data[31:0]};
        default: ov_mv_res = xr_data[63:0];
      endcase
    end else begin
      unique case (ov_sew_q)
        2'd0:    ov_mv_res = {{56{xr_data[7]}}, xr_data[7:0]};
        2'd1:    ov_mv_res = {{48{xr_data[15]}}, xr_data[15:0]};
        2'd2:    ov_mv_res = {{32{xr_data[31]}}, xr_data[31:0]};
        default: ov_mv_res = xr_data[63:0];
      endcase
    end
  end

  always_comb begin
    logic [15:0] cnt;
    logic [63:0] first;
    logic found;
    cnt   = '0;
    first = '1;
    found = 1'b0;
    for (int b = 0; b < Blocks; b++) begin
      cnt = cnt + 16'(ov_blk_cnt_q[b]);
      if (!found && ov_blk_any_q[b]) begin
        first = 64'(64 * b) + 64'(ov_blk_first_q[b]);
        found = 1'b1;
      end
    end
    ov_red_res = ov_is_first ? first : 64'(cnt);
  end

  // Off-head control state (4 flops driven by i_rst and ov_killed).
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ov_state_q  <= OV_IDLE;
      ov_s2_cap_q <= 1'b0;
    end else if (ov_killed) begin
      ov_state_q  <= OV_IDLE;
      ov_s2_cap_q <= 1'b0;
    end else begin
      unique case (ov_state_q)
        OV_IDLE: begin
          if (ov_accept) ov_state_q <= OV_CHK;
        end
        OV_CHK: begin
          if (!ov_hazard && !ov_port4_busy) begin
            ov_s2_cap_q <= 1'b0;
            if (!ov_is_mask_red) ov_state_q <= OV_CAP_MV;
            else if (ov_masked) ov_state_q <= OV_RD0;
            else ov_state_q <= OV_ST1;
          end
        end
        OV_CAP_MV: ov_state_q <= OV_OUT;
        OV_RD0: begin
          if (!ov_s2_cap_q) ov_s2_cap_q <= 1'b1;
          if (!ov_port4_busy) ov_state_q <= OV_ST1;
        end
        OV_ST1: ov_state_q <= OV_ST2;
        OV_ST2: ov_state_q <= OV_REDUCE;
        OV_REDUCE: ov_state_q <= OV_OUT;
        OV_OUT: if (ov_done) ov_state_q <= OV_IDLE;
        default: ov_state_q <= OV_IDLE;
      endcase
    end
  end

  // Off-head datapath registers (state-only enables; no reset or kill fanout).
  always_ff @(posedge i_clk) begin
    if (ov_state_q == OV_IDLE) begin
      ov_tag_q  <= ov_pick_tag;
      ov_insn_q <= insn_q[ov_pick_tag];
      ov_sew_q  <= vtox_sew_q[ov_pick_tag];
    end
    if (ov_state_q == OV_CHK) ov_vl_q <= i_vl;
    if ((ov_state_q == OV_RD0) && !ov_s2_cap_q) ov_s2_q <= xr_data;
    if (ov_state_q == OV_ST1) ov_active_q <= (ov_masked ? (ov_s2_q & xr_data) : xr_data) & ov_body;
    if (ov_state_q == OV_ST2) begin
      ov_blk_cnt_q   <= ov_blk_cnt;
      ov_blk_first_q <= ov_blk_first;
      ov_blk_any_q   <= ov_blk_any;
    end
    if (ov_state_q == OV_CAP_MV) ov_res_q <= ov_mv_res;
    else if (ov_state_q == OV_REDUCE) ov_res_q <= ov_red_res;
  end

  always_comb begin
    ov_complete       = '0;
    ov_complete.valid = (ov_state_q == OV_OUT) && !ov_killed;
    ov_complete.tag   = ov_tag_q;
    ov_complete.value = riscv_pkg::FLEN'(ov_res_q);
  end

  // --------------------------------------------------------------------------
  // Head MMU & Vector Memory Unit
  // --------------------------------------------------------------------------
  logic [riscv_pkg::VmtPpnBits-1:0] desc_launch_ppn0, desc_launch_ppn1;
  logic [11:0] desc_launch_page_offset;
  logic [15:0] desc_launch_first_elem, desc_launch_last_elem;
  logic [1:0] desc_launch_eew_log2;
  logic [VLEN-1:0] desc_launch_active_mask;
  logic [4:0] desc_launch_vd_vs3;
  logic [VmtIdxW-1:0] desc_launch_vmt_idx;
  logic desc_launch_free_vmt;
  logic [SegW-1:0] desc_launch_seg0, desc_launch_seg1;

  // The head MMU's rs1 read and the OPFVF scalar read share the register
  // files' extra read port; one instruction is at the head, so they never
  // overlap.
  logic hmmu_rf_read_en;
  logic [4:0] hmmu_rf_read_addr;
  assign o_rf_read_en   = hmmu_rf_read_en || fp_read_q;
  assign o_rf_read_addr = fp_read_q ? fp_read_addr_q : hmmu_rf_read_addr;

  vec_head_mmu #(
      .VLEN          (VLEN),
      .CACHED_TIER_EN(CACHED_TIER_EN)
  ) u_head_mmu (
      .i_clk                    (i_clk),
      .i_rst                    (i_rst),
      .i_head_tag               (i_head_tag),
      .i_rob_empty              (i_rob_empty),
      .i_head_safe              (i_head_safe),
      .i_head_is_vmem           (is_vmem_q[i_head_tag]),
      .i_head_insn              (insn_q[i_head_tag]),
      .i_head_vmt_idx           (vmt_idx_by_tag_q[i_head_tag]),
      .i_flush_all              (i_flush_all),
      .i_fatal_stop             (i_fatal_stop),
      .i_commit_valid           (i_commit_valid),
      .i_commit_tag             (i_commit_tag),
      .i_commit_exception       (i_commit_exception),
      .i_vec_idle               (vec_backend_idle_q && (xs == X_IDLE)),
      .i_csr_wb_pending         (i_csr_wb_pending),
      .i_sq_committed_empty     (i_sq_committed_empty),
      .i_int_take_armed         (i_int_take_armed),
      .i_vl                     (i_vl),
      .i_vtype                  (i_vtype),
      .i_vstart                 (i_vstart),
      .o_rf_read_en             (hmmu_rf_read_en),
      .o_rf_read_addr           (hmmu_rf_read_addr),
      .i_rf_read_data           (i_rf_read_data),
      .o_vrf_read_en            (vhead_vrf_read_en),
      .o_vrf_read_addr          (vhead_vrf_read_addr),
      .i_vrf_read_data          (xr_data),
      .i_translate              (i_translate),
      .i_eff_priv_u             (i_eff_priv_u),
      .i_sum                    (i_sum),
      .i_mxr                    (i_mxr),
      .i_pm_mode                (i_pm_mode),
      .i_tlb_invalidate         (i_tlb_invalidate),
      .o_walk_req_valid         (o_walk_req_valid),
      .i_walk_req_ready         (i_walk_req_ready),
      .o_walk_vpn               (o_walk_vpn),
      .i_walk_resp_valid        (i_walk_resp_valid),
      .i_walk_resp              (i_walk_resp),
      .o_vmt_range_valid        (o_vmt_range_valid),
      .o_vmt_range_idx          (o_vmt_range_idx),
      .o_vmt_range_seg0         (o_vmt_range_seg0),
      .o_vmt_range_seg1         (o_vmt_range_seg1),
      .o_zero_vmt_done_valid    (zero_vmt_done_valid),
      .o_zero_vmt_done_idx      (zero_vmt_done_idx),
      .i_grant                  (i_grant),
      .o_vhead_complete         (vhead_complete),
      .o_cdb_done               (vhead_cdb_done),
      .o_cdb_done_tag           (vhead_cdb_done_tag),
      .o_vmem_head_shield       (o_vmem_head_shield),
      .o_vmem_fault_vstart_valid(o_vmem_fault_vstart_valid),
      .o_vmem_fault_vstart      (o_vmem_fault_vstart),
      .o_retire_vload           (vhead_retire_vload),
      .o_retire_vstore          (vhead_retire_vstore),
      .o_vmem_vs_dirty          (o_vmem_vs_dirty),
      .o_vl_trim_valid          (o_vl_trim_valid),
      .o_vl_trim                (o_vl_trim),
      .o_desc_valid             (desc_launch_valid),
      .o_desc_ppn0              (desc_launch_ppn0),
      .o_desc_ppn1              (desc_launch_ppn1),
      .o_desc_page_offset       (desc_launch_page_offset),
      .o_desc_first_elem        (desc_launch_first_elem),
      .o_desc_last_elem         (desc_launch_last_elem),
      .o_desc_eew_log2          (desc_launch_eew_log2),
      .o_desc_active_mask       (desc_launch_active_mask),
      .o_desc_is_store          (desc_launch_is_store),
      .o_desc_vd_vs3            (desc_launch_vd_vs3),
      .o_desc_vmt_idx           (desc_launch_vmt_idx),
      .o_desc_free_vmt_on_done  (desc_launch_free_vmt),
      .o_desc_seg0              (desc_launch_seg0),
      .o_desc_seg1              (desc_launch_seg1),
      .i_vmu_done               (vmu_done),
      .i_vmu_fatal              (o_vmu_fatal)
  );

  // Handoff latch: never cleared by i_flush_all, because retired vector memory
  // instructions must run to completion across any younger mispredict/trap flush.
  assign vmu_cmd_valid = vmem_desc_valid_q && vmu_idle && eng_idle && !issued_non_grp_q &&
                         !i_fatal_stop && !o_vmu_fatal;

  logic [4:0] vmu_first_r, vmu_last_r;
  logic [31:0] vmu_launch_mask;
  assign vmu_first_r = vmem_desc_vd_vs3_q +
      5'((vmem_desc_first_elem_q << vmem_desc_eew_log2_q) >> ByteBits);
  assign vmu_last_r = vmem_desc_vd_vs3_q +
      5'((vmem_desc_last_elem_q << vmem_desc_eew_log2_q) >> ByteBits);
  assign vmu_launch_mask = vec_grp_mask(vmu_first_r, 4'(vmu_last_r - vmu_first_r) + 4'd1);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      vmem_desc_valid_q <= 1'b0;
      vmu_wr_mask_q     <= 32'd0;
      vmu_rd_mask_q     <= 32'd0;
    end else if (i_fatal_stop || o_vmu_fatal) begin
      vmem_desc_valid_q <= 1'b0;
      vmu_wr_mask_q     <= 32'd0;
      vmu_rd_mask_q     <= 32'd0;
    end else begin
      if (vmu_done) begin
        vmu_wr_mask_q <= 32'd0;
        vmu_rd_mask_q <= 32'd0;
      end
      if (desc_launch_valid) begin
        vmem_desc_valid_q       <= 1'b1;
        vmem_desc_ppn0_q        <= desc_launch_ppn0;
        vmem_desc_ppn1_q        <= desc_launch_ppn1;
        vmem_desc_page_offset_q <= desc_launch_page_offset;
        vmem_desc_first_elem_q  <= desc_launch_first_elem;
        vmem_desc_last_elem_q   <= desc_launch_last_elem;
        vmem_desc_eew_log2_q    <= desc_launch_eew_log2;
        vmem_desc_active_mask_q <= desc_launch_active_mask;
        vmem_desc_is_store_q    <= desc_launch_is_store;
        vmem_desc_vd_vs3_q      <= desc_launch_vd_vs3;
        vmem_desc_vmt_idx_q     <= desc_launch_vmt_idx;
        vmem_desc_free_vmt_q    <= desc_launch_free_vmt;
        vmem_desc_seg0_q        <= desc_launch_seg0;
        vmem_desc_seg1_q        <= desc_launch_seg1;
      end else if (vmu_cmd_valid) begin
        vmem_desc_valid_q <= 1'b0;
        vmu_wr_mask_q     <= vmem_desc_is_store_q ? 32'd0 : vmu_launch_mask;
        vmu_rd_mask_q     <= vmem_desc_is_store_q ? vmu_launch_mask : 32'd0;
      end
    end
  end

  vec_vmu #(
      .VLEN(VLEN)
  ) u_vmu (
      .i_clk             (i_clk),
      .i_rst             (i_rst),
      .i_fatal_stop      (i_fatal_stop),
      .i_cmd_valid       (vmu_cmd_valid),
      .i_ppn0            (vmem_desc_ppn0_q),
      .i_ppn1            (vmem_desc_ppn1_q),
      .i_page_offset     (vmem_desc_page_offset_q),
      .i_first_elem      (vmem_desc_first_elem_q),
      .i_last_elem       (vmem_desc_last_elem_q),
      .i_eew_log2        (vmem_desc_eew_log2_q),
      .i_row_stride      (64'd0),
      .i_row_count       (16'd1),
      .i_active_mask     (vmem_desc_active_mask_q),
      .i_is_store        (vmem_desc_is_store_q),
      .i_vd_vs3          (vmem_desc_vd_vs3_q),
      .i_vmt_idx         (vmem_desc_vmt_idx_q),
      .i_free_vmt_on_done(vmem_desc_free_vmt_q),
      .i_dbg_seg0        (vmem_desc_seg0_q),
      .i_dbg_seg1        (vmem_desc_seg1_q),
      .o_idle            (vmu_idle),
      .o_done            (vmu_done),
      .o_vmt_done_valid  (vmu_vmt_done_valid),
      .o_vmt_done_idx    (vmu_vmt_done_idx),
      .o_xr_en           (vmu_xr_en),
      .o_xr_addr         (vmu_xr_addr),
      .i_xr_data         (xr_data),
      .o_xw_en           (vmu_xw_en),
      .o_xw_addr         (vmu_xw_addr),
      .o_xw_data         (vmu_xw_data),
      .o_xw_be           (vmu_xw_be),
      .o_lc_req_valid    (o_lc_req_valid),
      .i_lc_req_ready    (i_lc_req_ready),
      .o_lc_req_write    (o_lc_req_write),
      .o_lc_req_addr     (o_lc_req_addr),
      .o_lc_req_data     (o_lc_req_data),
      .o_lc_req_mask     (o_lc_req_mask),
      .o_lc_req_id       (o_lc_req_id),
      .i_lc_resp_valid   (i_lc_resp_valid),
      .i_lc_resp_id      (i_lc_resp_id),
      .i_lc_resp_data    (i_lc_resp_data),
      .i_lc_resp_error   (i_lc_resp_error),
      .o_fatal           (o_vmu_fatal),
      .o_fatal_addr      (o_vmu_fatal_addr)
  );

  assign o_vtox_complete = vhead_complete.valid ? vhead_complete :
      (vtox_only_complete.valid ? vtox_only_complete : ov_complete);
  assign o_vmt_done_valid = zero_vmt_done_valid || vmu_vmt_done_valid;
  assign o_vmt_done_idx = zero_vmt_done_valid ? zero_vmt_done_idx : vmu_vmt_done_idx;

`ifndef SYNTHESIS
`ifndef FORMAL
  logic x_reset_seen_q = 1'b0;
  // The vl and vstart that the head check judged for the last OP-VE. Its
  // queue entry samples the CSRs again at the registered commit, and the
  // engine trusts that second sample to be whole element groups.
  logic x_group_sampled_q;
  logic [15:0] x_group_vl_q, x_group_vstart_q;
  always @(posedge i_clk) begin
    if (i_rst) x_group_sampled_q <= 1'b0;
    else if (xs == X_WAIT && xwait_q == 2'd1 && xi[6:0] == riscv_pkg::OPC_OP_VE) begin
      x_group_sampled_q <= 1'b1;
      x_group_vl_q <= i_vl;
      x_group_vstart_q <= i_vstart;
    end
  end
  always @(posedge i_clk) begin
    if (i_rst) x_reset_seen_q <= 1'b1;
    if (x_reset_seen_q && !i_rst) begin
      if (push && insn_q[i_commit_tag][6:0] == riscv_pkg::OPC_OP_VE) begin
        assert (i_vl[1:0] == 2'b00 && i_vstart[1:0] == 2'b00)
        else
          $error(
              "vec_unit: element group queued with vl %0d, vstart %0d (tag %0d)",
              i_vl,
              i_vstart,
              i_commit_tag
          );
        assert (x_group_sampled_q && i_vl == x_group_vl_q && i_vstart == x_group_vstart_q)
        else
          $error(
              "vec_unit: element group queued with vl %0d, vstart %0d; head check saw %0d, %0d",
              i_vl,
              i_vstart,
              x_group_vl_q,
              x_group_vstart_q
          );
      end
      assert (!(xs == X_OUT && (i_rob_empty || i_head_tag != vtox_tag_q)))
      else
        $error(
            "vec_unit: head-service result presented for tag %0d, head %0d, empty %0b",
            vtox_tag_q,
            i_head_tag,
            i_rob_empty
        );
      assert (!(ov_complete.valid && i_rob_empty))
      else $error("vec_unit: off-head vector-to-scalar result presented on empty ROB");
      assert (!vec_backend_idle_q || vec_backend_idle)
      else $error("vec_unit: registered backend idle disagreed with live backend idle");
      assert (!(alloc_q_valid && i_commit_valid && (i_commit_tag == alloc_q_tag)))
      else $error("vec_unit: commit arrived for tag still in alloc_q (%0d)", alloc_q_tag);
      assert (vmu_idle || (|vmu_wr_mask_q) || (|vmu_rd_mask_q) || o_vmu_fatal)
      else $error("vec_unit: VMU active with empty registered VMU register masks");
      assert (backend_push_d1_q || backend_vload_d1_q ||
              ((backend_wr_mask_live & ~backend_wr_mask_q) == 32'd0))
      else
        $error(
            "vec_unit: live backend write mask %h not covered by registered mask %h",
            backend_wr_mask_live,
            backend_wr_mask_q
        );
      if (xs == X_OUT && xi[6:0] == riscv_pkg::OPC_OP_VE) assert (xres_q == 64'(xi));
      assert (!(vhead_complete.valid && vtox_only_complete.valid));
      assert (!(zero_vmt_done_valid && vmu_vmt_done_valid));
      assert ($onehot0({ov_xr_en, vhead_vrf_read_en, vmu_xr_en}));
      assert (!(fp_read_q && hmmu_rf_read_en));
      assert (!(desc_launch_valid && vmem_desc_valid_q));
    end
  end
`endif
`endif

endmodule
