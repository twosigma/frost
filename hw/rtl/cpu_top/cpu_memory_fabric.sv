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

// Arbitrate the tile's cache, uncached data, and uncached instruction traffic.
// IDs identify owners only: cache 0..31, uncached data 32, fetch slots 34/35.
// Each request's attributes are supplied independently of that allocation.
module cpu_memory_fabric #(
    parameter int unsigned ADDR_WIDTH = riscv_pkg::PhysAddrBits,
    parameter int unsigned DATA_BYTES = 64,
    parameter int unsigned FETCH_BYTES = 8,
    parameter int unsigned ID_BITS = 6,
    parameter int unsigned USER_BITS = 1,
    parameter logic [2:0] MEMORY_PROT = 3'b011
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_axi_rst,
    input logic i_cache_valid,
    output logic o_cache_ready,
    input logic i_cache_write,
    input logic [ADDR_WIDTH-1:0] i_cache_addr,
    input logic [DATA_BYTES*8-1:0] i_cache_wdata,
    input logic [DATA_BYTES-1:0] i_cache_wstrb,
    input logic [4:0] i_cache_id,
    output logic o_cache_resp_valid,
    output logic [4:0] o_cache_resp_id,
    output logic [DATA_BYTES*8-1:0] o_cache_resp_data,
    output logic o_cache_resp_error,
    input logic i_data_valid,
    output logic o_data_ready,
    input logic i_data_write,
    input logic [ADDR_WIDTH-1:0] i_data_addr,
    input logic [2:0] i_data_size,
    input logic [3:0] i_data_cache,
    input logic [2:0] i_data_prot,
    input logic [DATA_BYTES*8-1:0] i_data_wdata,
    input logic [DATA_BYTES-1:0] i_data_wstrb,
    output logic o_data_resp_valid,
    output logic [DATA_BYTES*8-1:0] o_data_resp_data,
    output logic [1:0] o_data_resp_status,
    // o_data_resp_valid with an OKAY status.
    output logic o_data_resp_ok,
    input logic i_fetch_valid,
    output logic o_fetch_ready,
    input logic [ADDR_WIDTH-1:0] i_fetch_addr,
    input logic i_fetch_id,
    output logic o_fetch_resp_valid,
    output logic o_fetch_resp_id,
    output logic [FETCH_BYTES*8-1:0] o_fetch_resp_data,
    output logic o_fetch_resp_error,
    output logic o_idle,
    output logic o_axi_awvalid,
    input logic i_axi_awready,
    output logic [ID_BITS-1:0] o_axi_awid,
    output logic [ADDR_WIDTH-1:0] o_axi_awaddr,
    output logic [7:0] o_axi_awlen,
    output logic [2:0] o_axi_awsize,
    output logic [1:0] o_axi_awburst,
    output logic o_axi_awlock,
    output logic [3:0] o_axi_awcache,
    output logic [2:0] o_axi_awprot,
    output logic [3:0] o_axi_awqos,
    output logic [3:0] o_axi_awregion,
    output logic [USER_BITS-1:0] o_axi_awuser,
    output logic o_axi_wvalid,
    input logic i_axi_wready,
    output logic [DATA_BYTES*8-1:0] o_axi_wdata,
    output logic [DATA_BYTES-1:0] o_axi_wstrb,
    output logic o_axi_wlast,
    output logic [USER_BITS-1:0] o_axi_wuser,
    input logic i_axi_bvalid,
    output logic o_axi_bready,
    input logic [ID_BITS-1:0] i_axi_bid,
    input logic [1:0] i_axi_bresp,
    input logic [USER_BITS-1:0] i_axi_buser,
    output logic o_axi_arvalid,
    input logic i_axi_arready,
    output logic [ID_BITS-1:0] o_axi_arid,
    output logic [ADDR_WIDTH-1:0] o_axi_araddr,
    output logic [7:0] o_axi_arlen,
    output logic [2:0] o_axi_arsize,
    output logic [1:0] o_axi_arburst,
    output logic o_axi_arlock,
    output logic [3:0] o_axi_arcache,
    output logic [2:0] o_axi_arprot,
    output logic [3:0] o_axi_arqos,
    output logic [3:0] o_axi_arregion,
    output logic [USER_BITS-1:0] o_axi_aruser,
    input logic i_axi_rvalid,
    output logic o_axi_rready,
    input logic [ID_BITS-1:0] i_axi_rid,
    input logic [DATA_BYTES*8-1:0] i_axi_rdata,
    input logic [1:0] i_axi_rresp,
    input logic i_axi_rlast,
    input logic [USER_BITS-1:0] i_axi_ruser
);
  initial begin
    if (ID_BITS < 6) $fatal(1, "cpu_memory_fabric requires at least six AXI ID bits");
    if (FETCH_BYTES < 8 || FETCH_BYTES > DATA_BYTES || (FETCH_BYTES & (FETCH_BYTES - 1)) != 0)
      $fatal(
          1, "cpu_memory_fabric fetch size must be an 8-byte-or-larger power of two fitting AXI"
      );
  end
  logic [1:0] next_client_q, selected;
  logic [2:0] requests;
  logic req_valid, req_ready, req_write;
  logic master_ready, master_idle, pending_q;
  logic [ADDR_WIDTH-1:0] req_addr;
  logic [2:0] req_size, req_prot;
  logic [3:0] req_cache;
  logic [DATA_BYTES*8-1:0] req_data;
  logic [DATA_BYTES-1:0] req_strb;
  logic [ID_BITS-1:0] req_id, resp_id;
  logic [ID_BITS-1:0] read_resp_id;
  logic [DATA_BYTES*8-1:0] read_resp_data;
  logic [1:0] read_resp_status;
  logic resp_write;
  logic queued_write;
  logic [ADDR_WIDTH-1:0] queued_addr;
  logic [2:0] queued_size, queued_prot;
  logic [3:0] queued_cache;
  logic [DATA_BYTES*8-1:0] queued_data;
  logic [DATA_BYTES-1:0] queued_strb;
  logic [ID_BITS-1:0] queued_id;
  logic resp_valid;
  logic [DATA_BYTES*8-1:0] resp_data;
  logic [1:0] resp_status;
  logic [$clog2(DATA_BYTES)-4:0] fetch_dword_q[2];
  assign requests = {i_fetch_valid, i_data_valid, i_cache_valid};
  always_comb begin
    selected = next_client_q;
    for (int offset = 2; offset >= 0; offset--) begin
      if (requests[(int'(next_client_q)+offset)%3])
        selected = 2'((int'(next_client_q) + offset) % 3);
    end
    req_valid = requests[selected];
    req_write = i_cache_write;
    req_addr = i_cache_addr;
    req_size = 3'($clog2(DATA_BYTES));
    req_cache = 4'b1111;
    req_prot = MEMORY_PROT;
    req_data = i_cache_wdata;
    req_strb = i_cache_wstrb;
    req_id = ID_BITS'(i_cache_id);
    if (selected == 1) begin
      req_write = i_data_write;
      req_addr = i_data_addr;
      req_size = i_data_size;
      req_cache = i_data_cache;
      req_prot = i_data_prot;
      req_data = i_data_wdata;
      req_strb = i_data_wstrb;
      req_id = ID_BITS'(32);
    end else if (selected == 2) begin
      req_write = 1'b0;
      req_addr = i_fetch_addr;
      req_size = 3'($clog2(FETCH_BYTES));
      req_cache = FETCH_BYTES > 8 ? 4'b1110 : 4'b0010;
      req_prot = MEMORY_PROT | 3'b100;
      req_data = '0;
      req_strb = '0;
      req_id = ID_BITS'(34) | ID_BITS'(i_fetch_id);
    end
  end
  // Register the arbitration result before the master's ID/channel checks.
  // Cache acceptance must not traverse the other clients' live valids,
  // the wide request mux, and the master's busy-ID lookup in one cycle.
  // A queued request has not yet been presented to AXI and may be discarded
  // by CPU reset; the master independently drains already presented beats.
  assign req_ready = !i_rst && !i_axi_rst && (!pending_q || master_ready);
  assign o_idle = master_idle && !pending_q;
  // The cache client's grant for each pointer value, so the L2's ready does
  // not wait for the encoded selection. Equal to selected == 0.
  logic cache_selected;
  always_comb begin
    unique case (next_client_q)
      2'd0: cache_selected = i_cache_valid || !(i_data_valid || i_fetch_valid);
      2'd1: cache_selected = i_cache_valid && !i_data_valid && !i_fetch_valid;
      2'd2: cache_selected = i_cache_valid && !i_fetch_valid;
      default: cache_selected = i_cache_valid;
    endcase
  end
  assign o_cache_ready = req_ready && cache_selected;
`ifndef SYNTHESIS
  always_comb begin
    p_cache_selected_exact : assert (cache_selected == (selected == 0));
  end
`endif
  assign o_data_ready  = req_ready && selected == 1;
  assign o_fetch_ready = req_ready && selected == 2;
  always_ff @(posedge i_clk) begin
    if (i_rst || i_axi_rst) begin
      next_client_q <= 0;
      pending_q <= 1'b0;
    end else begin
      if (pending_q && master_ready) pending_q <= 1'b0;
      if (req_valid && req_ready) begin
        next_client_q <= selected == 2 ? 0 : selected + 1'b1;
        pending_q <= 1'b1;
        queued_write <= req_write;
        queued_addr <= req_addr;
        queued_size <= req_size;
        queued_prot <= req_prot;
        queued_cache <= req_cache;
        queued_data <= req_data;
        queued_strb <= req_strb;
        queued_id <= req_id;
      end
    end
    if (i_fetch_valid && o_fetch_ready)
      fetch_dword_q[i_fetch_id] <= i_fetch_addr[$clog2(DATA_BYTES)-1:3];
  end
  assign o_cache_resp_valid = resp_valid && resp_id < ID_BITS'(32);
  assign o_cache_resp_id = resp_id[4:0];
  assign o_cache_resp_data = resp_data;
  assign o_cache_resp_error = resp_status[1];
  // The master decodes the data client's ID before its response select.
  logic data_resp_valid;
  assign o_data_resp_valid  = data_resp_valid;
  assign o_data_resp_data   = resp_data;
  assign o_data_resp_status = resp_status;
  logic data_resp_ok;
  assign o_data_resp_ok = data_resp_ok;
  assign o_fetch_resp_valid = resp_valid && (resp_id == ID_BITS'(34) || resp_id == ID_BITS'(35));
  // Fetch IDs belong only to reads. Select their word lanes from the R buffer
  // while the shared response arbitration controls publication.
  assign o_fetch_resp_id = read_resp_id[0];
  assign o_fetch_resp_data = (FETCH_BYTES * 8)'(read_resp_data >>
      {fetch_dword_q[read_resp_id[0]], 6'b0});
  assign o_fetch_resp_error = read_resp_status[1];

`ifndef SYNTHESIS
  always_comb begin
    if (o_fetch_resp_valid) begin
      p_fetch_response_is_read : assert (!resp_write);
      p_fetch_response_id_exact : assert (o_fetch_resp_id == resp_id[0]);
      p_fetch_response_data_exact :
      assert (o_fetch_resp_data == (FETCH_BYTES * 8)'(resp_data >>
              {fetch_dword_q[resp_id[0]], 6'b0}));
      p_fetch_response_error_exact : assert (o_fetch_resp_error == resp_status[1]);
    end
  end
`endif
  cpu_axi_master #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_BYTES(DATA_BYTES),
      .ID_BITS(ID_BITS),
      .USER_BITS(USER_BITS),
      .FLAG_RESP_ID(32)
  ) master (
      .i_clk,
      .i_rst,
      .i_axi_rst,
      .i_req_valid(pending_q),
      .o_req_ready(master_ready),
      .i_req_write(queued_write),
      .i_req_addr(queued_addr),
      .i_req_size(queued_size),
      .i_req_cache(queued_cache),
      .i_req_prot(queued_prot),
      .i_req_wdata(queued_data),
      .i_req_wstrb(queued_strb),
      .i_req_id(queued_id),
      .o_resp_valid(resp_valid),
      .i_resp_ready(1'b1),
      .o_resp_write(resp_write),
      .o_resp_id(resp_id),
      .o_resp_rdata(resp_data),
      .o_resp_status(resp_status),
      .o_resp_valid_id(data_resp_valid),
      .o_resp_ok_id(data_resp_ok),
      .o_read_resp_id(read_resp_id),
      .o_read_resp_rdata(read_resp_data),
      .o_read_resp_status(read_resp_status),
      .o_idle(master_idle),
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
endmodule
