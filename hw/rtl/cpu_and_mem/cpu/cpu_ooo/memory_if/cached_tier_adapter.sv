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
 * cached_tier_adapter: converts the data-memory request router's 64-bit beats
 * into line requests on the cache hierarchy's upstream port
 * (frost_cache_hierarchy).
 *
 * The router side moves one MemDataBits beat per transaction with MemStrbBits
 * byte strobes, as defined under "Data-tier bus contract" in hw/rtl/README.md.
 * The line side carries LINE_BYTES-byte lines.
 *
 * Router-side protocol:
 *   - i_read_req: a one-cycle pulse for an accepted cached-region load, with
 *     the load queue's slot id on i_read_id and the address on i_req_addr. It
 *     completes any number of cycles later with o_read_valid, o_read_id, and
 *     o_read_data (the addressed beat), held until i_read_ready. Up to
 *     READ_SLOTS reads may be outstanding, one per slot id, and they complete
 *     in line-response order.
 *   - i_write_byte_en != 0: a cached-region store fired this cycle, with its
 *     address on i_req_addr and its data on i_write_data, completed by an
 *     o_write_done pulse. One store is in flight at a time. o_write_inflight
 *     is high from the cycle after the store fires until the done pulse. The
 *     router ORs it into write_port_busy with its own write enables, which
 *     cover the fire cycle, so no load reaches the port while a cached store
 *     is pending.
 *
 * A read becomes a full-line read, and the addressed beat is selected from the
 * response. A write becomes a line write with the beat replicated across every
 * lane and the strobes on the addressed lane (the cache merges on a miss).
 * Reads use their slot number as the line id and the store uses WriteId.
 * Pending requests go out as soon as the cache is ready, the store first, so
 * several may be in flight; the cache orders same-line requests by acceptance.
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
  // Flops, not distributed RAM: every free slot is written in the same cycle,
  // which a distributed RAM's single write port cannot do. A free slot samples
  // i_req_addr on every clock (enable = the slot's own valid flop) and freezes
  // once its valid bit sets. i_read_req, a deep cone through the load queue's
  // L0 lookup and the router's accept gate, therefore enables only each
  // slot's valid and sent flops, not its address register. Only a valid
  // slot's address is ever used, so the idle contents do not matter.
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

  // Read responses leave through a registered output beat, so the router sees
  // flops. The router may hold that beat behind the fast tier's fixed-latency
  // response, so beats that land while it is occupied wait in a queue. Every
  // queued beat belongs to an outstanding read, so READ_SLOTS entries suffice.
  // A beat arriving with the output free bypasses the queue, keeping the
  // line-response-to-router latency at one cycle.
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

      // Enqueue router requests. The load queue launches only into a free
      // slot (checked below), so the valid and sent updates do not test the
      // slot state. The free-slot sampling captures the launched address on
      // the accepting edge (see rd_addr_q).
      for (int s = 0; s < int'(READ_SLOTS); s++) begin
        if (!rd_valid_q[s]) rd_addr_q[s] <= i_req_addr;
      end
      if (i_read_req) begin
        rd_valid_q[i_read_id] <= 1'b1;
        rd_sent_q[i_read_id]  <= 1'b0;
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

  assign o_write_inflight = pending_write_valid;

`ifndef SYNTHESIS
  logic                launch_check_q;
  logic [SlotBits-1:0] launch_id_q;
  logic [    XLEN-1:0] launch_addr_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) launch_check_q <= 1'b0;
    if (!i_rst) begin
      if (i_read_req && rd_valid_q[i_read_id])
        $error("cached_tier_adapter: read request on slot %0d while it is pending", i_read_id);
      // The free-slot sampling above captures the launched address exactly.
      launch_check_q <= i_read_req;
      launch_id_q    <= i_read_id;
      launch_addr_q  <= i_req_addr;
      if (launch_check_q && rd_addr_q[launch_id_q] !== launch_addr_q)
        $error("cached_tier_adapter: slot %0d did not capture its launch address", launch_id_q);
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
