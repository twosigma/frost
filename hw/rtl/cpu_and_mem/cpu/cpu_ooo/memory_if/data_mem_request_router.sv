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
 * Cached-tier accesses go through coherence_l1d and complete by
 * handshake: reads return tagged with their LQ slot id, one outstanding per
 * slot. The uncached response takes the LQ response port first while the
 * cache holds its response (o_cached_read_ready). With
 * VARIABLE_UNCACHED=1, uncached requests use ready/valid and complete only on
 * their external R/B response. The zero setting retains the fixed-latency
 * interface for pipeline component tests. While a
 * cached store is pending, i_cached_write_inflight keeps the write port busy.
 * The cached read enable also leaves split on its one late term, the live LQ
 * launch (o_data_mem_cached_read_sel), so the adapter can apply it last.
 *
 * Addresses have passed the configured PMA. Memory and device classification
 * retains full physical addresses; relocated device regions may exceed 4 GiB.
 * The FROST map alone keeps its legacy untranslated device-quadrant stores.
 */

module data_mem_request_router #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    // MMIO register window base, by default the PMA's (riscv_pkg). The UART
    // RX data and FIFO pop registers are fixed offsets from it.
    parameter int unsigned MMIO_ADDR = riscv_pkg::MmioWindowAddr,
    // Cached tier: loads and stores to [CACHED_BASE, CACHED_BASE +
    // CACHED_SIZE_BYTES) are served by the cache hierarchy with variable
    // latency.
    parameter longint unsigned CACHED_BASE = riscv_pkg::DdrBase,
    parameter longint unsigned CACHED_SIZE_BYTES = riscv_pkg::DdrCapacityBytes,
    // cpu_top routes all noncached accesses through an AXI completion path.
    // The legacy local-memory wrapper retains its one-cycle path at zero.
    parameter bit VARIABLE_UNCACHED = 1'b0
) (
    input logic [1:0] i_coherent_read_kind = '0,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_coherent_read_tag = '0,
    input logic i_coherent_sq_sc = 1'b0,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_coherent_sq_tag = '0,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_coherent_amo_tag = '0,
    output logic [1:0] o_coherent_read_kind,
    output logic [2:0] o_coherent_read_size,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_coherent_read_tag,
    output logic o_coherent_write_atomic,
    output logic o_coherent_write_sc,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_coherent_write_tag,
    input logic i_clk,
    input logic i_rst,
    // Fatal-stop gate for new accesses. Payload selection stays independent
    // of this gate so it does not feed the cache address-comparison path.
    input logic i_block_new_requests = 1'b0,
    // The flush that clears the LQ: a full pipeline flush or commit-time
    // recovery. It cancels a held request that has not been accepted, and the
    // LQ then expects no response for it.
    input logic i_flush_all,

    // Store-queue write request (highest priority).
    input logic i_sq_mem_write_en,
    input logic [XLEN-1:0] i_sq_mem_write_addr,
    input logic [riscv_pkg::MemDataBits-1:0] i_sq_mem_write_data,
    input logic [riscv_pkg::MemStrbBits-1:0] i_sq_mem_write_byte_en,
    input riscv_pkg::mem_size_e i_sq_mem_write_size = riscv_pkg::MEM_SIZE_DOUBLE,
    input logic i_sq_mem_write_is_mmio,
    input logic i_sq_mem_write_buffered = 1'b0,
    // Registered cached-tier flag for the SQ write (parallels is_mmio).
    input logic i_sq_mem_write_is_cached,

    // Atomic-unit write request.
    input logic                              i_amo_mem_write_en,
    input logic [                  XLEN-1:0] i_amo_mem_write_addr,
    input logic [riscv_pkg::MemDataBits-1:0] i_amo_mem_write_data,
    input logic                              i_amo_mem_write_is_dword,
    // The LQ registers this tier flag with the AMO write address. It must
    // match whenever write enable is high. PMA checks reject device AMOs.
    input logic                              i_amo_mem_write_is_cached,

    // Load-queue read request. The slot id tags a cached read for the
    // adapter (don't-care for the fast tier).
    input logic i_lq_mem_read_en,
    input logic [XLEN-1:0] i_lq_mem_read_addr,
    input logic i_lq_mem_addr_valid,
    input logic [riscv_pkg::CachedLoadSlotBits-1:0] i_lq_mem_read_id,
    // The load is an LR or an AMO (the adapter never shares its line request).
    input logic i_lq_mem_read_no_merge,
    input riscv_pkg::mem_size_e i_lq_mem_read_size = riscv_pkg::MEM_SIZE_DOUBLE,
    // Registered SQ status, high only when no committed-but-unwritten store
    // remains. Same-cycle raw commits already clear it pessimistically. Do not
    // pipeline it again, or a stale-high cycle can release a device read.
    input logic i_sq_committed_empty,

    // External data memory read data. BRAM data is combinational the cycle
    // after a read is accepted. The legacy TestRIG mux folds in registered MMIO
    // read data.
    input  logic [       riscv_pkg::MemDataBits-1:0] i_data_mem_rd_data,
    // Cached read completion is held until ready; write done is a pulse.
    input  logic [       riscv_pkg::MemDataBits-1:0] i_cached_read_data,
    input  logic [riscv_pkg::CachedLoadSlotBits-1:0] i_cached_read_id,
    input  logic                                     i_cached_read_valid,
    input  logic                                     i_cached_read_error = 1'b0,
    output logic                                     o_cached_read_ready,
    // A cached response is being held behind the fast beat this cycle. The
    // load queue registers it into its launch hold so a run of back-to-back
    // fast launches cannot starve the held response: one skipped launch
    // opens the response port.
    output logic                                     o_cached_read_held,
    input  logic                                     i_cached_write_done,
    input  logic                                     i_cached_write_inflight,

    // Variable-latency uncached path. Request enables are single-cycle
    // handoffs; the adapter retains each request through AXI backpressure.
    input logic i_uncached_read_request_ready = 1'b1,
    output logic o_uncached_read_enable,
    output riscv_pkg::mem_size_e o_uncached_read_size,
    input logic i_uncached_read_valid = 1'b0,
    output logic o_uncached_read_ready,
    input logic [riscv_pkg::MemDataBits-1:0] i_uncached_read_data = '0,
    input logic [1:0] i_uncached_read_status = 2'b00,
    output logic [riscv_pkg::MemStrbBits-1:0] o_uncached_write_byte_en,
    output riscv_pkg::mem_size_e o_uncached_write_size,
    output logic o_uncached_write_buffered,
    input logic i_uncached_write_done = 1'b0,
    input logic [1:0] i_uncached_write_status = 2'b00,
    input logic i_uncached_write_inflight = 1'b0,

    // External data memory port.
    output logic [                         XLEN-1:0] o_data_mem_addr,
    output logic [       riscv_pkg::MemDataBits-1:0] o_data_mem_wr_data,
    output logic [       riscv_pkg::MemStrbBits-1:0] o_data_mem_per_byte_wr_en,
    output logic [       riscv_pkg::MemStrbBits-1:0] o_data_mem_bram_byte_wr_en,
    // Equivalent to |o_data_mem_bram_byte_wr_en; formed from arbitration
    // terms for timing. Used by the legacy TestRIG debug store mirror.
    output logic                                     o_data_mem_bram_write_any,
    output logic                                     o_data_mem_read_enable,
    // Cached-tier write/read requests (asserted only for cached-range accesses).
    output logic [       riscv_pkg::MemStrbBits-1:0] o_data_mem_cached_byte_wr_en,
    // Cached-tier write data: SQ-store drain data, or the AMO new value on the
    // single cycle a cached AMO write is launched to the adapter.
    output logic [       riscv_pkg::MemDataBits-1:0] o_data_mem_cached_wr_data,
    output logic                                     o_data_mem_cached_read_enable,
    // o_data_mem_cached_read_enable as (sel ? if_sel : if_clear), with early
    // cofactors: sel is the live LQ launch.
    output logic                                     o_data_mem_cached_read_sel,
    output logic                                     o_data_mem_cached_read_if_sel,
    output logic                                     o_data_mem_cached_read_if_clear,
    output logic [riscv_pkg::CachedLoadSlotBits-1:0] o_data_mem_cached_read_id,
    output logic                                     o_data_mem_cached_read_no_merge,
    output logic                                     o_mmio_read_pulse,
    output logic [                         XLEN-1:0] o_mmio_load_addr,
    output logic                                     o_mmio_load_valid,
    output logic                                     o_mmio_fifo0_read_pulse,
    output logic                                     o_mmio_fifo1_read_pulse,
    output logic                                     o_mmio_uart_rx_ready_pulse,

    // Status back to SQ / AMO / LQ.
    output logic                                     o_sq_mem_write_done,
    output logic                                     o_sq_mem_write_error,
    output logic                                     o_amo_mem_write_done,
    output logic                                     o_amo_mem_write_error,
    // The request register's valid bit, fed back into the LQ's bus-busy gate.
    // It stays high through the accept cycle.
    output logic                                     o_lq_mem_request_valid,
    // High while a device-quadrant request is held. cpu_ooo raises its
    // device-read interrupt shield from it.
    output logic                                     o_device_request_pending,
    output logic [       riscv_pkg::MemDataBits-1:0] o_lq_mem_read_data,
    output logic                                     o_lq_mem_read_valid,
    output logic                                     o_lq_mem_read_error,
    // Source of this cycle's read response: a cached slot (with its id) or
    // the fast tier's single outstanding request.
    output logic                                     o_lq_mem_read_is_cached,
    output logic [riscv_pkg::CachedLoadSlotBits-1:0] o_lq_mem_read_id
);

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) reset_seen_q <= 1'b1;
`endif

  assign o_uncached_write_buffered = i_sq_mem_write_en && i_sq_mem_write_buffered;
  assign o_uncached_write_size = i_sq_mem_write_en ? i_sq_mem_write_size :
      i_amo_mem_write_is_dword ? riscv_pkg::MEM_SIZE_DOUBLE : riscv_pkg::MEM_SIZE_WORD;

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
  assign sq_mem_write_en         = i_sq_mem_write_en && !i_block_new_requests;
  assign sq_mem_write_addr       = i_sq_mem_write_addr;
  assign sq_mem_write_data       = i_sq_mem_write_data;
  assign sq_mem_write_byte_en    = i_sq_mem_write_byte_en;
  assign sq_mem_write_is_mmio    = i_sq_mem_write_is_mmio;
  assign sq_mem_write_is_cached  = i_sq_mem_write_is_cached;
  assign amo_mem_write_en        = i_amo_mem_write_en && !i_block_new_requests;
  assign amo_mem_write_addr      = i_amo_mem_write_addr;
  assign amo_mem_write_data      = i_amo_mem_write_data;
  assign amo_mem_write_is_dword  = i_amo_mem_write_is_dword;
  assign amo_mem_write_is_cached = i_amo_mem_write_is_cached;
  // AMO write strobes: word lanes for .W (by addr[2]); full beat for .D.
  logic [riscv_pkg::MemStrbBits-1:0] amo_write_strobes;
  assign amo_write_strobes = riscv_pkg::mem_strobe_for(
      amo_mem_write_is_dword ? 2'b11 : 2'b10, amo_mem_write_addr[2:0]
  );
  assign lq_mem_read_en = i_lq_mem_read_en && !i_block_new_requests;
  assign lq_mem_read_addr = i_lq_mem_read_addr;
  assign lq_mem_addr_valid = i_lq_mem_addr_valid;

  // Cast the 32-bit MMIO_ADDR parameter to XLEN; an XLEN-wide part-select
  // would be out of range at XLEN=64.
  localparam logic [XLEN-1:0] UartRxDataMmioAddr = XLEN'(MMIO_ADDR) + XLEN'(32'h4);
  localparam logic [XLEN-1:0] Fifo0MmioAddr = XLEN'(MMIO_ADDR) + XLEN'(32'h8);
  localparam logic [XLEN-1:0] Fifo1MmioAddr = XLEN'(MMIO_ADDR) + XLEN'(32'hC);

  logic                                                        sq_write_done_fast;
  logic                                                        write_port_busy;
  logic                                                        amo_mem_write_done;
  logic                                                        lq_mem_request_valid;
  logic                 [                            XLEN-1:0] lq_mem_request_addr;
  logic                 [   riscv_pkg::CachedLoadSlotBits-1:0] lq_mem_request_id;
  logic                 [   riscv_pkg::CachedLoadSlotBits-1:0] lq_mem_request_id_eff;
  logic                                                        lq_mem_request_no_merge;
  logic                 [                                 1:0] coherent_kind_q;
  logic                 [riscv_pkg::ReorderBufferTagWidth-1:0] coherent_tag_q;
  riscv_pkg::mem_size_e                                        lq_mem_request_size;
  logic                                                        lq_mem_request_no_merge_eff;
  logic                 [                            XLEN-1:0] lq_mem_request_addr_eff;
  logic                 [          riscv_pkg::MemDataBits-1:0] lq_mem_read_data;
  logic                                                        lq_mem_read_valid;
  logic                                                        lq_live_request_requires_park;
  logic                                                        lq_pending_request_requires_drain;
  logic                                                        lq_live_read_accepted;
  logic                                                        lq_pending_read_candidate;
  logic                                                        lq_pending_read_accepted;
  logic                                                        lq_pending_read_shielded;
  logic                                                        device_request_pending_q;
  logic                                                        device_accept_armed_q;
  logic                                                        lq_pending_mmio_read_accepted;
  logic                                                        lq_mem_read_accepted;

  // Effective queued-load address: held copy if a request is pending, else the
  // live LQ read address.
  assign lq_mem_request_addr_eff = lq_mem_request_valid ? lq_mem_request_addr : lq_mem_read_addr;
  // The cached-load slot id travels with the request the same way: a parked
  // load must reach the adapter under its own id, not the one presented
  // live on the accept cycle.
  assign lq_mem_request_id_eff = lq_mem_request_valid ? lq_mem_request_id : i_lq_mem_read_id;
  assign lq_mem_request_no_merge_eff =
      lq_mem_request_valid ? lq_mem_request_no_merge : i_lq_mem_read_no_merge;
  if (1'b1) begin : gen_coherent_metadata
    always_ff @(posedge i_clk) begin
      if (!lq_mem_request_valid) begin
        coherent_kind_q <= i_coherent_read_kind;
        coherent_tag_q  <= i_coherent_read_tag;
      end
    end
    assign o_coherent_read_kind = lq_mem_request_valid ? coherent_kind_q : i_coherent_read_kind;
    assign o_coherent_read_tag = lq_mem_request_valid ? coherent_tag_q : i_coherent_read_tag;
    assign o_coherent_read_size = 3'(
        lq_mem_request_valid ? lq_mem_request_size : i_lq_mem_read_size
    );
    assign o_coherent_write_sc = sq_mem_write_en && sq_mem_write_is_cached && i_coherent_sq_sc;
    assign o_coherent_write_atomic = o_coherent_write_sc || amo_cached_write_launch;
    assign o_coherent_write_tag = sq_mem_write_en ? i_coherent_sq_tag : i_coherent_amo_tag;
  end
  // The live device-quadrant decode forces capture. Acceptance and MMIO
  // effects use only the held address.
  assign lq_live_request_requires_park = riscv_pkg::pma_device_quadrant(lq_mem_read_addr);
  assign lq_pending_request_requires_drain = riscv_pkg::pma_device_quadrant(lq_mem_request_addr);

  // -------------------------------------------------------------------------
  // Tier decode.
  // ---------------------------------------------------------------------------
  // Read tier comes from the held or live address; write tier flags arrive
  // registered with the SQ or AMO address. Cached writes must not reach BRAM,
  // where they would corrupt an aliased word. AMOs cannot target devices,
  // so uncached AMOs go to Normal memory and cannot select devices.
  logic lq_mem_request_is_cached;
  assign lq_mem_request_is_cached =
      (lq_mem_request_addr_eff >= XLEN'(CACHED_BASE)) &&
      (lq_mem_request_addr_eff <  (XLEN'(CACHED_BASE) + XLEN'(CACHED_SIZE_BYTES)));
  // The same decode of the live and the held address, for the split enable.
  logic lq_live_is_cached, lq_held_is_cached;
  assign lq_live_is_cached =
      (lq_mem_read_addr >= XLEN'(CACHED_BASE)) &&
      (lq_mem_read_addr <  (XLEN'(CACHED_BASE) + XLEN'(CACHED_SIZE_BYTES)));
  assign lq_held_is_cached =
      (lq_mem_request_addr >= XLEN'(CACHED_BASE)) &&
      (lq_mem_request_addr <  (XLEN'(CACHED_BASE) + XLEN'(CACHED_SIZE_BYTES)));

  // The LQ holds AMO write enable until done. The cached adapter requires a
  // single launch pulse, so amo_variable_inflight blocks repeats until done.
  // VARIABLE_UNCACHED extends this ownership to the uncached AXI adapter;
  // only the legacy local-memory path completes an AMO combinationally.
  logic amo_variable_inflight;
  logic amo_cached_write_launch;
  logic amo_uncached_write_launch;
  assign amo_cached_write_launch =
      amo_mem_write_en && amo_mem_write_is_cached && !amo_variable_inflight;
  assign amo_uncached_write_launch = VARIABLE_UNCACHED && amo_mem_write_en &&
      !amo_mem_write_is_cached && !amo_variable_inflight;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      amo_variable_inflight <= 1'b0;
    end else if (amo_cached_write_launch || amo_uncached_write_launch) begin
      amo_variable_inflight <= 1'b1;
    end else if (i_cached_write_done || (VARIABLE_UNCACHED && i_uncached_write_done)) begin
      amo_variable_inflight <= 1'b0;
    end
  end

  // A variable-latency store holds the port through adapter completion.
  // The LQ bus-busy gate includes these terms, so normally only device
  // reads wait in the request register. Any load arriving while busy is held.
  assign write_port_busy = sq_mem_write_en || amo_mem_write_en || i_cached_write_inflight ||
      (VARIABLE_UNCACHED && i_uncached_write_inflight);

  // Low-BRAM write selects use registered request and tier flags.
  logic sq_bram_write;
  logic amo_bram_write;
  assign sq_bram_write = sq_mem_write_en && !sq_mem_write_is_mmio && !sq_mem_write_is_cached;
  assign amo_bram_write = amo_mem_write_en && !amo_mem_write_is_cached;

  // Low-BRAM and cached reads can be accepted live. Device-quadrant reads
  // never are, even with every blocker open: they are captured into the
  // request register first and accepted only from there.
  assign lq_live_read_accepted =
      !i_rst && !i_flush_all && !write_port_busy && lq_mem_read_en &&
      !lq_live_request_requires_park &&
      (!VARIABLE_UNCACHED || lq_live_is_cached || i_uncached_read_request_ready);
  assign lq_pending_read_candidate =
      !i_rst && !i_flush_all && !i_block_new_requests &&
      !write_port_busy && lq_mem_request_valid &&
      (!VARIABLE_UNCACHED || lq_held_is_cached || i_uncached_read_request_ready);
  assign lq_pending_read_shielded =
      lq_pending_read_candidate &&
      (!lq_pending_request_requires_drain || i_sq_committed_empty);
`ifdef FROST_XILINX_PRIMS
  // INIT=A222 implements I0 & (!I1 | (I2 & I3)). A held device request
  // requires drained committed stores and an armed interrupt shield in the
  // accept cycle. The portable lq_pending_read_shielded is unused here.
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
  // Arming adds a requirement; it does not replace the live drain, write-port,
  // or flush gates, which may change between arming and acceptance.
  assign lq_pending_read_accepted =
      lq_pending_read_shielded &&
      (!lq_pending_request_requires_drain || device_accept_armed_q);
`endif
  assign lq_mem_read_accepted = lq_live_read_accepted || lq_pending_read_accepted;
  // The uncached read enable for each value of the late launch, so the launch
  // only selects between them.
  (* keep = "true" *) logic uncached_read_if_launch, uncached_read_if_idle;
  assign uncached_read_if_idle = VARIABLE_UNCACHED && !lq_mem_request_is_cached &&
      lq_pending_read_accepted;
  assign uncached_read_if_launch = VARIABLE_UNCACHED && !lq_mem_request_is_cached &&
      (lq_pending_read_accepted ||
       (!i_rst && !i_flush_all && !write_port_busy && !lq_live_request_requires_park &&
        (lq_live_is_cached || i_uncached_read_request_ready)));
  assign lq_pending_mmio_read_accepted =
      lq_pending_read_accepted && lq_pending_request_requires_drain;

  always_comb begin
    o_data_mem_read_enable = lq_mem_read_accepted;

    // Address changes without read_enable are harmless; select independently
    // of the read-accept gate, for timing.
    o_data_mem_addr = i_sq_mem_write_en ? sq_mem_write_addr :
                      i_amo_mem_write_en ? amo_mem_write_addr :
                      (lq_mem_request_valid || lq_mem_addr_valid) ?
                      lq_mem_request_addr_eff : '0;

    o_data_mem_wr_data = i_sq_mem_write_en ? sq_mem_write_data :
                         i_amo_mem_write_en ? amo_mem_write_data : '0;
    // Unmasked byte-write-enable for peripherals (UART/FIFO/timer). MMIO
    // writes must remain visible here so the registered shadow in frost_rvfi_platform
    // can dispatch them on the next cycle.
    o_data_mem_per_byte_wr_en = sq_mem_write_en ? sq_mem_write_byte_en :
                                amo_mem_write_en ?
                                amo_write_strobes : '0;
    // Mask MMIO and cached writes using registered tier flags; neither may
    // write an aliased BRAM word.
    o_data_mem_bram_byte_wr_en =
        sq_bram_write ? sq_mem_write_byte_en :
        amo_bram_write ? amo_write_strobes : '0;
    // Reduce the selected strobes using |(s ? a : b) == (s ? |a : |b).
    // AMO strobes are always nonzero: 8'h0F or 8'hF0 for .W, 8'hFF for .D.
    o_data_mem_bram_write_any = sq_bram_write ? (|sq_mem_write_byte_en) : amo_bram_write;

    // Send cached SQ writes or one AMO launch pulse. They cannot overlap:
    // AMOs issue at the ROB head after all committed stores have drained.
    o_data_mem_cached_byte_wr_en =
        (sq_mem_write_en && sq_mem_write_is_cached) ? sq_mem_write_byte_en :
        amo_cached_write_launch ?
            amo_write_strobes : '0;

    // Cached-tier write data: SQ-store drain data, or the AMO new value on the
    // launch pulse.
    o_data_mem_cached_wr_data = amo_cached_write_launch ? amo_mem_write_data : sq_mem_write_data;

    // Only cached loads may trigger cache lookup side effects: miss, fill,
    // and eviction.
    o_data_mem_cached_read_enable = o_data_mem_read_enable && lq_mem_request_is_cached;
    // A live launch never overlaps a held request, so with one the live read
    // is the only candidate, and without one only the held request can be
    // accepted.
    o_data_mem_cached_read_sel = lq_mem_read_en;
    o_data_mem_cached_read_if_sel = !i_rst && !i_flush_all && !i_block_new_requests &&
        !write_port_busy &&
        !lq_live_request_requires_park && lq_live_is_cached;
    o_data_mem_cached_read_if_clear = lq_pending_read_accepted && lq_held_is_cached;
    o_data_mem_cached_read_id = lq_mem_request_id_eff;
    o_data_mem_cached_read_no_merge = lq_mem_request_no_merge_eff;

    o_uncached_read_enable = lq_mem_read_en ? uncached_read_if_launch : uncached_read_if_idle;
    o_uncached_read_size = lq_mem_request_valid ? lq_mem_request_size : i_lq_mem_read_size;
    o_uncached_write_byte_en = !VARIABLE_UNCACHED ? '0 :
        (sq_mem_write_en && !sq_mem_write_is_cached) ? sq_mem_write_byte_en :
        amo_uncached_write_launch ? amo_write_strobes : '0;

    // BRAM writes complete in the accept cycle; cached writes wait for the
    // adapter's done pulse. The LQ holds the request until done to preserve
    // result and cache-invalidate ordering.
    amo_mem_write_done = !sq_mem_write_en && amo_mem_write_en &&
                         (amo_mem_write_is_cached ? i_cached_write_done :
                          VARIABLE_UNCACHED ? i_uncached_write_done : 1'b1);

    o_mmio_load_addr = lq_mem_request_addr;
    o_mmio_load_valid = lq_pending_mmio_read_accepted;
  end

  // In the legacy profile, BRAM/MMIO SQ writes complete next cycle. Cached done
  // means L1D has applied a hit or accepted a write miss for merging on fill;
  // it does not require DDR completion. Done retires the SQ record and
  // releases cache invalidation. Younger same-address loads wait until the
  // store leaves the SQ, then L1D serves them from the merged data.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      sq_write_done_fast <= 1'b0;
    end else begin
      sq_write_done_fast <= !VARIABLE_UNCACHED && sq_mem_write_en && !sq_mem_write_is_cached;
    end
  end

  // Reset and flush cancel unaccepted requests. A flush blocks accept before
  // clearing valid at the edge. The LQ sees valid still set on that edge and
  // owes no response for the canceled request. Already accepted requests have
  // valid clear and use the LQ's normal response-drain accounting.
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

  // The pending indication uses only the held valid bit and address.
  assign o_device_request_pending = lq_mem_request_valid && lq_pending_request_requires_drain;

  // Delay o_device_request_pending by one cycle. cpu_ooo's interrupt shield
  // sets from the same signal and shares reset/flush, so it is already set
  // whenever device_request_pending_q is high.
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

  // Sample address, slot ID and no-merge bit while empty. A blocked or staged
  // request is captured on its handoff edge, then held while valid. Data after
  // a live accept or cancellation is unused.
  always_ff @(posedge i_clk) begin
    if (!lq_mem_request_valid) begin
      lq_mem_request_addr <= lq_mem_read_addr;
      lq_mem_request_id <= i_lq_mem_read_id;
      lq_mem_request_no_merge <= i_lq_mem_read_no_merge;
      lq_mem_request_size <= i_lq_mem_read_size;
    end
  end

`ifndef SYNTHESIS
  always_comb begin
    if (!$isunknown(
            {lq_mem_request_valid, lq_mem_read_en, o_data_mem_cached_read_enable,
                     o_data_mem_cached_read_if_sel, o_data_mem_cached_read_if_clear}
        ) && !(lq_mem_request_valid && lq_mem_read_en)) begin
      p_cached_read_split_exact :
      assert (o_data_mem_cached_read_enable ==
              (o_data_mem_cached_read_sel ? o_data_mem_cached_read_if_sel :
                                            o_data_mem_cached_read_if_clear));
    end
  end
`endif
`ifndef SYNTHESIS
`ifndef FORMAL
  // The LQ's bus-busy gate includes the valid bit, so the one-entry register
  // never receives a second request while it holds one. Check that contract.
  always @(posedge i_clk) begin
    if (reset_seen_q && !i_rst && lq_mem_request_valid && lq_mem_read_en)
      $error("data_mem_request_router: live LQ read overlapped held request");
  end
`endif
`endif

  // Read responses share one LQ port. The legacy BRAM/MMIO beat has fixed
  // latency. In VARIABLE_UNCACHED mode its response instead comes from the
  // AXI adapter. Both have priority over cached responses, which retain their
  // slot ID and remain valid at the cached adapter until accepted.
  logic fast_read_accepted;
  assign fast_read_accepted = !VARIABLE_UNCACHED && lq_mem_read_accepted &&
      !lq_mem_request_is_cached;

  // Legacy local (BRAM/MMIO) one-cycle valid; inactive with AXI.
  (* max_fanout = 32 *) logic fast_read_valid;
  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush_all) fast_read_valid <= 1'b0;
    else fast_read_valid <= fast_read_accepted;
  end

  // The LQ registers o_cached_read_held to skip a fast launch and prevent
  // starving a cached response.
  logic uncached_response;
  assign uncached_response = VARIABLE_UNCACHED && i_uncached_read_valid;
  assign o_uncached_read_ready = VARIABLE_UNCACHED && !fast_read_valid;
  assign o_cached_read_ready = !fast_read_valid && !uncached_response;
  assign o_cached_read_held = i_cached_read_valid && (fast_read_valid || uncached_response);
  assign lq_mem_read_valid = fast_read_valid || uncached_response || i_cached_read_valid;
  assign lq_mem_read_data = fast_read_valid ? i_data_mem_rd_data :
      uncached_response ? i_uncached_read_data : i_cached_read_data;
  assign o_lq_mem_read_is_cached = !fast_read_valid && !uncached_response && i_cached_read_valid;
  assign o_lq_mem_read_error = !fast_read_valid &&
      (uncached_response ? (i_uncached_read_status != 2'b00) :
                            (i_cached_read_valid && i_cached_read_error));
  assign o_lq_mem_read_id = i_cached_read_id;

  // Only an accepted held request can cause an MMIO read.
  assign o_mmio_read_pulse = lq_pending_mmio_read_accepted;

  // The legacy TestRIG fixture samples MMIO on o_mmio_read_pulse. Destructive FIFO/UART
  // pulses follow one cycle later, aligned with fast-response valid.
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

  // Output wiring. Cached SQ and AMO writes never overlap. Route adapter done
  // to AMO while its variable-latency write is in flight, and to SQ otherwise.
  assign o_sq_mem_write_done = sq_write_done_fast ||
      ((i_cached_write_done || (VARIABLE_UNCACHED && i_uncached_write_done)) &&
       !amo_variable_inflight);
  assign o_sq_mem_write_error = VARIABLE_UNCACHED && i_uncached_write_done &&
      !amo_variable_inflight && (i_uncached_write_status != 2'b00);
  assign o_amo_mem_write_done = amo_mem_write_done;
  assign o_amo_mem_write_error = VARIABLE_UNCACHED && amo_mem_write_done &&
      !amo_mem_write_is_cached && (i_uncached_write_status != 2'b00);
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

  // The LQ must not launch a second read while the request register is valid;
  // its bus-busy gate includes this bit and all write-port terms.
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
               !lq_live_request_requires_park &&
               (!VARIABLE_UNCACHED || lq_live_is_cached || i_uncached_read_request_ready)));
      p_pending_read_candidate_equivalent :
      assert (lq_pending_read_candidate ==
              (!i_flush_all && !i_block_new_requests && !write_port_busy &&
               lq_mem_request_valid &&
               (!VARIABLE_UNCACHED || lq_held_is_cached || i_uncached_read_request_ready)));
      p_pending_read_shielded_equivalent :
      assert (lq_pending_read_shielded ==
              (lq_pending_read_candidate &&
               (!lq_pending_request_requires_drain || i_sq_committed_empty)));
      p_pending_read_accept_equivalent :
      assert (lq_pending_read_accepted ==
              (lq_pending_read_shielded &&
               (!lq_pending_request_requires_drain || device_accept_armed_q)));
      // Every armed accept must still pass the drain gate.
      p_arming_only_restricts : assert (!lq_pending_read_accepted || lq_pending_read_shielded);
      // A device read is unreachable unless the interrupt shield was already
      // established when this request was armed.
      if (lq_pending_read_accepted && lq_pending_request_requires_drain) begin
        p_device_accept_needs_arm : assert (device_accept_armed_q);
      end
      p_read_accept_equivalent :
      assert (lq_mem_read_accepted == (lq_live_read_accepted || lq_pending_read_accepted));
      p_data_read_is_accept : assert (o_data_mem_read_enable == lq_mem_read_accepted);
      // The any-byte-written flag must equal the strobe reduction for all inputs.
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
        assert (lq_mem_request_valid && lq_pending_request_requires_drain &&
                lq_pending_read_accepted);
        p_mmio_effect_needs_sq_drain : assert (i_sq_committed_empty);
      end
    end
    if (i_rst || i_flush_all || i_block_new_requests) begin
      p_reset_or_flush_suppresses_accept :
      assert (!lq_live_read_accepted && !lq_pending_read_candidate &&
              !lq_pending_read_shielded && !lq_pending_read_accepted &&
              !lq_mem_read_accepted);
      p_reset_or_flush_has_no_combinational_read_effect :
      assert (!o_data_mem_read_enable && !o_data_mem_cached_read_enable &&
              !o_mmio_read_pulse && !o_mmio_load_valid);
    end
    if (i_block_new_requests) begin
      p_stop_suppresses_writes :
      assert (!(|o_data_mem_bram_byte_wr_en) && !(|o_data_mem_per_byte_wr_en) &&
              !(|o_data_mem_cached_byte_wr_en) && !(|o_uncached_write_byte_en));
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

      // Arming requires device_request_pending_q in the previous cycle, when
      // cpu_ooo's shield is already set. Interrupt hold precedes every device
      // read effect.
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
      // Cover staging, arming, drain waits, and release. Earliest device accept
      // is three cycles after handoff.
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

`ifndef SYNTHESIS
  always_comb begin
    p_uncached_read_enable_exact :
    assert (o_uncached_read_enable ==
            (VARIABLE_UNCACHED && lq_mem_read_accepted && !lq_mem_request_is_cached));
  end
`endif

`ifndef SYNTHESIS
`ifdef FROST_COVERAGE
  // Cover points for simulation coverage (tests/README.md).
  // A full flush, from an interrupt or a debug halt, cancels a device read
  // parked before accept.
  cover_flush_cancels_parked_device_read :
  cover property (@(posedge i_clk) disable iff (!reset_seen_q || i_rst)
      o_device_request_pending && i_flush_all);
`endif
`endif

endmodule : data_mem_request_router
