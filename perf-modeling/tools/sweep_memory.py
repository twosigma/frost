#!/usr/bin/env python3
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

"""Sweep cache resources and physical-channel service with explicit configurations."""

import argparse
import dataclasses
import hashlib
import subprocess
import sys
from collections import deque
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import frost_perf_model as model

PERF = Path(__file__).resolve().parents[1]


def configurations(group: str) -> list[Any]:
    """Return independent resource probes and a channel/concurrency grid."""
    base = model.ModelConfig()
    configs = [base]
    if group == "outstanding":
        for endpoint in ("behavioral", "channel1", "channel2"):
            ddr = (
                base.ddr
                if endpoint == "behavioral"
                else dataclasses.replace(
                    base.ddr,
                    controller="interleaved",
                    channels=int(endpoint[-1]),
                    num_slots=32,
                    cycles_per_line=4,
                )
            )
            for misses in (4, 8, 12, 16):
                for profile, l1d, lq, inflight, distance in (
                    ("base", 8, 8, 4, 8),
                    ("prefetch8", 8, 8, 8, 8),
                    ("distance16", 8, 8, 4, 16),
                    ("prefetch8_distance16", 8, 8, 8, 16),
                    ("l1d16", 16, 8, 4, 8),
                    ("lq16", 8, 16, 4, 8),
                    ("feed16", 16, 16, 8, 16),
                ):
                    configs.append(
                        model.with_config(
                            base,
                            f"{endpoint}_l2_{misses}_{profile}",
                            l2_mshrs=misses,
                            l1d_mshrs=l1d,
                            l1d_id_bits=1 + (l1d - 1).bit_length(),
                            load_queue_entries=lq,
                            l2_prefetch_inflight=inflight,
                            l2_prefetch_distance=distance,
                            ddr=ddr,
                        )
                    )
        return configs
    if group in {"x3", "all"}:
        for field, values in (
            ("l1d_mshrs", [1, 2, 4]),
            ("l2_mshrs", [1, 2, 8, 12, 16]),
            ("axi_id_pool_size", [1, 2, 4, 8, 16]),
            ("l2_bytes", [65536, 262144, 1048576, 4194304]),
        ):
            configs.extend(
                model.with_config(base, f"{field}_{value}", **{field: value})
                for value in values
            )
        for latency in [10, 60, 120]:
            configs.append(
                model.with_config(
                    base,
                    f"latency_{latency}",
                    ddr=dataclasses.replace(base.ddr, latency_cycles=latency),
                )
            )
        for bits in [6, 7]:
            configs.append(
                model.with_config(
                    base,
                    f"axi_width_{bits}",
                    axi_id_bits=bits,
                    cpu_axi_id_bits=bits + 1,
                    ddr=dataclasses.replace(base.ddr, id_bits=bits),
                )
            )
    if group in {"channels", "all"}:
        for latency in [30, 60]:
            for interval in [1, 4, 8]:
                for channels in [1, 2, 4]:
                    for misses in [4, 16]:
                        cfg = model.with_config(
                            base,
                            f"channels_{channels}_latency_{latency}_interval_{interval}_l2_{misses}",
                            l2_mshrs=misses,
                            ddr=dataclasses.replace(
                                base.ddr,
                                controller="interleaved",
                                channels=channels,
                                num_slots=64,
                                latency_cycles=latency,
                                cycles_per_line=interval,
                            ),
                        )
                        configs.append(cfg)
    return configs


def controller_probe(
    channels: int,
    latency: int,
    interval: int,
    outstanding: int,
    transactions: int = 4096,
) -> dict[str, Any]:
    """Measure a read stream through the shared AXI port without a CPU bottleneck.

    Each accepted line has a distinct internal owner until its response.
    Cache ID capacity and endpoint queues cover the largest pool under test.
    """
    if not 1 <= outstanding <= 128:
        raise ValueError("probe requires 1..128 owners")
    minimum_transactions = max(256, 8 * outstanding)
    if transactions < minimum_transactions:
        raise ValueError(f"probe requires at least {minimum_transactions} transactions")
    config = model.with_config(
        model.ModelConfig(),
        "controller_probe",
        l2_mshrs=128,
        l2_id_bits=8,
        axi_id_bits=8,
        cpu_axi_id_bits=9,
        axi_id_pool_size=outstanding,
        ddr=model.DdrConfig(
            controller="interleaved",
            id_bits=8,
            channels=channels,
            latency_cycles=latency,
            cycles_per_line=interval,
            num_slots=128,
        ),
    )
    loop = model.EventLoop()
    soc = model.SocTopModel(config, loop)
    bridge = model.AxiBridge(loop, soc, 64, 8, outstanding)
    free = deque(range(128))
    issued = 0
    completed: list[int] = []

    def finish(slot: int, ok: bool) -> None:
        if not ok:
            raise RuntimeError("probe transaction failed")
        free.append(slot)
        completed.append(loop.cycle)

    limit = transactions * (latency + channels * interval + 10) * 4
    while len(completed) < transactions:
        if loop.cycle > limit:
            raise RuntimeError("controller probe timed out")
        loop.run_ready()
        if issued < transactions and free:
            slot = free[0]
            request = model.Request(
                config.soc.ddr_base + issued * 64,
                False,
                "probe",
                model.TransactionId("probe", "fill", slot, 8),
                lambda ok, slot=slot: finish(slot, ok),
            )
            if bridge.submit(request):
                free.popleft()
                issued += 1
        loop.cycle += 1
    bridge._account()
    ideal = min(1.0, channels / interval)
    throughput = (transactions - 1) / (completed[-1] - completed[0])
    return {
        "configuration": dataclasses.asdict(config),
        "transactions": transactions,
        "measurement": "finite_response_window",
        "cycles": loop.cycle,
        "first_response_cycle": completed[0],
        "last_response_cycle": completed[-1],
        "lines_per_cycle": throughput,
        "ideal_lines_per_cycle": ideal,
        "fraction_of_ideal": throughput / ideal,
        "axi": dict(bridge.stats),
        "ddr": soc.ddr.summary(),
    }


def provenance() -> dict[str, Any]:
    """Record the source revision and hashes of the experiment implementation."""
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=PERF,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return {
        "commit": commit,
        "source_sha256": {
            str(path.relative_to(PERF)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in [
                PERF / "frost_perf_model.py",
                PERF / "memory_workloads.py",
                Path(__file__),
            ]
        },
    }


def main() -> None:
    """Write complete configurations and results for each selected experiment."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument(
        "--group",
        choices=["x3", "channels", "controller", "outstanding", "all"],
        default="all",
    )
    parser.add_argument(
        "--kernels",
        nargs="+",
        choices=["coremark", *model.KERNELS],
        default=["coremark", *model.KERNELS],
    )
    parser.add_argument("--scale-shift", type=int, default=4)
    parser.add_argument("--passes", type=int, default=1)
    parser.add_argument("--mlp-lines", type=int, default=512)
    parser.add_argument("--probe-transactions", type=int, default=4096)
    args = parser.parse_args()
    if args.group in {"controller", "all"} and args.probe_transactions < 1024:
        parser.error("the controller grid requires at least 1024 probe transactions")
    results: dict[str, Any] = {
        "provenance": provenance(),
        "runs": [],
        "controller_probes": [],
    }
    if args.group != "controller":
        for config in configurations(args.group):
            for kernel in args.kernels:
                result = (
                    model.run_workload(config, "coremark", 11)
                    if kernel == "coremark"
                    else model.run_memory_kernel(
                        config, kernel, args.scale_shift, args.mlp_lines, args.passes
                    )
                )
                results["runs"].append(result)
            print(f"completed {config.name}", file=sys.stderr, flush=True)
    if args.group in {"controller", "all"}:
        for latency in [10, 30, 60, 120]:
            for interval in [1, 4, 8]:
                for channels in [1, 2, 4]:
                    for outstanding in [1, 2, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128]:
                        results["controller_probes"].append(
                            controller_probe(
                                channels,
                                latency,
                                interval,
                                outstanding,
                                args.probe_transactions,
                            )
                        )
                    print(
                        f"completed controller channels={channels} latency={latency} interval={interval}",
                        file=sys.stderr,
                        flush=True,
                    )
    model.dump_json(args.out, results)


if __name__ == "__main__":
    main()
