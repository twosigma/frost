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
 * cached_tier_adapter: beat<->line adapter between the data-memory request
 * router and the cache hierarchy (the frost_cache_hierarchy upstream port).
 *
 * The router side moves one MemDataBits (64-bit) beat per transaction with
 * MemStrbBits byte strobes, the aligned-dword view defined under "Data-tier
 * bus contract" in hw/rtl/README.md. The line side carries 256-bit lines.
 *
 * Router-side protocol (handshake, variable-latency completion):
 *   - i_read_req: a 1-cycle pulse for an accepted cached-region load, tagged
 *     with the load queue's slot id (i_read_id). The address is on i_req_addr
 *     that cycle. It completes any number of cycles later with o_read_valid,
 *     o_read_id and o_read_data (the addressed beat, registered), held until
 *     i_read_ready. Up to READ_SLOTS reads may be outstanding, one per slot
 *     id, and their beats complete in line-response order.
 *   - i_write_byte_en != 0: a cached-region store fired this cycle, with
 *     address and data on i_req_addr and i_write_data. It completes with an
 *     o_write_done pulse. One store is in flight at a time.
 *     o_write_inflight stays high from the cycle after the fire until the done
 *     pulse, and the router folds it into write_port_busy so no load issues
 *     while a cached store is pending. The fire cycle itself is covered by
 *     sq_mem_write_en, so the port's load-vs-store ordering has no gap.
 *
 * Beat<->line conversion: a CPU read becomes a full-line read and the
 * addressed beat is muxed out of the 256-bit response. A CPU write becomes a
 * line write with the beat replicated across every lane and the byte strobes
 * shifted to the addressed lane (the cache merges on a miss).
 *
 * On the line port, reads carry their slot number and the store carries
 * WriteId. Pending requests go to the cache as soon as it is ready, the store
 * first, so several may be in flight, and the cache orders same-line requests
 * by acceptance. Read responses leave through a registered output beat. Beats
 * that land while it is occupied wait in a queue of depth READ_SLOTS, never
 * more than the number of outstanding reads, because the router may hold the
 * output behind the fast tier's fixed-latency response.
 */
module cached_tier_adapter #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned LINE_BYTES = 32,
    // Line-port transaction id width and the number of read slots (ids
    // 0..READ_SLOTS-1); the single store uses id READ_SLOTS.
    parameter int unsigned LINE_ID_BITS = 3,
    parameter int unsigned READ_SLOTS = riscv_pkg::CachedLoadSlots,
    localparam int unsigned SlotBits = (READ_SLOTS > 1) ? $clog2(READ_SLOTS) : 1
) (
    input logic i_clk,
    input logic i_rst,

    // Router-facing request side (one aligned beat per transaction).
    input logic                              i_read_req,
    input logic [              SlotBits-1:0] i_read_id,
    input logic [                  XLEN-1:0] i_req_addr,
    input logic [riscv_pkg::MemStrbBits-1:0] i_write_byte_en,
    input logic [riscv_pkg::MemDataBits-1:0] i_write_data,

    // Router-facing completion side.
    output logic [riscv_pkg::MemDataBits-1:0] o_read_data,
    output logic [              SlotBits-1:0] o_read_id,
    output logic                              o_read_valid,
    input  logic                              i_read_ready,
    output logic                              o_write_done,
    output logic                              o_write_inflight,

    // Line port master (to the cache hierarchy).
    output logic                    o_line_req_valid,
    input  logic                    i_line_req_ready,
    output logic                    o_line_req_write,
    output logic [        XLEN-1:0] o_line_req_addr,
    output logic [LINE_BYTES*8-1:0] o_line_req_wdata,
    output logic [  LINE_BYTES-1:0] o_line_req_wstrb,
    output logic [LINE_ID_BITS-1:0] o_line_req_id,
    input  logic                    i_line_resp_valid,
    input  logic [LINE_ID_BITS-1:0] i_line_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_line_resp_rdata
);

  localparam int unsigned BeatBits = riscv_pkg::MemDataBits;
  localparam int unsigned BeatStrbBits = riscv_pkg::MemStrbBits;
  localparam int unsigned BeatOffBits = $clog2(BeatStrbBits);  // addr bits below the beat index
  localparam int unsigned BeatsPerLine = LINE_BYTES / BeatStrbBits;
  localparam int unsigned BeatSelBits = $clog2(BeatsPerLine);
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam logic [LINE_ID_BITS-1:0] WriteId = LINE_ID_BITS'(READ_SLOTS);
  localparam int unsigned RespPtrBits = SlotBits + 1;

  initial begin
    if ((1 << LINE_ID_BITS) <= READ_SLOTS)
      $fatal(1, "cached_tier_adapter: LINE_ID_BITS cannot address the store id");
  end

  // ---- Read slots -------------------------------------------------------------
  logic [  READ_SLOTS-1:0] rd_valid_q;  // request accepted, response outstanding
  logic [  READ_SLOTS-1:0] rd_sent_q;  // line request fired
  // Flops, not distributed RAM: the write enable is the load queue's launch
  // pulse after the router's accept gate, a deep cone that meets timing into
  // a flop CE but not into a LUTRAM WE (x3 post-opt probe, -0.33 ns).
  (* ram_style = "registers" *)
  logic [        XLEN-1:0] rd_addr_q                                             [READ_SLOTS];

  // ---- Pending store ------------------------------------------------------------
  logic                    pending_write_valid;
  logic                    pending_write_sent;
  logic [        XLEN-1:0] pending_write_addr;
  logic [    BeatBits-1:0] pending_write_data;
  logic [BeatStrbBits-1:0] pending_write_byte_en;

  logic                    write_fire;
  assign write_fire = |i_write_byte_en;

  // ---- Issue: the store first, then the lowest unsent read slot ----------------
  logic                issue_write;
  logic                issue_read_any;
  logic [SlotBits-1:0] issue_read_sel;
  always_comb begin
    issue_read_any = 1'b0;
    issue_read_sel = '0;
    for (int s = int'(READ_SLOTS) - 1; s >= 0; s--) begin
      if (rd_valid_q[s] && !rd_sent_q[s]) begin
        issue_read_any = 1'b1;
        issue_read_sel = SlotBits'(s);
      end
    end
  end
  assign issue_write = pending_write_valid && !pending_write_sent;

  assign o_line_req_valid = issue_write || issue_read_any;
  assign o_line_req_write = issue_write;
  assign o_line_req_addr = issue_write ?
      {pending_write_addr[XLEN-1:OffsetBits], {OffsetBits{1'b0}}} :
      {rd_addr_q[issue_read_sel][XLEN-1:OffsetBits], {OffsetBits{1'b0}}};
  // Beat replicated across every lane; the strobes select the addressed lanes.
  assign o_line_req_wdata = {BeatsPerLine{pending_write_data}};
  always_comb begin
    o_line_req_wstrb = '0;
    o_line_req_wstrb[pending_write_addr[OffsetBits-1:BeatOffBits]*BeatStrbBits+:BeatStrbBits] =
        pending_write_byte_en;
  end
  assign o_line_req_id = issue_write ? WriteId : LINE_ID_BITS'(issue_read_sel);

  logic line_req_fire;
  assign line_req_fire = o_line_req_valid && i_line_req_ready;

  // ---- Responses --------------------------------------------------------------
  logic resp_is_write, resp_is_read;
  logic [SlotBits-1:0] resp_slot;
  assign resp_is_write = i_line_resp_valid && (i_line_resp_id == WriteId);
  assign resp_is_read  = i_line_resp_valid && (i_line_resp_id != WriteId);
  assign resp_slot     = SlotBits'(i_line_resp_id);

  // The addressed beat of a read response, selected by the slot's address.
  logic [BeatSelBits-1:0] resp_beat_sel;
  logic [BeatBits-1:0] resp_beat;
  assign resp_beat_sel = rd_addr_q[resp_slot][BeatOffBits+:BeatSelBits];
  assign resp_beat = i_line_resp_rdata[resp_beat_sel*BeatBits+:BeatBits];

  // Read responses: a registered output beat plus a queue for beats that land
  // while the output is occupied. The router still sees flops, as it did when
  // only one read could be in flight. A beat arriving with the output free
  // bypasses the queue, keeping the one-cycle line-response-to-router latency.
  logic [BeatBits-1:0] rq_data_q[READ_SLOTS];
  logic [SlotBits-1:0] rq_id_q  [READ_SLOTS];
  logic [RespPtrBits-1:0] rq_wr_q, rq_rd_q;
  logic rq_nonempty, rq_pop, rq_push, out_take;
  assign rq_nonempty = (rq_wr_q != rq_rd_q);
  // The output reloads when empty or when the router takes the beat.
  assign out_take = !o_read_valid || i_read_ready;
  assign rq_pop = out_take && rq_nonempty;
  // A new beat queues unless the output can take it straight away.
  assign rq_push = resp_is_read && !(out_take && !rq_nonempty);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      rd_valid_q          <= '0;
      rd_sent_q           <= '0;
      pending_write_valid <= 1'b0;
      pending_write_sent  <= 1'b0;
      o_write_done        <= 1'b0;
      o_read_valid        <= 1'b0;
      rq_wr_q             <= '0;
      rq_rd_q             <= '0;
    end else begin
      o_write_done <= 1'b0;

      // Enqueue router requests. The load queue only launches into a free
      // slot, asserted below, so the slot write is not qualified by the slot
      // state. That keeps the launch pulse's cone out of a wider enable.
      if (i_read_req) begin
        rd_valid_q[i_read_id] <= 1'b1;
        rd_sent_q[i_read_id]  <= 1'b0;
        rd_addr_q[i_read_id]  <= i_req_addr;
      end
      if (write_fire && !pending_write_valid) begin
        pending_write_valid   <= 1'b1;
        pending_write_sent    <= 1'b0;
        pending_write_addr    <= i_req_addr;
        pending_write_data    <= i_write_data;
        pending_write_byte_en <= i_write_byte_en;
      end

      // Launch.
      if (line_req_fire) begin
        if (issue_write) pending_write_sent <= 1'b1;
        else rd_sent_q[issue_read_sel] <= 1'b1;
      end

      // Retire on the line responses.
      if (resp_is_write) begin
        pending_write_valid <= 1'b0;
        o_write_done        <= 1'b1;
      end
      if (resp_is_read) rd_valid_q[resp_slot] <= 1'b0;
      if (rq_push) begin
        rq_data_q[rq_wr_q[SlotBits-1:0]] <= resp_beat;
        rq_id_q[rq_wr_q[SlotBits-1:0]] <= resp_slot;
        rq_wr_q <= rq_wr_q + 1'b1;
      end
      if (rq_pop) rq_rd_q <= rq_rd_q + 1'b1;
      // Output beat: queue head first (oldest), else the arriving beat.
      if (out_take) begin
        if (rq_nonempty) begin
          o_read_valid <= 1'b1;
          o_read_data  <= rq_data_q[rq_rd_q[SlotBits-1:0]];
          o_read_id    <= rq_id_q[rq_rd_q[SlotBits-1:0]];
        end else if (resp_is_read) begin
          o_read_valid <= 1'b1;
          o_read_data  <= resp_beat;
          o_read_id    <= resp_slot;
        end else begin
          o_read_valid <= 1'b0;
        end
      end
    end
  end

  // The store is "in flight" from the cycle after its fire until the done
  // pulse. The fire cycle itself is covered by sq_mem_write_en in the router's
  // write_port_busy, so coverage is gapless.
  assign o_write_inflight = pending_write_valid;

`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (i_read_req && rd_valid_q[i_read_id])
        $error("cached_tier_adapter: read request on slot %0d while it is pending", i_read_id);
      if (write_fire && pending_write_valid)
        $error("cached_tier_adapter: write request while a write is already pending");
      if (resp_is_write && !pending_write_sent)
        $error("cached_tier_adapter: write response with no write in flight");
      if (resp_is_read && !(rd_valid_q[resp_slot] && rd_sent_q[resp_slot]))
        $error("cached_tier_adapter: read response for slot %0d not in flight", resp_slot);
      if (rq_push && ((rq_wr_q - rq_rd_q) == RespPtrBits'(READ_SLOTS)))
        $error("cached_tier_adapter: read-response queue overflow");
    end
  end
`endif

endmodule : cached_tier_adapter
