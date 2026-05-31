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

"""Unit tests for the CPU OOO from_ex_comb synthesizer."""

from collections.abc import Mapping
from typing import Any

import cocotb
from cocotb.triggers import Timer


XLEN = 32
ROB_TAG_WIDTH = 5
CHECKPOINT_ID_WIDTH = 3
RAS_PTR_BITS = 3
MASK32 = (1 << XLEN) - 1

FROM_EX_FIELDS = [
    ("branch_taken", 1),
    ("branch_target_address", XLEN),
    ("btb_update", 1),
    ("btb_update_pc", XLEN),
    ("btb_update_target", XLEN),
    ("btb_update_taken", 1),
    ("btb_update_compressed", 1),
    ("btb_update_requires_pc_reg_handoff", 1),
    ("ras_misprediction", 1),
    ("ras_restore_tos", RAS_PTR_BITS),
    ("ras_restore_valid_count", RAS_PTR_BITS + 1),
    ("ras_pop_after_restore", 1),
    ("ras_push_after_restore", 1),
    ("ras_push_address_after_restore", XLEN),
]

MISPREDICT_COMMIT_FIELDS = [
    ("tag", ROB_TAG_WIDTH),
    ("has_checkpoint", 1),
    ("checkpoint_id", CHECKPOINT_ID_WIDTH),
    ("redirect_pc", XLEN),
    ("pc", XLEN),
    ("branch_target", XLEN),
    ("branch_taken", 1),
    ("is_branch", 1),
    ("is_call", 1),
    ("is_return", 1),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("is_compressed", 1),
]

CORRECT_BRANCH_COMMIT_FIELDS = [
    ("tag", ROB_TAG_WIDTH),
    ("checkpoint_id", CHECKPOINT_ID_WIDTH),
    ("pc", XLEN),
    ("branch_target", XLEN),
    ("branch_taken", 1),
    ("is_branch", 1),
    ("is_jal", 1),
    ("is_jalr", 1),
    ("is_compressed", 1),
]


def _pack_struct(
    fields: list[tuple[str, int]],
    values: Mapping[str, int | bool],
) -> int:
    """Pack a SystemVerilog packed struct from declaration-ordered fields."""
    packed = 0
    offset = sum(width for _, width in fields)
    for name, width in fields:
        offset -= width
        raw = int(values.get(name, 0))
        packed |= (raw & ((1 << width) - 1)) << offset
    return packed


def _unpack_struct(fields: list[tuple[str, int]], packed: int) -> dict[str, Any]:
    """Unpack a SystemVerilog packed struct into named Python values."""
    result: dict[str, Any] = {}
    offset = sum(width for _, width in fields)
    for name, width in fields:
        offset -= width
        raw = (packed >> offset) & ((1 << width) - 1)
        result[name] = bool(raw) if width == 1 else raw
    return result


def _pack_mispredict_commit(fields: Mapping[str, int | bool]) -> int:
    """Pack a mispredict_commit_capture_t value."""
    return _pack_struct(MISPREDICT_COMMIT_FIELDS, fields)


def _pack_correct_branch_commit(fields: Mapping[str, int | bool]) -> int:
    """Pack a correct_branch_commit_capture_t value."""
    return _pack_struct(CORRECT_BRANCH_COMMIT_FIELDS, fields)


def _read_from_ex(dut: Any) -> dict[str, Any]:
    """Read and unpack the synthesized from_ex_comb_t output."""
    return _unpack_struct(FROM_EX_FIELDS, int(dut.o_from_ex_comb.value))


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


def _clear_inputs(dut: Any) -> None:
    """Drive all synthesizer inputs to zero."""
    dut.i_early_mispredict_active.value = 0
    dut.i_early_mispredict_redirect_pc.value = 0
    dut.i_early_mispredict_pc.value = 0
    dut.i_early_mispredict_branch_target.value = 0
    dut.i_early_mispredict_branch_taken.value = 0
    dut.i_early_mispredict_is_compressed.value = 0
    dut.i_restored_ras_tos.value = 0
    dut.i_restored_ras_valid_count.value = 0
    dut.i_mispredict_recovery_pending.value = 0
    dut.i_mispredict_commit_q.value = 0
    dut.i_correct_branch_commit_pending.value = 0
    dut.i_correct_branch_commit_q.value = 0


async def _setup_test(dut: Any) -> None:
    """Initialize the combinational DUT inputs."""
    _clear_inputs(dut)
    await _settle()


def _drive_mispredict_commit(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive the commit-time misprediction path."""
    dut.i_mispredict_recovery_pending.value = 1
    dut.i_mispredict_commit_q.value = _pack_mispredict_commit(fields)


def _drive_correct_branch_commit(dut: Any, fields: Mapping[str, int | bool]) -> None:
    """Drive the correctly-predicted branch commit path."""
    dut.i_correct_branch_commit_pending.value = 1
    dut.i_correct_branch_commit_q.value = _pack_correct_branch_commit(fields)


def _assert_btb_update(
    output: Mapping[str, Any],
    *,
    pc: int,
    target: int,
    taken: bool,
    compressed: bool,
) -> None:
    """Assert the BTB update payload fields."""
    assert output["btb_update"]
    assert output["btb_update_pc"] == (pc & MASK32)
    assert output["btb_update_target"] == (target & MASK32)
    assert output["btb_update_taken"] is taken
    assert output["btb_update_compressed"] is compressed
    assert output["btb_update_requires_pc_reg_handoff"]


@cocotb.test()
async def test_idle_output_is_zero(dut: Any) -> None:
    """With no recovery source pending, the synthesized bus is zero."""
    await _setup_test(dut)

    output = _read_from_ex(dut)

    assert all(value == 0 or value is False for value in output.values())


@cocotb.test()
async def test_early_mispredict_has_priority_and_restores_ras(dut: Any) -> None:
    """Early recovery wins over commit paths and drives BTB/RAS restore."""
    await _setup_test(dut)

    dut.i_early_mispredict_active.value = 1
    dut.i_early_mispredict_redirect_pc.value = 0x80000100
    dut.i_early_mispredict_pc.value = 0x80000080
    dut.i_early_mispredict_branch_target.value = 0x80000200
    dut.i_early_mispredict_branch_taken.value = 0
    dut.i_early_mispredict_is_compressed.value = 1
    dut.i_restored_ras_tos.value = 3
    dut.i_restored_ras_valid_count.value = 5
    _drive_mispredict_commit(
        dut,
        {
            "redirect_pc": 0x11111111,
            "pc": 0x22222222,
            "branch_target": 0x33333333,
            "branch_taken": True,
            "is_branch": True,
        },
    )
    _drive_correct_branch_commit(
        dut,
        {
            "pc": 0x44444444,
            "branch_target": 0x55555555,
            "branch_taken": True,
            "is_branch": True,
        },
    )
    await _settle()

    output = _read_from_ex(dut)

    assert output["branch_taken"]
    assert output["branch_target_address"] == 0x80000100
    _assert_btb_update(
        output,
        pc=0x80000080,
        target=0x80000200,
        taken=False,
        compressed=True,
    )
    assert output["ras_misprediction"]
    assert output["ras_restore_tos"] == 3
    assert output["ras_restore_valid_count"] == 5
    assert not output["ras_pop_after_restore"]
    assert not output["ras_push_after_restore"]


@cocotb.test()
async def test_commit_mispredict_branch_redirects_and_updates_btb(dut: Any) -> None:
    """Commit-time branch recovery redirects fetch and trains the BTB."""
    await _setup_test(dut)

    _drive_mispredict_commit(
        dut,
        {
            "redirect_pc": 0x100,
            "pc": 0x80,
            "branch_target": 0x180,
            "branch_taken": True,
            "is_branch": True,
            "is_compressed": True,
        },
    )
    await _settle()

    output = _read_from_ex(dut)

    assert output["branch_taken"]
    assert output["branch_target_address"] == 0x100
    _assert_btb_update(output, pc=0x80, target=0x180, taken=True, compressed=True)
    assert not output["ras_misprediction"]


@cocotb.test()
async def test_commit_mispredict_jal_updates_btb(dut: Any) -> None:
    """Commit-time JAL recovery trains the BTB."""
    await _setup_test(dut)

    _drive_mispredict_commit(
        dut,
        {
            "redirect_pc": 0x400,
            "pc": 0x300,
            "branch_target": 0x500,
            "branch_taken": True,
            "is_branch": True,
            "is_jal": True,
        },
    )
    await _settle()

    output = _read_from_ex(dut)

    assert output["branch_target_address"] == 0x400
    _assert_btb_update(output, pc=0x300, target=0x500, taken=True, compressed=False)


@cocotb.test()
async def test_commit_mispredict_jalr_redirects_without_btb_update(dut: Any) -> None:
    """Commit-time JALR recovery redirects but does not train the BTB."""
    await _setup_test(dut)

    _drive_mispredict_commit(
        dut,
        {
            "redirect_pc": 0x700,
            "pc": 0x600,
            "branch_target": 0x710,
            "branch_taken": True,
            "is_branch": True,
            "is_jalr": True,
        },
    )
    await _settle()

    output = _read_from_ex(dut)

    assert output["branch_taken"]
    assert output["branch_target_address"] == 0x700
    assert not output["btb_update"]


@cocotb.test()
async def test_commit_mispredict_return_restores_and_pops_ras(dut: Any) -> None:
    """Mispredicted returns restore RAS state and request a pop."""
    await _setup_test(dut)

    dut.i_restored_ras_tos.value = 6
    dut.i_restored_ras_valid_count.value = 7
    _drive_mispredict_commit(
        dut,
        {
            "redirect_pc": 0x900,
            "has_checkpoint": True,
            "checkpoint_id": 2,
            "pc": 0x880,
            "branch_target": 0x900,
            "branch_taken": True,
            "is_branch": True,
            "is_return": True,
            "is_jalr": True,
        },
    )
    await _settle()

    output = _read_from_ex(dut)

    assert output["ras_misprediction"]
    assert output["ras_restore_tos"] == 6
    assert output["ras_restore_valid_count"] == 7
    assert output["ras_pop_after_restore"]
    assert not output["ras_push_after_restore"]


@cocotb.test()
async def test_commit_mispredict_call_restores_and_pushes_link(dut: Any) -> None:
    """Mispredicted calls restore RAS state and push the architectural link."""
    await _setup_test(dut)

    dut.i_restored_ras_tos.value = 1
    dut.i_restored_ras_valid_count.value = 2
    _drive_mispredict_commit(
        dut,
        {
            "redirect_pc": 0xA00,
            "has_checkpoint": True,
            "pc": 0xA80,
            "branch_target": 0xA00,
            "branch_taken": True,
            "is_branch": True,
            "is_call": True,
            "is_compressed": True,
        },
    )
    await _settle()

    output = _read_from_ex(dut)

    assert output["ras_misprediction"]
    assert output["ras_restore_tos"] == 1
    assert output["ras_restore_valid_count"] == 2
    assert not output["ras_pop_after_restore"]
    assert output["ras_push_after_restore"]
    assert output["ras_push_address_after_restore"] == 0xA82


@cocotb.test()
async def test_correct_branch_commit_updates_btb_without_redirect(dut: Any) -> None:
    """Correct branch commit updates the BTB without redirect or RAS restore."""
    await _setup_test(dut)

    _drive_correct_branch_commit(
        dut,
        {
            "tag": 4,
            "checkpoint_id": 1,
            "pc": 0xB00,
            "branch_target": 0xB80,
            "branch_taken": False,
            "is_branch": True,
            "is_compressed": True,
        },
    )
    await _settle()

    output = _read_from_ex(dut)

    assert not output["branch_taken"]
    assert output["branch_target_address"] == 0
    _assert_btb_update(output, pc=0xB00, target=0xB80, taken=False, compressed=True)
    assert not output["ras_misprediction"]


@cocotb.test()
async def test_correct_jal_and_jalr_commits_do_not_update_btb(dut: Any) -> None:
    """Correct JAL/JALR commits are excluded from this BTB-update path."""
    await _setup_test(dut)

    for is_jal, is_jalr in [(True, False), (False, True)]:
        _clear_inputs(dut)
        _drive_correct_branch_commit(
            dut,
            {
                "pc": 0xC00,
                "branch_target": 0xD00,
                "branch_taken": True,
                "is_branch": True,
                "is_jal": is_jal,
                "is_jalr": is_jalr,
            },
        )
        await _settle()

        output = _read_from_ex(dut)

        assert not output["branch_taken"]
        assert not output["btb_update"]
