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

"""Read-stream saturation and experiment configuration checks."""

import pytest

from test_perf_model import _load

sweep = _load("tools/sweep_memory.py", "frost_memory_sweep_test")


def test_controller_probe_separates_channels_pool_and_port() -> None:
    """Extra channels need enough IDs and remain bounded by the shared port."""
    one = sweep.controller_probe(1, 12, 4, 16, 256)
    two = sweep.controller_probe(2, 12, 4, 16, 256)
    limited = sweep.controller_probe(2, 12, 4, 1, 256)
    port = sweep.controller_probe(2, 12, 1, 32, 256)
    assert one["lines_per_cycle"] == pytest.approx(0.25)
    assert two["lines_per_cycle"] == pytest.approx(0.5, rel=0.01)
    assert limited["lines_per_cycle"] == pytest.approx(1 / 12)
    assert limited["axi"]["max_inflight"] == 1
    assert port["lines_per_cycle"] == pytest.approx(1)
    assert two["ddr"]["pending_reads"] == 0


def test_controller_probe_measures_latency_budget() -> None:
    """A fixed pool supplies half the throughput when its lifetime doubles."""
    short = sweep.controller_probe(2, 12, 1, 4, 256)
    long = sweep.controller_probe(2, 24, 1, 4, 256)
    assert long["lines_per_cycle"] / short["lines_per_cycle"] == pytest.approx(
        0.5, rel=0.01
    )
    assert short["axi"]["max_inflight"] == long["axi"]["max_inflight"] == 4


def test_sweep_configurations_are_valid_and_named() -> None:
    """Every sweep point has a unique identity and valid resource geometry."""
    configs = sweep.configurations("all")
    assert len({config.name for config in configs}) == len(configs)
    for config in configs:
        config.validate()
