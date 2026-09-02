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
// Serializing-instruction FSM. Pins WFI, CSR, FENCE/FENCE.I, MRET, and
// exceptions at the ROB head and produces commit_stall. serial_state is
// exported for ROB performance counters, CSR/MRET start outputs, and
// assertions; serial_state_next is internal. serial_state_e lives in riscv_pkg.
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
    // Semantic retirement events. The native event is the actual FENCE.I /
    // SFENCE.VMA retirement condition, derived from registered serializer
    // ownership rather than a live ROB-head reread. Translation CSRs receive
    // one additional register: its semantic event is high while the
    // registered commit bus writes csr_file, and the final registered flush
    // follows one cycle later.
    output logic o_native_fence_commit_event,
    output logic o_translation_csr_commit_event_q,
    output logic o_commit_stall
);

  riscv_pkg::serial_state_e serial_state, serial_state_next;
  logic commit_stall;
  logic retire_permit;
  logic translation_csr_owner_q;
  logic translation_csr_commit_event;
  logic translation_csr_commit_event_q;

  // These are the head-independent conjuncts of reorder_buffer.commit_en.
  // Entry into either owned state proves that the pinned head is valid, done,
  // non-exceptional, and of the matching class; retaining only these guards
  // keeps the live head one-hot read out of both semantic event cones.
  // A flush-after-head request is already a subtype of i_flush_en/i_flush_all
  // at this boundary, so it does not need a separate input on the event cone.
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

  // Capture from NEXT state so this level rises on the same edge that enters
  // SERIAL_FENCE_I_SYNC and falls on the same edge that leaves it.  The head
  // is pinned for the whole sync, making this phase-identical to
  // o_fence_i_sync_req && head_is_sfence while removing the live ROB-head
  // onehot read from the TLB/PTW invalidation cone.
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
        // TIMING (late-side re-association): the IDLE commit_stall is exported
        // WITHOUT the head_ready/!i_commit_hold/!i_early_recovery_en/
        // !i_flush_en/!i_flush_all gate.  Every reorder_buffer consumer ANDs
        // commit_stall with commit_ready_early (or an equivalent superset of
        // the gate conjuncts), so <early> && !commit_stall is bit-identical
        // with or without the gate — but head_ready carries the same-cycle
        // CDB head-done bypass, and keeping it out of the stall cone removes
        // one fused stage from the CDB -> commit -> SQ/trap late arc.  The
        // perf-counter consumer in reorder_buffer re-applies the dropped
        // conjuncts explicitly.  The FSM transitions below keep the full
        // gate, exactly as before.
        if (head_exception) begin
          // Exception: wait for trap unit
          commit_stall = 1'b1;
        end else if (head_is_wfi) begin
          // WFI: stalls until an interrupt is pending
          commit_stall = !i_interrupt_pending;
        end else if (head_is_csr) begin
          // CSR: need to execute at commit
          commit_stall = 1'b1;
        end else if (head_is_fence || head_is_fence_i) begin
          // FENCE/FENCE.I: wait for committed SQ entries to drain; FENCE.I
          // additionally stalls through the cache sync.
          commit_stall = !(i_sq_committed_empty && !head_is_fence_i);
        end else if (head_is_mret) begin
          // MRET: signal trap unit
          commit_stall = 1'b1;
        end
        // AMO/LR and non-serializing instructions: no stall

        if (head_ready && !i_commit_hold && !i_early_recovery_en &&
                          !i_flush_en    && !i_flush_all) begin
          // Check for serializing instructions at head
          if (head_exception) begin
            // Exception: wait for trap unit
            serial_state_next = riscv_pkg::SERIAL_TRAP_WAIT;
          end else if (head_is_wfi) begin
            // WFI: wait for interrupt (no state change when one is pending —
            // the WFI commits immediately)
            if (!i_interrupt_pending) begin
              serial_state_next = riscv_pkg::SERIAL_WFI_WAIT;
            end
          end else if (head_is_csr) begin
            // CSR: need to execute at commit
            serial_state_next = riscv_pkg::SERIAL_CSR_EXEC;
          end else if (head_is_fence || head_is_fence_i) begin
            // FENCE/FENCE.I: wait for committed SQ entries to drain.
            // FENCE.I additionally syncs the caches before committing (the
            // drained stores sit dirty in the write-back L1D; the L1I and
            // the fetch buffer must refill from post-writeback data).
            if (i_sq_committed_empty) begin
              if (head_is_fence_i) begin
                serial_state_next = riscv_pkg::SERIAL_FENCE_I_SYNC;
              end
              // Plain FENCE with drained SQ commits without serializing.
            end else begin
              serial_state_next = riscv_pkg::SERIAL_WAIT_SQ;
            end
          end else if (head_is_mret) begin
            // MRET: signal trap unit
            serial_state_next = riscv_pkg::SERIAL_MRET_EXEC;
          end else if (head_is_amo || head_is_lr) begin
            // AMO/LR: ordering enforced at LQ issue time (waits for ROB head +
            // SQ committed-empty). Once CDB arrives (head_done=1), commit normally.
            // No SQ check here (would deadlock with younger uncommitted SQ entries).
          end
          // Non-serializing instructions: no stall
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
            // Translation-class CSRs own a pre-commit drain state. Move
            // unconditionally so the one-cycle done pulse cannot be lost if
            // stores or a recovery guard still block retirement.
            serial_state_next = riscv_pkg::SERIAL_CSR_TRANSLATION_DRAIN;
          end else begin
            // Ordinary CSR complete, can commit on its historical cycle.
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
          // MRET complete, can commit
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
          // Trap unit has taken the exception, flush will follow
          serial_state_next = riscv_pkg::SERIAL_IDLE;
          // Note: i_flush_all will reset state machine
        end
      end

      default: begin
        serial_state_next = riscv_pkg::SERIAL_IDLE;
      end
    endcase
  end

  assign o_serial_state = serial_state;
  assign o_commit_stall = commit_stall;

`ifndef SYNTHESIS
`ifndef FORMAL
  // Simulation-only X guard.  Formal properties live in the parent ROB;
  // keeping $isunknown out of the BTOR model avoids unsupported z literals.
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
