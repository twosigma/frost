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

module rob_alloc_lvt_reference #(
    parameter int unsigned HeadMetaWidth = 24,
    localparam int unsigned NextWidth =
        2*riscv_pkg::XLEN + riscv_pkg::RegAddrWidth + riscv_pkg::CheckpointIdWidth + HeadMetaWidth,
    localparam int unsigned HeadWidth = NextWidth + riscv_pkg::XLEN + 15
) (
    input logic i_clk,
    input logic alloc_en,
    alloc_en_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] tail_idx,
    tail_idx_2,
    head_idx,
    head_next_idx,
    input logic [(1 << riscv_pkg::ReorderBufferTagWidth)-1:0] head_clear_mask,
    head_next_clear_mask,
    input riscv_pkg::reorder_buffer_alloc_req_t i_alloc_req,
    i_alloc_req_2,
    input logic [riscv_pkg::CheckpointIdWidth-1:0] alloc_checkpoint_id_data,
    alloc_checkpoint_id_data_2,
    input logic [HeadMetaWidth-1:0] alloc_head_meta_data,
    alloc_head_meta_data_2,
    output logic [HeadWidth-1:0] o_head,
    output logic [NextWidth-1:0] o_next
);
  logic [riscv_pkg::XLEN-1:0] head_pc;
  logic [riscv_pkg::XLEN-1:0] head_next_pc;
  logic [riscv_pkg::XLEN-1:0] head_fallthrough_pc;
  logic [riscv_pkg::XLEN-1:0] head_next_fallthrough_pc;
  logic [riscv_pkg::RegAddrWidth-1:0] head_dest_reg;
  logic [riscv_pkg::RegAddrWidth-1:0] head_next_dest_reg;
  logic [riscv_pkg::CheckpointIdWidth-1:0] head_checkpoint_id;
  logic [riscv_pkg::CheckpointIdWidth-1:0] head_next_checkpoint_id;
  logic [HeadMetaWidth-1:0] head_meta_rd_data;
  logic [HeadMetaWidth-1:0] head_next_meta_rd_data;
  logic [12-1:0] head_csr_addr;
  logic [3-1:0] head_csr_op;
  logic [riscv_pkg::XLEN-1:0] head_csr_write_data;
  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (riscv_pkg::ReorderBufferTagWidth),
      .DATA_WIDTH     (riscv_pkg::XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_reference_pc (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.pc, i_alloc_req.pc}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_pc)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (riscv_pkg::ReorderBufferTagWidth),
      .DATA_WIDTH     (riscv_pkg::XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_reference_pc_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.pc, i_alloc_req.pc}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
      .o_read_data    (head_next_pc)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (riscv_pkg::ReorderBufferTagWidth),
      .DATA_WIDTH     (riscv_pkg::XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_reference_fallthrough_pc (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.link_addr, i_alloc_req.link_addr}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_fallthrough_pc)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (riscv_pkg::ReorderBufferTagWidth),
      .DATA_WIDTH     (riscv_pkg::XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_reference_fallthrough_pc_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.link_addr, i_alloc_req.link_addr}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
      .o_read_data    (head_next_fallthrough_pc)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (riscv_pkg::ReorderBufferTagWidth),
      .DATA_WIDTH     (riscv_pkg::RegAddrWidth),
      .NUM_WRITE_PORTS(2)
  ) u_reference_dest_reg (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.dest_reg, i_alloc_req.dest_reg}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_dest_reg)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (riscv_pkg::ReorderBufferTagWidth),
      .DATA_WIDTH     (riscv_pkg::RegAddrWidth),
      .NUM_WRITE_PORTS(2)
  ) u_reference_dest_reg_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.dest_reg, i_alloc_req.dest_reg}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
      .o_read_data    (head_next_dest_reg)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (riscv_pkg::ReorderBufferTagWidth),
      .DATA_WIDTH     (riscv_pkg::CheckpointIdWidth),
      .NUM_WRITE_PORTS(2)
  ) u_reference_checkpoint_id (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_checkpoint_id_data_2, alloc_checkpoint_id_data}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_checkpoint_id)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (riscv_pkg::ReorderBufferTagWidth),
      .DATA_WIDTH     (riscv_pkg::CheckpointIdWidth),
      .NUM_WRITE_PORTS(2)
  ) u_reference_checkpoint_id_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_checkpoint_id_data_2, alloc_checkpoint_id_data}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
      .o_read_data    (head_next_checkpoint_id)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (riscv_pkg::ReorderBufferTagWidth),
      .DATA_WIDTH     (HeadMetaWidth),
      .NUM_WRITE_PORTS(2)
  ) u_reference_head_meta (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_head_meta_data_2, alloc_head_meta_data}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_meta_rd_data)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (riscv_pkg::ReorderBufferTagWidth),
      .DATA_WIDTH     (HeadMetaWidth),
      .NUM_WRITE_PORTS(2)
  ) u_reference_head_meta_next (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({alloc_head_meta_data_2, alloc_head_meta_data}),
      .i_read_address (head_next_idx),
      .i_read_onehot  (head_next_clear_mask),
      .o_read_data    (head_next_meta_rd_data)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (riscv_pkg::ReorderBufferTagWidth),
      .DATA_WIDTH     (12),
      .NUM_WRITE_PORTS(2)
  ) u_reference_csr_addr (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_addr, i_alloc_req.csr_addr}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_csr_addr)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (riscv_pkg::ReorderBufferTagWidth),
      .DATA_WIDTH     (3),
      .NUM_WRITE_PORTS(2)
  ) u_reference_csr_op (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_op, i_alloc_req.csr_op}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_csr_op)
  );

  mwp_dist_ram_ohread #(
      .ADDR_WIDTH     (riscv_pkg::ReorderBufferTagWidth),
      .DATA_WIDTH     (riscv_pkg::XLEN),
      .NUM_WRITE_PORTS(2)
  ) u_reference_csr_write_data (
      .i_clk,
      .i_write_enable ({alloc_en_2, alloc_en}),
      .i_write_address({tail_idx_2, tail_idx}),
      .i_write_data   ({i_alloc_req_2.csr_write_data, i_alloc_req.csr_write_data}),
      .i_read_address (head_idx),
      .i_read_onehot  (head_clear_mask),
      .o_read_data    (head_csr_write_data)
  );
  assign o_head = {
    head_pc,
    head_fallthrough_pc,
    head_dest_reg,
    head_checkpoint_id,
    head_meta_rd_data,
    head_csr_addr,
    head_csr_op,
    head_csr_write_data
  };
  assign o_next = {
    head_next_pc,
    head_next_fallthrough_pc,
    head_next_dest_reg,
    head_next_checkpoint_id,
    head_next_meta_rd_data
  };
endmodule
