/*
 *    Copyright 2026 John Goodacre
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
 * nic_pause_rx: the receive half of IEEE 802.3x flow control, in the RX MAC clock domain, between
 * the receive MAC's frame stream and the ingress FIFO.
 *
 * Pause frames. A frame whose destination is 01-80-C2-00-00-01 or the station address is held
 * back for its first beat (the destination is in that beat); its second beat carries the
 * EtherType and opcode. A MAC control PAUSE frame (EtherType 0x8808, opcode 0x0001) is consumed
 * here and never reaches the FIFO: o_pause_ev pulses at its last beat, and o_pause_interval, with a
 * toggle on o_pause_tog, carries its pause_time for the transmit side. Any other frame that
 * matched the destination is released to the FIFO unchanged, held beat first. Frames that do not
 * match pass straight through. The receive MAC publishes complete, CRC-checked frames only, each at
 * least 60 bytes long, so a held frame always has its second and third beats.
 *
 * Pause decision. o_want_pause rises when the FIFO's occupancy reaches i_high_water and falls when it
 * drops to i_low_water (hysteresis), and stays low while i_tx_en is clear. The transmit half turns
 * the level into pause request, refresh and release frames.
 */
module nic_pause_rx #(
    parameter int unsigned OCC_BITS = 14
) (
    input logic i_clk,
    input logic i_rst,

    input logic [47:0] i_mac,

    // The receive MAC's stream, with the beat code {last, bytes - 1}.
    input  logic [63:0] i_m_data,
    input  logic [ 3:0] i_m_code,
    input  logic        i_m_valid,
    output logic        o_m_ready,
    // Toward the ingress FIFO.
    output logic        o_f_valid,
    output logic [67:0] o_f_word,
    input  logic        i_f_ready,

    input logic [OCC_BITS-1:0] i_occupancy,
    input logic [OCC_BITS-1:0] i_high_water,
    input logic [OCC_BITS-1:0] i_low_water,
    input logic                i_tx_en,

    output logic        o_want_pause,
    output logic        o_pause_ev,
    output logic        o_pause_tog,
    output logic [15:0] o_pause_interval
);
  typedef enum logic [1:0] {
    S_PASS,
    S_HOLD,
    S_DROP
  } state_e;
  state_e state_q;
  logic at_start_q;
  logic [67:0] hold_q;
  logic [1:0] idx_q;  // the beat index inside a dropped frame, saturating at 3

  logic da_match, is_pause;
  assign da_match = (i_m_data[47:0] == 48'h0100_00C2_8001) || (i_m_data[47:0] == i_mac);
  // Beat 1: bytes 12-13 the EtherType 0x8808 and bytes 14-15 the opcode 0x0001.
  assign is_pause = (i_m_data[63:32] == 32'h0100_0888);

  always_comb begin
    o_m_ready = i_f_ready;
    o_f_valid = i_m_valid;
    o_f_word  = {i_m_code, i_m_data};
    unique case (state_q)
      S_PASS: begin
        if (at_start_q && da_match) begin
          o_f_valid = 1'b0;
          o_m_ready = 1'b1;
        end
      end
      S_HOLD: begin
        o_f_valid = i_m_valid && !is_pause;
        o_f_word  = hold_q;
        o_m_ready = i_m_valid && is_pause;
      end
      S_DROP: begin
        o_f_valid = 1'b0;
        o_m_ready = 1'b1;
      end
      default: begin
      end
    endcase
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q          <= S_PASS;
      at_start_q       <= 1'b1;
      idx_q            <= '0;
      o_pause_ev       <= 1'b0;
      o_pause_tog      <= 1'b0;
      o_pause_interval <= '0;
    end else begin
      o_pause_ev <= 1'b0;
      unique case (state_q)
        S_PASS: begin
          if (i_m_valid && o_m_ready) begin
            if (at_start_q && da_match) begin
              hold_q     <= {i_m_code, i_m_data};
              state_q    <= S_HOLD;
              at_start_q <= 1'b0;
            end else begin
              at_start_q <= i_m_code[3];
            end
          end
        end
        S_HOLD: begin
          if (i_m_valid) begin
            if (is_pause) begin
              state_q <= S_DROP;
              idx_q   <= 2'd2;
            end else if (i_f_ready) begin
              state_q <= S_PASS;
            end
          end
        end
        S_DROP: begin
          if (i_m_valid) begin
            // Beat 2: bytes 16-17 are pause_time, high byte first.
            if (idx_q == 2'd2) o_pause_interval <= {i_m_data[7:0], i_m_data[15:8]};
            if (idx_q != 2'd3) idx_q <= idx_q + 2'd1;
            if (i_m_code[3]) begin
              state_q     <= S_PASS;
              at_start_q  <= 1'b1;
              o_pause_ev  <= 1'b1;
              o_pause_tog <= !o_pause_tog;
            end
          end
        end
        default: state_q <= S_PASS;
      endcase
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || !i_tx_en) o_want_pause <= 1'b0;
    else if (i_occupancy >= i_high_water) o_want_pause <= 1'b1;
    else if (i_occupancy <= i_low_water) o_want_pause <= 1'b0;
  end
endmodule : nic_pause_rx
