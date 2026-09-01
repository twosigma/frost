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
 * Logical entries are rounded up to the XPM's 9-bit write granule, then the
 * largest power-of-two number of slots that fits in a row is used:
 *
 *   DATA_WIDTH       slot width       logical entries / physical row
 *       1..9              9                         8
 *      10..18            18                         4
 *      19..27            27                         2
 *      28..36            36                         2
 *      37..72          45..72                       1
 *
 * This makes a write update exactly one logical entry through the 9-bit XPM
 * write enables, preserving every sibling in the same physical row. Writes
 * take one cycle and same-cycle read/write collisions return the old value.
 *
 * READ_LATENCY includes the final registered lane-select mux. The XPM (or its
 * portable behavioral equivalent) supplies READ_LATENCY-1 cycles and the mux
 * supplies the last cycle. i_read_enable qualifies a logical request but the
 * caller deliberately owns the matching response-valid pipeline. In hardware
 * the physical URAM read port runs continuously so a late request-valid cone
 * does not feed the enable cascade; only qualified results reach o_read_data.
 *
 * SUPPORT_BULK_CLEAR selects a portable simulation implementation with a
 * one-cycle clear of every physical row. Hardware instances leave it zero so
 * the array remains an UltraRAM without array-wide reset logic.
 */
module sdp_packed_tag_uram #(
    parameter int unsigned ADDR_WIDTH         = 16,
    parameter int unsigned DATA_WIDTH         = 13,
    parameter int unsigned READ_LATENCY       = 3,
    parameter int unsigned SUPPORT_BULK_CLEAR = 0
) (
    input logic i_clk,

    input logic                  i_write_enable,
    input logic                  i_bulk_clear,
    input logic [ADDR_WIDTH-1:0] i_write_address,
    input logic [DATA_WIDTH-1:0] i_write_data,

    input  logic                  i_read_enable,
    input  logic [ADDR_WIDTH-1:0] i_read_address,
    output logic [DATA_WIDTH-1:0] o_read_data
);

  initial begin
    if (ADDR_WIDTH < 1) $fatal(1, "sdp_packed_tag_uram: ADDR_WIDTH must be >= 1");
    if ((DATA_WIDTH < 1) || (DATA_WIDTH > 72))
      $fatal(1, "sdp_packed_tag_uram: DATA_WIDTH must be in [1, 72]");
    if (READ_LATENCY < 2) $fatal(1, "sdp_packed_tag_uram: READ_LATENCY must be >= 2");
  end

  localparam int unsigned PhysicalRowWidth = 72;
  localparam int unsigned WriteGranuleWidth = 9;
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
  localparam int unsigned LaneSelectWidth = (LaneBits == 0) ? 1 : LaneBits;
  localparam int unsigned SlotsPerRow = 2 ** LaneBits;
  localparam int unsigned SlotWidth = GranulesPerSlot * WriteGranuleWidth;
  localparam int unsigned PhysicalAddrBits = ADDR_WIDTH - LaneBits;
  localparam int unsigned PhysicalAddrWidth = (PhysicalAddrBits == 0) ? 1 : PhysicalAddrBits;
  localparam int unsigned PhysicalDepth = 2 ** PhysicalAddrBits;
  localparam int unsigned XpmReadLatency = READ_LATENCY - 1;

  logic [LaneSelectWidth-1:0] write_lane;
  logic [LaneSelectWidth-1:0] read_lane;
  if (LaneBits == 0) begin : gen_single_lane_address
    assign write_lane = '0;
    assign read_lane  = '0;
  end else begin : gen_multi_lane_address
    assign write_lane = i_write_address[LaneBits-1:0];
    assign read_lane  = i_read_address[LaneBits-1:0];
  end

  logic [PhysicalAddrWidth-1:0] write_row_address;
  logic [PhysicalAddrWidth-1:0] read_row_address;
  assign write_row_address = PhysicalAddrWidth'(i_write_address >> LaneBits);
  assign read_row_address  = PhysicalAddrWidth'(i_read_address >> LaneBits);

  logic [PhysicalRowWidth-1:0] physical_write_data;
  logic [PhysicalRowWidth/WriteGranuleWidth-1:0] physical_write_enable;
  always_comb begin
    physical_write_data   = '0;
    physical_write_enable = '0;
    for (int unsigned lane = 0; lane < SlotsPerRow; lane++) begin
      // Replicate the logical payload into every slot; only the 9-bit write
      // enables select a destination. This keeps a 72-bit address-controlled
      // barrel mux off the URAM data input.
      physical_write_data[lane*SlotWidth+:DATA_WIDTH] = i_write_data;
      if (int'(write_lane) == lane) begin
        physical_write_enable[lane*GranulesPerSlot+:GranulesPerSlot] =
            {GranulesPerSlot{i_write_enable}};
      end
    end
  end

  logic [PhysicalRowWidth-1:0] row_dout;

`ifdef FROST_XILINX_PRIMS
`ifdef FROST_VIVADO_SYNTH
`ifndef YOSYS
  `define FROST_PACKED_TAG_USE_XPM
`endif
`endif
`endif

  // Bulk clear is a simulation acceleration. Selecting it elaborates a
  // portable array on purpose, keeping clear loops out of the hardware XPM.
  if (SUPPORT_BULK_CLEAR != 0) begin : gen_clearable_storage
    (* ram_style = "ultra" *)logic [PhysicalRowWidth-1:0] memory [ PhysicalDepth];
    logic [PhysicalRowWidth-1:0] rd_pipe[XpmReadLatency];

    always_ff @(posedge i_clk) begin
      if (i_bulk_clear) for (int unsigned row = 0; row < PhysicalDepth; row++) memory[row] <= '0;
      else
        for (int unsigned granule = 0; granule < PhysicalRowWidth / WriteGranuleWidth; granule++)
        if (physical_write_enable[granule])
          memory[write_row_address][granule*WriteGranuleWidth+:WriteGranuleWidth] <=
                physical_write_data[granule*WriteGranuleWidth+:WriteGranuleWidth];
    end

    always_ff @(posedge i_clk) begin
      if (i_read_enable) rd_pipe[0] <= memory[read_row_address];
      for (int unsigned stage = 1; stage < XpmReadLatency; stage++)
      rd_pipe[stage] <= rd_pipe[stage-1];
    end
    assign row_dout = rd_pipe[XpmReadLatency-1];
  end else begin : gen_hardware_storage
`ifdef FROST_PACKED_TAG_USE_XPM
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(PhysicalAddrWidth),
        .ADDR_WIDTH_B(PhysicalAddrWidth),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(WriteGranuleWidth),
        .CASCADE_HEIGHT(0),
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
        .doutb         (row_dout),
        .dbiterrb      (),
        .sbiterrb      (),
        .clka          (i_clk),
        .clkb          (i_clk),
        .ena           (|physical_write_enable),
        .wea           (physical_write_enable),
        .addra         (write_row_address),
        .dina          (physical_write_data),
        // The caller qualifies responses independently. Keeping the physical
        // read port enabled removes the logical request-valid cone from every
        // URAM in a depth cascade without changing the sampled address or
        // READ_LATENCY contract.
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

    for (
        genvar granule = 0; granule < PhysicalRowWidth / WriteGranuleWidth; granule++
    ) begin : gen_write_granule
      always_ff @(posedge i_clk)
        if (physical_write_enable[granule])
          memory[write_row_address][granule*WriteGranuleWidth+:WriteGranuleWidth] <=
              physical_write_data[granule*WriteGranuleWidth+:WriteGranuleWidth];
    end

    always_ff @(posedge i_clk) begin
      if (i_read_enable) rd_pipe[0] <= memory[read_row_address];
      for (int unsigned stage = 1; stage < XpmReadLatency; stage++)
      rd_pipe[stage] <= rd_pipe[stage-1];
    end
    assign row_dout = rd_pipe[XpmReadLatency-1];
`endif
  end

`ifdef FROST_PACKED_TAG_USE_XPM
  `undef FROST_PACKED_TAG_USE_XPM
`endif

  // Pipeline the lane beside the row read. The final registered select is the
  // last cycle counted by READ_LATENCY and holds across gaps in i_read_enable.
  logic [LaneSelectWidth-1:0] read_lane_pipe[XpmReadLatency];
  logic read_valid_pipe[XpmReadLatency];
  always_ff @(posedge i_clk) begin
    read_valid_pipe[0] <= i_read_enable;
    if (i_read_enable) read_lane_pipe[0] <= read_lane;
    for (int unsigned stage = 1; stage < XpmReadLatency; stage++) begin
      read_valid_pipe[stage] <= read_valid_pipe[stage-1];
      read_lane_pipe[stage]  <= read_lane_pipe[stage-1];
    end
  end

  always_ff @(posedge i_clk)
    if (read_valid_pipe[XpmReadLatency-1])
      o_read_data <= row_dout[int'(read_lane_pipe[XpmReadLatency-1])*SlotWidth+:DATA_WIDTH];

endmodule : sdp_packed_tag_uram
