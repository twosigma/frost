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
 * nic_rx_engine: frames from the RX FIFO into ring buffers.
 *
 * One frame per descriptor, in ring order. A frame is admitted only when an
 * eligible descriptor is cached (the FIFO holds it otherwise, so a ring-empty
 * window costs no frame); its first beat is examined for the filter
 * (PROMISC, a group address, or the station address) and a rejected frame
 * is consumed without touching a descriptor. An accepted frame takes the
 * descriptor: a buffer of length 0 or outside the aperture consumes the
 * frame and completes with DD|ERR; otherwise the beats go through
 * nic_byte_pack to strobed line writes at the buffer address, bytes beyond
 * the buffer length dropped (TRUNC). After the last beat, once every data
 * write has its response, the status word (descriptor word 2: received
 * length, DD, TRUNC, ERR, ABORT) is written; on its response the completion
 * is reported. One status write is in flight at a time, so DD becomes
 * visible in ring order; the next frame's data may start meanwhile.
 *
 * i_abort (the MAC domain is resetting: the stream epoch changes) abandons
 * a frame still owed beats: no more are taken, the packer is flushed and
 * its held write withdrawn, the outstanding writes are awaited and the
 * descriptor completes with DD|ERR|ABORT; a frame whose last beat is in
 * completes normally. i_stop (the RESET drain) abandons it with no completion and
 * waits for the responses owed; o_idle then says nothing is in flight.
 * i_enable low stops admission and descriptor fetching only. The CSR block
 * changes BASE/SIZE (i_restart) only while the direction is disabled and
 * idle, so a status write never targets a stale ring.
 */
module nic_rx_engine #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned TAG_BITS = 4,
    parameter logic [31:0] APERTURE_BASE = 32'h8000_0000,
    parameter logic [31:0] APERTURE_BYTES = 32'h4000_0000
) (
    input logic i_clk,
    input logic i_rst,

    // Configuration and control.
    input  logic                  i_enable,
    input  logic [ADDR_WIDTH-1:0] i_base,
    input  logic [           4:0] i_size_log2,
    input  logic [          15:0] i_tail,
    input  logic                  i_restart,
    input  logic                  i_promisc,
    input  logic [          47:0] i_mac,        // byte 0 in bits 7:0
    input  logic                  i_stop,
    input  logic                  i_abort,
    output logic [          15:0] o_head,
    output logic                  o_idle,

    // Beats from the RX FIFO (first-word-fall-through).
    input  logic        i_fifo_valid,
    output logic        o_fifo_ready,
    input  logic [63:0] i_fifo_data,
    input  logic [ 3:0] i_fifo_code,

    // The DMA front-end.
    output logic                    o_req_valid,
    input  logic                    i_req_ready,
    output logic                    o_req_write,
    output logic [  ADDR_WIDTH-1:0] o_req_addr,
    output logic [LINE_BYTES*8-1:0] o_req_wdata,
    output logic [  LINE_BYTES-1:0] o_req_wstrb,
    output logic [             1:0] o_req_kind,
    output logic [    TAG_BITS-1:0] o_req_tag,
    input  logic                    i_resp_valid,
    input  logic [             1:0] i_resp_kind,
    input  logic [    TAG_BITS-1:0] i_resp_tag,
    input  logic                    i_resp_error,
    input  logic [LINE_BYTES*8-1:0] i_resp_rdata,

    // Events (one-cycle pulses).
    output logic        o_complete,        // a status write's response returned
    output logic [ 2:0] o_complete_flags,  // {ABORT, ERR, TRUNC}
    output logic [15:0] o_complete_bytes,  // received length
    output logic        o_filtered         // a frame was rejected by the filter
);
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);

  typedef enum logic [2:0] {
    S_IDLE,
    S_DATA,
    S_DISCARD,
    S_FLUSH,
    S_DRAIN,
    S_STATUS
  } state_e;
  state_e state_q;

  // ---- descriptor supply -----------------------------------------------------------
  logic df_pending, df_rd_valid, df_rd_ready, df_desc_valid, df_take;
  logic [ADDR_WIDTH-1:0] df_rd_addr, df_status_addr;
  logic [TAG_BITS-1:0] df_rd_tag;
  logic [31:0] df_word0;
  /* verilator lint_off UNUSEDSIGNAL */  // word 1 bits above the length are reserved
  logic [31:0] df_word1;
  /* verilator lint_on UNUSEDSIGNAL */
  nic_desc_fetch #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .TAG_BITS  (TAG_BITS)
  ) u_desc (
      .i_clk             (i_clk),
      .i_rst             (i_rst),
      .i_enable          (i_enable),
      .i_base            (i_base),
      .i_size_log2       (i_size_log2),
      .i_tail            (i_tail),
      .i_invalidate      (i_stop || !i_enable),
      .i_restart         (i_restart),
      .o_head            (o_head),
      .o_pending         (df_pending),
      .o_rd_valid        (df_rd_valid),
      .i_rd_ready        (df_rd_ready),
      .o_rd_addr         (df_rd_addr),
      .o_rd_tag          (df_rd_tag),
      .i_resp_valid      (i_resp_valid && (i_resp_kind == nic_pkg::ReqKindDesc)),
      .i_resp_tag        (i_resp_tag),
      .i_resp_error      (i_resp_error),
      .i_resp_rdata      (i_resp_rdata),
      .o_desc_valid      (df_desc_valid),
      .o_desc_word0      (df_word0),
      .o_desc_word1      (df_word1),
      .o_desc_status_addr(df_status_addr),
      .i_desc_take       (df_take)
  );

  // ---- the packer --------------------------------------------------------------------
  logic pk_flush, pk_start, pk_beat_valid, pk_beat_ready, pk_wr_valid, pk_wr_ready, pk_busy;
  logic [ADDR_WIDTH-1:0] pk_wr_addr;
  logic [LINE_BYTES*8-1:0] pk_wr_wdata;
  logic [LINE_BYTES-1:0] pk_wr_wstrb;
  logic [3:0] beat_bytes;
  logic beat_last;
  assign beat_bytes = 4'(i_fifo_code[2:0]) + 4'd1;
  assign beat_last  = i_fifo_code[nic_pkg::BeatCodeLastBit];
  nic_byte_pack #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES)
  ) u_pack (
      .i_clk       (i_clk),
      .i_rst       (i_rst),
      .i_flush     (pk_flush),
      .i_start     (pk_start),
      .i_addr      (df_word0),
      .i_limit     (df_word1[15:0]),
      .i_beat_valid(pk_beat_valid),
      .o_beat_ready(pk_beat_ready),
      .i_beat_data (i_fifo_data),
      .i_beat_bytes(beat_bytes),
      .i_beat_last (beat_last),
      .o_wr_valid  (pk_wr_valid),
      .i_wr_ready  (pk_wr_ready),
      .o_wr_addr   (pk_wr_addr),
      .o_wr_wdata  (pk_wr_wdata),
      .o_wr_wstrb  (pk_wr_wstrb),
      .o_busy      (pk_busy)
  );

  // ---- frame context -------------------------------------------------------------------
  logic [ADDR_WIDTH-1:0] status_addr_q;
  logic [15:0] buf_len_q, frame_len_q;
  logic bad_desc_q, err_q, abort_q, stop_q;
  logic [2:0] outstanding_q;  // data writes accepted by the front-end, not yet answered
  logic [TAG_BITS-1:0] seq_q;
  logic dd_inflight_q;
  logic [2:0] dd_flags_q;
  logic [15:0] dd_bytes_q;

  function automatic logic in_aperture(input logic [ADDR_WIDTH-1:0] addr, input logic [15:0] len);
    logic [32:0] last_plus_one;
    last_plus_one = 33'(addr) + 33'(len);
    in_aperture = (addr >= APERTURE_BASE) &&
        (last_plus_one <= (33'(APERTURE_BASE) + 33'(APERTURE_BYTES)));
  endfunction

  logic accept, desc_ok;
  assign accept  = i_promisc || i_fifo_data[0] || (i_fifo_data[47:0] == i_mac);
  assign desc_ok = (df_word1[15:0] != 16'd0) && in_aperture(df_word0, df_word1[15:0]);
  logic admit;
  assign admit = (state_q == S_IDLE) && i_enable && !i_stop && !i_abort && i_fifo_valid &&
      df_desc_valid;
  assign df_take = admit && accept;
  assign pk_start = admit && accept && desc_ok;

  // ---- beats ---------------------------------------------------------------------------
  assign pk_beat_valid = (state_q == S_DATA) && i_fifo_valid && !i_stop && !i_abort;
  always_comb begin
    case (state_q)
      S_DATA:    o_fifo_ready = pk_beat_ready && !i_stop && !i_abort;
      S_DISCARD: o_fifo_ready = !i_stop && !i_abort;
      default:   o_fifo_ready = 1'b0;
    endcase
  end
  logic beat_fire;
  assign beat_fire = i_fifo_valid && o_fifo_ready;
  logic [16:0] frame_len_sum;
  assign frame_len_sum = 17'(frame_len_q) + 17'(beat_bytes);
  logic trunc;
  assign trunc = frame_len_q > buf_len_q;

  // Abandoning a frame: the packer is flushed and presents no more writes,
  // its beats stop, the writes already accepted are awaited in S_DRAIN. A
  // MAC-domain reset (i_abort) cuts a frame only while beats are still
  // owed (S_DATA); a frame whose last beat is in needs nothing from the MAC
  // any more and completes normally. The drain (i_stop) cuts either.
  logic abandon;
  assign abandon = (i_stop && ((state_q == S_DATA) || (state_q == S_FLUSH))) ||
      (i_abort && (state_q == S_DATA));
  assign pk_flush = abandon;

  // ---- requests: status write, then data writes, then descriptor reads ----------------
  logic st_valid, st_fire, data_fire;
  assign st_valid = (state_q == S_STATUS) && !dd_inflight_q && !i_stop;
  logic [31:0] status_word;
  assign status_word = {
    12'b0,
    abort_q,
    (err_q || bad_desc_q || abort_q),
    (trunc && !bad_desc_q && !abort_q),
    1'b1,
    frame_len_q
  };
  logic [OffsetBits-1:0] status_off;
  assign status_off = status_addr_q[OffsetBits-1:0];
  // A write the packer holds is withdrawn from the front-end in the cycle
  // the frame is abandoned (the flush drops it), so nothing of an abandoned
  // frame is written after the abort.
  logic pk_wr_present;
  assign pk_wr_present = pk_wr_valid && !abandon;
  always_comb begin
    o_req_valid = st_valid || pk_wr_present || df_rd_valid;
    if (st_valid) begin
      o_req_write = 1'b1;
      o_req_addr  = {status_addr_q[ADDR_WIDTH-1:OffsetBits], {OffsetBits{1'b0}}};
      o_req_wdata = (LINE_BYTES * 8)'(status_word) << (8 * status_off);
      o_req_wstrb = LINE_BYTES'(4'hF) << status_off;
      o_req_kind  = nic_pkg::ReqKindStatus;
      o_req_tag   = '0;
    end else if (pk_wr_present) begin
      o_req_write = 1'b1;
      o_req_addr  = pk_wr_addr;
      o_req_wdata = pk_wr_wdata;
      o_req_wstrb = pk_wr_wstrb;
      o_req_kind  = nic_pkg::ReqKindData;
      o_req_tag   = seq_q;
    end else begin
      o_req_write = 1'b0;
      o_req_addr  = df_rd_addr;
      o_req_wdata = '0;
      o_req_wstrb = '0;
      o_req_kind  = nic_pkg::ReqKindDesc;
      o_req_tag   = df_rd_tag;
    end
  end
  assign st_fire     = st_valid && i_req_ready;
  assign pk_wr_ready = i_req_ready && !st_valid && !abandon;
  assign data_fire   = pk_wr_present && pk_wr_ready;
  assign df_rd_ready = i_req_ready && !st_valid && !pk_wr_present;

  logic data_resp, status_resp;
  assign data_resp = i_resp_valid && (i_resp_kind == nic_pkg::ReqKindData);
  assign status_resp = i_resp_valid && (i_resp_kind == nic_pkg::ReqKindStatus);

  assign o_idle = (state_q == S_IDLE) && (outstanding_q == 3'd0) && !dd_inflight_q && !df_pending &&
      !pk_busy;


  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q          <= S_IDLE;
      outstanding_q    <= '0;
      seq_q            <= '0;
      dd_inflight_q    <= 1'b0;
      o_complete       <= 1'b0;
      o_filtered       <= 1'b0;
      bad_desc_q       <= 1'b0;
      err_q            <= 1'b0;
      abort_q          <= 1'b0;
      stop_q           <= 1'b0;
      frame_len_q      <= '0;
      buf_len_q        <= '0;
      o_complete_flags <= '0;
      o_complete_bytes <= '0;
    end else begin
      o_complete <= 1'b0;
      o_filtered <= 1'b0;
      outstanding_q <= outstanding_q + 3'(data_fire) - 3'(data_resp);
      if (data_fire) seq_q <= seq_q + 1'b1;
      if (data_resp && i_resp_error) err_q <= 1'b1;
      // A status response with the error flag is a write the drain withdrew
      // (the ring itself was validated): the slot frees, nothing completed.
      if (status_resp) begin
        dd_inflight_q    <= 1'b0;
        o_complete       <= !i_resp_error;
        o_complete_flags <= dd_flags_q;
        o_complete_bytes <= dd_bytes_q;
      end
      if (beat_fire) frame_len_q <= frame_len_sum[16] ? 16'hFFFF : frame_len_sum[15:0];

      case (state_q)
        S_IDLE: begin
          if (admit) begin
            frame_len_q <= '0;
            err_q       <= 1'b0;
            abort_q     <= 1'b0;
            stop_q      <= 1'b0;
            bad_desc_q  <= 1'b0;
            if (!accept) begin
              state_q <= S_DISCARD;
            end else begin
              status_addr_q <= df_status_addr;
              buf_len_q     <= df_word1[15:0];
              if (desc_ok) begin
                state_q <= S_DATA;
              end else begin
                bad_desc_q <= 1'b1;
                state_q    <= S_DISCARD;
              end
            end
          end
        end
        S_DATA: begin
          if (i_stop) begin
            stop_q  <= 1'b1;
            state_q <= S_DRAIN;
          end else if (i_abort) begin
            abort_q <= 1'b1;
            state_q <= S_DRAIN;
          end else if (beat_fire && beat_last) begin
            state_q <= S_FLUSH;
          end
        end
        S_DISCARD: begin
          if (i_stop) begin
            state_q <= S_IDLE;
          end else if (i_abort) begin
            abort_q <= 1'b1;
            state_q <= bad_desc_q ? S_STATUS : S_IDLE;
          end else if (beat_fire && beat_last) begin
            o_filtered <= !bad_desc_q;
            state_q    <= bad_desc_q ? S_STATUS : S_IDLE;
          end
        end
        S_FLUSH: begin
          // The frame is complete on this side (its last beat is in); only
          // the drain (no completion) cuts it, a MAC-domain reset does not.
          if (i_stop) begin
            stop_q  <= 1'b1;
            state_q <= S_DRAIN;
          end else if (!pk_busy && (outstanding_q == 3'd0) && !data_fire) begin
            state_q <= S_STATUS;
          end
        end
        S_DRAIN: begin
          if (i_stop) stop_q <= 1'b1;
          if ((outstanding_q == 3'd0) && !pk_busy)
            state_q <= (stop_q || i_stop) ? S_IDLE : S_STATUS;
        end
        S_STATUS: begin
          if (i_stop) begin
            state_q <= S_IDLE;
          end else if (st_fire) begin
            dd_inflight_q <= 1'b1;
            dd_flags_q    <= status_word[19:17];
            dd_bytes_q    <= frame_len_q;
            state_q       <= S_IDLE;
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  always_ff @(posedge i_clk) begin
    if (!i_rst && data_resp && (outstanding_q == 3'd0) && !data_fire)
      $error("nic_rx_engine: data response with nothing outstanding");
    if (!i_rst && status_resp && !dd_inflight_q)
      $error("nic_rx_engine: status response with no status write in flight");
  end
`endif
`endif
endmodule : nic_rx_engine
