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

"""Adapt riscv-torture generated .S files for Frost.

Takes a raw riscv-torture output .S file and wraps it with:
  - frost_header.S at the top (startup, FPU init, data copy)
  - frost_footer.S at the bottom (register dump, UART signature, PASS marker)

The adapted file is a self-contained .S file that can be compiled directly.

Usage:
    ./adapt_test.py input.S output.S
    ./adapt_test.py --batch raw_dir/ adapted_dir/
"""

import argparse
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()


def adapt_test(input_path: Path, output_path: Path) -> bool:
    """Adapt a single riscv-torture test for Frost.

    The adapted file structure:
      1. #include "frost_header.S"   (provides _start, startup code)
      2. _torture_test_begin:        (label that frost_header jumps to)
      3. [original torture test code, with modifications]
      4. j _torture_test_end         (jump to footer)
      5. [original data sections]
      6. #include "frost_footer.S"   (register dump, signature, PASS)

    Modifications to the original code:
      - Remove any existing _start label (frost_header provides it)
      - Remove tohost/fromhost references
      - Replace `ecall` with `j _torture_test_end`
    """
    try:
        lines = input_path.read_text().splitlines()
    except OSError as e:
        print(f"Error reading {input_path}: {e}", file=sys.stderr)
        return False

    # Separate code and data sections
    code_lines = []
    data_lines = []
    in_data = False
    skip_tohost = False

    # riscv_test.h macros and includes to strip entirely
    strip_lines = {
        '#include "riscv_test.h"',
        '#include "test_macros.h"',
        "RVTEST_CODE_END",
        "RVTEST_DATA_BEGIN",
        "RVTEST_DATA_END",
        "TEST_DATA",
    }
    # Prefixes of riscv_test.h mode macros (RVTEST_RV64UF, RVTEST_RV32U, etc.)
    strip_prefixes = ("RVTEST_RV",)

    for line in lines:
        stripped = line.strip()

        # Skip blank lines at start
        if not code_lines and not data_lines and not stripped:
            continue

        # Strip riscv_test.h includes and macros
        if stripped in strip_lines:
            continue
        if any(stripped.startswith(p) for p in strip_prefixes):
            continue

        # Strip RVTEST_CODE_BEGIN (defines _start, conflicts with frost_header)
        if stripped == "RVTEST_CODE_BEGIN":
            continue

        # Detect data section
        if stripped.startswith(".data") or stripped.startswith(".section .data"):
            in_data = True

        # Skip tohost/fromhost declarations
        if "tohost" in stripped or "fromhost" in stripped:
            skip_tohost = True
            continue
        if skip_tohost and (stripped.startswith(".") or not stripped):
            if not stripped:
                skip_tohost = False
            continue
        skip_tohost = False

        # Remove existing _start label
        if stripped == "_start:" or stripped == ".globl _start":
            continue

        if in_data:
            data_lines.append(line)
        else:
            # Replace ecall/RVTEST_FAIL/RVTEST_PASS with jump to footer
            if stripped == "ecall":
                code_lines.append("    j _torture_test_end")
            elif stripped == "RVTEST_FAIL":
                code_lines.append("    j _torture_test_end")
            elif stripped == "RVTEST_PASS":
                code_lines.append("    j _torture_test_end")
            else:
                code_lines.append(line)

    # Build adapted file
    adapted = []
    adapted.append("// Adapted riscv-torture test for Frost")
    adapted.append(f"// Original: {input_path.name}")
    adapted.append("")
    adapted.append('#include "frost_header.S"')
    adapted.append("")
    adapted.append("    .globl _torture_test_begin")
    adapted.append("_torture_test_begin:")
    adapted.append("")
    adapted.extend(code_lines)
    adapted.append("")
    adapted.append("    // End of torture test — jump to register dump")
    adapted.append("    j _torture_test_end")
    adapted.append("")

    if data_lines:
        adapted.extend(data_lines)
        adapted.append("")

    adapted.append('#include "frost_footer.S"')
    adapted.append("")

    try:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text("\n".join(adapted))
    except OSError as e:
        print(f"Error writing {output_path}: {e}", file=sys.stderr)
        return False

    return True


def main() -> int:
    """Adapt riscv-torture tests for Frost."""
    parser = argparse.ArgumentParser(
        description="Adapt riscv-torture tests for Frost",
    )
    parser.add_argument(
        "input",
        help="Input .S file or directory (with --batch)",
    )
    parser.add_argument(
        "output",
        help="Output .S file or directory (with --batch)",
    )
    parser.add_argument(
        "--batch",
        action="store_true",
        help="Process all .S files in input directory",
    )

    args = parser.parse_args()
    input_path = Path(args.input)
    output_path = Path(args.output)

    if args.batch:
        if not input_path.is_dir():
            print(f"Error: {input_path} is not a directory", file=sys.stderr)
            return 1

        output_path.mkdir(parents=True, exist_ok=True)
        test_files = sorted(input_path.glob("*.S"))
        if not test_files:
            print(f"No .S files found in {input_path}")
            return 1

        n_ok = 0
        n_err = 0
        for test_file in test_files:
            out_file = output_path / test_file.name
            if adapt_test(test_file, out_file):
                n_ok += 1
            else:
                n_err += 1
                print(f"  Failed: {test_file.name}")

        print(f"Adapted {n_ok} tests ({n_err} errors)")
        return 1 if n_err > 0 else 0

    else:
        if not input_path.is_file():
            print(f"Error: {input_path} does not exist", file=sys.stderr)
            return 1

        if adapt_test(input_path, output_path):
            print(f"Adapted: {input_path} -> {output_path}")
            return 0
        return 1


if __name__ == "__main__":
    sys.exit(main())
