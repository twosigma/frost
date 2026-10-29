/*
 *    Copyright 2026 John Goodacre
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
 * vcu118_eth1g: VCU118 1Gb RJ-45 Ethernet SGMII-over-LVDS PCS/PMA and
 * TI DP83867ISRGZ PHY bootstrap wrapper.
 *
 * On VCU118, the onboard TI DP83867ISRGZ PHY (Bank 64, PHY_ADDR = 5'h03)
 * defaults out of reset to 4-wire SGMII mode with its differential
 * SGMII clock output (AT22/AU22) disabled. Because UltraScale+ native HSSIO
 * BITSLICE in vcu118_pcs_pma_1g requires the SGMII clock to be present and
 * stable before releasing reset, this module sequences:
 *   1. Hardware PHY reset assertion (o_phy_rst_n = 0) for ~21 ms.
 *   2. Post-reset wait (~21 ms) for DP83867 internal POR and strap latch.
 *   3. Clause-22 MDIO indirect/direct register writes to PHY_ADDR = 5'h03:
 *      - CFG4 (0x0031) <= 0x0070 (SGMII auto-negotiation timer = 11 ms)
 *      - SGMIICTL1 (0x00D3) <= 0x4000 (enable 6-wire SGMII clock)
 *      - 10M_SGMII_CFG (0x016F) <= 0x0015 (10M SGMII configuration)
 *      - PHYCR (0x0010) <= 0x5848 (SGMII enable, auto MDI/MDIX)
 *      - BMCR (0x0000) <= 0x1340 (1000M full-duplex, enable & restart AN)
 *   4. Clock stabilization wait (~2.6 ms) before releasing vcu118_pcs_pma_1g
 *      out of reset.
 */
module vcu118_eth1g (
    input logic i_clk_div4,  // Free-running CPU/4 clock
    input logic i_rst,       // Active-high board reset

    // Bank 64 SGMII-over-LVDS pins
    input  logic i_sgmii_clk_p,  // AT22 (from DP83867)
    input  logic i_sgmii_clk_n,  // AU22
    input  logic i_sgmii_rx_p,   // AU24
    input  logic i_sgmii_rx_n,   // AV24
    output logic o_sgmii_tx_p,   // AU21
    output logic o_sgmii_tx_n,   // AV21

    // Bank 64 TI DP83867 PHY management pins
    output logic o_phy_rst_n,  // BA21
    output logic o_phy_mdc,    // AV23
    inout  wire  io_phy_mdio,  // AR23

    // Secondary 1G NIC PHY-side interface (frost.sv)
    output logic        o_tx_clk,
    output logic        o_rx_clk,
    output logic        o_tx_clk_ok,
    output logic        o_rx_clk_ok,
    input  logic [63:0] i_tx_raw_data,
    input  logic        i_tx_raw_valid,
    output logic [63:0] o_rx_raw_data,
    output logic        o_rx_raw_valid,
    output logic        o_rx_signal_ok,
    input  logic [ 3:1] i_phy_ctrl,
    output logic [ 4:0] o_phy_status,
    input  logic        i_rx_block_lock
);
  /* verilator lint_off UNUSEDSIGNAL */
  logic tx_raw_valid_unused;
  logic tx_disable_unused;
  logic rx_block_lock_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign tx_raw_valid_unused  = i_tx_raw_valid;
  assign tx_disable_unused    = i_phy_ctrl[nic_pkg::PhyCtrlBitTxDisable];
  assign rx_block_lock_unused = i_rx_block_lock;

  // Synchronize NIC PHY_CTRL bits into i_clk_div4 domain
  logic phy_reset_div4, pma_loopback_div4;
  cdc_sync #(
      .WIDTH(2)
  ) u_ctrl_div4_sync (
      .i_clk(i_clk_div4),
      .i_rst(1'b0),
      .i_async({
        i_phy_ctrl[nic_pkg::PhyCtrlBitPhyReset], i_phy_ctrl[nic_pkg::PhyCtrlBitPmaLoopback]
      }),
      .o_sync({phy_reset_div4, pma_loopback_div4})
  );

  // ---------------------------------------------------------------------------
  // 1. Clause-22 MDIO Master & TI DP83867 Bootstrap Sequencer (i_clk_div4)
  // ---------------------------------------------------------------------------
  localparam logic [4:0] PhyAddr = 5'h03;
  localparam logic [4:0] RegBmcr = 5'h00;
  localparam logic [4:0] RegRegcr = 5'h0D;
  localparam logic [4:0] RegAddar = 5'h0E;
  localparam logic [4:0] RegPhycr = 5'h10;
  localparam int unsigned NumInitWrites = 14;

  function automatic logic [20:0] get_init_cmd(input logic [3:0] idx);
    unique case (idx)
      // 0..3: Extended write 0x0031 (CFG4) <= 0x0070 (SGMII AN timer = 11 ms)
      4'd0: return {RegRegcr, 16'h001F};
      4'd1: return {RegAddar, 16'h0031};
      4'd2: return {RegRegcr, 16'h401F};
      4'd3: return {RegAddar, 16'h0070};
      // 4..7: Extended write 0x00D3 (SGMIICTL1) <= 0x4000 (6-wire SGMII clock)
      4'd4: return {RegRegcr, 16'h001F};
      4'd5: return {RegAddar, 16'h00D3};
      4'd6: return {RegRegcr, 16'h401F};
      4'd7: return {RegAddar, 16'h4000};
      // 8..11: Extended write 0x016F (10M_SGMII_CFG) <= 0x0015
      4'd8: return {RegRegcr, 16'h001F};
      4'd9: return {RegAddar, 16'h016F};
      4'd10: return {RegRegcr, 16'h401F};
      4'd11: return {RegAddar, 16'h0015};
      // 12: Direct write 0x0010 (PHYCR) <= 0x5848 (SGMII enable, auto MDIX)
      4'd12: return {RegPhycr, 16'h5848};
      // 13: Direct write 0x0000 (BMCR) <= 0x1340 (1000M FD, AN enable + restart)
      default: return {RegBmcr, 16'h1340};
    endcase
  endfunction

  typedef enum logic [2:0] {
    ST_RST_ASSERT = 3'd0,
    ST_RST_WAIT   = 3'd1,
    ST_MDIO_LOAD  = 3'd2,
    ST_MDIO_SHIFT = 3'd3,
    ST_CLK_SETTLE = 3'd4,
    ST_DONE       = 3'd5
  } init_state_e;

  init_state_e        state_q = ST_RST_ASSERT;
  logic        [20:0] wait_cnt_q = '0;
  logic        [ 3:0] cmd_idx_q = '0;
  logic        [ 6:0] bit_cnt_q = '0;
  logic        [ 4:0] clk_div_q = '0;
  logic        [63:0] shift_reg_q = '1;
  logic               phy_rst_n_q = 1'b0;
  logic               mdc_q = 1'b0;
  logic               mdio_o_q = 1'b1;
  logic               mdio_t_q = 1'b1;
  logic               phy_init_done_q = 1'b0;

  logic        [20:0] init_cmd;
  assign init_cmd = get_init_cmd(cmd_idx_q);

  always_ff @(posedge i_clk_div4) begin
    if (i_rst) begin
      state_q         <= ST_RST_ASSERT;
      wait_cnt_q      <= '0;
      cmd_idx_q       <= '0;
      bit_cnt_q       <= '0;
      clk_div_q       <= '0;
      shift_reg_q     <= '1;
      phy_rst_n_q     <= 1'b0;
      mdc_q           <= 1'b0;
      mdio_o_q        <= 1'b1;
      mdio_t_q        <= 1'b1;
      phy_init_done_q <= 1'b0;
    end else begin
      unique case (state_q)
        ST_RST_ASSERT: begin
          phy_rst_n_q     <= 1'b0;
          phy_init_done_q <= 1'b0;
          mdc_q           <= 1'b0;
          mdio_t_q        <= 1'b1;
          if (wait_cnt_q[20]) begin
            wait_cnt_q  <= '0;
            phy_rst_n_q <= 1'b1;
            state_q     <= ST_RST_WAIT;
          end else begin
            wait_cnt_q <= wait_cnt_q + 1'b1;
          end
        end

        ST_RST_WAIT: begin
          phy_rst_n_q <= 1'b1;
          if (wait_cnt_q[20]) begin
            wait_cnt_q <= '0;
            cmd_idx_q  <= '0;
            state_q    <= ST_MDIO_LOAD;
          end else begin
            wait_cnt_q <= wait_cnt_q + 1'b1;
          end
        end

        ST_MDIO_LOAD: begin
          // 32-bit preamble (all 1s) + ST(01) + OP(01) + PA(5) + RA(5) + TA(10) + DATA(16)
          shift_reg_q <= {
            32'hFFFF_FFFF, 2'b01, 2'b01, PhyAddr, init_cmd[20:16], 2'b10, init_cmd[15:0]
          };
          bit_cnt_q <= 7'd64;
          clk_div_q <= '0;
          mdc_q <= 1'b0;
          mdio_o_q <= 1'b1;
          mdio_t_q <= 1'b0;
          state_q <= ST_MDIO_SHIFT;
        end

        ST_MDIO_SHIFT: begin
          clk_div_q <= clk_div_q + 1'b1;
          if (clk_div_q == 5'd15) begin
            mdc_q <= 1'b1;
          end else if (clk_div_q == 5'd31) begin
            mdc_q <= 1'b0;
            if (bit_cnt_q == 7'd0) begin
              mdio_t_q <= 1'b1;
              mdio_o_q <= 1'b1;
              if (cmd_idx_q == 4'(NumInitWrites - 1)) begin
                wait_cnt_q <= '0;
                state_q    <= ST_CLK_SETTLE;
              end else begin
                cmd_idx_q <= cmd_idx_q + 1'b1;
                state_q   <= ST_MDIO_LOAD;
              end
            end else begin
              mdio_o_q    <= shift_reg_q[63];
              mdio_t_q    <= 1'b0;
              shift_reg_q <= {shift_reg_q[62:0], 1'b1};
              bit_cnt_q   <= bit_cnt_q - 1'b1;
            end
          end
        end

        ST_CLK_SETTLE: begin
          mdio_t_q <= 1'b1;
          mdc_q    <= 1'b0;
          if (wait_cnt_q[17]) begin
            state_q <= ST_DONE;
          end else begin
            wait_cnt_q <= wait_cnt_q + 1'b1;
          end
        end

        ST_DONE: begin
          phy_rst_n_q     <= 1'b1;
          phy_init_done_q <= 1'b1;
          mdio_t_q        <= 1'b1;
          mdc_q           <= 1'b0;
        end

        default: state_q <= ST_RST_ASSERT;
      endcase
    end
  end

  assign o_phy_rst_n = phy_rst_n_q;
  assign o_phy_mdc   = mdc_q;

  /* verilator lint_off UNUSEDSIGNAL */
  logic mdio_i_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  IOBUF u_mdio_iobuf (
      .I (mdio_o_q),
      .O (mdio_i_unused),
      .T (mdio_t_q),
      .IO(io_phy_mdio)
  );

  // ---------------------------------------------------------------------------
  // 2. Xilinx 1G/2.5G Ethernet PCS/PMA (SGMII over LVDS in Bank 64)
  // ---------------------------------------------------------------------------
  logic clk125_out;
  logic rst_125_out;
  logic sgmii_clk_en_0;
  logic tx_locked, rx_locked;
  logic [7:0] gmii_rxd;
  logic gmii_rx_dv, gmii_rx_er;
  logic [15:0] status_vector_0;

  vcu118_pcs_pma_1g u_pcs_pma_1g (
      .txp_0                 (o_sgmii_tx_p),
      .txn_0                 (o_sgmii_tx_n),
      .rxp_0                 (i_sgmii_rx_p),
      .rxn_0                 (i_sgmii_rx_n),
      .refclk625_p           (i_sgmii_clk_p),
      .refclk625_n           (i_sgmii_clk_n),
      .clk125_out            (clk125_out),
      .clk312_out            (),
      .rst_125_out           (rst_125_out),
      .tx_logic_reset        (),
      .rx_logic_reset        (),
      .rx_locked             (rx_locked),
      .tx_locked             (tx_locked),
      .tx_bsc_rst_out        (),
      .rx_bsc_rst_out        (),
      .tx_bs_rst_out         (),
      .rx_bs_rst_out         (),
      .tx_rst_dly_out        (),
      .rx_rst_dly_out        (),
      .tx_bsc_en_vtc_out     (),
      .rx_bsc_en_vtc_out     (),
      .tx_bs_en_vtc_out      (),
      .rx_bs_en_vtc_out      (),
      .riu_clk_out           (),
      .riu_addr_out          (),
      .riu_wr_data_out       (),
      .riu_wr_en_out         (),
      .riu_nibble_sel_out    (),
      .tx_pll_clk_out        (),
      .rx_pll_clk_out        (),
      .tx_rdclk_out          (),
      .tx_dly_rdy_1          (1'b1),
      .rx_dly_rdy_1          (1'b1),
      .tx_vtc_rdy_1          (1'b1),
      .rx_vtc_rdy_1          (1'b1),
      .tx_dly_rdy_2          (1'b1),
      .rx_dly_rdy_2          (1'b1),
      .tx_vtc_rdy_2          (1'b1),
      .rx_vtc_rdy_2          (1'b1),
      .tx_dly_rdy_3          (1'b1),
      .rx_dly_rdy_3          (1'b1),
      .tx_vtc_rdy_3          (1'b1),
      .rx_vtc_rdy_3          (1'b1),
      .riu_rddata_1          (16'b0),
      .riu_valid_1           (1'b0),
      .riu_prsnt_1           (1'b0),
      .riu_rddata_2          (16'b0),
      .riu_valid_2           (1'b0),
      .riu_prsnt_2           (1'b0),
      .riu_rddata_3          (16'b0),
      .riu_valid_3           (1'b0),
      .riu_prsnt_3           (1'b0),
      .rx_btval_1            (),
      .rx_btval_2            (),
      .rx_btval_3            (),
      .sgmii_clk_r_0         (),
      .sgmii_clk_f_0         (),
      .sgmii_clk_en_0        (sgmii_clk_en_0),
      .gmii_txd_0            (i_tx_raw_data[7:0]),
      .gmii_tx_en_0          (i_tx_raw_data[8]),
      .gmii_tx_er_0          (i_tx_raw_data[9]),
      .gmii_rxd_0            (gmii_rxd),
      .gmii_rx_dv_0          (gmii_rx_dv),
      .gmii_rx_er_0          (gmii_rx_er),
      .gmii_isolate_0        (),
      .an_interrupt_0        (),
      .an_adv_config_vector_0(16'hd801),
      .an_restart_config_0   (1'b0),
      .speed_is_10_100_0     (status_vector_0[11:10] != 2'b10),
      .speed_is_100_0        (status_vector_0[11:10] == 2'b01),
      .status_vector_0       (status_vector_0),
      .reset                 (!phy_init_done_q || phy_reset_div4),
      .signal_detect_0       (1'b1),
      .configuration_vector_0({1'b1, 2'b00, pma_loopback_div4, 1'b0})
  );

  // ---------------------------------------------------------------------------
  // 3. NIC Interface Signals (clk125_out and status levels)
  // ---------------------------------------------------------------------------
  logic pma_loopback_125;
  cdc_sync u_loop_125_sync (
      .i_clk  (clk125_out),
      .i_rst  (1'b0),
      .i_async(pma_loopback_div4),
      .o_sync (pma_loopback_125)
  );

  logic rx_signal_ok_q = 1'b0;
  vcu118_sgmii_link u_link (
      .i_clk(clk125_out),
      .i_rst(rst_125_out),
      .i_status(status_vector_0),
      .i_loopback(pma_loopback_125),
      .o_ready(rx_signal_ok_q)
  );

  logic clk_ok;
  assign clk_ok         = phy_init_done_q && !rst_125_out && tx_locked && rx_locked;

  assign o_tx_clk       = clk125_out;
  assign o_rx_clk       = clk125_out;
  assign o_tx_clk_ok    = clk_ok;
  assign o_rx_clk_ok    = clk_ok;
  assign o_rx_raw_data  = {54'b0, gmii_rx_er, gmii_rx_dv, gmii_rxd};
  assign o_rx_raw_valid = sgmii_clk_en_0;
  assign o_rx_signal_ok = rx_signal_ok_q;

  always_comb begin
    o_phy_status                                     = '0;
    o_phy_status[nic_pkg::PhyStatusBitClkShared]     = 1'b1;
    o_phy_status[nic_pkg::PhyStatusBitGtResetDone]   = clk_ok;
    o_phy_status[nic_pkg::PhyStatusBitCdrLock]       = rx_locked;
    o_phy_status[nic_pkg::PhyStatusBitModulePresent] = 1'b1;
    o_phy_status[nic_pkg::PhyStatusBitLos]           = !status_vector_0[1];
  end
endmodule : vcu118_eth1g

// Decode the negotiated SGMII status for the full-duplex GMII MAC.
module vcu118_sgmii_link (
    input logic i_clk,
    input logic i_rst,
    input logic [15:0] i_status,
    input logic i_loopback,
    output logic o_ready = 1'b0
);
  always_ff @(posedge i_clk) begin
    if (i_rst) o_ready <= 1'b0;
    else o_ready <= (i_status[0] && i_status[1] && i_status[7] && i_status[12]) || i_loopback;
  end
endmodule : vcu118_sgmii_link
