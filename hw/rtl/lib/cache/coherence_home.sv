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

`include "coherence_types.svh"

// One acquisition owns its L2 block through completion and release. A fill
// overlaps victim recalls. Detached dirty blocks own their addresses until B.
module coherence_home #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 64,
    parameter int unsigned CACHE_BYTES = 2 * 1024 * 1024,
    parameter int unsigned WAYS = 4,
    parameter int unsigned NUM_WB = 2,
    parameter bit ULTRA = 1'b1,
    localparam int unsigned WayBits = WAYS > 1 ? $clog2(WAYS) : 1,
    localparam int unsigned WbBits = NUM_WB > 1 ? $clog2(NUM_WB) : 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_fatal_stop,
    input logic i_d_valid,
    output logic o_d_ready,
    input logic [ADDR_WIDTH+311:0] i_d,
    output logic o_p_valid,
    input logic i_p_ready,
    output logic [ADDR_WIDTH+29:0] o_p,
    input logic i_r_valid,
    output logic o_r_ready,
    input logic [ADDR_WIDTH+274:0] i_r,
    input logic i_w_valid,
    output logic o_w_ready,
    input logic [ADDR_WIDTH+259:0] i_w,
    output logic o_wa_valid,
    input logic i_wa_ready,
    output logic [ADDR_WIDTH+10:0] o_wa,
    output logic o_g_valid,
    input logic i_g_ready,
    output logic [ADDR_WIDTH+274:0] o_g,
    input logic i_c_valid,
    output logic o_c_ready,
    input logic [ADDR_WIDTH+17:0] i_c,
    output logic o_u_valid,
    input logic i_u_ready,
    output logic [ADDR_WIDTH+14:0] o_u,
    output logic o_mem_req_valid,
    input logic i_mem_req_ready,
    output logic o_mem_req_write,
    output logic [ADDR_WIDTH-1:0] o_mem_req_addr,
    output logic [8*LINE_BYTES-1:0] o_mem_req_data,
    output logic [LINE_BYTES-1:0] o_mem_req_mask,
    output logic [4:0] o_mem_req_id,
    input logic i_mem_resp_valid,
    input logic [4:0] i_mem_resp_id,
    input logic [8*LINE_BYTES-1:0] i_mem_resp_data,
    input logic i_mem_resp_error,
    output logic o_fatal,
    output logic [ADDR_WIDTH-1:0] o_fatal_addr
);
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  localparam int unsigned OffsetBits = $clog2(LINE_BYTES);
  localparam int unsigned Sectors = LINE_BYTES / 32;
  localparam logic [5:0] FillTid = 6'(coherence_pkg::fill_base(1));
  localparam logic [5:0] PutTid = 6'(coherence_pkg::put_base(1, 1));
  typedef enum logic [4:0] {
    Idle,
    Lookup,
    LookupWait,
    Recall,
    ProbeSend,
    ProbeWait,
    AbsorbAck,
    ProbeNext,
    Detach,
    InvalidateVictim,
    InvalidateWait,
    FillWait,
    Check,
    Apply,
    Update,
    UpdateWait,
    Result,
    Complete,
    PutAck,
    Fatal
  } phase_t;
  phase_t phase_q;
  coh_d_t demand_in, demand;
  coh_r_t reply;
  coh_w_t put_in, put_q;
  coh_p_t  probe_q;
  coh_wa_t ack_q;
  coh_g_t  result;
  logic endpoint_ready, endpoint_live, work_valid, result_ready;
  logic put_active_q, write_turn_q;
  logic array_req_ready, array_resp_valid, array_hit, array_available;
  logic array_update_ready;
  logic [WayBits-1:0] array_way, way_q;
  logic [ADDR_WIDTH-1:0] array_addr, address_q, victim_addr_q;
  logic [1:0] array_state, line_state_q;
  logic [8*LINE_BYTES-1:0] array_data, image_q;
  logic victim_q, sector_q, check_done_q, sc_failed_q, grant_error_q;
  logic fill_valid_q, fill_sent_q, fill_done_q, fill_error_q;
  logic [8*LINE_BYTES-1:0] fill_data_q;
  logic [NUM_WB-1:0] wb_valid_q, wb_sent_q;
  logic [  ADDR_WIDTH-1:0] wb_addr_q[NUM_WB];
  logic [8*LINE_BYTES-1:0] wb_data_q[NUM_WB];
  logic wb_free, wb_pending, address_locked;
  logic [WbBits-1:0] wb_free_slot, wb_pending_slot;
  logic [  1:0] result_state;
  logic [ 31:0] sector_mask;
  logic [255:0] sector_data;
  logic select_put, active;
  logic [5:0] active_tid;
  logic probe_matches;
  wire lookup_fire = active && phase_q == Lookup && !address_locked && array_req_ready;

  assign demand_in = i_d;
  assign put_in = i_w;
  assign reply = i_r;
  assign active = !i_rst && !i_fatal_stop && !o_fatal;
  assign select_put = i_w_valid && (!i_d_valid || write_turn_q);
  assign o_d_ready = active && phase_q == Idle && !select_put && endpoint_ready;
  assign o_w_ready = active && phase_q == Idle && select_put && !endpoint_live;
  assign active_tid = put_active_q ? PutTid : 6'd0;

  coherence_home_endpoint #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .NUM_HARTS(1),
      .L2_NUM_MSHR(1),
      .TID(0)
  ) endpoint (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .i_epoch(1'b0),
      .i_d_valid(i_d_valid && active && phase_q == Idle && !select_put),
      .o_d_ready(endpoint_ready),
      .i_d(i_d),
      .o_work_valid(work_valid),
      .o_work(demand),
      .i_result_valid(active && phase_q == Result),
      .o_result_ready(result_ready),
      .i_result(result),
      .o_g_valid(o_g_valid),
      .i_g_ready(i_g_ready),
      .o_g(o_g),
      .i_c_valid(i_c_valid && active),
      .i_error_disposed(grant_error_q),
      .o_c_ready(o_c_ready),
      .i_c(i_c),
      .i_absorb_valid(1'b0),
      .o_absorb_ready(),
      .i_absorb('0),
      .i_cancel_valid(1'b0),
      .i_cancel('0),
      .o_u_valid(o_u_valid),
      .i_u_ready(i_u_ready),
      .o_u(o_u),
      .o_live(endpoint_live),
      .o_pending()
  );

  coherence_array #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_BYTES(LINE_BYTES),
      .CACHE_BYTES(CACHE_BYTES),
      .WAYS(WAYS),
      .ULTRA(ULTRA)
  ) array (
      .i_clk(i_clk),
      .i_rst(i_rst),
      .o_init_done(),
      .i_req_valid(active && phase_q == Lookup && !address_locked),
      .o_req_ready(array_req_ready),
      .i_req_addr(address_q),
      .i_req_exclude('0),
      .i_req_visit(1'b0),
      .i_req_way('0),
      .o_resp_valid(array_resp_valid),
      .i_resp_ready(phase_q == LookupWait),
      .o_resp_hit(array_hit),
      .o_resp_available(array_available),
      .o_resp_way(array_way),
      .o_resp_addr(array_addr),
      .o_resp_state(array_state),
      .o_resp_data(array_data),
      .i_update_valid(active && (phase_q == Update || phase_q == InvalidateVictim)),
      .o_update_ready(array_update_ready),
      .i_update_addr(phase_q == InvalidateVictim ? victim_addr_q : address_q),
      .i_update_way(way_q),
      .i_update_state(phase_q == InvalidateVictim ? 2'b00 : line_state_q),
      .i_update_insert(fill_valid_q && phase_q == Update),
      .i_update_mask({LINE_BYTES{phase_q == Update}}),
      .i_update_data(image_q)
  );

  always_comb begin
    wb_free = 1'b0;
    wb_free_slot = '0;
    wb_pending = 1'b0;
    wb_pending_slot = '0;
    address_locked = 1'b0;
    for (int slot = NUM_WB - 1; slot >= 0; slot--) begin
      if (!wb_valid_q[slot]) begin
        wb_free = 1'b1;
        wb_free_slot = WbBits'(slot);
      end
      if (wb_valid_q[slot] && !wb_sent_q[slot]) begin
        wb_pending = 1'b1;
        wb_pending_slot = WbBits'(slot);
      end
      if (wb_valid_q[slot] &&
          wb_addr_q[slot][ADDR_WIDTH-1:OffsetBits] == address_q[ADDR_WIDTH-1:OffsetBits])
        address_locked = 1'b1;
    end
  end

  // The memory presentation is frozen independently of the home FSM.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      o_mem_req_valid <= 1'b0;
      o_mem_req_write <= 1'b0;
      o_mem_req_addr <= '0;
      o_mem_req_data <= '0;
      o_mem_req_mask <= '0;
      o_mem_req_id <= '0;
    end else begin
      if (o_mem_req_valid && i_mem_req_ready) o_mem_req_valid <= 1'b0;
      if (!o_mem_req_valid && !o_fatal && !i_fatal_stop) begin
        if (fill_valid_q && !fill_sent_q) begin
          o_mem_req_valid <= 1'b1;
          o_mem_req_write <= 1'b0;
          o_mem_req_addr <= {address_q[ADDR_WIDTH-1:OffsetBits], {OffsetBits{1'b0}}};
          o_mem_req_data <= '0;
          o_mem_req_mask <= '0;
          o_mem_req_id <= '0;
        end else if (wb_pending) begin
          o_mem_req_valid <= 1'b1;
          o_mem_req_write <= 1'b1;
          o_mem_req_addr <= wb_addr_q[wb_pending_slot];
          o_mem_req_data <= wb_data_q[wb_pending_slot];
          o_mem_req_mask <= '1;
          o_mem_req_id <= 5'd16 | 5'(wb_pending_slot);
        end
      end
    end
  end

  (* keep = "true" *) wire probe_eligible = !i_fatal_stop && !o_fatal && phase_q == ProbeSend;
  assign o_p_valid = !i_rst && probe_eligible;
  assign o_p = probe_q;
  assign probe_matches = reply.tid == probe_q.tid && reply.epoch == probe_q.epoch &&
      reply.hart == 0 && reply.addr == probe_q.addr &&
      ((probe_q.opcode == coherence_pkg::CheckSC && reply.opcode == coherence_pkg::CheckAck) ||
       (probe_q.opcode != coherence_pkg::CheckSC &&
        (reply.opcode == coherence_pkg::ProbeAck || reply.opcode == coherence_pkg::ProbeData)));
  assign o_r_ready = active && phase_q == ProbeWait && probe_matches;
  assign o_wa_valid = active && (phase_q == AbsorbAck || phase_q == PutAck);
  assign o_wa = ack_q;

  always_comb begin
    result = '0;
    result.q = demand.q;
    result.addr = demand.addr;
    result.tid = 0;
    result.data = image_q[(LINE_BYTES == 64 && demand.addr[5] ? 256 : 0)+:256];
    result.error = grant_error_q;
    result.opcode = coherence_pkg::GrantData;
    case (demand.opcode)
      coherence_pkg::GetS, coherence_pkg::LoadReserved: result.opcode = coherence_pkg::GrantS;
      coherence_pkg::GetM, coherence_pkg::Atomic: result.opcode = coherence_pkg::GrantM;
      coherence_pkg::StoreConditional:
      result.opcode = sc_failed_q ? coherence_pkg::GrantFail : coherence_pkg::GrantM;
      coherence_pkg::DMAWrite, coherence_pkg::Prefetch: result.opcode = coherence_pkg::GrantAck;
      default: begin
      end
    endcase
    sector_mask  = put_active_q ? '1 : demand.mask;
    sector_data  = put_active_q ? put_q.data : demand.wdata;
    result_state = line_state_q;
    if (put_active_q || demand.opcode == coherence_pkg::DMAWrite)
      result_state = coherence_pkg::Modified;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      phase_q <= Idle;
      put_active_q <= 1'b0;
      put_q <= '0;
      write_turn_q <= 1'b1;
      address_q <= '0;
      victim_addr_q <= '0;
      way_q <= '0;
      line_state_q <= '0;
      image_q <= '0;
      victim_q <= 1'b0;
      sector_q <= 1'b0;
      check_done_q <= 1'b0;
      sc_failed_q <= 1'b0;
      grant_error_q <= 1'b0;
      probe_q <= '0;
      ack_q <= '0;
      fill_valid_q <= 1'b0;
      fill_sent_q <= 1'b0;
      fill_done_q <= 1'b0;
      fill_error_q <= 1'b0;
      fill_data_q <= '0;
      wb_valid_q <= '0;
      wb_sent_q <= '0;
      o_fatal <= 1'b0;
      o_fatal_addr <= '0;
      for (int slot = 0; slot < NUM_WB; slot++) begin
        wb_addr_q[slot] <= '0;
        wb_data_q[slot] <= '0;
      end
    end else begin
      if (o_mem_req_valid && i_mem_req_ready) begin
        if (o_mem_req_write) wb_sent_q[WbBits'(o_mem_req_id)] <= 1'b1;
        else fill_sent_q <= 1'b1;
      end
      if (i_mem_resp_valid) begin
        if (i_mem_resp_id[4]) begin
          if (i_mem_resp_error) begin
            o_fatal <= 1'b1;
            o_fatal_addr <= wb_addr_q[WbBits'(i_mem_resp_id)];
          end else begin
            wb_valid_q[WbBits'(i_mem_resp_id)] <= 1'b0;
            wb_sent_q[WbBits'(i_mem_resp_id)]  <= 1'b0;
          end
        end else begin
          fill_data_q  <= i_mem_resp_data;
          fill_error_q <= i_mem_resp_error;
          fill_done_q  <= 1'b1;
        end
      end
      if (active) begin
        case (phase_q)
          Idle: begin
            if (i_d_valid && o_d_ready || i_w_valid && o_w_ready) begin
              put_active_q <= i_w_valid && o_w_ready;
              put_q <= put_in;
              address_q <= o_w_ready ? put_in.addr : demand_in.addr;
              write_turn_q <= !o_w_ready;
              fill_valid_q <= 1'b0;
              fill_sent_q <= 1'b0;
              fill_done_q <= 1'b0;
              fill_error_q <= 1'b0;
              check_done_q <= 1'b0;
              sc_failed_q <= 1'b0;
              grant_error_q <= 1'b0;
              victim_q <= 1'b0;
              phase_q <= Lookup;
            end
          end
          Lookup: if (!address_locked && array_req_ready) phase_q <= LookupWait;
          LookupWait:
          if (array_resp_valid) begin
            way_q <= array_way;
            line_state_q <= array_state;
            image_q <= array_data;
            victim_addr_q <= array_addr;
            sector_q <= 1'b0;
            if (!array_hit && put_active_q) begin
              o_fatal <= 1'b1;
              o_fatal_addr <= address_q;
              phase_q <= Fatal;
            end else if (array_hit) begin
              phase_q <= Check;
            end else begin
              victim_q <= array_state != coherence_pkg::Invalid;
              phase_q  <= Recall;
            end
          end
          Recall: begin
            // Dirty victims reserve credit before their first recall. A
            // clean victim may acquire dirty data from its private owner.
            if (line_state_q != coherence_pkg::Modified || wb_free) begin
              fill_valid_q <= 1'b1;
              if (!victim_q) phase_q <= FillWait;
              else begin
                probe_q <= '0;
                probe_q.opcode <= coherence_pkg::ProbeRead;
                probe_q.tid <= FillTid;
                probe_q.addr <= victim_addr_q | ADDR_WIDTH'(int'(sector_q) * 32);
                probe_q.reason <= coherence_pkg::Replace;
                phase_q <= ProbeSend;
              end
            end
          end
          ProbeSend: if (i_p_ready) phase_q <= ProbeWait;
          ProbeWait:
          if (i_r_valid && o_r_ready) begin
            if (reply.error) begin
              if (!victim_q && !put_active_q && !reply.data_valid && !reply.absorbed &&
                  reply.state != coherence_pkg::Modified &&
                      line_state_q != coherence_pkg::Modified &&
                  demand.opcode != coherence_pkg::GetM) begin
                grant_error_q <= 1'b1;
                phase_q <= Result;
              end else begin
                o_fatal <= 1'b1;
                o_fatal_addr <= reply.addr;
                phase_q <= Fatal;
              end
            end else begin
              if (probe_q.opcode == coherence_pkg::CheckSC) begin
                check_done_q <= 1'b1;
                sc_failed_q  <= !reply.sc_valid;
              end
              if (reply.data_valid) begin
                image_q[(LINE_BYTES == 64 && reply.addr[5] ? 256 : 0)+:256] <= reply.data;
                line_state_q <= coherence_pkg::Modified;
              end
              if (reply.absorbed) begin
                ack_q.hart <= reply.hart;
                ack_q.put_id <= reply.put_id;
                ack_q.epoch <= reply.put_epoch;
                ack_q.addr <= reply.addr;
                ack_q.absorbed <= 1'b1;
                ack_q.tid <= reply.tid;
                ack_q.error <= 1'b0;
                phase_q <= AbsorbAck;
              end else phase_q <= ProbeNext;
            end
          end
          AbsorbAck: if (i_wa_ready) phase_q <= ProbeNext;
          ProbeNext: begin
            if (victim_q) begin
              if (Sectors == 2 && !sector_q) begin
                sector_q <= 1'b1;
                phase_q  <= Recall;
              end else phase_q <= Detach;
            end else if (probe_q.opcode == coherence_pkg::CheckSC) phase_q <= Check;
            else phase_q <= Apply;
          end
          Detach: begin
            if (line_state_q != coherence_pkg::Modified || wb_free) begin
              if (line_state_q == coherence_pkg::Modified) begin
                wb_valid_q[wb_free_slot] <= 1'b1;
                wb_sent_q[wb_free_slot]  <= 1'b0;
                wb_addr_q[wb_free_slot]  <= victim_addr_q;
                wb_data_q[wb_free_slot]  <= image_q;
              end
              victim_q <= 1'b0;
              phase_q  <= InvalidateVictim;
            end
          end
          InvalidateVictim: if (array_update_ready) phase_q <= InvalidateWait;
          InvalidateWait: if (array_req_ready) phase_q <= FillWait;
          FillWait:
          if (fill_done_q) begin
            if (fill_error_q && demand.opcode == coherence_pkg::GetM) begin
              o_fatal <= 1'b1;
              o_fatal_addr <= address_q;
              phase_q <= Fatal;
            end else if (fill_error_q) begin
              grant_error_q <= 1'b1;
              phase_q <= Result;
            end else begin
              image_q <= fill_data_q;
              line_state_q <= coherence_pkg::Shared;
              phase_q <= Check;
            end
          end
          Check: begin
            probe_q <= '0;
            probe_q.tid <= active_tid;
            probe_q.addr <= address_q;
            probe_q.requester <= demand.q.src;
            if (!put_active_q && demand.opcode == coherence_pkg::StoreConditional &&
                !check_done_q) begin
              probe_q.opcode <= coherence_pkg::CheckSC;
              probe_q.reason <= coherence_pkg::Check;
              probe_q.check_q <= demand.q;
              probe_q.offset <= demand.offset;
              probe_q.size <= demand.size;
              phase_q <= ProbeSend;
            end else if (put_active_q || sc_failed_q || demand.opcode == coherence_pkg::GetS ||
                demand.opcode == coherence_pkg::LoadReserved || demand.opcode ==
                    coherence_pkg::GetM ||
                demand.opcode == coherence_pkg::Prefetch) begin
              phase_q <= Apply;
            end else begin
              probe_q.opcode <= demand.opcode == coherence_pkg::DMAWrite ?
                  coherence_pkg::ProbeInvalidate : coherence_pkg::ProbeRead;
              probe_q.reason <= demand.opcode == coherence_pkg::DMAWrite ?
                  coherence_pkg::Write : coherence_pkg::Read;
              probe_q.check_q <= demand.q;
              phase_q <= ProbeSend;
            end
          end
          Apply: begin
            if (put_active_q || demand.opcode == coherence_pkg::DMAWrite) begin
              for (int byte_idx = 0; byte_idx < 32; byte_idx++) begin
                if (sector_mask[byte_idx])
                  image_q[(LINE_BYTES == 64 && address_q[5] ? 256 : 0)+8*byte_idx+:8] <=
                      sector_data[8*byte_idx+:8];
              end
            end
            line_state_q <= result_state;
            phase_q <= Update;
          end
          Update: if (array_update_ready) phase_q <= UpdateWait;
          UpdateWait:
          if (array_req_ready) begin
            if (put_active_q) begin
              ack_q <= '0;
              ack_q.hart <= put_q.hart;
              ack_q.put_id <= put_q.put_id;
              ack_q.epoch <= put_q.epoch;
              ack_q.addr <= put_q.addr;
              ack_q.tid <= PutTid;
              phase_q <= PutAck;
            end else phase_q <= Result;
          end
          Result: if (result_ready) phase_q <= Complete;
          Complete: if (o_u_valid && i_u_ready) phase_q <= Idle;
          PutAck: if (i_wa_ready) phase_q <= Idle;
          default: begin
          end
        endcase
      end
    end
  end

  if (NUM_WB < 1 || NUM_WB > 16) begin : gen_invalid
    initial $fatal(1, "coherence_home: invalid writeback capacity");
  end
`ifndef SYNTHESIS
`ifdef FORMAL
  always_comb begin
`else
  always @(posedge i_clk) begin
`endif
    p_probe_valid_exact : assert (o_p_valid == (active && phase_q == ProbeSend));
  end
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      if (i_r_valid && phase_q == ProbeWait) assert (probe_matches);
      if (i_w_valid && o_w_ready) assert (put_in.hart == 0 && put_in.epoch == 0);
      if (phase_q == LookupWait && array_resp_valid) assert (array_available);
      if (i_mem_resp_valid && i_mem_resp_id[4])
        assert (wb_valid_q[WbBits'(i_mem_resp_id)] && wb_sent_q[WbBits'(i_mem_resp_id)]);
      if (i_mem_resp_valid && !i_mem_resp_id[4])
        assert (fill_valid_q && fill_sent_q && !fill_done_q && i_mem_resp_id == 0);
      if (o_g_valid) assert (!victim_q && endpoint_live && phase_q == Result);
    end
  end
`endif
`ifdef FORMAL
`ifdef COHERENCE_HOME_WB_PROOF
  logic f_past_valid = 1'b0;
  (* anyconst *) logic [$clog2(LINE_BYTES)-1:0] f_byte;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (!i_rst && i_mem_resp_valid && i_mem_resp_id[4]) assume (int'(i_mem_resp_id[3:0]) < NUM_WB);
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      for (int slot = 0; slot < NUM_WB; slot++) begin
        if ($past(
                wb_valid_q[slot]
            ) && !$past(
                i_mem_resp_valid && i_mem_resp_id == (5'd16 | 5'(slot)) && !i_mem_resp_error
            )) begin
          assert (wb_valid_q[slot]);
          assert (wb_addr_q[slot] == $past(wb_addr_q[slot]));
          assert (wb_data_q[slot][8*f_byte+:8] == $past(wb_data_q[slot][8*f_byte+:8]));
        end
      end
      if (address_locked && phase_q == Lookup) assert (!lookup_fire);
    end
  end
`else
  logic f_past_valid = 1'b0;
  wire [7:0] f_reply_byte = reply.data[7:0];
  wire f_reply_upper = LINE_BYTES == 64 && reply.addr[5];
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (!i_rst) begin
      if (i_w_valid) assume (put_in.hart == 0 && put_in.epoch == 0 && put_in.addr[4:0] == 0);
      if (i_r_valid && phase_q == ProbeWait) assume (probe_matches);
      if (i_mem_resp_valid) begin
        if (i_mem_resp_id[4]) begin
          assume (int'(i_mem_resp_id[3:0]) < NUM_WB);
          assume (wb_valid_q[WbBits'(i_mem_resp_id)] && wb_sent_q[WbBits'(i_mem_resp_id)]);
        end else assume (fill_valid_q && fill_sent_q && !fill_done_q && i_mem_resp_id == 0);
      end
    end
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      if ($past(o_mem_req_valid && !i_mem_req_ready)) begin
        assert (o_mem_req_valid);
        assert ({o_mem_req_addr, o_mem_req_id, o_mem_req_write} == $past(
            {o_mem_req_addr, o_mem_req_id, o_mem_req_write}
        ));
      end
      if (o_g_valid || o_u_valid) assert (!o_d_ready && !o_w_ready);
      if (address_locked && phase_q == Lookup) assert (!lookup_fire);
      for (int slot = 0; slot < NUM_WB; slot++) begin
        if ($past(
                wb_valid_q[slot]
            ) && !$past(
                i_mem_resp_valid && i_mem_resp_id == (5'd16 | 5'(slot)) && !i_mem_resp_error
            )) begin
          assert (wb_valid_q[slot]);
          assert (wb_addr_q[slot] == $past(wb_addr_q[slot]));
          assert (wb_data_q[slot][7:0] == $past(wb_data_q[slot][7:0]));
        end
      end
      if ($past(active && phase_q == Apply)) begin
        if ($past((put_active_q || demand.opcode == coherence_pkg::DMAWrite) && sector_mask[0]))
          assert (image_q[($past(
              LINE_BYTES == 64 && address_q[5]
          ) ? 256 : 0)+:8] == $past(
              sector_data[7:0]
          ));
          else assert (image_q[7:0] == $past(image_q[7:0]));
      end
      if ($past(
              active && phase_q == ProbeWait && i_r_valid && o_r_ready &&
          !reply.error && reply.data_valid
          ))
        assert (image_q[($past(f_reply_upper) ? 256 : 0)+:8] == $past(f_reply_byte));
      if (o_wa_valid && ack_q.absorbed) begin
        assert (phase_q == AbsorbAck);
        assert (ack_q.tid == probe_q.tid && ack_q.addr == probe_q.addr);
      end
      if ($past(active && o_p_valid && !i_p_ready) && active) begin
        assert (o_p_valid);
        assert (o_p == $past(o_p));
      end
      if ($past(active && o_wa_valid && !i_wa_ready) && active) begin
        assert (o_wa_valid);
        assert (o_wa == $past(o_wa));
      end
      cover (o_g_valid && i_g_ready && result.opcode == coherence_pkg::GrantM);
      cover (o_wa_valid && ack_q.absorbed && i_wa_ready);
    end
  end
`endif
`ifdef COHERENCE_HOME_COVER
  logic [6:0] f_wb_age = 0;
  always_ff @(posedge i_clk) begin
    if (i_rst || !wb_sent_q[0]) f_wb_age <= 0;
    else if (f_wb_age != 127) f_wb_age <= f_wb_age + 1'b1;
    if (!i_rst) begin
      cover (wb_valid_q[0]);
      cover (wb_sent_q[0] && f_wb_age >= 3);
      cover (address_locked && phase_q == Lookup && !lookup_fire);
`ifdef COHERENCE_HOME_COVER_ERROR
      cover (o_fatal && wb_valid_q[0] && wb_sent_q[0]);
`else
      cover (f_past_valid && $past(!i_rst && wb_valid_q[0] && wb_sent_q[0] &&
          i_mem_resp_valid && i_mem_resp_id == 16 && !i_mem_resp_error) && !wb_valid_q[0]);
`endif
    end
  end
`endif
`endif
endmodule
