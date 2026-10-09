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
 * imem_predecode_line: predecode sideband for one cache line.
 *
 * Apply riscv_pkg::imem_make_sideband independently to each 32-bit word,
 * matching the low BRAM's write-time and initialization metadata. Register
 * the result alongside the cache-line fill.
 */
module imem_predecode_line #(
    parameter int unsigned LINE_BYTES = 32
) (
    input logic [LINE_BYTES*8-1:0] i_line,
    output logic [(LINE_BYTES/4)*riscv_pkg::ImemSidebandWidth-1:0] o_sideband
);

  localparam int unsigned WordsPerLine  = LINE_BYTES / 4;
  localparam int unsigned SidebandWidth = riscv_pkg::ImemSidebandWidth;

  for (genvar gw = 0; gw < int'(WordsPerLine); gw++) begin : gen_word_sideband
    assign o_sideband[gw*SidebandWidth+:SidebandWidth] = riscv_pkg::imem_make_sideband(
        i_line[gw*32+:32]
    );
  end

endmodule : imem_predecode_line
