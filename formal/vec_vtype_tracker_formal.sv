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

/* A surviving memory allocation's restart clear cannot become an older CSR value.
 * Inputs are free after an initial reset. Dispatch is quiescent during recovery
 * and a retiring CSR; checkpoints may be restored only after being saved in the
 * current full-flush epoch. A later CSR retirement supersedes earlier prediction.
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
  logic valid, start;
  logic [8:0] vtype;
  logic seen_reset = 1'b0;
  logic owned_q, owned_n;
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
    assume (!(restore && (rst || flush_all || arch_reload)));
    if (restore) assume (ckpt_valid_q[restore_id]);
    owned_n = owned_q;
    if (alloc && (alloc_op == riscv_pkg::VLOAD || alloc_op == riscv_pkg::VSTORE)) owned_n = 1'b1;
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
      p_memory_clear_survives_reload : assert (!owned_q || !start);
      cover (valid && unknown_clear_q && arch_start && !start);
      cover (restore && ckpt_owned_q[restore_id] && !valid);
      cover (owned_q && arch_reload && arch_start);
    end
  end
endmodule
