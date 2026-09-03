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

"""Unit tests for the int_alu_shim module.

Tests ADD, ADDI, SUB, shifts, LUI, AUIPC, JAL link, CSR read, branch
no-writeback, busy signalling, a sample of Zb*/Zicond ops, and operand
patterns that only carry meaning at XLEN=64. The ALU is single-cycle, so
results are available combinationally (no polling loop needed).
"""

from typing import Any

import cocotb
from cocotb.clock import Clock

from .fp_add_shim_interface import _parse_instr_op_enum
from .int_alu_shim_interface import IntAluShimInterface
from config import MASK_XLEN
from models import alu_model

CLOCK_PERIOD_NS = 10

MASK32 = 0xFFFF_FFFF

# ---------------------------------------------------------------------------
# Parse instr_op_e from riscv_pkg.sv so op values track the RTL source.
# ---------------------------------------------------------------------------
_INSTR_OPS = _parse_instr_op_enum()


def _op(name: str) -> int:
    """Look up an instr_op_e value by name, raising KeyError on mismatch."""
    return _INSTR_OPS[name]


# ---------------------------------------------------------------------------
# Common setup helper
# ---------------------------------------------------------------------------
async def setup(dut: Any) -> IntAluShimInterface:
    """Start clock, reset DUT, and return the interface."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    iface = IntAluShimInterface(dut)
    await iface.reset()
    return iface


# ============================================================================
# Test 1: After reset, outputs are idle
# ============================================================================
@cocotb.test()
async def test_reset_state(dut: Any) -> None:
    """After reset: o_fu_complete.valid=0, o_fu_busy=0."""
    iface = await setup(dut)

    result = iface.read_fu_complete()
    assert result["valid"] is False, "fu_complete.valid should be 0 after reset"
    assert iface.read_busy() is False, "fu_busy should be 0 after reset"


# ============================================================================
# Test 2: ADD basic (10 + 20 = 30)
# ============================================================================
@cocotb.test()
async def test_add_basic(dut: Any) -> None:
    """ADD: 10 + 20 = 30 (register + register, use_imm=False)."""
    iface = await setup(dut)

    rob_tag = 1
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("ADD"),
        src1_value=10,
        src2_value=20,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == 30, f"Expected 30, got {result['value']}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 3: ADDI basic (100 + imm 50 = 150)
# ============================================================================
@cocotb.test()
async def test_addi_basic(dut: Any) -> None:
    """ADDI: 100 + imm(50) = 150 (use_imm=True)."""
    iface = await setup(dut)

    rob_tag = 2
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("ADDI"),
        src1_value=100,
        src2_value=0,
        imm=50,
        use_imm=True,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == 150, f"Expected 150, got {result['value']}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 4: SUB basic (50 - 30 = 20)
# ============================================================================
@cocotb.test()
async def test_sub_basic(dut: Any) -> None:
    """SUB: 50 - 30 = 20."""
    iface = await setup(dut)

    rob_tag = 3
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("SUB"),
        src1_value=50,
        src2_value=30,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == 20, f"Expected 20, got {result['value']}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 5: SLLI (1 << 4 = 16)
# ============================================================================
@cocotb.test()
async def test_slli(dut: Any) -> None:
    """SLLI: 1 << 4 = 16 (use_imm=True, shift amount in imm[5:0])."""
    iface = await setup(dut)

    rob_tag = 4
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("SLLI"),
        src1_value=1,
        src2_value=0,
        imm=4,
        use_imm=True,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == 16, f"Expected 16, got {result['value']}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 6: LUI (loads upper immediate)
# ============================================================================
@cocotb.test()
async def test_lui(dut: Any) -> None:
    """LUI: loads upper immediate value directly as result."""
    iface = await setup(dut)

    rob_tag = 5
    imm_val = 0x12345000
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("LUI"),
        src1_value=0,
        src2_value=0,
        imm=imm_val,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert (
        result["value"] == imm_val
    ), f"Expected 0x{imm_val:08X}, got 0x{result['value']:016X}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 7: AUIPC (pc + upper immediate)
# ============================================================================
@cocotb.test()
async def test_auipc(dut: Any) -> None:
    """AUIPC: pc + upper immediate."""
    iface = await setup(dut)

    rob_tag = 6
    pc_val = 0x0000_1000
    imm_val = 0x0000_2000
    expected = (pc_val + imm_val) & MASK_XLEN

    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("AUIPC"),
        src1_value=0,
        src2_value=0,
        imm=imm_val,
        pc=pc_val,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert (
        result["value"] == expected
    ), f"Expected 0x{expected:08X}, got 0x{result['value']:016X}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 8: JAL produces pc+4 as link address
# ============================================================================
@cocotb.test()
async def test_jal_link(dut: Any) -> None:
    """JAL produces the pre-computed link address on the CDB."""
    iface = await setup(dut)

    rob_tag = 7
    pc_val = 0x0000_0100
    link_addr = (pc_val + 4) & MASK32

    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("JAL"),
        src1_value=0,
        src2_value=0,
        pc=pc_val,
        link_addr=link_addr,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert (
        result["value"] == link_addr
    ), f"Expected 0x{link_addr:08X}, got 0x{result['value']:016X}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 9: SEXT_H sign-extends low 16 bits
# ============================================================================
@cocotb.test()
async def test_sext_h(dut: Any) -> None:
    """SEXT_H: sign-extend the low halfword to XLEN."""
    iface = await setup(dut)

    rob_tag = 8
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("SEXT_H"),
        src1_value=0x0000_8001,
        src2_value=0,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    expected = alu_model.sext_h(0x0000_8001)
    assert (
        result["value"] == expected
    ), f"Expected 0x{expected:X}, got 0x{result['value']:X}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 10: PACK implements zext.h when rs2=x0
# ============================================================================
@cocotb.test()
async def test_pack_zext_h(dut: Any) -> None:
    """PACK with rs2=0 packs the low halves (rs2=0 clears the top)."""
    iface = await setup(dut)

    rob_tag = 9
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("PACK"),
        src1_value=0xAABB_CCDD,
        src2_value=0,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    expected = alu_model.pack(0xAABB_CCDD, 0)
    assert (
        result["value"] == expected
    ), f"Expected 0x{expected:X}, got 0x{result['value']:X}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 11: SH2ADD computes rs2 + (rs1 << 2)
# ============================================================================
@cocotb.test()
async def test_sh2add(dut: Any) -> None:
    """SH2ADD: rs2 + (rs1 << 2)."""
    iface = await setup(dut)

    rob_tag = 10
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("SH2ADD"),
        src1_value=3,
        src2_value=4,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == 16, f"Expected 16, got {result['value']}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 12: REV8 reverses byte order
# ============================================================================
@cocotb.test()
async def test_rev8(dut: Any) -> None:
    """REV8: reverse the byte order of the full XLEN-wide value."""
    iface = await setup(dut)

    rob_tag = 11
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("REV8"),
        src1_value=0x1122_3344,
        src2_value=0,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    expected = alu_model.rev8(0x1122_3344)
    assert (
        result["value"] == expected
    ), f"Expected 0x{expected:X}, got 0x{result['value']:X}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 13: BREV8 reverses bits within each byte
# ============================================================================
@cocotb.test()
async def test_brev8(dut: Any) -> None:
    """BREV8: reverse bits within each byte independently."""
    iface = await setup(dut)

    rob_tag = 12
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("BREV8"),
        src1_value=0x0123_4567,
        src2_value=0,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert (
        result["value"] == 0x80C4_A2E6
    ), f"Expected 0x80C4A2E6, got 0x{result['value']:08X}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 14: BEXTI extracts a single immediate-selected bit
# ============================================================================
@cocotb.test()
async def test_bexti(dut: Any) -> None:
    """BEXTI: extract the selected bit into bit 0."""
    iface = await setup(dut)

    rob_tag = 13
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("BEXTI"),
        src1_value=0x0000_0080,
        src2_value=0,
        imm=7,
        use_imm=True,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == 1, f"Expected 1, got {result['value']}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 15: CZERO.EQZ zeros the value when rs2 is zero
# ============================================================================
@cocotb.test()
async def test_czero_eqz(dut: Any) -> None:
    """CZERO.EQZ: rd=0 when rs2 == 0, else rd=rs1."""
    iface = await setup(dut)

    rob_tag = 14
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("CZERO_EQZ"),
        src1_value=0x1234_5678,
        src2_value=0,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == 0, f"Expected 0, got 0x{result['value']:08X}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 16: CZERO.NEZ zeros the value when rs2 is nonzero
# ============================================================================
@cocotb.test()
async def test_czero_nez(dut: Any) -> None:
    """CZERO.NEZ: rd=0 when rs2 != 0, else rd=rs1."""
    iface = await setup(dut)

    rob_tag = 15
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("CZERO_NEZ"),
        src1_value=0x89AB_CDEF,
        src2_value=5,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == 0, f"Expected 0, got 0x{result['value']:08X}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 17: PACK packs low halfwords from rs1 and rs2
# ============================================================================
@cocotb.test()
async def test_pack_general(dut: Any) -> None:
    """PACK: upper halfword from rs2, lower halfword from rs1."""
    iface = await setup(dut)

    rob_tag = 16
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("PACK"),
        src1_value=0xAABB_CCDD,
        src2_value=0x1122_3344,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    expected = alu_model.pack(0xAABB_CCDD, 0x1122_3344)
    assert (
        result["value"] == expected
    ), f"Expected 0x{expected:X}, got 0x{result['value']:X}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# Test 18: busy is always 0 (ALU is single-cycle)
# ============================================================================
@cocotb.test()
async def test_never_busy(dut: Any) -> None:
    """ALU shim busy is always 0 regardless of input."""
    iface = await setup(dut)

    assert iface.read_busy() is False, "busy should be 0 after reset"

    iface.drive_issue(
        valid=True,
        rob_tag=8,
        op=_op("ADD"),
        src1_value=1,
        src2_value=2,
    )
    await iface.step()
    assert iface.read_busy() is False, "busy should be 0 even during valid issue"

    iface.clear_issue()
    await iface.step()
    assert iface.read_busy() is False, "busy should be 0 after clearing issue"


# ============================================================================
# Test 19: Branch ops (BEQ) produce valid=0 (no writeback)
# ============================================================================
@cocotb.test()
async def test_branch_no_valid(dut: Any) -> None:
    """Branch ops (BEQ) do not produce a valid writeback."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=13,
        op=_op("BEQ"),
        src1_value=42,
        src2_value=42,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert (
        result["valid"] is False
    ), "BEQ should not produce valid writeback (branch resolution is separate)"
    iface.clear_issue()


# ============================================================================
# Test 20: CSR read (CSRRS with i_csr_read_data)
# ============================================================================
@cocotb.test()
async def test_csr_read(dut: Any) -> None:
    """CSRRS: ALU shim passes through src1_value (rs1) for register CSR ops."""
    iface = await setup(dut)

    rob_tag = 14
    rs1_val = 0x0000_00A5

    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("CSRRS"),
        src1_value=rs1_val,
        src2_value=0,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion for CSRRS"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert (
        result["value"] == rs1_val
    ), f"Expected 0x{rs1_val:08X}, got 0x{result['value']:016X}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()


# ============================================================================
# RV64-discriminating vectors (audit vacuous-pass list): ops/operand
# patterns that only exist or only carry meaning at XLEN=64.
# ============================================================================
async def _check_op(
    dut: Any,
    op_name: str,
    src1: int,
    src2: int,
    expected: int,
    imm: int | None = None,
) -> None:
    """Drive one op through the shim and compare against the model value."""
    iface = await setup(dut)
    if imm is not None:
        iface.drive_issue(
            valid=True,
            rob_tag=7,
            op=_op(op_name),
            src1_value=src1,
            src2_value=src2,
            imm=imm,
            use_imm=True,
        )
    else:
        iface.drive_issue(
            valid=True,
            rob_tag=7,
            op=_op(op_name),
            src1_value=src1,
            src2_value=src2,
        )
    await iface.step()
    result = iface.read_fu_complete()
    assert result["valid"] is True, f"{op_name}: expected valid completion"
    assert (
        result["value"] == expected
    ), f"{op_name}: expected 0x{expected:X}, got 0x{result['value']:X}"
    iface.clear_issue()


@cocotb.test()
async def test_rv64_sll_shamt40(dut: Any) -> None:
    """64-bit SLL with shamt 40 (bit 5 of rs2 live)."""
    await _check_op(dut, "SLL", 0x1F, 40, alu_model.sll(0x1F, 40))


@cocotb.test()
async def test_rv64_srai_shamt6(dut: Any) -> None:
    """SRAI with a 6-bit immediate shamt (imm[5] set)."""
    await _check_op(
        dut,
        "SRAI",
        0x8000_0000_0000_0000,
        0,
        alu_model.sra(0x8000_0000_0000_0000, 63),
        imm=63,
    )


@cocotb.test()
async def test_rv64_addw_wrap(dut: Any) -> None:
    """ADDW wraps at 32 bits and sign-extends."""
    await _check_op(dut, "ADDW", 0x7FFF_FFFF, 1, alu_model.addw(0x7FFF_FFFF, 1))


@cocotb.test()
async def test_rv64_add_uw(dut: Any) -> None:
    """ADD.UW zero-extends rs1's low word before the 64-bit add."""
    await _check_op(
        dut,
        "ADD_UW",
        0xFFFF_FFFF_FFFF_FFFF,
        8,
        alu_model.add_uw(0xFFFF_FFFF_FFFF_FFFF, 8),
    )


@cocotb.test()
async def test_rv64_slli_uw(dut: Any) -> None:
    """SLLI.UW with a 6-bit shamt crossing bit 32."""
    await _check_op(
        dut, "SLLI_UW", 0xFFFF_FFFF, 0, alu_model.slli_uw(0xFFFF_FFFF, 33), imm=33
    )


@cocotb.test()
async def test_rv64_sh3add_uw(dut: Any) -> None:
    """SH3ADD.UW shift-add on the zero-extended word."""
    await _check_op(
        dut,
        "SH3ADD_UW",
        0x8000_0001,
        0x10,
        alu_model.sh3add_uw(0x8000_0001, 0x10),
    )


@cocotb.test()
async def test_rv64_rorw(dut: Any) -> None:
    """RORW rotates the low word and sign-extends bit 31."""
    await _check_op(dut, "RORW", 1, 1, alu_model.rorw(1, 1))


@cocotb.test()
async def test_rv64_rori_shamt6(dut: Any) -> None:
    """64-bit RORI with shamt 40 (6-bit immediate)."""
    await _check_op(dut, "RORI", 0xDEAD_BEEF, 0, alu_model.ror(0xDEAD_BEEF, 40), imm=40)


@cocotb.test()
async def test_rv64_bexti_bit40(dut: Any) -> None:
    """BEXTI with a 6-bit index reaching the high word."""
    await _check_op(dut, "BEXTI", 1 << 40, 0, alu_model.bext(1 << 40, 40), imm=40)


@cocotb.test()
async def test_rv64_clzw(dut: Any) -> None:
    """CLZW counts within the low word only."""
    await _check_op(
        dut, "CLZW", 0xFFFF_FFFF_0000_0001, 0, alu_model.clzw(0xFFFF_FFFF_0000_0001)
    )


@cocotb.test()
async def test_rv64_cpop64(dut: Any) -> None:
    """CPOP counts all 64 bits."""
    await _check_op(
        dut, "CPOP", 0xF0F0_F0F0_F0F0_F0F0, 0, alu_model.cpop(0xF0F0_F0F0_F0F0_F0F0)
    )


@cocotb.test()
async def test_rv64_packw(dut: Any) -> None:
    """PACKW: pack the low halfwords into a sext32 word (zext.h when rs2=0)."""
    await _check_op(dut, "PACKW", 0x8000, 0xBEEF, alu_model.packw(0x8000, 0xBEEF))
