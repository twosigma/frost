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
 * nic_reset_test_harness: cocotb top for the NIC's reset handshake and the
 * clock-crossing library under it.
 *
 * Three clocks: the core clock and the two MAC clocks. The bench drives the
 * clock-ok levels, the RESET request and the DMA-idle answer, pushes words
 * through a core-to-TX and an RX-to-core async_fifo, pulses events into an
 * RX-to-core cdc_gray_count, and watches the controller's busy/ready
 * outputs and the domains' resets. Each domain's FIFO half is reset by that
 * domain's reset; the core-side halves by the controller's per-domain hold.
 */
module nic_reset_test_harness #(
    parameter int unsigned DATA_WIDTH = 16,
    parameter int unsigned DEPTH = 16
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_tx_clk,
    input logic i_rx_clk,
    input logic i_tx_clk_ok,
    input logic i_rx_clk_ok,
    input logic i_reset_req,
    input logic i_dma_idle,

    output logic o_stop_dma,
    output logic o_core_rst,
    output logic o_busy,
    output logic o_tx_ready,
    output logic o_rx_ready,
    output logic o_tx_domain_rst,
    output logic o_rx_domain_rst,
    output logic o_tx_core_rst,
    output logic o_rx_core_rst,
    output logic o_tx_req,
    output logic o_rx_req,
    output logic o_tx_gen,
    output logic o_rx_gen,
    output logic o_tx_applied,
    output logic o_rx_applied,

    // Core -> TX packet FIFO.
    input  logic [DATA_WIDTH-1:0] i_c2t_data,
    input  logic                  i_c2t_valid,
    output logic                  o_c2t_ready,
    output logic [DATA_WIDTH-1:0] o_t_data,
    output logic                  o_t_valid,
    input  logic                  i_t_ready,
    // RX -> core packet FIFO.
    input  logic [DATA_WIDTH-1:0] i_r_data,
    input  logic                  i_r_valid,
    output logic                  o_r_ready,
    output logic [DATA_WIDTH-1:0] o_c_data,
    output logic                  o_c_valid,
    input  logic                  i_c_ready,
    // RX -> core event counter.
    input  logic                  i_r_event,
    output logic [          63:0] o_c_total
);
  logic [1:0] in_reset, applied, applied_valid, req, gen, core_rst_dom, ready;

  nic_reset_ctrl ctrl (
      .i_clk          (i_clk),
      .i_rst          (i_rst),
      .i_reset_req    (i_reset_req),
      .i_dma_idle     (i_dma_idle),
      .o_stop_dma     (o_stop_dma),
      .o_core_rst     (o_core_rst),
      .o_busy         (o_busy),
      .i_clk_ok       ({i_rx_clk_ok, i_tx_clk_ok}),
      .i_in_reset     (in_reset),
      .i_applied_gen  (applied),
      .i_applied_valid(applied_valid),
      .o_req          (req),
      .o_gen          (gen),
      .o_core_rst_dom (core_rst_dom),
      .o_ready        (ready)
  );
  assign o_tx_ready    = ready[0];
  assign o_rx_ready    = ready[1];
  assign o_tx_core_rst = core_rst_dom[0];
  assign o_rx_core_rst = core_rst_dom[1];
  assign o_tx_req      = req[0];
  assign o_rx_req      = req[1];
  assign o_tx_gen      = gen[0];
  assign o_rx_gen      = gen[1];
  assign o_tx_applied  = applied[0];
  assign o_rx_applied  = applied[1];

  nic_domain_reset tx_domain (
      .i_clk           (i_tx_clk),
      .i_core_rst_async(i_rst),
      .i_req_async     (req[0]),
      .i_gen_async     (gen[0]),
      .o_domain_rst    (o_tx_domain_rst),
      .o_in_reset      (in_reset[0]),
      .o_applied_gen   (applied[0]),
      .o_applied_valid (applied_valid[0])
  );
  nic_domain_reset rx_domain (
      .i_clk           (i_rx_clk),
      .i_core_rst_async(i_rst),
      .i_req_async     (req[1]),
      .i_gen_async     (gen[1]),
      .o_domain_rst    (o_rx_domain_rst),
      .o_in_reset      (in_reset[1]),
      .o_applied_gen   (applied[1]),
      .o_applied_valid (applied_valid[1])
  );

  async_fifo #(
      .DATA_WIDTH(DATA_WIDTH),
      .DEPTH(DEPTH)
  ) c2t (
      .i_clk  (i_clk),
      .i_rst  (i_rst || core_rst_dom[0]),
      .i_data (i_c2t_data),
      .i_valid(i_c2t_valid),
      .o_ready(o_c2t_ready),
      .o_clk  (i_tx_clk),
      .o_rst  (o_tx_domain_rst),
      .o_data (o_t_data),
      .o_valid(o_t_valid),
      .i_ready(i_t_ready)
  );
  async_fifo #(
      .DATA_WIDTH(DATA_WIDTH),
      .DEPTH(DEPTH)
  ) r2c (
      .i_clk  (i_rx_clk),
      .i_rst  (o_rx_domain_rst),
      .i_data (i_r_data),
      .i_valid(i_r_valid),
      .o_ready(o_r_ready),
      .o_clk  (i_clk),
      .o_rst  (i_rst || core_rst_dom[1]),
      .o_data (o_c_data),
      .o_valid(o_c_valid),
      .i_ready(i_c_ready)
  );
  cdc_gray_count events (
      .i_src_clk   (i_rx_clk),
      .i_src_rst   (o_rx_domain_rst),
      .i_src_event (i_r_event),
      .i_dst_clk   (i_clk),
      .i_dst_rst   (i_rst || o_core_rst),
      .i_dst_rebase(core_rst_dom[1]),
      .o_dst_total (o_c_total)
  );
endmodule : nic_reset_test_harness
