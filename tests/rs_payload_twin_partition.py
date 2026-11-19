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

"""Print the payload twin's guarded assertions and their compiled task partition.

Run from the repository root in the formal image with
python3 tests/rs_payload_twin_partition.py. The table goes to standard output.
"""

from __future__ import annotations

import csv
import hashlib
import re
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path
from tempfile import TemporaryDirectory

from test_run_formal import formal_task_config

FORMAL = Path(__file__).resolve().parents[1] / "formal"
TARGET = "rs_payload_twin"


def compile_groups(work: Path) -> list[str]:
    """Compile the shared model, then apply each task's resolved group commands."""
    sby = TARGET + ".sby"
    tasks = subprocess.check_output(
        ["sby", "--dumptasks", sby], cwd=FORMAL, text=True
    ).split()
    subprocess.run(
        ["sby", "--setup", "-d", str(work / "setup"), sby, tasks[0]],
        cwd=FORMAL,
        stdout=sys.stderr,
        check=True,
    )
    configs = [formal_task_config(TARGET, task) for task in tasks]
    common = configs[0]["[script]"]
    split = next(i for i, line in enumerate(common) if line.startswith("select -set "))
    prefix = common[:split]
    commands = [
        *prefix,
        "design -save complete",
        "dump -o ../../drivers.il t:$eq t:$mux",
    ]
    tails: dict[str, list[str]] = {"all": []}
    for task, config in zip(tasks, configs, strict=True):
        assert config["[files]"] == configs[0]["[files]"], task
        assert config["[script]"][:split] == prefix, task
        tails[task] = config["[script]"][split:]
    for group, tail in tails.items():
        commands.extend(
            [
                "design -load complete",
                *tail,
                f"dump -o ../../{group}.checks t:$check",
                # Hash the remaining circuit, including every assumption and initial value.
                "delete t:$check r:FLAVOR=assert %i",
                f"write_rtlil -sort ../../{group}.il",
            ]
        )
    script = work / "partition.ys"
    script.write_text("\n".join(commands) + "\n")
    subprocess.run(
        ["yosys", "-Q", "-q", "-s", str(script)], cwd=work / "setup/src", check=True
    )
    return tasks


def cells(path: Path) -> Iterator[tuple[str, str, str, dict[str, str]]]:
    """Read the selected RTLIL cells emitted by Yosys dump."""
    src = ""
    with path.open() as stream:
        for line in stream:
            fields = line.strip().split(maxsplit=2)
            if fields[:2] == ["attribute", r"\src"]:
                src = fields[2].strip('"')
            if fields[:1] != ["cell"]:
                continue
            _, kind, name = fields
            values = {}
            for item in stream:
                parts = item.strip().split(maxsplit=2)
                if parts == ["end"]:
                    break
                if parts[:1] in (["parameter"], ["connect"]):
                    values[parts[1]] = parts[2]
            yield kind, name, src, values
            src = ""


def assertions(path: Path) -> dict[str, tuple[str, str, str]]:
    """Return each compiled assertion's source, enable and predicate signals."""
    found = {}
    for kind, name, src, ports in cells(path):
        if kind == "$check" and ports[r"\FLAVOR"] == '"assert"':
            assert ports[r"\TRG"] == "{ }", (name, src)
            assert name not in found, name
            found[name] = (src, ports[r"\EN"], ports[r"\A"])
    return found


def source_statements(
    text: str, reference: dict[str, tuple[str, str, str]]
) -> dict[str, str]:
    """Use compiled source positions to recover each complete guarded statement."""
    # Preserve line and column offsets while ignoring punctuation in comments.
    text = re.sub(
        r"//[^\n]*|/\*.*?\*/",
        lambda m: re.sub(r"[^\n]", " ", m[0]),
        text,
        flags=re.DOTALL,
    )
    start = list(re.finditer(r"\balways_comb\s+begin\b", text))[-1].end()
    lines = [0, *(m.end() for m in re.finditer("\n", text))]
    statements = {}
    ends: set[int] = set()
    for name, (src, _, _) in reference.items():
        location = re.fullmatch(
            r"rs_payload_twin_formal\.sv:(\d+)\.(\d+)-\d+\.\d+", src
        )
        assert location, src
        pos = lines[int(location[1]) - 1] + int(location[2]) - 1
        assert pos >= start, src
        left = max(start, text.rfind(";", start, pos) + 1)
        right = text.index(";", pos)
        statement = " ".join(text[left:right].split())
        assert right not in ends and re.search(r"\bassert\s*\(", statement), src
        ends.add(right)
        statements[name] = statement
    assert len(ends) == text.count(";", start), "unmatched source assertion"
    return statements


def report(work: Path, tasks: list[str]) -> None:
    """Check the disjoint union and print each source comparison and its drivers."""
    reference = assertions(work / "all.checks")
    statements = source_statements(
        (work / "setup/src/rs_payload_twin_formal.sv").read_text(), reference
    )
    circuit = work / "all.il"
    with circuit.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").digest()
    wanted = {
        signal
        for _, enable, predicate in reference.values()
        for signal in (enable, predicate)
    }
    drivers = {
        ports[r"\Y"]: (kind, ports)
        for kind, _, _, ports in cells(work / "drivers.il")
        if ports[r"\Y"] in wanted
    }
    seen: set[str] = set()
    writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    writer.writerow(
        (
            "task",
            "cell",
            "source",
            "guarded assertion",
            "compiled enable",
            "compiled lhs",
            "compiled rhs",
        )
    )
    for task in tasks:
        with (work / f"{task}.il").open("rb") as stream:
            assert hashlib.file_digest(stream, "sha256").digest() == digest, (
                f"{task} changed the circuit outside its assertions"
            )
        group = assertions(work / f"{task}.checks")
        assert group and not seen.intersection(group), (
            f"empty or overlapping group: {task}"
        )
        for name, record in sorted(group.items()):
            assert record == reference[name], (task, name, record)
            src, enable, predicate = record
            assert predicate in drivers and drivers[predicate][0] == "$eq", (
                f"{task} {src} no longer compares two compiled signals"
            )
            _, equality = drivers[predicate]
            if enable in drivers:
                kind, mux = drivers[enable]
                assert (kind, mux[r"\A"], mux[r"\B"]) == ("$mux", "1'0", "1'1"), (
                    task,
                    name,
                )
                enable = mux[r"\S"]
            writer.writerow(
                (
                    task,
                    name,
                    src,
                    statements[name],
                    enable,
                    equality[r"\A"],
                    equality[r"\B"],
                )
            )
        seen.update(group)
        print(f"{task} has {len(group)} assertions", file=sys.stderr)
    assert seen == reference.keys() and len(seen) == len(statements), (
        "incomplete partition"
    )
    print(
        f"The groups cover all {len(seen)} assertions without overlap. All remaining circuit logic is identical.",
        file=sys.stderr,
    )


if __name__ == "__main__":
    with TemporaryDirectory() as directory:
        work = Path(directory)
        report(work, compile_groups(work))
