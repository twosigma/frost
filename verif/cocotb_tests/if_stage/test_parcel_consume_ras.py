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

"""Golden-model tests for the stage-2 consume-side RAS.

PARCEL_QUEUE_DESIGN.md section 2.4.  parcel_consume_ras wraps the (unchanged)
ras_detector + return_address_stack and drives them from the head/slot-1 queue
entry, with all side effects edge-triggered on DEQUEUE-FIRE.

The testbench co-simulates a Python model of the stack (matching
return_address_stack's push/pop/checkpoint semantics) plus the consume-side
gating, and checks the packet metadata + the return redirect every cycle.  The
underlying stack is separately verified by test_return_address_stack; here the
focus is the consume-side integration: dequeue-fire gating (the panel's
finding-3 no-refire-under-stall), the halfword/disable gates, and the redirect.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

CLOCK_PERIOD_NS = 10
RAS_DEPTH = 8

# pq_entry_t field offsets (only pc / instr_bytes / is_compressed matter here).
_OFF_PC = 79
_OFF_INSTR_BYTES = 47
_OFF_IS_COMPRESSED = 46

# 32-bit call / return / neutral instructions (ras_detector recognizes these).
CALL = 0x000000EF  # jal x1, 0        -> PUSH
RET = 0x00008067  # jalr x0, x1, 0    -> POP (return)
NEUTRAL = 0x00000013  # addi x0,x0,0   -> neither


def _pack_entry(pc_word: int, instr_bytes: int, is_compressed: int) -> int:
    """Pack the entry bits the RAS reads."""
    return (
        ((pc_word & 0x7FFFFFFF) << _OFF_PC)
        | ((instr_bytes & 0xFFFFFFFF) << _OFF_INSTR_BYTES)
        | ((is_compressed & 1) << _OFF_IS_COMPRESSED)
    )


class RasModel:
    """Model of return_address_stack (no-misprediction path) + consume gating."""

    def __init__(self, depth: int = RAS_DEPTH) -> None:
        """Create an empty stack."""
        self.depth = depth
        self.ram = [0] * depth
        self.tos = 0
        self.valid_count = 0

    @property
    def not_empty(self) -> bool:
        """Whether the stack has valid entries."""
        return self.valid_count != 0

    def target(self) -> int:
        """Return the combinational o_ras_target (= ram[tos])."""
        return self.ram[self.tos]

    def clock(self, *, push: bool, pop: bool, link: int) -> None:
        """Apply one edge (push has priority over pop, as in the RTL)."""
        if push:
            self.tos = (self.tos + 1) % self.depth
            self.ram[self.tos] = link
            if self.valid_count != self.depth:
                self.valid_count += 1
        elif pop:
            self.tos = (self.tos - 1) % self.depth
            self.valid_count -= 1


def _clear(dut: Any) -> None:
    dut.i_entry_valid.value = 0
    dut.i_entry0.value = 0
    dut.i_stall.value = 0
    dut.i_flush.value = 0
    dut.i_prediction_allowed.value = 1
    dut.i_ras_misprediction.value = 0
    dut.i_ras_restore_tos.value = 0
    dut.i_ras_restore_valid_count.value = 0
    dut.i_ras_pop_after_restore.value = 0
    dut.i_ras_push_after_restore.value = 0
    dut.i_ras_push_address_after_restore.value = 0


async def _settle() -> None:
    await Timer(1, unit="ns")


class Harness:
    """Drives the RAS one cycle and checks its outputs against the model."""

    def __init__(self, dut: Any) -> None:
        """Start the clock and reset the model."""
        self.dut = dut
        self.model = RasModel()
        self.cycle = 0

    async def reset(self) -> None:
        """Pulse reset and clear inputs."""
        cocotb.start_soon(Clock(self.dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
        _clear(self.dut)
        self.dut.i_rst.value = 1
        await RisingEdge(self.dut.i_clk)
        await FallingEdge(self.dut.i_clk)
        self.dut.i_rst.value = 0
        await _settle()

    async def step(
        self,
        *,
        instr: int | None = None,
        pc_word: int = 0x100 >> 1,
        is_compressed: int = 0,
        valid: bool = True,
        stall: bool = False,
        flush: bool = False,
        pred_allowed: bool = True,
        ctx: str = "",
    ) -> dict[str, int]:
        """Drive one cycle, check the outputs, and advance the model."""
        dut, m = self.dut, self.model
        ctx = ctx or f"cycle {self.cycle}"

        head_valid = instr is not None
        if instr is not None:
            dut.i_entry0.value = _pack_entry(pc_word, instr, is_compressed)
        else:
            dut.i_entry0.value = 0
        dut.i_entry_valid.value = 1 if (head_valid and valid) else 0
        dut.i_stall.value = 1 if stall else 0
        dut.i_flush.value = 1 if flush else 0
        dut.i_prediction_allowed.value = 1 if pred_allowed else 0
        await _settle()

        # Reference computation (matches the RTL gating).
        slot1_present = bool(head_valid and valid) and not flush
        dequeue_fire = slot1_present and not stall
        pc_bit1 = (pc_word >> 0) & 1  # pc_word is [31:1]; its bit 0 is address bit 1
        # CALL/RET are 32-bit encodings (quadrant 11); when is_compressed is
        # set, ras_detector reads their low 16 bits as a compressed parcel,
        # which is not a call/return -- so they only count when not compressed.
        is_call = instr == CALL and not is_compressed
        is_return = instr == RET and not is_compressed
        lookup_allowed = pred_allowed and (not pc_bit1 or bool(is_compressed))
        effect_allowed = lookup_allowed and dequeue_fire
        ras_valid = is_return and m.not_empty
        exp_predicted = 1 if (slot1_present and lookup_allowed and ras_valid) else 0
        exp_target = m.target()
        exp_redirect = 1 if (exp_predicted and dequeue_fire) else 0

        assert (
            int(dut.o_ras_predicted.value) == exp_predicted
        ), f"{ctx}: ras_predicted={int(dut.o_ras_predicted.value)} want {exp_predicted}"
        assert (
            int(dut.o_ras_checkpoint_tos.value) == m.tos
        ), f"{ctx}: checkpoint_tos={int(dut.o_ras_checkpoint_tos.value)} want {m.tos}"
        assert int(dut.o_ras_checkpoint_valid_count.value) == m.valid_count, (
            f"{ctx}: valid_count={int(dut.o_ras_checkpoint_valid_count.value)} "
            f"want {m.valid_count}"
        )
        assert (
            int(dut.o_ras_redirect_valid.value) == exp_redirect
        ), f"{ctx}: redirect_valid={int(dut.o_ras_redirect_valid.value)} want {exp_redirect}"
        if exp_predicted:
            assert (
                (int(dut.o_ras_predicted_target.value)) == exp_target
            ), f"{ctx}: target={int(dut.o_ras_predicted_target.value):#x} want {exp_target:#x}"
        if exp_redirect:
            assert (
                int(dut.o_ras_redirect_target.value) << 1
            ) == exp_target, f"{ctx}: redirect_target mismatch"

        # Model side effects (dequeue-fire gated).
        do_push = bool(is_call) and effect_allowed
        do_pop = bool(is_return) and effect_allowed and m.not_empty
        link = (pc_word << 1) + (2 if is_compressed else 4)

        await RisingEdge(dut.i_clk)
        m.clock(push=do_push, pop=do_pop, link=link)
        await _settle()
        self.cycle += 1
        return {
            "predicted": exp_predicted,
            "redirect": exp_redirect,
            "target": exp_target,
        }


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_reset_empty(dut: Any) -> None:
    """After reset the stack is empty and predicts nothing."""
    h = Harness(dut)
    await h.reset()
    exp = await h.step(instr=RET, ctx="empty-return")  # return with empty stack
    assert exp["predicted"] == 0 and exp["redirect"] == 0


@cocotb.test()
async def test_call_then_return(dut: Any) -> None:
    """A call pushes its link; a later return predicts it and redirects."""
    h = Harness(dut)
    await h.reset()
    await h.step(instr=CALL, pc_word=0x100 >> 1, ctx="call")  # push link 0x104
    await h.step(instr=NEUTRAL, pc_word=0x200 >> 1, ctx="neutral")
    exp = await h.step(instr=RET, pc_word=0x300 >> 1, ctx="return")
    assert exp["predicted"] == 1 and exp["redirect"] == 1
    assert exp["target"] == 0x104  # the pushed link (call pc 0x100 + 4)
    # Stack now empty: a second return predicts nothing.
    exp2 = await h.step(instr=RET, pc_word=0x400 >> 1, ctx="return2")
    assert exp2["predicted"] == 0


@cocotb.test()
async def test_no_side_effects_under_stall(dut: Any) -> None:
    """Hold a return under stall: it must not pop or re-fire (finding 3).

    The redirect fires exactly once, when the return finally retires.
    """
    h = Harness(dut)
    await h.reset()
    await h.step(instr=CALL, pc_word=0x10 >> 1, ctx="call")  # push 0x14
    vc_before = h.model.valid_count
    fires = 0
    for i in range(4):  # hold the return under stall
        exp = await h.step(instr=RET, pc_word=0x20 >> 1, stall=True, ctx=f"stall-{i}")
        assert exp["redirect"] == 0  # no redirect under stall
        assert h.model.valid_count == vc_before  # no pop
        fires += exp["redirect"]
    assert fires == 0
    # Release: the return retires -> redirect fires once, pops.
    exp = await h.step(instr=RET, pc_word=0x20 >> 1, ctx="release")
    assert exp["redirect"] == 1 and exp["target"] == 0x14
    assert h.model.valid_count == vc_before - 1


@cocotb.test()
async def test_prediction_disabled(dut: Any) -> None:
    """i_prediction_allowed=0 suppresses predict / push / pop."""
    h = Harness(dut)
    await h.reset()
    # A call while disabled does not push.
    await h.step(instr=CALL, pc_word=0x10 >> 1, pred_allowed=False, ctx="call-disabled")
    assert h.model.valid_count == 0
    # A return while disabled does not predict, even after a real push.
    await h.step(instr=CALL, pc_word=0x20 >> 1, ctx="call")  # push 0x24
    exp = await h.step(instr=RET, pc_word=0x30 >> 1, pred_allowed=False, ctx="ret-dis")
    assert exp["predicted"] == 0 and exp["redirect"] == 0
    assert h.model.valid_count == 1  # not popped


@cocotb.test()
async def test_halfword_native_return_not_predicted(dut: Any) -> None:
    """A 32-bit return at a halfword PC is not predicted (halfword gate)."""
    h = Harness(dut)
    await h.reset()
    await h.step(instr=CALL, pc_word=0x40 >> 1, ctx="call")  # push 0x44
    # Return at a halfword PC (bit 1 set), 32-bit -> gated off.
    exp = await h.step(instr=RET, pc_word=0x102 >> 1, is_compressed=0, ctx="hw-return")
    assert exp["predicted"] == 0 and exp["redirect"] == 0
    assert h.model.valid_count == 1  # not popped (effect gated)


@cocotb.test()
async def test_flush_inert(dut: Any) -> None:
    """A flush makes the head absent: no prediction, no side effects."""
    h = Harness(dut)
    await h.reset()
    await h.step(instr=CALL, pc_word=0x50 >> 1, ctx="call")  # push 0x54
    exp = await h.step(instr=RET, pc_word=0x60 >> 1, flush=True, ctx="flushed-return")
    assert exp["predicted"] == 0 and exp["redirect"] == 0
    assert h.model.valid_count == 1  # not popped


# ---------------------------------------------------------------------------
# Randomized soak
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_randomized_soak(dut: Any) -> None:
    """Soak random call/return/neutral streams with stalls and flushes."""
    h = Harness(dut)
    await h.reset()
    rng = random.Random(0x2A5)
    for i in range(3000):
        r = rng.random()
        instr = CALL if r < 0.35 else (RET if r < 0.7 else NEUTRAL)
        pc_word = (
            rng.getrandbits(30) << 1 | (1 if rng.random() < 0.2 else 0)
        ) & 0x7FFFFFFF
        await h.step(
            instr=instr,
            pc_word=pc_word,
            is_compressed=1 if rng.random() < 0.3 else 0,
            valid=rng.random() > 0.1,
            stall=rng.random() < 0.15,
            flush=rng.random() < 0.05,
            pred_allowed=rng.random() > 0.1,
            ctx=f"soak-{i}",
        )
