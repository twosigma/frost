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
 * frost_cache -- recursive, line-granular, write-back write-allocate cache.
 *
 * Direct-mapped, single-outstanding, blocking. One module serves every level
 * of the hierarchy: the upstream port (slave) and downstream port (master)
 * speak the SAME line protocol, so caches stack by instantiation:
 *   CPU adapter -> frost_cache(L1, BRAM) -> DDR
 *   CPU adapter -> frost_cache(L1, BRAM) -> frost_cache(L2, URAM) -> DDR
 *
 * LINE PORT PROTOCOL (one transaction in flight, no IDs):
 *   request:  req_valid && req_ready = fire. The slave captures addr/write/
 *             wdata/wstrb at the fire cycle. The master holds req_valid (and
 *             stable payload) until ready. addr is a full byte address; the
 *             slave uses addr[..LINE_OFFSET] (line-aligned).
 *   response: resp_valid is a 1-cycle pulse, >= 1 cycle after the fire.
 *             Reads: resp_rdata carries the line. Writes: completion ack
 *             (rdata don't-care). The master must not issue a new request
 *             until it has seen the response of the previous one.
 *   Partial writes carry byte strobes (write-allocate: a write miss fetches
 *   the line from below and merges). A write with ALL strobes set skips the
 *   fetch (whole-line allocate) -- this is the common case for evictions
 *   arriving from the level above, so L2 never reads DDR to absorb one.
 *
 * GEOMETRY: CACHE_SIZE_BYTES / LINE_BYTES direct-mapped lines; a 32-byte line
 * is exactly one 256-bit data-array row (sdp_ram_byte_en: BRAM or URAM via
 * MEMORY_PRIMITIVE). Tags+valid+dirty live in a block RAM (sdp_block_ram).
 *
 * RESET: a sweep FSM walks the tag array clearing every valid bit
 * (NUM_LINES cycles) before asserting req_ready. This re-invalidates the
 * cache on ANY reset -- including the image-load reset the JTAG loader
 * asserts while it rewrites memory -- so stale (possibly dirty) lines from a
 * previous program are discarded by design, never written back.
 *
 * The CPU side already tolerates variable latency (the LQ consumes a valid
 * pulse and the SQ waits for a done pulse), so hits and misses may take any
 * number of cycles. Hit latencies with the default DATA_READ_LATENCY:
 * read hit = DATA_READ_LATENCY+3 cycles from fire, write hit = 3 cycles.
 */
module frost_cache #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned CACHE_SIZE_BYTES = 128 * 1024,
    parameter int unsigned LINE_BYTES = 32,
    // Data-array primitive + latencies (see sdp_ram_byte_en). "block" for L1,
    // "ultra" for the X3 L2. Simulation behaviour is primitive-agnostic.
    // Untyped on purpose: Vivado fails to resolve string-typed parameters
    // propagated into the XPM macro (see sdp_ram_byte_en).
    // verilog_lint: waive explicit-parameter-storage-type
    parameter DATA_MEMORY_PRIMITIVE = "block",
    parameter int unsigned DATA_READ_LATENCY = 2,
    parameter int unsigned DATA_WRITE_LATENCY = 1
) (
    input logic i_clk,
    input logic i_rst,

    // Upstream line port (slave).
    input  logic                    i_up_req_valid,
    output logic                    o_up_req_ready,
    input  logic                    i_up_req_write,
    input  logic [  ADDR_WIDTH-1:0] i_up_req_addr,
    input  logic [LINE_BYTES*8-1:0] i_up_req_wdata,
    input  logic [  LINE_BYTES-1:0] i_up_req_wstrb,
    output logic                    o_up_resp_valid,
    output logic [LINE_BYTES*8-1:0] o_up_resp_rdata,

    // Downstream line port (master).
    output logic                    o_down_req_valid,
    input  logic                    i_down_req_ready,
    output logic                    o_down_req_write,
    output logic [  ADDR_WIDTH-1:0] o_down_req_addr,
    output logic [LINE_BYTES*8-1:0] o_down_req_wdata,
    output logic [  LINE_BYTES-1:0] o_down_req_wstrb,
    input  logic                    i_down_resp_valid,
    input  logic [LINE_BYTES*8-1:0] i_down_resp_rdata
);

  localparam int unsigned LineBits = LINE_BYTES * 8;
  localparam int unsigned NumLines = CACHE_SIZE_BYTES / LINE_BYTES;
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam int unsigned IndexBits = $clog2(NumLines);
  localparam int unsigned TagBits = ADDR_WIDTH - IndexBits - OffsetBits;
  // Tag entry layout: {valid, dirty, tag}
  localparam int unsigned TagEntryBits = TagBits + 2;

  initial begin
    if (NumLines * LINE_BYTES != CACHE_SIZE_BYTES)
      $fatal(1, "frost_cache: CACHE_SIZE_BYTES must be a multiple of LINE_BYTES");
    if (2 ** IndexBits != NumLines) $fatal(1, "frost_cache: line count must be a power of 2");
    if (2 ** OffsetBits != LINE_BYTES) $fatal(1, "frost_cache: LINE_BYTES must be a power of 2");
  end

  // ---- Request registers (captured at the upstream fire) -------------------
  logic                  req_write_q;
  logic [ADDR_WIDTH-1:0] req_addr_q;
  logic [  LineBits-1:0] req_wdata_q;
  logic [LINE_BYTES-1:0] req_wstrb_q;

  logic [ IndexBits-1:0] req_index;
  logic [   TagBits-1:0] req_tag;
  assign req_index = req_addr_q[OffsetBits+:IndexBits];
  assign req_tag   = req_addr_q[ADDR_WIDTH-1-:TagBits];

  // ---- FSM ------------------------------------------------------------------
  typedef enum logic [3:0] {
    S_SWEEP,       // reset: invalidate every tag entry
    S_IDLE,        // accept a request; tag read issued at the fire
    S_TAG_CHECK,   // tag compare; dispatch hit/miss work
    S_READ_WAIT,   // read hit: wait out the data-array read latency
    S_EVICT_WAIT,  // miss with dirty victim: read the victim line
    S_WB_REQ,      // present the victim writeback downstream
    S_WB_WAIT,     // wait for the writeback ack
    S_FILL_REQ,    // present the line fetch downstream
    S_FILL_WAIT,   // wait for the fetched line
    S_ALLOC,       // write the new line + tag
    S_RESPOND      // pulse the upstream response
  } state_e;

  state_e                    state_q;

  logic   [   IndexBits-1:0] sweep_idx_q;
  logic   [             7:0] wait_cnt_q;  // data-array latency countdown (latencies are small)
  logic   [     TagBits-1:0] victim_tag_q;
  logic   [    LineBits-1:0] victim_line_q;
  logic   [    LineBits-1:0] line_buf_q;
  logic   [    LineBits-1:0] resp_data_q;

  // ---- Tag array (sync 1-cycle read; written by sweep / hit / allocate) -----
  logic                      tag_we;
  logic   [   IndexBits-1:0] tag_waddr;
  logic   [TagEntryBits-1:0] tag_wdata;
  logic   [   IndexBits-1:0] tag_raddr;
  logic   [TagEntryBits-1:0] tag_rdata;

  logic tag_rdata_valid, tag_rdata_dirty;
  logic [TagBits-1:0] tag_rdata_tag;
  assign {tag_rdata_valid, tag_rdata_dirty, tag_rdata_tag} = tag_rdata;

  logic hit;
  assign hit = tag_rdata_valid && (tag_rdata_tag == req_tag);

  sdp_block_ram #(
      .ADDR_WIDTH(IndexBits),
      .DATA_WIDTH(TagEntryBits)
  ) tag_array (
      .i_clk(i_clk),
      .i_write_enable(tag_we),
      .i_write_address(tag_waddr),
      .i_read_address(tag_raddr),
      .i_write_data(tag_wdata),
      .o_read_data(tag_rdata)
  );

  // Tag read address: the incoming request's index, sampled at the fire so the
  // entry is readable in S_TAG_CHECK. Don't-care in every other state.
  assign tag_raddr = i_up_req_addr[OffsetBits+:IndexBits];

  // ---- Data array (one row per line) ----------------------------------------
  logic                  data_re;
  logic [ IndexBits-1:0] data_raddr;
  logic [  LineBits-1:0] data_rdata;
  logic                  data_row_we;  // qualifies the byte strobes below
  logic [LINE_BYTES-1:0] data_wbyte_en;
  logic [  LineBits-1:0] data_wdata;

  sdp_ram_byte_en #(
      .DATA_WIDTH(LineBits),
      .ADDR_WIDTH(IndexBits),
      .READ_LATENCY(DATA_READ_LATENCY),
      .WRITE_LATENCY(DATA_WRITE_LATENCY),
      .MEMORY_PRIMITIVE(DATA_MEMORY_PRIMITIVE)
  ) data_array (
      .i_clk(i_clk),
      .i_waddr(req_index),
      .i_wdata(data_wdata),
      .i_wbyte_en(data_wbyte_en & {LINE_BYTES{data_row_we}}),
      .i_re(data_re),
      .i_raddr(data_raddr),
      .o_rdata(data_rdata)
  );
  assign data_raddr = req_index;

  // The (partial) upstream write merged into the fetched line: strobed bytes
  // take the request's data, the rest keep the fill. (A generate rather than
  // a function: Yosys cannot parse loop-variable declarations in functions.)
  logic [LineBits-1:0] fill_merged;
  for (genvar gb = 0; gb < int'(LINE_BYTES); gb++) begin : gen_fill_merge
    assign fill_merged[gb*8+:8] =
        req_wstrb_q[gb] ? req_wdata_q[gb*8+:8] : i_down_resp_rdata[gb*8+:8];
  end

  logic up_req_fire;
  assign up_req_fire = i_up_req_valid && o_up_req_ready;
  assign o_up_req_ready = (state_q == S_IDLE);

  logic whole_line_write;
  assign whole_line_write = req_write_q && (&req_wstrb_q);

  // ---- Combinational outputs / array drives ---------------------------------
  always_comb begin
    tag_we           = 1'b0;
    tag_waddr        = req_index;
    tag_wdata        = '0;
    data_re          = 1'b0;
    data_row_we      = 1'b0;
    data_wbyte_en    = '0;
    data_wdata       = '0;

    o_down_req_valid = 1'b0;
    o_down_req_write = 1'b0;
    o_down_req_addr  = {req_addr_q[ADDR_WIDTH-1:OffsetBits], {OffsetBits{1'b0}}};
    o_down_req_wdata = victim_line_q;
    o_down_req_wstrb = '1;

    unique case (state_q)
      S_SWEEP: begin
        tag_we    = 1'b1;
        tag_waddr = sweep_idx_q;
        tag_wdata = '0;  // valid=0, dirty=0
      end

      S_TAG_CHECK: begin
        if (hit && !req_write_q) begin
          data_re = 1'b1;  // read hit: start the data-array read
        end else if (hit && req_write_q) begin
          // Write hit: strobed byte write into the line, mark dirty.
          data_row_we   = 1'b1;
          data_wbyte_en = req_wstrb_q;
          data_wdata    = req_wdata_q;
          tag_we        = 1'b1;
          tag_wdata     = {1'b1, 1'b1, req_tag};
        end else if (tag_rdata_valid && tag_rdata_dirty) begin
          data_re = 1'b1;  // miss with dirty victim: read it out for writeback
        end
      end

      S_WB_REQ: begin
        o_down_req_valid = 1'b1;
        o_down_req_write = 1'b1;
        o_down_req_addr  = {victim_tag_q, req_index, {OffsetBits{1'b0}}};
        o_down_req_wdata = victim_line_q;
        o_down_req_wstrb = '1;
      end

      S_FILL_REQ: begin
        o_down_req_valid = 1'b1;
        o_down_req_write = 1'b0;
      end

      S_ALLOC: begin
        // Write the whole new line and its tag. Dirty iff allocated by a write.
        data_row_we   = 1'b1;
        data_wbyte_en = '1;
        data_wdata    = line_buf_q;
        tag_we        = 1'b1;
        tag_wdata     = {1'b1, req_write_q, req_tag};
      end

      default: ;
    endcase
  end

  assign o_up_resp_valid = (state_q == S_RESPOND);
  assign o_up_resp_rdata = resp_data_q;

  // ---- Sequential FSM --------------------------------------------------------
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q     <= S_SWEEP;
      sweep_idx_q <= '0;
    end else begin
      unique case (state_q)
        S_SWEEP: begin
          sweep_idx_q <= sweep_idx_q + 1'b1;
          if (sweep_idx_q == {IndexBits{1'b1}}) state_q <= S_IDLE;
        end

        S_IDLE: begin
          if (up_req_fire) begin
            req_write_q <= i_up_req_write;
            req_addr_q  <= i_up_req_addr;
            req_wdata_q <= i_up_req_wdata;
            req_wstrb_q <= i_up_req_wstrb;
            state_q     <= S_TAG_CHECK;
          end
        end

        S_TAG_CHECK: begin
          if (hit && !req_write_q) begin
            wait_cnt_q <= 8'(DATA_READ_LATENCY);
            state_q    <= S_READ_WAIT;
          end else if (hit && req_write_q) begin
            state_q <= S_RESPOND;
          end else if (tag_rdata_valid && tag_rdata_dirty) begin
            wait_cnt_q   <= 8'(DATA_READ_LATENCY);
            victim_tag_q <= tag_rdata_tag;
            state_q      <= S_EVICT_WAIT;
          end else if (whole_line_write) begin
            // Clean/invalid victim + whole-line write: allocate without a fetch.
            line_buf_q <= req_wdata_q;
            state_q    <= S_ALLOC;
          end else begin
            state_q <= S_FILL_REQ;
          end
        end

        S_READ_WAIT: begin
          wait_cnt_q <= wait_cnt_q - 1'b1;
          if (wait_cnt_q == 8'd1) begin
            resp_data_q <= data_rdata;
            state_q     <= S_RESPOND;
          end
        end

        S_EVICT_WAIT: begin
          wait_cnt_q <= wait_cnt_q - 1'b1;
          if (wait_cnt_q == 8'd1) begin
            victim_line_q <= data_rdata;
            state_q       <= S_WB_REQ;
          end
        end

        S_WB_REQ: if (i_down_req_ready) state_q <= S_WB_WAIT;

        S_WB_WAIT: begin
          if (i_down_resp_valid) begin
            if (whole_line_write) begin
              line_buf_q <= req_wdata_q;
              state_q    <= S_ALLOC;
            end else begin
              state_q <= S_FILL_REQ;
            end
          end
        end

        S_FILL_REQ: if (i_down_req_ready) state_q <= S_FILL_WAIT;

        S_FILL_WAIT: begin
          if (i_down_resp_valid) begin
            line_buf_q <= req_write_q ? fill_merged : i_down_resp_rdata;
            state_q <= S_ALLOC;
          end
        end

        S_ALLOC: begin
          resp_data_q <= line_buf_q;
          state_q     <= S_RESPOND;
        end

        S_RESPOND: state_q <= S_IDLE;

        default: state_q <= S_SWEEP;
      endcase
    end
  end

`ifndef SYNTHESIS
  // Protocol checks (simulation only).
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (i_down_resp_valid && !(state_q == S_WB_WAIT || state_q == S_FILL_WAIT))
        $error("frost_cache: downstream response outside a WAIT state (state=%0d)", state_q);
      if (i_up_req_valid && o_up_req_ready && i_up_req_write && i_up_req_wstrb == '0)
        $error("frost_cache: write request with empty strobes");
    end
  end
`endif

endmodule : frost_cache
