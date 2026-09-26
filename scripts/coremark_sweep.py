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

"""Run and archive cycle-exact CoreMark simulations in the frost Docker image.

The sweep covers seed sets, link orders, compressed code and memory tiers, and
archives what each run needs to be reproduced. Each CoreMark report covers one
iteration with a synthetic timer, so its CoreMark/MHz is only a diagnostic for
comparing cycle counts, not a benchmark score.
"""

import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ("core_list_join", "core_main", "core_matrix", "core_state", "core_util")
CRCS = {
    "performance": ("e9f5", "e714", "1fd7", "8e3a"),
    "validation": ("18f2", "e3c1", "0747", "8d84"),
}


def parse_reports(log: str, seed_set: str, runs: int) -> list[dict]:
    """Parse one CRC-validated CoreMark report per run from the log."""
    reports = []
    for chunk in log.split("CoreMark Size")[1:]:

        def field(name: str) -> str:
            match = re.search(rf"^{re.escape(name)}\s*:\s*([^\r\n]+)", chunk, re.M)
            if not match:
                raise ValueError(f"missing CoreMark field: {name}")
            return match[1].strip()

        crc = tuple(
            field(name).lower().removeprefix("0x").zfill(4)
            for name in ("seedcrc", "[0]crclist", "[0]crcmatrix", "[0]crcstate")
        )
        if crc != CRCS[seed_set] or "Correct operation validated." not in chunk:
            raise ValueError(f"unvalidated {seed_set} report: {crc}")
        ticks, iterations = int(field("Total ticks")), int(field("Iterations"))
        if ticks <= 0 or iterations != 1:
            raise ValueError("expected a positive one-iteration simulation tick count")
        reports.append(
            {
                "ticks": ticks,
                "iterations": iterations,
                "crcs": crc,
                "coremark_per_mhz_diagnostic": 1_000_000 * iterations / ticks,
                "compiler": field("Compiler version"),
                "flags": field("Compiler flags"),
                "memory_location": field("Memory location"),
                "official_length": False,
            }
        )
    if len(reports) != runs:
        raise ValueError(f"expected {runs} reports, found {len(reports)}")
    return reports


def link_orders(count: int) -> list[tuple[str, ...]]:
    """Return the natural link order, then count - 1 others in a fixed shuffle."""
    if not 1 <= count <= 120:
        raise ValueError("orders must be between 1 and 120")
    remaining = [order for order in itertools.permutations(SOURCES) if order != SOURCES]
    random.Random(322265625).shuffle(remaining)
    return [SOURCES, *remaining[: count - 1]]


def capture(*command: str) -> str:
    """Return a command's stripped stdout, raising if the command fails."""
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def fingerprint() -> str:
    """Return a digest of the sources, to detect edits during the sweep."""
    digest = hashlib.sha256(capture("git", "rev-parse", "HEAD").encode())
    digest.update(
        subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=ROOT)
    )
    for name in sorted(
        capture("git", "ls-files", "--others", "--exclude-standard").splitlines()
    ):
        path = ROOT / name
        if path.is_file():
            digest.update(name.encode())
            digest.update(path.read_bytes())
    # git diff shows an edited submodule only as dirty, so a second edit would
    # not change it: hash the benchmark sources directly.
    benchmark = ROOT / "sw/apps/coremark/coremark"
    for path in sorted([*benchmark.glob("*.c"), *benchmark.glob("*.h")]):
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    for path in sorted(benchmark.parent.glob("sw.elf-*.gcda")):
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def main(argv: list[str] | None = None) -> int:
    """Run and archive each requested configuration, stopping at the first failure."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--orders", type=int, default=4)
    parser.add_argument(
        "--compressed", choices=("0", "1"), nargs="+", default=["0", "1"]
    )
    parser.add_argument(
        "--memory", choices=("bram", "ddr"), nargs="+", default=["bram", "ddr"]
    )
    parser.add_argument("--seeds", choices=tuple(CRCS), nargs="+", default=list(CRCS))
    parser.add_argument(
        "--runs",
        type=int,
        default=1,
        help="runs per BRAM configuration, with a reset between runs; DDR runs once",
    )
    parser.add_argument("--pgo", choices=("0", "1"), default="1")
    parser.add_argument(
        "--tune-flags",
        help="APP_TUNE_FLAGS for every build, recorded with each result",
    )
    parser.add_argument("--verilator-arg", action="append", default=[])
    args = parser.parse_args(argv)
    if args.runs < 1:
        parser.error("--runs must be positive")
    orders = link_orders(args.orders)
    output = args.output.resolve()
    if output.is_relative_to(ROOT):
        parser.error(
            "--output must be outside the checkout to keep source fingerprints stable"
        )
    output.mkdir(parents=True, exist_ok=False)
    source_hash = fingerprint()
    metadata = {
        "revision": capture("git", "rev-parse", "HEAD"),
        "source_fingerprint": source_hash,
        "docker_image": capture(
            "docker",
            "image",
            "inspect",
            os.environ.get("FROST_DOCKER_IMAGE", "frost"),
            "--format",
            "{{.Id}}",
        ),
        "command": [
            str(Path(__file__).resolve()),
            *(argv if argv is not None else sys.argv[1:]),
        ],
        "official_length": False,
        "requested_bram_runs": args.runs,
        "note": "One iteration with synthetic timer frequency; compare matching run indices. "
        "DDR runs once, matching the repository's reset/image-loading contract.",
        "benchmark_sources": {
            name: hashlib.sha256(
                (ROOT / "sw/apps/coremark/coremark" / (name + ".c")).read_bytes()
            ).hexdigest()
            for name in SOURCES
        },
        "benchmark_gitlink": capture(
            "git", "ls-tree", "HEAD", "sw/apps/coremark/coremark"
        ),
        "profile_inputs": {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted((ROOT / "sw/apps/coremark").glob("sw.elf-*.gcda"))
        }
        if args.pgo == "1"
        else {},
    }
    (output / "source.patch").write_bytes(
        subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=ROOT)
    )
    for name in capture(
        "git", "ls-files", "--others", "--exclude-standard"
    ).splitlines():
        path = ROOT / name
        if path.is_file():
            target = output / "untracked" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
    (output / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
    benchmark = ROOT / "sw/apps/coremark/coremark"
    (output / "benchmark").mkdir()
    for path in [*benchmark.glob("*.c"), *benchmark.glob("*.h")]:
        shutil.copy2(path, output / "benchmark" / path.name)
    if args.pgo == "1":
        (output / "profiles").mkdir()
        for path in benchmark.parent.glob("sw.elf-*.gcda"):
            shutil.copy2(path, output / "profiles" / path.name)
    for index, order in enumerate(orders):
        for compressed, memory, seeds in itertools.product(
            args.compressed, args.memory, args.seeds
        ):
            name = f"order-{index}-c{compressed}-{memory}-{seeds}"
            directory = output / name
            directory.mkdir()
            runs = 1 if memory == "ddr" else args.runs
            settings = {
                "COCOTB_NUM_RUNS": str(runs),
                "FROST_COCOTB_MEM_CONFIG": memory,
                "FROST_VERILATOR_EXTRA_ARGS": " ".join(args.verilator_arg),
                "COREMARK_COMPRESSED": compressed,
                "COREMARK_SEED_SET": seeds,
                "COREMARK_SOURCE_ORDER": " ".join(order),
                "COREMARK_PGO": args.pgo,
            }
            if args.tune_flags is not None:
                settings["APP_TUNE_FLAGS"] = args.tune_flags
            command = [
                str(ROOT / "scripts/frost.py"),
                "run",
                "env",
                "MAKEFLAGS=-j16",
                *(f"{key}={value}" for key, value in settings.items()),
                "bash",
                "-c",
                "cd tests && make clean && exec ./test_run_cocotb.py coremark",
            ]
            print(f"Running {name}", flush=True)
            with (directory / "run.log").open("w") as log:
                result = subprocess.run(
                    command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT
                )
            record: dict[str, Any] = {
                "command": command,
                "settings": settings,
                "returncode": result.returncode,
            }
            app = ROOT / "sw/apps/coremark"
            for artifact in (
                "sw.elf",
                "sw.bin",
                "sw.S",
                "sw_ddr.bin",
                ".frost-build-config.bin",
            ):
                path = app / artifact
                if path.is_file():
                    shutil.copy2(path, directory / path.name)
                    record[artifact + "_sha256"] = hashlib.sha256(
                        path.read_bytes()
                    ).hexdigest()
            failure = None
            try:
                if result.returncode:
                    raise ValueError(f"simulation exited {result.returncode}")
                record["reports"] = parse_reports(
                    (directory / "run.log").read_text(), seeds, runs
                )
                if fingerprint() != source_hash:
                    raise ValueError(
                        "source changed during sweep; discard comparisons across revisions"
                    )
            except ValueError as error:
                failure = str(error)
                record["error"] = failure
            (directory / "result.json").write_text(json.dumps(record, indent=2) + "\n")
            if failure:
                print(f"{name}: {failure}", file=sys.stderr)
                return 1
            print(
                f"{name}: {[r['ticks'] for r in record['reports']]} ticks", flush=True
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
