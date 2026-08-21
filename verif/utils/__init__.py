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

"""Data conversion, logging, memory, and validation helpers.

Modules
-------
riscv_utils
    RISC-V specific type conversions:
    - Sign extension for various bit widths
    - Signed/unsigned value conversions
    - Bit manipulation helpers

memory_utils
    Memory address and alignment utilities:
    - Address alignment functions
    - Byte enable mask generation for stores
    - Memory size calculations

instruction_logger
    Structured logging for instruction execution:
    - Formatted output with PC flow, register updates, memory operations
    - Coverage summary reporting
    - Debug logging for branch flush and pipeline operations

validation
    Assertion utilities:
    - HardwareAssertions class for RISC-V-specific validations
    - Register index bounds checking
    - Immediate value range validation

Usage
-----
Import utilities as needed::

    from utils.riscv_utils import sign_extend
    from utils.memory_utils import calculate_byte_enables
    from utils.validation import HardwareAssertions

    # Sign extend a 12-bit immediate to 32 bits
    signed_imm = sign_extend(raw_imm, bit_width=12)

    # Validate a register index
    HardwareAssertions.assert_register_valid(reg_idx)
"""

from utils.riscv_utils import sign_extend, to_signed32, to_unsigned32
from utils.validation import HardwareAssertions

# Note: InstructionLogger is not imported at package level to avoid circular imports.
# Import directly when needed: from utils.instruction_logger import InstructionLogger

__all__ = [
    "sign_extend",
    "to_signed32",
    "to_unsigned32",
    "HardwareAssertions",
]
