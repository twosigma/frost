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

// Reference for the coherence_array_equiv target: the array with one data
// RAM of {way, set} rows, read from an input register after the tag
// decision, and replacement state in one RAM written whole from the
// lookup's copy. coherence_array must match it cycle for cycle.
module coherence_array_reference #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned CACHE_BYTES = 128 * 1024,
    parameter int unsigned WAYS = 4,
    parameter bit BIMODAL_INSERT = 1'b0,
    parameter bit ULTRA = 1'b0,
    parameter int unsigned TAG_READ_LATENCY = ULTRA ? 3 : 1,
    parameter int unsigned DATA_READ_LATENCY = ULTRA ? 6 : 2,
    parameter int unsigned DATA_WRITE_LATENCY = ULTRA ? 2 : 1,
    parameter int unsigned SIM_FAST_MAINT = 0,
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
    input logic i_req_data_if_modified,
    // These lookups need data only on a hit, or only on a miss whose selected
    // victim is Modified. Otherwise they reply in the first data-read cycle,
    // from the registered tag result, and the data read goes unused. A
    // maintenance visit always waits for its data.
    input logic i_req_data_if_hit,
    input logic i_req_data_if_victim_modified,
    // A hit of this lookup leaves replacement state unchanged.
    input logic i_req_no_touch,
    output logic o_resp_valid,
    input logic i_resp_ready,
    output logic o_resp_hit,
    output logic o_resp_available,
    output logic [WayBits-1:0] o_resp_way,
    output logic [ADDR_WIDTH-1:0] o_resp_addr,
    output logic [1:0] o_resp_state,
    // Data is meaningful only when valid; skipped reads keep the prior data.
    output logic o_resp_data_valid,
    output logic [8*LINE_BYTES-1:0] o_resp_data,
    // An update names a complete tag and row. Writes finish before another
    // lookup can read either port, including the RAM's input registers.
    input logic i_update_valid,
    output logic o_update_ready,
    input logic [ADDR_WIDTH-1:0] i_update_addr,
    input logic [WayBits-1:0] i_update_way,
    input logic [1:0] i_update_state,
    // An insertion follows a lookup of the same set and selected way. With
    // BIMODAL_INSERT, i_update_touch makes it update replacement state.
    input logic i_update_insert,
    input logic i_update_touch,
    input logic [LINE_BYTES-1:0] i_update_mask,
    input logic [8*LINE_BYTES-1:0] i_update_data
);
`ifndef SYNTHESIS
`ifdef FORMAL
  wire sim_reset_seen_q = 1'b1;
`else
  logic sim_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) sim_reset_seen_q <= 1'b1;
`endif
`endif
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
    Data,
    Reply,
    WriteWait
  } phase_t;
  phase_t phase_q;
  logic [CountBits-1:0] count_q;
  logic [SetBits-1:0] init_set_q, set_q;
  logic [TagBits-1:0] tag_q;
  logic visit_q, skip_data_q, modified_data_q, no_touch_q, hit_data_q, victim_data_q;
  // The early reply depends only on registered request flags and tag results.
  logic data_valid_q, early_reply;
  logic [WayBits-1:0] visit_way_q;
  logic [WAYS-1:0] exclude_q;
  logic [PlruBits-1:0] plru_read, plru_q, plru_write;
  logic [15:0] insert_lfsr_q;
  logic plru_we, plru_hit_q;
  logic [WAYS-1:0] tag_we;
  logic [SetBits-1:0] tag_raddr, tag_waddr;
  logic [TagEntryBits-1:0] tag_wdata;
  logic [TagEntryBits-1:0] tag_rdata [WAYS];
`ifdef SYNTHESIS
  localparam int unsigned SimFastInit = 0;
  wire init_bulk_clear = 1'b0;
`else
  localparam int unsigned SimFastInit = SIM_FAST_MAINT;
  // Only an observed reset permits the simulation bulk clear.
  wire init_bulk_clear = SimFastInit != 0 && sim_reset_seen_q && !i_rst && phase_q == Init;
`endif

  logic hit, hit_modified;
  logic select_valid;
  logic [PlruBits-1:0] select_plru;
  logic [WayBits-1:0] selected;
  logic [RowBits-1:0] data_raddr, data_waddr;
  logic [8*LINE_BYTES-1:0] data_rdata;
  logic update_fire, request_fire, select_data;

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
  assign o_update_ready = phase_q == Idle;
  assign update_fire = i_update_valid && o_update_ready;
  assign o_req_ready = phase_q == Idle && !i_update_valid;
  assign request_fire = i_req_valid && o_req_ready;
  assign early_reply = (hit_data_q && !o_resp_hit) ||
      (victim_data_q && (o_resp_hit || o_resp_state != 2'b11));
  // An early reply holds through Reply until it is consumed.
  assign o_resp_valid = phase_q == Reply || (phase_q == Data && early_reply);
  assign o_resp_data_valid = data_valid_q && !early_reply;
  assign tag_raddr = i_req_addr[OffsetBits+:SetBits];
  assign tag_waddr = phase_q == Init ? init_set_q : i_update_addr[OffsetBits+:SetBits];
  assign tag_wdata = phase_q == Init ? '0 :
      {i_update_state, i_update_addr[ADDR_WIDTH-1:OffsetBits+SetBits]};
  // The tag and replacement RAMs have no reset, so reset gates their writes.
  for (genvar way = 0; way < WAYS; way++) begin : gen_tag_en
    assign tag_we[way] = !i_rst && (phase_q == Init ||
        (update_fire && i_update_way == WayBits'(way)));
  end

  assign select_valid = phase_q == Tags && count_q == 1;
  assign select_plru = phase_q == Tags && count_q == CountBits'(TAG_READ_LATENCY) ?
      plru_read : plru_q;
  assign plru_we = !i_rst && (phase_q == Init ||
      (update_fire && i_update_insert &&
       (!BIMODAL_INSERT || i_update_touch || insert_lfsr_q[4:0] == 0)) ||
      plru_hit_q);
  // Hit touches use the registered way during data service or the reply.
  // The metadata write finishes before another request or update can enter.
  assign plru_write = phase_q == Init ? '0 : touch(plru_q, plru_hit_q ? o_resp_way : i_update_way);
  sdp_block_ram #(
      .ADDR_WIDTH(SetBits),
      .DATA_WIDTH(PlruBits),
      .SUPPORT_BULK_CLEAR(SimFastInit)
  ) replacement (
      .i_clk(i_clk),
      .i_write_enable(plru_we),
      .i_bulk_clear(init_bulk_clear),
      .i_write_address(phase_q == Init ? init_set_q : set_q),
      .i_read_address(tag_raddr),
      .i_write_data(plru_write),
      .o_read_data(plru_read)
  );

  if (ULTRA) begin : gen_tag_ultra
    logic [WAYS*TagEntryBits-1:0] row;
    sdp_packed_tag_uram #(
        .ADDR_WIDTH(RowBits),
        .DATA_WIDTH(TagEntryBits),
        .READ_LATENCY(TAG_READ_LATENCY),
        .READ_WORDS(WAYS),
        .SUPPORT_BULK_CLEAR(SimFastInit)
    ) tags (
        .i_clk(i_clk),
        .i_write_enable(|tag_we),
        .i_bulk_clear(init_bulk_clear),
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
          .DATA_WIDTH(TagEntryBits),
          .SUPPORT_BULK_CLEAR(SimFastInit)
      ) tags (
          .i_clk(i_clk),
          .i_write_enable(tag_we[way]),
          .i_bulk_clear(init_bulk_clear),
          .i_write_address(tag_waddr),
          .i_read_address(tag_raddr),
          .i_write_data(tag_wdata),
          .o_read_data(tag_rdata[way])
      );
    end
  end

  assign data_raddr = (RowBits'(selected) << SetBits) | RowBits'(set_q);
  assign select_data = visit_q || !((hit && skip_data_q) || (modified_data_q && !hit_modified));
  assign data_waddr = (RowBits'(i_update_way) << SetBits) |
      RowBits'(i_update_addr[OffsetBits+:SetBits]);
  sdp_ram_byte_en #(
      .DATA_WIDTH(8 * LINE_BYTES),
      .ADDR_WIDTH(RowBits),
      .READ_LATENCY(DATA_READ_LATENCY),
      .WRITE_LATENCY(DATA_WRITE_LATENCY),
      .MEMORY_PRIMITIVE(ULTRA ? "ultra" : "block"),
      .REGISTER_READ_INPUT(1'b1),
      .REGISTER_READ_OUTPUT(ULTRA)
  ) data_array (
`ifndef SYNTHESIS
`ifndef FORMAL
      .i_check_enable(sim_reset_seen_q && !i_rst),
`endif
`endif
      .i_clk(i_clk),
      .i_waddr(data_waddr),
      .i_wdata(i_update_data),
      .i_wbyte_en(i_update_mask & {LINE_BYTES{update_fire}}),
      .i_re(select_valid && select_data),
      .i_raddr(data_raddr),
      .o_rdata(data_rdata)
  );

  always_comb begin
    selected = victim(select_plru, ~exclude_q);
    hit = 1'b0;
    hit_modified = 1'b0;
    for (int way = WAYS - 1; way >= 0; way--) begin
      if (tag_rdata[way][TagBits+:2] == 0 && !exclude_q[way]) selected = WayBits'(way);
    end
    for (int way = 0; way < WAYS; way++) begin
      if (tag_rdata[way][TagBits+:2] != 0 && tag_rdata[way][TagBits-1:0] == tag_q) begin
        hit = 1'b1;
        hit_modified = tag_rdata[way][TagBits+:2] == 2'b11;
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
      modified_data_q <= 1'b0;
      no_touch_q <= 1'b0;
      hit_data_q <= 1'b0;
      victim_data_q <= 1'b0;
      visit_way_q <= '0;
      exclude_q <= '0;
      plru_q <= '0;
      plru_hit_q <= 1'b0;
      insert_lfsr_q <= 16'hACE1;
      o_resp_hit <= 1'b0;
      o_resp_available <= 1'b0;
      o_resp_way <= '0;
      o_resp_addr <= '0;
      o_resp_state <= '0;
      o_resp_data <= '0;
      data_valid_q <= 1'b0;
    end else begin
      plru_hit_q <= select_valid && hit && !visit_q && !no_touch_q;
      insert_lfsr_q <= {
        insert_lfsr_q[14:0],
        insert_lfsr_q[15] ^ insert_lfsr_q[13] ^ insert_lfsr_q[12] ^ insert_lfsr_q[10]
      };
      if (phase_q == Tags && count_q == CountBits'(TAG_READ_LATENCY)) plru_q <= plru_read;
      case (phase_q)
        Init: begin
          init_set_q <= init_set_q + 1'b1;
          if (&init_set_q || init_bulk_clear) begin
            count_q <= CountBits'(DATA_WRITE_LATENCY + 1);
            phase_q <= WriteWait;
          end
        end
        Idle: begin
          // Tag and PLRU updates are visible to every later lookup, since no
          // request shares an update's cycle; only a data write waits.
          if (update_fire) begin
            if (|i_update_mask) begin
              count_q <= CountBits'(DATA_WRITE_LATENCY);
              phase_q <= WriteWait;
            end
          end else if (request_fire) begin
            set_q <= i_req_addr[OffsetBits+:SetBits];
            tag_q <= i_req_addr[ADDR_WIDTH-1:OffsetBits+SetBits];
            visit_q <= i_req_visit;
            skip_data_q <= i_req_skip_data_on_hit;
            modified_data_q <= i_req_data_if_modified;
            no_touch_q <= i_req_no_touch;
            hit_data_q <= i_req_data_if_hit && !i_req_visit;
            victim_data_q <= i_req_data_if_victim_modified && !i_req_visit;
            visit_way_q <= i_req_way;
            exclude_q <= i_req_exclude;
            count_q <= CountBits'(TAG_READ_LATENCY);
            phase_q <= Tags;
          end
        end
        Tags: begin
          count_q <= count_q - 1'b1;
          if (count_q == 1) begin
            o_resp_hit <= hit && !visit_q;
            o_resp_available <= hit || visit_q || !(&exclude_q);
            o_resp_way <= selected;
            o_resp_addr <= {tag_rdata[selected][TagBits-1:0], set_q, {OffsetBits{1'b0}}};
            o_resp_state <= tag_rdata[selected][TagBits+:2];
            data_valid_q <= select_data;
            if (!select_data) begin
              phase_q <= Reply;
            end else begin
              count_q <= CountBits'(DATA_READ_LATENCY);
              phase_q <= Data;
            end
          end
        end
        Data: begin
          count_q <= count_q - 1'b1;
          if (early_reply && i_resp_ready) phase_q <= Idle;
          else if (count_q == 1) begin
            // A held early reply keeps its data unchanged into Reply.
            if (!early_reply) o_resp_data <= data_rdata;
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
endmodule
