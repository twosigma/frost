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

"""Unit tests for the TestRIG scalar FP and Zcb generators and CI wiring."""

import importlib
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import pytest
import yaml  # type: ignore[import-untyped]

REPO_ROOT = Path(__file__).resolve().parents[1]
VERIF_DIR = REPO_ROOT / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))

fp_ext = importlib.import_module("testrig.fp_ext")
compressed_mops = importlib.import_module("testrig.compressed_mops")
preamble = importlib.import_module("testrig.preamble")
rvfi_dii = importlib.import_module("testrig.rvfi_dii")
test_testrig = importlib.import_module("test_testrig")

FP_GOLDEN = [
    (fp_ext.op_fp(0x00, 2, 1, 0, 3), 0x002081D3),  # fadd.s f3, f1, f2, rne
    (fp_ext.op_fp(0x01, 2, 1, 7, 3), 0x0220F1D3),  # fadd.d f3, f1, f2, dyn
    (fp_ext.op_fp(0x2C, 0, 1, 0, 3), 0x580081D3),  # fsqrt.s f3, f1, rne
    (fp_ext.op_fp(0x2D, 0, 1, 0, 3), 0x5A0081D3),  # fsqrt.d f3, f1, rne
    (fp_ext.r4_type(0x43, 3, 0, 2, 1, 0, 4), 0x18208243),  # fmadd.s f4, f1, f2, f3, rne
    (
        fp_ext.r4_type(0x4F, 3, 1, 2, 1, 1, 4),
        0x1A20924F,
    ),  # fnmadd.d f4, f1, f2, f3, rtz
    (fp_ext.op_fp(0x22, 0, 1, 0, 2), 0x44008153),  # fcvt.h.s f2, f1, rne
    (fp_ext.op_fp(0x20, 2, 1, 0, 2), 0x40208153),  # fcvt.s.h f2, f1, rne
    (fp_ext.op_fp(0x78, 1, 0, 0, 5), 0xF01002D3),  # fli.s f5, 0
    (fp_ext.op_fp(0x79, 1, 31, 0, 5), 0xF21F82D3),  # fli.d f5, 31
    (fp_ext.op_fp(0x14, 2, 1, 2, 6), 0x2820A353),  # fminm.s f6, f1, f2
    (fp_ext.op_fp(0x51, 2, 1, 5, 11), 0xA220D5D3),  # fltq.d x11, f1, f2
    (fp_ext.op_fp(0x21, 5, 1, 0, 7), 0x425083D3),  # froundnx.d f7, f1, rne
    (fp_ext.op_fp(0x61, 8, 1, 1, 11), 0xC28095D3),  # fcvtmod.w.d x11, f1, rtz
    (fp_ext.op_fp(0x70, 0, 1, 1, 11), 0xE00095D3),  # fclass.s x11, f1
    (fp_ext.op_fp(0x71, 0, 1, 1, 11), 0xE20095D3),  # fclass.d x11, f1
]

ZCB_GOLDEN = [
    (compressed_mops._mop_r(0, 17, 10), 0x81C548F3),
    (compressed_mops._mop_r(31, 20, 10), 0xCDF54A73),
    (compressed_mops._mop_rr(0, 17, 10, 11), 0x82B548F3),
    (compressed_mops._mop_rr(7, 24, 10, 11), 0xCEB54C73),
]


@pytest.mark.parametrize(("encoded", "expected"), FP_GOLDEN + ZCB_GOLDEN)
def test_scalar_fp_and_zcb_encodings(encoded: int, expected: int) -> None:
    """Selected scalar FP and Zcb/Zimop helper encodings match the ISA."""
    assert encoded == expected


def test_fp_li_materializes_all_64bit_shapes() -> None:
    """fp_ext.Trace.li builds 12-bit, 32-bit, shifted high-half, and full 64-bit values."""
    mask64 = (1 << 64) - 1
    values = [
        0,
        1,
        -1 & mask64,
        2047,
        (-2048) & mask64,
        0x7FFF_F800,
        0x7FFF_FFFF,
        0x8000_0000,
        0xFFFF_FFFF_8000_0000,
        0x7FF0_0000_0000_0000,
        0x8000_0000_0000_0000,
        0xFFF8_0000_0000_0000,
        0x3FF0_0000_0000_0000,
        0x0123_4567_89AB_CDEF,
        0xFEDC_BA98_7654_3210,
    ]
    for target in values:
        trace = fp_ext.Trace()
        trace.li(10, target)
        reg = 0
        for line in trace.lines:
            word = int(line.split()[1], 16)
            opcode = word & 0x7F
            funct3 = (word >> 12) & 0x7
            imm_i = (word >> 20) & 0xFFF
            simm_i = imm_i - 0x1000 if (imm_i & 0x800) else imm_i
            if opcode == 0x37:
                u32 = word & 0xFFFF_F000
                reg = (u32 - (1 << 32) if (u32 & 0x8000_0000) else u32) & mask64
            elif opcode == 0x13 and funct3 == 0:
                reg = simm_i & mask64
            elif opcode == 0x13 and funct3 == 1:
                reg = (reg << (imm_i & 0x3F)) & mask64
            elif opcode == 0x13 and funct3 == 6:
                reg = (reg | (simm_i & mask64)) & mask64
            elif opcode == 0x1B and funct3 == 0:
                low32 = (reg + simm_i) & 0xFFFF_FFFF
                reg = (low32 - (1 << 32) if (low32 & 0x8000_0000) else low32) & mask64
            else:
                raise AssertionError(f"unexpected instruction in Trace.li: {line}")
        assert reg == target, hex(target)


@pytest.mark.parametrize(
    ("module", "count", "length"),
    ((fp_ext, 4, 250), (compressed_mops, 4, 200)),
)
def test_seed_reproducibility_and_trace_format(
    tmp_path: Path, module: Any, count: int, length: int
) -> None:
    """Identical seeds produce byte-identical traces with valid .4byte lines."""
    first = module.write_tests(tmp_path / "a", count, 20261123, length)
    second = module.write_tests(tmp_path / "b", count, 20261123, length)
    assert len(first) == count
    for one, two in zip(first, second, strict=True):
        text = one.read_text(encoding="utf-8")
        assert text == two.read_text(encoding="utf-8")
        body = [line for line in text.splitlines() if not line.startswith("#")]
        assert body[0] == ".noshrink"
        assert ".shrink" in body
        words = 0
        for line in body:
            if line in (".noshrink", ".shrink"):
                continue
            assert re.match(r"^\.4byte 0x[0-9a-f]{8}(?: # \S.*)?$", line), line
            words += 1
        assert words >= length - 3


def test_fp_ext_batch_covers_all_implemented_scalar_fp_ops(tmp_path: Path) -> None:
    """A 60-trace batch covers all 85 implemented F, D, Zfhmin and Zfa encodings."""
    expected_ops = (
        set(fp_ext.BINARY_ARITH)
        | set(fp_ext.SQRTS)
        | set(fp_ext.FMA_OPS)
        | set(fp_ext.SIGN_INJ)
        | set(fp_ext.CONVERSIONS)
        | set(fp_ext.FP_TO_INT)
        | set(fp_ext.INT_TO_FP)
        | set(fp_ext.ROUNDS)
        | set(fp_ext.MINMAX)
        | set(fp_ext.COMPARES)
        | set(fp_ext.CLASSIFIES)
        | {
            "flh",
            "fsh",
            "flw",
            "fsw",
            "fld",
            "fsd",
            "fmv.x.h",
            "fmv.h.x",
            "fmv.x.w",
            "fmv.w.x",
            "fmv.x.d",
            "fmv.d.x",
            "fli.s",
            "fli.d",
            "fcvtmod.w.d",
        }
    )
    assert len(expected_ops) == 85
    paths = fp_ext.write_tests(tmp_path / "fp", 60, 1001, 250)
    seen_ops: set[str] = set()
    comments: list[str] = []
    for path in paths:
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith(".4byte "):
                comment = line.split("# ", 1)[1]
                comments.append(comment)
                seen_ops.add(comment.split()[0])
    assert expected_ops - seen_ops == set()
    joined = "\n".join(comments)
    for token in (
        "reserved static rm",
        "DYN with reserved frm",
        "fcvtmod.w.d rm != rtz",
        "misaligned",
        "illegal fadd.h",
        "illegal fclass.h",
        "illegal fli.h",
        "illegal fmadd.h",
    ):
        assert token in joined, token


def test_zcb_batch_covers_all_zcb_zcmop_zimop_and_ntl_forms(tmp_path: Path) -> None:
    """A 50-trace batch covers all Zcb, Zcmop, Zimop, Zihintntl and reserved forms."""
    paths = compressed_mops.write_tests(tmp_path / "zcb", 50, 1001, 200)
    joined = "\n".join(p.read_text(encoding="utf-8") for p in paths)
    for token in (
        "# c.lbu",
        "# c.lh(u)",
        "# c.sb",
        "# c.sh",
        "# c.mul",
        *(f"# c.unary.{sel}" for sel in range(6)),
        *(f"# c.mop.{n}" for n in range(1, 16, 2)),
        "# mop.r.",
        "# mop.rr.",
        "# ntl",
        "# c.ntl",
        "# reserved",
    ):
        assert token in joined, token


def test_sail_executes_fp_ext_and_zcb_batches(tmp_path: Path) -> None:
    """Sail 0.16 executes scalar FP and Zcb batches with expected trap outcomes."""
    sail_bin = shutil.which("sail_riscv_sim")
    if sail_bin is None:
        pytest.skip("sail_riscv_sim is not installed (it is in the frost image)")

    sail_config = test_testrig.write_sail_config(30, tmp_path)
    fp_paths = fp_ext.write_tests(tmp_path / "fp", 10, 1001, 250)
    zcb_paths = compressed_mops.write_tests(tmp_path / "zcb", 8, 1001, 200)

    port, _ = test_testrig.free_ports()
    proc = subprocess.Popen(
        [
            sail_bin,
            "--config-override",
            str(sail_config),
            "--disable-trap-loop-detection",
            "--rvfi-dii",
            str(port),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        sock = None
        for _ in range(40):
            try:
                sock = socket.create_connection(("127.0.0.1", port), timeout=2.0)
                break
            except OSError:
                time.sleep(0.05)
        assert sock is not None, "Sail did not open RVFI-DII socket"
        with sock:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            reader = rvfi_dii.PacketReader(sock)
            sock.sendall(rvfi_dii.DiiPacket(rvfi_dii.VERSION_QUERY_WORD, 1, 0).encode())
            assert len(reader.read(rvfi_dii.V1_PACKET_BYTES)) == 88
            sock.sendall(rvfi_dii.DiiPacket(2, 1, ord("v")).encode())
            assert reader.read(16) == rvfi_dii.version_ack(2)
            sock.sendall(rvfi_dii.DiiPacket(0, 1, rvfi_dii.CMD_END_OF_TRACE).encode())
            assert rvfi_dii.decode_v2(reader).halt == 1

            pre = list(preamble.reset_preamble())
            for kind, paths in (("fp", fp_paths), ("zcb", zcb_paths)):
                traps = 0
                retired = 0
                for path in paths:
                    items = [
                        (
                            int(line.split()[1], 16),
                            line.split("# ", 1)[1] if "# " in line else "",
                        )
                        for line in path.read_text(encoding="utf-8").splitlines()
                        if line.startswith(".4byte ")
                    ]
                    words = pre + [word for word, _ in items]
                    for start in range(0, len(words), 64):
                        batch = words[start : start + 64]
                        sock.sendall(
                            b"".join(
                                rvfi_dii.DiiPacket(
                                    word, 1, rvfi_dii.CMD_INSTRUCTION
                                ).encode()
                                for word in batch
                            )
                        )
                        for offset, word in enumerate(batch):
                            pkt = rvfi_dii.decode_v2(reader)
                            idx = start + offset - len(pre)
                            if idx >= 0:
                                desc = items[idx][1]
                                if kind == "fp":
                                    expect_trap = any(
                                        k in desc
                                        for k in (
                                            "reserved",
                                            "rm != rtz",
                                            "illegal ",
                                        )
                                    )
                                else:
                                    expect_trap = desc == "reserved"
                                assert bool(pkt.trap) == expect_trap, (
                                    path.name,
                                    idx,
                                    hex(word),
                                    desc,
                                    pkt,
                                )
                                traps += int(bool(pkt.trap))
                                retired += int(not pkt.trap)
                    sock.sendall(
                        rvfi_dii.DiiPacket(0, 1, rvfi_dii.CMD_END_OF_TRACE).encode()
                    )
                    assert rvfi_dii.decode_v2(reader).halt == 1
                assert retired > 0 and traps > 0, (kind, retired, traps)
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_ci_scalar_testrig_runs_fp_ext_and_zcb_before_wfi_clean() -> None:
    """The recurring scalar TestRIG CI job runs both --fp-ext and --zcb."""
    workflow = yaml.safe_load((REPO_ROOT / ".github/workflows/ci.yml").read_text())
    steps = workflow["jobs"]["test-testrig"]["steps"]
    by_name = {step["name"]: (idx, step) for idx, step in enumerate(steps)}

    fp_idx, fp_step = by_name["Compare FROST with Sail on random scalar FP sequences"]
    zcb_idx, zcb_step = by_name[
        "Compare FROST with Sail on random Zcb, Zcmop, Zimop, and Zihintntl sequences"
    ]
    wfi_idx, _ = by_name["Compare FROST with Sail on directed WFI traces"]
    assert fp_idx < wfi_idx and zcb_idx < wfi_idx

    for step, flag, expected_log in (
        (fp_step, "--fp-ext", "tests/testrig_logs/fp-ext"),
        (zcb_step, "--zcb", "tests/testrig_logs/zcb"),
    ):
        assert "!cancelled()" in step["if"]
        assert "matrix.shard" not in step["if"]
        tokens = shlex.split(step["run"].replace("\\\n", ""))
        args = tokens[tokens.index("tests/test_testrig.py") + 1 :]
        parsed = test_testrig.parse_arguments(args)
        assert getattr(parsed, flag.lstrip("-").replace("-", "_")) >= 50
        assert parsed.continue_on_fail is True
        assert parsed.log_dir == expected_log
