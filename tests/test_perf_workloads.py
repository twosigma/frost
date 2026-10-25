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

"""DDR workload addresses, memory dependence, and experiment configuration."""

import json
from pathlib import Path
from typing import Any

import pytest

from test_perf_model import model


@pytest.mark.parametrize(
    "name,loads,stores",
    [
        ("ddr_mlp_independent", 16, 0),
        ("ddr_mlp_chase", 16, 0),
        ("ddr_mlp_store", 0, 16),
        ("ddr_bench_seq_read", 512, 0),
        ("ddr_bench_stride_read", 128, 0),
        ("ddr_bench_streams_read", 64, 0),
        ("ddr_bench_streams_aliased_read", 64, 0),
        ("ddr_bench_random_read", 16, 0),
        ("ddr_bench_record_read", 32, 0),
        ("ddr_bench_chase", 8, 0),
        ("ddr_bench_copy", 128, 128),
        ("ddr_bench_write", 0, 128),
    ],
)
def test_kernel_access_counts_and_completion(
    name: str, loads: int, stores: int
) -> None:
    """The scaled loops perform the C source's memory access counts."""
    builder = model.ProgramBuilder()
    ops = model.build_kernel(builder, name, 8, 16)
    assert sum(op.kind == "load" for op in ops) == loads
    assert sum(op.kind == "store" for op in ops) == stores
    assert all(0 <= dep < op.op_id for op in ops for dep in op.depends_on)
    result = model.run_memory_kernel(model.ModelConfig(), name, 8, 16)
    assert result["retired"] == len(ops)
    assert not result["pipeline"]["stats"].get("memory_faults", 0)


def memory_ancestors(ops: list[Any], op: Any) -> set[int]:
    """Find the memory producers on an operation's dependency paths."""
    pending = list(op.depends_on)
    visited: set[int] = set()
    while pending:
        dep = pending.pop()
        if dep not in visited:
            visited.add(dep)
            pending.extend(ops[dep].depends_on)
    return {index for index in visited if ops[index].kind in {"load", "store"}}


def test_chase_dependencies_and_independent_streams() -> None:
    """Each chase address depends on its predecessor; independent loads do not."""
    for name in (
        "ddr_mlp_chase",
        "ddr_bench_chase",
        "ddr_mlp_independent",
        "ddr_bench_random_read",
    ):
        ops = model.build_kernel(model.ProgramBuilder(), name, 8, 16)
        loads = [op for op in ops if op.kind == "load"]
        for previous, following in zip(loads, loads[1:]):
            ancestors = memory_ancestors(ops, following)
            if name.endswith("chase"):
                assert previous.op_id in ancestors
            else:
                assert not ancestors


def test_stream_aliases_and_record_sectors() -> None:
    """Aliased streams share cache sets and record pairs share an L2 line."""
    ops = model.build_kernel(
        model.ProgramBuilder(), "ddr_bench_streams_aliased_read", 8
    )
    addresses = [op.data_address for op in ops if op.kind == "load"]
    assert addresses[:4] == [0x82800000, 0x82A00000, 0x82C00000, 0x82E00000]
    assert addresses[4:8] == [address + 8 for address in addresses[:4]]
    ops = model.build_kernel(model.ProgramBuilder(), "ddr_bench_record_read", 8)
    loads = [op for op in ops if op.kind == "load"]
    for lower, upper in zip(loads[::2], loads[1::2]):
        assert upper.data_address - lower.data_address == 32
        assert upper.data_address // 64 == lower.data_address // 64
        assert lower.op_id not in memory_ancestors(ops, upper)


def test_copy_data_dependencies_and_store_addresses() -> None:
    """Copy stores depend on their source load, and the MLP store uses word one."""
    ops = model.build_kernel(model.ProgramBuilder(), "ddr_bench_copy", 8)
    loads = [op for op in ops if op.kind == "load"]
    stores = [op for op in ops if op.kind == "store"]
    for load, store in zip(loads, stores):
        assert store.data_address - load.data_address == 576 * 1024
        assert load.op_id in memory_ancestors(ops, store)
    ops = model.build_kernel(model.ProgramBuilder(), "ddr_mlp_store", mlp_lines=16)
    assert [op.data_address for op in ops if op.kind == "store"] == [
        0x80600004 + 32 * i for i in range(16)
    ]


def test_configuration_file_sets_nested_controller_fields(tmp_path: Path) -> None:
    """JSON configuration selects channel timing without replacing cache defaults."""
    path = tmp_path / "config.json"
    path.write_text(
        json.dumps(
            {
                "axi_id_pool_size": 2,
                "ddr": {
                    "controller": "interleaved",
                    "channels": 2,
                    "cycles_per_line": 4,
                },
            }
        )
    )
    config = model.load_config(path)
    assert config.l1d_mshrs == 8
    assert config.axi_id_pool_size == 2
    assert config.ddr.channels == 2 and config.ddr.latency_cycles == 30
    path.write_text(json.dumps({"ddr": {"channels": 0}}))
    with pytest.raises(ValueError):
        model.load_config(path)


def test_repeated_passes_reuse_data_cache() -> None:
    """A second sequential pass retires its work without another cold fill set."""
    first = model.run_memory_kernel(model.ModelConfig(), "ddr_bench_seq_read", 8)
    twice = model.run_memory_kernel(
        model.ModelConfig(), "ddr_bench_seq_read", 8, passes=2
    )
    assert twice["retired"] == 2 * first["retired"]
    assert twice["cycles"] < 2 * first["cycles"]
    assert (
        twice["memory"]["l1d"]["stats"]["misses"]
        == first["memory"]["l1d"]["stats"]["misses"]
    )
