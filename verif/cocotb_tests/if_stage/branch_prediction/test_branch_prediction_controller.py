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
BP_DIR_IDX_BITS = 10
BIM_MASK = (1 << BP_DIR_IDX_BITS) - 1
PC_A = 0x80000100
PC_B = 0x80000120
PC_HALFWORD = 0x80000202
SLOT2_PC = 0x80000300
SLOT2_HALFWORD_PC = 0x80000402
RETURN_PC = 0x80000500
TARGET_A = 0x80001000
TARGET_HALFWORD = 0x80002002
TARGET_SLOT2 = 0x80003000
TARGET_SLOT2_ALT = 0x80003400
TARGET_SLOT2_HALFWORD = 0x80004000
TARGET_BTB_RETURN = 0x80005000
TARGET_RAS_RETURN = 0x80006000
TARGET_RAS_RECOVERY = 0x80007000
GHOST_OWNER_PC = 0x80000700

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


def _dir_idx(pc: int) -> int:
    """Return the branch direction predictor index for a fetch PC."""
    return (pc >> 1) & BIM_MASK


def _clear_inputs(dut: Any) -> None:
    """Drive all inputs except reset to idle values."""
    dut.i_stall.value = 0
    dut.i_stall_registered.value = 0
    dut.i_fetch_progress.value = 1
    dut.i_flush.value = 0
    dut.i_pd_redirect.value = 0
    dut.i_pc.value = 0
    dut.i_pc_2.value = 0
    dut.i_pc_2_alt.value = 0
    dut.i_pc_2_base.value = 0
    dut.i_lookup_lead_collapsed.value = 0
    dut.i_slot2_plus2_candidate_valid.value = 0
    dut.i_slot2_plus4_candidate_valid.value = 0
    dut.i_slot2_valid.value = 0
    dut.i_slot2_is_compressed_plus2.value = 0
    dut.i_slot2_is_compressed_plus4.value = 0
    dut.i_slot2_is_compressed.value = 0
    dut.i_trap_taken.value = 0
    dut.i_mret_taken.value = 0
    dut.i_branch_taken.value = 0
    dut.i_any_holdoff_safe.value = 0
    dut.i_is_32bit_spanning.value = 0
    dut.i_use_instr_buffer.value = 0
    dut.i_disable_branch_prediction.value = 0
    dut.i_disable_branch_prediction_wcs0.value = 0
    dut.i_disable_branch_prediction_wcs.value = 0
    dut.i_window_cannot_serve_raw.value = 0
    dut.i_fetch_lookup_is_lower_parcel.value = 0
    dut.i_btb_update.value = 0
    dut.i_btb_update_pc.value = 0
    dut.i_btb_update_target.value = 0
    dut.i_btb_update_taken.value = 0
    dut.i_btb_update_compressed.value = 0
    dut.i_btb_update_requires_pc_reg_handoff.value = 0
    dut.i_btb_early_update_active.value = 0
    dut.i_btb_early_update_pc.value = 0
    dut.i_btb_early_update_taken.value = 0
    dut.i_btb_late_update_pc.value = 0
    dut.i_btb_late_update_taken.value = 0
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
    """Apply one BTB update through the controller's staging register."""
    _clear_inputs(dut)
    dut.i_btb_update.value = 1
    dut.i_btb_update_pc.value = pc
    dut.i_btb_update_target.value = target
    dut.i_btb_update_taken.value = int(taken)
    dut.i_btb_update_compressed.value = int(compressed)
    dut.i_btb_update_requires_pc_reg_handoff.value = int(handoff)
    dut.i_btb_late_update_pc.value = pc
    dut.i_btb_late_update_taken.value = int(taken)
    await _advance_cycle(dut)
    dut.i_btb_update.value = 0
    # branch_prediction_controller registers the full BTB update transaction,
    # so the predictor writes it on this following edge.
    await _advance_cycle(dut)


async def _stage_slot2_images(dut: Any, lookup_base: int) -> None:
    """Launch the T2, T4, and rotated-T2 reads from the early fetch PC."""
    dut.i_pc.value = lookup_base
    await _advance_cycle(dut)


async def _dir_update(dut: Any, *, idx: int, taken: bool) -> None:
    """Apply one branch direction predictor update and clear the update port."""
    _clear_inputs(dut)
    dut.i_dir_update_valid.value = 1
    dut.i_dir_update_idx.value = idx
    dut.i_dir_update_taken.value = int(taken)
    await _advance_cycle(dut)
    dut.i_dir_update_valid.value = 0
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
async def test_direction_update_trains_registered_slot1_metadata(dut: Any) -> None:
    """Direction updates train the embedded predictor and snapshot slot-1 metadata."""
    await _setup_test(dut)

    await _dir_update(dut, idx=_dir_idx(PC_A), taken=True)
    await _dir_update(dut, idx=_dir_idx(PC_A), taken=True)

    dut.i_pc.value = PC_A
    dut.i_pc_2.value = SLOT2_PC
    await _settle()

    assert not dut.o_predicted_taken.value
    assert not dut.o_prediction_used.value
    assert int(dut.o_dir_idx_2.value) == _dir_idx(SLOT2_PC)

    await _advance_cycle(dut)

    assert dut.o_dir_predicted_taken.value
    assert int(dut.o_dir_idx.value) == _dir_idx(PC_A)
    assert not dut.o_prediction_used_r.value


@cocotb.test()
async def test_direction_slot1_snapshot_holds_during_stall(dut: Any) -> None:
    """The registered slot-1 direction metadata holds while IF is stalled."""
    await _setup_test(dut)

    await _dir_update(dut, idx=_dir_idx(PC_A), taken=True)
    await _dir_update(dut, idx=_dir_idx(PC_A), taken=True)

    dut.i_pc.value = PC_A
    await _advance_cycle(dut)

    assert dut.o_dir_predicted_taken.value
    assert int(dut.o_dir_idx.value) == _dir_idx(PC_A)

    # The registered metadata stays with PC_A, while the live companions
    # always identify the current lookup PC for a collapsed-lead response.
    dut.i_pc.value = PC_B
    await _settle()
    assert not dut.o_dir_predicted_taken_live.value
    assert dut.o_dir_predicted_taken.value
    assert int(dut.o_dir_idx_live.value) == _dir_idx(PC_B)
    assert int(dut.o_dir_idx.value) == _dir_idx(PC_A)

    dut.i_stall.value = 1
    await _advance_cycle(dut)

    assert dut.o_dir_predicted_taken.value
    assert int(dut.o_dir_idx.value) == _dir_idx(PC_A)


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
async def test_slot2_collision_kills_metadata_and_quarantines_holdoffs(
    dut: Any,
) -> None:
    """A slot-2 redirect wins over a simultaneous younger slot-1 prediction.

    Slot-2 validity is late instruction-memory sideband.  It must still kill
    slot-1's registered handoff and metadata on the collision edge, but the two
    holdoff flops omit that late clear so the sideband cone stays off their
    synchronous reset pins.  A simultaneous slot-1 hit may therefore load them
    for the mandatory redirect bubble.  Model both a fetch-invalid stretch and
    a registered stall, then verify the holdoffs clear on the first delivered
    bubble cycle without reviving slot-1 state.
    """
    await _setup_test(dut)
    await _btb_update(dut, pc=PC_A, target=TARGET_A, handoff=True)
    await _btb_update(dut, pc=SLOT2_PC, target=TARGET_SLOT2)

    _clear_inputs(dut)
    await _stage_slot2_images(dut, SLOT2_PC - 2)
    dut.i_pc.value = PC_A
    dut.i_pc_2.value = SLOT2_PC
    dut.i_pc_2_base.value = SLOT2_PC - 2
    dut.i_slot2_plus2_candidate_valid.value = 1
    dut.i_slot2_valid.value = 1
    await _settle()

    assert dut.o_prediction_used.value
    assert dut.o_slot2_prediction_used.value
    assert int(dut.o_predicted_target.value) == TARGET_A
    assert int(dut.o_slot2_predicted_target.value) == TARGET_SLOT2

    await _advance_cycle(dut)

    # Slot-2 owns the redirect, so the younger slot-1 handoff/metadata die on
    # the collision edge.  Its holdoff load is harmless bubble-only state.
    assert not dut.o_prediction_used_r.value
    assert not dut.o_sel_prediction_r.value
    assert dut.o_prediction_holdoff.value
    assert dut.o_btb_only_prediction_holdoff.value

    _clear_inputs(dut)
    dut.i_any_holdoff_safe.value = 1
    dut.i_fetch_progress.value = 0
    await _advance_cycle(dut)

    assert dut.o_prediction_holdoff.value
    assert dut.o_btb_only_prediction_holdoff.value
    assert not dut.o_prediction_used_r.value
    assert not dut.o_sel_prediction_r.value

    dut.i_fetch_progress.value = 1
    dut.i_stall.value = 1
    dut.i_stall_registered.value = 1
    await _advance_cycle(dut)

    assert dut.o_prediction_holdoff.value
    assert dut.o_btb_only_prediction_holdoff.value
    assert not dut.o_prediction_used_r.value
    assert not dut.o_sel_prediction_r.value

    # The registered redirect bubble remains a prediction blocker on its first
    # delivered cycle.  Releasing the stretch therefore loads zeros and adds no
    # extra holdoff cycle.
    dut.i_stall.value = 0
    dut.i_stall_registered.value = 0
    await _advance_cycle(dut)

    assert not dut.o_prediction_holdoff.value
    assert not dut.o_btb_only_prediction_holdoff.value
    assert not dut.o_prediction_used_r.value
    assert not dut.o_sel_prediction_r.value


@cocotb.test()
async def test_live_prediction_holdoff_blocks_slot2_redirect(dut: Any) -> None:
    """Slot-2 cannot consume a prediction while slot-1 metadata is live."""
    await _setup_test(dut)
    await _btb_update(dut, pc=PC_A, target=TARGET_A)
    await _btb_update(dut, pc=SLOT2_PC, target=TARGET_A)

    _clear_inputs(dut)
    dut.i_pc.value = PC_A
    await _advance_cycle(dut)

    assert dut.o_prediction_used_r.value
    assert dut.o_prediction_holdoff.value
    assert dut.o_btb_only_prediction_holdoff.value

    _clear_inputs(dut)
    # Hold the live slot-1 bookkeeping while the slot-2 images are staged.
    dut.i_fetch_progress.value = 0
    await _stage_slot2_images(dut, SLOT2_PC - 2)
    dut.i_fetch_progress.value = 1
    dut.i_pc_2.value = SLOT2_PC
    dut.i_pc_2_base.value = SLOT2_PC - 2
    dut.i_slot2_plus2_candidate_valid.value = 1
    dut.i_slot2_valid.value = 1
    await _settle()

    assert dut.o_slot2_btb_hit.value
    assert not dut.o_slot2_prediction_used.value
    assert not dut.o_slot2_prediction_used_for_pc.value
    assert dut.o_prediction_used_r.value
    assert dut.o_prediction_holdoff.value


@cocotb.test()
async def test_pd_redirect_target_match_preserves_stalled_metadata(
    dut: Any,
) -> None:
    """A stalled matching PD redirect preserves metadata; a mismatch kills it."""
    await _setup_test(dut)
    await _btb_update(dut, pc=PC_A, target=TARGET_A, handoff=True)

    _clear_inputs(dut)
    dut.i_pc.value = PC_A
    await _advance_cycle(dut)

    assert dut.o_prediction_used_r.value
    assert dut.o_sel_prediction_r.value
    assert dut.o_prediction_holdoff.value
    assert dut.o_btb_only_prediction_holdoff.value

    _clear_inputs(dut)
    dut.i_stall.value = 1
    dut.i_stall_registered.value = 1
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = TARGET_A
    await _advance_cycle(dut)

    # The redirect always kills the pc_reg handoff.  With no fetch progress,
    # matching metadata and its holdoffs remain attached to the same target.
    assert dut.o_prediction_used_r.value
    assert not dut.o_sel_prediction_r.value
    assert dut.o_prediction_holdoff.value
    assert dut.o_btb_only_prediction_holdoff.value

    dut.i_pd_redirect_target.value = TARGET_SLOT2
    await _advance_cycle(dut)

    assert not dut.o_prediction_used_r.value
    assert not dut.o_sel_prediction_r.value
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
        ("i_use_instr_buffer", 1),
        ("i_trap_taken", 1),
        ("i_mret_taken", 1),
        ("i_stall_registered", 1),
        ("i_fetch_lookup_is_lower_parcel", 1),
    )

    for signal_name, value in blockers:
        _clear_inputs(dut)
        dut.i_pc.value = PC_A
        getattr(dut, signal_name).value = value
        if signal_name == "i_disable_branch_prediction":
            dut.i_disable_branch_prediction_wcs0.value = value
            dut.i_disable_branch_prediction_wcs.value = value
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
async def test_native_halfword_ras_return_uses_full_fetch_window(dut: Any) -> None:
    """A native return at PC[1]=1 is complete in the 64-bit fetch window."""
    await _setup_test(dut)

    _drive_call(dut, link_address=TARGET_RAS_RETURN)
    await _advance_cycle(dut)
    _clear_inputs(dut)

    dut.i_pc.value = PC_HALFWORD
    _drive_return(dut)
    dut.i_is_compressed.value = 0
    await _settle()

    assert dut.o_ras_predicted.value
    assert dut.o_prediction_used.value
    assert dut.o_prediction_used_for_pc.value
    assert int(dut.o_predicted_target.value) == TARGET_RAS_RETURN


@cocotb.test()
async def test_lower_parcel_lookup_witness_does_not_block_ras(dut: Any) -> None:
    """The containing-word BTB gate leaves real assembled returns predictive."""
    await _setup_test(dut)

    _drive_call(dut, link_address=TARGET_RAS_RETURN)
    await _advance_cycle(dut)
    _clear_inputs(dut)

    dut.i_pc.value = RETURN_PC
    dut.i_fetch_lookup_is_lower_parcel.value = 1
    _drive_return(dut)
    await _settle()

    assert dut.o_ras_predicted.value
    assert dut.o_prediction_used.value
    assert dut.o_prediction_used_for_pc.value
    assert int(dut.o_predicted_target.value) == TARGET_RAS_RETURN


@cocotb.test()
async def test_spanning_ras_return_suppresses_use_without_pop(dut: Any) -> None:
    """A spanning return waits without consuming its RAS entry."""
    await _setup_test(dut)

    _drive_call(dut, link_address=TARGET_RAS_RETURN)
    await _advance_cycle(dut)
    _clear_inputs(dut)

    dut.i_pc.value = RETURN_PC
    _drive_return(dut)
    dut.i_is_32bit_spanning.value = 1
    await _settle()

    assert not dut.o_ras_predicted.value
    _assert_no_effective_slot1_prediction(dut)
    assert int(dut.o_predicted_target.value) == TARGET_RAS_RETURN
    assert int(dut.o_ras_checkpoint_valid_count.value) == 1

    # Holding the spanning return through an edge must not consume the top.
    await _advance_cycle(dut)
    assert not dut.o_ras_predicted.value
    assert int(dut.o_ras_checkpoint_valid_count.value) == 1

    # Once the assembled instruction is no longer spanning, the same return
    # becomes usable and its prediction consumes exactly that preserved entry.
    dut.i_is_32bit_spanning.value = 0
    await _settle()
    assert dut.o_ras_predicted.value
    assert dut.o_prediction_used.value
    assert dut.o_prediction_used_for_pc.value
    assert int(dut.o_predicted_target.value) == TARGET_RAS_RETURN
    assert int(dut.o_ras_checkpoint_valid_count.value) == 1

    await _advance_cycle(dut)
    assert int(dut.o_ras_checkpoint_valid_count.value) == 0
    assert not dut.o_ras_predicted.value


@cocotb.test()
async def test_ras_target_payload_is_independent_of_global_prediction_disable(
    dut: Any,
) -> None:
    """Prediction disable clears validity without selecting the BTB payload."""
    await _setup_test(dut)

    _drive_call(dut, link_address=TARGET_RAS_RETURN)
    await _advance_cycle(dut)
    _clear_inputs(dut)
    await _btb_update(dut, pc=RETURN_PC, target=TARGET_BTB_RETURN)

    dut.i_pc.value = RETURN_PC
    _drive_return(dut)
    dut.i_disable_branch_prediction.value = 1
    dut.i_disable_branch_prediction_wcs0.value = 1
    dut.i_disable_branch_prediction_wcs.value = 1
    await _settle()

    assert not dut.o_ras_predicted.value
    _assert_no_effective_slot1_prediction(dut)
    assert int(dut.o_predicted_target.value) == TARGET_RAS_RETURN

    dut.i_disable_branch_prediction.value = 0
    dut.i_disable_branch_prediction_wcs0.value = 0
    dut.i_disable_branch_prediction_wcs.value = 0
    await _settle()

    assert dut.o_ras_predicted.value
    assert dut.o_prediction_used.value
    assert int(dut.o_predicted_target.value) == TARGET_RAS_RETURN


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

    await _stage_slot2_images(dut, SLOT2_PC - 2)
    dut.i_pc_2.value = SLOT2_PC
    dut.i_pc_2_base.value = SLOT2_PC - 2
    # The candidate-valid arm may remain live while the full IF validity gate
    # suppresses a holdoff/flush cycle.
    dut.i_slot2_plus2_candidate_valid.value = 1
    await _settle()

    assert not dut.o_slot2_btb_hit.value
    assert not dut.o_slot2_prediction_used.value

    dut.i_slot2_valid.value = 1
    await _settle()

    assert dut.o_slot2_btb_hit.value
    assert dut.o_slot2_prediction_used.value
    assert dut.o_slot2_prediction_used_for_pc.value

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

    await _stage_slot2_images(dut, SLOT2_HALFWORD_PC - 2)
    dut.i_pc_2.value = SLOT2_HALFWORD_PC
    dut.i_pc_2_base.value = SLOT2_HALFWORD_PC - 2
    dut.i_slot2_plus2_candidate_valid.value = 1
    dut.i_slot2_valid.value = 1
    dut.i_slot2_is_compressed_plus2.value = 1
    dut.i_slot2_is_compressed.value = 1
    await _settle()

    assert dut.o_slot2_btb_hit.value
    assert not dut.o_slot2_prediction_used.value

    dut.i_slot2_is_compressed_plus2.value = 0
    dut.i_slot2_is_compressed.value = 0
    await _settle()

    assert dut.o_slot2_prediction_used.value
    assert dut.o_slot2_prediction_used_for_pc.value


@cocotb.test()
async def test_slot2_btb_prediction_safely_misses_unstaged_current_index(
    dut: Any,
) -> None:
    """Candidate validity cannot escape the staged base/successor coverage."""
    await _setup_test(dut)
    await _btb_update(dut, pc=SLOT2_PC, target=TARGET_SLOT2)

    # Launch a disjoint image read, then present an otherwise valid current
    # slot-2 candidate. The predictor must not reuse registered image data.
    await _stage_slot2_images(dut, SLOT2_PC + 0x20)
    dut.i_pc_2.value = SLOT2_PC
    dut.i_pc_2_base.value = SLOT2_PC - 2
    dut.i_slot2_plus2_candidate_valid.value = 1
    dut.i_slot2_valid.value = 1
    await _settle()

    assert not dut.o_slot2_btb_hit.value
    assert not dut.o_slot2_predicted_taken.value
    assert not dut.o_slot2_prediction_used.value
    assert not dut.o_slot2_prediction_used_for_pc.value

    # The same candidate becomes visible once its predecessor index is staged
    # on the preceding edge.
    dut.i_slot2_plus2_candidate_valid.value = 0
    dut.i_slot2_valid.value = 0
    await _stage_slot2_images(dut, SLOT2_PC - 2)
    dut.i_slot2_plus2_candidate_valid.value = 1
    dut.i_slot2_valid.value = 1
    await _settle()

    assert dut.o_slot2_btb_hit.value
    assert dut.o_slot2_predicted_taken.value
    assert dut.o_slot2_prediction_used.value
    assert dut.o_slot2_prediction_used_for_pc.value


@cocotb.test()
async def test_collapsed_fetch_lead_transfers_live_taken_hit_to_slot2(
    dut: Any,
) -> None:
    """A live taken hit redirects with emitted slot-2 metadata ownership.

    A fetch-invalid response gap can collapse the usual one-cycle lookup lead:
    the live slot-1 BTB address then names the branch already carried by slot 2.
    If slot 2's staged image missed, transfer that exact hit and target to slot
    2.  The emitted branch is stamped taken, so a not-taken loop exit recovers
    to its fall-through. No duplicate live slot-1 prediction may arm; an older
    registered RAS call remains independently valid.
    """
    await _setup_test(dut)
    await _btb_update(dut, pc=SLOT2_PC, target=TARGET_SLOT2)

    # Model the observed collapsed-lead failure: the staged slot-2 row is
    # unrelated, while the live slot-1 lookup has caught up to the emitted +4
    # candidate behind a native slot 1.
    await _stage_slot2_images(dut, SLOT2_PC + 0x20)
    dut.i_pc.value = SLOT2_PC
    dut.i_pc_2_alt.value = SLOT2_PC
    dut.i_pc_2_base.value = SLOT2_PC - 4
    dut.i_lookup_lead_collapsed.value = 1
    dut.i_slot2_plus4_candidate_valid.value = 1
    dut.i_slot2_valid.value = 1
    # The RAS input is the older registered packet. Its real call must push
    # even while this younger live lookup belongs to emitted slot 2.
    _drive_call(dut, link_address=PC_B)
    await _settle()

    assert dut.btb_hit.value
    assert dut.btb_predicted_taken.value
    assert not dut.btb_hit_2.value
    assert dut.slot2_live_fallback_hit.value
    assert dut.o_predicted_taken.value
    assert int(dut.o_predicted_target.value) == TARGET_SLOT2
    assert dut.o_slot2_btb_hit.value
    assert dut.o_slot2_predicted_taken.value
    assert dut.o_slot2_prediction_used.value
    assert dut.o_slot2_prediction_used_for_pc.value
    assert int(dut.o_slot2_predicted_target.value) == TARGET_SLOT2
    _assert_no_effective_slot1_prediction(dut)
    assert not dut.o_prediction_requires_pc_reg_handoff.value
    assert not dut.o_ras_predicted.value

    await _advance_cycle(dut)

    assert not dut.o_prediction_used_r.value
    assert not dut.o_sel_prediction_r.value
    assert not dut.o_prediction_holdoff.value
    assert not dut.o_btb_only_prediction_holdoff.value
    assert not dut.o_dir_predicted_taken.value
    assert int(dut.o_dir_idx.value) == 0
    assert int(dut.o_ras_checkpoint_valid_count.value) == 1

    # Once ordinary fixed-latency lookahead stages the exact predecessor image,
    # that image is authoritative and the fallback arm stays idle. Slot 2 is
    # still the unique owner: the identical live lookup must not redundantly
    # register the already-emitted branch as a future slot-1 prediction.
    _clear_inputs(dut)
    await _stage_slot2_images(dut, SLOT2_PC - 4)
    dut.i_pc.value = SLOT2_PC
    dut.i_pc_2_alt.value = SLOT2_PC
    dut.i_pc_2_base.value = SLOT2_PC - 4
    dut.i_slot2_plus4_candidate_valid.value = 1
    dut.i_slot2_valid.value = 1
    await _settle()

    assert dut.btb_hit_2.value
    assert not dut.slot2_live_fallback_hit.value
    assert dut.o_slot2_btb_hit.value
    assert dut.o_slot2_prediction_used.value
    assert int(dut.o_slot2_predicted_target.value) == TARGET_SLOT2
    assert dut.slot1_aliases_emitted_slot2.value
    _assert_no_effective_slot1_prediction(dut)
    assert not dut.o_prediction_requires_pc_reg_handoff.value


@cocotb.test()
async def test_fixed_lead_live_taken_disagreement_has_no_duplicate_owner(
    dut: Any,
) -> None:
    """A late live-taken verdict cannot re-own an emitted slot-2 branch.

    A BTB training update can become visible to the combinational slot-1
    lookup after the synchronous slot-2 image was launched.  When the live PC
    exactly names the branch being emitted in slot 2, consuming that newer
    verdict as a future slot-1 prediction would replay the same branch with
    stale bytes.  Suppress the duplicate live owner for this transition; the
    already-emitted, unpredicted branch will resolve normally.
    """
    await _setup_test(dut)
    await _btb_update(dut, pc=SLOT2_PC, target=TARGET_SLOT2)

    # Keep the staged image stale/disjoint while the live canonical lookup has
    # the trained taken row.  Unlike the fetch-gap fallback test above, this is
    # ordinary fixed-latency service.
    await _stage_slot2_images(dut, SLOT2_PC + 0x20)
    dut.i_pc.value = SLOT2_PC
    dut.i_pc_2_alt.value = SLOT2_PC
    dut.i_pc_2_base.value = SLOT2_PC - 4
    dut.i_lookup_lead_collapsed.value = 0
    dut.i_slot2_plus4_candidate_valid.value = 1
    dut.i_slot2_valid.value = 1
    _drive_call(dut, link_address=PC_B)
    await _settle()

    assert dut.btb_hit.value
    assert dut.btb_predicted_taken.value
    assert not dut.btb_hit_2.value
    assert dut.fixed_lead_live_taken_aliases_emitted_slot2.value
    assert dut.slot1_aliases_emitted_slot2.value
    # The owner-free timing cofactor deliberately retains the otherwise-valid
    # live proposal; only the canonical slot-1 consumer applies ownership.
    assert dut.o_prediction_used_live_cofactor.value
    assert not dut.slot2_live_fallback_hit.value
    assert not dut.o_slot2_btb_hit.value
    assert not dut.o_slot2_prediction_used.value
    assert not dut.o_slot2_prediction_used_for_pc.value
    _assert_no_effective_slot1_prediction(dut)
    assert not dut.o_prediction_requires_pc_reg_handoff.value
    assert not dut.o_ras_predicted.value

    await _advance_cycle(dut)

    assert not dut.o_prediction_used_r.value
    assert not dut.o_sel_prediction_r.value
    assert not dut.o_prediction_holdoff.value
    assert not dut.o_btb_only_prediction_holdoff.value
    assert not dut.o_dir_predicted_taken.value
    assert int(dut.o_dir_idx.value) == 0
    # The current owner is a newer BTB lookup; it cannot suppress the older
    # registered call's stack update.
    assert int(dut.o_ras_checkpoint_valid_count.value) == 1


@cocotb.test()
async def test_older_ras_return_ignores_current_slot2_candidate_owner(
    dut: Any,
) -> None:
    """Current BTB ownership cannot suppress an older registered return."""
    await _setup_test(dut)

    # Seed one return address, then present the older return while an unrelated
    # collapsed-lead +4 candidate owns the current live BTB lookup.
    _drive_call(dut, link_address=TARGET_RAS_RETURN)
    await _advance_cycle(dut)
    _clear_inputs(dut)

    dut.i_pc.value = SLOT2_PC
    dut.i_pc_2_alt.value = SLOT2_PC
    dut.i_pc_2_base.value = SLOT2_PC - 4
    dut.i_lookup_lead_collapsed.value = 1
    dut.i_slot2_plus4_candidate_valid.value = 1
    dut.i_slot2_valid.value = 1
    _drive_return(dut)
    await _settle()

    assert int(dut.o_ras_checkpoint_valid_count.value) == 1
    assert dut.slot1_prediction_owned_by_slot2.value
    assert dut.o_prediction_used_live_cofactor.value
    assert dut.o_prediction_used.value
    assert dut.o_prediction_used_for_pc.value
    assert dut.o_ras_predicted.value
    assert int(dut.o_predicted_target.value) == TARGET_RAS_RETURN

    await _advance_cycle(dut)

    assert int(dut.o_ras_checkpoint_valid_count.value) == 0


@cocotb.test()
async def test_older_ras_return_preempts_younger_slot2_redirect(dut: Any) -> None:
    """A delayed return owns the redirect ahead of a current slot-2 hit."""
    await _setup_test(dut)

    _drive_call(dut, link_address=TARGET_RAS_RETURN)
    await _advance_cycle(dut)
    await _btb_update(dut, pc=SLOT2_PC, target=TARGET_SLOT2)
    await _stage_slot2_images(dut, SLOT2_PC - 4)

    dut.i_pc.value = SLOT2_PC
    dut.i_pc_2_alt.value = SLOT2_PC
    dut.i_pc_2_base.value = SLOT2_PC - 4
    dut.i_slot2_plus4_candidate_valid.value = 1
    dut.i_slot2_valid.value = 1
    _drive_return(dut)
    await _settle()

    assert dut.slot1_prediction_owned_by_slot2.value
    assert dut.btb_hit.value
    assert dut.btb_hit_2.value
    assert dut.o_slot2_btb_hit.value
    assert not dut.o_slot2_prediction_used.value
    assert not dut.o_slot2_prediction_used_for_pc.value
    assert not dut.o_slot2_predicted_taken.value
    assert dut.o_ras_predicted.value
    assert dut.o_prediction_used.value
    assert dut.o_prediction_used_for_pc.value
    assert int(dut.o_predicted_target.value) == TARGET_RAS_RETURN
    assert dut.ras_inst.do_pop.value

    await _advance_cycle(dut)

    assert int(dut.o_ras_checkpoint_valid_count.value) == 0


@cocotb.test()
async def test_slot2_candidate_owner_blocks_slot1_when_full_slot2_valid_is_low(
    dut: Any,
) -> None:
    """Late packet validity stays out of slot-1 prediction ownership.

    IF can force a candidate slot-2 position to one-wide after the timing
    candidate has already identified it, notably while preserving a pending
    prediction owner.  A taken live lookup at that candidate must not become a
    duplicate slot-1 owner, but no nonexistent slot-2 packet may receive the
    fallback metadata either.
    """
    await _setup_test(dut)
    await _btb_update(dut, pc=SLOT2_PC, target=TARGET_SLOT2)

    await _stage_slot2_images(dut, SLOT2_PC + 0x20)
    dut.i_pc.value = SLOT2_PC
    dut.i_pc_2_alt.value = SLOT2_PC
    dut.i_pc_2_base.value = SLOT2_PC - 4
    dut.i_slot2_plus4_candidate_valid.value = 1
    dut.i_slot2_valid.value = 0
    _drive_call(dut, link_address=PC_B)
    await _settle()

    assert dut.btb_predicted_taken.value
    assert dut.slot1_prediction_owned_by_slot2.value
    assert not dut.slot1_aliases_emitted_slot2.value
    assert not dut.fixed_lead_live_taken_aliases_emitted_slot2.value
    assert not dut.slot2_live_fallback_hit.value
    assert not dut.o_slot2_btb_hit.value
    assert not dut.o_slot2_prediction_used.value
    _assert_no_effective_slot1_prediction(dut)
    assert not dut.o_dir_predicted_taken_live.value
    assert not dut.o_prediction_requires_pc_reg_handoff.value
    assert not dut.o_ras_predicted.value

    await _advance_cycle(dut)

    assert not dut.o_prediction_used_r.value
    assert not dut.o_sel_prediction_r.value
    assert not dut.o_prediction_holdoff.value
    assert not dut.o_btb_only_prediction_holdoff.value
    assert not dut.o_dir_predicted_taken.value
    assert int(dut.o_dir_idx.value) == 0
    assert int(dut.o_ras_checkpoint_valid_count.value) == 1


@cocotb.test()
async def test_blocked_ghost_slot2_candidate_preserves_direction_snapshot(
    dut: Any,
) -> None:
    """An unobservable timing candidate cannot zero the next packet's snapshot."""
    await _setup_test(dut)
    ghost_idx = _dir_idx(GHOST_OWNER_PC)

    # Make both the live BTB verdict and the independent bimodal direction
    # observably taken at the ghost candidate address.
    await _dir_update(dut, idx=ghost_idx, taken=True)
    await _dir_update(dut, idx=ghost_idx, taken=True)
    await _btb_update(dut, pc=GHOST_OWNER_PC, target=TARGET_SLOT2)

    # Candidate identity is a timing cofactor and may remain asserted while a
    # global holdoff suppresses the full packet.  It still blocks unobservable
    # live ownership, but it must not poison the registered metadata snapshot
    # that advances for the following packet.
    await _stage_slot2_images(dut, GHOST_OWNER_PC + 0x20)
    dut.i_pc.value = GHOST_OWNER_PC
    dut.i_pc_2_alt.value = GHOST_OWNER_PC
    dut.i_pc_2_base.value = GHOST_OWNER_PC - 4
    dut.i_slot2_plus4_candidate_valid.value = 1
    dut.i_slot2_valid.value = 0
    dut.i_any_holdoff_safe.value = 1
    await _settle()

    assert dut.btb_predicted_taken.value
    assert dut.dir_taken.value
    assert dut.slot1_prediction_owned_by_slot2.value
    assert not dut.slot1_snapshot_owned_by_slot2.value
    assert not dut.prediction_common.value
    assert not dut.o_dir_predicted_taken_live.value

    await _advance_cycle(dut)
    _clear_inputs(dut)
    await _settle()

    assert dut.o_dir_predicted_taken.value
    assert int(dut.o_dir_idx.value) == ghost_idx

    # direction_predictor RAM is not reset between cocotb tests.  Return this
    # dedicated row to strongly not-taken so later tests remain order-neutral.
    await _dir_update(dut, idx=ghost_idx, taken=False)
    await _dir_update(dut, idx=ghost_idx, taken=False)


@cocotb.test()
async def test_collapsed_fetch_lead_transfers_live_not_taken_hit_metadata(
    dut: Any,
) -> None:
    """A live not-taken fallback remains a slot-2 hit without redirecting."""
    await _setup_test(dut)
    await _btb_update(dut, pc=SLOT2_PC, target=TARGET_SLOT2, taken=False)

    await _stage_slot2_images(dut, SLOT2_PC + 0x20)
    dut.i_pc.value = SLOT2_PC
    dut.i_pc_2.value = SLOT2_PC
    dut.i_pc_2_base.value = SLOT2_PC - 2
    dut.i_lookup_lead_collapsed.value = 1
    dut.i_slot2_plus2_candidate_valid.value = 1
    dut.i_slot2_valid.value = 1
    _drive_call(dut, link_address=PC_B)
    await _settle()

    assert dut.btb_hit.value
    assert not dut.btb_predicted_taken.value
    assert not dut.btb_hit_2.value
    assert dut.slot2_live_fallback_hit.value
    assert dut.o_slot2_btb_hit.value
    assert not dut.o_slot2_predicted_taken.value
    assert not dut.o_slot2_prediction_used.value
    assert not dut.o_slot2_prediction_used_for_pc.value
    assert int(dut.o_slot2_predicted_target.value) == TARGET_SLOT2
    _assert_no_effective_slot1_prediction(dut)
    assert not dut.o_prediction_requires_pc_reg_handoff.value

    await _advance_cycle(dut)

    assert not dut.o_prediction_used_r.value
    assert not dut.o_sel_prediction_r.value
    assert not dut.o_dir_predicted_taken.value
    assert int(dut.o_dir_idx.value) == 0
    assert int(dut.o_ras_checkpoint_valid_count.value) == 1


@cocotb.test()
async def test_slot2_btb_prediction_selects_alternate_pc_candidate(dut: Any) -> None:
    """One-hot valid arms preserve target identity and local safety qualification."""
    await _setup_test(dut)
    await _btb_update(dut, pc=SLOT2_PC, target=TARGET_SLOT2)
    await _btb_update(dut, pc=SLOT2_PC + 2, target=TARGET_SLOT2_ALT)

    await _stage_slot2_images(dut, SLOT2_PC - 2)
    dut.i_pc_2.value = SLOT2_PC
    dut.i_pc_2_alt.value = SLOT2_PC + 2
    dut.i_pc_2_base.value = SLOT2_PC - 2
    dut.i_slot2_plus2_candidate_valid.value = 1
    dut.i_slot2_plus4_candidate_valid.value = 0
    dut.i_slot2_valid.value = 1
    # The +2 candidate is word-aligned, so a live/BTB size mismatch plays no
    # part in its safety qualification.
    dut.i_slot2_is_compressed_plus2.value = 1
    dut.i_slot2_is_compressed_plus4.value = 1
    dut.i_slot2_is_compressed.value = 1
    await _settle()

    assert dut.o_slot2_btb_hit.value
    assert dut.o_slot2_prediction_used.value
    assert int(dut.o_slot2_predicted_target.value) == TARGET_SLOT2

    dut.i_slot2_plus2_candidate_valid.value = 0
    dut.i_slot2_plus4_candidate_valid.value = 1
    await _settle()

    assert dut.o_slot2_btb_hit.value
    # The +4 candidate is halfword-aligned and was trained native.  Its strict
    # size guard must block use, while the +4 valid arm still chooses its hit
    # and target metadata.
    assert not dut.o_slot2_prediction_used.value
    assert int(dut.o_slot2_predicted_target.value) == TARGET_SLOT2_ALT

    dut.i_slot2_is_compressed_plus4.value = 0
    dut.i_slot2_is_compressed.value = 0
    await _settle()

    assert dut.o_slot2_prediction_used.value
    assert dut.o_slot2_prediction_used_for_pc.value
    assert int(dut.o_slot2_predicted_target.value) == TARGET_SLOT2_ALT
