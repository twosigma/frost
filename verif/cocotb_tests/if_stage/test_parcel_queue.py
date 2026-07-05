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

"""Unit tests for the stage-2 parcel queue (PARCEL_QUEUE_DESIGN.md 2.2).

The queue is payload-transparent, so entries are driven as random
ENTRY_BITS-wide integers and checked bit-exactly against a golden model.
The model mirrors the RTL contract: the presented view is the first two of
(array in FIFO order, then this cycle's incoming enqueue); full and partial
flushes dominate same-cycle enqueue.
"""

import random
from typing import Any

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

CLOCK_PERIOD_NS = 10
DEPTH = 8
HEADROOM = 4
ENTRY_BITS = 110


class QueueModel:
    """Golden model of the parcel queue's presented view and update rule."""

    def __init__(self) -> None:
        """Create an empty queue."""
        self.array: list[int] = []

    def presented(self, incoming: list[int]) -> list[int]:
        """Return the combinational FWFT view for this cycle."""
        return (self.array + incoming)[:2]

    def update(
        self,
        incoming: list[int],
        deq: int,
        *,
        flush_full: bool = False,
        flush_partial: bool = False,
    ) -> None:
        """Apply one clock edge."""
        if flush_full or flush_partial:
            self.array = []
            return
        combined = self.array + incoming
        self.array = combined[deq:]


def _random_entry(rng: random.Random) -> int:
    return rng.getrandbits(ENTRY_BITS)


def _clear_inputs(dut: Any) -> None:
    dut.i_enq_valid.value = 0
    dut.i_enq_entry0.value = 0
    dut.i_enq_entry1.value = 0
    dut.i_deq_count.value = 0
    dut.i_flush_full.value = 0
    dut.i_flush_partial.value = 0


async def _settle() -> None:
    await Timer(1, unit="ns")


async def _setup_test(dut: Any) -> None:
    cocotb.start_soon(Clock(dut.i_clk, CLOCK_PERIOD_NS, unit="ns").start())
    _clear_inputs(dut)
    dut.i_rst.value = 1
    await RisingEdge(dut.i_clk)
    await FallingEdge(dut.i_clk)
    dut.i_rst.value = 0
    await _settle()


def _drive_cycle_inputs(
    dut: Any,
    incoming: list[int],
    deq: int,
    *,
    flush_full: bool = False,
    flush_partial: bool = False,
) -> None:
    assert len(incoming) <= 2
    dut.i_enq_valid.value = (1 if len(incoming) >= 1 else 0) | (
        2 if len(incoming) >= 2 else 0
    )
    dut.i_enq_entry0.value = incoming[0] if len(incoming) >= 1 else 0
    dut.i_enq_entry1.value = incoming[1] if len(incoming) >= 2 else 0
    dut.i_deq_count.value = deq
    dut.i_flush_full.value = int(flush_full)
    dut.i_flush_partial.value = int(flush_partial)


def _check_presented(
    dut: Any, model: QueueModel, incoming: list[int], context: str
) -> None:
    presented = model.presented(incoming)
    got_valid = int(dut.o_entry_valid.value)
    want_valid = (1 if len(presented) >= 1 else 0) | (2 if len(presented) >= 2 else 0)
    assert got_valid == want_valid, (
        f"{context}: o_entry_valid={got_valid:#x}, want {want_valid:#x} "
        f"(array={len(model.array)}, incoming={len(incoming)})"
    )
    if len(presented) >= 1:
        assert int(dut.o_entry0.value) == presented[0], f"{context}: o_entry0 mismatch"
    if len(presented) >= 2:
        assert int(dut.o_entry1.value) == presented[1], f"{context}: o_entry1 mismatch"
    assert int(dut.o_count.value) == len(
        model.array
    ), f"{context}: o_count={int(dut.o_count.value)}, model array={len(model.array)}"
    want_bp = (DEPTH - len(model.array)) < HEADROOM
    assert (
        bool(dut.o_backpressure.value) is want_bp
    ), f"{context}: o_backpressure={bool(dut.o_backpressure.value)}, want {want_bp}"


async def _step(
    dut: Any,
    model: QueueModel,
    incoming: list[int],
    deq: int,
    *,
    flush_full: bool = False,
    flush_partial: bool = False,
    context: str = "step",
) -> None:
    """Drive one cycle, check the combinational view, commit the edge."""
    _drive_cycle_inputs(
        dut, incoming, deq, flush_full=flush_full, flush_partial=flush_partial
    )
    await _settle()
    _check_presented(dut, model, incoming, context)
    await RisingEdge(dut.i_clk)
    model.update(incoming, deq, flush_full=flush_full, flush_partial=flush_partial)
    await _settle()


@cocotb.test()
async def test_reset_state(dut: Any) -> None:
    """After reset: empty, nothing presented, no backpressure."""
    await _setup_test(dut)
    assert int(dut.o_entry_valid.value) == 0
    assert int(dut.o_count.value) == 0
    assert bool(dut.o_backpressure.value) is False


@cocotb.test()
async def test_fwft_single(dut: Any) -> None:
    """Present and consume an arriving entry in the same cycle.

    An entry enqueued into an empty queue is presented combinationally and
    can be dequeued that cycle (the refill-latency-parity property).
    """
    await _setup_test(dut)
    model = QueueModel()
    rng = random.Random(1)
    entry = _random_entry(rng)
    await _step(dut, model, [entry], 1, context="fwft-single")
    assert model.array == []
    await _step(dut, model, [], 0, context="fwft-single-after")


@cocotb.test()
async def test_fwft_double_take_both(dut: Any) -> None:
    """Present a 2-wide enqueue into an empty queue and take both.

    Both incoming entries are visible combinationally and consumed the
    same cycle.
    """
    await _setup_test(dut)
    model = QueueModel()
    rng = random.Random(2)
    entries = [_random_entry(rng), _random_entry(rng)]
    await _step(dut, model, entries, 2, context="fwft-double")
    await _step(dut, model, [], 0, context="fwft-double-after")


@cocotb.test()
async def test_fwft_double_take_none(dut: Any) -> None:
    """Store bypassed-but-not-consumed entries into the array.

    Entries presented via fall-through but not dequeued re-present
    identically from flops the next cycle.
    """
    await _setup_test(dut)
    model = QueueModel()
    rng = random.Random(3)
    entries = [_random_entry(rng), _random_entry(rng)]
    await _step(dut, model, entries, 0, context="fwft-store")
    await _step(dut, model, [], 2, context="fwft-store-drain")


@cocotb.test()
async def test_partial_fallthrough_pairing(dut: Any) -> None:
    """Pair an array-resident entry with a same-cycle incoming entry.

    The one-deep fall-through case: slot 1 from flops, slot 2 from the
    live enqueue.
    """
    await _setup_test(dut)
    model = QueueModel()
    rng = random.Random(4)
    first = _random_entry(rng)
    second = _random_entry(rng)
    await _step(dut, model, [first], 0, context="pair-preload")
    await _step(dut, model, [second], 2, context="pair-mixed")
    assert model.array == []


@cocotb.test()
async def test_backpressure_threshold(dut: Any) -> None:
    """Backpressure asserts exactly when free slots drop below HEADROOM."""
    await _setup_test(dut)
    model = QueueModel()
    rng = random.Random(5)
    threshold = DEPTH - HEADROOM + 1  # smallest occupancy with backpressure
    while len(model.array) < threshold - 1:
        await _step(dut, model, [_random_entry(rng)], 0, context="bp-fill")
    assert bool(dut.o_backpressure.value) is False
    await _step(dut, model, [_random_entry(rng)], 0, context="bp-cross")
    assert bool(dut.o_backpressure.value) is True
    await _step(dut, model, [], 1, context="bp-release")
    assert bool(dut.o_backpressure.value) is False


@cocotb.test()
async def test_full_flush_dominates_enqueue(dut: Any) -> None:
    """Leave the queue empty on a flush coincident with a 2-wide enqueue.

    The panel's phantom-entry race (review record finding 4): flush must
    dominate the same-cycle enqueue with an atomic pointer reset.
    """
    await _setup_test(dut)
    model = QueueModel()
    rng = random.Random(6)
    await _step(
        dut, model, [_random_entry(rng), _random_entry(rng)], 0, context="ff-preload"
    )
    entries = [_random_entry(rng), _random_entry(rng)]
    await _step(dut, model, entries, 0, flush_full=True, context="ff-flush")
    assert model.array == []
    # Stop driving the flush-cycle enqueue before checking emptiness: the
    # FWFT view legitimately presents still-driven incoming entries.
    _clear_inputs(dut)
    await _settle()
    assert int(dut.o_entry_valid.value) == 0
    assert int(dut.o_count.value) == 0
    # Pointer reset sanity: the queue behaves normally afterwards.
    fresh = [_random_entry(rng), _random_entry(rng)]
    await _step(dut, model, fresh, 1, context="ff-after")
    await _step(dut, model, [], 1, context="ff-drain")
    assert model.array == []


@cocotb.test()
async def test_partial_flush_dequeue_fire(dut: Any) -> None:
    """Emit the head return on a partial flush and kill everything younger.

    The RAS dequeue-fire pulse: the head entry emits on the firing cycle;
    younger array entries and the same-cycle enqueue die.
    """
    await _setup_test(dut)
    model = QueueModel()
    rng = random.Random(7)
    ret = _random_entry(rng)
    younger = [_random_entry(rng) for _ in range(3)]
    await _step(dut, model, [ret], 0, context="pf-preload-ret")
    await _step(dut, model, younger[:2], 0, context="pf-preload-y01")
    await _step(dut, model, younger[2:], 0, context="pf-preload-y2")
    # Dequeue-fire cycle: head presented must be the return; wrong-path
    # sequential entries arrive the same cycle and must be suppressed.
    _drive_cycle_inputs(dut, [_random_entry(rng)], 1, flush_partial=True)
    await _settle()
    assert int(dut.o_entry_valid.value) & 1
    assert int(dut.o_entry0.value) == ret
    await RisingEdge(dut.i_clk)
    model.update([], 0, flush_partial=True)
    await _settle()
    _clear_inputs(dut)
    await _settle()
    assert int(dut.o_count.value) == 0
    assert int(dut.o_entry_valid.value) == 0
    # Pointer meet-point sanity: subsequent traffic behaves.
    fresh = [_random_entry(rng)]
    await _step(dut, model, fresh, 1, context="pf-after")
    assert model.array == []


@cocotb.test()
async def test_full_flush_wins_over_partial(dut: Any) -> None:
    """Coincident full + partial flush resolves to the full reset."""
    await _setup_test(dut)
    model = QueueModel()
    rng = random.Random(8)
    await _step(
        dut, model, [_random_entry(rng), _random_entry(rng)], 0, context="fw-preload"
    )
    await _step(
        dut,
        model,
        [_random_entry(rng)],
        1,
        flush_full=True,
        flush_partial=True,
        context="fw-both",
    )
    assert model.array == []
    assert int(dut.o_count.value) == 0
    await _step(dut, model, [_random_entry(rng)], 1, context="fw-after")


@cocotb.test()
async def test_stall_immobility(dut: Any) -> None:
    """Hold the presented bundle bit-stable while dequeue is zero.

    A downstream stall must re-present the identical bundle — the stage-2
    replacement for the _sc replay apparatus.
    """
    await _setup_test(dut)
    model = QueueModel()
    rng = random.Random(9)
    entries = [_random_entry(rng), _random_entry(rng)]
    await _step(dut, model, entries, 0, context="stall-preload")
    for cycle in range(5):
        await _step(dut, model, [], 0, context=f"stall-hold-{cycle}")
        assert int(dut.o_entry0.value) == entries[0]
        assert int(dut.o_entry1.value) == entries[1]
    await _step(dut, model, [], 2, context="stall-release")
    assert model.array == []


@cocotb.test()
async def test_randomized_soak(dut: Any) -> None:
    """Soak randomized enqueue/dequeue/flush traffic against the model.

    Exercises wraparound, mixed fall-through pairing, and both flush
    kinds over 3000 cycles.
    """
    await _setup_test(dut)
    model = QueueModel()
    rng = random.Random(0xF057)
    for cycle in range(3000):
        free = DEPTH - len(model.array)
        max_enq = min(2, free)
        enq_n = rng.choice([0, 1, 2, 2, 1])
        enq_n = min(enq_n, max_enq)
        incoming = [_random_entry(rng) for _ in range(enq_n)]
        presented_n = len(model.presented(incoming))
        flush_full = rng.random() < 0.03
        flush_partial = False
        if not flush_full and presented_n >= 1 and rng.random() < 0.03:
            flush_partial = True
            deq = 1
        else:
            deq = rng.randint(0, presented_n)
        await _step(
            dut,
            model,
            incoming,
            deq,
            flush_full=flush_full,
            flush_partial=flush_partial,
            context=f"soak-{cycle}",
        )
    # Drain and verify residue.
    while model.presented([]):
        await _step(dut, model, [], 1, context="soak-drain")
    assert int(dut.o_count.value) == 0
