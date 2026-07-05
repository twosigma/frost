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

"""Golden-model tests for the stage-2 parcel fill engine (B2, 2-wide).

PARCEL_QUEUE_DESIGN.md sections 2.1 / 2.1.1 / 2.1.2.  The engine walks the
instruction stream, enqueuing up to two ``pq_entry_t`` per served window: a
slot-1 at ``served_addr`` (ask-time prediction binding) and a contiguous
slot-2 at ``served_addr + 2`` (walk-time binding) when the bundle conditions
hold.

The testbench co-simulates a one-cycle-latency provider over a synthetic
instruction memory, a dual-ported BTB/DIR (slot-1 + slot-2 lookups), and a
Python reference of the engine.  The provider and BTB are driven from the
DUT's own ``o_ask_pc`` / ``o_lookup_pc`` / ``o_lookup_pc_2`` so a walk bug
cannot be masked, while the reference's ask and bundle are checked against the
DUT every cycle.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

CLOCK_PERIOD_NS = 10

# pq_entry_t field offsets within the 110-bit packed struct (LSB..MSB order
# matches riscv_pkg::pq_entry_t; see PARCEL_QUEUE_DESIGN.md entry-format table).
_OFF_DIR_IDX = 0
_OFF_DIR_TAKEN = 10
_OFF_PRED_TARGET = 11
_OFF_PRED_TAKEN = 42
_OFF_BTB_HIT = 43
_OFF_SLOT2_START_OK = 44
_OFF_ALLOWS_SLOT2 = 45
_OFF_IS_COMPRESSED = 46
_OFF_INSTR_BYTES = 47
_OFF_PC = 79

# riscv_pkg sideband bit positions (per 32-bit word).
_SB_IS_COMPRESSED_LO = 0
_SB_IS_COMPRESSED_HI = 1
_SB_ALLOWS_SLOT2_LO = 8
_SB_ALLOWS_SLOT2_HI = 9
_SB_SLOT2_START_LO = 10
_SB_SLOT2_START_HI = 11


def _bit(value: int, pos: int) -> int:
    """Extract a single bit."""
    return (value >> pos) & 1


# ---------------------------------------------------------------------------
# riscv_pkg::imem_make_sideband replica (word bytes -> 12-bit sideband)
# ---------------------------------------------------------------------------
def _compressed_control(parcel: int) -> bool:
    """Return whether a 16-bit parcel is a compressed control-flow op."""
    funct3 = (parcel >> 13) & 0x7
    funct4 = (parcel >> 12) & 0xF
    rs1 = (parcel >> 7) & 0x1F
    rs2 = (parcel >> 2) & 0x1F
    op = parcel & 0x3
    return (op == 1 and funct3 in (1, 5, 6, 7)) or (
        op == 2 and rs2 == 0 and rs1 != 0 and funct4 in (0b1000, 0b1001)
    )


def _native_serialize(opcode: int) -> bool:
    """Return whether a 7-bit opcode is a serialize-class native op."""
    return opcode in (0b1110011, 0b0001111, 0b0101111)


def _native_fp_compute(opcode: int) -> bool:
    """Return whether a 7-bit opcode is an FP-compute native op."""
    return opcode in (0b1010011, 0b1000011, 0b1000111, 0b1001011, 0b1001111)


def _make_sideband(word: int) -> int:
    """Compute the 12-bit predecode sideband for one 32-bit word."""
    is_c_lo = (word & 0x3) != 0x3
    is_c_hi = ((word >> 16) & 0x3) != 0x3
    cc_lo = _compressed_control(word & 0xFFFF)
    cc_hi = _compressed_control((word >> 16) & 0xFFFF)
    ns_lo = _native_serialize(word & 0x7F)
    ns_hi = _native_serialize((word >> 16) & 0x7F)
    fp_lo = _native_fp_compute(word & 0x7F)
    fp_hi = _native_fp_compute((word >> 16) & 0x7F)
    bits = [
        is_c_lo,
        is_c_hi,
        cc_lo,
        cc_hi,
        ns_lo,
        ns_hi,
        fp_lo,
        fp_hi,
        is_c_lo and not cc_lo,  # allows_slot2_after lo
        is_c_hi and not cc_hi,  # allows_slot2_after hi
        is_c_lo or not (ns_lo or fp_lo),  # slot2_start_valid lo
        is_c_hi or not (ns_hi or fp_hi),  # slot2_start_valid hi
    ]
    sb = 0
    for i, b in enumerate(bits):
        sb |= (1 if b else 0) << i
    return sb


# ---------------------------------------------------------------------------
# Instruction memory + stream builder
# ---------------------------------------------------------------------------
class Imem:
    """Word-addressed instruction memory with halfword-granular writes."""

    def __init__(self) -> None:
        """Create an empty memory."""
        self.words: dict[int, int] = {}

    def write(self, addr: int, value: int, nbytes: int) -> None:
        """Write ``nbytes`` (2 or 4) of ``value`` at halfword granularity."""
        for i in range(0, nbytes, 2):
            hw = (value >> (i * 8)) & 0xFFFF
            a = addr + i
            wa = a & ~0x3
            shift = 16 if (a & 0x2) else 0
            w = self.words.get(wa, 0)
            w = (w & ~(0xFFFF << shift)) | (hw << shift)
            self.words[wa] = w

    def word(self, wa: int) -> int:
        """Return the 32-bit word at (word-aligned) address ``wa``."""
        return self.words.get(wa & ~0x3, 0)

    def window(self, served_addr: int) -> tuple[int, int]:
        """Return (instr64, sideband24) for the window covering served_addr."""
        wa = served_addr & ~0x3
        low = self.word(wa)
        high = self.word(wa + 4)
        instr64 = (high << 32) | low
        sideband = (_make_sideband(high) << 12) | _make_sideband(low)
        return instr64, sideband


def build_stream(
    instrs: list[tuple[bool, int]], base: int = 0
) -> tuple[Imem, list[dict]]:
    """Lay out contiguous instructions; return (imem, expected served list)."""
    imem = Imem()
    served: list[dict] = []
    addr = base
    for is_c, value in instrs:
        size = 2 if is_c else 4
        imem.write(addr, value, size)
        bytes32 = (value & 0xFFFF) if is_c else (value & 0xFFFFFFFF)
        served.append(
            {"pc": addr, "size": size, "is_compressed": is_c, "instr_bytes": bytes32}
        )
        addr += size
    return imem, served


# Sideband-consistent instruction encodings.
C_NOP = 0x0001  # c.nop        (compressed, not control; pairs freely)
C_LI = 0x4501  # c.li x10,0    (compressed, not control)
C_J = 0xA001  # c.j .          (compressed CONTROL -> allows_slot2_after=0)
N_NOP = 0x00000013  # addi x0,x0,0 (32-bit, not serialize/fp)
N_ECALL = 0x00000073  # SYSTEM       (32-bit serialize -> slot2_start_ok=0 in slot-2)


# ---------------------------------------------------------------------------
# BTB / DIR model
# ---------------------------------------------------------------------------
class Btb:
    """A dual-ported BTB/DIR table: a pure function of the lookup address."""

    def __init__(self) -> None:
        """Create an empty predictor."""
        self.taken: dict[int, int] = {}  # pc(full) -> target(full)
        self.dir: dict[int, tuple[int, int]] = {}  # pc(full) -> (dir_taken, idx)

    def lookup(self, pc_full: int) -> dict:
        """Return the BTB/DIR result for a full lookup address."""
        hit = pc_full in self.taken
        target = self.taken.get(pc_full, 0)
        dir_taken, dir_idx = self.dir.get(pc_full, (0, 0))
        return {
            "hit": 1 if hit else 0,
            "taken": 1 if hit else 0,
            "target": target,  # full even address
            "dir_taken": dir_taken,
            "dir_idx": dir_idx,
        }


# ---------------------------------------------------------------------------
# Fill-engine reference (mirrors parcel_fill_engine.sv, 2-wide)
# ---------------------------------------------------------------------------
class FillRef:
    """Cycle-accurate reference of the 2-wide fill engine."""

    def __init__(self) -> None:
        """Create a reference in its post-reset state."""
        self.ask_q = 0
        self.bind_valid = False
        self.bind_pc = 0  # [31:1]
        self.bind_hit = 0
        self.bind_taken = 0
        self.bind_target = 0  # [31:1]
        self.bind_dir_taken = 0
        self.bind_dir_idx = 0
        self.slot2_redir_pending = False
        self.slot2_redir_target = 0  # [31:1]

    def combinational(
        self, win: dict | None, redir: dict | None, bp: bool, lr2: dict
    ) -> dict:
        """Predict this cycle's accept/entries/ask/flush outputs."""
        sa = self.ask_q
        sa_hw = (sa >> 1) & 1
        slot2_redir_fire = self.slot2_redir_pending
        tag_ok = win is not None and ((win["served_addr"] >> 1) == (sa >> 1))
        redirect_valid = redir is not None
        accept = tag_ok and not redirect_valid and not bp and not slot2_redir_fire

        if win is not None:
            low = win["instr"] & 0xFFFFFFFF
            high = (win["instr"] >> 32) & 0xFFFFFFFF
            sb_lo = win["sideband"] & 0xFFF
            sb_hi = (win["sideband"] >> 12) & 0xFFF
        else:
            low = high = sb_lo = sb_hi = 0

        # ---- Slot-1 at served_addr (word-lo when sa_hw=0, word-hi when =1). ----
        if sa_hw:
            s1_is_c = _bit(sb_lo, _SB_IS_COMPRESSED_HI)
            s1_allows = _bit(sb_lo, _SB_ALLOWS_SLOT2_HI)
            s1_start = _bit(sb_lo, _SB_SLOT2_START_HI)
            s1_span = ((high & 0xFFFF) << 16) | ((low >> 16) & 0xFFFF)
            s1_bytes = ((low >> 16) & 0xFFFF) if s1_is_c else s1_span
        else:
            s1_is_c = _bit(sb_lo, _SB_IS_COMPRESSED_LO)
            s1_allows = _bit(sb_lo, _SB_ALLOWS_SLOT2_LO)
            s1_start = _bit(sb_lo, _SB_SLOT2_START_LO)
            s1_bytes = (low & 0xFFFF) if s1_is_c else low
        s1_size = 2 if s1_is_c else 4

        # ---- Slot-2 at served_addr+2: CURRENT_HI (sa_hw=0) or NEXT_LO (=1). ----
        if sa_hw:  # NEXT_LO -- lo parcel of the high word, sb_hi lo bits
            s2_is_c = _bit(sb_hi, _SB_IS_COMPRESSED_LO)
            s2_allows = _bit(sb_hi, _SB_ALLOWS_SLOT2_LO)
            s2_start = _bit(sb_hi, _SB_SLOT2_START_LO)
            s2_bytes = (high & 0xFFFF) if s2_is_c else high
        else:  # CURRENT_HI -- hi parcel of the low word, sb_lo hi bits
            s2_is_c = _bit(sb_lo, _SB_IS_COMPRESSED_HI)
            s2_allows = _bit(sb_lo, _SB_ALLOWS_SLOT2_HI)
            s2_start = _bit(sb_lo, _SB_SLOT2_START_HI)
            s2_span = ((high & 0xFFFF) << 16) | ((low >> 16) & 0xFFFF)
            s2_bytes = ((low >> 16) & 0xFFFF) if s2_is_c else s2_span
        s2_size = 2 if s2_is_c else 4
        s2_pc = sa + 2

        bind_match = self.bind_valid and (self.bind_pc == (sa >> 1))
        slot1_taken = accept and bind_match and bool(self.bind_taken)
        slot2_present = (
            accept and bool(s1_allows) and bool(s2_start) and not slot1_taken
        )
        slot2_taken = slot2_present and bool(lr2["taken"])

        redir_target = redir["target"] if redir is not None else 0
        redir_partial = bool(redir["partial"]) if redir is not None else False
        if redirect_valid:
            ask_d = redir_target << 1
        elif slot2_redir_fire:
            ask_d = self.slot2_redir_target << 1
        elif slot1_taken:
            ask_d = self.bind_target << 1
        elif accept:
            ask_d = (sa + 2 + s2_size) if slot2_present else (sa + s1_size)
        else:
            ask_d = sa

        e0 = {
            "pc": sa >> 1,
            "instr_bytes": s1_bytes,
            "is_compressed": s1_is_c,
            "allows_slot2_after": s1_allows,
            "slot2_start_ok": s1_start,
            "btb_hit": self.bind_hit if bind_match else 0,
            "predicted_taken": self.bind_taken if bind_match else 0,
            "predicted_target": self.bind_target if bind_match else 0,
            "dir_taken": self.bind_dir_taken if bind_match else 0,
            "dir_idx": self.bind_dir_idx if bind_match else 0,
        }
        e1 = {
            "pc": s2_pc >> 1,
            "instr_bytes": s2_bytes,
            "is_compressed": s2_is_c,
            "allows_slot2_after": s2_allows,
            "slot2_start_ok": s2_start,
            "btb_hit": lr2["hit"],
            "predicted_taken": lr2["taken"],
            "predicted_target": lr2["target"] >> 1,
            "dir_taken": lr2["dir_taken"],
            "dir_idx": lr2["dir_idx"],
        }
        return {
            "accept": accept,
            "slot2_present": slot2_present,
            "slot2_taken": slot2_taken,
            "e0": e0,
            "e1": e1,
            "ask_d": ask_d,
            "flush_full": redirect_valid and not redir_partial,
            "flush_partial": redirect_valid and redir_partial,
            "core_redirect": redirect_valid or slot2_redir_fire,
            "s2_target": lr2["target"] >> 1,
        }

    def clock(
        self, ask_d: int, lr1: dict, slot2_taken: bool, s2_target: int, redir: bool
    ) -> None:
        """Advance registers: ask, slot-1 binding, slot-2 redirect one-shot."""
        self.ask_q = ask_d
        self.bind_valid = True
        self.bind_pc = ask_d >> 1
        self.bind_hit = lr1["hit"]
        self.bind_taken = lr1["taken"]
        self.bind_target = lr1["target"] >> 1
        self.bind_dir_taken = lr1["dir_taken"]
        self.bind_dir_idx = lr1["dir_idx"]
        self.slot2_redir_pending = (not redir) and slot2_taken
        if slot2_taken:
            self.slot2_redir_target = s2_target


# ---------------------------------------------------------------------------
# DUT helpers
# ---------------------------------------------------------------------------
def _unpack_entry(v: int) -> dict:
    """Extract pq_entry_t fields from the packed struct integer."""
    return {
        "dir_idx": (v >> _OFF_DIR_IDX) & 0x3FF,
        "dir_taken": (v >> _OFF_DIR_TAKEN) & 1,
        "predicted_target": (v >> _OFF_PRED_TARGET) & 0x7FFFFFFF,
        "predicted_taken": (v >> _OFF_PRED_TAKEN) & 1,
        "btb_hit": (v >> _OFF_BTB_HIT) & 1,
        "slot2_start_ok": (v >> _OFF_SLOT2_START_OK) & 1,
        "allows_slot2_after": (v >> _OFF_ALLOWS_SLOT2) & 1,
        "is_compressed": (v >> _OFF_IS_COMPRESSED) & 1,
        "instr_bytes": (v >> _OFF_INSTR_BYTES) & 0xFFFFFFFF,
        "pc": (v >> _OFF_PC) & 0x7FFFFFFF,
    }


async def _settle() -> None:
    """Advance simulation time by a delta so combinational logic settles."""
    await Timer(1, unit="ns")


def _clear_inputs(dut: Any) -> None:
    """Drive every DUT input to its idle value."""
    dut.i_redirect_valid.value = 0
    dut.i_redirect_target.value = 0
    dut.i_redirect_partial.value = 0
    dut.i_win_valid.value = 0
    dut.i_win_served_addr.value = 0
    dut.i_win_instr.value = 0
    dut.i_win_sideband.value = 0
    dut.i_btb_hit.value = 0
    dut.i_btb_taken.value = 0
    dut.i_btb_target.value = 0
    dut.i_dir_taken.value = 0
    dut.i_dir_idx.value = 0
    dut.i_btb_hit_2.value = 0
    dut.i_btb_taken_2.value = 0
    dut.i_btb_target_2.value = 0
    dut.i_dir_taken_2.value = 0
    dut.i_dir_idx_2.value = 0
    dut.i_queue_backpressure.value = 0


async def _reset(dut: Any) -> None:
    """Start the clock, pulse reset, and settle into the walk-from-0 state."""
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await _settle()


class Harness:
    """Drives one co-simulation cycle and checks every DUT output."""

    def __init__(self, dut: Any, imem: Imem, btb: Btb) -> None:
        """Bind the DUT to an instruction memory and predictor."""
        self.dut = dut
        self.imem = imem
        self.btb = btb
        self.ref = FillRef()
        self.cycle = 0
        self.enqueued: list[dict] = []

    async def step(
        self,
        *,
        win_valid: bool = True,
        served_override: int | None = None,
        redir: dict | None = None,
        backpressure: bool = False,
    ) -> dict:
        """Drive and check one cycle; return the reference's expectation dict."""
        dut, ref = self.dut, self.ref
        ctx = f"cycle {self.cycle}"

        # ---- Provider: serve the ask the engine is waiting on (ref.ask_q). ----
        served_addr = ref.ask_q if served_override is None else served_override
        instr64, sideband = self.imem.window(served_addr)
        win: dict | None = None
        if win_valid:
            win = {"served_addr": served_addr, "instr": instr64, "sideband": sideband}
            dut.i_win_valid.value = 1
            dut.i_win_served_addr.value = served_addr
            dut.i_win_instr.value = instr64
            dut.i_win_sideband.value = sideband
        else:
            dut.i_win_valid.value = 0
            dut.i_win_served_addr.value = 0
            dut.i_win_instr.value = 0
            dut.i_win_sideband.value = 0

        if redir is not None:
            dut.i_redirect_valid.value = 1
            dut.i_redirect_target.value = redir["target"]  # [31:1]
            dut.i_redirect_partial.value = 1 if redir["partial"] else 0
        else:
            dut.i_redirect_valid.value = 0
            dut.i_redirect_target.value = 0
            dut.i_redirect_partial.value = 0
        dut.i_queue_backpressure.value = 1 if backpressure else 0
        await _settle()

        # ---- Slot-2 lookup (o_lookup_pc_2 = served_addr + 2, off the register). ----
        dut_lookup2 = int(dut.o_lookup_pc_2.value)
        assert dut_lookup2 == (
            (ref.ask_q + 2) >> 1
        ), f"{ctx}: o_lookup_pc_2={dut_lookup2:#x} != {(ref.ask_q + 2) >> 1:#x}"
        lr2 = self.btb.lookup(dut_lookup2 << 1)
        dut.i_btb_hit_2.value = lr2["hit"]
        dut.i_btb_taken_2.value = lr2["taken"]
        dut.i_btb_target_2.value = lr2["target"] >> 1
        dut.i_dir_taken_2.value = lr2["dir_taken"]
        dut.i_dir_idx_2.value = lr2["dir_idx"]
        await _settle()

        exp = ref.combinational(win, redir, backpressure, lr2)

        # ---- Slot-1 lookup (o_lookup_pc = ask_d). ----
        dut_lookup = int(dut.o_lookup_pc.value)
        assert dut_lookup == (
            exp["ask_d"] >> 1
        ), f"{ctx}: o_lookup_pc={dut_lookup:#x} != ref ask {exp['ask_d'] >> 1:#x}"
        lr1 = self.btb.lookup(dut_lookup << 1)
        dut.i_btb_hit.value = lr1["hit"]
        dut.i_btb_taken.value = lr1["taken"]
        dut.i_btb_target.value = lr1["target"] >> 1
        dut.i_dir_taken.value = lr1["dir_taken"]
        dut.i_dir_idx.value = lr1["dir_idx"]
        await _settle()

        # ---- Check combinational outputs. ----
        assert int(dut.o_ask_pc.value) == (
            exp["ask_d"] >> 1
        ), f"{ctx}: o_ask_pc={int(dut.o_ask_pc.value):#x} != {exp['ask_d'] >> 1:#x}"
        want_valid = (2 if exp["slot2_present"] else 0) | (1 if exp["accept"] else 0)
        assert (
            int(dut.o_enq_valid.value) == want_valid
        ), f"{ctx}: o_enq_valid={int(dut.o_enq_valid.value):#b} want {want_valid:#b}"
        assert bool(dut.o_flush_full.value) == exp["flush_full"], f"{ctx}: flush_full"
        assert (
            bool(dut.o_flush_partial.value) == exp["flush_partial"]
        ), f"{ctx}: flush_partial"
        assert (
            bool(dut.o_core_redirect.value) == exp["core_redirect"]
        ), f"{ctx}: core_redirect"

        if exp["accept"]:
            got0 = _unpack_entry(int(dut.o_enq_entry0.value))
            for field, want in exp["e0"].items():
                assert (
                    got0[field] == want
                ), f"{ctx}: e0.{field}={got0[field]:#x} want {want:#x}"
            self.enqueued.append(exp["e0"])
        if exp["slot2_present"]:
            got1 = _unpack_entry(int(dut.o_enq_entry1.value))
            for field, want in exp["e1"].items():
                assert (
                    got1[field] == want
                ), f"{ctx}: e1.{field}={got1[field]:#x} want {want:#x}"
            self.enqueued.append(exp["e1"])

        # ---- Clock and advance the reference registers. ----
        await RisingEdge(dut.i_clk)
        ref.clock(
            exp["ask_d"], lr1, exp["slot2_taken"], exp["s2_target"], redir is not None
        )
        await _settle()
        self.cycle += 1
        return exp

    async def drain_to(self, n: int, *, max_cycles: int = 64) -> None:
        """Step (idle traffic) until at least ``n`` entries have enqueued."""
        c = 0
        while len(self.enqueued) < n and c < max_cycles:
            await self.step()
            c += 1
        assert len(self.enqueued) >= n, f"only {len(self.enqueued)}/{n} enqueued"


# ---------------------------------------------------------------------------
# Walk tests (bundle-aware)
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_reset_starts_at_zero(dut: Any) -> None:
    """After reset the engine asks for the reset vector (0) and enqueues it."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP), (True, C_NOP)])
    h = Harness(dut, imem, Btb())
    exp = await h.step()
    assert exp["accept"]
    assert h.enqueued[0]["pc"] == 0
    assert h.enqueued[0]["predicted_taken"] == 0


@cocotb.test()
async def test_walk_compressed_bundles(dut: Any) -> None:
    """A run of pairable compressed instructions walks two-wide in order."""
    await _reset(dut)
    imem, served = build_stream([(True, C_NOP)] * 8)
    h = Harness(dut, imem, Btb())
    await h.drain_to(8)
    pcs = [e["pc"] << 1 for e in h.enqueued[:8]]
    assert pcs == [s["pc"] for s in served], pcs
    assert all(e["is_compressed"] == 1 for e in h.enqueued[:8])
    # Two-wide actually formed bundles (not one per cycle over 8 cycles).
    assert h.cycle <= 6, f"expected bundling, took {h.cycle} cycles"


@cocotb.test()
async def test_walk_native_single(dut: Any) -> None:
    """A run of 32-bit instructions cannot pair (allows_slot2_after=0)."""
    await _reset(dut)
    imem, served = build_stream([(False, N_NOP)] * 6)
    h = Harness(dut, imem, Btb())
    for _ in range(6):
        exp = await h.step()
        assert not exp["slot2_present"]  # 32-bit slot-1 never leads a bundle
    pcs = [e["pc"] << 1 for e in h.enqueued]
    assert pcs == [s["pc"] for s in served], pcs
    assert all(e["instr_bytes"] == N_NOP for e in h.enqueued)


@cocotb.test()
async def test_walk_mixed_and_spanning(dut: Any) -> None:
    """Assemble a 32-bit op that lands at a halfword boundary across two words."""
    await _reset(dut)
    prog = [(True, C_NOP), (False, 0x12345637), (True, C_LI), (False, 0xABCDE6B7)]
    imem, served = build_stream(prog)
    h = Harness(dut, imem, Btb())
    await h.drain_to(len(prog))
    for got, want in zip(h.enqueued, served):
        assert (got["pc"] << 1) == want["pc"]
        assert got["is_compressed"] == int(want["is_compressed"])
        assert (
            got["instr_bytes"] == want["instr_bytes"]
        ), f"pc {want['pc']:#x}: bytes {got['instr_bytes']:#x} want {want['instr_bytes']:#x}"
    assert served[1]["pc"] == 2 and served[1]["instr_bytes"] == 0x12345637


# ---------------------------------------------------------------------------
# Slot-2 formation tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_bundle_compressed_pair(dut: Any) -> None:
    """Two compressed instructions enqueue as a bundle in one cycle."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_LI), (True, C_NOP)])
    h = Harness(dut, imem, Btb())
    exp = await h.step()
    assert exp["accept"] and exp["slot2_present"]
    assert exp["e0"]["pc"] == 0 and exp["e0"]["instr_bytes"] == C_LI
    assert (exp["e1"]["pc"] << 1) == 2 and exp["e1"]["instr_bytes"] == C_NOP
    assert exp["ask_d"] == 4  # advanced past both


@cocotb.test()
async def test_bundle_compressed_then_native(dut: Any) -> None:
    """A compressed slot-1 pairs with a 32-bit slot-2 spanning both words."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP), (False, 0x12345637)])
    h = Harness(dut, imem, Btb())
    exp = await h.step()
    assert exp["slot2_present"]
    assert (exp["e1"]["pc"] << 1) == 2
    assert exp["e1"]["is_compressed"] == 0
    assert exp["e1"]["instr_bytes"] == 0x12345637  # CURRENT_HI span assembly
    assert exp["ask_d"] == 6  # 0 + 2 + 4


@cocotb.test()
async def test_bundle_next_lo_position(dut: Any) -> None:
    """Slot-2 at NEXT_LO: reach a halfword served address via a redirect."""
    await _reset(dut)
    # A compressed slot-1 at 0x82 (word-hi) + compressed slot-2 at 0x84 (NEXT_LO).
    imem, _ = build_stream([(True, C_LI), (True, C_NOP)], base=0x82)
    imem0, _ = build_stream([(True, C_NOP)], base=0)
    imem.words.update(imem0.words)
    h = Harness(dut, imem, Btb())
    await h.step()  # cold walk from 0
    exp = await h.step(redir={"target": 0x82 >> 1, "partial": False})
    assert exp["ask_d"] == 0x82
    exp2 = await h.step()  # serve 0x82: slot-1 at word-hi, slot-2 at NEXT_LO
    assert exp2["slot2_present"]
    assert (exp2["e0"]["pc"] << 1) == 0x82 and exp2["e0"]["instr_bytes"] == C_LI
    assert (exp2["e1"]["pc"] << 1) == 0x84 and exp2["e1"]["instr_bytes"] == C_NOP


@cocotb.test()
async def test_no_pair_after_compressed_branch(dut: Any) -> None:
    """A compressed control-flow slot-1 (allows_slot2_after=0) blocks slot-2."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_J), (True, C_NOP)])
    h = Harness(dut, imem, Btb())
    exp = await h.step()
    assert exp["accept"] and not exp["slot2_present"]
    assert exp["e0"]["allows_slot2_after"] == 0


@cocotb.test()
async def test_no_pair_slot2_serialize(dut: Any) -> None:
    """A serialize (SYSTEM/CSR) slot-2 (slot2_start_ok=0) blocks pairing."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP), (False, N_ECALL)])
    h = Harness(dut, imem, Btb())
    exp = await h.step()
    assert exp["accept"] and not exp["slot2_present"]
    # The engine advances past slot-1 only; the serialize op replays as slot-1.
    assert exp["ask_d"] == 2


@cocotb.test()
async def test_no_pair_after_taken_slot1(dut: Any) -> None:
    """A predicted-taken slot-1 blocks slot-2 (bundle would be discontiguous)."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_LI), (True, C_NOP)])
    tgt, _ = build_stream([(True, C_NOP)] * 2, base=0x60)
    imem.words.update(tgt.words)
    btb = Btb()
    btb.taken[0x0] = 0x60
    h = Harness(dut, imem, btb)
    await h.step()  # cold pc0; arm its binding via a redirect back to 0
    await h.step(redir={"target": 0x0 >> 1, "partial": False})
    exp = await h.step()
    assert exp["accept"] and not exp["slot2_present"]  # slot-1 taken suppresses slot-2
    assert exp["e0"]["predicted_taken"] == 1
    assert exp["ask_d"] == 0x60


# ---------------------------------------------------------------------------
# Redirect tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_slot2_taken_redirect_bubble(dut: Any) -> None:
    """A taken slot-2 registers a one-cycle redirect: bundle, bubble, target."""
    await _reset(dut)
    # slot-1 C_NOP @0, slot-2 @2 is a taken branch to 0x50 (BTB-driven).
    imem, _ = build_stream([(True, C_NOP), (True, C_LI)])
    tgt, _ = build_stream([(True, C_NOP), (True, C_NOP)], base=0x50)
    imem.words.update(tgt.words)
    btb = Btb()
    btb.taken[0x2] = 0x50
    h = Harness(dut, imem, btb)
    # Serve @0: bundle {e0@0, e1@2-branch} enqueues, slot-2 taken registers.
    exp = await h.step()
    assert exp["slot2_present"] and exp["slot2_taken"]
    assert (
        exp["e1"]["predicted_taken"] == 1
        and (exp["e1"]["predicted_target"] << 1) == 0x50
    )
    assert exp["ask_d"] == 4  # sequential (wrong-path) ask past the RVC+RVC bundle
    assert not exp["core_redirect"]
    # Fire cycle: redirect to target, pulse core_redirect, NO enqueue (bubble).
    exp_fire = await h.step()
    assert exp_fire["core_redirect"] and not exp_fire["accept"]
    assert not exp_fire["flush_full"] and not exp_fire["flush_partial"]  # no flush
    assert exp_fire["ask_d"] == 0x50
    n = len(h.enqueued)
    # Target walked next.
    exp_t = await h.step()
    assert (exp_t["e0"]["pc"] << 1) == 0x50
    assert len(h.enqueued) == n + (2 if exp_t["slot2_present"] else 1)


@cocotb.test()
async def test_slot1_taken_redirect(dut: Any) -> None:
    """A predicted-taken slot-1 steers the next ask to the target, zero bubble."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_LI), (True, C_J)])
    imem2, _ = build_stream([(True, C_NOP), (True, C_NOP)], base=0x40)
    imem.words.update(imem2.words)
    btb = Btb()
    btb.taken[0x0] = 0x40
    h = Harness(dut, imem, btb)
    await h.step()  # cold pc0
    await h.step(redir={"target": 0x0 >> 1, "partial": False})
    exp = await h.step()
    assert exp["e0"]["pc"] == 0 and exp["e0"]["predicted_taken"] == 1
    assert not exp["slot2_present"]
    assert exp["ask_d"] == 0x40 and not exp["core_redirect"]  # ask-time, no pulse


@cocotb.test()
async def test_full_flush_redirect(dut: Any) -> None:
    """A full redirect resteers, pulses core_redirect, and full-flushes."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP)] * 4)
    imem2, _ = build_stream([(True, C_NOP)] * 4, base=0x100)
    imem.words.update(imem2.words)
    h = Harness(dut, imem, Btb())
    await h.step()
    n_before = len(h.enqueued)
    exp = await h.step(redir={"target": 0x100 >> 1, "partial": False})
    assert not exp["accept"] and len(h.enqueued) == n_before
    assert exp["flush_full"] and not exp["flush_partial"] and exp["core_redirect"]
    assert exp["ask_d"] == 0x100
    exp2 = await h.step()
    assert (exp2["e0"]["pc"] << 1) == 0x100


@cocotb.test()
async def test_partial_flush_redirect(dut: Any) -> None:
    """A partial (RAS dequeue-fire) redirect asserts flush_partial only."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP)] * 3)
    imem2, _ = build_stream([(True, C_NOP)] * 3, base=0x80)
    imem.words.update(imem2.words)
    h = Harness(dut, imem, Btb())
    await h.step()
    exp = await h.step(redir={"target": 0x80 >> 1, "partial": True})
    assert exp["flush_partial"] and not exp["flush_full"] and exp["core_redirect"]
    assert exp["ask_d"] == 0x80


# ---------------------------------------------------------------------------
# Hold / acceptance tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_freeze_holds_ask(dut: Any) -> None:
    """Freeze the walk while ``i_win_valid`` is low, then resume correctly."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP)] * 6)
    h = Harness(dut, imem, Btb())
    await h.step()
    ask_held = int(dut.o_ask_pc.value)
    for _ in range(3):
        exp = await h.step(win_valid=False)
        assert not exp["accept"]
        assert int(dut.o_ask_pc.value) == ask_held
    n = len(h.enqueued)
    await h.step()
    assert len(h.enqueued) > n


@cocotb.test()
async def test_backpressure_holds_ask(dut: Any) -> None:
    """Queue backpressure holds the ask and suppresses enqueue."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP)] * 6)
    h = Harness(dut, imem, Btb())
    await h.step()
    ask_held = int(dut.o_ask_pc.value)
    for _ in range(3):
        exp = await h.step(backpressure=True)
        assert not exp["accept"]
        assert int(dut.o_ask_pc.value) == ask_held
    await h.step()
    assert len(h.enqueued) >= 2


@cocotb.test()
async def test_stale_window_rejected(dut: Any) -> None:
    """Reject a valid window whose served_addr misses the outstanding ask."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP)] * 4)
    h = Harness(dut, imem, Btb())
    await h.step()
    n = len(h.enqueued)
    ask_held = int(dut.o_ask_pc.value)
    exp = await h.step(served_override=0xDEAD_0000 | ((ask_held << 1) ^ 0x4))
    assert not exp["accept"] and len(h.enqueued) == n
    assert int(dut.o_ask_pc.value) == ask_held
    await h.step()
    assert len(h.enqueued) > n


@cocotb.test()
async def test_binding_not_leaked_across_redirect(dut: Any) -> None:
    """Guard the stale-at-birth analog (design 2.1.1 / finding 1)."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_LI), (True, C_J)])
    tgt, _ = build_stream([(True, C_NOP)] * 2, base=0x200)
    other, _ = build_stream([(True, C_NOP)] * 2, base=0x300)
    imem.words.update(tgt.words)
    imem.words.update(other.words)
    btb = Btb()
    btb.taken[0x0] = 0x200
    h = Harness(dut, imem, btb)
    await h.step()
    await h.step(redir={"target": 0x0 >> 1, "partial": False})
    exp = await h.step(redir={"target": 0x300 >> 1, "partial": False})
    assert not exp["accept"]
    assert exp["ask_d"] == 0x300
    exp2 = await h.step()
    assert (exp2["e0"]["pc"] << 1) == 0x300
    assert exp2["e0"]["predicted_taken"] == 0
    assert exp2["e0"]["predicted_target"] == 0


@cocotb.test()
async def test_dir_metadata_bound(dut: Any) -> None:
    """Bind slot-1 and slot-2 decoupled direction metadata from their lookups."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP)] * 4)
    btb = Btb()
    btb.dir[0x0] = (1, 0x155)  # slot-1 @0 hint (bound one cycle later)
    btb.dir[0x2] = (1, 0x2AB)  # slot-2 @2 hint (walk-time bound)
    h = Harness(dut, imem, btb)
    exp = await h.step()  # bundle {0, 2}
    assert exp["slot2_present"]
    assert exp["e1"]["dir_taken"] == 1 and exp["e1"]["dir_idx"] == 0x2AB


# ---------------------------------------------------------------------------
# Randomized soak
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_randomized_soak(dut: Any) -> None:
    """Soak a random program with freezes, backpressure, and redirects."""
    await _reset(dut)
    rng = random.Random(0xB222)

    imem = Imem()
    btb = Btb()
    choices = [
        C_NOP | (C_NOP << 16),
        C_LI | (C_NOP << 16),
        N_NOP,
        N_ECALL,
        C_J | (C_NOP << 16),
        C_NOP | (C_J << 16),
    ]
    for base in range(0, 0x800, 4):
        imem.words[base] = rng.choice(choices)
    for _ in range(40):
        src = rng.randrange(0, 0x800) & ~0x1
        dst = rng.randrange(0, 0x800) & ~0x1
        btb.taken[src] = dst

    h = Harness(dut, imem, btb)
    for _ in range(4000):
        redir = None
        if rng.random() < 0.04:
            redir = {
                "target": (rng.randrange(0, 0x800) & ~0x1) >> 1,
                "partial": rng.random() < 0.3,
            }
        await h.step(
            win_valid=rng.random() > 0.15,
            redir=redir,
            backpressure=rng.random() < 0.12,
        )
