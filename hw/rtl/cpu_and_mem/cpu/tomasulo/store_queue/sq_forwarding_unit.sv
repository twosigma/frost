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

// =============================================================================
// sq_forwarding_unit
// =============================================================================
// Store-to-load forwarding CAM:
//   * Block 1 - per-entry qualification (older-store / addr-overlap / can-forward)
//     from the FF-based SQ fields,
//   * Block 2 - newest-conflicting-store priority select,
//   * Block 3 - register the result (break MEM_RS -> SQ scan -> LQ path).
// Forwarding data arrives as a per-entry mirror from store_queue so the winner
// tree can carry the selected payload directly instead of creating a
// winner-index -> async LUTRAM -> output-register timing arc.  The helper
// functions are duplicated from store_queue (pure combinational, already
// duplicated across modules by design).
// =============================================================================
module sq_forwarding_unit #(
    parameter int unsigned DEPTH = riscv_pkg::SqDepth
) (
    input logic i_clk,
    input logic i_rst_n,
    input logic i_flush_all,

    // Load probe (from MEM_RS via LQ) + ROB head + commit snoop
    input logic i_sq_check_valid,
    // Flush-free capture enable for the Block-3 output register (identical
    // to i_sq_check_valid minus the flush terms, which carried the
    // registered trap/MRET pulse into every capture bit's D; see
    // load_queue.o_sq_check_capture_valid for the consumer-side-kill
    // safety argument).
    input logic i_sq_check_capture_valid,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_b,
    input riscv_pkg::mem_size_e i_sq_check_size,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_sq_check_rob_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,
    // Commit pulses for the same-cycle committed-store scan guard.  The
    // store_queue feeds these from the TRAP-CONE-FREE scan variants (no
    // full-flush mask term): on the one cycle where they differ from the
    // architectural pulses (registered trap/MRET/FENCE.I flush), the capture
    // below latches a result that is structurally unconsumable
    // (capture-then-kill — see the Block-3 comment).  Keeping the flush mask
    // off these inputs keeps the registered trap pulse off every capture
    // D-pin (x3 post-opt -0.138, 65 endpoints).
    input logic i_commit_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag,
    input logic i_commit_valid_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag_2,

    // SQ ring head (oldest undrained entry).  Ring-slot distance from this
    // index is the program-order ranking key for the newest-conflict winner:
    // ROB-tag age wraps for committed-but-undrained entries (their tags may
    // already be reused), but slot order is allocation order and never lies.
    input logic [$clog2(DEPTH)-1:0] i_sq_head_idx,

    // SQ entry-array state (bare names match the verbatim body)
    input logic [DEPTH-1:0] sq_valid,
    input logic [DEPTH-1:0] sq_addr_valid,
    input logic [DEPTH-1:0] sq_data_valid,
    input logic [DEPTH-1:0] sq_is_mmio,
    input logic [DEPTH-1:0] sq_is_sc,
    input logic [DEPTH-1:0] sq_committed,
    input logic [(DEPTH*riscv_pkg::ReorderBufferTagWidth)-1:0] sq_rob_tag_flat,
    input logic [(DEPTH*riscv_pkg::XLEN)-1:0] sq_address_flat,
    input logic [(DEPTH*2)-1:0] sq_size_flat,
    input logic [(DEPTH*riscv_pkg::FLEN)-1:0] sq_data_fwd_flat,

    output logic o_sq_all_older_addrs_known,
    output riscv_pkg::sq_forward_result_t o_sq_forward
);

  // Local pkg-param aliases (match store_queue) so the verbatim bodies below
  // can use the unqualified names.
  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned MemSizeWidth = 2;
  localparam int unsigned WordAddrWidth = XLEN - 2;
  localparam int unsigned IdxWidth = $clog2(DEPTH);

  typedef struct packed {
    logic                       valid;
    // Ring-slot distance from i_sq_head_idx, NOT ROB-tag age: committed
    // entries can outlive their ROB tag (reused next lap), which makes
    // tag-based age rank them as youngest when they are in fact the oldest.
    // Slot order is allocation (= program) order and is wrap-proof.
    logic [IdxWidth-1:0]        age;
    logic                       can_forward;
    logic [riscv_pkg::FLEN-1:0] data;
  } fwd_winner_t;

  function automatic fwd_winner_t choose_newer_winner(input fwd_winner_t lhs,
                                                      input fwd_winner_t rhs);
    begin
      if (!lhs.valid) begin
        choose_newer_winner = rhs;
      end else if (!rhs.valid) begin
        choose_newer_winner = lhs;
      end else if (rhs.age >= lhs.age) begin
        choose_newer_winner = rhs;
      end else begin
        choose_newer_winner = lhs;
      end
    end
  endfunction

  (* equivalent_register_removal = "no", max_fanout = 16 *)
  logic [ReorderBufferTagWidth-1:0] rob_head_tag_q;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      rob_head_tag_q <= '0;
    end else begin
      rob_head_tag_q <= i_rob_head_tag;
    end
  end

  function automatic logic word_addr_eq(input logic [WordAddrWidth-1:0] lhs,
                                        input logic [WordAddrWidth-1:0] rhs);
    logic [WordAddrWidth-1:0] diff;
    logic [5:0] group_has_diff;
    begin
      diff = lhs ^ rhs;
      group_has_diff[0] = |diff[4:0];
      group_has_diff[1] = |diff[9:5];
      group_has_diff[2] = |diff[14:10];
      group_has_diff[3] = |diff[19:15];
      group_has_diff[4] = |diff[24:20];
      group_has_diff[5] = |diff[29:25];
      word_addr_eq = ~(|group_has_diff);
    end
  endfunction

  function automatic logic full_addr_eq(input logic [XLEN-1:0] lhs, input logic [XLEN-1:0] rhs);
    logic [XLEN-1:0] diff;
    logic [6:0] group_has_diff;
    begin
      diff = lhs ^ rhs;
      group_has_diff[0] = |diff[4:0];
      group_has_diff[1] = |diff[9:5];
      group_has_diff[2] = |diff[14:10];
      group_has_diff[3] = |diff[19:15];
      group_has_diff[4] = |diff[24:20];
      group_has_diff[5] = |diff[29:25];
      group_has_diff[6] = |diff[31:30];
      full_addr_eq = ~(|group_has_diff);
    end
  endfunction

  function automatic logic [4:0] inc5(input logic [4:0] value, input logic carry_in);
    logic carry1;
    logic carry2;
    logic carry3;
    logic carry4;
    begin
      carry1 = carry_in & value[0];
      carry2 = carry1 & value[1];
      carry3 = carry2 & value[2];
      carry4 = carry3 & value[3];
      inc5   = value ^ {carry4, carry3, carry2, carry1, carry_in};
    end
  endfunction

  function automatic logic word_addr_inc_eq(input logic [WordAddrWidth-1:0] base,
                                            input logic [WordAddrWidth-1:0] target);
    logic [5:0] group_all_ones;
    logic [5:0] carry_in;
    logic [5:0] group_has_diff;
    begin
      group_all_ones[0] = &base[4:0];
      group_all_ones[1] = &base[9:5];
      group_all_ones[2] = &base[14:10];
      group_all_ones[3] = &base[19:15];
      group_all_ones[4] = &base[24:20];
      group_all_ones[5] = &base[29:25];

      carry_in[0] = 1'b1;
      carry_in[1] = group_all_ones[0];
      carry_in[2] = group_all_ones[0] & group_all_ones[1];
      carry_in[3] = group_all_ones[0] & group_all_ones[1] & group_all_ones[2];
      carry_in[4] = group_all_ones[0] & group_all_ones[1] & group_all_ones[2] & group_all_ones[3];
      carry_in[5] = group_all_ones[0] & group_all_ones[1] & group_all_ones[2] &
                    group_all_ones[3] & group_all_ones[4];

      group_has_diff[0] = |(target[4:0] ^ inc5(base[4:0], carry_in[0]));
      group_has_diff[1] = |(target[9:5] ^ inc5(base[9:5], carry_in[1]));
      group_has_diff[2] = |(target[14:10] ^ inc5(base[14:10], carry_in[2]));
      group_has_diff[3] = |(target[19:15] ^ inc5(base[19:15], carry_in[3]));
      group_has_diff[4] = |(target[24:20] ^ inc5(base[24:20], carry_in[4]));
      group_has_diff[5] = |(target[29:25] ^ inc5(base[29:25], carry_in[5]));

      word_addr_inc_eq = ~(|group_has_diff);
    end
  endfunction

  // Generate byte-enable mask from address offset and size
  function automatic logic [3:0] gen_byte_en(input logic [1:0] addr_offset,
                                             input riscv_pkg::mem_size_e size);
    begin
      case (size)
        riscv_pkg::MEM_SIZE_BYTE:   gen_byte_en = 4'b0001 << addr_offset;
        riscv_pkg::MEM_SIZE_HALF:   gen_byte_en = addr_offset[1] ? 4'b1100 : 4'b0011;
        riscv_pkg::MEM_SIZE_WORD:   gen_byte_en = 4'b1111;
        riscv_pkg::MEM_SIZE_DOUBLE: gen_byte_en = 4'b1111;  // Each phase is word-width
        default:                    gen_byte_en = 4'b0000;
      endcase
    end
  endfunction

  // Forwarding scan results — promoted to module scope so the per-entry
  // qualification mask and winner select stay in separate blocks and avoid
  // UNOPTFLAT circular combinational logic.
  logic fwd_all_older_known;
  logic fwd_found_match;
  logic fwd_can_fwd;
  logic [FLEN-1:0] fwd_selected_data;
  logic [3:0] fwd_load_byte_mask;
  logic [DEPTH-1:0] fwd_addr_unknown_mask;
  logic [DEPTH-1:0] fwd_conflict_mask;
  logic [DEPTH-1:0] fwd_can_forward_mask;
  logic [ReorderBufferTagWidth:0] fwd_load_age;
  logic [ReorderBufferTagWidth:0] fwd_entry_age[DEPTH];
  logic [IdxWidth-1:0] fwd_entry_slot_age[DEPTH];
  logic [FLEN-1:0] fwd_entry_data[DEPTH];
`ifndef FORMAL
  fwd_winner_t fwd_leaf[DEPTH];
  fwd_winner_t fwd_pair[4];
  fwd_winner_t fwd_quad[2];
  fwd_winner_t fwd_winner;
`endif

  assign fwd_load_byte_mask = gen_byte_en(i_sq_check_addr[1:0], i_sq_check_size);
  assign fwd_load_age       = {1'b0, i_sq_check_rob_tag} - {1'b0, rob_head_tag_q};

  // Block 1: per-entry forwarding qualification from FF-based fields only
  // (no LUTRAM read, no inter-entry "last match wins" dependency).
  // Select older stores by ROB age directly so the forwarding path does not
  // need a head-relative barrel rotation over sq_valid/sq_addr_valid.
  always_comb begin
    logic same_word;
    logic base_match;
    logic double_hi_match;
    logic load_double_hi;
    logic older_store;
    logic store_committed;
    logic [3:0] store_byte_mask;
    logic [3:0] load_byte_mask;
    logic [ReorderBufferTagWidth-1:0] entry_rob_tag;
    logic [XLEN-1:0] entry_address;
    logic [FLEN-1:0] entry_data;
    logic [XLEN-1:0] entry_image_lo;
    riscv_pkg::mem_size_e entry_size;
    // Port-split: entries 0..DEPTH/2-1 use i_sq_check_addr, entries
    // DEPTH/2..DEPTH-1 use i_sq_check_addr_b.  Both values are identical
    // (driven by sister registers in LQ), but the two source FFs let the
    // placer split the per-entry CARRY8 compare chains across two physical
    // anchor points.  Without this split, all per-entry compares routed
    // from a single source FF, contributing ~0.2 ns route hops on the
    // -0.178 ns post-synth path (LQ → SQ CAM → output FF).
    logic [XLEN-1:0] sq_check_addr_for_entry;
    logic [WordAddrWidth-1:0] sq_check_word_for_entry;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      same_word = 1'b0;
      base_match = 1'b0;
      double_hi_match = 1'b0;
      load_double_hi = 1'b0;
      older_store = 1'b0;
      store_committed = 1'b0;
      store_byte_mask = 4'b0000;
      load_byte_mask = fwd_load_byte_mask;
      // (i < DEPTH/2) is constant per loop iteration after synth unroll —
      // the select collapses to a wire-pick of one of the two address ports.
      entry_rob_tag = sq_rob_tag_flat[i*ReorderBufferTagWidth+:ReorderBufferTagWidth];
      entry_address = sq_address_flat[i*XLEN+:XLEN];
      entry_data = sq_data_fwd_flat[i*FLEN+:FLEN];
      entry_image_lo = entry_data[XLEN-1:0] << {entry_address[1:0], 3'b000};
      entry_size = riscv_pkg::mem_size_e'(sq_size_flat[i*MemSizeWidth+:MemSizeWidth]);
      sq_check_addr_for_entry = (i < (DEPTH / 2)) ? i_sq_check_addr : i_sq_check_addr_b;
      sq_check_word_for_entry = sq_check_addr_for_entry[XLEN-1:2];
      fwd_entry_age[i] = {1'b0, entry_rob_tag} - {1'b0, rob_head_tag_q};
      // Program-order rank for winner selection: ring distance from the SQ
      // head.  DEPTH is a power of two, so the subtraction wraps naturally.
      fwd_entry_slot_age[i] = IdxWidth'(i) - i_sq_head_idx;
      fwd_addr_unknown_mask[i] = 1'b0;
      fwd_conflict_mask[i] = 1'b0;
      fwd_can_forward_mask[i] = 1'b0;
      fwd_entry_data[i] = '0;

      // Stores retire from the ROB before they drain from the SQ.  Keep a
      // store visible to younger-load disambiguation in the cycle its commit
      // arrives so the load cannot slip through the one-cycle sq_committed lag.
      // Widen-commit extends the same guard to slot 2.
      store_committed = sq_committed[i] ||
                        (i_commit_valid && (entry_rob_tag == i_commit_rob_tag)) ||
                        (i_commit_valid_2 && (entry_rob_tag == i_commit_rob_tag_2));
      older_store = sq_valid[i] && (store_committed || (fwd_entry_age[i] < fwd_load_age));

      if (older_store) begin
        // Check if this older store has its address resolved
        if (!sq_addr_valid[i]) begin
          fwd_addr_unknown_mask[i] = 1'b1;
        end

        // Check for address overlap
        if (sq_addr_valid[i]) begin
          same_word = word_addr_eq(entry_address[XLEN-1:2], sq_check_word_for_entry);
          store_byte_mask = gen_byte_en(entry_address[1:0], entry_size);

          // Non-double accesses only conflict when their byte ranges overlap.
          base_match = same_word && ((entry_size == riscv_pkg::MEM_SIZE_DOUBLE) ||
                       (i_sq_check_size == riscv_pkg::MEM_SIZE_DOUBLE) ||
                       (|(store_byte_mask & load_byte_mask)));

          // DOUBLE store: also overlaps at word addr+4
          double_hi_match = (entry_size == riscv_pkg::MEM_SIZE_DOUBLE) &&
              word_addr_inc_eq(entry_address[XLEN-1:2], sq_check_word_for_entry);

          // DOUBLE load: check if store is at the +4 word
          load_double_hi = (i_sq_check_size == riscv_pkg::MEM_SIZE_DOUBLE) &&
              word_addr_inc_eq(sq_check_word_for_entry, entry_address[XLEN-1:2]);

          if (base_match || double_hi_match || load_double_hi) begin
            fwd_conflict_mask[i] = 1'b1;

            // Forwarding: only non-MMIO, non-SC stores with valid data.  A
            // store-conditional may fail at drain time and write nothing, so
            // its data must never reach a younger load early.
            if (sq_data_valid[i] && !sq_is_mmio[i] && !sq_is_sc[i]) begin
              // Case 1: FLD from FSD, exact address (full 64-bit payload)
              if (base_match && full_addr_eq(
                      entry_address, sq_check_addr_for_entry
                  ) && (entry_size == riscv_pkg::MEM_SIZE_DOUBLE) &&
                      (i_sq_check_size == riscv_pkg::MEM_SIZE_DOUBLE)) begin
                fwd_can_forward_mask[i] = 1'b1;
                fwd_entry_data[i]       = entry_data;  // EXACT (64-bit)
                // Case 2: byte/half/word load whose bytes the store fully
                // covers in its base word.  store_byte_mask places sub-word
                // store data at its memory byte lanes (a DOUBLE store's base
                // word is fully written, mask 1111), so covered loads read
                // the memory-image word Block 3 reconstructs.  The LQ applies
                // the load's own byte/half extraction and sign extension.
              end else if (base_match &&
                  (i_sq_check_size != riscv_pkg::MEM_SIZE_DOUBLE) &&
                  ((store_byte_mask & load_byte_mask) == load_byte_mask)) begin
                fwd_can_forward_mask[i] = 1'b1;
                fwd_entry_data[i]       = {{(FLEN - XLEN) {1'b0}}, entry_image_lo};
                // Case 3: byte/half/word load inside the fully-written high
                // word of a DOUBLE store (addr+4)
              end else if (double_hi_match && (i_sq_check_size != riscv_pkg::MEM_SIZE_DOUBLE)) begin
                fwd_can_forward_mask[i] = 1'b1;
                fwd_entry_data[i]       = {{(FLEN - XLEN) {1'b0}}, entry_data[FLEN-1:XLEN]};
              end
            end
          end
        end
      end
    end
  end

  assign fwd_all_older_known = ~(|fwd_addr_unknown_mask);
  assign fwd_found_match     = |fwd_conflict_mask;

  // Block 2: newest conflicting store wins for data/extract selection, ranked
  // by SQ ring-slot distance from i_sq_head_idx (allocation = program order;
  // ROB-tag age is wrap-ambiguous once committed entries outlive their tag).
  // The heavy address/age qualification is already parallelized above, so this
  // block only prioritizes 1-bit match results and their precomputed metadata.
`ifdef FORMAL
  // Yosys's formal frontend currently mishandles the balanced tree's unpacked
  // array of packed structs, treating fields such as fwd_leaf[i].can_forward
  // as implicit wires. Use an equivalent linear selector for formal only; the
  // synthesized implementation below remains the timing-optimized tree.
  logic fwd_formal_winner_valid;
  logic [IdxWidth-1:0] fwd_formal_winner_age;

  always_comb begin
    fwd_formal_winner_valid = 1'b0;
    fwd_formal_winner_age   = '0;
    fwd_can_fwd             = 1'b0;
    fwd_selected_data       = '0;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (fwd_conflict_mask[i] &&
          (!fwd_formal_winner_valid || (fwd_entry_slot_age[i] >= fwd_formal_winner_age))) begin
        fwd_formal_winner_valid = 1'b1;
        fwd_formal_winner_age   = fwd_entry_slot_age[i];
        fwd_can_fwd             = fwd_can_forward_mask[i];
        fwd_selected_data       = fwd_entry_data[i];
      end
    end
  end
`else
  // Keep this as a balanced tree: the old serial loop let an SQ-check address
  // bit feed each entry's conflict logic and then walk an 8-entry winner chain
  // before reaching o_sq_forward.can_forward.
  always_comb begin
    for (int unsigned i = 0; i < DEPTH; i++) begin
      fwd_leaf[i].valid       = fwd_conflict_mask[i];
      fwd_leaf[i].age         = fwd_entry_slot_age[i];
      fwd_leaf[i].can_forward = fwd_can_forward_mask[i];
      fwd_leaf[i].data        = fwd_entry_data[i];
    end

    fwd_pair[0]       = choose_newer_winner(fwd_leaf[0], fwd_leaf[1]);
    fwd_pair[1]       = choose_newer_winner(fwd_leaf[2], fwd_leaf[3]);
    fwd_pair[2]       = choose_newer_winner(fwd_leaf[4], fwd_leaf[5]);
    fwd_pair[3]       = choose_newer_winner(fwd_leaf[6], fwd_leaf[7]);

    fwd_quad[0]       = choose_newer_winner(fwd_pair[0], fwd_pair[1]);
    fwd_quad[1]       = choose_newer_winner(fwd_pair[2], fwd_pair[3]);

    fwd_winner        = choose_newer_winner(fwd_quad[0], fwd_quad[1]);

    fwd_can_fwd       = fwd_winner.valid && fwd_winner.can_forward;
    fwd_selected_data = fwd_winner.data;
  end
`endif

  // Block 3: Registered forwarding outputs.
  // Keep the SQ compare/forwarding result behind a register so the LQ sees it
  // one cycle later; this breaks the MEM_RS -> SQ scan -> LQ -> BRAM path.
  //
  // TIMING (x3 post-opt -0.135, 65 endpoints): the synchronous i_flush_all
  // clear pulled the registered trap/MRET pulse (trap_taken_prev replicas)
  // into every capture bit's D-mux, making flush distribution the late
  // arrival of this cone. Capture-then-kill instead: the register captures
  // the probe result unconditionally and the flush kills the CONSUMER --
  // every reader (sq_can_issue, sq_do_forward in load_queue.sv) is gated by
  // the probing load's staged state (sq_check_phase2 /
  // sq_check_entry_issueable), which i_flush_all clears in the same cycle.
  // Staleness is bounded to exactly one cycle: with the LQ flushed no probe
  // issues, so the i_sq_check_valid arm self-clears these bits on the next
  // edge.
  //
  // The same contract covers the capture DATA cone: the capture enable
  // (i_sq_check_capture_valid) omits the flush and commit-block terms, and
  // the commit pulses feeding the scan above are the trap-cone-free scan
  // variants.  A capture computed on the flush cycle may therefore treat a
  // squashed store commit as visible — and is exactly as unconsumable as any
  // other flush-cycle capture.
  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      o_sq_all_older_addrs_known <= 1'b0;
      o_sq_forward.match         <= 1'b0;
      o_sq_forward.can_forward   <= 1'b0;
    end else begin
      o_sq_all_older_addrs_known <= i_sq_check_capture_valid ? fwd_all_older_known : 1'b0;
      o_sq_forward.match         <= i_sq_check_capture_valid ? fwd_found_match : 1'b0;
      o_sq_forward.can_forward   <= i_sq_check_capture_valid ? fwd_can_fwd : 1'b0;
    end

    // Data is qualified by the same-edge match/can_forward above; the
    // capture gate just keeps the register from tracking the winner
    // tree while no probe is in flight. Must use the SAME enable as the
    // match/can_forward arm so the pair stays coherent.
    if (i_sq_check_capture_valid) begin
      o_sq_forward.data <= fwd_selected_data;
    end
  end

endmodule
