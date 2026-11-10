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

"""Memory-controller service, backpressure, and transaction ownership tests."""

from dataclasses import replace
from typing import Any

import pytest

from test_perf_model import model


def advance(loop: Any, cycle: int) -> None:
    """Run every cycle through the requested cycle."""
    while loop.cycle <= cycle:
        loop.run_ready()
        loop.cycle += 1


def transaction(
    loop: Any,
    results: list[tuple[int, int, bool]],
    slot: int,
    address: int,
    write: bool = False,
) -> Any:
    """Build a transaction that records its identity and completion cycle."""
    return model.AxiTransaction(
        address=address,
        is_write=write,
        transaction_id=model.TransactionId("test", "fill", slot, 5),
        complete=lambda ok: results.append((slot, loop.cycle, ok)),
        source="test",
    )


@pytest.mark.parametrize(
    "channels,expected", [(1, [6, 10, 14, 18]), (2, [6, 7, 10, 11])]
)
def test_channel_interleave_and_bandwidth(channels: int, expected: list[int]) -> None:
    """Sequential lines use independent service intervals on distinct channels."""
    loop = model.EventLoop()
    config = model.DdrConfig(
        controller="interleaved", channels=channels, latency_cycles=6, cycles_per_line=4
    )
    controller = model.InterleavedDdrController(loop, config)
    results: list[tuple[int, int, bool]] = []
    for slot in range(4):
        assert controller.submit(transaction(loop, results, slot, 64 * slot))
        advance(loop, slot)
    advance(loop, 30)
    assert [cycle for _, cycle, _ in results] == expected
    assert all(ok for _, _, ok in results)
    assert controller.summary()["pending_reads"] == 0


def test_channel_queues_backpressure_independently() -> None:
    """A full channel leaves the other channel's queue available."""
    loop = model.EventLoop()
    controller = model.InterleavedDdrController(
        loop,
        model.DdrConfig(
            controller="interleaved",
            channels=2,
            interleave_bytes=128,
            num_slots=1,
            latency_cycles=30,
        ),
    )
    results: list[tuple[int, int, bool]] = []
    assert controller.submit(transaction(loop, results, 0, 0))
    assert not controller.submit(transaction(loop, results, 1, 64))
    assert controller.submit(transaction(loop, results, 1, 128))
    assert not controller.submit(transaction(loop, results, 0, 256))
    advance(loop, 35)
    assert {slot for slot, _, _ in results} == {0, 1}
    assert controller.submit(transaction(loop, results, 0, 256))


def test_shared_return_port_serializes_reads() -> None:
    """Two ready channels deliver at most one read response per cycle."""
    loop = model.EventLoop()
    controller = model.InterleavedDdrController(
        loop, model.DdrConfig(controller="interleaved", channels=2, latency_cycles=3)
    )
    results: list[tuple[int, int, bool]] = []
    for slot in range(2):
        assert controller.submit(transaction(loop, results, slot, slot * 64))
    advance(loop, 5)
    assert results == [(0, 3, True), (1, 4, True)]


@pytest.mark.parametrize(
    "reorder,expected", [(False, [(0, 8), (1, 9)]), (True, [(1, 2), (0, 8)])]
)
def test_channel_reordering(reorder: bool, expected: list[tuple[int, int]]) -> None:
    """Only the reorder setting allows a ready younger read past an older read."""
    loop = model.EventLoop()
    controller = model.InterleavedDdrController(
        loop, model.DdrConfig(controller="interleaved", reorder=reorder)
    )
    delays = iter([8, 2])
    controller._latency._sample_latency = lambda: next(delays)
    results: list[tuple[int, int, bool]] = []
    for slot in range(2):
        assert controller.submit(transaction(loop, results, slot, slot * 64))
    advance(loop, 10)
    assert [(slot, cycle) for slot, cycle, _ in results] == expected


def test_reads_and_writes_share_channel_bandwidth() -> None:
    """Read and write completions consume the same physical-channel service rate."""
    loop = model.EventLoop()
    controller = model.InterleavedDdrController(
        loop,
        model.DdrConfig(controller="interleaved", latency_cycles=3, cycles_per_line=4),
    )
    results: list[tuple[int, int, bool]] = []
    assert controller.submit(transaction(loop, results, 0, 0))
    assert controller.submit(transaction(loop, results, 1, 64, write=True))
    advance(loop, 10)
    assert results == [(0, 3, True), (1, 7, True)]


@pytest.mark.parametrize(
    "reorder,write,expected",
    [
        (False, False, [(0, 8), (1, 9)]),
        (True, False, [(1, 2), (0, 8)]),
        (False, True, [(1, 2), (0, 8)]),
    ],
)
def test_behavioral_reschedules_earlier_response(
    reorder: bool, write: bool, expected: list[tuple[int, int]]
) -> None:
    """A pending read cannot delay a ready write or a permitted reordered read."""
    loop = model.EventLoop()
    controller = model.SingleChannelDdrController(
        loop, model.DdrConfig(reorder=reorder)
    )
    delays = iter([8, 1])
    controller._sample_latency = lambda: next(delays)
    results: list[tuple[int, int, bool]] = []
    assert controller.submit(transaction(loop, results, 0, 0))
    advance(loop, 0)
    assert controller.submit(transaction(loop, results, 1, 64, write))
    advance(loop, 12)
    assert [(slot, cycle) for slot, cycle, _ in results] == expected
    assert controller.summary()["stats"]["completed"] == 2


@pytest.mark.parametrize(
    "changes",
    [
        {"channels": 0},
        {"num_slots": 0},
        {"cycles_per_line": 0},
        {"interleave_bytes": 96},
        {"interleave_bytes": 0},
        {"controller": "behavioral", "channels": 2},
    ],
)
def test_invalid_channel_settings(changes: dict[str, Any]) -> None:
    """Invalid queue, interleave, and service settings fail before simulation."""
    with pytest.raises(ValueError):
        replace(model.DdrConfig(controller="interleaved"), **changes).validate()


class HeldSoc:
    """Hold transactions until a test supplies an out-of-order response."""

    def __init__(self) -> None:
        """Create an accepting endpoint with no transactions."""
        self.transactions: list[Any] = []
        self.ready = True

    def submit_axi(self, tx: Any) -> bool:
        """Accept and record a transaction only while ready."""
        if self.ready:
            self.transactions.append(tx)
        return self.ready


def test_axi_pool_ownership_and_out_of_order_release() -> None:
    """Only a matching response releases its ID and the shared pool entry."""
    loop = model.EventLoop()
    soc = HeldSoc()
    bridge = model.AxiBridge(loop, soc, 64, 6, 2)
    completed: list[tuple[int, bool]] = []

    def request(slot: int, write: bool = False) -> Any:
        return model.Request(
            slot * 64,
            write,
            "test",
            model.TransactionId("l2", "writeback" if write else "fill", slot, 5),
            lambda ok: completed.append((slot, ok)),
        )

    assert bridge.submit(request(7))
    loop.cycle += 1
    assert bridge.submit(request(3, True))
    assert [tx.axi_id for tx in soc.transactions] == [7, 19]
    loop.cycle += 1
    assert not bridge.submit(request(0))
    assert not bridge.submit(request(7))
    soc.transactions[1].complete(False)
    assert completed == [(3, False)]
    assert bridge.submit(request(0))
    assert soc.transactions[2].axi_id == 0
    assert bridge.inflight.keys() == {7, 0}
    soc.transactions[0].complete(True)
    soc.transactions[2].complete(True)
    assert not bridge.inflight
    with pytest.raises(RuntimeError, match="owner"):
        soc.transactions[0].complete(True)


def test_axi_rejected_request_does_not_own_an_id() -> None:
    """Downstream backpressure leaves the ID pool available for a retry."""
    loop = model.EventLoop()
    soc = HeldSoc()
    bridge = model.AxiBridge(loop, soc, 64, 5, 1)
    req = model.Request(
        0, False, "test", model.TransactionId("l2", "fill", 0, 5), lambda ok: None
    )
    soc.ready = False
    assert not bridge.submit(req)
    assert not bridge.inflight
    soc.ready = True
    assert bridge.submit(req)


def test_explicit_zero_axi_id_is_preserved() -> None:
    """An explicit zero is distinct from an unspecified AXI ID."""
    tx = model.AxiTransaction(
        0,
        False,
        model.TransactionId("l2", "fill", 7, 5),
        lambda ok: None,
        "test",
        axi_id=0,
    )
    assert tx.axi_id == 0


def test_axi_width_and_pool_are_independent_of_cache_slots() -> None:
    """The wire width covers internal IDs while a separate pool limits concurrency."""
    cfg = replace(model.ModelConfig(), axi_id_pool_size=1)
    cfg.validate()
    cfg = replace(
        cfg, axi_id_bits=6, cpu_axi_id_bits=7, ddr=replace(cfg.ddr, id_bits=6)
    )
    cfg.validate()
    with pytest.raises(ValueError, match="truncation"):
        replace(cfg, l2_id_bits=7).validate()
    with pytest.raises(ValueError, match="pool"):
        replace(cfg, axi_id_pool_size=65).validate()
    with pytest.raises(ValueError, match="slots"):
        replace(cfg, l2_mshrs=32).validate()
    replace(cfg, l2_mshrs=32, l2_id_bits=6).validate()


def test_axi_pool_limit_changes_memory_stress_cycles() -> None:
    """A one-entry pool serializes misses despite spare L2 miss slots."""
    baseline = model.run_workload(model.ModelConfig(), "memory_stress", 11)
    limited = model.run_workload(
        replace(model.ModelConfig(), axi_id_pool_size=1), "memory_stress", 11
    )
    assert limited["cycles"] > baseline["cycles"]
    assert limited["memory"]["axi"]["max_inflight"] == 1
    assert limited["memory"]["axi"]["id_pool_backpressure"] > 0


def test_early_load_wakeup_only_advances_memory_consumers() -> None:
    """The load token bypasses MEM_RS registration without changing ALU dependencies."""
    for kind in ("load", "alu"):
        builder = model.ProgramBuilder()
        dependency: tuple[int, ...] = ()
        for index in range(32):
            load = builder.emit("load", 0x80002000, 0x80400000 + index * 64, dependency)
            dependency = (
                (load,)
                if kind == "load"
                else (builder.emit("alu", 0x80002004, depends_on=(load,)),)
            )
        cycles = []
        for enabled in (False, True):
            config = replace(
                model.ModelConfig(), early_load_wakeup=enabled, l2_prefetch=False
            )
            pipeline = model.FrostPipeline(config, builder.ops)
            pipeline.fetch_state[pipeline._fetch_line(0x80002000)] = "ready"
            # Resident L1D lines: a miss's installation would hold the
            # controller past the dependent load's wakeup.
            l1d = pipeline.memory.l1d
            for op in builder.ops:
                if op.kind == "load":
                    _, set_index, tag = l1d._set_and_tag(op.data_address)
                    l1d._ways(set_index)[0].valid = True
                    l1d._ways(set_index)[0].tag = tag
            cycles.append(pipeline.run()["cycles"])
        if kind == "load":
            assert cycles[0] - cycles[1] == 31
        else:
            assert cycles[0] == cycles[1]


@pytest.mark.parametrize(
    "registered,fault,expected",
    [(0, False, True), (1, False, True), (2, False, False), (0, True, False)],
)
def test_early_load_requires_a_free_registered_lane(
    registered: int, fault: bool, expected: bool
) -> None:
    """A fault or two occupied registered lanes prevents early token injection."""
    producer = model.RobEntry(model.MicroOp(0, "load", 0, 0), 0, fault=fault)
    consumer = model.RobEntry(model.MicroOp(1, "load", 0, 64, (0,)), 0)
    pipeline = model.FrostPipeline(model.ModelConfig(), [])
    pipeline._registered_cdb_count = registered
    pipeline.mem_rs_in_use = 1
    pipeline.completions = [producer]
    pipeline._drain_cdb()
    assert pipeline._deps_ready(consumer) == expected
    pipeline.loop.cycle += 1
    pipeline._drain_cdb()
    assert pipeline._deps_ready(consumer)


def cache_for_replacement(bimodal: bool = False) -> Any:
    """Create one four-way set whose lower level holds fills pending."""
    loop = model.EventLoop()

    class Lower:
        def submit(self, request: Any) -> bool:
            return True

    return model.CacheLevel(
        "test",
        loop,
        Lower(),
        256,
        64,
        4,
        4,
        2,
        2,
        1,
        1,
        1,
        1,
        4,
        bimodal_insert=bimodal,
    )


def test_tree_plru_and_reserved_subtrees() -> None:
    """The victim walk visits all four ways and avoids reserved subtrees."""
    cache = cache_for_replacement()
    for index, line in enumerate(cache._ways(0)):
        line.valid, line.tag = True, index
    for expected in [0, 2, 1, 3, 0]:
        assert cache._victim(0) == expected
        cache._touch(0, expected)
    cache.plru[0] = 0
    for index in range(4):
        assert cache._victim(0) == index
        cache._ways(0)[index].reserved_by = index
    assert cache._victim(0) is None
    cache._ways(0)[2].reserved_by = None
    assert cache._victim(0) == 2


def test_cache_response_latency_preserves_one_per_cycle_bandwidth() -> None:
    """Consecutive hits preserve lookup latency and the pipelined response rate."""
    cache = cache_for_replacement()
    cache.response_cycles = 3
    line = cache._ways(0)[0]
    line.valid, line.tag = True, 0
    completed: list[int] = []
    for slot in range(4):
        request = model.Request(
            0,
            False,
            "test",
            model.TransactionId("test", "fill", slot, 4),
            lambda ok: completed.append(cache.loop.cycle),
        )
        assert cache.submit(request)
        advance(cache.loop, slot)
    advance(cache.loop, 10)
    assert completed == [5, 6, 7, 8]


def test_bimodal_lfsr_advances_with_cycles_and_only_gates_allocations() -> None:
    """The RTL seed touches allocation at cycle 154 but not at cycle 153."""
    cache = cache_for_replacement(True)
    cache.loop.cycle = 153
    cache._touch(0, 0, allocation=True)
    assert cache.plru.get(0, 0) == 0
    cache.loop.cycle = 154
    cache._touch(0, 0, allocation=True)
    assert cache._insert_lfsr == 0xDCA0
    assert cache.plru[0] == 3
    cache.loop.cycle = 155
    cache._touch(0, 3, allocation=True)
    assert cache.plru[0] == 3
    cache._touch(0, 3)
    assert cache.plru[0] == 2


def test_bimodal_changes_conflict_workload() -> None:
    """Insertion policy changes misses when five lines compete for four ways."""
    builder = model.ProgramBuilder()
    dependency: tuple[int, ...] = ()
    for index in range(100):
        dependency = (
            builder.emit(
                "load", 0x80002000, 0x80600000 + (index % 5) * 32768, dependency
            ),
        )
    results = []
    for bimodal in (False, True):
        config = replace(
            model.ModelConfig(),
            l0_cache_depth=0,
            l2_prefetch=False,
            l1d_bimodal_insert=bimodal,
        )
        results.append(model.FrostPipeline(config, builder.ops).run())
    assert results[0]["cycles"] != results[1]["cycles"]
    assert (
        results[0]["memory"]["l1d"]["stats"]["misses"]
        != results[1]["memory"]["l1d"]["stats"]["misses"]
    )


def test_read_stream_confirms_on_three_adjacent_misses_within_its_page() -> None:
    """The look-ahead cursor runs up to eight sectors past the frontier, in the page."""
    stream = model.ReadStream(8, 4096, 32)
    assert stream.demand(0x1000, True)
    stream.demand(0x1020, True)
    assert stream.consume() is None
    stream.demand(0x1040, True)
    assert [stream.consume() for _ in range(9)] == [
        0x1000 + 32 * sector for sector in range(3, 11)
    ] + [None]
    stream.demand(0x1060, False)
    assert stream.consume() == 0x1000 + 32 * 11
    edge = model.ReadStream(8, 4096, 32)
    for sector in range(124, 127):
        edge.demand(0x2000 + 32 * sector, True)
    assert edge.consume() == 0x2000 + 32 * 127
    assert edge.consume() is None
    assert edge.demand(0x5000, True)
    assert not edge.confirmed


class HeldLower:
    """Accept every request and keep it until a test completes it."""

    def __init__(self) -> None:
        """Hold no requests."""
        self.requests: list[Any] = []

    def submit(self, request: Any) -> bool:
        """Accept and record a request."""
        self.requests.append(request)
        return True


def coherent_l1d(**changes: Any) -> tuple[Any, Any, HeldLower]:
    """Build a coherent L1D, with its loop, in front of a holding lower level."""
    loop = model.EventLoop()
    lower = HeldLower()
    config = replace(model.ModelConfig(), **changes)
    return model.CoherentL1d(loop, lower, config), loop, lower


def load(address: int, done: list[int] | None = None, ident: int = 0) -> Any:
    """Return a demand load that records its completion cycle in done."""
    return model.Request(
        address,
        False,
        "l1d",
        ident,
        lambda ok: done.append(address) if done is not None else None,
        bytes_size=8,
    )


def idle(l1d: Any, loop: Any) -> None:
    """Advance the loop until the L1D's controller is idle."""
    while loop.cycle < l1d.busy_until:
        loop.run_ready()
        loop.cycle += 1
    loop.run_ready()


@pytest.mark.parametrize("slots,expected", [(2, [7, 6]), (4, [7, 6, 5, 4])])
def test_look_ahead_takes_the_highest_endpoints_and_demand_the_lowest(
    slots: int, expected: list[int]
) -> None:
    """Demand misses take endpoints from 1 up; hints fill the top slots only."""
    l1d, loop, _lower = coherent_l1d(l1d_hit_path=False, l1d_lookahead_slots=slots)
    for sector in range(3):
        idle(l1d, loop)
        assert l1d.submit(load(0x8000_0000 + 32 * sector, ident=sector))
    assert sorted(status.slot for status in l1d.mshrs.values()) == [1, 2, 3]
    for _ in range(slots + 2):
        idle(l1d, loop)
        l1d.step_after_loads()
    hints = [
        status.slot
        for status in l1d.mshrs.values()
        if status.primary.source == "l1d_lookahead"
    ]
    assert hints == expected
    assert l1d.stats["lookahead_issued"] == slots


def test_controller_serves_one_lookup_at_a_time() -> None:
    """A read hit holds the controller through its tag and data reads."""
    l1d, loop, _lower = coherent_l1d(l1d_hit_path=False)
    line = l1d._ways(0)[0]
    line.valid, line.tag = True, 0x8000_0000 // 32 // l1d.sets_count
    done: list[int] = []
    assert l1d.submit(load(0x8000_0000, done))
    assert not l1d.submit(load(0x8000_0008, done, 1))
    assert l1d.busy_until == l1d.lookup_cycles + l1d.data_cycles == 6


def tick_l1d(l1d: Any, loop: Any, stop: int) -> None:
    """Drive both L1D paths and the stream detector through stop, inclusive."""
    while loop.cycle <= stop:
        loop.run_ready()
        l1d.step()
        l1d.service_replays()
        l1d.step_after_loads()
        loop.cycle += 1


def warm_l1d(l1d: Any, address: int) -> None:
    """Install a clean sector without warming the CPU's L0."""
    _, index, tag = l1d._set_and_tag(address)
    way = l1d._victim(index)
    assert way is not None
    line = l1d._ways(index)[way]
    line.valid, line.tag = True, tag


@pytest.mark.parametrize("lanes,span", [(1, 4599), (2, 2296), (4, 1146)])
def test_cached_load_chains_match_rtl_launch_spans(lanes: int, span: int) -> None:
    """512 warm L1D loads, with L0 aliases, match the measured RTL launch windows."""

    class LaunchPipeline(model.FrostPipeline):
        def _issue(self) -> None:
            old = {entry.op.op_id for entry in self.rob if entry.rs_issued}
            super()._issue()
            launches.extend(
                self.loop.cycle
                for entry in self.rob
                if entry.rs_issued and entry.op.op_id not in old
            )

    builder = model.ProgramBuilder()
    for index in range(512):
        lane, node = index % lanes, index // lanes % 16
        builder.emit(
            "load",
            4 * index,
            0x8000_0000 + 4096 * node + 8 * lane,
            (index - lanes,) if index >= lanes else (),
        )
    config = replace(model.ModelConfig(), l0_cache_depth=512, l2_mshrs=8)
    pipeline = LaunchPipeline(config, builder.ops)
    launches: list[int] = []
    for op in builder.ops:
        pipeline.fetch_state[pipeline._fetch_line(op.fetch_address)] = "ready"
        if (
            pipeline.memory.l1d._find(
                *pipeline.memory.l1d._set_and_tag(op.data_address)[1:]
            )
            is None
        ):
            warm_l1d(pipeline.memory.l1d, op.data_address)
    result = pipeline.run()
    assert launches[-1] - launches[0] == span
    assert result["memory"]["l1d"]["stats"]["hit_path_hits"] == 512


def test_hit_path_answers_under_a_miss_and_shadows_only_the_selected_read() -> None:
    """Hits overlap a controller miss; its shadow has no data read or second answer."""
    l1d, loop, lower = coherent_l1d(l1d_lookahead_slots=0)
    address = 0x8000_0000
    warm_l1d(l1d, address)
    answers: list[tuple[int, int, bool]] = []
    for ident in range(4):
        request = model.Request(
            address,
            False,
            "l1d",
            ident,
            lambda ok, ident=ident: answers.append((ident, loop.cycle, ok)),
        )
        assert l1d.submit(request)
        tick_l1d(l1d, loop, ident)
    tick_l1d(l1d, loop, 12)
    assert answers == [(ident, ident + 6, True) for ident in range(4)]
    assert l1d.stats["shadow_lookups"] == 2
    assert l1d.stats["controller_busy_cycles"] == 2 * l1d.lookup_cycles
    assert l1d.stats["hits"] == l1d.stats["hit_path_hits"] == 4
    assert not lower.requests and not l1d.reads

    # A miss occupies the controller, but another set's hit port still runs.
    miss = 0x8000_1000
    assert l1d.submit(load(miss, ident=10))
    tick_l1d(l1d, loop, 14)
    assert miss // 32 in l1d.mshrs
    arrival = loop.cycle
    assert l1d.submit(
        model.Request(
            address,
            False,
            "l1d",
            11,
            lambda ok: answers.append((11, loop.cycle, ok)),
        )
    )
    tick_l1d(l1d, loop, arrival + 6)
    assert answers[-1] == (11, arrival + 6, True)
    assert l1d.stats["misses"] == 1


def test_shadow_miss_acquires_once_and_attached_load_replays_after_fill() -> None:
    """Both misses follow the controller; an attached read gets no second hit offer."""
    l1d, loop, lower = coherent_l1d(l1d_lookahead_slots=0)
    done: list[int] = []
    assert l1d.submit(load(0x8000_0000, done, 1))
    tick_l1d(l1d, loop, 1)
    assert l1d.submit(load(0x8000_0008, done, 2))
    tick_l1d(l1d, loop, 12)
    assert l1d.stats["misses"] == 1 and l1d.stats["mshr_merges"] == 1
    assert len(lower.requests) == 1 and not done
    lower.requests[0].complete(True)
    tick_l1d(l1d, loop, 40)
    assert sorted(done) == [0x8000_0000, 0x8000_0008]
    assert l1d.stats["hit_path_hits"] == 0
    assert l1d.stats["hit_path_offers"] == 2
    assert not l1d.reads and not l1d._used_mshr_slots


def test_stage_three_selection_shadows_a_hit_and_keeps_its_snapshot() -> None:
    """A late controller selection cannot answer twice or lose a sampled hit."""
    l1d, loop, lower = coherent_l1d(l1d_lookahead_slots=0)
    address = 0x8000_0000
    warm_l1d(l1d, address)
    done: list[int] = []
    l1d.busy_until = 3
    assert l1d.submit(load(address, done))
    tick_l1d(l1d, loop, 1)
    # A later array change does not revoke a hit from the stage-1 image.
    l1d._ways(0)[0].valid = False
    tick_l1d(l1d, loop, 16)
    assert done == [address]
    assert l1d.stats["shadow_skips"] == 1
    assert not lower.requests


def test_tags_only_hit_after_a_path_miss_needs_a_later_data_lookup() -> None:
    """If only the shadow sees an installation, it cannot return absent data."""
    l1d, loop, _lower = coherent_l1d(l1d_lookahead_slots=0)
    address = 0x8000_0000
    done: list[int] = []
    assert l1d.submit(load(address, done))
    advance(loop, 1)  # the hit port samples an absent sector
    loop.cycle = 1
    warm_l1d(l1d, address)  # tags become resident before the controller lookup
    l1d.service_replays()
    assert l1d.busy_until == 5 and not done
    tick_l1d(l1d, loop, 8)
    assert not done
    tick_l1d(l1d, loop, 16)
    assert done == [address] and l1d.stats["hits"] == 1
    assert not l1d.stats["hit_path_hits"]


def test_read_slot_credit_is_held_until_the_response() -> None:
    """Accepted misses consume finite read slots while endpoints await grants."""
    l1d, loop, _lower = coherent_l1d(l1d_read_slots=2, l1d_lookahead_slots=0)
    assert l1d.submit(load(0x8000_0000, ident=1))
    tick_l1d(l1d, loop, 0)
    assert l1d.submit(load(0x8000_1000, ident=2))
    tick_l1d(l1d, loop, 12)
    assert len(l1d.reads) == 2
    assert not l1d.submit(load(0x8000_2000, ident=3))


def test_hit_port_sees_a_fill_before_the_controller_finishes_update_wait() -> None:
    """A grant's tag copy is visible on the cycle after its write edge."""
    l1d, loop, lower = coherent_l1d(l1d_lookahead_slots=0)
    address = 0x8000_0000
    assert l1d.submit(load(address, ident=1))
    tick_l1d(l1d, loop, 5)
    lower.requests[0].complete(True)
    tick_l1d(l1d, loop, 9)  # grant selects at 6, writes its image at 10
    done: list[int] = []
    assert l1d.submit(
        model.Request(
            address,
            False,
            "l1d",
            2,
            lambda ok: done.append(loop.cycle),
        )
    )
    tick_l1d(l1d, loop, 20)
    assert done == [16]
    assert l1d.stats["hit_path_hits"] == 1
    assert l1d.stats["misses"] == 1


def test_hit_port_refuses_a_bank_claim_and_a_same_set_update() -> None:
    """A refused one-shot offer falls back to a normal data lookup."""
    for collision in ("claim", "update", "store", "writeback"):
        l1d, loop, _lower = coherent_l1d(l1d_lookahead_slots=0)
        address = 0x8000_0000
        warm_l1d(l1d, address)
        if collision == "claim":
            l1d._array_claim_cycle = 1
        elif collision == "update":
            l1d._array_update = (1, 2, l1d._set_and_tag(address)[1])
        elif collision == "store":
            l1d.push_store(address)
        else:
            l1d._wb_lines[0] = address // 32
        answers: list[int] = []
        assert l1d.submit(load(address, answers))
        # Run the offer before clearing its blocker, then allow fallback.
        advance(loop, 1)
        l1d.records.clear()
        l1d._wb_lines.clear()
        tick_l1d(l1d, loop, 12)
        assert answers == [address]
        assert l1d.stats["hit_path_refused"] == 1
        assert not l1d.stats["hit_path_hits"]
        assert l1d.stats["controller_busy_cycles"] == 6


def test_hit_reports_advance_only_a_confirmed_stream_and_yield_to_demands() -> None:
    """The two-entry second input drops overflow and never confirms a stream."""
    l1d, loop, _lower = coherent_l1d()
    stream = l1d.stream
    stream.demand(0x8000_0000, True)
    stream.demand(0x8000_0020, True)
    l1d._hit_reports.append(0x8000_0040 // 32)
    l1d._train_path_hits()
    assert not stream.confirmed and stream.frontier == 1
    stream.demand(0x8000_0040, True)
    assert stream.confirmed
    l1d._hit_reports.extend([0x8000_0060 // 32, 0x8000_0080 // 32])
    l1d._demand_report_cycle = loop.cycle
    l1d._new_hit_report = 0x8000_00A0 // 32
    l1d._train_path_hits()
    assert l1d.stats["hit_path_stream_drops"] == 1
    assert stream.frontier == 2
    loop.cycle += 1
    l1d._train_path_hits()
    assert stream.frontier == 3
    loop.cycle += 1
    l1d._train_path_hits()
    assert stream.frontier == 4


def test_controller_replacement_write_drops_a_concurrent_hit_port_touch() -> None:
    """The single replacement write port gives an array hit priority in every set."""
    l1d, loop, _lower = coherent_l1d(l1d_lookahead_slots=0)
    controller_address, path_address = 0x8000_0000, 0x8000_0020
    warm_l1d(l1d, controller_address)
    warm_l1d(l1d, path_address)
    assert l1d._read(load(controller_address, ident=1), True)
    assert l1d.submit(load(path_address, ident=2))
    tick_l1d(l1d, loop, 12)
    assert l1d.stats["hit_path_touch_drops"] == 1
    assert l1d.plru.get(1, 0) == 0


def test_controller_touch_follows_an_earlier_hit_port_touch() -> None:
    """Controller selection does not move its tag-result touch ahead of a hit."""
    l1d, loop, _lower = coherent_l1d(l1d_lookahead_slots=0)
    base = 0x8000_0000
    tag = l1d._set_and_tag(base)[2]
    for way, line in enumerate(l1d._ways(0)):
        line.valid, line.dirty, line.tag = True, True, tag + way
    loop.cycle = 5
    assert l1d.submit(load(base + 2 * l1d.sets_count * 32, ident=1))
    advance(loop, 5)
    loop.run_ready()
    l1d.push_store(base)
    l1d.step()  # store selects at 6 and touches way 0 at 9
    tick_l1d(l1d, loop, 14)  # hit port touches way 2 at 8
    assert l1d.plru[0] == 7
    assert l1d._victim(0) == 3


def test_fallback_hit_reports_when_its_data_arrives_after_queued_hits() -> None:
    """A controller hit reports after its data read, preserving stream input order."""
    l1d, loop, _lower = coherent_l1d()
    address = 0x8000_0000
    for sector in range(3):
        l1d.stream.demand(address + 32 * sector, True)
    warm_l1d(l1d, address + 128)
    assert l1d._read(load(address + 128), True)
    loop.after(3, lambda: setattr(l1d, "_new_hit_report", (address + 96) // 32))
    while loop.cycle <= 6:
        loop.run_ready()
        l1d._train_path_hits()
        loop.cycle += 1
    assert l1d.stream.frontier == 4


def test_store_records_combine_by_sector_and_install_at_the_head() -> None:
    """The youngest unsealed record combines; credit counts records, not stores."""
    l1d, loop, lower = coherent_l1d()
    for offset in range(0, 32, 8):
        l1d.push_store(0x8000_0000 + offset)
    for record in range(1, 4):
        l1d.push_store(0x8000_0000 + 64 * record)
    assert len(l1d.records) == 4 and l1d.records[0].contributors == 4
    assert not l1d.store_ready()
    l1d.step()
    assert l1d.records[0].sealed and l1d.records[0].status.slot == 0
    idle(l1d, loop)
    l1d.step_after_loads()
    lent = [record.status.slot for record in l1d.records if record.status]
    assert lent == [0, 1] and l1d.borrowed == 1


def test_home_prefetch_confirms_on_two_lines_and_keeps_its_reserve() -> None:
    """Two consecutive lines start a stream; a prefetch never takes a reserved fill."""
    pipeline = model.FrostPipeline(replace(model.ModelConfig(), l2_mshrs=8), [])
    memory, loop = pipeline.memory, pipeline.loop
    prefetcher = memory.prefetcher
    for line in (0x0200_0000, 0x0200_0001):
        prefetcher.observe(line)
    advance(loop, 40)
    issued = {status.line_address for status in memory.l2.mshrs.values()}
    assert issued == {0x0200_0002 + index for index in range(len(issued))}
    assert len(issued) <= memory.l2.mshr_count - prefetcher.reserve
    assert prefetcher.stats["streams_allocated"] == 1


def test_mem_rs_frees_at_issue_and_stores_retire_before_their_write() -> None:
    """Loads and stores leave MEM_RS when they issue; stores commit before the L1D writes."""
    builder = model.ProgramBuilder()
    for index in range(8):
        builder.emit("load", 0x80002000, 0x80400000 + 4096 * index)
    builder.emit("store", 0x80002004, 0x80800000)
    cycles = []
    for entries in (2, 8):
        config = replace(model.ModelConfig(), mem_rs_entries=entries, l2_prefetch=False)
        pipeline = model.FrostPipeline(config, builder.ops)
        pipeline.fetch_state[pipeline._fetch_line(0x80002000)] = "ready"
        result = pipeline.run()
        cycles.append(result["cycles"])
        assert result["pipeline"]["max_occupancy"]["mem_rs"] <= entries
        # The store has committed while its write still waits to drain.
        assert pipeline.committed_stores or pipeline.memory.l1d.records
    # The loads' misses overlap although two entries hold their issue.
    assert cycles[0] - cycles[1] <= 8
