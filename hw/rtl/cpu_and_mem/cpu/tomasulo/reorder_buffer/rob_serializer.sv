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
// rob_serializer
// =============================================================================
// Serializing-instruction FSM. Pins a WFI, CSR, FENCE, FENCE.I, SFENCE.VMA,
// xRET, or exceptional instruction at the ROB head while it waits for
// committed stores to drain or for a cache sync, a CSR handshake, the trap
// unit, or an interrupt. head_is_fence_i is also set for SFENCE.VMA, and
// head_is_mret for every xRET. serial_state_e lives in riscv_pkg.
//
// o_commit_stall is the full stall. o_commit_stall_for_retire drops the
// retirement-permission terms in FENCE_I_SYNC and CSR_TRANSLATION_DRAIN, so
// only retirement logic, which applies those terms itself, may use it.
// Performance counters and assertions use o_commit_stall.
// =============================================================================
module rob_serializer (
    input logic i_clk,
    input logic i_rst_n,
    input logic i_flush_all,
    input logic i_flush_en,
    input logic i_commit_hold,
    input logic i_early_recovery_en,
    input logic i_interrupt_pending,
    input logic i_sq_committed_empty,
    // FENCE.I cache sync handshake: the request is a level (decoded from the
    // sync state) held until the cache side reports done; done is a level
    // that stays high while the request is high, so no pulses can be missed.
    input logic i_fence_i_sync_done,
    input logic i_csr_done,
    input logic i_mret_done,
    input logic i_trap_taken,
    input logic head_ready,
    input logic head_exception,
    input logic head_is_wfi,
    input logic head_is_csr,
    input logic head_is_fence,
    input logic head_is_fence_i,
    input logic head_is_mret,
    input logic head_is_amo,
    input logic head_is_lr,
    input logic head_is_sfence,
    input logic head_csr_may_change_translation,

    output riscv_pkg::serial_state_e o_serial_state,
    output logic o_fence_i_sync_req,
    output logic o_sfence_window,
    // FENCE-class retirement events. o_native_fence_commit_event is high in
    // the cycle a FENCE.I or SFENCE.VMA retires, decoded from the serializer
    // state instead of the live ROB head. o_translation_csr_commit_event_q is
    // high the cycle after a translation CSR retires, while the registered
    // commit bus writes csr_file; the full flush follows a cycle later.
    output logic o_native_fence_commit_event,
    output logic o_translation_csr_commit_event_q,
    output logic o_commit_stall,
    // Retirement only: consumers must also apply the four retire_permit terms.
    output logic o_commit_stall_for_retire
);

  riscv_pkg::serial_state_e serial_state, serial_state_next;
  logic commit_stall;
  logic retire_permit;
  logic translation_csr_owner_q;
  logic translation_csr_commit_event;
  logic translation_csr_commit_event_q;

  // The head-independent terms of reorder_buffer's commit_en. Entering
  // FENCE_I_SYNC or CSR_TRANSLATION_DRAIN already required a valid, done,
  // non-exceptional head of the matching class, and that head stays pinned,
  // so the two retirement events use these terms and no head terms, which
  // keeps the live one-hot ROB-head read out of their logic.
  // i_flush_after_head_commit always arrives with i_flush_en or i_flush_all,
  // so it needs no term here.
  assign retire_permit = !i_commit_hold && !i_early_recovery_en && !i_flush_en && !i_flush_all;

  assign o_native_fence_commit_event =
      (serial_state == riscv_pkg::SERIAL_FENCE_I_SYNC) && i_fence_i_sync_done &&
      retire_permit;
  assign translation_csr_commit_event =
      (serial_state == riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN) &&
      i_sq_committed_empty && retire_permit;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      translation_csr_owner_q        <= 1'b0;
      translation_csr_commit_event_q <= 1'b0;
    end else begin
      if ((serial_state == riscv_pkg::SERIAL_IDLE) &&
          (serial_state_next == riscv_pkg::SERIAL_CSR_EXEC)) begin
        translation_csr_owner_q <= head_csr_may_change_translation;
      end
      translation_csr_commit_event_q <= translation_csr_commit_event;
    end
  end
  assign o_translation_csr_commit_event_q = translation_csr_commit_event_q;

  assign o_fence_i_sync_req = (serial_state == riscv_pkg::SERIAL_FENCE_I_SYNC);

  // Registered from the next state, so this level rises on the edge that
  // enters SERIAL_FENCE_I_SYNC and falls on the edge that leaves it. The head
  // is pinned for the whole sync, so the level equals o_fence_i_sync_req &&
  // head_is_sfence cycle for cycle, without the live one-hot ROB-head read in
  // the TLB/PTW invalidate logic.
  logic sfence_window_q;
  always_ff @(posedge i_clk) begin
    if (!i_rst_n || i_flush_all) begin
      sfence_window_q <= 1'b0;
    end else begin
      sfence_window_q <= (serial_state_next == riscv_pkg::SERIAL_FENCE_I_SYNC) && head_is_sfence;
    end
  end
  assign o_sfence_window = sfence_window_q;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      serial_state <= riscv_pkg::SERIAL_IDLE;
    end else if (i_flush_all) begin
      serial_state <= riscv_pkg::SERIAL_IDLE;
    end else begin
      serial_state <= serial_state_next;
    end
  end

  always_comb begin
    serial_state_next = serial_state;
    commit_stall = 1'b0;

    case (serial_state)
      riscv_pkg::SERIAL_IDLE: begin
        // TIMING: the IDLE stall omits the head_ready, !i_commit_hold,
        // !i_early_recovery_en, !i_flush_en, and !i_flush_all terms. Every
        // retirement consumer in reorder_buffer ANDs the stall with
        // commit_ready_early or another superset of those terms, so
        // <early> && !commit_stall is the same with or without them.
        // head_ready carries the same-cycle CDB head-done bypass, so leaving
        // it out keeps the stall logic off the CDB -> commit -> SQ/trap path.
        // The ROB's performance counters re-apply the omitted terms. The FSM
        // transitions below keep all of them.
        if (head_exception) begin
          // Exception: wait for trap unit
          commit_stall = 1'b1;
        end else if (head_is_wfi) begin
          // WFI: stall until an interrupt is pending
          commit_stall = !i_interrupt_pending;
        end else if (head_is_csr) begin
          // CSR: need to execute at commit
          commit_stall = 1'b1;
        end else if (head_is_fence || head_is_fence_i) begin
          // FENCE/FENCE.I: wait for committed SQ entries to drain. FENCE.I
          // also stalls through the cache sync.
          commit_stall = !(i_sq_committed_empty && !head_is_fence_i);
        end else if (head_is_mret) begin
          // xRET: signal the trap unit
          commit_stall = 1'b1;
        end
        // AMO/LR and non-serializing instructions: no stall

        if (head_ready && !i_commit_hold && !i_early_recovery_en &&
                          !i_flush_en    && !i_flush_all) begin
          if (head_exception) begin
            serial_state_next = riscv_pkg::SERIAL_TRAP_WAIT;
          end else if (head_is_wfi) begin
            // WFI: wait for an interrupt. When one is already pending the WFI
            // commits this cycle, so the state does not change.
            if (!i_interrupt_pending) begin
              serial_state_next = riscv_pkg::SERIAL_WFI_WAIT;
            end
          end else if (head_is_csr) begin
            serial_state_next = riscv_pkg::SERIAL_CSR_EXEC;
          end else if (head_is_fence || head_is_fence_i) begin
            // FENCE/FENCE.I: wait for committed SQ entries to drain. FENCE.I
            // then syncs the caches before committing, because the drained
            // stores sit dirty in the write-back L1D and the L1I and the
            // fetch buffer have to refill from post-writeback data.
            if (i_sq_committed_empty) begin
              if (head_is_fence_i) begin
                serial_state_next = riscv_pkg::SERIAL_FENCE_I_SYNC;
              end
              // Plain FENCE with drained SQ commits without serializing.
            end else begin
              serial_state_next = riscv_pkg::SERIAL_WAIT_SQ;
            end
          end else if (head_is_mret) begin
            serial_state_next = riscv_pkg::SERIAL_MRET_EXEC;
          end else if (head_is_amo || head_is_lr) begin
            // AMO/LR: ordering is enforced at LQ issue, which issues an LR
            // only at the ROB head and an AMO only at the head with committed
            // stores drained. Once the CDB marks the entry done it commits
            // through the ordinary path. Waiting here for an empty SQ would
            // deadlock on younger stores, which cannot commit before it.
          end
        end
      end

      riscv_pkg::SERIAL_WAIT_SQ: begin
        commit_stall = 1'b1;
        if (i_sq_committed_empty) begin
          if (head_is_fence_i) begin
            // FENCE.I continues into the cache sync once the SQ drains.
            serial_state_next = riscv_pkg::SERIAL_FENCE_I_SYNC;
          end else begin
            // Committed SQ entries drained, can commit
            serial_state_next = riscv_pkg::SERIAL_IDLE;
            commit_stall = 1'b0;
          end
        end
      end

      riscv_pkg::SERIAL_FENCE_I_SYNC: begin
        commit_stall = 1'b1;
        if (i_fence_i_sync_done && retire_permit) begin
          serial_state_next = riscv_pkg::SERIAL_IDLE;
          commit_stall = 1'b0;
        end
      end

      riscv_pkg::SERIAL_CSR_EXEC: begin
        commit_stall = 1'b1;
        if (i_csr_done) begin
          if (translation_csr_owner_q) begin
            // A CSR that may change translation waits for committed stores to
            // drain before it retires. Move unconditionally so the one-cycle
            // done pulse cannot be lost while stores drain or retirement is
            // not permitted.
            serial_state_next = riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN;
          end else begin
            // Ordinary CSR complete, can commit this cycle.
            serial_state_next = riscv_pkg::SERIAL_IDLE;
            commit_stall = 1'b0;
          end
        end
      end

      riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN: begin
        commit_stall = 1'b1;
        if (i_sq_committed_empty && retire_permit) begin
          serial_state_next = riscv_pkg::SERIAL_IDLE;
          commit_stall = 1'b0;
        end
      end

      riscv_pkg::SERIAL_MRET_EXEC: begin
        commit_stall = 1'b1;
        if (i_mret_done) begin
          // xRET complete, can commit
          serial_state_next = riscv_pkg::SERIAL_IDLE;
          commit_stall = 1'b0;
        end
      end

      riscv_pkg::SERIAL_WFI_WAIT: begin
        commit_stall = 1'b1;
        if (i_interrupt_pending) begin
          // Interrupt arrived, WFI can commit
          serial_state_next = riscv_pkg::SERIAL_IDLE;
          commit_stall = 1'b0;
        end
      end

      riscv_pkg::SERIAL_TRAP_WAIT: begin
        commit_stall = 1'b1;
        if (i_trap_taken) begin
          // The trap unit has taken the exception. A flush follows.
          serial_state_next = riscv_pkg::SERIAL_IDLE;
          // i_flush_all resets the state machine in any case.
        end
      end

      default: begin
        serial_state_next = riscv_pkg::SERIAL_IDLE;
      end
    endcase
  end

  assign o_serial_state = serial_state;
  assign o_commit_stall = commit_stall;

  // Retirement stall: keep the retire_permit terms off the stall path in
  // FENCE_I_SYNC and CSR_TRANSLATION_DRAIN. The FSM transitions and the two
  // retirement events keep them, and so does o_commit_stall, because the
  // performance counters count blocked cycles even while retirement is not
  // permitted.
  always_comb begin
    o_commit_stall_for_retire = commit_stall;
    case (serial_state)
      riscv_pkg::SERIAL_FENCE_I_SYNC: o_commit_stall_for_retire = !i_fence_i_sync_done;
      riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN: o_commit_stall_for_retire = !i_sq_committed_empty;
      default: ;
    endcase
  end

  // For the rob_retire_stall formal target: the two stalls differ only in
  // FENCE_I_SYNC and CSR_TRANSLATION_DRAIN while retirement is not permitted,
  // and the retirement stall is never set without o_commit_stall.
`ifdef ROB_RETIRE_STALL_LOCAL_PROOF
  always_comb begin
    assert (!retire_permit || (o_commit_stall_for_retire == commit_stall));
    assert (!o_commit_stall_for_retire || commit_stall);
    assert ((serial_state == riscv_pkg::SERIAL_FENCE_I_SYNC) ||
        (serial_state == riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN) ||
        (o_commit_stall_for_retire == commit_stall));
  end
`endif


`ifndef SYNTHESIS
`ifndef FORMAL
  // Simulation-only assertions: $isunknown would put unsupported z literals
  // into the BTOR model. The formal properties live in the parent ROB.
  always_ff @(posedge i_clk) begin
    if (i_rst_n && !i_flush_all && !$isunknown(
            {
              sfence_window_q,
              serial_state,
              head_is_sfence,
              translation_csr_owner_q,
              translation_csr_commit_event,
              translation_csr_commit_event_q,
              o_native_fence_commit_event
            }
        )) begin
      p_sfence_window_phase_exact :
      assert (sfence_window_q ==
              ((serial_state == riscv_pkg::SERIAL_FENCE_I_SYNC) && head_is_sfence));
      p_plain_fence_i_never_opens_sfence_window : assert (!sfence_window_q || head_is_sfence);
      p_native_event_owned_by_sync_state :
      assert (!o_native_fence_commit_event ||
              ((serial_state == riscv_pkg::SERIAL_FENCE_I_SYNC) && i_fence_i_sync_done &&
               retire_permit));
      p_translation_event_owned_by_drain_state :
      assert (!translation_csr_commit_event ||
              ((serial_state == riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN) &&
               translation_csr_owner_q && i_sq_committed_empty && retire_permit));
    end
  end
`endif
`endif

endmodule
