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

"""Unit tests for the IF-stage branch prediction controller."""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


CLOCK_PERIOD_NS = 10
PC_A = 0x80000100
PC_HALFWORD = 0x80000202
SLOT2_PC = 0x80000300
SLOT2_HALFWORD_PC = 0x80000402
RETURN_PC = 0x80000500
TARGET_A = 0x80001000
TARGET_HALFWORD = 0x80002002
TARGET_SLOT2 = 0x80003000
TARGET_SLOT2_HALFWORD = 0x80004000
TARGET_BTB_RETURN = 0x80005000
TARGET_RAS_RETURN = 0x80006000
TARGET_RAS_RECOVERY = 0x80007000

OPC_JAL = 0b1101111
OPC_JALR = 0b1100111


def _make_instr(
    *,
    funct7: int = 0,
    rs2: int = 0,
    rs1: int = 0,
    funct3: int = 0,
    rd: int = 0,
    opcode: int = 0,
) -> int:
    """Pack an instr_t-compatible RISC-V instruction word."""
    return (
        ((funct7 & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def _make_jal(*, rd: int) -> int:
    """Build a JAL instruction with detector-relevant fields set."""
    return _make_instr(rd=rd, opcode=OPC_JAL)


def _make_jalr(*, rd: int, rs1: int) -> int:
    """Build a JALR instruction with detector-relevant fields set."""
    return _make_instr(rs1=rs1, rd=rd, opcode=OPC_JALR)


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs except reset to idle values."""
    dut.i_stall.value = 0
    dut.i_stall_registered.value = 0
    dut.i_flush.value = 0
    dut.i_pc.value = 0
    dut.i_pc_2.value = 0
    dut.i_slot2_valid.value = 0
    dut.i_slot2_pc_is_halfword.value = 0
    dut.i_slot2_is_compressed.value = 0
    dut.i_trap_taken.value = 0
    dut.i_mret_taken.value = 0
    dut.i_branch_taken.value = 0
    dut.i_any_holdoff_safe.value = 0
    dut.i_is_32bit_spanning.value = 0
    dut.i_spanning_wait_for_fetch.value = 0
    dut.i_spanning_in_progress.value = 0
    dut.i_use_instr_buffer.value = 0
    dut.i_disable_branch_prediction.value = 0
    dut.i_btb_update.value = 0
    dut.i_btb_update_pc.value = 0
    dut.i_btb_update_target.value = 0
    dut.i_btb_update_taken.value = 0
    dut.i_btb_update_compressed.value = 0
    dut.i_btb_update_requires_pc_reg_handoff.value = 0
    dut.i_dir_update_valid.value = 0
    dut.i_dir_update_idx.value = 0
    dut.i_dir_update_taken.value = 0
    dut.i_instruction.value = 0
    dut.i_raw_parcel.value = 0
    dut.i_is_compressed.value = 0
    dut.i_instruction_valid.value = 0
    dut.i_link_address.value = 0
    dut.i_ras_misprediction.value = 0
    dut.i_ras_restore_tos.value = 0
    dut.i_ras_restore_valid_count.value = 0
    dut.i_ras_pop_after_restore.value = 0
    dut.i_ras_push_after_restore.value = 0
    dut.i_ras_push_address_after_restore.value = 0


async def _settle() -> None:
    """Let combinational outputs settle."""
    await Timer(1, unit="ns")


async def _advance_cycle(dut: Any) -> None:
    """Advance one clock edge and let registered outputs settle."""
    await RisingEdge(dut.i_clk)
    await _settle()


async def _setup_test(dut: Any) -> None:
    """Start the clock, reset controller state, and clear inputs."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_reset.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_reset.value = 0
    await _settle()


async def _btb_update(
    dut: Any,
    *,
    pc: int,
    target: int,
    taken: bool = True,
    compressed: bool = False,
    handoff: bool = False,
) -> None:
    """Apply one BTB update and clear the update port."""
    _clear_inputs(dut)
    dut.i_btb_update.value = 1
    dut.i_btb_update_pc.value = pc
    dut.i_btb_update_target.value = target
    dut.i_btb_update_taken.value = int(taken)
    dut.i_btb_update_compressed.value = int(compressed)
    dut.i_btb_update_requires_pc_reg_handoff.value = int(handoff)
    await _advance_cycle(dut)
    dut.i_btb_update.value = 0
    await _settle()


def _drive_call(dut: Any, *, link_address: int) -> None:
    """Drive a valid call instruction for RAS push."""
    dut.i_instruction.value = _make_jal(rd=1)
    dut.i_instruction_valid.value = 1
    dut.i_link_address.value = link_address


def _drive_return(dut: Any) -> None:
    """Drive a valid JALR x0, x1, 0 return instruction for RAS prediction."""
    dut.i_instruction.value = _make_jalr(rd=0, rs1=1)
    dut.i_instruction_valid.value = 1


def _assert_no_effective_slot1_prediction(dut: Any) -> None:
    """Assert that slot-1 prediction is not consumed by the controller."""
    assert not dut.o_prediction_used.value
    assert not dut.o_prediction_used_for_pc.value
    assert not dut.o_control_flow_to_halfword_pred.value


@cocotb.test()
async def test_reset_clears_registered_prediction_state(dut: Any) -> None:
    """Reset clears registered prediction metadata and holdoff state."""
    await _setup_test(dut)

    assert not dut.o_prediction_used_r.value
    assert not dut.o_sel_prediction_r.value
    assert not dut.o_prediction_holdoff.value
    assert not dut.o_btb_only_prediction_holdoff.value
    assert not dut.o_slot2_prediction_used.value
    assert not dut.o_ras_predicted.value


@cocotb.test()
async def test_slot1_btb_prediction_registers_metadata_and_holdoffs(dut: Any) -> None:
    """A used BTB prediction registers target metadata and one-cycle holdoffs."""
    await _setup_test(dut)
    await _btb_update(dut, pc=PC_A, target=TARGET_A, handoff=True)

    dut.i_pc.value = PC_A
    await _settle()

    assert dut.o_predicted_taken.value
    assert int(dut.o_predicted_target.value) == TARGET_A
    assert dut.o_prediction_used.value
    assert dut.o_prediction_used_for_pc.value
    assert dut.o_prediction_requires_pc_reg_handoff.value
    assert not dut.o_ras_predicted.value
    assert not dut.o_control_flow_to_halfword_pred.value

    await _advance_cycle(dut)

    assert dut.o_prediction_used_r.value
    assert dut.o_sel_prediction_r.value
    assert int(dut.o_predicted_target_r.value) == TARGET_A
    assert dut.o_prediction_holdoff.value
    assert dut.o_btb_only_prediction_holdoff.value

    _clear_inputs(dut)
    await _advance_cycle(dut)

    assert not dut.o_prediction_used_r.value
    assert not dut.o_prediction_holdoff.value
    assert not dut.o_btb_only_prediction_holdoff.value


@cocotb.test()
async def test_slot1_btb_prediction_blockers_suppress_effective_use(dut: Any) -> None:
    """Stable controller blockers suppress BTB predictions without hiding raw hits."""
    await _setup_test(dut)
    await _btb_update(dut, pc=PC_A, target=TARGET_A)

    blockers: tuple[tuple[str, int], ...] = (
        ("i_disable_branch_prediction", 1),
        ("i_any_holdoff_safe", 1),
        ("i_spanning_wait_for_fetch", 1),
        ("i_spanning_in_progress", 1),
        ("i_use_instr_buffer", 1),
        ("i_trap_taken", 1),
        ("i_mret_taken", 1),
        ("i_stall_registered", 1),
    )

    for signal_name, value in blockers:
        _clear_inputs(dut)
        dut.i_pc.value = PC_A
        getattr(dut, signal_name).value = value
        await _settle()

        assert dut.o_predicted_taken.value
        assert int(dut.o_predicted_target.value) == TARGET_A
        _assert_no_effective_slot1_prediction(dut)


@cocotb.test()
async def test_first_stall_cycle_keeps_pc_select_but_not_metadata(dut: Any) -> None:
    """A first-cycle stall may select PC but must not commit prediction metadata."""
    await _setup_test(dut)
    await _btb_update(dut, pc=PC_A, target=TARGET_A)

    dut.i_pc.value = PC_A
    dut.i_stall.value = 1
    await _settle()

    assert dut.o_prediction_used_for_pc.value
    assert not dut.o_prediction_used.value

    await _advance_cycle(dut)

    assert not dut.o_prediction_used_r.value
    assert not dut.o_sel_prediction_r.value
    assert not dut.o_prediction_holdoff.value
    assert not dut.o_btb_only_prediction_holdoff.value


@cocotb.test()
async def test_late_branch_and_spanning_gates_suppress_prediction_use(
    dut: Any,
) -> None:
    """Late branch resolution and spanning state suppress otherwise valid BTB hits."""
    await _setup_test(dut)
    await _btb_update(dut, pc=PC_A, target=TARGET_A)

    for signal_name in ("i_branch_taken", "i_is_32bit_spanning"):
        _clear_inputs(dut)
        dut.i_pc.value = PC_A
        getattr(dut, signal_name).value = 1
        await _settle()

        assert dut.o_predicted_taken.value
        assert int(dut.o_predicted_target.value) == TARGET_A
        _assert_no_effective_slot1_prediction(dut)


@cocotb.test()
async def test_halfword_slot1_btb_requires_compressed_entry(dut: Any) -> None:
    """Slot-1 halfword PCs only use BTB entries trained as compressed branches."""
    await _setup_test(dut)
    await _btb_update(
        dut,
        pc=PC_HALFWORD,
        target=TARGET_HALFWORD,
        compressed=False,
    )

    dut.i_pc.value = PC_HALFWORD
    await _settle()

    assert dut.o_predicted_taken.value
    _assert_no_effective_slot1_prediction(dut)

    await _btb_update(
        dut,
        pc=PC_HALFWORD,
        target=TARGET_HALFWORD,
        compressed=True,
    )

    dut.i_pc.value = PC_HALFWORD
    await _settle()

    assert dut.o_prediction_used.value
    assert dut.o_prediction_used_for_pc.value
    assert dut.o_control_flow_to_halfword_pred.value


@cocotb.test()
async def test_ras_return_prediction_takes_priority_over_btb(dut: Any) -> None:
    """A valid RAS return prediction overrides a simultaneous BTB target."""
    await _setup_test(dut)

    _drive_call(dut, link_address=TARGET_RAS_RETURN)
    await _advance_cycle(dut)
    _clear_inputs(dut)
    await _btb_update(dut, pc=RETURN_PC, target=TARGET_BTB_RETURN)

    dut.i_pc.value = RETURN_PC
    _drive_return(dut)
    await _settle()

    assert dut.o_ras_predicted.value
    assert int(dut.o_ras_predicted_target.value) == TARGET_RAS_RETURN
    assert dut.o_predicted_taken.value
    assert int(dut.o_predicted_target.value) == TARGET_RAS_RETURN
    assert dut.o_prediction_used.value
    assert dut.o_prediction_used_for_pc.value

    await _advance_cycle(dut)

    assert dut.o_prediction_holdoff.value
    assert not dut.o_btb_only_prediction_holdoff.value


@cocotb.test()
async def test_ras_recovery_inputs_are_registered_before_restore(dut: Any) -> None:
    """RAS recovery inputs take effect one cycle after reaching the controller."""
    await _setup_test(dut)

    dut.i_ras_misprediction.value = 1
    dut.i_ras_restore_tos.value = 0
    dut.i_ras_restore_valid_count.value = 0
    dut.i_ras_push_after_restore.value = 1
    dut.i_ras_push_address_after_restore.value = TARGET_RAS_RECOVERY
    await _advance_cycle(dut)

    _clear_inputs(dut)
    _drive_return(dut)
    await _settle()

    assert not dut.o_ras_predicted.value

    _clear_inputs(dut)
    await _advance_cycle(dut)

    _drive_return(dut)
    await _settle()

    assert dut.o_ras_predicted.value
    assert int(dut.o_ras_predicted_target.value) == TARGET_RAS_RECOVERY


@cocotb.test()
async def test_slot2_btb_prediction_gates_valid_and_halfword_size_match(
    dut: Any,
) -> None:
    """Slot-2 predictions require valid slot-2 state and matching halfword size."""
    await _setup_test(dut)
    await _btb_update(dut, pc=SLOT2_PC, target=TARGET_SLOT2)

    dut.i_pc_2.value = SLOT2_PC
    await _settle()

    assert not dut.o_slot2_btb_hit.value
    assert not dut.o_slot2_prediction_used.value

    dut.i_slot2_valid.value = 1
    await _settle()

    assert dut.o_slot2_btb_hit.value
    assert dut.o_slot2_prediction_used.value
    assert dut.o_slot2_prediction_used_for_pc.value
    assert int(dut.o_slot2_predicted_target.value) == TARGET_SLOT2

    dut.i_stall.value = 1
    await _settle()

    assert dut.o_slot2_prediction_used_for_pc.value
    assert not dut.o_slot2_prediction_used.value

    await _btb_update(
        dut,
        pc=SLOT2_HALFWORD_PC,
        target=TARGET_SLOT2_HALFWORD,
        compressed=False,
    )

    dut.i_pc_2.value = SLOT2_HALFWORD_PC
    dut.i_slot2_valid.value = 1
    dut.i_slot2_pc_is_halfword.value = 1
    dut.i_slot2_is_compressed.value = 1
    await _settle()

    assert dut.o_slot2_btb_hit.value
    assert not dut.o_slot2_prediction_used.value

    dut.i_slot2_is_compressed.value = 0
    await _settle()

    assert dut.o_slot2_prediction_used.value
    assert dut.o_slot2_prediction_used_for_pc.value
