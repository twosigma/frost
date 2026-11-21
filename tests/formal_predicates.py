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

"""Identify formal predicates and their enclosing SystemVerilog source."""

import json
import subprocess
import tempfile
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import sby_config


@dataclass(frozen=True)
class PredicateExemption:
    """An exact [files] source, named scope and tokenized expression for listed tasks."""

    source: str
    scope: str
    expression: str
    tasks: tuple[tuple[str, str], ...]


def _child(node: dict, *tags: str) -> dict:
    for tag in tags:
        node = next((c for c in node.get("children", ()) if c and c["tag"] == tag), {})
    return node


def _leaves(node: dict) -> Iterator[dict]:
    if "start" in node:
        yield node
    for child in node.get("children", ()):
        if child:
            yield from _leaves(child)


def _scope_identifier(node: dict) -> str:
    tag = node["tag"]
    if tag == "kModuleDeclaration":
        name = _child(node, "kModuleHeader", "SymbolIdentifier")
    elif tag in ("kSeqBlock", "kGenerateBlock"):
        name = _child(node, "kBegin", "kLabel", "SymbolIdentifier")
    elif tag == "kAssertionItem":
        name = _child(node, "kBlockIdentifier", "kUnqualifiedId", "SymbolIdentifier")
    elif tag == "kLabeledStatement" and _child(node, "kAssertionStatement"):
        name = _child(node, "kUnqualifiedId", "SymbolIdentifier")
    elif tag == "kPropertyDeclaration":
        name = _child(node, "SymbolIdentifier")
    else:
        return ""
    return name.get("text", "")


def _verible(source: str, path: Path, output_option: str) -> dict:
    with tempfile.TemporaryFile() as output:
        try:
            result = subprocess.run(
                ["verible-verilog-syntax", "--export_json", output_option, "-"],
                input=source.encode("ascii"),
                stdout=output,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise sby_config.ConfigError(
                f"{path}: cannot parse predicate source: {error}"
            ) from error
        if result.returncode:
            raise sby_config.ConfigError(f"{path}: cannot parse predicate source")
        output.seek(0)
        return dict(json.load(output)["-"])


def harness_tokens(path: Path) -> list[str]:
    """Keep both preprocessor branches, predicates, guards and synthesis directives."""
    source = sby_config.read_checked_text(path)
    tokens = []
    for token in _verible(source, path, "--printrawtokens")["rawtokens"]:
        tag = token["tag"]
        value = source[token["start"] : token["end"]]
        if tag in ("TK_SPACE", "TK_NEWLINE"):
            continue
        if "COMMENT" in tag and not any(
            word in value.lower()
            for word in ("synthesis", "synopsys", "pragma", "translate_")
        ):
            continue
        tokens.append(value)
    return tokens


def predicate_spans(path: Path, staged_name: str) -> dict[tuple[str, str], list[str]]:
    """Map full named scopes and complete expressions to native frontend source spans."""
    source = sby_config.read_checked_text(path)
    tree = _verible(source, path, "--printtree").get("tree")

    spans: dict[tuple[str, str], list[str]] = {}

    def visit(node: dict[str, Any], scope: tuple[str, ...]) -> None:
        name = _scope_identifier(node)
        tag = node["tag"]
        if tag == "kModuleDeclaration":
            scope = (name,) if name else ()
        elif name and scope:
            scope = (*scope, name)
        if tag in (
            "kAssertionStatement",
            "kAssertPropertyStatement",
            "kAssumePropertyStatement",
        ):
            # A pass/fail action is not the condition being checked.
            prefix = tag.removesuffix("Statement")
            header = _child(node, prefix + "Clause", prefix + "Header")
            if header:
                visit(header, scope)
            return
        if tag in ("kExpression", "kPropertySpec"):
            if len(scope) < 2:
                return
            # Keep the outer condition (including negation, guards and property
            # clocks). Each lexical call in it must identify just one source site.
            leaves = list(_leaves(node))
            calls = [
                t
                for t in leaves
                if t["tag"] == "SystemTFIdentifier" and t.get("text") == "$isunknown"
            ]
            if calls and not any(source[t["start"]] == "`" for t in leaves):
                # A macro operand's value is not identified by its unexpanded text.
                tokens = [source[t["start"] : t["end"]] for t in leaves]
                if tokens[-1] == ";":
                    tokens.pop()
                key = (".".join(scope), " ".join(tokens))
                for call in calls:
                    start = call["start"]
                    line = 1 + source.count("\n", 0, start)
                    col = start - source.rfind("\n", 0, start)
                    spans.setdefault(key, []).append(
                        f"{staged_name}:{line}.{col}-{line}.{col + len('$isunknown')}"
                    )
            return
        for child in node.get("children", ()):
            if child:
                visit(child, scope)

    if tree:
        visit(tree, ())
    return spans


def resolve_predicate_sites(
    directory: Path, entries: tuple[PredicateExemption, ...], *, staged: bool = False
) -> tuple[str, ...]:
    """Resolve every key exactly once in the checkout or the files given to the compiler."""
    sources: dict[str, dict[tuple[str, str], list[str]]] = {}
    sites = []
    for entry in entries:
        if entry.source not in sources:
            name = Path(entry.source).name
            path = directory / (name if staged else entry.source)
            sources[entry.source] = predicate_spans(path, name)
        matches = sources[entry.source].get((entry.scope, entry.expression), [])
        if len(matches) != 1:
            raise sby_config.ConfigError(
                f"expected one $isunknown predicate in {entry.source} at {entry.scope} "
                f"with expression {entry.expression!r}, found {len(matches)}"
            )
        sites.append(matches[0])
    if len(set(sites)) != len(sites):
        raise sby_config.ConfigError("duplicate high-impedance predicate exemption")
    return tuple(sites)
