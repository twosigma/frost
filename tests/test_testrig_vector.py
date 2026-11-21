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
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
VERIF_DIR = REPO_ROOT / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))
vector = importlib.import_module("testrig.vector")
test_testrig = importlib.import_module("test_testrig")

WORD = re.compile(r"^\.4byte (0x[0-9a-f]{8})\s+# (.+)$")


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
    expected = (20, instructions + 589) if vector_directed else (15, instructions)
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
    ):
        trace = trace_dir / filename
        assert trace.is_file() == vector_directed
        if vector_directed:
            assert trace.read_bytes() == (VERIF_DIR / "testrig" / filename).read_bytes()
            lines = trace.read_text().splitlines()
            assert sum(line.startswith(".4byte ") for line in lines) == words
            assert sum(line.startswith(".assert ") for line in lines) == checks


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


def test_readout_sees_every_register_and_vxsat() -> None:
    """The read-out reads v31 and vxsat as well as the other registers."""
    lines = vector.trace(random.Random(5), 128, 3)
    tail = lines[len(lines) - 1 - lines[::-1].index(".noshrink") :]
    text = "\n".join(tail)
    assert "vmv.x.s a3, v31" in text and "csr" in text and "vxsat" in text
