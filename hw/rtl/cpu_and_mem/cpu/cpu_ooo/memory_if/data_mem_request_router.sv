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
 * Data-memory request router: arbitrates the single data-memory port among
 * store queue (SQ) writes, atomic-unit (AMO) writes, and load queue (LQ)
 * reads, in that priority.
 *
 * Low-BRAM and cached loads are accepted in the cycle they arrive unless a
 * write holds the port or a flush is active. A device-quadrant load always
 * waits first in a one-entry request register and is accepted only from
 * there, once the port is free, every committed store has drained, and the
 * request is armed behind cpu_ooo's device-read interrupt shield
 * (device_accept_armed_q). Arming only adds a precondition: the flush,
 * write-port, and drain conditions are still checked in the accept cycle. The
 * register's valid bit feeds back to the LQ's bus-busy gate, so the LQ never
 * presents a second request while one is held. See also "Device loads" in the
 * load queue README.
 *
 * Cached-tier accesses go through cached_tier_adapter and complete by
 * handshake: reads return tagged with their LQ slot id, one outstanding per
 * slot, and the fast tier's fixed-latency response takes the LQ response port
 * first while the adapter holds a cached one (o_cached_read_ready). While a
 * cached store is pending, i_cached_write_inflight keeps the write port busy.
 */

module data_mem_request_router #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned MMIO_ADDR = 32'h4000_0000,
    parameter int unsigned MMIO_SIZE_BYTES = 32'h2C,
    // Cached tier: loads and stores to [CACHED_BASE, CACHED_BASE +
    // CACHED_SIZE_BYTES) are served by the cache hierarchy with variable
    // latency.
    parameter int unsigned CACHED_BASE = 32'h8000_0000,
    parameter int unsigned CACHED_SIZE_BYTES = 32'h4000_0000
) (
    input logic i_clk,
    input logic i_rst,
    // The flush that clears the LQ: a full pipeline flush or commit-time
    // recovery. It cancels a held request that has not been accepted, and the
    // LQ then expects no response for it.
    input logic i_flush_all,

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
    // Registered cached-tier flag for the AMO write, like the SQ's. The load
    // queue decodes the cached range from the address it captures into
    // i_amo_mem_write_addr, on the same edge, so the flag matches that address
    // on every cycle the enable is high; an AMO never targets a device (its
    // PMA check faults first). TIMING: keeps the range compare out of the
    // BRAM WEA and debug-mirror cone.
    input logic                              i_amo_mem_write_is_cached,

    // Load-queue read request. The slot id tags a cached read for the
    // adapter (don't-care for the fast tier).
    input logic                                     i_lq_mem_read_en,
    input logic [                         XLEN-1:0] i_lq_mem_read_addr,
    input logic                                     i_lq_mem_addr_valid,
    input logic [riscv_pkg::CachedLoadSlotBits-1:0] i_lq_mem_read_id,
    // Registered SQ status, high only when no committed-but-unwritten store
    // remains. Same-cycle raw commits already clear it pessimistically. Do not
    // pipeline it again, or a stale-high cycle can release a device read.
    input logic                                     i_sq_committed_empty,

    // External data memory read data. BRAM data is combinational the cycle
    // after a read is accepted. The cpu_and_mem mux folds in registered MMIO
    // read data.
    input  logic [       riscv_pkg::MemDataBits-1:0] i_data_mem_rd_data,
    // Cached-tier completion (from cached_tier_adapter): handshake pulses with
    // variable latency, plus the write-inflight hold.
    input  logic [       riscv_pkg::MemDataBits-1:0] i_cached_read_data,
    input  logic [riscv_pkg::CachedLoadSlotBits-1:0] i_cached_read_id,
    input  logic                                     i_cached_read_valid,
    output logic                                     o_cached_read_ready,
    // A cached response is being held behind the fast beat this cycle. The
    // load queue registers it into its launch hold so a run of back-to-back
    // fast launches cannot starve the held response: one skipped launch
    // opens the response port.
    output logic                                     o_cached_read_held,
    input  logic                                     i_cached_write_done,
    input  logic                                     i_cached_write_inflight,

    // External data memory port.
    output logic [                         XLEN-1:0] o_data_mem_addr,
    output logic [       riscv_pkg::MemDataBits-1:0] o_data_mem_wr_data,
    output logic [       riscv_pkg::MemStrbBits-1:0] o_data_mem_per_byte_wr_en,
    output logic [       riscv_pkg::MemStrbBits-1:0] o_data_mem_bram_byte_wr_en,
    // |o_data_mem_bram_byte_wr_en, built from the arbitration terms rather
    // than by reducing the eight strobes. TIMING: the debug-mode store mirror
    // (cpu_and_mem) needs "any low-BRAM byte written" on its slice-writer
    // FIFO write enable; deriving it here keeps that enable two LUT levels
    // from the source registers instead of reducing the strobe cone again.
    output logic                                     o_data_mem_bram_write_any,
    output logic                                     o_data_mem_read_enable,
    // Cached-tier write/read requests (asserted only for cached-range accesses).
    output logic [       riscv_pkg::MemStrbBits-1:0] o_data_mem_cached_byte_wr_en,
    // Cached-tier write data: SQ-store drain data, or the AMO new value on the
    // single cycle a cached AMO write is launched to the adapter.
    output logic [       riscv_pkg::MemDataBits-1:0] o_data_mem_cached_wr_data,
    output logic                                     o_data_mem_cached_read_enable,
    output logic [riscv_pkg::CachedLoadSlotBits-1:0] o_data_mem_cached_read_id,
    output logic                                     o_mmio_read_pulse,
    output logic [                         XLEN-1:0] o_mmio_load_addr,
    output logic                                     o_mmio_load_valid,
    output logic                                     o_mmio_fifo0_read_pulse,
    output logic                                     o_mmio_fifo1_read_pulse,
    output logic                                     o_mmio_uart_rx_ready_pulse,

    // Status back to SQ / AMO / LQ.
    output logic                                     o_sq_mem_write_done,
    output logic                                     o_amo_mem_write_done,
    // The request register's valid bit, fed back into the LQ's bus-busy gate.
    // It stays high through the accept cycle.
    output logic                                     o_lq_mem_request_valid,
    // High while a device-quadrant request is held. cpu_ooo raises its
    // device-read interrupt shield from it.
    output logic                                     o_device_request_pending,
    output logic [       riscv_pkg::MemDataBits-1:0] o_lq_mem_read_data,
    output logic                                     o_lq_mem_read_valid,
    // Source of this cycle's read response: a cached slot (with its id) or
    // the fast tier's single outstanding request.
    output logic                                     o_lq_mem_read_is_cached,
    output logic [riscv_pkg::CachedLoadSlotBits-1:0] o_lq_mem_read_id
);

  // --- Port aliases.
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
  logic                              amo_mem_write_is_cached;
  logic                              lq_mem_read_en;
  logic [                  XLEN-1:0] lq_mem_read_addr;
  logic                              lq_mem_addr_valid;
  assign sq_mem_write_en         = i_sq_mem_write_en;
  assign sq_mem_write_addr       = i_sq_mem_write_addr;
  assign sq_mem_write_data       = i_sq_mem_write_data;
  assign sq_mem_write_byte_en    = i_sq_mem_write_byte_en;
  assign sq_mem_write_is_mmio    = i_sq_mem_write_is_mmio;
  assign sq_mem_write_is_cached  = i_sq_mem_write_is_cached;
  assign amo_mem_write_en        = i_amo_mem_write_en;
  assign amo_mem_write_addr      = i_amo_mem_write_addr;
  assign amo_mem_write_data      = i_amo_mem_write_data;
  assign amo_mem_write_is_dword  = i_amo_mem_write_is_dword;
  assign amo_mem_write_is_cached = i_amo_mem_write_is_cached;
  // AMO write strobes: word lanes for .W (by addr[2]); full beat for .D.
  logic [riscv_pkg::MemStrbBits-1:0] amo_write_strobes;
  assign amo_write_strobes = riscv_pkg::mem_strobe_for(
      amo_mem_write_is_dword ? 2'b11 : 2'b10, amo_mem_write_addr[2:0]
  );
  assign lq_mem_read_en = i_lq_mem_read_en;
  assign lq_mem_read_addr = i_lq_mem_read_addr;
  assign lq_mem_addr_valid = i_lq_mem_addr_valid;

  // Router-internal state and nets. Address constants use XLEN'() casts rather
  // than [XLEN-1:0] part-selects: MMIO_ADDR is a 32-bit int parameter, so a
  // 64-bit part-select of it would be out of range.
  localparam logic [XLEN-1:0] UartRxDataMmioAddr = XLEN'(MMIO_ADDR) + XLEN'(32'h4);
  localparam logic [XLEN-1:0] Fifo0MmioAddr = XLEN'(MMIO_ADDR) + XLEN'(32'h8);
  localparam logic [XLEN-1:0] Fifo1MmioAddr = XLEN'(MMIO_ADDR) + XLEN'(32'hC);

  logic                                     sq_write_done_fast;
  logic                                     write_port_busy;
  logic                                     amo_mem_write_done;
  logic                                     lq_mem_request_valid;
  logic [                         XLEN-1:0] lq_mem_request_addr;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] lq_mem_request_id;
  logic [riscv_pkg::CachedLoadSlotBits-1:0] lq_mem_request_id_eff;
  logic [                         XLEN-1:0] lq_mem_request_addr_eff;
  logic [       riscv_pkg::MemDataBits-1:0] lq_mem_read_data;
  logic                                     lq_mem_read_valid;
  logic                                     lq_pending_request_is_mmio;
  logic                                     lq_live_request_requires_park;
  logic                                     lq_pending_request_requires_drain;
  logic                                     lq_live_read_accepted;
  logic                                     lq_pending_read_candidate;
  logic                                     lq_pending_read_accepted;
  logic                                     lq_pending_read_shielded;
  logic                                     device_request_pending_q;
  logic                                     device_accept_armed_q;
  logic                                     lq_pending_mmio_read_accepted;
  logic                                     lq_mem_read_accepted;

  // Effective queued-load address: held copy if a request is pending, else the
  // live LQ read address.
  assign lq_mem_request_addr_eff = lq_mem_request_valid ? lq_mem_request_addr : lq_mem_read_addr;
  // The cached-load slot id travels with the request the same way: a parked
  // load must reach the adapter under its own id, not the one presented
  // live on the accept cycle.
  assign lq_mem_request_id_eff = lq_mem_request_valid ? lq_mem_request_id : i_lq_mem_read_id;
  // Served MMIO window (register window + PLIC window, riscv_pkg).
  assign lq_pending_request_is_mmio = riscv_pkg::mmio_window_hit(
      lq_mem_request_addr, XLEN'(MMIO_ADDR), XLEN'(MMIO_SIZE_BYTES)
  );

  // Device ordering uses the LQ's device-quadrant classification, which is
  // broader than the served MMIO window above. The live decode only blocks
  // the bypass so the request is captured; acceptance uses the same two-bit
  // decode of the held address, so no live LQ signal reaches an MMIO effect.
  assign lq_live_request_requires_park = (lq_mem_read_addr[31:30] == 2'b01);
  assign lq_pending_request_requires_drain = (lq_mem_request_addr[31:30] == 2'b01);

  // -------------------------------------------------------------------------
  // Tier decode.
  //
  // Read side: is_cached for the load address (held or live). For the
  // default aligned 1 GiB region the range compare reduces to an equality
  // test of addr[XLEN-1:30], so the decode stays off any timing-critical
  // cone. It feeds the cached read enable, which lands on the adapter's
  // request register rather than a memory enable cascade, and the fast-tier
  // response valid.
  //
  // Write side: the tier flags arrive registered, the SQ's computed at its
  // drain and the AMO's captured by the load queue beside the write address,
  // so no address-range compare reaches the BRAM WEA pins. A cached write,
  // SQ or AMO, is kept off the BRAM, where it would corrupt the word its
  // address aliases, and goes to the cached tier instead; an AMO's
  // read-modify-write result is lost unless it reaches the cache hierarchy.
  // An AMO never targets a device, so a non-cached AMO write goes to the BRAM.
  // Like any write it also appears on o_data_mem_per_byte_wr_en, where the
  // device decodes in cpu_and_mem never match its address.
  logic lq_mem_request_is_cached;
  assign lq_mem_request_is_cached =
      (lq_mem_request_addr_eff >= XLEN'(CACHED_BASE)) &&
      (lq_mem_request_addr_eff <  (XLEN'(CACHED_BASE) + XLEN'(CACHED_SIZE_BYTES)));

  // Cached AMO write handshake. The LQ holds i_amo_mem_write_en high for the
  // whole AMO write phase, until it sees o_amo_mem_write_done, but the
  // cached_tier_adapter must see a one-cycle strobe, since it takes every
  // cycle with a nonzero strobe as a new store. amo_cached_inflight is set by
  // the launch and held until the adapter pulses i_cached_write_done, which
  // suppresses a relaunch in between. A non-cached AMO never sets it, since
  // its done is combinational.
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

  // A cached store holds the write port from its fire (sq_mem_write_en) until
  // its done pulse; i_cached_write_inflight covers every cycle in between.
  // The LQ's bus-busy gate includes all three terms, so in the core no load
  // arrives while the port is busy, and only device reads use the request
  // register (for their staging and arming cycles and any drain wait). A load
  // that does arrive while the port is busy waits in the register.
  assign write_port_busy = sq_mem_write_en || amo_mem_write_en || i_cached_write_inflight;

  // Low-BRAM write selects. Every term is a flop (SQ outputs, the LQ's
  // one-hot AMO state and its registered cached-tier flag), so each select is
  // one LUT from registered state.
  logic sq_bram_write;
  logic amo_bram_write;
  assign sq_bram_write = sq_mem_write_en && !sq_mem_write_is_mmio && !sq_mem_write_is_cached;
  assign amo_bram_write = amo_mem_write_en && !amo_mem_write_is_cached;

  // Low-BRAM and cached reads can be accepted live. Device-quadrant reads
  // never are, even with every blocker open: they are captured into the
  // request register first and accepted only from there.
  assign lq_live_read_accepted =
      !i_rst && !i_flush_all && !write_port_busy && lq_mem_read_en &&
      !lq_live_request_requires_park;
  assign lq_pending_read_candidate =
      !i_rst && !i_flush_all && !write_port_busy && lq_mem_request_valid;
  assign lq_pending_read_shielded =
      lq_pending_read_candidate &&
      (!lq_pending_request_requires_drain || i_sq_committed_empty);
`ifdef FROST_XILINX_PRIMS
  // INIT=A222 implements I0 & (!I1 | (I2 & I3)): accept the pending candidate
  // unless the held request is in the device quadrant, in which case the
  // committed stores must have drained and the read must be armed behind the
  // interrupt shield. Both device conditions share one isolated LUT at the
  // end of the read-enable cone, so arming adds no logic level on the BRAM
  // enable path. I0, I1 and I3 all derive from registered state. The portable
  // lq_pending_read_shielded above is unused here and optimizes away.
  (* dont_touch = "true" *)
  LUT4 #(
      .INIT(16'hA222)
  ) u_mmio_drain_accept_gate (
      .I0(lq_pending_read_candidate),
      .I1(lq_pending_request_requires_drain),
      .I2(i_sq_committed_empty),
      .I3(device_accept_armed_q),
      .O (lq_pending_read_accepted)
  );
`else
  // Device-read interrupt shield gate, on top of the drain gate above. The
  // armed bit only adds a precondition and never replaces one, because the
  // arming cycle's view can go stale: before the accept, i_sq_committed_empty
  // may fall, write_port_busy may rise, or a flush may arrive, and each still
  // blocks the accept here (p_arming_only_restricts below).
  assign lq_pending_read_accepted =
      lq_pending_read_shielded &&
      (!lq_pending_request_requires_drain || device_accept_armed_q);
`endif
  assign lq_mem_read_accepted = lq_live_read_accepted || lq_pending_read_accepted;
  assign lq_pending_mmio_read_accepted = lq_pending_read_accepted && lq_pending_request_is_mmio;

  always_comb begin
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
    // BRAM byte-write-enable: MMIO and cached writes are masked with the
    // registered tier flags, so neither the data_memory_address mux nor an
    // address-range compare sits on the BRAM WEA path. A cached store must
    // not also land in the BRAM, where it would corrupt the word its address
    // aliases; it goes to the cached tier instead.
    o_data_mem_bram_byte_wr_en =
        sq_bram_write ? sq_mem_write_byte_en :
        amo_bram_write ? amo_write_strobes : '0;
    // Any low-BRAM byte written: |o_data_mem_bram_byte_wr_en by the mux
    // identity |(s ? a : b) == (s ? |a : |b), with the AMO leg folded to its
    // select because an AMO strobe is never zero (mem_strobe_for: word lanes
    // 8'h0F / 8'hF0, dword 8'hFF). The FORMAL block below pins the identity.
    o_data_mem_bram_write_any = sq_bram_write ? (|sq_mem_write_byte_en) : amo_bram_write;

    // Cached-tier byte-write-enable: a cached SQ store, or the one-cycle
    // launch of a cached AMO write. amo_cached_write_launch drops once
    // amo_cached_inflight is set, so the held i_amo_mem_write_en presents
    // exactly one strobe to the adapter. SQ and AMO writes never overlap at
    // the cached tier: an AMO issues only at the ROB head after every
    // committed store has been written, so no SQ store can drain while a
    // cached AMO write is in flight.
    o_data_mem_cached_byte_wr_en =
        (sq_mem_write_en && sq_mem_write_is_cached) ? sq_mem_write_byte_en :
        amo_cached_write_launch ?
            amo_write_strobes : '0;

    // Cached-tier write data: SQ-store drain data, or the AMO new value on the
    // launch pulse. This is a separate cached-only port, off the BRAM WEA cone.
    o_data_mem_cached_wr_data = amo_cached_write_launch ? amo_mem_write_data : sq_mem_write_data;

    // Cached-tier read enable: the accept qualified by is_cached (cheap; see
    // the tier decode). The qualifier is required, since a cache lookup has
    // side effects (miss, fill, eviction) and must not fire for other loads.
    o_data_mem_cached_read_enable = o_data_mem_read_enable && lq_mem_request_is_cached;
    o_data_mem_cached_read_id = lq_mem_request_id_eff;

    // AMO write completion. Fast tier (BRAM): the write lands the same cycle,
    // so done is combinational. Cached tier: the adapter completes the line
    // write with a variable-latency i_cached_write_done pulse, and the cached
    // AMO done is sourced from that. The LQ holds the write request until it
    // sees done, which keeps its result/cache-invalidate ordering intact.
    amo_mem_write_done = !sq_mem_write_en && amo_mem_write_en &&
                         (amo_mem_write_is_cached ? i_cached_write_done : 1'b1);

    o_mmio_load_addr = lq_mem_request_addr;
    o_mmio_load_valid = lq_pending_mmio_read_accepted;
  end

  // SQ write-done timing. Fast tier (BRAM or MMIO): done one cycle after the
  // SQ fires. Cached tier: the adapter pulses i_cached_write_done once the L1D
  // has ordered the store, meaning a write hit has been applied or a write
  // miss has been absorbed into a miss-status slot whose fill will merge it;
  // the store need not have reached DDR. The done lets the SQ retire the
  // metadata-FIFO-head entry and its in-flight accounting, and releases the
  // cache-invalidate. That is all the ordering it needs: a younger
  // same-address load cannot issue to memory until the older store leaves the
  // SQ (load_queue.sv), and the L1D, the hart's ordering point, serves every
  // later read of that line from the merged data.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      sq_write_done_fast <= 1'b0;
    end else begin
      sq_write_done_fast <= sq_mem_write_en && !sq_mem_write_is_cached;
    end
  end

  // Request register valid bit.
  //
  // Reset and i_flush_all cancel a held request before it is accepted. An
  // interrupt taken before the shield is up can raise the registered full
  // flush while a device request is held. That flush blocks the accept
  // combinationally and clears this bit at the edge; the LQ sees the bit
  // still set on that edge, so it does not wait to drop a response for it. A
  // request that was already accepted has this bit low, and the LQ drains its
  // response through its normal flush accounting.
  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush_all) begin
      lq_mem_request_valid <= 1'b0;
    end else begin
      // A live or held request stays pending until it is accepted. The LQ's
      // bus-busy gate sees this bit, so no second request arrives while it is
      // set, including in the accept cycle.
      lq_mem_request_valid <= (lq_mem_request_valid || lq_mem_read_en) && !lq_mem_read_accepted;
    end
  end

  // Registered state only (valid bit AND two held address bits), so it can
  // feed cpu_ooo's shield register without exporting any live cone.
  assign o_device_request_pending = lq_mem_request_valid && lq_pending_request_requires_drain;

  // One-cycle history of o_device_request_pending.
  //
  // cpu_ooo's shield register sets from the same signal and, like this bit,
  // clears on reset and i_flush_all, so the shield is set whenever this bit
  // is. The router thus knows the trap unit is already holding interrupts
  // without taking the shield back as an input, which keeps the trap unit the
  // shield's only consumer and avoids a cpu_ooo-to-router feedback net.
  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush_all) device_request_pending_q <= 1'b0;
    else device_request_pending_q <= o_device_request_pending;
  end

  // Device-read arming register.
  //
  // A device read is irrevocable once accepted. An interrupt taken on the
  // accept edge, or at any point before the load commits, would flush the
  // load and re-execute it after the trap, repeating the destructive read
  // (UART RX pop, FIFO pop, clear-on-read). The trap unit therefore holds
  // interrupts across that window (i_device_read_at_head), as it does for
  // AMOs (i_amo_at_head).
  //
  // The hold must be up before the read fires, so a device request is
  // accepted only once this register is set, and it sets only after the
  // request has been pending for a full cycle, when cpu_ooo's shield register
  // is already holding interrupts off. For a device handoff:
  //
  //   N   : the LQ hands off the load at the ROB head; the valid bit sets at
  //         the edge.
  //   N+1 : o_device_request_pending is high; cpu_ooo's shield register sets.
  //   N+2 : the trap unit sees the shield; device_request_pending_q is high,
  //         so this register sets at the edge.
  //   N+3 : accept, with interrupts already held.
  //
  // The last cycle an interrupt can still be taken is N+1. Its registered
  // flush arrives at N+2, where it blocks arming and clears the valid bit,
  // canceling the request before accept with no response owed. From N+2 on
  // the trap unit takes no interrupt, so no flush can land between the
  // accept and the load's commit. Exceptions stay enabled, as with the AMO
  // shield: the load is at the ROB head, and a device load that faults
  // completes with its exception inside the LQ, without a router handoff.
  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush_all) begin
      device_accept_armed_q <= 1'b0;
    end else begin
      device_accept_armed_q <= o_device_request_pending && !write_port_busy &&
                               i_sq_committed_empty && device_request_pending_q;
    end
  end

  // Shadow the live address and slot id on every cycle the register is empty.
  // On the edge a request is blocked or starts its device staging cycle this
  // captures exactly that request, and the enable depends only on the local
  // valid bit, not on write arbitration, address decode, committed-empty,
  // reset, or flush. After a live accept or a cancellation the shadow is
  // don't-care, since only the valid bit says the address is meaningful.
  always_ff @(posedge i_clk) begin
    if (!lq_mem_request_valid) begin
      lq_mem_request_addr <= lq_mem_read_addr;
      lq_mem_request_id   <= i_lq_mem_read_id;
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // The LQ's bus-busy gate includes the valid bit, so the one-entry register
  // never receives a second request while it holds one. Check that contract.
  always @(posedge i_clk) begin
    if (!i_rst && lq_mem_request_valid && lq_mem_read_en)
      $error("data_mem_request_router: live LQ read overlapped held request");
  end
`endif
`endif

  // Read response timing.
  //
  // Two sources share the single LQ response port. The fast tier's
  // fixed-latency response cannot wait, so it wins and the adapter holds a
  // cached response for that cycle (o_cached_read_ready):
  //
  //   * Fast path (BRAM and MMIO): the external BRAM returns data exactly one
  //     cycle after a non-cached read is accepted. fast_read_valid is the
  //     accept pulse, qualified !is_cached, delayed one cycle, and the data
  //     comes combinationally from i_data_mem_rd_data. A low-BRAM read can
  //     be accepted live; a device read spends its staging and arming cycles
  //     in the request register first.
  //
  //   * Cached path: the adapter presents i_cached_read_valid with
  //     i_cached_read_data and i_cached_read_id when the cache hierarchy
  //     completes the load, a hit after a few cycles or a miss after a
  //     writeback/fill round trip, and holds it until accepted here.
  logic fast_read_accepted;
  assign fast_read_accepted = lq_mem_read_accepted && !lq_mem_request_is_cached;

  // Fast (BRAM/MMIO) 1-cycle valid.
  logic fast_read_valid;
  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush_all) fast_read_valid <= 1'b0;
    else fast_read_valid <= fast_read_accepted;
  end

  // Fast first: a cached response waits out a fast cycle. The held flag keeps
  // that wait bounded without touching the accept cone. The load queue
  // registers it.
  assign o_cached_read_ready = !fast_read_valid;
  assign o_cached_read_held = i_cached_read_valid && fast_read_valid;
  assign lq_mem_read_valid = fast_read_valid | i_cached_read_valid;
  assign lq_mem_read_data = fast_read_valid ? i_data_mem_rd_data : i_cached_read_data;
  assign o_lq_mem_read_is_cached = !fast_read_valid && i_cached_read_valid;
  assign o_lq_mem_read_id = i_cached_read_id;

  // MMIO read pulse: only an accepted held request produces it, so no live
  // LQ address or request signal reaches this cone.
  assign o_mmio_read_pulse = lq_pending_mmio_read_accepted;

  // Destructive MMIO read side effects are registered here, so the LQ/AMO
  // arbitration cone ends at local flops instead of crossing out to the
  // top-level FIFO and UART pulse registers. cpu_and_mem samples the load
  // data on o_mmio_read_pulse; these pulses follow one cycle after the
  // accept, aligned with the fast-response valid.
  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush_all) begin
      o_mmio_fifo0_read_pulse <= 1'b0;
      o_mmio_fifo1_read_pulse <= 1'b0;
      o_mmio_uart_rx_ready_pulse <= 1'b0;
    end else begin
      o_mmio_fifo0_read_pulse <= o_mmio_read_pulse && (lq_mem_request_addr == Fifo0MmioAddr);
      o_mmio_fifo1_read_pulse <= o_mmio_read_pulse && (lq_mem_request_addr == Fifo1MmioAddr);
      o_mmio_uart_rx_ready_pulse <= o_mmio_read_pulse &&
                                    (lq_mem_request_addr == UartRxDataMmioAddr);
    end
  end

  // --- Output wiring.
  // The adapter's done serves both cached SQ stores and cached AMO writes,
  // which it cannot tell apart and which never overlap (see
  // o_data_mem_cached_byte_wr_en). It goes to the AMO path while a cached AMO
  // write is in flight (amo_mem_write_done already qualifies it) and to the
  // SQ otherwise.
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
    if (i_rst || i_flush_all) begin
      f_device_park_seen <= 1'b0;
    end else if (lq_mem_request_valid && lq_pending_request_requires_drain &&
                 !i_sq_committed_empty) begin
      f_device_park_seen <= 1'b1;
    end
  end

  // Producer contract: the LQ's bus-busy launch gate includes the valid bit
  // and every write-port term, so the one-entry register is never offered a
  // second request. tomasulo_wrapper proves the LQ side of this
  // assume/guarantee pair (p_router_pending_blocks_lq_handoff).
  always_comb begin
    if (!i_rst && lq_mem_request_valid) begin
      a_no_live_read_while_held : assume (!lq_mem_read_en);
    end
  end

  // The accept equations; the FROST_XILINX_PRIMS LUT implements the same
  // pending accept. Live low-BRAM and cached requests keep their bypass, but a
  // live device request has no effect until its address is in the register.
  always_comb begin
    if (!i_rst) begin
      p_live_read_accept_equivalent :
      assert (lq_live_read_accepted ==
              (!i_flush_all && !write_port_busy && lq_mem_read_en &&
               !lq_live_request_requires_park));
      p_pending_read_candidate_equivalent :
      assert (lq_pending_read_candidate ==
              (!i_flush_all && !write_port_busy && lq_mem_request_valid));
      p_pending_read_shielded_equivalent :
      assert (lq_pending_read_shielded ==
              (lq_pending_read_candidate &&
               (!lq_pending_request_requires_drain || i_sq_committed_empty)));
      p_pending_read_accept_equivalent :
      assert (lq_pending_read_accepted ==
              (lq_pending_read_shielded &&
               (!lq_pending_request_requires_drain || device_accept_armed_q)));
      // Arming only restricts: every accept also passes the drain gate
      // (lq_pending_read_shielded), so arming can remove accepts but never add
      // one.
      p_arming_only_restricts : assert (!lq_pending_read_accepted || lq_pending_read_shielded);
      // A device read is unreachable unless the interrupt shield was already
      // established when this request was armed.
      if (lq_pending_read_accepted && lq_pending_request_requires_drain) begin
        p_device_accept_needs_arm : assert (device_accept_armed_q);
      end
      p_read_accept_equivalent :
      assert (lq_mem_read_accepted == (lq_live_read_accepted || lq_pending_read_accepted));
      p_data_read_is_accept : assert (o_data_mem_read_enable == lq_mem_read_accepted);
      // The structural any-byte-written flag is exactly the strobe reduction,
      // for every strobe/width/address combination the inputs can present.
      p_bram_write_any_is_strobe_reduction :
      assert (o_data_mem_bram_write_any == (|o_data_mem_bram_byte_wr_en));
      p_cached_read_is_accept :
      assert (o_data_mem_cached_read_enable == (lq_mem_read_accepted && lq_mem_request_is_cached));
      p_mmio_valid_is_accept : assert (o_mmio_load_valid == lq_pending_mmio_read_accepted);
      p_mmio_pulse_is_accept : assert (o_mmio_read_pulse == lq_pending_mmio_read_accepted);
      p_mmio_addr_is_held : assert (o_mmio_load_addr == lq_mem_request_addr);
      if (!lq_mem_request_valid && lq_mem_read_en && lq_live_request_requires_park) begin
        p_live_device_handoff_not_accepted : assert (!lq_mem_read_accepted);
        p_live_device_handoff_has_no_read_effect :
        assert (!o_data_mem_read_enable && !o_data_mem_cached_read_enable &&
                !o_mmio_read_pulse && !o_mmio_load_valid);
      end
      if (lq_pending_read_accepted && lq_pending_request_requires_drain) begin
        p_device_accept_needs_sq_drain : assert (i_sq_committed_empty);
      end
      if (o_mmio_read_pulse) begin
        p_mmio_effect_is_registered_pending :
        assert (lq_mem_request_valid && lq_pending_request_is_mmio && lq_pending_read_accepted);
        p_mmio_effect_is_device : assert (lq_pending_request_requires_drain);
        p_mmio_effect_needs_sq_drain : assert (i_sq_committed_empty);
      end
    end
    if (i_rst || i_flush_all) begin
      p_reset_or_flush_suppresses_accept :
      assert (!lq_live_read_accepted && !lq_pending_read_candidate &&
              !lq_pending_read_shielded && !lq_pending_read_accepted &&
              !lq_mem_read_accepted);
      p_reset_or_flush_has_no_combinational_read_effect :
      assert (!o_data_mem_read_enable && !o_data_mem_cached_read_enable &&
              !o_mmio_read_pulse && !o_mmio_load_valid);
    end
  end

  always @(posedge i_clk) begin
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      // The valid bit follows its next-state equation, and a held request
      // keeps its address.
      p_pending_conservation :
      assert (lq_mem_request_valid == (!$past(
          i_flush_all
      ) && (($past(
          lq_mem_request_valid
      ) || $past(
          lq_mem_read_en
      )) && !$past(
          lq_mem_read_accepted
      ))));
      if ($past(!i_flush_all && lq_mem_request_valid && !lq_mem_read_accepted)) begin
        p_blocked_request_remains_pending : assert (lq_mem_request_valid);
        p_blocked_request_addr_stable : assert (lq_mem_request_addr == $past(lq_mem_request_addr));
      end
      if ($past(!lq_mem_request_valid)) begin
        p_empty_hold_shadows_live_addr : assert (lq_mem_request_addr == $past(lq_mem_read_addr));
      end
      if ($past(
              !i_flush_all && !lq_mem_request_valid && lq_mem_read_en &&
                lq_live_request_requires_park
          )) begin
        p_device_handoff_becomes_pending : assert (lq_mem_request_valid);
        p_device_handoff_captures_address : assert (lq_mem_request_addr == $past(lq_mem_read_addr));
      end
      if (i_flush_all && $past(
              !i_flush_all && !lq_mem_request_valid && lq_mem_read_en &&
                lq_live_request_requires_park
          )) begin
        p_flushed_device_handoff_is_pending_before_cancel_edge : assert (lq_mem_request_valid);
        p_flushed_device_handoff_has_no_accept_or_effect :
        assert (!lq_mem_read_accepted && !o_data_mem_read_enable &&
                !o_data_mem_cached_read_enable && !o_mmio_read_pulse &&
                !o_mmio_load_valid && !fast_read_valid &&
                !o_mmio_fifo0_read_pulse && !o_mmio_fifo1_read_pulse &&
                !o_mmio_uart_rx_ready_pulse);
      end

      // The arming bit follows its next-state equation. Setting it needs
      // device_request_pending_q in the previous cycle, when cpu_ooo's shield
      // register was therefore already set, so the interrupt hold is older
      // than any device read effect.
      p_arm_conservation :
      assert (device_accept_armed_q == (!$past(
          i_flush_all
      ) && $past(
          o_device_request_pending && !write_port_busy && i_sq_committed_empty &&
              device_request_pending_q
      )));
      if (device_accept_armed_q) begin
        p_arm_implies_two_cycle_pending : assert ($past(device_request_pending_q));
      end
      if (o_mmio_read_pulse) begin
        p_device_effect_had_two_cycle_pending : assert ($past(device_request_pending_q));
      end

      // Fast responses and destructive sidebands can only follow an accepted
      // request; a parked request cannot seed either pipeline.
      p_fast_valid_follows_accept : assert (fast_read_valid == $past(fast_read_accepted));
      p_fifo0_pulse_follows_accept :
      assert (o_mmio_fifo0_read_pulse == $past(
          o_mmio_read_pulse && (lq_mem_request_addr == Fifo0MmioAddr)
      ));
      p_fifo1_pulse_follows_accept :
      assert (o_mmio_fifo1_read_pulse == $past(
          o_mmio_read_pulse && (lq_mem_request_addr == Fifo1MmioAddr)
      ));
      p_uart_rx_pulse_follows_accept :
      assert (o_mmio_uart_rx_ready_pulse == $past(
          o_mmio_read_pulse && (lq_mem_request_addr == UartRxDataMmioAddr)
      ));
    end

    if (f_past_valid && $past(i_rst || i_flush_all)) begin
      p_reset_or_flush_clears_pending : assert (!lq_mem_request_valid);
      p_reset_or_flush_clears_arm : assert (!device_accept_armed_q);
      p_reset_or_flush_clears_pending_history : assert (!device_request_pending_q);
      p_reset_or_flush_clears_fast_valid : assert (!fast_read_valid);
      p_reset_or_flush_clears_destructive_pulses :
      assert (!o_mmio_fifo0_read_pulse && !o_mmio_fifo1_read_pulse && !o_mmio_uart_rx_ready_pulse);
    end

    if (!i_rst) begin
      // Exercise the device staging cycle, the arming cycles the interrupt
      // shield adds, an extra drain wait, and the release from registered
      // state. The fastest device read is accepted three cycles after its
      // live handoff (see the arming register).
      cover_device_minimum_park_arm_accept :
      cover (f_past_valid && !$past(
          i_rst
      ) && $past(
          lq_mem_request_valid && !write_port_busy && i_sq_committed_empty &&
                   device_request_pending_q && lq_pending_request_requires_drain
      ) && lq_mem_request_valid && lq_pending_read_accepted);
      cover_device_drain_closes_after_capture :
      cover (f_past_valid && !$past(
          i_rst || i_flush_all
      ) && $past(
          !lq_mem_request_valid && lq_mem_read_en &&
                   lq_live_request_requires_park && i_sq_committed_empty
      ) && lq_mem_request_valid && !i_sq_committed_empty && !lq_pending_read_accepted);
      cover_device_handoff_canceled_by_flush :
      cover (f_past_valid && i_flush_all && $past(
          !i_rst && !i_flush_all && !lq_mem_request_valid &&
                   lq_mem_read_en && lq_live_request_requires_park
      ));
      cover_device_park :
      cover (lq_mem_request_valid && lq_pending_request_requires_drain &&
             !i_sq_committed_empty && !write_port_busy);
      cover_device_park_release :
      cover (f_device_park_seen && lq_pending_read_accepted &&
             lq_pending_request_requires_drain && i_sq_committed_empty);
      cover_device_shield_arms_then_accepts :
      cover (f_past_valid && !$past(
          i_rst
      ) && device_accept_armed_q && lq_pending_read_accepted && lq_pending_request_requires_drain);
      // The first pending cycle is inert even with every other blocker open:
      // that cycle is what raises cpu_ooo's shield register.
      cover_device_held_on_first_pending_cycle :
      cover (lq_mem_request_valid && lq_pending_request_requires_drain &&
             i_sq_committed_empty && !write_port_busy && !device_request_pending_q &&
             !lq_pending_read_accepted);
      cover_write_and_drain_park :
      cover (lq_mem_request_valid && lq_pending_request_requires_drain &&
             !i_sq_committed_empty && write_port_busy);
    end
  end
`endif  // FORMAL

endmodule : data_mem_request_router
