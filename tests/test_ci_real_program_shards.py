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

import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest
from _pytest.mark.expression import Expression

from ci_matrix import WORKFLOW, expand_matrix, workflow_jobs
from real_program_limits import real_program_cycle_limit
from test_run_cocotb import (
    COREMARK_PRO_TESTS,
    DDR_TIER_EXCLUDE,
    REAL_PROGRAM_TESTS,
    TEST_REGISTRY,
    UNIT_TEST_PARAMS,
    UNIT_TESTS,
    UNIT_TESTS_IN_JOB_B,
)


VECTOR_SHARD = "Vector programs"
COMPLEMENT = "Runtime and other"
SHARD_TITLE_PREFIX = "Real Programs ("
BUDGET_FILE = Path(__file__).with_name("fixtures") / "ci_real_program_budgets.json"
DEFAULT_TIMEOUT_MINUTES = 240
TIMEOUT_CEILING_MINUTES = 300
LONG_PROGRAM_SECONDS = 30 * 60
LONG_PROGRAM_CYCLES = 10_000_000


@dataclass(frozen=True)
class ProgramShard:
    """One expanded real-program job and the nodes selected by its filters."""

    name: str
    tier: str
    coverage: bool
    timeout_minutes: int
    selected: frozenset[str]

    @property
    def cases(self) -> frozenset[str]:
        """Programs that execute after the runner's DDR skips."""
        if self.tier == "ddr":
            return self.selected - DDR_TIER_EXCLUDE
        return self.selected


def _matrix() -> dict[str, Any]:
    matrix: dict[str, Any] = workflow_jobs()["test-verilator"]["strategy"]["matrix"]
    return matrix


def shard_filter(shard: dict[str, Any], tier: str) -> str:
    """Resolve the base selector and the tier-specific alternatives as in CI."""
    base: str = shard["pytest_filter"]
    extra = shard.get("pytest_filter_extra", {}).get(tier)
    return f"({base}) or ({extra})" if extra else base


def _is_opensbi(name: str) -> bool:
    return (
        name.startswith("opensbi_") or TEST_REGISTRY[name].app_name == "opensbi_smoke"
    )


@pytest.fixture(scope="module")
def real_program_shards() -> list[ProgramShard]:
    """Evaluate the workflow's selectors on the collected real-program nodes."""
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
        cwd=WORKFLOW.parents[2],
        capture_output=True,
        text=True,
        check=True,
        timeout=120,
    )
    nodes = [
        line.casefold()
        for line in result.stdout.splitlines()
        if line.startswith("tests/")
    ]
    nodes_by_program = {node.rsplit("[", 1)[-1].rstrip("]"): node for node in nodes}
    assert len(nodes_by_program) == len(nodes), "Duplicate application test IDs"
    assert nodes_by_program.keys() == set(REAL_PROGRAM_TESTS), (
        f"Programs omitted from pytest: {set(REAL_PROGRAM_TESTS) - nodes_by_program.keys()}"
    )

    shards = []
    complements = []
    for combo in expand_matrix(_matrix()):
        tier, shard = combo["mem_config"], combo["shard"]
        if not shard["name"].startswith(SHARD_TITLE_PREFIX):
            continue
        if shard["pytest_filter"].lstrip().startswith("not ("):
            complements.append((tier, shard["name"]))
        keyword_filter = Expression.compile(shard_filter(shard, tier))
        marker_filter = Expression.compile(shard["pytest_mark"])
        selected = set()
        for name, node in nodes_by_program.items():
            marks = {"cocotb", "cocotb_real_program", "slow"}
            if name in COREMARK_PRO_TESTS:
                marks.add("coremark_pro")

            def matches_mark(mark: str, /, **kwargs: str | int | bool | None) -> bool:
                assert not kwargs
                return mark in marks

            def matches_keyword(
                keyword: str, /, **kwargs: str | int | bool | None
            ) -> bool:
                assert not kwargs
                return keyword.casefold() in node

            if marker_filter.evaluate(matches_mark) and (
                keyword_filter.evaluate(matches_keyword)
            ):
                selected.add(name)
        shards.append(
            ProgramShard(
                shard["name"].removeprefix(SHARD_TITLE_PREFIX).removesuffix(")"),
                tier,
                tier in shard["coverage"],
                shard.get("timeout_minutes", DEFAULT_TIMEOUT_MINUTES),
                frozenset(selected),
            )
        )
    assert complements == [
        (tier, f"{SHARD_TITLE_PREFIX}{COMPLEMENT})") for tier in ("bram", "ddr")
    ], complements
    return shards


@pytest.fixture(scope="module")
def budgets() -> dict[str, Any]:
    """Load the hosted wall-time allowance for each program and job."""
    data: dict[str, Any] = json.loads(BUDGET_FILE.read_text())
    return data


def test_front_end_fuzzer_seeds_match_the_program_guides() -> None:
    """Each documented seed selects its own generator input in the registry."""
    root = Path(__file__).resolve().parents[1]
    guide = (root / "tests/README.md").read_text()
    documented = set(re.findall(r"`(fefuzz_\d+)`", guide))
    registered = {
        name for name, config in TEST_REGISTRY.items() if config.app_name == "fefuzz"
    }
    assert registered
    assert registered == documented
    for name in registered:
        seed = dict(TEST_REGISTRY[name].extra_env)["FE_SEED"]
        assert name == f"fefuzz_{seed}"
    assert "| `fefuzz/` |" in (root / "sw/README.md").read_text()


def test_registered_programs_have_one_ci_shard(
    real_program_shards: list[ProgramShard],
) -> None:
    """Require one CI selection for each supported program tier."""
    # Fixed-layout programs and tier-independent builds run on the BRAM axis.
    bram_axis_only = {
        "cbo_zero_bench",
        "cbo_zero_pages_board",
        "cbo_zero_pages_board_ddr",
    } | {
        name
        for name in REAL_PROGRAM_TESTS
        if _is_opensbi(name) or name.endswith("_sram_macros")
    }
    errors: list[tuple[str, str, list[str], int | str | list[str]]] = []
    for name in REAL_PROGRAM_TESTS:
        for tier in ("bram", "ddr"):
            matches = [
                shard.name
                for shard in real_program_shards
                if shard.tier == tier and name in shard.cases
            ]
            expected = (
                0 if tier == "ddr" and name in bram_axis_only | DDR_TIER_EXCLUDE else 1
            )
            if len(matches) != expected:
                errors.append((name, tier, matches, expected))
            if name.startswith("vec_") and matches != [VECTOR_SHARD]:
                errors.append((name, tier, matches, [VECTOR_SHARD]))
            if not name.startswith("vec_") and VECTOR_SHARD in matches:
                errors.append((name, tier, matches, "outside the vector shard"))
    assert not errors, (
        f"Programs must select exactly one shard per supported tier: {errors}"
    )


def test_opensbi_boots_have_dedicated_covered_bram_shards(
    real_program_shards: list[ProgramShard],
) -> None:
    """Each OpenSBI boot has one covered BRAM job of its own."""
    for name in REAL_PROGRAM_TESTS:
        if _is_opensbi(name):
            jobs = [shard for shard in real_program_shards if name in shard.selected]
            assert len(jobs) == 1, (name, jobs)
            shard = jobs[0]
            assert (shard.tier, shard.coverage, shard.selected) == (
                "bram",
                True,
                {name},
            ), (name, shard)


def test_long_programs_have_named_ci_shards(
    real_program_shards: list[ProgramShard], budgets: dict[str, Any]
) -> None:
    """Check effective cycle limits and planned wall times in the complement."""
    unassigned = []
    for shard in real_program_shards:
        if shard.name != COMPLEMENT:
            continue
        for name in sorted(shard.cases):
            config = TEST_REGISTRY[name]
            env = dict(config.extra_env)
            cycles = max(
                real_program_cycle_limit(config.app_name, env),
                max(
                    (
                        int(value)
                        for key, value in env.items()
                        if key.startswith("COCOTB_") and key.endswith("MAX_CYCLES")
                    ),
                    default=0,
                ),
            )
            seconds = budgets["case_seconds"][shard.tier].get(name, 0)
            if cycles > LONG_PROGRAM_CYCLES or seconds >= LONG_PROGRAM_SECONDS:
                unassigned.append((name, shard.tier, cycles, seconds))
    assert not unassigned, (
        "Programs above 10 million cycles or with at least 30 minutes of planned "
        f"wall time need named shards (name, tier, cycles, seconds): {unassigned}"
    )


def test_irq_take_hold_collects_coverage(
    real_program_shards: list[ProgramShard],
) -> None:
    """Keep the IRQ hold regression in covered jobs on both memory tiers."""
    jobs = [
        (shard.tier, shard.coverage)
        for shard in real_program_shards
        if "irq_take_hold_test" in shard.cases
    ]
    assert sorted(jobs) == [("bram", True), ("ddr", True)], jobs


def test_cocotb_job_uses_the_checked_selectors_and_timeout() -> None:
    """Tie selector and timeout evaluation to the workflow's job inputs."""
    job = workflow_jobs()["test-verilator"]
    env = next(
        step["env"] for step in job["steps"] if "PYTEST_MARK" in step.get("env", {})
    )
    extra = "matrix.shard.pytest_filter_extra[matrix.mem_config]"
    assert env["PYTEST_MARK"] == "${{ matrix.shard.pytest_mark }}"
    assert " ".join(env["PYTEST_FILTER"].split()) == (
        f"${{{{ {extra} && format('({{0}}) or ({{1}})', matrix.shard.pytest_filter, "
        f"{extra}) || matrix.shard.pytest_filter }}}}"
    )
    assert job["timeout-minutes"] == (
        "${{ matrix.shard.timeout_minutes || "
        f"(startsWith(matrix.shard.name, 'Unit Tests') && 360 || {DEFAULT_TIMEOUT_MINUTES}) }}}}"
    )


def test_program_shards_fit_wall_time_budgets(
    real_program_shards: list[ProgramShard], budgets: dict[str, Any]
) -> None:
    """Charge every selection against its shard's setup and execution allowance."""
    assert budgets["case_seconds"].keys() == {"bram", "ddr"}
    failures = []
    for tier in ("bram", "ddr"):
        shards = [shard for shard in real_program_shards if shard.tier == tier]
        case_seconds = budgets["case_seconds"][tier]
        overhead = budgets["job_overhead_seconds"][tier]
        capped = budgets["capped_plan_seconds"].get(tier, {})
        extra = case_seconds.keys() - {case for shard in shards for case in shard.cases}
        assert not extra, (
            f"{tier}: budget rows for unselected programs: {sorted(extra)}"
        )
        assert overhead.keys() == {shard.name for shard in shards}, tier
        assert capped.keys() <= overhead.keys(), tier
        assert all(
            type(seconds) is int and seconds > 0 for seconds in case_seconds.values()
        ), tier
        assert all(
            type(seconds) is int and seconds >= 0 for seconds in overhead.values()
        ), tier
        for shard in shards:
            missing = shard.cases - case_seconds.keys()
            if missing:
                failures.append(
                    f"{tier} / {shard.name}: supply case seconds for {sorted(missing)}"
                )
                continue
            timeout = shard.timeout_minutes * 60
            # The planned elapsed seconds must fit with the 1.8x allowance.
            # For ceiling-limited jobs, freeze growth at the recorded plan.
            plan_limit = timeout * 5 // 9
            if shard.name in capped:
                assert shard.timeout_minutes == TIMEOUT_CEILING_MINUTES, (
                    tier,
                    shard.name,
                )
                assert plan_limit < capped[shard.name] < timeout, (tier, shard.name)
                plan_limit = capped[shard.name]
            planned = overhead[shard.name] + sum(
                case_seconds[name] for name in shard.cases
            )
            if planned > plan_limit:
                failures.append(
                    f"{tier} / {shard.name}: {planned}s planned, {plan_limit}s allowed "
                    f"with a {shard.timeout_minutes}min job timeout"
                )
    assert not failures, "CI real-program budget exceeded:\n" + "\n".join(failures)


def test_every_unit_bench_is_in_exactly_one_unit_job() -> None:
    """Require each unit bench to select one of the two unit-test CI jobs."""
    matrix = _matrix()
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


def test_shard_time_limits_stay_within_github_and_policy(
    real_program_shards: list[ProgramShard],
) -> None:
    """Only the unsplittable CoreMark-PRO loops program may exceed 300 minutes."""
    exceptions = [
        (shard.name, shard.tier, shard.timeout_minutes, shard.selected)
        for shard in real_program_shards
        if shard.timeout_minutes > TIMEOUT_CEILING_MINUTES
    ]
    assert exceptions == [
        ("CoreMark-PRO / loops", tier, 340, {"coremark_pro_loops"})
        for tier in ("bram", "ddr")
    ], exceptions
