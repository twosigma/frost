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
    - Per-ROB-tag instruction word and class flags (is_varith_q, is_vtox_q,
      is_vmem_q) plus the allocated VMT index of each vector memory op.
    - An 8-entry queue (VIQ) filled when a vector arithmetic entry retires,
      feeding vec_engine one instruction at a time.
    - Head-executed vector-to-scalar operations (VTOX: vmv.x.s, vcpop.m,
      vfirst.m; VTOF: vfmv.f.s, NaN-boxed) completing on CDB slot 6. The
      same service reads the f-register scalar of an OPFVF instruction
      (VARITH_F) at the head and completes it with that value, which the
      instruction carries to the VIQ when it retires.
    - OP-VE element-group alignment of architectural vl and vstart checked at
      the ROB head before a successful retirement can enqueue the operation.
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

  logic [31:0] insn_q[riscv_pkg::ReorderBufferDepth];
  logic [VmtIdxW-1:0] vmt_idx_by_tag_q[riscv_pkg::ReorderBufferDepth];
  logic [riscv_pkg::ReorderBufferDepth-1:0] is_varith_q, is_vtox_q, is_vmem_q;
  logic [riscv_pkg::ReorderBufferDepth-1:0] vtox_retire_q;
  logic vtox_done;
  logic [TagW-1:0] vtox_tag_q;
  logic vhead_cdb_done;
  logic [TagW-1:0] vhead_cdb_done_tag;

  always_ff @(posedge i_clk) begin
    if (i_alloc) begin
      insn_q[i_alloc_tag]           <= i_alloc_insn;
      vmt_idx_by_tag_q[i_alloc_tag] <= i_alloc_vmt_idx;
    end
    // Every allocation of a tag rewrites its flags, so a flag left by a
    // squashed vector instruction never describes a later one.
    if (i_rst) begin
      is_vtox_q <= '0;
      vtox_retire_q <= '0;
      is_varith_q <= '0;
      is_vmem_q <= '0;
    end else begin
      if (vtox_done) is_vtox_q[vtox_tag_q] <= 1'b0;
      if (vhead_cdb_done) is_vmem_q[vhead_cdb_done_tag] <= 1'b0;
      if (i_alloc) begin
        is_vtox_q[i_alloc_tag] <= i_alloc_is_vtox || i_alloc_is_vfscalar ||
            (i_alloc_is_varith && (i_alloc_insn[6:0] == riscv_pkg::OPC_OP_VE));
        vtox_retire_q[i_alloc_tag] <= i_alloc_is_vtox;
        is_varith_q[i_alloc_tag] <= i_alloc_is_varith;
        is_vmem_q[i_alloc_tag] <= i_alloc_is_vmem;
      end
      if (i_alloc_2) begin
        is_vtox_q[i_alloc_tag_2] <= 1'b0;
        vtox_retire_q[i_alloc_tag_2] <= 1'b0;
        is_varith_q[i_alloc_tag_2] <= 1'b0;
        is_vmem_q[i_alloc_tag_2] <= 1'b0;
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

  // VIQ: {insn, scalar, vl, vtype, vstart, vxrm, frm}
  localparam int unsigned EntryW = 32 + 64 + 16 + 9 + 16 + 2 + 3;
  logic [EntryW-1:0] viq_q[Depth];
  logic [$clog2(Depth)-1:0] head_q, tail_q;
  logic [$clog2(Depth):0] count_q;
  logic push, pop, issued_q;
  logic eng_idle;
  assign push = varith_commit_only;
  assign pop  = eng_idle && !issued_q && (count_q != '0) && vmu_idle && !vmem_desc_valid_q;
  always_ff @(posedge i_clk) begin
    if (push)
      viq_q[tail_q] <= {
        insn_q[i_commit_tag], i_commit_value, i_vl, i_vtype, i_vstart, i_vxrm, i_frm
      };
    if (i_rst) begin
      head_q        <= '0;
      tail_q        <= '0;
      count_q       <= '0;
      issued_q      <= 1'b0;
      o_commit_hold <= 1'b0;
    end else begin
      if (push) tail_q <= tail_q + 1'b1;
      if (pop) head_q <= head_q + 1'b1;
      count_q <= count_q + ($clog2(Depth) + 1)'(push) - ($clog2(Depth) + 1)'(pop);
      issued_q <= pop;
      // Two spare entries cover the commit bus's registered delay.
      o_commit_hold <= (count_q + ($clog2(Depth) + 1)'(push)) >= ($clog2(Depth) + 1)'(Depth - 2);
    end
  end

  logic [31:0] e_insn;
  logic [63:0] e_scalar;
  logic [15:0] e_vl, e_vstart;
  logic [8:0] e_vtype;
  logic [1:0] e_vxrm;
  logic [2:0] e_frm;
  assign {e_insn, e_scalar, e_vl, e_vtype, e_vstart, e_vxrm, e_frm} = viq_q[head_q];

  vec_engine #(
      .VLEN(VLEN)
  ) u_engine (
      .i_clk        (i_clk),
      .i_rst        (i_rst),
      .i_valid      (pop),
      .o_idle       (eng_idle),
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
  // Vector-to-scalar at the head
  // --------------------------------------------------------------------------
  localparam int unsigned Blocks = VLEN / 64;
  typedef enum logic [2:0] {
    X_IDLE,
    X_WAIT,
    X_RD2,   // vs2 read presented
    X_RD0,   // v0 read presented
    X_ST1,   // per-64-bit counts and first indices
    X_ST2,   // combine
    X_OUT    // presented until granted
  } xstate_e;
  xstate_e xs;
  logic [31:0] xi;
  logic [1:0] xwait_q;
  logic [VLEN-1:0] xs2_q, xactive_q;
  logic [15:0] xvl_q;
  logic [8:0] xvt_q;
  logic [Blocks-1:0][6:0] blk_cnt_q;
  logic [Blocks-1:0][5:0] blk_first_q;
  logic [Blocks-1:0] blk_any_q;
  logic [63:0] xres_q, fp_scalar_q;
  logic group_bounds_fault_q;
  // The f-register read of an OPFVF instruction, held from the head check to
  // the grant
  logic fp_read_q;
  logic [4:0] fp_read_addr_q;
  wire x_masked = !xi[25];
  wire x_is_mv = (xi[19:15] == 5'b00000);
  wire x_is_first = (xi[19:15] == 5'b10001);
  assign xi = insn_q[vtox_tag_q];

  logic vtox_xr_en;
  assign vtox_xr_en = (xs == X_RD2) || (xs == X_RD0);
  assign xr_addr = vmu_xr_en         ? vmu_xr_addr :
                   vhead_vrf_read_en ? vhead_vrf_read_addr :
                   (xs == X_RD0)     ? 5'd0 : xi[24:20];
  assign vtox_done = (xs == X_OUT) && i_grant;

  logic vec_backend_idle;
  logic vtox_backend_ready;
  assign vec_backend_idle   = eng_idle && (count_q == '0) && !issued_q &&
                              vmu_idle && !vmem_desc_valid_q;
  assign vtox_backend_ready = vec_backend_idle && !o_vmem_head_shield && !i_csr_wb_pending;
  assign o_idle = vec_backend_idle && (xs == X_IDLE) && !o_vmem_head_shield;

  // Per-64-bit counts and first set bits of the active mask.
  logic [Blocks-1:0][6:0] blk_cnt;
  logic [Blocks-1:0][5:0] blk_first;
  logic [Blocks-1:0] blk_any;
  always_comb begin
    for (int b = 0; b < Blocks; b++) begin
      blk_first[b] = 6'd63;
      for (int j = 63; j >= 0; j--) if (xactive_q[64*b+j]) blk_first[b] = 6'(j);
      blk_cnt[b] = 7'($countones(xactive_q[64*b+:64]));
      blk_any[b] = |xactive_q[64*b+:64];
    end
  end

  // Body bits below vl.
  logic [VLEN-1:0] body;
  always_comb for (int k = 0; k < VLEN; k++) body[k] = 16'(k) < xvl_q;

  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush_all) begin
      xs <= X_IDLE;
      fp_read_q <= 1'b0;
      fp_read_addr_q <= '0;
      group_bounds_fault_q <= 1'b0;
    end else begin
      unique case (xs)
        X_IDLE:
        if (!i_rob_empty && is_vtox_q[i_head_tag] && i_head_safe && vtox_backend_ready) begin
          vtox_tag_q <= i_head_tag;
          fp_read_q <= insn_q[i_head_tag][14:12] == 3'b101;
          fp_read_addr_q <= insn_q[i_head_tag][19:15];
          xwait_q <= '0;
          xs <= X_WAIT;
        end
        X_WAIT: begin
          xwait_q <= xwait_q + 2'd1;
          // The last older instruction's queue push lands a cycle after it
          // retires, so idleness is checked again before the read.
          if (xwait_q == 2'd1) begin
            xvl_q <= i_vl;
            xvt_q <= i_vtype;
            group_bounds_fault_q <= riscv_pkg::vector_partial_group(
                xi[6:0], i_vl[1:0], i_vstart[1:0]
            );
            if (vtox_backend_ready && !i_rob_empty && i_head_tag == vtox_tag_q && i_head_safe) begin
              // Element groups need only the architectural bounds at the head.
              xs <= (xi[6:0] == riscv_pkg::OPC_OP_VE) ? X_OUT : X_RD2;
            end else begin
              xs <= X_IDLE;
              fp_read_q <= 1'b0;
            end
          end
        end
        X_RD2:   xs <= X_RD0;
        X_RD0: begin
          fp_scalar_q <= i_fp_read_data;
          xs2_q <= xr_data;  // vs2, read last cycle
          xs <= X_ST1;
        end
        X_ST1: begin
          // v0 arrives now; active bits for vcpop/vfirst
          xactive_q <= xs2_q & body & (x_masked ? xr_data : '1);
          xs <= X_ST2;
        end
        X_ST2: begin
          blk_cnt_q <= blk_cnt;
          blk_first_q <= blk_first;
          blk_any_q <= blk_any;
          xs <= X_OUT;
        end
        X_OUT:
        if (i_grant) begin
          xs <= X_IDLE;
          fp_read_q <= 1'b0;
        end
        default: xs <= X_IDLE;
      endcase
    end
  end

  // Result, formed from the block values while presented.
  always_comb begin
    logic [15:0] cnt;
    logic [63:0] first;
    logic found;
    cnt   = '0;
    first = '1;
    found = 1'b0;
    for (int b = 0; b < Blocks; b++) begin
      cnt = cnt + 16'(blk_cnt_q[b]);
      if (!found && blk_any_q[b]) begin
        first = 64'(64 * b) + 64'(blk_first_q[b]);
        found = 1'b1;
      end
    end
    // OPFVF: the f-register scalar; vfmv.f.s: element 0, NaN-boxed
    if (xi[6:0] == riscv_pkg::OPC_OP_VE) xres_q = 64'(xi);
    else if (xi[14:12] == 3'b101) xres_q = fp_scalar_q;
    else if (xi[14:12] == 3'b001) begin
      case (xvt_q[4:3])
        1: xres_q = {48'hffffffffffff, xs2_q[15:0]};
        2: xres_q = {32'hffffffff, xs2_q[31:0]};
        default: xres_q = xs2_q[63:0];
      endcase
    end else if (x_is_mv) begin
      unique case (xvt_q[4:3])
        2'd0: xres_q = {{56{xs2_q[7]}}, xs2_q[7:0]};
        2'd1: xres_q = {{48{xs2_q[15]}}, xs2_q[15:0]};
        2'd2: xres_q = {{32{xs2_q[31]}}, xs2_q[31:0]};
        default: xres_q = xs2_q[63:0];
      endcase
    end else if (x_is_first) xres_q = first;
    else xres_q = 64'(cnt);
  end

  riscv_pkg::fu_complete_t vtox_only_complete, vhead_complete;
  always_comb begin
    vtox_only_complete           = '0;
    vtox_only_complete.valid     = (xs == X_OUT);
    vtox_only_complete.tag       = vtox_tag_q;
    vtox_only_complete.value     = riscv_pkg::FLEN'(xres_q);
    vtox_only_complete.exception = group_bounds_fault_q;
    vtox_only_complete.exc_cause = riscv_pkg::exc_cause_t'(2);
  end

  // --------------------------------------------------------------------------
  // Head MMU & Vector Memory Unit
  // --------------------------------------------------------------------------
  logic desc_launch_valid;
  logic [riscv_pkg::VmtPpnBits-1:0] desc_launch_ppn0, desc_launch_ppn1;
  logic [11:0] desc_launch_page_offset;
  logic [15:0] desc_launch_first_elem, desc_launch_last_elem;
  logic [1:0] desc_launch_eew_log2;
  logic [VLEN-1:0] desc_launch_active_mask;
  logic desc_launch_is_store;
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
      .i_vec_idle               (vec_backend_idle && (xs == X_IDLE)),
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
  assign vmu_cmd_valid = vmem_desc_valid_q && vmu_idle && eng_idle && !issued_q &&
                         !i_fatal_stop && !o_vmu_fatal;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      vmem_desc_valid_q <= 1'b0;
    end else if (i_fatal_stop || o_vmu_fatal) begin
      vmem_desc_valid_q <= 1'b0;
    end else if (desc_launch_valid) begin
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

  assign o_vtox_complete  = vhead_complete.valid ? vhead_complete : vtox_only_complete;
  assign o_vmt_done_valid = zero_vmt_done_valid || vmu_vmt_done_valid;
  assign o_vmt_done_idx   = zero_vmt_done_valid ? zero_vmt_done_idx : vmu_vmt_done_idx;

`ifndef SYNTHESIS
`ifndef FORMAL
  logic x_reset_seen_q = 1'b0;
  always @(posedge i_clk) begin
    if (i_rst) x_reset_seen_q <= 1'b1;
    if (x_reset_seen_q && !i_rst) begin
      assert (!(xs == X_OUT && (i_rob_empty || i_head_tag != vtox_tag_q)))
      else
        $error(
            "vec_unit: vector-to-scalar result presented for tag %0d, head %0d, empty %0b",
            vtox_tag_q,
            i_head_tag,
            i_rob_empty
        );
      assert (!(vhead_complete.valid && vtox_only_complete.valid));
      assert (!(zero_vmt_done_valid && vmu_vmt_done_valid));
      assert ($onehot0({vtox_xr_en, vhead_vrf_read_en, vmu_xr_en}));
      assert (!(fp_read_q && hmmu_rf_read_en));
      assert (!(desc_launch_valid && vmem_desc_valid_q));
    end
  end
`endif
`endif

endmodule
