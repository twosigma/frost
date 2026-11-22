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
import signal
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from contextlib import suppress
from pathlib import Path
from typing import Any, NamedTuple, TextIO


class ShardPlan(NamedTuple):
    """Shard count and hosted limits for one selection and vector length."""

    shards: int
    deadline_minutes: int
    job_minutes: int


SUITE = "tests/test_riscv_vector_tests.py"
ROOT = Path(__file__).resolve().parents[1]
NATIVE = ["--rtl", "--simulator", "native"]
SLICES = 20
CYCLE_PROFILE = Path("tests/fixtures/rvv_ci_profile.csv")
FORM_PROFILE = Path("tests/fixtures/rvv_ci_form_times.csv")
COMPLETE_PROFILE = Path("tests/fixtures/rvv_ci_complete_times.csv")
FORM_PLANS = {
    128: ShardPlan(4, 92, 135),
    256: ShardPlan(7, 92, 135),
    512: ShardPlan(13, 96, 139),
}
COMPLETE_PLANS = {
    128: ShardPlan(7, 297, 340),
    256: ShardPlan(11, 296, 339),
    512: ShardPlan(25, 316, 359),
}
PROGRAMS_PER_WIDTH = 3017
FORMS_PER_WIDTH = 665
SLICE_SECONDS = 90 * 60


def matrix(
    campaign: str, run_number: int, requested: str, slices_per_run: int = 1
) -> list[dict]:
    """Return one row per runner that will simulate programs."""
    if not 1 <= slices_per_run <= SLICES:
        raise ValueError(f"slices per run must be between 1 and {SLICES}")
    if requested:
        if campaign == "complete":
            raise ValueError("choose either a slice or the complete campaign")
        shard_options("slice", requested)
        parts = [requested]
    elif campaign == "complete" or slices_per_run == SLICES:
        mode, plans = (
            ("complete", COMPLETE_PLANS)
            if campaign == "complete"
            else ("forms", FORM_PLANS)
        )
        return [
            {
                "vlen": width,
                "mode": mode,
                "part": f"{k}/{plan.shards}",
                "step_minutes": plan.deadline_minutes + 3,
                "job_minutes": plan.job_minutes,
            }
            for width, plan in plans.items()
            for k in range(1, plan.shards + 1)
        ]
    else:
        start = run_number * slices_per_run
        parts = [str((start + offset) % SLICES) for offset in range(slices_per_run)]
    return [
        {"vlen": width, "mode": "slice", "part": part}
        for part in parts
        for width in COMPLETE_PLANS
    ]


def shard_options(mode: str, part: str, *, root: Path = Path(".")) -> list[str]:
    """Keep slice numbering stable and balance the full selections by profile."""
    if mode == "slice":
        if part not in {str(k) for k in range(SLICES)}:
            raise ValueError("slice must be an integer from 0 to 19")
        return ["--one-per-form", "--shard", f"{int(part) + 1}/{SLICES}"]
    if mode == "forms":
        return [
            "--one-per-form",
            "--shard-profile",
            str(root / FORM_PROFILE),
            "--shard",
            part,
        ]
    return ["--shard-profile", str(root / COMPLETE_PROFILE), "--shard", part]


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


def iter_rows(path: Path) -> Iterator[dict]:
    """Yield completed results up to the first unreadable record."""
    with path.open("rb") as stream:
        for number, line in enumerate(stream, 1):
            try:
                row = json.loads(line)
            except ValueError as exc:
                raise ValueError(f"{path.name}:{number}: {exc}") from exc
            if not isinstance(row, dict) or not isinstance(row.get("name"), str):
                raise ValueError(f"{path.name}:{number}: result needs a program name")
            yield row


def read_rows(path: Path) -> list[dict]:
    """Require the entire shard results file to be readable."""
    return list(iter_rows(path))


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


def run_until(command: list[str], deadline: float, transcript: TextIO) -> int:
    """Stop the suite and its active tools when the shard budget expires."""
    print(shlex.join(command), file=transcript, flush=True)
    with subprocess.Popen(
        command, start_new_session=True, stdout=transcript, stderr=subprocess.STDOUT
    ) as process:
        try:
            return process.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            # Let a model build release its make process group first.
            process.send_signal(signal.SIGINT)
            with suppress(subprocess.TimeoutExpired):
                process.wait(timeout=2)
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            raise


def save_failure(work: Path, output: Path, name: str, row: dict) -> str:
    """Keep the native output or build diagnostic and describe it in the summary."""
    if Path(name).name != name or name in {".", ".."}:
        return "Invalid program name."
    source = work / "images" / name / "native.log"
    log = Path("failures") / f"{name}.log"
    message = row.get("message")
    if not isinstance(message, str):
        message = ""
    reason = message.removesuffix(f" ({source})")
    if source.is_file() or message:
        (output / log).parent.mkdir(exist_ok=True)
        if source.is_file():
            shutil.copyfile(source, output / log)
        else:
            (output / log).write_text(message + "\n")
        if message:
            row["message"] = f"{reason} ({log})"
        detail = reason.splitlines()[0] if reason else "No verified pass"
        return f"{detail}. See `{log}` in the shard artifact."
    return "No verified pass." if row else "No result recorded."


def run_shard(
    vlen: int, mode: str, part: str, output: Path, prebuilt: Path | None
) -> int:
    """Run one shard and leave its command and per-program evidence."""
    from test_riscv_vector_tests import parse_makefrag

    selection = shard_options(mode, part)
    seconds = SLICE_SECONDS
    if mode != "slice":
        plan = (FORM_PLANS if mode == "forms" else COMPLETE_PLANS)[vlen]
        if part not in {f"{k}/{plan.shards}" for k in range(1, plan.shards + 1)}:
            raise ValueError(f"invalid {mode} shard for VLEN {vlen}: {part}")
        seconds = plan.deadline_minutes * 60

    output.mkdir(parents=True, exist_ok=True)
    results = output / "results.jsonl"
    manifest = output / "simulator.json"
    selected = output / "selected.txt"
    for old in (results, manifest, selected, *(output / "failures").glob("*.log")):
        old.unlink(missing_ok=True)
    summary = output / "summary.md"
    summary.write_text(
        f"### Generated vectors at VLEN {vlen}, {mode} {part}\n\n"
        f"```sh\n{reproduce(vlen, selection)}\n```\n"
    )
    deadline = time.monotonic() + seconds
    with (
        tempfile.TemporaryDirectory(prefix="rvv-ci-") as tmp,
        summary.open("a") as log,
        (output / "shard.log").open("w") as transcript,
    ):
        work = Path(tmp)
        command = [
            sys.executable,
            "-u",
            str(ROOT / SUITE),
            *NATIVE,
            "--vlen",
            str(vlen),
            "--workdir",
            str(work),
        ]
        try:
            if prebuilt is None:
                prebuilt = work / "model/frost-native"
                build = [*command, "--sim-threads", "4", "--build-sim", str(prebuilt)]
                if run_until(build, deadline, transcript):
                    print(
                        "\nSimulator build failed. Zero programs ran. See `shard.log`.",
                        file=log,
                    )
                    return 1
            shutil.copyfile(f"{prebuilt}.json", manifest)
            status = run_until(
                [
                    *command,
                    "--prebuilt-sim",
                    str(prebuilt),
                    *shard_options(mode, part, root=ROOT),
                    "--results-jsonl",
                    str(results),
                ],
                deadline,
                transcript,
            )
        except subprocess.TimeoutExpired:
            print(
                f"\nShard exceeded its {seconds:g}-second deadline. See `shard.log`.",
                file=log,
            )
            status = 1
        except OSError as exc:
            print(f"\nCould not run the suite: {exc}", file=log)
            return 1
        makefrag = work / "Makefrag"
        if not makefrag.exists():
            print(
                "\nThe suite stopped before recording its selection. See `shard.log`.",
                file=log,
            )
            return 1
        names = parse_makefrag(makefrag.read_text())
        selected.write_text("".join(f"{name}\n" for name in names))
        rows: list[dict] = []
        read_error = ""
        try:
            rows.extend(iter_rows(results))
        except (OSError, ValueError) as exc:
            read_error = f"Could not read the results: {exc}"
        ran, failed, errors = check_rows(names, rows, vlen)
        if read_error:
            errors.append(read_error)
        expected = PROGRAMS_PER_WIDTH if mode == "complete" else FORMS_PER_WIDTH
        try:
            count = json.loads((work / "selection.json").read_text())["selection_count"]
            if type(count) is not int or count != expected:
                errors.append(
                    f"Expected {expected} programs before sharding, found {count}"
                )
        except (OSError, ValueError, KeyError, TypeError) as exc:
            errors.append(f"Could not read the selection count: {exc}")
        print(
            f"\n{len(names)} selected, {ran} ran, {len(failed)} failed or unverified.",
            file=log,
        )
        for error in errors:
            print(f"\n{error}.", file=log)
        by_name = {row["name"]: row for row in rows}
        for name in failed:
            detail = save_failure(work, output, name, by_name.get(name, {}))
            print(f"\n`{name}` at VLEN {vlen}: {detail}\n", file=log)
            print(f"```sh\n{reproduce(vlen, ['--test', name])}\n```", file=log)
        if failed and rows and not read_error:
            temp = results.with_suffix(".tmp")
            temp.write_text("".join(json.dumps(row) + "\n" for row in rows))
            temp.replace(results)
        return int(bool(status or errors or failed))


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
    for vlen, plan in COMPLETE_PLANS.items():
        merged = output / f"v{vlen}.jsonl"
        merged.unlink(missing_ok=True)
        item: dict[str, Any] = {"vlen": vlen, "passed": False}
        widths.append(item)
        try:
            shards = sorted(artifacts.glob(f"rvv-v{vlen}-*"))
            if len(shards) != plan.shards:
                raise ValueError(f"expected {plan.shards} shards, found {len(shards)}")
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
    plan.add_argument("--slices-per-run", type=int, default=1)
    plan.add_argument("--slice", default="")
    run = commands.add_parser("run")
    run.add_argument("vlen", type=int, choices=COMPLETE_PLANS)
    run.add_argument("mode", choices=("slice", "forms", "complete"))
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
            rows = matrix(
                args.campaign, args.run_number, args.slice, args.slices_per_run
            )
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
