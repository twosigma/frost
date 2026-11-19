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

"""Select, run and report the generated vector shards in CI."""

import argparse
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

SUITE = "tests/test_riscv_vector_tests.py"
ROOT = Path(__file__).resolve().parents[1]
NATIVE = ["--rtl", "--simulator", "native"]
SLICES = 20
# The wider programs account for most of the simulation cycles.
COMPLETE_SHARDS = {128: 3, 256: 3, 512: 14}
PROGRAMS_PER_WIDTH = 3017


def matrix(campaign: str, run_number: int, requested: str) -> list[dict]:
    """Return one row per runner that will simulate programs."""
    if campaign == "complete":
        if requested:
            raise ValueError("choose either a slice or the complete campaign")
        return [
            {"vlen": width, "mode": "complete", "part": f"{k}/{count}"}
            for width, count in COMPLETE_SHARDS.items()
            for k in range(1, count + 1)
        ]
    part = requested if requested else str(run_number % SLICES)
    shard_options("slice", part)
    return [{"vlen": width, "mode": "slice", "part": part} for width in COMPLETE_SHARDS]


def shard_options(mode: str, part: str) -> list[str]:
    """Translate a zero-based slice into the suite's one-based shard."""
    if mode == "slice":
        if part not in {str(k) for k in range(SLICES)}:
            raise ValueError("slice must be an integer from 0 to 19")
        return ["--one-per-form", "--shard", f"{int(part) + 1}/{SLICES}"]
    return ["--shard", part]


def reproduce(vlen: int, selection: list[str]) -> str:
    """Print a local command with the shard's memory settings."""
    command = [
        "./scripts/frost.py",
        "run",
        "python3",
        SUITE,
        *NATIVE,
        "--sim-threads",
        "4",
        "--vlen",
        str(vlen),
        *selection,
    ]
    seed = os.environ.get("FROST_DDR_MODEL_SEED")
    prefix = f"FROST_DDR_MODEL_SEED={shlex.quote(seed)} " if seed else ""
    return prefix + shlex.join(command)


def read_rows(path: Path) -> list[dict]:
    """Read all completed results from one shard."""
    rows = []
    for line in path.read_text().splitlines():
        row = json.loads(line)
        if not isinstance(row, dict) or not isinstance(row.get("name"), str):
            raise ValueError(f"{path}: result needs a program name")
        rows.append(row)
    return rows


def check_rows(
    names: list[str], rows: list[dict], vlen: int
) -> tuple[int, list[str], list[str]]:
    """Check the selection, observed runs and assertion-enabled passes."""
    expected = set(names)
    seen = set()
    passed = set()
    ran = 0
    errors = []
    for row in rows:
        name = row["name"]
        if name in seen:
            errors.append(f"Duplicate result for {name}")
            passed.discard(name)
            continue
        seen.add(name)
        cycles = row.get("cycles")
        wall = row.get("wall_seconds")
        image = row.get("image_sha256")
        executed = type(cycles) is int and cycles > 0
        ran += int(executed)
        if (
            row.get("vlen") == vlen
            and row.get("simulator") == "native"
            and row.get("verdict") == "PASS"
            and executed
            and isinstance(wall, (float, int))
            and not isinstance(wall, bool)
            and math.isfinite(wall)
            and wall > 0
            and row.get("assertions_armed") is True
            and isinstance(image, str)
            and re.fullmatch("[0-9a-f]{64}", image)
        ):
            passed.add(name)
    if not names:
        errors.append("Zero programs selected")
    if len(names) != len(expected):
        errors.append("Duplicate names in the selection")
    if not ran:
        errors.append("Zero programs ran with a recorded cycle count")
    if expected != seen:
        errors.append("Result names do not match the selection")
    return ran, sorted(expected - passed), errors


def run_shard(
    vlen: int, mode: str, part: str, output: Path, prebuilt: Path | None
) -> int:
    """Run one shard and leave its command and per-program evidence."""
    from test_riscv_vector_tests import parse_makefrag

    selection = shard_options(mode, part)
    if mode == "complete" and part not in {
        f"{k}/{COMPLETE_SHARDS[vlen]}" for k in range(1, COMPLETE_SHARDS[vlen] + 1)
    }:
        raise ValueError(f"invalid complete shard for VLEN {vlen}: {part}")

    output.mkdir(parents=True, exist_ok=True)
    results = output / "results.jsonl"
    manifest = output / "simulator.json"
    selected = output / "selected.txt"
    for old in (results, manifest, selected):
        old.unlink(missing_ok=True)
    summary = output / "summary.md"
    summary.write_text(
        f"### Generated vectors at VLEN {vlen}, {mode} {part}\n\n"
        f"```sh\n{reproduce(vlen, selection)}\n```\n"
    )
    command = [sys.executable, str(ROOT / SUITE), *NATIVE, "--vlen", str(vlen)]
    with tempfile.TemporaryDirectory(prefix="rvv-ci-") as tmp, summary.open("a") as log:
        work = Path(tmp)
        if prebuilt is None:
            prebuilt = work / "model/frost-native"
            build = subprocess.run(
                [*command, "--sim-threads", "4", "--build-sim", str(prebuilt)]
            )
            if build.returncode:
                print("\nSimulator build failed. Zero programs ran.", file=log)
                return 1
        try:
            shutil.copyfile(f"{prebuilt}.json", manifest)
            run = subprocess.run(
                [
                    *command,
                    "--prebuilt-sim",
                    str(prebuilt),
                    *selection,
                    "--workdir",
                    str(work),
                    "--results-jsonl",
                    str(results),
                ]
            )
            makefrag = work / "Makefrag"
            if not makefrag.exists():
                print("\nThe suite stopped before recording its selection.", file=log)
                return 1
            names = parse_makefrag(makefrag.read_text())
            selected.write_text("".join(f"{name}\n" for name in names))
            try:
                rows = read_rows(results)
            except (OSError, ValueError) as exc:
                print(f"\nCould not read the results: {exc}", file=log)
                rows = []
            ran, failed, errors = check_rows(names, rows, vlen)
            print(
                f"\n{len(names)} selected, {ran} ran, {len(failed)} failed or unverified.",
                file=log,
            )
            for error in errors:
                print(f"\n{error}.", file=log)
            for name in failed:
                print(f"\n`{name}` at VLEN {vlen}\n", file=log)
                print(f"```sh\n{reproduce(vlen, ['--test', name])}\n```", file=log)
            return int(bool(run.returncode or errors or failed))
        except (OSError, ValueError, KeyError) as exc:
            print(f"\nCould not verify shard results: {exc}", file=log)
            return 1


def collect(artifacts: Path, output: Path, shard_status: str = "success") -> int:
    """Verify all complete-campaign shards and keep the merged evidence."""
    from rvv_simulator import VectorSimulator, file_sha256, native_source_identity
    from test_riscv_vector_tests import DEFAULT_DDR_BYTES, SUITE_DIR, merge_results

    output.mkdir(parents=True, exist_ok=True)
    for name in ("evidence.json", "summary.md"):
        (output / name).unlink(missing_ok=True)
    widths: list[dict[str, Any]] = []
    lines = ["### Complete generated vector campaign", ""]
    sources = native_source_identity(os.environ.copy())
    for vlen, count in COMPLETE_SHARDS.items():
        merged = output / f"v{vlen}.jsonl"
        merged.unlink(missing_ok=True)
        item: dict[str, Any] = {"vlen": vlen, "passed": False}
        widths.append(item)
        try:
            shards = sorted(artifacts.glob(f"rvv-v{vlen}-*"))
            if len(shards) != count:
                raise ValueError(f"expected {count} shards, found {len(shards)}")
            settings = VectorSimulator(
                "native", vlen, DEFAULT_DDR_BYTES, 1
            ).model_settings
            binaries = {}
            selected_count = 0
            ran = 0
            failed = []
            errors: list[str] = []
            for shard in shards:
                manifest = json.loads((shard / "simulator.json").read_text())
                if (
                    not isinstance(manifest, dict)
                    or manifest.get("sources") != sources
                    or manifest.get("settings") != settings
                    or not isinstance(manifest.get("sha256"), str)
                    or not re.fullmatch("[0-9a-f]{64}", manifest["sha256"])
                ):
                    raise ValueError(f"{shard.name}: native simulator identity differs")
                binaries[shard.name] = manifest["sha256"]
                names = (shard / "selected.txt").read_text().splitlines()
                runs, failures, issues = check_rows(
                    names, read_rows(shard / "results.jsonl"), vlen
                )
                selected_count += len(names)
                ran += runs
                failed.extend(failures)
                errors.extend(f"{shard.name}: {issue}" for issue in issues)
            item.update(settings=settings, executables=binaries)
            paths = [shard / "results.jsonl" for shard in shards]
            status = merge_results(paths, merged)
            rows = read_rows(merged)
            item.update(
                selected=selected_count,
                ran=ran,
                failures=sorted(failed),
                errors=errors,
                results_sha256=hashlib.sha256(merged.read_bytes()).hexdigest(),
            )
            if status or failed or errors or len(rows) != PROGRAMS_PER_WIDTH:
                raise ValueError(
                    f"{len(rows)} results, {ran} ran, {len(failed)} failed"
                )
            item["passed"] = True
            lines.append(f"- VLEN {vlen} passed all {ran} programs.")
        except (OSError, KeyError, ValueError) as exc:
            item["error"] = str(exc)
            lines.append(f"- VLEN {vlen} failed verification: {exc}")
    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True, cwd=ROOT
    ).strip()
    if shard_status != "success":
        lines.append(f"\nThe shard jobs ended with status `{shard_status}`.")
    passed = shard_status == "success" and all(item["passed"] for item in widths)
    if passed:
        total = sum(item["ran"] for item in widths)
        lines.append(f"\nAll {total:,} programs passed with assertions armed.")
    evidence = {
        "commit": commit,
        "run_url": os.environ.get("FROST_RVV_RUN_URL"),
        "image_id": os.environ.get("FROST_RVV_IMAGE_ID"),
        "ddr_seed": os.environ.get("FROST_DDR_MODEL_SEED"),
        "shard_status": shard_status,
        "passed": passed,
        "sources": sources,
        "widths": widths,
        "tools": {
            name: file_sha256(SUITE_DIR / "build" / name)
            for name in ("generator", "merger", "pspike")
        },
    }
    (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    (output / "summary.md").write_text("\n".join(lines) + "\n")
    return int(not evidence["passed"])


def main() -> int:
    """Select the workflow matrix or run its checks."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("matrix")
    plan.add_argument(
        "--campaign", choices=("rotation", "complete"), default="rotation"
    )
    plan.add_argument("--run-number", type=int, required=True)
    plan.add_argument("--slice", default="")
    run = commands.add_parser("run")
    run.add_argument("vlen", type=int, choices=COMPLETE_SHARDS)
    run.add_argument("mode", choices=("slice", "complete"))
    run.add_argument("part")
    run.add_argument("--output", type=Path, default=Path("rvv-results"))
    run.add_argument("--prebuilt-sim", type=Path)
    merge = commands.add_parser("collect")
    merge.add_argument("artifacts", type=Path)
    merge.add_argument("output", type=Path)
    merge.add_argument("--shard-status", default="success")
    args = parser.parse_args()
    try:
        if args.command == "matrix":
            rows = matrix(args.campaign, args.run_number, args.slice)
            print(json.dumps({"include": rows}, separators=(",", ":")))
            return 0
        if args.command == "collect":
            return collect(args.artifacts, args.output, args.shard_status)
        return run_shard(
            args.vlen, args.mode, args.part, args.output, args.prebuilt_sim
        )
    except ValueError as exc:
        parser.exit(2, f"error: {exc}\n")


if __name__ == "__main__":
    sys.exit(main())
