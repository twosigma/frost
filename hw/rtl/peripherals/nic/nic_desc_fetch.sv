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
 * nic_desc_fetch: descriptor supply for one ring.
 *
 * Descriptors are 16 bytes, two per 32-byte line, in a ring of
 * 2^i_size_log2 entries at i_base. Software posts descriptors below i_tail;
 * this block runs a prefetch cursor ahead of the consumer index (o_head),
 * fetching the line of the cursor's descriptor through the DMA front-end
 * (one read in flight) into a two-line cache, and offers the head
 * descriptor's words to the engine (from registers, a cycle behind the
 * cache), which takes it with i_desc_take.
 *
 * Eligibility is captured when the read is ISSUED: from a fetched line the
 * cursor's descriptor is eligible, and the following one when it is below
 * i_tail at that moment; nothing else in the line is ever used, and a TAIL
 * that advanced while the read was in flight makes no further slot
 * eligible, so a descriptor posted later is always re-read after its
 * doorbell. i_invalidate drops the cache and moves the cursor back to the
 * head (a disable or RESET); i_restart also zeroes the head (a BASE write:
 * a new ring generation). A response for a read issued before an
 * invalidation is dropped (the read is orphaned), as is a response with
 * i_resp_error set (the front-end refused or withdrew the read).
 */
module nic_desc_fetch #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned LINE_BYTES = 32,
    parameter int unsigned TAG_BITS   = 4
) (
    input logic i_clk,
    input logic i_rst,

    input  logic                  i_enable,
    input  logic [ADDR_WIDTH-1:0] i_base,        // 32-byte aligned
    input  logic [           4:0] i_size_log2,   // 2..16
    input  logic [          15:0] i_tail,
    input  logic                  i_invalidate,
    input  logic                  i_restart,
    output logic [          15:0] o_head,
    output logic                  o_pending,     // a read is in flight

    // Descriptor line reads (kind = descriptor) through the front-end.
    output logic                    o_rd_valid,
    input  logic                    i_rd_ready,
    output logic [  ADDR_WIDTH-1:0] o_rd_addr,
    output logic [    TAG_BITS-1:0] o_rd_tag,
    input  logic                    i_resp_valid,
    input  logic [    TAG_BITS-1:0] i_resp_tag,
    input  logic                    i_resp_error,
    input  logic [LINE_BYTES*8-1:0] i_resp_rdata,

    // The head descriptor.
    output logic                  o_desc_valid,
    output logic [          31:0] o_desc_word0,
    output logic [          31:0] o_desc_word1,
    output logic [ADDR_WIDTH-1:0] o_desc_status_addr,  // byte address of its word 2
    input  logic                  i_desc_take
);
  logic [15:0] mask;
  assign mask = 16'((32'd1 << i_size_log2) - 1);

  logic [15:0] head_q, cursor_q;
  assign o_head = head_q;

  // Two cache slots: the line index (index of its first descriptor), the
  // eligibility of its two descriptors, the words.
  logic [ 1:0] slot_valid_q;
  logic [15:0] slot_index_q [2];
  logic [ 1:0] slot_elig_q  [2];
  logic [31:0] slot_words_q [2] [8];

  logic pending_q, pend_orphan_q;
  logic pend_slot_q;
  logic [1:0] pend_elig_q;
  logic [15:0] pend_index_q;
  assign o_pending = pending_q;

  // Distance helpers in ring index space.
  function automatic logic [15:0] ring_dist(input logic [15:0] a, input logic [15:0] b,
                                            input logic [15:0] m);
    ring_dist = (a - b) & m;
  endfunction

  // ---- prefetch ----------------------------------------------------------------
  logic slot_free_any;
  logic slot_free_idx;
  assign slot_free_any = !(&slot_valid_q);
  assign slot_free_idx = slot_valid_q[0];  // slot 0 first
  logic posted;  // the cursor is below the tail
  assign posted = ring_dist(i_tail, cursor_q, mask) != 16'd0;
  logic [15:0] cursor_line;  // index of the line's first descriptor
  assign cursor_line = cursor_q & ~16'd1;
  logic next_elig;  // the descriptor after the cursor is in this line and posted
  assign next_elig  = (cursor_q[0] == 1'b0) && (ring_dist(i_tail, cursor_q, mask) > 16'd1);
  assign o_rd_valid = i_enable && !i_invalidate && !pending_q && slot_free_any && posted;
  assign o_rd_addr  = i_base + (ADDR_WIDTH'(cursor_line) << 4);
  assign o_rd_tag   = TAG_BITS'(slot_free_idx);
  logic rd_fire;
  assign rd_fire = o_rd_valid && i_rd_ready;

  // ---- the head descriptor --------------------------------------------------------
  logic head_hit;
  logic head_slot;
  always_comb begin
    head_hit  = 1'b0;
    head_slot = 1'b0;
    for (int s = 1; s >= 0; s--) begin
      if (slot_valid_q[s] && (slot_index_q[s] == (head_q & ~16'd1)) &&
          slot_elig_q[s][head_q[0]]) begin
        head_hit  = 1'b1;
        head_slot = 1'(s);
      end
    end
  end
  // The head descriptor is offered from registers: the slot search and the
  // word mux happen a cycle ahead of the engine's decision (that path, into
  // the packer's start, was the core domain's longest). A take, an
  // invalidation or a restart blanks the view for the cycle it changes the
  // state, so a stale image is never offered.
  logic desc_valid_q;
  logic [31:0] desc_word0_q, desc_word1_q;
  logic [ADDR_WIDTH-1:0] desc_status_addr_q;
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      desc_valid_q <= 1'b0;
    end else begin
      desc_valid_q       <= i_enable && head_hit && !i_desc_take && !i_invalidate && !i_restart;
      desc_word0_q       <= slot_words_q[head_slot][{head_q[0], 2'd0}];
      desc_word1_q       <= slot_words_q[head_slot][{head_q[0], 2'd1}];
      desc_status_addr_q <= i_base + (ADDR_WIDTH'(head_q) << 4) + ADDR_WIDTH'(8);
    end
  end
  assign o_desc_valid = desc_valid_q;
  assign o_desc_word0 = desc_word0_q;
  assign o_desc_word1 = desc_word1_q;
  assign o_desc_status_addr = desc_status_addr_q;

  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      head_q        <= '0;
      cursor_q      <= '0;
      slot_valid_q  <= '0;
      pending_q     <= 1'b0;
      pend_orphan_q <= 1'b0;
    end else begin
      if (i_restart) begin
        head_q   <= '0;
        cursor_q <= '0;
      end
      if (i_invalidate || i_restart) begin
        slot_valid_q <= '0;
        if (!i_restart) cursor_q <= head_q;
        pend_orphan_q <= 1'b1;  // a read in flight lands nowhere
      end else begin
        if (rd_fire) begin
          pending_q     <= 1'b1;
          pend_orphan_q <= 1'b0;
          pend_slot_q   <= slot_free_idx;
          pend_index_q  <= cursor_line;
          pend_elig_q   <= cursor_q[0] ? 2'b10 : (next_elig ? 2'b11 : 2'b01);
          cursor_q      <= (cursor_q + (next_elig ? 16'd2 : 16'd1)) & mask;
        end
        if (i_desc_take && head_hit) begin
          slot_elig_q[head_slot][head_q[0]] <= 1'b0;
          if ((slot_elig_q[head_slot] & ~(2'b01 << head_q[0])) == 2'b00)
            slot_valid_q[head_slot] <= 1'b0;
          head_q <= (head_q + 16'd1) & mask;
        end
      end
      if (i_resp_valid && pending_q) begin
        pending_q <= 1'b0;
        if (!pend_orphan_q && !i_resp_error && !(i_invalidate || i_restart)) begin
          slot_valid_q[pend_slot_q] <= 1'b1;
          slot_index_q[pend_slot_q] <= pend_index_q;
          slot_elig_q[pend_slot_q]  <= pend_elig_q;
          for (int w = 0; w < 8; w++) slot_words_q[pend_slot_q][w] <= i_resp_rdata[w*32+:32];
        end
      end
    end
  end

`ifndef SYNTHESIS
`ifndef FORMAL
  always_ff @(posedge i_clk) begin
    if (!i_rst && i_resp_valid && pending_q && (i_resp_tag != TAG_BITS'(pend_slot_q)))
      $error("nic_desc_fetch: response tag %0d, expected %0d", i_resp_tag, pend_slot_q);
    if (!i_rst && i_resp_valid && !pending_q)
      $error("nic_desc_fetch: response with no read in flight");
  end
`endif
`endif
endmodule : nic_desc_fetch
