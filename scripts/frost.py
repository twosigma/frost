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

"""Run FROST's reproducible development workflows in the pinned Docker image.

The container runs as the invoking user's UID and GID.  Files created in the
bind-mounted checkout therefore remain writable by native tools such as Vivado.
Its host-owned cache keeps pre-commit hook environments across container runs.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
from collections import Counter
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

DEFAULT_IMAGE = "frost"
FAST_TEST_MARKERS = "not cocotb and not synthesis and not formal and not slow"
IMAGE_INPUT_FILES = ("Dockerfile", "docker_entrypoint.py")
DOCTOR_TIMEOUT_SECONDS = 30
IMAGE_REFERENCE_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/:@+-]*$")
FORWARDED_ENV_PREFIXES = ("COCOTB_", "FROST_")
FORWARDED_ENV_NAMES = {
    "CACHED_HAS_L2",
    "DDR_MODEL_BYTES",
    "DDR_MODEL_LATENCY",
    "ENABLE_CACHED_TIER",
    "FPGA_CPU_CLK_FREQ",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "PYTEST_ADDOPTS",
    "SIM_FAST_MAINT",
    "SIM_MEM_SIZE_BYTES",
    "WAVES",
    "http_proxy",
    "https_proxy",
    "no_proxy",
}

COCOTB_COMMAND = (
    "bash",
    "-c",
    'cd tests && make clean && exec ./test_run_cocotb.py "$@"',
    "frost-cocotb",
)
PYTEST_COMMAND = (
    "bash",
    "-c",
    'cd tests && make clean && exec pytest test_run_cocotb.py "$@"',
    "frost-pytest",
)

CHECK_STEPS = (
    ("Lint", ("pre-commit", "run", "--all-files")),
    (
        "Fast Python Tests",
        ("pytest", "tests", "-m", FAST_TEST_MARKERS, "-v"),
    ),
)

TOOL_VERSION_ARGUMENTS = {
    "verilator": "VERILATOR_VERSION",
    "yosys": "YOSYS_VERSION",
    "sby": "SBY_VERSION",
    "z3": "Z3_VERSION",
    "boolector": "BOOLECTOR_VERSION",
    "riscv_gcc": "XPACK_RISCV_VERSION",
    "clang_tidy": "CLANG_TIDY_VERSION",
    "verible": "VERIBLE_VERSION",
    "cocotb": "COCOTB_VERSION",
    "pytest": "PYTEST_VERSION",
    "pytest_cov": "PYTEST_COV_VERSION",
    "pre_commit": "PRE_COMMIT_VERSION",
    "click": "CLICK_VERSION",
}
PACKAGE_VERSION_TOOLS = {"cocotb", "pytest", "pytest_cov", "pre_commit", "click"}

IMAGE_PROBE_SCRIPT = r"""
import hashlib
import importlib.metadata
import json
import os
import platform
import stat
import subprocess


def command_output(command):
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"error": str(error)}
    output = (result.stdout or result.stderr).strip()
    if result.returncode != 0:
        return {"error": output or f"exit {result.returncode}"}
    return {"version": output}


tools = {
    "verilator": command_output(["verilator", "--version"]),
    "yosys": command_output(["yosys", "-V"]),
    "sby": command_output(["sby", "--version"]),
    "z3": command_output(["z3", "--version"]),
    "boolector": command_output(["boolector", "--version"]),
    "riscv_gcc": command_output(["riscv-none-elf-gcc", "--version"]),
    "clang_tidy": command_output(["clang-tidy", "--version"]),
    "verible": command_output(["verible-verilog-lint", "--version"]),
}
try:
    import cocotb
except (ImportError, OSError) as error:
    tools["cocotb"] = {"error": str(error)}
else:
    tools["cocotb"] = {"version": cocotb.__version__}
for key, distribution in {
    "pytest": "pytest",
    "pytest_cov": "pytest-cov",
    "pre_commit": "pre-commit",
    "click": "click",
}.items():
    try:
        tools[key] = {"version": importlib.metadata.version(distribution)}
    except importlib.metadata.PackageNotFoundError as error:
        tools[key] = {"error": str(error)}

fingerprints = {}
for filename in ("Dockerfile", "docker_entrypoint.py"):
    path = os.path.join("/usr/local/share/frost-image-inputs", filename)
    try:
        with open(path, "rb") as source:
            fingerprints[filename] = hashlib.sha256(source.read()).hexdigest()
    except OSError:
        fingerprints[filename] = None

entrypoint = "/usr/local/bin/docker_entrypoint.py"
try:
    entrypoint_mode = stat.S_IMODE(os.stat(entrypoint).st_mode)
except OSError:
    entrypoint_mode = None

print(json.dumps({
    "architecture": platform.machine(),
    "python": platform.python_version(),
    "tools": tools,
    "fingerprints": fingerprints,
    "entrypoint_mode": entrypoint_mode,
}))
"""


@dataclass(frozen=True)
class CommandOutcome:
    """Captured result from a diagnostic host command."""

    returncode: int
    stdout: str = ""
    stderr: str = ""


@dataclass(frozen=True)
class Diagnostic:
    """One user-facing doctor result."""

    status: str
    name: str
    detail: str


@dataclass(frozen=True)
class CheckStepResult:
    """Result and elapsed time for one aggregate fast check."""

    name: str
    status: str
    duration: float
    returncode: int | None


@dataclass(frozen=True)
class OwnershipScan:
    """Bounded report of root-owned paths outside excluded trees."""

    count: int
    samples: tuple[str, ...]
    errors: tuple[str, ...]


def workflow_command(workflow: str, arguments: Sequence[str]) -> list[str]:
    """Return the in-container command for a named workflow."""
    args = list(arguments)
    if workflow == "cocotb":
        return [*COCOTB_COMMAND, *args]
    if workflow == "pytest":
        return [*PYTEST_COMMAND, *args]
    if workflow == "formal":
        return ["python3", "tests/test_run_formal.py", *args]
    if workflow == "synthesis":
        return ["python3", "tests/test_run_yosys.py", *args]
    if workflow == "lint":
        return ["pre-commit", "run", *(args or ["--all-files"])]
    if workflow == "shell":
        return ["bash", *args]
    if workflow == "run":
        if not args:
            raise ValueError("the run workflow requires a command")
        return args
    raise ValueError(f"unknown workflow: {workflow}")


def forwarded_environment_names(environment: Mapping[str, str]) -> list[str]:
    """Return safe development-variable names to inherit in the container."""
    return sorted(
        name
        for name in environment
        if name in FORWARDED_ENV_NAMES
        or any(name.startswith(prefix) for prefix in FORWARDED_ENV_PREFIXES)
    )


def validate_image_reference(image: str) -> None:
    """Reject values that Docker could mistake for host-side options."""
    if not IMAGE_REFERENCE_PATTERN.fullmatch(image):
        raise ValueError(f"invalid Docker image reference: {image!r}")


def default_cache_directory(environment: Mapping[str, str]) -> Path:
    """Return the private, host-owned cache used by container workflows."""
    if xdg_cache_home := environment.get("XDG_CACHE_HOME"):
        cache_root = Path(xdg_cache_home).expanduser()
    else:
        home = environment.get("HOME")
        cache_root = (Path(home).expanduser() if home else Path.home()) / ".cache"
    return (cache_root / "frost" / "container").absolute()


def prepare_cache_directory(cache_directory: Path, uid: int) -> None:
    """Create or validate the private cache before mounting it into Docker."""
    try:
        metadata = cache_directory.lstat()
    except FileNotFoundError:
        cache_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        metadata = cache_directory.lstat()

    if stat.S_ISLNK(metadata.st_mode):
        raise OSError("path is a symbolic link")
    if not stat.S_ISDIR(metadata.st_mode):
        raise OSError("path is not a directory")
    if metadata.st_uid != uid:
        raise OSError(f"owned by UID {metadata.st_uid}, expected UID {uid}")

    mode = stat.S_IMODE(metadata.st_mode)
    if mode != 0o700:
        cache_directory.chmod(0o700)


def _normalize_returncode(returncode: int) -> int:
    """Translate a subprocess signal result to the conventional shell status."""
    return 128 - returncode if returncode < 0 else returncode


def run_streaming_command(command: Sequence[str]) -> int:
    """Run a command with live output and return a shell-compatible status."""
    try:
        result = subprocess.run(command, check=False)
    except FileNotFoundError:
        print("Error: Docker is not installed or is not on PATH", file=sys.stderr)
        return 127
    except KeyboardInterrupt:
        return 130
    return _normalize_returncode(result.returncode)


def run_captured_command(
    command: Sequence[str], *, timeout: int = DOCTOR_TIMEOUT_SECONDS
) -> CommandOutcome:
    """Run a bounded diagnostic command without streaming its output."""
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError as error:
        return CommandOutcome(127, stderr=str(error))
    except subprocess.TimeoutExpired:
        if list(command[:2]) == ["docker", "run"] and "--name" in command:
            name_index = command.index("--name") + 1
            if name_index < len(command):
                try:
                    subprocess.run(
                        ["docker", "rm", "--force", command[name_index]],
                        check=False,
                        capture_output=True,
                        timeout=5,
                    )
                except (OSError, subprocess.TimeoutExpired):
                    pass
        return CommandOutcome(124, stderr=f"timed out after {timeout}s")
    except OSError as error:
        return CommandOutcome(1, stderr=str(error))
    return CommandOutcome(
        _normalize_returncode(result.returncode),
        result.stdout.strip(),
        result.stderr.strip(),
    )


def build_docker_command(
    container_command: Sequence[str],
    *,
    repository_root: Path,
    image: str,
    uid: int,
    gid: int,
    environment: Mapping[str, str],
    cache_directory: Path | None = None,
    interactive: bool = False,
    environment_overrides: Mapping[str, str] | None = None,
    suppressed_environment_names: frozenset[str] = frozenset(),
) -> list[str]:
    """Build the host-side Docker invocation for a workflow command."""
    validate_image_reference(image)
    overrides = environment_overrides or {}
    command = [
        "docker",
        "run",
        "--rm",
        "--init",
        "--pull=never",
        "--user",
        f"{uid}:{gid}",
        "--env",
        f"HOME=/tmp/frost-home-{uid}",
    ]
    for name in forwarded_environment_names(environment):
        if name in suppressed_environment_names or name in overrides:
            continue
        command.extend(("--env", name))
    for name, value in sorted(overrides.items()):
        command.extend(("--env", f"{name}={value}"))
    if cache_directory is not None:
        command.extend(
            (
                "--volume",
                f"{cache_directory}:/tmp/frost-home-{uid}/.cache",
            )
        )
    if interactive:
        command.append("--interactive")
        if sys.stdout.isatty():
            command.append("--tty")
    command.extend(
        (
            "--volume",
            f"{repository_root}:/workspace",
            "--workdir",
            "/workspace",
            image,
            *container_command,
        )
    )
    return command


def build_image_probe_command(image: str, uid: int, gid: int) -> list[str]:
    """Build a sandboxed, checkout-free command that inventories an image."""
    validate_image_reference(image)
    return [
        "docker",
        "run",
        "--rm",
        "--pull=never",
        "--name",
        f"frost-doctor-{uid}-{os.getpid()}",
        "--network",
        "none",
        "--read-only",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        "--pids-limit",
        "128",
        "--cpus",
        "1",
        "--memory",
        "512m",
        "--user",
        f"{uid}:{gid}",
        "--env",
        f"HOME=/tmp/frost-doctor-{uid}",
        "--entrypoint",
        "python3",
        image,
        "-c",
        IMAGE_PROBE_SCRIPT,
    ]


def dockerfile_version_pins(dockerfile: Path) -> dict[str, str]:
    """Read version-valued build arguments from the repository Dockerfile."""
    pattern = re.compile(r"^ARG\s+([A-Z0-9_]+_VERSION)=([^\s#]+)")
    pins: dict[str, str] = {}
    for line in dockerfile.read_text(encoding="utf-8").splitlines():
        if match := pattern.match(line):
            pins[match.group(1)] = match.group(2)
    return pins


def sha256_file(path: Path) -> str:
    """Return a stable digest for one image build input."""
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def image_fingerprint_problems(
    repository_root: Path, probe: Mapping[str, object]
) -> list[str]:
    """Return build inputs missing from or stale in the inspected image."""
    fingerprints = probe.get("fingerprints")
    if not isinstance(fingerprints, Mapping):
        return ["image did not report embedded build-input fingerprints"]

    problems: list[str] = []
    for filename in IMAGE_INPUT_FILES:
        actual = fingerprints.get(filename)
        if not isinstance(actual, str):
            problems.append(f"image does not embed {filename}")
            continue
        expected = sha256_file(repository_root / filename)
        if actual != expected:
            problems.append(f"embedded {filename} differs from the checkout")
    return problems


def _expected_tool_version(tool: str, configured: str) -> str:
    """Normalize packaging suffixes that are absent from command output."""
    if tool == "riscv_gcc":
        return configured.rsplit("-", maxsplit=1)[0]
    return configured


def tool_version_problems(
    probe: Mapping[str, object], pins: Mapping[str, str]
) -> list[str]:
    """Return missing tools and versions that disagree with Dockerfile pins."""
    tools = probe.get("tools")
    if not isinstance(tools, Mapping):
        return ["image did not report its tool versions"]

    problems: list[str] = []
    for tool, argument in TOOL_VERSION_ARGUMENTS.items():
        configured = pins.get(argument)
        if configured is None:
            problems.append(f"Dockerfile is missing {argument}")
            continue
        report = tools.get(tool)
        if not isinstance(report, Mapping):
            problems.append(f"{tool} was not reported")
            continue
        if error := report.get("error"):
            problems.append(f"{tool} is unavailable ({error})")
            continue
        version = report.get("version")
        expected = _expected_tool_version(tool, configured)
        if tool in PACKAGE_VERSION_TOOLS:
            matches = version == expected
        else:
            matches = (
                isinstance(version, str)
                and re.search(rf"(?<![0-9.]){re.escape(expected)}(?![0-9.])", version)
                is not None
            )
        if not matches:
            problems.append(
                f"{tool} expected {expected}, got {version or 'no version'}"
            )
    return problems


def image_runtime_problems(probe: Mapping[str, object]) -> list[str]:
    """Return incompatibilities that prevent supported non-root workflows."""
    problems: list[str] = []
    architecture = probe.get("architecture")
    if architecture not in {"x86_64", "amd64"}:
        problems.append(
            f"unsupported image architecture {architecture!r}; expected x86_64"
        )

    python_version = probe.get("python")
    if not isinstance(python_version, str) or not python_version.startswith("3.12."):
        problems.append(f"expected Python 3.12, got {python_version or 'no version'}")

    entrypoint_mode = probe.get("entrypoint_mode")
    if entrypoint_mode != 0o755:
        rendered_mode = (
            oct(entrypoint_mode) if isinstance(entrypoint_mode, int) else "missing"
        )
        problems.append(f"entrypoint mode is {rendered_mode}, expected 0o755")
    return problems


def _concise_command_error(outcome: CommandOutcome) -> str:
    """Choose one bounded, useful line from a failed diagnostic command."""
    output = outcome.stderr or outcome.stdout or f"exit {outcome.returncode}"
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    return (lines[-1] if lines else f"exit {outcome.returncode}")[:300]


def submodule_diagnostic(
    repository_root: Path,
    command_runner: Callable[[Sequence[str]], CommandOutcome],
) -> Diagnostic:
    """Inspect recursive submodule state without initializing anything."""
    if not (repository_root / ".gitmodules").exists():
        return Diagnostic("PASS", "Submodules", "repository has no submodules")

    outcome = command_runner(
        ["git", "-C", str(repository_root), "submodule", "status", "--recursive"]
    )
    if outcome.returncode != 0:
        return Diagnostic(
            "FAIL",
            "Submodules",
            f"could not inspect status: {_concise_command_error(outcome)}",
        )

    states: dict[str, list[str]] = {"-": [], "+": [], "U": []}
    for line in outcome.stdout.splitlines():
        if not line or line[0] not in states:
            continue
        fields = line[1:].strip().split()
        path = fields[1] if len(fields) > 1 else line[1:].strip()
        states[line[0]].append(path)

    if states["-"] or states["U"]:
        details: list[str] = []
        if states["-"]:
            details.append("uninitialized: " + ", ".join(states["-"][:5]))
        if states["U"]:
            details.append("conflicted: " + ", ".join(states["U"][:5]))
        return Diagnostic("FAIL", "Submodules", "; ".join(details))
    if states["+"]:
        return Diagnostic(
            "WARN",
            "Submodules",
            "checked out at a different commit: " + ", ".join(states["+"][:5]),
        )
    count = len([line for line in outcome.stdout.splitlines() if line.strip()])
    return Diagnostic(
        "PASS", "Submodules", f"{count} recursive entries are initialized"
    )


def scan_root_owned_paths(
    repository_root: Path, uid: int, *, sample_limit: int = 8
) -> OwnershipScan:
    """Find topmost root-owned paths while pruning Git metadata and ``hw``."""
    if uid == 0:
        return OwnershipScan(0, (), ())

    count = 0
    samples: list[str] = []
    errors: list[str] = []

    def record_walk_error(error: OSError) -> None:
        location = Path(error.filename) if error.filename else repository_root
        try:
            rendered = location.relative_to(repository_root).as_posix()
        except ValueError:
            rendered = str(location)
        if len(errors) < sample_limit:
            errors.append(f"{rendered}: {error.strerror or error}")

    for current, directories, filenames in os.walk(
        repository_root,
        topdown=True,
        onerror=record_walk_error,
        followlinks=False,
    ):
        current_path = Path(current)
        if current_path == repository_root:
            directories[:] = [
                name for name in directories if name not in {".git", "hw"}
            ]

        for name in list(directories):
            path = current_path / name
            try:
                metadata = path.lstat()
            except OSError as error:
                if len(errors) < sample_limit:
                    errors.append(f"{path.relative_to(repository_root)}: {error}")
                directories.remove(name)
                continue
            if metadata.st_uid == 0:
                count += 1
                if len(samples) < sample_limit:
                    samples.append(path.relative_to(repository_root).as_posix())
                directories.remove(name)

        for name in filenames:
            path = current_path / name
            try:
                metadata = path.lstat()
            except OSError as error:
                if len(errors) < sample_limit:
                    errors.append(f"{path.relative_to(repository_root)}: {error}")
                continue
            if metadata.st_uid == 0:
                count += 1
                if len(samples) < sample_limit:
                    samples.append(path.relative_to(repository_root).as_posix())
    return OwnershipScan(count, tuple(samples), tuple(errors))


def ownership_diagnostics(repository_root: Path, uid: int) -> list[Diagnostic]:
    """Describe root-owned checkout artifacts without changing ownership."""
    if uid == 0:
        return [
            Diagnostic(
                "SKIP",
                "Repository ownership",
                "running as root cannot diagnose UID 0 artifacts",
            )
        ]

    scan = scan_root_owned_paths(repository_root, uid)
    diagnostics: list[Diagnostic] = []
    if scan.count:
        detail = f"{scan.count} root-owned path(s): " + ", ".join(scan.samples)
        if scan.count > len(scan.samples):
            detail += f" (and {scan.count - len(scan.samples)} more)"
        diagnostics.append(Diagnostic("FAIL", "Repository ownership", detail))
    else:
        diagnostics.append(
            Diagnostic(
                "PASS",
                "Repository ownership",
                "no root-owned paths found outside .git/ and hw/",
            )
        )
    if scan.errors:
        diagnostics.append(
            Diagnostic(
                "WARN",
                "Ownership scan",
                "could not inspect: " + "; ".join(scan.errors),
            )
        )
    return diagnostics


def cache_diagnostics(cache_directory: Path, uid: int) -> list[Diagnostic]:
    """Inspect the executable tooling cache without creating or repairing it."""
    try:
        metadata = cache_directory.lstat()
    except FileNotFoundError:
        ancestor = cache_directory.parent
        while not ancestor.exists() and ancestor.parent != ancestor:
            ancestor = ancestor.parent
        if not ancestor.is_dir() or not os.access(ancestor, os.W_OK | os.X_OK):
            return [
                Diagnostic(
                    "FAIL",
                    "Container cache",
                    f"nearest existing parent {ancestor} is not a writable directory",
                )
            ]
        return [
            Diagnostic(
                "PASS",
                "Container cache",
                f"{cache_directory} will be created on first use",
            )
        ]
    except OSError as error:
        return [Diagnostic("FAIL", "Container cache", str(error))]

    if stat.S_ISLNK(metadata.st_mode):
        return [Diagnostic("FAIL", "Container cache", "cache path is a symbolic link")]
    if not stat.S_ISDIR(metadata.st_mode):
        return [Diagnostic("FAIL", "Container cache", "cache path is not a directory")]
    if metadata.st_uid != uid:
        return [
            Diagnostic(
                "FAIL",
                "Container cache",
                f"owned by UID {metadata.st_uid}, expected UID {uid}",
            )
        ]

    mode = stat.S_IMODE(metadata.st_mode)
    if mode & 0o700 != 0o700:
        return [
            Diagnostic(
                "FAIL",
                "Container cache",
                f"owner permissions {oct(mode)} must include rwx",
            )
        ]

    foreign_count = 0
    foreign_samples: list[str] = []
    walk_errors: list[str] = []

    def record_walk_error(error: OSError) -> None:
        location = error.filename or str(cache_directory)
        if len(walk_errors) < 5:
            walk_errors.append(f"{location}: {error.strerror or error}")

    for current, directories, filenames in os.walk(
        cache_directory, topdown=True, onerror=record_walk_error, followlinks=False
    ):
        for name in [*directories, *filenames]:
            path = Path(current) / name
            try:
                entry = path.lstat()
            except OSError as error:
                if len(walk_errors) < 5:
                    walk_errors.append(f"{path}: {error}")
                continue
            if entry.st_uid != uid:
                foreign_count += 1
                if len(foreign_samples) < 5:
                    foreign_samples.append(path.relative_to(cache_directory).as_posix())
    if foreign_count:
        return [
            Diagnostic(
                "FAIL",
                "Container cache",
                f"{foreign_count} foreign-owned entries: " + ", ".join(foreign_samples),
            )
        ]
    if walk_errors:
        return [
            Diagnostic(
                "FAIL",
                "Container cache",
                "could not inspect cache entries: " + "; ".join(walk_errors),
            )
        ]
    if mode & 0o077:
        return [
            Diagnostic(
                "WARN",
                "Container cache",
                f"permissions {oct(mode)} are broader than the recommended 0o700",
            )
        ]
    return [
        Diagnostic(
            "PASS", "Container cache", f"{cache_directory} is private and writable"
        )
    ]


def _print_doctor_results(diagnostics: Sequence[Diagnostic]) -> int:
    """Print ordered diagnostics and return the aggregate doctor status."""
    for diagnostic in diagnostics:
        print(f"[{diagnostic.status}] {diagnostic.name}: {diagnostic.detail}")
    counts = Counter(diagnostic.status for diagnostic in diagnostics)
    print(
        "Doctor: "
        f"{counts['PASS']} passed, {counts['WARN']} warnings, "
        f"{counts['FAIL']} failed, {counts['SKIP']} skipped"
    )
    return 1 if counts["FAIL"] else 0


def run_doctor(
    *,
    repository_root: Path,
    image: str,
    uid: int,
    gid: int,
    environment: Mapping[str, str],
    command_runner: Callable[[Sequence[str]], CommandOutcome] = run_captured_command,
    docker_finder: Callable[[str], str | None] = shutil.which,
) -> int:
    """Run read-only host and image health diagnostics."""
    diagnostics: list[Diagnostic] = []
    docker_ready = False
    daemon_ready = False
    image_ready = False

    docker_path = docker_finder("docker")
    if docker_path is None:
        diagnostics.append(
            Diagnostic(
                "FAIL", "Docker CLI", "Docker is not installed or is not on PATH"
            )
        )
    else:
        outcome = command_runner(["docker", "--version"])
        if outcome.returncode == 0:
            docker_ready = True
            diagnostics.append(
                Diagnostic("PASS", "Docker CLI", outcome.stdout or docker_path)
            )
        else:
            diagnostics.append(
                Diagnostic("FAIL", "Docker CLI", _concise_command_error(outcome))
            )

    if docker_ready:
        outcome = command_runner(["docker", "info", "--format", "{{.ServerVersion}}"])
        if outcome.returncode == 0:
            daemon_ready = True
            diagnostics.append(
                Diagnostic("PASS", "Docker daemon", f"server {outcome.stdout}")
            )
        else:
            diagnostics.append(
                Diagnostic("FAIL", "Docker daemon", _concise_command_error(outcome))
            )
    else:
        diagnostics.append(
            Diagnostic("SKIP", "Docker daemon", "Docker CLI is unavailable")
        )

    if daemon_ready:
        outcome = command_runner(
            ["docker", "image", "inspect", image, "--format", "{{.Id}}"]
        )
        if outcome.returncode == 0:
            image_ready = True
            diagnostics.append(
                Diagnostic("PASS", "Docker image", f"{image} ({outcome.stdout[:24]})")
            )
        else:
            diagnostics.append(
                Diagnostic(
                    "FAIL",
                    "Docker image",
                    f"cannot inspect {image!r}: {_concise_command_error(outcome)}; "
                    f"run `docker build -t {image} .`",
                )
            )
    else:
        diagnostics.append(
            Diagnostic("SKIP", "Docker image", "Docker daemon is unavailable")
        )

    if image_ready:
        outcome = command_runner(build_image_probe_command(image, uid, gid))
        if outcome.returncode != 0:
            diagnostics.append(
                Diagnostic("FAIL", "Image probe", _concise_command_error(outcome))
            )
            diagnostics.extend(
                (
                    Diagnostic("SKIP", "Image runtime", "image probe failed"),
                    Diagnostic("SKIP", "Image freshness", "image probe failed"),
                    Diagnostic("SKIP", "Pinned tools", "image probe failed"),
                )
            )
        else:
            try:
                probe = json.loads(outcome.stdout)
            except (json.JSONDecodeError, TypeError) as error:
                diagnostics.append(
                    Diagnostic("FAIL", "Image probe", f"returned invalid JSON: {error}")
                )
                diagnostics.extend(
                    (
                        Diagnostic("SKIP", "Image runtime", "image probe was invalid"),
                        Diagnostic(
                            "SKIP", "Image freshness", "image probe was invalid"
                        ),
                        Diagnostic("SKIP", "Pinned tools", "image probe was invalid"),
                    )
                )
            else:
                if not isinstance(probe, Mapping):
                    diagnostics.append(
                        Diagnostic(
                            "FAIL", "Image probe", "returned a non-object payload"
                        )
                    )
                    diagnostics.extend(
                        (
                            Diagnostic(
                                "SKIP", "Image runtime", "image probe was invalid"
                            ),
                            Diagnostic(
                                "SKIP", "Image freshness", "image probe was invalid"
                            ),
                            Diagnostic(
                                "SKIP", "Pinned tools", "image probe was invalid"
                            ),
                        )
                    )
                else:
                    diagnostics.append(
                        Diagnostic(
                            "PASS", "Image probe", "sandboxed inventory completed"
                        )
                    )
                    runtime_problems = image_runtime_problems(probe)
                    diagnostics.append(
                        Diagnostic(
                            "FAIL" if runtime_problems else "PASS",
                            "Image runtime",
                            "; ".join(runtime_problems)
                            if runtime_problems
                            else "x86_64, Python 3.12, and non-root entrypoint mode match",
                        )
                    )
                    try:
                        fingerprint_problems = image_fingerprint_problems(
                            repository_root, probe
                        )
                    except OSError as error:
                        fingerprint_problems = [
                            f"could not hash local image inputs: {error}"
                        ]
                    diagnostics.append(
                        Diagnostic(
                            "FAIL" if fingerprint_problems else "PASS",
                            "Image freshness",
                            (
                                "; ".join(fingerprint_problems)
                                + f"; run `docker build -t {image} .`"
                                if fingerprint_problems
                                else "embedded Dockerfile and entrypoint match the checkout"
                            ),
                        )
                    )
                    try:
                        pins = dockerfile_version_pins(repository_root / "Dockerfile")
                    except OSError as error:
                        version_problems = [f"could not read Dockerfile: {error}"]
                    else:
                        version_problems = tool_version_problems(probe, pins)
                    diagnostics.append(
                        Diagnostic(
                            "FAIL" if version_problems else "PASS",
                            "Pinned tools",
                            "; ".join(version_problems)
                            if version_problems
                            else f"{len(TOOL_VERSION_ARGUMENTS)} tool versions match Dockerfile",
                        )
                    )
    else:
        diagnostics.extend(
            (
                Diagnostic("SKIP", "Image probe", "Docker image is unavailable"),
                Diagnostic("SKIP", "Image runtime", "Docker image is unavailable"),
                Diagnostic("SKIP", "Image freshness", "Docker image is unavailable"),
                Diagnostic("SKIP", "Pinned tools", "Docker image is unavailable"),
            )
        )

    diagnostics.append(submodule_diagnostic(repository_root, command_runner))
    diagnostics.extend(ownership_diagnostics(repository_root, uid))
    diagnostics.extend(cache_diagnostics(default_cache_directory(environment), uid))
    return _print_doctor_results(diagnostics)


def _print_check_summary(results: Sequence[CheckStepResult]) -> None:
    """Print a compact status and timing summary for aggregate fast checks."""
    print("\nFast-check summary:")
    for result in results:
        if result.returncode is None:
            suffix = ""
        elif result.returncode:
            suffix = f" (exit {result.returncode})"
        else:
            suffix = ""
        print(f"  {result.status:4}  {result.duration:7.2f}s  {result.name}{suffix}")


def run_fast_checks(
    *,
    repository_root: Path,
    image: str,
    uid: int,
    gid: int,
    environment: Mapping[str, str],
    cache_directory: Path,
    fail_fast: bool,
    command_runner: Callable[[Sequence[str]], int] = run_streaming_command,
    clock: Callable[[], float] = time.monotonic,
) -> int:
    """Run CI's lint and fast-Python lanes with aggregate reporting."""
    print("Running CI's Lint and Fast Python jobs.")
    print("Note: lint hooks may update files; review the worktree if lint fails.")
    results: list[CheckStepResult] = []
    first_failure = 0
    stop = False

    for index, (name, container_command) in enumerate(CHECK_STEPS, start=1):
        if stop:
            results.append(CheckStepResult(name, "SKIP", 0.0, None))
            continue
        print(f"\n[{index}/{len(CHECK_STEPS)}] {name}", flush=True)
        docker_command = build_docker_command(
            container_command,
            repository_root=repository_root,
            image=image,
            uid=uid,
            gid=gid,
            environment=environment,
            cache_directory=cache_directory,
            environment_overrides={"FROST_SKIP_SUBMODULE_INIT": "1"},
            suppressed_environment_names=frozenset({"PYTEST_ADDOPTS"}),
        )
        started = clock()
        returncode = command_runner(docker_command)
        duration = max(0.0, clock() - started)
        status = "PASS" if returncode == 0 else "FAIL"
        results.append(CheckStepResult(name, status, duration, returncode))
        print(f"[{status}] {name} ({duration:.2f}s)")
        if returncode and first_failure == 0:
            first_failure = returncode
        # Docker reserves 125-127 for infrastructure/launch failures. Ctrl-C
        # also stops immediately; ordinary lint/test failures still aggregate.
        if returncode in {125, 126, 127, 130} or (returncode and fail_fast):
            stop = True

    _print_check_summary(results)
    return first_failure


def _argument_parser() -> argparse.ArgumentParser:
    """Create the command-line parser."""
    parser = argparse.ArgumentParser(
        description=(
            "Run FROST development workflows in the pinned container without "
            "creating root-owned repository files. Tool-workflow arguments pass "
            "through unchanged; doctor and check parse their documented options."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  %(prog)s doctor
  %(prog)s check
  %(prog)s cocotb hello_world
  FROST_COCOTB_MEM_CONFIG=ddr %(prog)s cocotb hello_world
  %(prog)s pytest -m 'cocotb and cocotb_unit' -v
  %(prog)s formal --target trap_unit
  %(prog)s synthesis --target generic
  %(prog)s lint
  %(prog)s run python3 sw/apps/build_all_apps.py --list
""",
    )
    parser.add_argument(
        "--image",
        default=os.environ.get("FROST_DOCKER_IMAGE", DEFAULT_IMAGE),
        help=(
            "local Docker image to use (default: %(default)s; override with "
            "FROST_DOCKER_IMAGE)"
        ),
    )
    parser.add_argument(
        "workflow",
        choices=(
            "doctor",
            "check",
            "cocotb",
            "pytest",
            "formal",
            "synthesis",
            "lint",
            "shell",
            "run",
        ),
        help="health/check workflow, tool shortcut, or 'run' for an arbitrary command",
    )
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    return parser


def _doctor_argument_parser() -> argparse.ArgumentParser:
    """Create the parser for the read-only doctor command."""
    return argparse.ArgumentParser(
        prog=f"{Path(sys.argv[0]).name} doctor",
        description="Diagnose the local checkout and pinned image without changing them.",
    )


def _check_argument_parser() -> argparse.ArgumentParser:
    """Create the parser for CI's aggregate fast checks."""
    parser = argparse.ArgumentParser(
        prog=f"{Path(sys.argv[0]).name} check",
        description="Run CI's Lint and Fast Python jobs in the pinned image.",
    )
    parser.add_argument(
        "--fail-fast",
        action="store_true",
        help="stop after the first failed lane instead of reporting both",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Run the selected workflow and return its exit status."""
    args = _argument_parser().parse_args(argv)
    try:
        validate_image_reference(args.image)
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2

    repository_root = Path(__file__).resolve().parents[1]
    uid = os.getuid()
    gid = os.getgid()

    if args.workflow == "doctor":
        _doctor_argument_parser().parse_args(args.arguments)
        return run_doctor(
            repository_root=repository_root,
            image=args.image,
            uid=uid,
            gid=gid,
            environment=os.environ,
        )

    check_arguments = None
    if args.workflow == "check":
        check_arguments = _check_argument_parser().parse_args(args.arguments)

    cache_directory = default_cache_directory(os.environ)
    try:
        prepare_cache_directory(cache_directory, uid)
    except OSError as error:
        print(
            f"Error: unsafe or unusable container cache {cache_directory}: {error}",
            file=sys.stderr,
        )
        return 1

    if check_arguments is not None:
        return run_fast_checks(
            repository_root=repository_root,
            image=args.image,
            uid=uid,
            gid=gid,
            environment=os.environ,
            cache_directory=cache_directory,
            fail_fast=check_arguments.fail_fast,
        )

    try:
        container_command = workflow_command(args.workflow, args.arguments)
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2

    docker_command = build_docker_command(
        container_command,
        repository_root=repository_root,
        image=args.image,
        uid=uid,
        gid=gid,
        environment=os.environ,
        cache_directory=cache_directory,
        interactive=args.workflow == "shell",
    )
    return run_streaming_command(docker_command)


if __name__ == "__main__":
    sys.exit(main())
