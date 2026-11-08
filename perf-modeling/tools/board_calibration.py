#!/usr/bin/env python3
# Copyright (c) 2026 John Goodacre.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Compare the model with a board calibration data set.

A data set directory holds manifest.json (the board, build, clocks and raw
result files), measurements.json (each benchmark's measured figure) and
model_config.json (the model configuration of that platform, in
--config-file form). The tool runs each benchmark body from
board_workloads.py from caches full of unrelated lines, measures its steady
state after the body's warm-up share has retired, converts cycles to the
board's units at the manifest's CPU clock, and writes each figure, the
model's, and their residual. Points marked "fit" set a configuration
latency and reproduce the board by construction; --fit searches those
latencies again and prints them. --set applies further configuration
fields to every run, for sensitivity studies.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import sys
from pathlib import Path
from typing import Any

PERF = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PERF))
import board_workloads  # noqa: E402
import frost_perf_model as model  # noqa: E402

FILL_BASE = 0xA000_0000  # the preconditioned lines' region, apart from the kernels'


class MeasuredPipeline(model.FrostPipeline):
    """A pipeline that notes the cycle at which its warm-up has retired."""

    def __init__(self, config: Any, program: list[Any], warm_ops: int) -> None:
        """Run program; the window opens once warm_ops micro-ops retire."""
        super().__init__(config, program)
        self.warm_ops = warm_ops
        self.window: tuple[int, int] | None = None  # (retired, cycle) at the start
        for op in program:
            self.fetch_state[self._fetch_line(op.fetch_address)] = "ready"

    def _retire(self) -> None:
        super()._retire()
        if self.window is None and self.retired >= self.warm_ops:
            self.window = (self.retired, self.loop.cycle)


def precondition(pipeline: Any, dirty: float) -> None:
    """Fill every L1D and L2 set with valid lines of an unrelated region.

    A dirty share of them is modified, so a fill evicts a victim and, behind
    a long store stream, writes one back, as in the middle of a pass over a
    buffer far larger than the L2.
    """
    memory = pipeline.memory
    # The L1D's lines sit in L2 sets away from the kernels' sets.
    for cache, base in ((memory.l1d, FILL_BASE + 0x14_0000), (memory.l2, FILL_BASE)):
        base_line = base // cache.line_bytes
        for set_index in range(cache.sets_count):
            lines = []
            for way in range(cache.ways):
                line = base_line + way * cache.sets_count + set_index
                modified = (set_index + way) % 2 == 0 if dirty == 0.5 else dirty >= 1.0
                lines.append(
                    model.CacheLine(
                        tag=line // cache.sets_count, valid=True, dirty=modified
                    )
                )
            cache.sets[set_index] = lines


def run_kernel(config: Any, name: str, cpu_mhz: float) -> dict[str, Any]:
    """Run one board body and return its steady-state figure and counters."""
    kernel = board_workloads.KERNELS[name]
    builder = model.ProgramBuilder()
    kernel.build(builder)
    ops = builder.ops
    pipeline = MeasuredPipeline(config, ops, int(len(ops) * kernel.warm_fraction))
    if name != "l2_chase":
        precondition(pipeline, kernel.dirty)
    result = pipeline.run(max_cycles=50_000_000)
    assert pipeline.window is not None
    retired, start = pipeline.window
    cycles = result["cycles"] - start
    accesses = (len(ops) - retired) / len(ops) * kernel.accesses
    stats = result["pipeline"]["stats"]
    figure = (
        kernel.bytes_per_access * accesses / cycles * cpu_mhz
        if kernel.metric == "MBps"
        else cycles / accesses / cpu_mhz * 1000.0
    )
    return {
        "figure": figure,
        "unit": "MB/s" if kernel.metric == "MBps" else "ns per load",
        "cycles_per_access": cycles / accesses,
        "window_ipc": (len(ops) - retired) / cycles,
        "sq_full_fraction": stats.get("sq_full_cycles", 0) / result["cycles"],
        "l1d": result["memory"]["l1d"]["stats"],
        "l2": result["memory"]["l2"]["stats"],
        "prefetcher": result["memory"]["prefetcher"],
    }


def load_set(directory: Path) -> tuple[dict[str, Any], dict[str, Any], Any]:
    """Read a data set's manifest, measurements, and model configuration."""
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    measurements = json.loads(
        (directory / "measurements.json").read_text(encoding="utf-8")
    )
    config = model.load_config(directory / "model_config.json")
    return manifest, measurements, config


def compare(
    manifest: dict[str, Any], measurements: dict[str, Any], config: Any
) -> dict[str, Any]:
    """Run every measured body and return the model's figures and residuals."""
    cpu_mhz = manifest["clocks_mhz"]["cpu"]
    points = []
    for point in measurements["points"]:
        run = run_kernel(config, point["kernel"], cpu_mhz)
        points.append(
            {
                "name": point["name"],
                "kernel": point["kernel"],
                "role": point["role"],
                "unit": run["unit"],
                "board": point["value"],
                "model": round(run["figure"], 1),
                "residual": round(run["figure"] / point["value"] - 1, 4),
                "model_cycles_per_access": round(run["cycles_per_access"], 2),
                "model_window_ipc": round(run["window_ipc"], 3),
                "model_sq_full_fraction": round(run["sq_full_fraction"], 3),
            }
        )
    return {
        "data_set": manifest["name"],
        "model_version": model.MODEL_VERSION,
        "configuration": dataclasses.asdict(config),
        "points": points,
    }


def fit(config: Any, manifest: dict[str, Any], measurements: dict[str, Any]) -> None:
    """Print the L2 data and DDR latencies that reproduce the latency chains."""
    cpu_mhz = manifest["clocks_mhz"]["cpu"]
    target = {p["kernel"]: p["value"] for p in measurements["points"]}
    best: tuple[float, int] | None = None
    for cycles in range(1, 120):
        trial = model.with_config(config, config.name, l2_data_cycles=cycles)
        error = abs(
            run_kernel(trial, "l2_chase", cpu_mhz)["figure"] - target["l2_chase"]
        )
        if best is None or error < best[0]:
            best = (error, cycles)
        elif error > 2 * best[0] + 5:
            break
    assert best is not None
    print("l2_data_cycles", best[1], "error_ns", round(best[0], 2))
    config = model.with_config(config, config.name, l2_data_cycles=best[1])
    best = None
    for latency in range(20, 400, 2):
        ddr = dataclasses.replace(config.ddr, latency_cycles=latency)
        trial = model.with_config(config, config.name, ddr=ddr)
        error = abs(
            run_kernel(trial, "dram_chase", cpu_mhz)["figure"] - target["dram_chase"]
        )
        if best is None or error < best[0]:
            best = (error, latency)
        elif error > 2 * best[0] + 20:
            break
    assert best is not None
    print("ddr.latency_cycles", best[1], "error_ns", round(best[0], 2))


def parse_args() -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-set", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--fit", action="store_true")
    parser.add_argument(
        "--set",
        action="append",
        default=[],
        metavar="FIELD=JSON",
        help="override a ModelConfig field for every run",
    )
    return parser.parse_args()


def main() -> int:
    """Compare or fit, and print each point's residual."""
    args = parse_args()
    manifest, measurements, config = load_set(args.data_set)
    changes = {}
    for item in args.set:
        key, value = item.split("=", 1)
        changes[key] = json.loads(value)
    if changes:
        config = model.with_config(config, f"{config.name}_trial", **changes)
    if args.fit:
        fit(config, manifest, measurements)
        return 0
    record = compare(manifest, measurements, config)
    for point in record["points"]:
        print(
            f"{point['name']:<22} board {point['board']:>8} model {point['model']:>8}"
            f" {point['unit']:<12} residual {100 * point['residual']:+6.1f}%"
            f" ({point['role']})"
        )
    if args.out:
        model.dump_json(args.out, record)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
