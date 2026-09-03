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

"""Shared test configuration, pipeline, and commit-wait helpers.

Contents:
    TestConfig: Dataclass for test configuration parameters
    handle_branch_flush: Handle pipeline flush after taken branches
    flush_remaining_outputs: Drain pipeline after test completion
    warmup_pipeline: Feed PIPELINE_DEPTH NOPs before the first checked output
    execute_nop: Execute a NOP instruction and model its effects
    drive_nops_until: Event-based wait (OOO retirement is not fixed-latency)
    rob_commit_writes_int_reg: Commit-bus probe for a specific x-register write
    wait_for_int_reg_commit: Wait until an instruction writing x<reg> retires

Usage::

    from cocotb_tests.test_common import (
        TestConfig,
        handle_branch_flush,
        flush_remaining_outputs,
        execute_nop,
    )
"""

import cocotb
from cocotb.triggers import RisingEdge, FallingEdge
from dataclasses import dataclass
from typing import Any

from config import (
    MASK32,
    NOP_INSTRUCTION,
    DEFAULT_NUM_TEST_LOOPS,
    DEFAULT_MIN_COVERAGE_COUNT,
    DEFAULT_MEMORY_INIT_SIZE,
    DEFAULT_CLOCK_PERIOD_NS,
    DEFAULT_RESET_CYCLES,
    PIPELINE_DEPTH,
    PIPELINE_FLUSH_CYCLES,
)
from cocotb_tests.test_state import TestState
from cocotb_tests.test_helpers import DUTInterface


@dataclass
class TestConfig:
    """Per-test configuration, passed explicitly rather than through globals.

    Basic Parameters:
        num_loops: How many random instructions to generate and test
        min_coverage_count: Minimum executions required per instruction type
        memory_init_size: Size of initialized memory region (in bytes)
        clock_period_ns: Clock period for simulation
        reset_cycles: How many clock cycles to hold reset

    Advanced Options:
        use_structured_logging: When True, log the PC flow, register updates
            and memory ops in a formatted form for debugging a failure; when
            False, use the standard (less verbose) cocotb logging.

        constrain_addresses_to_memory: When True, keep generated addresses in
            [0, memory_init_size) so the allocated memory gets exercised; when
            False, addresses can fall anywhere in the 32-bit space, and many
            are out of range.

        force_one_address: If True, use rs1=0 and imm=0 so every access hits
            one address, which stresses memory hazards and cache behavior.

        compressed_ratio: Fraction (0.0-1.0) of compressed (C extension)
            instructions. 0.0 (the default) generates only 32-bit
            instructions; above 0 mixes in 16-bit ones, which advance the PC
            by 2 instead of 4. Only ALU compressed instructions are used, no
            branches or jumps.
    """

    num_loops: int = DEFAULT_NUM_TEST_LOOPS
    min_coverage_count: int = DEFAULT_MIN_COVERAGE_COUNT
    memory_init_size: int = DEFAULT_MEMORY_INIT_SIZE
    clock_period_ns: int = DEFAULT_CLOCK_PERIOD_NS
    reset_cycles: int = DEFAULT_RESET_CYCLES
    use_structured_logging: bool = False
    constrain_addresses_to_memory: bool = False
    force_one_address: bool = False
    compressed_ratio: float = 0.0


def handle_branch_flush(
    state: TestState, operation: str
) -> tuple[str, int, int, int, int]:
    """Handle branch flush by inserting NOP (addi x0, x0, 0).

    A taken branch flushes the pipeline: the instructions fetched after it
    are discarded. The model stands in for them with a NOP, which adds 0 to
    x0, writes the hardwired-zero x0, and advances the PC by 4.

    Pipeline Flush State Machine:
        ┌─────────────────────────────────────────────────────────────┐
        │ Branch/jump taken in EX stage                               │
        │                                                             │
        │ Cycle 0: branch_taken_current = True   → Insert NOP         │
        │ Cycle 1: branch_taken_previous = True  → Insert NOP         │
        │ Cycle 2: branch_taken_two_cycles_ago   → Insert NOP         │
        │ Cycle 3: All flags cleared             → Resume normal ops  │
        └─────────────────────────────────────────────────────────────┘

    This reference model treats all branches and jumps (JAL, JALR,
    conditional branches) as resolving at EX with a 3-cycle flush. The CPU
    predicts branches and its flush timing varies, but the monitors'
    expected-value queues line up with this simplified model.

    Args:
        state: Test state to update branch tracking
        operation: Previous operation type (unused, kept for API compatibility)

    Returns:
        Tuple of (operation, rd, rs1, rs2, imm) representing a NOP
    """
    # Shift the branch-taken and JAL flags through the model's three flush
    # slots.
    state.advance_branch_state()

    return "addi", 0, 0, 0, 0  # operation, rd, rs1, rs2, imm


async def flush_remaining_outputs(
    dut: Any,
    state: TestState,
    dut_if: DUTInterface | None = None,
) -> None:
    """Flush remaining expected outputs through the pipeline.

    When the main test loop ends, instructions are still in the pipeline.
    This waits for them to drain so the monitors can check them.

    The PC monitor sees output earlier than the register file monitor
    because of pipeline staging, so the PC queue is padded with sequential
    values for the instructions still in flight.

    Args:
        dut: Device under test
        state: Test state with expected value queues
        dut_if: Optional DUT interface (for cleaner signal access)
    """
    # Pad the PC queue for the instructions still in the pipeline.
    for _ in range(PIPELINE_FLUSH_CYCLES):
        expected_pc = (state.program_counter_current + 4) & MASK32
        state.program_counter_expected_values_queue.append(expected_pc)
        state.program_counter_current += 4

    # The monitors pop these queues as the hardware produces valid outputs.
    while state.has_pending_expectations():
        if dut_if:
            await RisingEdge(dut_if.clock)
        else:
            await RisingEdge(dut.i_clk)
        cocotb.log.info(
            f"len(register_file_expected_values_queue) is {len(state.register_file_current_expected_queue)}"
        )


async def warmup_pipeline(
    dut_if: DUTInterface, state: TestState, enable_fp: bool = False
) -> None:
    """Fill the pipeline with NOPs to synchronize expected value queues.

    Queues expected values for the first PIPELINE_DEPTH cycles, before o_vld
    starts firing, and drives NOPs so the initial state is predictable.

    Args:
        dut_if: DUT interface for signal access
        state: Test state for tracking expectations
        enable_fp: If True, also queue FP register file expectations
    """
    cocotb.log.info(f"=== Warming up pipeline ({PIPELINE_DEPTH} NOPs) ===")
    for warmup_cycle in range(PIPELINE_DEPTH):
        expected_pc = (state.program_counter_current + 4) & MASK32
        state.queue_expected_outputs(expected_pc, include_fp=enable_fp)

        dut_if.instruction = NOP_INSTRUCTION

        await RisingEdge(dut_if.clock)
        state.increment_cycle_counter()
        state.increment_instret_counter()

        state.update_program_counter(expected_pc)
        state.advance_register_state()

        cocotb.log.info(
            f"Warmup NOP {warmup_cycle}: pc_cur={state.program_counter_current}"
        )


# Cycle budget for event-based waits in directed tests. Hitting it means the
# DUT never produced the awaited architectural effect (an instruction that
# never retired, for example). That is a hard failure; do not raise the
# budget to make it go away.
EVENT_WAIT_BUDGET_CYCLES = 300


def rob_commit_writes_int_reg(dut: Any, reg: int) -> bool:
    """Return True when the registered ROB commit bus is retiring a write to x<reg>.

    Checks both slots of the 2-wide commit. The registered commit bus
    (dbg_rob_commit_reg_* / dbg_rob_commit_2_reg_* debug taps on cpu_ooo) is
    what drives the architectural regfile write ports, so a hit here means the
    regfile write lands on the next rising edge.

    Args:
        dut: cpu_tb toplevel handle (probes dut.device_under_test)
        reg: Architectural integer register index being watched (1-31)
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
    """Feed NOPs and sample ``done()`` once per clock cycle until it holds.

    The cpu_ooo core retires instructions at ROB commit, a variable number of
    cycles after the cpu_tb harness feeds them (longer still for serialized
    ops like LR/SC/AMO/CSR), so directed tests must wait for the architectural
    effect instead of counting a fixed in-order pipeline depth.

    Unlike execute_nop(), this samples every clock cycle, including front-end
    stall cycles where no new NOP is consumed, so a single-cycle event such
    as the registered commit-bus pulse cannot be missed.

    Args:
        dut_if: DUT interface for signal access
        state: Test state (cycle counter kept in sync)
        done: Zero-argument callable sampled after each rising edge
        what: Description of the awaited event (for the timeout error)
        budget: Maximum cycles to wait before failing the test

    Raises:
        AssertionError: If ``done()`` never holds within ``budget`` cycles.
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
    """Execute a NOP instruction (addi x0, x0, 0).

    Used for pipeline warmup, for padding during branch-flush recovery, and
    for waiting while pipeline effects propagate. The NOP reads x0, adds 0,
    writes the hardwired-zero x0 (no effect), and advances the PC by 4.

    Args:
        dut_if: DUT interface for signal access
        state: Test state for tracking expectations
        log_instr: If True, log the NOP execution for debugging
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
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)

    dut_if.instruction = instr
    await RisingEdge(dut_if.clock)

    state.increment_cycle_counter()
    state.increment_instret_counter()
    state.update_program_counter(expected_pc)
