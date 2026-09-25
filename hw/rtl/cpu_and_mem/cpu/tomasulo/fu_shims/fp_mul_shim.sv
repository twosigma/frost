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
 * FP Multiply Shim (CDB Slot 5, FMUL_RS)
 *
 * Translates rs_issue_t from FMUL_RS into FPU subunit native ports and packs
 * their results into fu_complete_t for the CDB adapter. Both subunits are
 * fully pipelined and accept one operation per cycle:
 *   - fpu_mult_unit: FMUL_S/D (11 cycles)
 *   - fpu_fma_unit:  FMADD/FMSUB/FNMADD/FNMSUB S/D (16 cycles)
 *
 * Each subunit completes in issue order, so its ROB tags wait in a 16-entry
 * circular queue. Completions enter a shared 16-entry ordering ring (the
 * fifo_* arrays: tag, source subunit, flush state) that presents its head
 * until the adapter takes it; each subunit's value and flags wait in its own
 * block-RAM FIFO. o_fu_busy rises when the tag queues and the ring together
 * reach 14 entries, which keeps each queue and the ring at 14 entries or
 * fewer, so nothing can overflow.
 *
 * A squashed operation still runs to the end of its subunit and is dropped
 * there. A full flush empties the ring; a partial flush marks the squashed
 * ring entries, which are skipped when they reach the head.
 *
 * The wrapper feeds this shim a flush registered one cycle late; its adapter
 * covers the flush cycle itself (fu_shims README, "Flushes").
 *
 * FMA operand mapping: a=src1, b=src2, c=src3
 *   FMADD:  negate_product=0, negate_c=0  → a*b + c
 *   FMSUB:  negate_product=0, negate_c=1  → a*b - c
 *   FNMSUB: negate_product=1, negate_c=0  → -(a*b) + c = c - a*b
 *   FNMADD: negate_product=1, negate_c=1  → -(a*b) - c
 */
module fp_mul_shim (
    input logic i_clk,
    input logic i_rst_n,

    // From FMUL_RS (issue output)
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
    input logic i_mul_accepted
);

  localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;

  function automatic logic [31:0] unbox32(input logic [FLEN-1:0] value);
    unbox32 = (&value[FLEN-1:32]) ? value[31:0] : riscv_pkg::FpCanonicalNan;
  endfunction

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
  logic use_mult, use_fma;
  logic op_is_double;
  logic negate_product, negate_c;

  always_comb begin
    use_mult       = 1'b0;
    use_fma        = 1'b0;
    op_is_double   = 1'b0;
    negate_product = 1'b0;
    negate_c       = 1'b0;

    case (i_rs_issue.op)
      riscv_pkg::FMUL_S: use_mult = 1'b1;
      riscv_pkg::FMUL_D: begin
        use_mult = 1'b1;
        op_is_double = 1'b1;
      end

      riscv_pkg::FMADD_S: use_fma = 1'b1;
      riscv_pkg::FMADD_D: begin
        use_fma = 1'b1;
        op_is_double = 1'b1;
      end

      riscv_pkg::FMSUB_S: begin
        use_fma  = 1'b1;
        negate_c = 1'b1;
      end
      riscv_pkg::FMSUB_D: begin
        use_fma = 1'b1;
        op_is_double = 1'b1;
        negate_c = 1'b1;
      end

      riscv_pkg::FNMSUB_S: begin
        use_fma = 1'b1;
        negate_product = 1'b1;
      end
      riscv_pkg::FNMSUB_D: begin
        use_fma = 1'b1;
        op_is_double = 1'b1;
        negate_product = 1'b1;
      end

      riscv_pkg::FNMADD_S: begin
        use_fma = 1'b1;
        negate_product = 1'b1;
        negate_c = 1'b1;
      end
      riscv_pkg::FNMADD_D: begin
        use_fma = 1'b1;
        op_is_double = 1'b1;
        negate_product = 1'b1;
        negate_c = 1'b1;
      end

      default: ;
    endcase
  end

  // Operand extraction
  wire [31:0] src1_s = unbox32(i_rs_issue.src1_value);
  wire [31:0] src2_s = unbox32(i_rs_issue.src2_value);
  wire [31:0] src3_s = unbox32(i_rs_issue.src3_value);
  wire [63:0] src1_d = i_rs_issue.src1_value;
  wire [63:0] src2_d = i_rs_issue.src2_value;
  wire [63:0] src3_d = i_rs_issue.src3_value;

  // ===========================================================================
  // Multi-in-flight metadata and result FIFO
  // ===========================================================================
  // mul_busy caps the tag queues plus the ring at ResultFifoDepth - 2
  // entries, so a tag queue as deep as the ring never fills.
  localparam int unsigned ResultFifoDepth = 16;
  localparam int unsigned QueueDepth = ResultFifoDepth;
  localparam int unsigned QueuePtrW = $clog2(QueueDepth);
  localparam int unsigned QueueCountW = $clog2(QueueDepth + 1);
  localparam int unsigned FifoPtrW = $clog2(ResultFifoDepth);
  localparam int unsigned FifoCountW = $clog2(ResultFifoDepth + 1);
  localparam int unsigned FlagsW = 5;  // fp_flags_t width
  localparam int unsigned PayloadW = FLEN + FlagsW;
  localparam int unsigned CreditCountW = $clog2((2 * QueueDepth) + ResultFifoDepth + 1);

  logic fire, fire_mult, fire_fma;
  logic mul_busy;

  assign fire = i_rs_issue.valid & (use_mult | use_fma) & ~mul_busy;
  assign fire_mult = fire & use_mult;
  assign fire_fma = fire & use_fma;

  logic mult_valid_out, fma_valid_out;

  logic [       TagW-1:0] mult_tag_q        [     QueueDepth];
  logic                   mult_flushed_q    [     QueueDepth];
  logic                   mult_valid_q      [     QueueDepth];
  // The head pointers drive the tag read, the partial-flush age compare, and
  // the completion-valid logic that gates the whole result FIFO, so they fan
  // out widely. The fanout cap lets synthesis replicate these small counters
  // per consumer group.
  (* max_fanout = 32 *)logic [  QueuePtrW-1:0] mult_rd_ptr;
  logic [  QueuePtrW-1:0] mult_wr_ptr;
  logic [QueueCountW-1:0] mult_count;

  logic [       TagW-1:0] fma_tag_q         [     QueueDepth];
  logic                   fma_flushed_q     [     QueueDepth];
  logic                   fma_valid_q       [     QueueDepth];
  (* max_fanout = 32 *)logic [  QueuePtrW-1:0] fma_rd_ptr;
  logic [  QueuePtrW-1:0] fma_wr_ptr;
  logic [QueueCountW-1:0] fma_count;

  logic [       TagW-1:0] fifo_tag          [ResultFifoDepth];
  logic                   fifo_source_is_fma[ResultFifoDepth];
  logic                   fifo_valid        [ResultFifoDepth];
  logic                   fifo_flushed      [ResultFifoDepth];
  // Read pointer capped like the queue head pointers above (output read mux).
  (* max_fanout = 32 *)logic [   FifoPtrW-1:0] fifo_rd_ptr;
  logic [   FifoPtrW-1:0] fifo_wr_ptr;
  logic [ FifoCountW-1:0] fifo_count;

  // The shared ring above holds only ordering and flush metadata. Payloads are
  // kept in one block-RAM FIFO per producer, so neither 69-bit result bus has
  // to route into every slot of a shared flip-flop array. The ring head's
  // source bit selects which producer's payload head to present.
  logic [FifoPtrW-1:0] mult_payload_rd_ptr, mult_payload_wr_ptr;
  logic [FifoPtrW-1:0] fma_payload_rd_ptr, fma_payload_wr_ptr;
  logic [FifoPtrW-1:0] mult_payload_read_addr, fma_payload_read_addr;
  logic [PayloadW-1:0] mult_payload_head, fma_payload_head;
  logic [    PayloadW-1:0] fifo_head_payload;
  logic [    PayloadW-1:0] head_bypass_q;
  logic                    head_bypass_valid_q;

  logic [CreditCountW-1:0] total_occupancy;
  assign total_occupancy = CreditCountW'(mult_count) + CreditCountW'(fma_count) +
                           CreditCountW'(fifo_count);
  assign mul_busy = total_occupancy >= CreditCountW'(ResultFifoDepth - 2);
  assign o_fu_busy = mul_busy;

  // ===========================================================================
  // Subunit: Multiplier (FMUL S/D)
  // ===========================================================================
  logic [FLEN-1:0] mult_result;
  riscv_pkg::fp_flags_t mult_flags;
  logic mult_busy;

  fpu_mult_unit u_mult (
      .i_clk          (i_clk),
      .i_rst          (~i_rst_n),
      .i_valid        (fire & use_mult),
      .i_use_unit     (use_mult),
      .i_op_is_double (op_is_double),
      .i_operand_a_s  (src1_s),
      .i_operand_b_s  (src2_s),
      .i_operand_a_d  (src1_d),
      .i_operand_b_d  (src2_d),
      .i_rounding_mode(i_rs_issue.rm),
      .i_dest_reg     (5'b0),
      .o_result       (mult_result),
      .o_valid        (mult_valid_out),
      .o_flags        (mult_flags),
      .o_busy         (mult_busy),
      .o_dest_reg     (),
      .o_start        ()
  );

  // ===========================================================================
  // Subunit: FMA (FMADD/FMSUB/FNMADD/FNMSUB S/D)
  // ===========================================================================
  logic [FLEN-1:0] fma_result;
  riscv_pkg::fp_flags_t fma_flags;
  logic fma_busy;

  fpu_fma_unit u_fma (
      .i_clk           (i_clk),
      .i_rst           (~i_rst_n),
      .i_valid         (fire & use_fma),
      .i_use_unit      (use_fma),
      .i_op_is_double  (op_is_double),
      .i_operand_a_s   (src1_s),
      .i_operand_b_s   (src2_s),
      .i_operand_c_s   (src3_s),
      .i_operand_a_d   (src1_d),
      .i_operand_b_d   (src2_d),
      .i_operand_c_d   (src3_d),
      .i_negate_product(negate_product),
      .i_negate_c      (negate_c),
      .i_rounding_mode (i_rs_issue.rm),
      .i_dest_reg      (5'b0),
      .o_result        (fma_result),
      .o_valid         (fma_valid_out),
      .o_flags         (fma_flags),
      .o_busy          (fma_busy),
      .o_dest_reg      (),
      .o_start         ()
  );

  // ===========================================================================
  // Completion handling and output FIFO
  // ===========================================================================
  logic mult_pop, fma_pop;
  logic mult_head_partial_flushing, fma_head_partial_flushing;
  logic mult_completion_valid, fma_completion_valid;

  assign mult_pop = mult_valid_out && (mult_count != '0);
  assign fma_pop = fma_valid_out && (fma_count != '0);

  assign mult_head_partial_flushing = mult_pop && i_flush_en && is_younger(
      mult_tag_q[mult_rd_ptr], i_flush_tag, i_rob_head_tag
  );
  assign fma_head_partial_flushing = fma_pop && i_flush_en && is_younger(
      fma_tag_q[fma_rd_ptr], i_flush_tag, i_rob_head_tag
  );

  assign mult_completion_valid = mult_pop && !i_flush &&
      !mult_flushed_q[mult_rd_ptr] && !mult_head_partial_flushing;
  assign fma_completion_valid = fma_pop && !i_flush &&
      !fma_flushed_q[fma_rd_ptr] && !fma_head_partial_flushing;

  logic [1:0] fifo_push_count;
  assign fifo_push_count = {1'b0, mult_completion_valid} + {1'b0, fma_completion_valid};

  logic fifo_head_partial_flushing;
  logic fifo_head_flushed;
  logic fifo_pop;
  logic mult_payload_pop, fma_payload_pop;
  logic fifo_push_becomes_head;
  logic [PayloadW-1:0] first_push_payload;

  assign fifo_head_partial_flushing = (fifo_count != '0) &&
      !fifo_flushed[fifo_rd_ptr] && i_flush_en &&
      is_younger(
      fifo_tag[fifo_rd_ptr], i_flush_tag, i_rob_head_tag
  );
  assign fifo_head_flushed = (fifo_count != '0) &&
      (fifo_flushed[fifo_rd_ptr] || fifo_head_partial_flushing);
  assign fifo_pop = (fifo_count != '0) && (i_mul_accepted || fifo_head_flushed);

  assign mult_payload_pop = fifo_pop && !fifo_source_is_fma[fifo_rd_ptr];
  assign fma_payload_pop = fifo_pop && fifo_source_is_fma[fifo_rd_ptr];

  // Prefetch the post-pop producer heads. The block-RAM output registers load
  // these addresses on the same edge that advances the local read pointers,
  // which lets one result leave the ring every cycle.
  // Compute the increment before the late acceptance/flush result. Each final
  // address bit uses just the two precomputed pointer bits, producer
  // permission, acceptance and flush: at most one LUT5 after either late event.
  (* keep = "true" *) logic [FifoPtrW-1:0] mult_payload_next_ptr, fma_payload_next_ptr;
  (* keep = "true" *) logic mult_payload_pop_permission, fma_payload_pop_permission;
  assign mult_payload_next_ptr = mult_payload_rd_ptr + FifoPtrW'(1);
  assign fma_payload_next_ptr = fma_payload_rd_ptr + FifoPtrW'(1);
  assign mult_payload_pop_permission = (fifo_count != '0) && !fifo_source_is_fma[fifo_rd_ptr];
  assign fma_payload_pop_permission = (fifo_count != '0) && fifo_source_is_fma[fifo_rd_ptr];
  assign mult_payload_read_addr =
      ((i_mul_accepted || fifo_head_flushed) && mult_payload_pop_permission) ?
      mult_payload_next_ptr : mult_payload_rd_ptr;
  assign fma_payload_read_addr =
      ((i_mul_accepted || fifo_head_flushed) && fma_payload_pop_permission) ?
      fma_payload_next_ptr : fma_payload_rd_ptr;

`ifdef FP_PAYLOAD_READ_LOCAL_PROOF
  always_comb begin
    assert (mult_payload_read_addr == mult_payload_rd_ptr + FifoPtrW'(mult_payload_pop));
    assert (fma_payload_read_addr == fma_payload_rd_ptr + FifoPtrW'(fma_payload_pop));
  end
`endif

  // A synchronous RAM cannot expose an empty-queue push on the write edge, and
  // its read-during-write value is primitive-dependent. Bypass the first push
  // whenever it becomes the new shared head: either an empty handoff or a
  // one-entry pop/refill. On the following edge the RAM prefetch has caught up.
  assign fifo_push_becomes_head = (fifo_push_count != '0) && (fifo_count == FifoCountW'(fifo_pop));
  assign first_push_payload = mult_completion_valid ?
      {mult_flags, mult_result} : {fma_flags, fma_result};

  sdp_block_ram #(
      .ADDR_WIDTH(FifoPtrW),
      .DATA_WIDTH(PayloadW)
  ) u_mult_payload_ram (
      .i_clk          (i_clk),
      .i_write_enable (mult_completion_valid),
      .i_bulk_clear   (1'b0),
      .i_write_address(mult_payload_wr_ptr),
      .i_read_address (mult_payload_read_addr),
      .i_write_data   ({mult_flags, mult_result}),
      .o_read_data    (mult_payload_head)
  );

  sdp_block_ram #(
      .ADDR_WIDTH(FifoPtrW),
      .DATA_WIDTH(PayloadW)
  ) u_fma_payload_ram (
      .i_clk          (i_clk),
      .i_write_enable (fma_completion_valid),
      .i_bulk_clear   (1'b0),
      .i_write_address(fma_payload_wr_ptr),
      .i_read_address (fma_payload_read_addr),
      .i_write_data   ({fma_flags, fma_result}),
      .o_read_data    (fma_payload_head)
  );

  assign fifo_head_payload = head_bypass_valid_q ? head_bypass_q :
      (fifo_source_is_fma[fifo_rd_ptr] ? fma_payload_head : mult_payload_head);

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      mult_rd_ptr <= '0;
      mult_wr_ptr <= '0;
      mult_count  <= '0;
      fma_rd_ptr  <= '0;
      fma_wr_ptr  <= '0;
      fma_count   <= '0;
      for (int i = 0; i < QueueDepth; i++) begin
        mult_valid_q[i]   <= 1'b0;
        mult_flushed_q[i] <= 1'b0;
        fma_valid_q[i]    <= 1'b0;
        fma_flushed_q[i]  <= 1'b0;
      end
    end else begin
      if (i_flush) begin
        for (int i = 0; i < QueueDepth; i++) begin
          if (mult_valid_q[i]) mult_flushed_q[i] <= 1'b1;
          if (fma_valid_q[i]) fma_flushed_q[i] <= 1'b1;
        end
      end else if (i_flush_en) begin
        for (int i = 0; i < QueueDepth; i++) begin
          if (mult_valid_q[i] && !mult_flushed_q[i] && is_younger(
                  mult_tag_q[i], i_flush_tag, i_rob_head_tag
              )) begin
            mult_flushed_q[i] <= 1'b1;
          end
          if (fma_valid_q[i] && !fma_flushed_q[i] && is_younger(
                  fma_tag_q[i], i_flush_tag, i_rob_head_tag
              )) begin
            fma_flushed_q[i] <= 1'b1;
          end
        end
      end

      if (mult_pop) begin
        mult_valid_q[mult_rd_ptr] <= 1'b0;
        mult_flushed_q[mult_rd_ptr] <= 1'b0;
        mult_rd_ptr <= mult_rd_ptr + 1'b1;
      end
      if (fma_pop) begin
        fma_valid_q[fma_rd_ptr] <= 1'b0;
        fma_flushed_q[fma_rd_ptr] <= 1'b0;
        fma_rd_ptr <= fma_rd_ptr + 1'b1;
      end

      if (fire_mult) begin
        mult_valid_q[mult_wr_ptr] <= 1'b1;
        mult_tag_q[mult_wr_ptr] <= i_rs_issue.rob_tag;
        mult_flushed_q[mult_wr_ptr] <= i_flush || (i_flush_en && is_younger(
            i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag
        ));
        mult_wr_ptr <= mult_wr_ptr + 1'b1;
      end
      if (fire_fma) begin
        fma_valid_q[fma_wr_ptr] <= 1'b1;
        fma_tag_q[fma_wr_ptr] <= i_rs_issue.rob_tag;
        fma_flushed_q[fma_wr_ptr] <= i_flush || (i_flush_en && is_younger(
            i_rs_issue.rob_tag, i_flush_tag, i_rob_head_tag
        ));
        fma_wr_ptr <= fma_wr_ptr + 1'b1;
      end

      case ({
        fire_mult, mult_pop
      })
        2'b10:   mult_count <= mult_count + 1'b1;
        2'b01:   mult_count <= mult_count - 1'b1;
        default: mult_count <= mult_count;
      endcase
      case ({
        fire_fma, fma_pop
      })
        2'b10:   fma_count <= fma_count + 1'b1;
        2'b01:   fma_count <= fma_count - 1'b1;
        default: fma_count <= fma_count;
      endcase
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush) begin
      mult_payload_rd_ptr <= '0;
      mult_payload_wr_ptr <= '0;
      fma_payload_rd_ptr  <= '0;
      fma_payload_wr_ptr  <= '0;
      head_bypass_valid_q <= 1'b0;
    end else begin
      if (mult_payload_pop) mult_payload_rd_ptr <= mult_payload_rd_ptr + 1'b1;
      if (mult_completion_valid) mult_payload_wr_ptr <= mult_payload_wr_ptr + 1'b1;
      if (fma_payload_pop) fma_payload_rd_ptr <= fma_payload_rd_ptr + 1'b1;
      if (fma_completion_valid) fma_payload_wr_ptr <= fma_payload_wr_ptr + 1'b1;

      head_bypass_valid_q <= fifo_push_becomes_head;
      if (fifo_push_becomes_head) head_bypass_q <= first_push_payload;
    end
  end

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      fifo_rd_ptr <= '0;
      fifo_wr_ptr <= '0;
      fifo_count  <= '0;
      for (int i = 0; i < ResultFifoDepth; i++) begin
        fifo_valid[i]   <= 1'b0;
        fifo_flushed[i] <= 1'b0;
      end
    end else if (i_flush) begin
      fifo_rd_ptr <= '0;
      fifo_wr_ptr <= '0;
      fifo_count  <= '0;
      for (int i = 0; i < ResultFifoDepth; i++) begin
        fifo_valid[i]   <= 1'b0;
        fifo_flushed[i] <= 1'b0;
      end
    end else begin
      if (i_flush_en) begin
        for (int i = 0; i < ResultFifoDepth; i++) begin
          if (fifo_valid[i] && !fifo_flushed[i] && is_younger(
                  fifo_tag[i], i_flush_tag, i_rob_head_tag
              )) begin
            fifo_flushed[i] <= 1'b1;
          end
        end
      end

      if (fifo_pop) begin
        fifo_valid[fifo_rd_ptr] <= 1'b0;
        fifo_flushed[fifo_rd_ptr] <= 1'b0;
        fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
      end

      // Decode-form pushes keep the entry select in local enables. The two push
      // slots can never target the same entry (the FMA slot lands at wr_ptr +
      // mult_completion_valid). Payloads are written to the producer-local RAMs
      // above in the same cycle.
      for (int unsigned i = 0; i < ResultFifoDepth; i++) begin
        if (mult_completion_valid && (fifo_wr_ptr == FifoPtrW'(i))) begin
          fifo_valid[i]         <= 1'b1;
          fifo_flushed[i]       <= 1'b0;
          fifo_tag[i]           <= mult_tag_q[mult_rd_ptr];
          fifo_source_is_fma[i] <= 1'b0;
        end
        if (fma_completion_valid &&
            ((fifo_wr_ptr + FifoPtrW'(mult_completion_valid)) == FifoPtrW'(i))) begin
          fifo_valid[i]         <= 1'b1;
          fifo_flushed[i]       <= 1'b0;
          fifo_tag[i]           <= fma_tag_q[fma_rd_ptr];
          fifo_source_is_fma[i] <= 1'b1;
        end
      end

      fifo_wr_ptr <= fifo_wr_ptr + FifoPtrW'(fifo_push_count);

      case ({
        fifo_push_count, fifo_pop
      })
        3'b000:  fifo_count <= fifo_count;
        3'b001:  fifo_count <= fifo_count - 1'b1;
        3'b010:  fifo_count <= fifo_count + 1'b1;
        3'b011:  fifo_count <= fifo_count;
        3'b100:  fifo_count <= fifo_count + FifoCountW'(2);
        3'b101:  fifo_count <= fifo_count + 1'b1;
        default: fifo_count <= fifo_count;
      endcase
    end
  end

  always_comb begin
    if ((fifo_count != '0) && !fifo_flushed[fifo_rd_ptr] && !fifo_head_partial_flushing) begin
      o_fu_complete.valid     = 1'b1;
      o_fu_complete.tag       = fifo_tag[fifo_rd_ptr];
      o_fu_complete.value     = fifo_head_payload[FLEN-1:0];
      o_fu_complete.exception = 1'b0;
      o_fu_complete.exc_cause = riscv_pkg::exc_cause_t'('0);
      o_fu_complete.fp_flags  = riscv_pkg::fp_flags_t'(fifo_head_payload[PayloadW-1:FLEN]);
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
  // Formal Verification
  // ===========================================================================
`ifdef FORMAL
`ifndef FP_PAYLOAD_READ_LOCAL_PROOF

  initial assume (!i_rst_n);

  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // Ghost occupancy counters prove that every shared source token has exactly
  // one payload in the corresponding producer-local RAM FIFO. They elaborate
  // only for formal and add no implementation state.
  logic [FifoCountW-1:0] f_mult_payload_count, f_fma_payload_count;
  logic [FifoCountW-1:0] f_mult_source_tokens, f_fma_source_tokens;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush) begin
      f_mult_payload_count <= '0;
      f_fma_payload_count  <= '0;
    end else begin
      case ({
        mult_completion_valid, mult_payload_pop
      })
        2'b10:   f_mult_payload_count <= f_mult_payload_count + 1'b1;
        2'b01:   f_mult_payload_count <= f_mult_payload_count - 1'b1;
        default: f_mult_payload_count <= f_mult_payload_count;
      endcase
      case ({
        fma_completion_valid, fma_payload_pop
      })
        2'b10:   f_fma_payload_count <= f_fma_payload_count + 1'b1;
        2'b01:   f_fma_payload_count <= f_fma_payload_count - 1'b1;
        default: f_fma_payload_count <= f_fma_payload_count;
      endcase
    end
  end

  always_comb begin
    f_mult_source_tokens = '0;
    f_fma_source_tokens  = '0;
    for (int i = 0; i < ResultFifoDepth; i++) begin
      if (fifo_valid[i] && fifo_source_is_fma[i]) begin
        f_fma_source_tokens = f_fma_source_tokens + 1'b1;
      end else if (fifo_valid[i]) begin
        f_mult_source_tokens = f_mult_source_tokens + 1'b1;
      end
    end
  end

  always @(posedge i_clk) begin
    if (f_past_valid) assume (i_rst_n);
  end

  always_comb begin
    if (i_rst_n) begin
      p_mult_count_in_range : assert (mult_count <= QueueCountW'(QueueDepth));
      p_fma_count_in_range : assert (fma_count <= QueueCountW'(QueueDepth));
      p_fifo_count_in_range : assert (fifo_count <= FifoCountW'(ResultFifoDepth));
      p_total_occupancy_within_credits :
      assert (total_occupancy <= CreditCountW'(ResultFifoDepth - 2));
      p_payload_count_matches_fifo :
      assert (f_mult_payload_count + f_fma_payload_count == fifo_count);
      p_mult_payload_count_matches_sources : assert (f_mult_payload_count == f_mult_source_tokens);
      p_fma_payload_count_matches_sources : assert (f_fma_payload_count == f_fma_source_tokens);
      p_mult_payload_pointer_distance :
      assert (mult_payload_wr_ptr - mult_payload_rd_ptr == f_mult_payload_count[FifoPtrW-1:0]);
      p_fma_payload_pointer_distance :
      assert (fma_payload_wr_ptr - fma_payload_rd_ptr == f_fma_payload_count[FifoPtrW-1:0]);
    end
  end

`ifdef FP_MUL_SHIM_TAG_ORDER_PROOF
  // Tag order. f_pick (a free input) selects one issued operation, and the
  // ghost state below follows it: first through its subunit's tag queue, then,
  // if it completes, through the shared ring. f_queue_ahead and f_ring_ahead
  // count the older entries in front of it. When everything older has left a
  // queue or the ring, its tag must be at the head: the subunit queue pops it
  // in the cycle its own result leaves the subunit (f_age, at the fixed
  // latencies in the fp_multiplier and fp_fma headers), and the ring presents
  // it with its tag and source. Since f_pick is arbitrary, this holds for every
  // operation. A full flush empties the ring; in the tag queue the operation
  // still pops in order, marked flushed.
  localparam int unsigned FMultCycles = 11;
  localparam int unsigned FFmaCycles = 16;
  (* anyseq *) logic f_pick;
  logic f_armed, f_in_queue, f_in_ring, f_fma;
  logic [TagW-1:0] f_tag;
  logic [4:0] f_age;
  logic [QueueCountW-1:0] f_queue_ahead;
  logic [FifoCountW-1:0] f_ring_ahead;
  logic f_queue_pop;

  assign f_queue_pop = f_in_queue && (f_fma ? fma_pop : mult_pop);

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      f_armed    <= 1'b0;
      f_in_queue <= 1'b0;
      f_in_ring  <= 1'b0;
    end else begin
      if (!f_armed && f_pick && fire) begin
        f_armed <= 1'b1;
        f_in_queue <= 1'b1;
        f_fma <= use_fma;
        f_tag <= i_rs_issue.rob_tag;
        f_age <= 5'd1;
        f_queue_ahead <= use_fma ? fma_count - QueueCountW'(fma_pop) :
                                   mult_count - QueueCountW'(mult_pop);
      end
      if (f_in_queue) f_age <= f_age + 5'd1;
      if (f_queue_pop) begin
        if (f_queue_ahead == '0) begin
          f_in_queue <= 1'b0;
          if (f_fma ? fma_completion_valid : mult_completion_valid) begin
            f_in_ring <= 1'b1;
            f_ring_ahead <= fifo_count - FifoCountW'(fifo_pop) +
                FifoCountW'(f_fma && mult_completion_valid);
          end
        end else begin
          f_queue_ahead <= f_queue_ahead - 1'b1;
        end
      end
      if (f_in_ring) begin
        if (i_flush || (fifo_pop && (f_ring_ahead == '0))) f_in_ring <= 1'b0;
        else if (fifo_pop) f_ring_ahead <= f_ring_ahead - 1'b1;
      end
    end
  end

  always_comb begin
    if (i_rst_n && f_queue_pop && (f_queue_ahead == '0)) begin
      p_tracked_queue_head :
      assert ((f_fma ? fma_tag_q[fma_rd_ptr] : mult_tag_q[mult_rd_ptr]) == f_tag);
      p_tracked_pop_at_own_result :
      assert (f_age == 5'(f_fma ? FFmaCycles : FMultCycles));
    end
    if (i_rst_n && f_in_ring && (f_ring_ahead == '0)) begin
      p_tracked_ring_head :
      assert (fifo_count != '0 && fifo_tag[fifo_rd_ptr] == f_tag &&
              fifo_source_is_fma[fifo_rd_ptr] == f_fma);
      if (!fifo_head_flushed) begin
        p_tracked_ring_head_presents : assert (o_fu_complete.valid && o_fu_complete.tag == f_tag);
      end
    end
  end

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_tracked_mult_leaves_ring :
      cover (f_in_ring && !f_fma && (f_ring_ahead == '0) && fifo_pop && !fifo_head_flushed);
      cover_tracked_fma_leaves_ring :
      cover (f_in_ring && f_fma && (f_ring_ahead == '0) && fifo_pop && !fifo_head_flushed);
      cover_tracked_behind_older : cover (f_in_ring && (f_ring_ahead != '0) && fifo_pop);
    end
  end
`endif

  always @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_fire_mult : cover (fire && use_mult);
      cover_fire_fma : cover (fire && use_fma);
      cover_complete : cover (o_fu_complete.valid);
      cover_two_completions : cover (mult_completion_valid && fma_completion_valid);
    end
  end

`endif  // FP_PAYLOAD_READ_LOCAL_PROOF
`endif  // FORMAL

endmodule : fp_mul_shim
