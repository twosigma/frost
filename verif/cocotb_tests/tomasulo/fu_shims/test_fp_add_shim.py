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

"""Unit tests for the fp_add_shim module.

Tests FP add/sub, compare, classify, sign-injection operations, busy
signalling, and flush behavior through the shim interface.
"""

import re
from pathlib import Path
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from .fp_add_shim_interface import (
    FpAddShimInterface,
    nan_box_f32,
)
from config import XLEN

CLOCK_PERIOD_NS = 10

# Maximum cycles to wait for the shim to complete an operation before
# declaring a timeout.
MAX_LATENCY = 50

# ---------------------------------------------------------------------------
# IEEE 754 single-precision bit patterns
# ---------------------------------------------------------------------------
F32_1_0 = 0x3F80_0000  # 1.0f
F32_2_0 = 0x4000_0000  # 2.0f
F32_3_0 = 0x4040_0000  # 3.0f
F32_NEG_1_0 = 0xBF80_0000  # -1.0f

# NaN-boxed versions (upper 32 bits = 0xFFFFFFFF)
FLEN_1_0 = nan_box_f32(F32_1_0)
FLEN_2_0 = nan_box_f32(F32_2_0)
FLEN_3_0 = nan_box_f32(F32_3_0)
FLEN_NEG_1_0 = nan_box_f32(F32_NEG_1_0)


# ---------------------------------------------------------------------------
# Parse instr_op_e from riscv_pkg.sv so op values track the RTL source.
# ---------------------------------------------------------------------------
def _parse_instr_op_enum() -> dict[str, int]:
    """Parse the instr_op_e enum from riscv_pkg.sv and return name->value map.

    Handles both implicit sequential values and explicit assignments
    (e.g. ``FOO = 5``, ``BAR = 32'HDEAD_BEEF``).  Raises RuntimeError
    on parse failures so silent mis-numbering cannot occur.
    """
    pkg_path = (
        Path(__file__).resolve().parents[4]
        / "hw"
        / "rtl"
        / "cpu_and_mem"
        / "cpu"
        / "riscv_pkg.sv"
    )
    text = pkg_path.read_text()
    # Extract the enum body between 'typedef enum {' and '} instr_op_e;'
    m = re.search(r"typedef\s+enum\s*\{(.*?)\}\s*instr_op_e\s*;", text, re.DOTALL)
    if not m:
        raise RuntimeError("Could not find instr_op_e enum in riscv_pkg.sv")
    body = m.group(1)
    result: dict[str, int] = {}
    next_val = 0
    for line in body.splitlines():
        line = re.sub(r"//.*", "", line)  # strip comments
        line = re.sub(r"/\*.*?\*/", "", line)  # strip inline /* */
        line = line.strip().rstrip(",")
        if not line:
            continue
        # NAME = VALUE  (explicit assignment)
        # Supports: plain decimal (5), sized (8'd5, 32'hFF), unsized ('hFF),
        # octal (8'o17), binary (4'b1010), with optional _ separators.
        em = re.fullmatch(
            r"([A-Z_][A-Z0-9_]*)\s*=\s*(?:\d*'[bBdDhHoO])?([0-9a-fA-F_]+)",
            line,
        )
        if em:
            digits = em.group(2).replace("_", "")
            base = 10
            # Detect base from the format specifier preceding the digits
            bm = re.search(r"'([bBdDhHoO])", line)
            if bm:
                base = {"b": 2, "d": 10, "h": 16, "o": 8}[bm.group(1).lower()]
            try:
                next_val = int(digits, base)
            except ValueError as exc:
                raise RuntimeError(f"Cannot parse instr_op_e value: {line!r}") from exc
            result[em.group(1)] = next_val
            next_val += 1
            continue
        # NAME  (implicit sequential)
        if re.fullmatch(r"[A-Z_][A-Z0-9_]*", line):
            result[line] = next_val
            next_val += 1
            continue
        # Unrecognised non-blank line inside the enum -- fail loudly
        raise RuntimeError(f"Cannot parse instr_op_e entry: {line!r}")
    if not result:
        raise RuntimeError("instr_op_e enum body is empty")
    return result


_INSTR_OPS = _parse_instr_op_enum()


def _op(name: str) -> int:
    """Look up an instr_op_e value by name, raising KeyError on mismatch."""
    return _INSTR_OPS[name]


# ---------------------------------------------------------------------------
# Common setup helper
# ---------------------------------------------------------------------------
async def setup(dut: Any) -> FpAddShimInterface:
    """Start clock, reset DUT, and return the interface."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    iface = FpAddShimInterface(dut)
    await iface.reset()
    return iface


async def wait_for_complete(iface: FpAddShimInterface) -> dict:
    """Wait until o_fu_complete.valid is asserted, then return the result.

    Raises AssertionError if the result does not arrive within MAX_LATENCY
    cycles.
    """
    for cycle in range(MAX_LATENCY):
        await FallingEdge(iface.clock)
        result = iface.read_fu_complete()
        if result["valid"]:
            return result
    raise AssertionError(f"fu_complete.valid not asserted within {MAX_LATENCY} cycles")


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
# Test 2: FADD_S basic (1.0 + 2.0 = 3.0)
# ============================================================================
@cocotb.test()
async def test_fadd_s_basic(dut: Any) -> None:
    """FADD_S: 1.0 + 2.0 = 3.0, result NaN-boxed in 64 bits."""
    iface = await setup(dut)

    rob_tag = 1
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("FADD_S"),
        src1_value=FLEN_1_0,
        src2_value=FLEN_2_0,
        rm=0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_complete(iface)

    expected = nan_box_f32(F32_3_0)
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == expected, (
        f"value mismatch: got 0x{result['value']:016X}, " f"expected 0x{expected:016X}"
    )
    assert result["exception"] is False, "unexpected exception"


# ============================================================================
# Test 3: FSUB_S basic (3.0 - 1.0 = 2.0)
# ============================================================================
@cocotb.test()
async def test_fsub_s_basic(dut: Any) -> None:
    """FSUB_S: 3.0 - 1.0 = 2.0, result NaN-boxed in 64 bits."""
    iface = await setup(dut)

    rob_tag = 2
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("FSUB_S"),
        src1_value=FLEN_3_0,
        src2_value=FLEN_1_0,
        rm=0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_complete(iface)

    expected = nan_box_f32(F32_2_0)
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == expected, (
        f"value mismatch: got 0x{result['value']:016X}, " f"expected 0x{expected:016X}"
    )
    assert result["exception"] is False, "unexpected exception"


# ============================================================================
# Test 4: Busy during operation
# ============================================================================
@cocotb.test()
async def test_busy_during_operation(dut: Any) -> None:
    """After issuing FADD_S, o_fu_busy=1 while in-flight, 0 after completion."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=3,
        op=_op("FADD_S"),
        src1_value=FLEN_1_0,
        src2_value=FLEN_2_0,
        rm=0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()
    await FallingEdge(iface.clock)

    # The shim should be busy while the operation is in-flight
    busy_seen = iface.read_busy()
    assert busy_seen is True, "fu_busy should be 1 while operation is in-flight"

    # Wait for completion
    result = await wait_for_complete(iface)
    assert result["valid"] is True

    # After the result is produced, busy should drop on the next cycle
    await RisingEdge(iface.clock)
    await FallingEdge(iface.clock)
    assert iface.read_busy() is False, "fu_busy should be 0 after completion"


# ============================================================================
# Test 5: Flush clears in-flight operation
# ============================================================================
@cocotb.test()
async def test_flush_clears_inflight(dut: Any) -> None:
    """After issuing FADD_S then asserting i_flush, no valid output appears."""
    iface = await setup(dut)

    iface.drive_issue(
        valid=True,
        rob_tag=4,
        op=_op("FADD_S"),
        src1_value=FLEN_1_0,
        src2_value=FLEN_2_0,
        rm=0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    # Assert flush
    iface.drive_flush()
    await RisingEdge(iface.clock)
    iface.clear_flush()
    await FallingEdge(iface.clock)

    # The underlying subunit still runs to completion even after flush;
    # in_flight (and thus o_fu_busy) only clears once the subunit finishes.
    # The shim suppresses the result (valid=0) but we must wait for the
    # subunit to complete before busy drops.

    # Wait for busy to drop (subunit finishes), verify no valid output appears
    for _ in range(MAX_LATENCY):
        result = iface.read_fu_complete()
        assert result["valid"] is False, "fu_complete.valid should remain 0 after flush"
        if not iface.read_busy():
            break
        await RisingEdge(iface.clock)
        await FallingEdge(iface.clock)
    else:
        raise AssertionError(
            f"fu_busy did not drop within {MAX_LATENCY} cycles after flush"
        )

    # Confirm busy is 0 now
    assert iface.read_busy() is False, "fu_busy should be 0 after subunit completes"


# ============================================================================
# Test 6: FEQ_S with equal values -> result = 1 (integer)
# ============================================================================
@cocotb.test()
async def test_feq_s_equal(dut: Any) -> None:
    """FEQ_S: comparing 1.0 == 1.0 should produce integer result 1."""
    iface = await setup(dut)

    rob_tag = 5
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("FEQ_S"),
        src1_value=FLEN_1_0,
        src2_value=FLEN_1_0,
        rm=0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_complete(iface)

    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    # FEQ returns an integer 0 or 1 (not NaN-boxed); result is XLEN value
    assert (
        result["value"] == 1
    ), f"FEQ_S(1.0, 1.0) should be 1, got 0x{result['value']:016X}"
    assert result["exception"] is False, "unexpected exception"


# ============================================================================
# Test 7: FCLASS_S on a positive normal number
# ============================================================================
@cocotb.test()
async def test_fclass_s_positive_normal(dut: Any) -> None:
    """FCLASS_S on 1.0 (positive normal) should set bit 6 (0x40)."""
    iface = await setup(dut)

    rob_tag = 6
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("FCLASS_S"),
        src1_value=FLEN_1_0,
        src2_value=0,
        rm=0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_complete(iface)

    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    # FCLASS bit 6 = positive normal number
    expected_class = 0x40
    assert result["value"] == expected_class, (
        f"FCLASS_S(1.0) should be 0x{expected_class:X}, "
        f"got 0x{result['value']:016X}"
    )
    assert result["exception"] is False, "unexpected exception"


# ============================================================================
# Test 8: FSGNJ_S with different sign sources
# ============================================================================
@cocotb.test()
async def test_fsgnj_s(dut: Any) -> None:
    """FSGNJ_S: magnitude from src1 (1.0), sign from src2 (-1.0) -> -1.0."""
    iface = await setup(dut)

    rob_tag = 7
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("FSGNJ_S"),
        src1_value=FLEN_1_0,
        src2_value=FLEN_NEG_1_0,
        rm=0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_complete(iface)

    # FSGNJ takes magnitude of rs1 and sign of rs2
    # magnitude(1.0) = 0x3F800000, sign(-1.0) = 1 -> -1.0 = 0xBF800000
    expected = nan_box_f32(F32_NEG_1_0)
    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == expected, (
        f"FSGNJ_S(1.0, -1.0) should be 0x{expected:016X}, "
        f"got 0x{result['value']:016X}"
    )
    assert result["exception"] is False, "unexpected exception"


# ============================================================================
# Test 9: FMAX_D with a signaling NaN raises NV and returns the number
# ============================================================================
@cocotb.test()
async def test_fmax_d_snan_sets_invalid(dut: Any) -> None:
    """FMAX_D(sNaN, 1.0) returns 1.0 and raises invalid-operation."""
    iface = await setup(dut)

    rob_tag = 8
    snan_d = 0x7FF0_0000_0000_0001
    one_d = 0x3FF0_0000_0000_0000
    iface.drive_issue(
        valid=True,
        rob_tag=rob_tag,
        op=_op("FMAX_D"),
        src1_value=snan_d,
        src2_value=one_d,
        rm=0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()

    result = await wait_for_complete(iface)

    assert (
        result["tag"] == rob_tag
    ), f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    assert result["value"] == one_d, (
        f"FMAX_D(sNaN, 1.0) should be 0x{one_d:016X}, " f"got 0x{result['value']:016X}"
    )
    assert (
        result["fp_flags"] == 0x10
    ), f"FMAX_D(sNaN, 1.0) should raise NV only, got 0x{result['fp_flags']:02X}"
    assert result["exception"] is False, "unexpected exception"


@cocotb.test()
async def test_fmax_d_snan_after_clean_ops_sets_invalid(dut: Any) -> None:
    """A later FMAX_D(sNaN, 1.0) still raises NV after clean min/max ops."""
    iface = await setup(dut)

    one_d = 0x3FF0_0000_0000_0000
    two_d = 0x4000_0000_0000_0000
    neg_one_d = 0xBFF0_0000_0000_0000
    neg_two_d = 0xC000_0000_0000_0000
    snan_d = 0x7FF0_0000_0000_0001

    for tag, op_name, src1, src2, expected in [
        (9, "FMIN_D", two_d, one_d, one_d),
        (10, "FMAX_D", two_d, one_d, two_d),
        (11, "FMAX_D", neg_one_d, neg_two_d, neg_one_d),
    ]:
        iface.drive_issue(
            valid=True,
            rob_tag=tag,
            op=_op(op_name),
            src1_value=src1,
            src2_value=src2,
            rm=0,
        )
        await RisingEdge(iface.clock)
        iface.clear_issue()
        result = await wait_for_complete(iface)
        assert result["value"] == expected
        assert result["fp_flags"] == 0
        await RisingEdge(iface.clock)

    iface.drive_issue(
        valid=True,
        rob_tag=12,
        op=_op("FMAX_D"),
        src1_value=snan_d,
        src2_value=one_d,
        rm=0,
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()
    result = await wait_for_complete(iface)

    assert result["value"] == one_d
    assert result["fp_flags"] == 0x10


# ============================================================================
# RV64 vectors (M3 rung 4): W-form result sign-extension (unsigned included),
# 32-bit W saturation vs 64-bit L range, low-word operand pre-shaping,
# FMV.X.D/FMV.D.X, and unboxed compare results. Self-skip at XLEN=32.
# ============================================================================
MASK64 = 0xFFFF_FFFF_FFFF_FFFF

F32_3E9 = 0x4F32_D05E  # 3.0e9f (exactly representable)
F32_4E9 = 0x4F6E_6B28  # 4.0e9f (exactly representable)
F32_2P32 = 0x4F80_0000  # 2^32 as a float
F32_2P40 = 0x5380_0000  # 2^40 as a float
F32_2P64 = 0x5F80_0000  # 2^64 as a float
F64_NEG_2_0 = 0xC000_0000_0000_0000  # -2.0
F64_NEG_2P40 = 0xC270_0000_0000_0000  # -(2^40)
F64_2P63 = 0x43E0_0000_0000_0000  # 2^63
FFLAG_NV = 0x10
FFLAG_NX = 0x01


def _skip_unless_rv64() -> bool:
    return XLEN != 64


async def _run_op(
    dut: Any, op_name: str, src1: int, src2: int = 0, rm: int = 0
) -> dict:
    """Reset, issue a single op, and return its completion record."""
    iface = await setup(dut)
    iface.drive_issue(
        valid=True, rob_tag=7, op=_op(op_name), src1_value=src1, src2_value=src2, rm=rm
    )
    await RisingEdge(iface.clock)
    iface.clear_issue()
    return await wait_for_complete(iface)


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fcvt_w_s_sext(dut: Any) -> None:
    """FCVT.W.S(-1.0f): the 32-bit result sign-extends into the 64-bit rd."""
    result = await _run_op(dut, "FCVT_W_S", nan_box_f32(F32_NEG_1_0))
    assert result["value"] == MASK64, f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == 0


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fcvt_wu_s_sext(dut: Any) -> None:
    """FCVT.WU.S(3e9f): unsigned W results also sign-extend from bit 31."""
    result = await _run_op(dut, "FCVT_WU_S", nan_box_f32(F32_3E9))
    assert result["value"] == 0xFFFF_FFFF_B2D0_5E00, f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == 0


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fcvt_w_s_saturates_at_32_bits(dut: Any) -> None:
    """FCVT.W.S(4e9f) saturates at int32 max with NV, not at the 64-bit range."""
    result = await _run_op(dut, "FCVT_W_S", nan_box_f32(F32_4E9))
    assert result["value"] == 0x0000_0000_7FFF_FFFF, f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == FFLAG_NV


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fcvt_l_s_wide(dut: Any) -> None:
    """FCVT.L.S(4e9f) is in 64-bit range: no saturation, no flags."""
    result = await _run_op(dut, "FCVT_L_S", nan_box_f32(F32_4E9))
    assert result["value"] == 0x0000_0000_EE6B_2800, f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == 0


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fcvt_l_s_negative(dut: Any) -> None:
    """FCVT.L.S(-1.0f) produces the full-width 64-bit -1."""
    result = await _run_op(dut, "FCVT_L_S", nan_box_f32(F32_NEG_1_0))
    assert result["value"] == MASK64, f"got 0x{result['value']:016X}"


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fcvt_s_l_wide(dut: Any) -> None:
    """FCVT.S.L(2^40): the full 64-bit operand converts (a W-form would see 0)."""
    result = await _run_op(dut, "FCVT_S_L", 1 << 40)
    assert result["value"] == nan_box_f32(F32_2P40), f"got 0x{result['value']:016X}"


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fcvt_s_lu_full_width(dut: Any) -> None:
    """FCVT.S.LU(2^64-1): the whole register is the unsigned operand."""
    result = await _run_op(dut, "FCVT_S_LU", MASK64)
    assert result["value"] == nan_box_f32(F32_2P64), f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == FFLAG_NX


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fcvt_s_w_low_word(dut: Any) -> None:
    """FCVT.S.W converts the sign-extended low word: 0x00000000_FFFFFFFF -> -1.0f."""
    result = await _run_op(dut, "FCVT_S_W", 0x0000_0000_FFFF_FFFF)
    assert result["value"] == nan_box_f32(F32_NEG_1_0), f"got 0x{result['value']:016X}"


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fcvt_s_wu_low_word(dut: Any) -> None:
    """FCVT.S.WU zero-extends the low word: an all-ones register -> 2^32f, NX."""
    result = await _run_op(dut, "FCVT_S_WU", MASK64)
    assert result["value"] == nan_box_f32(F32_2P32), f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == FFLAG_NX


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fcvt_w_d_sext(dut: Any) -> None:
    """FCVT.W.D(-2.0): W-form results from the D instance sign-extend too."""
    result = await _run_op(dut, "FCVT_W_D", F64_NEG_2_0)
    assert result["value"] == MASK64 - 1, f"got 0x{result['value']:016X}"


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fcvt_lu_d_wide(dut: Any) -> None:
    """FCVT.LU.D(2^63) is in unsigned-64 range: no saturation, no flags."""
    result = await _run_op(dut, "FCVT_LU_D", F64_2P63)
    assert result["value"] == 0x8000_0000_0000_0000, f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == 0


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fcvt_d_l_roundtrip(dut: Any) -> None:
    """FCVT.D.L(-(2^40)) is exact, and FCVT.L.D returns the original integer."""
    result = await _run_op(dut, "FCVT_D_L", (-(1 << 40)) & MASK64)
    assert result["value"] == F64_NEG_2P40, f"got 0x{result['value']:016X}"
    result = await _run_op(dut, "FCVT_L_D", F64_NEG_2P40)
    assert result["value"] == (-(1 << 40)) & MASK64, f"got 0x{result['value']:016X}"


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fmv_x_w_sext(dut: Any) -> None:
    """FMV.X.W sign-extends the raw 32-bit pattern (upper operand bits ignored)."""
    result = await _run_op(dut, "FMV_X_W", 0x0000_0000_BF80_0000)
    assert result["value"] == 0xFFFF_FFFF_BF80_0000, f"got 0x{result['value']:016X}"


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_fmv_x_d_and_d_x(dut: Any) -> None:
    """FMV.X.D and FMV.D.X move the full 64-bit pattern verbatim."""
    pattern = 0x8000_0000_0000_0001
    result = await _run_op(dut, "FMV_X_D", pattern)
    assert result["value"] == pattern, f"got 0x{result['value']:016X}"
    pattern = 0x4008_0000_0000_0000  # 3.0
    result = await _run_op(dut, "FMV_D_X", pattern)
    assert result["value"] == pattern, f"got 0x{result['value']:016X}"


@cocotb.test(skip=_skip_unless_rv64())
async def test_rv64_feq_s_result_not_boxed(dut: Any) -> None:
    """FEQ.S writes exactly 0 or 1 into the 64-bit rd (no NaN-boxing)."""
    result = await _run_op(dut, "FEQ_S", FLEN_1_0, FLEN_1_0)
    assert result["value"] == 1, f"got 0x{result['value']:016X}"
