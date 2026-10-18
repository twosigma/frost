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
 * Width-generic simple-dual-port tag RAM packed into 72-bit UltraRAM rows.
 * Logical entries are rounded up to the XPM's 9-bit write granule, and each
 * row then holds the largest power-of-two number of slots that fits:
 *
 *   DATA_WIDTH       slot width       logical entries / physical row
 *       1..9              9                         8
 *      10..18            18                         4
 *      19..27            27                         2
 *      28..36            36                         2
 *      37..72          45..72                       1
 *
 * Entries are accessed in aligned groups of READ_WORDS consecutive logical
 * entries (a power of 2). A read returns the whole group containing
 * i_read_address, entry j of the group in word j of o_read_data. A write
 * updates the words of the group containing i_write_address that
 * i_write_word_mask selects, all with i_write_data. With READ_WORDS=1 a
 * group is one entry: reads and writes address single entries, and the
 * mask's one bit enables the write. frost_cache reads all ways of a set at
 * once this way.
 *
 * A group shares one physical row when it fits. A larger group spreads over
 * READ_WORDS / (entries per row) banks, each a full-width array read at the
 * same row address. Every slot has its own 9-bit XPM write enables, so a
 * write preserves every slot it does not select. Writes take one cycle and
 * same-cycle read/write collisions return the old value.
 *
 * READ_LATENCY includes the final registered group-select mux. The XPM, or
 * its portable behavioral equivalent, supplies READ_LATENCY-1 cycles and the
 * mux supplies the last cycle. i_read_enable qualifies a logical request, and
 * the caller tracks response validity. The hardware URAM read port runs
 * continuously; only qualified results reach o_read_data.
 *
 * SUPPORT_BULK_CLEAR selects a portable simulation implementation with a
 * one-cycle clear of every physical row. Hardware instances leave it zero so
 * the array remains an UltraRAM without array-wide reset logic.
 */
module sdp_packed_tag_uram #(
    parameter int unsigned ADDR_WIDTH         = 16,
    parameter int unsigned DATA_WIDTH         = 13,
    parameter int unsigned READ_LATENCY       = 3,
    parameter int unsigned READ_WORDS         = 1,
    parameter int unsigned SUPPORT_BULK_CLEAR = 0
) (
    input logic i_clk,

    input logic                  i_write_enable,
    input logic                  i_bulk_clear,
    input logic [ADDR_WIDTH-1:0] i_write_address,
    input logic [READ_WORDS-1:0] i_write_word_mask,
    input logic [DATA_WIDTH-1:0] i_write_data,

    input  logic                             i_read_enable,
    input  logic [           ADDR_WIDTH-1:0] i_read_address,
    output logic [READ_WORDS*DATA_WIDTH-1:0] o_read_data
);

  localparam int unsigned PhysicalRowWidth = 72;
  localparam int unsigned WriteGranuleWidth = 9;
  localparam int unsigned GranulesPerRow = PhysicalRowWidth / WriteGranuleWidth;
  localparam int unsigned GranulesPerSlot = (DATA_WIDTH + WriteGranuleWidth - 1) /
      WriteGranuleWidth;
  localparam int unsigned WidthLimitedSlots =
      (GranulesPerSlot <= 1) ? 8 :
      (GranulesPerSlot <= 2) ? 4 :
      (GranulesPerSlot <= 4) ? 2 : 1;
  localparam int unsigned WidthLimitedLaneBits = $clog2(WidthLimitedSlots);
  // Tiny logical memories can have fewer entries than the width permits per
  // row. Capping the lane bits also avoids an empty physical-address slice.
  localparam int unsigned LaneBits =
      (ADDR_WIDTH < WidthLimitedLaneBits) ? ADDR_WIDTH : WidthLimitedLaneBits;
  localparam int unsigned SlotsPerRow = 2 ** LaneBits;
  localparam int unsigned SlotWidth = GranulesPerSlot * WriteGranuleWidth;
  localparam int unsigned XpmReadLatency = READ_LATENCY - 1;
  // A group's words in one bank's row (RowWords), the banks a group spans,
  // and the groups sharing a row. Entry address = {row, group, word}.
  localparam int unsigned WordBits = $clog2(READ_WORDS);
  localparam int unsigned RowWords = (READ_WORDS < SlotsPerRow) ? READ_WORDS : SlotsPerRow;
  localparam int unsigned Banks = READ_WORDS / RowWords;
  localparam int unsigned GroupsPerRow = SlotsPerRow / RowWords;
  localparam int unsigned GroupBits = $clog2(GroupsPerRow);
  localparam int unsigned GroupSelectWidth = (GroupBits == 0) ? 1 : GroupBits;
  localparam int unsigned PhysicalAddrBits = ADDR_WIDTH - WordBits - GroupBits;
  localparam int unsigned PhysicalAddrWidth = (PhysicalAddrBits == 0) ? 1 : PhysicalAddrBits;
  localparam int unsigned PhysicalDepth = 2 ** PhysicalAddrBits;

  initial begin
    if (ADDR_WIDTH < 1) $fatal(1, "sdp_packed_tag_uram: ADDR_WIDTH must be >= 1");
    if ((DATA_WIDTH < 1) || (DATA_WIDTH > 72))
      $fatal(1, "sdp_packed_tag_uram: DATA_WIDTH must be in [1, 72]");
    if (READ_LATENCY < 2) $fatal(1, "sdp_packed_tag_uram: READ_LATENCY must be >= 2");
    if ((READ_WORDS < 1) || (2 ** WordBits != READ_WORDS) || (WordBits > ADDR_WIDTH))
      $fatal(1, "sdp_packed_tag_uram: READ_WORDS must be a power of 2 within the entries");
  end

  logic [GroupSelectWidth-1:0] write_group;
  logic [GroupSelectWidth-1:0] read_group;
  if (GroupBits == 0) begin : gen_single_group_row
    assign write_group = '0;
    assign read_group  = '0;
  end else begin : gen_multi_group_row
    assign write_group = i_write_address[WordBits+:GroupBits];
    assign read_group  = i_read_address[WordBits+:GroupBits];
  end

  logic [PhysicalAddrWidth-1:0] write_row_address;
  logic [PhysicalAddrWidth-1:0] read_row_address;
  assign write_row_address = PhysicalAddrWidth'(i_write_address >> (WordBits + GroupBits));
  assign read_row_address  = PhysicalAddrWidth'(i_read_address >> (WordBits + GroupBits));

  // Bank b's slot g * RowWords + r holds word b * RowWords + r of the
  // group in position g of its row.
  logic [PhysicalRowWidth-1:0] physical_write_data;
  logic [  GranulesPerRow-1:0] physical_write_enable[Banks];
  always_comb begin
    physical_write_data = '0;
    for (int unsigned slot = 0; slot < SlotsPerRow; slot++) begin
      // All slots receive the payload; write enables select destinations.
      physical_write_data[slot*SlotWidth+:DATA_WIDTH] = i_write_data;
    end
    for (int unsigned bank = 0; bank < Banks; bank++) begin
      physical_write_enable[bank] = '0;
      for (int unsigned group = 0; group < GroupsPerRow; group++) begin
        for (int unsigned word = 0; word < RowWords; word++) begin
          if (int'(write_group) == group) begin
            physical_write_enable[bank][(group*RowWords+word)*GranulesPerSlot+:GranulesPerSlot] =
                {GranulesPerSlot{i_write_enable && i_write_word_mask[bank*RowWords+word]}};
          end
        end
      end
    end
  end

  logic [PhysicalRowWidth-1:0] row_dout[Banks];

`ifdef FROST_XILINX_PRIMS
`ifdef FROST_VIVADO_SYNTH
`ifndef YOSYS
  `define FROST_PACKED_TAG_USE_XPM
`endif
`endif
`endif

  for (genvar gb = 0; gb < int'(Banks); gb++) begin : gen_bank
    // Bulk clear is a simulation acceleration. Selecting it elaborates a
    // portable array, which keeps the clear loop out of the hardware XPM.
    if (SUPPORT_BULK_CLEAR != 0) begin : gen_clearable_storage
      (* ram_style = "ultra" *)logic [PhysicalRowWidth-1:0] memory [ PhysicalDepth];
      logic [PhysicalRowWidth-1:0] rd_pipe[XpmReadLatency];

      always_ff @(posedge i_clk) begin
        if (i_bulk_clear) for (int unsigned row = 0; row < PhysicalDepth; row++) memory[row] <= '0;
        else
          for (int unsigned granule = 0; granule < GranulesPerRow; granule++)
          if (physical_write_enable[gb][granule])
            memory[write_row_address][granule*WriteGranuleWidth+:WriteGranuleWidth] <=
                  physical_write_data[granule*WriteGranuleWidth+:WriteGranuleWidth];
      end

      always_ff @(posedge i_clk) begin
        if (i_read_enable) rd_pipe[0] <= memory[read_row_address];
        for (int unsigned stage = 1; stage < XpmReadLatency; stage++)
        rd_pipe[stage] <= rd_pipe[stage-1];
      end
      assign row_dout[gb] = rd_pipe[XpmReadLatency-1];
    end else begin : gen_hardware_storage
`ifdef FROST_PACKED_TAG_USE_XPM
      xpm_memory_sdpram #(
          .ADDR_WIDTH_A(PhysicalAddrWidth),
          .ADDR_WIDTH_B(PhysicalAddrWidth),
          .AUTO_SLEEP_TIME(0),
          .BYTE_WRITE_WIDTH_A(WriteGranuleWidth),
          // Use parallel banks for timing, preserving latency and write granularity.
          .CASCADE_HEIGHT(1),
          .CLOCKING_MODE("common_clock"),
          .ECC_MODE("no_ecc"),
          .MEMORY_INIT_FILE("none"),
          .MEMORY_INIT_PARAM("0"),
          .MEMORY_OPTIMIZATION("true"),
          .MEMORY_PRIMITIVE("ultra"),
          .MEMORY_SIZE(PhysicalRowWidth * PhysicalDepth),
          .MESSAGE_CONTROL(0),
          .READ_DATA_WIDTH_B(PhysicalRowWidth),
          .READ_LATENCY_B(XpmReadLatency),
          .READ_RESET_VALUE_B("0"),
          .RST_MODE_A("SYNC"),
          .RST_MODE_B("SYNC"),
          .SIM_ASSERT_CHK(0),
          .USE_EMBEDDED_CONSTRAINT(0),
          .USE_MEM_INIT(0),
          .WAKEUP_TIME("disable_sleep"),
          .WRITE_DATA_WIDTH_A(PhysicalRowWidth),
          .WRITE_MODE_B("read_first"),
          .WRITE_PROTECT(1)
      ) u_xpm_ram (
          .doutb         (row_dout[gb]),
          .dbiterrb      (),
          .sbiterrb      (),
          .clka          (i_clk),
          .clkb          (i_clk),
          .ena           (|physical_write_enable[gb]),
          .wea           (physical_write_enable[gb]),
          .addra         (write_row_address),
          .dina          (physical_write_data),
          // Read continuously; the final register qualifies responses.
          .enb           (1'b1),
          .addrb         (read_row_address),
          .regceb        (1'b1),
          .rstb          (1'b0),
          .sleep         (1'b0),
          .injectsbiterra(1'b0),
          .injectdbiterra(1'b0)
      );
`else
      (* ram_style = "ultra" *)logic [PhysicalRowWidth-1:0] memory [ PhysicalDepth];
      logic [PhysicalRowWidth-1:0] rd_pipe[XpmReadLatency];

      for (genvar granule = 0; granule < int'(GranulesPerRow); granule++) begin : gen_write_granule
        always_ff @(posedge i_clk)
          if (physical_write_enable[gb][granule])
            memory[write_row_address][granule*WriteGranuleWidth+:WriteGranuleWidth] <=
                physical_write_data[granule*WriteGranuleWidth+:WriteGranuleWidth];
      end

      always_ff @(posedge i_clk) begin
        if (i_read_enable) rd_pipe[0] <= memory[read_row_address];
        for (int unsigned stage = 1; stage < XpmReadLatency; stage++)
        rd_pipe[stage] <= rd_pipe[stage-1];
      end
      assign row_dout[gb] = rd_pipe[XpmReadLatency-1];
`endif
    end
  end

`ifdef FROST_PACKED_TAG_USE_XPM
  `undef FROST_PACKED_TAG_USE_XPM
`endif

  // Delay the group with the row. Unqualified groups reach the final mux
  // only when read_valid_pipe is low, so the group pipeline needs no enable.
  // The final register supplies the last READ_LATENCY cycle and holds its
  // output between qualified responses.
  logic [GroupSelectWidth-1:0] read_group_pipe[XpmReadLatency];
  logic read_valid_pipe[XpmReadLatency];
  always_ff @(posedge i_clk) begin
    read_valid_pipe[0] <= i_read_enable;
    read_group_pipe[0] <= read_group;
    for (int unsigned stage = 1; stage < XpmReadLatency; stage++) begin
      read_valid_pipe[stage] <= read_valid_pipe[stage-1];
      read_group_pipe[stage] <= read_group_pipe[stage-1];
    end
  end

  always_ff @(posedge i_clk)
    if (read_valid_pipe[XpmReadLatency-1])
      for (int unsigned bank = 0; bank < Banks; bank++)
        for (int unsigned word = 0; word < RowWords; word++)
          o_read_data[(bank*RowWords+word)*DATA_WIDTH+:DATA_WIDTH] <=
          row_dout[bank][(int'(read_group_pipe[XpmReadLatency-1])*RowWords+word)*SlotWidth+:
                         DATA_WIDTH];

endmodule : sdp_packed_tag_uram
