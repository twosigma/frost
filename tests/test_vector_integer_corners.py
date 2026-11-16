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

"""Generate self-checking fixed-point/divide corner programs with Spike results.

The data explicitly includes min*min, min/-1, division by zero, rounding ties
and maximum shifts. Each form runs at e64,m1 and e8,mf8, with masked and
unmasked operations. Narrowing clips use e32,m1 with 64-bit sources because
128-bit source elements are outside ELEN. Expected register bytes and vxsat
come from the riscv-vector-tests patcher and merger, never a Python result
model. Run in the frost image; --rtl additionally executes the finished files.
"""

import argparse
import json
import os
import re
from pathlib import Path

import test_riscv_vector_tests as suite
from test_riscv_tests import check_pass_fail, run_simulation

FORMS = suite.REPO_ROOT / "hw/sim/vector_reference/integer_forms.json"
FIXED = re.compile(
    r"^v(aadd|aaddu|asub|asubu|sadd|saddu|ssub|ssubu|smul|ssrl|ssra|nclip|nclipu)\."
)
DIVIDE = re.compile(r"^v(div|divu|rem|remu)\.")


def source(form: str, vlen: int, fractional: bool) -> tuple[str, dict[str, object]]:
    """Emit operands and reference-recording points for one form and geometry."""
    narrow = form.startswith("vnclip")
    sew = 8 if fractional else (32 if narrow else 64)
    aw = sew * (2 if narrow else 1)
    lmul = "mf8" if fractional else "m1"
    aw_mask = (1 << aw) - 1
    mask = (1 << sew) - 1
    minimum = 1 << (aw - 1)
    pairs = [
        (minimum, 1 << (sew - 1)),
        (minimum, mask),
        (aw_mask, 0),
        (aw_mask, sew - 1),
        (3, 1),
        (1, 1),
        (0, 1),
        ((1 << (sew - 1)) - 1, 1),
        (0, mask),
        (minimum, 1),
        ((1 << sew) - 1, 1),
        ((1 << sew) + 1, 1),
    ]
    lines = [
        '#include "riscv_test.h"',
        '#include "test_macros.h"',
        "RVTEST_RV64UVX",
        "RVTEST_CODE_BEGIN",
        "vsetvli t0, x0, e8,m1,tu,mu",
    ]
    data = [".balign 64", "resultdata:", f".zero {vlen // 8}"]
    count = 0
    rounds = range(4) if FIXED.match(form) else range(1)
    for rounding in rounds:
        for masked in (False, True):
            for a, b in pairs:
                label = f"case_{count}"
                # Whole-register setup is independent of the tested LMUL/SEW.
                for reg, values, width, registers in (
                    (8, [a & aw_mask], aw, 2 if narrow and not fractional else 1),
                    (16, [b & mask], sew, 1),
                    (24, [0xA5], 8, 1),
                    (0, [0x55], 8, 1),
                ):
                    data += [".balign 64", f"{label}_{reg}:"]
                    raw = int(values[0]).to_bytes(width // 8, "little")
                    raw *= (registers * vlen // 8) // len(raw)
                    data.append(".byte " + ",".join(str(byte) for byte in raw))
                    lines += [
                        f"la a0, {label}_{reg}",
                        f"vl{registers}re8.v v{reg}, (a0)",
                    ]
                lines += [
                    f"csrwi vxrm, {rounding}",
                    "csrwi vxsat, 0",
                    f"vsetvli t0, x0, e{sew},{lmul},tu,mu",
                ]
                suffix = form.rsplit(".", 1)[1]
                if suffix.endswith("v"):
                    operand = "v16"
                elif suffix.endswith("x"):
                    lines.append(f"li a3, 0x{b & mask:x}")
                    operand = "a3"
                else:
                    immediate = b & 31
                    if not form.startswith(("vssr", "vnclip")) and immediate >= 16:
                        immediate -= 32
                    operand = str(immediate)
                lines += [
                    f"{form} v24, v8, {operand}" + (", v0.t" if masked else ""),
                    "la a0, resultdata",
                    "vs1r.v v24, (a0)",
                    # Patcher records one whole destination register plus vxsat.
                    ".word 0x003c000b",
                ]
                count += 1
    lines += [
        "TEST_PASSFAIL",
        "RVTEST_CODE_END",
        ".data",
        "RVTEST_DATA_BEGIN",
        *data,
        "RVTEST_DATA_END",
    ]
    return "\n".join(lines) + "\n", {
        "form": form,
        "sew": sew,
        "source_eew": aw,
        "lmul": lmul,
        "cases": count,
        "rounding_modes": list(rounds),
        "masked_and_unmasked": True,
        "operand_pairs": pairs,
    }


def prepare(work: Path, vlen: int) -> list[str]:
    """Record reference results and merge them into the corner programs."""
    work.mkdir(parents=True, exist_ok=True)
    for directory in suite.PIPELINE_DIRECTORIES:
        (work / directory).mkdir(exist_ok=True)
    names = []
    manifest = []
    for form in json.loads(FORMS.read_text()):
        if not (FIXED.match(form) or DIVIDE.match(form)):
            continue
        for fractional in (False, True):
            name = form.replace(".", "_") + ("_fractional" if fractional else "_wide")
            text, detail = source(form, vlen, fractional)
            (work / "stage1" / f"{name}.S").write_text(text)
            error = suite.build_and_patch(work, name, vlen)
            if error:
                raise RuntimeError(f"{name}: {error}")
            names.append(name)
            manifest.append({"name": name, **detail})
    suite.merge_stage2(work)
    (work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return names


def main() -> None:
    """Build the reference corpus and optionally run each complete RTL program."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vlen", type=int, choices=(128, 256, 512), default=256)
    parser.add_argument(
        "--work-dir", type=Path, default=Path(".pytest_cache/vector_corners")
    )
    parser.add_argument("--rtl", action="store_true")
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    work = args.work_dir.resolve()
    if args.resume:
        names = [
            row["name"] for row in json.loads((work / "manifest.json").read_text())
        ]
    else:
        names = prepare(work, args.vlen)
    print(f"Prepared {len(names)} complete programs at VLEN {args.vlen}", flush=True)
    if not args.rtl:
        return
    results = (
        json.loads((work / "results.json").read_text())
        if args.resume and (work / "results.json").exists()
        else []
    )
    assert [row["name"] for row in results] == names[: len(results)]
    for name in names[len(results) :]:
        error = suite.compile_for_frost(work / "stage2" / f"{name}.S", args.vlen)
        if error:
            raise RuntimeError(error)
        result = run_simulation(
            os.environ.get("SIM", "verilator"),
            max_cycles=suite.DEFAULT_RTL_MAX_CYCLES,
            coverage_label=f"vector_corner_{name}",
        )
        if result is None:
            raise RuntimeError(f"{name}: simulation timed out")
        (work / f"{name}.rtl.log").write_text(
            (result.stdout or "") + (result.stderr or "")
        )
        status, message = check_pass_fail(result)
        results.append({"name": name, "status": status, "message": message})
        (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"{len(results)}/{len(names)} {name}: {status} {message}", flush=True)
        if status != "PASS":
            raise RuntimeError(f"{name}: {message}")


if __name__ == "__main__":
    main()
