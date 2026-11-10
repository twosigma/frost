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

// Observe validated PAUSE directly on XGMII, independently of packet storage
// and host backpressure. Symbol, preamble, length and CRC acceptance follow
// eth10g_mac_rx, with no storage-credit checks. Only the first 18 frame bytes
// are retained. Publish the interval with its event after a valid /T/ and FCS;
// the bus remains stable until the next event for the TX-domain crossing.
module nic_pause_rx_wire #(
    parameter int unsigned MAX_FRAME_BYTES = 9216
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_enable,
    input logic [63:0] i_xgmii_data,
    input logic [7:0] i_xgmii_ctrl,
    input logic [47:0] i_mac,
    output logic o_pause_ev,
    output logic o_pause_tog,
    output logic [15:0] o_pause_interval
);
  import eth10g_crc_pkg::*;
  localparam int unsigned CountWidth = $clog2(MAX_FRAME_BYTES + 5);
  localparam logic [31:0] CrcResidue = 32'hdebb20e3;

  function automatic logic [31:0] crc32_advance(input logic [31:0] seed, input int unsigned count);
    logic [31:0] value;
    value = seed;
    for (int step = 0; step < 8; step++) begin
      if (step < count) value = crc32_byte(value, 8'h00);
    end
    return value;
  endfunction

  logic decode_valid;
  logic [63:0] decode_data;
  logic [7:0] decode_control, decode_terminate, decode_preamble;
  logic [1:0] decode_start, decode_sfd;
  logic [31:0] decode_crc_check[8];
  logic [31:0] decode_crc_word, decode_crc_upper;
  logic [31:0] lane_crc[8], prefix_crc[9], upper_crc;
  always_comb begin
    for (int lane = 0; lane < 8; lane++) begin
      lane_crc[lane] = crc32_byte(32'h0, i_xgmii_data[lane*8+:8]);
    end
    for (int count = 0; count < 9; count++) begin
      prefix_crc[count] = '0;
      for (int lane = 0; lane < count; lane++) begin
        prefix_crc[count] ^= crc32_advance(lane_crc[lane], count - 1 - lane);
      end
    end
    upper_crc = crc32_advance(32'hffffffff, 4);
    for (int lane = 4; lane < 8; lane++) begin
      upper_crc ^= crc32_advance(lane_crc[lane], 7 - lane);
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) decode_valid <= 1'b0;
    else decode_valid <= i_enable;
    decode_data <= i_xgmii_data;
    decode_control <= i_xgmii_ctrl;
    for (int lane = 0; lane < 8; lane++) begin
      decode_terminate[lane] <= i_xgmii_ctrl[lane] && i_xgmii_data[lane*8+:8] == 8'hfd;
      decode_preamble[lane]  <= !i_xgmii_ctrl[lane] && i_xgmii_data[lane*8+:8] == 8'h55;
      decode_crc_check[lane] <= prefix_crc[lane] ^ CrcResidue;
    end
    decode_start[0] <= i_xgmii_ctrl[0] && i_xgmii_data[7:0] == 8'hfb;
    decode_start[1] <= i_xgmii_ctrl[4] && i_xgmii_data[39:32] == 8'hfb;
    decode_sfd[0] <= !i_xgmii_ctrl[3] && i_xgmii_data[31:24] == 8'hd5;
    decode_sfd[1] <= !i_xgmii_ctrl[7] && i_xgmii_data[63:56] == 8'hd5;
    decode_crc_word <= prefix_crc[8];
    decode_crc_upper <= upper_crc;
  end

  typedef enum logic [1:0] {
    IDLE,
    PREAMBLE,
    FRAME
  } state_t;
  state_t state, next_state;
  logic [CountWidth-1:0] byte_count, next_byte_count;
  logic [31:0] crc, next_crc;
  logic [7:0] frame_overlength, next_frame_overlength;
  logic [7:0] frame_event, frame_first, frame_long_enough, frame_crc_ok;
  logic frame_continue, frame_commit, frame_terminated_early;
  logic lower_preamble, tail_preamble, upper_continue;
  logic start_lower, start_upper, in_frame, in_preamble, commit;
  always_comb begin
    for (int lane = 0; lane < 8; lane++) begin
      frame_event[lane] = decode_control[lane] || frame_overlength[lane];
      frame_long_enough[lane] = int'(byte_count) + lane >= 64;
      frame_crc_ok[lane] = crc32_advance(crc, lane) == decode_crc_check[lane];
    end
    for (int lane = 0; lane < 8; lane++) begin
      frame_first[lane] = frame_event[lane] && (frame_event & ~(8'hff << lane)) == 8'h0;
    end
    frame_continue = frame_event == 0;
    frame_commit = |(frame_first & decode_terminate & frame_long_enough & frame_crc_ok);
    frame_terminated_early = |(frame_first[3:0] & decode_terminate[3:0]);
    lower_preamble = decode_preamble[6:1] == 6'h3f && decode_sfd[1];
    tail_preamble = decode_preamble[7:5] == 3'b111;
    upper_continue = decode_preamble[2:0] == 3'b111 && decode_sfd[0] && decode_control[7:4] == 4'b0;

    start_lower = decode_valid && decode_start[0];
    in_frame = decode_valid && !decode_start[0] && state == FRAME;
    in_preamble = decode_valid && !decode_start[0] && state == PREAMBLE;
    start_upper = decode_valid && decode_start[1] && !(in_frame && frame_terminated_early);
    commit = in_frame && frame_commit;

    next_state = state;
    if (start_upper) next_state = tail_preamble ? PREAMBLE : IDLE;
    else if (start_lower) next_state = lower_preamble ? FRAME : IDLE;
    else if (in_frame) next_state = frame_continue ? FRAME : IDLE;
    else if (in_preamble) next_state = upper_continue ? FRAME : IDLE;

    next_byte_count = byte_count;
    next_crc = crc;
    next_frame_overlength = frame_overlength;
    if (in_frame && frame_continue) begin
      next_byte_count = byte_count + CountWidth'(8);
      next_crc = crc32_advance(crc, 8) ^ decode_crc_word;
      for (int lane = 0; lane < 8; lane++) begin
        next_frame_overlength[lane] = int'(byte_count) >= int'(MAX_FRAME_BYTES) - 4 - lane;
      end
    end else if (in_preamble && upper_continue) begin
      next_byte_count = CountWidth'(4);
      next_crc = decode_crc_upper;
      next_frame_overlength = '0;
    end else if (decode_valid) begin
      next_byte_count = '0;
      next_crc = 32'hffffffff;
      next_frame_overlength = '0;
    end
  end

  // Data flops need no reset: a validated frame necessarily overwrites all
  // 18 header bytes before its /T/ can publish an event.
  logic [143:0] header_q;
  always_ff @(posedge i_clk) begin
    if (in_preamble && upper_continue) header_q[31:0] <= decode_data[63:32];
    for (int b = 0; b < 18; b++) begin
      for (int lane = 0; lane < 8; lane++) begin
        if (in_frame && byte_count + CountWidth'(lane) == CountWidth'(b) && !decode_control[lane])
          header_q[b*8+:8] <= decode_data[lane*8+:8];
      end
    end
  end
  logic is_pause;
  assign is_pause = ((header_q[47:0] == 48'h0100_00C2_8001) ||
      (header_q[47:0] == i_mac)) && header_q[127:96] == 32'h0100_0888;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state <= IDLE;
      byte_count <= '0;
      crc <= 32'hffffffff;
      frame_overlength <= '0;
      o_pause_ev <= 1'b0;
      o_pause_tog <= 1'b0;
      o_pause_interval <= '0;
    end else begin
      state <= next_state;
      byte_count <= next_byte_count;
      crc <= next_crc;
      frame_overlength <= next_frame_overlength;
      o_pause_ev <= 1'b0;
      if (commit && is_pause) begin
        o_pause_ev <= 1'b1;
        o_pause_tog <= !o_pause_tog;
        o_pause_interval <= {header_q[135:128], header_q[143:136]};
      end
    end
  end
endmodule
