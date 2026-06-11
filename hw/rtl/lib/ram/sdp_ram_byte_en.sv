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
 * selectable memory primitive ("block" BRAM or "ultra" UltraRAM). Row-granular
 * sibling of sdp_uram_byte_en (no word packing: one access = one full row).
 * Backs the frost_cache data arrays -- L1 uses MEMORY_PRIMITIVE="block",
 * L2 uses "ultra"; a 32-byte cache line is exactly one 256-bit row.
 *
 * STORAGE -- two implementations behind synthesis-tool defines, with IDENTICAL
 * external behaviour and latency so simulation matches hardware (same scheme
 * as sdp_uram_byte_en):
 *   - FROST_XILINX_PRIMS + FROST_VIVADO_SYNTH: xpm_memory_sdpram with
 *     MEMORY_PRIMITIVE passed through; the XPM pipelines deep cascades
 *     internally to meet READ_LATENCY_B.
 *   - else (Yosys, Verilator): behavioral memory with a matching read pipeline.
 *
 * READ path: i_re/i_raddr are registered once at the module boundary, then
 * READ_LATENCY-1 cycles through the memory read pipeline; total i_re->o_rdata
 * latency = READ_LATENCY. WRITE path: byte writes with WRITE_LATENCY-1
 * input-register stages (1 = single-cycle write). No power-up init: contents
 * are don't-care until written (the cache's tag sweep makes them unreachable).
 */
module sdp_ram_byte_en #(
    parameter int unsigned DATA_WIDTH       = 256,     // bits per row (multiple of 8)
    parameter int unsigned ADDR_WIDTH       = 12,      // row-address bits
    parameter int unsigned READ_LATENCY     = 2,       // total cycles i_re->o_rdata (>= 2)
    parameter int unsigned WRITE_LATENCY    = 1,       // total cycles i_w*->array updated (>= 1)
    // Untyped on purpose: Vivado fails to resolve a string-typed parameter
    // propagated into xpm_memory_sdpram's MEMORY_PRIMITIVE.
    // verilog_lint: waive-start explicit-parameter-storage-type
    parameter              MEMORY_PRIMITIVE = "block"  // "block" | "ultra" | "auto"
    // verilog_lint: waive-end explicit-parameter-storage-type
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
  localparam int unsigned XpmReadLatency = READ_LATENCY - 1;  // 1 cycle = read-input reg

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

  logic row_write_en;
  assign row_write_en = |wbyte_en_q;

  // ---- Read-port input register --------------------------------------------
  // Ends the request cone at a register before the memory and lets the tool
  // replicate it across the wide array (same discipline as sdp_uram_byte_en).
  logic                  re_in_reg;
  logic [ADDR_WIDTH-1:0] raddr_reg;
  always_ff @(posedge i_clk) begin
    re_in_reg <= i_re;
    raddr_reg <= i_raddr;
  end

  // ---- Storage: DATA_WIDTH x Depth, byte-write, deep read pipeline ---------
  logic [DATA_WIDTH-1:0] row_dout;  // valid XpmReadLatency cycles after re_in_reg

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
      .WRITE_MODE_B("read_first"),  // never read+write the same row in a cycle
      .WRITE_PROTECT(1)
  ) u_xpm_ram (
      .doutb         (row_dout),
      .dbiterrb      (),
      .sbiterrb      (),
      .clka          (i_clk),
      .clkb          (i_clk),
      .ena           (row_write_en),
      .wea           (wbyte_en_q),
      .addra         (waddr_q),
      .dina          (wdata_q),
      .enb           (re_in_reg),
      .addrb         (raddr_reg),
      .regceb        (1'b1),
      .rstb          (1'b0),
      .sleep         (1'b0),
      .injectsbiterra(1'b0),
      .injectdbiterra(1'b0)
  );
`else
  // Portable equivalent -- single-cycle byte write + XpmReadLatency-stage read
  // pipeline. Same external latency as the XPM. The storage is declared in
  // per-primitive generate branches so the ram_style hint matches
  // MEMORY_PRIMITIVE (without it, Yosys spends unbounded time decomposing a
  // multi-MiB array toward block RAM on UltraScale+).
  if (MEMORY_PRIMITIVE == "ultra") begin : gen_ultra_storage
    (* ram_style = "ultra" *) logic [DATA_WIDTH-1:0] memory[Depth];
    for (genvar byte_index = 0; byte_index < int'(NumBytes); byte_index++) begin : gen_write_byte
      always_ff @(posedge i_clk)
        if (wbyte_en_q[byte_index])
          memory[waddr_q][byte_index*8+:8] <= wdata_q[byte_index*8+:8];
    end
    logic [DATA_WIDTH-1:0] rd_pipe[XpmReadLatency];
    always_ff @(posedge i_clk) begin
      if (re_in_reg) rd_pipe[0] <= memory[raddr_reg];
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
      if (re_in_reg) rd_pipe[0] <= memory[raddr_reg];
      for (int unsigned k = 1; k < XpmReadLatency; k++) rd_pipe[k] <= rd_pipe[k-1];
    end
    assign row_dout = rd_pipe[XpmReadLatency-1];
  end
`endif
`ifdef FROST_SDP_RAM_USE_XPM
  `undef FROST_SDP_RAM_USE_XPM
`endif

  assign o_rdata = row_dout;

endmodule : sdp_ram_byte_en
