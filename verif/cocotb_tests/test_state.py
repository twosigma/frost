#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

"""Test state management for CPU verification.

Test State
==========

This module defines the TestState class which tracks CPU state across pipeline
stages during verification. It's separated from test_cpu.py to avoid circular
dependencies, as multiple modules need to reference this state.

Pipeline Timing Model:
    The CPU has a multi-stage pipeline, so we track state at different
    pipeline stages to correctly model when results become visible:

    - register_file_previous: Values at instruction decode (cycle N-1)
    - register_file_current: Values after writeback (cycle N)
    - program_counter_two_cycles_ago: PC of instr in writeback stage
    - program_counter_previous: PC of instr in execute stage
    - program_counter_current: PC of instr in fetch stage

CSR Counter Tracking (Zicsr + Zicntr):
    The CPU implements Zicntr performance counters:
    - cycle/cycleh: Clock cycles since reset
    - instret/instreth: Instructions retired since reset
    - time/timeh: Aliased to cycle (no separate RTC)

    These are tracked in software to verify CSR read values:
    - csr_cycle_counter: Incremented every clock edge
    - csr_instret_counter: Incremented when instruction retires (o_vld)

Queue Management:
    Expected value queues hold predicted results that will be checked
    when they emerge from the pipeline. Monitors pop from these queues
    when hardware signals indicate valid output.
"""

from config import (
    MASK32,
    MASK64,
    PIPELINE_IF_TO_EX_CYCLES,
    PIPELINE_IF_TO_MA_CYCLES,
)


class TestState:
    """Encapsulates the test state and queues.

    This class maintains the complete software model of CPU state, tracking
    values across pipeline stages to account for execution delays.

    Attributes:
        register_file_current: Register values after current writeback
        register_file_previous: Register values visible to current instruction
        fp_register_file_current: FP register values after current writeback
        fp_register_file_previous: FP register values visible to current instruction
        program_counter_current: PC at fetch stage
        program_counter_previous: PC at decode stage
        program_counter_two_cycles_ago: PC at writeback stage
        branch_taken_current: Whether current instruction is a taken branch/jump
        branch_taken_previous: Whether previous instruction was a taken branch/jump
        branch_taken_two_cycles_ago: Whether instruction two cycles ago was taken
        branch_was_jal_current: Whether current branch was caused by JAL
        branch_was_jal_previous: Whether previous branch was caused by JAL
        csr_cycle_counter: Clock cycle counter for CSR verification
        csr_instret_counter: Instruction retired counter for CSR verification
        reservation_valid: Whether an LR/SC reservation is active
        reservation_address: Word-aligned address of current reservation
        pending_lr_address: Address of pending LR.W (not yet at MA stage)
        pending_lr_countdown: Cycles until pending LR.W reaches MA stage
        last_sc_succeeded: Whether the last SC.W instruction succeeded
        last_sc_address: Address of the last SC.W instruction
        last_sc_data: Data value of the last SC.W instruction
        register_file_current_expected_queue: Queue for integer register verification
        fp_register_file_current_expected_queue: Queue for FP register verification
        program_counter_expected_values_queue: Queue for PC verification
        memory_write_data_expected_queue: Queue for memory write data verification
        memory_write_address_expected_queue: Queue for memory write address verification
    """

    def __init__(self) -> None:
        """Initialize test state with default values for CPU verification."""
        # ====================================================================
        # Integer Register File State
        # ====================================================================
        # With full forwarding, instruction N sees results from all previous
        # instructions via forwarding paths (EX→ID, MA→ID, WB→ID).
        # 'previous' = values visible to current instruction (for operand reads)
        # 'current' = values after writeback of current instruction
        self.register_file_current: list[int] = [0] * 32
        self.register_file_previous: list[int] = [0] * 32

        # ====================================================================
        # FP Register File State (F extension)
        # ====================================================================
        # Same pipeline timing as integer register file.
        # FP registers f0-f31 are separate from integer registers x0-x31.
        # Note: Unlike x0 which is hardwired to 0, f0 is a normal register.
        self.fp_register_file_current: list[int] = [0] * 32
        self.fp_register_file_previous: list[int] = [0] * 32

        # ====================================================================
        # Program Counter State
        # ====================================================================
        # Track PC at different pipeline stages for output verification
        self.program_counter_current: int = 8  # Fetch stage
        self.program_counter_previous: int = 4  # Decode stage
        self.program_counter_two_cycles_ago: int = 0  # Writeback stage

        # ====================================================================
        # Branch/Jump State
        # ====================================================================
        # 6-stage pipeline needs 3 flush cycles when branch is taken
        self.branch_taken_current: bool = False
        self.branch_taken_previous: bool = False
        self.branch_taken_two_cycles_ago: bool = False
        self.branch_was_jal_current: bool = False
        self.branch_was_jal_previous: bool = False

        # ====================================================================
        # CSR Counter State
        # ====================================================================
        # Shadow RTL counters to verify CSR read values
        self.csr_cycle_counter: int = 0  # Increments every clock edge
        self.csr_instret_counter: int = 0  # Increments when instruction retires

        # ====================================================================
        # LR/SC Reservation State
        # ====================================================================
        self.reservation_valid: bool = False
        self.reservation_address: int = 0
        self.pending_lr_address: int | None = None
        self.pending_lr_countdown: int = 0
        self.last_sc_succeeded: bool = False
        self.last_sc_address: int = 0
        self.last_sc_data: int = 0

        # ====================================================================
        # Expected Output Queues
        # ====================================================================
        self.register_file_current_expected_queue: list[list[int]] = []
        self.fp_register_file_current_expected_queue: list[list[int]] = []
        self.program_counter_expected_values_queue: list[int] = []
        self.memory_write_data_expected_queue: list[int] = []
        self.memory_write_address_expected_queue: list[int] = []

    # ========================================================================
    # Convenience Properties
    # ========================================================================

    @property
    def is_in_flush(self) -> bool:
        """Check if pipeline is currently flushing due to a taken branch/jump."""
        return (
            self.branch_taken_current
            or self.branch_taken_previous
            or self.branch_taken_two_cycles_ago
        )

    # ========================================================================
    # State Update Methods
    # ========================================================================

    def update_program_counter(self, expected_program_counter: int) -> None:
        """Update program counter state across pipeline stages."""
        self.program_counter_two_cycles_ago = self.program_counter_previous
        self.program_counter_previous = self.program_counter_current
        self.program_counter_current = expected_program_counter

    def update_register(self, register_index: int, value: int) -> None:
        """Update a register in the current integer register file state.

        Args:
            register_index: Register to update (1-31, x0 is ignored)
            value: Value to write (will be masked to 32 bits)
        """
        if register_index and register_index < 32:
            self.register_file_current[register_index] = value & MASK32

    def update_fp_register(self, register_index: int, value: int) -> None:
        """Update a register in the current FP register file state.

        Args:
            register_index: FP register to update (0-31, f0 is writeable unlike x0)
            value: Value to write (will be masked to 64 bits)
        """
        if register_index < 32:
            self.fp_register_file_current[register_index] = value & MASK64

    def advance_register_state(self) -> None:
        """Advance both integer and FP register state: current becomes previous."""
        self.register_file_previous = self.register_file_current.copy()
        self.fp_register_file_previous = self.fp_register_file_current.copy()

    def queue_expected_outputs(self, expected_pc: int) -> None:
        """Queue expected register files (int and FP) and PC for monitor verification.

        Args:
            expected_pc: Expected program counter value
        """
        self.register_file_current_expected_queue.append(
            self.register_file_current.copy()
        )
        self.fp_register_file_current_expected_queue.append(
            self.fp_register_file_current.copy()
        )
        self.program_counter_expected_values_queue.append(expected_pc)

    def has_pending_expectations(self) -> bool:
        """Check if there are still expected values waiting to be verified."""
        return (
            len(self.register_file_current_expected_queue) > 0
            or len(self.fp_register_file_current_expected_queue) > 0
            or len(self.program_counter_expected_values_queue) > 0
            or len(self.memory_write_data_expected_queue) > 0
            or len(self.memory_write_address_expected_queue) > 0
        )

    # ========================================================================
    # CSR Counter Methods
    # ========================================================================

    def increment_cycle_counter(self) -> None:
        """Increment CSR cycle counter (called every clock edge)."""
        self.csr_cycle_counter += 1

    def increment_instret_counter(self) -> None:
        """Increment CSR instret counter (called when instruction retires)."""
        self.csr_instret_counter += 1

    # ========================================================================
    # LR/SC Reservation Methods
    # ========================================================================

    def set_reservation(self, address: int) -> None:
        """Set LR/SC reservation for the given word-aligned address.

        Called when LR.W instruction completes in MA stage.
        The reservation is used by subsequent SC.W to determine success/failure.

        Args:
            address: Word-aligned memory address (lower 2 bits ignored)
        """
        self.reservation_valid = True
        self.reservation_address = address & ~0x3  # Word-align

    def clear_reservation(self) -> None:
        """Clear any active LR/SC reservation.

        Called when:
        - SC.W executes (regardless of success/failure)
        - Store to reserved address occurs
        - Context switch (not modeled in random tests)
        """
        self.reservation_valid = False

    def check_reservation(self, address: int) -> bool:
        """Check if SC.W to the given address should succeed.

        Args:
            address: Word-aligned memory address for SC.W

        Returns:
            True if reservation is valid and address matches (SC succeeds),
            False otherwise (SC fails)
        """
        if not self.reservation_valid:
            return False
        return (address & ~0x3) == self.reservation_address

    def schedule_reservation(self, address: int) -> None:
        """Schedule a reservation to be set after pipeline delay.

        LR.W is generated at IF stage but reservation is set at MA stage
        (3 cycles later). This tracks the pending reservation.

        Args:
            address: Word-aligned address for reservation
        """
        self.pending_lr_address = address & ~0x3
        self.pending_lr_countdown = (
            PIPELINE_IF_TO_MA_CYCLES  # LR.W sets reservation at MA stage
        )

    def advance_pending_reservation(self) -> None:
        """Advance pending reservation countdown, setting reservation when ready.

        Called once per cycle to model pipeline timing of reservation setting.
        """
        if self.pending_lr_countdown > 0:
            self.pending_lr_countdown -= 1
            if self.pending_lr_countdown == 0 and self.pending_lr_address is not None:
                self.set_reservation(self.pending_lr_address)
                self.pending_lr_address = None

    # ========================================================================
    # CSR Read Methods
    # ========================================================================

    def get_csr_value(
        self, csr_address: int, pipeline_offset: int = PIPELINE_IF_TO_EX_CYCLES
    ) -> int:
        """Get expected CSR value for a CSR read instruction.

        CSR reads happen in EX stage, which is PIPELINE_IF_TO_EX_CYCLES after IF.
        The counter value at EX time is what gets captured.

        Pipeline timing for counters (6-stage: IF-PD-ID-EX-MA-WB):

        - cycle: Increments every clock edge. When CSR is in EX, the counter
          has incremented pipeline_offset more times since generation.
        - instret: Increments only when instruction retires in WB stage.
          The instret value read is the count before this CSR's generation.

        Args:
            csr_address: CSR address being read (e.g., 0xC00 for cycle)
            pipeline_offset: Cycles from IF to EX stage (default PIPELINE_IF_TO_EX_CYCLES)

        Returns:
            Expected 32-bit CSR value
        """
        from encoders.instruction_encode import CSRAddress

        # Cycle counter: increments every clock, so add pipeline offset
        cycle_at_ex = self.csr_cycle_counter + pipeline_offset

        # Instret counter: only increments when instruction retires in WB stage.
        # The CSR read captures the value BEFORE the current posedge increment.
        instret_at_ex = max(0, self.csr_instret_counter - PIPELINE_IF_TO_EX_CYCLES)

        if csr_address in (CSRAddress.CYCLE, CSRAddress.TIME):
            return cycle_at_ex & MASK32
        elif csr_address in (CSRAddress.CYCLEH, CSRAddress.TIMEH):
            return (cycle_at_ex >> 32) & MASK32
        elif csr_address == CSRAddress.INSTRET:
            return instret_at_ex & MASK32
        elif csr_address == CSRAddress.INSTRETH:
            return (instret_at_ex >> 32) & MASK32
        else:
            # Unknown CSR - RTL returns 0 for unimplemented CSRs
            return 0

    # ========================================================================
    # Branch Flush Methods
    # ========================================================================

    def advance_branch_state(self) -> None:
        """Advance branch tracking state for pipeline flush handling.

        Shifts branch taken flags through the 3-cycle flush window.
        Called during branch flush to track when flush completes.
        """
        self.branch_taken_two_cycles_ago = self.branch_taken_previous
        self.branch_taken_previous = self.branch_taken_current
        self.branch_taken_current = False
        self.branch_was_jal_previous = self.branch_was_jal_current
        self.branch_was_jal_current = False
