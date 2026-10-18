// Copyright (c) 2026 John Goodacre.
// SPDX-License-Identifier: Apache-2.0
// Directed PTW root-pointer/PTE-address boundary check.
module test_ptw_high_addr;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst = 1'b1;
  logic [riscv_pkg::PtePpnBits-1:0] root_ppn;
  logic req_valid;
  logic [riscv_pkg::Sv39VpnBits-1:0] req_vpn;
  logic req_ready, resp_valid;
  riscv_pkg::ptw_resp_t resp;
  logic line_valid;
  logic [riscv_pkg::PhysAddrBits-1:0] line_addr;

  ptw u_ptw (
      .i_clk(clk),
      .i_rst(rst),
      .i_root_ppn(root_ppn),
      .i_req_valid(req_valid),
      .o_req_ready(req_ready),
      .i_req_vpn(req_vpn),
      .i_discard(1'b0),
      .o_resp_valid(resp_valid),
      .o_resp(resp),
      .o_line_req_valid(line_valid),
      .i_line_req_ready(1'b0),
      .o_line_req_addr(line_addr),
      .o_line_req_id(),
      .i_line_resp_valid(1'b0),
      .i_line_resp_id('0),
      .i_line_resp_rdata('0)
  );

  initial begin
    logic [63:0] table_base;
    req_valid = 1'b0;
    req_vpn = riscv_pkg::Sv39VpnBits'(9'h12) << 18;
    table_base = riscv_pkg::DdrBase + 64'h2000;
    if (riscv_pkg::DdrCapacityLog2Bytes >= 33) table_base += 64'h1_0000_0000;
    root_ppn = riscv_pkg::PtePpnBits'(table_base >> 12);
    repeat (2) @(negedge clk);
    rst = 1'b0;
    req_valid = 1'b1;
    @(negedge clk);
    assert (line_valid && line_addr == riscv_pkg::PhysAddrBits'(table_base + 64'h80))
    else
      $fatal(1, "high PTE address truncated or refused: valid=%b addr=%h", line_valid, line_addr);

    // Reset the held read, then request a table starting exactly at the
    // excluded end of the configured DDR aperture. No read may be issued.
    rst = 1'b1;
    req_valid = 1'b0;
    root_ppn = riscv_pkg::PtePpnBits'(riscv_pkg::DdrLimit >> 12);
    @(negedge clk);
    rst = 1'b0;
    req_valid = 1'b1;
    @(negedge clk);
    req_valid = 1'b0;
    assert (!line_valid)
    else $fatal(1, "out-of-range PTE line issued");
    @(negedge clk);
    assert (resp_valid && resp.fault_kind == riscv_pkg::DFAULT_ACCESS && !line_valid)
    else $fatal(1, "out-of-range root did not access-fault");
    $finish;
  end
endmodule
