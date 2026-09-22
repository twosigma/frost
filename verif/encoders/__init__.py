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

"""RISC-V instruction encoders and mnemonic-to-evaluator tables.

``instruction_encode`` handles 32-bit formats; ``compressed_encode`` handles
16-bit formats. ``op_tables`` defines the subset used by the Python generator.
"""

from encoders.op_tables import (
    R_ALU,
    I_ALU,
    LOADS,
    STORES,
    BRANCHES,
    JUMPS,
    CSRS,
)

__all__ = [
    "R_ALU",
    "I_ALU",
    "LOADS",
    "STORES",
    "BRANCHES",
    "JUMPS",
    "CSRS",
]
