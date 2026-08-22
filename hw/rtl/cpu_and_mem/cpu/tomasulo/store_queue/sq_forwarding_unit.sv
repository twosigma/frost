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
//
// Overlap model (hw/rtl/README.md, "Data-tier bus contract"): dword granule.  No access
// crosses an aligned 8-byte beat (misaligned accesses trap before reaching
// this CAM, matching the old word model's alignment assumption), so two
// accesses conflict exactly when they share a dword address AND their 8-lane
// byte masks intersect; a store can forward when its lane mask covers the
// load's.  The forwarded payload is the aligned-dword memory image at the
// load's dword — store data shifted to its byte lanes — from which the LQ
// extracts by the load's own addr[2:0] (or consumes whole for FLD/LD).
//
// Forwarding data arrives as a per-entry FF mirror from store_queue.  The scan
// registers only the winning entry index plus its store offset; the mirrored
// payload is selected after that boundary during the LQ consume cycle.  This
// keeps the SQ address compare / winner tree off all 64 payload D-pins
// without adding a pipeline stage.  The helper functions are duplicated from
// store_queue (pure combinational, already duplicated across modules by
// design).
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
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_c,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_d,
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
  localparam int unsigned DwordAddrWidth = XLEN - 3;
  localparam int unsigned IdxWidth = $clog2(DEPTH);

  typedef struct packed {
    logic                valid;
    // Ring-slot distance from i_sq_head_idx, NOT ROB-tag age: committed
    // entries can outlive their ROB tag (reused next lap), which makes
    // tag-based age rank them as youngest when they are in fact the oldest.
    // Slot order is allocation (= program) order and is wrap-proof.
    logic [IdxWidth-1:0] age;
    logic                can_forward;
    logic [IdxWidth-1:0] idx;
    logic [2:0]          store_off;
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

  // Five-bit-tiled dword-address comparator: the XOR is reduced in 5-bit groups
  // so Vivado maps each group into one LUT
  // ahead of a shallow final NOR — same shape the word-granule version used
  // on this documented-critical compare cone, one bit narrower.
  function automatic logic dword_addr_eq(input logic [DwordAddrWidth-1:0] lhs,
                                         input logic [DwordAddrWidth-1:0] rhs);
    logic [DwordAddrWidth-1:0] diff;
    logic [5:0] group_has_diff;
    begin
      diff = lhs ^ rhs;
      group_has_diff[0] = |diff[4:0];
      group_has_diff[1] = |diff[9:5];
      group_has_diff[2] = |diff[14:10];
      group_has_diff[3] = |diff[19:15];
      group_has_diff[4] = |diff[24:20];
      group_has_diff[5] = |diff[DwordAddrWidth-1:25];
      dword_addr_eq = ~(|group_has_diff);
    end
  endfunction

  // Generate byte-enable mask from address offset and size (8-lane strobes
  // on the aligned-dword beat; DOUBLE covers the whole beat).
  function automatic logic [riscv_pkg::MemStrbBits-1:0] gen_byte_en(
      input logic [2:0] addr_offset, input riscv_pkg::mem_size_e size);
    begin
      gen_byte_en = riscv_pkg::mem_strobe_for(2'(size), addr_offset);
    end
  endfunction

  // Forwarding scan results — promoted to module scope so the per-entry
  // qualification mask and winner select stay in separate blocks and avoid
  // UNOPTFLAT circular combinational logic.
  logic fwd_all_older_known;
  logic fwd_found_match;
  logic fwd_can_fwd;
  logic [IdxWidth-1:0] fwd_match_idx;
  logic [2:0] fwd_winner_store_off;
  logic [riscv_pkg::MemStrbBits-1:0] fwd_load_byte_mask;
  logic [DEPTH-1:0] fwd_addr_unknown_mask;
  logic [DEPTH-1:0] fwd_conflict_mask;
  logic [DEPTH-1:0] fwd_can_forward_mask;
  logic [ReorderBufferTagWidth:0] fwd_load_age;
  logic [ReorderBufferTagWidth:0] fwd_entry_age[DEPTH];
  logic [IdxWidth-1:0] fwd_entry_slot_age[DEPTH];
`ifdef FORMAL
  // Old implementation's pre-register payload expression, retained only as
  // an equivalence oracle for the registered-metadata retime.
  logic [FLEN-1:0] fwd_entry_data_reference[DEPTH];
`endif
`ifndef FORMAL
  // Balanced pairwise reduction tree over the DEPTH leaves, stored heap-ordered
  // in one flat array (a 2-D unpacked array is not yosys-parseable): node[1] is
  // the winner, node[2*k] and node[2*k+1] are the children of node[k], and the
  // leaves occupy node[FwdTreeWidth .. FwdTreeWidth+DEPTH-1]. Leaves past DEPTH
  // stay valid=0, which choose_newer_winner discards. At DEPTH = 8 this reduces
  // to exactly the previous explicit pair/quad/winner structure, with the
  // same operand pairing and the same rhs-wins tie-break, so the synthesized
  // logic and its timing are unchanged -- but the tree now tracks DEPTH instead
  // of silently ignoring entries 8 and above. (The rest of the SQ still assumes
  // a power-of-two DEPTH: its ring pointers index the entry arrays directly.)
  localparam int unsigned FwdTreeLevels = $clog2(DEPTH);
  localparam int unsigned FwdTreeWidth = 1 << FwdTreeLevels;
  fwd_winner_t fwd_node[2*FwdTreeWidth];
  fwd_winner_t fwd_winner;
`endif

  assign fwd_load_byte_mask = gen_byte_en(i_sq_check_addr[2:0], i_sq_check_size);
  assign fwd_load_age       = {1'b0, i_sq_check_rob_tag} - {1'b0, rob_head_tag_q};

  // Block 1: per-entry forwarding qualification from FF-based fields only
  // (no LUTRAM read, no inter-entry "last match wins" dependency).
  // Select older stores by ROB age directly so the forwarding path does not
  // need a head-relative barrel rotation over sq_valid/sq_addr_valid.
  always_comb begin
    logic same_dword;
    logic older_store;
    logic store_committed;
    logic [riscv_pkg::MemStrbBits-1:0] store_byte_mask;
    logic [riscv_pkg::MemStrbBits-1:0] load_byte_mask;
    logic [ReorderBufferTagWidth-1:0] entry_rob_tag;
    logic [XLEN-1:0] entry_address;
    riscv_pkg::mem_size_e entry_size;
`ifdef FORMAL
    logic [FLEN-1:0] entry_data_reference;
`endif
    // Four-way port split: each two-entry quarter uses one phase-identical
    // address captured by sister registers in the LQ. The constant selects
    // below collapse to wires after loop unrolling. This extends the original
    // two-anchor cut: post-place still measured a fo=12, 0.514 ns hop from
    // sq_check_addr_q to the first compare LUT on the winner-index WNS path.
    logic [XLEN-1:0] sq_check_addr_for_entry;
    logic [DwordAddrWidth-1:0] sq_check_dword_for_entry;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      same_dword = 1'b0;
      older_store = 1'b0;
      store_committed = 1'b0;
      store_byte_mask = '0;
      load_byte_mask = fwd_load_byte_mask;
      // The quarter boundaries are constant per loop iteration after synth
      // unroll, so the select collapses to a wire-pick, not a runtime mux.
      entry_rob_tag = sq_rob_tag_flat[i*ReorderBufferTagWidth+:ReorderBufferTagWidth];
      entry_address = sq_address_flat[i*XLEN+:XLEN];
`ifdef FORMAL
      entry_data_reference = sq_data_fwd_flat[i*FLEN+:FLEN];
`endif
      entry_size = riscv_pkg::mem_size_e'(sq_size_flat[i*MemSizeWidth+:MemSizeWidth]);
      if (i < (DEPTH / 4)) begin
        sq_check_addr_for_entry = i_sq_check_addr;
      end else if (i < (DEPTH / 2)) begin
        sq_check_addr_for_entry = i_sq_check_addr_b;
      end else if (i < ((3 * DEPTH) / 4)) begin
        sq_check_addr_for_entry = i_sq_check_addr_c;
      end else begin
        sq_check_addr_for_entry = i_sq_check_addr_d;
      end
      sq_check_dword_for_entry = sq_check_addr_for_entry[XLEN-1:3];
      fwd_entry_age[i] = {1'b0, entry_rob_tag} - {1'b0, rob_head_tag_q};
      // Program-order rank for winner selection: ring distance from the SQ
      // head.  DEPTH is a power of two, so the subtraction wraps naturally.
      fwd_entry_slot_age[i] = IdxWidth'(i) - i_sq_head_idx;
      fwd_addr_unknown_mask[i] = 1'b0;
      fwd_conflict_mask[i] = 1'b0;
      fwd_can_forward_mask[i] = 1'b0;
`ifdef FORMAL
      fwd_entry_data_reference[i] = '0;
`endif

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

        // Check for address overlap.  No access crosses its aligned dword,
        // so overlap is exactly: same dword AND intersecting 8-lane masks
        // (a DOUBLE's mask is 8'hFF, covering the whole beat).
        if (sq_addr_valid[i]) begin
          same_dword = dword_addr_eq(entry_address[XLEN-1:3], sq_check_dword_for_entry);
          store_byte_mask = gen_byte_en(entry_address[2:0], entry_size);

          if (same_dword && (|(store_byte_mask & load_byte_mask))) begin
            fwd_conflict_mask[i] = 1'b1;

            // Forwarding: only non-MMIO, non-SC stores with valid data.  A
            // store-conditional may fail at drain time and write nothing, so
            // its data must never reach a younger load early.
            //
            // Covered-subset forward: the store's lanes cover every lane the
            // load reads (exact-dword FLD-from-FSD is the FF ⊆ FF case).
            // Block 3 reconstructs the dword memory image; the LQ applies
            // the load's own extraction and sign/NaN handling.
            if (sq_data_valid[i] && !sq_is_mmio[i] && !sq_is_sc[i] &&
                ((store_byte_mask & load_byte_mask) == load_byte_mask)) begin
              fwd_can_forward_mask[i] = 1'b1;
`ifdef FORMAL
              fwd_entry_data_reference[i] = entry_data_reference << {entry_address[2:0], 3'b000};
`endif
            end
          end
        end
      end
    end
  end

  assign fwd_all_older_known = ~(|fwd_addr_unknown_mask);
  assign fwd_found_match     = |fwd_conflict_mask;

  // Block 2: newest conflicting store wins for data selection, ranked by SQ
  // ring-slot distance from i_sq_head_idx (allocation = program order;
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
  logic [2:0] fwd_formal_winner_store_off;
  logic [FLEN-1:0] fwd_selected_data_reference;

  always_comb begin
    fwd_formal_winner_valid     = 1'b0;
    fwd_formal_winner_age       = '0;
    fwd_formal_winner_store_off = '0;
    fwd_can_fwd                 = 1'b0;
    fwd_match_idx               = '0;
    fwd_selected_data_reference = '0;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      if (fwd_conflict_mask[i] &&
          (!fwd_formal_winner_valid || (fwd_entry_slot_age[i] >= fwd_formal_winner_age))) begin
        fwd_formal_winner_valid     = 1'b1;
        fwd_formal_winner_age       = fwd_entry_slot_age[i];
        fwd_formal_winner_store_off = sq_address_flat[i*XLEN+:3];
        fwd_can_fwd                 = fwd_can_forward_mask[i];
        fwd_match_idx               = IdxWidth'(i);
        fwd_selected_data_reference = fwd_entry_data_reference[i];
      end
    end
  end
  assign fwd_winner_store_off = fwd_formal_winner_store_off;
`else
  // Keep this as a balanced tree: the old serial loop let an SQ-check address
  // bit feed each entry's conflict logic and then walk a DEPTH-entry winner
  // chain before reaching o_sq_forward.can_forward.
  always_comb begin
    // Default every node first: the power-of-two padding above DEPTH must read
    // as invalid, and defaulting the whole array keeps the unused node[0] and
    // any padding leaves from inferring latches.
    for (int unsigned n = 0; n < 2 * FwdTreeWidth; n++) begin
      fwd_node[n] = '0;
    end

    for (int unsigned i = 0; i < DEPTH; i++) begin
      fwd_node[FwdTreeWidth+i].valid       = fwd_conflict_mask[i];
      fwd_node[FwdTreeWidth+i].age         = fwd_entry_slot_age[i];
      fwd_node[FwdTreeWidth+i].can_forward = fwd_can_forward_mask[i];
      fwd_node[FwdTreeWidth+i].idx         = IdxWidth'(i);
      fwd_node[FwdTreeWidth+i].store_off   = sq_address_flat[i*XLEN+:3];
    end

    // Descending order so both children are final before their parent.
    for (int n = int'(FwdTreeWidth) - 1; n >= 1; n--) begin
      fwd_node[n] = choose_newer_winner(fwd_node[2*n], fwd_node[(2*n)+1]);
    end

    fwd_winner    = fwd_node[1];

    fwd_can_fwd   = fwd_winner.valid && fwd_winner.can_forward;
    fwd_match_idx = fwd_winner.idx;
  end
  assign fwd_winner_store_off = fwd_winner.store_off;
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
  end

  // The winner metadata uses the SAME capture enable as match/can_forward.
  // Data is selected from the write-once per-entry FF mirror after this edge,
  // during the existing LQ consume cycle.  A forwardable entry's mirror cannot
  // be overwritten before the consumer edge: sq_data_we requires the old
  // sq_data_valid bit to be zero, while can_forward requires it to be one.
  // Capturing store_off here also makes a same-edge free, flush, or slot
  // reuse unable to change the selected payload interpretation.
  logic [IdxWidth-1:0] fwd_match_idx_q;
  logic [2:0] fwd_winner_store_off_q;

  // These are payload metadata, meaningful only with registered can_forward,
  // so like the old payload register they need no reset value.
  always_ff @(posedge i_clk) begin
    if (i_sq_check_capture_valid) begin
      fwd_match_idx_q        <= fwd_match_idx;
      fwd_winner_store_off_q <= fwd_winner_store_off;
    end
  end

  logic [FLEN-1:0] fwd_selected_raw_q;
  always_comb begin
    fwd_selected_raw_q = sq_data_fwd_flat[fwd_match_idx_q*FLEN+:FLEN];

    // Consumers qualify data with can_forward, so keep that control off the
    // 64 payload bits.  The image places the store data at its byte lanes in
    // the aligned dword; covered-subset forwarding guarantees the load only
    // reads lanes the store actually wrote (an aligned dword store shifts by
    // zero and passes through whole).
    o_sq_forward.data  = fwd_selected_raw_q << {fwd_winner_store_off_q, 3'b000};
  end

`ifdef FORMAL
  // Capture the old implementation's 64-bit D expression on the same edge as
  // the new compact metadata.  The assertion proves both value equivalence and
  // the store_queue contract that a selected write-once mirror remains stable
  // through the following LQ consume cycle.
  logic [FLEN-1:0] fwd_selected_data_reference_q;
  always_ff @(posedge i_clk) begin
    if (i_sq_check_capture_valid) begin
      fwd_selected_data_reference_q <= fwd_selected_data_reference;
    end
  end

  always_comb begin
    if (i_rst_n && o_sq_forward.can_forward) begin
      p_registered_metadata_data_exact :
      assert (o_sq_forward.data == fwd_selected_data_reference_q);
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst_n) begin
      cover_forward_aligned : cover (o_sq_forward.can_forward && fwd_winner_store_off_q == 3'b000);
      cover_forward_shifted : cover (o_sq_forward.can_forward && fwd_winner_store_off_q != 3'b000);
      cover_wrapped_winner :
      cover (i_sq_check_capture_valid && fwd_can_fwd && fwd_match_idx < i_sq_head_idx);
      cover_flush_cycle_capture : cover (i_flush_all && i_sq_check_capture_valid);
    end
  end
`endif

endmodule
