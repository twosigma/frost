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

// Composed verification of the StoreConditional GrantM writeback-exclusion
// obligation assumed in standalone coherence_l1d (lines 5718-5721):
// composes production coherence_l1d, production coherence_home (with its real
// coherence_home_completions, coherence_home_engine, coherence_home_array,
// PutM/PutAck FSM, FillRecall/FillInstall FSM, writeback slot, forward path,
// and arbiters), a legal DMA requester, a free-latency memory responder, and
// all eight real coherence_link channels at LINK_STAGES = 0, 1, 2, 3.
module coherence_sc_wa_formal #(
    parameter int unsigned LINK_STAGES = 0,
    parameter int unsigned L1D_MISSES = 1,
    parameter int unsigned ADDR_BITS = 8,
    parameter bit ENABLE_DMA = 1'b1,
    parameter bit COVER_MODE = 1'b0
) (
    input logic i_clk,
    input logic [ADDR_BITS-1:0] i_cpu_addr,
    input logic i_store_req,
    input logic [7:0] i_store_mask,
    input logic i_atomic_write_req,
    input logic [7:0] i_atomic_write_mask,
    input logic i_atomic_protected_extra,
    input logic i_sc_req,
    input logic [ADDR_BITS-1:0] i_sc_addr,
    input logic [2:0] i_sc_size,
    input logic i_sc_commit_req,
    input logic i_sc_result_ready,
    input logic i_res_valid,
    input logic [ADDR_BITS-1:0] i_res_addr,
    input logic [2:0] i_res_size,
    input logic i_cut_admit_ready,
    input logic i_cut_inval_done,
    input logic i_dma_req,
    input logic i_dma_write,
    input logic [ADDR_BITS-1:5] i_dma_sector,
    input logic i_dma_g_ready,
    input logic i_dma_c_valid,
    input logic i_dma_u_ready,
    input logic i_mem_req_ready,
    input logic i_mem_resp_valid,
    input logic i_mem_resp_write
);
  localparam int unsigned AddrWidth = 32;
  localparam int unsigned LineBytes = 64;
  localparam logic [5:0] FillTid = 6'(coherence_pkg::fill_base(1));
  localparam logic [5:0] PutTid = 6'(coherence_pkg::put_base(1, 1));
  `FROST_COHERENCE_TYPES(AddrWidth)

  logic past_q = 1'b0;
  wire  rst = !past_q;
  always_ff @(posedge i_clk) past_q <= 1'b1;

  logic store_credit_q;
  logic hart_fatal, home_fatal;
  wire fatal = hart_fatal || home_fatal;
  wire hart_active = !rst && !fatal;

  logic o_write_done, o_write_inflight, o_store_ready, o_pending_store;
  logic o_sc_write_pending, o_atomic_live, o_sc_ready, o_sc_result_valid, o_sc_success, o_sc_error;
  logic o_sc_write_done;

  // Read-only observation of internal L1D control state to form legal CPU
  // inputs with zero assumptions and assert the exact GrantM / wb_live check.
  wire atomic_q = hart.atomic_q;
  wire atomic_local_q = hart.atomic_local_q;
  wire atomic_sc_q = hart.atomic_sc_q;
  wire atomic_granted_q = hart.atomic_granted_q;
  wire atomic_written_q = hart.atomic_written_q;
  wire atomic_write_q = hart.atomic_write_q;
  wire sc_committed_q = hart.sc_committed_q;
  wire amo_waiting = hart.amo_waiting;
  wire [AddrWidth-1:0] atomic_addr_q = hart.atomic_addr_q;
  wire [2:0] atomic_size_q = hart.atomic_size_q;
  wire [1:0] atomic_tag_q = hart.atomic_tag_q;

  // Cover-only primary-input driver (zero assumptions). Every prove task sets
  // COVER_MODE = 0 so all primary inputs remain completely unrestricted.
  typedef enum logic [2:0] {
    DmaIdle,
    DmaDemand,
    DmaWaitG,
    DmaHoldC,
    DmaSendC,
    DmaWaitU
  } dma_phase_t;
  dma_phase_t dma_phase_q;
  logic [ADDR_BITS-1:0] c_cpu_addr, c_sc_addr, c_res_addr;
  logic c_store_req, c_atomic_write_req, c_sc_req, c_sc_commit_req, c_res_valid;
  logic [7:0] c_store_mask, c_atomic_write_mask;
  logic c_atomic_protected_extra;
  logic [2:0] c_sc_size, c_res_size;
  logic c_sc_result_ready, c_cut_admit_ready, c_cut_inval_done;
  logic c_dma_req, c_dma_write, c_dma_g_ready, c_dma_c_valid, c_dma_u_ready;
  logic [ADDR_BITS-1:5] c_dma_sector;
  logic c_mem_req_ready, c_mem_resp_valid, c_mem_resp_write;
  logic sc_fire, ordinary_store_ok, dma_g_hit;

  if (!COVER_MODE) begin : gen_free_inputs
    assign c_cpu_addr = i_cpu_addr;
    assign c_sc_addr = i_sc_addr;
    assign c_res_addr = i_res_addr;
    assign c_store_req = i_store_req;
    assign c_store_mask = i_store_mask;
    assign c_atomic_write_req = i_atomic_write_req;
    assign c_atomic_write_mask = i_atomic_write_mask;
    assign c_atomic_protected_extra = i_atomic_protected_extra;
    assign c_sc_req = i_sc_req;
    assign c_sc_size = i_sc_size;
    assign c_sc_commit_req = i_sc_commit_req;
    assign c_sc_result_ready = i_sc_result_ready;
    assign c_res_valid = i_res_valid;
    assign c_res_size = i_res_size;
    assign c_cut_admit_ready = i_cut_admit_ready;
    assign c_cut_inval_done = i_cut_inval_done;
    assign c_dma_req = i_dma_req;
    assign c_dma_write = i_dma_write;
    assign c_dma_sector = i_dma_sector;
    assign c_dma_g_ready = i_dma_g_ready;
    assign c_dma_c_valid = i_dma_c_valid;
    assign c_dma_u_ready = i_dma_u_ready;
    assign c_mem_req_ready = i_mem_req_ready;
    assign c_mem_resp_valid = i_mem_resp_valid;
    assign c_mem_resp_write = i_mem_resp_write;
  end else begin : gen_cover_driver
    // Five deterministic primary-input scenarios selected on reset, using only
    // public handshakes and LINK_STAGES-scaled DMA-C release timings so all 12
    // covers are reached cleanly under depth 200 for LINK_STAGES = 0..3.
    logic [2:0] cover_case_q;
    logic [3:0] cover_step_q;
    logic [5:0] cover_wait_q;
    wire cover_idle = store_credit_q && o_sc_ready && !o_pending_store && !o_atomic_live;
    wire [5:0] dma_overlap = 6'd10 + 6'(LINK_STAGES);
    wire [5:0] case1_rel = 6'(LINK_STAGES);
    wire [5:0] case2_rel = 6'd5 + 6'(LINK_STAGES);
    wire [5:0] case3_rel = 6'd18 + 6'(5 * LINK_STAGES);

    always_ff @(posedge i_clk) begin
      if (rst) begin
        cover_case_q <= i_cpu_addr[2:0];
        cover_step_q <= 4'd0;
        cover_wait_q <= 6'd0;
      end else begin
        case (cover_case_q)
          3'd0: begin
            case (cover_step_q)
              4'd0: if (sc_fire) cover_step_q <= 4'd1;
              4'd1: if (cover_idle) cover_step_q <= 4'd2;
              4'd2: if (sc_fire) cover_step_q <= 4'd3;
              default: ;
            endcase
          end
          3'd1, 3'd2, 3'd3: begin
            case (cover_step_q)
              4'd0:
              if (ordinary_store_ok) begin
                cover_step_q <= 4'd1;
                cover_wait_q <= 6'd0;
              end
              4'd1: begin
                if (dma_phase_q == DmaHoldC && cover_idle) cover_step_q <= 4'd2;
                else if (cover_wait_q != 6'd63) cover_wait_q <= cover_wait_q + 6'd1;
              end
              4'd2: if (ordinary_store_ok) cover_step_q <= 4'd3;
              4'd3: if (ordinary_store_ok) cover_step_q <= 4'd4;
              4'd4:
              if (sc_fire) begin
                cover_step_q <= 4'd5;
                cover_wait_q <= 6'd0;
              end
              4'd5: if (cover_wait_q != 6'd63) cover_wait_q <= cover_wait_q + 6'd1;
              default: ;
            endcase
          end
          default: begin
            case (cover_step_q)
              4'd0: if (ordinary_store_ok) cover_step_q <= 4'd1;
              4'd1: if (dma_phase_q == DmaDemand) cover_step_q <= 4'd2;
              4'd2: if (sc_fire) cover_step_q <= 4'd3;
              default: ;
            endcase
          end
        endcase
      end
    end

    always_comb begin
      c_cpu_addr = '0;
      c_sc_addr = '0;
      c_res_addr = '0;
      c_store_req = 1'b0;
      c_store_mask = 8'hff;
      c_atomic_write_req = 1'b1;
      c_atomic_write_mask = 8'hff;
      c_atomic_protected_extra = 1'b1;
      c_sc_req = 1'b0;
      c_sc_size = 3'd3;
      c_sc_commit_req = 1'b1;
      c_sc_result_ready = 1'b1;
      c_res_valid = 1'b0;
      c_res_size = 3'd3;
      c_cut_admit_ready = 1'b1;
      c_cut_inval_done = 1'b1;
      c_dma_req = 1'b0;
      c_dma_write = 1'b0;
      c_dma_sector = '0;
      c_dma_g_ready = 1'b1;
      c_dma_c_valid = 1'b1;
      c_dma_u_ready = 1'b1;
      c_mem_req_ready = 1'b1;
      c_mem_resp_valid = 1'b1;
      c_mem_resp_write = 1'b0;

      case (cover_case_q)
        3'd0: begin
          case (cover_step_q)
            4'd0: begin
              c_sc_req = cover_idle;
              c_sc_addr = 8'h00;
              c_res_valid = 1'b1;
              c_res_addr = 8'h00;
            end
            4'd1: begin
              c_res_valid = 1'b1;
              c_res_addr  = 8'h00;
            end
            4'd2: begin
              c_sc_req = cover_idle;
              c_sc_addr = 8'h20;
              c_res_valid = 1'b0;
            end
            default: ;
          endcase
        end
        3'd1, 3'd2, 3'd3: begin
          case (cover_step_q)
            4'd0: begin
              c_store_req = cover_idle;
              c_cpu_addr  = 8'h40;
            end
            4'd1: begin
              c_dma_req = dma_phase_q == DmaIdle && cover_wait_q >= dma_overlap;
              c_dma_write = 1'b0;
              c_dma_sector = 3'd2;
              c_dma_c_valid = 1'b0;
            end
            4'd2: begin
              c_store_req = cover_idle;
              c_cpu_addr = 8'h40;
              c_dma_c_valid = 1'b0;
            end
            4'd3: begin
              c_store_req = store_credit_q && !o_pending_store;
              c_cpu_addr = 8'h00;
              c_dma_c_valid = 1'b0;
            end
            4'd4: begin
              c_dma_c_valid = 1'b0;
              c_sc_req = o_sc_ready;
              c_sc_addr = cover_case_q == 3'd3 ? 8'h20 : 8'h40;
              c_res_valid = 1'b1;
              c_res_addr = cover_case_q == 3'd3 ? 8'h20 : 8'h40;
            end
            default: begin
              c_res_valid = 1'b1;
              c_res_addr = cover_case_q == 3'd3 ? 8'h20 : 8'h40;
              if (cover_case_q == 3'd1) c_dma_c_valid = cover_wait_q >= case1_rel;
              else if (cover_case_q == 3'd2) c_dma_c_valid = cover_wait_q >= case2_rel;
              else c_dma_c_valid = cover_wait_q >= case3_rel;
            end
          endcase
        end
        default: begin
          case (cover_step_q)
            4'd0: begin
              c_store_req = cover_idle;
              c_cpu_addr  = 8'h00;
            end
            4'd1: begin
              c_dma_req = cover_idle && dma_phase_q == DmaIdle;
              c_dma_write = 1'b0;
              c_dma_sector = 3'd4;
            end
            4'd2: begin
              c_sc_req = dma_phase_q == DmaIdle && cover_idle;
              c_sc_addr = 8'h80;
              c_res_valid = 1'b1;
              c_res_addr = 8'h80;
            end
            default: begin
              c_res_valid = 1'b1;
              c_res_addr  = 8'h80;
            end
          endcase
        end
      endcase
    end
  end

  wire [AddrWidth-1:0] full_cpu_addr = {{(AddrWidth - ADDR_BITS) {1'b0}}, c_cpu_addr};
  wire [AddrWidth-1:0] full_sc_addr = {{(AddrWidth - ADDR_BITS) {1'b0}}, c_sc_addr};
  wire [AddrWidth-1:0] full_res_addr = {{(AddrWidth - ADDR_BITS) {1'b0}}, c_res_addr};

  wire sc_valid = hart_active && c_sc_req && !atomic_q && !amo_waiting;
  assign sc_fire = sc_valid && o_sc_ready;

  wire atomic_write_ok = hart_active && c_atomic_write_req && (|c_atomic_write_mask) &&
      atomic_q && atomic_granted_q && !atomic_written_q && !atomic_write_q &&
      (!atomic_sc_q || sc_committed_q);

  assign ordinary_store_ok = hart_active && !atomic_write_ok && !sc_fire &&
      c_store_req && store_credit_q && !atomic_q && !amo_waiting && (|c_store_mask);

  wire [7:0] write_mask = atomic_write_ok ? c_atomic_write_mask :
      ordinary_store_ok ? c_store_mask : 8'h0;
  wire write_atomic = atomic_write_ok;
  wire write_sc = atomic_write_ok && atomic_sc_q;
  wire [1:0] write_tag = atomic_write_ok ? atomic_tag_q : 2'b0;
  wire [AddrWidth-1:0] cpu_address = atomic_write_ok ? atomic_addr_q : full_cpu_addr;

  wire sc_commit = hart_active && c_sc_commit_req && atomic_q && atomic_sc_q && atomic_granted_q;

  wire sc_hold_res = atomic_q && atomic_sc_q && atomic_granted_q && !atomic_written_q;
  wire res_valid = sc_hold_res ? 1'b1 : c_res_valid;
  wire [AddrWidth-1:0] res_addr = sc_hold_res ? atomic_addr_q : full_res_addr;
  wire [2:0] res_size = sc_hold_res ? atomic_size_q : c_res_size;

  wire atomic_protected = atomic_q ||
      (hart.request_live && hart.acquisition_q.opcode == coherence_pkg::Atomic) ||
      c_atomic_protected_extra;

  always_ff @(posedge i_clk) begin
    if (rst) store_credit_q <= 1'b0;
    else store_credit_q <= o_store_ready;
  end

  // Channels between L1D, real coherence_link stages, and production coherence_home.
  logic [L1D_MISSES-1:0] l1d_d_valid, l1d_d_ready, l1d_c_valid, l1d_c_ready;
  logic [L1D_MISSES-1:0][AddrWidth+311:0] l1d_d;
  logic [L1D_MISSES-1:0][ AddrWidth+17:0] l1d_c;
  logic [L1D_MISSES-1:0] hart_d_valid, hart_d_ready, hart_c_valid, hart_c_ready;
  logic [L1D_MISSES-1:0][AddrWidth+311:0] hart_d;
  logic [L1D_MISSES-1:0][ AddrWidth+17:0] hart_c;

  logic l1d_p_valid, l1d_p_ready, l1d_r_valid, l1d_r_ready;
  logic l1d_w_valid, l1d_w_ready, l1d_wa_valid, l1d_wa_ready;
  logic l1d_g_valid, l1d_g_ready, l1d_u_valid, l1d_u_ready;
  logic [AddrWidth+29:0] l1d_p, home_p;
  logic [AddrWidth+274:0] l1d_r, home_r, l1d_g;
  logic [AddrWidth+259:0] l1d_w, home_w;
  logic [AddrWidth+10:0] l1d_wa, home_wa;
  logic [AddrWidth+14:0] l1d_u;

  logic home_d_valid, home_d_ready, home_c_valid, home_c_ready;
  logic home_p_valid, home_p_ready, home_r_valid, home_r_ready;
  logic home_w_valid, home_w_ready, home_wa_valid, home_wa_ready;
  logic home_g_valid, home_g_ready, home_u_valid, home_u_ready;
  logic [AddrWidth+311:0] home_d;
  logic [AddrWidth+17:0] home_c;
  coh_g_t home_g;
  coh_u_t home_u;
  logic link_g_ready, link_u_ready;

  // Minimal single-slot legal DMA agent (source 2) for ProbeSnapshot/ProbeInvalidate/FillRecall.
  localparam logic [8:0] DmaKey = {2'd2, 2'd3, 4'd0, 1'b0};
  coh_d_t dma_d_q;
  coh_c_t dma_c_q;
  logic dma_d_ready, dma_c_ready;
  wire dma_d_valid = ENABLE_DMA && hart_active && dma_phase_q == DmaDemand;
  wire dma_c_valid = ENABLE_DMA && hart_active && dma_phase_q == DmaSendC;
  assign dma_g_hit = ENABLE_DMA && home_g_valid && home_g.q.src == 2'd2;
  wire dma_u_hit = ENABLE_DMA && home_u_valid && home_u.q.src == 2'd2;
  wire dma_g_ready = ENABLE_DMA && dma_phase_q == DmaWaitG && c_dma_g_ready;
  wire dma_u_ready = ENABLE_DMA && dma_phase_q == DmaWaitU && c_dma_u_ready;

  always_ff @(posedge i_clk) begin
    if (rst) begin
      dma_phase_q <= DmaIdle;
      dma_d_q <= '0;
      dma_c_q <= '0;
    end else if (ENABLE_DMA && !fatal) begin
      case (dma_phase_q)
        DmaIdle:
        if (c_dma_req) begin
          dma_d_q <= '0;
          dma_d_q.opcode <= c_dma_write ? coherence_pkg::DMAWrite : coherence_pkg::DMARead;
          dma_d_q.q <= DmaKey;
          dma_d_q.addr <= {{(AddrWidth - ADDR_BITS) {1'b0}}, c_dma_sector, 5'b0};
          dma_d_q.size <= 3'd5;
          dma_d_q.mask <= c_dma_write ? 32'hffff_ffff : 32'b0;
          dma_phase_q <= DmaDemand;
        end
        DmaDemand: if (dma_d_valid && dma_d_ready) dma_phase_q <= DmaWaitG;
        DmaWaitG:
        if (dma_g_hit && dma_g_ready) begin
          dma_c_q <= '0;
          dma_c_q.q <= DmaKey;
          dma_c_q.tid <= home_g.tid;
          dma_c_q.addr <= home_g.addr;
          dma_c_q.status <= coherence_pkg::Consumed;
          dma_phase_q <= c_dma_c_valid ? DmaSendC : DmaHoldC;
        end
        DmaHoldC:  if (c_dma_c_valid) dma_phase_q <= DmaSendC;
        DmaSendC:  if (dma_c_valid && dma_c_ready) dma_phase_q <= DmaWaitU;
        DmaWaitU:  if (dma_u_hit && dma_u_ready) dma_phase_q <= DmaIdle;
        default:   dma_phase_q <= DmaIdle;
      endcase
    end
  end

  coherence_l1d #(
      .ADDR_WIDTH(AddrWidth),
      .CACHE_BYTES(64),
      .WAYS(1),
      .TAG_BITS(2),
      .MISSES(L1D_MISSES),
      .HOME_CACHE_BYTES(128),
      .HOME_WAYS(1),
      .HOME_LINE_BYTES(LineBytes),
      .ZERO_LINE(1'b0),
      .FULL_LINE(1'b0),
      .STREAM_PREFETCH(1'b0),
      .WITHDRAW_ABSORBED_W(LINK_STAGES != 0)
  ) hart (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_fatal_stop(fatal),
      .i_read_valid(1'b0),
      .i_read_id(3'b0),
      .i_read_kind(2'b0),
      .i_read_size(3'd3),
      .i_read_tag(2'b0),
      .i_address(cpu_address),
      .o_read_valid(),
      .i_read_ready(1'b1),
      .o_read_id(),
      .o_read_data(),
      .o_read_error(),
      .i_write_mask(write_mask),
      .i_write_data(64'b0),
      .i_write_atomic(write_atomic),
      .i_write_sc(write_sc),
      .i_write_zero(1'b0),
      .i_write_more(1'b0),
      .i_next_same(1'b0),
      .i_write_tag(write_tag),
      .o_write_done(o_write_done),
      .o_write_inflight(o_write_inflight),
      .o_store_ready(o_store_ready),
      .o_twin_push(),
      .o_twin_push_addr(),
      .o_pending_store(o_pending_store),
      .o_sc_write_pending(o_sc_write_pending),
      .o_atomic_live(o_atomic_live),
      .o_block_valid(),
      .o_block_addr(),
      .i_atomic_protected(atomic_protected),
      .i_sc_valid(sc_valid),
      .o_sc_ready(o_sc_ready),
      .i_sc_address(full_sc_addr),
      .i_sc_size(c_sc_size),
      .i_sc_tag(2'b0),
      .i_sc_commit(sc_commit),
      .o_sc_result_valid(o_sc_result_valid),
      .i_sc_result_ready(c_sc_result_ready),
      .o_sc_success(o_sc_success),
      .o_sc_error(o_sc_error),
      .o_sc_write_done(o_sc_write_done),
      .o_sc_write_tag(),
      .i_reservation_valid(res_valid),
      .i_reservation_addr(res_addr),
      .i_reservation_size(res_size),
      .i_maint_valid(1'b0),
      .i_maint_line(1'b0),
      .i_maint_address('0),
      .o_maint_done(),
      .o_cut_hold(),
      .o_cut_admit_valid(),
      .i_cut_admit_ready(c_cut_admit_ready),
      .i_cut_admit_clean(1'b0),
      .o_cut_address(),
      .o_cut_inval_valid(),
      .i_cut_inval_done(c_cut_inval_done),
      .o_cut_release(),
      .o_d_valid(l1d_d_valid),
      .i_d_ready(l1d_d_ready),
      .o_d(l1d_d),
      .i_p_valid(l1d_p_valid),
      .o_p_ready(l1d_p_ready),
      .i_p(l1d_p),
      .o_r_valid(l1d_r_valid),
      .i_r_ready(l1d_r_ready),
      .o_r(l1d_r),
      .o_w_valid(l1d_w_valid),
      .i_w_ready(l1d_w_ready),
      .o_w(l1d_w),
      .i_wa_valid(l1d_wa_valid),
      .o_wa_ready(l1d_wa_ready),
      .i_wa(l1d_wa),
      .i_g_valid(l1d_g_valid),
      .o_g_ready(l1d_g_ready),
      .i_g(l1d_g),
      .o_c_valid(l1d_c_valid),
      .i_c_ready(l1d_c_ready),
      .o_c(l1d_c),
      .i_u_valid(l1d_u_valid),
      .o_u_ready(l1d_u_ready),
      .i_u(l1d_u),
      .o_perf_events(),
      .o_fatal(hart_fatal),
      .o_fatal_addr()
  );

  for (genvar ep = 0; ep < L1D_MISSES; ep++) begin : gen_ep_links
    coherence_link #(
        .WIDTH (AddrWidth + 312),
        .STAGES(LINK_STAGES),
        .KIND  (1)
    ) link_d (
        .i_clk(i_clk),
        .i_rst(rst),
        .i_stopped(fatal),
        .i_valid(l1d_d_valid[ep]),
        .o_ready(l1d_d_ready[ep]),
        .i_payload(l1d_d[ep]),
        .o_valid(hart_d_valid[ep]),
        .i_ready(hart_d_ready[ep]),
        .o_payload(hart_d[ep])
    );
    coherence_link #(
        .WIDTH (AddrWidth + 18),
        .STAGES(LINK_STAGES),
        .KIND  (1)
    ) link_c (
        .i_clk(i_clk),
        .i_rst(rst),
        .i_stopped(fatal),
        .i_valid(l1d_c_valid[ep]),
        .o_ready(l1d_c_ready[ep]),
        .i_payload(l1d_c[ep]),
        .o_valid(hart_c_valid[ep]),
        .i_ready(hart_c_ready[ep]),
        .o_payload(hart_c[ep])
    );
  end
  coherence_link #(
      .WIDTH(AddrWidth + 30),
      .STAGES(LINK_STAGES),
      .KIND(1),
      .CREDITS(1)
  ) link_p (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_stopped(fatal),
      .i_valid(home_p_valid),
      .o_ready(home_p_ready),
      .i_payload(home_p),
      .o_valid(l1d_p_valid),
      .i_ready(l1d_p_ready),
      .o_payload(l1d_p)
  );
  coherence_link #(
      .WIDTH (AddrWidth + 275),
      .STAGES(LINK_STAGES),
      .KIND  (0)
  ) link_r (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_stopped(fatal),
      .i_valid(l1d_r_valid),
      .o_ready(l1d_r_ready),
      .i_payload(l1d_r),
      .o_valid(home_r_valid),
      .i_ready(home_r_ready),
      .o_payload(home_r)
  );
  coherence_link #(
      .WIDTH (AddrWidth + 260),
      .STAGES(LINK_STAGES),
      .KIND  (2)
  ) link_w (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_stopped(fatal),
      .i_valid(l1d_w_valid),
      .o_ready(l1d_w_ready),
      .i_payload(l1d_w),
      .o_valid(home_w_valid),
      .i_ready(home_w_ready),
      .o_payload(home_w)
  );
  coherence_link #(
      .WIDTH (AddrWidth + 11),
      .STAGES(LINK_STAGES),
      .KIND  (0)
  ) link_wa (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_stopped(fatal),
      .i_valid(home_wa_valid),
      .o_ready(home_wa_ready),
      .i_payload(home_wa),
      .o_valid(l1d_wa_valid),
      .i_ready(l1d_wa_ready),
      .o_payload(l1d_wa)
  );
  coherence_link #(
      .WIDTH (AddrWidth + 275),
      .STAGES(LINK_STAGES),
      .KIND  (0)
  ) link_g (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_stopped(fatal),
      .i_valid(home_g_valid && home_g.q.src == 2'd0),
      .o_ready(link_g_ready),
      .i_payload(home_g),
      .o_valid(l1d_g_valid),
      .i_ready(l1d_g_ready),
      .o_payload(l1d_g)
  );
  coherence_link #(
      .WIDTH (AddrWidth + 15),
      .STAGES(LINK_STAGES),
      .KIND  (0)
  ) link_u (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_stopped(fatal),
      .i_valid(home_u_valid && home_u.q.src == 2'd0),
      .o_ready(link_u_ready),
      .i_payload(home_u),
      .o_valid(l1d_u_valid),
      .i_ready(l1d_u_ready),
      .o_payload(l1d_u)
  );

  assign home_g_ready = home_g.q.src == 2'd2 ? dma_g_ready : link_g_ready;
  assign home_u_ready = home_u.q.src == 2'd2 ? dma_u_ready : link_u_ready;

  coherence_d_arbiter #(
      .WIDTH(AddrWidth + 312),
      .PORTS(L1D_MISSES + 1)
  ) d_arbiter (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_valid({dma_d_valid, hart_d_valid}),
      .o_ready({dma_d_ready, hart_d_ready}),
      .i_payload({dma_d_q, hart_d}),
      .o_valid(home_d_valid),
      .o_selected(),
      .i_ready(home_d_ready),
      .o_payload(home_d)
  );
  coherence_d_arbiter #(
      .WIDTH(AddrWidth + 18),
      .PORTS(L1D_MISSES + 1),
      .HOLD_VALID(1)
  ) c_arbiter (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_valid({dma_c_valid, hart_c_valid}),
      .o_ready({dma_c_ready, hart_c_ready}),
      .i_payload({dma_c_q, hart_c}),
      .o_valid(home_c_valid),
      .o_selected(),
      .i_ready(home_c_ready),
      .o_payload(home_c)
  );

  // Free-latency legal memory responder (zero assumptions) for production coherence_home.
  logic mem_req_valid, mem_req_write;
  logic [AddrWidth-1:0] mem_req_addr;
  logic [4:0] mem_req_id;
  logic mem_read_pend_q, mem_write_pend_q;
  wire mem_resp_read = !rst && c_mem_resp_valid && mem_read_pend_q &&
      (!mem_write_pend_q || !c_mem_resp_write);
  wire mem_resp_write = !rst && c_mem_resp_valid && mem_write_pend_q &&
      (!mem_read_pend_q || c_mem_resp_write);
  wire mem_resp_valid = mem_resp_read || mem_resp_write;
  wire [4:0] mem_resp_id = mem_resp_write ? 5'd16 : 5'd0;

  always_ff @(posedge i_clk) begin
    if (rst) begin
      mem_read_pend_q  <= 1'b0;
      mem_write_pend_q <= 1'b0;
    end else begin
      if (mem_resp_read) mem_read_pend_q <= 1'b0;
      if (mem_resp_write) mem_write_pend_q <= 1'b0;
      if (mem_req_valid && c_mem_req_ready) begin
        if (mem_req_write) mem_write_pend_q <= 1'b1;
        else mem_read_pend_q <= 1'b1;
      end
    end
  end

  coherence_home #(
      .ADDR_WIDTH(AddrWidth),
      .LINE_BYTES(LineBytes),
      .CACHE_BYTES(128),
      .WAYS(1),
      .NUM_WB(1),
      .COMPLETIONS(2),
      .RESULTS(1),
      .FILLS(1),
      .PREFETCH_RESERVE(0),
      .PREFETCH_SLOTS(0),
      .ULTRA(1'b0),
      .PARALLEL_READ(1'b0)
  ) home (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_fatal_stop(fatal),
      .i_d_valid(home_d_valid),
      .o_d_ready(home_d_ready),
      .i_d(home_d),
      .o_p_valid(home_p_valid),
      .i_p_ready(home_p_ready),
      .o_p(home_p),
      .i_r_valid(home_r_valid),
      .o_r_ready(home_r_ready),
      .i_r(home_r),
      .i_w_valid(home_w_valid),
      .o_w_ready(home_w_ready),
      .i_w(home_w),
      .o_wa_valid(home_wa_valid),
      .i_wa_ready(home_wa_ready),
      .o_wa(home_wa),
      .o_g_valid(home_g_valid),
      .i_g_ready(home_g_ready),
      .o_g(home_g),
      .i_c_valid(home_c_valid),
      .o_c_ready(home_c_ready),
      .i_c(home_c),
      .o_u_valid(home_u_valid),
      .i_u_ready(home_u_ready),
      .o_u(home_u),
      .o_prefetch_room(),
      .o_accepted(),
      .o_accepted_opcode(),
      .o_accepted_q(),
      .o_accepted_addr(),
      .o_mem_req_valid(mem_req_valid),
      .i_mem_req_ready(c_mem_req_ready),
      .o_mem_req_write(mem_req_write),
      .o_mem_req_addr(mem_req_addr),
      .o_mem_req_data(),
      .o_mem_req_mask(),
      .o_mem_req_id(mem_req_id),
      .i_mem_resp_valid(mem_resp_valid),
      .i_mem_resp_id(mem_resp_id),
      .i_mem_resp_data('0),
      .i_mem_resp_error(1'b0),
      .o_perf_events(),
      .o_write_perf_events(),
      .o_fatal(home_fatal),
      .o_fatal_addr()
  );

  // Read-only observation of production coherence_home internals for invariants and covers.
  coh_g_t  l1d_grant;
  coh_wa_t l1d_wa_pkt;
  coh_r_t  home_r_obs, l1d_r_pkt;
  coh_w_t  home_put_pkt[2];
  coh_p_t  home_fill_probe;
  coh_wa_t home_fill_ack;
  coh_g_t  result_g, comp_buf0_g, comp_buf1_g;
  assign l1d_grant = l1d_g;
  assign l1d_wa_pkt = l1d_wa;
  assign home_r_obs = home_r;
  assign l1d_r_pkt = l1d_r;
  assign home_put_pkt[0] = home.put_q[0];
  assign home_put_pkt[1] = home.put_q[1];
  assign home_fill_probe = home.fill_probe[0];
  assign home_fill_ack = home.fill_ack_q[0];
  assign result_g = home.result;
  assign comp_buf0_g = home.completions.buffer_q[0];
  assign comp_buf1_g = home.completions.buffer_q[1];

  wire [53:0] home_tag_ram = home.array.gen_tag_block.gen_way[0].tags.o_f_ram;
  wire [26:0] home_tag_ent0 = home_tag_ram[0+:27];
  wire [26:0] home_tag_ent1 = home_tag_ram[27+:27];

  localparam logic [2:0] ArrInit = 3'd0, ArrInitDrain = 3'd1, ArrIdle = 3'd2,
      ArrTags = 3'd3, ArrSelect = 3'd4, ArrReply = 3'd5;
  localparam logic [2:0] PutFree = 3'd0, PutLookup = 3'd1, PutDecision = 3'd2,
      PutUpdate = 3'd3, PutUpdateWait = 3'd4, PutAck = 3'd5;
  localparam logic [3:0] FillFree = 4'd0, FillRecall = 4'd1, FillDetach = 4'd2,
      FillInvalidate = 4'd3, FillInvalidateWait = 4'd4, FillMemory = 4'd5,
      FillInstall = 4'd6, FillInstallWait = 4'd7, FillReady = 4'd8;
  localparam logic [2:0] RecallOffer = 3'd0, RecallWait = 3'd1, RecallAck = 3'd2,
      RecallDone = 3'd3;
  localparam logic [3:0] EngFree = 4'd0, EngLookup = 4'd1, EngService = 4'd2,
      EngUpdate = 4'd3, EngUpdateWait = 4'd4, EngResult = 4'd5;
  localparam logic [2:0] EngProbeDone = 3'd0, EngProbeOffer = 3'd1,
      EngProbeWait = 3'd2, EngProbeAck = 3'd3;
  localparam logic [1:0] PutPresent = 2'd1, PutAccepted = 2'd2;
  localparam logic [3:0] L1dIdle = 4'd0, L1dLookup = 4'd1, L1dLookupWait = 4'd2,
      L1dAcquire = 4'd3, L1dFreeze = 4'd4, L1dUpdate = 4'd5, L1dUpdateWait = 4'd6,
      L1dProbeAbsorb = 4'd7, L1dProbeReply = 4'd8;
  localparam logic [3:0] L1dOpRead = 4'd0, L1dOpStore = 4'd1, L1dOpGrant = 4'd2,
      L1dOpProbe = 4'd3, L1dOpMaint = 4'd4, L1dOpAtomicWr = 4'd5, L1dOpSC = 4'd6;

  wire sc_ep0_grant = !rst && l1d_g_valid && hart.ep_g_ready[0] &&
      !l1d_grant.error &&
      hart.acquisition_q.opcode == coherence_pkg::StoreConditional;
  wire sc_ep0_grantm = sc_ep0_grant && l1d_grant.opcode == coherence_pkg::GrantM;
  wire sc_ep0_grantfail = sc_ep0_grant && l1d_grant.opcode == coherence_pkg::GrantFail;

  wire wb0_same_grant = hart.wb_live[0] &&
      hart.wb_addr[0][AddrWidth-1:5] == l1d_grant.addr[AddrWidth-1:5];
  wire wb1_same_grant = hart.wb_live[1] &&
      hart.wb_addr[1][AddrWidth-1:5] == l1d_grant.addr[AddrWidth-1:5];
  wire wb_other_grant = (hart.wb_live[0] &&
      hart.wb_addr[0][AddrWidth-1:5] != l1d_grant.addr[AddrWidth-1:5]) ||
      (hart.wb_live[1] &&
      hart.wb_addr[1][AddrWidth-1:5] != l1d_grant.addr[AddrWidth-1:5]);

  wire ep0_sc_live = hart.live[0] && hart.acquisition_q.opcode == coherence_pkg::StoreConditional;
  wire l1d_wa_fire = !rst && l1d_wa_valid && l1d_wa_ready && !l1d_wa_pkt.error;
  wire wa_matches_sc = l1d_wa_fire && ep0_sc_live &&
      l1d_wa_pkt.addr[AddrWidth-1:5] == hart.acquisition_q.addr[AddrWidth-1:5];

  wire snapshot_probe_dirty = !rst && home_r_valid && home_r_ready &&
      home.gen_engine[0].service.probe_q.opcode == coherence_pkg::ProbeSnapshot &&
      !home_r_obs.error && home_r_obs.opcode == coherence_pkg::ProbeData &&
      home_r_obs.data_valid && !home_r_obs.absorbed;

  wire put0_holds_token = home.array_response && home.array_token_onehot[2] &&
      home.put_busy_q[0] && !home.put_live[0];
  wire put1_holds_token = home.array_response && home.array_token_onehot[3] &&
      home.put_busy_q[1] && !home.put_live[1];
  wire any_put_holds_token = put0_holds_token || put1_holds_token;
  wire same_put_holds_token_sc = ep0_sc_live && (
      (put0_holds_token &&
       home_put_pkt[0].addr[AddrWidth-1:5] == hart.acquisition_q.addr[AddrWidth-1:5]) ||
      (put1_holds_token &&
       home_put_pkt[1].addr[AddrWidth-1:5] == hart.acquisition_q.addr[AddrWidth-1:5]));
  wire sc_blocked_by_put = !rst && home.array_response && home.decision_engine &&
      !home.engine_idle[0] &&
      home.gen_engine[0].service.request_q.opcode == coherence_pkg::StoreConditional &&
      home.decision_blocked && (|home.put_blocks);
  wire fill_recall_dirty_fire = !rst && home.fill_phase_q[0] == FillRecall &&
      home_r_valid && home.fill_r_ready[0] && !home_r_obs.error && home_r_obs.data_valid;

  logic sc_wa_ordinary_seen_q, sc_wa_absorbed_seen_q, snapshot_probe_seen_q;
  logic sc_same_put_token_seen_q, sc_put_blocked_seen_q, fill_recall_seen_q;

  wire ep0_send_d = hart.gen_request[0].request.send_d_phase;
  wire ep0_wait_g = hart.gen_request[0].request.wait_g_phase;
  wire ep0_grant_ph = hart.gen_request[0].request.grant_phase;
  wire ep0_done_ph = hart.gen_request[0].request.done_phase;
  wire ep0_send_c = hart.gen_request[0].request.send_c_phase;
  wire ep0_wait_u = hart.gen_request[0].request.wait_u_phase;
  wire ep0_sc_wait_g = ep0_wait_g && hart.acquisition_q.opcode == coherence_pkg::StoreConditional;

  wire eng_idle = home.engine_idle[0];
  wire [AddrWidth-1:0] eng_addr = home.engine_addr[0];
  wire [5:0] eng_tid = home.engine_tid[0];
  wire [3:0] eng_opcode = home.engine_opcode[0];
  wire [3:0] eng_phase = home.gen_engine[0].service.phase_q;
  wire [2:0] eng_probe_phase = home.gen_engine[0].service.probe_phase_q;

  wire engine_sc_live = !eng_idle &&
      eng_opcode == coherence_pkg::StoreConditional &&
      !home.gen_engine[0].service.failed_q && !home.gen_engine[0].service.error_q;
  wire engine_sc_service = engine_sc_live &&
      (eng_phase == EngService || eng_phase == EngUpdate ||
       eng_phase == EngUpdateWait || eng_phase == EngResult);
  wire engine_sc_probing_read = engine_sc_live && eng_phase == EngService &&
      home.gen_engine[0].service.probe_q.opcode == coherence_pkg::ProbeRead &&
      (eng_probe_phase == EngProbeOffer || eng_probe_phase == EngProbeWait);
  wire engine_sc_probe_wait_read = engine_sc_live && eng_phase == EngService &&
      home.gen_engine[0].service.probe_q.opcode == coherence_pkg::ProbeRead &&
      eng_probe_phase == EngProbeWait;
  wire engine_sc_probe_ack = engine_sc_live && eng_phase == EngService &&
      eng_probe_phase == EngProbeAck;
  wire engine_sc_past_probe = engine_sc_live &&
      (eng_phase == EngUpdate || eng_phase == EngUpdateWait ||
       eng_phase == EngResult ||
       (eng_phase == EngService && eng_probe_phase == EngProbeDone &&
        home.gen_engine[0].service.probe_q.opcode == coherence_pkg::ProbeRead));
  wire engine_sc_update_wait = engine_sc_live && eng_phase == EngUpdateWait;
  wire engine_sc_result = engine_sc_live && eng_phase == EngResult;
  wire result_is_sc_grantm = home.result_valid && !result_g.error &&
      result_g.opcode == coherence_pkg::GrantM && ep0_sc_live &&
      result_g.q == hart.acquisition_q.q &&
      result_g.addr == hart.acquisition_q.addr;
  wire comp_buf_is_sc_grantm = home.completions.buffer_ready_q[0] && !comp_buf0_g.error &&
      comp_buf0_g.opcode == coherence_pkg::GrantM && ep0_sc_live &&
      comp_buf0_g.q == hart.acquisition_q.q &&
      comp_buf0_g.addr == hart.acquisition_q.addr;
  wire home_g_is_sc_grantm = home_g_valid && !home_g.error &&
      home_g.opcode == coherence_pkg::GrantM && ep0_sc_live &&
      home_g.q == hart.acquisition_q.q &&
      home_g.addr == hart.acquisition_q.addr;

  // Inspect in-flight packets inside staged links for STAGES > 0.
  logic [1:0] wa_link_any, wa_link_ge1, wa_link_ge2;
  logic [1:0] wa_link_ord, wa_link_ord_ge1, wa_link_ord_ge2;
  logic [1:0] wa_link_abs, wa_link_abs_ge1, wa_link_abs_ge2;
  logic [1:0] wa_link_abs_fill, wa_link_abs_fill_ge1, wa_link_abs_fill_ge2;
  logic [1:0] r_link_abs;
  logic r_link_sc_reply_clean, r_link_sc_reply_abs;
  logic [1:0] r_link_sc_reply_abs_slot;
  logic r_link_fill_reply_clean, r_link_fill_reply_abs;
  logic [1:0] r_link_fill_reply_abs_slot;
  logic [1:0] g_link_sc_grantm;
  logic g_link_sc_any, g_link_getm_any;
  logic [AddrWidth-1:0] g_link_getm_addr;
  logic d_link_ep0_any, c_link_ep0_any, g_link_ep0_any, u_link_ep0_any;
  logic p_link_any, r_link_any, w_link_ret_any, w_link_ret_last;
  if (LINK_STAGES == 0) begin : gen_obs_s0
    assign wa_link_any = 2'b00;
    assign wa_link_ge1 = 2'b00;
    assign wa_link_ge2 = 2'b00;
    assign wa_link_ord = 2'b00;
    assign wa_link_ord_ge1 = 2'b00;
    assign wa_link_ord_ge2 = 2'b00;
    assign wa_link_abs = 2'b00;
    assign wa_link_abs_ge1 = 2'b00;
    assign wa_link_abs_ge2 = 2'b00;
    assign wa_link_abs_fill = 2'b00;
    assign wa_link_abs_fill_ge1 = 2'b00;
    assign wa_link_abs_fill_ge2 = 2'b00;
    assign r_link_abs = 2'b00;
    assign r_link_sc_reply_clean = 1'b0;
    assign r_link_sc_reply_abs = 1'b0;
    assign r_link_sc_reply_abs_slot = 2'b00;
    assign r_link_fill_reply_clean = 1'b0;
    assign r_link_fill_reply_abs = 1'b0;
    assign r_link_fill_reply_abs_slot = 2'b00;
    assign g_link_sc_grantm = 2'b00;
    assign g_link_sc_any = 1'b0;
    assign g_link_getm_any = 1'b0;
    assign g_link_getm_addr = '0;
    assign d_link_ep0_any = 1'b0;
    assign c_link_ep0_any = 1'b0;
    assign g_link_ep0_any = 1'b0;
    assign u_link_ep0_any = 1'b0;
    assign p_link_any = 1'b0;
    assign r_link_any = 1'b0;
    assign w_link_ret_any = 1'b0;
    assign w_link_ret_last = 1'b0;
  end else begin : gen_obs_staged
    assign d_link_ep0_any = (|gen_ep_links[0].link_d.gen_credit.valid_q) ||
        (gen_ep_links[0].link_d.gen_credit.count_q != '0);
    assign c_link_ep0_any = (|gen_ep_links[0].link_c.gen_credit.valid_q) ||
        (gen_ep_links[0].link_c.gen_credit.count_q != '0);
    assign g_link_ep0_any = |link_g.gen_always.valid_q;
    assign u_link_ep0_any = |link_u.gen_always.valid_q;
    assign p_link_any = |link_p.gen_credit_one.valid_q;
    assign r_link_any = |link_r.gen_always.valid_q;
    assign w_link_ret_any = |link_w.gen_mirror.return_q;
    assign w_link_ret_last = link_w.gen_mirror.return_q[LINK_STAGES-1];
    always_comb begin
      wa_link_any = 2'b00;
      wa_link_ge1 = 2'b00;
      wa_link_ge2 = 2'b00;
      wa_link_ord = 2'b00;
      wa_link_ord_ge1 = 2'b00;
      wa_link_ord_ge2 = 2'b00;
      wa_link_abs = 2'b00;
      wa_link_abs_ge1 = 2'b00;
      wa_link_abs_ge2 = 2'b00;
      wa_link_abs_fill = 2'b00;
      wa_link_abs_fill_ge1 = 2'b00;
      wa_link_abs_fill_ge2 = 2'b00;
      r_link_abs = 2'b00;
      r_link_sc_reply_clean = 1'b0;
      r_link_sc_reply_abs = 1'b0;
      r_link_sc_reply_abs_slot = 2'b00;
      r_link_fill_reply_clean = 1'b0;
      r_link_fill_reply_abs = 1'b0;
      r_link_fill_reply_abs_slot = 2'b00;
      g_link_sc_grantm = 2'b00;
      g_link_sc_any = 1'b0;
      g_link_getm_any = 1'b0;
      g_link_getm_addr = '0;
      for (int s = 0; s < int'(LINK_STAGES); s++) begin
        coh_wa_t wa_s;
        coh_r_t  r_s;
        coh_g_t  g_s;
        wa_s = link_wa.gen_always.payload_q[s*(AddrWidth+11)+:(AddrWidth+11)];
        r_s  = link_r.gen_always.payload_q[s*(AddrWidth+275)+:(AddrWidth+275)];
        g_s  = link_g.gen_always.payload_q[s*(AddrWidth+275)+:(AddrWidth+275)];
        if (link_r.gen_always.valid_q[s] && !r_s.error &&
            engine_sc_probe_wait_read &&
            r_s.tid == eng_tid && r_s.addr == eng_addr &&
            (r_s.opcode == coherence_pkg::ProbeAck || r_s.opcode == coherence_pkg::ProbeData)) begin
          if (r_s.absorbed) begin
            r_link_sc_reply_abs = 1'b1;
            r_link_sc_reply_abs_slot[r_s.put_id] = 1'b1;
          end else begin
            r_link_sc_reply_clean = 1'b1;
          end
        end
        if (link_r.gen_always.valid_q[s] && !r_s.error &&
            home.fill_phase_q[0] == FillRecall && home.recall_phase_q[0] == RecallWait &&
            r_s.tid == FillTid && r_s.addr == home_fill_probe.addr &&
            (r_s.opcode == coherence_pkg::ProbeAck || r_s.opcode == coherence_pkg::ProbeData)) begin
          if (r_s.absorbed) begin
            r_link_fill_reply_abs = 1'b1;
            r_link_fill_reply_abs_slot[r_s.put_id] = 1'b1;
          end else begin
            r_link_fill_reply_clean = 1'b1;
          end
        end
        if (link_g.gen_always.valid_q[s] && !g_s.error &&
            g_s.opcode == coherence_pkg::GrantM) begin
          g_link_getm_any  = 1'b1;
          g_link_getm_addr = g_s.addr;
          if (ep0_sc_live && g_s.q == hart.acquisition_q.q &&
              g_s.addr == hart.acquisition_q.addr)
            g_link_sc_any = 1'b1;
        end
        for (int slot = 0; slot < 2; slot++) begin
          if (link_wa.gen_always.valid_q[s] && !wa_s.error &&
              wa_s.put_id == 1'(slot) &&
              wa_s.addr[AddrWidth-1:5] == hart.wb_addr[slot][AddrWidth-1:5]) begin
            wa_link_any[slot] = 1'b1;
            if (s >= 1) wa_link_ge1[slot] = 1'b1;
            if (s >= 2) wa_link_ge2[slot] = 1'b1;
            if (!wa_s.absorbed) begin
              wa_link_ord[slot] = 1'b1;
              if (s >= 1) wa_link_ord_ge1[slot] = 1'b1;
              if (s >= 2) wa_link_ord_ge2[slot] = 1'b1;
            end
            if (wa_s.absorbed) begin
              wa_link_abs[slot] = 1'b1;
              if (s >= 1) wa_link_abs_ge1[slot] = 1'b1;
              if (s >= 2) wa_link_abs_ge2[slot] = 1'b1;
              if (wa_s.tid == FillTid) begin
                wa_link_abs_fill[slot] = 1'b1;
                if (s >= 1) wa_link_abs_fill_ge1[slot] = 1'b1;
                if (s >= 2) wa_link_abs_fill_ge2[slot] = 1'b1;
              end
            end
          end
          if (link_r.gen_always.valid_q[s] && !r_s.error && r_s.absorbed &&
              r_s.put_id == 1'(slot) &&
              r_s.addr[AddrWidth-1:5] == hart.wb_addr[slot][AddrWidth-1:5])
            r_link_abs[slot] = 1'b1;
          if (link_g.gen_always.valid_q[s] && !g_s.error &&
              g_s.opcode == coherence_pkg::GrantM &&
              ep0_sc_live && g_s.q == hart.acquisition_q.q &&
              g_s.addr[AddrWidth-1:5] == hart.wb_addr[slot][AddrWidth-1:5])
            g_link_sc_grantm[slot] = 1'b1;
        end
      end
    end
  end

  wire l1d_r_sc_clean = l1d_r_valid && !l1d_r_pkt.error && !l1d_r_pkt.absorbed &&
      engine_sc_probe_wait_read &&
      l1d_r_pkt.tid == eng_tid && l1d_r_pkt.addr == eng_addr &&
      (l1d_r_pkt.opcode == coherence_pkg::ProbeAck ||
       l1d_r_pkt.opcode == coherence_pkg::ProbeData);
  wire l1d_r_sc_abs = l1d_r_valid && !l1d_r_pkt.error && l1d_r_pkt.absorbed &&
      engine_sc_probe_wait_read &&
      l1d_r_pkt.tid == eng_tid && l1d_r_pkt.addr == eng_addr &&
      l1d_r_pkt.opcode == coherence_pkg::ProbeData;
  wire l1d_probe_reply_sc_clean = hart.phase_q == L1dProbeReply && !hart.reply_q.error &&
      !hart.reply_q.absorbed && engine_sc_probe_wait_read &&
      hart.probe_q.opcode == coherence_pkg::ProbeRead &&
      hart.reply_q.tid == eng_tid && hart.reply_q.addr == eng_addr;
  wire l1d_probe_reply_sc_abs = hart.phase_q == L1dProbeReply && !hart.reply_q.error &&
      hart.reply_q.absorbed && engine_sc_probe_wait_read &&
      hart.probe_q.opcode == coherence_pkg::ProbeRead &&
      hart.reply_q.tid == eng_tid && hart.reply_q.addr == eng_addr;

  wire fill_recall_wait = home.fill_phase_q[0] == FillRecall &&
      home.recall_phase_q[0] == RecallWait;
  wire l1d_r_fill_clean = l1d_r_valid && !l1d_r_pkt.error && !l1d_r_pkt.absorbed &&
      fill_recall_wait && l1d_r_pkt.tid == FillTid &&
      l1d_r_pkt.addr == home_fill_probe.addr &&
      (l1d_r_pkt.opcode == coherence_pkg::ProbeAck ||
       l1d_r_pkt.opcode == coherence_pkg::ProbeData);
  wire l1d_r_fill_abs = l1d_r_valid && !l1d_r_pkt.error && l1d_r_pkt.absorbed &&
      fill_recall_wait && l1d_r_pkt.tid == FillTid &&
      l1d_r_pkt.addr == home_fill_probe.addr &&
      l1d_r_pkt.opcode == coherence_pkg::ProbeData;
  wire l1d_probe_reply_fill_clean = hart.phase_q == L1dProbeReply && !hart.reply_q.error &&
      !hart.reply_q.absorbed && fill_recall_wait &&
      hart.probe_q.opcode == coherence_pkg::ProbeRead &&
      hart.reply_q.tid == FillTid && hart.reply_q.addr == home_fill_probe.addr;
  wire l1d_probe_reply_fill_abs = hart.phase_q == L1dProbeReply && !hart.reply_q.error &&
      hart.reply_q.absorbed && fill_recall_wait &&
      hart.probe_q.opcode == coherence_pkg::ProbeRead &&
      hart.reply_q.tid == FillTid && hart.reply_q.addr == home_fill_probe.addr;

  wire sc_grant_pipeline = engine_sc_service || result_is_sc_grantm ||
      comp_buf_is_sc_grantm || home_g_is_sc_grantm || g_link_sc_any;

  // Helper invariants (all checked as assertions, zero assumptions).
  coh_d_t ep0_demand, comp_work[2];
  coh_g_t ep0_grant_pkt;
  coh_c_t ep0_comp_pkt;
  assign ep0_demand = hart.gen_request[0].request.demand_q;
  assign comp_work[0] = home.completions.work[0];
  assign comp_work[1] = home.completions.work[1];
  assign ep0_grant_pkt = hart.gen_request[0].request.grant_q;
  assign ep0_comp_pkt = hart.gen_request[0].request.completion_q;

  function automatic logic home_block_resident(
      input logic [2:0] arr_phase,
      input logic [26:0] ent0,
      input logic [26:0] ent1,
      input logic [AddrWidth-1:0] addr
  );
    logic [26:0] ent;
    ent = addr[6] ? ent1 : ent0;
    home_block_resident = arr_phase != ArrInit && ent[26:25] != 2'b00 &&
        ent[24:0] == addr[AddrWidth-1:7];
  endfunction

  function automatic logic home_fill_installing(
      input logic [3:0] fphase,
      input logic [AddrWidth-1:0] faddr,
      input logic [AddrWidth-1:0] addr
  );
    home_fill_installing = (fphase == FillInstall || fphase == FillInstallWait) &&
        faddr[AddrWidth-1:6] == addr[AddrWidth-1:6];
  endfunction

  function automatic logic home_fill_invalidating(
      input logic [3:0] fphase,
      input logic fvic,
      input logic [AddrWidth-1:0] fold,
      input logic [AddrWidth-1:0] addr
  );
    home_fill_invalidating = (fphase == FillDetach || fphase == FillInvalidate ||
        fphase == FillInvalidateWait) && fvic && fold[AddrWidth-1:6] == addr[AddrWidth-1:6];
  endfunction

  // L1D 1-way 2-set array tag, writeback disjointness, and L2 inclusion invariants.
  localparam int unsigned ArrTagBits = AddrWidth - 6;
  localparam int unsigned ArrEntryBits = ArrTagBits + 3;
  logic inv_wb_tag_ok, inv_arr_ok, inv_freeze_ok, inv_grant_wb_ok;
  logic inv_home_arr_ok, inv_home_fill_ok, inv_home_incl_ok, inv_home_cmp_ok;
  always_comb begin
    logic [ArrEntryBits-1:0] ent;
    logic is_mod;
    logic [AddrWidth-6:0] sec;
    logic [AddrWidth-1:0] sec_addr;
    logic [26:0] h_ent;
    logic [3:0] tag_owners, read_owners, upd_owners;
    int tag_cnt, read_cnt, upd_cnt;
    inv_wb_tag_ok = 1'b1;
    inv_arr_ok = 1'b1;
    inv_freeze_ok = 1'b1;
    inv_grant_wb_ok = 1'b1;
    inv_home_arr_ok = 1'b1;
    inv_home_fill_ok = 1'b1;
    inv_home_incl_ok = 1'b1;
    inv_home_cmp_ok = 1'b1;

    // L1D array and phase consistency.
    if (hart.f_arr_phase > 4'd5) inv_arr_ok = 1'b0;
    if (hart.active && hart.phase_q == L1dLookupWait) begin
      if (hart.f_arr_phase == 4'd0 || hart.f_arr_phase == 4'd1 || hart.f_arr_phase == 4'd5)
        inv_arr_ok = 1'b0;
      if (hart.f_arr_visit || {hart.f_arr_tag, hart.f_arr_set} != hart.lookup_addr_q[AddrWidth-1:5])
        inv_arr_ok = 1'b0;
      if (hart.f_arr_phase == 4'd2 &&
          hart.f_arr_tag_rdata0 != hart.f_arr_tags[hart.f_arr_set*ArrEntryBits+:ArrEntryBits])
        inv_arr_ok = 1'b0;
      if (hart.f_arr_phase == 4'd3 || hart.f_arr_phase == 4'd4) begin
        ent = hart.f_arr_tags[hart.f_arr_set*ArrEntryBits+:ArrEntryBits];
        if (hart.array_hit !=
            (ent[ArrTagBits+:2] != 2'b00 && ent[ArrTagBits-1:0] == hart.f_arr_tag))
          inv_arr_ok = 1'b0;
        if (hart.array_state != ent[ArrTagBits+:2]) inv_arr_ok = 1'b0;
        if (hart.array_way != 1'b0) inv_arr_ok = 1'b0;
        if (hart.array_addr[AddrWidth-1:5] != {ent[ArrTagBits-1:0], hart.f_arr_set})
          inv_arr_ok = 1'b0;
      end
      if (hart.f_arr_phase == 4'd2 && hart.array_valid) inv_arr_ok = 1'b0;
      if (hart.f_arr_phase == 4'd3 && (hart.array_valid != hart.f_arr_early_reply))
        inv_arr_ok = 1'b0;
      if (hart.f_arr_phase == 4'd4 && !hart.array_valid) inv_arr_ok = 1'b0;
    end
    if (hart.active && (hart.phase_q == L1dFreeze || hart.phase_q == L1dUpdate ||
                        hart.phase_q == 4'd9 || hart.phase_q == 4'd10 ||
                        hart.phase_q == 4'd11 || hart.phase_q == 4'd12 ||
                        hart.phase_q == 4'd13 || hart.phase_q == 4'd14 ||
                        hart.phase_q == L1dProbeAbsorb)) begin
      if (hart.f_arr_phase != 4'd1 || hart.array_valid) inv_arr_ok = 1'b0;
    end
    if (hart.active && (hart.phase_q == L1dIdle || hart.phase_q == L1dLookup ||
                        hart.phase_q == L1dProbeReply || hart.phase_q == L1dAcquire)) begin
      if ((hart.f_arr_phase != 4'd0 && hart.f_arr_phase != 4'd1 && hart.f_arr_phase != 4'd5) ||
          hart.array_valid)
        inv_arr_ok = 1'b0;
    end
    if (hart.active && hart.phase_q == L1dUpdateWait) begin
      if ((hart.f_arr_phase != 4'd1 && hart.f_arr_phase != 4'd5) || hart.array_valid)
        inv_arr_ok = 1'b0;
    end
    if (hart.active && (hart.phase_q == L1dLookup || hart.phase_q == L1dLookupWait) &&
        hart.operation_q == L1dOpGrant) begin
      if (hart.lookup_addr_q[AddrWidth-1:5] != hart.grant_q.addr[AddrWidth-1:5]) inv_arr_ok = 1'b0;
      if (!hart.wb_reserved_q) inv_arr_ok = 1'b0;
      if (hart.atomic_q && hart.atomic_granted_q) inv_arr_ok = 1'b0;
    end
    if (hart.active && hart.phase_q == L1dLookupWait && hart.operation_q == L1dOpGrant) begin
      if (hart.f_arr_phase == 4'd2 && hart.f_arr_exclude != 1'b0) inv_arr_ok = 1'b0;
      if ((hart.f_arr_phase == 4'd3 || hart.f_arr_phase == 4'd4) && !hart.array_available)
        inv_arr_ok = 1'b0;
    end
    if (hart.active && (hart.phase_q == L1dLookup || hart.phase_q == L1dLookupWait) &&
        hart.operation_q == L1dOpProbe) begin
      if (hart.lookup_addr_q[AddrWidth-1:5] != hart.probe_q.addr[AddrWidth-1:5]) inv_arr_ok = 1'b0;
    end
    if (hart.active && (hart.phase_q == L1dLookup || hart.phase_q == L1dLookupWait) &&
        hart.operation_q == L1dOpStore) begin
      if (hart.lookup_addr_q[AddrWidth-1:5] != hart.pending_addr_q[AddrWidth-1:5])
        inv_arr_ok = 1'b0;
    end
    if (hart.active &&
        (hart.phase_q == L1dLookup || hart.phase_q == L1dLookupWait ||
         hart.phase_q == L1dUpdate || hart.phase_q == L1dUpdateWait) &&
        hart.operation_q == L1dOpAtomicWr) begin
      if (!(hart.atomic_q && hart.atomic_granted_q && !hart.atomic_written_q &&
            ((hart.phase_q != L1dLookup && hart.phase_q != L1dLookupWait) ||
             hart.lookup_addr_q[AddrWidth-1:5] == hart.atomic_addr_q[AddrWidth-1:5])))
        inv_arr_ok = 1'b0;
    end
    if (hart.active && (hart.phase_q == L1dLookup || hart.phase_q == L1dLookupWait) &&
        hart.operation_q == L1dOpSC) begin
      if (!(hart.atomic_q && hart.atomic_sc_q && !hart.atomic_local_q && !hart.atomic_granted_q &&
            !hart.sc_home_q && !hart.live[0] &&
            hart.lookup_addr_q[AddrWidth-1:5] == hart.atomic_addr_q[AddrWidth-1:5]))
        inv_arr_ok = 1'b0;
    end
    if (hart.active && hart.phase_q == 4'd9) begin
      if (!(hart.operation_q == L1dOpSC && hart.atomic_q && hart.atomic_sc_q &&
            !hart.atomic_local_q && !hart.atomic_granted_q && !hart.sc_home_q && !hart.live[0] &&
            (!hart.local_hit_q ||
             hart.update_addr_q[AddrWidth-1:5] == hart.atomic_addr_q[AddrWidth-1:5])))
        inv_arr_ok = 1'b0;
    end
    if (hart.active && hart.phase_q == L1dUpdate && hart.operation_q == L1dOpGrant) begin
      if (hart.update_addr_q[AddrWidth-1:5] != hart.grant_q.addr[AddrWidth-1:5] ||
          (hart.state_q == coherence_pkg::Modified) !=
          (!hart.grant_q.error && coherence_pkg::is_grantm(
              hart.grant_q.opcode
          )))
        inv_arr_ok = 1'b0;
    end
    if (hart.active && hart.phase_q == L1dUpdateWait && hart.operation_q == L1dOpGrant &&
        hart.acquisition_sc_q) begin
      ent = hart.f_arr_tags[hart.acquisition_q.addr[5]*ArrEntryBits+:ArrEntryBits];
      if (!(hart.f_arr_phase != 4'd0 && ent[ArrTagBits+:2] == 2'b11 &&
            ent[ArrTagBits-1:0] == hart.acquisition_q.addr[AddrWidth-1:6]))
        inv_arr_ok = 1'b0;
    end
    if (hart.active && hart.phase_q == L1dUpdate &&
        !(hart.operation_q == L1dOpGrant || hart.operation_q == L1dOpStore ||
          hart.operation_q == L1dOpAtomicWr || hart.operation_q == L1dOpProbe))
      inv_arr_ok = 1'b0;
    if (hart.active && hart.phase_q == L1dUpdate &&
        (hart.operation_q == L1dOpAtomicWr || hart.operation_q == L1dOpStore) &&
        hart.state_q != coherence_pkg::Modified)
      inv_arr_ok = 1'b0;
    if (hart.pending_q && hart.atomic_q) inv_arr_ok = 1'b0;
    if (hart.active && hart.phase_q != L1dIdle && hart.operation_q == L1dOpStore && hart.atomic_q)
      inv_arr_ok = 1'b0;
    if (hart.atomic_write_q && !(hart.atomic_q && hart.atomic_granted_q && !hart.atomic_written_q))
      inv_arr_ok = 1'b0;
    if ((hart.atomic_granted_q || hart.atomic_local_q) && !hart.atomic_q) inv_arr_ok = 1'b0;
    if (hart.atomic_q && !hart.atomic_local_q && hart.atomic_granted_q &&
        !(hart.live[0] &&
          (hart.atomic_written_q ? (ep0_done_ph || ep0_send_c || ep0_wait_u) :
                                   (ep0_done_ph && !hart.done_q))))
      inv_arr_ok = 1'b0;
    if (hart.atomic_q && hart.atomic_granted_q && !hart.atomic_written_q) begin
      ent = hart.f_arr_tags[hart.atomic_addr_q[5]*ArrEntryBits+:ArrEntryBits];
      if (!(hart.f_arr_phase != 4'd0 && ent[ArrTagBits+:2] == 2'b11 &&
            ent[ArrTagBits-1:0] == hart.atomic_addr_q[AddrWidth-1:6]))
        inv_arr_ok = 1'b0;
      if (!hart.atomic_local_q &&
          !(ep0_done_ph && !hart.done_q &&
            hart.acquisition_q.addr[AddrWidth-1:5] == hart.atomic_addr_q[AddrWidth-1:5]))
        inv_arr_ok = 1'b0;
    end
    if (hart.phase_q == 4'd11 || hart.phase_q == 4'd12) begin
      if (!(hart.atomic_q && hart.atomic_local_q &&
            hart.atomic_granted_q && !hart.atomic_written_q))
        inv_arr_ok = 1'b0;
    end
    if (hart.active && hart.phase_q == L1dAcquire) begin
      if (hart.acq_ep_q != 1'b0 || hart.live[0] || !hart.wb_free || hart.atomic_local_q ||
          (hart.operation_q != L1dOpStore && hart.operation_q != L1dOpSC))
        inv_freeze_ok = 1'b0;
      if (hart.operation_q == L1dOpSC &&
          !(hart.atomic_q && hart.atomic_sc_q &&
            hart.lookup_addr_q[AddrWidth-1:5] == hart.atomic_addr_q[AddrWidth-1:5]))
        inv_freeze_ok = 1'b0;
      if (hart.operation_q == L1dOpStore) begin
        if (hart.atomic_q) inv_freeze_ok = 1'b0;
        for (int s = 0; s < 2; s++)
        if (hart.wb_live[s] && hart.wb_addr[s][AddrWidth-1:5] == hart.lookup_addr_q[AddrWidth-1:5])
          inv_freeze_ok = 1'b0;
      end
    end
    if (hart.active && hart.phase_q == L1dFreeze) begin
      if (hart.operation_q != L1dOpGrant || hart.wb_live[hart.freeze_slot_q] ||
          !hart.wb_reserved_q || hart.freeze_slot_q != hart.reserved_wb_q)
        inv_freeze_ok = 1'b0;
      if (!(hart.update_addr_q[5] == hart.freeze_addr_q[5] &&
            hart.update_addr_q[AddrWidth-1:5] != hart.freeze_addr_q[AddrWidth-1:5] &&
            hart.update_addr_q[AddrWidth-1:5] == hart.grant_q.addr[AddrWidth-1:5] &&
            (hart.state_q == coherence_pkg::Modified) ==
            (!hart.grant_q.error && coherence_pkg::is_grantm(
              hart.grant_q.opcode
          ))))
        inv_freeze_ok = 1'b0;
      ent = hart.f_arr_tags[hart.freeze_addr_q[5]*ArrEntryBits+:ArrEntryBits];
      if (!(ent[ArrTagBits+:2] == 2'b11 &&
            ent[ArrTagBits-1:0] == hart.freeze_addr_q[AddrWidth-1:6]))
        inv_freeze_ok = 1'b0;
    end
    if (hart.active && hart.phase_q == L1dUpdate && hart.state_q == coherence_pkg::Modified) begin
      if (hart.operation_q == L1dOpGrant) begin
        if (!(!hart.grant_q.error && coherence_pkg::is_grantm(
                hart.grant_q.opcode
            ) && hart.update_addr_q[AddrWidth-1:5] == hart.grant_q.addr[AddrWidth-1:5]))
          inv_freeze_ok = 1'b0;
      end else if (hart.operation_q == L1dOpStore || hart.operation_q == L1dOpAtomicWr ||
                   hart.operation_q == L1dOpProbe) begin
        ent = hart.f_arr_tags[hart.update_addr_q[5]*ArrEntryBits+:ArrEntryBits];
        if (!(ent[ArrTagBits+:2] == 2'b11 &&
              ent[ArrTagBits-1:0] == hart.update_addr_q[AddrWidth-1:6]))
          inv_freeze_ok = 1'b0;
      end else begin
        inv_freeze_ok = 1'b0;
      end
    end
    if (hart.active && hart.phase_q == L1dUpdate && hart.operation_q == L1dOpProbe) begin
      ent = hart.f_arr_tags[hart.update_addr_q[5]*ArrEntryBits+:ArrEntryBits];
      if (hart.update_mask_q != '0 ||
          hart.update_addr_q[AddrWidth-1:5] != hart.probe_q.addr[AddrWidth-1:5] ||
          ent[ArrTagBits+:2] == 2'b00 ||
          ent[ArrTagBits-1:0] != hart.update_addr_q[AddrWidth-1:6] ||
          (hart.probe_q.opcode == coherence_pkg::ProbeRead &&
           hart.state_q != coherence_pkg::Shared) ||
          (hart.probe_q.opcode == coherence_pkg::ProbeInvalidate &&
           hart.state_q != coherence_pkg::Invalid) ||
          (hart.probe_q.opcode == coherence_pkg::ProbeSnapshot &&
           hart.state_q != coherence_pkg::Modified))
        inv_freeze_ok = 1'b0;
    end
    if (hart.active && hart.phase_q >= 4'd9 && hart.phase_q <= 4'd12) begin
      if (hart.phase_q != 4'd9 || hart.local_hit_q) begin
        ent = hart.f_arr_tags[hart.update_addr_q[5]*ArrEntryBits+:ArrEntryBits];
        if (!(hart.state_q == coherence_pkg::Modified &&
              ent[ArrTagBits+:2] == 2'b11 &&
              ent[ArrTagBits-1:0] == hart.update_addr_q[AddrWidth-1:6]))
          inv_freeze_ok = 1'b0;
      end
    end
    for (int set_i = 0; set_i < 2; set_i++) begin
      ent = hart.f_arr_tags[set_i*ArrEntryBits+:ArrEntryBits];
      is_mod = (ent[ArrTagBits+:2] == 2'b11) &&
          (hart.f_arr_phase != 4'd0 || set_i < int'(hart.f_arr_init_set));
      sec = {ent[ArrTagBits-1:0], 1'(set_i)};
      sec_addr = {sec, 5'b0};
      for (int s = 0; s < 2; s++) begin
        if (hart.wb_live[s] && is_mod && sec == hart.wb_addr[s][AddrWidth-1:5]) begin
          if (!(hart.phase_q == L1dUpdate && hart.operation_q == L1dOpGrant &&
                hart.freeze_slot_q == 1'(s) &&
                hart.freeze_addr_q[AddrWidth-1:5] == sec &&
                hart.update_addr_q[5] == 1'(set_i) &&
                hart.update_addr_q[AddrWidth-1:5] != sec))
            inv_wb_tag_ok = 1'b0;
        end
      end
      // L2 inclusion for L1D Modified sectors.
      if (is_mod) begin
        if (!(home_block_resident(home.array.phase_q, home_tag_ent0, home_tag_ent1, sec_addr) ||
              home_fill_installing(home.fill_phase_q[0], home.fill_addr_q[0], sec_addr)))
          inv_home_incl_ok = 1'b0;
        if (home_fill_invalidating(
                home.fill_phase_q[0], home.fill_victim_q[0], home.fill_old_addr_q[0], sec_addr))
          inv_home_incl_ok = 1'b0;
        if (home.fill_phase_q[0] == FillRecall && home.fill_victim_q[0] &&
            home.fill_old_addr_q[0][AddrWidth-1:6] == sec_addr[AddrWidth-1:6]) begin
          if (sec_addr[5] == 1'b0 &&
              (home.fill_sector_q[0] || home.recall_phase_q[0] == RecallAck ||
               home.recall_phase_q[0] == RecallDone || l1d_probe_reply_fill_clean ||
               l1d_probe_reply_fill_abs || l1d_r_fill_clean || l1d_r_fill_abs ||
               r_link_fill_reply_clean || r_link_fill_reply_abs))
            inv_home_incl_ok = 1'b0;
          if (sec_addr[5] == 1'b1 && home.fill_sector_q[0] &&
              (home.recall_phase_q[0] == RecallAck || home.recall_phase_q[0] == RecallDone ||
               l1d_probe_reply_fill_clean || l1d_probe_reply_fill_abs ||
               l1d_r_fill_clean || l1d_r_fill_abs ||
               r_link_fill_reply_clean || r_link_fill_reply_abs))
            inv_home_incl_ok = 1'b0;
        end
      end
    end
    for (int s = 0; s < 2; s++) begin
      if (hart.wb_live[s]) begin
        if (hart.live[0] && (ep0_send_d || ep0_wait_g || ep0_grant_ph) &&
            hart.acquisition_q.opcode == coherence_pkg::GetM &&
            hart.acquisition_q.addr[AddrWidth-1:5] == hart.wb_addr[s][AddrWidth-1:5])
          inv_grant_wb_ok = 1'b0;
        if (hart.live[0] && ep0_grant_ph &&
            hart.acquisition_q.opcode == coherence_pkg::StoreConditional &&
            !ep0_grant_pkt.error && coherence_pkg::is_grantm(
                ep0_grant_pkt.opcode
            ) && hart.acquisition_q.addr[AddrWidth-1:5] == hart.wb_addr[s][AddrWidth-1:5])
          inv_grant_wb_ok = 1'b0;
        if (hart.operation_q == L1dOpGrant && !hart.grant_q.error && coherence_pkg::is_grantm(
                hart.grant_q.opcode
            ) && (hart.phase_q == L1dLookup || hart.phase_q == L1dLookupWait ||
                  hart.phase_q == L1dFreeze || hart.phase_q == L1dUpdate) &&
                hart.grant_q.addr[AddrWidth-1:5] == hart.wb_addr[s][AddrWidth-1:5])
          inv_grant_wb_ok = 1'b0;
        if (hart.operation_q == L1dOpStore &&
            (hart.phase_q == L1dLookup || hart.phase_q == L1dLookupWait) &&
            hart.lookup_addr_q[AddrWidth-1:5] == hart.wb_addr[s][AddrWidth-1:5])
          inv_grant_wb_ok = 1'b0;
        // L2 inclusion for L1D wb_live slots (except absorbed fill-recall WA already in link_wa).
        if (!wa_link_abs_fill[s]) begin
          if (!(home_block_resident(
                  home.array.phase_q, home_tag_ent0, home_tag_ent1, hart.wb_addr[s]) ||
                home_fill_installing(home.fill_phase_q[0], home.fill_addr_q[0], hart.wb_addr[s])))
            inv_home_incl_ok = 1'b0;
          if (home_fill_invalidating(
                  home.fill_phase_q[0], home.fill_victim_q[0],
                  home.fill_old_addr_q[0], hart.wb_addr[s]))
            inv_home_incl_ok = 1'b0;
          if (home.fill_phase_q[0] == FillRecall && home.fill_victim_q[0] &&
              home.fill_old_addr_q[0][AddrWidth-1:6] == hart.wb_addr[s][AddrWidth-1:6]) begin
            if (hart.wb_addr[s][5] == 1'b0 &&
                (home.fill_sector_q[0] || home.recall_phase_q[0] == RecallDone ||
                 (home.recall_phase_q[0] == RecallAck &&
                  !(home_fill_ack.absorbed && home_fill_ack.put_id == 1'(s))) ||
                 l1d_probe_reply_fill_clean || l1d_r_fill_clean || r_link_fill_reply_clean ||
                 (l1d_probe_reply_fill_abs && hart.reply_q.put_id != 1'(s)) ||
                 (l1d_r_fill_abs && l1d_r_pkt.put_id != 1'(s)) ||
                 (r_link_fill_reply_abs && !r_link_fill_reply_abs_slot[s])))
              inv_home_incl_ok = 1'b0;
            if (hart.wb_addr[s][5] == 1'b1 && home.fill_sector_q[0] &&
                (home.recall_phase_q[0] == RecallDone ||
                 (home.recall_phase_q[0] == RecallAck &&
                  !(home_fill_ack.absorbed && home_fill_ack.put_id == 1'(s))) ||
                 l1d_probe_reply_fill_clean || l1d_r_fill_clean || r_link_fill_reply_clean ||
                 (l1d_probe_reply_fill_abs && hart.reply_q.put_id != 1'(s)) ||
                 (l1d_r_fill_abs && l1d_r_pkt.put_id != 1'(s)) ||
                 (r_link_fill_reply_abs && !r_link_fill_reply_abs_slot[s])))
              inv_home_incl_ok = 1'b0;
          end
        end
        // Pipeline bound for fill-recall absorbed WA draining through link_wa.
        if (wa_link_abs_fill[s]) begin
          if (home.fill_phase_q[0] == FillInvalidate && !wa_link_abs_fill_ge1[s])
            inv_home_incl_ok = 1'b0;
          if (home.fill_phase_q[0] == FillInvalidateWait &&
              !((home.array.write_valid_q[0] && home.array.write_token_q[0] == 2'd1) ?
                wa_link_abs_fill_ge2[s] : 1'b0))
            inv_home_incl_ok = 1'b0;
          if (home.fill_phase_q[0] == FillMemory || home.fill_phase_q[0] == FillInstall ||
              home.fill_phase_q[0] == FillInstallWait || home.fill_phase_q[0] == FillReady ||
              home.fill_phase_q[0] == FillFree)
            inv_home_incl_ok = 1'b0;
        end
      end
    end
    // L2 inclusion for live GrantM in L1D/links/completions (excluding FillInstall forward window).
    if (hart.live[0] && (ep0_grant_ph || (ep0_done_ph && !hart.done_q &&
        hart.operation_q == L1dOpGrant &&
        (hart.phase_q == L1dLookup || hart.phase_q == L1dLookupWait ||
         hart.phase_q == L1dFreeze || hart.phase_q == L1dUpdate))) &&
        !ep0_grant_pkt.error && coherence_pkg::is_grantm(ep0_grant_pkt.opcode)) begin
      if (!(home_block_resident(
              home.array.phase_q, home_tag_ent0, home_tag_ent1, hart.acquisition_q.addr) ||
            home_fill_installing(
              home.fill_phase_q[0], home.fill_addr_q[0], hart.acquisition_q.addr)))
        inv_home_incl_ok = 1'b0;
      if (home_fill_invalidating(
              home.fill_phase_q[0], home.fill_victim_q[0],
              home.fill_old_addr_q[0], hart.acquisition_q.addr) ||
          (home.fill_phase_q[0] == FillRecall && home.fill_victim_q[0] &&
           home.fill_old_addr_q[0][AddrWidth-1:6] == hart.acquisition_q.addr[AddrWidth-1:6]))
        inv_home_incl_ok = 1'b0;
    end
    if (g_link_getm_any) begin
      if (!(home_block_resident(
              home.array.phase_q, home_tag_ent0, home_tag_ent1, g_link_getm_addr) ||
            home_fill_installing(home.fill_phase_q[0], home.fill_addr_q[0], g_link_getm_addr)))
        inv_home_incl_ok = 1'b0;
      if (home_fill_invalidating(
              home.fill_phase_q[0], home.fill_victim_q[0],
              home.fill_old_addr_q[0], g_link_getm_addr) ||
          (home.fill_phase_q[0] == FillRecall && home.fill_victim_q[0] &&
           home.fill_old_addr_q[0][AddrWidth-1:6] == g_link_getm_addr[AddrWidth-1:6]))
        inv_home_incl_ok = 1'b0;
    end
    for (int p = 0; p < 2; p++) begin
      if (home.put_busy_q[p]) begin
        if (!home_block_resident(
                home.array.phase_q, home_tag_ent0, home_tag_ent1, home_put_pkt[p].addr))
          inv_home_incl_ok = 1'b0;
        if (home.fill_blocking_q[0] &&
            (home.fill_addr_q[0][AddrWidth-1:6] == home_put_pkt[p].addr[AddrWidth-1:6] ||
             (home.fill_victim_q[0] &&
              home.fill_old_addr_q[0][AddrWidth-1:6] == home_put_pkt[p].addr[AddrWidth-1:6])))
          inv_home_incl_ok = 1'b0;
      end
    end

    // Production coherence_home_array invariants (ULTRA=0, WAYS=1, Sets=2).
    tag_owners = {
        home.put_phase_q[1] == PutDecision,
        home.put_phase_q[0] == PutDecision,
        1'b0,
        eng_phase == EngLookup && home.gen_engine[0].service.lookup_sent_q
    };
    read_owners = {
        1'b0,
        1'b0,
        home.fill_phase_q[0] == FillRecall &&
            home.fill_read_sent_q[0] && !home.fill_read_done_q[0],
        eng_phase == EngService &&
            home.gen_engine[0].service.read_sent_q && !home.gen_engine[0].service.read_done_q
    };
    upd_owners = {
        home.put_phase_q[1] == PutUpdateWait,
        home.put_phase_q[0] == PutUpdateWait,
        home.fill_phase_q[0] == FillInvalidateWait || home.fill_phase_q[0] == FillInstallWait,
        eng_phase == EngUpdateWait
    };
    tag_cnt = $countones(tag_owners);
    read_cnt = $countones(read_owners);
    upd_cnt = $countones(upd_owners);

    if (home.array.phase_q > ArrReply) inv_home_arr_ok = 1'b0;
    if (home.array.token_onehot_q != (4'b0001 << home.array.token_q)) inv_home_arr_ok = 1'b0;
    if (home.array.read_open_q != 3'b000 || home.array.i_req_spec) inv_home_arr_ok = 1'b0;
    if (home.array.o_read_valid != home.array.read_valid_q[2]) inv_home_arr_ok = 1'b0;
    if (home.array.phase_q == ArrInit || home.array.phase_q == ArrInitDrain ||
        home.array.phase_q == ArrIdle) begin
      if (tag_cnt != 0) inv_home_arr_ok = 1'b0;
    end else begin
      if (tag_cnt != 1 || !tag_owners[home.array.token_q]) inv_home_arr_ok = 1'b0;
      if (home.array.phase_q == ArrTags && home.array.count_q != 2'd1) inv_home_arr_ok = 1'b0;
      if (home.array.token_q == 2'd0 &&
          home.array_query[AddrWidth-1:6] != eng_addr[AddrWidth-1:6])
        inv_home_arr_ok = 1'b0;
      if (home.array.token_q == 2'd2 &&
          home.array_query[AddrWidth-1:6] != home_put_pkt[0].addr[AddrWidth-1:6])
        inv_home_arr_ok = 1'b0;
      if (home.array.token_q == 2'd3 &&
          home.array_query[AddrWidth-1:6] != home_put_pkt[1].addr[AddrWidth-1:6])
        inv_home_arr_ok = 1'b0;
    end
    h_ent = home.array.set_q ? home_tag_ent1 : home_tag_ent0;
    if (home.array.phase_q == ArrTags && home.array.tag_rdata[0] != h_ent)
      inv_home_arr_ok = 1'b0;
    if (home.array.phase_q == ArrSelect || home.array.phase_q == ArrReply) begin
      if (home.array.tags_q[0] != h_ent) inv_home_arr_ok = 1'b0;
    end
    if (home.array.phase_q == ArrReply) begin
      if (home.array_way != 1'b0 ||
          home.array_hit != (h_ent[26:25] != 2'b00 && h_ent[24:0] == home.array.tag_q) ||
          home.array_state != h_ent[26:25] ||
          home.array_addr != {h_ent[24:0], home.array.set_q, 6'b0} ||
          (home.array_hit && !home.array_available) ||
          (!home.array_hit && home.array_available && home.array_exclude[0]))
        inv_home_arr_ok = 1'b0;
    end
    if ($countones(home.array.read_valid_q) != read_cnt) inv_home_arr_ok = 1'b0;
    for (int st = 0; st < 3; st++) begin
      if (home.array.read_valid_q[st]) begin
        if (!read_owners[home.array.read_token_q[st]] || home.array.read_way_q[st] != 1'b0)
          inv_home_arr_ok = 1'b0;
        for (int oth = st + 1; oth < 3; oth++)
        if (home.array.read_valid_q[oth] &&
            home.array.read_token_q[st] == home.array.read_token_q[oth])
          inv_home_arr_ok = 1'b0;
      end
    end
    if ($countones(home.array.write_valid_q) != upd_cnt) inv_home_arr_ok = 1'b0;
    for (int st = 0; st < 2; st++) begin
      if (home.array.write_valid_q[st]) begin
        if (!upd_owners[home.array.write_token_q[st]]) inv_home_arr_ok = 1'b0;
        for (int oth = st + 1; oth < 2; oth++)
        if (home.array.write_valid_q[oth] &&
            home.array.write_token_q[st] == home.array.write_token_q[oth])
          inv_home_arr_ok = 1'b0;
      end
    end
    if (home.array.phase_q == ArrInit || home.array.phase_q == ArrInitDrain) begin
      if (home.array.read_valid_q != 3'b0 || home.array.write_valid_q != 2'b0 ||
          home.fill_phase_q[0] != FillFree || home.put_busy_q != 2'b00 ||
          home.completions.pin_valid_q != 2'b00 || (!eng_idle && eng_phase != EngLookup))
        inv_home_arr_ok = 1'b0;
      if (home.array.phase_q == ArrInit && home.array.init_set_q && home_tag_ent0 != 27'b0)
        inv_home_arr_ok = 1'b0;
      if (home.array.phase_q == ArrInitDrain && (home_tag_ent0 != 27'b0 || home_tag_ent1 != 27'b0))
        inv_home_arr_ok = 1'b0;
    end

    // Registered decision and W-readiness comparators in production coherence_home.
    if (home.array.phase_q == ArrSelect || home.array.phase_q == ArrReply) begin
      if (home.wb_block_q[0] !=
              (home.wb_addr_q[0][AddrWidth-1:6] == home.array_query[AddrWidth-1:6]) ||
          home.wb_set_q[0] != (home.wb_addr_q[0][6] == home.array_query[6]) ||
          home.fill_block_q[0] !=
              (home.fill_addr_q[0][AddrWidth-1:6] == home.array_query[AddrWidth-1:6]) ||
          home.fill_old_block_q[0] !=
              (home.fill_old_addr_q[0][AddrWidth-1:6] == home.array_query[AddrWidth-1:6]) ||
          home.fill_set_q[0] != (home.fill_addr_q[0][6] == home.array_query[6]))
        inv_home_cmp_ok = 1'b0;
      for (int p = 0; p < 2; p++) begin
        if (!home.put_accepted_q[p] &&
            (home.put_sector_q[p] !=
                (home_put_pkt[p].addr[AddrWidth-1:5] == home.decision_addr[AddrWidth-1:5]) ||
             home.put_set_q[p] != (home_put_pkt[p].addr[6] == home.array_query[6])))
          inv_home_cmp_ok = 1'b0;
        if (home.put_accepted_q[p] &&
            (!home.put_busy_q[p] || home.put_phase_q[p] != PutLookup ||
             home.held_put_sector_q !=
                (home_put_pkt[p].addr[AddrWidth-1:5] == home.decision_addr[AddrWidth-1:5]) ||
             home.held_put_set_q != (home_put_pkt[p].addr[6] == home.array_query[6])))
          inv_home_cmp_ok = 1'b0;
      end
      for (int slot = 0; slot < 2; slot++) begin
        if (home.completions.pin_valid_q[slot] &&
            home.completions.query_set_q[slot] !=
                (home.completions.work_address[slot][6] == home.array_query[6]))
          inv_home_cmp_ok = 1'b0;
      end
    end
    if (home.array.phase_q == ArrReply) begin
      if (home.wb_tag_q[0][0] != (home.wb_addr_q[0][AddrWidth-1:7] == home.array_tags[0]))
        inv_home_cmp_ok = 1'b0;
      for (int p = 0; p < 2; p++) begin
        if (!home.put_accepted_q[p] &&
            home.put_tag_q[p][0] != (home_put_pkt[p].addr[AddrWidth-1:7] == home.array_tags[0]))
          inv_home_cmp_ok = 1'b0;
        if (home.put_accepted_q[p] &&
            home.held_put_tag_q[0] != (home_put_pkt[p].addr[AddrWidth-1:7] == home.array_tags[0]))
          inv_home_cmp_ok = 1'b0;
      end
      if (!home.engine_accepted_q[0] &&
          (home.engine_set_q[0] != (eng_addr[6] == home.array_query[6]) ||
           home.engine_tag_q[0][0] != (eng_addr[AddrWidth-1:7] == home.array_tags[0])))
        inv_home_cmp_ok = 1'b0;
      if (home.engine_accepted_q[0] &&
          (eng_idle ||
           home.work_set_q != (eng_addr[6] == home.array_query[6]) ||
           home.work_tag_q[0] != (eng_addr[AddrWidth-1:7] == home.array_tags[0])))
        inv_home_cmp_ok = 1'b0;
      if (home.put_selected_q &&
          (home.held_put_set_q != (home.selected_put_q.addr[6] == home.array_query[6]) ||
           home.held_put_tag_q[0] !=
               (home.selected_put_q.addr[AddrWidth-1:7] == home.array_tags[0])))
        inv_home_cmp_ok = 1'b0;
    end
    // W readiness registered blocking terms when put_selected_q holds.
    if (home.put_selected_q) begin
      if (home.fill_blocking_q[0] &&
          (home.fill_addr_q[0][AddrWidth-1:6] == home.selected_put_q.addr[AddrWidth-1:6] ||
           (home.fill_victim_q[0] &&
            home.fill_old_addr_q[0][AddrWidth-1:6] == home.selected_put_q.addr[AddrWidth-1:6])) &&
          !home.put_held_blocked)
        inv_home_cmp_ok = 1'b0;
      if (home.wb_valid_q[0] &&
          home.wb_addr_q[0][AddrWidth-1:6] == home.selected_put_q.addr[AddrWidth-1:6] &&
          !home.put_held_blocked)
        inv_home_cmp_ok = 1'b0;
      if (home.fill_allocated_q &&
          home.fill_phase_q[0] != FillFree &&
          home.fill_addr_q[0][AddrWidth-1:6] == home.selected_put_q.addr[AddrWidth-1:6] &&
          !home.put_query_q)
        inv_home_cmp_ok = 1'b0;
      if (home.victim_allocated_q &&
          home.fill_phase_q[0] != FillFree && home.fill_victim_q[0] &&
          home.fill_old_addr_q[0][AddrWidth-1:6] == home.selected_put_q.addr[AddrWidth-1:6] &&
          !home.put_victim_q)
        inv_home_cmp_ok = 1'b0;
    end

    // Production coherence_home fill, writeback, forward, and memory invariants.
    if (home.fill_phase_q[0] > FillReady || home.recall_phase_q[0] > RecallDone ||
        home.fill_cmo_q[0] || home.fill_cmo_hit_q[0] || home.fill_cmo_clean_q[0] ||
        home.fill_cmo_inval_q[0] || home.fill_cmo_wb_q[0] || home.fill_prefetch_q[0] ||
        home.fill_zero_q[0] || home.zero_clear_q[0] || home.fill_error_q[0] ||
        home.lookup_prefetch_q || home.lookup_fill_q || home.lookup_cmo_q ||
        home.prefetch_fill_q || home.engine_prefetch_q[0] || home.engine_nofill_q[0] ||
        home.engine_cmo_q[0] || home.fill_way_q[0] != 1'b0 || home.fill_wb_q[0] != 1'b0)
      inv_home_fill_ok = 1'b0;
    if (home.fill_live_q[0] != (home.fill_phase_q[0] != FillFree) ||
        home.fill_blocking_q[0] !=
            (home.fill_phase_q[0] != FillFree && home.fill_phase_q[0] != FillReady) ||
        home.gen_fill[0].fill_install_q != (home.fill_phase_q[0] == FillInstall) ||
        home.gen_fill[0].fill_invalidate_q != (home.fill_phase_q[0] == FillInvalidate) ||
        home.forward_pick_q[0] != home.fill_forward_q[0] ||
        int'(home.fill_seat_count_q[0]) != $countones(home.fill_seats_q[0]) ||
        !$onehot0(home.fill_primary_q[0]) ||
        (home.fill_primary_q[0] & ~home.fill_seats_q[0]) != 2'b00 ||
        home.fill_forward_q[0] != (home.fill_primary_q[0] != 2'b00 &&
            (home.fill_phase_q[0] == FillInstall || home.fill_phase_q[0] == FillInstallWait ||
             home.fill_phase_q[0] == FillReady)))
      inv_home_fill_ok = 1'b0;
    if (home.fill_phase_q[0] == FillFree &&
        (home.fill_seats_q[0] != 2'b00 || home.fill_primary_q[0] != 2'b00 ||
         home.fill_forward_q[0]))
      inv_home_fill_ok = 1'b0;
    if (home.fill_phase_q[0] != FillFree) begin
      if (home.fill_addr_q[0][5:0] != 6'b0 || home.fill_old_addr_q[0][5:0] != 6'b0 ||
          (home.fill_done_q[0] && !home.fill_sent_q[0]) ||
          (home.fill_read_done_q[0] && !home.fill_read_sent_q[0]))
        inv_home_fill_ok = 1'b0;
      if (home.fill_phase_q[0] != FillInstall && home.fill_phase_q[0] != FillInstallWait &&
          home.fill_phase_q[0] != FillReady && home.fill_seats_q[0] == 2'b00)
        inv_home_fill_ok = 1'b0;
      if ((home.fill_phase_q[0] == FillInstall || home.fill_phase_q[0] == FillInstallWait ||
           home.fill_phase_q[0] == FillReady) &&
          !(home.fill_sent_q[0] && home.fill_done_q[0]))
        inv_home_fill_ok = 1'b0;
      if (home.fill_phase_q[0] == FillReady && !home.fill_woken_q[0]) inv_home_fill_ok = 1'b0;
      if (home.fill_woken_q[0] &&
          !(home.fill_phase_q[0] == FillInstallWait || home.fill_phase_q[0] == FillReady))
        inv_home_fill_ok = 1'b0;
      if (home.fill_victim_q[0] &&
          (home.fill_old_addr_q[0][6] != home.fill_addr_q[0][6] ||
           home.fill_old_addr_q[0][AddrWidth-1:6] == home.fill_addr_q[0][AddrWidth-1:6]))
        inv_home_fill_ok = 1'b0;
      if (home.fill_phase_q[0] == FillRecall || home.fill_phase_q[0] == FillDetach) begin
        if (!home.fill_victim_q[0] || !home.wb_valid_q[0] || home.wb_frozen_q[0] ||
            home.wb_addr_q[0] != home.fill_old_addr_q[0])
          inv_home_fill_ok = 1'b0;
      end
      if (home.fill_phase_q[0] == FillRecall || home.fill_phase_q[0] == FillDetach ||
          home.fill_phase_q[0] == FillInvalidate) begin
        if (!home.fill_victim_q[0] ||
            !home_block_resident(
                home.array.phase_q, home_tag_ent0, home_tag_ent1, home.fill_old_addr_q[0]))
          inv_home_fill_ok = 1'b0;
      end
      if ((home.fill_phase_q[0] == FillInvalidate ||
           home.fill_phase_q[0] == FillInvalidateWait) && !home.fill_victim_q[0])
        inv_home_fill_ok = 1'b0;
      if (home.fill_phase_q[0] == FillInvalidateWait ||
          home.fill_phase_q[0] == FillMemory || home.fill_phase_q[0] == FillInstall) begin
        if ((home.fill_addr_q[0][6] ? home_tag_ent1[26:25] : home_tag_ent0[26:25]) != 2'b00)
          inv_home_fill_ok = 1'b0;
      end
      if (home.fill_phase_q[0] == FillInstallWait || home.fill_phase_q[0] == FillReady) begin
        if (!home_block_resident(
                home.array.phase_q, home_tag_ent0, home_tag_ent1, home.fill_addr_q[0]))
          inv_home_fill_ok = 1'b0;
      end
      if (home.fill_phase_q[0] == FillRecall && home.recall_phase_q[0] == RecallAck) begin
        if (!home_fill_ack.absorbed || home_fill_ack.error ||
            home_fill_ack.hart != 1'b0 || home_fill_ack.epoch != 1'b0 ||
            home_fill_ack.tid != FillTid || home_fill_ack.addr != home_fill_probe.addr)
          inv_home_fill_ok = 1'b0;
      end
      for (int slot = 0; slot < 2; slot++) begin
        if (home.fill_seats_q[0][slot]) begin
          if (!home.completions.live[slot] || !home.completions.work_valid[slot] ||
              home.completions.pin_valid_q[slot] ||
              home.completions.work_address[slot][AddrWidth-1:6] !=
                  home.fill_addr_q[0][AddrWidth-1:6])
            inv_home_fill_ok = 1'b0;
        end
        if (home.fill_primary_q[0][slot]) begin
          if (home.completions.work_identity[slot] != 9'b0 ||
              home.completions.predecessors_q[slot] != 2'b00 ||
              home.completions.issued_q[slot] ||
              comp_work[slot].opcode != coherence_pkg::GetM ||
              home.completions.work_address[slot][5] != home.fill_primary_upper_q[0] ||
              home.fill_primary_ident_q[0] != 9'b0 ||
              home.fill_primary_tid_q[0] != 6'(slot) || !home.fill_primary_getm_q[0])
            inv_home_fill_ok = 1'b0;
        end
      end
    end
    // Memory request / response tracking invariants.
    if ((home.wb_frozen_q[0] && !home.wb_valid_q[0]) ||
        (home.wb_sent_q[0] && !home.wb_frozen_q[0]))
      inv_home_fill_ok = 1'b0;
    if (mem_read_pend_q &&
        !(home.fill_phase_q[0] != FillFree && home.fill_sent_q[0] && !home.fill_done_q[0]))
      inv_home_fill_ok = 1'b0;
    if (mem_write_pend_q && !(home.wb_valid_q[0] && home.wb_frozen_q[0] && home.wb_sent_q[0]))
      inv_home_fill_ok = 1'b0;
    if (home.memory_out_valid) begin
      if (mem_req_write) begin
        if (mem_req_id != 5'd16 || !home.wb_valid_q[0] || !home.wb_frozen_q[0] ||
            home.wb_sent_q[0] || mem_write_pend_q)
          inv_home_fill_ok = 1'b0;
      end else begin
        if (mem_req_id != 5'd0 || home.fill_phase_q[0] == FillFree ||
            home.fill_sent_q[0] || home.fill_done_q[0] || mem_read_pend_q)
          inv_home_fill_ok = 1'b0;
      end
    end
  end

  // Per-source probe uniqueness across {link_p, hart.probe_valid_q, link_r}.
  logic inv_probe_src_ok;
  if (LINK_STAGES == 0) begin : gen_probe_src_s0
    assign inv_probe_src_ok = 1'b1;
  end else begin : gen_probe_src_staged
    always_comb begin
      int eng_probe_cnt, fill_probe_cnt;
      inv_probe_src_ok = 1'b1;
      eng_probe_cnt = 0;
      fill_probe_cnt = 0;
      if (hart.probe_valid_q) begin
        if (hart.probe_q.tid == FillTid) fill_probe_cnt = fill_probe_cnt + 1;
        else eng_probe_cnt = eng_probe_cnt + 1;
      end
      for (int s = 0; s < int'(LINK_STAGES); s++) begin
        coh_p_t p_s;
        coh_r_t r_s;
        p_s = link_p.gen_credit_one.payload_q[s*(AddrWidth+30)+:(AddrWidth+30)];
        r_s = link_r.gen_always.payload_q[s*(AddrWidth+275)+:(AddrWidth+275)];
        if (link_p.gen_credit_one.valid_q[s]) begin
          if (p_s.tid == FillTid) fill_probe_cnt = fill_probe_cnt + 1;
          else eng_probe_cnt = eng_probe_cnt + 1;
        end
        if (link_r.gen_always.valid_q[s]) begin
          if (r_s.tid == FillTid) fill_probe_cnt = fill_probe_cnt + 1;
          else eng_probe_cnt = eng_probe_cnt + 1;
        end
      end
      if (eng_probe_cnt > 1 || fill_probe_cnt > 1) inv_probe_src_ok = 1'b0;
    end
  end

  for (genvar slot = 0; slot < 2; slot++) begin : gen_inv
    always_ff @(posedge i_clk)
      if (!rst) begin
        p_inv_put_phase :
        assert (home.put_phase_q[slot] <= PutAck &&
            home.put_busy_q[slot] == (home.put_phase_q[slot] != PutFree) &&
            home.put_way_q[slot] == 1'b0);
        if (home.put_busy_q[slot]) begin
          p_inv_put_meta :
          assert (home_put_pkt[slot].hart == 1'b0 &&
              home_put_pkt[slot].put_id == 1'(slot) &&
              home_put_pkt[slot].epoch == 1'b0 &&
              home_put_pkt[slot].addr[4:0] == 5'b0);
        end
        if (hart.wb_live[slot])
          p_inv_wb_aligned :
          assert (hart.wb_addr[slot][4:0] == 5'b0 &&
              hart.gen_put[slot].put.frozen_q.hart == 1'b0 &&
              hart.gen_put[slot].put.frozen_q.put_id == 1'(slot) &&
              hart.gen_put[slot].put.frozen_q.epoch == 1'b0);
        if (hart.wb_live[slot] && hart.gen_put[slot].put.phase_q == PutAccepted)
          p_inv_put_acc :
          assert (
              (home.put_busy_q[slot] && home_put_pkt[slot].addr == hart.wb_addr[slot]) ||
              wa_link_ord[slot]);
        if (hart.wb_live[slot] &&
            hart.gen_put[slot].put.phase_q == PutPresent &&
            hart.gen_put[slot].put.absorbed_q) begin
          p_inv_put_abs :
          assert (
              (hart.phase_q == L1dProbeReply && hart.reply_q.absorbed &&
               hart.reply_q.put_id == 1'(slot) &&
               hart.reply_q.addr == hart.wb_addr[slot]) ||
              (l1d_r_valid && l1d_r_pkt.absorbed &&
               l1d_r_pkt.put_id == 1'(slot) &&
               l1d_r_pkt.addr == hart.wb_addr[slot]) ||
              r_link_abs[slot] ||
              (!eng_idle && eng_phase == EngService &&
               eng_probe_phase == EngProbeAck &&
               home.gen_engine[0].service.ack_q.absorbed &&
               home.gen_engine[0].service.ack_q.put_id == 1'(slot) &&
               home.gen_engine[0].service.ack_q.addr == hart.wb_addr[slot]) ||
              (home.fill_phase_q[0] == FillRecall && home.recall_phase_q[0] == RecallAck &&
               home_fill_ack.absorbed && home_fill_ack.put_id == 1'(slot) &&
               home_fill_ack.addr == hart.wb_addr[slot]) ||
              wa_link_abs[slot]);
          if (!wa_link_abs[slot])
            p_inv_put_abs_comp :
            assert (
                (hart.gen_put[slot].put.absorb_tid_q == FillTid &&
                 home.fill_phase_q[0] == FillRecall &&
                 home_fill_probe.addr == hart.wb_addr[slot]) ||
                (hart.gen_put[slot].put.absorb_tid_q < 6'd2 &&
                 home.completions.live[hart.gen_put[slot].put.absorb_tid_q[0]] &&
                 !home.completions.release_valid[hart.gen_put[slot].put.absorb_tid_q[0]] &&
                 home.completions.work_address[hart.gen_put[slot].put.absorb_tid_q[0]]
                     [AddrWidth-1:5] == hart.wb_addr[slot][AddrWidth-1:5]));
        end
        if (home.put_busy_q[slot])
          p_inv_put_busy :
          assert (hart.wb_live[slot] &&
              hart.wb_addr[slot] == home_put_pkt[slot].addr &&
              !wa_link_ord[slot] &&
              (hart.gen_put[slot].put.phase_q == PutAccepted ||
               (w_link_ret_any && hart.wb_selected_q && hart.wb_select_q == 1'(slot) &&
                hart.gen_put[slot].put.phase_q == PutPresent &&
                !hart.gen_put[slot].put.absorbed_q)));
        if (home.ack_arbiter.selected_q && home.ack_arbiter.selected_port_q == 2'(2 + slot))
          p_inv_ack_ord_put :
          assert (
              hart.gen_put[slot].put.phase_q == PutAccepted ||
              (w_link_ret_last && hart.wb_selected_q && hart.wb_select_q == 1'(slot)));
        if (hart.phase_q == L1dProbeReply && hart.reply_q.absorbed &&
            hart.reply_q.put_id == 1'(slot))
          p_inv_reply_abs_slot :
          assert (hart.wb_live[slot] &&
              hart.gen_put[slot].put.phase_q == PutPresent &&
              hart.gen_put[slot].put.absorbed_q &&
              hart.wb_addr[slot] == hart.reply_q.addr &&
              hart.gen_put[slot].put.absorb_tid_q == hart.reply_q.tid &&
              !wa_link_abs[slot]);
        if (l1d_r_valid && l1d_r_pkt.absorbed && l1d_r_pkt.put_id == 1'(slot))
          p_inv_l1d_r_abs_slot :
          assert (hart.wb_live[slot] &&
              hart.gen_put[slot].put.phase_q == PutPresent &&
              hart.gen_put[slot].put.absorbed_q &&
              hart.wb_addr[slot] == l1d_r_pkt.addr &&
              hart.gen_put[slot].put.absorb_tid_q == l1d_r_pkt.tid &&
              !wa_link_abs[slot]);
        if (!eng_idle && eng_phase == EngService &&
            eng_probe_phase == EngProbeAck &&
            home.gen_engine[0].service.ack_q.put_id == 1'(slot))
          p_inv_eng_ack_slot :
          assert (hart.wb_live[slot] &&
              hart.gen_put[slot].put.phase_q == PutPresent &&
              hart.gen_put[slot].put.absorbed_q &&
              hart.wb_addr[slot] == home.gen_engine[0].service.ack_q.addr &&
              hart.gen_put[slot].put.absorb_tid_q == home.gen_engine[0].service.ack_q.tid &&
              !wa_link_abs[slot]);
        if (home.fill_phase_q[0] == FillRecall && home.recall_phase_q[0] == RecallAck &&
            home_fill_ack.put_id == 1'(slot))
          p_inv_fill_ack_slot :
          assert (hart.wb_live[slot] &&
              hart.gen_put[slot].put.phase_q == PutPresent &&
              hart.gen_put[slot].put.absorbed_q &&
              hart.wb_addr[slot] == home_fill_ack.addr &&
              hart.gen_put[slot].put.absorb_tid_q == FillTid &&
              !wa_link_abs[slot]);
        if (!eng_idle && eng_phase != EngLookup)
          p_inv_eng_no_put_busy :
          assert (!(home.put_busy_q[slot] &&
              home_put_pkt[slot].addr[AddrWidth-1:5] == eng_addr[AddrWidth-1:5]));
        if (sc_grant_pipeline)
          p_inv_sc_no_put_busy :
          assert (!(home.put_busy_q[slot] &&
              home_put_pkt[slot].addr[AddrWidth-1:5] == hart.acquisition_q.addr[AddrWidth-1:5]));
        if (engine_sc_live && eng_phase == EngService &&
            home.gen_engine[0].service.probe_q.opcode == coherence_pkg::CheckSC &&
            hart.wb_live[slot] && hart.gen_put[slot].put.phase_q == PutAccepted &&
            hart.wb_addr[slot][AddrWidth-1:5] == eng_addr[AddrWidth-1:5])
          p_inv_sc_check_ord :
          assert (
              eng_probe_phase == EngProbeOffer &&
              (home.probe_arbiter.selected_q && home.probe_arbiter.selected_port_q == 2'd0 ?
               wa_link_ord_ge2[slot] : wa_link_ord_ge1[slot]));
        if (engine_sc_probing_read)
          p_inv_sc_probe_no_ord :
          assert (!(hart.wb_live[slot] &&
              hart.gen_put[slot].put.phase_q == PutAccepted &&
              hart.wb_addr[slot][AddrWidth-1:5] == eng_addr[AddrWidth-1:5]));
        if (hart.operation_q == L1dOpProbe &&
            (hart.phase_q == L1dLookup || hart.phase_q == L1dLookupWait ||
             hart.phase_q == L1dUpdate || hart.phase_q == L1dProbeAbsorb) &&
            hart.wb_live[slot] && hart.wb_addr[slot] == hart.probe_q.addr)
          p_inv_probe_wb_match : assert (hart.probe_absorbed_q && hart.probe_put_q == 1'(slot));
        if (l1d_probe_reply_sc_clean || l1d_r_sc_clean || r_link_sc_reply_clean)
          p_inv_sc_reply_clean_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == eng_addr[AddrWidth-1:5]));
        if (l1d_probe_reply_sc_abs && hart.reply_q.put_id != 1'(slot))
          p_inv_sc_reply_abs_other :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == eng_addr[AddrWidth-1:5]));
        if (l1d_r_sc_abs && l1d_r_pkt.put_id != 1'(slot))
          p_inv_sc_r_abs_other :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == eng_addr[AddrWidth-1:5]));
        if (r_link_sc_reply_abs && !r_link_sc_reply_abs_slot[slot])
          p_inv_sc_rlink_abs_other :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == eng_addr[AddrWidth-1:5]));
        if (engine_sc_probe_ack)
          p_inv_sc_probe_ack_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == eng_addr[AddrWidth-1:5] &&
              !(home.gen_engine[0].service.ack_q.absorbed &&
                home.gen_engine[0].service.ack_q.put_id == 1'(slot) &&
                home.gen_engine[0].service.dirty_q)));
        if (engine_sc_past_probe)
          p_inv_sc_past_probe_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == eng_addr[AddrWidth-1:5] &&
              !(home.gen_engine[0].service.dirty_q && wa_link_abs[slot])));
        if (engine_sc_update_wait)
          p_inv_sc_upwait_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == eng_addr[AddrWidth-1:5] &&
              !((home.array.write_valid_q[0] && home.array.write_token_q[0] == 2'd0) ?
                wa_link_abs_ge1[slot] : wa_link_abs_ge2[slot])));
        if (engine_sc_result)
          p_inv_sc_result_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == eng_addr[AddrWidth-1:5]));
        if (result_is_sc_grantm)
          p_inv_result_sc_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == result_g.addr[AddrWidth-1:5]));
        if (comp_buf_is_sc_grantm)
          p_inv_buf_sc_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == comp_buf0_g.addr[AddrWidth-1:5]));
        if (home_g_is_sc_grantm)
          p_inv_home_g_sc_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == home_g.addr[AddrWidth-1:5]));
        if (g_link_sc_grantm[slot]) p_inv_link_g_sc_wb : assert (!hart.wb_live[slot]);

        // Completions per-slot invariants (supporting engine buffer 0 + forward buffer 1).
        p_inv_comp_pred :
        assert (
            home.completions.gen_endpoint[slot].endpoint.phase_q <= 3'd4 &&
            home.completions.gen_endpoint[slot].endpoint.phase_q != 3'd3 &&
            home.completions.gen_endpoint[slot].endpoint.pending_q == 4'b0 &&
            (!home.completions.handed_q[slot] ||
             (home.completions.live[slot] &&
              (!home.completions.work_valid[slot] || home.completions.result_valid_q[slot]) &&
              home.completions.work_identity[slot] == DmaKey)) &&
            !home.completions.predecessors_q[slot][slot] &&
            (home.completions.predecessors_q[slot] & ~home.completions.live) == 2'b00 &&
            home.completions.pred_clear_q[slot] ==
                (home.completions.predecessors_q[slot] == 2'b00) &&
            home.completions.way_q[slot] == 1'b0 &&
            !home.completions.follows_cmo_q[slot] &&
            !home.completions.nofill_q[slot] &&
            home.completions.parked_q[slot] == (home.fill_phase_q[0] != FillFree &&
                (home.fill_primary_q[0][slot] ||
                 (home.fill_phase_q[0] != FillReady &&
                  !(home.fill_phase_q[0] == FillInstallWait && home.fill_woken_q[0]) &&
                  home.fill_seats_q[0][slot]))));
        if (home.completions.issued_q[slot] ||
            (home.completions.live[slot] && !home.completions.work_valid[slot]))
          p_inv_comp_issued :
          assert (home.completions.live[slot] && home.completions.predecessors_q[slot] == 2'b00 &&
              !home.completions.parked_q[slot] &&
              (home.completions.work_valid[slot] || home.completions.pin_valid_q[slot]));
        if (home.completions.buffer_owned_q[slot])
          p_inv_comp_buf_own :
          assert (home.completions.issued_q[slot] && home.completions.work_valid[slot] &&
              home.completions.buffer_live_q[home.completions.buffer_index_q[slot]] &&
              (!home.completions.buffer_index_q[slot] ||
               (home.completions.result_valid_q[slot] && home.completions.pin_valid_q[slot] &&
                home.completions.work_identity[slot] == 9'b0 &&
                comp_work[slot].opcode == coherence_pkg::GetM)));
        if (home.completions.result_valid_q[slot])
          p_inv_comp_res_valid :
          assert (home.completions.buffer_owned_q[slot] &&
              home.completions.pin_valid_q[slot] &&
              home.completions.work_valid[slot] && !home.completions.error_q[slot] &&
              (home.completions.buffer_index_q[slot] ?
               (!comp_buf1_g.error && comp_buf1_g.opcode == coherence_pkg::GrantM &&
                comp_buf1_g.tid == 6'(slot) && comp_buf1_g.q == 9'b0 &&
                comp_buf1_g.addr == home.completions.work_address[slot]) :
               (!comp_buf0_g.error &&
                (comp_buf0_g.opcode != coherence_pkg::GrantFail ||
                 comp_work[slot].opcode == coherence_pkg::StoreConditional) &&
                (comp_work[slot].opcode != coherence_pkg::GetM ||
                 comp_buf0_g.opcode == coherence_pkg::GrantM) &&
                (comp_work[slot].opcode != coherence_pkg::StoreConditional ||
                 comp_buf0_g.opcode == coherence_pkg::GrantM ||
                 comp_buf0_g.opcode == coherence_pkg::GrantFail) &&
                comp_buf0_g.tid == 6'(slot) &&
                comp_buf0_g.q == home.completions.work_identity[slot] &&
                comp_buf0_g.addr == home.completions.work_address[slot] &&
                comp_buf0_g.opcode <= coherence_pkg::GrantMZero)));
        if (home.completions.pin_valid_q[slot])
          p_inv_comp_pin :
          assert (home.completions.issued_q[slot] && home.completions.live[slot] &&
              (home_block_resident(home.array.phase_q, home_tag_ent0, home_tag_ent1,
                                   home.completions.work_address[slot]) ||
               home_fill_installing(home.fill_phase_q[0], home.fill_addr_q[0],
                                    home.completions.work_address[slot])) &&
              !home_fill_invalidating(home.fill_phase_q[0], home.fill_victim_q[0],
                                      home.fill_old_addr_q[0],
                                      home.completions.work_address[slot]) &&
              !(home.fill_phase_q[0] == FillRecall && home.fill_victim_q[0] &&
                home.fill_old_addr_q[0][AddrWidth-1:6] ==
                    home.completions.work_address[slot][AddrWidth-1:6]));
        if (home.put_selected_q && home.completions.live[slot] &&
            !home.completions.release_valid[slot] &&
            home.completions.work_address[slot][AddrWidth-1:5] ==
                home.selected_put_q.addr[AddrWidth-1:5])
          p_inv_comp_put_busy : assert (home.put_busy);
        if (home.completions.live[slot] && home.completions.work_identity[slot] == 9'b0)
          p_inv_comp_ep0 :
          assert (hart.live[0] && !home.completions.handed_q[slot] &&
              !d_link_ep0_any && !u_link_ep0_any &&
              home.completions.work[slot] == hart.acquisition_q &&
              (!home.completions.work_valid[slot] || (ep0_wait_g && !g_link_ep0_any)) &&
              (home.completions.gen_endpoint[slot].endpoint.phase_q != 3'd2 ||
               ((g_link_ep0_any && ep0_wait_g) ||
                ((ep0_grant_ph || ep0_done_ph || ep0_send_c) &&
                 ep0_grant_pkt.tid == 6'(slot)) ||
                (ep0_wait_u && c_link_ep0_any && ep0_grant_pkt.tid == 6'(slot)))) &&
              (!home.completions.release_valid[slot] ||
               (ep0_wait_u && !c_link_ep0_any && ep0_grant_pkt.tid == 6'(slot))));
        if (home.completions.live[slot] && home.completions.work_identity[slot] != 9'b0)
          p_inv_comp_dma :
          assert (home.completions.work_identity[slot] == DmaKey &&
              (comp_work[slot].opcode == coherence_pkg::DMARead ||
               comp_work[slot].opcode == coherence_pkg::DMAWrite) &&
              comp_work[slot].addr[4:0] == 5'b0);
      end
  end

  always_ff @(posedge i_clk) begin
    if (rst) begin
      snapshot_probe_seen_q <= 1'b0;
      fill_recall_seen_q <= 1'b0;
    end else begin
      if (snapshot_probe_dirty) snapshot_probe_seen_q <= 1'b1;
      if (fill_recall_dirty_fire) fill_recall_seen_q <= 1'b1;
    end
    if (rst || !ep0_sc_live) begin
      sc_wa_ordinary_seen_q <= 1'b0;
      sc_wa_absorbed_seen_q <= 1'b0;
      sc_same_put_token_seen_q <= 1'b0;
      sc_put_blocked_seen_q <= 1'b0;
    end else begin
      if (wa_matches_sc && !l1d_wa_pkt.absorbed) sc_wa_ordinary_seen_q <= 1'b1;
      if (wa_matches_sc && l1d_wa_pkt.absorbed) sc_wa_absorbed_seen_q <= 1'b1;
      if (same_put_holds_token_sc) sc_same_put_token_seen_q <= 1'b1;
      if (sc_blocked_by_put) sc_put_blocked_seen_q <= 1'b1;
    end
    if (!rst) begin
      // Core obligation from standalone coherence_l1d.sv (lines 5718-5721).
      if (sc_ep0_grantm) begin
        p_sc_grantm_no_wb0 : assert (!wb0_same_grant);
        p_sc_grantm_no_wb1 : assert (!wb1_same_grant);
      end
      // Production array_token mutual exclusion: an engine decision never shares
      // a cycle with a put holding the array token.
      p_engine_put_token_excl :
      assert (!(home.array_response && home.decision_engine &&
                (home.array_token_onehot[2] || home.array_token_onehot[3])));
      p_inv_no_fatal : assert (!fatal && home.run && hart.active);
      p_inv_wb_distinct :
      assert (!(hart.wb_live[0] && hart.wb_live[1] &&
          hart.wb_addr[0][AddrWidth-1:5] == hart.wb_addr[1][AddrWidth-1:5]));
      p_inv_wb_tag_ok : assert (inv_wb_tag_ok);
      p_inv_arr_ok : assert (inv_arr_ok);
      p_inv_freeze_ok : assert (inv_freeze_ok);
      p_inv_grant_wb_ok : assert (inv_grant_wb_ok);
      p_inv_home_arr_ok : assert (inv_home_arr_ok);
      p_inv_home_fill_ok : assert (inv_home_fill_ok);
      p_inv_home_incl_ok : assert (inv_home_incl_ok);
      p_inv_home_cmp_ok : assert (inv_home_cmp_ok);
      p_inv_probe_src_ok : assert (inv_probe_src_ok);

      if (ep0_send_d || ep0_wait_g || ep0_grant_ph) p_inv_ep0_not_done : assert (!hart.done_q);
      if (hart.live[0]) begin
        if (ep0_grant_ph || ep0_done_ph || ep0_send_c || ep0_wait_u)
          p_inv_ep0_grant_meta :
          assert (ep0_grant_pkt.addr == hart.acquisition_q.addr &&
              !ep0_grant_pkt.error &&
              (hart.acquisition_q.opcode == coherence_pkg::GetM ?
               ep0_grant_pkt.opcode == coherence_pkg::GrantM :
               (ep0_grant_pkt.opcode == coherence_pkg::GrantM ||
                ep0_grant_pkt.opcode == coherence_pkg::GrantFail)));
        if (ep0_grant_ph || ep0_done_ph || ep0_send_c)
          p_inv_ep0_has_comp :
          assert (
              (home.completions.live[0] && home.completions.work_identity[0] == 9'b0 &&
               !home.completions.work_valid[0] && !home.completions.release_valid[0] &&
               !home.completions.handed_q[0] &&
               home.completions.work_address[0] == hart.acquisition_q.addr) ||
              (home.completions.live[1] && home.completions.work_identity[1] == 9'b0 &&
               !home.completions.work_valid[1] && !home.completions.release_valid[1] &&
               !home.completions.handed_q[1] &&
               home.completions.work_address[1] == hart.acquisition_q.addr));
        if (ep0_send_c)
          p_inv_ep0_comp_meta :
          assert (ep0_comp_pkt.q == 9'b0 &&
              ep0_comp_pkt.tid == ep0_grant_pkt.tid &&
              ep0_comp_pkt.addr == hart.acquisition_q.addr);
      end
      if (hart.active)
        p_inv_wb_reserved_exact :
        assert (hart.wb_reserved_q ==
            ((ep0_send_d || ep0_wait_g || ep0_grant_ph) ||
             (hart.operation_q == L1dOpGrant &&
              (hart.phase_q == L1dLookup || hart.phase_q == L1dLookupWait ||
               hart.phase_q == L1dFreeze || hart.phase_q == L1dUpdate ||
               hart.phase_q == L1dUpdateWait))));
      if (hart.active && hart.operation_q == L1dOpGrant &&
          (hart.phase_q == L1dLookup || hart.phase_q == L1dLookupWait ||
           hart.phase_q == L1dFreeze || hart.phase_q == L1dUpdate ||
           hart.phase_q == L1dUpdateWait))
        p_inv_grant_op_meta :
        assert (hart.grant_ep_q == 1'b0 &&
            hart.grant_q == ep0_grant_pkt &&
            hart.wb_reserved_q && ep0_done_ph && !hart.done_q &&
            !hart.grant_q.error && hart.grant_q.opcode == coherence_pkg::GrantM &&
            hart.grant_q.addr == hart.acquisition_q.addr &&
            !hart.atomic_local_q && !(hart.atomic_q && hart.atomic_granted_q));
      p_inv_store_buf :
      assert (hart.store_count <= 3'd4 &&
          hart.store_buffer.next_q == hart.store_head_index + hart.store_count[1:0] &&
          hart.store_valid == (
              (hart.store_count >= 3'd1 ? (4'b0001 << hart.store_head_index) : 4'b0000) |
              (hart.store_count >= 3'd2 ? (4'b0001 << (hart.store_head_index + 2'd1)) : 4'b0000) |
              (hart.store_count >= 3'd3 ? (4'b0001 << (hart.store_head_index + 2'd2)) : 4'b0000) |
              (hart.store_count >= 3'd4 ? (4'b0001 << (hart.store_head_index + 2'd3)) : 4'b0000)) &&
          (!store_credit_q || hart.store_count < 3'd4) &&
          (hart.phase_q == L1dIdle || hart.operation_q != L1dOpStore ||
           (hart.store_count >= 3'd1 && hart.store_selected_q == hart.store_head_index)) &&
          (!(hart.live[0] && hart.acquisition_store_q &&
             (ep0_send_d || ep0_wait_g || ep0_grant_ph || (ep0_done_ph && !hart.done_q))) ||
           (hart.store_count >= 3'd1 && hart.store_acquired[hart.store_head_index] &&
            !(hart.phase_q != L1dIdle && hart.operation_q == L1dOpStore))));
      if (hart.phase_q == L1dUpdateWait && hart.operation_q == L1dOpStore &&
          hart.tail_checked_q && hart.tail_q && !hart.tail_wb_blocked_q)
        p_inv_tail_wb_blk : assert (!hart.tail_wb_blocked);
      if (hart.wb_reserved_q && hart.wb_live[hart.reserved_wb_q])
        p_inv_wb_res_live :
        assert (
            (hart.phase_q == L1dUpdate && hart.operation_q == L1dOpGrant &&
             hart.freeze_slot_q == hart.reserved_wb_q) ||
            (hart.phase_q == L1dUpdateWait && hart.operation_q == L1dOpGrant));

      // Arbiter consistency across harness and production coherence_home.
      p_inv_arb_ack :
      assert (home.ack_arbiter.selected_ports_q ==
              (home.ack_arbiter.selected_q ?
               (4'b0001 << home.ack_arbiter.selected_port_q) : 4'b0000) &&
          (!home.ack_arbiter.selected_q ||
           (home.ack_valid[home.ack_arbiter.selected_port_q] &&
            home.ack_out == home.ack_payload[home.ack_arbiter.selected_port_q])));
      p_inv_arb_probe :
      assert (home.probe_arbiter.selected_ports_q ==
              (home.probe_arbiter.selected_q ?
               (4'b0001 << home.probe_arbiter.selected_port_q) : 4'b0000) &&
          (!home.probe_arbiter.selected_q ||
           (home.probe_valid[home.probe_arbiter.selected_port_q] &&
            home.probe_out == home.probe_payload[home.probe_arbiter.selected_port_q])));
      p_inv_arb_result :
      assert (home.result_arbiter.selected_ports_q ==
              (home.result_arbiter.selected_q ? 1'b1 : 1'b0) &&
          (!home.result_arbiter.selected_q ||
           (home.engine_result[0] && home.result == home.engine_result_payload[0])));
      p_inv_arb_tag :
      assert (home.tag_arbiter.selected_ports_q ==
              (home.tag_arbiter.selected_q ?
               (4'b0001 << home.tag_arbiter.selected_port_q) : 4'b0000) &&
          (!home.tag_arbiter.selected_q ||
           (home.tag_valid[home.tag_arbiter.selected_port_q] &&
            home.tag_request == home.tag_payload[home.tag_arbiter.selected_port_q])));
      p_inv_arb_read :
      assert (home.read_arbiter.selected_ports_q ==
              (home.read_arbiter.selected_q ?
               (4'b0001 << home.read_arbiter.selected_port_q) : 4'b0000) &&
          (!home.read_arbiter.selected_q ||
           (home.read_valid[home.read_arbiter.selected_port_q] &&
            home.row_request == home.read_payload[home.read_arbiter.selected_port_q])));
      p_inv_arb_update :
      assert (home.update_arbiter.selected_ports_q ==
              (home.update_arbiter.selected_q ?
               (4'b0001 << home.update_arbiter.selected_port_q) : 4'b0000) &&
          (!home.update_arbiter.selected_q ||
           (home.update_valid[home.update_arbiter.selected_port_q] &&
            home.update_request == home.update_payload[home.update_arbiter.selected_port_q])));
      p_inv_arb_d :
      assert (
          d_arbiter.selected_ports_q ==
              (d_arbiter.selected_q ? (2'b01 << d_arbiter.selected_port_q) : 2'b00) &&
          (!d_arbiter.selected_q ||
           ((d_arbiter.selected_port_q ? dma_d_valid : hart_d_valid[0]) &&
            home_d == (d_arbiter.selected_port_q ? dma_d_q : hart_d[0]))));
      p_inv_arb_c :
      assert (
          c_arbiter.selected_ports_q ==
              (c_arbiter.selected_q ? (2'b01 << c_arbiter.selected_port_q) : 2'b00) &&
          (!c_arbiter.selected_q ||
           ((c_arbiter.selected_port_q ? dma_c_valid : hart_c_valid[0]) &&
            home_c == (c_arbiter.selected_port_q ? dma_c_q : hart_c[0]))));
      p_inv_arb_rel :
      assert (
          home.completions.release_arbiter.selected_ports_q ==
              (home.completions.release_arbiter.selected_q ?
               (2'b01 << home.completions.release_arbiter.selected_port_q) : 2'b00) &&
          (!home.completions.release_arbiter.selected_q ||
           (home.completions.release_valid[home.completions.release_arbiter.selected_port_q] &&
            home_u ==
                home.completions.releases[home.completions.release_arbiter.selected_port_q])));

      // Completions global invariants (engine buffer 0 + forward buffer 1).
      p_inv_comp_global :
      assert (
          home.completions.wake_error_q == 2'b00 && home.completions.error_q == 2'b00 &&
          home.completions.work_buffer_q == 1'b0 &&
          (!home.completions.work_selected_q ||
           home.completions.work_parked_q[0] ==
               home.completions.parked_q[home.completions.work_slot_q]) &&
          home.completions.work_selected_slots_q ==
              (home.completions.work_selected_q ?
               (2'b01 << home.completions.work_slot_q) : 2'b00) &&
          home.completions.buffer_live_q[0] ==
              ((home.completions.buffer_owned_q[0] && !home.completions.buffer_index_q[0]) ||
               (home.completions.buffer_owned_q[1] && !home.completions.buffer_index_q[1])) &&
          home.completions.buffer_live_q[1] ==
              ((home.completions.buffer_owned_q[0] && home.completions.buffer_index_q[0]) ||
               (home.completions.buffer_owned_q[1] && home.completions.buffer_index_q[1])) &&
          !(home.completions.buffer_owned_q[0] && home.completions.buffer_owned_q[1] &&
            home.completions.buffer_index_q[0] == home.completions.buffer_index_q[1]) &&
          home.completions.buffer_ready_q[0] ==
              ((home.completions.result_valid_q[0] && !home.completions.buffer_index_q[0]) ||
               (home.completions.result_valid_q[1] && !home.completions.buffer_index_q[1])) &&
          home.completions.buffer_ready_q[1] == home.completions.buffer_live_q[1] &&
          (!(home.completions.live[0] && home.completions.live[1]) ||
           home.completions.work_identity[0] != home.completions.work_identity[1]));
      if (home.completions.work_selected_q)
        p_inv_comp_work_sel :
        assert (home.completions.work_valid[home.completions.work_slot_q] &&
            !home.completions.issued_q[home.completions.work_slot_q] &&
            !home.completions.buffer_owned_q[home.completions.work_slot_q] &&
            !home.completions.pin_valid_q[home.completions.work_slot_q] &&
            home.completions.predecessors_q[home.completions.work_slot_q] == 2'b00 &&
            !home.completions.buffer_live_q[0]);
      if (home.completions.grant_selected_q)
        p_inv_comp_grant_sel :
        assert (home.completions.result_valid_q[home.completions.grant_slot_q] &&
            home.completions.buffer_owned_q[home.completions.grant_slot_q] &&
            home.completions.grant_buffer_q ==
                home.completions.buffer_index_q[home.completions.grant_slot_q] &&
            home_g.q == home.completions.work_identity[home.completions.grant_slot_q] &&
            home_g.tid == 6'(home.completions.grant_slot_q) &&
            home_g.addr == home.completions.work_address[home.completions.grant_slot_q] &&
            !home_g.error &&
            (home_g.opcode != coherence_pkg::GrantFail ||
             comp_work[home.completions.grant_slot_q].opcode == coherence_pkg::StoreConditional) &&
            (comp_work[home.completions.grant_slot_q].opcode != coherence_pkg::GetM ||
             home_g.opcode == coherence_pkg::GrantM) &&
            (comp_work[home.completions.grant_slot_q].opcode != coherence_pkg::StoreConditional ||
             home_g.opcode == coherence_pkg::GrantM ||
             home_g.opcode == coherence_pkg::GrantFail) &&
            home_g.opcode <= coherence_pkg::GrantMZero);

      // Engine local invariants.
      p_inv_eng_global :
      assert (eng_phase <= EngResult &&
          eng_probe_phase <= EngProbeAck && !home.gen_engine[0].service.error_q &&
          home.gen_engine[0].service.way_q == 1'b0 &&
          (!home.gen_engine[0].service.read_done_q || home.gen_engine[0].service.read_sent_q) &&
          (!eng_idle || eng_probe_phase == EngProbeDone));
      if (home.gen_engine[0].service.quick_q && eng_phase == EngService)
        p_inv_eng_quick :
        assert (!home.gen_engine[0].service.needs_probe &&
            home.gen_engine[0].service.needs_data &&
            eng_probe_phase == EngProbeDone &&
            !home.gen_engine[0].service.dirty_q &&
            !home.gen_engine[0].service.error_q);
      if (hart.probe_valid_q)
        p_inv_probe_q_meta :
        assert (hart.probe_q.epoch == 1'b0 && hart.probe_q.addr[4:0] == 5'b0 &&
            ((eng_phase == EngService && eng_probe_phase == EngProbeWait &&
              hart.probe_q == home.gen_engine[0].service.probe_q) ||
             (home.fill_phase_q[0] == FillRecall && home.recall_phase_q[0] == RecallWait &&
              hart.probe_q == home_fill_probe)));
      if (l1d_p_valid)
        p_inv_l1d_p_eng :
        assert (
            (eng_phase == EngService &&
             eng_probe_phase == (LINK_STAGES == 0 ? EngProbeOffer : EngProbeWait) &&
             l1d_p == home.gen_engine[0].service.probe_q) ||
            (home.fill_phase_q[0] == FillRecall &&
             home.recall_phase_q[0] == (LINK_STAGES == 0 ? RecallOffer : RecallWait) &&
             l1d_p == home_fill_probe));
      if (hart.operation_q == L1dOpProbe &&
          (hart.phase_q == L1dLookup || hart.phase_q == L1dLookupWait ||
           hart.phase_q == L1dUpdate || hart.phase_q == L1dProbeAbsorb ||
           hart.phase_q == L1dProbeReply))
        p_inv_probe_op_meta :
        assert (hart.probe_valid_q && !l1d_r_valid &&
            (hart.phase_q == L1dProbeReply || hart.probe_q.opcode != coherence_pkg::CheckSC) &&
            !hart.reply_q.error && hart.reply_q.hart == 1'b0 &&
            hart.reply_q.epoch == 1'b0 && hart.reply_q.put_epoch == 1'b0 &&
            hart.reply_q.tid == hart.probe_q.tid &&
            hart.reply_q.addr == hart.probe_q.addr);
      if (hart.operation_q == L1dOpProbe &&
          (hart.phase_q == L1dUpdate || hart.phase_q == L1dProbeAbsorb ||
           hart.phase_q == L1dProbeReply))
        p_inv_reply_q_meta :
        assert (
            (hart.probe_q.opcode == coherence_pkg::CheckSC ?
             (hart.reply_q.opcode == coherence_pkg::CheckAck &&
              !hart.reply_q.data_valid && !hart.reply_q.absorbed) :
             (hart.reply_q.opcode == coherence_pkg::ProbeAck ||
              hart.reply_q.opcode == coherence_pkg::ProbeData)) &&
            (!hart.reply_q.absorbed ||
             (hart.reply_q.data_valid && hart.reply_q.opcode == coherence_pkg::ProbeData)) &&
            (hart.phase_q != L1dUpdate ||
             (hart.reply_q.absorbed == hart.probe_absorbed_q &&
              (!hart.probe_absorbed_q || hart.reply_q.put_id == hart.probe_put_q))) &&
            (hart.phase_q != L1dProbeAbsorb ||
             (hart.probe_absorbed_q && hart.reply_q.absorbed &&
              hart.reply_q.put_id == hart.probe_put_q)));
      if (hart.phase_q == L1dProbeAbsorb || hart.phase_q == L1dProbeReply)
        p_inv_probe_phase_op : assert (hart.operation_q == L1dOpProbe);
      if (l1d_r_valid)
        p_inv_l1d_r_meta :
        assert (hart.probe_valid_q && !l1d_r_pkt.error &&
            l1d_r_pkt.tid == hart.probe_q.tid && l1d_r_pkt.addr == hart.probe_q.addr &&
            l1d_r_pkt.hart == 1'b0 && l1d_r_pkt.epoch == 1'b0 &&
            l1d_r_pkt.put_epoch == 1'b0 &&
            ((eng_phase == EngService && eng_probe_phase == EngProbeWait &&
              l1d_r_pkt.tid == eng_tid && l1d_r_pkt.addr == eng_addr &&
              (home.gen_engine[0].service.probe_q.opcode == coherence_pkg::CheckSC ?
               (l1d_r_pkt.opcode == coherence_pkg::CheckAck &&
                !l1d_r_pkt.data_valid && !l1d_r_pkt.absorbed) :
               (l1d_r_pkt.opcode == coherence_pkg::ProbeAck ||
                l1d_r_pkt.opcode == coherence_pkg::ProbeData))) ||
             (home.fill_phase_q[0] == FillRecall && home.recall_phase_q[0] == RecallWait &&
              l1d_r_pkt.tid == FillTid && l1d_r_pkt.addr == home_fill_probe.addr &&
              (l1d_r_pkt.opcode == coherence_pkg::ProbeAck ||
               l1d_r_pkt.opcode == coherence_pkg::ProbeData))) &&
            (!l1d_r_pkt.absorbed ||
             (l1d_r_pkt.data_valid && l1d_r_pkt.opcode == coherence_pkg::ProbeData)));
      if (home_r_valid) begin
        p_inv_home_r_meta :
        assert (!home_r_obs.error &&
            home_r_obs.hart == 1'b0 && home_r_obs.epoch == 1'b0 &&
            home_r_obs.put_epoch == 1'b0 &&
            (!home_r_obs.absorbed ||
             (home_r_obs.data_valid && home_r_obs.opcode == coherence_pkg::ProbeData)));
      end
      if (!eng_idle) begin
        p_inv_engine_comp :
        assert (eng_tid < 6'd2 &&
            home.completions.live[eng_tid[0]] &&
            home.completions.issued_q[eng_tid[0]] &&
            home.completions.buffer_owned_q[eng_tid[0]] &&
            !home.completions.buffer_index_q[eng_tid[0]] &&
            !home.completions.result_valid_q[eng_tid[0]] &&
            home.completions.work_valid[eng_tid[0]] &&
            !home.completions.release_valid[eng_tid[0]] &&
            home.completions.work_address[eng_tid[0]] == eng_addr &&
            home.completions.work_identity[eng_tid[0]] == home.gen_engine[0].service.request_q.q &&
            home.completions.work[eng_tid[0]] == home.gen_engine[0].service.request_q &&
            home.gen_engine[0].service.way_q == 1'b0);
        if (eng_phase == EngLookup)
          p_inv_eng_lookup :
          assert (!home.completions.pin_valid_q[eng_tid[0]] &&
              !home.gen_engine[0].service.read_sent_q &&
              !home.gen_engine[0].service.read_done_q &&
              !home.gen_engine[0].service.dirty_q &&
              !home.gen_engine[0].service.failed_q &&
              !home.gen_engine[0].service.quick_q &&
              eng_probe_phase == EngProbeDone);
          else
            p_inv_eng_pinned :
            assert (home.completions.pin_valid_q[eng_tid[0]] &&
              home_block_resident(home.array.phase_q, home_tag_ent0, home_tag_ent1, eng_addr) &&
              home.gen_engine[0].service.probe_q.addr == eng_addr &&
              home.gen_engine[0].service.probe_q.tid == eng_tid &&
              home.gen_engine[0].service.probe_q.epoch == 1'b0 && eng_addr[4:0] == 5'b0 &&
              (!home.gen_engine[0].service.failed_q || eng_probe_phase == EngProbeDone) &&
              (!engine_sc_live ||
               (home.gen_engine[0].service.probe_q.opcode == coherence_pkg::ProbeRead ||
                (eng_phase == EngService &&
                 (eng_probe_phase == EngProbeOffer ||
                  eng_probe_phase == EngProbeWait) &&
                 home.gen_engine[0].service.probe_q.opcode == coherence_pkg::CheckSC))));
        if (eng_phase == EngUpdate || eng_phase == EngUpdateWait || eng_phase == EngResult)
          p_inv_eng_post_svc : assert (eng_probe_phase == EngProbeDone);
        if (eng_phase == EngService && eng_probe_phase == EngProbeAck)
          p_inv_eng_ack :
          assert (home.gen_engine[0].service.dirty_q &&
              home.gen_engine[0].service.ack_q.absorbed &&
              !home.gen_engine[0].service.ack_q.error &&
              home.gen_engine[0].service.ack_q.addr == eng_addr &&
              home.gen_engine[0].service.ack_q.tid == eng_tid &&
              home.gen_engine[0].service.ack_q.hart == 1'b0 &&
              home.gen_engine[0].service.ack_q.epoch == 1'b0);
      end
      if (l1d_wa_valid) p_inv_wa_no_err : assert (!l1d_wa_pkt.error);
      if (ep0_send_d)
        p_inv_ep0_send_d_clean :
        assert (!d_link_ep0_any && !g_link_ep0_any &&
            !c_link_ep0_any && !u_link_ep0_any &&
            !(home.completions.live[0] && home.completions.work_identity[0] == 9'b0) &&
            !(home.completions.live[1] && home.completions.work_identity[1] == 9'b0));
      if (hart.atomic_q && hart.atomic_granted_q && !hart.atomic_written_q) begin
        if (hart.atomic_local_q)
          p_inv_local_sc_no_probe :
          assert (!hart.probe_valid_q &&
              (hart.phase_q == 4'd11 || hart.phase_q == 4'd12 ||
               ((hart.phase_q == L1dUpdate || hart.phase_q == L1dUpdateWait) &&
                hart.operation_q == L1dOpAtomicWr)));
          else begin
            p_inv_remote_sc_comp :
            assert (
              (home.completions.live[0] && home.completions.work_identity[0] == 9'b0 &&
               !home.completions.work_valid[0] && !home.completions.release_valid[0] &&
               !home.completions.handed_q[0] &&
               home.completions.work_address[0][AddrWidth-1:5] ==
                   hart.atomic_addr_q[AddrWidth-1:5]) ||
              (home.completions.live[1] && home.completions.work_identity[1] == 9'b0 &&
               !home.completions.work_valid[1] && !home.completions.release_valid[1] &&
               !home.completions.handed_q[1] &&
               home.completions.work_address[1][AddrWidth-1:5] ==
                   hart.atomic_addr_q[AddrWidth-1:5]));
            p_inv_remote_sc_no_probe :
            assert (
              (eng_idle || eng_addr[AddrWidth-1:5] != hart.atomic_addr_q[AddrWidth-1:5]) &&
              (!hart.probe_valid_q ||
               hart.probe_q.addr[AddrWidth-1:5] != hart.atomic_addr_q[AddrWidth-1:5]));
          end
      end
      if (home.completions.live[0] && home.completions.live[1] &&
          home.completions.work_address[0][AddrWidth-1:5] ==
              home.completions.work_address[1][AddrWidth-1:5])
        p_inv_comp_same_sec_ord :
        assert (
            home.completions.handed_q[0] || home.completions.handed_q[1] ||
            home.completions.predecessors_q[0][1] || home.completions.predecessors_q[1][0]);

      // L1D ep0 metadata and SC exclusivity.
      p_inv_l1d_const :
      assert (!hart.maint_q && !hart.twin_fill_q &&
          hart.rd_valid_q == 8'b0 &&
          hart.way_q == 1'b0 && hart.atomic_way_q == 1'b0 &&
          (!hart.atomic_q || hart.atomic_sc_q) &&
          hart.phase_q <= 4'd14 && hart.phase_q != 4'd10 &&
          hart.operation_q <= L1dOpSC &&
          !(hart.phase_q != L1dIdle &&
            (hart.operation_q == L1dOpRead || hart.operation_q == L1dOpMaint)) &&
          (hart.phase_q != L1dFreeze || hart.operation_q == L1dOpGrant) &&
          hart.gen_request[0].request.phase_q <= 3'd6 &&
          hart.gen_put[0].put.phase_q <= PutAccepted &&
          hart.gen_put[1].put.phase_q <= PutAccepted &&
          (!hart.atomic_local_q || (!hart.live[0] &&
           (hart.phase_q == 4'd11 || hart.phase_q == 4'd12 ||
            hart.phase_q == 4'd13 || hart.phase_q == 4'd14 ||
            ((hart.phase_q == L1dUpdate || hart.phase_q == L1dUpdateWait) &&
             hart.operation_q == L1dOpAtomicWr)))) &&
          ((hart.phase_q != 4'd13 && hart.phase_q != 4'd14) ||
           (hart.atomic_q && hart.atomic_local_q)) &&
          !(hart.sc_home_q && hart.atomic_local_q) &&
          dma_phase_q <= DmaWaitU);
      if (hart.live[0])
        p_inv_ep0_meta :
        assert (ep0_demand == hart.acquisition_q &&
            (hart.acquisition_q.opcode == coherence_pkg::GetM ||
             hart.acquisition_q.opcode == coherence_pkg::StoreConditional) &&
            hart.acquisition_store_q == coherence_pkg::is_getm(
            hart.acquisition_q.opcode
        ) && hart.acquisition_sc_q == (hart.acquisition_q.opcode == coherence_pkg::StoreConditional)
            && (!hart.acquisition_sc_q ||
                (hart.atomic_q && hart.atomic_sc_q && !hart.atomic_local_q &&
                 hart.atomic_addr_q[AddrWidth-1:5] == hart.acquisition_q.addr[AddrWidth-1:5])) &&
            hart.acquisition_q.q == 9'b0 && hart.acquisition_q.addr[4:0] == 5'b0);
      if (ep0_send_d || ep0_wait_g)
        p_inv_ep0_no_grant :
        assert (hart.phase_q != L1dFreeze &&
            !(hart.operation_q == L1dOpGrant && hart.phase_q != L1dIdle) &&
            !hart.ep_grant_valid[0]);
      if (sc_grant_pipeline) begin
        p_inv_sc_ep0_wait :
        assert (ep0_sc_wait_g &&
            hart.phase_q != L1dFreeze &&
            !(hart.operation_q == L1dOpGrant && hart.phase_q != L1dIdle) &&
            !hart.maint_q && !hart.twin_fill_q);
      end
      if (dma_phase_q == DmaDemand)
        p_inv_dma_d :
        assert (dma_d_q.q == DmaKey &&
            (dma_d_q.opcode == coherence_pkg::DMARead ||
             dma_d_q.opcode == coherence_pkg::DMAWrite) &&
            dma_d_q.addr[4:0] == 5'b0);
      if (dma_phase_q == DmaHoldC || dma_phase_q == DmaSendC)
        p_inv_dma_c : assert (dma_c_q.q == DmaKey);
      if (engine_sc_live) begin
        p_inv_engine_sc_ep0 :
        assert (ep0_sc_wait_g &&
            home.gen_engine[0].service.request_q.q == hart.acquisition_q.q &&
            eng_addr == hart.acquisition_q.addr);
      end
      if (!fatal && l1d_wa_valid) p_l1d_wa_taken : assert (l1d_wa_ready);
      if (!fatal && l1d_g_valid) p_l1d_g_taken : assert (l1d_g_ready);
      if (!fatal && l1d_u_valid) p_l1d_u_taken : assert (l1d_u_ready);
      if (!fatal && home_r_valid) p_home_r_taken : assert (home_r_ready);
      p_no_fatal : assert (!fatal);

      c_sc_grantm : cover (sc_ep0_grantm);
      c_sc_grantfail : cover (sc_ep0_grantfail);
      c_putm_ordinary_wa : cover (l1d_wa_fire && !l1d_wa_pkt.absorbed);
      c_putm_absorbed_wa : cover (l1d_wa_fire && l1d_wa_pkt.absorbed);
      c_sc_wb_same_ordinary_grantm : cover (sc_ep0_grantm && sc_wa_ordinary_seen_q);
      c_sc_wb_same_absorbed_grantm : cover (sc_ep0_grantm && sc_wa_absorbed_seen_q);
      c_sc_wb_other_grantm : cover (sc_ep0_grantm && wb_other_grant);
      c_snapshot_probe_before_sc : cover (sc_ep0_grantm && snapshot_probe_seen_q);
      c_put_token_same_sector_sc : cover (sc_ep0_grantm && sc_same_put_token_seen_q);
      c_sc_blocked_by_put_blocks : cover (sc_ep0_grantm && sc_put_blocked_seen_q);
      c_sc_grantm_other_put_token :
      cover ((home_g_is_sc_grantm || sc_ep0_grantm) && any_put_holds_token);
      c_fill_recall_before_sc : cover (sc_ep0_grantm && fill_recall_seen_q);
    end
  end

  if (LINK_STAGES > 0) begin : gen_inv_staged
    localparam int unsigned LinkCredits = 2 * LINK_STAGES + 1;
    logic inv_link_rst_ok, inv_link_d_ok, inv_link_c_ok, inv_link_g_ok, inv_link_u_ok;
    logic inv_link_p_ok, inv_link_r_ok, inv_link_wa_ok, inv_link_w_ok;
    always_comb begin
      int d_occ, c_occ, wa_slot_cnt[2];
      int d_head_plus, c_head_plus, d_tail_exp, c_tail_exp;
      coh_c_t c_h, c_s;
      coh_r_t r_sr;
      inv_link_rst_ok = 1'b1;
      inv_link_d_ok = 1'b1;
      inv_link_c_ok = 1'b1;
      inv_link_g_ok = 1'b1;
      inv_link_u_ok = 1'b1;
      inv_link_p_ok = 1'b1;
      inv_link_r_ok = 1'b1;
      inv_link_wa_ok = 1'b1;
      inv_link_w_ok = 1'b1;
      c_h = '0;
      c_s = '0;
      r_sr = '0;

      if (gen_ep_links[0].link_d.gen_credit.reset_q !=
          gen_ep_links[0].link_c.gen_credit.reset_q ||
          gen_ep_links[0].link_d.gen_credit.reset_q !=
          link_p.gen_credit_one.reset_q)
        inv_link_rst_ok = 1'b0;
      if (gen_ep_links[0].link_d.gen_credit.reset_q) begin
        if (hart.live[0] || (|hart.wb_live) || hart.probe_valid_q ||
            !eng_idle || (|home.completions.live) || (|home.put_busy_q) ||
            home.put_selected_q || home.fill_phase_q[0] != FillFree ||
            (|link_g.gen_always.valid_q) || (|link_u.gen_always.valid_q) ||
            (|link_r.gen_always.valid_q) || (|link_wa.gen_always.valid_q) ||
            (|link_w.gen_mirror.valid_q) || (|link_w.gen_mirror.return_q))
          inv_link_rst_ok = 1'b0;
      end

      // link_d (KIND=1, CREDITS=2*LINK_STAGES+1).
      d_occ = $countones(gen_ep_links[0].link_d.gen_credit.valid_q) +
          int'(gen_ep_links[0].link_d.gen_credit.count_q);
      if (gen_ep_links[0].link_d.gen_credit.reset_q) begin
        if (gen_ep_links[0].link_d.gen_credit.credits_q != '0 ||
            gen_ep_links[0].link_d.gen_credit.valid_q != '0 ||
            gen_ep_links[0].link_d.gen_credit.count_q != '0 ||
            gen_ep_links[0].link_d.gen_credit.return_q != '0 ||
            gen_ep_links[0].link_d.gen_credit.head_q != '0 ||
            gen_ep_links[0].link_d.gen_credit.tail_q != '0)
          inv_link_d_ok = 1'b0;
      end else begin
        if (int'(gen_ep_links[0].link_d.gen_credit.credits_q) + d_occ + $countones(
                gen_ep_links[0].link_d.gen_credit.return_q
            ) != int'(LinkCredits))
          inv_link_d_ok = 1'b0;
      end
      d_head_plus = int'(gen_ep_links[0].link_d.gen_credit.head_q) +
          int'(gen_ep_links[0].link_d.gen_credit.count_q);
      d_tail_exp = d_head_plus >= int'(LinkCredits) ? d_head_plus - int'(LinkCredits) : d_head_plus;
      if (int'(gen_ep_links[0].link_d.gen_credit.head_q) >= int'(LinkCredits) ||
          int'(gen_ep_links[0].link_d.gen_credit.tail_q) >= int'(LinkCredits) ||
          int'(gen_ep_links[0].link_d.gen_credit.tail_q) != d_tail_exp ||
          d_occ > 1)
        inv_link_d_ok = 1'b0;
      if (d_occ == 1) begin
        if (!(hart.live[0] && ep0_wait_g && !g_link_ep0_any &&
              !c_link_ep0_any && !u_link_ep0_any &&
              !(home.completions.live[0] && home.completions.work_identity[0] == 9'b0) &&
              !(home.completions.live[1] && home.completions.work_identity[1] == 9'b0)))
          inv_link_d_ok = 1'b0;
        for (int s = 0; s < int'(LINK_STAGES); s++) begin
          if (gen_ep_links[0].link_d.gen_credit.valid_q[s] &&
              gen_ep_links[0].link_d.gen_credit.payload_q[s*(AddrWidth+312)+:(AddrWidth+312)] !=
              hart.acquisition_q)
            inv_link_d_ok = 1'b0;
        end
        if (gen_ep_links[0].link_d.gen_credit.count_q != '0 &&
            gen_ep_links[0].link_d.gen_credit.head_payload != hart.acquisition_q)
          inv_link_d_ok = 1'b0;
      end

      // link_c (KIND=1, CREDITS=2*LINK_STAGES+1).
      c_occ = $countones(gen_ep_links[0].link_c.gen_credit.valid_q) +
          int'(gen_ep_links[0].link_c.gen_credit.count_q);
      if (gen_ep_links[0].link_c.gen_credit.reset_q) begin
        if (gen_ep_links[0].link_c.gen_credit.credits_q != '0 ||
            gen_ep_links[0].link_c.gen_credit.valid_q != '0 ||
            gen_ep_links[0].link_c.gen_credit.count_q != '0 ||
            gen_ep_links[0].link_c.gen_credit.return_q != '0 ||
            gen_ep_links[0].link_c.gen_credit.head_q != '0 ||
            gen_ep_links[0].link_c.gen_credit.tail_q != '0)
          inv_link_c_ok = 1'b0;
      end else begin
        if (int'(gen_ep_links[0].link_c.gen_credit.credits_q) + c_occ + $countones(
                gen_ep_links[0].link_c.gen_credit.return_q
            ) != int'(LinkCredits))
          inv_link_c_ok = 1'b0;
      end
      c_head_plus = int'(gen_ep_links[0].link_c.gen_credit.head_q) +
          int'(gen_ep_links[0].link_c.gen_credit.count_q);
      c_tail_exp = c_head_plus >= int'(LinkCredits) ? c_head_plus - int'(LinkCredits) : c_head_plus;
      if (int'(gen_ep_links[0].link_c.gen_credit.head_q) >= int'(LinkCredits) ||
          int'(gen_ep_links[0].link_c.gen_credit.tail_q) >= int'(LinkCredits) ||
          int'(gen_ep_links[0].link_c.gen_credit.tail_q) != c_tail_exp ||
          c_occ > 1)
        inv_link_c_ok = 1'b0;
      if (c_occ == 1) begin
        if (!(hart.live[0] && ep0_wait_u && !u_link_ep0_any &&
              ep0_grant_pkt.tid < 6'd2 &&
              home.completions.live[ep0_grant_pkt.tid[0]] &&
              home.completions.work_identity[ep0_grant_pkt.tid[0]] == 9'b0 &&
              !home.completions.work_valid[ep0_grant_pkt.tid[0]] &&
              !home.completions.release_valid[ep0_grant_pkt.tid[0]] &&
              !home.completions.handed_q[ep0_grant_pkt.tid[0]]))
          inv_link_c_ok = 1'b0;
        for (int s = 0; s < int'(LINK_STAGES); s++) begin
          c_s = gen_ep_links[0].link_c.gen_credit.payload_q[s*(AddrWidth+18)+:(AddrWidth+18)];
          if (gen_ep_links[0].link_c.gen_credit.valid_q[s] &&
              !(c_s.q == 9'b0 && c_s.tid == ep0_grant_pkt.tid &&
                c_s.addr == hart.acquisition_q.addr))
            inv_link_c_ok = 1'b0;
        end
        c_h = gen_ep_links[0].link_c.gen_credit.head_payload;
        if (gen_ep_links[0].link_c.gen_credit.count_q != '0 &&
            !(c_h.q == 9'b0 && c_h.tid == ep0_grant_pkt.tid &&
              c_h.addr == hart.acquisition_q.addr))
          inv_link_c_ok = 1'b0;
      end

      // link_g (KIND=0).
      if ($countones(link_g.gen_always.valid_q) > 1) inv_link_g_ok = 1'b0;
      for (int s = 0; s < int'(LINK_STAGES); s++) begin
        coh_g_t g_s;
        g_s = link_g.gen_always.payload_q[s*(AddrWidth+275)+:(AddrWidth+275)];
        if (link_g.gen_always.valid_q[s]) begin
          if (!(hart.live[0] && ep0_wait_g && !d_link_ep0_any &&
                !g_s.error && g_s.q == 9'b0 &&
                g_s.addr == hart.acquisition_q.addr &&
                g_s.tid < 6'd2 && g_s.opcode <= coherence_pkg::GrantMZero &&
                (g_s.opcode != coherence_pkg::GrantFail ||
                 hart.acquisition_q.opcode == coherence_pkg::StoreConditional) &&
                (hart.acquisition_q.opcode != coherence_pkg::GetM ||
                 g_s.opcode == coherence_pkg::GrantM) &&
                (hart.acquisition_q.opcode != coherence_pkg::StoreConditional ||
                 g_s.opcode == coherence_pkg::GrantM ||
                 g_s.opcode == coherence_pkg::GrantFail) &&
                home.completions.live[g_s.tid[0]] &&
                home.completions.work_identity[g_s.tid[0]] == 9'b0 &&
                !home.completions.work_valid[g_s.tid[0]] &&
                !home.completions.release_valid[g_s.tid[0]] &&
                !home.completions.handed_q[g_s.tid[0]] &&
                home.completions.work_address[g_s.tid[0]] == hart.acquisition_q.addr))
            inv_link_g_ok = 1'b0;
        end
      end

      // link_u (KIND=0).
      if ($countones(link_u.gen_always.valid_q) > 1) inv_link_u_ok = 1'b0;
      for (int s = 0; s < int'(LINK_STAGES); s++) begin
        coh_u_t u_s;
        u_s = link_u.gen_always.payload_q[s*(AddrWidth+15)+:(AddrWidth+15)];
        if (link_u.gen_always.valid_q[s]) begin
          if (!(hart.live[0] && ep0_wait_u && !c_link_ep0_any &&
                u_s.q == 9'b0 && u_s.tid == ep0_grant_pkt.tid &&
                u_s.addr == hart.acquisition_q.addr &&
                !(home.completions.live[0] && home.completions.work_identity[0] == 9'b0) &&
                !(home.completions.live[1] && home.completions.work_identity[1] == 9'b0)))
            inv_link_u_ok = 1'b0;
        end
      end

      // link_p (KIND=1, CREDITS=1) and link_r (KIND=0).
      if (link_p.gen_credit_one.reset_q) begin
        if (link_p.gen_credit_one.credit_q ||
            link_p.gen_credit_one.valid_q != '0 ||
            link_p.gen_credit_one.return_q != '0)
          inv_link_p_ok = 1'b0;
      end else begin
        if (int'(link_p.gen_credit_one.credit_q) + $countones(
                link_p.gen_credit_one.valid_q
            ) + $countones(
                link_p.gen_credit_one.return_q
            ) != 1)
          inv_link_p_ok = 1'b0;
      end
      for (int s = 0; s < int'(LINK_STAGES); s++) begin
        coh_p_t p_s;
        coh_r_t r_s;
        p_s = link_p.gen_credit_one.payload_q[s*(AddrWidth+30)+:(AddrWidth+30)];
        r_s = link_r.gen_always.payload_q[s*(AddrWidth+275)+:(AddrWidth+275)];
        if (link_p.gen_credit_one.valid_q[s]) begin
          if (!((eng_phase == EngService && eng_probe_phase == EngProbeWait &&
                 p_s == home.gen_engine[0].service.probe_q) ||
                (home.fill_phase_q[0] == FillRecall && home.recall_phase_q[0] == RecallWait &&
                 p_s == home_fill_probe)))
            inv_link_p_ok = 1'b0;
        end
        if (link_r.gen_always.valid_q[s]) begin
          if (!(!r_s.error && r_s.hart == 1'b0 && r_s.epoch == 1'b0 &&
                r_s.put_epoch == 1'b0 &&
                ((eng_phase == EngService && eng_probe_phase == EngProbeWait &&
                  r_s.tid == eng_tid && r_s.addr == eng_addr &&
                  (home.gen_engine[0].service.probe_q.opcode == coherence_pkg::CheckSC ?
                   (r_s.opcode == coherence_pkg::CheckAck &&
                    !r_s.data_valid && !r_s.absorbed) :
                   (r_s.opcode == coherence_pkg::ProbeAck ||
                    r_s.opcode == coherence_pkg::ProbeData))) ||
                 (home.fill_phase_q[0] == FillRecall && home.recall_phase_q[0] == RecallWait &&
                  r_s.tid == FillTid && r_s.addr == home_fill_probe.addr &&
                  (r_s.opcode == coherence_pkg::ProbeAck ||
                   r_s.opcode == coherence_pkg::ProbeData)))))
            inv_link_r_ok = 1'b0;
          if (r_s.absorbed) begin
            if (!(r_s.data_valid && r_s.opcode == coherence_pkg::ProbeData &&
                  hart.wb_live[r_s.put_id] &&
                  hart.wb_addr[r_s.put_id] == r_s.addr &&
                  !wa_link_abs[r_s.put_id] &&
                  (r_s.put_id ?
                   (hart.gen_put[1].put.phase_q == PutPresent &&
                    hart.gen_put[1].put.absorbed_q &&
                    hart.gen_put[1].put.absorb_tid_q == r_s.tid) :
                   (hart.gen_put[0].put.phase_q == PutPresent &&
                    hart.gen_put[0].put.absorbed_q &&
                    hart.gen_put[0].put.absorb_tid_q == r_s.tid))))
              inv_link_r_ok = 1'b0;
          end
        end
      end

      // link_wa (KIND=0).
      wa_slot_cnt[0] = 0;
      wa_slot_cnt[1] = 0;
      for (int s = 0; s < int'(LINK_STAGES); s++) begin
        coh_wa_t wa_s;
        wa_s = link_wa.gen_always.payload_q[s*(AddrWidth+11)+:(AddrWidth+11)];
        if (link_wa.gen_always.valid_q[s]) begin
          if (!(!wa_s.error && wa_s.hart == 1'b0 && wa_s.epoch == 1'b0 &&
                wa_s.addr[4:0] == 5'b0 &&
                hart.wb_live[wa_s.put_id] &&
                hart.wb_addr[wa_s.put_id] == wa_s.addr))
            inv_link_wa_ok = 1'b0;
          if (wa_s.put_id) wa_slot_cnt[1] = wa_slot_cnt[1] + 1;
          else wa_slot_cnt[0] = wa_slot_cnt[0] + 1;
          if (!wa_s.absorbed) begin
            if (home.put_busy_q[wa_s.put_id] ||
                (wa_s.put_id ? (hart.gen_put[1].put.phase_q != PutAccepted) :
                               (hart.gen_put[0].put.phase_q != PutAccepted)))
              inv_link_wa_ok = 1'b0;
          end else begin
            if (!(wa_s.put_id ?
                  (hart.gen_put[1].put.phase_q == PutPresent &&
                   hart.gen_put[1].put.absorbed_q &&
                   hart.gen_put[1].put.absorb_tid_q == wa_s.tid) :
                  (hart.gen_put[0].put.phase_q == PutPresent &&
                   hart.gen_put[0].put.absorbed_q &&
                   hart.gen_put[0].put.absorb_tid_q == wa_s.tid)))
              inv_link_wa_ok = 1'b0;
          end
        end
      end
      if (wa_slot_cnt[0] > 1 || wa_slot_cnt[1] > 1) inv_link_wa_ok = 1'b0;

      // link_w (KIND=2 mirror).
      if ($countones(
              link_w.gen_mirror.return_q
          ) > 1 || ((link_w.gen_mirror.consumed_q == link_w.gen_mirror.seq_q) != w_link_ret_any))
        inv_link_w_ok = 1'b0;
      if (w_link_ret_any) begin
        if (!(hart.wb_selected_q && hart.wb_live[hart.wb_select_q] &&
              home.put_busy_q[hart.wb_select_q] &&
              home_put_pkt[hart.wb_select_q].addr == hart.wb_addr[hart.wb_select_q] &&
              !wa_link_ord[hart.wb_select_q] && !home.put_selected_q &&
              (hart.wb_select_q ?
               (hart.gen_put[1].put.phase_q == PutPresent && !hart.gen_put[1].put.absorbed_q) :
               (hart.gen_put[0].put.phase_q == PutPresent && !hart.gen_put[0].put.absorbed_q))))
          inv_link_w_ok = 1'b0;
        if (link_w.gen_mirror.return_q[0] && home.put_phase_q[hart.wb_select_q] != PutLookup)
          inv_link_w_ok = 1'b0;
        if (LINK_STAGES >= 2 && link_w.gen_mirror.return_q[LINK_STAGES >= 2 ? 1 : 0] &&
            home.ack_arbiter.selected_q &&
            home.ack_arbiter.selected_port_q == 2'(2 + hart.wb_select_q))
          inv_link_w_ok = 1'b0;
        for (int s = 0; s < int'(LINK_STAGES); s++) begin
          if (link_w.gen_mirror.valid_q[s] &&
              link_w.gen_mirror.seq_stage_q[s] != link_w.gen_mirror.seq_q)
            inv_link_w_ok = 1'b0;
        end
      end
      for (int s = 0; s < int'(LINK_STAGES); s++) begin
        coh_w_t w_s;
        w_s = link_w.gen_mirror.payload_q[s*(AddrWidth+260)+:(AddrWidth+260)];
        if (link_w.gen_mirror.valid_q[s] &&
            link_w.gen_mirror.seq_stage_q[s] != link_w.gen_mirror.consumed_q) begin
          if (!(!w_link_ret_any &&
                link_w.gen_mirror.seq_stage_q[s] == link_w.gen_mirror.seq_q &&
                w_s.hart == 1'b0 && w_s.epoch == 1'b0 && w_s.addr[4:0] == 5'b0 &&
                hart.wb_live[w_s.put_id] &&
                hart.wb_addr[w_s.put_id] == w_s.addr &&
                (w_s.put_id ? (hart.gen_put[1].put.phase_q == PutPresent) :
                              (hart.gen_put[0].put.phase_q == PutPresent))))
            inv_link_w_ok = 1'b0;
          for (int sy = 0; sy < s; sy++) begin
            if (link_w.gen_mirror.valid_q[sy] &&
                link_w.gen_mirror.seq_stage_q[sy] != link_w.gen_mirror.seq_q)
              inv_link_w_ok = 1'b0;
          end
          if (!(w_s.put_id ? hart.gen_put[1].put.absorbed_q : hart.gen_put[0].put.absorbed_q)) begin
            if (!(hart.wb_selected_q && hart.wb_select_q == w_s.put_id)) inv_link_w_ok = 1'b0;
          end else begin
            if ((l1d_r_valid && s == 0) ||
                (eng_phase == EngService && eng_probe_phase == EngProbeAck &&
                 home.gen_engine[0].service.ack_q.put_id == w_s.put_id) ||
                (home.fill_phase_q[0] == FillRecall && home.recall_phase_q[0] == RecallAck &&
                 home_fill_ack.put_id == w_s.put_id) ||
                wa_link_abs[w_s.put_id])
              inv_link_w_ok = 1'b0;
            for (int sr = 0; sr < int'(LINK_STAGES); sr++) begin
              r_sr = link_r.gen_always.payload_q[sr*(AddrWidth+275)+:(AddrWidth+275)];
              if (s < sr + 2 && link_r.gen_always.valid_q[sr] &&
                  r_sr.absorbed && r_sr.put_id == w_s.put_id)
                inv_link_w_ok = 1'b0;
            end
          end
        end
      end
    end
    always_ff @(posedge i_clk)
      if (!rst) begin
        p_inv_link_rst : assert (inv_link_rst_ok);
        p_inv_link_d : assert (inv_link_d_ok);
        p_inv_link_c : assert (inv_link_c_ok);
        p_inv_link_g : assert (inv_link_g_ok);
        p_inv_link_u : assert (inv_link_u_ok);
        p_inv_link_p : assert (inv_link_p_ok);
        p_inv_link_r : assert (inv_link_r_ok);
        p_inv_link_wa : assert (inv_link_wa_ok);
        p_inv_link_w : assert (inv_link_w_ok);
      end
  end
endmodule
