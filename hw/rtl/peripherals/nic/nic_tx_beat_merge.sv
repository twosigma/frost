// Copyright (c) 2026 John Goodacre.

/*
 * nic_tx_beat_merge: joins a frame's descriptor segments into FIFO beats.
 *
 * A frame is one or more descriptors (FIRST on the initial, LAST on the final).
 * nic_byte_unpack packs each segment on its own: every beat carries 8 bytes
 * except a segment's last, which carries 1..8. A segment's last beat can
 * leave 1..7 bytes that the next segment must complete, so this stage holds
 * them and prepends them to the next segment's beats. The FIFO sees only full
 * 8-byte beats inside a frame, and its last flag only on the LAST segment's
 * final beat. Frame end with more than 8 bytes pending takes two beats.
 *
 * i_seg_last marks the segment's final beat from the packer; i_frame_end is
 * the descriptor's LAST flag. i_flush drops held bytes (reset, stop or abort).
 */
module nic_tx_beat_merge (
    input logic i_clk,
    input logic i_rst,

    input logic i_flush,

    // Beats from nic_byte_unpack.
    input  logic        i_in_valid,
    output logic        o_in_ready,
    input  logic [63:0] i_in_data,
    input  logic [ 3:0] i_in_bytes,
    input  logic        i_seg_last,
    input  logic        i_frame_end,

    // Beats into the TX FIFO.
    output logic        o_out_valid,
    input  logic        i_out_ready,
    output logic [63:0] o_out_data,
    output logic [ 3:0] o_out_code,

    // A frame-final tail still waits for the FIFO (nothing else is held between frames).
    output logic o_busy
);
  logic [2:0] held_n_q;  // bytes held from earlier segments, 0..7
  logic [63:0] held_q;  // the held bytes, lowest address in lane 0
  logic tail_q;  // a frame-final tail of 1..7 bytes is waiting for the FIFO
  logic [2:0] tail_n_q;
  logic [63:0] tail_q_data;

  // The held bytes, then this beat's bytes: up to 15 valid bytes.
  // Only the valid bytes count: the bytes above a beat's count are not zero.
  function automatic logic [63:0] low_bytes(input logic [3:0] n);
    low_bytes = (n >= 4'd8) ? '1 : ((64'd1 << {n, 3'b000}) - 64'd1);
  endfunction

  logic [127:0] comb;
  logic [3:0] total;
  logic end_of_frame;
  logic need_out;
  assign comb = {64'b0, held_q & low_bytes(
      4'(held_n_q)
  )} | ({64'b0, i_in_data & low_bytes(
      i_in_bytes
  )} << {held_n_q, 3'b000});
  assign total = 4'(held_n_q) + i_in_bytes;
  assign end_of_frame = i_seg_last && i_frame_end;
  assign need_out = end_of_frame || (total >= 4'd8);

  // A tail takes the FIFO before any new input is accepted.
  assign o_out_valid = tail_q || (i_in_valid && need_out);
  assign o_out_data = tail_q ? tail_q_data : comb[63:0];
  always_comb begin
    if (tail_q) o_out_code = nic_pkg::beat_code(1'b1, 4'(tail_n_q));
    else if (end_of_frame && total <= 4'd8) o_out_code = nic_pkg::beat_code(1'b1, total);
    else o_out_code = nic_pkg::beat_code(1'b0, 4'd8);
  end
  assign o_in_ready = !tail_q && (!need_out || i_out_ready);
  assign o_busy = tail_q;

  logic in_fire, out_fire;
  assign in_fire  = i_in_valid && o_in_ready;
  assign out_fire = o_out_valid && i_out_ready;

  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush) begin
      held_n_q <= '0;
      held_q   <= '0;
      tail_q   <= 1'b0;
      tail_n_q <= '0;
    end else begin
      if (out_fire && tail_q) tail_q <= 1'b0;
      if (in_fire) begin
        if (end_of_frame) begin
          if (total > 4'd8) begin
            tail_q      <= 1'b1;
            tail_n_q    <= 3'(total - 4'd8);
            tail_q_data <= comb[127:64];
          end
          held_n_q <= '0;
        end else if (total >= 4'd8) begin
          held_n_q <= 3'(total - 4'd8);
          held_q   <= comb[127:64];
        end else begin
          held_n_q <= 3'(total);
          held_q   <= comb[63:0];
        end
      end
    end
  end
endmodule : nic_tx_beat_merge
