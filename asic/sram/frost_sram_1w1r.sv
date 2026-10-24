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
 * The ASIC flow's simple dual-port memory: one write port and one read port.
 * Under FROST_SRAM_MACROS, which the ASIC flow (asic/config.mk) and the
 * simulations of the macros' models define, the RAM wrappers in
 * hw/rtl/lib/ram keep their storage here. A
 * memory of more than 4,096 bits whose depth and width are multiples of one
 * of the OpenRAM macros below, with write-mask lanes that macro can build,
 * is a grid of those macros; any other memory is a behavioral array, which
 * synthesis builds from flip-flops, or mocks as one row above 4,096 bits.
 * asic/openram.py generates the macros.
 *
 * Writes are synchronous to i_write_clock: bit k of i_write_mask writes lane
 * k, bits [k*MASK_GRANULE +: MASK_GRANULE], of the word at i_write_address.
 * Reads are synchronous to i_read_clock: in the cycle after one with
 * i_read_enable, o_read_data holds the word at that cycle's i_read_address.
 * After a cycle without a read, the macros' read data is undefined and the
 * array's holds.
 *
 * A macro reads the word that it writes in the same cycle as undefined data,
 * where the array, like a block RAM, reads the old word. A memory with one
 * lane on a COMMON_CLOCK gets the old word from macros too: they take each
 * write a cycle late, from a register, and a read of the word that the
 * register holds returns the register's copy. With more lanes, a macro-built
 * memory's read of the word being written is undefined, and with
 * COMMON_CLOCK simulation returns X for it, except in a bulk clear's cycle.
 *
 * SIM_BULK_CLEAR, for simulation only, makes i_bulk_clear zero every word
 * in one write-clock cycle and drop a write in the same cycle, as the
 * wrappers' behavioral clear does. The macros have no such operation;
 * simulation clears their models' words directly, so a macro's read in that
 * cycle returns zeros rather than the old word.
 *
 * The macros have no initial contents. With USE_INIT_FILE, simulation starts
 * the memory with the hex image INIT_FILE, of at most 2**ADDR_WIDTH words,
 * as a block RAM would; a chip writes the memory before reading it.
 */
module frost_sram_1w1r #(
    parameter int unsigned ADDR_WIDTH = 9,
    parameter int unsigned DATA_WIDTH = 64,
    parameter int unsigned MASK_GRANULE = DATA_WIDTH,
    // Both ports run on one clock, so a read and a write share cycles.
    parameter bit COMMON_CLOCK = 1'b1,
    parameter bit SIM_BULK_CLEAR = 1'b0,
    // Simulation only: the starting image, at most 40 characters.
    parameter bit USE_INIT_FILE = 1'b0,
    parameter bit [319:0] INIT_FILE = ""
) (
    input logic                               i_write_clock,
    input logic                               i_bulk_clear,
    input logic [DATA_WIDTH/MASK_GRANULE-1:0] i_write_mask,
    input logic [             ADDR_WIDTH-1:0] i_write_address,
    input logic [             DATA_WIDTH-1:0] i_write_data,

    input  logic                  i_read_clock,
    input  logic                  i_read_enable,
    input  logic [ADDR_WIDTH-1:0] i_read_address,
    output logic [DATA_WIDTH-1:0] o_read_data
);

  initial begin
    if (DATA_WIDTH % MASK_GRANULE != 0)
      $fatal(1, "frost_sram_1w1r: DATA_WIDTH must be a multiple of MASK_GRANULE");
`ifdef SYNTHESIS
    if (SIM_BULK_CLEAR) $fatal(1, "frost_sram_1w1r: bulk clear is for simulation only");
`endif
  end

  logic bulk_clear;
  assign bulk_clear = SIM_BULK_CLEAR && i_bulk_clear;

  localparam int unsigned Lanes = DATA_WIDTH / MASK_GRANULE;

  // Whether a memory tiles onto a macro of 2**tile_address_bits words of
  // tile_data_bits, whose write-mask bits enable tile_mask_bits each, or
  // whole words when tile_mask_bits is 0.
  function automatic bit fits(input int unsigned tile_address_bits,
                              input int unsigned tile_data_bits, input int unsigned tile_mask_bits);
    fits = (DATA_WIDTH * (2 ** ADDR_WIDTH) > 4096) && (ADDR_WIDTH >= tile_address_bits) &&
        (DATA_WIDTH % tile_data_bits == 0) &&
        ((tile_mask_bits != 0) ? (MASK_GRANULE % tile_mask_bits == 0) :
                                 (MASK_GRANULE % tile_data_bits == 0));
  endfunction

  // The macros, in order of preference (asic/openram.py, MACROS), and the
  // memories they build. An earlier macro that also fits takes a memory.
  localparam int unsigned ArrayMacro = 0;
  localparam int unsigned Macro4096x64m8 = 1;  // L2 data
  localparam int unsigned Macro1024x64m8 = 2;  // L1D data
  localparam int unsigned Macro1024x19 = 3;  // L1D tags
  localparam int unsigned Macro1024x18 = 4;  // L2 tags
  localparam int unsigned Macro512x68 = 5;  // NIC FIFOs
  localparam int unsigned Macro256x36 = 6;  // BTB slot-2 payloads
  localparam int unsigned Macro128x64m8 = 7;  // L1I data
  localparam int unsigned Macro8192x28 = 8;  // Instruction memory, cold banks
  localparam int unsigned Macro8192x4 = 9;  // Instruction memory, four-bit banks
  function automatic int unsigned select_macro();
    if (fits(12, 64, 8)) select_macro = Macro4096x64m8;
    else if (fits(10, 64, 8)) select_macro = Macro1024x64m8;
    else if (fits(10, 19, 0)) select_macro = Macro1024x19;
    else if (fits(10, 18, 0)) select_macro = Macro1024x18;
    else if (fits(9, 68, 0)) select_macro = Macro512x68;
    else if (fits(8, 36, 0)) select_macro = Macro256x36;
    else if (fits(7, 64, 8)) select_macro = Macro128x64m8;
    else if (fits(13, 28, 0)) select_macro = Macro8192x28;
    else if (fits(13, 4, 0)) select_macro = Macro8192x4;
    else select_macro = ArrayMacro;
  endfunction
  localparam int unsigned Macro = select_macro();
  localparam int unsigned TileAddrWidth =
      (Macro == Macro8192x28 || Macro == Macro8192x4) ? 13 :
      (Macro == Macro4096x64m8) ? 12 :
      (Macro == Macro1024x64m8 || Macro == Macro1024x19 || Macro == Macro1024x18) ? 10 :
      (Macro == Macro512x68) ? 9 :
      (Macro == Macro256x36) ? 8 :
      (Macro == Macro128x64m8) ? 7 : ADDR_WIDTH;
  localparam int unsigned TileDataWidth =
      (Macro == Macro4096x64m8 || Macro == Macro1024x64m8 || Macro == Macro128x64m8) ? 64 :
      (Macro == Macro1024x19) ? 19 :
      (Macro == Macro1024x18) ? 18 :
      (Macro == Macro512x68) ? 68 :
      (Macro == Macro256x36) ? 36 :
      (Macro == Macro8192x28) ? 28 :
      (Macro == Macro8192x4) ? 4 : DATA_WIDTH;
  // Bits per write-mask bit of the macro; 0 for whole-word writes.
  localparam int unsigned TileMaskGranule =
      (Macro == Macro4096x64m8 || Macro == Macro1024x64m8 || Macro == Macro128x64m8) ? 8 : 0;

  logic [DATA_WIDTH-1:0] read_data;

  // The write that the macros take this cycle, and whether this cycle's read
  // returns the held write's word instead of the macros' (gen_held_write).
  localparam bit HoldWrites = COMMON_CLOCK && (Lanes == 1) && (Macro != ArrayMacro);
  logic [     Lanes-1:0] macro_write_mask;
  logic [ADDR_WIDTH-1:0] macro_write_address;
  logic [DATA_WIDTH-1:0] macro_write_data;
  logic                  held_read_q;
  logic [DATA_WIDTH-1:0] held_read_data_q;
  if (HoldWrites) begin : gen_held_write
    // The bulk clear drops the held write as well as its own cycle's write,
    // since both come before it.
    logic                  held_q;
    logic [ADDR_WIDTH-1:0] held_address_q;
    logic [DATA_WIDTH-1:0] held_data_q;
    always_ff @(posedge i_write_clock) begin
      held_q         <= i_write_mask[0] && !bulk_clear;
      held_address_q <= i_write_address;
      held_data_q    <= i_write_data;
    end
    assign macro_write_mask    = held_q;
    assign macro_write_address = held_address_q;
    assign macro_write_data    = held_data_q;
    always_ff @(posedge i_read_clock) begin
      held_read_q <= i_read_enable && held_q && !bulk_clear && (i_read_address == held_address_q);
      held_read_data_q <= held_data_q;
    end
  end else begin : gen_direct_write
    assign macro_write_mask    = i_write_mask;
    assign macro_write_address = i_write_address;
    assign macro_write_data    = i_write_data;
    assign held_read_q         = 1'b0;
    assign held_read_data_q    = '0;
  end

  if (Macro == ArrayMacro) begin : gen_array
    logic [DATA_WIDTH-1:0] memory[2**ADDR_WIDTH];
    if (SIM_BULK_CLEAR) begin : gen_clearable_write
      always_ff @(posedge i_write_clock)
        if (bulk_clear) for (int i = 0; i < 2 ** ADDR_WIDTH; i++) memory[i] <= '0;
        else
          for (int lane = 0; lane < int'(Lanes); lane++)
            if (i_write_mask[lane])
              memory[i_write_address][lane*MASK_GRANULE+:MASK_GRANULE] <=
                i_write_data[lane*MASK_GRANULE+:MASK_GRANULE];
    end else begin : gen_write
      for (genvar lane = 0; lane < int'(Lanes); lane++) begin : gen_write_lane
        always_ff @(posedge i_write_clock)
          if (i_write_mask[lane])
            memory[i_write_address][lane*MASK_GRANULE+:MASK_GRANULE] <=
                i_write_data[lane*MASK_GRANULE+:MASK_GRANULE];
      end
    end
    always_ff @(posedge i_read_clock) if (i_read_enable) read_data <= memory[i_read_address];
`ifndef SYNTHESIS
    initial if (USE_INIT_FILE) $readmemh(INIT_FILE, memory);
`endif
  end else begin : gen_macros
    // A grid of Rows by Columns macros: the high address bits pick a row,
    // and each column holds TileDataWidth bits of the word.
    localparam int unsigned Rows = 2 ** (ADDR_WIDTH - TileAddrWidth);
    localparam int unsigned Columns = DATA_WIDTH / TileDataWidth;
    localparam int unsigned RowBits = (Rows > 1) ? $clog2(Rows) : 1;
    localparam int unsigned TileMaskBits =
        (TileMaskGranule != 0) ? TileDataWidth / TileMaskGranule : 1;

    logic [RowBits-1:0] write_row, read_row, read_row_q;
    if (Rows > 1) begin : gen_row_select
      assign write_row = macro_write_address[ADDR_WIDTH-1-:RowBits];
      assign read_row  = i_read_address[ADDR_WIDTH-1-:RowBits];
    end else begin : gen_one_row
      assign write_row = '0;
      assign read_row  = '0;
    end
    // The row whose words the macros' outputs hold, captured with the
    // address.
    always_ff @(posedge i_read_clock) if (i_read_enable) read_row_q <= read_row;

    // Row r's words in bits [r*DATA_WIDTH +: DATA_WIDTH].
    logic [Rows*DATA_WIDTH-1:0] row_read_data;
    assign read_data = row_read_data[read_row_q*DATA_WIDTH+:DATA_WIDTH];

    for (genvar row = 0; row < int'(Rows); row++) begin : gen_row
      for (genvar column = 0; column < int'(Columns); column++) begin : gen_column
        // The mask bits for this column: each macro mask bit, or the whole
        // tile for a macro without them, lies in one lane of the memory.
        logic [TileMaskBits-1:0] tile_mask;
        for (genvar mask_bit = 0; mask_bit < int'(TileMaskBits); mask_bit++) begin : gen_mask
          assign tile_mask[mask_bit] = macro_write_mask[(column*TileDataWidth+mask_bit*
              ((TileMaskGranule != 0) ? TileMaskGranule : TileDataWidth))/MASK_GRANULE];
        end
        logic write_select, read_select;
        assign write_select = !bulk_clear && (write_row == RowBits'(row)) && (|tile_mask);
        assign read_select  = i_read_enable && (read_row == RowBits'(row));

        logic [TileAddrWidth-1:0] write_address, read_address;
        logic [TileDataWidth-1:0] write_data, tile_read_data;
        assign write_address = macro_write_address[TileAddrWidth-1:0];
        assign read_address = i_read_address[TileAddrWidth-1:0];
        assign write_data = macro_write_data[column*TileDataWidth+:TileDataWidth];
        assign row_read_data[row*DATA_WIDTH+column*TileDataWidth+:TileDataWidth] = tile_read_data;

        // OpenRAM ports: 0 writes, 1 reads; chip selects are active low. The
        // alternatives share a name, so gen_macro.u_macro is the macro.
        if (Macro == Macro4096x64m8) begin : gen_macro
          sram_1w1r_4096x64_m8 u_macro (
              .clk0  (i_write_clock),
              .csb0  (!write_select),
              .wmask0(tile_mask),
              .addr0 (write_address),
              .din0  (write_data),
              .clk1  (i_read_clock),
              .csb1  (!read_select),
              .addr1 (read_address),
              .dout1 (tile_read_data)
          );
        end else if (Macro == Macro1024x64m8) begin : gen_macro
          sram_1w1r_1024x64_m8 u_macro (
              .clk0  (i_write_clock),
              .csb0  (!write_select),
              .wmask0(tile_mask),
              .addr0 (write_address),
              .din0  (write_data),
              .clk1  (i_read_clock),
              .csb1  (!read_select),
              .addr1 (read_address),
              .dout1 (tile_read_data)
          );
        end else if (Macro == Macro1024x19) begin : gen_macro
          sram_1w1r_1024x19 u_macro (
              .clk0 (i_write_clock),
              .csb0 (!write_select),
              .addr0(write_address),
              .din0 (write_data),
              .clk1 (i_read_clock),
              .csb1 (!read_select),
              .addr1(read_address),
              .dout1(tile_read_data)
          );
        end else if (Macro == Macro1024x18) begin : gen_macro
          sram_1w1r_1024x18 u_macro (
              .clk0 (i_write_clock),
              .csb0 (!write_select),
              .addr0(write_address),
              .din0 (write_data),
              .clk1 (i_read_clock),
              .csb1 (!read_select),
              .addr1(read_address),
              .dout1(tile_read_data)
          );
        end else if (Macro == Macro512x68) begin : gen_macro
          sram_1w1r_512x68 u_macro (
              .clk0 (i_write_clock),
              .csb0 (!write_select),
              .addr0(write_address),
              .din0 (write_data),
              .clk1 (i_read_clock),
              .csb1 (!read_select),
              .addr1(read_address),
              .dout1(tile_read_data)
          );
        end else if (Macro == Macro256x36) begin : gen_macro
          sram_1w1r_256x36 u_macro (
              .clk0 (i_write_clock),
              .csb0 (!write_select),
              .addr0(write_address),
              .din0 (write_data),
              .clk1 (i_read_clock),
              .csb1 (!read_select),
              .addr1(read_address),
              .dout1(tile_read_data)
          );
        end else if (Macro == Macro8192x28) begin : gen_macro
          sram_1w1r_8192x28 u_macro (
              .clk0 (i_write_clock),
              .csb0 (!write_select),
              .addr0(write_address),
              .din0 (write_data),
              .clk1 (i_read_clock),
              .csb1 (!read_select),
              .addr1(read_address),
              .dout1(tile_read_data)
          );
        end else if (Macro == Macro8192x4) begin : gen_macro
          sram_1w1r_8192x4 u_macro (
              .clk0 (i_write_clock),
              .csb0 (!write_select),
              .addr0(write_address),
              .din0 (write_data),
              .clk1 (i_read_clock),
              .csb1 (!read_select),
              .addr1(read_address),
              .dout1(tile_read_data)
          );
        end else begin : gen_macro
          sram_1w1r_128x64_m8 u_macro (
              .clk0  (i_write_clock),
              .csb0  (!write_select),
              .wmask0(tile_mask),
              .addr0 (write_address),
              .din0  (write_data),
              .clk1  (i_read_clock),
              .csb1  (!read_select),
              .addr1 (read_address),
              .dout1 (tile_read_data)
          );
        end
`ifndef SYNTHESIS
        if (SIM_BULK_CLEAR) begin : gen_bulk_clear
          always @(posedge i_write_clock)
            if (bulk_clear)
              for (int i = 0; i < 2 ** TileAddrWidth; i++) gen_macro.u_macro.mem[i] = '0;
        end
        // This macro's slice of the starting image.
        if (USE_INIT_FILE) begin : gen_init
          initial begin
            logic [DATA_WIDTH-1:0] image[2**ADDR_WIDTH];
            $readmemh(INIT_FILE, image);
            for (int i = 0; i < 2 ** TileAddrWidth; i++) begin
              gen_macro.u_macro.mem[i] =
                  image[row*(2**TileAddrWidth)+i][column*TileDataWidth+:TileDataWidth];
            end
          end
        end
`endif
      end
    end
  end

  // A macro's read of the word that it writes in the same cycle is
  // undefined, and simulation returns X for it; a held write's word comes
  // from its register instead. A bulk clear drops its cycle's write, so that
  // read returns zeros.
  logic [DATA_WIDTH-1:0] macro_read_data;
`ifndef SYNTHESIS
  if (COMMON_CLOCK && (Macro != ArrayMacro)) begin : gen_collision
    logic collision_q;
    always_ff @(posedge i_read_clock)
      collision_q <= i_read_enable && !bulk_clear && (|macro_write_mask) &&
          (i_read_address == macro_write_address);
    assign macro_read_data = collision_q ? 'x : read_data;
  end else begin : gen_no_collision
    assign macro_read_data = read_data;
  end
`else
  assign macro_read_data = read_data;
`endif
  assign o_read_data = held_read_q ? held_read_data_q : macro_read_data;

endmodule : frost_sram_1w1r
