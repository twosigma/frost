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
 * Equivalence proof for the nic_reset_ctrl split: compares the structural
 * composition of nic_core_reset_ctrl and nic_mac_reset_ctrl against a direct
 * monolithic reference of the core RESET FSM and per-domain handshake.
 */
module nic_reset_split_equiv (
    input logic       i_clk,
    input logic       i_rst,
    input logic       i_reset_req,
    input logic       i_dma_idle,
    input logic [1:0] i_clk_ok,
    input logic [1:0] i_in_reset,
    input logic [1:0] i_applied_gen,
    input logic [1:0] i_applied_valid
);
  logic dut_stop_dma, dut_core_rst, dut_core_rst_next, dut_busy;
  logic [1:0] dut_req, dut_gen, dut_core_rst_dom, dut_ready;

  nic_reset_ctrl u_dut (
      .i_clk          (i_clk),
      .i_rst          (i_rst),
      .i_reset_req    (i_reset_req),
      .i_dma_idle     (i_dma_idle),
      .o_stop_dma     (dut_stop_dma),
      .o_core_rst     (dut_core_rst),
      .o_core_rst_next(dut_core_rst_next),
      .o_busy         (dut_busy),
      .i_clk_ok       (i_clk_ok),
      .i_in_reset     (i_in_reset),
      .i_applied_gen  (i_applied_gen),
      .i_applied_valid(i_applied_valid),
      .o_req          (dut_req),
      .o_gen          (dut_gen),
      .o_core_rst_dom (dut_core_rst_dom),
      .o_ready        (dut_ready)
  );

  // Direct monolithic reference implementation.
  localparam int unsigned CoreRstCycles = 4;
  typedef enum logic [1:0] {
    S_IDLE,
    S_DRAIN,
    S_RESET
  } state_e;
  state_e ref_state_q;
  logic [2:0] ref_cnt_q;
  logic ref_pending_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ref_state_q   <= S_DRAIN;
      ref_cnt_q     <= '0;
      ref_pending_q <= 1'b0;
    end else begin
      if (i_reset_req) ref_pending_q <= 1'b1;
      unique case (ref_state_q)
        S_IDLE: begin
          if (ref_pending_q || i_reset_req) begin
            ref_state_q   <= S_DRAIN;
            ref_pending_q <= 1'b0;
          end
        end
        S_DRAIN: begin
          ref_pending_q <= 1'b0;
          if (i_dma_idle) begin
            ref_state_q <= S_RESET;
            ref_cnt_q   <= '0;
          end
        end
        S_RESET: begin
          ref_cnt_q <= ref_cnt_q + 1'b1;
          if (ref_cnt_q == 3'(CoreRstCycles - 1)) ref_state_q <= S_IDLE;
        end
        default: ref_state_q <= S_IDLE;
      endcase
    end
  end
  wire ref_stop_dma = (ref_state_q != S_IDLE);
  wire ref_core_rst = (ref_state_q == S_RESET);
  wire ref_busy = (ref_state_q != S_IDLE);
  wire ref_core_rst_next = !i_rst &&
      ((ref_state_q == S_DRAIN && i_dma_idle) ||
       (ref_state_q == S_RESET && ref_cnt_q != 3'(CoreRstCycles - 1)));
  wire ref_start = (ref_state_q == S_RESET) && (ref_cnt_q == '0);

  logic [1:0] ref_req, ref_gen, ref_core_rst_dom, ref_ready;
  for (genvar d = 0; d < 2; d++) begin : gen_ref
    logic [2:0] sync_s0_q, sync_s1_q;
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        sync_s0_q <= 3'b001;
        sync_s1_q <= 3'b001;
      end else begin
        sync_s0_q <= {i_applied_valid[d], i_applied_gen[d], i_in_reset[d]};
        sync_s1_q <= sync_s0_q;
      end
    end
    wire applied_valid_s = sync_s1_q[2];
    wire applied_s = sync_s1_q[1];
    wire in_reset_s = sync_s1_q[0];

    typedef enum logic [1:0] {
      D_IDLE,
      D_REQUEST,
      D_RELEASE
    } dstate_e;
    dstate_e dstate_q;
    logic gen_q, req_q, clk_ok_q;
    wire clk_lost = clk_ok_q && !i_clk_ok[d];
    always_ff @(posedge i_clk) begin
      if (i_rst) begin
        dstate_q <= D_IDLE;
        gen_q    <= 1'b0;
        req_q    <= 1'b0;
        clk_ok_q <= 1'b0;
      end else begin
        clk_ok_q <= i_clk_ok[d];
        unique case (dstate_q)
          D_IDLE: begin
            if (ref_start || clk_lost) begin
              gen_q    <= ~gen_q;
              req_q    <= 1'b1;
              dstate_q <= D_REQUEST;
            end
          end
          D_REQUEST: begin
            if (i_clk_ok[d] && applied_valid_s && (applied_s == gen_q)) begin
              req_q    <= 1'b0;
              dstate_q <= D_RELEASE;
            end
          end
          D_RELEASE: begin
            if (!in_reset_s) dstate_q <= D_IDLE;
            if (ref_start || clk_lost) begin
              gen_q    <= ~gen_q;
              req_q    <= 1'b1;
              dstate_q <= D_REQUEST;
            end
          end
          default: dstate_q <= D_IDLE;
        endcase
      end
    end
    assign ref_req[d] = req_q;
    assign ref_gen[d] = gen_q;
    assign ref_ready[d] = (dstate_q == D_IDLE) && applied_valid_s && (applied_s == gen_q) &&
        !in_reset_s && i_clk_ok[d];
    assign ref_core_rst_dom[d] = !ref_ready[d];
  end

`ifdef FORMAL
  logic f_past_valid = 1'b0;
  logic f_core_rst_next_q = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    f_core_rst_next_q <= dut_core_rst_next;
    if (!f_past_valid) assume (i_rst);
  end

  // Inductive invariant tying the split and monolithic state elements.
  always_comb begin
    if (f_past_valid) begin
      assert (dut_core_rst == f_core_rst_next_q);
      assert (dut_stop_dma == ref_stop_dma);
      assert (dut_core_rst == ref_core_rst);
      assert (dut_core_rst_next == ref_core_rst_next);
      assert (dut_busy == ref_busy);
      assert (dut_req == ref_req);
      assert (dut_gen == ref_gen);
      assert (dut_core_rst_dom == ref_core_rst_dom);
      assert (dut_ready == ref_ready);
      assert (u_dut.u_core.state_q == ref_state_q);
      assert (u_dut.u_core.rst_cnt_q == ref_cnt_q);
      assert (u_dut.u_core.req_pending_q == ref_pending_q);
      assert (u_dut.u_mac.gen_domain[0].dstate_q == gen_ref[0].dstate_q);
      assert (u_dut.u_mac.gen_domain[1].dstate_q == gen_ref[1].dstate_q);
      assert (u_dut.u_mac.gen_domain[0].gen_q == gen_ref[0].gen_q);
      assert (u_dut.u_mac.gen_domain[1].gen_q == gen_ref[1].gen_q);
      assert (u_dut.u_mac.gen_domain[0].req_q == gen_ref[0].req_q);
      assert (u_dut.u_mac.gen_domain[1].req_q == gen_ref[1].req_q);
      assert (u_dut.u_mac.gen_domain[0].clk_ok_q == gen_ref[0].clk_ok_q);
      assert (u_dut.u_mac.gen_domain[1].clk_ok_q == gen_ref[1].clk_ok_q);
      assert (u_dut.u_mac.gen_domain[0].sync_far.stage_q[0] == gen_ref[0].sync_s0_q);
      assert (u_dut.u_mac.gen_domain[0].sync_far.stage_q[1] == gen_ref[0].sync_s1_q);
      assert (u_dut.u_mac.gen_domain[1].sync_far.stage_q[0] == gen_ref[1].sync_s0_q);
      assert (u_dut.u_mac.gen_domain[1].sync_far.stage_q[1] == gen_ref[1].sync_s1_q);
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst) begin
      cover (dut_core_rst && (dut_req == 2'b11));
      cover (dut_ready == 2'b11);
      cover ((dut_ready == 2'b01) && (dut_req == 2'b10));
    end
  end
`endif
endmodule : nic_reset_split_equiv
