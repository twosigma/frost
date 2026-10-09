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

"""Test statistics and DUT access through configurable hierarchy paths."""

from typing import Any
from dataclasses import dataclass, field
from cocotb.triggers import FallingEdge

from config import DUTSignalPaths
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
    """Track instruction, branch, and memory-operation counts for a test."""

    instructions_executed: int = 0
    branches_taken: int = 0
    branches_not_taken: int = 0
    loads_executed: int = 0
    stores_executed: int = 0
    coverage: dict[str, int] = field(default_factory=dict)

    def record_instruction(
        self, operation: str, branch_was_taken: bool | None = None
    ) -> None:
        """Count a mnemonic and, when supplied, its branch outcome."""
        self.instructions_executed += 1
        self.coverage[operation] = self.coverage.get(operation, 0) + 1

        if branch_was_taken is not None:
            if branch_was_taken:
                self.branches_taken += 1
            else:
                self.branches_not_taken += 1

        if operation in LOADS:
            self.loads_executed += 1
        elif operation in STORES:
            self.stores_executed += 1

    def report(self) -> str:
        """Generate statistics report."""
        lines = [
            "\n=== Test Statistics ===",
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
        """Return coverage failures for recorded mnemonics below minimum_execution_count."""
        issues = []
        for operation, execution_count in self.coverage.items():
            if execution_count < minimum_execution_count:
                issues.append(
                    f"{operation}: only {execution_count} executions (min: {minimum_execution_count})"
                )
        return issues


class DUTInterface:
    """DUT signal access through configurable hierarchy paths."""

    def __init__(self, dut: Any, signal_paths: DUTSignalPaths | None = None):
        """Bind the DUT, using config.DUTSignalPaths unless custom paths are supplied."""
        self.dut = dut
        self.paths = signal_paths or DUTSignalPaths()

        # Injected instructions bypass fetch, but their PCs still use IF.
        # Disable prediction so trained BTB entries cannot redirect those PCs.
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
        """Read the combinational stall signal.

        A registered stall would remain high on release while IF accepts the
        held instruction again, causing the driver to issue it twice.
        """
        return bool(self.dut.pipeline_stall_comb.value)

    def is_in_reset(self) -> bool:
        """Check if CPU is in reset."""
        return bool(self.dut.i_rst.value)

    def is_ready(self) -> bool:
        """Check if CPU is ready for next instruction."""
        return not (self.is_stalled() or self.is_in_reset())

    def _navigate_signal_path(self, path: str) -> Any:
        """Resolve a dot-separated path relative to the DUT handle."""
        obj = self.dut
        for attr in path.split("."):
            obj = getattr(obj, attr)
        return obj

    def _get_regfile_ram(self, ram_index: int = 0) -> Any:
        """Return the configured RAM handle (ram_index: 0 for rs1, otherwise rs2)."""
        if ram_index == 0:
            path = self.paths.regfile_ram_rs1_path
        else:
            path = self.paths.regfile_ram_rs2_path
        return self._navigate_signal_path(path)

    # Read ports on the architectural integer register file (NUM_READ_PORTS of
    # its generic_regfile instance in ooo_register_files).
    _INT_RF_READ_PORTS = 4

    def _int_regfile_inst(self) -> Any | None:
        """Return the architectural integer register-file instance for the cpu_ooo DUT.

        Returns None when the hierarchy does not expose it (other toplevels).
        """
        try:
            return self.dut.device_under_test.ooo_register_files_inst.regfile_inst
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
            ram_index: Configured RAM path the fallback reads (0 = rs1, 1 = rs2)

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
        # Fallback for a DUT without the cpu_ooo hierarchy: the configured path.
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
            # Deposit into every read port so dispatch and snapshot reads agree.
            self._deposit_regfile_value(
                regfile_inst, self._INT_RF_READ_PORTS, reg, value
            )
            return
        # Fallback for a DUT without the cpu_ooo hierarchy: flat rs1 and rs2
        # RAMs at the configured paths.
        ram_rs1 = self._get_regfile_ram(0)
        ram_rs2 = self._get_regfile_ram(1)
        ram_rs1[reg].value = value
        ram_rs2[reg].value = value

    async def wait_ready(self) -> int:
        """Wait for readiness; return elapsed cycles for CSR counter synchronization."""
        wait_cycles = 0
        while not self.is_ready():
            await FallingEdge(self.clock)
            wait_cycles += 1
        return wait_cycles

    async def reset_dut(self, cycles: int = 3) -> int:
        """Reset the DUT and return the number of clock cycles elapsed.

        The count covers the ``cycles`` reset cycles and the wait for
        o_rst_done. The RTL cycle counter holds at zero during reset and runs
        during the wait, so a CSR counter model starts from the count minus
        ``cycles``.
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
