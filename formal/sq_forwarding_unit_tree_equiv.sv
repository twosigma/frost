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

// Typed interface placeholders replaced in sq_forwarding_unit.sby:tree_equiv
// by the stashed synthesis (fixed-priority newest pick) and formal (linear scan)
// elaborations of sq_forwarding_unit at the core's SqDepth.
module sq_forwarding_unit_shipped (
    input logic i_clk,
    input logic i_rst_n,
    input logic i_flush_all,
    input logic i_sq_check_capture_valid,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_b,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_c,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_d,
    input riscv_pkg::mem_size_e i_sq_check_size,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_sq_check_rob_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,
    input logic i_commit_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag,
    input logic i_commit_valid_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag_2,
    input logic [$clog2(riscv_pkg::SqDepth)-1:0] i_sq_head_idx,
    input logic [riscv_pkg::SqDepth-1:0] sq_valid,
    input logic [riscv_pkg::SqDepth-1:0] sq_addr_valid,
    input logic [riscv_pkg::SqDepth-1:0] sq_data_valid,
    input logic [riscv_pkg::SqDepth-1:0] sq_is_mmio,
    input logic [riscv_pkg::SqDepth-1:0] sq_is_sc,
    input logic [riscv_pkg::SqDepth-1:0] sq_is_zero,
    input logic [riscv_pkg::SqDepth-1:0] sq_is_cmo,
    input logic [riscv_pkg::SqDepth-1:0] sq_committed,
    input logic [(riscv_pkg::SqDepth*riscv_pkg::ReorderBufferTagWidth)-1:0] sq_rob_tag_flat,
    input logic [(riscv_pkg::SqDepth*riscv_pkg::XLEN)-1:0] sq_address_flat,
    input logic [(riscv_pkg::SqDepth*2)-1:0] sq_size_flat,
    input logic [(riscv_pkg::SqDepth*riscv_pkg::FLEN)-1:0] sq_data_fwd_flat,
    output logic o_sq_all_older_addrs_known,
    output riscv_pkg::sq_forward_result_t o_sq_forward
);
  assign o_sq_all_older_addrs_known = 1'b0;
  assign o_sq_forward = '0;
endmodule

module sq_forwarding_unit_formal_sel (
    input logic i_clk,
    input logic i_rst_n,
    input logic i_flush_all,
    input logic i_sq_check_capture_valid,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_b,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_c,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_d,
    input riscv_pkg::mem_size_e i_sq_check_size,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_sq_check_rob_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,
    input logic i_commit_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag,
    input logic i_commit_valid_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag_2,
    input logic [$clog2(riscv_pkg::SqDepth)-1:0] i_sq_head_idx,
    input logic [riscv_pkg::SqDepth-1:0] sq_valid,
    input logic [riscv_pkg::SqDepth-1:0] sq_addr_valid,
    input logic [riscv_pkg::SqDepth-1:0] sq_data_valid,
    input logic [riscv_pkg::SqDepth-1:0] sq_is_mmio,
    input logic [riscv_pkg::SqDepth-1:0] sq_is_sc,
    input logic [riscv_pkg::SqDepth-1:0] sq_is_zero,
    input logic [riscv_pkg::SqDepth-1:0] sq_is_cmo,
    input logic [riscv_pkg::SqDepth-1:0] sq_committed,
    input logic [(riscv_pkg::SqDepth*riscv_pkg::ReorderBufferTagWidth)-1:0] sq_rob_tag_flat,
    input logic [(riscv_pkg::SqDepth*riscv_pkg::XLEN)-1:0] sq_address_flat,
    input logic [(riscv_pkg::SqDepth*2)-1:0] sq_size_flat,
    input logic [(riscv_pkg::SqDepth*riscv_pkg::FLEN)-1:0] sq_data_fwd_flat,
    output logic o_sq_all_older_addrs_known,
    output riscv_pkg::sq_forward_result_t o_sq_forward
);
  assign o_sq_all_older_addrs_known = 1'b0;
  assign o_sq_forward = '0;
endmodule

// Unbounded sequential equivalence miter between the shipped fixed-priority
// newest pick (ifndef FORMAL) and the formal linear selector (ifdef FORMAL) at the
// core's SqDepth geometry across arbitrary unconstrained inputs.
module sq_forwarding_unit_tree_equiv #(
    parameter int unsigned DEPTH = riscv_pkg::SqDepth
) (
    input logic i_clk,
    input logic i_rst_n,
    input logic i_flush_all,
    input logic i_sq_check_capture_valid,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_b,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_c,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_d,
    input riscv_pkg::mem_size_e i_sq_check_size,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_sq_check_rob_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,
    input logic i_commit_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag,
    input logic i_commit_valid_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag_2,
    input logic [$clog2(DEPTH)-1:0] i_sq_head_idx,
    input logic [DEPTH-1:0] sq_valid,
    input logic [DEPTH-1:0] sq_addr_valid,
    input logic [DEPTH-1:0] sq_data_valid,
    input logic [DEPTH-1:0] sq_is_mmio,
    input logic [DEPTH-1:0] sq_is_sc,
    input logic [DEPTH-1:0] sq_is_zero,
    input logic [DEPTH-1:0] sq_is_cmo,
    input logic [DEPTH-1:0] sq_committed,
    input logic [(DEPTH*riscv_pkg::ReorderBufferTagWidth)-1:0] sq_rob_tag_flat,
    input logic [(DEPTH*riscv_pkg::XLEN)-1:0] sq_address_flat,
    input logic [(DEPTH*2)-1:0] sq_size_flat,
    input logic [(DEPTH*riscv_pkg::FLEN)-1:0] sq_data_fwd_flat
);

  logic                          tree_older_known;
  riscv_pkg::sq_forward_result_t tree_fwd;
  logic                          lin_older_known;
  riscv_pkg::sq_forward_result_t lin_fwd;

  sq_forwarding_unit_shipped u_shipped (
      .i_clk                     (i_clk),
      .i_rst_n                   (i_rst_n),
      .i_flush_all               (i_flush_all),
      .i_sq_check_capture_valid  (i_sq_check_capture_valid),
      .i_sq_check_addr           (i_sq_check_addr),
      .i_sq_check_addr_b         (i_sq_check_addr_b),
      .i_sq_check_addr_c         (i_sq_check_addr_c),
      .i_sq_check_addr_d         (i_sq_check_addr_d),
      .i_sq_check_size           (i_sq_check_size),
      .i_sq_check_rob_tag        (i_sq_check_rob_tag),
      .i_rob_head_tag            (i_rob_head_tag),
      .i_commit_valid            (i_commit_valid),
      .i_commit_rob_tag          (i_commit_rob_tag),
      .i_commit_valid_2          (i_commit_valid_2),
      .i_commit_rob_tag_2        (i_commit_rob_tag_2),
      .i_sq_head_idx             (i_sq_head_idx),
      .sq_valid                  (sq_valid),
      .sq_addr_valid             (sq_addr_valid),
      .sq_data_valid             (sq_data_valid),
      .sq_is_mmio                (sq_is_mmio),
      .sq_is_sc                  (sq_is_sc),
      .sq_is_zero                (sq_is_zero),
      .sq_is_cmo                 (sq_is_cmo),
      .sq_committed              (sq_committed),
      .sq_rob_tag_flat           (sq_rob_tag_flat),
      .sq_address_flat           (sq_address_flat),
      .sq_size_flat              (sq_size_flat),
      .sq_data_fwd_flat          (sq_data_fwd_flat),
      .o_sq_all_older_addrs_known(tree_older_known),
      .o_sq_forward              (tree_fwd)
  );

  sq_forwarding_unit_formal_sel u_formal_sel (
      .i_clk                     (i_clk),
      .i_rst_n                   (i_rst_n),
      .i_flush_all               (i_flush_all),
      .i_sq_check_capture_valid  (i_sq_check_capture_valid),
      .i_sq_check_addr           (i_sq_check_addr),
      .i_sq_check_addr_b         (i_sq_check_addr_b),
      .i_sq_check_addr_c         (i_sq_check_addr_c),
      .i_sq_check_addr_d         (i_sq_check_addr_d),
      .i_sq_check_size           (i_sq_check_size),
      .i_sq_check_rob_tag        (i_sq_check_rob_tag),
      .i_rob_head_tag            (i_rob_head_tag),
      .i_commit_valid            (i_commit_valid),
      .i_commit_rob_tag          (i_commit_rob_tag),
      .i_commit_valid_2          (i_commit_valid_2),
      .i_commit_rob_tag_2        (i_commit_rob_tag_2),
      .i_sq_head_idx             (i_sq_head_idx),
      .sq_valid                  (sq_valid),
      .sq_addr_valid             (sq_addr_valid),
      .sq_data_valid             (sq_data_valid),
      .sq_is_mmio                (sq_is_mmio),
      .sq_is_sc                  (sq_is_sc),
      .sq_is_zero                (sq_is_zero),
      .sq_is_cmo                 (sq_is_cmo),
      .sq_committed              (sq_committed),
      .sq_rob_tag_flat           (sq_rob_tag_flat),
      .sq_address_flat           (sq_address_flat),
      .sq_size_flat              (sq_size_flat),
      .sq_data_fwd_flat          (sq_data_fwd_flat),
      .o_sq_all_older_addrs_known(lin_older_known),
      .o_sq_forward              (lin_fwd)
  );

  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;
  always_comb begin
    if (!f_past_valid) assume (!i_rst_n);
  end

  always_comb begin
    if (f_past_valid && i_rst_n) begin
      // Control outputs match unconditionally on every cycle.
      p_tree_older_known_eq : assert (tree_older_known == lin_older_known);
      p_tree_match_eq : assert (tree_fwd.match == lin_fwd.match);
      p_tree_can_forward_eq : assert (tree_fwd.can_forward == lin_fwd.can_forward);

      // Whenever at least one older store conflicts with the load (including every
      // forwardable hit), the selected payload data matches bit-for-bit.
      if (tree_fwd.match || tree_fwd.can_forward) begin
        p_tree_data_eq_on_match : assert (tree_fwd.data == lin_fwd.data);
      end
    end
  end

endmodule
