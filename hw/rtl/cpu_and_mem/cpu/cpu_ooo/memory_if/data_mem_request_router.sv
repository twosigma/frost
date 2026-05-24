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
 * Data-memory request router.
 *
 * Arbitrates the single external data-memory port among the store queue (SQ),
 * the atomic unit (AMO), and queued load-queue (LQ) reads. Priority: SQ writes
 * > AMO writes > queued LQ reads. Holds a blocked load request in a one-entry
 * register until the store/AMO port conflict clears, and produces the MMIO
 * read/write sidebands and the 1-cycle load-read-valid pulse.
 *
 * Extracted verbatim from cpu_ooo (no functional change): the body below is the
 * former "Memory Interface" section, with the parent's signals presented as
 * ports and aliased back to their original names. lq_mem_request_addr_eff is
 * folded in here since all of its uses live in this block.
 */

module data_mem_request_router #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000,
    parameter int unsigned MMIO_SIZE_BYTES = 32'h2C
) (
    input logic i_clk,
    input logic i_rst,

    // Store-queue write request (highest priority).
    input logic            i_sq_mem_write_en,
    input logic [XLEN-1:0] i_sq_mem_write_addr,
    input logic [XLEN-1:0] i_sq_mem_write_data,
    input logic [     3:0] i_sq_mem_write_byte_en,
    input logic            i_sq_mem_write_is_mmio,

    // Atomic-unit write request.
    input logic            i_amo_mem_write_en,
    input logic [XLEN-1:0] i_amo_mem_write_addr,
    input logic [XLEN-1:0] i_amo_mem_write_data,

    // Load-queue read request.
    input logic            i_lq_mem_read_en,
    input logic [XLEN-1:0] i_lq_mem_read_addr,
    input logic            i_lq_mem_addr_valid,

    // External data memory read data.
    input logic [XLEN-1:0] i_data_mem_rd_data,

    // External data memory port.
    output logic [XLEN-1:0] o_data_mem_addr,
    output logic [XLEN-1:0] o_data_mem_wr_data,
    output logic [     3:0] o_data_mem_per_byte_wr_en,
    output logic [     3:0] o_data_mem_bram_byte_wr_en,
    output logic            o_data_mem_read_enable,
    output logic            o_mmio_read_pulse,
    output logic [XLEN-1:0] o_mmio_load_addr,
    output logic            o_mmio_load_valid,

    // Status back to SQ / AMO / LQ.
    output logic            o_sq_mem_write_done,
    output logic            o_amo_mem_write_done,
    output logic            o_lq_mem_request_valid,
    output logic [XLEN-1:0] o_lq_mem_read_data,
    output logic            o_lq_mem_read_valid
);

  // --- Port aliases: keep the extracted body identical to the cpu_ooo original.
  logic sq_mem_write_en;
  logic [XLEN-1:0] sq_mem_write_addr, sq_mem_write_data;
  logic [3:0] sq_mem_write_byte_en;
  logic       sq_mem_write_is_mmio;
  logic       amo_mem_write_en;
  logic [XLEN-1:0] amo_mem_write_addr, amo_mem_write_data;
  logic            lq_mem_read_en;
  logic [XLEN-1:0] lq_mem_read_addr;
  logic            lq_mem_addr_valid;
  assign sq_mem_write_en      = i_sq_mem_write_en;
  assign sq_mem_write_addr    = i_sq_mem_write_addr;
  assign sq_mem_write_data    = i_sq_mem_write_data;
  assign sq_mem_write_byte_en = i_sq_mem_write_byte_en;
  assign sq_mem_write_is_mmio = i_sq_mem_write_is_mmio;
  assign amo_mem_write_en     = i_amo_mem_write_en;
  assign amo_mem_write_addr   = i_amo_mem_write_addr;
  assign amo_mem_write_data   = i_amo_mem_write_data;
  assign lq_mem_read_en       = i_lq_mem_read_en;
  assign lq_mem_read_addr     = i_lq_mem_read_addr;
  assign lq_mem_addr_valid    = i_lq_mem_addr_valid;

  // Router-internal state / nets (formerly cpu_ooo locals).
  logic sq_mem_write_done, sq_mem_write_done_comb;
  logic            amo_mem_write_done;
  logic            lq_mem_request_valid;
  logic [XLEN-1:0] lq_mem_request_addr;
  logic [XLEN-1:0] lq_mem_request_addr_eff;
  logic [XLEN-1:0] lq_mem_read_data;
  logic            lq_mem_read_valid;

  // Effective queued-load address: held copy if a request is pending, else the
  // live LQ read address.
  assign lq_mem_request_addr_eff = lq_mem_request_valid ? lq_mem_request_addr : lq_mem_read_addr;

  // AMO MMIO check: short cone from amo_entry_idx → lq_address_amo LUTRAM →
  // range comparison. AMOs on MMIO are undefined by spec but we preserve the
  // pre-existing "zero the BRAM write-enable" safety so a stray AMO cannot
  // corrupt an aliased BRAM word. Kept local so the dependency on
  // amo_mem_write_addr never reaches the SQ-only path.
  logic amo_mem_write_is_mmio;
  assign amo_mem_write_is_mmio =
      (amo_mem_write_addr >= MMIO_ADDR[XLEN-1:0]) &&
      (amo_mem_write_addr <  (MMIO_ADDR[XLEN-1:0] + MMIO_SIZE_BYTES[XLEN-1:0]));

  always_comb begin
    // Load queue memory read. Bypass the one-entry request register when the
    // port is already free; fall back to the queued copy only when a store
    // or AMO held the port in the previous cycle.
    o_data_mem_read_enable = !sq_mem_write_en && !amo_mem_write_en &&
                             (lq_mem_request_valid || lq_mem_read_en);

    // Keep the BRAM address mux select independent of the LQ read-enable /
    // cache-hit cone. Address-only changes are harmless without read_enable.
    o_data_mem_addr = sq_mem_write_en ? sq_mem_write_addr :
                      amo_mem_write_en ? amo_mem_write_addr :
                      (lq_mem_request_valid || lq_mem_addr_valid) ?
                      lq_mem_request_addr_eff : '0;

    o_data_mem_wr_data = sq_mem_write_en ? sq_mem_write_data :
                         amo_mem_write_en ? amo_mem_write_data : '0;
    // Unmasked byte-write-enable for peripherals (UART/FIFO/timer). MMIO
    // writes must remain visible here so the registered shadow in cpu_and_mem
    // can dispatch them on the next cycle.
    o_data_mem_per_byte_wr_en = sq_mem_write_en ? sq_mem_write_byte_en :
                                amo_mem_write_en ? 4'b1111 : 4'b0000;
    // BRAM-specific byte-write-enable: MMIO-targeted stores are pre-masked at
    // the SQ/AMO source using registered is_mmio flags. Keeping this check
    // out of cpu_and_mem (where the old address-range test pulled in the full
    // data_memory_address mux) breaks the -1.045 ns issued_idx_reg →
    // data_memory/WEA path reported post-synthesis.
    o_data_mem_bram_byte_wr_en =
        (sq_mem_write_en && !sq_mem_write_is_mmio) ? sq_mem_write_byte_en :
        (amo_mem_write_en && !amo_mem_write_is_mmio) ? 4'b1111 : 4'b0000;

    sq_mem_write_done_comb = sq_mem_write_en;
    amo_mem_write_done = !sq_mem_write_en && amo_mem_write_en;

    o_mmio_load_addr = lq_mem_request_addr_eff;
    o_mmio_load_valid = o_data_mem_read_enable &&
                        (lq_mem_request_addr_eff >= MMIO_ADDR[XLEN-1:0]) &&
                        (lq_mem_request_addr_eff < (MMIO_ADDR[XLEN-1:0] +
                                                   MMIO_SIZE_BYTES[XLEN-1:0]));
  end

  // SQ write done: register to align with write_outstanding in the SQ
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      sq_mem_write_done <= 1'b0;
      lq_mem_request_valid <= 1'b0;
    end else begin
      sq_mem_write_done <= sq_mem_write_done_comb;

      if (lq_mem_request_valid) begin
        // Hold the queued load request until stores/AMOs stop owning the port.
        if (!sq_mem_write_en && !amo_mem_write_en) begin
          lq_mem_request_valid <= 1'b0;
        end
      end else if (lq_mem_read_en && (sq_mem_write_en || amo_mem_write_en)) begin
        lq_mem_request_valid <= 1'b1;
      end
    end
  end

  // Capture the blocked load request so it can retry once the store/AMO port
  // conflict clears. Unblocked loads bypass this register entirely.
  always_ff @(posedge i_clk) begin
    if (lq_mem_read_en && (sq_mem_write_en || amo_mem_write_en)) begin
      lq_mem_request_addr <= lq_mem_read_addr;
    end
  end

  // Load data always comes from external memory
  assign lq_mem_read_data = i_data_mem_rd_data;

  // Memory read valid: 1-cycle latency from when the queued load request
  // actually reaches the external memory/MMIO port.
  logic mem_read_pending;
  logic lq_mem_read_accepted;
  assign lq_mem_read_accepted = o_data_mem_read_enable;
  always_ff @(posedge i_clk) begin
    if (i_rst) mem_read_pending <= 1'b0;
    else mem_read_pending <= lq_mem_read_accepted;
  end
  assign lq_mem_read_valid = mem_read_pending;

  // MMIO read pulse
  assign o_mmio_read_pulse = lq_mem_read_accepted &&
                             (o_data_mem_addr >= MMIO_ADDR[XLEN-1:0]) &&
                             (o_data_mem_addr < (MMIO_ADDR[XLEN-1:0] + MMIO_SIZE_BYTES[XLEN-1:0]));

  // --- Output wiring.
  assign o_sq_mem_write_done = sq_mem_write_done;
  assign o_amo_mem_write_done = amo_mem_write_done;
  assign o_lq_mem_request_valid = lq_mem_request_valid;
  assign o_lq_mem_read_data = lq_mem_read_data;
  assign o_lq_mem_read_valid = lq_mem_read_valid;

endmodule : data_mem_request_router
