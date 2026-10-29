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

// One lookup owns the tag and data result until its consumer releases it.
// The controller holds replacement and coherence ownership outside this array.
module coherence_array #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned CACHE_BYTES = 128 * 1024,
    parameter int unsigned WAYS = 4,
    parameter bit BIMODAL_INSERT = 1'b0,
    parameter bit ULTRA = 1'b0,
    parameter int unsigned TAG_READ_LATENCY = ULTRA ? 3 : 1,
    parameter int unsigned DATA_READ_LATENCY = ULTRA ? 6 : 2,
    parameter int unsigned DATA_WRITE_LATENCY = ULTRA ? 2 : 1,
    localparam int unsigned OffsetBits = $clog2(LINE_BYTES),
    localparam int unsigned Sets = CACHE_BYTES / (LINE_BYTES * WAYS),
    localparam int unsigned SetBits = $clog2(Sets),
    localparam int unsigned WayBits = WAYS > 1 ? $clog2(WAYS) : 1,
    localparam int unsigned WaySelBits = $clog2(WAYS),
    localparam int unsigned RowBits = SetBits + WaySelBits
) (
    input logic i_clk,
    input logic i_rst,
    output logic o_init_done,
    input logic i_req_valid,
    output logic o_req_ready,
    input logic [ADDR_WIDTH-1:0] i_req_addr,
    input logic [WAYS-1:0] i_req_exclude,
    // A maintenance visit reads this way regardless of the address tag.
    input logic i_req_visit,
    input logic [WayBits-1:0] i_req_way,
    input logic i_req_skip_data_on_hit,
    output logic o_resp_valid,
    input logic i_resp_ready,
    output logic o_resp_hit,
    output logic o_resp_available,
    output logic [WayBits-1:0] o_resp_way,
    output logic [ADDR_WIDTH-1:0] o_resp_addr,
    output logic [1:0] o_resp_state,
    output logic o_resp_data_valid,
    output logic [8*LINE_BYTES-1:0] o_resp_data,
    // An update names a complete tag and row. Writes finish before another
    // lookup can read either port, including the RAM's input registers.
    input logic i_update_valid,
    output logic o_update_ready,
    input logic [ADDR_WIDTH-1:0] i_update_addr,
    input logic [WayBits-1:0] i_update_way,
    input logic [1:0] i_update_state,
    input logic i_update_insert,
    input logic [LINE_BYTES-1:0] i_update_mask,
    input logic [8*LINE_BYTES-1:0] i_update_data
);
  localparam int unsigned TagBits = ADDR_WIDTH - SetBits - OffsetBits;
  localparam int unsigned TagEntryBits = TagBits + 2;
  localparam int unsigned PlruBits = WAYS > 1 ? WAYS - 1 : 1;
  localparam int unsigned MaxLatency = DATA_READ_LATENCY + DATA_WRITE_LATENCY +
      TAG_READ_LATENCY + 2;
  localparam int unsigned CountBits = $clog2(MaxLatency + 1);
  typedef enum logic [3:0] {
    Init,
    Idle,
    Tags,
    Select,
    ReadData,
    Data,
    Reply,
    WriteWait
  } phase_t;
  phase_t phase_q;
  logic [CountBits-1:0] count_q;
  logic [SetBits-1:0] init_set_q, set_q;
  logic [TagBits-1:0] tag_q;
  logic visit_q, skip_data_q;
  logic [WayBits-1:0] visit_way_q;
  logic [WAYS-1:0] exclude_q;
  logic [PlruBits-1:0] plru_read, plru_q, plru_write;
  logic [15:0] insert_lfsr_q;
  logic plru_we;
  logic [WAYS-1:0] tag_we;
  logic [SetBits-1:0] tag_raddr, tag_waddr;
  logic [TagEntryBits-1:0] tag_wdata;
  logic [TagEntryBits-1:0] tag_rdata[WAYS];
  logic [TagEntryBits-1:0] tags_q[WAYS];
  logic hit;
  logic [WayBits-1:0] selected;
  logic [RowBits-1:0] data_raddr, data_waddr;
  logic [8*LINE_BYTES-1:0] data_rdata;
  logic update_fire, request_fire;

  function automatic logic [WayBits-1:0] victim(input logic [PlruBits-1:0] state,
                                                input logic [WAYS-1:0] eligible);
    int node, base, span;
    logic left_ok, right_ok, right;
    node = 1;
    base = 0;
    span = WAYS;
    for (int level = 0; level < int'(WaySelBits); level++) begin
      span = span / 2;
      left_ok = 1'b0;
      right_ok = 1'b0;
      for (int way = 0; way < WAYS; way++) begin
        if (way >= base && way < base + span) left_ok |= eligible[way];
        if (way >= base + span && way < base + 2 * span) right_ok |= eligible[way];
      end
      right = right_ok && (!left_ok || state[node-1]);
      node  = 2 * node + int'(right);
      if (right) base = base + span;
    end
    victim = WayBits'(base);
  endfunction

  function automatic logic [PlruBits-1:0] touch(input logic [PlruBits-1:0] state,
                                                input logic [WayBits-1:0] way);
    logic [PlruBits-1:0] value;
    int node;
    value = state;
    node  = 1;
    for (int level = WaySelBits - 1; level >= 0; level--) begin
      value[node-1] = !way[level];
      node = 2 * node + int'(way[level]);
    end
    touch = value;
  endfunction

  assign o_init_done = phase_q != Init;
  assign o_update_ready = !i_rst && phase_q == Idle;
  assign update_fire = i_update_valid && o_update_ready;
  assign o_req_ready = !i_rst && phase_q == Idle && !i_update_valid;
  assign request_fire = i_req_valid && o_req_ready;
  assign o_resp_valid = !i_rst && phase_q == Reply;
  assign tag_raddr = i_req_addr[OffsetBits+:SetBits];
  assign tag_waddr = phase_q == Init ? init_set_q : i_update_addr[OffsetBits+:SetBits];
  assign tag_wdata = phase_q == Init ? '0 :
      {i_update_state, i_update_addr[ADDR_WIDTH-1:OffsetBits+SetBits]};
  for (genvar way = 0; way < WAYS; way++) begin : gen_tag_en
    assign tag_we[way] = !i_rst && (phase_q == Init ||
        (update_fire && i_update_way == WayBits'(way)));
  end

  assign plru_we = !i_rst && (phase_q == Init ||
      (update_fire && i_update_insert && (!BIMODAL_INSERT || insert_lfsr_q[4:0] == 0)) ||
      (phase_q == Select && hit && !visit_q));
  assign plru_write = phase_q == Init ? '0 : touch(
      plru_q, phase_q == Select ? selected : i_update_way
  );
  sdp_block_ram #(
      .ADDR_WIDTH(SetBits),
      .DATA_WIDTH(PlruBits)
  ) replacement (
      .i_clk(i_clk),
      .i_write_enable(plru_we),
      .i_bulk_clear(1'b0),
      .i_write_address(phase_q == Init ? init_set_q : set_q),
      .i_read_address(tag_raddr),
      .i_write_data(plru_write),
      .o_read_data(plru_read)
  );

  if (ULTRA) begin : gen_tag_ultra
    logic [WAYS*TagEntryBits-1:0] row;
    sdp_packed_tag_uram #(
        .ADDR_WIDTH  (RowBits),
        .DATA_WIDTH  (TagEntryBits),
        .READ_LATENCY(TAG_READ_LATENCY),
        .READ_WORDS  (WAYS)
    ) tags (
        .i_clk(i_clk),
        .i_write_enable(|tag_we),
        .i_bulk_clear(1'b0),
        .i_write_address(RowBits'(tag_waddr) << WaySelBits),
        .i_write_word_mask(tag_we),
        .i_write_data(tag_wdata),
        .i_read_enable(request_fire),
        .i_read_address(RowBits'(tag_raddr) << WaySelBits),
        .o_read_data(row)
    );
    for (genvar way = 0; way < WAYS; way++) begin : gen_unpack
      assign tag_rdata[way] = row[way*TagEntryBits+:TagEntryBits];
    end
  end else begin : gen_tag_block
    for (genvar way = 0; way < WAYS; way++) begin : gen_way
      sdp_block_ram #(
          .ADDR_WIDTH(SetBits),
          .DATA_WIDTH(TagEntryBits)
      ) tags (
          .i_clk(i_clk),
          .i_write_enable(tag_we[way]),
          .i_bulk_clear(1'b0),
          .i_write_address(tag_waddr),
          .i_read_address(tag_raddr),
          .i_write_data(tag_wdata),
          .o_read_data(tag_rdata[way])
      );
    end
  end

  assign data_raddr = (RowBits'(o_resp_way) << SetBits) | RowBits'(set_q);
  assign data_waddr = (RowBits'(i_update_way) << SetBits) |
      RowBits'(i_update_addr[OffsetBits+:SetBits]);
  sdp_ram_byte_en #(
      .DATA_WIDTH(8 * LINE_BYTES),
      .ADDR_WIDTH(RowBits),
      .READ_LATENCY(DATA_READ_LATENCY),
      .WRITE_LATENCY(DATA_WRITE_LATENCY),
      .MEMORY_PRIMITIVE(ULTRA ? "ultra" : "block"),
      .REGISTER_READ_INPUT(ULTRA),
      .REGISTER_READ_OUTPUT(ULTRA)
  ) data_array (
      .i_clk(i_clk),
      .i_waddr(data_waddr),
      .i_wdata(i_update_data),
      .i_wbyte_en(i_update_mask & {LINE_BYTES{update_fire}}),
      .i_re(phase_q == ReadData),
      .i_raddr(data_raddr),
      .o_rdata(data_rdata)
  );

  always_comb begin
    selected = victim(plru_q, ~exclude_q);
    hit = 1'b0;
    for (int way = WAYS - 1; way >= 0; way--) begin
      if (tags_q[way][TagBits+:2] == 0 && !exclude_q[way]) selected = WayBits'(way);
    end
    for (int way = 0; way < WAYS; way++) begin
      if (tags_q[way][TagBits+:2] != 0 && tags_q[way][TagBits-1:0] == tag_q) begin
        hit = 1'b1;
        selected = WayBits'(way);
      end
    end
    if (visit_q) selected = visit_way_q;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      phase_q <= Init;
      init_set_q <= '0;
      count_q <= '0;
      set_q <= '0;
      tag_q <= '0;
      visit_q <= 1'b0;
      skip_data_q <= 1'b0;
      visit_way_q <= '0;
      exclude_q <= '0;
      plru_q <= '0;
      insert_lfsr_q <= 16'hACE1;
      o_resp_hit <= 1'b0;
      o_resp_available <= 1'b0;
      o_resp_way <= '0;
      o_resp_addr <= '0;
      o_resp_state <= '0;
      o_resp_data <= '0;
      o_resp_data_valid <= 1'b0;
      for (int way = 0; way < WAYS; way++) tags_q[way] <= '0;
    end else begin
      insert_lfsr_q <= {
        insert_lfsr_q[14:0],
        insert_lfsr_q[15] ^ insert_lfsr_q[13] ^ insert_lfsr_q[12] ^ insert_lfsr_q[10]
      };
      if (phase_q == Tags && count_q == CountBits'(TAG_READ_LATENCY)) plru_q <= plru_read;
      case (phase_q)
        Init: begin
          init_set_q <= init_set_q + 1'b1;
          if (&init_set_q) begin
            count_q <= CountBits'(DATA_WRITE_LATENCY + 1);
            phase_q <= WriteWait;
          end
        end
        Idle: begin
          if (update_fire) begin
            count_q <= CountBits'(DATA_WRITE_LATENCY);
            phase_q <= WriteWait;
          end else if (request_fire) begin
            set_q <= i_req_addr[OffsetBits+:SetBits];
            tag_q <= i_req_addr[ADDR_WIDTH-1:OffsetBits+SetBits];
            visit_q <= i_req_visit;
            skip_data_q <= i_req_skip_data_on_hit;
            visit_way_q <= i_req_way;
            exclude_q <= i_req_exclude;
            count_q <= CountBits'(TAG_READ_LATENCY);
            phase_q <= Tags;
          end
        end
        Tags: begin
          count_q <= count_q - 1'b1;
          if (count_q == 1) begin
            for (int way = 0; way < WAYS; way++) tags_q[way] <= tag_rdata[way];
            phase_q <= Select;
          end
        end
        Select: begin
          o_resp_hit <= hit && !visit_q;
          o_resp_available <= hit || visit_q || !(&exclude_q);
          o_resp_way <= selected;
          o_resp_addr <= {tags_q[selected][TagBits-1:0], set_q, {OffsetBits{1'b0}}};
          o_resp_state <= tags_q[selected][TagBits+:2];
          o_resp_data_valid <= !(hit && !visit_q && skip_data_q);
          if (hit && !visit_q && skip_data_q) begin
            o_resp_data <= '0;
            phase_q <= Reply;
          end else phase_q <= ReadData;
        end
        ReadData: begin
          count_q <= CountBits'(DATA_READ_LATENCY);
          phase_q <= Data;
        end
        Data: begin
          count_q <= count_q - 1'b1;
          if (count_q == 1) begin
            o_resp_data <= data_rdata;
            phase_q <= Reply;
          end
        end
        Reply:   if (i_resp_ready) phase_q <= Idle;
        WriteWait: begin
          count_q <= count_q - 1'b1;
          if (count_q == 1) phase_q <= Idle;
        end
        default: phase_q <= Init;
      endcase
    end
  end

  if (ADDR_WIDTH < 32 || ADDR_WIDTH > 56 || (LINE_BYTES != 32 && LINE_BYTES != 64) ||
      Sets < 2 || (Sets & (Sets - 1)) != 0 || (WAYS != 1 && WAYS != 4) ||
      CACHE_BYTES != Sets * WAYS * LINE_BYTES || DATA_READ_LATENCY < 2 ||
      DATA_WRITE_LATENCY < 1 || TAG_READ_LATENCY < 1 || (!ULTRA &&
          TAG_READ_LATENCY != 1)) begin : gen_invalid
    initial $fatal(1, "coherence_array: invalid parameters");
  end
`ifdef FORMAL
  (* anyconst *) logic [RowBits-1:0] f_row;
  (* anyconst *) logic [OffsetBits-1:0] f_byte;
  logic f_byte_known = 1'b0;
  logic [7:0] f_byte_value;
  always_ff @(posedge i_clk) begin
    if (i_rst) f_byte_known <= 1'b0;
    else if (update_fire && data_waddr == f_row && i_update_mask[f_byte]) begin
      f_byte_known <= 1'b1;
      f_byte_value <= i_update_data[8*f_byte+:8];
    end
    if (!i_rst && o_resp_valid && o_resp_data_valid &&
        ((RowBits'(o_resp_way) << SetBits) | RowBits'(set_q)) == f_row && f_byte_known)
      assert (o_resp_data[8*f_byte+:8] == f_byte_value);
  end
  logic f_past_valid = 1'b0;
  wire [ADDR_WIDTH+WayBits+11:0] f_response_signature = {
    o_resp_hit, o_resp_available, o_resp_way, o_resp_addr, o_resp_state, o_resp_data[7:0]
  };
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (i_req_valid) assume (i_req_way < WAYS);
    if (i_update_valid) assume (i_update_way < WAYS);
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(o_resp_valid && !i_resp_ready)) begin
        assert (o_resp_valid);
        assert (o_resp_data_valid == $past(o_resp_data_valid));
        assert (f_response_signature == $past(f_response_signature));
      end
      assert (!(request_fire && update_fire));
      assert (!(o_resp_valid && (o_req_ready || o_update_ready)));
      if (phase_q == Select) assert (selected < WAYS);
      if (o_resp_valid && !o_resp_data_valid) assert (o_resp_hit && skip_data_q && !visit_q);
    end
  end
`endif
endmodule
