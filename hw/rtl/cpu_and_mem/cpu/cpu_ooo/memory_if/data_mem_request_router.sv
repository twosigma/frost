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
 * CACHED TIER (high-address region, default [0x8000_0000, +1 GiB)): backed by
 * the cache hierarchy -> DDR through cached_tier_adapter. Completion is
 * HANDSHAKE-based: the adapter pulses i_cached_read_valid /
 * i_cached_write_done any number of cycles after the request, and holds
 * i_cached_write_inflight while a cached store is pending. The LQ's
 * single-outstanding slow gate blocks every load launch while a cached load
 * is in flight, and write_port_busy (which folds in the write-inflight hold)
 * queues loads behind a pending cached store, so the fast and cached read
 * responses can never overlap -- per-tier mutual exclusion.
 */

module data_mem_request_router #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000,
    parameter int unsigned MMIO_SIZE_BYTES = 32'h2C,
    // Cached memory tier (high-address region). Loads/stores to
    // [CACHED_BASE, CACHED_BASE+CACHED_SIZE_BYTES) are served by the cache
    // hierarchy with variable latency; the low BRAM range + MMIO stay 1-cycle.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter int unsigned CACHED_SIZE_BYTES = 32'h4000_0000
) (
    input logic i_clk,
    input logic i_rst,

    // Store-queue write request (highest priority).
    input logic            i_sq_mem_write_en,
    input logic [XLEN-1:0] i_sq_mem_write_addr,
    input logic [XLEN-1:0] i_sq_mem_write_data,
    input logic [     3:0] i_sq_mem_write_byte_en,
    input logic            i_sq_mem_write_is_mmio,
    // Registered cached-tier flag for the SQ write (parallels is_mmio).
    input logic            i_sq_mem_write_is_cached,

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
    // Cached-tier completion (from cached_tier_adapter): handshake pulses with
    // variable latency, plus the write-inflight hold.
    input logic [XLEN-1:0] i_cached_read_data,
    input logic            i_cached_read_valid,
    input logic            i_cached_write_done,
    input logic            i_cached_write_inflight,

    // External data memory port.
    output logic [XLEN-1:0] o_data_mem_addr,
    output logic [XLEN-1:0] o_data_mem_wr_data,
    output logic [     3:0] o_data_mem_per_byte_wr_en,
    output logic [     3:0] o_data_mem_bram_byte_wr_en,
    output logic            o_data_mem_read_enable,
    // Cached-tier write/read requests (asserted only for cached-range accesses).
    output logic [     3:0] o_data_mem_cached_byte_wr_en,
    output logic            o_data_mem_cached_read_enable,
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

  // --- Port aliases: keep the body close to the original extracted form.
  logic sq_mem_write_en;
  logic [XLEN-1:0] sq_mem_write_addr, sq_mem_write_data;
  logic [3:0] sq_mem_write_byte_en;
  logic       sq_mem_write_is_mmio;
  logic       sq_mem_write_is_cached;
  logic       amo_mem_write_en;
  logic [XLEN-1:0] amo_mem_write_addr, amo_mem_write_data;
  logic            lq_mem_read_en;
  logic [XLEN-1:0] lq_mem_read_addr;
  logic            lq_mem_addr_valid;
  assign sq_mem_write_en        = i_sq_mem_write_en;
  assign sq_mem_write_addr      = i_sq_mem_write_addr;
  assign sq_mem_write_data      = i_sq_mem_write_data;
  assign sq_mem_write_byte_en   = i_sq_mem_write_byte_en;
  assign sq_mem_write_is_mmio   = i_sq_mem_write_is_mmio;
  assign sq_mem_write_is_cached = i_sq_mem_write_is_cached;
  assign amo_mem_write_en       = i_amo_mem_write_en;
  assign amo_mem_write_addr     = i_amo_mem_write_addr;
  assign amo_mem_write_data     = i_amo_mem_write_data;
  assign lq_mem_read_en         = i_lq_mem_read_en;
  assign lq_mem_read_addr       = i_lq_mem_read_addr;
  assign lq_mem_addr_valid      = i_lq_mem_addr_valid;

  // Router-internal state / nets.
  logic            sq_write_done_fast;
  logic            write_port_busy;
  logic            amo_mem_write_done;
  logic            lq_mem_request_valid;
  logic [XLEN-1:0] lq_mem_request_addr;
  logic [XLEN-1:0] lq_mem_request_addr_eff;
  logic [XLEN-1:0] lq_mem_read_data;
  logic            lq_mem_read_valid;
  logic            lq_mem_request_is_mmio;

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
  // Cached-tier decode.
  //
  // READ side: is_cached for the queued load address. For the power-of-two
  // aligned 1 GiB region this range compare reduces to a 2-bit test of the
  // top address bits, keeping the decode off any timing-critical cone. It is
  // consumed by the cached read-enable (which lands on the adapter's request
  // register, not a memory enable cascade) and the per-tier read-valid seed.
  //
  // WRITE side: the SQ flag arrives pre-registered (i_sq_mem_write_is_cached,
  // computed at the SQ drain alongside is_mmio), keeping the late
  // address-range test off the BRAM WEA pin. The AMO write flag is decoded
  // locally like amo_mem_write_is_mmio; AMOs are restricted to the low BRAM
  // tier by the linker, so the cached decode only provides the "never corrupt
  // an aliased BRAM word" safety -- a (forbidden) cached AMO write is masked
  // from the BRAM and dropped, NOT forwarded to the cache, so the adapter's
  // write-done pulses can only ever belong to SQ stores.
  logic lq_mem_request_is_cached;
  assign lq_mem_request_is_cached =
      (lq_mem_request_addr_eff >= CACHED_BASE[XLEN-1:0]) &&
      (lq_mem_request_addr_eff <  (CACHED_BASE[XLEN-1:0] + CACHED_SIZE_BYTES[XLEN-1:0]));

  logic amo_mem_write_is_cached;
  assign amo_mem_write_is_cached =
      (amo_mem_write_addr >= CACHED_BASE[XLEN-1:0]) &&
      (amo_mem_write_addr <  (CACHED_BASE[XLEN-1:0] + CACHED_SIZE_BYTES[XLEN-1:0]));

  // A cached store owns the write port from its fire (sq_mem_write_en) until
  // its done pulse (i_cached_write_inflight covers the cycles in between), so
  // loads queue behind it and the 1-deep queued-load register can never be
  // overwritten by launches during a long store flight.
  assign write_port_busy = sq_mem_write_en || amo_mem_write_en || i_cached_write_inflight;

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
    // BRAM-specific byte-write-enable: MMIO- AND cached-targeted stores are
    // pre-masked at the SQ/AMO source using registered tier flags. Keeping
    // these checks out of cpu_and_mem (where the old address-range test pulled
    // in the full data_memory_address mux) breaks the issued_idx_reg →
    // data_memory/WEA timing path. A cached store must not also land in the
    // BRAM (its aliased low word would be corrupted), so it is excluded here
    // and routed to the cached tier instead.
    o_data_mem_bram_byte_wr_en =
        (sq_mem_write_en && !sq_mem_write_is_mmio && !sq_mem_write_is_cached) ?
            sq_mem_write_byte_en :
        (amo_mem_write_en && !amo_mem_write_is_mmio && !amo_mem_write_is_cached) ?
            4'b1111 : 4'b0000;

    // Cached-tier byte-write-enable: SQ stores only. AMO cached writes are
    // linker-forbidden; they are masked from the BRAM above and intentionally
    // NOT forwarded here (see the decode comment).
    o_data_mem_cached_byte_wr_en =
        (sq_mem_write_en && sq_mem_write_is_cached) ? sq_mem_write_byte_en : 4'b0000;

    // Cached-tier read enable: the accepted-load pulse qualified by is_cached.
    // The enable lands on the adapter's request register (not a memory enable
    // cascade) and the 1 GiB decode is a 2-bit compare, so qualification is
    // cheap -- and required, since a cache lookup has side effects
    // (miss/fill/evict) and must not fire for low-BRAM loads.
    o_data_mem_cached_read_enable = o_data_mem_read_enable && lq_mem_request_is_cached;

    amo_mem_write_done = !sq_mem_write_en && amo_mem_write_en;

    o_mmio_load_addr = lq_mem_request_addr_eff;
    o_mmio_load_valid = o_data_mem_read_enable && lq_mem_request_is_mmio;
  end

  // Per-tier SQ write-done timing. Fast tier (BRAM/MMIO): done one cycle after
  // the SQ fires, as before. Cached tier: the adapter pulses
  // i_cached_write_done once the store has landed in the cache hierarchy;
  // i_mem_write_done releases the SQ entry (store_queue.sv sq_sent /
  // write_outstanding) and the cache-invalidate, and a younger same-address
  // load is blocked from issuing to memory until the older store leaves the
  // SQ (load_queue.sv), so holding the cached done until the write lands keeps
  // that forwarding/ordering correct with no new hazard logic.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      sq_write_done_fast <= 1'b0;
    end else begin
      sq_write_done_fast <= sq_mem_write_en && !sq_mem_write_is_cached;
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
  // cycle (the load queue's single-outstanding slow gate blocks every launch
  // while a cached read is in flight, and only one read is accepted per cycle):
  //
  //   * FAST path (BRAM + MMIO): the external BRAM returns data exactly one
  //     cycle after a non-cached read is accepted. fast_valid is the accept
  //     pulse (qualified !is_cached) delayed one cycle; data is forwarded
  //     combinationally from i_data_mem_rd_data. This is identical to the
  //     1-cycle production baseline for low-BRAM/MMIO loads.
  //
  //   * CACHED path: the adapter pulses i_cached_read_valid with
  //     i_cached_read_data when the cache hierarchy completes the load --
  //     a hit after a few cycles, a miss after a writeback/fill round trip.
  //     No fixed-latency pipeline models it; the pulse IS the timing.
  logic lq_mem_read_accepted;
  assign lq_mem_read_accepted = o_data_mem_read_enable;

  logic fast_read_accepted;
  assign fast_read_accepted = lq_mem_read_accepted && !lq_mem_request_is_cached;

  // Fast (BRAM/MMIO) 1-cycle valid.
  logic fast_read_valid;
  always_ff @(posedge i_clk) begin
    if (i_rst) fast_read_valid <= 1'b0;
    else fast_read_valid <= fast_read_accepted;
  end

  // The two valids are mutually exclusive (LQ gate guarantee), so OR them.
  assign lq_mem_read_valid = fast_read_valid | i_cached_read_valid;
  // Select the cached data only when its valid is asserted; otherwise the
  // BRAM / MMIO combinational data.
  assign lq_mem_read_data = i_cached_read_valid ? i_cached_read_data : i_data_mem_rd_data;

  // MMIO read pulse.  Read side effects are driven only by LQ reads; using the
  // full data-port address mux here needlessly pulls SQ/AMO write addresses
  // into FIFO/UART consume-pulse timing.
  assign o_mmio_read_pulse = lq_mem_read_accepted && lq_mem_request_is_mmio;

  // --- Output wiring.
  assign o_sq_mem_write_done = sq_write_done_fast | i_cached_write_done;
  assign o_amo_mem_write_done = amo_mem_write_done;
  assign o_lq_mem_request_valid = lq_mem_request_valid;
  assign o_lq_mem_read_data = lq_mem_read_data;
  assign o_lq_mem_read_valid = lq_mem_read_valid;

endmodule : data_mem_request_router
