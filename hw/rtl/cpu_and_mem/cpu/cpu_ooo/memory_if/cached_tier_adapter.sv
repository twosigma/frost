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
 * cached_tier_adapter -- beat<->line adapter between the data-memory request
 * router and the cache hierarchy (frost_cache_hierarchy upstream port).
 *
 * The router side moves one MemDataBits (64-bit) beat per transaction with
 * MemStrbBits byte strobes, carrying the aligned-dword view defined in
 * docs/rv64/m1_data_tier.md; the line side is unchanged 256-bit lines.
 *
 * Router-side protocol (handshake, variable-latency completion):
 *   - i_read_req: 1-cycle pulse, an accepted cached-region load. The address
 *     is on i_req_addr that cycle. Completion: o_read_valid pulse with
 *     o_read_data (the addressed beat), any number of cycles later.
 *   - i_write_byte_en != 0: a cached-region store fired this cycle (addr/data
 *     on i_req_addr/i_write_data). Completion: o_write_done pulse.
 *     o_write_inflight stays high from the cycle AFTER the fire until the done
 *     pulse; the router folds it into write_port_busy so no load issues while
 *     a cached store is pending (the fire cycle itself is covered by
 *     sq_mem_write_en), preserving load-vs-store ordering on the port.
 *
 * Beat<->line conversion: a CPU read becomes a full-line read and the
 * addressed beat is muxed out of the 256-bit response. A CPU write becomes a
 * line write with the beat replicated across every lane and the byte strobes
 * shifted to the addressed lane (the cache merges on a miss).
 *
 * Serialization: at most one line request in flight. One pending-read slot +
 * one pending-write slot; when both are occupied the read is always the older
 * (the router blocks cached loads while a cached store is in flight, and the
 * LQ's slow_outstanding gate blocks every load while a cached load is in
 * flight), so reads are served first. Invariants are assertion-checked in
 * simulation AND hardware-refused: a request arriving while its slot is
 * still pending is dropped (deterministic upstream stall) rather than
 * absorbed, and the serving read's beat select is snapshotted at launch, so
 * an upstream gate regression can no longer silently corrupt the slot or
 * return the wrong beat as valid data.
 */
module cached_tier_adapter #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    parameter int unsigned LINE_BYTES = 32
) (
    input logic i_clk,
    input logic i_rst,

    // Router-facing request side (one aligned beat per transaction).
    input logic                              i_read_req,
    input logic [                  XLEN-1:0] i_req_addr,
    input logic [riscv_pkg::MemStrbBits-1:0] i_write_byte_en,
    input logic [riscv_pkg::MemDataBits-1:0] i_write_data,

    // Router-facing completion side.
    output logic [riscv_pkg::MemDataBits-1:0] o_read_data,
    output logic                              o_read_valid,
    output logic                              o_write_done,
    output logic                              o_write_inflight,

    // Line port master (to the cache hierarchy).
    output logic                    o_line_req_valid,
    input  logic                    i_line_req_ready,
    output logic                    o_line_req_write,
    output logic [        XLEN-1:0] o_line_req_addr,
    output logic [LINE_BYTES*8-1:0] o_line_req_wdata,
    output logic [  LINE_BYTES-1:0] o_line_req_wstrb,
    input  logic                    i_line_resp_valid,
    input  logic [LINE_BYTES*8-1:0] i_line_resp_rdata
);

  localparam int unsigned BeatBits = riscv_pkg::MemDataBits;
  localparam int unsigned BeatStrbBits = riscv_pkg::MemStrbBits;
  localparam int unsigned BeatOffBits = $clog2(BeatStrbBits);  // addr bits below the beat index
  localparam int unsigned BeatsPerLine = LINE_BYTES / BeatStrbBits;
  localparam int unsigned BeatSelBits = $clog2(BeatsPerLine);
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);

  // ---- Pending request slots -------------------------------------------------
  logic                    pending_read_valid;
  logic [        XLEN-1:0] pending_read_addr;
  logic                    pending_write_valid;
  logic [        XLEN-1:0] pending_write_addr;
  logic [    BeatBits-1:0] pending_write_data;
  logic [BeatStrbBits-1:0] pending_write_byte_en;

  logic                    write_fire;
  assign write_fire = |i_write_byte_en;

  // ---- Issue FSM: one line transaction in flight ------------------------------
  logic busy_q;  // a line request has fired and its response is outstanding
  logic serving_read_q;

  logic issue_read, issue_write;
  assign issue_read = !busy_q && pending_read_valid;
  assign issue_write = !busy_q && !pending_read_valid && pending_write_valid;

  assign o_line_req_valid = issue_read || issue_write;
  assign o_line_req_write = issue_write;
  assign o_line_req_addr = issue_write ?
      {pending_write_addr[XLEN-1:OffsetBits], {OffsetBits{1'b0}}} :
      {pending_read_addr[XLEN-1:OffsetBits], {OffsetBits{1'b0}}};
  // Beat replicated across every lane; the strobes select the addressed lanes.
  assign o_line_req_wdata = {BeatsPerLine{pending_write_data}};
  always_comb begin
    o_line_req_wstrb = '0;
    o_line_req_wstrb[pending_write_addr[OffsetBits-1:BeatOffBits]*BeatStrbBits+:BeatStrbBits] =
        pending_write_byte_en;
  end

  logic line_req_fire;
  assign line_req_fire = o_line_req_valid && i_line_req_ready;

  // Beat select for the read response, captured from the pending read address.
  logic [BeatSelBits-1:0] read_beat_sel;
  assign read_beat_sel = pending_read_addr[BeatOffBits+:BeatSelBits];

  // HARDENING: the serving transaction's beat select, snapshotted at launch.
  // The upstream gates (LQ slow_outstanding, router write_port_busy) are the
  // real single-outstanding guarantee, but if they ever regress and a second
  // read overwrites pending_read_addr mid-flight, muxing the response through
  // the LIVE address would silently return the WRONG BEAT as valid data.
  // Snapshotting at line_req_fire makes the in-flight response immune; the
  // duplicate request itself is refused below (deterministic stall, caught by
  // the sim assertions) instead of corrupting state.
  logic [BeatSelBits-1:0] serving_beat_sel_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      pending_read_valid  <= 1'b0;
      pending_write_valid <= 1'b0;
      busy_q              <= 1'b0;
      serving_read_q      <= 1'b0;
      o_read_valid        <= 1'b0;
      o_write_done        <= 1'b0;
    end else begin
      o_read_valid <= 1'b0;
      o_write_done <= 1'b0;

      // Enqueue router requests. A request while the same-type slot is still
      // pending is a protocol violation (see the assertions below): refuse it
      // so the in-flight transaction's identity/data stay intact -- the
      // violator hangs waiting for a completion that never comes, which is
      // deterministic and debuggable, unlike a silently corrupted slot.
      if (i_read_req && !pending_read_valid) begin
        pending_read_valid <= 1'b1;
        pending_read_addr  <= i_req_addr;
      end
      if (write_fire && !pending_write_valid) begin
        pending_write_valid   <= 1'b1;
        pending_write_addr    <= i_req_addr;
        pending_write_data    <= i_write_data;
        pending_write_byte_en <= i_write_byte_en;
      end

      // Launch the next line transaction.
      if (line_req_fire) begin
        busy_q             <= 1'b1;
        serving_read_q     <= issue_read;
        serving_beat_sel_q <= read_beat_sel;
      end

      // Retire on the line response.
      if (busy_q && i_line_resp_valid) begin
        busy_q <= 1'b0;
        if (serving_read_q) begin
          pending_read_valid <= 1'b0;
          o_read_valid       <= 1'b1;
          o_read_data        <= i_line_resp_rdata[serving_beat_sel_q*BeatBits+:BeatBits];
        end else begin
          pending_write_valid <= 1'b0;
          o_write_done        <= 1'b1;
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
      if (i_read_req && pending_read_valid)
        $error("cached_tier_adapter: read request while a read is already pending");
      if (i_read_req && pending_write_valid)
        $error("cached_tier_adapter: read request while a write is pending (router must block)");
      if (write_fire && pending_write_valid)
        $error("cached_tier_adapter: write request while a write is already pending");
      if (i_line_resp_valid && !busy_q)
        $error("cached_tier_adapter: line response with no transaction in flight");
    end
  end
`endif

endmodule : cached_tier_adapter
