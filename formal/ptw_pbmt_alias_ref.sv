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

module ptw_pbmt_alias_ref #(
    parameter bit ExpectAlias = 1'b1
) (
    input logic [riscv_pkg::XLEN-1:0] i_addr,
    input logic i_io
);
  wire alias_hit = riscv_pkg::pma_pbmt_alias_ok(i_addr);
  if (ExpectAlias) begin : gen_alias
    logic [riscv_pkg::XLEN-1:0] real_addr;
    logic expected;
    always_comb begin
      real_addr = i_addr;
      real_addr[riscv_pkg::PbmtAliasBit] = 1'b0;
      expected = i_addr[riscv_pkg::PbmtAliasBit] && (real_addr >= riscv_pkg::DdrBase) &&
          (real_addr < riscv_pkg::PbmtAliasCoverLimit);
      p_alias_range_exact : assert (riscv_pkg::PbmtAliasEnabled && alias_hit == expected);
    end
  end else begin : gen_no_alias
    localparam int unsigned PageTop = riscv_pkg::PtePpnBits + 11;
    localparam int unsigned DdrBit = 28;  // 256 MiB of aligned DDR.
    wire [riscv_pkg::PtePpnBits-1:0] ppn = i_addr[PageTop:12];
    wire in_ddr = i_addr[PageTop:DdrBit] == riscv_pkg::DdrBase[PageTop:DdrBit];
    wire [1:0] pbmt = i_io ? riscv_pkg::PbmtIo : riscv_pkg::PbmtNc;
    wire same_ppn = riscv_pkg::pbmt_leaf_ppn(ppn, pbmt) == ppn;
    wire access_fault = riscv_pkg::pbmt_leaf_access_fault(ppn, pbmt);
    always_comb begin
      p_no_alias :
      assert (riscv_pkg::DdrCapacityLog2Bytes == DdrBit && !riscv_pkg::PbmtAliasEnabled &&
          !alias_hit && same_ppn && access_fault == in_ddr);
    end
  end
endmodule
