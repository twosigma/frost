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
import sys
from pathlib import Path
from typing import Any

import pytest

VERIF_DIR = Path(__file__).resolve().parents[1] / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))

alu_model = importlib.import_module("models.alu_model")
packed_structs = importlib.import_module("utils.packed_structs")
cpu_structs = importlib.import_module("cocotb_tests.cpu_structs")
compressed_encode = importlib.import_module("encoders.compressed_encode")
lq_model = importlib.import_module("cocotb_tests.tomasulo.load_queue.lq_model")
rat_interface = importlib.import_module(
    "cocotb_tests.tomasulo.register_alias_table.rat_interface"
)
tomasulo_interface = importlib.import_module(
    "cocotb_tests.tomasulo.tomasulo_wrapper.tomasulo_interface"
)
rob_interface = importlib.import_module(
    "cocotb_tests.tomasulo.reorder_buffer.reorder_buffer_interface"
)
config = importlib.import_module("config")


def test_pack_struct_keeps_declaration_order_and_wide_values() -> None:
    """The first declared field is the MSB, including on wide RV64 packets."""
    fields = [("op", 3), ("valid", 1), ("value", 64), ("tail", 4)]
    values = {"op": 5, "valid": True, "value": 0xFEDC_BA98_7654_3210, "tail": 10}

    assert packed_structs.pack_struct(fields, values) == 0xB_FEDC_BA98_7654_3210_A
    assert packed_structs.pack_struct(fields, {"tail": 5, "unused": 123}) == 5


def test_pack_struct_masks_signed_and_oversized_fields() -> None:
    """Each field truncates independently; one-bit integers use their low bit."""
    fields = [("signed", 4), ("flag", 1), ("byte", 8)]

    assert (
        packed_structs.pack_struct(fields, {"signed": -2, "flag": 2, "byte": 0x1FF})
        == 0b1110_0_11111111
    )
    assert packed_structs.pack_struct(fields, {"signed": 16, "flag": -1}) == 0x100


def test_unpack_struct_keeps_bool_types_and_ignores_high_bits() -> None:
    """Unpacking preserves every value bit and returns only one-bit fields as bool."""
    fields = [("op", 3), ("valid", 1), ("value", 64), ("tail", 4)]
    unpacked = packed_structs.unpack_struct(fields, 0xFB_FEDC_BA98_7654_3210_A)

    assert unpacked == {
        "op": 5,
        "valid": True,
        "value": 0xFEDC_BA98_7654_3210,
        "tail": 10,
    }
    assert unpacked["valid"] is True
    assert type(unpacked["op"]) is int
    assert packed_structs.unpack_struct(fields, 0)["valid"] is False


def test_empty_struct_has_no_bits() -> None:
    """Empty schemas neither consume values nor expose bits from the input."""
    assert packed_structs.pack_struct([], {"unused": 1}) == 0
    assert packed_structs.unpack_struct([], -1) == {}


def test_rob_allocation_schema_matches_manual_driver() -> None:
    """Check every allocation field against the independently written ROB packer."""
    assert sum(width for _, width in cpu_structs.ROB_ALLOC_REQ_FIELDS) == (
        rob_interface.ALLOC_REQ_WIDTH
    )
    for name, default in vars(rob_interface.AllocationRequest()).items():
        for pattern in (1, -1, 0x12345_FEDC_BA98_7654_3210):
            request = rob_interface.AllocationRequest()
            setattr(
                request, name, bool(pattern) if isinstance(default, bool) else pattern
            )
            expected = packed_structs.pack_struct(
                cpu_structs.ROB_ALLOC_REQ_FIELDS,
                {"alloc_valid": True, **vars(request)},
            )
            assert rob_interface.pack_alloc_request(request) == expected, name


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


@pytest.mark.parametrize(("rd", "nzimm"), ((0, 1), (1, 0)))
def test_c_addi_encoder_rejects_hint_encodings(rd: int, nzimm: int) -> None:
    """C.ADDI excludes the x0 and zero-immediate HINT encodings."""
    with pytest.raises(AssertionError):
        compressed_encode.enc_c_addi(rd, nzimm)


def test_c_nop_has_a_dedicated_encoder() -> None:
    """C.NOP (C.ADDI x0, 0) has its own encoder."""
    assert compressed_encode.enc_c_nop() == 0x0001


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


class _VectorValue:
    """Resolvable stand-in for a cocotb vector value."""

    is_resolvable = True

    def __init__(self, value: int) -> None:
        self._value = value

    def __int__(self) -> int:
        return self._value


class _VectorHandle:
    """Stand-in for a VPI handle of a packed struct: a width and a value."""

    def __init__(self, width: int, value: int) -> None:
        self._width = width
        self.value = _VectorValue(value)

    def __len__(self) -> int:
        return self._width


def test_packed_struct_reads_fields_through_the_whole_vector() -> None:
    """Fields come out of the packed value at their cpu_structs positions."""
    real_program = importlib.import_module("cocotb_tests.test_real_program")
    layout = cpu_structs.ID_TO_EX_FIELDS
    width = sum(field_width for _, field_width in layout)
    packed = packed_structs.pack_struct(
        layout,
        {
            "program_counter": 0x8000_0000_0000_0B8C,
            "instruction": 0x00A5_8593,
            "is_not_nop": 1,
        },
    )
    struct = real_program._PackedStruct(_VectorHandle(width, packed), layout, "slot2")

    value = struct.read()
    assert value == packed
    assert struct.field(value, "program_counter") == 0x8000_0000_0000_0B8C
    assert struct.field(value, "instruction") == 0x00A5_8593
    assert struct.field(value, "is_not_nop") == 1
    assert struct.field(value, "is_compressed") == 0


def test_packed_struct_rejects_a_layout_of_another_width() -> None:
    """A layout that no longer matches the RTL struct fails at setup."""
    real_program = importlib.import_module("cocotb_tests.test_real_program")
    layout = cpu_structs.COMMIT_FIELDS
    width = sum(field_width for _, field_width in layout)

    with pytest.raises(AssertionError, match="bits wide"):
        real_program._PackedStruct(_VectorHandle(width + 1, 0), layout, "commit")


def test_required_signals_name_every_missing_handle() -> None:
    """An opt-in check fails at setup and names the handles it could not find."""
    real_program = importlib.import_module("cocotb_tests.test_real_program")

    real_program._require_signals("CHECK", {"present": object()})
    with pytest.raises(AssertionError, match="CHECK needs .*: a, b$"):
        real_program._require_signals(
            "CHECK", {"b": None, "present": object(), "a": None}
        )
