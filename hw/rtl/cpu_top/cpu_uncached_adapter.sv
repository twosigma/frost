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

// Convert the CPU's aligned-dword data view to narrow AXI byte lanes.
// The router hands off one read; the SQ can hand off two stores before its
// completion FIFO applies backpressure. Each pulse is captured exactly once.
// Memory-system admission, device ordering, and the interrupt shield remain
// the router's responsibility. A store completes only after its B response.
// No transaction is retried, merged, prefetched, or widened here.
module cpu_uncached_adapter #(
    parameter int unsigned ADDR_WIDTH = 40,
    parameter int unsigned DATA_BYTES = 64,
    // The platform's AXI security/privilege domain for this CPU master.
    parameter logic [2:0] DATA_PROT = 3'b011
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_read_enable,
    output logic o_read_ready,
    input logic [ADDR_WIDTH-1:0] i_read_addr,
    input logic [1:0] i_read_size,
    input logic i_read_device,
    output logic o_read_valid,
    input logic i_read_resp_ready,
    output logic [63:0] o_read_data,
    output logic [1:0] o_read_status,
    input logic i_write_enable,
    output logic o_write_ready,
    input logic [ADDR_WIDTH-1:0] i_write_addr,
    input logic [1:0] i_write_size,
    input logic i_write_device,
    input logic [63:0] i_write_data,
    input logic [7:0] i_write_strb,
    output logic o_write_done,
    output logic [1:0] o_write_status,
    output logic o_write_inflight,
    output logic o_idle,

    output logic o_req_valid,
    input logic i_req_ready,
    output logic o_req_write,
    output logic [ADDR_WIDTH-1:0] o_req_addr,
    output logic [2:0] o_req_size,
    output logic [3:0] o_req_cache,
    output logic [2:0] o_req_prot,
    output logic [DATA_BYTES*8-1:0] o_req_wdata,
    output logic [DATA_BYTES-1:0] o_req_wstrb,
    input logic i_resp_valid,
    input logic [DATA_BYTES*8-1:0] i_resp_rdata,
    input logic [1:0] i_resp_status
);
  localparam int unsigned OffsetBits = $clog2(DATA_BYTES);
  initial begin
    if (DATA_BYTES < 16 || DATA_BYTES > 128 || (DATA_BYTES & (DATA_BYTES - 1)) != 0)
      $fatal(1, "cpu_uncached_adapter: expected a 16..128-byte power-of-two bus");
  end

  logic read_pending_q;
  logic [ADDR_WIDTH-1:0] read_addr_q;
  logic [1:0] read_size_q;
  logic read_device_q;
  logic [1:0] write_count_q;
  logic write_head_q, write_tail_q;
  logic [ADDR_WIDTH-1:0] write_addr_q[2];
  logic [1:0] write_size_q[2];
  logic write_device_q[2];
  logic [63:0] write_data_q[2];
  logic [7:0] write_strb_q[2];
  logic active_q, active_write_q;
  logic request_write;
  // Hold the selected client if the downstream arbiter stalls its request.
  logic request_held_q, held_write_q;
  logic req_fire, write_pop, write_push;

  assign write_pop = i_resp_valid && active_q && active_write_q && !i_rst;
  assign write_push = i_write_enable && o_write_ready;
  assign o_write_ready = !i_rst && ((write_count_q < 2) || write_pop);
  assign o_read_ready = !i_rst && !read_pending_q && !o_read_valid &&
      !(active_q && !active_write_q);
  assign request_write = request_held_q ? held_write_q : (write_count_q != 0);
  assign o_req_valid = !i_rst && !active_q && ((write_count_q != 0) || read_pending_q);
  assign o_req_write = request_write;
  assign o_req_addr = request_write ? write_addr_q[write_head_q] : read_addr_q;
  assign o_req_size = {1'b0, request_write ? write_size_q[write_head_q] : read_size_q};
  // Device Non-bufferable, or Normal Non-cacheable Non-bufferable. These
  // attributes come from PMA classification and have no relationship to ID.
  assign o_req_cache = (request_write ? write_device_q[write_head_q] : read_device_q) ?
      4'b0000 : 4'b0010;
  assign o_req_prot = DATA_PROT;
  assign o_req_wdata = request_write ? {(DATA_BYTES / 8) {write_data_q[write_head_q]}} : '0;
  assign o_req_wstrb = request_write ? DATA_BYTES'(write_strb_q[write_head_q]) <<
      {write_addr_q[write_head_q][OffsetBits-1:3], 3'b000} : '0;
  assign req_fire = o_req_valid && i_req_ready;
  assign o_write_inflight = write_count_q != 0;
  assign o_idle = !read_pending_q && !o_read_valid && !active_q && (write_count_q == 0);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      read_pending_q <= 1'b0;
      o_read_valid <= 1'b0;
      write_count_q <= 0;
      write_head_q <= 1'b0;
      write_tail_q <= 1'b0;
      active_q <= 1'b0;
      active_write_q <= 1'b0;
      request_held_q <= 1'b0;
      o_write_done <= 1'b0;
    end else begin
      o_write_done   <= write_pop;
      request_held_q <= o_req_valid && !i_req_ready;
      if (o_req_valid && !i_req_ready) held_write_q <= request_write;
      if (o_read_valid && i_read_resp_ready) o_read_valid <= 1'b0;
      if (i_read_enable && o_read_ready) begin
        read_pending_q <= 1'b1;
        read_addr_q <= i_read_addr;
        read_size_q <= i_read_size;
        read_device_q <= i_read_device;
      end
      if (write_push) begin
        write_addr_q[write_tail_q] <= i_write_addr;
        write_size_q[write_tail_q] <= i_write_size;
        write_device_q[write_tail_q] <= i_write_device;
        write_data_q[write_tail_q] <= i_write_data;
        write_strb_q[write_tail_q] <= i_write_strb;
        write_tail_q <= !write_tail_q;
      end
      case ({
        write_push, write_pop
      })
        2'b10:   write_count_q <= write_count_q + 1'b1;
        2'b01:   write_count_q <= write_count_q - 1'b1;
        default: ;
      endcase
      if (req_fire) begin
        active_q <= 1'b1;
        active_write_q <= request_write;
        if (!request_write) read_pending_q <= 1'b0;
      end
      if (i_resp_valid && active_q) begin
        active_q <= 1'b0;
        if (active_write_q) begin
          write_head_q   <= !write_head_q;
          o_write_status <= i_resp_status;
        end else begin
          o_read_valid  <= 1'b1;
          o_read_data   <= 64'(i_resp_rdata >> {read_addr_q[OffsetBits-1:3], 6'b000000});
          o_read_status <= i_resp_status;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always @(posedge i_clk) begin
    if (!i_rst) begin
      assert (!i_read_enable || o_read_ready)
      else $error("cpu_uncached_adapter: more than one outstanding uncached read");
      assert (!i_write_enable || o_write_ready)
      else $error("cpu_uncached_adapter: SQ exceeded two outstanding stores");
      assert (!i_resp_valid || active_q)
      else $error("cpu_uncached_adapter: response without an outstanding request");
    end
  end
`endif
endmodule
