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
 * Valid/ready FIFO between clocks with a fixed phase relationship, such as
 * MMCM-related main and divided clocks. Binary pointers cross through two-flop
 * synchronizers; storage is dual-clock block RAM. This is not a general
 * asynchronous FIFO: unrelated clocks require Gray-coded pointers
 * (async_fifo).
 *
 * The RAM holds up to DEPTH - 1 entries, besides the one in the output
 * register. The write side sees the read pointer through its synchronizer, so
 * its occupancy is never below the true one and its status outputs are
 * conservative: o_ready (room for this write; the write is i_valid &&
 * o_ready), o_almost_full (fewer than ALMOST_FULL_MARGIN more writes fit),
 * and o_empty (every entry written has left the RAM for the output
 * register). o_almost_full is an early warning for a writer that cannot check
 * o_ready on every write, such as software that polls a status bit and then
 * writes a burst.
 *
 * The storage read is registered and lags the read pointer by one o_clk
 * cycle, so after o_data loads an entry the next load waits a cycle for that
 * read. A consumer may take o_data in any cycle o_valid is high; one that
 * takes it right after a load sees o_valid low for a cycle.
 *
 * Each side resets in its own domain, at its own clock edges, and a write
 * during the write-side reset is dropped. Each side must apply its reset at
 * one of its clock edges while the other side is still held in reset, so the
 * resets must span several cycles of the slower clock. Otherwise one side
 * works from the other side's old pointer: the status is wrong, stale entries
 * can come out, and the pointers can stay out of step.
 */
module dc_fifo #(
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned DEPTH = 4096,
    parameter int unsigned ALMOST_FULL_MARGIN = 1
) (
    // Input (write) interface
    input  logic                  i_clk,
    input  logic                  i_rst,
    input  logic [DATA_WIDTH-1:0] i_data,
    input  logic                  i_valid,
    output logic                  o_ready,
    output logic                  o_almost_full,
    output logic                  o_empty,

    // Output (read) interface
    input  logic                  o_clk,
    input  logic                  o_rst,
    output logic [DATA_WIDTH-1:0] o_data,
    output logic                  o_valid,
    input  logic                  i_ready
);


  localparam int unsigned AddressWidth = $clog2(DEPTH);

  initial begin
    if ((1 << AddressWidth) != DEPTH) $fatal(1, "dc_fifo: DEPTH must be a power of two");
    if (ALMOST_FULL_MARGIN == 0 || ALMOST_FULL_MARGIN >= DEPTH)
      $fatal(1, "dc_fifo: ALMOST_FULL_MARGIN must be in 1..DEPTH-1");
  end

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

  // Binary pointers, one per clock domain, each crossing into the other
  // domain through two synchronizer stages. The clocks share a source, so the
  // second stage buys timing closure rather than metastability protection.
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

  logic [AddressWidth:0] write_pointer_next;
  assign write_pointer_next = write_pointer_in_input_domain + 1;
  logic [AddressWidth:0] read_pointer_next;
  assign read_pointer_next = read_pointer_in_output_domain + 1;

  // Write clock domain logic (input side)
  always @(posedge i_clk) begin
    if (i_rst) begin
      write_pointer_in_input_domain <= 0;
    end else begin
      if (i_valid && o_ready) begin
        write_pointer_in_input_domain <= write_pointer_next;
      end
    end
  end

  // Read pointer crossing into the input domain.
  always @(posedge i_clk) begin
    if (i_rst) begin
      read_pointer_synchronized_stage1 <= '0;
      read_pointer_synchronized_stage2 <= '0;
    end else begin
      read_pointer_synchronized_stage1 <= read_pointer_in_output_domain;
      read_pointer_synchronized_stage2 <= read_pointer_synchronized_stage1;
    end
  end

  // Write-side status from the occupancy seen through the synchronizer.
  logic [AddressWidth:0] write_occupancy;
  assign write_occupancy = write_pointer_in_input_domain - read_pointer_synchronized_stage2;
  assign o_ready = write_occupancy < (AddressWidth + 1)'(DEPTH - 1);
  assign o_almost_full = write_occupancy >= (AddressWidth + 1)'(DEPTH - ALMOST_FULL_MARGIN);
  assign o_empty = write_pointer_in_input_domain == read_pointer_synchronized_stage2;

  // Read clock domain logic (output side). memory_read_data holds the entry
  // at the read pointer only if the pointer did not move at the last edge.
  logic read_data_valid_registered;
  logic read_data_fresh;
  logic take, load;
  assign take = read_data_valid_registered && i_ready;
  assign load = (!read_data_valid_registered || take) && read_data_fresh &&
      (read_pointer_in_output_domain != write_pointer_synchronized_stage2);

  always @(posedge o_clk) begin
    if (o_rst) begin
      read_pointer_in_output_domain <= 0;
      read_data_valid_registered <= 0;
      read_data_fresh <= 0;
    end else begin
      read_data_fresh <= !load;
      if (load) begin
        // Load the next entry once the output register is free.
        o_data <= memory_read_data;
        read_pointer_in_output_domain <= read_pointer_next;
        read_data_valid_registered <= 1;
      end else if (take) begin
        // The consumer took the entry and no next one is ready yet.
        read_data_valid_registered <= 0;
      end
    end
  end

  // Write pointer crossing into the output domain.
  always @(posedge o_clk) begin
    if (o_rst) begin
      write_pointer_synchronized_stage1 <= '0;
      write_pointer_synchronized_stage2 <= '0;
    end else begin
      write_pointer_synchronized_stage1 <= write_pointer_in_input_domain;
      write_pointer_synchronized_stage2 <= write_pointer_synchronized_stage1;
    end
  end

  assign o_valid = read_data_valid_registered;

endmodule : dc_fifo
