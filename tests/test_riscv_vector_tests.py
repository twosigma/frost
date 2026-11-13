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

r"""Run the self-checking riscv-vector-tests (chipsalliance) tests.

The suite's Go generator writes one assembly file per instruction form and
operand case. Spike then runs each test once to record the expected results,
the merger folds them into the test, and the finished test checks itself. The
image carries the generator, merger and patcher in /opt/riscv-vector-tests
(override with RISCV_VECTOR_TESTS_DIR). Run in the frost image from the
repository root:

    ./scripts/frost.py run python3 tests/test_riscv_vector_tests.py --pattern '^vadd\.vv$'
    ./scripts/frost.py run python3 tests/test_riscv_vector_tests.py --vlen 256 --shard 1/20
    ./scripts/frost.py run python3 tests/test_riscv_vector_tests.py --list

Without --rtl, each test runs on Spike as the suite's own reference check. A
full run at VLEN 128 is 3042 tests (generation about two minutes, build and run
about eight minutes at four jobs); --pattern and --shard select a part.

With --rtl, the tests are built for FROST (riscv_tests/riscv_test.h, the DDR
memory configuration, because the images are large) and run in simulation on a
core built with the vector unit and the matching VLEN:

    ./scripts/frost.py run bash -c 'cd tests && make clean'
    FROST_VERILATOR_EXTRA_ARGS='-GVECTOR=1 -GVLEN=128' \
        ./scripts/frost.py run python3 tests/test_riscv_vector_tests.py --rtl \
        --vlen 128 --pattern '^vadd\.vv$'

The pytest entry points run a small Spike sample, which guards the generator
and this wiring. The simulation entry point is skipped unless
FROST_RVV_TESTS_RTL=1 is set.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

import pytest

TESTS_DIR = Path(__file__).parent.resolve()
REPO_ROOT = TESTS_DIR.parent
RISCV_TESTS_APP_DIR = REPO_ROOT / "sw" / "apps" / "riscv_tests"

SUITE_DIR = Path(os.environ.get("RISCV_VECTOR_TESTS_DIR", "/opt/riscv-vector-tests"))
RISCV_PREFIX = os.environ.get("RISCV_PREFIX", "riscv64-linux-")

SUPPORTED_VLENS = (128, 256, 512)
DEFAULT_VLEN = 128

# The suite Makefile's ISA strings for XLEN 64. MARCH names the extensions the
# generator emits tests for; VARCH is the matching Spike configuration, with
# the hardware vector length.
MARCH = (
    "rv64gcv_zvbb_zvbc_zfh_zvfh_zvkg_zvkned_zvknha_zvksed_zvksh"
    "_zfbfmin_zvfbfmin_zvfbfwma"
)
# Compiler options the suite's Makefile uses; the defines and code-generation
# options are also passed to the FROST build.
GCC_TEST_OPTIONS = [
    "-fvisibility=hidden",
    "-DENTROPY=0xdeadbeef",
    "-DLFSR_BITS=9",
    "-fno-tree-loop-distribute-patterns",
]
GCC_OPTIONS = [
    "-static",
    "-mcmodel=medany",
    "-nostdlib",
    "-nostartfiles",
    *GCC_TEST_OPTIONS,
]

# Cycles for one test in simulation. The tests average about 34 thousand
# instructions and the largest about 94 thousand, with cold DDR on every
# first touch; the figure is a ceiling, not a measurement.
DEFAULT_RTL_MAX_CYCLES = "20000000"

# Instruction forms covered by the sample that CI runs: integer, widening,
# floating point, load, mask, crypto, and carry-less multiply.
SAMPLE_PATTERN = (
    r"^(vadd\.vv|vwmul\.vv|vfadd\.vv|vle8\.v|vmseq\.vv|vsha2ms\.vv|vclmul\.vv)$"
)


# Subdirectories of the work directory that one run fills.
PIPELINE_DIRECTORIES = ("stage1", "stage2", "patch", "bin1", "bin2")


def suite_available() -> bool:
    """Return whether the image carries the generator, merger and patcher."""
    return all(
        (SUITE_DIR / "build" / tool).is_file()
        for tool in ("generator", "merger", "pspike")
    )


def varch(vlen: int) -> str:
    """Return the Spike ISA suffix for a hardware vector length."""
    return f"zvl{vlen}b_zve64d_zfh_zfhmin_zvfh"


def spike_isa(vlen: int) -> str:
    """Return the Spike ISA string for a hardware vector length."""
    return f"{MARCH}_{varch(vlen)}"


def parse_makefrag(text: str) -> list[str]:
    """Return the test names from the generator's Makefrag."""
    names = []
    for line in text.splitlines()[1:]:
        name = line.strip().rstrip("\\").strip()
        if name:
            names.append(name)
    return names


def parse_shard(spec: str) -> tuple[int, int]:
    """Parse K/N (1-based) into (index, count).

    >>> parse_shard("2/5")
    (2, 5)
    """
    match = re.fullmatch(r"(\d+)/(\d+)", spec)
    if not match:
        raise argparse.ArgumentTypeError(f"shard must be K/N, got {spec!r}")
    index, count = int(match.group(1)), int(match.group(2))
    if not 1 <= index <= count:
        raise argparse.ArgumentTypeError(f"shard {spec!r}: need 1 <= K <= N")
    return index, count


def select_shard(names: list[str], index: int, count: int) -> list[str]:
    """Return the names of shard `index` of `count`, dealing sorted names round robin.

    >>> select_shard(["a", "b", "c", "d", "e"], 2, 3)
    ['b', 'e']
    """
    return sorted(names)[index - 1 :: count]


@dataclass
class VectorTestResult:
    """Result of one generated test."""

    name: str
    passed: bool
    message: str = ""


def run_tool(
    command: list[str], cwd: Path | None = None, timeout: int = 600
) -> subprocess.CompletedProcess[str]:
    """Run a command, capturing text output."""
    return subprocess.run(
        command, cwd=cwd, capture_output=True, text=True, timeout=timeout, check=False
    )


def generate_tests(
    workdir: Path,
    vlen: int,
    pattern: str,
    shard: tuple[int, int] | None = None,
) -> list[str]:
    """Run the generator into workdir/stage1 and return the selected test names.

    With a shard, the stage-1 sources of the other shards are removed so the
    later steps see only this shard's tests. Output of an earlier run in the
    same directory is cleared first, as the suite's Makefile does, because the
    merger takes every stage-1 source it finds.
    """
    workdir = workdir.resolve()
    for stale in PIPELINE_DIRECTORIES:
        shutil.rmtree(workdir / stale, ignore_errors=True)
    (workdir / "Makefrag").unlink(missing_ok=True)
    stage1 = workdir / "stage1"
    stage1.mkdir(parents=True, exist_ok=True)
    result = run_tool(
        [
            str(SUITE_DIR / "build" / "generator"),
            "-VLEN",
            str(vlen),
            "-XLEN",
            "64",
            "-split=10000",
            "-integer=0",
            f"-pattern={pattern}",
            "-testfloat3level=2",
            "-repeat=1",
            "-stage1output",
            f"{stage1}/",
            "-configs",
            f"{SUITE_DIR / 'configs'}/",
            "-march",
            MARCH,
        ],
        cwd=workdir,
        timeout=1800,
    )
    if result.returncode != 0:
        raise RuntimeError(f"generator failed:\n{result.stdout}{result.stderr}")
    makefrag = workdir / "Makefrag"
    names = parse_makefrag(makefrag.read_text()) if makefrag.is_file() else []
    if shard is not None:
        keep = set(select_shard(names, *shard))
        for name in names:
            if name not in keep:
                (stage1 / f"{name}.S").unlink()
        names = sorted(keep)
    return names


def suite_include_args() -> list[str]:
    """Include path of the suite's own physical test environment and macros."""
    return [
        f"-I{SUITE_DIR / 'env' / 'riscv-test-env' / 'p'}",
        f"-I{SUITE_DIR / 'macros' / 'general'}",
    ]


def build_and_patch(workdir: Path, name: str, vlen: int) -> str:
    """Build a stage-1 test and record its expected results with pspike.

    Returns an error message, or an empty string on success.
    """
    elf = workdir / "bin1" / name
    elf.parent.mkdir(exist_ok=True)
    patch = workdir / "patch" / f"{name}.patch"
    patch.parent.mkdir(exist_ok=True)
    build = run_tool(
        [
            f"{RISCV_PREFIX}gcc",
            f"-march={MARCH}",
            "-mabi=lp64d",
            *GCC_OPTIONS,
            *suite_include_args(),
            "-T",
            str(SUITE_DIR / "env" / "riscv-test-env" / "p" / "link.ld"),
            str(workdir / "stage1" / f"{name}.S"),
            "-o",
            str(elf),
        ],
        timeout=300,
    )
    if build.returncode != 0:
        return f"stage-1 build failed: {build.stderr.strip()[-400:]}"
    run = run_tool(
        [str(SUITE_DIR / "build" / "pspike"), f"--isa={spike_isa(vlen)}", str(elf)],
        timeout=300,
    )
    if run.returncode != 0:
        return f"pspike failed (exit {run.returncode}): {run.stderr.strip()[-400:]}"
    patch.write_text(run.stdout)
    return ""


def merge_stage2(workdir: Path) -> None:
    """Fold the recorded results into the stage-1 sources, giving stage 2."""
    (workdir / "stage2").mkdir(exist_ok=True)
    result = run_tool(
        [
            str(SUITE_DIR / "build" / "merger"),
            "-stage1output",
            f"{workdir / 'stage1'}/",
            "-stage2output",
            f"{workdir / 'stage2'}/",
            "-stage2patch",
            f"{workdir / 'patch'}/",
        ],
        cwd=workdir,
    )
    if result.returncode != 0:
        raise RuntimeError(f"merger failed:\n{result.stdout}{result.stderr}")


def run_on_spike(workdir: Path, name: str, vlen: int) -> VectorTestResult:
    """Build a stage-2 test with the suite's environment and run it on Spike."""
    elf = workdir / "bin2" / name
    elf.parent.mkdir(exist_ok=True)
    build = run_tool(
        [
            f"{RISCV_PREFIX}gcc",
            f"-march={MARCH}",
            "-mabi=lp64d",
            *GCC_OPTIONS,
            *suite_include_args(),
            "-T",
            str(SUITE_DIR / "env" / "riscv-test-env" / "p" / "link.ld"),
            str(workdir / "stage2" / f"{name}.S"),
            "-o",
            str(elf),
        ],
        timeout=300,
    )
    if build.returncode != 0:
        return VectorTestResult(
            name, False, f"stage-2 build failed: {build.stderr.strip()[-400:]}"
        )
    run = run_tool(["spike", f"--isa={spike_isa(vlen)}", str(elf)], timeout=300)
    if run.returncode != 0:
        return VectorTestResult(name, False, f"spike exit {run.returncode}")
    return VectorTestResult(name, True)


def prepare(
    workdir: Path, vlen: int, pattern: str, shard: tuple[int, int] | None, jobs: int
) -> tuple[list[str], list[VectorTestResult]]:
    """Generate, patch and merge; return the test names and any failures."""
    workdir = workdir.resolve()
    names = generate_tests(workdir, vlen, pattern, shard)
    failures: list[VectorTestResult] = []
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        errors = list(pool.map(lambda n: build_and_patch(workdir, n, vlen), names))
    good = []
    for name, error in zip(names, errors, strict=True):
        if error:
            failures.append(VectorTestResult(name, False, error))
            (workdir / "stage1" / f"{name}.S").unlink()
        else:
            good.append(name)
    if good:
        merge_stage2(workdir)
    return good, failures


def run_spike_tests(
    workdir: Path,
    vlen: int,
    pattern: str,
    shard: tuple[int, int] | None = None,
    jobs: int = 4,
) -> list[VectorTestResult]:
    """Generate the selected tests and run each on Spike as the self-check."""
    workdir = workdir.resolve()
    names, results = prepare(workdir, vlen, pattern, shard, jobs)
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        results += list(pool.map(lambda n: run_on_spike(workdir, n, vlen), names))
    return results


def compile_for_frost(source: Path, vlen: int) -> str:
    """Build a stage-2 test for FROST in the DDR configuration.

    Returns an error message, or an empty string on success.
    """
    subprocess.run(
        ["make", "clean"],
        cwd=RISCV_TESTS_APP_DIR,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    result = run_tool(
        [
            "make",
            f"TEST_SRC={source}",
            "MEM_CONFIG=ddr",
            "ENV=p",
            f"ARCH={MARCH}",
            f"EXTRA_INCLUDES=-I{SUITE_DIR / 'macros' / 'general'}",
            f"TEST_CFLAGS={' '.join(GCC_TEST_OPTIONS)}",
        ],
        cwd=RISCV_TESTS_APP_DIR,
        timeout=300,
    )
    return "" if result.returncode == 0 else result.stdout[-400:] + result.stderr[-400:]


def run_rtl_tests(
    workdir: Path,
    vlen: int,
    pattern: str,
    shard: tuple[int, int] | None = None,
    max_cycles: str = DEFAULT_RTL_MAX_CYCLES,
    jobs: int = 4,
) -> list[VectorTestResult]:
    """Generate the selected tests and run each on a FROST simulation."""
    # Imported here: the simulator harness is needed only for the RTL run.
    from test_riscv_tests import check_pass_fail, run_simulation

    workdir = workdir.resolve()
    names, results = prepare(workdir, vlen, pattern, shard, jobs)
    for name in names:
        error = compile_for_frost(workdir / "stage2" / f"{name}.S", vlen)
        if error:
            results.append(
                VectorTestResult(name, False, f"FROST build failed: {error}")
            )
            continue
        sim = run_simulation(
            os.environ.get("SIM", "verilator"),
            max_cycles=max_cycles,
            coverage_label=f"riscv_vector_tests_v{vlen}_{name}",
        )
        if sim is None:
            results.append(VectorTestResult(name, False, "simulation timed out"))
            continue
        status, message = check_pass_fail(sim)
        results.append(VectorTestResult(name, status == "PASS", message))
    return results


def report(results: list[VectorTestResult]) -> int:
    """Print per-test lines and a summary; return the process exit status."""
    for result in sorted(results, key=lambda r: r.name):
        line = f"  {result.name:40s} {'PASS' if result.passed else 'FAIL'}"
        if result.message:
            line += f"  ({result.message.splitlines()[0] if result.message else ''})"
        print(line, flush=True)
    failed = [r for r in results if not r.passed]
    print(f"{len(results) - len(failed)} passed, {len(failed)} failed")
    return 1 if failed or not results else 0


# =============================================================================
# Pytest integration
# =============================================================================

needs_suite = pytest.mark.skipif(
    not suite_available(),
    reason=(
        f"riscv-vector-tests is not in this image ({SUITE_DIR}); rebuild the image "
        "from the repository Dockerfile"
    ),
)


class TestHelpers:
    """Selection helpers; they need no tools."""

    def test_parse_makefrag(self) -> None:
        """The generator's Makefrag lists one test per line."""
        assert parse_makefrag("tests = \\\n  a-0 \\\n  b-1 \\\n") == ["a-0", "b-1"]

    def test_shards_partition_the_tests(self) -> None:
        """Every test lands in exactly one shard."""
        names = [f"t{i}" for i in range(23)]
        shards = [select_shard(names, k, 5) for k in range(1, 6)]
        assert sorted(sum(shards, [])) == sorted(names)

    def test_bad_shard_rejected(self) -> None:
        """K must lie in 1..N."""
        with pytest.raises(argparse.ArgumentTypeError):
            parse_shard("0/4")
        with pytest.raises(argparse.ArgumentTypeError):
            parse_shard("5/4")


@needs_suite
@pytest.mark.parametrize("vlen", [128, 256])
def test_spike_sample(vlen: int, tmp_path: Path) -> None:
    """A sample of generated tests passes on Spike at VLEN 128 and 256."""
    results = run_spike_tests(tmp_path, vlen, SAMPLE_PATTERN, shard=(1, 4), jobs=4)
    assert results, "the generator produced no tests"
    failed = [f"{r.name}: {r.message}" for r in results if not r.passed]
    assert not failed, "\n".join(failed)


@needs_suite
def test_reused_work_directory_and_relative_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A relative work directory works, and a rerun there starts clean."""
    monkeypatch.chdir(tmp_path)
    first = run_spike_tests(Path("work"), 128, r"^vadd\.vv$", jobs=2)
    assert first and all(r.passed for r in first)
    second = run_spike_tests(Path("work"), 128, r"^vsub\.vv$", jobs=2)
    assert second and all(r.passed for r in second)
    assert not any(r.name.startswith("vadd_vv") for r in second)


@needs_suite
def test_sample_shard_changes_selection(tmp_path: Path) -> None:
    """Different shards of one pattern generate different tests."""
    first = generate_tests(tmp_path / "a", 128, SAMPLE_PATTERN, (1, 4))
    second = generate_tests(tmp_path / "b", 128, SAMPLE_PATTERN, (2, 4))
    assert first and second and not set(first) & set(second)


@pytest.mark.cocotb
@pytest.mark.slow
@pytest.mark.skipif(
    os.environ.get("FROST_RVV_TESTS_RTL") != "1",
    reason="needs a core with the vector unit; set FROST_RVV_TESTS_RTL=1 and "
    "FROST_VERILATOR_EXTRA_ARGS='-GVECTOR=1 -GVLEN=<VLEN>'",
)
@needs_suite
def test_rtl_sample(tmp_path: Path) -> None:
    """A sample of generated tests passes on the simulated core."""
    vlen = int(os.environ.get("FROST_RVV_TESTS_VLEN", str(DEFAULT_VLEN)))
    results = run_rtl_tests(tmp_path, vlen, SAMPLE_PATTERN, shard=(1, 4))
    failed = [f"{r.name}: {r.message}" for r in results if not r.passed]
    assert results and not failed, "\n".join(failed)


def main() -> int:
    """Command-line entry point."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument(
        "--vlen", type=int, choices=SUPPORTED_VLENS, default=DEFAULT_VLEN
    )
    parser.add_argument("--pattern", default=".*", help="regex on instruction names")
    parser.add_argument("--shard", type=parse_shard, help="run shard K of N (1-based)")
    parser.add_argument("--jobs", type=int, default=4, help="parallel Spike jobs")
    parser.add_argument(
        "--rtl",
        action="store_true",
        help="run on the simulated core instead of Spike (needs a vector core)",
    )
    parser.add_argument("--max-cycles", default=DEFAULT_RTL_MAX_CYCLES)
    parser.add_argument("--workdir", type=Path, help="keep generated files here")
    parser.add_argument(
        "--list", action="store_true", help="print the selected tests and exit"
    )
    args = parser.parse_args()

    if not suite_available():
        print(
            f"error: riscv-vector-tests not found in {SUITE_DIR}; rebuild the image "
            "from the repository Dockerfile",
            file=sys.stderr,
        )
        return 2

    own_workdir = args.workdir is None
    workdir = (
        Path(tempfile.mkdtemp(prefix="rvv_tests_"))
        if own_workdir
        else args.workdir.resolve()
    )
    workdir.mkdir(parents=True, exist_ok=True)
    try:
        if args.list:
            for name in generate_tests(workdir, args.vlen, args.pattern, args.shard):
                print(name)
            return 0
        if args.rtl:
            results = run_rtl_tests(
                workdir, args.vlen, args.pattern, args.shard, args.max_cycles, args.jobs
            )
        else:
            results = run_spike_tests(
                workdir, args.vlen, args.pattern, args.shard, args.jobs
            )
        return report(results)
    finally:
        if own_workdir:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
