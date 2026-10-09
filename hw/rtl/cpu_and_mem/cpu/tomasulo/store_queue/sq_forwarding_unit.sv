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
// Store-to-load forwarding CAM. Qualify entries, select the newest conflicting
// store, and register the result for the next cycle.
//
// Overlap is per aligned dword, as on the data bus (hw/rtl/README.md,
// "Data-tier bus contract"): every access is one dword beat with an 8-lane byte
// mask. Two accesses conflict when they share a dword and their masks
// intersect, and a store can forward when its mask covers the load's. The
// forwarded payload is the store data shifted to its byte lanes in the aligned
// dword. The LQ extracts from it by the load's own addr[2:0], or takes it whole
// for FLD/LD. The masks and payload shift require natural alignment.
// With a nonzero mtvec base (i_trap_misaligned_accesses), misaligned loads
// trap before probing. A faulting store may have an early address here, but
// its data stays invalid and cannot forward. With a zero mtvec base,
// alignment is unchecked and a misaligned store forwards incorrect byte lanes.
//
// Register the winning index and byte offset, then select the payload from
// store_queue's FF data mirror during the LQ consume cycle.
// =============================================================================
module sq_forwarding_unit #(
    parameter int unsigned DEPTH = riscv_pkg::SqDepth
) (
    input logic i_clk,
    input logic i_rst_n,
    input logic i_flush_all,

    // Load probe (from MEM_RS via LQ) + ROB head + commit snoop
    // Capture omits flush and commit-block gates for timing. The LQ qualifies
    // consumption instead
    // (hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/README.md, "Forwarding
    // results captured on a flush cycle").
    input logic i_sq_check_capture_valid,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_b,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_c,
    input logic [riscv_pkg::XLEN-1:0] i_sq_check_addr_d,
    input riscv_pkg::mem_size_e i_sq_check_size,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_sq_check_rob_tag,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_rob_head_tag,
    // Commit pulses for the same-cycle committed-store guard in Block 1.
    // store_queue supplies i_commit_valid_scan* without the full-flush mask.
    // A full-flush-cycle capture is never consumed (see Block 3).
    input logic i_commit_valid,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag,
    input logic i_commit_valid_2,
    input logic [riscv_pkg::ReorderBufferTagWidth-1:0] i_commit_rob_tag_2,

    // SQ ring head (oldest entry not yet freed). Block 2 ranks conflicting
    // stores by ring distance from it.
    input logic [$clog2(DEPTH)-1:0] i_sq_head_idx,

    // SQ entry-array state, named as in store_queue (no i_ prefix)
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

  localparam int unsigned ReorderBufferTagWidth = riscv_pkg::ReorderBufferTagWidth;
  localparam int unsigned XLEN = riscv_pkg::XLEN;
  localparam int unsigned FLEN = riscv_pkg::FLEN;
  localparam int unsigned MemSizeWidth = 2;
  localparam int unsigned DwordAddrWidth = XLEN - 3;
  localparam int unsigned IdxWidth = $clog2(DEPTH);

  typedef struct packed {
    logic                valid;
    // Ring distance from i_sq_head_idx, not ROB-tag age (see Block 2).
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

  // Group the address comparison for timing; the last group holds the high bits.
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

  // Separate qualification and selection blocks to avoid UNOPTFLAT warnings.
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
  // Reference payload computed by the scan: each forwardable entry's store
  // data shifted to its byte lanes. The formal check at the end of the module
  // compares the registered-metadata select against it.
  logic [FLEN-1:0] fwd_entry_data_reference[DEPTH];
`endif
`ifndef FORMAL
  // Heap-ordered reduction tree in a flat array for Yosys compatibility:
  // node[1] is the winner; node[2*k] and node[2*k+1] are node[k]'s children.
  // Leaves occupy node[FwdTreeWidth .. FwdTreeWidth+DEPTH-1]; padding is
  // invalid. SQ ring pointers require a power-of-two DEPTH.
  localparam int unsigned FwdTreeLevels = $clog2(DEPTH);
  localparam int unsigned FwdTreeWidth  = 1 << FwdTreeLevels;
  fwd_winner_t fwd_node[2*FwdTreeWidth];
  fwd_winner_t fwd_winner;
`endif

  assign fwd_load_byte_mask = gen_byte_en(i_sq_check_addr[2:0], i_sq_check_size);
  assign fwd_load_age       = {1'b0, i_sq_check_rob_tag} - {1'b0, rob_head_tag_q};

  // Block 1: qualify entries by ROB-tag age. Committed stores always count
  // as older than the probing load.
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
    // Each quarter uses an identical registered address copy for fanout.
    logic [XLEN-1:0] sq_check_addr_for_entry;
    logic [DwordAddrWidth-1:0] sq_check_dword_for_entry;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      same_dword = 1'b0;
      older_store = 1'b0;
      store_committed = 1'b0;
      store_byte_mask = '0;
      load_byte_mask = fwd_load_byte_mask;
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
      // head.  DEPTH is a power of two, so the subtraction wraps modulo DEPTH.
      fwd_entry_slot_age[i] = IdxWidth'(i) - i_sq_head_idx;
      fwd_addr_unknown_mask[i] = 1'b0;
      fwd_conflict_mask[i] = 1'b0;
      fwd_can_forward_mask[i] = 1'b0;
`ifdef FORMAL
      fwd_entry_data_reference[i] = '0;
`endif

      // Count both commit pulses before sq_committed updates, so a younger
      // load cannot pass a committing store regardless of ROB-head timing.
      store_committed = sq_committed[i] ||
                        (i_commit_valid && (entry_rob_tag == i_commit_rob_tag)) ||
                        (i_commit_valid_2 && (entry_rob_tag == i_commit_rob_tag_2));
      older_store = sq_valid[i] && (store_committed || (fwd_entry_age[i] < fwd_load_age));

      if (older_store) begin
        if (!sq_addr_valid[i]) begin
          fwd_addr_unknown_mask[i] = 1'b1;
        end

        // Overlap: same dword and intersecting 8-lane masks (a DOUBLE's mask
        // is 8'hFF, the whole beat).
        if (sq_addr_valid[i]) begin
          same_dword = dword_addr_eq(entry_address[XLEN-1:3], sq_check_dword_for_entry);
          store_byte_mask = gen_byte_en(entry_address[2:0], entry_size);

          if (same_dword && (|(store_byte_mask & load_byte_mask))) begin
            fwd_conflict_mask[i] = 1'b1;

            // Forward only from non-MMIO, non-SC stores with valid data whose
            // lanes cover every lane the load reads. A store-conditional can
            // fail and write nothing, so its data must never reach a younger
            // load.
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

  // Block 2: the newest conflicting store wins, ranked by ring distance from
  // i_sq_head_idx. Ring order is allocation order, which is program order.
  // ROB-tag age cannot rank here: a committed store can wait to drain after
  // its ROB tag has been reused, and tag age would then rank it newest and
  // forward stale data.
`ifdef FORMAL
  // Yosys treats fields of the tree's unpacked struct array as implicit wires.
  // Use an equivalent linear selector for formal builds.
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
  // Use a balanced tree for timing.
  always_comb begin
    // Default unused nodes and padding to invalid to avoid latches.
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

  // Block 3: register forwarding results for the following LQ cycle.
  //
  // No flush clear, for timing. Both readers in load_queue.sv (sq_can_issue
  // and sq_do_forward) require sq_check_phase2 and sq_check_entry_issueable,
  // which a full flush clears on the capture edge. The unused result clears
  // on the next edge because the flushed LQ presents no probe.
  //
  // Capture and scan-only commit pulses omit flush qualification. A captured
  // result may therefore include a squashed store's commit, but the same
  // consumer gates prevent its use.
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

  // The winner metadata uses the same capture enable as match/can_forward.
  // Data is selected from the write-once per-entry FF mirror after this edge,
  // during the LQ consume cycle. A forwardable entry's mirror cannot be
  // overwritten before the consumer edge: sq_data_we requires the entry's
  // sq_data_valid to be clear, while can_forward requires it to be set.
  // Capturing store_off here also keeps a same-edge free, flush, or slot reuse
  // from changing how the selected payload is interpreted.
  logic [IdxWidth-1:0] fwd_match_idx_q;
  logic [2:0] fwd_winner_store_off_q;

  // No reset: this metadata matters only when the registered can_forward is
  // set.
  always_ff @(posedge i_clk) begin
    if (i_sq_check_capture_valid) begin
      fwd_match_idx_q        <= fwd_match_idx;
      fwd_winner_store_off_q <= fwd_winner_store_off;
    end
  end

  logic [FLEN-1:0] fwd_selected_raw_q;
  always_comb begin
    fwd_selected_raw_q = sq_data_fwd_flat[fwd_match_idx_q*FLEN+:FLEN];

    // Consumers require can_forward. Shift into the store's byte lanes;
    // coverage qualification lets the load read only lanes the store wrote.
    o_sq_forward.data  = fwd_selected_raw_q << {fwd_winner_store_off_q, 3'b000};
  end

`ifdef FORMAL
  // Register the reference payload on the same edge as the winner metadata.
  // The assertion checks both that the metadata select reproduces it and the
  // store_queue contract that a selected write-once mirror stays stable
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
