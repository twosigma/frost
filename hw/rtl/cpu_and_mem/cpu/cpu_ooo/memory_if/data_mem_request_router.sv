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
 * register until both the store/AMO port conflict and, for the complete device
 * quadrant, the committed-store drain fence clear. The request releases only
 * when every applicable blocker has cleared. The drain check terminates
 * at the router's read-accept boundary so every memory/MMIO read effect shares
 * one decision, without feeding the SQ status back through the LQ issue cone.
 *
 * CACHED TIER (high-address region, default [0x8000_0000, +1 GiB)): backed by
 * the cache hierarchy -> DDR through cached_tier_adapter. Completion is
 * HANDSHAKE-based: the adapter pulses i_cached_read_valid /
 * i_cached_write_done any number of cycles after the request, and holds
 * i_cached_write_inflight while a cached store is pending. The LQ's
 * single-outstanding slow gate blocks every load launch while a cached load is
 * in flight. A parked request's registered pending bit feeds directly back to
 * the LQ bus-busy gate, so a second handoff cannot overwrite the router hold.
 * write_port_busy (which folds in the write-inflight hold) queues loads behind
 * a pending cached store, so fast and cached read responses cannot overlap --
 * per-tier mutual exclusion.
 */

module data_mem_request_router #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000,
    parameter int unsigned MMIO_SIZE_BYTES = 32'h2C,
    // Cached memory tier (high-address region). Loads/stores to
    // [CACHED_BASE, CACHED_BASE+CACHED_SIZE_BYTES) are served by the cache
    // hierarchy with variable latency. The low BRAM stays 1-cycle; MMIO returns
    // one cycle after terminal accept but may first park for store drain.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter int unsigned CACHED_SIZE_BYTES = 32'h4000_0000
) (
    input logic i_clk,
    input logic i_rst,

    // Store-queue write request (highest priority).
    input logic                              i_sq_mem_write_en,
    input logic [                  XLEN-1:0] i_sq_mem_write_addr,
    input logic [riscv_pkg::MemDataBits-1:0] i_sq_mem_write_data,
    input logic [riscv_pkg::MemStrbBits-1:0] i_sq_mem_write_byte_en,
    input logic                              i_sq_mem_write_is_mmio,
    // Registered cached-tier flag for the SQ write (parallels is_mmio).
    input logic                              i_sq_mem_write_is_cached,

    // Atomic-unit write request.
    input logic                              i_amo_mem_write_en,
    input logic [                  XLEN-1:0] i_amo_mem_write_addr,
    input logic [riscv_pkg::MemDataBits-1:0] i_amo_mem_write_data,
    input logic                              i_amo_mem_write_is_dword,

    // Load-queue read request.
    input logic            i_lq_mem_read_en,
    input logic [XLEN-1:0] i_lq_mem_read_addr,
    input logic            i_lq_mem_addr_valid,
    // Registered SQ status, high only when no committed-but-unwritten store
    // remains. It is already pessimistically cleared by same-cycle raw commits;
    // do not pipeline it again or a stale-high cycle can release a device read.
    input logic            i_sq_committed_empty,

    // External data memory read data (BRAM, combinational the cycle after a read
    // is accepted; the cpu_and_mem mux folds in registered MMIO read data).
    input logic [riscv_pkg::MemDataBits-1:0] i_data_mem_rd_data,
    // Cached-tier completion (from cached_tier_adapter): handshake pulses with
    // variable latency, plus the write-inflight hold.
    input logic [riscv_pkg::MemDataBits-1:0] i_cached_read_data,
    input logic                              i_cached_read_valid,
    input logic                              i_cached_write_done,
    input logic                              i_cached_write_inflight,

    // External data memory port.
    output logic [                  XLEN-1:0] o_data_mem_addr,
    output logic [riscv_pkg::MemDataBits-1:0] o_data_mem_wr_data,
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_per_byte_wr_en,
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_bram_byte_wr_en,
    output logic                              o_data_mem_read_enable,
    // Cached-tier write/read requests (asserted only for cached-range accesses).
    output logic [riscv_pkg::MemStrbBits-1:0] o_data_mem_cached_byte_wr_en,
    // Cached-tier write data. SQ-store drain data normally; the AMO new value
    // on the single cycle a cached AMO write is launched to the adapter.
    output logic [riscv_pkg::MemDataBits-1:0] o_data_mem_cached_wr_data,
    output logic                              o_data_mem_cached_read_enable,
    output logic                              o_mmio_read_pulse,
    output logic [                  XLEN-1:0] o_mmio_load_addr,
    output logic                              o_mmio_load_valid,
    output logic                              o_mmio_fifo0_read_pulse,
    output logic                              o_mmio_fifo1_read_pulse,
    output logic                              o_mmio_uart_rx_ready_pulse,

    // Status back to SQ / AMO / LQ.
    output logic                              o_sq_mem_write_done,
    output logic                              o_amo_mem_write_done,
    // Registered pending Q, fed directly back into the integrated LQ's
    // bus-busy gate. It remains high throughout the terminal-accept cycle.
    output logic                              o_lq_mem_request_valid,
    output logic [riscv_pkg::MemDataBits-1:0] o_lq_mem_read_data,
    output logic                              o_lq_mem_read_valid
);

  // --- Port aliases: keep the body close to the original extracted form.
  logic                              sq_mem_write_en;
  logic [                  XLEN-1:0] sq_mem_write_addr;
  logic [riscv_pkg::MemDataBits-1:0] sq_mem_write_data;
  logic [riscv_pkg::MemStrbBits-1:0] sq_mem_write_byte_en;
  logic                              sq_mem_write_is_mmio;
  logic                              sq_mem_write_is_cached;
  logic                              amo_mem_write_en;
  logic [                  XLEN-1:0] amo_mem_write_addr;
  logic [riscv_pkg::MemDataBits-1:0] amo_mem_write_data;
  logic                              amo_mem_write_is_dword;
  logic                              lq_mem_read_en;
  logic [                  XLEN-1:0] lq_mem_read_addr;
  logic                              lq_mem_addr_valid;
  assign sq_mem_write_en        = i_sq_mem_write_en;
  assign sq_mem_write_addr      = i_sq_mem_write_addr;
  assign sq_mem_write_data      = i_sq_mem_write_data;
  assign sq_mem_write_byte_en   = i_sq_mem_write_byte_en;
  assign sq_mem_write_is_mmio   = i_sq_mem_write_is_mmio;
  assign sq_mem_write_is_cached = i_sq_mem_write_is_cached;
  assign amo_mem_write_en       = i_amo_mem_write_en;
  assign amo_mem_write_addr     = i_amo_mem_write_addr;
  assign amo_mem_write_data     = i_amo_mem_write_data;
  assign amo_mem_write_is_dword = i_amo_mem_write_is_dword;
  // AMO write strobes: word lanes for .W (by addr[2]); full beat for .D.
  logic [riscv_pkg::MemStrbBits-1:0] amo_write_strobes;
  assign amo_write_strobes = riscv_pkg::mem_strobe_for(
      amo_mem_write_is_dword ? 2'b11 : 2'b10, amo_mem_write_addr[2:0]
  );
  assign lq_mem_read_en = i_lq_mem_read_en;
  assign lq_mem_read_addr = i_lq_mem_read_addr;
  assign lq_mem_addr_valid = i_lq_mem_addr_valid;

  // Router-internal state / nets. XLEN'() casts, not [XLEN-1:0]
  // part-selects: MMIO_ADDR is a 32-bit int parameter, so a 64-bit
  // part-select of it would be out of range.
  localparam logic [XLEN-1:0] UartRxDataMmioAddr = XLEN'(MMIO_ADDR) + XLEN'(32'h4);
  localparam logic [XLEN-1:0] Fifo0MmioAddr = XLEN'(MMIO_ADDR) + XLEN'(32'h8);
  localparam logic [XLEN-1:0] Fifo1MmioAddr = XLEN'(MMIO_ADDR) + XLEN'(32'hC);

  logic                              sq_write_done_fast;
  logic                              write_port_busy;
  logic                              amo_mem_write_done;
  logic                              lq_mem_request_valid;
  logic [                  XLEN-1:0] lq_mem_request_addr;
  logic [                  XLEN-1:0] lq_mem_request_addr_eff;
  logic [riscv_pkg::MemDataBits-1:0] lq_mem_read_data;
  logic                              lq_mem_read_valid;
  logic                              lq_mem_request_is_mmio;
  logic                              lq_mem_request_requires_drain;
  logic                              lq_mem_read_candidate;
  logic                              lq_mem_read_accepted;

  // Effective queued-load address: held copy if a request is pending, else the
  // live LQ read address.
  assign lq_mem_request_addr_eff = lq_mem_request_valid ? lq_mem_request_addr : lq_mem_read_addr;
  assign lq_mem_request_is_mmio =
      (lq_mem_request_addr_eff >= XLEN'(MMIO_ADDR)) &&
      (lq_mem_request_addr_eff < (XLEN'(MMIO_ADDR) + XLEN'(MMIO_SIZE_BYTES)));

  // Device ordering uses the LQ's full-quadrant classification, deliberately
  // broader than the implemented MMIO register window above. Besides matching
  // the architectural classification exactly, this is a two-bit decode at the
  // terminal accept boundary and conservatively orders unmapped device space.
  assign lq_mem_request_requires_drain = (lq_mem_request_addr_eff[31:30] == 2'b01);

  // AMO MMIO check: short cone from amo_entry_idx → lq_address_amo LUTRAM →
  // range comparison. AMOs on MMIO are undefined by spec but we preserve the
  // pre-existing "zero the BRAM write-enable" safety so a stray AMO cannot
  // corrupt an aliased BRAM word. Kept local so the dependency on
  // amo_mem_write_addr never reaches the SQ-only path.
  logic amo_mem_write_is_mmio;
  assign amo_mem_write_is_mmio =
      (amo_mem_write_addr >= XLEN'(MMIO_ADDR)) &&
      (amo_mem_write_addr <  (XLEN'(MMIO_ADDR) + XLEN'(MMIO_SIZE_BYTES)));

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
  // locally like amo_mem_write_is_mmio. A cached AMO write is masked off the
  // BRAM (so its aliased low word is never corrupted) and instead forwarded to
  // the cached tier just like a cached SQ store -- the AMO read-modify-write
  // must reach DDR or the modified value is lost. AMO MMIO writes stay
  // dropped (undefined by spec; the BRAM-mask safety is preserved).
  logic lq_mem_request_is_cached;
  assign lq_mem_request_is_cached =
      (lq_mem_request_addr_eff >= XLEN'(CACHED_BASE)) &&
      (lq_mem_request_addr_eff <  (XLEN'(CACHED_BASE) + XLEN'(CACHED_SIZE_BYTES)));

  logic amo_mem_write_is_cached;
  assign amo_mem_write_is_cached =
      (amo_mem_write_addr >= XLEN'(CACHED_BASE)) &&
      (amo_mem_write_addr <  (XLEN'(CACHED_BASE) + XLEN'(CACHED_SIZE_BYTES)));

  // Cached AMO write handshake. The LQ holds i_amo_mem_write_en high for the
  // whole AMO write phase (until it sees o_amo_mem_write_done), but the
  // cached_tier_adapter must see the byte-write-enable as a SINGLE-CYCLE pulse
  // (it re-enqueues on every cycle the strobe is non-zero). amo_cached_inflight
  // is set the cycle a cached AMO write is launched to the adapter and held
  // until the adapter pulses i_cached_write_done, suppressing re-launch in
  // between. A non-cached AMO never sets it (its done is combinational).
  logic amo_cached_inflight;
  logic amo_cached_write_launch;
  assign amo_cached_write_launch =
      amo_mem_write_en && amo_mem_write_is_cached && !amo_cached_inflight;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      amo_cached_inflight <= 1'b0;
    end else if (amo_cached_write_launch) begin
      amo_cached_inflight <= 1'b1;
    end else if (i_cached_write_done) begin
      amo_cached_inflight <= 1'b0;
    end
  end

  // A cached store owns the write port from its fire (sq_mem_write_en) until
  // its done pulse (i_cached_write_inflight covers every cycle in between).
  // These three busy terms are a strict subset of the integrated LQ's bus-busy
  // gate, so the LQ normally holds such reads upstream. The legacy replay path
  // remains supported at this standalone boundary; the intentional integrated
  // use of the register is a drain-blocked MMIO handoff. Its registered pending
  // Q feeds directly back to the LQ bus-busy gate so the hold cannot be
  // overwritten.
  assign write_port_busy = sq_mem_write_en || amo_mem_write_en || i_cached_write_inflight;

  // Legacy port arbitration candidate, before the device-order fence. The
  // explicit terminal LUT below is the only consumer of committed-empty in
  // the read path: every downstream read effect derives from its accept.
  assign lq_mem_read_candidate = !write_port_busy && (lq_mem_request_valid || lq_mem_read_en);
`ifdef FROST_XILINX_PRIMS
  // INIT=A2 implements I0 & (!I1 | I2): accept the ordinary candidate unless
  // it targets the device quadrant while a committed store remains undrained.
  (* dont_touch = "true" *)
  LUT3 #(
      .INIT(8'hA2)
  ) u_mmio_drain_accept_gate (
      .I0(lq_mem_read_candidate),
      .I1(lq_mem_request_requires_drain),
      .I2(i_sq_committed_empty),
      .O (lq_mem_read_accepted)
  );
`else
  assign lq_mem_read_accepted =
      lq_mem_read_candidate &&
      (!lq_mem_request_requires_drain || i_sq_committed_empty);
`endif

  always_comb begin
    // Load queue memory read. An ordinary request bypasses the one-entry hold
    // when the port is free. A write conflict or closed device-drain fence
    // parks it; only the terminal accepted pulse can reach memory or MMIO.
    o_data_mem_read_enable = lq_mem_read_accepted;

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
                                amo_mem_write_en ?
                                amo_write_strobes : '0;
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
            amo_write_strobes : '0;

    // Cached-tier byte-write-enable: a cached SQ store, or the single-cycle
    // launch pulse of a cached AMO write (word-width). The launch qualifier
    // (amo_cached_write_launch) drops once amo_cached_inflight is set, so the
    // held i_amo_mem_write_en presents exactly one strobe to the adapter. SQ
    // and AMO writes are mutually exclusive at the cached tier: AMOs issue only
    // at the ROB head with an empty SQ, so a cached SQ store can never be
    // draining while a cached AMO write is in flight.
    o_data_mem_cached_byte_wr_en =
        (sq_mem_write_en && sq_mem_write_is_cached) ? sq_mem_write_byte_en :
        amo_cached_write_launch ?
            amo_write_strobes : '0;

    // Cached-tier write data: SQ-store drain data normally; the AMO new value
    // on the launch pulse. Off the BRAM WEA cone (separate cached-only port).
    o_data_mem_cached_wr_data = amo_cached_write_launch ? amo_mem_write_data : sq_mem_write_data;

    // Cached-tier read enable: the accepted-load pulse qualified by is_cached.
    // The enable lands on the adapter's request register (not a memory enable
    // cascade) and the 1 GiB decode is a 2-bit compare, so qualification is
    // cheap -- and required, since a cache lookup has side effects
    // (miss/fill/evict) and must not fire for low-BRAM loads.
    o_data_mem_cached_read_enable = o_data_mem_read_enable && lq_mem_request_is_cached;

    // AMO write completion. Fast tier (BRAM): the write lands the same cycle,
    // so done is combinational as before. Cached tier: the adapter completes
    // the line write with a variable-latency i_cached_write_done pulse, so the
    // cached AMO done is sourced from that (the LQ holds the write request until
    // it sees done, keeping its result/cache-invalidate ordering correct).
    amo_mem_write_done = !sq_mem_write_en && amo_mem_write_en &&
                         (amo_mem_write_is_cached ? i_cached_write_done : 1'b1);

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
  //
  // There is intentionally no flush input here. In the integrated CPU, a
  // drain-parked device request owns the incomplete ROB head: MRET, FENCE.I,
  // and commit-time recovery cannot pass it, while a trap waits for the same
  // committed-empty bit that accepts this request and only raises the
  // registered full-flush pulse on the following cycle. Reset is the only
  // pre-accept cancellation boundary. The LQ's stale-response drain handles
  // the already-accepted interrupt race documented in load_queue/README.md.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      lq_mem_request_valid <= 1'b0;
    end else begin
      // One-entry conservation: a live/held request remains pending until the
      // terminal accept fires. This registered Q feeds directly back to the LQ
      // bus-busy gate, so it cannot present a second request while this bit is
      // set (including throughout the accept cycle).
      lq_mem_request_valid <= (lq_mem_request_valid || lq_mem_read_en) && !lq_mem_read_accepted;
    end
  end

  // Continuously shadow the live address while the hold is empty. On the edge
  // that a request becomes blocked this captures the exact request, but the
  // 64-bit register-enable cone depends only on the local pending Q -- never on
  // write arbitration, address decode, or committed-empty. Accepted bypasses
  // also update this don't-care shadow and otherwise remain unregistered.
  always_ff @(posedge i_clk) begin
    if (!lq_mem_request_valid) begin
      lq_mem_request_addr <= lq_mem_read_addr;
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // The registered-pending feedback contract makes this one-entry boundary
  // lossless. Catch any future producer change that presents a second request
  // while the held one is pending.
  always @(posedge i_clk) begin
    if (!i_rst && lq_mem_request_valid && lq_mem_read_en)
      $error("data_mem_request_router: live LQ read overlapped held request");
  end
`endif
`endif

  // Per-tier memory read response timing.
  //
  // Two independent valid taps that, by construction, never assert in the same
  // cycle (the load queue's cached single-outstanding gate and this router's
  // registered-pending feedback block conflicting launches, and only one read
  // is accepted per cycle):
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
  assign lq_mem_read_data  = i_cached_read_valid ? i_cached_read_data : i_data_mem_rd_data;

  // MMIO read pulse.  Read side effects are driven only by LQ reads; using the
  // full data-port address mux here needlessly pulls SQ/AMO write addresses
  // into FIFO/UART consume-pulse timing.
  assign o_mmio_read_pulse = lq_mem_read_accepted && lq_mem_request_is_mmio;

  // Register destructive MMIO read side effects inside the router so the
  // LQ/AMO arbitration cone stops at local flops instead of crossing back out
  // to the top-level FIFO/UART pulse registers.  The load data itself is still
  // sampled by cpu_and_mem on o_mmio_read_pulse, so the visible load response
  // timing is unchanged.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_mmio_fifo0_read_pulse <= 1'b0;
      o_mmio_fifo1_read_pulse <= 1'b0;
      o_mmio_uart_rx_ready_pulse <= 1'b0;
    end else begin
      o_mmio_fifo0_read_pulse <= o_mmio_read_pulse && (lq_mem_request_addr_eff == Fifo0MmioAddr);
      o_mmio_fifo1_read_pulse <= o_mmio_read_pulse && (lq_mem_request_addr_eff == Fifo1MmioAddr);
      o_mmio_uart_rx_ready_pulse <= o_mmio_read_pulse &&
                                    (lq_mem_request_addr_eff == UartRxDataMmioAddr);
    end
  end

  // --- Output wiring.
  // The adapter's cached done is shared by cached SQ stores and cached AMO
  // writes (the adapter cannot tell them apart). They are mutually exclusive
  // (an AMO issues only at the ROB head with an empty SQ), so steer a cached
  // done to the SQ only when no cached AMO write is in flight, and to the AMO
  // path otherwise (amo_mem_write_done already qualifies it).
  assign o_sq_mem_write_done = sq_write_done_fast | (i_cached_write_done && !amo_cached_inflight);
  assign o_amo_mem_write_done = amo_mem_write_done;
  assign o_lq_mem_request_valid = lq_mem_request_valid;
  assign o_lq_mem_read_data = lq_mem_read_data;
  assign o_lq_mem_read_valid = lq_mem_read_valid;

`ifdef FORMAL
  initial assume (i_rst);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  logic f_device_park_seen;
  always @(posedge i_clk) begin
    if (i_rst) begin
      f_device_park_seen <= 1'b0;
    end else if (lq_mem_request_valid && lq_mem_request_requires_drain &&
                 !i_sq_committed_empty) begin
      f_device_park_seen <= 1'b1;
    end
  end

  // Producer protocol: the registered pending Q is fed directly into the
  // integrated LQ's bus-busy launch gate. The ordinary write-conflict queue is
  // also unreachable from that gate. Consequently the one-entry hold is never
  // offered a second request. The wrapper proves the feedback half of this
  // assume/guarantee contract.
  always_comb begin
    if (!i_rst && lq_mem_request_valid) begin
      a_no_live_read_while_held : assume (!lq_mem_read_en);
    end
  end

  // The explicit primitive and portable fallback implement one terminal
  // decision, and every externally visible read effect is qualified by it.
  always_comb begin
    if (!i_rst) begin
      p_read_accept_equivalent :
      assert (lq_mem_read_accepted ==
              (lq_mem_read_candidate &&
               (!lq_mem_request_requires_drain || i_sq_committed_empty)));
      p_data_read_is_accept : assert (o_data_mem_read_enable == lq_mem_read_accepted);
      p_cached_read_is_accept :
      assert (o_data_mem_cached_read_enable == (lq_mem_read_accepted && lq_mem_request_is_cached));
      p_mmio_valid_is_accept :
      assert (o_mmio_load_valid == (lq_mem_read_accepted && lq_mem_request_is_mmio));
      p_mmio_pulse_is_accept :
      assert (o_mmio_read_pulse == (lq_mem_read_accepted && lq_mem_request_is_mmio));
      if (lq_mem_read_accepted && lq_mem_request_requires_drain) begin
        p_device_accept_needs_sq_drain : assert (i_sq_committed_empty);
      end
      if (o_mmio_read_pulse) begin
        p_mmio_effect_needs_sq_drain : assert (i_sq_committed_empty);
      end
    end
  end

  always @(posedge i_clk) begin
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      // Exact one-entry conservation and stable held payload.
      p_pending_conservation :
      assert (lq_mem_request_valid == (($past(
          lq_mem_request_valid
      ) || $past(
          lq_mem_read_en
      )) && !$past(
          lq_mem_read_accepted
      )));
      if ($past(lq_mem_request_valid && !lq_mem_read_accepted)) begin
        p_blocked_request_remains_pending : assert (lq_mem_request_valid);
        p_blocked_request_addr_stable : assert (lq_mem_request_addr == $past(lq_mem_request_addr));
      end
      if ($past(!lq_mem_request_valid)) begin
        p_empty_hold_shadows_live_addr : assert (lq_mem_request_addr == $past(lq_mem_read_addr));
      end

      // Fast responses and destructive sidebands can only follow an accepted
      // request; a parked request cannot seed either pipeline.
      p_fast_valid_follows_accept : assert (fast_read_valid == $past(fast_read_accepted));
      p_fifo0_pulse_follows_accept :
      assert (o_mmio_fifo0_read_pulse == $past(
          o_mmio_read_pulse && (lq_mem_request_addr_eff == Fifo0MmioAddr)
      ));
      p_fifo1_pulse_follows_accept :
      assert (o_mmio_fifo1_read_pulse == $past(
          o_mmio_read_pulse && (lq_mem_request_addr_eff == Fifo1MmioAddr)
      ));
      p_uart_rx_pulse_follows_accept :
      assert (o_mmio_uart_rx_ready_pulse == $past(
          o_mmio_read_pulse && (lq_mem_request_addr_eff == UartRxDataMmioAddr)
      ));
    end

    if (f_past_valid && $past(i_rst)) begin
      p_reset_clears_pending : assert (!lq_mem_request_valid);
      p_reset_clears_fast_valid : assert (!fast_read_valid);
      p_reset_clears_destructive_pulses :
      assert (!o_mmio_fifo0_read_pulse && !o_mmio_fifo1_read_pulse && !o_mmio_uart_rx_ready_pulse);
    end

    if (!i_rst) begin
      // Exercise a drain-only park followed by the exact terminal release.
      cover_device_park :
      cover (lq_mem_request_valid && lq_mem_request_requires_drain &&
             !i_sq_committed_empty && !write_port_busy);
      cover_device_park_release :
      cover (f_device_park_seen && lq_mem_read_accepted &&
             lq_mem_request_requires_drain && i_sq_committed_empty);
      cover_write_and_drain_park :
      cover (lq_mem_request_valid && lq_mem_request_requires_drain &&
             !i_sq_committed_empty && write_port_busy);
    end
  end
`endif  // FORMAL

endmodule : data_mem_request_router
