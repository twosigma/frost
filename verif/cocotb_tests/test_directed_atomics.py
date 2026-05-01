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

"""Directed tests for A extension atomic memory operations (LR.W, SC.W).

Directed Atomics Tests
======================

This module contains directed tests for the atomic memory operation instructions
(LR.W and SC.W) that are part of the RISC-V A extension. These instructions
are tested separately from the random regression because:

1. LR/SC behavior is stateful (reservation register)
2. SC success/failure depends on prior LR and intervening operations
3. Random testing cannot easily exercise the reservation protocol

Test Cases:
    1. LR.W + SC.W success: Load-reserved then store-conditional to same address
    2. SC.W without LR.W: Should fail (no reservation)
    3. SC.W to wrong address: LR to addr A, SC to addr B (should fail)
    4. Back-to-back LR.W/SC.W: Tests pipeline forwarding of reservation
    5. LR.W + intervening ops + SC.W: Reservation should persist through NOPs

LR/SC Protocol:
    ┌────────────────────────────────────────────────────────────────┐
    │ LR.W rd, (rs1)                                                 │
    │   - Load word from memory[rs1] into rd                         │
    │   - Set reservation register to rs1 address                    │
    │                                                                │
    │ SC.W rd, rs2, (rs1)                                            │
    │   - If reservation matches rs1 address:                        │
    │       - Store rs2 to memory[rs1]                               │
    │       - Write 0 to rd (success)                                │
    │   - Else:                                                      │
    │       - Do not store                                           │
    │       - Write 1 to rd (failure)                                │
    │   - Clear reservation in either case                           │
    └────────────────────────────────────────────────────────────────┘

Usage:
    make test TEST=test_directed_lr_sc
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from typing import Any

from config import MASK32, PIPELINE_DEPTH
from models.memory_model import MemoryModel
from cocotb_tests.test_helpers import DUTInterface
from cocotb_tests.test_state import TestState
from cocotb_tests.test_common import TestConfig, execute_nop


async def execute_lr_sc_instruction(
    dut_if: DUTInterface,
    state: TestState,
    mem_model: MemoryModel,
    operation: str,
    rd: int,
    rs1: int,
    rs2: int,
    expected_rd_value: int,
    expected_sc_success: bool | None,
) -> None:
    """Execute a single LR.W or SC.W instruction and model its effects.

    This function encapsulates the full execute-and-model pattern for atomic
    memory operations:
    1. Wait for DUT to be ready
    2. Encode the instruction
    3. Model expected behavior (load/store, reservation handling)
    4. Queue expected values for monitors
    5. Drive instruction and advance state

    Args:
        dut_if: DUT interface for signal access
        state: Test state for tracking expectations
        mem_model: Memory model for load/store operations
        operation: "lr.w" or "sc.w"
        rd: Destination register
        rs1: Address register
        rs2: Data register (for SC.W, ignored for LR.W)
        expected_rd_value: Expected value written to rd
        expected_sc_success: For SC.W, whether it should succeed (None for LR.W)
    """
    from encoders.op_tables import AMO_LR_SC

    # Wait for DUT ready
    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()

    # Encode instruction
    encoder = AMO_LR_SC[operation]
    if operation == "lr.w":
        instr = encoder(rd, rs1)
    else:
        instr = encoder(rd, rs2, rs1)

    # Model expected behavior
    address = state.register_file_previous[rs1] & ~0x3  # Word-aligned

    queue_len = len(state.register_file_current_expected_queue)

    if operation == "lr.w":
        # LR.W: load from memory, set reservation
        mem_model.read_address = address
        state.set_reservation(address)
        writeback_value = expected_rd_value
        cocotb.log.info(
            f"LR.W x{rd}, (x{rs1}): addr=0x{address:08X}, "
            f"loaded=0x{writeback_value:08X}, reservation set, queue_before={queue_len}, "
            f"instr=0x{instr:08X}"
        )
    else:
        # SC.W: check reservation, conditionally store
        success = state.check_reservation(address)
        state.clear_reservation()
        writeback_value = 0 if success else 1

        if success:
            # Model memory write
            write_data = state.register_file_previous[rs2]
            state.memory_write_address_expected_queue.append(address)
            state.memory_write_data_expected_queue.append(write_data)
            mem_model.write_word(address, write_data)
            cocotb.log.info(
                f"SC.W x{rd}, x{rs2}, (x{rs1}): addr=0x{address:08X}, "
                f"data=0x{write_data:08X}, SUCCESS (rd=0)"
            )
        else:
            cocotb.log.info(
                f"SC.W x{rd}, x{rs2}, (x{rs1}): addr=0x{address:08X}, "
                f"FAILED (rd=1, no write)"
            )

        # Track SC result for verification
        state.last_sc_succeeded = success
        state.last_sc_address = address
        state.last_sc_data = state.register_file_previous[rs2]

    # Update register file model
    if rd != 0:
        state.register_file_current[rd] = writeback_value & MASK32

    # Queue expected outputs
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)

    # Drive instruction
    dut_if.instruction = instr
    await RisingEdge(dut_if.clock)

    # Advance state
    state.increment_cycle_counter()
    state.increment_instret_counter()
    state.update_program_counter(expected_pc)
    state.advance_register_state()


async def execute_store(
    dut_if: DUTInterface,
    state: TestState,
    mem_model: MemoryModel,
    rs1: int,
    rs2: int,
    imm: int = 0,
) -> None:
    """Execute a SW (store word) instruction.

    Used by directed tests to initialize memory before testing LR/SC sequences.

    Args:
        dut_if: DUT interface for signal access
        state: Test state for tracking expectations
        mem_model: Memory model for store operations
        rs1: Base address register
        rs2: Data register
        imm: Immediate offset (default 0)
    """
    from encoders.op_tables import STORES

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()

    enc_sw = STORES["sw"]
    instr = enc_sw(rs2, rs1, imm)

    # Model memory write
    address = (state.register_file_previous[rs1] + imm) & MASK32
    write_data = state.register_file_previous[rs2] & MASK32

    # Queue expected memory write
    state.memory_write_address_expected_queue.append(address)
    state.memory_write_data_expected_queue.append(write_data)

    # Update software memory model
    mem_model.write_word(address, write_data)

    cocotb.log.info(
        f"SW x{rs2}, {imm}(x{rs1}): addr=0x{address:08X}, data=0x{write_data:08X}"
    )

    # Queue expected outputs (no register change for store)
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
    state.advance_register_state()


async def run_directed_lr_sc_test(dut: Any, config: TestConfig | None = None) -> None:
    """Directed test for LR.W (load-reserved) and SC.W (store-conditional).

    This test exercises the atomic memory operation instructions that are
    excluded from random testing due to their stateful nature. LR.W sets
    a reservation on a memory address, and SC.W conditionally stores only
    if the reservation is still valid.

    Test Cases:
        1. LR.W + SC.W success: Load-reserved then store-conditional to same address
        2. SC.W without LR.W: Should fail (no reservation)
        3. SC.W to wrong address: Load-reserved to addr A, SC to addr B (should fail)
        4. Back-to-back LR.W/SC.W: Tests pipeline forwarding
        5. LR.W + intervening ops + SC.W: Reservation should persist

    Args:
        dut: Device under test (cocotb SimHandle)
        config: Test configuration. If None, uses default configuration.
    """
    if config is None:
        config = TestConfig(num_loops=100)  # Shorter test for directed cases

    # ========================================================================
    # Initialization Phase
    # ========================================================================
    dut_if = DUTInterface(dut)
    state = TestState()

    # Initialize DUT signals
    dut_if.instruction = 0x00000013  # 32-bit NOP (addi x0, x0, 0)

    # Set up specific register values for testing
    # Use word-aligned addresses in the initialized memory region
    test_address_1 = 0x100  # First test address
    test_address_2 = 0x200  # Second test address (for mismatch test)
    test_data = 0xDEADBEEF

    # Set up specific register values for testing
    # All registers get set to their final test values BEFORE queueing expected values
    test_value_1 = 0x12345678  # Initial value for addr1
    test_value_2 = 0x87654321  # Initial value for addr2

    # Initialize all registers to known values (not random for directed test)
    state.register_file_current = [0] * 32
    for i in range(1, 32):
        state.register_file_current[i] = (i * 0x01010101) & MASK32  # Predictable values

    # Store test-specific values in registers
    state.register_file_current[10] = test_address_1  # x10 = addr1
    state.register_file_current[11] = test_address_2  # x11 = addr2
    state.register_file_current[12] = test_data  # x12 = data to store
    state.register_file_current[20] = test_value_1  # x20 = initial value for addr1
    state.register_file_current[21] = test_value_2  # x21 = initial value for addr2

    # Write ALL register values to DUT at once
    for i in range(1, 32):
        dut_if.write_register(i, state.register_file_current[i])

    # Start clock
    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())

    # Note: Monitors are intentionally NOT started for directed tests.
    # The monitor infrastructure assumes steady-state instruction flow where
    # expected values are queued at the same rate o_vld fires. Directed tests
    # with explicit waits/checks don't maintain this steady state.
    # Instead, we use explicit verification after each instruction sequence.

    # Reset DUT
    reset_cycle_count = await dut_if.reset_dut(config.reset_cycles)
    state.csr_cycle_counter = reset_cycle_count - config.reset_cycles

    # Initialize memory model
    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    # Initialize register file history used by the monitor alignment model.
    state.register_file_previous = state.register_file_current.copy()

    # ========================================================================
    # Warmup: Let pipeline drain and sync expected queues
    # ========================================================================
    cocotb.log.info("=== Warming up pipeline ===")
    for i in range(8):  # More than pipeline depth to ensure sync
        cocotb.log.info(
            f"Warmup NOP {i}: queue_len={len(state.register_file_current_expected_queue)}"
        )
        await execute_nop(dut_if, state)

    # ========================================================================
    # Initialize DUT memory by performing stores
    # ========================================================================
    cocotb.log.info("=== Initializing memory via store instructions ===")

    # SW x20, 0(x10) - store test_value_1 to test_address_1
    await execute_store(dut_if, state, mem_model, rs1=10, rs2=20)
    # SW x21, 0(x11) - store test_value_2 to test_address_2
    await execute_store(dut_if, state, mem_model, rs1=11, rs2=21)

    # Wait for stores to complete through pipeline before reading
    cocotb.log.info("=== Waiting for stores to complete ===")
    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)

    # Debug: Check what's in the DUT's memory after stores
    word_addr_1 = test_address_1 >> 2  # Convert byte address to word address
    word_addr_2 = test_address_2 >> 2
    try:
        mem_val_1 = int(dut.data_memory_for_simulation.memory[word_addr_1].value)
        mem_val_2 = int(dut.data_memory_for_simulation.memory[word_addr_2].value)
        cocotb.log.info(
            f"DEBUG: DUT memory[{word_addr_1}] (addr 0x{test_address_1:08X}) = 0x{mem_val_1:08X}"
        )
        cocotb.log.info(
            f"DEBUG: DUT memory[{word_addr_2}] (addr 0x{test_address_2:08X}) = 0x{mem_val_2:08X}"
        )
    except Exception as e:
        cocotb.log.warning(f"DEBUG: Could not read DUT memory: {e}")

    # ========================================================================
    # Test Case 1: LR.W + SC.W Success (same address)
    # ========================================================================
    cocotb.log.info("=== Test Case 1: LR.W + SC.W to same address (should succeed) ===")

    # Drive LR.W x5, (x10) - load from test_address_1, set reservation
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="lr.w",
        rd=5,
        rs1=10,
        rs2=0,
        expected_rd_value=0x12345678,  # Value at test_address_1
        expected_sc_success=None,  # N/A for LR.W
    )

    # Wait for LR.W to complete through pipeline
    for _ in range(PIPELINE_DEPTH + 4):
        await execute_nop(dut_if, state)

    # Check x5 after LR.W
    x5_value = dut_if.read_register(5)
    cocotb.log.info(
        f"DEBUG: After LR.W + NOPs, x5 = 0x{x5_value:08X} (expected 0x12345678)"
    )
    assert (
        x5_value == 0x12345678
    ), f"LR.W failed: x5 = 0x{x5_value:08X}, expected 0x12345678"
    cocotb.log.info("=== LR.W TEST PASSED! ===")

    # Drive SC.W x6, x12, (x10) - store test_data to test_address_1
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="sc.w",
        rd=6,
        rs1=10,
        rs2=12,
        expected_rd_value=0,  # 0 = success
        expected_sc_success=True,
    )

    # Verify SC.W result after pipeline flush
    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)
    x6_value = dut_if.read_register(6)
    assert (
        x6_value == 0
    ), f"SC.W Test Case 1 failed: x6 = {x6_value}, expected 0 (success)"
    cocotb.log.info(f"SC.W x6 = {x6_value} (success)")

    # ========================================================================
    # Test Case 2: SC.W without LR.W (should fail)
    # ========================================================================
    cocotb.log.info("=== Test Case 2: SC.W without LR.W (should fail) ===")

    # SC.W x7, x12, (x10) - no reservation, should fail
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="sc.w",
        rd=7,
        rs1=10,
        rs2=12,
        expected_rd_value=1,  # 1 = failure
        expected_sc_success=False,
    )

    # Verify SC.W failure
    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)
    x7_value = dut_if.read_register(7)
    assert (
        x7_value == 1
    ), f"SC.W Test Case 2 failed: x7 = {x7_value}, expected 1 (failure)"
    cocotb.log.info(f"SC.W x7 = {x7_value} (failed as expected)")

    # ========================================================================
    # Test Case 3: LR.W + SC.W to different address (should fail)
    # ========================================================================
    cocotb.log.info("=== Test Case 3: LR.W addr1, SC.W addr2 (should fail) ===")

    # LR.W x8, (x10) - load from test_address_1
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="lr.w",
        rd=8,
        rs1=10,
        rs2=0,
        expected_rd_value=test_data,  # Value stored by Test Case 1
        expected_sc_success=None,
    )

    # SC.W x9, x12, (x11) - try to store to test_address_2 (wrong address!)
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="sc.w",
        rd=9,
        rs1=11,
        rs2=12,  # x11 = addr2, different from LR's x10
        expected_rd_value=1,  # 1 = failure (address mismatch)
        expected_sc_success=False,
    )

    # Verify SC.W failure due to address mismatch
    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)
    x9_value = dut_if.read_register(9)
    assert (
        x9_value == 1
    ), f"SC.W Test Case 3 failed: x9 = {x9_value}, expected 1 (failure)"
    cocotb.log.info(f"SC.W x9 = {x9_value} (failed due to address mismatch)")

    # ========================================================================
    # Test Case 4: Back-to-back LR.W/SC.W (pipeline forwarding test)
    # ========================================================================
    cocotb.log.info("=== Test Case 4: Back-to-back LR.W/SC.W (pipeline test) ===")

    # This tests the forwarding logic for LR in MA stage when SC is in EX stage
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="lr.w",
        rd=13,
        rs1=11,
        rs2=0,  # LR from addr2
        expected_rd_value=0x87654321,  # Original value at addr2
        expected_sc_success=None,
    )

    # Immediately follow with SC.W to same address
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="sc.w",
        rd=14,
        rs1=11,
        rs2=12,  # SC to addr2 (same as LR)
        expected_rd_value=0,  # 0 = success (forwarded reservation)
        expected_sc_success=True,
    )

    # Verify back-to-back SC.W success
    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)
    x14_value = dut_if.read_register(14)
    assert (
        x14_value == 0
    ), f"SC.W Test Case 4 failed: x14 = {x14_value}, expected 0 (success)"
    cocotb.log.info(f"SC.W x14 = {x14_value} (back-to-back success via forwarding)")

    # ========================================================================
    # Test Case 5: LR.W + intervening NOPs + SC.W (reservation persists)
    # ========================================================================
    cocotb.log.info("=== Test Case 5: LR.W + NOPs + SC.W (reservation persists) ===")

    # LR.W x15, (x10) - set reservation
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="lr.w",
        rd=15,
        rs1=10,
        rs2=0,
        expected_rd_value=test_data,  # Value from Test Case 1's SC
        expected_sc_success=None,
    )

    # Insert a few NOPs (addi x0, x0, 0)
    for _ in range(3):
        await execute_nop(dut_if, state)

    # SC.W x16, x12, (x10) - should still succeed
    await execute_lr_sc_instruction(
        dut_if,
        state,
        mem_model,
        operation="sc.w",
        rd=16,
        rs1=10,
        rs2=12,
        expected_rd_value=0,  # 0 = success
        expected_sc_success=True,
    )

    # Verify SC.W success after intervening NOPs
    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)
    x16_value = dut_if.read_register(16)
    assert (
        x16_value == 0
    ), f"SC.W Test Case 5 failed: x16 = {x16_value}, expected 0 (success)"
    cocotb.log.info(f"SC.W x16 = {x16_value} (success after NOPs)")

    # ========================================================================
    # Cleanup: Flush pipeline with NOPs
    # ========================================================================
    cocotb.log.info("=== Flushing pipeline ===")
    for _ in range(10):
        await execute_nop(dut_if, state)

    cocotb.log.info("=== All LR.W/SC.W directed tests passed! ===")


@cocotb.test()
async def test_directed_lr_sc(dut: Any) -> None:
    """Directed test for LR.W and SC.W atomic instructions."""
    await run_directed_lr_sc_test(dut)
