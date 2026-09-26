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

The directed test runs one compressed instruction type at a time and reads
back the register value it commits; negative immediates and the shift forms
are covered. The random test cycles through the compressed ALU forms in the
op_tables C_* tables with random operands, seeded by the cocotb random seed,
and checks each result against the table's evaluator. About half of its words
carry a second random instruction in the high half, so the two halves also
dispatch as one bundle.

Usage: ``./scripts/frost.py cocotb compressed``.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from typing import Any

from config import MASK_XLEN, NOP_INSTRUCTION, PIPELINE_DEPTH
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
from encoders.op_tables import (
    C_ALU_FULL,
    C_ALU_IMM_FULL,
    C_ALU_IMM_LIMITED,
    C_ALU_REG,
)
from models.memory_model import MemoryModel
from cocotb_tests.test_helpers import DUTInterface, TestStatistics
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

    An architectural register write lands at ROB commit, a variable number of
    cycles after the harness feeds the instruction, so a fixed NOP fill after
    the instruction is not enough. Poll the committed value until it equals
    ``expected``, then assert. Every checked instruction writes a value that
    differs from the register's prior contents (the directed test starts from
    zeroed registers, and the random test draws only operands that change
    rd), so a stale read cannot end the poll early. The instruction bus still
    carries the NOP filler driven by the preceding execute helper, so waiting
    only has to advance clock cycles.

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


class CompressedHarness:
    """Drive compressed instructions into cpu_tb and check committed registers."""

    def __init__(self, dut: Any) -> None:
        """Create the harness for one test."""
        self.dut = dut
        self.dut_if = DUTInterface(dut)
        self.c_nop = enc_c_nop()
        self.nop_packed = (self.c_nop << 16) | self.c_nop

    async def start(
        self, config: TestConfig, registers: list[int] | None = None
    ) -> None:
        """Load x1-x31, start the clock, reset, and flush the pipeline.

        Reset does not clear the register file, so each test loads it (with
        zeros by default): otherwise a test would inherit the registers an
        earlier test in the same simulation left behind.

        Args:
            config: Clock and reset settings
            registers: Values for x0-x31 (x0 is ignored); zeros if None
        """
        for reg in range(1, 32):
            self.dut_if.write_register(reg, registers[reg] if registers else 0)
        self.dut_if.instruction = NOP_INSTRUCTION

        Clock(self.dut_if.clock, config.clock_period_ns, unit="ns").start()
        await self.dut_if.reset_dut(config.reset_cycles)

        # These tests never store, so with empty expected-write queues any
        # DUT store fails the test.
        mem_model = MemoryModel(self.dut)
        cocotb.start_soon(mem_model.driver_and_monitor([], []))

        cocotb.log.info("=== Flushing pipeline ===")
        await self.flush_pipeline()
        cocotb.log.info(f"Pipeline flushed, PC = {int(self.dut_if.dut.o_pc.value)}")

    async def flush_pipeline(self) -> None:
        """Flush the pipeline with compressed NOPs."""
        for _ in range(PIPELINE_DEPTH * 2):
            await FallingEdge(self.dut_if.clock)
            self.dut_if.instruction = self.nop_packed
            await RisingEdge(self.dut_if.clock)

    async def execute(self, instr_16bit: int, high_16bit: int | None = None) -> None:
        """Drive one word of compressed instructions, then NOP filler behind it.

        A compressed instruction advances the PC by 2, so the PC can end up
        on an odd half-word. Wait for word alignment before driving the next
        instruction. The filler does not wait for commit; check polls for
        the result.

        Args:
            instr_16bit: 16-bit compressed instruction for the low half
            high_16bit: 16-bit compressed instruction for the high half, which
                runs second (C.NOP if None)
        """
        # With PC[1]=1 and prev_was_compressed_at_lo=1 the CPU reads from
        # instr_buffer rather than i_instr, so an instruction driven now would
        # be ignored. Wait for PC[1]=0.
        while True:
            pc_val = int(self.dut_if.dut.o_pc.value)
            if (pc_val & 0x2) == 0:  # PC[1] == 0, word-aligned
                break
            # Wait one more cycle to let CPU process hi half
            await FallingEdge(self.dut_if.clock)
            self.dut_if.instruction = self.nop_packed
            await RisingEdge(self.dut_if.clock)

        # The CPU runs both halves of the word, low half first; the two can
        # dispatch together as one bundle. A C.NOP in the high half leaves
        # the low instruction as the only one with an effect.
        high = self.c_nop if high_16bit is None else high_16bit
        packed = (high << 16) | instr_16bit
        await FallingEdge(self.dut_if.clock)
        self.dut_if.instruction = packed
        await RisingEdge(self.dut_if.clock)

        # NOP filler behind the instruction
        for _ in range(PIPELINE_DEPTH + 1):
            await FallingEdge(self.dut_if.clock)
            self.dut_if.instruction = self.nop_packed
            await RisingEdge(self.dut_if.clock)

    async def check(self, reg: int, expected: int, desc: str) -> None:
        """Check that x<reg> commits the expected XLEN-wide value.

        Args:
            reg: Register number to check
            expected: Expected value (negative values are two's complement)
            desc: Description for logging

        Raises:
            AssertionError: If register value doesn't match expected
        """
        await settle_check_reg(
            self.dut_if,
            lambda: self.dut_if.read_register(reg) & MASK_XLEN,
            f"x{reg}",
            expected & MASK_XLEN,
            desc,
        )


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
        config: Test configuration (clock and reset). If None, uses defaults.
    """
    harness = CompressedHarness(dut)
    await harness.start(config or TestConfig())
    execute_compressed_instr = harness.execute
    check_reg = harness.check

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
    await execute_compressed_instr(enc_c_li(rd=8, imm=-16))
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


# Every modeled compressed ALU form, as (family, mnemonic).
_COMPRESSED_ALU_FORMS = (
    [("reg", mnemonic) for mnemonic in sorted(C_ALU_REG)]
    + [("full", mnemonic) for mnemonic in sorted(C_ALU_FULL)]
    + [("imm_limited", mnemonic) for mnemonic in sorted(C_ALU_IMM_LIMITED)]
    + [("imm_full", mnemonic) for mnemonic in sorted(C_ALU_IMM_FULL)]
)


def _operand_choices(family: str, mnemonic: str) -> list[tuple[int, int]]:
    """List every legal (rd, rs2 or immediate) pair for one compressed ALU form.

    The rd'/rs2' forms use x8-x15, the full-register forms use rd and rs2
    other than x0, the C.ADDI immediate is nonzero, and shift amounts are 1-63.
    """
    if family == "reg":
        return [(rd, rs2) for rd in range(8, 16) for rs2 in range(8, 16)]
    if family == "full":
        return [(rd, rs2) for rd in range(1, 32) for rs2 in range(1, 32)]
    if family == "imm_limited":
        rds = list(range(8, 16))
        imms = list(range(-32, 32) if mnemonic == "c.andi" else range(1, 64))
    else:
        rds = list(range(1, 32))
        if mnemonic == "c.slli":
            imms = list(range(1, 64))
        elif mnemonic == "c.addi":
            imms = [imm for imm in range(-32, 32) if imm]
        else:
            imms = list(range(-32, 32))
    return [(rd, imm) for rd in rds for imm in imms]


def _compressed_alu_instruction(
    family: str, mnemonic: str, rd: int, operand: int, regs: list[int]
) -> tuple[int, int]:
    """Encode one compressed ALU instruction and model its rd result.

    Returns:
        (16-bit encoding, expected rd value)
    """
    if family in ("reg", "full"):
        encoder, evaluator = (C_ALU_REG if family == "reg" else C_ALU_FULL)[mnemonic]
        rs1_value = 0 if mnemonic == "c.mv" else regs[rd]
        return encoder(rd, operand), evaluator(rs1_value, regs[operand])
    table = C_ALU_IMM_LIMITED if family == "imm_limited" else C_ALU_IMM_FULL
    encoder, evaluator = table[mnemonic]
    rs1_value = 0 if mnemonic == "c.li" else regs[rd]
    return encoder(rd, operand), evaluator(rs1_value, operand & MASK_XLEN)


def _draw_changing_instruction(
    rng: random.Random, family: str, mnemonic: str, regs: list[int]
) -> tuple[int, int, int] | None:
    """Draw operands whose result changes rd, uniformly among those that do.

    Returns:
        (16-bit encoding, rd, expected rd value), or None if no operands of
        the form change any register.
    """
    choices = _operand_choices(family, mnemonic)
    rng.shuffle(choices)
    for rd, operand in choices:
        encoding, expected = _compressed_alu_instruction(
            family, mnemonic, rd, operand, regs
        )
        if expected != regs[rd]:
            return encoding, rd, expected
    return None


def _limited_register_refresh(regs: list[int]) -> tuple[int, int, int]:
    """Build a C.LI that loads x8 with a value no x8-x15 register holds.

    The value is neither 0 nor -1 either, so afterwards every compressed ALU
    form has operands that change a register: x8 is nonzero, differs from
    x9, and is not all ones (the one other value C.SRAI leaves unchanged).

    Returns:
        (16-bit encoding, rd, expected rd value)
    """
    encoder, evaluator = C_ALU_IMM_FULL["c.li"]
    held = {regs[reg] for reg in range(8, 16)}
    for imm in [*range(1, 32), *range(-32, -1)]:
        value = evaluator(0, imm & MASK_XLEN)
        if value not in held:
            return encoder(8, imm), 8, value
    raise AssertionError("x8-x15 hold every candidate C.LI value")


def _draw_high_parcel(
    rng: random.Random, regs: list[int], low: tuple[int, int, int]
) -> tuple[str, int, int, int] | None:
    """Draw an instruction for the high half of a word behind ``low``.

    It runs after the low-half instruction, so it is drawn against the
    registers that instruction leaves and changes its own rd from there. When
    both write one register only the final value can be checked, so that
    value must also differ from the register's value before the word.

    Returns:
        (mnemonic, 16-bit encoding, rd, expected rd value), or None if the
        draw gives no such instruction
    """
    _, low_rd, low_expected = low
    after_low = regs.copy()
    after_low[low_rd] = low_expected
    family, mnemonic = rng.choice(_COMPRESSED_ALU_FORMS)
    drawn = _draw_changing_instruction(rng, family, mnemonic, after_low)
    if drawn is None or (drawn[1] == low_rd and drawn[2] == regs[low_rd]):
        return None
    return (mnemonic, *drawn)


async def run_random_compressed_test(dut: Any, config: TestConfig) -> None:
    """Drive random compressed ALU instructions and check each against the model.

    The registers start at random 64-bit values, and the test cycles through
    every form with operands whose result changes the destination, so each
    check can pass only once that instruction has committed. The rd'/rs2'
    forms can leave x8-x15 in a state no operands of a form change (all
    equal, for example); a checked C.LI then loads x8 with a value after
    which every form has such operands. About half of the words also carry a
    random instruction in the high half, which the core runs second and can
    dispatch in the same bundle (slot 2). The run ends by comparing x1-x31
    with the model, checking that every form ran at least
    config.min_coverage_count times, and checking that some word pairs
    dispatched as one bundle.

    Args:
        dut: Device under test (cocotb SimHandle)
        config: Test configuration; num_loops sets how many forms are drawn
    """
    rng = random.Random(cocotb.RANDOM_SEED)
    cocotb.log.info(f"Random compressed stream seeded with {cocotb.RANDOM_SEED}")
    regs = [0] + [rng.getrandbits(64) for _ in range(31)]
    harness = CompressedHarness(dut)
    await harness.start(config, regs)
    stats = TestStatistics()

    async def drive(mnemonic: str, encoding: int, rd: int, expected: int) -> None:
        regs[rd] = expected
        stats.record_instruction(mnemonic)
        await harness.execute(encoding)
        await harness.check(rd, expected, f"{mnemonic} (0x{encoding:04x})")

    async def drive_pair(
        mnemonic: str, encoding: int, rd: int, expected: int
    ) -> tuple[str, int, int, int] | None:
        """Drive a low-half instruction with a random high-half one, if drawn."""
        high = _draw_high_parcel(rng, regs, (encoding, rd, expected))
        if high is None:
            await drive(mnemonic, encoding, rd, expected)
            return None
        high_mnemonic, high_encoding, high_rd, high_expected = high
        regs[rd] = expected
        regs[high_rd] = high_expected
        stats.record_instruction(mnemonic)
        stats.record_instruction(high_mnemonic)
        await harness.execute(encoding, high_encoding)
        if high_rd != rd:
            await harness.check(rd, expected, f"{mnemonic} (0x{encoding:04x}), low")
        await harness.check(
            high_rd, high_expected, f"{high_mnemonic} (0x{high_encoding:04x}), high"
        )
        return high

    # ROB allocation for slot 2 fires only when a word's two instructions
    # dispatch as one bundle; alloc_valid is the request struct's MSB.
    slot2_alloc = dut.device_under_test.rob_alloc_req_2
    slot2_valid_shift = len(slot2_alloc) - 1
    slot2_dispatches = 0

    async def count_slot2_dispatches() -> None:
        nonlocal slot2_dispatches
        while True:
            await RisingEdge(harness.dut_if.clock)
            if (int(slot2_alloc.value) >> slot2_valid_shift) & 1:
                slot2_dispatches += 1

    slot2_counter = cocotb.start_soon(count_slot2_dispatches())
    word_pairs = 0
    for index in range(config.num_loops):
        family, mnemonic = _COMPRESSED_ALU_FORMS[index % len(_COMPRESSED_ALU_FORMS)]
        drawn = _draw_changing_instruction(rng, family, mnemonic, regs)
        if drawn is None:
            await drive("c.li", *_limited_register_refresh(regs))
            drawn = _draw_changing_instruction(rng, family, mnemonic, regs)
            assert drawn is not None, f"No {mnemonic} operands change a register"
        if rng.random() < 0.5:
            if await drive_pair(mnemonic, *drawn) is not None:
                word_pairs += 1
        else:
            await drive(mnemonic, *drawn)

    for reg in range(1, 32):
        actual = harness.dut_if.read_register(reg) & MASK_XLEN
        assert actual == regs[reg], (
            f"x{reg} = 0x{actual:016x} at the end of the stream, model 0x{regs[reg]:016x}"
        )
    coverage_issues = stats.check_coverage(config.min_coverage_count)
    assert not coverage_issues, "Coverage: " + "; ".join(coverage_issues)
    slot2_counter.cancel()
    cocotb.log.info(
        f"{word_pairs} words carried two instructions; slot 2 dispatched in "
        f"{slot2_dispatches} cycles"
    )
    assert slot2_dispatches, "No word pair dispatched as one bundle"
    cocotb.log.info(stats.report())


@cocotb.test()
async def test_random_compressed_alu_instructions(dut: Any) -> None:
    """Random compressed ALU instructions, each checked against the op_tables model."""
    await run_random_compressed_test(
        dut, TestConfig(num_loops=400, min_coverage_count=5)
    )
