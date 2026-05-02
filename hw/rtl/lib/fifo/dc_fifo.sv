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
 * Dual-clock synchronous FIFO with valid/ready handshaking.
 * This module transfers data between two clock domains that share the same source
 * (e.g., a main clock and a divided version from an MMCM). Since the clocks have a
 * fixed phase relationship, Gray code pointer encoding is unnecessary - simple binary
 * pointers with 2-FF synchronizers suffice. The FIFO uses dual-clock block RAM allowing
 * independent read and write clocks. Write operations occur in the input clock domain
 * while reads occur in the output clock domain. This FIFO is used for crossing
 * between the main CPU clock and the divided peripheral clock (UART, JTAG) in the system.
 */
module dc_fifo #(
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned DEPTH = 4096,
    parameter int unsigned READY_MARGIN = 1
) (
    // Input (write) interface
    input  logic                  i_clk,
    input  logic                  i_rst,
    input  logic [DATA_WIDTH-1:0] i_data,
    input  logic                  i_valid,
    output logic                  o_ready,

    // Output (read) interface
    input  logic                  o_clk,
    input  logic                  o_rst,
    output logic [DATA_WIDTH-1:0] o_data,
    output logic                  o_valid,
    input  logic                  i_ready
);


  localparam int unsigned AddressWidth = $clog2(DEPTH);
  localparam int unsigned EffectiveReadyMargin = (READY_MARGIN == 0) ? 1 : READY_MARGIN;
  localparam int unsigned ReadyThresholdInt = (DEPTH > EffectiveReadyMargin) ?
                                              (DEPTH - EffectiveReadyMargin) :
                                              0;
  localparam logic [AddressWidth:0] ReadyThreshold = (AddressWidth + 1)'(ReadyThresholdInt);

  // Dual-clock block RAM for crossing between clock domains
  logic [DATA_WIDTH-1:0] memory_read_data;
  logic [AddressWidth-1:0] memory_write_address;
  logic [AddressWidth-1:0] memory_read_address;
  logic memory_write_enable;

  sdp_block_ram_dc #(
      .ADDR_WIDTH(AddressWidth),
      .DATA_WIDTH(DATA_WIDTH)
  ) synchronous_dual_clock_fifo_storage (
      .i_write_clock(i_clk),
      .i_read_clock(o_clk),
      .i_write_enable(memory_write_enable),
      .i_write_address(memory_write_address),
      .i_read_address(memory_read_address),
      .i_write_data(i_data),
      .o_read_data(memory_read_data)
  );

  // Binary pointers for each clock domain
  // Since clocks are derived from same source (synchronous), no Gray code needed
  // _i suffix: input (write) clock domain
  // _o suffix: output (read) clock domain
  // _sync1, _sync2: synchronizer stages (2-FF synchronizer for timing closure)
  logic [AddressWidth:0] write_pointer_in_input_domain;
  logic [AddressWidth:0] write_pointer_synchronized_stage1;
  logic [AddressWidth:0] write_pointer_synchronized_stage2;
  logic [AddressWidth:0] read_pointer_in_output_domain;
  logic [AddressWidth:0] read_pointer_synchronized_stage1;
  logic [AddressWidth:0] read_pointer_synchronized_stage2;

  // Write when input provides valid data and FIFO has space
  assign memory_write_enable  = i_valid && o_ready;
  assign memory_write_address = write_pointer_in_input_domain[AddressWidth-1:0];
  assign memory_read_address  = read_pointer_in_output_domain[AddressWidth-1:0];

  // Next pointer values (incremented)
  logic [AddressWidth:0] write_pointer_next;
  assign write_pointer_next = write_pointer_in_input_domain + 1;
  logic [AddressWidth:0] read_pointer_next;
  assign read_pointer_next = read_pointer_in_output_domain + 1;

  // Write clock domain logic (input side)
  always @(posedge i_clk) begin
    if (i_rst) begin
      write_pointer_in_input_domain <= 0;
    end else begin
      // Write when input has valid data and we signal ready (FIFO not full)
      if (i_valid && o_ready) begin
        write_pointer_in_input_domain <= write_pointer_next;
      end
    end
  end

  // Clock domain crossing: Synchronize read pointer from output to input domain
  // 2-FF synchronizer helps with timing closure even for synchronous clocks
  always @(posedge i_clk) begin
    if (i_rst) begin
      read_pointer_synchronized_stage1 <= '0;
      read_pointer_synchronized_stage2 <= '0;
    end else begin
      read_pointer_synchronized_stage1 <= read_pointer_in_output_domain;
      read_pointer_synchronized_stage2 <= read_pointer_synchronized_stage1;
    end
  end

  // FIFO is ready when there is enough free space for one write plus a small
  // caller-selected margin for upstream pipeline delay.
  logic [AddressWidth:0] write_occupancy_after_next;
  assign write_occupancy_after_next = write_pointer_next - read_pointer_synchronized_stage2;
  assign o_ready = write_occupancy_after_next <= ReadyThreshold;

  // Read clock domain logic (output side)
  logic read_data_valid_registered;

  always @(posedge o_clk) begin
    if (o_rst) begin
      read_pointer_in_output_domain <= 0;
      read_data_valid_registered <= 0;
    end else begin
      // Read when: 1) No valid data OR consumer ready, AND 2) FIFO not empty
      if ((!read_data_valid_registered || i_ready) &&
          (read_pointer_in_output_domain != write_pointer_synchronized_stage2)) begin
        // Read data from memory (already registered in sdp_block_ram_dc)
        o_data <= memory_read_data;
        read_pointer_in_output_domain <= read_pointer_next;
        read_data_valid_registered <= 1;
      end else if (i_ready) begin
        // Consumer accepted data, clear valid flag
        read_data_valid_registered <= 0;
      end
    end
  end

  // Clock domain crossing: Synchronize write pointer from input to output domain
  // 2-FF synchronizer helps with timing closure even for synchronous clocks
  always @(posedge o_clk) begin
    if (o_rst) begin
      write_pointer_synchronized_stage1 <= '0;
      write_pointer_synchronized_stage2 <= '0;
    end else begin
      write_pointer_synchronized_stage1 <= write_pointer_in_input_domain;
      write_pointer_synchronized_stage2 <= write_pointer_synchronized_stage1;
    end
  end

  // Output valid signal indicates data is available for consumer
  assign o_valid = read_data_valid_registered;

endmodule : dc_fifo
