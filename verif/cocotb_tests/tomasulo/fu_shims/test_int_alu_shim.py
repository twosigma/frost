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
no-writeback, and busy signalling.  The ALU is single-cycle, so results
are available combinationally (no polling loop needed).
"""

from typing import Any

import cocotb
from cocotb.clock import Clock

from .fp_add_shim_interface import _parse_instr_op_enum
from .int_alu_shim_interface import IntAluShimInterface

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
    """SLLI: 1 << 4 = 16 (use_imm=True, shift amount in imm[4:0])."""
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
    expected = (pc_val + imm_val) & MASK32

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
    """JAL: produces pc+4 as the link (return) address."""
    iface = await setup(dut)

    rob_tag = 7
    pc_val = 0x0000_0100
    expected = (pc_val + 4) & MASK32

    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("JAL"),
        src1_value=0,
        src2_value=0,
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
# Test 9: busy is always 0 (ALU is single-cycle)
# ============================================================================
@cocotb.test()
async def test_never_busy(dut: Any) -> None:
    """ALU shim busy is always 0 regardless of input."""
    iface = await setup(dut)

    assert iface.read_busy() is False, "busy should be 0 after reset"

    # Drive a valid issue
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
# Test 10: Branch ops (BEQ) produce valid=0 (no writeback)
# ============================================================================
@cocotb.test()
async def test_branch_no_valid(dut: Any) -> None:
    """Branch ops (BEQ) do not produce a valid writeback."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=9,
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
# Test 11: CSR read (CSRRS with i_csr_read_data)
# ============================================================================
@cocotb.test()
async def test_csr_read(dut: Any) -> None:
    """CSRRS: result is i_csr_read_data."""
    iface = await setup(dut)

    rob_tag = 10
    csr_val = 0xDEAD_BEEF

    iface.drive_csr_read_data(csr_val)
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("CSRRS"),
        src1_value=0,
        src2_value=0,
    )
    await iface.step()

    result = iface.read_fu_complete()
    assert result["valid"] is True, "Expected valid completion for CSRRS"
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert (
        result["value"] == csr_val
    ), f"Expected 0x{csr_val:08X}, got 0x{result['value']:016X}"
    assert result["exception"] is False, "unexpected exception"
    iface.clear_issue()
