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

"""Fast checks of TestRIG startup, RVFI-DII packets, and the preamble."""

import errno
import importlib
import json
import re
import shutil
import socket
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
VERIF_DIR = REPO_ROOT / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))

rvfi_dii = importlib.import_module("testrig.rvfi_dii")
preamble = importlib.import_module("testrig.preamble")
test_testrig = importlib.import_module("test_testrig")


def test_server_ports_survive_immediate_reuse(monkeypatch: pytest.MonkeyPatch) -> None:
    """A released ephemeral port may be assigned to the very next bind."""
    first_port: int | None = None

    class ReusingSocket(socket.socket):
        """Prefer the first probe's port whenever the kernel permits it."""

        def bind(self, address: Any) -> None:
            nonlocal first_port
            if address[1] == 0 and first_port is not None:
                try:
                    super().bind((address[0], first_port))
                    return
                except OSError as error:
                    if error.errno != errno.EADDRINUSE:
                        raise
            super().bind(address)
            if first_port is None:
                first_port = self.getsockname()[1]

    monkeypatch.setattr(socket, "socket", ReusingSocket)
    sail_port, frost_port = test_testrig.free_ports()
    assert sail_port != frost_port
    assert sail_port != 0 and frost_port != 0
    # The implementations must be able to take ownership of both ports.
    with (
        socket.create_server(("127.0.0.1", sail_port)),
        socket.create_server(("127.0.0.1", frost_port)),
    ):
        pass


@pytest.mark.parametrize(
    ("kind", "pattern", "production_only"),
    (
        (
            "parameter",
            r"\bparameter\s+((?:int unsigned|longint unsigned|bit|logic)"
            r"(?:\s*\[[^\]]+\])?)\s+(\w+)",
            {"ASYNC_CPU_CLOCK", "CACHE_NORMAL_MEMORY", "BOOT_ADDR"},
        ),
        (
            "port",
            r"\b((?:input|output|inout)\s+logic(?:\s*\[[^\]]+\])?)\s+(\w+)",
            {"i_cpu_clk"},
        ),
    ),
)
def test_platform_interface_matches_testrig_fixture(
    kind: str, pattern: str, production_only: set[str]
) -> None:
    """The TestRIG replacement accepts the platform's shared interface."""
    interfaces = []
    for path in ("hw/rtl/platform_top.sv", "hw/sim/frost_rvfi_platform.sv"):
        source = (REPO_ROOT / path).read_text(encoding="utf-8")
        source = re.sub(r"//[^\n]*|/\*.*?\*/", "", source, flags=re.S)
        header = re.search(
            r"\bmodule\s+\w+\s*#\((.*?)\)\s*\((.*?)\)\s*;", source, flags=re.S
        )
        assert header is not None, path
        interface = {}
        for declaration in header[1 if kind == "parameter" else 2].split(","):
            match = re.fullmatch(
                pattern + r"(?:\s*=\s*.+)?", declaration.strip(), flags=re.S
            )
            assert match is not None, (path, declaration)
            datatype, name = match.groups()
            assert name not in interface, (path, name)
            interface[name] = re.sub(r"\s+", "", datatype)
        interfaces.append(interface)
    production, fixture = interfaces
    # TestRIG injects instructions at reset and uses a single CPU clock with
    # fixed-latency Normal memory. These controls belong to platform_top.
    for name in production_only:
        production.pop(name)
    assert fixture == production


@pytest.mark.parametrize("capacity_log2_bytes", (30, 36, 37))
@pytest.mark.parametrize("sscofpmf", (False, True))
def test_sail_ddr_capacity_matches_frost(
    tmp_path: Path, capacity_log2_bytes: int, sscofpmf: bool
) -> None:
    """The generated Sail region follows the FROST capacity selection."""
    path = test_testrig.write_sail_config(
        capacity_log2_bytes, tmp_path, sscofpmf=sscofpmf
    )
    config = json.loads(path.read_text(encoding="utf-8"))
    regions = config["memory"]["regions"]
    ddr = [region for region in regions if region["base"]["value"] == "0x80000000"]
    assert len(ddr) == 1
    assert int(ddr[0]["size"]["value"], 16) == 1 << capacity_log2_bytes
    assert len(regions) == len(test_testrig.atomics.load_regions())
    assert config["extensions"]["Zihpm"]["supported"] == sscofpmf
    assert config["extensions"]["Sscofpmf"]["supported"]
    assert config["platform"]["reservation"] == {
        "reservation_set_size_exp": 5,
        "require_exact_reservation_addr": False,
        "invalidate_on_same_hart_store": True,
    }


def test_default_csr_view_keeps_absent_hpm_aliases() -> None:
    """Default generation checks absent aliases; Sscofpmf needs its own view."""
    include = re.compile(test_testrig.DEFAULT_CSR_INCLUDE)
    for counter in range(11, 32):
        assert include.fullmatch(f"hpmcounter{counter}")
    assert include.fullmatch("medeleg")
    assert not include.fullmatch("mideleg")
    assert not include.fullmatch("scountovf")


def test_dii_packet_wire_layout() -> None:
    """Instruction word, time, and command sit where TestRIG puts them."""
    wire = bytes([0x13, 0x00, 0x10, 0x00, 0x01, 0x00, 0x01, 0x00])
    packet = rvfi_dii.DiiPacket.decode(wire)
    assert (packet.insn, packet.time, packet.cmd) == (0x00100013, 1, 1)
    assert packet.encode() == wire
    query = rvfi_dii.DiiPacket(rvfi_dii.VERSION_QUERY_WORD, 1, 0)
    assert query.is_version_query
    assert not rvfi_dii.DiiPacket(rvfi_dii.VERSION_QUERY_WORD, 1, 1).is_version_query


def test_version_negotiation_packets() -> None:
    """A version-1 halt of 3 advertises version 2; the ack echoes the version."""
    reply = rvfi_dii.version_query_response()
    assert len(reply) == rvfi_dii.V1_PACKET_BYTES
    # QuickCheckVEngine reads the halt byte at offset 86.
    assert reply[86] == 3
    assert rvfi_dii.version_ack(2) == b"version=" + (2).to_bytes(8, "little")


def _decode(data: bytes) -> Any:
    left, right = socket.socketpair()
    with left, right:
        left.sendall(data)
        return rvfi_dii.decode_v2(rvfi_dii.PacketReader(right))


def test_v2_round_trip_with_store() -> None:
    """A store record carries both extension blocks and decodes unchanged."""
    record = rvfi_dii.RvfiRecord(
        order=7,
        insn=0x00B53023,
        mode=rvfi_dii.MODE_SUPERVISOR,
        pc_rdata=0x8000_0010,
        pc_wdata=0x8000_0014,
        rd_addr=0,
        mem_addr=0x8000_8000,
        mem_wmask=0xFF,
        mem_wdata=0x0123_4567_89AB_CDEF,
    )
    data = record.encode_v2()
    assert data[:8] == b"trace-v2"
    expected_size = (
        rvfi_dii.V2_HEADER_BYTES
        + rvfi_dii.V2_INT_DATA_BYTES
        + rvfi_dii.V2_MEM_DATA_BYTES
    )
    assert len(data) == expected_size
    assert int.from_bytes(data[8:16], "little") == expected_size
    assert _decode(data) == record


def test_v2_halt_token_is_header_only() -> None:
    """Like Sail's, a halt token has no extension blocks."""
    data = rvfi_dii.RvfiRecord.halt_token().encode_v2()
    assert len(data) == rvfi_dii.V2_HEADER_BYTES
    decoded = _decode(data)
    assert decoded.halt == 1
    assert decoded.rd_addr == 0 and decoded.mem_wmask == 0


def test_v1_layout_matches_testrig() -> None:
    """Fields land at the byte offsets of TestRIG's 88-byte packet."""
    record = rvfi_dii.RvfiRecord(
        order=1, pc_rdata=2, pc_wdata=3, insn=4, rd_wdata=5, rd_addr=9, trap=1
    )
    data = record.encode_v1()
    assert len(data) == rvfi_dii.V1_PACKET_BYTES
    assert int.from_bytes(data[0:8], "little") == 1
    assert int.from_bytes(data[16:24], "little") == 3
    assert int.from_bytes(data[48:56], "little") == 5
    assert (data[84], data[85]) == (9, 1)


def test_preamble_ends_just_below_the_test() -> None:
    """The jump lands the last two words at 0x8000_0000 - 8, minstret last."""
    words = preamble.reset_preamble()
    assert all(word & 0b11 == 0b11 for word in words), "all words are 32-bit"
    jalr_index = next(i for i, word in enumerate(words) if word & 0x7F == 0x67)
    assert len(words) - jalr_index - 1 == 2
    # csrrw x0, minstret, x0
    assert words[-1] == (preamble.CSR_MINSTRET << 20) | (0b001 << 12) | 0x73
    # The four instructions before the jump build the landing address in x31.
    x31 = 0
    for word in words[jalr_index - 4 : jalr_index]:
        opcode, funct3 = word & 0x7F, (word >> 12) & 0x7
        immediate = word >> 20
        if opcode == 0x37:
            x31 = ((word >> 12) << 12) & 0xFFFF_FFFF
            x31 = x31 - (1 << 32) if x31 & 0x8000_0000 else x31
            x31 &= (1 << 64) - 1
        elif funct3 == 0b001:
            x31 = (x31 << (immediate & 0x3F)) & ((1 << 64) - 1)
        elif funct3 == 0b101:
            x31 >>= immediate & 0x3F
        else:
            immediate = immediate - 4096 if immediate & 0x800 else immediate
            x31 = (x31 + immediate) & ((1 << 64) - 1)
    assert x31 == preamble.TEST_START_PC - 8


@pytest.mark.parametrize("sscofpmf", (False, True))
def test_sail_config_validates(tmp_path: Path, sscofpmf: bool) -> None:
    """The FROST override merges into a configuration Sail accepts."""
    sail = shutil.which("sail_riscv_sim")
    if sail is None:
        pytest.skip("sail_riscv_sim is not installed (it is in the frost image)")
    config = test_testrig.write_sail_config(30, tmp_path, sscofpmf=sscofpmf)
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
    assert re.match(r"rv64imafdcb_zicntr_zicond_zicsr_zifencei_zihintpause", isa)
    assert ("zihpm" in isa.strip().split("_")) == sscofpmf
