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
 * One frame per descriptor, in ring order. The FIFO holds a frame until an
 * eligible descriptor is cached. The first beat passes the filter if PROMISC
 * is set, its destination is a group address, or it matches the station.
 * Rejected frames consume no descriptor. Accepted frames with zero-length or
 * out-of-aperture buffers complete with DD|ERR. Other frames pass through
 * nic_byte_pack; bytes beyond the buffer length are dropped and set TRUNC.
 * After the last beat and all data responses, write descriptor word 2
 * (received length, DD, TRUNC, ERR, ABORT). Its response reports completion.
 * With i_rx_csum_en (ABI_CTRL bit 2) the status write is 8 bytes and also carries
 * the Internet checksum of the frame from byte 14 to its end (the bytes after the
 * Ethernet header; Linux CHECKSUM_COMPLETE), in the order the bytes would sit in
 * memory, so a little-endian CPU reads it as the kernel's folded sum. It is in
 * word 3 [15:0] in the legacy layout and in word 2 [31:16] (the buffer length
 * stays in [15:0]) in the extended layout, with RxStatusCsumValidBit set in the
 * status word only for a frame that completed without error, truncation, or
 * abort and reached byte 14.
 * Only one status write is in flight, preserving DD order while the next
 * frame's data may start.
 *
 * i_abort (the MAC domain is resetting) abandons a frame still owed beats:
 * no more are taken, the packer is flushed and its held write withdrawn, the
 * outstanding writes are awaited, and the descriptor completes with
 * DD|ERR|ABORT; a frame whose last beat is in completes normally. i_stop (the
 * RESET drain) abandons it with no completion and waits for the responses
 * owed; o_idle then says nothing is in flight. i_enable low stops admission
 * (including one about to act) and descriptor fetching only; a frame already
 * admitted finishes. The CSR block changes BASE/SIZE (i_restart)
 * only while the direction is disabled and idle, so a status write never
 * targets a stale ring.
 */
module nic_rx_engine #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned TAG_BITS = 4,
    parameter logic [63:0] APERTURE_BASE = 64'h8000_0000,
    parameter logic [63:0] APERTURE_BYTES = 64'h4000_0000
) (
    input logic i_clk,
    input logic i_rst,
`ifndef SYNTHESIS
`ifndef FORMAL
    input logic i_sim_hold = 1'b0,
`endif
`endif

    // Configuration and control.
    input  logic                  i_enable,
    input  logic                  i_wide_mode,
    input  logic                  i_rx_csum_en,
    input  logic [ADDR_WIDTH-1:0] i_base,
    input  logic [           4:0] i_size_log2,
    input  logic [          15:0] i_tail,
    input  logic                  i_restart,
    input  logic                  i_promisc,
    input  logic [          47:0] i_mac,         // byte 0 in bits 7:0
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
    S_ADMIT,
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
  logic [63:0] df_word0;
  /* verilator lint_off UNUSEDSIGNAL */  // word 1 bits above the length are reserved
  logic [31:0] df_word1;
  /* verilator lint_on UNUSEDSIGNAL */
  nic_desc_fetch #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .TAG_BITS  (TAG_BITS)
  ) u_desc (
`ifndef SYNTHESIS
`ifndef FORMAL
      .i_sim_hold        (i_sim_hold),
`endif
`endif
      .i_clk             (i_clk),
      .i_rst             (i_rst),
      .i_enable          (i_enable),
      .i_wide_mode       (i_wide_mode),
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
  // Frame context (below) that the packer reads.
  logic [ADDR_WIDTH-1:0] buf_addr_q;
  logic [15:0] buf_len_q;
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
      .i_addr      (buf_addr_q),
      .i_limit     (buf_len_q),
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
  logic [15:0] frame_len_q;
  logic bad_desc_q, err_q, abort_q, stop_q;
  logic accept_q, desc_ok_q;  // the admit decision, registered
  logic [2:0] outstanding_q;  // data writes accepted by the front-end, not yet answered
  logic [TAG_BITS-1:0] seq_q;
  logic dd_inflight_q;
  logic [2:0] dd_flags_q;
  logic [15:0] dd_bytes_q;

  function automatic logic in_aperture(input logic [63:0] addr, input logic [15:0] len);
    logic [64:0] last_plus_one;
    last_plus_one = 65'(addr) + 65'(len);
    in_aperture = (addr >= APERTURE_BASE) &&
        ((ADDR_WIDTH == 64) || ((addr >> ADDR_WIDTH) == 0)) &&
        (last_plus_one <= (65'(APERTURE_BASE) + 65'(APERTURE_BYTES)));
  endfunction

  // S_IDLE registers filter and descriptor checks; S_ADMIT acts on them.
  // The first beat and descriptor stay stable until taken. Recheck i_enable
  // in S_ADMIT so a disable cancels admission before the descriptor is taken.
  logic accept, desc_ok;
  assign accept  = i_promisc || i_fifo_data[0] || (i_fifo_data[47:0] == i_mac);
  assign desc_ok = (df_word1[15:0] != 16'd0) && in_aperture(df_word0, df_word1[15:0]);
  logic consider, admit;
  assign consider = (state_q == S_IDLE) && i_enable && !i_stop && !i_abort && i_fifo_valid &&
      df_desc_valid;
  assign admit = (state_q == S_ADMIT) && i_enable && !i_stop && !i_abort && df_desc_valid;
  assign df_take = admit && accept_q;
  assign pk_start = admit && accept_q && desc_ok_q;

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

  // Abort only while S_DATA still needs MAC beats. S_FLUSH can finish after
  // a MAC reset. i_stop abandons either state. Flush the packer and wait in
  // S_DRAIN for accepted writes.
  logic abandon;
  assign abandon = (i_stop && ((state_q == S_DATA) || (state_q == S_FLUSH))) ||
      (i_abort && (state_q == S_DATA));
  assign pk_flush = abandon;

  // ---- requests: status write, then data writes, then descriptor reads ----------------
  logic st_valid, st_fire, data_fire;
  assign st_valid = (state_q == S_STATUS) && !dd_inflight_q && !i_stop;
  // ---- the frame checksum (bytes 14 to the end, sixteen-bit big-endian words) --------
  // The beats are 8-byte aligned, so each beat holds four whole words. The first
  // beat is skipped and the second keeps only its last word. A final odd byte is
  // the high half of its word (the next lane is masked to zero).
  logic [31:0] csum_acc_q;
  logic [15:0] csum_w[4];
  logic [17:0] csum_beat_sum;
  logic [3:0] csum_lane_keep;
  always_comb begin
    for (int w = 0; w < 4; w++) begin
      logic lane0_ok, lane1_ok;
      lane0_ok = (beat_bytes > 4'(2 * w));
      lane1_ok = (beat_bytes > 4'(2 * w + 1));
      csum_w[w] = {
        lane0_ok ? i_fifo_data[16*w+:8] : 8'h00, lane1_ok ? i_fifo_data[16*w+8+:8] : 8'h00
      };
    end
    csum_lane_keep = (frame_len_q == 16'd0) ? 4'b0000 : (frame_len_q == 16'd8) ? 4'b1000 : 4'b1111;
    csum_beat_sum  = 18'd0;
    for (int w = 0; w < 4; w++)
    if (csum_lane_keep[w]) csum_beat_sum = csum_beat_sum + 18'(csum_w[w]);
  end
  logic [16:0] csum_fold1;
  logic [15:0] csum_sum16, csum_field;
  assign csum_fold1 = 17'(csum_acc_q[31:16]) + 17'(csum_acc_q[15:0]);
  assign csum_sum16 = csum_fold1[15:0] + 16'(csum_fold1[16]);
  assign csum_field = {csum_sum16[7:0], csum_sum16[15:8]};
  logic csum_valid;
  assign csum_valid = i_rx_csum_en && !err_q && !bad_desc_q && !abort_q && !trunc &&
      (frame_len_q >= 16'd14);

  logic [31:0] status_word;
  assign status_word = {
    11'b0,
    csum_valid,
    abort_q,
    (err_q || bad_desc_q || abort_q),
    (trunc && !bad_desc_q && !abort_q),
    1'b1,
    frame_len_q
  };
  logic [OffsetBits-1:0] status_off, status_pair_off;
  assign status_off = status_addr_q[OffsetBits-1:0];
  assign status_pair_off = {status_addr_q[OffsetBits-1:3], 3'b000};
  // Withdraw the packer's held write on abandonment. Writes already accepted
  // by the front-end still drain.
  logic pk_wr_present;
  assign pk_wr_present = pk_wr_valid && !abandon;
  always_comb begin
    o_req_valid = st_valid || pk_wr_present || df_rd_valid;
    if (st_valid) begin
      o_req_write = 1'b1;
      o_req_addr  = {status_addr_q[ADDR_WIDTH-1:OffsetBits], {OffsetBits{1'b0}}};
      if (i_rx_csum_en) begin
        // An 8-byte write of the descriptor's words 2 and 3, status and checksum
        // together so that DD never shows before the checksum.
        o_req_wdata = (LINE_BYTES * 8)'(i_wide_mode ?
            {status_word, csum_field, buf_len_q} : {16'b0, csum_field, status_word}) <<
            (8 * status_pair_off);
        o_req_wstrb = LINE_BYTES'(8'hFF) << status_pair_off;
      end else begin
        o_req_wdata = (LINE_BYTES * 8)'(status_word) << (8 * status_off);
        o_req_wstrb = LINE_BYTES'(4'hF) << status_off;
      end
      o_req_kind = nic_pkg::ReqKindStatus;
      o_req_tag  = '0;
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
      csum_acc_q       <= '0;
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
      if (beat_fire && (state_q == S_DATA)) csum_acc_q <= csum_acc_q + 32'(csum_beat_sum);

      case (state_q)
        S_IDLE: begin
          if (consider) begin
            accept_q      <= accept;
            desc_ok_q     <= desc_ok;
            status_addr_q <= df_status_addr;
            buf_addr_q    <= ADDR_WIDTH'(df_word0);
            buf_len_q     <= df_word1[15:0];
            frame_len_q   <= '0;
            csum_acc_q    <= '0;
            err_q         <= 1'b0;
            abort_q       <= 1'b0;
            stop_q        <= 1'b0;
            bad_desc_q    <= 1'b0;
            state_q       <= S_ADMIT;
          end
        end
        S_ADMIT: begin
          // A disable, the drain, a MAC-domain reset, or df_desc_valid
          // falling cancels the admission.
          if (!admit) begin
            state_q <= S_IDLE;
          end else if (!accept_q) begin
            state_q <= S_DISCARD;
          end else if (desc_ok_q) begin
            state_q <= S_DATA;
          end else begin
            bad_desc_q <= 1'b1;
            state_q    <= S_DISCARD;
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
  bit reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) reset_seen_q <= 1'b1;
    if (!i_sim_hold) begin
      if (reset_seen_q && !i_rst && data_resp && (outstanding_q == 3'd0) && !data_fire)
        $error("nic_rx_engine: data response with nothing outstanding");
      if (reset_seen_q && !i_rst && status_resp && !dd_inflight_q)
        $error("nic_rx_engine: status response with no status write in flight");
    end
  end
`endif
`endif
endmodule : nic_rx_engine
