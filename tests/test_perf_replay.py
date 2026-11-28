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

"""End-to-end instruction replay and source-defined backend resource contracts."""

import dataclasses
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest


from test_instruction_trace import row, write_stream, stream_api
from test_perf_model import model, PERF_MODELING, _write_trace, _baseline


def replay_fixture(path: Path) -> tuple[Any, dict[str, Any]]:
    """Build an architectural path with execute/PD redirects, loads and multiplies."""
    pcs = [0, 4, 64, 68, 128, 132, 136, 140]
    rows = [row(i, pc) for i, pc in enumerate(pcs)]
    for index, tier in ((1, "none"), (3, "pd_direction")):
        rows[index] = {
            **row(index, pcs[index], 0x00008463),
            "kind": "branch",
            "destination": None,
            "taken": True,
            "next_pc": pcs[index + 1],
            "prediction": {
                "f0_taken": False,
                "f0_target": 0,
                "pd_tier": tier,
                "pd_taken": tier != "none",
                "pd_target": pcs[index + 1],
                "execute_redirect": tier == "none",
            },
        }
    rows[4] = {
        **row(4, pcs[4], 0x0000B103),
        "kind": "load",
        "address": 4096,
        "memory_bytes": 8,
        "destination": 2,
    }
    rows[5] = {**row(5, pcs[5], 0x022101BB), "sources": [2], "destination": 3}
    rows[6] = {
        **row(6, pcs[6], 0x0030B023),
        "kind": "store",
        "sources": [1, 3],
        "destination": None,
        "address": 4104,
        "memory_bytes": 8,
    }
    write_stream(path, rows)
    stream = stream_api.read_stream(path)
    manifest = {
        "instruction_stream": {"sha256": stream.sha256, "instructions": len(rows)},
        "artifacts": stream.metadata["artifacts"],
        "git_commit": "a" * 40,
        "benchmark": "coremark",
        "memory_configuration": {"tier": "bram"},
        "run_number": 1,
        "timed_region": {"start_pc": "0x0", "stop_pc": "0x10"},
    }
    return stream, manifest


def test_instruction_stream_and_named_workload_end_to_end(tmp_path: Path) -> None:
    """Fetch callbacks, dependency wakeup and both redirects remain connected to retirement."""
    path = tmp_path / "instructions.jsonl"
    stream, manifest = replay_fixture(path)
    direct = model.run_instruction_stream(model.ModelConfig(), stream)
    named = model.run_workload(
        model.ModelConfig(),
        "coremark_bram",
        11,
        instruction_trace=path,
        manifest=manifest,
    )
    assert direct["cycles"] == named["cycles"]
    assert direct["retired"] == 8
    assert direct["frontend"]["stats"]["redirect_execute"] == 1
    assert direct["frontend"]["stats"]["redirect_pd"] == 1
    assert direct["pipeline"]["stats"]["branches_without_cdb"] == 2
    assert direct["pipeline"]["stats"]["multiplies_issued"] == 1
    assert direct["frontend"]["provider"]["line_requests"] == 3
    slow = model.run_instruction_stream(
        dataclasses.replace(
            model.ModelConfig(), soc=model.SocConfig(local_wide_fetch_cycles=20)
        ),
        stream,
    )
    assert slow["cycles"] > direct["cycles"]


def test_calibration_cli_with_instruction_replay(tmp_path: Path) -> None:
    """The CI command succeeds, writes portable provenance, and rejects a swapped binary."""
    path = tmp_path / "instructions.jsonl"
    stream, manifest = replay_fixture(path)
    result = model.run_instruction_stream(model.ModelConfig(), stream)
    cycles, retired = result["cycles"], result["retired"]
    trace = tmp_path / "trace.jsonl"
    _write_trace(trace, cycles, retired, {"dispatch", "axi"})
    trace.write_text(trace.read_text().replace('"abc"', '"' + "a" * 40 + '"'))
    baseline_path = tmp_path / "baseline.json"
    _baseline(baseline_path, retired / cycles)
    baseline = json.loads(baseline_path.read_text())
    baseline["model_workload"] = "coremark_bram"
    baseline_path.write_text(json.dumps(baseline))
    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text(json.dumps(manifest))
    counters_path = tmp_path / "counters.json"
    counters_path.write_text(
        json.dumps(
            {
                "cycles": cycles,
                "retired_uops": retired,
                "dispatch_distribution": {
                    "total_dispatched_uops": cycles,
                    "cycles_1_uop": cycles,
                    "cycles_2_uops": 0,
                },
                "commit_distribution": {"cycles_1_uop": retired, "cycles_2_uops": 0},
                "axi_totals": {
                    "ar_requests": 1,
                    "aw_requests": 0,
                    "r_responses": 1,
                    "b_responses": 0,
                },
            }
        )
    )
    output = tmp_path / "record.json"
    command = [
        sys.executable,
        str(PERF_MODELING / "tools/run_calibration.py"),
        "--trace",
        str(trace),
        "--manifest",
        str(manifest_path),
        "--counters",
        str(counters_path),
        "--instructions",
        str(path),
        "--baseline",
        str(baseline_path),
        "--rtl-commit",
        "a" * 40,
        "--out",
        str(output),
    ]
    process = subprocess.run(command, capture_output=True, text=True, timeout=30)
    assert process.returncode == 0, process.stdout + process.stderr
    record = json.loads(output.read_text())
    assert record["check"]["passed"]
    assert record["check"]["model"]["retired_uops"] == retired
    assert str(tmp_path) not in output.read_text()
    manifest["artifacts"]["sw.bin_sha256"] = "d" * 64
    manifest_path.write_text(json.dumps(manifest))
    process = subprocess.run(command, capture_output=True, text=True, timeout=30)
    assert process.returncode != 0 and "binary" in process.stderr


def test_atomic_dispatch_and_registered_release() -> None:
    """A full station stalls both slots even when it issues on the same edge."""
    ops = [model.MicroOp(i, "alu", i * 4, execution_cycles=2) for i in range(4)]
    pipe = model.FrostPipeline(
        dataclasses.replace(model.ModelConfig(), int_rs_entries=2),
        ops,
        scalar_replay=True,
    )
    pipe.fetch_state[0] = "ready"
    pipe._dispatch()
    pipe.loop.cycle = 1
    pipe._snapshot_dispatch()
    pipe._issue()
    pipe._dispatch()
    assert pipe.next_dispatch == 2 and pipe.int_rs_in_use == 0
    assert pipe.stats["dispatch_stall_int_rs"] == 1
    pipe.loop.cycle = 2
    pipe._snapshot_dispatch()
    pipe._dispatch()
    assert pipe.next_dispatch == 4


def test_issue_uses_slot_indices_and_second_port_window() -> None:
    """A younger low-slot op wins over an older high-slot op; port 1 cannot scan slot 8."""
    pipe = model.FrostPipeline(model.ModelConfig(), [], scalar_replay=True)
    older = model.RobEntry(model.MicroOp(0, "alu", 0), 0, rs_slot=8)
    younger = model.RobEntry(model.MicroOp(1, "alu", 4), 1, rs_slot=0)
    pipe.int_slots[8], pipe.int_slots[0] = older, younger
    pipe.int_rs_in_use = 2
    pipe._issue()
    assert younger.issued and not older.issued
    assert pipe.int_rs_in_use == 1
    pipe.loop.cycle += 1
    pipe._issue()
    assert older.issued and pipe.int_rs_in_use == 0


def test_conditional_branch_needs_no_cdb_and_jal_needs_no_station() -> None:
    """CDB saturation cannot defer branch resolution; JAL completes at allocation."""
    ops = [
        model.MicroOp(0, "branch", 0, instruction=0x0000006F),
        model.MicroOp(1, "branch", 4, mispredict=True, instruction=0x00000063),
    ]
    pipe = model.FrostPipeline(model.ModelConfig(), ops, scalar_replay=True)
    pipe.fetch_state[0] = "ready"
    pipe._dispatch()
    assert pipe.entries[0].done and pipe.int_rs_in_use == 1
    pipe.loop.cycle = 1
    pipe._issue()
    pipe.loop.cycle = 3
    pipe.loop.run_ready()
    assert pipe.entries[1].done
    assert pipe.stats["branch_mispredicts"] == 1
    assert not pipe.completions
    assert pipe.backend_blocked_until == 5


def test_bram_provider_alias_crossing_and_port_contention() -> None:
    """Two window words, direct-map eviction and an occupied data port all matter."""
    config = dataclasses.replace(model.ModelConfig(), normal_fetch_lines=2)
    loop = model.EventLoop()
    soc = model.SocTopModel(config, loop)
    provider = model.BramFetchProvider(config, loop, soc)

    def fetch(pc: int) -> int:
        completed: list[int] = []
        start = loop.cycle
        provider.request(pc, completed.append)
        while not completed:
            loop.cycle += 1
            loop.run_ready()
        return completed[0] - start

    assert fetch(28) > 1  # two words on opposite sides of a 32-byte boundary
    assert provider.stats["line_requests"] == 2
    assert fetch(28) == 1
    assert fetch(64) > 1
    assert fetch(0) > 1  # same direct index as line 2
    assert provider.stats["line_requests"] == 4
    before = provider.stats["local_port_backpressure"]
    assert soc.submit_axi(
        model.AxiTransaction(
            address=4096,
            is_write=False,
            transaction_id=model.TransactionId("uncached", "fill", 0, 6),
            complete=lambda _ok: None,
            source="uncached",
            axi_id=32,
            bytes_size=8,
        )
    )
    fetch(96)
    assert provider.stats["local_port_backpressure"] > before


def test_metadata_stop_uses_pre_pop_window_count() -> None:
    """Draining metadata does not bypass the registered seven-window stop check."""
    from test_perf_frontend import front

    queue = front.ParcelQueue()
    for index in range(7):
        queue.push([front.Parcel(index, 0, index, True)])
    queue.parcels.popleft()
    queue.clock()
    assert queue.metadata_count == 6 and queue.stop
    queue.clock()
    assert not queue.stop


@pytest.mark.parametrize(
    "instruction,kind,expected",
    [
        (0x00108093, "alu", False),
        (0x0000B103, "load", True),
        (0x021080BB, "alu", False),
    ],
)
def test_load_wakeup_uses_station_specific_paths(
    instruction: int, kind: str, expected: bool
) -> None:
    """With both registered lanes occupied only MEM's third early token can issue."""
    pipe = model.FrostPipeline(model.ModelConfig(), [], scalar_replay=True)
    load = model.RobEntry(model.MicroOp(0, "load", 0, 4096), 0)
    consumer = model.RobEntry(
        model.MicroOp(1, kind, 4, depends_on=(0,), instruction=instruction), 0
    )
    pipe._registered_cdb_count = 2
    pipe.completions.append(load)
    pipe._drain_cdb()
    assert pipe._deps_ready(consumer) is expected
    pipe.loop.cycle = 1
    assert pipe._deps_ready(consumer)
