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

// Formal harness for sq_forwarding_unit.
// Checks grouped dword/64-byte-block address comparators, ROB-age and dual
// same-cycle commit-snoop qualification, ring-order winner selection, Zicbom,
// cbo.zero, MMIO and SC vetoes, byte-lane coverage, and registered index/offset
// payload selection against an independent ring-order specification.
module sq_forwarding_unit_formal #(
    parameter int unsigned DEPTH = 8
) (
    input logic i_clk,
    input logic i_rst_n,
    input logic i_flush_all,
    input logic i_sq_check_capture_valid,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_b,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_c,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_d,
    input riscv_pkg::mem_size_e i_sq_check_size,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_sq_check_rob_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,
    input logic i_commit_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag,
    input logic i_commit_valid_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag_2,
    input logic [$clog2(DEPTH)-1:0] i_sq_head_idx,
    input logic [DEPTH-1:0] sq_valid,
    input logic [DEPTH-1:0] sq_addr_valid,
    input logic [DEPTH-1:0] sq_data_valid,
    input logic [DEPTH-1:0] sq_is_mmio,
    input logic [DEPTH-1:0] sq_is_sc,
    input logic [DEPTH-1:0] sq_is_zero,
    input logic [DEPTH-1:0] sq_is_cmo,
    input logic [DEPTH-1:0] sq_committed,
    input logic [(DEPTH*riscv_pkg::ReorderBufferTagWidth)-1:0] sq_rob_tag_flat,
    input logic [(DEPTH*riscv_pkg::XLEN)-1:0] sq_address_flat,
    input logic [(DEPTH*2)-1:0] sq_size_flat,
    input logic [(DEPTH*riscv_pkg::FLEN)-1:0] sq_data_fwd_flat
);

  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned IdxWidth = $clog2(DEPTH);

  logic                          o_sq_all_older_addrs_known;
  riscv_pkg::sq_forward_result_t o_sq_forward;

  sq_forwarding_unit #(
      .DEPTH(DEPTH)
  ) dut (
      .i_clk                     (i_clk),
      .i_rst_n                   (i_rst_n),
      .i_flush_all               (i_flush_all),
      .i_sq_check_capture_valid  (i_sq_check_capture_valid),
      .i_sq_check_addr           (i_sq_check_addr),
      .i_sq_check_addr_b         (i_sq_check_addr_b),
      .i_sq_check_addr_c         (i_sq_check_addr_c),
      .i_sq_check_addr_d         (i_sq_check_addr_d),
      .i_sq_check_size           (i_sq_check_size),
      .i_sq_check_rob_tag        (i_sq_check_rob_tag),
      .i_rob_head_tag            (i_rob_head_tag),
      .i_commit_valid            (i_commit_valid),
      .i_commit_rob_tag          (i_commit_rob_tag),
      .i_commit_valid_2          (i_commit_valid_2),
      .i_commit_rob_tag_2        (i_commit_rob_tag_2),
      .i_sq_head_idx             (i_sq_head_idx),
      .sq_valid                  (sq_valid),
      .sq_addr_valid             (sq_addr_valid),
      .sq_data_valid             (sq_data_valid),
      .sq_is_mmio                (sq_is_mmio),
      .sq_is_sc                  (sq_is_sc),
      .sq_is_zero                (sq_is_zero),
      .sq_is_cmo                 (sq_is_cmo),
      .sq_committed              (sq_committed),
      .sq_rob_tag_flat           (sq_rob_tag_flat),
      .sq_address_flat           (sq_address_flat),
      .sq_size_flat              (sq_size_flat),
      .sq_data_fwd_flat          (sq_data_fwd_flat),
      .o_sq_all_older_addrs_known(o_sq_all_older_addrs_known),
      .o_sq_forward              (o_sq_forward)
  );

  logic f_past_valid = 1'b0;
  initial assume (!i_rst_n);
  always_ff @(posedge i_clk) begin
    f_past_valid <= 1'b1;
  end

  // Caller contracts proved in load_queue and store_queue:
  // 1. load_queue replicates its probe address across all four fanout copies.
  // 2. store_queue sets sq_is_zero on every sq_is_cmo entry passed to the CAM.
  // 3. store_queue's write-once FF data mirror holds a valid entry's payload
  //    across the capture edge through the consume cycle.
  always_comb begin
    assume (i_sq_check_addr_b == i_sq_check_addr);
    assume (i_sq_check_addr_c == i_sq_check_addr);
    assume (i_sq_check_addr_d == i_sq_check_addr);
    assume ((sq_is_cmo & ~sq_is_zero) == '0);
  end

  for (genvar s = 0; s < DEPTH; s++) begin : gen_data_mirror_hold
    always_ff @(posedge i_clk) begin
      if (f_past_valid && i_rst_n && $past(
              i_rst_n
          ) && $past(
              i_sq_check_capture_valid && sq_valid[s] && sq_data_valid[s]
          )) begin
        assume (sq_data_fwd_flat[s*FLEN+:FLEN] == $past(sq_data_fwd_flat[s*FLEN+:FLEN]));
      end
    end
  end

  function automatic logic [7:0] ref_byte_mask(input logic [1:0] size_bits,
                                               input logic [2:0] offset);
    case (size_bits)
      2'b00:   ref_byte_mask = 8'h01 << offset;
      2'b01:   ref_byte_mask = 8'h03 << {offset[2:1], 1'b0};
      2'b10:   ref_byte_mask = offset[2] ? 8'hf0 : 8'h0f;
      default: ref_byte_mask = 8'hff;
    endcase
  endfunction

  function automatic logic ref_naturally_aligned(input logic [1:0] size_bits,
                                                 input logic [2:0] offset);
    case (size_bits)
      2'b00:   ref_naturally_aligned = 1'b1;
      2'b01:   ref_naturally_aligned = !offset[0];
      2'b10:   ref_naturally_aligned = (offset[1:0] == 2'b00);
      default: ref_naturally_aligned = (offset == 3'b000);
    endcase
  endfunction

  // Independent specification scanning the SQ ring from oldest (i_sq_head_idx)
  // to youngest (i_sq_head_idx + DEPTH - 1 mod DEPTH).
  logic [ReorderBufferTagWidth-1:0] ref_rob_head_tag_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      ref_rob_head_tag_q <= '0;
    end else begin
      ref_rob_head_tag_q <= i_rob_head_tag;
    end
  end

  logic                ref_all_older_known;
  logic                ref_match;
  logic                ref_can_forward;
  logic                ref_cmo_conflict;
  logic [    FLEN-1:0] ref_data;
  logic [    FLEN-1:0] ref_win_raw_data;
  logic [         2:0] ref_win_store_off;
  logic [         1:0] ref_win_size_bits;
  logic [         7:0] ref_load_mask_comb;
  logic [IdxWidth-1:0] ref_win_idx;
  logic [         3:0] ref_conflict_count;

  always_comb begin
    logic [ReorderBufferTagWidth:0] load_age;
    logic [ReorderBufferTagWidth:0] entry_age;
    logic [ReorderBufferTagWidth-1:0] entry_tag;
    logic [XLEN-1:0] entry_addr;
    logic [1:0] entry_size_bits;
    logic [7:0] store_mask;
    logic entry_committed;
    logic entry_older;
    logic addr_match;
    logic [IdxWidth-1:0] slot;

    ref_all_older_known = 1'b1;
    ref_match           = 1'b0;
    ref_can_forward     = 1'b0;
    ref_cmo_conflict    = 1'b0;
    ref_data            = '0;
    ref_win_raw_data    = '0;
    ref_win_store_off   = '0;
    ref_win_size_bits   = '0;
    ref_win_idx         = '0;
    ref_conflict_count  = '0;

    ref_load_mask_comb  = ref_byte_mask(2'(i_sq_check_size), i_sq_check_addr[2:0]);
    load_age            = {1'b0, i_sq_check_rob_tag} - {1'b0, ref_rob_head_tag_q};

    for (int unsigned step = 0; step < DEPTH; step++) begin
      slot = i_sq_head_idx + IdxWidth'(step);
      entry_tag = sq_rob_tag_flat[slot*ReorderBufferTagWidth+:ReorderBufferTagWidth];
      entry_addr = sq_address_flat[slot*XLEN+:XLEN];
      entry_size_bits = sq_size_flat[slot*2+:2];
      entry_age = {1'b0, entry_tag} - {1'b0, ref_rob_head_tag_q};
      addr_match = 1'b0;
      store_mask = '0;

      entry_committed = sq_committed[slot] ||
                        (i_commit_valid && (entry_tag == i_commit_rob_tag)) ||
                        (i_commit_valid_2 && (entry_tag == i_commit_rob_tag_2));
      entry_older = sq_valid[slot] && (entry_committed || (entry_age < load_age));

      if (entry_older) begin
        if (!sq_addr_valid[slot]) begin
          ref_all_older_known = 1'b0;
        end else begin
          addr_match = sq_is_zero[slot] ?
              (entry_addr[XLEN-1:6] == i_sq_check_addr[XLEN-1:6]) :
              (entry_addr[XLEN-1:3] == i_sq_check_addr[XLEN-1:3]);
          store_mask = sq_is_zero[slot] ? 8'hff : ref_byte_mask(entry_size_bits, entry_addr[2:0]);

          if (addr_match && (|(store_mask & ref_load_mask_comb))) begin
            ref_match          = 1'b1;
            ref_conflict_count = ref_conflict_count + 4'd1;
            ref_win_idx        = slot;
            ref_win_store_off  = entry_addr[2:0];
            ref_win_size_bits  = entry_size_bits;
            ref_win_raw_data   = sq_data_fwd_flat[slot*FLEN+:FLEN];

            if (sq_is_cmo[slot]) begin
              ref_cmo_conflict = 1'b1;
            end

            if (sq_data_valid[slot] && !sq_is_mmio[slot] && !sq_is_sc[slot] && !sq_is_zero[slot] &&
                ((store_mask & ref_load_mask_comb) == ref_load_mask_comb)) begin
              ref_can_forward = 1'b1;
              ref_data        = sq_data_fwd_flat[slot*FLEN+:FLEN] << {entry_addr[2:0], 3'b000};
            end else begin
              ref_can_forward = 1'b0;
              ref_data        = '0;
            end
          end
        end
      end
    end

    if (ref_cmo_conflict) begin
      ref_can_forward = 1'b0;
    end
  end

  logic            ref_all_older_known_q;
  logic            ref_match_q;
  logic            ref_can_forward_q;
  logic [FLEN-1:0] ref_data_q;
  logic [FLEN-1:0] ref_win_raw_data_q;
  logic [     2:0] ref_win_store_off_q;
  logic [     1:0] ref_win_size_bits_q;
  logic [     7:0] ref_load_mask_q;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      ref_all_older_known_q <= 1'b0;
      ref_match_q           <= 1'b0;
      ref_can_forward_q     <= 1'b0;
    end else begin
      ref_all_older_known_q <= i_sq_check_capture_valid ? ref_all_older_known : 1'b0;
      ref_match_q           <= i_sq_check_capture_valid ? ref_match : 1'b0;
      ref_can_forward_q     <= i_sq_check_capture_valid ? ref_can_forward : 1'b0;
    end
    if (i_sq_check_capture_valid) begin
      ref_data_q          <= ref_data;
      ref_win_raw_data_q  <= ref_win_raw_data;
      ref_win_store_off_q <= ref_win_store_off;
      ref_win_size_bits_q <= ref_win_size_bits;
      ref_load_mask_q     <= ref_load_mask_comb;
    end
  end

  always_ff @(posedge i_clk) begin
    // Synchronous reset clears all three registered control outputs.
    if (f_past_valid && !$past(i_rst_n)) begin
      p_reset_clears_outputs :
      assert (!o_sq_all_older_addrs_known && !o_sq_forward.match && !o_sq_forward.can_forward);
    end

    // A cycle without a valid load probe clears all registered control outputs.
    if (f_past_valid && i_rst_n && $past(i_rst_n) && !$past(i_sq_check_capture_valid)) begin
      p_idle_probe_clears_outputs :
      assert (!o_sq_all_older_addrs_known && !o_sq_forward.match && !o_sq_forward.can_forward);
    end
  end

  always_comb begin
    if (i_rst_n) begin
      // Forwarding permission requires a detected address/lane conflict.
      p_can_forward_implies_match : assert (!o_sq_forward.can_forward || o_sq_forward.match);

      // Older-store address-known flag matches the ring-order specification.
      p_older_addrs_known_exact : assert (o_sq_all_older_addrs_known == ref_all_older_known_q);

      // Address/byte-lane conflict flag matches the ring-order specification.
      p_match_exact : assert (o_sq_forward.match == ref_match_q);

      // Forwarding qualification (including Zicbom/MMIO/SC/cbo.zero vetoes and
      // full byte-mask coverage) matches the ring-order specification.
      p_can_forward_exact : assert (o_sq_forward.can_forward == ref_can_forward_q);

      // Forwarded payload from the registered index/offset mux matches the
      // youngest conflicting store in ring order.
      if (o_sq_forward.can_forward) begin
        p_forward_data_exact : assert (o_sq_forward.data == ref_data_q);
      end
    end
  end

  // For naturally aligned winning stores, every byte lane covered by the load
  // carries the corresponding byte from the winning store's raw value.
  logic [7:0] aligned_lane_ok;
  always_comb begin
    aligned_lane_ok = 8'hff;
    for (int unsigned lane = 0; lane < 8; lane++) begin
      if (ref_load_mask_q[lane] &&
          (o_sq_forward.data[lane*8+:8] !=
           ref_win_raw_data_q[(3'(lane)-ref_win_store_off_q)*8+:8])) begin
        aligned_lane_ok[lane] = 1'b0;
      end
    end
    if (i_rst_n && o_sq_forward.can_forward && ref_naturally_aligned(
            ref_win_size_bits_q, ref_win_store_off_q
        )) begin
      p_aligned_lane_bytes_exact : assert (&aligned_lane_ok);
    end
  end

  // Reachability covers for multi-entry arbitration and veto corner cases.
  always_ff @(posedge i_clk) begin
    if (f_past_valid && i_rst_n && $past(i_rst_n)) begin
      // Youngest conflicting store wraps past slot 0 around i_sq_head_idx and forwards.
      c_wrapped_ring_winner :
      cover (o_sq_forward.can_forward && $past(
          i_sq_check_capture_valid && (ref_conflict_count >= 4'd2) && (ref_win_idx < i_sq_head_idx)
      ));

      // Older committed store whose reused ROB tag looks younger by tag age
      // loses to a younger uncommitted store in ring order.
      c_committed_tag_reused_beaten_by_younger :
      cover (o_sq_forward.can_forward && $past(
          i_sq_check_capture_valid && (ref_conflict_count >= 4'd2) &&
                   sq_committed[i_sq_head_idx] && !sq_committed[ref_win_idx]
      ));

      // Same-cycle commit snoop qualifies a store whose ROB tag would not rank
      // older by ROB-head subtraction alone.
      c_same_cycle_commit_snoop_match :
      cover (o_sq_forward.match && $past(
          i_sq_check_capture_valid && i_commit_valid && (sq_committed == '0)
      ));

      // Older Zicbom block entry vetoes forwarding even when a younger store
      // covers every byte lane of the probing load.
      c_cmo_vetoes_younger_covering_store :
      cover (o_sq_forward.match && !o_sq_forward.can_forward && $past(
          i_sq_check_capture_valid && ref_cmo_conflict && (ref_conflict_count >= 4'd2)
      ));

      // cbo.zero blocks a load to a different dword within the same 64-byte block.
      c_zero_block_cross_dword_conflict :
      cover (o_sq_forward.match && !o_sq_forward.can_forward && $past(
          i_sq_check_capture_valid && sq_is_zero[ref_win_idx] && !sq_is_cmo[ref_win_idx] &&
                   (sq_address_flat[ref_win_idx*XLEN+3+:3] != i_sq_check_addr[5:3])
      ));

      // Shifted sub-dword store forwards non-zero lanes to a narrower load.
      c_shifted_subword_forward :
      cover (o_sq_forward.can_forward && (ref_win_store_off_q != 3'b000) &&
             (o_sq_forward.data != '0));
    end
  end

endmodule
