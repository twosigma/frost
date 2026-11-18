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

"""Keep every collected real program in one appropriately sized CI shard."""

import subprocess
import sys
from pathlib import Path

import yaml  # type: ignore[import-untyped]
from _pytest.mark.expression import Expression

from test_run_cocotb import (
    COREMARK_PRO_TESTS,
    DDR_TIER_EXCLUDE,
    TEST_REGISTRY,
    UNIT_TEST_PARAMS,
    UNIT_TESTS,
    UNIT_TESTS_IN_JOB_B,
)


VECTOR_SHARD = "Real Programs (Vector programs)"


def test_registered_programs_have_one_ci_shard() -> None:
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
    programs = {
        name
        for name, config in TEST_REGISTRY.items()
        if config.app_name is not None and config.include_in_pytest
    }
    assert programs
    missing = [
        name for name in sorted(programs) if not any(f"[{name}]" in n for n in nodes)
    ]
    assert not missing, f"Program configurations omitted from pytest: {missing}"

    workflow = yaml.safe_load((root / ".github/workflows/ci.yml").read_text())
    matrix = workflow["jobs"]["test-verilator"]["strategy"]["matrix"]
    jobs = [
        (tier, shard) for tier in matrix["mem_config"] for shard in matrix["shard"]
    ] + [(job["mem_config"], job["shard"]) for job in matrix["include"]]
    # Fixed-layout programs and tier-independent builds run on the BRAM axis.
    bram_axis_only = {
        "cbo_zero_bench",
        "cbo_zero_pages_board",
        "cbo_zero_pages_board_ddr",
    } | {
        name
        for name in programs
        if name.startswith("opensbi_") or name.endswith("_sram_macros")
    }
    marks = {"cocotb", "cocotb_real_program"}

    def matches_mark(keyword: str, /, **kwargs: str | int | bool | None) -> bool:
        assert not kwargs
        return keyword in marks

    errors: list[tuple[str, str, list[str], int | str | list[str]]] = []
    for name in sorted(programs):
        marks.discard("coremark_pro")
        if name in COREMARK_PRO_TESTS:
            marks.add("coremark_pro")
        selected = [node for node in nodes if f"[{name}]" in node]
        assert len(selected) == 1, (name, selected)
        node = selected[0]

        def matches_keyword(keyword: str, /, **kwargs: str | int | bool | None) -> bool:
            assert not kwargs
            return keyword.casefold() in node.casefold()

        for tier in matrix["mem_config"]:
            if tier == "ddr" and name in DDR_TIER_EXCLUDE:
                continue
            matches = [
                shard["name"]
                for job_tier, shard in jobs
                if job_tier == tier
                and Expression.compile(shard["pytest_mark"]).evaluate(matches_mark)
                and Expression.compile(shard["pytest_filter"]).evaluate(matches_keyword)
            ]
            expected = 0 if tier == "ddr" and name in bram_axis_only else 1
            if len(matches) != expected:
                errors.append((name, tier, matches, expected))
            # Vector programs, including ones added later, share one shard.
            if name.startswith("vec_") and matches != [VECTOR_SHARD]:
                errors.append((name, tier, matches, [VECTOR_SHARD]))
            if not name.startswith("vec_") and VECTOR_SHARD in matches:
                errors.append((name, tier, matches, "not the vector shard"))
    assert not errors, (
        f"Programs must select exactly one shard per supported tier: {errors}"
    )


def test_long_programs_have_named_ci_shards() -> None:
    """OpenSBI and budgets above 10 million cycles require explicit shards."""
    root = Path(__file__).resolve().parents[1]
    workflow = yaml.safe_load((root / ".github/workflows/ci.yml").read_text())
    matrix = workflow["jobs"]["test-verilator"]["strategy"]["matrix"]
    complements = [
        shard
        for shard in matrix["shard"]
        if shard["pytest_filter"].lstrip().startswith("not (")
    ]
    assert len(complements) == 1, "Keep one complement for unlisted programs"
    complement = Expression.compile(complements[0]["pytest_filter"])
    complement_mark = Expression.compile(complements[0]["pytest_mark"])
    unassigned = []
    for name, config in TEST_REGISTRY.items():
        if config.app_name is None or not config.include_in_pytest:
            continue
        long_budget = any(
            key.startswith("COCOTB_")
            and key.endswith("MAX_CYCLES")
            and int(value) > 10_000_000
            for key, value in config.extra_env
        )
        if not (name.startswith("opensbi_") or long_budget):
            continue
        marks = {"cocotb", "cocotb_real_program"}
        if name in COREMARK_PRO_TESTS:
            marks.add("coremark_pro")

        def matches_mark(keyword: str, /, **kwargs: str | int | bool | None) -> bool:
            assert not kwargs
            return keyword in marks

        if not complement_mark.evaluate(matches_mark):
            continue
        node = f"tests/test_run_cocotb.py::TestRealPrograms::test_real_program[{name}]"

        def matches_keyword(keyword: str, /, **kwargs: str | int | bool | None) -> bool:
            assert not kwargs
            return keyword.casefold() in node.casefold()

        if complement.evaluate(matches_keyword):
            unassigned.append(name)
    assert not unassigned, (
        "OpenSBI and programs with registry budgets above 10 million cycles need "
        "named shards and exclusions from Runtime and other: "
        f"{unassigned}"
    )


def test_every_unit_bench_is_in_exactly_one_unit_job() -> None:
    """Require each unit bench to select one of the two unit-test CI jobs."""
    root = Path(__file__).resolve().parents[1]
    workflow = yaml.safe_load((root / ".github/workflows/ci.yml").read_text())
    matrix = workflow["jobs"]["test-verilator"]["strategy"]["matrix"]
    jobs = [
        job["shard"]
        for job in matrix["include"]
        if job["shard"]["name"].startswith("Unit Tests")
    ]
    assert [job["name"] for job in jobs] == ["Unit Tests A", "Unit Tests B"]
    assert not UNIT_TESTS_IN_JOB_B - set(UNIT_TESTS), "stale job B entries"
    assert len(UNIT_TEST_PARAMS) == len(UNIT_TESTS)
    selected: dict[str, list[str]] = {}
    for param in UNIT_TEST_PARAMS:
        name = str(param.values[0])
        marks = {"cocotb"} | {mark.name for mark in param.marks}
        node = f"tests/test_run_cocotb.py::TestUnitTests::test_unit[{name}]"

        def matches_mark(keyword: str, /, **kwargs: str | int | bool | None) -> bool:
            assert not kwargs
            return keyword in marks

        def matches_keyword(keyword: str, /, **kwargs: str | int | bool | None) -> bool:
            assert not kwargs
            return keyword.casefold() in node.casefold()

        selected[name] = [
            job["name"]
            for job in jobs
            if Expression.compile(job["pytest_mark"]).evaluate(matches_mark)
            and Expression.compile(job["pytest_filter"]).evaluate(matches_keyword)
        ]
    wrong = {name: names for name, names in selected.items() if len(names) != 1}
    assert not wrong, f"Unit benches must select exactly one job: {wrong}"
    counts = [
        sum(job == [n] for job in selected.values())
        for n in ("Unit Tests A", "Unit Tests B")
    ]
    assert min(counts) > 0
    # The assignment halves the benches by measured time, so neither job may
    # hold much more than half of them.
    assert max(counts) <= 0.6 * len(UNIT_TESTS), counts


def test_shard_time_limits_stay_within_github_and_policy() -> None:
    """Only the unsplittable CoreMark-PRO loops program may exceed 300 minutes."""
    root = Path(__file__).resolve().parents[1]
    workflow = yaml.safe_load((root / ".github/workflows/ci.yml").read_text())
    matrix = workflow["jobs"]["test-verilator"]["strategy"]["matrix"]
    shards = list(matrix["shard"]) + [job["shard"] for job in matrix["include"]]
    too_long = {
        shard["name"]: shard["timeout_minutes"]
        for shard in shards
        if shard.get("timeout_minutes", 0) > 300
    }
    assert too_long == {"Real Programs (CoreMark-PRO / loops)": 340}, too_long
