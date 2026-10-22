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


// Preserve the priority tree before the file's late claim/write selection.
(* keep_hierarchy = "yes" *)
module imsic_priority #(
    parameter int unsigned NUM_IDS = 63
) (
    input logic [NUM_IDS:0] i_candidates,
    output logic [$clog2(NUM_IDS+1)-1:0] o_top,
    output logic [NUM_IDS:0] o_onehot
);
  localparam int unsigned NumBits   = NUM_IDS + 1;
  localparam int unsigned NumWords  = NumBits / 64;
  localparam int unsigned NumGroups = NumBits / 8;
  (* keep = "true" *)logic [NumGroups-1:0] group_any;
  (* keep = "true" *)logic [ NumWords-1:0] word_any;
  for (genvar w = 0; w < int'(NumWords); w++) begin : gen_word
    assign word_any[w] = |group_any[8*w+:8];
  end
  for (genvar g = 0; g < int'(NumGroups); g++) begin : gen_group
    localparam int Word  = g / 8;
    localparam int Group = g % 8;
    (* keep = "true" *) logic earlier_word, earlier_group;
    assign group_any[g] = |i_candidates[8*g+:8];
    if (Word == 0) assign earlier_word = 1'b0;
    else assign earlier_word = |word_any[Word-1:0];
    if (Group == 0) assign earlier_group = 1'b0;
    else assign earlier_group = |group_any[8*Word+:Group];
    for (genvar b = 0; b < 8; b++) begin : gen_bit
      logic earlier_bit;
      if (b == 0) assign earlier_bit = 1'b0;
      else assign earlier_bit = |i_candidates[8*g+:b];
      assign o_onehot[8*g+b] = i_candidates[8*g+b] &&
          !earlier_bit && !earlier_group && !earlier_word;
    end
  end
  for (genvar b = 0; b < $clog2(NumBits); b++) begin : gen_encode
    logic [NumBits-1:0] selected;
    for (genvar i = 0; i < int'(NumBits); i++) begin : gen_identity
      assign selected[i] = ((i >> b) & 1) != 0 && o_onehot[i];
    end
    assign o_top[b] = |selected;
  end
endmodule : imsic_priority
