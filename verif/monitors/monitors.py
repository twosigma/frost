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

"""Hardware verification monitors for continuous output checking.

Monitors
========

This module implements concurrent verification monitors that run alongside
the main test, continuously checking hardware outputs against expected values.

How Monitors Work:
    Monitors are coroutines that run in the background, watching for valid
    output signals from the DUT. When outputs are valid, monitors:
    1. Pop expected value from their queue
    2. Read actual value from DUT
    3. Compare and raise AssertionError on mismatch

Why Use Monitors:
    - Immediate failure detection (catch errors as they happen)
    - Continuous verification (not just end-of-test)
    - Decoupled checking (test loop focuses on stimulus, monitors on checking)
    - Automatic synchronization (monitors wait for valid signals)

Monitors Provided:
    - regfile_monitor: Verifies integer register file writes (x1-x31, excluding x0)
    - fp_regfile_monitor: Verifies FP register file writes (f0-f31, all writeable)
    - pc_monitor: Verifies program counter updates

Note:
    Memory writes are monitored by MemoryModel.driver_and_monitor() which
    also drives read data back to the CPU (dual purpose).
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

T = TypeVar("T")


class Monitor(ABC, Generic[T]):
    """Abstract base class for hardware verification monitors.

    Provides the common run loop pattern for monitors that:
    1. Wait for a valid signal
    2. Read actual value from hardware
    3. Compare against expected value from queue
    4. Raise AssertionError on mismatch

    Subclasses implement the abstract methods to customize behavior.
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

        # Navigate to register file RAM once
        obj = dut
        for attr in paths.regfile_ram_rs1_path.split("."):
            obj = getattr(obj, attr)
        self._ram = obj

    def is_valid(self) -> bool:
        """Check if register file output is valid."""
        return bool(self.dut.o_vld.value)

    def read_actual(self) -> list[int]:
        """Read all register values from hardware."""
        return [int(self._ram[i].value) for i in range(NUM_REGISTERS)]

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

    Unlike the integer register file where x0 is hardwired to zero,
    all 32 FP registers (f0-f31) are fully writeable and must be verified.
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

        # Navigate to FP register file RAM once
        obj = dut
        for attr in paths.fp_regfile_ram_fs1_path.split("."):
            obj = getattr(obj, attr)
        self._ram = obj

    def is_valid(self) -> bool:
        """Check if FP register file output is valid."""
        return bool(self.dut.o_vld.value)

    def read_actual(self) -> list[int]:
        """Read all FP register values from hardware."""
        return [int(self._ram[i].value) for i in range(NUM_REGISTERS)]

    def compare(self, actual: list[int], expected: list[int]) -> str | None:
        """Compare actual and expected FP register file states.

        Unlike integer registers where x0 is always 0, all FP registers
        (f0-f31) must be compared since they are all writeable.
        """
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

    Monitors the register file (32 RISC-V general-purpose registers x0-x31) and compares
    hardware values against expected software model values. Register x0 is always 0 and
    is not checked. The monitor waits for the output valid signal before checking values.

    Args:
        dut: Device under test
        expected_queue: Queue of expected register file states
        signal_paths: Optional custom signal paths. If None, uses defaults.
    """
    monitor = RegisterFileMonitor(dut, expected_queue, signal_paths)
    await monitor.run()


async def pc_monitor(dut: Any, expected_queue: list[int]) -> None:
    """Monitor and validate program counter values from the DUT.

    Monitors the program counter (PC) output from the CPU and compares against expected
    values from the software model. The PC indicates which instruction address is currently
    being fetched. Waits for the PC valid signal before checking values.
    """
    monitor = ProgramCounterMonitor(dut, expected_queue)
    await monitor.run()


async def fp_regfile_monitor(
    dut: Any,
    expected_queue: list[list[int]],
    signal_paths: DUTSignalPaths | None = None,
) -> None:
    """Monitor and validate FP register file values written by the DUT.

    Monitors the FP register file (32 RISC-V F extension registers f0-f31) and compares
    hardware values against expected software model values. Unlike the integer register
    file where x0 is hardwired to zero, all FP registers are fully writeable.
    The monitor waits for the output valid signal before checking values.

    Args:
        dut: Device under test
        expected_queue: Queue of expected FP register file states
        signal_paths: Optional custom signal paths. If None, uses defaults.
    """
    monitor = FPRegisterFileMonitor(dut, expected_queue, signal_paths)
    await monitor.run()
