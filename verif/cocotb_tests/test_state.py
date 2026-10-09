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

"""Reference state and expected-write queues for directed cpu_tb tests.

"previous" and "current" describe instruction history, not pipeline
residency. RV64 counters are 64-bit and have no high-half CSRs.
"""

from config import MASK_XLEN

# The LR/SC reservation covers the aligned doubleword that holds the LR's
# address: sc_pending_unit compares addr[XLEN-1:3].
_RESERVATION_ADDRESS_MASK = MASK_XLEN & ~0x7


class TestState:
    """CPU reference state and queues of expected architectural effects.

    register_file_previous supplies the current instruction's operands;
    register_file_current includes its result. MemoryModel consumes the
    expected store-address and store-data queues. reservation_address is
    doubleword-aligned; last_sc_* records the last modeled SC.W.
    """

    def __init__(self) -> None:
        """Initialize test state with default values for CPU verification."""
        self.register_file_current: list[int] = [0] * 32
        self.register_file_previous: list[int] = [0] * 32

        self.program_counter_current: int = 8

        # Stimulus-side counter shadows for CSR checks
        self.csr_cycle_counter: int = 0  # Advanced by stimulus helpers
        self.csr_instret_counter: int = 0  # Counts modeled instructions

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
        """Advance the stimulus-side cycle shadow."""
        self.csr_cycle_counter += 1

    def increment_instret_counter(self) -> None:
        """Count a modeled instruction when the stimulus helper issues it."""
        self.csr_instret_counter += 1

    def set_reservation(self, address: int) -> None:
        """Reserve the modeled LR.W address with bits 2:0 ignored."""
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
        """Return whether an SC.W address lies in the active reserved doubleword."""
        if not self.reservation_valid:
            return False
        return (address & _RESERVATION_ADDRESS_MASK) == self.reservation_address
