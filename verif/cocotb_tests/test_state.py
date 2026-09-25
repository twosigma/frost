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

"""CPU reference state for the directed cpu_tb tests.

Register files, the program counter, counter shadows, the LR/SC reservation,
and the expected-write queues that MemoryModel's store monitor consumes.
"previous" and "current" describe instruction history, not pipeline
residency. RV64 counters are 64-bit and have no high-half CSRs.
"""

from config import MASK_XLEN

# The LR/SC reservation covers the aligned doubleword that holds the LR's
# address: sc_pending_unit compares addr[XLEN-1:3].
_RESERVATION_ADDRESS_MASK = MASK_XLEN & ~0x7


class TestState:
    """Software CPU state and expected-value queues.

    Attributes:
        register_file_current: Register values after the current instruction writes
        register_file_previous: Register values the current instruction reads
        program_counter_current: PC of the current instruction
        csr_cycle_counter: Clock cycle counter for CSR verification
        csr_instret_counter: Instruction retired counter for CSR verification
        reservation_valid: Whether an LR/SC reservation is active
        reservation_address: Doubleword-aligned address of current reservation
        last_sc_succeeded: Whether the last SC.W instruction succeeded
        last_sc_address: Address of the last SC.W instruction
        last_sc_data: Data value of the last SC.W instruction
        register_file_current_expected_queue: Expected integer register files
        program_counter_expected_values_queue: Expected PCs
        memory_write_data_expected_queue: Expected store data, for MemoryModel
        memory_write_address_expected_queue: Expected store addresses, for MemoryModel
    """

    def __init__(self) -> None:
        """Initialize test state with default values for CPU verification."""
        # 'previous' holds the values the current instruction reads, with every
        # older result visible; 'current' holds the values after it writes.
        self.register_file_current: list[int] = [0] * 32
        self.register_file_previous: list[int] = [0] * 32

        self.program_counter_current: int = 8

        # Shadow RTL counters to verify CSR read values
        self.csr_cycle_counter: int = 0  # Increments every clock edge
        self.csr_instret_counter: int = 0  # Increments when instruction retires

        self.reservation_valid: bool = False
        self.reservation_address: int = 0
        self.last_sc_succeeded: bool = False
        self.last_sc_address: int = 0
        self.last_sc_data: int = 0

        self.register_file_current_expected_queue: list[list[int]] = []
        self.program_counter_expected_values_queue: list[int] = []
        self.memory_write_data_expected_queue: list[int] = []
        self.memory_write_address_expected_queue: list[int] = []

    def update_program_counter(self, expected_program_counter: int) -> None:
        """Set the program counter of the next instruction."""
        self.program_counter_current = expected_program_counter

    def advance_register_state(self) -> None:
        """Make the current register values the ones the next instruction reads."""
        self.register_file_previous = self.register_file_current.copy()

    def increment_cycle_counter(self) -> None:
        """Increment CSR cycle counter (called every clock edge)."""
        self.csr_cycle_counter += 1

    def increment_instret_counter(self) -> None:
        """Increment CSR instret counter (called when instruction retires)."""
        self.csr_instret_counter += 1

    def set_reservation(self, address: int) -> None:
        """Reserve the aligned doubleword that holds ``address``.

        Callers set it when they model an LR.W; a later SC.W checks it.

        Args:
            address: LR.W address (lower 3 bits ignored)
        """
        self.reservation_valid = True
        self.reservation_address = address & _RESERVATION_ADDRESS_MASK

    def clear_reservation(self) -> None:
        """Clear any active LR/SC reservation.

        Callers clear it on every SC.W, whether or not it succeeds. Other events
        that end a reservation, such as a store to the reserved address, are
        not modeled.
        """
        self.reservation_valid = False

    def check_reservation(self, address: int) -> bool:
        """Check if SC.W to the given address should succeed.

        An SC.W to either word of the reserved doubleword succeeds.

        Args:
            address: SC.W address

        Returns:
            True if reservation is valid and address matches (SC succeeds),
            False otherwise (SC fails)
        """
        if not self.reservation_valid:
            return False
        return (address & _RESERVATION_ADDRESS_MASK) == self.reservation_address
