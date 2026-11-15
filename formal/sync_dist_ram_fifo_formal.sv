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

// Formal harness for sync_dist_ram_fifo.
// Checks exact occupancy flags, empty-pop gating, simultaneous push and pop
// (including while full), mid-flight synchronous reset recovery, and FIFO
// ordering and payload integrity of a symbolically selected word across
// pointer wraparounds.
module sync_dist_ram_fifo_formal #(
    parameter int unsigned ADDR_WIDTH = 3,
    parameter int unsigned DATA_WIDTH = 8
) (
    input logic                  i_clk,
    input logic                  i_rst,
    input logic                  i_write_enable,
    input logic                  i_read_enable,
    input logic [DATA_WIDTH-1:0] i_write_data,
    input logic                  i_watch_capture
);

  localparam int unsigned FifoDepth      = 2 ** ADDR_WIDTH;
  localparam int unsigned FillCountWidth = ADDR_WIDTH + 1;

  logic [DATA_WIDTH-1:0] o_read_data;
  logic                  o_empty;
  logic                  o_full;

  sync_dist_ram_fifo #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_WIDTH(DATA_WIDTH)
  ) dut (
      .i_clk         (i_clk),
      .i_rst         (i_rst),
      .i_write_enable(i_write_enable),
      .i_read_enable (i_read_enable),
      .i_write_data  (i_write_data),
      .o_read_data   (o_read_data),
      .o_empty       (o_empty),
      .o_full        (o_full)
  );

  // Start in synchronous reset on step 0; later mid-flight resets remain free.
  logic f_past_valid = 1'b0;
  always_ff @(posedge i_clk) f_past_valid <= 1'b1;
  always_comb if (!f_past_valid) assume (i_rst);

  // Documented caller contract: never push without a simultaneous pop when full.
  always_comb begin
    if (!i_rst && o_full && !i_read_enable) begin
      assume (!i_write_enable);
    end
  end

  // Reference occupancy counter and symbolically selected watched-word tracker.
  logic [FillCountWidth-1:0] ref_count = '0;
  logic f_watched_live = 1'b0;
  logic [ADDR_WIDTH-1:0] f_watched_pos = '0;
  logic [DATA_WIDTH-1:0] f_watched_data = '0;
  logic [4:0] wrap_pushes = '0;

  wire do_pop = i_read_enable && (ref_count != '0);
  wire do_push = i_write_enable;
  wire [FillCountWidth-1:0] count_after_pop = do_pop ? (ref_count - FillCountWidth'(1)) : ref_count;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      ref_count      <= '0;
      f_watched_live <= 1'b0;
      f_watched_pos  <= '0;
      f_watched_data <= '0;
      wrap_pushes    <= '0;
    end else begin
      if (do_push && !do_pop) begin
        ref_count <= ref_count + FillCountWidth'(1);
      end else if (!do_push && do_pop) begin
        ref_count <= ref_count - FillCountWidth'(1);
      end

      if (do_push && (wrap_pushes != 5'h1f)) begin
        wrap_pushes <= wrap_pushes + 5'd1;
      end

      if (f_watched_live) begin
        if (do_pop) begin
          if (f_watched_pos == '0) begin
            f_watched_live <= 1'b0;
          end else begin
            f_watched_pos <= f_watched_pos - ADDR_WIDTH'(1);
          end
        end
      end else if (do_push && i_watch_capture) begin
        f_watched_live <= 1'b1;
        f_watched_pos  <= count_after_pop[ADDR_WIDTH-1:0];
        f_watched_data <= i_write_data;
      end
    end
  end

  always_comb begin
    if (f_past_valid && !i_rst) begin
      // o_empty matches zero reference occupancy.
      p_empty_exact : assert (o_empty == (ref_count == '0));

      // o_full matches FifoDepth reference occupancy.
      p_full_exact : assert (o_full == (ref_count == FillCountWidth'(FifoDepth)));

      // o_empty and o_full are never simultaneously asserted.
      p_flags_mutex : assert (!(o_empty && o_full));

      // While a watched word is queued, its position stays strictly below occupancy;
      // when it reaches position 0, asynchronous o_read_data exposes it intact.
      if (f_watched_live) begin
        p_watched_in_bounds : assert ({1'b0, f_watched_pos} < ref_count);
        if (f_watched_pos == '0) begin
          p_watched_head_nonempty : assert (!o_empty);
          p_watched_head_data : assert (o_read_data == f_watched_data);
        end
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (f_past_valid && !$past(i_rst) && !i_rst) begin
      // Reading an empty FIFO without a push keeps the FIFO empty on the next cycle.
      if ($past(o_empty && i_read_enable && !i_write_enable)) begin
        p_empty_pop_gated : assert (o_empty);
      end
    end

    if (f_past_valid && !i_rst) begin
      // Reach full occupancy, simultaneous push+pop while full, empty pop, and pointer wraparound.
      c_full : cover (o_full);
      c_push_pop_when_full : cover (o_full && i_write_enable && i_read_enable);
      c_empty_pop_then_push : cover ($past(!i_rst && o_empty && i_read_enable) && i_write_enable);
      c_wrapped_and_drained : cover ((wrap_pushes >= 5'(2 * FifoDepth)) && o_empty);
    end
  end

endmodule
