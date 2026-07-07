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
 * parcel_queue -- the stage-2 front end's instruction-entry FIFO
 * (PARCEL_QUEUE_DESIGN.md section 2.2).  Scaffolding: built and unit-tested,
 * not yet instantiated (landing step A).
 *
 * The fill engine enqueues up to two pq_entry_t per cycle (a walked bundle,
 * prediction metadata already bound); the consume engine reads the two
 * oldest entries and dequeues what it emits.  Entries are immutable once
 * enqueued and valid in FIFO order, so occupancy is a single count -- no
 * per-entry valid bits, no tags.
 *
 * FIRST-WORD-FALL-THROUGH: the presented view is the first two entries of
 * (array contents, then this cycle's incoming enqueue).  On an empty (or
 * one-deep) queue the consumer therefore sees arriving entries
 * combinationally, which is what keeps every flushing-redirect refill at
 * today's latency (design section 2.2 / review record finding 2).  Bypassed
 * entries are still written to the array; the head pointer simply advances
 * past whatever the consumer took, so the bypass adds no control state.
 *
 * FLUSH SEMANTICS (both dominate same-cycle enqueue -- the atomic pointer
 * update alone empties the window, so no wrong-path phantom entry can survive
 * even though the mem_q content write is unconditional; review record finding 4):
 *   - full (backend branch / trap / MRET / FENCE.I / PD redirect):
 *     head = tail = 0, count = 0.
 *   - partial (RAS consume redirect, a dequeue-fire pulse: the head return
 *     entry emits this cycle, every younger entry dies):
 *     head = tail = head + deq_count, count = 0.
 *   Full wins when both fire (the backend redirect outranks the RAS
 *   redirect in the section 2.5 matrix).
 *
 * BACKPRESSURE: o_backpressure asserts while fewer than HEADROOM slots are
 * free.  HEADROOM covers the provider seam's in-flight window plus its
 * registered-backpressure lag (up to two entries each; design section 7.1),
 * so the fill engine can treat it as "hold the ask" without ever overrunning
 * the array.
 */
module parcel_queue #(
    parameter int unsigned DEPTH = 8,  // power of two
    parameter int unsigned HEADROOM = 4
) (
    input logic i_clk,
    input logic i_rst,

    // Enqueue (fill engine).  i_enq_valid[1] implies i_enq_valid[0].
    input logic [1:0] i_enq_valid,
    input riscv_pkg::pq_entry_t i_enq_entry0,
    input riscv_pkg::pq_entry_t i_enq_entry1,

    // Dequeue (consume engine): how many presented entries were emitted this
    // cycle.  Must not exceed the number presented.
    input logic [1:0] i_deq_count,

    // Flushes (section 2.5 redirect matrix).
    input logic i_flush_full,
    input logic i_flush_partial,

    // Presented view (combinational, first-word-fall-through).
    output logic [1:0] o_entry_valid,
    output riscv_pkg::pq_entry_t o_entry0,
    output riscv_pkg::pq_entry_t o_entry1,

    // Occupancy (registered count) and the fill-side hold request.
    output logic [$clog2(DEPTH+1)-1:0] o_count,
    output logic o_backpressure
);

  localparam int unsigned PtrBits = $clog2(DEPTH);
  localparam int unsigned CntBits = $clog2(DEPTH + 1);

  riscv_pkg::pq_entry_t mem_q[DEPTH];
  logic [PtrBits-1:0] head_q;
  logic [PtrBits-1:0] tail_q;
  logic [CntBits-1:0] count_q;

  // ===========================================================================
  // Presented view: first two of (array in FIFO order, then incoming enqueue)
  // ===========================================================================
  logic [PtrBits-1:0] head_p1;
  assign head_p1 = head_q + PtrBits'(1);

  logic array_has_1, array_has_2;
  assign array_has_1 = count_q != '0;
  assign array_has_2 = count_q >= CntBits'(2);

  assign o_entry_valid[0] = array_has_1 || i_enq_valid[0];
  assign o_entry_valid[1] = array_has_2 || (array_has_1 && i_enq_valid[0]) ||
      (!array_has_1 && i_enq_valid[1]);

  assign o_entry0 = array_has_1 ? mem_q[head_q] : i_enq_entry0;
  assign o_entry1 = array_has_2 ? mem_q[head_p1] : (array_has_1 ? i_enq_entry0 : i_enq_entry1);

  // ===========================================================================
  // Occupancy / backpressure
  // ===========================================================================
  assign o_count = count_q;
  // Free slots below the headroom -> hold the ask.  Combinational off the
  // registered count only; HEADROOM absorbs the seam's in-flight window and
  // registered lag (up to 2 entries each).
  assign o_backpressure = (CntBits'(DEPTH) - count_q) < CntBits'(HEADROOM);

  // ===========================================================================
  // Pointer / count / storage update
  // ===========================================================================
  logic [1:0] enq_count;
  assign enq_count = {1'b0, i_enq_valid[0]} + {1'b0, i_enq_valid[1]};

  logic flush_any;
  assign flush_any = i_flush_full || i_flush_partial;

  logic [PtrBits-1:0] tail_p1;
  assign tail_p1 = tail_q + PtrBits'(1);

  always_ff @(posedge i_clk) begin
    // x3 TIMING: the mem_q write is intentionally NOT gated by flush.
    // Reachability of a written slot is guaranteed solely by the atomic count
    // reset below (count_q<='0 on any flush): a slot becomes readable only after
    // tail advances past it -- which happens on the same real enqueue that wrote
    // it with correct data -- and every flush empties the window, so a
    // speculative wrong-path write at the old tail is always either overwritten
    // before it is counted or left outside [head, tail).  The write DATA
    // (i_enq_entry*) is stall-independent, so dropping the !flush_any gate takes
    // frontend_stall (which reaches flush via the RAS partial-redirect) off all
    // ~1975 mem_q write-enable pins -- the -0.977ns endpoint bulk.
    if (i_enq_valid[0]) mem_q[tail_q] <= i_enq_entry0;
    if (i_enq_valid[1]) mem_q[tail_p1] <= i_enq_entry1;
  end

  always_ff @(posedge i_clk) begin
    if (i_rst || i_flush_full) begin
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
    end else if (i_flush_partial) begin
      // The head entry (the return) emitted this cycle; everything younger
      // dies.  head and tail meet just past whatever was dequeued.
      head_q  <= head_q + PtrBits'(i_deq_count);
      tail_q  <= head_q + PtrBits'(i_deq_count);
      count_q <= '0;
    end else begin
      head_q  <= head_q + PtrBits'(i_deq_count);
      tail_q  <= tail_q + PtrBits'(enq_count);
      count_q <= count_q + CntBits'(enq_count) - CntBits'(i_deq_count);
    end
  end

`ifndef SYNTHESIS
  // Contract checks (simulation only).
  logic [1:0] presented_count;
  assign presented_count = {1'b0, o_entry_valid[0]} + {1'b0, o_entry_valid[1]};
  always_ff @(posedge i_clk) begin
    if (!i_rst) begin
      p_enq_valid_onehot_order :
      assert (!i_enq_valid[1] || i_enq_valid[0])
      else $error("parcel_queue: enq_valid[1] without enq_valid[0]");
      p_deq_within_presented :
      assert (i_deq_count <= presented_count)
      else $error("parcel_queue: dequeued %0d of %0d presented", i_deq_count, presented_count);
      p_no_overfill :
      assert (flush_any ||
              (CntBits'(count_q) + CntBits'(enq_count) - CntBits'(i_deq_count) <= CntBits'(DEPTH)))
      else
        $error(
            "parcel_queue: overfill (count %0d enq %0d deq %0d)", count_q, enq_count, i_deq_count
        );
      p_partial_flush_is_dequeue_fire :
      assert (!i_flush_partial || i_flush_full || (i_deq_count == 2'd1))
      else $error("parcel_queue: partial flush with deq_count %0d", i_deq_count);
      p_count_matches_pointers :
      assert (PtrBits'(count_q) == (tail_q - head_q))
      else $error("parcel_queue: count %0d vs pointer distance %0d", count_q, tail_q - head_q);
    end
  end
`endif

endmodule : parcel_queue
