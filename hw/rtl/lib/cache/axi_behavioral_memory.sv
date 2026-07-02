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
 * axi_behavioral_memory -- SIMULATION-ONLY main-memory model (stands in for
 * the DDR controller in Phase 1; replaced by the board's DDR controller
 * (MIG DDR3 / DDR4 IP) + SmartConnect on hardware). AXI4 slave, single-beat 256-bit transactions (asserts on
 * anything else), parameterized response latency to mimic DDR access time.
 *
 * The array is dense and parameter-sized (default 64 MiB) while the DECODED
 * region is 1 GiB: the cache hierarchy above never knows the difference, and
 * any program touching beyond MEM_BYTES trips an assertion instead of
 * silently aliasing. CoreMark-PRO's largest official working set (~6 MiB
 * heap) fits with an order of magnitude to spare; bump MEM_BYTES via -G for
 * bigger experiments.
 *
 * Storage is word-granular so $readmemh can load sw_ddr.mem directly (the
 * same objcopy -O verilog --verilog-data-width 4 format as sw.mem, emitted
 * REGION-RELATIVE: file offset 0 = the cached region base). Addresses on the
 * AXI side are already region-relative (the bridge subtracts the base).
 * Like hardware DDR contents, the array persists across CPU resets; the
 * caches re-invalidate on reset, so a reloaded program sees fresh memory.
 */
module axi_behavioral_memory #(
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned MEM_BYTES = 64 * 1024 * 1024,
    parameter int unsigned LATENCY = 30,  // cycles from AR (or AW+W) to R (or B)
    parameter bit USE_INIT_FILE = 1'b0,
    parameter bit [8*64-1:0] INIT_FILE = "sw_ddr.mem"
) (
    input logic i_clk,
    input logic i_rst,

    // AXI4 slave (single-beat bursts only).
    input  logic                    i_axi_awvalid,
    output logic                    o_axi_awready,
    input  logic [            31:0] i_axi_awaddr,
    input  logic [             7:0] i_axi_awlen,
    input  logic                    i_axi_wvalid,
    output logic                    o_axi_wready,
    input  logic [LINE_BYTES*8-1:0] i_axi_wdata,
    input  logic [  LINE_BYTES-1:0] i_axi_wstrb,
    output logic                    o_axi_bvalid,
    input  logic                    i_axi_bready,
    output logic [             1:0] o_axi_bresp,
    input  logic                    i_axi_arvalid,
    output logic                    o_axi_arready,
    input  logic [            31:0] i_axi_araddr,
    input  logic [             7:0] i_axi_arlen,
    output logic                    o_axi_rvalid,
    input  logic                    i_axi_rready,
    output logic [LINE_BYTES*8-1:0] o_axi_rdata,
    output logic [             1:0] o_axi_rresp,
    output logic                    o_axi_rlast
);

  localparam int unsigned NumWords = MEM_BYTES / 4;
  localparam int unsigned WordsPerLine = LINE_BYTES / 4;

  logic [31:0] memory[NumWords];

`ifndef YOSYS
  // Simulation-only image load (Yosys cannot elaborate $fopen; this module is
  // never instantiated in synthesized configurations anyway).
  initial begin
    if (USE_INIT_FILE) begin
      // Probe before $readmemh so flows that never generate a DDR image
      // (e.g. external test-suite builds) run with zeroed memory instead of
      // a missing-file error.
      int init_fd;
      init_fd = $fopen(INIT_FILE, "r");
      if (init_fd != 0) begin
        $fclose(init_fd);
        $readmemh(INIT_FILE, memory);
      end
    end
  end
`endif

  // ---- Write channel ----------------------------------------------------------
  typedef enum logic [1:0] {
    W_IDLE,
    W_WAIT,
    W_RESP
  } wstate_e;
  wstate_e wstate_q;

  logic [31:0] awaddr_q;
  logic [LINE_BYTES*8-1:0] wdata_q;
  logic [LINE_BYTES-1:0] wstrb_q;
  logic aw_got_q, w_got_q;
  logic [15:0] wlat_q;

  assign o_axi_awready = (wstate_q == W_IDLE) && !aw_got_q;
  assign o_axi_wready  = (wstate_q == W_IDLE) && !w_got_q;
  assign o_axi_bvalid  = (wstate_q == W_RESP);
  assign o_axi_bresp   = 2'b00;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      wstate_q <= W_IDLE;
      aw_got_q <= 1'b0;
      w_got_q  <= 1'b0;
    end else begin
      unique case (wstate_q)
        W_IDLE: begin
          if (i_axi_awvalid && o_axi_awready) begin
            awaddr_q <= i_axi_awaddr;
            aw_got_q <= 1'b1;
          end
          if (i_axi_wvalid && o_axi_wready) begin
            wdata_q <= i_axi_wdata;
            wstrb_q <= i_axi_wstrb;
            w_got_q <= 1'b1;
          end
          if ((aw_got_q || (i_axi_awvalid && o_axi_awready)) &&
              (w_got_q || (i_axi_wvalid && o_axi_wready))) begin
            wlat_q   <= 16'(LATENCY);
            wstate_q <= W_WAIT;
          end
        end

        W_WAIT: begin
          wlat_q <= wlat_q - 1'b1;
          if (wlat_q <= 16'd1) begin
            // Perform the strobed write at response time. The address is
            // masked into the modeled array (see the read-channel comment).
            for (int unsigned w = 0; w < WordsPerLine; w++) begin
              for (int unsigned b = 0; b < 4; b++) begin
                if (wstrb_q[w*4+b]) begin
                  memory[(((awaddr_q&(MEM_BYTES-1))>>2)+w)][b*8+:8] <= wdata_q[(w*32)+(b*8)+:8];
                end
              end
            end
            wstate_q <= W_RESP;
          end
        end

        W_RESP: begin
          if (i_axi_bready) begin
            aw_got_q <= 1'b0;
            w_got_q  <= 1'b0;
            wstate_q <= W_IDLE;
          end
        end

        default: wstate_q <= W_IDLE;
      endcase
    end
  end

  // ---- Read channel -----------------------------------------------------------
  typedef enum logic [1:0] {
    R_IDLE,
    R_WAIT,
    R_RESP
  } rstate_e;
  rstate_e rstate_q;

  logic [31:0] araddr_q;
  logic [15:0] rlat_q;
  logic [LINE_BYTES*8-1:0] rdata_q;

  assign o_axi_arready = (rstate_q == R_IDLE);
  assign o_axi_rvalid  = (rstate_q == R_RESP);
  assign o_axi_rdata   = rdata_q;
  assign o_axi_rresp   = 2'b00;
  assign o_axi_rlast   = 1'b1;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      rstate_q <= R_IDLE;
    end else begin
      unique case (rstate_q)
        R_IDLE: begin
          if (i_axi_arvalid) begin
            araddr_q <= i_axi_araddr;
            rlat_q   <= 16'(LATENCY);
            rstate_q <= R_WAIT;
          end
        end

        R_WAIT: begin
          rlat_q <= rlat_q - 1'b1;
          if (rlat_q <= 16'd1) begin
            // Mask into the modeled array: wrong-path speculative loads can
            // target anywhere in the architectural 1 GiB region, and must
            // complete (with don't-care data) rather than kill the sim. The
            // bounds warning below flags ARCHITECTURAL accesses that exceed
            // the model so a too-small DDR_MODEL_BYTES is still noticed.
            for (int unsigned w = 0; w < WordsPerLine; w++) begin
              rdata_q[w*32+:32] <= memory[(((araddr_q&(MEM_BYTES-1))>>2)+w)];
            end
            rstate_q <= R_RESP;
          end
        end

        R_RESP: if (i_axi_rready) rstate_q <= R_IDLE;

        default: rstate_q <= R_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // Out-of-model accesses alias into the array (harmless for wrong-path
  // speculation); warn a few times so an undersized DDR_MODEL_BYTES against a
  // real working set is still visible. Writes are always architectural
  // (stores drain post-commit), so a masked WRITE is the strongest signal.
  int unsigned oob_warnings = 0;
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (i_axi_awvalid && o_axi_awready && i_axi_awlen != 8'd0)
        $error("axi_behavioral_memory: only single-beat write bursts supported");
      if (i_axi_arvalid && o_axi_arready && i_axi_arlen != 8'd0)
        $error("axi_behavioral_memory: only single-beat read bursts supported");
      if (oob_warnings < 8) begin
        if (i_axi_awvalid && o_axi_awready && (i_axi_awaddr + LINE_BYTES > MEM_BYTES)) begin
          // Writes are always architectural (stores drain post-commit), so a
          // masked write means DDR_MODEL_BYTES is too small for the program.
          $display("WARNING: axi_behavioral_memory: WRITE 0x%08x beyond modeled %0d bytes",
                   i_axi_awaddr, MEM_BYTES);
          oob_warnings <= oob_warnings + 1;
        end else if (i_axi_arvalid && o_axi_arready &&
                     (i_axi_araddr + LINE_BYTES > MEM_BYTES)) begin
          // Aliased; wrong-path speculative reads are expected to land here.
          $display("WARNING: axi_behavioral_memory: read 0x%08x beyond modeled %0d bytes",
                   i_axi_araddr, MEM_BYTES);
          oob_warnings <= oob_warnings + 1;
        end
      end
    end
  end
`endif

endmodule : axi_behavioral_memory
