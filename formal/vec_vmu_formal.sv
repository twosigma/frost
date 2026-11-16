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

// Constant descriptor wiring lets the formal model discard unused store
// datapaths. The DUT's properties retain arbitrary ready/response choices.
module vec_vmu_formal (
    input logic i_clk,
    input logic i_rst,
    input logic i_cmd_valid,
    input logic i_lc_req_ready,
    input logic i_lc_resp_valid,
    input logic [3:0] i_lc_resp_id,
    input logic [255:0] i_lc_resp_data
);
  vec_vmu #(
      .VLEN(256)
  ) dut (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_fatal_stop(1'b0),
      .i_cmd_valid(i_cmd_valid),
      .i_ppn0(riscv_pkg::VmtPpnBits'(20'h83000)),
      .i_ppn1(riscv_pkg::VmtPpnBits'(20'h83100)),
      .i_page_offset(12'd1),
      .i_first_elem(16'd0),
      .i_last_elem(16'd192),
      .i_eew_log2(2'd0),
      .i_row_stride(64'd0),
      .i_row_count(16'd1),
      .i_active_mask('1),
      .i_is_store(1'b0),
      .i_vd_vs3(5'd8),
      .i_vmt_idx('0),
      .i_free_vmt_on_done(1'b1),
      .i_dbg_seg0('0),
      .i_dbg_seg1('0),
      .i_xr_data('0),
      .i_lc_req_ready(i_lc_req_ready),
      .i_lc_resp_valid(i_lc_resp_valid),
      .i_lc_resp_id(i_lc_resp_id),
      .i_lc_resp_data(i_lc_resp_data),
      .i_lc_resp_error(1'b0)
  );
endmodule
