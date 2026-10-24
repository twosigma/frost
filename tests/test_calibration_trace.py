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

"""Tests for the real-program bench's calibration capture, on a stand-in DUT."""

import hashlib
import importlib
import json
import logging
import re
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any

import cocotb
import pytest

VERIF_DIR = Path(__file__).resolve().parents[1] / "verif"
if str(VERIF_DIR) not in sys.path:
    sys.path.insert(0, str(VERIF_DIR))

calibration_trace = importlib.import_module("cocotb_tests.calibration_trace")
cpu_structs = importlib.import_module("cocotb_tests.cpu_structs")
packed_structs = importlib.import_module("utils.packed_structs")

CORE = calibration_trace.CORE_PATH
CPU_TOP = calibration_trace.CPU_TOP_PATH
SLOT2 = f"{CORE}.from_id_to_ex_2"
SLOT2_WIDTH = sum(width for _, width in cpu_structs.ID_TO_EX_FIELDS)


class _Node:
    """A stand-in DUT scope and signal; any child path exists unless absent."""

    def __init__(self, path: str, absent: set[str], widths: dict[str, int]) -> None:
        self._path = path
        self._absent = absent
        self._widths = widths
        self._children: dict[str, _Node] = {}
        self.value: Any = 0

    def __getattr__(self, name: str) -> "_Node":
        if name.startswith("_"):
            raise AttributeError(name)
        path = f"{self._path}.{name}" if self._path else name
        if path in self._absent:
            raise AttributeError(name)
        if name not in self._children:
            self._children[name] = _Node(path, self._absent, self._widths)
        return self._children[name]

    def __len__(self) -> int:
        return self._widths.get(self._path, 1)


def _dut(absent: frozenset[str] = frozenset(), slot2_width: int = SLOT2_WIDTH) -> _Node:
    return _Node("", set(absent), {SLOT2: slot2_width})


def _no_symbols(name: str, app_name: str | None) -> dict[int, tuple[int, int]]:
    raise AssertionError(f"looked up {name} for {app_name}")


# CoreMark's timing functions as sw.S lists them: start_time ends with its
# return, and stop_time starts with the cycle-counter read.
_COREMARK_CODE = {
    "start_time": {
        0x57A8: (0x0010_0793, 32),
        0x5840: (0xC000_22F3, 32),
        0x5844: (0x8051_BC23, 32),
        0x5848: (0x0000_8067, 32),
    },
    "stop_time": {0x584C: (0xC000_27F3, 32), 0x5850: (0x0010_0293, 32)},
}


def _coremark_symbols(name: str, app_name: str | None) -> dict[int, tuple[int, int]]:
    assert app_name == "coremark"
    return _COREMARK_CODE.get(name, {})


# The second of two runs of hello_world, and the first, with the bench's
# 3 ns clock.
_RUN: dict[str, Any] = {
    "app_name": "hello_world",
    "run_number": 2,
    "num_runs": 2,
    "clock_period_ns": 3,
    "symbol_code": _no_symbols,
}
_FIRST_RUN = {**_RUN, "run_number": 1}


def _drive(dut: _Node, values: dict[str, int]) -> None:
    """Set each named signal, and clear every other signal the capture reads."""
    for path in _SIGNALS:
        node: Any = dut
        for part in path.split("."):
            node = getattr(node, part)
        node.value = values.get(path, 0)


_SIGNALS = [
    f"{CORE}.dbg_commit_valid",
    f"{CORE}.dbg_commit_pc",
    f"{CORE}.dbg_commit_2_valid",
    f"{CORE}.dbg_commit_2_pc",
    calibration_trace.COMMIT_MISPREDICTION_PATH,
    f"{CORE}.dbg_rob_alloc_valid",
    f"{CORE}.dbg_dispatch_stall",
    f"{CORE}.dbg_pipeline_stall",
    f"{CORE}.rob_count",
    f"{CORE}.sq_count",
    SLOT2,
    *(
        f"{CPU_TOP}.{port}"
        for port in (
            "o_axi_arvalid",
            "i_axi_arready",
            "o_axi_arid",
            "o_axi_araddr",
            "o_axi_awvalid",
            "i_axi_awready",
            "o_axi_awid",
            "o_axi_awaddr",
            "i_axi_rvalid",
            "o_axi_rready",
            "i_axi_rid",
            "i_axi_rresp",
            "i_axi_bvalid",
            "o_axi_bready",
            "i_axi_bid",
            "i_axi_bresp",
        )
    ),
]


@pytest.fixture(autouse=True)
def _environment(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """Give cocotb a log and clear the capture's settings."""
    monkeypatch.setattr(cocotb, "log", logging.getLogger("test"), raising=False)
    for name in (
        "FROST_CALIBRATION_TRACE_PATH",
        "FROST_CALIBRATION_COUNTERS_PATH",
        "FROST_CALIBRATION_MANIFEST_PATH",
        "FROST_CALIBRATION_TARGET_RUN",
        "FROST_CALIBRATION_START_PC",
        "FROST_CALIBRATION_STOP_PC",
        "FROST_GIT_COMMIT",
        "FROST_COCOTB_MEM_CONFIG",
        "FROST_VERILATOR_EXTRA_ARGS",
        "FROST_DDR_MODEL_SEED",
        "DDR_MODEL_LATENCY",
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.chdir(tmp_path)


def test_capture_is_off_without_a_trace_path_or_for_another_run(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Only the target run, the last one by default, records a trace."""
    trace = calibration_trace.CalibrationTrace
    assert trace.from_environment(_dut(), **_RUN) is None
    monkeypatch.setenv("FROST_CALIBRATION_TRACE_PATH", str(tmp_path / "t.jsonl"))
    assert trace.from_environment(_dut(), **_FIRST_RUN) is None
    assert trace.from_environment(_dut(), **_RUN) is not None
    monkeypatch.setenv("FROST_CALIBRATION_TARGET_RUN", "1")
    assert trace.from_environment(_dut(), **_FIRST_RUN) is not None


def test_missing_signals_fail_the_capture(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A build without a signal the capture reads fails and names the signal."""
    monkeypatch.setenv("FROST_CALIBRATION_TRACE_PATH", str(tmp_path / "t.jsonl"))
    absent = frozenset({f"{CORE}.rob_count", f"{CPU_TOP}.i_axi_bid"})
    with pytest.raises(
        AssertionError,
        match=(
            "FROST_CALIBRATION_TRACE_PATH needs signals this build does not expose: "
            f"{CORE}.rob_count, {CPU_TOP}.i_axi_bid$"
        ),
    ):
        calibration_trace.CalibrationTrace.from_environment(_dut(absent), **_RUN)


def test_a_slot2_layout_of_another_width_fails_the_capture(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The slot-2 packet must match its cpu_structs layout."""
    monkeypatch.setenv("FROST_CALIBRATION_TRACE_PATH", str(tmp_path / "t.jsonl"))
    with pytest.raises(AssertionError, match="bits wide"):
        calibration_trace.CalibrationTrace.from_environment(
            _dut(slot2_width=SLOT2_WIDTH + 1), **_RUN
        )


def test_the_window_runs_from_the_start_pc_to_the_stop_pc(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The trace starts the cycle after the start PC retires and ends with the stop PC."""
    trace_path = tmp_path / "t.jsonl"
    counters_path = tmp_path / "counters.json"
    monkeypatch.setenv("FROST_CALIBRATION_TRACE_PATH", str(trace_path))
    monkeypatch.setenv("FROST_CALIBRATION_COUNTERS_PATH", str(counters_path))
    monkeypatch.setenv("FROST_CALIBRATION_START_PC", "0x100")
    monkeypatch.setenv("FROST_CALIBRATION_STOP_PC", "0x200")
    dut = _dut()
    capture = calibration_trace.CalibrationTrace.from_environment(dut, **_RUN)
    assert capture is not None
    real_slot2 = packed_structs.pack_struct(cpu_structs.ID_TO_EX_FIELDS, {"is_real": 1})
    cycles = [
        # The start PC retires: the window opens on the next cycle.
        {f"{CORE}.dbg_commit_valid": 1, f"{CORE}.dbg_commit_pc": 0x100},
        # Two micro-ops dispatch, and an AXI read is accepted.
        {
            f"{CORE}.dbg_rob_alloc_valid": 1,
            SLOT2: real_slot2,
            f"{CORE}.rob_count": 4,
            f"{CPU_TOP}.o_axi_arvalid": 1,
            f"{CPU_TOP}.i_axi_arready": 1,
            f"{CPU_TOP}.o_axi_arid": 34,
            f"{CPU_TOP}.o_axi_araddr": 0x5880,
        },
        # Both slots retire, the second at the stop PC; a write waits.
        {
            f"{CORE}.dbg_commit_valid": 1,
            f"{CORE}.dbg_commit_pc": 0x1FC,
            f"{CORE}.dbg_commit_2_valid": 1,
            f"{CORE}.dbg_commit_2_pc": 0x200,
            f"{CORE}.dbg_dispatch_stall": 1,
            f"{CORE}.rob_count": 2,
            f"{CPU_TOP}.o_axi_awvalid": 1,
            f"{CPU_TOP}.i_axi_rvalid": 1,
            f"{CPU_TOP}.o_axi_rready": 1,
            f"{CPU_TOP}.i_axi_rid": 34,
        },
        # After the window: nothing more is recorded.
        {f"{CORE}.dbg_rob_alloc_valid": 1},
    ]
    for cycle, values in enumerate(cycles):
        _drive(dut, values)
        capture.sample(cycle)
    capture.finish("")

    records = [json.loads(line) for line in trace_path.read_text().splitlines()]
    assert records[0]["event"] == "meta"
    assert records[1:] == [
        {"cycle": 0, "event": "dispatch", "source": "rob", "uops": 2},
        {
            "cycle": 0,
            "event": "axi_request",
            "source": "axi",
            "axi_id": 34,
            "address": "0x00005880",
            "is_write": False,
            "bytes": 64,
        },
        {"cycle": 1, "event": "retire", "source": "rob", "uops": 2},
        {
            "cycle": 1,
            "event": "axi_response",
            "source": "axi",
            "axi_id": 34,
            "ok": True,
        },
    ]
    counters = json.loads(counters_path.read_text())
    assert counters["cycles"] == 2
    assert counters["retired_uops"] == 2
    assert counters["dispatch_distribution"]["cycles_2_uops"] == 1
    assert counters["stalls"]["dispatch_stall_cycles"] == 1
    assert counters["occupancy"]["mean_rob_occupancy"] == 3.0
    assert counters["axi_totals"]["aw_backpressure_cycles"] == 1


def _elf_with_comment(comment: bytes) -> bytes:
    """Return a minimal little-endian ELF64 file whose .comment holds comment."""
    names = b"\0.shstrtab\0.comment\0"
    comment_data = comment + b"\0"
    names_offset = 64
    comment_offset = names_offset + len(names)
    shoff = comment_offset + len(comment_data)
    shoff += -shoff % 8
    image = bytearray(shoff)
    image[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<Q", image, 0x28, shoff)
    struct.pack_into("<HHH", image, 0x3A, 64, 3, 1)
    image[names_offset:comment_offset] = names
    image[comment_offset : comment_offset + len(comment_data)] = comment_data
    for name, kind, offset, size in (
        (0, 0, 0, 0),
        (1, 3, names_offset, len(names)),
        (11, 1, comment_offset, len(comment_data)),
    ):
        image += struct.pack("<IIQQQQIIQQ", name, kind, 0, 0, offset, size, 0, 0, 1, 0)
    return bytes(image)


def test_the_commit_comes_from_frost_git_commit_then_git(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """FROST_GIT_COMMIT wins; otherwise git names HEAD, or the commit is unknown."""
    monkeypatch.setenv("FROST_GIT_COMMIT", " 0123abc ")
    assert calibration_trace.git_commit() == "0123abc"
    monkeypatch.delenv("FROST_GIT_COMMIT")
    monkeypatch.setattr(calibration_trace, "REPOSITORY_ROOT", tmp_path)
    assert calibration_trace.git_commit() == "unknown"
    git = ["git", "-C", str(tmp_path), "-c", "user.name=t", "-c", "user.email=t@t"]
    subprocess.run([*git, "init", "-q"], check=True)
    subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "t"], check=True)
    head = subprocess.run(
        [*git, "rev-parse", "HEAD"], capture_output=True, text=True, check=True
    ).stdout.strip()
    assert calibration_trace.git_commit() == head


def test_ddr_model_settings_follow_the_simulation_arguments() -> None:
    """The last -G argument sets a parameter, over DDR_MODEL_LATENCY."""
    settings = calibration_trace.ddr_model_settings
    assert settings({}) == calibration_trace.DDR_MODEL_DEFAULTS
    assert settings({"DDR_MODEL_LATENCY": "45"})["DDR_MODEL_LATENCY"] == 45
    assert settings(
        {
            "DDR_MODEL_LATENCY": "45",
            "FROST_VERILATOR_EXTRA_ARGS": (
                "-GL2_CACHE_BYTES=4096 -GDDR_MODEL_LATENCY=12 -GDDR_MODEL_REORDER=1 "
                "-GDDR_MODEL_LATENCY=17"
            ),
        }
    ) == {
        "DDR_MODEL_LATENCY": 17,
        "DDR_MODEL_LATENCY_JITTER": 0,
        "DDR_MODEL_REORDER": 1,
    }


def test_ddr_model_defaults_match_the_makefile_and_frost() -> None:
    """The defaults are tests/Makefile's latency and frost.sv's jitter and reordering."""
    root = Path(__file__).resolve().parents[1]
    makefile = (root / "tests" / "Makefile").read_text()
    frost = (root / "hw" / "rtl" / "frost.sv").read_text()
    latency = re.search(r"^DDR_MODEL_LATENCY \?= (\d+)$", makefile, re.MULTILINE)
    assert latency is not None
    expected = {"DDR_MODEL_LATENCY": int(latency.group(1))}
    for name in ("DDR_MODEL_LATENCY_JITTER", "DDR_MODEL_REORDER"):
        default = re.search(rf"parameter int unsigned {name} = (\d+)", frost)
        assert default is not None
        expected[name] = int(default.group(1))
    assert calibration_trace.DDR_MODEL_DEFAULTS == expected


def test_elf_comment_reads_the_compiler_version(tmp_path: Path) -> None:
    """The first .comment string names the compiler; other files give None."""
    elf = tmp_path / "sw.elf"
    elf.write_bytes(
        _elf_with_comment(b"GCC: (toolchains.bootlin.com 2026.08-1) 15.3.0")
    )
    assert (
        calibration_trace.elf_comment(elf)
        == "GCC: (toolchains.bootlin.com 2026.08-1) 15.3.0"
    )
    elf.write_bytes(b"not an ELF file" * 8)
    assert calibration_trace.elf_comment(elf) is None
    assert calibration_trace.elf_comment(tmp_path / "missing.elf") is None


def test_the_manifest_takes_its_metadata_from_the_run(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The commit, tools, clock, tier, DDR settings, and images come from the run."""
    program = tmp_path / "sw" / "apps" / "hello_world"
    program.mkdir(parents=True)
    elf = _elf_with_comment(b"GCC: (vendor) 15.3.0")
    (program / "sw.elf").write_bytes(elf)
    (program / "sw.mem").write_text("@0\n")
    (tmp_path / "sw.mem").symlink_to(program / "sw.mem")
    trace_path = tmp_path / "t.jsonl"
    monkeypatch.setenv("FROST_CALIBRATION_TRACE_PATH", str(trace_path))
    monkeypatch.setenv("FROST_GIT_COMMIT", "abc123")
    monkeypatch.setenv("FROST_COCOTB_MEM_CONFIG", "ddr")
    monkeypatch.setenv(
        "FROST_VERILATOR_EXTRA_ARGS",
        "-GDDR_MODEL_LATENCY=44 -GDDR_MODEL_LATENCY_JITTER=7",
    )
    monkeypatch.setenv("FROST_DDR_MODEL_SEED", "123-job-0")
    capture = calibration_trace.CalibrationTrace.from_environment(_dut(), **_RUN)
    assert capture is not None
    capture.finish("")

    meta = json.loads(trace_path.read_text().splitlines()[0])
    assert meta["rtl_commit"] == "abc123"
    manifest = capture.manifest("", 1.0)
    assert manifest["git_commit"] == "abc123"
    assert manifest["clock_frequency_hz"] == 333_333_333
    assert manifest["environment"] == {
        "toolchain": "GCC: (vendor) 15.3.0",
        "testbench": f"cocotb {cocotb.__version__}",
    }
    assert manifest["memory_configuration"] == {
        "tier": "ddr",
        "ddr_model": "axi_behavioral_memory",
        "ddr_latency": 44,
        "ddr_latency_jitter": 7,
        "ddr_reorder": False,
        "ddr_model_seed": "123-job-0",
    }
    assert manifest["artifacts"] == {
        "sw.elf_sha256": hashlib.sha256(elf).hexdigest(),
        "sw.mem_sha256": hashlib.sha256(b"@0\n").hexdigest(),
    }
    assert "branch" not in manifest and "command_line" not in manifest


def test_coremark_s_window_comes_from_its_timing_functions(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The window runs from start_time's return to stop_time's entry."""
    window = calibration_trace.timed_window
    assert window("coremark", _coremark_symbols) == (0x5848, 0x584C)
    assert window("hello_world", _no_symbols) == (0, 0)
    compressed = {"start_time": {0x10: (0x0001_0793, 32), 0x14: (0x8082, 16)}}
    assert window(
        "coremark", lambda name, _app: {**_COREMARK_CODE, **compressed}[name]
    ) == (0x14, 0x584C)
    monkeypatch.setenv("FROST_CALIBRATION_START_PC", "0x100")
    assert window("coremark", _coremark_symbols) == (0x100, 0x584C)
    monkeypatch.setenv("FROST_CALIBRATION_STOP_PC", "0x200")
    assert window("coremark", _no_symbols) == (0x100, 0x200)


@pytest.mark.parametrize("missing", ["start_time", "stop_time"])
def test_a_coremark_build_without_its_timing_functions_fails(missing: str) -> None:
    """The capture names the function it could not find in sw.S."""
    code = {name: lines for name, lines in _COREMARK_CODE.items() if name != missing}
    with pytest.raises(AssertionError, match=f"sw.S has no .*{missing}"):
        calibration_trace.timed_window(
            "coremark", lambda name, _app: code.get(name, {})
        )


@pytest.mark.parametrize(
    "retired_pcs,error",
    [
        ([], "never retired the start PC 0x100"),
        ([0x100], "never retired the stop PC 0x200"),
    ],
)
def test_a_window_that_never_opens_or_closes_fails(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, retired_pcs: list[int], error: str
) -> None:
    """A run that misses the window's start PC, or its stop PC, fails at the end."""
    monkeypatch.setenv("FROST_CALIBRATION_TRACE_PATH", str(tmp_path / "t.jsonl"))
    monkeypatch.setenv("FROST_CALIBRATION_START_PC", "0x100")
    monkeypatch.setenv("FROST_CALIBRATION_STOP_PC", "0x200")
    dut = _dut()
    capture = calibration_trace.CalibrationTrace.from_environment(dut, **_RUN)
    assert capture is not None
    for cycle, pc in enumerate([*retired_pcs, 0x104, 0x108]):
        _drive(dut, {f"{CORE}.dbg_commit_valid": 1, f"{CORE}.dbg_commit_pc": pc})
        capture.sample(cycle)
    with pytest.raises(AssertionError, match=error):
        capture.finish("")


def test_relative_output_paths_start_at_the_repository_root(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The documented commands name their files from the repository root."""
    monkeypatch.setattr(calibration_trace, "REPOSITORY_ROOT", tmp_path)
    monkeypatch.setenv("FROST_CALIBRATION_TRACE_PATH", "out/t.jsonl")
    monkeypatch.setenv("FROST_CALIBRATION_COUNTERS_PATH", "out/counters.json")
    absolute = tmp_path / "elsewhere" / "manifest.json"
    monkeypatch.setenv("FROST_CALIBRATION_MANIFEST_PATH", str(absolute))
    (tmp_path / "tests").mkdir()
    monkeypatch.chdir(tmp_path / "tests")
    capture = calibration_trace.CalibrationTrace.from_environment(_dut(), **_RUN)
    assert capture is not None
    capture.finish("")
    assert (tmp_path / "out" / "t.jsonl").is_file()
    assert (tmp_path / "out" / "counters.json").is_file()
    assert absolute.is_file()
