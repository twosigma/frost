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
// composes the real coherence_l1d, real coherence_home_engine, real
// coherence_home_completions, real coherence_d_arbiter instances (including
// ack_arbiter and result_arbiter), the home's PutM tracking / PutAck FSM, and
// all eight real coherence_link stages at LINK_STAGES = 0, 1, 2, 3.
module coherence_sc_wa_formal #(
    parameter int unsigned LINK_STAGES = 0,
    parameter int unsigned L1D_MISSES = 1,
    parameter int unsigned ADDR_BITS = 7,
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
    input logic i_dma_u_ready,
    input logic i_tag_ready,
    input logic i_decision_hit,
    input logic i_decision_spec,
    input logic i_read_ready,
    input logic i_data_valid_req,
    input logic i_update_ready,
    input logic i_updated_req,
    input logic [1:0] i_put_done
);
  localparam int unsigned AddrWidth = 32;
  localparam int unsigned LineBytes = 64;
  localparam logic [5:0] PutTid = 6'(coherence_pkg::put_base(1, 1));
  `FROST_COHERENCE_TYPES(AddrWidth)

  logic past_q = 1'b0;
  wire  rst = !past_q;
  always_ff @(posedge i_clk) past_q <= 1'b1;

  logic store_credit_q;
  logic hart_fatal, engine_fatal;
  wire fatal = hart_fatal || engine_fatal;
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
  logic c_dma_req, c_dma_write, c_dma_g_ready, c_dma_u_ready;
  logic [ADDR_BITS-1:5] c_dma_sector;
  logic c_tag_ready, c_decision_hit, c_decision_spec;
  logic c_read_ready, c_data_valid_req, c_update_ready, c_updated_req;
  logic [1:0] c_put_done;

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
    assign c_dma_u_ready = i_dma_u_ready;
    assign c_tag_ready = i_tag_ready;
    assign c_decision_hit = i_decision_hit;
    assign c_decision_spec = i_decision_spec;
    assign c_read_ready = i_read_ready;
    assign c_data_valid_req = i_data_valid_req;
    assign c_update_ready = i_update_ready;
    assign c_updated_req = i_updated_req;
    assign c_put_done = i_put_done;
  end else begin : gen_cover_driver
    // Four self-timed primary-input scenarios selected by i_cpu_addr[1:0] on
    // the reset cycle, using only public DUT/agent handshake outputs:
    //   0: SC GrantM followed by SC GrantFail
    //   1: Store 0x00 -> Store 0x40 (eviction PutM held in PutWork) -> SC 0x00
    //      -> ordinary WA while SC live -> SC GrantM
    //   2: Store 0x00 -> Store 0x40 (evicts 0x00 into wb) + DMAWrite 0x00
    //      paused in EngLookup (holds put_busy) -> SC 0x00 -> DMAWrite
    //      absorbs wb -> absorbed WA while SC live -> SC GrantM
    //   3: Store 0x20 -> Store 0x60 (eviction PutM held in PutWork) ->
    //      DMARead 0x60 (ProbeSnapshot dirty) -> SC 0x00 GrantM beside wb
    localparam logic [4:0] CoverWait = 5'(8 + 2 * LINK_STAGES);
    logic [1:0] cover_case_q;
    logic [3:0] cover_step_q;
    logic [4:0] cover_wait_q;
    wire cover_idle = store_credit_q && o_sc_ready && !o_pending_store && !o_atomic_live;
    always_ff @(posedge i_clk) begin
      if (rst) begin
        cover_case_q <= i_cpu_addr[1:0];
        cover_step_q <= 4'd0;
        cover_wait_q <= 5'd0;
      end else begin
        case (cover_case_q)
          2'd0: begin
            case (cover_step_q)
              4'd0: if (cover_idle) cover_step_q <= 4'd1;
              4'd1: if (o_sc_ready) cover_step_q <= 4'd2;
              4'd2: if (cover_idle) cover_step_q <= 4'd3;
              default: ;
            endcase
          end
          2'd1: begin
            case (cover_step_q)
              4'd0: if (cover_idle) cover_step_q <= 4'd1;
              4'd1: if (cover_idle) cover_step_q <= 4'd2;
              4'd2:
              if (cover_idle) begin
                cover_step_q <= 4'd3;
                cover_wait_q <= 5'd0;
              end
              4'd3: begin
                if (cover_wait_q == CoverWait) cover_step_q <= 4'd4;
                else cover_wait_q <= cover_wait_q + 5'd1;
              end
              default: ;
            endcase
          end
          2'd2: begin
            case (cover_step_q)
              4'd0: if (cover_idle) cover_step_q <= 4'd1;
              4'd1:
              if (cover_idle) begin
                cover_step_q <= 4'd2;
                cover_wait_q <= 5'd0;
              end
              4'd2: begin
                if (cover_wait_q == 5'(12 + 2 * LINK_STAGES)) cover_step_q <= 4'd3;
                else cover_wait_q <= cover_wait_q + 5'd1;
              end
              4'd3:
              if (dma_phase_q == DmaWaitG && cover_idle) begin
                cover_step_q <= 4'd4;
                cover_wait_q <= 5'd0;
              end
              4'd4: begin
                if (cover_wait_q == CoverWait) cover_step_q <= 4'd5;
                else cover_wait_q <= cover_wait_q + 5'd1;
              end
              default: ;
            endcase
          end
          default: begin
            case (cover_step_q)
              4'd0: if (cover_idle) cover_step_q <= 4'd1;
              4'd1: if (cover_idle) cover_step_q <= 4'd2;
              4'd2: if (cover_idle) cover_step_q <= 4'd3;
              4'd3: if (dma_phase_q == DmaIdle && cover_idle) cover_step_q <= 4'd4;
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
      c_atomic_write_req = 1'b0;
      c_atomic_write_mask = 8'hff;
      c_atomic_protected_extra = 1'b1;
      c_sc_req = 1'b0;
      c_sc_size = 3'd3;
      c_sc_commit_req = 1'b0;
      c_sc_result_ready = 1'b1;
      c_res_valid = 1'b0;
      c_res_size = 3'd3;
      c_cut_admit_ready = 1'b1;
      c_cut_inval_done = 1'b1;
      c_dma_req = 1'b0;
      c_dma_write = 1'b0;
      c_dma_sector = '0;
      c_dma_g_ready = 1'b1;
      c_dma_u_ready = 1'b1;
      c_tag_ready = 1'b1;
      c_decision_hit = 1'b1;
      c_decision_spec = 1'b0;
      c_read_ready = 1'b1;
      c_data_valid_req = 1'b1;
      c_update_ready = 1'b1;
      c_updated_req = 1'b1;
      c_put_done = 2'b11;

      case (cover_case_q)
        2'd0: begin
          case (cover_step_q)
            4'd0: begin
              c_sc_req = cover_idle;
              c_sc_addr = 7'h00;
              c_res_valid = 1'b1;
              c_res_addr = 7'h00;
            end
            4'd1: begin
              c_res_valid = 1'b1;
              c_res_addr = 7'h00;
              c_sc_commit_req = 1'b1;
              c_atomic_write_req = 1'b1;
            end
            4'd2: begin
              c_sc_req = cover_idle;
              c_sc_addr = 7'h20;
              c_res_valid = 1'b0;
            end
            default: ;
          endcase
        end
        2'd1: begin
          case (cover_step_q)
            4'd0: begin
              c_store_req = cover_idle;
              c_cpu_addr  = 7'h00;
            end
            4'd1: begin
              c_store_req = cover_idle;
              c_cpu_addr  = 7'h40;
              c_put_done  = 2'b00;
            end
            4'd2: begin
              c_sc_req = cover_idle;
              c_sc_addr = 7'h00;
              c_res_valid = 1'b1;
              c_res_addr = 7'h00;
              c_put_done = 2'b00;
            end
            4'd3: begin
              c_res_valid = 1'b1;
              c_res_addr  = 7'h00;
              c_put_done  = 2'b00;
            end
            default: begin
              c_res_valid = 1'b1;
              c_res_addr  = 7'h00;
              c_put_done  = 2'b11;
            end
          endcase
        end
        2'd2: begin
          case (cover_step_q)
            4'd0: begin
              c_store_req = cover_idle;
              c_cpu_addr  = 7'h00;
            end
            4'd1: begin
              c_store_req = cover_idle;
              c_cpu_addr  = 7'h40;
            end
            4'd2: begin
              if (cover_wait_q == 5'(12 + 2 * LINK_STAGES)) begin
                c_dma_req = 1'b1;
                c_dma_write = 1'b1;
                c_dma_sector = 2'd0;
              end
            end
            4'd3: begin
              c_tag_ready = 1'b0;
              c_sc_req = dma_phase_q == DmaWaitG && cover_idle;
              c_sc_addr = 7'h00;
              c_res_valid = 1'b1;
              c_res_addr = 7'h00;
            end
            4'd4: begin
              c_tag_ready = 1'b0;
              c_res_valid = 1'b1;
              c_res_addr  = 7'h00;
            end
            default: begin
              c_tag_ready = 1'b1;
              c_res_valid = 1'b1;
              c_res_addr  = 7'h00;
            end
          endcase
        end
        default: begin
          c_put_done = 2'b00;
          case (cover_step_q)
            4'd0: begin
              c_store_req = cover_idle;
              c_cpu_addr  = 7'h20;
            end
            4'd1: begin
              c_store_req = cover_idle;
              c_cpu_addr  = 7'h60;
            end
            4'd2: begin
              c_dma_req = cover_idle;
              c_dma_sector = 2'd3;
            end
            4'd3: begin
              c_sc_req = dma_phase_q == DmaIdle && cover_idle;
              c_sc_addr = 7'h00;
              c_res_valid = 1'b1;
              c_res_addr = 7'h00;
            end
            default: begin
              c_res_valid = 1'b1;
              c_res_addr  = 7'h00;
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
  wire sc_fire = sc_valid && o_sc_ready;

  wire atomic_write_ok = hart_active && c_atomic_write_req && (|c_atomic_write_mask) &&
      atomic_q && atomic_granted_q && !atomic_written_q && !atomic_write_q &&
      (!atomic_sc_q || sc_committed_q);

  wire ordinary_store_ok = hart_active && !atomic_write_ok && !sc_fire &&
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

  // Channels between L1D, real coherence_link stages, and real home components.
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

  // Minimal single-slot legal DMA agent (source 2) for ProbeSnapshot/ProbeInvalidate.
  localparam logic [8:0] DmaKey = {2'd2, 2'd3, 4'd0, 1'b0};
  coh_d_t dma_d_q;
  coh_c_t dma_c_q;
  logic dma_d_ready, dma_c_ready;
  wire dma_d_valid = ENABLE_DMA && hart_active && dma_phase_q == DmaDemand;
  wire dma_c_valid = ENABLE_DMA && hart_active && dma_phase_q == DmaSendC;
  wire dma_g_hit = ENABLE_DMA && home_g_valid && home_g.q.src == 2'd2;
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
          dma_phase_q <= DmaSendC;
        end
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

  // Real coherence_home_completions + real coherence_home_engine + real
  // coherence_d_arbiter (ack_arbiter, result_arbiter, probe_arbiter) + exact
  // coherence_home PutM acceptance & PutAck locking.
  logic run;
  always_ff @(posedge i_clk) begin
    if (rst) run <= 1'b1;
    else run <= !fatal;
  end

  logic work_valid, work_error, work_buffer;
  coh_d_t work;
  logic [5:0] work_tid;
  logic put_busy;
  logic result_valid, result_ready, engine_result_valid, engine_result_ready;
  logic [AddrWidth+274:0] engine_result_payload, result_payload;
  logic [255:0] engine_image;

  // PutM handling matching coherence_home.sv lines 1291-1434.
  typedef enum logic [1:0] {
    PutFree,
    PutWork,
    PutAck
  } put_phase_t;
  put_phase_t put_phase_q[2];
  logic [1:0] put_busy_q;
  coh_w_t incoming_put, selected_put_q, put_q[2];
  logic put_selected_q;
  assign incoming_put = home_w;
  wire put_key_match = incoming_put.hart == selected_put_q.hart &&
      incoming_put.put_id == selected_put_q.put_id &&
      incoming_put.epoch == selected_put_q.epoch &&
      incoming_put.addr == selected_put_q.addr;
  wire [AddrWidth-1:0] held_put_next = put_selected_q ? selected_put_q.addr : incoming_put.addr;
  assign home_w_ready = run && put_selected_q && put_key_match && !put_busy &&
      !put_busy_q[selected_put_q.put_id];

  always_ff @(posedge i_clk) begin
    if (rst) begin
      put_selected_q <= 1'b0;
      selected_put_q <= '0;
    end else begin
      if (!put_selected_q && home_w_valid) begin
        selected_put_q <= incoming_put;
        put_selected_q <= 1'b1;
      end
      if (put_selected_q && (!home_w_valid || !put_key_match || home_w_ready))
        put_selected_q <= 1'b0;
    end
  end

  logic [2:0] ack_valid, ack_ready;
  logic [2:0][AddrWidth+10:0] ack_payload;
  logic ack_out_valid;
  logic [AddrWidth+10:0] ack_out;

  for (genvar put = 0; put < 2; put++) begin : gen_put
    coh_wa_t ack;
    always_comb begin
      ack = '0;
      ack.hart = put_q[put].hart;
      ack.put_id = put_q[put].put_id;
      ack.epoch = put_q[put].epoch;
      ack.addr = put_q[put].addr;
      ack.tid = PutTid + 6'(put);
    end
    assign ack_valid[1+put]   = run && put_phase_q[put] == PutAck;
    assign ack_payload[1+put] = ack;
    always_ff @(posedge i_clk) begin
      if (rst) begin
        put_phase_q[put] <= PutFree;
        put_busy_q[put] <= 1'b0;
        put_q[put] <= '0;
      end else if (run) begin
        if (home_w_valid && home_w_ready && incoming_put.put_id == 1'(put)) begin
          put_q[put] <= incoming_put;
          put_busy_q[put] <= 1'b1;
          put_phase_q[put] <= PutWork;
        end
        if (put_phase_q[put] == PutWork && c_put_done[put]) put_phase_q[put] <= PutAck;
        if (ack_valid[1+put] && ack_ready[1+put]) begin
          put_phase_q[put] <= PutFree;
          put_busy_q[put]  <= 1'b0;
        end
      end
    end
  end

  // Engine array-handshake model with free latency, hit/miss, spec read, and exact PutM sector blocking.
  logic engine_idle, engine_lookup_valid, engine_read_valid, engine_update_valid;
  logic engine_take_spec;
  logic [AddrWidth-1:0] engine_lookup_addr, engine_addr;
  logic [5:0] engine_tid;
  logic [3:0] engine_opcode;
  logic engine_p_valid, engine_p_ready;
  logic [AddrWidth+29:0] engine_p;
  logic tag_pending_q, read_pending_q, update_pending_q;

  wire engine_lookup_ready = run && !tag_pending_q && c_tag_ready;
  wire engine_read_ready = run && !read_pending_q && c_read_ready;
  wire engine_update_ready = run && !update_pending_q && c_update_ready;

  wire decision_put_conflict =
      (put_busy_q[0] && put_q[0].addr[AddrWidth-1:5] == engine_addr[AddrWidth-1:5]) ||
      (put_busy_q[1] && put_q[1].addr[AddrWidth-1:5] == engine_addr[AddrWidth-1:5]);
  wire decision_valid = run && tag_pending_q;
  wire decision_resident = !decision_put_conflict && c_decision_hit;
  wire decision_spec = c_decision_spec && !read_pending_q;
  wire retry_valid = decision_valid && !decision_resident;
  wire pin_valid = decision_valid && decision_resident;
  wire data_valid = run && read_pending_q && c_data_valid_req;
  wire updated = run && update_pending_q && c_updated_req;

  always_ff @(posedge i_clk) begin
    if (rst) begin
      tag_pending_q <= 1'b0;
      read_pending_q <= 1'b0;
      update_pending_q <= 1'b0;
    end else if (run) begin
      if (decision_valid) tag_pending_q <= 1'b0;
      else if (engine_lookup_valid && engine_lookup_ready) tag_pending_q <= 1'b1;
      if (data_valid) read_pending_q <= 1'b0;
      else if ((engine_read_valid && engine_read_ready) ||
          (decision_valid && decision_resident && engine_take_spec))
        read_pending_q <= 1'b1;
      if (updated) update_pending_q <= 1'b0;
      else if (engine_update_valid && engine_update_ready) update_pending_q <= 1'b1;
    end
  end

  coherence_home_completions #(
      .ADDR_WIDTH(AddrWidth),
      .LINE_BYTES(LineBytes),
      .CACHE_BYTES(128),
      .WAYS(1),
      .SLOTS(2),
      .RESULT_SLOTS(1),
      .PREFETCH_SLOTS(0)
  ) completions (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_fatal_stop(!run),
      .i_d_valid(home_d_valid),
      .o_d_ready(home_d_ready),
      .i_d(home_d),
      .o_work_valid(work_valid),
      .i_work_ready(run && engine_idle),
      .o_work(work),
      .o_work_tid(work_tid),
      .o_work_buffer(work_buffer),
      .o_work_error(work_error),
      .o_work_counted(),
      .o_work_nofill(),
      .o_accepted(),
      .o_accepted_opcode(),
      .o_accepted_q(),
      .o_accepted_addr(),
      .i_count_valid(decision_valid),
      .i_count_tid(engine_tid),
      .o_waiting(),
      .o_waiting_request(),
      .i_park(2'b0),
      .i_wake(2'b0),
      .i_wake_error(2'b0),
      .i_retry_park(1'b0),
      .o_image_index(),
      .o_image_select(),
      .i_image_data(engine_image),
      .i_forward_valid(1'b0),
      .o_forward_ready(),
      .i_forward_slots(2'b0),
      .i_forward_way(1'b0),
      .i_forward('0),
      .i_retry_valid(retry_valid),
      .i_retry_tid(engine_tid),
      .i_pin_valid(pin_valid),
      .i_pin_tid(engine_tid),
      .i_pin_way(1'b0),
      .i_query_addr(engine_addr),
      .o_exclude(),
      .i_next_put_addr(held_put_next),
      .o_put_busy(put_busy),
      .i_result_valid(result_valid && run),
      .o_result_ready(result_ready),
      .i_result(result_payload),
      .o_g_valid(home_g_valid),
      .i_g_ready(home_g_ready),
      .o_g(home_g),
      .i_c_valid(home_c_valid),
      .o_c_ready(home_c_ready),
      .i_c(home_c),
      .o_u_valid(home_u_valid),
      .i_u_ready(home_u_ready),
      .o_u(home_u)
  );

  coherence_home_engine #(
      .ADDR_WIDTH(AddrWidth),
      .LINE_BYTES(LineBytes),
      .WAYS(1)
  ) engine (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_stop(!run),
      .i_work_valid(work_valid && engine_idle),
      .i_work(work),
      .i_tid(work_tid),
      .i_work_error(work_error),
      .o_idle(engine_idle),
      .o_lookup_valid(engine_lookup_valid),
      .i_lookup_ready(engine_lookup_ready),
      .o_lookup_addr(engine_lookup_addr),
      .o_addr(engine_addr),
      .o_tid(engine_tid),
      .o_opcode(engine_opcode),
      .o_maintenance(),
      .o_non_alloc(),
      .i_decision_valid(decision_valid),
      .i_decision_resident(decision_resident),
      .i_decision_way(1'b0),
      .i_decision_state(2'(coherence_pkg::Shared)),
      .i_decision_spec(decision_spec),
      .o_take_spec(engine_take_spec),
      .o_read_valid(engine_read_valid),
      .o_read_offer(),
      .i_read_ready(engine_read_ready),
      .o_way(),
      .i_data_valid(data_valid),
      .i_data(512'b0),
      .o_p_valid(engine_p_valid),
      .i_p_ready(engine_p_ready),
      .o_p(engine_p),
      .i_r_valid(home_r_valid),
      .o_r_ready(home_r_ready),
      .i_r(home_r),
      .o_wa_valid(ack_valid[0]),
      .i_wa_ready(ack_ready[0]),
      .o_wa(ack_payload[0]),
      .o_update_valid(engine_update_valid),
      .i_update_ready(engine_update_ready),
      .o_update_mask(),
      .o_update_data(),
      .i_updated(updated),
      .o_result_valid(engine_result_valid),
      .i_result_ready(engine_result_ready),
      .o_result(engine_result_payload),
      .o_image(engine_image),
      .o_fatal(engine_fatal)
  );

  coherence_d_arbiter #(
      .WIDTH(AddrWidth + 275),
      .PORTS(1),
      .HOLD_VALID(1)
  ) result_arbiter (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_valid(engine_result_valid),
      .o_ready(engine_result_ready),
      .i_payload(engine_result_payload),
      .o_valid(result_valid),
      .o_selected(),
      .i_ready(result_ready && run),
      .o_payload(result_payload)
  );
  logic probe_out_valid;
  logic [AddrWidth+29:0] probe_out;
  coherence_d_arbiter #(
      .WIDTH(AddrWidth + 30),
      .PORTS(1),
      .HOLD_VALID(1)
  ) probe_arbiter (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_valid(engine_p_valid),
      .o_ready(engine_p_ready),
      .i_payload(engine_p),
      .o_valid(probe_out_valid),
      .o_selected(),
      .i_ready(home_p_ready && run),
      .o_payload(probe_out)
  );
  assign home_p_valid = run && probe_out_valid;
  assign home_p = probe_out;

  coherence_d_arbiter #(
      .WIDTH(AddrWidth + 11),
      .PORTS(3),
      .HOLD_VALID(1)
  ) ack_arbiter (
      .i_clk(i_clk),
      .i_rst(rst),
      .i_valid(ack_valid),
      .o_ready(ack_ready),
      .i_payload(ack_payload),
      .o_valid(ack_out_valid),
      .o_selected(),
      .i_ready(home_wa_ready && run),
      .o_payload(ack_out)
  );
  assign home_wa_valid = run && ack_out_valid;
  assign home_wa = ack_out;

  coh_g_t  l1d_grant;
  coh_wa_t l1d_wa_pkt;
  assign l1d_grant  = l1d_g;
  assign l1d_wa_pkt = l1d_wa;

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

  logic sc_wa_ordinary_seen_q, sc_wa_absorbed_seen_q, snapshot_probe_seen_q;
  coh_r_t home_r_obs;
  assign home_r_obs = home_r;
  wire snapshot_probe_dirty = !rst && home_r_valid && home_r_ready &&
      engine.probe_q.opcode == coherence_pkg::ProbeSnapshot &&
      !home_r_obs.error && home_r_obs.opcode == coherence_pkg::ProbeData &&
      home_r_obs.data_valid && !home_r_obs.absorbed;
  wire ep0_sc_live = hart.live[0] && hart.acquisition_q.opcode == coherence_pkg::StoreConditional;
  wire l1d_wa_fire = !rst && l1d_wa_valid && l1d_wa_ready && !l1d_wa_pkt.error;
  wire wa_matches_sc = l1d_wa_fire && ep0_sc_live &&
      l1d_wa_pkt.addr[AddrWidth-1:5] == hart.acquisition_q.addr[AddrWidth-1:5];

  // Protocol-level inductive invariants (all checked as assertions, zero assumptions).
  coh_r_t l1d_r_pkt;
  coh_g_t result_g, comp_buf_g;
  assign l1d_r_pkt  = l1d_r;
  assign result_g   = result_payload;
  assign comp_buf_g = completions.buffer_q[0];

  localparam logic [3:0] EngFree = 4'd0, EngLookup = 4'd1, EngService = 4'd2,
      EngUpdate = 4'd3, EngUpdateWait = 4'd4, EngResult = 4'd5;
  localparam logic [2:0] EngProbeDone = 3'd0, EngProbeOffer = 3'd1,
      EngProbeWait = 3'd2, EngProbeAck = 3'd3;
  localparam logic [1:0] PutPresent = 2'd1, PutAccepted = 2'd2;
  localparam logic [3:0] L1dIdle = 4'd0, L1dLookup = 4'd1, L1dLookupWait = 4'd2,
      L1dAcquire = 4'd3, L1dFreeze = 4'd4, L1dUpdate = 4'd5, L1dUpdateWait = 4'd6,
      L1dProbeAbsorb = 4'd7, L1dProbeReply = 4'd8;
  localparam logic [3:0] L1dOpRead = 4'd0, L1dOpStore = 4'd1, L1dOpGrant = 4'd2,
      L1dOpProbe = 4'd3, L1dOpMaint = 4'd4, L1dOpAtomicWr = 4'd5, L1dOpSC = 4'd6,
      L1dOpPrefetch = 4'd7, L1dOpLookahead = 4'd8, L1dOpTwin = 4'd9;

  wire ep0_send_d = hart.gen_request[0].request.send_d_phase;
  wire ep0_wait_g = hart.gen_request[0].request.wait_g_phase;
  wire ep0_grant_ph = hart.gen_request[0].request.grant_phase;
  wire ep0_done_ph = hart.gen_request[0].request.done_phase;
  wire ep0_send_c = hart.gen_request[0].request.send_c_phase;
  wire ep0_wait_u = hart.gen_request[0].request.wait_u_phase;
  wire ep0_sc_wait_g = ep0_wait_g && hart.acquisition_q.opcode == coherence_pkg::StoreConditional;

  wire engine_sc_live = !engine_idle &&
      engine.request_q.opcode == coherence_pkg::StoreConditional &&
      !engine.failed_q && !engine.error_q;
  wire engine_sc_service = engine_sc_live &&
      (engine.phase_q == EngService || engine.phase_q == EngUpdate ||
       engine.phase_q == EngUpdateWait || engine.phase_q == EngResult);
  wire engine_sc_probing_read = engine_sc_live && engine.phase_q == EngService &&
      engine.probe_q.opcode == coherence_pkg::ProbeRead &&
      (engine.probe_phase_q == EngProbeOffer || engine.probe_phase_q == EngProbeWait);
  wire engine_sc_probe_wait_read = engine_sc_live && engine.phase_q == EngService &&
      engine.probe_q.opcode == coherence_pkg::ProbeRead &&
      engine.probe_phase_q == EngProbeWait;
  wire engine_sc_probe_ack = engine_sc_live && engine.phase_q == EngService &&
      engine.probe_phase_q == EngProbeAck;
  wire engine_sc_past_probe = engine_sc_live &&
      (engine.phase_q == EngUpdate || engine.phase_q == EngUpdateWait ||
       engine.phase_q == EngResult ||
       (engine.phase_q == EngService && engine.probe_phase_q == EngProbeDone &&
        engine.probe_q.opcode == coherence_pkg::ProbeRead));
  wire engine_sc_update_wait = engine_sc_live && engine.phase_q == EngUpdateWait;
  wire engine_sc_result = engine_sc_live && engine.phase_q == EngResult;
  wire result_is_sc_grantm = result_valid && !result_g.error &&
      result_g.opcode == coherence_pkg::GrantM && ep0_sc_live &&
      result_g.q == hart.acquisition_q.q &&
      result_g.addr == hart.acquisition_q.addr;
  wire comp_buf_is_sc_grantm = completions.buffer_ready_q[0] && !comp_buf_g.error &&
      comp_buf_g.opcode == coherence_pkg::GrantM && ep0_sc_live &&
      comp_buf_g.q == hart.acquisition_q.q &&
      comp_buf_g.addr == hart.acquisition_q.addr;
  wire home_g_is_sc_grantm = home_g_valid && !home_g.error &&
      home_g.opcode == coherence_pkg::GrantM && ep0_sc_live &&
      home_g.q == hart.acquisition_q.q &&
      home_g.addr == hart.acquisition_q.addr;

  // Inspect in-flight packets inside staged links for STAGES > 0.
  logic [1:0] wa_link_any, wa_link_ge1, wa_link_ge2;
  logic [1:0] wa_link_ord, wa_link_ord_ge1, wa_link_ord_ge2;
  logic [1:0] wa_link_abs, wa_link_abs_ge1, wa_link_abs_ge2;
  logic [1:0] r_link_abs;
  logic r_link_sc_reply_clean, r_link_sc_reply_abs;
  logic [1:0] r_link_sc_reply_abs_slot;
  logic [1:0] g_link_sc_grantm;
  logic g_link_sc_any;
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
    assign r_link_abs = 2'b00;
    assign r_link_sc_reply_clean = 1'b0;
    assign r_link_sc_reply_abs = 1'b0;
    assign r_link_sc_reply_abs_slot = 2'b00;
    assign g_link_sc_grantm = 2'b00;
    assign g_link_sc_any = 1'b0;
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
      r_link_abs = 2'b00;
      r_link_sc_reply_clean = 1'b0;
      r_link_sc_reply_abs = 1'b0;
      r_link_sc_reply_abs_slot = 2'b00;
      g_link_sc_grantm = 2'b00;
      g_link_sc_any = 1'b0;
      for (int s = 0; s < int'(LINK_STAGES); s++) begin
        coh_wa_t wa_s;
        coh_r_t  r_s;
        coh_g_t  g_s;
        wa_s = link_wa.gen_always.payload_q[s*(AddrWidth+11)+:(AddrWidth+11)];
        r_s  = link_r.gen_always.payload_q[s*(AddrWidth+275)+:(AddrWidth+275)];
        g_s  = link_g.gen_always.payload_q[s*(AddrWidth+275)+:(AddrWidth+275)];
        if (link_r.gen_always.valid_q[s] && !r_s.error &&
            engine_sc_probe_wait_read &&
            r_s.tid == engine_tid && r_s.addr == engine_addr &&
            (r_s.opcode == coherence_pkg::ProbeAck || r_s.opcode == coherence_pkg::ProbeData)) begin
          if (r_s.absorbed) begin
            r_link_sc_reply_abs = 1'b1;
            r_link_sc_reply_abs_slot[r_s.put_id] = 1'b1;
          end else begin
            r_link_sc_reply_clean = 1'b1;
          end
        end
        if (link_g.gen_always.valid_q[s] && !g_s.error &&
            g_s.opcode == coherence_pkg::GrantM &&
            ep0_sc_live && g_s.q == hart.acquisition_q.q &&
            g_s.addr == hart.acquisition_q.addr)
          g_link_sc_any = 1'b1;
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
      l1d_r_pkt.tid == engine_tid && l1d_r_pkt.addr == engine_addr &&
      (l1d_r_pkt.opcode == coherence_pkg::ProbeAck ||
       l1d_r_pkt.opcode == coherence_pkg::ProbeData);
  wire l1d_r_sc_abs = l1d_r_valid && !l1d_r_pkt.error && l1d_r_pkt.absorbed &&
      engine_sc_probe_wait_read &&
      l1d_r_pkt.tid == engine_tid && l1d_r_pkt.addr == engine_addr &&
      l1d_r_pkt.opcode == coherence_pkg::ProbeData;
  wire l1d_probe_reply_sc_clean = hart.phase_q == L1dProbeReply && !hart.reply_q.error &&
      !hart.reply_q.absorbed && engine_sc_probe_wait_read &&
      hart.probe_q.opcode == coherence_pkg::ProbeRead &&
      hart.reply_q.tid == engine_tid && hart.reply_q.addr == engine_addr;
  wire l1d_probe_reply_sc_abs = hart.phase_q == L1dProbeReply && !hart.reply_q.error &&
      hart.reply_q.absorbed && engine_sc_probe_wait_read &&
      hart.probe_q.opcode == coherence_pkg::ProbeRead &&
      hart.reply_q.tid == engine_tid && hart.reply_q.addr == engine_addr;

  wire sc_grant_pipeline = engine_sc_service || result_is_sc_grantm ||
      comp_buf_is_sc_grantm || home_g_is_sc_grantm || g_link_sc_any;

  // Helper invariants (all checked as assertions, zero assumptions).
  coh_d_t ep0_demand, comp_work[2];
  coh_g_t ep0_grant_pkt;
  coh_c_t ep0_comp_pkt;
  assign ep0_demand = hart.gen_request[0].request.demand_q;
  assign comp_work[0] = completions.work[0];
  assign comp_work[1] = completions.work[1];
  assign ep0_grant_pkt = hart.gen_request[0].request.grant_q;
  assign ep0_comp_pkt = hart.gen_request[0].request.completion_q;

  // L1D 1-way 2-set array tag and writeback disjointness invariants.
  localparam int unsigned ArrTagBits = AddrWidth - 6;
  localparam int unsigned ArrEntryBits = ArrTagBits + 3;
  logic inv_wb_tag_ok, inv_arr_ok, inv_freeze_ok, inv_grant_wb_ok;
  always_comb begin
    logic [ArrEntryBits-1:0] ent;
    logic is_mod;
    logic [AddrWidth-6:0] sec;
    inv_wb_tag_ok = 1'b1;
    inv_arr_ok = 1'b1;
    inv_freeze_ok = 1'b1;
    inv_grant_wb_ok = 1'b1;
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
          ent[ArrTagBits-1:0] != hart.update_addr_q[AddrWidth-1:6])
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
      end
    end
  end

  for (genvar slot = 0; slot < 2; slot++) begin : gen_inv
    always_ff @(posedge i_clk)
      if (!rst) begin
        p_inv_put_phase :
        assert (put_phase_q[slot] <= PutAck && put_busy_q[slot] == (put_phase_q[slot] != PutFree));
        if (put_busy_q[slot]) begin
          p_inv_put_meta :
          assert (put_q[slot].hart == 1'b0 &&
              put_q[slot].put_id == 1'(slot) &&
              put_q[slot].epoch == 1'b0 &&
              put_q[slot].addr[4:0] == 5'b0);
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
              (put_busy_q[slot] && put_q[slot].addr == hart.wb_addr[slot]) ||
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
              (!engine_idle && engine.phase_q == EngService &&
               engine.probe_phase_q == EngProbeAck &&
               engine.ack_q.absorbed && engine.ack_q.put_id == 1'(slot) &&
               engine.ack_q.addr == hart.wb_addr[slot]) ||
              wa_link_abs[slot]);
          if (!wa_link_abs[slot])
            p_inv_put_abs_comp :
            assert (
                hart.gen_put[slot].put.absorb_tid_q < 6'd2 &&
                completions.live[hart.gen_put[slot].put.absorb_tid_q[0]] &&
                !completions.release_valid[hart.gen_put[slot].put.absorb_tid_q[0]] &&
                completions.work_address[hart.gen_put[slot].put.absorb_tid_q[0]][AddrWidth-1:5] ==
                    hart.wb_addr[slot][AddrWidth-1:5]);
        end
        if (put_busy_q[slot])
          p_inv_put_busy :
          assert (hart.wb_live[slot] &&
              hart.wb_addr[slot] == put_q[slot].addr &&
              !wa_link_ord[slot] &&
              (hart.gen_put[slot].put.phase_q == PutAccepted ||
               (w_link_ret_any && hart.wb_selected_q && hart.wb_select_q == 1'(slot) &&
                hart.gen_put[slot].put.phase_q == PutPresent &&
                !hart.gen_put[slot].put.absorbed_q)));
        if (ack_arbiter.selected_q && ack_arbiter.selected_port_q == 2'(1 + slot))
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
        if (!engine_idle && engine.phase_q == EngService &&
            engine.probe_phase_q == EngProbeAck && engine.ack_q.put_id == 1'(slot))
          p_inv_eng_ack_slot :
          assert (hart.wb_live[slot] &&
              hart.gen_put[slot].put.phase_q == PutPresent &&
              hart.gen_put[slot].put.absorbed_q &&
              hart.wb_addr[slot] == engine.ack_q.addr &&
              hart.gen_put[slot].put.absorb_tid_q == engine.ack_q.tid &&
              !wa_link_abs[slot]);
        if (!engine_idle && engine.phase_q != EngLookup)
          p_inv_eng_no_put_busy :
          assert (!(put_busy_q[slot] &&
              put_q[slot].addr[AddrWidth-1:5] == engine_addr[AddrWidth-1:5]));
        if (engine_sc_live && engine.phase_q == EngService &&
            engine.probe_q.opcode == coherence_pkg::CheckSC &&
            hart.wb_live[slot] && hart.gen_put[slot].put.phase_q == PutAccepted &&
            hart.wb_addr[slot][AddrWidth-1:5] == engine_addr[AddrWidth-1:5])
          p_inv_sc_check_ord :
          assert (
              engine.probe_phase_q == EngProbeOffer &&
              (probe_arbiter.selected_q ? wa_link_ord_ge2[slot] : wa_link_ord_ge1[slot]));
        if (engine_sc_probing_read)
          p_inv_sc_probe_no_ord :
          assert (!(hart.wb_live[slot] &&
              hart.gen_put[slot].put.phase_q == PutAccepted &&
              hart.wb_addr[slot][AddrWidth-1:5] == engine_addr[AddrWidth-1:5]));
        if (hart.operation_q == L1dOpProbe &&
            (hart.phase_q == L1dLookup || hart.phase_q == L1dLookupWait ||
             hart.phase_q == L1dUpdate || hart.phase_q == L1dProbeAbsorb) &&
            hart.wb_live[slot] && hart.wb_addr[slot] == hart.probe_q.addr)
          p_inv_probe_wb_match : assert (hart.probe_absorbed_q && hart.probe_put_q == 1'(slot));
        if (l1d_probe_reply_sc_clean || l1d_r_sc_clean || r_link_sc_reply_clean)
          p_inv_sc_reply_clean_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == engine_addr[AddrWidth-1:5]));
        if (l1d_probe_reply_sc_abs && hart.reply_q.put_id != 1'(slot))
          p_inv_sc_reply_abs_other :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == engine_addr[AddrWidth-1:5]));
        if (l1d_r_sc_abs && l1d_r_pkt.put_id != 1'(slot))
          p_inv_sc_r_abs_other :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == engine_addr[AddrWidth-1:5]));
        if (r_link_sc_reply_abs && !r_link_sc_reply_abs_slot[slot])
          p_inv_sc_rlink_abs_other :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == engine_addr[AddrWidth-1:5]));
        if (engine_sc_probe_ack)
          p_inv_sc_probe_ack_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == engine_addr[AddrWidth-1:5] &&
              !(engine.ack_q.absorbed && engine.ack_q.put_id == 1'(slot) &&
                engine.dirty_q)));
        if (engine_sc_past_probe)
          p_inv_sc_past_probe_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == engine_addr[AddrWidth-1:5] &&
              !(engine.dirty_q && wa_link_abs[slot])));
        if (engine_sc_update_wait)
          p_inv_sc_upwait_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == engine_addr[AddrWidth-1:5] &&
              !wa_link_abs_ge1[slot]));
        if (engine_sc_result)
          p_inv_sc_result_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == engine_addr[AddrWidth-1:5] &&
              !wa_link_abs_ge2[slot]));
        if (result_is_sc_grantm)
          p_inv_result_sc_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == result_g.addr[AddrWidth-1:5]));
        if (comp_buf_is_sc_grantm)
          p_inv_buf_sc_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == comp_buf_g.addr[AddrWidth-1:5]));
        if (home_g_is_sc_grantm)
          p_inv_home_g_sc_wb :
          assert (!(hart.wb_live[slot] &&
              hart.wb_addr[slot][AddrWidth-1:5] == home_g.addr[AddrWidth-1:5]));
        if (g_link_sc_grantm[slot]) p_inv_link_g_sc_wb : assert (!hart.wb_live[slot]);

        // Completions per-slot invariants.
        p_inv_comp_pred :
        assert (
            completions.gen_endpoint[slot].endpoint.phase_q <= 3'd4 &&
            completions.gen_endpoint[slot].endpoint.phase_q != 3'd3 &&
            completions.gen_endpoint[slot].endpoint.pending_q == 4'b0 &&
            (!completions.handed_q[slot] ||
             (completions.live[slot] &&
              (!completions.work_valid[slot] || completions.result_valid_q[slot]) &&
              completions.work_identity[slot] == DmaKey)) &&
            !completions.predecessors_q[slot][slot] &&
            (completions.predecessors_q[slot] & ~completions.live) == 2'b00 &&
            completions.pred_clear_q[slot] == (completions.predecessors_q[slot] == 2'b00));
        if (completions.issued_q[slot] || (completions.live[slot] && !completions.work_valid[slot]))
          p_inv_comp_issued :
          assert (completions.live[slot] && completions.predecessors_q[slot] == 2'b00);
        if (completions.buffer_owned_q[slot])
          p_inv_comp_buf_own :
          assert (completions.issued_q[slot] && completions.work_valid[slot] &&
              completions.buffer_index_q[slot] == 1'b0 && completions.buffer_live_q[0]);
        if (completions.result_valid_q[slot])
          p_inv_comp_res_valid :
          assert (completions.buffer_owned_q[slot] &&
              completions.work_valid[slot] && !completions.error_q[slot] &&
              !comp_buf_g.error &&
              (comp_buf_g.opcode != coherence_pkg::GrantFail ||
               comp_work[slot].opcode == coherence_pkg::StoreConditional) &&
              (comp_work[slot].opcode != coherence_pkg::StoreConditional ||
               comp_buf_g.opcode == coherence_pkg::GrantM ||
               comp_buf_g.opcode == coherence_pkg::GrantFail) &&
              comp_buf_g.tid == 6'(slot) &&
              comp_buf_g.q == completions.work_identity[slot] &&
              comp_buf_g.addr == completions.work_address[slot] &&
              comp_buf_g.opcode <= coherence_pkg::GrantMZero);
        if (completions.pin_valid_q[slot])
          p_inv_comp_pin : assert (completions.issued_q[slot] && completions.live[slot]);
        if (put_selected_q && completions.live[slot] && !completions.release_valid[slot] &&
            completions.work_address[slot][AddrWidth-1:5] == selected_put_q.addr[AddrWidth-1:5])
          p_inv_comp_put_busy : assert (put_busy);
        if (completions.live[slot] && completions.work_identity[slot] == 9'b0)
          p_inv_comp_ep0 :
          assert (hart.live[0] && !completions.handed_q[slot] &&
              !d_link_ep0_any && !u_link_ep0_any &&
              completions.work[slot] == hart.acquisition_q &&
              (!completions.work_valid[slot] || (ep0_wait_g && !g_link_ep0_any)) &&
              (completions.gen_endpoint[slot].endpoint.phase_q != 3'd2 ||
               ((g_link_ep0_any && ep0_wait_g) ||
                ((ep0_grant_ph || ep0_done_ph || ep0_send_c) &&
                 ep0_grant_pkt.tid == 6'(slot)) ||
                (ep0_wait_u && c_link_ep0_any && ep0_grant_pkt.tid == 6'(slot)))) &&
              (!completions.release_valid[slot] ||
               (ep0_wait_u && !c_link_ep0_any && ep0_grant_pkt.tid == 6'(slot))));
        if (completions.live[slot] && completions.work_identity[slot] != 9'b0)
          p_inv_comp_dma :
          assert (completions.work_identity[slot] == DmaKey &&
              (comp_work[slot].opcode == coherence_pkg::DMARead ||
               comp_work[slot].opcode == coherence_pkg::DMAWrite) &&
              comp_work[slot].addr[4:0] == 5'b0);
      end
  end

  always_ff @(posedge i_clk) begin
    if (rst) snapshot_probe_seen_q <= 1'b0;
    else if (snapshot_probe_dirty) snapshot_probe_seen_q <= 1'b1;
    if (rst || !ep0_sc_live) begin
      sc_wa_ordinary_seen_q <= 1'b0;
      sc_wa_absorbed_seen_q <= 1'b0;
    end else begin
      if (wa_matches_sc && !l1d_wa_pkt.absorbed) sc_wa_ordinary_seen_q <= 1'b1;
      if (wa_matches_sc && l1d_wa_pkt.absorbed) sc_wa_absorbed_seen_q <= 1'b1;
    end
    if (!rst) begin
      // Core obligation from standalone coherence_l1d.sv (lines 5718-5721).
      if (sc_ep0_grantm) begin
        p_sc_grantm_no_wb0 : assert (!wb0_same_grant);
        p_sc_grantm_no_wb1 : assert (!wb1_same_grant);
      end
      p_inv_no_fatal : assert (!fatal && run && hart.active);
      p_inv_wb_distinct :
      assert (!(hart.wb_live[0] && hart.wb_live[1] &&
          hart.wb_addr[0][AddrWidth-1:5] == hart.wb_addr[1][AddrWidth-1:5]));
      p_inv_wb_tag_ok : assert (inv_wb_tag_ok);
      p_inv_arr_ok : assert (inv_arr_ok);
      p_inv_freeze_ok : assert (inv_freeze_ok);
      p_inv_grant_wb_ok : assert (inv_grant_wb_ok);
      if (ep0_send_d || ep0_wait_g || ep0_grant_ph) p_inv_ep0_not_done : assert (!hart.done_q);
      if (hart.live[0]) begin
        if (ep0_grant_ph || ep0_done_ph || ep0_send_c || ep0_wait_u)
          p_inv_ep0_grant_meta :
          assert (ep0_grant_pkt.addr == hart.acquisition_q.addr &&
              !ep0_grant_pkt.error &&
              (ep0_grant_pkt.opcode != coherence_pkg::GrantFail ||
               hart.acquisition_q.opcode == coherence_pkg::StoreConditional) &&
              (!hart.acquisition_sc_q ||
               ep0_grant_pkt.opcode == coherence_pkg::GrantM ||
               ep0_grant_pkt.opcode == coherence_pkg::GrantFail));
        if (ep0_grant_ph || ep0_done_ph || ep0_send_c)
          p_inv_ep0_has_comp :
          assert (
              (completions.live[0] && completions.work_identity[0] == 9'b0 &&
               !completions.work_valid[0] && !completions.release_valid[0] &&
               !completions.handed_q[0] &&
               completions.work_address[0] == hart.acquisition_q.addr) ||
              (completions.live[1] && completions.work_identity[1] == 9'b0 &&
               !completions.work_valid[1] && !completions.release_valid[1] &&
               !completions.handed_q[1] &&
               completions.work_address[1] == hart.acquisition_q.addr));
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
            hart.wb_reserved_q && ep0_done_ph && !hart.done_q &&
            !hart.grant_q.error && hart.grant_q.opcode != coherence_pkg::GrantFail &&
            (!hart.acquisition_sc_q || hart.grant_q.opcode == coherence_pkg::GrantM) &&
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
      // Arbiter consistency.
      p_inv_arb_ack :
      assert (ack_arbiter.selected_port_q < 2'd3 &&
          ack_arbiter.selected_ports_q ==
              (ack_arbiter.selected_q ? (3'b001 << ack_arbiter.selected_port_q) : 3'b000) &&
          (!ack_arbiter.selected_q ||
           (ack_valid[ack_arbiter.selected_port_q] &&
            ack_out == ack_payload[ack_arbiter.selected_port_q])));
      p_inv_arb_probe :
      assert (
          probe_arbiter.selected_ports_q == (probe_arbiter.selected_q ? 1'b1 : 1'b0) &&
          (!probe_arbiter.selected_q || (engine_p_valid && probe_out == engine_p)));
      p_inv_arb_result :
      assert (
          result_arbiter.selected_ports_q == (result_arbiter.selected_q ? 1'b1 : 1'b0) &&
          (!result_arbiter.selected_q ||
           (engine_result_valid && result_payload == engine_result_payload)));
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
          completions.release_arbiter.selected_ports_q ==
              (completions.release_arbiter.selected_q ?
               (2'b01 << completions.release_arbiter.selected_port_q) : 2'b00) &&
          (!completions.release_arbiter.selected_q ||
           (completions.release_valid[completions.release_arbiter.selected_port_q] &&
            home_u == completions.releases[completions.release_arbiter.selected_port_q])));

      // Completions global invariants.
      p_inv_comp_global :
      assert (
          !completions.buffer_live_q[1] && !completions.buffer_ready_q[1] &&
          completions.parked_q == 2'b00 && completions.ready_q == 2'b00 &&
          completions.wake_error_q == 2'b00 && completions.error_q == 2'b00 &&
          completions.work_parked_q == 1'b0 && completions.work_buffer_q == 1'b0 &&
          completions.work_selected_slots_q ==
              (completions.work_selected_q ? (2'b01 << completions.work_slot_q) : 2'b00) &&
          !(completions.buffer_owned_q[0] && completions.buffer_owned_q[1]) &&
          completions.buffer_live_q[0] == (|completions.buffer_owned_q) &&
          completions.buffer_ready_q[0] == (|completions.result_valid_q) &&
          (!(completions.live[0] && completions.live[1]) ||
           completions.work_identity[0] != completions.work_identity[1]));
      if (completions.work_selected_q)
        p_inv_comp_work_sel :
        assert (completions.work_valid[completions.work_slot_q] &&
            !completions.issued_q[completions.work_slot_q] &&
            !completions.buffer_owned_q[completions.work_slot_q] &&
            !completions.pin_valid_q[completions.work_slot_q] &&
            completions.predecessors_q[completions.work_slot_q] == 2'b00 &&
            !completions.buffer_live_q[0]);
      if (completions.grant_selected_q)
        p_inv_comp_grant_sel :
        assert (completions.grant_buffer_q == 1'b0 &&
            completions.result_valid_q[completions.grant_slot_q] &&
            completions.buffer_owned_q[completions.grant_slot_q] &&
            home_g.q == completions.work_identity[completions.grant_slot_q] &&
            home_g.tid == 6'(completions.grant_slot_q) &&
            home_g.addr == completions.work_address[completions.grant_slot_q] &&
            !home_g.error &&
            (home_g.opcode != coherence_pkg::GrantFail ||
             comp_work[completions.grant_slot_q].opcode == coherence_pkg::StoreConditional) &&
            (comp_work[completions.grant_slot_q].opcode != coherence_pkg::StoreConditional ||
             home_g.opcode == coherence_pkg::GrantM ||
             home_g.opcode == coherence_pkg::GrantFail) &&
            home_g.opcode <= coherence_pkg::GrantMZero);

      // Engine local invariants.
      p_inv_eng_global :
      assert (engine.phase_q <= EngResult &&
          engine.probe_phase_q <= EngProbeAck && !engine.error_q &&
          (!engine.read_done_q || engine.read_sent_q) &&
          (!engine_idle || engine.probe_phase_q == EngProbeDone) &&
          tag_pending_q == (engine.phase_q == EngLookup && engine.lookup_sent_q) &&
          update_pending_q == (engine.phase_q == EngUpdateWait) &&
          read_pending_q == (engine.phase_q == EngService &&
                             engine.read_sent_q && !engine.read_done_q));
      if (engine.quick_q && engine.phase_q == EngService)
        p_inv_eng_quick :
        assert (!engine.needs_probe && engine.needs_data &&
            engine.probe_phase_q == EngProbeDone && !engine.dirty_q && !engine.error_q);
      if (hart.probe_valid_q)
        p_inv_probe_q_meta :
        assert (hart.probe_q.epoch == 1'b0 &&
            hart.probe_q.addr[4:0] == 5'b0 &&
            engine.phase_q == EngService && engine.probe_phase_q == EngProbeWait &&
            hart.probe_q == engine.probe_q);
      if (l1d_p_valid)
        p_inv_l1d_p_eng :
        assert (engine.phase_q == EngService &&
            engine.probe_phase_q == (LINK_STAGES == 0 ? EngProbeOffer : EngProbeWait) &&
            l1d_p == engine.probe_q);
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
            l1d_r_pkt.hart == 1'b0 && l1d_r_pkt.epoch == 1'b0 &&
            l1d_r_pkt.put_epoch == 1'b0 &&
            engine.phase_q == EngService && engine.probe_phase_q == EngProbeWait &&
            l1d_r_pkt.tid == engine_tid && l1d_r_pkt.addr == engine_addr &&
            (engine.probe_q.opcode == coherence_pkg::CheckSC ?
             (l1d_r_pkt.opcode == coherence_pkg::CheckAck &&
              !l1d_r_pkt.data_valid && !l1d_r_pkt.absorbed) :
             (l1d_r_pkt.opcode == coherence_pkg::ProbeAck ||
              l1d_r_pkt.opcode == coherence_pkg::ProbeData)) &&
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
      if (!engine_idle) begin
        p_inv_engine_comp :
        assert (engine_tid < 6'd2 &&
            completions.live[engine_tid[0]] &&
            completions.issued_q[engine_tid[0]] &&
            completions.buffer_owned_q[engine_tid[0]] &&
            !completions.result_valid_q[engine_tid[0]] &&
            completions.work_valid[engine_tid[0]] &&
            !completions.release_valid[engine_tid[0]] &&
            completions.work_address[engine_tid[0]] == engine_addr &&
            completions.work_identity[engine_tid[0]] == engine.request_q.q &&
            completions.work[engine_tid[0]] == engine.request_q);
        if (engine.phase_q == EngLookup)
          p_inv_eng_lookup :
          assert (!completions.pin_valid_q[engine_tid[0]] &&
              !engine.read_sent_q && !engine.read_done_q &&
              !engine.dirty_q && !engine.failed_q && !engine.quick_q &&
              engine.probe_phase_q == EngProbeDone);
          else
            p_inv_eng_pinned :
            assert (completions.pin_valid_q[engine_tid[0]] &&
              engine.probe_q.addr == engine_addr && engine.probe_q.tid == engine_tid &&
              engine.probe_q.epoch == 1'b0 && engine_addr[4:0] == 5'b0 &&
              (!engine.failed_q || engine.probe_phase_q == EngProbeDone) &&
              (!engine_sc_live ||
               (engine.probe_q.opcode == coherence_pkg::ProbeRead ||
                (engine.phase_q == EngService &&
                 (engine.probe_phase_q == EngProbeOffer ||
                  engine.probe_phase_q == EngProbeWait) &&
                 engine.probe_q.opcode == coherence_pkg::CheckSC))));
        if (engine.phase_q == EngUpdate || engine.phase_q == EngUpdateWait ||
            engine.phase_q == EngResult)
          p_inv_eng_post_svc : assert (engine.probe_phase_q == EngProbeDone);
        if (engine.phase_q == EngService && engine.probe_phase_q == EngProbeAck)
          p_inv_eng_ack :
          assert (engine.dirty_q && engine.ack_q.absorbed &&
              !engine.ack_q.error &&
              engine.ack_q.addr == engine_addr && engine.ack_q.tid == engine_tid &&
              engine.ack_q.hart == 1'b0 && engine.ack_q.epoch == 1'b0);
      end
      if (l1d_wa_valid) p_inv_wa_no_err : assert (!l1d_wa_pkt.error);
      if (ep0_send_d)
        p_inv_ep0_send_d_clean :
        assert (!d_link_ep0_any && !g_link_ep0_any &&
            !c_link_ep0_any && !u_link_ep0_any &&
            !(completions.live[0] && completions.work_identity[0] == 9'b0) &&
            !(completions.live[1] && completions.work_identity[1] == 9'b0));
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
              (completions.live[0] && completions.work_identity[0] == 9'b0 &&
               !completions.work_valid[0] && !completions.release_valid[0] &&
               !completions.handed_q[0] &&
               completions.work_address[0][AddrWidth-1:5] == hart.atomic_addr_q[AddrWidth-1:5]) ||
              (completions.live[1] && completions.work_identity[1] == 9'b0 &&
               !completions.work_valid[1] && !completions.release_valid[1] &&
               !completions.handed_q[1] &&
               completions.work_address[1][AddrWidth-1:5] == hart.atomic_addr_q[AddrWidth-1:5]));
            p_inv_remote_sc_no_probe :
            assert (
              (engine_idle || engine_addr[AddrWidth-1:5] != hart.atomic_addr_q[AddrWidth-1:5]) &&
              (!hart.probe_valid_q ||
               hart.probe_q.addr[AddrWidth-1:5] != hart.atomic_addr_q[AddrWidth-1:5]));
          end
      end
      if (completions.live[0] && completions.live[1] &&
          completions.work_address[0][AddrWidth-1:5] == completions.work_address[1][AddrWidth-1:5])
        p_inv_comp_same_sec_ord :
        assert (
            completions.handed_q[0] || completions.handed_q[1] ||
            completions.predecessors_q[0][1] || completions.predecessors_q[1][0]);

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
      if (dma_phase_q == DmaSendC) p_inv_dma_c : assert (dma_c_q.q == DmaKey);
      if (engine_sc_live) begin
        p_inv_engine_sc_ep0 :
        assert (ep0_sc_wait_g &&
            engine.request_q.q == hart.acquisition_q.q &&
            engine_addr == hart.acquisition_q.addr);
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

      // All reset_q registers mirror i_rst delayed by 1 cycle, so they match
      // and hold only while the composed machine is still in its reset state.
      if (gen_ep_links[0].link_d.gen_credit.reset_q !=
          gen_ep_links[0].link_c.gen_credit.reset_q ||
          gen_ep_links[0].link_d.gen_credit.reset_q !=
          link_p.gen_credit_one.reset_q)
        inv_link_rst_ok = 1'b0;
      if (gen_ep_links[0].link_d.gen_credit.reset_q) begin
        if (hart.live[0] || (|hart.wb_live) || hart.probe_valid_q ||
            !engine_idle || (|completions.live) || (|put_busy_q) || put_selected_q ||
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
              !(completions.live[0] && completions.work_identity[0] == 9'b0) &&
              !(completions.live[1] && completions.work_identity[1] == 9'b0)))
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
              completions.live[ep0_grant_pkt.tid[0]] &&
              completions.work_identity[ep0_grant_pkt.tid[0]] == 9'b0 &&
              !completions.work_valid[ep0_grant_pkt.tid[0]] &&
              !completions.release_valid[ep0_grant_pkt.tid[0]] &&
              !completions.handed_q[ep0_grant_pkt.tid[0]]))
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
                (hart.acquisition_q.opcode != coherence_pkg::StoreConditional ||
                 g_s.opcode == coherence_pkg::GrantM ||
                 g_s.opcode == coherence_pkg::GrantFail) &&
                completions.live[g_s.tid[0]] &&
                completions.work_identity[g_s.tid[0]] == 9'b0 &&
                !completions.work_valid[g_s.tid[0]] &&
                !completions.release_valid[g_s.tid[0]] &&
                !completions.handed_q[g_s.tid[0]] &&
                completions.work_address[g_s.tid[0]] == hart.acquisition_q.addr))
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
                !(completions.live[0] && completions.work_identity[0] == 9'b0) &&
                !(completions.live[1] && completions.work_identity[1] == 9'b0)))
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
      if (int'(p_link_any) + int'(hart.probe_valid_q) + $countones(link_r.gen_always.valid_q) > 1)
        inv_link_p_ok = 1'b0;
      for (int s = 0; s < int'(LINK_STAGES); s++) begin
        coh_p_t p_s;
        coh_r_t r_s;
        p_s = link_p.gen_credit_one.payload_q[s*(AddrWidth+30)+:(AddrWidth+30)];
        r_s = link_r.gen_always.payload_q[s*(AddrWidth+275)+:(AddrWidth+275)];
        if (link_p.gen_credit_one.valid_q[s]) begin
          if (!(engine.phase_q == EngService &&
                engine.probe_phase_q == EngProbeWait &&
                p_s == engine.probe_q))
            inv_link_p_ok = 1'b0;
        end
        if (link_r.gen_always.valid_q[s]) begin
          if (!(!r_s.error && r_s.hart == 1'b0 && r_s.epoch == 1'b0 &&
                r_s.put_epoch == 1'b0 &&
                engine.phase_q == EngService && engine.probe_phase_q == EngProbeWait &&
                r_s.tid == engine_tid && r_s.addr == engine_addr &&
                (engine.probe_q.opcode == coherence_pkg::CheckSC ?
                 (r_s.opcode == coherence_pkg::CheckAck &&
                  !r_s.data_valid && !r_s.absorbed) :
                 (r_s.opcode == coherence_pkg::ProbeAck ||
                  r_s.opcode == coherence_pkg::ProbeData))))
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
            if (put_busy_q[wa_s.put_id] ||
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
              put_busy_q[hart.wb_select_q] &&
              put_q[hart.wb_select_q].addr == hart.wb_addr[hart.wb_select_q] &&
              !wa_link_ord[hart.wb_select_q] && !put_selected_q &&
              (hart.wb_select_q ?
               (hart.gen_put[1].put.phase_q == PutPresent && !hart.gen_put[1].put.absorbed_q) :
               (hart.gen_put[0].put.phase_q == PutPresent && !hart.gen_put[0].put.absorbed_q))))
          inv_link_w_ok = 1'b0;
        if (link_w.gen_mirror.return_q[0] && put_phase_q[hart.wb_select_q] != PutWork)
          inv_link_w_ok = 1'b0;
        if (LINK_STAGES >= 2 && link_w.gen_mirror.return_q[LINK_STAGES >= 2 ? 1 : 0] &&
            ack_arbiter.selected_q &&
            ack_arbiter.selected_port_q == 2'(1 + hart.wb_select_q))
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
                (engine.phase_q == EngService && engine.probe_phase_q == EngProbeAck &&
                 engine.ack_q.put_id == w_s.put_id) ||
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
