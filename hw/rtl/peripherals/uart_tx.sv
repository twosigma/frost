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
  UART transmitter with valid/ready handshaking.
  This module implements a UART transmitter that accepts data via a simple valid/ready
  interface and serializes it for transmission over a single-wire UART output. The module
  implements standard UART framing with 1 start bit, 8 data bits, and 1 stop bit (8N1
  configuration). A finite state machine manages the transmission sequence: IDLE waits
  for data, START_BIT sends the start bit, DATA_BITS shifts out the 8 data bits LSB-first,
  and STOP_BIT completes the frame. This module is used for debug console output.
 */
module uart_tx #(
    parameter int unsigned DATA_WIDTH  = 8,
    parameter int unsigned CLK_FREQ_HZ = 300000000,
    parameter int unsigned BAUD_RATE   = 115200
) (
    input logic i_clk,
    input logic i_rst,

    input  logic [DATA_WIDTH-1:0] i_data,
    input  logic                  i_valid,
    output logic                  o_ready,

    output logic o_uart
);

  // Baud rate generation: clock cycles per bit = CLK_FREQ / BAUD_RATE
  // Multiply by DATA_WIDTH to get cycles per byte, then divide during transmission
  localparam int unsigned ClockCyclesPerBit = CLK_FREQ_HZ / (BAUD_RATE * DATA_WIDTH);
  localparam int unsigned PrescalerCounterWidth = 19;

  // UART transmitter FSM states (8N1 format: 1 start, 8 data, 1 stop)
  typedef enum logic [1:0] {
    STATE_IDLE      = 2'b00,  // Waiting for data
    STATE_START_BIT = 2'b01,  // Transmitting start bit (low)
    STATE_DATA_BITS = 2'b10,  // Transmitting data bits (LSB first)
    STATE_STOP_BIT  = 2'b11   // Transmitting stop bit (high)
  } uart_state_t;

  uart_state_t current_state, next_state;

  logic ready_registered;
  logic uart_output_bit_registered;
  logic [DATA_WIDTH-1:0] data_shift_register;  // Holds data being transmitted
  logic [PrescalerCounterWidth-1:0] baud_rate_prescaler_counter;
  logic [3:0] bits_remaining_counter;  // Counts down from 8 to 0

  // Wire assignments for module outputs
  assign o_ready = ready_registered;
  assign o_uart  = uart_output_bit_registered;

  // FSM state register with synchronous reset
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      current_state <= STATE_IDLE;
    end else begin
      current_state <= next_state;
    end
  end

  // FSM next state logic - determines state transitions based on counters
  always_comb begin
    next_state = current_state;  // Default: stay in current state

    unique case (current_state)
      STATE_IDLE: begin
        // Start transmission when valid data arrives
        if (i_valid && ready_registered) begin
          next_state = STATE_START_BIT;
        end
      end

      STATE_START_BIT: begin
        // Move to data bits after start bit completes (prescaler reaches 0)
        if (baud_rate_prescaler_counter == 0) begin
          next_state = STATE_DATA_BITS;
        end
      end

      STATE_DATA_BITS: begin
        // Move to stop bit after all 8 data bits transmitted
        if (baud_rate_prescaler_counter == 0 && bits_remaining_counter == 0) begin
          next_state = STATE_STOP_BIT;
        end
      end

      STATE_STOP_BIT: begin
        // Return to idle after stop bit completes
        if (baud_rate_prescaler_counter == 0) begin
          next_state = STATE_IDLE;
        end
      end

      default: next_state = STATE_IDLE;
    endcase
  end

  // Datapath registers and UART bit generation logic
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ready_registered <= 1'b0;
      uart_output_bit_registered <= 1'b1;  // UART idle state is high
      data_shift_register <= '0;
      baud_rate_prescaler_counter <= '0;
      bits_remaining_counter <= '0;
    end else begin
      unique case (current_state)
        STATE_IDLE: begin
          uart_output_bit_registered <= 1'b1;  // UART line idle (high)
          ready_registered <= 1'b1;  // Ready to accept new data

          if (i_valid && ready_registered) begin
            // Capture incoming data and begin transmission
            data_shift_register <= i_data;
            ready_registered <= 1'b0;  // Not ready during transmission
            baud_rate_prescaler_counter <= PrescalerCounterWidth'((ClockCyclesPerBit << 3) - 1);
            bits_remaining_counter <= 4'(DATA_WIDTH);  // Will send 8 bits
          end
        end

        STATE_START_BIT: begin
          uart_output_bit_registered <= 1'b0;  // UART start bit is always low

          if (baud_rate_prescaler_counter > 0) begin
            baud_rate_prescaler_counter <= baud_rate_prescaler_counter - 1;
          end else begin
            // Start bit complete, move to data bits
            baud_rate_prescaler_counter <= PrescalerCounterWidth'((ClockCyclesPerBit << 3) - 1);
            bits_remaining_counter <= bits_remaining_counter - 1;
          end
        end

        STATE_DATA_BITS: begin
          // Transmit current data bit (LSB first per UART standard)
          uart_output_bit_registered <= data_shift_register[0];

          if (baud_rate_prescaler_counter > 0) begin
            baud_rate_prescaler_counter <= baud_rate_prescaler_counter - 1;
          end else begin
            if (bits_remaining_counter > 0) begin
              // Shift right for next bit (LSB first transmission)
              data_shift_register <= data_shift_register >> 1;
              bits_remaining_counter <= bits_remaining_counter - 1;
              baud_rate_prescaler_counter <= PrescalerCounterWidth'((ClockCyclesPerBit << 3) - 1);
            end else begin
              // All data bits sent, prepare for stop bit
              baud_rate_prescaler_counter <= PrescalerCounterWidth'((ClockCyclesPerBit << 3));
            end
          end
        end

        STATE_STOP_BIT: begin
          uart_output_bit_registered <= 1'b1;  // UART stop bit is always high

          if (baud_rate_prescaler_counter > 0) begin
            baud_rate_prescaler_counter <= baud_rate_prescaler_counter - 1;
          end else begin
            // Frame complete, return to idle and accept new data
            ready_registered <= 1'b1;
          end
        end

        default: begin
          ready_registered <= 1'b0;
          uart_output_bit_registered <= 1'b1;
          baud_rate_prescaler_counter <= '0;
          bits_remaining_counter <= '0;
        end
      endcase
    end
  end

endmodule : uart_tx
