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
 * "ultra"; a 32-byte cache line is exactly one 256-bit row.
 *
 * Storage has two implementations behind synthesis-tool defines, with the same
 * external behaviour and latency so that simulation matches hardware:
 *   - FROST_XILINX_PRIMS + FROST_VIVADO_SYNTH: xpm_memory_sdpram with
 *     MEMORY_PRIMITIVE passed through; the XPM pipelines deep cascades
 *     internally to meet READ_LATENCY_B.
 *   - else (Yosys, Verilator): behavioral memory with a matching read pipeline.
 *
 * The read path has one of two forms with the same total i_re->o_rdata
 * latency, READ_LATENCY:
 *   - REGISTER_READ_INPUT=1: i_re/i_raddr are registered once at the module
 *     boundary and then spend READ_LATENCY-1 cycles in the memory read
 *     pipeline. A read samples the array one cycle after i_re, so it sees a
 *     write presented in the i_re cycle.
 *   - REGISTER_READ_INPUT=0: i_raddr goes straight to the array, which reads
 *     every cycle, and READ_LATENCY counts the array's own output register
 *     (block RAM: DOB_REG), so o_rdata comes from a register instead of the
 *     RAM's slower unregistered output. A read samples the array in the i_re
 *     cycle and does not see a write presented in that cycle (read-first), so
 *     the user must not read a row in the cycle it is written; frost_cache's
 *     raw_hazard stall guarantees this. i_re qualifies nothing here and is
 *     used only by the collision check. o_rdata changes every cycle, so it is
 *     valid only READ_LATENCY cycles after a read.
 * Writes are byte writes with WRITE_LATENCY-1 input-register stages (1 =
 * single-cycle write). There is no power-up init: contents are don't-care
 * until written, and the cache's tag sweep makes them unreachable.
 */
module sdp_ram_byte_en #(
    parameter int unsigned DATA_WIDTH = 256,  // bits per row (multiple of 8)
    parameter int unsigned ADDR_WIDTH = 12,  // row-address bits
    parameter int unsigned READ_LATENCY = 2,  // total cycles i_re->o_rdata (>= 2)
    parameter int unsigned WRITE_LATENCY = 1,  // total cycles i_w*->array updated (>= 1)
    // Untyped because Vivado fails to resolve a string-typed parameter
    // propagated into xpm_memory_sdpram's MEMORY_PRIMITIVE.
    // verilog_lint: waive-start explicit-parameter-storage-type
    parameter MEMORY_PRIMITIVE = "block",  // "block" | "ultra" | "auto"
    // verilog_lint: waive-end explicit-parameter-storage-type
    // 1 = register i_re/i_raddr at the boundary; 0 = present i_raddr to the
    // array directly and count its output register (see the header).
    parameter bit REGISTER_READ_INPUT = 1'b1
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
    if (READ_LATENCY < 2) $fatal(1, "sdp_ram_byte_en: READ_LATENCY must be >= 2");
    if (WRITE_LATENCY < 1) $fatal(1, "sdp_ram_byte_en: WRITE_LATENCY must be >= 1");
  end

  localparam int unsigned NumBytes = DATA_WIDTH / 8;
  localparam int unsigned Depth = 2 ** ADDR_WIDTH;
  // The cycles spent in the memory read pipeline: one fewer than the total
  // when the read inputs are registered at the boundary.
  localparam int unsigned XpmReadLatency = REGISTER_READ_INPUT ? READ_LATENCY - 1 : READ_LATENCY;

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
  // Ends the request cone at a register before the memory and lets the tool
  // replicate it across the wide array.
  // The array's read enable and address: the boundary registers, or the
  // inputs themselves with the enable held high.
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
      // read_first: a read of a row written at the same edge returns the old
      // data, as in the portable model below. frost_cache never has the
      // memory read and write one row at the same edge (after the read-input
      // register and the write stages), at either write latency; the
      // simulation check at the end of the module flags it.
      .WRITE_MODE_B("read_first"),
      .WRITE_PROTECT(1)
  ) u_xpm_ram (
      .doutb         (row_dout),
      .dbiterrb      (),
      .sbiterrb      (),
      .clka          (i_clk),
      .clkb          (i_clk),
      // The byte enables alone gate the write: the XPM writes byte k when
      // ena && wea[k], and ena would be |wea. Tied high, the enable carries
      // no OR-reduction of the byte enables to the head of every cascade in
      // a wide array.
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
`else
  // Portable equivalent: a single-cycle byte write and an XpmReadLatency-stage
  // read pipeline, with the same external latency as the XPM. The storage sits
  // in per-primitive generate branches so the ram_style hint matches
  // MEMORY_PRIMITIVE. Without that hint, Yosys spends unbounded time
  // decomposing a multi-MiB array toward block RAM on UltraScale+.
  if (MEMORY_PRIMITIVE == "ultra") begin : gen_ultra_storage
    (* ram_style = "ultra" *) logic [DATA_WIDTH-1:0] memory[Depth];
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

  assign o_rdata = row_dout;

`ifndef SYNTHESIS
`ifndef FORMAL
  // The write mode never decides a read's data: the memory is never asked to
  // read and write one row at the same edge (see WRITE_MODE_B).
  // A read and a write of one row at the same array edge: the read returns
  // the old row.
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
