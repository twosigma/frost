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
    expected = (25, instructions + 2011) if vector_directed else (15, instructions)
    assert (plan.traces, plan.instructions) == expected
    assert len(list(trace_dir.glob("vector_42_*.S"))) == 12
    for family in ("integer", "fp", "memory"):
        filename = f"vector_source_widths_{family}.S"
        assert (trace_dir / filename).read_bytes() == (
            VERIF_DIR / "testrig" / filename
        ).read_bytes()
    for filename, words, checks in (
        ("vector_state_results.S", 69, 56),
        ("vector_fractional_lmul.S", 54, 62),
        ("vector_fp_results_flags.S", 74, 51),
        ("vector_fma.S", 186, 146),
        ("vector_fp_compare.S", 206, 264),
        ("vector_fp_convert.S", 210, 209),
        ("vector_cached_load.S", 13, 4),
        ("vector_cached_store.S", 12, 4),
        ("vector_unit_stride.S", 926, 336),
        ("vector_int_compare.S", 261, 210),
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


def _vlmax(vlen: int, sew: int, lmul_code: int) -> int:
    num, den = _LMUL_NUM_DEN[lmul_code]
    return (vlen * num) // (sew * den)


def _signed12(word: int) -> int:
    imm = (word >> 20) & 0xFFF
    return imm - 0x1000 if imm & 0x800 else imm


def _check_unit_stride_store_readbacks(
    trace: Path, blocks: list[str], words: list[int]
) -> None:
    """Verify every unit-stride or mask vector store is immediately read back."""
    for block in blocks:
        assert block.lstrip().startswith(".4byte "), (
            f"{trace.name}: compressed instruction not allowed in vector store trace"
        )
    vl_by_vlen: dict[int, int] | None = None
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
            sew = 8 << ((vtype >> 3) & 7)
            lmul = vtype & 7
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
            sew = 8 << ((vtype >> 3) & 7)
            lmul = vtype & 7
            vl_by_vlen = {v: _vlmax(v, sew, lmul) for v in vector.VECTOR_LENGTHS}
        elif word & 0xFE00_707F == 0x8000_7057:  # vsetvl
            raise AssertionError(f"{trace.name}: vsetvl at index {index} hides VL")
        elif test_testrig.run_stats.is_vector_store(word):
            assert vl_by_vlen is not None, f"{trace.name}: store before vset* config"
            assert re.search(r"(?m)^\.assert trap == 0\b", blocks[index]), (
                f"{trace.name}: retiring vector store at index {index} needs trap == 0"
            )
            mop = (word >> 26) & 3
            nf = (word >> 29) & 7
            sumop = (word >> 20) & 0x1F
            width = (word >> 12) & 7
            rs1 = (word >> 15) & 0x1F
            assert mop == 0 and nf == 0 and sumop in (0, 0x0B), (
                f"{trace.name}: unsupported vector store form at index {index}"
            )
            if sumop == 0x0B:  # vsm.v
                assert width == 0 and bool((word >> 25) & 1)
                written_per_vlen = {v: (vl + 7) // 8 for v, vl in vl_by_vlen.items()}
            else:
                elem_bytes = _VMEM_WIDTH_BYTES[width]
                written_per_vlen = {v: vl * elem_bytes for v, vl in vl_by_vlen.items()}
            max_written = max(written_per_vlen.values())
            min_written = min(written_per_vlen.values())
            required = set(range(max_written))
            covered: set[int] = set()
            asserted_offsets: set[int] = set()
            scan = index + 1
            while scan < len(words):
                next_word = words[scan]
                next_op = next_word & 0x7F
                next_f3 = (next_word >> 12) & 7
                if (
                    next_op == 0x03
                    and next_f3 in _SCALAR_LOAD_WIDTH_BYTES
                    and ((next_word >> 15) & 0x1F) == rs1
                    and ((next_word >> 7) & 0x1F) != 0
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
            if max_written == 0:
                assert 0 in asserted_offsets, (
                    f"{trace.name}: zero-length vector store at index {index} "
                    "needs a sentinel readback assertion"
                )
            else:
                assert set(range(min_written)) <= asserted_offsets or (
                    sumop == 0x0B and min_written != max_written
                ), (
                    f"{trace.name}: vector store at index {index} missing rd_wdata "
                    "assertion on always-active bytes"
                )


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
        if trace.name == "vector_unit_stride.S":
            assert stores, f"{trace.name}: expected unit-stride vector stores"
            _check_unit_stride_store_readbacks(trace, blocks, words)
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


def test_readout_sees_every_register_and_vxsat() -> None:
    """The read-out reads v31 and vxsat as well as the other registers."""
    lines = vector.trace(random.Random(5), 128, 3)
    tail = lines[len(lines) - 1 - lines[::-1].index(".noshrink") :]
    text = "\n".join(tail)
    assert "vmv.x.s a3, v31" in text and "csr" in text and "vxsat" in text
