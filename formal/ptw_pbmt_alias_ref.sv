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

module ptw_pbmt_alias_ref (
    input logic [riscv_pkg::XLEN-1:0] i_addr
);
  logic [riscv_pkg::XLEN-1:0] real_addr;
  logic expected;
  always_comb begin
    real_addr = i_addr;
    real_addr[riscv_pkg::PbmtAliasBit] = 1'b0;
    expected = riscv_pkg::PbmtAliasEnabled && i_addr[riscv_pkg::PbmtAliasBit] &&
        (real_addr >= riscv_pkg::DdrBase) && (real_addr < riscv_pkg::PbmtAliasCoverLimit);
    p_alias_range_exact : assert (riscv_pkg::pma_pbmt_alias_ok(i_addr) == expected);
  end
endmodule
