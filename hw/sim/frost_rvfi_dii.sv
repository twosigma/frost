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
  RVFI-DII harness for TestRIG (simulation only). frost_rvfi_platform instantiates it
  when FROST_RVFI_DII is defined; verif/cocotb_tests/test_rvfi_dii.py loads an
  instruction stream into it, releases reset, and reads back one record per
  retired or trapped instruction.

  Direct instruction injection. TestRIG feeds instructions by position in a
  stream, not by address: the k-th instruction to retire or trap executes
  stream word k at whatever PC the architecture reaches. This module stands in
  for the low-BRAM instruction memory and answers every fetch window from a
  layout of the stream: word r at address R, word r+1 at R plus the length of
  word r (2 bytes for a compressed parcel, otherwise 4), and so on. Bytes
  outside the layout read as C.NOP. The layout (R, r) changes only when the
  fetch PC loads a redirect from pc_controller's arms 0 to 4, on that edge:
    - reset: (0, 0);
    - trap or xRET, FENCE-class flush, commit-time misprediction recovery:
      the target and the number of stream words consumed so far;
    - early misprediction recovery: the target and one past the branch,
      whose stream index is the consumed count plus its distance from the ROB
      head (dispatch gives every instruction one ROB entry, in order);
    - PD redirect: the target and one past the PD branch, found by its PC in
      the current layout.
  frost_rvfi_platform disables branch prediction in this build, so fetch never leaves
  the current layout on its own and every instruction in IF, PD, and ID was
  fetched from it. Responses take one cycle and are computed from the layout
  current when they are presented, so a response presented after a redirect
  can only belong to the new path, and IF discards one whose served tag does
  not match.

  Retirement records. Each cycle's events, in program order: a slot-1
  commit, a slot-2 commit, an xRET take, an exception take. Each consumes the
  next stream word. A memory-order replay or an interrupt consumes none
  (interrupts are tied off in this build, and one counts as an error). Store
  data comes from the store queue's in-order memory writes, matched to the
  stores the SQ accepted at commit; AMO data from the atomic unit's write; a
  CSR read value from commit_actions' delayed write-back.

  Device window. Loads and stores that FROST's PMA sends to the device
  quadrant use a RAM here instead of the devices, so the reference model can
  describe them as memory. The RAM, the DDR model (axi_behavioral_memory),
  and the low BRAM data copy (frost_rvfi_platform) clear on every reset.
*/
module frost_rvfi_dii #(
    parameter int unsigned XLEN = riscv_pkg::XLEN,
    // Stream words, including the FROST-only reset preamble.
    parameter int unsigned MaxInsns = 8192,
    // Recorded events (retirements and traps): every stream word, the event
    // after the last one, and the events that retire while completion is
    // detected.
    parameter int unsigned MaxEvents = MaxInsns + 16,
    localparam int unsigned TagW = riscv_pkg::ReorderBufferTagWidth
) (
    input logic i_clk,
    input logic i_rst,

    // Instruction memory, in place of imem_predecode's fetch port: the
    // virtual address of the presented window request, and the one-cycle
    // response with its predecode views.
    input  logic [                                 31:0] i_fetch_address,
    // Bit 2 of the physical address of the window's first word (equal to the
    // virtual one whenever the translation is valid), for the bank select.
    input  logic                                         i_fetch_parity,
    output logic [                                 63:0] o_fetch_data,
    output logic [                                 63:0] o_fetch_data_by_parity,
    output logic [riscv_pkg::ImemFetchSidebandWidth-1:0] o_fetch_sideband,
    output logic [                                  7:0] o_fetch_pc_metadata,
    output logic [                                  7:0] o_fetch_pc_metadata_by_parity,
    output logic [                                  3:0] o_fetch_pc_pairability_by_parity,
    output logic [                                  1:0] o_fetch_slot2_start_valid_lo_by_parity,
    output logic                                         o_fetch_bank_sel_r,

    // Fetch-PC redirects: pc_controller's one-hot arm select, its load
    // enable, and the values of arms 1 to 4.
    input logic [riscv_pkg::PcNextArms-1:0] i_npc_sel,
    input logic                             i_pc_update_en,
    input logic [                 XLEN-1:0] i_trap_redirect_pc,
    input logic [                 XLEN-1:0] i_fence_redirect_pc,
    input logic [                 XLEN-1:0] i_branch_redirect_pc,
    input logic [                 XLEN-1:0] i_pd_redirect_pc,
    // The PD-stage branch behind a PD redirect.
    input logic [                 XLEN-1:0] i_pd_branch_pc,
    input logic                             i_early_mispredict_active,
    input logic [                 TagW-1:0] i_early_mispredict_tag,
    input logic [                   TagW:0] i_rob_head_ptr,

    // Retirement.
    input riscv_pkg::reorder_buffer_commit_t            i_commit,
    input logic                                         i_commit_valid,
    input riscv_pkg::reorder_buffer_commit_t            i_commit_2,
    input logic                                         i_commit_2_valid,
    input logic                                         i_xret_taken,
    input logic                              [XLEN-1:0] i_xret_pc,
    input logic                              [XLEN-1:0] i_xret_target,
    input logic                                         i_trap_taken,
    input logic                                         i_trap_no_csr,
    input logic                                         i_trap_to_d,
    input logic                              [XLEN-1:0] i_trap_cause,
    input logic                              [XLEN-1:0] i_trap_pc,
    input logic                              [XLEN-1:0] i_trap_target,
    input logic                              [     1:0] i_priv,
    // commit_actions' delayed CSR write-back (the CSR's read value).
    input logic                                         i_csr_wb_pending,
    input logic                              [XLEN-1:0] i_csr_wb_data,
    // The SQ accepted the previous cycle's slot-1 or slot-2 commit as a store
    // (a successful SC included, a failed one excluded).
    input logic                                         i_sq_commit_valid,
    input logic                                         i_sq_commit_valid_2,
    // Store-queue memory writes: one per committed store, in order, as an
    // aligned 64-bit beat with replicated data and a byte strobe.
    input logic                                         i_sq_write_en,
    input logic                              [XLEN-1:0] i_sq_write_addr,
    input logic                              [    63:0] i_sq_write_data,
    input logic                              [     7:0] i_sq_write_strb,
    // The atomic unit's write for an AMO at the ROB head.
    input logic                                         i_amo_write_en,
    input logic                              [XLEN-1:0] i_amo_write_addr,
    input logic                              [    63:0] i_amo_write_data,
    input logic                                         i_amo_write_is_dword,

    // Device-quadrant RAM: a load's dword address with its capture pulse,
    // and a store's beat.
    input  logic [31:0] i_dev_read_addr,
    input  logic        i_dev_read_capture,
    output logic [63:0] o_dev_read_data,
    input  logic        i_dev_write_en,
    input  logic [31:0] i_dev_write_addr,
    input  logic [63:0] i_dev_write_data,
    input  logic [ 7:0] i_dev_write_strb
);

  // ===========================================================================
  // State written and read by the cocotb test (public through cocotb's
  // --public-flat-rw Verilator build).
  // ===========================================================================
  // The stream and its length. Words at and beyond dii_count read as C.NOP.
  logic [31:0] dii_insn[MaxInsns];
  int unsigned dii_count;
  // Stop condition: event_target events recorded and every record complete,
  // or no event for hang_limit cycles.
  int unsigned event_target;
  int unsigned hang_limit;

  // One record per event (field offsets in rvfi_record_t below, decoded by
  // the cocotb test).
  typedef struct packed {
    logic [137:0] reserved;
    logic         csr_pending;    // waiting for the CSR read value
    logic         store_pending;  // waiting for the store's memory write
    logic         valid;
    logic [1:0]   mode;
    logic         trap;
    logic [7:0]   rd_addr;
    logic [7:0]   mem_wmask;
    logic [31:0]  insn;
    logic [63:0]  mem_wdata;
    logic [63:0]  mem_addr;
    logic [63:0]  rd_wdata;
    logic [63:0]  pc_wdata;
    logic [63:0]  pc_rdata;
  } rvfi_record_t;

  rvfi_record_t rvfi_record[MaxEvents];
  int unsigned event_count;
  logic done;
  logic hung;
  // Sticky harness errors (bit meanings in the cocotb test): 0 interrupt
  // taken, 1 record overflow, 2 store write without a pending store, 3 CSR
  // write-back without a pending CSR, 4 AMO retired without a write, 5 a
  // fetch redirect from a prediction arm, 6 a retirement in an early-recovery
  // cycle, 7 two control events in one cycle, 8 a misprediction redirect not
  // loaded into the fetch PC, 9 a PD redirect from a PC outside the layout.
  logic [31:0] error_flags;
  // A PD redirect whose branch PC is not a laid-out word (error bit 9).
  logic pd_branch_outside_layout;

  // ===========================================================================
  // Stream layout
  // ===========================================================================
  // offset[k] is word k's byte offset from word 0 when the whole stream is laid
  // out sequentially; a layout (R, r) puts word k at R + offset[k] - offset[r].
  // Recomputed in every reset cycle, after the test has written the stream.
  int unsigned offset[MaxInsns+1];
  logic [XLEN-1:0] layout_pc;
  int unsigned layout_index;

  localparam logic [15:0] CNop = 16'h0001;

  function automatic int unsigned insn_length(input logic [31:0] insn);
    insn_length = (insn[1:0] == 2'b11) ? 4 : 2;
  endfunction

  always @(posedge i_clk) begin
    if (i_rst) begin
      offset[0] = 0;
      for (int unsigned k = 0; k < MaxInsns; k++) begin
        offset[k+1] = offset[k] + insn_length(dii_insn[k]);
      end
    end
  end

  // Stream index of the word whose layout covers byte offset `position`
  // from word 0 (binary search; the offsets increase strictly).
  function automatic int unsigned word_at_offset(input longint unsigned position);
    int unsigned lo, hi, mid;
    lo = 0;
    hi = dii_count;  // offset[lo] <= position < offset[hi]
    while (hi - lo > 1) begin
      mid = lo + (hi - lo) / 2;
      if (longint'(offset[mid]) <= position) lo = mid;
      else hi = mid;
    end
    word_at_offset = lo;
  endfunction

  // The halfword at a (halfword-aligned) address under the current layout.
  function automatic logic [15:0] layout_halfword(input logic [31:0] address);
    logic [31:0] relative;
    longint unsigned position;
    int unsigned k;
    relative = address - layout_pc[31:0];
    // Addresses below the layout base, and a layout starting past the end of
    // the stream, read as filler.
    if (relative[31] || layout_index >= dii_count) return CNop;
    position = longint'(offset[layout_index]) + longint'(relative);
    if (position >= longint'(offset[dii_count])) return CNop;
    k = word_at_offset(position);
    return (position == longint'(offset[k])) ? dii_insn[k][15:0] : dii_insn[k][31:16];
  endfunction

  // The stream index of the instruction at a PC under the current layout, or
  // MaxInsns when the PC is not the start of a laid-out word.
  function automatic int unsigned layout_index_of(input logic [XLEN-1:0] pc);
    logic [31:0] relative;
    longint unsigned position;
    int unsigned k;
    relative = pc[31:0] - layout_pc[31:0];
    if (relative[31] || layout_index >= dii_count) return MaxInsns;
    position = longint'(offset[layout_index]) + longint'(relative);
    if (position >= longint'(offset[dii_count])) return MaxInsns;
    k = word_at_offset(position);
    return (position == longint'(offset[k])) ? k : MaxInsns;
  endfunction

  // ===========================================================================
  // Instruction memory
  // ===========================================================================
  // Register the request like a block-RAM read; compute the response from
  // the layout current at the output.
  logic [29:0] request_word_q;
  logic request_parity_q;
  always_ff @(posedge i_clk) begin
    request_word_q   <= i_fetch_address[31:2];
    request_parity_q <= i_fetch_parity;
  end

  logic [31:0] current_word, next_word, even_word, odd_word;
  logic [riscv_pkg::ImemSidebandWidth-1:0] even_sideband, odd_sideband;
  logic [3:0] even_pc_metadata, odd_pc_metadata;

  function automatic logic [3:0] pc_metadata(input logic [riscv_pkg::ImemSidebandWidth-1:0] sb);
    pc_metadata = {
      sb[riscv_pkg::ImemSbPairableNativeHi],
      sb[riscv_pkg::ImemSbPairableCompressedHi],
      sb[riscv_pkg::ImemSbIsCompressedHi],
      sb[riscv_pkg::ImemSbIsCompressedLo]
    };
  endfunction

  always_comb begin
    logic [31:0] base;
    base = {request_word_q, 2'b00};
    current_word = {layout_halfword(base + 32'd2), layout_halfword(base)};
    next_word = {layout_halfword(base + 32'd6), layout_halfword(base + 32'd4)};
  end

  assign o_fetch_bank_sel_r = request_parity_q;
  assign even_word = o_fetch_bank_sel_r ? next_word : current_word;
  assign odd_word = o_fetch_bank_sel_r ? current_word : next_word;
  assign even_sideband = riscv_pkg::imem_make_sideband(even_word);
  assign odd_sideband = riscv_pkg::imem_make_sideband(odd_word);
  assign even_pc_metadata = pc_metadata(even_sideband);
  assign odd_pc_metadata = pc_metadata(odd_sideband);

  assign o_fetch_data = {next_word, current_word};
  assign o_fetch_data_by_parity = {odd_word, even_word};
  assign o_fetch_sideband = o_fetch_bank_sel_r ? {even_sideband, odd_sideband} :
                                                 {odd_sideband, even_sideband};
  assign o_fetch_pc_metadata = o_fetch_bank_sel_r ? {even_pc_metadata, odd_pc_metadata} :
                                                    {odd_pc_metadata, even_pc_metadata};
  assign o_fetch_pc_metadata_by_parity = {odd_pc_metadata, even_pc_metadata};
  assign o_fetch_pc_pairability_by_parity = {
    odd_sideband[riscv_pkg::ImemSbPairableNativeLo],
    odd_sideband[riscv_pkg::ImemSbEvenLocalPairValid],
    even_sideband[riscv_pkg::ImemSbPairableNativeLo],
    even_sideband[riscv_pkg::ImemSbEvenLocalPairValid]
  };
  assign o_fetch_slot2_start_valid_lo_by_parity = {
    odd_sideband[riscv_pkg::ImemSbSlot2StartValidLo],
    even_sideband[riscv_pkg::ImemSbSlot2StartValidLo]
  };

  // ===========================================================================
  // Events
  // ===========================================================================
  logic event_commit, event_commit_2, event_exception;
  assign event_commit = i_commit_valid;
  assign event_commit_2 = i_commit_2_valid;
  // A Debug Mode entry or park, or a memory-order replay, writes no trap CSR
  // and consumes no stream word.
  assign event_exception = i_trap_taken && !i_trap_no_csr && !i_trap_to_d && !i_trap_cause[XLEN-1];
  int unsigned events_this_cycle;
  assign events_this_cycle = int'(event_commit) + int'(event_commit_2) + int'(i_xret_taken) +
      int'(event_exception);

  function automatic logic [XLEN-1:0] retired_next_pc(
      input riscv_pkg::reorder_buffer_commit_t commit);
    if (commit.is_branch || commit.is_mret) retired_next_pc = commit.redirect_pc;
    else retired_next_pc = commit.pc + (commit.is_compressed ? 64'd2 : 64'd4);
  endfunction

  function automatic rvfi_record_t commit_record(input riscv_pkg::reorder_buffer_commit_t commit,
                                                 input int unsigned index, input logic [1:0] priv);
    rvfi_record_t r;
    r = '0;
    r.valid = 1'b1;
    r.pc_rdata = commit.pc;
    r.pc_wdata = retired_next_pc(commit);
    r.insn = (index < MaxInsns) ? dii_insn[index] : 32'h0;
    r.mode = priv;
    // Integer destinations only: like Sail, FP register writes are not
    // reported. x0 is never reported.
    if (commit.dest_valid && !commit.dest_rf && (commit.dest_reg != 0)) begin
      r.rd_addr = 8'(commit.dest_reg);
      r.rd_wdata = commit.value[XLEN-1:0];
      r.csr_pending = commit.is_csr;
    end
    commit_record = r;
  endfunction

  // Indices of the previous cycle's commits, for the SQ's commit acceptance.
  int unsigned prev_commit_index, prev_commit_2_index;
  // Records waiting for their store's memory write, oldest first.
  int unsigned store_queue[$];
  int unsigned csr_pending_index;
  logic csr_pending;
  // The last AMO write, consumed by the AMO's retirement.
  logic amo_write_seen;
  logic [XLEN-1:0] amo_write_addr;
  logic [63:0] amo_write_data;
  logic amo_write_is_dword;
  int unsigned idle_cycles;
  // Events whose store-queue acceptance has been seen: the SQ reports a
  // commit's store the cycle after it retires, so this trails event_count by
  // one cycle.
  int unsigned store_checked_count;

  always @(posedge i_clk) begin
    if (i_rst) begin
      event_count <= 0;
      store_checked_count <= 0;
      done <= 1'b0;
      hung <= 1'b0;
      error_flags <= '0;
      store_queue.delete();
      csr_pending <= 1'b0;
      amo_write_seen <= 1'b0;
      idle_cycles <= 0;
      prev_commit_index <= 0;
      prev_commit_2_index <= 0;
      for (int unsigned i = 0; i < MaxEvents; i++) rvfi_record[i] <= '0;
    end else begin
      int unsigned n;
      n = event_count;

      // Stores the SQ accepted at last cycle's commit, slot 1 first.
      if (i_sq_commit_valid) begin
        store_queue.push_back(prev_commit_index);
        if (prev_commit_index < MaxEvents) rvfi_record[prev_commit_index].store_pending <= 1'b1;
      end
      if (i_sq_commit_valid_2) begin
        store_queue.push_back(prev_commit_2_index);
        if (prev_commit_2_index < MaxEvents) rvfi_record[prev_commit_2_index].store_pending <= 1'b1;
      end

      if (event_commit) begin
        if (n < MaxEvents) begin
          rvfi_record_t r;
          r = commit_record(i_commit, n, i_priv);
          if (i_commit.is_amo && !i_commit.is_lr && !i_commit.is_sc) begin
            if (amo_write_seen) begin
              r.mem_addr = amo_write_is_dword ? {amo_write_addr[XLEN-1:3], 3'b000} :
                                                {amo_write_addr[XLEN-1:2], 2'b00};
              r.mem_wmask = amo_write_is_dword ? 8'hFF : 8'h0F;
              r.mem_wdata = amo_write_is_dword ? amo_write_data :
                  {32'h0, (amo_write_addr[2] ? amo_write_data[63:32] : amo_write_data[31:0])};
            end else begin
              error_flags[4] <= 1'b1;
            end
          end
          rvfi_record[n] <= r;
          if (r.csr_pending) csr_pending_index <= n;
        end
        if (i_commit.is_csr && i_commit.dest_valid && !i_commit.dest_rf) csr_pending <= 1'b1;
        prev_commit_index <= n;
        n++;
      end
      if (event_commit_2) begin
        if (n < MaxEvents) rvfi_record[n] <= commit_record(i_commit_2, n, i_priv);
        prev_commit_2_index <= n;
        n++;
      end
      if (i_xret_taken) begin
        if (n < MaxEvents) begin
          rvfi_record_t r;
          r = '0;
          r.valid = 1'b1;
          r.pc_rdata = i_xret_pc;
          r.pc_wdata = i_xret_target;
          r.insn = (n < MaxInsns) ? dii_insn[n] : 32'h0;
          r.mode = i_priv;
          rvfi_record[n] <= r;
        end
        n++;
      end
      if (event_exception) begin
        if (n < MaxEvents) begin
          rvfi_record_t r;
          r = '0;
          r.valid = 1'b1;
          r.trap = 1'b1;
          r.pc_rdata = i_trap_pc;
          r.pc_wdata = i_trap_target;
          r.insn = (n < MaxInsns) ? dii_insn[n] : 32'h0;
          r.mode = i_priv;
          rvfi_record[n] <= r;
        end
        n++;
      end
      if (i_trap_taken && i_trap_cause[XLEN-1]) error_flags[0] <= 1'b1;
      if (n > MaxEvents) error_flags[1] <= 1'b1;
      if (int'(i_xret_taken) + int'(event_exception) + int'(event_commit) > 1)
        error_flags[7] <= 1'b1;
      event_count <= n;

      // CSR read value.
      if (i_csr_wb_pending) begin
        if (!csr_pending) error_flags[3] <= 1'b1;
        else begin
          if (csr_pending_index < MaxEvents && rvfi_record[csr_pending_index].csr_pending) begin
            rvfi_record[csr_pending_index].rd_wdata <= i_csr_wb_data;
            rvfi_record[csr_pending_index].csr_pending <= 1'b0;
          end
          csr_pending <= 1'b0;
        end
      end

      // Store data, matched in order.
      if (i_sq_write_en) begin
        if (store_queue.size() == 0) error_flags[2] <= 1'b1;
        else begin
          int unsigned s;
          int unsigned lane;
          logic [7:0] mask;
          logic [63:0] value;
          s = store_queue.pop_front();
          lane = 0;
          while (lane < 8 && !i_sq_write_strb[lane]) lane++;
          // The strobe as written, from its lowest byte, so a strobe with a
          // gap or the wrong width shows up in mem_wmask.
          mask  = i_sq_write_strb >> lane;
          value = i_sq_write_data >> (8 * lane);
          for (int b = 0; b < 8; b++) begin
            if (!mask[b]) value[b*8+:8] = 8'h00;
          end
          if (s < MaxEvents) begin
            rvfi_record[s].mem_addr <= {i_sq_write_addr[XLEN-1:3], 3'(lane)};
            rvfi_record[s].mem_wmask <= mask;
            rvfi_record[s].mem_wdata <= value;
            rvfi_record[s].store_pending <= 1'b0;
          end
        end
      end

      // AMO write, consumed by the AMO's retirement (always later).
      if (i_amo_write_en) begin
        amo_write_seen <= 1'b1;
        amo_write_addr <= i_amo_write_addr;
        amo_write_data <= i_amo_write_data;
        amo_write_is_dword <= i_amo_write_is_dword;
      end else if (event_commit && i_commit.is_amo) begin
        amo_write_seen <= 1'b0;
      end

      // Completion and hang detection. Events counted at the start of this
      // cycle have had their SQ acceptance checked above.
      store_checked_count <= event_count;
      idle_cycles <= (events_this_cycle != 0) ? 0 : idle_cycles + 1;
      if (!done) begin
        if (idle_cycles > hang_limit) begin
          hung <= 1'b1;
          done <= 1'b1;
        end else if ((store_checked_count >= event_target) && (store_queue.size() == 0) &&
                     !csr_pending && !i_csr_wb_pending) begin
          done <= 1'b1;
        end
      end

      if (event_commit && i_early_mispredict_active) error_flags[6] <= 1'b1;
      // Arms 7 to 10 and 12 follow branch predictions, which this build
      // disables. Arm 11 (halfword catch-up) is sequential and allowed.
      if (i_pc_update_en && (|i_npc_sel[10:7] || i_npc_sel[12])) error_flags[5] <= 1'b1;
      if (i_npc_sel[3] && !i_pc_update_en) error_flags[8] <= 1'b1;
      if (pd_branch_outside_layout) error_flags[9] <= 1'b1;
    end
  end

  // ===========================================================================
  // Layout updates, on the edge that loads a redirect into the fetch PC
  // ===========================================================================
  always @(posedge i_clk) begin
    if (i_rst) begin
      layout_pc <= '0;
      layout_index <= 0;
    end else if (i_pc_update_en) begin
      int unsigned consumed;
      consumed = event_count + events_this_cycle;
      if (i_npc_sel[1]) begin
        layout_pc <= i_trap_redirect_pc;
        layout_index <= consumed;
      end else if (i_npc_sel[2]) begin
        layout_pc <= i_fence_redirect_pc;
        layout_index <= consumed;
      end else if (i_npc_sel[3]) begin
        layout_pc <= i_branch_redirect_pc;
        if (i_early_mispredict_active) begin
          // The ROB holds consecutive stream words starting at its head.
          layout_index <= event_count + 1 +
              int'(TagW'(i_early_mispredict_tag - i_rob_head_ptr[TagW-1:0]));
        end else begin
          layout_index <= consumed;
        end
      end else if (i_npc_sel[4]) begin
        layout_pc <= i_pd_redirect_pc;
        layout_index <= layout_index_of(i_pd_branch_pc) + 1;
      end
    end
  end

  always_ff @(posedge i_clk) begin
    if (i_rst) pd_branch_outside_layout <= 1'b0;
    else if (i_pc_update_en && (i_npc_sel[4:0] == 5'b10000)) begin
      if (layout_index_of(i_pd_branch_pc) == MaxInsns) pd_branch_outside_layout <= 1'b1;
    end
  end

  // ===========================================================================
  // Device-window RAM
  // ===========================================================================
  bit [63:0] device_ram[bit [28:0]];

  always @(posedge i_clk) begin
    if (i_rst) begin
      device_ram.delete();
    end else if (i_dev_write_en) begin
      bit [63:0] row;
      row = device_ram.exists(i_dev_write_addr[31:3]) ? device_ram[i_dev_write_addr[31:3]] : '0;
      for (int b = 0; b < 8; b++) begin
        if (i_dev_write_strb[b]) row[b*8+:8] = i_dev_write_data[b*8+:8];
      end
      device_ram[i_dev_write_addr[31:3]] = row;
    end
  end

  always_comb begin
    o_dev_read_data = device_ram.exists(i_dev_read_addr[31:3]) ? device_ram[i_dev_read_addr[31:3]] :
        '0;
  end

  // i_dev_read_capture is unused here: frost_rvfi_platform registers the value on it.
  logic unused_dev_read_capture;
  assign unused_dev_read_capture = i_dev_read_capture;

endmodule : frost_rvfi_dii
