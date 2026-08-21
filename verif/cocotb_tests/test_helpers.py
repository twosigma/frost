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

"""Shared test statistics and DUT-access helpers.

Classes:
    TestStatistics: Tracks execution metrics and coverage
        - Records instruction counts by type
        - Tracks branches taken/not-taken
        - Monitors memory operation counts
        - Formats reports and validates coverage thresholds

    DUTInterface: DUT signal access
        - Hides signal hierarchy details
        - Provides property-based access to signals
        - Encapsulates register file operations
        - Supports configurable signal paths for different DUTs
        - Provides common operations (reset, wait_ready, etc.)
"""

import random
from typing import Any
from dataclasses import dataclass, field
from cocotb.triggers import FallingEdge

from config import DUTSignalPaths, MASK64
from encoders.op_tables import LOADS, STORES
from utils.validation import HardwareAssertions


def read_port_ram_entry(ram: Any, index: int) -> int:
    """Read one committed entry from a regfile read-port RAM handle.

    Supports the three shapes a read-port RAM path can resolve to:
    - Banked multi-write RAM (mwp_dist_ram): the committed value is the bank
      selected by the per-address live-value table,
      ``g_banks[lvt[index]].u_bank.ram[index]``.
    - Single-write RAM instance (sdp_dist_ram): flat ``ram[index]`` member.
    - A bare unpacked array handle: indexed directly.
    """
    try:
        sel = int(ram.lvt[index].value)
        return int(ram.g_banks[sel].u_bank.ram[index].value)
    except AttributeError:
        pass
    try:
        return int(ram.ram[index].value)
    except AttributeError:
        return int(ram[index].value)


@dataclass
class TestStatistics:
    """Track test execution statistics for better reporting."""

    cycles_executed: int = 0
    instructions_executed: int = 0
    branches_taken: int = 0
    branches_not_taken: int = 0
    loads_executed: int = 0
    stores_executed: int = 0
    coverage: dict[str, int] = field(default_factory=dict)

    def record_instruction(
        self, operation: str, branch_was_taken: bool | None = None
    ) -> None:
        """Record execution of a single instruction for statistics tracking.

        Args:
            operation: Instruction mnemonic (e.g., "add", "lw", "beq")
            branch_was_taken: For branch instructions, whether branch was taken
        """
        self.instructions_executed += 1
        self.coverage[operation] = self.coverage.get(operation, 0) + 1

        # Track branch statistics
        if branch_was_taken is not None:
            if branch_was_taken:
                self.branches_taken += 1
            else:
                self.branches_not_taken += 1

        # Track memory operation statistics
        if operation in LOADS:
            self.loads_executed += 1
        elif operation in STORES:
            self.stores_executed += 1

    def report(self) -> str:
        """Generate statistics report."""
        lines = [
            "\n=== Test Statistics ===",
            f"Total cycles: {self.cycles_executed}",
            f"Instructions executed: {self.instructions_executed}",
            f"Branches: {self.branches_taken} taken, {self.branches_not_taken} not taken",
            f"Memory ops: {self.loads_executed} loads, {self.stores_executed} stores",
            "\nInstruction coverage:",
        ]

        for op in sorted(self.coverage.keys()):
            count = self.coverage[op]
            lines.append(f"  {op:8s}: {count:4d} executions")

        return "\n".join(lines)

    def check_coverage(self, minimum_execution_count: int = 50) -> list[str]:
        """Check which instructions didn't meet minimum coverage threshold.

        Args:
            minimum_execution_count: Minimum times each instruction should execute

        Returns:
            List of instructions that didn't meet threshold

        Note:
            An instruction passes only on a strictly-greater-than check
            (count > minimum_execution_count).
        """
        issues = []
        for operation, execution_count in self.coverage.items():
            if execution_count <= minimum_execution_count:
                issues.append(
                    f"{operation}: only {execution_count} executions (min: {minimum_execution_count})"
                )
        return issues


class DUTInterface:
    """DUT signal access through configurable hierarchy paths."""

    def __init__(self, dut: Any, signal_paths: DUTSignalPaths | None = None):
        """Initialize DUT interface.

        Args:
            dut: The device under test (cocotb SimHandle)
            signal_paths: Optional custom signal paths configuration.
                         If None, uses default paths from config.
        """
        self.dut = dut
        self.paths = signal_paths or DUTSignalPaths()

        # Disable branch prediction for random instruction tests.
        # The CPU test drives instructions directly (bypassing fetch), but the PC
        # flows through the IF stage with branch prediction. As the BTB accumulates
        # entries, predictions redirect the PC unexpectedly, causing mismatches.
        # Disabling prediction ensures predictable sequential PC behavior.
        self.dut.i_disable_branch_prediction.value = 1

    @property
    def clock(self) -> Any:
        """Get clock signal."""
        return self.dut.i_clk

    @property
    def reset(self) -> Any:
        """Get reset signal."""
        return self.dut.i_rst

    @reset.setter
    def reset(self, value: int) -> None:
        """Set reset signal."""
        self.dut.i_rst.value = value

    @property
    def instruction(self) -> Any:
        """Get instruction signal."""
        return self.dut.instruction_from_testbench

    @instruction.setter
    def instruction(self, value: int) -> None:
        """Set instruction signal."""
        self.dut.instruction_from_testbench.value = value

    def is_stalled(self) -> bool:
        """Check if CPU is stalled.

        Uses the combinational stall signal (not registered) to ensure the test
        sees stalls immediately. This prevents duplicate instruction execution
        when multi-cycle stalls end: with the registered signal, there's a 1-cycle
        window where the test doesn't see the stall has ended but IF stage reads
        the same instruction from i_instr again.
        """
        return bool(self.dut.pipeline_stall_comb.value)

    def is_in_reset(self) -> bool:
        """Check if CPU is in reset."""
        return bool(self.dut.i_rst.value)

    def is_ready(self) -> bool:
        """Check if CPU is ready for next instruction."""
        return not (self.is_stalled() or self.is_in_reset())

    def _navigate_signal_path(self, path: str) -> Any:
        """Navigate to a signal using dot-separated path string.

        Args:
            path: Dot-separated path (e.g.,
                "device_under_test.ooo_register_files_inst.regfile_inst")

        Returns:
            Signal object at the path
        """
        obj = self.dut
        for attr in path.split("."):
            obj = getattr(obj, attr)
        return obj

    def _get_regfile_ram(self, ram_index: int = 0) -> Any:
        """Get register file RAM instance.

        Args:
            ram_index: 0 for rs1 RAM, 1 for rs2 RAM

        Returns:
            Register file RAM array
        """
        if ram_index == 0:
            path = self.paths.regfile_ram_rs1_path
        else:
            path = self.paths.regfile_ram_rs2_path
        return self._navigate_signal_path(path)

    # Number of read ports on the architectural register files
    # (generic_regfile instances in the current cpu_ooo).
    _INT_RF_READ_PORTS = 8
    _FP_RF_READ_PORTS = 12

    def _int_regfile_inst(self) -> Any | None:
        """Return the architectural integer register-file instance for the cpu_ooo DUT.

        Returns None when the hierarchy does not expose it (other toplevels).
        """
        try:
            return self.dut.device_under_test.ooo_register_files_inst.regfile_inst
        except Exception:
            return None

    def _fp_regfile_inst(self) -> Any | None:
        """Return the architectural FP register-file instance for the cpu_ooo DUT.

        Returns None when the hierarchy does not expose it (other toplevels).
        """
        try:
            return self.dut.device_under_test.ooo_register_files_inst.fp_regfile_inst
        except Exception:
            return None

    def _read_port_ram(self, regfile_inst: Any, port: int) -> tuple[Any, bool]:
        """Return (read_port_ram_handle, is_multi_write) for one read port.

        generic_regfile gives each read port its own RAM: a multi-write banked
        RAM (mwp_dist_ram, under gen_multi_write) when there are 2+ write ports,
        otherwise a single-write sdp_dist_ram (under gen_single_write).
        """
        rp = regfile_inst.gen_read_port[port]
        try:
            return rp.gen_multi_write.read_port_ram, True
        except Exception:
            return rp.gen_single_write.read_port_ram, False

    def _deposit_regfile_value(
        self, regfile_inst: Any, ports: int, reg: int, value: int
    ) -> None:
        """Deposit a register value into every read-port RAM of a regfile.

        For the banked multi-write RAM, writes both banks and clears the
        live-value table so every read port and the committed-value snapshot
        return the deposited value.
        """
        for port in range(ports):
            try:
                ram, multi = self._read_port_ram(regfile_inst, port)
            except Exception:
                break
            if multi:
                ram.g_banks[0].u_bank.ram[reg].value = value
                ram.g_banks[1].u_bank.ram[reg].value = value
                ram.lvt[reg].value = 0
            else:
                ram.ram[reg].value = value

    def read_register(self, reg: int, ram_index: int = 0) -> int:
        """Read an architectural integer register value from hardware.

        Args:
            reg: Register index (0-31)
            ram_index: Legacy RAM-instance selector (only used by the fallback)

        Returns:
            Register value
        """
        HardwareAssertions.assert_register_valid(reg)
        if reg == 0:
            return 0
        regfile_inst = self._int_regfile_inst()
        if regfile_inst is not None:
            ram, _ = self._read_port_ram(regfile_inst, 0)
            # Committed value = the bank chosen by the live-value table
            # (banked RAM) or the flat RAM contents (single-write RAM).
            return read_port_ram_entry(ram, reg)
        # Fallback: legacy regfile RAM via the configured signal path.
        ram = self._get_regfile_ram(ram_index)
        return read_port_ram_entry(ram, reg)

    def write_register(self, reg: int, value: int) -> None:
        """Deposit an architectural integer register value into hardware.

        Args:
            reg: Register index (0-31)
            value: Value to write
        """
        HardwareAssertions.assert_register_valid(reg)
        if reg == 0:  # x0 is always zero
            return
        regfile_inst = self._int_regfile_inst()
        if regfile_inst is not None:
            # Deposit into every read port (and, for the banked RAM, both banks
            # with the live-value table cleared) so all dispatch read ports and
            # the snapshot read return the deposited value.
            self._deposit_regfile_value(
                regfile_inst, self._INT_RF_READ_PORTS, reg, value
            )
            return
        # Fallback: legacy flat regfile RAM (rs1 + rs2 instances).
        ram_rs1 = self._get_regfile_ram(0)
        ram_rs2 = self._get_regfile_ram(1)
        ram_rs1[reg].value = value
        ram_rs2[reg].value = value

    def initialize_registers(self, seed_value: int | None = None) -> list[int]:
        """Initialize all registers randomly and return the values."""
        if seed_value is not None:
            random.seed(seed_value)

        values = [0] * 32
        for i in range(1, 32):  # x0 always 0
            values[i] = random.randint(0, 2**32 - 1)
            self.write_register(i, values[i])

        return values

    def _get_fp_regfile_ram(self, ram_index: int = 0) -> Any:
        """Get FP register file RAM instance.

        Args:
            ram_index: 0 for fs1 RAM, 1 for fs2 RAM, 2 for fs3 RAM

        Returns:
            FP register file RAM array
        """
        if ram_index == 0:
            path = self.paths.fp_regfile_ram_fs1_path
        elif ram_index == 1:
            path = self.paths.fp_regfile_ram_fs2_path
        else:
            path = self.paths.fp_regfile_ram_fs3_path
        return self._navigate_signal_path(path)

    def read_fp_register(self, reg: int) -> int:
        """Read an architectural FP register value (as raw bits) from hardware.

        Args:
            reg: FP register index (0-31)

        Returns:
            FP register raw bit value
        """
        HardwareAssertions.assert_register_valid(reg)
        regfile_inst = self._fp_regfile_inst()
        if regfile_inst is not None:
            ram, _ = self._read_port_ram(regfile_inst, 0)
            return read_port_ram_entry(ram, reg)
        # Fallback: legacy FP regfile RAM via the configured signal path.
        ram = self._get_fp_regfile_ram(0)
        return read_port_ram_entry(ram, reg)

    def write_fp_register(self, reg: int, value: int) -> None:
        """Deposit an architectural FP register value into hardware.

        Unlike integer registers where x0 is hardwired to zero,
        all FP registers f0-f31 are writable.

        Args:
            reg: FP register index (0-31)
            value: Value to write
        """
        HardwareAssertions.assert_register_valid(reg)
        masked_value = value & MASK64
        regfile_inst = self._fp_regfile_inst()
        if regfile_inst is not None:
            self._deposit_regfile_value(
                regfile_inst, self._FP_RF_READ_PORTS, reg, masked_value
            )
            return
        # Fallback: legacy flat FP regfile RAM (fs1 + fs2 + fs3 instances).
        ram_fs1 = self._get_fp_regfile_ram(0)
        ram_fs2 = self._get_fp_regfile_ram(1)
        ram_fs3 = self._get_fp_regfile_ram(2)
        ram_fs1[reg].value = masked_value
        ram_fs2[reg].value = masked_value
        ram_fs3[reg].value = masked_value

    def initialize_fp_registers(self) -> list[int]:
        """Initialize all FP registers to zero and return the values.

        FP registers start at 0 to match RTL reset state.
        This ensures test isolation when running multiple tests.
        """
        values = [0] * 32
        for i in range(32):  # All FP registers are writable (unlike x0)
            self.write_fp_register(i, 0)

        return values

    async def wait_ready(self) -> int:
        """Wait for DUT to be ready.

        Returns:
            Number of clock cycles spent waiting (for CSR counter sync)
        """
        wait_cycles = 0
        while not self.is_ready():
            await FallingEdge(self.clock)
            wait_cycles += 1
        return wait_cycles

    async def reset_dut(self, cycles: int = 3) -> int:
        """Reset the DUT and return the number of clock cycles elapsed.

        The cycle count is needed to synchronize CSR counter tracking,
        since the RTL cycle counter runs during reset/cache-clear.

        Returns:
            Number of clock cycles elapsed during reset sequence
        """
        self.reset = 1
        cycle_count = 0
        for _ in range(cycles):
            await FallingEdge(self.clock)
            cycle_count += 1
        self.reset = 0
        # RTL cycle counter starts incrementing after reset deasserts
        while not bool(self.dut.o_rst_done.value):
            await FallingEdge(self.clock)
            cycle_count += 1
        return cycle_count
