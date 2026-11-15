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
 *   5. Poll the PHY receive-error counter (RECR, 0x0015), then dummy-write it to clear it.
 *      Publish the sample with an acknowledged toggle through o_phy_diag. The unused FCS
 *      field is reserved and zero: DP83867 exposes no FCS error count. Use rx_mac_bad_fcs for
 *      MAC-detected FCS errors. The status_vector rides in o_rx_raw_data[25:10] for the
 *      NIC's PCS event counters (its bits: 0 link, 1 sync, 2 RUDI /C/, 3 RUDI /I/, 4 RUDI INVALID,
 *      5 RXDISPERR, 6 RXNOTINTABLE, 7 PHY link, 9:8 remote fault code, 11:10 speed, 12 duplex,
 *      13 remote fault, 15:14 pause).
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
    // Hold {toggle, 16'b0, RECR[15:0]} until i_phy_diag_ack matches the toggle.
    // The FCS field is reserved and zero on DP83867 (nic_pkg PhyDiagBits).
    output logic [32:0] o_phy_diag,
    input  logic        i_phy_diag_ack,
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
  logic mdio_i_raw, mdio_o_w, mdio_t_w, phy_init_done_q;
  vcu118_phy_mdio u_mdio (
      .i_clk          (i_clk_div4),
      .i_rst          (i_rst),
      .o_phy_rst_n    (o_phy_rst_n),
      .o_phy_mdc      (o_phy_mdc),
      .o_mdio_o       (mdio_o_w),
      .o_mdio_t       (mdio_t_w),
      .i_mdio_i       (mdio_i_raw),
      .o_phy_init_done(phy_init_done_q),
      .o_phy_diag     (o_phy_diag),
      .i_phy_diag_ack (i_phy_diag_ack)
  );

  IOBUF u_mdio_iobuf (
      .I (mdio_o_w),
      .O (mdio_i_raw),
      .T (mdio_t_w),
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
  // The PCS/PMA status_vector rides above the GMII bits for the NIC's PCS event counters.
  assign o_rx_raw_data  = {38'b0, status_vector_0, gmii_rx_er, gmii_rx_dv, gmii_rxd};
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

// The Clause-22 MDIO master and DP83867 bootstrap and counter-poll sequencer. The wait bits set
// the PHY reset, post-reset and clock settle times and the poll interval, in clocks of i_clk
// (2^RST_BIT, 2^SETTLE_BIT, 2^POLL_BIT); the defaults give about 21 ms, 2.6 ms and 21 ms at 50 MHz.
module vcu118_phy_mdio #(
    parameter int unsigned RST_BIT = 20,
    parameter int unsigned SETTLE_BIT = 17,
    parameter int unsigned POLL_BIT = 20
) (
    input  logic        i_clk,
    input  logic        i_rst,
    output logic        o_phy_rst_n,
    output logic        o_phy_mdc,
    output logic        o_mdio_o,
    output logic        o_mdio_t,
    input  logic        i_mdio_i,
    output logic        o_phy_init_done,
    output logic [32:0] o_phy_diag,
    input  logic        i_phy_diag_ack
);
  localparam int unsigned RstBit = RST_BIT;
  localparam int unsigned SettleBit = SETTLE_BIT;
  localparam int unsigned PollBit = POLL_BIT;
  localparam logic [4:0] PhyAddr = 5'h03;
  localparam logic [4:0] RegBmcr = 5'h00;
  localparam logic [4:0] RegRegcr = 5'h0D;
  localparam logic [4:0] RegAddar = 5'h0E;
  localparam logic [4:0] RegPhycr = 5'h10;
  localparam logic [4:0] RegRecr = 5'h15;
  localparam int unsigned NumInitWrites = 14;
  // Poll sequence after the init writes: an acknowledged RECR read, then a dummy write to clear.
  localparam int unsigned PollRecrIdx = NumInitWrites;
  localparam int unsigned PollRecrClearIdx = NumInitWrites + 1;

  // {read, register, data}
  function automatic logic [21:0] get_cmd(input logic [4:0] idx);
    unique case (idx)
      // 0..3: Extended write 0x0031 (CFG4) <= 0x0070 (SGMII AN timer = 11 ms)
      5'd0: return {1'b0, RegRegcr, 16'h001F};
      5'd1: return {1'b0, RegAddar, 16'h0031};
      5'd2: return {1'b0, RegRegcr, 16'h401F};
      5'd3: return {1'b0, RegAddar, 16'h0070};
      // 4..7: Extended write 0x00D3 (SGMIICTL1) <= 0x4000 (6-wire SGMII clock)
      5'd4: return {1'b0, RegRegcr, 16'h001F};
      5'd5: return {1'b0, RegAddar, 16'h00D3};
      5'd6: return {1'b0, RegRegcr, 16'h401F};
      5'd7: return {1'b0, RegAddar, 16'h4000};
      // 8..11: Extended write 0x016F (10M_SGMII_CFG) <= 0x0015
      5'd8: return {1'b0, RegRegcr, 16'h001F};
      5'd9: return {1'b0, RegAddar, 16'h016F};
      5'd10: return {1'b0, RegRegcr, 16'h401F};
      5'd11: return {1'b0, RegAddar, 16'h0015};
      // 12: Direct write 0x0010 (PHYCR) <= 0x5848 (SGMII enable, auto MDIX)
      5'd12: return {1'b0, RegPhycr, 16'h5848};
      // 13: Direct write 0x0000 (BMCR) <= 0x1340 (1000M FD, AN enable + restart)
      5'd13: return {1'b0, RegBmcr, 16'h1340};
      // 14: Direct read of RECR (receive error counter)
      5'd14: return {1'b1, RegRecr, 16'h0000};
      // A dummy write clears the saturating RECR after its acknowledged read.
      default: return {1'b0, RegRecr, 16'h0000};
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
  logic        [ 4:0] cmd_idx_q = '0;
  logic        [ 6:0] bit_cnt_q = '0;
  logic        [ 4:0] clk_div_q = '0;
  logic        [63:0] shift_reg_q = '1;
  logic               phy_rst_n_q = 1'b0;
  logic               mdc_q = 1'b0;
  logic               mdio_o_q = 1'b1;
  logic               mdio_t_q = 1'b1;
  logic               phy_init_done_q = 1'b0;

  logic        [21:0] init_cmd;
  assign init_cmd = get_cmd(cmd_idx_q);

  // MDIO read path: the pad level is synchronised, shifted in at the rising MDC edge of each
  // data bit. Publish the complete sample atomically and hold it until acknowledged.
  // The published payload and toggle survive sequencer reset, so an in-flight transfer
  // stays coherent and reset cannot impersonate a completed poll. Partial reads are discarded.
  (* ASYNC_REG = "TRUE" *) logic mdio_i_s1_q, mdio_i_s_q;
  logic rd_ok_q;
  logic [15:0] rd_shift_q = '0;
  logic [15:0] diag_recr_q = '0;
  logic diag_tog_q = 1'b0;
  logic polled_q = 1'b0;
  logic [15:0] sample_recr_q;
  logic diag_ack_s;
  cdc_sync u_diag_ack_sync (
      .i_clk  (i_clk),
      .i_rst  (1'b0),
      .i_async(i_phy_diag_ack),
      .o_sync (diag_ack_s)
  );
  always_ff @(posedge i_clk) begin
    mdio_i_s1_q <= i_mdio_i;
    mdio_i_s_q  <= mdio_i_s1_q;
  end

  always_ff @(posedge i_clk) begin
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
      polled_q        <= 1'b0;
      rd_ok_q         <= 1'b0;
      sample_recr_q   <= '0;
    end else begin
      unique case (state_q)
        ST_RST_ASSERT: begin
          phy_rst_n_q     <= 1'b0;
          phy_init_done_q <= 1'b0;
          mdc_q           <= 1'b0;
          mdio_t_q        <= 1'b1;
          if (wait_cnt_q[RstBit]) begin
            wait_cnt_q  <= '0;
            phy_rst_n_q <= 1'b1;
            state_q     <= ST_RST_WAIT;
          end else begin
            wait_cnt_q <= wait_cnt_q + 1'b1;
          end
        end

        ST_RST_WAIT: begin
          phy_rst_n_q <= 1'b1;
          if (wait_cnt_q[RstBit]) begin
            wait_cnt_q <= '0;
            cmd_idx_q  <= '0;
            state_q    <= ST_MDIO_LOAD;
          end else begin
            wait_cnt_q <= wait_cnt_q + 1'b1;
          end
        end

        ST_MDIO_LOAD: begin
          // 32-bit preamble (all 1s) + ST(01) + OP(01) + PA(5) + RA(5) + TA(10) + DATA(16)
          // OP is 01 for a write and 10 for a read (init_cmd[21]; a read ignores the data field)
          shift_reg_q <= {
            32'hFFFF_FFFF,
            2'b01,
            init_cmd[21] ? 2'b10 : 2'b01,
            PhyAddr,
            init_cmd[20:16],
            2'b10,
            init_cmd[15:0]
          };
          rd_ok_q <= 1'b0;
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
            // The PHY drives zero in the second turnaround slot. A released line is no reply.
            if (init_cmd[21] && bit_cnt_q == 7'd16) rd_ok_q <= !mdio_i_s_q;
            // A read's 16 data bits are the last 16 slots (bit_cnt 15..0): sample before MDC rises.
            if (init_cmd[21] && bit_cnt_q <= 7'd15) rd_shift_q <= {rd_shift_q[14:0], mdio_i_s_q};
          end else if (clk_div_q == 5'd31) begin
            mdc_q <= 1'b0;
            if (bit_cnt_q == 7'd0) begin
              mdio_t_q <= 1'b1;
              mdio_o_q <= 1'b1;
              if (init_cmd[21] && !rd_ok_q) begin
                polled_q <= 1'b0;
                wait_cnt_q <= '0;
                state_q <= ST_DONE;
              end else if (cmd_idx_q == 5'(NumInitWrites - 1)) begin
                wait_cnt_q <= '0;
                state_q    <= ST_CLK_SETTLE;
              end else if (cmd_idx_q == 5'(PollRecrClearIdx)) begin
                polled_q   <= 1'b1;
                wait_cnt_q <= '0;
                state_q    <= ST_DONE;
              end else begin
                if (cmd_idx_q == 5'(PollRecrIdx)) sample_recr_q <= rd_shift_q;
                cmd_idx_q <= cmd_idx_q + 1'b1;
                state_q   <= ST_MDIO_LOAD;
              end
            end else begin
              mdio_o_q    <= shift_reg_q[63];
              // A read releases the line from the turnaround's first bit (frame bit 46)
              mdio_t_q    <= init_cmd[21] && (bit_cnt_q <= 7'd18);
              shift_reg_q <= {shift_reg_q[62:0], 1'b1};
              bit_cnt_q   <= bit_cnt_q - 1'b1;
            end
          end
        end

        ST_CLK_SETTLE: begin
          mdio_t_q <= 1'b1;
          mdc_q    <= 1'b0;
          if (wait_cnt_q[SettleBit]) begin
            wait_cnt_q <= '0;
            state_q    <= ST_DONE;
          end else begin
            wait_cnt_q <= wait_cnt_q + 1'b1;
          end
        end

        ST_DONE: begin
          phy_rst_n_q     <= 1'b1;
          phy_init_done_q <= 1'b1;
          mdio_t_q        <= 1'b1;
          mdc_q           <= 1'b0;
          if (polled_q && diag_ack_s == diag_tog_q) begin
            diag_recr_q <= sample_recr_q;
            diag_tog_q <= !diag_tog_q;
            polled_q <= 1'b0;
          end
          // A stopped destination holds the published sample and delays the next poll.
          if (wait_cnt_q[PollBit]) begin
            if (!polled_q && diag_ack_s == diag_tog_q) begin
              wait_cnt_q <= '0;
              cmd_idx_q  <= 5'(PollRecrIdx);
              state_q    <= ST_MDIO_LOAD;
            end
          end else begin
            wait_cnt_q <= wait_cnt_q + 1'b1;
          end
        end

        default: state_q <= ST_RST_ASSERT;
      endcase
    end
  end

  assign o_phy_diag = {diag_tog_q, 16'b0, diag_recr_q};
  assign o_phy_rst_n = phy_rst_n_q;
  assign o_phy_mdc = mdc_q;
  assign o_phy_init_done = phy_init_done_q;
  assign o_mdio_o = mdio_o_q;
  assign o_mdio_t = mdio_t_q;

endmodule : vcu118_phy_mdio
