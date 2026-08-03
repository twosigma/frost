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

"""Generate riscv-torture tests and golden references for Frost.

Workflow:
  1. Generate random RV32/RV64 IMAFDC .S test files (--xlen selects)
  2. Compile for Spike, run Spike, save signature as golden reference
  3. Store .S files in tests/ (rv32) or tests_rv64/ and references in the
     matching references dir — the corpora never collide

The rv64 stream mixes in the W-form ALU/MUL ops, LD/SD/LWU, and the .d
atomics, seeds registers with 64-bit values, and pins AMO address
computation to a dedicated temporary (x30) so the runner can compare the
full non-address GPR set against Spike (the rv32 corpus predates that and
is FP-compare-only). The committed rv64 corpus was generated with
--seed 20260803.

Usage:
    # Generate new tests and Spike references:
    ./generate_tests.py --generate --count 20
    ./generate_tests.py --generate --xlen 64 --count 20 --seed 20260803

    # Generate references for existing tests only:
    ./generate_tests.py --references-only [--xlen 64]

    # Generate references for a single test:
    ./generate_tests.py --references-only --test tests/test_001.S
"""

import argparse
import os
import random
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
LINKER_SCRIPT = SCRIPT_DIR / "link_riscv_torture.ld"
SPIKE_LINKER_SCRIPT = SCRIPT_DIR / "link_spike.ld"

# Per-XLEN corpus directories (sibling dirs, mirroring the arch-reference
# namespacing intent of docs/rv64/phase1_plan.md D11: the two suites never
# collide, and the committed rv32 corpus is untouched by rv64 generation).
TESTS_DIR_BY_XLEN = {32: SCRIPT_DIR / "tests", 64: SCRIPT_DIR / "tests_rv64"}
REFERENCES_DIR_BY_XLEN = {
    32: SCRIPT_DIR / "references",
    64: SCRIPT_DIR / "references_rv64",
}

# Frost ISA strings for Spike
FROST_ISA_BY_XLEN = {
    32: "rv32imafdc_zicsr_zifencei_zba_zbb_zbs_zbkb_zicond",
    64: "rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zbkb_zicond",
}

RISCV_PREFIX = os.environ.get("RISCV_PREFIX", "riscv-none-elf-")
ARCH_BY_XLEN = {
    32: "rv32imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause",
    64: "rv64imafdc_zicsr_zicntr_zifencei_zba_zbb_zbs_zicond_zbkb_zihintpause",
}
ABI_BY_XLEN = {32: "ilp32", 64: "lp64"}

# Registers available for random operations
# Exclude: x0 (zero), x2 (sp), x3 (gp) — set by frost_header.S
# x31 reserved as memory base pointer during test
COMPUTE_GPRS_BY_XLEN = {
    32: [f"x{i}" for i in range(1, 31) if i not in (2, 3)],
    # rv64 additionally reserves x30 as the dedicated AMO address temporary
    # so layout-dependent addresses contaminate ONLY {sp, gp, x30, x31} —
    # the runner then compares the remaining GPR words against Spike
    # (the rv32 corpus predates this and stays FP-compare-only).
    64: [f"x{i}" for i in range(1, 30) if i not in (2, 3)],
}
MEM_BASE_REG = "x31"
AMO_ADDR_REG_RV64 = "x30"

# Base-I ALU instructions (reg-reg / reg-imm) — shifts operate at XLEN
ALU_RR_OPS = ["add", "sub", "sll", "srl", "sra", "and", "or", "xor", "slt", "sltu"]
ALU_RI_OPS = ["addi", "slli", "srli", "srai", "andi", "ori", "xori", "slti", "sltiu"]
# RV64I W-form ALU instructions (32-bit operate + sign-extend)
ALU_RR_W_OPS = ["addw", "subw", "sllw", "srlw", "sraw"]
ALU_RI_W_OPS = ["addiw", "slliw", "srliw", "sraiw"]
# M multiply/divide — full-width at either XLEN
MUL_OPS = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
# RV64M W-forms
MUL_W_OPS = ["mulw", "divw", "divuw", "remw", "remuw"]
# A atomics (word forms at both XLENs; doubleword forms at 64)
AMO_OPS = [
    "amoadd.w",
    "amoswap.w",
    "amoand.w",
    "amoor.w",
    "amoxor.w",
    "amomin.w",
    "amominu.w",
    "amomax.w",
    "amomaxu.w",
]
AMO_D_OPS = [
    "amoadd.d",
    "amoswap.d",
    "amoand.d",
    "amoor.d",
    "amoxor.d",
    "amomin.d",
    "amominu.d",
    "amomax.d",
    "amomaxu.d",
]
# RV32F single-precision FP
FP_S_OPS = ["fadd.s", "fsub.s", "fmul.s", "fdiv.s", "fmin.s", "fmax.s"]
FP_S_FUSED = ["fmadd.s", "fmsub.s", "fnmadd.s", "fnmsub.s"]
# RV32D double-precision FP
FP_D_OPS = ["fadd.d", "fsub.d", "fmul.d", "fdiv.d", "fmin.d", "fmax.d"]
FP_D_FUSED = ["fmadd.d", "fmsub.d", "fnmadd.d", "fnmsub.d"]
# Branch ops
BRANCH_OPS = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]


def _rand_gpr(rng: random.Random, xlen: int) -> str:
    return rng.choice(COMPUTE_GPRS_BY_XLEN[xlen])


def _rand_fpr(rng: random.Random) -> str:
    return f"f{rng.randint(0, 31)}"


def _rand_imm12(rng: random.Random) -> int:
    return rng.randint(-2048, 2047)


def _rand_shamt(rng: random.Random, xlen: int) -> int:
    """Shift amount for the full-width shifts (0-31 at rv32, 0-63 at rv64)."""
    return rng.randint(0, xlen - 1)


def _gen_alu_seq(rng: random.Random, lines: list[str], xlen: int) -> None:
    """Generate 1-3 random ALU instructions (W-forms mixed in at rv64)."""
    for _ in range(rng.randint(1, 3)):
        use_w = xlen == 64 and rng.random() < 0.35
        if rng.random() < 0.5:
            op = rng.choice(ALU_RR_W_OPS if use_w else ALU_RR_OPS)
            rd, rs1, rs2 = (
                _rand_gpr(rng, xlen),
                _rand_gpr(rng, xlen),
                _rand_gpr(rng, xlen),
            )
            lines.append(f"    {op} {rd}, {rs1}, {rs2}")
        else:
            op = rng.choice(ALU_RI_W_OPS if use_w else ALU_RI_OPS)
            rd, rs1 = _rand_gpr(rng, xlen), _rand_gpr(rng, xlen)
            if op in ("slliw", "srliw", "sraiw"):
                imm = rng.randint(0, 31)  # W-shifts take a 5-bit shamt
            elif op in ("slli", "srli", "srai"):
                imm = _rand_shamt(rng, xlen)
            else:
                imm = _rand_imm12(rng)
            lines.append(f"    {op} {rd}, {rs1}, {imm}")


def _gen_mul_seq(rng: random.Random, lines: list[str], xlen: int) -> None:
    """Generate 1-2 random multiply/divide instructions (W-forms at rv64)."""
    for _ in range(rng.randint(1, 2)):
        use_w = xlen == 64 and rng.random() < 0.35
        op = rng.choice(MUL_W_OPS if use_w else MUL_OPS)
        rd, rs1, rs2 = _rand_gpr(rng, xlen), _rand_gpr(rng, xlen), _rand_gpr(rng, xlen)
        lines.append(f"    {op} {rd}, {rs1}, {rs2}")


def _gen_mem_seq(rng: random.Random, lines: list[str], memsize: int, xlen: int) -> None:
    """Generate a load-store sequence using the memory data region."""
    # Use aligned offsets within the data region
    max_word_offset = (memsize - 4) & ~3
    offset = rng.randint(0, max_word_offset // 4) * 4

    rd = _rand_gpr(rng, xlen)
    rs = _rand_gpr(rng, xlen)

    op_types = ["word", "half", "byte"]
    if xlen == 64:
        # LD/SD (8-byte aligned) and the zero-extending LWU join the pool
        op_types += ["double", "wordu"]

    op_type = rng.choice(op_types)
    if op_type == "double":
        max_dword_offset = (memsize - 8) & ~7
        offset = rng.randint(0, max_dword_offset // 8) * 8
        lines.append(f"    ld {rd}, {offset}({MEM_BASE_REG})")
        lines.append(f"    sd {rs}, {offset}({MEM_BASE_REG})")
    elif op_type == "wordu":
        lines.append(f"    lwu {rd}, {offset}({MEM_BASE_REG})")
        lines.append(f"    sw {rs}, {offset}({MEM_BASE_REG})")
    elif op_type == "word":
        lines.append(f"    lw {rd}, {offset}({MEM_BASE_REG})")
        lines.append(f"    sw {rs}, {offset}({MEM_BASE_REG})")
    elif op_type == "half":
        load_op = rng.choice(["lh", "lhu"])
        offset = offset & ~1  # half-word align
        lines.append(f"    {load_op} {rd}, {offset}({MEM_BASE_REG})")
        lines.append(f"    sh {rs}, {offset}({MEM_BASE_REG})")
    else:
        load_op = rng.choice(["lb", "lbu"])
        lines.append(f"    {load_op} {rd}, {offset}({MEM_BASE_REG})")
        lines.append(f"    sb {rs}, {offset}({MEM_BASE_REG})")


def _gen_branch_seq(
    rng: random.Random, lines: list[str], label_id: int, xlen: int
) -> None:
    """Generate a short branch sequence that always reconverges."""
    op = rng.choice(BRANCH_OPS)
    rs1, rs2 = _rand_gpr(rng, xlen), _rand_gpr(rng, xlen)
    rd = _rand_gpr(rng, xlen)

    taken_label = f"_br_taken_{label_id}"
    done_label = f"_br_done_{label_id}"

    lines.append(f"    {op} {rs1}, {rs2}, {taken_label}")
    # Not-taken path: one ALU op
    alu_op = rng.choice(ALU_RR_OPS)
    r1, r2 = _rand_gpr(rng, xlen), _rand_gpr(rng, xlen)
    lines.append(f"    {alu_op} {rd}, {r1}, {r2}")
    lines.append(f"    j {done_label}")
    lines.append(f"{taken_label}:")
    # Taken path: different ALU op
    alu_op2 = rng.choice(ALU_RR_OPS)
    r3, r4 = _rand_gpr(rng, xlen), _rand_gpr(rng, xlen)
    lines.append(f"    {alu_op2} {rd}, {r3}, {r4}")
    lines.append(f"{done_label}:")


def _gen_fp_seq(rng: random.Random, lines: list[str]) -> None:
    """Generate 1-3 random floating-point instructions."""
    for _ in range(rng.randint(1, 3)):
        use_double = rng.random() < 0.4
        if use_double:
            ops = FP_D_OPS
            fused = FP_D_FUSED
        else:
            ops = FP_S_OPS
            fused = FP_S_FUSED

        if rng.random() < 0.2 and fused:
            op = rng.choice(fused)
            fd = _rand_fpr(rng)
            fs1, fs2, fs3 = _rand_fpr(rng), _rand_fpr(rng), _rand_fpr(rng)
            lines.append(f"    {op} {fd}, {fs1}, {fs2}, {fs3}")
        else:
            op = rng.choice(ops)
            fd, fs1, fs2 = _rand_fpr(rng), _rand_fpr(rng), _rand_fpr(rng)
            lines.append(f"    {op} {fd}, {fs1}, {fs2}")


def _gen_amo_seq(rng: random.Random, lines: list[str], memsize: int, xlen: int) -> None:
    """Generate a single AMO instruction (.d forms mixed in at rv64)."""
    use_d = xlen == 64 and rng.random() < 0.4
    if use_d:
        op = rng.choice(AMO_D_OPS)
        max_off = (memsize - 8) & ~7
        offset = rng.randint(0, max_off // 8) * 8
    else:
        op = rng.choice(AMO_OPS)
        max_off = (memsize - 4) & ~3
        offset = rng.randint(0, max_off // 4) * 4
    rd = _rand_gpr(rng, xlen)
    rs2 = _rand_gpr(rng, xlen)
    if xlen == 64:
        # Dedicated address temporary: keeps layout-dependent addresses out
        # of the compared GPR set (see COMPUTE_GPRS_BY_XLEN).
        addr_reg = AMO_ADDR_REG_RV64
    else:
        # Load address into a random temp register (legacy rv32 behavior;
        # this is why the rv32 GPR block is not signature-compared).
        addr_reg = _rand_gpr(rng, xlen)
        while addr_reg == rd or addr_reg == rs2:
            addr_reg = _rand_gpr(rng, xlen)
    lines.append(f"    addi {addr_reg}, {MEM_BASE_REG}, {offset}")
    lines.append(f"    {op} {rd}, {rs2}, ({addr_reg})")


def generate_test(
    seed: int, nseqs: int = 200, memsize: int = 1024, xlen: int = 32
) -> str:
    """Generate a random RV32/RV64 IMAFDC torture test."""
    rng = random.Random(seed)
    lines: list[str] = []
    gpr_max = (1 << xlen) - 1
    gpr_digits = xlen // 4

    lines.append(f"// Generated RV{xlen}IMAFDC torture test for Frost (seed={seed})")
    lines.append(f"// nseqs={nseqs} memsize={memsize}")
    lines.append("")
    lines.append('#include "frost_header.S"')
    lines.append("")
    lines.append("    .globl _torture_test_begin")
    lines.append("_torture_test_begin:")
    lines.append("")

    # Initialize GPRs with random XLEN-wide values
    lines.append("    // Initialize integer registers")
    for reg in COMPUTE_GPRS_BY_XLEN[xlen]:
        val = rng.randint(0, gpr_max)
        lines.append(f"    li {reg}, 0x{val:0{gpr_digits}x}")
    lines.append(f"    la {MEM_BASE_REG}, _torture_data")
    lines.append("")

    # Initialize FP registers from data section
    lines.append("    // Initialize FP registers from data section")
    # Use x1 temporarily as FP data pointer (will be restored after)
    lines.append("    la x1, _torture_fp_init")
    for i in range(32):
        lines.append(f"    fld f{i}, {i * 8}(x1)")
    # Restore x1 to a random value
    val = rng.randint(0, gpr_max)
    lines.append(f"    li x1, 0x{val:0{gpr_digits}x}")
    lines.append("")

    # Generate random instruction sequences
    branch_id = 0
    # Sequence type weights: alu, mem, branch, fp, mul, amo
    weights = [50, 10, 20, 10, 5, 5]

    for _ in range(nseqs):
        seq_type = rng.choices(
            ["alu", "mem", "branch", "fp", "mul", "amo"],
            weights=weights,
            k=1,
        )[0]

        if seq_type == "alu":
            _gen_alu_seq(rng, lines, xlen)
        elif seq_type == "mem":
            _gen_mem_seq(rng, lines, memsize, xlen)
        elif seq_type == "branch":
            _gen_branch_seq(rng, lines, branch_id, xlen)
            branch_id += 1
        elif seq_type == "fp":
            _gen_fp_seq(rng, lines)
        elif seq_type == "mul":
            _gen_mul_seq(rng, lines, xlen)
        elif seq_type == "amo":
            _gen_amo_seq(rng, lines, memsize, xlen)

    lines.append("")
    lines.append("    j _torture_test_end")
    lines.append("")

    # Data section
    lines.append("    .data")
    lines.append("    .align 3")
    lines.append("_torture_fp_init:")
    for i in range(32):
        val = rng.randint(0, 0xFFFFFFFFFFFFFFFF)
        lines.append(f"    .dword 0x{val:016x}")
    lines.append("")
    lines.append("    .align 2")
    lines.append("_torture_data:")
    for i in range(memsize // 4):
        val = rng.randint(0, 0xFFFFFFFF)
        lines.append(f"    .word 0x{val:08x}")
    lines.append("")
    lines.append('#include "frost_footer.S"')
    lines.append("")

    return "\n".join(lines)


def discover_tests(xlen: int) -> list[Path]:
    """Find all adapted .S test files for one XLEN."""
    tests_dir = TESTS_DIR_BY_XLEN[xlen]
    if not tests_dir.is_dir():
        return []
    return sorted(tests_dir.glob("*.S"))


def generate_one_reference(
    test_src: Path, xlen: int, verbose: bool = False
) -> tuple[str, str, str]:
    """Compile a torture test for Spike, run it, and extract signature.

    Returns (test_name, status, message).
    """
    test_name = test_src.stem
    references_dir = REFERENCES_DIR_BY_XLEN[xlen]
    references_dir.mkdir(parents=True, exist_ok=True)
    ref_path = references_dir / f"{test_name}.reference_output"

    with tempfile.TemporaryDirectory() as tmpdir:
        elf_path = Path(tmpdir) / "test.elf"
        sig_path = Path(tmpdir) / "test.sig"

        cc = f"{RISCV_PREFIX}gcc"

        env_dir = SCRIPT_DIR.parent / "riscv_tests" / "riscv-tests" / "env"
        cmd = [
            cc,
            f"-march={ARCH_BY_XLEN[xlen]}",
            f"-mabi={ABI_BY_XLEN[xlen]}",
            "-static",
            # lp64 needs PC-relative addressing for the 0x8xxx_xxxx Spike
            # link (medlow's absolute lui cannot form those at 64). Kept off
            # the rv32 build so --references-only reproduces the committed
            # corpus bit-exactly.
            *(["-mcmodel=medany"] if xlen == 64 else []),
            "-nostdlib",
            "-nostartfiles",
            f"-I{SCRIPT_DIR}",
            f"-I{env_dir}",
            f"-I{env_dir / 'p'}",
            f"-T{SPIKE_LINKER_SCRIPT}",
            "-o",
            str(elf_path),
            str(test_src),
        ]

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            msg = result.stderr.strip().split("\n")[-1] if result.stderr else "unknown"
            return test_name, "SKIP", f"Compile failed: {msg}"

        spike_cmd = [
            "spike",
            f"--isa={FROST_ISA_BY_XLEN[xlen]}",
            # Map main RAM at 0x80000000 (4MB) and UART sink at 0x40000000 (4KB).
            # Without the UART region, stores to 0x40000000 in frost_footer.S
            # cause access faults and an infinite trap loop.
            "-m0x80000000:0x400000,0x40000000:0x1000",
            f"+signature={sig_path}",
            "+signature-granularity=4",
            str(elf_path),
        ]

        try:
            result = subprocess.run(
                spike_cmd, capture_output=True, text=True, timeout=120
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


def _worker(args: tuple[str, int, bool]) -> tuple[str, str, str]:
    """Worker for parallel reference generation."""
    test_src_str, xlen, verbose = args
    return generate_one_reference(Path(test_src_str), xlen, verbose)


def main() -> int:
    """Generate riscv-torture tests and references for Frost."""
    parser = argparse.ArgumentParser(
        description="Generate riscv-torture tests and references for Frost",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--generate",
        action="store_true",
        help="Generate new random IMAFDC torture tests and Spike references",
    )
    group.add_argument(
        "--references-only",
        action="store_true",
        help="Generate Spike references for existing tests",
    )
    parser.add_argument(
        "--xlen",
        type=int,
        choices=(32, 64),
        default=32,
        help=(
            "Corpus XLEN: 32 (tests/ + references/) or 64 (tests_rv64/ + "
            "references_rv64/, the FROST_RV64 build axis). Default: 32."
        ),
    )
    parser.add_argument(
        "--count",
        type=int,
        default=20,
        metavar="N",
        help="Number of tests to generate (default: 20)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        metavar="S",
        help="Base seed for test generation (default: random)",
    )
    parser.add_argument(
        "--nseqs",
        type=int,
        default=200,
        metavar="N",
        help="Number of instruction sequences per test (default: 200)",
    )
    parser.add_argument(
        "--test", metavar="PATH", help="Generate reference for a single test"
    )
    parser.add_argument("--parallel", type=int, default=8, metavar="N")
    parser.add_argument("--verbose", "-v", action="store_true")

    args = parser.parse_args()

    # Check prerequisites
    if not shutil.which(f"{RISCV_PREFIX}gcc"):
        print(f"Error: {RISCV_PREFIX}gcc not found in PATH.")
        return 1

    xlen = args.xlen
    tests_dir = TESTS_DIR_BY_XLEN[xlen]
    references_dir = REFERENCES_DIR_BY_XLEN[xlen]

    if args.generate:
        if not shutil.which("spike"):
            print("Error: spike not found in PATH. Install riscv-isa-sim.")
            return 1

        tests_dir.mkdir(parents=True, exist_ok=True)
        references_dir.mkdir(parents=True, exist_ok=True)

        base_seed = args.seed if args.seed is not None else random.randint(0, 2**32 - 1)
        print(
            f"Generating {args.count} rv{xlen} torture tests "
            f"(base_seed={base_seed}, nseqs={args.nseqs})"
        )
        print(f"Output: {tests_dir}/")

        # Generate test .S files
        for i in range(args.count):
            test_name = f"test_{i + 1:03d}"
            test_path = tests_dir / f"{test_name}.S"
            seed = base_seed + i
            test_code = generate_test(seed, nseqs=args.nseqs, xlen=xlen)
            test_path.write_text(test_code)
            if args.verbose:
                print(f"  Generated {test_name} (seed={seed})")

        print(f"Generated {args.count} tests")
        print()

        # Generate Spike references
        print("Generating Spike references...")
        tests = discover_tests(xlen)
        work_items = [(str(t), xlen, args.verbose) for t in tests]
        results = []

        if args.parallel > 1 and len(tests) > 1:
            with ProcessPoolExecutor(max_workers=args.parallel) as executor:
                futures = {executor.submit(_worker, item): item for item in work_items}
                for future in as_completed(futures):
                    results.append(future.result())
        else:
            for item in work_items:
                results.append(_worker(item))

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

        print(f"\nTotal: {n_ok} OK, {n_skip} SKIP, {n_err} ERROR")
        return 1 if n_err > 0 else 0

    # References-only mode
    if not shutil.which("spike"):
        print("Error: spike not found in PATH. Install riscv-isa-sim.")
        return 1

    if args.test:
        test_path = Path(args.test)
        if not test_path.exists():
            test_path = tests_dir / args.test
        if not test_path.exists():
            print(f"Error: Test not found: {args.test}")
            return 1

        name, status, msg = generate_one_reference(test_path, xlen, args.verbose)
        print(f"{name:40s} {status}  {msg}")
        return 0 if status == "OK" else 1

    tests = discover_tests(xlen)
    if not tests:
        print(f"No test files found in {tests_dir}/")
        print("Use --generate to create tests first")
        return 1

    print(f"Generating references for {len(tests)} tests")
    print(f"ISA: {FROST_ISA_BY_XLEN[xlen]}")
    print(f"Output: {references_dir}/")
    print()

    work_items = [(str(t), xlen, args.verbose) for t in tests]
    results = []

    if args.parallel > 1 and len(tests) > 1:
        with ProcessPoolExecutor(max_workers=args.parallel) as executor:
            futures = {executor.submit(_worker, item): item for item in work_items}
            for future in as_completed(futures):
                results.append(future.result())
    else:
        for item in work_items:
            results.append(_worker(item))

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

    print(f"\nTotal: {n_ok} OK, {n_skip} SKIP, {n_err} ERROR")
    print(f"References stored in: {references_dir}/")
    return 1 if n_err > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
