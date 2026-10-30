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

// Copyright (c) 2026 John Goodacre.

// VCU118 board wrapper: CPU clocking (MMCM), USB-UART, status LEDs, and FROST subsystem.
module vcu118_frost #(
    parameter int unsigned CPU_CLK_HZ = 200_000_000,
    parameter int unsigned PERF_COUNTERS = 0,
    parameter int unsigned ENABLE_CACHED_TIER = 1,
    parameter int unsigned USE_BEHAVIORAL_DDR = 0
) (
    // Differential system clock SYSCLK1_300 (G31 / F31, Bank 47 in SLR1)
    input logic sysclk1_300_p,
    input logic sysclk1_300_n,

    // Active-high CPU reset pushbutton (SW5 on L19)
    input logic cpu_reset,

    // Silicon Labs CP2105 USB-UART console (Bank 64: BB21 TX, AW25 RX)
    output logic o_uart_tx,
    input  logic i_uart_rx,

    // Diagnostic LEDs (Bank 40: AT32, AV34, AY30, BB32)
    output logic [3:0] gpio_led,

    // Dedicated DDR4 differential reference clock (Bank 71: E12/D12 in SLR2)
    input logic default_250mhz_clk_clk_p,
    input logic default_250mhz_clk_clk_n,

    // DDR4 Channel 0 Component Memory Interface (72-bit native ECC in SLR2)
    output logic [16:0] ddr4_sdram_c0_adr,
    output logic        ddr4_sdram_c0_act_n,
    output logic [ 1:0] ddr4_sdram_c0_ba,
    output logic [ 0:0] ddr4_sdram_c0_bg,
    output logic        ddr4_sdram_c0_ck_c,
    output logic        ddr4_sdram_c0_ck_t,
    output logic        ddr4_sdram_c0_cke,
    output logic        ddr4_sdram_c0_cs_n,
    inout  wire  [ 8:0] ddr4_sdram_c0_dm_n,
    inout  wire  [71:0] ddr4_sdram_c0_dq,
    inout  wire  [ 8:0] ddr4_sdram_c0_dqs_c,
    inout  wire  [ 8:0] ddr4_sdram_c0_dqs_t,
    output logic        ddr4_sdram_c0_odt,
    output logic        ddr4_sdram_c0_reset_n,

    // 10G QSFP1 Lane 0 GTY transceiver (Quad 231, X1Y48) & cage control (Bank 64)
    input  logic i_qsfp1_refclk_p,
    input  logic i_qsfp1_refclk_n,
    input  logic i_qsfp1_rx_p,
    input  logic i_qsfp1_rx_n,
    output logic o_qsfp1_tx_p,
    output logic o_qsfp1_tx_n,
    output logic o_qsfp1_modsell,
    output logic o_qsfp1_resetl,
    output logic o_qsfp1_lpmode,
    input  logic i_qsfp1_modprsl,

    // 1G RJ-45 SGMII-over-LVDS & TI DP83867 PHY management (Bank 64)
    input  logic i_sgmii_clk_p,
    input  logic i_sgmii_clk_n,
    input  logic i_sgmii_rx_p,
    input  logic i_sgmii_rx_n,
    output logic o_sgmii_tx_p,
    output logic o_sgmii_tx_n,
    output logic o_phy_rst_n,
    output logic o_phy_mdc,
    inout  wire  io_phy_mdio
);

  localparam int unsigned L2LineBytes = 64;

  logic main_clock, divided_clock_by_4, freerun_clk_150;
  logic cpu_clock_locked;

  // MMCM generates the CPU and CPU/4 clocks from SYSCLK1_300.
  vcu118_clock #(
      .CPU_CLK_HZ(CPU_CLK_HZ)
  ) u_clock_gen (
      .i_sysclk_p       (sysclk1_300_p),
      .i_sysclk_n       (sysclk1_300_n),
      .i_rst            (cpu_reset),
      .o_clk_cpu        (main_clock),
      .o_clk_div4       (divided_clock_by_4),
      .o_clk_freerun_150(freerun_clk_150),
      .o_locked         (cpu_clock_locked)
  );

  // Heartbeat counter for visual status
  logic [26:0] heartbeat_cnt_q = '0;
  always_ff @(posedge main_clock or negedge cpu_clock_locked) begin
    if (!cpu_clock_locked) begin
      heartbeat_cnt_q <= '0;
    end else begin
      heartbeat_cnt_q <= heartbeat_cnt_q + 1'b1;
    end
  end

  logic ddr_init_done;
  assign gpio_led[0] = cpu_clock_locked;
  assign gpio_led[1] = ddr_init_done;
  assign gpio_led[2] = heartbeat_cnt_q[26];
  assign gpio_led[3] = cpu_reset;

  logic cpu_side_aresetn;
  assign cpu_side_aresetn = cpu_clock_locked && !cpu_reset;

  // Active-low synchronous reset for FROST
  logic [3:0] rst_sync_q = '0;
  always_ff @(posedge main_clock or negedge cpu_clock_locked) begin
    if (!cpu_clock_locked) begin
      rst_sync_q <= '0;
    end else begin
      rst_sync_q <= {rst_sync_q[2:0], !(cpu_reset || !ddr_init_done)};
    end
  end
  logic frost_rst_n;
  assign frost_rst_n = rst_sync_q[3];

  // 2. DDR AXI Wires between FROST Subsystem and DDR4 Controller
  logic ddr_axi_rst_n;
  logic ddr_axi_awvalid, ddr_axi_awready;
  logic [4:0] ddr_axi_awid;
  logic [riscv_pkg::DdrAxiAddrBits-1:0] ddr_axi_awaddr;
  logic [7:0] ddr_axi_awlen;
  logic [2:0] ddr_axi_awsize;
  logic [1:0] ddr_axi_awburst;
  logic ddr_axi_wvalid, ddr_axi_wready;
  logic [L2LineBytes*8-1:0] ddr_axi_wdata;
  logic [L2LineBytes-1:0] ddr_axi_wstrb;
  logic ddr_axi_wlast;
  logic ddr_axi_bvalid, ddr_axi_bready;
  logic [4:0] ddr_axi_bid;
  logic [1:0] ddr_axi_bresp;
  logic ddr_axi_arvalid, ddr_axi_arready;
  logic [4:0] ddr_axi_arid;
  logic [riscv_pkg::DdrAxiAddrBits-1:0] ddr_axi_araddr;
  logic [7:0] ddr_axi_arlen;
  logic [2:0] ddr_axi_arsize;
  logic [1:0] ddr_axi_arburst;
  logic ddr_axi_rvalid, ddr_axi_rready;
  logic [4:0] ddr_axi_rid;
  logic [L2LineBytes*8-1:0] ddr_axi_rdata;
  logic [1:0] ddr_axi_rresp;
  logic ddr_axi_rlast;

  // 3. 10G QSFP1 GTY Transceiver & 1G RJ-45 SGMII PCS/PMA Wrappers
  /* verilator lint_off UNUSEDSIGNAL */
  logic qsfp1_modprsl_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign qsfp1_modprsl_unused = i_qsfp1_modprsl;
  assign o_qsfp1_modsell      = 1'b0;
  assign o_qsfp1_resetl       = 1'b1;
  assign o_qsfp1_lpmode       = 1'b0;

  logic nic_tx_clk, nic_rx_clk, nic_tx_clk_ok, nic_rx_clk_ok;
  logic [63:0] nic_tx_raw_data, nic_rx_raw_data;
  logic nic_tx_raw_valid, nic_rx_raw_valid, nic_rx_signal_ok;
  logic [4:0] nic_phy_status;
  logic [3:1] nic_phy_ctrl;
  logic       nic_rx_block_lock;

  vcu118_nic_gty u_nic_gty (
      .i_freerun_clk  (freerun_clk_150),
      .i_refclk_p     (i_qsfp1_refclk_p),
      .i_refclk_n     (i_qsfp1_refclk_n),
      .i_rxp          (i_qsfp1_rx_p),
      .i_rxn          (i_qsfp1_rx_n),
      .o_txp          (o_qsfp1_tx_p),
      .o_txn          (o_qsfp1_tx_n),
      .o_tx_clk       (nic_tx_clk),
      .o_rx_clk       (nic_rx_clk),
      .o_tx_clk_ok    (nic_tx_clk_ok),
      .o_rx_clk_ok    (nic_rx_clk_ok),
      .i_tx_raw_data  (nic_tx_raw_data),
      .i_tx_raw_valid (nic_tx_raw_valid),
      .o_rx_raw_data  (nic_rx_raw_data),
      .o_rx_raw_valid (nic_rx_raw_valid),
      .o_rx_signal_ok (nic_rx_signal_ok),
      .i_phy_ctrl     (nic_phy_ctrl),
      .o_phy_status   (nic_phy_status),
      .i_rx_block_lock(nic_rx_block_lock)
  );

  logic nic_1g_tx_clk, nic_1g_rx_clk, nic_1g_tx_clk_ok, nic_1g_rx_clk_ok;
  logic [63:0] nic_1g_tx_raw_data, nic_1g_rx_raw_data;
  logic nic_1g_tx_raw_valid, nic_1g_rx_raw_valid, nic_1g_rx_signal_ok;
  logic [4:0] nic_1g_phy_status;
  logic [3:1] nic_1g_phy_ctrl;
  logic       nic_1g_rx_block_lock;

  vcu118_eth1g u_eth1g (
      .i_clk_div4     (divided_clock_by_4),
      .i_rst          (!cpu_clock_locked || cpu_reset),
      .i_sgmii_clk_p  (i_sgmii_clk_p),
      .i_sgmii_clk_n  (i_sgmii_clk_n),
      .i_sgmii_rx_p   (i_sgmii_rx_p),
      .i_sgmii_rx_n   (i_sgmii_rx_n),
      .o_sgmii_tx_p   (o_sgmii_tx_p),
      .o_sgmii_tx_n   (o_sgmii_tx_n),
      .o_phy_rst_n    (o_phy_rst_n),
      .o_phy_mdc      (o_phy_mdc),
      .io_phy_mdio    (io_phy_mdio),
      .o_tx_clk       (nic_1g_tx_clk),
      .o_rx_clk       (nic_1g_rx_clk),
      .o_tx_clk_ok    (nic_1g_tx_clk_ok),
      .o_rx_clk_ok    (nic_1g_rx_clk_ok),
      .i_tx_raw_data  (nic_1g_tx_raw_data),
      .i_tx_raw_valid (nic_1g_tx_raw_valid),
      .o_rx_raw_data  (nic_1g_rx_raw_data),
      .o_rx_raw_valid (nic_1g_rx_raw_valid),
      .o_rx_signal_ok (nic_1g_rx_signal_ok),
      .i_phy_ctrl     (nic_1g_phy_ctrl),
      .o_phy_status   (nic_1g_phy_status),
      .i_rx_block_lock(nic_1g_rx_block_lock)
  );

  // 4. Shared Xilinx FROST Subsystem & STARTUPE3 SPI NOR Flash Bridge
  logic spi_cs_n, spi_sck, spi_mosi, spi_miso;
  logic [3:0] startup_di;
  logic       mem_ok;
  (* ASYNC_REG = "TRUE" *)logic [1:0] mem_ok_synchronizer;
  always_ff @(posedge main_clock) begin
    mem_ok_synchronizer <= {mem_ok_synchronizer[0], mem_ok};
  end
  logic mem_ok_synced;
  assign mem_ok_synced = mem_ok_synchronizer[1];

  assign spi_miso = startup_di[1];

  STARTUPE3 #(
      .PROG_USR     ("FALSE"),
      .SIM_CCLK_FREQ(0.0)
  ) u_startup (
      .CFGCLK   (),
      .CFGMCLK  (),
      .DI       (startup_di),
      .EOS      (),
      .PREQ     (),
      .DO       ({3'b111, spi_mosi}),
      .DTS      (4'b0010),
      .FCSBO    (spi_cs_n),
      .FCSBTS   (1'b0),
      .GSR      (1'b0),
      .GTS      (1'b0),
      .KEYCLEARB(1'b1),
      .PACK     (1'b0),
      .USRCCLKO (spi_sck),
      .USRCCLKTS(1'b0),
      .USRDONEO (1'b1),
      .USRDONETS(1'b0)
  );

  xilinx_frost_subsystem #(
      .CLK_FREQ_HZ       (CPU_CLK_HZ),
      .ENABLE_CACHED_TIER(ENABLE_CACHED_TIER),
      .USE_BEHAVIORAL_DDR(USE_BEHAVIORAL_DDR),
      .PERF_COUNTERS     (PERF_COUNTERS),
      .RAW_LOOPBACK      (0),
      .ENABLE_1G_ETH     (1)
  ) u_frost_subsystem (
      .i_clk     (main_clock),
      .i_clk_div4(divided_clock_by_4),
      .i_rst_n   (frost_rst_n),

      .o_uart_tx(o_uart_tx),
      .i_uart_rx(i_uart_rx),

      .i_ddr_axi_rst_n  (ddr_axi_rst_n),
      .o_ddr_axi_awvalid(ddr_axi_awvalid),
      .i_ddr_axi_awready(ddr_axi_awready),
      .o_ddr_axi_awid   (ddr_axi_awid),
      .o_ddr_axi_awaddr (ddr_axi_awaddr),
      .o_ddr_axi_awlen  (ddr_axi_awlen),
      .o_ddr_axi_awsize (ddr_axi_awsize),
      .o_ddr_axi_awburst(ddr_axi_awburst),
      .o_ddr_axi_wvalid (ddr_axi_wvalid),
      .i_ddr_axi_wready (ddr_axi_wready),
      .o_ddr_axi_wdata  (ddr_axi_wdata),
      .o_ddr_axi_wstrb  (ddr_axi_wstrb),
      .o_ddr_axi_wlast  (ddr_axi_wlast),
      .i_ddr_axi_bvalid (ddr_axi_bvalid),
      .o_ddr_axi_bready (ddr_axi_bready),
      .i_ddr_axi_bid    (ddr_axi_bid),
      .i_ddr_axi_bresp  (ddr_axi_bresp),
      .o_ddr_axi_arvalid(ddr_axi_arvalid),
      .i_ddr_axi_arready(ddr_axi_arready),
      .o_ddr_axi_arid   (ddr_axi_arid),
      .o_ddr_axi_araddr (ddr_axi_araddr),
      .o_ddr_axi_arlen  (ddr_axi_arlen),
      .o_ddr_axi_arsize (ddr_axi_arsize),
      .o_ddr_axi_arburst(ddr_axi_arburst),
      .i_ddr_axi_rvalid (ddr_axi_rvalid),
      .o_ddr_axi_rready (ddr_axi_rready),
      .i_ddr_axi_rid    (ddr_axi_rid),
      .i_ddr_axi_rdata  (ddr_axi_rdata),
      .i_ddr_axi_rresp  (ddr_axi_rresp),
      .i_ddr_axi_rlast  (ddr_axi_rlast),

      // No CPU-visible ECC telemetry.
      .i_ecc_present      (1'b0),
      .i_ecc_poll         (1'b0),
      .i_ecc_ce_valid     (1'b0),
      .i_ecc_ce_count     ('0),
      .i_ecc_ce_addr_valid(1'b0),
      .i_ecc_ce_addr      ('0),
      .i_ecc_ue_valid     (1'b0),
      .i_ecc_ue_addr_valid(1'b0),
      .i_ecc_ue_addr      ('0),

      .i_nic_tx_clk       (nic_tx_clk),
      .i_nic_rx_clk       (nic_rx_clk),
      .i_nic_tx_clk_ok    (nic_tx_clk_ok),
      .i_nic_rx_clk_ok    (nic_rx_clk_ok),
      .o_nic_tx_raw_data  (nic_tx_raw_data),
      .o_nic_tx_raw_valid (nic_tx_raw_valid),
      .i_nic_rx_raw_data  (nic_rx_raw_data),
      .i_nic_rx_raw_valid (nic_rx_raw_valid),
      .i_nic_rx_signal_ok (nic_rx_signal_ok),
      .i_nic_phy_status   (nic_phy_status),
      .o_nic_phy_ctrl     (nic_phy_ctrl),
      .o_nic_rx_block_lock(nic_rx_block_lock),

      .i_nic_1g_tx_clk       (nic_1g_tx_clk),
      .i_nic_1g_rx_clk       (nic_1g_rx_clk),
      .i_nic_1g_tx_clk_ok    (nic_1g_tx_clk_ok),
      .i_nic_1g_rx_clk_ok    (nic_1g_rx_clk_ok),
      .o_nic_1g_tx_raw_data  (nic_1g_tx_raw_data),
      .o_nic_1g_tx_raw_valid (nic_1g_tx_raw_valid),
      .i_nic_1g_rx_raw_data  (nic_1g_rx_raw_data),
      .i_nic_1g_rx_raw_valid (nic_1g_rx_raw_valid),
      .i_nic_1g_rx_signal_ok (nic_1g_rx_signal_ok),
      .i_nic_1g_phy_status   (nic_1g_phy_status),
      .o_nic_1g_phy_ctrl     (nic_1g_phy_ctrl),
      .o_nic_1g_rx_block_lock(nic_1g_rx_block_lock),

      .o_spi_cs_n  (spi_cs_n),
      .o_spi_sck   (spi_sck),
      .o_spi_mosi  (spi_mosi),
      .i_spi_miso  (spi_miso),
      .i_ddr_status({ddr_init_done, mem_ok_synced})
  );

  // 5. DDR4 Initialization Engine (for valid ECC generation)

  logic init_busy;
  logic init_awvalid;
  logic [4:0] init_awid;
  logic [30:0] init_awaddr;
  logic [7:0] init_awlen;
  logic [2:0] init_awsize;
  logic [1:0] init_awburst;
  logic init_wvalid;
  logic [L2LineBytes*8-1:0] init_wdata;
  logic [L2LineBytes-1:0] init_wstrb;
  logic init_wlast;
  logic init_bready;

  logic s00_awvalid;
  logic [4:0] s00_awid;
  logic [30:0] s00_awaddr;
  logic [7:0] s00_awlen;
  logic [2:0] s00_awsize;
  logic [1:0] s00_awburst;
  logic s00_wvalid;
  logic [L2LineBytes*8-1:0] s00_wdata;
  logic [L2LineBytes-1:0] s00_wstrb;
  logic s00_wlast;
  logic s00_bready;

  assign s00_awvalid = init_busy ? init_awvalid : ddr_axi_awvalid;
  assign s00_awid    = init_busy ? init_awid    : ddr_axi_awid;
  assign s00_awaddr  = init_busy ? init_awaddr  : ddr_axi_awaddr;
  assign s00_awlen   = init_busy ? init_awlen   : ddr_axi_awlen;
  assign s00_awsize  = init_busy ? init_awsize  : ddr_axi_awsize;
  assign s00_awburst = init_busy ? init_awburst : ddr_axi_awburst;
  assign s00_wvalid  = init_busy ? init_wvalid  : ddr_axi_wvalid;
  assign s00_wdata   = init_busy ? init_wdata   : ddr_axi_wdata;
  assign s00_wstrb   = init_busy ? init_wstrb   : ddr_axi_wstrb;
  assign s00_wlast   = init_busy ? init_wlast   : ddr_axi_wlast;
  assign s00_bready  = init_busy ? init_bready  : ddr_axi_bready;

  (* ASYNC_REG = "TRUE" *) logic [1:0] jtag_aresetn_synchronizer = '0;
  always_ff @(posedge divided_clock_by_4) begin
    jtag_aresetn_synchronizer <= {jtag_aresetn_synchronizer[0], cpu_side_aresetn & ddr_init_done};
  end

  // DDR subsystem integration: tie off if in BRAM-only mode, or instantiate ddr_subsys
  generate
    if (USE_BEHAVIORAL_DDR || !ENABLE_CACHED_TIER) begin : gen_tieoff_ddr
      assign mem_ok                = 1'b1;
      assign ddr_init_done         = 1'b1;
      assign init_busy             = 1'b0;
      assign ddr_axi_rst_n         = cpu_clock_locked;
      assign ddr_axi_awready       = 1'b0;
      assign ddr_axi_wready        = 1'b0;
      assign ddr_axi_bvalid        = 1'b0;
      assign ddr_axi_bid           = '0;
      assign ddr_axi_bresp         = 2'b00;
      assign ddr_axi_arready       = 1'b0;
      assign ddr_axi_rvalid        = 1'b0;
      assign ddr_axi_rid           = '0;
      assign ddr_axi_rdata         = '0;
      assign ddr_axi_rresp         = 2'b00;
      assign ddr_axi_rlast         = 1'b0;

      assign ddr4_sdram_c0_adr     = '0;
      assign ddr4_sdram_c0_act_n   = 1'b1;
      assign ddr4_sdram_c0_ba      = '0;
      assign ddr4_sdram_c0_bg      = '0;
      assign ddr4_sdram_c0_ck_c    = 1'b0;
      assign ddr4_sdram_c0_ck_t    = 1'b0;
      assign ddr4_sdram_c0_cke     = '0;
      assign ddr4_sdram_c0_cs_n    = '1;
      assign ddr4_sdram_c0_odt     = '0;
      assign ddr4_sdram_c0_reset_n = 1'b0;
    end else begin : gen_real_ddr
      assign ddr_axi_rst_n = mem_ok_synced;

      vcu118_ddr_init #(
          .ADDR_BITS   (31),
          .DATA_BITS   (512),
          .ID_BITS     (5),
          .REGION_BYTES(32'h8000_0000)
      ) u_ddr_init (
          .i_clk    (main_clock),
          .i_rst_n  (cpu_clock_locked),
          .i_start  (cpu_clock_locked && mem_ok_synced),
          .o_busy   (init_busy),
          .o_done   (ddr_init_done),
          .o_awvalid(init_awvalid),
          .i_awready(ddr_axi_awready),
          .o_awid   (init_awid),
          .o_awaddr (init_awaddr),
          .o_awlen  (init_awlen),
          .o_awsize (init_awsize),
          .o_awburst(init_awburst),
          .o_wvalid (init_wvalid),
          .i_wready (ddr_axi_wready),
          .o_wdata  (init_wdata),
          .o_wstrb  (init_wstrb),
          .o_wlast  (init_wlast),
          .i_bvalid (ddr_axi_bvalid),
          .o_bready (init_bready),
          .i_bresp  (ddr_axi_bresp)
      );

      ddr_subsys_wrapper ddr_subsystem (
          .cpu_clk                 (main_clock),
          .jtag_clk                (divided_clock_by_4),
          .default_250mhz_clk_clk_p(default_250mhz_clk_clk_p),
          .default_250mhz_clk_clk_n(default_250mhz_clk_clk_n),
          .sys_reset               (cpu_reset || !cpu_clock_locked),
          .cpu_aresetn             (cpu_side_aresetn),
          .jtag_aresetn            (jtag_aresetn_synchronizer[1]),
          .mem_ok                  (mem_ok),

          .S00_AXI_awvalid(s00_awvalid),
          .S00_AXI_awready(ddr_axi_awready),
          .S00_AXI_awid   (s00_awid),
          .S00_AXI_awaddr (s00_awaddr),
          .S00_AXI_awlen  (s00_awlen),
          .S00_AXI_awsize (s00_awsize),
          .S00_AXI_awburst(s00_awburst),
          .S00_AXI_wvalid (s00_wvalid),
          .S00_AXI_wready (ddr_axi_wready),
          .S00_AXI_wdata  (s00_wdata),
          .S00_AXI_wstrb  (s00_wstrb),
          .S00_AXI_wlast  (s00_wlast),
          .S00_AXI_bvalid (ddr_axi_bvalid),
          .S00_AXI_bready (s00_bready),
          .S00_AXI_bid    (ddr_axi_bid),
          .S00_AXI_bresp  (ddr_axi_bresp),

          .S00_AXI_arvalid(ddr_axi_arvalid),
          .S00_AXI_arready(ddr_axi_arready),
          .S00_AXI_arid   (ddr_axi_arid),
          .S00_AXI_araddr (ddr_axi_araddr),
          .S00_AXI_arlen  (ddr_axi_arlen),
          .S00_AXI_arsize (ddr_axi_arsize),
          .S00_AXI_arburst(ddr_axi_arburst),
          .S00_AXI_rvalid (ddr_axi_rvalid),
          .S00_AXI_rready (ddr_axi_rready),
          .S00_AXI_rid    (ddr_axi_rid),
          .S00_AXI_rdata  (ddr_axi_rdata),
          .S00_AXI_rresp  (ddr_axi_rresp),
          .S00_AXI_rlast  (ddr_axi_rlast),

          .ddr4_sdram_c0_act_n  (ddr4_sdram_c0_act_n),
          .ddr4_sdram_c0_adr    (ddr4_sdram_c0_adr),
          .ddr4_sdram_c0_ba     (ddr4_sdram_c0_ba),
          .ddr4_sdram_c0_bg     (ddr4_sdram_c0_bg),
          .ddr4_sdram_c0_ck_c   (ddr4_sdram_c0_ck_c),
          .ddr4_sdram_c0_ck_t   (ddr4_sdram_c0_ck_t),
          .ddr4_sdram_c0_cke    (ddr4_sdram_c0_cke),
          .ddr4_sdram_c0_cs_n   (ddr4_sdram_c0_cs_n),
          .ddr4_sdram_c0_dm_n   (ddr4_sdram_c0_dm_n),
          .ddr4_sdram_c0_dq     (ddr4_sdram_c0_dq),
          .ddr4_sdram_c0_dqs_c  (ddr4_sdram_c0_dqs_c),
          .ddr4_sdram_c0_dqs_t  (ddr4_sdram_c0_dqs_t),
          .ddr4_sdram_c0_odt    (ddr4_sdram_c0_odt),
          .ddr4_sdram_c0_reset_n(ddr4_sdram_c0_reset_n)
      );
    end
  endgenerate

endmodule
