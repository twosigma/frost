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
 * FP shim (CDB slot 4, FP_RS)
 *
 * Starts each FP_RS issue on fp_engine, which runs every FP compute operation
 * one at a time, and packs the engine's result into fu_complete_t for the CDB
 * adapter. One tag register tracks the operation in the engine. o_fu_busy is
 * high whenever a nonsquashed operation occupies the engine, its result cycle
 * included. The wrapper also stops FP_RS while the adapter holds a result,
 * so the engine's one-cycle result always finds the adapter free.
 *
 * A full flush, or a partial flush that covers the operation (the ROB-age
 * compare the rest of the back end uses), kills it in the engine, which is
 * idle again on the next cycle. With LAUNCH_SQUASH=0, an issue the same flush
 * covers never starts.
 * A flush in the result cycle itself is left to the adapter, which sees the
 * same flush.
 *
 * With LAUNCH_SQUASH, a flushed issue starts and a registered squash bit
 * kills it in its first decode cycle. There is no valid completion, and
 * o_fu_busy stays low. Fast operations may write result and flag registers
 * during that cycle. The engine cannot take an issue then, so
 * LAUNCH_SQUASH requires a bubble after a flushed issue. FP_RS provides it:
 * the flush clears the squashed stage2 packet and blocks refill.
 *
 * PIPELINE also sends FDIV.S and FDIV.D to fp_div_unit (radix 16), which
 * shares the engine's tag, kill, busy and completion: one of the two holds
 * an operation at a time.
 *
 * PIPELINE sends FADD, FSUB, FMUL and the FMA forms (fp_op_pipelined) to
 * fp_fma_pipe instead, one per cycle, and the engine
 * keeps the rest. FP_RS presents an engine operation only while the engine
 * is idle (its divide gate on o_fu_busy and the engine adapter), and a
 * pipelined operation whenever o_pipe_busy is low, so pipelined operations
 * pass a running divide or square root. A tracker as deep as the pipeline
 * (riscv_pkg::FpPipeDepth) carries each operation's valid bit, ROB tag and
 * flushed bit; a flush marks entries and they leave the tail without a
 * completion. Unflushed results enter a 16-entry FIFO (LUTRAM payload) whose
 * head is o_pipe_complete (CDB slot 6); i_pipe_accepted pops it. A registered credit,
 * o_pipe_busy, keeps tracker entries plus FIFO entries within the FIFO depth,
 * so the tail never finds the FIFO full.
 *
 * Forward wake: in the cycle before an operation's result reaches the tail
 * register, o_fwd_wake_valid and o_fwd_wake_tag name it (unflushed), and in
 * the next cycle o_fwd_value is its result. FP_RS uses the pair to issue a
 * dependent operation so that it reads the result straight from the tail
 * register. The CDB broadcast still follows through the FIFO.
 */
module fp_shim #(
    parameter bit LAUNCH_SQUASH = 1'b0,
    parameter bit PIPELINE = 1'b0
) (
    input logic i_clk,
    input logic i_rst_n,

    // From FP_RS (issue output)
    input riscv_pkg::rs_issue_t i_rs_issue,

    // FU completion to CDB adapter
    output riscv_pkg::fu_complete_t o_fu_complete,

    // The engine holds a nonsquashed operation
    output logic o_fu_busy,

    // PIPELINE: FIFO head to the pipeline's CDB adapter, and its pop
    output riscv_pkg::fu_complete_t o_pipe_complete,
    input  logic                    i_pipe_accepted,

    // PIPELINE: no credit for another pipelined operation (registered)
    output logic o_pipe_busy,

    // PIPELINE: forward wake (tag one cycle ahead of the tail value)
    output logic                                        o_fwd_wake_valid,
    output logic [riscv_pkg::ReorderBufferTagWidth-1:0] o_fwd_wake_tag,
    output logic [                 riscv_pkg::FLEN-1:0] o_fwd_value,

    // Pipeline flush (full)
    input logic i_flush,

    // Pipeline flush (partial): kill an operation younger than the tag
    input logic                                        i_flush_en,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_flush_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag
);

`ifndef SYNTHESIS
  logic reset_seen_q = 1'b0;
  always_ff @(posedge i_clk) if (!i_rst_n) reset_seen_q <= 1'b1;
`endif

  localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth;

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

  logic eng_idle, eng_done;
  logic [riscv_pkg::FLEN-1:0] eng_result;
  riscv_pkg::fp_flags_t eng_flags;
  logic [TagW-1:0] tag_q;

  logic launch_flushed, start, kill, squash_q;
  assign launch_flushed = i_flush || (i_flush_en && is_younger(
      i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag
  ));

  // With PIPELINE, the engine takes only the operations the pipeline does not.
  // FP_RS's engine gate (FP_ENGINE_GATE) uses the same list.
  function automatic logic fp_op_pipelined(input riscv_pkg::instr_op_e op);
    case (op)
      riscv_pkg::FADD_S, riscv_pkg::FSUB_S, riscv_pkg::FMUL_S, riscv_pkg::FMADD_S,
      riscv_pkg::FMSUB_S, riscv_pkg::FNMADD_S, riscv_pkg::FNMSUB_S, riscv_pkg::FADD_D,
      riscv_pkg::FSUB_D, riscv_pkg::FMUL_D, riscv_pkg::FMADD_D, riscv_pkg::FMSUB_D,
      riscv_pkg::FNMADD_D, riscv_pkg::FNMSUB_D:
      fp_op_pipelined = 1'b1;
      default: fp_op_pipelined = 1'b0;
    endcase
  endfunction

  logic is_pipe_op, eng_issue;
  assign is_pipe_op = PIPELINE && fp_op_pipelined(i_rs_issue.op);
  assign eng_issue  = i_rs_issue.valid && !is_pipe_op;

  if (LAUNCH_SQUASH) begin : g_launch_squash
    assign start = eng_issue && eng_idle;
    assign kill = squash_q || (!eng_idle && (i_flush || (i_flush_en && is_younger(
        tag_q, i_flush_tag, i_rob_head_tag
    ))));
    always_ff @(posedge i_clk) begin
      if (!i_rst_n) squash_q <= 1'b0;
      else squash_q <= start && launch_flushed;
    end
  end else begin : g_launch_gated
    assign start = eng_issue && eng_idle && !launch_flushed;
    assign kill = !eng_idle && (i_flush || (i_flush_en && is_younger(
        tag_q, i_flush_tag, i_rob_head_tag
    )));
    assign squash_q = 1'b0;
  end

  always_ff @(posedge i_clk) begin
    if (start) tag_q <= i_rs_issue.rob_tag;
  end

`ifdef FORMAL
  // The engine can finish on any busy cycle. A kill returns it to idle.
  (* anyseq *) logic f_eng_finish;
  (* anyseq *) logic [riscv_pkg::FLEN-1:0] f_eng_result;
  (* anyseq *) logic [4:0] f_eng_flags;
  logic f_eng_busy, f_eng_done;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      f_eng_busy <= 1'b0;
      f_eng_done <= 1'b0;
    end else if (kill) begin
      f_eng_busy <= 1'b0;
      f_eng_done <= 1'b0;
    end else if (start) begin
      f_eng_busy <= 1'b1;
    end else if (f_eng_done) begin
      f_eng_busy <= 1'b0;
      f_eng_done <= 1'b0;
    end else if (f_eng_busy && f_eng_finish) begin
      f_eng_done <= 1'b1;
    end
  end
  assign eng_idle   = !f_eng_busy;
  assign eng_done   = f_eng_done;
  assign eng_result = f_eng_result;
  assign eng_flags  = riscv_pkg::fp_flags_t'(f_eng_flags);
`else
  logic is_div_op;
  assign is_div_op = PIPELINE &&
      (i_rs_issue.op == riscv_pkg::FDIV_S || i_rs_issue.op == riscv_pkg::FDIV_D);
  logic e_idle, e_done, d_idle, d_done;
  logic [riscv_pkg::FLEN-1:0] e_result, d_result;
  riscv_pkg::fp_flags_t e_flags, d_flags;

  if (PIPELINE) begin : g_div_unit
    fp_div_unit u_div (
        .i_clk   (i_clk),
        .i_rst_n (i_rst_n),
        .i_start (start && is_div_op),
        .i_op    (i_rs_issue.op),
        .i_rm    (i_rs_issue.rm),
        .i_src1  (i_rs_issue.src1_value),
        .i_src2  (i_rs_issue.src2_value),
        .i_kill  (kill),
        .o_idle  (d_idle),
        .o_done  (d_done),
        .o_result(d_result),
        .o_flags (d_flags)
    );
  end else begin : g_no_div_unit
    assign d_idle   = 1'b1;
    assign d_done   = 1'b0;
    assign d_result = '0;
    assign d_flags  = '0;
  end

  assign eng_idle   = e_idle && d_idle;
  assign eng_done   = e_done || d_done;
  assign eng_result = d_done ? d_result : e_result;
  assign eng_flags  = d_done ? d_flags : e_flags;

  fp_engine u_engine (
      .i_clk      (i_clk),
      .i_rst_n    (i_rst_n),
      .i_start    (start && !is_div_op),
      .i_op       (i_rs_issue.op),
      .i_rm       (i_rs_issue.rm),
      .i_src1     (i_rs_issue.src1_value),
      .i_src2     (i_rs_issue.src2_value),
      .i_src3     (i_rs_issue.src3_value),
      // Zfa FLI's constant index (dispatch places the rs1 field in imm).
      .i_fli_index(i_rs_issue.imm[4:0]),
      .i_kill     (kill),
      .o_idle     (e_idle),
      .o_done     (e_done),
      .o_result   (e_result),
      .o_flags    (e_flags)
  );
`endif

  assign o_fu_busy = !eng_idle && !squash_q;

  always_comb begin
    o_fu_complete.valid     = eng_done;
    o_fu_complete.tag       = tag_q;
    o_fu_complete.value     = eng_result;
    o_fu_complete.exception = 1'b0;
    o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
    o_fu_complete.fp_flags  = eng_flags;
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  // The RS removes an entry on issue, so issuing while the engine is busy
  // loses it. This also forbids issue in a squashed start's decode cycle.
  always @(posedge i_clk) begin
    if (reset_seen_q && i_rst_n && eng_issue && !eng_idle) begin
`ifdef FROST_SIM_ASSERTIONS
      assert (1'b0) else
`endif
      $error("fp_shim: issue of tag %0d while the engine is busy", i_rs_issue.rob_tag);
    end
  end
`endif
`endif


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

  // FP_RS presents an engine operation only while the engine is free.
  always_comb begin
    if (i_rst_n) begin
      assume (!eng_issue || !o_fu_busy);
      // The station leaves a bubble after an issue covered by a flush.
      if (squash_q) a_engine_squash_bubble : assume (!eng_issue);
    end
  end

  // Busy exactly while the engine holds an operation, result cycle included,
  // and a result only while busy.
  always_comb begin
    if (i_rst_n) begin
      p_busy_is_engine : assert (o_fu_busy == (f_eng_busy && !squash_q));
      p_complete_only_when_busy : assert (!o_fu_complete.valid || o_fu_busy);
    end
  end

  // A kill leaves the engine idle on the next cycle, so FP_RS may issue again.
  always @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n) && $past(kill)) begin
      p_kill_frees_engine : assert (!o_fu_busy);
    end
  end

  // ---------------------------------------------------------------------------
  // A squashed tag must not complete until a new operation starts with it.
  // The ROB and RS cannot distinguish a stale completion from a reused tag
  // (tomasulo README, "CDB priority and tag reuse"). Track one arbitrary tag.
  // ---------------------------------------------------------------------------
  (* anyconst *) logic [TagW-1:0] f_watch_tag;

  logic f_watch_held;  // the watched tag is the operation in the engine
  assign f_watch_held = o_fu_busy && (tag_q == f_watch_tag);

  logic f_watch_issue;
  assign f_watch_issue = eng_issue && (i_rs_issue.rob_tag == f_watch_tag);

  logic f_watch_squashed_now;
  assign f_watch_squashed_now = (f_watch_held || f_watch_issue) &&
      (i_flush || (i_flush_en && is_younger(
      f_watch_tag, i_flush_tag, i_rob_head_tag
  )));

  logic f_watch_dead_q;
  initial f_watch_dead_q = 1'b0;
  always @(posedge i_clk) begin
    if (!i_rst_n) f_watch_dead_q <= 1'b0;
    else if (f_watch_squashed_now) f_watch_dead_q <= 1'b1;
    else if (start && (i_rs_issue.rob_tag == f_watch_tag)) f_watch_dead_q <= 1'b0;
  end

  always_comb begin
    if (i_rst_n && f_watch_dead_q && o_fu_complete.valid) begin
      p_no_stale_complete : assert (o_fu_complete.tag != f_watch_tag);
    end
  end

  // A completion carries the tag of the operation that started last.
  logic [TagW-1:0] f_started_tag;
  always @(posedge i_clk) begin
    if (start) f_started_tag <= i_rs_issue.rob_tag;
  end
  always_comb begin
    if (i_rst_n && o_fu_complete.valid) begin
      p_complete_tag : assert (o_fu_complete.tag == f_started_tag);
    end
  end

  // Inductive strengthening (fp_shim_pipe.sby proves): the engine holds the
  // last started tag, and a squashed watched tag is not the one it holds.
  always_comb begin
    if (i_rst_n && f_eng_busy) begin
      p_busy_holds_started_tag : assert (tag_q == f_started_tag);
      if (squash_q) p_squash_before_result : assert (!f_eng_done);
      if (f_watch_dead_q && !squash_q) p_dead_not_held : assert (tag_q != f_watch_tag);
    end
  end

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_complete : cover (o_fu_complete.valid);
      cover_kill : cover (kill);
      if (LAUNCH_SQUASH) begin
        c_delayed_launch_kill : cover (squash_q && f_eng_busy && kill && !o_fu_busy);
      end
      cover_launch_flushed : cover (i_rs_issue.valid && launch_flushed);
      cover_watch_dead_then_reused :
      cover (f_watch_dead_q && start && (i_rs_issue.rob_tag == f_watch_tag));
    end
  end

`endif  // FORMAL

  // ===========================================================================
  // Pipelined path (PIPELINE)
  // ===========================================================================
  localparam int unsigned PipeDepth = riscv_pkg::FpPipeDepth;
  localparam int unsigned FifoDepth = 16;
  localparam int unsigned FifoAw = $clog2(FifoDepth);

  if (PIPELINE) begin : g_pipe
    logic pipe_in;
    assign pipe_in = i_rs_issue.valid && is_pipe_op;

    // Datapath. Under FORMAL its results are arbitrary: the proofs cover
    // tags, flushes and credits; fp_fma_pipe_equiv covers the arithmetic.
    logic [riscv_pkg::FLEN-1:0] pipe_result;
    riscv_pkg::fp_flags_t pipe_flags;
    logic pipe_valid_unused;
`ifdef FORMAL
    (* anyseq *) logic [riscv_pkg::FLEN-1:0] f_pipe_result;
    (* anyseq *) logic [4:0] f_pipe_flags;
    assign pipe_result = f_pipe_result;
    assign pipe_flags = riscv_pkg::fp_flags_t'(f_pipe_flags);
    assign pipe_valid_unused = 1'b0;
`else
    fp_fma_pipe u_pipe (
        .i_clk   (i_clk),
        .i_rst_n (i_rst_n),
        .i_valid (pipe_in),
        .i_op    (i_rs_issue.op),
        .i_rm    (i_rs_issue.rm),
        .i_src1  (i_rs_issue.src1_value),
        .i_src2  (i_rs_issue.src2_value),
        .i_src3  (i_rs_issue.src3_value),
        .o_valid (pipe_valid_unused),
        .o_result(pipe_result),
        .o_flags (pipe_flags)
    );
`endif

    // --- Tracker: entry k is the operation in the pipeline's register k+1 ---
    logic [PipeDepth-1:0] trk_valid, trk_flushed;
    logic [TagW-1:0] trk_tag[PipeDepth];

    always_ff @(posedge i_clk) begin
      if (!i_rst_n) begin
        trk_valid   <= '0;
        trk_flushed <= '0;
      end else if (i_flush) begin
        trk_valid   <= '0;
        trk_flushed <= '0;
      end else begin
        trk_valid[0] <= pipe_in;
        trk_flushed[0] <= pipe_in && i_flush_en && is_younger(
            i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag
        );
        for (int k = 1; k < PipeDepth; k++) begin
          trk_valid[k] <= trk_valid[k-1];
          trk_flushed[k] <= trk_valid[k-1] && (trk_flushed[k-1] || (i_flush_en && is_younger(
              trk_tag[k-1], i_flush_tag, i_rob_head_tag
          )));
        end
      end
    end

    always_ff @(posedge i_clk) begin
      trk_tag[0] <= i_rs_issue.rob_tag;
      for (int k = 1; k < PipeDepth; k++) trk_tag[k] <= trk_tag[k-1];
    end

    // Forward wake from the second-to-last entry; its result is the tail
    // register on the next cycle.
    assign o_fwd_wake_valid = trk_valid[PipeDepth-2] && !trk_flushed[PipeDepth-2];
    assign o_fwd_wake_tag   = trk_tag[PipeDepth-2];
    assign o_fwd_value      = pipe_result;

    // --- Result FIFO ---
    logic tail_live;
    logic tail_flush_young;
    assign tail_live = trk_valid[PipeDepth-1] && !trk_flushed[PipeDepth-1];
    assign tail_flush_young = i_flush_en && is_younger(
        trk_tag[PipeDepth-1], i_flush_tag, i_rob_head_tag
    );

    logic [TagW-1:0] fifo_tag[FifoDepth];
    logic [FifoDepth-1:0] fifo_flushed;
    logic [FifoAw-1:0] fifo_wr_ptr, fifo_rd_ptr;
    logic [FifoAw:0] fifo_count;
    logic fifo_push, fifo_pop, fifo_head_flushed, fifo_nonempty;
    logic [riscv_pkg::FLEN+5-1:0] fifo_rd_data;

    assign fifo_push = tail_live;
    assign fifo_nonempty = (fifo_count != '0);
    assign fifo_head_flushed = fifo_flushed[fifo_rd_ptr];
    assign fifo_pop = fifo_nonempty && (i_pipe_accepted || fifo_head_flushed);

    sdp_dist_ram #(
        .ADDR_WIDTH(FifoAw),
        .DATA_WIDTH(riscv_pkg::FLEN + 5)
    ) u_fifo_payload (
        .i_clk,
        .i_write_enable (fifo_push),
        .i_write_address(fifo_wr_ptr),
        .i_write_data   ({pipe_flags, pipe_result}),
        .i_read_address (fifo_rd_ptr),
        .o_read_data    (fifo_rd_data)
    );

    always_ff @(posedge i_clk) begin
      if (!i_rst_n || i_flush) begin
        fifo_flushed <= '0;
        fifo_wr_ptr  <= '0;
        fifo_rd_ptr  <= '0;
        fifo_count   <= '0;
      end else begin
        if (i_flush_en) begin
          for (int i = 0; i < FifoDepth; i++) begin
            if (is_younger(fifo_tag[i], i_flush_tag, i_rob_head_tag)) fifo_flushed[i] <= 1'b1;
          end
        end
        if (fifo_push) begin
          fifo_tag[fifo_wr_ptr] <= trk_tag[PipeDepth-1];
          fifo_flushed[fifo_wr_ptr] <= tail_flush_young;
          fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
        end
        if (fifo_pop) fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
        case ({
          fifo_push, fifo_pop
        })
          2'b10:   fifo_count <= fifo_count + 1'b1;
          2'b01:   fifo_count <= fifo_count - 1'b1;
          default: ;
        endcase
      end
    end

    // The registered flushed bit drops results a flush marked earlier; the
    // adapter filters a same-cycle flush. Payload is unspecified without valid.
    always_comb begin
      o_pipe_complete          = '0;
      o_pipe_complete.valid    = fifo_nonempty && !fifo_head_flushed;
      o_pipe_complete.tag      = fifo_tag[fifo_rd_ptr];
      o_pipe_complete.value    = fifo_rd_data[riscv_pkg::FLEN-1:0];
      o_pipe_complete.fp_flags = riscv_pkg::fp_flags_t'(fifo_rd_data[riscv_pkg::FLEN+:5]);
    end

    // --- Credit: tracker entries (flushed or not) plus FIFO entries ---
    // Registered from next-state counts: an issue is allowed only while the
    // occupancy after the edge leaves room for it, so every entry reaching
    // the tail finds a free FIFO slot.
    logic [$clog2(PipeDepth+1)-1:0] trk_next_count;
    logic [FifoAw:0] fifo_next_count;
    always_comb begin
      trk_next_count = $clog2(PipeDepth + 1)'(pipe_in);
      for (int k = 0; k < PipeDepth - 1; k++)
      trk_next_count = trk_next_count + $clog2(PipeDepth + 1)'(trk_valid[k]);
      fifo_next_count = fifo_count + (FifoAw + 1)'(fifo_push) - (FifoAw + 1)'(fifo_pop);
    end
    logic pipe_busy_q;
    always_ff @(posedge i_clk) begin
      if (!i_rst_n) pipe_busy_q <= 1'b0;
      else
        pipe_busy_q <= !i_flush &&
            ((FifoAw + 2)'(trk_next_count) + (FifoAw + 2)'(fifo_next_count) >=
             (FifoAw + 2)'(FifoDepth));
    end
    assign o_pipe_busy = pipe_busy_q;

    logic unused_pipe;
    assign unused_pipe = pipe_valid_unused;

`ifndef SYNTHESIS
`ifndef FORMAL
    always @(posedge i_clk) begin
      if (reset_seen_q && i_rst_n) begin
        if (pipe_in && pipe_busy_q)
          $error("fp_shim: pipelined issue of tag %0d without a credit", i_rs_issue.rob_tag);
        if (fifo_push && !fifo_pop && fifo_count == (FifoAw + 1)'(FifoDepth))
          $error("fp_shim: result FIFO overflow");
        if (trk_valid[PipeDepth-1] && !pipe_valid_unused)
          $error("fp_shim: tracker tail without a pipeline result");
      end
    end
`endif
`endif

`ifdef FORMAL
    // -------------------------------------------------------------------------
    // Pipelined-path properties
    // -------------------------------------------------------------------------
    // FIFO slot i holds an entry: its distance from the read pointer, taken
    // modulo the depth, is below the count.
    logic [FifoDepth-1:0] f_slot_used;
    always_comb begin
      for (int i = 0; i < FifoDepth; i++) begin
        logic [FifoAw-1:0] slot_off;
        slot_off = FifoAw'(i) - fifo_rd_ptr;
        f_slot_used[i] = {1'b0, slot_off} < fifo_count;
      end
    end

    // FP_RS presents a pipelined operation only with a credit, and never
    // with the tag of a live operation (ROB tags are unique while live).
    always_comb begin
      if (i_rst_n) assume (!pipe_in || !pipe_busy_q);
    end
    logic f_tag_live;
    always_comb begin
      f_tag_live = 1'b0;
      for (int k = 0; k < PipeDepth; k++)
      if (trk_valid[k] && !trk_flushed[k] && trk_tag[k] == i_rs_issue.rob_tag) f_tag_live = 1'b1;
      for (int i = 0; i < FifoDepth; i++)
      if (f_slot_used[i] && !fifo_flushed[i] && fifo_tag[i] == i_rs_issue.rob_tag)
        f_tag_live = 1'b1;
      if (i_rst_n) assume (!pipe_in || !f_tag_live);
    end

    logic [FifoAw+1:0] f_occupancy;
    always_comb begin
      f_occupancy = (FifoAw + 2)'(fifo_count);
      for (int k = 0; k < PipeDepth; k++) f_occupancy = f_occupancy + (FifoAw + 2)'(trk_valid[k]);
    end
    always_comb begin
      if (i_rst_n) begin
        p_occupancy_bound : assert (f_occupancy <= (FifoAw + 2)'(FifoDepth));
        p_no_fifo_overflow :
        assert (!(fifo_push && !fifo_pop && fifo_count == (FifoAw + 1)'(FifoDepth)));
        p_count_bound : assert (fifo_count <= (FifoAw + 1)'(FifoDepth));
        p_pointer_relation : assert (fifo_wr_ptr - fifo_rd_ptr == fifo_count[FifoAw-1:0]);
        p_flushed_only_valid : assert ((trk_flushed & ~trk_valid) == '0);
      end
    end

    // A ghost shift register of issues: every tracker entry is the issue
    // k + 1 cycles earlier with the same tag, flushed once covered.
    logic [PipeDepth-1:0] f_iss_valid;
    logic [TagW-1:0] f_iss_tag[PipeDepth];
    always @(posedge i_clk) begin
      if (!i_rst_n || i_flush) f_iss_valid <= '0;
      else f_iss_valid <= {f_iss_valid[PipeDepth-2:0], pipe_in};
      f_iss_tag[0] <= i_rs_issue.rob_tag;
      for (int k = 1; k < PipeDepth; k++) f_iss_tag[k] <= f_iss_tag[k-1];
    end
    always_comb begin
      if (i_rst_n) begin
        for (int k = 0; k < PipeDepth; k++) begin
          assert (trk_valid[k] == f_iss_valid[k]);  // tracker valid matches the issue
          if (trk_valid[k]) assert (trk_tag[k] == f_iss_tag[k]);  // and its tag
        end
      end
    end

    // The wake names the entry that reaches the tail next cycle.
    always @(posedge i_clk) begin
      if (f_past_valid && i_rst_n && $past(
              i_rst_n
          ) && $past(
              o_fwd_wake_valid
          ) && !$past(
              i_flush
          )) begin
        p_wake_then_tail :
        assert (trk_valid[PipeDepth-1] && trk_tag[PipeDepth-1] == $past(o_fwd_wake_tag));
      end
    end

    // A squashed pipelined operation never completes and never wakes until
    // a new issue reuses its tag.
    logic f_pwatch_live_issue, f_pwatch_squash, f_pwatch_dead_q;
    assign f_pwatch_live_issue = pipe_in && (i_rs_issue.rob_tag == f_watch_tag);
    assign f_pwatch_squash = (i_flush || (i_flush_en && is_younger(
        f_watch_tag, i_flush_tag, i_rob_head_tag
    ))) && (f_pwatch_live_issue || (|(trk_valid & ~trk_flushed)) || fifo_nonempty);
    always @(posedge i_clk) begin
      if (!i_rst_n) f_pwatch_dead_q <= 1'b0;
      else if (f_pwatch_squash) f_pwatch_dead_q <= 1'b1;
      else if (f_pwatch_live_issue) f_pwatch_dead_q <= 1'b0;
    end
    always_comb begin
      if (i_rst_n && f_pwatch_dead_q) begin
        p_pipe_no_stale_complete :
        assert (!(o_pipe_complete.valid && o_pipe_complete.tag == f_watch_tag &&
                                             !(i_flush_en && is_younger(
            f_watch_tag, i_flush_tag, i_rob_head_tag
        ))));
        p_pipe_no_stale_wake : assert (!(o_fwd_wake_valid && o_fwd_wake_tag == f_watch_tag));
      end
    end

    // An unsquashed issue completes exactly once: count completions of a
    // watched issue with an always-accepting adapter.
    logic [1:0] f_pwatch_done;
    logic f_pwatch_open;
    always @(posedge i_clk) begin
      if (!i_rst_n || f_pwatch_squash) begin
        f_pwatch_open <= 1'b0;
        f_pwatch_done <= '0;
      end else if (f_pwatch_live_issue) begin
        f_pwatch_open <= 1'b1;
        f_pwatch_done <= '0;
      end else if (f_pwatch_open && o_pipe_complete.valid && i_pipe_accepted &&
                   o_pipe_complete.tag == f_watch_tag && f_pwatch_done != 2'd3) begin
        f_pwatch_done <= f_pwatch_done + 2'd1;
      end
    end
    always_comb begin
      if (i_rst_n) p_pipe_at_most_once : assert (f_pwatch_done <= 2'd1);
    end

    // Inductive strengthening: live (unflushed) entries carrying the watched
    // tag, in the tracker and in the occupied FIFO slots.
    logic [4:0] f_live_watch;
    always_comb begin
      f_live_watch = '0;
      for (int k = 0; k < PipeDepth; k++)
      if (trk_valid[k] && !trk_flushed[k] && trk_tag[k] == f_watch_tag) f_live_watch += 5'd1;
      for (int i = 0; i < FifoDepth; i++)
      if (f_slot_used[i] && !fifo_flushed[i] && fifo_tag[i] == f_watch_tag) f_live_watch += 5'd1;
    end
    // Live tags are pairwise distinct (the issue assumption keeps them so).
    localparam int unsigned NLive = PipeDepth + FifoDepth;
    logic [NLive-1:0] f_live;
    logic [ TagW-1:0] f_live_tag[NLive];
    always_comb begin
      for (int k = 0; k < PipeDepth; k++) begin
        f_live[k] = trk_valid[k] && !trk_flushed[k];
        f_live_tag[k] = trk_tag[k];
      end
      for (int i = 0; i < FifoDepth; i++) begin
        f_live[PipeDepth+i] = f_slot_used[i] && !fifo_flushed[i];
        f_live_tag[PipeDepth+i] = fifo_tag[i];
      end
    end
    logic f_live_distinct;
    always_comb begin
      f_live_distinct = 1'b1;
      for (int a = 0; a < NLive; a++)
      for (int b = a + 1; b < NLive; b++)
      if (f_live[a] && f_live[b] && f_live_tag[a] == f_live_tag[b]) f_live_distinct = 1'b0;
    end
    always_comb begin
      if (i_rst_n) begin
        p_live_tags_distinct : assert (f_live_distinct);
        p_live_watch_unique : assert (f_live_watch <= 5'd1);
        if (f_pwatch_dead_q) p_dead_has_no_live : assert (f_live_watch == '0);
        if (f_pwatch_open && f_pwatch_done == '0) p_open_is_live : assert (f_live_watch == 5'd1);
        if (f_pwatch_done != '0) p_done_has_no_live : assert (f_live_watch == '0);
        if (!f_pwatch_open) p_closed_has_no_done : assert (f_pwatch_done == '0);
        if (!f_pwatch_open) p_closed_has_no_live : assert (f_live_watch == '0);
      end
    end

    always @(posedge i_clk) begin
      if (i_rst_n) begin
        cover_pipe_complete : cover (o_pipe_complete.valid && i_pipe_accepted);
        cover_pipe_busy : cover (pipe_busy_q);
        cover_pipe_wake : cover (o_fwd_wake_valid);
        cover_pipe_once : cover (f_pwatch_done == 2'd1);
        cover_pipe_flushed_head : cover (fifo_nonempty && fifo_head_flushed);
      end
    end
`endif
  end else begin : g_no_pipe
    assign o_pipe_complete  = '0;
    assign o_pipe_busy      = 1'b0;
    assign o_fwd_wake_valid = 1'b0;
    assign o_fwd_wake_tag   = '0;
    assign o_fwd_value      = '0;
    logic unused_no_pipe;
    assign unused_no_pipe = i_pipe_accepted;
  end

endmodule : fp_shim
