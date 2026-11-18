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

"""Compare vector arithmetic legality with Spike across registers and every vtype.

Run in the frost image with ``python3 tests/test_vector_legality_reference.py``
(``--forms fp`` for the floating-point forms, which run with Zfh and Zvfh).
The comparison calls the installed reference instruction implementations and
the RTL decoder and dispatch legality module (vec_arith_legality). It does not
copy the reference's formulas.
VL is one and vstart zero; this sweep checks geometry, not restart policy.
Spike omits the general source/source EEW reservation, so the comparator
checks that specification rule separately and reports its cases separately.
All other accepted/rejected results come from Spike's instruction functions.
"""

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "hw" / "sim" / "vector_reference"
HEADERS = Path("/usr/local/include/riscv")


# Each form list and the extensions the reference needs for it.
FORM_SETS = {
    "integer": ("integer_forms.json", "_zvbb"),
    "fp": ("fp_forms.json", "_zfh_zvfh"),
}


def build(build_dir: Path, form_set: str = "integer") -> Path:
    """Build the RTL comparator and link the installed reference library."""
    build_dir.mkdir(parents=True, exist_ok=True)
    form_file, extensions = FORM_SETS[form_set]
    forms = json.loads((SOURCE / form_file).read_text())
    declarations = [
        "#include <riscv/encoding.h>",
        f'static const char isa_extensions[] = "{extensions}";',
    ]
    entries = []
    for form in forms:
        # The two greater-than vector/vector spellings are assembler aliases
        # of less-than with exchanged sources, not distinct instruction bits.
        canonical = {"vmsgt.vv": "vmslt.vv", "vmsgtu.vv": "vmsltu.vv"}.get(form, form)
        name = canonical.replace(".", "_")
        symbol = "fast_rv64i_" + name
        declarations.append(f"extern reg_t {symbol}(processor_t *, insn_t, reg_t);")
        entries.append(
            f'{{"{form}", MATCH_{name.upper()}, MASK_{name.upper()}, {symbol}}}'
        )
    (build_dir / "forms.h").write_text(
        "\n".join(declarations)
        + "\nstruct Form { const char *name; uint32_t match, mask; insn_func_t execute; };\n"
        + "const Form forms[] = {\n"
        + ",\n".join(entries)
        + "\n};\n"
    )
    command = [
        "verilator",
        "--cc",
        "--exe",
        "--build",
        "-j",
        str(min(16, int(os.environ.get("NUMBER_OF_CPU_CORES", "4")))),
        "-Wno-fatal",
        "--top-module",
        "vec_legality_reference",
        "--Mdir",
        str(build_dir / "obj"),
        "-CFLAGS",
        f"-std=c++17 -I{build_dir} -I/usr/local/include",
        "-LDFLAGS",
        "-L/usr/local/lib -Wl,-rpath,/usr/local/lib -lriscv",
        str(ROOT / "hw/rtl/cpu_and_mem/cpu/riscv_pkg.sv"),
        str(ROOT / "hw/rtl/cpu_and_mem/cpu/id_stage/instr_decoder.sv"),
        str(ROOT / "hw/rtl/cpu_and_mem/cpu/vector/vec_arith_legality.sv"),
        str(SOURCE / "vec_legality_reference.sv"),
        str(SOURCE / "legality.cpp"),
    ]
    with (build_dir / "build.log").open("w") as log:
        result = subprocess.run(
            command, stdout=log, stderr=subprocess.STDOUT, timeout=600, check=False
        )
    assert result.returncode == 0, f"comparator build failed: {build_dir / 'build.log'}"
    return build_dir / "obj" / "Vvec_legality_reference"


def compare(binary: Path, vlen: int, output: Path, *, negative: bool = False) -> None:
    """Run a bounded sweep and require the expected comparison outcome."""
    command = [str(binary), str(vlen)] + (["negative"] if negative else [])
    with output.open("w") as log:
        result = subprocess.run(
            command, stdout=log, stderr=subprocess.STDOUT, timeout=1200, check=False
        )
    text = output.read_text()
    if negative:
        assert result.returncode == 1 and "MISMATCH" in text
    else:
        assert result.returncode == 0 and "TOTAL " in text and "mismatches=0" in text, (
            f"legality comparison failed: {output}"
        )


@pytest.mark.slow
@pytest.mark.skipif(
    not HEADERS.is_dir() or shutil.which("verilator") is None,
    reason="needs the frost image's reference headers and Verilator",
)
def test_integer_legality_reference(tmp_path: Path) -> None:
    """Compare every integer form at all supported vector lengths."""
    binary = build(tmp_path)
    for vlen in (128, 256, 512):
        compare(binary, vlen, tmp_path / f"legality_{vlen}.log")
    compare(binary, 128, tmp_path / "negative.log", negative=True)


@pytest.mark.slow
@pytest.mark.skipif(
    not HEADERS.is_dir() or shutil.which("verilator") is None,
    reason="needs the frost image's reference headers and Verilator",
)
def test_fp_legality_reference(tmp_path: Path) -> None:
    """Compare every floating-point form at all supported vector lengths."""
    binary = build(tmp_path, "fp")
    for vlen in (128, 256, 512):
        compare(binary, vlen, tmp_path / f"legality_fp_{vlen}.log")
    compare(binary, 128, tmp_path / "negative_fp.log", negative=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vlen", type=int, choices=(128, 256, 512), default=256)
    parser.add_argument(
        "--build-dir", type=Path, default=Path(".pytest_cache/vector_legality")
    )
    parser.add_argument("--negative-control", action="store_true")
    parser.add_argument("--forms", choices=sorted(FORM_SETS), default="integer")
    args = parser.parse_args()
    build_path = args.build_dir.resolve() / args.forms
    executable = build(build_path, args.forms)
    compare(
        executable,
        args.vlen,
        build_path / f"legality_{args.vlen}.log",
        negative=args.negative_control,
    )
