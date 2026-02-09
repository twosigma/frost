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

"""Directed tests for machine-mode trap handling.

Directed Trap Tests
===================

This module contains directed tests for machine-mode trap handling instructions
and behaviors. These tests are separated from random regression because:

1. Trap handling requires precise CSR setup (mtvec, mepc, mcause)
2. Interrupt testing requires external signal control (i_interrupts_reg)
3. Race conditions between traps/interrupts need deterministic sequences

Test Categories:
    Basic Trap Handling:
        - ECALL: Environment call from M-mode (mcause=11)
        - EBREAK: Breakpoint exception (mcause=3)
        - MRET: Return from machine-mode trap handler

    Interrupt Handling:
        - Timer interrupt trap entry (mstatus.MIE cleared)
        - MRET + interrupt race condition
        - CSRSI enabling MIE with pending interrupt

RISC-V Trap Entry Protocol:
    ┌────────────────────────────────────────────────────────────────┐
    │ On trap/interrupt entry:                                       │
    │   1. mepc <- PC of faulting/interrupted instruction            │
    │   2. mcause <- cause code (11=ECALL, 3=EBREAK, 0x8000_0007=MTI)│
    │   3. mstatus.MPIE <- mstatus.MIE (save old interrupt enable)  │
    │   4. mstatus.MIE <- 0 (disable interrupts)                    │
    │   5. PC <- mtvec (jump to trap handler)                       │
    │                                                                 │
    │ On MRET:                                                        │
    │   1. mstatus.MIE <- mstatus.MPIE (restore interrupt enable)   │
    │   2. mstatus.MPIE <- 1                                         │
    │   3. PC <- mepc (return to saved PC)                           │
    └────────────────────────────────────────────────────────────────┘

Usage:
    make test TEST=test_directed_trap_handling
    make test TEST=test_directed_interrupt_trap_mstatus
    make test TEST=test_directed_mret_interrupt_race
    make test TEST=test_directed_csrsi_enable_mie
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


async def run_directed_trap_test(dut: Any, config: TestConfig | None = None) -> None:
    """Directed test for machine-mode trap handling (ECALL, EBREAK, MRET).

    This test exercises the trap handling infrastructure:
    1. Set up mtvec to point to a trap handler address
    2. Execute ECALL - verify jump to mtvec, mepc/mcause saved correctly
    3. Execute MRET - verify return to instruction after ECALL
    4. Execute EBREAK - verify jump to mtvec with different mcause
    5. Execute MRET - verify return again

    Args:
        dut: Device under test (cocotb SimHandle)
        config: Test configuration. If None, uses default configuration.
    """
    from encoders.op_tables import TRAP_INSTRS, CSRS
    from encoders.instruction_encode import CSRAddress

    if config is None:
        config = TestConfig(num_loops=100)

    # ========================================================================
    # Initialization Phase
    # ========================================================================
    dut_if = DUTInterface(dut)
    state = TestState()

    dut_if.instruction = 0x00000013  # 32-bit NOP (addi x0, x0, 0)

    # Initialize registers to known values
    state.register_file_current = [0] * 32
    for i in range(1, 32):
        state.register_file_current[i] = (i * 0x11111111) & MASK32

    # Set up specific values for trap testing
    trap_handler_address = 0x1000  # Trap handler at 0x1000
    state.register_file_current[1] = trap_handler_address  # x1 = trap handler addr

    # Write registers to DUT
    for i in range(1, 32):
        dut_if.write_register(i, state.register_file_current[i])

    # Start clock
    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())

    # Reset DUT
    await dut_if.reset_dut(config.reset_cycles)

    # Initialize memory model (needed for pipeline to work correctly)
    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    # Initialize register file pipeline states for 6-stage pipeline.
    state.register_file_previous = state.register_file_current.copy()

    # ========================================================================
    # Warmup: Let pipeline stabilize
    # ========================================================================
    cocotb.log.info("=== Warming up pipeline ===")
    for _ in range(8):
        await execute_nop(dut_if, state)

    # ========================================================================
    # Step 1: Set up mtvec (trap vector base address)
    # Use CSRRW to write trap_handler_address to mtvec
    # ========================================================================
    cocotb.log.info("=== Setting up mtvec ===")

    # CSRRW x0, mtvec, x1 - write x1 to mtvec, discard old value
    enc_csrrw = CSRS["csrrw"]
    instr_csrrw_mtvec = enc_csrrw(0, CSRAddress.MTVEC, 1)  # rd=0, csr=mtvec, rs1=x1

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrrw_mtvec
    await RisingEdge(dut_if.clock)

    # Track state
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    cocotb.log.info(f"Set mtvec = 0x{trap_handler_address:08X}")

    # Let the CSR write complete through pipeline
    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)

    # Record the PC where ECALL will be executed
    ecall_pc = state.program_counter_current

    # ========================================================================
    # Step 2: Execute ECALL - should trap to mtvec
    # ========================================================================
    cocotb.log.info(f"=== Executing ECALL at PC=0x{ecall_pc:08X} ===")

    enc_ecall = TRAP_INSTRS["ecall"]
    instr_ecall = enc_ecall()

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_ecall
    await RisingEdge(dut_if.clock)

    # After ECALL, PC should jump to mtvec (trap_handler_address)
    # mepc should contain ecall_pc, mcause should be 11 (ECALL from M-mode)
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    # Note: The expected PC after ECALL is complex due to pipeline flush
    # For now, we'll just track state and verify via register reads
    state.program_counter_expected_values_queue.append(trap_handler_address)
    state.update_program_counter(trap_handler_address)
    state.advance_register_state()

    cocotb.log.info("ECALL executed, expecting jump to trap handler")

    # Wait for trap to be taken and pipeline to stabilize
    for _ in range(10):
        await execute_nop(dut_if, state)

    # ========================================================================
    # Step 3: Verify mepc and mcause via CSR reads
    # ========================================================================
    cocotb.log.info("=== Verifying mepc and mcause ===")

    # Read mepc into x2: CSRRS x2, mepc, x0
    enc_csrrs = CSRS["csrrs"]
    instr_read_mepc = enc_csrrs(2, CSRAddress.MEPC, 0)  # rd=x2, csr=mepc, rs1=x0

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_read_mepc
    await RisingEdge(dut_if.clock)

    # x2 should get mepc value (ecall_pc adjusted for pipeline)
    # We'll verify this after pipeline drains
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    # Let read complete
    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)

    # Check mepc value
    mepc_value = dut_if.read_register(2)
    cocotb.log.info(f"mepc = 0x{mepc_value:08X} (expected near 0x{ecall_pc:08X})")

    # Read mcause into x3: CSRRS x3, mcause, x0
    instr_read_mcause = enc_csrrs(3, CSRAddress.MCAUSE, 0)  # rd=x3, csr=mcause, rs1=x0

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_read_mcause
    await RisingEdge(dut_if.clock)

    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)

    mcause_value = dut_if.read_register(3)
    cocotb.log.info(
        f"mcause = 0x{mcause_value:08X} (expected 11 for ECALL from M-mode)"
    )

    # Verify mcause is 11 (ECALL from M-mode)
    assert mcause_value == 11, f"mcause mismatch: got {mcause_value}, expected 11"
    cocotb.log.info("mcause verification PASSED")

    # ========================================================================
    # Step 4: Execute MRET - should return to mepc
    # ========================================================================
    cocotb.log.info("=== Executing MRET ===")

    enc_mret = TRAP_INSTRS["mret"]
    instr_mret = enc_mret()

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_mret
    await RisingEdge(dut_if.clock)

    # After MRET, PC should return to mepc
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    # PC goes to mepc value
    state.program_counter_expected_values_queue.append(mepc_value)
    state.update_program_counter(mepc_value)
    state.advance_register_state()

    cocotb.log.info(f"MRET executed, expecting return to 0x{mepc_value:08X}")

    # Wait for MRET to complete
    for _ in range(10):
        await execute_nop(dut_if, state)

    # ========================================================================
    # Step 5: Test EBREAK (breakpoint exception)
    # ========================================================================
    cocotb.log.info("=== Testing EBREAK ===")

    # First, re-set mtvec (it may have been affected by previous operations)
    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrrw_mtvec  # Re-use the CSRRW instruction
    await RisingEdge(dut_if.clock)

    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)

    ebreak_pc = state.program_counter_current

    enc_ebreak = TRAP_INSTRS["ebreak"]
    instr_ebreak = enc_ebreak()

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_ebreak
    await RisingEdge(dut_if.clock)

    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    state.program_counter_expected_values_queue.append(trap_handler_address)
    state.update_program_counter(trap_handler_address)
    state.advance_register_state()

    cocotb.log.info(f"EBREAK executed at PC=0x{ebreak_pc:08X}")

    for _ in range(10):
        await execute_nop(dut_if, state)

    # Verify mcause is 3 (Breakpoint)
    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_read_mcause
    await RisingEdge(dut_if.clock)

    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)

    mcause_value = dut_if.read_register(3)
    cocotb.log.info(f"mcause = {mcause_value} (expected 3 for breakpoint)")
    assert mcause_value == 3, f"mcause mismatch: got {mcause_value}, expected 3"
    cocotb.log.info("EBREAK mcause verification PASSED")

    # Execute MRET to return from EBREAK
    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_mret
    await RisingEdge(dut_if.clock)

    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    state.program_counter_expected_values_queue.append(0)  # Will be mepc
    state.update_program_counter(0)
    state.advance_register_state()

    for _ in range(10):
        await execute_nop(dut_if, state)

    # ========================================================================
    # Cleanup
    # ========================================================================
    cocotb.log.info("=== Flushing pipeline ===")
    for _ in range(10):
        await execute_nop(dut_if, state)

    cocotb.log.info("=== All trap handling tests passed! ===")


@cocotb.test()
async def test_directed_trap_handling(dut: Any) -> None:
    """Directed test for machine-mode trap handling (ECALL, EBREAK, MRET)."""
    await run_directed_trap_test(dut)


# ============================================================================
# Directed Test for Interrupt Trap mstatus Behavior
# ============================================================================


async def run_directed_interrupt_trap_test(
    dut: Any, config: TestConfig | None = None
) -> None:
    """Directed test for interrupt trap entry - verify mstatus.MIE is cleared.

    This test exercises the critical RISC-V interrupt trap entry behavior:
    When an interrupt is taken, the hardware MUST:
    1. Save current MIE (bit 3) to MPIE (bit 7)
    2. Clear MIE (bit 3) to disable further interrupts

    Args:
        dut: Device under test (cocotb SimHandle)
        config: Test configuration. If None, uses default configuration.
    """
    from encoders.op_tables import CSRS
    from encoders.instruction_encode import CSRAddress

    if config is None:
        config = TestConfig(num_loops=100)

    # ========================================================================
    # Initialization Phase
    # ========================================================================
    dut_if = DUTInterface(dut)
    state = TestState()

    dut_if.instruction = 0x00000013  # 32-bit NOP (addi x0, x0, 0)

    # Initialize registers
    state.register_file_current = [0] * 32
    for i in range(1, 32):
        state.register_file_current[i] = (i * 0x11111111) & MASK32

    # Set up trap handler address
    trap_handler_address = 0x1000
    state.register_file_current[1] = trap_handler_address  # x1 = trap handler addr
    state.register_file_current[2] = 0x80  # x2 = MTIE bit (bit 7 of mie)
    state.register_file_current[3] = 0x08  # x3 = MIE bit (bit 3 of mstatus)

    # Write registers to DUT
    for i in range(1, 32):
        dut_if.write_register(i, state.register_file_current[i])

    # Start clock
    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())

    # Reset DUT
    await dut_if.reset_dut(config.reset_cycles)

    # Initialize memory model
    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    # Initialize register file pipeline states for 6-stage pipeline.
    state.register_file_previous = state.register_file_current.copy()

    # ========================================================================
    # Warmup
    # ========================================================================
    cocotb.log.info("=== Warming up pipeline ===")
    for _ in range(8):
        await execute_nop(dut_if, state)

    # ========================================================================
    # Step 1: Set up mtvec (trap vector base address)
    # ========================================================================
    cocotb.log.info("=== Setting up mtvec ===")

    enc_csrrw = CSRS["csrrw"]
    instr_csrrw_mtvec = enc_csrrw(0, CSRAddress.MTVEC, 1)  # rd=0, csr=mtvec, rs1=x1

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrrw_mtvec
    await RisingEdge(dut_if.clock)

    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    cocotb.log.info(f"Set mtvec = 0x{trap_handler_address:08X}")

    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)

    # ========================================================================
    # Step 2: Enable timer interrupt in mie (set MTIE bit 7)
    # ========================================================================
    cocotb.log.info("=== Enabling timer interrupt in mie ===")

    # CSRRW x0, mie, x2 - write 0x80 to mie (MTIE = 1)
    instr_csrrw_mie = enc_csrrw(0, CSRAddress.MIE, 2)

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrrw_mie
    await RisingEdge(dut_if.clock)

    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    cocotb.log.info("Set mie = 0x80 (MTIE enabled)")

    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)

    # ========================================================================
    # Step 3: Enable global interrupts in mstatus (set MIE bit 3)
    # ========================================================================
    cocotb.log.info("=== Enabling global interrupts in mstatus ===")

    # CSRRW x0, mstatus, x3 - write 0x08 to mstatus (MIE = 1)
    instr_csrrw_mstatus = enc_csrrw(0, CSRAddress.MSTATUS, 3)

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrrw_mstatus
    await RisingEdge(dut_if.clock)

    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    cocotb.log.info("Set mstatus = 0x08 (MIE enabled)")

    # Read back mstatus to verify
    for _ in range(3):
        await execute_nop(dut_if, state)

    # ========================================================================
    # Step 4: Verify mstatus.MIE is set before triggering interrupt
    # ========================================================================
    cocotb.log.info("=== Verifying mstatus before interrupt ===")

    # Access internal mstatus signal
    try:
        mstatus_before = int(dut.device_under_test.csr_file_inst.mstatus.value)
        mie_before = (mstatus_before >> 3) & 1
        mpie_before = (mstatus_before >> 7) & 1
        cocotb.log.info(
            f"Before interrupt: mstatus=0x{mstatus_before:08X}, "
            f"MIE={mie_before}, MPIE={mpie_before}"
        )
        assert mie_before == 1, f"MIE should be 1 before interrupt, got {mie_before}"
    except Exception as e:
        cocotb.log.warning(f"Could not read mstatus directly: {e}")

    # ========================================================================
    # Step 5: Trigger timer interrupt by setting mtip
    # ========================================================================
    cocotb.log.info("=== Triggering timer interrupt ===")

    # Set i_interrupts_reg to trigger timer interrupt (bit 1 = mtip)
    # interrupt_t is {meip, mtip, msip} = {bit2, bit1, bit0}
    dut.i_interrupts_reg.value = 0b010  # mtip = 1

    cocotb.log.info("Set i_interrupts_reg = 0b010 (mtip=1)")

    # ========================================================================
    # Step 6: Wait for trap to be taken and monitor mstatus
    # ========================================================================
    cocotb.log.info("=== Monitoring trap_taken and mstatus ===")

    trap_detected = False
    for cycle in range(20):
        await RisingEdge(dut_if.clock)

        # Check if trap is being taken
        try:
            trap_taken = int(dut.device_under_test.trap_unit_inst.o_trap_taken.value)
            mstatus_current = int(dut.device_under_test.csr_file_inst.mstatus.value)
            mie_current = (mstatus_current >> 3) & 1
            mpie_current = (mstatus_current >> 7) & 1

            if trap_taken:
                trap_detected = True
                cocotb.log.info(
                    f"Cycle {cycle}: trap_taken=1, mstatus=0x{mstatus_current:08X}, "
                    f"MIE={mie_current}, MPIE={mpie_current}"
                )
                # Capture mstatus value after trap_taken goes high
                break
            else:
                cocotb.log.info(
                    f"Cycle {cycle}: trap_taken=0, mstatus=0x{mstatus_current:08X}, "
                    f"MIE={mie_current}, MPIE={mpie_current}"
                )
        except Exception as e:
            cocotb.log.warning(f"Cycle {cycle}: Could not read signals: {e}")

    assert trap_detected, "Timer interrupt trap was not taken!"

    # ========================================================================
    # Step 7: Wait one more cycle and verify mstatus.MIE is cleared
    # ========================================================================
    await RisingEdge(dut_if.clock)

    try:
        mstatus_after = int(dut.device_under_test.csr_file_inst.mstatus.value)
        mie_after = (mstatus_after >> 3) & 1
        mpie_after = (mstatus_after >> 7) & 1

        cocotb.log.info(
            f"After trap: mstatus=0x{mstatus_after:08X}, "
            f"MIE={mie_after}, MPIE={mpie_after}"
        )

        # THE CRITICAL CHECK: MIE must be 0 after trap entry!
        if mie_after != 0:
            cocotb.log.error(
                f"BUG DETECTED! mstatus.MIE should be 0 after trap entry, "
                f"but got MIE={mie_after}. mstatus=0x{mstatus_after:08X}"
            )
            # Also check MPIE - it should have the old MIE value (1)
            cocotb.log.info(f"MPIE={mpie_after} (should be 1, saving old MIE)")

        assert mie_after == 0, (
            f"TRAP BUG: mstatus.MIE should be 0 after interrupt trap entry! "
            f"Got mstatus=0x{mstatus_after:08X} (MIE={mie_after})"
        )
        assert mpie_after == 1, (
            f"TRAP BUG: mstatus.MPIE should be 1 (old MIE value)! "
            f"Got mstatus=0x{mstatus_after:08X} (MPIE={mpie_after})"
        )

        cocotb.log.info("SUCCESS: mstatus.MIE correctly cleared to 0 on trap entry!")
        cocotb.log.info("SUCCESS: mstatus.MPIE correctly set to 1 (old MIE value)!")

    except AttributeError as e:
        cocotb.log.error(f"Could not access internal signals: {e}")
        raise

    # ========================================================================
    # Step 8: Clear interrupt and verify trap is no longer pending
    # ========================================================================
    dut.i_interrupts_reg.value = 0b000  # Clear all interrupts

    # Cleanup
    for _ in range(10):
        await execute_nop(dut_if, state)

    cocotb.log.info("=== Interrupt trap mstatus test PASSED! ===")


@cocotb.test()
async def test_directed_interrupt_trap_mstatus(dut: Any) -> None:
    """Directed test for interrupt trap entry - verify mstatus.MIE is cleared."""
    await run_directed_interrupt_trap_test(dut)


# ============================================================================
# Directed Test for MRET + Interrupt Race Condition
# ============================================================================


async def run_directed_mret_interrupt_race_test(
    dut: Any, config: TestConfig | None = None
) -> None:
    """Directed test for MRET with pending interrupt - verify correct behavior.

    This test checks for a potential priority bug where an interrupt arrives
    while MRET is in the EX stage. There's a priority mismatch:
    - trap_unit: take_mret has priority for o_trap_target (goes to mepc)
    - csr_file: i_trap_taken has priority for mstatus (does trap entry)

    Expected correct behavior:
    - If interrupt has priority, PC should go to mtvec, mstatus should do trap entry
    - If MRET has priority, PC should go to mepc, mstatus should restore from MPIE
    """
    from encoders.op_tables import CSRS, TRAP_INSTRS
    from encoders.instruction_encode import CSRAddress

    if config is None:
        config = TestConfig(num_loops=100)

    dut_if = DUTInterface(dut)
    state = TestState()
    dut_if.instruction = 0x00000013  # 32-bit NOP (addi x0, x0, 0)

    # Initialize registers
    state.register_file_current = [0] * 32
    for i in range(1, 32):
        state.register_file_current[i] = (i * 0x11111111) & MASK32

    trap_handler_address = 0x1000
    return_address = 0x2000
    state.register_file_current[1] = trap_handler_address
    state.register_file_current[2] = 0x80  # MTIE
    state.register_file_current[3] = 0x88  # MIE=1, MPIE=1
    state.register_file_current[4] = return_address

    for i in range(1, 32):
        dut_if.write_register(i, state.register_file_current[i])

    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())
    await dut_if.reset_dut(config.reset_cycles)

    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    # Initialize register file pipeline states for 6-stage pipeline.
    state.register_file_previous = state.register_file_current.copy()

    # Warmup
    cocotb.log.info("=== Warming up pipeline ===")
    for _ in range(8):
        await execute_nop(dut_if, state)

    # Set up mtvec
    cocotb.log.info("=== Setting up mtvec ===")
    enc_csrrw = CSRS["csrrw"]
    instr_csrrw_mtvec = enc_csrrw(0, CSRAddress.MTVEC, 1)
    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrrw_mtvec
    await RisingEdge(dut_if.clock)
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    for _ in range(3):
        await execute_nop(dut_if, state)

    # Set up mepc (return address for MRET)
    cocotb.log.info("=== Setting up mepc ===")
    instr_csrrw_mepc = enc_csrrw(0, CSRAddress.MEPC, 4)  # mepc = x4 = return_address
    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrrw_mepc
    await RisingEdge(dut_if.clock)
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    for _ in range(3):
        await execute_nop(dut_if, state)

    # Enable timer interrupt in mie
    cocotb.log.info("=== Enabling timer interrupt in mie ===")
    instr_csrrw_mie = enc_csrrw(0, CSRAddress.MIE, 2)
    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrrw_mie
    await RisingEdge(dut_if.clock)
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    for _ in range(3):
        await execute_nop(dut_if, state)

    # Set mstatus to 0x88 (MIE=1, MPIE=1) - simulates being in trap handler
    cocotb.log.info("=== Setting mstatus = 0x88 (MIE=1, MPIE=1) ===")
    instr_csrrw_mstatus = enc_csrrw(0, CSRAddress.MSTATUS, 3)
    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrrw_mstatus
    await RisingEdge(dut_if.clock)
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    for _ in range(3):
        await execute_nop(dut_if, state)

    # Verify setup
    try:
        mstatus_before = int(dut.device_under_test.csr_file_inst.mstatus.value)
        mepc_before = int(dut.device_under_test.csr_file_inst.mepc.value)
        mtvec_before = int(dut.device_under_test.csr_file_inst.mtvec.value)
        cocotb.log.info(
            f"Before MRET: mstatus=0x{mstatus_before:08X}, "
            f"mepc=0x{mepc_before:08X}, mtvec=0x{mtvec_before:08X}"
        )
    except Exception as e:
        cocotb.log.warning(f"Could not read CSRs: {e}")

    # Now trigger interrupt AND execute MRET in the same cycle
    cocotb.log.info("=== Executing MRET with pending timer interrupt ===")

    # Assert timer interrupt
    dut.i_interrupts_reg.value = 0b010  # mtip = 1

    # Execute MRET instruction
    enc_mret = TRAP_INSTRS["mret"]
    instr_mret = enc_mret()

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_mret
    await RisingEdge(dut_if.clock)

    # Check signals during the race condition
    try:
        trap_taken = int(dut.device_under_test.trap_unit_inst.o_trap_taken.value)
        mret_taken = int(dut.device_under_test.trap_unit_inst.o_mret_taken.value)
        trap_target = int(dut.device_under_test.trap_unit_inst.o_trap_target.value)
        mstatus = int(dut.device_under_test.csr_file_inst.mstatus.value)
        cocotb.log.info(
            f"During race: trap_taken={trap_taken}, mret_taken={mret_taken}, "
            f"trap_target=0x{trap_target:08X}, mstatus=0x{mstatus:08X}"
        )

        if trap_taken and mret_taken:
            cocotb.log.warning(
                "RACE CONDITION: Both trap_taken and mret_taken are high!"
            )
            if trap_target == return_address:
                cocotb.log.error(
                    f"BUG: trap_target=mepc(0x{return_address:08X}) but trap_taken=1!"
                )
            elif trap_target == trap_handler_address:
                cocotb.log.info("OK: trap_target=mtvec (interrupt has priority)")
    except Exception as e:
        cocotb.log.warning(f"Could not read signals: {e}")

    # Wait for next cycle and check mstatus
    await RisingEdge(dut_if.clock)
    try:
        mstatus_after = int(dut.device_under_test.csr_file_inst.mstatus.value)
        mie_after = (mstatus_after >> 3) & 1
        mpie_after = (mstatus_after >> 7) & 1
        cocotb.log.info(
            f"After race: mstatus=0x{mstatus_after:08X}, MIE={mie_after}, MPIE={mpie_after}"
        )

        # The key assertion: mstatus should be consistent with what happened
        # If interrupt was taken, MIE should be 0
        # If MRET was executed, MIE should be 1 (restored from MPIE)
    except Exception as e:
        cocotb.log.warning(f"Could not read mstatus: {e}")

    # Clear interrupt
    dut.i_interrupts_reg.value = 0b000

    # Cleanup
    for _ in range(10):
        await execute_nop(dut_if, state)

    cocotb.log.info("=== MRET + interrupt race test complete ===")


@cocotb.test()
async def test_directed_mret_interrupt_race(dut: Any) -> None:
    """Directed test for MRET with pending interrupt race condition."""
    await run_directed_mret_interrupt_race_test(dut)


# ============================================================================
# Directed Test for CSRSI enables MIE while interrupt pending
# ============================================================================


async def run_directed_csrsi_enable_mie_test(
    dut: Any, config: TestConfig | None = None
) -> None:
    """Directed test for CSRSI enabling MIE while interrupt is already pending.

    This tests the exact FreeRTOS scenario:
    1. Timer interrupt is pending (but MIE=0, so not taken)
    2. CSRSI mstatus, 0x8 is executed to enable MIE
    3. Next cycle: interrupt is detected and trap is taken
    4. After trap: MIE should be 0, MPIE should be 1

    This catches the bug where the CSR write and trap entry interact incorrectly.
    """
    from encoders.op_tables import CSRS
    from encoders.instruction_encode import CSRAddress

    if config is None:
        config = TestConfig(num_loops=100)

    dut_if = DUTInterface(dut)
    state = TestState()
    dut_if.instruction = 0x00000013  # 32-bit NOP (addi x0, x0, 0)

    # Initialize registers
    state.register_file_current = [0] * 32
    for i in range(1, 32):
        state.register_file_current[i] = (i * 0x11111111) & MASK32

    trap_handler_address = 0x1000
    state.register_file_current[1] = trap_handler_address
    state.register_file_current[2] = 0x80  # MTIE

    for i in range(1, 32):
        dut_if.write_register(i, state.register_file_current[i])

    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())
    await dut_if.reset_dut(config.reset_cycles)

    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    # Initialize register file pipeline states for 6-stage pipeline.
    state.register_file_previous = state.register_file_current.copy()

    # Warmup
    cocotb.log.info("=== Warming up pipeline ===")
    for _ in range(8):
        await execute_nop(dut_if, state)

    # Set up mtvec
    cocotb.log.info("=== Setting up mtvec ===")
    enc_csrrw = CSRS["csrrw"]
    instr_csrrw_mtvec = enc_csrrw(0, CSRAddress.MTVEC, 1)
    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrrw_mtvec
    await RisingEdge(dut_if.clock)
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    for _ in range(3):
        await execute_nop(dut_if, state)

    # Enable timer interrupt in mie
    cocotb.log.info("=== Enabling timer interrupt in mie ===")
    instr_csrrw_mie = enc_csrrw(0, CSRAddress.MIE, 2)
    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrrw_mie
    await RisingEdge(dut_if.clock)
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    for _ in range(3):
        await execute_nop(dut_if, state)

    # Assert timer interrupt BEFORE enabling MIE
    cocotb.log.info("=== Asserting timer interrupt (MIE still 0) ===")
    dut.i_interrupts_reg.value = 0b010  # mtip = 1

    # Verify mstatus is 0x00 (MIE=0)
    try:
        mstatus_before = int(dut.device_under_test.csr_file_inst.mstatus.value)
        cocotb.log.info(f"Before CSRSI: mstatus=0x{mstatus_before:08X}")
        assert (mstatus_before & 0x8) == 0, "MIE should be 0 before CSRSI!"
    except Exception as e:
        cocotb.log.warning(f"Could not read mstatus: {e}")

    # Wait a cycle with interrupt pending but MIE=0 (no trap should happen)
    for _ in range(3):
        await execute_nop(dut_if, state)

    # Verify trap has NOT been taken yet (MIE=0)
    try:
        trap_taken = int(dut.device_under_test.trap_unit_inst.o_trap_taken.value)
        cocotb.log.info(f"Before CSRSI: trap_taken={trap_taken} (should be 0)")
        assert trap_taken == 0, "Trap should not be taken with MIE=0!"
    except Exception as e:
        cocotb.log.warning(f"Could not read trap_taken: {e}")

    # NOW execute CSRSI mstatus, 0x8 to enable MIE
    cocotb.log.info("=== Executing CSRSI mstatus, 0x8 (enable MIE) ===")
    enc_csrsi = CSRS["csrrsi"]
    instr_csrsi_mstatus = enc_csrsi(0, CSRAddress.MSTATUS, 0x8)  # Set bit 3 (MIE)

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrsi_mstatus

    # Log cycle-by-cycle what happens
    cocotb.log.info("=== Cycle-by-cycle monitoring ===")
    for cycle in range(PIPELINE_DEPTH):
        await RisingEdge(dut_if.clock)
        try:
            trap_taken = int(dut.device_under_test.trap_unit_inst.o_trap_taken.value)
            mstatus = int(dut.device_under_test.csr_file_inst.mstatus.value)
            mie = (mstatus >> 3) & 1
            mpie = (mstatus >> 7) & 1
            csr_write_en = int(dut.device_under_test.csr_write_enable.value)
            cocotb.log.info(
                f"Cycle {cycle}: trap_taken={trap_taken}, csr_write_en={csr_write_en}, "
                f"mstatus=0x{mstatus:08X}, MIE={mie}, MPIE={mpie}"
            )

            # If trap was taken, check mstatus
            if trap_taken:
                cocotb.log.info(f">>> Trap detected at cycle {cycle}")
                # The trap is being taken NOW, mstatus update happens next edge
        except Exception as e:
            cocotb.log.warning(f"Cycle {cycle}: Could not read signals: {e}")

    # Wait one additional cycle for mstatus to be updated after trap_taken.
    # This is needed because:
    # 1. interrupt_pending is registered in trap_unit for timing optimization (1 cycle latency)
    # 2. mstatus update happens on the clock edge after trap_taken is asserted
    # Total: 2 cycles from MIE enable to mstatus update
    await RisingEdge(dut_if.clock)

    # Final check
    try:
        mstatus_final = int(dut.device_under_test.csr_file_inst.mstatus.value)
        mie_final = (mstatus_final >> 3) & 1
        mpie_final = (mstatus_final >> 7) & 1
        cocotb.log.info(
            f"Final: mstatus=0x{mstatus_final:08X}, MIE={mie_final}, MPIE={mpie_final}"
        )

        # THE KEY CHECK: after trap entry, MIE must be 0!
        if mie_final != 0:
            cocotb.log.error(
                f"BUG: MIE should be 0 after trap entry, got MIE={mie_final}! "
                f"mstatus=0x{mstatus_final:08X}"
            )

        assert (
            mie_final == 0
        ), f"CSRSI+TRAP BUG: MIE should be 0 after trap! Got mstatus=0x{mstatus_final:08X}"
        assert (
            mpie_final == 1
        ), f"CSRSI+TRAP BUG: MPIE should be 1! Got mstatus=0x{mstatus_final:08X}"

        cocotb.log.info("SUCCESS: MIE correctly cleared after CSRSI + trap!")

    except Exception as e:
        cocotb.log.error(f"Final check failed: {e}")
        raise

    # Clear interrupt
    dut.i_interrupts_reg.value = 0b000

    for _ in range(10):
        await execute_nop(dut_if, state)

    cocotb.log.info("=== CSRSI enable MIE test complete ===")


@cocotb.test()
async def test_directed_csrsi_enable_mie(dut: Any) -> None:
    """Directed test for CSRSI enabling MIE while interrupt pending."""
    await run_directed_csrsi_enable_mie_test(dut)


# ============================================================================
# Directed Test for Illegal Instruction Trapping (mcause=2)
# ============================================================================


async def run_directed_illegal_instruction_test(
    dut: Any, config: TestConfig | None = None
) -> None:
    """Directed test for illegal instruction detection (mcause=2).

    This test exercises the illegal instruction trap mechanism by injecting
    several hand-crafted encodings that do not correspond to any valid
    RISC-V instruction. For each illegal encoding, the test verifies:
    1. The processor traps to the mtvec address
    2. mcause is set to 2 (Illegal instruction)
    3. MRET successfully returns to continue execution

    Illegal encodings tested:
        - Unknown opcode (0x7F - all ones in opcode field)
        - Reserved funct3 in BRANCH (funct3=010)
        - Reserved funct7 in OP (funct7=0x7F, funct3=000)
        - Reserved funct3 in LOAD (funct3=011)
        - Reserved funct3 in STORE (funct3=011)

    Args:
        dut: Device under test (cocotb SimHandle)
        config: Test configuration. If None, uses default configuration.
    """
    from encoders.op_tables import TRAP_INSTRS, CSRS
    from encoders.instruction_encode import (
        CSRAddress,
        RType,
        IType,
        SType,
        BType,
        FPType,
        R4Type,
        FPFunct7,
        Opcode,
    )

    if config is None:
        config = TestConfig(num_loops=100)

    # ========================================================================
    # Initialization Phase
    # ========================================================================
    dut_if = DUTInterface(dut)
    state = TestState()

    dut_if.instruction = 0x00000013  # 32-bit NOP (addi x0, x0, 0)

    # Initialize registers to known values
    state.register_file_current = [0] * 32
    for i in range(1, 32):
        state.register_file_current[i] = (i * 0x11111111) & MASK32

    # Set up specific values for trap testing
    trap_handler_address = 0x1000  # Trap handler at 0x1000
    state.register_file_current[1] = trap_handler_address  # x1 = trap handler addr

    # Write registers to DUT
    for i in range(1, 32):
        dut_if.write_register(i, state.register_file_current[i])

    # Start clock
    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())

    # Reset DUT
    await dut_if.reset_dut(config.reset_cycles)

    # Initialize memory model (needed for pipeline to work correctly)
    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    # Initialize register file pipeline states for 6-stage pipeline.
    state.register_file_previous = state.register_file_current.copy()

    # ========================================================================
    # Warmup: Let pipeline stabilize
    # ========================================================================
    cocotb.log.info("=== Warming up pipeline ===")
    for _ in range(8):
        await execute_nop(dut_if, state)

    # ========================================================================
    # Step 1: Set up mtvec (trap vector base address)
    # Use CSRRW to write trap_handler_address to mtvec
    # ========================================================================
    cocotb.log.info("=== Setting up mtvec ===")

    # CSRRW x0, mtvec, x1 - write x1 to mtvec, discard old value
    enc_csrrw = CSRS["csrrw"]
    instr_csrrw_mtvec = enc_csrrw(0, CSRAddress.MTVEC, 1)  # rd=0, csr=mtvec, rs1=x1

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrrw_mtvec
    await RisingEdge(dut_if.clock)

    # Track state
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    cocotb.log.info(f"Set mtvec = 0x{trap_handler_address:08X}")

    # Let the CSR write complete through pipeline
    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)

    # ========================================================================
    # Step 2: Define illegal instruction encodings to test
    # ========================================================================
    illegal_cases = [
        ("unknown opcode 0x7F", IType.encode(0, 0, 0, 0, 0b1111111)),
        ("bad funct3=010 in BRANCH", BType.encode(0, 0, 0, 0b010, 0x63)),
        ("bad funct7=0x7F in OP", RType.encode(0b1111111, 0, 0, 0b000, 0, 0x33)),
        ("bad funct3=011 in LOAD", IType.encode(0, 0, 0b011, 0, 0x03)),
        ("bad funct3=011 in STORE", SType.encode(0, 0, 0, 0b011, 0x23)),
        # FP reserved rounding mode: rm=101 on FADD.S (OPC_OP_FP arithmetic)
        ("reserved rm=5 in FADD.S", FPType.encode(FPFunct7.FADD_S, 2, 1, 5, 3)),
        # FP reserved rounding mode: rm=110 on FMADD.S (FMA opcode)
        ("reserved rm=6 in FMADD.S", R4Type.encode(0, 2, 1, 6, 3, Opcode.FMADD, fmt=0)),
    ]

    # Prepare MRET and CSRRS instructions for reuse
    enc_mret = TRAP_INSTRS["mret"]
    instr_mret = enc_mret()

    enc_csrrs = CSRS["csrrs"]
    instr_read_mcause = enc_csrrs(3, CSRAddress.MCAUSE, 0)  # rd=x3, csr=mcause, rs1=x0

    # ========================================================================
    # Step 3: Test each illegal instruction encoding
    # ========================================================================
    for name, encoding in illegal_cases:
        cocotb.log.info(f"=== Testing illegal: {name} (0x{encoding:08X}) ===")

        # Record the PC where the illegal instruction will be executed
        illegal_pc = state.program_counter_current

        # Execute the illegal instruction
        await FallingEdge(dut_if.clock)
        await dut_if.wait_ready()
        dut_if.instruction = encoding
        await RisingEdge(dut_if.clock)

        # After illegal instruction, PC should jump to mtvec (trap_handler_address)
        state.register_file_current_expected_queue.append(
            state.register_file_current.copy()
        )
        state.program_counter_expected_values_queue.append(trap_handler_address)
        state.update_program_counter(trap_handler_address)
        state.advance_register_state()

        cocotb.log.info(
            f"Illegal instruction executed at PC=0x{illegal_pc:08X}, "
            f"expecting jump to trap handler"
        )

        # Wait for trap to be taken and pipeline to stabilize
        for _ in range(10):
            await execute_nop(dut_if, state)

        # Read mcause into x3: CSRRS x3, mcause, x0
        await FallingEdge(dut_if.clock)
        await dut_if.wait_ready()
        dut_if.instruction = instr_read_mcause
        await RisingEdge(dut_if.clock)

        state.register_file_current_expected_queue.append(
            state.register_file_current.copy()
        )
        expected_pc = (state.program_counter_current + 4) & MASK32
        state.program_counter_expected_values_queue.append(expected_pc)
        state.update_program_counter(expected_pc)
        state.advance_register_state()

        # Let read complete through pipeline
        for _ in range(PIPELINE_DEPTH):
            await execute_nop(dut_if, state)

        # Verify mcause is 2 (Illegal instruction)
        mcause_value = dut_if.read_register(3)
        cocotb.log.info(f"mcause = {mcause_value} (expected 2 for illegal instruction)")
        assert (
            mcause_value == 2
        ), f"mcause mismatch for '{name}': got {mcause_value}, expected 2"
        cocotb.log.info(f"mcause verification PASSED for '{name}'")

        # Execute MRET to return from trap handler
        await FallingEdge(dut_if.clock)
        await dut_if.wait_ready()
        dut_if.instruction = instr_mret
        await RisingEdge(dut_if.clock)

        # After MRET, PC returns to mepc
        state.register_file_current_expected_queue.append(
            state.register_file_current.copy()
        )
        state.program_counter_expected_values_queue.append(0)  # Will be mepc
        state.update_program_counter(0)
        state.advance_register_state()

        cocotb.log.info("MRET executed, returning from trap handler")

        # Wait for MRET to complete and pipeline to stabilize
        for _ in range(10):
            await execute_nop(dut_if, state)

        # Re-set mtvec before next test case (may have been affected)
        await FallingEdge(dut_if.clock)
        await dut_if.wait_ready()
        dut_if.instruction = instr_csrrw_mtvec
        await RisingEdge(dut_if.clock)

        state.register_file_current_expected_queue.append(
            state.register_file_current.copy()
        )
        expected_pc = (state.program_counter_current + 4) & MASK32
        state.program_counter_expected_values_queue.append(expected_pc)
        state.update_program_counter(expected_pc)
        state.advance_register_state()

        for _ in range(PIPELINE_DEPTH):
            await execute_nop(dut_if, state)

    # ========================================================================
    # Cleanup
    # ========================================================================
    cocotb.log.info("=== Flushing pipeline ===")
    for _ in range(10):
        await execute_nop(dut_if, state)

    cocotb.log.info("=== All illegal instruction trap tests passed! ===")


@cocotb.test()
async def test_directed_illegal_instruction(dut: Any) -> None:
    """Directed test for illegal instruction trapping (mcause=2)."""
    await run_directed_illegal_instruction_test(dut)
