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
 * immu_test_harness: standalone instruction-MMU seam for cocotb.
 *
 * The harness owns the upstream PC register so a test drives the same edge
 * relationship as pc_controller: i_pc_d is sampled only when
 * i_pc_update_en is asserted, and immu sees the resulting registered o_pc.
 * The load enable stays outside immu because the IMMU visibility boundary is
 * exact registered-PC tagging, not advance control. Keeping that register in
 * the harness makes translated retag bubbles and same-edge retarget races
 * visible instead of letting a testbench change the lookup key between edges.
 *
 * The package-typed walker response is flattened at this boundary because
 * cocotb cannot portably drive fields of a SystemVerilog packed struct.
 */
module immu_test_harness #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned NUM_ENTRIES = 8
) (
    input logic i_clk,
    input logic i_rst,

    input logic i_active,
    input logic i_priv_u,
    input logic i_tlb_invalidate,

    input logic i_pc_update_en,
    input logic [XLEN-1:0] i_pc_d,
    output logic [XLEN-1:0] o_pc,

    output logic [31:0] o_pa0,
    output logic [31:0] o_pa1,
    output logic o_pa_valid,
    output logic o_fault0,
    output logic o_fault0_page,
    output logic o_fault1,
    output logic o_fault1_page,
    output logic o_line_after_ok,

    output logic o_walk_req_valid,
    input logic i_walk_req_ready,
    output logic [riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,

    input logic i_walk_resp_valid,
    input logic [1:0] i_walk_resp_fault_kind,
    input logic [riscv_pkg::Sv39VpnBits-1:0] i_walk_resp_vpn,
    input logic [riscv_pkg::PtePpnBits-1:0] i_walk_resp_ppn,
    input logic [1:0] i_walk_resp_level,
    input logic i_walk_resp_perm_r,
    input logic i_walk_resp_perm_w,
    input logic i_walk_resp_perm_x,
    input logic i_walk_resp_perm_u,
    input logic i_walk_resp_perm_d
);

  logic [XLEN-1:0] pc_q;
  riscv_pkg::ptw_resp_t walk_resp;

  always_ff @(posedge i_clk) begin
    if (i_rst) pc_q <= '0;
    else if (i_pc_update_en) pc_q <= i_pc_d;
  end

  assign o_pc = pc_q;

  always_comb begin
    walk_resp = '0;
    walk_resp.fault_kind = riscv_pkg::data_fault_kind_e'(i_walk_resp_fault_kind);
    walk_resp.vpn = i_walk_resp_vpn;
    walk_resp.ppn = i_walk_resp_ppn;
    walk_resp.level = i_walk_resp_level;
    walk_resp.perm_r = i_walk_resp_perm_r;
    walk_resp.perm_w = i_walk_resp_perm_w;
    walk_resp.perm_x = i_walk_resp_perm_x;
    walk_resp.perm_u = i_walk_resp_perm_u;
    walk_resp.perm_d = i_walk_resp_perm_d;
  end

  immu #(
      .XLEN(XLEN),
      .NUM_ENTRIES(NUM_ENTRIES)
  ) u_immu (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_active(i_active),
      .i_priv_u(i_priv_u),
      .i_tlb_invalidate(i_tlb_invalidate),
      .i_pc(pc_q),
      .o_pa0(o_pa0),
      .o_pa1(o_pa1),
      .o_pa_valid(o_pa_valid),
      .o_fault0(o_fault0),
      .o_fault0_page(o_fault0_page),
      .o_fault1(o_fault1),
      .o_fault1_page(o_fault1_page),
      .o_line_after_ok(o_line_after_ok),
      .o_walk_req_valid(o_walk_req_valid),
      .i_walk_req_ready(i_walk_req_ready),
      .o_walk_vpn(o_walk_vpn),
      .i_walk_resp_valid(i_walk_resp_valid),
      .i_walk_resp(walk_resp)
  );

endmodule : immu_test_harness
