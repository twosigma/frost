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

"""Directed decoupled-fetch schedules and replay execution dependencies."""

import dataclasses
import importlib
from typing import Any

import pytest

from test_perf_model import model

front = importlib.import_module("fetch_frontend")
stream = importlib.import_module("instruction_stream")


def program(lengths: list[int], start: int = 0) -> list[Any]:
    """Build a sequential mix of C.NOP and ADDI with no data dependencies."""
    result = []
    pc = start
    for index, length in enumerate(lengths):
        raw = b"\x01\x00" if length == 2 else b"\x13\x00\x00\x00"
        result.append(
            stream.Instruction(
                index,
                pc,
                raw,
                0x13,
                "alu",
                (),
                0,
                None,
                0,
                False,
                pc + length,
                None,
                (),
            )
        )
        pc += length
    return result


def run_frontend(fe: Any, cycles: int = 200) -> tuple[list[int], list[int]]:
    """Drain decoded bundles each cycle and return IDs with delivery cycles."""
    ids: list[int] = []
    stamps: list[int] = []
    for cycle in range(cycles):
        fe.step(cycle)
        if fe.decoded:
            bundle = fe.decoded[0]
            ids.extend(i.index for i in bundle)
            stamps.extend([cycle] * len(bundle))
            fe.consume(len(bundle))
        if len(ids) == len(fe.program):
            break
    return ids, stamps


def test_fetch_runs_ahead_of_decode_and_stops_with_reserved_headroom() -> None:
    """Decode stall permits F0/F1 to fill 12 parcels before registered stop."""
    fe = front.FetchFrontend(program([4] * 64))
    for cycle in range(20):
        fe.step(cycle, decode_ready=False)
    assert fe.cursor == (6, 0)
    assert len(fe.queue.parcels) == 12
    assert fe.queue.metadata_count == 3
    assert fe.stats["run_ahead_launches"] == 3
    assert fe.queue.stop
    ids: list[int] = []
    for cycle in range(20, 150):
        fe.step(cycle)
        if fe.decoded:
            bundle = fe.decoded[0]
            ids.extend(i.index for i in bundle)
            fe.consume(len(bundle))
    assert ids == list(range(64))


def test_metadata_saturates_before_parcels_for_short_taken_windows() -> None:
    """Eight one-parcel windows fit; the registered stop trips at seven."""
    ops = program([2] * 20)
    for index, insn in enumerate(ops):
        target = (index + 1) * 16
        ops[index] = dataclasses.replace(
            insn,
            pc=index * 16,
            kind="branch",
            taken=True,
            next_pc=target,
            prediction=stream.Prediction(True, target, "none", True, target, False),
        )
    fe = front.FetchFrontend(ops)
    for cycle in range(20):
        fe.step(cycle, decode_ready=False)
    assert len(fe.queue.parcels) == 8
    assert fe.queue.metadata_count == 8
    assert fe.queue.stop
    fe.queue.flush()
    assert not fe.queue.stop and fe.queue.metadata_count == 0


def test_parcel_capacity_is_distinct_from_stop_threshold() -> None:
    """Registered stop reserves room for arrivals; the physical ring still has 16 slots."""
    queue = front.ParcelQueue()
    for window in range(4):
        queue.push([front.Parcel(window * 4 + p, 0, window, p == 3) for p in range(4)])
        queue.clock()
        assert queue.stop == (window >= 1)
    assert len(queue.parcels) == 16 and queue.metadata_count == 4
    with pytest.raises(OverflowError, match="capacity"):
        queue.push([front.Parcel(16, 0, 4, True)])


def test_empty_bypass_has_no_queue_cycle_and_f0_overlaps_f1() -> None:
    """Two 32-bit instructions reach PD on cycle 1 and dispatch on cycle 3."""
    fe = front.FetchFrontend(program([4] * 8))
    ids, stamps = run_frontend(fe)
    assert ids == list(range(8))
    assert stamps == [3, 3, 4, 4, 5, 5, 6, 6]
    assert fe.queue.max_parcels == 0
    assert fe.stats["empty_bypass"] == 4


@pytest.mark.parametrize(
    "lengths,start", [([2, 4, 4, 2, 4], 0), ([4, 4, 2, 4], 2), ([2, 2, 2, 4, 2, 4], 0)]
)
def test_partial_bypass_compression_and_spanning(
    lengths: list[int], start: int
) -> None:
    """Every byte is consumed once, including a native instruction split over windows."""
    fe = front.FetchFrontend(program(lengths, start))
    ids, _ = run_frontend(fe)
    assert ids == list(range(len(lengths)))
    assert fe.stats["drained_parcels"] == sum(lengths) // 2
    assert fe.stats["partial_bypass"] > 0


@pytest.mark.parametrize("lengths", [[4, 4], [2, 4], [2, 2, 2, 4]])
def test_predicted_taken_can_span_and_never_pairs_past_branch(
    lengths: list[int],
) -> None:
    """A branch truncates its window, fetching its target without a recovery bubble."""
    ops = program(lengths)
    branch = ops[-1]
    ops[-1] = dataclasses.replace(
        branch,
        kind="branch",
        taken=True,
        next_pc=64,
        prediction=stream.Prediction(True, 64, "none", True, 64, False),
    )
    target = program([4, 4], start=64)
    ops.extend(dataclasses.replace(i, index=len(lengths) + i.index) for i in target)
    fe = front.FetchFrontend(ops)
    ids, _ = run_frontend(fe)
    assert ids == list(range(len(ops)))
    assert not any(k.startswith("redirect_") for k in fe.stats)
    assert fe.stats["f0_taken"] == 1


@pytest.mark.parametrize("tier", ["pd_direction", "pd_backing", "pd_ittage"])
def test_pd_redirect_preserves_its_branch_and_refetches_target(tier: str) -> None:
    """PD corrects an F0 miss; the branch and all older decoded packets survive."""
    ops = program([4, 4, 4])
    ops[1] = dataclasses.replace(
        ops[1],
        kind="branch",
        taken=True,
        next_pc=64,
        prediction=stream.Prediction(False, 0, tier, True, 64, False),
    )
    ops[2] = dataclasses.replace(ops[2], pc=64, next_pc=68)
    fe = front.FetchFrontend(ops)
    ids, stamps = run_frontend(fe)
    assert ids == [0, 1, 2]
    assert stamps == [3, 3, 6]
    assert fe.stats["redirect_pd"] == 1
    assert fe.stats[tier] == 1


@pytest.mark.parametrize("kind", front.REDIRECT_PRIORITY)
def test_redirect_classes_and_provider_retarget(kind: str) -> None:
    """Arms 1..4 flush fetch storage; F1 validation keeps older queued parcels."""
    fe = front.FetchFrontend(program([4] * 20))
    fe.step(0, decode_ready=False)
    fe.step(1, decode_ready=False)
    assert fe.f1 is not None and len(fe.queue.parcels) == 4
    fe.pd = (fe.program[0],)
    fe.id = (fe.program[1],)
    fe.decoded.append((fe.program[2],))
    fe.request_redirect(kind, 10)
    fe.step(2)
    assert fe.f1 is None and fe.cursor == (10, 0)
    assert fe.retarget_until == 3
    assert len(fe.queue.parcels) == (4 if kind.startswith("f1_") else 0)
    assert bool(fe.decoded) == (kind not in {"trap", "fence", "execute"})
    assert fe.stats[f"redirect_{kind}"] == 1


def test_redirect_priority_and_stale_provider_replies() -> None:
    """Trap beats every younger redirect, and neither stale epoch nor tag is admitted."""
    fe = front.FetchFrontend(program([4] * 20))
    fe.step(0)
    stale = fe.f1
    for kind in reversed(front.REDIRECT_PRIORITY):
        fe.request_redirect(kind, 4)
    fe.step(1)
    assert fe.stats["redirect_trap"] == 1
    fe.f1 = stale
    fe.step(2)
    assert fe.stats["stale_provider_reply"] == 1
    assert fe.f1.pc == 16
    fe.f1.served_pc = 0
    fe.step(3)
    assert fe.stats["redirect_f1_tag"] == 1
    assert not fe.queue.parcels and fe.cursor == (4, 0)


def test_refill_keeps_prediction_and_accepts_on_data_cycle() -> None:
    """A five-cycle refill overlaps the one-cycle lookup and immediately bypasses to PD."""
    fe = front.FetchFrontend(program([4, 4]), provider_latency=lambda _pc: 5)
    for cycle in range(5):
        fe.step(cycle)
        assert not fe.pd
    fe.step(5)
    assert [i.index for i in fe.pd] == [0, 1]
    assert fe.f1 is None
    assert fe.stats["refill_predictor_overlap"] == 1
    fe.step(6)
    fe.step(7)
    assert [i.index for i in fe.decoded[0]] == [0, 1]


def test_false_fast_btb_hit_preserves_validated_bytes() -> None:
    """F1 removes a stale prediction but pushes and drains the real instructions."""
    fe = front.FetchFrontend(program([4] * 4))
    fe.step(0)
    fe.f1.false_prediction = True
    fe.step(1)
    assert [i.index for i in fe.pd] == [0, 1]
    assert fe.cursor == (2, 0) and fe.f1 is None
    assert fe.stats["redirect_f1_false_btb"] == 1
    ids: list[int] = []
    for cycle in range(2, 12):
        fe.step(cycle)
        if fe.decoded:
            ids.extend(i.index for i in fe.decoded[0])
            fe.consume(len(fe.decoded[0]))
    assert ids == [0, 1, 2, 3]


def test_execute_recovery_waits_for_branch_operands() -> None:
    """The actual target is not fetched until the dependent branch resolves."""
    ops = program([4, 4, 4])
    ops[0] = dataclasses.replace(ops[0], destination=1)
    ops[1] = dataclasses.replace(
        ops[1],
        kind="branch",
        taken=True,
        next_pc=64,
        sources=(1,),
        depends_on=(0,),
        prediction=stream.Prediction(False, 0, "none", False, 0, True),
    )
    ops[2] = dataclasses.replace(ops[2], pc=64, next_pc=68)
    fe = front.FetchFrontend(ops)
    for cycle in range(10):
        fe.step(cycle)
        while fe.decoded:
            fe.consume(len(fe.decoded[0]))
    assert fe.cursor == (2, 0) and fe.barrier == 1
    assert fe.stats["windows"] == 1
    fe.request_redirect("execute", 2)
    for cycle in range(10, 15):
        fe.step(cycle)
    assert fe.decoded[0][0].index == 2


def test_native_execution_stages_and_l0_dependency_span() -> None:
    """Replay's scalar stage counts and three-cycle resident chase are explicit."""
    assert model.instruction_execution_cycles(0x00108093) == 2  # ADDI
    assert model.instruction_execution_cycles(0x021080B3) == 7  # MUL
    assert model.instruction_execution_cycles(0x021080BB) == 4  # MULW
    assert model.instruction_execution_cycles(0x0A1090B3) == 4  # CLMUL
    with pytest.raises(ValueError, match="division"):
        model.instruction_execution_cycles(0x0210C0B3)
    ops = [
        model.MicroOp(i, "load", i * 4, 64, (i - 1,) if i else ()) for i in range(100)
    ]
    pipe = model.FrostPipeline(model.ModelConfig(), ops, l0_hit_cycles=3)
    pipe.l0_cache[8] = 8
    pipe.fetch_state = {pipe._fetch_line(op.fetch_address): "ready" for op in ops}
    result = pipe.run()
    assert result["cycles"] == 302
    assert result["pipeline"]["stats"]["l0_hits"] == 100


@pytest.mark.parametrize(
    "state", ["done", "dispatch_broadcast", "resident_broadcast", "retired"]
)
def test_registered_dispatch_done_repair(state: str) -> None:
    """Live completed renames wait for repair; resident broadcasts still bypass."""
    producer = model.MicroOp(0, "alu", 0)
    consumer = model.MicroOp(1, "alu", 4, depends_on=(0,), execution_cycles=2)
    pipe = model.FrostPipeline(
        model.ModelConfig(), [producer, consumer], scalar_replay=True
    )
    pipe.fetch_state[0] = "ready"
    entry = model.RobEntry(producer, dispatched_cycle=0, issued=True)
    pipe.entries[0] = entry
    pipe.next_dispatch = 1
    pipe.loop.cycle = 10
    pipe.int_rs_in_use = int(state in {"dispatch_broadcast", "resident_broadcast"})
    if state == "dispatch_broadcast":
        pipe.completions.append(entry)
        pipe._drain_cdb()
    elif state != "resident_broadcast":
        entry.done = True
        entry.retired = state == "retired"
        pipe.completed_ids.add(0)
    pipe._dispatch()
    pipe.loop.cycle = 11
    if state == "resident_broadcast":
        pipe.completions.append(entry)
        pipe._drain_cdb()
    pipe._issue()
    delayed = state in {"done", "dispatch_broadcast"}
    assert pipe.entries[1].issued == (not delayed)
    pipe.loop.cycle = 12
    pipe._issue()
    assert pipe.entries[1].issued
    assert pipe.stats["dispatch_done_repairs"] == int(delayed)


@pytest.mark.parametrize(
    "kinds,issued",
    [
        (("alu", "branch"), (True, False)),
        (("branch", "alu"), (True, True)),
        (("branch", "branch"), (True, False)),
    ],
)
def test_only_integer_issue_port_zero_accepts_branches(
    kinds: tuple[str, str], issued: tuple[bool, bool]
) -> None:
    """A ready branch cannot occupy the second integer issue port."""
    ops = [model.MicroOp(i, kind, i * 4) for i, kind in enumerate(kinds)]
    pipe = model.FrostPipeline(model.ModelConfig(), ops, scalar_replay=True)
    pipe.fetch_state[0] = "ready"
    pipe._dispatch()
    pipe.loop.cycle = 1
    pipe._issue()
    assert tuple(pipe.entries[i].issued for i in range(2)) == issued
    pipe.loop.cycle = 2
    pipe._issue()
    assert all(entry.issued for entry in pipe.entries.values())
