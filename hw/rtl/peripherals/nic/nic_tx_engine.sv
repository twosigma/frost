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
 * One frame per descriptor, in ring order. Require length 1..MaxFrameBytes,
 * FIRST and LAST, and a buffer inside the aperture; otherwise complete with
 * DONE|ERR and send nothing. Read lines in address order, with up to four in
 * flight or held in the reorder buffer. nic_byte_unpack feeds 8-byte FIFO
 * beats; the last carries the remaining bytes and the last flag.
 * After the last beat enters the FIFO, all reads have been consumed and the
 * status word can be written. Its response reports completion. DONE means the
 * buffer has been read, not that the frame reached the wire. Only one status
 * write is in flight.
 *
 * While beats remain, i_abort (the MAC domain is resetting) abandons the
 * frame: stop pushing beats, wait for outstanding reads, then complete with
 * DONE|ERR|ABORT. i_stop (the RESET drain) abandons it without completion.
 * A descriptor rejected inside an open frame abandons that frame too: the merge and segment
 * stages are flushed, a last beat flagged o_fifo_abort closes whatever the FIFO already
 * holds of it, and the descriptor completes with DONE|ERR|ABORT. A frame's first segment is
 * at most MaxFrameBytes (65535 after a parameter descriptor); later segments may carry 65535.
 * i_enable low stops admission and descriptor fetching only; an admitted
 * frame finishes. BASE/SIZE change only while disabled and idle.
 */
module nic_tx_engine #(
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

    input  logic                  i_enable,
    input  logic                  i_wide_mode,
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
    // The frame's checksum request {offset/2, start/2, enable}, from the upper
    // bits of its FIRST descriptor's length word. It holds from the FIRST segment's
    // admission until the next FIRST segment, so it is valid on every beat of the
    // frame. Offset zero means no checksum.
    output logic [14:0] o_fifo_csum,
    // Set on the one-byte last beat that closes a frame the engine abandoned mid-way.
    output logic        o_fifo_abort,
    // A frame the segment stage could not segment, or whose length differed (one-cycle pulse).
    output logic        o_segment_err,

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
  // Reads in flight, one line of the DMA port each. Eight slots gained only 3 to 7% on a cold
  // transmit stream in simulation (the L2's miss registers and the port's 8 ids set the rate),
  // so the reorder buffer keeps its four.
  localparam int unsigned RobEntries = 4;
  localparam int unsigned SlotBits = $clog2(RobEntries);
  localparam int unsigned LineCountBits = 12;  // 65535 / LINE_BYTES + 2 fits

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
  logic [63:0] df_word0;
  logic [31:0] df_word1;
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

  // ---- the unpacker -------------------------------------------------------------------
  logic
      up_flush, up_start, up_line_valid, up_line_ready, up_beat_valid, up_beat_ready, up_beat_last;
  /* verilator lint_off UNUSEDSIGNAL */  // the engine tracks the frame itself
  logic up_busy;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [LINE_BYTES*8-1:0] up_line_data;
  logic [63:0] up_beat_data;
  logic [3:0] up_beat_bytes;
  // Frame context (below) that the unpacker reads.
  logic [15:0] len_q;
  logic [OffsetBits-1:0] offset_q;
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

  // ---- segments into FIFO beats -------------------------------------------------------
  logic last_q;  // the admitted segment ends its frame
  // Parameter descriptors: the parameters wait for the FIRST descriptor of the frame they
  // describe and then travel with it (f*), which the segment stage latches at the frame's first beat.
  logic first_q, param_q, param_pending_q;
  logic [31:0] param_w0_q, param_w1_q;  // this descriptor's words, read at S_IDLE
  logic [31:0] px_w0_q, px_w1_q;  // the pending parameter descriptor's words
  logic fseg_en_q, fseg_ip6_q, fseg_vlan_q;
  logic [13:0] fseg_mss_q;
  logic [15:0] fseg_payload_q;
  logic [6:0] fseg_l4off2_q;
  logic [3:0] fseg_tcphl4_q;
  logic in_frame_q;  // a frame has started and its LAST has not yet been admitted
  logic mg_in_ready, mg_out_valid, mg_out_ready;
  logic [63:0] mg_out_data;
  logic [3:0] mg_out_code;
  logic mg_flush;
  // A rejected descriptor inside an open frame abandons it: kill_q flushes the merge and segment
  // stages for a cycle, and inj_q closes the frame the FIFO already holds with an abort beat.
  logic kill_q, fifo_open_q, inj_q;
  assign mg_flush = i_stop || i_abort || kill_q;
  nic_tx_beat_merge u_merge (
      .i_clk      (i_clk),
      .i_rst      (i_rst),
      .i_flush    (mg_flush),
      .i_in_valid (up_beat_valid && !mg_flush),
      .o_in_ready (mg_in_ready),
      .i_in_data  (up_beat_data),
      .i_in_bytes (up_beat_bytes),
      .i_seg_last (up_beat_last),
      .i_frame_end(last_q),
      .o_out_valid(mg_out_valid),
      .i_out_ready(mg_out_ready),
      .o_out_data (mg_out_data),
      .o_out_code (mg_out_code),
      .o_busy     ()
  );

  // ---- frame context and the reorder buffer ----------------------------------------
  logic [ADDR_WIDTH-1:0] status_addr_q;
  logic [ADDR_WIDTH-OffsetBits-1:0] line_first_q;
  logic [LineCountBits-1:0] n_lines_q, issued_q, cons_q;
  logic bad_desc_q, err_q, abort_q, stop_q;
  logic desc_ok_q;  // the admit decision, registered
  logic [SlotBits:0] outstanding_q;  // reads accepted by the front-end, not yet answered
  logic dd_inflight_q;
  logic [2:0] dd_flags_q;
  logic [15:0] dd_bytes_q;  // the completion context, held while the next frame starts
  logic [RobEntries-1:0] rob_busy_q, rob_valid_q;  // busy: issued; valid: data landed
  logic [LINE_BYTES*8-1:0] rob_data_q[RobEntries];

  function automatic logic in_aperture(input logic [63:0] addr, input logic [15:0] len);
    logic [64:0] last_plus_one;
    last_plus_one = 65'(addr) + 65'(len);
    in_aperture = (addr >= APERTURE_BASE) &&
        ((ADDR_WIDTH == 64) || ((addr >> ADDR_WIDTH) == 0)) &&
        (last_plus_one <= (65'(APERTURE_BASE) + 65'(APERTURE_BYTES)));
  endfunction

  logic desc_ok;
  // A segment starts a frame when none is open, and continues one otherwise.
  // A frame's first segment is limited to MaxFrameBytes unless a parameter descriptor precedes it;
  // continuation segments take the full 16-bit length (the MAC and the segment stage bound the frame).
  logic [15:0] seg_max;
  assign seg_max = (df_word1[nic_pkg::TxWord1BitFirst] && !param_pending_q) ?
      16'(nic_pkg::MaxFrameBytes) : 16'hFFFF;
  assign desc_ok = (df_word1[15:0] != 16'd0) && (df_word1[15:0] <= seg_max) &&
      (df_word1[nic_pkg::TxWord1BitFirst] == !in_frame_q) && in_aperture(
      df_word0, df_word1[15:0]
  );
  logic desc_param;
  assign desc_param = (df_word1[15:0] == 16'd0) && !df_word1[nic_pkg::TxWord1BitFirst] &&
      !df_word1[nic_pkg::TxWord1BitLast] && df_word1[nic_pkg::TxWord1BitParam] && !in_frame_q;
  // S_IDLE registers descriptor validation; S_ADMIT starts the unpacker and
  // takes the descriptor. Recheck i_enable in S_ADMIT so a disable cancels
  // admission before the descriptor is taken.
  logic consider, admit;
  assign consider = (state_q == S_IDLE) && i_enable && !i_stop && !i_abort && df_desc_valid;
  assign admit    = (state_q == S_ADMIT) && i_enable && !i_stop && !i_abort && df_desc_valid;
  assign df_take  = admit;
  assign up_start = admit && desc_ok_q;
  // Lines covering [offset, offset + len): ((offset + len - 1) >> OffsetBits) + 1.
  logic [LineCountBits-1:0] n_lines_new;
  logic [16:0] span_last;  // offset + len - 1
  assign span_last   = 17'(df_word0[OffsetBits-1:0]) + 17'(df_word1[15:0]) - 17'd1;
  assign n_lines_new = LineCountBits'(span_last >> OffsetBits) + 1'b1;

  // ---- reads -----------------------------------------------------------------------------
  logic [SlotBits-1:0] issue_slot, cons_slot;
  assign issue_slot = issued_q[SlotBits-1:0];
  assign cons_slot  = cons_q[SlotBits-1:0];
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
  logic [14:0] csum_req_q;
  // The segment stage: a frame with a parameter descriptor ahead of it is cut into segments;
  // any other frame passes through.
  logic seg_in_ready, seg_out_valid;
  logic [63:0] seg_out_data;
  logic [ 3:0] seg_out_code;
  logic [14:0] seg_out_csum;
  nic_tx_segment u_segment (
      .i_clk        (i_clk),
      .i_rst        (i_rst),
      .i_flush      (mg_flush),
      .i_cfg_segment(fseg_en_q),
      .i_cfg_mss    (fseg_mss_q),
      .i_cfg_payload(fseg_payload_q),
      .i_cfg_l4_off2(fseg_l4off2_q),
      .i_cfg_tcphl4 (fseg_tcphl4_q),
      .i_cfg_ip6    (fseg_ip6_q),
      .i_cfg_vlan   (fseg_vlan_q),
      .i_cfg_csum   (csum_req_q),
      .i_in_valid   (mg_out_valid && !mg_flush),
      .o_in_ready   (seg_in_ready),
      .i_in_data    (mg_out_data),
      .i_in_code    (mg_out_code),
      .o_out_valid  (seg_out_valid),
      .i_out_ready  (i_fifo_ready && !mg_flush && !inj_q),
      .o_out_data   (seg_out_data),
      .o_out_code   (seg_out_code),
      .o_out_csum   (seg_out_csum),
      .o_err        (o_segment_err)
  );
  assign o_fifo_csum   = seg_out_csum;
  assign o_fifo_valid  = inj_q || (seg_out_valid && !mg_flush);
  assign o_fifo_data   = inj_q ? 64'b0 : seg_out_data;
  assign o_fifo_code   = inj_q ? 4'b1000 : seg_out_code;
  assign o_fifo_abort  = inj_q;
  assign mg_out_ready  = seg_in_ready && !mg_flush;
  assign up_beat_ready = mg_in_ready && !mg_flush;
  logic unpack_fire;  // a segment beat has entered the merge stage
  assign unpack_fire = up_beat_valid && up_beat_ready;

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
  logic [SlotBits-1:0] resp_slot;
  assign resp_slot = i_resp_tag[SlotBits-1:0];

  assign o_idle = (state_q == S_IDLE) && (outstanding_q == '0) && !dd_inflight_q && !df_pending;

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
      last_q           <= 1'b0;
      in_frame_q       <= 1'b0;
      csum_req_q       <= '0;
      first_q          <= 1'b0;
      param_q          <= 1'b0;
      param_pending_q  <= 1'b0;
      fseg_en_q        <= 1'b0;
      kill_q           <= 1'b0;
      fifo_open_q      <= 1'b0;
      inj_q            <= 1'b0;
    end else begin
      o_complete <= 1'b0;
      kill_q <= 1'b0;
      if (o_fifo_valid && i_fifo_ready) fifo_open_q <= !o_fifo_code[3];
      if (inj_q && i_fifo_ready) inj_q <= 1'b0;
      if (kill_q && fifo_open_q) inj_q <= 1'b1;
      // A stop or abort drops any open frame; the ring's driver resubmits it.
      if (i_stop || i_abort) begin
        in_frame_q      <= 1'b0;
        param_pending_q <= 1'b0;
        inj_q           <= 1'b0;
        fifo_open_q     <= 1'b0;
      end
      outstanding_q <= outstanding_q + (SlotBits + 1)'(rd_fire) - (SlotBits + 1)'(data_resp);
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
            last_q        <= df_word1[nic_pkg::TxWord1BitLast];
            first_q       <= df_word1[nic_pkg::TxWord1BitFirst];
            param_q       <= desc_param;
            param_w0_q    <= df_word0[31:0];
            param_w1_q    <= df_word1;
            if (df_word1[nic_pkg::TxWord1BitFirst]) begin
              csum_req_q <= {df_word1[31:25], df_word1[24:18], df_word1[31:25] != 7'd0};
            end
            offset_q     <= df_word0[OffsetBits-1:0];
            line_first_q <= df_word0[ADDR_WIDTH-1:OffsetBits];
            n_lines_q    <= n_lines_new;
            err_q        <= 1'b0;
            abort_q      <= 1'b0;
            stop_q       <= 1'b0;
            issued_q     <= '0;
            cons_q       <= '0;
            state_q      <= S_ADMIT;
          end
        end
        S_ADMIT: begin
          if (!admit) begin
            state_q <= S_IDLE;
          end else begin
            bad_desc_q <= !desc_ok_q && !param_q;
            in_frame_q <= desc_ok_q && !last_q;
            if (!desc_ok_q && !param_q && in_frame_q) begin
              // Abort the open frame: nothing of it may join the next frame's bytes.
              abort_q         <= 1'b1;
              kill_q          <= 1'b1;
              param_pending_q <= 1'b0;
            end
            state_q <= desc_ok_q ? S_DATA : S_STATUS;
            if (param_q) begin
              param_pending_q <= 1'b1;
              px_w0_q         <= param_w0_q;
              px_w1_q         <= param_w1_q;
            end
            if (desc_ok_q && first_q) begin
              // The frame takes the pending parameter descriptor, if any.
              fseg_en_q       <= param_pending_q;
              param_pending_q <= 1'b0;
              fseg_mss_q      <= px_w0_q[13:0];
              fseg_payload_q  <= px_w0_q[31:16];
              fseg_l4off2_q   <= px_w1_q[25:19];
              fseg_tcphl4_q   <= px_w1_q[29:26];
              fseg_ip6_q      <= px_w1_q[30];
              fseg_vlan_q     <= px_w1_q[31];
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
          end else if (unpack_fire && up_beat_last) begin
            state_q <= S_STATUS;
          end
        end
        S_DRAIN: begin
          // Reads in flight return (the drain answers withdrawn ones too);
          // the reorder buffer is cleared for the next frame.
          if (i_stop) stop_q <= 1'b1;
          if ((outstanding_q == '0) && !rd_fire) begin
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
  bit reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) reset_seen_q <= 1'b1;
    if (!i_sim_hold) begin
      if (reset_seen_q && !i_rst && data_resp && (outstanding_q == '0) && !rd_fire)
        $error("nic_tx_engine: data response with nothing outstanding");
      if (reset_seen_q && !i_rst && data_resp && !rob_busy_q[resp_slot] && !(state_q == S_DRAIN))
        $error("nic_tx_engine: data response for a free reorder slot %0d", resp_slot);
      if (reset_seen_q && !i_rst && status_resp && !dd_inflight_q)
        $error("nic_tx_engine: status response with no status write in flight");
    end
  end
`endif
`endif
endmodule : nic_tx_engine
