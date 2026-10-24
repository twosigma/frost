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
 * MMIO-controlled DMA master on the cache hierarchy's coherent port, through
 * dma_test_engine_axi, which carries its line requests over AXI4.
 * Data writes complete before an optional status write; the interrupt follows
 * the final write's completion.
 *
 * Legacy registers (32-bit, word stride; the CPU sees them as a strongly
 * ordered device window, see hw/rtl/README.md "Memory Map"):
 *
 *   0x00 CTRL    W: bit 0 START (ignored while busy), bit 2 ABORT (ignored
 *                while idle)
 *                R: bit 0 BUSY, bit 1 DONE, bit 2 ERROR, bit 3 IRQ pending
 *   0x04 ACK     W: any value clears DONE, ERROR and the interrupt
 *   0x08 SRC     source byte address (copy mode)
 *   0x0C DST     destination byte address
 *   0x10 LEN     transfer length in bytes (0 performs no data transfer)
 *   0x14 MODE    bit 0: 0 = copy SRC to DST, 1 = fill DST;
 *                bit 1: write STATUS_VALUE to STATUS_ADDR after the data;
 *                bit 2: raise the interrupt on completion;
 *                bit 3 (BURST): move each line as four 8-byte AXI beats,
 *                each a coherent line request of its own, instead of one
 *                32-byte beat (o_burst); without concurrent stores to the
 *                source or destination the data is the same, and status
 *                and interrupt still follow all data writes
 *   0x18 PATTERN fill mode writes PATTERN + i to the i-th 32-bit word of the
 *                transfer (the word holding DST is word 0), so a reader can
 *                check the order in which values become visible
 *   0x1C STATUS_ADDR  32-bit-aligned address of the status word
 *   0x20 STATUS_VALUE the status word
 *   0x24 LINES   R: DST line writes completed in the current or last transfer
 *   0x28 ABI_CTRL R: bit 0 wide mode, bit 1 wide support; W: bit 0 selects
 *                wide mode only while idle, clearing all three addresses
 *
 * In wide mode, the legacy address registers are read-only low-word views.
 * Address programming uses aligned, complete 64-bit MMIO stores:
 *   0x40 SRC64, 0x48 DST64, 0x50 STATUS_ADDR64.
 * A partial write to that bank is rejected by the CPU MMIO router. START
 * remains the activation boundary for the group of configuration registers.
 *
 * A transfer walks DST line by line. Copy mode reads the matching SRC line
 * first (SRC and DST must share their offset within a line), fill mode
 * generates the data; the DST write carries strobes for the bytes inside
 * [DST, DST+LEN). One line is in flight at a time, so the engine's traffic is
 * strictly ordered: every data write has completed (the port's response,
 * which is the shared level's completion) before the status write is
 * issued, and the status write has completed before DONE and the interrupt
 * are raised.
 *
 * DST and its transfer range must lie within
 * [APERTURE_BASE, APERTURE_BASE + APERTURE_BYTES). Copy mode also checks SRC;
 * status-write mode checks STATUS_ADDR and its word alignment. Invalid START
 * sets ERROR without moving data or raising an interrupt. START snapshots
 * configuration, so writes while BUSY program only the next transfer.
 *
 * A coherent response error aborts the transfer, sets ERROR (not DONE), and
 * suppresses any subsequent data or success-status write.
 *
 * Once latched, ABORT issues no further data or status request, waits for
 * any outstanding response, then reports ERROR without DONE and raises the
 * interrupt if the transfer enabled it. Requests already accepted are never
 * cancelled, so the caller must not reuse the buffers until BUSY falls. An
 * ABORT that lands in the cycle the transfer completes has no effect (the
 * transfer reports DONE): an abort can always race a completion. Reset (the
 * CPU's reset) also stops a transfer without cancelling accepted requests:
 * the engine issues nothing in reset, and a response to a request accepted
 * before reset is dropped.
 */
module dma_test_engine #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned ID_BITS = 3,
    parameter logic [63:0] APERTURE_BASE = 64'h8000_0000,
    parameter logic [63:0] APERTURE_BYTES = 64'h4000_0000
) (
    input logic i_clk,
    input logic i_rst,

    // Register interface: 32-bit lane writes and a dword read pair, the
    // same shape the APLIC uses. i_wr_offset / i_rd_offset are byte offsets
    // within the window (bit 2 selects the word of a dword).
    input  logic        i_wr_en,
    input  logic [ 7:0] i_wr_offset,
    input  logic [31:0] i_wr_data,
    // Separate full-width transaction. It must be asserted only for an
    // aligned store with all eight byte strobes; a half-store is not a write.
    input  logic        i_wr64_en,
    input  logic [63:0] i_wr64_data,
    input  logic [ 7:0] i_rd_offset,
    output logic [63:0] o_rd_pair,
    output logic        o_irq,
    // MODE's BURST bit of the active transfer, for the AXI adapter.
    output logic        o_burst,

    // DMA line port (master).
    output logic                    o_dma_req_valid,
    input  logic                    i_dma_req_ready,
    output logic                    o_dma_req_write,
    output logic [  ADDR_WIDTH-1:0] o_dma_req_addr,
    output logic [LINE_BYTES*8-1:0] o_dma_req_wdata,
    output logic [  LINE_BYTES-1:0] o_dma_req_wstrb,
    output logic [     ID_BITS-1:0] o_dma_req_id,
    input  logic                    i_dma_resp_valid,
    input  logic                    i_dma_resp_error = 1'b0,
    input  logic [     ID_BITS-1:0] i_dma_resp_id,
    input  logic [LINE_BYTES*8-1:0] i_dma_resp_rdata
);
  localparam int unsigned LineBits   = LINE_BYTES * 8;
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  logic [63:0] src_q, dst_q, status_addr_q;
  logic [31:0] len_q, mode_q, pattern_q, status_value_q;
  logic [31:0] lines_q;
  logic busy_q, done_q, error_q, irq_q;
  logic wide_mode_q;

  logic wr_ctrl, wr_ack;
  assign wr_ctrl = i_wr_en && (i_wr_offset == 8'h00);
  assign wr_ack  = i_wr_en && (i_wr_offset == 8'h04);
  logic start_req, abort_req;
  assign start_req = wr_ctrl && i_wr_data[0] && !busy_q;
  assign abort_req = wr_ctrl && i_wr_data[2];

  logic [31:0] ctrl_rd;
  assign ctrl_rd = {28'b0, irq_q, error_q, done_q, busy_q};
  always_comb begin
    unique case (i_rd_offset[7:3])
      5'd0: o_rd_pair = {32'b0, ctrl_rd};
      5'd1: o_rd_pair = {dst_q[31:0], src_q[31:0]};
      5'd2: o_rd_pair = {mode_q, len_q};
      5'd3: o_rd_pair = {status_addr_q[31:0], pattern_q};
      5'd4: o_rd_pair = {lines_q, status_value_q};
      5'd5: o_rd_pair = {32'b0, 30'b0, 1'b1, wide_mode_q};
      5'd8: o_rd_pair = src_q;
      5'd9: o_rd_pair = dst_q;
      5'd10: o_rd_pair = status_addr_q;
      default: o_rd_pair = '0;
    endcase
  end
  assign o_irq   = irq_q;
  assign o_burst = a_burst_q;

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

  logic [63:0] cur_line_q;  // DST byte address of the line being worked (line-aligned)
  logic [64:0] end_addr_q;  // DST + LEN (exclusive)
  logic [63:0] src_line_q;  // SRC line address matching cur_line_q
  logic [31:0] word_idx_q;  // 32-bit word offset of this line from the first DST line
  logic [LineBits-1:0] line_data_q;
  logic abort_pending_q;
  // The active transfer's copy of the programming registers, taken at START.
  logic [63:0] a_dst_q, a_status_addr_q;
  logic [31:0] a_pattern_q, a_status_value_q;
  logic a_fill_q, a_status_q, a_irq_q, a_burst_q;
  logic mode_fill, mode_status;
  assign mode_fill   = mode_q[0];
  assign mode_status = mode_q[1];

  // Aperture and alignment checks evaluated at START.
  logic src_ok, dst_ok, status_ok, layout_ok;
  logic [64:0] dst_end;
  logic [64:0] aperture_end;
  assign dst_end = {1'b0, dst_q} + 65'(len_q);
  assign aperture_end = 65'(APERTURE_BASE) + 65'(APERTURE_BYTES);
  function automatic logic in_aperture(input logic [63:0] a);
    in_aperture = (65'(a) >= 65'(APERTURE_BASE)) && (65'(a) < aperture_end);
  endfunction
  assign dst_ok = in_aperture(dst_q) && (dst_end <= aperture_end);
  assign src_ok = mode_fill || (in_aperture(
      src_q
  ) && ((65'(src_q) + 65'(len_q)) <= aperture_end) &&
      (src_q[OffsetBits-1:0] == dst_q[OffsetBits-1:0]));
  assign status_ok = !mode_status || (in_aperture(status_addr_q) && (status_addr_q[1:0] == 2'b00));
  // Never let an address above the port's physical width alias a low line.
  assign layout_ok = dst_ok && src_ok && status_ok &&
      (ADDR_WIDTH == 64 || (dst_q >> ADDR_WIDTH) == 0) &&
      (mode_fill || ADDR_WIDTH == 64 || (src_q >> ADDR_WIDTH) == 0) &&
      (!mode_status || ADDR_WIDTH == 64 || (status_addr_q >> ADDR_WIDTH) == 0);

  // Strobes for the current line: bytes b with cur_line + b in [DST, END).
  logic [LINE_BYTES-1:0] line_strb;
  always_comb begin
    for (int b = 0; b < int'(LINE_BYTES); b++) begin
      logic [64:0] byte_addr;
      byte_addr = 65'(cur_line_q) + 65'(b);
      line_strb[b] = (byte_addr >= 65'(a_dst_q)) && (byte_addr < end_addr_q);
    end
  end

  // Fill data: PATTERN + i for the i-th 32-bit word of the transfer (word
  // lane a_dst_q[OffsetBits-1:2] of the first line is word 0).
  logic [LineBits-1:0] fill_data;
  always_comb begin
    for (int w = 0; w < int'(LINE_BYTES / 4); w++) begin
      fill_data[w*32+:32] = a_pattern_q + word_idx_q + 32'(w) - 32'(a_dst_q[OffsetBits-1:2]);
    end
  end

  // Status word placed in its 32-bit lane of the line with a 4-byte strobe.
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
    o_dma_req_addr  = ADDR_WIDTH'(cur_line_q);
    o_dma_req_wdata = a_fill_q ? fill_data : line_data_q;
    o_dma_req_wstrb = line_strb;
    o_dma_req_id    = '0;
    unique case (state_q)
      S_READ: begin
        o_dma_req_valid = !abort_pending_q;
        o_dma_req_addr  = ADDR_WIDTH'(src_line_q);
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
        o_dma_req_addr  = ADDR_WIDTH'({a_status_addr_q[63:OffsetBits], {OffsetBits{1'b0}}});
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
  assign more_lines = (65'(cur_line_q) + 65'(LINE_BYTES)) < end_addr_q;

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
      wide_mode_q     <= 1'b0;
    end else begin
      // Mode changes are accepted only at the idle activation boundary.
      // Clearing all address registers prevents a stale cross-mode address.
      if (i_wr_en && (i_wr_offset == 8'h28) && !busy_q && (i_wr_data[0] != wide_mode_q)) begin
        wide_mode_q   <= i_wr_data[0];
        src_q         <= '0;
        dst_q         <= '0;
        status_addr_q <= '0;
      end
      // Register writes: START copies them into the active transfer, so a
      // write during a transfer affects only the next one.
      if (i_wr_en) begin
        unique case (i_wr_offset)
          8'h08:   if (!wide_mode_q) src_q <= {32'b0, i_wr_data};
          8'h0c:   if (!wide_mode_q) dst_q <= {32'b0, i_wr_data};
          8'h10:   len_q <= i_wr_data;
          8'h14:   mode_q <= i_wr_data;
          8'h18:   pattern_q <= i_wr_data;
          8'h1c:   if (!wide_mode_q) status_addr_q <= {32'b0, i_wr_data};
          8'h20:   status_value_q <= i_wr_data;
          default: ;
        endcase
      end
      if (i_wr64_en && wide_mode_q) begin
        unique case (i_wr_offset)
          8'h40:   src_q <= i_wr64_data;
          8'h48:   dst_q <= i_wr64_data;
          8'h50:   status_addr_q <= i_wr64_data;
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
            cur_line_q       <= {dst_q[63:OffsetBits], {OffsetBits{1'b0}}};
            src_line_q       <= {src_q[63:OffsetBits], {OffsetBits{1'b0}}};
            end_addr_q       <= dst_end;
            word_idx_q       <= '0;
            a_dst_q          <= dst_q;
            a_pattern_q      <= pattern_q;
            a_status_addr_q  <= status_addr_q;
            a_status_value_q <= status_value_q;
            a_fill_q         <= mode_fill;
            a_status_q       <= mode_status;
            a_irq_q          <= mode_q[2];
            a_burst_q        <= mode_q[3];
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
        // The latched abort blocks new requests. A response still drains before
        // the transfer finishes, including when ABORT arrives on its edge.
        S_READ: begin
          if (abort_pending_q) state_q <= S_FINISH;
          else if (req_fire) state_q <= S_READ_WAIT;
        end
        S_READ_WAIT: begin
          if (i_dma_resp_valid) begin
            line_data_q <= i_dma_resp_rdata;
            state_q <= (abort_pending_q || i_dma_resp_error) ? S_FINISH : S_WRITE;
            if (i_dma_resp_error) abort_pending_q <= 1'b1;
          end
        end
        S_WRITE: begin
          if (abort_pending_q) state_q <= S_FINISH;
          else if (req_fire) state_q <= S_WRITE_WAIT;
        end
        S_WRITE_WAIT: begin
          if (i_dma_resp_valid) begin
            if (!i_dma_resp_error) lines_q <= lines_q + 1'b1;
            if (i_dma_resp_error) abort_pending_q <= 1'b1;
            if (abort_pending_q || i_dma_resp_error) begin
              state_q <= S_FINISH;
            end else if (more_lines) begin
              cur_line_q <= cur_line_q + 64'(LINE_BYTES);
              src_line_q <= src_line_q + 64'(LINE_BYTES);
              word_idx_q <= word_idx_q + 32'(LINE_BYTES / 4);
              state_q    <= a_fill_q ? S_WRITE : S_READ;
            end else begin
              state_q <= a_status_q ? S_STATUS : S_FINISH;
            end
          end
        end
        S_STATUS: begin
          if (abort_pending_q) state_q <= S_FINISH;
          else if (req_fire) state_q <= S_STATUS_WAIT;
        end
        S_STATUS_WAIT:
        if (i_dma_resp_valid) begin
          state_q <= S_FINISH;
          if (i_dma_resp_error) abort_pending_q <= 1'b1;
        end
        S_FINISH: begin
          busy_q          <= 1'b0;
          done_q          <= !abort_pending_q;
          error_q         <= abort_pending_q;
          irq_q           <= a_irq_q;
          state_q         <= S_IDLE;
          abort_pending_q <= 1'b0;  // an abort written this cycle came too late
        end
        default: state_q <= S_IDLE;
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
