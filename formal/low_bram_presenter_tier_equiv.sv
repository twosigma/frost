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

module low_bram_presenter_tier_equiv (
    input logic clk
);
  (* anyseq *) logic rst, hold, claim, redirect, pa_valid, quarantine;
  (* anyseq *) logic [31:0] pc, pa0, pa1;
  (* anyseq *) logic [3:0] faults;
  logic past_valid = 1'b0;
  logic initialized = 1'b0;
  logic high_q;
  wire high = pa0[31];
  wire tier_change = high ^ high_q;
  logic [1:0] response_valid;
  logic [31:0] served_pc[2];
  logic [63:0] data_pair[2];
  logic [3:0] served_faults[2];
  logic [63:0] slow_pair[2];
  logic [1:0] overlay_q;
  logic [31:0] addr0[2], addr1[2];

  always_ff @(posedge clk) begin
    past_valid  <= 1'b1;
    initialized <= past_valid;
    // First reset establishes the presenter state; the second memory edge
    // replaces the arbitrary request launched before that reset. Later reset
    // pulses remain unconstrained.
    if (!initialized) assume (rst);
    if (rst) high_q <= 1'b0;
    else high_q <= high;
  end

  for (genvar variant = 0; variant < 2; variant++) begin : gen_variant
    wire enabled = 1'b1;
    wire [31:0] fetch_pc;
    wire [3:0] fetch_faults;
    wire fetch_valid;
    logic ready_q = 1'b0;
    logic history_valid_q = 1'b0;
    logic [63:0] history_pair_q;
    logic [63:0] read_pair_q;
    wire [63:0] pair_addr = {addr1[variant], addr0[variant]};
    wire overlay = addr0[variant][31:16] == 0 && addr1[variant][31:16] == 0;
    initial overlay_q[variant] = 1'b0;

    low_bram_fetch_presenter #(
        .SEPARATE_ADDRESS_RETARGET(variant != 0)
    ) dut (
        .i_clk(clk),
        .i_rst(rst),
        .i_response_ready(ready_q),
        .i_response_overlay_hit(overlay_q[variant]),
        .i_response_claim(claim),
        .i_publish_hold(hold),
        .i_owner_low(!high),
        .i_retarget(redirect || tier_change),
        .i_address_retarget(redirect),
        .i_pc(pc),
        .i_pa0(pa0),
        .i_pa1(pa1),
        .i_pa_valid(pa_valid),
        .i_fault0(faults[0]),
        .i_fault0_page(faults[1]),
        .i_fault1(faults[2]),
        .i_fault1_page(faults[3]),
        .o_fetch_address(fetch_pc),
        .o_fetch_pa0(addr0[variant]),
        .o_fetch_pa1(addr1[variant]),
        .o_fetch_pa_valid(fetch_valid),
        .o_fetch_fault0(fetch_faults[0]),
        .o_fetch_fault0_page(fetch_faults[1]),
        .o_fetch_fault1(fetch_faults[2]),
        .o_fetch_fault1_page(fetch_faults[3]),
        .o_response_valid(response_valid[variant])
    );

    // Same read/history equations as imem_predecode. Address identities model
    // arbitrary deterministic payload and metadata for each physical pair.
    always_ff @(posedge clk) begin
      if (enabled) begin
        read_pair_q <= pair_addr;
        data_pair[variant] <= pair_addr;
        slow_pair[variant] <= read_pair_q;
        served_pc[variant] <= fetch_pc;
        served_faults[variant] <= fetch_faults;
      end
      if (quarantine) begin
        overlay_q[variant] <= 1'b0;
        ready_q <= 1'b0;
        history_valid_q <= 1'b0;
      end else if (enabled) begin
        overlay_q[variant] <= overlay;
        ready_q <= overlay || (history_valid_q && pair_addr == history_pair_q);
        history_valid_q <= 1'b1;
        history_pair_q <= pair_addr;
      end else history_valid_q <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (initialized && !rst && !high_q && !high) begin
      assert (response_valid[0] == response_valid[1]);
      assert (addr0[0] == addr0[1]);
      assert (addr1[0] == addr1[1]);
      if (response_valid[0]) begin
        assert (served_pc[0] == served_pc[1]);
        assert (served_faults[0] == served_faults[1]);
        assert (data_pair[0] == data_pair[1]);
        assert (overlay_q[0] == overlay_q[1]);
        if (!overlay_q[0]) assert (slow_pair[0] == slow_pair[1]);
      end
    end
  end
endmodule
