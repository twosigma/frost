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

"""Cocotb tests for the fp_mul_shim module.

Verifies FMUL_S/D, FMADD/FMSUB/FNMADD/FNMSUB S/D operations through
the shim, including NaN-boxing of single-precision results, busy
back-pressure, and flush behavior.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from .fp_add_shim_interface import _parse_instr_op_enum
from .fp_mul_shim_interface import FpMulShimInterface

CLOCK_PERIOD_NS = 10

# ---------------------------------------------------------------------------
# Parse op codes from RTL source
# ---------------------------------------------------------------------------
_INSTR_OPS = _parse_instr_op_enum()

OP_FMUL_S = _INSTR_OPS["FMUL_S"]
OP_FMADD_S = _INSTR_OPS["FMADD_S"]
OP_FMSUB_S = _INSTR_OPS["FMSUB_S"]
OP_FNMADD_S = _INSTR_OPS["FNMADD_S"]
OP_FNMSUB_S = _INSTR_OPS["FNMSUB_S"]

# ---------------------------------------------------------------------------
# IEEE 754 single-precision constants (NaN-boxed in 64-bit)
# ---------------------------------------------------------------------------
NAN_BOX = 0xFFFF_FFFF_0000_0000

F32_1_0 = 0x3F80_0000
F32_2_0 = 0x4000_0000
F32_3_0 = 0x4040_0000
F32_5_0 = 0x40A0_0000
F32_6_0 = 0x40C0_0000
F32_7_0 = 0x40E0_0000

# NaN-boxed 64-bit representations for driving src values
SRC_1_0 = NAN_BOX | F32_1_0
SRC_2_0 = NAN_BOX | F32_2_0
SRC_3_0 = NAN_BOX | F32_3_0

# Expected NaN-boxed 64-bit results
RES_5_0 = NAN_BOX | F32_5_0
RES_6_0 = NAN_BOX | F32_6_0
RES_7_0 = NAN_BOX | F32_7_0

# Maximum cycles to wait for completion (mult ~9 cycles, fma ~10 cycles)
MAX_LATENCY = 20


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
async def setup(dut: Any) -> FpMulShimInterface:
    """Start clock, reset DUT, and return the interface."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    iface = FpMulShimInterface(dut)
    await iface.reset()
    return iface


async def wait_for_complete(dut: Any, iface: FpMulShimInterface) -> dict:
    """Wait until o_fu_complete.valid is asserted and return the unpacked result.

    Raises an assertion error if valid is not seen within MAX_LATENCY cycles.
    """
    for _ in range(MAX_LATENCY):
        await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        result = iface.read_fu_complete()
        if result["valid"]:
            return result
    raise AssertionError("fu_complete.valid not asserted within MAX_LATENCY cycles")


# ============================================================================
# Test 1: After reset, valid=0 and busy=0
# ============================================================================
@cocotb.test()
async def test_reset_state(dut: Any) -> None:
    """After reset, o_fu_complete.valid=0 and o_fu_busy=0."""
    iface = await setup(dut)

    result = iface.read_fu_complete()
    assert result["valid"] == 0, f"Expected valid=0 after reset, got {result['valid']}"
    assert not iface.read_busy(), "Expected busy=0 after reset"


# ============================================================================
# Test 2: FMUL_S basic -- 2.0 * 3.0 = 6.0 (NaN-boxed)
# ============================================================================
@cocotb.test()
async def test_fmul_s_basic(dut: Any) -> None:
    """FMUL_S: 2.0f * 3.0f = 6.0f, result is NaN-boxed."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=1,
        op=OP_FMUL_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
    )
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    # Clear issue after one cycle
    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)

    result = await wait_for_complete(dut, iface)

    assert result["valid"], "Expected valid completion"
    assert result["tag"] == 1, f"Expected tag=1, got {result['tag']}"
    assert result["value"] == RES_6_0, (
        f"Expected NaN-boxed 6.0f (0x{RES_6_0:016X}), " f"got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 3: FMADD_S basic -- 2.0 * 3.0 + 1.0 = 7.0
# ============================================================================
@cocotb.test()
async def test_fmadd_s_basic(dut: Any) -> None:
    """FMADD_S: src1=2.0f, src2=3.0f, src3=1.0f -> 2.0*3.0+1.0 = 7.0f."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=2,
        op=OP_FMADD_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
        src3_value=SRC_1_0,
    )
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)

    result = await wait_for_complete(dut, iface)

    assert result["valid"], "Expected valid completion"
    assert result["tag"] == 2, f"Expected tag=2, got {result['tag']}"
    assert result["value"] == RES_7_0, (
        f"Expected NaN-boxed 7.0f (0x{RES_7_0:016X}), " f"got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 4: FMSUB_S basic -- 2.0 * 3.0 - 1.0 = 5.0
# ============================================================================
@cocotb.test()
async def test_fmsub_s_basic(dut: Any) -> None:
    """FMSUB_S: src1=2.0f, src2=3.0f, src3=1.0f -> 2.0*3.0-1.0 = 5.0f."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=3,
        op=OP_FMSUB_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
        src3_value=SRC_1_0,
    )
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)

    result = await wait_for_complete(dut, iface)

    assert result["valid"], "Expected valid completion"
    assert result["tag"] == 3, f"Expected tag=3, got {result['tag']}"
    assert result["value"] == RES_5_0, (
        f"Expected NaN-boxed 5.0f (0x{RES_5_0:016X}), " f"got 0x{result['value']:016X}"
    )


# ============================================================================
# Test 5: Busy during operation
# ============================================================================
@cocotb.test()
async def test_busy_during_operation(dut: Any) -> None:
    """Fire FMUL_S, check busy=1 during computation, busy=0 after completion."""
    iface = await setup(dut)

    assert not iface.read_busy(), "busy should be 0 before issue"

    iface.drive_issue(
        valid=True,
        rob_tag=4,
        op=OP_FMUL_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
    )
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    # Clear issue after one cycle
    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)

    # Check busy is asserted during computation
    assert iface.read_busy(), "busy should be 1 while operation is in-flight"

    # Wait for completion
    result = await wait_for_complete(dut, iface)
    assert result["valid"], "Expected valid completion"

    # After completion, busy should deassert on the next cycle
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    assert not iface.read_busy(), "busy should be 0 after completion"


# ============================================================================
# Test 6: Flush clears in-flight operation
# ============================================================================
@cocotb.test()
async def test_flush_clears_inflight(dut: Any) -> None:
    """Fire FMUL_S, assert i_flush, verify no valid output appears."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=5,
        op=OP_FMUL_S,
        src1_value=SRC_2_0,
        src2_value=SRC_3_0,
    )
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    # Clear issue and assert flush
    iface.drive_issue(valid=False, rob_tag=0, op=0, src1_value=0, src2_value=0)
    iface.drive_flush()

    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)

    iface.clear_flush()

    # Wait enough cycles for the operation to have completed (if not flushed)
    for _ in range(MAX_LATENCY):
        await RisingEdge(dut.i_clk)
        await FallingEdge(dut.i_clk)
        result = iface.read_fu_complete()
        assert not result["valid"], (
            "Expected no valid output after flush, "
            f"but got valid with tag={result['tag']}"
        )
