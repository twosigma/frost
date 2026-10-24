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

"""Select control toggle declarations from Verilator's elaborated JSON tree.

coverage_toggle.json selects scalar control ports, scalar control registers,
and enum state registers. Verilator applies its total-bit width limit before
this selection. The generated control file disables other declarations by
source line. Lines shared with selected declarations or executable coverage
are included, so line coverage and explicit cover statements are unaffected.
"""

import argparse
from collections.abc import Iterator
from fnmatch import fnmatchcase
import json
from pathlib import Path
from typing import Any

CONFIG = Path(__file__).with_suffix(".json")
# Disabling a procedure or assignment's source line can suppress the cover
# counters inside a multiline initializer, even on other source lines.
EXECUTABLE_NODES = {
    "ALWAYS",
    "INITIAL",
    "INITIALSTATIC",
    "INITIALAUTOMATIC",
    "FINAL",
    "ASSIGN",
    "ASSIGNW",
    "ASSIGNDLY",
}


def nodes(tree: Any) -> Iterator[dict[str, Any]]:
    """Yield JSON tree nodes, ignoring pointer references and scalar properties."""
    if isinstance(tree, dict):
        yield tree
        for value in tree.values():
            if isinstance(value, (dict, list)):
                yield from nodes(value)
    elif isinstance(tree, list):
        for value in tree:
            yield from nodes(value)


def source_line(node: dict[str, Any], files: dict[str, Any]) -> tuple[str, int]:
    """Resolve a Verilator location to its input filename and first source line."""
    file_id, position, _ = node["loc"].split(",")
    return files[file_id]["filename"], int(position.split(":")[0])


def protected_lines(tree: Any, files: dict[str, Any]) -> set[tuple[str, int]]:
    """Find counter locations and the procedures and assignments containing them."""
    protected: set[tuple[str, int]] = set()

    def visit(value: Any) -> bool:
        if isinstance(value, list):
            children = [visit(child) for child in value]
            return any(children)
        if not isinstance(value, dict):
            return False
        children = [
            visit(child) for child in value.values() if isinstance(child, (dict, list))
        ]
        has_counter = value.get("type") == "COVERINC" or any(children)
        if value.get("type") == "COVEROTHERDECL" or (
            value.get("type") in EXECUTABLE_NODES and has_counter
        ):
            protected.add(source_line(value, files))
        return has_counter

    visit(tree)
    return protected


def signal_kind(variable: dict[str, Any], types: dict[str, Any]) -> str:
    """Classify a declaration as an enum, a scalar bit/logic value, or other data."""
    dtype = types[variable["dtypep"]]
    while dtype["type"] == "REFDTYPE":
        dtype = types[dtype["refDTypep"]]
    if dtype["type"] == "ENUMDTYPE":
        return "enum"
    bounds = dtype.get("range", "0:0").split(":")
    if (
        dtype["type"] == "BASICDTYPE"
        and dtype.get("keyword") in ("bit", "logic")
        and len(bounds) == 2
        and bounds[0] == bounds[1]
    ):
        return "scalar"
    return "other"


def exclusions(
    tree: dict[str, Any], metadata: dict[str, Any], config: dict[str, Any]
) -> set[tuple[str, int]]:
    """Return declaration lines that can be disabled without excluding selected points."""
    files = metadata["files"]
    variables = []
    types = {}
    sequential: set[str] = set()
    toggle_lines = set()
    for node in nodes(tree):
        kind = node.get("type", "")
        if kind == "VAR" and node.get("varType") != "MODULETEMP":
            variables.append(node)
        elif kind.endswith("DTYPE"):
            types[node["addr"]] = node
        elif kind == "ASSIGNDLY":
            sequential.update(
                ref["varp"]
                for ref in nodes(node["lhsp"])
                if ref.get("type") == "VARREF" and ref.get("access") in ("WR", "RW")
            )
        elif kind == "COVERTOGGLEDECL":
            toggle_lines.add(source_line(node, files))

    selected = set()
    for variable in variables:
        location = source_line(variable, files)
        if location not in toggle_lines:
            continue
        name = variable.get("origName", variable["name"])
        if any(fnmatchcase(name, pattern) for pattern in config["exclude_names"]):
            continue
        if any(
            fnmatchcase(location[0], pattern) for pattern in config["exclude_files"]
        ):
            continue
        kind = signal_kind(variable, types)
        control = any(fnmatchcase(name, pattern) for pattern in config["control_names"])
        port = variable.get("direction", "NONE") != "NONE"
        register = variable["addr"] in sequential
        if (register and kind == "enum") or (
            kind == "scalar" and control and (port or register)
        ):
            selected.add(location)
    return toggle_lines - selected - protected_lines(tree, files)


def write_control(
    tree_path: Path,
    metadata_path: Path,
    output: Path,
    config: dict[str, Any],
    dependencies: Path | None = None,
) -> None:
    """Write a Verilator control file and optional make dependencies for its inputs."""
    tree = json.loads(tree_path.read_text(encoding="utf-8"))
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    disabled = exclusions(tree, metadata, config)
    text = "`verilator_config\n" + "".join(
        f"coverage_off -file {json.dumps(file)} -lines {line}\n"
        for file, line in sorted(disabled)
    )
    if dependencies is not None:
        _, separator, prerequisites = dependencies.read_text(
            encoding="utf-8"
        ).partition(" : ")
        if not separator:
            raise ValueError(f"Missing dependency rule in {dependencies}")
        target = str(output).replace("$", "$$").replace("#", "\\#").replace(" ", "\\ ")
        output.with_suffix(output.suffix + ".d").write_text(
            f"{target} : {prerequisites}", encoding="utf-8"
        )
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(output)


def main() -> None:
    """Print the configured width or generate declaration exclusions for a build."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--config", type=Path, default=CONFIG)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("width", help="print the total-bit width limit")
    generate = commands.add_parser("generate", help="write declaration exclusions")
    generate.add_argument("tree", type=Path)
    generate.add_argument("metadata", type=Path)
    generate.add_argument("output", type=Path)
    generate.add_argument("--dependencies", type=Path)
    arguments = parser.parse_args()
    config = json.loads(arguments.config.read_text(encoding="utf-8"))
    if arguments.command == "width":
        print(config["max_width"])
    else:
        write_control(
            arguments.tree,
            arguments.metadata,
            arguments.output,
            config,
            arguments.dependencies,
        )


if __name__ == "__main__":
    main()
