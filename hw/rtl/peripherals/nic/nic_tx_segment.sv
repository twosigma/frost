// Copyright (c) 2026 John Goodacre.

/*
 * nic_tx_segment: packet stream segmentation on the transmit frame stream.
 *
 * A frame the TX engine marks for segmentation (a parameter descriptor ahead of it carried the
 * max segment size, the payload length and the header geometry) arrives as one stream of beats:
 * the Ethernet, IP and transport headers, then up to 64 KB of payload. This stage cuts it
 * into frames of at most segment payload bytes, each with its own copy of the headers.
 * Any other frame passes through untouched, beat for beat.
 *
 * Per segment the headers change as software segmentation changes them:
 *   IPv4: total length, identification (+1 a segment), header checksum.
 *   IPv6: payload length.
 *   TCP:  sequence number (+ payload sent so far), FIN and PSH only on the last
 *         segment, CWR only on the first, and the checksum field set to the
 *         pseudo-header sum plus this segment's TCP length, ready for the MAC's
 *         checksum insertion (o_out_csum names the TCP checksum for every segment).
 * The stack hands over the pseudo-header sum without the length, as it does for every
 * segmentation-capable device.
 *
 * Structure, every step a short registered stage:
 *   capture   the header beats are stored in a byte array; the IPv4 header sum without
 *             its length, identification and checksum words accumulates as they pass.
 *   init      the identification, sequence number, flags and TCP checksum are read back.
 *   prepare   per segment: the payload length (the lesser of MSS and what is left), the
 *             header fields in a short pipeline, then thirteen byte writes into the stored
 *             header. The next segment's preparation runs while this segment's payload
 *             streams, so it costs no cycles except for a very small MSS.
 *   emit      the stored header goes into nic_tx_beat_merge as one segment; the payload
 *             follows from a 16-byte accumulator that realigns the input to the segment.
 * nic_tx_beat_merge packs the two into 8-byte beats and ends each segment's frame.
 *
 * A frame the stage cannot segment (no or oversize header, MSS 0, a short header) is
 * dropped; one whose payload differs from the declared length is padded with zeros or
 * has its excess discarded. o_err pulses once for each.
 */
module nic_tx_segment (
    input logic i_clk,
    input logic i_rst,
    input logic i_flush,

    // The frame whose first beat is next (held by nic_tx_engine until that beat is taken).
    input logic        i_cfg_segment,
    input logic [13:0] i_cfg_mss,
    input logic [15:0] i_cfg_payload,
    input logic [ 6:0] i_cfg_l4_off2,
    input logic [ 3:0] i_cfg_tcphl4,
    input logic        i_cfg_ip6,
    input logic        i_cfg_vlan,
    input logic [14:0] i_cfg_csum,     // the request of a frame that is not segmented

    // Frame beats in: 64 data bits and {last, bytes - 1}.
    input  logic        i_in_valid,
    output logic        o_in_ready,
    input  logic [63:0] i_in_data,
    input  logic [ 3:0] i_in_code,

    // Beats out, with the checksum request of the frame they belong to.
    output logic        o_out_valid,
    input  logic        i_out_ready,
    output logic [63:0] o_out_data,
    output logic [ 3:0] o_out_code,
    output logic [14:0] o_out_csum,

    output logic o_err,
    // Includes buffered input and output, so a later frame cannot cancel an earlier one.
    output logic o_busy
);
  localparam int unsigned HbBytes = 160;
  localparam int unsigned HbBeats = HbBytes / 8;
  localparam int unsigned PpWrites = 13;
  localparam logic [4:0] PpIdle = 5'd31;
  localparam logic [4:0] PpLast = 5'(5 + PpWrites - 1);

  typedef enum logic [2:0] {
    S_IDLE,
    S_PASS,
    S_DROP,
    S_CAP,
    S_INIT,
    S_RUN
  } state_e;
  state_e state_q;

  typedef enum logic [1:0] {
    EM_WAIT,
    EM_HDR,
    EM_PAY,
    EM_END
  } emit_e;
  emit_e em_q;

  // ---- the input FIFO ---------------------------------------------------------------
  // Beats and their frame's configuration wait in a two-entry FIFO whose ready is a function of
  // its fill alone, so the stage never sits on the path from the engine's unpacker, and a change
  // of the engine's configuration for the next frame cannot reach a beat already queued.
  logic [126:0] ib_q[2];
  logic ib_rd_q, ib_wr_q;
  logic [1:0] ib_cnt_q;
  logic ib_push, ib_pop, h_valid, h_ready;
  logic [126:0] h_entry;
  assign o_in_ready = (ib_cnt_q != 2'd2);
  assign ib_push = i_in_valid && o_in_ready;
  assign h_valid = (ib_cnt_q != 2'd0);
  assign h_entry = ib_q[ib_rd_q];
  assign ib_pop = h_valid && h_ready;
  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush) begin
      ib_cnt_q <= '0;
      ib_rd_q  <= 1'b0;
      ib_wr_q  <= 1'b0;
    end else begin
      ib_cnt_q <= ib_cnt_q + 2'(ib_push) - 2'(ib_pop);
      if (ib_push) ib_wr_q <= ~ib_wr_q;
      if (ib_pop) ib_rd_q <= ~ib_rd_q;
    end
    if (ib_push)
      ib_q[ib_wr_q] <= {
        i_cfg_csum,
        i_cfg_vlan,
        i_cfg_ip6,
        i_cfg_tcphl4,
        i_cfg_l4_off2,
        i_cfg_payload,
        i_cfg_mss,
        i_cfg_segment,
        i_in_code,
        i_in_data
      };
  end
  logic [63:0] h_data;
  logic [ 3:0] h_code;
  logic h_cfg_segment, h_cfg_ip6, h_cfg_vlan;
  logic [13:0] h_cfg_mss;
  logic [15:0] h_cfg_payload;
  logic [ 6:0] h_cfg_l4_off2;
  logic [ 3:0] h_cfg_tcphl4;
  logic [14:0] h_cfg_csum;
  assign {h_cfg_csum, h_cfg_vlan, h_cfg_ip6, h_cfg_tcphl4, h_cfg_l4_off2, h_cfg_payload,
          h_cfg_mss, h_cfg_segment, h_code, h_data} = h_entry;

  // ---- the frame's configuration (latched when it starts) ------------------------
  logic [13:0] mss_q;
  logic [ 7:0] l4off_q;
  logic [ 5:0] tcphl_q;
  logic        ip6_q;
  logic [ 7:0] l3_q;  // 14, or 18 behind a VLAN tag
  logic [ 8:0] hdr_len_q;  // l4 offset + TCP header
  logic [ 4:0] hb_last_q;  // index of the last header beat
  logic [ 3:0] hl_tail_q;  // header bytes in the last header beat, 1 to 8

  logic [ 8:0] hdr_len_c;
  logic        cfg_bad;
  assign hdr_len_c = 9'(h_cfg_l4_off2) * 9'd2 + 9'(h_cfg_tcphl4) * 9'd4;
  assign cfg_bad = (h_cfg_mss == 14'd0) || (h_cfg_payload == 16'd0) ||
      (hdr_len_c > 9'(HbBytes)) || ({h_cfg_tcphl4, 2'b00} < 6'd20) ||
      ({h_cfg_l4_off2, 1'b0} < (h_cfg_vlan ? 8'd18 : 8'd14) + (h_cfg_ip6 ? 8'd40 : 8'd20));

  // ---- the merge stage -----------------------------------------------------------
  logic        mg_valid;
  logic        mg_ready;
  logic        mg_seg_last;
  logic        mg_frame_end;
  logic [63:0] mg_data;
  logic [ 3:0] mg_bytes;
  logic        mg_out_valid;
  logic [63:0] mg_out_data;
  logic [ 3:0] mg_out_code;
  logic        mg_busy;
  nic_tx_beat_merge u_merge (
      .i_clk      (i_clk),
      .i_rst      (i_rst),
      .i_flush    (i_flush),
      .i_in_valid (mg_valid),
      .o_in_ready (mg_ready),
      .i_in_data  (mg_data),
      .i_in_bytes (mg_bytes),
      .i_seg_last (mg_seg_last),
      .i_frame_end(mg_frame_end),
      .o_out_valid(mg_out_valid),
      .i_out_ready(i_out_ready),
      .o_out_data (mg_out_data),
      .o_out_code (mg_out_code),
      .o_busy     (mg_busy)
  );

  // ---- bypass ---------------------------------------------------------------------
  // An unsegmented frame goes straight through, but only once the merge stage has
  // delivered the tail of the frame before it.
  logic pass_mode;
  logic sk_empty, sk_ready;
  assign pass_mode = (state_q == S_PASS) ||
      ((state_q == S_IDLE) && !h_cfg_segment && !mg_busy && sk_empty);
  assign o_out_valid = pass_mode ? h_valid : mg_out_valid;
  assign o_out_data = pass_mode ? h_data : mg_out_data;
  assign o_out_code = pass_mode ? h_code : mg_out_code;
  assign o_out_csum = pass_mode ? h_cfg_csum : {7'd8, l4off_q[7:1], 1'b1};

  // ---- the header store ----------------------------------------------------------
  logic [7:0] hb_q[HbBytes];
  logic [4:0] cap_idx_q;
  logic [4:0] hb_rd_q;  // header beat being emitted
  logic [63:0] hdr_beat_q;  // that beat, registered

  function automatic logic [63:0] hb_beat(input logic [4:0] idx);
    logic [63:0] v;
    v = '0;
    for (int b = 0; b < HbBeats; b++)
    if (idx == 5'(b)) for (int j = 0; j < 8; j++) v[8*j+:8] = hb_q[8*b+j];
    return v;
  endfunction

  function automatic logic [7:0] hb_byte(input logic [7:0] off);
    logic [7:0] v;
    v = '0;
    for (int b = 0; b < HbBytes; b++) if (off == 8'(b)) v = hb_q[b];
    return v;
  endfunction

  // ---- the payload accumulator ---------------------------------------------------
  logic [127:0] acc_q;
  logic [  4:0] acc_cnt_q;
  logic         in_done_q;  // the input's last beat has been taken
  logic         excess_q;  // input arrived after the declared payload was segmented

  // ---- segment bookkeeping ----------------------------------------------------------
  logic [ 15:0] rem_q;  // payload not yet assigned to a segment
  logic [ 15:0] sent_q;  // payload bytes of the segments prepared so far
  logic [ 15:0] kk_q;  // index of the segment being prepared
  logic [13:0] prep_plen_q, cur_plen_q, seg_rem_q;
  logic prep_first_q, prep_last_q, cur_last_q, prep_valid_q;
  logic err_pending_q;

  // The originals, read back from the stored header.
  logic [15:0] id0_q, seed0_q;
  logic [31:0] seq0_q;
  logic [ 7:0] flags0_q;
  logic [20:0] s0_q;  // IPv4 header sum without total length, identification, checksum
  logic [ 3:0] init_step_q;
  logic [ 7:0] rd_off_q;

  // The preparation pipeline.
  logic [ 4:0] pp_step_q;  // 0 to 5 compute, 5 to 17 write, PpIdle idle
  logic [15:0] tot_len_q, id_q, ip_f2_q, ipck_q, tck_q;
  logic [21:0] ip_sum_q;
  logic [16:0] ip_f1_q, tck_sum_q, tck_f1_q;
  logic [31:0] seq_q;
  logic [ 7:0] flags_q;
  logic        pp_active;
  assign pp_active = pp_step_q != PpIdle;

  // ---- input -----------------------------------------------------------------------
  logic [ 3:0] in_bytes;
  logic        in_last;
  logic [63:0] in_masked;
  assign in_bytes = 4'(h_code[2:0]) + 4'd1;
  assign in_last  = h_code[3];
  always_comb begin
    in_masked = '0;
    for (int j = 0; j < 8; j++) if (4'(j) < in_bytes) in_masked[8*j+:8] = h_data[8*j+:8];
  end

  logic in_fire, run_fire;
  always_comb begin
    case (state_q)
      S_IDLE:  h_ready = h_cfg_segment ? 1'b0 : (i_out_ready && !mg_busy && sk_empty);
      S_PASS:  h_ready = i_out_ready;
      S_DROP:  h_ready = 1'b1;
      S_CAP:   h_ready = 1'b1;
      S_RUN:   h_ready = !in_done_q && ((em_q == EM_END) || (acc_cnt_q <= 5'd8));
      default: h_ready = 1'b0;
    endcase
  end
  assign in_fire = h_valid && h_ready;
  // Qualify payload capture within RUN so bypass backpressure does not enter its controls.
  assign run_fire = h_valid && (state_q == S_RUN) && !in_done_q &&
      ((em_q == EM_END) || (acc_cnt_q <= 5'd8));

  // ---- header emission ---------------------------------------------------------------
  logic hdr_valid, hdr_fire, hdr_final;
  assign hdr_valid = (state_q == S_RUN) && (em_q == EM_HDR);
  assign hdr_final = (hb_rd_q == hb_last_q);
  assign hdr_fire  = hdr_valid && sk_ready;

  // ---- payload emission --------------------------------------------------------------
  logic       pay_valid;
  logic       pay_fire;
  logic       pay_shortage;
  logic       pay_end;
  logic [3:0] pay_n;
  logic [3:0] seg_n;  // min(8, segment bytes left)
  logic [3:0] avail_n;  // min(8, bytes in the accumulator), or 8 of zeros on a shortage
  assign seg_n = (seg_rem_q[13:3] != '0) ? 4'd8 : {1'b0, seg_rem_q[2:0]};
  assign pay_shortage = in_done_q && (acc_cnt_q == 5'd0) && (seg_rem_q != '0);
  assign avail_n = pay_shortage ? 4'd8 : ((acc_cnt_q >= 5'd8) ? 4'd8 : acc_cnt_q[3:0]);
  assign pay_n = (seg_n < avail_n) ? seg_n : avail_n;
  assign pay_valid = (state_q == S_RUN) && (em_q == EM_PAY) && (pay_n != 4'd0);
  assign pay_fire = pay_valid && sk_ready;
  assign pay_end = (seg_rem_q == 14'(pay_n));

  // ---- the emission buffer ---------------------------------------------------------
  // The beats for the merge stage wait in a two-entry FIFO. Its ready is a function of its fill
  // alone, so the sequencer above never waits on the merge stage's combinational ready (and the
  // merge stage sees every input straight from a register). Two entries keep one beat a cycle.
  logic [63:0] sk_data_q [2];
  logic [ 3:0] sk_bytes_q[2];
  logic sk_seg_last_q[2], sk_frame_end_q[2];
  logic sk_rd_q, sk_wr_q;
  logic [1:0] sk_cnt_q;
  logic sk_push, sk_pop;
  assign sk_empty = (sk_cnt_q == 2'd0);
  assign o_busy   = (state_q != S_IDLE) || h_valid || !sk_empty || mg_busy;
  assign sk_ready = (sk_cnt_q != 2'd2);
  assign sk_push  = (hdr_valid || pay_valid) && sk_ready;
  assign sk_pop   = !sk_empty && mg_ready;
  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush) begin
      sk_cnt_q <= '0;
      sk_rd_q  <= 1'b0;
      sk_wr_q  <= 1'b0;
    end else begin
      sk_cnt_q <= sk_cnt_q + 2'(sk_push) - 2'(sk_pop);
      if (sk_push) sk_wr_q <= ~sk_wr_q;
      if (sk_pop) sk_rd_q <= ~sk_rd_q;
    end
    if (sk_push) begin
      sk_data_q[sk_wr_q] <= hdr_valid ? hdr_beat_q : (pay_shortage ? 64'd0 : acc_q[63:0]);
      sk_bytes_q[sk_wr_q] <= hdr_valid ? (hdr_final ? hl_tail_q : 4'd8) : pay_n;
      sk_seg_last_q[sk_wr_q] <= hdr_valid ? hdr_final : pay_end;
      sk_frame_end_q[sk_wr_q] <= pay_valid && !hdr_valid && pay_end;
    end
  end
  assign mg_valid = !sk_empty;
  assign mg_data = sk_data_q[sk_rd_q];
  assign mg_bytes = sk_bytes_q[sk_rd_q];
  assign mg_seg_last = sk_seg_last_q[sk_rd_q];
  assign mg_frame_end = sk_frame_end_q[sk_rd_q];

  // ---- the IPv4 header sum while capturing ----------------------------------------
  // The words that count are registered as they pass and added a cycle later, so the beat's
  // path from the unpacker never meets the adders. The sum is not needed for ten more cycles.
  logic [15:0] cap_w_q   [4];
  logic        cap_vld_q;
  logic [17:0] cap_sum;
  always_comb begin
    cap_sum = '0;
    for (int w = 0; w < 4; w++) cap_sum = cap_sum + 18'(cap_w_q[w]);
  end

  // The beat's 16-bit words inside the IPv4 header, without total length, id and checksum.
  logic [3:0] cap_keep;
  always_comb begin
    for (int w = 0; w < 4; w++) begin
      logic [8:0] o;
      o = 9'(cap_idx_q) * 9'd8 + 9'(2 * w);
      cap_keep[w] = !ip6_q && (o >= 9'(l3_q)) && (o < 9'(l4off_q)) &&
          (o != 9'(l3_q) + 9'd2) && (o != 9'(l3_q) + 9'd4) && (o != 9'(l3_q) + 9'd10);
    end
  end

  // ---- header patch values -----------------------------------------------------------
  logic [8:0] iplen_base;  // IPv4: header bytes from the IP header on; IPv6: behind the base header
  assign iplen_base = ip6_q ? (hdr_len_q - 9'(l3_q) - 9'd40) : (hdr_len_q - 9'(l3_q));

  logic [7:0] flag_mask;
  assign flag_mask = 8'hFF & (prep_last_q ? 8'hFF : 8'hF6) & (prep_first_q ? 8'hFF : 8'h7F);

  // The jth byte written into the stored header: offset, value, enable.
  logic [4:0] pw_j;
  logic [7:0] pw_off, pw_val;
  logic pw_en;
  assign pw_j = pp_step_q - 5'd5;
  always_comb begin
    pw_en  = 1'b0;
    pw_off = '0;
    pw_val = '0;
    case (pw_j)
      5'd0: begin
        pw_en  = 1'b1;
        pw_off = l3_q + (ip6_q ? 8'd4 : 8'd2);
        pw_val = tot_len_q[15:8];
      end
      5'd1: begin
        pw_en  = 1'b1;
        pw_off = l3_q + (ip6_q ? 8'd5 : 8'd3);
        pw_val = tot_len_q[7:0];
      end
      5'd2: begin
        pw_en  = !ip6_q;
        pw_off = l3_q + 8'd4;
        pw_val = id_q[15:8];
      end
      5'd3: begin
        pw_en  = !ip6_q;
        pw_off = l3_q + 8'd5;
        pw_val = id_q[7:0];
      end
      5'd4: begin
        pw_en  = !ip6_q;
        pw_off = l3_q + 8'd10;
        pw_val = ipck_q[15:8];
      end
      5'd5: begin
        pw_en  = !ip6_q;
        pw_off = l3_q + 8'd11;
        pw_val = ipck_q[7:0];
      end
      5'd6: begin
        pw_en  = 1'b1;
        pw_off = l4off_q + 8'd4;
        pw_val = seq_q[31:24];
      end
      5'd7: begin
        pw_en  = 1'b1;
        pw_off = l4off_q + 8'd5;
        pw_val = seq_q[23:16];
      end
      5'd8: begin
        pw_en  = 1'b1;
        pw_off = l4off_q + 8'd6;
        pw_val = seq_q[15:8];
      end
      5'd9: begin
        pw_en  = 1'b1;
        pw_off = l4off_q + 8'd7;
        pw_val = seq_q[7:0];
      end
      5'd10: begin
        pw_en  = 1'b1;
        pw_off = l4off_q + 8'd13;
        pw_val = flags_q;
      end
      5'd11: begin
        pw_en  = 1'b1;
        pw_off = l4off_q + 8'd16;
        pw_val = tck_q[15:8];
      end
      5'd12: begin
        pw_en  = 1'b1;
        pw_off = l4off_q + 8'd17;
        pw_val = tck_q[7:0];
      end
      default: ;
    endcase
  end
  logic pw_now;
  assign pw_now = (pp_step_q >= 5'd5) && (pp_step_q <= PpLast) && pw_en;

  // ---- the read-back of the originals -------------------------------------------
  logic [7:0] rd_byte;
  assign rd_byte = hb_byte(rd_off_q);
  function automatic logic [7:0] init_off(input logic [3:0] step, input logic [7:0] l3,
                                          input logic [7:0] l4);
    case (step)
      4'd0: init_off = l3 + 8'd4;
      4'd1: init_off = l3 + 8'd5;
      4'd2: init_off = l4 + 8'd4;
      4'd3: init_off = l4 + 8'd5;
      4'd4: init_off = l4 + 8'd6;
      4'd5: init_off = l4 + 8'd7;
      4'd6: init_off = l4 + 8'd13;
      4'd7: init_off = l4 + 8'd16;
      default: init_off = l4 + 8'd17;
    endcase
  endfunction

  // ---- next accumulator state ---------------------------------------------------
  logic [  3:0] n_out;
  logic [  4:0] cnt_after;
  logic [127:0] acc_shift;
  logic [127:0] acc_next;
  logic [  4:0] cnt_next;
  logic         append;
  assign n_out = pay_fire ? pay_n : 4'd0;
  assign cnt_after = pay_shortage ? 5'd0 : (acc_cnt_q - 5'(n_out));
  assign acc_shift = pay_shortage ? 128'd0 : (acc_q >> {n_out, 3'b000});
  assign append = run_fire && (em_q != EM_END);
  always_comb begin
    acc_next = acc_shift;
    cnt_next = cnt_after;
    if (append) begin
      acc_next = acc_shift | (128'(in_masked) << {cnt_after, 3'b000});
      cnt_next = cnt_after + 5'(in_bytes);
    end
  end

  // ---- the state machine ------------------------------------------------------------
  logic cap_final;  // this beat is the last header beat
  logic [3:0] hl_in_last;
  logic cap_short;  // the frame ends before its headers do
  logic end_now;
  assign cap_final = (cap_idx_q == hb_last_q);
  assign hl_in_last = (hdr_len_q[2:0] == 3'd0) ? 4'd8 : {1'b0, hdr_len_q[2:0]};
  assign cap_short = in_fire && (state_q == S_CAP) &&
      ((in_last && !cap_final) || (in_last && cap_final && (in_bytes < hl_in_last)));
  assign end_now = (state_q == S_RUN) && (em_q == EM_END) && (in_done_q || (run_fire && in_last));

  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush) begin
      state_q       <= S_IDLE;
      em_q          <= EM_WAIT;
      acc_cnt_q     <= '0;
      in_done_q     <= 1'b0;
      excess_q      <= 1'b0;
      pp_step_q     <= PpIdle;
      prep_valid_q  <= 1'b0;
      err_pending_q <= 1'b0;
      o_err         <= 1'b0;
      cap_idx_q     <= '0;
      cap_vld_q     <= 1'b0;
    end else begin
      o_err <= 1'b0;
      cap_vld_q <= (state_q == S_CAP) && in_fire;
      case (state_q)
        S_IDLE: begin
          if (h_valid && !h_cfg_segment) begin
            if (in_fire && !in_last) state_q <= S_PASS;
          end else if (h_valid && h_cfg_segment && sk_empty && !mg_busy) begin
            // The previous frame's last beats have left, so its checksum request is not replaced.
            mss_q         <= h_cfg_mss;
            l4off_q       <= {h_cfg_l4_off2, 1'b0};
            tcphl_q       <= {h_cfg_tcphl4, 2'b00};
            ip6_q         <= h_cfg_ip6;
            l3_q          <= h_cfg_vlan ? 8'd18 : 8'd14;
            hdr_len_q     <= hdr_len_c;
            hb_last_q     <= 5'((hdr_len_c + 9'd7) >> 3) - 5'd1;
            hl_tail_q     <= (hdr_len_c[2:0] == 3'd0) ? 4'd8 : {1'b0, hdr_len_c[2:0]};
            cap_idx_q     <= '0;
            s0_q          <= '0;
            acc_cnt_q     <= '0;
            acc_q         <= '0;
            in_done_q     <= 1'b0;
            excess_q      <= 1'b0;
            rem_q         <= h_cfg_payload;
            sent_q        <= '0;
            kk_q          <= '0;
            prep_valid_q  <= 1'b0;
            err_pending_q <= 1'b0;
            em_q          <= EM_WAIT;
            pp_step_q     <= PpIdle;
            if (cfg_bad) begin
              o_err   <= 1'b1;
              state_q <= S_DROP;
            end else begin
              state_q <= S_CAP;
            end
          end
        end

        S_PASS: begin
          if (in_fire && in_last) state_q <= S_IDLE;
        end

        S_DROP: begin
          if (in_fire && in_last) state_q <= S_IDLE;
        end

        S_CAP: begin
          if (cap_vld_q) s0_q <= s0_q + 21'(cap_sum);
          if (in_fire) begin
            for (int j = 0; j < 8; j++)
            for (int b = 0; b < HbBeats; b++) if (cap_idx_q == 5'(b)) hb_q[8*b+j] <= h_data[8*j+:8];
            for (int w = 0; w < 4; w++)
            cap_w_q[w] <= cap_keep[w] ? {h_data[16*w+:8], h_data[16*w+8+:8]} : 16'd0;
            cap_idx_q <= cap_idx_q + 5'd1;
            if (cap_short) begin
              o_err   <= 1'b1;
              state_q <= in_last ? S_IDLE : S_DROP;
            end else if (cap_final) begin
              // Payload bytes behind the header in this beat start the accumulator.
              acc_q       <= 128'(in_masked >> {hl_in_last, 3'b000});
              acc_cnt_q   <= 5'(in_bytes) - 5'(hl_in_last);
              in_done_q   <= in_last;
              init_step_q <= '0;
              state_q     <= S_INIT;
            end
          end
        end

        S_INIT: begin
          if (cap_vld_q) s0_q <= s0_q + 21'(cap_sum);
          rd_off_q    <= init_off(init_step_q, l3_q, l4off_q);
          init_step_q <= init_step_q + 4'd1;
          case (init_step_q)
            4'd1:    id0_q[15:8] <= rd_byte;
            4'd2:    id0_q[7:0] <= rd_byte;
            4'd3:    seq0_q[31:24] <= rd_byte;
            4'd4:    seq0_q[23:16] <= rd_byte;
            4'd5:    seq0_q[15:8] <= rd_byte;
            4'd6:    seq0_q[7:0] <= rd_byte;
            4'd7:    flags0_q <= rd_byte;
            4'd8:    seed0_q[15:8] <= rd_byte;
            4'd9: begin
              seed0_q[7:0] <= rd_byte;
              pp_step_q    <= 5'd0;
              em_q         <= EM_WAIT;
              state_q      <= S_RUN;
            end
            default: ;
          endcase
        end

        S_RUN: begin
          // Input beats join the accumulator (in EM_END they are excess).
          acc_q     <= acc_next;
          acc_cnt_q <= cnt_next;
          if (run_fire) in_done_q <= in_last;
          if (run_fire && (em_q == EM_END)) excess_q <= 1'b1;

          // The preparation pipeline.
          if (pp_active) pp_step_q <= pp_step_q + 5'd1;
          case (pp_step_q)
            5'd0: begin
              prep_plen_q  <= (rem_q > {2'b00, mss_q}) ? mss_q : rem_q[13:0];
              prep_last_q  <= (rem_q <= {2'b00, mss_q});
              prep_first_q <= (kk_q == 16'd0);
              rem_q        <= (rem_q > {2'b00, mss_q}) ? (rem_q - {2'b00, mss_q}) : 16'd0;
            end
            5'd1: begin
              tot_len_q <= 16'(iplen_base) + 16'(prep_plen_q);
              id_q      <= id0_q + kk_q;
              seq_q     <= seq0_q + 32'(sent_q);
              tck_sum_q <= 17'(seed0_q) + 17'(tcphl_q) + 17'(prep_plen_q);
              flags_q   <= flags0_q & flag_mask;
            end
            5'd2: begin
              ip_sum_q <= 22'(s0_q) + 22'(tot_len_q) + 22'(id_q);
              tck_f1_q <= 17'(tck_sum_q[15:0]) + 17'(tck_sum_q[16]);
            end
            5'd3: begin
              ip_f1_q <= 17'(ip_sum_q[15:0]) + 17'(ip_sum_q[21:16]);
              tck_q   <= tck_f1_q[15:0] + 16'(tck_f1_q[16]);
            end
            5'd4: ip_f2_q <= ip_f1_q[15:0] + 16'(ip_f1_q[16]);
            5'd5: ipck_q <= ~ip_f2_q;
            default: ;
          endcase
          if (pw_now) begin
            for (int b = 0; b < HbBytes; b++) if (pw_off == 8'(b)) hb_q[b] <= pw_val;
          end
          if (pp_step_q == PpLast) begin
            // The segment is ready; the next one is prepared against the new payload offset.
            pp_step_q    <= PpIdle;
            prep_valid_q <= 1'b1;
            sent_q       <= sent_q + 16'(prep_plen_q);
            kk_q         <= kk_q + 16'd1;
          end

          // Emission.
          case (em_q)
            EM_WAIT: begin
              if (prep_valid_q) begin
                prep_valid_q <= 1'b0;
                cur_plen_q   <= prep_plen_q;
                cur_last_q   <= prep_last_q;
                hb_rd_q      <= '0;
                hdr_beat_q   <= hb_beat(5'd0);
                em_q         <= EM_HDR;
              end
            end
            EM_HDR: begin
              if (hdr_fire) begin
                hb_rd_q    <= hb_rd_q + 5'd1;
                hdr_beat_q <= hb_beat(hb_rd_q + 5'd1);
                if (hdr_final) begin
                  seg_rem_q <= cur_plen_q;
                  em_q      <= EM_PAY;
                  // Prepare the next segment while this one's payload streams.
                  if (!cur_last_q) pp_step_q <= 5'd0;
                end
              end
            end
            EM_PAY: begin
              if (pay_fire && pay_shortage) err_pending_q <= 1'b1;
              if (pay_fire) begin
                seg_rem_q <= seg_rem_q - 14'(pay_n);
                if (pay_end) em_q <= cur_last_q ? EM_END : EM_WAIT;
              end
            end
            EM_END: begin
              if (end_now) begin
                state_q <= S_IDLE;
                if (err_pending_q || excess_q || in_fire || (acc_cnt_q != 5'd0)) o_err <= 1'b1;
              end
            end
            default: em_q <= EM_WAIT;
          endcase
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule : nic_tx_segment
