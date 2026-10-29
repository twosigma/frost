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

"""Check flash images, boot-stage bounds and programming without hardware."""

import ctypes
from pathlib import Path
import struct
import subprocess
import sys

import pytest

from test_fpga_managed_flows import ROOT, load_module

packer = load_module("flash_packer", "fpga/flash/make_flash_image.py")
programmer = load_module("flash_programmer", "fpga/flash/program_flash.py")


def components(directory: Path) -> dict[str, Path]:
    """Create distinct payloads, including a minimal DTB envelope."""
    paths = {}
    for index, name in enumerate(("FSBL", "OpenSBI", "DTB", "U-Boot")):
        path = directory / name
        path.write_bytes(bytes([index + 1]) * 101)
        paths[name] = path
    paths["DTB"].write_bytes(struct.pack(">II", 0xD00DFEED, 40) + bytes(32))
    return paths


def test_flash_headers_and_padding(tmp_path: Path) -> None:
    """All payloads have CRC headers, fixed offsets and erased padding."""
    import zlib

    paths = components(tmp_path)
    output = tmp_path / "flash.bin"
    packer.build_flash_image(ROOT, output, paths)
    image = output.read_bytes()
    assert len(image) == 0x400000
    for index, part in enumerate(packer.PARTITIONS):
        payload = paths[part["name"]].read_bytes()
        offset = index * 0x100000
        header = struct.unpack_from("<8I", image, offset)
        assert header == (
            0x54535246,
            1,
            part["load_addr"],
            len(payload),
            zlib.crc32(payload),
            part["entry_addr"],
            0,
            0,
        )
        assert image[offset + 32 : offset + 32 + len(payload)] == payload
        assert set(image[offset + 32 + len(payload) : offset + 0x100000]) == {255}


@pytest.mark.parametrize(
    "name,capacity",
    [("FSBL", 0x13C00), ("OpenSBI", 0xFFFE0), ("DTB", 0x20000), ("U-Boot", 0xFFFE0)],
)
@pytest.mark.parametrize("extra", [-1, 1])
def test_flash_rejects_invalid_sizes(
    tmp_path: Path, name: str, capacity: int, extra: int
) -> None:
    """Empty and overflowing components cannot overwrite an adjacent partition."""
    paths = components(tmp_path)
    paths[name].write_bytes(bytes(0 if extra == -1 else capacity + extra))
    output = tmp_path / "flash.bin"
    output.write_bytes(b"preserve")
    with pytest.raises(ValueError, match=name):
        packer.build_flash_image(ROOT, output, paths)
    assert output.read_bytes() == b"preserve"


def test_boot_header_bounds(tmp_path: Path) -> None:
    """Execute the firmware's validator on overflow, alignment and entry errors."""
    source = tmp_path / "header.c"
    source.write_text(
        '#include "flash_boot.h"\nint check(flash_image_hdr_t *h) { return flash_image_valid(h, 0x4000, 0x13c00); }\n'
    )
    library = tmp_path / "header.so"
    subprocess.run(
        [
            "cc",
            "-shared",
            "-fPIC",
            "-I",
            str(ROOT / "sw/lib/include"),
            str(source),
            "-o",
            str(library),
        ],
        check=True,
    )
    check = ctypes.CDLL(str(library)).check
    valid = [0x54535246, 1, 0x4000, 0x13C00, 0, 0x4000, 0, 0]
    assert check((ctypes.c_uint32 * 8)(*valid)) == 1
    for field, value in [
        (0, 0),
        (1, 2),
        (2, 0x4001),
        (2, 0xFFFFFFFC),
        (3, 0),
        (3, 0x13C01),
        (3, 0xFFFFFFFF),
        (5, 0x4002),
        (5, 0x80000000),
        (6, 1),
        (7, 1),
    ]:
        bad = valid.copy()
        bad[field] = value
        assert check((ctypes.c_uint32 * 8)(*bad)) == 0, (field, value)


def test_flash_prepare_does_not_discover_hardware(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Preparation uses argv paths and never acquires a cable."""
    boot = tmp_path / "boot image.bin"
    boot.write_bytes(bytes(0x400000))
    bit = tmp_path / "fpga image.bit"
    bit.write_bytes(b"bit")
    calls: list[list[str]] = []
    monkeypatch.setattr(
        programmer.subprocess, "run", lambda cmd, **kw: calls.append(cmd)
    )
    monkeypatch.setattr(
        programmer, "select_target", lambda *a, **kw: pytest.fail("hardware access")
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "program_flash.py",
            "--boot-image",
            str(boot),
            "--fpga-image",
            str(bit),
            "--output-dir",
            str(tmp_path / "out"),
            "--prepare-only",
        ],
    )
    programmer.main()
    assert len(calls) == 1 and calls[0][-4:-1] == ["prepare", str(boot), str(bit)]


@pytest.mark.parametrize("boot_only", [False, True])
def test_cfgmem_uses_bitstream_conversion(tmp_path: Path, boot_only: bool) -> None:
    """Tcl passes .bit through loadbit and software through loaddata."""
    boot = tmp_path / "boot image.bin"
    boot.write_bytes(bytes(0x400000))
    bit = tmp_path / "fpga image.bit"
    bit.write_bytes(b"bit")
    harness = tmp_path / "test.tcl"
    harness.write_text(
        "proc write_cfgmem {args} {puts $args}\nset script [lindex $argv 4]\nset argv [lrange $argv 0 3]\nset argc 4\nsource $script\n"
    )
    result = subprocess.run(
        [
            "tclsh",
            str(harness),
            "prepare",
            str(boot),
            "" if boot_only else str(bit),
            str(tmp_path / "out.bin"),
            str(ROOT / "fpga/flash/program_flash.tcl"),
        ],
        text=True,
        capture_output=True,
    )
    # The production script takes four arguments, excluding the harness path.
    assert result.returncode == 0, result.stderr
    assert "-loaddata" in result.stdout
    assert ("-loadbit" in result.stdout) == (not boot_only)


@pytest.mark.parametrize(
    "part,failure", [("xcvu9p", False), ("xcvu9p", True), ("xcux35", False)]
)
def test_flash_program_cleanup(tmp_path: Path, part: str, failure: bool) -> None:
    """The flash transaction rejects other devices and closes failed sessions."""
    cfg = tmp_path / "config.bin"
    cfg.write_bytes(b"cfg")
    cfg.with_suffix(".prm").write_text("prm")
    harness = tmp_path / "hardware.tcl"
    harness.write_text(r"""
set script [lindex $argv 0]
set part [lindex $argv 1]
set failure [lindex $argv 2]
set argv [lrange $argv 3 end]
set argc [llength $argv]
proc open_hw_manager {} {}
proc connect_hw_server {args} {puts "CONNECT:$args"}
proc get_hw_targets {} {return cable1}
proc current_hw_target {target} {puts "TARGET:$target"}
proc open_hw_target {} {}
proc get_hw_devices {} {return device0}
proc get_property {name object} {
    if {$name eq "PART"} {return $::part}
    return config0
}
proc get_cfgmem_parts {name} {return $name}
proc create_hw_cfgmem {args} {puts CREATE_CFG}
proc set_property {args} {}
proc create_hw_bitstream {args} {}
proc program_hw_devices {args} {}
proc refresh_hw_device {args} {}
proc program_hw_cfgmem {args} {
    puts PROGRAM_FLASH
    if {$::failure} {error "injected flash failure"}
}
proc close_hw_target {} {puts CLOSE_TARGET}
proc disconnect_hw_server {} {puts DISCONNECT_SERVER}
proc close_hw_manager {} {puts CLOSE_MANAGER}
source $script
""")
    result = subprocess.run(
        [
            "tclsh",
            str(harness),
            str(ROOT / "fpga/flash/program_flash.tcl"),
            part,
            str(int(failure)),
            "program",
            str(cfg),
            "cable1",
            "localhost:3219",
        ],
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert result.returncode == int(failure or part != "xcvu9p"), result.stderr
    assert result.stdout.endswith("CLOSE_TARGET\nDISCONNECT_SERVER\nCLOSE_MANAGER\n")
    assert ("PROGRAM_FLASH" in result.stdout) == (part == "xcvu9p")
    assert "TARGET:cable1" in result.stdout


def test_flash_listing_needs_no_images(monkeypatch: pytest.MonkeyPatch) -> None:
    """Listing cables never prepares configuration data or requires image files."""
    calls = []
    monkeypatch.setattr(sys, "argv", ["program_flash.py", "--list-targets"])
    monkeypatch.setattr(programmer, "select_target", lambda *a, **kw: calls.append(kw))
    monkeypatch.setattr(
        programmer.subprocess, "run", lambda *a, **kw: pytest.fail("Vivado preparation")
    )
    programmer.main()
    assert len(calls) == 1 and calls[0]["list_only"] is True
