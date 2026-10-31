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
 * axi_coherent_bridge: AXI4 slave into cpu_top's coherent ingress.
 *
 * DMA masters reach cached memory through this bridge, which turns their
 * bursts into the ingress's line requests of LINE_BYTES bytes (32 for
 * cpu_top; hw/rtl/lib/axi/README.md).
 * It meets every ingress precondition itself: each request is line aligned
 * and inside [REGION_BASE, REGION_BASE + REGION_BYTES), each write has a
 * strobe, and each id is unique among the requests in flight.
 *
 * Classification. Each AW and AR waits one cycle in an input register and is
 * classified from there. A burst with AxSIZE wider than the bus, the reserved
 * burst type, a FIXED burst over 16 beats, a WRAP burst that is not 2, 4, 8 or
 * 16 beats from an AxSIZE-aligned address, or an INCR burst that crosses a
 * 4 KiB boundary is answered SLVERR; one whose start address lies outside the
 * region is answered DECERR. Such an error burst sends no line request: its W
 * beats are taken and its B, or every one of its R beats (with zero data),
 * carries the code. The region's boundaries are 4 KiB aligned, so a legal
 * burst that starts inside it stays inside it. AxLOCK, AxCACHE, AxPROT and
 * AxQOS are ignored: an exclusive access is performed as a normal one and
 * answered OKAY, as AXI4 specifies for a slave without exclusive support.
 *
 * Beats and segments. Beat addresses and byte lanes follow AXI4 for FIXED,
 * INCR and WRAP bursts, and W strobes are masked to the beat's lanes. A
 * segment is the set of beats one line request serves: with a bus as wide as
 * a line each beat is its own segment; with a narrower one it is a run of
 * consecutive beats in one line, merged in an assembly register, later
 * beats overwriting earlier ones byte by byte. A segment whose strobes are
 * all clear sends no request.
 *
 * Ordering. Line writes are issued in AW and beat order and line reads in AR
 * and beat order; the two directions are independent, as in AXI. B returns in
 * AW order once the burst's beats are all in and every line it wrote has been
 * answered, so a B means the burst's bytes are ordered at the L2. R returns in
 * AR order, a burst at a time. An ingress error answers SLVERR on the B, or on
 * the R beats of that line.
 *
 * Ids and the line port. Writes use line ids {0, n} and reads {1, n}, with
 * n in [0, 2^(LINE_ID_BITS-1)). A write id is held from sealing to its line
 * response; a read id until its last R beat, so every line response finds a
 * place. Writes take the line port first, and a read waits at most
 * STARVATION_LIMIT write grants; the choice is held while the presented
 * request waits, as the ingress requires.
 *
 * Every AXI READY and every B and R output comes from registered state, and
 * the line request is presented from registers. i_rst is synchronous; while it
 * is asserted every VALID and READY is low. It must reset the bridge with its
 * AXI masters, and each reset of the ingress, which drops the requests it
 * holds, must overlap one of the bridge.
 */
module axi_coherent_bridge #(
    parameter int unsigned ADDR_WIDTH = 64,
    parameter int unsigned DATA_WIDTH = 256,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned ID_WIDTH = 5,
    parameter int unsigned LINE_ADDR_WIDTH = 32,
    parameter int unsigned LINE_ID_BITS = 3,
    parameter logic [63:0] REGION_BASE = 64'h8000_0000,
    parameter logic [63:0] REGION_BYTES = 64'h4000_0000,
    parameter int unsigned WRITE_BURSTS = 4,
    parameter int unsigned READ_BURSTS = 4,
    parameter int unsigned STARVATION_LIMIT = 8
) (
    input logic i_clk,
    input logic i_rst,

    // AXI4 slave.
    input  logic                    i_axi_awvalid,
    output logic                    o_axi_awready,
    input  logic [    ID_WIDTH-1:0] i_axi_awid,
    input  logic [  ADDR_WIDTH-1:0] i_axi_awaddr,
    input  logic [             7:0] i_axi_awlen,
    input  logic [             2:0] i_axi_awsize,
    input  logic [             1:0] i_axi_awburst,
    input  logic                    i_axi_awlock,
    input  logic [             3:0] i_axi_awcache,
    input  logic [             2:0] i_axi_awprot,
    input  logic [             3:0] i_axi_awqos,
    input  logic                    i_axi_wvalid,
    output logic                    o_axi_wready,
    input  logic [  DATA_WIDTH-1:0] i_axi_wdata,
    input  logic [DATA_WIDTH/8-1:0] i_axi_wstrb,
    input  logic                    i_axi_wlast,
    output logic                    o_axi_bvalid,
    input  logic                    i_axi_bready,
    output logic [    ID_WIDTH-1:0] o_axi_bid,
    output logic [             1:0] o_axi_bresp,
    input  logic                    i_axi_arvalid,
    output logic                    o_axi_arready,
    input  logic [    ID_WIDTH-1:0] i_axi_arid,
    input  logic [  ADDR_WIDTH-1:0] i_axi_araddr,
    input  logic [             7:0] i_axi_arlen,
    input  logic [             2:0] i_axi_arsize,
    input  logic [             1:0] i_axi_arburst,
    input  logic                    i_axi_arlock,
    input  logic [             3:0] i_axi_arcache,
    input  logic [             2:0] i_axi_arprot,
    input  logic [             3:0] i_axi_arqos,
    output logic                    o_axi_rvalid,
    input  logic                    i_axi_rready,
    output logic [    ID_WIDTH-1:0] o_axi_rid,
    output logic [  DATA_WIDTH-1:0] o_axi_rdata,
    output logic [             1:0] o_axi_rresp,
    output logic                    o_axi_rlast,

    // Line port (master) into the coherent ingress.
    output logic                       o_line_req_valid,
    input  logic                       i_line_req_ready,
    output logic                       o_line_req_write,
    output logic [LINE_ADDR_WIDTH-1:0] o_line_req_addr,
    output logic [   8*LINE_BYTES-1:0] o_line_req_wdata,
    output logic [     LINE_BYTES-1:0] o_line_req_wstrb,
    output logic [   LINE_ID_BITS-1:0] o_line_req_id,
    input  logic                       i_line_resp_valid,
    input  logic [   LINE_ID_BITS-1:0] i_line_resp_id,
    input  logic [   8*LINE_BYTES-1:0] i_line_resp_rdata,
    input  logic                       i_line_resp_error
);
  localparam int unsigned LineBytes = LINE_BYTES;
  localparam int unsigned LineBits = 8 * LineBytes;
  localparam int unsigned OffsetBits = $clog2(LineBytes);
  localparam int unsigned BusBytes = DATA_WIDTH / 8;
  localparam int unsigned BusSize = $clog2(BusBytes);  // AxSIZE of a full-width beat
  localparam logic [11:0] BusMask = 12'(BusBytes - 1);
  localparam logic [11:0] LineMask = 12'(LineBytes - 1);
  localparam int unsigned WordsPerLine = LineBytes / BusBytes;
  localparam int unsigned WordBits = (WordsPerLine > 1) ? $clog2(WordsPerLine) : 1;
  localparam int unsigned LineAddrBits = LINE_ADDR_WIDTH - OffsetBits;
  localparam int unsigned SubIdBits = LINE_ID_BITS - 1;
  localparam int unsigned NumSubIds = 1 << SubIdBits;
  localparam int unsigned WbtBits = $clog2(WRITE_BURSTS);
  localparam int unsigned RbtBits = $clog2(READ_BURSTS);
  localparam int unsigned WbtCountBits = $clog2(WRITE_BURSTS + 1);
  localparam int unsigned RbtCountBits = $clog2(READ_BURSTS + 1);
  // Lines one write burst can have in flight: at most one per write id.
  localparam int unsigned OutBits = $clog2(NumSubIds + 1);
  // Read segments issued and not yet returned on R: one per read id, plus
  // error segments, which hold no id.
  localparam int unsigned SegDepth = NumSubIds;
  localparam int unsigned SegBits = (SegDepth > 1) ? $clog2(SegDepth) : 1;
  localparam int unsigned SegCountBits = $clog2(SegDepth + 1);
  localparam int unsigned StarveBits = $clog2(STARVATION_LIMIT + 1);

  localparam logic [1:0] RespOkay = 2'b00;
  localparam logic [1:0] RespSlvErr = 2'b10;
  localparam logic [1:0] RespDecErr = 2'b11;
  localparam logic [1:0] BurstFixed = 2'b00;
  localparam logic [1:0] BurstIncr = 2'b01;
  localparam logic [1:0] BurstWrap = 2'b10;

  initial begin
    if (LINE_BYTES < 4 || LINE_BYTES > 128 || (LINE_BYTES & (LINE_BYTES - 1)) != 0)
      $fatal(1, "axi_coherent_bridge: LINE_BYTES must be a power of two from 4 to 128");
    if (DATA_WIDTH < 8 || DATA_WIDTH > 8 * LINE_BYTES || (DATA_WIDTH & (DATA_WIDTH - 1)) != 0)
      $fatal(1, "axi_coherent_bridge: DATA_WIDTH must be a power of two from 8 to 8*LINE_BYTES");
    if (LINE_ID_BITS < 2) $fatal(1, "axi_coherent_bridge: LINE_ID_BITS must be at least 2");
    if (ADDR_WIDTH < 12 || ADDR_WIDTH > 64)
      $fatal(1, "axi_coherent_bridge: ADDR_WIDTH must be 12 to 64");
    if (LINE_ADDR_WIDTH <= OffsetBits || LINE_ADDR_WIDTH > 64)
      $fatal(1, "axi_coherent_bridge: LINE_ADDR_WIDTH must be 6 to 64");
    if (WRITE_BURSTS < 2 || (WRITE_BURSTS & (WRITE_BURSTS - 1)) != 0 ||
        READ_BURSTS < 2 || (READ_BURSTS & (READ_BURSTS - 1)) != 0)
      $fatal(1, "axi_coherent_bridge: burst table depths must be powers of two, at least 2");
    if (REGION_BYTES == 0 || REGION_BASE[11:0] != 0 || REGION_BYTES[11:0] != 0)
      $fatal(1, "axi_coherent_bridge: the region must be nonempty and 4 KiB aligned");
    if ((65'(REGION_BASE) + 65'(REGION_BYTES)) > (65'(1) << LINE_ADDR_WIDTH))
      $fatal(1, "axi_coherent_bridge: the region must fit LINE_ADDR_WIDTH");
    if (STARVATION_LIMIT < 1) $fatal(1, "axi_coherent_bridge: STARVATION_LIMIT must be >= 1");
  end

  // ---------------------------------------------------------------------------
  // Burst geometry
  // ---------------------------------------------------------------------------
  // 2^size - 1, the byte offset mask of one transfer.
  function automatic logic [11:0] size_mask(input logic [2:0] size);
    size_mask = 12'((32'd1 << size) - 32'd1);
  endfunction

  // The response code of a burst, from its address and geometry.
  function automatic logic [1:0] classify(input logic [ADDR_WIDTH-1:0] addr, input logic [7:0] len,
                                          input logic [2:0] size, input logic [1:0] burst);
    logic [11:0] start;
    logic [15:0] page_end;
    logic size_ok, type_ok, fixed_ok, wrap_ok, page_ok, in_region;
    start = addr[11:0] & ~size_mask(size);
    // One past the burst's last byte, counted from the start of its page.
    page_end = 16'(start) + ((16'(len) + 16'd1) << size);
    size_ok = 32'(size) <= BusSize;
    type_ok = burst != 2'b11;
    fixed_ok = (burst != BurstFixed) || (len <= 8'd15);
    wrap_ok = (burst != BurstWrap) ||
        (((len == 8'd1) || (len == 8'd3) || (len == 8'd7) || (len == 8'd15)) &&
         ((addr[11:0] & size_mask(size)) == 12'd0));
    page_ok = (burst != BurstIncr) || (page_end <= 16'd4096);
    in_region = (65'(addr) >= 65'(REGION_BASE)) &&
        (65'(addr) < (65'(REGION_BASE) + 65'(REGION_BYTES)));
    if (!(size_ok && type_ok && fixed_ok && wrap_ok && page_ok)) classify = RespSlvErr;
    else if (!in_region) classify = RespDecErr;
    else classify = RespOkay;
  endfunction

  // The address of the beat after one at addr. Only the low 12 bits change:
  // INCR bursts stay in one page, WRAP windows are aligned, FIXED repeats.
  function automatic logic [LINE_ADDR_WIDTH-1:0] next_beat(
      input logic [LINE_ADDR_WIDTH-1:0] addr, input logic [7:0] len, input logic [2:0] size,
      input logic [1:0] burst);
    logic [11:0] incr, wrap_mask;
    incr = (addr[11:0] | size_mask(size)) + 12'd1;
    wrap_mask = 12'(((32'(len) + 32'd1) << size) - 32'd1);
    next_beat = addr;
    if (burst == BurstIncr) next_beat[11:0] = incr;
    else if (burst == BurstWrap) next_beat[11:0] = (addr[11:0] & ~wrap_mask) | (incr & wrap_mask);
  endfunction

  // The bus byte lanes of a beat at line offset `offset`: from there to the end
  // of its AxSIZE-aligned transfer.
  function automatic logic [BusBytes-1:0] beat_lanes(input logic [OffsetBits-1:0] offset,
                                                     input logic [2:0] size);
    logic [11:0] low, high;
    low  = 12'(offset) & BusMask;
    high = (12'(offset) | size_mask(size)) & BusMask;
    for (int b = 0; b < int'(BusBytes); b++) beat_lanes[b] = (12'(b) >= low) && (12'(b) <= high);
  endfunction

  // Whether a beat at line offset `offset` ends its segment.
  function automatic logic ends_segment(input logic [OffsetBits-1:0] offset, input logic [7:0] len,
                                        input logic [2:0] size, input logic [1:0] burst,
                                        input logic last);
    logic line_end, wide_wrap;
    line_end  = ((12'(offset) | size_mask(size)) & LineMask) == LineMask;
    wide_wrap = ((32'(len) + 32'd1) << size) > 32'(LineBytes);
    if (WordsPerLine == 1) ends_segment = 1'b1;
    else if (last) ends_segment = 1'b1;
    else if (burst == BurstIncr) ends_segment = line_end;
    else if (burst == BurstWrap) ends_segment = wide_wrap && line_end;
    else ends_segment = 1'b0;
  endfunction

  // Lowest clear bit of a busy mask.
  function automatic logic [SubIdBits-1:0] lowest_free(input logic [NumSubIds-1:0] busy);
    lowest_free = '0;
    for (int k = int'(NumSubIds) - 1; k >= 0; k--) if (!busy[k]) lowest_free = SubIdBits'(k);
  endfunction

  // First clear bit of a busy mask at or after start, wrapping.
  function automatic logic [SubIdBits-1:0] next_free(input logic [NumSubIds-1:0] busy,
                                                     input logic [SubIdBits-1:0] start);
    next_free = start;
    for (int k = int'(NumSubIds) - 1; k >= 0; k--) begin
      if (!busy[SubIdBits'(int'(start)+k)]) next_free = SubIdBits'(int'(start) + k);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Line port: the write and read request registers and their merge
  // ---------------------------------------------------------------------------
  logic wreq_valid_q, rreq_valid_q;
  logic [LineAddrBits-1:0] wreq_line_q, rreq_line_q;
  logic [ LineBits-1:0] wreq_data_q;
  logic [LineBytes-1:0] wreq_strb_q;
  logic [SubIdBits-1:0] wreq_sub_q, rreq_sub_q;
  // The side presented (1 = read), chosen one cycle ahead; held while the
  // presented request waits for ready.
  logic sel_read_q;
  logic [StarveBits-1:0] starve_q;

  assign o_line_req_valid = !i_rst && (sel_read_q ? rreq_valid_q : wreq_valid_q);
  assign o_line_req_write = !sel_read_q;
  assign o_line_req_addr = {sel_read_q ? rreq_line_q : wreq_line_q, {OffsetBits{1'b0}}};
  assign o_line_req_wdata = wreq_data_q;
  assign o_line_req_wstrb = wreq_strb_q;
  assign o_line_req_id = {sel_read_q, sel_read_q ? rreq_sub_q : wreq_sub_q};

  logic line_fire, wreq_fire, rreq_fire;
  assign line_fire = o_line_req_valid && i_line_req_ready;
  assign wreq_fire = line_fire && !sel_read_q;
  assign rreq_fire = line_fire && sel_read_q;

  logic resp_write, resp_read;
  logic [SubIdBits-1:0] resp_sub;
  assign resp_write = i_line_resp_valid && !i_line_resp_id[LINE_ID_BITS-1];
  assign resp_read  = i_line_resp_valid && i_line_resp_id[LINE_ID_BITS-1];
  assign resp_sub   = i_line_resp_id[SubIdBits-1:0];

  // ---------------------------------------------------------------------------
  // Write path
  // ---------------------------------------------------------------------------
  logic aw_q_valid;
  logic [ID_WIDTH-1:0] aw_q_id;
  logic [ADDR_WIDTH-1:0] aw_q_addr;
  logic [7:0] aw_q_len;
  logic [2:0] aw_q_size;
  logic [1:0] aw_q_burst;
  logic [1:0] aw_q_code;
  assign aw_q_code = classify(aw_q_addr, aw_q_len, aw_q_size, aw_q_burst);

  // Write burst table, in AW order. The input register always finds room:
  // AWREADY counts it.
  logic [WbtCountBits-1:0] wbt_count_q;
  logic [WbtBits-1:0] wbt_head_q, wbt_tail_q;
  logic [ID_WIDTH-1:0] wbt_id_q[WRITE_BURSTS];
  logic [1:0] wbt_code_q[WRITE_BURSTS];
  logic [LINE_ADDR_WIDTH-1:0] wbt_addr_q[WRITE_BURSTS];
  logic [7:0] wbt_len_q[WRITE_BURSTS];
  logic [2:0] wbt_size_q[WRITE_BURSTS];
  logic [1:0] wbt_burst_q[WRITE_BURSTS];
  logic [WRITE_BURSTS-1:0] wbt_done_q, wbt_err_q;
  logic [OutBits-1:0] wbt_out_q[WRITE_BURSTS];

  assign o_axi_awready = !i_rst && ((32'(wbt_count_q) + 32'(aw_q_valid)) < WRITE_BURSTS);
  logic aw_fire;
  assign aw_fire = i_axi_awvalid && o_axi_awready;

  // The W engine works on the oldest entry whose beats are not all in.
  logic [WbtCountBits-1:0] w_pend_q;
  logic [WbtBits-1:0] w_idx_q;
  logic w_err_q, w_last_q, w_seg_end_q;
  logic [LINE_ADDR_WIDTH-1:0] w_addr_q;
  logic [7:0] w_beat_q, w_len_q;
  logic [2:0] w_size_q;
  logic [1:0] w_burst_q;
  logic [BusBytes-1:0] w_lanes_q;
  // The line being assembled (narrow buses only).
  logic [LineBits-1:0] asm_data_q;
  logic [LineBytes-1:0] asm_strb_q;

  logic [NumSubIds-1:0] w_id_busy_q;
  logic [WbtBits-1:0] w_id_burst_q[NumSubIds];
  logic w_id_free;
  assign w_id_free = !(&w_id_busy_q);

  assign o_axi_wready = !i_rst && (w_pend_q != '0) &&
      (w_err_q || !w_seg_end_q || (!wreq_valid_q && w_id_free));
  logic w_fire, w_burst_end;
  assign w_fire = i_axi_wvalid && o_axi_wready;
  assign w_burst_end = w_fire && w_last_q;

  // The beat merged into the line: strobes masked to the beat's lanes and
  // placed at its bus word.
  logic [ BusBytes-1:0] w_strb;
  logic [ LineBits-1:0] w_line_data;
  logic [LineBytes-1:0] w_line_strb;
  logic w_seal, w_seal_any;
  logic [SubIdBits-1:0] w_new_sub;
  assign w_strb = i_axi_wstrb & w_lanes_q;
  always_comb begin
    logic [WordBits-1:0] word;
    word = (WordsPerLine > 1) ? WordBits'(w_addr_q[OffsetBits-1:0] >> BusSize) : '0;
    for (int b = 0; b < int'(LineBytes); b++) begin
      logic hit;
      hit = ((WordsPerLine == 1) || (WordBits'(b / int'(BusBytes)) == word)) &&
          w_strb[b%int'(BusBytes)];
      w_line_data[b*8+:8] = hit ? i_axi_wdata[(b%int'(BusBytes))*8+:8] :
          ((WordsPerLine > 1) ? asm_data_q[b*8+:8] : 8'h00);
      w_line_strb[b] = hit || ((WordsPerLine > 1) && asm_strb_q[b]);
    end
  end
  assign w_seal = w_fire && !w_err_q && w_seg_end_q;
  assign w_seal_any = w_seal && (|w_line_strb);
  assign w_new_sub = lowest_free(w_id_busy_q);

  // The burst the W engine takes after the current one: the next entry, or
  // the input register's burst entering the table now.
  logic w_load, w_load_from_aw;
  logic [WbtBits-1:0] w_next_idx;
  logic [LINE_ADDR_WIDTH-1:0] w_next_addr;
  logic [7:0] w_next_len;
  logic [2:0] w_next_size;
  logic [1:0] w_next_burst;
  logic w_next_err;
  assign w_next_idx = (w_pend_q == '0) ? w_idx_q : w_idx_q + 1'b1;
  assign w_load_from_aw = (w_pend_q == '0) || (w_pend_q == WbtCountBits'(1));
  assign w_load = ((w_pend_q == '0) && aw_q_valid) ||
      (w_burst_end && ((w_pend_q > WbtCountBits'(1)) || aw_q_valid));
  assign w_next_addr = w_load_from_aw ? LINE_ADDR_WIDTH'(aw_q_addr) : wbt_addr_q[w_next_idx];
  assign w_next_len = w_load_from_aw ? aw_q_len : wbt_len_q[w_next_idx];
  assign w_next_size = w_load_from_aw ? aw_q_size : wbt_size_q[w_next_idx];
  assign w_next_burst = w_load_from_aw ? aw_q_burst : wbt_burst_q[w_next_idx];
  assign w_next_err = w_load_from_aw ? (aw_q_code != RespOkay) :
      (wbt_code_q[w_next_idx] != RespOkay);

  // The current burst's next beat.
  logic [LINE_ADDR_WIDTH-1:0] w_step_addr;
  logic w_step_last;
  assign w_step_addr = next_beat(w_addr_q, w_len_q, w_size_q, w_burst_q);
  assign w_step_last = (w_beat_q + 8'd1) == w_len_q;

  // B: the head entry answers once its beats are in and its lines answered.
  logic b_ready_head;
  assign b_ready_head = (wbt_count_q != '0) && wbt_done_q[wbt_head_q] &&
      (wbt_out_q[wbt_head_q] == '0);
  assign o_axi_bvalid = !i_rst && b_ready_head;
  assign o_axi_bid = wbt_id_q[wbt_head_q];
  assign o_axi_bresp = (wbt_code_q[wbt_head_q] != RespOkay) ? wbt_code_q[wbt_head_q] :
      (wbt_err_q[wbt_head_q] ? RespSlvErr : RespOkay);
  logic b_fire;
  assign b_fire = o_axi_bvalid && i_axi_bready;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      aw_q_valid   <= 1'b0;
      wbt_count_q  <= '0;
      wbt_head_q   <= '0;
      wbt_tail_q   <= '0;
      wbt_done_q   <= '0;
      wbt_err_q    <= '0;
      w_pend_q     <= '0;
      w_idx_q      <= '0;
      w_err_q      <= 1'b0;
      w_last_q     <= 1'b0;
      w_seg_end_q  <= 1'b0;
      asm_strb_q   <= '0;
      wreq_valid_q <= 1'b0;
      w_id_busy_q  <= '0;
      for (int k = 0; k < int'(WRITE_BURSTS); k++) wbt_out_q[k] <= '0;
    end else begin
      // The input register: refilled by a handshake, emptied into the table.
      aw_q_valid <= aw_fire;
      if (aw_fire) begin
        aw_q_id    <= i_axi_awid;
        aw_q_addr  <= i_axi_awaddr;
        aw_q_len   <= i_axi_awlen;
        aw_q_size  <= i_axi_awsize;
        aw_q_burst <= i_axi_awburst;
      end
      if (aw_q_valid) begin
        wbt_id_q[wbt_tail_q]    <= aw_q_id;
        wbt_code_q[wbt_tail_q]  <= aw_q_code;
        wbt_addr_q[wbt_tail_q]  <= LINE_ADDR_WIDTH'(aw_q_addr);
        wbt_len_q[wbt_tail_q]   <= aw_q_len;
        wbt_size_q[wbt_tail_q]  <= aw_q_size;
        wbt_burst_q[wbt_tail_q] <= aw_q_burst;
        wbt_done_q[wbt_tail_q]  <= 1'b0;
        wbt_err_q[wbt_tail_q]   <= 1'b0;
        wbt_tail_q              <= wbt_tail_q + 1'b1;
      end
      wbt_count_q <= wbt_count_q + WbtCountBits'(aw_q_valid) - WbtCountBits'(b_fire);
      if (b_fire) wbt_head_q <= wbt_head_q + 1'b1;
      w_pend_q <= w_pend_q + WbtCountBits'(aw_q_valid) - WbtCountBits'(w_burst_end);

      // The W engine.
      if (w_load) begin
        w_idx_q <= w_next_idx;
        w_err_q <= w_next_err;
        w_addr_q <= w_next_addr;
        w_beat_q <= '0;
        w_len_q <= w_next_len;
        w_size_q <= w_next_size;
        w_burst_q <= w_next_burst;
        w_last_q <= w_next_len == 8'd0;
        w_seg_end_q <= ends_segment(
            w_next_addr[OffsetBits-1:0], w_next_len, w_next_size, w_next_burst, w_next_len == 8'd0
        );
        w_lanes_q <= beat_lanes(w_next_addr[OffsetBits-1:0], w_next_size);
      end else if (w_burst_end) begin
        w_idx_q <= w_idx_q + 1'b1;
      end else if (w_fire) begin
        w_addr_q <= w_step_addr;
        w_beat_q <= w_beat_q + 8'd1;
        w_last_q <= w_step_last;
        w_seg_end_q <= ends_segment(
            w_step_addr[OffsetBits-1:0], w_len_q, w_size_q, w_burst_q, w_step_last
        );
        w_lanes_q <= beat_lanes(w_step_addr[OffsetBits-1:0], w_size_q);
      end
      if (w_burst_end) wbt_done_q[w_idx_q] <= 1'b1;

      // Assembly and sealing.
      if (w_fire && !w_err_q) begin
        if (w_seg_end_q) asm_strb_q <= '0;
        else begin
          asm_data_q <= w_line_data;
          asm_strb_q <= w_line_strb;
        end
      end
      if (wreq_fire) wreq_valid_q <= 1'b0;
      if (w_seal_any) begin
        wreq_valid_q <= 1'b1;
        wreq_line_q <= w_addr_q[LINE_ADDR_WIDTH-1:OffsetBits];
        wreq_data_q <= w_line_data;
        wreq_strb_q <= w_line_strb;
        wreq_sub_q <= w_new_sub;
        w_id_busy_q[w_new_sub] <= 1'b1;
        w_id_burst_q[w_new_sub] <= w_idx_q;
      end
      if (resp_write) begin
        w_id_busy_q[resp_sub] <= 1'b0;
        if (i_line_resp_error) wbt_err_q[w_id_burst_q[resp_sub]] <= 1'b1;
      end
      for (int k = 0; k < int'(WRITE_BURSTS); k++) begin
        wbt_out_q[k] <= wbt_out_q[k] +
            OutBits'(w_seal_any && (w_idx_q == WbtBits'(k))) -
            OutBits'(resp_write && (w_id_burst_q[resp_sub] == WbtBits'(k)));
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Read path
  // ---------------------------------------------------------------------------
  logic ar_q_valid;
  logic [ID_WIDTH-1:0] ar_q_id;
  logic [ADDR_WIDTH-1:0] ar_q_addr;
  logic [7:0] ar_q_len;
  logic [2:0] ar_q_size;
  logic [1:0] ar_q_burst;
  logic [1:0] ar_q_code;
  assign ar_q_code = classify(ar_q_addr, ar_q_len, ar_q_size, ar_q_burst);

  // Read burst table, in AR order.
  logic [RbtCountBits-1:0] rbt_count_q;
  logic [RbtBits-1:0] rbt_head_q, rbt_tail_q;
  logic [ID_WIDTH-1:0] rbt_id_q[READ_BURSTS];
  logic [1:0] rbt_code_q[READ_BURSTS];
  logic [LINE_ADDR_WIDTH-1:0] rbt_addr_q[READ_BURSTS];
  logic [7:0] rbt_len_q[READ_BURSTS];
  logic [2:0] rbt_size_q[READ_BURSTS];
  logic [1:0] rbt_burst_q[READ_BURSTS];

  assign o_axi_arready = !i_rst && ((32'(rbt_count_q) + 32'(ar_q_valid)) < READ_BURSTS);
  logic ar_fire;
  assign ar_fire = i_axi_arvalid && o_axi_arready;

  // Segments issued and not yet returned on R, in issue order.
  logic [SegCountBits-1:0] seg_count_q;
  logic [SegBits-1:0] seg_head_q, seg_tail_q;
  logic [SubIdBits-1:0] seg_sub_q[SegDepth];
  logic [SegDepth-1:0] seg_err_q;
  logic seg_room;
  assign seg_room = 32'(seg_count_q) < SegDepth;

  logic [NumSubIds-1:0] r_id_busy_q, rbuf_valid_q;
  logic r_id_free;
  assign r_id_free = !(&r_id_busy_q);

  // The issue walker works on the oldest entry with segments left to issue.
  logic [RbtCountBits-1:0] i_pend_q;
  logic [RbtBits-1:0] i_idx_q;
  logic i_err_q, i_last_q, i_seg_start_q, i_seg_end_q;
  logic [LINE_ADDR_WIDTH-1:0] i_addr_q;
  logic [7:0] i_beat_q, i_len_q;
  logic [2:0] i_size_q;
  logic [1:0] i_burst_q;

  logic i_have, i_issue, i_advance, i_burst_end;
  assign i_have = i_pend_q != '0;
  // An error burst becomes one error segment; a memory burst's segment
  // start needs the read register, an id and a segment entry.
  assign i_issue = i_have && !i_err_q && i_seg_start_q && !rreq_valid_q && r_id_free && seg_room;
  assign i_advance = i_have && (i_err_q ? seg_room : (!i_seg_start_q || i_issue));
  assign i_burst_end = i_advance && (i_err_q || i_last_q);
  // Read IDs rotate, so a retired ID is reused last: a line ingress may hold a
  // read's ID after its last beat until its own release.
  logic [SubIdBits-1:0] r_new_sub, r_next_sub_q;
  assign r_new_sub = next_free(r_id_busy_q, r_next_sub_q);

  logic i_load, i_load_from_ar;
  logic [RbtBits-1:0] i_next_idx;
  logic [LINE_ADDR_WIDTH-1:0] i_next_addr;
  logic [7:0] i_next_len;
  logic [2:0] i_next_size;
  logic [1:0] i_next_burst;
  logic i_next_err;
  assign i_next_idx = (i_pend_q == '0) ? i_idx_q : i_idx_q + 1'b1;
  assign i_load_from_ar = (i_pend_q == '0) || (i_pend_q == RbtCountBits'(1));
  assign i_load = ((i_pend_q == '0) && ar_q_valid) ||
      (i_burst_end && ((i_pend_q > RbtCountBits'(1)) || ar_q_valid));
  assign i_next_addr = i_load_from_ar ? LINE_ADDR_WIDTH'(ar_q_addr) : rbt_addr_q[i_next_idx];
  assign i_next_len = i_load_from_ar ? ar_q_len : rbt_len_q[i_next_idx];
  assign i_next_size = i_load_from_ar ? ar_q_size : rbt_size_q[i_next_idx];
  assign i_next_burst = i_load_from_ar ? ar_q_burst : rbt_burst_q[i_next_idx];
  assign i_next_err = i_load_from_ar ? (ar_q_code != RespOkay) :
      (rbt_code_q[i_next_idx] != RespOkay);

  logic [LINE_ADDR_WIDTH-1:0] i_step_addr;
  logic i_step_last;
  assign i_step_addr = next_beat(i_addr_q, i_len_q, i_size_q, i_burst_q);
  assign i_step_last = (i_beat_q + 8'd1) == i_len_q;

  // The R path returns the head entry's beats.
  logic r_err_q, r_last_q, r_seg_end_q;
  logic [1:0] r_code_q;
  logic [ID_WIDTH-1:0] r_id_q;
  logic [LINE_ADDR_WIDTH-1:0] r_addr_q;
  logic [7:0] r_beat_q, r_len_q;
  logic [2:0] r_size_q;
  logic [1:0] r_burst_q;

  logic [SubIdBits-1:0] r_seg_sub;
  logic r_seg_err;
  assign r_seg_sub = seg_sub_q[seg_head_q];
  assign r_seg_err = seg_err_q[seg_head_q];

  // Line responses into the read buffer, by read id.
  logic [LineBits:0] rbuf_rdata;
`ifdef FORMAL
  // In formal builds the buffer is a register array with sdp_dist_ram's
  // behavior (synchronous write, asynchronous read), so the invariants can
  // name its entries.
  logic [LineBits:0] f_rbuf_q[NumSubIds];
  always_ff @(posedge i_clk) begin
    if (resp_read) f_rbuf_q[resp_sub] <= {i_line_resp_error, i_line_resp_rdata};
  end
  assign rbuf_rdata = f_rbuf_q[r_seg_sub];
`else
  sdp_dist_ram #(
      .ADDR_WIDTH(SubIdBits),
      .DATA_WIDTH(LineBits + 1)
  ) u_rbuf (
      .i_clk(i_clk),
      .i_write_enable(resp_read),
      .i_write_address(resp_sub),
      .i_read_address(r_seg_sub),
      .i_write_data({i_line_resp_error, i_line_resp_rdata}),
      .o_read_data(rbuf_rdata)
  );
`endif

  logic r_beat_ready;
  assign r_beat_ready = (rbt_count_q != '0) && (seg_count_q != '0) &&
      (r_seg_err || rbuf_valid_q[r_seg_sub]);
  assign o_axi_rvalid = !i_rst && r_beat_ready;
  assign o_axi_rid = r_id_q;
  assign o_axi_rlast = r_last_q;
  always_comb begin
    logic [WordBits-1:0] word;
    word = (WordsPerLine > 1) ? WordBits'(r_addr_q[OffsetBits-1:0] >> BusSize) : '0;
    o_axi_rdata = '0;
    if (!r_err_q) o_axi_rdata = rbuf_rdata[32'(word)*DATA_WIDTH+:DATA_WIDTH];
    if (r_err_q) o_axi_rresp = r_code_q;
    else o_axi_rresp = rbuf_rdata[LineBits] ? RespSlvErr : RespOkay;
  end
  logic r_fire, r_seg_done, r_burst_done;
  assign r_fire = o_axi_rvalid && i_axi_rready;
  // An error burst's single segment covers all of its beats.
  assign r_seg_done = r_fire && (r_err_q ? r_last_q : r_seg_end_q);
  assign r_burst_done = r_fire && r_last_q;

  logic r_load, r_load_from_ar;
  logic [RbtBits-1:0] r_next_idx;
  logic [LINE_ADDR_WIDTH-1:0] r_next_addr;
  logic [7:0] r_next_len;
  logic [2:0] r_next_size;
  logic [1:0] r_next_burst;
  logic [1:0] r_next_code;
  logic [ID_WIDTH-1:0] r_next_id;
  assign r_next_idx = (rbt_count_q == '0) ? rbt_head_q : rbt_head_q + 1'b1;
  assign r_load_from_ar = (rbt_count_q == '0) || (rbt_count_q == RbtCountBits'(1));
  assign r_load = ((rbt_count_q == '0) && ar_q_valid) ||
      (r_burst_done && ((rbt_count_q > RbtCountBits'(1)) || ar_q_valid));
  assign r_next_addr = r_load_from_ar ? LINE_ADDR_WIDTH'(ar_q_addr) : rbt_addr_q[r_next_idx];
  assign r_next_len = r_load_from_ar ? ar_q_len : rbt_len_q[r_next_idx];
  assign r_next_size = r_load_from_ar ? ar_q_size : rbt_size_q[r_next_idx];
  assign r_next_burst = r_load_from_ar ? ar_q_burst : rbt_burst_q[r_next_idx];
  assign r_next_code = r_load_from_ar ? ar_q_code : rbt_code_q[r_next_idx];
  assign r_next_id = r_load_from_ar ? ar_q_id : rbt_id_q[r_next_idx];

  logic [LINE_ADDR_WIDTH-1:0] r_step_addr;
  logic r_step_last;
  assign r_step_addr = next_beat(r_addr_q, r_len_q, r_size_q, r_burst_q);
  assign r_step_last = (r_beat_q + 8'd1) == r_len_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ar_q_valid    <= 1'b0;
      rbt_count_q   <= '0;
      rbt_head_q    <= '0;
      rbt_tail_q    <= '0;
      i_pend_q      <= '0;
      i_idx_q       <= '0;
      i_err_q       <= 1'b0;
      i_last_q      <= 1'b0;
      i_seg_start_q <= 1'b0;
      i_seg_end_q   <= 1'b0;
      seg_count_q   <= '0;
      seg_head_q    <= '0;
      seg_tail_q    <= '0;
      rreq_valid_q  <= 1'b0;
      r_id_busy_q   <= '0;
      r_next_sub_q  <= '0;
      rbuf_valid_q  <= '0;
      r_err_q       <= 1'b0;
      r_last_q      <= 1'b0;
      r_seg_end_q   <= 1'b0;
    end else begin
      ar_q_valid <= ar_fire;
      if (ar_fire) begin
        ar_q_id    <= i_axi_arid;
        ar_q_addr  <= i_axi_araddr;
        ar_q_len   <= i_axi_arlen;
        ar_q_size  <= i_axi_arsize;
        ar_q_burst <= i_axi_arburst;
      end
      if (ar_q_valid) begin
        rbt_id_q[rbt_tail_q]    <= ar_q_id;
        rbt_code_q[rbt_tail_q]  <= ar_q_code;
        rbt_addr_q[rbt_tail_q]  <= LINE_ADDR_WIDTH'(ar_q_addr);
        rbt_len_q[rbt_tail_q]   <= ar_q_len;
        rbt_size_q[rbt_tail_q]  <= ar_q_size;
        rbt_burst_q[rbt_tail_q] <= ar_q_burst;
        rbt_tail_q              <= rbt_tail_q + 1'b1;
      end
      rbt_count_q <= rbt_count_q + RbtCountBits'(ar_q_valid) - RbtCountBits'(r_burst_done);
      if (r_burst_done) rbt_head_q <= rbt_head_q + 1'b1;
      i_pend_q <= i_pend_q + RbtCountBits'(ar_q_valid) - RbtCountBits'(i_burst_end);

      // The issue walker.
      if (i_load) begin
        i_idx_q <= i_next_idx;
        i_err_q <= i_next_err;
        i_addr_q <= i_next_addr;
        i_beat_q <= '0;
        i_len_q <= i_next_len;
        i_size_q <= i_next_size;
        i_burst_q <= i_next_burst;
        i_last_q <= i_next_len == 8'd0;
        i_seg_start_q <= 1'b1;
        i_seg_end_q <= ends_segment(
            i_next_addr[OffsetBits-1:0], i_next_len, i_next_size, i_next_burst, i_next_len == 8'd0
        );
      end else if (i_burst_end) begin
        i_idx_q <= i_idx_q + 1'b1;
      end else if (i_advance) begin
        i_addr_q <= i_step_addr;
        i_beat_q <= i_beat_q + 8'd1;
        i_last_q <= i_step_last;
        i_seg_start_q <= i_seg_end_q;
        i_seg_end_q <= ends_segment(
            i_step_addr[OffsetBits-1:0], i_len_q, i_size_q, i_burst_q, i_step_last
        );
      end

      // Segments: pushed by the walker, popped by R.
      if (i_advance && (i_err_q || i_issue)) begin
        seg_sub_q[seg_tail_q] <= r_new_sub;
        seg_err_q[seg_tail_q] <= i_err_q;
        seg_tail_q            <= seg_tail_q + 1'b1;
      end
      seg_count_q <= seg_count_q + SegCountBits'(i_advance && (i_err_q || i_issue)) -
          SegCountBits'(r_seg_done);
      if (r_seg_done) seg_head_q <= seg_head_q + 1'b1;

      if (rreq_fire) rreq_valid_q <= 1'b0;
      if (i_issue) begin
        rreq_valid_q <= 1'b1;
        rreq_line_q <= i_addr_q[LINE_ADDR_WIDTH-1:OffsetBits];
        rreq_sub_q <= r_new_sub;
        r_next_sub_q <= r_new_sub + 1'b1;
        r_id_busy_q[r_new_sub] <= 1'b1;
      end
      if (resp_read) rbuf_valid_q[resp_sub] <= 1'b1;
      if (r_seg_done && !r_seg_err) begin
        r_id_busy_q[r_seg_sub]  <= 1'b0;
        rbuf_valid_q[r_seg_sub] <= 1'b0;
      end

      // The R path.
      if (r_load) begin
        r_err_q <= r_next_code != RespOkay;
        r_code_q <= r_next_code;
        r_id_q <= r_next_id;
        r_addr_q <= r_next_addr;
        r_beat_q <= '0;
        r_len_q <= r_next_len;
        r_size_q <= r_next_size;
        r_burst_q <= r_next_burst;
        r_last_q <= r_next_len == 8'd0;
        r_seg_end_q <= ends_segment(
            r_next_addr[OffsetBits-1:0], r_next_len, r_next_size, r_next_burst, r_next_len == 8'd0
        );
      end else if (r_fire && !r_last_q) begin
        r_addr_q <= r_step_addr;
        r_beat_q <= r_beat_q + 8'd1;
        r_last_q <= r_step_last;
        r_seg_end_q <= ends_segment(
            r_step_addr[OffsetBits-1:0], r_len_q, r_size_q, r_burst_q, r_step_last
        );
      end
    end
  end

  // ---------------------------------------------------------------------------
  // The merge onto the line port
  // ---------------------------------------------------------------------------
  // Next cycle's valids, the hold, and the starvation count decide the side
  // presented next cycle, so the line port's payload comes from registers.
  logic wreq_valid_n, rreq_valid_n, hold, sel_read_n;
  logic [StarveBits-1:0] starve_n;
  assign wreq_valid_n = (wreq_valid_q && !wreq_fire) || w_seal_any;
  assign rreq_valid_n = (rreq_valid_q && !rreq_fire) || i_issue;
  assign hold = o_line_req_valid && !i_line_req_ready;
  always_comb begin
    starve_n = starve_q;
    if (rreq_fire || !rreq_valid_q) starve_n = '0;
    else if (wreq_fire && (starve_q != StarveBits'(STARVATION_LIMIT))) starve_n = starve_q + 1'b1;
    if (hold) sel_read_n = sel_read_q;
    else
      sel_read_n = rreq_valid_n && (!wreq_valid_n || (starve_n == StarveBits'(STARVATION_LIMIT)));
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      sel_read_q <= 1'b0;
      starve_q   <= '0;
    end else begin
      sel_read_q <= sel_read_n;
      starve_q   <= starve_n;
    end
  end

  // The ignored AXI attributes.
  /* verilator lint_off UNUSEDSIGNAL */
  logic attrs_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign attrs_unused = ^{
    i_axi_awlock,
    i_axi_awcache,
    i_axi_awprot,
    i_axi_awqos,
    i_axi_arlock,
    i_axi_arcache,
    i_axi_arprot,
    i_axi_arqos,
    i_axi_wlast
  };

`ifndef SYNTHESIS
`ifndef FORMAL
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) reset_seen_q <= 1'b1;
  // Simulation-only checks of the masters and the ingress.
  always_ff @(posedge i_clk) begin
    if (reset_seen_q && !i_rst) begin
      if (w_fire && (i_axi_wlast != w_last_q))
        $error(
            "axi_coherent_bridge: WLAST %0d on beat %0d of %0d",
            i_axi_wlast,
            w_beat_q,
            32'(w_len_q) + 1
        );
      if (resp_write && !w_id_busy_q[resp_sub])
        $error("axi_coherent_bridge: write response for free id %0d", resp_sub);
      if (resp_read && (!r_id_busy_q[resp_sub] || rbuf_valid_q[resp_sub]))
        $error("axi_coherent_bridge: read response for id %0d not awaiting one", resp_sub);
    end
  end
`endif
`endif

`ifdef FORMAL
  // ---------------------------------------------------------------------------
  // Formal environment, reference model and properties
  // (formal/axi_coherent_bridge.sby). The reference follows AXI4 (IHI0022
  // A3.4) with its own formulas: beat addresses, byte lanes and legality;
  // segments as maximal runs of beats in one line (single beats when the bus
  // is as wide as a line); the bytes each segment writes; and which line
  // writes each B must wait for. Reads are checked through one arbitrary
  // byte, f_addr, whose line every read response returns as f_val, with the
  // error bit f_line_err. The p_* assertions are the properties; the h_*
  // assertions are invariants that map the reference onto the RTL's state,
  // so that all of them close by induction. These are safety properties:
  // response ordering, no duplicate responses and request conservation.
  // Eventual completion and starvation freedom are not proved; the cocotb
  // bridge benches check completion with timeouts at 256, 64 and 32 bits.
  // ---------------------------------------------------------------------------
  initial assume (i_rst);
  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // Reference queues: a power of two above either table's depth.
  localparam int unsigned FDepth = 2 * ((WRITE_BURSTS > READ_BURSTS) ? WRITE_BURSTS : READ_BURSTS);
  localparam int unsigned FBits = $clog2(FDepth);
  localparam int unsigned FCountBits = FBits + 1;
  localparam int unsigned FOpenBits = $clog2(NumSubIds + 2);
  localparam int unsigned NumLineIds = 1 << LINE_ID_BITS;
  localparam logic [ADDR_WIDTH-1:0] FBusMask = ADDR_WIDTH'(BusBytes - 1);

  function automatic logic [1:0] f_code(input logic [ADDR_WIDTH-1:0] a, input logic [7:0] len,
                                        input logic [2:0] size, input logic [1:0] burst);
    logic legal;
    logic [31:0] nbytes, beats, start;
    nbytes = 32'd1 << size;
    beats  = 32'(len) + 32'd1;
    start  = 32'(a[11:0]) & ~(nbytes - 32'd1);
    legal  = (nbytes <= BusBytes) && (burst != 2'b11);
    if (burst == BurstFixed) legal = legal && (beats <= 32'd16);
    if (burst == BurstWrap)
      legal = legal && ((beats == 2) || (beats == 4) || (beats == 8) || (beats == 16)) &&
          ((32'(a[11:0]) & (nbytes - 32'd1)) == 0);
    if (burst == BurstIncr) legal = legal && (start + (beats << size) <= 32'd4096);
    if (!legal) f_code = RespSlvErr;
    else if ((65'(a) < 65'(REGION_BASE)) || (65'(a) >= 65'(REGION_BASE) + 65'(REGION_BYTES)))
      f_code = RespDecErr;
    else f_code = RespOkay;
  endfunction

  // The address of the beat after one at a, in a burst starting at start.
  function automatic logic [ADDR_WIDTH-1:0] f_next(
      input logic [ADDR_WIDTH-1:0] a, input logic [ADDR_WIDTH-1:0] start, input logic [7:0] len,
      input logic [2:0] size, input logic [1:0] burst);
    logic [ADDR_WIDTH-1:0] nbytes, window;
    nbytes = ADDR_WIDTH'(1) << size;
    window = (ADDR_WIDTH'(len) + 1'b1) << size;  // a power of two for a legal WRAP
    if (burst == BurstFixed) f_next = a;
    else if (burst == BurstIncr) f_next = (a & ~(nbytes - 1'b1)) + nbytes;
    else f_next = (start & ~(window - 1'b1)) | ((a + nbytes) & (window - 1'b1));
  endfunction

  // The address of beat `beat` of a burst, in closed form (A3.4.1).
  function automatic logic [ADDR_WIDTH-1:0] f_beat_addr(
      input logic [ADDR_WIDTH-1:0] start, input logic [7:0] beat, input logic [7:0] len,
      input logic [2:0] size, input logic [1:0] burst);
    logic [ADDR_WIDTH-1:0] nbytes, window, offset;
    nbytes = ADDR_WIDTH'(1) << size;
    window = (ADDR_WIDTH'(len) + 1'b1) << size;
    offset = ADDR_WIDTH'(beat) << size;
    if ((burst == BurstFixed) || (beat == 8'd0)) f_beat_addr = start;
    else if (burst == BurstIncr) f_beat_addr = (start & ~(nbytes - 1'b1)) + offset;
    else f_beat_addr = (start & ~(window - 1'b1)) | ((start + offset) & (window - 1'b1));
  endfunction

  // The last beat of the segment that starts at beat `first` of a memory
  // burst: the end of the run of beats in its line, or the burst's last beat.
  function automatic logic [7:0] f_seg_last(input logic [ADDR_WIDTH-1:0] start,
                                            input logic [7:0] first, input logic [7:0] len,
                                            input logic [2:0] size, input logic [1:0] burst);
    logic [ADDR_WIDTH-1:0] a, after_line, aligned;
    logic [31:0] run, last;
    a = f_beat_addr(start, first, len, size, burst);
    after_line = (a | ADDR_WIDTH'(LineBytes - 1)) + 1'b1;
    aligned = a & ~((ADDR_WIDTH'(1) << size) - 1'b1);
    run = 32'((after_line - aligned) >> size);
    last = 32'(first) + run - 32'd1;
    if ((BusBytes == LineBytes) || (burst == BurstFixed) ||
        ((burst == BurstWrap) && (((32'(len) + 32'd1) << size) <= LineBytes)))
      f_seg_last = (BusBytes == LineBytes) ? first : len;
    else f_seg_last = (last >= 32'(len)) ? len : last[7:0];
  endfunction

  // Whether a beat at a, of `size`, carries byte b.
  function automatic logic f_covers(input logic [ADDR_WIDTH-1:0] a, input logic [2:0] size,
                                    input logic [ADDR_WIDTH-1:0] b);
    f_covers = (b >= a) && (b <= (a | ((ADDR_WIDTH'(1) << size) - 1'b1)));
  endfunction

  // The bus byte lanes a beat at a carries.
  function automatic logic [BusBytes-1:0] f_lanes(input logic [ADDR_WIDTH-1:0] a,
                                                  input logic [2:0] size);
    logic [ADDR_WIDTH-1:0] last, lane_addr;
    last = a | ((ADDR_WIDTH'(1) << size) - 1'b1);
    for (int b = 0; b < int'(BusBytes); b++) begin
      lane_addr  = (a & ~FBusMask) | ADDR_WIDTH'(b);
      f_lanes[b] = (lane_addr >= a) && (lane_addr <= last);
    end
  endfunction

  // Whether the beat at a is the last of its segment.
  function automatic logic f_seg_end(
      input logic [ADDR_WIDTH-1:0] a, input logic [ADDR_WIDTH-1:0] start, input logic [7:0] len,
      input logic [2:0] size, input logic [1:0] burst, input logic last);
    logic [ADDR_WIDTH-1:0] n;
    n = f_next(a, start, len, size, burst);
    f_seg_end = (BusBytes == LineBytes) || last ||
        (n[ADDR_WIDTH-1:OffsetBits] != a[ADDR_WIDTH-1:OffsetBits]);
  endfunction

  function automatic logic [LineBits-1:0] f_masked(input logic [LineBits-1:0] data,
                                                   input logic [LineBytes-1:0] strb);
    for (int b = 0; b < int'(LineBytes); b++) f_masked[b*8+:8] = strb[b] ? data[b*8+:8] : 8'h00;
  endfunction

  (* anyconst *) logic [ADDR_WIDTH-1:0] f_addr;
  (* anyconst *) logic [7:0] f_val;
  (* anyconst *) logic f_line_err;
  always_comb begin
    assume ((65'(f_addr) >= 65'(REGION_BASE)) &&
            (65'(f_addr) < 65'(REGION_BASE) + 65'(REGION_BYTES)));
  end
  logic [LineAddrBits-1:0] f_line;
  logic [  OffsetBits-1:0] f_off;
  assign f_line = f_addr[LINE_ADDR_WIDTH-1:OffsetBits];
  assign f_off  = f_addr[OffsetBits-1:0];

  // ---- the AXI4 master ---------------------------------------------------------
  always @(posedge i_clk) begin
    if (i_rst) begin
      assume (!i_axi_awvalid && !i_axi_wvalid && !i_axi_arvalid);
    end else if (f_past_valid && !$past(i_rst)) begin
      if ($past(i_axi_awvalid && !o_axi_awready))
        assume (i_axi_awvalid && $stable(
            {i_axi_awid, i_axi_awaddr, i_axi_awlen, i_axi_awsize, i_axi_awburst}
        ));
      if ($past(i_axi_wvalid && !o_axi_wready))
        assume (i_axi_wvalid && $stable({i_axi_wdata, i_axi_wstrb, i_axi_wlast}));
      if ($past(i_axi_arvalid && !o_axi_arready))
        assume (i_axi_arvalid && $stable(
            {i_axi_arid, i_axi_araddr, i_axi_arlen, i_axi_arsize, i_axi_arburst}
        ));
    end
  end

  // ---- the ingress: answers only ids in flight, a cycle or more later ----------
  logic [NumLineIds-1:0] f_out_q;  // ids in flight
  logic [NumLineIds-1:0] f_rline_f_q;  // reads in flight of f_line, by id
  always @(posedge i_clk) begin
    if (i_rst) begin
      f_out_q <= '0;
      f_rline_f_q <= '0;
    end else begin
      if (i_line_resp_valid) f_out_q[i_line_resp_id] <= 1'b0;
      if (line_fire) begin
        f_out_q[o_line_req_id] <= 1'b1;
        f_rline_f_q[o_line_req_id] <= !o_line_req_write &&
            (o_line_req_addr[LINE_ADDR_WIDTH-1:OffsetBits] == f_line);
      end
    end
  end
  always_comb begin
    if (i_rst || !f_past_valid) assume (!i_line_resp_valid);
    if (i_line_resp_valid) assume (f_out_q[i_line_resp_id]);
    if (i_line_resp_valid && f_rline_f_q[i_line_resp_id])
      assume ((i_line_resp_rdata[32'(f_off)*8+:8] == f_val) && (i_line_resp_error == f_line_err));
  end

  // ---- reference: write bursts -------------------------------------------------
  // Accepted AWs from the oldest without a B; the W beats arriving belong to
  // the oldest whose beats are not all in, f_wi.
  logic [ID_WIDTH-1:0] f_aw_id[FDepth];
  logic [ADDR_WIDTH-1:0] f_aw_addr[FDepth];
  logic [7:0] f_aw_len[FDepth];
  logic [2:0] f_aw_size[FDepth];
  logic [1:0] f_aw_burst[FDepth], f_aw_code[FDepth];
  logic [FDepth-1:0] f_aw_wdone, f_aw_err;
  logic [FOpenBits-1:0] f_aw_open[FDepth];  // sealed line writes not yet answered
  logic [FBits-1:0] f_aw_head, f_aw_tail, f_wi;
  logic [FCountBits-1:0] f_aw_count, f_aw_wpend;
  logic [7:0] f_w_beat;
  logic [ADDR_WIDTH-1:0] f_w_addr;
  // The open segment's strobed bytes, and a sealed segment awaiting its
  // line request.
  logic [LineBits-1:0] f_seg_data_q, f_due_data_q;
  logic [LineBytes-1:0] f_seg_strb_q, f_due_strb_q;
  logic f_due_q;
  logic [LineAddrBits-1:0] f_due_line_q;
  logic [FBits-1:0] f_due_ref_q;
  logic [FBits-1:0] f_wid_ref_q[NumSubIds];  // the burst of each write id in flight
  assign f_aw_tail = f_aw_head + FBits'(f_aw_count);
  assign f_wi = f_aw_head + FBits'(f_aw_count - f_aw_wpend);

  // The W beat on the bus now, as the reference sees it.
  logic [ADDR_WIDTH-1:0] f_wb_addr;
  logic f_wb_mem, f_wb_last, f_wb_seg_end, f_wb_seal;
  logic [ BusBytes-1:0] f_wb_lanes;
  logic [ LineBits-1:0] f_mrg_data;
  logic [LineBytes-1:0] f_mrg_strb;
  always_comb begin
    f_wb_addr = (f_w_beat == '0) ? f_aw_addr[f_wi] : f_w_addr;
    f_wb_mem = f_aw_code[f_wi] == RespOkay;
    f_wb_last = f_w_beat == f_aw_len[f_wi];
    f_wb_seg_end = f_seg_end(f_wb_addr, f_aw_addr[f_wi], f_aw_len[f_wi], f_aw_size[f_wi],
                             f_aw_burst[f_wi], f_wb_last);
    f_wb_lanes = f_lanes(f_wb_addr, f_aw_size[f_wi]);
    for (int b = 0; b < int'(LineBytes); b++) begin
      if (((32'(b) / BusBytes) == (32'(f_wb_addr[OffsetBits-1:0]) / BusBytes)) &&
          i_axi_wstrb[b%BusBytes] && f_wb_lanes[b%BusBytes]) begin
        f_mrg_data[b*8+:8] = i_axi_wdata[(b%BusBytes)*8+:8];
        f_mrg_strb[b] = 1'b1;
      end else begin
        f_mrg_data[b*8+:8] = f_seg_data_q[b*8+:8];
        f_mrg_strb[b] = f_seg_strb_q[b];
      end
    end
    f_wb_seal = w_fire && f_wb_mem && f_wb_seg_end && (|f_mrg_strb);
  end

  logic f_wresp;
  logic [SubIdBits-1:0] f_wresp_sub;
  assign f_wresp = i_line_resp_valid && !i_line_resp_id[LINE_ID_BITS-1];
  assign f_wresp_sub = i_line_resp_id[SubIdBits-1:0];

  always @(posedge i_clk) begin
    if (i_rst) begin
      f_aw_head  <= '0;
      f_aw_count <= '0;
      f_aw_wpend <= '0;
      f_aw_wdone <= '0;
      f_aw_err   <= '0;
      for (int k = 0; k < int'(FDepth); k++) f_aw_open[k] <= '0;
      f_w_beat <= '0;
      f_seg_strb_q <= '0;
      f_due_q <= 1'b0;
    end else begin
      if (aw_fire) begin
        f_aw_id[f_aw_tail] <= i_axi_awid;
        f_aw_addr[f_aw_tail] <= i_axi_awaddr;
        f_aw_len[f_aw_tail] <= i_axi_awlen;
        f_aw_size[f_aw_tail] <= i_axi_awsize;
        f_aw_burst[f_aw_tail] <= i_axi_awburst;
        f_aw_code[f_aw_tail] <= f_code(i_axi_awaddr, i_axi_awlen, i_axi_awsize, i_axi_awburst);
        f_aw_wdone[f_aw_tail] <= 1'b0;
        f_aw_err[f_aw_tail] <= 1'b0;
      end
      f_aw_count <= f_aw_count + FCountBits'(aw_fire) - FCountBits'(b_fire);
      f_aw_wpend <= f_aw_wpend + FCountBits'(aw_fire) - FCountBits'(w_fire && f_wb_last);
      if (b_fire) f_aw_head <= f_aw_head + 1'b1;
      if (w_fire) begin
        f_w_addr <= f_next(
            f_wb_addr, f_aw_addr[f_wi], f_aw_len[f_wi], f_aw_size[f_wi], f_aw_burst[f_wi]
        );
        f_w_beat <= f_wb_last ? 8'd0 : f_w_beat + 8'd1;
        if (f_wb_last) f_aw_wdone[f_wi] <= 1'b1;
        if (f_wb_mem) begin
          f_seg_data_q <= f_mrg_data;
          f_seg_strb_q <= f_wb_seg_end ? '0 : f_mrg_strb;
        end
      end
      if (wreq_fire) begin
        f_due_q <= 1'b0;
        f_wid_ref_q[o_line_req_id[SubIdBits-1:0]] <= f_due_ref_q;
      end
      if (f_wb_seal) begin
        f_due_q <= 1'b1;
        f_due_line_q <= f_wb_addr[LINE_ADDR_WIDTH-1:OffsetBits];
        f_due_data_q <= f_mrg_data;
        f_due_strb_q <= f_mrg_strb;
        f_due_ref_q <= f_wi;
      end
      if (f_wresp && i_line_resp_error) f_aw_err[f_wid_ref_q[f_wresp_sub]] <= 1'b1;
      for (int k = 0; k < int'(FDepth); k++) begin
        if (aw_fire && (f_aw_tail == FBits'(k))) f_aw_open[k] <= '0;
        else
          f_aw_open[k] <= f_aw_open[k] + FOpenBits'(f_wb_seal && (f_wi == FBits'(k))) -
              FOpenBits'(f_wresp && (f_wid_ref_q[f_wresp_sub] == FBits'(k)));
      end
    end
  end

  // ---- reference: read bursts ----------------------------------------------------
  logic [ID_WIDTH-1:0] f_ar_id[FDepth];
  logic [ADDR_WIDTH-1:0] f_ar_addr[FDepth];
  logic [7:0] f_ar_len[FDepth];
  logic [2:0] f_ar_size[FDepth];
  logic [1:0] f_ar_burst[FDepth], f_ar_code[FDepth];
  logic [FBits-1:0] f_ar_head, f_ar_tail;
  logic [FCountBits-1:0] f_ar_count;
  logic [7:0] f_r_beat;
  logic [ADDR_WIDTH-1:0] f_r_addr, f_rb_addr;
  logic f_rb_last, f_rb_seg_end;
  assign f_ar_tail = f_ar_head + FBits'(f_ar_count);
  assign f_rb_addr = (f_r_beat == '0) ? f_ar_addr[f_ar_head] : f_r_addr;
  assign f_rb_last = f_r_beat == f_ar_len[f_ar_head];
  assign f_rb_seg_end = f_seg_end(
      f_rb_addr,
      f_ar_addr[f_ar_head],
      f_ar_len[f_ar_head],
      f_ar_size[f_ar_head],
      f_ar_burst[f_ar_head],
      f_rb_last
  );
  always @(posedge i_clk) begin
    if (i_rst) begin
      f_ar_head  <= '0;
      f_ar_count <= '0;
      f_r_beat   <= '0;
    end else begin
      if (ar_fire) begin
        f_ar_id[f_ar_tail] <= i_axi_arid;
        f_ar_addr[f_ar_tail] <= i_axi_araddr;
        f_ar_len[f_ar_tail] <= i_axi_arlen;
        f_ar_size[f_ar_tail] <= i_axi_arsize;
        f_ar_burst[f_ar_tail] <= i_axi_arburst;
        f_ar_code[f_ar_tail] <= f_code(i_axi_araddr, i_axi_arlen, i_axi_arsize, i_axi_arburst);
      end
      f_ar_count <= f_ar_count + FCountBits'(ar_fire) - FCountBits'(r_fire && f_rb_last);
      if (r_fire) begin
        f_r_addr <= f_next(
            f_rb_addr,
            f_ar_addr[f_ar_head],
            f_ar_len[f_ar_head],
            f_ar_size[f_ar_head],
            f_ar_burst[f_ar_head]
        );
        f_r_beat <= f_rb_last ? 8'd0 : f_r_beat + 8'd1;
        if (f_rb_last) f_ar_head <= f_ar_head + 1'b1;
      end
    end
  end

  // ---- properties ----------------------------------------------------------------
  always_comb begin
    if (i_rst) begin
      p_quiet_in_reset :
      assert (!o_axi_awready && !o_axi_wready && !o_axi_arready && !o_axi_bvalid &&
              !o_axi_rvalid && !o_line_req_valid);
    end
    if (!i_rst && f_past_valid) begin
      p_tables_bounded :
      assert ((32'(f_aw_count) <= WRITE_BURSTS) && (32'(f_ar_count) <= READ_BURSTS));
      if (w_fire) p_w_after_aw : assert (f_aw_wpend != '0);
      if (o_axi_bvalid) begin
        p_b_order : assert ((f_aw_count != '0) && (o_axi_bid == f_aw_id[f_aw_head]));
        p_b_after_w : assert (f_aw_wdone[f_aw_head]);
        p_b_after_lines : assert (f_aw_open[f_aw_head] == '0);
        p_b_code :
        assert (o_axi_bresp == ((f_aw_code[f_aw_head] != RespOkay) ? f_aw_code[f_aw_head] :
                                (f_aw_err[f_aw_head] ? RespSlvErr : RespOkay)));
      end
      if (o_axi_rvalid) begin
        p_r_order : assert ((f_ar_count != '0) && (o_axi_rid == f_ar_id[f_ar_head]));
        p_r_last : assert (o_axi_rlast == f_rb_last);
        if (f_ar_code[f_ar_head] != RespOkay) begin
          p_r_error_code : assert ((o_axi_rresp == f_ar_code[f_ar_head]) && (o_axi_rdata == '0));
        end else begin
          p_r_memory_code : assert ((o_axi_rresp == RespOkay) || (o_axi_rresp == RespSlvErr));
          if (f_covers(f_rb_addr, f_ar_size[f_ar_head], f_addr)) begin
            p_r_line_code : assert (o_axi_rresp == (f_line_err ? RespSlvErr : RespOkay));
            if (!f_line_err) p_r_data : assert (o_axi_rdata[(f_addr%BusBytes)*8+:8] == f_val);
          end
        end
      end
      if (o_line_req_valid) begin
        p_line_aligned : assert (o_line_req_addr[OffsetBits-1:0] == '0);
        p_line_in_region :
        assert ((65'(o_line_req_addr) >= 65'(REGION_BASE)) &&
                                   (65'(o_line_req_addr) < 65'(REGION_BASE) + 65'(REGION_BYTES)));
        p_line_id_free : assert (!f_out_q[o_line_req_id]);
      end
      // Each line write is the next sealed segment: its line, exactly its
      // strobed bytes, and their data from the last beat that strobed each.
      if (o_line_req_valid && o_line_req_write) begin
        p_write_is_due : assert (f_due_q);
        p_write_line :
        assert ((o_line_req_addr[LINE_ADDR_WIDTH-1:OffsetBits] == f_due_line_q) &&
                (o_line_req_wstrb == f_due_strb_q) &&
                (f_masked(
            o_line_req_wdata, o_line_req_wstrb
        ) == f_masked(
            f_due_data_q, f_due_strb_q
        )));
      end
      if (f_wb_seal) p_one_segment_waits : assert (!f_due_q);
    end
  end

  always @(posedge i_clk) begin
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(o_axi_bvalid && !i_axi_bready))
        p_b_held : assert (o_axi_bvalid && $stable({o_axi_bid, o_axi_bresp}));
      if ($past(o_axi_rvalid && !i_axi_rready))
        p_r_held :
        assert (o_axi_rvalid && $stable({o_axi_rid, o_axi_rdata, o_axi_rresp, o_axi_rlast}));
      if ($past(o_line_req_valid && !i_line_req_ready)) begin
        p_line_held :
        assert (o_line_req_valid && $stable(
            {o_line_req_write, o_line_req_addr, o_line_req_id}
        ) && (!o_line_req_write || $stable(
            {o_line_req_wdata, o_line_req_wstrb}
        )));
      end
    end
  end

  // ---- the reference mapped onto the RTL -------------------------------------------
  // Indexes and offsets are sized variables, so every sum wraps at its width.
  logic [WbtBits-1:0] f_wbt_idx[WRITE_BURSTS];  // the j-th oldest write burst's table entry
  logic [  FBits-1:0] f_aw_idx [WRITE_BURSTS];  // and its reference entry
  logic [RbtBits-1:0] f_rbt_idx[ READ_BURSTS];
  logic [  FBits-1:0] f_ar_idx [ READ_BURSTS];
  logic [FBits-1:0] f_aw_newest, f_ar_newest, f_due_off;
  logic [WbtBits-1:0] f_w_engine_idx, f_due_entry_off;
  logic [FBits-1:0] f_wid_off[NumSubIds];
  logic [WbtBits-1:0] f_wid_entry_off[NumSubIds];
  logic [31:0] f_open_count[WRITE_BURSTS];  // line writes in flight or due, by burst
  logic [WbtBits-1:0] f_wbt_tail;
  logic f_w_prev_end;  // whether the previous W beat of this burst ended a segment
  logic [RbtBits-1:0] f_rbt_tail;
  logic [SegBits-1:0] f_seg_tail;
  logic [RbtBits-1:0] f_i_idx;  // the walker's entry
  logic f_i_prev_end;  // whether the walker's previous beat ended a segment
  logic [ADDR_WIDTH-1:0] f_i_prev_addr;
  always_comb begin
    for (int j = 0; j < int'(WRITE_BURSTS); j++) begin
      f_wbt_idx[j] = wbt_head_q + WbtBits'(j);
      f_aw_idx[j]  = f_aw_head + FBits'(j);
    end
    for (int j = 0; j < int'(READ_BURSTS); j++) begin
      f_rbt_idx[j] = rbt_head_q + RbtBits'(j);
      f_ar_idx[j]  = f_ar_head + FBits'(j);
    end
    f_aw_newest = f_aw_tail - 1'b1;
    f_wbt_tail = wbt_head_q + WbtBits'(wbt_count_q);
    f_w_prev_end = f_seg_end(
      f_beat_addr(
        f_aw_addr[f_wi], f_w_beat - 8'd1, f_aw_len[f_wi], f_aw_size[f_wi], f_aw_burst[f_wi]
      ),
      f_aw_addr[f_wi],
      f_aw_len[f_wi],
      f_aw_size[f_wi],
      f_aw_burst[f_wi],
      1'b0
    );
    f_rbt_tail = rbt_head_q + RbtBits'(rbt_count_q);
    f_seg_tail = seg_head_q + SegBits'(seg_count_q);
    f_ar_newest = f_ar_tail - 1'b1;
    f_w_engine_idx = wbt_head_q + WbtBits'(wbt_count_q - w_pend_q);
    f_i_idx = rbt_head_q + RbtBits'(rbt_count_q - i_pend_q);
    f_i_prev_addr = f_beat_addr(ADDR_WIDTH'(rbt_addr_q[f_i_idx]), i_beat_q - 8'd1, i_len_q,
                                i_size_q, i_burst_q);
    f_i_prev_end = f_seg_end(f_i_prev_addr, ADDR_WIDTH'(rbt_addr_q[f_i_idx]), i_len_q, i_size_q,
                             i_burst_q, 1'b0);
    f_due_off = f_due_ref_q - f_aw_head;
    f_due_entry_off = w_id_burst_q[wreq_sub_q] - wbt_head_q;
    for (int n = 0; n < int'(NumSubIds); n++) begin
      f_wid_off[n] = f_wid_ref_q[n] - f_aw_head;
      f_wid_entry_off[n] = w_id_burst_q[n] - wbt_head_q;
    end
    for (int j = 0; j < int'(WRITE_BURSTS); j++) begin
      f_open_count[j] = 32'(f_due_q && (f_due_ref_q == f_aw_idx[j]));
      for (int n = 0; n < int'(NumSubIds); n++)
      f_open_count[j] += 32'(f_out_q[n] && (f_wid_ref_q[n] == f_aw_idx[j]));
    end
  end

  always_comb begin
    if (!i_rst && f_past_valid) begin
      // The RTL's own queues.
      h_queues :
      assert ((wbt_tail_q == f_wbt_tail) && (32'(wbt_count_q) <= WRITE_BURSTS) &&
              (rbt_tail_q == f_rbt_tail) && (32'(rbt_count_q) <= READ_BURSTS) &&
              (seg_tail_q == f_seg_tail) && (32'(seg_count_q) <= SegDepth));
      for (int j = 0; j < int'(WRITE_BURSTS); j++) begin
        // h_w_free_entry: a free entry has no line writes open
        if (32'(j) >= 32'(wbt_count_q)) assert (wbt_out_q[f_wbt_idx[j]] == '0);
      end
      // Write bursts: the table, then the input register.
      h_w_count : assert (32'(f_aw_count) == 32'(wbt_count_q) + 32'(aw_q_valid));
      h_w_pend : assert (32'(f_aw_wpend) == 32'(w_pend_q) + 32'(aw_q_valid));
      h_w_pend_bound : assert (f_aw_wpend <= f_aw_count);
      for (int j = 0; j < int'(WRITE_BURSTS); j++) begin
        if (32'(j) < 32'(f_aw_count)) begin
          // h_w_done_order: bursts whose beats are all in come first
          assert (f_aw_wdone[f_aw_idx[j]] == (32'(j) < 32'(f_aw_count - f_aw_wpend)));
          // h_w_open_count: a burst's open line writes are the due one and the ids
          assert (32'(f_aw_open[f_aw_idx[j]]) == f_open_count[j]);
          // h_w_ref_code: each burst keeps the code its geometry gives
          assert (f_aw_code[f_aw_idx[j]] == f_code(
              f_aw_addr[f_aw_idx[j]],
              f_aw_len[f_aw_idx[j]],
              f_aw_size[f_aw_idx[j]],
              f_aw_burst[f_aw_idx[j]]
          ));
        end
      end
      for (int j = 0; j < int'(WRITE_BURSTS); j++) begin
        if (32'(j) < 32'(wbt_count_q)) begin
          // h_w_entry
          assert ((wbt_id_q[f_wbt_idx[j]] == f_aw_id[f_aw_idx[j]]) &&
                  (wbt_code_q[f_wbt_idx[j]] == f_aw_code[f_aw_idx[j]]) &&
                  (wbt_addr_q[f_wbt_idx[j]] == LINE_ADDR_WIDTH'(f_aw_addr[f_aw_idx[j]])) &&
                  (wbt_len_q[f_wbt_idx[j]] == f_aw_len[f_aw_idx[j]]) &&
                  (wbt_size_q[f_wbt_idx[j]] == f_aw_size[f_aw_idx[j]]) &&
                  (wbt_burst_q[f_wbt_idx[j]] == f_aw_burst[f_aw_idx[j]]) &&
                  (wbt_done_q[f_wbt_idx[j]] == f_aw_wdone[f_aw_idx[j]]) &&
                  (wbt_err_q[f_wbt_idx[j]] == f_aw_err[f_aw_idx[j]]) &&
                  (32'(wbt_out_q[f_wbt_idx[j]]) == 32'(f_aw_open[f_aw_idx[j]])));
        end
      end
      if (aw_q_valid) begin
        h_w_input :
        assert ((aw_q_id == f_aw_id[f_aw_newest]) && (aw_q_addr == f_aw_addr[f_aw_newest]) &&
                (aw_q_len == f_aw_len[f_aw_newest]) && (aw_q_size == f_aw_size[f_aw_newest]) &&
                (aw_q_burst == f_aw_burst[f_aw_newest]) &&
                (aw_q_code == f_aw_code[f_aw_newest]) && !f_aw_wdone[f_aw_newest] &&
                !f_aw_err[f_aw_newest] && (f_aw_open[f_aw_newest] == '0));
      end
      // The W engine: on the oldest entry with W beats left, or the next
      // one to be allocated.
      h_w_index : assert ((w_idx_q == f_w_engine_idx) && (w_pend_q <= wbt_count_q));
      // A segment is open only inside a memory burst, after its first beat.
      if ((f_aw_wpend == '0) || !f_wb_mem || (f_w_beat == '0) || f_w_prev_end) begin
        h_w_no_open_segment : assert (f_seg_strb_q == '0);
      end
      if (w_pend_q == '0) begin
        h_w_idle : assert (f_w_beat == '0);
      end else begin
        h_w_engine :
        assert ((w_beat_q == f_w_beat) &&
                (w_len_q == f_aw_len[f_wi]) && (w_size_q == f_aw_size[f_wi]) &&
                (w_burst_q == f_aw_burst[f_wi]) && (w_err_q == !f_wb_mem) &&
                (w_last_q == f_wb_last));
        if (!w_err_q) begin
          h_w_beat :
          assert ((w_addr_q == LINE_ADDR_WIDTH'(f_wb_addr)) && (w_seg_end_q == f_wb_seg_end) &&
                  (w_lanes_q == f_wb_lanes));
        end
      end
      if (WordsPerLine > 1) begin
        h_w_assembly :
        assert ((asm_strb_q == f_seg_strb_q) && (f_masked(
            asm_data_q, asm_strb_q
        ) == f_masked(
            f_seg_data_q, f_seg_strb_q
        )));
      end
      h_w_due : assert (wreq_valid_q == f_due_q);
      if (f_due_q) begin
        h_w_due_in_region :
        assert ((65'({f_due_line_q, {OffsetBits{1'b0}}}) >= 65'(REGION_BASE)) &&
                (65'({f_due_line_q, {OffsetBits{1'b0}}}) < 65'(REGION_BASE) + 65'(REGION_BYTES)));
      end
      if (rreq_valid_q) begin
        h_r_req_in_region :
        assert ((65'({rreq_line_q, {OffsetBits{1'b0}}}) >= 65'(REGION_BASE)) &&
                (65'({rreq_line_q, {OffsetBits{1'b0}}}) < 65'(REGION_BASE) + 65'(REGION_BYTES)));
      end
      if (f_due_q) begin
        h_w_due_line :
        assert ((wreq_line_q == f_due_line_q) && (wreq_strb_q == f_due_strb_q) && (f_masked(
            wreq_data_q, wreq_strb_q
        ) == f_masked(
            f_due_data_q, f_due_strb_q
        )) && w_id_busy_q[wreq_sub_q] && (32'(f_due_off) < 32'(wbt_count_q)) &&
            (32'(f_due_entry_off) == 32'(f_due_off)));
      end
      for (int n = 0; n < int'(NumSubIds); n++) begin
        // h_w_id_out
        assert (f_out_q[n] == (w_id_busy_q[n] && !(f_due_q && (wreq_sub_q == SubIdBits'(n)))));
        if (f_out_q[n]) begin
          // h_w_id_burst
          assert ((32'(f_wid_off[n]) < 32'(wbt_count_q)) &&
                  (32'(f_wid_entry_off[n]) == 32'(f_wid_off[n])));
        end
      end
      if ((f_aw_wpend != '0) && f_wb_mem) begin
        h_w_beat_closed :
        assert ((f_w_beat <= f_aw_len[f_wi]) && (f_wb_addr == f_beat_addr(
            f_aw_addr[f_wi], f_w_beat, f_aw_len[f_wi], f_aw_size[f_wi], f_aw_burst[f_wi]
        )));
      end
      // Read bursts and the R path.
      h_r_count : assert (32'(f_ar_count) == 32'(rbt_count_q) + 32'(ar_q_valid));
      if ((f_ar_count != '0) && (f_ar_code[f_ar_head] == RespOkay)) begin
        h_r_beat_closed :
        assert ((f_r_beat <= f_ar_len[f_ar_head]) && (f_rb_addr == f_beat_addr(
            f_ar_addr[f_ar_head],
            f_r_beat,
            f_ar_len[f_ar_head],
            f_ar_size[f_ar_head],
            f_ar_burst[f_ar_head]
        )));
      end
      // The issue walker: on the oldest table entry with segments left, or
      // the next one to be allocated.
      h_i_index : assert ((i_idx_q == f_i_idx) && (i_pend_q <= rbt_count_q));
      if (i_pend_q != '0) begin
        h_i_entry :
        assert ((i_len_q == rbt_len_q[f_i_idx]) &&
                (i_size_q == rbt_size_q[f_i_idx]) && (i_burst_q == rbt_burst_q[f_i_idx]) &&
                (i_err_q == (rbt_code_q[f_i_idx] != RespOkay)) &&
                (i_last_q == (i_beat_q == i_len_q)) &&
                (i_beat_q <= i_len_q));
        if (!i_err_q) begin
          h_i_beat :
          assert ((ADDR_WIDTH'(i_addr_q) == f_beat_addr(
              ADDR_WIDTH'(rbt_addr_q[f_i_idx]), i_beat_q, i_len_q, i_size_q, i_burst_q
          )) && (i_seg_end_q == f_seg_end(
              ADDR_WIDTH'(i_addr_q),
              ADDR_WIDTH'(rbt_addr_q[f_i_idx]),
              i_len_q,
              i_size_q,
              i_burst_q,
              i_last_q
          )) && (i_seg_start_q == ((i_beat_q == 8'd0) || f_i_prev_end)));
        end
      end
      // Each read id is waiting for its request's handshake, its response, or
      // its segment's R beats, exactly one of them.
      for (int n = 0; n < int'(NumSubIds); n++) begin
        // h_r_id
        assert (r_id_busy_q[n] ==
                (f_out_q[NumSubIds+n] || rbuf_valid_q[n] ||
                 (rreq_valid_q && (rreq_sub_q == SubIdBits'(n)))));
        // h_r_id_one
        assert ((32'(f_out_q[NumSubIds+n]) + 32'(rbuf_valid_q[n]) +
                 32'(rreq_valid_q && (rreq_sub_q == SubIdBits'(n)))) <= 1);
      end
      for (int j = 0; j < int'(READ_BURSTS); j++) begin
        // h_r_ref_code
        if (32'(j) < 32'(f_ar_count))
          assert (f_ar_code[f_ar_idx[j]] == f_code(
              f_ar_addr[f_ar_idx[j]],
              f_ar_len[f_ar_idx[j]],
              f_ar_size[f_ar_idx[j]],
              f_ar_burst[f_ar_idx[j]]
          ));
      end
      for (int j = 0; j < int'(READ_BURSTS); j++) begin
        if (32'(j) < 32'(rbt_count_q)) begin
          // h_r_entry
          assert ((rbt_id_q[f_rbt_idx[j]] == f_ar_id[f_ar_idx[j]]) &&
                  (rbt_code_q[f_rbt_idx[j]] == f_ar_code[f_ar_idx[j]]) &&
                  (rbt_addr_q[f_rbt_idx[j]] == LINE_ADDR_WIDTH'(f_ar_addr[f_ar_idx[j]])) &&
                  (rbt_len_q[f_rbt_idx[j]] == f_ar_len[f_ar_idx[j]]) &&
                  (rbt_size_q[f_rbt_idx[j]] == f_ar_size[f_ar_idx[j]]) &&
                  (rbt_burst_q[f_rbt_idx[j]] == f_ar_burst[f_ar_idx[j]]));
        end
      end
      if (ar_q_valid) begin
        h_r_input :
        assert ((ar_q_id == f_ar_id[f_ar_newest]) && (ar_q_addr == f_ar_addr[f_ar_newest]) &&
                (ar_q_len == f_ar_len[f_ar_newest]) && (ar_q_size == f_ar_size[f_ar_newest]) &&
                (ar_q_burst == f_ar_burst[f_ar_newest]) && (ar_q_code == f_ar_code[f_ar_newest]));
      end
      if (rbt_count_q == '0) begin
        h_r_idle : assert (f_r_beat == '0);
      end else begin
        h_r_path :
        assert ((r_id_q == f_ar_id[f_ar_head]) && (r_code_q == f_ar_code[f_ar_head]) &&
                (r_err_q == (f_ar_code[f_ar_head] != RespOkay)) && (r_beat_q == f_r_beat) &&
                (r_len_q == f_ar_len[f_ar_head]) && (r_size_q == f_ar_size[f_ar_head]) &&
                (r_burst_q == f_ar_burst[f_ar_head]) && (r_last_q == f_rb_last));
        if (!r_err_q) begin
          h_r_beat :
          assert ((r_addr_q == LINE_ADDR_WIDTH'(f_rb_addr)) && (r_seg_end_q == f_rb_seg_end));
        end
      end
    end
  end

  // ---- the read path's segments ----------------------------------------------------
  // Ghost state: each segment entry's burst (table index) and first beat,
  // the first beat of the R path's segment, and the line each read id asked
  // for. The invariants below tie the segment queue to the issue walker and
  // the R path: its entries are consecutive segments, from the one R is
  // returning to the walker's last.
  logic [RbtBits-1:0] f_seg_bidx_q[SegDepth];
  logic [7:0] f_seg_first_q[SegDepth];
  logic [7:0] f_r_first_q;
  logic [LineAddrBits-1:0] f_rid_line_q[NumSubIds];
  always @(posedge i_clk) begin
    if (i_advance && (i_err_q || i_issue)) begin
      f_seg_bidx_q[seg_tail_q]  <= i_idx_q;
      f_seg_first_q[seg_tail_q] <= i_err_q ? 8'd0 : i_beat_q;
    end
    if (i_issue) f_rid_line_q[r_new_sub] <= i_addr_q[LINE_ADDR_WIDTH-1:OffsetBits];
    if (r_load) f_r_first_q <= 8'd0;
    else if (r_fire && !r_last_q && !r_err_q && r_seg_end_q) f_r_first_q <= r_beat_q + 8'd1;
  end

  logic [SegBits-1:0] f_slot[SegDepth];
  logic [RbtBits-1:0] f_sb[SegDepth], f_succ_b[SegDepth];
  logic [7:0] f_sf[SegDepth], f_slast[SegDepth], f_succ_f[SegDepth];
  logic f_serr[SegDepth];
  logic [ADDR_WIDTH-1:0] f_sstart[SegDepth], f_sline[SegDepth];
  logic [7:0] f_r_last;
  logic [SegBits-1:0] f_tail_slot;
  logic [RbtBits-1:0] f_tail_succ_b;
  logic [7:0] f_tail_succ_f, f_walker_beat, f_tail_last;
  logic [NumSubIds-1:0] f_id_queued;
  always_comb begin
    for (int k = 0; k < int'(SegDepth); k++) begin
      f_slot[k] = seg_head_q + SegBits'(k);
      f_sb[k] = f_seg_bidx_q[f_slot[k]];
      f_sf[k] = f_seg_first_q[f_slot[k]];
      f_serr[k] = seg_err_q[f_slot[k]];
      f_sstart[k] = ADDR_WIDTH'(rbt_addr_q[f_sb[k]]);
      f_sline[k] = f_beat_addr(f_sstart[k], f_sf[k], rbt_len_q[f_sb[k]], rbt_size_q[f_sb[k]],
                               rbt_burst_q[f_sb[k]]);
      f_slast[k] = f_serr[k] ? rbt_len_q[f_sb[k]] : f_seg_last(
          f_sstart[k], f_sf[k], rbt_len_q[f_sb[k]], rbt_size_q[f_sb[k]], rbt_burst_q[f_sb[k]]);
      f_succ_b[k] = (f_slast[k] == rbt_len_q[f_sb[k]]) ? f_sb[k] + 1'b1 : f_sb[k];
      f_succ_f[k] = (f_slast[k] == rbt_len_q[f_sb[k]]) ? 8'd0 : f_slast[k] + 8'd1;
    end
    f_tail_slot   = seg_tail_q - 1'b1;
    f_tail_succ_b = f_succ_b[0];
    f_tail_succ_f = f_succ_f[0];
    f_tail_last   = f_slast[0];
    for (int k = 0; k < int'(SegDepth); k++) begin
      if (32'(k) + 1 == 32'(seg_count_q)) begin
        f_tail_succ_b = f_succ_b[k];
        f_tail_succ_f = f_succ_f[k];
        f_tail_last   = f_slast[k];
      end
    end
    f_walker_beat = (i_pend_q != '0) ? i_beat_q : 8'd0;
    f_r_last =
        f_seg_last(ADDR_WIDTH'(rbt_addr_q[rbt_head_q]), f_r_first_q, r_len_q, r_size_q, r_burst_q);
    for (int n = 0; n < int'(NumSubIds); n++) begin
      f_id_queued[n] = 1'b0;
      for (int k = 0; k < int'(SegDepth); k++)
      if ((32'(k) < 32'(seg_count_q)) && !f_serr[k] && (seg_sub_q[f_slot[k]] == SubIdBits'(n)))
        f_id_queued[n] = 1'b1;
    end
  end

  always_comb begin
    if (!i_rst && f_past_valid) begin
      for (int k = 0; k < int'(SegDepth); k++) begin
        if (32'(k) < 32'(seg_count_q)) begin
          // h_seg_entry: a live entry's burst is in the table, with its kind
          assert ((32'(RbtBits'(f_sb[k] - rbt_head_q)) < 32'(rbt_count_q)) &&
                  (f_serr[k] == (rbt_code_q[f_sb[k]] != RespOkay)) &&
                  (f_serr[k] ? (f_sf[k] == 8'd0) : (f_sf[k] <= rbt_len_q[f_sb[k]])));
          if (!f_serr[k]) begin
            // h_seg_id: its id is busy and asked for the segment's line
            assert (r_id_busy_q[seg_sub_q[f_slot[k]]] &&
                    (f_rid_line_q[seg_sub_q[f_slot[k]]] ==
                     f_sline[k][LINE_ADDR_WIDTH-1:OffsetBits]));
          end
          for (int m = 0; m < int'(SegDepth); m++) begin
            // h_seg_ids_distinct
            if ((m > k) && (32'(m) < 32'(seg_count_q)) && !f_serr[k] && !f_serr[m])
              assert (seg_sub_q[f_slot[k]] != seg_sub_q[f_slot[m]]);
          end
        end
        // h_seg_successor: consecutive entries are consecutive segments
        if (32'(k) + 1 < 32'(seg_count_q))
          assert ((f_sb[k+1] == f_succ_b[k]) && (f_sf[k+1] == f_succ_f[k]));
      end
      for (int n = 0; n < int'(NumSubIds); n++) begin
        // h_r_id_in_queue: a busy read id belongs to a live memory segment
        assert (r_id_busy_q[n] == f_id_queued[n]);
        // h_r_id_port_line
        if (f_out_q[NumSubIds+n]) assert (f_rline_f_q[NumSubIds+n] == (f_rid_line_q[n] == f_line));
        // h_r_buffer: a buffered line of f_line holds f_val and its error bit
        if (rbuf_valid_q[n] && (f_rid_line_q[n] == f_line))
          assert ((f_rbuf_q[n][32'(f_off)*8+:8] == f_val) && (f_rbuf_q[n][LineBits] == f_line_err));
      end
      if (rreq_valid_q) begin
        h_r_req_line : assert (rreq_line_q == f_rid_line_q[rreq_sub_q]);
      end
      // The head entry is the segment R is returning, and R is inside it.
      if (seg_count_q != '0) begin
        h_seg_head : assert ((f_sb[0] == rbt_head_q) && (f_sf[0] == f_r_first_q));
      end
      if (rbt_count_q != '0) begin
        if (r_err_q) begin
          h_r_in_segment_err : assert (f_r_first_q == 8'd0);
        end else begin
          h_r_in_segment :
          assert ((f_r_first_q <= r_beat_q) && (r_beat_q <= f_r_last) &&
                  (r_seg_end_q == (r_beat_q == f_r_last)));
        end
      end
      // R never passes the walker: on the same burst it is behind it, or, with
      // nothing queued, at the walker's unissued segment.
      if ((i_pend_q != '0) && (i_pend_q == rbt_count_q)) begin
        if (seg_count_q == '0) begin
          h_r_at_walker : assert ((r_beat_q == i_beat_q) && (r_beat_q == f_r_first_q));
        end else begin
          h_r_behind_walker : assert (r_beat_q < i_beat_q);
        end
      end
      // The walker is at the end of the queue.
      if (seg_count_q != '0) begin
        if ((i_pend_q != '0) && !i_seg_start_q) begin
          h_walker_mid :
          assert ((f_seg_bidx_q[f_tail_slot] == i_idx_q) && !seg_err_q[f_tail_slot] &&
                  (f_seg_first_q[f_tail_slot] <= i_beat_q) && (i_beat_q <= f_tail_last));
        end else begin
          h_walker_next : assert ((f_tail_succ_b == i_idx_q) && (f_tail_succ_f == f_walker_beat));
        end
      end else if (rbt_count_q != '0) begin
        h_walker_at_r :
        assert ((i_pend_q != '0) && (i_idx_q == rbt_head_q) && i_seg_start_q &&
                (i_beat_q == f_r_first_q));
      end
    end
  end

  always @(posedge i_clk) begin
    if (!i_rst) begin
      c_wrap_write :
      cover (b_fire && (f_aw_burst[f_aw_head] == BurstWrap) &&
                            (f_aw_code[f_aw_head] == RespOkay) && (f_aw_len[f_aw_head] >= 8'd3));
      c_narrow_incr :
      cover (b_fire && (f_aw_burst[f_aw_head] == BurstIncr) &&
                             (f_aw_code[f_aw_head] == RespOkay) &&
                             (32'(f_aw_size[f_aw_head]) < BusSize) &&
                             (f_aw_len[f_aw_head] >= 8'd4));
      c_merged_line_write :
      cover (wreq_fire && (WordsPerLine > 1) &&
                                   (o_line_req_wstrb[0] && o_line_req_wstrb[LineBytes-1]));
      c_error_read_done :
      cover (r_fire && o_axi_rlast && (f_ar_code[f_ar_head] != RespOkay) &&
                                 (f_ar_len[f_ar_head] != 8'd0));
      c_byte_read :
      cover (r_fire && (o_axi_rresp == RespOkay) && !f_line_err &&
                           (f_ar_code[f_ar_head] == RespOkay) &&
                           f_covers(
          f_rb_addr, f_ar_size[f_ar_head], f_addr
      ));
      c_read_and_write_ids_busy : cover ((&w_id_busy_q) && (&r_id_busy_q));
      c_two_line_writes_open : cover (f_aw_open[f_aw_head] == FOpenBits'(2));
      c_write_error_b :
      cover (b_fire && (o_axi_bresp == RespSlvErr) && (f_aw_code[f_aw_head] == RespOkay));
      c_read_error_r :
      cover (r_fire && (o_axi_rresp == RespSlvErr) && (f_ar_code[f_ar_head] == RespOkay));
    end
  end
`endif

endmodule : axi_coherent_bridge
