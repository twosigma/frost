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

"""Keep every registered Zicboz program configuration reachable from CI."""

import subprocess
import sys
from pathlib import Path

import yaml  # type: ignore[import-untyped]
from _pytest.mark.expression import Expression

from test_run_cocotb import TEST_REGISTRY


def test_zero_programs_have_one_ci_shard() -> None:
    """Require collection and one CI selection for each supported program tier."""
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "tests/test_run_cocotb.py",
            "--collect-only",
            "-q",
            "-m",
            "cocotb and cocotb_real_program",
            "-p",
            "no:cacheprovider",
        ],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
        timeout=120,
    )
    nodes = [line for line in result.stdout.splitlines() if line.startswith("tests/")]
    programs = {name for name in TEST_REGISTRY if name.startswith("cbo_zero_")}
    assert programs
    missing = [
        name for name in sorted(programs) if not any(f"[{name}]" in n for n in nodes)
    ]
    assert not missing, f"Zicboz configurations omitted from pytest: {missing}"

    workflow = yaml.safe_load((root / ".github/workflows/ci.yml").read_text())
    matrix = workflow["jobs"]["test-verilator"]["strategy"]["matrix"]
    jobs = [
        (tier, shard) for tier in matrix["mem_config"] for shard in matrix["shard"]
    ] + [(job["mem_config"], job["shard"]) for job in matrix["include"]]
    bram_axis_only = {
        "cbo_zero_bench",
        "cbo_zero_pages_board",
        # This registry entry selects its own DDR program layout.
        "cbo_zero_pages_board_ddr",
    }
    marks = {"cocotb", "cocotb_real_program"}

    def matches_mark(keyword: str, /, **kwargs: str | int | bool | None) -> bool:
        assert not kwargs
        return keyword in marks

    for name in sorted(programs):
        selected = [node for node in nodes if f"[{name}]" in node]
        assert len(selected) == 1, (name, selected)
        node = selected[0]

        def matches_keyword(keyword: str, /, **kwargs: str | int | bool | None) -> bool:
            assert not kwargs
            return keyword.casefold() in node.casefold()

        for tier in matrix["mem_config"]:
            matches = [
                shard["name"]
                for job_tier, shard in jobs
                if job_tier == tier
                and Expression.compile(shard["pytest_mark"]).evaluate(matches_mark)
                and Expression.compile(shard["pytest_filter"]).evaluate(matches_keyword)
            ]
            expected = 0 if tier == "ddr" and name in bram_axis_only else 1
            assert len(matches) == expected, (name, tier, matches)
