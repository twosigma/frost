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

// The selected partition checks each original predicate and enable. Every
// partition assumes the preceding cycle's result for every assertion. History
// starts true, so a first failure satisfies all history assumptions and reaches
// its owning partition. All partitions must pass.
(* techmap_celltype = "axi_coherent_bridge_checked_assert" *)
module axi_coherent_bridge_assert (
    input logic A,
    input logic EN
);
  // The bridge's mapped assertion names contain this file's source location.
  // Keep its checked predicate at line 32 to preserve every assertion identity.
  logic prior_ok = 1'b1;
  always @($global_clock) prior_ok <= !EN || A;
  always_comb assume (prior_ok);

  always_comb if (EN) assert (A);
endmodule

(* techmap_celltype = "$assert" *)
module axi_coherent_bridge_assert_history (
    input logic A,
    input logic EN
);
  logic prior_ok = 1'b1;
  always @($global_clock) prior_ok <= !EN || A;
  always_comb assume (prior_ok);
endmodule

// Both fixed maps are reachable from this top before their processes are
// lowered. Mapping then uses them without deriving a fresh specialization.
module axi_coherent_bridge_assert_maps (
    input logic A,
    input logic EN
);
  axi_coherent_bridge_assert_history history (
      .A,
      .EN
  );
  axi_coherent_bridge_assert checked_map (
      .A,
      .EN
  );
endmodule
