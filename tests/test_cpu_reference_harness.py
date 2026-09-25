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

"""Fast checks of the CPU reference harness: generator, encoders, and models."""

import importlib
import sys
from pathlib import Path

import pytest

VERIF_DIR = Path(__file__).resolve().parents[1] / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))

instruction_encode = importlib.import_module("encoders.instruction_encode")
op_tables = importlib.import_module("encoders.op_tables")
instruction_generator = importlib.import_module("cocotb_tests.instruction_generator")

GENERATOR = instruction_generator.InstructionGenerator


def test_random_csr_pool_holds_only_the_read_forms() -> None:
    """The pool leaves out csrrw and csrrwi, whose write traps on read-only INSTRET."""
    pool = GENERATOR.get_all_operations()

    assert sorted(op for op in pool if op in op_tables.CSRS) == [
        "csrrc",
        "csrrci",
        "csrrs",
        "csrrsi",
    ]


@pytest.mark.parametrize("operation", ("csrrs", "csrrc", "csrrsi", "csrrci"))
def test_random_csr_instructions_read_instret_without_writing(
    monkeypatch: pytest.MonkeyPatch, operation: str
) -> None:
    """Each random CSR instruction reads INSTRET with rs1=x0 or zimm=0."""
    monkeypatch.setattr(
        GENERATOR, "get_all_operations", staticmethod(lambda: [operation])
    )
    register_file = [0] + [0x1000 + 4 * reg for reg in range(1, 32)]

    params = GENERATOR.generate_random_instruction(register_file)

    assert params.csr_address == instruction_encode.CSRAddress.INSTRET
    assert params.source_register_1 == 0
    assert params.immediate == 0
