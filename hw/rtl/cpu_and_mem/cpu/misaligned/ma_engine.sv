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
 * Misaligned-access engine
 *
 * Performs one misaligned plain load or store after the core has stopped
 * everything around it: every older instruction has retired and its stores
 * are installed, nothing younger has been dispatched, and new architectural
 * work stays held while o_busy is set. The access is described by i_start's
 * operands. The engine
 *
 *   1. waits for i_older_vector_mem_done (older vector memory instructions
 *      complete; tied high in a core without a vector unit),
 *   2. reads the store data register through the register-file read port,
 *   3. checks the lower part, then the upper part if the access crosses a
 *      32-byte sector, as ma_pkg defines them: Bare accesses use the virtual
 *      address as the physical one; translated ones walk the page table
 *      through the walker port (one walk per page; an upper part in the same
 *      page reuses the lower part's leaf),
 *   4. stops with o_fault and the ma_pkg outcome if either part does not
 *      pass, before any memory request,
 *   5. otherwise issues the lower sector's request and then the upper
 *      sector's on the line client (sector reads for a load, masked sector
 *      writes for a store), with request identities 0 and 1, and waits for
 *      every response,
 *   6. writes a load's value through the write-back port and pulses o_done.
 *
 * A load response with an error ends the access, once every response is in,
 * with a load access fault whose trap value is zero, as the load queue reports
 * bus errors. A store response with an error, and i_fatal_stop at any time,
 * are terminal at once: the engine issues no further request, raises
 * o_fatal_error for a failed write, stays busy, and never reports completion
 * or a fault again until reset. Nothing completes, faults or requests on the
 * edge that samples i_fatal_stop or receives a failed write.
 *
 * The walker port's responses must already be routed to this requester; the
 * engine also ignores a response whose VPN echo is not the page it asked for.
 * The line client must answer each issued identity exactly once.
 */
module ma_engine #(
    parameter int unsigned LC_ID_BITS = 1,
    localparam int unsigned XLEN = riscv_pkg::XLEN,
    localparam int unsigned SectorBytes = ma_pkg::SectorBytes,
    localparam int unsigned SectorBits = 8 * SectorBytes
) (
    input logic i_clk,
    input logic i_rst,

    // Start: one pulse while o_busy is clear.
    input logic                            i_start,
    input logic                 [XLEN-1:0] i_va,
    input riscv_pkg::mem_size_e            i_size,
    input logic                            i_unsigned,
    input logic                            i_store,
    // FP destination (FLW/FLD) or FP data source (FSW/FSD).
    input logic                            i_fp,
    input logic                 [     4:0] i_rd,
    input logic                            i_rd_valid,
    input logic                 [     4:0] i_rs2,
    // Older vector memory instructions have completed.
    input logic                            i_older_vector_mem_done,
    // Registered translation state (as the data MMU receives it).
    input logic                            i_translate,
    input logic                            i_eff_priv_u,
    input logic                            i_sum,
    input logic                            i_mxr,
    // Hart stop: terminal for the engine.
    input logic                            i_fatal_stop,

    output logic o_busy,
    output logic o_done,
    output logic o_fault,
    output logic [ma_pkg::CauseBits-1:0] o_fault_cause,
    output logic [XLEN-1:0] o_fault_tval,
    output logic o_fatal_error,

    // Register-file read: the address is held while o_rf_read_en is set, and
    // i_rf_read_data is the register's value from the cycle after it is
    // first presented.
    output logic            o_rf_read_en,
    output logic            o_rf_read_fp,
    output logic [     4:0] o_rf_read_addr,
    input  logic [XLEN-1:0] i_rf_read_data,

    // Register write-back, one pulse.
    output logic            o_wb_valid,
    output logic            o_wb_fp,
    output logic [     4:0] o_wb_rd,
    output logic [XLEN-1:0] o_wb_data,

    // Page-table walker requester.
    output logic                                              o_walk_req_valid,
    input  logic                                              i_walk_req_ready,
    output logic                 [riscv_pkg::Sv39VpnBits-1:0] o_walk_vpn,
    input  logic                                              i_walk_resp_valid,
    input  riscv_pkg::ptw_resp_t                              i_walk_resp,

    // Line client: 32-byte sector requests and their responses.
    output logic                   o_lc_req_valid,
    input  logic                   i_lc_req_ready,
    output logic                   o_lc_req_write,
    output logic [       XLEN-1:0] o_lc_req_addr,
    output logic [ SectorBits-1:0] o_lc_req_data,
    output logic [SectorBytes-1:0] o_lc_req_mask,
    output logic [ LC_ID_BITS-1:0] o_lc_req_id,
    input  logic                   i_lc_resp_valid,
    input  logic [ LC_ID_BITS-1:0] i_lc_resp_id,
    input  logic                   i_lc_resp_error,
    input  logic [ SectorBits-1:0] i_lc_resp_data
);

  typedef enum logic [3:0] {
    S_IDLE,
    S_ORDER,
    S_RF_READ,
    S_RF_CAPTURE,
    S_XLATE,
    S_WALK_REQ,
    S_WALK_RESP,
    S_DECIDE,
    S_ISSUE_LO,
    S_ISSUE_HI,
    S_WAIT_RESP,
    S_FINISH,
    S_FATAL
  } state_e;

  state_e state_q;

  // Captured access.
  logic [XLEN-1:0] va_q;
  riscv_pkg::mem_size_e size_q;
  logic unsigned_q, store_q, fp_q, rd_valid_q;
  logic [4:0] rd_q, rs2_q;
  logic translate_q;
  logic [XLEN-1:0] data_q;

  // Translation results.
  logic part_q;  // 0: lower part, 1: upper part
  ma_pkg::ma_part_e lower_q, upper_q;
  logic [XLEN-1:0] lower_pa_q, upper_pa_q;
  logic [riscv_pkg::Sv39VpnBits-1:0] walk_vpn_q;

  // Memory phase.
  logic [1:0] resp_seen_q;
  logic resp_error_q;
  logic [SectorBits-1:0] lo_line_q, hi_line_q;
  logic fatal_error_q;

  logic split;
  assign split = ma_pkg::crosses_sector(size_q, va_q);

  logic [XLEN-1:0] upper_va;
  assign upper_va = ma_pkg::upper_va(va_q);

  logic [XLEN-1:0] part_va;
  assign part_va = part_q ? upper_va : va_q;

  // Verdict of a walk response for the part being translated.
  logic walk_resp_match;
  assign walk_resp_match = i_walk_resp_valid && (i_walk_resp.vpn == walk_vpn_q);

  ma_pkg::ma_part_e walk_verdict;
  logic [XLEN-1:0] walk_pa;
  assign walk_pa = ma_pkg::leaf_pa(i_walk_resp.ppn, i_walk_resp.level, part_va);
  always_comb begin
    unique case (i_walk_resp.fault_kind)
      riscv_pkg::DFAULT_PAGE:   walk_verdict = ma_pkg::MaPartPage;
      riscv_pkg::DFAULT_ACCESS: walk_verdict = ma_pkg::MaPartAccess;
      default: begin
        if (!ma_pkg::leaf_perm_ok(
                store_q,
                i_walk_resp.perm_r,
                i_walk_resp.perm_w,
                i_walk_resp.perm_x,
                i_walk_resp.perm_u,
                i_walk_resp.perm_d,
                i_eff_priv_u,
                i_sum,
                i_mxr
            ))
          walk_verdict = ma_pkg::MaPartPage;
        else if (ma_pkg::leaf_ppn_out_of_range(i_walk_resp.ppn))
          walk_verdict = ma_pkg::MaPartAccess;
        else walk_verdict = ma_pkg::region(walk_pa, 1'b0);
      end
    endcase
  end

  // Verdict available without a walk: Bare, a non-canonical address, or an
  // upper part in the lower part's page.
  logic xlate_direct;
  ma_pkg::ma_part_e direct_verdict;
  logic [XLEN-1:0] direct_pa;
  always_comb begin
    xlate_direct = 1'b1;
    direct_pa = part_va;
    if (!translate_q) begin
      direct_verdict = ma_pkg::region(part_va, store_q);
    end else if (!riscv_pkg::sv39_va_canonical(part_va)) begin
      direct_verdict = ma_pkg::MaPartPage;
    end else if (part_q && (upper_va[XLEN-1:12] == va_q[XLEN-1:12])) begin
      direct_pa = {lower_pa_q[XLEN-1:12], upper_va[11:0]};
      direct_verdict = ma_pkg::region(direct_pa, 1'b0);
    end else begin
      xlate_direct   = 1'b0;
      direct_verdict = ma_pkg::MaPartOk;
    end
  end

  ma_pkg::ma_outcome_t outcome;
  assign outcome = ma_pkg::outcome(lower_q, upper_q, split, store_q, va_q);

  // Alignment between register order and the two sectors.
  logic [SectorBits-1:0] place_lo_data, place_hi_data;
  logic [SectorBytes-1:0] place_lo_mask, place_hi_mask;
  logic [63:0] extract_raw;
  line_align #(
      .LINE_BYTES(SectorBytes),
      .DATA_BYTES(8)
  ) align (
      .i_offset (va_q[ma_pkg::SectorOffsetBits-1:0]),
      .i_nbytes (ma_pkg::size_bytes(size_q)),
      .i_lo_line(lo_line_q),
      .i_hi_line(hi_line_q),
      .o_extract(extract_raw),
      .i_data   (data_q),
      .o_lo_data(place_lo_data),
      .o_hi_data(place_hi_data),
      .o_lo_mask(place_lo_mask),
      .o_hi_mask(place_hi_mask),
      .o_crosses()
  );

  logic [1:0] resp_expected;
  assign resp_expected = {split, 1'b1};

  logic [1:0] resp_seen_next;
  always_comb begin
    resp_seen_next = resp_seen_q;
    if (i_lc_resp_valid) resp_seen_next[i_lc_resp_id[0]] = 1'b1;
  end

  logic in_memory_phase;
  assign in_memory_phase = (state_q == S_ISSUE_LO) || (state_q == S_ISSUE_HI) ||
      (state_q == S_WAIT_RESP);

  logic store_write_failed;
  assign store_write_failed = in_memory_phase && store_q && i_lc_resp_valid && i_lc_resp_error;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      state_q <= S_IDLE;
      fatal_error_q <= 1'b0;
    end else if (i_fatal_stop) begin
      state_q <= S_FATAL;
    end else if (store_write_failed) begin
      // A failed write is terminal at once: no further request is issued,
      // and responses still outstanding are absorbed in S_FATAL.
      state_q <= S_FATAL;
      fatal_error_q <= 1'b1;
    end else begin
      unique case (state_q)
        S_IDLE: if (i_start) state_q <= S_ORDER;
        S_ORDER: if (i_older_vector_mem_done) state_q <= store_q ? S_RF_READ : S_XLATE;
        S_RF_READ: state_q <= S_RF_CAPTURE;
        S_RF_CAPTURE: state_q <= S_XLATE;
        S_XLATE: begin
          if (xlate_direct) begin
            if (!part_q && (direct_verdict == ma_pkg::MaPartOk) && split) begin
              part_q <= 1'b1;
            end else begin
              state_q <= S_DECIDE;
            end
          end else begin
            state_q <= S_WALK_REQ;
          end
        end
        S_WALK_REQ: if (i_walk_req_ready) state_q <= S_WALK_RESP;
        S_WALK_RESP: begin
          if (walk_resp_match) begin
            if (!part_q && (walk_verdict == ma_pkg::MaPartOk) && split) begin
              part_q  <= 1'b1;
              state_q <= S_XLATE;
            end else begin
              state_q <= S_DECIDE;
            end
          end
        end
        S_DECIDE: state_q <= outcome.ok ? S_ISSUE_LO : S_IDLE;
        S_ISSUE_LO: if (i_lc_req_ready) state_q <= split ? S_ISSUE_HI : S_WAIT_RESP;
        S_ISSUE_HI: if (i_lc_req_ready) state_q <= S_WAIT_RESP;
        S_WAIT_RESP: begin
          if (resp_seen_next == resp_expected) state_q <= S_FINISH;
        end
        S_FINISH: state_q <= S_IDLE;
        default: ;  // S_FATAL holds until reset
      endcase
      if (state_q == S_IDLE && i_start) part_q <= 1'b0;
    end
  end

  // Datapath registers (no reset: each is written before it is read).
  always_ff @(posedge i_clk) begin
    if (state_q == S_IDLE && i_start) begin
      va_q <= i_va;
      size_q <= i_size;
      unsigned_q <= i_unsigned;
      store_q <= i_store;
      fp_q <= i_fp;
      rd_q <= i_rd;
      rd_valid_q <= i_rd_valid;
      rs2_q <= i_rs2;
      translate_q <= i_translate;
      lower_q <= ma_pkg::MaPartOk;
      upper_q <= ma_pkg::MaPartOk;
      data_q <= '0;
    end
    if (state_q == S_RF_CAPTURE) data_q <= i_rf_read_data;
    if (state_q == S_XLATE && xlate_direct) begin
      if (part_q) begin
        upper_q <= direct_verdict;
        upper_pa_q <= direct_pa;
      end else begin
        lower_q <= direct_verdict;
        lower_pa_q <= direct_pa;
      end
    end
    if (state_q == S_XLATE && !xlate_direct) walk_vpn_q <= part_va[38:12];
    if (state_q == S_WALK_RESP && walk_resp_match) begin
      if (part_q) begin
        upper_q <= walk_verdict;
        upper_pa_q <= walk_pa;
      end else begin
        lower_q <= walk_verdict;
        lower_pa_q <= walk_pa;
      end
    end
    if (state_q == S_DECIDE) begin
      resp_seen_q  <= 2'b00;
      resp_error_q <= 1'b0;
    end
    if (in_memory_phase) begin
      resp_seen_q <= resp_seen_next;
      if (i_lc_resp_valid) begin
        if (i_lc_resp_error) resp_error_q <= 1'b1;
        if (i_lc_resp_id[0]) hi_line_q <= i_lc_resp_data;
        else lo_line_q <= i_lc_resp_data;
      end
    end
  end

  // Outputs.
  assign o_busy = (state_q != S_IDLE);
  assign o_fatal_error = fatal_error_q;

  // Nothing completes, faults or starts a request on the edge that samples a
  // hart stop.
  assign o_fault = !i_fatal_stop && ((state_q == S_DECIDE && !outcome.ok) ||
      (state_q == S_FINISH && !store_q && resp_error_q));
  assign o_fault_cause = (state_q == S_FINISH) ? ma_pkg::part_cause(
      ma_pkg::MaPartAccess, 1'b0
  ) : outcome.cause;
  assign o_fault_tval = (state_q == S_FINISH) ? '0 : outcome.tval;
  assign o_done = !i_fatal_stop && (state_q == S_FINISH) && (store_q || !resp_error_q);

  assign o_rf_read_en = (state_q == S_RF_READ) || (state_q == S_RF_CAPTURE);
  assign o_rf_read_fp = fp_q;
  assign o_rf_read_addr = rs2_q;

  assign o_wb_valid = o_done && !store_q && rd_valid_q;
  assign o_wb_fp = fp_q;
  assign o_wb_rd = rd_q;
  assign o_wb_data = ma_pkg::load_value(extract_raw, size_q, unsigned_q, fp_q);

  assign o_walk_req_valid = !i_fatal_stop && (state_q == S_WALK_REQ);
  assign o_walk_vpn = walk_vpn_q;

  logic issue_hi;
  assign issue_hi = (state_q == S_ISSUE_HI);
  assign o_lc_req_valid = !i_fatal_stop && !store_write_failed &&
      ((state_q == S_ISSUE_LO) || issue_hi);
  assign o_lc_req_write = store_q;
  assign o_lc_req_addr = {
    (issue_hi ? upper_pa_q[XLEN-1:ma_pkg::SectorOffsetBits] :
                lower_pa_q[XLEN-1:ma_pkg::SectorOffsetBits]),
    {ma_pkg::SectorOffsetBits{1'b0}}
  };
  assign o_lc_req_data = issue_hi ? place_hi_data : place_lo_data;
  assign o_lc_req_mask = store_q ? (issue_hi ? place_hi_mask : place_lo_mask) : '0;
  assign o_lc_req_id = LC_ID_BITS'(issue_hi);

  // ---------------------------------------------------------------------------
  // Checks
  // ---------------------------------------------------------------------------
  initial begin
    if (LC_ID_BITS < 1) $fatal(1, "ma_engine needs at least two line-client identities");
    if (ma_pkg::XLEN != riscv_pkg::XLEN || ma_pkg::CauseBits != riscv_pkg::ExcCauseWidth ||
        ma_pkg::PtePpnBits != riscv_pkg::PtePpnBits)
      $fatal(1, "ma_pkg widths differ from riscv_pkg");
  end

`ifndef FORMAL
`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) begin
    if (i_rst) reset_seen_q <= 1'b1;
    if (reset_seen_q && !i_rst) begin
      // A start only while idle; one response per issued identity (late
      // responses may still arrive after a hart stop).
      if (i_start) p_sim_start_idle : assert (state_q == S_IDLE);
      if (i_lc_resp_valid) begin
        p_sim_expected_response :
        assert ((state_q == S_FATAL) ||
                (in_memory_phase && !resp_seen_q[i_lc_resp_id[0]] && (i_lc_resp_id[0] <= split)));
      end
    end
  end
`endif
`endif

`ifdef FORMAL
  // Environment: starts only while idle, one response per issued identity.
  logic [1:0] issued_q;
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
    if (i_rst || (state_q == S_IDLE && i_start)) issued_q <= 2'b00;
    else if (o_lc_req_valid && i_lc_req_ready) issued_q[o_lc_req_id[0]] <= 1'b1;
  end
  always_comb begin
    // Reset in the first cycle; starts only while idle.
    if (!f_past_valid) assume (i_rst);
    assume (i_rst || !i_start || state_q == S_IDLE);
    if (i_lc_resp_valid) begin
      assume (in_memory_phase || state_q == S_FATAL);
      assume (issued_q[i_lc_resp_id[0]] && !resp_seen_q[i_lc_resp_id[0]]);
    end
  end

  // Sequence bookkeeping for the properties. f_lower_checked_q and
  // f_upper_checked_q record that each part's verdict register was written
  // from a translation result in this access.
  logic f_seq_fault_q, f_seq_done_q, f_seq_wb_q;
  logic f_lower_checked_q, f_upper_checked_q;
  logic f_verdict_write;
  assign f_verdict_write = (state_q == S_XLATE && xlate_direct) ||
      (state_q == S_WALK_RESP && walk_resp_match);
  always_ff @(posedge i_clk) begin
    if (i_rst || (state_q == S_IDLE && i_start)) begin
      f_seq_fault_q <= 1'b0;
      f_seq_done_q <= 1'b0;
      f_seq_wb_q <= 1'b0;
      f_lower_checked_q <= 1'b0;
      f_upper_checked_q <= 1'b0;
    end else begin
      if (o_fault) f_seq_fault_q <= 1'b1;
      if (o_done) f_seq_done_q <= 1'b1;
      if (o_wb_valid) f_seq_wb_q <= 1'b1;
      if (f_verdict_write && !part_q) f_lower_checked_q <= 1'b1;
      if (f_verdict_write && part_q) f_upper_checked_q <= 1'b1;
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && !i_rst && !$past(i_rst)) begin
      // No memory request before both parts have passed every check, and the
      // lower sector is always issued before the upper one.
      if (o_lc_req_valid) begin
        p_req_after_checks :
        assert (outcome.ok && f_lower_checked_q && (!split || f_upper_checked_q));
        p_req_lower_first : assert (!issue_hi || issued_q[0]);
        p_req_upper_only_split : assert (!issue_hi || split);
      end
      // Request payload is stable until accepted, unless a hart stop or a
      // failed write ends the access.
      if ($past(
              o_lc_req_valid && !i_lc_req_ready
          ) && !$past(
              i_fatal_stop
          ) && !$past(
              store_write_failed
          ) && !i_fatal_stop && !store_write_failed) begin
        p_req_stable :
        assert (o_lc_req_valid && $stable(
            o_lc_req_id
        ) && $stable(
            o_lc_req_addr
        ) && $stable(
            o_lc_req_mask
        ) && $stable(
            o_lc_req_data
        ) && $stable(
            o_lc_req_write
        ));
      end
      // Each identity is issued at most once per access.
      if (o_lc_req_valid) p_req_once : assert (!issued_q[o_lc_req_id[0]]);
      // Completion and fault: at most one of them per access, never both.
      p_done_fault_excl : assert (!(o_done && o_fault));
      if (o_done || o_fault) p_one_end : assert (!f_seq_done_q && !f_seq_fault_q);
      // Done only once every issued request has answered.
      if (o_done) p_done_after_resp : assert (resp_seen_q == resp_expected && issued_q[0]);
      // A fault after the memory phase is a load's response error, reported
      // as a load access fault with a zero trap value once every response is in.
      if (o_fault && state_q == S_FINISH) begin
        p_late_fault_load :
        assert (!store_q && resp_error_q && resp_seen_q == resp_expected &&
                                    o_fault_cause == 5'd5 && o_fault_tval == '0);
      end
      // A fault before the memory phase follows a check and precedes any request.
      if (o_fault && state_q == S_DECIDE) begin
        p_early_fault_checked : assert (f_lower_checked_q && issued_q == 2'b00);
      end
      // One register write, only for a load with a destination, with done.
      if (o_wb_valid) p_wb_with_done : assert (o_done && !store_q && rd_valid_q && !f_seq_wb_q);
      // Busy covers the whole access.
      if (o_done || o_fault || o_lc_req_valid || o_walk_req_valid) p_busy : assert (o_busy);
      // Nothing completes, faults or requests on an edge that samples a stop.
      if (i_fatal_stop) begin
        p_stop_quiet :
        assert (!o_done && !o_fault && !o_wb_valid && !o_lc_req_valid && !o_walk_req_valid);
      end
      // No request is offered on the edge that receives a failed write.
      if (store_write_failed) p_fail_quiet : assert (!o_lc_req_valid && !o_done);
      // A failed store write, or a hart stop, is terminal from the next cycle.
      if ($past(state_q == S_FATAL) || $past(i_fatal_stop) || $past(store_write_failed)) begin
        p_fatal_terminal :
        assert (state_q == S_FATAL && !o_done && !o_fault && !o_wb_valid &&
                                   !o_lc_req_valid && !o_walk_req_valid);
      end
      if (o_fatal_error) p_fatal_error_terminal : assert (state_q == S_FATAL);
      // A store's sector masks cover exactly the stored bytes.
      if (o_lc_req_valid && store_q) begin
        p_store_bytes :
        assert ($countones(
            place_lo_mask
        ) + $countones(
            place_hi_mask
        ) == ma_pkg::size_bytes(
            size_q
        ));
      end
    end
  end

  // Reachability.
  always_comb begin
    if (!i_rst) begin
      cover_split_store_done : cover (o_done && store_q && split);
      cover_split_load_wb : cover (o_wb_valid && split);
      cover_upper_fault :
      cover (o_fault && state_q == S_DECIDE && split &&
                                 (lower_q == ma_pkg::MaPartOk) && (upper_q != ma_pkg::MaPartOk));
      cover_store_error_before_upper : cover (store_write_failed && state_q == S_ISSUE_HI);
      cover_walked_upper : cover (state_q == S_WALK_RESP && part_q);
    end
  end
`endif

endmodule
