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

"""Generate golden reference signatures using Spike ISA simulator.

Compiles each riscv-arch-test assembly file for Spike, runs it, and
stores the resulting memory signature as the golden reference for
comparison against Frost's RTL simulation. References are namespaced
per XLEN (references/rv32i_m/... and references/rv64i_m/...) so the
two suites never collide (docs/rv64/phase1_plan.md D11).

Run inside the frost Docker image, which pins Spike (D10), so the
references are reproducible.

Usage:
    ./generate_references.py --extensions I M A
    ./generate_references.py --all
    ./generate_references.py --xlen 64 --all
    ./generate_references.py --test rv32i_m/I/src/add-01.S
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
ARCH_TEST_DIR = SCRIPT_DIR / "riscv-arch-test"
REFERENCES_DIR = SCRIPT_DIR / "references"

# Per-XLEN suite names: also the namespace under references/ (D11).
SUITE_NAMES = {32: "rv32i_m", 64: "rv64i_m"}


def suite_dir(xlen: int) -> Path:
    """Test-suite source directory for one XLEN."""
    return ARCH_TEST_DIR / "riscv-test-suite" / SUITE_NAMES[xlen]


def _submodule_spike_env(xlen: int) -> Path:
    """Return the submodule's riscof spike_simple env for one XLEN."""
    return ARCH_TEST_DIR / "riscof-plugins" / f"rv{xlen}" / "spike_simple" / "env"


def _build_spike_env(xlen: int) -> Path:
    """Materialize an 8-byte-signature-aligned copy of the submodule env.

    Derived at runtime from the submodule's riscof spike_simple plugin with
    one change: the signature area is force-aligned to 8 bytes. Frost runs
    FLEN=64, so the framework's signature stores (fsd, SIGALIGN=8) must not
    misalign, and this Spike build has no --misaligned. We patch ALIGNMENT
    into a throwaway dir rather than committing a derived copy of the
    framework header (whose inline-asm macros must not be reformatted).
    """
    env_dir = Path(tempfile.mkdtemp(prefix="frost_spike_env_"))
    src_env = _submodule_spike_env(xlen)
    shutil.copy(src_env / "link.ld", env_dir / "link.ld")
    header = (src_env / "model_test.h").read_text()
    # Force ALIGNMENT to 3 (8 bytes) on both XLEN branches.
    header = re.sub(r"#define ALIGNMENT\s+\d+", "#define ALIGNMENT 3", header)
    (env_dir / "model_test.h").write_text(header)
    return env_dir


# gcc -march — must match what Frost's software builds may emit. Both
# widths carry compressed code since the M4 C-table recode.
FROST_MARCH = {
    32: "rv32imafdc_zicsr_zifencei_zba_zbb_zbs_zbkb_zicond",
    64: "rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zbkb_zicond",
}

# spike --isa — matches the march today, but must keep C even if a
# future build drops it: the framework's fixed-length LA()/trap-prolog
# macros pad with c.nops that execute (.option rvc; .align; .option
# norvc in arch_test.h) regardless of the march, and a no-C Spike also
# changes misaligned-jump legality (the privilege misalign references).
SPIKE_ISA = {
    32: "rv32imafdc_zicsr_zifencei_zba_zbb_zbs_zbkb_zicond",
    64: "rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zbkb_zicond",
}

FROST_ABI = {32: "ilp32", 64: "lp64"}

# Extensions that Frost supports and that have tests in the suite.
SUPPORTED_EXTENSIONS = {
    32: [
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
        "F_Zcf",
        "D_Zcd",
        "hints",
    ],
    64: [
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
        # No F_Zcf at 64: C.FLW/C.FSW are exactly the slots RV64C
        # reinterprets as C.LD/C.SD, so Zcf is RV32-only.
        "D_Zcd",
        "hints",
    ],
}

# Filter for extensions where only a subset of tests applies.
# privilege: Frost implements M and U modes (no S-mode), so privilege tests
# are filtered to exclude the supervisor and hypervisor tests (and the U-mode
# menvcfg illegal-access tests, which the prefix whitelist below also drops).
# K: Frost implements Zbkb only — at rv32 that is pack/packh/brev8/zip/unzip;
# at rv64 zip/unzip retire (RV32-only encodings) and packw joins.
EXTENSION_TEST_FILTERS: dict[int, dict[str, set[str]]] = {
    32: {
        "privilege": {"ebreak", "ecall", "misalign", "menvcfg_m"},
        "K": {"pack", "packh", "brev8", "zip", "unzip"},
    },
    64: {
        "privilege": {"ebreak", "ecall", "misalign", "menvcfg_m"},
        "K": {"pack", "packh", "packw", "brev8"},
    },
}

# Excluded by filename prefix: Frost has no Zbc (clmul/clmulh/clmulr), and
# the C directory mixes in Zcb tests Frost does not implement.
EXTENSION_TEST_EXCLUDES: dict[int, dict[str, set[str]]] = {
    32: {
        "B": {"clmul"},
        "C": {"clbu", "clh", "clhu", "cmul", "cnot", "csb", "csext", "csh", "czext"},
        # menvcfg_m does not assemble at this suite snapshot.
        "privilege": {"menvcfg_m"},
    },
    64: {
        "B": {"clmul"},
        "C": {"clbu", "clh", "clhu", "cmul", "cnot", "csb", "csext", "csh", "czext"},
        "privilege": {"menvcfg_m"},
    },
}

RISCV_PREFIX = os.environ.get("RISCV_PREFIX", "riscv-none-elf-")


def discover_tests(extension: str, xlen: int) -> list[Path]:
    """Find all .S test files for an extension, applying filters."""
    src_dir = suite_dir(xlen) / extension / "src"
    if not src_dir.is_dir():
        return []
    tests = sorted(src_dir.glob("*.S"))
    allowed_prefixes = EXTENSION_TEST_FILTERS[xlen].get(extension)
    if allowed_prefixes is not None:
        tests = [
            t
            for t in tests
            if any(t.stem.startswith(prefix) for prefix in allowed_prefixes)
        ]
    excluded_prefixes = EXTENSION_TEST_EXCLUDES[xlen].get(extension)
    if excluded_prefixes is not None:
        tests = [
            t
            for t in tests
            if not any(t.stem.startswith(prefix) for prefix in excluded_prefixes)
        ]
    return tests


def test_defines(test_src: Path) -> list[str]:
    """Extract the compile defines a test declares in its RVTEST_CASE strings.

    riscof parses `def NAME=True` clauses from each case string and passes
    them as -D flags; this standalone flow does the same. Every test
    defines TEST_CASE_1 (gating its body); tests that need the framework
    trap handler additionally define rvtest_mtrap_routine.
    """
    text = test_src.read_text(errors="replace")
    names = sorted(set(re.findall(r"def\s+(\w+)\s*=\s*True", text)))
    return [f"-D{name}=True" for name in names]


def generate_one_reference(
    test_src: Path,
    extension: str,
    xlen: int,
    spike_env: Path,
    verbose: bool = False,
) -> tuple[str, str, str]:
    """Compile a test for Spike, run it, and save the signature.

    Returns (test_name, status, message) where status is
    "OK", "SKIP", or "ERROR".
    """
    test_name = test_src.stem
    ref_dir = REFERENCES_DIR / SUITE_NAMES[xlen] / extension
    ref_dir.mkdir(parents=True, exist_ok=True)
    ref_path = ref_dir / f"{test_name}.reference_output"

    defines = test_defines(test_src)

    with tempfile.TemporaryDirectory() as tmpdir:
        elf_path = Path(tmpdir) / "test.elf"
        sig_path = Path(tmpdir) / "test.sig"

        # Compile for Spike
        cc = f"{RISCV_PREFIX}gcc"
        # Use FLEN=64 since Frost has D extension (64-bit FP registers)
        cmd = [
            cc,
            f"-march={FROST_MARCH[xlen]}",
            f"-mabi={FROST_ABI[xlen]}",
            "-static",
            "-mcmodel=medany",
            "-fvisibility=hidden",
            "-nostdlib",
            "-nostartfiles",
            "-g",
            f"-T{spike_env / 'link.ld'}",
            f"-I{spike_env}",
            f"-I{ARCH_TEST_DIR / 'riscv-test-suite' / 'env'}",
            f"-DXLEN={xlen}",
            "-DFLEN=64",
            *defines,
            "-o",
            str(elf_path),
            str(test_src),
        ]
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode != 0:
            msg = result.stderr.strip().split("\n")[-1] if result.stderr else "unknown"
            return test_name, "SKIP", f"Compile failed: {msg}"

        # Run on Spike. The signature area is 8-aligned (see _build_spike_env),
        # so FLEN=64 signature stores never misalign and no --misaligned
        # support is needed; tests that deliberately misalign install the
        # framework trap handler and trap identically here and on Frost.
        spike = os.environ.get("FROST_SPIKE", "spike")
        spike_cmd = [
            spike,
            f"--isa={SPIKE_ISA[xlen]}",
            f"+signature={sig_path}",
            "+signature-granularity=4",
            str(elf_path),
        ]
        try:
            result = subprocess.run(
                spike_cmd,
                capture_output=True,
                text=True,
                timeout=60,
            )
        except subprocess.TimeoutExpired:
            return test_name, "SKIP", "Spike timed out"

        if result.returncode != 0:
            msg = result.stderr.strip().split("\n")[-1] if result.stderr else "unknown"
            return test_name, "ERROR", f"Spike failed: {msg}"

        if not sig_path.exists() or sig_path.stat().st_size == 0:
            return test_name, "ERROR", "Spike produced no signature"

        # Copy signature to references directory
        shutil.copy2(sig_path, ref_path)

        lines = ref_path.read_text().strip().split("\n")
        return test_name, "OK", f"{len(lines)} words"


def _worker(args: tuple[str, str, int, str, bool]) -> tuple[str, str, str]:
    """Worker for parallel reference generation."""
    test_src_str, extension, xlen, spike_env_str, verbose = args
    return generate_one_reference(
        Path(test_src_str), extension, xlen, Path(spike_env_str), verbose
    )


def main() -> int:
    """Generate golden reference signatures using Spike."""
    parser = argparse.ArgumentParser(
        description="Generate golden reference signatures using Spike",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--extensions", nargs="+", metavar="EXT")
    group.add_argument("--all", action="store_true")
    group.add_argument("--test", metavar="PATH")
    parser.add_argument(
        "--xlen",
        type=int,
        choices=(32, 64),
        default=32,
        help="Which suite/reference namespace to generate (default 32)",
    )
    parser.add_argument("--parallel", type=int, default=8, metavar="N")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    # Check prerequisites
    if not shutil.which(os.environ.get("FROST_SPIKE", "spike")):
        print("Error: spike not found in PATH. Install riscv-isa-sim first.")
        return 1
    if not shutil.which(f"{RISCV_PREFIX}gcc"):
        print(f"Error: {RISCV_PREFIX}gcc not found in PATH.")
        return 1

    spike_env = _build_spike_env(args.xlen)

    # Single test mode
    if args.test:
        test_path = ARCH_TEST_DIR / "riscv-test-suite" / args.test
        if not test_path.exists():
            test_path = suite_dir(args.xlen).parent / args.test
        if not test_path.exists():
            print(f"Error: Test not found: {args.test}")
            return 1
        parts = Path(args.test).parts
        ext = parts[1] if len(parts) > 1 else "unknown"
        name, status, msg = generate_one_reference(
            test_path, ext, args.xlen, spike_env, args.verbose
        )
        print(f"{name:40s} {status}  {msg}")
        return 0 if status == "OK" else 1

    extensions = SUPPORTED_EXTENSIONS[args.xlen] if args.all else args.extensions

    print(f"Generating references for: {', '.join(extensions)}")
    print(f"march: {FROST_MARCH[args.xlen]}  spike --isa: {SPIKE_ISA[args.xlen]}")
    print(f"Output: {REFERENCES_DIR / SUITE_NAMES[args.xlen]}/")
    print()

    total_ok = 0
    total_skip = 0
    total_error = 0

    for ext in extensions:
        tests = discover_tests(ext, args.xlen)
        if not tests:
            print(f"{ext}: no tests found, skipping")
            continue

        print(f"{ext} ({len(tests)} tests):")
        work_items = [
            (str(t), ext, args.xlen, str(spike_env), args.verbose) for t in tests
        ]

        results = []
        if args.parallel > 1 and len(tests) > 1:
            with ProcessPoolExecutor(max_workers=args.parallel) as executor:
                futures = {executor.submit(_worker, item): item for item in work_items}
                for future in as_completed(futures):
                    results.append(future.result())
        else:
            for item in work_items:
                results.append(_worker(item))

        # Sort by test name for consistent display
        results.sort(key=lambda r: r[0])

        n_ok = n_skip = n_err = 0
        for name, status, msg in results:
            if status == "OK":
                n_ok += 1
                if args.verbose:
                    print(f"  {name:40s} OK  ({msg})")
            elif status == "SKIP":
                n_skip += 1
                print(f"  {name:40s} SKIP  ({msg})")
            else:
                n_err += 1
                print(f"  {name:40s} ERROR  ({msg})")

        print(f"  => {n_ok} OK, {n_skip} SKIP, {n_err} ERROR")
        total_ok += n_ok
        total_skip += n_skip
        total_error += n_err

    print()
    print(f"Total: {total_ok} OK, {total_skip} SKIP, {total_error} ERROR")
    print(f"References stored in: {REFERENCES_DIR / SUITE_NAMES[args.xlen]}/")
    return 1 if total_error > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
