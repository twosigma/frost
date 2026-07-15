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

"""Test cases and infrastructure for RISC-V CPU verification.

This package contains all CoCoTB test cases for the Frost RISC-V CPU.

Test Modules
------------

Random Regression Tests:
    test_cpu
        Main random instruction regression test (16,000+ instructions).
        Tests all instruction types with coverage tracking.

Directed Tests:
    test_directed_atomics
        LR.W/SC.W atomic memory operation tests

    test_directed_traps
        ECALL, EBREAK, MRET, and interrupt handling tests

    test_compressed
        C extension compressed (16-bit) instruction tests

Integration Tests:
    test_real_program
        Full system tests with compiled programs (Hello World, CoreMark)

Infrastructure:
    test_common
        Shared utilities (TestConfig, handle_branch_flush, execute_nop)

    test_state
        TestState class for tracking CPU state across pipeline stages

    test_helpers
        DUTInterface and TestStatistics helper classes

    instruction_executor
        InstructionExecutor class for simplified directed test writing

    cpu_model
        Software reference model for instruction execution

    instruction_generator
        Random instruction generation with constraints

Running Tests
-------------
Run registered tests from the repository root through the frost wrapper,
naming a target from ``TEST_REGISTRY`` in ``tests/test_run_cocotb.py``::

    ./scripts/frost.py cocotb directed_traps
    ./scripts/frost.py cocotb hello_world
    ./scripts/frost.py cocotb --list-tests
"""

# Re-export commonly used classes for convenience
from cocotb_tests.test_common import TestConfig
from cocotb_tests.test_state import TestState
from cocotb_tests.test_helpers import DUTInterface, TestStatistics
from cocotb_tests.instruction_executor import InstructionExecutor

__all__ = [
    "TestConfig",
    "TestState",
    "DUTInterface",
    "TestStatistics",
    "InstructionExecutor",
]
