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

"""Concurrent monitors that compare DUT outputs with expected values.

Each monitor is a coroutine running in the background. When the DUT asserts the
valid signal the monitor watches, it pops the head of its expected queue, reads
the actual value out of the DUT, and raises AssertionError if the two differ.

    - regfile_monitor: integer register file writes (x1-x31, excluding x0)
    - fp_regfile_monitor: FP register file writes (f0-f31, all writeable)
    - pc_monitor: program counter updates

Memory writes are checked by ``MemoryModel.driver_and_monitor()``, which
compares writes with the expected queues but drives nothing back to the CPU.
"""

from abc import ABC, abstractmethod
from cocotb.triggers import RisingEdge, ReadOnly
from typing import Any, Generic, TypeVar
from config import (
    MASK32,
    MASK64,
    DUTSignalPaths,
    FIRST_WRITABLE_REGISTER,
    NUM_REGISTERS,
)
from cocotb_tests.test_helpers import read_port_ram_entry

T = TypeVar("T")


class Monitor(ABC, Generic[T]):
    """Common monitor run loop.

    1. Wait for a valid signal
    2. Read actual value from hardware
    3. Compare against expected value from queue
    4. Raise AssertionError on mismatch

    Subclasses implement the abstract methods.
    """

    def __init__(self, dut: Any, expected_queue: list[T], name: str = "Monitor"):
        """Initialize monitor with DUT and expected queue.

        Args:
            dut: Device under test (cocotb SimHandle)
            expected_queue: Queue of expected values to verify against
            name: Monitor name for error messages
        """
        self.dut = dut
        self.expected_queue = expected_queue
        self.name = name
        self.cycle = 0

    @abstractmethod
    def is_valid(self) -> bool:
        """Check if output is valid and should be verified this cycle."""
        ...

    @abstractmethod
    def read_actual(self) -> T:
        """Read actual value(s) from hardware."""
        ...

    @abstractmethod
    def compare(self, actual: T, expected: T) -> str | None:
        """Compare actual and expected values.

        Returns:
            None if values match, error message string if mismatch.
        """
        ...

    async def run(self) -> None:
        """Run the monitor loop until test ends."""
        while True:
            await RisingEdge(self.dut.i_clk)
            await ReadOnly()
            if self.is_valid():
                expected = self.expected_queue.pop(0)
                actual = self.read_actual()
                error = self.compare(actual, expected)
                if error:
                    raise AssertionError(
                        f"{self.name} at cycle {self.cycle}: {error} "
                        f"with {len(self.expected_queue)} expected values remaining"
                    )
                self.cycle += 1


class RegisterFileMonitor(Monitor[list[int]]):
    """Monitor for register file verification."""

    def __init__(
        self,
        dut: Any,
        expected_queue: list[list[int]],
        signal_paths: DUTSignalPaths | None = None,
    ) -> None:
        """Initialize register file monitor.

        Args:
            dut: Device under test
            expected_queue: Queue of expected register file states
            signal_paths: Optional custom signal paths
        """
        super().__init__(dut, expected_queue, "Register file mismatch")
        paths = signal_paths or DUTSignalPaths()

        # Navigate to the register file read-port RAM once
        obj = dut
        for attr in paths.regfile_ram_rs1_path.split("."):
            obj = getattr(obj, attr)
        self._ram = obj

    def is_valid(self) -> bool:
        """Check if register file output is valid."""
        return bool(self.dut.o_vld.value)

    def read_actual(self) -> list[int]:
        """Read all committed register values from hardware."""
        return [read_port_ram_entry(self._ram, i) for i in range(NUM_REGISTERS)]

    def compare(self, actual: list[int], expected: list[int]) -> str | None:
        """Compare actual and expected register file states."""
        for reg in range(FIRST_WRITABLE_REGISTER, NUM_REGISTERS):
            hw_val = actual[reg]
            sw_val = expected[reg] & MASK32
            if hw_val != sw_val:
                return f"Register x{reg}: DUT 0x{hw_val:08x} EXP 0x{sw_val:08x}"
        return None


class ProgramCounterMonitor(Monitor[int]):
    """Monitor for program counter verification."""

    def __init__(self, dut: Any, expected_queue: list[int]) -> None:
        """Initialize program counter monitor.

        Args:
            dut: Device under test
            expected_queue: Queue of expected PC values
        """
        super().__init__(dut, expected_queue, "Program counter mismatch")

    def is_valid(self) -> bool:
        """Check if PC output is valid."""
        return bool(self.dut.o_pc_vld.value)

    def read_actual(self) -> int:
        """Read PC value from hardware."""
        return int(self.dut.o_pc.value)

    def compare(self, actual: int, expected: int) -> str | None:
        """Compare actual and expected PC values."""
        if actual != expected:
            return f"DUT 0x{actual:08x} EXP 0x{expected:08x}"
        return None


class FPRegisterFileMonitor(Monitor[list[int]]):
    """Monitor for FP register file verification (F extension).

    The integer register file hardwires x0 to zero, but all 32 FP registers
    (f0-f31) are writeable, so the compare covers f0 as well.
    """

    def __init__(
        self,
        dut: Any,
        expected_queue: list[list[int]],
        signal_paths: DUTSignalPaths | None = None,
    ) -> None:
        """Initialize FP register file monitor.

        Args:
            dut: Device under test
            expected_queue: Queue of expected FP register file states
            signal_paths: Optional custom signal paths
        """
        super().__init__(dut, expected_queue, "FP Register file mismatch")
        paths = signal_paths or DUTSignalPaths()

        # Navigate to the FP register file read-port RAM once
        obj = dut
        for attr in paths.fp_regfile_ram_fs1_path.split("."):
            obj = getattr(obj, attr)
        self._ram = obj

    def is_valid(self) -> bool:
        """Check if FP register file output is valid."""
        return bool(self.dut.o_vld.value)

    def read_actual(self) -> list[int]:
        """Read all committed FP register values from hardware."""
        return [read_port_ram_entry(self._ram, i) for i in range(NUM_REGISTERS)]

    def compare(self, actual: list[int], expected: list[int]) -> str | None:
        """Compare actual and expected FP register file states."""
        for reg in range(NUM_REGISTERS):  # Start from f0, not f1
            hw_val = actual[reg]
            sw_val = expected[reg] & MASK64
            if hw_val != sw_val:
                return (
                    f"FP Register f{reg}: DUT 0x{hw_val:016x} " f"EXP 0x{sw_val:016x}"
                )
        return None


# Standalone functions for backward compatibility
async def regfile_monitor(
    dut: Any,
    expected_queue: list[list[int]],
    signal_paths: DUTSignalPaths | None = None,
) -> None:
    """Monitor and validate register file values written by the DUT.

    Compares the integer registers x1-x31 against the software model's
    expected values each time the DUT raises its output valid signal. Register
    x0 is hardwired to zero and is not checked.

    Args:
        dut: Device under test
        expected_queue: Queue of expected register file states
        signal_paths: Optional custom signal paths. If None, uses defaults.
    """
    monitor = RegisterFileMonitor(dut, expected_queue, signal_paths)
    await monitor.run()


async def pc_monitor(dut: Any, expected_queue: list[int]) -> None:
    """Monitor and validate program counter values from the DUT.

    Compares the CPU's PC output against the software model's expected values
    each time the DUT raises the PC valid signal. o_pc carries the address of
    the instruction being fetched.
    """
    monitor = ProgramCounterMonitor(dut, expected_queue)
    await monitor.run()


async def fp_regfile_monitor(
    dut: Any,
    expected_queue: list[list[int]],
    signal_paths: DUTSignalPaths | None = None,
) -> None:
    """Monitor and validate FP register file values written by the DUT.

    Compares the 32 F-extension registers (f0-f31) against the software
    model's expected values each time the DUT raises its output valid signal.
    All FP registers are writeable, so f0 is checked too.

    Args:
        dut: Device under test
        expected_queue: Queue of expected FP register file states
        signal_paths: Optional custom signal paths. If None, uses defaults.
    """
    monitor = FPRegisterFileMonitor(dut, expected_queue, signal_paths)
    await monitor.run()
