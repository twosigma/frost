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

// Formal harness for nic_irq.
// Proves sticky W1C status with set-over-clear priority, atomic IRQ_MASK_SET
// and IRQ_MASK_CLR updates, registered o_irq level gating, unbounded mask
// independence of completion counting/timing/status via relational shadow
// comparison, and moderated RX/TX notifications against an independent
// completion-count and cycle-timestamp deadline specification.
module nic_irq_formal #(
    parameter logic [31:0] TICK_DEFAULT = 32'd2,
    parameter bit          BOUNDED_SPEC = 1'b0
) (
    input logic        i_clk,
    input logic        i_rst,
    input logic        i_wr_en,
    input logic [11:0] i_wr_offset,
    input logic [31:0] i_wr_data,
    input logic        i_rx_done,
    input logic        i_tx_done,
    input logic        i_rx_drop,
    input logic        i_link_change,
    input logic        i_desc_err
);

  logic [31:0] o_status;
  logic [31:0] o_mask;
  logic [31:0] o_rx_coalesce;
  logic [31:0] o_tx_coalesce;
  logic [31:0] o_tick;
  logic        o_irq;

  nic_irq #(
      .TICK_DEFAULT(TICK_DEFAULT)
  ) dut (
      .i_clk        (i_clk),
      .i_rst        (i_rst),
      .i_wr_en      (i_wr_en),
      .i_wr_offset  (i_wr_offset),
      .i_wr_data    (i_wr_data),
      .o_status     (o_status),
      .o_mask       (o_mask),
      .o_rx_coalesce(o_rx_coalesce),
      .o_tx_coalesce(o_tx_coalesce),
      .o_tick       (o_tick),
      .i_rx_done    (i_rx_done),
      .i_tx_done    (i_tx_done),
      .i_rx_drop    (i_rx_drop),
      .i_link_change(i_link_change),
      .i_desc_err   (i_desc_err),
      .o_irq        (o_irq)
  );

  // Force reset on step 0; later cycles allow arbitrary resets in both prove and bmc.
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;
  always_comb begin
    if (!f_past_valid) assume (i_rst);
  end

  wire wr_status = i_wr_en && (i_wr_offset == nic_pkg::IrqStatusOffset);
  wire wr_mask = i_wr_en && (i_wr_offset == nic_pkg::IrqMaskOffset);
  wire wr_mask_set = i_wr_en && (i_wr_offset == nic_pkg::IrqMaskSetOffset);
  wire wr_mask_clr = i_wr_en && (i_wr_offset == nic_pkg::IrqMaskClrOffset);

  // Unbounded relational proof (prove task): compare against a shadow instance that
  // receives identical non-mask writes and event pulses while suppressing mask writes,
  // proving across all depths that masking never perturbs o_status or moderation state.
  if (!BOUNDED_SPEC) begin : g_unbounded_mask_shadow
    wire is_mask_write = (i_wr_offset == nic_pkg::IrqMaskOffset) ||
        (i_wr_offset == nic_pkg::IrqMaskSetOffset) ||
        (i_wr_offset == nic_pkg::IrqMaskClrOffset);

    logic [31:0] shadow_status;
    logic [31:0] shadow_mask;
    logic [31:0] shadow_rx_coalesce;
    logic [31:0] shadow_tx_coalesce;
    logic [31:0] shadow_tick;
    logic shadow_irq;

    nic_irq #(
        .TICK_DEFAULT(TICK_DEFAULT)
    ) u_unmasked_ref (
        .i_clk        (i_clk),
        .i_rst        (i_rst),
        .i_wr_en      (i_wr_en && !is_mask_write),
        .i_wr_offset  (i_wr_offset),
        .i_wr_data    (i_wr_data),
        .o_status     (shadow_status),
        .o_mask       (shadow_mask),
        .o_rx_coalesce(shadow_rx_coalesce),
        .o_tx_coalesce(shadow_tx_coalesce),
        .o_tick       (shadow_tick),
        .i_rx_done    (i_rx_done),
        .i_tx_done    (i_tx_done),
        .i_rx_drop    (i_rx_drop),
        .i_link_change(i_link_change),
        .i_desc_err   (i_desc_err),
        .o_irq        (shadow_irq)
    );

    for (genvar d = 0; d < 2; d++) begin : g_mask_rel_inv
      always_comb begin
        if (f_past_valid) begin
          p_rel_mod_state_eq :
          assert ((dut.gen_moderator[d].count_q == u_unmasked_ref.gen_moderator[d].count_q) &&
                  (dut.gen_moderator[d].armed_q == u_unmasked_ref.gen_moderator[d].armed_q) &&
                  (dut.gen_moderator[d].max_s == u_unmasked_ref.gen_moderator[d].max_s) &&
                  (dut.gen_moderator[d].delay_s == u_unmasked_ref.gen_moderator[d].delay_s) &&
                  (dut.gen_moderator[d].tick_s == u_unmasked_ref.gen_moderator[d].tick_s) &&
                  (dut.gen_moderator[d].tick_cnt_q == u_unmasked_ref.gen_moderator[d].tick_cnt_q) &&
                  (dut.gen_moderator[d].ticks_q == u_unmasked_ref.gen_moderator[d].ticks_q));
        end
      end
    end

    always_comb begin
      if (f_past_valid) begin
        p_mask_never_loses_status :
        assert ((o_status == shadow_status) && (o_rx_coalesce == shadow_rx_coalesce) &&
                (o_tx_coalesce == shadow_tx_coalesce) && (o_tick == shadow_tick));
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && $past(i_rst)) begin
      // Reset clears status, mask, coalesce registers, o_irq, and restores TICK_DEFAULT.
      p_reset_values :
      assert ((o_status == '0) && (o_mask == '0) && (o_rx_coalesce == '0) &&
              (o_tx_coalesce == '0) && (o_tick == TICK_DEFAULT) && !o_irq);
    end

    if (f_past_valid && !$past(i_rst) && !i_rst) begin
      // Registered o_irq equals the OR-reduction of the previous cycle's masked status.
      p_irq_registered_exact :
      assert (o_irq == |($past(
          o_status[nic_pkg::IrqBits-1:0]
      ) & $past(
          o_mask[nic_pkg::IrqBits-1:0]
      )));

      // Direct, W1S, and W1C mask register writes update only the targeted mask bits.
      if ($past(wr_mask)) begin
        p_mask_direct :
        assert (o_mask[nic_pkg::IrqBits-1:0] == $past(i_wr_data[nic_pkg::IrqBits-1:0]));
      end else if ($past(wr_mask_set)) begin
        p_mask_w1s :
        assert (o_mask[nic_pkg::IrqBits-1:0] == ($past(
            o_mask[nic_pkg::IrqBits-1:0]
        ) | $past(
            i_wr_data[nic_pkg::IrqBits-1:0]
        )));
      end else if ($past(wr_mask_clr)) begin
        p_mask_w1c :
        assert (o_mask[nic_pkg::IrqBits-1:0] == ($past(
            o_mask[nic_pkg::IrqBits-1:0]
        ) & ~$past(
            i_wr_data[nic_pkg::IrqBits-1:0]
        )));
      end else begin
        p_mask_stable : assert (o_mask == $past(o_mask));
      end

      // Plain event bits (RX_DROP, LINK, DESC_ERR) are sticky until W1C, and a
      // same-cycle event pulse beats W1C.
      p_plain_events_w1c_and_priority :
      assert (o_status[4:2] == (($past(
          o_status[4:2]
      ) & ~($past(
          wr_status
      ) ? $past(
          i_wr_data[4:2]
      ) : 3'b000)) | $past(
          {i_desc_err, i_link_change, i_rx_drop}
      )));

      // Moderated RX and TX status bits stay sticky once raised until W1C clears them.
      if ($past(o_status[0]) && !($past(wr_status) && $past(i_wr_data[0]))) begin
        p_rx_status_sticky : assert (o_status[0]);
      end
      if ($past(o_status[1]) && !($past(wr_status) && $past(i_wr_data[1]))) begin
        p_tx_status_sticky : assert (o_status[1]);
      end

      // Starting an RX interval via W1C+completion when delay==0 raises RX status one cycle later,
      // even if another W1C occurs on that raise cycle.
      if ($past(
              f_past_valid
          ) && !$past(
              i_rst, 2
          ) && $past(
              wr_status && i_wr_data[0] && i_rx_done && (o_rx_coalesce[15:0] == 16'd0), 2
          )) begin
        p_rx_zero_delay_notifies : assert (o_status[0]);
      end
    end
  end

  // Independent completion-count and cycle-timestamp moderation specification.
  // Models architectural intervals from completion count since ack, first-completion
  // cycle timestamp, and exact product (delay * max(1, tick)) without subtick dividers.
  if (BOUNDED_SPEC) begin : g_bounded_spec
    wire [1:0] ev_done = {i_tx_done, i_rx_done};
    wire [1:0] ev_ack = {wr_status && i_wr_data[1], wr_status && i_wr_data[0]};

    // Within bounded depth (< 31 cycles from reset), elapsed < 31 always holds, so
    // capping delay and tick at 31 preserves exact (elapsed >= delay * eff_tick)
    // across all 16-bit delays and 32-bit ticks without a 48-bit SMT multiplier.
    localparam int unsigned SpecCap = 31;

    logic [5:0] spec_cycle = 6'd0;
    always_ff @(posedge i_clk) begin
      if (i_rst) spec_cycle <= 6'd0;
      else if (spec_cycle != 6'd63) spec_cycle <= spec_cycle + 6'd1;
    end

    logic [ 1:0] spec_has_comp;
    logic [ 1:0] spec_interval_open;
    logic [ 1:0] spec_raise;
    logic [ 8:0] rx_comp_count;
    logic [ 7:0] rx_max_count;
    logic [15:0] rx_delay_units;
    logic [11:0] rx_deadline_cycles;
    logic [11:0] rx_elapsed_cycles;

    for (genvar d = 0; d < 2; d++) begin : g_spec_dir
      logic        has_comp_q = 1'b0;
      logic        notified_q = 1'b0;
      logic [ 8:0] comp_count_q = 9'd0;
      logic [ 5:0] start_cycle_q = 6'd0;
      logic [ 7:0] snap_max_q = 8'd0;
      logic [15:0] snap_delay_q = 16'd0;
      logic [11:0] snap_deadline_q = 12'd0;

      wire  [23:0] cfg_coal = (d == 0) ? o_rx_coalesce[23:0] : o_tx_coalesce[23:0];
      wire  [31:0] eff_tick = (o_tick == 32'd0) ? 32'd1 : o_tick;
      wire  [ 5:0] cap_delay = (cfg_coal[15:0] > SpecCap[15:0]) ? SpecCap[5:0] : cfg_coal[5:0];
      wire  [ 5:0] cap_tick = (eff_tick > SpecCap) ? SpecCap[5:0] : eff_tick[5:0];
      wire  [11:0] next_deadline = 12'(cap_delay) * 12'(cap_tick);
      wire  [11:0] elapsed = 12'(spec_cycle - start_cycle_q);
      wire         interval_open = has_comp_q && !notified_q;
      wire         count_met = (snap_max_q != 8'd0) && (comp_count_q >= 9'(snap_max_q));
      wire         time_met = (snap_delay_q == 16'd0) || (elapsed >= snap_deadline_q);
      wire         raise_now = interval_open && (count_met || time_met);

      assign spec_has_comp[d] = has_comp_q;
      assign spec_interval_open[d] = interval_open;
      assign spec_raise[d] = raise_now;

      if (d == 0) begin : g_rx_obs
        assign rx_comp_count      = comp_count_q;
        assign rx_max_count       = snap_max_q;
        assign rx_delay_units     = snap_delay_q;
        assign rx_deadline_cycles = snap_deadline_q;
        assign rx_elapsed_cycles  = elapsed;
      end

      always_ff @(posedge i_clk) begin
        if (i_rst) begin
          has_comp_q      <= 1'b0;
          notified_q      <= 1'b0;
          comp_count_q    <= 9'd0;
          start_cycle_q   <= 6'd0;
          snap_max_q      <= 8'd0;
          snap_delay_q    <= 16'd0;
          snap_deadline_q <= 12'd0;
        end else if (ev_ack[d] && ev_done[d]) begin
          has_comp_q      <= 1'b1;
          notified_q      <= 1'b0;
          comp_count_q    <= 9'd1;
          start_cycle_q   <= spec_cycle + 6'd1;
          snap_max_q      <= cfg_coal[23:16];
          snap_delay_q    <= cfg_coal[15:0];
          snap_deadline_q <= next_deadline;
        end else if (ev_ack[d]) begin
          has_comp_q   <= 1'b0;
          notified_q   <= 1'b0;
          comp_count_q <= 9'd0;
        end else if (ev_done[d]) begin
          if (!has_comp_q) begin
            has_comp_q      <= 1'b1;
            notified_q      <= 1'b0;
            comp_count_q    <= 9'd1;
            start_cycle_q   <= spec_cycle + 6'd1;
            snap_max_q      <= cfg_coal[23:16];
            snap_delay_q    <= cfg_coal[15:0];
            snap_deadline_q <= next_deadline;
          end else begin
            if (comp_count_q != 9'h1FF) comp_count_q <= comp_count_q + 9'd1;
            if (raise_now) notified_q <= 1'b1;
          end
        end else begin
          if (raise_now) notified_q <= 1'b1;
        end
      end
    end

    always_comb begin
      if (f_past_valid && !i_rst) begin
        // Lossless moderation invariant: whenever at least one completion has arrived in the
        // current post-W1C interval, either o_status[d] is asserted or the interval remains open.
        if (spec_has_comp[0]) begin
          p_no_stranded_rx_completion : assert (o_status[0] || spec_interval_open[0]);
        end
        if (spec_has_comp[1]) begin
          p_no_stranded_tx_completion : assert (o_status[1] || spec_interval_open[1]);
        end
      end
    end

    always_ff @(posedge i_clk) begin
      if (f_past_valid && !$past(i_rst) && !i_rst) begin
        // Exact RX and TX moderated status transitions against the timestamp/count oracle,
        // including notification beating a same-cycle W1C.
        p_moderated_rx_exact :
        assert (o_status[0] == (($past(
            o_status[0]
        ) & ~($past(
            wr_status
        ) && $past(
            i_wr_data[0]
        ))) | $past(
            spec_raise[0]
        )));
        p_moderated_tx_exact :
        assert (o_status[1] == (($past(
            o_status[1]
        ) & ~($past(
            wr_status
        ) && $past(
            i_wr_data[1]
        ))) | $past(
            spec_raise[1]
        )));
      end

      if (f_past_valid && !i_rst) begin
        // Reach count-threshold notification, multi-tick timer deadline, snapshot isolation
        // across mid-interval register writes and extra completions, and raise+W1C race.
        c_count_threshold_raise :
        cover (spec_interval_open[0] && (rx_delay_units > 16'd2) && (rx_max_count == 8'd2) &&
               (rx_comp_count == 9'd2) && spec_raise[0]);
        c_timer_deadline_raise :
        cover (spec_interval_open[0] && (rx_max_count == 8'd0) && (rx_delay_units == 16'd2) &&
               (rx_deadline_cycles == 12'd6) && (rx_elapsed_cycles == 12'd6) && spec_raise[0]);
        c_snapshot_ignores_mid_interval_reconfig :
        cover (spec_interval_open[0] && (rx_comp_count == 9'd2) && (rx_max_count == 8'd0) &&
               (rx_delay_units == 16'd2) && (o_rx_coalesce[23:16] == 8'd1) &&
               (o_tick == 32'd9) && (rx_deadline_cycles == 12'd4) && spec_raise[0]);
        c_raise_beats_same_cycle_w1c : cover ($past(spec_raise[0] && ev_ack[0]) && o_status[0]);
        c_masked_event_then_unmask_irq :
        cover ($past(
            f_past_valid
        ) && $past(
            !i_rst && o_status[0] && (o_mask == '0), 2
        ) && $past(
            !i_rst && o_mask[0]
        ) && o_irq);
      end
    end
  end

endmodule
