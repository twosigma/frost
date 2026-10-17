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
 * memory_error_unit: software's view of memory errors. It counts the DDR
 * controller's corrected (CE) and uncorrectable (UE) ECC errors, which a
 * board-specific reader reports (boards/x3/x3_ecc_reader.sv on the X3), and
 * the error responses that the cache hierarchy's AXI bridge receives. It
 * keeps the address or transaction of the latest report of each kind and
 * drives one level interrupt for the kinds software enables. Counts start at
 * the unit's reset, so software sees the errors since it started.
 *
 * Registers, 32 bits each, in a 256-byte window, written by 32-bit stores and
 * read as 64-bit pairs:
 *   0x00 CAPS         RO   bit 0: an ECC reader is active; bits 15:8: 1
 *   0x04 STATUS       W1C  bit 0 CE, bit 1 UE, bit 2 AXI read error,
 *                          bit 3 AXI write error, bit 4 new CE_ADDR, bit 5
 *                          new UE_ADDR; set by each report of its kind, which
 *                          wins over a clear in the same cycle
 *   0x08 IRQ_EN       RW   bits 5:0: the STATUS bits that interrupt
 *   0x10 CE_COUNT     RO   corrected errors
 *   0x14 UE_COUNT     RO   uncorrectable errors the reader reported (on the
 *                          X3, the first one after each clear of the
 *                          controller's UE status; every one the CPU reads
 *                          also counts in AXI_RD_ERRS)
 *   0x18 AXI_RD_ERRS  RO   AXI read error responses
 *   0x1C AXI_WR_ERRS  RO   AXI write error responses
 *   0x20 CE_ADDR      RO   physical address of the line of the latest CE
 *                          report with an address (64 bits)
 *   0x28 UE_ADDR      RO   physical address of the line of the latest UE
 *                          report with an address (64 bits)
 *   0x30 AXI_ERR      RO   latest AXI error: bit 0 write, bits 2:1 response,
 *                          bits 15:8 transaction id (a write wins over a read
 *                          in the same cycle)
 *   0x38 ECC_POLLS    RO   the reader's completed polls of the controller,
 *                          which stop advancing if the reader stops
 * The counters saturate at 2^32 - 1. Reset clears everything; other offsets
 * read zero. The interrupt is STATUS & IRQ_EN, straight from the
 * registers, so it drops in the cycle after software clears its STATUS bits.
 */
module memory_error_unit #(
    parameter int unsigned ID_BITS = 8
) (
    input logic i_clk,
    input logic i_rst,

    // Register bus, the same shape as the DMA test engine's: byte offsets
    // within the window, 32-bit writes, 64-bit read pairs.
    input  logic        i_wr_en,
    input  logic [ 7:0] i_wr_offset,
    input  logic [31:0] i_wr_data,
    input  logic [ 7:0] i_rd_offset,
    output logic [63:0] o_rd_pair,
    output logic        o_irq,

    // ECC reports from the board's reader; without one, tie them low.
    input logic        i_ecc_present,
    input logic        i_ecc_poll,       // the reader finished a poll
    input logic        i_ce_valid,       // corrected errors since the last report
    input logic [ 7:0] i_ce_count,
    input logic        i_ce_addr_valid,  // a corrected error's address
    input logic [63:0] i_ce_addr,
    input logic        i_ue_valid,       // an uncorrectable error
    input logic        i_ue_addr_valid,  // an uncorrectable error's address
    input logic [63:0] i_ue_addr,

    // AXI error responses at the cache hierarchy's bridge, one channel each
    // for reads and writes.
    input logic               i_rd_err_valid,
    input logic [        1:0] i_rd_err_resp,
    input logic [ID_BITS-1:0] i_rd_err_id,
    input logic               i_wr_err_valid,
    input logic [        1:0] i_wr_err_resp,
    input logic [ID_BITS-1:0] i_wr_err_id
);

  localparam logic [7:0] Version = 8'd1;

  logic [5:0] status_q, irq_en_q;
  logic [31:0] ce_count_q, ue_count_q, axi_rd_errs_q, axi_wr_errs_q, ecc_polls_q;
  logic [63:0] ce_addr_q, ue_addr_q;
  logic [15:0] axi_err_q;

  logic wr_status, wr_irq_en;
  assign wr_status = i_wr_en && (i_wr_offset[7:2] == 6'h01);
  assign wr_irq_en = i_wr_en && (i_wr_offset[7:2] == 6'h02);

  logic [5:0] status_set;
  assign status_set = {
    i_ue_addr_valid, i_ce_addr_valid, i_wr_err_valid, i_rd_err_valid, i_ue_valid, i_ce_valid
  };

  function automatic logic [31:0] saturating_add(input logic [31:0] count,
                                                 input logic [7:0] increment);
    logic [32:0] sum;
    sum = {1'b0, count} + 33'(increment);
    saturating_add = sum[32] ? '1 : sum[31:0];
  endfunction

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      status_q      <= '0;
      irq_en_q      <= '0;
      ce_count_q    <= '0;
      ue_count_q    <= '0;
      axi_rd_errs_q <= '0;
      axi_wr_errs_q <= '0;
      ecc_polls_q   <= '0;
      ce_addr_q     <= '0;
      ue_addr_q     <= '0;
      axi_err_q     <= '0;
    end else begin
      status_q <= (status_q & ~(wr_status ? i_wr_data[5:0] : 6'b0)) | status_set;
      if (wr_irq_en) irq_en_q <= i_wr_data[5:0];
      if (i_ce_valid) ce_count_q <= saturating_add(ce_count_q, i_ce_count);
      if (i_ue_valid) ue_count_q <= saturating_add(ue_count_q, 8'd1);
      if (status_set[2]) axi_rd_errs_q <= saturating_add(axi_rd_errs_q, 8'd1);
      if (status_set[3]) axi_wr_errs_q <= saturating_add(axi_wr_errs_q, 8'd1);
      if (i_ecc_poll) ecc_polls_q <= saturating_add(ecc_polls_q, 8'd1);
      if (i_ce_addr_valid) ce_addr_q <= i_ce_addr;
      if (i_ue_addr_valid) ue_addr_q <= i_ue_addr;
      if (i_wr_err_valid) axi_err_q <= {8'(i_wr_err_id), 5'b0, i_wr_err_resp, 1'b1};
      else if (i_rd_err_valid) axi_err_q <= {8'(i_rd_err_id), 5'b0, i_rd_err_resp, 1'b0};
    end
  end

  always_comb begin
    unique case (i_rd_offset[7:3])
      5'd0: o_rd_pair = {26'b0, status_q, 16'b0, Version, 7'b0, i_ecc_present};
      5'd1: o_rd_pair = {32'b0, 26'b0, irq_en_q};
      5'd2: o_rd_pair = {ue_count_q, ce_count_q};
      5'd3: o_rd_pair = {axi_wr_errs_q, axi_rd_errs_q};
      5'd4: o_rd_pair = ce_addr_q;
      5'd5: o_rd_pair = ue_addr_q;
      5'd6: o_rd_pair = {48'b0, axi_err_q};
      5'd7: o_rd_pair = {32'b0, ecc_polls_q};
      default: o_rd_pair = '0;
    endcase
  end
  assign o_irq = |(status_q & irq_en_q);

endmodule : memory_error_unit
