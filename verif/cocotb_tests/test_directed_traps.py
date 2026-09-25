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

"""Directed machine-mode trap tests.

These tests live outside the random regression because trap handling needs
exact CSR setup (mtvec, mepc, mcause), interrupt tests drive an external
signal (i_interrupts_reg), and trap/interrupt collisions need deterministic
sequences.

Tests:
    Traps and MRET:
        - ECALL: environment call from M-mode (mcause=11)
        - EBREAK: breakpoint exception (mcause=3)
        - Illegal instruction (mcause=2)
        - MRET: return from the machine-mode trap handler

    Interrupts:
        - Timer interrupt trap entry (mstatus.MIE cleared, MPIE saved)
        - MTIP swept across an MRET: the entry's mepc and MPP match the
          retirement order, and no MRET the entry flushes is taken
        - CSRSI enabling MIE with an interrupt already pending
        - Precise-interrupt sweep: mepc versus the committed prefix

Trap entry writes mepc and mcause, copies mstatus.MIE into MPIE, clears MIE,
and jumps to mtvec. MRET copies MPIE back into MIE, sets MPIE, and returns to
mepc.

Usage: ``./scripts/frost.py cocotb directed_traps``.
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

    Point mtvec at a trap handler address, run ECALL, read mepc and mcause
    back with CSR reads, return with MRET, then repeat with EBREAK. The ECALL
    checks mepc against its exact instruction PC and mcause against 11; the
    EBREAK check expects mcause 3.

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

    state.register_file_current = [0] * 32
    for i in range(1, 32):
        state.register_file_current[i] = (i * 0x11111111) & MASK32

    trap_handler_address = 0x1000  # Trap handler at 0x1000
    state.register_file_current[1] = trap_handler_address  # x1 = trap handler addr

    for i in range(1, 32):
        dut_if.write_register(i, state.register_file_current[i])

    Clock(dut_if.clock, config.clock_period_ns, unit="ns").start()

    await dut_if.reset_dut(config.reset_cycles)

    # No stores are queued, so the memory monitor fails the test on any DUT
    # store.
    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    state.register_file_previous = state.register_file_current.copy()

    # ========================================================================
    # Warmup: Let pipeline stabilize
    # ========================================================================
    cocotb.log.info("=== Warming up pipeline ===")
    for _ in range(8):
        await execute_nop(dut_if, state)

    # ========================================================================
    # Step 1: Set up mtvec (trap vector base address)
    # ========================================================================
    cocotb.log.info("=== Setting up mtvec ===")

    # CSRRW x0, mtvec, x1 - write x1 to mtvec, discard old value
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

    # Let the CSR write complete through pipeline
    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)

    # ========================================================================
    # Step 2: Execute ECALL - should trap to mtvec
    # ========================================================================
    cocotb.log.info("=== Executing ECALL ===")

    enc_ecall = TRAP_INSTRS["ecall"]
    instr_ecall = enc_ecall()

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    # cpu_tb registers instruction_from_testbench together with the current
    # fetch request. TestState starts its synthetic PC at zero, whereas the
    # DUT's directed-test reset vector is non-zero, so use the real request PC
    # that will travel with this ECALL.
    ecall_pc = int(dut.o_pc.value)
    cocotb.log.info(f"ECALL fetch request PC=0x{ecall_pc:08X}")
    dut_if.instruction = instr_ecall
    await RisingEdge(dut_if.clock)

    # ECALL redirects to mtvec with mepc = ecall_pc and mcause = 11 (ECALL
    # from M-mode). The harness PC model does not follow the flush, so the
    # expected-PC queue is fed mtvec and the CSRs are checked by reading them
    # back below.
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
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

    # x2 receives mepc once the read drains. A synchronous exception must
    # report the exact faulting instruction PC, independent of later MRET use.
    state.register_file_current_expected_queue.append(
        state.register_file_current.copy()
    )
    expected_pc = (state.program_counter_current + 4) & MASK32
    state.program_counter_expected_values_queue.append(expected_pc)
    state.update_program_counter(expected_pc)
    state.advance_register_state()

    for _ in range(PIPELINE_DEPTH):
        await execute_nop(dut_if, state)

    mepc_value = dut_if.read_register(2)
    cocotb.log.info(f"mepc = 0x{mepc_value:08X} (expected 0x{ecall_pc:08X})")
    assert mepc_value == ecall_pc, (
        f"mepc mismatch: got 0x{mepc_value:X}, expected ECALL PC 0x{ecall_pc:X}"
    )

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

    # Rewrite mtvec so this step does not depend on what the ECALL/MRET
    # sequence left behind.
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
    """Check that interrupt trap entry clears mstatus.MIE.

    On interrupt entry the hardware saves MIE (bit 3) into MPIE (bit 7) and
    clears MIE, so no further interrupt is taken inside the handler. After the
    timer source clears, no machine interrupt may stay pending.

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

    state.register_file_current = [0] * 32
    for i in range(1, 32):
        state.register_file_current[i] = (i * 0x11111111) & MASK32

    trap_handler_address = 0x1000
    state.register_file_current[1] = trap_handler_address  # x1 = trap handler addr
    state.register_file_current[2] = 0x80  # x2 = MTIE bit (bit 7 of mie)
    state.register_file_current[3] = 0x08  # x3 = MIE bit (bit 3 of mstatus)

    for i in range(1, 32):
        dut_if.write_register(i, state.register_file_current[i])

    Clock(dut_if.clock, config.clock_period_ns, unit="ns").start()

    await dut_if.reset_dut(config.reset_cycles)

    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

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

    # ========================================================================
    # Step 4: Verify mstatus.MIE is set before triggering interrupt
    # ========================================================================
    cocotb.log.info("=== Verifying mstatus before interrupt ===")

    # The CSR write is serialized, so it lands after a variable delay. Poll
    # mstatus until MIE is set, and fail the test (not just log a warning) if
    # this precondition never holds.
    for _ in range(PIPELINE_DEPTH * 3):
        await execute_nop(dut_if, state)
        mstatus_before = int(dut.device_under_test.csr_file_inst.mstatus.value)
        if (mstatus_before >> 3) & 1:
            break
    else:
        raise AssertionError(
            f"mstatus.MIE did not become 1: mstatus=0x{mstatus_before:X}"
        )

    mie_before = (mstatus_before >> 3) & 1
    mpie_before = (mstatus_before >> 7) & 1
    cocotb.log.info(
        f"Before interrupt: mstatus=0x{mstatus_before:08X}, "
        f"MIE={mie_before}, MPIE={mpie_before}"
    )

    # ========================================================================
    # Step 5: Trigger timer interrupt by setting mtip
    # ========================================================================
    cocotb.log.info("=== Triggering timer interrupt ===")

    # interrupt_t is {meip, mtip, msip} = {bit2, bit1, bit0}.
    dut.i_interrupts_reg.value = 0b010  # mtip = 1

    cocotb.log.info("Set i_interrupts_reg = 0b010 (mtip=1)")

    # ========================================================================
    # Step 6: Wait for trap to be taken and monitor mstatus
    # ========================================================================
    cocotb.log.info("=== Monitoring trap_taken and mstatus ===")

    trap_detected = False
    for cycle in range(20):
        await RisingEdge(dut_if.clock)

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

        if mie_after != 0:
            cocotb.log.error(
                f"BUG DETECTED! mstatus.MIE should be 0 after trap entry, "
                f"but got MIE={mie_after}. mstatus=0x{mstatus_after:08X}"
            )
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
    # Step 8: Clear the interrupt and verify the pending state drains
    # ========================================================================
    dut.i_interrupts_reg.value = 0b000  # Clear all interrupts

    for _ in range(10):
        await execute_nop(dut_if, state)

    trap_unit = dut.device_under_test.trap_unit_inst
    assert int(trap_unit.m_int_pending.value) == 0, (
        "machine interrupt remained pending after its source cleared"
    )
    assert int(trap_unit.o_trap_taken.value) == 0, (
        "trap re-fired after the timer source cleared"
    )

    cocotb.log.info("=== Interrupt trap mstatus test PASSED! ===")


@cocotb.test()
async def test_directed_interrupt_trap_mstatus(dut: Any) -> None:
    """Check that interrupt trap entry clears mstatus.MIE."""
    await run_directed_interrupt_trap_test(dut)


# ============================================================================
# MRET + Timer Interrupt Ordering Sweep
# ============================================================================


MRET_RACE_TARGET = 0x2000  # mepc written before the MRET
MSTATUS_MIE = 1 << 3
MSTATUS_MPIE = 1 << 7


async def sweep_mret_interrupt_race(
    dut: Any, config: TestConfig | None = None
) -> list[dict[str, Any]]:
    """Sweep MTIP's rise across an MRET and record what each offset retired.

    The core runs in M-mode with mstatus.MIE=1, MPIE=1, MPP=U, mie.MTIE=1,
    mtvec=0x1000 and mepc=0x2000, then an MRET is fed. For each offset in
    0..23, MTIP rises that many cycles after the MRET enters the feed and stays
    high. Each result holds the cycles of the interrupt takes and MRET takes
    after the feed, mepc/mcause/mstatus sampled right after the first take,
    and the mepc expected from the retirements before that take: the PC after
    the last retired instruction (all are 32 bits wide), or the MRET target if
    the MRET retired last.
    """
    from encoders.op_tables import I_ALU, CSRS, TRAP_INSTRS
    from encoders.instruction_encode import CSRAddress

    if config is None:
        config = TestConfig(num_loops=100)

    nop = 0x00000013
    instr_mret = TRAP_INSTRS["mret"]()
    fire_offsets = range(0, 24)
    window = 40  # feed steps after the MRET before giving up on a take
    post_trap = 8  # feed steps to keep watching after the first take

    enc_addi = I_ALU["addi"][0]
    enc_slli = I_ALU["slli"][0]
    enc_csrrw = CSRS["csrrw"]

    dut_if = DUTInterface(dut)
    clk = dut_if.clock
    d = dut.device_under_test
    trap_unit = d.trap_unit_inst
    csr = d.csr_file_inst
    Clock(clk, config.clock_period_ns, unit="ns").start()

    # Retirements and control takes, sampled after every rising edge so that
    # stall cycles are not skipped, plus the CSR state one cycle after each
    # take (when the entry's CSR writes are visible).
    events: list[tuple[int, str, int]] = []
    entry_state: list[tuple[int, int, int]] = []
    both_high: list[int] = []
    cycle = [0]

    async def monitor() -> None:
        capture = False
        while True:
            await RisingEdge(clk)
            cycle[0] += 1
            n = cycle[0]
            if capture:
                entry_state.append(
                    (int(csr.mepc.value), int(csr.mcause.value), int(csr.mstatus.value))
                )
            capture = False
            if int(d.dbg_commit_valid.value):
                events.append((n, "commit", int(d.dbg_commit_pc.value)))
            if int(d.dbg_commit_2_valid.value):
                events.append((n, "commit", int(d.dbg_commit_2_pc.value)))
            mret_taken = int(trap_unit.o_mret_taken.value)
            trap_taken = int(trap_unit.o_trap_taken.value)
            if mret_taken and trap_taken:
                both_high.append(n)
            if mret_taken:
                events.append((n, "mret", 0))
            if trap_taken:
                events.append((n, "trap", 0))
                capture = True

    cocotb.start_soon(monitor())

    async def feed(instr: int) -> None:
        await FallingEdge(clk)
        await dut_if.wait_ready()
        dut_if.instruction = instr
        await RisingEdge(clk)

    async def raise_mtip_after(cycles: int) -> None:
        """Raise mtip `cycles` falling edges after the MRET is presented.

        Counting clock edges here, not feed steps, keeps the offset exact
        when wait_ready() stalls the feed.
        """
        for _ in range(cycles):
            await FallingEdge(clk)
        dut.i_interrupts_reg.value = 0b010  # mtip

    async def setup() -> None:
        """Reset, then set mtvec, mepc, mie.MTIE and mstatus with fed instructions."""
        dut.i_interrupts_reg.value = 0
        dut_if.instruction = nop
        await dut_if.reset_dut(config.reset_cycles)
        events.clear()
        entry_state.clear()
        for _ in range(6):
            await feed(nop)
        await feed(enc_addi(1, 0, 1))
        await feed(enc_slli(1, 1, 12))  # x1 = mtvec = 0x1000
        await feed(enc_addi(4, 0, 1))
        await feed(enc_slli(4, 4, 13))  # x4 = mepc = 0x2000
        await feed(enc_addi(2, 0, 0x80))  # x2 = mie.MTIE
        await feed(enc_addi(3, 0, MSTATUS_MIE | MSTATUS_MPIE))  # x3: MPP = U
        for _ in range(4):
            await feed(nop)
        for csr_address, reg in (
            (CSRAddress.MTVEC, 1),
            (CSRAddress.MEPC, 4),
            (CSRAddress.MIE, 2),
            (CSRAddress.MSTATUS, 3),
        ):
            await feed(enc_csrrw(0, csr_address, reg))
            for _ in range(4):
                await feed(nop)
        # The mstatus write lands after a variable delay; wait for MIE.
        for _ in range(64):
            if int(csr.mstatus.value) & MSTATUS_MIE:
                break
            await feed(nop)
        else:
            raise AssertionError("mstatus.MIE never became 1 during setup")
        for _ in range(4):
            await feed(nop)

    results: list[dict[str, Any]] = []
    for fire_offset in fire_offsets:
        await setup()
        start = cycle[0]
        first_trap_c: int | None = None
        injector = None
        for c in range(window + post_trap):
            await FallingEdge(clk)
            await dut_if.wait_ready()
            dut_if.instruction = instr_mret if c == 0 else nop
            if c == 0:
                injector = cocotb.start_soon(raise_mtip_after(fire_offset))
            await RisingEdge(clk)
            if first_trap_c is None and any(
                kind == "trap" and n > start for n, kind, _ in events
            ):
                first_trap_c = c
            if first_trap_c is not None and c >= first_trap_c + post_trap:
                break
        if injector is not None and not injector.done():
            injector.cancel()
        dut.i_interrupts_reg.value = 0

        traps = [n for n, kind, _ in events if kind == "trap" and n > start]
        mrets = [n for n, kind, _ in events if kind == "mret" and n > start]
        want_mepc = None
        if traps:
            for n, kind, pc in events:
                if n >= traps[0]:
                    break
                if kind == "commit":
                    want_mepc = pc + 4
                elif kind == "mret":
                    want_mepc = MRET_RACE_TARGET
        results.append(
            {
                "fire_offset": fire_offset,
                "traps": [n - start for n in traps],
                "mrets": [n - start for n in mrets],
                "entry": entry_state[0] if entry_state else None,
                "want_mepc": want_mepc,
            }
        )
        entry = entry_state[0] if entry_state else (0, 0, 0)
        cocotb.log.info(
            f"offset={fire_offset:2d} takes={results[-1]['traps']} "
            f"mrets={results[-1]['mrets']} mepc=0x{entry[0]:x} "
            f"want=0x{(want_mepc or 0):x} mcause=0x{entry[1]:x} mstatus=0x{entry[2]:x}"
        )

    assert not both_high, (
        f"o_trap_taken and o_mret_taken both high at cycles {both_high}"
    )
    return results


@cocotb.test()
async def test_directed_mret_interrupt_race(dut: Any) -> None:
    """Sweep MTIP across an MRET and check the first interrupt entry.

    At every offset the interrupt must be taken (none lost), as a machine
    timer interrupt with MIE=0 and MPIE=1 after entry, and mepc and MPP must
    match the order: taken before the MRET retires, mepc is the PC after the
    last retired instruction and MPP=M; taken after it, mepc is the MRET
    target and MPP=U. The sweep must produce both orders.
    """
    results = await sweep_mret_interrupt_race(dut)
    timer_cause = (1 << 63) | 7
    orders: dict[str, list[int]] = {"interrupt first": [], "mret first": []}
    for r in results:
        offset = r["fire_offset"]
        assert r["traps"], f"offset {offset}: no interrupt taken (mtip stays high)"
        assert r["entry"] is not None, f"offset {offset}: no CSR state after the take"
        mepc, mcause, mstatus = r["entry"]
        mret_first = any(n < r["traps"][0] for n in r["mrets"])
        order = "mret first" if mret_first else "interrupt first"
        mpp = (mstatus >> 11) & 0b11
        assert mcause == timer_cause, (
            f"offset {offset}: mcause=0x{mcause:x}, want machine timer 0x{timer_cause:x}"
        )
        assert mepc == r["want_mepc"], (
            f"offset {offset} ({order}): mepc=0x{mepc:x}, want 0x{(r['want_mepc'] or 0):x}, "
            f"the PC after the last instruction retired before the take"
        )
        if mret_first:
            assert mepc == MRET_RACE_TARGET, (
                f"offset {offset}: an interrupt after the MRET must save its target"
            )
            assert mpp == 0, f"offset {offset}: MPP={mpp}, want U after the MRET"
        else:
            assert mpp == 3, (
                f"offset {offset}: MPP={mpp}, want M (taken before the MRET)"
            )
        assert not (mstatus & MSTATUS_MIE), (
            f"offset {offset}: MIE still set after entry"
        )
        assert mstatus & MSTATUS_MPIE, f"offset {offset}: MPIE not set after entry"
        orders[order].append(offset)
    cocotb.log.info(f"Orders by fire offset: {orders}")
    for order, offsets in orders.items():
        assert offsets, (
            f"no offset produced '{order}'; widen the sweep so it crosses the MRET "
            f"take (orders seen: {orders})"
        )


@cocotb.test()
async def test_directed_mret_interrupt_race_no_xret_after_take(dut: Any) -> None:
    """Check that no MRET and no second interrupt are taken after the entry.

    An MRET dispatched in the take cycle can be the ROB head in the entry's
    flush cycle; the flush removes it, so the trap unit must not take it
    there. Once the entry clears MIE, the interrupt must not be taken again.
    """
    results = await sweep_mret_interrupt_race(dut)
    extra: list[tuple[int, list[int], list[int]]] = []
    for r in results:
        if not r["traps"]:
            continue  # test_directed_mret_interrupt_race checks that each offset traps
        first = r["traps"][0]
        if any(n > first for n in r["mrets"]) or len(r["traps"]) != 1:
            extra.append((r["fire_offset"], r["traps"], r["mrets"]))
    assert not extra, (
        "an MRET or a second interrupt was taken after the entry "
        f"(offset, takes, mrets): {extra}"
    )


# ============================================================================
# Directed Test for CSRSI enables MIE while interrupt pending
# ============================================================================


async def run_directed_csrsi_enable_mie_test(
    dut: Any, config: TestConfig | None = None
) -> None:
    """Directed test for CSRSI enabling MIE while interrupt is already pending.

    A timer interrupt is pending with MIE=0, and CSRSI mstatus, 0x8 enables
    MIE. The interrupt must be taken once the write lands, and trap entry
    must leave MIE=0 and MPIE=1.
    """
    from encoders.op_tables import CSRS
    from encoders.instruction_encode import CSRAddress

    if config is None:
        config = TestConfig(num_loops=100)

    dut_if = DUTInterface(dut)
    state = TestState()
    dut_if.instruction = 0x00000013  # 32-bit NOP (addi x0, x0, 0)

    state.register_file_current = [0] * 32
    for i in range(1, 32):
        state.register_file_current[i] = (i * 0x11111111) & MASK32

    trap_handler_address = 0x1000
    state.register_file_current[1] = trap_handler_address
    state.register_file_current[2] = 0x80  # MTIE

    for i in range(1, 32):
        dut_if.write_register(i, state.register_file_current[i])

    Clock(dut_if.clock, config.clock_period_ns, unit="ns").start()
    await dut_if.reset_dut(config.reset_cycles)

    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

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

    # Assert the timer interrupt before enabling MIE.
    cocotb.log.info("=== Asserting timer interrupt (MIE still 0) ===")
    dut.i_interrupts_reg.value = 0b010  # mtip = 1

    # Check that MIE is still 0. This test already depends on the exposed
    # hierarchy, so a missing signal or failed precondition must fail the test.
    mstatus_before = int(dut.device_under_test.csr_file_inst.mstatus.value)
    cocotb.log.info(f"Before CSRSI: mstatus=0x{mstatus_before:08X}")
    assert (mstatus_before & 0x8) == 0, "MIE should be 0 before CSRSI!"

    # A few NOPs with the interrupt pending and MIE=0; no trap should fire.
    for _ in range(3):
        await execute_nop(dut_if, state)

    # Verify no trap has been taken (MIE=0).
    trap_taken = int(dut.device_under_test.trap_unit_inst.o_trap_taken.value)
    cocotb.log.info(f"Before CSRSI: trap_taken={trap_taken} (should be 0)")
    assert trap_taken == 0, "Trap should not be taken with MIE=0!"

    # Execute CSRSI mstatus, 0x8 to enable MIE
    cocotb.log.info("=== Executing CSRSI mstatus, 0x8 (enable MIE) ===")
    enc_csrsi = CSRS["csrrsi"]
    instr_csrsi_mstatus = enc_csrsi(0, CSRAddress.MSTATUS, 0x8)  # Set bit 3 (MIE)

    await FallingEdge(dut_if.clock)
    await dut_if.wait_ready()
    dut_if.instruction = instr_csrsi_mstatus
    await RisingEdge(dut_if.clock)
    # Park a NOP so exactly one CSRSI enters the pipe (the harness keeps
    # presenting dut_if.instruction every fetch; without this the trap handler
    # would fetch CSRSIs and re-enable MIE in a trap loop).
    dut_if.instruction = 0x00000013

    # Poll for the trap. A CSR instruction is serialized: it waits for the ROB
    # head, runs the csr_done handshake, and commits, and its write lands from
    # the registered commit bus. Only then is the pending interrupt taken, so
    # the delay varies; the budget is generous.
    cocotb.log.info("=== Waiting for CSRSI commit + interrupt trap ===")
    trap_seen_cycle = -1
    for cycle in range(100):
        await RisingEdge(dut_if.clock)
        try:
            trap_taken = int(dut.device_under_test.trap_unit_inst.o_trap_taken.value)
            mstatus = int(dut.device_under_test.csr_file_inst.mstatus.value)
            csr_fire = int(dut.device_under_test.csr_commit_fire.value)
            if csr_fire or trap_taken:
                cocotb.log.info(
                    f"Cycle {cycle}: trap_taken={trap_taken}, "
                    f"csr_commit_fire={csr_fire}, mstatus=0x{mstatus:08X}"
                )
            if trap_taken:
                trap_seen_cycle = cycle
                cocotb.log.info(f">>> Trap detected at cycle {cycle}")
                break
        except Exception as e:
            cocotb.log.warning(f"Cycle {cycle}: Could not read signals: {e}")

    assert trap_seen_cycle >= 0, (
        "CSRSI+TRAP BUG: no trap taken within 100 cycles of the CSRSI "
        "(MIE enable never took effect or pending interrupt not delivered)"
    )

    # mstatus updates on the edge after trap_taken asserts; give it two edges
    # so the registered trap state settles before the final check.
    await RisingEdge(dut_if.clock)
    await RisingEdge(dut_if.clock)

    try:
        mstatus_final = int(dut.device_under_test.csr_file_inst.mstatus.value)
        mie_final = (mstatus_final >> 3) & 1
        mpie_final = (mstatus_final >> 7) & 1
        cocotb.log.info(
            f"Final: mstatus=0x{mstatus_final:08X}, MIE={mie_final}, MPIE={mpie_final}"
        )

        if mie_final != 0:
            cocotb.log.error(
                f"BUG: MIE should be 0 after trap entry, got MIE={mie_final}! "
                f"mstatus=0x{mstatus_final:08X}"
            )

        assert mie_final == 0, (
            f"CSRSI+TRAP BUG: MIE should be 0 after trap! Got mstatus=0x{mstatus_final:08X}"
        )
        assert mpie_final == 1, (
            f"CSRSI+TRAP BUG: MPIE should be 1! Got mstatus=0x{mstatus_final:08X}"
        )

        cocotb.log.info("SUCCESS: MIE correctly cleared after CSRSI + trap!")

    except Exception as e:
        cocotb.log.error(f"Final check failed: {e}")
        raise

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

    Inject encodings that match no RISC-V instruction and, for each one,
    assert that mcause reads 2, then MRET back so the next case can run.

    Illegal encodings tested:
        - Unknown opcode (0x7F, all ones in the opcode field)
        - Reserved funct3 in BRANCH (funct3=010)
        - Reserved funct7 in OP (funct7=0x7F, funct3=000)
        - Reserved funct3 in LOAD (funct3=111, reserved at both XLENs;
          011 is a legal LD at RV64)
        - Reserved funct3 in STORE (funct3=111, reserved at both XLENs;
          011 is a legal SD at RV64)
        - Reserved rounding mode rm=101 on FADD.S
        - Reserved rounding mode rm=110 on FMADD.S

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

    state.register_file_current = [0] * 32
    for i in range(1, 32):
        state.register_file_current[i] = (i * 0x11111111) & MASK32

    trap_handler_address = 0x1000  # Trap handler at 0x1000
    state.register_file_current[1] = trap_handler_address  # x1 = trap handler addr

    for i in range(1, 32):
        dut_if.write_register(i, state.register_file_current[i])

    Clock(dut_if.clock, config.clock_period_ns, unit="ns").start()

    await dut_if.reset_dut(config.reset_cycles)

    # No stores are queued, so the memory monitor fails the test on any DUT
    # store.
    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor(
            state.memory_write_data_expected_queue,
            state.memory_write_address_expected_queue,
        )
    )

    state.register_file_previous = state.register_file_current.copy()

    # ========================================================================
    # Warmup: Let pipeline stabilize
    # ========================================================================
    cocotb.log.info("=== Warming up pipeline ===")
    for _ in range(8):
        await execute_nop(dut_if, state)

    # ========================================================================
    # Step 1: Set up mtvec (trap vector base address)
    # ========================================================================
    cocotb.log.info("=== Setting up mtvec ===")

    # CSRRW x0, mtvec, x1 - write x1 to mtvec, discard old value
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
        # funct3=111 is reserved in LOAD and STORE at both XLENs. Do not use
        # 011: at RV64 it is LD/SD, a legal 8-byte access that does not trap.
        ("bad funct3=111 in LOAD", IType.encode(0, 0, 0b111, 0, 0x03)),
        ("bad funct3=111 in STORE", SType.encode(0, 0, 0, 0b111, 0x23)),
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

        illegal_pc = state.program_counter_current

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
        assert mcause_value == 2, (
            f"mcause mismatch for '{name}': got {mcause_value}, expected 2"
        )
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

        # Rewrite mtvec so the next case does not depend on what this one left
        # behind.
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


# ============================================================================
# Directed Test for Precise Interrupt Entry (mepc off-by-one detector)
# ============================================================================
#
# An asynchronous timer interrupt must leave precise state: mepc (taken from
# interrupt_resume_pc in cpu_ooo) and the set of retired instructions must
# agree, so no instruction may commit in the o_trap_taken cycle. trap_unit
# arms each interrupt a cycle early so the ROB's commit hold is already active
# on the take cycle.
#
# Prefix invariant: at trap entry the architectural regfile reflects exactly
# the instructions with PC < mepc. Every such instruction's destination
# register holds its marker, and no instruction with PC >= mepc has its marker
# visible. The test sweeps the interrupt fire cycle across a stream of
# distinct register-writing ops in a single simulation and flags any offset
# where the invariant breaks or no trap is taken.
#
# The architectural integer regfile is a multi-write distributed RAM
# (generic_regfile -> mwp_dist_ram) with a per-address live-value table, so a
# register's committed value is g_banks[lvt[r]].u_bank.ram[r] on read port 0.


async def run_directed_interrupt_commit_race_test(
    dut: Any, config: TestConfig | None = None, mode: str = "alu"
) -> None:
    """Sweep an async timer interrupt cycle-by-cycle over a register-writing stream.

    Every offset must take the interrupt: mtip stays high from its fire cycle
    to the end of the observation window, with mie.MTIE and mstatus.MIE set.
    At each offset the trap-entry precise-state prefix invariant must hold.

    mode="alu":  the stream is `addi xK, x0, marker`; the result comes from
                 the ALU.
    mode="load": the stream is `lw xK, off(x4)`; the result comes through the
                 load queue and data memory.
    """
    from encoders.op_tables import I_ALU, CSRS, LOADS
    from encoders.instruction_encode import CSRAddress

    if config is None:
        config = TestConfig(num_loops=100)

    # ---- parameters --------------------------------------------------------
    nop = 0x00000013
    base_reg = 5  # stream writes x5..x{4+n_stream}
    n_stream = 27  # x5..x31
    warmup = 6
    gap = 4  # NOPs between serialized CSR writes
    obs = 56  # stream + observation cycles per offset
    post_trap = 8  # cycles to keep observing after o_trap_taken
    fire_lo, fire_hi = 0, 40
    mem_base = 0x400  # byte base of the load region (x4); BRAM, non-cached

    enc_addi = I_ALU["addi"][0]
    enc_slli = I_ALU["slli"][0]
    enc_csrrw = CSRS["csrrw"]
    enc_lw = LOADS["lw"][0]

    # Iteration-unique expected destination value: distinct per (stream index,
    # generation) and never 0, so a leftover value from a prior sweep iteration
    # can never masquerade as a commit in the current one (neither the regfile
    # RAM nor the data BRAM is reset between runs).
    def expected_val(i: int, gen: int) -> int:
        if mode == "load":
            # 32-bit memory word loaded into the dest register.
            return (0x19990000 | ((gen & 0xFF) << 8) | (i & 0xFF)) & MASK32
        return 0x40 + gen * 48 + i  # 12-bit signed addi immediate: keep <= 2047

    def stream_instr(c: int, gen: int) -> int:
        if mode == "load":
            return enc_lw(base_reg + c, 4, c * 4)  # lw x{5+c}, (c*4)(x4)
        return enc_addi(base_reg + c, 0, expected_val(c, gen))

    dut_if = DUTInterface(dut)
    clk = dut_if.clock
    d = dut.device_under_test

    def ri(handle: Any) -> int | None:
        try:
            return int(handle.value)
        except Exception:
            return None

    # Read port 0 of the architectural integer regfile (multi-write banked RAM).
    def _read_port0() -> Any:
        return d.ooo_register_files_inst.regfile_inst.gen_read_port[
            0
        ].gen_multi_write.read_port_ram

    def read_reg(r: int) -> int | None:
        if r == 0:
            return 0
        try:
            rp = _read_port0()
            sel = int(rp.lvt[r].value)
            return int(rp.g_banks[sel].u_bank.ram[r].value) & MASK32
        except Exception as e:  # pragma: no cover - surfaced as a clear failure
            raise AssertionError(
                f"regfile read path failed for x{r}: {e}. "
                f"Expected ooo_register_files_inst.regfile_inst."
                f"gen_read_port[0].gen_multi_write.read_port_ram.{{lvt,g_banks[*].u_bank.ram}}"
            ) from e

    # one clock for the whole sweep
    Clock(clk, config.clock_period_ns, unit="ns").start()

    async def feed(instr: int) -> None:
        await FallingEdge(clk)
        await dut_if.wait_ready()
        dut_if.instruction = instr
        await RisingEdge(clk)

    gen_counter = {"g": 0}

    async def setup_phase() -> int:
        """Reset and set mtvec, mie.MTIE, and mstatus.MIE with fed instructions.

        i_interrupts_reg stays 0, so nothing fires yet. Returns the new
        generation number.
        """
        gen = gen_counter["g"]
        gen_counter["g"] += 1
        dut.i_interrupts_reg.value = 0
        dut_if.instruction = nop
        await dut_if.reset_dut(config.reset_cycles)
        for _ in range(6):
            await feed(nop)
        # Preload the load region with this generation's expected values (the
        # data BRAM persists across reset, so refresh it every iteration).
        # Whole dword rows per deposit: word-granule RMW pokes to the same
        # row within one delta would lose the first word (queued deposits).
        if mode == "load":
            from models.memory_model import poke_dut_memory_dword

            for i in range(0, n_stream, 2):
                low_word = expected_val(i, gen)
                high_word = expected_val(i + 1, gen) if i + 1 < n_stream else 0
                poke_dut_memory_dword(
                    dut, mem_base + 4 * i, (high_word << 32) | low_word
                )
        # Construct CSR operands (no deposits needed): x1=mtvec(0x1000),
        # x2=mie.MTIE(0x80), x3=mstatus.MIE(0x08), x4=load base.
        await feed(enc_addi(1, 0, 1))  # x1 = 1
        await feed(enc_slli(1, 1, 12))  # x1 = 0x1000
        await feed(enc_addi(2, 0, 0x80))  # x2 = MTIE
        await feed(enc_addi(3, 0, 0x08))  # x3 = MIE
        await feed(enc_addi(4, 0, mem_base))  # x4 = load base address
        for _ in range(warmup):
            await feed(nop)
        await feed(enc_csrrw(0, CSRAddress.MTVEC, 1))
        for _ in range(gap):
            await feed(nop)
        await feed(enc_csrrw(0, CSRAddress.MIE, 2))
        for _ in range(gap):
            await feed(nop)
        await feed(enc_csrrw(0, CSRAddress.MSTATUS, 3))
        for _ in range(gap):
            await feed(nop)
        return gen

    async def calibrate() -> list[int]:
        """Run the stream with no interrupt to learn each stream instruction's PC.

        Captures PCs from the regfile write ports, checks that they are
        contiguous, and confirms a clean run commits every marker.
        """
        gen = await setup_phase()
        reg_pc: dict[int, int] = {}
        for c in range(obs):
            await FallingEdge(clk)
            await dut_if.wait_ready()
            dut_if.instruction = stream_instr(c, gen) if c < n_stream else nop
            await RisingEdge(clk)
            we0, a0, pc0 = (
                ri(d.dbg_port0_int_we),
                ri(d.dbg_port0_int_addr),
                ri(d.dbg_rob_commit_reg_pc),
            )
            we1, a1, pc1 = (
                ri(d.dbg_port1_int_we),
                ri(d.dbg_port1_int_addr),
                ri(d.dbg_rob_commit_2_reg_pc),
            )
            if (
                we0
                and a0 is not None
                and pc0 is not None
                and base_reg <= a0 < base_reg + n_stream
            ):
                reg_pc.setdefault(a0, pc0)
            if (
                we1
                and a1 is not None
                and pc1 is not None
                and base_reg <= a1 < base_reg + n_stream
            ):
                reg_pc.setdefault(a1, pc1)
        missing = [
            base_reg + i for i in range(n_stream) if (base_reg + i) not in reg_pc
        ]
        assert not missing, f"calibration missed regfile writes for {missing}: {reg_pc}"
        stream_pcs = [reg_pc[base_reg + i] for i in range(n_stream)]
        for i in range(1, n_stream):
            assert stream_pcs[i] == stream_pcs[0] + 4 * i, (
                f"stream PCs not contiguous: {[hex(p) for p in stream_pcs]}"
            )
        for i in range(n_stream):
            v = read_reg(base_reg + i)
            assert v == expected_val(i, gen), (
                f"clean-run marker mismatch x{base_reg + i}: "
                f"got {v:#x} want {expected_val(i, gen):#x}"
            )
        cocotb.log.info(
            f"Calibrated stream PCs x{base_reg}..x{base_reg + n_stream - 1}: "
            f"{stream_pcs[0]:#x}..{stream_pcs[-1]:#x} (step 4); clean run committed "
            f"all {n_stream} markers."
        )
        return stream_pcs

    async def run_offset(fire_offset: int, stream_pcs: list[int]) -> dict[str, Any]:
        gen = await setup_phase()
        trap_c: int | None = None
        racer: dict[str, Any] | None = None
        resume_at_trap: int | None = None
        last_mepc: int | None = None
        for c in range(obs):
            await FallingEdge(clk)
            await dut_if.wait_ready()
            # Stop injecting new stream writes once the trap is taken so the
            # post-trap handler (NOPs) cannot perturb the x5..x31 snapshot.
            if c < n_stream and trap_c is None:
                dut_if.instruction = stream_instr(c, gen)
            else:
                dut_if.instruction = nop
            # Cycle-exact injection: assert mtip for the cycle ending at this edge.
            if c == fire_offset:
                dut.i_interrupts_reg.value = 0b010
            await RisingEdge(clk)
            ttr = ri(d.dbg_trap_taken_raw)
            mepc = ri(d.csr_file_inst.mepc)
            if mepc is not None:
                last_mepc = mepc
            if trap_c is None and ttr == 1:
                trap_c = c
                resume_at_trap = ri(d.dbg_interrupt_resume_pc)
                racer = dict(
                    valid=ri(d.dbg_commit_valid),
                    pc=ri(d.dbg_commit_pc),
                    dest_valid=ri(d.dbg_commit_dest_valid),
                    dest_reg=ri(d.dbg_commit_dest_reg),
                    value=ri(d.dbg_commit_value),
                    c2_valid=ri(d.dbg_commit_2_valid),
                    c2_pc=ri(d.dbg_commit_2_pc),
                )
            if trap_c is not None and c >= trap_c + post_trap:
                break
        mepc_final = ri(d.csr_file_inst.mepc)
        if mepc_final is None:
            mepc_final = last_mepc
        regs = {base_reg + i: read_reg(base_reg + i) for i in range(n_stream)}
        dut.i_interrupts_reg.value = 0
        return dict(
            fire_offset=fire_offset,
            gen=gen,
            trap_c=trap_c,
            mepc=mepc_final,
            resume_at_trap=resume_at_trap,
            racer=racer,
            regs=regs,
        )

    def analyze(res: dict[str, Any], stream_pcs: list[int]) -> dict[str, Any]:
        gen = res["gen"]
        mepc = res["mepc"]
        regs = res["regs"]
        committed = [
            regs[base_reg + i] == expected_val(i, gen) for i in range(n_stream)
        ]
        ncommit = sum(committed)
        longest_prefix = 0
        while longest_prefix < n_stream and committed[longest_prefix]:
            longest_prefix += 1
        lost: list[int] = []
        leaked: list[int] = []
        r: int | None = None
        no_trap = res["trap_c"] is None
        if mepc is not None and not no_trap:
            # Expected #committed stream instrs == those with PC < mepc.
            r = sum(1 for pc in stream_pcs if pc < mepc)
            for i in range(n_stream):
                if stream_pcs[i] < mepc and not committed[i]:
                    lost.append(i)  # mepc skipped it, but its write is missing
                elif stream_pcs[i] >= mepc and committed[i]:
                    leaked.append(i)  # committed though mepc resumes at/before it
        violation = bool(lost or leaked) and not no_trap
        return dict(
            committed=committed,
            ncommit=ncommit,
            longest_prefix=longest_prefix,
            R=r,
            lost=lost,
            leaked=leaked,
            violation=violation,
            no_trap=no_trap,
        )

    # ---- sweep -------------------------------------------------------------
    cocotb.log.info(f"=== Precise-interrupt sweep: stream mode={mode} ===")
    cocotb.log.info("=== Calibrating clean stream PCs (no interrupt) ===")
    stream_pcs = await calibrate()

    cocotb.log.info("=== Sweeping interrupt fire-cycle (single simulation) ===")
    results: list[dict[str, Any]] = []
    for fire_offset in range(fire_lo, fire_hi):
        res = await run_offset(fire_offset, stream_pcs)
        an = analyze(res, stream_pcs)
        res["an"] = an
        results.append(res)

        def _h(x: int | None) -> str:
            return "None" if x is None else f"0x{x:08x}"

        racer = res["racer"] or {}
        tag = (
            "  <<< VIOLATION"
            if an["violation"]
            else ("  (no trap)" if an["no_trap"] else "")
        )
        cocotb.log.info(
            f"offset={fire_offset:2d} trap_c={res['trap_c']} mepc={_h(res['mepc'])} "
            f"resume@trap={_h(res['resume_at_trap'])} R={an['R']} "
            f"committed={an['ncommit']} prefix={an['longest_prefix']} "
            f"lost={an['lost']} leaked={an['leaked']} "
            f"racer[pc={_h(racer.get('pc'))} x{racer.get('dest_reg')}={_h(racer.get('value'))} "
            f"v={racer.get('valid')}]{tag}"
        )

    violations = [r for r in results if r["an"]["violation"]]

    # ---- detailed evidence for each violation ------------------------------
    for r in violations[:8]:
        an = r["an"]
        gen = r["gen"]
        fo = r["fire_offset"]
        cocotb.log.error(
            f"--- VIOLATION fire_offset={fo} mepc=0x{r['mepc']:08x} "
            f"resume_pc@trap="
            f"{f'0x{r["resume_at_trap"]:08x}' if r['resume_at_trap'] is not None else None} ---"
        )
        for i in an["lost"]:
            reg = base_reg + i
            cocotb.log.error(
                f"   LOST  x{reg} (stream #{i}, pc=0x{stream_pcs[i]:08x} < mepc): "
                f"expected marker 0x{expected_val(i, gen):08x}, regfile=0x{r['regs'][reg]:08x} "
                f"-- mepc advanced past this instruction but its write is missing"
            )
        for i in an["leaked"]:
            reg = base_reg + i
            cocotb.log.error(
                f"   LEAK  x{reg} (stream #{i}, pc=0x{stream_pcs[i]:08x} >= mepc): "
                f"regfile=0x{r['regs'][reg]:08x} == marker 0x{expected_val(i, gen):08x} "
                f"-- committed although mepc resumes at/before it (re-execution)"
            )
        rc = r["racer"]
        if rc and rc.get("valid"):
            cocotb.log.error(
                f"   trap-cycle commit: pc=0x{rc['pc']:08x} "
                f"x{rc['dest_reg']}<=0x{(rc['value'] or 0):08x} -- committed in the "
                f"o_trap_taken cycle"
            )

    # ---- per-offset mepc table (every offset, passing or not) --------------
    cocotb.log.info("=== Per-offset mepc / commit summary ===")
    for r in results:
        an = r["an"]
        cocotb.log.info(
            f"  offset={r['fire_offset']:2d} "
            f"mepc={f'0x{r["mepc"]:08x}' if r['mepc'] is not None else None} "
            f"committed={an['ncommit']} prefix={an['longest_prefix']} "
            f"violation={an['violation']}"
        )

    n_trapped = sum(1 for r in results if not r["an"]["no_trap"])
    cocotb.log.info(
        f"Swept {len(results)} offsets ({n_trapped} took the trap); "
        f"{len(violations)} violated the prefix invariant."
    )

    no_trap_offsets = [r["fire_offset"] for r in results if r["an"]["no_trap"]]
    assert not no_trap_offsets, (
        f"LOST INTERRUPT (mode={mode}): {len(no_trap_offsets)}/{len(results)} fire "
        f"offsets took no trap within the {obs}-cycle window: {no_trap_offsets}. mtip "
        f"stays high from the fire cycle with mie.MTIE and mstatus.MIE set, so every "
        f"offset must trap."
    )
    assert not violations, (
        f"PRECISE-INTERRUPT VIOLATION (mode={mode}): {len(violations)}/{len(results)} "
        f"interrupt fire-offsets violate the trap-entry prefix invariant (architectural "
        f"regfile != instructions with PC < mepc). First failing "
        f"offset={violations[0]['fire_offset']}, mepc=0x{violations[0]['mepc']:08x}, "
        f"lost={violations[0]['an']['lost']}, leaked={violations[0]['an']['leaked']}. "
        f"See the log above for the lost and leaked registers (expected vs "
        f"actual value) and any commit in the trap cycle."
    )
    cocotb.log.info(
        f"=== mode={mode}: no violations across all fire offsets; "
        f"trap-entry prefix invariant holds. ==="
    )


@cocotb.test()
async def test_directed_interrupt_commit_race(dut: Any) -> None:
    """Sweep an async M-timer interrupt across an ALU stream.

    Every fire cycle must take the interrupt, and the architectural regfile at
    trap entry must reflect exactly the instructions with PC < mepc
    (precise-state prefix invariant).
    """
    await run_directed_interrupt_commit_race_test(dut, mode="alu")


@cocotb.test()
async def test_directed_interrupt_commit_race_loads(dut: Any) -> None:
    """Run the same precise-interrupt sweep across a stream of loads.

    The stream is `lw` instructions whose results come through the load queue
    and data memory.
    """
    await run_directed_interrupt_commit_race_test(dut, mode="load")
