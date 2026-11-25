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
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
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

    def present(self, dut: Any, *, valid: int = 1, override_served_pc: int | None = None) -> None:
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
    assert s2["sel_compressed"] is True and s2["effective_instr"] == COMPRESSED_ADDIW_EXPANDED


@cocotb.test()
async def test_stall_buffers_in_parcel_queue_and_asserts_stop_fetch(dut: Any) -> None:
    """Back-end stall fills the parcel queue up to headroom, raises stop_fetch, then drains in order."""
    words = {BASE_PC + 4 * i: (ADD_INSTR_A if i % 2 == 0 else ADD_INSTR_B) for i in range(12)}
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
    assert saw_stop_fetch, "parcel queue must assert stop_fetch once occupancy reaches headroom"

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
    await _train_btb(
        dut, pc=BASE_PC, target=ret_pc, taken=True, call=True, jump=True
    )
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
        dut, pc=BASE_PC + 4, target=BRANCH_TARGET, taken=True, call=True, jump=True, repeats=1
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
