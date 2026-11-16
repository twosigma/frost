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
  The vtype in effect at dispatch ({vill, vtype[7:0]}), for vector
  arithmetic legality. vsetvli and vsetivli set it from their immediates
  (with the vector-config unit's vill rules); vsetvl makes it unknown, and so
  does a full flush. While it is unknown, cpu_ooo holds vector arithmetic at
  dispatch. It becomes known again from the architectural vtype once no
  vector-config instruction has been in the ROB for three cycles (its commit
  update reaches the CSR file two cycles after it leaves the ROB). Branch
  checkpoints save it with the rename state, and a partial flush restores it.
  The same checkpoint holds the nonzero-vstart flag and whether an allocation
  has predicted it clear. A load/store may allocate while vtype is unknown:
  its prediction must survive the delayed architectural reload. CSR retirement
  and full flush discard the prediction so the next reload observes the newer
  CSR value or the surviving architectural state, respectively.
*/
module vec_vtype_tracker #(
    parameter int unsigned VLEN = 256
) (
    input logic i_clk,
    input logic i_rst,
    // Slot-1 allocation (vector-config instructions dispatch in slot 1 only)
    input logic i_alloc,
    input riscv_pkg::instr_op_e i_alloc_op,
    input logic [11:0] i_alloc_imm,  // instruction bits 31:20
    input logic i_ckpt_save,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_ckpt_id,
    input logic i_restore,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] i_restore_id,
    input logic i_flush_all,
    input logic i_vcfg_in_flight,  // registered, from the ROB
    input logic [8:0] i_arch_vtype,  // {vill, vtype[7:0]}
    input logic i_arch_vstart_nonzero,
    input logic i_arch_reload,
    output logic o_vstart_nonzero,
    output logic [8:0] o_vtype,
    output logic o_valid
);

  logic imm_vill;
  logic [7:0] imm_vtype;
  vec_cfg_unit #(
      .VLEN(VLEN)
  ) u_imm (
      .i_op       (i_alloc_op),
      .i_avl      ('0),
      .i_vtype    ('0),
      .i_imm      (i_alloc_imm),
      .i_rs1_field(5'd1),
      .o_vill     (imm_vill),
      .o_vtype    (imm_vtype),
      .o_rs1_x0   (),
      .o_vlmax    (),
      .o_vl       ()
  );

  // The next state is formed twice from registered state and slot 1's
  // decode: once for a cycle without an allocation and once for an
  // allocation of that instruction. The allocation strobe settles late in
  // the dispatch cycle, so it only selects between the two (kept as separate
  // nets) at the registers. A checkpoint is saved only in a cycle in which
  // slot 1 allocates, because bundles dispatch whole (cpu_ooo checks it), so
  // the checkpoint data is the allocation's next state and does not wait for
  // the strobe. A restore never coincides with an allocation (recovery holds
  // dispatch), so it is part of the cycle without one.
  // vtype validity and ownership of the vstart prediction are independent.
  // A pending vtype reload must not undo a younger memory allocation's clear.
  logic [8:0] vt_idle, vt_alloc;
  logic valid_idle, start_idle, valid_alloc, start_alloc;
  logic start_predicted_q, predicted_alloc;
  logic cfg_imm, cfg_reg, clears_start, reload;
  logic [2:0] quiet_q;  // cycles with no vector-config instruction in flight
  assign cfg_imm = (i_alloc_op == riscv_pkg::VSETVLI) || (i_alloc_op == riscv_pkg::VSETIVLI);
  assign cfg_reg = i_alloc_op == riscv_pkg::VSETVL;
  assign clears_start = cfg_imm || cfg_reg || (i_alloc_op == riscv_pkg::VARITH) ||
      (i_alloc_op == riscv_pkg::VARITH_X) || (i_alloc_op == riscv_pkg::VTOX) ||
      (i_alloc_op == riscv_pkg::VLOAD) || (i_alloc_op == riscv_pkg::VSTORE);
  assign reload = !o_valid && (quiet_q == 3'd3) && !i_vcfg_in_flight;
  // Without an allocation: reload the architectural state once it is current
  assign vt_idle = reload ? i_arch_vtype : o_vtype;
  assign valid_idle = o_valid || reload;
  assign start_idle = reload ? (i_arch_vstart_nonzero && !start_predicted_q) : o_vstart_nonzero;
  // With one: vsetvli/vsetivli install their immediate vtype, vsetvl makes it
  // unknown, and every vector instruction predicts vstart clear
  assign vt_alloc = cfg_imm ? {imm_vill, imm_vtype} : cfg_reg ? o_vtype : vt_idle;
  assign valid_alloc = cfg_imm || (!cfg_reg && valid_idle);
  assign start_alloc = !clears_start && start_idle;
  assign predicted_alloc = clears_start || start_predicted_q;

  // {start_predicted, vstart nonzero, valid, vtype}. The CSR dispatch fence
  // excludes allocation during its registered commit; a later CSR access
  // observes drained vector work and supersedes the prediction.
  logic [11:0] ckpt_q[riscv_pkg::NumCheckpoints];
  (* keep = "true" *) logic [11:0] next_idle;
  (* keep = "true" *) logic [11:0] next_alloc;
  assign next_alloc = {
    !i_arch_reload && predicted_alloc, start_alloc, !i_arch_reload && valid_alloc, vt_alloc
  };
  assign next_idle = i_restore ? ckpt_q[i_restore_id] : {
    !i_arch_reload && start_predicted_q, start_idle, !i_arch_reload && valid_idle, vt_idle
  };
  always_ff @(posedge i_clk) begin
    if (i_ckpt_save) ckpt_q[i_ckpt_id] <= next_alloc;
    if (i_rst || i_flush_all) begin
      o_valid <= 1'b0;
      start_predicted_q <= 1'b0;
    end else begin
      {start_predicted_q, o_vstart_nonzero, o_valid, o_vtype} <= i_alloc ? next_alloc : next_idle;
    end
  end

  // Allocation precedes the registered ROB in-flight flag. Restart the quiet
  // interval immediately so a register-form vsetvl cannot reload the old CSR
  // value in that gap.
  (* keep = "true" *) logic [2:0] quiet_idle;
  assign quiet_idle = i_vcfg_in_flight ? 3'd0 : (quiet_q == 3'd3) ? 3'd3 : quiet_q + 3'd1;
  always_ff @(posedge i_clk) begin
    if (i_rst) quiet_q <= '0;
    else quiet_q <= (i_alloc && (cfg_imm || cfg_reg)) ? 3'd0 : quiet_idle;
  end

endmodule
