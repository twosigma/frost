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
    Sign extension at an arbitrary bit width, and signed/unsigned casts at 32
    bits and at the active XLEN.

memory_utils
    Address alignment checks, byte strobes and data replication for stores on
    the 64-bit data-tier beat, and address/immediate constraints for random
    stimulus.

instruction_logger
    Formatted execution lines carrying PC flow, register writeback, and memory
    address, plus pipeline events such as flushes and the end-of-run
    instruction coverage summary.

validation
    ValidationError plus assertions that attach the failing values as a context
    dict, including the RISC-V bounds checks in HardwareAssertions.

Only the four names in __all__ are re-exported here. Import anything else from
its own module::

    from utils.memory_utils import calculate_byte_mask_for_store
"""

from utils.riscv_utils import sign_extend, to_signed32, to_unsigned32
from utils.validation import HardwareAssertions

# InstructionLogger is not re-exported here: it imports encoders.op_tables, which
# reaches back into utils.riscv_utils via models.alu_model, so pulling it in during
# package init would close a cycle. Import it from its own module instead:
# from utils.instruction_logger import InstructionLogger

__all__ = [
    "sign_extend",
    "to_signed32",
    "to_unsigned32",
    "HardwareAssertions",
]
