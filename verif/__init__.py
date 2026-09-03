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

"""Cocotb verification framework for the Frost RISC-V CPU.

Subpackages:
    encoders
        Instruction encoders for the supported extensions
        (RV64IMAFDCB + Zicsr, Zicntr, Zba, Zbb, Zbs, Zbkb, Zicond)

    models
        Software reference models for ALU, FP, memory, and branch logic

    monitors
        Runtime monitors for the integer and FP register files and the PC

    cocotb_tests
        Random and directed test cases, plus the infrastructure they share

    utils
        Data conversion, logging, and validation helpers

Modules:
    config
        Shared constants (bit masks, pipeline offsets) and DUT signal paths

    verification_types
        ``NewType`` aliases such as Address and RegisterIndex

    exceptions
        Exception hierarchy for verification failures

Run a target from ``TEST_REGISTRY`` in ``tests/test_run_cocotb.py`` through
the repository wrapper::

    ./scripts/frost.py cocotb hello_world
    ./scripts/frost.py cocotb directed_traps
    ./scripts/frost.py cocotb --list-tests

See ``verif/README.md`` for details.
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
