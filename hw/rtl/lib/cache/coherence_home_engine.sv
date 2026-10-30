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

// A resident request owns its image until the completion credit returns.
module coherence_home_engine #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 64,
    parameter int unsigned WAYS = 4,
    localparam int unsigned WayBits = WAYS > 1 ? $clog2(WAYS) : 1
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_stop,
    input logic i_work_valid,
    input logic [ADDR_WIDTH+311:0] i_work,
    input logic [5:0] i_tid,
    input logic i_work_error,
    output logic o_idle,
    output logic o_lookup_valid,
    input logic i_lookup_ready,
    output logic [ADDR_WIDTH-1:0] o_addr,
    output logic [5:0] o_tid,
    output logic [3:0] o_opcode,
    output logic o_maintenance,
    input logic i_decision_valid,
    input logic i_decision_resident,
    input logic [WayBits-1:0] i_decision_way,
    input logic [1:0] i_decision_state,
    output logic o_read_valid,
    output logic o_read_offer,
    input logic i_read_ready,
    output logic [WayBits-1:0] o_way,
    input logic i_data_valid,
    input logic [8*LINE_BYTES-1:0] i_data,
    output logic o_p_valid,
    input logic i_p_ready,
    output logic [ADDR_WIDTH+29:0] o_p,
    input logic i_r_valid,
    output logic o_r_ready,
    input logic [ADDR_WIDTH+274:0] i_r,
    output logic o_wa_valid,
    input logic i_wa_ready,
    output logic [ADDR_WIDTH+10:0] o_wa,
    output logic o_update_valid,
    input logic i_update_ready,
    output logic [LINE_BYTES-1:0] o_update_mask,
    output logic [8*LINE_BYTES-1:0] o_update_data,
    input logic i_updated,
    output logic o_result_valid,
    input logic i_result_ready,
    output logic [ADDR_WIDTH+274:0] o_result,
    output logic [255:0] o_image,
`ifdef COHERENCE_HOME_CONTROL
    output logic o_tag_owner,
    output logic o_unpinned_owner,
    output logic o_pin_owner,
    output logic o_initial_error,
    output logic o_read_owner,
    output logic o_update_owner,
`endif
    output logic o_fatal
);
  `FROST_COHERENCE_TYPES(ADDR_WIDTH)
  // Lookup lasts from work acceptance through the tag decision;
  // lookup_sent_q records that the tag port accepted the lookup.
  typedef enum logic [3:0] {
    Free,
    Lookup,
    Service,
    Update,
    UpdateWait,
    Result,
    Fatal
  } phase_t;
  typedef enum logic [2:0] {
    ProbeDone,
    ProbeOffer,
    ProbeWait,
    ProbeAck
  } probe_phase_t;
  phase_t phase_q;
  probe_phase_t probe_phase_q;
  coh_d_t request_q;
  coh_p_t probe_q;
  coh_r_t reply;
  coh_wa_t ack_q;
  coh_g_t result;
  logic [5:0] tid_q;
  logic [WayBits-1:0] way_q;
  logic [8*LINE_BYTES-1:0] image_q;
  logic [1:0] state_q;
  logic read_sent_q, read_done_q, dirty_q, failed_q, error_q, lookup_sent_q;
  logic probe_matches, upper, run, active, needs_probe, needs_data;
  logic reply_fire, reply_fatal, service_error, service_dirty, service_complete;
  logic data_complete, probe_complete, deciding;
  // Reset clears every register below and the home's arbiters, so internal
  // work and the offers to those arbiters are qualified by the stop alone.
  assign run = !i_stop;
  assign active = !i_rst && run;
  assign reply = i_r;
  assign upper = LINE_BYTES == 64 && request_q.addr[5];
  assign needs_probe = request_q.opcode == coherence_pkg::Atomic ||
      request_q.opcode == coherence_pkg::StoreConditional ||
      request_q.opcode == coherence_pkg::ReadOnceIF ||
      request_q.opcode == coherence_pkg::ReadOncePTW ||
      request_q.opcode == coherence_pkg::DMARead || request_q.opcode == coherence_pkg::DMAWrite;
  assign needs_data = request_q.opcode != coherence_pkg::DMAWrite &&
      request_q.opcode != coherence_pkg::Prefetch;
  assign o_idle = phase_q == Free;
  assign deciding = phase_q == Lookup && lookup_sent_q;
`ifdef COHERENCE_HOME_CONTROL
  assign o_tag_owner = deciding;
  assign o_unpinned_owner = phase_q == Lookup;
  assign o_pin_owner = phase_q == Service || phase_q == Update ||
      phase_q == UpdateWait || phase_q == Fatal || (phase_q == Result && read_sent_q);
  always_ff @(posedge i_clk) begin
    if (i_rst) o_initial_error <= 1'b0;
    else if (active && i_work_valid) o_initial_error <= i_work_error;
    if (!i_rst && phase_q == Result && !read_sent_q) assert (o_initial_error);
    if (!i_rst && phase_q != Free && o_initial_error)
      assert (phase_q == Result && error_q && !read_sent_q);
  end
  assign o_read_owner   = (phase_q == Service || phase_q == Fatal) && read_sent_q && !read_done_q;
  assign o_update_owner = phase_q == UpdateWait;
`endif
  assign o_lookup_valid = run && phase_q == Lookup && !lookup_sent_q;
  assign o_addr = request_q.addr;
  assign o_tid = tid_q;
  assign o_opcode = request_q.opcode;
  assign o_maintenance = request_q.maintenance;
  assign o_way = way_q;
  assign o_read_offer = phase_q == Service && !read_sent_q;
  assign o_read_valid = run && o_read_offer;
  assign o_p_valid = run && phase_q == Service && probe_phase_q == ProbeOffer;
  assign o_p = probe_q;
  assign probe_matches = reply.tid == tid_q && reply.addr == probe_q.addr &&
      reply.epoch == probe_q.epoch && reply.hart == 0 &&
      (probe_q.opcode == coherence_pkg::CheckSC ? reply.opcode == coherence_pkg::CheckAck :
       reply.opcode == coherence_pkg::ProbeAck || reply.opcode == coherence_pkg::ProbeData);
  assign o_r_ready = run && phase_q == Service && probe_phase_q == ProbeWait && probe_matches;
  assign reply_fire = i_r_valid && o_r_ready;
  assign reply_fatal = reply_fire && reply.error &&
      (reply.data_valid || reply.absorbed || reply.state == coherence_pkg::Modified ||
       state_q == coherence_pkg::Modified || request_q.opcode == coherence_pkg::GetM);
  assign data_complete = read_done_q || i_data_valid;
  assign probe_complete = probe_phase_q == ProbeDone ||
      (probe_phase_q == ProbeAck && i_wa_ready) ||
      (reply_fire && (reply.error || (!reply.absorbed &&
       (probe_q.opcode != coherence_pkg::CheckSC || !reply.sc_valid))));
  assign service_error = error_q || (reply_fire && reply.error);
  assign service_dirty = dirty_q || (reply_fire && reply.data_valid);
  assign service_complete = phase_q == Service && data_complete && probe_complete && !reply_fatal;
  assign o_wa_valid = run && phase_q == Service && probe_phase_q == ProbeAck;
  assign o_wa = ack_q;
  assign o_update_valid = run && phase_q == Update;
  assign o_update_data = image_q;
  assign o_update_mask = LINE_BYTES'(dirty_q ? 32'hffff_ffff : request_q.mask) << (upper ? 32 : 0);
  assign o_result_valid = run && phase_q == Result;
  assign o_result = result;
  assign o_image = image_q[(upper ? 256 : 0)+:256];
  assign o_fatal = phase_q == Fatal;
  always_comb begin
    result = '0;
    result.q = request_q.q;
    result.addr = request_q.addr;
    result.tid = tid_q;
    result.error = error_q;
    result.opcode = coherence_pkg::GrantData;
    result.data = o_image;
    case (request_q.opcode)
      coherence_pkg::GetS, coherence_pkg::LoadReserved: result.opcode = coherence_pkg::GrantS;
      coherence_pkg::GetM, coherence_pkg::Atomic: result.opcode = coherence_pkg::GrantM;
      coherence_pkg::StoreConditional:
      result.opcode = failed_q ? coherence_pkg::GrantFail : coherence_pkg::GrantM;
      coherence_pkg::DMAWrite, coherence_pkg::Prefetch: begin
        result.opcode = coherence_pkg::GrantAck;
        result.data   = '0;
      end
      default: begin
      end
    endcase
  end
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      phase_q <= Free;
      probe_phase_q <= ProbeDone;
      request_q <= '0;
      probe_q <= '0;
      ack_q <= '0;
      tid_q <= '0;
      way_q <= '0;
      state_q <= '0;
      read_sent_q <= 1'b0;
      read_done_q <= 1'b0;
      dirty_q <= 1'b0;
      failed_q <= 1'b0;
      error_q <= 1'b0;
      lookup_sent_q <= 1'b0;
    end else if (run) begin
      if (i_work_valid) begin
        request_q <= i_work;
        tid_q <= i_tid;
        error_q <= i_work_error;
        failed_q <= 1'b0;
        dirty_q <= 1'b0;
        read_sent_q <= 1'b0;
        read_done_q <= 1'b0;
        lookup_sent_q <= 1'b0;
        phase_q <= i_work_error ? Result : Lookup;
      end
      if (o_lookup_valid && i_lookup_ready) lookup_sent_q <= 1'b1;
      if (deciding && i_decision_valid) begin
        if (!i_decision_resident) phase_q <= Free;
        else begin
          way_q <= i_decision_way;
          state_q <= i_decision_state;
          read_sent_q <= !needs_data;
          read_done_q <= !needs_data;
          probe_phase_q <= needs_probe ? ProbeOffer : ProbeDone;
          probe_q <= '0;
          probe_q.tid <= tid_q;
          probe_q.addr <= request_q.addr;
          probe_q.requester <= request_q.q.src;
          probe_q.check_q <= request_q.q;
          probe_q.offset <= request_q.offset;
          probe_q.size <= request_q.size;
          probe_q.opcode <= request_q.opcode == coherence_pkg::StoreConditional ?
              coherence_pkg::CheckSC : request_q.opcode == coherence_pkg::DMAWrite ?
              coherence_pkg::ProbeInvalidate : coherence_pkg::ProbeRead;
          probe_q.reason <= request_q.opcode == coherence_pkg::StoreConditional ?
              coherence_pkg::Check : request_q.opcode == coherence_pkg::DMAWrite ?
              coherence_pkg::Write : coherence_pkg::Read;
          phase_q <= Service;
        end
      end
      if (o_read_valid && i_read_ready) read_sent_q <= 1'b1;
      if (i_data_valid) begin
        read_done_q <= 1'b1;
        for (int sector = 0; sector < LINE_BYTES / 32; sector++)
        if (!dirty_q || (sector != int'(upper)))
          image_q[sector*256+:256] <= i_data[sector*256+:256];
      end
      if (o_p_valid && i_p_ready) probe_phase_q <= ProbeWait;
      if (i_r_valid && o_r_ready) begin
        if (reply.data_valid) begin
          image_q[(upper ? 256 : 0)+:256] <= reply.data;
          dirty_q <= 1'b1;
        end
        if (reply.error) begin
          if (reply.data_valid || reply.absorbed || reply.state == coherence_pkg::Modified ||
              state_q == coherence_pkg::Modified || request_q.opcode == coherence_pkg::GetM)
            phase_q <= Fatal;
          else begin
            error_q <= 1'b1;
            probe_phase_q <= ProbeDone;
          end
        end else begin
          if (probe_q.opcode == coherence_pkg::CheckSC) begin
            failed_q <= !reply.sc_valid;
            probe_phase_q <= reply.sc_valid ? ProbeOffer : ProbeDone;
            probe_q.opcode <= coherence_pkg::ProbeRead;
            probe_q.reason <= coherence_pkg::Read;
          end else probe_phase_q <= ProbeDone;
          if (reply.absorbed) begin
            ack_q <= '0;
            ack_q.hart <= reply.hart;
            ack_q.put_id <= reply.put_id;
            ack_q.epoch <= reply.put_epoch;
            ack_q.addr <= reply.addr;
            ack_q.absorbed <= 1'b1;
            ack_q.tid <= reply.tid;
            probe_phase_q <= ProbeAck;
          end
        end
      end
      if (o_wa_valid && i_wa_ready) probe_phase_q <= ProbeDone;
      if (service_complete) begin
        if (request_q.opcode == coherence_pkg::DMAWrite && !service_error) begin
          for (int byte_idx = 0; byte_idx < 32; byte_idx++)
          if (request_q.mask[byte_idx])
            image_q[(upper ? 256 : 0)+8*byte_idx+:8] <= request_q.wdata[8*byte_idx+:8];
        end
        phase_q <= !service_error &&
            (service_dirty || request_q.opcode == coherence_pkg::DMAWrite) ? Update : Result;
      end
      if (o_update_valid && i_update_ready) phase_q <= UpdateWait;
      if (phase_q == UpdateWait && i_updated) phase_q <= Result;
      if (o_result_valid && i_result_ready) phase_q <= Free;
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge i_clk)
    if (!i_rst) begin
      assert (!read_done_q || read_sent_q);
      if (phase_q == Update || phase_q == UpdateWait)
        assert (read_done_q && probe_phase_q == ProbeDone);
      if (i_work_valid) assert (o_idle);
      if (i_decision_valid) assert (deciding);
      if (i_data_valid)
        assert ((phase_q == Service || phase_q == Fatal) && read_sent_q && !read_done_q);
      if (i_updated) assert (phase_q == UpdateWait);
      if (o_r_ready) assert (probe_matches);
      if (phase_q == Lookup) assert (!read_sent_q && !read_done_q && !dirty_q);
      if (phase_q == Update || phase_q == UpdateWait || phase_q == Result)
        if (!error_q) assert (read_done_q && probe_phase_q == ProbeDone);
    end
`endif
`ifdef FORMAL
`ifndef COHERENCE_HOME_CONTROL
  logic f_past_valid = 1'b0;
  (* anyconst *) logic [4:0] f_byte;
  logic [7:0] f_baseline_q, f_dirty_value_q;
  logic f_baseline_valid_q, f_dirty_valid_q;
  wire [7:0] f_write_byte = request_q.wdata[8*f_byte+:8];
  wire f_write_mask = request_q.mask[f_byte];
  wire [7:0] f_image_byte = o_image[8*f_byte+:8];
  wire [7:0] f_data_byte = i_data[(upper ? 256 : 0)+8*f_byte+:8];
  wire [7:0] f_reply_byte = reply.data[8*f_byte+:8];
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (!f_past_valid) assume (i_rst);
    if (i_work_valid) assume (o_idle && active);
    if (i_decision_valid) begin
      assume (deciding && active);
      assume (int'(i_decision_way) < WAYS);
    end
    if (i_data_valid)
      assume ((phase_q == Service || phase_q == Fatal) &&
          needs_data && read_sent_q && !read_done_q);
    if (i_updated) assume (phase_q == UpdateWait);
    if (i_r_valid && o_r_ready && probe_q.opcode == coherence_pkg::CheckSC)
      assume (!reply.data_valid && !reply.absorbed);
    if (f_past_valid && !$past(i_rst) && $past(i_stop)) assume (i_stop || i_rst);
    if (i_rst || i_work_valid) begin
      f_baseline_valid_q <= 1'b0;
      f_dirty_valid_q <= 1'b0;
    end else if (active) begin
      if (i_data_valid) begin
        f_baseline_q <= f_data_byte;
        f_baseline_valid_q <= 1'b1;
      end
      if (i_r_valid && o_r_ready && reply.data_valid) begin
        f_dirty_value_q <= f_reply_byte;
        f_dirty_valid_q <= 1'b1;
      end
      if (phase_q == Lookup) begin
        assert (!read_sent_q && !read_done_q && !dirty_q);
        assert (!f_baseline_valid_q && !f_dirty_valid_q);
      end
      if (phase_q == Service || phase_q == Fatal) begin
        assert (dirty_q == f_dirty_valid_q);
        if (needs_data && read_done_q) assert (f_baseline_valid_q);
        if (f_dirty_valid_q)
          assert (f_image_byte == f_dirty_value_q);
          else if (f_baseline_valid_q) assert (f_image_byte == f_baseline_q);
      end
      if (phase_q == Update || phase_q == UpdateWait || phase_q == Result) begin
        if (!error_q && needs_data) assert (f_baseline_valid_q);
        if (!error_q && request_q.opcode == coherence_pkg::DMAWrite && f_write_mask)
          assert (f_image_byte == f_write_byte);
          else if (!error_q && f_dirty_valid_q)
            assert (f_image_byte == f_dirty_value_q);
            else if (!error_q && f_baseline_valid_q) assert (f_image_byte == f_baseline_q);
      end
      if (phase_q == Update || phase_q == UpdateWait || phase_q == Result)
        if (!error_q) assert (read_done_q && probe_phase_q == ProbeDone);
      if (phase_q == Result) assert (probe_phase_q == ProbeDone || error_q);
      if (o_update_valid)
        assert (!error_q && (dirty_q || request_q.opcode == coherence_pkg::DMAWrite));
    end
    if (f_past_valid && !i_rst && !$past(i_rst) && active) begin
      if ($past(o_p_valid && !i_p_ready)) assert (o_p_valid && o_p == $past(o_p));
      if ($past(o_wa_valid && !i_wa_ready)) assert (o_wa_valid && o_wa == $past(o_wa));
      if ($past(o_result_valid && !i_result_ready))
        assert (o_result_valid && o_result == $past(o_result));
      if ($past(o_update_valid && !i_update_ready)) begin
        assert (o_update_valid);
        assert ({o_update_data, o_update_mask} == $past({o_update_data, o_update_mask}));
      end
      cover (i_r_valid && o_r_ready && reply.data_valid && i_data_valid);
      cover (o_result_valid && failed_q);
      cover (o_result_valid && f_dirty_valid_q && request_q.opcode == coherence_pkg::DMAWrite);
    end
  end
`endif
`endif

endmodule
