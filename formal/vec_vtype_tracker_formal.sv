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

/* A surviving allocation's restart clear cannot become an older CSR value, for
 * every vector instruction other than configuration (arithmetic, floating point,
 * vector-to-scalar moves, loads and stores), and the tracked vtype follows its
 * specification in every cycle.
 * Inputs are free after an initial reset. Dispatch is quiescent during recovery
 * and a retiring CSR, and a checkpoint is saved only while slot 1 allocates;
 * checkpoints may be restored only after being saved in the current full-flush
 * epoch. A later CSR retirement supersedes earlier prediction.
 *
 * vtype: reset and full flush make it unknown, and so does a CSR retirement.
 * vsetvli and vsetivli install the vtype of their immediate (vill, with the
 * other bits clear, for a set bit above bit 7, the reserved vlmul or a SEW
 * above LMUL * 64). vsetvl makes it unknown. Any other allocation, or a cycle
 * without one, keeps a known vtype. An unknown vtype is reloaded from the
 * architectural vtype exactly when the last three cycles had no reset and no
 * configuration instruction allocating or in flight, and none is in flight
 * now. A restore returns the {valid, vtype} that its checkpoint's allocation
 * produced; the harness watches one arbitrary checkpoint.
 */
module vec_vtype_tracker_formal (
    input logic i_clk
);
  localparam int unsigned CW = riscv_pkg::CheckpointIdWidth;
  localparam int unsigned NC = riscv_pkg::NumCheckpoints;
  (* anyseq *) logic rst, alloc, save, restore, flush_all, cfg_pending, arch_reload;
  (* anyseq *) riscv_pkg::instr_op_e alloc_op;
  (* anyseq *) logic [11:0] alloc_imm;
  (* anyseq *) logic [CW-1:0] save_id, restore_id;
  (* anyseq *) logic [8:0] arch_type;
  (* anyseq *) logic arch_start;
  (* anyconst *) logic [CW-1:0] watch_id;
  logic valid, start;
  logic [8:0] vtype;
  logic seen_reset = 1'b0;
  logic owned_q, owned_n;
  // The instructions that clear vstart when they retire, other than
  // configuration: each allocation of one predicts vstart clear
  logic clears;
  assign clears = (alloc_op == riscv_pkg::VARITH) || (alloc_op == riscv_pkg::VARITH_X) ||
      (alloc_op == riscv_pkg::VARITH_F) || (alloc_op == riscv_pkg::VARITH_C) ||
      (alloc_op == riscv_pkg::VTOX) ||
      (alloc_op == riscv_pkg::VTOF) || (alloc_op == riscv_pkg::VLOAD) ||
      (alloc_op == riscv_pkg::VSTORE);
  logic [NC-1:0] ckpt_owned_q, ckpt_valid_q;
  logic unknown_clear_q;

  vec_vtype_tracker #(
      .VLEN(256)
  ) dut (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_alloc(alloc),
      .i_alloc_op(alloc_op),
      .i_alloc_imm(alloc_imm),
      .i_ckpt_save(save),
      .i_ckpt_id(save_id),
      .i_restore(restore),
      .i_restore_id(restore_id),
      .i_flush_all(flush_all),
      .i_vcfg_in_flight(cfg_pending),
      .i_arch_vtype(arch_type),
      .i_arch_vstart_nonzero(arch_start),
      .i_arch_reload(arch_reload),
      .o_vstart_nonzero(start),
      .o_vtype(vtype),
      .o_valid(valid)
  );

  always_comb begin
    if (!seen_reset) assume (rst);
    if (rst || flush_all || restore || arch_reload) assume (!alloc);
    if (rst || flush_all || restore) assume (!save);
    if (save) assume (alloc);  // bundles dispatch whole (p_vec_tracker_save_allocates)
    assume (!(restore && (rst || flush_all || arch_reload)));
    if (restore) assume (ckpt_valid_q[restore_id]);
    owned_n = owned_q;
    if (alloc && clears) owned_n = 1'b1;
    if (arch_reload) owned_n = 1'b0;
  end

  always_ff @(posedge i_clk) begin
    if (rst) seen_reset <= 1'b1;
    if (save) ckpt_owned_q[save_id] <= owned_n;
    if (rst || flush_all) begin
      owned_q <= 1'b0;
      ckpt_valid_q <= '0;
      unknown_clear_q <= 1'b0;
    end else begin
      if (save) ckpt_valid_q[save_id] <= 1'b1;
      if (restore) owned_q <= ckpt_owned_q[restore_id];
      else owned_q <= owned_n;
      if (arch_reload || restore) unknown_clear_q <= 1'b0;
      else if (alloc && !valid && (alloc_op == riscv_pkg::VLOAD || alloc_op == riscv_pkg::VSTORE))
        unknown_clear_q <= 1'b1;
    end
    if (seen_reset && !rst) begin
      p_vector_clear_survives_reload : assert (!owned_q || !start);
      cover (valid && unknown_clear_q && arch_start && !start);
      cover (restore && ckpt_owned_q[restore_id] && !valid);
      cover (owned_q && arch_reload && arch_start);
    end
  end

  // ---------------------------------------------------------------------------
  // vtype half
  // ---------------------------------------------------------------------------
  logic imm_op, imm_alloc, reg_alloc, cfg_alloc;
  assign imm_op = (alloc_op == riscv_pkg::VSETVLI) || (alloc_op == riscv_pkg::VSETIVLI);
  assign imm_alloc = alloc && imm_op;
  assign reg_alloc = alloc && (alloc_op == riscv_pkg::VSETVL);
  assign cfg_alloc = imm_alloc || reg_alloc;

  // The immediate's vtype: zimm is instruction bits 30:20 (vsetvli) or 29:20
  // (vsetivli); alloc_imm holds bits 31:20.
  logic [10:0] zimm;
  logic [2:0] zsew, zlmul;
  logic zill;
  logic [8:0] imm_vtype;
  assign zimm = (alloc_op == riscv_pkg::VSETIVLI) ? {1'b0, alloc_imm[9:0]} : alloc_imm[10:0];
  assign zsew = zimm[5:3];
  assign zlmul = zimm[2:0];
  assign zill = (zimm[10:8] != 3'd0) || (zlmul == 3'b100) || (zsew > 3'd3) ||
      ((zlmul == 3'b101) && (zsew > 3'd0)) || ((zlmul == 3'b110) && (zsew > 3'd1)) ||
      ((zlmul == 3'b111) && (zsew > 3'd2));
  assign imm_vtype = zill ? 9'h100 : {1'b0, zimm[7:0]};

  // busy_q[i]: i + 1 cycles ago a reset, a configuration allocation or the
  // in-flight indication. quiet: none in the last three cycles, and no
  // configuration instruction is in flight now.
  logic [2:0] busy_q;
  logic quiet;
  assign quiet = (busy_q == 3'd0) && !cfg_pending;

  // The next {valid, vtype} of an allocation; the vtype matters only when valid
  logic alloc_valid_n;
  logic [8:0] alloc_vtype_n;
  assign alloc_valid_n = imm_op || ((alloc_op != riscv_pkg::VSETVL) && (valid || quiet));
  assign alloc_vtype_n = imm_op ? imm_vtype : valid ? vtype : arch_type;

  // The previous cycle; past_q: it was at or after the first reset
  logic past_q = 1'b0;
  logic valid_q, alloc_q, restore_q, imm_alloc_q, reg_alloc_q, quiet_q;
  logic kept_q, reg_wait_q, cleared_q, watch_restore_q;
  logic [8:0] vtype_q, arch_type_q, imm_vtype_q;
  logic [9:0] watch_ckpt_q;  // {valid, vtype} saved in checkpoint watch_id
  // reg_seen_q: a vsetvl allocated and the vtype has not become known since;
  // reg_wait_q: so in the previous cycle, with no vsetvli/vsetivli or restore
  logic reg_seen_q;
  always_ff @(posedge i_clk) begin
    busy_q <= {busy_q[1:0], rst || cfg_alloc || cfg_pending};
    if (save && (save_id == watch_id)) watch_ckpt_q <= {alloc_valid_n, alloc_vtype_n};
    past_q <= seen_reset || rst;
    valid_q <= valid;
    vtype_q <= vtype;
    arch_type_q <= arch_type;
    imm_vtype_q <= imm_vtype;
    alloc_q <= alloc;
    restore_q <= restore;
    imm_alloc_q <= imm_alloc;
    reg_alloc_q <= reg_alloc;
    quiet_q <= quiet;
    // No reset, flush, restore, CSR retirement or configuration allocation
    kept_q <= !(rst || flush_all || restore || arch_reload || cfg_alloc);
    cleared_q <= rst || flush_all || (arch_reload && !restore);
    watch_restore_q <= restore && (restore_id == watch_id);
    if (rst || flush_all) reg_seen_q <= 1'b0;
    else if (reg_alloc) reg_seen_q <= 1'b1;
    else if (!valid_q && valid) reg_seen_q <= 1'b0;
    reg_wait_q <= reg_seen_q && !valid && !imm_alloc && !restore;
  end

  always_comb begin
    if (past_q) begin
      if (valid_q && !alloc_q && !restore_q && valid)
        p_known_vtype_stable : assert (vtype == vtype_q);
      if (valid_q && kept_q) p_known_vtype_kept : assert (valid && (vtype == vtype_q));
      if (imm_alloc_q) p_imm_config_installs_vtype : assert (valid && (vtype == imm_vtype_q));
      if (reg_alloc_q) p_reg_config_makes_vtype_unknown : assert (!valid);
      if (cleared_q) p_vtype_unknown_after_flush_or_csr : assert (!valid);
      if (!valid_q && valid && !imm_alloc_q && !restore_q)
        p_vtype_reloads_quiet_csr : assert (quiet_q && (vtype == arch_type_q));
      if (!valid_q && quiet_q && kept_q)
        p_vtype_reloads_when_quiet : assert (valid && (vtype == arch_type_q));
      if (watch_restore_q)
        p_vtype_restores_checkpoint :
        assert ((valid == watch_ckpt_q[9]) && (!valid || (vtype == watch_ckpt_q[8:0])));
      c_vtype_stable : cover (valid_q && !alloc_q && !restore_q && valid);
      c_imm_legal : cover (imm_alloc_q && valid && !vtype[8]);
      c_imm_vill : cover (imm_alloc_q && valid && vtype[8]);
      c_reg_config_reload : cover (reg_wait_q && valid && (vtype != vtype_q));
      c_restore_known : cover (watch_restore_q && !valid_q && valid);
    end
  end
endmodule
