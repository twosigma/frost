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
import os
import subprocess
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path

DEFAULT_IMAGE = "frost"
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
) -> list[str]:
    """Build the host-side Docker invocation for a workflow command."""
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
        command.extend(("--env", name))
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


def _argument_parser() -> argparse.ArgumentParser:
    """Create the command-line parser."""
    parser = argparse.ArgumentParser(
        description=(
            "Run FROST development workflows in the pinned container without "
            "creating root-owned repository files. Arguments after WORKFLOW are "
            "passed through unchanged."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
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
        choices=("cocotb", "pytest", "formal", "synthesis", "lint", "shell", "run"),
        help="workflow shortcut, or 'run' for an arbitrary command",
    )
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Run the selected workflow and return its exit status."""
    args = _argument_parser().parse_args(argv)
    try:
        container_command = workflow_command(args.workflow, args.arguments)
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2

    repository_root = Path(__file__).resolve().parents[1]
    uid = os.getuid()
    cache_directory = Path("/tmp") / f"frost-container-cache-{uid}"
    try:
        cache_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    except OSError as error:
        print(
            f"Error: could not create container cache {cache_directory}: {error}",
            file=sys.stderr,
        )
        return 1
    docker_command = build_docker_command(
        container_command,
        repository_root=repository_root,
        image=args.image,
        uid=uid,
        gid=os.getgid(),
        environment=os.environ,
        cache_directory=cache_directory,
        interactive=args.workflow == "shell",
    )
    try:
        result = subprocess.run(docker_command, check=False)
    except FileNotFoundError:
        print("Error: Docker is not installed or is not on PATH", file=sys.stderr)
        return 127
    except KeyboardInterrupt:
        return 130

    if result.returncode < 0:
        return 128 - result.returncode
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
