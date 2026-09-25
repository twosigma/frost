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

Tests FP add/sub, compare, min/max, classify, sign-injection, convert and
move operations, busy signalling, and flush behavior through the shim
interface.
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
    # Accept either an implicit enum base or a one-line bit/logic base.
    m = re.search(
        r"typedef\s+enum"
        r"(?:\s+(?:bit|logic)(?:\s+(?:signed|unsigned))?(?:\s*\[[^\r\n]+?\])?)?"
        r"\s*\{([^}]*)\}\s*instr_op_e\s*;",
        text,
        re.DOTALL,
    )
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
        # Any other non-blank line inside the enum is a parse failure.
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
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
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
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == expected, (
        f"value mismatch: got 0x{result['value']:016X}, expected 0x{expected:016X}"
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
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == expected, (
        f"value mismatch: got 0x{result['value']:016X}, expected 0x{expected:016X}"
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

    busy_seen = iface.read_busy()
    assert busy_seen is True, "fu_busy should be 1 while operation is in-flight"

    result = await wait_for_complete(iface)
    assert result["valid"] is True

    # Busy drops on the cycle after the result is produced.
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

    iface.drive_flush()
    await RisingEdge(iface.clock)
    iface.clear_flush()
    await FallingEdge(iface.clock)

    # A flush does not stop the subunit. in_flight, and so o_fu_busy, clears
    # only when the subunit finishes, and the shim drops the result it produces
    # (valid=0). Wait for busy to fall, checking that no valid output appears
    # on the way.
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

    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    # FEQ returns an integer 0 or 1 (not NaN-boxed); result is XLEN value
    assert result["value"] == 1, (
        f"FEQ_S(1.0, 1.0) should be 1, got 0x{result['value']:016X}"
    )
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

    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    # FCLASS bit 6 = positive normal number
    expected_class = 0x40
    assert result["value"] == expected_class, (
        f"FCLASS_S(1.0) should be 0x{expected_class:X}, got 0x{result['value']:016X}"
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
    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == expected, (
        f"FSGNJ_S(1.0, -1.0) should be 0x{expected:016X}, got 0x{result['value']:016X}"
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

    assert result["tag"] == rob_tag, (
        f"tag mismatch: got {result['tag']}, expected {rob_tag}"
    )
    assert result["value"] == one_d, (
        f"FMAX_D(sNaN, 1.0) should be 0x{one_d:016X}, got 0x{result['value']:016X}"
    )
    assert result["fp_flags"] == 0x10, (
        f"FMAX_D(sNaN, 1.0) should raise NV only, got 0x{result['fp_flags']:02X}"
    )
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
# RV64 vectors: W-form results sign-extend (unsigned ones too), W conversions
# saturate at 32 bits while L conversions have the full 64-bit range, W-form
# integer sources use only the low word, FMV.X.D and FMV.D.X move all 64 bits,
# and compare results are not NaN-boxed.
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


@cocotb.test()
async def test_rv64_fcvt_w_s_sext(dut: Any) -> None:
    """FCVT.W.S(-1.0f): the 32-bit result sign-extends into the 64-bit rd."""
    result = await _run_op(dut, "FCVT_W_S", nan_box_f32(F32_NEG_1_0))
    assert result["value"] == MASK64, f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == 0


@cocotb.test()
async def test_rv64_fcvt_wu_s_sext(dut: Any) -> None:
    """FCVT.WU.S(3e9f): unsigned W results also sign-extend from bit 31."""
    result = await _run_op(dut, "FCVT_WU_S", nan_box_f32(F32_3E9))
    assert result["value"] == 0xFFFF_FFFF_B2D0_5E00, f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == 0


@cocotb.test()
async def test_rv64_fcvt_w_s_saturates_at_32_bits(dut: Any) -> None:
    """FCVT.W.S(4e9f) saturates at int32 max with NV, not at the 64-bit range."""
    result = await _run_op(dut, "FCVT_W_S", nan_box_f32(F32_4E9))
    assert result["value"] == 0x0000_0000_7FFF_FFFF, f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == FFLAG_NV


@cocotb.test()
async def test_rv64_fcvt_l_s_wide(dut: Any) -> None:
    """FCVT.L.S(4e9f) is in 64-bit range: no saturation, no flags."""
    result = await _run_op(dut, "FCVT_L_S", nan_box_f32(F32_4E9))
    assert result["value"] == 0x0000_0000_EE6B_2800, f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == 0


@cocotb.test()
async def test_rv64_fcvt_l_s_negative(dut: Any) -> None:
    """FCVT.L.S(-1.0f) produces the full-width 64-bit -1."""
    result = await _run_op(dut, "FCVT_L_S", nan_box_f32(F32_NEG_1_0))
    assert result["value"] == MASK64, f"got 0x{result['value']:016X}"


@cocotb.test()
async def test_rv64_fcvt_s_l_wide(dut: Any) -> None:
    """FCVT.S.L(2^40): the full 64-bit operand converts (a W-form would see 0)."""
    result = await _run_op(dut, "FCVT_S_L", 1 << 40)
    assert result["value"] == nan_box_f32(F32_2P40), f"got 0x{result['value']:016X}"


@cocotb.test()
async def test_rv64_fcvt_s_lu_full_width(dut: Any) -> None:
    """FCVT.S.LU(2^64-1): the whole register is the unsigned operand."""
    result = await _run_op(dut, "FCVT_S_LU", MASK64)
    assert result["value"] == nan_box_f32(F32_2P64), f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == FFLAG_NX


@cocotb.test()
async def test_rv64_fcvt_s_w_low_word(dut: Any) -> None:
    """FCVT.S.W converts the sign-extended low word: 0x00000000_FFFFFFFF -> -1.0f."""
    result = await _run_op(dut, "FCVT_S_W", 0x0000_0000_FFFF_FFFF)
    assert result["value"] == nan_box_f32(F32_NEG_1_0), f"got 0x{result['value']:016X}"


@cocotb.test()
async def test_rv64_fcvt_s_wu_low_word(dut: Any) -> None:
    """FCVT.S.WU zero-extends the low word: an all-ones register -> 2^32f, NX."""
    result = await _run_op(dut, "FCVT_S_WU", MASK64)
    assert result["value"] == nan_box_f32(F32_2P32), f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == FFLAG_NX


@cocotb.test()
async def test_rv64_fcvt_w_d_sext(dut: Any) -> None:
    """FCVT.W.D(-2.0): W-form results from the D instance sign-extend too."""
    result = await _run_op(dut, "FCVT_W_D", F64_NEG_2_0)
    assert result["value"] == MASK64 - 1, f"got 0x{result['value']:016X}"


@cocotb.test()
async def test_rv64_fcvt_lu_d_wide(dut: Any) -> None:
    """FCVT.LU.D(2^63) is in unsigned-64 range: no saturation, no flags."""
    result = await _run_op(dut, "FCVT_LU_D", F64_2P63)
    assert result["value"] == 0x8000_0000_0000_0000, f"got 0x{result['value']:016X}"
    assert result["fp_flags"] == 0


@cocotb.test()
async def test_rv64_fcvt_d_l_roundtrip(dut: Any) -> None:
    """FCVT.D.L(-(2^40)) is exact, and FCVT.L.D returns the original integer."""
    result = await _run_op(dut, "FCVT_D_L", (-(1 << 40)) & MASK64)
    assert result["value"] == F64_NEG_2P40, f"got 0x{result['value']:016X}"
    result = await _run_op(dut, "FCVT_L_D", F64_NEG_2P40)
    assert result["value"] == (-(1 << 40)) & MASK64, f"got 0x{result['value']:016X}"


@cocotb.test()
async def test_rv64_fmv_x_w_sext(dut: Any) -> None:
    """FMV.X.W sign-extends the raw 32-bit pattern (upper operand bits ignored)."""
    result = await _run_op(dut, "FMV_X_W", 0x0000_0000_BF80_0000)
    assert result["value"] == 0xFFFF_FFFF_BF80_0000, f"got 0x{result['value']:016X}"


@cocotb.test()
async def test_rv64_fmv_x_d_and_d_x(dut: Any) -> None:
    """FMV.X.D and FMV.D.X move the full 64-bit pattern verbatim."""
    pattern = 0x8000_0000_0000_0001
    result = await _run_op(dut, "FMV_X_D", pattern)
    assert result["value"] == pattern, f"got 0x{result['value']:016X}"
    pattern = 0x4008_0000_0000_0000  # 3.0
    result = await _run_op(dut, "FMV_D_X", pattern)
    assert result["value"] == pattern, f"got 0x{result['value']:016X}"


@cocotb.test()
async def test_rv64_feq_s_result_not_boxed(dut: Any) -> None:
    """FEQ.S writes exactly 0 or 1 into the 64-bit rd (no NaN-boxing)."""
    result = await _run_op(dut, "FEQ_S", FLEN_1_0, FLEN_1_0)
    assert result["value"] == 1, f"got 0x{result['value']:016X}"


# ============================================================================
# Conversion corners in every rounding mode
# ============================================================================
RM_RNE, RM_RTZ, RM_RDN, RM_RUP, RM_RMM = range(5)
FFLAG_UF = 0x02
INT32_MIN_SEXT = 0xFFFF_FFFF_8000_0000
INT64_MIN = 0x8000_0000_0000_0000


async def _run_vectors(dut: Any, vectors: list[tuple[str, int, int, int, int]]) -> None:
    """Run (op, src1, rm, expected value, expected flags) vectors one at a time."""
    iface = await setup(dut)
    failures: list[str] = []
    for op_name, src1, rm, value, flags in vectors:
        iface.drive_issue(
            valid=True, rob_tag=7, op=_op(op_name), src1_value=src1, src2_value=0, rm=rm
        )
        await RisingEdge(iface.clock)
        iface.clear_issue()
        result = await wait_for_complete(iface)
        await RisingEdge(iface.clock)
        if result["value"] != value or result["fp_flags"] != flags:
            failures.append(
                f"{op_name}({src1:#018x}, rm={rm}): got {result['value']:#018x} flags "
                f"{result['fp_flags']:#04x}, expected {value:#018x} flags {flags:#04x}"
            )
    assert not failures, "\n".join(failures)


@cocotb.test()
async def test_fcvt_w_d_just_below_int32_min(dut: Any) -> None:
    """FCVT.W.D between -2^31-1 and -2^31: NX if it rounds to -2^31, NV otherwise."""
    nx, nv = FFLAG_NX, FFLAG_NV
    # Flags per rounding mode, in RNE, RTZ, RDN, RUP, RMM order. The result is
    # -2^31 in every case, the saturation value included.
    cases = [
        (0xC1E0_0000_0000_0000, (0, 0, 0, 0, 0)),  # -2^31
        (0xC1E0_0000_0000_0001, (nx, nx, nv, nx, nx)),  # next double below -2^31
        (0xC1E0_0000_0008_0000, (nx, nx, nv, nx, nx)),  # -2^31 - 0.25
        (0xC1E0_0000_0010_0000, (nx, nx, nv, nx, nv)),  # -2^31 - 0.5
        (0xC1E0_0000_0018_0000, (nv, nx, nv, nx, nv)),  # -2^31 - 0.75
        (0xC1E0_0000_0020_0000, (nv, nv, nv, nv, nv)),  # -2^31 - 1
    ]
    await _run_vectors(
        dut,
        [
            ("FCVT_W_D", src, rm, INT32_MIN_SEXT, flags[rm])
            for src, flags in cases
            for rm in range(5)
        ],
    )


@cocotb.test()
async def test_fcvt_signed_integer_min_boundaries(dut: Any) -> None:
    """The most negative integer converts exactly; the next FP value below it is NV."""
    cases = [
        ("FCVT_W_S", nan_box_f32(0xCF00_0000), INT32_MIN_SEXT, 0),  # -2^31
        ("FCVT_W_S", nan_box_f32(0xCF00_0001), INT32_MIN_SEXT, FFLAG_NV),
        ("FCVT_L_S", nan_box_f32(0xDF00_0000), INT64_MIN, 0),  # -2^63
        ("FCVT_L_S", nan_box_f32(0xDF00_0001), INT64_MIN, FFLAG_NV),
        ("FCVT_L_D", 0xC3E0_0000_0000_0000, INT64_MIN, 0),  # -2^63
        ("FCVT_L_D", 0xC3E0_0000_0000_0001, INT64_MIN, FFLAG_NV),
    ]
    await _run_vectors(
        dut,
        [
            (op_name, src, rm, value, flags)
            for op_name, src, value, flags in cases
            for rm in range(5)
        ],
    )


@cocotb.test()
async def test_fcvt_other_range_limits(dut: Any) -> None:
    """At the unsigned and upper range limits, NX if the rounded value fits, else NV."""
    nx, nv = FFLAG_NX, FFLAG_NV
    all_nv, exact = (nv,) * 5, (0,) * 5
    ones = 0xFFFF_FFFF_FFFF_FFFF  # UINT64_MAX, and UINT32_MAX sign-extended
    int64_max = 0x7FFF_FFFF_FFFF_FFFF
    # op -> (operand, result in every mode, flags in RNE, RTZ, RDN, RUP, RMM
    # order). At these limits the saturation value equals the nearest in-range
    # result, so only the flags depend on the mode.
    cases = {
        "FCVT_WU_D": [
            (0xBFE0_0000_0000_0000, 0, (nx, nx, nv, nx, nv)),  # -0.5
            (0xBFE8_0000_0000_0000, 0, (nv, nx, nv, nx, nv)),  # -0.75
            (0xBFF0_0000_0000_0000, 0, all_nv),  # -1
            (0x41EF_FFFF_FFF0_0000, ones, (nv, nx, nx, nv, nv)),  # 2^32 - 0.5
            (0x41F0_0000_0000_0000, ones, all_nv),  # 2^32
        ],
        "FCVT_W_D": [
            (0x41DF_FFFF_FFE0_0000, 0x7FFF_FFFF, (nv, nx, nx, nv, nv)),  # 2^31 - 0.5
        ],
        "FCVT_W_S": [
            (nan_box_f32(0x4EFF_FFFF), 0x7FFF_FF80, exact),  # 2^31 - 128
            (nan_box_f32(0x4F00_0000), 0x7FFF_FFFF, all_nv),  # 2^31
        ],
        "FCVT_WU_S": [
            (nan_box_f32(0xBF40_0000), 0, (nv, nx, nv, nx, nv)),  # -0.75
            (nan_box_f32(0x4F7F_FFFF), 0xFFFF_FFFF_FFFF_FF00, exact),  # 2^32 - 256
            (nan_box_f32(0x4F80_0000), ones, all_nv),  # 2^32
        ],
        "FCVT_L_S": [
            (nan_box_f32(0x5EFF_FFFF), 0x7FFF_FF80_0000_0000, exact),  # 2^63 - 2^39
            (nan_box_f32(0x5F00_0000), int64_max, all_nv),  # 2^63
        ],
        "FCVT_LU_S": [
            (nan_box_f32(0x5F7F_FFFF), 0xFFFF_FF00_0000_0000, exact),  # 2^64 - 2^40
            (nan_box_f32(0x5F80_0000), ones, all_nv),  # 2^64
        ],
        "FCVT_L_D": [
            (0x43DF_FFFF_FFFF_FFFF, 0x7FFF_FFFF_FFFF_FC00, exact),  # 2^63 - 1024
            (0x43E0_0000_0000_0000, int64_max, all_nv),  # 2^63
        ],
        "FCVT_LU_D": [
            (0xBFE0_0000_0000_0000, 0, (nx, nx, nv, nx, nv)),  # -0.5
            (0x43EF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_F800, exact),  # 2^64 - 2048
            (0x43F0_0000_0000_0000, ones, all_nv),  # 2^64
        ],
    }
    await _run_vectors(
        dut,
        [
            (op_name, src, rm, value, flags[rm])
            for op_name, rows in cases.items()
            for src, value, flags in rows
            for rm in range(5)
        ],
    )


@cocotb.test()
async def test_fcvt_s_d_tiny_directed_rounding(dut: Any) -> None:
    """FCVT.S.D far below the smallest subnormal: RUP and RDN round away from zero."""
    magnitudes = [
        0x0370_0000_0000_0000,  # 2^-200
        0x0000_0000_0000_0001,  # smallest double subnormal
        0x3660_0000_0000_0000,  # 2^-153
        0x366F_FFFF_FFFF_FFFF,  # just below 2^-152
        0x3670_0000_0000_0000,  # 2^-152
    ]
    vectors = []
    for magnitude in magnitudes:
        for negative in (False, True):
            sign = 0x8000_0000 if negative else 0
            for rm in range(5):
                away = (rm == RM_RUP and not negative) or (rm == RM_RDN and negative)
                expected = nan_box_f32(sign | int(away))
                src = magnitude | (INT64_MIN if negative else 0)
                vectors.append(("FCVT_S_D", src, rm, expected, FFLAG_UF | FFLAG_NX))
    await _run_vectors(dut, vectors)


@cocotb.test()
async def test_fcvt_s_d_rounds_up_to_min_normal(dut: Any) -> None:
    """FCVT.S.D just below 2^-126 can round up to the smallest normal, tiny or not.

    Underflow is decided after rounding as if the exponent range were
    unbounded, so 2^-126 - 2^-150 (24 significant bits) is tiny even when its
    subnormal rounding gives 2^-126.
    """
    min_normal, max_subnormal = 0x0080_0000, 0x007F_FFFF
    uf_nx = FFLAG_UF | FFLAG_NX
    # (magnitude, {rounding mode: (magnitude of result, flags)}) for a positive
    # operand; RDN and RUP swap for a negative one.
    cases = [
        (  # 2^-126 - 2^-179: not tiny after rounding to 24 bits
            0x380F_FFFF_FFFF_FFFF,
            {
                RM_RNE: (min_normal, FFLAG_NX),
                RM_RTZ: (max_subnormal, uf_nx),
                RM_RDN: (max_subnormal, uf_nx),
                RM_RUP: (min_normal, FFLAG_NX),
                RM_RMM: (min_normal, FFLAG_NX),
            },
        ),
        (  # 2^-126 - 2^-150: tiny, and a tie at subnormal precision
            0x380F_FFFF_E000_0000,
            {
                RM_RNE: (min_normal, uf_nx),
                RM_RTZ: (max_subnormal, uf_nx),
                RM_RDN: (max_subnormal, uf_nx),
                RM_RUP: (min_normal, uf_nx),
                RM_RMM: (min_normal, uf_nx),
            },
        ),
        (  # 2^-126 - 2^-149: the largest subnormal, exact
            0x380F_FFFF_C000_0000,
            {rm: (max_subnormal, 0) for rm in range(5)},
        ),
    ]
    vectors = []
    for magnitude, by_mode in cases:
        for negative in (False, True):
            for rm in range(5):
                mode = {RM_RDN: RM_RUP, RM_RUP: RM_RDN}.get(rm, rm) if negative else rm
                result, flags = by_mode[mode]
                sign = 0x8000_0000 if negative else 0
                src = magnitude | (INT64_MIN if negative else 0)
                vectors.append(("FCVT_S_D", src, rm, nan_box_f32(sign | result), flags))
    await _run_vectors(dut, vectors)
