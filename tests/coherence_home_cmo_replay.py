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

"""Replay the verified home CMO cover or run the standalone cover and replay."""

import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DRIVER = "verilog_defines -D COHERENCE_HOME_CMO_WITNESS"
SLANG_DRIVER = "-DCOHERENCE_HOME_CMO_WITNESS"
SLANG_FAST_COVER = "-DCOHERENCE_HOME_CMO_FAST_COVER"
REACHED = re.compile(r"Reached cover statement in step (\d+) at [^:]+: (\S+)")
UNREACHED = re.compile(r"Unreached cover statement at [^:]+: (\S+)")


def strip_witness_driver(script: str) -> tuple[str, int]:
    """Remove the single witness-driver define and return the script and expected cover count."""
    lines = script.splitlines()
    if DRIVER in lines:
        if lines.count(DRIVER) != 1 or any(SLANG_DRIVER in line for line in lines):
            raise ValueError("Expected exactly one CMO witness driver define")
        lines.remove(DRIVER)
        return "\n".join(lines) + "\n", 4

    slang_hits = 0
    fast_cover = False
    updated: list[str] = []
    for line in lines:
        tokens = line.split()
        if tokens and tokens[0] == "read_slang" and SLANG_DRIVER in tokens:
            slang_hits += tokens.count(SLANG_DRIVER)
            fast_cover = fast_cover or SLANG_FAST_COVER in tokens
            line = " ".join(tok for tok in tokens if tok != SLANG_DRIVER)
        elif SLANG_DRIVER in line:
            raise ValueError("Unexpected CMO witness driver define outside read_slang")
        updated.append(line)
    if slang_hits != 1:
        raise ValueError("Expected exactly one CMO witness driver define")
    return "\n".join(updated) + "\n", 5 if fast_cover else 4


def primary_inputs(trace: Path, names: set[str], last: int) -> str:
    """Keep exactly one value per primary input and frame, starting at reset."""
    frames: dict[int, dict[str, str]] = {}
    frame = -1
    for line in trace.read_text().splitlines():
        state = re.fullmatch(r"state (\d+)", line)
        if state:
            frame = int(state[1])
            if frame != len(frames):
                raise ValueError(f"Nonconsecutive input frames in {trace}")
            frames[frame] = {}
        match = re.fullmatch(
            r"assume \(= \[([^\]]+)\] (true|false|#[bx][0-9a-fA-F]+)\)", line
        )
        if frame >= 0 and match and match[1] in names:
            if match[1] in frames[frame]:
                raise ValueError(f"Duplicate input {match[1]} at frame {frame}")
            frames[frame][match[1]] = line

    if (
        not names
        or frame != last
        or any(row.keys() != names for row in frames.values())
    ):
        raise ValueError(f"Incomplete primary inputs in {trace} through frame {last}")
    return "".join(
        f"state {step}\n" + "".join(f"{line}\n" for line in inputs.values())
        for step, inputs in frames.items()
    )


def witness_traces(engine: Path) -> dict[str, tuple[int, Path]]:
    """Associate each reached source predicate with the trace written for it."""
    witnesses: dict[str, tuple[int, Path]] = {}
    pending: list[tuple[str, int]] = []
    for line in (engine / "logfile.txt").read_text().splitlines():
        hit = REACHED.search(line)
        if hit:
            pending.append((hit[2], int(hit[1])))
        trace = re.search(
            r"Writing trace to constraints file: engine_0/(trace\d+\.smtc)", line
        )
        if trace:
            for goal, step in pending:
                if goal in witnesses:
                    raise ValueError(f"Duplicate cover result for {goal}")
                witnesses[goal] = step, engine / trace[1]
            pending.clear()
    if pending:
        raise ValueError("Missing trace after a reached cover")
    return witnesses


def undriven_model(driven: Path, dest: Path, deadline: float) -> tuple[Path, int]:
    """Rebuild the same SBY model with only the witness-driver define removed."""
    shutil.copytree(driven / "src", dest / "src")
    model = dest / "model"
    model.mkdir()
    expected_goals = 4
    for stage in ("design", "design_prep", "design_smt2"):
        script = (driven / "model" / f"{stage}.ys").read_text()
        if stage == "design":
            script, expected_goals = strip_witness_driver(script)
        path = model / f"{stage}.ys"
        path.write_text(script)
        subprocess.run(
            ["yosys", "-Q", "-T", "-q", str(path)],
            cwd=dest / "src" if stage == "design" else model,
            check=True,
            timeout=deadline - time.monotonic(),
        )
    return model / "design_smt2.smt2", expected_goals


def run_cover(sby: Path, task: str, timeout: int, work: Path) -> None:
    """Search the registered cover, then replay its inputs within the same budget."""
    deadline = time.monotonic() + timeout
    driven = work / "driven"
    subprocess.run(
        ["sby", "-f", "-d", str(driven), str(sby), task],
        cwd=sby.parent,
        check=True,
        timeout=deadline - time.monotonic(),
    )
    replay_witnesses(driven, work, deadline)


def cover_goals(metadata: str) -> set[str]:
    """Extract the smtbmc cover identifiers (named labels or source spans) from SMT2 metadata."""
    return set(re.findall(r"^; yosys-smt2-cover \d+ (?:\S+ )?(\S+)$", metadata, re.M))


def replay_witnesses(driven: Path, work: Path, deadline: float) -> None:
    """Replay the guided run's traces using only the undriven primary inputs."""
    witnesses = witness_traces(driven / "engine_0")
    model, expected_goals = undriven_model(driven, work / "undriven", deadline)
    metadata = model.read_text()
    goals = cover_goals(metadata)
    inputs = set(re.findall(r"^; yosys-smt2-input (\S+) \d+$", metadata, re.M))
    if len(goals) != expected_goals or witnesses.keys() != goals:
        raise ValueError(f"Expected a witness for each undriven home cover: {goals}")

    for goal, (step, trace) in witnesses.items():
        constraints = work / "inputs.smtc"
        constraints.write_text(primary_inputs(trace, inputs, step))
        # The start frame skips earlier cover queries. Initial conditions,
        # transitions and assumptions still apply throughout the trace.
        replay = subprocess.run(
            [
                "yosys-smtbmc",
                "-s",
                "boolector",
                "--presat",
                "--unroll",
                "-c",
                "--noprogress",
                "-t",
                f"{step}:{step + 1}",
                "--smtc",
                str(constraints),
                str(model),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=deadline - time.monotonic(),
        )
        reached = {(int(n), span) for n, span in REACHED.findall(replay.stdout)}
        missed = set(UNREACHED.findall(replay.stdout))
        # Other grant cases can be unreachable for this particular input trace.
        status = "FAILED" if missed else "PASSED"
        if (
            (step, goal) not in reached
            or not missed <= goals
            or {span for _, span in reached} != goals - missed
            or replay.returncode != int(bool(missed))
            or not replay.stdout.rstrip().endswith(f"Status: {status}")
        ):
            raise ValueError(
                f"Input replay missed {goal} at frame {step}\n{replay.stdout}"
            )
        print(
            f"Replayed {goal} at frame {step} with {len(inputs)} primary inputs",
            flush=True,
        )


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="coh_home_cmo_") as temp:
        if sys.argv[1] == "--replay-verified":
            replay_witnesses(
                Path(sys.argv[2]), Path(temp), time.monotonic() + float(sys.argv[3])
            )
        else:
            run_cover(
                Path(sys.argv[1]).resolve(), sys.argv[2], int(sys.argv[3]), Path(temp)
            )
