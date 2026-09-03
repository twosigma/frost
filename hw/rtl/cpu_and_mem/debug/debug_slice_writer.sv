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
 * Debug slice writer (Phase 3 M3). The low BRAM's instruction copy is written
 * only through the div4-clock programming port (the JTAG loader's), so this
 * block is how the debug module lands words in its execution slice and how
 * a debugger's stores into BRAM code become fetchable: core-domain requests
 * cross into the div4 domain through the repo's phase-locked dc_fifo and a
 * small engine drives the programming port when the loader is idle.
 *
 * Two request kinds:
 *   WRITE  {word address, data}: the word goes to both copies exactly like a
 *          loader write (the debug module's park / abstract / progbuf words).
 *   MIRROR {word address}: the data copy already holds the word (a store in
 *          Debug Mode landed it); read it back through the data copy's port
 *          A and write it into the instruction copy only. Never write the
 *          data copy from a mirror: a younger store could already have
 *          changed the word and a stale write-back would revert it. Reading
 *          the whole word also makes partial stores (a halfword c.ebreak
 *          breakpoint) exact.
 *
 * Completion: every request eventually increments a div4-domain done
 * counter, Gray-coded across to the core domain; the request counter and
 * the synchronized done counter agree exactly when no write is outstanding
 * (o_all_done). The increment is delayed past imem_predecode's registered
 * port-A stage so "done" means "visible to the fetch port". Requests are
 * accepted only while o_req_ready. cpu_and_mem arbitrates the debug module,
 * which can wait, against the store snoop, which cannot: a refused snoop
 * push becomes a sticky command error there.
 */
module debug_slice_writer #(
    parameter int unsigned MEM_BYTE_ADDR_WIDTH = 18,
    parameter int unsigned DEPTH = 32
) (
    // Core domain
    input  logic                           i_clk,
    input  logic                           i_rst,
    input  logic                           i_req_valid,
    input  logic                           i_req_mirror,
    input  logic [MEM_BYTE_ADDR_WIDTH-1:2] i_req_word_addr,
    input  logic [                   31:0] i_req_data,
    output logic                           o_req_ready,
    output logic                           o_all_done,

    // div4 domain: the programming-port face (the loader wins the port;
    // i_port_busy stalls the engine while it does)
    input  logic        i_clk_div4,
    input  logic        i_rst_div4,
    input  logic        i_port_busy,
    output logic [31:0] o_port_a_byte_addr,
    output logic [31:0] o_port_a_data,
    output logic        o_imem_we,           // instruction copy word write
    output logic        o_dmem_we,           // data copy word write (WRITE kind only)
    input  logic [63:0] i_dmem_rd_data       // data copy port-A read data (dword row)
);

  localparam int unsigned WordAddrBits = MEM_BYTE_ADDR_WIDTH - 2;
  localparam int unsigned ReqBits = 1 + WordAddrBits + 32;
  localparam int unsigned CountBits = 8;

  // ---------------------------------------------------------------------------
  // Core domain: request FIFO push + request counter
  // ---------------------------------------------------------------------------
  logic fifo_ready;
  logic push;
  assign push = i_req_valid && fifo_ready;
  assign o_req_ready = fifo_ready;

  logic [CountBits-1:0] req_count_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) req_count_q <= '0;
    else if (push) req_count_q <= req_count_q + 1'b1;
  end

  logic [ReqBits-1:0] fifo_out;
  logic fifo_out_valid, fifo_pop;
  dc_fifo #(
      .DATA_WIDTH(ReqBits),
      .DEPTH(DEPTH),
      .READY_MARGIN(1)
  ) u_req_fifo (
      .i_clk  (i_clk),
      .i_rst  (i_rst),
      .i_data ({i_req_mirror, i_req_word_addr, i_req_data}),
      .i_valid(i_req_valid),
      .o_ready(fifo_ready),
      .o_clk  (i_clk_div4),
      .o_rst  (i_rst_div4),
      .o_data (fifo_out),
      .o_valid(fifo_out_valid),
      .i_ready(fifo_pop)
  );

  // ---------------------------------------------------------------------------
  // div4 domain: engine
  // ---------------------------------------------------------------------------
  logic req_mirror;
  logic [WordAddrBits-1:0] req_word_addr;
  logic [31:0] req_data;
  assign {req_mirror, req_word_addr, req_data} = fifo_out;

  typedef enum logic [1:0] {
    Idle,
    MirrorRead,  // data-copy port A presents the row; data lands next cycle
    MirrorWrite  // write the read-back word into the instruction copy
  } state_e;
  state_e state_q;

  logic [31:0] req_byte_addr;
  assign req_byte_addr = 32'(req_word_addr) << 2;

  // The programming port is driven for exactly one cycle per WRITE, and
  // one read cycle plus one write cycle per MIRROR. dc_fifo's registered RAM
  // read lags its read pointer by one cycle (see its header), so o_data is
  // only trustworthy two cycles after the pointer last moved: after the load
  // that raised o_valid, and after every pop. pop_ok enforces both: o_valid
  // must already have been high last cycle and no pop may have fired last
  // cycle.
  logic pop_q, valid_q, pop_ok;
  always_ff @(posedge i_clk_div4) begin
    if (i_rst_div4) begin
      pop_q   <= 1'b0;
      valid_q <= 1'b0;
    end else begin
      pop_q   <= fifo_pop;
      valid_q <= fifo_out_valid;
    end
  end
  assign pop_ok = fifo_out_valid && valid_q && !pop_q;
  logic write_fire;
  logic imem_write;
  always_comb begin
    fifo_pop = 1'b0;
    imem_write = 1'b0;
    o_dmem_we = 1'b0;
    o_port_a_byte_addr = req_byte_addr;
    o_port_a_data = req_data;
    unique case (state_q)
      Idle: begin
        if (pop_ok && !i_port_busy) begin
          if (req_mirror) begin
            // Present the read address; the data copy's registered port-A
            // read returns the row in MirrorWrite.
          end else begin
            imem_write = 1'b1;
            o_dmem_we  = 1'b1;
            fifo_pop   = 1'b1;
          end
        end
      end
      MirrorRead: begin
        // The row is read at this address; it lands in the data copy's port-A
        // register on the next edge. Nothing to drive.
      end
      MirrorWrite: begin
        if (!i_port_busy) begin
          o_port_a_data = req_word_addr[0] ? i_dmem_rd_data[63:32] : i_dmem_rd_data[31:0];
          imem_write    = 1'b1;
          fifo_pop      = 1'b1;
        end
      end
      default: ;
    endcase
  end
  assign o_imem_we  = imem_write;
  assign write_fire = imem_write;

  always_ff @(posedge i_clk_div4) begin
    if (i_rst_div4) begin
      state_q <= Idle;
    end else begin
      unique case (state_q)
        Idle: if (pop_ok && !i_port_busy && req_mirror) state_q <= MirrorRead;
        // The loader owning the port in either mirror cycle restarts the
        // read (the row register then holds the loader's row).
        MirrorRead: if (!i_port_busy) state_q <= MirrorWrite;
        MirrorWrite: state_q <= i_port_busy ? MirrorRead : Idle;
        default: state_q <= Idle;
      endcase
    end
  end

  // Done counter: a write presented in cycle n is registered by
  // imem_predecode's port-A stage at n+1 and lands in its arrays at n+2, so
  // count it two cycles later. Gray-coded across to the core domain.
  logic [1:0] write_delay_q;
  logic [CountBits-1:0] done_count_q;
  always_ff @(posedge i_clk_div4) begin
    if (i_rst_div4) begin
      write_delay_q <= 2'b00;
      done_count_q  <= '0;
    end else begin
      write_delay_q <= {write_delay_q[0], write_fire};
      if (write_delay_q[1]) done_count_q <= done_count_q + 1'b1;
    end
  end
  logic [CountBits-1:0] done_gray_div4;
  assign done_gray_div4 = done_count_q ^ (done_count_q >> 1);

  (* ASYNC_REG = "TRUE" *)logic [CountBits-1:0] done_gray_sync1;
  (* ASYNC_REG = "TRUE" *)logic [CountBits-1:0] done_gray_sync2;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      done_gray_sync1 <= '0;
      done_gray_sync2 <= '0;
    end else begin
      done_gray_sync1 <= done_gray_div4;
      done_gray_sync2 <= done_gray_sync1;
    end
  end
  logic [CountBits-1:0] done_count_core;
  always_comb begin
    done_count_core[CountBits-1] = done_gray_sync2[CountBits-1];
    for (int i = CountBits - 2; i >= 0; i--) begin
      done_count_core[i] = done_count_core[i+1] ^ done_gray_sync2[i];
    end
  end
  assign o_all_done = (req_count_q == done_count_core);

`ifndef SYNTHESIS
  // The counters may never run more than DEPTH + engine depth apart.
  always_ff @(posedge i_clk) begin
    if (!i_rst && ((req_count_q - done_count_core) > CountBits'(DEPTH + 4)))
      $error("debug_slice_writer: request/done counters diverged");
  end
`endif

endmodule : debug_slice_writer
