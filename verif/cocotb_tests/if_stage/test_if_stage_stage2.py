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

"""Smoke test for the stage-2 integrated front end (if_stage_stage2).

Drives the provider seam (o_pc -> one-cycle-latency window over a NOP memory)
with branch prediction disabled, and checks that the fill -> queue -> consume
dataflow delivers IF->PD packets with contiguous PCs.  A second test asserts a
backend branch redirect and checks the walk resteers.  This validates the
integration wiring end-to-end; functional parity vs HEAD is the coremark gate
at the atomic swap.
"""

from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

CLOCK_PERIOD_NS = 10
NOP = 0x00000013  # addi x0,x0,0 (32-bit)

# from_if_to_pd_t packed layout (see test_parcel_consume_engine).
_PKT_DECL = [
    ("program_counter", 32),
    ("raw_parcel", 16),
    ("sel_nop", 1),
    ("sel_compressed", 1),
    ("effective_instr", 32),
    ("link_address", 32),
    ("btb_hit", 1),
    ("btb_predicted_taken", 1),
    ("btb_predicted_target", 32),
    ("ras_predicted", 1),
    ("ras_predicted_target", 32),
    ("ras_checkpoint_tos", 3),
    ("ras_checkpoint_valid_count", 4),
    ("bp_dir_taken", 1),
    ("bp_dir_idx", 10),
    ("decomp_illegal", 1),
]


def _pkt_offsets() -> dict[str, tuple[int, int]]:
    off: dict[str, tuple[int, int]] = {}
    pos = 0
    for name, width in reversed(_PKT_DECL):
        off[name] = (pos, width)
        pos += width
    return off


_PKT_OFF = _pkt_offsets()


def unpack_packet(v: int) -> dict[str, int]:
    """Extract from_if_to_pd_t fields."""
    return {
        name: (v >> off) & ((1 << width) - 1) for name, (off, width) in _PKT_OFF.items()
    }


# pipeline_ctrl_t bit positions (MSB-first packed struct).
def pack_pipeline_ctrl(*, reset: int = 0, stall: int = 0, flush: int = 0) -> int:
    """Pack pipeline_ctrl_t (only the fields the test drives)."""
    return (reset << 6) | (stall << 5) | (flush << 2)


def pack_from_ex_comb(*, branch_taken: int = 0, branch_target: int = 0) -> int:
    """Pack from_ex_comb_t (only branch_taken / branch_target)."""
    return (branch_taken << 142) | ((branch_target & 0xFFFFFFFF) << 110)


class NopMem:
    """Backing memory: every word is a 32-bit NOP unless overridden."""

    def __init__(self) -> None:
        """Create the memory."""
        self.words: dict[int, int] = {}

    def window(self, served_addr: int) -> int:
        """Return the 64-bit {word+1, word} window for served_addr."""
        wa = served_addr & ~0x3
        low = self.words.get(wa, NOP)
        high = self.words.get(wa + 4, NOP)
        return (high << 32) | low


async def _settle() -> None:
    await Timer(1, unit="ns")


def _drive_idle(dut: Any) -> None:
    dut.i_from_ex_comb.value = 0
    dut.i_trap_ctrl.value = 0
    dut.i_frontend_state_flush.value = 0
    dut.i_fence_i_flush.value = 0
    dut.i_fence_i_target.value = 0
    dut.i_disable_branch_prediction.value = 1  # sequential walk
    dut.i_dir_update_valid.value = 0
    dut.i_dir_update_idx.value = 0
    dut.i_dir_update_taken.value = 0
    dut.i_pd_redirect.value = 0
    dut.i_pd_redirect_target.value = 0
    dut.i_instr_bank_sel_r.value = 0


async def _reset(dut: Any) -> None:
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _drive_idle(dut)
    dut.i_pipeline_ctrl.value = pack_pipeline_ctrl(reset=1)
    dut.i_instr.value = 0
    dut.i_instr_sideband.value = 0
    dut.i_served_addr.value = 0
    dut.i_instr_valid.value = 0
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_pipeline_ctrl.value = 0
    await _settle()


class Fixture:
    """Drives the provider seam and collects delivered packets."""

    def __init__(self, dut: Any, mem: NopMem) -> None:
        """Bind the DUT to a backing memory."""
        self.dut = dut
        self.mem = mem
        self.served_q = 0  # ask registered last cycle -> served this cycle
        self.delivered: list[int] = []  # program counters, in delivery order

    async def cycle(
        self, *, branch_taken: int = 0, branch_target: int = 0, valid: int = 1
    ) -> None:
        """Serve the outstanding ask's window, capture packets, advance."""
        dut = self.dut
        # Compute the sideband for the served window in RTL (predecode is inside
        # the fetch path normally); here the memory is NOPs so drive zero
        # sideband -- is_compressed etc. are read from bytes-derived sideband,
        # but for NOP (native) the sideband bits we need are all 0 anyway.
        instr = self.mem.window(self.served_q)
        dut.i_served_addr.value = self.served_q
        dut.i_instr.value = instr
        dut.i_instr_sideband.value = _nop_window_sideband(instr)
        dut.i_instr_valid.value = valid
        dut.i_pipeline_ctrl.value = pack_pipeline_ctrl()
        dut.i_from_ex_comb.value = pack_from_ex_comb(
            branch_taken=branch_taken, branch_target=branch_target
        )
        await _settle()

        for sig in (dut.o_from_if_to_pd, dut.o_from_if_to_pd_2):
            pkt = unpack_packet(int(sig.value))
            if not pkt["sel_nop"]:
                self.delivered.append(pkt["program_counter"])

        new_ask = int(dut.o_pc.value)
        await RisingEdge(dut.i_clk)
        self.served_q = new_ask
        await _settle()


def _sideband12(word: int) -> int:
    """Minimal riscv_pkg sideband for a 32-bit word (NOP stream)."""
    is_c_lo = (word & 0x3) != 0x3
    is_c_hi = ((word >> 16) & 0x3) != 0x3
    # slot2_start_valid = is_compressed || !(serialize||fp); NOP is neither.
    s2_lo = 1 if is_c_lo else 1
    s2_hi = 1 if is_c_hi else 1
    sb = 0
    sb |= is_c_lo << 0
    sb |= is_c_hi << 1
    sb |= s2_lo << 10
    sb |= s2_hi << 11
    return sb


def _nop_window_sideband(instr64: int) -> int:
    """Sideband for the two words of a window (low + high)."""
    low = instr64 & 0xFFFFFFFF
    high = (instr64 >> 32) & 0xFFFFFFFF
    return (_sideband12(high) << 12) | _sideband12(low)


@cocotb.test()
async def test_sequential_walk(dut: Any) -> None:
    """A NOP stream (prediction off) delivers contiguous PCs from 0."""
    await _reset(dut)
    fx = Fixture(dut, NopMem())
    for _ in range(24):
        await fx.cycle()
    # Some packets must have been delivered, contiguous from 0 in +4 steps.
    assert len(fx.delivered) >= 8, f"only {len(fx.delivered)} packets delivered"
    for i, pc in enumerate(fx.delivered[:8]):
        assert pc == 4 * i, f"packet {i}: pc={pc:#x} want {4 * i:#x}"


@cocotb.test()
async def test_branch_redirect(dut: Any) -> None:
    """A backend branch redirect resteers the walk to the target."""
    await _reset(dut)
    fx = Fixture(dut, NopMem())
    for _ in range(6):
        await fx.cycle()
    n_before = len(fx.delivered)
    # Redirect to 0x400; then run and check delivered PCs continue from 0x400.
    await fx.cycle(branch_taken=1, branch_target=0x400)
    for _ in range(12):
        await fx.cycle()
    after = fx.delivered[n_before:]
    targets = [pc for pc in after if pc >= 0x400]
    assert (
        targets
    ), f"no packets from the redirect target; got {[hex(p) for p in after]}"
    assert (
        targets[0] == 0x400
    ), f"first post-redirect target pc={targets[0]:#x} want 0x400"
