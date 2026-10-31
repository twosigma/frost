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

// Tag decisions, row reads and masked updates have independent service ports.
module coherence_home_array #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 64,
    parameter int unsigned CACHE_BYTES = 2 * 1024 * 1024,
    parameter int unsigned WAYS = 4,
    parameter int unsigned TOKEN_BITS = 4,
    parameter bit ULTRA = 1'b1,
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
    input logic [TOKEN_BITS-1:0] i_req_token,
    output logic [ADDR_WIDTH-1:0] o_query_addr,
    input logic [WAYS-1:0] i_exclude,
    output logic o_resp_valid,
    input logic i_resp_ready,
    input logic i_resp_claim,
    output logic [TOKEN_BITS-1:0] o_resp_token,
    // The response token decoded one-hot, registered with o_resp_token.
    output logic [(1 << TOKEN_BITS)-1:0] o_resp_token_onehot,
    output logic o_resp_hit,
    output logic o_resp_available,
    output logic [WayBits-1:0] o_resp_way,
    output logic [ADDR_WIDTH-1:0] o_resp_addr,
    output logic [1:0] o_resp_state,
    // The selection's tag fields for every way, held from selection through
    // the response; o_resp_addr's tag is o_resp_tags[o_resp_way].
    output logic [WAYS-1:0][ADDR_WIDTH-SetBits-OffsetBits-1:0] o_resp_tags,
    input logic i_read_valid,
    // i_read_valid before the consumer's stop qualification. It decides the
    // update side of row contention, which matters only while an update is
    // valid, and then equals i_read_valid.
    input logic i_read_offer,
    output logic o_read_ready,
    input logic [ADDR_WIDTH-1:0] i_read_addr,
    input logic [WayBits-1:0] i_read_way,
    input logic [TOKEN_BITS-1:0] i_read_token,
    output logic o_read_valid,
    output logic [TOKEN_BITS-1:0] o_read_token,
    output logic [8*LINE_BYTES-1:0] o_read_data,
    input logic i_update_valid,
    output logic o_update_ready,
    input logic [ADDR_WIDTH-1:0] i_update_addr,
    input logic [WayBits-1:0] i_update_way,
    input logic i_update_tag,
    input logic [1:0] i_update_state,
    // Equals |i_update_mask whenever i_update_valid; the caller forms it ahead
    // of its own registers, so readiness does not reduce the mask.
    input logic i_update_has_data,
    input logic [LINE_BYTES-1:0] i_update_mask,
    input logic [8*LINE_BYTES-1:0] i_update_data,
    input logic [TOKEN_BITS-1:0] i_update_token,
    output logic o_updated,
`ifdef COHERENCE_HOME_CONTROL
    input logic [(1<<TOKEN_BITS)-1:0] i_tag_owner,
    input logic [(1<<TOKEN_BITS)-1:0][ADDR_WIDTH-1:0] i_tag_address,
    input logic [(1<<TOKEN_BITS)-1:0] i_read_owner,
    input logic [(1<<TOKEN_BITS)-1:0] i_update_owner,
    // Selection and response cycles, when the query has held since the edge
    // before.
    output logic o_query_held,
`endif
    output logic [TOKEN_BITS-1:0] o_updated_token
);
`ifndef SYNTHESIS
  // Registers power up arbitrary and the reset can reach this module a few
  // cycles after the first edge, so the simulation checks begin at the first
  // reset.
`ifdef FORMAL
  // Formal tasks start from a reset or from an induction state; the checks
  // apply in both.
  wire sim_reset_seen_q = 1'b1;
`else
  logic sim_reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) sim_reset_seen_q <= 1'b1;
`endif
`endif
  localparam int unsigned TagBits = ADDR_WIDTH - SetBits - OffsetBits;
  localparam int unsigned TagEntryBits = TagBits + 2;
  localparam int unsigned PlruBits = WAYS > 1 ? WAYS - 1 : 1;
  localparam int unsigned CountBits = $clog2(TAG_READ_LATENCY + 2);
  localparam int unsigned TagSlots = TagEntryBits <= 9 ? 8 :
      TagEntryBits <= 18 ? 4 : TagEntryBits <= 36 ? 2 : 1;
  localparam int unsigned TagGroupBits = ULTRA && TagSlots > WAYS ? $clog2(TagSlots / WAYS) : 0;
  typedef enum logic [2:0] {
    Init,
    InitDrain,
    Idle,
    Tags,
    Select,
    Reply
  } phase_t;
  phase_t phase_q;
  logic [CountBits-1:0] count_q;
  logic [SetBits-1:0] init_set_q, set_q;
  logic [TagBits-1:0] tag_q;
  logic [TOKEN_BITS-1:0] token_q;
  logic [(1 << TOKEN_BITS)-1:0] token_onehot_q;
  logic [PlruBits-1:0] plru_read, plru_q;
  logic plru_we;
  logic [WAYS-1:0] tag_we;
  logic [SetBits-1:0] tag_raddr, tag_waddr;
  logic [TagEntryBits-1:0] tag_wdata;
  logic [TagEntryBits-1:0] tag_rdata[WAYS], tags_q[WAYS];
  logic hit;
  logic [WayBits-1:0] selected;
  logic request_fire, read_fire, update_fire;
  logic tag_hazard, read_hazard, write_hazard;
  logic read_turn_q, row_contended;
  logic [RowBits-1:0] read_row, write_row;
  logic [8*LINE_BYTES-1:0] data_rdata;
  logic [DATA_READ_LATENCY:0] read_valid_q;
  logic [TOKEN_BITS-1:0] read_token_q[DATA_READ_LATENCY+1];
  logic [RowBits-1:0] read_row_q[DATA_READ_LATENCY+1];
  logic [DATA_WRITE_LATENCY:0] write_valid_q, write_data_q;
  logic [TOKEN_BITS-1:0] write_token_q[DATA_WRITE_LATENCY+1];
  logic [RowBits-1:0] write_row_q[DATA_WRITE_LATENCY+1];

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


  assign o_init_done = phase_q != Init && phase_q != InitDrain;
  assign o_query_addr = {tag_q, set_q, {OffsetBits{1'b0}}};
  assign tag_raddr = i_req_addr[OffsetBits+:SetBits];
  assign tag_waddr = phase_q == Init ? init_set_q : i_update_addr[OffsetBits+:SetBits];
  assign tag_wdata = phase_q == Init ? '0 :
      {i_update_state, i_update_addr[ADDR_WIDTH-1:OffsetBits+SetBits]};
  assign tag_hazard = (phase_q == Tags || phase_q == Select || phase_q == Reply) &&
      (set_q >> TagGroupBits) == (tag_waddr >> TagGroupBits);
  assign row_contended = i_read_valid && i_update_valid && i_update_has_data &&
      read_row == write_row;
  wire update_contended = i_read_offer && i_update_has_data && read_row == write_row;
  assign o_update_ready = !i_rst && o_init_done && !write_hazard &&
      !(update_contended && read_turn_q) &&
      !(i_update_tag && tag_hazard);
  assign update_fire = i_update_valid && o_update_ready;
  // A claim reaches readiness through the last term only: the other terms
  // and the same-set comparison form beside the consumer's decision.
  (* keep = "true" *) logic req_ready_unclaimed, req_claim_conflict;
  assign req_ready_unclaimed = !i_rst && (phase_q == Idle || (phase_q == Reply && i_resp_ready)) &&
      !(i_update_valid && i_update_tag &&
        (tag_waddr >> TagGroupBits) == (tag_raddr >> TagGroupBits));
  assign req_claim_conflict = phase_q == Reply && set_q == tag_raddr;
  assign o_req_ready = req_ready_unclaimed && !(i_resp_claim && req_claim_conflict);
  assign request_fire = i_req_valid && o_req_ready;
  assign o_resp_valid = !i_rst && phase_q == Reply;
  for (genvar way = 0; way < WAYS; way++) begin : gen_resp_tags
    assign o_resp_tags[way] = tags_q[way][TagBits-1:0];
  end
  assign o_resp_token = token_q;
  assign o_resp_token_onehot = token_onehot_q;
`ifndef SYNTHESIS
  // Reset and every request capture write both, so they agree after reset.
`ifdef FORMAL
  wire token_reset_seen = !i_rst;
`else
  logic token_reset_seen = 1'b0;
  always_ff @(posedge i_clk) if (i_rst) token_reset_seen <= 1'b1;
`endif
  always_comb if (token_reset_seen) assert (token_onehot_q == (1 << TOKEN_BITS)'(1) << token_q);
`endif
  assign plru_we = !i_rst && (phase_q == Init || (o_resp_valid && i_resp_ready && i_resp_claim));
  sdp_block_ram #(
      .ADDR_WIDTH(SetBits),
      .DATA_WIDTH(PlruBits)
  ) replacement (
      .i_clk,
      .i_write_enable(plru_we),
      .i_bulk_clear(1'b0),
      .i_write_address(phase_q == Init ? init_set_q : set_q),
      .i_read_address(tag_raddr),
      .i_write_data(phase_q == Init ? PlruBits'(0) : touch(plru_q, o_resp_way)),
      .o_read_data(plru_read)
  );
  for (genvar way = 0; way < WAYS; way++) begin : gen_tag_en
    assign tag_we[way] = !i_rst && (phase_q == Init ||
        (update_fire && i_update_tag && i_update_way == WayBits'(way)));
  end
  if (ULTRA) begin : gen_tag_ultra
    logic [WAYS*TagEntryBits-1:0] row;
    sdp_packed_tag_uram #(
        .ADDR_WIDTH  (RowBits),
        .DATA_WIDTH  (TagEntryBits),
        .READ_LATENCY(TAG_READ_LATENCY),
        .READ_WORDS  (WAYS)
    ) tags (
        .i_clk,
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
          .i_clk,
          .i_write_enable(tag_we[way]),
          .i_bulk_clear(1'b0),
          .i_write_address(tag_waddr),
          .i_read_address(tag_raddr),
          .i_write_data(tag_wdata),
          .o_read_data(tag_rdata[way])
      );
    end
  end

  assign read_row = (RowBits'(i_read_way) << SetBits) | RowBits'(i_read_addr[OffsetBits+:SetBits]);
  assign write_row = (RowBits'(i_update_way) << SetBits) |
      RowBits'(i_update_addr[OffsetBits+:SetBits]);
  always_comb begin
    write_hazard = 1'b0;
    read_hazard  = 1'b0;
    for (int stage = 0; stage <= DATA_READ_LATENCY; stage++)
    if (read_valid_q[stage] && read_row_q[stage] == write_row && i_update_has_data)
      write_hazard = 1'b1;
    for (int stage = 0; stage <= DATA_WRITE_LATENCY; stage++) begin
      if (write_valid_q[stage] && write_data_q[stage]) begin
        if (write_row_q[stage] == write_row && i_update_has_data) write_hazard = 1'b1;
        if (write_row_q[stage] == read_row) read_hazard = 1'b1;
      end
    end
  end
  assign o_read_ready = !i_rst && o_init_done && !read_hazard && !(row_contended && !read_turn_q);
  assign read_fire = i_read_valid && o_read_ready;
  assign o_read_valid = !i_rst && read_valid_q[DATA_READ_LATENCY];
  assign o_read_token = read_token_q[DATA_READ_LATENCY];
  assign o_updated = !i_rst && write_valid_q[DATA_WRITE_LATENCY];
  assign o_updated_token = write_token_q[DATA_WRITE_LATENCY];
  sdp_ram_byte_en #(
      .DATA_WIDTH(8 * LINE_BYTES),
      .ADDR_WIDTH(RowBits),
      .READ_LATENCY(DATA_READ_LATENCY),
      .WRITE_LATENCY(DATA_WRITE_LATENCY),
      .MEMORY_PRIMITIVE(ULTRA ? "ultra" : "block"),
      .REGISTER_READ_INPUT(ULTRA),
      .REGISTER_READ_OUTPUT(ULTRA)
  ) data_array (
      .i_clk,
      .i_waddr(write_row),
      .i_wdata(i_update_data),
      .i_wbyte_en(i_update_mask & {LINE_BYTES{update_fire}}),
      .i_re(read_fire),
      .i_raddr(read_row),
      .o_rdata(data_rdata)
  );
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      read_valid_q  <= '0;
      write_valid_q <= '0;
      write_data_q  <= '0;
      read_turn_q   <= 1'b0;
    end else begin
      if (read_fire || (update_fire && i_update_has_data)) read_turn_q <= !read_fire;
      read_valid_q[0] <= read_fire;
      read_token_q[0] <= i_read_token;
      read_row_q[0]   <= read_row;
      for (int stage = 1; stage <= DATA_READ_LATENCY; stage++) begin
        read_valid_q[stage] <= read_valid_q[stage-1];
        read_token_q[stage] <= read_token_q[stage-1];
        read_row_q[stage]   <= read_row_q[stage-1];
      end
      if (read_valid_q[DATA_READ_LATENCY-1]) o_read_data <= data_rdata;
      write_valid_q[0] <= update_fire;
      write_data_q[0]  <= i_update_has_data;
      write_token_q[0] <= i_update_token;
      write_row_q[0]   <= write_row;
      for (int stage = 1; stage <= DATA_WRITE_LATENCY; stage++) begin
        write_valid_q[stage] <= write_valid_q[stage-1];
        write_data_q[stage]  <= write_data_q[stage-1];
        write_token_q[stage] <= write_token_q[stage-1];
        write_row_q[stage]   <= write_row_q[stage-1];
      end
    end
  end

  always_comb begin
    selected = victim(plru_q, ~i_exclude);
    hit = 1'b0;
    for (int way = WAYS - 1; way >= 0; way--)
    if (tags_q[way][TagBits+:2] == 0 && !i_exclude[way]) selected = WayBits'(way);
    for (int way = 0; way < WAYS; way++) begin
      if (tags_q[way][TagBits+:2] != 0 && tags_q[way][TagBits-1:0] == tag_q) begin
        hit = 1'b1;
        selected = WayBits'(way);
      end
    end
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      phase_q <= Init;
      init_set_q <= '0;
      set_q <= '0;
      tag_q <= '0;
      token_q <= '0;
      token_onehot_q <= (1 << TOKEN_BITS)'(1);
      count_q <= '0;
      plru_q <= '0;
      o_resp_hit <= 1'b0;
      o_resp_available <= 1'b0;
      o_resp_way <= '0;
      o_resp_addr <= '0;
      o_resp_state <= '0;
    end else begin
      case (phase_q)
        Init: begin
          init_set_q <= init_set_q + 1'b1;
          if (&init_set_q) phase_q <= InitDrain;
        end
        InitDrain: phase_q <= Idle;
        Tags: begin
          if (count_q == CountBits'(TAG_READ_LATENCY)) plru_q <= plru_read;
          count_q <= count_q - 1'b1;
          if (count_q == 1) begin
            for (int way = 0; way < WAYS; way++) tags_q[way] <= tag_rdata[way];
            phase_q <= Select;
          end
        end
        Select: begin
          o_resp_hit <= hit;
          o_resp_available <= hit || !(&i_exclude);
          o_resp_way <= selected;
          o_resp_addr <= {tags_q[selected][TagBits-1:0], set_q, {OffsetBits{1'b0}}};
          o_resp_state <= tags_q[selected][TagBits+:2];
          phase_q <= Reply;
        end
        Reply: if (i_resp_ready) phase_q <= Idle;
        default: begin
        end
      endcase
      if (request_fire) begin
        set_q <= i_req_addr[OffsetBits+:SetBits];
        tag_q <= i_req_addr[ADDR_WIDTH-1:OffsetBits+SetBits];
        token_q <= i_req_token;
        token_onehot_q <= (1 << TOKEN_BITS)'(1) << i_req_token;
        count_q <= CountBits'(TAG_READ_LATENCY);
        phase_q <= Tags;
      end
    end
  end
  if (ADDR_WIDTH < 32 || ADDR_WIDTH > 56 || (LINE_BYTES != 32 && LINE_BYTES != 64) ||
      Sets < 2 || (Sets & (Sets - 1)) != 0 || (WAYS != 1 && WAYS != 4) ||
      CACHE_BYTES != Sets * WAYS * LINE_BYTES || TOKEN_BITS < 1 ||
      DATA_READ_LATENCY < 2 || DATA_WRITE_LATENCY < 1 || TAG_READ_LATENCY < 1 ||
      (!ULTRA && TAG_READ_LATENCY != 1) || (ULTRA && TAG_READ_LATENCY < 2)) begin : gen_invalid
    initial $fatal(1, "coherence_home_array: invalid parameters");
  end
`ifndef SYNTHESIS
  always_ff @(posedge i_clk) begin
    if (sim_reset_seen_q && !i_rst) begin
      if (read_fire) assert (int'(i_read_way) < WAYS);
      if (update_fire) assert (int'(i_update_way) < WAYS);
      if (o_resp_valid && i_resp_ready && i_resp_claim) assert (o_resp_available);
      if (o_resp_valid)
        assert (o_resp_addr == {o_resp_tags[o_resp_way], set_q, {OffsetBits{1'b0}}});
      assert (!(read_fire && update_fire && |i_update_mask && read_row == write_row));
      if (update_fire && i_update_tag) assert (!tag_hazard);
      if (i_update_valid) assert (i_read_offer == i_read_valid);
    end
  end
`endif
`ifdef COHERENCE_HOME_CONTROL
  assign o_query_held = !i_rst && (phase_q == Select || phase_q == Reply);
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (phase_q == Reply && !o_resp_hit && o_resp_available) assert (!i_exclude[o_resp_way]);
      if (phase_q == Tags || phase_q == Select || phase_q == Reply) begin
        assert (i_tag_owner[token_q]);
        assert ((o_query_addr >> OffsetBits) == (i_tag_address[token_q] >> OffsetBits));
      end
      if (request_fire) assert (!i_tag_owner[i_req_token]);
      if (read_fire) assert (!i_read_owner[i_read_token]);
      if (update_fire) assert (!i_update_owner[i_update_token]);
      for (int stage = 0; stage <= DATA_READ_LATENCY; stage++) begin
        if (read_valid_q[stage]) begin
          assert (i_read_owner[read_token_q[stage]]);
          for (int other = stage + 1; other <= DATA_READ_LATENCY; other++)
          if (read_valid_q[other]) assert (read_token_q[stage] != read_token_q[other]);
        end
      end
      for (int stage = 0; stage <= DATA_WRITE_LATENCY; stage++) begin
        if (write_valid_q[stage]) begin
          assert (i_update_owner[write_token_q[stage]]);
          for (int other = stage + 1; other <= DATA_WRITE_LATENCY; other++)
          if (write_valid_q[other]) assert (write_token_q[stage] != write_token_q[other]);
        end
      end
    end
  end
`else
`ifdef FORMAL
  logic f_past_valid = 1'b0;
  (* anyconst *) logic [RowBits-1:0] f_row;
`ifdef COHERENCE_ARRAY_BYTE
  wire [OffsetBits-1:0] f_byte = OffsetBits'(`COHERENCE_ARRAY_BYTE);
`else
  (* anyconst *) logic [OffsetBits-1:0] f_byte;
`endif
  logic f_known_q = 1'b0;
  logic [7:0] f_value_q;
  logic [DATA_READ_LATENCY:0] f_check_q;
  logic [7:0] f_expected_q[DATA_READ_LATENCY+1];
  localparam int unsigned ServiceBound = DATA_READ_LATENCY + DATA_WRITE_LATENCY + 5;
  logic [$clog2(ServiceBound+1)-1:0] f_read_wait_q, f_write_wait_q;
  localparam int unsigned TagServiceBound = TAG_READ_LATENCY + 4;
  logic [$clog2(TagServiceBound+1)-1:0] f_tag_wait_q;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (i_read_valid) assume (int'(i_read_way) < WAYS);
    if (i_update_valid) assume (int'(i_update_way) < WAYS);
    if (i_update_valid) assume (i_read_offer == i_read_valid);
    if (i_update_valid) assume (i_update_has_data == |i_update_mask);
    if (o_resp_valid && i_resp_ready && i_resp_claim) assume (o_resp_available);
    if (i_rst) begin
      f_known_q <= 1'b0;
      f_check_q <= '0;
    end else begin
      if (update_fire && write_row == f_row && i_update_mask[f_byte]) begin
        f_known_q <= 1'b1;
        f_value_q <= i_update_data[8*f_byte+:8];
      end
      f_check_q[0] <= read_fire && read_row == f_row && f_known_q;
      f_expected_q[0] <= f_value_q;
      for (int stage = 1; stage <= DATA_READ_LATENCY; stage++) begin
        f_check_q[stage] <= f_check_q[stage-1];
        f_expected_q[stage] <= f_expected_q[stage-1];
      end
      if (f_check_q[DATA_READ_LATENCY]) begin
        assert (o_read_valid);
        assert (o_read_data[8*f_byte+:8] == f_expected_q[DATA_READ_LATENCY]);
      end
    end
    if (i_rst || !o_init_done || !row_contended || i_update_tag) begin
      f_read_wait_q  <= '0;
      f_write_wait_q <= '0;
    end else begin
      f_read_wait_q  <= read_fire ? '0 : f_read_wait_q + 1'b1;
      f_write_wait_q <= update_fire ? '0 : f_write_wait_q + 1'b1;
      assert (int'(f_read_wait_q) < ServiceBound);
      assert (int'(f_write_wait_q) < ServiceBound);
    end
    if (i_rst || !o_init_done || !i_update_valid || !i_update_tag ||
        |i_update_mask || !i_resp_ready ||
        (f_past_valid && i_update_addr != $past(
            i_update_addr
        )))
      f_tag_wait_q <= '0;
    else begin
      f_tag_wait_q <= update_fire ? '0 : f_tag_wait_q + 1'b1;
      assert (int'(f_tag_wait_q) < TagServiceBound);
    end
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(o_resp_valid && !i_resp_ready)) begin
        assert (o_resp_valid);
        assert ({o_resp_token, o_resp_hit, o_resp_available, o_resp_way,
            o_resp_addr, o_resp_state} == $past(
            {o_resp_token, o_resp_hit, o_resp_available, o_resp_way, o_resp_addr, o_resp_state}
        ));
      end
      cover (request_fire && read_fire && update_fire);
      cover (o_read_valid && o_updated && o_resp_valid);
    end
  end
`endif
`endif
endmodule
