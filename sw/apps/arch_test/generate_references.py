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

"""Generate golden reference signatures with the Spike ISA simulator.

Compiles each riscv-arch-test assembly file for Spike, runs it, and
stores the resulting memory signature as the golden reference for
comparison against FROST's RTL simulation. Every test is built for RV64
(XLEN=64, FLEN=64), including the F and D tests that RV32 and RV64 share,
which the suite keeps under rv32i_m. References mirror the source path:
references/<suite>/<extension>/<test>.reference_output.

Run it inside the frost Docker image, which pins Spike, so the
references are reproducible.

Usage:
    ./generate_references.py --extensions I M A
    ./generate_references.py --all
    ./generate_references.py --test rv64i_m/I/src/add-01.S
    ./generate_references.py --test rv32i_m/F/src/fadd_b1-01.S
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
SUITE_ROOT = ARCH_TEST_DIR / "riscv-test-suite"
REFERENCES_DIR = SCRIPT_DIR / "references"

# Suite directories under riscv-test-suite that each extension's tests come
# from. rv64i_m holds the RV64 tests. The F and D tests that RV32 and RV64
# share (fadd, fmadd, fdiv, fsqrt, fcvt.w.s, fcvt.s.d, ...) exist only under
# rv32i_m; rv64i_m/F and rv64i_m/D hold just the RV64-only conversions and
# moves. Only tests whose RVTEST_ISA lists RV64 are selected, and only the .S
# files directly in each src directory (the *_b15 fused multiply-add sets in
# its subdirectories are not). This must match EXTENSION_SUITES in
# tests/test_arch_compliance.py.
DEFAULT_SUITES = ("rv64i_m",)
EXTENSION_SUITES: dict[str, tuple[str, ...]] = {
    "F": ("rv64i_m", "rv32i_m"),
    "D": ("rv64i_m", "rv32i_m"),
}

# The submodule's riscof env for the rv64 Spike reference build.
SPIKE_ENV_DIR = ARCH_TEST_DIR / "riscof-plugins" / "rv64" / "spike_simple" / "env"


def _signature_alignment(header: Path) -> tuple[int, int]:
    """Return the .align operands before begin_signature and end_signature.

    Macro continuation lines are joined first, and an operand that names a
    #define in the same header is resolved. Exits with an error when either
    bound has no numeric alignment.
    """
    text = header.read_text().replace("\\\n", " ")
    # A numeric #define, optionally followed by a // or /* */ comment.
    define_re = r"^\s*#define\s+(\w+)\s+(\d+)\s*(?://.*|/\*.*\*/)?\s*$"
    defines = dict(re.findall(define_re, text, re.MULTILINE))
    alignments = []
    for label in ("begin_signature", "end_signature"):
        match = re.search(rf"\.align\s+(\w+)\s*;\s*\.global\s+{label}\b", text)
        operand = defines.get(match.group(1), match.group(1)) if match else ""
        if not operand.isdigit():
            sys.exit(f"Error: {header}: no numeric .align before {label}")
        alignments.append(int(operand))
    return alignments[0], alignments[1]


def spike_env() -> Path:
    """Return the Spike env directory after checking its signature bounds.

    The signature region [begin_signature, end_signature) includes the
    trailing .align padding, so the Spike env and FROST's model_test.h must
    align both bounds alike, or the signatures differ by padding words. The
    bounds must also be at least 8-byte aligned: the FLEN=64 signature
    stores (fsd) must not misalign, and the pinned Spike has no --misaligned.
    """
    spike_align = _signature_alignment(SPIKE_ENV_DIR / "model_test.h")
    frost_align = _signature_alignment(SCRIPT_DIR / "model_test.h")
    if spike_align != frost_align:
        sys.exit(
            f"Error: signature alignment (begin, end) is {spike_align} in the Spike env "
            f"but {frost_align} in model_test.h; make FROST_SIG_ALIGN match the env."
        )
    if min(spike_align) < 3:
        sys.exit(
            f"Error: signature alignment {spike_align} is below 8 bytes (.align 3)."
        )
    return SPIKE_ENV_DIR


# gcc -march: must match what FROST's software builds may emit, including
# compressed code, except for the tests in NO_COMPRESS_TESTS below.
FROST_MARCH = "rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zbkb_zicond"

# Misaligned load/store trap tests whose test op must not be compressed. The
# framework trap handler (arch_test.h) resumes at (mepc & ~3) + 8, which
# assumes a 4-byte op and two 2-byte c.nops before the next test case. A
# compressed c.sd/c.ld/c.sw/c.lw leaves only 6 bytes, so the resume lands
# mid-instruction and the misdecoded code that follows faults on absolute
# addresses. The handler's region checks then make the signature depend on
# the link map, which differs between the Spike env's link.ld and FROST's
# linker scripts. Building these tests without C keeps every trap on the
# intended, link-independent path; the C suite and rv64uc cover the
# compressed encodings. This set must mirror NO_COMPRESS_TESTS in the app
# Makefile. The lh/lhu/sh/lwu tests need no entry because those ops have no
# C forms, and the branch/jump misalign tests need C for target-legality
# semantics.
NO_COMPRESS_TESTS = {
    "misalign-ld-01",
    "misalign-lw-01",
    "misalign-sw-01",
    "misalign-sd-01",
}


def test_march(test_name: str) -> str:
    """Return the gcc -march for one test (drops C for NO_COMPRESS_TESTS)."""
    march = FROST_MARCH
    if test_name in NO_COMPRESS_TESTS:
        march = march.replace("imafdc", "imafd")
    return march


# spike --isa. It keeps C even for the NO_COMPRESS_TESTS builds: the
# framework's fixed-length LA()/trap-prolog macros pad with c.nops that
# execute (.option rvc; .align; .option norvc in arch_test.h) regardless
# of the march, and a no-C Spike also changes misaligned-jump legality
# (the privilege misalign references).
SPIKE_ISA = "rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zbkb_zicond"

FROST_ABI = "lp64"

# Extensions that FROST supports and that have tests in the suite.
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
    # No F_Zcf: C.FLW/C.FSW are exactly the slots RV64C reinterprets
    # as C.LD/C.SD, so Zcf is an RV32-only extension.
    "D_Zcd",
    "hints",
]

# Allowed filename prefixes for extensions where only a subset of tests
# applies. privilege: FROST implements M, S, and U modes but no hypervisor.
# The envcfg tests are left out: they declare Zicbom, Zicboz, and Ssdtso, and
# FROST's menvcfg implements only STCE. K: FROST implements Zbkb only, which
# at rv64 is pack/packh/packw/brev8 (zip/unzip are RV32-only encodings).
EXTENSION_TEST_FILTERS: dict[str, set[str]] = {
    "privilege": {"ebreak", "ecall", "misalign"},
    "K": {"pack", "packh", "packw", "brev8"},
}

# Excluded by filename prefix: FROST has no Zbc (clmul/clmulh/clmulr), and
# the C directory mixes in Zcb tests FROST does not implement.
EXTENSION_TEST_EXCLUDES: dict[str, set[str]] = {
    "B": {"clmul"},
    "C": {"clbu", "clh", "clhu", "cmul", "cnot", "csb", "csext", "csh", "czext"},
}

RISCV_PREFIX = os.environ.get("RISCV_PREFIX", "riscv64-linux-")


def declares_rv64(test_src: Path) -> bool:
    """Return True if the test's RVTEST_ISA string lists an RV64 ISA."""
    match = re.search(r'RVTEST_ISA\("([^"]*)"\)', test_src.read_text(errors="replace"))
    return match is not None and "RV64" in match.group(1)


def reference_path(test_src: Path) -> Path:
    """Return the reference file for a test: references/<suite>/<extension>/<test>."""
    # Path shape: .../riscv-test-suite/<suite>/<extension>/src/[<subdir>/]<test>.S
    suite, extension = test_src.relative_to(SUITE_ROOT).parts[:2]
    return REFERENCES_DIR / suite / extension / f"{test_src.stem}.reference_output"


def discover_tests(extension: str) -> list[Path]:
    """Find the RV64 .S test files for an extension, applying filters."""
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
    env_dir: Path,
    verbose: bool = False,
) -> tuple[str, str, str]:
    """Compile a test for Spike, run it, and save the signature.

    Returns (test_name, status, message) where status is
    "OK", "SKIP", or "ERROR".
    """
    test_name = test_src.stem
    ref_path = reference_path(test_src)
    ref_path.parent.mkdir(parents=True, exist_ok=True)

    defines = test_defines(test_src)

    with tempfile.TemporaryDirectory() as tmpdir:
        elf_path = Path(tmpdir) / "test.elf"
        sig_path = Path(tmpdir) / "test.sig"

        cc = f"{RISCV_PREFIX}gcc"
        # FLEN=64: FROST has the D extension (64-bit FP registers).
        cmd = [
            cc,
            f"-march={test_march(test_name)}",
            f"-mabi={FROST_ABI}",
            "-static",
            "-fno-pie",
            "-no-pie",
            "-fno-stack-protector",
            "-mcmodel=medany",
            "-fvisibility=hidden",
            "-nostdlib",
            "-nostartfiles",
            "-g",
            f"-T{env_dir / 'link.ld'}",
            f"-I{env_dir}",
            f"-I{ARCH_TEST_DIR / 'riscv-test-suite' / 'env'}",
            "-DXLEN=64",
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

        # The signature area is at least 8-byte aligned (checked in spike_env),
        # so FLEN=64 signature stores never misalign and no --misaligned
        # support is needed. Tests that misalign by design install the
        # framework trap handler and trap identically here and on FROST.
        spike = os.environ.get("FROST_SPIKE", "spike")
        spike_cmd = [
            spike,
            f"--isa={SPIKE_ISA}",
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

        shutil.copy2(sig_path, ref_path)

        lines = ref_path.read_text().strip().split("\n")
        return test_name, "OK", f"{len(lines)} words"


def _worker(args: tuple[str, str, bool]) -> tuple[str, str, str]:
    """Worker for parallel reference generation."""
    test_src_str, env_dir_str, verbose = args
    return generate_one_reference(Path(test_src_str), Path(env_dir_str), verbose)


def main() -> int:
    """Generate golden reference signatures using Spike."""
    parser = argparse.ArgumentParser(
        description="Generate golden reference signatures using Spike",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--extensions", nargs="+", metavar="EXT")
    group.add_argument("--all", action="store_true")
    group.add_argument("--test", metavar="PATH")
    parser.add_argument("--parallel", type=int, default=8, metavar="N")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    if not shutil.which(os.environ.get("FROST_SPIKE", "spike")):
        print(
            "Error: spike not found in PATH. "
            "Run this script in the frost Docker image (scripts/frost.py run)."
        )
        return 1
    if not shutil.which(f"{RISCV_PREFIX}gcc"):
        print(
            f"Error: {RISCV_PREFIX}gcc not found in PATH. "
            "Run this script in the frost Docker image (scripts/frost.py run)."
        )
        return 1

    env_dir = spike_env()

    # Single test mode
    if args.test:
        test_path = SUITE_ROOT / args.test
        if not test_path.exists():
            print(f"Error: Test not found: {args.test}")
            return 1
        if not declares_rv64(test_path):
            print(f"Error: {args.test} does not list RV64 in its RVTEST_ISA")
            return 1
        name, status, msg = generate_one_reference(test_path, env_dir, args.verbose)
        print(f"{name:40s} {status}  {msg}")
        return 0 if status == "OK" else 1

    extensions = SUPPORTED_EXTENSIONS if args.all else args.extensions

    print(f"Generating references for: {', '.join(extensions)}")
    print(f"march: {FROST_MARCH}  spike --isa: {SPIKE_ISA}")
    print(f"Output: {REFERENCES_DIR}/")
    print()

    total_ok = 0
    total_skip = 0
    total_error = 0

    for ext in extensions:
        tests = discover_tests(ext)
        if not tests:
            print(f"{ext}: no tests found, skipping")
            continue

        print(f"{ext} ({len(tests)} tests):")
        work_items = [(str(t), str(env_dir), args.verbose) for t in tests]

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
    print(f"References stored in: {REFERENCES_DIR}/")
    return 1 if total_error > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
