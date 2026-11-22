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
import threading
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
            r"\b((?:parameter|localparam)\s+(?:int unsigned|longint unsigned|bit|logic)"
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


def _balanced(text: str, start: int) -> int:
    """Index just past the parenthesis group that opens at text[start]."""
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    raise AssertionError("unbalanced parentheses")


def _split_top_level(text: str) -> list[str]:
    """Split on commas that are not inside (), [] or {}."""
    parts, depth, current = [], 0, ""
    for char in text:
        depth += char in "([{"
        depth -= char in ")]}"
        if char == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += char
    parts.append(current)
    return [part for part in parts if part.strip()]


def test_platform_connects_every_cpu_ooo_port() -> None:
    """Every cpu_ooo output and every input without a default is connected.

    The platform builds with Verilator warnings fatal, so a port added to
    cpu_ooo and not named here only shows up in the TestRIG job. Inputs that
    have a default may be left unnamed.
    """

    def strip(text: str) -> str:
        return re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S)

    rtl = strip(
        (REPO_ROOT / "hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv").read_text(
            encoding="utf-8"
        )
    )
    header = re.search(r"\bmodule\s+cpu_ooo\s*#\s*\(", rtl)
    assert header is not None
    ports_open = rtl.index("(", _balanced(rtl, header.end() - 1))
    ports_text = rtl[ports_open + 1 : _balanced(rtl, ports_open) - 1]
    ports = set()
    for declaration in _split_top_level(ports_text):
        # A default is a "=" outside any dimension or expression.
        flat = re.sub(r"\[[^\]]*\]|\([^)]*\)", "", declaration)
        name_part, has_default, _ = flat.partition("=")
        name_part = name_part.strip()
        assert re.match(r"(input|output|inout)\b", name_part), declaration
        if name_part.startswith("input") and has_default:
            continue  # may be left at its default
        ports.add(re.findall(r"\w+", name_part)[-1])
    assert len(ports) > 100

    platform = strip(
        (REPO_ROOT / "hw/sim/frost_rvfi_platform.sv").read_text(encoding="utf-8")
    )
    instance = re.search(r"\bcpu_ooo\s*#\s*\(", platform)
    assert instance is not None
    after_parameters = _balanced(platform, instance.end() - 1)
    pins_open = platform.index("(", after_parameters)
    pins_text = platform[pins_open : _balanced(platform, pins_open)]
    assert ".*" not in pins_text, "name every cpu_ooo port explicitly"
    # Only associations at the top level of the pin list count, not member
    # references such as cpu_inst.o_x inside another pin's expression.
    top_level, depth = "", 0
    for char in pins_text[1:-1]:
        if depth == 0:
            top_level += char
        depth += char in "([{"
        depth -= char in ")]}"
    connected = set(re.findall(r"\.(\w+)\s*(?:,|$|\()", top_level))
    assert ports - connected == set()


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
    assert config["extensions"]["Zihpm"]["supported"]
    assert config["extensions"]["Sscofpmf"]["supported"]
    assert config["extensions"]["Svinval"]["supported"]
    assert config["platform"]["reservation"] == {
        "reservation_set_size_exp": 5,
        "require_exact_reservation_addr": False,
        "invalidate_on_same_hart_store": True,
    }


def test_sail_wfi_overlay_is_opt_in(tmp_path: Path) -> None:
    """The WFI configuration changes only the WFI model settings."""
    base = test_testrig.write_sail_config(30, tmp_path)
    directed = test_testrig.write_sail_config(30, tmp_path, wfi_mode=True)
    assert base != directed
    expected = test_testrig.load_sail_json(base)
    assert expected["platform"]["wfi_is_nop"] is True
    expected["platform"].update(wfi_is_nop=False, max_time_to_wait=0)
    assert test_testrig.load_sail_json(directed) == expected


def _sail_header(record: Any) -> bytes:
    """Use Sail's header-only reply with no valid bit or extension blocks."""
    encoded = record.encode_v2()
    return (
        encoded[:8]
        + rvfi_dii.V2_HEADER_BYTES.to_bytes(8, "little")
        + encoded[16:37]
        + bytes(3)
        + encoded[40:56]
        + bytes(8)
    )


@pytest.mark.parametrize(
    "case",
    (
        "wake",
        "tw",
        "u-trap",
        "trailing",
        "extra-tick",
        "interrupt",
        "nop",
        "m-trap",
        "wrong-insn",
        "bad-padding",
    ),
)
def test_sail_wfi_monitor(case: str) -> None:
    """Only the bounded Sail wait is folded, replaying the consumed packet once."""
    wire = rvfi_dii
    stats = test_testrig.run_stats
    pc = 0x8000_0100
    successor = pc + 4 if case in ("wake", "bad-padding") else 0x8000_0400
    start = wire.RvfiRecord(
        order=17,
        insn=wire.WFI_INSN,
        pc_rdata=pc,
        mode=wire.MODE_MACHINE if case in ("wake", "m-trap") else wire.MODE_SUPERVISOR,
    )
    if case == "u-trap":
        start.mode, start.trap, start.pc_wdata = wire.MODE_USER, 1, successor
    if case == "nop":
        start.pc_wdata = pc + 4
    first = _sail_header(start)
    second = _sail_header(
        wire.RvfiRecord(
            mode=0,
            ixl=0,
            trap=int(case in ("tw", "interrupt", "m-trap")),
            intr=int(case == "interrupt"),
            pc_wdata=0 if case == "extra-tick" else successor,
        )
    )
    if case == "bad-padding":
        second = second[:38] + b"\x01" + second[39:]
    instruction = wire.DiiPacket(0x00100513, 19, wire.CMD_INSTRUCTION).encode()
    after = wire.RvfiRecord(
        order=18,
        insn=0x00100513,
        pc_rdata=successor,
        pc_wdata=successor + 4,
        rd_addr=10,
        rd_wdata=1,
    ).encode_v2()
    query = wire.DiiPacket(wire.VERSION_QUERY_WORD, 0, wire.CMD_END_OF_TRACE).encode()
    version = wire.DiiPacket(2, 0, wire.CMD_SET_VERSION).encode()
    wfi = wire.DiiPacket(wire.WFI_INSN, 1, wire.CMD_INSTRUCTION).encode()
    end = wire.DiiPacket(0, 0, wire.CMD_END_OF_TRACE).encode()
    halt = wire.RvfiRecord.halt_token().encode_v2()
    success = case in ("wake", "tw", "u-trap")
    first_request = instruction if case == "wrong-insn" else wfi
    send_followup = case not in ("trailing", "nop", "wrong-insn")
    exchange = [
        (query, wire.version_query_response()),
        (version, wire.version_ack(2)),
        (first_request, first),
    ]
    if send_followup and case != "u-trap":
        exchange.append((instruction, second))
    if success:
        exchange.extend(((instruction, after), (end, halt)))

    with socket.create_server(("127.0.0.1", 0)) as listener:
        listener.settimeout(3)
        failures: list[Exception] = []

        def serve() -> None:
            try:
                with listener.accept()[0] as peer:
                    peer.settimeout(3)
                    reader = wire.PacketReader(peer)
                    for request, response in exchange:
                        assert reader.read(wire.DII_PACKET_BYTES) == request
                        peer.sendall(response)
                    # In particular, a trailing WFI never forwards the end
                    # command, and an invalid wait reply never resends a word.
                    assert peer.recv(1) == b""
            except Exception as error:
                failures.append(error)

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        monitor = stats.WfiTraceMonitor("Sail", listener.getsockname()[1], 3)
        try:
            with socket.create_connection(
                ("127.0.0.1", monitor.port), timeout=3
            ) as engine:
                reader = wire.PacketReader(engine)
                engine.sendall(query + version)
                assert reader.read(88) == wire.version_query_response()
                assert reader.read(16) == wire.version_ack(2)
                engine.sendall(
                    first_request + (instruction if send_followup else b"") + end
                )
                if success:
                    start.trap, start.pc_wdata = int(case != "wake"), successor
                    expected = _sail_header(start) + after + halt
                    assert reader.read(len(expected)) == expected
                else:
                    assert engine.recv(1) == b""
            worker.join(timeout=3)
            assert not worker.is_alive()
        finally:
            monitor.close()
            worker.join(timeout=3)
    assert not failures
    if success:
        assert monitor.traces == [stats.TraceCounts(2, 2)]
        assert not monitor.errors
    else:
        assert not monitor.traces
        expected_error = {
            "trailing": "must be followed by an instruction",
            "nop": "unexpected Sail WFI reply",
            "extra-tick": "unexpected Sail WFI completion reply",
            "interrupt": "unexpected Sail WFI completion reply",
            "m-trap": "unexpected Sail WFI completion reply",
            "wrong-insn": "unexpected Sail instruction reply in WFI mode",
            "bad-padding": "unexpected Sail WFI completion reply",
        }[case]
        assert expected_error in monitor.errors[0]


@pytest.mark.parametrize("timeout_wakes", (0, 1))
def test_wfi_short_trace_diagnoses_missing_wake(
    tmp_path: Path, timeout_wakes: int
) -> None:
    """Report an unfinished wait from the DUT counters and partial trace."""
    strand = test_testrig.wfi.write_tests(tmp_path)[0]
    observation = {
        "wfi": {
            "wait_entries": 1,
            "source_wakes": 0,
            "timeout_wakes": timeout_wakes,
            "retired_after_wake": 0,
            "commit_while_waiting": 0,
            "pending": 0,
        },
        "records": [[rvfi_dii.MODE_MACHINE, 0, 5, 0]] * (strand.target_index - 1),
    }
    errors = test_testrig.wfi.verify(strand, observation)
    assert ("WFI never woke" in errors) == (timeout_wakes == 0)


def test_default_csr_view_keeps_absent_hpm_aliases() -> None:
    """Default generation includes Zihpm user aliases, stimecmp, scountovf and mideleg."""
    include = re.compile(test_testrig.DEFAULT_CSR_INCLUDE)
    for counter in range(3, 32):
        assert include.fullmatch(f"hpmcounter{counter}")
    for counter in range(3, 11):
        assert not include.fullmatch(f"mhpmevent{counter}")
    assert include.fullmatch("medeleg")
    assert include.fullmatch("mideleg")
    assert include.fullmatch("stimecmp")
    assert include.fullmatch("scountovf")


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
    assert re.match(
        r"rv64imafdcb_zic64b_zicbom_zicbop_zicboz_ziccif_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zihpm",
        isa,
    )
    tokens = set(isa.strip().split("_"))
    for ext in (
        "zkt",
        "sscounterenw",
        "sstvecd",
        "zcb",
        "zcmop",
        "zimop",
        "zihintntl",
        "zihpm",
        "svinval",
        "sscofpmf",
    ):
        assert ext in tokens
    assert "zicclsm" not in tokens


def test_svinval_generator_reproducibility_and_coverage(tmp_path: Path) -> None:
    """verif/testrig/svinval.py writes deterministic traces covering Svinval forms."""
    dir_a = tmp_path / "a"
    dir_b = tmp_path / "b"
    paths_a = test_testrig.svinval.write_tests(
        dir_a, count=8, seed=20261115, length=120
    )
    paths_b = test_testrig.svinval.write_tests(
        dir_b, count=8, seed=20261115, length=120
    )
    assert len(paths_a) == 8
    texts_a = [p.read_text(encoding="utf-8") for p in paths_a]
    texts_b = [p.read_text(encoding="utf-8") for p in paths_b]
    assert texts_a == texts_b

    joined = "\n".join(texts_a)
    assert ".noshrink" in joined and ".shrink" in joined
    assert "0x18000073" in joined  # sfence.w.inval
    assert "0x18100073" in joined  # sfence.inval.ir
    assert "0x16000073" in joined  # sinval.vma x0, x0
    assert "remap" in joined
    assert "first insn after U->" in joined
    assert "mop ->" in joined

    args = test_testrig.parse_arguments(["--svinval", "50", "--seed", "7"])
    assert args.svinval == 50 and args.seed == 7
    with pytest.raises(SystemExit):
        test_testrig.parse_arguments(["--sscofpmf", "--svinval", "5"])
    with pytest.raises(SystemExit):
        test_testrig.parse_arguments(["--vector", "2", "--svinval", "5"])


def test_lq_probe_launch_defaults_agree() -> None:
    """All six CPU/SoC tops default LQ_PROBE_LAUNCH=1; standalone units stay 0."""
    enabled_tops = (
        "hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv",
        "hw/rtl/cpu_top/frost_hart.sv",
        "hw/rtl/cpu_top/cpu_top.sv",
        "hw/rtl/platform_top.sv",
        "hw/rtl/frost.sv",
        "hw/sim/frost_rvfi_platform.sv",
    )
    for rel_path in enabled_tops:
        source = (REPO_ROOT / rel_path).read_text(encoding="utf-8")
        assert re.search(
            r"\bparameter\s+bit\s+LQ_PROBE_LAUNCH\s*=\s*1'b1\b", source
        ), f"{rel_path} must default LQ_PROBE_LAUNCH to 1'b1"

    cpu_ooo_src = (
        REPO_ROOT / "hw/rtl/cpu_and_mem/cpu/cpu_ooo/cpu_ooo.sv"
    ).read_text(encoding="utf-8")
    assert ".LQ_PROBE_LAUNCH(LQ_PROBE_LAUNCH && CACHED_TIER_EN)" in cpu_ooo_src

    disabled_units = (
        (
            "hw/rtl/cpu_and_mem/cpu/tomasulo/load_queue/load_queue.sv",
            "PROBE_LAUNCH",
        ),
        (
            "hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/tomasulo_wrapper.sv",
            "LQ_PROBE_LAUNCH",
        ),
        (
            "hw/rtl/cpu_and_mem/cpu/tomasulo/tomasulo_wrapper/"
            "tomasulo_coherent_cut_test_harness.sv",
            "LQ_PROBE_LAUNCH",
        ),
    )
    for rel_path, param_name in disabled_units:
        source = (REPO_ROOT / rel_path).read_text(encoding="utf-8")
        assert re.search(
            rf"\bparameter\s+bit\s+{param_name}\s*=\s*1'b0\b", source
        ), f"{rel_path} must keep {param_name} defaulting to 1'b0"

    subsystem = (REPO_ROOT / "boards/xilinx_frost_subsystem.sv").read_text(
        encoding="utf-8"
    )
    assert "LQ_PROBE_LAUNCH" not in subsystem
