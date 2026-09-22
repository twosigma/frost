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

"""Cocotb tests, encoders, reference models, and monitors for FROST.

Run named targets through ``scripts/frost.py cocotb``; see ``verif/README.md``.
"""

from verification_types import Address, RegisterIndex, Instruction
from config import MASK32, PIPELINE_DEPTH

__all__ = [
    "Address",
    "RegisterIndex",
    "Instruction",
    "MASK32",
    "PIPELINE_DEPTH",
]
