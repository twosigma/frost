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

The suite's Go generator splits each instruction form into assembly programs.
Spike then runs each test once to record the expected results,
the merger folds them into the test, and the finished test checks itself. The
image carries the generator, merger and patcher in /opt/riscv-vector-tests
(override with RISCV_VECTOR_TESTS_DIR). Run in the frost image from the
repository root:

    ./scripts/frost.py run python3 tests/test_riscv_vector_tests.py --pattern '^vadd\.vv$'
    ./scripts/frost.py run python3 tests/test_riscv_vector_tests.py --vlen 256 --shard 1/20
    ./scripts/frost.py run python3 tests/test_riscv_vector_tests.py --list

Without --rtl the finished tests run on Spike. With --rtl the runner builds
FROST DDR images and a vector core at the selected VLEN. Cocotb is the
default. The native C++ harness can run several processes sharing one model:

    ./scripts/frost.py run python3 tests/test_riscv_vector_tests.py --rtl \
        --simulator native --rtl-jobs 2 --vlen 128 --class float --shard 1/20

The pytest entry points run a small Spike sample, which guards the generator
and this wiring. The simulation entry points are skipped unless
FROST_RVV_TESTS_RTL=1 is set.
"""

import argparse
import hashlib
import heapq
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
import zlib
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import nullcontext
from pathlib import Path

import pytest

import rvv_simulator
from rvv_simulator import IMAGE_FILES, VectorSimulator, VectorTestResult, image_hash

TESTS_DIR = Path(__file__).parent.resolve()
REPO_ROOT = TESTS_DIR.parent
RISCV_TESTS_APP_DIR = REPO_ROOT / "sw" / "apps" / "riscv_tests"

SUITE_DIR = Path(
    os.environ.get("RISCV_VECTOR_TESTS_DIR", "/opt/riscv-vector-tests")
).resolve()
RISCV_PREFIX = os.environ.get("RISCV_PREFIX", "riscv64-linux-")

SUPPORTED_VLENS = (128, 256, 512)
DEFAULT_VLEN = 128

# Spike also exercises the upstream configurations outside the core's ISA.
RTL_MARCH = "rv64gcv_zvbb_zvbc_zfh_zvfh_zvkg_zvkned_zvknha"
MARCH = RTL_MARCH + "_zvksed_zvksh_zfbfmin_zvfbfmin_zvfbfwma"
DEFAULT_DDR_BYTES = 8 * 1024 * 1024
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

# Instruction forms selected for the RTL smoke sample: integer arithmetic
# and compare plus unit-stride, whole-register and mask memory operations.
RTL_SAMPLE_PATTERN = r"^(vadd\.vv|vmseq\.vv|vle8\.v|vle32\.v|vse16\.v|vse64\.v|vl2re8\.v|vs2r\.v|vlm\.v|vsm\.v)$"


# Subdirectories of the work directory that one run fills.
PIPELINE_DIRECTORIES = ("stage1", "stage2", "patch", "bin1", "bin2", "images")


def suite_available() -> bool:
    """Return whether the image carries the generator, merger and patcher."""
    return all(
        (SUITE_DIR / "build" / tool).is_file()
        for tool in ("generator", "merger", "pspike")
    )


def varch(vlen: int) -> str:
    """Return the Spike ISA suffix for a hardware vector length."""
    return f"zvl{vlen}b_zve64d_zfh_zfhmin_zvfh"


def spike_isa(vlen: int, march: str = MARCH) -> str:
    """Return the Spike ISA string for a hardware vector length."""
    return f"{march}_{varch(vlen)}"


def parse_makefrag(text: str) -> list[str]:
    """Return the test names from the generator's Makefrag."""
    names = []
    for line in text.splitlines()[1:]:
        name = line.strip().rstrip("\\").strip()
        if name:
            names.append(name)
    if len(set(names)) != len(names):
        raise ValueError("duplicate test name in generator Makefrag")
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


# Instruction classes for sharding by kind. A test belongs to the first class
# whose rule matches its mnemonic; "integer" takes the rest.
INSTRUCTION_CLASSES = (
    "load-store",
    "crypto",
    "bitmanip",
    "float",
    "mask-permute-reduce",
    "integer",
)
_CRYPTO = re.compile(r"v(aes|sha2|sm3|sm4|ghsh|gmul)")
_BITMANIP = re.compile(r"v(andn|brev8?|rev8|clz|ctz|cpop_v|rol|ror|wsll|clmulh?)(_|$)")
_LOAD_STORE = re.compile(r"v[ls][a-z0-9]*_v")
_MASK_PERMUTE_REDUCE = re.compile(
    r"v(m(and|nand|andn|or|nor|orn|xor|xnor)_mm|m(sbf|sif|sof)_m|iota|id_v|cpop_m|first"
    r"|w?red|slide|rgather|compress|mv[1248]r|mv_[sx]_[sx]|fmv_[fs]_[sf]|fslide)"
)


def instruction_class(test_name: str) -> str:
    """Return the class of a generated test, such as vadd_vv-0 or vle8_v-3.

    >>> [instruction_class(n) for n in ("vle8_v-0", "vfadd_vv-1", "vadd_vv-0")]
    ['load-store', 'float', 'integer']
    """
    mnemonic = test_name.rsplit("-", 1)[0]
    if _CRYPTO.match(mnemonic):
        return "crypto"
    if _BITMANIP.match(mnemonic):
        return "bitmanip"
    if mnemonic.startswith("vfirst") or _MASK_PERMUTE_REDUCE.match(mnemonic):
        return "mask-permute-reduce"
    if mnemonic.startswith(("vf", "vmf")):
        return "float"
    if _LOAD_STORE.fullmatch(mnemonic):
        return "load-store"
    return "integer"


def one_per_form(names: list[str], vlen: int) -> list[str]:
    """Spread selections across the LMUL-ordered splits and rotate by VLEN."""
    forms: dict[str, list[int]] = defaultdict(list)
    for name in names:
        form, split = name.rsplit("-", 1)
        forms[form].append(int(split))
    selected = []
    for form, splits in sorted(forms.items()):
        count = len(splits)
        offset = zlib.crc32(form.encode()) + SUPPORTED_VLENS.index(vlen) * count // 3
        selected.append(f"{form}-{sorted(splits)[offset % count]}")
    return selected


def cycle_weight(source: Path, vlen: int) -> int:
    """Estimate work from the setup code and whole-register checks in a split."""
    code = source.read_bytes().split(b"RVTEST_CODE_END", 1)[0]
    checks = 0
    for word in re.findall(rb"^\s*\.word 0x([0-9a-fA-F]+)", code, re.M):
        insn = int(word, 16)
        if insn & 127 == 0x0B:
            checks += (insn >> 21 & 15) * (vlen // 64) + (insn >> 20 & 1)
    return code.count(b"\n") + 12 * checks


def shard_weights(
    stage1: Path, names: list[str], vlen: int, profile: bytes
) -> dict[str, int]:
    """Use matching measured cycles and scale estimates for the unmeasured splits."""
    weights = {name: cycle_weight(stage1 / f"{name}.S", vlen) for name in names}
    measured = {}
    for line in profile.splitlines():
        row = json.loads(line)
        name = row["name"]
        if row["vlen"] == vlen and name in weights and row["verdict"] == "PASS":
            cycles = row["cycles"]
            if type(cycles) is not int or cycles <= 0 or name in measured:
                raise ValueError(
                    f"cycle profile: invalid or duplicate cycle count for {name}"
                )
            measured[name] = cycles
    if measured:
        total = sum(measured.values())
        estimate = sum(weights[name] for name in measured)
        for name, weight in weights.items():
            weights[name] = measured.get(name, max(1, weight * total // estimate))
    return weights


def selection_sha256(names: list[str], vlen: int) -> str:
    """Identify the complete selection before partitioning it among shards."""
    selection = json.dumps([vlen, sorted(names)], separators=(",", ":"))
    return hashlib.sha256(selection.encode()).hexdigest()


def select_shard(weights: dict[str, int], index: int, count: int) -> list[str]:
    """Assign the heaviest remaining test to the shard with the least work."""
    loads = [(0, k) for k in range(min(count, len(weights)))]
    selected = []
    for name in sorted(weights, key=lambda n: (-weights[n], n)):
        total, k = loads[0]
        if k == index - 1:
            selected.append(name)
        heapq.heapreplace(loads, (total + weights[name], k))
    return sorted(selected)


def run_tool(
    command: list[str], cwd: Path | None = None, timeout: int = 600
) -> subprocess.CompletedProcess[str]:
    """Run a command, capturing text output."""
    try:
        return subprocess.run(
            command,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return subprocess.CompletedProcess(command, 1, "", str(exc))


def add_conversion_cases(source: Path, configs: list[Path]) -> None:
    """Exercise both conversion configs' raw operands at their source widths."""
    # The pinned generator reads fsew* for FP operands. These TOMLs encode
    # bit patterns in sew* (including distinct NaN payloads).
    code: list[str] = []
    for config in configs:
        with config.open("rb") as stream:
            form = tomllib.load(stream)
        for key, cases in form["tests"].items():
            width = int(key.removeprefix("sew"))
            sew = width // 2 if form["name"] == "vfncvt.f.f.w" else width
            for (operand,) in cases:
                bits = int(operand, 0) if isinstance(operand, str) else operand
                code.extend(
                    (
                        f"vsetivli zero, 1, e{width},m1,tu,mu",
                        f"li t0, {bits:#x}",
                        "vmv.s.x v16, t0",
                        f"vsetivli zero, 1, e{sew},m1,tu,mu",
                        f"{form['name']} v8, v16",
                        "la a0, resultdata",
                        "vs1r.v v8, (a0)",
                        ".word 0x24000b",  # pspike records v8 (one register).
                    )
                )
    text = source.read_text()
    marker = "  TEST_CASE(2, x0, 0x0)"
    if text.count(marker) != 1:
        raise ValueError(f"{source}: missing generator check placeholder")
    source.write_text(text.replace(marker, "\n".join([*code, marker])))


def generate_form(
    stage1: Path, configs: list[Path], vlen: int, march: str, pattern: str = ".*"
) -> list[str]:
    """Give each instruction its own generator process and TestFloat state."""
    config = configs[0]
    if len(configs) > 1 and (
        config.stem not in {"vfncvt.f.f.w", "vfwcvt.f.f.v"}
        or {p.name for p in configs} != {config.name}
        or {p.parent.name for p in configs} != {"v", "zvfhmin"}
    ):
        raise ValueError(f"conflicting generator configs: {configs}")
    with tempfile.TemporaryDirectory(dir=stage1.parent) as scratch:
        temp = Path(scratch)
        config_dir = temp / "configs" / config.parent.name
        config_dir.mkdir(parents=True)
        (config_dir / config.name).symlink_to(config)
        result = run_tool(
            [
                str(SUITE_DIR / "build" / "generator"),
                "-VLEN",
                str(vlen),
                "-XLEN=64",
                "-split=10000",
                "-integer=0",
                f"-pattern={pattern}",
                "-testfloat3level=2",
                "-repeat=1",
                "-stage1output",
                str(stage1),
                "-configs",
                str(config_dir.parent),
                "-march",
                march,
            ],
            cwd=temp,
            timeout=1800,
        )
        if result.returncode:
            raise RuntimeError(
                f"{config.name}: generator failed:\n{result.stdout}{result.stderr}"
            )
        names = parse_makefrag((temp / "Makefrag").read_text())
    if names and len(configs) > 1:
        add_conversion_cases(stage1 / f"{config.stem.replace('.', '_')}-0.S", configs)
    return names


def generate_tests(
    workdir: Path,
    vlen: int,
    pattern: str,
    shard: tuple[int, int] | None = None,
    instruction_kind: str | None = None,
    *,
    rtl: bool = False,
    one: bool = False,
    jobs: int = 4,
    cycle_profile: Path | None = None,
) -> list[str]:
    """Generate one set of splits per matching form and retain the selection."""
    workdir = workdir.resolve()
    for stale in PIPELINE_DIRECTORIES:
        shutil.rmtree(workdir / stale, ignore_errors=True)
    (workdir / "Makefrag").unlink(missing_ok=True)
    stage1 = workdir / "stage1"
    stage1.mkdir(parents=True, exist_ok=True)
    march = RTL_MARCH if rtl else MARCH
    extensions = {"v", "zvfhmin", *march.split("_")[1:]}
    forms: dict[str, list[Path]] = defaultdict(list)
    for config in sorted((SUITE_DIR / "configs").glob("*/*.toml")):
        if config.parent.name not in extensions:
            continue
        if (
            instruction_kind
            and instruction_class(config.stem.replace(".", "_")) != instruction_kind
        ):
            continue
        forms[config.stem.replace(".", "_")].append(config)
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        groups = pool.map(
            lambda cs: generate_form(stage1, cs, vlen, march, pattern), forms.values()
        )
        names = sorted(n for group in groups for n in group)
    if len(set(names)) != len(names):
        raise ValueError("duplicate generated test name")
    selected = one_per_form(names, vlen) if one else names
    profile = cycle_profile.read_bytes() if cycle_profile is not None else b""
    identity = {
        "selection_sha256": selection_sha256(selected, vlen),
        "profile_sha256": hashlib.sha256(profile).hexdigest(),
    }
    if shard:
        weights = shard_weights(stage1, selected, vlen, profile)
        selected = select_shard(weights, *shard)
    for name in set(names) - set(selected):
        (stage1 / f"{name}.S").unlink()
    continuation = " \\\n"
    (workdir / "Makefrag").write_text(
        "tests ="
        + continuation
        + "".join(f"  {name}{continuation}" for name in selected)
    )
    (workdir / "selection.json").write_text(json.dumps(identity, indent=2) + "\n")
    return sorted(selected)


def suite_include_args() -> list[str]:
    """Include path of the suite's own physical test environment and macros."""
    return [
        f"-I{SUITE_DIR / 'env' / 'riscv-test-env' / 'p'}",
        f"-I{SUITE_DIR / 'macros' / 'general'}",
    ]


def build_and_patch(workdir: Path, name: str, vlen: int, march: str = MARCH) -> str:
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
            f"-march={march}",
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
        [
            str(SUITE_DIR / "build" / "pspike"),
            f"--isa={spike_isa(vlen, march)}",
            str(elf),
        ],
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
    workdir: Path,
    vlen: int,
    pattern: str,
    shard: tuple[int, int] | None,
    jobs: int,
    instruction_kind: str | None = None,
    *,
    one: bool = False,
    rtl: bool = False,
    cycle_profile: Path | None = None,
) -> tuple[list[str], list[VectorTestResult]]:
    """Generate, patch and merge; return the test names and any failures."""
    workdir = workdir.resolve()
    names = generate_tests(
        workdir,
        vlen,
        pattern,
        shard,
        instruction_kind,
        rtl=rtl,
        one=one,
        jobs=jobs,
        cycle_profile=cycle_profile,
    )
    failures: list[VectorTestResult] = []
    march = RTL_MARCH if rtl else MARCH
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        errors = list(
            pool.map(lambda n: build_and_patch(workdir, n, vlen, march), names)
        )
    good = []
    for name, error in zip(names, errors, strict=True):
        if error:
            failures.append(VectorTestResult(name, False, error))
            (workdir / "stage1" / f"{name}.S").unlink()
        else:
            good.append(name)
    if good:
        try:
            merge_stage2(workdir)
        except RuntimeError as exc:
            return [], failures + [VectorTestResult(n, False, str(exc)) for n in good]
    return good, failures


def run_spike_tests(
    workdir: Path,
    vlen: int,
    pattern: str,
    shard: tuple[int, int] | None = None,
    jobs: int = 4,
    instruction_kind: str | None = None,
    *,
    one: bool = False,
    cycle_profile: Path | None = None,
) -> list[VectorTestResult]:
    """Generate the selected tests and run each on Spike as the self-check."""
    workdir = workdir.resolve()
    names, results = prepare(
        workdir,
        vlen,
        pattern,
        shard,
        jobs,
        instruction_kind,
        one=one,
        cycle_profile=cycle_profile,
    )
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        results += list(pool.map(lambda n: run_on_spike(workdir, n, vlen), names))
    return results


def compile_for_frost(
    source: Path,
    vlen: int,
    output: Path = RISCV_TESTS_APP_DIR,
    ddr_bytes: int | None = None,
) -> str:
    """Build the three memory images and check all DDR allocations at link time."""
    output.mkdir(parents=True, exist_ok=True)
    flags = list(GCC_TEST_OPTIONS)
    if ddr_bytes is not None:
        flags.append(f"-Wl,--defsym=__frost_ddr_bytes={ddr_bytes}")
    result = run_tool(
        [
            "make",
            "-B",
            "images",
            f"TEST_SRC={source.resolve()}",
            "MEM_CONFIG=ddr",
            "ENV=p",
            f"ARCH={RTL_MARCH}",
            f"OUTPUT_DIR={output.resolve()}",
            f"EXTRA_INCLUDES=-I{SUITE_DIR / 'macros' / 'general'}",
            f"TEST_CFLAGS={' '.join(flags)}",
        ],
        cwd=RISCV_TESTS_APP_DIR,
        timeout=300,
    )
    if result.returncode:
        limit = f" ({ddr_bytes} DDR bytes)" if ddr_bytes is not None else ""
        return f"image build failed{limit}: {result.stderr.strip()[-1500:]}"
    return ""


def result_record(
    result: VectorTestResult, simulator: str, vlen: int, identity: dict[str, str]
) -> dict[str, object]:
    """Describe one selected program, including failures before simulation."""
    return {
        "name": result.name,
        "class": instruction_class(result.name),
        "vlen": vlen,
        "simulator": simulator,
        "image_sha256": result.image_sha256,
        "verdict": "PASS" if result.passed else "FAIL",
        "cycles": result.cycles,
        "wall_seconds": result.wall_seconds,
        "assertions_armed": result.assertions_armed,
        "message": result.message,
        "selection_sha256": identity["selection_sha256"],
        "profile_sha256": identity["profile_sha256"],
    }


def merge_results(inputs: list[Path], output: Path) -> int:
    """Verify the union of shards before publishing their complete result set."""
    if output.resolve() in {path.resolve() for path in inputs}:
        raise ValueError("use a separate output file for the merged results")
    rows = {}
    identity = None
    for path in inputs:
        with path.open() as stream:
            for number, line in enumerate(stream, 1):
                row = json.loads(line)
                if not isinstance(row, dict):
                    raise ValueError(f"{path}:{number}: expected a result object")
                width = row.get("vlen")
                backend = row.get("simulator")
                selection = row.get("selection_sha256")
                profile = row.get("profile_sha256")
                if (
                    type(width) is not int
                    or width not in SUPPORTED_VLENS
                    or backend not in ("native", "verilator")
                    or not all(
                        isinstance(h, str) and re.fullmatch("[0-9a-f]{64}", h)
                        for h in (selection, profile)
                    )
                ):
                    raise ValueError(
                        f"{path}:{number}: missing or invalid result identity"
                    )
                current = (width, backend, selection, profile)
                if identity is not None and current != identity:
                    raise ValueError(
                        f"{path}:{number}: VLEN, simulator, selection or cycle profile differs"
                    )
                identity = current
                name = row.get("name")
                if (
                    not isinstance(name, str)
                    or not name
                    or row.get("verdict") not in ("PASS", "FAIL")
                ):
                    raise ValueError(f"{path}:{number}: invalid name or verdict")
                if name in rows:
                    raise ValueError(f"{path}:{number}: duplicate test {name}")
                rows[name] = row
            if stream.tell() == 0:
                raise ValueError(f"{path}: empty results")
    if identity is None or selection_sha256(list(rows), identity[0]) != identity[2]:
        raise ValueError("result names do not cover the complete selection")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as directory:
        temp = Path(directory) / "results.jsonl"
        with temp.open("w") as stream_out:
            for name in sorted(rows):
                print(json.dumps(rows[name]), file=stream_out)
        temp.replace(output)
    failures = sum(row["verdict"] == "FAIL" for row in rows.values())
    print(f"Merged {len(rows)} results, {failures} failed")
    return int(bool(failures))


def run_rtl_tests(
    workdir: Path,
    vlen: int,
    pattern: str,
    shard: tuple[int, int] | None = None,
    max_cycles: str = DEFAULT_RTL_MAX_CYCLES,
    jobs: int = 4,
    instruction_kind: str | None = None,
    *,
    simulator: str = "verilator",
    rtl_jobs: int = 1,
    sim_threads: int = 1,
    prebuilt_sim: Path | None = None,
    ddr_bytes: int = DEFAULT_DDR_BYTES,
    one: bool = False,
    results_jsonl: Path | None = None,
    cycle_profile: Path | None = None,
) -> list[VectorTestResult]:
    """Prepare isolated images, build the model once and run independent processes."""
    workdir = workdir.resolve()
    results: list[VectorTestResult] = []
    images = workdir / "images"
    if results_jsonl:
        results_jsonl.unlink(missing_ok=True)
    model = VectorSimulator(simulator, vlen, ddr_bytes, int(max_cycles))
    if prebuilt_sim:
        model.use_native(prebuilt_sim)
    names, failures = prepare(
        workdir,
        vlen,
        pattern,
        shard,
        jobs,
        instruction_kind,
        rtl=True,
        one=one,
        cycle_profile=cycle_profile,
    )
    if results_jsonl:
        results_jsonl.parent.mkdir(parents=True, exist_ok=True)
    identity = json.loads((workdir / "selection.json").read_text())
    with (
        results_jsonl.open("w", buffering=1)
        if results_jsonl
        else nullcontext() as stream
    ):

        def record(result: VectorTestResult) -> None:
            results.append(result)
            if stream:
                print(
                    json.dumps(result_record(result, simulator, vlen, identity)),
                    file=stream,
                )

        for failure in failures:
            record(failure)
        ready = []
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            builds = {
                pool.submit(
                    compile_for_frost,
                    workdir / "stage2" / f"{name}.S",
                    vlen,
                    images / name,
                    ddr_bytes,
                ): name
                for name in names
            }
            for task in as_completed(builds):
                name = builds[task]
                error = task.result()
                if error:
                    record(VectorTestResult(name, False, error))
                else:
                    ready.append(name)
        if ready and not prebuilt_sim:
            try:
                model.build(workdir / f"{simulator}-v{vlen}", sim_threads)
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
                for name in ready:
                    record(
                        VectorTestResult(
                            name,
                            False,
                            str(exc),
                            image_sha256=image_hash(images / name),
                        )
                    )
                return results
        with ThreadPoolExecutor(max_workers=rtl_jobs) as pool:
            runs = {
                pool.submit(model.run, images / name): name for name in sorted(ready)
            }
            for simulation in as_completed(runs):
                try:
                    result = simulation.result()
                except (OSError, ValueError, KeyError) as exc:
                    result = VectorTestResult(runs[simulation], False, str(exc))
                record(result)
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

    def test_duplicate_makefrag_rejected(self) -> None:
        """A duplicate entry must fail the run even if the assembly file exists."""
        with pytest.raises(ValueError, match="duplicate"):
            parse_makefrag("tests =\n a-0\n a-0\n")

    def test_shards_partition_the_tests(self) -> None:
        """Every test lands in exactly one shard."""
        names = {f"t{i}": i + 1 for i in range(23)}
        shards = [select_shard(names, k, 5) for k in range(1, 6)]
        assert sorted(sum(shards, [])) == sorted(names)
        assert select_shard(names, 10**9, 10**9) == []

    def test_bad_shard_rejected(self) -> None:
        """K must lie in 1..N."""
        with pytest.raises(argparse.ArgumentTypeError):
            parse_shard("0/4")
        with pytest.raises(argparse.ArgumentTypeError):
            parse_shard("5/4")


@needs_suite
@pytest.mark.slow
@pytest.mark.parametrize("vlen", SUPPORTED_VLENS)
def test_complete_rtl_inventory(tmp_path: Path, vlen: int) -> None:
    """Pin the upstream split count in each class and reject repeated names."""
    names = generate_tests(tmp_path, vlen, ".*", rtl=True)
    assert len(names) == len(set(names)) == 3017
    assert Counter(map(instruction_class, names)) == {
        "float": 1243,
        "integer": 1043,
        "load-store": 487,
        "mask-permute-reduce": 163,
        "bitmanip": 63,
        "crypto": 18,
    }
    assert len(one_per_form(names, vlen)) == 665


@needs_suite
@pytest.mark.parametrize("vlen", SUPPORTED_VLENS)
def test_conversion_operands(tmp_path: Path, vlen: int) -> None:
    """Both operand widths and all three raw patterns per config reach Spike."""
    names, failures = prepare(
        tmp_path, vlen, r"^vf(ncvt\.f\.f\.w|wcvt\.f\.f\.v)$", None, 2, rtl=True
    )
    assert not failures
    assert len(names) == len(set(names)) == 8
    for name, widths in (("vfncvt_f_f_w-0", (32, 64)), ("vfwcvt_f_f_v-0", (16, 32))):
        # The unmodified configs generate identical TestFloat data for every
        # split. Preserve that data in addition to the explicit raw operands.
        stem = name.removesuffix("-0")
        splits = [n for n in names if n.startswith(stem + "-")]
        for extension in ("v", "zvfhmin"):
            config = (
                SUITE_DIR / "configs" / extension / f"{stem.replace('_', '.')}.toml"
            )
            assert (
                sorted(generate_form(tmp_path / extension, [config], vlen, RTL_MARCH))
                == splits
            )
        for split in splits:
            expected = (tmp_path / "v" / f"{split}.S").read_text()
            assert (tmp_path / "zvfhmin" / f"{split}.S").read_text() == expected
            combined = (tmp_path / "stage1" / f"{split}.S").read_text()
            prefix, marker, suffix = expected.partition("  TEST_CASE(2, x0, 0x0)")
            assert (
                marker
                and combined.startswith(prefix)
                and combined.endswith(marker + suffix)
            )
        source = (tmp_path / "stage2" / f"{name}.S").read_text()
        for width in widths:
            for operand in ((1 << width) - 1, (1 << width) - 2, 2):
                assert (
                    f"vsetivli zero, 1, e{width},m1,tu,mu\nli t0, {operand:#x}\n"
                    in source
                )
        assert source.count("vs1r.v v8, (a0)") == 6
        assert ".word 0x24000b" not in source
        result = run_on_spike(tmp_path, name, vlen)
        assert result.passed, result.message


@needs_suite
def test_frost_image_equivalence_and_bounds(tmp_path: Path) -> None:
    """Match the default app images and reject an allocation beyond modeled DDR."""
    if not (RISCV_TESTS_APP_DIR / "riscv-tests/env/encoding.h").is_file():
        pytest.skip("the FROST image build needs the riscv-tests environment submodule")
    names, failures = prepare(tmp_path, 128, r"^vadd\.vv$", None, 1, one=True, rtl=True)
    assert len(names) == 1 and not failures
    source = tmp_path / "stage2" / f"{names[0]}.S"
    reference = tmp_path / "reference"
    reference.mkdir()
    # Run the ordinary all target in a private copy of the app's build layout.
    app = reference / "sw/apps/riscv_tests"
    app.mkdir(parents=True)
    for item in RISCV_TESTS_APP_DIR.iterdir():
        if item.name in {
            "Makefile",
            "riscv-tests",
            "riscv_test.h",
            "crt0_riscv_tests_ddr.S",
            "link_riscv_tests_ddr.ld",
        }:
            (app / item.name).symlink_to(item)
    (reference / "sw/common").symlink_to(REPO_ROOT / "sw/common")
    build = run_tool(
        [
            "make",
            "all",
            "MEM_CONFIG=ddr",
            "ENV=p",
            f"TEST_SRC={source}",
            f"ARCH={RTL_MARCH}",
            f"EXTRA_INCLUDES=-I{SUITE_DIR / 'macros/general'}",
            f"TEST_CFLAGS={' '.join(GCC_TEST_OPTIONS)}",
        ],
        cwd=app,
    )
    assert build.returncode == 0, build.stderr
    image = tmp_path / "image"
    assert not compile_for_frost(source, 128, image, DEFAULT_DDR_BYTES)
    for filename in IMAGE_FILES:
        assert (image / filename).read_bytes() == (app / filename).read_bytes()
    assert not (image / "sw.S").exists()
    symbols = run_tool([f"{RISCV_PREFIX}nm", "--defined-only", str(image / "sw.elf")])
    end = re.search(r"^([0-9a-fA-F]+) \w _heap_end$", symbols.stdout, re.M)
    assert end, symbols.stderr
    footprint = int(end[1], 16) - 0x80000000
    assert not compile_for_frost(source, 128, image, footprint)
    error = compile_for_frost(source, 128, image, footprint - 1)
    assert ".heap" in error and "overflowed by 1 byte" in error


def test_shard_weights_use_cycles(tmp_path: Path) -> None:
    """A measured split and an estimated split use the same cost units."""
    names = ["a-0", "b-0", "c-0", "d-0"]
    for n in names:
        (tmp_path / f"{n}.S").write_text(".word 0x20000b\n" * (8 if n == "a-0" else 1))
    profile = tmp_path / "history.jsonl"
    profile.write_text(
        json.dumps({"name": "b-0", "vlen": 128, "verdict": "PASS", "cycles": 100})
        + "\n"
    )
    weights = shard_weights(tmp_path, names, 128, profile.read_bytes())
    assert weights == {"a-0": 800, "b-0": 100, "c-0": 100, "d-0": 100}
    assert select_shard(weights, 1, 2) == ["a-0"]
    assert select_shard(weights, 2, 2) == ["b-0", "c-0", "d-0"]


def test_one_per_form_rotation() -> None:
    """Selection is independent of enumeration order and covers early and late splits."""
    names = [f"{form}-{i}" for form in ("vadd_vv", "vfadd_vf") for i in range(12)]
    by_vlen = [one_per_form(names, v) for v in SUPPORTED_VLENS]
    assert by_vlen == [one_per_form(names[::-1], v) for v in SUPPORTED_VLENS]
    for chosen in zip(*by_vlen, strict=True):
        assert len({name.rsplit("-", 1)[0] for name in chosen}) == 1
        assert {int(name.rsplit("-", 1)[1]) // 4 for name in chosen} == {0, 1, 2}


def test_prebuilt_simulator_identity(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Bind the artifact to the build inputs, tool, bytes and model geometry."""
    model = VectorSimulator("native", 128, DEFAULT_DDR_BYTES, 100)
    stage = tmp_path / "checkout"
    hw = stage / "hw"
    rtl = hw / "rtl/example.sv"
    for name in (*rvv_simulator.NATIVE_INPUTS, "rtl/example.sv"):
        path = hw / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(name)
    monkeypatch.setattr(rvv_simulator, "ROOT", stage)

    def make_model(command: list[str], log: Path) -> None:
        model.binary.parent.mkdir(parents=True, exist_ok=True)
        model.binary.write_bytes(rtl.read_bytes())
        model.binary.chmod(0o755)

    monkeypatch.setattr(model, "_make", make_model)
    model.build(tmp_path / "build")
    artifact = tmp_path / "artifact"
    model.export_native(artifact)
    model.use_native(artifact)
    for width, capacity in ((256, DEFAULT_DDR_BYTES), (128, 4096)):
        with pytest.raises(ValueError, match="model settings"):
            VectorSimulator("native", width, capacity, 100).use_native(artifact)
    for path in (rtl, *(hw / name for name in rvv_simulator.NATIVE_INPUTS)):
        original = path.read_bytes()
        path.write_bytes(original + b"changed")
        with pytest.raises(ValueError, match="sources"):
            model.use_native(artifact)
        path.write_bytes(original)
    clean_binary = model.binary
    original = rtl.read_bytes()
    rtl.write_bytes(original + b"changed")
    model.build(tmp_path / "build")
    assert model.binary != clean_binary
    rtl.write_bytes(original)
    restored = tmp_path / "export-after-restore"
    model.export_native(restored)
    with pytest.raises(ValueError, match="sources"):
        model.use_native(restored)
    with monkeypatch.context() as patch:
        patch.setattr(
            subprocess, "check_output", lambda *a, **kw: "different Verilator"
        )
        with pytest.raises(ValueError, match="Verilator version"):
            model.use_native(artifact)
    artifact.write_bytes(b"other executable")
    with pytest.raises(ValueError, match="checksum"):
        model.use_native(artifact)
    monkeypatch.setenv("ENABLE_CACHED_TIER", "0")
    monkeypatch.delenv("MISALIGNED_HW", raising=False)
    uncached = VectorSimulator("native", 128, DEFAULT_DDR_BYTES, 100)
    assert uncached.model_settings["MISALIGNED_HW"] == "0"


def test_merge_shard_results(tmp_path: Path) -> None:
    """Disjoint shards must identify one profile and cover one complete selection."""
    names = ["vadd_vv-0", "vsub_vv-0"]
    identity = {
        "selection_sha256": selection_sha256(names, 128),
        "profile_sha256": hashlib.sha256(b"profile A").hexdigest(),
    }
    rows = [
        result_record(VectorTestResult(n, True), "native", 128, identity) for n in names
    ]
    parts = [tmp_path / n for n in names]
    output = tmp_path / "complete.jsonl"
    for path, row in zip(parts, rows, strict=True):
        path.write_text(json.dumps(row) + "\n")
    assert merge_results(parts[::-1], output) == 0
    complete = output.read_bytes()
    assert [json.loads(line) for line in complete.splitlines()] == rows
    with pytest.raises(ValueError, match="complete selection"):
        merge_results(parts[:1], output)
    with pytest.raises(ValueError, match="duplicate test"):
        merge_results([parts[0], parts[0]], output)
    for key in identity:
        other = {**rows[1], key: hashlib.sha256(b"other").hexdigest()}
        parts[1].write_text(json.dumps(other) + "\n")
        with pytest.raises(ValueError, match="differs"):
            merge_results(parts, output)
    assert output.read_bytes() == complete
    parts[1].write_text(json.dumps({**rows[1], "verdict": "FAIL"}) + "\n")
    assert merge_results(parts, output) == 1
    assert json.loads(output.read_text().splitlines()[1])["verdict"] == "FAIL"


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


def test_instruction_classes() -> None:
    """Examples from each class land in it."""
    examples = {
        "vle8_v-0": "load-store",
        "vlseg2e8ff_v-1": "load-store",
        "vsse32_v-0": "load-store",
        "vaesdf_vv-0": "crypto",
        "vsha2ms_vv-2": "crypto",
        "vclmul_vx-0": "bitmanip",
        "vcpop_v-0": "bitmanip",
        "vcpop_m-0": "mask-permute-reduce",
        "vfirst_m-0": "mask-permute-reduce",
        "vmsbf_m-0": "mask-permute-reduce",
        "vmsof_m-1": "mask-permute-reduce",
        "vredsum_vs-0": "mask-permute-reduce",
        "vslidedown_vx-0": "mask-permute-reduce",
        "vfadd_vv-0": "float",
        "vmfeq_vv-0": "float",
        "vadd_vv-0": "integer",
        "vsll_vi-0": "integer",
        "vsext_vf2-0": "integer",
    }
    for name, kind in examples.items():
        assert instruction_class(name) == kind, name
    assert set(examples.values()) == set(INSTRUCTION_CLASSES)


@needs_suite
def test_class_selection(tmp_path: Path) -> None:
    """--class keeps only that class, and only its sources remain."""
    names = generate_tests(
        tmp_path, 128, r"^(vadd\.vv|vle[[:digit:]]\.v|vfadd\.vv)$", None, "load-store"
    )
    assert names and all(n.startswith("vle8_v") for n in names)
    assert sorted(p.stem for p in (tmp_path / "stage1").glob("*.S")) == names


@needs_suite
def test_sample_shard_changes_selection(tmp_path: Path) -> None:
    """Adjacent shards identify the same complete selection and exact profile bytes."""
    profile = tmp_path / "history.jsonl"
    profile.write_bytes(
        b'{"name":"vadd_vv-0","vlen":128,"verdict":"PASS","cycles":100}\n'
    )
    first = generate_tests(
        tmp_path / "a", 128, SAMPLE_PATTERN, (1, 2), cycle_profile=profile
    )
    second = generate_tests(
        tmp_path / "b", 128, SAMPLE_PATTERN, (2, 2), cycle_profile=profile
    )
    assert first and second and not set(first) & set(second)
    expected = {
        "selection_sha256": selection_sha256(first + second, 128),
        "profile_sha256": hashlib.sha256(profile.read_bytes()).hexdigest(),
    }
    for part in ("a", "b"):
        assert json.loads((tmp_path / part / "selection.json").read_text()) == expected


@pytest.mark.cocotb
@pytest.mark.slow
@pytest.mark.skipif(
    os.environ.get("FROST_RVV_TESTS_RTL") != "1",
    reason="set FROST_RVV_TESTS_RTL=1 to run the vector RTL sample",
)
@needs_suite
def test_rtl_sample(tmp_path: Path) -> None:
    """A sample of generated tests passes on the simulated core."""
    vlen = int(os.environ.get("FROST_RVV_TESTS_VLEN", str(DEFAULT_VLEN)))
    results = run_rtl_tests(tmp_path, vlen, RTL_SAMPLE_PATTERN, shard=(1, 4))
    failed = [f"{r.name}: {r.message}" for r in results if not r.passed]
    assert results and not failed, "\n".join(failed)


@pytest.mark.cocotb
@pytest.mark.slow
@pytest.mark.skipif(
    os.environ.get("FROST_RVV_TESTS_RTL") != "1", reason="set FROST_RVV_TESTS_RTL=1"
)
@needs_suite
def test_native_parity_and_corrupt_check(tmp_path: Path) -> None:
    """Both benches pass the same image and a flipped expected bit fails natively."""
    names, failures = prepare(tmp_path, 128, r"^vle8\.v$", None, 1, rtl=True, one=True)
    assert len(names) == 1 and not failures
    source = tmp_path / "stage2" / f"{names[0]}.S"
    image = tmp_path / "images" / names[0]
    assert not compile_for_frost(source, 128, image)
    native = VectorSimulator("native", 128, DEFAULT_DDR_BYTES, 1_000_000)
    native.build(tmp_path / "native")
    cocotb = VectorSimulator("verilator", 128, DEFAULT_DDR_BYTES, 1_000_000)
    cocotb.build(tmp_path / "verilator")
    (image / "results.xml").write_text("<testsuites/>\n")
    reference, candidate = cocotb.run(image), native.run(image)
    assert reference.passed and candidate.passed, (reference, candidate)
    assert reference.image_sha256 == candidate.image_sha256
    assert reference.cycles == candidate.cycles
    native.max_cycles = 100
    stopped = native.run(image)
    assert not stopped.passed and stopped.cycles == 100
    assert "100-cycle limit" in stopped.message
    native.max_cycles = 1_000_000
    text, changes = re.subn(
        r"(TEST_CASE\(\d+,\s*t0,\s*)(0x[0-9a-fA-F]+)",
        lambda m: m[1] + hex(int(m[2], 16) ^ 1),
        source.read_text(),
        count=1,
    )
    assert changes == 1
    source.write_text(text)
    assert not compile_for_frost(source, 128, image)
    failed = native.run(image)
    assert (
        not failed.passed and failed.assertions_armed and "<<FAIL>>" in failed.message
    )
    assert failed.image_sha256 != candidate.image_sha256


@pytest.mark.cocotb
@pytest.mark.slow
@pytest.mark.skipif(
    os.environ.get("FROST_RVV_TESTS_RTL") != "1", reason="set FROST_RVV_TESTS_RTL=1"
)
@needs_suite
def test_native_rejects_modified_rtl(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An executable built with a failing RTL assertion cannot run in a clean tree."""
    names, failures = prepare(tmp_path, 128, r"^vle8\.v$", None, 1, rtl=True, one=True)
    assert len(names) == 1 and not failures
    image = tmp_path / "images" / names[0]
    assert not compile_for_frost(tmp_path / "stage2" / f"{names[0]}.S", 128, image)
    modified = tmp_path / "modified"
    shutil.copytree(
        REPO_ROOT / "hw", modified / "hw", ignore=shutil.ignore_patterns("sim_build")
    )
    top = modified / "hw/rtl/frost.sv"
    marker = "endmodule : frost"
    original = top.read_text()
    assert original.count(marker) == 1
    top.write_text(
        original.replace(
            marker,
            "always @(posedge i_clk) if (uart_write_enable_from_cpu)\n"
            '  assert (uart_write_data_from_cpu != 8\'h3c) else $error("unexpected UART marker");\n'
            + marker,
        )
    )
    with monkeypatch.context() as patch:
        patch.setattr(rvv_simulator, "ROOT", modified)
        model = VectorSimulator("native", 128, DEFAULT_DDR_BYTES, 1_000_000)
        model.build(tmp_path / "build")
        artifact = modified / "artifact/frost-native"
        model.export_native(artifact)
        model.use_native(artifact)
        result = model.run(image)
        assert not result.passed and result.assertions_armed
        assert "unexpected UART marker" in result.message
    copied = tmp_path / "download"
    shutil.copytree(artifact.parent, copied)
    consumer = VectorSimulator("native", 128, DEFAULT_DDR_BYTES, 1_000_000)
    with pytest.raises(ValueError, match="prebuilt simulator sources"):
        consumer.use_native(copied / "frost-native")


def positive_int(value: str) -> int:
    """Parse a strictly positive job count, budget or memory size."""
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main() -> int:
    """Command-line entry point."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument(
        "--vlen", type=int, choices=SUPPORTED_VLENS, default=DEFAULT_VLEN
    )
    parser.add_argument("--pattern", default=".*", help="regex on instruction names")
    parser.add_argument("--class", dest="instruction_kind", choices=INSTRUCTION_CLASSES)
    parser.add_argument(
        "--one-per-form", action="store_true", help="select one split per instruction"
    )
    parser.add_argument(
        "--shard", type=parse_shard, help="cycle-weighted shard K/N (1-based)"
    )
    parser.add_argument(
        "--cycle-profile",
        type=Path,
        help="use measured cycles from a results JSONL for sharding",
    )
    parser.add_argument(
        "--jobs",
        type=positive_int,
        default=4,
        help="parallel generation and image builds",
    )
    parser.add_argument("--rtl", action="store_true", help="run on the simulated core")
    parser.add_argument(
        "--simulator", choices=("verilator", "native"), default="verilator"
    )
    parser.add_argument(
        "--rtl-jobs", type=positive_int, default=1, help="concurrent RTL processes"
    )
    parser.add_argument(
        "--sim-threads",
        type=positive_int,
        default=1,
        help="Verilator threads per native build",
    )
    artifact = parser.add_mutually_exclusive_group()
    artifact.add_argument(
        "--build-sim",
        type=Path,
        help="write the native simulator and its .json settings, then exit",
    )
    artifact.add_argument(
        "--prebuilt-sim", type=Path, help="use a checked --build-sim artifact"
    )
    parser.add_argument(
        "--results-jsonl", type=Path, help="write one RTL result per selected image"
    )
    parser.add_argument(
        "--merge-results",
        type=Path,
        nargs="+",
        metavar="SHARD",
        help="verify and merge a complete set of shard JSONL files",
    )
    parser.add_argument(
        "--max-cycles", type=positive_int, default=DEFAULT_RTL_MAX_CYCLES
    )
    parser.add_argument(
        "--ddr-bytes",
        type=positive_int,
        default=os.environ.get("DDR_MODEL_BYTES", str(DEFAULT_DDR_BYTES)),
    )
    parser.add_argument("--workdir", type=Path, help="keep this invocation's files")
    parser.add_argument(
        "--list", action="store_true", help="print the selected tests and exit"
    )
    args = parser.parse_args()
    if args.merge_results:
        if not args.results_jsonl:
            parser.error("--merge-results requires an output file via --results-jsonl")
        try:
            return merge_results(args.merge_results, args.results_jsonl)
        except (OSError, ValueError) as exc:
            parser.exit(1, f"error: {exc}\n")
    if (args.build_sim or args.prebuilt_sim or args.sim_threads != 1) and not (
        args.rtl and args.simulator == "native"
    ):
        parser.error("native simulator build options require --rtl --simulator native")
    if not args.rtl and (
        args.results_jsonl or args.rtl_jobs != 1 or args.simulator == "native"
    ):
        parser.error("RTL execution options require --rtl")
    if args.cycle_profile and not args.shard:
        parser.error("--cycle-profile requires --shard")
    if (
        args.results_jsonl
        and args.cycle_profile
        and args.results_jsonl.resolve() == args.cycle_profile.resolve()
    ):
        parser.error(
            "use a separate output file for --results-jsonl and --cycle-profile"
        )
    if not args.build_sim and not suite_available():
        parser.error(
            f"riscv-vector-tests not found in {SUITE_DIR}; rebuild the image from the repository Dockerfile"
        )
    with (
        tempfile.TemporaryDirectory(prefix="rvv_tests_")
        if args.workdir is None
        else nullcontext(str(args.workdir)) as directory
    ):
        workdir = Path(directory).resolve()
        workdir.mkdir(parents=True, exist_ok=True)
        try:
            if args.build_sim:
                model = VectorSimulator(
                    "native", args.vlen, args.ddr_bytes, args.max_cycles
                )
                model.build(workdir / f"native-v{args.vlen}", args.sim_threads)
                model.export_native(args.build_sim)
                return 0
            if args.list:
                names = generate_tests(
                    workdir,
                    args.vlen,
                    args.pattern,
                    args.shard,
                    args.instruction_kind,
                    rtl=args.rtl,
                    one=args.one_per_form,
                    jobs=args.jobs,
                    cycle_profile=args.cycle_profile,
                )
                for name in names:
                    print(name)
                return 0
            if args.rtl:
                results = run_rtl_tests(
                    workdir,
                    args.vlen,
                    args.pattern,
                    args.shard,
                    str(args.max_cycles),
                    args.jobs,
                    args.instruction_kind,
                    simulator=args.simulator,
                    prebuilt_sim=args.prebuilt_sim,
                    rtl_jobs=args.rtl_jobs,
                    sim_threads=args.sim_threads,
                    ddr_bytes=args.ddr_bytes,
                    one=args.one_per_form,
                    results_jsonl=args.results_jsonl,
                    cycle_profile=args.cycle_profile,
                )
            else:
                results = run_spike_tests(
                    workdir,
                    args.vlen,
                    args.pattern,
                    args.shard,
                    args.jobs,
                    args.instruction_kind,
                    one=args.one_per_form,
                    cycle_profile=args.cycle_profile,
                )
            return report(results)
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1


if __name__ == "__main__":
    sys.exit(main())
