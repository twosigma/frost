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

"""Print the pytest nodes in a formal CI shard that depend on given files."""

import argparse
import shlex
import subprocess
import sys
from pathlib import Path

import yaml  # type: ignore[import-untyped]

import ci_reuse
import sby_config
from test_fp_forward_wake_mutations import MUTATIONS as FP_FORWARD_WAKE_MUTATIONS
from test_pa_bridge_mutation import PROOF as PA_BRIDGE_PROOF
from test_predictor_mutations import MUTATIONS

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_PROOFS = {
    "tests/test_pa_bridge_mutation.py::test_wide_bridge_rejects_32_bit_offset": (
        PA_BRIDGE_PROOF
    ),
    **{
        f"tests/test_predictor_mutations.py::test_predictor_rejects_difference[{case}]": (
            ROOT / "formal" / f"{mutation.proof}.sby"
        )
        for case, mutation in MUTATIONS.items()
    },
    **{
        f"tests/test_fp_forward_wake_mutations.py::test_fp_forward_wake_rejects_fault[{case}]": (
            ROOT / "formal" / f"{mutation.proof}.sby"
        )
        for case, mutation in FP_FORWARD_WAKE_MUTATIONS.items()
    },
}
TOOL_CHECK = "tests/test_run_formal.py::TestFormalVerification::test_sby_installed"


def collect_nodes(command: str, expression: str) -> list[str]:
    """Collect with the same test paths and filter as the workflow."""
    words = shlex.split(command.replace("\\\n", ""))
    args = [
        arg
        for arg in words[words.index("pytest") + 1 :]
        if arg not in ("-v", "--durations=0")
    ]
    args[args.index("$PYTEST_FILTER")] = expression
    result = subprocess.run(
        [sys.executable, "-m", "pytest", *args, "--collect-only", "-q"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    if result.returncode:
        raise ValueError((result.stdout + result.stderr).strip())
    return ci_reuse.parse_collection(result.stdout)


def affected_nodes(nodes: list[str], sources: set[Path]) -> list[str]:
    """Match collected tasks and mutation cases against their proof inputs."""
    registry = ci_reuse.FormalRegistry(ROOT)
    selected = []
    affected: dict[Path, bool] = {}
    for node in nodes:
        if node == TOOL_CHECK:
            continue
        if match := ci_reuse.FORMAL_NODE.fullmatch(node):
            task = registry.tasks[match[1]]
            proof = ROOT / registry.formal_dir / task.sby_file
        else:
            fixture = node if node in FIXTURE_PROOFS else node.partition("[")[0]
            if fixture not in FIXTURE_PROOFS:
                raise ValueError(f"No proof mapping for collected fixture {fixture}")
            proof = FIXTURE_PROOFS[fixture]
            if ROOT / node.partition("::")[0] in sources:
                selected.append(node)
                continue
        if proof not in affected:
            affected[proof] = bool(
                sources.intersection(
                    path.resolve() for path in sby_config.proof_inputs(proof)
                )
            )
        if affected[proof]:
            selected.append(node)
    return selected


def main() -> None:
    """Read a shard from the workflow and print its matching node IDs."""
    workflow = yaml.safe_load((ROOT / ".github/workflows/ci.yml").read_text())
    job = workflow["jobs"]["test-formal"]
    filters = {
        shard["shard"]: shard["pytest_filter"]
        for shard in job["strategy"]["matrix"]["include"]
    }
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shard", choices=filters, default="Other tasks")
    parser.add_argument("sources", nargs="*", type=Path, help="proof or input paths")
    options = parser.parse_args()
    command = next(
        step["run"]
        for step in job["steps"]
        if step.get("name") == "Run formal verification"
    )
    try:
        selected = collect_nodes(command, filters[options.shard])
        if options.sources:
            selected = affected_nodes(
                selected, {path.resolve() for path in options.sources}
            )
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")
    if selected:
        print("\n".join(selected))
    else:
        print(f"No matching tests in {options.shard}", file=sys.stderr)


if __name__ == "__main__":
    main()
