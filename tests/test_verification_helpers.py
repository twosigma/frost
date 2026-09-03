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

"""Fast regression tests for Python-side verification helpers."""

import importlib
import random
import sys
from pathlib import Path
from typing import Any

import pytest

VERIF_DIR = Path(__file__).resolve().parents[1] / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))

alu_model = importlib.import_module("models.alu_model")
branch_model = importlib.import_module("models.branch_model")
memory_utils = importlib.import_module("utils.memory_utils")
monitors = importlib.import_module("monitors.monitors")
compressed_encode = importlib.import_module("encoders.compressed_encode")
instruction_generator = importlib.import_module("cocotb_tests.instruction_generator")
lq_model = importlib.import_module("cocotb_tests.tomasulo.load_queue.lq_model")
rat_interface = importlib.import_module(
    "cocotb_tests.tomasulo.register_alias_table.rat_interface"
)
tomasulo_interface = importlib.import_module(
    "cocotb_tests.tomasulo.tomasulo_wrapper.tomasulo_interface"
)
config = importlib.import_module("config")


@pytest.mark.parametrize(
    ("operation", "operand_a", "operand_b", "expected"),
    (
        ("blt", 0xFFFF_FFFF_0000_0000, 0, True),
        ("bge", 0xFFFF_FFFF_0000_0000, 0, False),
        ("bltu", 0, 0x0000_0001_0000_0000, True),
        ("bgeu", 0, 0x0000_0001_0000_0000, False),
        ("beq", 1 << config.XLEN, 0, True),
        ("bne", 1 << config.XLEN, 0, False),
    ),
)
def test_branch_decisions_use_xlen(
    operation: str, operand_a: int, operand_b: int, expected: bool
) -> None:
    """Branch comparisons must neither truncate to 32 bits nor exceed XLEN."""
    assert (
        branch_model.branch_taken_decision(operation, operand_a, operand_b) is expected
    )


@pytest.mark.parametrize(
    ("operation", "old_value", "rs2_value", "expected"),
    (
        ("amoswap", 0xAAAA_AAAA_0000_0001, 0xBBBB_BBBB_8765_4321, 0x8765_4321),
        ("amoadd", 0xAAAA_AAAA_FFFF_FFFF, 0xBBBB_BBBB_0000_0001, 0),
        ("amoxor", 0xAAAA_AAAA_FFFF_0000, 0xBBBB_BBBB_00FF_00FF, 0xFF00_00FF),
        ("amoand", 0xAAAA_AAAA_FFFF_0000, 0xBBBB_BBBB_00FF_00FF, 0x00FF_0000),
        ("amoor", 0xAAAA_AAAA_FFFF_0000, 0xBBBB_BBBB_00FF_00FF, 0xFFFF_00FF),
        ("amomin", 0xAAAA_AAAA_FFFF_FFFF, 0xBBBB_BBBB_0000_0001, 0xFFFF_FFFF),
        ("amomax", 0xAAAA_AAAA_FFFF_FFFF, 0xBBBB_BBBB_0000_0001, 1),
        ("amominu", 0xAAAA_AAAA_0000_0001, 0xBBBB_BBBB_0000_0002, 1),
        ("amomaxu", 0xAAAA_AAAA_0000_0001, 0xBBBB_BBBB_0000_0002, 2),
    ),
)
def test_amo_word_evaluators_return_a_word(
    operation: str, old_value: int, rs2_value: int, expected: int
) -> None:
    """Every .W evaluator returns only the low 32-bit memory result."""
    evaluator = getattr(alu_model, operation)
    assert evaluator(old_value, rs2_value) == expected


def test_aligned_immediate_rejects_an_out_of_range_address(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A memory-size constraint must inspect the effective address itself."""
    monkeypatch.setattr(random, "choice", lambda candidates: candidates[-1])

    immediate = memory_utils.generate_aligned_immediate(
        base_value=0,
        target_alignment=4,
        immediate_min=0,
        immediate_max=16,
        memory_size_constraint=16,
    )

    assert immediate == 12


def test_constrained_immediate_does_not_alias_an_rv64_address() -> None:
    """A set upper word must not wrap into low constrained RAM."""
    with pytest.raises(ValueError, match="no immediate"):
        memory_utils.generate_aligned_immediate(
            base_value=0x1_0000_0000,
            target_alignment=4,
            immediate_min=0,
            immediate_max=0,
            memory_size_constraint=0x2000,
        )


@pytest.mark.parametrize("operation", ("lb", "lh", "lw", "sb", "amoadd.w"))
def test_integer_generator_honors_memory_size_constraint(
    monkeypatch: pytest.MonkeyPatch, operation: str
) -> None:
    """Every integer memory-operation shape stays in allocated memory."""
    monkeypatch.setattr(
        instruction_generator.InstructionGenerator,
        "get_all_operations",
        staticmethod(lambda: [operation]),
    )
    monkeypatch.setattr(instruction_generator.random, "randint", lambda _lo, hi: hi)
    register_file = [0] + [0x1_0000_0000 + 4 * reg for reg in range(1, 32)]

    params = instruction_generator.InstructionGenerator.generate_random_instruction(
        register_file, constrain_to_memory_size=0x2000
    )
    address = (
        register_file[params.source_register_1] + params.immediate
    ) & config.MASK_XLEN

    assert address < 0x2000


@pytest.mark.parametrize("operation", ("flw", "fld", "fsw", "fsd"))
def test_fp_generator_honors_memory_size_constraint(
    monkeypatch: pytest.MonkeyPatch, operation: str
) -> None:
    """Both F- and D-width memory operations stay in allocated memory."""
    monkeypatch.setattr(instruction_generator.random, "randint", lambda _lo, hi: hi)
    int_register_file = [0] + [0x1_0000_0000 + 8 * reg for reg in range(1, 32)]
    fp_register_file = [0] * 32

    params = instruction_generator.InstructionGenerator.generate_random_fp_instruction(
        int_register_file,
        fp_register_file,
        constrain_to_memory_size=0x2000,
        fp_operations=[operation],
    )
    address = (
        int_register_file[params.source_register_1] + params.immediate
    ) & config.MASK_XLEN

    assert address < 0x2000


def test_constrained_amo_base_does_not_alias_above_32_bits(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """AMO base selection applies the memory bound to the full XLEN value."""
    monkeypatch.setattr(random, "choice", lambda candidates: candidates[-1])
    register_file = [0] + [0x1_0000_0000 + 4 * reg for reg in range(1, 32)]

    selected = instruction_generator._choose_constrained_word_aligned_rs1(
        register_file, 0x2000
    )

    assert selected == 0


def test_unconstrained_address_classification_uses_all_rv64_bits() -> None:
    """A high-word address must be rejected instead of aliasing low RAM."""
    high_address = 0x1_0000_0000

    assert instruction_generator._effective_address(high_address, 0) == high_address
    assert instruction_generator._is_mmio_address(high_address)
    with pytest.raises(AssertionError, match="reserved-region memory access"):
        instruction_generator.assert_random_memory_access_in_ram("lw", high_address, 0)


def test_unconstrained_generator_recovers_from_an_upper_word_base(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The public random generator must reselect an RV64-invalid RAM base."""
    monkeypatch.setattr(
        instruction_generator.InstructionGenerator,
        "get_all_operations",
        staticmethod(lambda: ["lb"]),
    )
    monkeypatch.setattr(instruction_generator.random, "randint", lambda _lo, hi: hi)
    register_file = [0] + [0x1_0000_0000 + 4 * reg for reg in range(1, 32)]

    params = instruction_generator.InstructionGenerator.generate_random_instruction(
        register_file
    )
    address = instruction_generator._effective_address(
        register_file[params.source_register_1], params.immediate
    )

    assert params.source_register_1 == 0
    assert address < instruction_generator.MMIO_BASE_ADDR


@pytest.mark.parametrize(("rd", "nzimm"), ((0, 1), (1, 0)))
def test_c_addi_encoder_rejects_hint_encodings(rd: int, nzimm: int) -> None:
    """C.ADDI excludes the x0 and zero-immediate HINT encodings."""
    with pytest.raises(AssertionError):
        compressed_encode.enc_c_addi(rd, nzimm)


def test_c_nop_has_a_dedicated_encoder() -> None:
    """The architectural C.NOP encoding remains available explicitly."""
    assert compressed_encode.enc_c_nop() == 0x0001


def test_integer_register_monitor_compares_the_upper_word() -> None:
    """An RV64 mismatch above bit 31 must fail the register-file snapshot."""
    monitor = monitors.RegisterFileMonitor.__new__(monitors.RegisterFileMonitor)
    expected = [0] * config.NUM_REGISTERS
    actual = [0] * config.NUM_REGISTERS
    expected[1] = 0x1234_5678_89AB_CDEF
    actual[1] = 0x0000_0000_89AB_CDEF

    error = monitor.compare(actual, expected)

    assert error is not None
    assert "Register x1" in error


def test_lq_model_gives_rob_head_lr_priority_over_physical_order() -> None:
    """The model's head shortcut includes LR, matching the RTL selector."""
    model = lq_model.LQModel()
    assert model.alloc(
        rob_tag=5, is_fp=False, size=lq_model.MEM_SIZE_WORD, sign_ext=False
    )
    assert model.alloc(
        rob_tag=1,
        is_fp=False,
        size=lq_model.MEM_SIZE_WORD,
        sign_ext=False,
        is_lr=True,
    )
    model.addr_update(rob_tag=5, address=0x5000)
    model.addr_update(rob_tag=1, address=0x1000)

    request = model.issue_to_memory(
        all_older_known=True,
        sq_forward=lq_model.SQForwardResult(),
        rob_head_tag=1,
    )

    assert request == {"addr": 0x1000, "size": lq_model.MEM_SIZE_WORD}


class _Signal:
    """Minimal writable cocotb-signal stand-in."""

    def __init__(self) -> None:
        self.value = 0


class _RatLookupDut:
    """Signal subset used by the RAT source-lookup setters."""

    def __init__(self) -> None:
        self.i_int_src1_addr = _Signal()
        self.i_int_src2_addr = _Signal()
        self.i_int_src1_addr_2 = _Signal()
        self.i_int_src2_addr_2 = _Signal()
        self.i_int_regfile_data1 = _Signal()
        self.i_int_regfile_data2 = _Signal()
        self.i_int_regfile_data1_2 = _Signal()
        self.i_int_regfile_data2_2 = _Signal()


@pytest.mark.parametrize(
    "interface_type",
    (rat_interface.RATInterface, tomasulo_interface.TomasuloInterface),
)
def test_rat_interfaces_preserve_rv64_regfile_values(interface_type: Any) -> None:
    """Both direct and integration RAT drivers must retain bits 63:32."""
    dut = _RatLookupDut()
    interface = interface_type(dut)
    values = (
        0x0123_4567_89AB_CDEF,
        0xFEDC_BA98_7654_3210,
        0x1357_9BDF_2468_ACE0,
        0xF0E1_D2C3_B4A5_9687,
    )

    interface.set_int_src1(1, values[0])
    interface.set_int_src2(2, values[1])
    interface.set_int_src1_2(3, values[2])
    interface.set_int_src2_2(4, values[3])

    assert dut.i_int_regfile_data1.value == values[0]
    assert dut.i_int_regfile_data2.value == values[1]
    assert dut.i_int_regfile_data1_2.value == values[2]
    assert dut.i_int_regfile_data2_2.value == values[3]
