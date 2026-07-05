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

"""Golden-model tests for the stage-2 parcel fill engine.

PARCEL_QUEUE_DESIGN.md sections 2.1 / 2.1.1.  The engine is a 1-wide,
self-aligned instruction walk: it presents an ask, the provider serves that
ask's window one cycle later, and the engine enqueues one ``pq_entry_t`` per
served instruction with prediction metadata bound (pc-tagged) from the
ask-time lookup.

The testbench co-simulates three reference models against the DUT, cycle by
cycle:

* a **provider** -- a one-cycle-latency window over a synthetic instruction
  memory (``imem``), serving the address the engine asked for last cycle;
* a **BTB/DIR** -- a pure function of the lookup address;
* a **fill-engine reference** -- mirrors the RTL's accept / decode / bind /
  advance so every enqueued entry, the presented ask, and the flush/redirect
  outputs are predicted independently and checked bit-exactly.

The provider and BTB are driven from the DUT's own ``o_ask_pc`` /
``o_lookup_pc`` (so a walk bug cannot be masked by feeding the DUT the
reference's intentions), while the reference's ask is asserted equal to the
DUT's every cycle.
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
    lo = word & 0xFFFF
    hi = (word >> 16) & 0xFFFF
    is_c_lo = (word & 0x3) != 0x3
    is_c_hi = ((word >> 16) & 0x3) != 0x3
    cc_lo = _compressed_control(lo)
    cc_hi = _compressed_control(hi)
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
    """Lay out contiguous instructions; return (imem, expected served list).

    Each element is (is_compressed, value): a 16-bit parcel or a 32-bit word.
    Returns the imem plus, per instruction, the pc, size, is_compressed, and
    the effective 32-bit ``instr_bytes`` the fill engine must produce.
    """
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


# Simple, sideband-consistent instruction encodings.
C_NOP = 0x0001  # c.nop  (compressed, not control)
N_NOP = 0x00000013  # addi x0,x0,0 (32-bit, not serialize/fp)


# ---------------------------------------------------------------------------
# BTB / DIR model
# ---------------------------------------------------------------------------
class Btb:
    """A BTB/DIR table: a pure function of the lookup address."""

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
# Fill-engine reference (mirrors parcel_fill_engine.sv)
# ---------------------------------------------------------------------------
class FillRef:
    """Cycle-accurate reference of the fill engine's combinational + state."""

    def __init__(self) -> None:
        """Create a reference in its post-reset state (ask 0, cold binding)."""
        self.ask_q = 0
        self.bind_valid = False
        self.bind_pc = 0  # [31:1]
        self.bind_hit = 0
        self.bind_taken = 0
        self.bind_target = 0  # [31:1]
        self.bind_dir_taken = 0
        self.bind_dir_idx = 0

    def combinational(self, win: dict | None, redir: dict | None, bp: bool) -> dict:
        """Predict this cycle's accept/entry/ask/flush outputs."""
        sa = self.ask_q
        sa_hw = (sa >> 1) & 1
        tag_ok = win is not None and ((win["served_addr"] >> 1) == (sa >> 1))
        redirect_valid = redir is not None
        accept = tag_ok and not redirect_valid and not bp

        # Decode the served instruction (self-aligned: low word = word(sa)).
        if win is not None:
            low = win["instr"] & 0xFFFFFFFF
            high = (win["instr"] >> 32) & 0xFFFFFFFF
            sb_cur = win["sideband"] & 0xFFF
        else:
            low = high = sb_cur = 0
        is_c = bool(
            (sb_cur >> (_SB_IS_COMPRESSED_HI if sa_hw else _SB_IS_COMPRESSED_LO)) & 1
        )
        allows2 = bool(
            (sb_cur >> (_SB_ALLOWS_SLOT2_HI if sa_hw else _SB_ALLOWS_SLOT2_LO)) & 1
        )
        start2 = bool(
            (sb_cur >> (_SB_SLOT2_START_HI if sa_hw else _SB_SLOT2_START_LO)) & 1
        )
        parcel = (low >> 16) & 0xFFFF if sa_hw else low & 0xFFFF
        if is_c:
            instr_bytes = parcel
        elif not sa_hw:
            instr_bytes = low
        else:
            instr_bytes = ((high & 0xFFFF) << 16) | ((low >> 16) & 0xFFFF)
        size = 2 if is_c else 4

        bind_match = self.bind_valid and (self.bind_pc == (sa >> 1))
        taken_redirect = accept and bind_match and bool(self.bind_taken)

        redir_target = redir["target"] if redir is not None else 0
        redir_partial = bool(redir["partial"]) if redir is not None else False
        if redirect_valid:
            ask_d = redir_target << 1
        elif taken_redirect:
            ask_d = self.bind_target << 1
        elif accept:
            ask_d = sa + size
        else:
            ask_d = sa

        entry = {
            "pc": sa >> 1,
            "instr_bytes": instr_bytes,
            "is_compressed": int(is_c),
            "allows_slot2_after": int(allows2),
            "slot2_start_ok": int(start2),
            "btb_hit": self.bind_hit if bind_match else 0,
            "predicted_taken": self.bind_taken if bind_match else 0,
            "predicted_target": self.bind_target if bind_match else 0,
            "dir_taken": self.bind_dir_taken if bind_match else 0,
            "dir_idx": self.bind_dir_idx if bind_match else 0,
        }
        return {
            "accept": accept,
            "entry": entry,
            "ask_d": ask_d,
            "flush_full": redirect_valid and not redir_partial,
            "flush_partial": redirect_valid and redir_partial,
            "core_redirect": redirect_valid,
        }

    def clock(self, ask_d: int, lr: dict) -> None:
        """Advance the registers: latch the ask and this cycle's binding."""
        self.ask_q = ask_d
        self.bind_valid = True
        self.bind_pc = ask_d >> 1
        self.bind_hit = lr["hit"]
        self.bind_taken = lr["taken"]
        self.bind_target = lr["target"] >> 1
        self.bind_dir_taken = lr["dir_taken"]
        self.bind_dir_idx = lr["dir_idx"]


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

        exp = ref.combinational(win, redir, backpressure)

        # ---- Drive the BTB from the DUT's own lookup address. ----
        dut_lookup = int(dut.o_lookup_pc.value)
        assert dut_lookup == (
            exp["ask_d"] >> 1
        ), f"{ctx}: o_lookup_pc={dut_lookup:#x} != ref ask {exp['ask_d'] >> 1:#x}"
        lr = self.btb.lookup(dut_lookup << 1)
        dut.i_btb_hit.value = lr["hit"]
        dut.i_btb_taken.value = lr["taken"]
        dut.i_btb_target.value = lr["target"] >> 1
        dut.i_dir_taken.value = lr["dir_taken"]
        dut.i_dir_idx.value = lr["dir_idx"]
        await _settle()

        # ---- Check combinational outputs. ----
        assert int(dut.o_ask_pc.value) == (exp["ask_d"] >> 1), (
            f"{ctx}: o_ask_pc={int(dut.o_ask_pc.value):#x} "
            f"!= ref {exp['ask_d'] >> 1:#x}"
        )
        want_valid = 0b01 if exp["accept"] else 0b00
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
            got = _unpack_entry(int(dut.o_enq_entry0.value))
            for field, want in exp["entry"].items():
                assert (
                    got[field] == want
                ), f"{ctx}: entry.{field}={got[field]:#x} want {want:#x}"
            self.enqueued.append(exp["entry"])

        # ---- Clock and advance the reference registers. ----
        await RisingEdge(dut.i_clk)
        ref.clock(exp["ask_d"], lr)
        await _settle()
        self.cycle += 1
        return exp


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_reset_starts_at_zero(dut: Any) -> None:
    """After reset the engine asks for the reset vector (0) and enqueues it."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP), (True, C_NOP)])
    h = Harness(dut, imem, Btb())
    exp = await h.step()
    # First served instruction (pc 0) enqueues; its binding is cold (reset).
    assert exp["accept"]
    assert h.enqueued[0]["pc"] == 0
    assert h.enqueued[0]["predicted_taken"] == 0


@cocotb.test()
async def test_walk_compressed(dut: Any) -> None:
    """A run of compressed instructions advances the ask by +2 each cycle."""
    await _reset(dut)
    imem, served = build_stream([(True, C_NOP)] * 8)
    h = Harness(dut, imem, Btb())
    for _ in range(8):
        await h.step()
    pcs = [e["pc"] << 1 for e in h.enqueued]
    assert pcs == [s["pc"] for s in served], pcs
    assert all(e["is_compressed"] == 1 for e in h.enqueued)


@cocotb.test()
async def test_walk_native(dut: Any) -> None:
    """A run of 32-bit instructions advances the ask by +4 each cycle."""
    await _reset(dut)
    imem, served = build_stream([(False, N_NOP)] * 6)
    h = Harness(dut, imem, Btb())
    for _ in range(6):
        await h.step()
    pcs = [e["pc"] << 1 for e in h.enqueued]
    assert pcs == [s["pc"] for s in served], pcs
    assert all(e["is_compressed"] == 0 for e in h.enqueued)
    assert all(e["instr_bytes"] == N_NOP for e in h.enqueued)


@cocotb.test()
async def test_walk_mixed_and_spanning(dut: Any) -> None:
    """Assemble a 32-bit op that lands at a halfword boundary across two words.

    A mixed C/32-bit stream places a 32-bit instruction at pc 2 so it spans
    word0/word1; the fill engine must reproduce the original 32-bit word.
    """
    await _reset(dut)
    prog = [(True, C_NOP), (False, 0x12345637), (True, 0x4501), (False, 0xABCDE6B7)]
    imem, served = build_stream(prog)
    h = Harness(dut, imem, Btb())
    for _ in range(len(prog)):
        await h.step()
    for got, want in zip(h.enqueued, served):
        assert (got["pc"] << 1) == want["pc"]
        assert got["is_compressed"] == int(want["is_compressed"])
        assert got["instr_bytes"] == want["instr_bytes"], (
            f"pc {want['pc']:#x}: bytes {got['instr_bytes']:#x} "
            f"want {want['instr_bytes']:#x}"
        )
    assert served[1]["pc"] == 2 and served[1]["instr_bytes"] == 0x12345637


@cocotb.test()
async def test_slot1_taken_redirect(dut: Any) -> None:
    """Steer the next ask to a predicted-taken slot-1 branch's target.

    The branch binds taken/target to its own entry, and the next served entry
    is the target (zero bubble in the ask stream).
    """
    await _reset(dut)
    imem, _ = build_stream([(True, 0x4501), (True, C_NOP)])  # 0,2
    imem2, _ = build_stream([(True, C_NOP), (True, C_NOP)], base=0x40)
    imem.words.update(imem2.words)
    btb = Btb()
    btb.taken[0x0] = 0x40
    h = Harness(dut, imem, btb)
    # Cycle 0: pc0's binding is cold (reset), so it enqueues without prediction
    # and advances sequentially.  Redirect back to 0 to arm pc0's binding.
    await h.step()
    assert h.enqueued[0]["pc"] == 0 and h.enqueued[0]["predicted_taken"] == 0
    await h.step(redir={"target": 0x0 >> 1, "partial": False})
    # ask==0 with the binding for 0 armed from the redirect-cycle lookup.
    exp = await h.step()
    assert exp["entry"]["pc"] == 0
    assert exp["entry"]["predicted_taken"] == 1
    assert (exp["entry"]["predicted_target"] << 1) == 0x40
    assert exp["ask_d"] == 0x40  # next ask is the target
    exp2 = await h.step()
    assert (exp2["entry"]["pc"] << 1) == 0x40


@cocotb.test()
async def test_full_flush_redirect(dut: Any) -> None:
    """Resteer, pulse core_redirect, and full-flush on a redirect.

    The same-cycle window is not enqueued and the walk resumes at the target.
    """
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP)] * 4)
    imem2, _ = build_stream([(True, C_NOP)] * 4, base=0x100)
    imem.words.update(imem2.words)
    h = Harness(dut, imem, Btb())
    await h.step()
    await h.step()
    n_before = len(h.enqueued)
    exp = await h.step(redir={"target": 0x100 >> 1, "partial": False})
    assert not exp["accept"] and len(h.enqueued) == n_before
    assert exp["flush_full"] and not exp["flush_partial"] and exp["core_redirect"]
    assert exp["ask_d"] == 0x100
    exp2 = await h.step()
    assert (exp2["entry"]["pc"] << 1) == 0x100


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


@cocotb.test()
async def test_freeze_holds_ask(dut: Any) -> None:
    """Freeze the walk while ``i_win_valid`` is low, then resume correctly.

    A frozen cycle enqueues nothing and holds the ask; the walk continues when
    the window returns.
    """
    await _reset(dut)
    imem, served = build_stream([(True, C_NOP)] * 5)
    h = Harness(dut, imem, Btb())
    await h.step()  # enqueue pc0
    ask_held = int(dut.o_ask_pc.value)
    for _ in range(3):
        exp = await h.step(win_valid=False)
        assert not exp["accept"]
        assert int(dut.o_ask_pc.value) == ask_held  # ask frozen
    n = len(h.enqueued)
    await h.step()  # window returns -> resume
    assert len(h.enqueued) == n + 1
    assert (h.enqueued[-1]["pc"] << 1) == served[1]["pc"]


@cocotb.test()
async def test_backpressure_holds_ask(dut: Any) -> None:
    """Queue backpressure holds the ask and suppresses enqueue."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP)] * 5)
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
    """Reject a valid window whose served_addr misses the outstanding ask.

    Tag-checked acceptance treats the mismatch as an unserved cycle; the ask
    holds and the correct window resumes the walk.
    """
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP)] * 4)
    h = Harness(dut, imem, Btb())
    await h.step()  # enqueue pc0, ask now pc2
    n = len(h.enqueued)
    ask_held = int(dut.o_ask_pc.value)
    exp = await h.step(served_override=0xDEAD_0000 | ((ask_held << 1) ^ 0x4))
    assert not exp["accept"] and len(h.enqueued) == n
    assert int(dut.o_ask_pc.value) == ask_held  # ask holds on mismatch
    await h.step()
    assert len(h.enqueued) == n + 1


@cocotb.test()
async def test_binding_not_leaked_across_redirect(dut: Any) -> None:
    """Guard the stale-at-birth analog (design 2.1.1 / finding 1).

    A redirect landing before a predicted branch is served must not leak that
    branch's binding onto the first post-redirect entry; the target's own
    binding applies.
    """
    await _reset(dut)
    imem, _ = build_stream([(True, 0x4501), (True, C_NOP)])
    tgt, _ = build_stream([(True, C_NOP)] * 2, base=0x200)
    other, _ = build_stream([(True, C_NOP)] * 2, base=0x300)
    imem.words.update(tgt.words)
    imem.words.update(other.words)
    btb = Btb()
    btb.taken[0x0] = 0x200
    h = Harness(dut, imem, btb)
    # Walk pc0 (cold), then redirect to 0 to arm pc0's taken binding.
    await h.step()
    await h.step(redir={"target": 0x0 >> 1, "partial": False})
    # ask==0, binding for 0 armed (taken->0x200).  Before serving pc0, redirect
    # elsewhere (0x300).  pc0 is NOT enqueued; the binding must not survive.
    exp = await h.step(redir={"target": 0x300 >> 1, "partial": False})
    assert not exp["accept"]
    assert exp["ask_d"] == 0x300
    # First post-redirect entry is 0x300 with its own (empty) binding.
    exp2 = await h.step()
    assert (exp2["entry"]["pc"] << 1) == 0x300
    assert exp2["entry"]["predicted_taken"] == 0
    assert exp2["entry"]["predicted_target"] == 0


@cocotb.test()
async def test_dir_metadata_bound(dut: Any) -> None:
    """Bind decoupled bimodal direction metadata from the ask-time lookup."""
    await _reset(dut)
    imem, _ = build_stream([(True, C_NOP)] * 4)
    btb = Btb()
    btb.dir[0x2] = (1, 0x2AB)  # pc2 carries a direction hint + index
    h = Harness(dut, imem, btb)
    await h.step()  # pc0 (cold)
    exp = await h.step()  # pc2 -- its lookup was armed last cycle
    assert exp["entry"]["pc"] << 1 == 0x2
    assert exp["entry"]["dir_taken"] == 1
    assert exp["entry"]["dir_idx"] == 0x2AB


# ---------------------------------------------------------------------------
# Randomized soak
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_randomized_soak(dut: Any) -> None:
    """Soak a random program with random freezes, backpressure, and redirects.

    Runs 4000 cycles of a random contiguous program with taken branches
    sprinkled into the BTB, checked against the reference model every cycle.
    """
    await _reset(dut)
    rng = random.Random(0xF111)

    imem = Imem()
    btb = Btb()
    for base in range(0, 0x800, 4):
        imem.words[base] = rng.choice(
            [C_NOP | (C_NOP << 16), N_NOP, 0x4501 | (0x4505 << 16)]
        )
    for _ in range(24):
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
