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

module nic_tx_hold_formal (
    input logic i_clk,
    input logic i_rst,
    input logic i_tx_domain_ready,
    input logic i_stop,
    input logic i_fifo_ready
);
  (* anyseq *) logic enable;
  logic wide_mode, restart;
  logic [31:0] base;
  logic [ 4:0] size_log2;
  logic [15:0] ring_tail;
  logic fifo_valid, fifo_abort;
  logic [63:0] fifo_data;
  logic [ 3:0] fifo_code;
  logic [14:0] fifo_csum;
  logic req_valid, req_ready, resp_valid, resp_error;
  logic [31:0] req_addr;
  logic [1:0] req_kind, resp_kind;
  logic [3:0] req_tag, resp_tag;
  logic [255:0] resp_data;

  nic_tx_engine dut (
      .i_clk           (i_clk),
      .i_rst           (i_rst),
      .i_enable        (enable),
      .i_wide_mode     (wide_mode),
      .i_base          (base),
      .i_size_log2     (size_log2),
      .i_tail          (ring_tail),
      .i_restart       (restart),
      .i_stop          (i_stop),
      .i_abort         (!i_tx_domain_ready),
      .o_head          (),
      .o_idle          (),
      .o_fifo_valid    (fifo_valid),
      .i_fifo_ready    (i_fifo_ready),
      .o_fifo_data     (fifo_data),
      .o_fifo_code     (fifo_code),
      .o_fifo_csum     (fifo_csum),
      .o_fifo_abort    (fifo_abort),
      .o_segment_err   (),
      .o_req_valid     (req_valid),
      .i_req_ready     (req_ready),
      .o_req_write     (),
      .o_req_addr      (req_addr),
      .o_req_wdata     (),
      .o_req_wstrb     (),
      .o_req_kind      (req_kind),
      .o_req_tag       (req_tag),
      .i_resp_valid    (resp_valid),
      .i_resp_kind     (resp_kind),
      .i_resp_tag      (resp_tag),
      .i_resp_error    (resp_error),
      .i_resp_rdata    (resp_data),
      .o_complete      (),
      .o_complete_flags(),
      .o_complete_bytes()
  );

  logic past_valid = 1'b0;
  logic stalled_q, stalled;
  // Keep data and metadata visible in the cover traces.
  (* keep *)logic [83:0] payload;
  logic [83:0] payload_q;
  assign stalled = fifo_valid && !i_fifo_ready;
  assign payload = {fifo_data, fifo_code, fifo_csum, fifo_abort};
  always_ff @(posedge i_clk) begin
    past_valid <= 1'b1;
    if (!past_valid) initial_reset : assume (i_rst);

    if (i_rst) stalled_q <= 1'b0;
    else stalled_q <= i_tx_domain_ready && stalled;
    if (stalled) payload_q <= payload;

    // The accepting edge is subject to the same checks as every stalled edge.
    if (past_valid && stalled_q && !i_rst && i_tx_domain_ready) begin
      hold_valid : assert (fifo_valid);
      hold_payload : assert (payload == payload_q);
    end
  end

`ifndef NIC_TX_HOLD_COVER
  // The safety proof leaves every engine input free after the initial reset.
  (* anyseq *) logic f_wide_mode, f_restart, f_req_ready, f_resp_valid, f_resp_error;
  (* anyseq *)logic [ 31:0] f_base;
  (* anyseq *)logic [  4:0] f_size_log2;
  (* anyseq *)logic [ 15:0] f_ring_tail;
  (* anyseq *)logic [  1:0] f_resp_kind;
  (* anyseq *)logic [  3:0] f_resp_tag;
  (* anyseq *)logic [255:0] f_resp_data;
  assign {wide_mode, restart, req_ready, resp_valid, resp_error} = {
    f_wide_mode, f_restart, f_req_ready, f_resp_valid, f_resp_error
  };
  assign {base, size_log2, ring_tail, resp_kind, resp_tag, resp_data} = {
    f_base, f_size_log2, f_ring_tail, f_resp_kind, f_resp_tag, f_resp_data
  };

  logic segment_stalled;
  logic [82:0] segment_payload;
  assign segment_stalled = dut.seg_out_valid && !dut.u_segment.i_out_ready;
  assign segment_payload = {dut.seg_out_data, dut.seg_out_code, dut.seg_out_csum};
  always_ff @(posedge i_clk) begin
    if (past_valid) begin
      // A push cannot overwrite a held head of either two-entry segment queue.
      segment_input_queue :
      assert (
          (dut.u_segment.ib_cnt_q <= 2'd2) &&
          (dut.u_segment.ib_cnt_q[0] == (dut.u_segment.ib_rd_q ^ dut.u_segment.ib_wr_q)));
      segment_emission_queue :
      assert (
          (dut.u_segment.sk_cnt_q <= 2'd2) &&
          (dut.u_segment.sk_cnt_q[0] == (dut.u_segment.sk_rd_q ^ dut.u_segment.sk_wr_q)));

      // A flush at the current edge clears the segment stage after sampling.
      if (!i_rst && $past(segment_stalled && !i_rst && !dut.u_segment.i_flush)) begin
        segment_hold : assert (dut.seg_out_valid && (segment_payload == $past(segment_payload)));
      end
    end
  end
`else
  // The ring posts an open frame, then optionally posts a rejected continuation.
  // The first data descriptor supplies eight beats for a 54-byte header and a 7-byte MSS.
  localparam logic [31:0] RingBase = 32'h8010_0000;
  localparam logic [31:0] FrameBase = 32'h8020_0000;
  localparam logic [31:0] First = 32'd1 << nic_pkg::TxWord1BitFirst;
  localparam logic [31:0] Last = 32'd1 << nic_pkg::TxWord1BitLast;
  localparam logic [31:0] Checksum = {7'd6, 7'd3, 18'd0};
  localparam logic [31:0] Parameters = {2'b00, 4'd5, 7'd17, 1'b1, 18'd0};
  localparam logic [127:0] RejectedDesc = {64'd0, (Last | 32'd8), 32'h1000};
  localparam logic [127:0] PlainDesc = {64'd0, (First | Checksum | 32'd16), FrameBase};
  localparam logic [127:0] ParamDesc = {64'd0, Parameters, 16'd14, 16'd7};
  localparam logic [127:0] SegmentedDesc = {64'd0, (First | 32'd64), FrameBase};

  (* anyseq *) logic start_segmented, post_rejected, dma_ready, dma_reply;
  (* anyseq *) logic [255:0] packet_data;
  logic segmented_q, posted_q, pending_q, first_desc_line_q;
  logic [255:0] first_desc_line;
  assign first_desc_line = segmented_q ? {SegmentedDesc, ParamDesc} : {RejectedDesc, PlainDesc};
  assign wide_mode = 1'b0;
  assign base = RingBase;
  assign size_log2 = 5'd2;
  assign restart = 1'b0;
  assign ring_tail = (segmented_q ? 16'd2 : 16'd1) + 16'(posted_q);
  assign req_ready = !pending_q && dma_ready;
  assign resp_valid = pending_q && dma_reply;
  assign resp_error = 1'b0;
  assign resp_data = (resp_kind != nic_pkg::ReqKindDesc) ? packet_data :
      (first_desc_line_q ? first_desc_line : {128'd0, RejectedDesc});

  // Pick a ring at reset. One pending slot returns the accepted request's kind and tag.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      segmented_q <= start_segmented;
      posted_q    <= 1'b0;
      pending_q   <= 1'b0;
    end else begin
      if (post_rejected) posted_q <= 1'b1;
      if (resp_valid) pending_q <= 1'b0;
      if (req_valid && req_ready) begin
        pending_q         <= 1'b1;
        resp_kind         <= req_kind;
        resp_tag          <= req_tag;
        first_desc_line_q <= req_addr == RingBase;
      end
    end
  end

  logic rejected, frame_open_q, rejected_while_held_q, stopped_while_held_q;
  logic transfer, accept_held, accept_after_reject, core_reset_held;
  assign rejected = dut.admit && dut.in_frame_q && !dut.desc_ok_q && !dut.param_q;
  assign transfer = !i_rst && i_tx_domain_ready && fifo_valid && i_fifo_ready;
  assign accept_held = stalled_q && transfer;
  assign accept_after_reject = accept_held && rejected_while_held_q && !stopped_while_held_q &&
      !i_stop;
  assign core_reset_held = past_valid && i_rst && i_tx_domain_ready && i_stop &&
      stopped_while_held_q && stalled_q && stalled;
  always_ff @(posedge i_clk) begin
    if (i_rst || !i_tx_domain_ready) begin
      frame_open_q          <= 1'b0;
      rejected_while_held_q <= 1'b0;
      stopped_while_held_q  <= 1'b0;
    end else begin
      if (transfer) frame_open_q <= !fifo_code[3];
      rejected_while_held_q <= stalled_q && stalled && (rejected_while_held_q || rejected);
      stopped_while_held_q  <= stalled_q && stalled && (stopped_while_held_q || i_stop);
    end

    if (past_valid) begin
      reject_first :
      cover (accept_after_reject && !segmented_q && !frame_open_q && !fifo_code[3] && !fifo_abort &&
             fifo_csum[0]);
      reject_middle :
      cover (accept_after_reject && !segmented_q && frame_open_q && !fifo_code[3] && !fifo_abort &&
             fifo_csum[0]);
      reject_segment_last :
      cover (accept_after_reject && segmented_q && frame_open_q && fifo_code[3] && !fifo_abort &&
             !dut.u_segment.pass_mode);
      stop_held_data : cover (accept_held && stopped_while_held_q && i_stop && !fifo_abort);
      stop_held_abort :
      cover (accept_held && stopped_while_held_q && i_stop && fifo_abort && frame_open_q);
      drain_domain_reset :
      cover (!i_rst && !i_tx_domain_ready && i_stop && !i_fifo_ready &&
                                  stopped_while_held_q && stalled_q && !fifo_valid);
      drain_core_reset :
      cover (!i_rst && i_tx_domain_ready && !fifo_valid && $past(core_reset_held));
    end
  end
`endif
endmodule : nic_tx_hold_formal
