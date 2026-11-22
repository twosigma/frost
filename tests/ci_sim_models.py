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


"""Build and restore the executable used by a cocotb simulation."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from functools import cache
from itertools import groupby
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "tests"
STORE = ROOT / ".ci-sim-models"
DDR_PARAMETERS = ("DDR_MODEL_LATENCY", "DDR_MODEL_LATENCY_JITTER", "DDR_MODEL_REORDER")
SOURCE_SUFFIXES = (
    ".sv",
    ".v",
    ".vh",
    ".svh",
    ".vlt",
    ".f",
    ".c",
    ".cc",
    ".cpp",
    ".cxx",
    ".h",
    ".hh",
    ".hpp",
)


# tests/Makefile turns these environment variables into Verilator arguments:
# WAVES and the coverage switches for every toplevel, the rest as -G overrides
# of the frost toplevel.
MAKEFILE_BUILD_VARIABLES = (
    "WAVES",
    "FROST_COVERAGE",
    "FROST_COVERAGE_TOGGLE",
    "SIM_MEM_SIZE_BYTES",
    "FROST_CPU_PERIOD_PS",
    "ENABLE_CACHED_TIER",
    "DDR_MODEL_BYTES",
    "DDR_MODEL_LATENCY",
    "SIM_FAST_MAINT",
    "MEMORY_LINK_STAGES",
    "MISALIGNED_HW",
)


def ddr_timing_args(arguments: str) -> list[str]:
    """Move decimal overrides to plusargs. Verilator evaluates other expressions."""
    values = {}
    for arg in arguments.split():
        name, _, value = arg.removeprefix("-G").partition("=")
        if arg.startswith("-G") and name in DDR_PARAMETERS:
            values[name] = value
    return [
        f"-G{name}={value}"
        for name, value in values.items()
        if re.fullmatch(r"0|[1-9][0-9]{0,9}", value) and int(value) <= 0xFFFFFFFF
    ]


def ordered_parameters(arguments: list[str]) -> list[str]:
    """Order adjacent decimal -G settings by name, preserving repeated overrides."""

    def decimal(arg: str) -> bool:
        return re.fullmatch(r"-G[A-Za-z_]\w*=(0|[1-9]\d*)", arg) is not None

    result = []
    for numeric, items in groupby(arguments, key=decimal):
        if numeric:
            # Distinct named assignments commute. Stable sorting keeps the
            # original precedence of multiple assignments to one parameter.
            result.extend(sorted(items, key=lambda arg: arg.partition("=")[0]))
        else:
            result.extend(items)
    return result


def settings(top: str, env: dict[str, str]) -> dict[str, str]:
    """Describe the Makefile inputs for a clean build in the shared image."""
    arguments = env.get("FROST_VERILATOR_EXTRA_ARGS", "").split()
    if top == "frost":
        runtime = {arg.split("=")[0] for arg in ddr_timing_args(" ".join(arguments))}
        arguments = [arg for arg in arguments if arg.split("=")[0] not in runtime]
        # The Makefile enables assertions for this top.
        if all(
            arg.startswith(("-G", "-D", "+define+"))
            or arg.endswith((".sv", ".v", ".vlt"))
            or arg == "--assert"
            for arg in arguments
        ):
            arguments = [arg for arg in arguments if arg != "--assert"]
    config = {
        name: env[name]
        for name in MAKEFILE_BUILD_VARIABLES
        if name in env
        and (
            top == "frost"
            or name in ("WAVES", "FROST_COVERAGE", "FROST_COVERAGE_TOGGLE")
        )
    }
    for key, default in (
        ("WAVES", "0"),
        ("FROST_COVERAGE", "0"),
        ("FROST_COVERAGE_TOGGLE", "0"),
        ("SIM_FAST_MAINT", "1"),
    ):
        if config.get(key) == default:
            config.pop(key)
    if config.get("FROST_CPU_PERIOD_PS"):
        config["FROST_CPU_PERIOD_PS"] = "1"
    if (
        env.get("FROST_RANDOM_START") == "1"
        or env.get("FROST_RANDOM_START_SEED", "").strip()
    ):
        config["FROST_RANDOM_START"] = "1"
    return dict(
        config,
        TOPLEVEL=top,
        FROST_VERILATOR_EXTRA_ARGS=" ".join(ordered_parameters(arguments)),
    )


def group(config: dict[str, str]) -> str:
    """Name a model configuration in artifacts and consumer selections."""
    return hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()[:24]


def checksum(path: Path) -> str:
    """Hash a runtime file without buffering the executable."""
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


@cache
def selection(path: Path) -> dict:
    """Read the immutable selection for this job."""
    return json.loads(path.read_text())


def select_model(top: str, env: dict[str, str]) -> None:
    """Select a producer or an explicitly job-local configuration."""
    plan = selection(STORE / "selection.json")
    key = group(settings(top, env))
    if key in plan["shared"]:
        env["FROST_SIM_IMPORT"] = str(STORE / key)
    elif key not in plan["local"]:
        raise ValueError(
            f"unplanned simulator configuration {key}: {settings(top, env)}"
        )


def compile_command(args: list[str], build_args: str) -> dict:
    """Keep the actual ordered Verilator and C++ options, apart from build paths."""
    # -Mdir is scratch space. Parallel build jobs do not set simulation threads.
    command = []
    index = 0
    while index < len(args):
        arg = args[index]
        index += 1
        if arg in ("-Mdir", "-j"):
            index += 1
        elif (
            arg != "--assert"
            or arg not in command
            or any(a in args for a in ("--no-assert", "--noassert"))
        ):
            command.append(arg)
    return {
        "verilator": ordered_parameters(command),
        "build": [a for a in shlex.split(build_args) if not re.fullmatch(r"-j\d+", a)],
        "compiler": {
            key: os.environ[key]
            for key in (
                "CC",
                "CXX",
                "CFLAGS",
                "CPPFLAGS",
                "CXXFLAGS",
                "LDFLAGS",
                "OPT_FAST",
                "OPT_SLOW",
                "OPT_GLOBAL",
            )
            if key in os.environ
        },
    }


def scope() -> list[str]:
    """Bind the loaded image and workflow run to the checked-out source revision."""
    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    return [os.environ["FROST_SIM_SCOPE"], commit]


def source_digest(record: Path, command: dict) -> str:
    """Check the checkout files read by Verilator and the linked C++ sources."""
    root = ROOT.resolve()
    files = {(TESTS / "Makefile").resolve()}
    for line in record.read_text().splitlines():
        if line.startswith("S "):
            raw = Path(line.rsplit('"', 2)[1])
            files.add((raw if raw.is_absolute() else TESTS / raw).resolve())
    for arg in command["verilator"][1:]:
        if arg.startswith(("-", "+")):
            continue
        raw = Path(arg)
        if not raw.is_absolute() and raw.suffix not in SOURCE_SUFFIXES:
            continue
        path = (raw if raw.is_absolute() else TESTS / raw).resolve()
        if path.is_relative_to(root) and path.is_file():
            files.add(path)
    digest = hashlib.sha256()
    for path in sorted(files):
        if path.is_relative_to(root) and path.is_file():
            digest.update(path.relative_to(root).as_posix().encode() + b"\0")
            digest.update(bytes.fromhex(checksum(path)))
    return digest.hexdigest()


def verilate(tool: str, build_args: str, args: list[str]) -> None:
    """Run Verilator for a producer, or supply its two runtime files to make."""
    directory = Path(args[args.index("-Mdir") + 1])
    command = compile_command([tool, *args], build_args)
    if "FROST_SIM_IMPORT" not in os.environ:
        (directory / "command.json").write_text(json.dumps(command))
        os.execv(tool, [tool, *args])

    source = Path(os.environ["FROST_SIM_IMPORT"])
    manifest = json.loads((source / "manifest.json").read_text())
    if manifest["scope"] != scope() or manifest["command"] != command:
        raise ValueError(
            f"{source}: incompatible simulator scope or compiler invocation"
        )
    for name in ("Vtop", "Vtop__verFiles.dat"):
        if checksum(source / name) != manifest["files"][name]:
            raise ValueError(f"{source / name}: simulator checksum differs")
    if source_digest(source / "Vtop__verFiles.dat", command) != manifest["sources"]:
        raise ValueError(f"{source}: simulator sources differ")
    shutil.copyfile(source / "Vtop__verFiles.dat", directory / "Vtop__verFiles.dat")
    # cocotb's Verilator rule runs make -f Vtop.mk in the build directory.
    # Install the binary on that step, including its executable permission.
    (directory / "Vtop.mk").write_text(
        f"all:\n\tinstall -m 755 {shlex.quote(str(source / 'Vtop'))} Vtop\n"
    )
    print(f"Restoring simulator {source.name}", flush=True)


def build(config: dict[str, str], output: Path) -> None:
    """Export the executable, startup build record and compatibility manifest."""
    directory = TESTS / "sim_build"
    env = {
        key: value
        for key, value in os.environ.items()
        if key not in MAKEFILE_BUILD_VARIABLES
        and key
        not in (
            "FROST_RANDOM_START",
            "FROST_RANDOM_START_SEED",
            "FROST_DDR_TIMING_ARGS",
            "FROST_SIM_IMPORT",
            "FROST_VERILATOR_EXTRA_ARGS",
        )
    }
    env.update(config)
    env.update(FROST_SIM_EXPORT="1", ROOT=str(ROOT), SIM_BUILD=str(directory))
    subprocess.run(["make", "clean"], cwd=TESTS, env=env, check=True)
    subprocess.run(["make", str(directory / "Vtop")], cwd=TESTS, env=env, check=True)
    output.mkdir(parents=True, exist_ok=True)
    files = {}
    for name in ("Vtop", "Vtop__verFiles.dat"):
        shutil.copyfile(directory / name, output / name)
        files[name] = checksum(output / name)
    command = json.loads((directory / "command.json").read_text())
    manifest = {
        "scope": scope(),
        "sources": source_digest(output / "Vtop__verFiles.dat", command),
        "command": command,
        "files": files,
    }
    (output / "manifest.json").write_text(json.dumps(manifest) + "\n")


def build_bundle(models: list[dict], output: Path) -> None:
    """Build each configuration requested by this set of consumers."""
    for model in models:
        directory = output / model["key"]
        if "vlen" in model:
            binary = directory / "frost-native"
            subprocess.run(
                [
                    sys.executable,
                    str(TESTS / "test_riscv_vector_tests.py"),
                    "--rtl",
                    "--simulator",
                    "native",
                    "--sim-threads",
                    "4",
                    "--vlen",
                    str(model["vlen"]),
                    "--build-sim",
                    str(binary),
                ],
                check=True,
            )
            record = {
                "scope": scope(),
                "vlen": model["vlen"],
                "threads": 4,
                "files": {
                    name: checksum(directory / name)
                    for name in ("frost-native", "frost-native.json")
                },
            }
            (directory / "manifest.json").write_text(json.dumps(record) + "\n")
        else:
            build(model["config"], directory)


def receive(request: dict) -> None:
    """Download this job's exact bundles from the run and check their scope."""
    if (
        not isinstance(request, dict)
        or "shared" not in request
        or "local" not in request
    ):
        raise ValueError(f"missing simulator selection: {request!r}")
    STORE.mkdir(exist_ok=True)
    for artifact in request.get("artifacts", []):
        subprocess.run(
            [
                "gh",
                "run",
                "download",
                os.environ["GITHUB_RUN_ID"],
                "--name",
                artifact,
                "--dir",
                str(STORE),
            ],
            check=True,
            timeout=600,
        )
    for key in request["shared"]:
        directory = STORE / key
        record = json.loads((directory / "manifest.json").read_text())
        if record["scope"] != scope():
            raise ValueError(
                f"{key}: simulator belongs to a different run, checkout or image"
            )
        if key.startswith("rvv-"):
            if f"rvv-{record['vlen']}" != key or record["threads"] != 4:
                raise ValueError(f"{key}: incompatible native simulator configuration")
            for name in ("frost-native", "frost-native.json"):
                if checksum(directory / name) != record["files"][name]:
                    raise ValueError(f"{key}: native simulator checksum differs")
            (directory / "frost-native").chmod(0o755)
        else:
            for name in ("Vtop", "Vtop__verFiles.dat"):
                if not (directory / name).is_file():
                    raise FileNotFoundError(directory / name)
    (STORE / "selection.json").write_text(json.dumps(request))


def main() -> None:
    """Run the producer, download, or Verilator make recipe."""
    if sys.argv[1] == "verilate":
        verilate(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif sys.argv[1] == "receive":
        receive(json.loads(sys.argv[2]))
    elif sys.argv[1] == "build":
        build_bundle(json.loads(sys.argv[2]), Path(sys.argv[3]))
    else:
        raise ValueError("expected build, receive or verilate")


if __name__ == "__main__":
    main()
