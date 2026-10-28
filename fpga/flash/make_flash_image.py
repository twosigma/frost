#!/usr/bin/env python3
#    Copyright 2026 John Goodacre
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

"""Pack multi-stage boot components into a single SPI NOR flash image for VCU118.

SPI Flash Layout:
  Offsets below 0x0300_0000: FPGA configuration image
  Offset 0x0300_0000 (Rel +0x000000): FSBL       (load 0x0000_4000, entry 0x0000_4000)
  Offset 0x0310_0000 (Rel +0x100000): OpenSBI    (load 0x8000_0000, entry 0x8000_0000)
  Offset 0x0320_0000 (Rel +0x200000): DTB        (load 0x8220_0000, entry 0x8220_0000)
  Offset 0x0330_0000 (Rel +0x300000): U-Boot     (load 0x8020_0000, entry 0x8020_0000)
"""

import argparse
from pathlib import Path
import struct
import zlib

IMAGE_MAGIC_FROST = 0x54535246  # "FRST"
IMAGE_VERSION = 1
HEADER_SIZE = 32

FLASH_BASE_OFFSET = 0x0300_0000

PARTITIONS = [
    {
        "name": "FSBL",
        "flash_abs_offset": 0x0300_0000,
        "load_addr": 0x0000_4000,
        "entry_addr": 0x0000_4000,
        "default_file": "sw/apps/fsbl/sw.bin",
    },
    {
        "name": "OpenSBI",
        "flash_abs_offset": 0x0310_0000,
        "load_addr": 0x8000_0000,
        "entry_addr": 0x8000_0000,
        "default_file": "sw/uboot/build/opensbi/platform/generic/firmware/fw_jump.bin",
    },
    {
        "name": "DTB",
        "flash_abs_offset": 0x0320_0000,
        "load_addr": 0x8220_0000,
        "entry_addr": 0x8220_0000,
        "default_file": "boards/vcu118/frost.dtb",
    },
    {
        "name": "U-Boot",
        "flash_abs_offset": 0x0330_0000,
        "load_addr": 0x8020_0000,
        "entry_addr": 0x8020_0000,
        "default_file": "sw/uboot/u-boot.bin",
    },
]


def make_header(load_addr: int, entry_addr: int, payload_len: int, crc32: int) -> bytes:
    """Encode the fixed boot-stage image header."""
    return struct.pack(
        "<8I",
        IMAGE_MAGIC_FROST,
        IMAGE_VERSION,
        load_addr,
        payload_len,
        crc32,
        entry_addr,
        0,
        0,
    )


def build_flash_image(
    repo_root: Path, output_path: Path, components: dict[str, Path] | None = None
) -> None:
    """Pack validated payloads into four nonoverlapping flash partitions."""
    image = bytearray(b"\xff" * 0x400000)
    for part in PARTITIONS:
        name = str(part["name"])
        source = (components or {}).get(name, repo_root / str(part["default_file"]))
        payload = source.read_bytes()
        capacity = {"FSBL": 0x13C00, "DTB": 0x20000}.get(name, 0x100000 - HEADER_SIZE)
        if not 0 < len(payload) <= capacity:
            raise ValueError(f"{name}: payload must contain 1..{capacity} bytes")
        if name == "DTB":
            if len(payload) < 40 or payload[:4] != b"\xd0\x0d\xfe\xed":
                raise ValueError("DTB: expected a flattened device tree")
            if int.from_bytes(payload[4:8], "big") != len(payload):
                raise ValueError("DTB: total size does not match the payload")
        header = make_header(
            int(part["load_addr"]),
            int(part["entry_addr"]),
            len(payload),
            zlib.crc32(payload),
        )
        offset = int(part["flash_abs_offset"]) - FLASH_BASE_OFFSET
        image[offset : offset + HEADER_SIZE + len(payload)] = header + payload
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(image)


def main() -> None:
    """Build a boot image from the selected component files."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--output", required=True, type=Path)
    parser.add_argument("--fsbl", type=Path)
    parser.add_argument("--opensbi", type=Path)
    parser.add_argument("--dtb", type=Path)
    parser.add_argument("--uboot", type=Path)
    args = parser.parse_args()
    components = {
        name: path
        for name, path in (
            ("FSBL", args.fsbl),
            ("OpenSBI", args.opensbi),
            ("DTB", args.dtb),
            ("U-Boot", args.uboot),
        )
        if path is not None
    }
    try:
        build_flash_image(Path(__file__).resolve().parents[2], args.output, components)
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
