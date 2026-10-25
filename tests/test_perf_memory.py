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
            controller="interleaved", channels=2, interleave_bytes=128, num_slots=1
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
