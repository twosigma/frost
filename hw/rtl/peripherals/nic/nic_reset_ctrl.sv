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
 * nic_reset_ctrl: structural composition of nic_core_reset_ctrl and
 * nic_mac_reset_ctrl for reset-handshake benches and equivalence checks.
 */
module nic_reset_ctrl (
    input logic i_clk,
    input logic i_rst,

    input  logic i_reset_req,
    input  logic i_dma_idle,
    output logic o_stop_dma,
    output logic o_core_rst,
    output logic o_core_rst_next,
    output logic o_busy,

    // Per domain (index 0 = TX, 1 = RX).
    input  logic [1:0] i_clk_ok,
    input  logic [1:0] i_in_reset,
    input  logic [1:0] i_applied_gen,
    input  logic [1:0] i_applied_valid,
    output logic [1:0] o_req,
    output logic [1:0] o_gen,
    output logic [1:0] o_core_rst_dom,
    output logic [1:0] o_ready
);
  logic start_domains;

  nic_core_reset_ctrl u_core (
      .i_clk          (i_clk),
      .i_rst          (i_rst),
      .i_reset_req    (i_reset_req),
      .i_dma_idle     (i_dma_idle),
      .o_stop_dma     (o_stop_dma),
      .o_core_rst     (o_core_rst),
      .o_core_rst_next(o_core_rst_next),
      .o_busy         (o_busy),
      .o_mac_restart  (start_domains)
  );

  nic_mac_reset_ctrl u_mac (
      .i_clk          (i_clk),
      .i_rst          (i_rst),
      .i_restart      (start_domains),
      .i_clk_ok       (i_clk_ok),
      .i_in_reset     (i_in_reset),
      .i_applied_gen  (i_applied_gen),
      .i_applied_valid(i_applied_valid),
      .o_req          (o_req),
      .o_gen          (o_gen),
      .o_core_rst_dom (o_core_rst_dom),
      .o_ready        (o_ready)
  );
endmodule : nic_reset_ctrl
