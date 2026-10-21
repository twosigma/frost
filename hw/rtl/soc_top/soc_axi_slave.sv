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

// FROST's private AXI decode: physical DDR addresses pass to the board's
// 5-bit-ID line interface; low memory and devices use one local request port.
// The decode depends on addresses, never on cacheability encoded in AXI IDs.
// Both AXI and local interfaces retain ownership through backpressure. Only
// fabric reset cancels transactions; core-only reset does not reset this block.
module soc_axi_slave #(
    parameter int unsigned ADDR_WIDTH = riscv_pkg::PhysAddrBits,
    parameter int unsigned DATA_BYTES = 64,
    parameter int unsigned ID_BITS = 6,
    parameter int unsigned USER_BITS = 1,
    parameter longint unsigned DDR_BASE = riscv_pkg::DdrBase,
    parameter longint unsigned DDR_BYTES = riscv_pkg::DdrCapacityBytes
) (
    input  logic                                 i_clk,
    input  logic                                 i_axi_rst,
    output logic                                 o_local_valid,
    input  logic                                 i_local_ready,
    output logic                                 o_local_write,
    output logic [               ADDR_WIDTH-1:0] o_local_addr,
    output logic [                          2:0] o_local_size,
    output logic [                          2:0] o_local_prot,
    output logic [                         63:0] o_local_wdata,
    output logic [                          7:0] o_local_wstrb,
    output logic                                 o_local_error,
    input  logic                                 i_local_resp_valid,
    output logic                                 o_local_resp_ready,
    input  logic [             DATA_BYTES*8-1:0] i_local_resp_rdata,
    input  logic [                          1:0] i_local_resp_status,
    input  logic                                 i_axi_awvalid,
    output logic                                 o_axi_awready,
    input  logic [                  ID_BITS-1:0] i_axi_awid,
    input  logic [               ADDR_WIDTH-1:0] i_axi_awaddr,
    input  logic [                          7:0] i_axi_awlen,
    input  logic [                          2:0] i_axi_awsize,
    input  logic [                          1:0] i_axi_awburst,
    input  logic                                 i_axi_awlock,
    input  logic [                          3:0] i_axi_awcache,
    input  logic [                          2:0] i_axi_awprot,
    input  logic [                          3:0] i_axi_awqos,
    input  logic [                          3:0] i_axi_awregion,
    input  logic [                USER_BITS-1:0] i_axi_awuser,
    input  logic                                 i_axi_wvalid,
    output logic                                 o_axi_wready,
    input  logic [             DATA_BYTES*8-1:0] i_axi_wdata,
    input  logic [               DATA_BYTES-1:0] i_axi_wstrb,
    input  logic                                 i_axi_wlast,
    input  logic [                USER_BITS-1:0] i_axi_wuser,
    output logic                                 o_axi_bvalid,
    input  logic                                 i_axi_bready,
    output logic [                  ID_BITS-1:0] o_axi_bid,
    output logic [                          1:0] o_axi_bresp,
    output logic [                USER_BITS-1:0] o_axi_buser,
    input  logic                                 i_axi_arvalid,
    output logic                                 o_axi_arready,
    input  logic [                  ID_BITS-1:0] i_axi_arid,
    input  logic [               ADDR_WIDTH-1:0] i_axi_araddr,
    input  logic [                          7:0] i_axi_arlen,
    input  logic [                          2:0] i_axi_arsize,
    input  logic [                          1:0] i_axi_arburst,
    input  logic                                 i_axi_arlock,
    input  logic [                          3:0] i_axi_arcache,
    input  logic [                          2:0] i_axi_arprot,
    input  logic [                          3:0] i_axi_arqos,
    input  logic [                          3:0] i_axi_arregion,
    input  logic [                USER_BITS-1:0] i_axi_aruser,
    output logic                                 o_axi_rvalid,
    input  logic                                 i_axi_rready,
    output logic [                  ID_BITS-1:0] o_axi_rid,
    output logic [             DATA_BYTES*8-1:0] o_axi_rdata,
    output logic [                          1:0] o_axi_rresp,
    output logic                                 o_axi_rlast,
    output logic [                USER_BITS-1:0] o_axi_ruser,
    output logic                                 o_ddr_axi_awvalid,
    input  logic                                 i_ddr_axi_awready,
    output logic [                          4:0] o_ddr_axi_awid,
    output logic [riscv_pkg::DdrAxiAddrBits-1:0] o_ddr_axi_awaddr,
    output logic [                          7:0] o_ddr_axi_awlen,
    output logic [                          2:0] o_ddr_axi_awsize,
    output logic [                          1:0] o_ddr_axi_awburst,
    output logic                                 o_ddr_axi_wvalid,
    input  logic                                 i_ddr_axi_wready,
    output logic [             DATA_BYTES*8-1:0] o_ddr_axi_wdata,
    output logic [               DATA_BYTES-1:0] o_ddr_axi_wstrb,
    output logic                                 o_ddr_axi_wlast,
    input  logic                                 i_ddr_axi_bvalid,
    output logic                                 o_ddr_axi_bready,
    input  logic [                          4:0] i_ddr_axi_bid,
    input  logic [                          1:0] i_ddr_axi_bresp,
    output logic                                 o_ddr_axi_arvalid,
    input  logic                                 i_ddr_axi_arready,
    output logic [                          4:0] o_ddr_axi_arid,
    output logic [riscv_pkg::DdrAxiAddrBits-1:0] o_ddr_axi_araddr,
    output logic [                          7:0] o_ddr_axi_arlen,
    output logic [                          2:0] o_ddr_axi_arsize,
    output logic [                          1:0] o_ddr_axi_arburst,
    input  logic                                 i_ddr_axi_rvalid,
    output logic                                 o_ddr_axi_rready,
    input  logic [                          4:0] i_ddr_axi_rid,
    input  logic [             DATA_BYTES*8-1:0] i_ddr_axi_rdata,
    input  logic [                          1:0] i_ddr_axi_rresp,
    input  logic                                 i_ddr_axi_rlast
);
  localparam int unsigned OffsetBits = $clog2(DATA_BYTES);
  logic aw_valid_q, aw_sent_q, w_sent_q, aw_ddr_q, aw_bad_q;
  logic [ID_BITS-1:0] aw_id_q;
  logic [ADDR_WIDTH-1:0] aw_addr_q;
  logic [2:0] aw_size_q, aw_prot_q;
  logic ar_valid_q, ar_bad_q;
  logic [ID_BITS-1:0] ar_id_q;
  logic [ADDR_WIDTH-1:0] ar_addr_q;
  logic [2:0] ar_size_q, ar_prot_q;
  logic ar_ddr, ar_ddr_ok, aw_ddr, aw_ddr_ok;
  wire normal_instruction_line = i_axi_arprot[2] && i_axi_arsize == 5 && i_axi_araddr[4:0] == 0;
  assign ar_ddr = i_axi_araddr >= ADDR_WIDTH'(DDR_BASE) && 64'(i_axi_araddr) < DDR_BASE + DDR_BYTES;
  assign aw_ddr = i_axi_awaddr >= ADDR_WIDTH'(DDR_BASE) && 64'(i_axi_awaddr) < DDR_BASE + DDR_BYTES;
  // FROST's board DDR port has five ID bits and whole-line transactions.
  // The reusable CPU interface keeps all six bits; this private narrowing is
  // valid only for cache writebacks/fills. Reject an unsupported transaction
  // without aliasing an ID or physical address.
  assign ar_ddr_ok = ar_ddr && i_axi_arid < ID_BITS'(32) &&
      i_axi_arlen == 0 && i_axi_arsize == 3'(OffsetBits) && !i_axi_arlock;
  assign aw_ddr_ok = aw_ddr && i_axi_awid < ID_BITS'(32) &&
      i_axi_awlen == 0 && i_axi_awsize == 3'(OffsetBits) && !i_axi_awlock;

  logic local_busy_q, local_write_q;
  logic [ID_BITS-1:0] local_id_q;
  logic [OffsetBits-4:0] local_dword_q;
  logic local_r_valid_q, local_b_valid_q;
  logic [ID_BITS-1:0] local_r_id_q, local_b_id_q;
  logic [DATA_BYTES*8-1:0] local_r_data_q;
  logic [1:0] local_r_status_q, local_b_status_q;
  logic choose_read, can_read, can_write, prefer_write_q;
  logic local_hold_q, local_hold_read_q;
  logic local_fire, local_resp_fire;
  // An idle local address slot may pass an accepted address directly to
  // the local port. Backpressure still captures it in the existing slot.
  wire fresh_local_ar = i_axi_arvalid && !ar_valid_q && !ar_ddr_ok;
  wire fresh_local_aw = i_axi_awvalid && !aw_valid_q && !aw_ddr_ok;
  wire local_aw_valid = (aw_valid_q && !aw_ddr_q) || fresh_local_aw;
  wire [ID_BITS-1:0] local_ar_id = ar_valid_q ? ar_id_q : i_axi_arid;
  wire [ID_BITS-1:0] local_aw_id = aw_valid_q ? aw_id_q : i_axi_awid;
  wire [ADDR_WIDTH-1:0] local_ar_addr = ar_valid_q ? ar_addr_q : i_axi_araddr;
  wire [ADDR_WIDTH-1:0] local_aw_addr = aw_valid_q ? aw_addr_q : i_axi_awaddr;
  wire [2:0] local_ar_size = ar_valid_q ? ar_size_q : i_axi_arsize;
  wire [2:0] local_aw_size = aw_valid_q ? aw_size_q : i_axi_awsize;
  wire [2:0] local_ar_prot = ar_valid_q ? ar_prot_q : i_axi_arprot;
  wire [2:0] local_aw_prot = aw_valid_q ? aw_prot_q : i_axi_awprot;
  wire local_ar_bad = ar_valid_q ? ar_bad_q : ar_ddr || i_axi_arlen != 0 ||
      i_axi_arlock || (i_axi_arsize > 3 && !normal_instruction_line);
  wire local_aw_bad = aw_valid_q ? aw_bad_q : (aw_ddr && !aw_ddr_ok) ||
      i_axi_awlen != 0 || (!aw_ddr && i_axi_awsize > 3) || i_axi_awlock;
  assign can_read = (ar_valid_q || fresh_local_ar) && !local_r_valid_q;
  assign can_write = local_aw_valid && i_axi_wvalid && !local_b_valid_q;
  // Once presented, a local request keeps its owner through backpressure,
  // including when the other address channel arrives in a later cycle.
  assign choose_read = local_hold_q ? local_hold_read_q :
      can_read && (!can_write || !prefer_write_q);
  assign o_local_valid = !i_axi_rst && !local_busy_q && (can_read || can_write);
  assign o_local_write = !choose_read;
  assign o_local_addr = choose_read ? local_ar_addr : local_aw_addr;
  assign o_local_size = choose_read ? local_ar_size : local_aw_size;
  assign o_local_prot = choose_read ? local_ar_prot : local_aw_prot;
  assign o_local_wdata = 64'(i_axi_wdata >> {local_aw_addr[OffsetBits-1:3], 6'b0});
  assign o_local_wstrb = 8'(i_axi_wstrb >> {local_aw_addr[OffsetBits-1:3], 3'b0});
  assign o_local_error = choose_read ? local_ar_bad : local_aw_bad || !i_axi_wlast;
  assign local_fire = o_local_valid && i_local_ready;
  assign o_local_resp_ready = local_busy_q &&
      (local_write_q ? !local_b_valid_q : !local_r_valid_q) && !i_axi_rst;
  assign local_resp_fire = i_local_resp_valid && o_local_resp_ready;

  assign o_axi_awready = !aw_valid_q && !i_axi_rst;
  assign o_axi_wready = !i_axi_rst &&
      ((aw_valid_q && aw_ddr_q) ? !w_sent_q && i_ddr_axi_wready :
       local_aw_valid && !local_busy_q && !choose_read && !local_b_valid_q && i_local_ready);
  assign o_ddr_axi_awvalid = aw_valid_q && aw_ddr_q && !aw_sent_q && !i_axi_rst;
  assign o_ddr_axi_awid = aw_id_q[4:0];
  assign o_ddr_axi_awaddr = riscv_pkg::DdrAxiAddrBits'(aw_addr_q - ADDR_WIDTH'(DDR_BASE));
  assign o_ddr_axi_awlen = 0;
  assign o_ddr_axi_awsize = aw_size_q;
  assign o_ddr_axi_awburst = 2'b01;
  assign o_ddr_axi_wvalid = aw_valid_q && aw_ddr_q && !w_sent_q && i_axi_wvalid && !i_axi_rst;
  assign o_ddr_axi_wdata = i_axi_wdata;
  assign o_ddr_axi_wstrb = i_axi_wstrb;
  assign o_ddr_axi_wlast = i_axi_wlast;

  assign o_axi_arready = !i_axi_rst && (ar_ddr_ok ? i_ddr_axi_arready : !ar_valid_q);
  assign o_ddr_axi_arvalid = i_axi_arvalid && ar_ddr_ok && !i_axi_rst;
  assign o_ddr_axi_arid = i_axi_arid[4:0];
  assign o_ddr_axi_araddr = riscv_pkg::DdrAxiAddrBits'(i_axi_araddr - ADDR_WIDTH'(DDR_BASE));
  assign o_ddr_axi_arlen = 0;
  assign o_ddr_axi_arsize = i_axi_arsize;
  assign o_ddr_axi_arburst = 2'b01;

  logic r_hold_q, r_hold_local_q, r_local;
  logic b_hold_q, b_hold_local_q, b_local;
  // Forward a completed local response when its output slot is empty.
  // If AXI or DDR arbitration blocks it, the slot captures the exact beat.
  wire local_read_reply = local_resp_fire && !local_write_q;
  wire local_write_reply = local_resp_fire && local_write_q;
  wire local_r_available = local_r_valid_q || local_read_reply;
  wire local_b_available = local_b_valid_q || local_write_reply;
  wire [DATA_BYTES*8-1:0] local_reply_data = i_local_resp_rdata << {local_dword_q, 6'b0};
  assign r_local = r_hold_q ? r_hold_local_q : local_r_available;
  assign b_local = b_hold_q ? b_hold_local_q : local_b_available;
  assign o_axi_rvalid = !i_axi_rst && (r_local ? local_r_available : i_ddr_axi_rvalid);
  assign o_axi_rid =
      r_local ? (local_r_valid_q ? local_r_id_q : local_id_q) : ID_BITS'(i_ddr_axi_rid);
  assign o_axi_rdata =
      r_local ? (local_r_valid_q ? local_r_data_q : local_reply_data) : i_ddr_axi_rdata;
  assign o_axi_rresp =
      r_local ? (local_r_valid_q ? local_r_status_q : i_local_resp_status) : i_ddr_axi_rresp;
  assign o_axi_rlast = r_local ? 1'b1 : i_ddr_axi_rlast;
  assign o_axi_ruser = '0;
  assign o_ddr_axi_rready = !i_axi_rst && !r_local && i_axi_rready;
  assign o_axi_bvalid = !i_axi_rst && (b_local ? local_b_available : i_ddr_axi_bvalid);
  assign o_axi_bid =
      b_local ? (local_b_valid_q ? local_b_id_q : local_id_q) : ID_BITS'(i_ddr_axi_bid);
  assign o_axi_bresp =
      b_local ? (local_b_valid_q ? local_b_status_q : i_local_resp_status) : i_ddr_axi_bresp;
  assign o_axi_buser = '0;
  assign o_ddr_axi_bready = !i_axi_rst && !b_local && i_axi_bready;

  always_ff @(posedge i_clk) begin
    if (i_axi_rst) begin
      aw_valid_q <= 1'b0;
      aw_sent_q <= 1'b0;
      w_sent_q <= 1'b0;
      ar_valid_q <= 1'b0;
      local_busy_q <= 1'b0;
      local_r_valid_q <= 1'b0;
      local_b_valid_q <= 1'b0;
      r_hold_q <= 1'b0;
      b_hold_q <= 1'b0;
      prefer_write_q <= 1'b0;
      local_hold_q <= 1'b0;
    end else begin
      local_hold_q <= o_local_valid && !i_local_ready;
      if (o_local_valid) local_hold_read_q <= choose_read;
      r_hold_q <= o_axi_rvalid && !i_axi_rready;
      if (o_axi_rvalid) r_hold_local_q <= r_local;
      b_hold_q <= o_axi_bvalid && !i_axi_bready;
      if (o_axi_bvalid) b_hold_local_q <= b_local;
      if (o_axi_rvalid && i_axi_rready && r_local) local_r_valid_q <= 1'b0;
      if (o_axi_bvalid && i_axi_bready && b_local) local_b_valid_q <= 1'b0;
      if (i_axi_awvalid && o_axi_awready) begin
        aw_valid_q <= 1'b1;
        aw_sent_q <= 1'b0;
        w_sent_q <= 1'b0;
        aw_id_q <= i_axi_awid;
        aw_addr_q <= i_axi_awaddr;
        aw_size_q <= i_axi_awsize;
        aw_prot_q <= i_axi_awprot;
        aw_ddr_q <= aw_ddr_ok;
        aw_bad_q <= (aw_ddr && !aw_ddr_ok) || i_axi_awlen != 0 ||
            (!aw_ddr && i_axi_awsize > 3) || i_axi_awlock;
      end
      if (o_ddr_axi_awvalid && i_ddr_axi_awready) aw_sent_q <= 1'b1;
      if (o_ddr_axi_wvalid && i_ddr_axi_wready) w_sent_q <= 1'b1;
      if (aw_valid_q && aw_ddr_q && (aw_sent_q || i_ddr_axi_awready) &&
          (w_sent_q || (i_axi_wvalid && i_ddr_axi_wready)))
        aw_valid_q <= 1'b0;
      if (i_axi_arvalid && o_axi_arready && !ar_ddr_ok) begin
        ar_valid_q <= 1'b1;
        ar_id_q <= i_axi_arid;
        ar_addr_q <= i_axi_araddr;
        ar_size_q <= i_axi_arsize;
        ar_prot_q <= i_axi_arprot;
        ar_bad_q <= ar_ddr || i_axi_arlen != 0 || i_axi_arlock ||
            (i_axi_arsize > 3 && !normal_instruction_line);
      end
      if (local_fire) begin
        local_busy_q <= 1'b1;
        local_write_q <= !choose_read;
        local_id_q <= choose_read ? local_ar_id : local_aw_id;
        local_dword_q <= o_local_addr[OffsetBits-1:3];
        prefer_write_q <= choose_read;
        if (choose_read) ar_valid_q <= 1'b0;
        else aw_valid_q <= 1'b0;
      end
      if (local_resp_fire) begin
        local_busy_q <= 1'b0;
        if (local_write_q) begin
          local_b_valid_q <= !(b_local && i_axi_bready);
          local_b_id_q <= local_id_q;
          local_b_status_q <= i_local_resp_status;
        end else begin
          local_r_valid_q <= !(r_local && i_axi_rready);
          local_r_id_q <= local_id_q;
          local_r_data_q <= i_local_resp_rdata << {local_dword_q, 6'b0};
          local_r_status_q <= i_local_resp_status;
        end
      end
    end
  end
endmodule
