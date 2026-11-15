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

"""Unit tests for the TestRIG Sv39 MMU and CMO/Sstvala generators."""

import importlib
import random
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
VERIF_DIR = REPO_ROOT / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))

mmu = importlib.import_module("testrig.mmu")
cmo = importlib.import_module("testrig.cmo")
preamble = importlib.import_module("testrig.preamble")
rvfi_dii = importlib.import_module("testrig.rvfi_dii")
test_testrig = importlib.import_module("test_testrig")

GOLDEN = [
    (mmu.sfence_vma(0, 0), 0x12000073),
    (mmu.sfence_vma(5, 0), 0x12028073),
    (mmu.sfence_vma(0, 6), 0x12600073),
    (mmu.sfence_vma(5, 6), 0x12628073),
    (mmu.amo("amoadd", 8, 5, 6, 8), 0x0053342F),
    (mmu.amo("amoswap", 9, 5, 6, 8), 0x085334AF),
    (mmu.csrr(10, "satp"), 0x18002573),
    (mmu.csrw("satp", 5), 0x18029073),
    (mmu.csrr(11, "mtval"), 0x343025F3),
    (mmu.csrr(12, "stval"), 0x14302673),
    (mmu.MRET, 0x30200073),
    (mmu.SRET, 0x10200073),
    (mmu.EBREAK, 0x00100073),
    (cmo.cbo("cbo.inval", 11), 0x0005A00F),
    (cmo.cbo("cbo.clean", 11), 0x0015A00F),
    (cmo.cbo("cbo.flush", 11), 0x0025A00F),
    (cmo.cbo("cbo.zero", 11), 0x0045A00F),
    (cmo.prefetch("prefetch.i", 10, 0), 0x00056013),
    (cmo.prefetch("prefetch.r", 10, 64), 0x04156013),
    (cmo.prefetch("prefetch.w", 10, -32), 0xFE356013),
    (cmo.lr_d(8, 5), 0x1002B42F),
    (cmo.sc_d(9, 0, 5), 0x1802B4AF),
    (cmo.WRS_NTO, 0x00D00073),
    (cmo.WRS_STO, 0x01D00073),
    (cmo.WFI, 0x10500073),
    (cmo.C_EBREAK, 0x00009002),
    (cmo.C_UNIMP, 0x00000000),
]


@pytest.mark.parametrize(("instruction", "word"), GOLDEN)
def test_encoding(instruction: Any, word: int) -> None:
    """Each encoder word matches the RISC-V specification."""
    assert instruction.word == word, instruction.text


def _simulate_u64_load(seq: list[Any]) -> dict[int, int]:
    """Execute the integer subset used by mmu.load_u64 and return register values."""
    regs = {i: 0 for i in range(32)}
    mask64 = (1 << 64) - 1
    for inst in seq:
        word = inst.word
        opcode = word & 0x7F
        rd = (word >> 7) & 0x1F
        funct3 = (word >> 12) & 0x7
        rs1 = (word >> 15) & 0x1F
        rs2 = (word >> 20) & 0x1F
        imm_i = (word >> 20) & 0xFFF
        simm_i = imm_i - 0x1000 if (imm_i & 0x800) else imm_i
        if opcode == 0x37:  # LUI
            u32 = word & 0xFFFFF000
            val = u32 - (1 << 32) if (u32 & 0x80000000) else u32
        elif opcode == 0x13 and funct3 == 0:  # ADDI
            val = regs[rs1] + simm_i
        elif opcode == 0x13 and funct3 == 6:  # ORI
            val = regs[rs1] | (simm_i & mask64)
        elif opcode == 0x13 and funct3 == 1:  # SLLI
            val = regs[rs1] << (imm_i & 0x3F)
        elif opcode == 0x13 and funct3 == 5:  # SRLI
            val = (regs[rs1] & mask64) >> (imm_i & 0x3F)
        elif opcode == 0x1B and funct3 == 0:  # ADDIW
            low32 = (regs[rs1] + simm_i) & 0xFFFF_FFFF
            val = low32 - (1 << 32) if (low32 & 0x80000000) else low32
        elif opcode == 0x33 and funct3 == 6:  # OR
            val = regs[rs1] | regs[rs2]
        else:
            raise AssertionError(f"unexpected instruction in load_u64: {inst}")
        if rd != 0:
            regs[rd] = val & mask64
    return regs


def test_load_u64_materializes_all_corners() -> None:
    """load_u64 builds exact 64-bit values across sign boundaries and random inputs."""
    rng = random.Random(42)
    values = [
        0,
        1,
        2047,
        2048,
        0x7FFF_F7FF,
        0x7FFF_F800,
        0x7FFF_FFFF,
        0x8000_0000,
        0x8000_0800,
        0xFFFF_F800,
        0xFFFF_FFFF,
        1 << 32,
        (1 << 32) | 0x8000_0001,
        (1 << 63) - 1,
        1 << 63,
        (1 << 64) - 2048,
        (1 << 64) - 1,
        mmu.make_satp(0x1FF, mmu.ROOT_A),
        mmu.make_pte(mmu.PA_HIGH_PPN, mmu.PTE_V | mmu.PTE_R),
        mmu.VA_NEG_MEGA,
    ] + [rng.getrandbits(64) for _ in range(100)]

    for target in values:
        regs = _simulate_u64_load(mmu.load_u64(5, target, scratch=7))
        assert regs[5] == target, hex(target)


@pytest.mark.parametrize(("module", "length"), ((mmu, 350), (cmo, 300)))
def test_seed_reproducibility_and_trace_format(
    tmp_path: Path, module: Any, length: int
) -> None:
    """Identical seeds produce identical trace files with valid .4byte lines."""
    first = module.write_tests(tmp_path / "a", 3, 20261115, length)
    second = module.write_tests(tmp_path / "b", 3, 20261115, length)
    for one, two in zip(first, second, strict=True):
        text = one.read_text(encoding="utf-8")
        assert text == two.read_text(encoding="utf-8")
        body = [line for line in text.splitlines() if not line.startswith("#")]
        assert body[0] == ".noshrink"
        words = 0
        for line in body:
            if line in (".noshrink", ".shrink"):
                continue
            assert re.match(r"^\.4byte 0x[0-9a-f]{8} # \S", line), line
            words += 1
        assert words >= length


def test_mmu_batch_covers_sfence_forms_asid_and_sstvala() -> None:
    """A small MMU batch exercises all four SFENCE.VMA forms, satp, and xtval reads."""
    generator = mmu.Generator(random.Random(99))
    sfence_forms: set[tuple[bool, bool]] = set()
    strand_kinds: set[str] = set()
    texts: list[str] = []
    for _ in range(25):
        for strand in generator.test(400):
            assert strand.noshrink
            if strand.check is not None:
                strand_kinds.add(strand.check.kind)
            for inst in strand.instructions:
                texts.append(inst.text)
                if (inst.word & 0xFE007FFF) == 0x12000073:
                    rs1 = (inst.word >> 15) & 0x1F
                    rs2 = (inst.word >> 20) & 0x1F
                    sfence_forms.add((rs1 != 0, rs2 != 0))
    assert sfence_forms == {(False, False), (True, False), (False, True), (True, True)}
    assert "noncanonical_fetch" in mmu.STRAND_KINDS
    assert strand_kinds == set(mmu.STRAND_KINDS)
    joined = "\n".join(texts)
    for token in (
        "csrw satp,",
        "csrr ",
        "mtval",
        "stval",
        "mret",
        "sret",
    ):
        assert token in joined, token


def test_cmo_batch_covers_zicbom_zicboz_zicbop_and_zawrs() -> None:
    """A small CMO batch emits all cache-block, prefetch, Zawrs, and envcfg forms."""
    generator = cmo.Generator(random.Random(101))
    texts = [
        inst.text
        for _ in range(25)
        for strand in generator.test(320)
        for inst in strand.instructions
    ]
    joined = "\n".join(texts)
    for token in (
        "cbo.inval ",
        "cbo.clean ",
        "cbo.flush ",
        "cbo.zero ",
        "prefetch.i ",
        "prefetch.r ",
        "prefetch.w ",
        "wrs.nto",
        "wrs.sto",
        "wfi",
        "csrw menvcfg,",
        "csrw senvcfg,",
        "mtval",
        "stval",
    ):
        assert token in joined, token


def test_cli_flags_for_mmu_and_cmo() -> None:
    """test_testrig parses --mmu and --cmo and rejects conflicting mode combinations."""
    mmu_args = test_testrig.parse_arguments(["--mmu", "25", "--seed", "7"])
    assert mmu_args.mmu == 25 and mmu_args.cmo == 0 and mmu_args.seed == 7
    cmo_args = test_testrig.parse_arguments(["--cmo", "30"])
    assert cmo_args.cmo == 30 and cmo_args.mmu == 0
    for bad in (
        ["--mmu", "-1"],
        ["--cmo", "-1"],
        ["--zcb", "-1"],
        ["--mmu", "5", "--cmo", "5"],
        ["--mmu", "5", "--atomics", "5"],
        ["--mmu", "5", "--zcb", "5"],
        ["--mmu", "5", "--fp-ext", "5"],
        ["--cmo", "5", "--sscofpmf"],
        ["--mmu", "5", "--vector", "5"],
    ):
        with pytest.raises(SystemExit):
            test_testrig.parse_arguments(bad)


def test_verify_mode_rvfi_detects_missed_traps_tval_and_unreached_kinds() -> None:
    """verify_mode_rvfi flags missed predicted traps, bad CSR reads, and zero-hit kinds."""
    strand = mmu.Strand(
        True,
        [
            mmu.jalr(8, 5, 0),
            mmu.alu_imm("addi", 9, 0, 7),
            mmu.csrr(10, "mtval"),
            mmu.csrr(11, "mepc"),
            mmu.csrr(12, "mcause"),
        ],
        mmu.StrandCheck(
            kind="instr_page_fault",
            priv=mmu.PRIV_S,
            target_index=1,
            will_trap=True,
            expected_cause=12,
            cause_index=4,
            tval_index=2,
            expected_tval=0x0022_3000,
            handler_priv=mmu.PRIV_M,
            extra_retire_indices=(0,),
        ),
    )
    digest = mmu.trace_digest([inst.word for inst in strand.instructions])
    good_records = [
        rvfi_dii.RvfiRecord(mode=mmu.PRIV_S, trap=0, rd_addr=8, rd_wdata=0x8000_0104),
        rvfi_dii.RvfiRecord(mode=mmu.PRIV_S, trap=1),
        rvfi_dii.RvfiRecord(mode=mmu.PRIV_M, trap=0, rd_addr=10, rd_wdata=0x0022_3000),
        rvfi_dii.RvfiRecord(mode=mmu.PRIV_M, trap=0, rd_addr=11, rd_wdata=0x0022_3000),
        rvfi_dii.RvfiRecord(mode=mmu.PRIV_M, trap=0, rd_addr=12, rd_wdata=12),
    ]

    ok = mmu.verify_mode_rvfi(
        "mmu",
        ("instr_page_fault",),
        [[strand]],
        {digest: good_records},
        require_all_kinds=True,
    )
    assert ok.errors == []
    assert ok.fault_xtval_reads == 1
    assert ok.sequences_reached["instr_page_fault"] == 1
    assert "instr_page_fault" in mmu.format_behavior_summary(ok)

    # A predicted trap that retires instead of trapping fails verification.
    missed_trap = list(good_records)
    missed_trap[1] = rvfi_dii.RvfiRecord(mode=mmu.PRIV_S, trap=0, rd_addr=9, rd_wdata=7)
    missed = mmu.verify_mode_rvfi(
        "mmu",
        ("instr_page_fault",),
        [[strand]],
        {digest: missed_trap},
        require_all_kinds=True,
    )
    assert any("expected trap=1" in err for err in missed.errors)

    # A trapping xtval CSR read (as happens if jalr lacks a filler instruction) fails.
    trapping_tval = list(good_records)
    trapping_tval[2] = rvfi_dii.RvfiRecord(mode=mmu.PRIV_S, trap=1)
    bad_tval = mmu.verify_mode_rvfi(
        "mmu",
        ("instr_page_fault",),
        [[strand]],
        {digest: trapping_tval},
        require_all_kinds=True,
    )
    assert bad_tval.fault_xtval_reads == 0
    assert any("xtval CSR read" in err for err in bad_tval.errors)

    # Requiring full catalog coverage fails when a strand kind has zero hits.
    unreached = mmu.verify_mode_rvfi(
        "mmu",
        ("instr_page_fault", "store_page_fault"),
        [[strand]],
        {digest: good_records},
        require_all_kinds=True,
    )
    assert any("store_page_fault" in err for err in unreached.errors)


def test_sail_executes_generated_mmu_and_cmo_traces(tmp_path: Path) -> None:
    """Sail executes MMU and CMO batches and satisfies every strand RVFI check."""
    sail_bin = shutil.which("sail_riscv_sim")
    if sail_bin is None:
        pytest.skip("sail_riscv_sim is not installed (it is in the frost image)")

    sail_config = test_testrig.write_sail_config(30, tmp_path)
    mmu_paths, mmu_strands = mmu.write_tests_with_strands(
        tmp_path / "mmu", 12, 20261115, 350
    )
    cmo_paths, cmo_strands = cmo.write_tests_with_strands(
        tmp_path / "cmo", 10, 20261115, 300
    )

    port, unused_port = test_testrig.free_ports()
    _ = unused_port
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

            for mode_name, catalog, paths, strand_lists in (
                ("mmu", mmu.STRAND_KINDS, mmu_paths, mmu_strands),
                ("cmo", cmo.STRAND_KINDS, cmo_paths, cmo_strands),
            ):
                records_by_digest: dict[str, list[Any]] = {}
                for trace_path in paths:
                    pre = list(preamble.reset_preamble())
                    body_words = [
                        int(line.split()[1], 16)
                        for line in trace_path.read_text(encoding="utf-8").splitlines()
                        if line.startswith(".4byte ")
                    ]
                    words = pre + body_words
                    records: list[Any] = []
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
                            if start + offset >= len(pre):
                                assert pkt.pc_wdata != 0, (trace_path, hex(word), pkt)
                                assert pkt.insn != 0 or word == 0 or pkt.trap == 1, (
                                    trace_path,
                                    hex(word),
                                    pkt,
                                )
                                records.append(pkt)
                    sock.sendall(
                        rvfi_dii.DiiPacket(0, 1, rvfi_dii.CMD_END_OF_TRACE).encode()
                    )
                    halt = rvfi_dii.decode_v2(reader)
                    assert halt.halt == 1
                    records_by_digest[mmu.trace_digest(body_words)] = records

                summary = mmu.verify_mode_rvfi(
                    mode_name,
                    catalog,
                    strand_lists,
                    records_by_digest,
                    require_all_kinds=True,
                )
                assert summary.errors == [], summary.errors
                assert summary.fault_xtval_reads > 0
                for kind in catalog:
                    assert summary.sequences_reached[kind] > 0, (mode_name, kind)
                table = mmu.format_behavior_summary(summary)
                assert f"RVFI strand behavior summary ({mode_name}," in table
    finally:
        proc.terminate()
        proc.wait(timeout=5)
