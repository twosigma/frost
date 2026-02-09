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
  UART receiver with valid/ready handshaking.
  This module implements a UART receiver that samples the serial input and outputs
  received data via a simple valid/ready interface. The module implements standard
  UART framing with 1 start bit, 8 data bits, and 1 stop bit (8N1 configuration).
  A finite state machine manages the reception sequence: IDLE waits for start bit
  (falling edge), START_BIT verifies the start bit at mid-bit, DATA_BITS samples
  the 8 data bits LSB-first at mid-bit, and STOP_BIT verifies the stop bit.
  Data is sampled at the middle of each bit period for maximum noise immunity.
  This module is used for debug console input.
 */
module uart_rx #(
    parameter int unsigned DATA_WIDTH  = 8,
    parameter int unsigned CLK_FREQ_HZ = 300000000,
    parameter int unsigned BAUD_RATE   = 115200
) (
    input logic i_clk,
    input logic i_rst,

    input logic i_uart,

    output logic [DATA_WIDTH-1:0] o_data,
    output logic                  o_valid,
    input  logic                  i_ready
);

  // Baud rate generation: clock cycles per bit = CLK_FREQ / BAUD_RATE
  localparam int unsigned ClockCyclesPerBit = CLK_FREQ_HZ / BAUD_RATE;
  localparam int unsigned PrescalerCounterWidth = 19;

  // Half-bit delay for sampling in the middle of each bit
  localparam int unsigned HalfBitCycles = ClockCyclesPerBit / 2;

  // UART receiver FSM states (8N1 format: 1 start, 8 data, 1 stop)
  typedef enum logic [1:0] {
    STATE_IDLE      = 2'b00,  // Waiting for start bit (falling edge)
    STATE_START_BIT = 2'b01,  // Verifying start bit at mid-bit
    STATE_DATA_BITS = 2'b10,  // Receiving data bits (LSB first)
    STATE_STOP_BIT  = 2'b11   // Verifying stop bit
  } uart_state_t;

  uart_state_t current_state, next_state;

  // Input synchronization - 2-stage synchronizer for metastability protection
  (* ASYNC_REG = "TRUE" *)
  logic [1:0] uart_input_sync;
  logic uart_input_synchronized;
  always_ff @(posedge i_clk) begin
    uart_input_sync[0] <= i_uart;
    uart_input_sync[1] <= uart_input_sync[0];
  end
  assign uart_input_synchronized = uart_input_sync[1];

  logic [DATA_WIDTH-1:0] data_shift_register;  // Holds data being received
  logic [DATA_WIDTH-1:0] data_output_register;  // Holds completed received data
  logic [PrescalerCounterWidth-1:0] baud_rate_prescaler_counter;
  logic [$clog2(DATA_WIDTH+1)-1:0] bits_remaining_counter;  // Counts down from 8 to 0
  logic output_valid_registered;

  // Wire assignments for module outputs
  assign o_data  = data_output_register;
  assign o_valid = output_valid_registered;

  // FSM state register with synchronous reset
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      current_state <= STATE_IDLE;
    end else begin
      current_state <= next_state;
    end
  end

  // FSM next state logic - determines state transitions based on counters and input
  always_comb begin
    next_state = current_state;  // Default: stay in current state

    unique case (current_state)
      STATE_IDLE: begin
        // Start reception when start bit detected (falling edge - line goes low)
        if (!uart_input_synchronized) begin
          next_state = STATE_START_BIT;
        end
      end

      STATE_START_BIT: begin
        // At mid-bit, verify this is a real start bit (still low)
        if (baud_rate_prescaler_counter == 0) begin
          if (!uart_input_synchronized) begin
            // Valid start bit confirmed, move to data reception
            next_state = STATE_DATA_BITS;
          end else begin
            // False start - line went high, return to idle
            next_state = STATE_IDLE;
          end
        end
      end

      STATE_DATA_BITS: begin
        // Move to stop bit after all 8 data bits received
        if (baud_rate_prescaler_counter == 0 && bits_remaining_counter == 0) begin
          next_state = STATE_STOP_BIT;
        end
      end

      STATE_STOP_BIT: begin
        // Return to idle after stop bit sampled
        if (baud_rate_prescaler_counter == 0) begin
          next_state = STATE_IDLE;
        end
      end

      default: next_state = STATE_IDLE;
    endcase
  end

  // Datapath registers and UART bit sampling logic
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      data_shift_register <= '0;
      data_output_register <= '0;
      baud_rate_prescaler_counter <= '0;
      bits_remaining_counter <= '0;
      output_valid_registered <= 1'b0;
    end else begin
      // Clear valid when downstream accepts data
      if (output_valid_registered && i_ready) begin
        output_valid_registered <= 1'b0;
      end

      unique case (current_state)
        STATE_IDLE: begin
          if (!uart_input_synchronized) begin
            // Falling edge detected - start bit beginning
            // Wait half a bit period to sample at middle of start bit
            baud_rate_prescaler_counter <= PrescalerCounterWidth'(HalfBitCycles - 1);
            bits_remaining_counter <= ($clog2(DATA_WIDTH + 1))'(DATA_WIDTH);  // Will receive 8 bits
            data_shift_register <= '0;
          end
        end

        STATE_START_BIT: begin
          if (baud_rate_prescaler_counter > 0) begin
            baud_rate_prescaler_counter <= baud_rate_prescaler_counter - 1;
          end else begin
            // At mid-bit of start bit, set up for first data bit
            // Wait full bit period to reach middle of first data bit
            if (!uart_input_synchronized) begin
              baud_rate_prescaler_counter <= PrescalerCounterWidth'(ClockCyclesPerBit - 1);
            end
            // If start bit invalid (high), FSM returns to IDLE - no action needed here
          end
        end

        STATE_DATA_BITS: begin
          if (baud_rate_prescaler_counter > 0) begin
            baud_rate_prescaler_counter <= baud_rate_prescaler_counter - 1;
          end else begin
            if (bits_remaining_counter > 0) begin
              // Sample current bit at mid-bit, shift into MSB (LSB first reception)
              data_shift_register <= {uart_input_synchronized, data_shift_register[DATA_WIDTH-1:1]};
              bits_remaining_counter <= bits_remaining_counter - 1;
              baud_rate_prescaler_counter <= PrescalerCounterWidth'(ClockCyclesPerBit - 1);
            end else begin
              // All data bits received, wait for stop bit
              baud_rate_prescaler_counter <= PrescalerCounterWidth'(ClockCyclesPerBit - 1);
            end
          end
        end

        STATE_STOP_BIT: begin
          if (baud_rate_prescaler_counter > 0) begin
            baud_rate_prescaler_counter <= baud_rate_prescaler_counter - 1;
          end else begin
            // Stop bit sampled - if valid (high), output received data
            if (uart_input_synchronized) begin
              data_output_register <= data_shift_register;
              output_valid_registered <= 1'b1;
            end
            // If stop bit invalid (low) - framing error, discard data silently
          end
        end

        default: begin
          baud_rate_prescaler_counter <= '0;
          bits_remaining_counter <= '0;
        end
      endcase
    end
  end

endmodule : uart_rx
