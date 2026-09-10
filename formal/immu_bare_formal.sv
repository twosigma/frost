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

// Exhaustive public Bare-bypass equivalence with arbitrary address bits.
// The width variants check only Bare behavior and package input conversion;
// they do not claim support for translated Sv39 operation at those widths.
module immu_bare_formal #(
    parameter int unsigned XLEN = riscv_pkg::XLEN
) (
    input logic [XLEN-1:0] pc
);
  logic [31:0] pa0, pa1;
  logic pa_valid, fault0, fault1, page0, page1, line_after_ok;
  logic [riscv_pkg::XLEN-1:0] package_pc;
  riscv_pkg::fetch_verdict_t reference_verdict;
  assign package_pc = riscv_pkg::XLEN'(pc);
  assign reference_verdict = riscv_pkg::fetch_verdict(package_pc);

  immu #(
      .XLEN(XLEN)
  ) dut (
      .i_clk(1'b0),
      .i_rst(1'b0),
      .i_active(1'b0),
      .i_priv_u(1'b0),
      .i_tlb_invalidate(1'b0),
      .i_pc(pc),
      .o_pa0(pa0),
      .o_pa1(pa1),
      .o_pa_valid(pa_valid),
      .o_fault0(fault0),
      .o_fault0_page(page0),
      .o_fault1(fault1),
      .o_fault1_page(page1),
      .o_line_after_ok(line_after_ok),
      .i_walk_req_ready(1'b0),
      .i_walk_resp_valid(1'b0),
      .i_walk_resp('0)
  );

  always_comb begin
    p_bare_pa0_matches_original : assert (pa0 == pc[31:0]);
    p_bare_pa1_matches_original : assert (pa1 == {pc[31:2] + 30'd1, 2'b00});
    p_bare_fault0_matches_original : assert (fault0 == reference_verdict.bare_fault0);
    p_bare_fault1_matches_original : assert (fault1 == reference_verdict.bare_fault1);
    p_bare_flags_match_original : assert (pa_valid && !page0 && !page1 && line_after_ok);
  end
endmodule
