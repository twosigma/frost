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
 * Simple-dual-port RAM with byte-write enables, a pipelined read, and a
 * selectable memory primitive ("block" BRAM or "ultra" UltraRAM). Access is
 * row-granular, with no word packing: one access is one full row. This backs
 * the frost_cache data arrays. L1 uses MEMORY_PRIMITIVE="block" and L2 uses
 * "ultra"; a cache line is exactly one row, 256 bits in the L1s and 512 in
 * the L2.
 *
 * Storage has three implementations behind synthesis-tool defines, with the
 * same external behaviour and latency so that simulation matches hardware:
 *   - FROST_XILINX_PRIMS + FROST_VIVADO_SYNTH: xpm_memory_sdpram with
 *     MEMORY_PRIMITIVE passed through; the XPM pipelines deep cascades
 *     internally to meet READ_LATENCY_B.
 *   - FROST_SRAM_MACROS (the ASIC flow): frost_sram_1w1r (asic/sram), SRAM
 *     macros or flip-flops, whose registered read is the first read stage.
 *     It reads undefined data in the cycle after array_re is low, which
 *     frost_cache never uses.
 *   - else (Yosys, Verilator): behavioral memory with a matching read pipeline.
 *
 * Both read forms have READ_LATENCY cycles from i_re to o_rdata:
 *   - REGISTER_READ_INPUT=1 registers the request, then samples the array one
 *     cycle later. With WRITE_LATENCY=1, it sees a write presented with i_re.
 *   - REGISTER_READ_INPUT=0 reads continuously. When the memory's share of
 *     the latency (READ_LATENCY less a REGISTER_READ_OUTPUT register) is 2 or
 *     more, it includes the array output register (BRAM DOB_REG); at 1 the
 *     array's own read latch drives the output, for a caller that registers
 *     the data itself. Same-edge writes return old data. The caller must avoid
 *     qualified reads of a row being written; frost_cache never issues one
 *     (see its data array). i_re only qualifies the collision check, so
 *     changing o_rdata is valid only READ_LATENCY cycles after a request.
 * REGISTER_READ_OUTPUT=1 spends one of the READ_LATENCY cycles on a fabric
 * register after the memory. Synthesis keeps it out of the memory (KEEP), so
 * placement can hold the memory's last stage beside a wide array and put this
 * register near the readers.
 * Writes are byte writes with WRITE_LATENCY-1 input-register stages (1 =
 * single-cycle write). There is no power-up init: contents are don't-care
 * until written, and the cache's tag sweep makes them unreachable.
 */
module sdp_ram_byte_en #(
    parameter int unsigned DATA_WIDTH = 256,  // bits per row (multiple of 8)
    parameter int unsigned ADDR_WIDTH = 12,  // row-address bits
    parameter int unsigned READ_LATENCY = 2,  // total cycles i_re->o_rdata (see the check)
    parameter int unsigned WRITE_LATENCY = 1,  // total cycles i_w*->array updated (>= 1)
    // Untyped because Vivado fails to resolve a string-typed parameter
    // propagated into xpm_memory_sdpram's MEMORY_PRIMITIVE.
    // verilog_lint: waive-start explicit-parameter-storage-type
    parameter MEMORY_PRIMITIVE = "block",  // "block" | "ultra" | "auto"
    // verilog_lint: waive-end explicit-parameter-storage-type
    // 1 = register i_re/i_raddr at the boundary; 0 = present i_raddr to the
    // array directly (see the header).
    parameter bit REGISTER_READ_INPUT = 1'b1,
    // 1 = register o_rdata in the fabric after the memory, as one of the
    // READ_LATENCY cycles (see the header).
    parameter bit REGISTER_READ_OUTPUT = 1'b0
) (
    input logic i_clk,

    // Write port (port A): byte-granular, row-addressed.
    input logic [  ADDR_WIDTH-1:0] i_waddr,
    input logic [  DATA_WIDTH-1:0] i_wdata,
    input logic [DATA_WIDTH/8-1:0] i_wbyte_en,

    // Read port (port B): row-addressed. Data appears READ_LATENCY cycles after i_re.
    input  logic                  i_re,
    input  logic [ADDR_WIDTH-1:0] i_raddr,
    output logic [DATA_WIDTH-1:0] o_rdata
);

  initial begin
    if (DATA_WIDTH % 8 != 0) $fatal(1, "sdp_ram_byte_en: DATA_WIDTH must be a multiple of 8");
    if (READ_LATENCY < 1 + (REGISTER_READ_INPUT ? 1 : 0) + (REGISTER_READ_OUTPUT ? 1 : 0))
      $fatal(1, "sdp_ram_byte_en: READ_LATENCY must leave the memory at least one cycle");
    if (WRITE_LATENCY < 1) $fatal(1, "sdp_ram_byte_en: WRITE_LATENCY must be >= 1");
  end

  localparam int unsigned NumBytes = DATA_WIDTH / 8;
  localparam int unsigned Depth = 2 ** ADDR_WIDTH;
  // The cycles spent in the memory read pipeline: the total less the
  // registers at the boundary.
  localparam int unsigned XpmReadLatency =
      READ_LATENCY - (REGISTER_READ_INPUT ? 1 : 0) - (REGISTER_READ_OUTPUT ? 1 : 0);

  // ---- Write-port input register pipeline (WRITE_LATENCY-1 stages) ---------
  localparam int unsigned WriteRegStages = WRITE_LATENCY - 1;
  logic [ADDR_WIDTH-1:0] waddr_q;
  logic [DATA_WIDTH-1:0] wdata_q;
  logic [  NumBytes-1:0] wbyte_en_q;
  if (WriteRegStages == 0) begin : gen_write_comb
    assign waddr_q    = i_waddr;
    assign wdata_q    = i_wdata;
    assign wbyte_en_q = i_wbyte_en;
  end else begin : gen_write_pipe
    logic [ADDR_WIDTH-1:0] waddr_pipe   [WriteRegStages];
    logic [DATA_WIDTH-1:0] wdata_pipe   [WriteRegStages];
    logic [  NumBytes-1:0] wbyte_en_pipe[WriteRegStages];
    always_ff @(posedge i_clk) begin
      waddr_pipe[0]    <= i_waddr;
      wdata_pipe[0]    <= i_wdata;
      wbyte_en_pipe[0] <= i_wbyte_en;
      for (int unsigned k = 1; k < WriteRegStages; k++) begin
        waddr_pipe[k]    <= waddr_pipe[k-1];
        wdata_pipe[k]    <= wdata_pipe[k-1];
        wbyte_en_pipe[k] <= wbyte_en_pipe[k-1];
      end
    end
    assign waddr_q    = waddr_pipe[WriteRegStages-1];
    assign wdata_q    = wdata_pipe[WriteRegStages-1];
    assign wbyte_en_q = wbyte_en_pipe[WriteRegStages-1];
  end

  // A row is written on this edge. The XPM's port enable stays high (see
  // u_xpm_ram), so only the collision check at the end of the module uses it.
  logic row_write_en;
  assign row_write_en = |wbyte_en_q;

  // ---- Read-port input register --------------------------------------------
  // Optional input registration for timing; direct reads run continuously.
  logic                  array_re;
  logic [ADDR_WIDTH-1:0] array_raddr;
  if (REGISTER_READ_INPUT) begin : gen_read_input_reg
    logic                  re_in_reg;
    logic [ADDR_WIDTH-1:0] raddr_reg;
    always_ff @(posedge i_clk) begin
      re_in_reg <= i_re;
      raddr_reg <= i_raddr;
    end
    assign array_re    = re_in_reg;
    assign array_raddr = raddr_reg;
  end else begin : gen_read_input_direct
    assign array_re    = 1'b1;
    assign array_raddr = i_raddr;
  end

  // ---- Storage: DATA_WIDTH x Depth, byte-write, deep read pipeline ---------
  logic [DATA_WIDTH-1:0] row_dout;  // valid XpmReadLatency cycles after array_re

`ifdef FROST_XILINX_PRIMS
`ifdef FROST_VIVADO_SYNTH
`ifndef YOSYS
  `define FROST_SDP_RAM_USE_XPM
`endif
`endif
`endif

`ifdef FROST_SDP_RAM_USE_XPM
  xpm_memory_sdpram #(
      .ADDR_WIDTH_A(ADDR_WIDTH),
      .ADDR_WIDTH_B(ADDR_WIDTH),
      .AUTO_SLEEP_TIME(0),
      .BYTE_WRITE_WIDTH_A(8),
      .CASCADE_HEIGHT(0),  // 0 = let Vivado choose the cascade height
      .CLOCKING_MODE("common_clock"),
      .ECC_MODE("no_ecc"),
      .MEMORY_INIT_FILE("none"),
      .MEMORY_INIT_PARAM("0"),
      .MEMORY_OPTIMIZATION("true"),
      .MEMORY_PRIMITIVE(MEMORY_PRIMITIVE),
      .MEMORY_SIZE(DATA_WIDTH * Depth),  // total bits
      .MESSAGE_CONTROL(0),
      .READ_DATA_WIDTH_B(DATA_WIDTH),
      .READ_LATENCY_B(XpmReadLatency),
      .READ_RESET_VALUE_B("0"),
      .RST_MODE_A("SYNC"),
      .RST_MODE_B("SYNC"),
      .SIM_ASSERT_CHK(0),
      .USE_EMBEDDED_CONSTRAINT(0),
      .USE_MEM_INIT(0),
      .WAKEUP_TIME("disable_sleep"),
      .WRITE_DATA_WIDTH_A(DATA_WIDTH),
      // Same-edge reads return old data. frost_cache must avoid qualified
      // reads of a row being written, including all input pipeline stages.
      .WRITE_MODE_B("read_first"),
      .WRITE_PROTECT(1)
  ) u_xpm_ram (
      .doutb         (row_dout),
      .dbiterrb      (),
      .sbiterrb      (),
      .clka          (i_clk),
      .clkb          (i_clk),
      // With ena high, the byte enables alone gate writes.
      .ena           (1'b1),
      .wea           (wbyte_en_q),
      .addra         (waddr_q),
      .dina          (wdata_q),
      .enb           (array_re),
      .addrb         (array_raddr),
      .regceb        (1'b1),
      .rstb          (1'b0),
      .sleep         (1'b0),
      .injectsbiterra(1'b0),
      .injectdbiterra(1'b0)
  );
`elsif FROST_SRAM_MACROS
  // The memory's registered read is the first of the XPM latency's stages.
  logic [DATA_WIDTH-1:0] memory_read_data;
  frost_sram_1w1r #(
      .ADDR_WIDTH  (ADDR_WIDTH),
      .DATA_WIDTH  (DATA_WIDTH),
      .MASK_GRANULE(8)
  ) u_sram (
      .i_write_clock(i_clk),
      .i_bulk_clear(1'b0),
      .i_write_mask(wbyte_en_q),
      .i_write_address(waddr_q),
      .i_write_data(wdata_q),
      .i_read_clock(i_clk),
      .i_read_enable(array_re),
      .i_read_address(array_raddr),
      .o_read_data(memory_read_data)
  );
  if (XpmReadLatency == 1) begin : gen_sram_read
    assign row_dout = memory_read_data;
  end else begin : gen_sram_read_pipe
    logic [DATA_WIDTH-1:0] rd_pipe[XpmReadLatency-1];
    always_ff @(posedge i_clk) begin
      rd_pipe[0] <= memory_read_data;
      for (int unsigned k = 1; k < XpmReadLatency - 1; k++) rd_pipe[k] <= rd_pipe[k-1];
    end
    assign row_dout = rd_pipe[XpmReadLatency-2];
  end
`else
  // Match the XPM latency. Separate branches give each array its ram_style;
  // without the ultra hint, Yosys attempts to decompose large arrays into BRAM.
  if (MEMORY_PRIMITIVE == "ultra") begin : gen_ultra_storage
    (* ram_style = "ultra" *) logic [DATA_WIDTH-1:0] memory[Depth];

`ifdef FROST_RANDOM_START
    initial begin
      for (int row = 0; row < Depth; row++)
      for (int chunk = 0; chunk < (DATA_WIDTH + 31) / 32; chunk++)
      memory[row] = (memory[row] << 32) | DATA_WIDTH'($urandom);
    end
`endif
    for (genvar byte_index = 0; byte_index < int'(NumBytes); byte_index++) begin : gen_write_byte
      always_ff @(posedge i_clk)
        if (wbyte_en_q[byte_index])
          memory[waddr_q][byte_index*8+:8] <= wdata_q[byte_index*8+:8];
    end
    logic [DATA_WIDTH-1:0] rd_pipe[XpmReadLatency];
    always_ff @(posedge i_clk) begin
      if (array_re) rd_pipe[0] <= memory[array_raddr];
      for (int unsigned k = 1; k < XpmReadLatency; k++) rd_pipe[k] <= rd_pipe[k-1];
    end
    assign row_dout = rd_pipe[XpmReadLatency-1];
  end else begin : gen_block_storage
    (* ram_style = "block" *) logic [DATA_WIDTH-1:0] memory[Depth];

`ifdef FROST_RANDOM_START
    initial begin
      for (int row = 0; row < Depth; row++)
      for (int chunk = 0; chunk < (DATA_WIDTH + 31) / 32; chunk++)
      memory[row] = (memory[row] << 32) | DATA_WIDTH'($urandom);
    end
`endif
    for (genvar byte_index = 0; byte_index < int'(NumBytes); byte_index++) begin : gen_write_byte
      always_ff @(posedge i_clk)
        if (wbyte_en_q[byte_index])
          memory[waddr_q][byte_index*8+:8] <= wdata_q[byte_index*8+:8];
    end
    logic [DATA_WIDTH-1:0] rd_pipe[XpmReadLatency];
    always_ff @(posedge i_clk) begin
      if (array_re) rd_pipe[0] <= memory[array_raddr];
      for (int unsigned k = 1; k < XpmReadLatency; k++) rd_pipe[k] <= rd_pipe[k-1];
    end
    assign row_dout = rd_pipe[XpmReadLatency-1];
  end
`endif
`ifdef FROST_SDP_RAM_USE_XPM
  `undef FROST_SDP_RAM_USE_XPM
`endif

  // ---- Read-port output register -------------------------------------------
  // Optional fabric stage after the memory (see the header).
  if (REGISTER_READ_OUTPUT) begin : gen_read_output_reg
    (* keep = "true" *) logic [DATA_WIDTH-1:0] rdata_q;
    always_ff @(posedge i_clk) rdata_q <= row_dout;
    assign o_rdata = rdata_q;
  end else begin : gen_read_output_direct
    assign o_rdata = row_dout;
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // Reject qualified reads that collide with a write at the array edge.
  // Such a read would return the old row.
  logic                  check_re;
  logic [ADDR_WIDTH-1:0] check_raddr;
  if (REGISTER_READ_INPUT) begin : gen_check_registered
    assign check_re    = array_re;
    assign check_raddr = array_raddr;
  end else begin : gen_check_direct
    assign check_re    = i_re;
    assign check_raddr = i_raddr;
  end
  always @(posedge i_clk) begin
    if (check_re && row_write_en && (check_raddr == waddr_q)) begin
      $error("sdp_ram_byte_en: row %0d read and written at the same edge", check_raddr);
    end
  end
`endif
`endif

endmodule : sdp_ram_byte_en
