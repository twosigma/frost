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

// MEM_RS -> LQ pre-issue slice of tomasulo_wrapper with the ready-pick
// ports. The real merger drives MEM_RS's CDB inputs from the raw lanes and
// early-load token; MEM_RS and the LQ are wired as in the wrapper, including
// the translation-active muxes on the look-ahead tag, candidate tags and
// needs-LQ bit, and the direct data-MMU tag port. Every other input is
// unconstrained. MEM_RS asserts (RS_PRETAG_LOCAL_PROOF) that its look-ahead
// tag is the issue winner's and that the exported ready vectors pick the
// same entries; the LQ asserts (F_LQ_PREMATCH_PAIR) that every ready-pick
// candidate match equals the CAM of the candidate tag the wrapper's mux
// drives, and that the registered selected match equals the registered CAM
// of the wrapper's look-ahead tag qualified by needs-LQ.
module rs_lq_prematch_equiv (
    input logic i_clk
);
  localparam int unsigned W = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned RsDepth = riscv_pkg::MemRsDepth;
  (* anyseq *) riscv_pkg::fu_complete_t early_load;
  (* anyseq *) riscv_pkg::cdb_broadcast_t registered_0, registered_1;
  (* anyseq *) logic enable;
  (* anyseq *) logic translation_active;
  (* anyseq *) logic [W-1:0] dmmu_pre_rob_tag;
  (* anyseq *) logic dmmu_pre_needs_lq;
  riscv_pkg::cdb_broadcast_t merged_0, merged_1;
  mem_wakeup_merge #(
      .FORMAL_STANDALONE_ENV(1'b0)
  ) merger (
      .i_enable(enable),
      .i_load(early_load),
      .i_registered_0(registered_0),
      .i_registered_1(registered_1),
      .o_wakeup_0(merged_0),
      .o_wakeup_1(merged_1),
      .o_injected()
  );

  logic [W-1:0] rs_pre_tag;
  logic [8*W-1:0] rs_pre_tags;
  logic [2:0] rs_pre_sel;
  logic rs_pre_needs_lq;
  logic [8*RsDepth-1:0] rs_pre_ready;
  logic [RsDepth*W-1:0] rs_pre_entry_tags;
  reservation_station #(
      .DEPTH(RsDepth),
      .PREISSUE_VALID_COFACTOR(1'b1),
      .PREISSUE_RAW_WAKEUP(1'b1),
      .PREISSUE_READY_EXPORT(1'b1),
      .HAS_SRC3(1'b0),
      .DISPATCH_REPAIR_BYPASS(1'b0),
      .ISSUE_REPAIR_BYPASS(1'b0),
      .ALLOC_INDEXED_REPAIR(1'b1),
      .SPECULATIVE_DATA_WRITES(1'b1),
      .FORMAL_STANDALONE_ENV(1'b0),
      .TRUST_DISPATCH_VALID(1'b1)
  ) station (
      .i_clk(i_clk),
      .i_cdb(merged_0),
      .i_cdb_2(merged_1),
      .i_issue_cdb_valid(merged_0.valid),
      .i_issue_cdb_tag(merged_0.tag),
      .i_issue_cdb_2_valid(merged_1.valid),
      .i_issue_cdb_2_tag(merged_1.tag),
      .o_pre_issue_rob_tag(rs_pre_tag),
      .o_pre_issue_rob_tags(rs_pre_tags),
      .o_pre_issue_sel(rs_pre_sel),
      .o_pre_issue_ready(rs_pre_ready),
      .o_pre_issue_entry_tags(rs_pre_entry_tags),
      .i_pre_issue_raw_valid({
        enable && early_load.valid && !early_load.exception, registered_1.valid, registered_0.valid
      }),
      .i_pre_issue_raw_tags({early_load.tag, registered_1.tag, registered_0.tag}),
      .o_pre_issue_needs_lq(rs_pre_needs_lq)
  );

  // tomasulo_wrapper's translation muxes.
  wire [W-1:0] pre_tag_final = translation_active ? dmmu_pre_rob_tag : rs_pre_tag;
  wire [8*W-1:0] pre_tags_final = translation_active ? {8{dmmu_pre_rob_tag}} : rs_pre_tags;
  wire pre_needs_lq_final = translation_active ? dmmu_pre_needs_lq : rs_pre_needs_lq;

  load_queue #(
      .PREISSUE_CANDIDATES(1'b1),
      .PREISSUE_SEL_WIDTH(3),
      .PREISSUE_READY_PICK(1'b1),
      .PREISSUE_RS_DEPTH(RsDepth),
      .ENABLE_SQ_FORWARD_FAST_PATH(1'b1)
  ) lq (
      .i_clk(i_clk),
      .i_pre_issue_rob_tag(pre_tag_final),
      .i_pre_issue_rob_tags(pre_tags_final),
      .i_pre_issue_sel(rs_pre_sel),
      .i_pre_issue_needs_lq(pre_needs_lq_final),
      .i_pre_issue_ready(rs_pre_ready),
      .i_pre_issue_entry_tags(rs_pre_entry_tags),
      .i_pre_issue_direct(translation_active),
      .i_pre_issue_direct_tag(dmmu_pre_rob_tag)
  );
endmodule
