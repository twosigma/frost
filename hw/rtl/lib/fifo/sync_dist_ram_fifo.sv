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
 * Circular FIFO in distributed RAM with asynchronous read. Reads are gated
 * when empty, but writes are not gated by o_full: writing while full overwrites
 * the oldest entry and advances fill_count beyond FifoDepth, deasserting
 * o_full. Callers must prevent overflow; frost.sv's MMIO FIFOs deliberately
 * ignore o_full for timing.
 */
module sync_dist_ram_fifo #(
    parameter int unsigned ADDR_WIDTH = 5,  // Address width (FIFO has 2^ADDR_WIDTH entries)
    parameter int unsigned DATA_WIDTH = 32  // Data width in bits
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_write_enable,  // Push data into FIFO
    input logic i_read_enable,  // Pop data from FIFO
    input logic [DATA_WIDTH-1:0] i_write_data,
    output logic [DATA_WIDTH-1:0] o_read_data,
    output logic o_empty,  // FIFO is empty (no data available)
    output logic o_full  // FIFO is full (no space available)
);

  localparam int unsigned FifoDepth = 2 ** ADDR_WIDTH;
  localparam int unsigned FillCountWidth = ADDR_WIDTH + 1;  // +1 to represent full state

  // FIFO pointers and status
  logic [ADDR_WIDTH-1:0] write_pointer, read_pointer;
  logic [FillCountWidth-1:0] fill_count;  // Number of entries currently in FIFO
  logic fifo_is_empty;

  // Underlying distributed RAM storage
  sdp_dist_ram #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_WIDTH(DATA_WIDTH)
  ) fifo_storage_ram (
      .i_clk(i_clk),
      .i_write_enable(i_write_enable),
      .i_write_address(write_pointer),
      .i_read_address(read_pointer),
      .i_write_data(i_write_data),
      .o_read_data(o_read_data)
  );

  // FIFO pointer and counter management
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      write_pointer <= '0;
      read_pointer  <= '0;
      fill_count    <= '0;
    end else begin
      // Advance write pointer on write (wraps around automatically)
      if (i_write_enable) begin
        write_pointer <= write_pointer + 1'b1;
      end

      // Advance read pointer on read (only if not empty)
      if (i_read_enable & ~fifo_is_empty) begin
        read_pointer <= read_pointer + 1'b1;
      end

      // Update fill count based on simultaneous reads and writes
      if (i_write_enable & ~(i_read_enable & ~fifo_is_empty)) begin
        fill_count <= fill_count + 1'b1;  // Write only: increment
      end else if (~i_write_enable & (i_read_enable & ~fifo_is_empty)) begin
        fill_count <= fill_count - 1'b1;  // Read only: decrement
      end
      // If both write and read, fill count stays the same
    end
  end

  // FIFO status flags
  assign fifo_is_empty = (fill_count == '0);
  assign o_full        = (fill_count == FillCountWidth'(FifoDepth));
  assign o_empty       = fifo_is_empty;

endmodule : sync_dist_ram_fifo
