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
import os
from pathlib import Path
import re
import struct
import subprocess
import sys

import pytest

from test_fpga_managed_flows import ROOT, load_module

packer = load_module("flash_packer", "fpga/flash/make_flash_image.py")
programmer = load_module("flash_programmer", "fpga/flash/program_flash.py")


TCL_HARNESS = (
    "proc write_cfgmem {args} {puts $args}\n"
    "set script [lindex $argv 4]\nset argv [lrange $argv 0 3]\nset argc 4\nsource $script\n"
)


def components(directory: Path) -> dict[str, Path]:
    """Create distinct payloads, including a minimal DTB envelope."""
    paths = {}
    for index, name in enumerate(("FSBL", "OpenSBI", "DTB", "U-Boot")):
        path = directory / name
        path.write_bytes(bytes([index + 1]) * 101)
        paths[name] = path
    paths["DTB"].write_bytes(struct.pack(">II", 0xD00DFEED, 40) + bytes(32))
    return paths


def test_boot_base_agrees_across_the_flash_tools() -> None:
    """The ROM header, the packer and the programmer place the boot partition together."""
    header = (ROOT / "sw/lib/include/flash_boot.h").read_text()
    match = re.search(r"#define FLASH_BOOT_BASE (0x[0-9a-fA-F]+)u", header)
    assert match is not None
    base = int(match.group(1), 16)
    assert base == packer.FLASH_BASE_OFFSET == 0x0400_0000
    assert [p["flash_abs_offset"] for p in packer.PARTITIONS] == [
        base + 0x100000 * i for i in range(4)
    ]
    tcl = (ROOT / "fpga/flash/program_flash.tcl").read_text()
    assert f"set boot_base 0x{base:08x}" in tcl
    assert base >= 0x300_0000 + 0x100_0000  # clears a 51.9 MB bitstream with margin


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
    comp_dir = tmp_path / "comps"
    comp_dir.mkdir()
    boot = tmp_path / "boot image.bin"
    packer.build_flash_image(tmp_path, boot, components(comp_dir))
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


def test_cfgmem_rejects_a_bitstream_that_reaches_the_boot_partition(
    tmp_path: Path,
) -> None:
    """A configuration image larger than the space below the boot partition is refused."""
    boot = tmp_path / "boot.bin"
    boot.write_bytes(bytes(0x400000))
    bit = tmp_path / "big.bit"
    with bit.open("wb") as handle:
        handle.truncate(0x0400_0001)
    harness = tmp_path / "test.tcl"
    harness.write_text(TCL_HARNESS)
    result = subprocess.run(
        [
            "tclsh",
            str(harness),
            "prepare",
            str(boot),
            str(bit),
            str(tmp_path / "o.bin"),
            str(ROOT / "fpga/flash/program_flash.tcl"),
        ],
        text=True,
        capture_output=True,
    )
    assert result.returncode != 0
    assert "exceeds the space below the boot partition" in result.stderr + result.stdout


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


def test_flash_packer_vector_selects_vector_dtb(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """--vector picks boards/vcu118/frost_vector.dtb unless --dtb overrides it."""
    fake_repo = tmp_path / "repo"
    scalar_dtb = struct.pack(">II", 0xD00DFEED, 44) + b"SCLR" + bytes(32)
    vector_dtb = struct.pack(">II", 0xD00DFEED, 44) + b"VECT" + bytes(32)
    custom_dtb = struct.pack(">II", 0xD00DFEED, 44) + b"CUST" + bytes(32)
    for part in packer.PARTITIONS:
        target = fake_repo / str(part["default_file"])
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(scalar_dtb if part["name"] == "DTB" else b"X" * 64)
    vec_target = fake_repo / packer.VECTOR_DTB_FILE
    vec_target.parent.mkdir(parents=True, exist_ok=True)
    vec_target.write_bytes(vector_dtb)
    custom_path = tmp_path / "custom.dtb"
    custom_path.write_bytes(custom_dtb)

    out_default = tmp_path / "default.bin"
    out_vector = tmp_path / "vector.bin"
    out_override = tmp_path / "override.bin"
    packer.build_flash_image(fake_repo, out_default)
    packer.build_flash_image(fake_repo, out_vector, vector=True)
    packer.build_flash_image(fake_repo, out_override, {"DTB": custom_path}, vector=True)

    dtb_off = 0x200000 + packer.HEADER_SIZE
    assert out_default.read_bytes()[dtb_off : dtb_off + len(scalar_dtb)] == scalar_dtb
    assert out_vector.read_bytes()[dtb_off : dtb_off + len(vector_dtb)] == vector_dtb
    assert out_override.read_bytes()[dtb_off : dtb_off + len(custom_dtb)] == custom_dtb

    captured: list[tuple[dict[str, Path], bool]] = []
    monkeypatch.setattr(
        packer,
        "build_flash_image",
        lambda _root, _out, comps, *, vector=False: captured.append((comps, vector)),
    )
    monkeypatch.setattr(
        sys,
        "argv",
        ["make_flash_image.py", "-o", str(tmp_path / "cli.bin"), "--vector"],
    )
    packer.main()
    assert captured == [({}, True)]


def test_flash_vlen_selection_and_mismatch_refusal(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Flash Makefile, make_flash_image.py, and program_flash.py support only default VLEN 256."""
    # 1. sw/uboot/Makefile allows VLEN=256 (or omitted) with VECTOR=1 and refuses non-256 VLENs.
    for make_vars, expected_target, expected_err in (
        (["VECTOR=1", "VLEN=256"], "frost_vector.dtb", None),
        (["VECTOR=1"], "frost_vector.dtb", None),
        (
            ["VECTOR=1", "VLEN=128"],
            None,
            "non-default VLENs are supported over JTAG loading only",
        ),
        (
            ["VECTOR=1", "VLEN=512"],
            None,
            "non-default VLENs are supported over JTAG loading only",
        ),
        (
            ["VECTOR=1", "VLEN=64"],
            None,
            "non-default VLENs are supported over JTAG loading only",
        ),
        (["VECTOR=0", "VLEN=128"], None, "VLEN requires VECTOR=1"),
    ):
        res = subprocess.run(
            ["make", "-n", "-C", str(ROOT / "sw/uboot"), "dtb", *make_vars],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if expected_err is not None:
            assert res.returncode != 0
            assert expected_err in res.stderr
        else:
            assert expected_target is not None
            assert res.returncode == 0, res.stderr
            assert expected_target in res.stdout

    # Ambient VLEN in the caller environment must not break scalar U-Boot builds.
    ambient_res = subprocess.run(
        ["make", "-n", "-C", str(ROOT / "sw/uboot"), "dtb", "VECTOR=0"],
        capture_output=True,
        text=True,
        timeout=15,
        env={**os.environ, "VLEN": "512"},
    )
    assert ambient_res.returncode == 0, ambient_res.stderr
    assert "frost.dtb" in ambient_res.stdout

    # 2. Build DTBs for scalar, VLEN=256, and VLEN=128/512.
    import zlib

    meta_mod = load_module("vcu118_meta_flash_test", "fpga/common/vcu118_metadata.py")
    packer_mod = load_module(
        "frost_boot_image_flash_test",
        "linux/buildroot-external/board/frost/frost_boot_image.py",
    )
    fake_repo = tmp_path / "repo"
    for part in packer.PARTITIONS:
        target = fake_repo / str(part["default_file"])
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"X" * 64)

    dtb_blobs: dict[int, bytes] = {}
    for vlen in (128, 256, 512):
        sub = tmp_path / f"dtb_{vlen}"
        sub.mkdir()
        dts = packer_mod.gen_dts(
            clk_hz=162_500_000,
            initrd_range=None,
            bootargs="",
            model=f"flash-v{vlen}",
            board="vcu118",
            vector=True,
            vlen=vlen,
        )
        dtb_blobs[vlen] = packer_mod.compile_dtb(dts, sub, "dtc")
    (fake_repo / packer.VECTOR_DTB_FILE).write_bytes(dtb_blobs[256])
    (fake_repo / "dtb_128.dtb").write_bytes(dtb_blobs[128])
    (fake_repo / "dtb_512.dtb").write_bytes(dtb_blobs[512])

    scalar_sub = tmp_path / "dtb_scalar"
    scalar_sub.mkdir()
    scalar_bytes = packer_mod.compile_dtb(
        (ROOT / "boards/vcu118/dts/frost_vcu118.dts").read_text(), scalar_sub, "dtc"
    )
    (fake_repo / "boards/vcu118/frost.dtb").write_bytes(scalar_bytes)

    # make_flash_image.py packs frost_vector.dtb for --vector / --vector --vlen 256.
    flash_256 = tmp_path / "flash_256.bin"
    packer.build_flash_image(fake_repo, flash_256, vector=True, vlen=256)
    meta_mod.verify_dtb_vector_config(
        meta_mod.extract_dtb_from_flash_image(flash_256),
        expected_vector=True,
        expected_vlen=256,
        source="flash_256",
    )
    flash_scalar = tmp_path / "flash_scalar.bin"
    packer.build_flash_image(fake_repo, flash_scalar, vector=False)

    # make_flash_image.py refuses non-256 --vlen (both helper and CLI), --vlen without
    # --vector, and non-256 --dtb payloads with a clear JTAG-only message.
    for bad_vlen in (128, 512):
        with pytest.raises(
            ValueError, match="non-default VLENs are supported over JTAG loading only"
        ):
            packer.build_flash_image(
                fake_repo, tmp_path / f"bad_{bad_vlen}.bin", vector=True, vlen=bad_vlen
            )
        with monkeypatch.context() as mp:
            mp.setattr(
                sys,
                "argv",
                [
                    "make_flash_image.py",
                    "-o",
                    str(tmp_path / f"cli_{bad_vlen}.bin"),
                    "--vector",
                    "--vlen",
                    str(bad_vlen),
                ],
            )
            with pytest.raises(SystemExit) as stopped:
                packer.main()
            assert stopped.value.code == 2
            assert (
                "non-default VLENs are supported over JTAG loading only"
                in capsys.readouterr().err
            )

    with monkeypatch.context() as mp:
        mp.setattr(
            sys,
            "argv",
            ["make_flash_image.py", "-o", str(tmp_path / "bad.bin"), "--vlen", "256"],
        )
        with pytest.raises(SystemExit) as stopped:
            packer.main()
        assert stopped.value.code == 2
        assert "--vlen requires --vector" in capsys.readouterr().err

    with pytest.raises(
        ValueError, match="non-default VLENs are supported over JTAG loading only"
    ):
        packer.build_flash_image(
            fake_repo,
            tmp_path / "mismatch_dtb.bin",
            {"DTB": fake_repo / "dtb_128.dtb"},
            vector=True,
        )

    # Craft 4 MiB flash images containing non-256 (VLEN-128 / VLEN-512) DTB partitions.
    dtb_off = 0x200000
    flash_128 = tmp_path / "flash_128.bin"
    flash_512 = tmp_path / "flash_512.bin"
    for target_flash, dtb_bytes in (
        (flash_128, dtb_blobs[128]),
        (flash_512, dtb_blobs[512]),
    ):
        raw_non256 = bytearray(flash_256.read_bytes())
        hdr = packer.make_header(
            0x8220_0000, 0x8220_0000, len(dtb_bytes), zlib.crc32(dtb_bytes)
        )
        raw_non256[dtb_off : dtb_off + 0x100000] = b"\xff" * 0x100000
        raw_non256[dtb_off : dtb_off + packer.HEADER_SIZE + len(dtb_bytes)] = (
            hdr + dtb_bytes
        )
        target_flash.write_bytes(raw_non256)

    # program_flash.py rejects non-256 bitstreams, --vlen != 256, and non-256 boot images
    # even when --fpga-image has no metadata sidecar and no --vlen is passed.
    bit_128 = tmp_path / "vcu118_frost_128.bit"
    bit_128.write_bytes(b"v128-bit")
    meta_mod.write_vcu118_bitstream_metadata(
        bit_128, vector=True, vlen=128, cpu_clock_hz=162_500_000
    )
    bit_256 = tmp_path / "vcu118_frost_256.bit"
    bit_256.write_bytes(b"v256-bit")
    meta_mod.write_vcu118_bitstream_metadata(
        bit_256, vector=True, vlen=256, cpu_clock_hz=162_500_000
    )
    bit_no_sidecar = tmp_path / "unannotated.bit"
    bit_no_sidecar.write_bytes(b"unannotated-bit")

    with monkeypatch.context() as mp:
        mp.setattr(
            programmer, "select_target", lambda *a, **k: pytest.fail("cable touched")
        )
        mp.setattr(
            programmer.subprocess, "run", lambda *a, **k: pytest.fail("vivado touched")
        )
        for bad_argv in (
            [
                "program_flash.py",
                "--boot-image",
                str(flash_256),
                "--fpga-image",
                str(bit_128),
                "--output-dir",
                str(tmp_path / "out_bit128"),
                "--prepare-only",
            ],
            [
                "program_flash.py",
                "--boot-image",
                str(flash_256),
                "--boot-only",
                "--vlen",
                "128",
                "--output-dir",
                str(tmp_path / "out_boot_v128_flag"),
                "--prepare-only",
            ],
            [
                "program_flash.py",
                "--boot-image",
                str(flash_256),
                "--fpga-image",
                str(bit_256),
                "--vlen",
                "512",
                "--output-dir",
                str(tmp_path / "out_fpga_v512_flag"),
                "--prepare-only",
            ],
            [
                "program_flash.py",
                "--boot-image",
                str(flash_128),
                "--boot-only",
                "--output-dir",
                str(tmp_path / "out_boot128_img"),
                "--prepare-only",
            ],
            [
                "program_flash.py",
                "--boot-image",
                str(flash_128),
                "--fpga-image",
                str(bit_no_sidecar),
                "--output-dir",
                str(tmp_path / "out_nosidecar_128"),
                "--prepare-only",
            ],
            [
                "program_flash.py",
                "--boot-image",
                str(flash_512),
                "--fpga-image",
                str(bit_no_sidecar),
                "--output-dir",
                str(tmp_path / "out_nosidecar_512"),
                "--prepare-only",
            ],
        ):
            mp.setattr(sys, "argv", bad_argv)
            with pytest.raises(SystemExit) as stopped:
                programmer.main()
            assert stopped.value.code == 2
            assert (
                "non-default VLENs are supported over JTAG loading only"
                in capsys.readouterr().err
            )

        # Mismatched scalar boot image vs VLEN-256 bitstream is also refused.
        mp.setattr(
            sys,
            "argv",
            [
                "program_flash.py",
                "--boot-image",
                str(flash_scalar),
                "--fpga-image",
                str(bit_256),
                "--output-dir",
                str(tmp_path / "out_scalar_mismatch"),
                "--prepare-only",
            ],
        )
        with pytest.raises(SystemExit) as stopped:
            programmer.main()
        assert stopped.value.code == 2
        assert "requires 'v'" in capsys.readouterr().err

        # Default VLEN-256 --boot-only and --fpga-image prepare succeed cleanly without touching hardware.
        for ok_argv in (
            [
                "program_flash.py",
                "--boot-image",
                str(flash_256),
                "--boot-only",
                "--output-dir",
                str(tmp_path / "out_boot256_ok"),
                "--prepare-only",
            ],
            [
                "program_flash.py",
                "--boot-image",
                str(flash_256),
                "--fpga-image",
                str(bit_256),
                "--vlen",
                "256",
                "--output-dir",
                str(tmp_path / "out_fpga256_ok"),
                "--prepare-only",
            ],
            [
                "program_flash.py",
                "--boot-image",
                str(flash_scalar),
                "--boot-only",
                "--output-dir",
                str(tmp_path / "out_boot_scalar_ok"),
                "--prepare-only",
            ],
            [
                "program_flash.py",
                "--boot-image",
                str(flash_256),
                "--fpga-image",
                str(bit_no_sidecar),
                "--output-dir",
                str(tmp_path / "out_nosidecar_256_ok"),
                "--prepare-only",
            ],
            [
                "program_flash.py",
                "--boot-image",
                str(flash_scalar),
                "--fpga-image",
                str(bit_no_sidecar),
                "--output-dir",
                str(tmp_path / "out_nosidecar_scalar_ok"),
                "--prepare-only",
            ],
        ):
            prep_calls: list[list[str]] = []
            mp.setattr(
                programmer.subprocess, "run", lambda cmd, **k: prep_calls.append(cmd)
            )
            mp.setattr(sys, "argv", ok_argv)
            programmer.main()
            assert len(prep_calls) == 1 and prep_calls[0][-4] == "prepare"

    # Damaged DTB partition FRST headers (bad magic or bad version) are refused
    # before Vivado both with and without --vlen.
    bad_magic = tmp_path / "bad_magic.bin"
    raw_bad_magic = bytearray(flash_256.read_bytes())
    raw_bad_magic[dtb_off : dtb_off + 4] = b"NOPE"
    bad_magic.write_bytes(raw_bad_magic)

    bad_version = tmp_path / "bad_version.bin"
    raw_bad_ver = bytearray(flash_256.read_bytes())
    raw_bad_ver[dtb_off + 4 : dtb_off + 8] = struct.pack("<I", 99)
    bad_version.write_bytes(raw_bad_ver)

    with monkeypatch.context() as mp:
        mp.setattr(
            programmer, "select_target", lambda *a, **k: pytest.fail("cable touched")
        )
        mp.setattr(
            programmer.subprocess, "run", lambda *a, **k: pytest.fail("vivado touched")
        )
        for bad_boot in (bad_magic, bad_version):
            for bad_argv in (
                [
                    "program_flash.py",
                    "--boot-image",
                    str(bad_boot),
                    "--fpga-image",
                    str(bit_no_sidecar),
                    "--output-dir",
                    str(tmp_path / "out_damaged_fpga"),
                    "--prepare-only",
                ],
                [
                    "program_flash.py",
                    "--boot-image",
                    str(bad_boot),
                    "--boot-only",
                    "--output-dir",
                    str(tmp_path / "out_damaged_bootonly"),
                    "--prepare-only",
                ],
                [
                    "program_flash.py",
                    "--boot-image",
                    str(bad_boot),
                    "--boot-only",
                    "--vlen",
                    "256",
                    "--output-dir",
                    str(tmp_path / "out_damaged_bootonly_v256"),
                    "--prepare-only",
                ],
                [
                    "program_flash.py",
                    "--boot-image",
                    str(bad_boot),
                    "--fpga-image",
                    str(bit_no_sidecar),
                    "--vlen",
                    "256",
                    "--output-dir",
                    str(tmp_path / "out_damaged_fpga_v256"),
                    "--prepare-only",
                ],
            ):
                mp.setattr(sys, "argv", bad_argv)
                with pytest.raises(SystemExit) as stopped:
                    programmer.main()
                assert stopped.value.code == 2
                assert "invalid FRST header" in capsys.readouterr().err
