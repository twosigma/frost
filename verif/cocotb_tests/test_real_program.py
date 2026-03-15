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

"""Top-level simulation for the CPU and data/instruction memories, capable of running full programs such as Hello World and CoreMark.

Test Real Program
=================

This test monitors UART output from the CPU and checks for success/failure markers:
- Programs that run tests print "<<PASS>>" on success or "<<FAIL>>" on failure
- Hello World just needs to print "Hello, world!" to pass
- CoreMark runs with ITERATIONS=1 in simulation and must print "<<PASS>>" to pass

The test runs each program twice with a reset in between to verify programs are
robust to reset and all state is properly initialized.
"""

import os
from pathlib import Path
import re
from collections import Counter
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from typing import Any

CLK_PERIOD_NS = 3
UART_BAUD_RATE = 115200
UART_DATA_BITS = 8
UART_CLK_FREQ_HZ_DEFAULT = 300_000_000
UART_RX_DATA_MMIO_ADDR = 0x4000_0004
UART_RX_STATUS_MMIO_ADDR = 0x4000_0024

# Success/failure markers that programs print
PASS_MARKER = "<<PASS>>"
FAIL_MARKER = "<<FAIL>>"

_OBJDUMP_RE = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f ]+)\s+\s*.*$")


def _load_symbol_machine_code(
    symbol_name: str, app_name: str | None = None
) -> dict[int, tuple[int, int]]:
    """Load raw instruction words for a symbol from the compiled app objdump."""
    sw_s_path: Path | None = None

    sw_mem_path = Path("sw.mem")
    if sw_mem_path.is_symlink():
        sw_s_candidate = sw_mem_path.resolve().with_name("sw.S")
        if sw_s_candidate.exists():
            sw_s_path = sw_s_candidate

    if sw_s_path is None and app_name is not None:
        repo_root = Path(__file__).resolve().parents[2]
        sw_s_candidate = repo_root / "sw" / "apps" / app_name / "sw.S"
        if sw_s_candidate.exists():
            sw_s_path = sw_s_candidate

    if sw_s_path is None:
        return {}

    expected: dict[int, tuple[int, int]] = {}
    inside_symbol = False
    with sw_s_path.open() as sw_s_file:
        for line in sw_s_file:
            if f"<{symbol_name}>:" in line:
                inside_symbol = True
                continue
            if inside_symbol and re.match(r"^[0-9a-f]+ <.*>:$", line):
                break
            if not inside_symbol:
                continue
            match = _OBJDUMP_RE.match(line)
            if match is None:
                continue
            addr = int(match.group(1), 16)
            insn_hex = match.group(2).replace(" ", "")
            if len(insn_hex) not in {4, 8}:
                continue
            expected[addr] = (int(insn_hex, 16), 16 if len(insn_hex) == 4 else 32)

    return expected


def _load_symbol_ranges(
    symbol_names: list[str], app_name: str | None = None
) -> dict[str, tuple[int, int]]:
    """Load half-open [start, end) address ranges for symbols from sw.S."""
    sw_s_path: Path | None = None

    sw_mem_path = Path("sw.mem")
    if sw_mem_path.is_symlink():
        sw_s_candidate = sw_mem_path.resolve().with_name("sw.S")
        if sw_s_candidate.exists():
            sw_s_path = sw_s_candidate

    if sw_s_path is None and app_name is not None:
        repo_root = Path(__file__).resolve().parents[2]
        sw_s_candidate = repo_root / "sw" / "apps" / app_name / "sw.S"
        if sw_s_candidate.exists():
            sw_s_path = sw_s_candidate

    if sw_s_path is None:
        return {}

    wanted = set(symbol_names)
    symbol_starts: dict[str, int] = {}
    ordered_symbols: list[tuple[str, int]] = []
    symbol_header_re = re.compile(r"^([0-9a-f]+) <([^>]+)>:$")

    with sw_s_path.open() as sw_s_file:
        for line in sw_s_file:
            match = symbol_header_re.match(line.strip())
            if match is None:
                continue
            symbol_addr = int(match.group(1), 16)
            symbol_name = match.group(2)
            ordered_symbols.append((symbol_name, symbol_addr))
            if symbol_name in wanted:
                symbol_starts[symbol_name] = symbol_addr

    symbol_ranges: dict[str, tuple[int, int]] = {}
    for idx, (symbol_name, symbol_addr) in enumerate(ordered_symbols):
        if symbol_name not in wanted:
            continue
        end_addr = 0xFFFF_FFFF
        if idx + 1 < len(ordered_symbols):
            end_addr = ordered_symbols[idx + 1][1]
        symbol_ranges[symbol_name] = (symbol_addr, end_addr)

    return symbol_ranges


async def generate_divided_clock(dut: Any) -> None:
    """Generate i_clk_div4 as a proper 4:1 divided clock from i_clk.

    This ensures the clocks have a fixed phase relationship as expected
    by the dc_fifo clock domain crossing logic. The dc_fifo relies on clocks
    being derived from the same source (like from an MMCM) and does not use
    Gray code pointers, so the clocks must be synchronous.

    The divided clock toggles every 2 main clock rising edges, creating a
    clock with 4x the period of the main clock. Rising edges of i_clk_div4
    always coincide with rising edges of i_clk.
    """
    counter = 0
    dut.i_clk_div4.value = 0
    while True:
        await RisingEdge(dut.i_clk)
        counter += 1
        if counter == 2:
            counter = 0
            # Toggle i_clk_div4
            dut.i_clk_div4.value = 0 if int(dut.i_clk_div4.value) else 1


# Maximum cycles to run (prevents infinite loops)
# Override with COCOTB_MAX_CYCLES env var for tests needing more cycles (e.g. arch tests)
MAX_CYCLES = int(os.environ.get("COCOTB_MAX_CYCLES", 500000))

# Number of runs (reset-and-rerun cycles) per test invocation.
# Default is 2 to verify programs are robust to reset.
# Set to 1 for ISA tests that modify .text-resident data (e.g. riscv-tests rvc).
NUM_RUNS = int(os.environ.get("COCOTB_NUM_RUNS", 2))

# CoreMark-style benchmarks run the real benchmark body even with ITERATIONS=1.
# The OOO core's memory-heavy list and matrix phases legitimately exceed the
# generic program budget, so give them a larger default while keeping an env
# override.
COREMARK_MAX_CYCLES = int(os.environ.get("COCOTB_COREMARK_MAX_CYCLES", 15000000))

# sprintf_test needs more cycles due to ~200 test cases with heavy FP formatting on RV32
SPRINTF_TEST_MAX_CYCLES = 2000000

# Number of clock cycles to hold reset between runs
RESET_CYCLES = 10


class UartMonitor:
    """Monitor UART output from the CPU and collect characters."""

    def __init__(self, dut: Any) -> None:
        """Initialize the UART monitor with the DUT handle."""
        self.dut = dut
        self.output_buffer = ""
        self._running = True

    async def start(self) -> None:
        """Start monitoring UART output in the background."""
        cocotb.start_soon(self._monitor_uart())

    def stop(self) -> None:
        """Stop the monitor."""
        self._running = False

    def clear(self) -> None:
        """Clear the output buffer for a new run."""
        self.output_buffer = ""

    async def _monitor_uart(self) -> None:
        """Monitor UART write signals and collect characters."""
        while self._running:
            await RisingEdge(self.dut.i_clk)
            try:
                # Access UART signals from cpu_and_memory_subsystem
                uart_wr_en = self.dut.cpu_and_memory_subsystem.o_uart_wr_en.value
                # Check if uart_wr_en is valid (not X/Z) and equals 1
                if uart_wr_en.is_resolvable and uart_wr_en == 1:
                    uart_data = self.dut.cpu_and_memory_subsystem.o_uart_wr_data.value
                    # Check if data is valid before converting
                    if uart_data.is_resolvable:
                        char = chr(int(uart_data))
                        self.output_buffer += char
                        # Print character to console for visibility (without newline)
                        print(char, end="", flush=True)
            except AttributeError:
                # Signal not accessible (might be optimized out in some simulators)
                pass

    def contains(self, text: str) -> bool:
        """Check if the output buffer contains the given text."""
        return text in self.output_buffer

    def get_output(self) -> str:
        """Get the complete output buffer."""
        return self.output_buffer


def _get_signal(dut: Any, path: str) -> Any | None:
    """Get a nested signal by dotted path, or None if not found."""
    obj = dut
    for part in path.split("."):
        if not hasattr(obj, part):
            return None
        obj = getattr(obj, part)
    return obj


def _first_signal(dut: Any, paths: list[str]) -> Any | None:
    """Return the first resolvable signal from a list of dotted paths."""
    for path in paths:
        sig = _get_signal(dut, path)
        if sig is not None:
            return sig
    return None


def _read_int(signal: Any) -> int | None:
    """Read a signal as int, return None if not resolvable."""
    if signal is None:
        return None
    if isinstance(signal, int):
        return signal
    try:
        value = signal.value
    except AttributeError:
        return None
    if value.is_resolvable:
        return int(value)
    return None


def _read_bool(signal: Any) -> bool | None:
    """Read a signal as bool, return None if not resolvable."""
    value = _read_int(signal)
    if value is None:
        return None
    return bool(value)


class UartRxDriver:
    """Drive UART RX serial input to the DUT (8N1)."""

    def __init__(self, dut: Any) -> None:
        """Initialize UART RX driver."""
        self.dut = dut
        if not hasattr(dut, "i_uart_rx"):
            raise RuntimeError("UART RX signal not found on DUT")
        if not hasattr(dut, "i_clk_div4"):
            raise RuntimeError("UART RX driver requires i_clk_div4 on DUT")
        self.bit_cycles = self._compute_bit_cycles()
        # Idle high
        self.dut.i_uart_rx.value = 1

    def _compute_bit_cycles(self) -> int:
        """Match uart_rx.sv prescaler math to compute cycles per bit.

        uart_rx uses CLK_FREQ_HZ/4 (since it runs on clk_div4) and computes:
        ClockCyclesPerBit = (CLK_FREQ_HZ/4) / (BAUD_RATE * DATA_WIDTH)
        Then it waits ClockCyclesPerBit * DATA_WIDTH cycles per bit.
        """
        clk_freq = _read_u64(getattr(self.dut, "CLK_FREQ_HZ", None))
        if clk_freq is None:
            clk_freq = UART_CLK_FREQ_HZ_DEFAULT
        uart_clk_freq = clk_freq // 4
        base = uart_clk_freq // (UART_BAUD_RATE * UART_DATA_BITS)
        bit_cycles = base * UART_DATA_BITS
        cocotb.log.info(
            f"UartRxDriver: clk_freq={clk_freq}, uart_clk_freq={uart_clk_freq}, "
            f"base={base}, bit_cycles={bit_cycles}"
        )
        return max(1, bit_cycles)

    async def _wait_cycles(self, cycles: int) -> None:
        """Wait for a number of i_clk_div4 cycles."""
        for _ in range(cycles):
            await RisingEdge(self.dut.i_clk_div4)

    async def send_byte(self, value: int) -> None:
        """Send a single byte over UART RX (LSB first)."""
        # Start bit
        self.dut.i_uart_rx.value = 0
        await self._wait_cycles(self.bit_cycles)
        # Data bits
        for bit in range(UART_DATA_BITS):
            self.dut.i_uart_rx.value = (value >> bit) & 0x1
            await self._wait_cycles(self.bit_cycles)
        # Stop bit
        self.dut.i_uart_rx.value = 1
        await self._wait_cycles(self.bit_cycles)

    async def send(self, data: bytes) -> None:
        """Send a byte string over UART RX."""
        # Ensure line is idle for multiple bit times before starting
        # This gives the receiver time to sync after any glitches
        self.dut.i_uart_rx.value = 1
        await self._wait_cycles(self.bit_cycles * 4)
        for byte in data:
            await self.send_byte(byte)
            # Extra idle time between characters for receiver to process
            await self._wait_cycles(self.bit_cycles)


async def wait_for_uart_text(
    dut: Any,
    uart_monitor: UartMonitor,
    text: str,
    max_cycles: int,
    start_index: int = 0,
) -> None:
    """Wait until UART output contains text after start_index."""
    for cycle in range(max_cycles):
        await RisingEdge(dut.i_clk)
        if text in uart_monitor.get_output()[start_index:]:
            return
    raise AssertionError(
        f"Timed out waiting for UART text '{text}' within {max_cycles} cycles"
    )


def _read_u64(signal: Any) -> int | None:
    """Read a 64-bit counter from a cocotb signal, return None if not resolvable."""
    if signal is None:
        return None
    if isinstance(signal, int):
        return signal
    try:
        value = signal.value
    except AttributeError:
        return None
    if value.is_resolvable:
        return int(value)
    return None


class UartMmioDebugMonitor:
    """Capture MMIO/UART RX activity for debugging uart_echo."""

    def __init__(self, dut: Any, max_events: int = 200) -> None:
        """Initialize the debug monitor with the DUT and event buffer size."""
        self.dut = dut
        self.max_events = max_events
        self.events: list[str] = []
        self._running = True
        self.cycle = 0
        self.count_mmio_status = 0
        self.count_mmio_data = 0
        self.count_uart_ready = 0
        self.count_uart_valid_rise = 0

        # Try multiple paths in case of optimizer differences
        self.mmio_read_pulse = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.o_mmio_read_pulse",
                "cpu_and_memory_subsystem.mmio_read_pulse",
            ],
        )
        self.mmio_load_addr = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.o_mmio_load_addr",
                "cpu_and_memory_subsystem.mmio_load_addr",
            ],
        )
        self.mmio_load_valid = _first_signal(
            dut,
            [
                "cpu_and_memory_subsystem.cpu_inst.o_mmio_load_valid",
                "cpu_and_memory_subsystem.mmio_load_valid",
            ],
        )
        self.uart_rx_ready = _get_signal(
            dut, "cpu_and_memory_subsystem.o_uart_rx_ready"
        )
        self.uart_rx_valid = _get_signal(
            dut, "cpu_and_memory_subsystem.i_uart_rx_valid"
        )
        self.uart_rx_data = _get_signal(dut, "cpu_and_memory_subsystem.i_uart_rx_data")
        # Top-level UART RX CDC signals (inside frost)
        self.uart_rx_ready_top = _get_signal(dut, "uart_rx_data_ready_from_cpu")
        self.uart_rx_valid_top = _get_signal(dut, "uart_rx_data_valid_to_cpu")
        self.uart_rx_data_top = _get_signal(dut, "uart_rx_data_to_cpu")
        # uart_rx module signals (before CDC FIFO)
        self.uart_rx_module_valid = _get_signal(dut, "uart_receiver.o_valid")
        self.uart_rx_module_data = _get_signal(dut, "uart_receiver.o_data")
        self.uart_rx_module_ready = _get_signal(dut, "uart_receiver.i_ready")
        self.mmio_read_data_reg = _get_signal(
            dut, "cpu_and_memory_subsystem.mmio_read_data_reg"
        )
        self.mmio_read_data_comb = _get_signal(
            dut, "cpu_and_memory_subsystem.mmio_read_data_comb"
        )
        self.data_mem_or_periph = _get_signal(
            dut, "cpu_and_memory_subsystem.data_memory_or_peripheral_read_data"
        )
        # dc_fifo debug - track FIFO pointers and state
        self.fifo_read_ptr = _get_signal(
            dut, "uart_rx_cdc_fifo.read_pointer_in_output_domain"
        )
        self.fifo_write_ptr_synced = _get_signal(
            dut, "uart_rx_cdc_fifo.write_pointer_synchronized_stage2"
        )
        self.fifo_valid_reg = _get_signal(
            dut, "uart_rx_cdc_fifo.read_data_valid_registered"
        )
        self.fifo_o_data = _get_signal(dut, "uart_rx_cdc_fifo.o_data")

    async def start(self) -> None:
        """Start the background monitoring coroutine."""
        cocotb.start_soon(self._run())

    def stop(self) -> None:
        """Stop the monitoring coroutine."""
        self._running = False

    def _record(self, msg: str) -> None:
        self.events.append(msg)
        if len(self.events) > self.max_events:
            self.events.pop(0)

    def reset_events(self, reset_counts: bool = False) -> None:
        """Clear captured events (and optionally counters)."""
        self.events = []
        if reset_counts:
            self.count_mmio_status = 0
            self.count_mmio_data = 0
            self.count_uart_ready = 0
            self.count_uart_valid_rise = 0

    def dump_recent(self) -> None:
        """Log the most recent captured events and summary statistics."""
        if not self.events:
            cocotb.log.info("UART/MMIO debug: no events captured")
            return
        cocotb.log.info(
            "UART/MMIO debug summary: "
            f"mmio_status={self.count_mmio_status} "
            f"mmio_data={self.count_mmio_data} "
            f"uart_ready={self.count_uart_ready} "
            f"uart_valid_rise={self.count_uart_valid_rise}"
        )
        cocotb.log.info("UART/MMIO debug (most recent events):")
        for line in self.events:
            cocotb.log.info(line)

    async def _run(self) -> None:
        prev_uart_valid = False
        while self._running:
            await RisingEdge(self.dut.i_clk)
            self.cycle += 1

            mmio_pulse = _read_bool(self.mmio_read_pulse)
            uart_valid = _read_bool(self.uart_rx_valid)
            uart_ready = _read_bool(self.uart_rx_ready)
            mmio_addr = _read_int(self.mmio_load_addr)
            mmio_valid = _read_bool(self.mmio_load_valid)
            uart_data = _read_int(self.uart_rx_data)
            uart_valid_top = _read_bool(self.uart_rx_valid_top)
            uart_ready_top = _read_bool(self.uart_rx_ready_top)
            uart_data_top = _read_int(self.uart_rx_data_top)
            mmio_data_reg = _read_int(self.mmio_read_data_reg)
            mmio_data_comb = _read_int(self.mmio_read_data_comb)
            data_mem_or_periph = _read_int(self.data_mem_or_periph)

            if mmio_pulse and mmio_addr is not None:
                if mmio_addr == UART_RX_STATUS_MMIO_ADDR:
                    self.count_mmio_status += 1
                if mmio_addr == UART_RX_DATA_MMIO_ADDR:
                    self.count_mmio_data += 1

                status_bit = (mmio_data_reg or 0) & 0x1
                should_record = False
                if mmio_addr == UART_RX_DATA_MMIO_ADDR:
                    should_record = True
                elif mmio_addr == UART_RX_STATUS_MMIO_ADDR and (
                    status_bit or uart_valid
                ):
                    should_record = True
                elif uart_ready or uart_valid:
                    should_record = True

                if should_record:
                    self._record(
                        f"cycle={self.cycle} mmio_pulse=1 addr=0x{mmio_addr:08x} "
                        f"mmio_valid={mmio_valid} uart_valid={uart_valid} "
                        f"uart_ready={uart_ready} uart_data=0x{(uart_data or 0):02x} "
                        f"uart_valid_top={uart_valid_top} uart_ready_top={uart_ready_top} "
                        f"uart_data_top=0x{(uart_data_top or 0):02x} "
                        f"mmio_data_reg=0x{(mmio_data_reg or 0):08x} "
                        f"mmio_data_comb=0x{(mmio_data_comb or 0):08x} "
                        f"mem_or_periph=0x{(data_mem_or_periph or 0):08x}"
                    )
            if uart_ready:
                self.count_uart_ready += 1
                fifo_rptr = _read_int(self.fifo_read_ptr)
                fifo_wptr_sync = _read_int(self.fifo_write_ptr_synced)
                fifo_valid = _read_bool(self.fifo_valid_reg)
                fifo_data = _read_int(self.fifo_o_data)
                self._record(
                    f"cycle={self.cycle} uart_ready=1 addr=0x{(mmio_addr or 0):08x} "
                    f"uart_valid={uart_valid} uart_data=0x{(uart_data or 0):02x} "
                    f"fifo_rptr={fifo_rptr} fifo_wptr_sync={fifo_wptr_sync} "
                    f"fifo_valid={fifo_valid} fifo_data=0x{(fifo_data or 0):02x}"
                )
            if uart_valid and not prev_uart_valid:
                self.count_uart_valid_rise += 1
                fifo_rptr = _read_int(self.fifo_read_ptr)
                fifo_wptr_sync = _read_int(self.fifo_write_ptr_synced)
                fifo_data = _read_int(self.fifo_o_data)
                self._record(
                    f"cycle={self.cycle} uart_valid_rise data=0x{(uart_data or 0):02x} "
                    f"fifo_rptr={fifo_rptr} fifo_wptr_sync={fifo_wptr_sync} "
                    f"fifo_data=0x{(fifo_data or 0):02x}"
                )

            # Monitor uart_rx module output (before CDC FIFO)
            uart_rx_mod_valid = _read_bool(self.uart_rx_module_valid)
            uart_rx_mod_data = _read_int(self.uart_rx_module_data)
            uart_rx_mod_ready = _read_bool(self.uart_rx_module_ready)
            if uart_rx_mod_valid and not getattr(
                self, "_prev_uart_rx_mod_valid", False
            ):
                self._record(
                    f"cycle={self.cycle} UART_RX_MODULE valid_rise data=0x{(uart_rx_mod_data or 0):02x} "
                    f"ready={uart_rx_mod_ready}"
                )
            self._prev_uart_rx_mod_valid = bool(uart_rx_mod_valid)

            prev_uart_valid = bool(uart_valid)


def read_ras_stats(dut: Any) -> dict[str, int] | None:
    """Read RAS stats counters from the DUT if available."""
    try:
        cpu = dut.cpu_and_memory_subsystem.cpu_inst
    except AttributeError:
        return None

    ras_predicted = _read_u64(getattr(cpu, "ras_predicted_count", None))
    if ras_predicted is None:
        return None
    ras_return = _read_u64(getattr(cpu, "ras_return_count", None))
    if ras_return is None:
        return None
    ras_correct = _read_u64(getattr(cpu, "ras_correct_count", None))
    if ras_correct is None:
        return None
    ras_mispred = _read_u64(getattr(cpu, "ras_mispred_count", None))
    if ras_mispred is None:
        return None

    return {
        "ras_predicted": ras_predicted,
        "ras_return": ras_return,
        "ras_correct": ras_correct,
        "ras_mispred": ras_mispred,
    }


def log_ras_stats(run_number: int, stats: dict[str, int] | None) -> None:
    """Log RAS stats in a compact format."""
    if stats is None:
        return

    predicted = stats["ras_predicted"]
    returns = stats["ras_return"]
    correct = stats["ras_correct"]
    mispred = stats["ras_mispred"]

    acc = (correct / predicted) if predicted else 0.0
    use = (predicted / returns) if returns else 0.0

    cocotb.log.info(
        f"Run {run_number} RAS stats: predicted={predicted}, returns={returns}, "
        f"correct={correct}, mispred={mispred}, "
        f"predicted/returns={use:.3f}, correct/predicted={acc:.3f}"
    )


def get_expected_behavior() -> tuple[str | None, str | None, bool, str | None]:
    """Determine expected behavior based on the program being tested.

    Returns:
        Tuple of (success_marker, initial_text, has_defined_endpoint, app_name)
        - success_marker: Text that indicates test passed (None for open-ended tests)
        - initial_text: Text that must appear for test to pass (for open-ended tests)
        - has_defined_endpoint: True if test has a clear pass/fail endpoint
        - app_name: Name of the application being tested (for timeout selection)
    """
    # Check the sw.mem symlink to determine which program is running
    # The symlink is in the current working directory (tests/) not where this file is located
    sw_mem_path = "sw.mem"

    if os.path.islink(sw_mem_path):
        target = os.readlink(sw_mem_path)
        # Extract app name from path like "../sw/apps/hello_world/sw.mem"
        parts = target.split("/")
        if "apps" in parts:
            app_idx = parts.index("apps")
            if app_idx + 1 < len(parts):
                app_name = parts[app_idx + 1]

                # Define expected behavior per app
                if app_name == "hello_world":
                    # Just needs to print the first hello message
                    return (None, "Hello, world!", False, app_name)
                if app_name == "uart_echo":
                    # Interactive test handled separately (UART input injection)
                    return (None, None, False, app_name)
                else:
                    # All other tests (including coremark) have pass/fail markers
                    return (PASS_MARKER, None, True, app_name)

    # Default: expect pass marker
    return (PASS_MARKER, None, True, None)


async def run_until_complete(
    dut: Any,
    uart_monitor: UartMonitor,
    success_marker: str | None,
    initial_text: str | None,
    has_defined_endpoint: bool,
    max_cycles: int,
    run_number: int,
    app_name: str | None = None,
) -> None:
    """Run the program until it passes, fails, or times out.

    Args:
        dut: Device under test
        uart_monitor: UART monitor instance (should already be started)
        success_marker: Text that indicates test passed
        initial_text: Text that must appear for open-ended tests
        has_defined_endpoint: True if test has a clear pass/fail endpoint
        max_cycles: Maximum cycles before timeout
        run_number: Which run this is (1 or 2) for logging

    Raises:
        AssertionError: If test fails or times out
    """
    test_passed = False
    test_failed = False
    cycle = 0
    retired_count = 0
    last_progress_retired = 0
    is_coremark_like = app_name is not None and app_name.startswith("coremark")
    progress_interval = 0
    if is_coremark_like:
        progress_interval = int(
            os.environ.get("COCOTB_COREMARK_PROGRESS_INTERVAL", 500_000)
        )
    retire_sig = None
    pc_sig = None
    pc_vld_sig = None
    mem_rd_en_sig = None
    mem_addr_sig = None
    mem_wr_en_sig = None
    sq_count_sig = None
    sq_full_sig = None
    rob_count_sig = None
    dispatch_stall_sig = None
    retire_pc_sig = None
    retire_mispredict_sig = None
    branch_pred_off_sig = None
    branch_in_flight_count_sig = None
    fe_cf_pending_sig = None
    if_cf_pending_sig = None
    pd_cf_pending_sig = None
    id_cf_pending_sig = None
    if_btb_pred_sig = None
    if_ras_pred_sig = None
    pd_btb_pred_sig = None
    pd_ras_pred_sig = None
    id_btb_pred_sig = None
    id_ras_pred_sig = None
    lq_issue_mem_found_sig = None
    lq_sq_check_valid_sig = None
    lq_sq_can_issue_sig = None
    lq_sq_do_forward_sig = None
    lq_cache_hit_fast_path_sig = None
    lq_mem_outstanding_sig = None
    btb_hit_sig = None
    btb_pred_taken_sig = None
    pred_used_sig = None
    pred_holdoff_sig = None
    if_ras_pred_sig = None
    pd_ras_pred_sig = None
    id_ras_pred_sig = None
    if_pc_sig = None
    if_sel_nop_sig = None
    if_sel_spanning_sig = None
    if_sel_compressed_sig = None
    if_raw_parcel_sig = None
    if_effective_instr_sig = None
    if_spanning_instr_sig = None
    pd_pc_sig = None
    pd_instr_sig = None
    id_pc_sig = None
    id_op_sig = None
    int_rf_write_enable_sig = None
    int_rf_write_addr_sig = None
    int_rf_write_data_sig = None
    issue_valid_sig = None
    issue_pc_sig = None
    issue_src1_sig = None
    issue_src2_sig = None
    issue_pred_taken_sig = None
    control_flow_trace_label = None
    control_flow_trace_ranges: list[tuple[int, int]] | None = None
    control_flow_trace_env = os.environ.get("FROST_CONTROL_FLOW_TRACE_RANGES")
    branch_taken_live_sig = None
    branch_target_live_sig = None
    if_control_flow_holdoff_sig = None
    if_stall_sig = None
    if_stall_registered_sig = None
    front_end_cf_serialize_stall_sig = None
    front_end_stall_q_sig = None
    replay_after_dispatch_stall_q_sig = None
    if_ras_ckpt_tos_sig = None
    if_ras_ckpt_vc_sig = None
    pd_ras_ckpt_tos_sig = None
    pd_ras_ckpt_vc_sig = None
    id_ras_ckpt_tos_sig = None
    id_ras_ckpt_vc_sig = None
    ras_misprediction_live_sig = None
    ras_restore_tos_live_sig = None
    ras_restore_valid_count_live_sig = None
    ras_pop_after_restore_live_sig = None
    commit_valid_live_sig = None
    commit_pc_live_sig = None
    commit_is_return_live_sig = None
    commit_is_call_live_sig = None
    commit_checkpoint_id_live_sig = None
    commit_has_checkpoint_live_sig = None
    commit_predicted_taken_live_sig = None
    commit_branch_taken_live_sig = None
    if_valid_live_sig = None
    pd_valid_live_sig = None
    id_valid_live_sig = None
    post_flush_holdoff_live_sig = None
    csr_in_flight_live_sig = None
    pipeline_stall_live_sig = None
    pipeline_stall_registered_live_sig = None
    rob_alloc_valid_live_sig = None
    rob_alloc_pc_live_sig = None
    rob_alloc_is_csr_live_sig = None
    rob_alloc_is_mret_live_sig = None
    id_instruction_live_sig = None
    coremark_cf_debug_enabled = (
        is_coremark_like and os.environ.get("FROST_COREMARK_CF_DEBUG") == "1"
    )
    coremark_if_check_enabled = (
        is_coremark_like and os.environ.get("FROST_COREMARK_IF_CHECK") == "1"
    )
    coremark_matrix_expected: dict[int, tuple[int, int]] = {}
    coremark_symbol_ranges: dict[str, tuple[int, int]] = {}
    coremark_if_check_symbol = os.environ.get(
        "FROST_COREMARK_IF_CHECK_SYMBOL", "matrix_test"
    )
    coremark_retire_trace_path = (
        os.environ.get("FROST_COREMARK_RETIRE_TRACE_PATH") if is_coremark_like else None
    )
    coremark_retire_trace_symbol = (
        os.environ.get("FROST_COREMARK_RETIRE_TRACE_SYMBOL", "matrix_test")
        if is_coremark_like
        else None
    )
    coremark_matrix_base_pc: int | None = None
    coremark_matrix_last_pc: int | None = None
    coremark_matrix_retire_trace: list[int] = []
    if control_flow_trace_env:
        parsed_ranges: list[tuple[int, int]] = []
        for raw_range in control_flow_trace_env.split(","):
            raw_range = raw_range.strip()
            if not raw_range:
                continue
            if "-" not in raw_range:
                raise ValueError(
                    "FROST_CONTROL_FLOW_TRACE_RANGES entries must be start-end"
                )
            start_text, end_text = raw_range.split("-", 1)
            parsed_ranges.append((int(start_text, 0), int(end_text, 0)))
        control_flow_trace_ranges = parsed_ranges
        control_flow_trace_label = os.environ.get(
            "FROST_CONTROL_FLOW_TRACE_LABEL", f"{app_name or 'program'} trace"
        )
    if is_coremark_like:
        retire_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_valid"
        )
        retire_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_rob.o_commit.pc"
        )
        retire_mispredict_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.commit_is_misprediction"
        )
        pc_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.o_pc")
        pc_vld_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.o_pc_vld")
        mem_rd_en_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.o_data_mem_read_enable"
        )
        mem_addr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.o_data_mem_addr"
        )
        mem_wr_en_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.o_data_mem_per_byte_wr_en"
        )
        sq_count_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.sq_count")
        sq_full_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.sq_full")
        rob_count_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.rob_count")
        dispatch_stall_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_dispatch_stall"
        )
        branch_pred_off_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.disable_branch_prediction_ooo"
        )
        branch_in_flight_count_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_branch_in_flight_count"
        )
        fe_cf_pending_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.front_end_control_flow_pending"
        )
        if_stall_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pipeline_stall"
        )
        if_stall_registered_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pipeline_stall_registered"
        )
        front_end_cf_serialize_stall_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_front_end_cf_serialize_stall"
        )
        front_end_stall_q_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_stall_q"
        )
        replay_after_dispatch_stall_q_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_replay_after_dispatch_stall_q"
        )
        if coremark_cf_debug_enabled:
            if_cf_pending_sig = _get_signal(
                dut, "cpu_and_memory_subsystem.cpu_inst.if_unpredicted_control_flow"
            )
            pd_cf_pending_sig = _get_signal(
                dut, "cpu_and_memory_subsystem.cpu_inst.pd_unpredicted_control_flow"
            )
            id_cf_pending_sig = _get_signal(
                dut, "cpu_and_memory_subsystem.cpu_inst.id_unpredicted_control_flow"
            )
            if_btb_pred_sig = _get_signal(
                dut,
                "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.btb_predicted_taken",
            )
            if_ras_pred_sig = _get_signal(
                dut, "cpu_and_memory_subsystem.cpu_inst.dbg_if_ras_predicted"
            )
            pd_btb_pred_sig = _get_signal(
                dut,
                "cpu_and_memory_subsystem.cpu_inst.from_pd_to_id.btb_predicted_taken",
            )
            pd_ras_pred_sig = _get_signal(
                dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_ras_predicted"
            )
            id_btb_pred_sig = _get_signal(
                dut,
                "cpu_and_memory_subsystem.cpu_inst.from_id_to_ex.btb_predicted_taken",
            )
            id_ras_pred_sig = _get_signal(
                dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_ras_predicted"
            )
        lq_issue_mem_found_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_lq.issue_mem_found",
        )
        lq_sq_check_valid_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.sq_check_valid",
        )
        lq_sq_can_issue_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_lq.sq_can_issue",
        )
        lq_sq_do_forward_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_lq.sq_do_forward",
        )
        lq_cache_hit_fast_path_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_lq.cache_hit_fast_path",
        )
        lq_mem_outstanding_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_lq.mem_outstanding",
        )
        if_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.program_counter"
        )
        if_sel_nop_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.sel_nop"
        )
        if_sel_spanning_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.sel_spanning"
        )
        if_sel_compressed_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.sel_compressed"
        )
        if_raw_parcel_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.raw_parcel"
        )
        if_effective_instr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.effective_instr"
        )
        if_spanning_instr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.spanning_instr"
        )
        pd_pc_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_pc")
        pd_instr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_instr"
        )
        id_pc_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_pc")
        id_op_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_id_to_ex.instruction_operation",
        )
        issue_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.o_rs_issue_valid"
        )
        issue_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.o_rs_issue_pc"
        )
        if coremark_if_check_enabled:
            coremark_matrix_expected = _load_symbol_machine_code(
                coremark_if_check_symbol, app_name
            )
        elif coremark_retire_trace_path is not None:
            coremark_matrix_expected = _load_symbol_machine_code(
                coremark_if_check_symbol, app_name
            )
        if coremark_matrix_expected:
            coremark_matrix_base_pc = min(coremark_matrix_expected)
            coremark_matrix_last_pc = max(coremark_matrix_expected)
        coremark_symbol_ranges = _load_symbol_ranges(
            [
                "core_bench_list",
                "matrix_test",
                "core_bench_matrix",
                "core_state_transition",
                "core_bench_state",
                "crc16",
                "crcu16",
            ],
            app_name,
        )
        if (
            coremark_retire_trace_path is not None
            and coremark_retire_trace_symbol is not None
            and coremark_retire_trace_symbol in coremark_symbol_ranges
        ):
            coremark_matrix_base_pc, coremark_matrix_last_pc = coremark_symbol_ranges[
                coremark_retire_trace_symbol
            ]
            coremark_matrix_last_pc -= 1
    elif (
        app_name in {"branch_pred_test", "ras_stress_test"} or control_flow_trace_ranges
    ):
        retire_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.o_vld")
        retire_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.u_rob.o_commit.pc"
        )
        retire_mispredict_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.commit_is_misprediction"
        )
        pc_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.o_pc")
        pc_vld_sig = _get_signal(dut, "cpu_and_memory_subsystem.cpu_inst.o_pc_vld")
        branch_pred_off_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.disable_branch_prediction_ooo"
        )
        fe_cf_pending_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.front_end_control_flow_pending"
        )
        btb_hit_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.btb_hit",
        )
        btb_pred_taken_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.btb_predicted_taken",
        )
        pred_used_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.o_prediction_used",
        )
        pred_holdoff_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.o_prediction_holdoff",
        )
        if_ras_pred_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_if_ras_predicted"
        )
        pd_ras_pred_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_ras_predicted"
        )
        id_ras_pred_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_ras_predicted"
        )
        if_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.program_counter"
        )
        if_sel_nop_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.sel_nop"
        )
        if_raw_parcel_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.raw_parcel"
        )
        if_spanning_instr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.spanning_instr"
        )
        if_ras_ckpt_tos_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_if_ras_checkpoint_tos"
        )
        if_ras_ckpt_vc_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.dbg_if_ras_checkpoint_valid_count",
        )
        if_sel_spanning_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_if_to_pd.sel_spanning"
        )
        pd_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_pd_to_id.program_counter"
        )
        pd_instr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_pd_to_id.instruction"
        )
        pd_ras_ckpt_tos_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_ras_checkpoint_tos"
        )
        pd_ras_ckpt_vc_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.dbg_pd_ras_checkpoint_valid_count",
        )
        id_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_id_to_ex.program_counter"
        )
        id_ras_ckpt_tos_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_ras_checkpoint_tos"
        )
        id_ras_ckpt_vc_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.dbg_id_ras_checkpoint_valid_count",
        )
        id_op_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_id_to_ex.instruction_operation",
        )
        int_rf_write_enable_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.int_rf_write_enable"
        )
        int_rf_write_addr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.int_rf_write_addr"
        )
        int_rf_write_data_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.int_rf_write_data"
        )
        issue_valid_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.o_rs_issue_valid"
        )
        issue_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.o_rs_issue_pc"
        )
        issue_src1_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.o_rs_issue_src1_value"
        )
        issue_src2_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.o_rs_issue_src2_value"
        )
        issue_pred_taken_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.u_tomasulo.o_rs_issue_predicted_taken",
        )
        redirect_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.misprediction_redirect_pc"
        )
        btb_update_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.btb_update"
        )
        btb_update_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.btb_update_pc"
        )
        btb_update_target_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.btb_update_target",
        )
        btb_update_taken_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.btb_update_taken"
        )
        btb_update_compressed_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.btb_update_compressed",
        )
        if_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pc"
        )
        if_pc_reg_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pc_reg"
        )
        if_raw_parcel_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.raw_parcel"
        )
        if_effective_instr_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.effective_instr"
        )
        if_spanning_instr_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.spanning_instr"
        )
        if_sel_nop_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.sel_nop"
        )
        if_sel_spanning_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.sel_spanning"
        )
        if_sel_compressed_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.sel_compressed"
        )
        pending_prediction_active_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pending_prediction_active",
        )
        pending_prediction_fetch_holdoff_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pending_prediction_fetch_holdoff",
        )
        if_is_compressed_for_pc_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.is_compressed_for_pc"
        )
        if_is_32bit_spanning_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.is_32bit_spanning"
        )
        if_spanning_wait_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.spanning_wait_for_fetch",
        )
        if_spanning_in_progress_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.spanning_in_progress"
        )
        if_use_instr_buffer_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.use_instr_buffer"
        )
        if_use_buffer_after_prediction_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.use_buffer_after_prediction",
        )
        if_prev_compressed_lo_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.prev_was_compressed_at_lo",
        )
        pc_seq_next_pc_reg_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pc_controller_inst.seq_next_pc_reg",
        )
        pc_next_pc_reg_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pc_controller_inst.next_pc_reg",
        )
        pc_prev_was_32bit_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pc_controller_inst.prev_was_32bit",
        )
        pc_mid_32bit_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.pc_controller_inst.o_mid_32bit_correction",
        )
        ras_tos_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.tos",
        )
        ras_valid_count_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.valid_count",
        )
        ras_write_enable_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.ras_write_enable",
        )
        ras_write_data_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.ras_write_data",
        )
        ras_do_pop_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.do_pop",
        )
        ras_do_push_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.do_push",
        )
        ras_capture_inputs_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_inst.capture_op_inputs",
        )
        ras_target_live_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_target",
        )
        ras_is_call_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_is_call",
        )
        ras_is_return_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.ras_is_return",
        )
        ras_link_address_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.branch_prediction_controller_inst.i_link_address",
        )
        ras_misprediction_live_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.ras_misprediction",
        )
        ras_restore_tos_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.ras_restore_tos"
        )
        ras_restore_valid_count_live_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.ras_restore_valid_count",
        )
        ras_pop_after_restore_live_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.ras_pop_after_restore",
        )
        commit_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_valid"
        )
        commit_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_pc"
        )
        commit_is_return_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_is_return"
        )
        commit_is_call_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_is_call"
        )
        commit_checkpoint_id_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_checkpoint_id"
        )
        commit_has_checkpoint_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_has_checkpoint"
        )
        commit_predicted_taken_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_predicted_taken"
        )
        commit_branch_taken_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_commit_branch_taken"
        )
        commit_is_mret_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.rob_commit.is_mret"
        )
        branch_taken_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.branch_taken"
        )
        branch_target_live_sig = _get_signal(
            dut,
            "cpu_and_memory_subsystem.cpu_inst.from_ex_comb_synth.branch_target_address",
        )
        trap_taken_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.trap_taken"
        )
        mret_taken_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.mret_taken"
        )
        trap_target_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.trap_target"
        )
        trap_pending_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.trap_pending"
        )
        rob_trap_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.rob_trap_pc"
        )
        rob_trap_cause_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.rob_trap_cause"
        )
        mret_start_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.mret_start"
        )
        csr_commit_fire_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.csr_commit_fire"
        )
        csr_mtvec_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.csr_mtvec"
        )
        csr_mepc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.csr_mepc"
        )
        flush_pipeline_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.flush_pipeline"
        )
        commit_is_misprediction_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.commit_is_misprediction"
        )
        pd_final_instruction_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_instr"
        )
        pd_program_counter_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_pc"
        )
        id_program_counter_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_pc"
        )
        id_is_mret_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_is_mret"
        )
        id_instruction_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_instr"
        )
        if_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_if_valid_q"
        )
        pd_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pd_valid_q"
        )
        id_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_id_valid"
        )
        post_flush_holdoff_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_post_flush_holdoff_q"
        )
        csr_in_flight_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_csr_in_flight"
        )
        pipeline_stall_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pipeline_stall"
        )
        pipeline_stall_registered_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_pipeline_stall_registered"
        )
        rob_alloc_valid_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_alloc_valid"
        )
        rob_alloc_pc_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_alloc_pc"
        )
        rob_alloc_is_csr_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_alloc_is_csr"
        )
        rob_alloc_is_mret_live_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.dbg_rob_alloc_is_mret"
        )
        if_control_flow_holdoff_sig = _get_signal(
            dut, "cpu_and_memory_subsystem.cpu_inst.if_stage_inst.control_flow_holdoff"
        )
        if app_name == "branch_pred_test":
            if control_flow_trace_label is None:
                control_flow_trace_label = "Branch_pred_test"
            if control_flow_trace_ranges is None:
                control_flow_trace_ranges = [(0x352, 0x358)]
        elif app_name == "ras_stress_test":
            if control_flow_trace_label is None:
                control_flow_trace_label = "RAS_stress_test"
            if control_flow_trace_ranges is None:
                control_flow_trace_ranges = [
                    (0x315C, 0x3194),
                    (0x3196, 0x32C2),
                    (0x353C, 0x35DC),
                ]

    retired_pc_hist: Counter[int] = Counter()
    retired_mispredicts = 0
    last_progress_mispredicts = 0
    control_flow_debug_events: list[str] = []
    special_issue_events: list[str] = []
    btb_update_events: list[str] = []
    coremark_return_events: list[str] = []
    coremark_matrix_events: list[str] = []
    special_issue_limit = 80
    control_flow_debug_limit = int(
        os.environ.get(
            "FROST_CONTROL_FLOW_TRACE_LIMIT",
            "260" if app_name == "ras_stress_test" else "260",
        )
    )
    coremark_return_limit = 32
    coremark_matrix_limit = 160
    last_x2_commit = None
    last_x5_commit = None
    last_x8_commit = None
    last_x9_commit = None
    last_x10_commit = None
    last_x11_commit = None
    last_x18_commit = None
    last_x19_commit = None
    control_flow_trace_enabled = True
    retire_only_trace = os.environ.get("FROST_CONTROL_FLOW_RETIRE_ONLY") == "1"
    ras_transition_trace_active = True

    def in_trace_window(pc: int | None) -> bool:
        if pc is None or control_flow_trace_ranges is None:
            return False
        return any(lo <= pc <= hi for lo, hi in control_flow_trace_ranges)

    def in_coremark_matrix_window(pc: int | None) -> bool:
        if pc is None:
            return False
        return any(lo <= pc < hi for lo, hi in coremark_symbol_ranges.values())

    def coremark_symbol_name_for_pc(pc: int | None) -> str:
        if pc is None:
            return "-"
        for symbol_name, (lo, hi) in coremark_symbol_ranges.items():
            if lo <= pc < hi:
                return symbol_name
        return "-"

    def format_coremark_if_mismatch(
        *,
        stage: str,
        pc: int,
        expected_bits: int,
        expected_width: int,
        raw: int,
        sel_nop: bool,
        sel_spanning: bool,
        sel_compressed: bool,
        effective_instr: int,
        spanning_instr: int,
        pd_pc: int | None,
        pd_instr: int | None,
        id_pc: int | None,
        retire_pc: int | None,
    ) -> str:
        return (
            f"CoreMark matrix IF mismatch at cycle={cycle + 1} "
            f"stage={stage} pc=0x{pc:08x} "
            f"expected_width={expected_width} expected=0x{expected_bits:0{expected_width // 4}x} "
            f"sel_nop={int(sel_nop)} sel_span={int(sel_spanning)} "
            f"sel_comp={int(sel_compressed)} raw=0x{raw:04x} "
            f"eff=0x{effective_instr:08x} span=0x{spanning_instr:08x} "
            f"pd_pc=0x{(pd_pc or 0):08x} pd_instr=0x{(pd_instr or 0):08x} "
            f"id_pc=0x{(id_pc or 0):08x} retire_pc=0x{(retire_pc or 0):08x}"
        )

    def dump_coremark_retire_trace() -> None:
        if (
            coremark_retire_trace_path is None
            or coremark_matrix_base_pc is None
            or not coremark_matrix_retire_trace
        ):
            return
        trace_path = Path(coremark_retire_trace_path)
        trace_path.write_text(
            "\n".join(f"0x{pc:04x}" for pc in coremark_matrix_retire_trace) + "\n"
        )

    for cycle in range(max_cycles):
        await RisingEdge(dut.i_clk)
        if _read_bool(int_rf_write_enable_sig):
            commit_addr = _read_int(int_rf_write_addr_sig)
            commit_data = _read_int(int_rf_write_data_sig)
            if commit_addr == 2:
                last_x2_commit = commit_data
            elif commit_addr == 5:
                last_x5_commit = commit_data
            elif commit_addr == 8:
                last_x8_commit = commit_data
            elif commit_addr == 9:
                last_x9_commit = commit_data
            elif commit_addr == 10:
                last_x10_commit = commit_data
            elif commit_addr == 11:
                last_x11_commit = commit_data
            elif commit_addr == 18:
                last_x18_commit = commit_data
            elif commit_addr == 19:
                last_x19_commit = commit_data
        if _read_bool(retire_sig):
            retired_count += 1
            retire_pc = _read_int(retire_pc_sig)
            if retire_pc is not None:
                retired_pc_hist[retire_pc] += 1
                if (
                    coremark_retire_trace_path is not None
                    and coremark_matrix_base_pc is not None
                    and coremark_matrix_last_pc is not None
                    and coremark_matrix_base_pc <= retire_pc <= coremark_matrix_last_pc
                    and len(coremark_matrix_retire_trace) < 20000
                ):
                    coremark_matrix_retire_trace.append(
                        retire_pc - coremark_matrix_base_pc
                    )
                if (
                    is_coremark_like
                    and len(coremark_return_events) < coremark_return_limit
                ):
                    return_name = coremark_symbol_name_for_pc(retire_pc)
                    if return_name != "-":
                        coremark_return_events.append(
                            f"cycle={cycle + 1} sym={return_name} "
                            f"pc=0x{retire_pc:08x} "
                            f"a0=0x{(last_x10_commit or 0):08x} "
                            f"a1=0x{(last_x11_commit or 0):08x} "
                            f"x19=0x{(last_x19_commit or 0):08x}"
                        )
            if _read_bool(retire_mispredict_sig):
                retired_mispredicts += 1
            if (
                control_flow_trace_label is not None
                and control_flow_trace_enabled
                and ras_transition_trace_active
                and in_trace_window(retire_pc)
                and len(control_flow_debug_events) < control_flow_debug_limit
            ):
                pc = _read_int(pc_sig)
                control_flow_debug_events.append(
                    "retire "
                    f"cycle={cycle + 1} "
                    f"x2={last_x2_commit} "
                    f"x5={last_x5_commit} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"x10={last_x10_commit} "
                    f"x11={last_x11_commit} "
                    f"x19={last_x19_commit} "
                    f"retire_pc=0x{retire_pc:08x} "
                    f"fetch_pc=0x{(pc or 0):08x} "
                    f"pred_off={_read_bool(branch_pred_off_sig)} "
                    f"fe_cf_pending={_read_bool(fe_cf_pending_sig)} "
                    f"cf_hold={_read_bool(if_control_flow_holdoff_sig)} "
                    f"br_taken={_read_bool(branch_taken_live_sig)} "
                    f"br_target=0x{(_read_int(branch_target_live_sig) or 0):08x} "
                    f"btb_hit={_read_bool(btb_hit_sig)} "
                    f"btb_pred_taken={_read_bool(btb_pred_taken_sig)} "
                    f"pred_used={_read_bool(pred_used_sig)} "
                    f"pred_holdoff={_read_bool(pred_holdoff_sig)} "
                    f"if_ras={_read_bool(if_ras_pred_sig)} "
                    f"pd_ras={_read_bool(pd_ras_pred_sig)} "
                    f"id_ras={_read_bool(id_ras_pred_sig)} "
                    f"mispredict={_read_bool(retire_mispredict_sig)} "
                    f"redirect_pc=0x{(_read_int(redirect_pc_sig) or 0):08x}"
                )

        if coremark_if_check_enabled and coremark_matrix_expected:
            if_pc = _read_int(if_pc_sig)
            pd_pc = _read_int(pd_pc_sig)
            pd_instr = _read_int(pd_instr_sig)
            id_pc = _read_int(id_pc_sig)
            retire_pc = _read_int(retire_pc_sig) if _read_bool(retire_sig) else None
            if if_pc in coremark_matrix_expected:
                expected_bits, expected_width = coremark_matrix_expected[if_pc]
                sel_nop = bool(_read_bool(if_sel_nop_sig))
                sel_spanning = bool(_read_bool(if_sel_spanning_sig))
                sel_compressed = bool(_read_bool(if_sel_compressed_sig))
                raw = _read_int(if_raw_parcel_sig) or 0
                effective_instr = _read_int(if_effective_instr_sig) or 0
                spanning_instr = _read_int(if_spanning_instr_sig) or 0

                if not sel_nop:
                    mismatch = False
                    if expected_width == 16:
                        mismatch = (not sel_compressed) or (raw != expected_bits)
                    elif if_pc & 0x2:
                        mismatch = (not sel_spanning) or (
                            spanning_instr != expected_bits
                        )
                    else:
                        mismatch = (
                            sel_compressed
                            or sel_spanning
                            or (effective_instr != expected_bits)
                        )

                    if mismatch:
                        raise AssertionError(
                            format_coremark_if_mismatch(
                                stage="if",
                                pc=if_pc,
                                expected_bits=expected_bits,
                                expected_width=expected_width,
                                raw=raw,
                                sel_nop=sel_nop,
                                sel_spanning=sel_spanning,
                                sel_compressed=sel_compressed,
                                effective_instr=effective_instr,
                                spanning_instr=spanning_instr,
                                pd_pc=pd_pc,
                                pd_instr=pd_instr,
                                id_pc=id_pc,
                                retire_pc=retire_pc,
                            )
                        )

            if pd_pc in coremark_matrix_expected and pd_instr not in {None, 0x00000013}:
                expected_bits, expected_width = coremark_matrix_expected[pd_pc]
                if expected_width == 32 and pd_instr != expected_bits:
                    raise AssertionError(
                        format_coremark_if_mismatch(
                            stage="pd",
                            pc=pd_pc,
                            expected_bits=expected_bits,
                            expected_width=expected_width,
                            raw=_read_int(if_raw_parcel_sig) or 0,
                            sel_nop=bool(_read_bool(if_sel_nop_sig)),
                            sel_spanning=bool(_read_bool(if_sel_spanning_sig)),
                            sel_compressed=bool(_read_bool(if_sel_compressed_sig)),
                            effective_instr=_read_int(if_effective_instr_sig) or 0,
                            spanning_instr=_read_int(if_spanning_instr_sig) or 0,
                            pd_pc=pd_pc,
                            pd_instr=pd_instr,
                            id_pc=id_pc,
                            retire_pc=retire_pc,
                        )
                    )

        if is_coremark_like and len(coremark_matrix_events) < coremark_matrix_limit:
            if_pc = _read_int(if_pc_sig)
            pd_pc = _read_int(pd_pc_sig)
            id_pc = _read_int(id_pc_sig)
            issue_pc = _read_int(issue_pc_sig) if _read_bool(issue_valid_sig) else None
            retire_pc = _read_int(retire_pc_sig) if _read_bool(retire_sig) else None
            if any(
                in_coremark_matrix_window(stage_pc)
                for stage_pc in (if_pc, pd_pc, id_pc, issue_pc, retire_pc)
            ):
                coremark_matrix_events.append(
                    f"cycle={cycle + 1} "
                    f"if={coremark_symbol_name_for_pc(if_pc)}:0x{(if_pc or 0):08x} "
                    f"nop={int(bool(_read_bool(if_sel_nop_sig)))} "
                    f"raw=0x{(_read_int(if_raw_parcel_sig) or 0):04x} "
                    f"pd={coremark_symbol_name_for_pc(pd_pc)}:0x{(pd_pc or 0):08x} "
                    f"insn=0x{(_read_int(pd_instr_sig) or 0):08x} "
                    f"id={coremark_symbol_name_for_pc(id_pc)}:0x{(id_pc or 0):08x} "
                    f"op={_read_int(id_op_sig)} "
                    f"issue_v={int(bool(_read_bool(issue_valid_sig)))} "
                    f"issue={coremark_symbol_name_for_pc(issue_pc)}:0x{(issue_pc or 0):08x} "
                    f"retire_v={int(bool(_read_bool(retire_sig)))} "
                    f"retire={coremark_symbol_name_for_pc(retire_pc)}:0x{(retire_pc or 0):08x} "
                    f"x10=0x{(last_x10_commit or 0):08x} "
                    f"x11=0x{(last_x11_commit or 0):08x}"
                )

        if (
            app_name == "ras_stress_test"
            and ras_transition_trace_active
            and _read_bool(issue_valid_sig)
            and _read_int(issue_pc_sig)
            in {
                0x3174,
                0x3176,
                0x317C,
                0x318E,
                0x3194,
                0x31C2,
                0x31CA,
                0x31DE,
                0x31F2,
                0x3204,
                0x3218,
                0x322C,
                0x3240,
                0x3254,
                0x3266,
                0x327A,
                0x3290,
                0x32A2,
                0x353C,
                0x3542,
                0x3552,
                0x3562,
                0x3572,
            }
            and len(special_issue_events) < special_issue_limit
        ):
            special_issue_events.append(
                "issue* "
                f"cycle={cycle + 1} "
                f"x2={last_x2_commit} "
                f"x5={last_x5_commit} "
                f"x8={last_x8_commit} "
                f"x9={last_x9_commit} "
                f"x10={last_x10_commit} "
                f"x11={last_x11_commit} "
                f"x19={last_x19_commit} "
                f"pc=0x{(_read_int(issue_pc_sig) or 0):08x} "
                f"src1=0x{(_read_int(issue_src1_sig) or 0):08x} "
                f"src2=0x{(_read_int(issue_src2_sig) or 0):08x} "
                f"pred_taken={_read_bool(issue_pred_taken_sig)}"
            )

        if app_name == "ras_stress_test" and _read_bool(btb_update_sig):
            update_pc = _read_int(btb_update_pc_sig)
            if update_pc in {
                0x3174,
                0x3176,
                0x317C,
                0x318E,
                0x3194,
                0x31C2,
                0x31CA,
                0x31DE,
                0x31F2,
                0x3204,
                0x3218,
                0x322C,
                0x3240,
                0x3254,
                0x3266,
                0x327A,
                0x3290,
                0x32A2,
                0x353C,
                0x3542,
                0x3546,
                0x3550,
                0x3552,
                0x3556,
                0x3558,
                0x3562,
            }:
                btb_update_events.append(
                    "btbupd* "
                    f"cycle={cycle + 1} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"pc=0x{(update_pc or 0):08x} "
                    f"tgt=0x{(_read_int(btb_update_target_sig) or 0):08x} "
                    f"taken={_read_bool(btb_update_taken_sig)} "
                    f"comp={_read_bool(btb_update_compressed_sig)}"
                )

        if (
            control_flow_trace_label is not None
            and control_flow_trace_enabled
            and ras_transition_trace_active
            and len(control_flow_debug_events) < control_flow_debug_limit
            and not retire_only_trace
        ):
            update_pc = _read_int(btb_update_pc_sig)
            if (
                app_name == "ras_stress_test"
                and _read_bool(btb_update_sig)
                and in_trace_window(update_pc)
            ):
                control_flow_debug_events.append(
                    "btbupd "
                    f"cycle={cycle + 1} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"pc=0x{(update_pc or 0):08x} "
                    f"tgt=0x{(_read_int(btb_update_target_sig) or 0):08x} "
                    f"taken={_read_bool(btb_update_taken_sig)} "
                    f"comp={_read_bool(btb_update_compressed_sig)}"
                )
            pc = _read_int(pc_sig)
            if in_trace_window(pc):
                control_flow_debug_events.append(
                    "fetch  "
                    f"cycle={cycle + 1} "
                    f"x2={last_x2_commit} "
                    f"x5={last_x5_commit} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"x10={last_x10_commit} "
                    f"x11={last_x11_commit} "
                    f"x19={last_x19_commit} "
                    f"fetch_pc=0x{pc:08x} "
                    f"pc_vld={_read_bool(pc_vld_sig)} "
                    f"if_pc=0x{(_read_int(if_pc_live_sig) or 0):08x} "
                    f"if_pc_reg=0x{(_read_int(if_pc_reg_live_sig) or 0):08x} "
                    f"raw=0x{(_read_int(if_raw_parcel_live_sig) or 0):04x} "
                    f"eff=0x{(_read_int(if_effective_instr_sig) or 0):08x} "
                    f"span_instr=0x{(_read_int(if_spanning_instr_live_sig) or 0):08x} "
                    f"sel_nop={_read_bool(if_sel_nop_live_sig)} "
                    f"sel_span={_read_bool(if_sel_spanning_live_sig)} "
                    f"sel_comp={_read_bool(if_sel_compressed_sig)} "
                    f"is_comp_pc={_read_bool(if_is_compressed_for_pc_sig)} "
                    f"is32span={_read_bool(if_is_32bit_spanning_sig)} "
                    f"span_wait={_read_bool(if_spanning_wait_sig)} "
                    f"span_run={_read_bool(if_spanning_in_progress_sig)} "
                    f"use_buf={_read_bool(if_use_instr_buffer_sig)} "
                    f"use_buf_pred={_read_bool(if_use_buffer_after_prediction_sig)} "
                    f"prev_lo={_read_bool(if_prev_compressed_lo_sig)} "
                    f"prev32={_read_bool(pc_prev_was_32bit_sig)} "
                    f"mid32={_read_bool(pc_mid_32bit_sig)} "
                    f"seq_next_pc_reg=0x{(_read_int(pc_seq_next_pc_reg_sig) or 0):08x} "
                    f"next_pc_reg=0x{(_read_int(pc_next_pc_reg_sig) or 0):08x} "
                    f"pred_off={_read_bool(branch_pred_off_sig)} "
                    f"fe_cf_pending={_read_bool(fe_cf_pending_sig)} "
                    f"stall={_read_bool(if_stall_sig)} "
                    f"stall_r={_read_bool(if_stall_registered_sig)} "
                    f"dispatch_stall={_read_bool(dispatch_stall_sig)} "
                    f"fe_ser_stall={_read_bool(front_end_cf_serialize_stall_sig)} "
                    f"stall_q={_read_bool(front_end_stall_q_sig)} "
                    f"replay_q={_read_bool(replay_after_dispatch_stall_q_sig)} "
                    f"br_inflight={_read_int(branch_in_flight_count_sig)} "
                    f"cf_hold={_read_bool(if_control_flow_holdoff_sig)} "
                    f"br_taken={_read_bool(branch_taken_live_sig)} "
                    f"br_target=0x{(_read_int(branch_target_live_sig) or 0):08x} "
                    f"btb_hit={_read_bool(btb_hit_sig)} "
                    f"btb_pred_taken={_read_bool(btb_pred_taken_sig)} "
                    f"pred_used={_read_bool(pred_used_sig)} "
                    f"pred_holdoff={_read_bool(pred_holdoff_sig)} "
                    f"pend_active={_read_bool(pending_prediction_active_sig)} "
                    f"pend_fetch_hold={_read_bool(pending_prediction_fetch_holdoff_sig)} "
                    f"if_ras={_read_bool(if_ras_pred_sig)} "
                    f"if_ckpt={_read_int(if_ras_ckpt_tos_sig)}/{_read_int(if_ras_ckpt_vc_sig)} "
                    f"pd_ckpt={_read_int(pd_ras_ckpt_tos_sig)}/{_read_int(pd_ras_ckpt_vc_sig)} "
                    f"id_ckpt={_read_int(id_ras_ckpt_tos_sig)}/{_read_int(id_ras_ckpt_vc_sig)} "
                    f"ras_call={_read_bool(ras_is_call_sig)} "
                    f"ras_ret={_read_bool(ras_is_return_sig)} "
                    f"ras_tgt=0x{(_read_int(ras_target_live_sig) or 0):08x} "
                    f"ras_tos={_read_int(ras_tos_sig)} "
                    f"ras_vc={_read_int(ras_valid_count_sig)} "
                    f"ras_do_pop={_read_bool(ras_do_pop_sig)} "
                    f"ras_do_push={_read_bool(ras_do_push_sig)} "
                    f"ras_cap={_read_bool(ras_capture_inputs_sig)} "
                    f"ras_wen={_read_bool(ras_write_enable_sig)} "
                    f"ras_wdata=0x{(_read_int(ras_write_data_sig) or 0):08x} "
                    f"link=0x{(_read_int(ras_link_address_sig) or 0):08x} "
                    f"ras_restore={_read_bool(ras_misprediction_live_sig)} "
                    f"ras_rt_tos={_read_int(ras_restore_tos_live_sig)} "
                    f"ras_rt_vc={_read_int(ras_restore_valid_count_live_sig)} "
                    f"ras_rt_pop={_read_bool(ras_pop_after_restore_live_sig)} "
                    f"commit_v={_read_bool(commit_valid_live_sig)} "
                    f"commit_pc=0x{(_read_int(commit_pc_live_sig) or 0):08x} "
                    f"commit_ret={_read_bool(commit_is_return_live_sig)} "
                    f"commit_call={_read_bool(commit_is_call_live_sig)} "
                    f"commit_ckpt={_read_int(commit_checkpoint_id_live_sig)} "
                    f"commit_has_ckpt={_read_bool(commit_has_checkpoint_live_sig)} "
                    f"commit_pred={_read_bool(commit_predicted_taken_live_sig)} "
                    f"commit_taken={_read_bool(commit_branch_taken_live_sig)} "
                    f"commit_misp={_read_bool(retire_mispredict_sig)} "
                    f"commit_mret={_read_bool(commit_is_mret_live_sig)} "
                    f"trap_pend={_read_bool(trap_pending_live_sig)} "
                    f"trap_pc=0x{(_read_int(rob_trap_pc_live_sig) or 0):08x} "
                    f"trap_cause=0x{(_read_int(rob_trap_cause_live_sig) or 0):08x} "
                    f"trap_taken={_read_bool(trap_taken_live_sig)} "
                    f"mret_start={_read_bool(mret_start_live_sig)} "
                    f"mret_taken={_read_bool(mret_taken_live_sig)} "
                    f"trap_tgt=0x{(_read_int(trap_target_live_sig) or 0):08x} "
                    f"csr_fire={_read_bool(csr_commit_fire_live_sig)} "
                    f"mtvec=0x{(_read_int(csr_mtvec_live_sig) or 0):08x} "
                    f"mepc=0x{(_read_int(csr_mepc_live_sig) or 0):08x} "
                    f"flush={_read_bool(flush_pipeline_live_sig)} "
                    f"commit_flush={_read_bool(commit_is_misprediction_live_sig)} "
                    f"pd_pc=0x{(_read_int(pd_program_counter_live_sig) or 0):08x} "
                    f"pd_instr=0x{(_read_int(pd_final_instruction_live_sig) or 0):08x} "
                    f"id_pc=0x{(_read_int(id_program_counter_live_sig) or 0):08x} "
                    f"id_instr=0x{(_read_int(id_instruction_live_sig) or 0):08x} "
                    f"id_mret={_read_bool(id_is_mret_live_sig)} "
                    f"if_v={_read_bool(if_valid_live_sig)} "
                    f"pd_v={_read_bool(pd_valid_live_sig)} "
                    f"id_v={_read_bool(id_valid_live_sig)} "
                    f"post_flush={_read_int(post_flush_holdoff_live_sig)} "
                    f"csr_in_flight={_read_bool(csr_in_flight_live_sig)} "
                    f"pipe_stall={_read_bool(pipeline_stall_live_sig)} "
                    f"pipe_stall_r={_read_bool(pipeline_stall_registered_live_sig)} "
                    f"alloc_v={_read_bool(rob_alloc_valid_live_sig)} "
                    f"alloc_pc=0x{(_read_int(rob_alloc_pc_live_sig) or 0):08x} "
                    f"alloc_csr={_read_bool(rob_alloc_is_csr_live_sig)} "
                    f"alloc_mret={_read_bool(rob_alloc_is_mret_live_sig)}"
                )
            if_pc = _read_int(if_pc_sig)
            if in_trace_window(if_pc):
                control_flow_debug_events.append(
                    "ifpd   "
                    f"cycle={cycle + 1} "
                    f"x2={last_x2_commit} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"x10={last_x10_commit} "
                    f"x19={last_x19_commit} "
                    f"if_pc=0x{if_pc:08x} "
                    f"sel_nop={_read_bool(if_sel_nop_sig)} "
                    f"raw=0x{(_read_int(if_raw_parcel_sig) or 0):04x} "
                    f"sel_span={_read_bool(if_sel_spanning_sig)} "
                    f"span_instr=0x{(_read_int(if_spanning_instr_sig) or 0):08x} "
                    f"ras={_read_bool(if_ras_pred_sig)}"
                )
            pd_pc = _read_int(pd_pc_sig)
            if in_trace_window(pd_pc):
                control_flow_debug_events.append(
                    "pdid   "
                    f"cycle={cycle + 1} "
                    f"x2={last_x2_commit} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"x10={last_x10_commit} "
                    f"x19={last_x19_commit} "
                    f"pd_pc=0x{pd_pc:08x} "
                    f"instr=0x{(_read_int(pd_instr_sig) or 0):08x} "
                    f"ras={_read_bool(pd_ras_pred_sig)}"
                )
            id_pc = _read_int(id_pc_sig)
            if in_trace_window(id_pc):
                control_flow_debug_events.append(
                    "id     "
                    f"cycle={cycle + 1} "
                    f"x2={last_x2_commit} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"x10={last_x10_commit} "
                    f"x19={last_x19_commit} "
                    f"id_pc=0x{id_pc:08x} "
                    f"op={_read_int(id_op_sig)} "
                    f"ras={_read_bool(id_ras_pred_sig)}"
                )
            issue_pc = _read_int(issue_pc_sig)
            if _read_bool(issue_valid_sig) and in_trace_window(issue_pc):
                control_flow_debug_events.append(
                    "issue  "
                    f"cycle={cycle + 1} "
                    f"x2={last_x2_commit} "
                    f"x8={last_x8_commit} "
                    f"x9={last_x9_commit} "
                    f"x10={last_x10_commit} "
                    f"x19={last_x19_commit} "
                    f"pc=0x{issue_pc:08x} "
                    f"src1=0x{(_read_int(issue_src1_sig) or 0):08x} "
                    f"src2=0x{(_read_int(issue_src2_sig) or 0):08x} "
                    f"pred_taken={_read_bool(issue_pred_taken_sig)}"
                )
        if progress_interval and (cycle + 1) % progress_interval == 0:
            pc = _read_int(pc_sig)
            pc_vld = _read_bool(pc_vld_sig)
            mem_rd_en = _read_bool(mem_rd_en_sig)
            mem_addr = _read_int(mem_addr_sig)
            mem_wr_en = _read_int(mem_wr_en_sig)
            sq_count = _read_int(sq_count_sig)
            sq_full = _read_bool(sq_full_sig)
            rob_count = _read_int(rob_count_sig)
            dispatch_stall = _read_bool(dispatch_stall_sig)
            branch_pred_off = _read_bool(branch_pred_off_sig)
            branch_in_flight_count = _read_int(branch_in_flight_count_sig)
            fe_cf_pending = _read_bool(fe_cf_pending_sig)
            lq_issue_mem_found = _read_bool(lq_issue_mem_found_sig)
            lq_sq_check_valid = _read_bool(lq_sq_check_valid_sig)
            lq_sq_can_issue = _read_bool(lq_sq_can_issue_sig)
            lq_sq_do_forward = _read_bool(lq_sq_do_forward_sig)
            lq_cache_hit_fast_path = _read_bool(lq_cache_hit_fast_path_sig)
            lq_mem_outstanding = _read_bool(lq_mem_outstanding_sig)
            cf_debug_suffix = ""
            if coremark_cf_debug_enabled:
                if_pc = _read_int(if_pc_sig)
                pd_pc = _read_int(pd_pc_sig)
                id_pc = _read_int(id_pc_sig)
                if_cf_pending = _read_bool(if_cf_pending_sig)
                pd_cf_pending = _read_bool(pd_cf_pending_sig)
                id_cf_pending = _read_bool(id_cf_pending_sig)
                if_btb_pred = _read_bool(if_btb_pred_sig)
                if_ras_pred = _read_bool(if_ras_pred_sig)
                pd_btb_pred = _read_bool(pd_btb_pred_sig)
                pd_ras_pred = _read_bool(pd_ras_pred_sig)
                id_btb_pred = _read_bool(id_btb_pred_sig)
                id_ras_pred = _read_bool(id_ras_pred_sig)
                pd_instr = _read_int(pd_instr_sig)
                id_op = _read_int(id_op_sig)
                cf_debug_suffix = (
                    f" if_cf_pending={if_cf_pending}"
                    f" pd_cf_pending={pd_cf_pending}"
                    f" id_cf_pending={id_cf_pending}"
                    f" if_pc=0x{(if_pc or 0):08x}"
                    f" pd_pc=0x{(pd_pc or 0):08x}"
                    f" id_pc=0x{(id_pc or 0):08x}"
                    f" if_btb={if_btb_pred}"
                    f" if_ras={if_ras_pred}"
                    f" pd_btb={pd_btb_pred}"
                    f" pd_ras={pd_ras_pred}"
                    f" id_btb={id_btb_pred}"
                    f" id_ras={id_ras_pred}"
                    f" pd_instr=0x{(pd_instr or 0):08x}"
                    f" id_op={id_op}"
                )
            cocotb.log.info(
                f"Run {run_number} coremark progress: cycle={cycle + 1} "
                f"retired={retired_count} "
                f"delta_retired={retired_count - last_progress_retired} "
                f"mispredicts={retired_mispredicts} "
                f"delta_mispredicts={retired_mispredicts - last_progress_mispredicts} "
                f"pc=0x{(pc or 0):08x} pc_vld={pc_vld} "
                f"mem_rd_en={mem_rd_en} mem_addr=0x{(mem_addr or 0):08x} "
                f"mem_wr_en=0x{(mem_wr_en or 0):x} "
                f"sq_count={sq_count} sq_full={sq_full} "
                f"rob_count={rob_count} dispatch_stall={dispatch_stall} "
                f"branch_pred_off={branch_pred_off} "
                f"branch_in_flight_count={branch_in_flight_count} "
                f"fe_cf_pending={fe_cf_pending} "
                f"lq_issue_mem_found={lq_issue_mem_found} "
                f"lq_sq_check_valid={lq_sq_check_valid} "
                f"lq_sq_can_issue={lq_sq_can_issue} "
                f"lq_sq_do_forward={lq_sq_do_forward} "
                f"lq_cache_hit_fast_path={lq_cache_hit_fast_path} "
                f"lq_mem_outstanding={lq_mem_outstanding}"
                f"{cf_debug_suffix}"
            )
            last_progress_retired = retired_count
            last_progress_mispredicts = retired_mispredicts

        # Check for failure marker (always a failure if seen)
        if uart_monitor.contains(FAIL_MARKER):
            cocotb.log.error(f"Run {run_number} FAILED: Program printed failure marker")
            test_failed = True
            break

        # Check for success condition
        if has_defined_endpoint:
            # Test suite: look for pass marker
            if success_marker and uart_monitor.contains(success_marker):
                cocotb.log.info(
                    f"Run {run_number} PASSED: Program printed success marker"
                )
                test_passed = True
                break
        else:
            # Open-ended test: look for initial text
            if initial_text and uart_monitor.contains(initial_text):
                cocotb.log.info(
                    f"Run {run_number} PASSED: Found expected text '{initial_text}'"
                )
                test_passed = True
                # Continue running a bit more to let output complete
                for _ in range(10000):
                    await RisingEdge(dut.i_clk)
                break

    # Print run summary
    dump_coremark_retire_trace()
    print("\n")  # Newline after UART output
    cocotb.log.info(f"Run {run_number} completed after {cycle + 1} cycles")

    # Check results
    if test_failed:
        if is_coremark_like and coremark_return_events:
            cocotb.log.error(
                "Coremark return trace:\n" + "\n".join(coremark_return_events)
            )
        if is_coremark_like and coremark_retire_trace_path is not None:
            cocotb.log.error(
                "Coremark retire samples captured for "
                + str(coremark_retire_trace_symbol)
                + ": "
                + str(len(coremark_matrix_retire_trace))
            )
        if is_coremark_like and coremark_matrix_events:
            cocotb.log.error(
                "Coremark matrix window trace:\n" + "\n".join(coremark_matrix_events)
            )
        cocotb.log.error(f"UART output:\n{uart_monitor.get_output()}")
        raise AssertionError(
            f"Run {run_number} failed: program printed <<FAIL>> marker"
        )

    if not test_passed:
        if is_coremark_like and retired_pc_hist:
            top_retired_pcs = ", ".join(
                f"0x{pc:08x}:{count}" for pc, count in retired_pc_hist.most_common(12)
            )
            cocotb.log.error(
                "Coremark retired PC histogram (top 12): " + top_retired_pcs
            )
        if control_flow_trace_label is not None and retired_pc_hist:
            top_retired_pcs = ", ".join(
                f"0x{pc:08x}:{count}" for pc, count in retired_pc_hist.most_common(12)
            )
            cocotb.log.error(
                f"{control_flow_trace_label} retired PC histogram (top 12): "
                + top_retired_pcs
            )
        if control_flow_trace_label is not None and control_flow_debug_events:
            cocotb.log.error(
                f"{control_flow_trace_label} loop trace:\n"
                + "\n".join(control_flow_debug_events)
            )
        if app_name == "ras_stress_test" and special_issue_events:
            cocotb.log.error(
                "RAS_stress_test special issue trace:\n"
                + "\n".join(special_issue_events)
            )
        if app_name == "ras_stress_test":
            if btb_update_events:
                cocotb.log.error(
                    "RAS_stress_test BTB update trace:\n" + "\n".join(btb_update_events)
                )
            cocotb.log.error(
                "RAS_stress_test last architectural commits: "
                f"x8/s0={last_x8_commit} x18/s2={last_x18_commit}"
            )
        cocotb.log.error(f"UART output:\n{uart_monitor.get_output()}")
        if has_defined_endpoint:
            raise AssertionError(
                f"Run {run_number} failed: program did not print success marker "
                f"'{success_marker}' within {max_cycles} cycles"
            )
        else:
            raise AssertionError(
                f"Run {run_number} failed: program did not print expected text "
                f"'{initial_text}' within {max_cycles} cycles"
            )


async def run_uart_echo_interaction(
    dut: Any,
    uart_monitor: UartMonitor,
    uart_driver: UartRxDriver,
    debug_monitor: UartMmioDebugMonitor | None,
    max_cycles: int,
    run_number: int,
) -> None:
    """Run uart_echo by injecting UART RX input and checking echoed response."""
    prompt = "frost> "
    test_line = "xyz"
    expected_echo = f"{prompt}{test_line}"
    expected_response = f'You typed: "{test_line}"'

    try:
        await wait_for_uart_text(
            dut, uart_monitor, prompt, max_cycles=max_cycles, start_index=0
        )
    except AssertionError:
        if debug_monitor:
            debug_monitor.dump_recent()
        raise

    send_idx = len(uart_monitor.get_output())
    if debug_monitor:
        debug_monitor.reset_events(reset_counts=True)
    await uart_driver.send((test_line + "\r").encode("ascii"))

    try:
        await wait_for_uart_text(
            dut, uart_monitor, expected_echo, max_cycles=max_cycles, start_index=0
        )
        await wait_for_uart_text(
            dut,
            uart_monitor,
            expected_response,
            max_cycles=max_cycles,
            start_index=send_idx,
        )
    except AssertionError:
        if debug_monitor:
            debug_monitor.dump_recent()
        raise

    cocotb.log.info(f"Run {run_number} PASSED: uart_echo echoed '{test_line}'")


@cocotb.test()
async def test_real_program(dut: Any) -> None:
    """Reset the system, run the program twice, and verify it completes successfully both times.

    The test monitors UART output and checks for success/failure markers.
    Different programs have different success criteria:
    - Test suites (isa_test, strings_test, etc.): Must print "<<PASS>>"
    - Hello World: Must print "Hello, world!"
    - CoreMark: Must print "Coremark" welcome message

    The program is run twice with a reset in between to verify that programs
    are robust to reset and all state is properly initialized.
    """
    # Start clocks
    cocotb.start_soon(Clock(dut.i_clk, CLK_PERIOD_NS, unit="ns").start())
    # Note: i_clk_div4 only exists in frost.sv, not cpu_tb.sv testbench
    # Use a proper divided clock generator to ensure fixed phase relationship
    # between clocks, which is required by the dc_fifo clock domain crossing logic
    if hasattr(dut, "i_clk_div4"):
        cocotb.start_soon(generate_divided_clock(dut))

    disable_branch_prediction = int(
        os.environ.get("FROST_DISABLE_BRANCH_PREDICTION", "0")
    )
    if hasattr(dut, "i_disable_branch_prediction"):
        dut.i_disable_branch_prediction.value = disable_branch_prediction
    elif hasattr(dut, "cpu_and_memory_subsystem") and hasattr(
        dut.cpu_and_memory_subsystem, "i_disable_branch_prediction"
    ):
        dut.cpu_and_memory_subsystem.i_disable_branch_prediction.value = (
            disable_branch_prediction
        )

    # Get expected behavior for this program
    success_marker, initial_text, has_defined_endpoint, app_name = (
        get_expected_behavior()
    )

    # Use longer timeout for tests that need more cycles
    if app_name == "coremark":
        max_cycles = COREMARK_MAX_CYCLES
    elif app_name == "sprintf_test":
        max_cycles = SPRINTF_TEST_MAX_CYCLES
    else:
        max_cycles = MAX_CYCLES

    cocotb.log.info(
        f"Expected behavior: success_marker={success_marker}, "
        f"initial_text={initial_text}, has_defined_endpoint={has_defined_endpoint}, "
        f"app_name={app_name}, max_cycles={max_cycles}"
    )

    # Start UART monitor (runs throughout both program executions)
    uart_monitor = UartMonitor(dut)
    await uart_monitor.start()
    uart_driver = None
    debug_monitor = None
    if app_name == "uart_echo":
        uart_driver = UartRxDriver(dut)
        debug_monitor = UartMmioDebugMonitor(dut)
        await debug_monitor.start()

    for run_number in range(1, NUM_RUNS + 1):
        if run_number > 1:
            # Reset between runs
            cocotb.log.info(f"=== Asserting reset for {RESET_CYCLES} cycles ===")
            uart_monitor.clear()
            dut.i_rst_n.value = 0
            if hasattr(dut, "i_uart_rx"):
                dut.i_uart_rx.value = 1
            for _ in range(RESET_CYCLES):
                await RisingEdge(dut.i_clk)
            dut.i_rst_n.value = 1
        else:
            # Apply initial reset
            dut.i_instr_mem_en.value = 0
            dut.i_rst_n.value = 0
            if hasattr(dut, "i_uart_rx"):
                dut.i_uart_rx.value = 1
            await Timer(2 * CLK_PERIOD_NS, unit="ns")
            await RisingEdge(dut.i_clk)
            dut.i_rst_n.value = 1

        cocotb.log.info(f"=== Starting run {run_number} of {NUM_RUNS} ===")

        # Run until pass/fail
        if app_name == "uart_echo":
            assert uart_driver is not None
            await run_uart_echo_interaction(
                dut,
                uart_monitor,
                uart_driver,
                debug_monitor,
                max_cycles,
                run_number=run_number,
            )
        else:
            await run_until_complete(
                dut,
                uart_monitor,
                success_marker,
                initial_text,
                has_defined_endpoint,
                max_cycles,
                run_number=run_number,
                app_name=app_name,
            )
        log_ras_stats(run_number, read_ras_stats(dut))

    # Stop UART monitor
    uart_monitor.stop()
    if debug_monitor:
        debug_monitor.stop()

    cocotb.log.info(f"=== All {NUM_RUNS} run(s) completed successfully ===")
