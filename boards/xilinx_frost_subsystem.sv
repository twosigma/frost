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

// Common subsystem for Xilinx FPGA boards: the FROST CPU, the JTAG image
// programming path, and the reset sequencing around them. Board-specific top
// modules supply clock generation and board I/O.
module xilinx_frost_subsystem #(
    // CPU clock frequency in Hz. Must match the clock the board wrapper drives
    // on i_clk. The UART sits on i_clk_div4, so its baud divisor is derived
    // from CLK_FREQ_HZ / 4.
    parameter int unsigned CLK_FREQ_HZ = 300000000,
    // Cached-tier configuration, set by the board top. Hardware boards with a
    // real DDR controller pass ENABLE_CACHED_TIER=1 and USE_BEHAVIORAL_DDR=0.
    // The defaults leave the tier off for a future board that has not wired up
    // DDR yet. The full-system FROST hierarchy includes the UltraRAM L2.
    parameter int unsigned ENABLE_CACHED_TIER = 0,
    // 1 = the cached tier ends in the simulation-only behavioral DDR model;
    // 0 = it ends at the o_ddr_axi_*/i_ddr_axi_* ports below, wired to the
    // board's DDR controller subsystem (hardware board tops drive 0).
    parameter int unsigned USE_BEHAVIORAL_DDR = 1,
    // L1 instruction-cache size in bytes. The default matches X3; retaining a
    // parameter keeps cache-size experiments and future board wrappers simple.
    parameter int unsigned L1I_CACHE_BYTES = 16 * 1024,
    // Optional boot-hang UART classifier. Leave off for interactive testing.
    parameter int unsigned ENABLE_HANG_TRIAGE = 0
) (
    input logic i_clk,       // Main CPU clock
    input logic i_clk_div4,  // Divided clock for JTAG/UART (1/4 of main clock)
    input logic i_rst_n,     // Active-low reset from board

    output logic o_uart_tx,  // UART transmit for debug console
    input  logic i_uart_rx,  // UART receive for debug console input

    // DDR AXI master driven by the cache-hierarchy bridge: single-beat 256-bit
    // bursts, 4-bit transaction ids, addresses relative to the cached region
    // base. Quiescent when USE_BEHAVIORAL_DDR=1 or the cached tier is off.
    output logic         o_ddr_axi_awvalid,
    input  logic         i_ddr_axi_awready,
    output logic [  3:0] o_ddr_axi_awid,
    output logic [ 31:0] o_ddr_axi_awaddr,
    output logic [  7:0] o_ddr_axi_awlen,
    output logic [  2:0] o_ddr_axi_awsize,
    output logic [  1:0] o_ddr_axi_awburst,
    output logic         o_ddr_axi_wvalid,
    input  logic         i_ddr_axi_wready,
    output logic [255:0] o_ddr_axi_wdata,
    output logic [ 31:0] o_ddr_axi_wstrb,
    output logic         o_ddr_axi_wlast,
    input  logic         i_ddr_axi_bvalid,
    output logic         o_ddr_axi_bready,
    input  logic [  3:0] i_ddr_axi_bid,
    input  logic [  1:0] i_ddr_axi_bresp,
    output logic         o_ddr_axi_arvalid,
    input  logic         i_ddr_axi_arready,
    output logic [  3:0] o_ddr_axi_arid,
    output logic [ 31:0] o_ddr_axi_araddr,
    output logic [  7:0] o_ddr_axi_arlen,
    output logic [  2:0] o_ddr_axi_arsize,
    output logic [  1:0] o_ddr_axi_arburst,
    input  logic         i_ddr_axi_rvalid,
    output logic         o_ddr_axi_rready,
    input  logic [  3:0] i_ddr_axi_rid,
    input  logic [255:0] i_ddr_axi_rdata,
    input  logic [  1:0] i_ddr_axi_rresp,
    input  logic         i_ddr_axi_rlast
);

  // AXI4-Lite interface signals between JTAG-to-AXI bridge and AXI-to-BRAM controller.
  // Used for programming the low-BRAM image via JTAG without reprogramming the FPGA;
  // cached-region DDR images are loaded through the board's separate DDR JTAG master.
  logic [31:0] axi_write_address;
  logic [ 2:0] axi_write_protection;
  logic        axi_write_address_valid;
  logic        axi_write_address_ready;
  logic [31:0] axi_write_data;
  logic [ 3:0] axi_write_strobe;  // Byte-level write enables
  logic        axi_write_data_valid;
  logic        axi_write_data_ready;
  logic [ 1:0] axi_write_response;
  logic        axi_write_response_valid;
  logic        axi_write_response_ready;
  logic [31:0] axi_read_address;
  logic [ 2:0] axi_read_protection;
  logic        axi_read_address_valid;
  logic        axi_read_address_ready;
  logic [31:0] axi_read_data;
  logic [ 1:0] axi_read_response;
  logic        axi_read_data_valid;
  logic        axi_read_data_ready;

  // BRAM interface signals for low-BRAM image programming.
  logic        instruction_memory_enable;
  logic [ 3:0] instruction_memory_write_enable;
  logic [17:0] instruction_memory_address;
  logic [31:0] instruction_memory_write_data;
  logic [31:0] instruction_memory_read_data;

  // Hold the programming IP and CPU in reset briefly after the board-level reset
  // releases so clocks are stable before any BRAM write or instruction fetch.
  logic [15:0] programming_reset_counter = '0;
  logic        programming_reset_n = 1'b0;
  always_ff @(posedge i_clk_div4) begin
    if (!i_rst_n) begin
      programming_reset_counter <= '0;
      programming_reset_n <= 1'b0;
    end else if (!programming_reset_n) begin
      programming_reset_counter <= programming_reset_counter + 1'b1;
      if (&programming_reset_counter) begin
        programming_reset_n <= 1'b1;
      end
    end
  end

  logic       instruction_memory_program_enable;
  logic [3:0] instruction_memory_program_write_enable;
  assign instruction_memory_program_enable = i_rst_n & programming_reset_n &
                                             instruction_memory_enable;
  assign instruction_memory_program_write_enable =
      instruction_memory_write_enable & {4{i_rst_n & programming_reset_n}};

  // JTAG-to-AXI bridge IP: turns JTAG commands into AXI transactions.
  // Runs on the divided clock to stay within the JTAG frequency limit.
  jtag_axi_0 jtag_to_axi_bridge (
      .aclk(i_clk_div4),
      .aresetn(i_rst_n & programming_reset_n),
      // AXI master write address channel
      .m_axi_awaddr(axi_write_address),
      .m_axi_awprot(axi_write_protection),
      .m_axi_awvalid(axi_write_address_valid),
      .m_axi_awready(axi_write_address_ready),
      // AXI master write data channel
      .m_axi_wdata(axi_write_data),
      .m_axi_wstrb(axi_write_strobe),
      .m_axi_wvalid(axi_write_data_valid),
      .m_axi_wready(axi_write_data_ready),
      // AXI master write response channel
      .m_axi_bresp(axi_write_response),
      .m_axi_bvalid(axi_write_response_valid),
      .m_axi_bready(axi_write_response_ready),
      // AXI master read address channel
      .m_axi_araddr(axi_read_address),
      .m_axi_arprot(axi_read_protection),
      .m_axi_arvalid(axi_read_address_valid),
      .m_axi_arready(axi_read_address_ready),
      // AXI master read data channel
      .m_axi_rdata(axi_read_data),
      .m_axi_rresp(axi_read_response),
      .m_axi_rvalid(axi_read_data_valid),
      .m_axi_rready(axi_read_data_ready)
  );

  // AXI-to-BRAM controller IP: turns AXI transactions into BRAM port accesses,
  // giving JTAG memory-mapped write access to instruction memory.
  axi_bram_ctrl_0 axi_to_bram_controller (
      .s_axi_aclk   (i_clk_div4),
      .s_axi_aresetn(i_rst_n & programming_reset_n),
      // AXI slave write address channel
      .s_axi_awaddr (axi_write_address),
      .s_axi_awprot (axi_write_protection),
      .s_axi_awvalid(axi_write_address_valid),
      .s_axi_awready(axi_write_address_ready),
      // AXI slave write data channel
      .s_axi_wdata  (axi_write_data),
      .s_axi_wstrb  (axi_write_strobe),
      .s_axi_wvalid (axi_write_data_valid),
      .s_axi_wready (axi_write_data_ready),
      // AXI slave write response channel
      .s_axi_bresp  (axi_write_response),
      .s_axi_bvalid (axi_write_response_valid),
      .s_axi_bready (axi_write_response_ready),
      // AXI slave read address channel
      .s_axi_araddr (axi_read_address),
      .s_axi_arprot (axi_read_protection),
      .s_axi_arvalid(axi_read_address_valid),
      .s_axi_arready(axi_read_address_ready),
      // AXI slave read data channel
      .s_axi_rdata  (axi_read_data),
      .s_axi_rresp  (axi_read_response),
      .s_axi_rvalid (axi_read_data_valid),
      .s_axi_rready (axi_read_data_ready),
      // BRAM port for instruction memory access
      .bram_clk_a   (  /*not connected*/),
      .bram_en_a    (instruction_memory_enable),
      .bram_we_a    (instruction_memory_write_enable),
      .bram_addr_a  (instruction_memory_address),
      .bram_wrdata_a(instruction_memory_write_data),
      // TODO: support JTAG reads of instruction memory as well as writes.
      // That needs a bidirectional FIFO for the clock-domain crossing.
      .bram_rddata_a('0)                                // Reads are not supported
  );

  // Image-load reset: holds the CPU in reset while JTAG writes the software
  // image, so it never executes a half-written image. Every write restarts the
  // 27-bit counter at 1. Reset releases only after the counter runs all the way
  // to its maximum with no further write arriving.
  logic image_load_reset_n = 1'b1;
  logic [26:0] image_load_counter = '0;
  always_ff @(posedge i_clk_div4)
    if (instruction_memory_program_enable && (|instruction_memory_program_write_enable)) begin
      image_load_reset_n <= 1'b0;
      image_load_counter <= 1;
    end else if (image_load_counter > '0 && image_load_counter < '1) begin
      image_load_counter <= image_load_counter + 1;
    end else if (image_load_counter == '1) begin
      image_load_reset_n <= 1'b1;
    end

  // RISC-V debug transport (Phase 3 M3): the DTM's dtmcs and dmi registers
  // hang off the FPGA's own TAP through two BSCANE2 USER chains, USER3 for
  // dtmcs and USER4 for dmi. The Vivado debug hub behind jtag_axi keeps USER1.
  // OpenOCD retargets the three DTM registers with
  //   riscv set_ir idcode 0x09 ; riscv set_ir dtmcs 0x22 ; riscv set_ir dmi 0x23
  // (see fpga/debug/). The TAP-state outputs are ORed across the two
  // instances, and dtm_core qualifies every action with the register select.
  logic bscan_dtmcs_capture, bscan_dtmcs_shift, bscan_dtmcs_update, bscan_dtmcs_reset;
  logic bscan_dtmcs_sel, bscan_dtmcs_tck, bscan_dtmcs_tdi, bscan_dtmcs_tdo;
  logic bscan_dmi_capture, bscan_dmi_shift, bscan_dmi_update, bscan_dmi_reset;
  logic bscan_dmi_sel, bscan_dmi_tck, bscan_dmi_tdi, bscan_dmi_tdo;
  BSCANE2 #(
      .JTAG_CHAIN(3)
  ) bscan_dtmcs (
      .CAPTURE(bscan_dtmcs_capture),
      .DRCK(),
      .RESET(bscan_dtmcs_reset),
      .RUNTEST(),
      .SEL(bscan_dtmcs_sel),
      .SHIFT(bscan_dtmcs_shift),
      .TCK(bscan_dtmcs_tck),
      .TDI(bscan_dtmcs_tdi),
      .TMS(),
      .UPDATE(bscan_dtmcs_update),
      .TDO(bscan_dtmcs_tdo)
  );
  BSCANE2 #(
      .JTAG_CHAIN(4)
  ) bscan_dmi (
      .CAPTURE(bscan_dmi_capture),
      .DRCK(),
      .RESET(bscan_dmi_reset),
      .RUNTEST(),
      .SEL(bscan_dmi_sel),
      .SHIFT(bscan_dmi_shift),
      .TCK(bscan_dmi_tck),
      .TDI(bscan_dmi_tdi),
      .TMS(),
      .UPDATE(bscan_dmi_update),
      .TDO(bscan_dmi_tdo)
  );

  frost #(
      .CLK_FREQ_HZ(CLK_FREQ_HZ),
      .ENABLE_CACHED_TIER(ENABLE_CACHED_TIER),
      .USE_BEHAVIORAL_DDR(USE_BEHAVIORAL_DDR),
      .L1I_CACHE_BYTES(L1I_CACHE_BYTES),
      .ENABLE_HANG_TRIAGE(ENABLE_HANG_TRIAGE),
      .DEBUG_JTAG_TAP(0)
  ) frost_processor (
      .i_clk(i_clk),
      .i_clk_div4(i_clk_div4),
      .i_rst_n(i_rst_n & image_load_reset_n & programming_reset_n),  // Combined reset
      .i_instr_mem_en(instruction_memory_program_enable),
      .i_instr_mem_we(instruction_memory_program_write_enable),
      .i_instr_mem_addr({14'd0, instruction_memory_address}),  // Zero-extend to 32 bits
      .i_instr_mem_wrdata(instruction_memory_write_data),
      .o_instr_mem_rddata(instruction_memory_read_data),
      .o_uart_tx,
      .i_uart_rx,
      // Debug transport: BSCAN bundle (the generic TAP pins stay idle)
      .i_jtag_tck(1'b0),
      .i_jtag_tms(1'b0),
      .i_jtag_tdi(1'b0),
      .i_jtag_trst_n(1'b1),
      .o_jtag_tdo(),
      .i_dtm_bscan_tck(bscan_dtmcs_tck),
      .i_dtm_bscan_tdi(bscan_dtmcs_tdi),
      .i_dtm_bscan_tlr(bscan_dtmcs_reset | bscan_dmi_reset),
      .i_dtm_bscan_capture(bscan_dtmcs_capture | bscan_dmi_capture),
      .i_dtm_bscan_shift(bscan_dtmcs_shift | bscan_dmi_shift),
      .i_dtm_bscan_update(bscan_dtmcs_update | bscan_dmi_update),
      .i_dtm_bscan_sel_dtmcs(bscan_dtmcs_sel),
      .i_dtm_bscan_sel_dmi(bscan_dmi_sel),
      .o_dtm_bscan_tdo_dtmcs(bscan_dtmcs_tdo),
      .o_dtm_bscan_tdo_dmi(bscan_dmi_tdo),
      .o_ddr_axi_awvalid(o_ddr_axi_awvalid),
      .i_ddr_axi_awready(i_ddr_axi_awready),
      .o_ddr_axi_awid(o_ddr_axi_awid),
      .o_ddr_axi_awaddr(o_ddr_axi_awaddr),
      .o_ddr_axi_awlen(o_ddr_axi_awlen),
      .o_ddr_axi_awsize(o_ddr_axi_awsize),
      .o_ddr_axi_awburst(o_ddr_axi_awburst),
      .o_ddr_axi_wvalid(o_ddr_axi_wvalid),
      .i_ddr_axi_wready(i_ddr_axi_wready),
      .o_ddr_axi_wdata(o_ddr_axi_wdata),
      .o_ddr_axi_wstrb(o_ddr_axi_wstrb),
      .o_ddr_axi_wlast(o_ddr_axi_wlast),
      .i_ddr_axi_bvalid(i_ddr_axi_bvalid),
      .o_ddr_axi_bready(o_ddr_axi_bready),
      .i_ddr_axi_bid(i_ddr_axi_bid),
      .i_ddr_axi_bresp(i_ddr_axi_bresp),
      .o_ddr_axi_arvalid(o_ddr_axi_arvalid),
      .i_ddr_axi_arready(i_ddr_axi_arready),
      .o_ddr_axi_arid(o_ddr_axi_arid),
      .o_ddr_axi_araddr(o_ddr_axi_araddr),
      .o_ddr_axi_arlen(o_ddr_axi_arlen),
      .o_ddr_axi_arsize(o_ddr_axi_arsize),
      .o_ddr_axi_arburst(o_ddr_axi_arburst),
      .i_ddr_axi_rvalid(i_ddr_axi_rvalid),
      .o_ddr_axi_rready(o_ddr_axi_rready),
      .i_ddr_axi_rid(i_ddr_axi_rid),
      .i_ddr_axi_rdata(i_ddr_axi_rdata),
      .i_ddr_axi_rresp(i_ddr_axi_rresp),
      .i_ddr_axi_rlast(i_ddr_axi_rlast)
  );

endmodule : xilinx_frost_subsystem
