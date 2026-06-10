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
    parameter int unsigned MMIO_SIZE_BYTES = 32'h2C,
    // URAM memory tier (high-address region). Loads to [URAM_BASE,
    // URAM_BASE+URAM_SIZE_BYTES) are served by the UltraRAM scratchpad and take
    // URAM_READ_LATENCY cycles; the low BRAM range + MMIO stay 1-cycle. The
    // single-outstanding URAM read invariant (enforced by the load queue's
    // slow_outstanding gate) keeps the fast and URAM read responses from
    // overlapping. Production software never addresses this region, so the tier
    // is unused and the read path is byte-identical to the 1-cycle baseline.
    parameter int unsigned URAM_BASE = 32'h0100_0000,
    parameter int unsigned URAM_SIZE_BYTES = 8 * 1024 * 1024,
    parameter int unsigned URAM_READ_LATENCY = 2,
    // Extra cycles the URAM store-done is held vs the fast tier, matching the
    // write-input register stages in sdp_uram_byte_en (WRITE_LATENCY). Keeps the
    // SQ entry / store-to-load forwarding / ordering alive until the registered
    // URAM write actually lands. 1 = legacy single-cycle write (no extra hold).
    parameter int unsigned URAM_WRITE_LATENCY = 1
) (
    input logic i_clk,
    input logic i_rst,

    // Store-queue write request (highest priority).
    input logic            i_sq_mem_write_en,
    input logic [XLEN-1:0] i_sq_mem_write_addr,
    input logic [XLEN-1:0] i_sq_mem_write_data,
    input logic [     3:0] i_sq_mem_write_byte_en,
    input logic            i_sq_mem_write_is_mmio,
    // Registered URAM-tier flag for the SQ write (parallels is_mmio).
    input logic            i_sq_mem_write_is_uram,

    // Atomic-unit write request.
    input logic            i_amo_mem_write_en,
    input logic [XLEN-1:0] i_amo_mem_write_addr,
    input logic [XLEN-1:0] i_amo_mem_write_data,

    // Load-queue read request.
    input logic            i_lq_mem_read_en,
    input logic [XLEN-1:0] i_lq_mem_read_addr,
    input logic            i_lq_mem_addr_valid,

    // External data memory read data (BRAM, combinational the cycle after a read
    // is accepted; the cpu_and_mem mux folds in registered MMIO read data).
    input logic [XLEN-1:0] i_data_mem_rd_data,
    // URAM-tier read data, valid URAM_READ_LATENCY cycles after a URAM read.
    input logic [XLEN-1:0] i_uram_rd_data,

    // External data memory port.
    output logic [XLEN-1:0] o_data_mem_addr,
    output logic [XLEN-1:0] o_data_mem_wr_data,
    output logic [     3:0] o_data_mem_per_byte_wr_en,
    output logic [     3:0] o_data_mem_bram_byte_wr_en,
    output logic            o_data_mem_read_enable,
    // URAM-tier write/read enables (asserted only for URAM-range accesses).
    output logic [     3:0] o_data_mem_uram_byte_wr_en,
    output logic            o_data_mem_uram_read_enable,
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
  logic       sq_mem_write_is_uram;
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
  assign sq_mem_write_is_uram = i_sq_mem_write_is_uram;
  assign amo_mem_write_en     = i_amo_mem_write_en;
  assign amo_mem_write_addr   = i_amo_mem_write_addr;
  assign amo_mem_write_data   = i_amo_mem_write_data;
  assign lq_mem_read_en       = i_lq_mem_read_en;
  assign lq_mem_read_addr     = i_lq_mem_read_addr;
  assign lq_mem_addr_valid    = i_lq_mem_addr_valid;

  // Router-internal state / nets (formerly cpu_ooo locals).
  // Store-done, split per tier (see the always_ff below). Fast tier asserts one
  // cycle after the SQ fires (legacy); the URAM tier is delayed URAM_WRITE_LATENCY
  // cycles to match its registered write port.
  logic                          sq_write_done_fast;
  logic [URAM_WRITE_LATENCY-1:0] sq_write_done_uram_sr;
  logic                          sq_uram_write_before_done;
  logic                          write_port_busy;
  logic                          amo_mem_write_done;
  logic                          lq_mem_request_valid;
  logic [              XLEN-1:0] lq_mem_request_addr;
  logic [              XLEN-1:0] lq_mem_request_addr_eff;
  logic [              XLEN-1:0] lq_mem_read_data;
  logic                          lq_mem_read_valid;
  logic                          lq_mem_request_is_mmio;

  // Effective queued-load address: held copy if a request is pending, else the
  // live LQ read address.
  assign lq_mem_request_addr_eff = lq_mem_request_valid ? lq_mem_request_addr : lq_mem_read_addr;
  assign lq_mem_request_is_mmio =
      (lq_mem_request_addr_eff >= MMIO_ADDR[XLEN-1:0]) &&
      (lq_mem_request_addr_eff < (MMIO_ADDR[XLEN-1:0] + MMIO_SIZE_BYTES[XLEN-1:0]));

  // AMO MMIO check: short cone from amo_entry_idx → lq_address_amo LUTRAM →
  // range comparison. AMOs on MMIO are undefined by spec but we preserve the
  // pre-existing "zero the BRAM write-enable" safety so a stray AMO cannot
  // corrupt an aliased BRAM word. Kept local so the dependency on
  // amo_mem_write_addr never reaches the SQ-only path.
  logic amo_mem_write_is_mmio;
  assign amo_mem_write_is_mmio =
      (amo_mem_write_addr >= MMIO_ADDR[XLEN-1:0]) &&
      (amo_mem_write_addr <  (MMIO_ADDR[XLEN-1:0] + MMIO_SIZE_BYTES[XLEN-1:0]));

  // -------------------------------------------------------------------------
  // URAM tier decode.
  //
  // READ side: is_uram for the queued load address. This is computed the same
  // cheap way as is_mmio and never feeds o_data_mem_addr (the BRAM ADDR cone),
  // so it stays off the BRAM-ADDR late path. It is consumed only by the URAM
  // read-enable and (immediately registered into) the per-tier read-valid
  // pipeline below.
  //
  // WRITE side: the SQ flag arrives pre-registered (i_sq_mem_write_is_uram,
  // computed at the SQ drain alongside is_mmio), mirroring the discipline that
  // keeps the late address-range test off the BRAM WEA pin. The AMO write flag
  // is decoded locally like amo_mem_write_is_mmio; AMOs are restricted to the
  // low BRAM tier by the linker, so this only provides the same "never corrupt
  // an aliased BRAM word" safety as the MMIO case.
  logic lq_mem_request_is_uram;
  assign lq_mem_request_is_uram =
      (lq_mem_request_addr_eff >= URAM_BASE[XLEN-1:0]) &&
      (lq_mem_request_addr_eff <  (URAM_BASE[XLEN-1:0] + URAM_SIZE_BYTES[XLEN-1:0]));

  logic amo_mem_write_is_uram;
  assign amo_mem_write_is_uram =
      (amo_mem_write_addr >= URAM_BASE[XLEN-1:0]) &&
      (amo_mem_write_addr <  (URAM_BASE[XLEN-1:0] + URAM_SIZE_BYTES[XLEN-1:0]));

  generate
    if (URAM_WRITE_LATENCY > 1) begin : gen_sq_uram_write_hold
      assign sq_uram_write_before_done = |sq_write_done_uram_sr[URAM_WRITE_LATENCY-2:0];
    end else begin : gen_no_sq_uram_write_hold
      assign sq_uram_write_before_done = 1'b0;
    end
  endgenerate

  assign write_port_busy = sq_mem_write_en || amo_mem_write_en || sq_uram_write_before_done;

  always_comb begin
    // Load queue memory read. Bypass the one-entry request register when the
    // port is already free; fall back to the queued copy only when a store
    // or AMO held the port in the previous cycle.
    o_data_mem_read_enable = !write_port_busy && (lq_mem_request_valid || lq_mem_read_en);

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
    // BRAM-specific byte-write-enable: MMIO- AND URAM-targeted stores are
    // pre-masked at the SQ/AMO source using registered tier flags. Keeping these
    // checks out of cpu_and_mem (where the old address-range test pulled in the
    // full data_memory_address mux) breaks the -1.045 ns issued_idx_reg →
    // data_memory/WEA path reported post-synthesis. A URAM store must not also
    // land in the BRAM (its aliased low word would be corrupted), so it is
    // excluded here and routed to the URAM tier instead.
    o_data_mem_bram_byte_wr_en =
        (sq_mem_write_en && !sq_mem_write_is_mmio && !sq_mem_write_is_uram) ?
            sq_mem_write_byte_en :
        (amo_mem_write_en && !amo_mem_write_is_mmio && !amo_mem_write_is_uram) ?
            4'b1111 : 4'b0000;

    // URAM-tier byte-write-enable: only URAM-targeted stores/AMOs. The URAM and
    // BRAM write masks are mutually exclusive by tier.
    o_data_mem_uram_byte_wr_en =
        (sq_mem_write_en && sq_mem_write_is_uram) ? sq_mem_write_byte_en :
        (amo_mem_write_en && amo_mem_write_is_uram) ? 4'b1111 : 4'b0000;

    // URAM-tier read enable: UNCONDITIONAL on any queued load read, mirroring
    // the BRAM read. Deliberately NOT qualified by lq_mem_request_is_uram --
    // is_uram is computed on the (AMO-muxed) request address, so ANDing it onto
    // the enable dragged the long amo_entry_idx -> AMO-address-RAM -> is_uram cone
    // onto the URAM read-enable cascade (the dominant post-opt path). The URAM
    // harmlessly reads the aliased low word for non-URAM loads; the is_uram
    // qualification lives only on the per-tier read-valid below, so the response
    // is taken from the URAM only for actual URAM loads (data otherwise ignored).
    o_data_mem_uram_read_enable = o_data_mem_read_enable;

    amo_mem_write_done = !sq_mem_write_en && amo_mem_write_en;

    o_mmio_load_addr = lq_mem_request_addr_eff;
    o_mmio_load_valid = o_data_mem_read_enable && lq_mem_request_is_mmio;
  end

  // Per-tier SQ write-done timing. Fast tier (BRAM/MMIO, production): done one
  // cycle after the SQ fires, as before. URAM tier: the write-control inputs
  // carry (URAM_WRITE_LATENCY-1) extra register stages inside sdp_uram_byte_en,
  // so the data lands that many cycles later -- delay the URAM store-done to
  // match. i_mem_write_done releases the SQ entry (store_queue.sv sq_sent /
  // write_outstanding) and the cache-invalidate, and a younger same-address load
  // is blocked from issuing to memory until the older store leaves the SQ
  // (load_queue.sv), so holding the URAM done until the write lands keeps that
  // forwarding/ordering correct with no new hazard logic. MUST track
  // sdp_uram_byte_en's WRITE_LATENCY (both fed by URAM_WRITE_LATENCY).
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      sq_write_done_fast    <= 1'b0;
      sq_write_done_uram_sr <= '0;
    end else begin
      sq_write_done_fast       <= sq_mem_write_en && !sq_mem_write_is_uram;
      sq_write_done_uram_sr[0] <= sq_mem_write_en && sq_mem_write_is_uram;
      for (int s = 1; s < int'(URAM_WRITE_LATENCY); s++) begin
        sq_write_done_uram_sr[s] <= sq_write_done_uram_sr[s-1];
      end
    end
  end

  // Queued-load request register.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      lq_mem_request_valid <= 1'b0;
    end else begin
      if (lq_mem_request_valid) begin
        // Hold the queued load request until stores/AMOs stop owning the port.
        if (!write_port_busy) begin
          lq_mem_request_valid <= 1'b0;
        end
      end else if (lq_mem_read_en && write_port_busy) begin
        lq_mem_request_valid <= 1'b1;
      end
    end
  end

  // Capture the blocked load request so it can retry once the store/AMO port
  // conflict clears. Unblocked loads bypass this register entirely.
  always_ff @(posedge i_clk) begin
    if (lq_mem_read_en && write_port_busy) begin
      lq_mem_request_addr <= lq_mem_read_addr;
    end
  end

  // Per-tier memory read response timing.
  //
  // Two independent valid taps that, by construction, never assert in the same
  // cycle (the load queue's single-outstanding URAM gate blocks every launch
  // while a URAM read is in flight, and only one read is accepted per cycle):
  //
  //   * FAST path (BRAM + MMIO): the external BRAM returns data exactly one
  //     cycle after a non-URAM read is accepted. fast_valid is the accept pulse
  //     (qualified !is_uram) delayed one cycle; data is forwarded combinationally
  //     from i_data_mem_rd_data. This is identical to the production 1-cycle
  //     baseline -- in production is_uram is always 0, so this is the only tap.
  //
  //   * URAM path: the URAM primitive presents i_uram_rd_data URAM_READ_LATENCY
  //     cycles after its read pulse. A shift register of depth URAM_READ_LATENCY,
  //     seeded by (accept && is_uram), reproduces that delay -> uram_valid.
  //
  // Deliberately NOT a single captured is_uram flag selecting one shared valid
  // tap: that approach racily regressed the fast path. Keeping two taps OR-ed
  // (mutually exclusive) is the robust per-tier form.
  logic lq_mem_read_accepted;
  assign lq_mem_read_accepted = o_data_mem_read_enable;

  logic fast_read_accepted;
  logic uram_read_accepted;
  assign fast_read_accepted = lq_mem_read_accepted && !lq_mem_request_is_uram;
  assign uram_read_accepted = lq_mem_read_accepted && lq_mem_request_is_uram;

  // Fast (BRAM/MMIO) 1-cycle valid.
  logic fast_read_valid;
  always_ff @(posedge i_clk) begin
    if (i_rst) fast_read_valid <= 1'b0;
    else fast_read_valid <= fast_read_accepted;
  end

  // URAM valid pipeline: depth URAM_READ_LATENCY. uram_read_pending[0] is high
  // at accept+1; uram_read_pending[URAM_READ_LATENCY-1] is high at
  // accept+URAM_READ_LATENCY, the cycle i_uram_rd_data is valid.
  logic [URAM_READ_LATENCY-1:0] uram_read_pending;
  always_ff @(posedge i_clk) begin
    if (i_rst) uram_read_pending <= '0;
    else begin
      uram_read_pending[0] <= uram_read_accepted;
      for (int s = 1; s < int'(URAM_READ_LATENCY); s++) begin
        uram_read_pending[s] <= uram_read_pending[s-1];
      end
    end
  end
  logic uram_read_valid;
  assign uram_read_valid = uram_read_pending[URAM_READ_LATENCY-1];

  // The two valids are mutually exclusive (LQ gate guarantee), so OR them.
  assign lq_mem_read_valid = fast_read_valid | uram_read_valid;
  // Select the URAM data only when its valid is asserted; otherwise the BRAM /
  // MMIO combinational data. In production uram_read_valid is always 0, so this
  // is byte-identical to the baseline assign lq_mem_read_data = i_data_mem_rd_data.
  assign lq_mem_read_data = uram_read_valid ? i_uram_rd_data : i_data_mem_rd_data;

  // MMIO read pulse.  Read side effects are driven only by LQ reads; using the
  // full data-port address mux here needlessly pulls SQ/AMO write addresses
  // into FIFO/UART consume-pulse timing.
  assign o_mmio_read_pulse = lq_mem_read_accepted && lq_mem_request_is_mmio;

  // --- Output wiring.
  assign o_sq_mem_write_done = sq_write_done_fast | sq_write_done_uram_sr[URAM_WRITE_LATENCY-1];
  assign o_amo_mem_write_done = amo_mem_write_done;
  assign o_lq_mem_request_valid = lq_mem_request_valid;
  assign o_lq_mem_read_data = lq_mem_read_data;
  assign o_lq_mem_read_valid = lq_mem_read_valid;

endmodule : data_mem_request_router
