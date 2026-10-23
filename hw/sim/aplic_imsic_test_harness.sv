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

// APLIC direct lines and MSI stores feed the IMSIC alongside CPU IPI stores.
// The reset address configuration follows the IMSIC's page layout and is locked.
module aplic_imsic_test_harness #(
    parameter int unsigned NUM_SOURCES = 8,
    parameter int unsigned NUM_HARTS = 2,
    parameter int unsigned NUM_IDS = 63,
    parameter logic [31:0] M_BASE_ADDR = 32'h4800_0000,
    parameter logic [31:0] S_BASE_ADDR = 32'h4810_0000
) (
    input logic i_clk,
    input logic i_rst,
    input logic [NUM_SOURCES-1:0] i_src,
    input logic i_wr_en,
    input logic [21:0] i_wr_offset,
    input logic [31:0] i_wr_data,
    input logic [21:0] i_rd_offset,
    output logic [63:0] o_rd_pair,
    input logic i_rd_capture,
    input logic i_msi_ready,
    input logic [23:0] i_msi_addr_high,
    output logic o_msi_valid,
    output logic [55:0] o_msi_addr,
    output logic [31:0] o_msi_data,
    output logic [NUM_HARTS-1:0] o_aplic_meip,
    output logic [NUM_HARTS-1:0] o_aplic_seip,
    // CPU-side 32-bit store into the IMSIC regions (an IPI), wins over the APLIC.
    input logic i_cpu_wr_en,
    input logic [31:0] i_cpu_wr_addr,
    input logic [31:0] i_cpu_wr_data,
    input logic [8*NUM_HARTS-1:0] i_m_iselect,
    output logic [64*NUM_HARTS-1:0] o_m_ireg,
    input logic [NUM_HARTS-1:0] i_m_ireg_we,
    input logic [64*NUM_HARTS-1:0] i_m_ireg_keep,
    input logic [64*NUM_HARTS-1:0] i_m_ireg_set,
    output logic [32*NUM_HARTS-1:0] o_m_topei,
    input logic [NUM_HARTS-1:0] i_m_topei_claim,
    input logic [8*NUM_HARTS-1:0] i_s_iselect,
    output logic [64*NUM_HARTS-1:0] o_s_ireg,
    input logic [NUM_HARTS-1:0] i_s_ireg_we,
    input logic [64*NUM_HARTS-1:0] i_s_ireg_keep,
    input logic [64*NUM_HARTS-1:0] i_s_ireg_set,
    output logic [32*NUM_HARTS-1:0] o_s_topei,
    input logic [NUM_HARTS-1:0] i_s_topei_claim,
    output logic [NUM_HARTS-1:0] o_meip,
    output logic [NUM_HARTS-1:0] o_seip
);
  logic msi_ready, msi_fire, high_ok;
  logic [55:0] msi_addr;
  logic imsic_wr_en;
  logic [31:0] imsic_wr_addr, imsic_wr_data;
  logic [NUM_HARTS-1:0] m_illegal, s_illegal;

  aplic #(
      .NUM_SOURCES(NUM_SOURCES),
      .NUM_HARTS(NUM_HARTS),
      .IPRIOLEN(3),
      .MSI_ENABLE(1'b1),
      .MSI_ADDR_WIDTH(56),
      .MMSIADDRCFG_RESET(M_BASE_ADDR >> 12),
      .MMSIADDRCFGH_RESET(32'h8000_0000 | (32'($clog2(NUM_HARTS)) << 12)),
      .SMSIADDRCFG_RESET(S_BASE_ADDR >> 12),
      .SMSIADDRCFGH_RESET(32'b0)
  ) u_aplic (
      .i_clk,
      .i_rst,
      .i_src,
      .i_wr_en,
      .i_wr_offset,
      .i_wr_data,
      .i_rd_offset,
      .o_rd_pair,
      .i_rd_capture,
      .o_meip(o_aplic_meip),
      .o_seip(o_aplic_seip),
      .o_msi_valid,
      .i_msi_ready(msi_ready),
      .o_msi_addr,
      .o_msi_data
  );

  // The CPU store wins the shared write port; the APLIC waits.
  assign msi_ready = i_msi_ready && !i_cpu_wr_en;
  assign msi_fire = o_msi_valid && msi_ready;
  // The test can inject high address bits without unlocking the APLIC.
  // The receiver drops an out-of-range store before narrowing its address.
  assign msi_addr = o_msi_addr | {i_msi_addr_high, 32'b0};
  assign high_ok = (msi_addr[55:32] == '0);
  assign imsic_wr_en = i_cpu_wr_en || (msi_fire && high_ok);
  assign imsic_wr_addr = i_cpu_wr_en ? i_cpu_wr_addr : msi_addr[31:0];
  assign imsic_wr_data = i_cpu_wr_en ? i_cpu_wr_data : o_msi_data;

  imsic #(
      .NUM_HARTS(NUM_HARTS),
      .NUM_IDS(NUM_IDS),
      .M_BASE_ADDR(M_BASE_ADDR),
      .S_BASE_ADDR(S_BASE_ADDR)
  ) u_imsic (
      .i_clk,
      .i_rst,
      .i_wr_en(imsic_wr_en),
      .i_wr_addr(imsic_wr_addr),
      .i_wr_data(imsic_wr_data),
      .i_m_iselect,
      .o_m_ireg,
      .o_m_ireg_illegal(m_illegal),
      .i_m_ireg_we,
      .i_m_ireg_keep,
      .i_m_ireg_set,
      .o_m_topei,
      .i_m_topei_claim,
      .i_s_iselect,
      .o_s_ireg,
      .o_s_ireg_illegal(s_illegal),
      .i_s_ireg_we,
      .i_s_ireg_keep,
      .i_s_ireg_set,
      .o_s_topei,
      .i_s_topei_claim,
      .i_aplic_meip(o_aplic_meip),
      .i_aplic_seip(o_aplic_seip),
      .o_meip,
      .o_seip
  );

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_illegal;
  assign unused_illegal = |{m_illegal, s_illegal};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
