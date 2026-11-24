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

"""Tests for the FPGA programmer, loader, and ECC scripts, with Vivado mocked."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import struct
import sys
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parents[1]
TARGET = "localhost:3219/xilinx_tcf/Xilinx/cable-1"


def load_module(name: str, relative_path: str) -> Any:
    """Load scripts without leaving their standalone import paths installed."""
    spec = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    original = sys.path.copy()
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path[:] = original
    return module


target = load_module("managed_hw_target", "fpga/common/hw_target.py")
loader = load_module("managed_loader", "fpga/load_software/load_software.py")
programmer = load_module(
    "managed_programmer", "fpga/program_bitstream/program_bitstream.py"
)
ecc = load_module("managed_ddr_ecc", "fpga/ddr_ecc/ddr_ecc_status.py")


@pytest.mark.parametrize("url", ["localhost:3121", "127.0.0.1:3219", "[::1]:3219"])
def test_explicit_server_endpoint(url: str) -> None:
    """Explicit endpoints retain the caller's chosen host and port."""
    assert target.hardware_server_url(url) == url


@pytest.mark.parametrize(
    "url",
    [
        "",
        "localhost",
        "localhost:0",
        "localhost:65536",
        "localhost:3121 -foo",
        "tcp://localhost:3121",
    ],
)
def test_bad_server_endpoint(url: str) -> None:
    """Malformed endpoints must not fall back to an implicit local daemon."""
    with pytest.raises(argparse.ArgumentTypeError):
        target.hardware_server_url(url)


def test_exact_and_noninteractive_selection(monkeypatch: pytest.MonkeyPatch) -> None:
    """Exact selection ignores near matches, and non-interactive calls never prompt."""
    monkeypatch.setattr(
        target, "get_available_targets", lambda *a, **k: [TARGET, TARGET + "-other"]
    )
    monkeypatch.setattr(
        target, "prompt_target_selection", lambda *a: pytest.fail("must not prompt")
    )
    assert (
        target.select_target(
            "vivado", board="x3", target_exact=TARGET, non_interactive=True
        )
        == TARGET
    )
    for options in ({"target_exact": "cable-1"}, {"target_pattern": "cable"}, {}):
        with pytest.raises(SystemExit):
            target.select_target("vivado", board="x3", non_interactive=True, **options)


def test_discovery_propagates_failed_vivado(monkeypatch: pytest.MonkeyPatch) -> None:
    """Partial target output from a failed subprocess is not success."""

    def failed(command: list[str], **kwargs: Any) -> Any:
        assert command[-3:] == ["-tclargs", "", "127.0.0.1:3219"]
        assert kwargs["check"] is True and kwargs["timeout"] == 120
        raise subprocess.CalledProcessError(7, command, output="TARGET:misleading")

    monkeypatch.setattr(target.subprocess, "run", failed)
    with pytest.raises(subprocess.CalledProcessError):
        target.get_available_targets("vivado", hw_server_url="127.0.0.1:3219")


def test_missing_bitstream_fails_before_discovery(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A bad selected file must not touch the cable."""
    monkeypatch.setattr(
        sys,
        "argv",
        ["program_bitstream.py", "x3", "--bitstream", str(tmp_path / "missing.bit")],
    )
    monkeypatch.setattr(
        programmer, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )
    with pytest.raises(SystemExit):
        programmer.main()


def test_program_passes_selected_file_and_endpoint(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Programming preserves exact selection and paths containing spaces."""
    bitstream = tmp_path / "selected image.bit"
    bitstream.write_bytes(b"test bitstream")
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "program_bitstream.py",
            "x3",
            "--bitstream",
            str(bitstream),
            "--target-exact",
            TARGET,
            "--hw-server-url",
            "127.0.0.1:3219",
            "--non-interactive",
        ],
    )
    selected: list[dict[str, Any]] = []
    commands: list[list[str]] = []

    def select(*args: Any, **kwargs: Any) -> str:
        selected.append(kwargs)
        return TARGET

    monkeypatch.setattr(programmer, "select_target", select)
    monkeypatch.setattr(
        programmer.subprocess, "run", lambda command, **kwargs: commands.append(command)
    )
    programmer.main()
    assert selected[0]["target_exact"] == TARGET
    assert selected[0]["non_interactive"] is True
    assert commands[0][-4:] == [TARGET, "", str(bitstream), "127.0.0.1:3219"]


def test_loader_build_only_never_discovers(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """--debug --build-only emits a debug-build record without cable access."""
    monkeypatch.setattr(
        sys,
        "argv",
        ["load_software.py", "x3", "hello_world", "--debug", "--build-only"],
    )
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )
    calls: list[dict[str, Any]] = []

    def compile_app(*args: Any, **kwargs: Any) -> bool:
        calls.append(kwargs)
        return True

    monkeypatch.setattr(loader, "compile_app_for_board", compile_app)
    descriptor = {"app": "hello_world", "startStrategy": "main"}
    monkeypatch.setattr(loader, "validate_prebuilt_app", lambda *a, **k: descriptor)
    loader.main()
    assert calls == [
        {"mem_config": None, "debug": True, "ddr_bytes": 1 << 30, "board": "x3"}
    ]
    records = [
        line
        for line in capsys.readouterr().out.splitlines()
        if line.startswith("FROST_DEBUG_BUILD=")
    ]
    assert len(records) == 1
    assert json.loads(records[0].split("=", 1)[1]) == descriptor


def test_loader_passes_board_capacity_to_dma_torture(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """DMA aperture checks compile with the DDR range of the selected board."""
    compile_app_for_board = loader.compile_app_for_board
    monkeypatch.setattr(
        sys, "argv", ["load_software.py", "x3", "dma_torture", "--build-only"]
    )
    monkeypatch.setattr(loader, "validate_prebuilt_app", lambda *a, **k: None)
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )
    builds: list[dict[str, Any]] = []

    def compile_app(*args: Any, **kwargs: Any) -> bool:
        builds.append(kwargs)
        return True

    monkeypatch.setattr(loader, "compile_app_for_board", compile_app)
    loader.main()
    assert builds[0]["ddr_bytes"] == 1 << 30
    environments: list[dict[str, str]] = []

    def run(command: list[str], **kwargs: Any) -> Any:
        environments.append(kwargs["env"])
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.delenv("FROST_DDR_CAPACITY_LOG2_BYTES", raising=False)
    monkeypatch.setenv("EXTRA_CFLAGS", "-DDMA_TORTURE_QUICK=1")
    monkeypatch.setattr(loader.subprocess, "run", run)
    (tmp_path / "sw.mem").write_text("")
    (tmp_path / "sw.txt").write_text("")
    assert compile_app_for_board("dma_torture", tmp_path, 1, 1, **builds[0])
    assert len(environments) == 2
    for env in environments:
        assert env["FROST_DDR_CAPACITY_LOG2_BYTES"] == "30"
        assert env["EXTRA_CFLAGS"] == "-DDMA_TORTURE_QUICK=1"

    monkeypatch.setenv("FROST_DDR_CAPACITY_LOG2_BYTES", "36")
    assert not compile_app_for_board("dma_torture", tmp_path, 1, 1, **builds[0])
    assert len(environments) == 2


@pytest.mark.parametrize("board,capacity", (("x3", 2 << 20), ("vcu118", 4 << 20)))
@pytest.mark.parametrize("override", (None, "8388608"))
def test_loader_builds_with_board_l2_capacity(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    board: str,
    capacity: int,
    override: str | None,
) -> None:
    """Eviction programs follow the selected board or an explicit custom cache."""
    monkeypatch.delenv("FROST_L2_CACHE_BYTES", raising=False)
    if override is not None:
        monkeypatch.setenv("FROST_L2_CACHE_BYTES", override)
    environments = []

    def run(command: list[str], **kwargs: Any) -> Any:
        environments.append(kwargs["env"])
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(loader.subprocess, "run", run)
    for name in ("sw.mem", "sw.txt"):
        (tmp_path / name).write_text("")
    assert loader.compile_app_for_board(
        "lq_stale_slot_probe", tmp_path, 1, 1, board=board
    )
    assert len(environments) == 2
    assert all(
        env["FROST_L2_CACHE_BYTES"] == (override or str(capacity))
        for env in environments
    )


@pytest.mark.parametrize("board,capacity", (("x3", 16 << 10), ("vcu118", 32 << 10)))
@pytest.mark.parametrize("override", (None, "8192"))
def test_loader_builds_with_board_l1i_capacity(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    board: str,
    capacity: int,
    override: str | None,
) -> None:
    """L1I geometry programs follow the selected board or an explicit override."""
    monkeypatch.delenv("L1I_TEST_BYTES", raising=False)
    if override is not None:
        monkeypatch.setenv("L1I_TEST_BYTES", override)
    environments = []

    def run(command: list[str], **kwargs: Any) -> Any:
        environments.append(kwargs["env"])
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(loader.subprocess, "run", run)
    for name in ("sw.mem", "sw.txt"):
        (tmp_path / name).write_text("")
    assert loader.compile_app_for_board("l1i_set_test", tmp_path, 1, 1, board=board)
    assert len(environments) == 2
    assert all(
        env["L1I_TEST_BYTES"] == (override or str(capacity)) for env in environments
    )


def test_skip_build_loads_without_make(monkeypatch: pytest.MonkeyPatch) -> None:
    """Load the already selected files without replacing the debugger's ELF."""
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "load_software.py",
            "x3",
            "debug_target",
            "--debug",
            "--ddr",
            "--skip-build",
            "--hw-server-url",
            "127.0.0.1:3219",
            "--target-exact",
            TARGET,
            "--non-interactive",
        ],
    )
    monkeypatch.setattr(
        loader, "compile_app_for_board", lambda *a, **k: pytest.fail("must not rebuild")
    )
    monkeypatch.setattr(loader, "validate_prebuilt_app", lambda *a, **k: None)
    monkeypatch.setattr(loader, "select_target", lambda *a, **k: TARGET)
    commands: list[list[str]] = []
    monkeypatch.setattr(
        loader.subprocess, "run", lambda command, **kwargs: commands.append(command)
    )
    loader.main()
    assert commands[0][-5:] == ["debug_target", TARGET, "", "1", "127.0.0.1:3219"]


def test_skip_build_bad_artifacts_fail_before_discovery(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Stale build settings reject the load before cable discovery."""
    monkeypatch.setattr(
        sys, "argv", ["load_software.py", "x3", "hello_world", "--skip-build"]
    )
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )

    def invalid(*args: Any, **kwargs: Any) -> None:
        raise ValueError("wrong CPU clock")

    monkeypatch.setattr(loader, "validate_prebuilt_app", invalid)
    with pytest.raises(SystemExit):
        loader.main()


def test_clean_failure_does_not_build(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Do not load old outputs after a failed cleanup."""
    calls = []

    def failed(command: list[str], **kwargs: Any) -> Any:
        calls.append(command)
        assert kwargs["check"] is True
        raise subprocess.CalledProcessError(1, command)

    monkeypatch.setattr(loader.subprocess, "run", failed)
    assert not loader.compile_app_for_board("hello_world", tmp_path, 161132812, 1)
    assert calls == [["make", "clean"]]


@pytest.mark.parametrize(
    "mode,app",
    [
        ("bram", "hello_world"),
        ("ddr", "debug_target"),
        ("bram", "uart_echo"),
        ("bram", "tick_torture"),
    ],
)
def test_debug_profile_emits_dwarf_and_validates_settings(
    tmp_path: Path, mode: str, app: str
) -> None:
    """Keep DWARF despite -O3 -g0 tuning flags.

    Reject mismatched build settings and corrupt images before loading.
    """
    sw = tmp_path / "sw"
    (sw / "apps").mkdir(parents=True)
    (sw / "common").symlink_to(ROOT / "sw/common", target_is_directory=True)
    (sw / "lib").symlink_to(ROOT / "sw/lib", target_is_directory=True)
    app_dir = sw / "apps" / app
    app_dir.mkdir()
    for source in (ROOT / "sw/apps" / app).iterdir():
        if (
            source.name == "Makefile"
            or source.suffix in {".c", ".h"}
            or source.name == "target.S"
        ):
            shutil.copy2(source, app_dir / source.name)
    env = os.environ.copy()
    env.pop("MEM_CONFIG", None)
    env.pop("FROST_DEBUG", None)
    result = subprocess.run(
        [
            "make",
            "-s",
            "GENERATE_IMEM_INIT=0",
            "FROST_DEBUG=1",
            f"MEM_CONFIG={mode}",
            "FPGA_CPU_CLK_FREQ=161132812",
            "EXTRA_CFLAGS=-O3 -g0 -funroll-loops -fomit-frame-pointer",
            "APP_TUNE_FLAGS=-O3 -g0 -funroll-loops -fomit-frame-pointer",
        ],
        cwd=app_dir,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    descriptor = loader.validate_prebuilt_app(app_dir, 161132812, mode, True)
    effective_memory = "ddr" if app in loader.FORCED_DDR_APPS else mode
    assert descriptor["effectiveMemory"] == effective_memory
    assert descriptor["startStrategy"] == (
        "main" if effective_memory == "bram" else "attach"
    )
    assert descriptor["appDirectory"] == str(app_dir.resolve())
    mismatches = [
        (322265625, mode, True),
        (161132812, mode, False),
    ]
    if app not in loader.FORCED_DDR_APPS:
        mismatches.append((161132812, "ddr" if mode == "bram" else "bram", True))
    for clock, memory, debug in mismatches:
        with pytest.raises(ValueError):
            loader.validate_prebuilt_app(app_dir, clock, memory, debug)
    (app_dir / "sw.txt").write_text("nothex!!\n")
    with pytest.raises(ValueError, match="invalid 32-bit"):
        loader.validate_prebuilt_app(app_dir, 161132812, mode, True)


def minimal_debug_elf(
    *, main: bool = True, writable_ddr: bool = False, entry: int = 0
) -> bytes:
    """Build a minimal RISC-V ELF for the start-strategy and malformed-ELF tests."""
    definitions = [
        ("", 0, 0, 0, b"", 0, 0),
        (".text", 1, 6, 0, b"\x13\0\0\0", 0, 0),
        (".debug_info", 1, 0, 0, b"x", 0, 0),
        (".debug_line", 1, 0, 0, b"x", 0, 0),
        (".strtab", 3, 0, 0, b"\0main\0", 0, 0),
        (
            ".symtab",
            2,
            0,
            0,
            bytes(24) + struct.pack("<IBBHQQ", 1, 0x12, 0, int(main), 0, 4),
            4,
            24,
        ),
    ]
    if writable_ddr:
        definitions.append((".ddr_data", 1, 3, 0x80000000, b"data", 0, 0))
    names = b"\0"
    for definition in definitions[1:]:
        names += definition[0].encode() + b"\0"
    names += b".shstrtab\0"
    names_index = len(definitions)
    definitions.append((".shstrtab", 3, 0, 0, names, 0, 0))
    result = bytearray(64)
    headers = []
    for name, kind, flags, address, data, link, entry_size in definitions:
        offset = len(result)
        result.extend(data)
        headers.append(
            struct.pack(
                "<IIQQQQIIQQ",
                names.index(name.encode() + b"\0"),
                kind,
                flags,
                address,
                offset,
                len(data),
                link,
                0,
                1,
                entry_size,
            )
        )
    section_offset = len(result)
    for header in headers:
        result.extend(header)
    result[:16] = b"\x7fELF\x02\x01\x01" + bytes(9)
    struct.pack_into(
        "<HHIQQQIHHHHHH",
        result,
        16,
        2,
        243,
        1,
        entry,
        0,
        section_offset,
        0,
        64,
        0,
        0,
        64,
        len(headers),
        names_index,
    )
    return bytes(result)


def write_prebuilt(directory: Path, elf: bytes, **fields: str) -> None:
    """Write fixture images and a build-config stamp as make does, without compiling."""
    directory.mkdir(parents=True)
    (directory / "sw.elf").write_bytes(elf)
    (directory / "sw.txt").write_text("00000013\n")
    (directory / "sw_ddr.txt").write_text("00000000\n")
    config = {
        "MEM_CONFIG": "bram",
        "FROST_DEBUG": "1",
        "FPGA_CPU_CLK_FREQ": "161132812",
        **fields,
    }
    (directory / ".frost-build-config.bin").write_text(
        "|".join(f"{key}={value}" for key, value in config.items()) + "\n"
    )


@pytest.mark.parametrize(
    "main,writable_ddr,entry,strategy",
    [
        (True, False, 0, "main"),
        (False, False, 0, "reset"),
        (True, True, 0, "attach"),
        (True, False, 0x80000000, "attach"),
    ],
)
def test_elf_determines_safe_startup(
    tmp_path: Path, main: bool, writable_ddr: bool, entry: int, strategy: str
) -> None:
    """Restart only with entry 0 and no initialized writable DDR data.

    Restarting at main or reset does not reload DDR. Other ELFs must attach,
    regardless of the BRAM setting.
    """
    directory = tmp_path / "hello_world"
    write_prebuilt(
        directory, minimal_debug_elf(main=main, writable_ddr=writable_ddr, entry=entry)
    )
    descriptor = loader.validate_prebuilt_app(directory, 161132812, "bram", True)
    assert descriptor["startStrategy"] == strategy
    assert descriptor["elf"] == str(directory / "sw.elf")
    assert len(descriptor["buildConfigSha256"]) == 64


@pytest.mark.parametrize(
    "corruption",
    ["header", "sections", "section_payload", "names", "symbol_link", "empty_dwarf"],
)
def test_invalid_elf_tables_fail_closed(corruption: str) -> None:
    """Truncated or out-of-range ELF tables, or empty DWARF, raise ValueError."""
    elf = bytearray(minimal_debug_elf())
    section_offset = struct.unpack_from("<Q", elf, 40)[0]
    if corruption == "header":
        elf = elf[:63]
    elif corruption == "sections":
        struct.pack_into("<Q", elf, 40, len(elf) - 1)
    elif corruption == "section_payload":
        struct.pack_into("<Q", elf, section_offset + 64 + 32, len(elf) + 1)
    elif corruption == "names":
        struct.pack_into("<I", elf, section_offset + 64, 0xFFFFFFFF)
    elif corruption == "symbol_link":
        struct.pack_into("<I", elf, section_offset + 5 * 64 + 40, 99)
    elif corruption == "empty_dwarf":
        struct.pack_into("<Q", elf, section_offset + 2 * 64 + 32, 0)
    with pytest.raises(ValueError):
        loader.inspect_debug_elf(bytes(elf), True)


def test_coremark_pro_prebuilt_binds_alias_mode_and_diagnostics(tmp_path: Path) -> None:
    """A CoreMark-PRO build loads only for its workload, mode, and diagnostic flags.

    Every workload builds into the same directory with the same file names.
    """
    directory = tmp_path / "coremark_pro"
    selected = loader.coremark_pro_make_vars(
        "coremark_pro_core", hardware=True, hardware_mode="validation", board="x3"
    )
    flags = {
        key: "0"
        for key in [
            "COREMARK_PRO_TRACE",
            "COREMARK_PRO_CACHE_COUNTERS",
            "FROST_MALLOC_DISABLE_FREE",
            "FROST_MALLOC_GUARD_FREE",
            "FROST_MALLOC_EVICT_FREE",
            "FROST_MEMORY_FENCE_WRITES",
        ]
    }
    write_prebuilt(directory, minimal_debug_elf(), **selected, **flags)
    descriptor = loader.validate_prebuilt_app(
        directory,
        161132812,
        "bram",
        True,
        app_name="coremark_pro_core",
        make_vars=selected,
    )
    assert descriptor["app"] == "coremark_pro_core"
    for app, mode, diagnostic in [
        ("coremark_pro_sha", "validation", False),
        ("coremark_pro_core", "performance", False),
        ("coremark_pro_core", "validation", True),
    ]:
        changed = loader.coremark_pro_make_vars(
            app, hardware=True, hardware_mode=mode, board="x3"
        )
        if diagnostic:
            changed["FROST_MALLOC_DISABLE_FREE"] = "1"
        with pytest.raises(ValueError, match="workload options differ"):
            loader.validate_prebuilt_app(
                directory, 161132812, "bram", True, app_name=app, make_vars=changed
            )


@pytest.mark.parametrize("matching", [False, True])
def test_config_hash_binds_build_before_cable(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, matching: bool
) -> None:
    """The config hash must match, in either letter case, before the cable is used."""
    directory = tmp_path / "sw/apps/hello_world"
    write_prebuilt(directory, minimal_debug_elf())
    descriptor = loader.validate_prebuilt_app(directory, 161132812, "bram", True)
    monkeypatch.setattr(loader, "PROJECT_ROOT", tmp_path)
    monkeypatch.setenv("FROST_CPU_CLK_HZ", "161132812")
    monkeypatch.delenv("MEM_CONFIG", raising=False)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "load_software.py",
            "x3",
            "hello_world",
            "--debug",
            "--skip-build",
            "--expected-build-config-sha256",
            descriptor["buildConfigSha256"].upper() if matching else "0" * 64,
        ],
    )
    monkeypatch.setattr(
        loader, "compile_app_for_board", lambda *a, **k: pytest.fail("must not rebuild")
    )
    calls: list[list[str]] = []
    monkeypatch.setattr(
        loader.subprocess, "run", lambda command, **kwargs: calls.append(command)
    )
    monkeypatch.setattr(
        loader,
        "select_target",
        lambda *a, **k: TARGET if matching else pytest.fail("cable touched"),
    )
    if matching:
        loader.main()
        assert len(calls) == 1
    else:
        with pytest.raises(SystemExit):
            loader.main()
        assert not calls


@pytest.mark.parametrize(
    "extra",
    [
        ["--expected-build-config-sha256", "0" * 64],
        ["--skip-build", "--expected-build-config-sha256", "invalid"],
    ],
)
def test_config_hash_options_validate_before_build(
    monkeypatch: pytest.MonkeyPatch, extra: list[str]
) -> None:
    """A malformed hash or use outside skip-build never starts a build."""
    monkeypatch.setattr(sys, "argv", ["load_software.py", "x3", "uart_echo", *extra])
    monkeypatch.setattr(
        loader, "compile_app_for_board", lambda *a, **k: pytest.fail("build ran")
    )
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )
    with pytest.raises(SystemExit):
        loader.main()


@pytest.mark.parametrize("app", ["linux_boot", "opensbi_smoke"])
def test_composite_debug_rejected_before_build(
    monkeypatch: pytest.MonkeyPatch, app: str
) -> None:
    """--debug with a composite image fails before preflight or build."""
    monkeypatch.setattr(
        sys, "argv", ["load_software.py", "x3", app, "--debug", "--build-only"]
    )
    monkeypatch.setattr(
        loader, "_linux_boot_preflight", lambda: pytest.fail("preflight ran")
    )
    monkeypatch.setattr(
        loader, "compile_app_for_board", lambda *a, **k: pytest.fail("build ran")
    )
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )
    with pytest.raises(SystemExit):
        loader.main()


def test_normal_coremark_pro_load_preserves_inherited_diagnostics(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Preserve inherited diagnostics on ordinary loads; prebuilt checks do not run."""
    monkeypatch.setenv("FROST_MALLOC_DISABLE_FREE", "1")
    monkeypatch.setattr(
        sys, "argv", ["load_software.py", "x3", "coremark_pro_core", "-v1"]
    )
    builds = []

    def compile_app(*args: Any, **kwargs: Any) -> bool:
        assert os.environ["FROST_MALLOC_DISABLE_FREE"] == "1"
        builds.append((args, kwargs))
        return True

    monkeypatch.setattr(loader, "compile_app_for_board", compile_app)
    monkeypatch.setattr(
        loader,
        "validate_prebuilt_app",
        lambda *a, **k: pytest.fail("prebuilt validation ran for an ordinary load"),
    )
    monkeypatch.setattr(loader, "select_target", lambda *a, **k: TARGET)
    loads = []
    monkeypatch.setattr(
        loader.subprocess, "run", lambda command, **kwargs: loads.append(command)
    )
    loader.main()
    assert len(builds) == 1 and len(loads) == 1
    assert builds[0][0][0] == "coremark_pro_core"
    assert builds[0][1]["debug"] is False


@pytest.mark.parametrize("failure", [False, True])
@pytest.mark.parametrize(
    "board,part,mismatch",
    [
        ("x3", "xcu26_ux35", None),
        ("vcu118", "xcvu9p", None),
        ("vcu118", "xcvu9p-flga2104-2L-e", None),
        ("x3", "xcvu9p", "xcu26_ux35"),
        ("vcu118", "xcu26_ux35", "xcvu9p*"),
        ("x3", "xcux35", "xcu26_ux35"),
        ("vcu118", "xcux35", "xcvu9p*"),
    ],
)
def test_tcl_program_connection_cleanup(
    tmp_path: Path, failure: bool, board: str, part: str, mismatch: str | None
) -> None:
    """The programmer checks the device and disconnects, pass or fail.

    Stub Vivado commands stand in for the hardware manager.
    """
    bitstream = tmp_path / "selected.bit"
    bitstream.write_bytes(b"test")
    harness = tmp_path / "mock.tcl"
    harness.write_text("""
set actual_script [lindex $argv 0]
set argv [lrange $argv 1 end]
set argc [llength $argv]
proc open_hw_manager {} {puts OPEN_MANAGER}
proc connect_hw_server {args} {puts "CONNECT:$args"}
proc get_hw_targets {} {return {localhost:3219/xilinx_tcf/Xilinx/cable-1}}
proc current_hw_target {target} {puts "TARGET:$target"}
proc open_hw_target {} {puts OPEN_TARGET}
proc get_hw_devices {} {return device0}
proc get_property {key object} {
    if {$key ne "PART"} {error "Unexpected property $key"}
    return $::env(TEST_PART)
}
proc set_property {key value device} {puts "PROPERTY:$key:$value:$device"}
proc program_hw_devices {device} {
    puts PROGRAM
    if {$::env(TEST_PROGRAM_FAIL)} {error "injected programming failure"}
}
proc close_hw_target {} {puts CLOSE_TARGET}
proc disconnect_hw_server {} {puts DISCONNECT_SERVER}
proc close_hw_manager {} {puts CLOSE_MANAGER}
source $actual_script
""")
    env = os.environ.copy()
    env["TEST_PROGRAM_FAIL"] = str(int(failure))
    env["TEST_PART"] = part
    result = subprocess.run(
        [
            "tclsh",
            str(harness),
            str(ROOT / "fpga/program_bitstream/program_bitstream.tcl"),
            str(ROOT),
            board,
            TARGET,
            "",
            str(bitstream),
            "127.0.0.1:3219",
        ],
        capture_output=True,
        text=True,
        env=env,
        timeout=10,
    )
    failed = failure or mismatch is not None
    assert result.returncode == int(failed), result.stderr
    if mismatch is not None:
        assert "PROGRAM\n" not in result.stdout
        assert "PROPERTY:PROGRAM.FILE" not in result.stdout
        assert (
            f"Expected FPGA part {mismatch} for {board}, found {part}" in result.stderr
        )
    else:
        assert "PROGRAM\n" in result.stdout
    assert "CONNECT:-url 127.0.0.1:3219" in result.stdout
    assert result.stdout.endswith("CLOSE_TARGET\nDISCONNECT_SERVER\nCLOSE_MANAGER\n")
    assert ("FROST_PROGRAM_COMPLETE" in result.stdout) is not failed


@pytest.mark.parametrize("failure", [False, True])
def test_tcl_fetch_ila_capture_cleanup(tmp_path: Path, failure: bool) -> None:
    """capture_fetch_ila.tcl writes the CSV and closes its session, pass or fail.

    Stub Vivado commands stand in for the hardware manager and the ILA. Only
    commands Vivado has are stubbed, so a call to any other one fails.
    """
    csv = tmp_path / "fetch_ila.csv"
    harness = tmp_path / "mock-ila.tcl"
    harness.write_text("""
set actual_script [lindex $argv 0]
set argv [lrange $argv 1 end]
set argc [llength $argv]
proc open_hw_manager {} {puts OPEN_MANAGER}
proc connect_hw_server {args} {puts "CONNECT:$args"}
proc get_hw_targets {} {return {localhost:3219/xilinx_tcf/Xilinx/cable-1}}
proc current_hw_target {target} {puts "TARGET:$target"}
proc open_hw_target {} {puts OPEN_TARGET}
proc get_hw_devices {} {return device0}
proc current_hw_device {args} {return device0}
proc set_property {args} {}
proc refresh_hw_device {args} {}
proc get_hw_ilas {args} {return ila0}
proc get_hw_probes {args} {
    if {[lsearch -exact $args -filter] >= 0} {return probe0}
    return {probe0 probe1}
}
proc get_property {key object} {return $object}
proc report_property {args} {return "STATUS idle"}
proc run_hw_ila {ila} {puts "ARM:$ila"}
proc wait_on_hw_ila {args} {}
proc upload_hw_ila_data {ila} {
    if {$::env(TEST_UPLOAD_FAIL)} {error "injected upload failure"}
    return data0
}
proc write_hw_ila_data {args} {
    set fd [open [lindex $args end-1] w]
    puts $fd sample
    close $fd
}
proc close_hw_target {} {puts CLOSE_TARGET}
proc disconnect_hw_server {} {puts DISCONNECT_SERVER}
proc close_hw_manager {} {puts CLOSE_MANAGER}
source $actual_script
""")
    env = os.environ.copy()
    env["TEST_UPLOAD_FAIL"] = str(int(failure))
    result = subprocess.run(
        [
            "tclsh",
            str(harness),
            str(ROOT / "fpga/debug/capture_fetch_ila.tcl"),
            TARGET,
            str(tmp_path / "x3_frost.ltx"),
            str(csv),
            "*fault",
            "*pc*",
            "eq16'hX5E4",
            "3072",
            "1",
            "192.0.2.7",
        ],
        capture_output=True,
        text=True,
        env=env,
        timeout=10,
    )
    assert result.returncode == int(failure), result.stderr
    assert "CONNECT:-url 192.0.2.7:3121" in result.stdout
    assert "ARM:ila0" in result.stdout
    assert result.stdout.endswith("CLOSE_TARGET\nDISCONNECT_SERVER\nCLOSE_MANAGER\n")
    assert csv.exists() is not failure
    assert ("injected upload failure" in result.stderr) is failure


@pytest.mark.parametrize("app", [*loader.VALID_APPS, "unregistered_app"])
def test_tcl_loader_app_preflight_never_opens_manager(tmp_path: Path, app: str) -> None:
    """Validate apps before opening the hardware manager.

    Listed apps fail on their missing BRAM image; unlisted apps fail on name.
    """
    harness = tmp_path / "mock.tcl"
    harness.write_text("""
set actual_script [lindex $argv 0]
set argv [lrange $argv 1 end]
set argc [llength $argv]
proc open_hw_manager {} {puts SHOULD_NOT_OPEN}
source $actual_script
""")
    result = subprocess.run(
        [
            "tclsh",
            str(harness),
            str(ROOT / "fpga/load_software/load_software.tcl"),
            str(tmp_path),
            app,
            TARGET,
            "",
            "1",
            "127.0.0.1:3219",
        ],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 1
    if app in loader.VALID_APPS:
        assert "BRAM image" in result.stderr, result.stdout + result.stderr
        assert "Invalid software app" not in result.stdout
    else:
        assert f"Invalid software app '{app}'" in result.stdout
    assert "SHOULD_NOT_OPEN" not in result.stdout


@pytest.mark.parametrize("failure", [False, True])
def test_tcl_loader_transfer_and_cleanup(tmp_path: Path, failure: bool) -> None:
    """load_software.tcl loads BRAM and DDR and disconnects, pass or fail.

    Stub Vivado commands stand in for the hardware manager and AXI transactions.
    """
    app_dir = tmp_path / "sw/apps/debug_target"
    app_dir.mkdir(parents=True)
    for name in ("sw.txt", "sw_ddr.txt"):
        (app_dir / name).write_text("00000013\n00000013\n")
    harness = tmp_path / "mock-load.tcl"
    harness.write_text("""
set actual_script [lindex $argv 0]
set argv [lrange $argv 1 end]
set argc [llength $argv]
proc open_hw_manager {} {puts OPEN_MANAGER}
proc connect_hw_server {args} {puts "CONNECT:$args"}
proc get_hw_targets {} {return {localhost:3219/xilinx_tcf/Xilinx/cable-1}}
proc current_hw_target {target} {puts "TARGET:$target"}
proc open_hw_target {} {puts OPEN_TARGET}
proc get_hw_devices {} {return device0}
proc refresh_hw_device {device} {}
proc reset_hw_axi {axi} {}
proc get_hw_axis {args} {
    if {[llength $args] == 0 || [lindex $args 0] eq "-of_objects"} {return {bram ddr}}
    return [lindex $args 0]
}
proc get_property {key object} {
    if {$key eq "CELL_NAME"} {
        if {$object eq "bram"} {return jtag_to_axi_bridge}
        return jtag_axi_ddr
    }
    return $object
}
proc create_hw_axi_txn {args} {}
proc get_hw_axi_txns {args} {return [lindex $args end]}
proc delete_hw_axi_txn {args} {}
proc run_hw_axi {args} {
    if {$::env(TEST_TRANSFER_FAIL)} {error "injected transfer failure"}
}
proc close_hw_target {} {puts CLOSE_TARGET}
proc disconnect_hw_server {} {puts DISCONNECT_SERVER}
proc close_hw_manager {} {puts CLOSE_MANAGER}
source $actual_script
""")
    env = os.environ.copy()
    env["TEST_TRANSFER_FAIL"] = str(int(failure))
    env.pop("FROST_ILA_ARM_HOOK", None)
    env.pop("FROST_ILA_COLLECT_HOOK", None)
    result = subprocess.run(
        [
            "tclsh",
            str(harness),
            str(ROOT / "fpga/load_software/load_software.tcl"),
            str(tmp_path),
            "debug_target",
            TARGET,
            "",
            "1",
            "127.0.0.1:3219",
        ],
        capture_output=True,
        text=True,
        env=env,
        timeout=10,
    )
    assert result.returncode == int(failure), result.stderr
    assert "CONNECT:-url 127.0.0.1:3219" in result.stdout
    assert result.stdout.endswith("CLOSE_TARGET\nDISCONNECT_SERVER\nCLOSE_MANAGER\n")
    assert ("FROST_LOAD_COMPLETE" in result.stdout) is not failure


# --- DDR4 ECC state ----------------------------------------------------------
#
# The hardware regression consumes these ECC offsets and verdict() results.


@pytest.fixture
def ecc_tcl_harness(tmp_path: Path) -> Path:
    """Run the production Tcl with mock device and transaction commands."""
    harness = tmp_path / "mock-ecc.tcl"
    harness.write_text("""
set actual_script [lindex $argv 0]
set argv [lrange $argv 1 end]
set argc [llength $argv]
set txn_count 0
proc open_hw_manager {} {puts OPEN_MANAGER}
proc connect_hw_server {args} {puts "CONNECT:$args"}
proc get_hw_targets {} {return [list [lindex $::argv 0]]}
proc current_hw_target {target} {}
proc open_hw_target {} {}
proc get_hw_devices {} {return device0}
proc refresh_hw_device {args} {}
proc get_hw_axis {args} {
    if {[llength $args]} {return [lindex $args 0]}
    return {bram ddr}
}
proc get_property {key object} {
    switch -- $key {
        PART {return $::env(TEST_ECC_PART)}
        CELL_NAME {return [dict get {bram jtag_to_axi_bridge ddr ddr_subsys/jtag_axi_ddr} $object]}
        NAME {return $object}
        DATA {
            if {[info exists ::env(TEST_ECC_WRONG_WINDOW)]} {
                switch -- $::address {
                    0x80000000 {return 00000003}
                    0x8000000c {return 00000009}
                }
            }
            return [format %08x [expr {($::address & 0x7fff) == 8}]]
        }
        default {error "unexpected property $key"}
    }
}
proc create_hw_axi_txn {name axi args} {
    incr ::txn_count
    set ::address [dict get $args -address]
    puts "TXN $axi $args"
}
proc get_hw_axi_txns {name} {return $name}
proc delete_hw_axi_txn {args} {}
proc run_hw_axi {args} {
    if {[info exists ::env(TEST_ECC_FAIL_TXN)] && $::txn_count == $::env(TEST_ECC_FAIL_TXN)} {
        error "injected ECC transaction failure"
    }
}
proc close_hw_target {} {}
proc disconnect_hw_server {} {}
proc close_hw_manager {} {}
source $actual_script
""")
    return harness


def run_ecc_with_tcl_harness(
    monkeypatch: pytest.MonkeyPatch, harness: Path
) -> list[subprocess.CompletedProcess[str]]:
    """Replace Vivado's process with tclsh while keeping the emitted argv."""
    run = subprocess.run
    results: list[subprocess.CompletedProcess[str]] = []

    def run_tcl(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        script = command[command.index("-source") + 1]
        args = command[command.index("-tclargs") + 1 :]
        result = run(["tclsh", str(harness), script, *args], timeout=10, **kwargs)
        results.append(result)
        return result

    monkeypatch.setattr(ecc.subprocess, "run", run_tcl)
    return results


@pytest.mark.parametrize(
    "board,base,part",
    [
        ("x3", 0x40000000, "xcu26_ux35"),
        ("vcu118", 0x80000000, "xcvu9p"),
        ("vcu118", 0x80000000, "xcvu9p-flga2104-2L-e"),
    ],
)
@pytest.mark.parametrize("clear", [False, True])
def test_ecc_cli_uses_board_window_for_jtag_transactions(
    ecc_tcl_harness: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    board: str,
    base: int,
    part: str,
    clear: bool,
) -> None:
    """Run the Python and Tcl helpers with a model of the DDR JTAG master."""
    board_args = [board] if board != "x3" or clear else []
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "ddr_ecc_status.py",
            *board_args,
            "--json",
            "--hw-server-url",
            "127.0.0.1:3219",
            *(["--clear"] if clear else []),
        ],
    )
    monkeypatch.setenv("TEST_ECC_PART", part)
    monkeypatch.setattr(ecc, "select_target", lambda *a, **kw: TARGET)
    results = run_ecc_with_tcl_harness(monkeypatch, ecc_tcl_harness)
    assert ecc.main() == 0
    report = json.loads(capsys.readouterr().out)
    assert report["master"] == "ddr" and report["clean"]
    assert report["registers"]["ECC_ON_OFF"] == 1
    assert report["after_clear"] == (report["registers"] if clear else {})
    assert len(results) == 1
    assert "CONNECT:-url 127.0.0.1:3219" in results[0].stdout
    transactions = [
        line for line in results[0].stdout.splitlines() if line.startswith("TXN ")
    ]

    reads = [
        f"TXN ddr -type read -address {base + offset:#010x} -len 1"
        for _, offset in ecc.ECC_REGISTERS
    ]
    writes = [
        f"TXN ddr -type write -address {base + 0x00C:#010x} -len 1 -data 00000000",
        f"TXN ddr -type write -address {base:#010x} -len 1 -data 00000003",
    ]
    assert transactions == (reads + writes + reads if clear else reads)


@pytest.mark.parametrize(
    "board,vendor,part,expected",
    [
        ("x3", "Xilinx", "xcvu9p", "xcu26_ux35"),
        ("x3", "Xilinx", "xcvu9p-flga2104-2L-e", "xcu26_ux35"),
        ("vcu118", "Digilent", "xcu26_ux35", "xcvu9p*"),
        ("x3", "Xilinx", "xcux35", "xcu26_ux35"),
    ],
)
@pytest.mark.parametrize("clear", [False, True])
def test_ecc_checks_actual_fpga_part_before_transactions(
    ecc_tcl_harness: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    board: str,
    vendor: str,
    part: str,
    expected: str,
    clear: bool,
) -> None:
    """Cable discovery can succeed while the attached FPGA is wrong."""
    cable = f"localhost:3121/xilinx_tcf/{vendor}/888"
    monkeypatch.setitem(
        ecc.select_target.__globals__, "get_available_targets", lambda *a, **kw: [cable]
    )
    monkeypatch.setattr(
        sys,
        "argv",
        ["ddr_ecc_status.py", board, "--target", cable, "--non-interactive"]
        + (["--clear"] if clear else []),
    )
    monkeypatch.setenv("TEST_ECC_PART", part)
    monkeypatch.setenv("TEST_ECC_WRONG_WINDOW", "1")
    results = run_ecc_with_tcl_harness(monkeypatch, ecc_tcl_harness)
    assert ecc.main() == 1
    capture = capsys.readouterr()
    assert f"Expected FPGA part {expected} for {board}, found {part}" in capture.err
    assert "Clean:" not in capture.out
    assert "TXN " not in results[0].stdout


@pytest.mark.parametrize(
    "board,base,reason",
    [
        ("vcu118", "0x80000001", "must align to a 32-bit word"),
        ("vcu118", "0xfffffff0", "exceeds the 32-bit JTAG address space"),
        ("vcu118", "nothex", "32-bit hexadecimal ECC window base is required"),
        ("vcu118", "0x40000000", "ECC window for vcu118 is 0x80000000"),
        ("x3", "0x80000000", "ECC window for x3 is 0x40000000"),
    ],
)
def test_ecc_tcl_rejects_invalid_base_before_opening_manager(
    ecc_tcl_harness: Path, board: str, base: str, reason: str
) -> None:
    """Direct Tcl calls validate the supplied address against the board design."""
    result = subprocess.run(
        ["tclsh", str(ecc_tcl_harness), str(ecc.TCL_SCRIPT), TARGET, "1", base, board],
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert result.returncode == 1
    assert reason in result.stderr
    assert "OPEN_MANAGER" not in result.stdout
    assert "TXN " not in result.stdout


def test_ecc_tcl_starts_host_python_without_vivado_environment(
    ecc_tcl_harness: Path, tmp_path: Path
) -> None:
    """Remove Vivado's Python settings from the child process only."""
    python_env = {
        "PYTHONHOME": str(tmp_path / "fake_vivado_python_3_13_0"),
        "PYTHONPATH": str(tmp_path / "vivado modules"),
        "PYTHON": str(tmp_path / "vivado python"),
    }
    child_env = tmp_path / "child-env"
    host_python = tmp_path / "host python"
    host_python.write_text(r"""#!/bin/sh
printf '%s\n' "${PYTHONHOME-unset}" "${PYTHONPATH-unset}" "${PYTHON-unset}" \
    > "$TEST_ECC_CHILD_ENV"
exec "$TEST_ECC_HOST_PYTHON" "$@"
""")
    host_python.chmod(0o755)
    with ecc_tcl_harness.open("a") as harness:
        harness.write("""
foreach name {PYTHONHOME PYTHONPATH PYTHON} {
    puts "PARENT_ENV $name=$::env($name)"
}
""")
    result = subprocess.run(
        [
            "tclsh",
            str(ecc_tcl_harness),
            str(ecc.TCL_SCRIPT),
            TARGET,
            "0",
            "0x40000000",
            "x3",
            "",
            "",
            str(host_python),
        ],
        capture_output=True,
        text=True,
        env={
            **os.environ,
            **python_env,
            "TEST_ECC_CHILD_ENV": str(child_env),
            "TEST_ECC_HOST_PYTHON": sys.executable,
            "TEST_ECC_PART": "xcu26_ux35",
        },
        timeout=10,
    )
    assert result.returncode == 0, result.stderr
    assert child_env.read_text().splitlines() == ["unset"] * len(python_env)
    output = result.stdout.splitlines()
    assert "FROST_ECC_DONE" in output
    for name, value in python_env.items():
        assert f"PARENT_ENV {name}={value}" in output


@pytest.mark.parametrize("txn", [11, 12, 13])
def test_ecc_clear_reports_tool_failure_at_each_phase(
    ecc_tcl_harness: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    txn: int,
) -> None:
    """A failure during either clear write or the after sample fails the CLI."""
    monkeypatch.setenv("TEST_ECC_PART", "xcvu9p")
    monkeypatch.setenv("TEST_ECC_FAIL_TXN", str(txn))
    monkeypatch.setattr(sys, "argv", ["ddr_ecc_status.py", "vcu118", "--clear"])
    monkeypatch.setattr(ecc, "select_target", lambda *a, **kw: TARGET)
    results = run_ecc_with_tcl_harness(monkeypatch, ecc_tcl_harness)
    assert ecc.main() == 1
    capture = capsys.readouterr()
    assert "injected ECC transaction failure" in capture.err
    assert "Clean:" not in capture.out
    assert results[0].stdout.count("TXN ") == txn


def test_ecc_window_follows_jtag_assignment(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The JTAG C0_REG offset comes from the selected design recipe."""
    x3 = ecc.ECC_WINDOW_DESIGNS["x3"].read_text()
    design = tmp_path / "x3_ddr_bd.tcl"
    # Leave the first 1 GiB DDR segment and the ECC_AXI C0_REG segment in place.
    design.write_text(
        x3.replace("0x40000000 -range 0x00008000", "0x60000000 -range 0x00008000", 1)
    )
    monkeypatch.setitem(ecc.ECC_WINDOW_DESIGNS, "x3", design)
    assert ecc.ecc_window_base("x3") == 0x60000000


@pytest.mark.parametrize("count", [0, 2])
def test_ecc_cli_rejects_missing_or_ambiguous_window_before_discovery(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    count: int,
) -> None:
    """Only one JTAG assignment can authorize an ECC address."""
    design = tmp_path / "vcu118_ddr_bd.tcl"
    design.write_text(ecc.ECC_WINDOW_DESIGNS["vcu118"].read_text() * count)
    monkeypatch.setitem(ecc.ECC_WINDOW_DESIGNS, "vcu118", design)
    monkeypatch.setattr(sys, "argv", ["ddr_ecc_status.py", "vcu118"])
    monkeypatch.setattr(
        ecc, "select_target", lambda *a, **kw: pytest.fail("JTAG discovery")
    )
    assert ecc.main() == 1
    assert f"expected one C0_REG assignment for jtag_axi_ddr/Data, found {count}" in (
        capsys.readouterr().err
    )


@pytest.mark.parametrize(
    "assignment,reason",
    [
        ("0x00000000 -range 0x00008000", "overlaps the DDR data window"),
        ("0x80000001 -range 0x00008000", "must cover aligned 32-bit registers"),
        ("0x80000000 -range 0x000002c4", "must cover aligned 32-bit registers"),
        ("0xfffffff0 -range 0x00008000", "exceeds the 32-bit JTAG address space"),
    ],
)
def test_ecc_cli_rejects_invalid_design_windows(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    assignment: str,
    reason: str,
) -> None:
    """Invalid JTAG control windows fail before target discovery."""
    design = tmp_path / "vcu118_ddr_bd.tcl"
    original = ecc.ECC_WINDOW_DESIGNS["vcu118"].read_text()
    design.write_text(original.replace("0x80000000 -range 0x00008000", assignment))
    monkeypatch.setitem(ecc.ECC_WINDOW_DESIGNS, "vcu118", design)
    monkeypatch.setattr(sys, "argv", ["ddr_ecc_status.py", "vcu118"])
    monkeypatch.setattr(
        ecc, "select_target", lambda *a, **kw: pytest.fail("JTAG discovery")
    )
    assert ecc.main() == 1
    assert reason in capsys.readouterr().err


def test_ecc_register_offsets_match_the_controller() -> None:
    """ECC_REGISTERS has the controller's offsets and every register verdict() reads."""
    offsets = dict(ecc.ECC_REGISTERS)
    assert offsets["ECC_STATUS"] == 0x000
    assert offsets["ECC_EN_IRQ"] == 0x004
    assert offsets["ECC_ON_OFF"] == 0x008
    assert offsets["CE_CNT"] == 0x00C
    assert offsets["CE_FFA_31_00"] == 0x1C0
    assert offsets["UE_FFA_31_00"] == 0x2C0
    for name in ecc.VERDICT_REGISTERS:
        assert name in offsets
    assert len(offsets) == len(ecc.ECC_REGISTERS)


def test_ecc_parse_splits_before_and_after_clearing() -> None:
    """The transcript carries the master, the read values, and the cleared ones."""
    base = 0x40000000
    before, after, master = ecc.parse_report(
        "FROST_ECC_MASTER hw_axi_1\n"
        + ecc_sample(base, ECC_STATUS="00000003", CE_CNT="000000ff")
        + "FROST_ECC_CLEARED\n"
        + ecc_sample(base, marker="FROST_ECC_AFTER")
        + "FROST_ECC_DONE\n",
        base,
        clear=True,
    )
    assert master == "hw_axi_1"
    assert before == {**after, "ECC_STATUS": 0x3, "CE_CNT": 0xFF}
    assert after == {name: int(name == "ECC_ON_OFF") for name, _ in ecc.ECC_REGISTERS}


def ecc_sample(base: int, marker: str = "FROST_ECC", **values: str) -> str:
    """Build a complete addressed transcript with optional word overrides."""
    lines = []
    for name, offset in ecc.ECC_REGISTERS:
        data = values.get(name, "00000001" if name == "ECC_ON_OFF" else "00000000")
        lines.append(f"{marker} {name}@{base + offset:#010x}={data}\n")
    return "".join(lines)


@pytest.mark.parametrize(
    "values,exit_code,reason",
    [
        ({"ECC_STATUS": "0", "ECC_ON_OFF": "1", "CE_CNT": "0"}, 1, "malformed"),
        (
            {"ECC_STATUS": "0000", "ECC_ON_OFF": "0001", "CE_CNT": "0000"},
            1,
            "malformed",
        ),
        ({"ECC_ON_OFF": "100000001"}, 1, "100000001"),
        ({"ECC_STATUS": ""}, 1, "ECC_STATUS"),
        ({"ECC_STATUS": "ZZZZZZZZ"}, 1, "ZZZZZZZZ"),
        ({"CE_FFA_31_00": ""}, 1, "CE_FFA_31_00"),
        ({"CE_FFA_31_00": "NOT_HEX!"}, 1, "NOT_HEX!"),
        ({"ECC_ON_OFF": "deadbee1"}, 1, "ECC_ON_OFF has nonzero reserved bits"),
        ({"ECC_STATUS": "deadbee0"}, 1, "ECC_STATUS has nonzero reserved bits"),
        ({"ECC_ON_OFF": "00000000"}, 2, "ECC checking is disabled"),
        ({"CE_CNT": "00000001"}, 2, "CE_CNT is 1"),
        ({"ECC_STATUS": "00000002", "CE_CNT": "00000007"}, 2, "CE_CNT is 7"),
        ({"ECC_STATUS": "00000001"}, 2, "an uncorrectable error is latched"),
    ],
    ids=[
        "short_hex_1digit",
        "short_hex_4digit",
        "oversized_hex_9digit",
        "empty_verdict_value",
        "malformed_verdict_value",
        "empty_capture_value",
        "malformed_capture_value",
        "garbage_upper_bits_on_off",
        "garbage_upper_bits_status",
        "checking_disabled",
        "ce_cnt_only",
        "ce_cnt_and_status",
        "ue_status_bit",
    ],
)
def test_ecc_cli_rejects_bad_words_and_reports_dirty_samples(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    values: dict[str, str],
    exit_code: int,
    reason: str,
) -> None:
    """Reject malformed data and report valid samples with a recorded error."""
    output = "FROST_ECC_MASTER ddr\n" + ecc_sample(0x80000000, **values)
    mock_ecc_reply(monkeypatch, output + "FROST_ECC_DONE\n")
    assert ecc.main() == exit_code
    capture = capsys.readouterr()
    assert reason in (capture.err if exit_code == 1 else capture.out)
    assert "Clean:" not in capture.out


def mock_ecc_reply(
    monkeypatch: pytest.MonkeyPatch, output: str, *, clear: bool = False
) -> None:
    """Return a complete or partial transcript from a successful vendor process."""
    monkeypatch.setattr(
        sys,
        "argv",
        ["ddr_ecc_status.py", "vcu118"] + (["--clear"] if clear else []),
    )
    monkeypatch.setattr(ecc, "select_target", lambda *a, **kw: TARGET)
    monkeypatch.setattr(
        ecc.subprocess,
        "run",
        lambda command, **kw: subprocess.CompletedProcess(command, 0, output, ""),
    )


@pytest.mark.parametrize(
    "output,reason",
    [
        ("", "missing final FROST_ECC_DONE"),
        ("FROST_ECC_DONE\n", "missing FROST_ECC_MASTER"),
    ],
    ids=["empty_output", "only_done"],
)
def test_ecc_cli_requires_registers_even_when_the_tool_exits_successfully(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    output: str,
    reason: str,
) -> None:
    """A zero exit or a standalone completion marker alone cannot pass."""
    mock_ecc_reply(monkeypatch, output)
    assert ecc.main() == 1
    assert reason in capsys.readouterr().err


@pytest.mark.parametrize(
    "previous,replacement,reason",
    [
        (
            "FROST_ECC_DONE\n",
            "WARNING: FROST_ECC_DONE was never reached\n",
            "missing final",
        ),
        (
            "ECC_STATUS@0x80000000=00000000\n",
            "ECC_STATUS@0x80000000=00000001\nFROST_ECC ECC_STATUS@0x80000000=00000000\n",
            "duplicate ECC_STATUS",
        ),
        (
            "@0x80000008=",
            "@0x40000008=",
            "reported address 0x40000008, expected 0x80000008",
        ),
        (
            "FROST_ECC CE_CNT@0x8000000c=00000000\n",
            "",
            "missing FROST_ECC register replies: CE_CNT",
        ),
        (
            "FROST_ECC CE_FFA_31_00@0x800001c0=00000000\n",
            "",
            "missing FROST_ECC register replies: CE_FFA_31_00",
        ),
    ],
)
def test_ecc_cli_rejects_incomplete_or_misdirected_transcript(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    previous: str,
    replacement: str,
    reason: str,
) -> None:
    """A transcript needs a completion line and one observation per address."""
    output = "FROST_ECC_MASTER ddr\n" + ecc_sample(0x80000000) + "FROST_ECC_DONE\n"
    assert previous in output
    mock_ecc_reply(monkeypatch, output.replace(previous, replacement, 1))
    assert ecc.main() == 1
    capture = capsys.readouterr()
    assert reason in capture.err
    assert "Clean:" not in capture.out


@pytest.mark.parametrize("marker", ["", "FROST_ECC_CLEARED\n"])
def test_ecc_clear_requires_confirmation_and_all_after_reads(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], marker: str
) -> None:
    """A clean first sample cannot stand in for a completed clear."""
    output = "FROST_ECC_MASTER ddr\n" + ecc_sample(0x80000000)
    mock_ecc_reply(monkeypatch, output + marker + "FROST_ECC_DONE\n", clear=True)
    assert ecc.main() == 1
    capture = capsys.readouterr()
    reason = "missing FROST_ECC_AFTER" if marker else "expected one FROST_ECC_CLEARED"
    assert reason in capture.err
    assert "Clean:" not in capture.out


def test_ecc_clear_keeps_the_original_dirty_verdict(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A completed clear reports the original error and the second sample."""
    base = 0x80000000
    output = (
        "FROST_ECC_MASTER ddr\n"
        + ecc_sample(base, CE_CNT="00000001")
        + "FROST_ECC_CLEARED\n"
        + ecc_sample(base, marker="FROST_ECC_AFTER")
        + "FROST_ECC_DONE\n"
    )
    mock_ecc_reply(monkeypatch, output, clear=True)
    assert ecc.main() == 2
    report = capsys.readouterr().out
    assert "After clearing:" in report
    assert "Not clean: CE_CNT is 1" in report


def test_ecc_verdict_named_every_way_the_board_can_be_dirty() -> None:
    """Clean needs checking on and both registers zero; each fault is named."""
    assert ecc.verdict({"ECC_STATUS": 0, "CE_CNT": 0, "ECC_ON_OFF": 1}) == (True, [])

    # ECC errors from reading uninitialized DDR.
    clean, problems = ecc.verdict({"ECC_STATUS": 0x3, "CE_CNT": 0xFF, "ECC_ON_OFF": 1})
    assert not clean
    assert any("saturated" in p for p in problems)

    # The status bits are the controller's order: bit 0 uncorrectable, bit 1
    # correctable. Tested one at a time, so swapping them cannot pass.
    clean, problems = ecc.verdict(
        {"ECC_STATUS": ecc.ECC_STATUS_UE, "CE_CNT": 0, "ECC_ON_OFF": 1}
    )
    assert not clean and problems == ["an uncorrectable error is latched in ECC_STATUS"]
    clean, problems = ecc.verdict(
        {"ECC_STATUS": ecc.ECC_STATUS_CE, "CE_CNT": 0, "ECC_ON_OFF": 1}
    )
    assert not clean and problems == ["a correctable error is latched in ECC_STATUS"]
    assert (ecc.ECC_STATUS_UE, ecc.ECC_STATUS_CE) == (0x1, 0x2)

    # A counter below saturation is reported exactly, not as "at least".
    clean, problems = ecc.verdict({"ECC_STATUS": 0, "CE_CNT": 3, "ECC_ON_OFF": 1})
    assert not clean and problems == ["CE_CNT is 3"]

    # Zeros with checking disabled are the absence of a measurement, not a
    # clean one: the controller captures nothing while ECC_ON_OFF is clear.
    clean, problems = ecc.verdict({"ECC_STATUS": 0, "CE_CNT": 0, "ECC_ON_OFF": 0})
    assert not clean and problems == [
        "ECC checking is disabled, so the counters mean nothing"
    ]

    # A register the controller did not return is not a clean report.
    clean, problems = ecc.verdict({"ECC_STATUS": 0, "ECC_ON_OFF": 1})
    assert not clean and problems == ["CE_CNT was not read"]


@pytest.mark.parametrize(
    "board,capacity,clock", [("x3", 1 << 30, 322265625), ("vcu118", 1 << 31, 200000000)]
)
def test_board_loader_configuration(board: str, capacity: int, clock: int) -> None:
    """Loader clocks and DDR capacity agree with the selected hardware target."""
    assert loader.board_ddr_bytes(board) == capacity
    assert loader.board_clock_freq(board, {}) == (
        clock,
        False,
    )
    if board == "vcu118":
        with pytest.raises(ValueError, match="fixed CPU clock"):
            loader.board_clock_freq(board, {"FROST_CPU_CLK_HZ": "250000000"})


@pytest.mark.parametrize("app", ["memerr_readback", "svpbmt_cmo_test"])
def test_loader_refuses_apps_requiring_x3_memory_features(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], app: str
) -> None:
    """Reject incompatible applications before building or selecting a target."""
    monkeypatch.setattr(sys, "argv", ["load_software.py", "vcu118", app])
    monkeypatch.setattr(
        loader, "compile_app_for_board", lambda *a, **kw: pytest.fail("app build")
    )
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **kw: pytest.fail("JTAG discovery")
    )
    with pytest.raises(SystemExit) as rejected:
        loader.main()
    assert rejected.value.code == 2
    assert f"{app} is not supported on vcu118" in capsys.readouterr().err
    assert app in loader.valid_apps_for_board("x3")


@pytest.mark.parametrize("interface_one", [False, True])
def test_vcu118_serial_prefers_console_interface(
    monkeypatch: pytest.MonkeyPatch, interface_one: bool
) -> None:
    """Console discovery prefers the FPGA's CP2105 interface and leaves X3 alone."""
    defaults = load_module("managed_defaults", "fpga/common/hw_defaults.py")
    console = "/dev/serial/by-id/usb-Silicon_Labs_CP2105-console-if01-port0"
    system = "/dev/serial/by-id/usb-Silicon_Labs_CP2105-system-if00-port0"
    monkeypatch.setattr(
        defaults.glob,
        "glob",
        lambda pattern: (
            ([console] if interface_one else []) if "if01" in pattern else [system]
        ),
    )
    assert defaults.DEFAULT_SERIALS["vcu118"] == (console if interface_one else system)
    assert defaults.DEFAULT_SERIALS["x3"] == "/dev/ttyUSB3"
    monkeypatch.setattr(defaults.glob, "glob", lambda pattern: [])
    assert defaults.DEFAULT_SERIALS["vcu118"] == "/dev/ttyUSB0"


@pytest.mark.parametrize("board", ("x3", "vcu118"))
@pytest.mark.parametrize("mode", ("-v0", "-v1"))
@pytest.mark.parametrize("app", loader.COREMARK_PRO_APP_NAMES)
def test_coremark_pro_modes_build_for_each_board(
    monkeypatch: pytest.MonkeyPatch, board: str, mode: str, app: str
) -> None:
    """Every registered workload reaches compilation with explicit mode settings."""
    monkeypatch.delenv("FROST_CPU_CLK_HZ", raising=False)
    monkeypatch.setattr(
        sys, "argv", ["load_software.py", board, app, mode, "--build-only"]
    )
    builds = []

    def compile_app(*args: Any, **kwargs: Any) -> bool:
        builds.append((args, kwargs))
        return True

    monkeypatch.setattr(loader, "compile_app_for_board", compile_app)
    monkeypatch.setattr(loader, "validate_prebuilt_app", lambda *a, **k: None)
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )
    loader.main()
    assert len(builds) == 1
    arguments, options = builds[0]
    make_vars = arguments[4]
    assert make_vars["COREMARK_PRO_OFFICIAL"] == "1"
    if mode == "-v1":
        assert make_vars["COREMARK_PRO_RUN_ARGS"] == "-v1"
    else:
        run_args = make_vars["COREMARK_PRO_RUN_ARGS"].split()
        assert run_args[0] == "-v0" and int(run_args[1][2:]) > 0
        if board == "vcu118":
            reference = loader.coremark_pro_make_vars(app, hardware=True, board="x3")
            reference_args = reference["COREMARK_PRO_RUN_ARGS"].split()
            assert int(run_args[1][2:]) == 2 * int(reference_args[1][2:])
    assert options["ddr_bytes"] == (1 << 30 if board == "x3" else 1 << 31)


@pytest.mark.parametrize("capacity", (1 << 30, 1 << 31))
@pytest.mark.parametrize(
    "value",
    (
        None,
        "0x20000000",
        "0x40000000",
        "2147483648",
        "0",
        "-1",
        "garbage",
        "",
        "1",
        "0x100000000",
    ),
)
@pytest.mark.parametrize("source", ("environment", "make"))
def test_linux_memory_override_stays_within_board(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capacity: int,
    value: str | None,
    source: str,
) -> None:
    """Invalid memory nodes fail before make; supported smaller allocations survive."""
    monkeypatch.delenv("FROST_DDR_CAPACITY_LOG2_BYTES", raising=False)
    monkeypatch.delenv("FROST_LINUX_MEM_SIZE", raising=False)
    make_vars = {}
    if value is not None:
        if source == "environment":
            monkeypatch.setenv("FROST_LINUX_MEM_SIZE", value)
        else:
            make_vars["FROST_LINUX_MEM_SIZE"] = value
    commands = []

    def run(command: list[str], **kwargs: Any) -> Any:
        commands.append((command, kwargs["env"]))
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(loader.subprocess, "run", run)
    for name in ("sw.mem", "sw.txt"):
        (tmp_path / name).write_text("00000013\n")
    accepted = loader.compile_app_for_board(
        "linux_boot", tmp_path, 1, 1, make_vars, ddr_bytes=capacity
    )
    valid = value in (None, "0x20000000", "0x40000000") or (
        value == "2147483648" and capacity == 1 << 31
    )
    assert accepted is valid
    if valid:
        assert len(commands) == 2
        expected = capacity if value is None else int(value, 0)
        assert all(int(env["FROST_LINUX_MEM_SIZE"]) == expected for _, env in commands)
        assert all(
            int(env["FROST_DDR_CAPACITY_LOG2_BYTES"]) == capacity.bit_length() - 1
            for _, env in commands
        )
    else:
        assert commands == []


@pytest.mark.parametrize("first", ("bram", "ddr"))
@pytest.mark.parametrize("fault", ("none", "probe_wr", "probe_rd", "bad_data"))
def test_loader_probe_failure_never_selects_memory(
    tmp_path: Path, first: str, fault: str
) -> None:
    """Transport errors and corrupt replies abort before reset or image writes."""
    app_dir = tmp_path / "sw/apps/hello_world"
    app_dir.mkdir(parents=True)
    for name in ("sw.txt", "sw_ddr.txt"):
        (app_dir / name).write_text("00000013\n00000013\n")
    # An unrelated build's probes must not replace the programmed image's metadata.
    probes = tmp_path / "fpga/build/vcu118/work/vcu118_frost.ltx"
    probes.parent.mkdir(parents=True)
    probes.write_text("stale probes")
    harness = tmp_path / "probe.tcl"
    harness.write_text(r"""
set actual_script [lindex $argv 0]
set argv [lrange $argv 1 end]
set argc [llength $argv]
proc open_hw_manager {} {puts OPEN_MANAGER}
proc connect_hw_server {args} {}
proc get_hw_targets {} {return {localhost:3219/xilinx_tcf/Xilinx/cable-1}}
proc current_hw_target {target} {}
proc open_hw_target {} {}
proc get_hw_devices {} {return device0}
proc refresh_hw_device {device} {}
proc reset_hw_axi {axi} {}
proc set_property {key value device} {puts "PROPERTY:$key:$value:$device"}
proc get_hw_axis {args} {
    if {[llength $args] == 1} {return [lindex $args 0]}
    return [expr {$::env(TEST_FIRST) eq "ddr" ? "ddr bram" : "bram ddr"}]
}
proc get_property {key object} {
    if {$key eq "CELL_NAME"} {return {}}
    if {$key eq "DATA"} {
        if {$::env(TEST_FAULT) eq "bad_data"} {return DEADBEEF}
        return [expr {$::env(TEST_FIRST) eq "ddr" ? "A5A5A5A5" : "00000000"}]
    }
    return $object
}
proc create_hw_axi_txn {name axi args} {puts "CREATE:$name:$axi"}
proc get_hw_axi_txns {name} {return $name}
proc delete_hw_axi_txn {name} {puts "DELETE:$name"}
proc run_hw_axi {name} {
    if {$name eq $::env(TEST_FAULT)} {error "injected $name failure"}
}
proc close_hw_target {} {puts CLOSE_TARGET}
proc disconnect_hw_server {} {puts DISCONNECT_SERVER}
proc close_hw_manager {} {puts CLOSE_MANAGER}
source $actual_script
""")
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("FROST_ILA_")
    }
    env.update(TEST_FIRST=first, TEST_FAULT=fault)
    result = subprocess.run(
        [
            "tclsh",
            str(harness),
            str(ROOT / "fpga/load_software/load_software.tcl"),
            str(tmp_path),
            "hello_world",
            TARGET,
            "",
            "1",
            "127.0.0.1:3219",
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.stdout.endswith("CLOSE_TARGET\nDISCONNECT_SERVER\nCLOSE_MANAGER\n")
    assert "PROPERTY:PROBES.FILE:" not in result.stdout
    assert result.stdout.count("DELETE:probe_wr") == 2
    assert result.stdout.count("DELETE:probe_rd") == 2
    writes = [
        line
        for line in result.stdout.splitlines()
        if line.startswith("CREATE:") and not line.startswith("CREATE:probe_")
    ]
    if fault != "none":
        assert result.returncode == 1
        assert not writes
        assert "FROST_LOAD_COMPLETE" not in result.stdout
        assert (
            "injected" if fault != "bad_data" else "Unexpected AXI probe data"
        ) in result.stderr
    else:
        assert result.returncode == 0, result.stderr
        assert "CREATE:rst_assert:bram" in writes
        assert any(
            line.startswith("CREATE:ddrwr") and line.endswith(":ddr") for line in writes
        )
        assert any(
            line.startswith("CREATE:bramwr") and line.endswith(":bram")
            for line in writes
        )
        assert "FROST_LOAD_COMPLETE" in result.stdout


@pytest.mark.parametrize("board,vendor", (("x3", "Xilinx"), ("vcu118", "Digilent")))
def test_board_target_vendor_selection(
    monkeypatch: pytest.MonkeyPatch, board: str, vendor: str
) -> None:
    """Board selection isolates cables by vendor before choosing a target."""
    cables = [
        f"localhost:3121/xilinx_tcf/{name}/cable" for name in ("Xilinx", "Digilent")
    ]
    monkeypatch.setattr(target, "get_available_targets", lambda *a, **k: cables)
    selected = target.select_target("vivado", board=board, non_interactive=True)
    assert selected == f"localhost:3121/xilinx_tcf/{vendor}/cable"


def test_coremark_pro_missing_budget_is_an_argument_error(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Incomplete board registration fails before compilation or hardware access."""
    monkeypatch.delenv("FROST_CPU_CLK_HZ", raising=False)
    monkeypatch.setattr(
        sys,
        "argv",
        ["load_software.py", "vcu118", "coremark_pro_core", "-v0", "--build-only"],
    )

    def missing(*args: Any, **kwargs: Any) -> Any:
        raise ValueError("missing iteration budget")

    monkeypatch.setattr(loader, "coremark_pro_make_vars", missing)
    monkeypatch.setattr(
        loader, "compile_app_for_board", lambda *a, **k: pytest.fail("make ran")
    )
    with pytest.raises(SystemExit) as stopped:
        loader.main()
    assert stopped.value.code == 2
    assert "missing iteration budget" in capsys.readouterr().err


@pytest.mark.parametrize("board,floor", (("x3", 600.0), ("vcu118", 1200.0)))
@pytest.mark.parametrize("requested", (300.0, 1800.0))
def test_coremark_pro_zip_timeout_preserves_board_and_caller_budgets(
    board: str, floor: float, requested: float
) -> None:
    """ZIP's setup budget raises short timeouts without lowering explicit ones."""
    registry = sys.modules[loader.coremark_pro_make_vars.__module__]
    assert registry.coremark_pro_hardware_timeout(
        "coremark_pro_zip", board, requested
    ) == max(floor, requested)


@pytest.mark.parametrize(
    "board,app,options",
    [
        ("x3", "bootrom", []),
        ("vcu118", "bootrom", ["--ddr"]),
        ("x3", "fsbl", []),
        ("vcu118", "fsbl", []),
    ],
)
def test_flash_stage_loader_rejects_invalid_execution(
    monkeypatch: pytest.MonkeyPatch, board: str, app: str, options: list[str]
) -> None:
    """A flash-stage address must not be relocated to the JTAG reset vector."""
    monkeypatch.setattr(sys, "argv", ["load_software.py", board, app, *options])
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **kw: pytest.fail("cable touched")
    )
    monkeypatch.setattr(
        loader, "compile_app_for_board", lambda *a, **kw: pytest.fail("build started")
    )
    with pytest.raises(SystemExit) as error:
        loader.main()
    assert error.value.code == 2


@pytest.mark.parametrize("board", ["x3", "vcu118"])
def test_loader_lists_targets_without_an_application(
    monkeypatch: pytest.MonkeyPatch, board: str
) -> None:
    """Board application filtering permits target discovery without an app."""
    monkeypatch.setattr(sys, "argv", ["loader", board, "--list-targets"])
    calls: list[dict[str, Any]] = []
    monkeypatch.setattr(
        loader, "select_target", lambda *args, **kwargs: calls.append(kwargs)
    )
    monkeypatch.setattr(
        loader, "compile_app_for_board", lambda *a, **kw: pytest.fail("build started")
    )
    loader.main()
    assert len(calls) == 1
    assert calls[0]["list_only"] is True
    assert calls[0]["board"] == board


# --- Vector width and advertisement settings ---------------------------------


def _write_vector_board_repo(
    root: Path,
    *,
    x3_vlen: int = 256,
    x3_advertise: bool = True,
    vcu118_vector: bool = False,
    vcu118_vlen: int = 256,
    vcu118_advertise: bool = False,
    vcu118_via_param: bool = False,
) -> None:
    """Create a minimal board RTL and DDR layout under ``root``."""
    (root / "boards/x3").mkdir(parents=True, exist_ok=True)
    (root / "boards/vcu118").mkdir(parents=True, exist_ok=True)
    (root / "fpga/build").mkdir(parents=True, exist_ok=True)
    for board in ("x3", "vcu118"):
        target_bd = root / f"fpga/build/{board}_ddr_bd.tcl"
        if not target_bd.exists():
            target_bd.symlink_to(ROOT / f"fpga/build/{board}_ddr_bd.tcl")
    (root / "boards/xilinx_frost_subsystem.sv").write_text(
        "module xilinx_frost_subsystem #(\n"
        "    parameter bit VECTOR = 1'b0,\n"
        "    parameter int unsigned VLEN = 256,\n"
        "    parameter bit VECTOR_ADVERTISE = 1'b0\n"
        ") ();\n"
        "endmodule\n",
        encoding="utf-8",
    )
    x3_adv_line = (
        f"      .VECTOR_ADVERTISE(1'b{int(x3_advertise)}),\n" if x3_advertise else ""
    )
    (root / "boards/x3/x3_frost.sv").write_text(
        "module x3_frost #(\n"
        "    parameter int unsigned PERF_COUNTERS = 0\n"
        ") ();\n"
        "  xilinx_frost_subsystem #(\n"
        "      .VECTOR(1'b1),\n"
        f"      .VLEN({x3_vlen}),\n"
        f"{x3_adv_line}"
        "      .RAW_LOOPBACK(0)\n"
        "  ) subsystem ();\n"
        "endmodule\n",
        encoding="utf-8",
    )
    if vcu118_vector:
        header_params = (
            f"    parameter bit VECTOR = 1'b1,\n"
            f"    parameter int unsigned VLEN = {vcu118_vlen},\n"
            f"    parameter bit VECTOR_ADVERTISE = 1'b{int(vcu118_advertise)}\n"
            if vcu118_via_param
            else "    parameter bit MISALIGNED_HW = 1'b1\n"
        )
        vec_bind = "VECTOR" if vcu118_via_param else "1'b1"
        vlen_bind = "VLEN" if vcu118_via_param else str(vcu118_vlen)
        adv_bind = (
            "VECTOR_ADVERTISE" if vcu118_via_param else f"1'b{int(vcu118_advertise)}"
        )
        vcu_overrides = (
            f"      .VECTOR            ({vec_bind}),\n"
            f"      .VLEN              ({vlen_bind}),\n"
            f"      .VECTOR_ADVERTISE  ({adv_bind}),\n"
        )
    else:
        header_params = "    parameter bit MISALIGNED_HW = 1'b1\n"
        vcu_overrides = "      // .VECTOR(1'b1), .VECTOR_ADVERTISE(1'b1),\n"
    (root / "boards/vcu118/vcu118_frost.sv").write_text(
        "module vcu118_frost #(\n"
        f"{header_params}"
        ") ();\n"
        "  xilinx_frost_subsystem #(\n"
        "      .MISALIGNED_HW     (MISALIGNED_HW && (1 != 0)),\n"
        f"{vcu_overrides}"
        "      .RAW_LOOPBACK      (0)\n"
        "  ) u_frost_subsystem ();\n"
        "endmodule\n",
        encoding="utf-8",
    )


def _scratch_vector_repo(
    tmp_path: Path,
    app: str,
    *,
    x3_vlen: int = 256,
    x3_advertise: bool = True,
    vcu118_vector: bool = False,
    vcu118_vlen: int = 256,
    vcu118_advertise: bool = False,
) -> Path:
    """Create a self-contained scratch repository for compiling a vector app."""
    _write_vector_board_repo(
        tmp_path,
        x3_vlen=x3_vlen,
        x3_advertise=x3_advertise,
        vcu118_vector=vcu118_vector,
        vcu118_vlen=vcu118_vlen,
        vcu118_advertise=vcu118_advertise,
    )
    sw = tmp_path / "sw"
    (sw / "apps").mkdir(parents=True, exist_ok=True)
    for shared in ("common", "lib"):
        link = sw / shared
        if not link.exists():
            link.symlink_to(ROOT / "sw" / shared, target_is_directory=True)
    vec_common = sw / "apps" / "vec_common"
    if not vec_common.exists():
        vec_common.symlink_to(ROOT / "sw/apps/vec_common", target_is_directory=True)
    app_dir = sw / "apps" / app
    if not app_dir.exists():
        app_dir.mkdir()
        for source in (ROOT / "sw/apps" / app).iterdir():
            if source.name == "Makefile" or source.suffix in {".c", ".h", ".S"}:
                if source.name != "sw.S":
                    shutil.copy2(source, app_dir / source.name)
    return app_dir


def test_vec_vlen_apps_match_registered_sources() -> None:
    """VEC_VLEN_APPS matches every registered app whose C sources read VEC_VLEN."""
    discovered = set()
    for app in loader.VALID_APPS:
        source_dir = ROOT / "sw/apps" / loader.app_build_directory_name(app)
        if not source_dir.is_dir():
            continue
        for path in source_dir.iterdir():
            if path.suffix in {".c", ".h"} and "VEC_VLEN" in path.read_text(
                encoding="utf-8", errors="replace"
            ):
                discovered.add(app)
                break
    assert discovered == set(loader.VEC_VLEN_APPS)
    assert "vec_state_test" in loader.valid_apps_for_board("x3")
    assert "vec_state_test" in loader.valid_apps_for_board("vcu118")
    assert "vec_state_test" in loader.DEBUG_APPS


def test_board_vector_config_reads_rtl_defaults_and_variants(tmp_path: Path) -> None:
    """board_vector_config tracks X3 widths, VCU118 variants, and rejects invalid RTL."""
    # Live repository checks: X3 has a 256-bit vector unit; VCU118 matches its RTL.
    live_x3_vlen, live_x3_adv = loader.board_vector_config("x3")
    assert live_x3_vlen == 256
    assert isinstance(live_x3_adv, bool)
    live_vcu_vlen, live_vcu_adv = loader.board_vector_config("vcu118")
    assert live_vcu_vlen in loader.SUPPORTED_VEC_STATE_VLENS
    if live_vcu_vlen == 0:
        assert live_vcu_adv is False

    # X3 at 128, 256, 512 advertised and 256 unadvertised; VCU118 scalar (comments ignored).
    for width, advertise in ((128, True), (256, True), (512, True), (256, False)):
        repo = tmp_path / f"x3_{width}_{int(advertise)}"
        _write_vector_board_repo(repo, x3_vlen=width, x3_advertise=advertise)
        assert loader.board_vector_config("x3", project_root=repo) == (width, advertise)
        assert loader.board_vector_config("vcu118", project_root=repo) == (0, False)

    # VCU118 with Verible-aligned parameter references and direct literals.
    for via_param, advertise in ((True, False), (True, True), (False, True)):
        repo = tmp_path / f"vcu_{int(via_param)}_{int(advertise)}"
        _write_vector_board_repo(
            repo,
            vcu118_vector=True,
            vcu118_vlen=256,
            vcu118_advertise=advertise,
            vcu118_via_param=via_param,
        )
        assert loader.board_vector_config("vcu118", project_root=repo) == (
            256,
            advertise,
        )

    # Invalid RTL configurations fail closed.
    bad_adv = tmp_path / "bad_adv"
    _write_vector_board_repo(bad_adv)
    (bad_adv / "boards/vcu118/vcu118_frost.sv").write_text(
        "module vcu118_frost ();\n"
        "  xilinx_frost_subsystem #(.VECTOR(1'b0), .VECTOR_ADVERTISE(1'b1)) u ();\n"
        "endmodule\n",
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="VECTOR_ADVERTISE=1 requires VECTOR=1"):
        loader.board_vector_config("vcu118", project_root=bad_adv)

    bad_vlen = tmp_path / "bad_vlen"
    _write_vector_board_repo(bad_vlen, x3_vlen=64)
    with pytest.raises(ValueError, match="VLEN must be one of"):
        loader.board_vector_config("x3", project_root=bad_vlen)


@pytest.mark.parametrize(
    "board,app,argv_extra,expected_cflags",
    [
        ("x3", "vec_state_test", [], "-DVEC_VLEN=256 -DVEC_ADVERTISE=1"),
        (
            "x3",
            "vec_state_test",
            ["--vlen", "128"],
            "-DVEC_VLEN=128 -DVEC_ADVERTISE=1",
        ),
        (
            "x3",
            "vec_state_test",
            ["--vlen", "512"],
            "-DVEC_VLEN=512 -DVEC_ADVERTISE=1",
        ),
        (
            "x3",
            "vec_state_test",
            ["--vlen", "256", "--no-vec-advertise"],
            "-DVEC_VLEN=256 -DVEC_ADVERTISE=0",
        ),
        (
            "x3",
            "vec_state_test",
            ["--vlen", "0"],
            "-DVEC_VLEN=0 -DVEC_ADVERTISE=0",
        ),
        ("vcu118", "vec_state_test", [], "-DVEC_VLEN=0 -DVEC_ADVERTISE=0"),
        (
            "vcu118",
            "vec_state_test",
            ["--vlen", "0"],
            "-DVEC_VLEN=0 -DVEC_ADVERTISE=0",
        ),
        (
            "vcu118",
            "vec_state_test",
            ["--vlen", "256"],
            "-DVEC_VLEN=256 -DVEC_ADVERTISE=0",
        ),
        (
            "vcu118",
            "vec_state_test",
            ["--vlen", "256", "--vec-advertise"],
            "-DVEC_VLEN=256 -DVEC_ADVERTISE=1",
        ),
        ("x3", "vec_fp_test", [], "-DVEC_VLEN=256"),
        ("x3", "vec_fp_test", ["--vlen", "128"], "-DVEC_VLEN=128"),
        ("x3", "vec_integer_test", ["--vlen", "512"], "-DVEC_VLEN=512"),
        ("x3", "vec_crypto_exec_test", ["--vlen", "128"], "-DVEC_VLEN=128"),
        ("x3", "vec_source_eew_test", ["--vlen", "512"], "-DVEC_VLEN=512"),
        ("x3", "vec_vstart_reload_test", ["--vlen", "128"], "-DVEC_VLEN=128"),
        ("x3", "vec_vtype_handoff_test", ["--vlen", "512"], "-DVEC_VLEN=512"),
    ],
)
def test_loader_vector_options_build_expected_make_vars(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    board: str,
    app: str,
    argv_extra: list[str],
    expected_cflags: str,
) -> None:
    """Loader CLI computes per-program vector make_vars from RTL defaults and overrides."""
    _write_vector_board_repo(tmp_path, x3_vlen=256, x3_advertise=True)
    (tmp_path / "sw/apps" / app).mkdir(parents=True)
    monkeypatch.setattr(loader, "PROJECT_ROOT", tmp_path)
    monkeypatch.delenv("FROST_CPU_CLK_HZ", raising=False)
    monkeypatch.delenv("EXTRA_CFLAGS", raising=False)
    monkeypatch.setattr(
        sys, "argv", ["load_software.py", board, app, *argv_extra, "--build-only"]
    )
    builds: list[dict[str, str]] = []

    def compile_app(*args: Any, **kwargs: Any) -> bool:
        builds.append(args[4])
        return True

    monkeypatch.setattr(loader, "compile_app_for_board", compile_app)
    monkeypatch.setattr(loader, "validate_prebuilt_app", lambda *a, **k: {})
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )
    loader.main()
    assert builds == [{"EXTRA_CFLAGS": expected_cflags}]


@pytest.mark.parametrize(
    "argv,env_cflags,reason",
    [
        (
            ["x3", "vec_state_test", "--vlen", "0", "--vec-advertise"],
            None,
            "--vec-advertise requires a nonzero --vlen",
        ),
        (
            ["vcu118", "vec_state_test", "--vec-advertise"],
            None,
            "--vec-advertise requires a nonzero --vlen",
        ),
        (
            ["x3", "vec_fp_test", "--vlen", "0"],
            None,
            "requires a nonzero --vlen",
        ),
        (
            ["x3", "vec_fp_test", "--vec-advertise"],
            None,
            "only valid for vec_state_test",
        ),
        (
            ["x3", "vec_fp_test", "--no-vec-advertise"],
            None,
            "only valid for vec_state_test",
        ),
        (
            ["x3", "hello_world", "--vlen", "256"],
            None,
            "only valid for vector-width applications",
        ),
        (
            ["x3", "vec_arith_test", "--vlen", "128"],
            None,
            "only valid for vector-width applications",
        ),
        (
            ["x3", "hello_world", "--no-vec-advertise"],
            None,
            "only valid for vec_state_test",
        ),
        (
            ["x3", "vec_state_test", "--vlen", "64"],
            None,
            "invalid choice:",
        ),
        (
            ["x3", "--list-targets", "--vlen", "256"],
            None,
            "cannot be combined",
        ),
        (
            ["x3", "--list-targets", "--vec-advertise"],
            None,
            "cannot be combined",
        ),
        (
            ["x3", "vec_state_test"],
            "-DVEC_VLEN=128",
            "conflicts with selected VEC_VLEN=256",
        ),
        (
            ["x3", "vec_state_test"],
            "-D VEC_VLEN=128",
            "conflicts with selected VEC_VLEN=256",
        ),
        (
            ["x3", "vec_state_test"],
            "-DVEC_VLEN",
            "must assign an integer value to VEC_VLEN",
        ),
        (
            ["x3", "vec_state_test"],
            "-UVEC_VLEN",
            "cannot undefine VEC_VLEN",
        ),
        (
            ["x3", "vec_state_test"],
            "-DVEC_ADVERTISE=0",
            "conflicts with selected VEC_ADVERTISE=1",
        ),
        (
            ["x3", "vec_state_test"],
            "-UVEC_ADVERTISE",
            "cannot undefine VEC_ADVERTISE",
        ),
    ],
)
def test_loader_rejects_invalid_vector_options_before_build(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
    argv: list[str],
    env_cflags: str | None,
    reason: str,
) -> None:
    """Bad vector options or conflicting EXTRA_CFLAGS fail before build or cable."""
    _write_vector_board_repo(tmp_path, x3_vlen=256, x3_advertise=True)
    monkeypatch.setattr(loader, "PROJECT_ROOT", tmp_path)
    monkeypatch.delenv("EXTRA_CFLAGS", raising=False)
    if env_cflags is not None:
        monkeypatch.setenv("EXTRA_CFLAGS", env_cflags)
    monkeypatch.setattr(sys, "argv", ["load_software.py", *argv])
    monkeypatch.setattr(
        loader, "compile_app_for_board", lambda *a, **k: pytest.fail("build ran")
    )
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )
    with pytest.raises(SystemExit) as stopped:
        loader.main()
    assert stopped.value.code == 2
    assert reason in capsys.readouterr().err


def test_loader_preserves_unrelated_extra_cflags_with_vector_settings(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Non-conflicting inherited EXTRA_CFLAGS survive alongside VEC_VLEN."""
    _write_vector_board_repo(tmp_path, x3_vlen=256, x3_advertise=True)
    make_vars = loader.vector_app_make_vars(
        "vec_state_test",
        "x3",
        vlen=128,
        environment={"EXTRA_CFLAGS": "-DMY_FLAG=1 -DVEC_VLEN=128"},
        project_root=tmp_path,
    )
    assert make_vars == {"EXTRA_CFLAGS": "-DMY_FLAG=1 -DVEC_VLEN=128 -DVEC_ADVERTISE=1"}


def test_vec_state_test_vlen_and_advertise_reach_program_and_build_identity(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """Compiled vec_state_test receives VEC_VLEN and keeps distinct build identities.

    Builds the real vec_state_test through load_software.main() --build-only at
    scalar (0) and VLEN 128, 256, and 512, plus advertised vs unadvertised, and
    also builds a preprocessor probe sharing vec_state_test's Makefile so both
    VEC_VLEN and VEC_ADVERTISE are verified directly inside the linked ELF.
    Fails if VEC_VLEN or VEC_ADVERTISE fails to reach the C compiler.
    """
    app_dir = _scratch_vector_repo(
        tmp_path, "vec_state_test", x3_vlen=256, x3_advertise=True
    )
    monkeypatch.setattr(loader, "PROJECT_ROOT", tmp_path)
    monkeypatch.delenv("FROST_CPU_CLK_HZ", raising=False)
    monkeypatch.delenv("EXTRA_CFLAGS", raising=False)
    monkeypatch.delenv("MEM_CONFIG", raising=False)
    monkeypatch.delenv("FROST_DEBUG", raising=False)
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )

    configs: list[tuple[str, list[str], int, int]] = [
        ("vcu118", [], 0, 0),
        ("x3", ["--vlen", "0"], 0, 0),
        ("x3", ["--vlen", "128"], 128, 1),
        ("x3", [], 256, 1),
        ("x3", ["--vlen", "512"], 512, 1),
        ("x3", ["--vlen", "256", "--no-vec-advertise"], 256, 0),
        ("vcu118", ["--vlen", "256", "--vec-advertise"], 256, 1),
    ]
    config_hashes: dict[tuple[str, int, int], str] = {}
    x3_elfs_by_vlen: dict[int, bytes] = {}
    last_cfg: tuple[str, list[str], str] | None = None

    for board, extra, want_vlen, want_adv in configs:
        monkeypatch.setattr(
            sys,
            "argv",
            ["load_software.py", board, "vec_state_test", *extra, "--build-only"],
        )
        loader.main()
        out = capsys.readouterr().out
        assert "FROST_BUILD_COMPLETE" in out
        sha_lines = [
            line.split("=", 1)[1]
            for line in out.splitlines()
            if line.startswith("FROST_BUILD_CONFIG_SHA256=")
        ]
        assert len(sha_lines) == 1
        sha = sha_lines[0]
        assert len(sha) == 64

        stamp = (app_dir / ".frost-build-config.bin").read_text(encoding="utf-8")
        assert f"-DVEC_VLEN={want_vlen}" in stamp
        assert f"-DVEC_ADVERTISE={want_adv}" in stamp

        elf = (app_dir / "sw.elf").read_bytes()
        # Prove VEC_VLEN reached the real C preprocessor: scalar vs vector branch.
        if want_vlen == 0:
            assert b"VS reads zero\0" in elf
            assert b"VS resets Off\0" not in elf
            assert b"vstart keeps log2(VLEN) bits\0" not in elf
            assert b"fault buffer in low BRAM\0" not in elf
        else:
            assert b"VS reads zero\0" not in elf
            assert b"VS resets Off\0" in elf
            assert b"vstart keeps log2(VLEN) bits\0" in elf
            assert b"fault buffer in low BRAM\0" in elf

        key = (board, want_vlen, want_adv)
        assert sha not in config_hashes.values(), f"duplicate build identity for {key}"
        config_hashes[key] = sha
        if board == "x3" and (want_vlen == 0 or want_adv == 1):
            x3_elfs_by_vlen[want_vlen] = elf
        last_cfg = (board, extra, sha)

    # Every VLEN (0, 128, 256, 512) must produce a distinct compiled program image.
    assert set(x3_elfs_by_vlen) == {0, 128, 256, 512}
    assert len(set(x3_elfs_by_vlen.values())) == 4

    # --skip-build accepts the matching configuration and rejects every mismatch.
    assert last_cfg is not None
    last_board, last_extra, last_sha = last_cfg
    called_vivado: list[list[str]] = []
    with monkeypatch.context() as skip_patch:
        skip_patch.setattr(loader, "select_target", lambda *a, **k: TARGET)
        skip_patch.setattr(
            loader.subprocess, "run", lambda cmd, **kw: called_vivado.append(cmd)
        )
        skip_patch.setattr(
            sys,
            "argv",
            [
                "load_software.py",
                last_board,
                "vec_state_test",
                *last_extra,
                "--skip-build",
                "--expected-build-config-sha256",
                last_sha,
            ],
        )
        loader.main()
    assert len(called_vivado) == 1

    monkeypatch.setattr(
        loader, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )
    for bad_argv in (
        ["vcu118", "vec_state_test", "--skip-build"],
        [
            "vcu118",
            "vec_state_test",
            "--vlen",
            "128",
            "--vec-advertise",
            "--skip-build",
        ],
        [
            "vcu118",
            "vec_state_test",
            "--vlen",
            "256",
            "--no-vec-advertise",
            "--skip-build",
        ],
        ["x3", "vec_state_test", "--vlen", "256", "--vec-advertise", "--skip-build"],
    ):
        monkeypatch.setattr(sys, "argv", ["load_software.py", *bad_argv])
        with pytest.raises(SystemExit) as rejected:
            loader.main()
        assert rejected.value.code == 2

    # Verify that compiling vec_state_test directly without EXTRA_CFLAGS falls
    # back to scalar VEC_VLEN=0, proving the loader's flags are load-bearing.
    direct = subprocess.run(
        ["make", "-s", "clean"],
        cwd=app_dir,
        capture_output=True,
        text=True,
        timeout=60,
        check=True,
    )
    assert direct.returncode == 0
    direct_build = subprocess.run(
        ["make", "-s", "FPGA_CPU_CLK_FREQ=322265625"],
        cwd=app_dir,
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert direct_build.returncode == 0, direct_build.stdout + direct_build.stderr
    fallback_elf = (app_dir / "sw.elf").read_bytes()
    assert b"VS reads zero\0" in fallback_elf
    assert b"VS resets Off\0" not in fallback_elf

    # Direct preprocessor probe using vec_state_test's Makefile: fail if either
    # exact VEC_VLEN value or VEC_ADVERTISE value does not reach the compiled ELF.
    (app_dir / "main.c").write_text(
        '#include "uart.h"\n'
        "#define STR_(x) #x\n"
        "#define STR(x) STR_(x)\n"
        "int main(void) {\n"
        '    uart_puts("PROBE:VLEN=" STR(VEC_VLEN) ":ADV=" STR(VEC_ADVERTISE));\n'
        "    return 0;\n"
        "}\n",
        encoding="utf-8",
    )
    for board, extra, want_vlen, want_adv in (
        ("vcu118", [], 0, 0),
        ("x3", ["--vlen", "128"], 128, 1),
        ("x3", [], 256, 1),
        ("x3", ["--vlen", "512"], 512, 1),
        ("x3", ["--vlen", "256", "--no-vec-advertise"], 256, 0),
    ):
        monkeypatch.setattr(
            sys,
            "argv",
            ["load_software.py", board, "vec_state_test", *extra, "--build-only"],
        )
        loader.main()
        capsys.readouterr()
        elf = (app_dir / "sw.elf").read_bytes()
        marker = f"PROBE:VLEN={want_vlen}:ADV={want_adv}\0".encode()
        assert marker in elf, f"{marker!r} missing from compiled ELF"


def test_vector_width_app_rebuilds_distinct_elf_per_vlen(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    tmp_path: Path,
) -> None:
    """Non-state VEC_VLEN apps (e.g. vec_vtype_handoff_test) honor --vlen."""
    app_dir = _scratch_vector_repo(
        tmp_path, "vec_vtype_handoff_test", x3_vlen=256, x3_advertise=True
    )
    monkeypatch.setattr(loader, "PROJECT_ROOT", tmp_path)
    monkeypatch.delenv("FROST_CPU_CLK_HZ", raising=False)
    monkeypatch.delenv("EXTRA_CFLAGS", raising=False)
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )
    elfs: dict[int, bytes] = {}
    hashes: dict[int, str] = {}
    for width in (128, 256, 512):
        monkeypatch.setattr(
            sys,
            "argv",
            [
                "load_software.py",
                "x3",
                "vec_vtype_handoff_test",
                "--vlen",
                str(width),
                "--build-only",
            ],
        )
        loader.main()
        out = capsys.readouterr().out
        sha = next(
            line.split("=", 1)[1]
            for line in out.splitlines()
            if line.startswith("FROST_BUILD_CONFIG_SHA256=")
        )
        elfs[width] = (app_dir / "sw.elf").read_bytes()
        hashes[width] = sha
    assert len(set(elfs.values())) == 3
    assert len(set(hashes.values())) == 3
    # Last build was 512; --skip-build at 128 must fail before cable discovery.
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "load_software.py",
            "x3",
            "vec_vtype_handoff_test",
            "--vlen",
            "128",
            "--skip-build",
        ],
    )
    with pytest.raises(SystemExit) as rejected:
        loader.main()
    assert rejected.value.code == 2


def test_validate_prebuilt_vector_contract_rejects_bad_configs(tmp_path: Path) -> None:
    """Direct prebuilt validation fails closed on missing or conflicting vector flags."""
    directory = tmp_path / "vec_state_test"
    write_prebuilt(
        directory,
        minimal_debug_elf(),
        FPGA_CPU_CLK_FREQ="322265625",
        CFLAGS="-O3 -DVEC_VLEN=256 -DVEC_ADVERTISE=1",
    )
    ok = loader.validate_prebuilt_app(
        directory,
        322265625,
        "bram",
        True,
        app_name="vec_state_test",
        make_vars={"EXTRA_CFLAGS": "-DVEC_VLEN=256 -DVEC_ADVERTISE=1"},
    )
    assert ok["app"] == "vec_state_test"

    for bad_vars, pattern in (
        (None, "requires the selected vector settings"),
        ({}, "requires the selected vector settings"),
        ({"EXTRA_CFLAGS": "-DVEC_VLEN=256"}, "missing required vector macro"),
        (
            {"EXTRA_CFLAGS": "-DVEC_VLEN=64 -DVEC_ADVERTISE=1"},
            "unsupported VEC_VLEN=64",
        ),
        (
            {"EXTRA_CFLAGS": "-DVEC_VLEN=0 -DVEC_ADVERTISE=1"},
            "cannot set VEC_ADVERTISE=1 with VEC_VLEN=0",
        ),
        (
            {"EXTRA_CFLAGS": "-DVEC_VLEN=128 -DVEC_ADVERTISE=1"},
            "prebuilt vector length or advertisement differs",
        ),
        (
            {"EXTRA_CFLAGS": "-DVEC_VLEN=256 -DVEC_ADVERTISE=0"},
            "prebuilt vector length or advertisement differs",
        ),
    ):
        with pytest.raises(ValueError, match=pattern):
            loader.validate_prebuilt_app(
                directory,
                322265625,
                "bram",
                True,
                app_name="vec_state_test",
                make_vars=bad_vars,
            )

    # A prebuilt stamp lacking explicit VEC_VLEN/VEC_ADVERTISE or containing a
    # conflicting definition is rejected even for scalar VEC_VLEN=0.
    for bad_cflags in (
        "-O3",
        "-O3 -DVEC_VLEN=0",
        "-O3 -DVEC_VLEN=256 -UVEC_VLEN -DVEC_ADVERTISE=1",
        "-O3 -DVEC_VLEN=128 -DVEC_VLEN=256 -DVEC_ADVERTISE=1",
    ):
        (directory / ".frost-build-config.bin").write_text(
            f"MEM_CONFIG=bram|FROST_DEBUG=1|FPGA_CPU_CLK_FREQ=322265625|CFLAGS={bad_cflags}\n",
            encoding="utf-8",
        )
        with pytest.raises(ValueError):
            loader.validate_prebuilt_app(
                directory,
                322265625,
                "bram",
                True,
                app_name="vec_state_test",
                make_vars={"EXTRA_CFLAGS": "-DVEC_VLEN=0 -DVEC_ADVERTISE=0"},
            )


def test_vcu118_vector_loader_options_and_clocks(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Opt-in VCU118 --vector selects 162.5 MHz, VLEN 256, misa.V, vector apps, and V DTB."""
    # Default VCU118 remains scalar at 200 MHz with no vector-unit apps.
    assert loader.board_clock_freq("vcu118", {}) == (200_000_000, False)
    assert loader.board_vector_config("vcu118") == (0, False)
    assert not (set(loader.valid_apps_for_board("vcu118")) & loader.VECTOR_UNIT_APPS)

    # Opt-in VCU118 vector selects 162.5 MHz, VLEN 256, advertised V, and vector apps.
    assert loader.board_clock_freq("vcu118", {}, vector=True) == (162_500_000, False)
    assert loader.board_clock_freq(
        "vcu118", {"FROST_CPU_CLK_HZ": "162500000"}, vector=True
    ) == (162_500_000, True)
    assert loader.board_clock_freq("vcu118", {"FROST_CPU_CLK_HZ": "162500000"}) == (
        162_500_000,
        True,
    )
    assert loader.board_vector_config("vcu118", vector=True) == (256, True)
    assert loader.VECTOR_UNIT_APPS <= set(
        loader.valid_apps_for_board("vcu118", vector=True)
    )
    with pytest.raises(ValueError, match="fixed CPU clock"):
        loader.board_clock_freq(
            "vcu118", {"FROST_CPU_CLK_HZ": "200000000"}, vector=True
        )
    with pytest.raises(ValueError, match="fixed CPU clock"):
        loader.board_clock_freq(
            "vcu118", {"FROST_CPU_CLK_HZ": "162500000"}, vector=False
        )

    # CLI builds vector apps and vec_state_test at 162.5 MHz with VLEN=256, VEC_ADVERTISE=1.
    monkeypatch.delenv("FROST_CPU_CLK_HZ", raising=False)
    monkeypatch.delenv("EXTRA_CFLAGS", raising=False)
    monkeypatch.setattr(loader, "validate_prebuilt_app", lambda *a, **k: {})
    monkeypatch.setattr(
        loader, "select_target", lambda *a, **k: pytest.fail("cable touched")
    )
    monkeypatch.setattr(loader, "_linux_boot_preflight", lambda: None)

    for argv, expected_clock, expected_cflags, expected_vector in (
        (["vcu118", "hello_world", "--vector", "--build-only"], 162_500_000, {}, True),
        (
            ["vcu118", "vec_arith_test", "--vector", "--build-only"],
            162_500_000,
            {},
            True,
        ),
        (
            ["vcu118", "vec_state_test", "--vector", "--build-only"],
            162_500_000,
            {"EXTRA_CFLAGS": "-DVEC_VLEN=256 -DVEC_ADVERTISE=1"},
            True,
        ),
        (
            ["vcu118", "vec_fp_test", "--vector", "--build-only"],
            162_500_000,
            {"EXTRA_CFLAGS": "-DVEC_VLEN=256"},
            True,
        ),
        (["vcu118", "linux_boot", "--vector", "--build-only"], 162_500_000, {}, True),
        (["vcu118", "linux_boot", "--build-only"], 200_000_000, {}, False),
    ):
        seen: list[tuple[int, dict[str, str], bool]] = []

        def capture_compile(*args: Any, **kwargs: Any) -> bool:
            seen.append((args[2], args[4], bool(kwargs.get("vector", False))))
            return True

        with monkeypatch.context() as mp:
            mp.setattr(loader, "compile_app_for_board", capture_compile)
            mp.setattr(sys, "argv", ["load_software.py", *argv])
            loader.main()
        assert seen == [(expected_clock, expected_cflags, expected_vector)]

    # compile_app_for_board exports FROST_LINUX_VECTOR=1 for vcu118 vector and 0 for scalar.
    for vector_flag, expected_env in ((False, "0"), (True, "1")):
        captured_envs: list[dict[str, str]] = []

        def fake_run(cmd: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
            captured_envs.append(dict(kwargs["env"]))
            return subprocess.CompletedProcess(cmd, 0)

        monkeypatch.setattr(loader.subprocess, "run", fake_run)
        monkeypatch.setattr(Path, "exists", lambda _self: True)
        monkeypatch.setenv("FROST_LINUX_VECTOR", "1" if not vector_flag else "0")
        assert loader.compile_app_for_board(
            "linux_boot",
            ROOT / "sw/apps/linux_boot",
            162_500_000 if vector_flag else 200_000_000,
            10800,
            ddr_bytes=1 << 31,
            board="vcu118",
            vector=vector_flag,
        )
        assert captured_envs[-1]["FROST_LINUX_BOARD"] == "vcu118"
        assert captured_envs[-1]["FROST_LINUX_VECTOR"] == expected_env
        assert captured_envs[-1]["FPGA_CPU_CLK_FREQ"] == str(
            162_500_000 if vector_flag else 200_000_000
        )

    # Error paths: x3 --no-vector, scalar vcu118 + vector app, --list-targets --vector.
    for bad_argv, expected_err in (
        (
            ["x3", "hello_world", "--no-vector"],
            "--no-vector is only supported for vcu118",
        ),
        (["vcu118", "vec_arith_test"], "vec_arith_test is not supported on vcu118"),
        (["vcu118", "--list-targets", "--vector"], "cannot be combined"),
    ):
        monkeypatch.setattr(sys, "argv", ["load_software.py", *bad_argv])
        with pytest.raises(SystemExit) as stopped:
            loader.main()
        assert stopped.value.code == 2
        assert expected_err in capsys.readouterr().err
