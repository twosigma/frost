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

"""Fast checks of the TestRIG vector-instruction trace generator.

verif/testrig/vector.py writes the traces that tests/test_testrig.py --vector
replays on FROST and the Sail model. These check that each trace word is the
instruction its comment names, that traces are reproducible, that the Sail
configurations differ only in VLEN and are accepted, and, with two Sail
instances standing in for the two implementations, that the traces are
deterministic and sensitive to the vector length.
"""

import importlib
import json
import random
import re
import shutil
import subprocess
import sys
import time
from collections.abc import Iterable
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
VERIF_DIR = REPO_ROOT / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))
vector = importlib.import_module("testrig.vector")
test_testrig = importlib.import_module("test_testrig")

WORD = re.compile(r"^\.4byte (0x[0-9a-f]{8})\s+# (.+)$")
TRACE_WORD = re.compile(r"(?m)(?=^[ \t]*\.(?:2|4)byte[ \t]+)")


def test_traces_are_reproducible(tmp_path: Path) -> None:
    """The same seed gives the same traces, and a different seed does not."""
    first = vector.write_tests(tmp_path / "a", 3, 7, 20, 128)
    again = vector.write_tests(tmp_path / "b", 3, 7, 20, 128)
    other = vector.write_tests(tmp_path / "c", 3, 8, 20, 128)
    assert [p.read_text() for p in first] == [p.read_text() for p in again]
    assert [p.read_text() for p in first] != [p.read_text() for p in other]


@pytest.mark.parametrize("vlen", vector.VECTOR_LENGTHS)
def test_trace_shape(vlen: int) -> None:
    """Setup and read-out are kept whole; the read-out covers every element."""
    lines = vector.trace(random.Random(1), vlen, 10)
    assert lines.count(".noshrink") == 2 and lines.count(".shrink") == 1
    tail = lines[len(lines) - 1 - lines[::-1].index(".noshrink") :]
    readout = [w for w in tail if "vmv.x.s" in w or "vslidedown" in w]
    # v0..v31: one vmv.x.s per element, and a slide for every element but 0.
    elements = vlen // vector.ELEMENT_BITS
    assert len(readout) == 32 * (2 * elements - 1)


def test_unsupported_vlen_rejected(tmp_path: Path) -> None:
    """Only the vector lengths with a Sail configuration are accepted."""
    with pytest.raises(ValueError):
        vector.write_tests(tmp_path, 1, 1, 10, 64)


def test_words_match_the_assembler(tmp_path: Path) -> None:
    """Every word is what the assembler produces for the text beside it."""
    gcc = shutil.which("riscv64-linux-gcc")
    objdump = shutil.which("riscv64-linux-objdump")
    if gcc is None or objdump is None:
        pytest.skip("riscv64-linux-gcc is not installed (it is in the frost image)")
    entries = []
    for path in vector.write_tests(tmp_path / "t", 4, 3, 30, 256):
        for line in path.read_text().splitlines():
            match = WORD.match(line)
            if match:
                entries.append((int(match.group(1), 16), match.group(2)))
    source = tmp_path / "all.S"
    # The comments carry the assembly; csrr and vector names need the vector march.
    source.write_text("\n".join(text.split("  #")[0] for _, text in entries) + "\n")
    obj = tmp_path / "all.o"
    subprocess.run(
        [
            gcc,
            "-march=rv64imafdv_zicsr",
            "-mabi=lp64d",
            "-c",
            str(source),
            "-o",
            str(obj),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    raw = subprocess.run(
        [objdump, "-d", str(obj)], check=True, capture_output=True, text=True
    ).stdout
    words = [
        int(match.group(1), 16)
        for match in re.finditer(r"^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s", raw, re.MULTILINE)
    ]
    assert words
    assert words == [word for word, _ in entries]


def test_vlen_configs_differ_only_in_vlen() -> None:
    """The three Sail overlays are one file with a different V.vlen_exp."""
    overlays = {}
    for vlen in vector.VECTOR_LENGTHS:
        overlay = test_testrig.load_sail_json(test_testrig.sail_vector_overlay(vlen))
        assert overlay["extensions"]["V"].pop("vlen_exp") == vlen.bit_length() - 1
        overlays[vlen] = overlay
    assert overlays[128] == overlays[256] == overlays[512]


@pytest.mark.parametrize("vlen", vector.VECTOR_LENGTHS)
def test_sail_vector_config_validates(tmp_path: Path, vlen: int) -> None:
    """The merged configuration is accepted and enables V at the given length."""
    sail = shutil.which("sail_riscv_sim")
    if sail is None:
        pytest.skip("sail_riscv_sim is not installed (it is in the frost image)")
    config = test_testrig.write_sail_config(30, tmp_path, vlen=vlen)
    result = subprocess.run(
        [sail, "--config-override", str(config), "--validate-config"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    isa = subprocess.run(
        [sail, "--config-override", str(config), "--print-isa-string"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    base = isa.split("_")[0]
    assert base.startswith("rv64") and "v" in base[len("rv64") :], isa
    assert json.loads(config.read_text())["extensions"]["V"]["vlen_exp"] == (
        vlen.bit_length() - 1
    )


def _compare_two_sail(
    tmp_path: Path, trace_dir: Path, vlen_a: int, vlen_b: int
) -> subprocess.CompletedProcess[str]:
    """Run QuickCheckVEngine between two Sail instances, at two vector lengths."""
    sail = shutil.which("sail_riscv_sim")
    engine = shutil.which("QCVEngine")
    if sail is None or engine is None:
        pytest.skip("sail_riscv_sim or QCVEngine is not installed (frost image)")
    port_a, port_b = test_testrig.free_ports()
    processes = []
    try:
        for port, vlen in ((port_a, vlen_a), (port_b, vlen_b)):
            config_dir = tmp_path / f"sail_{port}"
            config_dir.mkdir()
            config = test_testrig.write_sail_config(30, config_dir, vlen=vlen)
            processes.append(
                subprocess.Popen(
                    [
                        sail,
                        "--config-override",
                        str(config),
                        "--disable-trap-loop-detection",
                        "--rvfi-dii",
                        str(port),
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            )
        time.sleep(2)
        return subprocess.run(
            [
                engine,
                "-a",
                str(port_a),
                "-b",
                str(port_b),
                "-r",
                vector.ARCHITECTURE,
                "-d",
                str(trace_dir),
                "-v",
                "1",
                "-S",
                "--no-save",
            ],
            cwd=tmp_path,
            capture_output=True,
            text=True,
            timeout=600,
            check=False,
            stdin=subprocess.DEVNULL,
        )
    finally:
        for process in processes:
            process.kill()
            process.wait()


@pytest.mark.parametrize("vlen", vector.VECTOR_LENGTHS)
def test_two_sail_instances_agree(tmp_path: Path, vlen: int) -> None:
    """Sail agrees with itself on the traces, so a mismatch is a real difference."""
    traces = tmp_path / "traces"
    vector.write_tests(traces, 4, 11, 20, vlen)
    result = _compare_two_sail(tmp_path, traces, vlen, vlen)
    assert result.returncode == 0 and "No Failure" in result.stdout, (
        result.stdout[-2000:] + result.stderr[-2000:]
    )


def test_traces_see_the_vector_length(tmp_path: Path) -> None:
    """Sail at VLEN 256 against Sail at VLEN 128 is reported as a failure."""
    traces = tmp_path / "traces"
    vector.write_tests(traces, 2, 11, 20, 256)
    result = _compare_two_sail(tmp_path, traces, 256, 128)
    assert result.returncode != 0 or "Failure." in result.stdout.replace(
        "No Failure", ""
    )


def test_arguments() -> None:
    """--vector implies a vector length, and bad values are rejected."""
    arguments = test_testrig.parse_arguments(["--vector", "3"])
    assert arguments.vlen == 128 and arguments.vector == 3
    assert test_testrig.parse_arguments(["--trace", "x.S", "--vlen", "256"]).vlen == 256
    assert test_testrig.parse_arguments([]).vlen is None
    assert not arguments.vector_source_widths and not arguments.vector_directed
    for bad in (["--vector", "-1"], ["--vector", "2", "--vector-length", "0"]):
        with pytest.raises(SystemExit):
            test_testrig.parse_arguments(bad)
    with pytest.raises(SystemExit):
        test_testrig.parse_arguments(["--vector", "2", "--sscofpmf"])
    for option in ("--vector-source-widths", "--vector-directed"):
        with pytest.raises(SystemExit):
            test_testrig.parse_arguments([option, "--vlen", "128"])


@pytest.mark.parametrize("vector_directed", (False, True))
@pytest.mark.parametrize(
    ("vlen", "instructions"), ((128, 2788), (256, 4324), (512, 7396))
)
def test_vector_directed_replay(
    tmp_path: Path, vlen: int, instructions: int, vector_directed: bool
) -> None:
    """Plan all generated and directed CI traces for the selected width."""
    options = [
        "--vector",
        "12",
        "--vector-length",
        "20",
        "--vector-source-widths",
        "--seed",
        "42",
        "--vlen",
        str(vlen),
    ]
    if vector_directed:
        options.append("--vector-directed")
    arguments = test_testrig.parse_arguments(options)
    config = test_testrig.write_sail_config(30, tmp_path, vlen=vlen)
    plan = test_testrig.prepare_inputs(arguments, tmp_path, config)
    trace_dir = tmp_path / "vector"
    assert plan.command == ["-d", str(trace_dir)]
    expected = (40, instructions + 27075) if vector_directed else (15, instructions)
    assert (plan.traces, plan.instructions) == expected
    assert len(list(trace_dir.glob("vector_42_*.S"))) == 12
    for family in ("integer", "fp", "memory"):
        filename = f"vector_source_widths_{family}.S"
        assert (trace_dir / filename).read_bytes() == (
            VERIF_DIR / "testrig" / filename
        ).read_bytes()
    for filename, words, checks in (
        ("vector_state_results.S", 72, 59),
        ("vector_fractional_lmul.S", 54, 62),
        ("vector_fp_results_flags.S", 74, 51),
        ("vector_fma.S", 186, 146),
        ("vector_fp_compare.S", 206, 264),
        ("vector_fp_convert.S", 210, 209),
        ("vector_cached_load.S", 13, 4),
        ("vector_cached_store.S", 12, 4),
        ("vector_unit_stride.S", 926, 336),
        ("vector_int_compare.S", 261, 210),
        ("vector_strided.S", 1846, 629),
        ("vector_indexed.S", 1924, 645),
        ("vector_segment.S", 2159, 1126),
        ("vector_fof.S", 326, 208),
        ("vector_int_widen_narrow.S", 1753, 871),
        ("vector_fixed_point.S", 1701, 1206),
        ("vector_fp_single.S", 1446, 1068),
        ("vector_whole_reg.S", 826, 662),
        ("vector_fp_widen.S", 1519, 1149),
        ("vector_permutes.S", 1876, 714),
        ("vector_reductions.S", 1731, 796),
        ("vector_carry_borrow.S", 1870, 759),
        ("vector_mask_ops.S", 1421, 601),
        ("vector_int_mul_add.S", 1707, 554),
        ("vector_int_vx_merge.S", 2956, 1303),
    ):
        trace = trace_dir / filename
        assert trace.is_file() == vector_directed
        if vector_directed:
            assert trace.read_bytes() == (VERIF_DIR / "testrig" / filename).read_bytes()
            lines = trace.read_text().splitlines()
            assert sum(line.startswith(".4byte ") for line in lines) == words
            assert sum(line.startswith(".assert ") for line in lines) == checks
    _check_vector_store_readbacks(trace_dir.glob("*.S"))


_LMUL_NUM_DEN = {
    0: (1, 1),
    1: (2, 1),
    2: (4, 1),
    3: (8, 1),
    5: (1, 8),
    6: (1, 4),
    7: (1, 2),
}
_VMEM_WIDTH_BYTES = {0: 1, 5: 2, 6: 4, 7: 8}
_SCALAR_LOAD_WIDTH_BYTES = {0: 1, 4: 1, 1: 2, 5: 2, 2: 4, 6: 4, 3: 8}
_INT_RD_OPCODES = frozenset(
    {0x03, 0x13, 0x17, 0x1B, 0x2F, 0x33, 0x37, 0x3B, 0x53, 0x57, 0x67, 0x6F, 0x73}
)


def _vlmax(vlen: int, sew: int, lmul_code: int) -> int:
    num, den = _LMUL_NUM_DEN[lmul_code]
    return (vlen * num) // (sew * den)


def _signed12(word: int) -> int:
    imm = (word >> 20) & 0xFFF
    return imm - 0x1000 if imm & 0x800 else imm


def _signed5(value: int) -> int:
    return value - 32 if value & 16 else value


def _signed32(value: int) -> int:
    value &= 0xFFFF_FFFF
    return value - 0x1_0000_0000 if value & 0x8000_0000 else value


def _sext64(value: int) -> int:
    value &= 0xFFFF_FFFF_FFFF_FFFF
    return value - 0x1_0000_0000_0000_0000 if value & 0x8000_0000_0000_0000 else value


def _lmul_regs(lmul_code: int) -> int:
    num, den = _LMUL_NUM_DEN[lmul_code]
    return max(1, num // den)


def _update_int_reg_tracking(reg_val: dict[int, int | None], word: int) -> None:
    """Track simple scalar constant arithmetic and clear on any other rd write."""
    opcode = word & 0x7F
    if opcode not in _INT_RD_OPCODES:
        return
    if opcode == 0x57:
        funct3 = (word >> 12) & 7
        if funct3 != 7 and not (funct3 == 2 and (word >> 26) == 0x10):
            return
    rd = (word >> 7) & 0x1F
    if rd == 0:
        return
    if opcode == 0x37:  # lui
        reg_val[rd] = _signed32(word & 0xFFFF_F000)
        return
    if opcode == 0x13:
        funct3 = (word >> 12) & 7
        rs1 = (word >> 15) & 0x1F
        src = reg_val.get(rs1)
        if src is None:
            reg_val[rd] = None
        elif funct3 == 0:  # addi
            reg_val[rd] = _sext64(src + _signed12(word))
        elif funct3 == 1 and (word >> 26) == 0:  # slli
            shamt = (word >> 20) & 0x3F
            reg_val[rd] = _sext64((src & 0xFFFF_FFFF_FFFF_FFFF) << shamt)
        elif funct3 == 5 and (word >> 26) == 0:  # srli
            shamt = (word >> 20) & 0x3F
            reg_val[rd] = _sext64((src & 0xFFFF_FFFF_FFFF_FFFF) >> shamt)
        else:
            reg_val[rd] = None
        return
    if opcode == 0x33 and ((word >> 12) & 7) == 6 and (word >> 25) == 0:  # or
        a = reg_val.get((word >> 15) & 0x1F)
        b = reg_val.get((word >> 20) & 0x1F)
        if a is not None and b is not None:
            reg_val[rd] = _sext64(
                (a & 0xFFFF_FFFF_FFFF_FFFF) | (b & 0xFFFF_FFFF_FFFF_FFFF)
            )
            return
    reg_val[rd] = None


def _read_vgroup(
    regs: list[bytearray | None], base: int, count: int
) -> bytearray | None:
    if count == 0:
        return bytearray()
    if base + count > 32:
        return None
    out = bytearray()
    for reg in regs[base : base + count]:
        if reg is None:
            return None
        out.extend(reg)
    return out


def _write_vgroup(
    regs: list[bytearray | None], base: int, count: int, buf: bytearray, vlenb: int
) -> None:
    for offset in range(count):
        regs[base + offset] = bytearray(buf[offset * vlenb : (offset + 1) * vlenb])


def _invalidate_vgroup(
    vrf: dict[int, list[bytearray | None]], base: int, count: int
) -> None:
    for regs in vrf.values():
        for reg in range(base, min(32, base + count)):
            regs[reg] = None


def _update_vec_reg_tracking(
    vrf: dict[int, list[bytearray | None]],
    reg_val: dict[int, int | None],
    sew: int | None,
    lmul_code: int | None,
    vl_by_vlen: dict[int, int] | None,
    word: int,
) -> None:
    """Track simple unmasked vector index builders and invalidate untracked writes."""
    opcode = word & 0x7F
    if opcode == 0x07:
        width = (word >> 12) & 7
        if width not in _VMEM_WIDTH_BYTES:
            return
        vd = (word >> 7) & 0x1F
        mop = (word >> 26) & 3
        umop = (word >> 20) & 0x1F
        if mop == 0 and umop == 0x08:
            count = ((word >> 29) & 7) + 1
            _invalidate_vgroup(vrf, vd, count)
            return
        if sew is None or lmul_code is None or lmul_code not in _LMUL_NUM_DEN:
            _invalidate_vgroup(vrf, vd, 8)
            return
        num, den = _LMUL_NUM_DEN[lmul_code]
        if mop in (1, 3):
            count = max(1, num // den)
        elif mop == 0 and umop == 0x0B:
            count = 1
        else:
            eew = _VMEM_WIDTH_BYTES[width] * 8
            count = min(8, max(1, (eew * num + sew * den - 1) // (sew * den)))
        _invalidate_vgroup(vrf, vd, count)
        return
    if opcode != 0x57:
        return
    funct3 = (word >> 12) & 7
    if funct3 == 7:
        return
    funct6 = word >> 26
    if funct6 == 0x10 and funct3 == 2:  # vmv.x.s / vcpop.m / vfirst.m
        return
    vd = (word >> 7) & 0x1F
    if sew is None or lmul_code is None or vl_by_vlen is None:
        _invalidate_vgroup(vrf, vd, 8)
        return
    vm = (word >> 25) & 1
    vs2 = (word >> 20) & 0x1F
    vs1 = (word >> 15) & 0x1F
    count = _lmul_regs(lmul_code)
    elem_bytes = sew // 8
    mask = (1 << sew) - 1

    if vm == 1 and funct6 == 0x17 and funct3 in (3, 4) and vs2 == 0:  # vmv.v.i / .x
        sval = _signed5(vs1) if funct3 == 3 else reg_val.get(vs1)
        if sval is None:
            _invalidate_vgroup(vrf, vd, count)
            return
        enc = (sval & mask).to_bytes(elem_bytes, "little")
        for v, vl in vl_by_vlen.items():
            vlenb = v // 8
            buf = (
                bytearray(count * vlenb)
                if vl == _vlmax(v, sew, lmul_code)
                else _read_vgroup(vrf[v], vd, count)
            )
            if buf is None:
                _invalidate_vgroup({v: vrf[v]}, vd, count)
                continue
            for idx in range(vl):
                buf[idx * elem_bytes : (idx + 1) * elem_bytes] = enc
            _write_vgroup(vrf[v], vd, count, buf, vlenb)
        return
    if vm == 1 and funct6 == 0x10 and funct3 == 6 and vs2 == 0:  # vmv.s.x
        sval = reg_val.get(vs1)
        if sval is None:
            _invalidate_vgroup(vrf, vd, 1)
            return
        enc = (sval & mask).to_bytes(elem_bytes, "little")
        for v, vl in vl_by_vlen.items():
            if vl > 0 and vrf[v][vd] is not None:
                vrf[v][vd][0:elem_bytes] = enc  # type: ignore[index]
        return
    if vm == 1 and funct6 == 0x0E and funct3 == 6:  # vslide1up.vx
        sval = reg_val.get(vs1)
        if sval is None:
            _invalidate_vgroup(vrf, vd, count)
            return
        enc0 = (sval & mask).to_bytes(elem_bytes, "little")
        for v, vl in vl_by_vlen.items():
            vlenb = v // 8
            src = _read_vgroup(vrf[v], vs2, count)
            dst = (
                bytearray(count * vlenb)
                if vl == _vlmax(v, sew, lmul_code)
                else _read_vgroup(vrf[v], vd, count)
            )
            if src is None or dst is None:
                _invalidate_vgroup({v: vrf[v]}, vd, count)
                continue
            if vl > 0:
                dst[0:elem_bytes] = enc0
                for idx in range(1, vl):
                    dst[idx * elem_bytes : (idx + 1) * elem_bytes] = src[
                        (idx - 1) * elem_bytes : idx * elem_bytes
                    ]
            _write_vgroup(vrf[v], vd, count, dst, vlenb)
        return
    if vm == 1 and funct6 == 0x14 and funct3 == 2 and vs2 == 0 and vs1 == 0x11:  # vid.v
        for v, vl in vl_by_vlen.items():
            vlenb = v // 8
            dst = (
                bytearray(count * vlenb)
                if vl == _vlmax(v, sew, lmul_code)
                else _read_vgroup(vrf[v], vd, count)
            )
            if dst is None:
                _invalidate_vgroup({v: vrf[v]}, vd, count)
                continue
            for idx in range(vl):
                dst[idx * elem_bytes : (idx + 1) * elem_bytes] = (idx & mask).to_bytes(
                    elem_bytes, "little"
                )
            _write_vgroup(vrf[v], vd, count, dst, vlenb)
        return
    if vm == 1 and funct6 in (0x0B, 0x25) and funct3 == 3:  # vxor.vi / vsll.vi
        imm = (_signed5(vs1) & mask) if funct6 == 0x0B else (vs1 & (sew - 1))
        for v, vl in vl_by_vlen.items():
            vlenb = v // 8
            src = _read_vgroup(vrf[v], vs2, count)
            dst = (
                bytearray(count * vlenb)
                if vl == _vlmax(v, sew, lmul_code)
                else _read_vgroup(vrf[v], vd, count)
            )
            if src is None or dst is None:
                _invalidate_vgroup({v: vrf[v]}, vd, count)
                continue
            for idx in range(vl):
                val = int.from_bytes(
                    src[idx * elem_bytes : (idx + 1) * elem_bytes], "little"
                )
                out = ((val ^ imm) if funct6 == 0x0B else (val << imm)) & mask
                dst[idx * elem_bytes : (idx + 1) * elem_bytes] = out.to_bytes(
                    elem_bytes, "little"
                )
            _write_vgroup(vrf[v], vd, count, dst, vlenb)
        return
    _invalidate_vgroup(vrf, vd, min(8, 2 * count))


def _check_vector_mem_store_readbacks(
    trace: Path, blocks: list[str], words: list[int]
) -> None:
    """Verify immediate readback for unit-stride, mask, strided, indexed, segment and whole-register stores."""
    for block in blocks:
        assert block.lstrip().startswith(".4byte "), (
            f"{trace.name}: compressed instruction not allowed in vector store trace"
        )
    vl_by_vlen: dict[int, int] | None = None
    sew: int | None = None
    lmul: int | None = None
    vill = False
    reg_val: dict[int, int | None] = {0: 0}
    vrf: dict[int, list[bytearray | None]] = {
        v: [None] * 32 for v in vector.VECTOR_LENGTHS
    }
    for index, word in enumerate(words):
        opcode = word & 0x7F
        if opcode == 0x73:
            funct3 = (word >> 12) & 7
            if funct3 in (1, 2, 3, 5, 6, 7):
                csr = (word >> 20) & 0xFFF
                assert csr != 0x301, f"{trace.name}: misa access is disallowed"
                rs1_or_uimm = (word >> 15) & 0x1F
                is_write = funct3 in (1, 5) or rs1_or_uimm != 0
                assert not (csr == 0x008 and is_write), (
                    f"{trace.name}: unexpected vstart write at index {index}"
                )
        elif word & 0xC000_707F == 0xC000_7057:  # vsetivli
            vtype = (word >> 20) & 0xFF
            uimm = (word >> 15) & 0x1F
            sew_code = (vtype >> 3) & 7
            sew = 8 << sew_code
            lmul = vtype & 7
            if (
                sew_code > 3
                or lmul not in _LMUL_NUM_DEN
                or sew * _LMUL_NUM_DEN[lmul][1] > 64 * _LMUL_NUM_DEN[lmul][0]
            ):
                vill = True
                vl_by_vlen = {v: 0 for v in vector.VECTOR_LENGTHS}
            else:
                vill = False
                vl_by_vlen = {
                    v: min(uimm, _vlmax(v, sew, lmul)) for v in vector.VECTOR_LENGTHS
                }
        elif word & 0x8000_707F == 0x0000_7057:  # vsetvli
            rs1 = (word >> 15) & 0x1F
            rd = (word >> 7) & 0x1F
            assert rs1 == 0 and rd != 0, (
                f"{trace.name}: dynamic vsetvli at index {index} hides VL"
            )
            vtype = (word >> 20) & 0xFF
            sew_code = (vtype >> 3) & 7
            sew = 8 << sew_code
            lmul = vtype & 7
            if (
                sew_code > 3
                or lmul not in _LMUL_NUM_DEN
                or sew * _LMUL_NUM_DEN[lmul][1] > 64 * _LMUL_NUM_DEN[lmul][0]
            ):
                vill = True
                vl_by_vlen = {v: 0 for v in vector.VECTOR_LENGTHS}
            else:
                vill = False
                vl_by_vlen = {v: _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS}
        elif word & 0xFE00_707F == 0x8000_7057:  # vsetvl
            raise AssertionError(f"{trace.name}: vsetvl at index {index} hides VL")
        elif test_testrig.run_stats.is_vector_store(word):
            if re.search(r'(?m)^\.assert trap == 1(?:[ \t]+"|[ \t]*$)', blocks[index]):
                continue  # The replay enforces the trap assertion on each such store.
            assert re.search(r"(?m)^\.assert trap == 0\b", blocks[index]), (
                f"{trace.name}: retiring vector store at index {index} needs trap == 0"
            )
            assert ((word >> 28) & 1) == 0, (
                f"{trace.name}: reserved mew=1 store at index {index}"
            )
            mop = (word >> 26) & 3
            nf = (word >> 29) & 7
            nfields = nf + 1
            rs2_or_sumop = (word >> 20) & 0x1F
            width = (word >> 12) & 7
            rs1 = (word >> 15) & 0x1F
            is_vsm = mop == 0 and rs2_or_sumop == 0x0B
            is_whole = mop == 0 and rs2_or_sumop == 0x08
            if is_whole:
                assert nf in (0, 1, 3, 7) and width == 0 and bool((word >> 25) & 1), (
                    f"{trace.name}: illegal whole-register store at index {index}"
                )
                per_vlen = {
                    v: set(range(nfields * (v // 8))) for v in vector.VECTOR_LENGTHS
                }
            else:
                assert not vill and vl_by_vlen is not None and sew is not None, (
                    f"{trace.name}: store before valid vset* config"
                )
                assert nf == 0 or mop in (0, 2), (
                    f"{trace.name}: unsupported vector store form at index {index}"
                )
                if mop == 0:
                    assert rs2_or_sumop in (0, 0x0B), (
                        f"{trace.name}: unsupported unit-stride sumop at index {index}"
                    )
                    if is_vsm:
                        assert nf == 0 and width == 0 and bool((word >> 25) & 1)
                        per_vlen = {
                            v: set(range((vl + 7) // 8)) for v, vl in vl_by_vlen.items()
                        }
                    else:
                        elem_bytes = _VMEM_WIDTH_BYTES[width]
                        seg_bytes = nfields * elem_bytes
                        per_vlen = {
                            v: set(range(vl * seg_bytes))
                            for v, vl in vl_by_vlen.items()
                        }
                elif mop == 2:  # strided or strided-segment
                    elem_bytes = _VMEM_WIDTH_BYTES[width]
                    seg_bytes = nfields * elem_bytes
                    stride = 0 if rs2_or_sumop == 0 else reg_val.get(rs2_or_sumop)
                    assert stride is not None, (
                        f"{trace.name}: unknown stride x{rs2_or_sumop} at index {index}"
                    )
                    per_vlen = {
                        v: {
                            i * stride + byte
                            for i in range(vl)
                            for byte in range(seg_bytes)
                        }
                        for v, vl in vl_by_vlen.items()
                    }
                else:  # indexed (mop in (1, 3))
                    index_bytes = _VMEM_WIDTH_BYTES[width]
                    elem_bytes = sew // 8
                    per_vlen = {}
                    for v, vl in vl_by_vlen.items():
                        vlenb = v // 8
                        needed_regs = (vl * index_bytes + vlenb - 1) // vlenb
                        idx_buf = _read_vgroup(vrf[v], rs2_or_sumop, needed_regs)
                        assert idx_buf is not None, (
                            f"{trace.name}: unknown index vector v{rs2_or_sumop} "
                            f"at index {index}"
                        )
                        written: set[int] = set()
                        for i in range(vl):
                            offset = int.from_bytes(
                                idx_buf[i * index_bytes : (i + 1) * index_bytes],
                                "little",
                            )
                            elem_range = set(range(offset, offset + elem_bytes))
                            if mop == 1:
                                assert written.isdisjoint(elem_range), (
                                    f"{trace.name}: unordered indexed store at index "
                                    f"{index} has overlapping active elements"
                                )
                            written.update(elem_range)
                        per_vlen[v] = written
            required = set().union(*per_vlen.values())
            always_active = set.intersection(*per_vlen.values())
            covered: set[int] = set()
            asserted_offsets: set[int] = set()
            scan = index + 1
            while scan < len(words):
                next_word = words[scan]
                next_op = next_word & 0x7F
                next_f3 = (next_word >> 12) & 7
                next_rd = (next_word >> 7) & 0x1F
                if (
                    next_op == 0x03
                    and next_f3 in _SCALAR_LOAD_WIDTH_BYTES
                    and ((next_word >> 15) & 0x1F) == rs1
                    and next_rd not in (0, rs1)
                ):
                    offset = _signed12(next_word)
                    load_bytes = _SCALAR_LOAD_WIDTH_BYTES[next_f3]
                    byte_range = set(range(offset, offset + load_bytes))
                    covered.update(byte_range)
                    if re.search(r"(?m)^\.assert rd_wdata == ", blocks[scan]):
                        asserted_offsets.update(byte_range)
                    scan += 1
                    continue
                break
            assert required <= covered, (
                f"{trace.name}: vector store at index {index} missing immediate "
                f"scalar readback for bytes {sorted(required - covered)}"
            )
            if not required:
                assert 0 in asserted_offsets, (
                    f"{trace.name}: zero-length vector store at index {index} "
                    "needs a sentinel readback assertion"
                )
            else:
                assert always_active <= asserted_offsets or (
                    is_vsm and len(always_active) != len(required)
                ), (
                    f"{trace.name}: vector store at index {index} missing rd_wdata "
                    "assertion on always-active bytes"
                )
        _update_vec_reg_tracking(vrf, reg_val, sew, lmul, vl_by_vlen, word)
        _update_int_reg_tracking(reg_val, word)


def _check_vector_store_readbacks(traces: Iterable[Path]) -> None:
    """Each vector store must assert a trap or read back all written elements."""
    for trace in traces:
        blocks = TRACE_WORD.split(trace.read_text())[1:]
        words = [int(block.split()[1], 0) for block in blocks]
        stores = [
            index
            for index, word in enumerate(words)
            if test_testrig.run_stats.is_vector_store(word)
        ]
        if trace.name in (
            "vector_unit_stride.S",
            "vector_strided.S",
            "vector_indexed.S",
            "vector_segment.S",
            "vector_whole_reg.S",
        ):
            assert stores, f"{trace.name}: expected vector stores"
            _check_vector_mem_store_readbacks(trace, blocks, words)
            continue
        if trace.name != "vector_cached_store.S":
            for store in stores:
                assert re.search(
                    r'(?m)^\.assert trap == 1(?:[ \t]+"|[ \t]*$)', blocks[store]
                ), f"{trace.name}: vector store needs a trap or scalar readback check"
            continue  # The replay enforces the trap assertion on each such store.

        (store,) = stores
        assert words[store] == 0x0204_6427  # vse32.v v8, (s0), unmasked
        assert re.search(r"(?m)^\.assert trap == 0\b", blocks[store])

        # Fix the setup so the store starts at lane zero with two active
        # lanes at a fresh base, and nothing else can initialize that memory.
        assert words[:store] == [
            0x6000_0293,  # addi t0, zero, 0x600
            0x3002_A073,  # csrs mstatus, t0
            0x4000_8437,  # lui s0, 0x40008
            0x0014_1413,  # slli s0, s0, 1
            0xC101_7657,  # vsetivli a2, 2, e32, m1, tu, mu
            0x0070_0313,  # addi t1, zero, 7
            0x0050_0393,  # addi t2, zero, 5
            0x5E03_C457,  # vmv.v.x v8, t2
            0x4203_6457,  # vmv.s.x v8, t1
        ], f"{trace.name}: unexpected vector store setup"
        assert re.search(r"(?m)^\.assert rd_wdata == 0x2\b", blocks[4])

        # Read consecutive stored addresses immediately, with both values
        # asserted in the replay.
        assert words[store + 1 :] == [
            0x0004_6503,  # lwu a0, 0(s0)
            0x0044_6503,  # lwu a0, 4(s0)
        ], f"{trace.name}: expected two immediate scalar reads"
        for block, value in zip(blocks[store + 1 :], (7, 5), strict=True):
            assert re.search(rf"(?m)^\.assert rd_wdata == {value:#x}\b", block)


@pytest.mark.parametrize(
    ("position", "encoding", "error"),
    [
        pytest.param("before", "0x80037057", "unexpected.*setup", id="vsetvl-before"),
        pytest.param(
            "after", "0x01037057", "immediate scalar reads", id="vsetvli-after"
        ),
        pytest.param(
            "after", "0x80037057", "immediate scalar reads", id="vsetvl-after"
        ),
        pytest.param("before", "0x0080d073", "unexpected.*setup", id="write-vstart"),
        pytest.param("before", "0x00642023", "unexpected.*setup", id="prestore"),
        pytest.param("before", "0xc018", "unexpected.*setup", id="compressed-prestore"),
    ],
)
def test_vector_store_readback_rejects_extra_instruction(
    tmp_path: Path, position: str, encoding: str, error: str
) -> None:
    """Setup and readback cannot change VL, vstart or prior memory contents."""
    trace = tmp_path / "vector_cached_store.S"
    lines = (VERIF_DIR / "testrig" / trace.name).read_text().splitlines()
    anchor = "0x02046427" if position == "before" else "0x00046503"
    index = next(
        i for i, line in enumerate(lines) if line.startswith(f".4byte {anchor} ")
    )
    size = 2 if len(encoding) == 6 else 4
    lines.insert(index, f".{size}byte {encoding}")
    trace.write_text("\n".join(lines) + "\n")
    with pytest.raises(AssertionError, match=error):
        _check_vector_store_readbacks([trace])


def test_vector_store_readback_rejects_vsetvli_before_store(tmp_path: Path) -> None:
    """The extra configuration can raise VL without changing the word count."""
    trace = tmp_path / "vector_cached_store.S"
    source = (VERIF_DIR / "testrig" / trace.name).read_text()
    trace.write_text(
        source.replace("0x00500393", "0x01037057").replace("0x5e03c457", "0x5e02b457")
    )
    with pytest.raises(AssertionError, match="unexpected.*setup"):
        _check_vector_store_readbacks([trace])


def test_vector_source_width_store_needs_trap_or_readback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A source-width entry needs the same check as a directed store."""
    trace = tmp_path / "unobserved_vector_store.S"
    source = (VERIF_DIR / "testrig" / "vector_cached_store.S").read_text()
    trace.write_text(source.split(".4byte 0x00046503", 1)[0])
    monkeypatch.setattr(test_testrig, "VECTOR_SOURCE_WIDTH_TRACES", (trace,))
    arguments = test_testrig.parse_arguments(
        ["--vector", "1", "--vector-source-widths", "--seed", "42"]
    )
    config = test_testrig.write_sail_config(30, tmp_path, vlen=128)
    test_testrig.prepare_inputs(arguments, tmp_path, config)
    with pytest.raises(AssertionError, match="unobserved_vector_store.S: vector store"):
        _check_vector_store_readbacks((tmp_path / "vector").glob("*.S"))


def test_vector_fp_compare_trace_covers_predicates() -> None:
    """Check encoded predicate, operand form, SEW and mask coverage."""
    trace = VERIF_DIR / "testrig" / "vector_fp_compare.S"
    vv, vf = 0b001, 0b101
    compare_forms = {
        0x18: (vv, vf),  # vmfeq
        0x19: (vv, vf),  # vmfle
        0x1B: (vv, vf),  # vmflt
        0x1C: (vv, vf),  # vmfne
        0x1D: (vf,),  # vmfgt
        0x1F: (vf,),  # vmfge
    }
    vtype = 0
    observed = set()
    for line in trace.read_text().splitlines():
        if not line.startswith(".4byte "):
            continue
        word = int(line.split()[1], 16)
        if word & 0xC000_707F == 0xC000_7057:  # vsetivli
            vtype = (word >> 20) & 0xFF
            assert vtype & 7 == 0  # LMUL 1
            assert (word >> 15) & 31 == 2  # Immediate AVL
        elif word & 0x7F == 0x57:  # OP-V
            funct6, form = word >> 26, (word >> 12) & 7
            if funct6 in compare_forms and form in (vv, vf):
                unmasked = bool(word & (1 << 25))
                if not unmasked:
                    assert vtype & 0xC0 == 0xC0  # ta, ma
                sew = 8 << ((vtype >> 3) & 7)
                observed.add((sew, funct6, form, unmasked))

    expected = {
        (sew, funct6, form, True)
        for sew in (32, 64)
        for funct6, forms in compare_forms.items()
        for form in forms
    }
    expected.add((64, 0x1B, vv, False))
    assert observed == expected


def test_vector_fp_convert_trace_covers_forms() -> None:
    """Check the encoded conversion forms, widths and guard."""
    trace = VERIF_DIR / "testrig" / "vector_fp_convert.S"
    single = {0, 1, 2, 3, 6, 7}
    widening = {8, 9, 10, 11, 12, 14, 15}
    narrowing = set(range(16, 24))
    vtype = 0
    observed = set()
    for line in trace.read_text().splitlines():
        if not line.startswith(".4byte "):
            continue
        word = int(line.split()[1], 16)
        if word & 0xC000_707F == 0xC000_7057:  # vsetivli
            vtype = (word >> 20) & 0xFF
            assert vtype & 7 == 0  # LMUL 1
            assert (word >> 15) & 31 == 2  # Immediate AVL
        elif word & 0xFC00_707F == 0x4800_1057:  # FP conversion
            sew = 8 << ((vtype >> 3) & 7)
            selector = (word >> 15) & 31
            unmasked = bool(word & (1 << 25))
            if not unmasked:
                assert vtype & 0xC0 == 0x40  # ta, mu
            observed.add((sew, selector, unmasked))

    expected = {(32, selector, True) for selector in single | widening | narrowing}
    expected.update((64, selector, True) for selector in single)
    expected.add((32, 1, False))  # Masked signed conversion from float
    assert observed == expected


def test_vector_unit_stride_trace_covers_forms() -> None:
    """Check unit-stride load/store widths, masking, vlm/vsm, VL regimes and no misa."""
    trace = VERIF_DIR / "testrig" / "vector_unit_stride.S"
    vtype = 0
    avl_mode = ""
    vl_imm = 0
    forms_seen: set[tuple[str, int, bool]] = set()
    regimes_seen: set[tuple[str, str]] = set()
    policies_seen: set[tuple[str, int]] = set()
    for line in trace.read_text().splitlines():
        if not line.startswith(".4byte "):
            continue
        word = int(line.split()[1], 16)
        opcode = word & 0x7F
        if opcode == 0x73 and ((word >> 12) & 7) in (1, 2, 3, 5, 6, 7):
            assert ((word >> 20) & 0xFFF) != 0x301  # No misa access
        elif word & 0xC000_707F == 0xC000_7057:  # vsetivli
            vtype = (word >> 20) & 0xFF
            vl_imm = (word >> 15) & 0x1F
            avl_mode = "imm"
        elif word & 0x8000_707F == 0x0000_7057:  # vsetvli
            vtype = (word >> 20) & 0xFF
            assert ((word >> 15) & 0x1F) == 0 and ((word >> 7) & 0x1F) != 0
            avl_mode = "vlmax"
        elif opcode in (0x07, 0x27) and ((word >> 12) & 7) in _VMEM_WIDTH_BYTES:
            mop = (word >> 26) & 3
            nf = (word >> 29) & 7
            umop = (word >> 20) & 0x1F
            assert mop == 0 and nf == 0 and umop in (0, 0x0B)
            unmasked = bool((word >> 25) & 1)
            eew = _VMEM_WIDTH_BYTES[(word >> 12) & 7] * 8
            if umop == 0x0B:
                kind = "vlm" if opcode == 0x07 else "vsm"
            else:
                kind = "vle" if opcode == 0x07 else "vse"
            forms_seen.add((kind, eew, unmasked))
            sew = 8 << ((vtype >> 3) & 7)
            lmul = vtype & 7
            if avl_mode == "vlmax":
                regimes_seen.add((kind, "vlmax"))
            elif vl_imm == 0:
                regimes_seen.add((kind, "zero"))
            elif all(vl_imm < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
                regimes_seen.add((kind, "below_vlmax"))
            policies_seen.add((kind, vtype & 0xC0))

    expected_forms = {
        (kind, eew, unmasked)
        for kind in ("vle", "vse")
        for eew in (8, 16, 32, 64)
        for unmasked in (True, False)
    }
    expected_forms.update({("vlm", 8, True), ("vsm", 8, True)})
    assert forms_seen == expected_forms
    for kind in ("vle", "vse", "vlm", "vsm"):
        assert (kind, "below_vlmax") in regimes_seen
        assert (kind, "vlmax") in regimes_seen
    assert ("vle", 0x00) in policies_seen  # tu, mu


@pytest.mark.parametrize(
    ("mutation", "error"),
    [
        pytest.param(
            "vsetvli-after", "missing immediate scalar readback", id="vsetvli"
        ),
        pytest.param(
            "vsetvl-after", "missing immediate scalar readback", id="vsetvl-after"
        ),
        pytest.param("vsetvl-before", "vsetvl", id="vsetvl-before"),
        pytest.param(
            "vstart-after", "missing immediate scalar readback", id="vstart-after"
        ),
        pytest.param("vstart-before", "vstart write", id="vstart-before"),
        pytest.param(
            "drop-readback", "missing immediate scalar readback", id="drop-load"
        ),
        pytest.param(
            "overwrite-before-readback",
            "missing immediate scalar readback",
            id="overwrite",
        ),
        pytest.param(
            "drop-vsm-readback", "missing immediate scalar readback", id="drop-vsm"
        ),
    ],
)
def test_vector_store_readback_covers_each_element(
    tmp_path: Path, mutation: str, error: str
) -> None:
    """Every unit-stride and mask store must read back all bytes immediately."""
    source_trace = VERIF_DIR / "testrig" / "vector_unit_stride.S"
    _check_vector_store_readbacks([source_trace])

    mutated = tmp_path / "vector_unit_stride.S"
    lines = source_trace.read_text().splitlines()
    if mutation == "drop-vsm-readback":
        anchor = next(
            i for i, line in enumerate(lines) if line.startswith(".4byte 0x02b480a7 ")
        )
        # Remove the lbu reading byte 0 after vsm.v.
        drop_idx = next(
            i
            for i in range(anchor + 1, len(lines))
            if lines[i].startswith(".4byte 0x0004c503 ")
        )
        del lines[drop_idx]
    else:
        # Target the first vse8.v v8, (s1) (0x02048427).
        anchor = next(
            i for i, line in enumerate(lines) if line.startswith(".4byte 0x02048427 ")
        )
        first_load = next(
            i
            for i in range(anchor + 1, len(lines))
            if lines[i].startswith(".4byte 0x0004c503 ")
        )
        if mutation == "vsetvli-after":
            lines.insert(
                first_load, ".4byte 0x00007657  # vsetvli a2, zero, e8, m1, tu, mu"
            )
        elif mutation == "vsetvl-after":
            lines.insert(first_load, ".4byte 0x80037057  # vsetvl zero, t1, t0")
        elif mutation == "vsetvl-before":
            lines.insert(anchor, ".4byte 0x80037057  # vsetvl zero, t1, t0")
        elif mutation == "vstart-after":
            lines.insert(first_load, ".4byte 0x00805073  # csrwi vstart, 0")
        elif mutation == "vstart-before":
            lines.insert(anchor, ".4byte 0x00805073  # csrwi vstart, 0")
        elif mutation == "drop-readback":
            del lines[first_load]
        elif mutation == "overwrite-before-readback":
            lines.insert(first_load, ".4byte 0x00648023  # sb t1, 0(s1)")
    mutated.write_text("\n".join(lines) + "\n")
    with pytest.raises(AssertionError, match=error):
        _check_vector_store_readbacks([mutated])


def test_vector_integer_compare_trace_covers_predicates() -> None:
    """Check the e32 predicate forms and e64 equality and ordering."""
    trace = VERIF_DIR / "testrig" / "vector_int_compare.S"
    words = [
        int(line.split()[1], 16)
        for line in trace.read_text().splitlines()
        if line.startswith(".4byte ")
    ]
    configurations = [
        index for index, word in enumerate(words) if word & 0x707F == 0x7057
    ]
    assert [words[index] for index in configurations] == [0xC102_7657, 0xC181_7657]
    _, e64 = configurations
    assert words[e64 + 1] == 0xC210_25F3  # csrr a1, vtype
    vv, vi, vx = 0, 3, 4
    forms = {
        0x18: (vv, vi, vx),  # vmseq
        0x19: (vv, vi, vx),  # vmsne
        0x1A: (vv, vx),  # vmsltu
        0x1B: (vv, vx),  # vmslt
        0x1C: (vv, vi, vx),  # vmsleu
        0x1D: (vv, vi, vx),  # vmsle
        0x1E: (vi, vx),  # vmsgtu
        0x1F: (vi, vx),  # vmsgt
    }
    observed = [
        (
            32 if index < e64 else 64,
            word >> 26,
            (word >> 12) & 7,
            bool(word & (1 << 25)),
        )
        for index, word in enumerate(words)
        if word & 0x7F == 0x57
        and word >> 26 in forms
        and (word >> 12) & 7 in (vv, vi, vx)
    ]
    expected = {
        (32, predicate, form, True)
        for predicate, variants in forms.items()
        for form in variants
    }
    expected.add((32, 0x1B, vx, False))
    expected.update((64, predicate, vv, True) for predicate in (0x18, 0x1A, 0x1B))
    assert len(observed) == len(expected)
    assert set(observed) == expected


def test_vector_strided_trace_covers_forms() -> None:
    """Check strided load/store widths, masking, strides, VL regimes and no misa."""
    trace = VERIF_DIR / "testrig" / "vector_strided.S"
    vtype = 0
    avl_mode = ""
    vl_imm = 0
    reg_val: dict[int, int | None] = {0: 0}
    forms_seen: set[tuple[str, int, bool]] = set()
    regimes_seen: set[tuple[str, str]] = set()
    stride_kinds_seen: set[tuple[str, str]] = set()
    eq_stride_widths: set[tuple[str, int]] = set()
    policies_seen: set[tuple[str, int]] = set()
    for line in trace.read_text().splitlines():
        if not line.startswith(".4byte "):
            continue
        word = int(line.split()[1], 16)
        opcode = word & 0x7F
        if opcode == 0x73 and ((word >> 12) & 7) in (1, 2, 3, 5, 6, 7):
            assert ((word >> 20) & 0xFFF) != 0x301  # No misa access
        elif word & 0xC000_707F == 0xC000_7057:  # vsetivli
            vtype = (word >> 20) & 0xFF
            vl_imm = (word >> 15) & 0x1F
            avl_mode = "imm"
        elif word & 0x8000_707F == 0x0000_7057:  # vsetvli
            vtype = (word >> 20) & 0xFF
            assert ((word >> 15) & 0x1F) == 0 and ((word >> 7) & 0x1F) != 0
            avl_mode = "vlmax"
        elif opcode in (0x07, 0x27) and ((word >> 12) & 7) in _VMEM_WIDTH_BYTES:
            mop = (word >> 26) & 3
            nf = (word >> 29) & 7
            rs2 = (word >> 20) & 0x1F
            assert mop == 2 and nf == 0
            unmasked = bool((word >> 25) & 1)
            elem_bytes = _VMEM_WIDTH_BYTES[(word >> 12) & 7]
            eew = elem_bytes * 8
            kind = "vlse" if opcode == 0x07 else "vsse"
            forms_seen.add((kind, eew, unmasked))
            stride = 0 if rs2 == 0 else reg_val.get(rs2)
            assert stride is not None
            if rs2 == 0:
                stride_kinds_seen.add((kind, "zero_x0"))
            elif stride == 0:
                stride_kinds_seen.add((kind, "zero_reg"))
            elif stride < 0:
                stride_kinds_seen.add((kind, "negative"))
            elif stride == elem_bytes:
                stride_kinds_seen.add((kind, "equal_eew"))
                eq_stride_widths.add((kind, eew))
            else:
                stride_kinds_seen.add((kind, "positive"))
            sew = 8 << ((vtype >> 3) & 7)
            lmul = vtype & 7
            if avl_mode == "vlmax":
                regimes_seen.add((kind, "vlmax"))
            elif vl_imm == 0:
                regimes_seen.add((kind, "zero"))
            elif all(vl_imm < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
                regimes_seen.add((kind, "below_vlmax"))
            policies_seen.add((kind, vtype & 0xC0))
        _update_int_reg_tracking(reg_val, word)

    expected_forms = {
        (kind, eew, unmasked)
        for kind in ("vlse", "vsse")
        for eew in (8, 16, 32, 64)
        for unmasked in (True, False)
    }
    assert forms_seen == expected_forms
    for kind in ("vlse", "vsse"):
        assert (kind, "below_vlmax") in regimes_seen
        assert (kind, "vlmax") in regimes_seen
        for stride_kind in ("positive", "negative", "zero_x0", "zero_reg", "equal_eew"):
            assert (kind, stride_kind) in stride_kinds_seen
        for eew in (8, 16, 32, 64):
            assert (kind, eew) in eq_stride_widths
    assert ("vlse", 0x00) in policies_seen  # tu, mu


@pytest.mark.parametrize(
    ("mutation", "error"),
    [
        pytest.param(
            "vsetvli-after", "missing immediate scalar readback", id="vsetvli"
        ),
        pytest.param(
            "vsetvl-after", "missing immediate scalar readback", id="vsetvl-after"
        ),
        pytest.param("vsetvl-before", "vsetvl", id="vsetvl-before"),
        pytest.param(
            "vstart-after", "missing immediate scalar readback", id="vstart-after"
        ),
        pytest.param("vstart-before", "vstart write", id="vstart-before"),
        pytest.param(
            "drop-pos-readback", "missing immediate scalar readback", id="drop-pos"
        ),
        pytest.param(
            "drop-neg-readback", "missing immediate scalar readback", id="drop-neg"
        ),
        pytest.param(
            "drop-zero-readback", "missing immediate scalar readback", id="drop-zero"
        ),
        pytest.param(
            "overwrite-before-readback",
            "missing immediate scalar readback",
            id="overwrite",
        ),
    ],
)
def test_strided_store_readback_covers_each_element(
    tmp_path: Path, mutation: str, error: str
) -> None:
    """Every strided store must read back all written bytes immediately."""
    source_trace = VERIF_DIR / "testrig" / "vector_strided.S"
    _check_vector_store_readbacks([source_trace])

    mutated = tmp_path / "vector_strided.S"
    lines = source_trace.read_text().splitlines()
    if mutation == "drop-neg-readback":
        anchor = next(
            i for i, line in enumerate(lines) if line.startswith(".4byte 0x0bd98427 ")
        )
        drop_idx = next(
            i
            for i in range(anchor + 1, len(lines))
            if lines[i].startswith(".4byte 0xffd9c503 ")  # lbu a0, -3(s3)
        )
        del lines[drop_idx]
    elif mutation == "drop-zero-readback":
        anchor = next(
            i for i, line in enumerate(lines) if line.startswith(".4byte 0x0a048427 ")
        )
        drop_idx = next(
            i
            for i in range(anchor + 1, len(lines))
            if lines[i].startswith(".4byte 0x0004c503 ")  # lbu a0, 0(s1)
        )
        del lines[drop_idx]
    else:
        anchor = next(
            i for i, line in enumerate(lines) if line.startswith(".4byte 0x0bd48427 ")
        )
        first_load = next(
            i
            for i in range(anchor + 1, len(lines))
            if lines[i].startswith(".4byte 0x0004c503 ")
        )
        if mutation == "vsetvli-after":
            lines.insert(
                first_load, ".4byte 0x00007657  # vsetvli a2, zero, e8, m1, tu, mu"
            )
        elif mutation == "vsetvl-after":
            lines.insert(first_load, ".4byte 0x80037057  # vsetvl zero, t1, t0")
        elif mutation == "vsetvl-before":
            lines.insert(anchor, ".4byte 0x80037057  # vsetvl zero, t1, t0")
        elif mutation == "vstart-after":
            lines.insert(first_load, ".4byte 0x00805073  # csrwi vstart, 0")
        elif mutation == "vstart-before":
            lines.insert(anchor, ".4byte 0x00805073  # csrwi vstart, 0")
        elif mutation == "drop-pos-readback":
            del lines[first_load]
        elif mutation == "overwrite-before-readback":
            lines.insert(first_load, ".4byte 0x00648023  # sb t1, 0(s1)")
    mutated.write_text("\n".join(lines) + "\n")
    with pytest.raises(AssertionError, match=error):
        _check_vector_store_readbacks([mutated])


def test_vector_indexed_trace_covers_forms() -> None:
    """Check indexed load/store widths, ordering, masking, cross-width, VL and no misa."""
    trace = VERIF_DIR / "testrig" / "vector_indexed.S"
    vtype = 0
    avl_mode = ""
    vl_imm = 0
    forms_seen: set[tuple[str, int, bool]] = set()
    regimes_seen: set[tuple[str, str]] = set()
    cross_width_seen: set[tuple[str, str]] = set()
    policies_seen: set[tuple[str, int]] = set()
    in_place_gather = False
    for line in trace.read_text().splitlines():
        if not line.startswith(".4byte "):
            continue
        word = int(line.split()[1], 16)
        opcode = word & 0x7F
        if opcode == 0x73 and ((word >> 12) & 7) in (1, 2, 3, 5, 6, 7):
            assert ((word >> 20) & 0xFFF) != 0x301  # No misa access
        elif word & 0xC000_707F == 0xC000_7057:  # vsetivli
            vtype = (word >> 20) & 0xFF
            vl_imm = (word >> 15) & 0x1F
            avl_mode = "imm"
        elif word & 0x8000_707F == 0x0000_7057:  # vsetvli
            vtype = (word >> 20) & 0xFF
            assert ((word >> 15) & 0x1F) == 0 and ((word >> 7) & 0x1F) != 0
            avl_mode = "vlmax"
        elif opcode in (0x07, 0x27) and ((word >> 12) & 7) in _VMEM_WIDTH_BYTES:
            mop = (word >> 26) & 3
            nf = (word >> 29) & 7
            vs2 = (word >> 20) & 0x1F
            vd = (word >> 7) & 0x1F
            assert mop in (1, 3) and nf == 0
            unmasked = bool((word >> 25) & 1)
            idx_eew = _VMEM_WIDTH_BYTES[(word >> 12) & 7] * 8
            if opcode == 0x07:
                kind = "vluxei" if mop == 1 else "vloxei"
                if vd == vs2:
                    in_place_gather = True
            else:
                kind = "vsuxei" if mop == 1 else "vsoxei"
            forms_seen.add((kind, idx_eew, unmasked))
            sew = 8 << ((vtype >> 3) & 7)
            lmul = vtype & 7
            direction = "load" if opcode == 0x07 else "store"
            if idx_eew < sew:
                cross_width_seen.add((direction, "narrow_idx"))
            elif idx_eew > sew:
                cross_width_seen.add((direction, "wide_idx"))
            if avl_mode == "vlmax":
                regimes_seen.add((kind, "vlmax"))
            elif vl_imm == 0:
                regimes_seen.add((kind, "zero"))
            elif all(vl_imm < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
                regimes_seen.add((kind, "below_vlmax"))
            policies_seen.add((direction, vtype & 0xC0))

    expected_forms = {
        (kind, idx_eew, unmasked)
        for kind in ("vluxei", "vloxei", "vsuxei", "vsoxei")
        for idx_eew in (8, 16, 32, 64)
        for unmasked in (True, False)
    }
    assert forms_seen == expected_forms
    for kind in ("vluxei", "vloxei", "vsuxei", "vsoxei"):
        assert (kind, "below_vlmax") in regimes_seen
        assert (kind, "vlmax") in regimes_seen
    for direction in ("load", "store"):
        assert (direction, "narrow_idx") in cross_width_seen
        assert (direction, "wide_idx") in cross_width_seen
    assert ("load", 0x00) in policies_seen  # tu, mu
    assert ("load", 0xC0) in policies_seen  # ta, ma
    assert in_place_gather


@pytest.mark.parametrize(
    ("mutation", "error"),
    [
        pytest.param(
            "vsetvli-after", "missing immediate scalar readback", id="vsetvli"
        ),
        pytest.param(
            "vsetvl-after", "missing immediate scalar readback", id="vsetvl-after"
        ),
        pytest.param("vsetvl-before", "vsetvl", id="vsetvl-before"),
        pytest.param(
            "vstart-after", "missing immediate scalar readback", id="vstart-after"
        ),
        pytest.param("vstart-before", "vstart write", id="vstart-before"),
        pytest.param(
            "drop-ux-readback", "missing immediate scalar readback", id="drop-ux"
        ),
        pytest.param(
            "drop-ox-readback", "missing immediate scalar readback", id="drop-ox"
        ),
        pytest.param(
            "drop-vlmax-high-readback",
            "missing immediate scalar readback",
            id="drop-vlmax-high",
        ),
        pytest.param(
            "overwrite-before-readback",
            "missing immediate scalar readback",
            id="overwrite",
        ),
    ],
)
def test_indexed_store_readback_covers_each_element(
    tmp_path: Path, mutation: str, error: str
) -> None:
    """Every indexed store must read back all written bytes immediately."""
    source_trace = VERIF_DIR / "testrig" / "vector_indexed.S"
    _check_vector_store_readbacks([source_trace])

    mutated = tmp_path / "vector_indexed.S"
    lines = source_trace.read_text().splitlines()
    if mutation == "drop-ox-readback":
        anchor = next(
            i for i, line in enumerate(lines) if line.startswith(".4byte 0x0f048427 ")
        )
        drop_idx = next(
            i
            for i in range(anchor + 1, len(lines))
            if lines[i].startswith(".4byte 0x0844c503 ")  # lbu a0, 132(s1)
        )
        del lines[drop_idx]
    elif mutation == "drop-vlmax-high-readback":
        # Last masked VLMAX vsuxei32.v v8, (s1), v16, v0.t (0x0504e427).
        anchor = [
            i for i, line in enumerate(lines) if line.startswith(".4byte 0x0504e427 ")
        ][-1]
        drop_idx = next(
            i
            for i in range(anchor + 1, len(lines))
            if lines[i].startswith(".4byte 0x0784b503 ")  # ld a0, 120(s1)
        )
        del lines[drop_idx]
    else:
        anchor = next(
            i for i, line in enumerate(lines) if line.startswith(".4byte 0x07048427 ")
        )
        first_load = next(
            i
            for i in range(anchor + 1, len(lines))
            if lines[i].startswith(".4byte 0x0844c503 ")  # lbu a0, 132(s1)
        )
        if mutation == "vsetvli-after":
            lines.insert(
                first_load, ".4byte 0x00007657  # vsetvli a2, zero, e8, m1, tu, mu"
            )
        elif mutation == "vsetvl-after":
            lines.insert(first_load, ".4byte 0x80037057  # vsetvl zero, t1, t0")
        elif mutation == "vsetvl-before":
            lines.insert(anchor, ".4byte 0x80037057  # vsetvl zero, t1, t0")
        elif mutation == "vstart-after":
            lines.insert(first_load, ".4byte 0x00805073  # csrwi vstart, 0")
        elif mutation == "vstart-before":
            lines.insert(anchor, ".4byte 0x00805073  # csrwi vstart, 0")
        elif mutation == "drop-ux-readback":
            del lines[first_load]
        elif mutation == "overwrite-before-readback":
            lines.insert(first_load, ".4byte 0x08648223  # sb t1, 132(s1)")
    mutated.write_text("\n".join(lines) + "\n")
    with pytest.raises(AssertionError, match=error):
        _check_vector_store_readbacks([mutated])


def test_vector_segment_trace_covers_forms() -> None:
    """Check unit-stride and strided segment field counts, widths, masking and no misa."""
    trace = VERIF_DIR / "testrig" / "vector_segment.S"
    vtype = 0
    avl_mode = ""
    vl_imm = 0
    reg_val: dict[int, int | None] = {0: 0}
    nfields_seen: set[tuple[str, int]] = set()
    width_mask_seen: set[tuple[str, int, bool]] = set()
    regimes_seen: set[tuple[str, str]] = set()
    stride_kinds_seen: set[tuple[str, str]] = set()
    emuls_seen: set[tuple[str, tuple[int, int]]] = set()
    policies_seen: set[tuple[str, int]] = set()
    for line in trace.read_text().splitlines():
        if not line.startswith(".4byte "):
            continue
        word = int(line.split()[1], 16)
        opcode = word & 0x7F
        if opcode == 0x73 and ((word >> 12) & 7) in (1, 2, 3, 5, 6, 7):
            assert ((word >> 20) & 0xFFF) != 0x301  # No misa access
        elif word & 0xC000_707F == 0xC000_7057:  # vsetivli
            vtype = (word >> 20) & 0xFF
            vl_imm = (word >> 15) & 0x1F
            avl_mode = "imm"
        elif word & 0x8000_707F == 0x0000_7057:  # vsetvli
            vtype = (word >> 20) & 0xFF
            assert ((word >> 15) & 0x1F) == 0 and ((word >> 7) & 0x1F) != 0
            avl_mode = "vlmax"
        elif opcode in (0x07, 0x27) and ((word >> 12) & 7) in _VMEM_WIDTH_BYTES:
            mop = (word >> 26) & 3
            nf = (word >> 29) & 7
            rs2_or_umop = (word >> 20) & 0x1F
            assert mop in (0, 2) and 1 <= nf <= 7
            if mop == 0:
                assert rs2_or_umop == 0
            nfields = nf + 1
            unmasked = bool((word >> 25) & 1)
            elem_bytes = _VMEM_WIDTH_BYTES[(word >> 12) & 7]
            eew = elem_bytes * 8
            if mop == 0:
                kind = "vlseg" if opcode == 0x07 else "vsseg"
            else:
                kind = "vlsseg" if opcode == 0x07 else "vssseg"
                stride = 0 if rs2_or_umop == 0 else reg_val.get(rs2_or_umop)
                assert stride is not None
                if rs2_or_umop == 0:
                    stride_kinds_seen.add((kind, "zero_x0"))
                elif stride == 0:
                    stride_kinds_seen.add((kind, "zero_reg"))
                elif stride < 0:
                    stride_kinds_seen.add((kind, "negative"))
                else:
                    stride_kinds_seen.add((kind, "positive"))
            nfields_seen.add((kind, nfields))
            width_mask_seen.add((kind, eew, unmasked))
            sew = 8 << ((vtype >> 3) & 7)
            lmul = vtype & 7
            num, den = _LMUL_NUM_DEN[lmul]
            emul_num = num * eew
            emul_den = den * sew
            if emul_num % emul_den == 0:
                emul_ratio = (emul_num // emul_den, 1)
            else:
                emul_ratio = (1, emul_den // emul_num)
            emuls_seen.add((kind, emul_ratio))
            if avl_mode == "vlmax":
                regimes_seen.add((kind, "vlmax"))
            elif vl_imm == 0:
                regimes_seen.add((kind, "zero"))
            elif all(vl_imm < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
                regimes_seen.add((kind, "below_vlmax"))
            policies_seen.add((kind, vtype & 0xC0))
        _update_int_reg_tracking(reg_val, word)

    for kind in ("vlseg", "vsseg"):
        for nfields in range(2, 9):
            assert (kind, nfields) in nfields_seen
        for regime in ("below_vlmax", "vlmax", "zero"):
            assert (kind, regime) in regimes_seen
    for kind in ("vlsseg", "vssseg"):
        for nfields in (2, 3, 4, 8):
            assert (kind, nfields) in nfields_seen
        for regime in ("below_vlmax", "zero"):
            assert (kind, regime) in regimes_seen
        for stride_kind in ("positive", "negative", "zero_x0", "zero_reg"):
            assert (kind, stride_kind) in stride_kinds_seen
    for kind in ("vlseg", "vsseg", "vlsseg", "vssseg"):
        for eew in (8, 16, 32, 64):
            assert (kind, eew, True) in width_mask_seen
        assert any(k == kind and not unmasked for k, _, unmasked in width_mask_seen)
        assert (kind, (2, 1)) in emuls_seen
    assert ("vlseg", (1, 2)) in emuls_seen and ("vsseg", (1, 2)) in emuls_seen
    assert ("vlseg", 0x00) in policies_seen and ("vlsseg", 0x00) in policies_seen


@pytest.mark.parametrize(
    ("mutation", "error"),
    [
        pytest.param(
            "vsetvli-after", "missing immediate scalar readback", id="vsetvli"
        ),
        pytest.param(
            "vsetvl-after", "missing immediate scalar readback", id="vsetvl-after"
        ),
        pytest.param("vsetvl-before", "vsetvl", id="vsetvl-before"),
        pytest.param(
            "vstart-after", "missing immediate scalar readback", id="vstart-after"
        ),
        pytest.param("vstart-before", "vstart write", id="vstart-before"),
        pytest.param(
            "drop-unit-field",
            "missing immediate scalar readback",
            id="drop-unit-field",
        ),
        pytest.param(
            "drop-strided-field",
            "missing immediate scalar readback",
            id="drop-strided-field",
        ),
        pytest.param(
            "drop-neg-field",
            "missing immediate scalar readback",
            id="drop-neg-field",
        ),
        pytest.param(
            "overwrite-before-readback",
            "missing immediate scalar readback",
            id="overwrite",
        ),
    ],
)
def test_segment_store_readback_covers_each_element(
    tmp_path: Path, mutation: str, error: str
) -> None:
    """Every unit-stride and strided segment store must read back all bytes."""
    source_trace = VERIF_DIR / "testrig" / "vector_segment.S"
    _check_vector_store_readbacks([source_trace])

    mutated = tmp_path / "vector_segment.S"
    lines = source_trace.read_text().splitlines()
    if mutation == "drop-strided-field":
        anchor = next(
            i for i, line in enumerate(lines) if line.startswith(".4byte 0x2bd4e427 ")
        )
        drop_idx = next(
            i
            for i in range(anchor + 1, len(lines))
            if lines[i].startswith(".4byte 0x0044e503 ")  # lwu a0, 4(s1)
        )
        del lines[drop_idx]
    elif mutation == "drop-neg-field":
        anchor = next(
            i for i, line in enumerate(lines) if line.startswith(".4byte 0x4bd9e427 ")
        )
        drop_idx = next(
            i
            for i in range(anchor + 1, len(lines))
            if lines[i].startswith(".4byte 0x0049e503 ")  # lwu a0, 4(s3)
        )
        del lines[drop_idx]
    else:
        anchor = next(
            i for i, line in enumerate(lines) if line.startswith(".4byte 0x2204ef27 ")
        )
        first_load = next(
            i
            for i in range(anchor + 1, len(lines))
            if lines[i].startswith(".4byte 0x0044e503 ")  # lwu a0, 4(s1)
        )
        if mutation == "vsetvli-after":
            lines.insert(
                first_load, ".4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu"
            )
        elif mutation == "vsetvl-after":
            lines.insert(first_load, ".4byte 0x80037057  # vsetvl zero, t1, t0")
        elif mutation == "vsetvl-before":
            lines.insert(anchor, ".4byte 0x80037057  # vsetvl zero, t1, t0")
        elif mutation == "vstart-after":
            lines.insert(first_load, ".4byte 0x00805073  # csrwi vstart, 0")
        elif mutation == "vstart-before":
            lines.insert(anchor, ".4byte 0x00805073  # csrwi vstart, 0")
        elif mutation == "drop-unit-field":
            del lines[first_load]
        elif mutation == "overwrite-before-readback":
            lines.insert(first_load, ".4byte 0x0064a223  # sw t1, 4(s1)")
    mutated.write_text("\n".join(lines) + "\n")
    with pytest.raises(AssertionError, match=error):
        _check_vector_store_readbacks([mutated])


def test_vector_fof_trace_covers_forms() -> None:
    """Check fault-only-first widths, masking, vl trimming, elem-0 traps and no misa."""
    trace = VERIF_DIR / "testrig" / "vector_fof.S"
    blocks = TRACE_WORD.split(trace.read_text())[1:]
    words = [int(block.split()[1], 0) for block in blocks]
    vtype = 0
    avl_mode = ""
    vl_imm = 0
    scalar_fault_checked = False
    trim_widths: set[int] = set()
    trap_widths: set[int] = set()
    masked_trim_seen = False
    masked_trap_seen = False
    masked_no_trim_seen = False
    m2_trim_seen = False
    vlmax_trim_seen = False
    zero_vl_seen = False
    for index, (block, word) in enumerate(zip(blocks, words, strict=True)):
        opcode = word & 0x7F
        if opcode == 0x73 and ((word >> 12) & 7) in (1, 2, 3, 5, 6, 7):
            assert ((word >> 20) & 0xFFF) != 0x301  # No misa access
        elif opcode == 0x03 and re.search(r"(?m)^\.assert trap == 1\b", block):
            scalar_fault_checked = True
        elif word & 0xC000_707F == 0xC000_7057:  # vsetivli
            vtype = (word >> 20) & 0xFF
            vl_imm = (word >> 15) & 0x1F
            avl_mode = "imm"
        elif word & 0x8000_707F == 0x0000_7057:  # vsetvli
            vtype = (word >> 20) & 0xFF
            assert ((word >> 15) & 0x1F) == 0 and ((word >> 7) & 0x1F) != 0
            avl_mode = "vlmax"
        elif opcode == 0x07 and ((word >> 12) & 7) in _VMEM_WIDTH_BYTES:
            mop = (word >> 26) & 3
            nf = (word >> 29) & 7
            lumop = (word >> 20) & 0x1F
            assert mop == 0 and nf == 0 and lumop == 0x10
            unmasked = bool((word >> 25) & 1)
            eew = _VMEM_WIDTH_BYTES[(word >> 12) & 7] * 8
            lmul = vtype & 7
            assert not test_testrig.run_stats.is_vector_store(word)
            if re.search(r"(?m)^\.assert trap == 1\b", block):
                if unmasked:
                    trap_widths.add(eew)
                else:
                    masked_trap_seen = True
            else:
                assert re.search(r"(?m)^\.assert trap == 0\b", block)
                if avl_mode == "imm" and vl_imm == 0:
                    zero_vl_seen = True
                    continue
                # Find the following csrr ..., vl assertion before the next vset*
                vl_read = None
                for scan in range(index + 1, len(words)):
                    next_w = words[scan]
                    if (next_w & 0x707F) == 0x7057:
                        break
                    if (next_w & 0xFFF0_707F) == 0xC200_2073:  # csrr rd, vl
                        m = re.search(
                            r"(?m)^\.assert rd_wdata == (0x[0-9a-f]+)\b", blocks[scan]
                        )
                        assert m is not None
                        vl_read = int(m.group(1), 16)
                        break
                assert vl_read is not None
                if avl_mode == "vlmax":
                    if vl_read < 4:
                        vlmax_trim_seen = True
                elif vl_read < vl_imm:
                    if unmasked:
                        trim_widths.add(eew)
                        if lmul == 1:
                            m2_trim_seen = True
                    else:
                        masked_trim_seen = True
                elif not unmasked and vl_read == vl_imm:
                    masked_no_trim_seen = True

    assert scalar_fault_checked
    assert trim_widths == {8, 16, 32, 64}
    assert trap_widths == {8, 16, 32, 64}
    assert masked_trim_seen and masked_trap_seen and masked_no_trim_seen
    assert m2_trim_seen and vlmax_trim_seen and zero_vl_seen


def test_vector_int_widen_narrow_trace_covers_forms() -> None:
    """Check all 41 widening, extending and narrowing integer encodings and corners."""
    trace = VERIF_DIR / "testrig" / "vector_int_widen_narrow.S"
    blocks = TRACE_WORD.split(trace.read_text())[1:]
    vtype = 0
    avl_mode = ""
    vl_imm = 0
    retired_forms: set[tuple[str, int, int, int | None]] = set()
    sews_by_group: dict[str, set[int]] = {}
    ext_sews: dict[int, set[int]] = {}
    masking_by_group: dict[str, set[bool]] = {}
    regimes_by_group: dict[str, set[str]] = {}
    policies_seen: set[int] = set()
    lmuls_seen: set[int] = set()
    overlaps_seen: set[str] = set()
    traps_seen = 0
    ctrl_count = 0

    ivv, mvv, ivi, ivx, mvx = 0, 2, 3, 4, 6
    wadd_f6 = {0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37}
    wmul_f6 = {0x38, 0x3A, 0x3B}
    wmacc_f6 = {0x3C, 0x3D, 0x3E, 0x3F}
    narrow_f6 = {0x2C, 0x2D}

    for block in blocks:
        assert block.lstrip().startswith(".4byte ")
        word = int(block.split()[1], 16)
        if word == 0x42E0_2557:
            ctrl_count += 1
        opcode = word & 0x7F
        if opcode == 0x73 and ((word >> 12) & 7) in (1, 2, 3, 5, 6, 7):
            assert ((word >> 20) & 0xFFF) != 0x301  # No misa access
            continue
        if word & 0xC000_707F == 0xC000_7057:  # vsetivli
            vtype = (word >> 20) & 0xFF
            vl_imm = (word >> 15) & 0x1F
            avl_mode = "imm"
            continue
        if word & 0x8000_707F == 0x0000_7057:  # vsetvli
            vtype = (word >> 20) & 0xFF
            assert ((word >> 15) & 0x1F) == 0 and ((word >> 7) & 0x1F) != 0
            avl_mode = "vlmax"
            continue
        if opcode != 0x57:
            continue

        f6 = word >> 26
        f3 = (word >> 12) & 7
        vm = bool((word >> 25) & 1)
        vs2 = (word >> 20) & 0x1F
        vs1 = (word >> 15) & 0x1F
        vd = (word >> 7) & 0x1F
        sew = 8 << ((vtype >> 3) & 7)
        lmul = vtype & 7

        group = ""
        sub: int | None = None
        if f3 in (mvv, mvx) and f6 in wadd_f6:
            group = "wadd"
        elif f3 == mvv and f6 == 0x12 and 2 <= vs1 <= 7:
            group = "ext"
            sub = vs1
        elif f3 in (ivv, ivi, ivx) and f6 in narrow_f6:
            group = "narrow"
        elif f3 in (mvv, mvx) and f6 in wmul_f6:
            group = "wmul"
        elif f3 in (mvv, mvx) and f6 in wmacc_f6:
            group = "wmacc"
        else:
            continue

        if re.search(r"(?m)^\.assert trap == 1\b", block):
            traps_seen += 1
            continue
        assert re.search(r"(?m)^\.assert trap == 0\b", block)

        retired_forms.add((group, f6, f3, sub))
        sews_by_group.setdefault(group, set()).add(sew)
        if group == "ext" and sub is not None:
            ext_sews.setdefault(sub, set()).add(sew)
        masking_by_group.setdefault(group, set()).add(vm)
        policies_seen.add(vtype & 0xC0)
        lmuls_seen.add(lmul)

        if avl_mode == "vlmax":
            regimes_by_group.setdefault(group, set()).add("vlmax")
        elif vl_imm == 0:
            regimes_by_group.setdefault(group, set()).add("zero")
        elif all(vl_imm < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
            regimes_by_group.setdefault(group, set()).add("below_vlmax")

        if group == "wadd" and f6 in {0x30, 0x31, 0x32, 0x33} and vs2 == vd + 1:
            overlaps_seen.add("wadd_upper")
        if group == "wadd" and f6 in {0x34, 0x35, 0x36, 0x37} and vs2 == vd:
            overlaps_seen.add("wadd_inplace")
        if group == "ext" and vs2 == vd + 1:
            overlaps_seen.add("ext_upper")
        if group == "narrow" and vs2 == vd:
            overlaps_seen.add("narrow_low")

    expected_forms: set[tuple[str, int, int, int | None]] = set()
    expected_forms.update(("wadd", f6, f3, None) for f6 in wadd_f6 for f3 in (mvv, mvx))
    expected_forms.update(("ext", 0x12, mvv, sub) for sub in range(2, 8))
    expected_forms.update(
        ("narrow", f6, f3, None) for f6 in narrow_f6 for f3 in (ivv, ivi, ivx)
    )
    expected_forms.update(("wmul", f6, f3, None) for f6 in wmul_f6 for f3 in (mvv, mvx))
    expected_forms.update(
        ("wmacc", f6, f3, None) for f6 in (0x3C, 0x3D, 0x3F) for f3 in (mvv, mvx)
    )
    expected_forms.add(("wmacc", 0x3E, mvx, None))
    assert len(expected_forms) == 41
    assert retired_forms == expected_forms

    for group in ("wadd", "narrow", "wmul", "wmacc"):
        assert sews_by_group[group] == {8, 16, 32}
    assert ext_sews == {
        2: {64},
        3: {64},
        4: {32, 64},
        5: {32, 64},
        6: {16, 32, 64},
        7: {16, 32, 64},
    }
    for group in ("wadd", "ext", "narrow", "wmul", "wmacc"):
        assert masking_by_group[group] == {True, False}
        assert {"below_vlmax", "vlmax", "zero"} <= regimes_by_group[group]
    assert {0x00, 0xC0} <= policies_seen  # tu, mu and ta, ma
    assert {0, 1, 7} <= lmuls_seen  # m1, m2, mf2
    assert overlaps_seen == {"wadd_upper", "wadd_inplace", "ext_upper", "narrow_low"}
    assert traps_seen == 5
    assert ctrl_count == 1


def test_vector_fixed_point_trace_covers_forms() -> None:
    """Check fixed-point forms, rounding modes, saturation and illegal overlap traps."""
    trace = VERIF_DIR / "testrig" / "vector_fixed_point.S"
    raw_lines = [
        line
        for line in trace.read_text().splitlines()
        if line.startswith((".4byte ", ".assert "))
    ]
    blocks: list[str] = []
    for line in raw_lines:
        if line.startswith(".4byte "):
            blocks.append(line)
        else:
            blocks[-1] += "\n" + line

    vtype = 0
    avl_mode = ""
    vl_imm = 0
    vxrm = 0
    retired_forms: set[tuple[str, int, int]] = set()
    sews_by_group: dict[str, set[int]] = {}
    masking_by_group: dict[str, set[bool]] = {}
    regimes_by_group: dict[str, set[str]] = {}
    vxrm_by_group: dict[str, set[int]] = {}
    vxrm_readbacks_checked: set[int] = set()
    pending_vxrm_readback: int | None = None
    vxsat_checked: set[int] = set()
    policies_seen: set[int] = set()
    lmuls_seen: set[int] = set()
    overlaps_seen: set[str] = set()
    trap_kinds: set[str] = set()
    traps_seen = 0
    ctrl_count = 0

    ivv, mvv, ivi, ivx, mvx = 0, 2, 3, 4, 6
    sat_f6 = {0x20, 0x21, 0x22, 0x23}
    avg_f6 = {0x08, 0x09, 0x0A, 0x0B}
    sshift_f6 = {0x2A, 0x2B}
    nclip_f6 = {0x2E, 0x2F}

    for block in blocks:
        assert block.lstrip().startswith(".4byte ")
        word = int(block.split()[1], 16)
        if word == 0x42F0_2557:
            ctrl_count += 1
        opcode = word & 0x7F
        is_vxrm_read = (
            opcode == 0x73
            and ((word >> 12) & 7) == 2
            and ((word >> 20) & 0xFFF) == 0x00A
        )
        if pending_vxrm_readback is not None:
            assert is_vxrm_read, "every vxrm write must be followed by csrr vxrm"
            assert f'rd_wdata == {pending_vxrm_readback:#x} "' in block
            vxrm_readbacks_checked.add(pending_vxrm_readback)
            pending_vxrm_readback = None
            continue
        if opcode == 0x73 and ((word >> 12) & 7) in (1, 2, 3, 5, 6, 7):
            csr = (word >> 20) & 0xFFF
            assert csr != 0x301  # No misa access
            if csr == 0x00A and ((word >> 12) & 7) == 5:  # csrwi vxrm, uimm
                vxrm = (word >> 15) & 3
                pending_vxrm_readback = vxrm
            if csr == 0x009 and ((word >> 12) & 7) == 2:  # csrr a0, vxsat
                if 'rd_wdata == 0x0 "' in block:
                    vxsat_checked.add(0)
                if 'rd_wdata == 0x1 "' in block:
                    vxsat_checked.add(1)
            continue
        if word & 0xC000_707F == 0xC000_7057:  # vsetivli
            vtype = (word >> 20) & 0xFF
            vl_imm = (word >> 15) & 0x1F
            avl_mode = "imm"
            continue
        if word & 0x8000_707F == 0x0000_7057:  # vsetvli
            vtype = (word >> 20) & 0xFF
            assert ((word >> 15) & 0x1F) == 0 and ((word >> 7) & 0x1F) != 0
            avl_mode = "vlmax"
            continue
        if opcode != 0x57:
            continue

        f6 = word >> 26
        f3 = (word >> 12) & 7
        vm = bool((word >> 25) & 1)
        vs2 = (word >> 20) & 0x1F
        vs1 = (word >> 15) & 0x1F
        vd = (word >> 7) & 0x1F
        sew = 8 << ((vtype >> 3) & 7)
        lmul = vtype & 7

        if re.search(r"(?m)^\.assert trap == 1\b", block):
            traps_seen += 1
            if f3 == mvv and f6 == 0x30 and vd == vs2 and lmul == 0:
                trap_kinds.add("widen_low_vs2")
            elif f3 == mvv and f6 == 0x3B and vd == vs1 and lmul == 0:
                trap_kinds.add("widen_low_vs1")
            elif f3 == mvv and f6 == 0x30 and vd == vs2 and lmul == 7:
                trap_kinds.add("widen_frac")
            elif f3 == mvv and f6 == 0x3C and vs2 == vd + 1:
                trap_kinds.add("wmacc_upper")
            elif f3 == ivv and f6 == 0x2E and vd == vs2 + 1:
                trap_kinds.add("nclip_upper")
            elif f3 == ivv and f6 == 0x20 and not vm and vd == 0:
                trap_kinds.add("masked_v0")
            elif f3 == ivv and f6 == 0x2E and sew == 64:
                trap_kinds.add("nclip_e64")
            elif f3 == ivi and f6 == 0x2F and lmul == 3:
                trap_kinds.add("nclip_m8")
            continue

        group = ""
        if f3 in (ivv, ivi, ivx) and f6 in sat_f6:
            group = "sat"
        elif f3 in (mvv, mvx) and f6 in avg_f6:
            group = "avg"
        elif f3 in (ivv, ivx) and f6 == 0x27:
            group = "smul"
        elif f3 in (ivv, ivi, ivx) and f6 in sshift_f6:
            group = "sshift"
        elif f3 in (ivv, ivi, ivx) and f6 in nclip_f6:
            group = "nclip"
        else:
            continue

        assert re.search(r"(?m)^\.assert trap == 0\b", block)
        retired_forms.add((group, f6, f3))
        sews_by_group.setdefault(group, set()).add(sew)
        masking_by_group.setdefault(group, set()).add(vm)
        vxrm_by_group.setdefault(group, set()).add(vxrm)
        policies_seen.add(vtype & 0xC0)
        lmuls_seen.add(lmul)

        if avl_mode == "vlmax":
            regimes_by_group.setdefault(group, set()).add("vlmax")
        elif vl_imm == 0:
            regimes_by_group.setdefault(group, set()).add("zero")
        elif all(vl_imm < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
            regimes_by_group.setdefault(group, set()).add("below_vlmax")

        if group == "sat" and vd == vs2:
            overlaps_seen.add("sat_inplace")
        if group == "nclip" and vd == vs2:
            overlaps_seen.add("nclip_low")

    expected_forms: set[tuple[str, int, int]] = set()
    expected_forms.update(
        ("sat", f6, f3) for f6 in (0x20, 0x21) for f3 in (ivv, ivi, ivx)
    )
    expected_forms.update(("sat", f6, f3) for f6 in (0x22, 0x23) for f3 in (ivv, ivx))
    expected_forms.update(("avg", f6, f3) for f6 in avg_f6 for f3 in (mvv, mvx))
    expected_forms.update(("smul", 0x27, f3) for f3 in (ivv, ivx))
    expected_forms.update(
        ("sshift", f6, f3) for f6 in sshift_f6 for f3 in (ivv, ivi, ivx)
    )
    expected_forms.update(
        ("nclip", f6, f3) for f6 in nclip_f6 for f3 in (ivv, ivi, ivx)
    )
    assert len(expected_forms) == 32
    assert retired_forms == expected_forms

    for group in ("sat", "avg", "smul", "sshift"):
        assert sews_by_group[group] == {8, 16, 32, 64}
    assert sews_by_group["nclip"] == {8, 16, 32}
    for group in ("sat", "avg", "smul", "sshift", "nclip"):
        assert masking_by_group[group] == {True, False}
        assert {"below_vlmax", "vlmax", "zero"} <= regimes_by_group[group]
    for group in ("avg", "smul", "sshift", "nclip"):
        assert vxrm_by_group[group] == {0, 1, 2, 3}
    assert pending_vxrm_readback is None
    assert vxrm_readbacks_checked == {0, 1, 2, 3}
    assert vxsat_checked == {0, 1}
    assert {0x00, 0xC0} <= policies_seen  # tu, mu and ta, ma
    assert {0, 1, 7} <= lmuls_seen  # m1, m2, mf2
    assert overlaps_seen == {"sat_inplace", "nclip_low"}
    assert traps_seen == 8
    assert trap_kinds == {
        "widen_low_vs2",
        "widen_low_vs1",
        "widen_frac",
        "wmacc_upper",
        "nclip_upper",
        "masked_v0",
        "nclip_e64",
        "nclip_m8",
    }
    assert ctrl_count == 1


def test_vector_fp_single_trace_covers_forms() -> None:
    """Check single-width FP forms, frm readbacks, flags, classes and traps."""
    trace = VERIF_DIR / "testrig" / "vector_fp_single.S"
    raw_lines = [
        line
        for line in trace.read_text().splitlines()
        if line.startswith((".4byte ", ".assert "))
    ]
    blocks: list[str] = []
    for line in raw_lines:
        if line.startswith(".4byte "):
            blocks.append(line)
        else:
            blocks[-1] += "\n" + line

    vtype = 0
    avl_mode = ""
    vl_imm = 0
    frm = 0
    retired_forms: set[tuple[str, int, int, int | None]] = set()
    sews_by_group: dict[str, set[int]] = {}
    masking_by_group: dict[str, set[bool]] = {}
    regimes_by_group: dict[str, set[str]] = {}
    frm_by_group: dict[str, set[int]] = {}
    frm_by_muldiv_op: dict[str, set[int]] = {}
    frm_readbacks_checked: set[int] = set()
    pending_frm_readback: int | None = None
    fflags_checked: set[int] = set()
    vfclass_bits: dict[int, set[int]] = {32: set(), 64: set()}
    in_vfclass_readback = False
    policies_seen: set[int] = set()
    lmuls_seen: set[int] = set()
    inplace_seen = False
    trap_kinds: set[str] = set()
    traps_seen = 0
    ctrl_count = 0

    opfvv, opfvf = 1, 5
    addsub_f6 = {0x00, 0x02, 0x27}
    muldiv_f6 = {0x20, 0x21, 0x24}
    minmax_f6 = {0x04, 0x06}
    sgnj_f6 = {0x08, 0x09, 0x0A}

    for block in blocks:
        assert block.lstrip().startswith(".4byte ")
        word = int(block.split()[1], 16)
        if word == 0x42D0_2557:
            ctrl_count += 1
        opcode = word & 0x7F
        is_frm_read = (
            opcode == 0x73
            and ((word >> 12) & 7) == 2
            and ((word >> 20) & 0xFFF) == 0x002
        )
        if pending_frm_readback is not None:
            assert is_frm_read, "every frm write must be followed by csrr frm"
            assert f'rd_wdata == {pending_frm_readback:#x} "' in block
            frm_readbacks_checked.add(pending_frm_readback)
            pending_frm_readback = None
            continue
        if opcode == 0x73 and ((word >> 12) & 7) in (1, 2, 3, 5, 6, 7):
            csr = (word >> 20) & 0xFFF
            assert csr != 0x301  # No misa access
            if csr == 0x002 and ((word >> 12) & 7) == 5:  # csrwi frm, uimm
                frm = (word >> 15) & 7
                pending_frm_readback = frm
            elif csr == 0x003 and ((word >> 12) & 7) == 5:  # csrwi fcsr, uimm
                frm = ((word >> 15) & 0x1F) >> 5
            elif csr == 0x001 and ((word >> 12) & 7) == 2:  # csrr a1, fflags
                m = re.search(r'(?m)^\.assert rd_wdata == (0x[0-9a-f]+) "', block)
                if m is not None:
                    fflags_checked.add(int(m.group(1), 16))
            continue
        if word & 0xC000_707F == 0xC000_7057:  # vsetivli
            vtype = (word >> 20) & 0xFF
            vl_imm = (word >> 15) & 0x1F
            avl_mode = "imm"
            continue
        if word & 0x8000_707F == 0x0000_7057:  # vsetvli
            vtype = (word >> 20) & 0xFF
            assert ((word >> 15) & 0x1F) == 0 and ((word >> 7) & 0x1F) != 0
            avl_mode = "vlmax"
            continue
        if opcode != 0x57:
            continue

        f6 = word >> 26
        f3 = (word >> 12) & 7
        vm = bool((word >> 25) & 1)
        vs2 = (word >> 20) & 0x1F
        vs1 = (word >> 15) & 0x1F
        vd = (word >> 7) & 0x1F
        sew = 8 << ((vtype >> 3) & 7)
        lmul = vtype & 7

        if in_vfclass_readback and f6 == 0x10 and f3 == 2 and vs1 == 0:
            m = re.search(r'(?m)^\.assert rd_wdata == (0x[0-9a-f]+) "', block)
            if m is not None:
                val = int(m.group(1), 16)
                if val in {1 << k for k in range(10)} and sew in vfclass_bits:
                    vfclass_bits[sew].add(val)
            continue

        if f3 not in (opfvv, opfvf):
            continue

        in_vfclass_readback = False

        if re.search(r"(?m)^\.assert trap == 1\b", block):
            traps_seen += 1
            if f6 == 0x00 and f3 == opfvv and sew == 8:
                trap_kinds.add("e8_fp")
            elif f6 == 0x02 and f3 == opfvv and frm == 5:
                trap_kinds.add("reserved_frm")
            elif f6 == 0x04 and f3 == opfvv and not vm and vd == 0:
                trap_kinds.add("masked_v0")
            elif f6 == 0x00 and f3 == opfvv and lmul == 1 and (vd & 1):
                trap_kinds.add("misaligned_m2")
            elif f6 == 0x17 and f3 == opfvf and vm and vs2 != 0:
                trap_kinds.add("reserved_vfmv_vf")
            elif f6 == 0x10 and f3 == opfvf and not vm:
                trap_kinds.add("reserved_vfmv_sf")
            continue

        group = ""
        sub: int | None = None
        if f6 in addsub_f6:
            group = "addsub"
        elif f6 in muldiv_f6 or (f6 == 0x13 and f3 == opfvv and vs1 == 0):
            group = "muldivsqrt"
            sub = vs1 if f6 == 0x13 else None
        elif f6 == 0x13 and f3 == opfvv and vs1 in (4, 5):
            group = "estimate"
            sub = vs1
        elif f6 in minmax_f6:
            group = "minmax"
        elif f6 in sgnj_f6:
            group = "sgnj"
        elif f6 == 0x13 and f3 == opfvv and vs1 == 16:
            group = "classify"
            sub = vs1
            in_vfclass_readback = True
        elif f6 == 0x17 and f3 == opfvf:
            group = "mergemove"
            sub = 1 if vm else 0
        elif f6 == 0x10 and ((f3 == opfvf and vs2 == 0) or (f3 == opfvv and vs1 == 0)):
            group = "mergemove"
            sub = 0
        else:
            continue

        assert re.search(r"(?m)^\.assert trap == 0\b", block)
        retired_forms.add((group, f6, f3, sub))
        sews_by_group.setdefault(group, set()).add(sew)
        masking_by_group.setdefault(group, set()).add(vm)
        frm_by_group.setdefault(group, set()).add(frm)
        if f6 == 0x24:
            frm_by_muldiv_op.setdefault("vfmul", set()).add(frm)
        elif f6 == 0x20:
            frm_by_muldiv_op.setdefault("vfdiv", set()).add(frm)
        elif f6 == 0x21:
            frm_by_muldiv_op.setdefault("vfrdiv", set()).add(frm)
        elif f6 == 0x13 and f3 == opfvv and vs1 == 0:
            frm_by_muldiv_op.setdefault("vfsqrt", set()).add(frm)
        policies_seen.add(vtype & 0xC0)
        lmuls_seen.add(lmul)

        if avl_mode == "vlmax":
            regimes_by_group.setdefault(group, set()).add("vlmax")
        elif vl_imm == 0:
            regimes_by_group.setdefault(group, set()).add("zero")
        elif all(vl_imm < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
            regimes_by_group.setdefault(group, set()).add("below_vlmax")

        if group == "addsub" and vd == vs2:
            inplace_seen = True

    expected_forms: set[tuple[str, int, int, int | None]] = {
        ("addsub", 0x00, opfvv, None),
        ("addsub", 0x00, opfvf, None),
        ("addsub", 0x02, opfvv, None),
        ("addsub", 0x02, opfvf, None),
        ("addsub", 0x27, opfvf, None),
        ("muldivsqrt", 0x24, opfvv, None),
        ("muldivsqrt", 0x24, opfvf, None),
        ("muldivsqrt", 0x20, opfvv, None),
        ("muldivsqrt", 0x20, opfvf, None),
        ("muldivsqrt", 0x21, opfvf, None),
        ("muldivsqrt", 0x13, opfvv, 0),
        ("estimate", 0x13, opfvv, 4),
        ("estimate", 0x13, opfvv, 5),
        ("minmax", 0x04, opfvv, None),
        ("minmax", 0x04, opfvf, None),
        ("minmax", 0x06, opfvv, None),
        ("minmax", 0x06, opfvf, None),
        ("sgnj", 0x08, opfvv, None),
        ("sgnj", 0x08, opfvf, None),
        ("sgnj", 0x09, opfvv, None),
        ("sgnj", 0x09, opfvf, None),
        ("sgnj", 0x0A, opfvv, None),
        ("sgnj", 0x0A, opfvf, None),
        ("classify", 0x13, opfvv, 16),
        ("mergemove", 0x17, opfvf, 0),
        ("mergemove", 0x17, opfvf, 1),
        ("mergemove", 0x10, opfvf, 0),
        ("mergemove", 0x10, opfvv, 0),
    }
    assert len(expected_forms) == 28
    assert retired_forms == expected_forms

    all_groups = (
        "addsub",
        "muldivsqrt",
        "estimate",
        "minmax",
        "sgnj",
        "classify",
        "mergemove",
    )
    for group in all_groups:
        assert sews_by_group[group] == {32, 64}
        assert masking_by_group[group] == {True, False}
        assert {"below_vlmax", "vlmax", "zero"} <= regimes_by_group[group]
    assert frm_by_group["addsub"] == {0, 1, 2, 3, 4}
    assert frm_by_group["muldivsqrt"] == {0, 1, 2, 3, 4}
    assert frm_by_group["estimate"] == {0, 1, 2, 3, 4}
    for op_name in ("vfmul", "vfdiv", "vfrdiv", "vfsqrt"):
        assert frm_by_muldiv_op[op_name] == {0, 1, 2, 3, 4}
    assert pending_frm_readback is None
    assert frm_readbacks_checked == {0, 1, 2, 3, 4, 5}
    assert 0 in fflags_checked
    fflags_or = 0
    for bits in fflags_checked:
        fflags_or |= bits
    assert fflags_or == 0x1F
    all_classes = {1 << k for k in range(10)}
    assert vfclass_bits[32] == all_classes
    assert vfclass_bits[64] == all_classes
    assert {0x00, 0xC0} <= policies_seen  # tu, mu and ta, ma
    assert {0, 1, 7} <= lmuls_seen  # m1, m2, mf2
    assert inplace_seen
    assert traps_seen == 6
    assert trap_kinds == {
        "e8_fp",
        "reserved_frm",
        "masked_v0",
        "misaligned_m2",
        "reserved_vfmv_vf",
        "reserved_vfmv_sf",
    }
    assert ctrl_count == 1


def test_vector_whole_reg_trace_covers_forms() -> None:
    """Check all 20 whole-register forms, mode independence, vstart and traps."""
    trace = VERIF_DIR / "testrig" / "vector_whole_reg.S"
    blocks = TRACE_WORD.split(trace.read_text())[1:]
    words = [int(block.split()[1], 0) for block in blocks]
    reg_val: dict[int, int | None] = {0: 0}
    vill = False
    vl_zero = False
    sew = 0
    lmul = 0
    vtype_raw = 0
    retired_forms: set[tuple[str, int, int]] = set()
    vill_retiring: set[str] = set()
    vl0_retiring: set[str] = set()
    vl0_faults: set[str] = set()
    mismatched_vtype_retiring: set[str] = set()
    odd_addr_retiring: set[str] = set()
    non8_load_offsets: set[tuple[int, int]] = set()
    page_cross_retiring: set[str] = set()
    p1_fault_vstarts: dict[int, int] = {}
    p1_resumed: set[int] = set()
    p0_store_fault_seen = False
    illegal_traps: set[str] = set()
    vill_csr_checks = 0
    ctrl_count = 0
    pending_p1_eew: int | None = None

    for idx, (block, word) in enumerate(zip(blocks, words, strict=True)):
        if word == 0x42C0_2557:  # vmv.x.s a0, v12 control
            ctrl_count += 1
        opcode = word & 0x7F
        if opcode == 0x73 and ((word >> 12) & 7) in (1, 2, 3, 5, 6, 7):
            csr = (word >> 20) & 0xFFF
            assert csr != 0x301  # No misa access
            rs1_or_uimm = (word >> 15) & 0x1F
            f3 = (word >> 12) & 7
            assert not (csr == 0x008 and (f3 in (1, 5) or rs1_or_uimm != 0))
            if csr == 0xC21 and f3 == 2:  # csrr vtype
                if re.search(r'(?m)^\.assert rd_wdata == 0x8000000000000000 "', block):
                    vill_csr_checks += 1
            elif csr == 0x008 and f3 == 2 and pending_p1_eew is not None:  # csrr vstart
                m = re.search(r'(?m)^\.assert rd_wdata == (0x[0-9a-f]+) "', block)
                if m is not None:
                    val = int(m.group(1), 16)
                    if val > 0:
                        p1_fault_vstarts[pending_p1_eew] = val
                    elif val == 0 and pending_p1_eew in p1_fault_vstarts:
                        p1_resumed.add(pending_p1_eew)
                        pending_p1_eew = None
        elif word & 0xC000_707F == 0xC000_7057:  # vsetivli
            vtype_raw = (word >> 20) & 0xFF
            uimm = (word >> 15) & 0x1F
            sew_code = (vtype_raw >> 3) & 7
            sew = 8 << sew_code
            lmul = vtype_raw & 7
            vill = (
                sew_code > 3
                or lmul not in _LMUL_NUM_DEN
                or sew * _LMUL_NUM_DEN[lmul][1] > 64 * _LMUL_NUM_DEN[lmul][0]
            )
            vl_zero = vill or uimm == 0
        elif word & 0x8000_707F == 0x0000_7057:  # vsetvli
            vtype_raw = (word >> 20) & 0xFF
            assert ((word >> 15) & 0x1F) == 0 and ((word >> 7) & 0x1F) != 0
            sew_code = (vtype_raw >> 3) & 7
            sew = 8 << sew_code
            lmul = vtype_raw & 7
            vill = (
                sew_code > 3
                or lmul not in _LMUL_NUM_DEN
                or sew * _LMUL_NUM_DEN[lmul][1] > 64 * _LMUL_NUM_DEN[lmul][0]
            )
            vl_zero = vill
        elif opcode in (0x07, 0x27) and ((word >> 12) & 7) in _VMEM_WIDTH_BYTES:
            mop = (word >> 26) & 3
            umop = (word >> 20) & 0x1F
            assert mop == 0 and umop == 0x08
            nf = (word >> 29) & 7
            nr = nf + 1
            mew = (word >> 28) & 1
            vm = (word >> 25) & 1
            width = (word >> 12) & 7
            eew = _VMEM_WIDTH_BYTES[width] * 8
            vd = (word >> 7) & 0x1F
            rs1 = (word >> 15) & 0x1F
            base = reg_val.get(rs1)
            kind = "vl" if opcode == 0x07 else "vs"
            if re.search(r"(?m)^\.assert trap == 1\b", block):
                if mew == 1:
                    illegal_traps.add(f"{kind}_mew1")
                elif vm == 0:
                    illegal_traps.add(f"{kind}_vm0")
                elif kind == "vs" and width != 0:
                    illegal_traps.add(f"vs_width_{eew}")
                elif nf not in (0, 1, 3, 7):
                    illegal_traps.add(f"{kind}_nf{nf}")
                elif (vd & nf) != 0:
                    illegal_traps.add(
                        f"{kind}_misalign_nr{nr}{'_vill' if vill else ''}"
                    )
                elif base == 0xC000_0000:
                    if vl_zero and not vill:
                        vl0_faults.add(kind)
                    elif kind == "vs":
                        p0_store_fault_seen = True
                elif base == 0xBFFF_FFF8 and kind == "vl" and nr == 1:
                    pending_p1_eew = eew
            else:
                assert re.search(r"(?m)^\.assert trap == 0\b", block)
                assert mew == 0 and vm == 1 and nf in (0, 1, 3, 7) and (vd & nf) == 0
                if kind == "vs":
                    assert width == 0
                retired_forms.add((kind, nr, eew))
                if vill:
                    vill_retiring.add(f"{kind}{nr}")
                elif vl_zero:
                    vl0_retiring.add(f"{kind}{nr}")
                if sew == 8 and lmul == 5 and (vtype_raw & 0xC0) == 0xC0:
                    mismatched_vtype_retiring.add(f"{kind}{nr}")
                assert base is not None
                addr = base & 0xFFFF_FFFF_FFFF_FFFF
                if addr & 1:
                    odd_addr_retiring.add(f"{kind}{nr}")
                if kind == "vl" and nr == 1 and (addr & 7) in (2, 4):
                    non8_load_offsets.add((eew, addr & 7))
                if (addr & 0xFFF) == 0xFF8:
                    page_cross_retiring.add(f"{kind}{nr}")
        _update_int_reg_tracking(reg_val, word)

    expected_forms = {
        ("vl", nr, eew) for nr in (1, 2, 4, 8) for eew in (8, 16, 32, 64)
    } | {("vs", nr, 8) for nr in (1, 2, 4, 8)}
    assert len(expected_forms) == 20
    assert retired_forms == expected_forms
    assert vill_csr_checks >= 2
    assert {"vl1", "vs1", "vl2", "vs2"} <= vill_retiring
    assert {"vl1", "vs1"} <= vl0_retiring
    assert vl0_faults == {"vl", "vs"}
    assert {"vl2", "vs2"} <= mismatched_vtype_retiring
    assert {"vl1", "vs1"} <= odd_addr_retiring
    assert {(16, 2), (32, 4)} <= non8_load_offsets
    assert {"vl2", "vs2"} <= page_cross_retiring
    assert p1_fault_vstarts == {8: 8, 16: 4, 32: 2, 64: 1}
    assert p1_resumed == {8, 16, 32, 64}
    assert p0_store_fault_seen
    expected_illegal_traps = {
        "vl_misalign_nr2_vill",
        "vs_misalign_nr2_vill",
        "vl_misalign_nr2",
        "vl_misalign_nr4",
        "vl_misalign_nr8",
        "vs_misalign_nr2",
        "vs_misalign_nr4",
        "vs_misalign_nr8",
        "vl_nf2",
        "vl_nf4",
        "vl_nf5",
        "vl_nf6",
        "vs_nf2",
        "vs_nf4",
        "vs_nf5",
        "vs_nf6",
        "vl_vm0",
        "vs_vm0",
        "vs_width_16",
        "vs_width_32",
        "vs_width_64",
        "vl_mew1",
        "vs_mew1",
    }
    assert illegal_traps == expected_illegal_traps
    assert ctrl_count == 1


@pytest.mark.parametrize(
    ("mutation", "error"),
    [
        pytest.param(
            "drop-always-active",
            "missing immediate scalar readback",
            id="drop-always-active",
        ),
        pytest.param(
            "drop-vlen512-byte",
            "missing immediate scalar readback",
            id="drop-vlen512-byte",
        ),
        pytest.param(
            "drop-odd-byte",
            "missing immediate scalar readback",
            id="drop-odd-byte",
        ),
        pytest.param(
            "drop-vill-readback",
            "missing immediate scalar readback",
            id="drop-vill-readback",
        ),
        pytest.param(
            "drop-assert",
            "missing rd_wdata assertion",
            id="drop-assert",
        ),
        pytest.param(
            "overwrite-before-readback",
            "missing immediate scalar readback",
            id="overwrite",
        ),
        pytest.param("vstart-before", "vstart write", id="vstart-before"),
        pytest.param("vsetvl-before", "vsetvl", id="vsetvl-before"),
    ],
)
def test_whole_reg_store_readback_covers_each_element(
    tmp_path: Path, mutation: str, error: str
) -> None:
    """Every retiring whole-register store must read back all written bytes."""
    source_trace = VERIF_DIR / "testrig" / "vector_whole_reg.S"
    _check_vector_store_readbacks([source_trace])

    mutated = tmp_path / "vector_whole_reg.S"
    lines = source_trace.read_text().splitlines()
    if mutation == "drop-vlen512-byte":
        # Target vs8r.v v16, (s4) (0xe28a0827) and drop its last 512-bit dw readback (504(s4)).
        anchor = next(
            i for i, line in enumerate(lines) if line.startswith(".4byte 0xe28a0827 ")
        )
        drop_idx = next(
            i for i in range(anchor + 1, len(lines)) if "# ld a0, 504(s4)" in lines[i]
        )
        del lines[drop_idx]
    elif mutation == "drop-odd-byte":
        # Target odd-address vs1r.v v8, (s5) (0x028a8427) and drop byte 63 readback.
        anchor = next(
            i
            for i, line in enumerate(lines)
            if line.startswith(".4byte 0x028a8427 ") and "odd-address" in lines[i + 1]
        )
        drop_idx = next(
            i for i in range(anchor + 1, len(lines)) if "# lbu a0, 63(s5)" in lines[i]
        )
        del lines[drop_idx]
    elif mutation == "drop-vill-readback":
        # Target vs1r.v v8, (s5) under vill=1 and drop its first readback.
        anchor = next(
            i
            for i, line in enumerate(lines)
            if line.startswith(".4byte 0x028a8427 ") and "vill1" in lines[i + 1]
        )
        drop_idx = next(
            i for i in range(anchor + 1, len(lines)) if "# ld a0, 0(s5)" in lines[i]
        )
        del lines[drop_idx]
    elif mutation == "drop-assert":
        # Target vs1r.v v8, (s1) (0x02848427) and remove rd_wdata assertion on offset 0.
        anchor = next(
            i
            for i, line in enumerate(lines)
            if line.startswith(".4byte 0x02848427 ") and "base" in lines[i + 1]
        )
        drop_idx = next(
            i
            for i in range(anchor + 1, len(lines))
            if lines[i].startswith(".assert rd_wdata == ")
        )
        del lines[drop_idx]
    else:
        anchor = next(
            i
            for i, line in enumerate(lines)
            if line.startswith(".4byte 0x02848427 ") and "base" in lines[i + 1]
        )
        first_load = next(
            i for i in range(anchor + 1, len(lines)) if "# ld a0, 0(s1)" in lines[i]
        )
        if mutation == "drop-always-active":
            del lines[first_load]
        elif mutation == "overwrite-before-readback":
            lines.insert(first_load, ".4byte 0x0064b023  # sd t1, 0(s1)")
        elif mutation == "vstart-before":
            lines.insert(anchor, ".4byte 0x00805073  # csrwi vstart, 0")
        elif mutation == "vsetvl-before":
            lines.insert(anchor, ".4byte 0x80037057  # vsetvl zero, t1, t0")
    mutated.write_text("\n".join(lines) + "\n")
    with pytest.raises(AssertionError, match=error):
        _check_vector_store_readbacks([mutated])


def test_vector_fp_widen_trace_covers_forms() -> None:
    """Check all 18 widening FP encodings, all 5 frm modes, flags, LMULs, overlaps and traps."""
    trace = VERIF_DIR / "testrig" / "vector_fp_widen.S"
    blocks = TRACE_WORD.split(trace.read_text())[1:]
    opfvv, opfvf = 0b001, 0b101
    widen_f6s = {
        0x30: "waddsub",
        0x32: "waddsub",
        0x34: "waddsub_w",
        0x36: "waddsub_w",
        0x38: "wmul",
        0x3C: "wfma",
        0x3D: "wfma",
        0x3E: "wfma",
        0x3F: "wfma",
    }
    vtype = 0
    vill = False
    avl_mode = ""
    vl_imm = 0
    frm = 0
    pending_frm_readback: int | None = None
    frm_readbacks_checked: set[int] = set()
    retired_forms: set[tuple[int, int]] = set()
    frm_by_op: dict[tuple[int, int], set[int]] = {}
    masking_by_group: dict[str, set[bool]] = {}
    regimes_by_group: dict[str, set[str]] = {}
    policies_seen: set[int] = set()
    lmuls_seen: set[int] = set()
    fflags_checked: set[int] = set()
    legal_overlaps: set[str] = set()
    trap_kinds: set[str] = set()
    traps_seen = 0
    ctrl_count = 0

    for block in blocks:
        word = int(block.split()[1], 0)
        if word == 0x42A0_2557:  # vmv.x.s a0, v10 control
            ctrl_count += 1
        opcode = word & 0x7F
        if pending_frm_readback is not None:
            assert (
                opcode == 0x73
                and ((word >> 12) & 7) == 2
                and ((word >> 20) & 0xFFF) == 0x002
            ), f"expected csrr frm after csrwi frm={pending_frm_readback}"
            assert re.search(
                rf'(?m)^\.assert rd_wdata == {pending_frm_readback:#x} "', block
            )
            frm_readbacks_checked.add(pending_frm_readback)
            pending_frm_readback = None
            continue
        if opcode == 0x73 and ((word >> 12) & 7) in (1, 2, 3, 5, 6, 7):
            csr = (word >> 20) & 0xFFF
            f3 = (word >> 12) & 7
            rs1_or_uimm = (word >> 15) & 0x1F
            assert csr != 0x301  # No misa access
            assert not (csr == 0x008 and (f3 in (1, 5) or rs1_or_uimm != 0))
            if csr == 0x002 and f3 == 5:  # csrwi frm, uimm
                frm = rs1_or_uimm & 7
                pending_frm_readback = frm
            elif csr == 0x001 and f3 == 2:  # csrr fflags
                m = re.search(r'(?m)^\.assert rd_wdata == (0x[0-9a-f]+) "', block)
                if m is not None:
                    fflags_checked.add(int(m.group(1), 16))
            continue
        if word & 0xC000_707F == 0xC000_7057:  # vsetivli
            vtype = (word >> 20) & 0xFF
            vl_imm = (word >> 15) & 0x1F
            avl_mode = "imm"
            sew_code = (vtype >> 3) & 7
            lmul = vtype & 7
            sew = 8 << sew_code
            vill = (
                sew_code > 3
                or lmul not in _LMUL_NUM_DEN
                or sew * _LMUL_NUM_DEN[lmul][1] > 64 * _LMUL_NUM_DEN[lmul][0]
            )
            continue
        if word & 0x8000_707F == 0x0000_7057:  # vsetvli
            vtype = (word >> 20) & 0xFF
            assert ((word >> 15) & 0x1F) == 0 and ((word >> 7) & 0x1F) != 0
            avl_mode = "vlmax"
            sew_code = (vtype >> 3) & 7
            lmul = vtype & 7
            sew = 8 << sew_code
            vill = (
                sew_code > 3
                or lmul not in _LMUL_NUM_DEN
                or sew * _LMUL_NUM_DEN[lmul][1] > 64 * _LMUL_NUM_DEN[lmul][0]
            )
            continue
        if opcode != 0x57:
            continue
        f6 = word >> 26
        f3 = (word >> 12) & 7
        if f3 not in (opfvv, opfvf) or f6 not in widen_f6s:
            continue
        vm = bool((word >> 25) & 1)
        vs2 = (word >> 20) & 0x1F
        vs1 = (word >> 15) & 0x1F
        vd = (word >> 7) & 0x1F
        sew = 8 << ((vtype >> 3) & 7)
        lmul = vtype & 7
        group = widen_f6s[f6]

        if re.search(r"(?m)^\.assert trap == 1\b", block):
            traps_seen += 1
            if vill:
                trap_kinds.add("vill")
            elif sew == 64:
                trap_kinds.add("sew64")
            elif sew == 8:
                trap_kinds.add("sew8")
            elif lmul == 3:
                trap_kinds.add("lmul_m8")
            elif frm == 5:
                trap_kinds.add("reserved_frm")
            elif not vm and vd == 0:
                trap_kinds.add("masked_v0")
            elif not vm and vs2 == 0:
                trap_kinds.add("masked_vs2_v0")
            elif lmul == 0 and (vd & 1):
                trap_kinds.add("misaligned_vd")
            elif group == "waddsub_w" and lmul == 0 and (vs2 & 1):
                trap_kinds.add("misaligned_vs2")
            elif group == "waddsub_w" and f3 == opfvv and (vs1 & ~1) == (vs2 & ~1):
                trap_kinds.add("wide_src_overlap")
            elif group == "wfma" and f3 == opfvv and (vs2 & ~1) == (vd & ~1):
                trap_kinds.add("fwfma_vs2_overlap")
            elif group == "wfma" and f3 == opfvv and (vs1 & ~1) == (vd & ~1):
                trap_kinds.add("fwfma_vs1_overlap")
            elif lmul == 7 and vd == vs2:
                trap_kinds.add("mf2_overlap")
            elif lmul == 0 and vd == vs2:
                trap_kinds.add("low_half_overlap")
            continue

        assert re.search(r"(?m)^\.assert trap == 0\b", block)
        assert not vill and sew == 32
        retired_forms.add((f6, f3))
        frm_by_op.setdefault((f6, f3), set()).add(frm)
        masking_by_group.setdefault(group, set()).add(vm)
        policies_seen.add(vtype & 0xC0)
        lmuls_seen.add(lmul)
        if avl_mode == "vlmax":
            regimes_by_group.setdefault(group, set()).add("vlmax")
        elif vl_imm == 0:
            regimes_by_group.setdefault(group, set()).add("zero")
        elif all(vl_imm < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
            regimes_by_group.setdefault(group, set()).add("below_vlmax")
        if group == "waddsub" and vs2 == vd + 1:
            legal_overlaps.add("upper_vs2")
        elif group == "wmul" and f3 == opfvv and vs1 == vd + 1:
            legal_overlaps.add("upper_vs1")
        elif group == "waddsub_w" and vd == vs2:
            legal_overlaps.add("inplace_wide")

    expected_forms = {(f6, f3) for f6 in widen_f6s for f3 in (opfvv, opfvf)}
    assert len(expected_forms) == 18
    assert retired_forms == expected_forms
    for f6, f3 in expected_forms:
        if (
            f6 != 0x38
        ):  # All 16 rounding-capable widening encodings cover all 5 frm modes
            assert frm_by_op[(f6, f3)] == {0, 1, 2, 3, 4}, (
                hex(f6),
                f3,
                frm_by_op[(f6, f3)],
            )
    assert pending_frm_readback is None
    assert frm_readbacks_checked == {0, 1, 2, 3, 4, 5}
    for group in ("waddsub", "waddsub_w", "wmul", "wfma"):
        assert masking_by_group[group] == {True, False}
        assert {"below_vlmax", "vlmax", "zero"} <= regimes_by_group[group]
    assert {0x00, 0x01, 0x05, 0x10} <= fflags_checked
    assert {0x00, 0xC0} <= policies_seen
    assert {7, 0, 1, 2} <= lmuls_seen  # mf2, m1, m2, m4
    assert legal_overlaps == {"upper_vs2", "upper_vs1", "inplace_wide"}
    assert traps_seen == 14
    assert trap_kinds == {
        "sew64",
        "sew8",
        "lmul_m8",
        "reserved_frm",
        "misaligned_vd",
        "misaligned_vs2",
        "masked_v0",
        "masked_vs2_v0",
        "low_half_overlap",
        "mf2_overlap",
        "wide_src_overlap",
        "fwfma_vs2_overlap",
        "fwfma_vs1_overlap",
        "vill",
    }
    assert ctrl_count == 1


def test_vector_permutes_trace_covers_forms() -> None:
    """Check all 17 permute encodings, widths, modes, corners and traps."""
    trace = VERIF_DIR / "testrig" / "vector_permutes.S"
    text = trace.read_text()
    blocks = TRACE_WORD.split(text)[1:]
    assert blocks

    opivv, opmvv, opivi, opivx, opfvf, opmvx = 0, 2, 3, 4, 5, 6
    retired_forms: set[tuple[str, int, int, int | None]] = set()
    sews_by_group: dict[str, set[int]] = {}
    ei16_sews: set[int] = set()
    masking_by_group: dict[str, set[bool]] = {}
    regimes_by_group: dict[str, set[str]] = {}
    policies_seen: set[int] = set()
    lmuls_seen: set[int] = set()
    uimm5_high_ops: set[tuple[int, int]] = set()
    inplace_ops: set[str] = set()
    ei16_self_e16 = False
    compress_v0_mask = False
    fflags_zero_checked = False
    trap_kinds: set[str] = set()
    traps_seen = 0
    ctrl_count = 0

    vtype = 0
    vill = False
    avl_mode = "imm"
    vl_imm = 0

    for block in blocks:
        word_match = re.match(r"^\.4byte (0x[0-9a-f]{8})\b", block)
        assert word_match is not None
        word = int(word_match.group(1), 16)
        opcode = word & 0x7F
        f3 = (word >> 12) & 0x7

        if word == 0x42B0_2557:
            ctrl_count += 1

        if opcode == 0x73 and f3 == 2:
            csr = (word >> 20) & 0xFFF
            if csr == 0x001 and re.search(r'(?m)^\.assert rd_wdata == 0x0 "', block):
                fflags_zero_checked = True
            continue

        if opcode != 0x57:
            continue

        if f3 == 7:
            if (word >> 30) == 0b11:
                vtype = (word >> 20) & 0x3FF
                vl_imm = (word >> 15) & 0x1F
                avl_mode = "imm"
            else:
                vtype = (word >> 20) & 0x7FF
                rs1 = (word >> 15) & 0x1F
                rd = (word >> 7) & 0x1F
                avl_mode = "vlmax" if rs1 == 0 and rd != 0 else "reg"
            sew_code = (vtype >> 3) & 7
            lmul_code = vtype & 7
            vill = (
                sew_code > 3
                or lmul_code == 4
                or (lmul_code in (5, 6, 7) and (lmul_code - 8) < (sew_code - 3))
            )
            continue

        f6 = (word >> 26) & 0x3F
        vm = bool((word >> 25) & 1)
        vs2 = (word >> 20) & 0x1F
        vs1 = (word >> 15) & 0x1F
        vd = (word >> 7) & 0x1F
        sew = 8 << ((vtype >> 3) & 7)
        lmul = vtype & 7

        if re.search(r"(?m)^\.assert trap == 1\b", block):
            traps_seen += 1
            if vill and f6 == 0x0E and f3 == opivi:
                trap_kinds.add("slide_vill")
            elif vill and f6 == 0x27 and f3 == opivi:
                trap_kinds.add("vmvr_vill")
            elif f6 == 0x0E and f3 == opivx and vd == vs2:
                trap_kinds.add("vslideup_overlap")
            elif f6 == 0x0E and f3 == opmvx and vd == vs2:
                trap_kinds.add("vslide1up_overlap")
            elif f6 == 0x0E and f3 == opfvf and sew == 8:
                trap_kinds.add("vfslide1_e8")
            elif f6 == 0x0E and f3 == opfvf and vd == vs2:
                trap_kinds.add("vfslide1up_overlap")
            elif f6 == 0x0C and f3 == opivv and vd == vs2:
                trap_kinds.add("vrgather_vd_vs2")
            elif f6 == 0x0C and f3 == opivv and vd == vs1:
                trap_kinds.add("vrgather_vd_vs1")
            elif f6 == 0x0E and f3 == opivv and sew == 8 and lmul == 3:
                trap_kinds.add("ei16_emul16")
            elif f6 == 0x0E and f3 == opivv and sew == 32 and vs2 == vs1:
                trap_kinds.add("ei16_src_overlap")
            elif (
                f6 == 0x0E and f3 == opivv and sew == 32 and lmul == 1 and vs1 == vd + 1
            ):
                trap_kinds.add("ei16_vd_vs1")
            elif f6 == 0x0E and f3 == opivv and sew == 8 and lmul == 0 and (vs1 & 1):
                trap_kinds.add("ei16_misaligned_vs1")
            elif f6 == 0x17 and f3 == opmvv and not vm:
                trap_kinds.add("compress_vm0")
            elif f6 == 0x17 and f3 == opmvv and vd == vs2:
                trap_kinds.add("compress_vd_vs2")
            elif f6 == 0x17 and f3 == opmvv and vd == vs1:
                trap_kinds.add("compress_vd_vs1")
            elif f6 == 0x17 and f3 == opmvv and vs2 == vs1:
                trap_kinds.add("compress_vs2_vs1")
            elif f6 == 0x27 and f3 == opivi and not vm:
                trap_kinds.add("vmvr_vm0")
            elif f6 == 0x27 and f3 == opivi and vs1 == 2:
                trap_kinds.add("vmvr_reserved_nr")
            elif f6 == 0x27 and f3 == opivi and vs1 == 1 and (vd & 1):
                trap_kinds.add("vmvr_misaligned_vd")
            elif f6 == 0x27 and f3 == opivi and vs1 == 3 and (vs2 & 3):
                trap_kinds.add("vmvr_misaligned_vs2")
            elif f6 == 0x0F and f3 == opivi and not vm and vd == 0:
                trap_kinds.add("masked_v0_dst")
            elif f6 == 0x0C and f3 == opivi and not vm and vs2 == 0:
                trap_kinds.add("masked_v0_vs2")
            continue

        # Only count explicitly asserted permute test instructions (ignore readback vslidedown helpers)
        if not re.search(r"(?m)^\.assert trap == 0\b", block):
            continue

        group = ""
        sub: int | None = None
        if f6 in (0x0E, 0x0F) and f3 in (opivx, opivi):
            group = "slide"
        elif f6 in (0x0E, 0x0F) and f3 == opmvx:
            group = "slide1_int"
        elif f6 in (0x0E, 0x0F) and f3 == opfvf:
            group = "slide1_fp"
        elif (f6 == 0x0C and f3 in (opivv, opivx, opivi)) or (
            f6 == 0x0E and f3 == opivv
        ):
            group = "gather"
        elif f6 == 0x17 and f3 == opmvv:
            group = "compress"
        elif f6 == 0x27 and f3 == opivi:
            group = "whole_move"
            sub = vs1
        else:
            continue

        retired_forms.add((group, f6, f3, sub))
        sews_by_group.setdefault(group, set()).add(sew)
        if f6 == 0x0E and f3 == opivv:
            ei16_sews.add(sew)
            if sew == 16 and vs2 == vs1:
                ei16_self_e16 = True
        masking_by_group.setdefault(group, set()).add(vm)
        policies_seen.add(vtype & 0xC0)
        lmuls_seen.add(lmul)

        if avl_mode == "vlmax":
            regimes_by_group.setdefault(group, set()).add("vlmax")
        elif vl_imm == 0:
            regimes_by_group.setdefault(group, set()).add("zero")
        elif all(vl_imm < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
            regimes_by_group.setdefault(group, set()).add("below_vlmax")

        if f3 == opivi and f6 in (0x0C, 0x0E, 0x0F) and vs1 >= 16:
            uimm5_high_ops.add((f6, vs1))
        if vd == vs2:
            if f6 == 0x0F and f3 in (opivx, opivi):
                inplace_ops.add("vslidedown")
            elif f6 == 0x0F and f3 == opmvx:
                inplace_ops.add("vslide1down")
            elif f6 == 0x0F and f3 == opfvf:
                inplace_ops.add("vfslide1down")
            elif f6 == 0x27 and f3 == opivi:
                inplace_ops.add("vmvr")
        if group == "compress" and vs1 == 0:
            compress_v0_mask = True

    expected_forms: set[tuple[str, int, int, int | None]] = {
        ("slide", 0x0E, opivx, None),
        ("slide", 0x0E, opivi, None),
        ("slide", 0x0F, opivx, None),
        ("slide", 0x0F, opivi, None),
        ("slide1_int", 0x0E, opmvx, None),
        ("slide1_int", 0x0F, opmvx, None),
        ("slide1_fp", 0x0E, opfvf, None),
        ("slide1_fp", 0x0F, opfvf, None),
        ("gather", 0x0C, opivv, None),
        ("gather", 0x0C, opivx, None),
        ("gather", 0x0C, opivi, None),
        ("gather", 0x0E, opivv, None),
        ("compress", 0x17, opmvv, None),
        ("whole_move", 0x27, opivi, 0),
        ("whole_move", 0x27, opivi, 1),
        ("whole_move", 0x27, opivi, 3),
        ("whole_move", 0x27, opivi, 7),
    }
    assert len(expected_forms) == 17
    assert retired_forms == expected_forms

    for group in ("slide", "slide1_int", "gather", "compress", "whole_move"):
        assert sews_by_group[group] == {8, 16, 32, 64}
    assert sews_by_group["slide1_fp"] == {32, 64}
    assert ei16_sews == {8, 16, 32, 64}

    for group in ("slide", "slide1_int", "slide1_fp", "gather"):
        assert masking_by_group[group] == {True, False}
    for group in ("compress", "whole_move"):
        assert masking_by_group[group] == {True}

    for group in (
        "slide",
        "slide1_int",
        "slide1_fp",
        "gather",
        "compress",
        "whole_move",
    ):
        assert {"below_vlmax", "vlmax", "zero"} <= regimes_by_group[group]

    assert {0x00, 0xC0} <= policies_seen  # tu, mu and ta, ma
    assert {0, 1, 2, 5, 6, 7} <= lmuls_seen  # m1, m2, m4, mf8, mf4, mf2
    assert {
        (0x0E, 16),
        (0x0F, 16),
        (0x0F, 31),
        (0x0C, 16),
        (0x0C, 31),
    } <= uimm5_high_ops
    assert inplace_ops == {"vslidedown", "vslide1down", "vfslide1down", "vmvr"}
    assert ei16_self_e16
    assert compress_v0_mask
    assert fflags_zero_checked
    assert traps_seen == 22
    assert trap_kinds == {
        "vslideup_overlap",
        "vslide1up_overlap",
        "vfslide1up_overlap",
        "vrgather_vd_vs2",
        "vrgather_vd_vs1",
        "ei16_emul16",
        "ei16_src_overlap",
        "ei16_vd_vs1",
        "ei16_misaligned_vs1",
        "compress_vd_vs2",
        "compress_vd_vs1",
        "compress_vs2_vs1",
        "compress_vm0",
        "vmvr_misaligned_vd",
        "vmvr_misaligned_vs2",
        "vmvr_reserved_nr",
        "vmvr_vm0",
        "masked_v0_dst",
        "masked_v0_vs2",
        "vfslide1_e8",
        "slide_vill",
        "vmvr_vill",
    }
    assert ctrl_count == 1


def test_vector_reductions_trace_covers_forms() -> None:
    """Check all 16 base-V reduction encodings, widths, frm modes, corners and traps."""
    trace = VERIF_DIR / "testrig" / "vector_reductions.S"
    text = trace.read_text()
    blocks = TRACE_WORD.split(text)[1:]
    assert blocks

    opivv, opfvv, opmvv = 0, 1, 2
    int_red_f6 = set(range(8))
    wint_red_f6 = {0x30, 0x31}
    fp_red_f6 = {0x01, 0x03, 0x05, 0x07}
    wfp_red_f6 = {0x31, 0x33}
    fp_sum_ops = {(0x01, opfvv), (0x03, opfvv), (0x31, opfvv), (0x33, opfvv)}

    retired_forms: set[tuple[str, int, int]] = set()
    sews_by_group: dict[str, set[int]] = {}
    masking_by_group: dict[str, set[bool]] = {}
    regimes_by_group: dict[str, set[str]] = {}
    frm_by_op: dict[tuple[int, int], set[int]] = {}
    frm_readbacks_checked: set[int] = set()
    fflags_checked: set[int] = set()
    policies_seen: set[int] = set()
    lmuls_seen: set[int] = set()
    legal_overlaps: set[str] = set()
    widen_m8_groups: set[str] = set()
    trap_kinds: set[str] = set()
    traps_seen = 0
    ctrl_count = 0

    vtype = 0
    vill = False
    avl_mode = "imm"
    vl_imm = 0
    frm = 0
    pending_frm_readback: int | None = None

    for block in blocks:
        word_match = re.match(r"^\.4byte (0x[0-9a-f]{8})\b", block)
        assert word_match is not None
        word = int(word_match.group(1), 16)
        opcode = word & 0x7F
        f3 = (word >> 12) & 0x7

        if word == 0x4320_2557:
            ctrl_count += 1

        if pending_frm_readback is not None:
            assert opcode == 0x73 and f3 == 2 and ((word >> 20) & 0xFFF) == 0x002
            m = re.search(r'(?m)^\.assert rd_wdata == (0x[0-9a-f]+) "', block)
            assert m is not None and int(m.group(1), 16) == pending_frm_readback
            frm_readbacks_checked.add(pending_frm_readback)
            pending_frm_readback = None
            continue

        if opcode == 0x73 and f3 in (1, 2, 3, 5, 6, 7):
            csr = (word >> 20) & 0xFFF
            uimm = (word >> 15) & 0x1F
            assert csr != 0x301  # No misa access
            assert not (csr == 0x008 and (f3 in (1, 5) or uimm != 0))
            if csr == 0x002 and f3 == 5:
                frm = uimm & 7
                pending_frm_readback = frm
            elif csr == 0x001 and f3 == 2:
                m = re.search(r'(?m)^\.assert rd_wdata == (0x[0-9a-f]+) "', block)
                if m is not None:
                    fflags_checked.add(int(m.group(1), 16))
            continue

        if opcode != 0x57:
            continue

        if f3 == 7:
            if (word >> 30) == 0b11:
                vtype = (word >> 20) & 0x3FF
                vl_imm = (word >> 15) & 0x1F
                avl_mode = "imm"
            else:
                vtype = (word >> 20) & 0x7FF
                rs1 = (word >> 15) & 0x1F
                rd = (word >> 7) & 0x1F
                avl_mode = "vlmax" if rs1 == 0 and rd != 0 else "reg"
            sew_code = (vtype >> 3) & 7
            lmul_code = vtype & 7
            vill = (
                sew_code > 3
                or lmul_code == 4
                or (lmul_code in (5, 6, 7) and (lmul_code - 8) < (sew_code - 3))
            )
            continue

        f6 = (word >> 26) & 0x3F
        vm = bool((word >> 25) & 1)
        vs2 = (word >> 20) & 0x1F
        vs1 = (word >> 15) & 0x1F
        vd = (word >> 7) & 0x1F
        sew = 8 << ((vtype >> 3) & 7)
        lmul = vtype & 7

        group = ""
        if f3 == opmvv and f6 in int_red_f6:
            group = "int_red"
        elif f3 == opivv and f6 in wint_red_f6:
            group = "wint_red"
        elif f3 == opfvv and f6 in fp_red_f6:
            group = "fp_red"
        elif f3 == opfvv and f6 in wfp_red_f6:
            group = "wfp_red"
        else:
            continue

        if re.search(r"(?m)^\.assert trap == 1\b", block):
            traps_seen += 1
            if vill:
                trap_kinds.add("vill")
            elif frm == 5 and group == "fp_red":
                trap_kinds.add("reserved_frm")
            elif group == "wint_red" and sew == 64:
                trap_kinds.add("vwredsumu_e64" if f6 == 0x30 else "vwredsum_e64")
            elif group == "wfp_red" and sew == 64:
                trap_kinds.add("vfwredusum_e64" if f6 == 0x31 else "vfwredosum_e64")
            elif group == "fp_red" and sew == 8:
                trap_kinds.add("vfredosum_e8")
            elif group == "wfp_red" and sew == 8:
                trap_kinds.add("vfwredosum_e8")
            elif group == "wint_red" and vs1 == vs2:
                trap_kinds.add("vwred_src_overlap")
            elif group == "wfp_red" and vs1 == vs2:
                trap_kinds.add("vfwred_src_overlap")
            elif group == "int_red" and not vm and vs2 == 0:
                trap_kinds.add("int_masked_vs2_v0")
            elif group == "int_red" and not vm and vs1 == 0:
                trap_kinds.add("int_masked_vs1_v0")
            elif group == "fp_red" and not vm and vs2 == 0:
                trap_kinds.add("fp_masked_vs2_v0")
            elif group == "fp_red" and not vm and vs1 == 0:
                trap_kinds.add("fp_masked_vs1_v0")
            elif group == "int_red" and lmul == 1 and (vs2 & 1):
                trap_kinds.add("misaligned_vs2_m2")
            continue

        assert re.search(r"(?m)^\.assert trap == 0\b", block)
        assert not vill
        retired_forms.add((group, f6, f3))
        sews_by_group.setdefault(group, set()).add(sew)
        masking_by_group.setdefault(group, set()).add(vm)
        policies_seen.add(vtype & 0xC0)
        lmuls_seen.add(lmul)

        if (f6, f3) in fp_sum_ops:
            frm_by_op.setdefault((f6, f3), set()).add(frm)
        if avl_mode == "vlmax":
            regimes_by_group.setdefault(group, set()).add("vlmax")
        elif vl_imm == 0:
            regimes_by_group.setdefault(group, set()).add("zero")
        elif all(vl_imm < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
            regimes_by_group.setdefault(group, set()).add("below_vlmax")

        if vd == vs2 == vs1:
            legal_overlaps.add(f"{group}_self")
        if not vm and vd == 0:
            legal_overlaps.add(f"{group}_masked_v0")
        if lmul == 3 and group in ("wint_red", "wfp_red") and (vd & 1):
            widen_m8_groups.add(group)

    expected_forms: set[tuple[str, int, int]] = (
        {("int_red", f6, opmvv) for f6 in int_red_f6}
        | {("wint_red", f6, opivv) for f6 in wint_red_f6}
        | {("fp_red", f6, opfvv) for f6 in fp_red_f6}
        | {("wfp_red", f6, opfvv) for f6 in wfp_red_f6}
    )
    assert len(expected_forms) == 16
    assert retired_forms == expected_forms

    assert sews_by_group["int_red"] == {8, 16, 32, 64}
    assert sews_by_group["wint_red"] == {8, 16, 32}
    assert sews_by_group["fp_red"] == {32, 64}
    assert sews_by_group["wfp_red"] == {32}

    for group in ("int_red", "wint_red", "fp_red", "wfp_red"):
        assert masking_by_group[group] == {True, False}
        assert {"below_vlmax", "vlmax", "zero"} <= regimes_by_group[group]

    for op_key in fp_sum_ops:
        assert frm_by_op[op_key] == {0, 1, 2, 3, 4}, (op_key, frm_by_op[op_key])
    assert pending_frm_readback is None
    assert frm_readbacks_checked == {0, 1, 2, 3, 4, 5}
    assert {0x00, 0x01, 0x05, 0x10} <= fflags_checked
    assert {0x00, 0xC0} <= policies_seen
    assert {0, 1, 3, 5, 6, 7} <= lmuls_seen
    assert {
        "int_red_self",
        "fp_red_self",
        "int_red_masked_v0",
        "wint_red_masked_v0",
        "fp_red_masked_v0",
        "wfp_red_masked_v0",
    } <= legal_overlaps
    assert widen_m8_groups == {"wint_red", "wfp_red"}
    assert traps_seen == 15
    assert trap_kinds == {
        "vwredsumu_e64",
        "vwredsum_e64",
        "vfwredusum_e64",
        "vfwredosum_e64",
        "vfredosum_e8",
        "vfwredosum_e8",
        "vwred_src_overlap",
        "vfwred_src_overlap",
        "int_masked_vs2_v0",
        "int_masked_vs1_v0",
        "fp_masked_vs2_v0",
        "fp_masked_vs1_v0",
        "misaligned_vs2_m2",
        "reserved_frm",
        "vill",
    }
    assert ctrl_count == 1


def test_vector_carry_borrow_trace_covers_forms() -> None:
    """Check all 15 base-V carry/borrow encodings, widths, simm5, overlaps and traps."""
    trace = VERIF_DIR / "testrig" / "vector_carry_borrow.S"
    text = trace.read_text()
    blocks = TRACE_WORD.split(text)[1:]
    assert blocks

    opivv, opivi, opivx = 0, 3, 4
    expected_forms: set[tuple[int, int, int]] = {
        (0x10, 0, opivv),
        (0x10, 0, opivx),
        (0x10, 0, opivi),
        (0x11, 0, opivv),
        (0x11, 0, opivx),
        (0x11, 0, opivi),
        (0x11, 1, opivv),
        (0x11, 1, opivx),
        (0x11, 1, opivi),
        (0x12, 0, opivv),
        (0x12, 0, opivx),
        (0x13, 0, opivv),
        (0x13, 0, opivx),
        (0x13, 1, opivv),
        (0x13, 1, opivx),
    }

    retired_forms: set[tuple[int, int, int]] = set()
    sews_by_form: dict[tuple[int, int, int], set[int]] = {}
    simm5_seen: set[tuple[int, int, int]] = set()
    regimes_seen: set[str] = set()
    policies_seen: set[int] = set()
    lmuls_seen: set[int] = set()
    legal_overlaps: set[str] = set()
    vxsat_zero_checks = 0
    traps_seen = 0
    trap_kinds: set[str] = set()
    ctrl_count = 0
    multibyte_mask_vl = False

    vtype = 0
    vill = False
    avl_mode = "imm"
    vl_imm = 0

    for block in blocks:
        word_match = re.match(r"^\.4byte (0x[0-9a-f]{8})\b", block)
        assert word_match is not None
        word = int(word_match.group(1), 16)
        opcode = word & 0x7F
        f3 = (word >> 12) & 0x7

        if word == 0x4330_2557:
            ctrl_count += 1

        if opcode == 0x73 and f3 in (1, 2, 3, 5, 6, 7):
            csr = (word >> 20) & 0xFFF
            uimm = (word >> 15) & 0x1F
            assert csr != 0x301  # No misa access
            assert not (csr == 0x008 and (f3 in (1, 5) or uimm != 0))
            if csr == 0x009 and f3 == 2:
                m = re.search(r'(?m)^\.assert rd_wdata == (0x[0-9a-f]+) "', block)
                if m is not None and int(m.group(1), 16) == 0:
                    vxsat_zero_checks += 1
            continue

        if opcode != 0x57:
            continue

        if f3 == 7:
            if (word >> 30) == 0b11:
                vtype = (word >> 20) & 0x3FF
                vl_imm = (word >> 15) & 0x1F
                avl_mode = "imm"
            else:
                vtype = (word >> 20) & 0x7FF
                rs1 = (word >> 15) & 0x1F
                rd = (word >> 7) & 0x1F
                avl_mode = "vlmax" if rs1 == 0 and rd != 0 else "reg"
            sew_code = (vtype >> 3) & 7
            lmul_code = vtype & 7
            vill = (
                sew_code > 3
                or lmul_code == 4
                or (lmul_code in (5, 6, 7) and (lmul_code - 8) < (sew_code - 3))
            )
            continue

        f6 = (word >> 26) & 0x3F
        if f3 not in (opivv, opivi, opivx) or f6 not in (0x10, 0x11, 0x12, 0x13):
            continue

        vm = (word >> 25) & 1
        vs2 = (word >> 20) & 0x1F
        vs1 = (word >> 15) & 0x1F
        vd = (word >> 7) & 0x1F
        sew = 8 << ((vtype >> 3) & 7)
        lmul = vtype & 7
        form = (f6, vm, f3)

        if re.search(r"(?m)^\.assert trap == 1\b", block):
            traps_seen += 1
            if vill:
                trap_kinds.add("vill")
            elif f6 in (0x10, 0x12) and vm == 1:
                trap_kinds.add(f"reserved_vm1_{f6:x}_{f3}")
            elif f6 in (0x12, 0x13) and f3 == opivi:
                trap_kinds.add(f"reserved_vi_{f6:x}_{vm}")
            elif f6 in (0x10, 0x12) and vm == 0 and vd == 0:
                trap_kinds.add(f"vd_v0_{f6:x}")
            elif vm == 0 and vs2 == 0:
                trap_kinds.add(f"vs2_v0_{f6:x}")
            elif vm == 0 and f3 == opivv and vs1 == 0:
                trap_kinds.add(f"vs1_v0_{f6:x}")
            elif lmul == 1 and f6 == 0x10 and (vd & 1):
                trap_kinds.add("misaligned_vd_m2")
            elif lmul == 1 and f6 == 0x11 and (vs2 & 1):
                trap_kinds.add("misaligned_vs2_m2")
            elif lmul == 1 and f6 == 0x12 and (vs1 & 1):
                trap_kinds.add("misaligned_vs1_m2")
            continue

        assert re.search(r"(?m)^\.assert trap == 0\b", block)
        assert not vill
        assert form in expected_forms
        retired_forms.add(form)
        sews_by_form.setdefault(form, set()).add(sew)
        policies_seen.add(vtype & 0xC0)
        lmuls_seen.add(lmul)

        if f3 == opivi:
            simm5_seen.add((f6, vm, vs1))

        if avl_mode == "vlmax":
            regimes_seen.add("vlmax")
        elif vl_imm == 0:
            regimes_seen.add("zero")
        elif all(vl_imm < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
            regimes_seen.add("below_vlmax")
        if avl_mode == "imm" and vl_imm >= 20 and f6 in (0x11, 0x13):
            multibyte_mask_vl = True

        if f6 in (0x10, 0x12) and f3 == opivv:
            if vd == vs2 == vs1:
                legal_overlaps.add(f"self_{f6:x}")
            elif vd == vs2:
                legal_overlaps.add("vd_eq_vs2")
            elif vd == vs1:
                legal_overlaps.add("vd_eq_vs1")
        if f6 in (0x11, 0x13) and vm == 0 and vd == 0:
            legal_overlaps.add(f"mask_vd_v0_{f6:x}")
        if f6 in (0x11, 0x13) and vm == 1 and (vs2 == 0 or (f3 == opivv and vs1 == 0)):
            legal_overlaps.add(f"vm1_src_v0_{f6:x}")
        if f6 in (0x11, 0x13) and lmul == 1 and vd == vs2:
            legal_overlaps.add("m2_mask_low_vs2")
        if f6 in (0x11, 0x13) and lmul == 1 and f3 == opivv and vd == vs1:
            legal_overlaps.add("m2_mask_low_vs1")
        if f6 in (0x11, 0x13) and lmul == 1 and (vd & 1):
            legal_overlaps.add("m2_mask_odd_vd")

    assert len(expected_forms) == 15
    assert retired_forms == expected_forms
    for form in expected_forms:
        assert sews_by_form[form] == {8, 16, 32, 64}, (form, sews_by_form[form])
    for f6, vm in ((0x10, 0), (0x11, 0), (0x11, 1)):
        assert (f6, vm, 0x1F) in simm5_seen  # -1
        assert (f6, vm, 0x10) in simm5_seen  # -16
        assert (f6, vm, 0x0F) in simm5_seen  # +15
    assert {"below_vlmax", "vlmax", "zero"} <= regimes_seen
    assert {0x00, 0xC0} <= policies_seen
    assert {0, 1, 2, 3, 5, 6, 7} <= lmuls_seen
    assert multibyte_mask_vl
    assert vxsat_zero_checks >= 2
    assert {
        "vd_eq_vs2",
        "vd_eq_vs1",
        "self_10",
        "self_12",
        "mask_vd_v0_11",
        "mask_vd_v0_13",
        "vm1_src_v0_11",
        "vm1_src_v0_13",
        "m2_mask_low_vs2",
        "m2_mask_low_vs1",
        "m2_mask_odd_vd",
    } <= legal_overlaps
    assert traps_seen == 18
    assert trap_kinds == {
        "reserved_vm1_10_0",
        "reserved_vm1_10_4",
        "reserved_vm1_10_3",
        "reserved_vm1_12_0",
        "reserved_vm1_12_4",
        "reserved_vi_12_0",
        "reserved_vi_13_1",
        "reserved_vi_13_0",
        "vd_v0_10",
        "vd_v0_12",
        "vs2_v0_10",
        "vs1_v0_12",
        "vs2_v0_11",
        "vs1_v0_13",
        "misaligned_vd_m2",
        "misaligned_vs2_m2",
        "misaligned_vs1_m2",
        "vill",
    }
    assert ctrl_count == 1


def test_vector_mask_ops_trace_covers_forms() -> None:
    """Check all 15 base-V mask-register encodings, >64b scans, SEWs, overlaps and traps."""
    trace = VERIF_DIR / "testrig" / "vector_mask_ops.S"
    text = trace.read_text()
    blocks = TRACE_WORD.split(text)[1:]
    assert blocks

    opmvv = 2
    logic_f6 = set(range(0x18, 0x20))
    scalar_vs1 = {16, 17}  # vcpop.m, vfirst.m (f6 == 0x10)
    scan_vs1 = {1, 2, 3}  # vmsbf.m, vmsof.m, vmsif.m (f6 == 0x14)
    elem_vs1 = {16, 17}  # viota.m, vid.v (f6 == 0x14)

    retired_forms: set[tuple[str, int, int]] = set()
    masking_by_group: dict[str, set[bool]] = {}
    sews_by_elem: dict[int, set[int]] = {}
    regimes_by_group: dict[str, set[str]] = {}
    policies_seen: set[int] = set()
    lmuls_seen: set[int] = set()
    legal_overlaps: set[str] = set()
    block1_groups: set[str] = set()
    vfirst_minus_one = False
    vfirst_block1 = False
    traps_seen = 0
    trap_kinds: set[str] = set()
    ctrl_count = 0

    vtype = 0
    vill = False
    avl_mode = "imm"
    vl_val = 0
    reg_val: dict[int, int | None] = {0: 0}

    for block in blocks:
        word_match = re.match(r"^\.4byte (0x[0-9a-f]{8})\b", block)
        assert word_match is not None
        word = int(word_match.group(1), 16)
        opcode = word & 0x7F
        f3 = (word >> 12) & 0x7

        if word == 0x4350_2557:
            ctrl_count += 1

        if opcode == 0x73 and f3 in (1, 2, 3, 5, 6, 7):
            csr = (word >> 20) & 0xFFF
            uimm = (word >> 15) & 0x1F
            assert csr != 0x301  # No misa access
            assert not (csr == 0x008 and (f3 in (1, 5) or uimm != 0))
            continue

        if opcode != 0x57:
            _update_int_reg_tracking(reg_val, word)
            continue

        if f3 == 7:
            if (word >> 30) == 0b11:
                vtype = (word >> 20) & 0x3FF
                vl_val = (word >> 15) & 0x1F
                avl_mode = "imm"
            else:
                vtype = (word >> 20) & 0x7FF
                rs1 = (word >> 15) & 0x1F
                rd = (word >> 7) & 0x1F
                if rs1 == 0 and rd != 0:
                    avl_mode = "vlmax"
                    vl_val = 0
                else:
                    avl_mode = "reg"
                    rv = reg_val.get(rs1)
                    vl_val = rv if rv is not None else 0
            sew_code = (vtype >> 3) & 7
            lmul_code = vtype & 7
            vill = (
                sew_code > 3
                or lmul_code == 4
                or (lmul_code in (5, 6, 7) and (lmul_code - 8) < (sew_code - 3))
            )
            continue

        f6 = (word >> 26) & 0x3F
        vm = bool((word >> 25) & 1)
        vs2 = (word >> 20) & 0x1F
        vs1 = (word >> 15) & 0x1F
        vd = (word >> 7) & 0x1F
        sew = 8 << ((vtype >> 3) & 7)
        lmul = vtype & 7

        group = ""
        form_id: tuple[str, int, int] | None = None
        if f3 == opmvv and f6 in logic_f6:
            group = "logic"
            form_id = ("logic", f6, 0)
        elif f3 == opmvv and f6 == 0x10 and vs1 in scalar_vs1:
            group = "scalar"
            form_id = ("scalar", f6, vs1)
        elif f3 == opmvv and f6 == 0x14 and vs1 in scan_vs1:
            group = "scan"
            form_id = ("scan", f6, vs1)
        elif f3 == opmvv and f6 == 0x14 and vs1 in elem_vs1:
            group = "elem"
            form_id = ("elem", f6, vs1)
        else:
            continue

        if re.search(r"(?m)^\.assert trap == 1\b", block):
            traps_seen += 1
            if vill:
                trap_kinds.add("vill")
            elif group == "logic" and not vm:
                trap_kinds.add(f"logic_vm0_{f6:x}")
            elif group == "scan" and vd == vs2:
                trap_kinds.add(f"scan_vd_vs2_{vs1}")
            elif group == "scan" and not vm and vd == 0:
                trap_kinds.add(f"scan_masked_v0_{vs1}")
            elif group == "elem" and vs1 == 16 and vd == vs2:
                trap_kinds.add("viota_vd_vs2")
            elif group == "elem" and not vm and vd == 0:
                trap_kinds.add(f"elem_masked_v0_{vs1}")
            elif group == "elem" and vs1 == 17 and vs2 != 0:
                trap_kinds.add("vid_vs2_nz")
            elif group == "elem" and lmul == 1 and (vd & 1):
                trap_kinds.add(f"elem_misaligned_m2_{vs1}")
            continue

        assert re.search(r"(?m)^\.assert trap == 0\b", block)
        assert not vill
        assert form_id is not None
        retired_forms.add(form_id)
        masking_by_group.setdefault(group, set()).add(vm)
        policies_seen.add(vtype & 0xC0)
        lmuls_seen.add(lmul)

        if group == "elem":
            sews_by_elem.setdefault(vs1, set()).add(sew)
        if group == "scalar" and vs1 == 17:
            m = re.search(r'(?m)^\.assert rd_wdata == (0x[0-9a-f]+) "', block)
            if m is not None:
                val = int(m.group(1), 16)
                if val == 0xFFFFFFFFFFFFFFFF:
                    vfirst_minus_one = True
                elif val >= 64:
                    vfirst_block1 = True

        if avl_mode == "vlmax":
            regimes_by_group.setdefault(group, set()).add("vlmax")
        elif vl_val == 0:
            regimes_by_group.setdefault(group, set()).add("zero")
        elif all(vl_val < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
            regimes_by_group.setdefault(group, set()).add("below_vlmax")
        if vl_val >= 80:
            block1_groups.add(group)

        if group == "logic":
            if vd == vs2 == vs1 == 0:
                legal_overlaps.add("logic_self_v0")
            elif vd == vs2 and (vd & 1) and lmul == 1:
                legal_overlaps.add("logic_m2_odd_vd_vs2")
            elif vd == vs1 and (vd & 1) and lmul == 1:
                legal_overlaps.add("logic_m2_odd_vd_vs1")
        elif group == "scalar" and not vm and vs2 == 0:
            legal_overlaps.add(f"scalar_masked_vs2_v0_{vs1}")
        elif group == "scan":
            if vm and vd == 0:
                legal_overlaps.add("scan_unmasked_vd_v0")
            if not vm and vs2 == 0:
                legal_overlaps.add("scan_masked_vs2_v0")
        elif group == "elem":
            if vm and vd == 0:
                legal_overlaps.add(f"elem_unmasked_vd_v0_{vs1}")
            if not vm and vs1 == 16 and vs2 == 0:
                legal_overlaps.add("viota_masked_vs2_v0")

    expected_forms: set[tuple[str, int, int]] = (
        {("logic", f6, 0) for f6 in logic_f6}
        | {("scalar", 0x10, vs1) for vs1 in scalar_vs1}
        | {("scan", 0x14, vs1) for vs1 in scan_vs1}
        | {("elem", 0x14, vs1) for vs1 in elem_vs1}
    )
    assert len(expected_forms) == 15
    assert retired_forms == expected_forms

    assert masking_by_group["logic"] == {True}
    for group in ("scalar", "scan", "elem"):
        assert masking_by_group[group] == {True, False}
    for group in ("logic", "scalar", "scan", "elem"):
        assert {"below_vlmax", "vlmax", "zero"} <= regimes_by_group[group]
    assert sews_by_elem[16] == {8, 16, 32, 64}
    assert sews_by_elem[17] == {8, 16, 32, 64}
    assert {"logic", "scalar", "scan"} <= block1_groups
    assert vfirst_minus_one and vfirst_block1
    assert {0x00, 0xC0} <= policies_seen
    assert {0, 1, 2, 3, 5, 6, 7} <= lmuls_seen
    assert {
        "logic_self_v0",
        "logic_m2_odd_vd_vs2",
        "logic_m2_odd_vd_vs1",
        "scalar_masked_vs2_v0_16",
        "scalar_masked_vs2_v0_17",
        "scan_unmasked_vd_v0",
        "scan_masked_vs2_v0",
        "elem_unmasked_vd_v0_16",
        "elem_unmasked_vd_v0_17",
        "viota_masked_vs2_v0",
    } <= legal_overlaps
    assert traps_seen == 15
    assert trap_kinds == {
        "logic_vm0_19",
        "logic_vm0_1b",
        "scan_vd_vs2_1",
        "scan_vd_vs2_2",
        "scan_vd_vs2_3",
        "scan_masked_v0_1",
        "scan_masked_v0_2",
        "scan_masked_v0_3",
        "viota_vd_vs2",
        "elem_masked_v0_16",
        "elem_masked_v0_17",
        "vid_vs2_nz",
        "elem_misaligned_m2_16",
        "elem_misaligned_m2_17",
        "vill",
    }
    assert ctrl_count == 1


def test_vector_int_mul_add_trace_covers_forms() -> None:
    """Check all 8 base-V int-mul-add encodings, SEWs, masking, policies, overlaps and traps."""
    trace = VERIF_DIR / "testrig" / "vector_int_mul_add.S"
    text = trace.read_text()
    blocks = TRACE_WORD.split(text)[1:]
    assert blocks

    mul_add_f6 = {0x29, 0x2B, 0x2D, 0x2F}
    mul_add_f3 = {2, 6}

    retired_forms: set[tuple[int, int]] = set()
    sews_by_form: dict[tuple[int, int], set[int]] = {}
    masking_by_form: dict[tuple[int, int], set[bool]] = {}
    regimes_seen: set[str] = set()
    policies_seen: set[int] = set()
    lmuls_seen: set[int] = set()
    legal_overlaps: set[str] = set()
    traps_seen = 0
    trap_kinds: set[str] = set()
    ctrl_count = 0

    vtype = 0
    vill = False
    avl_mode = "imm"
    vl_val = 0
    reg_val: dict[int, int | None] = {0: 0}

    for block in blocks:
        word_match = re.match(r"^\.4byte (0x[0-9a-f]{8})\b", block)
        assert word_match is not None
        word = int(word_match.group(1), 16)
        opcode = word & 0x7F
        f3 = (word >> 12) & 0x7

        if word == 0x4370_2557:
            ctrl_count += 1

        if opcode == 0x73 and f3 in (1, 2, 3, 5, 6, 7):
            csr = (word >> 20) & 0xFFF
            uimm = (word >> 15) & 0x1F
            assert csr != 0x301  # No misa access
            assert not (csr == 0x008 and (f3 in (1, 5) or uimm != 0))
            continue

        if opcode != 0x57:
            _update_int_reg_tracking(reg_val, word)
            continue

        if f3 == 7:
            if (word >> 30) == 0b11:
                vtype = (word >> 20) & 0x3FF
                vl_val = (word >> 15) & 0x1F
                avl_mode = "imm"
            else:
                vtype = (word >> 20) & 0x7FF
                rs1 = (word >> 15) & 0x1F
                rd = (word >> 7) & 0x1F
                if rs1 == 0 and rd != 0:
                    avl_mode = "vlmax"
                    vl_val = 0
                else:
                    avl_mode = "reg"
                    rv = reg_val.get(rs1)
                    vl_val = rv if rv is not None else 0
            sew_code = (vtype >> 3) & 7
            lmul_code = vtype & 7
            vill = (
                sew_code > 3
                or lmul_code == 4
                or (lmul_code in (5, 6, 7) and (lmul_code - 8) < (sew_code - 3))
            )
            continue

        f6 = (word >> 26) & 0x3F
        if f3 not in mul_add_f3 or f6 not in mul_add_f6:
            continue

        vm = bool((word >> 25) & 1)
        vs2 = (word >> 20) & 0x1F
        vs1 = (word >> 15) & 0x1F
        vd = (word >> 7) & 0x1F
        sew = 8 << ((vtype >> 3) & 7)
        lmul = vtype & 7
        form_id = (f6, f3)

        if re.search(r"(?m)^\.assert trap == 1\b", block):
            traps_seen += 1
            if vill:
                trap_kinds.add(f"vill_{f3}")
            elif not vm and vd == 0 and lmul == 1:
                trap_kinds.add("m2_masked_vd_v0")
            elif not vm and vd == 0:
                trap_kinds.add(f"masked_vd_v0_{f6:x}")
            elif not vm and vs2 == 0:
                trap_kinds.add(f"masked_vs2_v0_{f6:x}")
            elif not vm and f3 == 2 and vs1 == 0:
                trap_kinds.add(f"masked_vs1_v0_{f6:x}")
            elif lmul == 1 and (vd & 1):
                trap_kinds.add(f"m2_misaligned_vd_{f3}")
            elif lmul == 1 and f3 == 2 and (vs1 & 1):
                trap_kinds.add("m2_misaligned_vs1")
            elif lmul == 1 and (vs2 & 1):
                trap_kinds.add("m2_misaligned_vs2")
            elif lmul == 2 and (vd & 3):
                trap_kinds.add("m4_misaligned_vd")
            continue

        assert re.search(r"(?m)^\.assert trap == 0\b", block)
        assert not vill
        retired_forms.add(form_id)
        sews_by_form.setdefault(form_id, set()).add(sew)
        masking_by_form.setdefault(form_id, set()).add(vm)
        policies_seen.add(vtype & 0xC0)
        lmuls_seen.add(lmul)

        if avl_mode == "vlmax":
            regimes_seen.add("vlmax")
        elif vl_val == 0:
            regimes_seen.add("zero")
        elif all(vl_val < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
            regimes_seen.add("below_vlmax")

        if f3 == 2:
            if vd == vs1 == vs2:
                legal_overlaps.add("vd_vs1_vs2")
            elif vd == vs1:
                legal_overlaps.add(f"vd_vs1_{f6:x}")
            elif vd == vs2:
                legal_overlaps.add("vd_vs2")
            elif vs1 == vs2 and vs1 != 0:
                legal_overlaps.add("vs1_vs2")
            if vm and vd == 0:
                legal_overlaps.add("unmasked_vd_v0")
            if vm and vs1 == 0 and vs2 == 0:
                legal_overlaps.add("unmasked_vs1_vs2_v0")

    expected_forms = {(f6, f3) for f6 in mul_add_f6 for f3 in mul_add_f3}
    assert len(expected_forms) == 8
    assert retired_forms == expected_forms
    for form_id in expected_forms:
        assert sews_by_form[form_id] == {8, 16, 32, 64}, form_id
        assert masking_by_form[form_id] == {True, False}, form_id

    assert {"below_vlmax", "vlmax", "zero"} <= regimes_seen
    assert {0x00, 0xC0} <= policies_seen
    assert {0, 1, 2, 3, 5, 6, 7} <= lmuls_seen
    assert {
        "vd_vs1_2d",
        "vd_vs1_29",
        "vd_vs2",
        "vs1_vs2",
        "vd_vs1_vs2",
        "unmasked_vd_v0",
        "unmasked_vs1_vs2_v0",
    } <= legal_overlaps
    assert traps_seen == 16
    assert trap_kinds == {
        "masked_vd_v0_2d",
        "masked_vd_v0_2f",
        "masked_vd_v0_29",
        "masked_vd_v0_2b",
        "masked_vs2_v0_2d",
        "masked_vs2_v0_29",
        "masked_vs1_v0_2f",
        "masked_vs1_v0_2b",
        "m2_masked_vd_v0",
        "m2_misaligned_vd_2",
        "m2_misaligned_vd_6",
        "m2_misaligned_vs1",
        "m2_misaligned_vs2",
        "m4_misaligned_vd",
        "vill_2",
        "vill_6",
    }
    assert ctrl_count == 1


def test_vector_int_vx_merge_trace_covers_forms() -> None:
    """Check all 18 remaining non-segment integer encodings, div corners, overlaps and traps."""
    trace = VERIF_DIR / "testrig" / "vector_int_vx_merge.S"
    text = trace.read_text()
    blocks = TRACE_WORD.split(text)[1:]
    assert blocks

    vx_forms = {
        (0x03, 4),
        (0x09, 4),
        (0x25, 4),
        (0x28, 4),
        (0x29, 4),
        (0x04, 4),
        (0x05, 4),
        (0x06, 4),
        (0x07, 4),
        (0x24, 6),
        (0x27, 6),
        (0x26, 6),
        (0x20, 6),
        (0x21, 6),
        (0x22, 6),
        (0x23, 6),
    }
    merge_forms = {(0x17, 0), (0x17, 4)}
    div_f6 = {0x20, 0x21, 0x22, 0x23}

    retired_forms: set[tuple[int, int]] = set()
    sews_by_form: dict[tuple[int, int], set[int]] = {}
    masking_by_form: dict[tuple[int, int], set[bool]] = {}
    div_zero_sews: dict[int, set[int]] = {}
    div_neg1_sews: dict[int, set[int]] = {}
    regimes_seen: set[str] = set()
    policies_seen: set[int] = set()
    lmuls_seen: set[int] = set()
    legal_overlaps: set[str] = set()
    traps_seen = 0
    trap_kinds: set[str] = set()
    ctrl_count = 0

    vtype = 0
    vill = False
    avl_mode = "imm"
    vl_val = 0
    reg_val: dict[int, int | None] = {0: 0}

    for block in blocks:
        word_match = re.match(r"^\.4byte (0x[0-9a-f]{8})\b", block)
        assert word_match is not None
        word = int(word_match.group(1), 16)
        opcode = word & 0x7F
        f3 = (word >> 12) & 0x7

        if word == 0x4340_2557:
            ctrl_count += 1

        if opcode == 0x73 and f3 in (1, 2, 3, 5, 6, 7):
            csr = (word >> 20) & 0xFFF
            uimm = (word >> 15) & 0x1F
            assert csr != 0x301  # No misa access
            assert not (csr == 0x008 and (f3 in (1, 5) or uimm != 0))
            continue

        if opcode != 0x57:
            _update_int_reg_tracking(reg_val, word)
            continue

        if f3 == 7:
            if (word >> 30) == 0b11:
                vtype = (word >> 20) & 0x3FF
                vl_val = (word >> 15) & 0x1F
                avl_mode = "imm"
            else:
                vtype = (word >> 20) & 0x7FF
                rs1 = (word >> 15) & 0x1F
                rd = (word >> 7) & 0x1F
                if rs1 == 0 and rd != 0:
                    avl_mode = "vlmax"
                    vl_val = 0
                else:
                    avl_mode = "reg"
                    rv = reg_val.get(rs1)
                    vl_val = rv if rv is not None else 0
            sew_code = (vtype >> 3) & 7
            lmul_code = vtype & 7
            vill = (
                sew_code > 3
                or lmul_code == 4
                or (lmul_code in (5, 6, 7) and (lmul_code - 8) < (sew_code - 3))
            )
            continue

        f6 = (word >> 26) & 0x3F
        vm = bool((word >> 25) & 1)
        vs2 = (word >> 20) & 0x1F
        vs1 = (word >> 15) & 0x1F
        vd = (word >> 7) & 0x1F
        form_id = (f6, f3)
        is_vx = form_id in vx_forms
        is_merge = form_id in merge_forms and not vm
        if not (is_vx or is_merge):
            continue

        sew = 8 << ((vtype >> 3) & 7)
        lmul = vtype & 7

        if re.search(r"(?m)^\.assert trap == 1\b", block):
            traps_seen += 1
            if vill:
                trap_kinds.add(f"vill_{f6:x}_{f3}")
            elif is_merge and vd == 0:
                trap_kinds.add(f"merge_vd_v0_{f3}")
            elif is_merge and vs2 == 0:
                trap_kinds.add(f"merge_vs2_v0_{f3}")
            elif is_merge and f3 == 0 and vs1 == 0:
                trap_kinds.add("merge_vs1_v0")
            elif is_vx and not vm and vd == 0:
                trap_kinds.add(f"vx_masked_vd_v0_{f6:x}")
            elif is_vx and not vm and vs2 == 0:
                trap_kinds.add(f"vx_masked_vs2_v0_{f6:x}")
            elif lmul == 1 and (vd & 1):
                trap_kinds.add(f"m2_misaligned_vd_{f6:x}")
            elif lmul == 1 and (vs2 & 1):
                trap_kinds.add(f"m2_misaligned_vs2_{f6:x}")
            elif lmul == 1 and is_merge and f3 == 0 and (vs1 & 1):
                trap_kinds.add("m2_misaligned_merge_vs1")
            elif lmul == 2 and (vd & 3):
                trap_kinds.add("m4_misaligned_vd")
            continue

        assert re.search(r"(?m)^\.assert trap == 0\b", block)
        assert not vill
        retired_forms.add(form_id)
        sews_by_form.setdefault(form_id, set()).add(sew)
        masking_by_form.setdefault(form_id, set()).add(vm)
        policies_seen.add(vtype & 0xC0)
        lmuls_seen.add(lmul)

        if f3 == 6 and f6 in div_f6 and vl_val > 0:
            rv = reg_val.get(vs1)
            if rv is not None:
                sew_mask = (1 << sew) - 1
                low = rv & sew_mask
                if low == 0:
                    div_zero_sews.setdefault(f6, set()).add(sew)
                elif low == sew_mask:
                    div_neg1_sews.setdefault(f6, set()).add(sew)

        if avl_mode == "vlmax":
            regimes_seen.add("vlmax")
        elif vl_val == 0:
            regimes_seen.add("zero")
        elif all(vl_val < _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS):
            regimes_seen.add("below_vlmax")

        if is_vx:
            if vd == vs2 and vd != 0:
                legal_overlaps.add("vx_vd_vs2")
            if vm and vd == 0 and vs2 == 0:
                legal_overlaps.add("vx_unmasked_vd_vs2_v0")
        elif is_merge:
            if f3 == 0:
                if vd == vs2 == vs1:
                    legal_overlaps.add("merge_vv_all_eq")
                elif vd == vs2:
                    legal_overlaps.add("merge_vv_vd_vs2")
                elif vd == vs1:
                    legal_overlaps.add("merge_vv_vd_vs1")
                elif vs1 == vs2:
                    legal_overlaps.add("merge_vv_vs1_vs2")
            elif vd == vs2:
                legal_overlaps.add("merge_vx_vd_vs2")

    expected_forms = vx_forms | merge_forms
    assert len(expected_forms) == 18
    assert retired_forms == expected_forms
    for form_id in expected_forms:
        assert sews_by_form[form_id] == {8, 16, 32, 64}, form_id
    for form_id in vx_forms:
        assert masking_by_form[form_id] == {True, False}, form_id
    for form_id in merge_forms:
        assert masking_by_form[form_id] == {False}, form_id

    for f6 in div_f6:
        assert div_zero_sews[f6] == {8, 16, 32, 64}, hex(f6)
        assert div_neg1_sews[f6] == {8, 16, 32, 64}, hex(f6)

    assert {"below_vlmax", "vlmax", "zero"} <= regimes_seen
    assert {0x00, 0xC0} <= policies_seen
    assert {0, 1, 2, 3, 5, 6, 7} <= lmuls_seen
    assert {
        "vx_vd_vs2",
        "vx_unmasked_vd_vs2_v0",
        "merge_vv_vd_vs2",
        "merge_vv_vd_vs1",
        "merge_vv_vs1_vs2",
        "merge_vv_all_eq",
        "merge_vx_vd_vs2",
    } <= legal_overlaps
    assert traps_seen == 20
    assert trap_kinds == {
        "vx_masked_vd_v0_3",
        "vx_masked_vd_v0_25",
        "vx_masked_vd_v0_27",
        "vx_masked_vd_v0_21",
        "vx_masked_vs2_v0_9",
        "vx_masked_vs2_v0_5",
        "vx_masked_vs2_v0_26",
        "vx_masked_vs2_v0_23",
        "merge_vd_v0_0",
        "merge_vd_v0_4",
        "merge_vs2_v0_0",
        "merge_vs1_v0",
        "merge_vs2_v0_4",
        "m2_misaligned_vd_3",
        "m2_misaligned_vs2_21",
        "m2_misaligned_merge_vs1",
        "m4_misaligned_vd",
        "vill_3_4",
        "vill_21_6",
        "vill_17_0",
    }
    assert ctrl_count == 1


def test_readout_sees_every_register_and_vxsat() -> None:
    """The read-out reads v31 and vxsat as well as the other registers."""
    lines = vector.trace(random.Random(5), 128, 3)
    tail = lines[len(lines) - 1 - lines[::-1].index(".noshrink") :]
    text = "\n".join(tail)
    assert "vmv.x.s a3, v31" in text and "csr" in text and "vxsat" in text
