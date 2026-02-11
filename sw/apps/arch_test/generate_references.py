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
comparison against Frost's RTL simulation.

Usage:
    ./generate_references.py --extensions I M A
    ./generate_references.py --all
    ./generate_references.py --test rv32i_m/I/src/add-01.S
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
ARCH_TEST_DIR = SCRIPT_DIR / "riscv-arch-test"
SUITE_DIR = ARCH_TEST_DIR / "riscv-test-suite" / "rv32i_m"
SPIKE_ENV = ARCH_TEST_DIR / "riscof-plugins" / "rv32" / "spike_simple" / "env"
REFERENCES_DIR = SCRIPT_DIR / "references"

# Frost ISA string — must match what Frost implements
FROST_ISA = "rv32imafdc_zicsr_zifencei_zba_zbb_zbs_zbkb_zicond"

# Extensions that Frost supports and that have tests in the suite
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
    "F_Zcf",
    "D_Zcd",
    "hints",
]

# Filter for extensions where only a subset of tests applies.
# Frost is M-mode only (no S/U mode), so privilege tests are filtered
# to exclude supervisor, user, and hypervisor tests.
EXTENSION_TEST_FILTERS: dict[str, set[str]] = {
    "privilege": {
        "ebreak",
        "ecall",
        "misalign",
        "menvcfg_m",
    },
}

RISCV_PREFIX = os.environ.get("RISCV_PREFIX", "riscv-none-elf-")


def discover_tests(extension: str) -> list[Path]:
    """Find all .S test files for an extension, applying filters."""
    src_dir = SUITE_DIR / extension / "src"
    if not src_dir.is_dir():
        return []
    tests = sorted(src_dir.glob("*.S"))
    allowed_prefixes = EXTENSION_TEST_FILTERS.get(extension)
    if allowed_prefixes is not None:
        tests = [
            t
            for t in tests
            if any(t.stem.startswith(prefix) for prefix in allowed_prefixes)
        ]
    return tests


def generate_one_reference(
    test_src: Path, extension: str, verbose: bool = False
) -> tuple[str, str, str]:
    """Compile a test for Spike, run it, and save the signature.

    Returns (test_name, status, message) where status is
    "OK", "SKIP", or "ERROR".
    """
    test_name = test_src.stem
    ref_dir = REFERENCES_DIR / extension
    ref_dir.mkdir(parents=True, exist_ok=True)
    ref_path = ref_dir / f"{test_name}.reference_output"

    with tempfile.TemporaryDirectory() as tmpdir:
        elf_path = Path(tmpdir) / "test.elf"
        sig_path = Path(tmpdir) / "test.sig"

        # Compile for Spike
        cc = f"{RISCV_PREFIX}gcc"
        # Use FLEN=64 since Frost has D extension (64-bit FP registers)
        cmd = [
            cc,
            f"-march={FROST_ISA}",
            "-mabi=ilp32",
            "-static",
            "-mcmodel=medany",
            "-fvisibility=hidden",
            "-nostdlib",
            "-nostartfiles",
            "-g",
            f"-T{SPIKE_ENV / 'link.ld'}",
            f"-I{SPIKE_ENV}",
            f"-I{ARCH_TEST_DIR / 'riscv-test-suite' / 'env'}",
            "-DXLEN=32",
            "-DFLEN=64",
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

        # Run on Spike
        spike_cmd = [
            "spike",
            f"--isa={FROST_ISA}",
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


def _worker(args: tuple[str, str, bool]) -> tuple[str, str, str]:
    """Worker for parallel reference generation."""
    test_src_str, extension, verbose = args
    return generate_one_reference(Path(test_src_str), extension, verbose)


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

    # Check prerequisites
    if not shutil.which("spike"):
        print("Error: spike not found in PATH. Install riscv-isa-sim first.")
        return 1
    if not shutil.which(f"{RISCV_PREFIX}gcc"):
        print(f"Error: {RISCV_PREFIX}gcc not found in PATH.")
        return 1

    # Single test mode
    if args.test:
        test_path = SUITE_DIR.parent / args.test
        if not test_path.exists():
            test_path = ARCH_TEST_DIR / "riscv-test-suite" / args.test
        if not test_path.exists():
            print(f"Error: Test not found: {args.test}")
            return 1
        parts = Path(args.test).parts
        ext = parts[1] if len(parts) > 1 else "unknown"
        name, status, msg = generate_one_reference(test_path, ext, args.verbose)
        print(f"{name:40s} {status}  {msg}")
        return 0 if status == "OK" else 1

    extensions = SUPPORTED_EXTENSIONS if args.all else args.extensions

    print(f"Generating references for: {', '.join(extensions)}")
    print(f"ISA: {FROST_ISA}")
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
        work_items = [(str(t), ext, args.verbose) for t in tests]

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
