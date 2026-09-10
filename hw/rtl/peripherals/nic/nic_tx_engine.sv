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
 * nic_tx_engine: ring buffers into the TX FIFO.
 *
 * One frame per descriptor, in ring order. A descriptor is validated
 * (length 1..MaxFrameBytes, SOP and EOP, buffer inside the aperture);
 * an invalid one completes with DD|ERR and sends nothing. Otherwise the
 * buffer's lines are read in address order, up to four in flight or waiting
 * in a reorder buffer keyed by sequence, and nic_byte_unpack turns them into
 * 8-byte beats for the FIFO, the last beat carrying the remaining bytes and
 * the last flag. When the last beat has entered the FIFO (every read has
 * been consumed by then) the status word (DD) is written; on its response
 * the completion is reported: DD means the buffer has been read, not that
 * the frame reached the wire. One status write is in flight at a time.
 *
 * i_abort (the MAC domain is resetting) abandons the frame: no more beats
 * are pushed, the reads in flight are awaited, the descriptor completes
 * with DD|ERR|ABORT. i_stop (the RESET drain) abandons it with no
 * completion. i_enable low stops descriptor fetching only; the frame in
 * progress finishes. BASE/SIZE change only while disabled and idle.
 */
module nic_tx_engine #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned TAG_BITS = 4,
    parameter logic [31:0] APERTURE_BASE = 32'h8000_0000,
    parameter logic [31:0] APERTURE_BYTES = 32'h4000_0000
) (
    input logic i_clk,
    input logic i_rst,

    input  logic                  i_enable,
    input  logic [ADDR_WIDTH-1:0] i_base,
    input  logic [           4:0] i_size_log2,
    input  logic [          15:0] i_tail,
    input  logic                  i_restart,
    input  logic                  i_stop,
    input  logic                  i_abort,
    output logic [          15:0] o_head,
    output logic                  o_idle,

    // Beats into the TX FIFO.
    output logic        o_fifo_valid,
    input  logic        i_fifo_ready,
    output logic [63:0] o_fifo_data,
    output logic [ 3:0] o_fifo_code,

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
    output logic        o_complete,
    output logic [ 2:0] o_complete_flags,  // {ABORT, ERR, 0}
    output logic [15:0] o_complete_bytes   // descriptor length
);
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam int unsigned RobEntries = 4;
  localparam int unsigned LineCountBits = 10;  // MaxFrameBytes / LINE_BYTES + 2 fits

  typedef enum logic [2:0] {
    S_IDLE,
    S_ADMIT,
    S_DATA,
    S_DRAIN,
    S_STATUS
  } state_e;
  state_e state_q;

  // ---- descriptor supply -----------------------------------------------------------
  logic df_pending, df_rd_valid, df_rd_ready, df_desc_valid, df_take;
  logic [ADDR_WIDTH-1:0] df_rd_addr, df_status_addr;
  logic [TAG_BITS-1:0] df_rd_tag;
  logic [31:0] df_word0, df_word1;
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

  // ---- the unpacker -------------------------------------------------------------------
  logic
      up_flush, up_start, up_line_valid, up_line_ready, up_beat_valid, up_beat_ready, up_beat_last;
  /* verilator lint_off UNUSEDSIGNAL */  // the engine tracks the frame itself
  logic up_busy;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [LINE_BYTES*8-1:0] up_line_data;
  logic [63:0] up_beat_data;
  logic [3:0] up_beat_bytes;
  nic_byte_unpack #(
      .LINE_BYTES(LINE_BYTES)
  ) u_unpack (
      .i_clk       (i_clk),
      .i_rst       (i_rst),
      .i_flush     (up_flush),
      .i_start     (up_start),
      .i_offset    (offset_q),
      .i_len       (len_q),
      .i_line_valid(up_line_valid),
      .o_line_ready(up_line_ready),
      .i_line_data (up_line_data),
      .o_beat_valid(up_beat_valid),
      .i_beat_ready(up_beat_ready),
      .o_beat_data (up_beat_data),
      .o_beat_bytes(up_beat_bytes),
      .o_beat_last (up_beat_last),
      .o_busy      (up_busy)
  );

  // ---- frame context and the reorder buffer ----------------------------------------
  logic [ADDR_WIDTH-1:0] status_addr_q;
  logic [ADDR_WIDTH-OffsetBits-1:0] line_first_q;
  logic [LineCountBits-1:0] n_lines_q, issued_q, cons_q;
  logic [15:0] len_q;
  logic [OffsetBits-1:0] offset_q;
  logic bad_desc_q, err_q, abort_q, stop_q;
  logic desc_ok_q;  // the admit decision, registered
  logic [2:0] outstanding_q;
  logic dd_inflight_q;
  logic [2:0] dd_flags_q;
  logic [15:0] dd_bytes_q;  // the completion context, held while the next frame starts
  logic [RobEntries-1:0] rob_busy_q, rob_valid_q;  // busy: issued; valid: data landed
  logic [LINE_BYTES*8-1:0] rob_data_q[RobEntries];

  function automatic logic in_aperture(input logic [ADDR_WIDTH-1:0] addr, input logic [15:0] len);
    logic [32:0] last_plus_one;
    last_plus_one = 33'(addr) + 33'(len);
    in_aperture = (addr >= APERTURE_BASE) &&
        (last_plus_one <= (33'(APERTURE_BASE) + 33'(APERTURE_BYTES)));
  endfunction

  logic desc_ok;
  assign desc_ok = (df_word1[15:0] != 16'd0) && (df_word1[15:0] <= 16'(nic_pkg::MaxFrameBytes)) &&
      df_word1[nic_pkg::TxWord1BitSop] && df_word1[nic_pkg::TxWord1BitEop] && in_aperture(
      df_word0, df_word1[15:0]
  );
  // Admission takes two cycles: S_IDLE registers the validation of the head
  // descriptor, S_ADMIT acts on it, so the unpacker's start and the
  // descriptor take come from registers.
  logic consider, admit;
  assign consider = (state_q == S_IDLE) && i_enable && !i_stop && !i_abort && df_desc_valid;
  assign admit    = (state_q == S_ADMIT) && !i_stop && !i_abort && df_desc_valid;
  assign df_take  = admit;
  assign up_start = admit && desc_ok_q;
  // Lines covering [offset, offset + len): ((offset + len - 1) >> OffsetBits) + 1.
  logic [LineCountBits-1:0] n_lines_new;
  logic [16:0] span_last;  // offset + len - 1
  assign span_last   = 17'(df_word0[OffsetBits-1:0]) + 17'(df_word1[15:0]) - 17'd1;
  assign n_lines_new = LineCountBits'(span_last >> OffsetBits) + 1'b1;

  // ---- reads -----------------------------------------------------------------------------
  logic [1:0] issue_slot, cons_slot;
  assign issue_slot = issued_q[1:0];
  assign cons_slot  = cons_q[1:0];
  logic rd_valid, rd_fire;
  assign rd_valid = (state_q == S_DATA) && (issued_q != n_lines_q) && !rob_busy_q[issue_slot] &&
      !i_stop && !i_abort;
  logic [ADDR_WIDTH-1:0] rd_addr;
  assign rd_addr = {line_first_q + (ADDR_WIDTH - OffsetBits)'(issued_q), {OffsetBits{1'b0}}};

  assign up_line_valid = rob_valid_q[cons_slot];
  assign up_line_data = rob_data_q[cons_slot];
  logic line_fire;
  assign line_fire = up_line_valid && up_line_ready;

  // ---- beats --------------------------------------------------------------------------
  assign o_fifo_valid = up_beat_valid && !i_stop && !i_abort;
  assign o_fifo_data = up_beat_data;
  assign o_fifo_code = nic_pkg::beat_code(up_beat_last, up_beat_bytes);
  assign up_beat_ready = i_fifo_ready && !i_stop && !i_abort;
  logic beat_fire;
  assign beat_fire = o_fifo_valid && i_fifo_ready;

  // ---- requests: status write, then data reads, then descriptor reads -----------------
  logic st_valid, st_fire;
  assign st_valid = (state_q == S_STATUS) && !dd_inflight_q && !i_stop;
  logic [31:0] status_word;
  assign status_word = {12'b0, abort_q, (err_q || bad_desc_q || abort_q), 1'b0, 1'b1, 16'b0};
  logic [OffsetBits-1:0] status_off;
  assign status_off = status_addr_q[OffsetBits-1:0];
  always_comb begin
    o_req_valid = st_valid || rd_valid || df_rd_valid;
    if (st_valid) begin
      o_req_write = 1'b1;
      o_req_addr  = {status_addr_q[ADDR_WIDTH-1:OffsetBits], {OffsetBits{1'b0}}};
      o_req_wdata = (LINE_BYTES * 8)'(status_word) << (8 * status_off);
      o_req_wstrb = LINE_BYTES'(4'hF) << status_off;
      o_req_kind  = nic_pkg::ReqKindStatus;
      o_req_tag   = '0;
    end else if (rd_valid) begin
      o_req_write = 1'b0;
      o_req_addr  = rd_addr;
      o_req_wdata = '0;
      o_req_wstrb = '0;
      o_req_kind  = nic_pkg::ReqKindData;
      o_req_tag   = TAG_BITS'(issued_q);
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
  assign rd_fire     = rd_valid && !st_valid && i_req_ready;
  assign df_rd_ready = i_req_ready && !st_valid && !rd_valid;

  logic data_resp, status_resp;
  assign data_resp   = i_resp_valid && (i_resp_kind == nic_pkg::ReqKindData);
  assign status_resp = i_resp_valid && (i_resp_kind == nic_pkg::ReqKindStatus);
  logic [1:0] resp_slot;
  assign resp_slot = i_resp_tag[1:0];

  assign o_idle = (state_q == S_IDLE) && (outstanding_q == 3'd0) && !dd_inflight_q && !df_pending;

  logic abandon;
  assign abandon  = (i_stop || i_abort) && (state_q == S_DATA);
  assign up_flush = abandon;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q          <= S_IDLE;
      outstanding_q    <= '0;
      dd_inflight_q    <= 1'b0;
      rob_busy_q       <= '0;
      rob_valid_q      <= '0;
      issued_q         <= '0;
      cons_q           <= '0;
      n_lines_q        <= '0;
      o_complete       <= 1'b0;
      o_complete_flags <= '0;
      o_complete_bytes <= '0;
      bad_desc_q       <= 1'b0;
      err_q            <= 1'b0;
      abort_q          <= 1'b0;
      stop_q           <= 1'b0;
      len_q            <= '0;
    end else begin
      o_complete <= 1'b0;
      outstanding_q <= outstanding_q + 3'(rd_fire) - 3'(data_resp);
      if (rd_fire) begin
        rob_busy_q[issue_slot] <= 1'b1;
        issued_q <= issued_q + 1'b1;
      end
      if (data_resp) begin
        rob_valid_q[resp_slot] <= 1'b1;
        rob_data_q[resp_slot]  <= i_resp_rdata;
        if (i_resp_error) err_q <= 1'b1;
      end
      if (line_fire) begin
        rob_busy_q[cons_slot] <= 1'b0;
        rob_valid_q[cons_slot] <= 1'b0;
        cons_q <= cons_q + 1'b1;
      end
      // A status response with the error flag is a write the drain withdrew
      // (the ring itself was validated): the slot frees, nothing completed.
      if (status_resp) begin
        dd_inflight_q    <= 1'b0;
        o_complete       <= !i_resp_error;
        o_complete_flags <= dd_flags_q;
        o_complete_bytes <= dd_bytes_q;
      end

      case (state_q)
        S_IDLE: begin
          if (consider) begin
            desc_ok_q     <= desc_ok;
            status_addr_q <= df_status_addr;
            len_q         <= df_word1[15:0];
            offset_q      <= df_word0[OffsetBits-1:0];
            line_first_q  <= df_word0[ADDR_WIDTH-1:OffsetBits];
            n_lines_q     <= n_lines_new;
            err_q         <= 1'b0;
            abort_q       <= 1'b0;
            stop_q        <= 1'b0;
            issued_q      <= '0;
            cons_q        <= '0;
            state_q       <= S_ADMIT;
          end
        end
        S_ADMIT: begin
          if (!admit) begin
            state_q <= S_IDLE;
          end else begin
            bad_desc_q <= !desc_ok_q;
            state_q    <= desc_ok_q ? S_DATA : S_STATUS;
          end
        end
        S_DATA: begin
          if (i_stop) begin
            stop_q  <= 1'b1;
            state_q <= S_DRAIN;
          end else if (i_abort) begin
            abort_q <= 1'b1;
            state_q <= S_DRAIN;
          end else if (beat_fire && up_beat_last) begin
            state_q <= S_STATUS;
          end
        end
        S_DRAIN: begin
          // Reads in flight return (the drain answers withdrawn ones too);
          // the reorder buffer is cleared for the next frame.
          if (i_stop) stop_q <= 1'b1;
          if ((outstanding_q == 3'd0) && !rd_fire) begin
            rob_busy_q  <= '0;
            rob_valid_q <= '0;
            state_q     <= (stop_q || i_stop) ? S_IDLE : S_STATUS;
          end
        end
        S_STATUS: begin
          if (i_stop) begin
            state_q <= S_IDLE;
          end else if (st_fire) begin
            dd_inflight_q <= 1'b1;
            dd_flags_q    <= status_word[19:17];
            dd_bytes_q    <= len_q;
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
    if (!i_rst && data_resp && (outstanding_q == 3'd0) && !rd_fire)
      $error("nic_tx_engine: data response with nothing outstanding");
    if (!i_rst && data_resp && !rob_busy_q[resp_slot] && !(state_q == S_DRAIN))
      $error("nic_tx_engine: data response for a free reorder slot %0d", resp_slot);
    if (!i_rst && status_resp && !dd_inflight_q)
      $error("nic_tx_engine: status response with no status write in flight");
  end
`endif
`endif
endmodule : nic_tx_engine
