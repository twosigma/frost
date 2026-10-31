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

// Every assertion belongs to one of four partitions. All partitions must pass.
// The history assumption records only the preceding cycle, with an initially
// true value. A first assertion failure therefore satisfies every history
// assumption and is checked by the partition that owns that assertion.
// Cell names come from the same frozen DUT in every partition.
(* techmap_celltype = "$assert" *)
module axi_coherent_bridge_assert (
    input logic A,
    input logic EN
);
  parameter logic [1023:0] _TECHMAP_CELLNAME_ = "";
  function automatic integer unsigned group_number;
    integer unsigned hash_value;
    hash_value = 0;
    for (integer k = 0; k < $bits(_TECHMAP_CELLNAME_) / 8; k = k + 1)
      hash_value = (hash_value * 33) ^ _TECHMAP_CELLNAME_[8*k+:8];
    group_number = hash_value % 4;
  endfunction
  localparam integer unsigned Group = group_number();
  wire [8*32-1:0] _TECHMAP_DO_ = "proc; chformal -lower;";
  logic prior_ok = 1'b1;
  always @($global_clock) prior_ok <= !EN || A;
  always_comb assume (prior_ok);
  if (Group == `AXI_COHERENT_PARTITION) begin : g_check
    always_comb if (EN) assert (A);
  end
endmodule
