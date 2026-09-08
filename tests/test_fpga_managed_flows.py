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

"""Managed FPGA CLI contracts, using mocked Vivado and isolated software builds."""

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
    """A managed caller cannot accidentally choose a substring neighbor."""
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
    """Debug compilation can complete while another process owns JTAG."""
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
    assert calls == [{"mem_config": None, "debug": True}]
    records = [
        line
        for line in capsys.readouterr().out.splitlines()
        if line.startswith("FROST_DEBUG_BUILD=")
    ]
    assert len(records) == 1
    assert json.loads(records[0].split("=", 1)[1]) == descriptor


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
    assert not loader.compile_app_for_board("hello_world", tmp_path, 150000000, 1)
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
    """Compile in a temporary tree; final profile flags override hostile tuning."""
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
            "FPGA_CPU_CLK_FREQ=150000000",
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
    descriptor = loader.validate_prebuilt_app(app_dir, 150000000, mode, True)
    effective_memory = "ddr" if app in loader.FORCED_DDR_APPS else mode
    assert descriptor["effectiveMemory"] == effective_memory
    assert descriptor["startStrategy"] == (
        "main" if effective_memory == "bram" else "attach"
    )
    assert descriptor["appDirectory"] == str(app_dir.resolve())
    mismatches = [
        (300000000, mode, True),
        (150000000, mode, False),
    ]
    if app not in loader.FORCED_DDR_APPS:
        mismatches.append((150000000, "ddr" if mode == "bram" else "bram", True))
    for clock, memory, debug in mismatches:
        with pytest.raises(ValueError):
            loader.validate_prebuilt_app(app_dir, clock, memory, debug)
    (app_dir / "sw.txt").write_text("nothex!!\n")
    with pytest.raises(ValueError, match="invalid 32-bit"):
        loader.validate_prebuilt_app(app_dir, 150000000, mode, True)


def minimal_debug_elf(
    *, main: bool = True, writable_ddr: bool = False, entry: int = 0
) -> bytes:
    """Create bounded ELF tables for startup-policy and malformed-input checks."""
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
    """Write fixture images and the existing Make stamp, without compiling."""
    directory.mkdir(parents=True)
    (directory / "sw.elf").write_bytes(elf)
    (directory / "sw.txt").write_text("00000013\n")
    (directory / "sw_ddr.txt").write_text("00000000\n")
    config = {
        "MEM_CONFIG": "bram",
        "FROST_DEBUG": "1",
        "FPGA_CPU_CLK_FREQ": "150000000",
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
    """BRAM selection alone cannot establish that crt0 restores loaded DDR."""
    directory = tmp_path / "hello_world"
    write_prebuilt(
        directory, minimal_debug_elf(main=main, writable_ddr=writable_ddr, entry=entry)
    )
    descriptor = loader.validate_prebuilt_app(directory, 150000000, "bram", True)
    assert descriptor["startStrategy"] == strategy
    assert descriptor["elf"] == str(directory / "sw.elf")
    assert len(descriptor["buildConfigSha256"]) == 64


@pytest.mark.parametrize(
    "corruption",
    ["header", "sections", "section_payload", "names", "symbol_link", "empty_dwarf"],
)
def test_invalid_elf_tables_fail_closed(corruption: str) -> None:
    """Truncated or fabricated table ranges never become debugger metadata."""
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
    """Shared CoreMark-PRO artifact names cannot substitute another workload."""
    directory = tmp_path / "coremark_pro"
    selected = loader.coremark_pro_make_vars(
        "coremark_pro_core", hardware=True, hardware_mode="validation", board="x3"
    )
    flags = {
        key: "0"
        for key in [
            "COREMARK_PRO_TRACE",
            "FROST_MALLOC_DISABLE_FREE",
            "FROST_MALLOC_GUARD_FREE",
            "FROST_MALLOC_EVICT_FREE",
            "FROST_MEMORY_FENCE_WRITES",
        ]
    }
    write_prebuilt(directory, minimal_debug_elf(), **selected, **flags)
    descriptor = loader.validate_prebuilt_app(
        directory,
        150000000,
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
                directory, 150000000, "bram", True, app_name=app, make_vars=changed
            )


@pytest.mark.parametrize("matching", [False, True])
def test_config_hash_binds_build_before_cable(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, matching: bool
) -> None:
    """The build-only descriptor binds the exact prebuilt configuration."""
    directory = tmp_path / "sw/apps/hello_world"
    write_prebuilt(directory, minimal_debug_elf())
    descriptor = loader.validate_prebuilt_app(directory, 150000000, "bram", True)
    monkeypatch.setattr(loader, "PROJECT_ROOT", tmp_path)
    monkeypatch.setenv("FROST_CPU_CLK_HZ", "150000000")
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
    """Unsupported composite image layouts fail before preflight or build."""
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
    """Generic debugging must not impose a new contract on ordinary PRO loads."""
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
        lambda *a, **k: pytest.fail("new validator affected ordinary load"),
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
def test_tcl_program_connection_cleanup(tmp_path: Path, failure: bool) -> None:
    """Run actual programmer Tcl with fake Vivado commands, never a server."""
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
    result = subprocess.run(
        [
            "tclsh",
            str(harness),
            str(ROOT / "fpga/program_bitstream/program_bitstream.tcl"),
            str(ROOT),
            "x3",
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
    assert result.returncode == int(failure), result.stderr
    assert "CONNECT:-url 127.0.0.1:3219" in result.stdout
    assert result.stdout.endswith("CLOSE_TARGET\nDISCONNECT_SERVER\nCLOSE_MANAGER\n")
    assert ("FROST_PROGRAM_COMPLETE" in result.stdout) is not failure


def test_tcl_loader_missing_image_never_opens_manager(tmp_path: Path) -> None:
    """Direct Tcl callers receive the same preflight protection."""
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
            "debug_target",
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
    assert "BRAM image" in result.stderr and "SHOULD_NOT_OPEN" not in result.stdout


@pytest.mark.parametrize("failure", [False, True])
def test_tcl_loader_transfer_and_cleanup(tmp_path: Path, failure: bool) -> None:
    """Exercise actual BRAM/DDR helper dispatch with fake AXI transactions."""
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
