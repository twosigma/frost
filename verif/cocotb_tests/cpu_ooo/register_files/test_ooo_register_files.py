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

"""Unit tests for the CPU OOO architectural register files."""

from collections.abc import Mapping
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


CLOCK_PERIOD_NS = 10
XLEN = 32
FLEN = 64
INSTR_OP_WIDTH = 32
BRANCH_OP_WIDTH = 3
STORE_OP_WIDTH = 2
RAS_PTR_BITS = 3
BP_DIR_IDX_BITS = 10

PD_TO_ID_FIELDS = [
    ("program_counter", XLEN),
    ("instruction", 32),
    ("link_address", XLEN),
    ("source_reg_1_early", 5),
    ("source_reg_2_early", 5),
    ("fp_source_reg_3_early", 5),
    ("illegal_instruction", 1),
    ("btb_hit", 1),
    ("btb_predicted_taken", 1),
    ("btb_predicted_target", XLEN),
    ("ras_predicted", 1),
    ("ras_predicted_target", XLEN),
    ("ras_checkpoint_tos", RAS_PTR_BITS),
    ("ras_checkpoint_valid_count", RAS_PTR_BITS + 1),
    ("bp_dir_idx", BP_DIR_IDX_BITS),
]

ID_TO_EX_FIELDS = [
    ("program_counter", XLEN),
    ("immediate_i_type", 32),
    ("immediate_s_type", 32),
    ("immediate_b_type", 32),
    ("immediate_u_type", 32),
    ("immediate_j_type", 32),
    ("source_reg_1_data", XLEN),
    ("source_reg_2_data", XLEN),
    ("source_reg_1_is_x0", 1),
    ("source_reg_2_is_x0", 1),
    ("is_load_instruction", 1),
    ("is_load_byte", 1),
    ("is_load_halfword", 1),
    ("is_load_unsigned", 1),
    ("instruction_operation", INSTR_OP_WIDTH),
    ("branch_operation", BRANCH_OP_WIDTH),
    ("store_operation", STORE_OP_WIDTH),
    ("rs_type", 3),
    ("is_int_store", 1),
    ("is_branch_or_jump", 1),
    ("is_fence", 1),
    ("is_fence_i", 1),
    ("is_csr_imm", 1),
    ("has_fp_flags", 1),
    ("is_jump_and_link", 1),
    ("is_jump_and_link_register", 1),
    ("is_multiply", 1),
    ("is_divide", 1),
    ("is_csr_instruction", 1),
    ("csr_address", 12),
    ("csr_imm", 5),
    ("is_amo_instruction", 1),
    ("is_lr", 1),
    ("is_sc", 1),
    ("is_mret", 1),
    ("is_wfi", 1),
    ("is_ecall", 1),
    ("is_ebreak", 1),
    ("is_illegal_instruction", 1),
    ("is_fp_instruction", 1),
    ("is_fp_load", 1),
    ("is_fp_store", 1),
    ("is_fp_load_double", 1),
    ("is_fp_store_double", 1),
    ("is_fp_compute", 1),
    ("is_pipelined_fp_op", 1),
    ("fp_rm", 3),
    ("is_fp_to_int", 1),
    ("is_int_to_fp", 1),
    ("fp_source_reg_1_data", FLEN),
    ("fp_source_reg_2_data", FLEN),
    ("fp_source_reg_3_data", FLEN),
    ("link_address", XLEN),
    ("branch_target_precomputed", XLEN),
    ("jal_target_precomputed", XLEN),
    ("instruction", 32),
    ("btb_hit", 1),
    ("btb_predicted_taken", 1),
    ("btb_predicted_target", XLEN),
    ("ras_predicted", 1),
    ("ras_predicted_target", XLEN),
    ("ras_checkpoint_tos", RAS_PTR_BITS),
    ("ras_checkpoint_valid_count", RAS_PTR_BITS + 1),
    ("bp_dir_idx", BP_DIR_IDX_BITS),
    ("is_ras_return", 1),
    ("is_ras_call", 1),
    ("ras_predicted_target_nonzero", 1),
    ("ras_expected_rs1", XLEN),
    ("btb_correct_non_jalr", 1),
    ("btb_expected_rs1", XLEN),
    ("has_int_dest", 1),
    ("has_fp_dest", 1),
    ("uses_int_rs1", 1),
    ("uses_int_rs2", 1),
    ("uses_fp_rs1", 1),
    ("uses_fp_rs2", 1),
    ("uses_fp_rs3", 1),
    ("is_not_nop", 1),
]

RF_TO_FWD_FIELDS = [
    ("source_reg_1_data", XLEN),
    ("source_reg_2_data", XLEN),
]

FP_RF_TO_FWD_FIELDS = [
    ("fp_source_reg_1_data", FLEN),
    ("fp_source_reg_2_data", FLEN),
    ("fp_source_reg_3_data", FLEN),
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


def _unpack_struct(
    fields: list[tuple[str, int]],
    packed: int,
) -> dict[str, int | bool]:
    """Unpack a SystemVerilog packed struct into named Python values."""
    result: dict[str, int | bool] = {}
    offset = sum(width for _, width in fields)
    for name, width in fields:
        offset -= width
        raw = (packed >> offset) & ((1 << width) - 1)
        result[name] = bool(raw) if width == 1 else raw
    return result


def _pack_pd_to_id(fields: Mapping[str, int | bool]) -> int:
    """Pack a from_pd_to_id_t value."""
    return _pack_struct(PD_TO_ID_FIELDS, fields)


def _pack_id_to_ex(fields: Mapping[str, int | bool]) -> int:
    """Pack a from_id_to_ex_t value."""
    return _pack_struct(ID_TO_EX_FIELDS, fields)


def _make_instr(
    *,
    source_reg_1: int = 0,
    source_reg_2: int = 0,
    fp_source_reg_3: int = 0,
) -> int:
    """Build the source-register fields used by ooo_register_files."""
    return (
        ((fp_source_reg_3 & 0x1F) << 27)
        | ((source_reg_2 & 0x1F) << 20)
        | ((source_reg_1 & 0x1F) << 15)
    )


def _read_int_slot1(dut: Any) -> dict[str, int | bool]:
    """Read and unpack the slot-1 integer forwarding output."""
    return _unpack_struct(RF_TO_FWD_FIELDS, int(dut.o_rf_to_fwd.value))


def _read_int_slot2(dut: Any) -> dict[str, int | bool]:
    """Read and unpack the slot-2 integer forwarding output."""
    return _unpack_struct(RF_TO_FWD_FIELDS, int(dut.o_rf_to_fwd_2.value))


def _read_fp_slot1(dut: Any) -> dict[str, int | bool]:
    """Read and unpack the slot-1 FP forwarding output."""
    return _unpack_struct(FP_RF_TO_FWD_FIELDS, int(dut.o_fp_rf_to_fwd.value))


def _read_fp_slot2(dut: Any) -> dict[str, int | bool]:
    """Read and unpack the slot-2 FP forwarding output."""
    return _unpack_struct(FP_RF_TO_FWD_FIELDS, int(dut.o_fp_rf_to_fwd_2.value))


def _drive_pd_slot(
    dut: Any,
    fields: Mapping[str, int | bool],
    *,
    slot2: bool = False,
) -> None:
    """Drive a PD-to-ID slot with register-read source fields."""
    value = _pack_pd_to_id(fields)
    if slot2:
        dut.i_from_pd_to_id_2.value = value
    else:
        dut.i_from_pd_to_id.value = value


def _drive_ex_slot(
    dut: Any,
    *,
    rs1: int = 0,
    rs2: int = 0,
    fp_rs3: int = 0,
    slot2: bool = False,
) -> None:
    """Drive an ID-to-EX slot with dispatch read source fields."""
    value = _pack_id_to_ex(
        {
            "instruction": _make_instr(
                source_reg_1=rs1,
                source_reg_2=rs2,
                fp_source_reg_3=fp_rs3,
            )
        }
    )
    if slot2:
        dut.i_from_id_to_ex_2.value = value
    else:
        dut.i_from_id_to_ex.value = value


def _clear_writes(dut: Any) -> None:
    """Clear all commit write ports."""
    dut.i_port0_int_we.value = 0
    dut.i_port0_int_addr.value = 0
    dut.i_port0_int_data.value = 0
    dut.i_port1_int_we.value = 0
    dut.i_port1_int_addr.value = 0
    dut.i_port1_int_data.value = 0
    dut.i_port0_fp_we.value = 0
    dut.i_port0_fp_addr.value = 0
    dut.i_port0_fp_data.value = 0
    dut.i_port1_fp_we.value = 0
    dut.i_port1_fp_addr.value = 0
    dut.i_port1_fp_data.value = 0


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs to idle values."""
    _clear_writes(dut)
    _drive_pd_slot(dut, {})
    _drive_pd_slot(dut, {}, slot2=True)
    _drive_ex_slot(dut)
    _drive_ex_slot(dut, slot2=True)


def _drive_int_write(
    dut: Any,
    *,
    port: int,
    addr: int,
    data: int,
    enable: bool = True,
) -> None:
    """Drive one integer commit write port."""
    prefix = f"i_port{port}_int"
    getattr(dut, f"{prefix}_we").value = int(enable)
    getattr(dut, f"{prefix}_addr").value = addr
    getattr(dut, f"{prefix}_data").value = data


def _drive_fp_write(
    dut: Any,
    *,
    port: int,
    addr: int,
    data: int,
    enable: bool = True,
) -> None:
    """Drive one FP commit write port."""
    prefix = f"i_port{port}_fp"
    getattr(dut, f"{prefix}_we").value = int(enable)
    getattr(dut, f"{prefix}_addr").value = addr
    getattr(dut, f"{prefix}_data").value = data


async def _setup_test(dut: Any) -> None:
    """Start the clock and initialize inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    await Timer(1, unit="ns")


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _commit_writes(dut: Any) -> None:
    """Clock in currently-driven writes and clear the write ports."""
    await _advance_cycle(dut)
    _clear_writes(dut)
    await _settle()


def _drive_all_int_reads(dut: Any, *, rs1: int, rs2: int) -> None:
    """Drive both INT slots so ID and dispatch read the same source pair."""
    _drive_pd_slot(dut, {"source_reg_1_early": rs1, "source_reg_2_early": rs2})
    _drive_pd_slot(
        dut,
        {"source_reg_1_early": rs1, "source_reg_2_early": rs2},
        slot2=True,
    )
    _drive_ex_slot(dut, rs1=rs1, rs2=rs2)
    _drive_ex_slot(dut, rs1=rs1, rs2=rs2, slot2=True)


def _drive_all_fp_reads(dut: Any, *, rs1: int, rs2: int, rs3: int) -> None:
    """Drive both FP slots so ID and dispatch read the same source triple."""
    _drive_pd_slot(
        dut,
        {
            "source_reg_1_early": rs1,
            "source_reg_2_early": rs2,
            "fp_source_reg_3_early": rs3,
        },
    )
    _drive_pd_slot(
        dut,
        {
            "source_reg_1_early": rs1,
            "source_reg_2_early": rs2,
            "fp_source_reg_3_early": rs3,
        },
        slot2=True,
    )
    _drive_ex_slot(dut, rs1=rs1, rs2=rs2, fp_rs3=rs3)
    _drive_ex_slot(dut, rs1=rs1, rs2=rs2, fp_rs3=rs3, slot2=True)


@cocotb.test()
async def test_integer_register_reads_reach_both_slots(dut: Any) -> None:
    """Committed INT values feed ID and dispatch reads for both slots."""
    await _setup_test(dut)

    _drive_int_write(dut, port=0, addr=5, data=0x11112222)
    _drive_int_write(dut, port=1, addr=6, data=0x33334444)
    await _commit_writes(dut)

    _drive_all_int_reads(dut, rs1=5, rs2=6)
    await _settle()

    slot1 = _read_int_slot1(dut)
    slot2 = _read_int_slot2(dut)
    assert int(slot1["source_reg_1_data"]) == 0x11112222
    assert int(slot1["source_reg_2_data"]) == 0x33334444
    assert int(slot2["source_reg_1_data"]) == 0x11112222
    assert int(slot2["source_reg_2_data"]) == 0x33334444
    assert int(dut.o_int_rf_dispatch_rs1_data.value) == 0x11112222
    assert int(dut.o_int_rf_dispatch_rs2_data.value) == 0x33334444
    assert int(dut.o_int_rf_dispatch_rs1_data_2.value) == 0x11112222
    assert int(dut.o_int_rf_dispatch_rs2_data_2.value) == 0x33334444


@cocotb.test()
async def test_integer_same_cycle_bypass_prefers_port1(dut: Any) -> None:
    """INT same-cycle bypass chooses slot-2/port-1 data on same-address writes."""
    await _setup_test(dut)

    _drive_all_int_reads(dut, rs1=7, rs2=7)
    _drive_int_write(dut, port=0, addr=7, data=0xAAAA0000)
    _drive_int_write(dut, port=1, addr=7, data=0xBBBB1111)
    await _settle()

    slot1 = _read_int_slot1(dut)
    slot2 = _read_int_slot2(dut)
    assert int(slot1["source_reg_1_data"]) == 0xBBBB1111
    assert int(slot1["source_reg_2_data"]) == 0xBBBB1111
    assert int(slot2["source_reg_1_data"]) == 0xBBBB1111
    assert int(slot2["source_reg_2_data"]) == 0xBBBB1111
    assert int(dut.o_int_rf_dispatch_rs1_data.value) == 0xBBBB1111
    assert int(dut.o_int_rf_dispatch_rs2_data_2.value) == 0xBBBB1111

    await _commit_writes(dut)
    await _settle()

    assert int(_read_int_slot1(dut)["source_reg_1_data"]) == 0xBBBB1111


@cocotb.test()
async def test_integer_x0_write_is_not_bypassed_or_stored(dut: Any) -> None:
    """INT x0 ignores writes and suppresses same-cycle writeback bypass."""
    await _setup_test(dut)

    _drive_all_int_reads(dut, rs1=0, rs2=0)
    _drive_int_write(dut, port=0, addr=0, data=0x12345678)
    _drive_int_write(dut, port=1, addr=0, data=0x87654321)
    await _settle()

    slot1 = _read_int_slot1(dut)
    assert int(slot1["source_reg_1_data"]) == 0
    assert int(slot1["source_reg_2_data"]) == 0
    assert int(dut.o_int_rf_dispatch_rs1_data.value) == 0

    await _commit_writes(dut)

    assert int(_read_int_slot2(dut)["source_reg_1_data"]) == 0


@cocotb.test()
async def test_fp_register_reads_reach_all_sources_and_slots(dut: Any) -> None:
    """Committed FP values feed all three source reads for both slots."""
    await _setup_test(dut)

    _drive_fp_write(dut, port=0, addr=3, data=0x1111222233334444)
    _drive_fp_write(dut, port=1, addr=4, data=0x5555666677778888)
    await _commit_writes(dut)

    _drive_fp_write(dut, port=0, addr=5, data=0x9999AAAABBBBCCCC)
    await _commit_writes(dut)

    _drive_all_fp_reads(dut, rs1=3, rs2=4, rs3=5)
    await _settle()

    slot1 = _read_fp_slot1(dut)
    slot2 = _read_fp_slot2(dut)
    assert int(slot1["fp_source_reg_1_data"]) == 0x1111222233334444
    assert int(slot1["fp_source_reg_2_data"]) == 0x5555666677778888
    assert int(slot1["fp_source_reg_3_data"]) == 0x9999AAAABBBBCCCC
    assert int(slot2["fp_source_reg_1_data"]) == 0x1111222233334444
    assert int(slot2["fp_source_reg_2_data"]) == 0x5555666677778888
    assert int(slot2["fp_source_reg_3_data"]) == 0x9999AAAABBBBCCCC
    assert int(dut.o_fp_rf_dispatch_rs1_data.value) == 0x1111222233334444
    assert int(dut.o_fp_rf_dispatch_rs2_data.value) == 0x5555666677778888
    assert int(dut.o_fp_rf_dispatch_rs3_data.value) == 0x9999AAAABBBBCCCC
    assert int(dut.o_fp_rf_dispatch_rs1_data_2.value) == 0x1111222233334444
    assert int(dut.o_fp_rf_dispatch_rs2_data_2.value) == 0x5555666677778888
    assert int(dut.o_fp_rf_dispatch_rs3_data_2.value) == 0x9999AAAABBBBCCCC


@cocotb.test()
async def test_fp_same_cycle_bypass_prefers_port1(dut: Any) -> None:
    """FP same-cycle bypass chooses slot-2/port-1 data on same-address writes."""
    await _setup_test(dut)

    _drive_all_fp_reads(dut, rs1=9, rs2=9, rs3=9)
    _drive_fp_write(dut, port=0, addr=9, data=0xAAAABBBBCCCCDDDD)
    _drive_fp_write(dut, port=1, addr=9, data=0x1111222233334444)
    await _settle()

    slot1 = _read_fp_slot1(dut)
    slot2 = _read_fp_slot2(dut)
    assert int(slot1["fp_source_reg_1_data"]) == 0x1111222233334444
    assert int(slot1["fp_source_reg_2_data"]) == 0x1111222233334444
    assert int(slot1["fp_source_reg_3_data"]) == 0x1111222233334444
    assert int(slot2["fp_source_reg_1_data"]) == 0x1111222233334444
    assert int(slot2["fp_source_reg_2_data"]) == 0x1111222233334444
    assert int(slot2["fp_source_reg_3_data"]) == 0x1111222233334444
    assert int(dut.o_fp_rf_dispatch_rs3_data.value) == 0x1111222233334444
    assert int(dut.o_fp_rf_dispatch_rs3_data_2.value) == 0x1111222233334444

    await _commit_writes(dut)

    assert int(_read_fp_slot1(dut)["fp_source_reg_1_data"]) == 0x1111222233334444


@cocotb.test()
async def test_fp_register_zero_is_written_and_bypassed(dut: Any) -> None:
    """FP f0 is a normal register, unlike integer x0."""
    await _setup_test(dut)

    _drive_all_fp_reads(dut, rs1=0, rs2=0, rs3=0)
    _drive_fp_write(dut, port=0, addr=0, data=0x0102030405060708)
    await _settle()

    assert int(_read_fp_slot1(dut)["fp_source_reg_1_data"]) == 0x0102030405060708
    assert int(dut.o_fp_rf_dispatch_rs2_data.value) == 0x0102030405060708

    await _commit_writes(dut)

    slot2 = _read_fp_slot2(dut)
    assert int(slot2["fp_source_reg_1_data"]) == 0x0102030405060708
    assert int(slot2["fp_source_reg_2_data"]) == 0x0102030405060708
    assert int(slot2["fp_source_reg_3_data"]) == 0x0102030405060708
