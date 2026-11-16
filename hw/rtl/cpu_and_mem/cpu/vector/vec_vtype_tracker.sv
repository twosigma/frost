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
  The same checkpoint holds the nonzero-vstart flag. Every vector allocation
  clears that flag for younger instructions; CSR retirement invalidates the
  tracked state so the architectural vstart is read after its CSR update.
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

  // Allocation precedes the registered ROB in-flight flag. Restart the quiet
  // interval immediately so a register-form vsetvl cannot reload the old CSR
  // value in that gap.
  logic [2:0] quiet_q;  // cycles with no vector-config instruction in flight
  always_ff @(posedge i_clk) begin
    if (i_rst || i_vcfg_in_flight ||
        (i_alloc && (i_alloc_op == riscv_pkg::VSETVL || i_alloc_op == riscv_pkg::VSETVLI ||
                     i_alloc_op == riscv_pkg::VSETIVLI)))
      quiet_q <= '0;
    else if (quiet_q != 3'd3) quiet_q <= quiet_q + 3'd1;
  end

  logic [8:0] vt_n;
  logic valid_n, start_n;
  always_comb begin
    vt_n = o_vtype;
    valid_n = o_valid;
    start_n = o_vstart_nonzero;
    if (i_alloc && (i_alloc_op == riscv_pkg::VSETVLI || i_alloc_op == riscv_pkg::VSETIVLI)) begin
      start_n = 1'b0;
      vt_n = {imm_vill, imm_vtype};
      valid_n = 1'b1;
    end else if (i_alloc && i_alloc_op == riscv_pkg::VSETVL) begin
      start_n = 1'b0;
      valid_n = 1'b0;
    end else if (!o_valid && quiet_q == 3'd3 && !i_vcfg_in_flight) begin
      start_n = i_arch_vstart_nonzero;
      vt_n = i_arch_vtype;
      valid_n = 1'b1;
    end
    if (i_alloc && (i_alloc_op == riscv_pkg::VARITH || i_alloc_op == riscv_pkg::VARITH_X ||
                    i_alloc_op == riscv_pkg::VTOX))
      start_n = 1'b0;
    if (i_arch_reload) valid_n = 1'b0;
  end

  logic [10:0] ckpt_q[riscv_pkg::NumCheckpoints];
  always_ff @(posedge i_clk) begin
    if (i_ckpt_save) ckpt_q[i_ckpt_id] <= {start_n, valid_n, vt_n};
    if (i_rst || i_flush_all) begin
      o_valid <= 1'b0;
    end else if (i_restore) begin
      {o_vstart_nonzero, o_valid, o_vtype} <= ckpt_q[i_restore_id];
    end else begin
      o_vstart_nonzero <= start_n;
      o_valid <= valid_n;
      o_vtype <= vt_n;
    end
  end

endmodule
