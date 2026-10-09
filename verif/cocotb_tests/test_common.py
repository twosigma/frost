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

"""Shared configuration, instruction-driving, and commit-wait helpers.

Use event-based waits for OOO retirement. ``TestConfig`` holds the per-test
settings; ``DUTSignalPaths`` in config.py controls hierarchy access.
"""

import cocotb
from cocotb.triggers import RisingEdge, FallingEdge
from dataclasses import dataclass
from typing import Any

from config import (
    MASK_XLEN,
    NOP_INSTRUCTION,
    DEFAULT_NUM_TEST_LOOPS,
    DEFAULT_MIN_COVERAGE_COUNT,
    DEFAULT_CLOCK_PERIOD_NS,
    DEFAULT_RESET_CYCLES,
)
from cocotb_tests.test_state import TestState
from cocotb_tests.test_helpers import DUTInterface


@dataclass
class TestConfig:
    """Per-test configuration, passed explicitly rather than through globals.

    Attributes:
        num_loops: How many instructions a randomized test runs
        min_coverage_count: Minimum executions required per instruction type
        clock_period_ns: Clock period for simulation
        reset_cycles: How many clock cycles to hold reset
    """

    num_loops: int = DEFAULT_NUM_TEST_LOOPS
    min_coverage_count: int = DEFAULT_MIN_COVERAGE_COUNT
    clock_period_ns: int = DEFAULT_CLOCK_PERIOD_NS
    reset_cycles: int = DEFAULT_RESET_CYCLES


# Timeout for architectural effects such as retirement. A timeout is a
# failure to investigate, not a reason to increase the budget.
EVENT_WAIT_BUDGET_CYCLES = 300


def rob_commit_writes_int_reg(dut: Any, reg: int) -> bool:
    """Return whether either registered commit slot writes integer register reg.

    reg is an architectural index in 1-31. Probe cpu_tb.device_under_test's
    registered commit taps, which drive the regfile ports: a match means
    the write lands on the next rising edge.
    """
    d = dut.device_under_test
    for prefix in ("dbg_rob_commit_reg", "dbg_rob_commit_2_reg"):
        if (
            int(getattr(d, f"{prefix}_valid").value)
            and int(getattr(d, f"{prefix}_dest_valid").value)
            and int(getattr(d, f"{prefix}_dest_rf").value) == 0  # 0=INT, 1=FP
            and int(getattr(d, f"{prefix}_dest_reg").value) == reg
        ):
            return True
    return False


async def drive_nops_until(
    dut_if: DUTInterface,
    state: TestState,
    done: Any,
    what: str,
    budget: int = EVENT_WAIT_BUDGET_CYCLES,
) -> None:
    """Feed NOPs and check done() after every rising edge, including stalls.

    OOO retirement has variable latency. Sampling every edge prevents missing
    a one-cycle commit pulse while the front end is stalled. Update state's
    cycle count and raise AssertionError with what if budget cycles expire.
    """
    for _ in range(budget):
        await FallingEdge(dut_if.clock)
        if dut_if.is_ready():
            dut_if.instruction = NOP_INSTRUCTION
        await RisingEdge(dut_if.clock)
        state.increment_cycle_counter()
        if done():
            return
    raise AssertionError(f"Timed out after {budget} cycles waiting for {what}")


async def wait_for_int_reg_commit(
    dut: Any,
    dut_if: DUTInterface,
    state: TestState,
    reg: int,
    what: str,
    budget: int = EVENT_WAIT_BUDGET_CYCLES,
) -> None:
    """Wait until the DUT commits an instruction that writes x<reg>.

    After the commit-bus hit, pads two more NOPs so the architectural regfile
    write (one edge behind the registered commit bus) has landed before the
    caller does a backdoor read_register() check.
    """
    await drive_nops_until(
        dut_if, state, lambda: rob_commit_writes_int_reg(dut, reg), what, budget
    )
    for _ in range(2):
        await execute_nop(dut_if, state)


async def execute_nop(
    dut_if: DUTInterface, state: TestState, log_instr: bool = False
) -> None:
    """Issue ADDI x0, x0, 0 and advance the reference PC by four bytes.

    Queue the unchanged register state. log_instr enables diagnostic logging.
    """
    from encoders.op_tables import I_ALU

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()

    enc_addi, _ = I_ALU["addi"]
    instr = enc_addi(0, 0, 0)  # NOP

    queue_len = len(state.register_file_current_expected_queue)
    if log_instr:
        cocotb.log.info(f"NOP: queue len before={queue_len}")

    # Queue expected outputs (no register change)
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK_XLEN
    state.program_counter_expected_values_queue.append(expected_pc)

    dut_if.instruction = instr
    await RisingEdge(dut_if.clock)

    state.increment_cycle_counter()
    state.increment_instret_counter()
    state.update_program_counter(expected_pc)
