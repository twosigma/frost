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

"""Regenerate the AXI bridge assertion roster without changing known ownership.

Labels identify named assertions. Other identities use normalized assertion
source text and the ordinal of its lowered instances, ordered by source site
and numeric unroll suffix. Whitespace, comments and generated cell numbers do
not participate in the text identity. Identical statements at different sites
are distinguished by their source order; labels disambiguate such statements.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

COMMAND = "./scripts/frost.py run python3 formal/update_axi_bridge_groups.py"
ROSTER = "axi_coherent_bridge_groups.ys"
ASSIGNMENTS = "axi_coherent_bridge_groups.json"
HELD = "label:p_b_held"
TOKEN = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[\w$]+|\S', re.S)
SOURCE = re.compile(r"([^|]+):(\d+)\.(\d+)-(\d+)\.(\d+)")


def source_text(source: str, files: dict[str, str]) -> str:
    """Extract and normalize one assertion's source span from Yosys metadata."""
    match = SOURCE.fullmatch(source)
    if match is None:
        raise ValueError(f"Cannot identify assertion source span: {source}")
    filename, first, column, last, end = match.groups()
    lines = files[filename].splitlines(keepends=True)[int(first) - 1 : int(last)]
    lines[-1] = lines[-1][: int(end) - 1]
    lines[0] = lines[0][int(column) - 1 :]
    return " ".join(
        token
        for token in TOKEN.findall("".join(lines))
        if not token.startswith(("//", "/*"))
    )


def identities(cells: dict, files: dict[str, str]) -> dict[str, str]:
    """Map stable identities to the current lowered assertion cell names."""
    result = {}
    anonymous: dict[str, list[tuple[tuple[int, ...], str]]] = {}
    for name, cell in cells.items():
        if cell["type"] != "$assert":
            continue
        if not name.startswith("$"):
            result[f"label:{name}"] = name
            continue
        source = cell["attributes"]["src"]
        text = source_text(source, files)
        digest = hashlib.sha256(text.encode()).hexdigest()
        span = SOURCE.fullmatch(source)
        suffix = re.search(r"\$(\d+)$", name)
        if span is None or suffix is None:
            raise ValueError(f"Cannot order assertion instances: {name}")
        order = (*map(int, span.groups()[1:]), int(suffix[1]))
        anonymous.setdefault(digest, []).append((order, name))
    for digest, instances in sorted(anonymous.items()):
        for ordinal, (_, name) in enumerate(sorted(instances)):
            result[f"text:{digest}:{ordinal}"] = name
    if not result or len(set(result.values())) != len(result):
        raise ValueError("Assertion identities must be nonempty and unique")
    return result


def lowered_assertions(root: Path) -> dict[str, str]:
    """Use the proof's resolved script up to its frozen, unpartitioned model."""
    formal = root / "formal"
    config = subprocess.run(
        ["sby", "--dumpcfg", "axi_coherent_bridge.sby", "prove_soc8_0"],
        cwd=formal,
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    ).stdout
    sections: dict[str, list[str]] = {}
    section = ""
    for raw in config.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            section = line
            sections[section] = []
        else:
            sections[section].append(line)
    script = sections["[script]"]
    stop = script.index("write_rtlil ../model/unpartitioned.il")
    prefix = script[:stop]
    if prefix[-3:] != ["async2sync", "setundef -anyseq", "chformal -lower"]:
        raise ValueError("The proof's assertion-freezing sequence has changed")
    with tempfile.TemporaryDirectory(prefix="axi-bridge-roster-") as directory:
        work = Path(directory)
        files = {}
        for entry in sections["[files]"]:
            parts = shlex.split(entry)
            if len(parts) == 1:
                source = formal / parts[0]
                destination = source.name
            elif len(parts) == 2:
                destination, filename = parts
                source = formal / filename
            else:
                raise ValueError(f"Unsupported SBY file entry: {entry}")
            if destination == ROSTER:
                continue
            target = work / destination
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            files[destination] = target.read_text()
        prepared = subprocess.run(
            [
                "yosys",
                "-Q",
                "-T",
                "-q",
                "-p",
                "\n".join([*prefix, "write_json design.json"]),
            ],
            cwd=work,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if prepared.returncode:
            raise RuntimeError(
                f"Assertion preparation failed:\n{prepared.stdout}{prepared.stderr}"
            )
        design = json.loads((work / "design.json").read_text())
        return identities(design["modules"]["axi_coherent_bridge"]["cells"], files)


def update_assignments(previous: dict, current: dict[str, str]) -> dict:
    """Preserve known members; append others to the smallest ordinary group."""
    if previous["version"] != 1 or len(previous["groups"]) != 9:
        raise ValueError("Unsupported assertion assignment format")
    old = [key for group in previous["groups"] for key in group]
    if len(set(old)) != len(old) or previous["groups"][8] != [HELD]:
        raise ValueError("Assignments must be unique, with p_b_held alone in group 8")
    if HELD not in current:
        raise ValueError("The required p_b_held assertion is missing")
    groups = [[key for key in group if key in current] for group in previous["groups"]]
    for key in sorted(current.keys() - set(old)):
        group = min(range(8), key=lambda index: (len(groups[index]), index))
        groups[group].append(key)
    return {
        "version": 1,
        "groups": groups,
        "annotations": {
            key: value
            for key, value in sorted(previous["annotations"].items())
            if key in current
        },
    }


def render(assignments: dict, current: dict[str, str]) -> str:
    """Render exact cell selections and exhaustive ownership guards."""
    lines = [
        "# Explicit membership of every lowered assertion in the eight-burst design.",
        "# The count, disjointness and coverage checks reject stale or incomplete lists.",
        "select -set remaining t:$assert",
        "",
    ]
    for index, members in enumerate(assignments["groups"]):
        notes = [
            assignments["annotations"][key]
            for key in members
            if key in assignments["annotations"]
        ]
        suffix = f", including {', '.join(notes)}" if notes else ""
        lines.append(
            "# Partition 8 checks B-channel stability."
            if index == 8
            else f"# Partition {index}{suffix}."
        )
        cells = [f"c:{current[key]}" for key in members]
        if len(cells) == 1:
            lines.append(f"select -set group{index} {cells[0]}")
        elif not cells:
            lines.append(f"select -set group{index} t:$assert t:$assert %d")
        else:
            lines.append(f"select -set group{index} \\")
            lines.extend(
                f"  {cell}" + (" \\" if number < len(cells) - 1 else "")
                for number, cell in enumerate(cells)
            )
        lines.extend(
            [
                f"select -assert-count {len(cells)} @group{index}",
                f"select -assert-none @group{index} @remaining %d",
                f"select -set remaining @remaining @group{index} %d",
                "",
            ]
        )
    lines.extend(["select -assert-none @remaining", "select -clear", ""])
    return "\n".join(lines)


def main() -> int:
    """Check or update the roster and its persistent ownership assignments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check", action="store_true", help="Check without writing files"
    )
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[1]
    )
    args = parser.parse_args()
    try:
        formal = args.root.resolve() / "formal"
        previous = json.loads((formal / ASSIGNMENTS).read_text())
        current = lowered_assertions(args.root.resolve())
        assignments = update_assignments(previous, current)
        output = {
            ROSTER: render(assignments, current),
            ASSIGNMENTS: json.dumps(assignments, indent=2) + "\n",
        }
        if args.check:
            if any(
                not (formal / name).exists() or (formal / name).read_text() != body
                for name, body in output.items()
            ):
                print(
                    f"AXI bridge assertion roster is stale. Run: {COMMAND}",
                    file=sys.stderr,
                )
                return 1
            print(
                f"AXI bridge assertion roster is up to date ({len(current)} assertions)."
            )
        else:
            for name, body in output.items():
                (formal / name).write_text(body)
            print(f"Updated AXI bridge assertion roster ({len(current)} assertions).")
    except (
        ValueError,
        KeyError,
        OSError,
        RuntimeError,
        subprocess.SubprocessError,
    ) as error:
        print(
            f"Cannot regenerate AXI bridge assertion roster: {error}", file=sys.stderr
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
