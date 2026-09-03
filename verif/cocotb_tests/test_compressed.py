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

"""Directed tests for RISC-V C-extension instructions.

Compressed instructions are 16 bits wide, sit on 2-byte boundaries, and are
identified by bits [1:0] != 0b11. Most common instructions have a compressed
form, and some of those reach only registers x8-x15 (s0-s1/a0-a5).

Compressed instruction categories:
    ┌─────────────────────────────────────────────────────────────────┐
    │ Register Operations (full register set x1-x31):                │
    │   C.LI   rd, imm    - Load immediate (rd = sign_extend(imm))   │
    │   C.ADDI rd, nzimm  - Add immediate (rd = rd + nzimm)          │
    │   C.MV   rd, rs2    - Move register (rd = rs2)                 │
    │   C.ADD  rd, rs2    - Add register (rd = rd + rs2)             │
    │   C.SLLI rd, shamt  - Shift left logical (rd = rd << shamt)    │
    │                                                                 │
    │ Register Operations (limited to x8-x15 only):                   │
    │   C.SUB  rd', rs2'  - Subtract (rd' = rd' - rs2')              │
    │   C.AND  rd', rs2'  - AND (rd' = rd' & rs2')                   │
    │   C.OR   rd', rs2'  - OR (rd' = rd' | rs2')                    │
    │   C.XOR  rd', rs2'  - XOR (rd' = rd' ^ rs2')                   │
    │   C.SRLI rd', shamt - Shift right logical                      │
    │   C.SRAI rd', shamt - Shift right arithmetic                   │
    │   C.ANDI rd', imm   - AND immediate                            │
    └─────────────────────────────────────────────────────────────────┘

    rd' and rs2' are the 3-bit compressed register encoding: add 8 to get the
    architectural register number, which is why they cover only x8-x15.

Each test runs one compressed instruction type and reads back the register
value it commits. Negative immediates and the shift forms are covered.

Usage: ``cd tests && ./test_run_cocotb.py compressed``.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from typing import Any

from config import MASK32, PIPELINE_DEPTH
from models.memory_model import MemoryModel
from cocotb_tests.test_helpers import DUTInterface
from cocotb_tests.test_common import TestConfig, EVENT_WAIT_BUDGET_CYCLES


async def settle_check_reg(
    dut_if: DUTInterface,
    read_fn: Any,
    reg_name: str,
    expected: int,
    desc: str,
    budget: int = EVENT_WAIT_BUDGET_CYCLES,
) -> None:
    """Check a committed register value, tolerating OOO retirement latency.

    On the cpu_ooo core an architectural register write lands at ROB commit, a
    variable number of cycles after the harness feeds the instruction, so a
    fixed post-instruction NOP fill is not enough. Poll the committed value
    until it equals ``expected``, then assert. Every tested instruction writes
    a value that differs from the register's prior contents, so a stale read
    cannot end the poll early. The instruction bus still carries the NOP
    filler driven by the preceding execute helper, so waiting only has to
    advance clock cycles.

    Args:
        dut_if: DUT interface (for the clock)
        read_fn: Zero-argument callable returning the masked register value
        reg_name: Register name for messages (e.g. "x10", "f9")
        expected: Expected (masked) value
        desc: Check description for logging
        budget: Maximum cycles to wait before failing

    Raises:
        AssertionError: If the register never reaches ``expected``.
    """
    for _ in range(budget):
        if read_fn() == expected:
            break
        await RisingEdge(dut_if.clock)
    actual = read_fn()
    if actual != expected:
        raise AssertionError(
            f"FAIL: {desc} - {reg_name} = 0x{actual:08x}, "
            f"expected 0x{expected:08x} (after {budget}-cycle settle window)"
        )
    cocotb.log.info(f"  PASS: {desc} ({reg_name} = 0x{actual:08x})")


async def run_compressed_instruction_test(
    dut: Any, config: TestConfig | None = None
) -> None:
    """Test compressed (16-bit) instruction execution.

    Each step encodes one compressed instruction, packs it into a 32-bit word
    with a NOP in the high half, drives it through the pipeline, and checks
    the register value it commits.

    Tests: C.LI, C.ADDI, C.MV, C.ADD, C.SUB, C.AND, C.OR, C.XOR, C.SLLI,
           C.SRLI, C.SRAI, C.ANDI

    Args:
        dut: Device under test (cocotb SimHandle)
        config: Test configuration. If None, uses defaults.
    """
    if config is None:
        config = TestConfig(num_loops=500, min_coverage_count=5)

    from encoders.compressed_encode import (
        enc_c_li,
        enc_c_addi,
        enc_c_mv,
        enc_c_add,
        enc_c_sub,
        enc_c_and,
        enc_c_or,
        enc_c_xor,
        enc_c_slli,
        enc_c_srli,
        enc_c_srai,
        enc_c_andi,
        enc_c_nop,
    )

    dut_if = DUTInterface(dut)
    nop_32bit = 0x00000013  # addi x0, x0, 0
    c_nop = enc_c_nop()
    nop_packed = (c_nop << 16) | c_nop
    pipeline_depth = PIPELINE_DEPTH

    # Initialize instruction signal before clock starts
    dut_if.instruction = nop_32bit

    cocotb.start_soon(Clock(dut_if.clock, config.clock_period_ns, unit="ns").start())

    await dut_if.reset_dut(config.reset_cycles)

    # Initialize memory model (required for pipeline operation)
    mem_model = MemoryModel(dut)
    cocotb.start_soon(
        mem_model.driver_and_monitor([], [])  # Empty queues, not checking memory
    )

    def read_reg(reg: int) -> int:
        """Read a committed register value from the architectural register file."""
        return dut_if.read_register(reg)

    async def flush_pipeline() -> None:
        """Flush the pipeline with compressed NOPs."""
        for _ in range(pipeline_depth * 2):
            await FallingEdge(dut_if.clock)
            dut_if.instruction = nop_packed
            await RisingEdge(dut_if.clock)

    async def execute_compressed_instr(instr_16bit: int) -> None:
        """Execute a compressed instruction and wait for it to complete.

        A compressed instruction advances the PC by 2, so the PC can end up
        on an odd half-word. Wait for word alignment before driving the next
        instruction.

        Args:
            instr_16bit: 16-bit compressed instruction encoding
        """
        # With PC[1]=1 and prev_was_compressed_at_lo=1 the CPU reads from
        # instr_buffer rather than i_instr, so an instruction driven now would
        # be ignored. Wait for PC[1]=0.
        while True:
            pc_val = int(dut_if.dut.o_pc.value)
            if (pc_val & 0x2) == 0:  # PC[1] == 0, word-aligned
                break
            # Wait one more cycle to let CPU process hi half
            await FallingEdge(dut_if.clock)
            dut_if.instruction = nop_packed
            await RisingEdge(dut_if.clock)

        # The CPU processes both halves of a word as the PC advances from lo
        # to hi. A NOP in the high half leaves the instruction under test as
        # the only one with an effect.
        packed = (c_nop << 16) | instr_16bit
        await FallingEdge(dut_if.clock)
        dut_if.instruction = packed
        await RisingEdge(dut_if.clock)

        # Wait for pipeline to complete
        for _ in range(pipeline_depth + 1):
            await FallingEdge(dut_if.clock)
            dut_if.instruction = nop_packed
            await RisingEdge(dut_if.clock)

    async def check_reg(reg: int, expected: int, desc: str) -> None:
        """Check that a register has the expected value once the write commits.

        Args:
            reg: Register number to check
            expected: Expected value
            desc: Description for logging

        Raises:
            AssertionError: If register value doesn't match expected
        """
        await settle_check_reg(
            dut_if,
            lambda: read_reg(reg) & MASK32,
            f"x{reg}",
            expected & MASK32,
            desc,
        )

    # ========================================================================
    # Initial Pipeline Flush
    # ========================================================================
    cocotb.log.info("=== Flushing pipeline ===")
    await flush_pipeline()
    cocotb.log.info(f"Pipeline flushed, PC = {int(dut_if.dut.o_pc.value)}")

    # ========================================================================
    # Test 1: C.LI (Load Immediate)
    # ========================================================================
    cocotb.log.info("=== Test 1: C.LI ===")
    await execute_compressed_instr(enc_c_li(rd=10, imm=25))
    await check_reg(10, 25, "c.li x10, 25")

    await execute_compressed_instr(enc_c_li(rd=11, imm=-5))
    await check_reg(11, -5, "c.li x11, -5")

    # ========================================================================
    # Test 2: C.ADDI (Add Immediate)
    # ========================================================================
    cocotb.log.info("=== Test 2: C.ADDI ===")
    # x10 = 25 from previous test, add 10 -> 35
    await execute_compressed_instr(enc_c_addi(rd=10, nzimm=10))
    await check_reg(10, 35, "c.addi x10, 10 (25 + 10 = 35)")

    await execute_compressed_instr(enc_c_addi(rd=10, nzimm=-3))
    await check_reg(10, 32, "c.addi x10, -3 (35 - 3 = 32)")

    # ========================================================================
    # Test 3: C.MV (Move Register)
    # ========================================================================
    cocotb.log.info("=== Test 3: C.MV ===")
    # Set up x12 with a known value first
    await execute_compressed_instr(enc_c_li(rd=12, imm=17))
    await execute_compressed_instr(enc_c_mv(rd=13, rs2=12))
    await check_reg(13, 17, "c.mv x13, x12 (copy 17)")

    # ========================================================================
    # Test 4: C.ADD (Add Registers)
    # ========================================================================
    cocotb.log.info("=== Test 4: C.ADD ===")
    # x10 = 32, x12 = 17, set x10 = x10 + x12 = 49
    await execute_compressed_instr(enc_c_add(rd=10, rs2=12))
    await check_reg(10, 49, "c.add x10, x12 (32 + 17 = 49)")

    # ========================================================================
    # Test 5: C.SUB (Subtract Registers) - uses x8-x15 only
    # ========================================================================
    cocotb.log.info("=== Test 5: C.SUB ===")
    # Set up x8 = 93, x9 = 30
    await execute_compressed_instr(enc_c_li(rd=8, imm=31))  # Max positive imm is 31
    await execute_compressed_instr(enc_c_addi(rd=8, nzimm=31))  # 31 + 31 = 62
    await execute_compressed_instr(enc_c_addi(rd=8, nzimm=31))  # 62 + 31 = 93
    await execute_compressed_instr(enc_c_li(rd=9, imm=30))
    await execute_compressed_instr(enc_c_sub(rd_prime=8, rs2_prime=9))
    await check_reg(8, 63, "c.sub x8, x9 (93 - 30 = 63)")

    # ========================================================================
    # Test 6: C.AND (AND Registers)
    # ========================================================================
    cocotb.log.info("=== Test 6: C.AND ===")
    await execute_compressed_instr(enc_c_li(rd=14, imm=0x1F))  # 0b11111
    await execute_compressed_instr(enc_c_li(rd=15, imm=0x0A))  # 0b01010
    await execute_compressed_instr(enc_c_and(rd_prime=14, rs2_prime=15))
    await check_reg(14, 0x0A, "c.and x14, x15 (0x1F & 0x0A = 0x0A)")

    # ========================================================================
    # Test 7: C.OR (OR Registers)
    # ========================================================================
    cocotb.log.info("=== Test 7: C.OR ===")
    await execute_compressed_instr(enc_c_li(rd=14, imm=0x05))  # 0b00101
    await execute_compressed_instr(enc_c_li(rd=15, imm=0x0A))  # 0b01010
    await execute_compressed_instr(enc_c_or(rd_prime=14, rs2_prime=15))
    await check_reg(14, 0x0F, "c.or x14, x15 (0x05 | 0x0A = 0x0F)")

    # ========================================================================
    # Test 8: C.XOR (XOR Registers)
    # ========================================================================
    cocotb.log.info("=== Test 8: C.XOR ===")
    await execute_compressed_instr(enc_c_li(rd=14, imm=0x0F))  # 0b01111
    await execute_compressed_instr(enc_c_li(rd=15, imm=0x03))  # 0b00011
    await execute_compressed_instr(enc_c_xor(rd_prime=14, rs2_prime=15))
    await check_reg(14, 0x0C, "c.xor x14, x15 (0x0F ^ 0x03 = 0x0C)")

    # ========================================================================
    # Test 9: C.SLLI (Shift Left Logical Immediate)
    # ========================================================================
    cocotb.log.info("=== Test 9: C.SLLI ===")
    await execute_compressed_instr(enc_c_li(rd=10, imm=1))
    await execute_compressed_instr(enc_c_slli(rd=10, shamt=4))
    await check_reg(10, 16, "c.slli x10, 4 (1 << 4 = 16)")

    # ========================================================================
    # Test 10: C.SRLI (Shift Right Logical Immediate) - uses x8-x15
    # ========================================================================
    cocotb.log.info("=== Test 10: C.SRLI ===")
    await execute_compressed_instr(enc_c_li(rd=8, imm=31))  # 31 (max single imm)
    await execute_compressed_instr(enc_c_addi(rd=8, nzimm=1))  # 32
    await execute_compressed_instr(enc_c_srli(rd_prime=8, shamt=2))
    await check_reg(8, 8, "c.srli x8, 2 (32 >> 2 = 8)")

    # ========================================================================
    # Test 11: C.SRAI (Shift Right Arithmetic Immediate) - uses x8-x15
    # ========================================================================
    cocotb.log.info("=== Test 11: C.SRAI ===")
    await execute_compressed_instr(enc_c_li(rd=8, imm=-16))  # -16 (0xFFFFFFF0)
    await execute_compressed_instr(enc_c_srai(rd_prime=8, shamt=2))
    await check_reg(8, -4, "c.srai x8, 2 (-16 >>> 2 = -4)")

    # ========================================================================
    # Test 12: C.ANDI (AND Immediate) - uses x8-x15
    # ========================================================================
    cocotb.log.info("=== Test 12: C.ANDI ===")
    await execute_compressed_instr(enc_c_li(rd=8, imm=0x1F))  # 0b11111
    await execute_compressed_instr(enc_c_andi(rd_prime=8, imm=0x07))  # 0b00111
    await check_reg(8, 0x07, "c.andi x8, 7 (0x1F & 0x07 = 0x07)")

    cocotb.log.info("=== All compressed instruction tests passed! ===")


@cocotb.test()
async def test_compressed_instructions(dut: Any) -> None:
    """Test C extension compressed instruction execution."""
    await run_compressed_instruction_test(dut)


@cocotb.test()
async def test_random_riscv_regression_with_compressed(dut: Any) -> None:
    """Random RISC-V regression with C extension compressed instructions.

    Despite the name, this currently re-runs the directed suite in
    run_compressed_instruction_test (see its docstring for the instruction
    list). That suite consumes only the clock/reset fields of TestConfig,
    which are left at their defaults here, so the stimulus is identical to
    test_compressed_instructions.
    """
    config = TestConfig(num_loops=1000, min_coverage_count=10)
    await run_compressed_instruction_test(dut, config)
