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
MAX_CYCLES = 500000

# Coremark needs more cycles since it runs the full benchmark even with ITERATIONS=1
COREMARK_MAX_CYCLES = 5000000

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

    for cycle in range(max_cycles):
        await RisingEdge(dut.i_clk)

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
    print("\n")  # Newline after UART output
    cocotb.log.info(f"Run {run_number} completed after {cycle + 1} cycles")

    # Check results
    if test_failed:
        cocotb.log.error(f"UART output:\n{uart_monitor.get_output()}")
        raise AssertionError(
            f"Run {run_number} failed: program printed <<FAIL>> marker"
        )

    if not test_passed:
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

    # Get expected behavior for this program
    success_marker, initial_text, has_defined_endpoint, app_name = (
        get_expected_behavior()
    )

    # Use longer timeout for coremark since it runs the full benchmark
    max_cycles = COREMARK_MAX_CYCLES if app_name == "coremark" else MAX_CYCLES

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

    # === First run ===
    cocotb.log.info("=== Starting first run ===")

    # Apply initial reset
    dut.i_instr_mem_en.value = 0
    dut.i_rst_n.value = 0
    if hasattr(dut, "i_uart_rx"):
        dut.i_uart_rx.value = 1
    await Timer(2 * CLK_PERIOD_NS, unit="ns")
    await RisingEdge(dut.i_clk)
    dut.i_rst_n.value = 1

    # Run until pass/fail
    if app_name == "uart_echo":
        assert uart_driver is not None
        await run_uart_echo_interaction(
            dut, uart_monitor, uart_driver, debug_monitor, max_cycles, run_number=1
        )
    else:
        await run_until_complete(
            dut,
            uart_monitor,
            success_marker,
            initial_text,
            has_defined_endpoint,
            max_cycles,
            run_number=1,
        )
    log_ras_stats(1, read_ras_stats(dut))

    # === Reset between runs ===
    cocotb.log.info(f"=== Asserting reset for {RESET_CYCLES} cycles ===")
    uart_monitor.clear()
    dut.i_rst_n.value = 0
    if hasattr(dut, "i_uart_rx"):
        dut.i_uart_rx.value = 1
    for _ in range(RESET_CYCLES):
        await RisingEdge(dut.i_clk)
    dut.i_rst_n.value = 1

    # === Second run ===
    cocotb.log.info("=== Starting second run ===")

    # Run until pass/fail again
    if app_name == "uart_echo":
        assert uart_driver is not None
        await run_uart_echo_interaction(
            dut, uart_monitor, uart_driver, debug_monitor, max_cycles, run_number=2
        )
    else:
        await run_until_complete(
            dut,
            uart_monitor,
            success_marker,
            initial_text,
            has_defined_endpoint,
            max_cycles,
            run_number=2,
        )
    log_ras_stats(2, read_ras_stats(dut))

    # Stop UART monitor
    uart_monitor.stop()
    if debug_monitor:
        debug_monitor.stop()

    cocotb.log.info("=== Both runs completed successfully ===")
