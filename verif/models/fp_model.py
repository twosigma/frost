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

"""IEEE 754 single-precision floating-point model for F extension verification.

FP Model
========

This module implements software models for all RISC-V F extension operations.
It uses Python's struct module to perform bit-accurate IEEE 754 conversions.

The model handles:
    - Arithmetic operations (add, sub, mul, div, sqrt, fma)
    - Sign manipulation (fsgnj, fsgnjn, fsgnjx)
    - Min/max operations
    - Comparisons (feq, flt, fle)
    - Conversions (float<->int)
    - Classification (fclass)
    - Bit moves (fmv.x.w, fmv.w.x)

Special Value Handling:
    - NaN: Uses canonical quiet NaN (0x7FC00000) for results
    - Infinity: ±Inf handled per IEEE 754
    - Zero: Both +0 and -0 supported

Note: This model uses round-to-nearest-even (RNE) mode for simplicity.
The RTL uses dynamic rounding mode, but for random testing with random
operands, the difference is negligible for coverage purposes.
"""

from __future__ import annotations

import math
import struct
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from models.memory_model import MemoryModel


def _fma_float32(a_bits: int, b_bits: int, c_bits: int) -> int:
    """Compute single-precision fused multiply-add: (a * b) + c with single rounding.

    This function computes the FMA using exact integer arithmetic to avoid
    double-rounding issues that occur when using Python's float64-based math.fma().

    The algorithm:
    1. Handle special cases (inf, zero) first
    2. Unpack float32 operands to sign, exponent, mantissa
    3. Compute product mantissa exactly (48 bits from 24x24)
    4. Align addend to product's exponent
    5. Add/subtract with full precision
    6. Normalize and round once to float32

    Returns:
        32-bit IEEE 754 single-precision result
    """
    from decimal import Decimal, localcontext, ROUND_HALF_EVEN

    # Helper functions for special value detection
    def _is_inf(bits: int) -> bool:
        return ((bits >> 23) & 0xFF) == 0xFF and (bits & 0x7FFFFF) == 0

    def _is_zero(bits: int) -> bool:
        return (bits & 0x7FFFFFFF) == 0

    def _get_sign(bits: int) -> int:
        return (bits >> 31) & 1

    # Handle infinity cases that weren't caught by caller
    a_inf = _is_inf(a_bits)
    b_inf = _is_inf(b_bits)
    c_inf = _is_inf(c_bits)
    a_zero = _is_zero(a_bits)
    b_zero = _is_zero(b_bits)

    # inf * 0 = NaN (should be caught by caller, but just in case)
    if (a_inf and b_zero) or (a_zero and b_inf):
        return FP_CANONICAL_NAN

    # Product is infinity
    if a_inf or b_inf:
        prod_sign = _get_sign(a_bits) ^ _get_sign(b_bits)
        if c_inf:
            c_sign = _get_sign(c_bits)
            if prod_sign != c_sign:
                # inf + (-inf) = NaN
                return FP_CANONICAL_NAN
            else:
                # inf + inf = inf (same sign)
                return FP_NEG_INF if prod_sign else FP_POS_INF
        else:
            # inf + finite = inf
            return FP_NEG_INF if prod_sign else FP_POS_INF

    # Product is finite but c is infinity
    if c_inf:
        c_sign = _get_sign(c_bits)
        return FP_NEG_INF if c_sign else FP_POS_INF

    # All operands are finite - use Decimal with local context for determinism
    # Using localcontext() instead of getcontext() to avoid global state mutation
    # Need high precision to handle 48-bit product + alignment shifts without loss
    with localcontext() as ctx:
        ctx.prec = 150
        ctx.rounding = ROUND_HALF_EVEN

        def unpack_float32(bits: int) -> tuple[int, int, int]:
            """Unpack float32 to (sign, exponent, mantissa)."""
            sign = (bits >> 31) & 1
            exp = (bits >> 23) & 0xFF
            mant = bits & 0x7FFFFF
            return sign, exp, mant

        def float32_to_decimal(bits: int) -> Decimal:
            """Convert float32 bits to exact Decimal representation."""
            sign, exp, mant = unpack_float32(bits)

            if exp == 0:
                if mant == 0:
                    return Decimal("0") if sign == 0 else Decimal("-0")  # ±0
                # Subnormal: (-1)^sign * 2^(-126) * (0.mant)
                value = Decimal(mant) * Decimal(2) ** Decimal(-149)
            else:
                # Normal: (-1)^sign * 2^(exp-127) * (1.mant)
                value = (Decimal(0x800000 | mant)) * Decimal(2) ** Decimal(exp - 150)

            return -value if sign else value

        def decimal_to_float32(d: Decimal) -> int:
            """Convert Decimal to float32 bits with proper rounding.

            This implements direct single-precision rounding from Decimal to avoid
            double-rounding issues that occur when going Decimal -> float64 -> float32.

            Uses integer arithmetic where possible for exact bit extraction.
            """
            if d.is_nan():
                return FP_CANONICAL_NAN
            if d.is_infinite():
                return FP_NEG_INF if d < 0 else FP_POS_INF
            if d == 0:
                # Preserve sign of zero
                return FP_NEG_ZERO if d.is_signed() else FP_POS_ZERO

            # Extract sign and work with absolute value
            sign = 1 if d < 0 else 0
            d_abs = abs(d)

            # Find the binary exponent using binary search (no floating-point ln)
            # Find e such that 2^e <= d_abs < 2^(e+1)
            two = Decimal(2)

            # Start with bounds - float32 exponent range is -126 to +127 for normals
            # but we need to handle larger values for overflow detection
            if d_abs >= 1:
                # Search upward from 0
                exp_estimate = 0
                power = Decimal(1)
                while power * 2 <= d_abs:
                    power *= 2
                    exp_estimate += 1
                # Now 2^exp_estimate <= d_abs < 2^(exp_estimate+1)
            else:
                # Search downward from 0
                exp_estimate = -1
                power = Decimal("0.5")
                while power > d_abs:
                    power /= 2
                    exp_estimate -= 1
                # Now 2^exp_estimate <= d_abs < 2^(exp_estimate+1)

            # Verify our exponent is correct
            power_low = two**exp_estimate
            power_high = two ** (exp_estimate + 1)
            assert (
                power_low <= d_abs < power_high
            ), f"Exponent calc error: {power_low} <= {d_abs} < {power_high}"

            # IEEE 754 single precision:
            # - Exponent bias is 127
            # - Mantissa has 23 explicit bits (24 including implicit 1)
            # - Biased exponent range: 1-254 for normals, 0 for subnormals

            biased_exp = exp_estimate + 127

            if biased_exp >= 255:
                # Overflow to infinity
                return FP_NEG_INF if sign else FP_POS_INF
            elif biased_exp >= 1:
                # Normal number
                # Scale to get 26+ bits for guard/round/sticky extraction
                # We want significand * 2^25 where significand = d_abs / 2^exp_estimate
                # So we compute d_abs * 2^(25 - exp_estimate)

                # To get more sticky bits, scale by 2^50 instead of 2^25
                scale_exp = 50 - exp_estimate
                if scale_exp >= 0:
                    scaled = d_abs * (two**scale_exp)
                else:
                    scaled = d_abs / (two ** (-scale_exp))

                # Convert to integer - this is now exact for values that fit
                scaled_int = int(scaled)
                remainder = scaled - scaled_int

                # scaled_int has bits arranged as:
                # [50:27] = 24-bit mantissa (with implicit 1)
                # [26] = guard
                # [25] = round
                # [24:0] = sticky bits (plus remainder)

                mantissa_24 = scaled_int >> 27
                guard = (scaled_int >> 26) & 1
                round_bit = (scaled_int >> 25) & 1
                sticky = 1 if ((scaled_int & 0x1FFFFFF) != 0 or remainder != 0) else 0

                # Round to nearest even (RNE)
                lsb = mantissa_24 & 1
                round_up = guard & (round_bit | sticky | lsb)

                if round_up:
                    mantissa_24 += 1
                    # Check for mantissa overflow (1.111...1 + 1 = 10.000...0)
                    if mantissa_24 >= (1 << 24):
                        mantissa_24 >>= 1
                        biased_exp += 1
                        if biased_exp >= 255:
                            return FP_NEG_INF if sign else FP_POS_INF

                # Remove implicit 1 bit to get 23-bit mantissa
                mantissa_23 = mantissa_24 & 0x7FFFFF
                return (sign << 31) | (biased_exp << 23) | mantissa_23
            else:
                # Subnormal or underflow
                # For subnormals, biased_exp = 0, and we denormalize
                shift = 1 - biased_exp  # How much to right-shift the mantissa

                if shift >= 25:
                    # Complete underflow to zero
                    return FP_NEG_ZERO if sign else FP_POS_ZERO

                # Scale for subnormal: we need bits positioned for 2^(-126) base
                # Scale by 2^(50 + biased_exp - 1) = 2^(49 + biased_exp)
                scale_exp = 49 + biased_exp - exp_estimate
                if scale_exp >= 0:
                    scaled = d_abs * (two**scale_exp)
                else:
                    scaled = d_abs / (two ** (-scale_exp))

                scaled_int = int(scaled)
                remainder = scaled - scaled_int

                # Extract mantissa, guard, round, sticky
                mantissa = scaled_int >> 27
                guard = (scaled_int >> 26) & 1
                round_bit = (scaled_int >> 25) & 1
                sticky = 1 if ((scaled_int & 0x1FFFFFF) != 0 or remainder != 0) else 0

                # Round to nearest even
                lsb = mantissa & 1
                round_up = guard & (round_bit | sticky | lsb)

                if round_up:
                    mantissa += 1
                    # If mantissa overflows to 2^23, it becomes smallest normal
                    if mantissa >= (1 << 23):
                        return (sign << 31) | (1 << 23)  # Smallest normal

                mantissa_23 = mantissa & 0x7FFFFF
                return (sign << 31) | mantissa_23  # biased_exp = 0 for subnormal

        # Convert operands to Decimal
        a_dec = float32_to_decimal(a_bits)
        b_dec = float32_to_decimal(b_bits)
        c_dec = float32_to_decimal(c_bits)

        # Compute FMA exactly
        result_dec = a_dec * b_dec + c_dec

        # Convert back to float32 (single rounding)
        return decimal_to_float32(result_dec)


def _fma_float64(a_bits: int, b_bits: int, c_bits: int) -> int:
    """Compute double-precision fused multiply-add with single rounding.

    This uses exact integer arithmetic to avoid double-rounding and to provide
    deterministic results when math.fma() is unavailable.
    """

    def _unpack(bits: int) -> tuple[int, int, int]:
        """Return (sign, exp2, sig) where value = (-1)^sign * sig * 2^exp2."""
        sign = (bits >> 63) & 1
        exp = (bits >> 52) & 0x7FF
        mant = bits & DP_MANT_MASK
        if exp == 0:
            # Subnormal or zero: value = mant * 2^-1074
            return sign, -1074, mant
        # Normal: value = (1.mant) * 2^(exp-1023)
        return sign, exp - 1023 - 52, (1 << 52) | mant

    def _round_to_double(sign: int, sig: int, exp2: int) -> int:
        """Round exact value (sig * 2^exp2) to IEEE754 double (RNE)."""
        if sig == 0:
            # Exact zero (RNE) -> +0
            return DP_POS_ZERO

        n_bits = sig.bit_length()
        exp_unbiased = exp2 + n_bits - 1

        if exp_unbiased > 1023:
            return DP_NEG_INF if sign else DP_POS_INF

        if exp_unbiased >= -1022:
            # Normal number: keep 53-bit significand (incl implicit 1)
            shift = n_bits - 53
            if shift > 0:
                sig_53 = sig >> shift
                rem = sig & ((1 << shift) - 1)
                guard = (sig >> (shift - 1)) & 1
                sticky = 1 if (rem & ((1 << (shift - 1)) - 1)) != 0 else 0
                lsb = sig_53 & 1
                if guard and (sticky or lsb):
                    sig_53 += 1
                    if sig_53 >= (1 << 53):
                        sig_53 >>= 1
                        exp_unbiased += 1
                        if exp_unbiased > 1023:
                            return DP_NEG_INF if sign else DP_POS_INF
            elif shift < 0:
                sig_53 = sig << (-shift)
            else:
                sig_53 = sig

            exp_bits = exp_unbiased + 1023
            mant = sig_53 & DP_MANT_MASK
            return (sign << 63) | (exp_bits << 52) | mant

        # Subnormal: round to nearest 2^-1074
        shift = -(exp2 + 1074)
        if shift > 0:
            mant = sig >> shift
            rem = sig & ((1 << shift) - 1)
            guard = (sig >> (shift - 1)) & 1
            sticky = 1 if (rem & ((1 << (shift - 1)) - 1)) != 0 else 0
            lsb = mant & 1
            if guard and (sticky or lsb):
                mant += 1
        else:
            mant = sig << (-shift)

        if mant >= (1 << 52):
            # Rounds up to smallest normal
            return (sign << 63) | (1 << 52)
        if mant == 0:
            return DP_NEG_ZERO if sign else DP_POS_ZERO
        return (sign << 63) | (mant & DP_MANT_MASK)

    sign_a, exp_a, sig_a = _unpack(a_bits)
    sign_b, exp_b, sig_b = _unpack(b_bits)
    sign_c, exp_c, sig_c = _unpack(c_bits)

    # Exact product
    sign_p = sign_a ^ sign_b
    sig_p = sig_a * sig_b
    exp_p = exp_a + exp_b

    # Align to the smaller exponent for exact sum
    if exp_p >= exp_c:
        sig_p_shift = sig_p << (exp_p - exp_c)
        sig_c_shift = sig_c
        exp_min = exp_c
    else:
        sig_p_shift = sig_p
        sig_c_shift = sig_c << (exp_c - exp_p)
        exp_min = exp_p

    if sign_p == sign_c:
        sig_sum = sig_p_shift + sig_c_shift
        sign_sum = sign_p
    else:
        if sig_p_shift >= sig_c_shift:
            sig_sum = sig_p_shift - sig_c_shift
            sign_sum = sign_p
        else:
            sig_sum = sig_c_shift - sig_p_shift
            sign_sum = sign_c

    # Exact zero: sign depends on operand signs (RNE behavior).
    if sig_sum == 0:
        if sign_p == sign_c:
            return DP_NEG_ZERO if sign_p else DP_POS_ZERO
        return DP_POS_ZERO

    return _round_to_double(sign_sum, sig_sum, exp_min)


def _round_to_nearest_even(value: float) -> int:
    """Round to nearest even (RNE) and return as int."""
    # Python's round() implements bankers rounding (ties to even).
    return int(round(value))


# IEEE 754 single-precision constants
FP_POS_ZERO = 0x00000000
FP_NEG_ZERO = 0x80000000
FP_POS_INF = 0x7F800000
FP_NEG_INF = 0xFF800000
FP_CANONICAL_NAN = 0x7FC00000  # Canonical quiet NaN

# Masks for IEEE 754 single-precision
FP_SIGN_MASK = 0x80000000
FP_EXP_MASK = 0x7F800000
FP_MANT_MASK = 0x007FFFFF
MASK32 = 0xFFFFFFFF
MASK64 = 0xFFFFFFFFFFFFFFFF
FP32_NANBOX_MASK = 0xFFFFFFFF00000000


def box32(bits32: int) -> int:
    """NaN-box a 32-bit float into a 64-bit FP register value."""
    return (FP32_NANBOX_MASK | (bits32 & MASK32)) & MASK64


def unbox32(bits64: int) -> int:
    """Unbox a 64-bit FP register to 32-bit float bits.

    If the value is not NaN-boxed (upper 32 bits are not all 1s), return
    canonical quiet NaN per the RISC-V NaN-boxing rules.
    """
    if (bits64 & FP32_NANBOX_MASK) != FP32_NANBOX_MASK:
        return FP_CANONICAL_NAN
    return bits64 & MASK32


# IEEE 754 double-precision constants
DP_POS_ZERO = 0x0000000000000000
DP_NEG_ZERO = 0x8000000000000000
DP_POS_INF = 0x7FF0000000000000
DP_NEG_INF = 0xFFF0000000000000
DP_CANONICAL_NAN = 0x7FF8000000000000  # Canonical quiet NaN

# Masks for IEEE 754 double-precision
DP_SIGN_MASK = 0x8000000000000000
DP_EXP_MASK = 0x7FF0000000000000
DP_MANT_MASK = 0x000FFFFFFFFFFFFF


def bits_to_float(bits: int) -> float:
    """Convert 32-bit integer to IEEE 754 single-precision float."""
    packed = struct.pack(">I", bits & MASK32)
    return struct.unpack(">f", packed)[0]


def float_to_bits(f: float) -> int:
    """Convert IEEE 754 single-precision float to 32-bit integer."""
    if math.isnan(f):
        return FP_CANONICAL_NAN
    if math.isinf(f):
        return FP_NEG_INF if f < 0.0 else FP_POS_INF
    try:
        packed = struct.pack(">f", f)
    except OverflowError:
        # Value too large for float32: saturate to signed infinity.
        return FP_NEG_INF if f < 0.0 else FP_POS_INF
    return struct.unpack(">I", packed)[0]


def bits_to_double(bits: int) -> float:
    """Convert 64-bit integer to IEEE 754 double-precision float."""
    packed = struct.pack(">Q", bits & MASK64)
    return struct.unpack(">d", packed)[0]


def double_to_bits(d: float) -> int:
    """Convert IEEE 754 double-precision float to 64-bit integer."""
    if math.isnan(d):
        return DP_CANONICAL_NAN
    if math.isinf(d):
        return DP_NEG_INF if d < 0.0 else DP_POS_INF
    packed = struct.pack(">d", d)
    return struct.unpack(">Q", packed)[0]


def is_nan(bits: int) -> bool:
    """Check if bits represent a NaN value."""
    exp = (bits & FP_EXP_MASK) >> 23
    mant = bits & FP_MANT_MASK
    return exp == 0xFF and mant != 0


def is_inf(bits: int) -> bool:
    """Check if bits represent an infinity value."""
    exp = (bits & FP_EXP_MASK) >> 23
    mant = bits & FP_MANT_MASK
    return exp == 0xFF and mant == 0


def is_zero(bits: int) -> bool:
    """Check if bits represent a zero value (+0 or -0)."""
    return (bits & 0x7FFFFFFF) == 0


def is_subnormal(bits: int) -> bool:
    """Check if bits represent a subnormal (denormalized) number."""
    exp = (bits & FP_EXP_MASK) >> 23
    mant = bits & FP_MANT_MASK
    return exp == 0 and mant != 0


def is_negative(bits: int) -> bool:
    """Check if the sign bit is set."""
    return bool(bits & FP_SIGN_MASK)


def is_nan_d(bits: int) -> bool:
    """Check if bits represent a NaN value (double-precision)."""
    exp = (bits & DP_EXP_MASK) >> 52
    mant = bits & DP_MANT_MASK
    return exp == 0x7FF and mant != 0


def is_inf_d(bits: int) -> bool:
    """Check if bits represent an infinity value (double-precision)."""
    exp = (bits & DP_EXP_MASK) >> 52
    mant = bits & DP_MANT_MASK
    return exp == 0x7FF and mant == 0


def is_zero_d(bits: int) -> bool:
    """Check if bits represent a zero value (+0 or -0) (double-precision)."""
    return (bits & ~DP_SIGN_MASK) == 0


def is_negative_d(bits: int) -> bool:
    """Check if the sign bit is set (double-precision)."""
    return bool(bits & DP_SIGN_MASK)


def canonicalize_nan(bits: int) -> int:
    """Convert any NaN to canonical quiet NaN."""
    if is_nan(bits):
        return FP_CANONICAL_NAN
    return bits


# ============================================================================
# Arithmetic operations
# ============================================================================


def fadd_s(rs1_bits: int, rs2_bits: int) -> int:
    """FADD.S: rd = rs1 + rs2 (single-precision add)."""
    if is_nan(rs1_bits) or is_nan(rs2_bits):
        return FP_CANONICAL_NAN
    f1 = bits_to_float(rs1_bits)
    f2 = bits_to_float(rs2_bits)
    result = f1 + f2
    result_bits = float_to_bits(result)
    return canonicalize_nan(result_bits)


def fsub_s(rs1_bits: int, rs2_bits: int) -> int:
    """FSUB.S: rd = rs1 - rs2 (single-precision subtract)."""
    if is_nan(rs1_bits) or is_nan(rs2_bits):
        return FP_CANONICAL_NAN
    f1 = bits_to_float(rs1_bits)
    f2 = bits_to_float(rs2_bits)
    result = f1 - f2
    result_bits = float_to_bits(result)
    return canonicalize_nan(result_bits)


def fmul_s(rs1_bits: int, rs2_bits: int) -> int:
    """FMUL.S: rd = rs1 * rs2 (single-precision multiply)."""
    if is_nan(rs1_bits) or is_nan(rs2_bits):
        return FP_CANONICAL_NAN
    # Handle 0 * inf = NaN
    if (is_zero(rs1_bits) and is_inf(rs2_bits)) or (
        is_inf(rs1_bits) and is_zero(rs2_bits)
    ):
        return FP_CANONICAL_NAN
    f1 = bits_to_float(rs1_bits)
    f2 = bits_to_float(rs2_bits)
    result = f1 * f2
    result_bits = float_to_bits(result)
    return canonicalize_nan(result_bits)


def fdiv_s(rs1_bits: int, rs2_bits: int) -> int:
    """FDIV.S: rd = rs1 / rs2 (single-precision divide)."""
    if is_nan(rs1_bits) or is_nan(rs2_bits):
        return FP_CANONICAL_NAN
    # Handle special cases
    if is_inf(rs1_bits) and is_inf(rs2_bits):
        return FP_CANONICAL_NAN
    if is_zero(rs1_bits) and is_zero(rs2_bits):
        return FP_CANONICAL_NAN
    f1 = bits_to_float(rs1_bits)
    f2 = bits_to_float(rs2_bits)
    if f2 == 0.0:
        # Division by zero returns signed infinity
        sign = (rs1_bits ^ rs2_bits) & FP_SIGN_MASK
        return FP_POS_INF | sign
    result = f1 / f2
    result_bits = float_to_bits(result)
    return canonicalize_nan(result_bits)


def fsqrt_s(rs1_bits: int, _unused: int = 0) -> int:
    """FSQRT.S: rd = sqrt(rs1) (single-precision square root)."""
    if is_nan(rs1_bits):
        return FP_CANONICAL_NAN
    if is_negative(rs1_bits) and not is_zero(rs1_bits):
        # sqrt of negative number is NaN
        return FP_CANONICAL_NAN
    f1 = bits_to_float(rs1_bits)
    result = math.sqrt(f1)
    result_bits = float_to_bits(result)
    return canonicalize_nan(result_bits)


def _negate_float32(bits: int) -> int:
    """Negate a float32 value by flipping its sign bit."""
    return bits ^ FP_SIGN_MASK


def fmadd_s(rs1_bits: int, rs2_bits: int, rs3_bits: int) -> int:
    """FMADD.S: rd = rs1 * rs2 + rs3 (fused multiply-add)."""
    if is_nan(rs1_bits) or is_nan(rs2_bits) or is_nan(rs3_bits):
        return FP_CANONICAL_NAN
    # Handle 0 * inf cases
    if (is_zero(rs1_bits) and is_inf(rs2_bits)) or (
        is_inf(rs1_bits) and is_zero(rs2_bits)
    ):
        return FP_CANONICAL_NAN
    # Handle inf + (-inf) = NaN when product is inf
    if is_inf(rs1_bits) or is_inf(rs2_bits):
        prod_sign = ((rs1_bits >> 31) ^ (rs2_bits >> 31)) & 1
        if is_inf(rs3_bits) and ((rs3_bits >> 31) & 1) != prod_sign:
            return FP_CANONICAL_NAN
    # Use true single-precision FMA
    result_bits = _fma_float32(rs1_bits, rs2_bits, rs3_bits)
    return canonicalize_nan(result_bits)


def fmsub_s(rs1_bits: int, rs2_bits: int, rs3_bits: int) -> int:
    """FMSUB.S: rd = rs1 * rs2 - rs3 (fused multiply-subtract)."""
    if is_nan(rs1_bits) or is_nan(rs2_bits) or is_nan(rs3_bits):
        return FP_CANONICAL_NAN
    if (is_zero(rs1_bits) and is_inf(rs2_bits)) or (
        is_inf(rs1_bits) and is_zero(rs2_bits)
    ):
        return FP_CANONICAL_NAN
    # Handle inf - inf = NaN
    if is_inf(rs1_bits) or is_inf(rs2_bits):
        prod_sign = ((rs1_bits >> 31) ^ (rs2_bits >> 31)) & 1
        c_negated_sign = 1 - ((rs3_bits >> 31) & 1)  # Negated rs3 sign
        if is_inf(rs3_bits) and c_negated_sign != prod_sign:
            return FP_CANONICAL_NAN
    # FMSUB = FMA(a, b, -c)
    result_bits = _fma_float32(rs1_bits, rs2_bits, _negate_float32(rs3_bits))
    return canonicalize_nan(result_bits)


def fnmadd_s(rs1_bits: int, rs2_bits: int, rs3_bits: int) -> int:
    """FNMADD.S: rd = -(rs1 * rs2) - rs3."""
    if is_nan(rs1_bits) or is_nan(rs2_bits) or is_nan(rs3_bits):
        return FP_CANONICAL_NAN
    if (is_zero(rs1_bits) and is_inf(rs2_bits)) or (
        is_inf(rs1_bits) and is_zero(rs2_bits)
    ):
        return FP_CANONICAL_NAN
    # Handle -inf + (-inf) = NaN case
    if is_inf(rs1_bits) or is_inf(rs2_bits):
        prod_sign = ((rs1_bits >> 31) ^ (rs2_bits >> 31)) & 1
        negated_prod_sign = 1 - prod_sign  # Negated product sign
        c_negated_sign = 1 - ((rs3_bits >> 31) & 1)  # Negated rs3 sign
        if is_inf(rs3_bits) and c_negated_sign != negated_prod_sign:
            return FP_CANONICAL_NAN
    # FNMADD = FMA(-a, b, -c) = -(a*b) - c
    result_bits = _fma_float32(
        _negate_float32(rs1_bits), rs2_bits, _negate_float32(rs3_bits)
    )
    return canonicalize_nan(result_bits)


def fnmsub_s(rs1_bits: int, rs2_bits: int, rs3_bits: int) -> int:
    """FNMSUB.S: rd = -(rs1 * rs2) + rs3."""
    if is_nan(rs1_bits) or is_nan(rs2_bits) or is_nan(rs3_bits):
        return FP_CANONICAL_NAN
    if (is_zero(rs1_bits) and is_inf(rs2_bits)) or (
        is_inf(rs1_bits) and is_zero(rs2_bits)
    ):
        return FP_CANONICAL_NAN
    # Handle -inf + inf = NaN case
    if is_inf(rs1_bits) or is_inf(rs2_bits):
        prod_sign = ((rs1_bits >> 31) ^ (rs2_bits >> 31)) & 1
        negated_prod_sign = 1 - prod_sign  # Negated product sign
        if is_inf(rs3_bits) and ((rs3_bits >> 31) & 1) != negated_prod_sign:
            return FP_CANONICAL_NAN
    # FNMSUB = FMA(-a, b, c) = -(a*b) + c
    result_bits = _fma_float32(_negate_float32(rs1_bits), rs2_bits, rs3_bits)
    return canonicalize_nan(result_bits)


# ============================================================================
# Sign manipulation operations
# ============================================================================


def fsgnj_s(rs1_bits: int, rs2_bits: int) -> int:
    """FSGNJ.S: rd = |rs1| with sign of rs2."""
    magnitude = rs1_bits & ~FP_SIGN_MASK
    sign = rs2_bits & FP_SIGN_MASK
    return magnitude | sign


def fsgnjn_s(rs1_bits: int, rs2_bits: int) -> int:
    """FSGNJN.S: rd = |rs1| with negated sign of rs2."""
    magnitude = rs1_bits & ~FP_SIGN_MASK
    sign = (~rs2_bits) & FP_SIGN_MASK
    return magnitude | sign


def fsgnjx_s(rs1_bits: int, rs2_bits: int) -> int:
    """FSGNJX.S: rd = rs1 with sign XORed with rs2's sign."""
    return rs1_bits ^ (rs2_bits & FP_SIGN_MASK)


# ============================================================================
# Min/Max operations
# ============================================================================


def fmin_s(rs1_bits: int, rs2_bits: int) -> int:
    """FMIN.S: rd = min(rs1, rs2) with IEEE 754-2019 semantics."""
    # If either is signaling NaN, return canonical NaN
    # If one is NaN and other is not, return the non-NaN
    rs1_nan = is_nan(rs1_bits)
    rs2_nan = is_nan(rs2_bits)
    if rs1_nan and rs2_nan:
        return FP_CANONICAL_NAN
    if rs1_nan:
        return rs2_bits
    if rs2_nan:
        return rs1_bits
    # Handle -0 vs +0: -0 is less than +0
    if is_zero(rs1_bits) and is_zero(rs2_bits):
        return rs1_bits if is_negative(rs1_bits) else rs2_bits
    f1 = bits_to_float(rs1_bits)
    f2 = bits_to_float(rs2_bits)
    if f1 <= f2:
        return rs1_bits
    return rs2_bits


def fmax_s(rs1_bits: int, rs2_bits: int) -> int:
    """FMAX.S: rd = max(rs1, rs2) with IEEE 754-2019 semantics."""
    rs1_nan = is_nan(rs1_bits)
    rs2_nan = is_nan(rs2_bits)
    if rs1_nan and rs2_nan:
        return FP_CANONICAL_NAN
    if rs1_nan:
        return rs2_bits
    if rs2_nan:
        return rs1_bits
    # Handle -0 vs +0: +0 is greater than -0
    if is_zero(rs1_bits) and is_zero(rs2_bits):
        return rs1_bits if not is_negative(rs1_bits) else rs2_bits
    f1 = bits_to_float(rs1_bits)
    f2 = bits_to_float(rs2_bits)
    if f1 >= f2:
        return rs1_bits
    return rs2_bits


# ============================================================================
# Comparison operations (result goes to integer register)
# ============================================================================


def feq_s(rs1_bits: int, rs2_bits: int) -> int:
    """FEQ.S: rd = (rs1 == rs2) ? 1 : 0. Returns 0 if either is NaN."""
    if is_nan(rs1_bits) or is_nan(rs2_bits):
        return 0
    # +0 and -0 are equal
    if is_zero(rs1_bits) and is_zero(rs2_bits):
        return 1
    return 1 if rs1_bits == rs2_bits else 0


def flt_s(rs1_bits: int, rs2_bits: int) -> int:
    """FLT.S: rd = (rs1 < rs2) ? 1 : 0. Returns 0 if either is NaN."""
    if is_nan(rs1_bits) or is_nan(rs2_bits):
        return 0
    f1 = bits_to_float(rs1_bits)
    f2 = bits_to_float(rs2_bits)
    return 1 if f1 < f2 else 0


def fle_s(rs1_bits: int, rs2_bits: int) -> int:
    """FLE.S: rd = (rs1 <= rs2) ? 1 : 0. Returns 0 if either is NaN."""
    if is_nan(rs1_bits) or is_nan(rs2_bits):
        return 0
    f1 = bits_to_float(rs1_bits)
    f2 = bits_to_float(rs2_bits)
    return 1 if f1 <= f2 else 0


# ============================================================================
# Conversion operations
# ============================================================================


def fcvt_w_s(rs1_bits: int, _unused: int = 0) -> int:
    """FCVT.W.S: Convert float to signed 32-bit integer."""
    if is_nan(rs1_bits):
        return 0x7FFFFFFF  # Return max positive for NaN
    if is_inf(rs1_bits):
        return 0x7FFFFFFF if not is_negative(rs1_bits) else 0x80000000
    f = bits_to_float(rs1_bits)
    # Handle infinities and overflow
    if f >= 2147483648.0:  # >= 2^31
        return 0x7FFFFFFF
    if f < -2147483648.0:  # < -2^31
        return 0x80000000
    # Round to nearest even (RNE)
    result = _round_to_nearest_even(f)
    if result > 2147483647:
        return 0x7FFFFFFF
    if result < -2147483648:
        return 0x80000000
    return result & MASK32


def fcvt_wu_s(rs1_bits: int, _unused: int = 0) -> int:
    """FCVT.WU.S: Convert float to unsigned 32-bit integer."""
    if is_nan(rs1_bits):
        return 0xFFFFFFFF  # Return max unsigned for NaN
    if is_inf(rs1_bits):
        return 0xFFFFFFFF if not is_negative(rs1_bits) else 0
    f = bits_to_float(rs1_bits)
    # Handle overflow
    if f >= 4294967296.0:  # >= 2^32
        return 0xFFFFFFFF
    # Round to nearest even (RNE)
    result = _round_to_nearest_even(f)
    if result < 0:
        return 0
    if result > 0xFFFFFFFF:
        return 0xFFFFFFFF
    return result & MASK32


def fcvt_s_w(rs1_int: int, _unused: int = 0) -> int:
    """FCVT.S.W: Convert signed 32-bit integer to float."""
    # Treat as signed
    if rs1_int & 0x80000000:
        signed_val = rs1_int - 0x100000000
    else:
        signed_val = rs1_int
    f = float(signed_val)
    return float_to_bits(f)


def fcvt_s_wu(rs1_int: int, _unused: int = 0) -> int:
    """FCVT.S.WU: Convert unsigned 32-bit integer to float."""
    f = float(rs1_int & MASK32)
    return float_to_bits(f)


# ============================================================================
# Move operations
# ============================================================================


def fmv_x_w(rs1_bits: int, _unused: int = 0) -> int:
    """FMV.X.W: Move float bits to integer register (no conversion)."""
    return rs1_bits & MASK32


def fmv_w_x(rs1_int: int, _unused: int = 0) -> int:
    """FMV.W.X: Move integer bits to float register (no conversion)."""
    return rs1_int & MASK32


# ============================================================================
# Classification
# ============================================================================


def fclass_s(rs1_bits: int, _unused: int = 0) -> int:
    """FCLASS.S: Classify floating-point value.

    Returns a 10-bit mask indicating the class:
        bit 0: rs1 is -inf
        bit 1: rs1 is negative normal
        bit 2: rs1 is negative subnormal
        bit 3: rs1 is -0
        bit 4: rs1 is +0
        bit 5: rs1 is positive subnormal
        bit 6: rs1 is positive normal
        bit 7: rs1 is +inf
        bit 8: rs1 is signaling NaN
        bit 9: rs1 is quiet NaN
    """
    sign = is_negative(rs1_bits)
    exp = (rs1_bits & FP_EXP_MASK) >> 23
    mant = rs1_bits & FP_MANT_MASK

    if exp == 0xFF:
        if mant == 0:
            # Infinity
            return 1 if sign else 0x80  # bit 0 or bit 7
        else:
            # NaN - check if signaling (bit 22 = 0) or quiet (bit 22 = 1)
            if mant & 0x00400000:
                return 0x200  # bit 9: quiet NaN
            else:
                return 0x100  # bit 8: signaling NaN
    elif exp == 0:
        if mant == 0:
            # Zero
            return 8 if sign else 0x10  # bit 3 or bit 4
        else:
            # Subnormal
            return 4 if sign else 0x20  # bit 2 or bit 5
    else:
        # Normal
        return 2 if sign else 0x40  # bit 1 or bit 6


# ============================================================================
# D extension (double-precision floating-point)
# ============================================================================


def fadd_d(rs1_bits: int, rs2_bits: int) -> int:
    """FADD.D: rd = rs1 + rs2 (double-precision add)."""
    if is_nan_d(rs1_bits) or is_nan_d(rs2_bits):
        return DP_CANONICAL_NAN
    d1 = bits_to_double(rs1_bits)
    d2 = bits_to_double(rs2_bits)
    return double_to_bits(d1 + d2)


def fsub_d(rs1_bits: int, rs2_bits: int) -> int:
    """FSUB.D: rd = rs1 - rs2 (double-precision subtract)."""
    if is_nan_d(rs1_bits) or is_nan_d(rs2_bits):
        return DP_CANONICAL_NAN
    d1 = bits_to_double(rs1_bits)
    d2 = bits_to_double(rs2_bits)
    return double_to_bits(d1 - d2)


def fmul_d(rs1_bits: int, rs2_bits: int) -> int:
    """FMUL.D: rd = rs1 * rs2 (double-precision multiply)."""
    if is_nan_d(rs1_bits) or is_nan_d(rs2_bits):
        return DP_CANONICAL_NAN
    d1 = bits_to_double(rs1_bits)
    d2 = bits_to_double(rs2_bits)
    return double_to_bits(d1 * d2)


def fdiv_d(rs1_bits: int, rs2_bits: int) -> int:
    """FDIV.D: rd = rs1 / rs2 (double-precision divide)."""
    if is_nan_d(rs1_bits) or is_nan_d(rs2_bits):
        return DP_CANONICAL_NAN
    if is_inf_d(rs1_bits) and is_inf_d(rs2_bits):
        return DP_CANONICAL_NAN
    if is_zero_d(rs2_bits):
        if is_zero_d(rs1_bits):
            return DP_CANONICAL_NAN
        sign = (rs1_bits ^ rs2_bits) & DP_SIGN_MASK
        return DP_POS_INF | sign
    if is_inf_d(rs1_bits) and not is_inf_d(rs2_bits):
        sign = (rs1_bits ^ rs2_bits) & DP_SIGN_MASK
        return DP_POS_INF | sign
    if is_inf_d(rs2_bits) and not is_inf_d(rs1_bits):
        sign = (rs1_bits ^ rs2_bits) & DP_SIGN_MASK
        return DP_POS_ZERO | sign
    d1 = bits_to_double(rs1_bits)
    d2 = bits_to_double(rs2_bits)
    return double_to_bits(d1 / d2)


def fsqrt_d(rs1_bits: int, _unused: int = 0) -> int:
    """FSQRT.D: rd = sqrt(rs1) (double-precision)."""
    if is_nan_d(rs1_bits):
        return DP_CANONICAL_NAN
    if is_negative_d(rs1_bits) and not is_zero_d(rs1_bits):
        return DP_CANONICAL_NAN
    if is_inf_d(rs1_bits):
        return DP_NEG_INF if is_negative_d(rs1_bits) else DP_POS_INF
    d1 = bits_to_double(rs1_bits)
    try:
        return double_to_bits(math.sqrt(d1))
    except ValueError:
        return DP_CANONICAL_NAN


def fmadd_d(rs1_bits: int, rs2_bits: int, rs3_bits: int) -> int:
    """FMADD.D: rd = (rs1 * rs2) + rs3 (double-precision FMA)."""
    if is_nan_d(rs1_bits) or is_nan_d(rs2_bits) or is_nan_d(rs3_bits):
        return DP_CANONICAL_NAN
    if (is_inf_d(rs1_bits) and is_zero_d(rs2_bits)) or (
        is_zero_d(rs1_bits) and is_inf_d(rs2_bits)
    ):
        return DP_CANONICAL_NAN
    prod_inf = is_inf_d(rs1_bits) or is_inf_d(rs2_bits)
    if prod_inf and is_inf_d(rs3_bits):
        prod_sign = (rs1_bits ^ rs2_bits) & DP_SIGN_MASK
        if prod_sign != (rs3_bits & DP_SIGN_MASK):
            return DP_CANONICAL_NAN
        return DP_POS_INF | prod_sign
    if prod_inf and not is_inf_d(rs3_bits):
        prod_sign = (rs1_bits ^ rs2_bits) & DP_SIGN_MASK
        return DP_POS_INF | prod_sign
    if is_inf_d(rs3_bits) and not prod_inf:
        return DP_POS_INF | (rs3_bits & DP_SIGN_MASK)
    # Deterministic fused implementation (avoids libm differences)
    return _fma_float64(rs1_bits, rs2_bits, rs3_bits)


def fmsub_d(rs1_bits: int, rs2_bits: int, rs3_bits: int) -> int:
    """FMSUB.D: rd = (rs1 * rs2) - rs3."""
    return fmadd_d(rs1_bits, rs2_bits, rs3_bits ^ DP_SIGN_MASK)


def fnmadd_d(rs1_bits: int, rs2_bits: int, rs3_bits: int) -> int:
    """FNMADD.D: rd = -(rs1 * rs2) - rs3."""
    return fmadd_d(rs1_bits ^ DP_SIGN_MASK, rs2_bits, rs3_bits ^ DP_SIGN_MASK)


def fnmsub_d(rs1_bits: int, rs2_bits: int, rs3_bits: int) -> int:
    """FNMSUB.D: rd = -(rs1 * rs2) + rs3."""
    return fmadd_d(rs1_bits ^ DP_SIGN_MASK, rs2_bits, rs3_bits)


def fsgnj_d(rs1_bits: int, rs2_bits: int) -> int:
    """FSGNJ.D: rd = |rs1| with sign of rs2."""
    magnitude = rs1_bits & ~DP_SIGN_MASK
    sign = rs2_bits & DP_SIGN_MASK
    return magnitude | sign


def fsgnjn_d(rs1_bits: int, rs2_bits: int) -> int:
    """FSGNJN.D: rd = |rs1| with negated sign of rs2."""
    magnitude = rs1_bits & ~DP_SIGN_MASK
    sign = (~rs2_bits) & DP_SIGN_MASK
    return magnitude | sign


def fsgnjx_d(rs1_bits: int, rs2_bits: int) -> int:
    """FSGNJX.D: rd = rs1 with sign XORed with rs2's sign."""
    return rs1_bits ^ (rs2_bits & DP_SIGN_MASK)


def fmin_d(rs1_bits: int, rs2_bits: int) -> int:
    """FMIN.D: Minimum of two doubles with NaN handling."""
    if is_nan_d(rs1_bits) and is_nan_d(rs2_bits):
        return DP_CANONICAL_NAN
    if is_nan_d(rs1_bits):
        return rs2_bits
    if is_nan_d(rs2_bits):
        return rs1_bits
    if is_zero_d(rs1_bits) and is_zero_d(rs2_bits):
        return DP_NEG_ZERO if (rs1_bits | rs2_bits) & DP_SIGN_MASK else DP_POS_ZERO
    d1 = bits_to_double(rs1_bits)
    d2 = bits_to_double(rs2_bits)
    if d1 < d2:
        return rs1_bits
    if d2 < d1:
        return rs2_bits
    return rs1_bits


def fmax_d(rs1_bits: int, rs2_bits: int) -> int:
    """FMAX.D: Maximum of two doubles with NaN handling."""
    if is_nan_d(rs1_bits) and is_nan_d(rs2_bits):
        return DP_CANONICAL_NAN
    if is_nan_d(rs1_bits):
        return rs2_bits
    if is_nan_d(rs2_bits):
        return rs1_bits
    if is_zero_d(rs1_bits) and is_zero_d(rs2_bits):
        return rs1_bits if not is_negative_d(rs1_bits) else rs2_bits
    d1 = bits_to_double(rs1_bits)
    d2 = bits_to_double(rs2_bits)
    if d1 > d2:
        return rs1_bits
    if d2 > d1:
        return rs2_bits
    return rs1_bits


def feq_d(rs1_bits: int, rs2_bits: int) -> int:
    """FEQ.D: rd = (rs1 == rs2) ? 1 : 0. Returns 0 if either is NaN."""
    if is_nan_d(rs1_bits) or is_nan_d(rs2_bits):
        return 0
    d1 = bits_to_double(rs1_bits)
    d2 = bits_to_double(rs2_bits)
    return 1 if d1 == d2 else 0


def flt_d(rs1_bits: int, rs2_bits: int) -> int:
    """FLT.D: rd = (rs1 < rs2) ? 1 : 0. Returns 0 if either is NaN."""
    if is_nan_d(rs1_bits) or is_nan_d(rs2_bits):
        return 0
    d1 = bits_to_double(rs1_bits)
    d2 = bits_to_double(rs2_bits)
    return 1 if d1 < d2 else 0


def fle_d(rs1_bits: int, rs2_bits: int) -> int:
    """FLE.D: rd = (rs1 <= rs2) ? 1 : 0. Returns 0 if either is NaN."""
    if is_nan_d(rs1_bits) or is_nan_d(rs2_bits):
        return 0
    d1 = bits_to_double(rs1_bits)
    d2 = bits_to_double(rs2_bits)
    return 1 if d1 <= d2 else 0


def fcvt_w_d(rs1_bits: int, _unused: int = 0) -> int:
    """FCVT.W.D: Convert double to signed 32-bit integer."""
    if is_nan_d(rs1_bits):
        return 0x7FFFFFFF
    if is_inf_d(rs1_bits):
        return 0x7FFFFFFF if not is_negative_d(rs1_bits) else 0x80000000
    d = bits_to_double(rs1_bits)
    if d >= 2147483648.0:
        return 0x7FFFFFFF
    if d < -2147483648.0:
        return 0x80000000
    result = _round_to_nearest_even(d)
    if result > 2147483647:
        return 0x7FFFFFFF
    if result < -2147483648:
        return 0x80000000
    return result & MASK32


def fcvt_wu_d(rs1_bits: int, _unused: int = 0) -> int:
    """FCVT.WU.D: Convert double to unsigned 32-bit integer."""
    if is_nan_d(rs1_bits):
        return 0xFFFFFFFF
    if is_inf_d(rs1_bits):
        return 0xFFFFFFFF if not is_negative_d(rs1_bits) else 0
    d = bits_to_double(rs1_bits)
    if d >= 4294967296.0:
        return 0xFFFFFFFF
    result = _round_to_nearest_even(d)
    if result < 0:
        return 0
    if result > 0xFFFFFFFF:
        return 0xFFFFFFFF
    return result & MASK32


def fcvt_d_w(rs1_int: int, _unused: int = 0) -> int:
    """FCVT.D.W: Convert signed 32-bit integer to double."""
    if rs1_int & 0x80000000:
        signed_val = rs1_int - 0x100000000
    else:
        signed_val = rs1_int
    d = float(signed_val)
    return double_to_bits(d)


def fcvt_d_wu(rs1_int: int, _unused: int = 0) -> int:
    """FCVT.D.WU: Convert unsigned 32-bit integer to double."""
    d = float(rs1_int & MASK32)
    return double_to_bits(d)


def fcvt_s_d(rs1_bits: int, _unused: int = 0) -> int:
    """FCVT.S.D: Convert double to single."""
    if is_nan_d(rs1_bits):
        return FP_CANONICAL_NAN
    d = bits_to_double(rs1_bits)
    return float_to_bits(float(d))


def fcvt_d_s(rs1_bits: int, _unused: int = 0) -> int:
    """FCVT.D.S: Convert single to double."""
    f = bits_to_float(rs1_bits)
    return double_to_bits(float(f))


def fclass_d(rs1_bits: int, _unused: int = 0) -> int:
    """FCLASS.D: Classify double-precision value."""
    sign = is_negative_d(rs1_bits)
    exp = (rs1_bits & DP_EXP_MASK) >> 52
    mant = rs1_bits & DP_MANT_MASK

    if exp == 0x7FF:
        if mant == 0:
            return 1 if sign else 0x80
        if mant & (1 << 51):
            return 0x200
        return 0x100
    if exp == 0:
        if mant == 0:
            return 8 if sign else 0x10
        return 4 if sign else 0x20
    return 2 if sign else 0x40


# ============================================================================
# FLW/FSW - handled by memory model, not FPU
# These functions are for symmetry in the op_tables
# ============================================================================


def flw(memory_model: MemoryModel, address: int) -> int:
    """FLW: Load word from memory to FP register (uses same memory as LW)."""
    # Same as integer LW - load 32 bits from memory
    from models.alu_model import lw

    return lw(memory_model, address)


def fld(memory_model: MemoryModel, address: int) -> int:
    """FLD: Load doubleword from memory to FP register."""
    from models.alu_model import ld

    return ld(memory_model, address)
