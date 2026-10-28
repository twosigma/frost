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

// The shared memory side contains the S/M home, its L2 data array and the
// DMA ingress. cpu_memory_fabric combines L2 traffic with uncached data
// and instruction requests on the AXI master. See cpu_top/README.md.
`include "coherence_types.svh"

module frost_cluster_memory #(
    parameter int unsigned ENABLE_CACHED_TIER = 1,
    parameter bit ENABLE_COHERENCE = 1'b0,
    parameter int unsigned L2_CACHE_BYTES = 2 * 1024 * 1024,
    parameter int unsigned L2_WAYS = 4,
    parameter int unsigned L2_NUM_MSHR = 4,
    parameter int unsigned L2_NUM_WB = 2,
    parameter int unsigned L2_NUM_WAITERS = 2,
    parameter int unsigned L2_PREFETCH = 1,
    parameter int unsigned L2_PREFETCH_DISTANCE = 8,
    parameter int unsigned L2_PREFETCH_INFLIGHT = 4,
    parameter int unsigned L2_LINE_BYTES = 64,
    parameter int unsigned SIM_FAST_MAINT = 0,
    // The hart's uncached instruction fetch block (cpu_memory_fabric
    // FETCH_BYTES).
    parameter int unsigned FETCH_BYTES = 8,
    parameter int unsigned AXI_ID_BITS = 6,
    parameter int unsigned AXI_USER_BITS = 1,
    parameter logic [2:0] AXI_MEMORY_PROT = 3'b011,
    // DMA ingress uses 32-byte lines and 4-bit ids.
    localparam int unsigned L1LineBytes = 32,
    localparam int unsigned LineIdBits = 4

) (
    input logic i_clk,
    input logic i_rst,
    input logic i_axi_rst,
    // The tile's sticky fatal indication: the coherent ingress accepts and
    // presents nothing while it is set.
    input logic i_fatal_error,

    // Coherent ingress (cpu_top's i_coherent_req_* / o_coherent_resp_*).
    input logic i_coherent_req_valid,
    output logic o_coherent_req_ready,
    input logic i_coherent_req_write,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_coherent_req_addr,
    input logic [L1LineBytes*8-1:0] i_coherent_req_wdata,
    input logic [L1LineBytes-1:0] i_coherent_req_wstrb,
    input logic [LineIdBits-1:0] i_coherent_req_id,
    output logic o_coherent_resp_valid,
    output logic [LineIdBits-1:0] o_coherent_resp_id,
    output logic [L1LineBytes*8-1:0] o_coherent_resp_rdata,
    output logic o_coherent_resp_error,

    input logic i_coherent_d_valid,
    output logic o_coherent_d_ready,
    input logic [riscv_pkg::PhysAddrBits+311:0] i_coherent_d,
    output logic o_coherent_p_valid,
    input logic i_coherent_p_ready,
    output logic [riscv_pkg::PhysAddrBits+29:0] o_coherent_p,
    input logic i_coherent_r_valid,
    output logic o_coherent_r_ready,
    input logic [riscv_pkg::PhysAddrBits+274:0] i_coherent_r,
    input logic i_coherent_w_valid,
    output logic o_coherent_w_ready,
    input logic [riscv_pkg::PhysAddrBits+259:0] i_coherent_w,
    output logic o_coherent_wa_valid,
    input logic i_coherent_wa_ready,
    output logic [riscv_pkg::PhysAddrBits+10:0] o_coherent_wa,
    output logic o_coherent_g_valid,
    input logic i_coherent_g_ready,
    output logic [riscv_pkg::PhysAddrBits+274:0] o_coherent_g,
    input logic i_coherent_c_valid,
    output logic o_coherent_c_ready,
    input logic [riscv_pkg::PhysAddrBits+17:0] i_coherent_c,
    output logic o_coherent_u_valid,
    input logic i_coherent_u_ready,
    output logic [riscv_pkg::PhysAddrBits+14:0] o_coherent_u,

    // The hart's uncached and Device data requests.
    input logic i_data_req_valid,
    output logic o_data_req_ready,
    input logic i_data_req_write,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_data_req_addr,
    input logic [2:0] i_data_req_size,
    input logic [3:0] i_data_req_cache,
    input logic [2:0] i_data_req_prot,
    input logic [L2_LINE_BYTES*8-1:0] i_data_req_wdata,
    input logic [L2_LINE_BYTES-1:0] i_data_req_wstrb,
    output logic o_data_resp_valid,
    output logic [L2_LINE_BYTES*8-1:0] o_data_resp_data,
    output logic [1:0] o_data_resp_status,
    output logic o_data_resp_ok,

    // The hart's uncached instruction fetch requests.
    input logic i_fetch_req_valid,
    output logic o_fetch_req_ready,
    input logic [riscv_pkg::PhysAddrBits-1:0] i_fetch_req_addr,
    input logic i_fetch_req_id,
    output logic o_fetch_resp_valid,
    output logic o_fetch_resp_id,
    output logic [FETCH_BYTES*8-1:0] o_fetch_resp_data,
    output logic o_fetch_resp_error,

    // Fatal buffered-store failures in the L2, and its source-registered
    // performance observers.
    output logic o_cache_fatal,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_cache_fatal_addr,
    output cache_perf_pkg::cache_instance_perf_events_t o_l2_perf_events,
    output cache_perf_pkg::cache_write_perf_events_t o_l2_write_perf_events,

    // Outgoing AXI4 master (cpu_top's o_axi_* / i_axi_*).
    output logic o_axi_idle,
    output logic o_axi_awvalid,
    input logic i_axi_awready,
    output logic [AXI_ID_BITS-1:0] o_axi_awid,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_axi_awaddr,
    output logic [7:0] o_axi_awlen,
    output logic [2:0] o_axi_awsize,
    output logic [1:0] o_axi_awburst,
    output logic o_axi_awlock,
    output logic [3:0] o_axi_awcache,
    output logic [2:0] o_axi_awprot,
    output logic [3:0] o_axi_awqos,
    output logic [3:0] o_axi_awregion,
    output logic [AXI_USER_BITS-1:0] o_axi_awuser,
    output logic o_axi_wvalid,
    input logic i_axi_wready,
    output logic [L2_LINE_BYTES*8-1:0] o_axi_wdata,
    output logic [L2_LINE_BYTES-1:0] o_axi_wstrb,
    output logic o_axi_wlast,
    output logic [AXI_USER_BITS-1:0] o_axi_wuser,
    input logic i_axi_bvalid,
    output logic o_axi_bready,
    input logic [AXI_ID_BITS-1:0] i_axi_bid,
    input logic [1:0] i_axi_bresp,
    input logic [AXI_USER_BITS-1:0] i_axi_buser,
    output logic o_axi_arvalid,
    input logic i_axi_arready,
    output logic [AXI_ID_BITS-1:0] o_axi_arid,
    output logic [riscv_pkg::PhysAddrBits-1:0] o_axi_araddr,
    output logic [7:0] o_axi_arlen,
    output logic [2:0] o_axi_arsize,
    output logic [1:0] o_axi_arburst,
    output logic o_axi_arlock,
    output logic [3:0] o_axi_arcache,
    output logic [2:0] o_axi_arprot,
    output logic [3:0] o_axi_arqos,
    output logic [3:0] o_axi_arregion,
    output logic [AXI_USER_BITS-1:0] o_axi_aruser,
    input logic i_axi_rvalid,
    output logic o_axi_rready,
    input logic [AXI_ID_BITS-1:0] i_axi_rid,
    input logic [L2_LINE_BYTES*8-1:0] i_axi_rdata,
    input logic [1:0] i_axi_rresp,
    input logic i_axi_rlast,
    input logic [AXI_USER_BITS-1:0] i_axi_ruser
);
  localparam int unsigned DdrAxiIdBits = 5;

  logic dma_req_ready, dma_resp_valid, dma_resp_error;
  logic [LineIdBits-1:0] dma_resp_id;
  logic [L1LineBytes*8-1:0] dma_resp_rdata;
  wire coherent_address_ok = riscv_pkg::pma_cached_ok(
      riscv_pkg::XLEN'(i_coherent_req_addr)
  ) && i_coherent_req_addr[4:0] == 0;
  // Register ingress ownership before the shared level's same-line checks.
  // This separates a wrapper's arbitration/address mux from the cache
  // admission path, while permitting dequeue and replacement on one edge.
  logic coherent_pending_q;
  logic dma_req_write;
  logic [riscv_pkg::PhysAddrBits-1:0] dma_req_addr;
  logic [L1LineBytes*8-1:0] dma_req_wdata;
  logic [L1LineBytes-1:0] dma_req_wstrb;
  logic [LineIdBits-1:0] dma_req_id;
  wire dma_req_valid = ENABLE_COHERENCE && !i_rst && !i_fatal_error && coherent_pending_q;
  assign o_coherent_req_ready = ENABLE_COHERENCE && (ENABLE_CACHED_TIER != 0) &&
      !i_rst && !i_fatal_error && coherent_address_ok &&
      (!coherent_pending_q || dma_req_ready);
  always_ff @(posedge i_clk) begin
    if (i_rst) coherent_pending_q <= 1'b0;
    else begin
      if (dma_req_valid && dma_req_ready) coherent_pending_q <= 1'b0;
      if (i_coherent_req_valid && o_coherent_req_ready) begin
        coherent_pending_q <= 1'b1;
        dma_req_write <= i_coherent_req_write;
        dma_req_addr <= i_coherent_req_addr;
        dma_req_wdata <= i_coherent_req_wdata;
        dma_req_wstrb <= i_coherent_req_wstrb;
        dma_req_id <= i_coherent_req_id;
      end
    end
  end
  assign o_coherent_resp_valid = ENABLE_COHERENCE && dma_resp_valid;
  assign o_coherent_resp_id = ENABLE_COHERENCE ? dma_resp_id : '0;
  assign o_coherent_resp_rdata = ENABLE_COHERENCE ? dma_resp_rdata : '0;
  assign o_coherent_resp_error = ENABLE_COHERENCE && dma_resp_error;
  logic down_req_valid, down_req_ready, down_req_write;
  logic [riscv_pkg::PhysAddrBits-1:0] down_req_addr;
  logic [L2_LINE_BYTES*8-1:0] down_req_wdata;
  logic [L2_LINE_BYTES-1:0] down_req_wstrb;
  logic [DdrAxiIdBits-1:0] down_req_id;
  logic down_resp_valid, down_resp_error;
  logic [DdrAxiIdBits-1:0] down_resp_id;
  logic [L2_LINE_BYTES*8-1:0] down_resp_rdata;

  if (ENABLE_CACHED_TIER != 0) begin : gen_coherent_tier
    `FROST_COHERENCE_TYPES(riscv_pkg::PhysAddrBits)
    coh_d_t dma_d, home_d;
    coh_g_t grant;
    coh_c_t dma_c, home_c;
    coh_u_t release_message;
    logic dma_d_valid, dma_d_ready, home_d_valid, home_d_ready;
    logic g_valid, g_ready, dma_g_ready, dma_c_valid, dma_c_ready;
    logic home_c_valid, home_c_ready, u_valid, u_ready, dma_u_ready, dma_owner_q;
    coherence_line_bridge #(
        .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .ID_BITS(4),
        .SOURCE(2),
        .PORT_CLASS(3)
    ) ingress (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_fatal_stop(i_fatal_error),
        .i_req_valid(dma_req_valid),
        .o_req_ready(dma_req_ready),
        .i_req_write(dma_req_write),
        .i_req_addr(dma_req_addr),
        .i_req_data(dma_req_wdata),
        .i_req_mask(dma_req_wstrb),
        .i_req_id(dma_req_id),
        .o_resp_valid(dma_resp_valid),
        .o_resp_id(dma_resp_id),
        .o_resp_data(dma_resp_rdata),
        .o_resp_error(dma_resp_error),
        .o_clean_valid(),
        .o_clean_addr(),
        .i_clean_done(1'b0),
        .o_d_valid(dma_d_valid),
        .i_d_ready(dma_d_ready),
        .o_d(dma_d),
        .i_g_valid(g_valid && dma_owner_q),
        .o_g_ready(dma_g_ready),
        .i_g(grant),
        .o_c_valid(dma_c_valid),
        .o_c_selected(),
        .i_c_ready(dma_c_ready),
        .o_c(dma_c),
        .i_u_valid(u_valid && dma_owner_q),
        .o_u_ready(dma_u_ready),
        .i_u(release_message)
    );
    coherence_d_arbiter #(
        .WIDTH((riscv_pkg::PhysAddrBits + 312)),
        .PORTS(2)
    ) demands (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_valid({dma_d_valid, i_coherent_d_valid}),
        .o_ready({dma_d_ready, o_coherent_d_ready}),
        .i_payload({dma_d, i_coherent_d}),
        .o_valid(home_d_valid),
        .i_ready(home_d_ready),
        .o_payload(home_d)
    );
    always_ff @(posedge i_clk) begin
      if (i_rst) dma_owner_q <= 1'b0;
      else if (home_d_valid && home_d_ready) dma_owner_q <= home_d.q[8:7] == 2;
    end
    assign o_coherent_g_valid = g_valid && !dma_owner_q;
    assign o_coherent_g = grant;
    assign g_ready = dma_owner_q ? dma_g_ready : i_coherent_g_ready;
    assign home_c_valid = dma_owner_q ? dma_c_valid : i_coherent_c_valid;
    assign home_c = dma_owner_q ? dma_c : i_coherent_c;
    assign dma_c_ready = home_c_ready && dma_owner_q;
    assign o_coherent_c_ready = home_c_ready && !dma_owner_q;
    assign o_coherent_u_valid = u_valid && !dma_owner_q;
    assign o_coherent_u = release_message;
    assign u_ready = dma_owner_q ? dma_u_ready : i_coherent_u_ready;
    coherence_home #(
        .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
        .LINE_BYTES(L2_LINE_BYTES),
        .CACHE_BYTES(L2_CACHE_BYTES),
        .WAYS(L2_WAYS),
        .NUM_WB(L2_NUM_WB)
    ) home (
        .i_clk(i_clk),
        .i_rst(i_rst),
        .i_fatal_stop(i_fatal_error),
        .i_d_valid(home_d_valid),
        .o_d_ready(home_d_ready),
        .i_d(home_d),
        .o_p_valid(o_coherent_p_valid),
        .i_p_ready(i_coherent_p_ready),
        .o_p(o_coherent_p),
        .i_r_valid(i_coherent_r_valid),
        .o_r_ready(o_coherent_r_ready),
        .i_r(i_coherent_r),
        .i_w_valid(i_coherent_w_valid),
        .o_w_ready(o_coherent_w_ready),
        .i_w(i_coherent_w),
        .o_wa_valid(o_coherent_wa_valid),
        .i_wa_ready(i_coherent_wa_ready),
        .o_wa(o_coherent_wa),
        .o_g_valid(g_valid),
        .i_g_ready(g_ready),
        .o_g(grant),
        .i_c_valid(home_c_valid),
        .o_c_ready(home_c_ready),
        .i_c(home_c),
        .o_u_valid(u_valid),
        .i_u_ready(u_ready),
        .o_u(release_message),
        .o_mem_req_valid(down_req_valid),
        .i_mem_req_ready(down_req_ready),
        .o_mem_req_write(down_req_write),
        .o_mem_req_addr(down_req_addr),
        .o_mem_req_data(down_req_wdata),
        .o_mem_req_mask(down_req_wstrb),
        .o_mem_req_id(down_req_id),
        .i_mem_resp_valid(down_resp_valid),
        .i_mem_resp_id(down_resp_id),
        .i_mem_resp_data(down_resp_rdata),
        .i_mem_resp_error(down_resp_error),
        .o_perf_events(o_l2_perf_events),
        .o_write_perf_events(o_l2_write_perf_events),
        .o_fatal(o_cache_fatal),
        .o_fatal_addr(o_cache_fatal_addr)
    );
  end else begin : gen_no_cached_tier
    assign o_cache_fatal = 1'b0;
    assign o_cache_fatal_addr = '0;
    assign o_l2_perf_events = '0;
    assign o_l2_write_perf_events = '0;
    assign dma_req_ready = 1'b0;
    assign dma_resp_valid = 1'b0;
    assign dma_resp_id = '0;
    assign dma_resp_rdata = '0;
    assign dma_resp_error = 1'b0;
    assign down_req_valid = 1'b0;
    assign down_req_write = 1'b0;
    assign down_req_addr = '0;
    assign down_req_wdata = '0;
    assign down_req_wstrb = '0;
    assign down_req_id = '0;
  end

  if (ENABLE_CACHED_TIER == 0) begin : gen_no_coherent_channels
    assign o_coherent_d_ready = '0;
    assign o_coherent_p_valid = '0;
    assign o_coherent_p = '0;
    assign o_coherent_r_ready = '0;
    assign o_coherent_w_ready = '0;
    assign o_coherent_wa_valid = '0;
    assign o_coherent_wa = '0;
    assign o_coherent_g_valid = '0;
    assign o_coherent_g = '0;
    assign o_coherent_c_ready = '0;
    assign o_coherent_u_valid = '0;
    assign o_coherent_u = '0;
  end

  cpu_memory_fabric #(
      .FETCH_BYTES(FETCH_BYTES),
      .ADDR_WIDTH(riscv_pkg::PhysAddrBits),
      .DATA_BYTES(L2_LINE_BYTES),
      .ID_BITS(AXI_ID_BITS),
      .USER_BITS(AXI_USER_BITS),
      .MEMORY_PROT(AXI_MEMORY_PROT)
  ) memory_fabric (
      .i_clk,
      .i_rst,
      .i_axi_rst,
      .i_cache_valid(down_req_valid),
      .o_cache_ready(down_req_ready),
      .i_cache_write(down_req_write),
      .i_cache_addr(down_req_addr),
      .i_cache_wdata(down_req_wdata),
      .i_cache_wstrb(down_req_wstrb),
      .i_cache_id(down_req_id),
      .o_cache_resp_valid(down_resp_valid),
      .o_cache_resp_id(down_resp_id),
      .o_cache_resp_data(down_resp_rdata),
      .o_cache_resp_error(down_resp_error),
      .i_data_valid(i_data_req_valid),
      .o_data_ready(o_data_req_ready),
      .i_data_write(i_data_req_write),
      .i_data_addr(i_data_req_addr),
      .i_data_size(i_data_req_size),
      .i_data_cache(i_data_req_cache),
      .i_data_prot(i_data_req_prot),
      .i_data_wdata(i_data_req_wdata),
      .i_data_wstrb(i_data_req_wstrb),
      .o_data_resp_valid(o_data_resp_valid),
      .o_data_resp_data(o_data_resp_data),
      .o_data_resp_status(o_data_resp_status),
      .o_data_resp_ok(o_data_resp_ok),
      .i_fetch_valid(i_fetch_req_valid),
      .o_fetch_ready(o_fetch_req_ready),
      .i_fetch_addr(i_fetch_req_addr),
      .i_fetch_id(i_fetch_req_id),
      .o_fetch_resp_valid(o_fetch_resp_valid),
      .o_fetch_resp_id(o_fetch_resp_id),
      .o_fetch_resp_data(o_fetch_resp_data),
      .o_fetch_resp_error(o_fetch_resp_error),
      .o_idle(o_axi_idle),
      .o_axi_awvalid,
      .i_axi_awready,
      .o_axi_awid,
      .o_axi_awaddr,
      .o_axi_awlen,
      .o_axi_awsize,
      .o_axi_awburst,
      .o_axi_awlock,
      .o_axi_awcache,
      .o_axi_awprot,
      .o_axi_awqos,
      .o_axi_awregion,
      .o_axi_awuser,
      .o_axi_wvalid,
      .i_axi_wready,
      .o_axi_wdata,
      .o_axi_wstrb,
      .o_axi_wlast,
      .o_axi_wuser,
      .i_axi_bvalid,
      .o_axi_bready,
      .i_axi_bid,
      .i_axi_bresp,
      .i_axi_buser,
      .o_axi_arvalid,
      .i_axi_arready,
      .o_axi_arid,
      .o_axi_araddr,
      .o_axi_arlen,
      .o_axi_arsize,
      .o_axi_arburst,
      .o_axi_arlock,
      .o_axi_arcache,
      .o_axi_arprot,
      .o_axi_arqos,
      .o_axi_arregion,
      .o_axi_aruser,
      .i_axi_rvalid,
      .o_axi_rready,
      .i_axi_rid,
      .i_axi_rdata,
      .i_axi_rresp,
      .i_axi_rlast,
      .i_axi_ruser
  );
`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always @(posedge i_clk) begin
    if (i_rst) reset_seen_q <= 1'b1;
    if (reset_seen_q && !i_rst && ENABLE_COHERENCE && i_coherent_req_valid)
      assert (coherent_address_ok)
      else $error("frost_cluster_memory: coherent request outside cached memory");
  end
`endif
endmodule
