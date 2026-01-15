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

# Success/failure markers that programs print
PASS_MARKER = "<<PASS>>"
FAIL_MARKER = "<<FAIL>>"

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


def _read_u64(signal: Any) -> int | None:
    """Read a 64-bit counter from a cocotb signal, return None if not resolvable."""
    try:
        value = signal.value
    except AttributeError:
        return None
    if value.is_resolvable:
        return int(value)
    return None


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
    if hasattr(dut, "i_clk_div4"):
        cocotb.start_soon(Clock(dut.i_clk_div4, CLK_PERIOD_NS * 4, unit="ns").start())

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

    # === First run ===
    cocotb.log.info("=== Starting first run ===")

    # Apply initial reset
    dut.i_instr_mem_en.value = 0
    dut.i_rst_n.value = 0
    await Timer(2 * CLK_PERIOD_NS, unit="ns")
    await RisingEdge(dut.i_clk)
    dut.i_rst_n.value = 1

    # Run until pass/fail
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
    for _ in range(RESET_CYCLES):
        await RisingEdge(dut.i_clk)
    dut.i_rst_n.value = 1

    # === Second run ===
    cocotb.log.info("=== Starting second run ===")

    # Run until pass/fail again
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

    cocotb.log.info("=== Both runs completed successfully ===")
