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

Package Structure
-----------------

Subpackages:
    encoders
        RISC-V instruction encoding utilities for all supported extensions
        (RV64IMAFDCB + Zicsr, Zicntr, Zba, Zbb, Zbs, Zbkb, Zicond)

    models
        Software reference models for ALU operations, memory, and branch logic

    monitors
        Runtime verification monitors for register file, PC, and memory

    cocotb_tests
        Test cases and infrastructure for random and directed testing

    utils
        Utility functions for data conversion, logging, and validation

Modules:
    config
        Central configuration constants (bit masks, pipeline parameters, etc.)

    verification_types
        Type aliases for type safety (Address, RegisterIndex, etc.)

    exceptions
        Custom exception hierarchy for verification failures

Run a target from ``TEST_REGISTRY`` in ``tests/test_run_cocotb.py`` through
the repository wrapper::

    ./scripts/frost.py cocotb hello_world
    ./scripts/frost.py cocotb directed_traps
    ./scripts/frost.py cocotb --list-tests

See ``verif/README.md`` for details.
"""

# Re-export commonly used types for convenience
from verification_types import Address, RegisterIndex, Instruction
from config import MASK32, PIPELINE_DEPTH

__all__ = [
    "Address",
    "RegisterIndex",
    "Instruction",
    "MASK32",
    "PIPELINE_DEPTH",
]
