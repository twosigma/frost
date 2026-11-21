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

"""Reuse formal and synthesis results whose inputs are unchanged.

CI skips a formal task, or a Yosys synthesis target, when a pass marker
exists for the same key. A key is a SHA-256 over the inputs a change normally
touches: the files the check reads, the runner and pass-check code it goes
through, its timeout, the pytest configuration, the wrapper, the tool image's
identity, a schema version and a salt. A marker is written only after the
check passes in the same job with the same key.

The key is not a proof that every input is covered. What it misses is bounded
instead. Runs on main are counted, and a run on main reuses only markers
written in its own block of FULL_RUN_PERIOD counts of the same count
lifetime, at or before its own count. The first run of each block reuses
nothing, and a check it did not finish stays due in the next runs: a stale
pass is reported by at most nine consecutive main runs.
In every run one check in CANARY_PERIOD is proved again, and a forced run
proves everything.

The module uses only the standard library: CI runs it on the runner host,
before the image is downloaded, and in the image. tests/README.md describes
the CI side.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import tomllib
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import sby_config

# Bump SCHEMA when the meaning of a key or a marker changes. Bump SALT to make
# every key new, for example after a change to an input the key leaves out.
SCHEMA = 5
SALT = "2026-11-14"

# One in CANARY_PERIOD reusable checks is proved again in each run.
CANARY_PERIOD = 20
# A run on main reuses only markers written by a main run of its own block of
# FULL_RUN_PERIOD counts.
FULL_RUN_PERIOD = 10

ROOT = Path(__file__).resolve().parents[1]

# Module-level names of the runner modules whose values enter the keys
# directly (a task's registry entry and timeout, or the Yosys script), so that
# a new registry entry leaves the other keys alone.
FORMAL_BY_VALUE = frozenset(
    {
        "FORMAL_DIR",
        "FORMAL_TARGETS",
        "SBY_TASKS",
        "SBY_TASK_TIMEOUT_S",
        "SBY_TASK_TIMEOUT_OVERRIDES_S",
    }
)
SYNTHESIS_BY_VALUE = frozenset(
    {
        "DESIGN_FILELISTS",
        "GENERIC_SYNTH_COMMAND",
        "SYNTHESIS_TARGETS",
        "XILINX_PARTITIONS",
    }
)

# The wrapper that CI runs every check through.
WRAPPERS = ("scripts/frost.py",)
# Parser, configuration dump and elaborated-model checks used by formal runs.
FORMAL_HELPERS = (
    "tests/sby_config.py",
    "tests/sby_dump.sby",
    "tests/formal_model.cc",
    "tests/formal_predicates.py",
)
# Files pytest reads for its configuration and hooks when it runs tests/*.py,
# besides pyproject.toml; each enters keys as present or absent.
PYTEST_CONFIGURATION = tuple(
    f"{directory}{name}"
    for directory in ("", "tests/")
    for name in ("pytest.ini", ".pytest.ini", "tox.ini", "setup.cfg", "conftest.py")
)


class ReuseKeyError(Exception):
    """A key cannot be computed."""


def digest(data: bytes) -> str:
    """Return the SHA-256 hex digest of data."""
    return hashlib.sha256(data).hexdigest()


def canonical_digest(value: Any) -> str:
    """Return the SHA-256 of value's canonical JSON form."""
    return digest(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())


class FileCache:
    """Content digests and text of files, read once per process."""

    def __init__(self) -> None:
        """Start empty."""
        self._digests: dict[Path, str | None] = {}

    def digest(self, path: Path) -> str | None:
        """Return the file's content digest, or None if there is no file."""
        path = path.resolve()
        if path not in self._digests:
            self._digests[path] = digest(path.read_bytes()) if path.is_file() else None
        return self._digests[path]


def relative(path: Path, root: Path) -> str:
    """Return path relative to root, refusing paths outside it."""
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError as error:
        raise ReuseKeyError(f"{path} is outside {root}") from error


def harness_digests(root: Path, cache: FileCache) -> dict[str, str | None]:
    """Digest the pytest configuration and the wrapper every check runs under."""
    settings: Any = None
    pyproject = root / "pyproject.toml"
    if pyproject.is_file():
        try:
            settings = tomllib.loads(pyproject.read_text()).get("tool", {})
        except tomllib.TOMLDecodeError as error:
            raise ReuseKeyError(f"pyproject.toml does not parse: {error}") from error
        settings = settings.get("pytest")
    digests: dict[str, str | None] = {
        "pyproject.toml[tool.pytest]": canonical_digest(settings)
    }
    for name in (*PYTEST_CONFIGURATION, *WRAPPERS):
        digests[name] = cache.digest(root / name)
    return digests


class ModuleSource:
    """Top-level definitions of a Python module, read without importing it."""

    def __init__(self, path: Path) -> None:
        """Parse the module."""
        self.path = path
        self.lines = path.read_text().splitlines()
        self.body = ast.parse("\n".join(self.lines), filename=str(path)).body

    @staticmethod
    def names(node: ast.stmt) -> set[str]:
        """Return the names a top-level statement defines."""
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)):
            return {node.name}
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            return {
                n.id for t in targets for n in ast.walk(t) if isinstance(n, ast.Name)
            }
        return set()

    def runner_digest(self, by_value: frozenset[str]) -> str:
        """Digest the module's source except its test functions and by_value.

        Top-level functions named test_* are separate tests, which no check
        goes through; the by_value assignments enter the keys by value.
        """
        kept = []
        for node in self.body:
            names = self.names(node)
            if names & by_value or (
                isinstance(node, ast.FunctionDef) and node.name.startswith("test_")
            ):
                continue
            first = min(
                [node.lineno] + [d.lineno for d in getattr(node, "decorator_list", [])]
            )
            kept.append("\n".join(self.lines[first - 1 : node.end_lineno]))
        return digest("\n".join(kept).encode())

    def literal(self, name: str, constructors: dict[str, Any] | None = None) -> Any:
        """Return the value assigned to a top-level name.

        The value is evaluated with a few builtins and the given constructors
        and nothing else from the module.
        """
        nodes = [n for n in self.body if name in self.names(n)]
        node = nodes[-1] if nodes else None
        if not isinstance(node, (ast.Assign, ast.AnnAssign)) or node.value is None:
            raise ReuseKeyError(f"{self.path.name}: {name} is not an assignment")
        builtins = {
            f.__name__: f
            for f in (range, tuple, list, dict, str, int, len, zip, sorted)
        }
        namespace = {"__builtins__": builtins, **(constructors or {})}
        try:
            code = compile(ast.Expression(node.value), str(self.path), "eval")
            return eval(code, namespace)  # noqa: S307
        except Exception as error:
            raise ReuseKeyError(f"{self.path.name}: {name} is not a literal") from error


@dataclass(frozen=True)
class FormalTask:
    """A registered SymbiYosys task."""

    target: str
    sby_file: str
    task: str

    @property
    def test_id(self) -> str:
        """Pytest parameter id of the task."""
        return f"{self.target}_{self.task}"


class FormalRegistry:
    """The formal registry in tests/test_run_formal.py, read without importing it."""

    def __init__(self, root: Path) -> None:
        """Read the registry and the runner's source."""
        module = ModuleSource(root / "tests/test_run_formal.py")
        self.runner = module.runner_digest(FORMAL_BY_VALUE)
        self.formal_dir = module.literal("FORMAL_DIR")
        self.default_timeout = module.literal("SBY_TASK_TIMEOUT_S")
        self.timeout_overrides = module.literal("SBY_TASK_TIMEOUT_OVERRIDES_S")
        registered = {name for name, _ in module.literal("SBY_TASKS")}

        def target_entry(
            sby_file: str, description: str, tasks: tuple[str, ...] = ("bmc", "cover")
        ) -> tuple[str, tuple[str, ...]]:
            """Mirror FormalTarget's fields."""
            return sby_file, tuple(tasks)

        targets = module.literal("FORMAL_TARGETS", {"FormalTarget": target_entry})
        self.tasks: dict[str, FormalTask] = {}
        for sby_file, tasks in targets:
            for task in tasks:
                if task in registered:
                    entry = FormalTask(Path(sby_file).stem, sby_file, task)
                    self.tasks[entry.test_id] = entry

    def timeout(self, task: FormalTask) -> int:
        """Return the task's wall-clock backstop, as formal_task_timeout_s does."""
        return int(
            self.timeout_overrides.get((task.target, task.task), self.default_timeout)
        )


def formal_task_key(
    root: Path,
    test_id: str,
    tools_id: str,
    registry: FormalRegistry | None = None,
    cache: FileCache | None = None,
) -> str:
    """Return the reuse key of a formal task.

    The key holds the .sby text (with its [files] lines in sorted order, as
    SymbiYosys copies the files by name) and the path and content of every
    [files] entry. An entry must be one path to a regular file inside the
    repository. A task that replays its witnesses also keys its Python runner.
    """
    if not tools_id:
        raise ReuseKeyError("no tool image identity given")
    registry = registry or FormalRegistry(root)
    cache = cache or FileCache()
    task = registry.tasks.get(test_id)
    if task is None:
        raise ReuseKeyError(f"{test_id} is not a registered formal task")
    formal_dir = root / registry.formal_dir
    sby_path = formal_dir / task.sby_file
    name = task.sby_file
    runner = registry.runner
    if replay := sby_config.cmo_replay_helper(sby_path, task.task):
        replay_name = relative(replay, root)
        replay_digest = cache.digest(replay)
        if replay_digest is None:
            raise ReuseKeyError(f"missing formal replay helper: {replay_name}")
        runner = canonical_digest(
            {"main": runner, "replay": {replay_name: replay_digest}}
        )
    try:
        sections = dict(sby_config.source(sby_path).sections)
    except sby_config.ConfigError as error:
        raise ReuseKeyError(str(error)) from error
    entries = [
        line.strip()
        for line in sections.get("files", [])
        if line.strip() and not line.strip().startswith("#")
    ]
    if not entries:
        raise ReuseKeyError(f"{name}: no [files] entries")
    files = []
    for entry in entries:
        path = formal_dir / entry
        if len(entry.split()) != 1 or entry.startswith("/") or not path.is_file():
            raise ReuseKeyError(f"{name}: [files] entry '{entry}' is not one file")
        files.append(
            {"entry": entry, "path": relative(path, root), "sha256": cache.digest(path)}
        )
    sections["files"] = sorted(entries)
    helpers: dict[str, str] = {}
    for helper in FORMAL_HELPERS:
        helper_digest = cache.digest(root / helper)
        if helper_digest is None:
            raise ReuseKeyError(f"missing formal helper: {helper}")
        helpers[helper] = helper_digest

    return canonical_digest(
        {
            "schema": SCHEMA,
            "salt": SALT,
            "kind": "formal",
            "tools": tools_id,
            "test": test_id,
            "task": task.task,
            "formal_dir": registry.formal_dir,
            "sby": {"path": relative(sby_path, root), "sections": sections},
            "files": sorted(files, key=lambda f: (f["path"], f["entry"])),
            "timeout": registry.timeout(task),
            "runner": runner,
            "helpers": helpers,
            "harness": harness_digests(root, cache),
        }
    )


def synthesis_key(
    root: Path,
    test_id: str,
    script: str,
    cwd: Path,
    temp_dir: Path,
    timeout: int,
    tools_id: str,
) -> str:
    """Return the reuse key of a Yosys run of script from cwd.

    The key holds the script, the content of every file a read_verilog line
    names, and every file other than Python and Markdown in cwd, in each
    source's directory and in each -I directory, where Yosys resolves
    includes and $readmemh names. A path outside the repository and the
    temporary directory is an error.
    """
    if not tools_id:
        raise ReuseKeyError("no tool image identity given")
    cache = FileCache()
    module = ModuleSource(root / "tests/test_run_yosys.py")
    places = ((temp_dir.resolve(), "<tmp>"), (root.resolve(), "<root>"))

    def label(path: Path) -> str:
        # Resolve the directory but keep the name, so that a symlink is keyed
        # under its own name as well as its target's.
        absolute = Path(os.path.abspath(path))
        resolved = absolute.parent.resolve() / absolute.name
        for base, name in places:
            if resolved.is_relative_to(base):
                return f"{name}/{resolved.relative_to(base).as_posix()}"
        raise ReuseKeyError(f"synthesis reads {path}, outside the checkout")

    reads: dict[str, str | None] = {}
    directories = {cwd.resolve()}
    for line in script.splitlines():
        tokens = line.split()
        if not tokens or tokens[0] != "read_verilog":
            continue
        for token in tokens[1:]:
            if token.startswith("-I"):
                directories.add(Path(token[2:]).resolve())
                label(Path(token[2:]))
            elif not token.startswith(("-", "+/")):
                path = Path(token)
                if not path.is_file():
                    raise ReuseKeyError(f"synthesis source {token} does not exist")
                reads[label(path)] = cache.digest(path)
                directories.add(path.resolve().parent)
    neighbours = {}
    for directory in sorted(directories):
        for neighbour in sorted(directory.iterdir()):
            if neighbour.is_file() and neighbour.suffix not in (".py", ".md"):
                neighbours[label(neighbour)] = cache.digest(neighbour)

    normalized = script
    for base, name in places:
        normalized = normalized.replace(str(base), name)
    return canonical_digest(
        {
            "schema": SCHEMA,
            "salt": SALT,
            "kind": "synthesis",
            "tools": tools_id,
            "test": test_id,
            "script": normalized,
            "reads": reads,
            "neighbours": neighbours,
            "timeout": timeout,
            "runner": module.runner_digest(SYNTHESIS_BY_VALUE),
            "harness": harness_digests(root, cache),
        }
    )


def canary(test_id: str, seed: str) -> bool:
    """Return whether this run proves a reusable check again.

    Over CANARY_PERIOD consecutive seeds every check is chosen once.
    """
    if not seed:
        return False
    try:
        number = int(seed)
    except ValueError:
        number = int(digest(seed.encode())[:8], 16)
    bucket = int(digest(test_id.encode())[:8], 16) % CANARY_PERIOD
    return bucket == number % CANARY_PERIOD


def main_run() -> tuple[int, str] | None:
    """Return this run's count of main runs and the count's lifetime.

    FROST_REUSE_MAIN_RUN, set only on runs on main, counts those runs, and
    FROST_REUSE_MAIN_LIFETIME names the run that started the count, which
    changes whenever a lost count starts again. Outside main, return None.
    """
    count = os.environ.get("FROST_REUSE_MAIN_RUN", "")
    if not count:
        return None
    if not count.isdigit():
        raise ReuseKeyError(f"the main run count '{count}' is not a number")
    return int(count), os.environ.get("FROST_REUSE_MAIN_LIFETIME", "")


def reusable_on_main(marker: dict[str, Any], now: tuple[int, str]) -> bool:
    """Return whether a main run may reuse a marker.

    Only a marker of the same count lifetime, written in the same block of
    FULL_RUN_PERIOD counts and not after the current count.
    """
    written = marker.get("main_run")
    count, lifetime = now
    return (
        isinstance(written, int)
        and bool(lifetime)
        and marker.get("lifetime") == lifetime
        and written <= count
        and written // FULL_RUN_PERIOD == count // FULL_RUN_PERIOD
    )


def full_run_reason() -> str:
    """Return why this run proves every check again, or an empty string."""
    if os.environ.get("FROST_REUSE_FORCE", "") in ("1", "true"):
        return "a full run is forced"
    count = os.environ.get("FROST_REUSE_MAIN_RUN", "")
    if count.isdigit() and int(count) % FULL_RUN_PERIOD == 0:
        return (
            f"main run {count} starts a new block of {FULL_RUN_PERIOD} runs, so "
            "no earlier marker is reused"
        )
    return ""


def environment_origin() -> dict[str, str]:
    """Describe the run that proves a check, from FROST_REUSE_* variables."""
    origin = {
        "run_url": os.environ.get("FROST_REUSE_RUN_URL", ""),
        "commit": os.environ.get("FROST_REUSE_COMMIT", ""),
        "ref": os.environ.get("FROST_REUSE_REF", ""),
    }
    return {k: v for k, v in origin.items() if v} or {"run_url": "local run"}


class MarkerStore:
    """Pass markers of one kind of check, one JSON file per check."""

    def __init__(
        self, directory: Path, kind: str, main: tuple[int, str] | None = None
    ) -> None:
        """Use directory/kind for the markers, written with this main run count."""
        self.directory = directory / kind
        self.kind = kind
        self.main = main

    def path(self, test_id: str) -> Path:
        """Return the marker path of a check."""
        safe = re.sub(r"[^A-Za-z0-9_.-]", "_", test_id)[:120]
        return self.directory / f"{safe}-{digest(test_id.encode())[:10]}.json"

    def valid(self, test_id: str, key: str) -> dict[str, Any] | None:
        """Return the marker if it records a pass of this check with this key."""
        try:
            marker = json.loads(self.path(test_id).read_text())
        except (OSError, ValueError):
            return None
        expected = {"schema": SCHEMA, "kind": self.kind, "test": test_id, "key": key}
        if not isinstance(marker, dict) or not isinstance(marker.get("origin"), dict):
            return None
        if any(marker.get(field) != value for field, value in expected.items()):
            return None
        return marker

    def record_pass(self, test_id: str, key: str, origin: dict[str, str]) -> None:
        """Write a pass marker; call only after the check passed with this key."""
        self.directory.mkdir(parents=True, exist_ok=True)
        marker = {
            "schema": SCHEMA,
            "kind": self.kind,
            "test": test_id,
            "key": key,
            "origin": origin,
            "main_run": self.main[0] if self.main else None,
            "lifetime": self.main[1] if self.main else None,
            "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        path = self.path(test_id)
        temporary = path.with_suffix(f".tmp{os.getpid()}")
        temporary.write_text(json.dumps(marker, indent=1, sort_keys=True) + "\n")
        os.replace(temporary, path)

    def drop(self, test_id: str) -> None:
        """Remove a check's marker."""
        self.path(test_id).unlink(missing_ok=True)


@dataclass
class Decision:
    """What a check does in this run."""

    action: str  # "prove", "reuse" or "canary"
    marker: dict[str, Any] | None = None


class Reuse:
    """Reuse settings of a CI job, from FROST_REUSE_* environment variables."""

    def __init__(self, root: Path, kind: str) -> None:
        """Read the settings; FROST_REUSE_DIR must be set."""
        directory = Path(os.environ["FROST_REUSE_DIR"])
        self.kind = kind
        self.store = MarkerStore(root / directory, kind, main_run())
        self.tools_id = os.environ.get("FROST_REUSE_TOOLS_ID", "")
        # A forced run, and the first run of each block, reuse nothing.
        self.forced = bool(full_run_reason())
        self.seed = os.environ.get("FROST_REUSE_CANARY_SEED", "")
        report = os.environ.get("FROST_REUSE_REPORT", "")
        self.report_path = (root / report) if report else None
        host_keys = os.environ.get("FROST_REUSE_HOST_KEYS", "")
        self.host_keys: dict[str, str] = {}
        if host_keys and (root / host_keys).is_file():
            self.host_keys = json.loads((root / host_keys).read_text())

    @classmethod
    def from_env(cls, root: Path, kind: str) -> Reuse | None:
        """Return the job's settings, or None when reuse is off."""
        if not os.environ.get("FROST_REUSE_DIR"):
            return None
        return cls(root, kind)

    def decide(self, test_id: str, key: str) -> Decision:
        """Return whether to prove the check, reuse it or prove it as a canary."""
        host = self.host_keys.get(test_id)
        if host is not None and host != key:
            raise ReuseKeyError(
                f"{test_id}: the runner host and the image computed different keys"
            )
        marker = self.store.valid(test_id, key)
        # On main, a marker of an earlier block is proved again.
        main = self.store.main
        if (
            marker is None
            or self.forced
            or (main is not None and not reusable_on_main(marker, main))
        ):
            return Decision("prove", marker)
        if canary(test_id, self.seed):
            return Decision("canary", marker)
        return Decision("reuse", marker)

    def report(self, test_id: str, status: str, key: str, marker: Any = None) -> None:
        """Append a line to the job's reuse report."""
        if self.report_path is None:
            return
        entry = {
            "kind": self.kind,
            "test": test_id,
            "status": status,
            "key": key,
            "origin": (marker or {}).get("origin", {}),
        }
        self.report_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.report_path, "a") as stream:
            stream.write(json.dumps(entry, sort_keys=True) + "\n")


def describe_origin(origin: dict[str, str]) -> str:
    """Return a short Markdown description of the run that proved a check."""
    url = origin.get("run_url", "")
    text = f"[run]({url})" if url.startswith("http") else (url or "unknown run")
    if origin.get("commit"):
        text += f" at {origin['commit'][:10]}"
    if origin.get("ref"):
        text += f" on {origin['ref']}"
    return text


def image_identity(config: dict[str, Any]) -> str:
    """Return the identity of an image from its configuration."""
    layers = config.get("rootfs", {}).get("diff_ids") or []
    environment = (config.get("config") or {}).get("Env") or []
    if not layers:
        raise ReuseKeyError("image configuration has no layers")
    return "image-" + canonical_digest({"layers": layers, "env": environment})


def archive_identity(path: Path) -> str:
    """Return the identity of the image in a docker-archive tar."""
    with tarfile.open(path) as archive:
        manifest_member = archive.extractfile("manifest.json")
        assert manifest_member is not None
        manifest = json.load(manifest_member)
        if len(manifest) != 1:
            raise ReuseKeyError("archive holds more than one image")
        config_member = archive.extractfile(manifest[0]["Config"])
        assert config_member is not None
        return image_identity(json.load(config_member))


def docker_identity(image: str) -> str:
    """Return the identity of a loaded Docker image."""
    template = (
        '{"rootfs":{"diff_ids":{{json .RootFS.Layers}}},'
        '"config":{"Env":{{json .Config.Env}}}}'
    )
    output = subprocess.run(
        ["docker", "image", "inspect", image, "--format", template],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return image_identity(json.loads(output))


# ---------------------------------------------------------------------------
# CI commands
# ---------------------------------------------------------------------------

FORMAL_NODE = re.compile(
    r"^tests/test_run_formal\.py::TestFormalVerification::test_formal\[(.+)\]$"
)
RECORD_NAME = "formal-selection.json"
# A CI job runs with an empty FROST_REUSE_DIR when the gate could not keep
# the main-run count; it then neither reads nor writes markers.
REUSE_OFF = (
    "Reuse is off: the main-run count was not restored or saved, so every check "
    "is proved and no marker is read or written."
)


def selection_universe(root: Path, tools_id: str, expression: str) -> str:
    """Digest everything that decides which tests a formal job selects.

    That is the job's -k expression, the test modules and pytest settings,
    the workflow and the image. Any change makes the job collect again.
    """
    cache = FileCache()
    names = [relative(path, root) for path in sorted((root / "tests").glob("*.py"))]
    names += ["pyproject.toml", ".github/workflows/ci.yml"]
    names += [*PYTEST_CONFIGURATION, *WRAPPERS, *FORMAL_HELPERS]
    return canonical_digest(
        {
            "schema": SCHEMA,
            "salt": SALT,
            "tools": tools_id,
            "expression": expression,
            "files": {name: cache.digest(root / name) for name in names},
        }
    )


def parse_collection(text: str) -> list[str]:
    """Return the node ids of `pytest --collect-only -q` output, checked."""
    nodes = [line.strip() for line in text.splitlines() if "::" in line]
    # Only a clean summary: an error or a warning in it refuses the record.
    match = re.search(
        r"^(\d+)(?:/\d+)? tests? collected(?: \(\d+ deselected\))? in [\d.]+s$",
        text,
        re.M,
    )
    if match is None or int(match.group(1)) != len(nodes) or not nodes:
        raise ValueError("collection output does not match its own count")
    return nodes


def write_output(name: str, value: str) -> None:
    """Set a GitHub Actions step output, and print it."""
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as stream:
            stream.write(f"{name}={value}\n")
    print(f"{name}={value}")


def command_formal_record(arguments: argparse.Namespace) -> int:
    """Record which tests a formal job selected, for the next run's plan."""
    if not arguments.dir:
        print(REUSE_OFF)
        return 0
    directory = Path(arguments.dir)
    try:
        if arguments.collect_status != 0:
            raise ValueError(f"collection exited with {arguments.collect_status}")
        nodes = parse_collection(Path(arguments.collected).read_text())
    except (OSError, ValueError) as error:
        print(f"No selection record: {error}")
        (directory / RECORD_NAME).unlink(missing_ok=True)
        return 0
    universe = selection_universe(
        Path(arguments.root), arguments.tools_id, arguments.expression
    )
    directory.mkdir(parents=True, exist_ok=True)
    record = {"schema": SCHEMA, "universe": universe, "nodes": nodes}
    (directory / RECORD_NAME).write_text(json.dumps(record, indent=1) + "\n")
    print(f"Recorded {len(nodes)} selected tests")
    return 0


def plan_reason(
    root: Path, reuse: Reuse, expression: str, record: Any
) -> tuple[str, dict[str, str], list[tuple[str, str, Decision]]]:
    """Return why a formal job needs the image, its keys and its decisions."""
    keys: dict[str, str] = {}
    decisions: list[tuple[str, str, Decision]] = []
    if reuse.forced:
        return full_run_reason(), keys, decisions
    if not reuse.tools_id:
        return "no tool image identity", keys, decisions
    if not isinstance(record, dict) or record.get("schema") != SCHEMA:
        return "no selection record", keys, decisions
    if record.get("universe") != selection_universe(root, reuse.tools_id, expression):
        return "the selection inputs changed", keys, decisions
    try:
        registry = FormalRegistry(root)
    except ReuseKeyError as error:
        return str(error), keys, decisions
    cache = FileCache()
    reason = ""
    for node in record["nodes"]:
        match = FORMAL_NODE.match(node)
        if match is None or match.group(1) not in registry.tasks:
            return f"{node} always runs", keys, decisions
        test_id = match.group(1)
        try:
            key = formal_task_key(root, test_id, reuse.tools_id, registry, cache)
        except ReuseKeyError as error:
            return f"{test_id}: {error}", keys, decisions
        keys[test_id] = key
        decision = reuse.decide(test_id, key)
        decisions.append((test_id, key, decision))
        if decision.action != "reuse" and not reason:
            reason = f"{test_id} is proved in this run"
    return reason, keys, decisions


def command_formal_plan(arguments: argparse.Namespace) -> int:
    """Decide on the runner host whether a formal job needs the image.

    The job needs no image only when a selection record for the same
    universe shows that every selected test is a formal task with a valid
    marker, none is a canary and the run is not a full run.
    """
    if not arguments.dir:
        print(f"The image is needed. {REUSE_OFF}")
        write_output("need_image", "true")
        return 0
    root = Path(arguments.root)
    directory = Path(arguments.dir)
    os.environ["FROST_REUSE_DIR"] = str(directory.resolve())
    os.environ.pop("FROST_REUSE_HOST_KEYS", None)
    reuse = Reuse(root, "formal")
    reuse.report_path = Path(arguments.report) if arguments.report else None
    try:
        record = json.loads((directory / RECORD_NAME).read_text())
    except (OSError, ValueError):
        record = None
    reason, keys, decisions = plan_reason(root, reuse, arguments.expression, record)
    if arguments.host_keys:
        Path(arguments.host_keys).write_text(json.dumps(keys, indent=1) + "\n")
    if reason:
        print(f"The image is needed: {reason}")
        write_output("need_image", "true")
        return 0
    for test_id, key, decision in decisions:
        reuse.report(test_id, "reused", key, decision.marker)
    print(f"Every selected task ({len(decisions)}) passed before with the same key")
    write_output("need_image", "false")
    return 0


SUMMARY_LABELS = {
    "proved": "proved in this run",
    "canary": "proved again as a canary",
    "reused": "reused",
    "failed": "failed",
    "canary-failed": "FAILED although it had a pass marker",
    "proved-without-marker": "passed without a final PASS summary, no marker",
}


def command_summary(arguments: argparse.Namespace) -> int:
    """Print a job's reuse report as Markdown."""
    path = Path(arguments.report)
    entries = []
    if path.is_file():
        entries = [json.loads(line) for line in path.read_text().splitlines() if line]
    lines = [f"### {arguments.title}", ""]
    full_run = full_run_reason()
    if not os.environ.get("FROST_REUSE_DIR"):
        lines += [REUSE_OFF, ""]
    elif full_run:
        lines += [f"Every check is proved again: {full_run}.", ""]
    if not entries:
        print("\n".join(lines + ["No reuse report.", ""]))
        return 0
    counts: dict[str, int] = {}
    for entry in entries:
        counts[entry["status"]] = counts.get(entry["status"], 0) + 1
    lines += [
        ", ".join(
            f"{SUMMARY_LABELS.get(k, k)}: {v}" for k, v in sorted(counts.items())
        ),
        "",
        "| Check | Result | Passed with the same key in |",
        "|---|---|---|",
    ]
    for entry in sorted(entries, key=lambda e: e["test"]):
        origin = describe_origin(entry["origin"]) if entry["status"] == "reused" else ""
        status = SUMMARY_LABELS.get(entry["status"], entry["status"])
        lines.append(f"| `{entry['test']}` | {status} | {origin} |")
    print("\n".join(lines) + "\n")
    return 0


def command_image_id(arguments: argparse.Namespace) -> int:
    """Print the tool image identity."""
    if arguments.archive:
        print(archive_identity(Path(arguments.archive)))
    else:
        print(docker_identity(arguments.image))
    return 0


def main(argv: Iterable[str] | None = None) -> int:
    """Run a CI helper command."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    image = commands.add_parser("image-id", help="print the tool image identity")
    source = image.add_mutually_exclusive_group(required=True)
    source.add_argument("--archive", help="docker-archive tar of the image")
    source.add_argument("--image", help="name of a loaded image")
    image.set_defaults(handler=command_image_id)

    plan = commands.add_parser(
        "formal-plan", help="decide whether a job needs the image"
    )
    plan.add_argument("--dir", required=True, help="marker directory, empty for off")
    plan.add_argument("--expression", required=True, help="the job's -k expression")
    plan.add_argument("--report", help="reuse report to append to")
    plan.add_argument("--host-keys", help="write the computed keys here")
    plan.add_argument("--root", default=str(ROOT), help=argparse.SUPPRESS)
    plan.set_defaults(handler=command_formal_plan)

    record = commands.add_parser("formal-record", help="record a job's selection")
    record.add_argument("--dir", required=True)
    record.add_argument("--expression", required=True)
    record.add_argument("--tools-id", required=True)
    record.add_argument("--collected", required=True)
    record.add_argument("--collect-status", type=int, required=True)
    record.add_argument("--root", default=str(ROOT), help=argparse.SUPPRESS)
    record.set_defaults(handler=command_formal_record)

    summary = commands.add_parser("summary", help="print a reuse report as Markdown")
    summary.add_argument("--report", required=True)
    summary.add_argument("--title", required=True)
    summary.set_defaults(handler=command_summary)

    arguments = parser.parse_args(None if argv is None else list(argv))
    return int(arguments.handler(arguments))


if __name__ == "__main__":
    sys.exit(main())
