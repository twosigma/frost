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

"""Read the repository's SBY dialect and resolve configurations with SymbiYosys."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from collections.abc import Iterable
from functools import lru_cache
from pathlib import Path

NAME = r"[A-Za-z0-9_]+"
FILENAME = r"[A-Za-z0-9_][A-Za-z0-9_.-]*"
HEADER = re.compile(rf"\[(tasks|options|engines|script|files|file {FILENAME})\]")
TAG = re.compile(rf"(~?)({NAME}):(.*)")
FILE_PATH = re.compile(r"(?:[A-Za-z0-9_.-]+/)*" + FILENAME)


class ConfigError(ValueError):
    """A script uses syntax outside the repository's proof dialect."""


@dataclass
class TaskConfig:
    """A task after selection and file mapping."""

    script: list[str]
    files: dict[str, str]
    inline: dict[str, list[str]]
    options: dict[str, str]
    engines: list[list[str]]

    def scripts(self, directory: Path) -> dict[str, str]:
        """Read the Yosys scripts from this task's source directory."""
        bodies = {
            dest: (directory / source).read_text()
            for dest, source in self.files.items()
            if dest.endswith(".ys") and (directory / source).is_file()
        }
        bodies.update({name: "\n".join(lines) for name, lines in self.inline.items()})
        return bodies

    def commands(self, directory: Path) -> list[list[str]]:
        """Return the commands this task's script runs, its included scripts too."""
        return commands(self.script, self.scripts(directory))

    def sections(self) -> dict[str, list[str]]:
        """Return the task sections used in checks of proof depths and source lists."""
        return {
            "[options]": [f"{key} {value}" for key, value in self.options.items()],
            "[engines]": [" ".join(words) for words in self.engines],
            "[script]": [
                s.strip()
                for s in self.script
                if s.strip() and not s.lstrip().startswith("#")
            ],
            "[files]": list(self.files.values()),
            **{f"[file {name}]": lines for name, lines in self.inline.items()},
        }


@dataclass
class Source:
    """Validated sections and the groups active for each named task."""

    sections: dict[str, list[str]]
    tasks: dict[str, set[str]]

    def task(self, name: str) -> TaskConfig:
        """Resolve literal task selectors for tools that run outside the image."""
        active = self.tasks[name]
        resolved: dict[str, list[str]] = {}
        for section, lines in self.sections.items():
            if section in ("", "tasks"):
                continue
            body: list[str] = []
            block = True
            for line in lines:
                if line.strip() == "--":
                    block = True
                    continue
                match = TAG.fullmatch(line)
                if match:
                    negate, tag, rest = match.groups()
                    selected = (tag in active) != bool(negate)
                    line = rest.lstrip()
                    if not line:
                        block = selected
                        continue
                    if not selected:
                        continue
                if block:
                    body.append(line)
            resolved[section] = body

        def words(section: str) -> list[list[str]]:
            return [
                line.split()
                for raw in resolved.get(section, [])
                if (line := raw.partition("#")[0].strip())
            ]

        return TaskConfig(
            [line.rstrip() for line in resolved.get("script", [])],
            {Path(source).name: source for (source,) in words("files")},
            {k[5:]: body for k, body in resolved.items() if k.startswith("file ")},
            dict(
                line.split(maxsplit=1)
                for raw in resolved.get("options", [])
                if (line := raw.partition("#")[0].strip())
            ),
            words("engines"),
        )


@lru_cache(maxsize=512)
def read_source(path: Path, text: str) -> Source:
    """Accept only complete section headers, literal tags and plain file paths."""
    sections: dict[str, list[str]] = {"": []}
    tasks: dict[str, set[str]] = {}
    tags: set[str] = set()
    destinations: set[str] = set()
    section = ""
    block = 0
    for number, line in enumerate(text.removesuffix("\n").split("\n"), 1):

        def refuse(reason: str) -> None:
            raise ConfigError(f"{path.name}:{number}: {reason}: {line!r}")

        if any(not c.isprintable() and c != "\t" for c in line):
            refuse("control character")
        header = HEADER.fullmatch(line)
        if header:
            section = header[1]
            if section in sections or block:
                refuse("repeated section or section inside a tag block")
            if section == "tasks" and len(sections) != 1:
                refuse("[tasks] must precede other sections")
            if section.startswith("file "):
                if section[5:] in destinations:
                    refuse("duplicate file destination")
                destinations.add(section[5:])
            sections[section] = []
            continue
        if line.lstrip().startswith("[") or line.lstrip().startswith("--pycode"):
            refuse("unsupported section header or directive")
        sections[section].append(line)
        if not line.strip():
            continue
        if line.startswith("#"):
            # SymbiYosys reads a first word ending in ':' as a task selector
            # once [tasks] has names, comment or not, and stops on it.
            if tags and section != "tasks" and line.split()[0].endswith(":"):
                refuse("comment read as a task selector")
            continue
        if section == "tasks":
            lhs, colon, rhs = line.partition(":")
            names = lhs.split()
            if not colon:
                names, groups = names[:1], names[1:]
            else:
                groups = rhs.split()
            if not names or any(
                not re.fullmatch(NAME, word) for word in [*names, *groups]
            ):
                refuse("expected literal task and tag names")
            for name in names:
                if name in tasks:
                    refuse("duplicate task")
                tasks[name] = {name, *set(groups).difference({"default"})}
                tags.update(tasks[name])
            continue
        if not section:
            refuse("expected a section")
        if line.strip() == "--":
            if not block:
                refuse("unmatched end of tag block")
            block = 0
            continue
        tag = TAG.fullmatch(line)
        payload = line
        if tag:
            if tag[2] not in tags or section == "files" or section.startswith("file "):
                refuse("unknown or misplaced task tag")
            payload = tag[3].lstrip()
            if not payload:
                if block:
                    refuse("nested tag block")
                block = number
                continue
        elif re.match(r"^\S+:", line):
            refuse("unsupported task selector")
        if payload.lstrip().startswith(("[", "--")):
            refuse("tagged header or directive")
        if section == "files":
            source = payload.strip()
            if not FILE_PATH.fullmatch(source):
                refuse("expected one source path")
            dest = Path(source).name
            if dest in destinations:
                refuse(f"duplicate file destination {dest}")
            destinations.add(dest)
        elif section in ("options", "engines"):
            body = re.split(r"(?:^|\s)#", payload, maxsplit=1)[0].strip()
            if body and not re.fullmatch(
                r"[A-Za-z0-9_]+(?:[ \t]+[^\s#]+)"
                + ("+" if section == "options" else "*"),
                body,
            ):
                refuse(f"unsupported [{section}] entry")
    if block:
        raise ConfigError(f"{path.name}:{block}: unterminated tag block")
    if "tasks" in sections and not tasks:
        raise ConfigError(f"{path.name}: [tasks] names no task")
    return Source(sections, tasks or {"": set()})


def source(path: Path) -> Source:
    """Read and validate a checkout configuration."""
    return read_source(path, path.read_text())


def proof_inputs(path: Path) -> list[Path]:
    """List a proof and the source paths it declares relative to its directory."""
    definition = source(path)
    # The repository's [files] section is shared by every task.
    files = definition.task(next(iter(definition.tasks))).files
    return [path, *(path.parent / name for name in files.values())]


def cmo_replay_helper(path: Path, task: str | None = None) -> Path | None:
    """Locate the Python runner needed by the CMO cover or its whole-script fixture."""
    if path.name != "coherence_home.sby":
        return None
    cover = "coh_home_cmo_cover"
    if task == cover or (task is None and cover in source(path).tasks):
        return path.parent.parent / "tests" / "coherence_home_cmo_replay.py"
    return None


def stage_proof(path: Path, root: Path, fixture: Path) -> Path:
    """Copy a proof and all its inputs into a private checkout layout.

    SymbiYosys stages every external input from [files], including sources
    read by nested Yosys scripts. Inline [file] bodies travel with the proof.
    A registered Python replay travels with the fixture in its tests directory.
    """
    root = Path(os.path.abspath(root))
    sources = proof_inputs(path)
    if replay := cmo_replay_helper(path):
        sources.append(replay)
    destinations = [
        fixture / Path(os.path.abspath(source_file)).relative_to(root)
        for source_file in sources
    ]
    for source_file, destination in zip(sources, destinations, strict=True):
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_file, destination)
    return destinations[0]


# Only configurations are cached. The checks read the mapped files on each use.
_resolved: dict[Path, tuple[str, dict[str, TaskConfig]]] = {}


def sby_outcomes(texts: dict[str, str]) -> dict[str, dict]:
    """Return SymbiYosys's verdict on each configuration text, unchecked.

    Each value is {"error": message} when SymbiYosys refuses the text, else
    {"tasks": {task: configuration fields}}.
    """
    driver = Path(__file__).with_name("sby_dump.sby")
    run = subprocess.run(
        ["sby", "--dumpcfg", str(driver)],
        input=json.dumps(texts),
        capture_output=True,
        text=True,
        timeout=90,
    )
    if run.returncode:
        raise ConfigError(f"SymbiYosys: {run.stderr.strip()}")
    outcome = json.loads(run.stdout)
    if outcome.keys() != texts.keys():
        raise ConfigError("SymbiYosys returned a different set of files")
    return outcome


def resolve_files(paths: Iterable[Path]) -> None:
    """Resolve changed configurations in one SymbiYosys process."""
    pending: dict[str, str] = {}
    for path in paths:
        text = path.read_text()
        if path not in _resolved or _resolved[path][0] != text:
            read_source(path, text)
            pending[str(path)] = text
    if not pending:
        return
    for name, outcome in sby_outcomes(pending).items():
        if "error" in outcome:
            raise ConfigError(f"SymbiYosys: {name}: {outcome['error']}")
        _resolved[Path(name)] = (
            pending[name],
            {task: TaskConfig(**entry) for task, entry in outcome["tasks"].items()},
        )


def resolved(path: Path) -> dict[str, TaskConfig]:
    """Resolve every named task, including those outside the default set."""
    resolve_files([path])
    return _resolved[path][1]


def yosys_token(text: str) -> tuple[str, str]:
    """Split off the next argument as Yosys's next_token does for commands."""
    ends = ("", " ", "\t", "\r", "\n")
    rest = text.lstrip(" \t\r\n")
    if rest.startswith('"'):
        for index in range(1, len(rest)):
            if rest[index] == '"' and rest[index + 1 : index + 2] in ends:
                return rest[: index + 1], rest[index + 1 :]
            if rest[index : index + 2] == '";' and rest[index + 2 : index + 3] in ends:
                return rest[: index + 1] + ";", rest[index + 2 :]
    match = re.match(r"[^ \t\r\n]*", rest)
    assert match is not None
    return match.group(), rest[match.end() :]


def commands(
    script: list[str], files: dict[str, str], depth: int = 0
) -> list[list[str]]:
    """Return the commands a Yosys script runs, as argument lists.

    Follows Yosys: a trailing backslash continues a line, a first word ending in
    ':' is a label, an argument starting with '#' starts a comment, an argument
    ending in ';' ends a command (';;' and ';;;' add clean and clean -purge),
    and script is replaced by the commands it runs. tee, trace and debug with
    a command come out as the wrapper with its own options, then the command it
    runs, so that a check sees a file the wrapper writes.
    """
    assert depth < 8, "script files include each other"
    lines = list(script)
    lines_commands: list[list[str]] = []
    while lines:
        line = lines.pop(0)
        while line.endswith("\\") and lines:
            line = line[:-1] + lines.pop(0)
        words = line.split()
        if (
            words
            and not words[0].startswith("#")
            and len(words[0]) > 1
            and words[0].endswith(":")
        ):
            line = line.lstrip(" \t")[len(words[0]) :]
        args: list[str] = []
        token, line = yosys_token(line)
        while token and not token.startswith("#"):
            if token.endswith(";"):
                count = len(token) - len(token.rstrip(";"))
                if token.rstrip(";"):
                    args.append(token.rstrip(";"))
                lines_commands += [
                    args,
                    {2: ["clean"], 3: ["clean", "-purge"]}.get(count, []),
                ]
                args = []
            else:
                args.append(token)
            token, line = yosys_token(line)
        lines_commands.append(args)
    result: list[list[str]] = []
    for args in lines_commands:
        while args[:1] in (["tee"], ["trace"]) or (
            args[:1] == ["debug"] and args[1:2] not in (["-on"], ["-off"])
        ):
            index = 1
            while args[0] == "tee" and index < len(args):
                if args[index] in ("-o", "-a", "-s"):
                    index += 2
                elif args[index] == "-q" or re.match(r"[-+][0-9]", args[index]):
                    index += 1
                else:
                    break
            result.append(args[:index])
            args = args[index:]
        if not args or args[0].startswith(("#", ":")):
            continue
        # A shell escape, an option this reader does not know, a script language
        # or a plugin would hide the commands that run.
        assert not args[0].startswith(("!", "-", "+")), args
        assert args[0] not in ("tcl", "exec", "python", "plugin"), args
        if args[0] == "script":
            assert len(args) in (2, 3) and args[1] in files, args
            lines = files[args[1]].splitlines()
            if len(args) == 3:
                lines = script_block(lines, args[2])
            result += commands(lines, files, depth + 1)
        else:
            result.append(args)
    return result


def script_block(lines: list[str], labels: str) -> list[str]:
    """Return the lines that `script <file> <labels>` runs, as Yosys selects them.

    One label runs the block from that label to the next one; "from:to" runs
    from the line labeled from (the start when empty) up to the line labeled to
    (the end when empty), not including it. Continued lines are joined first.
    """
    run_from, _, run_to = (
        labels.partition(":") if ":" in labels else (labels, "", labels)
    )
    active = not run_from
    joined: list[str] = []
    while lines:
        line = lines[0]
        lines = lines[1:]
        while line.endswith("\\") and lines:
            line, lines = line[:-1] + lines[0], lines[1:]
        joined.append(line)
    selected: list[str] = []
    for line in joined:
        words = line.split()
        if (
            words
            and not words[0].startswith("#")
            and len(words[0]) > 1
            and words[0].endswith(":")
        ):
            label = words[0][:-1]
            line = line.lstrip(" \t")[len(words[0]) :]
            if label == run_from:
                active = True
            elif label == run_to or (run_from == run_to and run_from):
                active = False
        if active:
            selected.append(line)
    return selected
