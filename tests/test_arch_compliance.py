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

"""Run riscv-arch-test cases and compare their signatures with Spike references.

The ISA runners share build directories, so clean tests/ before each run. From
the repository root:

    ./scripts/frost.py run make -C tests clean
    ./scripts/frost.py run python3 tests/test_arch_compliance.py --extensions I M
    ./scripts/frost.py run python3 tests/test_arch_compliance.py --all
    ./scripts/frost.py run python3 tests/test_arch_compliance.py --test rv64i_m/I/src/addw-01.S
    ./scripts/frost.py run python3 tests/test_arch_compliance.py --test rv32i_m/F/src/fadd_b1-01.S

Every test runs on the RV64 core, including the F and D tests that RV32 and
RV64 share, which the suite keeps under rv32i_m. The pytest entry point
(TestArchCompliance) is marked slow and reads the memory tier from
FROST_ARCH_MEM_CONFIG.
"""

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

from test_run_cocotb import CocotbRunner

# Directory layout
TESTS_DIR = Path(__file__).parent.resolve()
REPO_ROOT = TESTS_DIR.parent
ARCH_TEST_APP_DIR = REPO_ROOT / "sw" / "apps" / "arch_test"
ARCH_TEST_DIR = ARCH_TEST_APP_DIR / "riscv-arch-test"
REFERENCES_DIR = ARCH_TEST_APP_DIR / "references"

SUITE_ROOT = ARCH_TEST_DIR / "riscv-test-suite"

# Suite directories under riscv-test-suite that each extension's tests come
# from. rv64i_m holds the RV64 tests. The F and D tests that RV32 and RV64
# share (fadd, fmadd, fdiv, fsqrt, fcvt.w.s, fcvt.s.d, ...) exist only under
# rv32i_m; rv64i_m/F and rv64i_m/D hold just the RV64-only conversions and
# moves. Only tests whose RVTEST_ISA lists RV64 run, and only the .S files
# directly in each src directory (the *_b15 fused multiply-add sets in its
# subdirectories do not). This must match EXTENSION_SUITES in
# sw/apps/arch_test/generate_references.py.
DEFAULT_SUITES = ("rv64i_m",)
EXTENSION_SUITES: dict[str, tuple[str, ...]] = {
    "F": ("rv64i_m", "rv32i_m"),
    "D": ("rv64i_m", "rv32i_m"),
}

# The suite's extension directories that FROST runs.
SUPPORTED_EXTENSIONS = [
    "I",
    "M",
    "A",
    "F",
    "D",
    "C",
    "B",
    "K",
    "Zicond",
    "Zifencei",
    "privilege",
    # No F_Zcf: C.FLW/C.FSW are exactly the slots RV64C reinterprets as
    # C.LD/C.SD, so Zcf is RV32-only.
    "D_Zcd",
    "hints",
]

# Extensions FROST implements only in part: extension -> test-name prefixes to
# run. Extensions not listed are not filtered here.
# K: FROST implements Zbkb (pack/packh/packw/brev8; zip and unzip are RV32-only
# encodings) but not Zbkx (xperm4/xperm8), Zkn (AES/SHA256/SHA512), or Zks
# (SM3/SM4).
# privilege: FROST implements M, S, and U modes but no hypervisor. The envcfg
# tests are left out: they declare Zicbom, Zicboz, and Ssdtso, and FROST's
# menvcfg implements only STCE. The directed sw/apps/umode_test covers U-mode,
# including illegal M-CSR and MRET access from U.
EXTENSION_TEST_FILTERS: dict[str, set[str]] = {
    "K": {"pack", "packh", "packw", "brev8"},
    "privilege": {"ebreak", "ecall", "misalign"},
}

# Tests excluded by filename prefix. FROST implements Zba/Zbb/Zbs but not Zbc,
# so the carry-less multiply tests do not assemble for its -march. The C
# directory also holds Zcb tests (clbu/clh/csb/cmul/...), which FROST does not
# implement.
EXTENSION_TEST_EXCLUDES: dict[str, set[str]] = {
    "B": {"clmul"},
    "C": {"clbu", "clh", "clhu", "cmul", "cnot", "csb", "csext", "csh", "czext"},
}

# Tests with more than this many cases (inst_ labels) are too slow for
# Verilator and are left out unless --no-sim-filter (CLI) or include_all=True
# (API) is given.
SIM_MAX_TEST_CASES = 5000

# Per-test simulation timeout in seconds; FROST_ARCH_SIM_TIMEOUT_SEC overrides it.
# This and the cycle budget in run_simulation cover the largest tests, the
# fused multiply-add *_b1 sets that --no-sim-filter adds, in the ddr tier.
ARCH_SIM_TIMEOUT_SEC = int(os.environ.get("FROST_ARCH_SIM_TIMEOUT_SEC", "12600"))

# Memory configurations decide where a test's code, data, and signature live,
# so a failure points at one path. Selected with --mem-config and passed to the
# arch_test Makefile as MEM_CONFIG, which picks the linker script and crt0.
#   bram   - code, data, and signature in low BRAM (pure ISA conformance).
#   icache - code in DDR (the L1I fetch path under test), data and signature in
#            low BRAM (isolates instruction fetch from the D-side cached tier).
#   ddr    - code, data, and signature in DDR (also exercises the D-side cached
#            tier on every load and store); the default.
MEM_CONFIGS = ("bram", "icache", "ddr")
DEFAULT_MEM_CONFIG = "ddr"
PARALLEL_UNSAFE_MESSAGE = (
    "parallel execution is disabled: workers share application outputs, memory-image "
    "symlinks, and simulator build/results paths; use --parallel 1"
)


@dataclass
class TestResult:
    """Result of a single architecture test."""

    __test__ = False

    test_name: str
    extension: str
    status: str  # "PASS", "FAIL", "SKIP"
    message: str = ""


def _count_test_cases(test_src: Path) -> int:
    """Count inst_ labels in a test file (proxy for test case count)."""
    count = 0
    with open(test_src) as f:
        for line in f:
            if line.startswith("inst_"):
                count += 1
    return count


def declares_rv64(test_src: Path) -> bool:
    """Return True if the test's RVTEST_ISA string lists an RV64 ISA."""
    match = re.search(r'RVTEST_ISA\("([^"]*)"\)', test_src.read_text(errors="replace"))
    return match is not None and "RV64" in match.group(1)


def discover_tests(extension: str, include_all: bool = False) -> list[Path]:
    """Find the RV64 .S test files for an extension.

    Tests come from the extension's EXTENSION_SUITES directories. If the
    extension has a filter in EXTENSION_TEST_FILTERS, only tests whose
    filename (without numeric suffix) matches a filter prefix are returned.

    Unless include_all is True, tests with more than SIM_MAX_TEST_CASES cases
    are left out as too slow to simulate.
    """
    tests: list[Path] = []
    for suite in EXTENSION_SUITES.get(extension, DEFAULT_SUITES):
        src_dir = SUITE_ROOT / suite / extension / "src"
        if src_dir.is_dir():
            tests.extend(t for t in sorted(src_dir.glob("*.S")) if declares_rv64(t))
    allowed_prefixes = EXTENSION_TEST_FILTERS.get(extension)
    if allowed_prefixes is not None:
        tests = [
            t
            for t in tests
            if any(t.stem.startswith(prefix) for prefix in allowed_prefixes)
        ]
    excluded_prefixes = EXTENSION_TEST_EXCLUDES.get(extension)
    if excluded_prefixes is not None:
        tests = [
            t
            for t in tests
            if not any(t.stem.startswith(prefix) for prefix in excluded_prefixes)
        ]
    if not include_all:
        filtered = []
        for t in tests:
            count = _count_test_cases(t)
            if count > SIM_MAX_TEST_CASES:
                print(
                    f"  Skipping {t.stem} ({count} test cases > {SIM_MAX_TEST_CASES} limit)"
                )
            else:
                filtered.append(t)
        tests = filtered
    return tests


def select_shard(tests: list[Path], shard: int, shard_count: int) -> list[Path]:
    """Return shard number `shard` (1-based) of `shard_count`, balanced by case count.

    Tests are dealt largest first to the shard with the fewest cases so far,
    so the shards take similar simulation time. The split depends only on the
    test list, so every CI job computes the same partition.
    """
    loads = [0] * shard_count
    members: list[list[Path]] = [[] for _ in range(shard_count)]
    sized = sorted(
        ((_count_test_cases(t), t) for t in tests),
        key=lambda item: (-item[0], str(item[1])),
    )
    for cases, test in sized:
        index = loads.index(min(loads))
        members[index].append(test)
        loads[index] += cases
    return sorted(members[shard - 1])


def get_reference_path(test_src: Path) -> Path:
    """Return the reference signature path for a test source file.

    References live under references/{suite}/{extension}/{test}.reference_output
    and come from generate_references.py, run with the image's pinned Spike. The
    suite name comes from the test's own path.
    """
    # Path shape: .../riscv-test-suite/{SUITE}/{EXT}/src/[{subdir}/]{test}.S
    suite_name, ext_name = test_src.relative_to(SUITE_ROOT).parts[:2]
    return REFERENCES_DIR / suite_name / ext_name / f"{test_src.stem}.reference_output"


def compile_test(
    test_src: Path, mem_config: str = DEFAULT_MEM_CONFIG
) -> tuple[bool, str]:
    """Compile a single arch test.

    Returns (success, combined_make_output). mem_config selects the linker
    script and crt0 (and the BRAM/DDR section split) through the arch_test
    Makefile's MEM_CONFIG variable. The output lets the caller tell a low-BRAM
    capacity overflow (a DDR-only test) from a real compile failure.
    """
    env = dict(os.environ)
    subprocess.run(
        ["make", "clean"],
        cwd=ARCH_TEST_APP_DIR,
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
    )

    rel_src = test_src.relative_to(ARCH_TEST_APP_DIR)
    result = subprocess.run(
        ["make", f"TEST_SRC={rel_src}", f"MEM_CONFIG={mem_config}"],
        cwd=ARCH_TEST_APP_DIR,
        capture_output=True,
        text=True,
        timeout=120,
        env=env,
    )
    return result.returncode == 0, result.stdout + result.stderr


def run_simulation() -> subprocess.CompletedProcess[str] | None:
    """Simulate the compiled test; return the result, or None on timeout."""
    runner = CocotbRunner(
        python_test_module="cocotb_tests.test_real_program",
        hdl_toplevel_module="frost",
        app_name=None,  # compile_test builds the image before this runs
    )

    os.environ["SIM"] = "verilator"
    env = runner.setup_environment()
    # Arch tests use the hardware memory map: the boot stub always comes from
    # the 256 KiB low BRAM (sw.mem). How much of the test's code, data, and
    # signature lives in the cached DDR region (sw_ddr.mem, preloaded into the
    # behavioral DDR) depends on --mem-config: all of it for ddr, the code for
    # icache, and none for bram (which emits an empty sw_ddr.mem). The build
    # uses the shared sim_build directory.
    sim_build_dir = runner._get_sim_build_dir(env)
    # A 50M-cycle budget instead of the 500K application default.
    env["COCOTB_MAX_CYCLES"] = "50000000"

    original_dir = os.getcwd()
    os.chdir(TESTS_DIR)

    try:
        # Clean only when the existing Verilator build cannot be reused (a
        # different toplevel, cocotb installation, or FROST_VERILATOR_EXTRA_ARGS).
        needs_clean = runner._verilator_needs_rebuild(sim_build_dir)
        if needs_clean:
            subprocess.run(["make", "clean"], check=False, env=env)

        # Point the sw.mem / sw64.mem / sw_ddr.mem symlinks at the compiled test
        for mem_name in ("sw.mem", "sw64.mem", "sw_ddr.mem"):
            mem_path = Path(mem_name)
            if mem_path.exists() or mem_path.is_symlink():
                mem_path.unlink()
            mem_path.symlink_to(ARCH_TEST_APP_DIR / mem_name)

        pythonpath = env.get("PYTHONPATH", "")
        cmd = (
            f"export PYTHONPATH='{pythonpath}' && "
            f"make COCOTB_TEST_MODULES='cocotb_tests.test_real_program' "
            f"TOPLEVEL=frost"
        )
        result = subprocess.run(
            ["bash", "-c", cmd],
            capture_output=True,
            text=True,
            env=env,
            check=False,
            timeout=ARCH_SIM_TIMEOUT_SEC,
        )

        if result.returncode == 0:
            runner._update_verilator_toplevel_marker(sim_build_dir)

        return result

    except subprocess.TimeoutExpired:
        return None
    finally:
        for mem_name in ("sw.mem", "sw64.mem", "sw_ddr.mem"):
            mem_path = Path(mem_name)
            if mem_path.exists() or mem_path.is_symlink():
                mem_path.unlink()
        os.chdir(original_dir)


def extract_signature(sim_output: str) -> list[str]:
    """Extract hex signature lines from simulation UART output.

    The RVMODEL_HALT macro prints each signature word as 8 lowercase hex
    characters followed by a newline, then <<PASS>>. Every 8-character hex line
    up to the standalone <<PASS>> marker is collected (the marker must start
    the line; "success_marker=<<PASS>>" inside a log message does not count).
    Interspersed cocotb log lines are ignored.
    """
    lines = sim_output.splitlines()
    sig_lines: list[str] = []
    for line in lines:
        stripped = line.strip()
        # Signature words are exactly 8 hex characters, one per line.
        if len(stripped) == 8 and all(c in "0123456789abcdefABCDEF" for c in stripped):
            sig_lines.append(stripped.lower())
        elif sig_lines and stripped.startswith("<<PASS>>"):
            # The signature dump is terminated by the standalone <<PASS>> marker.
            break
        # Any other line (cocotb logs, banners, blanks) is skipped without
        # discarding the words collected so far: cocotb logs periodically
        # during a long dump, so its lines can fall between signature words.
        # Signature words are the only bare 8-hex-digit lines the program
        # prints, so collecting them all up to <<PASS>> is exact.
    return sig_lines


def load_reference(ref_path: Path) -> list[str]:
    """Read a reference signature as lowercase hex words, skipping blank lines."""
    lines = []
    for line in ref_path.read_text().splitlines():
        stripped = line.strip()
        if stripped:
            lines.append(stripped.lower())
    return lines


def compare_signatures(actual: list[str], expected: list[str]) -> tuple[bool, str]:
    """Compare actual vs expected signatures, return (match, diff_message)."""
    if actual == expected:
        return True, ""

    # Report the word counts first, so a length mismatch (a truncated or
    # misextracted signature) stands out even when few words differ.
    diff_lines = [f"  (actual={len(actual)} words, expected={len(expected)} words)"]
    max_len = max(len(actual), len(expected))
    shown = 0
    for i in range(max_len):
        act = actual[i] if i < len(actual) else "<missing>"
        exp = expected[i] if i < len(expected) else "<missing>"
        if act != exp:
            diff_lines.append(f"  word {i}: got {act}, expected {exp}")
            shown += 1
            if shown >= 5:
                diff_lines.append("  ... and more")
                break

    return False, "\n".join(diff_lines)


def run_single_test(
    test_src: Path, extension: str, mem_config: str = DEFAULT_MEM_CONFIG
) -> TestResult:
    """Build, simulate, and verify a single arch test in the given mem config."""
    test_name = test_src.stem

    ref_path = get_reference_path(test_src)
    if not ref_path.exists():
        return TestResult(test_name, extension, "SKIP", "No reference output")

    compiled, compile_out = compile_test(test_src, mem_config)
    if not compiled:
        # In the bram and icache tiers, a linker region overflow means the test
        # does not fit in low BRAM (95 KiB of code, 1 KiB reserved for debug,
        # and 160 KiB of data and stack), assuming icache code fits its 64 MiB
        # DDR region. Report SKIP: the ddr tier, with 64 MiB, runs the test.
        if mem_config != "ddr" and (
            "will not fit in region" in compile_out or "overflowed by" in compile_out
        ):
            return TestResult(
                test_name,
                extension,
                "SKIP",
                f"exceeds low-BRAM capacity ({mem_config}); covered by the ddr tier",
            )
        return TestResult(test_name, extension, "FAIL", "Compilation failed")

    result = run_simulation()
    if result is None:
        return TestResult(
            test_name,
            extension,
            "FAIL",
            f"Simulation timed out after {ARCH_SIM_TIMEOUT_SEC}s",
        )

    combined_output = (result.stdout or "") + (result.stderr or "")

    # Check returncode first: when cocotb hits max cycles, its error message
    # contains the literal '<<PASS>>' string (the marker it was searching for),
    # so checking the output text first would give a false positive.
    if result.returncode != 0:
        return TestResult(
            test_name,
            extension,
            "FAIL",
            f"Simulation error (exit code {result.returncode})",
        )

    if "<<PASS>>" not in combined_output:
        return TestResult(test_name, extension, "FAIL", "No <<PASS>> marker in output")

    actual_sig = extract_signature(combined_output)
    if not actual_sig:
        return TestResult(test_name, extension, "FAIL", "No signature data in output")

    expected_sig = load_reference(ref_path)
    match, diff_msg = compare_signatures(actual_sig, expected_sig)

    if match:
        return TestResult(test_name, extension, "PASS")
    else:
        return TestResult(
            test_name, extension, "FAIL", f"Signature mismatch:\n{diff_msg}"
        )


def run_extension_tests(
    extension: str,
    parallel: int = 1,
    include_all: bool = False,
    mem_config: str = DEFAULT_MEM_CONFIG,
    shard: tuple[int, int] | None = None,
) -> list[TestResult]:
    """Run all tests for a given extension, or one (index, count) shard of them."""
    if parallel != 1:
        raise ValueError(PARALLEL_UNSAFE_MESSAGE)

    tests = discover_tests(extension, include_all=include_all)
    if shard is not None:
        tests = select_shard(tests, *shard)
    if not tests:
        print(f"  No tests found for extension {extension}")
        return []

    suites = ", ".join(EXTENSION_SUITES.get(extension, DEFAULT_SUITES))
    shard_text = f", shard {shard[0]}/{shard[1]}" if shard is not None else ""
    print(
        f"\nExtension: {extension} ({len(tests)} tests{shard_text}, "
        f"suites={suites}, mem-config={mem_config})"
    )

    results = []

    for test_src in tests:
        result = run_single_test(test_src, extension, mem_config)
        results.append(result)
        _print_result(result)

    return results


def _print_result(result: TestResult) -> None:
    """Print a single test result."""
    status_str = {
        "PASS": "PASS",
        "FAIL": "FAIL",
        "SKIP": "SKIP",
    }[result.status]
    line = f"  {result.test_name:40s} {status_str}"
    if result.message and result.status != "PASS":
        first_line = result.message.split("\n")[0]
        line += f"  ({first_line})"
    print(line)


# =============================================================================
# Pytest Integration
# =============================================================================


@pytest.mark.cocotb
@pytest.mark.slow
class TestArchCompliance:
    """RISC-V Architecture Compliance Tests (riscv-arch-test)."""

    EXTENSIONS = SUPPORTED_EXTENSIONS

    @pytest.mark.parametrize("extension", EXTENSIONS)
    def test_arch_compliance(self, extension: str, capsys: Any) -> None:
        """Run arch compliance tests for a single ISA extension.

        Parametrized by extension (not individual test) for manageable pytest output.
        The memory config defaults to ddr; override with FROST_ARCH_MEM_CONFIG.
        """
        os.environ["SIM"] = "verilator"
        mem_config = os.environ.get("FROST_ARCH_MEM_CONFIG", DEFAULT_MEM_CONFIG)
        with capsys.disabled():
            print(
                f"\nRunning arch compliance tests for extension {extension} "
                f"(mem-config={mem_config})..."
            )
            results = run_extension_tests(extension, mem_config=mem_config)

        failed = [r for r in results if r.status == "FAIL"]
        if failed:
            msg = "\n".join(f"  {r.test_name}: {r.message}" for r in failed)
            pytest.fail(f"{len(failed)} arch test(s) failed:\n{msg}")


# =============================================================================
# Standalone CLI
# =============================================================================


def main() -> int:
    """Run the selected arch tests and return the exit status."""
    parser = argparse.ArgumentParser(
        description="Run riscv-arch-test cases on FROST against Spike references",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Examples:
  %(prog)s --extensions I M
  %(prog)s --all
  %(prog)s --test rv64i_m/I/src/addw-01.S
  %(prog)s --test rv32i_m/F/src/fadd_b1-01.S

Available extensions: {", ".join(SUPPORTED_EXTENSIONS)}
""",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--extensions",
        nargs="+",
        metavar="EXT",
        help="Extensions to test (e.g., I M C F)",
    )
    group.add_argument(
        "--all",
        action="store_true",
        help="Run all supported extensions",
    )
    group.add_argument(
        "--test",
        metavar="PATH",
        help="Run a single test (path relative to riscv-test-suite, e.g., rv64i_m/I/src/addw-01.S)",
    )
    parser.add_argument(
        "--parallel",
        type=int,
        default=1,
        metavar="N",
        help="Number of workers; only 1 is supported",
    )
    parser.add_argument(
        "--shard",
        metavar="K/N",
        help="Run only shard K of N of each extension's tests, balanced by case count",
    )
    parser.add_argument(
        "--no-sim-filter",
        action="store_true",
        help="Also run tests with over 5000 cases (left out by default as too slow)",
    )
    parser.add_argument(
        "--mem-config",
        choices=MEM_CONFIGS,
        default=DEFAULT_MEM_CONFIG,
        help=(
            "Memory configuration: 'bram' (code, data, and signature in low BRAM), "
            "'icache' (code in DDR, data and signature in BRAM, to isolate "
            "instruction fetch), or 'ddr' (code, data, and signature in DDR, which "
            f"also exercises the D-side cached tier). Default: {DEFAULT_MEM_CONFIG}."
        ),
    )

    args = parser.parse_args()
    if args.parallel != 1:
        parser.error(PARALLEL_UNSAFE_MESSAGE)
    shard = None
    if args.shard is not None:
        match = re.fullmatch(r"(\d+)/(\d+)", args.shard)
        if not match or not 1 <= int(match.group(1)) <= int(match.group(2)):
            parser.error("--shard must be K/N with 1 <= K <= N")
        if args.test:
            parser.error("--shard applies to --extensions and --all, not --test")
        shard = (int(match.group(1)), int(match.group(2)))

    # Single test mode
    if args.test:
        test_path = SUITE_ROOT / args.test
        if not test_path.exists():
            print(f"Error: Test file not found: {args.test}")
            return 1
        if not declares_rv64(test_path):
            print(f"Error: {args.test} does not list RV64 in its RVTEST_ISA")
            return 1

        parts = Path(args.test).parts
        ext = parts[1] if len(parts) > 1 else "unknown"

        print(
            f"=== RISC-V Architecture Test: {args.test} (mem-config={args.mem_config}) ==="
        )
        result = run_single_test(test_path, ext, args.mem_config)
        _print_result(result)
        return 0 if result.status == "PASS" else 1

    # Multi-extension mode
    extensions = SUPPORTED_EXTENSIONS if args.all else args.extensions

    for ext in extensions:
        ext_suites = EXTENSION_SUITES.get(ext, DEFAULT_SUITES)
        if not any((SUITE_ROOT / suite / ext).is_dir() for suite in ext_suites):
            print(f"Warning: Extension '{ext}' not found in test suite, skipping")

    print("=" * 60)
    print("RISC-V Architecture Test Results")
    suites = sorted(
        {s for ext in extensions for s in EXTENSION_SUITES.get(ext, DEFAULT_SUITES)}
    )
    print(f"Suites: {', '.join(suites)}")
    print(f"Extensions: {', '.join(extensions)}")
    print(f"Memory config: {args.mem_config}")
    print("=" * 60)

    all_results: list[TestResult] = []
    for ext in extensions:
        results = run_extension_tests(
            ext,
            parallel=args.parallel,
            include_all=args.no_sim_filter,
            mem_config=args.mem_config,
            shard=shard,
        )
        all_results.extend(results)

    # Summary
    n_pass = sum(1 for r in all_results if r.status == "PASS")
    n_fail = sum(1 for r in all_results if r.status == "FAIL")
    n_skip = sum(1 for r in all_results if r.status == "SKIP")

    print()
    print("=" * 60)
    print(f"Summary: {n_pass} PASS, {n_fail} FAIL, {n_skip} SKIP")
    print("=" * 60)

    failed = [r for r in all_results if r.status == "FAIL"]
    if failed:
        print("\nFailed tests:")
        for r in failed:
            print(f"  [{r.extension}] {r.test_name}")
            if r.message:
                for line in r.message.split("\n"):
                    print(f"    {line}")

    return 1 if n_fail > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
