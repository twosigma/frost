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

"""Integration tests for the decoupled parcel-queue IF-stage top level."""

from collections.abc import Mapping
from functools import lru_cache
import importlib.util
from pathlib import Path
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tests.cpu_structs import (
    FROM_EX_FIELDS,
    IF_TO_PD_FIELDS,
    PIPELINE_CTRL_FIELDS,
)
from config import XLEN
from utils.packed_structs import (
    pack_struct as _pack_struct,
    unpack_struct as _unpack_struct,
)


@lru_cache(maxsize=1)
def _predecode_model() -> Any:
    """Load the predecode generator matching riscv_pkg::imem_make_sideband."""
    path = (
        Path(__file__).resolve().parents[3]
        / "sw/common/generate_imem_predecode_init.py"
    )
    spec = importlib.util.spec_from_file_location("expanded_predecode_model", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CLOCK_PERIOD_NS = 10
SIDEBAND_WIDTH = 80
SIDEBAND_MASK = (1 << SIDEBAND_WIDTH) - 1
WORD_MASK = (1 << (XLEN - 2)) - 1

# Executable BRAM addresses (in low executable PMA region 0x0000_0000..0x0003_FFFF)
BASE_PC = 0x00001000
BRANCH_TARGET = 0x00002000
TRAP_TARGET = 0x00003000
FENCE_TARGET = 0x00003400
PD_TARGET = 0x00002800

NOP_INSTR = 0x00000013  # addi x0, x0, 0
ADD_INSTR_A = 0x00B50533  # add x10, x10, x11
ADD_INSTR_B = 0x00C585B3  # add x11, x11, x12
ADD_INSTR_C = 0x00D60633  # add x12, x12, x13
ADD_INSTR_D = 0x00E686B3  # add x13, x13, x14
BRANCH_INSTR = 0x00000063  # beq x0, x0, 0
CALL_RA_INSTR = 0x000000EF  # jal ra, 0
RETURN_RA_INSTR = 0x00008067  # jalr x0, 0(ra)
COMPRESSED_NOP = 0x0001  # c.nop
COMPRESSED_ADDIW = 0x2221  # c.addiw x4, 8
COMPRESSED_ADDIW_EXPANDED = 0x0082021B
COMPRESSED_J = (0b101 << 13) | 0b01  # c.j 0

TRAP_CTRL_FIELDS = [
    ("trap_taken", 1),
    ("mret_taken", 1),
    ("trap_target", XLEN),
]


def _word(*, lo: int, hi: int) -> int:
    """Pack two 16-bit halfwords into one 32-bit word."""
    return ((hi & 0xFFFF) << 16) | (lo & 0xFFFF)


def _fetch_sideband(word0: int, word1: int) -> int:
    """Build the 160-bit predecode sideband for a 64-bit window {word1, word0}."""
    model = _predecode_model()
    sb0 = model.make_sideband(word0 & 0xFFFF_FFFF) & SIDEBAND_MASK
    sb1 = model.make_sideband(word1 & 0xFFFF_FFFF) & SIDEBAND_MASK
    return (sb1 << SIDEBAND_WIDTH) | sb0


def _drive_pipeline_ctrl(dut: Any, fields: Mapping[str, int | bool]) -> None:
    dut.i_pipeline_ctrl.value = _pack_struct(PIPELINE_CTRL_FIELDS, fields)


def _drive_from_ex(dut: Any, fields: Mapping[str, int | bool]) -> None:
    dut.i_from_ex_comb.value = _pack_struct(FROM_EX_FIELDS, fields)
    dut.i_btb_late_update_pc.value = int(fields.get("btb_update_pc", 0))
    dut.i_btb_late_update_taken.value = int(fields.get("btb_update_taken", 0))


def _drive_trap_ctrl(dut: Any, fields: Mapping[str, int | bool]) -> None:
    dut.i_trap_ctrl.value = _pack_struct(TRAP_CTRL_FIELDS, fields)


def _drive_window(
    dut: Any,
    *,
    word0: int,
    word1: int = NOP_INSTR,
    served_pc: int | None = None,
    valid: int = 1,
    fault0: int = 0,
    fault0_page: int = 0,
    fault1: int = 0,
    fault1_page: int = 0,
    served_high: int = 0,
) -> None:
    """Drive a 64-bit fetch window, its canonical sideband, and served-word tag."""
    fetch = ((word1 & 0xFFFF_FFFF) << 32) | (word0 & 0xFFFF_FFFF)
    dut.i_instr.value = fetch
    dut.i_instr_low_by_parity.value = 0 if served_high else fetch
    dut.i_instr_high.value = fetch if served_high else 0
    dut.i_instr_window_high.value = served_high
    dut.i_instr_sideband.value = _fetch_sideband(word0, word1)
    dut.i_instr_pc_metadata.value = 0
    dut.i_instr_pc_metadata_by_provider_parity.value = 0
    dut.i_pc_pairability_by_provider_parity.value = 0
    dut.i_slot2_start_valid_lo_by_provider_parity.value = 0
    dut.i_instr_pc_metadata_served_high.value = served_high
    dut.i_instr_bank_sel_r.value = 0
    dut.i_served_high.value = served_high
    dut.i_instr_valid.value = valid
    dut.i_instr_fault0.value = fault0
    dut.i_instr_fault0_page.value = fault0_page
    dut.i_instr_fault1.value = fault1
    dut.i_instr_fault1_page.value = fault1_page
    if served_pc is not None:
        sw = (served_pc >> 2) & WORD_MASK
        for lane in ("low", "high"):
            getattr(dut, f"i_served_word_{lane}").value = sw
            getattr(dut, f"i_served_last_word_{lane}").value = (sw + 1) & WORD_MASK
            getattr(dut, f"i_served_prev_word_{lane}").value = (sw - 1) & WORD_MASK
            getattr(dut, f"i_served_prev_word_valid_{lane}").value = int(sw != 0)


def _read_packet(dut: Any, *, slot2: bool = False) -> dict[str, Any]:
    sig = dut.o_from_if_to_pd_2 if slot2 else dut.o_from_if_to_pd
    return _unpack_struct(IF_TO_PD_FIELDS, int(sig.value))


async def _settle() -> None:
    await Timer(1, unit="ns")


async def _step(dut: Any) -> None:
    await RisingEdge(dut.i_clk)
    await _settle()


def _clear_inputs(dut: Any, *, boot_addr: int = BASE_PC) -> None:
    dut.i_boot_addr.value = boot_addr
    _drive_from_ex(dut, {})
    dut.i_btb_early_update_active.value = 0
    dut.i_btb_early_update_pc.value = 0
    dut.i_btb_early_update_taken.value = 0
    dut.i_dir_update_valid.value = 0
    dut.i_dir_update_idx.value = 0
    dut.i_dir_update_taken.value = 0
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=boot_addr, valid=0)
    dut.i_fetch_translation_active.value = 0
    dut.i_fetch_priv_u.value = 0
    dut.i_fetch_asid.value = 0
    dut.i_tlb_invalidate.value = 0
    dut.i_tlb_flush.value = 0
    dut.i_walk_req_ready.value = 0
    dut.i_walk_resp_valid.value = 0
    dut.i_walk_resp.value = 0
    _drive_pipeline_ctrl(dut, {})
    _drive_trap_ctrl(dut, {})
    dut.i_frontend_state_flush.value = 0
    dut.i_flush_all.value = 0
    dut.i_fence_i_flush.value = 0
    dut.i_fence_i_target.value = 0
    dut.i_btb_invalidate.value = 0
    dut.i_disable_branch_prediction.value = 1
    dut.i_fetch_trap_hold.value = 0
    dut.i_pd_redirect.value = 0
    dut.i_pd_redirect_taken.value = 1
    dut.i_pd_redirect_target.value = 0
    dut.i_pd_redirect_ras_push.value = 0
    dut.i_pd_redirect_ras_pop.value = 0
    dut.i_pd_redirect_ras_link.value = 0
    dut.i_pd_backing_refresh.value = 0
    dut.i_pd_backing_refresh_pc.value = 0
    dut.i_tage_hist.value = 0
    dut.i_itt_hist.value = 0
    dut.i_tage_train_valid.value = 0
    dut.i_tage_train_lookup.value = 0
    dut.i_tage_train_bank.value = 0
    dut.i_tage_train_alt_taken.value = 0
    dut.i_tage_train_taken.value = 0
    dut.i_tage_train_mispredicted.value = 0
    dut.i_itt_train_valid.value = 0
    dut.i_itt_train_lookup.value = 0
    dut.i_itt_train_bank.value = 0
    dut.i_itt_train_target.value = 0
    dut.i_itt_train_mispredicted.value = 0


async def _reset_dut(
    dut: Any,
    *,
    boot_addr: int = BASE_PC,
    enable_bp: bool = False,
) -> None:
    Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start()
    _clear_inputs(dut, boot_addr=boot_addr)
    dut.i_disable_branch_prediction.value = int(not enable_bp)
    _drive_pipeline_ctrl(dut, {"reset": 1})
    await _step(dut)
    await _step(dut)
    _drive_pipeline_ctrl(dut, {"reset": 0})
    await _settle()


async def _train_btb(
    dut: Any,
    *,
    pc: int,
    target: int,
    taken: bool = True,
    compressed: bool = False,
    call: bool = False,
    ret: bool = False,
    jump: bool = False,
    repeats: int = 2,
) -> None:
    """Train the fast BTB (and optionally backing BTB) via EX feedback."""
    for _ in range(repeats):
        _drive_from_ex(
            dut,
            {
                "btb_update": 1,
                "btb_update_pc": pc,
                "btb_update_target": target,
                "btb_update_taken": int(taken),
                "btb_update_compressed": int(compressed),
                "btb_update_call": int(call),
                "btb_update_return": int(ret),
                "btb_update_jump": int(jump),
            },
        )
        await _step(dut)
    _drive_from_ex(dut, {})
    # Allow the 1-cycle registered BTB update flop to commit into the RAM.
    await _step(dut)


class _SimpleFetchMem:
    """One-cycle synchronous fetch-provider model keyed by 32-bit word address."""

    def __init__(self, words: Mapping[int, int]) -> None:
        self.words = dict(words)
        self.faults: dict[int, tuple[int, int]] = {}
        self.pending_pc: int | None = None

    def read_word(self, addr: int) -> int:
        return self.words.get(addr & ~3, NOP_INSTR)

    def read_fault(self, addr: int) -> tuple[int, int]:
        return self.faults.get(addr & ~3, (0, 0))

    def present(
        self, dut: Any, *, valid: int = 1, override_served_pc: int | None = None
    ) -> None:
        if self.pending_pc is None:
            _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
            return
        base = self.pending_pc & ~3
        f0, f0p = self.read_fault(base)
        f1, f1p = self.read_fault(base + 4)
        _drive_window(
            dut,
            word0=self.read_word(base),
            word1=self.read_word(base + 4),
            served_pc=base if override_served_pc is None else override_served_pc,
            valid=valid,
            fault0=f0,
            fault0_page=f0p,
            fault1=f1,
            fault1_page=f1p,
        )

    def capture_request(self, dut: Any) -> None:
        self.pending_pc = int(dut.o_pc.value)


@cocotb.test()
async def test_reset_loads_boot_addr_and_clears_queue(dut: Any) -> None:
    """Reset loads o_pc from i_boot_addr and leaves both output slots as NOPs."""
    await _reset_dut(dut, boot_addr=BASE_PC)
    assert int(dut.o_pc.value) == BASE_PC
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is True
    assert s2["sel_nop"] is True
    assert int(dut.o_fetch_redirect.value) == 0


@cocotb.test()
async def test_zero_cycle_empty_bypass_native_pair(dut: Any) -> None:
    """An empty parcel queue bypasses an arriving 64-bit native window with zero latency."""
    mem = _SimpleFetchMem(
        {
            BASE_PC: ADD_INSTR_A,
            BASE_PC + 4: ADD_INSTR_B,
            BASE_PC + 8: ADD_INSTR_C,
            BASE_PC + 12: ADD_INSTR_D,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC)

    # Cycle 0: launch F0 request for BASE_PC while no window has returned yet (valid=1
    # launches immediately on a 1-cycle memory interface).
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)

    # Cycle 1: BASE_PC window arrives in F1 while queue is empty -> 0-cycle empty bypass!
    assert int(dut.o_pc.value) == BASE_PC + 8
    mem.present(dut, valid=1)
    await _settle()

    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False
    assert s1["program_counter"] == BASE_PC
    assert s1["effective_instr"] == ADD_INSTR_A
    assert s1["sel_compressed"] is False
    assert s2["sel_nop"] is False
    assert s2["program_counter"] == BASE_PC + 4
    assert s2["effective_instr"] == ADD_INSTR_B
    assert s2["sel_compressed"] is False

    mem.capture_request(dut)
    await _step(dut)

    # Cycle 2: next window (BASE_PC + 8, BASE_PC + 12) bypasses immediately as well.
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC + 8
    assert s1["effective_instr"] == ADD_INSTR_C
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 12
    assert s2["effective_instr"] == ADD_INSTR_D


@cocotb.test()
async def test_compressed_four_parcel_window_and_queue_draining(dut: Any) -> None:
    """Four 16-bit parcels bypass the first pair and drain the second pair from the queue."""
    w0 = _word(lo=COMPRESSED_ADDIW, hi=COMPRESSED_NOP)
    w1 = _word(lo=COMPRESSED_ADDIW, hi=COMPRESSED_NOP)
    mem = _SimpleFetchMem({BASE_PC: w0, BASE_PC + 4: w1})
    await _reset_dut(dut, boot_addr=BASE_PC)

    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)

    # First window arrives: slots 1+2 emit PC+0 and PC+2; PC+4 and PC+6 buffer in the queue.
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC
    assert s1["sel_compressed"] is True and s1["raw_parcel"] == COMPRESSED_ADDIW
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 2
    assert s2["sel_compressed"] is True and s2["raw_parcel"] == COMPRESSED_NOP
    assert s2["effective_instr"] == NOP_INSTR

    # Hold i_instr_valid=0 on the next cycle: the queue must still drain PC+4 and PC+6!
    await _step(dut)
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC + 4
    assert s1["raw_parcel"] == COMPRESSED_ADDIW
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 6
    assert s2["raw_parcel"] == COMPRESSED_NOP


@cocotb.test()
async def test_spanning_32bit_instruction_and_partial_bypass(dut: Any) -> None:
    """A 32-bit instruction spanning window boundaries assembles via zero-cycle partial bypass."""
    # Window 0: [0]=C.NOP, [1..2]=ADD_INSTR_A, [3]=ADD_INSTR_B[15:0]
    # Window 1: [0]=ADD_INSTR_B[31:16], [1]=C.ADDIW, [2..3]=ADD_INSTR_C
    w0 = _word(lo=COMPRESSED_NOP, hi=ADD_INSTR_A & 0xFFFF)
    w1 = _word(lo=(ADD_INSTR_A >> 16) & 0xFFFF, hi=ADD_INSTR_B & 0xFFFF)
    w2 = _word(lo=(ADD_INSTR_B >> 16) & 0xFFFF, hi=COMPRESSED_ADDIW)
    w3 = ADD_INSTR_C
    mem = _SimpleFetchMem(
        {BASE_PC: w0, BASE_PC + 4: w1, BASE_PC + 8: w2, BASE_PC + 12: w3}
    )
    await _reset_dut(dut, boot_addr=BASE_PC)

    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)

    # Cycle 1: window 0 arrives -> emits C.NOP (PC+0) + ADD_INSTR_A (PC+2), leaving hw[3] queued.
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 2
    assert s2["effective_instr"] == ADD_INSTR_A

    mem.capture_request(dut)
    await _step(dut)

    # Cycle 2: window 1 arrives while 1 halfword sits in the queue -> partial bypass
    # stitches ADD_INSTR_B (PC+6) and pairs C.ADDIW (PC+10) in the same cycle!
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC + 6
    assert s1["sel_compressed"] is False and s1["effective_instr"] == ADD_INSTR_B
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 10
    assert (
        s2["sel_compressed"] is True
        and s2["effective_instr"] == COMPRESSED_ADDIW_EXPANDED
    )


@cocotb.test()
async def test_stall_buffers_in_parcel_queue_and_asserts_stop_fetch(dut: Any) -> None:
    """Back-end stall fills the parcel queue up to headroom, raises stop_fetch, then drains in order."""
    words = {
        BASE_PC + 4 * i: (ADD_INSTR_A if i % 2 == 0 else ADD_INSTR_B) for i in range(12)
    }
    mem = _SimpleFetchMem(words)
    await _reset_dut(dut, boot_addr=BASE_PC)

    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)

    # Stall PD while streaming windows into the parcel queue.
    _drive_pipeline_ctrl(dut, {"stall": 1})
    saw_stop_fetch = False
    for _ in range(5):
        mem.present(dut, valid=1)
        await _settle()
        s1 = _read_packet(dut, slot2=False)
        assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC
        if int(dut.u_parcel_queue.o_stop_fetch.value) == 1:
            saw_stop_fetch = True
        if int(dut.f0_launch.value) == 1:
            mem.capture_request(dut)
        await _step(dut)
    assert saw_stop_fetch, (
        "parcel queue must assert stop_fetch once occupancy reaches headroom"
    )

    # Release stall with i_instr_valid=0 and verify all buffered instructions drain in order.
    _drive_pipeline_ctrl(dut, {"stall": 0})
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    drained_pcs: list[int] = []
    for _ in range(6):
        await _settle()
        s1 = _read_packet(dut, slot2=False)
        s2 = _read_packet(dut, slot2=True)
        if not s1["sel_nop"]:
            drained_pcs.append(s1["program_counter"])
        if not s2["sel_nop"]:
            drained_pcs.append(s2["program_counter"])
        await _step(dut)

    assert len(drained_pcs) >= 6
    assert drained_pcs == [BASE_PC + 4 * i for i in range(len(drained_pcs))]


@cocotb.test()
async def test_fetch_gap_and_collapsed_lead_accept(dut: Any) -> None:
    """Multi-cycle i_instr_valid gaps hold the launched request without duplicating or dropping parcels."""
    mem = _SimpleFetchMem(
        {
            BASE_PC: ADD_INSTR_A,
            BASE_PC + 4: ADD_INSTR_B,
            BASE_PC + 8: ADD_INSTR_C,
            BASE_PC + 12: ADD_INSTR_D,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC)

    # Arm collapsed lead by keeping i_instr_valid=0 on the first cycle after reset.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=BASE_PC, valid=0)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)

    # One more bubble cycle.
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC
    assert _read_packet(dut, slot2=False)["sel_nop"] is True

    # Window arrives -> collapsed-lead accept delivers BASE_PC and BASE_PC + 4 and advances PC.
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC
    assert s1["effective_instr"] == ADD_INSTR_A
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 4
    assert s2["effective_instr"] == ADD_INSTR_B
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 8


@cocotb.test()
async def test_served_word_tag_mismatch_triggers_f1_resteer(dut: Any) -> None:
    """A mismatched served-word tag squashes the window, pulses redirect, and resteers o_pc."""
    mem = _SimpleFetchMem({BASE_PC: ADD_INSTR_A, BASE_PC + 4: ADD_INSTR_B})
    await _reset_dut(dut, boot_addr=BASE_PC)

    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 8

    # Return a stale served tag (wrong word) for F1: must bubble and resteer to BASE_PC.
    mem.present(dut, valid=1, override_served_pc=BASE_PC + 0x40)
    await _settle()
    assert _read_packet(dut, slot2=False)["sel_nop"] is True
    assert int(dut.o_fetch_live_claim.value) == 0
    await _step(dut)

    assert int(dut.o_pc.value) == BASE_PC
    assert int(dut.o_fetch_redirect.value) == 1


@cocotb.test()
async def test_fast_btb_taken_prediction_and_truncation(dut: Any) -> None:
    """A trained F0 fast-BTB hit steers o_pc immediately and marks the predicted branch."""
    mem = _SimpleFetchMem(
        {
            BASE_PC: ADD_INSTR_A,
            BASE_PC + 4: BRANCH_INSTR,
            BRANCH_TARGET: ADD_INSTR_C,
            BRANCH_TARGET + 4: ADD_INSTR_D,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)

    # Train BTB at BASE_PC + 4 (slot 2 of the first 64-bit window) -> BRANCH_TARGET.
    await _train_btb(dut, pc=BASE_PC + 4, target=BRANCH_TARGET, taken=True)

    # Redirect cleanly to BASE_PC so fetch starts fresh at BASE_PC.
    dut.i_fence_i_flush.value = 1
    dut.i_fence_i_target.value = BASE_PC
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    dut.i_fence_i_flush.value = 0
    _drive_pipeline_ctrl(dut, {"flush": 0})

    # Launch BASE_PC: F0 BTB hits at pos 2 (BASE_PC + 4) and steers o_pc -> BRANCH_TARGET!
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BRANCH_TARGET

    # Cycle 1: BASE_PC window arrives -> slot 1 = ADD_INSTR_A, slot 2 = BRANCH_INSTR (taken).
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC
    assert s1["btb_predicted_taken"] is False
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 4
    assert s2["btb_predicted_taken"] is True
    assert s2["btb_predicted_target"] == BRANCH_TARGET

    mem.capture_request(dut)
    await _step(dut)

    # Cycle 2: BRANCH_TARGET window arrives with zero bubbles!
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    assert s1["sel_nop"] is False and s1["program_counter"] == BRANCH_TARGET
    assert s1["effective_instr"] == ADD_INSTR_C


@cocotb.test()
async def test_false_btb_interior_halfword_triggers_resteer(dut: Any) -> None:
    """A fast-BTB hit on the interior halfword of a 32-bit instruction is cancelled and resteered."""
    # Put a 32-bit ADD_INSTR_A at BASE_PC, whose upper halfword at BASE_PC + 2
    # happens to match a stale BTB entry trained on an overlapping compressed path.
    mem = _SimpleFetchMem({BASE_PC: ADD_INSTR_A, BASE_PC + 4: ADD_INSTR_B})
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)

    await _train_btb(
        dut, pc=BASE_PC + 2, target=BRANCH_TARGET, taken=True, compressed=True
    )

    dut.i_fence_i_flush.value = 1
    dut.i_fence_i_target.value = BASE_PC
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    dut.i_fence_i_flush.value = 0
    _drive_pipeline_ctrl(dut, {"flush": 0})

    # Launch BASE_PC: BTB speculatively steers o_pc -> BRANCH_TARGET.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BRANCH_TARGET

    # Window arrives in F1: interior halfword + non-control check cancels BTB hit,
    # emits ADD_INSTR_A/ADD_INSTR_B untaken, and resteers o_pc to BASE_PC + 8!
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC
    assert s1["effective_instr"] == ADD_INSTR_A and s1["btb_predicted_taken"] is False
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 4
    assert s2["effective_instr"] == ADD_INSTR_B and s2["btb_predicted_taken"] is False
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 8
    assert int(dut.o_fetch_redirect.value) == 1


@cocotb.test()
async def test_spanning_btb_branch_fetches_second_word_then_steers(dut: Any) -> None:
    """A 32-bit predicted branch at hw[3] fetches its upper halfword before steering to target."""
    # Window 0: [0]=C.NOP, [1..2]=ADD_INSTR_A, [3]=BRANCH_INSTR[15:0]
    # Window 1 (span_tail): [0]=BRANCH_INSTR[31:16]
    w0 = _word(lo=COMPRESSED_NOP, hi=ADD_INSTR_A & 0xFFFF)
    w1 = _word(lo=(ADD_INSTR_A >> 16) & 0xFFFF, hi=BRANCH_INSTR & 0xFFFF)
    w2 = _word(lo=(BRANCH_INSTR >> 16) & 0xFFFF, hi=COMPRESSED_NOP)
    mem = _SimpleFetchMem(
        {
            BASE_PC: w0,
            BASE_PC + 4: w1,
            BASE_PC + 8: w2,
            BASE_PC + 12: NOP_INSTR,
            BRANCH_TARGET: ADD_INSTR_C,
            BRANCH_TARGET + 4: ADD_INSTR_D,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(
        dut, pc=BASE_PC + 6, target=BRANCH_TARGET, taken=True, compressed=False
    )

    dut.i_fence_i_flush.value = 1
    dut.i_fence_i_target.value = BASE_PC
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    dut.i_fence_i_flush.value = 0
    _drive_pipeline_ctrl(dut, {"flush": 0})

    # Launch BASE_PC: spanning BTB hit advances sequentially to BASE_PC + 8 first.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 8

    # Window 0 arrives; F0 launches span_tail (BASE_PC + 8) and now steers to BRANCH_TARGET.
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["program_counter"] == BASE_PC
    assert s2["program_counter"] == BASE_PC + 2
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BRANCH_TARGET

    # Span tail arrives: stitches BRANCH_INSTR at BASE_PC + 6 with btb_predicted_taken=True!
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC + 6
    assert s1["effective_instr"] == BRANCH_INSTR
    assert s1["btb_predicted_taken"] is True
    assert s1["btb_predicted_target"] == BRANCH_TARGET
    assert s2["sel_nop"] is True

    mem.capture_request(dut)
    await _step(dut)

    # Target window arrives immediately after span_tail.
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    assert s1["sel_nop"] is False and s1["program_counter"] == BRANCH_TARGET
    assert s1["effective_instr"] == ADD_INSTR_C


@cocotb.test()
async def test_ras_call_return_and_ex_restore(dut: Any) -> None:
    """F0 call pushes the link address, a trained return predicts from RAS, and EX restores it."""
    # Place the return at a distinct BTB index from BASE_PC so both entries coexist.
    ret_pc = BRANCH_TARGET + 0x20
    mem = _SimpleFetchMem(
        {
            BASE_PC: CALL_RA_INSTR,
            BASE_PC + 4: ADD_INSTR_A,
            ret_pc: RETURN_RA_INSTR,
            ret_pc + 4: NOP_INSTR,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(dut, pc=BASE_PC, target=ret_pc, taken=True, call=True, jump=True)
    # Train return with a stale BTB target; RAS must override it with BASE_PC + 4.
    await _train_btb(
        dut, pc=ret_pc, target=FENCE_TARGET, taken=True, ret=True, jump=True
    )

    dut.i_fence_i_flush.value = 1
    dut.i_fence_i_target.value = BASE_PC
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    dut.i_fence_i_flush.value = 0
    _drive_pipeline_ctrl(dut, {"flush": 0})

    # Cycle 0: launch call at BASE_PC -> pushes BASE_PC + 4, steers to ret_pc.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == ret_pc

    # Cycle 1: launch return at ret_pc -> RAS supplies BASE_PC + 4!
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    assert s1["program_counter"] == BASE_PC
    ckpt_tos = s1["ras_checkpoint_tos"]
    ckpt_cnt = s1["ras_checkpoint_valid_count"]
    ckpt_top = s1["ras_checkpoint_top"]
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 4

    # Cycle 2: verify return packet carries the RAS-predicted target BASE_PC + 4.
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    assert s1["program_counter"] == ret_pc
    assert s1["btb_predicted_taken"] is True
    assert s1["btb_predicted_target"] == BASE_PC + 4

    # Trigger an EX RAS restore and verify the registered restore commits cleanly.
    _drive_from_ex(
        dut,
        {
            "branch_taken": 1,
            "branch_target_address": TRAP_TARGET,
            "ras_misprediction": 1,
            "ras_restore_tos": ckpt_tos,
            "ras_restore_valid_count": ckpt_cnt,
            "ras_restore_top": ckpt_top,
            "ras_push_after_restore": 1,
            "ras_push_address_after_restore": BASE_PC + 0x20,
        },
    )
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    _drive_from_ex(dut, {})
    _drive_pipeline_ctrl(dut, {"flush": 0})
    await _step(dut)
    assert int(dut.u_ras.o_nonempty.value) == 1
    assert int(dut.u_ras.o_top.value) == BASE_PC + 0x20


@cocotb.test()
async def test_fetch_faults_and_slot2_deferral(dut: Any) -> None:
    """Word-0 faults, spanning hi-half faults, and slot-2 fault deferral obey all fault contracts."""
    # Case 1: word-0 fault -> slot 1 faults (fetch_fault_hi=0), slot 2 is NOP.
    mem = _SimpleFetchMem({BASE_PC: ADD_INSTR_A, BASE_PC + 4: ADD_INSTR_B})
    mem.faults[BASE_PC] = (1, 1)
    await _reset_dut(dut, boot_addr=BASE_PC)

    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["fetch_fault"] is True
    assert s1["fetch_fault_page"] is True and s1["fetch_fault_hi"] is False
    assert s1["btb_predicted_taken"] is False
    assert s2["sel_nop"] is True and s2["fetch_fault"] is False

    # Case 2: non-faulting word 0 + faulting word 1 -> slot 2 deferred, then delivered as slot 1.
    mem2 = _SimpleFetchMem({BASE_PC: ADD_INSTR_A, BASE_PC + 4: ADD_INSTR_B})
    mem2.faults[BASE_PC + 4] = (1, 0)
    await _reset_dut(dut, boot_addr=BASE_PC)

    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem2.capture_request(dut)
    await _step(dut)
    mem2.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["fetch_fault"] is False
    assert s1["program_counter"] == BASE_PC
    assert s2["sel_nop"] is True and s2["fetch_fault"] is False

    await _step(dut)
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC + 4
    assert s1["fetch_fault"] is True and s1["fetch_fault_page"] is False

    # Case 3: upper-half 32-bit instruction straddling clean word 0 -> faulting word 1
    # must set fetch_fault_hi=True on slot 1.
    w0 = _word(lo=COMPRESSED_NOP, hi=ADD_INSTR_A & 0xFFFF)
    w1 = _word(lo=(ADD_INSTR_A >> 16) & 0xFFFF, hi=COMPRESSED_NOP)
    mem3 = _SimpleFetchMem({BASE_PC: w0, BASE_PC + 4: w1})
    mem3.faults[BASE_PC + 4] = (1, 1)
    await _reset_dut(dut, boot_addr=BASE_PC)

    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem3.capture_request(dut)
    await _step(dut)
    mem3.present(dut, valid=1)
    await _settle()
    # First cycle emits C.NOP at BASE_PC alone (straddling ADD_INSTR_A deferred due to fault).
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC
    assert s1["fetch_fault"] is False and s2["sel_nop"] is True

    await _step(dut)
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC + 2
    assert s1["fetch_fault"] is True and s1["fetch_fault_hi"] is True
    assert s1["fetch_fault_page"] is True


@cocotb.test()
async def test_pd_redirect_trap_priority_and_fetch_trap_hold(dut: Any) -> None:
    """PD redirect waits for stall release, traps beat PD, and fetch_trap_hold pauses drain."""
    await _reset_dut(dut, boot_addr=BASE_PC)

    # Stalled PD redirect must NOT redirect PC or pulse restore arm 4.
    _drive_pipeline_ctrl(dut, {"stall": 1})
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = PD_TARGET
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC
    assert int(dut.o_tage_hist_restore_arm.value) == 0

    # Release stall: PD redirect fires now!
    _drive_pipeline_ctrl(dut, {"stall": 0})
    await _step(dut)
    assert int(dut.o_pc.value) == PD_TARGET
    assert (int(dut.o_tage_hist_restore_arm.value) >> 3) & 1 == 1  # arm 4

    # Trap takes priority over simultaneous PD redirect and FENCE.I flush.
    dut.i_fence_i_flush.value = 1
    dut.i_fence_i_target.value = FENCE_TARGET
    _drive_trap_ctrl(dut, {"trap_taken": 1, "trap_target": TRAP_TARGET})
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    assert int(dut.o_pc.value) == TRAP_TARGET
    assert int(dut.o_tage_hist_restore_arm.value) & 1 == 1  # arm 1

    # Clear redirects and assert i_fetch_trap_hold: suppresses F0 launch and drain output.
    dut.i_pd_redirect.value = 0
    dut.i_fence_i_flush.value = 0
    _drive_trap_ctrl(dut, {})
    _drive_pipeline_ctrl(dut, {"flush": 0})
    dut.i_fetch_trap_hold.value = 1
    _drive_window(
        dut, word0=ADD_INSTR_A, word1=ADD_INSTR_B, served_pc=TRAP_TARGET, valid=1
    )
    await _step(dut)
    assert int(dut.o_pc.value) == TRAP_TARGET
    assert _read_packet(dut, slot2=False)["sel_nop"] is True


@cocotb.test()
async def test_btb_invalidate_four_cycle_hold(dut: Any) -> None:
    """i_btb_invalidate clears entries and blocks training writes during its four-cycle hold."""
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)

    # Pulse invalidate and attempt a BTB training write during the hold window.
    dut.i_btb_invalidate.value = 1
    await _step(dut)
    dut.i_btb_invalidate.value = 0

    _drive_from_ex(
        dut,
        {
            "btb_update": 1,
            "btb_update_pc": BASE_PC,
            "btb_update_target": BRANCH_TARGET,
            "btb_update_taken": 1,
        },
    )
    await _step(dut)
    _drive_from_ex(dut, {})
    for _ in range(3):
        await _step(dut)

    # The write landed during the 4-cycle invalidate hold, so BASE_PC must miss.
    _drive_window(dut, word0=BRANCH_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    assert int(dut.btb_taken_raw.value) == 0

    # Training after the hold expires must install normally.
    await _train_btb(dut, pc=BASE_PC, target=BRANCH_TARGET, taken=True)
    dut.i_fence_i_flush.value = 1
    dut.i_fence_i_target.value = BASE_PC
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    dut.i_fence_i_flush.value = 0
    _drive_pipeline_ctrl(dut, {"flush": 0})
    await _settle()
    assert int(dut.btb_taken_raw.value) == 1


@cocotb.test()
async def test_backing_btb_window_lookup_and_slot2_by_size(dut: Any) -> None:
    """After its reset sweep, backing_btb delivers window hits and per-size slot-2 outputs."""
    mem = _SimpleFetchMem(
        {
            BASE_PC: ADD_INSTR_A,
            BASE_PC + 4: CALL_RA_INSTR,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)

    # Let backing_btb finish its 512-set reset clear sweep.
    for _ in range(520):
        await _step(dut)

    # Train a jump at BASE_PC + 4 -> BRANCH_TARGET in both fast BTB and backing BTB,
    # then invalidate the fast BTB so only backing_btb predicts it.
    await _train_btb(
        dut,
        pc=BASE_PC + 4,
        target=BRANCH_TARGET,
        taken=True,
        call=True,
        jump=True,
        repeats=1,
    )
    # Wait 3 cycles for backing_btb's 3-stage update pipeline to commit.
    for _ in range(4):
        await _step(dut)
    dut.i_btb_invalidate.value = 1
    await _step(dut)
    dut.i_btb_invalidate.value = 0
    for _ in range(4):
        await _step(dut)

    # Fetch BASE_PC window and verify slot 2 carries the backing BTB hit and target.
    dut.i_fence_i_flush.value = 1
    dut.i_fence_i_target.value = BASE_PC
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    dut.i_fence_i_flush.value = 0
    _drive_pipeline_ctrl(dut, {"flush": 0})

    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)

    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 4
    assert (int(dut.o_backing_hit.value) >> 1) & 1 == 1
    backing_tgt = int(dut.o_backing_target.value)
    tgt_bits = len(dut.o_backing_target) // 2
    s2_tgt = ((backing_tgt >> tgt_bits) & ((1 << tgt_bits) - 1)) << 1
    assert s2_tgt == BRANCH_TARGET


# =============================================================================
# Restored Front-End-Independent Contracts & Decoupled Edge-Case Coverage
# =============================================================================

JAL_X0_INSTR = 0x0000006F  # jal x0, 0
JALR_X0_X5_INSTR = 0x00028067  # jalr x0, 0(x5)
JALR_SWAP_RA_INSTR = 0x000080E7  # jalr ra, 0(ra) (call+return swap)
COMPRESSED_BEQZ = 0xC001  # c.beqz x8, 0
COMPRESSED_JR_X5 = 0x8282  # c.jr x5
COMPRESSED_JALR_X5 = 0x9282  # c.jalr x5
COMPRESSED_JR_RA = 0x8082  # c.jr ra
COMPRESSED_JALR_RA = 0x9082  # c.jalr ra
PAGE_END_WORD = 0x0001_3FFC
UNMAPPED_BARE_PC = 0x0004_0000  # above 128 KiB BRAM exec PMA, below DDR


async def _redirect_fence(dut: Any, target: int) -> None:
    """Redirect IF cleanly to target using FENCE.I flush."""
    dut.i_fence_i_flush.value = 1
    dut.i_fence_i_target.value = target
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    dut.i_fence_i_flush.value = 0
    _drive_pipeline_ctrl(dut, {"flush": 0})
    await _settle()


def _ras_state(dut: Any) -> tuple[int, int, int]:
    """Return (nonempty, valid_count, top) from u_ras."""
    return (
        int(dut.u_ras.o_nonempty.value),
        int(dut.u_ras.o_valid_count.value),
        int(dut.u_ras.o_top.value),
    )


async def _launch_and_present(
    dut: Any,
    mem: _SimpleFetchMem,
    *,
    stall: int = 0,
    served_high: int = 0,
    valid: int = 1,
    override_served_pc: int | None = None,
) -> None:
    """Launch current o_pc on cycle 0 and present its window on cycle 1."""
    _drive_pipeline_ctrl(dut, {"stall": stall})
    _drive_window(
        dut,
        word0=NOP_INSTR,
        word1=NOP_INSTR,
        served_pc=0,
        valid=1,
        served_high=served_high,
    )
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    base = 0 if mem.pending_pc is None else (mem.pending_pc & ~3)
    f0, f0p = mem.read_fault(base)
    f1, f1p = mem.read_fault(base + 4)
    _drive_window(
        dut,
        word0=mem.read_word(base),
        word1=mem.read_word(base + 4),
        served_pc=base if override_served_pc is None else override_served_pc,
        valid=valid,
        fault0=f0,
        fault0_page=f0p,
        fault1=f1,
        fault1_page=f1p,
        served_high=served_high,
    )
    await _settle()


# -----------------------------------------------------------------------------
# Group A: Redirects during fetch gaps & stalls (no duplicates / no +2 desync)
# -----------------------------------------------------------------------------


@cocotb.test()
async def test_pd_redirect_during_fetch_gap_does_not_duplicate_target(
    dut: Any,
) -> None:
    """A PD redirect arriving during a fetch gap delivers the target stream once."""
    pd_target = BASE_PC + 0x104
    mem = _SimpleFetchMem(
        {
            BASE_PC: ADD_INSTR_A,
            BASE_PC + 4: BRANCH_INSTR,
            pd_target: ADD_INSTR_C,
            pd_target + 4: ADD_INSTR_D,
            pd_target + 8: ADD_INSTR_A,
            pd_target + 12: ADD_INSTR_B,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(dut, pc=BASE_PC + 4, target=BRANCH_TARGET, taken=True)
    await _redirect_fence(dut, BASE_PC)

    # Launch BASE_PC so a fast-BTB prediction fires toward BRANCH_TARGET.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BRANCH_TARGET

    # PD redirect arrives during a fetch-invalid gap (i_instr_valid=0).
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = pd_target
    await _step(dut)
    dut.i_pd_redirect.value = 0
    assert int(dut.o_pc.value) == pd_target
    assert int(dut.o_fetch_redirect.value) == 1
    assert int(dut.o_fetch_cached_retarget.value) == 1

    # Hold i_instr_valid=0 across mixed stalled/unstalled gap cycles.
    for stalled in (False, True, True, False):
        _drive_pipeline_ctrl(dut, {"stall": int(stalled)})
        await _settle()
        assert _read_packet(dut, slot2=False)["sel_nop"] is True
        await _step(dut)
    _drive_pipeline_ctrl(dut, {})
    assert int(dut.o_pc.value) == pd_target

    # Stale response from the old path (BASE_PC) must be ignored by tag match.
    _drive_window(dut, word0=ADD_INSTR_A, word1=ADD_INSTR_B, served_pc=BASE_PC, valid=1)
    await _settle()
    assert _read_packet(dut, slot2=False)["sel_nop"] is True

    # Matching response for pd_target delivers pd_target and pd_target+4 once via collapsed
    # accept, then cycle 1 launches pd_target+8 and cycle 2 delivers pd_target+8,+12.
    presented: list[int] = []
    mem.pending_pc = pd_target
    for step_idx in range(4):
        if step_idx == 0:
            mem.present(dut, valid=1)
        elif step_idx == 1:
            _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
            await _settle()
            mem.capture_request(dut)
        elif step_idx == 2:
            mem.present(dut, valid=1)
        else:
            _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
        await _settle()
        for slot2 in (False, True):
            pkt = _read_packet(dut, slot2=slot2)
            if not pkt["sel_nop"]:
                presented.append(pkt["program_counter"])
        await _step(dut)

    assert presented == [pd_target, pd_target + 4, pd_target + 8, pd_target + 12]


@cocotb.test()
async def test_branch_redirect_lands_during_fetch_invalid(dut: Any) -> None:
    """EX branch redirect lands while i_instr_valid=0, holds across gaps, then emits target."""
    mem = _SimpleFetchMem(
        {
            BRANCH_TARGET: ADD_INSTR_C,
            BRANCH_TARGET + 4: ADD_INSTR_D,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC)

    # Sit in a fetch-invalid gap before EX branch recovery fires.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC

    _drive_from_ex(dut, {"branch_taken": 1, "branch_target_address": BRANCH_TARGET})
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    _drive_from_ex(dut, {})
    _drive_pipeline_ctrl(dut, {"flush": 0})
    assert int(dut.o_pc.value) == BRANCH_TARGET
    assert int(dut.o_fetch_redirect.value) == 1
    assert int(dut.o_fetch_cached_retarget.value) == 1

    # Hold invalid for 2 more cycles: PC stays at BRANCH_TARGET and output bubbles.
    for _ in range(2):
        await _settle()
        assert int(dut.o_pc.value) == BRANCH_TARGET
        assert _read_packet(dut, slot2=False)["sel_nop"] is True
        await _step(dut)

    # First valid response with stale tag (BASE_PC) must bubble.
    _drive_window(dut, word0=ADD_INSTR_A, word1=ADD_INSTR_B, served_pc=BASE_PC, valid=1)
    await _settle()
    assert _read_packet(dut, slot2=False)["sel_nop"] is True

    # Matching response for BRANCH_TARGET delivers immediately via collapsed accept.
    mem.pending_pc = BRANCH_TARGET
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BRANCH_TARGET
    assert s1["effective_instr"] == ADD_INSTR_C
    assert s2["sel_nop"] is False and s2["program_counter"] == BRANCH_TARGET + 4
    assert s2["effective_instr"] == ADD_INSTR_D


@cocotb.test()
async def test_pd_redirect_with_stall_kills_btb_prediction_path(dut: Any) -> None:
    """A PD redirect colliding with an F0 BTB hit survives a multi-cycle stall without leaking."""
    stale_pred_target = BASE_PC + 0x5000
    pd_target = BASE_PC + 0x6000
    mem = _SimpleFetchMem(
        {
            pd_target: ADD_INSTR_A,
            pd_target + 4: ADD_INSTR_B,
            pd_target + 8: ADD_INSTR_C,
            pd_target + 12: ADD_INSTR_D,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(dut, pc=BASE_PC, target=stale_pred_target, taken=True)
    await _redirect_fence(dut, BASE_PC)

    # Collide PD redirect with an F0 BTB hit at BASE_PC.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = pd_target
    await _settle()
    assert int(dut.btb_taken_raw.value) == 1
    await _step(dut)
    dut.i_pd_redirect.value = 0
    dut.i_pd_redirect_target.value = 0

    assert int(dut.o_pc.value) == pd_target
    assert int(dut.o_fetch_cached_retarget.value) == 1

    # Immediate multi-cycle stall while provider responds for pd_target.
    _drive_pipeline_ctrl(dut, {"stall": 1})
    mem.capture_request(dut)
    await _step(dut)
    for _ in range(3):
        mem.present(dut, valid=1)
        await _settle()
        s1 = _read_packet(dut, slot2=False)
        if not s1["sel_nop"]:
            assert s1["program_counter"] == pd_target
        if int(dut.f0_launch.value) == 1:
            mem.capture_request(dut)
        await _step(dut)

    # Release stall and verify every emitted PC stays strictly on pd_target path.
    _drive_pipeline_ctrl(dut, {"stall": 0})
    presented: list[int] = []
    for _ in range(5):
        mem.present(dut, valid=1)
        await _settle()
        for slot2 in (False, True):
            pkt = _read_packet(dut, slot2=slot2)
            if not pkt["sel_nop"]:
                presented.append(pkt["program_counter"])
        if int(dut.f0_launch.value) == 1:
            mem.capture_request(dut)
        await _step(dut)

    assert presented[:4] == [pd_target, pd_target + 4, pd_target + 8, pd_target + 12]
    assert len(presented) == len(set(presented)), f"duplicate PCs: {presented}"


@cocotb.test()
async def test_pd_redirect_btb_collision_stall_no_duplicate_on_release(
    dut: Any,
) -> None:
    """After a PD redirect + BTB collision + stall, release emits each target PC once."""
    stale_pred_target = BASE_PC + 0x5000
    pd_target = BASE_PC + 0x6200
    mem = _SimpleFetchMem(
        {
            pd_target + 4 * i: (ADD_INSTR_A if i % 2 == 0 else ADD_INSTR_B)
            for i in range(8)
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(dut, pc=BASE_PC, target=stale_pred_target, taken=True)
    await _redirect_fence(dut, BASE_PC)

    # Collision cycle: unstalled PD redirect while F0 BTB hits.
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = pd_target
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _step(dut)
    dut.i_pd_redirect.value = 0
    assert int(dut.o_pc.value) == pd_target

    # Next cycle: stall starts while i_instr_valid=0 for 3 cycles (arms collapsed lead).
    _drive_pipeline_ctrl(dut, {"stall": 1})
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    for _ in range(3):
        await _step(dut)
        assert _read_packet(dut, slot2=False)["sel_nop"] is True

    # Release stall and serve pd_target window, then pd_target+8 window.
    _drive_pipeline_ctrl(dut, {"stall": 0})
    mem.pending_pc = pd_target
    presented: list[int] = []
    for cyc in range(4):
        if cyc == 0:
            mem.present(dut, valid=1)
        elif cyc == 1:
            _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
            mem.capture_request(dut)
        elif cyc == 2:
            mem.present(dut, valid=1)
        else:
            _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
        await _settle()
        for slot2 in (False, True):
            pkt = _read_packet(dut, slot2=slot2)
            if not pkt["sel_nop"]:
                presented.append(pkt["program_counter"])
        await _step(dut)

    assert presented == [pd_target, pd_target + 4, pd_target + 8, pd_target + 12]


@cocotb.test()
async def test_pd_redirect_stall_32bit_target_no_plus2_desync(dut: Any) -> None:
    """A stalled PD redirect colliding with a BTB hit never splits a 32-bit instruction."""
    pd_target = BASE_PC + 0x6400
    mem = _SimpleFetchMem(
        {
            pd_target + 4 * i: (ADD_INSTR_A if i % 2 == 0 else ADD_INSTR_B)
            for i in range(10)
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(
        dut, pc=BASE_PC, target=BASE_PC + 0x5202, taken=True, compressed=True
    )
    await _redirect_fence(dut, BASE_PC)

    # Hold PD redirect under stall for 3 cycles (flushing queue each cycle).
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = pd_target
    _drive_pipeline_ctrl(dut, {"stall": 1})
    for _ in range(3):
        await _step(dut)
        assert int(dut.o_pc.value) == BASE_PC
        assert int(dut.o_fetch_redirect.value) == 0

    # Release stall so PD redirect takes effect.
    _drive_pipeline_ctrl(dut, {"stall": 0})
    await _step(dut)
    dut.i_pd_redirect.value = 0
    assert int(dut.o_pc.value) == pd_target

    # Launch and stream 4 native 64-bit windows; every emitted PC must stay 4-byte aligned.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    pcs: list[int] = []
    for _ in range(4):
        mem.present(dut, valid=1)
        await _settle()
        for slot2 in (False, True):
            pkt = _read_packet(dut, slot2=slot2)
            assert pkt["sel_nop"] is False
            assert (pkt["program_counter"] & 0x2) == 0, (
                f"+2 desync at {pkt['program_counter']:#x}"
            )
            assert pkt["sel_compressed"] is False
            pcs.append(pkt["program_counter"])
        mem.capture_request(dut)
        await _step(dut)
    assert pcs == [pd_target + 4 * i for i in range(8)]


# -----------------------------------------------------------------------------
# Group B: RAS operations exactly once under stall, squash, restore, forwarding
# -----------------------------------------------------------------------------


@cocotb.test()
async def test_typed_call_pushes_once_when_stalled_and_drained(dut: Any) -> None:
    """A trained call pushes exactly once at F0 and never re-pushes while stalled in drain."""
    call_pc = BASE_PC
    callee = BASE_PC + 0x1000
    mem = _SimpleFetchMem(
        {
            call_pc: CALL_RA_INSTR,
            call_pc + 4: NOP_INSTR,
            callee: ADD_INSTR_A,
            callee + 4: ADD_INSTR_B,
        }
    )
    await _reset_dut(dut, boot_addr=call_pc, enable_bp=True)
    await _train_btb(dut, pc=call_pc, target=callee, taken=True, call=True, jump=True)
    await _redirect_fence(dut, call_pc)

    # Launch call window while PD is stalled: F0 pushes link ONCE on launch.
    _drive_pipeline_ctrl(dut, {"stall": 1})
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == callee

    # Present call window and hold PD stalled for 4 cycles: RAS count must stay 1.
    mem.present(dut, valid=1)
    await _settle()
    for cyc in range(4):
        if cyc > 0:
            _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
            await _settle()
        s1 = _read_packet(dut, slot2=False)
        assert s1["sel_nop"] is False
        assert s1["program_counter"] == call_pc
        assert s1["btb_predicted_taken"] is True
        assert s1["btb_predicted_target"] == callee
        assert s1["ras_checkpoint_valid_count"] == 0  # pre-push checkpoint
        assert _ras_state(dut) == (1, 1, call_pc + 4)
        await _step(dut)

    # Release stall: call drains cleanly and RAS still holds exactly 1 copy of link.
    _drive_pipeline_ctrl(dut, {"stall": 0})
    await _step(dut)
    assert _ras_state(dut) == (1, 1, call_pc + 4)


@cocotb.test()
async def test_slot2_stalled_call_updates_ras_once(dut: Any) -> None:
    """A trained compressed call in slot 2 pushes its link once even across a multi-cycle stall."""
    slot1_pc = BASE_PC
    slot2_pc = BASE_PC + 2
    callee = BASE_PC + 0x1400
    w0 = _word(lo=COMPRESSED_ADDIW, hi=COMPRESSED_JALR_X5)
    mem = _SimpleFetchMem(
        {
            slot1_pc: w0,
            slot1_pc + 4: NOP_INSTR,
            callee: ADD_INSTR_A,
            callee + 4: ADD_INSTR_B,
        }
    )
    await _reset_dut(dut, boot_addr=slot1_pc, enable_bp=True)
    await _train_btb(
        dut,
        pc=slot2_pc,
        target=callee,
        taken=True,
        compressed=True,
        call=True,
        jump=True,
    )
    await _redirect_fence(dut, slot1_pc)

    # Launch under stall: F0 steers to callee and pushes slot2_pc + 2 once.
    _drive_pipeline_ctrl(dut, {"stall": 1})
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == callee

    # Hold window in drain under stall for 4 cycles.
    mem.present(dut, valid=1)
    await _settle()
    for cyc in range(4):
        if cyc > 0:
            _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
            await _settle()
        s2 = _read_packet(dut, slot2=True)
        assert s2["sel_nop"] is False
        assert s2["program_counter"] == slot2_pc
        assert s2["btb_predicted_taken"] is True
        assert s2["btb_predicted_target"] == callee
        assert s2["ras_checkpoint_valid_count"] == 0
        assert _ras_state(dut) == (1, 1, slot2_pc + 2)
        await _step(dut)

    _drive_pipeline_ctrl(dut, {"stall": 0})
    await _step(dut)
    assert _ras_state(dut) == (1, 1, slot2_pc + 2)


@cocotb.test()
async def test_slot2_stalled_return_preserves_ras_target(dut: Any) -> None:
    """A trained return in slot 2 preserves its RAS target across stalls and pops once."""
    call_pc = BASE_PC
    ret_win_pc = BASE_PC + 0x1200
    ret_pc = ret_win_pc + 4
    stale_target = BASE_PC + 0x2400
    mem = _SimpleFetchMem(
        {
            call_pc: CALL_RA_INSTR,
            call_pc + 4: NOP_INSTR,
            ret_win_pc: ADD_INSTR_A,
            ret_pc: RETURN_RA_INSTR,
        }
    )
    await _reset_dut(dut, boot_addr=call_pc, enable_bp=True)
    await _train_btb(
        dut, pc=call_pc, target=ret_win_pc, taken=True, call=True, jump=True
    )
    await _train_btb(
        dut, pc=ret_pc, target=stale_target, taken=True, ret=True, jump=True
    )
    await _redirect_fence(dut, call_pc)

    # Launch call window -> pushes call_pc + 4 and steers to ret_win_pc.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == ret_win_pc

    # Present call window while launching ret_win_pc -> RAS predicts call_pc + 4 and pops once.
    mem.present(dut, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == call_pc + 4

    # Present ret_win_pc under multi-cycle stall: slot 2 keeps RAS target & pre-pop ckpt=1.
    _drive_pipeline_ctrl(dut, {"stall": 1})
    mem.present(dut, valid=1)
    await _settle()
    for cyc in range(4):
        if cyc > 0:
            _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
            await _settle()
        s2 = _read_packet(dut, slot2=True)
        assert s2["sel_nop"] is False
        assert s2["program_counter"] == ret_pc
        assert s2["btb_predicted_taken"] is True
        assert s2["btb_predicted_target"] == call_pc + 4
        assert s2["ras_checkpoint_valid_count"] == 1
        assert s2["ras_checkpoint_top"] == call_pc + 4
        assert _ras_state(dut)[:2] == (0, 0)
        await _step(dut)

    _drive_pipeline_ctrl(dut, {"stall": 0})
    await _step(dut)
    assert _ras_state(dut)[:2] == (0, 0)


@cocotb.test()
async def test_squashed_typed_call_leaves_ras_unchanged(dut: Any) -> None:
    """A redirect/flush coinciding with a trained F0 call drops its RAS push."""
    call_pc = BASE_PC
    callee = BASE_PC + 0x1000
    await _reset_dut(dut, boot_addr=call_pc, enable_bp=True)
    await _train_btb(dut, pc=call_pc, target=callee, taken=True, call=True, jump=True)

    for squash in ("pd_redirect", "flush"):
        await _redirect_fence(dut, call_pc)
        _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
        if squash == "pd_redirect":
            dut.i_pd_redirect.value = 1
            dut.i_pd_redirect_target.value = BASE_PC + 0x40
        else:
            _drive_pipeline_ctrl(dut, {"flush": 1})
        await _settle()
        assert int(dut.btb_taken_raw.value) == 1
        assert int(dut.f0_ras_push.value) == 0, squash
        await _step(dut)
        dut.i_pd_redirect.value = 0
        _drive_pipeline_ctrl(dut, {})
        _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
        await _settle()
        assert int(dut.f0_ras_push_q.value) == 0, squash
        await _step(dut)
        assert _ras_state(dut)[:2] == (0, 0), squash


@cocotb.test()
async def test_pd_redirect_ras_operation_happens_once_under_stall(dut: Any) -> None:
    """A held PD redirect pushes or pops RAS exactly once when stall releases, and flush drops it."""
    link = BASE_PC + 0x204
    await _reset_dut(dut, boot_addr=BASE_PC)

    async def drive_pd_ras(
        *, push: bool, pop: bool, cycles: int, flush: bool = False
    ) -> None:
        dut.i_pd_redirect.value = 1
        dut.i_pd_redirect_target.value = BASE_PC + 0x400
        dut.i_pd_redirect_ras_push.value = int(push)
        dut.i_pd_redirect_ras_pop.value = int(pop)
        dut.i_pd_redirect_ras_link.value = link
        for cyc in range(cycles):
            last = cyc == cycles - 1
            _drive_pipeline_ctrl(dut, {"stall": int(not last), "flush": int(flush)})
            await _settle()
            if not last or flush:
                assert int(dut.pd_ras_restore.value) == 0
            await _step(dut)
            if not last or flush:
                assert int(dut.ras_restore_q.value) == 0
        dut.i_pd_redirect.value = 0
        dut.i_pd_redirect_ras_push.value = 0
        dut.i_pd_redirect_ras_pop.value = 0
        _drive_pipeline_ctrl(dut, {})
        await _step(dut)
        await _step(dut)

    # Push held across 3 stalled cycles -> commits exactly once on release.
    await drive_pd_ras(push=True, pop=False, cycles=3)
    assert _ras_state(dut) == (1, 1, link)

    # Flush beats PD redirect -> does NOT push a second time.
    await drive_pd_ras(push=True, pop=False, cycles=1, flush=True)
    assert _ras_state(dut) == (1, 1, link)

    # Pop held across 2 stalled cycles -> pops once leaving count=0.
    # Capture PD's checkpoint first so pd_ras_ckpt_cnt_q reflects count=1.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _step(dut)
    mem = _SimpleFetchMem({int(dut.o_pc.value) - 8: ADD_INSTR_A})
    mem.pending_pc = int(dut.o_pc.value) - 8
    mem.present(dut, valid=1)
    await _step(dut)
    assert int(dut.pd_ras_ckpt_cnt_q.value) == 1

    await drive_pd_ras(push=False, pop=True, cycles=2)
    assert _ras_state(dut)[:2] == (0, 0)


@cocotb.test()
async def test_ras_restore_forwarding_non_pure_pop_and_swap(dut: Any) -> None:
    """Forwarded eff_ras_* on EX restore (+push, +swap nonempty/empty) matches u_ras next cycle."""
    ret_pc = BASE_PC + 0x1600
    link1 = BASE_PC + 0x208
    link2 = BASE_PC + 0x308
    mem = _SimpleFetchMem({ret_pc: RETURN_RA_INSTR, ret_pc + 4: NOP_INSTR})
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(
        dut, pc=ret_pc, target=FENCE_TARGET, taken=True, ret=True, jump=True
    )

    # Case 1: EX restore + push -> next cycle ras_restore_q=1 forwards eff_ras_top=link1,
    # allowing an immediate F0 return at ret_pc to predict link1 with zero bubble!
    _drive_from_ex(
        dut,
        {
            "branch_taken": 1,
            "branch_target_address": ret_pc,
            "ras_misprediction": 1,
            "ras_restore_tos": 0,
            "ras_restore_valid_count": 0,
            "ras_restore_top": 0,
            "ras_push_after_restore": 1,
            "ras_push_address_after_restore": link1,
        },
    )
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    _drive_from_ex(dut, {})
    _drive_pipeline_ctrl(dut, {})

    assert int(dut.o_pc.value) == ret_pc
    assert int(dut.ras_restore_q.value) == 1
    assert int(dut.eff_ras_nonempty.value) == 1
    assert int(dut.eff_ras_top.value) == link1
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == link1

    # Case 2: EX restore + coroutine swap (push+pop) on nonempty stack (cnt=1 -> top=link2, cnt=1).
    _drive_from_ex(
        dut,
        {
            "branch_taken": 1,
            "branch_target_address": BASE_PC,
            "ras_misprediction": 1,
            "ras_restore_tos": 1,
            "ras_restore_valid_count": 1,
            "ras_restore_top": link1,
            "ras_push_after_restore": 1,
            "ras_pop_after_restore": 1,
            "ras_push_address_after_restore": link2,
        },
    )
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    _drive_from_ex(dut, {})
    _drive_pipeline_ctrl(dut, {})
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    await _settle()
    assert int(dut.eff_ras_nonempty.value) == 1
    assert int(dut.eff_ras_cnt.value) == 1
    assert int(dut.eff_ras_top.value) == link2
    await _step(dut)
    assert _ras_state(dut) == (1, 1, link2)

    # Case 3: EX restore + swap (push+pop) on EMPTY stack (cnt=0 stays empty).
    _drive_from_ex(
        dut,
        {
            "branch_taken": 1,
            "branch_target_address": BASE_PC,
            "ras_misprediction": 1,
            "ras_restore_tos": 0,
            "ras_restore_valid_count": 0,
            "ras_restore_top": 0,
            "ras_push_after_restore": 1,
            "ras_pop_after_restore": 1,
            "ras_push_address_after_restore": link2,
        },
    )
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    _drive_from_ex(dut, {})
    _drive_pipeline_ctrl(dut, {})
    await _settle()
    assert int(dut.eff_ras_nonempty.value) == 0
    assert int(dut.eff_ras_cnt.value) == 0
    await _step(dut)
    assert _ras_state(dut)[:2] == (0, 0)


@cocotb.test()
async def test_ras_pure_pop_restore_suppresses_f0_pred_and_uses_live_ckpt(
    dut: Any,
) -> None:
    """A pure-pop RAS restore disables F0 prediction for 1 cycle and captures live u_ras ckpt."""
    link1 = BASE_PC + 0x204
    link2 = BASE_PC + 0x208
    mem = _SimpleFetchMem({BASE_PC: ADD_INSTR_A, BASE_PC + 4: ADD_INSTR_B})
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(dut, pc=BASE_PC, target=BRANCH_TARGET, taken=True)

    # Seed RAS with 2 entries: bottom=link1 (tos=1), top=link2 (tos=2).
    for tos, cnt, top, link in ((0, 0, 0, link1), (1, 1, link1, link2)):
        _drive_from_ex(
            dut,
            {
                "branch_taken": 1,
                "branch_target_address": BASE_PC,
                "ras_misprediction": 1,
                "ras_restore_tos": tos,
                "ras_restore_valid_count": cnt,
                "ras_restore_top": top,
                "ras_push_after_restore": 1,
                "ras_push_address_after_restore": link,
            },
        )
        _drive_pipeline_ctrl(dut, {"flush": 1})
        await _step(dut)
        _drive_from_ex(dut, {})
        _drive_pipeline_ctrl(dut, {})
        await _step(dut)
    assert _ras_state(dut) == (1, 2, link2)

    # Pure-pop restore from (tos=2, cnt=2, top=link2) -> next cycle count=1, top=link1.
    _drive_from_ex(
        dut,
        {
            "branch_taken": 1,
            "branch_target_address": BASE_PC,
            "ras_misprediction": 1,
            "ras_restore_tos": 2,
            "ras_restore_valid_count": 2,
            "ras_restore_top": link2,
            "ras_pop_after_restore": 1,
        },
    )
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    _drive_from_ex(dut, {})
    _drive_pipeline_ctrl(dut, {})

    # On the pure-pop commit cycle, f0_pred_en is suppressed so BTB at BASE_PC must NOT fire.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    assert int(dut.ras_restore_pure_pop_q.value) == 1
    assert int(dut.f0_pred_en.value) == 0
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 8  # sequential, NOT BRANCH_TARGET

    # Next cycle: u_ras holds (1, 1, link1) and F1's packet carries the exact live checkpoint!
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC
    assert s1["ras_checkpoint_valid_count"] == 1
    assert s1["ras_checkpoint_top"] == link1


@cocotb.test()
async def test_f1_false_btb_call_restores_ras(dut: Any) -> None:
    """A false fast-BTB call on a non-control instruction restores RAS and resteers."""
    mem = _SimpleFetchMem({BASE_PC: ADD_INSTR_A, BASE_PC + 4: ADD_INSTR_B})
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(
        dut, pc=BASE_PC, target=BRANCH_TARGET, taken=True, call=True, jump=True
    )
    await _redirect_fence(dut, BASE_PC)

    # F0 speculatively pushes BASE_PC+4 and steers to BRANCH_TARGET.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BRANCH_TARGET

    # F1 sees ADD_INSTR_A (not a control instruction): triggers false-BTB resteer & RAS restore!
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    assert s1["sel_nop"] is False and s1["btb_predicted_taken"] is False
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 8
    assert int(dut.o_fetch_redirect.value) == 1
    await _step(dut)
    assert _ras_state(dut)[:2] == (0, 0)


# -----------------------------------------------------------------------------
# Group C: Page-end fault priority, PMA faults, and faulted BTB suppression
# -----------------------------------------------------------------------------


@cocotb.test()
async def test_first_word_fault_wins_for_crossing_fetch_shapes(dut: Any) -> None:
    """At a page end, a first-word fault keeps its exact cause and fetch_fault_hi=0."""
    await _reset_dut(dut, boot_addr=BASE_PC)
    for compressed in (False, True):
        owner = (
            _word(lo=COMPRESSED_NOP, hi=COMPRESSED_NOP) if compressed else ADD_INSTR_A
        )
        for offset in (0, 2):
            pc = PAGE_END_WORD + offset
            for served_high in (0, 1):
                for page in (0, 1):
                    await _redirect_fence(dut, pc)
                    mem = _SimpleFetchMem(
                        {PAGE_END_WORD: owner, PAGE_END_WORD + 4: ADD_INSTR_B}
                    )
                    mem.faults[PAGE_END_WORD] = (1, page)
                    mem.faults[PAGE_END_WORD + 4] = (1, 1 - page)
                    await _launch_and_present(dut, mem, served_high=served_high)
                    s1 = _read_packet(dut, slot2=False)
                    s2 = _read_packet(dut, slot2=True)
                    assert s1["sel_nop"] is False
                    assert s1["program_counter"] == pc
                    assert s1["fetch_fault"] is True
                    assert s1["fetch_fault_page"] is bool(page)
                    assert s1["fetch_fault_hi"] is False
                    assert s1["btb_predicted_taken"] is False
                    assert s2["sel_nop"] is True


@cocotb.test()
async def test_buffered_first_word_fault_keeps_priority_at_page_end(dut: Any) -> None:
    """A queued straddling instruction at page end retains word-0 fault cause over clean live bus."""
    owner = _word(lo=COMPRESSED_J, hi=ADD_INSTR_A & 0xFFFF)
    await _reset_dut(dut, boot_addr=BASE_PC)
    for served_high in (0, 1):
        for page in (0, 1):
            await _redirect_fence(dut, PAGE_END_WORD)
            mem = _SimpleFetchMem(
                {PAGE_END_WORD: owner, PAGE_END_WORD + 4: ADD_INSTR_B}
            )
            mem.faults[PAGE_END_WORD] = (1, page)
            mem.faults[PAGE_END_WORD + 4] = (1, 1 - page)
            await _launch_and_present(dut, mem, served_high=served_high)

            # Cycle 1: slot 1 emits compressed parcel at 0x13FFC with word-0 fault cause.
            s1 = _read_packet(dut, slot2=False)
            assert s1["sel_nop"] is False
            assert s1["program_counter"] == PAGE_END_WORD
            assert s1["fetch_fault"] is True
            assert s1["fetch_fault_page"] is bool(page)
            assert s1["fetch_fault_hi"] is False
            assert _read_packet(dut, slot2=True)["sel_nop"] is True

            # Cycle 2: live bus is clean/invalid, queued straddling parcel at 0x13FFE drains
            # and MUST preserve word-0's fault cause with fetch_fault_hi=False!
            await _step(dut)
            _drive_window(
                dut,
                word0=ADD_INSTR_B,
                word1=ADD_INSTR_C,
                served_pc=0,
                valid=0,
                fault0=0,
                fault1=0,
            )
            await _settle()
            s1_next = _read_packet(dut, slot2=False)
            assert s1_next["sel_nop"] is False
            assert s1_next["program_counter"] == PAGE_END_WORD + 2
            assert s1_next["fetch_fault"] is True
            assert s1_next["fetch_fault_page"] is bool(page)
            assert s1_next["fetch_fault_hi"] is False


@cocotb.test()
async def test_faulting_fetch_suppresses_trained_btb_redirect(dut: Any) -> None:
    """Word-0, word-1, and spanning second-word faults suppress trained BTB & RAS ops."""
    target = BASE_PC + 0x200
    pc_s1 = BASE_PC + 0x20
    pc_s2 = pc_s1 + 4
    pc_span = BASE_PC + 0x46
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)

    for train_pc in (pc_s1, pc_s2):
        await _train_btb(dut, pc=train_pc, target=target, taken=True)
    await _train_btb(
        dut,
        pc=pc_span,
        target=target,
        taken=True,
        compressed=False,
        call=True,
        jump=True,
    )

    # 1. Word-0 fault suppresses slot-1 BTB and triggers false-BTB / fault veto.
    await _redirect_fence(dut, pc_s1)
    mem1 = _SimpleFetchMem({pc_s1: BRANCH_INSTR, pc_s2: BRANCH_INSTR})
    mem1.faults[pc_s1] = (1, 1)
    await _launch_and_present(dut, mem1)
    pkt1 = _read_packet(dut, slot2=False)
    assert pkt1["fetch_fault"] is True and pkt1["fetch_fault_page"] is True
    assert pkt1["btb_predicted_taken"] is False
    assert _read_packet(dut, slot2=True)["sel_nop"] is True

    # 2. Word-1 fault suppresses slot-2 BTB (slot 2 is deferred to slot 1 as a fault).
    await _redirect_fence(dut, pc_s1)
    mem2 = _SimpleFetchMem({pc_s1: ADD_INSTR_A, pc_s2: BRANCH_INSTR})
    mem2.faults[pc_s2] = (1, 1)
    await _launch_and_present(dut, mem2)
    assert _read_packet(dut, slot2=False)["program_counter"] == pc_s1
    assert _read_packet(dut, slot2=True)["sel_nop"] is True
    await _step(dut)
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    await _settle()
    pkt_def = _read_packet(dut, slot2=False)
    assert pkt_def["program_counter"] == pc_s2
    assert pkt_def["fetch_fault"] is True and pkt_def["btb_predicted_taken"] is False

    # 3. Spanning 32-bit call at pc_span (hw[3] of window pc_span - 6): second-word
    #    fault on span_tail sets fetch_fault_hi, clears btb_predicted_taken, and restores RAS.
    win0_pc = pc_span - 6  # 0x1040
    w0 = _word(lo=COMPRESSED_NOP, hi=COMPRESSED_NOP)
    w1 = _word(lo=COMPRESSED_NOP, hi=CALL_RA_INSTR & 0xFFFF)
    w2 = _word(lo=(CALL_RA_INSTR >> 16) & 0xFFFF, hi=COMPRESSED_NOP)
    mem3 = _SimpleFetchMem({win0_pc: w0, win0_pc + 4: w1, win0_pc + 8: w2})
    mem3.faults[win0_pc + 8] = (1, 1)
    await _redirect_fence(dut, win0_pc)

    # Launch win0_pc (spanning call at hw[3] steps sequentially to win0_pc + 8).
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem3.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == win0_pc + 8

    # Present win0_pc and launch span_tail (win0_pc + 8) which pushes RAS speculatively.
    mem3.present(dut, valid=1)
    await _settle()
    mem3.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == target

    # Drain compressed pair at win0_pc + 4 while span_tail arrives with fault0=1!
    mem3.present(dut, valid=1)
    await _settle()
    await _step(dut)

    # Next cycle: spanning call at pc_span drains with fetch_fault_hi=True, taken=False,
    # and RAS is restored back to empty!
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    await _settle()
    pkt_span = _read_packet(dut, slot2=False)
    assert pkt_span["sel_nop"] is False and pkt_span["program_counter"] == pc_span
    assert pkt_span["fetch_fault"] is True and pkt_span["fetch_fault_hi"] is True
    assert pkt_span["fetch_fault_page"] is True
    assert pkt_span["btb_predicted_taken"] is False
    await _step(dut)
    assert _ras_state(dut)[:2] == (0, 0)


@cocotb.test()
async def test_slot2_fault_suppresses_trained_call_and_defers_to_slot1(
    dut: Any,
) -> None:
    """A faulting slot-2 trained call neither redirects nor pushes RAS and defers to slot 1."""
    pc_s1 = BASE_PC + 0x60
    pc_s2 = pc_s1 + 4
    target = BASE_PC + 0x260
    await _reset_dut(dut, boot_addr=pc_s1, enable_bp=True)
    await _train_btb(dut, pc=pc_s2, target=target, taken=True, call=True, jump=True)
    await _redirect_fence(dut, pc_s1)

    mem = _SimpleFetchMem({pc_s1: ADD_INSTR_A, pc_s2: CALL_RA_INSTR})
    mem.faults[pc_s2] = (1, 1)
    await _launch_and_present(dut, mem)

    # F1 sees word-1 fault on the predicted slot-2 call -> cancels BTB & restores RAS!
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == pc_s1
    assert s1["fetch_fault"] is False
    assert s2["sel_nop"] is True and s2["fetch_fault"] is False
    await _step(dut)
    assert int(dut.o_pc.value) == pc_s1 + 8  # resteered away from target!

    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    await _settle()
    s1_next = _read_packet(dut, slot2=False)
    assert s1_next["program_counter"] == pc_s2
    assert s1_next["fetch_fault"] is True and s1_next["btb_predicted_taken"] is False
    await _step(dut)
    assert _ras_state(dut)[:2] == (0, 0)


@cocotb.test()
async def test_bare_pma_bad_fetch_asserts_fault_and_blocks_btb(dut: Any) -> None:
    """A Bare-mode fetch outside executable PMA asserts o_fetch_fault0, blocks BTB, and faults."""
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(dut, pc=UNMAPPED_BARE_PC, target=BRANCH_TARGET, taken=True)
    await _redirect_fence(dut, UNMAPPED_BARE_PC)

    assert int(dut.o_pc.value) == UNMAPPED_BARE_PC
    assert int(dut.o_fetch_pa_valid.value) == 1
    assert int(dut.o_fetch_fault0.value) == 1
    assert int(dut.o_fetch_fault0_page.value) == 0
    assert int(dut.f0_pred_en.value) == 0

    # Launch with real IMMU fault outputs fed back into the window.
    f0 = int(dut.o_fetch_fault0.value)
    f1 = int(dut.o_fetch_fault1.value)
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _step(dut)
    assert int(dut.o_pc.value) == UNMAPPED_BARE_PC + 8  # BTB blocked by PMA fault

    _drive_window(
        dut,
        word0=BRANCH_INSTR,
        word1=NOP_INSTR,
        served_pc=UNMAPPED_BARE_PC,
        valid=1,
        fault0=f0,
        fault1=f1,
    )
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    assert s1["sel_nop"] is False
    assert s1["program_counter"] == UNMAPPED_BARE_PC
    assert s1["fetch_fault"] is True
    assert s1["fetch_fault_page"] is False
    assert s1["btb_predicted_taken"] is False


@cocotb.test()
async def test_fetch_fault_with_arbitrary_metadata_preserves_fault_tags(
    dut: Any,
) -> None:
    """Faulting windows preserve fault tags and suppress prediction with arbitrary metadata."""
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(dut, pc=BASE_PC, target=BRANCH_TARGET, taken=True)
    await _redirect_fence(dut, BASE_PC)

    mem = _SimpleFetchMem({BASE_PC: ADD_INSTR_A, BASE_PC + 4: ADD_INSTR_B})
    mem.faults[BASE_PC] = (1, 0)
    mem.faults[BASE_PC + 4] = (1, 0)
    await _launch_and_present(dut, mem)
    dut.i_instr_pc_metadata.value = 0xFF
    dut.i_instr_pc_metadata_by_provider_parity.value = 0xFFFF
    dut.i_pc_pairability_by_provider_parity.value = 0xFF
    dut.i_slot2_start_valid_lo_by_provider_parity.value = 0xF
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["fetch_fault"] is True and s1["fetch_fault_page"] is False
    assert s1["btb_predicted_taken"] is False
    assert s2["sel_nop"] is True


# -----------------------------------------------------------------------------
# Group D: Provider retarget pulses (o_fetch_redirect / o_fetch_cached_retarget)
# -----------------------------------------------------------------------------


@cocotb.test()
async def test_trap_mret_fence_ex_and_pd_redirect_pulse_both_retargets(
    dut: Any,
) -> None:
    """Every architectural/EX/PD redirect pulses both provider retargets for 1 cycle."""
    await _reset_dut(dut, boot_addr=BASE_PC)
    assert int(dut.o_fetch_redirect.value) == 0
    assert int(dut.o_fetch_cached_retarget.value) == 0

    # 1. Trap redirect
    _drive_trap_ctrl(dut, {"trap_taken": 1, "trap_target": TRAP_TARGET})
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    _drive_trap_ctrl(dut, {})
    _drive_pipeline_ctrl(dut, {})
    assert int(dut.o_pc.value) == TRAP_TARGET
    assert int(dut.o_fetch_redirect.value) == 1
    assert int(dut.o_fetch_cached_retarget.value) == 1
    await _step(dut)
    assert int(dut.o_fetch_redirect.value) == 0
    assert int(dut.o_fetch_cached_retarget.value) == 0

    # 2. MRET redirect
    _drive_trap_ctrl(dut, {"mret_taken": 1, "trap_target": BASE_PC + 0x100})
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    _drive_trap_ctrl(dut, {})
    _drive_pipeline_ctrl(dut, {})
    assert int(dut.o_pc.value) == BASE_PC + 0x100
    assert int(dut.o_fetch_redirect.value) == 1
    assert int(dut.o_fetch_cached_retarget.value) == 1
    await _step(dut)
    assert int(dut.o_fetch_redirect.value) == 0
    assert int(dut.o_fetch_cached_retarget.value) == 0

    # 3. FENCE.I redirect
    dut.i_fence_i_flush.value = 1
    dut.i_fence_i_target.value = FENCE_TARGET
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    dut.i_fence_i_flush.value = 0
    _drive_pipeline_ctrl(dut, {})
    assert int(dut.o_pc.value) == FENCE_TARGET
    assert int(dut.o_fetch_redirect.value) == 1
    assert int(dut.o_fetch_cached_retarget.value) == 1
    await _step(dut)
    assert int(dut.o_fetch_redirect.value) == 0
    assert int(dut.o_fetch_cached_retarget.value) == 0

    # 4. EX branch redirect
    _drive_from_ex(dut, {"branch_taken": 1, "branch_target_address": BRANCH_TARGET})
    _drive_pipeline_ctrl(dut, {"flush": 1})
    await _step(dut)
    _drive_from_ex(dut, {})
    _drive_pipeline_ctrl(dut, {})
    assert int(dut.o_pc.value) == BRANCH_TARGET
    assert int(dut.o_fetch_redirect.value) == 1
    assert int(dut.o_fetch_cached_retarget.value) == 1
    await _step(dut)
    assert int(dut.o_fetch_redirect.value) == 0
    assert int(dut.o_fetch_cached_retarget.value) == 0

    # 5. Stalled PD redirect must NOT pulse; unstalled PD redirect MUST pulse.
    dut.i_pd_redirect.value = 1
    dut.i_pd_redirect_target.value = PD_TARGET
    _drive_pipeline_ctrl(dut, {"stall": 1})
    await _step(dut)
    assert int(dut.o_fetch_redirect.value) == 0
    assert int(dut.o_fetch_cached_retarget.value) == 0

    _drive_pipeline_ctrl(dut, {"stall": 0})
    await _step(dut)
    dut.i_pd_redirect.value = 0
    assert int(dut.o_pc.value) == PD_TARGET
    assert int(dut.o_fetch_redirect.value) == 1
    assert int(dut.o_fetch_cached_retarget.value) == 1
    await _step(dut)
    assert int(dut.o_fetch_redirect.value) == 0
    assert int(dut.o_fetch_cached_retarget.value) == 0


@cocotb.test()
async def test_normal_f0_btb_and_sequential_fetch_do_not_pulse_retarget(
    dut: Any,
) -> None:
    """Normal sequential fetch and valid F0 BTB steering keep provider retarget pulses low."""
    mem = _SimpleFetchMem(
        {
            BASE_PC: ADD_INSTR_A,
            BASE_PC + 4: ADD_INSTR_B,
            BASE_PC + 8: BRANCH_INSTR,
            BASE_PC + 12: NOP_INSTR,
            BRANCH_TARGET: ADD_INSTR_C,
            BRANCH_TARGET + 4: ADD_INSTR_D,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(dut, pc=BASE_PC + 8, target=BRANCH_TARGET, taken=True)
    await _redirect_fence(dut, BASE_PC)

    # Sequential F0 launch at BASE_PC -> BASE_PC + 8: no retarget pulse.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 8
    assert int(dut.o_fetch_redirect.value) == 0
    assert int(dut.o_fetch_cached_retarget.value) == 0

    # Valid F0 BTB steer at BASE_PC + 8 -> BRANCH_TARGET: no retarget pulse.
    mem.present(dut, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BRANCH_TARGET
    assert int(dut.o_fetch_redirect.value) == 0
    assert int(dut.o_fetch_cached_retarget.value) == 0

    # Target arrives cleanly, still no retarget pulse.
    mem.present(dut, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_fetch_redirect.value) == 0
    assert int(dut.o_fetch_cached_retarget.value) == 0


# -----------------------------------------------------------------------------
# Group E: Additional restored front-end-independent & decoupled contracts
# -----------------------------------------------------------------------------


@cocotb.test()
async def test_fetch_invalid_bubbles_holds_pc_and_resumes_compressed_pair(
    dut: Any,
) -> None:
    """Invalid fetch cycles emit NOPs when empty, hold PC, and resume with a compressed pair."""
    w0 = _word(lo=COMPRESSED_NOP, hi=COMPRESSED_ADDIW)
    mem = _SimpleFetchMem({BASE_PC: w0, BASE_PC + 4: ADD_INSTR_A})
    await _reset_dut(dut, boot_addr=BASE_PC)

    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    for _ in range(3):
        await _step(dut)
        assert int(dut.o_pc.value) == BASE_PC
        assert _read_packet(dut, slot2=False)["sel_nop"] is True
        assert _read_packet(dut, slot2=True)["sel_nop"] is True

    mem.pending_pc = BASE_PC
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC
    assert s1["sel_compressed"] is True and s1["raw_parcel"] == COMPRESSED_NOP
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 2
    assert s2["sel_compressed"] is True and s2["raw_parcel"] == COMPRESSED_ADDIW
    assert s2["effective_instr"] == COMPRESSED_ADDIW_EXPANDED


@cocotb.test()
async def test_redirect_during_backing_read_discards_stale_backing_reads(
    dut: Any,
) -> None:
    """Back-to-back redirects discard in-flight and held backing_btb reads."""
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    backing = dut.u_backing_btb

    # Wait for backing_btb's 512-set reset clear sweep to finish without triggering
    # tag-mismatch resteers, then run two clean cycles so held_valid_q populates.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    for _ in range(600):
        if (
            int(backing.sweep_active.value) == 0
            and int(backing.held_valid_q.value) == 1
        ):
            break
        await _step(dut)
    assert int(backing.held_valid_q.value) == 1

    for offset in (0x100, 0x200):
        _drive_from_ex(
            dut, {"branch_taken": 1, "branch_target_address": BASE_PC + offset}
        )
        _drive_pipeline_ctrl(dut, {"flush": 1})
        await _step(dut)
        assert int(dut.o_pc.value) == BASE_PC + offset

    assert int(backing.held_valid_q.value) == 0
    assert int(backing.request_valid_q.value) == 0
    _drive_from_ex(dut, {})
    _drive_pipeline_ctrl(dut, {})
    await _step(dut)
    assert int(backing.request_valid_q.value) == 1


@cocotb.test()
async def test_high_half_target_ignores_preceding_low_half_btb_entry(
    dut: Any,
) -> None:
    """Entering an aligned word at PC+2 ignores a trained fast-BTB entry at PC+0."""
    target_odd = BASE_PC + 2
    w0 = _word(lo=COMPRESSED_J, hi=COMPRESSED_ADDIW)
    mem = _SimpleFetchMem(
        {
            BASE_PC: w0,
            BASE_PC + 4: ADD_INSTR_A,
            BASE_PC + 8: ADD_INSTR_B,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(dut, pc=BASE_PC, target=BRANCH_TARGET, taken=True, compressed=True)
    await _redirect_fence(dut, target_odd)

    # F0 at BASE_PC + 2 must NOT take the low-halfword BTB entry at BASE_PC + 0!
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 8

    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == target_odd
    assert s1["raw_parcel"] == COMPRESSED_ADDIW
    assert s1["btb_predicted_taken"] is False
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 4
    assert s2["effective_instr"] == ADD_INSTR_A


@cocotb.test()
async def test_flushed_interior_halfword_entry_delivers_native_unchanged(
    dut: Any,
) -> None:
    """A trained BTB entry inside a native 32-bit instruction is suppressed after flush."""
    # Native 32-bit ADD_INSTR_A at BASE_PC; stale BTB entry trained at BASE_PC + 2 (native).
    mem = _SimpleFetchMem(
        {BASE_PC: ADD_INSTR_A, BASE_PC + 4: ADD_INSTR_B, BASE_PC + 8: ADD_INSTR_C}
    )
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    await _train_btb(
        dut, pc=BASE_PC + 2, target=BRANCH_TARGET, taken=True, compressed=False
    )
    await _redirect_fence(dut, BASE_PC)

    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BRANCH_TARGET  # speculative F0 hit

    # F1 detects interior halfword -> delivers ADD_INSTR_A & ADD_INSTR_B unchanged, resteers!
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC
    assert s1["effective_instr"] == ADD_INSTR_A and s1["btb_predicted_taken"] is False
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 4
    assert s2["effective_instr"] == ADD_INSTR_B and s2["btb_predicted_taken"] is False
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 8


@cocotb.test()
async def test_slot1_control_classification_and_indirect_taps(dut: Any) -> None:
    """o_slot1_has_control_flow and o_slot1_is_indirect classify every control opcode exactly."""
    cases = [
        (ADD_INSTR_A, False, False),
        (BRANCH_INSTR, True, False),
        (JAL_X0_INSTR, True, False),
        (CALL_RA_INSTR, True, False),
        (JALR_X0_X5_INSTR, True, True),
        (JALR_SWAP_RA_INSTR, True, True),
        (_word(lo=COMPRESSED_NOP, hi=COMPRESSED_NOP), False, False),
        (_word(lo=COMPRESSED_J, hi=COMPRESSED_NOP), True, False),
        (_word(lo=COMPRESSED_BEQZ, hi=COMPRESSED_NOP), True, False),
        (_word(lo=COMPRESSED_JR_X5, hi=COMPRESSED_NOP), True, True),
        (_word(lo=COMPRESSED_JALR_X5, hi=COMPRESSED_NOP), True, True),
        (_word(lo=COMPRESSED_JR_RA, hi=COMPRESSED_NOP), True, True),
    ]
    await _reset_dut(dut, boot_addr=BASE_PC)
    for idx, (word0, want_ctrl, want_ind) in enumerate(cases):
        pc = BASE_PC + 0x100 + 8 * idx
        await _redirect_fence(dut, pc)
        mem = _SimpleFetchMem({pc: word0, pc + 4: NOP_INSTR})
        await _launch_and_present(dut, mem)
        s1 = _read_packet(dut, slot2=False)
        assert s1["sel_nop"] is False and s1["program_counter"] == pc
        assert bool(int(dut.o_slot1_has_control_flow.value)) is want_ctrl, hex(word0)
        assert bool(int(dut.o_slot1_is_indirect.value)) is want_ind, hex(word0)
        # Control-flow slot 1 must never pair a slot 2.
        if want_ctrl:
            assert _read_packet(dut, slot2=True)["sel_nop"] is True, hex(word0)


@cocotb.test()
async def test_parcel_queue_wraparound_and_headroom_stress(dut: Any) -> None:
    """Streaming mixed 16b/32b/spanning windows across stalls wraps the queue with zero loss."""
    # Build a 12-window stream of compressed + native + spanning instructions.
    stream_instrs: list[tuple[int, int, bool]] = []
    halfwords: list[int] = []
    pc_cur = BASE_PC
    pattern = [
        (COMPRESSED_NOP, True),
        (ADD_INSTR_A, False),
        (COMPRESSED_ADDIW, True),
        (ADD_INSTR_B, False),
        (ADD_INSTR_C, False),
        (COMPRESSED_NOP, True),
        (ADD_INSTR_D, False),
        (COMPRESSED_ADDIW, True),
    ]
    for rep in range(4):
        for val, comp in pattern:
            stream_instrs.append((pc_cur, val, comp))
            if comp:
                halfwords.append(val & 0xFFFF)
                pc_cur += 2
            else:
                halfwords.append(val & 0xFFFF)
                halfwords.append((val >> 16) & 0xFFFF)
                pc_cur += 4
    while len(halfwords) % 4 != 0:
        halfwords.append(COMPRESSED_NOP)

    words: dict[int, int] = {}
    for w_idx in range(len(halfwords) // 2):
        words[BASE_PC + 4 * w_idx] = _word(
            lo=halfwords[2 * w_idx], hi=halfwords[2 * w_idx + 1]
        )
    mem = _SimpleFetchMem(words)
    await _reset_dut(dut, boot_addr=BASE_PC)

    # Initial F0 launch.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)

    observed: list[tuple[int, int, bool]] = []
    saw_stop = False
    end_addr = BASE_PC + 4 * len(words)
    stall_schedule = [1, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0]
    for cyc in range(64):
        stall = stall_schedule[cyc] if cyc < len(stall_schedule) else 0
        _drive_pipeline_ctrl(dut, {"stall": stall})
        # Model a 1-cycle synchronous memory: present the previously launched
        # window if one is in flight, or stay valid=1 to allow new F0 launches.
        if mem.pending_pc is not None and mem.pending_pc < end_addr:
            mem.present(dut, valid=1)
        elif int(dut.o_pc.value) < end_addr:
            _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
        else:
            _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
        await _settle()
        if int(dut.u_parcel_queue.o_stop_fetch.value) == 1:
            saw_stop = True
        if not stall:
            for slot2 in (False, True):
                pkt = _read_packet(dut, slot2=slot2)
                if not pkt["sel_nop"]:
                    val = (
                        pkt["raw_parcel"]
                        if pkt["sel_compressed"]
                        else pkt["effective_instr"]
                    )
                    observed.append(
                        (pkt["program_counter"], val, pkt["sel_compressed"])
                    )
        if int(dut.f0_launch.value) == 1:
            mem.capture_request(dut)
        elif int(dut.f1_accept.value) == 1 or int(dut.f1_collapsed_accept.value) == 1:
            mem.pending_pc = None
        await _step(dut)
        if len(observed) >= len(stream_instrs):
            break

    assert saw_stop, "stress pattern must exercise parcel-queue stop_fetch headroom"
    assert observed[: len(stream_instrs)] == stream_instrs


@cocotb.test()
async def test_fetch_trap_hold_pauses_drain_and_resumes_without_loss(dut: Any) -> None:
    """Asserting i_fetch_trap_hold bubbles drain and pauses F0, then resumes buffered stream."""
    mem = _SimpleFetchMem(
        {
            BASE_PC: _word(lo=COMPRESSED_ADDIW, hi=COMPRESSED_NOP),
            BASE_PC + 4: _word(lo=COMPRESSED_ADDIW, hi=COMPRESSED_NOP),
            BASE_PC + 8: ADD_INSTR_A,
            BASE_PC + 12: ADD_INSTR_B,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC)

    # Launch window 0 and let slots 1+2 (BASE_PC, BASE_PC+2) drain while BASE_PC+4,+6 queue.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)

    mem.present(dut, valid=1)
    await _settle()
    assert _read_packet(dut, slot2=False)["program_counter"] == BASE_PC
    assert _read_packet(dut, slot2=True)["program_counter"] == BASE_PC + 2
    mem.capture_request(dut)
    await _step(dut)

    # Assert i_fetch_trap_hold for 3 cycles: drain bubbles and F0 holds o_pc.
    held_pc = int(dut.o_pc.value)
    dut.i_fetch_trap_hold.value = 1
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=0)
    for _ in range(3):
        await _settle()
        assert _read_packet(dut, slot2=False)["sel_nop"] is True
        assert _read_packet(dut, slot2=True)["sel_nop"] is True
        await _step(dut)
        assert int(dut.o_pc.value) == held_pc

    # Drop i_fetch_trap_hold: buffered BASE_PC+4 and BASE_PC+6 resume intact!
    dut.i_fetch_trap_hold.value = 0
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC + 4
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 6


@cocotb.test()
async def test_tage_and_ittage_cross_window_slot2_metadata(dut: Any) -> None:
    """When slot 2 crosses into the next window, drain selects meta1 for TAGE/ITTAGE."""
    # Window 0: [0]=C.NOP, [1]=C.NOP, [2]=C.NOP, [3]=C.ADDIW (leaves 1 parcel in queue!)
    # Window 1: [0..1]=BRANCH_INSTR (slot 2 paired with window 0's hw[3]!)
    w0 = _word(lo=COMPRESSED_NOP, hi=COMPRESSED_NOP)
    w1 = _word(lo=COMPRESSED_NOP, hi=COMPRESSED_ADDIW)
    mem = _SimpleFetchMem(
        {
            BASE_PC: w0,
            BASE_PC + 4: w1,
            BASE_PC + 8: BRANCH_INSTR,
            BASE_PC + 12: NOP_INSTR,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)

    # Launch window 0 with hist=0x1111, then window 1 with hist=0x2222.
    dut.i_itt_hist.value = 0x1111
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)

    # Window 0 arrives: emits hw[0], hw[1], leaving hw[2], hw[3] queued; launches window 1.
    dut.i_itt_hist.value = 0x2222
    mem.present(dut, valid=1)
    await _settle()
    assert _read_packet(dut, slot2=False)["program_counter"] == BASE_PC
    assert _read_packet(dut, slot2=True)["program_counter"] == BASE_PC + 2
    mem.capture_request(dut)
    await _step(dut)

    # Stall 1 cycle while window 1 pushes into the queue (so hw[2], hw[3] are in ring,
    # followed by window 1 parcels in ring).
    _drive_pipeline_ctrl(dut, {"stall": 1})
    mem.present(dut, valid=1)
    await _step(dut)

    # Release stall: pop hw[2] (BASE_PC+4) + hw[3] (BASE_PC+6) OR force single-slot pop:
    # Actually hw[2]=C.NOP pairs with hw[3]=C.ADDIW; instead test cross-window pairing by
    # shifting window 0 to [0]=C.NOP, [1..2]=ADD_INSTR_A, [3]=C.ADDIW!
    w0_cw = _word(lo=COMPRESSED_NOP, hi=ADD_INSTR_A & 0xFFFF)
    w1_cw = _word(lo=(ADD_INSTR_A >> 16) & 0xFFFF, hi=COMPRESSED_ADDIW)
    mem_cw = _SimpleFetchMem(
        {
            BASE_PC: w0_cw,
            BASE_PC + 4: w1_cw,
            BASE_PC + 8: BRANCH_INSTR,
            BASE_PC + 12: NOP_INSTR,
        }
    )
    _drive_pipeline_ctrl(dut, {"stall": 0})
    await _redirect_fence(dut, BASE_PC)

    dut.i_itt_hist.value = 0x1234
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem_cw.capture_request(dut)
    await _step(dut)

    # Window 0 arrives -> emits BASE_PC (C.NOP) + BASE_PC+2 (ADD_INSTR_A), leaving hw[3]
    # (C.ADDIW at BASE_PC+6) as the single remaining parcel of window 0!
    dut.i_itt_hist.value = 0x5678
    mem_cw.present(dut, valid=1)
    await _settle()
    assert _read_packet(dut, slot2=False)["program_counter"] == BASE_PC
    assert _read_packet(dut, slot2=True)["program_counter"] == BASE_PC + 2
    mem_cw.capture_request(dut)
    await _step(dut)

    # Window 1 arrives -> slot 1 = C.ADDIW (BASE_PC+6, window 0), slot 2 = BRANCH_INSTR
    # (BASE_PC+8, window 1)! s2_uses_meta1 MUST be 1 and o_tage_lookup_hist MUST carry 0x5678!
    mem_cw.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC + 6
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 8
    assert s2["is_cond_branch"] is True
    assert int(dut.s2_uses_meta1.value) == 1
    assert int(dut.o_tage_slot_valid.value) == 0b11
    assert int(dut.o_tage_lookup_hist.value) == 0x5678


@cocotb.test()
async def test_pd_split_target_candidates_slot1_and_slot2(dut: Any) -> None:
    """Native and compressed PD split-target sums match exact PC + imm in both slots."""
    # beq x0, x0, +24 (imm=24 -> 0x00000C63); c.beqz x8, -8 (imm=-8 -> 0xDC65)
    beq_plus24 = 0x00000C63
    cbeqz_minus8 = 0xDC65
    # Place slot 1 at 0x1FF8 so slot 2 (0x1FFC) + 24 carries across bit 13 (PdTargetSplit=13)!
    pc_carry = 0x0000_1FF8
    mem = _SimpleFetchMem(
        {
            pc_carry: ADD_INSTR_A,
            pc_carry + 4: beq_plus24,
            BASE_PC: _word(lo=COMPRESSED_ADDIW, hi=cbeqz_minus8),
            BASE_PC + 4: NOP_INSTR,
        }
    )
    await _reset_dut(dut, boot_addr=pc_carry)
    await _launch_and_present(dut, mem)
    s2 = _read_packet(dut, slot2=True)
    assert s2["sel_nop"] is False and s2["program_counter"] == pc_carry + 4
    assert s2["is_cond_branch"] is True
    # Reconstruct full native target from split low + high_select:
    # high_select = {sign, carry}; upper = pc[XLEN-1:13] + (carry - sign).
    split = 13
    mask = (1 << split) - 1
    s2_pc = s2["program_counter"]
    hi_sel = s2["pd_target_native_high_select"]
    sign = (hi_sel >> 1) & 1
    carry = hi_sel & 1
    rebuilt_nat = (((s2_pc >> split) + carry - sign) << split) | (
        s2["pd_target_native_low"] & mask
    )
    assert rebuilt_nat == s2_pc + 24

    # Compressed negative branch in slot 2 at BASE_PC + 2 with offset -8.
    await _redirect_fence(dut, BASE_PC)
    await _launch_and_present(dut, mem)
    s2_c = _read_packet(dut, slot2=True)
    assert s2_c["sel_nop"] is False and s2_c["program_counter"] == BASE_PC + 2
    assert s2_c["sel_compressed"] is True and s2_c["is_cond_branch"] is True
    hi_sel_c = s2_c["pd_target_compressed_high_select"]
    sign_c = (hi_sel_c >> 1) & 1
    carry_c = hi_sel_c & 1
    rebuilt_cmp = (((s2_c["program_counter"] >> split) + carry_c - sign_c) << split) | (
        s2_c["pd_target_compressed_low"] & mask
    )
    assert rebuilt_cmp == s2_c["program_counter"] - 8


@cocotb.test()
async def test_bimodal_dir_predictor_updates_and_exposes_bp_dir_taken(
    dut: Any,
) -> None:
    """Direction-predictor updates propagate to o_from_if_to_pd.bp_dir_taken and bp_dir_idx."""
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    idx_mask = (1 << len(dut.i_dir_update_idx)) - 1
    dir_idx = (BASE_PC >> 1) & idx_mask

    # Saturate taken (4 updates) and verify bp_dir_taken=True on emitted slot 1.
    for _ in range(4):
        dut.i_dir_update_valid.value = 1
        dut.i_dir_update_idx.value = dir_idx
        dut.i_dir_update_taken.value = 1
        await _step(dut)
    dut.i_dir_update_valid.value = 0

    mem = _SimpleFetchMem({BASE_PC: BRANCH_INSTR, BASE_PC + 4: NOP_INSTR})
    await _redirect_fence(dut, BASE_PC)
    await _launch_and_present(dut, mem)
    s1 = _read_packet(dut, slot2=False)
    assert s1["program_counter"] == BASE_PC
    assert s1["bp_dir_idx"] == dir_idx
    assert s1["bp_dir_taken"] is True

    # Saturate not-taken (4 updates) and verify bp_dir_taken=False.
    for _ in range(4):
        dut.i_dir_update_valid.value = 1
        dut.i_dir_update_idx.value = dir_idx
        dut.i_dir_update_taken.value = 0
        await _step(dut)
    dut.i_dir_update_valid.value = 0

    await _redirect_fence(dut, BASE_PC)
    await _launch_and_present(dut, mem)
    s1_nt = _read_packet(dut, slot2=False)
    assert s1_nt["program_counter"] == BASE_PC
    assert s1_nt["bp_dir_taken"] is False


@cocotb.test()
async def test_backing_btb_refresh_preserves_trained_jump_entry(dut: Any) -> None:
    """i_pd_backing_refresh updates replacement without clobbering a trained jump entry."""
    mem = _SimpleFetchMem({BASE_PC: ADD_INSTR_A, BASE_PC + 4: CALL_RA_INSTR})
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)
    for _ in range(520):
        await _step(dut)

    await _train_btb(
        dut,
        pc=BASE_PC + 4,
        target=BRANCH_TARGET,
        taken=True,
        call=True,
        jump=True,
        repeats=1,
    )
    for _ in range(4):
        await _step(dut)

    # Pulse i_pd_backing_refresh for BASE_PC + 4, then invalidate fast BTB.
    dut.i_pd_backing_refresh.value = 1
    dut.i_pd_backing_refresh_pc.value = BASE_PC + 4
    await _step(dut)
    dut.i_pd_backing_refresh.value = 0
    for _ in range(4):
        await _step(dut)

    dut.i_btb_invalidate.value = 1
    await _step(dut)
    dut.i_btb_invalidate.value = 0
    for _ in range(4):
        await _step(dut)

    await _redirect_fence(dut, BASE_PC)
    await _launch_and_present(dut, mem)
    assert (int(dut.o_backing_hit.value) >> 1) & 1 == 1
    backing_tgt = int(dut.o_backing_target.value)
    tgt_bits = len(dut.o_backing_target) // 2
    s2_tgt = ((backing_tgt >> tgt_bits) & ((1 << tgt_bits) - 1)) << 1
    assert s2_tgt == BRANCH_TARGET


@cocotb.test()
async def test_width_funnel_events_report_deliver_and_kills(dut: Any) -> None:
    """Registered o_width_events accurately counts 2-wide delivery and slot-2 kill causes."""
    await _reset_dut(dut, boot_addr=BASE_PC)

    # 1. Two-wide native pair -> deliver1=1, deliver2=1.
    mem1 = _SimpleFetchMem({BASE_PC: ADD_INSTR_A, BASE_PC + 4: ADD_INSTR_B})
    await _launch_and_present(dut, mem1)
    await _step(dut)
    ev1 = int(dut.o_width_events.value)
    assert ev1 != 0  # deliver1 & deliver2 asserted
    assert int(dut.width_events_q.value) == ev1
    # Check fields via registered width_events_q bit positions:
    # struct packed order (MSB..LSB): deliver1, deliver2, kill_s1_native_ctrl,
    # kill_s1_native_serialize, kill_slot1_ctrl, kill_class, kill_window_limit,
    # kill_transient, slot2_pred_taken.
    assert (ev1 >> 8) & 1 == 1  # deliver1
    assert (ev1 >> 7) & 1 == 1  # deliver2

    # 2. Native control in slot 1 -> deliver1=1, deliver2=0, kill_s1_native_ctrl=1.
    await _redirect_fence(dut, BASE_PC)
    mem2 = _SimpleFetchMem({BASE_PC: BRANCH_INSTR, BASE_PC + 4: ADD_INSTR_B})
    await _launch_and_present(dut, mem2)
    await _step(dut)
    ev2 = int(dut.o_width_events.value)
    assert (ev2 >> 8) & 1 == 1  # deliver1
    assert (ev2 >> 7) & 1 == 0  # deliver2
    assert (ev2 >> 6) & 1 == 1  # kill_s1_native_ctrl

    # 3. Compressed control in slot 1 -> deliver1=1, deliver2=0, kill_slot1_ctrl=1.
    await _redirect_fence(dut, BASE_PC)
    mem3 = _SimpleFetchMem(
        {BASE_PC: _word(lo=COMPRESSED_J, hi=COMPRESSED_NOP), BASE_PC + 4: NOP_INSTR}
    )
    await _launch_and_present(dut, mem3)
    await _step(dut)
    ev3 = int(dut.o_width_events.value)
    assert (ev3 >> 8) & 1 == 1  # deliver1
    assert (ev3 >> 7) & 1 == 0  # deliver2
    assert (ev3 >> 4) & 1 == 1  # kill_slot1_ctrl

    # 4. Fault in word 0 -> deliver1=1, deliver2=0, kill_transient=1.
    await _redirect_fence(dut, BASE_PC)
    mem4 = _SimpleFetchMem({BASE_PC: ADD_INSTR_A, BASE_PC + 4: ADD_INSTR_B})
    mem4.faults[BASE_PC] = (1, 1)
    await _launch_and_present(dut, mem4)
    await _step(dut)
    ev4 = int(dut.o_width_events.value)
    assert (ev4 >> 8) & 1 == 1  # deliver1
    assert (ev4 >> 7) & 1 == 0  # deliver2
    assert (ev4 >> 1) & 1 == 1  # kill_transient


@cocotb.test()
async def test_odd_halfword_redirect_spanning_into_next_window(dut: Any) -> None:
    """Redirecting to PC+2 with a spanning 32-bit instruction at hw[3] assembles cleanly."""
    # Window 0 (start at BASE_PC + 2): hw[1..2]=ADD_INSTR_A, hw[3]=ADD_INSTR_B[15:0]
    # Window 1 (BASE_PC + 8): hw[0]=ADD_INSTR_B[31:16], hw[1]=COMPRESSED_ADDIW
    w0 = _word(lo=COMPRESSED_NOP, hi=ADD_INSTR_A & 0xFFFF)
    w1 = _word(lo=(ADD_INSTR_A >> 16) & 0xFFFF, hi=ADD_INSTR_B & 0xFFFF)
    w2 = _word(lo=(ADD_INSTR_B >> 16) & 0xFFFF, hi=COMPRESSED_ADDIW)
    mem = _SimpleFetchMem(
        {BASE_PC: w0, BASE_PC + 4: w1, BASE_PC + 8: w2, BASE_PC + 12: NOP_INSTR}
    )
    await _reset_dut(dut, boot_addr=BASE_PC)
    await _redirect_fence(dut, BASE_PC + 2)
    assert int(dut.o_pc.value) == BASE_PC + 2

    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 8

    # Cycle 1: emits ADD_INSTR_A at BASE_PC+2, leaves hw[3] (ADD_INSTR_B[15:0]) queued.
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC + 2
    assert s1["effective_instr"] == ADD_INSTR_A
    assert s2["sel_nop"] is True
    mem.capture_request(dut)
    await _step(dut)

    # Cycle 2: window 1 arrives -> partial bypass stitches ADD_INSTR_B at BASE_PC+6 and
    # pairs COMPRESSED_ADDIW at BASE_PC+10!
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC + 6
    assert s1["effective_instr"] == ADD_INSTR_B
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 10
    assert s2["effective_instr"] == COMPRESSED_ADDIW_EXPANDED


@cocotb.test()
async def test_tag_resteer_preserves_carry_hi_for_spanning_instruction(
    dut: Any,
) -> None:
    """A tag-mismatch resteer on window 1 preserves f1_carry_hi_q so hw[3] still stitches."""
    w0 = _word(lo=COMPRESSED_NOP, hi=ADD_INSTR_A & 0xFFFF)
    w1 = _word(lo=(ADD_INSTR_A >> 16) & 0xFFFF, hi=ADD_INSTR_B & 0xFFFF)
    w2 = _word(lo=(ADD_INSTR_B >> 16) & 0xFFFF, hi=COMPRESSED_ADDIW)
    mem = _SimpleFetchMem(
        {BASE_PC: w0, BASE_PC + 4: w1, BASE_PC + 8: w2, BASE_PC + 12: NOP_INSTR}
    )
    await _reset_dut(dut, boot_addr=BASE_PC)

    # Launch window 0.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)

    # Deliver window 0 -> emits C.NOP + ADD_INSTR_A, leaves hw[3] queued & f1_carry_hi_q=1;
    # launches window 1 (BASE_PC+8).
    mem.present(dut, valid=1)
    await _settle()
    assert _read_packet(dut, slot2=False)["program_counter"] == BASE_PC
    assert _read_packet(dut, slot2=True)["program_counter"] == BASE_PC + 2
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.f1_carry_hi_q.value) == 1

    # Return a mismatched tag for window 1 -> tag resteer back to BASE_PC+8; carry_hi MUST stay 1!
    mem.present(dut, valid=1, override_served_pc=BASE_PC + 0x40)
    await _settle()
    assert _read_packet(dut, slot2=False)["sel_nop"] is True
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 8
    assert int(dut.o_fetch_redirect.value) == 1
    assert int(dut.f1_carry_hi_q.value) == 1

    # Re-launch and deliver window 1 with matching tag -> ADD_INSTR_B stitches intact!
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=0, valid=1)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)

    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC + 6
    assert s1["effective_instr"] == ADD_INSTR_B
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 10
    assert s2["effective_instr"] == COMPRESSED_ADDIW_EXPANDED


@cocotb.test()
async def test_collapsed_fetch_trap_hold_pause_preserves_fresh_prediction(
    dut: Any,
) -> None:
    """Holding i_fetch_trap_hold across a collapsed-fetch pause preserves fresh prediction state."""
    mem = _SimpleFetchMem(
        {
            BASE_PC: ADD_INSTR_A,
            BASE_PC + 4: ADD_INSTR_B,
            BASE_PC + 8: ADD_INSTR_C,
            BASE_PC + 12: ADD_INSTR_D,
        }
    )
    await _reset_dut(dut, boot_addr=BASE_PC, enable_bp=True)

    # Wait out backing_btb's 512-set reset sweep, then train backing entries at
    # BASE_PC and BASE_PC + 8 and invalidate the fast BTB so only backing_btb hits.
    for _ in range(520):
        await _step(dut)
    await _train_btb(
        dut,
        pc=BASE_PC,
        target=BRANCH_TARGET,
        taken=True,
        jump=True,
        repeats=2,
    )
    await _train_btb(
        dut,
        pc=BASE_PC + 8,
        target=BRANCH_TARGET + 0x40,
        taken=True,
        jump=True,
        repeats=2,
    )
    _drive_from_ex(dut, {})
    for _ in range(4):
        await _step(dut)
    dut.i_btb_invalidate.value = 1
    await _step(dut)
    dut.i_btb_invalidate.value = 0
    for _ in range(4):
        await _step(dut)

    await _redirect_fence(dut, BASE_PC)
    assert int(dut.f1_req_valid_q.value) == 0
    assert int(dut.collapsed_armed_q.value) == 0
    assert int(dut.f1_pred_fresh_q.value) == 0

    # 1) With no outstanding F1 request, i_instr_valid=0, fetch_pa_valid=1, and no
    #    stop, clock once -> collapsed_armed_q=1 and f1_pred_fresh_q=1.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=BASE_PC, valid=0)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.f1_req_valid_q.value) == 0
    assert int(dut.collapsed_armed_q.value) == 1
    assert int(dut.f1_pred_fresh_q.value) == 1
    assert int(dut.o_pc.value) == BASE_PC

    # 2) Hold i_fetch_trap_hold=1 with i_instr_valid=0 for three clocks:
    #    f1_pred_fresh_q stays asserted while PC and predictors remain on BASE_PC.
    dut.i_fetch_trap_hold.value = 1
    for _ in range(3):
        await _step(dut)
        assert int(dut.collapsed_armed_q.value) == 1
        assert int(dut.f1_pred_fresh_q.value) == 1
        assert int(dut.o_pc.value) == BASE_PC
        assert _read_packet(dut, slot2=False)["sel_nop"] is True

    # Release i_fetch_trap_hold and present BASE_PC: collapsed accept emits the
    # window with its fresh backing-BTB hit intact and advances PC to BASE_PC + 8.
    dut.i_fetch_trap_hold.value = 0
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC
    assert s1["effective_instr"] == ADD_INSTR_A
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 4
    assert s2["effective_instr"] == ADD_INSTR_B
    assert int(dut.o_backing_hit.value) & 0b01 == 0b01
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 8

    # 3) Arm collapsed at BASE_PC + 8, pause with i_fetch_trap_hold=1 for two
    #    clocks, then present i_instr_valid=1 while still paused (drops
    #    f1_pred_fresh_q and retains f1_pred_hold_q), hold one more bubble cycle,
    #    then release and verify the held backing-BTB hit is still delivered.
    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=BASE_PC + 8, valid=0)
    await _settle()
    mem.capture_request(dut)
    await _step(dut)
    assert int(dut.collapsed_armed_q.value) == 1
    assert int(dut.f1_pred_fresh_q.value) == 1

    dut.i_fetch_trap_hold.value = 1
    await _step(dut)
    await _step(dut)
    assert int(dut.collapsed_armed_q.value) == 1
    assert int(dut.f1_pred_fresh_q.value) == 1

    mem.present(dut, valid=1)
    await _step(dut)
    assert int(dut.collapsed_armed_q.value) == 1
    assert int(dut.f1_pred_fresh_q.value) == 0

    _drive_window(dut, word0=NOP_INSTR, word1=NOP_INSTR, served_pc=BASE_PC + 8, valid=0)
    await _step(dut)
    assert int(dut.collapsed_armed_q.value) == 1
    assert int(dut.f1_pred_fresh_q.value) == 0

    dut.i_fetch_trap_hold.value = 0
    mem.present(dut, valid=1)
    await _settle()
    s1 = _read_packet(dut, slot2=False)
    s2 = _read_packet(dut, slot2=True)
    assert s1["sel_nop"] is False and s1["program_counter"] == BASE_PC + 8
    assert s1["effective_instr"] == ADD_INSTR_C
    assert s2["sel_nop"] is False and s2["program_counter"] == BASE_PC + 12
    assert s2["effective_instr"] == ADD_INSTR_D
    assert int(dut.o_backing_hit.value) & 0b01 == 0b01
    await _step(dut)
    assert int(dut.o_pc.value) == BASE_PC + 16
