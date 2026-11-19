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

package predictor_twin_fold_pkg;
  // Fold the same prefix of the full history that the reference predictor hashes.
  function automatic logic [riscv_pkg::TageIndexBits-1:0] history_index(
      input logic [riscv_pkg::TageDirHistBits-1:0] history, input int unsigned table_number);
    logic [riscv_pkg::TageIndexBits-1:0] result;
    int unsigned length;
    case (table_number)
      0: length = riscv_pkg::TageHist1Bits;
      1: length = riscv_pkg::TageHist2Bits;
      2: length = riscv_pkg::TageHist3Bits;
      default: length = riscv_pkg::TageHist4Bits;
    endcase
    result = '0;
    for (int b = 0; b < riscv_pkg::TageDirHistBits; b++)
    if (b < length) result[b%riscv_pkg::TageIndexBits] ^= history[b];
    return result;
  endfunction
endpackage
