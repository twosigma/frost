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
 * x3_ecc_reader: polls the X3 DDR4 controller's ECC registers for the memory
 * error unit (hw/rtl/cpu_and_mem/memory_error_unit.sv). It is an AXI4-Lite
 * master on the controller's management window, which the JTAG master also
 * reaches; fpga/ddr_ecc/ddr_ecc_status.py reads it there at the end of a
 * hardware regression and fails the run if ECC_STATUS or CE_CNT is nonzero.
 *
 * Once i_enable is set (DDR calibrated and initialized), the reader reads
 * ECC_ON_OFF, sets o_active if checking is on, and then polls every
 * POLL_CYCLES cycles:
 *   - It reads ECC_STATUS, then CE_CNT, and reports CE_CNT's increase since
 *     the previous poll as soon as it reads it. The controller counts one per
 *     read burst with a corrected error and stops at 255, so when CE_CNT
 *     reaches 128 the reader writes it back to 1, never 0, so the closing
 *     check still sees the run's errors. A corrected error from that read
 *     through the write's cycle goes uncounted.
 *   - If ECC_STATUS's CE bit is set, it reads CE_FFA, the controller's capture
 *     of the first corrected error since the bit was cleared, and reports its
 *     address, then clears the bit, which lets the controller capture the next
 *     one. So every poll interval with a corrected error reports one address.
 *   - If ECC_STATUS's UE bit has risen since the previous poll, it reads
 *     UE_FFA and reports the error and its address. It never clears the UE
 *     bit, as nothing else would record the error for the closing check: the
 *     controller has no UE counter. Each uncorrectable read also returns
 *     SLVERR to its AXI master, so the cache bridge reports every one of the
 *     CPU's.
 * A capture is read high half, low half, high half, low half, and gives an
 * address only if both reads of each half match. A JTAG clear between the
 * reads, then the delayed clear and a new capture, change the register at
 * most twice, and then matching pairs are one capture's (or zero); a JTAG
 * clear takes far longer than the four reads, so two cannot interleave. A response other than OKAY
 * clears o_active and stops the reader, after reporting an uncorrectable
 * error it has seen but not reported, without its address. A reader that
 * stops for any reason stops pulsing o_poll.
 *
 * The controller's register bank gives a register write priority over its
 * own update in the same cycle, and a write that leaves a status bit clear
 * also clears that bit's capture register in the next cycle (the generated
 * IP's ddr4_v2_2_axi_ctrl_reg_bank.sv). So around the CE clear, an
 * uncorrectable error in the write's cycle never sets the UE bit, and an error
 * in the cycle after sets its status bit over a capture register that reads
 * zero. A capture with no failing-word flags is such an empty one, and the
 * reader reports that error without an address. A JTAG clear of CE_CNT
 * between polls shows only as the count going down, so errors after it that
 * take the count past its old value are undercounted by that value.
 *
 * Reports are one-cycle pulses: o_poll at the end of each poll; o_ce_valid
 * with o_ce_count; o_ce_addr_valid with o_ce_addr; o_ue_valid for each
 * uncorrectable error; o_ue_addr_valid with o_ue_addr. An address is the CPU
 * physical address of the captured 64-byte line. The capture register gives
 * the read burst in DRAM terms (ddr4_v2_2_mc_ecc_dec_fix.sv): bits 63:56 flag
 * the failing ECC words, 43:24 hold the row, 23:8 the column, 3:2 the bank
 * group and 1:0 the bank. The X3 controller (fpga/build/x3_ddr_bd.tcl) has one
 * rank and maps an AXI byte address as {row[16:0], column[9:3], bank, bank
 * group, column[2:0], 3'b0} (its ROW_COLUMN_BANK order). ECC word v holds the
 * byte at offset v of each of the line's eight 8-byte words
 * (ddr4_v2_2_mc_ecc.sv), so the line is the finest place a capture names.
 */
module x3_ecc_reader #(
    parameter int unsigned POLL_CYCLES = 1 << 18,
    // The management window's address in this master's space, and the CPU
    // address of the controller's AXI address 0.
    parameter logic [31:0] CTRL_BASE = 32'h4000_0000,
    parameter logic [63:0] DDR_BASE = 64'h8000_0000
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_enable,

    output logic        o_awvalid,
    input  logic        i_awready,
    output logic [31:0] o_awaddr,
    output logic        o_wvalid,
    input  logic        i_wready,
    output logic [31:0] o_wdata,
    output logic [ 3:0] o_wstrb,
    input  logic        i_bvalid,
    output logic        o_bready,
    input  logic [ 1:0] i_bresp,
    output logic        o_arvalid,
    input  logic        i_arready,
    output logic [31:0] o_araddr,
    input  logic        i_rvalid,
    output logic        o_rready,
    input  logic [31:0] i_rdata,
    input  logic [ 1:0] i_rresp,

    output logic        o_active,
    output logic        o_poll,
    output logic        o_ce_valid,
    output logic [ 7:0] o_ce_count,
    output logic        o_ce_addr_valid,
    output logic [63:0] o_ce_addr,
    output logic        o_ue_valid,
    output logic        o_ue_addr_valid,
    output logic [63:0] o_ue_addr
);

  // Register offsets in the management window.
  localparam logic [31:0] EccStatus = 32'h000;
  localparam logic [31:0] EccOnOff = 32'h008;
  localparam logic [31:0] CeCnt = 32'h00C;
  localparam logic [31:0] CeFfaLo = 32'h1C0;
  localparam logic [31:0] CeFfaHi = 32'h1C4;
  localparam logic [31:0] UeFfaLo = 32'h2C0;
  localparam logic [31:0] UeFfaHi = 32'h2C4;
  // ECC_STATUS bits (write one to clear).
  localparam int unsigned StatusUe = 0;
  localparam int unsigned StatusCe = 1;
  localparam logic [7:0] CountResetAt = 8'd128;
  localparam logic [7:0] CountAfterReset = 8'd1;
  localparam int unsigned TimerBits = (POLL_CYCLES > 2) ? $clog2(POLL_CYCLES) : 1;

  typedef enum logic [4:0] {
    S_IDLE,
    S_ON_OFF,
    S_WAIT,
    S_STATUS,
    S_COUNT,
    S_CE_HI,
    S_CE_LO,
    S_CE_HI2,
    S_CE_LO2,
    S_CE_CLEAR,
    S_UE_HI,
    S_UE_LO,
    S_UE_HI2,
    S_UE_LO2,
    S_COUNT_RESET,
    S_REPORT,
    S_STOPPED
  } state_e;

  state_e state_q, next_state;
  logic addr_done_q, data_done_q;  // the transaction's AW or AR, and W, taken
  logic [TimerBits-1:0] timer_q;
  logic ce_set_q, ue_rose_q, ue_now_q, prev_ue_q;
  logic [7:0] count_q, last_count_q;
  logic [31:0] ffa_hi_q, ffa_lo_q, ffa_hi2_q;

  // A capture register to the CPU physical address of its 64-byte line, and
  // whether it holds a capture at all.
  function automatic logic [63:0] ffa_to_phys(input logic [63:0] ffa);
    ffa_to_phys = DDR_BASE + 64'({ffa[40:24], ffa[17:11], ffa[1:0], ffa[2], 6'b0});
  endfunction
  function automatic logic ffa_captured(input logic [63:0] ffa);
    ffa_captured = |ffa[63:56];
  endfunction

  // Each state from S_ON_OFF to S_COUNT_RESET but S_WAIT is one transaction.
  logic txn_state, is_write;
  logic [31:0] reg_offset, wdata;
  always_comb begin
    txn_state  = 1'b1;
    is_write   = 1'b0;
    reg_offset = EccStatus;
    wdata      = '0;
    unique case (state_q)
      S_ON_OFF: reg_offset = EccOnOff;
      S_STATUS: reg_offset = EccStatus;
      S_COUNT: reg_offset = CeCnt;
      S_CE_HI, S_CE_HI2: reg_offset = CeFfaHi;
      S_CE_LO, S_CE_LO2: reg_offset = CeFfaLo;
      S_CE_CLEAR: begin
        is_write = 1'b1;
        reg_offset = EccStatus;
        wdata = 32'(1) << StatusCe;
      end
      S_UE_HI, S_UE_HI2: reg_offset = UeFfaHi;
      S_UE_LO, S_UE_LO2: reg_offset = UeFfaLo;
      S_COUNT_RESET: begin
        is_write = 1'b1;
        reg_offset = CeCnt;
        wdata = 32'(CountAfterReset);
      end
      default: txn_state = 1'b0;
    endcase
  end

  assign o_awaddr  = CTRL_BASE + reg_offset;
  assign o_araddr  = CTRL_BASE + reg_offset;
  assign o_wdata   = wdata;
  assign o_wstrb   = 4'hF;
  assign o_awvalid = txn_state && is_write && !addr_done_q;
  assign o_wvalid  = txn_state && is_write && !data_done_q;
  assign o_arvalid = txn_state && !is_write && !addr_done_q;
  assign o_bready  = 1'b1;
  assign o_rready  = 1'b1;

  logic response, response_ok;
  assign response = txn_state && (is_write ? i_bvalid : i_rvalid);
  assign response_ok = (is_write ? i_bresp : i_rresp) == 2'b00;

  // Whether to write CE_CNT back: from the value being read, or the one read.
  logic count_high;
  assign count_high = ((state_q == S_COUNT) ? i_rdata[7:0] : count_q) >= CountResetAt;

  always_comb begin
    unique case (state_q)
      S_ON_OFF: next_state = S_WAIT;
      S_STATUS: next_state = S_COUNT;
      S_COUNT:
      next_state = ce_set_q ? S_CE_HI : ue_rose_q ? S_UE_HI : count_high ? S_COUNT_RESET : S_REPORT;
      S_CE_HI: next_state = S_CE_LO;
      S_CE_LO: next_state = S_CE_HI2;
      S_CE_HI2: next_state = S_CE_LO2;
      S_CE_LO2: next_state = S_CE_CLEAR;
      S_CE_CLEAR: next_state = ue_rose_q ? S_UE_HI : count_high ? S_COUNT_RESET : S_REPORT;
      S_UE_HI: next_state = S_UE_LO;
      S_UE_LO: next_state = S_UE_HI2;
      S_UE_HI2: next_state = S_UE_LO2;
      S_UE_LO2: next_state = count_high ? S_COUNT_RESET : S_REPORT;
      default: next_state = S_REPORT;
    endcase
  end

  // CE_CNT only grows between polls unless the JTAG check cleared it, in
  // which case all of the new value is new.
  logic [7:0] ce_increase;
  assign ce_increase = (i_rdata[7:0] >= last_count_q) ? i_rdata[7:0] - last_count_q : i_rdata[7:0];

  // The capture as the second low-half read completes it, and whether it is
  // one capture with a failing word.
  logic [63:0] ffa;
  logic ffa_valid;
  assign ffa = {ffa_hi2_q, i_rdata};
  assign ffa_valid = (ffa_hi2_q == ffa_hi_q) && (i_rdata == ffa_lo_q) && ffa_captured(ffa);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q         <= S_IDLE;
      addr_done_q     <= 1'b0;
      data_done_q     <= 1'b0;
      timer_q         <= '0;
      ce_set_q        <= 1'b0;
      ue_rose_q       <= 1'b0;
      ue_now_q        <= 1'b0;
      prev_ue_q       <= 1'b0;
      count_q         <= '0;
      last_count_q    <= '0;
      ffa_lo_q        <= '0;
      ffa_hi_q        <= '0;
      ffa_hi2_q       <= '0;
      o_active        <= 1'b0;
      o_poll          <= 1'b0;
      o_ce_valid      <= 1'b0;
      o_ce_count      <= '0;
      o_ce_addr_valid <= 1'b0;
      o_ce_addr       <= '0;
      o_ue_valid      <= 1'b0;
      o_ue_addr_valid <= 1'b0;
      o_ue_addr       <= '0;
    end else begin
      o_poll          <= 1'b0;
      o_ce_valid      <= 1'b0;
      o_ce_addr_valid <= 1'b0;
      o_ue_valid      <= 1'b0;
      o_ue_addr_valid <= 1'b0;

      if (o_awvalid && i_awready) addr_done_q <= 1'b1;
      if (o_arvalid && i_arready) addr_done_q <= 1'b1;
      if (o_wvalid && i_wready) data_done_q <= 1'b1;

      if (response) begin
        addr_done_q <= 1'b0;
        data_done_q <= 1'b0;
        if (!response_ok) begin
          o_active   <= 1'b0;
          o_ue_valid <= ue_rose_q;
          state_q    <= S_STOPPED;
        end else begin
          unique case (state_q)
            S_ON_OFF: begin
              o_active <= i_rdata[0];
              timer_q  <= '0;
            end
            S_STATUS: begin
              ce_set_q  <= i_rdata[StatusCe];
              ue_rose_q <= i_rdata[StatusUe] && !prev_ue_q;
              ue_now_q  <= i_rdata[StatusUe];
            end
            S_COUNT: begin
              count_q      <= i_rdata[7:0];
              last_count_q <= i_rdata[7:0];
              o_ce_valid   <= (ce_increase != 8'd0);
              o_ce_count   <= ce_increase;
            end
            S_CE_HI, S_UE_HI:   ffa_hi_q <= i_rdata;
            S_CE_LO, S_UE_LO:   ffa_lo_q <= i_rdata;
            S_CE_HI2, S_UE_HI2: ffa_hi2_q <= i_rdata;
            S_CE_LO2: begin
              o_ce_addr_valid <= ffa_valid;
              o_ce_addr       <= ffa_to_phys(ffa);
            end
            S_UE_LO2: begin
              o_ue_valid      <= 1'b1;
              o_ue_addr_valid <= ffa_valid;
              o_ue_addr       <= ffa_to_phys(ffa);
              ue_rose_q       <= 1'b0;
            end
            S_COUNT_RESET:      last_count_q <= CountAfterReset;
            default:            ;
          endcase
          state_q <= next_state;
        end
      end

      unique case (state_q)
        S_IDLE:  if (i_enable) state_q <= S_ON_OFF;
        S_WAIT: begin
          if (timer_q == '0) state_q <= S_STATUS;
          else timer_q <= timer_q - 1'b1;
        end
        S_REPORT: begin
          o_poll    <= 1'b1;
          prev_ue_q <= ue_now_q;
          timer_q   <= TimerBits'(POLL_CYCLES - 1);
          state_q   <= S_WAIT;
        end
        default: ;
      endcase
    end
  end

endmodule : x3_ecc_reader
