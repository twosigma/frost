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

"""Unit tests for the TestRIG misaligned load/store trace set and CI wiring."""

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

misaligned = importlib.import_module("testrig.misaligned")
preamble = importlib.import_module("testrig.preamble")
rvfi_dii = importlib.import_module("testrig.rvfi_dii")
test_testrig = importlib.import_module("test_testrig")

GOLDEN_ENCODINGS = [
    (misaligned.fload("flh", 10, 8, 1), 0x0014_1507),
    (misaligned.fload("flw", 10, 8, 2), 0x0024_2507),
    (misaligned.fload("fld", 10, 8, 7), 0x0074_3507),
    (misaligned.fstore("fsh", 8, 9, 1), 0x0084_90A7),
    (misaligned.fstore("fsw", 9, 8, 3), 0x0094_21A7),
    (misaligned.fstore("fsd", 8, 9, 5), 0x0084_B2A7),
    (misaligned.c_lhu(12, 9, 0), 0x0000_8490),
    (misaligned.c_lh(13, 9, 0), 0x0000_84D4),
    (misaligned.c_sh(13, 8, 0), 0x0000_8C14),
    (misaligned.c_lw(10, 8, 0), 0x0000_4008),
    (misaligned.c_sw(12, 8, 0), 0x0000_C010),
    (misaligned.c_ld(10, 8, 0), 0x0000_6008),
    (misaligned.c_sd(12, 8, 0), 0x0000_E010),
    (misaligned.c_fld(10, 8, 0), 0x0000_2008),
    (misaligned.c_fsd(8, 8, 0), 0x0000_A000),
    (misaligned.c_lwsp(10, 0), 0x0000_4502),
    (misaligned.c_ldsp(11, 0), 0x0000_6582),
    (misaligned.c_fldsp(10, 0), 0x0000_2502),
    (misaligned.c_swsp(12, 0), 0x0000_C032),
    (misaligned.c_sdsp(13, 0), 0x0000_E036),
    (misaligned.c_fsdsp(9, 0), 0x0000_A026),
    (misaligned.lr("lr.w", 10, 8), 0x1004_252F),
    (misaligned.lr("lr.d", 10, 8), 0x1004_352F),
    (misaligned.sc("sc.w", 10, 12, 8), 0x18C4_252F),
    (misaligned.sc("sc.d", 10, 12, 8), 0x18C4_352F),
    (misaligned.amoadd("amoadd.w", 10, 12, 8), 0x00C4_252F),
    (misaligned.amoadd("amoadd.d", 10, 12, 8), 0x00C4_352F),
]


@pytest.mark.parametrize(("inst", "expected"), GOLDEN_ENCODINGS)
def test_misaligned_helper_encodings(inst: Any, expected: int) -> None:
    """Each FP, compressed, and atomic helper matches the RISC-V encoding."""
    assert inst.word == expected, inst.text


def test_misaligned_traces_deterministic_and_bounded(tmp_path: Path) -> None:
    """write_tests is deterministic, valid .4byte syntax, and fits the harness."""
    first = misaligned.write_tests(tmp_path / "a")
    second = misaligned.write_tests(tmp_path / "b")
    assert len(first) == 5
    assert [p.name for p in first] == [p.name for p in second]

    pre_len = len(preamble.reset_preamble())
    seen_ops: set[str] = set()
    for one, two in zip(first, second, strict=True):
        text = one.read_text(encoding="utf-8")
        assert text == two.read_text(encoding="utf-8")
        insns = [line for line in text.splitlines() if line.startswith(".4byte ")]
        assert 100 <= len(insns) <= 4096, (one.name, len(insns))
        assert pre_len + len(insns) < 8192, (one.name, pre_len + len(insns))
        for line in insns:
            assert re.match(r"^\.4byte 0x[0-9a-f]{8} # \S.*$", line), line
            seen_ops.add(line.split("# ", 1)[1].split()[0])

    required_ops = {
        "lh",
        "lhu",
        "lw",
        "lwu",
        "ld",
        "sh",
        "sw",
        "sd",
        "flh",
        "flw",
        "fld",
        "fsh",
        "fsw",
        "fsd",
        "c.lh",
        "c.lhu",
        "c.sh",
        "c.lw",
        "c.sw",
        "c.ld",
        "c.sd",
        "c.fld",
        "c.fsd",
        "c.lwsp",
        "c.ldsp",
        "c.fldsp",
        "c.swsp",
        "c.sdsp",
        "c.fsdsp",
        "lr.w",
        "lr.d",
        "sc.w",
        "sc.d",
        "amoadd.w",
        "amoadd.d",
    }
    assert required_ops <= seen_ops, required_ops - seen_ops


def test_misaligned_cli_mutual_exclusion() -> None:
    """--misaligned parses cleanly and is mutually exclusive with other modes."""
    parsed = test_testrig.parse_arguments(["--misaligned"])
    assert parsed.misaligned is True
    for conflict in (
        ["--misaligned", "--wfi"],
        ["--misaligned", "--sscofpmf"],
        ["--misaligned", "--mmu", "1"],
        ["--misaligned", "--trace", "x.S"],
    ):
        with pytest.raises(SystemExit):
            test_testrig.parse_arguments(conflict)


def test_sail_executes_misaligned_trace_set(tmp_path: Path) -> None:
    """Sail 0.16 runs all five misaligned traces with expected retire and trap counts."""
    sail_bin = shutil.which("sail_riscv_sim")
    if sail_bin is None:
        pytest.skip("sail_riscv_sim is not installed (it is in the frost image)")

    sail_config = test_testrig.write_sail_config(30, tmp_path)
    paths = misaligned.write_tests(tmp_path / "misaligned")

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
            trap_counts: dict[str, int] = {}
            for path in paths:
                items = [
                    (
                        int(line.split()[1], 16),
                        line.split("# ", 1)[1],
                    )
                    for line in path.read_text(encoding="utf-8").splitlines()
                    if line.startswith(".4byte ")
                ]
                words = pre + [word for word, _ in items]
                traps = 0
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
                    for offset, _ in enumerate(batch):
                        pkt = rvfi_dii.decode_v2(reader)
                        idx = start + offset - len(pre)
                        if idx >= 0:
                            if pkt.trap:
                                # Every trapping case in this trace set must
                                # report zero mem_wmask so FROST and Sail match.
                                assert pkt.mem_wmask == 0, (
                                    path.name,
                                    idx,
                                    items[idx][1],
                                    pkt,
                                )
                                traps += 1
                sock.sendall(
                    rvfi_dii.DiiPacket(0, 1, rvfi_dii.CMD_END_OF_TRACE).encode()
                )
                assert rvfi_dii.decode_v2(reader).halt == 1
                trap_counts[path.name] = traps

            # Bare DDR traces must not trap at all.
            assert trap_counts["01_bare_int_offsets_boundaries.S"] == 0
            assert trap_counts["02_bare_fp_and_compressed.S"] == 0
            # Sv39 legal trace traps only on the three ecall returns to M-mode.
            assert trap_counts["03_sv39_same_and_cross_page.S"] == 3
            # Fault traces must exercise many second-page and region traps.
            assert trap_counts["04_sv39_second_page_faults.S"] >= 35
            assert trap_counts["05_region_misaligned_and_access_traps.S"] >= 60
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_ci_scalar_testrig_runs_misaligned_trace_set() -> None:
    """The recurring scalar TestRIG CI job replays --misaligned on shard 1."""
    workflow = yaml.safe_load((REPO_ROOT / ".github/workflows/ci.yml").read_text())
    steps = workflow["jobs"]["test-testrig"]["steps"]
    step = next(
        s
        for s in steps
        if s["name"] == "Replay saved TestRIG counterexamples and counter controls"
    )
    found = False
    for line in step["run"].splitlines():
        if "--misaligned" in line:
            tokens = shlex.split(line)
            args = tokens[tokens.index("tests/test_testrig.py") + 1 :]
            parsed = test_testrig.parse_arguments(args)
            assert parsed.misaligned is True
            assert parsed.continue_on_fail is True
            found = True
    assert found
