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

"""Assertions and validators with structured failure context.

Provided Utilities:

    ValidationError: AssertionError with a context dict
        - Stores context as attributes
        - Formats context in error message
        - Includes random seed for reproducibility

    Assertion Functions:
        - assert_equals(): Compare values with detailed mismatch info
        - assert_in_range(): Check value bounds
        - assert_aligned(): Verify memory alignment
        - assert_bit_width(): Ensure value fits in bit width

    HardwareAssertions: RISC-V-specific checks
        - assert_register_valid(): Register index in [0, 31]
        - assert_immediate_12bit(): Immediate in [-2048, 2047]
        - assert_branch_offset(): Valid branch offset (even, in range)

Example:
    >>> try:
    ...     assert_equals(0xDEAD, 0xBEEF, "Register mismatch", cycle=123, reg="x5")
    ... except ValidationError as e:
    ...     print(e.context['cycle'])  # 123
    ...     print(e.context['expected'])  # 0xBEEF
"""

from typing import Any
import cocotb


class ValidationError(AssertionError):
    """Enhanced assertion error with context."""

    def __init__(self, message: str, **context: Any) -> None:
        """Initialize with message and context."""
        self.context = context
        context_str = "\n".join(f"  {k}: {v}" for k, v in context.items())
        super().__init__(f"{message}\nContext:\n{context_str}" if context else message)


def assert_equals(
    actual: Any, expected: Any, message: str = "", **context: Any
) -> None:
    """Assert equality with enhanced error reporting."""
    if actual != expected:
        base_msg = message or f"Expected {expected}, got {actual}"
        cocotb.log.info(f"cocotb RANDOM_SEED is {cocotb.RANDOM_SEED}")
        raise ValidationError(
            base_msg,
            actual=actual,
            expected=expected,
            difference=actual - expected if isinstance(actual, int | float) else None,
            **context,
        )


def assert_in_range(
    value: int, min_val: int, max_val: int, name: str = "value"
) -> None:
    """Assert value is within range."""
    if not min_val <= value <= max_val:
        raise ValidationError(
            f"{name} out of range",
            value=value,
            min=min_val,
            max=max_val,
            out_by=min(abs(value - min_val), abs(value - max_val)),
        )


def assert_aligned(value: int, alignment: int, name: str = "value") -> None:
    """Assert value is properly aligned."""
    if value % alignment != 0:
        raise ValidationError(
            f"{name} not aligned to {alignment}-byte boundary",
            value=hex(value),
            alignment=alignment,
            misalignment=value % alignment,
        )


def assert_bit_width(value: int, bits: int, name: str = "value") -> None:
    """Assert value fits in specified bit width."""
    max_val = (1 << bits) - 1
    if value < 0 or value > max_val:
        raise ValidationError(
            f"{name} exceeds {bits}-bit width",
            value=hex(value),
            bits=bits,
            max_value=hex(max_val),
        )


class HardwareAssertions:
    """Hardware-specific assertion helpers."""

    @staticmethod
    def assert_register_valid(reg: int) -> None:
        """Assert register number is valid."""
        assert_in_range(reg, 0, 31, "register")

    @staticmethod
    def assert_immediate_12bit(imm: int) -> None:
        """Assert immediate fits in 12 bits (signed)."""
        assert_in_range(imm, -2048, 2047, "12-bit immediate")

    @staticmethod
    def assert_branch_offset(offset: int) -> None:
        """Assert branch offset is valid."""
        assert_aligned(offset, 2, "branch offset")
        assert_in_range(offset, -4096, 4094, "branch offset")
