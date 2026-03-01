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
 * FP Divide/Sqrt Shim (CDB Slot 6, FDIV_RS)
 *
 * Fully pipelined: 4 sub-units (div_s, div_d, sqrt_s, sqrt_d) each accept
 * a new operation every cycle. Per-sub-unit tag queues track in-flight ops.
 * Holding registers capture sub-unit completions. A priority arbiter drains
 * holding registers into a result FIFO. Credit-based back-pressure prevents
 * FIFO overflow.
 *
 * Pipeline depths: SP = 36 stages, DP = 65 stages.
 */
module fp_div_shim (
    input logic i_clk,
    input logic i_rst_n,

    // From FDIV_RS (issue output)
    input riscv_pkg::rs_issue_t i_rs_issue,

    // FU completion to CDB adapter
    output riscv_pkg::fu_complete_t o_fu_complete,

    // Back-pressure
    output logic o_fu_busy,

    // Pipeline flush (full)
    input logic i_flush,

    // Pipeline flush (partial)
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,

    // Result consumed by downstream adapter
    input logic i_div_accepted
);

  localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned FlagsW = 5;  // fp_flags_t width

  // Sub-unit indices
  localparam int unsigned NumUnits = 4;
  localparam int unsigned UDivS = 0;
  localparam int unsigned UDivD = 1;
  localparam int unsigned USqrtS = 2;
  localparam int unsigned USqrtD = 3;

  // Tag queue and FIFO depth
  localparam int unsigned QueueDepth = 4;
  localparam int unsigned FifoDepth = 4;

  // Pipeline depths per sub-unit (for tag queue shift registers)
  localparam int unsigned DivSDepth = 36;
  localparam int unsigned DivDDepth = 65;
  localparam int unsigned SqrtSDepth = 36;
  localparam int unsigned SqrtDDepth = 65;

  // ===========================================================================
  // Age comparison for partial flush
  // ===========================================================================
  function automatic logic is_younger(input logic [TagW-1:0] entry_tag,
                                      input logic [TagW-1:0] flush_tag,
                                      input logic [TagW-1:0] head);
    logic [TagW:0] entry_age;
    logic [TagW:0] flush_age;
    begin
      entry_age  = {1'b0, entry_tag} - {1'b0, head};
      flush_age  = {1'b0, flush_tag} - {1'b0, head};
      is_younger = entry_age > flush_age;
    end
  endfunction

  // ===========================================================================
  // Op decode
  // ===========================================================================
  logic use_div, use_sqrt;
  logic op_is_double;

  always_comb begin
    use_div      = 1'b0;
    use_sqrt     = 1'b0;
    op_is_double = 1'b0;

    case (i_rs_issue.op)
      riscv_pkg::FDIV_S: use_div = 1'b1;
      riscv_pkg::FDIV_D: begin
        use_div = 1'b1;
        op_is_double = 1'b1;
      end
      riscv_pkg::FSQRT_S: use_sqrt = 1'b1;
      riscv_pkg::FSQRT_D: begin
        use_sqrt = 1'b1;
        op_is_double = 1'b1;
      end
      default: ;
    endcase
  end

  // Operand extraction
  wire [31:0] src1_s = i_rs_issue.src1_value[31:0];
  wire [31:0] src2_s = i_rs_issue.src2_value[31:0];
  wire [63:0] src1_d = i_rs_issue.src1_value;
  wire [63:0] src2_d = i_rs_issue.src2_value;

  // ===========================================================================
  // Credit-based busy (forward declaration, computed below)
  // ===========================================================================
  logic div_busy;

  // ===========================================================================
  // Fire signals — route issue to exactly one sub-unit
  // ===========================================================================
  logic fire;
  assign fire = i_rs_issue.valid & (use_div | use_sqrt) & ~div_busy;

  logic fire_div_s, fire_div_d, fire_sqrt_s, fire_sqrt_d;
  assign fire_div_s  = fire & use_div & ~op_is_double;
  assign fire_div_d  = fire & use_div & op_is_double;
  assign fire_sqrt_s = fire & use_sqrt & ~op_is_double;
  assign fire_sqrt_d = fire & use_sqrt & op_is_double;

  // ===========================================================================
  // Sub-unit instantiation
  // ===========================================================================
  logic                 [31:0] div_s_result;
  logic                        div_s_valid;
  riscv_pkg::fp_flags_t        div_s_flags;

  fp_divider #(
      .FP_WIDTH(32)
  ) u_div_s (
      .i_clk(i_clk),
      .i_rst(~i_rst_n),
      .i_valid(fire_div_s),
      .i_operand_a(src1_s),
      .i_operand_b(src2_s),
      .i_rounding_mode(i_rs_issue.rm),
      .o_result(div_s_result),
      .o_valid(div_s_valid),
      .o_stall(),
      .o_flags(div_s_flags)
  );

  logic                 [63:0] div_d_result;
  logic                        div_d_valid;
  riscv_pkg::fp_flags_t        div_d_flags;

  fp_divider #(
      .FP_WIDTH(64)
  ) u_div_d (
      .i_clk(i_clk),
      .i_rst(~i_rst_n),
      .i_valid(fire_div_d),
      .i_operand_a(src1_d),
      .i_operand_b(src2_d),
      .i_rounding_mode(i_rs_issue.rm),
      .o_result(div_d_result),
      .o_valid(div_d_valid),
      .o_stall(),
      .o_flags(div_d_flags)
  );

  logic                 [31:0] sqrt_s_result;
  logic                        sqrt_s_valid;
  riscv_pkg::fp_flags_t        sqrt_s_flags;

  fp_sqrt #(
      .FP_WIDTH(32)
  ) u_sqrt_s (
      .i_clk(i_clk),
      .i_rst(~i_rst_n),
      .i_valid(fire_sqrt_s),
      .i_operand(src1_s),
      .i_rounding_mode(i_rs_issue.rm),
      .o_result(sqrt_s_result),
      .o_valid(sqrt_s_valid),
      .o_stall(),
      .o_flags(sqrt_s_flags)
  );

  logic                 [63:0] sqrt_d_result;
  logic                        sqrt_d_valid;
  riscv_pkg::fp_flags_t        sqrt_d_flags;

  fp_sqrt #(
      .FP_WIDTH(64)
  ) u_sqrt_d (
      .i_clk(i_clk),
      .i_rst(~i_rst_n),
      .i_valid(fire_sqrt_d),
      .i_operand(src1_d),
      .i_rounding_mode(i_rs_issue.rm),
      .o_result(sqrt_d_result),
      .o_valid(sqrt_d_valid),
      .o_stall(),
      .o_flags(sqrt_d_flags)
  );

  // Collect sub-unit outputs into arrays for uniform handling
  logic              unit_valid_out[NumUnits];
  logic [  FLEN-1:0] unit_result   [NumUnits];
  logic [FlagsW-1:0] unit_flags    [NumUnits];

  // NaN-box SP results
  assign unit_valid_out[UDivS]  = div_s_valid;
  assign unit_result[UDivS]     = {32'hFFFF_FFFF, div_s_result};
  assign unit_flags[UDivS]      = div_s_flags;

  assign unit_valid_out[UDivD]  = div_d_valid;
  assign unit_result[UDivD]     = div_d_result;
  assign unit_flags[UDivD]      = div_d_flags;

  assign unit_valid_out[USqrtS] = sqrt_s_valid;
  assign unit_result[USqrtS]    = {32'hFFFF_FFFF, sqrt_s_result};
  assign unit_flags[USqrtS]     = sqrt_s_flags;

  assign unit_valid_out[USqrtD] = sqrt_d_valid;
  assign unit_result[USqrtD]    = sqrt_d_result;
  assign unit_flags[USqrtD]     = sqrt_d_flags;

  // ===========================================================================
  // Per-sub-unit tag queues (shift registers, max depth = max pipeline depth)
  // Each sub-unit has its own depth matching the pipeline latency.
  // We use a unified max-depth array and per-unit depth parameters.
  // ===========================================================================
  localparam int unsigned MaxPipeDepth = 65;  // max(36, 65)

  // Tag queue arrays — flat for Icarus compatibility
  logic            tq_valid  [NumUnits] [MaxPipeDepth];
  logic [TagW-1:0] tq_tag    [NumUnits] [MaxPipeDepth];
  logic            tq_flushed[NumUnits] [MaxPipeDepth];

  // Fire signals as array for indexing
  logic            fire_unit [NumUnits];
  assign fire_unit[UDivS]  = fire_div_s;
  assign fire_unit[UDivD]  = fire_div_d;
  assign fire_unit[USqrtS] = fire_sqrt_s;
  assign fire_unit[USqrtD] = fire_sqrt_d;

  // Generate tag queue shift registers for each sub-unit
  for (genvar u = 0; u < NumUnits; u++) begin : gen_tq
    localparam int unsigned Depth = (u == UDivS)  ? DivSDepth  :
                                    (u == UDivD)  ? DivDDepth  :
                                    (u == USqrtS) ? SqrtSDepth : SqrtDDepth;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
      if (!i_rst_n) begin
        for (int i = 0; i < MaxPipeDepth; i++) begin
          tq_valid[u][i]   <= 1'b0;
          tq_tag[u][i]     <= '0;
          tq_flushed[u][i] <= 1'b0;
        end
      end else if (i_flush) begin
        for (int i = 0; i < MaxPipeDepth; i++) begin
          tq_valid[u][i] <= 1'b0;
        end
      end else begin
        // Shift stages [0..Depth-2] -> [1..Depth-1]
        for (int i = Depth - 1; i >= 1; i--) begin
          tq_valid[u][i] <= tq_valid[u][i-1];
          tq_tag[u][i]   <= tq_tag[u][i-1];
          if (tq_valid[u][i-1] && i_flush_en && is_younger(
                  tq_tag[u][i-1], i_flush_tag, i_rob_head_tag
              )) begin
            tq_flushed[u][i] <= 1'b1;
          end else begin
            tq_flushed[u][i] <= tq_flushed[u][i-1];
          end
        end
        // Stage 0: load from issue or invalidate
        if (fire_unit[u]) begin
          tq_valid[u][0] <= 1'b1;
          tq_tag[u][0]   <= i_rs_issue.rob_tag;
          if (i_flush_en && is_younger(i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag)) begin
            tq_flushed[u][0] <= 1'b1;
          end else begin
            tq_flushed[u][0] <= 1'b0;
          end
        end else begin
          tq_valid[u][0]   <= 1'b0;
          tq_tag[u][0]     <= '0;
          tq_flushed[u][0] <= 1'b0;
        end
      end
    end
  end

  // ===========================================================================
  // Per-sub-unit completion handling + holding registers
  // ===========================================================================
  // Tail index (output end of shift register) per unit
  logic            tail_valid           [NumUnits];
  logic [TagW-1:0] tail_tag             [NumUnits];
  logic            tail_flushed         [NumUnits];
  logic            tail_partial_flushing[NumUnits];
  logic            completing           [NumUnits];

  for (genvar u = 0; u < NumUnits; u++) begin : gen_tail
    localparam int unsigned Depth = (u == UDivS)  ? DivSDepth  :
                                    (u == UDivD)  ? DivDDepth  :
                                    (u == USqrtS) ? SqrtSDepth : SqrtDDepth;
    assign tail_valid[u] = tq_valid[u][Depth-1];
    assign tail_tag[u] = tq_tag[u][Depth-1];
    assign tail_flushed[u] = tq_flushed[u][Depth-1];
    assign tail_partial_flushing[u] = tail_valid[u] && i_flush_en && is_younger(
        tail_tag[u], i_flush_tag, i_rob_head_tag
    );
    assign completing[u] = tail_valid[u] && !tail_flushed[u] && !tail_partial_flushing[u];
  end

  // 2-deep hold buffers per sub-unit (prevents data loss on simultaneous
  // completions from different sub-units with back-to-back output).
  // Depth 2 is provably sufficient: needing depth 3 would require 3 ops in
  // one sub-unit + 3 higher-priority holds occupied = 6 credits > FifoDepth.
  logic                        hold_valid            [NumUnits] [2];
  logic [            TagW-1:0] hold_tag              [NumUnits] [2];
  logic [            FLEN-1:0] hold_value            [NumUnits] [2];
  logic [          FlagsW-1:0] hold_flags            [NumUnits] [2];
  logic                        hold_flushed          [NumUnits] [2];
  logic                        hold_rd               [NumUnits];
  logic                        hold_wr               [NumUnits];
  logic [                 1:0] hold_count            [NumUnits];

  // Arbiter: fixed priority drain of hold buffers into FIFO
  // Priority: DIV_S > DIV_D > SQRT_S > SQRT_D
  logic                        arbiter_sel_valid;
  logic [$clog2(NumUnits)-1:0] arbiter_sel;
  logic                        arbiter_entry_flushed;

  always_comb begin
    arbiter_sel_valid = 1'b0;
    arbiter_sel = '0;
    for (int i = 0; i < NumUnits; i++) begin
      if (hold_count[i] != 2'd0 && !arbiter_sel_valid) begin
        arbiter_sel_valid = 1'b1;
        arbiter_sel = i[$clog2(NumUnits)-1:0];
      end
    end
  end

  // Check if the arbiter's selected entry is already marked flushed
  assign arbiter_entry_flushed = arbiter_sel_valid &&
      hold_flushed[arbiter_sel][hold_rd[arbiter_sel]];

  // FIFO push from arbiter — skip entries that are flushed or being
  // partial-flushed this same cycle (fixes partial-flush race on push).
  logic fifo_push;
  logic push_partial_flushing;
  assign push_partial_flushing = arbiter_sel_valid && !arbiter_entry_flushed &&
      i_flush_en && is_younger(
      hold_tag[arbiter_sel][hold_rd[arbiter_sel]], i_flush_tag, i_rob_head_tag
  );
  assign fifo_push = arbiter_sel_valid && !arbiter_entry_flushed && !push_partial_flushing;

  // Hold buffer management (2-deep circular buffer per sub-unit)
  for (genvar u = 0; u < NumUnits; u++) begin : gen_hold
    always_ff @(posedge i_clk or negedge i_rst_n) begin
      if (!i_rst_n) begin
        hold_valid[u][0]   <= 1'b0;
        hold_valid[u][1]   <= 1'b0;
        hold_flushed[u][0] <= 1'b0;
        hold_flushed[u][1] <= 1'b0;
        hold_rd[u]         <= 1'b0;
        hold_wr[u]         <= 1'b0;
        hold_count[u]      <= 2'd0;
      end else if (i_flush) begin
        hold_valid[u][0]   <= 1'b0;
        hold_valid[u][1]   <= 1'b0;
        hold_flushed[u][0] <= 1'b0;
        hold_flushed[u][1] <= 1'b0;
        hold_rd[u]         <= 1'b0;
        hold_wr[u]         <= 1'b0;
        hold_count[u]      <= 2'd0;
      end else begin
        // Partial flush: mark younger hold entries as flushed
        for (int s = 0; s < 2; s++) begin
          if (hold_valid[u][s] && !hold_flushed[u][s] && i_flush_en && is_younger(
                  hold_tag[u][s], i_flush_tag, i_rob_head_tag
              )) begin
            hold_flushed[u][s] <= 1'b1;
          end
        end

        // Drain: arbiter pops from rd slot.
        // Use explicit slot writes (no variable index) for formal friendliness.
        if (arbiter_sel_valid && arbiter_sel == u[$clog2(NumUnits)-1:0]) begin
          if (hold_rd[u]) begin
            hold_valid[u][1]   <= 1'b0;
            hold_flushed[u][1] <= 1'b0;
          end else begin
            hold_valid[u][0]   <= 1'b0;
            hold_flushed[u][0] <= 1'b0;
          end
          hold_rd[u] <= ~hold_rd[u];
        end

        // Capture: push new completion to wr slot.
        // Keep this after drain so same-slot push+pop keeps push data.
        if (completing[u]) begin
          if (hold_wr[u]) begin
            hold_valid[u][1]   <= 1'b1;
            hold_tag[u][1]     <= tail_tag[u];
            hold_value[u][1]   <= unit_result[u];
            hold_flags[u][1]   <= unit_flags[u];
            hold_flushed[u][1] <= 1'b0;
          end else begin
            hold_valid[u][0]   <= 1'b1;
            hold_tag[u][0]     <= tail_tag[u];
            hold_value[u][0]   <= unit_result[u];
            hold_flags[u][0]   <= unit_flags[u];
            hold_flushed[u][0] <= 1'b0;
          end
          hold_wr[u] <= ~hold_wr[u];
        end

        // Update count
        case ({
          arbiter_sel_valid && arbiter_sel == u[$clog2(NumUnits)-1:0], completing[u]
        })
          2'b10:   hold_count[u] <= hold_count[u] - 1;
          2'b01:   hold_count[u] <= hold_count[u] + 1;
          default: hold_count[u] <= hold_count[u];
        endcase
      end
    end
  end

  // ===========================================================================
  // Result FIFO (depth 4, register-based)
  // ===========================================================================
  logic [               TagW-1:0] fifo_tag                   [FifoDepth];
  logic [               FLEN-1:0] fifo_value                 [FifoDepth];
  logic [             FlagsW-1:0] fifo_flags                 [FifoDepth];
  logic [          FifoDepth-1:0] fifo_valid;
  logic [          FifoDepth-1:0] fifo_flushed;
  logic [$clog2(FifoDepth+1)-1:0] fifo_count;
  logic [  $clog2(FifoDepth)-1:0] fifo_wr_ptr;
  logic [  $clog2(FifoDepth)-1:0] fifo_rd_ptr;

  // Same-cycle partial flush of FIFO head
  logic                           fifo_head_partial_flushing;
  assign fifo_head_partial_flushing = (fifo_count != '0) &&
      !fifo_flushed[fifo_rd_ptr] && i_flush_en &&
      is_younger(
      fifo_tag[fifo_rd_ptr], i_flush_tag, i_rob_head_tag
  );

  // FIFO pop: adapter consumed, or head is flushed (auto-drain)
  logic fifo_pop;
  logic fifo_head_flushed;
  assign fifo_head_flushed = fifo_valid[fifo_rd_ptr] &&
      (fifo_flushed[fifo_rd_ptr] || fifo_head_partial_flushing);
  assign fifo_pop = (fifo_count != '0) && (i_div_accepted || fifo_head_flushed);

  always_ff @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
      for (int i = 0; i < FifoDepth; i++) begin
        fifo_valid[i]   <= 1'b0;
        fifo_flushed[i] <= 1'b0;
      end
      fifo_wr_ptr <= '0;
      fifo_rd_ptr <= '0;
      fifo_count  <= '0;
    end else if (i_flush) begin
      for (int i = 0; i < FifoDepth; i++) begin
        fifo_valid[i]   <= 1'b0;
        fifo_flushed[i] <= 1'b0;
      end
      fifo_wr_ptr <= '0;
      fifo_rd_ptr <= '0;
      fifo_count  <= '0;
    end else begin
      // Partial flush: mark younger FIFO entries as flushed
      if (i_flush_en) begin
        for (int i = 0; i < FifoDepth; i++) begin
          if (fifo_valid[i] && !fifo_flushed[i] && is_younger(
                  fifo_tag[i], i_flush_tag, i_rob_head_tag
              )) begin
            fifo_flushed[i] <= 1'b1;
          end
        end
      end

      // Push from arbiter (reads from rd slot of selected hold buffer)
      if (fifo_push) begin
        fifo_tag[fifo_wr_ptr]     <= hold_tag[arbiter_sel][hold_rd[arbiter_sel]];
        fifo_value[fifo_wr_ptr]   <= hold_value[arbiter_sel][hold_rd[arbiter_sel]];
        fifo_flags[fifo_wr_ptr]   <= hold_flags[arbiter_sel][hold_rd[arbiter_sel]];
        fifo_valid[fifo_wr_ptr]   <= 1'b1;
        fifo_flushed[fifo_wr_ptr] <= 1'b0;
        fifo_wr_ptr               <= fifo_wr_ptr + 1;
      end

      // Pop
      if (fifo_pop) begin
        fifo_valid[fifo_rd_ptr] <= 1'b0;
        fifo_flushed[fifo_rd_ptr] <= 1'b0;
        fifo_rd_ptr <= fifo_rd_ptr + 1;
      end

      // Update count
      case ({
        fifo_push, fifo_pop
      })
        2'b10:   fifo_count <= fifo_count + 1;
        2'b01:   fifo_count <= fifo_count - 1;
        default: fifo_count <= fifo_count;
      endcase
    end
  end

  // ===========================================================================
  // FIFO head output drives o_fu_complete
  // ===========================================================================
  always_comb begin
    if (fifo_count != '0 && !fifo_flushed[fifo_rd_ptr] && !fifo_head_partial_flushing) begin
      o_fu_complete.valid     = 1'b1;
      o_fu_complete.tag       = fifo_tag[fifo_rd_ptr];
      o_fu_complete.value     = fifo_value[fifo_rd_ptr];
      o_fu_complete.exception = 1'b0;
      o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
      o_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'(fifo_flags[fifo_rd_ptr]);
    end else begin
      o_fu_complete.valid     = 1'b0;
      o_fu_complete.tag       = '0;
      o_fu_complete.value     = '0;
      o_fu_complete.exception = 1'b0;
      o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
      o_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'('0);
    end
  end

  // ===========================================================================
  // Busy signal: credit-based to prevent FIFO overflow
  // ===========================================================================
  // Count valid && !flushed entries across all tag queues
  logic [7:0] total_inflight;
  always_comb begin
    total_inflight = '0;
    for (int u = 0; u < NumUnits; u++) begin
      for (int i = 0; i < MaxPipeDepth; i++) begin
        // Only count entries within this unit's actual depth
        if ((u == UDivS  && i < DivSDepth)  ||
            (u == UDivD  && i < DivDDepth)  ||
            (u == USqrtS && i < SqrtSDepth) ||
            (u == USqrtD && i < SqrtDDepth)) begin
          if (tq_valid[u][i] && !tq_flushed[u][i]) total_inflight = total_inflight + 1;
        end
      end
    end
    // Also count valid, non-flushed hold buffer entries
    for (int u = 0; u < NumUnits; u++) begin
      for (int s = 0; s < 2; s++) begin
        if (hold_valid[u][s] && !hold_flushed[u][s]) total_inflight = total_inflight + 1;
      end
    end
  end

  logic [7:0] total_occupancy;
  assign total_occupancy = total_inflight + 8'(fifo_count);
  assign div_busy = total_occupancy >= 8'(FifoDepth);
  assign o_fu_busy = div_busy;

  // ===========================================================================
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  always_comb begin
    if (i_rst_n && o_fu_complete.valid) begin
      p_valid_has_tag : assert (o_fu_complete.tag == fifo_tag[fifo_rd_ptr]);
    end
  end

  // Guard: hold_count must never exceed 2 (depth of hold buffers).
  // Violation would mean the credit system failed to prevent overflow.
  for (genvar fu = 0; fu < NumUnits; fu++) begin : gen_hold_assert
    always @(posedge i_clk) begin
      if (i_rst_n) begin
        assert (hold_count[fu] <= 2'd2);
      end
    end
  end

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_fire_div_s : cover (fire_div_s);
      cover_fire_sqrt_s : cover (fire_sqrt_s);
      cover_complete : cover (o_fu_complete.valid);
    end
  end

`endif  // FORMAL

endmodule : fp_div_shim
