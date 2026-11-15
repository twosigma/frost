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

// Multiclock formal harness for dc_fifo coupled to cdc_reset_pair.
// In safety tasks (COVER_MODE=0), i_clk and o_clk are genuinely free on gclk
// (arbitrary phase, arbitrary ratio including SoC 4:1 and 1:4, and stopped
// clocks during reset), and i_arst may re-assert at runtime after traffic with
// staggered release across domains. Checks total and RAM occupancy bounds,
// conservative o_ready / o_almost_full / o_empty status flags, output valid/data
// stability under backpressure, and all-word FIFO ordering and payload integrity
// across unbounded RAM-entry reuse.
module dc_fifo_formal #(
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned DEPTH = 4,
    parameter int unsigned ALMOST_FULL_MARGIN = 1,
    parameter bit COVER_MODE = 1'b0
) (
    (* gclk *) input logic gclk,
    input logic i_arst,
    input logic i_free_wclk,
    input logic i_free_rclk,
    input logic i_sample_push,
    input logic i_use_div_clks,
    input logic [2:0] i_clk_ratio,
    input logic [2:0] i_init_phase,
    input logic [DATA_WIDTH-1:0] i_data,
    input logic i_valid,
    input logic i_ready
);

  localparam int unsigned AddrBits  = $clog2(DEPTH);
  localparam int unsigned PtrBits   = AddrBits + 1;
  localparam int unsigned CountBits = AddrBits + 2;

  // In COVER_MODE, optionally drive divided clocks from an arbitrary symbolic
  // initial phase to witness RAM-entry reuse at each exact ratio (1:1, 2:1,
  // 1:2, 4:1, 1:4) as well as free-clock staggered/post-traffic reset covers.
  wire f_use_div_clks = i_use_div_clks;
  wire [2:0] f_clk_ratio = i_clk_ratio;
  wire [2:0] f_init_phase = i_init_phase;

  logic f_init_done = 1'b0;
  logic [2:0] div_phase = '0;
  logic use_div_clks_q = 1'b0;
  logic [2:0] clk_ratio_q = '0;
  logic [2:0] init_phase_q = '0;

  always_ff @(posedge gclk) begin
    f_init_done    <= 1'b1;
    use_div_clks_q <= i_use_div_clks;
    clk_ratio_q    <= i_clk_ratio;
    init_phase_q   <= i_init_phase;
    if (!f_init_done) begin
      div_phase <= f_init_phase + 3'd1;
    end else begin
      div_phase <= div_phase + 3'd1;
    end
  end

  wire [2:0] cur_phase = f_init_done ? div_phase : f_init_phase;
  wire clk_div1 = ~cur_phase[0];
  wire clk_div2 = ~cur_phase[1];
  wire clk_div4 = ~cur_phase[2];

  logic div_i_clk;
  logic div_o_clk;
  always_comb begin
    unique case (f_clk_ratio)
      3'd0: begin
        div_i_clk = clk_div1;
        div_o_clk = clk_div1;
      end
      3'd1: begin
        div_i_clk = clk_div1;
        div_o_clk = clk_div2;
      end
      3'd2: begin
        div_i_clk = clk_div2;
        div_o_clk = clk_div1;
      end
      3'd3: begin
        div_i_clk = clk_div1;
        div_o_clk = clk_div4;
      end
      default: begin
        div_i_clk = clk_div4;
        div_o_clk = clk_div1;
      end
    endcase
  end

  wire use_div = COVER_MODE && f_use_div_clks;
  wire i_clk = use_div ? div_i_clk : i_free_wclk;
  wire o_clk = use_div ? div_o_clk : i_free_rclk;

  // Single assumption in safety tasks: assert asynchronous reset on tick 0.
  // Clocks, data/handshake inputs, and runtime reset re-assertions after tick 0
  // are completely unconstrained.
  always_comb begin
    if (!f_init_done) assume (i_arst);
    if (COVER_MODE) begin
      assume (f_clk_ratio <= 3'd4);
      if (f_init_done) begin
        assume (i_use_div_clks == use_div_clks_q);
        assume (i_clk_ratio == clk_ratio_q);
        assume (i_init_phase == init_phase_q);
        if (use_div) assume (!i_arst && i_valid && i_ready);
      end
    end
  end

  logic i_rst;
  logic o_rst;
  cdc_reset_pair u_reset_pair (
      .i_arst (i_arst),
      .i_a_clk(i_clk),
      .i_b_clk(o_clk),
      .o_a_rst(i_rst),
      .o_b_rst(o_rst)
  );

  logic                  o_ready;
  logic                  o_almost_full;
  logic                  o_empty;
  logic [DATA_WIDTH-1:0] o_data;
  logic                  o_valid;

  dc_fifo #(
      .DATA_WIDTH        (DATA_WIDTH),
      .DEPTH             (DEPTH),
      .ALMOST_FULL_MARGIN(ALMOST_FULL_MARGIN)
  ) dut (
      .i_clk        (i_clk),
      .i_rst        (i_rst),
      .i_data       (i_data),
      .i_valid      (i_valid),
      .o_ready      (o_ready),
      .o_almost_full(o_almost_full),
      .o_empty      (o_empty),
      .o_clk        (o_clk),
      .o_rst        (o_rst),
      .o_data       (o_data),
      .o_valid      (o_valid),
      .i_ready      (i_ready)
  );

  // Modulo-2*DEPTH push/pop pointers plus an unconstrained re-arming watched
  // transaction (Wolper reduction). Because i_sample_push is free and inflight
  // <= DEPTH < 2*DEPTH, watching any chosen push verifies FIFO ordering and all
  // DATA_WIDTH payload bits for every push across unbounded RAM-entry reuse.
  logic [PtrBits-1:0] f_wr_ptr = '0;
  logic [PtrBits-1:0] f_rd_ptr = '0;
  logic f_watch_gen = 1'b0;
  logic f_watch_ack = 1'b0;
  logic [PtrBits-1:0] f_watch_slot = '0;
  logic [DATA_WIDTH-1:0] f_watch_data = '0;
  logic [CountBits-1:0] f_sat_pushes = '0;
  logic [CountBits-1:0] f_sat_pops = '0;

  wire f_watching = (f_watch_gen != f_watch_ack);

  // Whenever either domain has released reset, cdc_reset_pair guarantees both
  // domains have already clocked their synchronous resets at least twice.
  wire domain_active = f_init_done && (!i_rst || !o_rst);

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      f_wr_ptr     <= '0;
      f_watch_gen  <= 1'b0;
      f_watch_slot <= '0;
      f_watch_data <= '0;
      f_sat_pushes <= '0;
    end else if (i_valid && o_ready) begin
      f_wr_ptr <= f_wr_ptr + PtrBits'(1);
      if (!COVER_MODE && !f_watching && i_sample_push) begin
        f_watch_gen  <= ~f_watch_gen;
        f_watch_slot <= f_wr_ptr;
        f_watch_data <= i_data;
      end
      if (COVER_MODE && (f_sat_pushes != {CountBits{1'b1}})) begin
        f_sat_pushes <= f_sat_pushes + CountBits'(1);
      end
    end
  end

  always_ff @(posedge o_clk) begin
    if (o_rst) begin
      f_rd_ptr    <= '0;
      f_watch_ack <= 1'b0;
      f_sat_pops  <= '0;
    end else if (o_valid && i_ready) begin
      f_rd_ptr <= f_rd_ptr + PtrBits'(1);
      if (COVER_MODE && (f_sat_pops != {CountBits{1'b1}})) begin
        f_sat_pops <= f_sat_pops + CountBits'(1);
      end
      if (!COVER_MODE && f_watching && (f_rd_ptr == f_watch_slot)) begin
        f_watch_ack <= f_watch_gen;
      end
    end
  end

  logic                  prev_o_clk = 1'b0;
  logic                  prev_o_rst = 1'b1;
  logic                  prev_o_valid = 1'b0;
  logic                  prev_i_ready = 1'b0;
  logic [DATA_WIDTH-1:0] prev_o_data = '0;
  logic                  prev_watching = 1'b0;
  logic                  prev_match_head = 1'b0;
  logic [DATA_WIDTH-1:0] prev_watch_data = '0;

  wire                   o_clk_rose = !prev_o_clk && o_clk;

  logic                  saw_pre_rst_pop = 1'b0;
  logic                  saw_post_traffic_rst = 1'b0;

  always_ff @(posedge gclk) begin
    if (!COVER_MODE) begin
      prev_o_clk      <= o_clk;
      prev_o_rst      <= o_rst;
      prev_o_valid    <= o_valid;
      prev_i_ready    <= i_ready;
      prev_o_data     <= o_data;
      prev_watching   <= f_watching;
      prev_match_head <= (f_rd_ptr == f_watch_slot);
      prev_watch_data <= f_watch_data;
    end

    if (COVER_MODE && f_init_done) begin
      if (!i_rst && !o_rst && (f_sat_pops != '0)) begin
        saw_pre_rst_pop <= 1'b1;
      end
      if (saw_pre_rst_pop && i_arst) begin
        saw_post_traffic_rst <= 1'b1;
      end
    end
  end

  wire [PtrBits-1:0] f_inflight = f_wr_ptr - f_rd_ptr;
  wire [PtrBits-1:0] true_ram_occ = f_inflight - PtrBits'(o_valid);

  generate
    if (!COVER_MODE) begin : g_safety
      always_comb begin
        if (f_init_done && i_arst) begin
          // Asynchronous reset request immediately asserts both domain resets.
          p_reset_pair_async_assert : assert (i_rst && o_rst);
        end

        if (domain_active) begin
          // Total unconsumed words (RAM plus output register) never exceed DEPTH,
          // and pops never lead pushes.
          p_inflight_bounded : assert (f_inflight <= PtrBits'(DEPTH));

          // True RAM occupancy never exceeds DEPTH - 1; when o_valid is high, at
          // least one unconsumed word is in flight and o_data holds the head entry.
          if (o_valid) begin
            p_valid_implies_inflight : assert (f_inflight != '0);
            if (f_watching && (f_rd_ptr == f_watch_slot)) begin
              p_valid_head_data_exact : assert (o_data == f_watch_data);
            end
          end
          p_ram_occ_bounded : assert (true_ram_occ <= PtrBits'(DEPTH - 1));

          // o_ready is asserted only when at least one of the DEPTH - 1 RAM slots is free.
          p_ready_conservative : assert (!o_ready || (true_ram_occ < PtrBits'(DEPTH - 1)));

          // o_almost_full is asserted whenever true RAM occupancy reaches DEPTH - ALMOST_FULL_MARGIN.
          p_almost_full_conservative :
          assert ((true_ram_occ < PtrBits'(DEPTH - ALMOST_FULL_MARGIN)) || o_almost_full);

          // o_empty is asserted only when every written word has already left the RAM.
          p_empty_conservative : assert (!o_empty || (true_ram_occ == '0));
        end

        if (f_init_done && !prev_o_rst && !o_rst) begin
          // Once o_valid is raised out of reset, o_valid and o_data hold until a
          // read-clock edge with i_ready.
          if (prev_o_valid && !(o_clk_rose && prev_i_ready)) begin
            p_out_hold_until_ready : assert (o_valid && (o_data == prev_o_data));
          end

          // Every popped word consumed on a ready read-clock edge emerges in exact
          // FIFO order with its intact payload.
          if (o_clk_rose && prev_o_valid && prev_i_ready && prev_watching && prev_match_head) begin
            p_fifo_order_and_data : assert (prev_o_data == prev_watch_data);
          end
        end
      end
    end
  endgenerate

  generate
    if (!COVER_MODE) begin : g_invariants
      wire [PtrBits-1:0] inv_w0 = dut.write_pointer_in_input_domain;
      wire [PtrBits-1:0] inv_w1 = dut.write_pointer_synchronized_stage1;
      wire [PtrBits-1:0] inv_w2 = dut.write_pointer_synchronized_stage2;
      wire [PtrBits-1:0] inv_r0 = dut.read_pointer_in_output_domain;
      wire [PtrBits-1:0] inv_r1 = dut.read_pointer_synchronized_stage1;
      wire [PtrBits-1:0] inv_r2 = dut.read_pointer_synchronized_stage2;
      wire [PtrBits-1:0] age_w1 = inv_w0 - inv_w1;
      wire [PtrBits-1:0] age_w2 = inv_w0 - inv_w2;
      wire [PtrBits-1:0] age_r0 = inv_w0 - inv_r0;
      wire [PtrBits-1:0] age_r1 = inv_w0 - inv_r1;
      wire [PtrBits-1:0] age_r2 = inv_w0 - inv_r2;
      wire [PtrBits-1:0] age_rd = inv_w0 - f_rd_ptr;
      wire [PtrBits-1:0] age_ws = inv_w0 - f_watch_slot;

      always_comb begin
        if (f_init_done) begin
          p_inv_rst_a_shift :
          assert (!u_reset_pair.reset_a.chain_q[0] || u_reset_pair.reset_a.chain_q[1]);
          p_inv_rst_b_shift :
          assert (!u_reset_pair.reset_b.chain_q[0] || u_reset_pair.reset_b.chain_q[1]);
          p_inv_peer_a_shift :
          assert (!u_reset_pair.peer_a.chain_q[0] || u_reset_pair.peer_a.chain_q[1]);
          p_inv_peer_b_shift :
          assert (!u_reset_pair.peer_b.chain_q[0] || u_reset_pair.peer_b.chain_q[1]);

          if (i_arst) begin
            p_inv_arst_chains :
            assert ((u_reset_pair.reset_a.chain_q == 2'b11) &&
                    (u_reset_pair.reset_b.chain_q == 2'b11));
          end
          if (u_reset_pair.a_reset) begin
            p_inv_a_holds_peer_a : assert (u_reset_pair.peer_a.chain_q == 2'b11);
          end
          if (u_reset_pair.b_reset) begin
            p_inv_b_holds_peer_b : assert (u_reset_pair.peer_b.chain_q == 2'b11);
          end

          if (!u_reset_pair.reset_a.chain_q[0] && i_rst) begin
            p_inv_w_domain_cleared :
            assert ((inv_w0 == '0) && (inv_r1 == '0) && (inv_r2 == '0) &&
                    (f_wr_ptr == '0) && !f_watch_gen);
          end
          if (!u_reset_pair.reset_b.chain_q[0] && o_rst) begin
            p_inv_r_domain_cleared :
            assert ((inv_r0 == '0) && !o_valid && !dut.read_data_fresh &&
                    (inv_w1 == '0) && (inv_w2 == '0) && (f_rd_ptr == '0) && !f_watch_ack);
          end

          if (domain_active) begin
            if (i_rst) begin
              p_inv_w_rst_holds_r_idle :
              assert ((inv_r0 == '0) && !o_valid && (inv_w1 == '0) && (inv_w2 == '0) &&
                      (f_rd_ptr == '0) && !f_watch_ack);
            end
            p_inv_wr_ptr_eq : assert (inv_w0 == f_wr_ptr);
            p_inv_rd_ptr_eq : assert (inv_r0 == (f_rd_ptr + PtrBits'(o_valid)));
            p_inv_ptr_chain :
            assert ((age_w1 <= age_w2) && (age_w2 <= age_r0) &&
                    (age_r0 <= age_r1) && (age_r1 <= age_r2) &&
                    (age_r2 <= PtrBits'(DEPTH - 1)));
            p_inv_rd_age_eq : assert (age_rd == (age_r0 + PtrBits'(o_valid)));

            if (f_watching) begin
              p_inv_watch_in_range : assert ((age_ws != '0) && (age_ws <= age_rd));
              if (age_ws > age_r0) begin
                p_inv_watch_in_outreg :
                assert (o_valid && (f_watch_slot == f_rd_ptr) && (o_data == f_watch_data));
              end else begin
                p_inv_watch_in_ram :
                assert (dut.synchronous_dual_clock_fifo_storage.ram[f_watch_slot[AddrBits-1:0]] ==
                        f_watch_data);
                if ((age_ws == age_r0) && dut.read_data_fresh && (inv_r0 != inv_w2)) begin
                  p_inv_watch_in_ram_out :
                  assert (dut.synchronous_dual_clock_fifo_storage.o_read_data == f_watch_data);
                end
              end
            end
          end
        end
      end
    end
  endgenerate

  generate
    if (COVER_MODE) begin : g_covers
      always_comb begin
        if (f_init_done) begin
          // Reach full FIFO capacity (DEPTH - 1 in RAM plus 1 in output register).
          c_full_capacity : cover (!i_rst && !o_rst && (f_inflight == PtrBits'(DEPTH)) && !o_ready);

          // Reach the 1-cycle BRAM reload bubble when consumer takes while RAM is non-empty.
          c_reload_bubble : cover (!i_rst && !o_rst && !o_valid && (true_ram_occ != '0));

          // Reach RAM-entry reuse (>= DEPTH + 1 pushes and pops) across 1:1, 2:1, 1:2,
          // 4:1, and 1:4 divided-clock ratios (excluding phase 7 on the asymmetric ratios).
          c_ram_reuse_1to1 :
          cover (use_div && (f_clk_ratio == 3'd0) && (f_sat_pops >= CountBits'(DEPTH + 1)));
          c_ram_reuse_2to1 :
          cover (use_div && (f_clk_ratio == 3'd1) && (f_init_phase != 3'd7) &&
                 (f_sat_pops >= CountBits'(DEPTH + 1)));
          c_ram_reuse_1to2 :
          cover (use_div && (f_clk_ratio == 3'd2) && (f_init_phase != 3'd7) &&
                 (f_sat_pops >= CountBits'(DEPTH + 1)));
          c_ram_reuse_4to1 :
          cover (use_div && (f_clk_ratio == 3'd3) && (f_init_phase != 3'd7) &&
                 (f_sat_pops >= CountBits'(DEPTH + 1)));
          c_ram_reuse_1to4 :
          cover (use_div && (f_clk_ratio == 3'd4) && (f_init_phase != 3'd7) &&
                 (f_sat_pops >= CountBits'(DEPTH + 1)));

          // Reach staggered reset release where writer pushes while reader reset is still held.
          c_staggered_reset_release : cover (!use_div && !i_rst && o_rst && (f_sat_pushes != '0));

          // Reach runtime reset re-assertion after traffic followed by fresh post-reset delivery.
          c_post_traffic_reset_recovery :
          cover (!use_div && saw_post_traffic_rst && !i_rst && !o_rst && (f_sat_pops != '0));
        end
      end
    end
  endgenerate

endmodule
