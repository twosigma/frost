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
// Extracted verbatim from reorder_buffer.sv (pure RTL boundary move, zero
// functional change).  The serializing-instruction state machine: pins WFI /
// CSR / FENCE / FENCE.I / MRET / exceptions at the ROB head and produces the
// commit_stall.  serial_state is exported (consumed by the ROB's perf counters,
// o_csr_start / o_mret_start, and assertions); serial_state_next is internal.
// serial_state_e lives in riscv_pkg so the ROB and this module share the type.
// =============================================================================
module rob_serializer
  import riscv_pkg::*;
(
    input logic i_clk,
    input logic i_rst_n,
    input logic i_flush_all,
    input logic i_flush_en,
    input logic i_commit_hold,
    input logic i_early_recovery_en,
    input logic i_interrupt_pending,
    input logic i_sq_committed_empty,
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

    output serial_state_e o_serial_state,
    output logic o_commit_stall
);

  serial_state_e serial_state, serial_state_next;
  logic commit_stall;

  always_ff @(posedge i_clk) begin
    if (!i_rst_n) begin
      serial_state <= SERIAL_IDLE;
    end else if (i_flush_all) begin
      serial_state <= SERIAL_IDLE;
    end else begin
      serial_state <= serial_state_next;
    end
  end

  always_comb begin
    serial_state_next = serial_state;
    commit_stall = 1'b0;

    case (serial_state)
      SERIAL_IDLE: begin
        if (head_ready && !i_commit_hold && !i_early_recovery_en &&
                          !i_flush_en    && !i_flush_all) begin
          // Check for serializing instructions at head
          if (head_exception) begin
            // Exception: wait for trap unit
            serial_state_next = SERIAL_TRAP_WAIT;
            commit_stall = 1'b1;
          end else if (head_is_wfi) begin
            // WFI: wait for interrupt
            if (i_interrupt_pending) begin
              // Interrupt pending, WFI can commit immediately
              serial_state_next = SERIAL_IDLE;
              commit_stall = 1'b0;
            end else begin
              serial_state_next = SERIAL_WFI_WAIT;
              commit_stall = 1'b1;
            end
          end else if (head_is_csr) begin
            // CSR: need to execute at commit
            serial_state_next = SERIAL_CSR_EXEC;
            commit_stall = 1'b1;
          end else if (head_is_fence || head_is_fence_i) begin
            // FENCE/FENCE.I: wait for committed SQ entries to drain
            if (i_sq_committed_empty) begin
              // No committed entries pending write, can commit
              serial_state_next = SERIAL_IDLE;
              commit_stall = 1'b0;
            end else begin
              serial_state_next = SERIAL_WAIT_SQ;
              commit_stall = 1'b1;
            end
          end else if (head_is_mret) begin
            // MRET: signal trap unit
            serial_state_next = SERIAL_MRET_EXEC;
            commit_stall = 1'b1;
          end else if (head_is_amo || head_is_lr) begin
            // AMO/LR: ordering enforced at LQ issue time (waits for ROB head +
            // SQ committed-empty). Once CDB arrives (head_done=1), commit normally.
            // No SQ check here (would deadlock with younger uncommitted SQ entries).
          end
          // Non-serializing instructions: no stall
        end
      end

      SERIAL_WAIT_SQ: begin
        commit_stall = 1'b1;
        if (i_sq_committed_empty) begin
          // Committed SQ entries drained, can commit
          serial_state_next = SERIAL_IDLE;
          commit_stall = 1'b0;
        end
      end

      SERIAL_CSR_EXEC: begin
        commit_stall = 1'b1;
        if (i_csr_done) begin
          // CSR complete, can commit
          serial_state_next = SERIAL_IDLE;
          commit_stall = 1'b0;
        end
      end

      SERIAL_MRET_EXEC: begin
        commit_stall = 1'b1;
        if (i_mret_done) begin
          // MRET complete, can commit
          serial_state_next = SERIAL_IDLE;
          commit_stall = 1'b0;
        end
      end

      SERIAL_WFI_WAIT: begin
        commit_stall = 1'b1;
        if (i_interrupt_pending) begin
          // Interrupt arrived, WFI can commit
          serial_state_next = SERIAL_IDLE;
          commit_stall = 1'b0;
        end
      end

      SERIAL_TRAP_WAIT: begin
        commit_stall = 1'b1;
        if (i_trap_taken) begin
          // Trap unit has taken the exception, flush will follow
          serial_state_next = SERIAL_IDLE;
          // Note: i_flush_all will reset state machine
        end
      end

      default: begin
        serial_state_next = SERIAL_IDLE;
      end
    endcase
  end

  assign o_serial_state = serial_state;
  assign o_commit_stall = commit_stall;

endmodule
