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


"""Plan simulator artifacts from the test registry and CI job matrices."""

import argparse
from collections import Counter, defaultdict
from collections.abc import Iterator
import json

from _pytest.mark.expression import Expression

from ci_matrix import expand_matrix, workflow_jobs
from ci_sim_models import group, settings
from ci_verilator import job_matrix
from test_run_cocotb import (
    DDR_TIER_EXCLUDE,
    REAL_PROGRAM_TEST_PARAMS,
    TEST_REGISTRY,
    UNIT_TEST_PARAMS,
    CocotbRunConfig,
)
from test_testrig import (
    DEFAULT_DDR_CAPACITY_LOG2_BYTES,
    simulator_config,
    wfi,
)


def shard_filter(shard: dict, tier: str) -> str:
    """Resolve the base selector and any tier-specific extension as in CI."""
    base: str = shard["pytest_filter"]
    extra = shard.get("pytest_filter_extra", {}).get(tier)
    return f"({base}) or ({extra})" if extra else base


def registry_tests(row: dict) -> list[str]:
    """Apply the shard's pytest expressions to the registry's collected cases."""
    tier, shard = row["mem_config"], row["shard"]
    mark = Expression.compile(shard["pytest_mark"])
    keyword = Expression.compile(shard_filter(shard, tier))
    names = []
    for params, node in (
        (REAL_PROGRAM_TEST_PARAMS, "TestRealPrograms::test_real_program"),
        (UNIT_TEST_PARAMS, "TestUnitTests::test_unit"),
    ):
        for param in params:
            name = str(param.values[0])
            marks = {"cocotb", "slow", *(m.name for m in param.marks)}
            nodeid = f"tests/test_run_cocotb.py::{node}[{name}]".casefold()

            def matches_mark(k: str, /, **kwargs: str | int | bool | None) -> bool:
                return not kwargs and k in marks

            def matches_name(k: str, /, **kwargs: str | int | bool | None) -> bool:
                return not kwargs and k.casefold() in nodeid

            if (
                mark.evaluate(matches_mark)
                and keyword.evaluate(matches_name)
                and not (tier == "ddr" and name in DDR_TIER_EXCLUDE)
            ):
                names.append(name)
    return names


def aperture_tests(capacity: int, shard: dict) -> list[str]:
    """Select the boundary benches or the programs for this aperture."""
    if "tests" in shard:
        return shard["tests"].split()
    return [
        f"{name}_{capacity}g"
        for name in shard["programs"].split()
        if capacity != 1 or name not in ("pma_fault_test", "vm_test", "nic_loopback")
    ]


def config_for(test: CocotbRunConfig, env: dict[str, str]) -> dict[str, str]:
    """Apply the registry overrides to the environment of this job."""
    env = {**env, **dict(test.extra_env)}
    env["FROST_VERILATOR_EXTRA_ARGS"] = " ".join(
        (*test.verilator_extra_args, env.get("FROST_VERILATOR_EXTRA_ARGS", ""))
    ).strip()
    return settings(test.hdl_toplevel_module, env)


def cocotb_jobs(
    jobs: dict,
    *,
    full: bool = True,
    toggle: bool = False,
    event: str = "push",
) -> Iterator[tuple[str, str, list[dict[str, str]]]]:
    """List the elaborations requested by each selected CI cocotb job."""
    if full or toggle:
        for row in expand_matrix(job_matrix(coverage_only=toggle)):
            tier, shard = row["mem_config"], row["shard"]
            unit = shard["name"].startswith("Unit Tests")
            covered = tier in shard["coverage"]
            env = {
                "FROST_RANDOM_START": "0" if unit else "1",
                "FROST_COVERAGE": str(int(covered)),
                "FROST_COVERAGE_TOGGLE": str(int(unit or (toggle and covered))),
            }
            yield (
                "test-verilator",
                f"{tier}/{shard['name']}",
                [config_for(TEST_REGISTRY[name], env) for name in registry_tests(row)],
            )
    if not full:
        return
    for row in expand_matrix(jobs["test-pa-width"]["strategy"]["matrix"]):
        capacity, shard = row["capacity_gib"], row["shard"]
        env = {
            "FROST_RANDOM_START": str(int(shard["name"] != "Unit boundaries")),
            "FROST_COVERAGE": str(int(capacity in shard["coverage"])),
            "SIM_FAST_MAINT": str(int((capacity, shard["name"]) != (1, "Bare access"))),
        }
        yield (
            "test-pa-width",
            f"{capacity}/{shard['name']}",
            [
                config_for(TEST_REGISTRY[name], env)
                for name in aperture_tests(capacity, shard)
            ],
        )
    default = CocotbRunConfig("cocotb_tests.test_real_program", "frost")
    for job in (
        "test-arch-compliance",
        "test-riscv-tests",
        "test-riscv-benchmarks",
        "test-riscv-torture",
    ):
        for index, row in enumerate(expand_matrix(jobs[job]["strategy"]["matrix"])):
            env = {
                "FROST_RANDOM_START": "1",
                "FROST_COVERAGE": str(row.get("coverage", 0)),
            }
            yield job, str(index), [config_for(default, env)]
    for row in expand_matrix(jobs["test-testrig"]["strategy"]["matrix"]):
        env = {"FROST_RANDOM_START": "1", "FROST_COVERAGE": str(row["coverage"])}
        cases = [
            config_for(simulator_config(DEFAULT_DDR_CAPACITY_LOG2_BYTES, None), env)
        ]
        if row["shard"] == 1:
            cases.append(
                config_for(
                    simulator_config(
                        DEFAULT_DDR_CAPACITY_LOG2_BYTES,
                        None,
                        wfi_timeout_cycles=wfi.DUT_TIMEOUT_CYCLES,
                    ),
                    env,
                )
            )
        yield "test-testrig", str(row["shard"]), cases
    if event in ("push", "pull_request"):
        for row in expand_matrix(jobs["test-testrig-vector"]["strategy"]["matrix"]):
            env = {"FROST_RANDOM_START": "1", "FROST_COVERAGE": "0"}
            yield (
                "test-testrig-vector",
                str(row["vlen"]),
                [
                    config_for(
                        simulator_config(DEFAULT_DDR_CAPACITY_LOG2_BYTES, row["vlen"]),
                        env,
                    )
                ],
            )
    yield (
        "test-native",
        "live",
        [
            config_for(TEST_REGISTRY[name], {})
            for name in ("hello_world", "hello_world", "coremark")
        ],
    )


def plan(
    full: bool,
    vectors: list[dict],
    *,
    toggle: bool = False,
    event: str = "push",
) -> tuple[list[dict], dict]:
    """Group repeated builds into artifacts downloaded by the same jobs."""
    jobs = workflow_jobs()
    configs = {}
    consumers: dict[str, dict] = defaultdict(dict)
    counts: Counter[str] = Counter()
    for job, label, cases in cocotb_jobs(jobs, full=full, toggle=toggle, event=event):
        keys = []
        for config in cases:
            key = group(config)
            configs[key] = config
            keys.append(key)
        # Each native comparison cleans first. Other jobs keep matching builds
        # between cases, including unit benches that only run in their own job.
        counts.update(
            key
            for index, key in enumerate(keys)
            if job == "test-native" or not index or keys[index - 1] != key
        )
        consumers[job][label] = sorted(set(keys))
    producers = [
        {"key": key, "config": config}
        for key, config in configs.items()
        if counts[key] > 1
    ]
    for job_rows in consumers.values():
        for label, keys in job_rows.items():
            job_rows[label] = {
                "shared": [key for key in keys if counts[key] > 1],
                "local": [key for key in keys if counts[key] == 1],
            }
    for width, count in Counter(row["vlen"] for row in vectors).items():
        key = f"rvv-{width}"
        consumers["test-rvv"][str(width)] = {
            "shared": [key] if count > 1 else [],
            "local": [],
        }
        if count > 1:
            producers.append({"key": key, "vlen": width})
    # Put configurations used by the same jobs together. The two unit jobs
    # can exchange their common small benches in one upload and download.
    bundles: dict[tuple, list] = defaultdict(list)
    for model in producers:
        users = tuple(
            (job, label)
            for job, labels in consumers.items()
            for label, request in labels.items()
            if model["key"] in request["shared"]
        )
        bundles[users].append(model)
    matrix = []
    for users, models in bundles.items():
        artifact = "sim-" + models[0]["key"]
        for job, label in users:
            consumers[job][label].setdefault("artifacts", []).append(artifact)
        matrix.append({"artifact": artifact, "models": models})
    return matrix, consumers


def parse_vectors(value: str) -> list[dict]:
    """Decode the rvv_ci matrix JSON, or treat an empty skipped output as none."""
    if not value.strip():
        return []
    return list(json.loads(value)["include"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--full", choices=["true", "false"], required=True)
    parser.add_argument("--toggle", choices=["true", "false"], default="false")
    parser.add_argument("--event", default="push")
    parser.add_argument("--vectors", default="")
    args = parser.parse_args()
    matrix, consumers = plan(
        args.full == "true",
        parse_vectors(args.vectors),
        toggle=args.toggle == "true",
        event=args.event,
    )
    for name, value in (
        ("sim_matrix", {"include": matrix} if matrix else {}),
        ("sim_consumers", consumers),
    ):
        print(f"{name}=" + json.dumps(value, separators=(",", ":")))
