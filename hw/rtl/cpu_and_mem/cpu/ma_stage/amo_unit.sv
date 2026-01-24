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
 * Atomic Memory Operation (AMO) Unit - RISC-V A-extension support
 *
 * Implements read-modify-write operations for atomic memory instructions.
 * Handles all AMO operations except LR/SC (which are handled separately).
 *
 * Supported Instructions:
 * =======================
 *   AMOSWAP.W  - Atomic swap:     mem[addr] ← rs2;           rd ← old_value
 *   AMOADD.W   - Atomic add:      mem[addr] ← old + rs2;     rd ← old_value
 *   AMOXOR.W   - Atomic XOR:      mem[addr] ← old ^ rs2;     rd ← old_value
 *   AMOAND.W   - Atomic AND:      mem[addr] ← old & rs2;     rd ← old_value
 *   AMOOR.W    - Atomic OR:       mem[addr] ← old | rs2;     rd ← old_value
 *   AMOMIN.W   - Atomic MIN:      mem[addr] ← min(old, rs2); rd ← old_value (signed)
 *   AMOMAX.W   - Atomic MAX:      mem[addr] ← max(old, rs2); rd ← old_value (signed)
 *   AMOMINU.W  - Atomic MIN (U):  mem[addr] ← min(old, rs2); rd ← old_value (unsigned)
 *   AMOMAXU.W  - Atomic MAX (U):  mem[addr] ← max(old, rs2); rd ← old_value (unsigned)
 *
 * State Machine:
 * ==============
 *                    +------------------------------------------+
 *                    |              AMO_IDLE                    |
 *                    |      (Waiting for AMO instruction)       |
 *                    +-----------------+------------------------+
 *                                      | is_amo && !stall && !processed
 *                                      | Capture: rs2, address, operation
 *                                      v
 *                    +------------------------------------------+
 *                    |              AMO_READ                    |
 *                    |  (Wait 1 cycle for BRAM read latency)    |
 *                    |  Memory data arrives at end of cycle     |
 *                    +-----------------+------------------------+
 *                                      | 1 cycle (BRAM latency)
 *                                      | Capture: old_value from memory
 *                                      v
 *                    +------------------------------------------+
 *                    |              AMO_WRITE                   |
 *                    |  Compute: new_value = f(old_value, rs2)  |
 *                    |  Write new_value to memory               |
 *                    |  Return old_value to rd (via forwarding) |
 *                    +-----------------+------------------------+
 *                                      | 1 cycle
 *                                      v
 *                                (back to IDLE)
 *
 * Timing:
 * =======
 *   Cycle 0: AMO detected in MA, transition to READ, capture rs2/addr/op
 *   Cycle 1: Wait for BRAM (READ state), capture old_value at end
 *   Cycle 2: Compute result, write to memory (WRITE state)
 *   Cycle 3: Return to IDLE, old_value written to rd
 *
 *   Total penalty: 2 cycles stall (READ + WRITE states)
 *
 * Atomicity Guarantee:
 * ====================
 *   For single-core designs without DMA, atomicity is naturally guaranteed
 *   since only the CPU can access memory. The pipeline stall ensures the
 *   read-modify-write sequence completes without interruption.
 *
 * Related Modules:
 *   - ma_stage.sv: Instantiates this unit, muxes AMO write path
 *   - store_unit.sv: Handles SC.W success/fail determination
 *   - hazard_resolution_unit.sv: Uses stall_for_amo signal
 *   - forwarding_unit.sv: Forwards AMO result to dependent instructions
 */
module amo_unit #(
    parameter int unsigned XLEN = 32
) (
    input logic i_clk,
    input logic i_rst,
    input logic i_stall,

    // Early detection when AMO is in EX stage (for rs2 capture)
    input logic i_amo_in_ex,
    // RS2 value - combinational forwarded value from forwarding unit
    input logic [XLEN-1:0] i_rs2_fwd,

    // From EX→MA pipeline register
    input logic i_is_amo_instruction,
    input logic i_is_lr,
    input logic i_is_sc,
    input riscv_pkg::instr_op_e i_instruction_operation,
    input logic [XLEN-1:0] i_data_memory_address,

    // Memory read data (arrives 1 cycle after address)
    input logic [XLEN-1:0] i_data_memory_read_data,

    // Outputs
    output logic            o_stall_for_amo,     // Stall pipeline during AMO
    output logic            o_amo_write_enable,  // Enable memory write for AMO
    output logic [XLEN-1:0] o_amo_write_data,    // Data to write to memory
    output logic [XLEN-1:0] o_amo_write_addr,    // Captured address for memory write
    output logic [XLEN-1:0] o_amo_result,        // Old value to write to rd
    output logic            o_amo_read_phase     // True during READ phase (for forwarding)
);

  // AMO state machine states
  typedef enum logic [1:0] {
    AMO_IDLE,  // Waiting for AMO instruction
    AMO_READ,  // AMO instruction detected, waiting for read data
    AMO_WRITE  // Read data available, writing new value
  } amo_state_e;

  amo_state_e amo_state, amo_state_next;

  // Registered values captured when AMO starts
  logic [XLEN-1:0] captured_rs2_value;
  logic [XLEN-1:0] captured_old_value;
  logic [XLEN-1:0] captured_address;
  riscv_pkg::instr_op_e captured_operation;

  // Early-captured rs2: captured when AMO is in EX stage (before entering MA).
  // This ensures we capture the correctly forwarded value before the pipeline
  // register updates, avoiding timing issues at the EX→MA boundary.
  logic [XLEN-1:0] rs2_early_captured;

  // Track whether current AMO instruction has been processed to prevent re-execution
  // This is needed because from_ex_to_ma holds its value during stalls, and without
  // this flag the AMO would re-trigger when returning to IDLE state.
  logic amo_instruction_processed;

  // Detect "regular" AMO operation (not LR or SC - those are handled differently)
  logic is_regular_amo;
  assign is_regular_amo = i_is_amo_instruction && !i_is_lr && !i_is_sc;

  // State machine transitions
  always_comb begin
    amo_state_next = amo_state;
    unique case (amo_state)
      AMO_IDLE: begin
        // Start AMO sequence when regular AMO instruction is in MA stage
        // Check !amo_instruction_processed to prevent re-triggering on same instruction
        if (is_regular_amo && !i_stall && !amo_instruction_processed) begin
          amo_state_next = AMO_READ;
        end
      end
      AMO_READ: begin
        // After 1 cycle, read data is available - transition to write phase
        amo_state_next = AMO_WRITE;
      end
      AMO_WRITE: begin
        // Transition to IDLE unconditionally
        // Don't wait for external stalls - they are frozen during AMO stall anyway
        // Waiting would cause a deadlock (mul/div counter frozen, can't complete)
        amo_state_next = AMO_IDLE;
      end
      default: amo_state_next = AMO_IDLE;
    endcase
  end

  // State register
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      amo_state <= AMO_IDLE;
    end else begin
      amo_state <= amo_state_next;
    end
  end

  // Track whether current AMO instruction has been processed
  // Set when we start processing (IDLE -> READ), cleared when pipeline advances
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      amo_instruction_processed <= 1'b0;
    end else if (amo_state == AMO_IDLE && amo_state_next == AMO_READ) begin
      // Starting to process this AMO instruction
      amo_instruction_processed <= 1'b1;
    end else if (!o_stall_for_amo && !i_stall) begin
      // Pipeline is advancing (no stalls), clear the flag
      // At the next posedge, from_ex_to_ma will have a new instruction
      amo_instruction_processed <= 1'b0;
    end
  end

  // Early-capture rs2 when AMO is in EX stage (before it enters MA).
  // This captures the combinational forwarded value at the correct time,
  // before the pipeline register updates at the EX→MA boundary.
  // The key is that we capture when stall is LOW and AMO is in EX - this is
  // exactly the cycle when the AMO will move to MA at the next posedge.
  always_ff @(posedge i_clk) begin
    if (i_rst) begin
      rs2_early_captured <= '0;
    end else if (i_amo_in_ex && !i_stall) begin
      // Capture forwarded rs2 when AMO is in EX and about to enter MA
      rs2_early_captured <= i_rs2_fwd;
    end
  end

  // Capture values when AMO starts processing in MA stage.
  always_ff @(posedge i_clk) begin
    if (amo_state == AMO_IDLE && is_regular_amo && !i_stall && !amo_instruction_processed) begin
      // Use the early-captured rs2 value - this was captured when AMO was in EX,
      // so it has the correctly forwarded value before the pipeline register update.
      captured_rs2_value <= rs2_early_captured;
      captured_address   <= i_data_memory_address;
      captured_operation <= i_instruction_operation;
    end
    // Capture old value when read data arrives
    if (amo_state == AMO_READ) begin
      captured_old_value <= i_data_memory_read_data;
    end
  end

  // AMO computation logic
  logic [XLEN-1:0] amo_computed_value;
  logic signed [XLEN-1:0] signed_old_value, signed_rs2;

  assign signed_old_value = $signed(captured_old_value);
  assign signed_rs2 = $signed(captured_rs2_value);

  always_comb begin
    amo_computed_value = captured_old_value;  // Default: keep old value

    unique case (captured_operation)
      riscv_pkg::AMOSWAP_W: amo_computed_value = captured_rs2_value;
      riscv_pkg::AMOADD_W: amo_computed_value = captured_old_value + captured_rs2_value;
      riscv_pkg::AMOXOR_W: amo_computed_value = captured_old_value ^ captured_rs2_value;
      riscv_pkg::AMOAND_W: amo_computed_value = captured_old_value & captured_rs2_value;
      riscv_pkg::AMOOR_W: amo_computed_value = captured_old_value | captured_rs2_value;
      riscv_pkg::AMOMIN_W:
      amo_computed_value = (signed_old_value < signed_rs2) ?
                                                  captured_old_value : captured_rs2_value;
      riscv_pkg::AMOMAX_W:
      amo_computed_value = (signed_old_value > signed_rs2) ?
                                                  captured_old_value : captured_rs2_value;
      riscv_pkg::AMOMINU_W:
      amo_computed_value = (captured_old_value < captured_rs2_value) ?
                                                  captured_old_value : captured_rs2_value;
      riscv_pkg::AMOMAXU_W:
      amo_computed_value = (captured_old_value > captured_rs2_value) ?
                                                  captured_old_value : captured_rs2_value;
      default: ;
    endcase
  end

  // Output signals
  // Stall pipeline during AMO_READ and AMO_WRITE states, and when starting.
  // WRITE stall is required because the memory interface has only one address:
  // during WRITE we use captured_address for the write, but if pipeline advances
  // the next instruction would try to read from the same address, causing the
  // next AMO to capture the wrong old value. Stalling during WRITE ensures the
  // write completes before any new read begins.
  assign o_stall_for_amo = (amo_state == AMO_READ) ||
                           (amo_state == AMO_WRITE) ||
                           (amo_state == AMO_IDLE && is_regular_amo && !i_stall &&
                            !amo_instruction_processed);

  // Enable memory write during AMO_WRITE state
  // Don't wait for external stalls - they are frozen and would cause deadlock
  assign o_amo_write_enable = (amo_state == AMO_WRITE);

  // Write data is the computed new value
  assign o_amo_write_data = amo_computed_value;

  // Write address is captured when AMO starts (stable during WRITE phase)
  assign o_amo_write_addr = captured_address;

  // Result (old value) is returned to rd
  assign o_amo_result = captured_old_value;

  // Signal that we're in READ phase - memory data is available for forwarding
  // At the posedge when this is true, i_data_memory_read_data has the old value
  assign o_amo_read_phase = (amo_state == AMO_READ);

endmodule : amo_unit
