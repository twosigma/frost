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
  Offset 0x0000_0000 .. 0x0270_0000: FPGA Bitstream (vcu118_frost.bit)
  Offset 0x0300_0000 (Rel +0x000000): FSBL       (load 0x0000_4000, entry 0x0000_4000)
  Offset 0x0310_0000 (Rel +0x100000): OpenSBI    (load 0x8000_0000, entry 0x8000_0000)
  Offset 0x0320_0000 (Rel +0x200000): DTB        (load 0x8220_0000, entry 0x8220_0000)
  Offset 0x0330_0000 (Rel +0x300000): U-Boot     (load 0x8020_0000, entry 0x8020_0000)
"""

import argparse
from pathlib import Path
import struct
import sys
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
        "default_file": "linux/build-mmu/images/fw_jump.bin",
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


def make_header(
    load_addr: int, entry_addr: int, payload_len: int, crc32: int, flags: int = 0
) -> bytes:
    """Encode the boot-stage image header."""
    return struct.pack(
        "<IIIIIIII",
        IMAGE_MAGIC_FROST,
        IMAGE_VERSION,
        load_addr & 0xFFFFFFFF,
        payload_len & 0xFFFFFFFF,
        crc32 & 0xFFFFFFFF,
        entry_addr & 0xFFFFFFFF,
        flags & 0xFFFFFFFF,
        0,  # reserved
    )


def build_flash_image(repo_root: Path, output_path: Path):
    """Pack the stage payloads at their flash offsets."""
    # Total image size spans from 0x0100_0000 to end of U-Boot (~0x0138_0000 -> 4 MiB buffer)
    max_offset = (
        max(p["flash_abs_offset"] for p in PARTITIONS) - FLASH_BASE_OFFSET + 0x0010_0000
    )
    image_buf = bytearray([0xFF] * max_offset)

    print(f"Building SPI flash image (base offset 0x{FLASH_BASE_OFFSET:08X})...")
    for part in PARTITIONS:
        file_path = repo_root / part["default_file"]
        if not file_path.is_file():
            print(
                f"ERROR: Component {part['name']} not found at {file_path}",
                file=sys.stderr,
            )
            sys.exit(1)

        payload = file_path.read_bytes()
        crc = zlib.crc32(payload) & 0xFFFFFFFF
        hdr = make_header(part["load_addr"], part["entry_addr"], len(payload), crc)

        rel_offset = part["flash_abs_offset"] - FLASH_BASE_OFFSET
        part_end = rel_offset + HEADER_SIZE + len(payload)

        if part_end > len(image_buf):
            # Extend buffer
            image_buf.extend([0xFF] * (part_end - len(image_buf)))

        image_buf[rel_offset : rel_offset + HEADER_SIZE] = hdr
        image_buf[rel_offset + HEADER_SIZE : part_end] = payload

        print(
            f"  [{part['name']:7s}] Abs: 0x{part['flash_abs_offset']:08X} (rel +0x{rel_offset:06X}) | "
            f"Load: 0x{part['load_addr']:08X} | Size: {len(payload):7d} B | CRC: 0x{crc:08X}"
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(image_buf)
    print(
        f"\nSuccessfully created flash image: {output_path} ({len(image_buf)} bytes / {len(image_buf) / 1024 / 1024:.2f} MiB)"
    )
    print("To program to VCU118 SPI NOR Flash:")
    print(
        f"  openFPGALoader -c digilent_hs2 --fpga-part xcvu9p-flga2104 --write-flash --offset 0x{FLASH_BASE_OFFSET:08X} {output_path}"
    )


def main():
    """Build the image selected by command-line options."""
    repo_root = Path(__file__).resolve().parent.parent.parent
    parser = argparse.ArgumentParser(
        description="Build VCU118 SPI NOR Flash Boot Image"
    )
    parser.add_argument(
        "-o",
        "--output",
        default="/tmp/frost_flash.bin",
        type=Path,
        help="Output binary file path (default: /tmp/frost_flash.bin)",
    )
    args = parser.parse_args()

    build_flash_image(repo_root, args.output)


if __name__ == "__main__":
    main()
