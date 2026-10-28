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
// CACHE_NORMAL_MEMORY permits aligned dword read fills for eligible Normal
// memory. Device/debug reads and all writes retain their original size.
// The buffered flag distinguishes retired stores from precise SC/AMO writes;
// only a retired store's late failure is fatal. No transaction is retried.
module cpu_uncached_adapter #(
    parameter bit CACHE_NORMAL_MEMORY = 1'b0,
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
    input logic i_write_buffered = 1'b0,
    input logic [63:0] i_write_data,
    input logic [7:0] i_write_strb,
    output logic o_write_done,
    output logic [1:0] o_write_status,
    output logic o_write_inflight,
    output logic o_idle,
    output logic o_fatal_error,
    output logic [ADDR_WIDTH-1:0] o_fatal_addr,

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
    input logic [1:0] i_resp_status,
    // i_resp_valid with an OKAY status, decoded before the response mux.
    input logic i_resp_ok
);

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) reset_seen_q <= 1'b1;
`endif
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
  logic write_buffered_q[2];
  logic [63:0] write_data_q[2];
  logic [7:0] write_strb_q[2];
  logic active_q, active_write_q;
  logic request_write;
  logic request_head, request_has_write, response_turnover;
  wire read_writethrough = !read_device_q && (CACHE_NORMAL_MEMORY && riscv_pkg::pma_writethrough_ok(
      64'(read_addr_q)
  ));
  wire write_writethrough = !write_device_q[request_head] &&
      (CACHE_NORMAL_MEMORY && riscv_pkg::pma_writethrough_ok(
      64'(write_addr_q[request_head])
  ));
  // Hold the selected client if the downstream arbiter stalls its request.
  logic request_held_q, held_write_q;
  logic req_fire, write_pop, write_push;

  wire fatal_write_reply = i_resp_valid && active_q && active_write_q &&
      i_resp_status[1] && write_buffered_q[write_head_q];
  assign write_pop = i_resp_valid && active_q && active_write_q && !i_rst && !fatal_write_reply;
  assign write_push = i_write_enable && o_write_ready;
  assign o_write_ready = !i_rst && !o_fatal_error && ((write_count_q < 2) || write_pop);
  assign o_read_ready = !i_rst && !o_fatal_error && !read_pending_q && !o_read_valid &&
      !(active_q && !active_write_q);
  // Queue the next request on a successful response edge. The fabric's
  // request register still separates it from AXI, whose master releases
  // this ID only after consuming the old response. Errors retain the
  // existing completion/recovery timing and never enable this turnover.
  assign response_turnover = i_resp_ok && active_q;
  assign request_head = write_head_q ^ write_pop;
  assign request_has_write = write_count_q > (write_pop ? 2'd1 : 2'd0);
  assign request_write = request_held_q ? held_write_q : request_has_write;
  // The request valid for each value of i_resp_ok, from registers only, so
  // the response reaches the fabric through one LUT. An OKAY response is a
  // valid one without an error, so it turns the active request over and pops
  // a completed write; otherwise an active request blocks.
  (* keep = "true" *) logic req_valid_if_ok, req_valid_if_none;
  assign req_valid_if_ok = !i_rst && !o_fatal_error &&
      (read_pending_q || (write_count_q > ((active_q && active_write_q) ? 2'd1 : 2'd0)));
  assign req_valid_if_none = !i_rst && !o_fatal_error && !active_q &&
      (read_pending_q || (write_count_q != 2'd0));
  assign o_req_valid = i_resp_ok ? req_valid_if_ok : req_valid_if_none;
  assign o_req_write = request_write;
  wire [ADDR_WIDTH-1:0] read_axi_addr = read_writethrough ?
      {read_addr_q[ADDR_WIDTH-1:3], 3'b0} : read_addr_q;
  wire [2:0] read_axi_size = read_writethrough ? 3'd3 : {1'b0, read_size_q};
  assign o_req_addr = request_write ? write_addr_q[request_head] : read_axi_addr;
  assign o_req_size = request_write ? {1'b0, write_size_q[request_head]} : read_axi_size;
  // Device Non-bufferable, Normal Non-cacheable Non-bufferable, or Normal
  // Write-through Read-allocate. Attributes follow PMA/policy, never AXI ID.
  wire [3:0] read_axi_cache = read_device_q ? 4'b0000 : read_writethrough ? 4'b1110 : 4'b0010;
  wire [3:0] write_axi_cache = write_device_q[request_head] ? 4'b0000 :
      write_writethrough ? 4'b0110 : 4'b0010;
  assign o_req_cache = request_write ? write_axi_cache : read_axi_cache;
  assign o_req_prot = DATA_PROT;
  assign o_req_wdata = request_write ? {(DATA_BYTES / 8) {write_data_q[request_head]}} : '0;
  assign o_req_wstrb = request_write ? DATA_BYTES'(write_strb_q[request_head]) <<
      {write_addr_q[request_head][OffsetBits-1:3], 3'b000} : '0;
  assign req_fire = o_req_valid && i_req_ready;
  assign o_write_inflight = write_count_q != 0;
  assign o_idle = !read_pending_q && !o_read_valid && !active_q && (write_count_q == 0);

  // Prepare the pending-bit alternatives without the late load-launch
  // pulse. Its last gate is then one LUT, instead of priority muxes for
  // enqueue, handoff and reset on the L0-miss-to-uncached-read path.
  (* keep = "true" *) logic read_pending_hold, read_pending_accept;
  assign read_pending_hold   = !i_rst && read_pending_q && !(req_fire && !request_write);
  assign read_pending_accept = !i_rst && o_read_ready && !(req_fire && !request_write);
  always_ff @(posedge i_clk) begin
    read_pending_q <= read_pending_hold || (i_read_enable && read_pending_accept);
    // An idle read slot may sample the candidate payload before its launch.
    // READY falls as soon as the slot is owned and stays low through the
    // response, preserving address/size/attributes and response byte lanes.
    if (o_read_ready) begin
      read_addr_q   <= i_read_addr;
      read_size_q   <= i_read_size;
      read_device_q <= i_read_device;
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_read_valid <= 1'b0;
      o_fatal_error <= 1'b0;
      o_fatal_addr <= '0;
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
      if (write_push) begin
        write_addr_q[write_tail_q] <= i_write_addr;
        write_size_q[write_tail_q] <= i_write_size;
        write_device_q[write_tail_q] <= i_write_device;
        write_buffered_q[write_tail_q] <= i_write_buffered;
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
      end
      if (fatal_write_reply) begin
        o_fatal_error <= 1'b1;
        o_fatal_addr  <= write_addr_q[write_head_q];
      end
      if (i_resp_valid && active_q && !fatal_write_reply) begin
        active_q <= req_fire;
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

`ifdef UNCACHED_READ_CAPTURE_LOCAL_PROOF
  logic reference_read_pending;
  always_comb begin
    reference_read_pending = read_pending_q;
    if (i_read_enable && o_read_ready) reference_read_pending = 1'b1;
    if (req_fire && !request_write) reference_read_pending = 1'b0;
    if (i_rst) reference_read_pending = 1'b0;
    p_read_pending_next_exact :
    assert ((read_pending_hold || (i_read_enable && read_pending_accept)) ==
            reference_read_pending);
  end
`endif

`ifndef SYNTHESIS
  always_comb begin
    p_resp_ok_exact : assert (i_resp_ok == (i_resp_valid && (i_resp_status == 2'b00)));
    p_req_valid_exact :
    assert (o_req_valid == (!i_rst && !o_fatal_error && (!active_q || response_turnover) &&
                            (request_has_write || read_pending_q)));
  end
  always @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
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
