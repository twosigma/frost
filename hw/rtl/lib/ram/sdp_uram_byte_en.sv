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
 * Simple-dual-port UltraRAM scratchpad with byte-write enables and a deep,
 * pipelined read. Backs the FROST "URAM tier" -- the large high-address region
 * (default base 0x0100_0000) where CoreMark-PRO working sets live, behind the
 * load queue's single-outstanding latency path.
 *
 * WORD PACKING: WORDS_PER_ROW DATA_WIDTH words share one URAM row so 32-bit data
 * fills the 72-bit URAM efficiently (8 MiB = 256 URAM blocks, not 512). The low
 * log2(WORDS_PER_ROW) word-address bits select the word within the row; the
 * upper bits index the row. The addressed word is muxed out of the row read.
 *
 * STORAGE -- two implementations behind synthesis-tool defines, with IDENTICAL
 * external behaviour and latency so simulation matches hardware:
 *   - FROST_XILINX_PRIMS + FROST_VIVADO_SYNTH (Vivado synthesis):
 *     xpm_memory_sdpram with
 *     MEMORY_PRIMITIVE="ultra". The XPM pipelines the URAM cascade INTERNALLY to
 *     meet READ_LATENCY_B -- registering the CAS_OUT_DOUT hops. (An inferred
 *     output-register pipeline is NOT folded into the URAM cascade by Vivado --
 *     verified across latency/retiming/shreg_extract sweeps -- so the XPM macro
 *     is required to actually pipeline a deep cascade.)
 *   - else (Yosys, Verilator, generic synthesis): a behavioral 256-bit memory
 *     with a matching read pipeline. Same i_re->o_rdata latency, so sim == synth.
 *
 * READ path (XPM port B): the read enable + address are registered once at the
 * module boundary (keeps the request/AMO decode cone and the wide-array fanout
 * off the URAM), then READ_LATENCY-1 cycles through the memory read pipeline;
 * total i_re->o_rdata latency = READ_LATENCY (matches the router's valid pipe).
 * WRITE path (XPM port A): byte writes with WRITE_LATENCY-1 input-register
 * stages (mirrors the read path). WRITE_LATENCY=1 is the legacy single-cycle
 * write; WRITE_LATENCY=2 registers i_waddr/i_wdata/i_wbyte_en at the boundary so
 * the SQ/router write-control cone ends at a register next to the URAM and the
 * tool replicates it across the wide block array. The extra write cycle is
 * matched by the router holding the URAM store-done (URAM_WRITE_LATENCY-1) cycles,
 * so no store->load ordering hazard is introduced.
 *
 * URAM specifics: single synchronous clock; no power-up INIT (powers up zero,
 * filled by a boot-copy loader on hardware; sim may $readmemh when USE_INIT_FILE).
 */
module sdp_uram_byte_en #(
    parameter int unsigned DATA_WIDTH = 32,  // bits (multiple of 8)
    parameter int unsigned ADDR_WIDTH = 21,  // word-addr bits; 2^21 * 4B = 8 MiB
    parameter int unsigned READ_LATENCY = 18,  // total cycles i_re->o_rdata (>= 2)
    parameter int unsigned WRITE_LATENCY = 1,  // total cycles i_w*->array updated (>=1; 2 = reg)
    parameter int unsigned WORDS_PER_ROW = 2,  // words packed per URAM row (pow2, >=2)
    parameter bit USE_INIT_FILE = 1'b0,  // sim only; hardware uses boot-copy
    parameter bit [8*64-1:0] INIT_FILE = "sw_uram.mem"
) (
    input logic i_clk,

    // Write port (port A): runtime stores / boot-copy, byte-granular, word-addressed.
    input logic [  ADDR_WIDTH-1:0] i_waddr,
    input logic [  DATA_WIDTH-1:0] i_wdata,
    input logic [DATA_WIDTH/8-1:0] i_wbyte_en,

    // Read port (port B): word-addressed. Data appears READ_LATENCY cycles after i_re.
    input  logic                  i_re,
    input  logic [ADDR_WIDTH-1:0] i_raddr,
    output logic [DATA_WIDTH-1:0] o_rdata
);

  initial begin
    if (DATA_WIDTH % 8 != 0) $fatal(1, "sdp_uram_byte_en: DATA_WIDTH must be a multiple of 8");
    if (READ_LATENCY < 2) $fatal(1, "sdp_uram_byte_en: READ_LATENCY must be >= 2");
    if (WRITE_LATENCY < 1) $fatal(1, "sdp_uram_byte_en: WRITE_LATENCY must be >= 1");
    if (WORDS_PER_ROW < 2 || (WORDS_PER_ROW & (WORDS_PER_ROW - 1)) != 0)
      $fatal(1, "sdp_uram_byte_en: WORDS_PER_ROW must be a power of 2 >= 2");
    if (ADDR_WIDTH <= $clog2(WORDS_PER_ROW))
      $fatal(1, "sdp_uram_byte_en: ADDR_WIDTH must exceed log2(WORDS_PER_ROW)");
  end

  localparam int unsigned NumBytes = DATA_WIDTH / 8;
  localparam int unsigned WordSelBits = $clog2(WORDS_PER_ROW);
  localparam int unsigned RowWidth = WORDS_PER_ROW * DATA_WIDTH;  // bits per URAM row
  localparam int unsigned RowBytes = RowWidth / 8;
  localparam int unsigned RowAddrWidth = ADDR_WIDTH - WordSelBits;
  localparam int unsigned RowDepth = 2 ** RowAddrWidth;
  localparam int unsigned XpmReadLatency = READ_LATENCY - 1;  // 1 cycle = read-input reg

  // ---- Write-port input register pipeline (WRITE_LATENCY-1 stages) ---------
  // Mirrors the read-port input register: ends the SQ/router write-control cone
  // at a register next to the URAM and lets the tool replicate it across the
  // wide block array. The extra store latency is matched by the router holding
  // the URAM store-done, so store->load forwarding stays correct.
  localparam int unsigned WriteRegStages = WRITE_LATENCY - 1;
  logic [  ADDR_WIDTH-1:0] waddr_q;
  logic [  DATA_WIDTH-1:0] wdata_q;
  logic [DATA_WIDTH/8-1:0] wbyte_en_q;
  if (WriteRegStages == 0) begin : gen_write_comb
    assign waddr_q    = i_waddr;
    assign wdata_q    = i_wdata;
    assign wbyte_en_q = i_wbyte_en;
  end else begin : gen_write_pipe
    logic [  ADDR_WIDTH-1:0] waddr_pipe   [WriteRegStages];
    logic [  DATA_WIDTH-1:0] wdata_pipe   [WriteRegStages];
    logic [DATA_WIDTH/8-1:0] wbyte_en_pipe[WriteRegStages];
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

  // ---- Address split + byte-write enables (combinational) -----------------
  logic [RowAddrWidth-1:0] write_row_addr, read_row_addr;
  logic [WordSelBits-1:0] write_word_sel, read_word_sel;
  assign write_row_addr = waddr_q[ADDR_WIDTH-1:WordSelBits];
  assign write_word_sel = waddr_q[WordSelBits-1:0];
  assign read_row_addr  = i_raddr[ADDR_WIDTH-1:WordSelBits];
  assign read_word_sel  = i_raddr[WordSelBits-1:0];

  // Byte-write enables steered to the addressed word's lanes; data replicated to
  // every word slot (the enables pick which bytes actually update).
  logic [RowBytes-1:0] row_byte_en;
  logic [RowWidth-1:0] row_wdata;
  logic                row_write_en;
  always_comb begin
    row_byte_en = '0;
    row_byte_en[write_word_sel*NumBytes+:NumBytes] = wbyte_en_q;
    row_wdata = {WORDS_PER_ROW{wdata_q}};
  end
  assign row_write_en = |wbyte_en_q;

  // ---- Read-port input register + word-select alignment pipeline ----------
  // Registering the read enable/address here ends the (AMO-muxed) request cone
  // at a register before the memory and lets the tool replicate it across the
  // wide block array. word_sel is pipelined the full READ_LATENCY so it aligns
  // with the row read data at the output mux.
  logic                    re_in_reg;
  logic [RowAddrWidth-1:0] read_row_addr_reg;
  logic [ WordSelBits-1:0] word_sel_pipe     [READ_LATENCY];
  always_ff @(posedge i_clk) begin
    re_in_reg         <= i_re;
    read_row_addr_reg <= read_row_addr;
    word_sel_pipe[0]  <= read_word_sel;
    for (int unsigned k = 1; k < READ_LATENCY; k++) word_sel_pipe[k] <= word_sel_pipe[k-1];
  end

  // ---- Storage: RowWidth x RowDepth, byte-write, deep read pipeline -------
  logic [RowWidth-1:0] row_dout;  // valid XpmReadLatency cycles after re_in_reg

`ifdef FROST_XILINX_PRIMS
`ifdef FROST_VIVADO_SYNTH
`ifndef YOSYS
  `define FROST_SDP_URAM_USE_XPM
`endif
`endif
`endif

`ifdef FROST_SDP_URAM_USE_XPM
  // Hardware: XPM UltraRAM. The macro pipelines the cascade internally to hit
  // READ_LATENCY_B (registers the CAS_OUT_DOUT hops), which inference would not.
  xpm_memory_sdpram #(
      .ADDR_WIDTH_A(RowAddrWidth),
      .ADDR_WIDTH_B(RowAddrWidth),
      .AUTO_SLEEP_TIME(0),
      .BYTE_WRITE_WIDTH_A(8),
      .CASCADE_HEIGHT(0),  // 0 = let Vivado choose the cascade height
      .CLOCKING_MODE("common_clock"),  // single clock (clka drives both ports)
      .ECC_MODE("no_ecc"),
      .MEMORY_INIT_FILE("none"),  // URAM powers up zero; heap needs no init
      .MEMORY_INIT_PARAM("0"),
      .MEMORY_OPTIMIZATION("true"),
      .MEMORY_PRIMITIVE("ultra"),
      .MEMORY_SIZE(RowWidth * RowDepth),  // total bits
      .MESSAGE_CONTROL(0),
      .READ_DATA_WIDTH_B(RowWidth),
      .READ_LATENCY_B(XpmReadLatency),  // cascade-pipelined read latency
      .READ_RESET_VALUE_B("0"),
      .RST_MODE_A("SYNC"),
      .RST_MODE_B("SYNC"),
      .SIM_ASSERT_CHK(0),
      .USE_EMBEDDED_CONSTRAINT(0),
      .USE_MEM_INIT(0),
      .WAKEUP_TIME("disable_sleep"),
      .WRITE_DATA_WIDTH_A(RowWidth),
      .WRITE_MODE_B("read_first"),  // ultra SDP requires read_first/write_first (not no_change);
                                    // we never read+write the same address in a cycle, so it is moot
      .WRITE_PROTECT(1)
  ) u_xpm_uram (
      .doutb         (row_dout),
      .dbiterrb      (),
      .sbiterrb      (),
      .clka          (i_clk),
      .clkb          (i_clk),
      .ena           (row_write_en),       // port A write enable
      .wea           (row_byte_en),        // port A byte-write enables
      .addra         (write_row_addr),
      .dina          (row_wdata),
      .enb           (re_in_reg),          // port B read enable (registered)
      .addrb         (read_row_addr_reg),  // port B read address (registered)
      .regceb        (1'b1),
      .rstb          (1'b0),
      .sleep         (1'b0),
      .injectsbiterra(1'b0),
      .injectdbiterra(1'b0)
  );
`else
  // Portable equivalent -- single-cycle byte write + XpmReadLatency-stage read
  // pipeline. Same external latency as the XPM.
  (* ram_style = "ultra" *) logic [RowWidth-1:0] memory[RowDepth];
  initial if (USE_INIT_FILE) $readmemh(INIT_FILE, memory);

  for (genvar byte_index = 0; byte_index < RowBytes; byte_index++) begin : gen_write_byte
    always_ff @(posedge i_clk)
      if (row_byte_en[byte_index])
        memory[write_row_addr][byte_index*8+:8] <= row_wdata[byte_index*8+:8];
  end

  logic [RowWidth-1:0] rd_pipe[XpmReadLatency];
  always_ff @(posedge i_clk) begin
    if (re_in_reg) rd_pipe[0] <= memory[read_row_addr_reg];
    for (int unsigned k = 1; k < XpmReadLatency; k++) rd_pipe[k] <= rd_pipe[k-1];
  end
  assign row_dout = rd_pipe[XpmReadLatency-1];
`endif
`ifdef FROST_SDP_URAM_USE_XPM
  `undef FROST_SDP_URAM_USE_XPM
`endif

  // ---- Word mux: select the addressed word from the row read (latency-aligned)
  assign o_rdata = row_dout[word_sel_pipe[READ_LATENCY-1]*DATA_WIDTH+:DATA_WIDTH];

endmodule : sdp_uram_byte_en
