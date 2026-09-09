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
 * dma_test_engine: a small DMA master on the cache hierarchy's coherent DMA
 * port, driven from memory-mapped registers. It is the second agent the
 * coherence litmus tests need (a device that reads and writes cached DDR
 * behind the CPU's caches) and the reference for the behaviour the NIC's ring
 * engine must reproduce: data writes complete before the status write, and
 * the interrupt follows the status write's completion.
 *
 * Registers (32-bit, word stride; the CPU sees them as a strongly ordered
 * device window, see hw/rtl/README.md "Memory Map"):
 *
 *   0x00 CTRL    W: bit 0 START (ignored while busy), bit 2 ABORT (ignored
 *                while idle)
 *                R: bit 0 BUSY, bit 1 DONE, bit 2 ERROR, bit 3 IRQ pending
 *   0x04 ACK     W: any value clears DONE, ERROR and the interrupt
 *   0x08 SRC     source byte address (copy modes)
 *   0x0C DST     destination byte address
 *   0x10 LEN     transfer length in bytes (0 performs no data transfer)
 *   0x14 MODE    bit 0: 0 = copy SRC to DST, 1 = fill DST;
 *                bit 1: write STATUS_VALUE to STATUS_ADDR after the data;
 *                bit 2: raise the interrupt on completion
 *   0x18 PATTERN fill mode writes PATTERN + i to the i-th dword of the
 *                transfer (i counts from DST's dword), so a reader can check
 *                the order in which values become visible
 *   0x1C STATUS_ADDR  32-bit-aligned address of the status word
 *   0x20 STATUS_VALUE the status word
 *   0x24 LINES   R: line operations completed in the current/last transfer
 *
 * A transfer walks DST line by line. Copy mode reads the matching SRC line
 * first (SRC and DST must share their offset within a line), fill mode
 * generates the data; the DST write carries strobes for the bytes inside
 * [DST, DST+LEN). One line is in flight at a time, so the engine's traffic is
 * strictly ordered: every data write has completed (the port's response,
 * which is the shared level's completion) before the status write is
 * issued, and the status write has completed before DONE and the interrupt
 * are raised. That is the completion-ordering contract the driver-facing
 * NIC engine must keep.
 *
 * Aperture: SRC, DST and STATUS_ADDR must fall inside the cached region
 * [APERTURE_BASE, APERTURE_BASE + APERTURE_BYTES) and a transfer must not
 * wrap out of it; otherwise START sets ERROR and moves nothing (and raises
 * no interrupt). START copies every transfer register into the active
 * transfer, so writes while BUSY program the next transfer only. ABORT
 * issues nothing further (no data line, no status write), waits for the
 * outstanding response, then reports ERROR without DONE and raises the
 * interrupt if the transfer enabled it; requests already accepted are never
 * cancelled, so the caller must not reuse the buffers until BUSY falls. An
 * ABORT that lands in the cycle the transfer completes has no effect (the
 * transfer reports DONE): an abort can always race a completion.
 * Reset (the CPU's reset) does the same
 * implicitly: the engine issues nothing in reset, and a response to a
 * request accepted before reset is dropped.
 */
module dma_test_engine #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned ID_BITS = 3,
    parameter logic [31:0] APERTURE_BASE = 32'h8000_0000,
    parameter logic [31:0] APERTURE_BYTES = 32'h4000_0000
) (
    input logic i_clk,
    input logic i_rst,

    // Register interface: 32-bit lane writes and a dword read pair, the
    // same shape the PLIC uses. i_wr_offset / i_rd_offset are byte offsets
    // within the window (bit 2 selects the word of a dword).
    input  logic        i_wr_en,
    input  logic [ 5:0] i_wr_offset,
    input  logic [31:0] i_wr_data,
    input  logic [ 5:0] i_rd_offset,
    output logic [63:0] o_rd_pair,
    output logic        o_irq,

    // DMA line port (master).
    output logic                    o_dma_req_valid,
    input  logic                    i_dma_req_ready,
    output logic                    o_dma_req_write,
    output logic [  ADDR_WIDTH-1:0] o_dma_req_addr,
    output logic [LINE_BYTES*8-1:0] o_dma_req_wdata,
    output logic [  LINE_BYTES-1:0] o_dma_req_wstrb,
    output logic [     ID_BITS-1:0] o_dma_req_id,
    input  logic                    i_dma_resp_valid,
    input  logic [     ID_BITS-1:0] i_dma_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_dma_resp_rdata
);
  localparam int unsigned LineBits = LINE_BYTES * 8;
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  logic [31:0] src_q, dst_q, len_q, mode_q, pattern_q, status_addr_q, status_value_q;
  logic [31:0] lines_q;
  logic busy_q, done_q, error_q, irq_q;

  logic wr_ctrl, wr_ack;
  assign wr_ctrl = i_wr_en && (i_wr_offset[5:2] == 4'h0);
  assign wr_ack  = i_wr_en && (i_wr_offset[5:2] == 4'h1);
  logic start_req, abort_req;
  assign start_req = wr_ctrl && i_wr_data[0] && !busy_q;
  assign abort_req = wr_ctrl && i_wr_data[2];

  logic [31:0] ctrl_rd;
  assign ctrl_rd = {28'b0, irq_q, error_q, done_q, busy_q};
  always_comb begin
    unique case (i_rd_offset[5:3])
      3'd0: o_rd_pair = {32'b0, ctrl_rd};
      3'd1: o_rd_pair = {dst_q, src_q};
      3'd2: o_rd_pair = {mode_q, len_q};
      3'd3: o_rd_pair = {status_addr_q, pattern_q};
      3'd4: o_rd_pair = {lines_q, status_value_q};
      default: o_rd_pair = '0;
    endcase
  end
  assign o_irq = irq_q;

  // ---------------------------------------------------------------------------
  // Transfer state
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE,
    S_READ,         // copy: present the SRC line read
    S_READ_WAIT,    // copy: wait for the line
    S_WRITE,        // present the DST line write
    S_WRITE_WAIT,   // wait for its completion
    S_STATUS,       // present the status word write
    S_STATUS_WAIT,
    S_FINISH        // raise DONE/IRQ (or ERROR after an abort)
  } state_e;
  state_e state_q;

  logic [31:0] cur_line_q;  // DST byte address of the line being worked (line-aligned)
  logic [31:0] end_addr_q;  // DST + LEN (exclusive)
  logic [31:0] src_line_q;  // SRC line address matching cur_line_q
  logic [31:0] dword_idx_q;  // index of the line's first dword within the transfer
  logic [LineBits-1:0] line_data_q;
  logic abort_pending_q;
  // The active transfer's copy of the programming registers, taken at START.
  logic [31:0] a_dst_q, a_pattern_q, a_status_addr_q, a_status_value_q;
  logic a_fill_q, a_status_q, a_irq_q;
  logic mode_fill, mode_status;
  assign mode_fill   = mode_q[0];
  assign mode_status = mode_q[1];

  // Aperture and alignment checks evaluated at START.
  logic src_ok, dst_ok, status_ok, layout_ok;
  logic [32:0] dst_end;
  assign dst_end = {1'b0, dst_q} + {1'b0, len_q};
  function automatic logic in_aperture(input logic [31:0] a);
    in_aperture = (a >= APERTURE_BASE) && (a < (APERTURE_BASE + APERTURE_BYTES));
  endfunction
  assign dst_ok = in_aperture(dst_q) && (dst_end <= (33'(APERTURE_BASE) + 33'(APERTURE_BYTES)));
  assign src_ok = mode_fill || (in_aperture(
      src_q
  ) && (({1'b0, src_q} + {1'b0, len_q}) <= (33'(APERTURE_BASE) + 33'(APERTURE_BYTES))) &&
      (src_q[OffsetBits-1:0] == dst_q[OffsetBits-1:0]));
  assign status_ok = !mode_status || (in_aperture(status_addr_q) && (status_addr_q[1:0] == 2'b00));
  assign layout_ok = dst_ok && src_ok && status_ok;

  // Strobes for the current line: bytes b with cur_line + b in [DST, END).
  logic [LINE_BYTES-1:0] line_strb;
  always_comb begin
    for (int b = 0; b < int'(LINE_BYTES); b++) begin
      logic [31:0] byte_addr;
      byte_addr = cur_line_q + 32'(b);
      line_strb[b] = (byte_addr >= a_dst_q) && (byte_addr < end_addr_q);
    end
  end

  // Fill data: PATTERN + i for the i-th dword of the transfer, counted from
  // DST's dword (lane dst_q[OffsetBits-1:2] of the first line is dword 0).
  logic [LineBits-1:0] fill_data;
  always_comb begin
    for (int d = 0; d < int'(LINE_BYTES / 4); d++) begin
      fill_data[d*32+:32] = a_pattern_q + dword_idx_q + 32'(d) - 32'(a_dst_q[OffsetBits-1:2]);
    end
  end

  // Status word positioned in its dword lane with a 4-byte strobe.
  logic [  LineBits-1:0] status_data;
  logic [LINE_BYTES-1:0] status_strb;
  always_comb begin
    status_data = '0;
    status_strb = '0;
    for (int d = 0; d < int'(LINE_BYTES / 4); d++) begin
      if (a_status_addr_q[OffsetBits-1:2] == 3'(d)) begin
        status_data[d*32+:32] = a_status_value_q;
        status_strb[d*4+:4]   = 4'hF;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Port drive
  // ---------------------------------------------------------------------------
  // An abort taken before a request fires withholds it (the state machine
  // then finishes without issuing it).
  always_comb begin
    o_dma_req_valid = 1'b0;
    o_dma_req_write = 1'b0;
    o_dma_req_addr  = cur_line_q;
    o_dma_req_wdata = a_fill_q ? fill_data : line_data_q;
    o_dma_req_wstrb = line_strb;
    o_dma_req_id    = '0;
    unique case (state_q)
      S_READ: begin
        o_dma_req_valid = !abort_pending_q;
        o_dma_req_addr  = src_line_q;
        o_dma_req_id    = ID_BITS'(1);
      end
      S_WRITE: begin
        o_dma_req_valid = !abort_pending_q;
        o_dma_req_write = 1'b1;
        o_dma_req_id    = ID_BITS'(2);
      end
      S_STATUS: begin
        o_dma_req_valid = !abort_pending_q;
        o_dma_req_write = 1'b1;
        o_dma_req_addr  = {a_status_addr_q[31:OffsetBits], {OffsetBits{1'b0}}};
        o_dma_req_wdata = status_data;
        o_dma_req_wstrb = status_strb;
        o_dma_req_id    = ID_BITS'(3);
      end
      default: ;
    endcase
  end
  logic req_fire;
  assign req_fire = o_dma_req_valid && i_dma_req_ready;

  logic more_lines;
  assign more_lines = (cur_line_q + LINE_BYTES) < end_addr_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q         <= S_IDLE;
      busy_q          <= 1'b0;
      done_q          <= 1'b0;
      error_q         <= 1'b0;
      irq_q           <= 1'b0;
      abort_pending_q <= 1'b0;
      lines_q         <= '0;
      src_q           <= '0;
      dst_q           <= '0;
      len_q           <= '0;
      mode_q          <= '0;
      pattern_q       <= '0;
      status_addr_q   <= '0;
      status_value_q  <= '0;
    end else begin
      // Register writes: START copies them into the active transfer, so a
      // write during a transfer affects only the next one.
      if (i_wr_en) begin
        unique case (i_wr_offset[5:2])
          4'h2: src_q <= i_wr_data;
          4'h3: dst_q <= i_wr_data;
          4'h4: len_q <= i_wr_data;
          4'h5: mode_q <= i_wr_data;
          4'h6: pattern_q <= i_wr_data;
          4'h7: status_addr_q <= i_wr_data;
          4'h8: status_value_q <= i_wr_data;
          default: ;
        endcase
      end
      if (wr_ack) begin
        done_q  <= 1'b0;
        error_q <= 1'b0;
        irq_q   <= 1'b0;
      end
      if (abort_req && busy_q) abort_pending_q <= 1'b1;

      unique case (state_q)
        S_IDLE: begin
          if (start_req) begin
            busy_q           <= 1'b1;
            done_q           <= 1'b0;
            error_q          <= 1'b0;
            abort_pending_q  <= 1'b0;
            lines_q          <= '0;
            cur_line_q       <= {dst_q[31:OffsetBits], {OffsetBits{1'b0}}};
            src_line_q       <= {src_q[31:OffsetBits], {OffsetBits{1'b0}}};
            end_addr_q       <= dst_end[31:0];
            dword_idx_q      <= '0;
            a_dst_q          <= dst_q;
            a_pattern_q      <= pattern_q;
            a_status_addr_q  <= status_addr_q;
            a_status_value_q <= status_value_q;
            a_fill_q         <= mode_fill;
            a_status_q       <= mode_status;
            a_irq_q          <= mode_q[2];
            if (!layout_ok) begin
              error_q <= 1'b1;
              busy_q  <= 1'b0;
            end else if (len_q == 32'd0) begin
              state_q <= mode_status ? S_STATUS : S_FINISH;
            end else begin
              state_q <= mode_fill ? S_WRITE : S_READ;
            end
          end
        end
        // Every issuing state checks the abort before firing (the request is
        // withheld above), so an abort landing in any wait state or on a
        // response edge ends the transfer at the next boundary with nothing
        // else issued.
        S_READ: begin
          if (abort_pending_q) state_q <= S_FINISH;
          else if (req_fire) state_q <= S_READ_WAIT;
        end
        S_READ_WAIT: begin
          if (i_dma_resp_valid) begin
            line_data_q <= i_dma_resp_rdata;
            state_q     <= abort_pending_q ? S_FINISH : S_WRITE;
          end
        end
        S_WRITE: begin
          if (abort_pending_q) state_q <= S_FINISH;
          else if (req_fire) state_q <= S_WRITE_WAIT;
        end
        S_WRITE_WAIT: begin
          if (i_dma_resp_valid) begin
            lines_q <= lines_q + 1'b1;
            if (abort_pending_q) begin
              state_q <= S_FINISH;
            end else if (more_lines) begin
              cur_line_q  <= cur_line_q + LINE_BYTES;
              src_line_q  <= src_line_q + LINE_BYTES;
              dword_idx_q <= dword_idx_q + 32'(LINE_BYTES / 4);
              state_q     <= a_fill_q ? S_WRITE : S_READ;
            end else begin
              state_q <= a_status_q ? S_STATUS : S_FINISH;
            end
          end
        end
        S_STATUS: begin
          if (abort_pending_q) state_q <= S_FINISH;
          else if (req_fire) state_q <= S_STATUS_WAIT;
        end
        S_STATUS_WAIT: if (i_dma_resp_valid) state_q <= S_FINISH;
        S_FINISH: begin
          busy_q          <= 1'b0;
          done_q          <= !abort_pending_q;
          error_q         <= abort_pending_q;
          irq_q           <= a_irq_q;
          state_q         <= S_IDLE;
          abort_pending_q <= 1'b0;  // an abort written this cycle came too late
        end
        default:       state_q <= S_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (!i_rst && i_dma_resp_valid) begin
      if (!((state_q == S_READ_WAIT) || (state_q == S_WRITE_WAIT) || (state_q == S_STATUS_WAIT)))
        $error("dma_test_engine: response with nothing outstanding");
      if ((state_q == S_READ_WAIT) && (i_dma_resp_id != ID_BITS'(1)))
        $error("dma_test_engine: read response carries id %0d", i_dma_resp_id);
      if ((state_q == S_WRITE_WAIT) && (i_dma_resp_id != ID_BITS'(2)))
        $error("dma_test_engine: write response carries id %0d", i_dma_resp_id);
      if ((state_q == S_STATUS_WAIT) && (i_dma_resp_id != ID_BITS'(3)))
        $error("dma_test_engine: status response carries id %0d", i_dma_resp_id);
    end
  end
`endif

endmodule : dma_test_engine
