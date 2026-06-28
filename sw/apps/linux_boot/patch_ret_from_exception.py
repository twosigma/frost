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

"""Patch the temporary Linux bring-up image for current bring-up hazards.

The external linux-mvp tree currently builds a debug kernel whose
ret_from_exception sequence contains:

    lw   a2, PT_EPC(sp)
    sc.w zero, a2, (sp)
    csrw mstatus, a0
    csrw mepc, a2
    ...
    mret

If the restored mstatus image has MIE set, the timer can preempt between the
CSR write and MRET (an M-mode restore-window race). The trap then saves mepc at
the MRET instruction itself, which later returns into MRET as user code and
produces SIGILL at ret_from_exception+0x76. (The U-mode variant of that race is
fixed in hardware -- cpu_ooo.sv seeds interrupt_resume_pc from csr_mepc on
mret_taken -- but the M-mode restore-window variant is not yet, so this software
crutch is still required: without it the unpatched kernel hangs at the CLINT
clocksource switch once the periodic timer tick ramps up.)

For bring-up, replace the reservation-clear SC with `andi a0, a0, -9`, clearing
MIE in the value written to mstatus.  MRET still restores the final
interrupt-enable state from MPIE, but the restore window is not interruptible.

The target instruction is located by its unique machine-code word
(`18c1202f`) rather than a fixed offset, so the patch survives kernel rebuilds
that shift ret_from_exception. If the word is absent the image is assumed
already patched (idempotent); if it occurs more than once the patch aborts
rather than risk hitting the wrong site.

Set FROST_LINUX_BOOTARGS to rewrite /chosen/bootargs in the generated DTB. This
is useful for hardware-only boot triage such as forcing initramfs_async=0 without
modifying the external linux-mvp artifact generator.

Set FROST_LINUX_NOOP_FUNCTIONS to rewrite selected kernel functions to
`li a0,0; ret` in the generated DDR images. This is a hardware bring-up escape
hatch for narrow isolation runs; do not use it for correctness testing.

Set FROST_LINUX_BUSYBOX to replace bin/busybox in the generated initramfs.
This is a bring-up hook for testing BFLT header changes without rebuilding the
external Buildroot tree.
"""

from __future__ import annotations

import argparse
import gzip
import os
import shutil
import stat
import struct
import subprocess
import tempfile
from pathlib import Path


OLD_WORD = "18c1202f"  # sc.w zero, a2, (sp) -- ret_from_exception reservation clear
NEW_WORD = "ff757513"  # andi a0, a0, -9    -- clear mstatus.MIE in the restore value

DTB_WORD = 0x200000
INITRD_WORD = 0x204000
KERNEL_ENTRY = 0x80000000
FDT_MAGIC = 0xD00DFEED
CPIO_NEWC_MAGIC = b"070701"
CPIO_TRAILER = "TRAILER!!!"
NOOP_INITCALL_PATCH = b"\x01\x45\x82\x80"  # c.li a0,0; c.ret
CPU_RELAX_DIV_SYMBOL = "__delay"
CPU_RELAX_DIV_OFFSET = 0x1C
CPU_RELAX_DIV_OLD = b"\xb3\xc7\x07\x02"  # div a5,a5,zero
CPU_RELAX_DIV_NEW = b"\x13\x00\x00\x00"  # nop
CPU_RELAX_PAUSE_OFFSET = 0x20
CPU_RELAX_PAUSE_OLD = b"\x0f\x00\x00\x01"  # pause / fence hint
CPU_RELAX_PAUSE_NEW = b"\x13\x00\x00\x00"  # nop
PROC_GET_INODE_MODE_RELOAD_OLD = b"\x83\xd7\x04\x00"  # lhu a5,0(s1)
PROC_GET_INODE_MODE_RELOAD_NEW = b"\x83\x57\x09\x06"  # lhu a5,96(s2)
PROC_GET_INODE_MODE_RELOAD_ADDRS = (0x001071B2, 0x00107220)
PROC_GET_INODE_MODE_LOAD_ADDR = 0x0010718C
PROC_GET_INODE_MODE_LOAD_OLD = b"\x83\x57\x09\x06"  # lhu a5,96(s2)
PROC_GET_INODE_MODE_FORCE_REG = b"\xb7\x87\x00\x00"  # lui a5,0x8 (S_IFREG)
PROC_LOOKUP_REF_AMO_ADDR = 0x0010BC82
PROC_LOOKUP_REF_AMO_OLD = b"\x2f\x27\xb5\x00"  # amoadd.w a4,a1,(a0)
PROC_LOOKUP_REF_AMO_CONST = b"\x13\x07\x10\x00"  # addi a4,zero,1
PROC_LOOKUP_DE_ADJUST_ADDR = 0x0010BC7C
PROC_LOOKUP_DE_ADJUST_OLD = b"\xaa\x87\x85\x45"  # mv a5,a0; li a1,1
PROC_LOOKUP_DE_ADJUST_NEW = b"\x93\x07\x05\xfb"  # addi a5,a0,-80
DEFAULT_SYSTEM_MAP = Path(
    os.path.expanduser(
        "~/bigger_l0/linux-mvp/buildroot/output/build/linux-6.18.7/System.map"
    )
)
INITRD_DEVICES = {
    "dev/console": (stat.S_IFCHR | 0o600, 5, 1),
    "dev/null": (stat.S_IFCHR | 0o666, 1, 3),
    "dev/random": (stat.S_IFCHR | 0o666, 1, 8),
    "dev/ttyS0": (stat.S_IFCHR | 0o600, 4, 64),
    "dev/urandom": (stat.S_IFCHR | 0o666, 1, 9),
}
DIAG_SHELL_INITTAB = """\
console::sysinit:/bin/echo FROST_DIAG_INITTAB_START
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -o remount,rw /
::sysinit:/bin/mkdir -p /dev/pts /dev/shm /run/lock/subsys /tmp /sys
::sysinit:/bin/mount -a
console::sysinit:/bin/echo FROST_DIAG_INITTAB_AFTER_RCS
console::respawn:/bin/sh
::shutdown:/bin/umount -a -r
"""
SEEDRNG_NOOP = """\
#!/bin/sh
# FPGA bring-up has no hardware entropy source; seedrng can block PID 1 forever.
exit 0
"""


def patch_ret_restore_window(path: Path) -> None:
    """Patch the single OLD_WORD occurrence to NEW_WORD.

    Works for both the dense FPGA-loader form (one word per line) and the
    $readmemh form (skips '@<addr>' directives and blank lines).
    """
    lines = path.read_text().splitlines()
    old_hits = []
    new_hits = 0
    for i, line in enumerate(lines):
        s = line.strip().lower()
        if not s or s.startswith("@"):
            continue
        if s == OLD_WORD:
            old_hits.append(i)
        elif s == NEW_WORD:
            new_hits += 1
    if not old_hits:
        if new_hits:
            return  # already patched
        raise SystemExit(
            f"{path}: target word {OLD_WORD} not found (and not already patched)"
        )
    if len(old_hits) > 1:
        raise SystemExit(
            f"{path}: {OLD_WORD} occurs {len(old_hits)}x; ambiguous, refusing to patch"
        )
    lines[old_hits[0]] = NEW_WORD
    path.write_text("\n".join(lines) + "\n")


def split_env_names(value: str) -> list[str]:
    """Parse value (space/comma-separated) into a deduplicated ordered list of names."""
    names: list[str] = []
    seen: set[str] = set()
    for raw_name in value.replace(",", " ").split():
        name = raw_name.strip()
        if not name or name in seen:
            continue
        names.append(name)
        seen.add(name)
    return names


def resolve_system_map_symbols(system_map: Path, names: list[str]) -> dict[str, int]:
    """Look up symbol names to byte addresses in a Linux System.map file."""
    if not names:
        return {}
    if not system_map.exists():
        raise SystemExit(f"System.map not found: {system_map}")

    wanted = set(names)
    resolved: dict[str, int] = {}
    for line in system_map.read_text().splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        addr, _kind, symbol = parts[:3]
        if symbol in wanted:
            resolved[symbol] = int(addr, 16)

    missing = [name for name in names if name not in resolved]
    if missing:
        raise SystemExit(f"{system_map}: missing symbol(s): " + " ".join(missing))
    return resolved


def patch_word_byte(word: str, byte_offset: int, value: int) -> str:
    """Patch one byte within a little-endian 4-byte hex word string and return the new word."""
    data = bytearray(struct.pack("<I", int(word, 16)))
    data[byte_offset] = value
    return f"{struct.unpack('<I', data)[0]:08x}"


def patch_dense_code_bytes(path: Path, patches: dict[int, bytes]) -> None:
    """Apply byte-level patches to a dense (one-word-per-line) hex image file."""
    words = [
        line.strip().lower() for line in path.read_text().splitlines() if line.strip()
    ]
    for byte_addr, patch in patches.items():
        for byte_idx, value in enumerate(patch):
            absolute_byte = byte_addr + byte_idx
            word_idx = absolute_byte // 4
            byte_offset = absolute_byte % 4
            if word_idx >= len(words):
                raise SystemExit(
                    f"{path}: patch address 0x{absolute_byte:x} is outside dense image"
                )
            words[word_idx] = patch_word_byte(words[word_idx], byte_offset, value)
    path.write_text("\n".join(words) + "\n")


def patch_sparse_code_bytes(path: Path, patches: dict[int, bytes]) -> None:
    """Apply byte-level patches to a sparse (@addr-directive) hex image file."""
    lines = path.read_text().splitlines()
    word_line_by_addr: dict[int, int] = {}
    current_word_addr = 0
    for idx, line in enumerate(lines):
        stripped = line.strip().lower()
        if not stripped:
            continue
        if stripped.startswith("@"):
            current_word_addr = int(stripped[1:], 16)
            continue
        word_line_by_addr[current_word_addr] = idx
        current_word_addr += 1

    for byte_addr, patch in patches.items():
        for byte_idx, value in enumerate(patch):
            absolute_byte = byte_addr + byte_idx
            word_addr = absolute_byte // 4
            byte_offset = absolute_byte % 4
            line_idx = word_line_by_addr.get(word_addr)
            if line_idx is None:
                raise SystemExit(
                    f"{path}: patch address 0x{absolute_byte:x} is outside sparse image"
                )
            lines[line_idx] = patch_word_byte(
                lines[line_idx].strip().lower(), byte_offset, value
            )
    path.write_text("\n".join(lines) + "\n")


def patch_code_bytes(path: Path, patches: dict[int, bytes]) -> None:
    """Dispatch to dense or sparse patcher based on image format and apply patches."""
    if not patches:
        return
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("@"):
            patch_sparse_code_bytes(path, patches)
        else:
            patch_dense_code_bytes(path, patches)
        return
    raise SystemExit(f"{path}: empty Linux DDR image")


def patch_noop_return_zero(path: Path, symbols: dict[str, int]) -> None:
    """Patch each symbol address with the NOOP_INITCALL_PATCH byte sequence."""
    patch_code_bytes(path, {addr: NOOP_INITCALL_PATCH for addr in symbols.values()})


def read_dense_code_bytes(path: Path, byte_addr: int, size: int) -> bytes:
    """Read size bytes at byte_addr from a dense hex image file."""
    words = [
        line.strip().lower() for line in path.read_text().splitlines() if line.strip()
    ]
    data = bytearray()
    for byte_idx in range(size):
        absolute_byte = byte_addr + byte_idx
        word_idx = absolute_byte // 4
        byte_offset = absolute_byte % 4
        if word_idx >= len(words):
            raise SystemExit(
                f"{path}: read address 0x{absolute_byte:x} is outside dense image"
            )
        data.append(struct.pack("<I", int(words[word_idx], 16))[byte_offset])
    return bytes(data)


def read_sparse_code_bytes(path: Path, byte_addr: int, size: int) -> bytes:
    """Read size bytes at byte_addr from a sparse (@addr-directive) hex image file."""
    lines = path.read_text().splitlines()
    word_by_addr: dict[int, str] = {}
    current_word_addr = 0
    for line in lines:
        stripped = line.strip().lower()
        if not stripped:
            continue
        if stripped.startswith("@"):
            current_word_addr = int(stripped[1:], 16)
            continue
        word_by_addr[current_word_addr] = stripped
        current_word_addr += 1

    data = bytearray()
    for byte_idx in range(size):
        absolute_byte = byte_addr + byte_idx
        word_addr = absolute_byte // 4
        byte_offset = absolute_byte % 4
        word = word_by_addr.get(word_addr)
        if word is None:
            raise SystemExit(
                f"{path}: read address 0x{absolute_byte:x} is outside sparse image"
            )
        data.append(struct.pack("<I", int(word, 16))[byte_offset])
    return bytes(data)


def read_code_bytes(path: Path, byte_addr: int, size: int) -> bytes:
    """Dispatch to dense or sparse reader based on image format."""
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("@"):
            return read_sparse_code_bytes(path, byte_addr, size)
        return read_dense_code_bytes(path, byte_addr, size)
    raise SystemExit(f"{path}: empty Linux DDR image")


def patch_cpu_relax_div(path: Path, delay_addr: int) -> None:
    """Patch the div-by-zero instruction inside cpu_relax (__delay+0x1C) to a NOP."""
    patch_addr = delay_addr + CPU_RELAX_DIV_OFFSET
    current = read_code_bytes(path, patch_addr, len(CPU_RELAX_DIV_OLD))
    if current not in (CPU_RELAX_DIV_OLD, CPU_RELAX_DIV_NEW):
        raise SystemExit(
            f"{path}: {CPU_RELAX_DIV_SYMBOL}+0x{CPU_RELAX_DIV_OFFSET:x} "
            f"at 0x{patch_addr:08x} has {current.hex()}, expected "
            f"{CPU_RELAX_DIV_OLD.hex()}"
        )
    patch_code_bytes(path, {patch_addr: CPU_RELAX_DIV_NEW})


def patch_cpu_relax_pause(path: Path, delay_addr: int) -> None:
    """Patch the pause fence hint inside cpu_relax (__delay+0x20) to a NOP."""
    patch_addr = delay_addr + CPU_RELAX_PAUSE_OFFSET
    current = read_code_bytes(path, patch_addr, len(CPU_RELAX_PAUSE_OLD))
    if current not in (CPU_RELAX_PAUSE_OLD, CPU_RELAX_PAUSE_NEW):
        raise SystemExit(
            f"{path}: {CPU_RELAX_DIV_SYMBOL}+0x{CPU_RELAX_PAUSE_OFFSET:x} "
            f"at 0x{patch_addr:08x} has {current.hex()}, expected "
            f"{CPU_RELAX_PAUSE_OLD.hex()}"
        )
    patch_code_bytes(path, {patch_addr: CPU_RELAX_PAUSE_NEW})


def patch_proc_get_inode_mode_reload(path: Path) -> None:
    """Patch all proc_get_inode mode-reload instructions to the new encoding."""
    patches: dict[int, bytes] = {}
    for addr in PROC_GET_INODE_MODE_RELOAD_ADDRS:
        current = read_code_bytes(path, addr, len(PROC_GET_INODE_MODE_RELOAD_OLD))
        if current not in (
            PROC_GET_INODE_MODE_RELOAD_OLD,
            PROC_GET_INODE_MODE_RELOAD_NEW,
        ):
            raise SystemExit(
                f"{path}: proc_get_inode mode reload at 0x{addr:08x} "
                f"has {current.hex()}, expected {PROC_GET_INODE_MODE_RELOAD_OLD.hex()}"
            )
        patches[addr] = PROC_GET_INODE_MODE_RELOAD_NEW
    patch_code_bytes(path, patches)


def patch_proc_get_inode_force_mode_reg(path: Path) -> None:
    """Patch proc_get_inode to force the mode load through a register."""
    current = read_code_bytes(
        path, PROC_GET_INODE_MODE_LOAD_ADDR, len(PROC_GET_INODE_MODE_LOAD_OLD)
    )
    if current not in (PROC_GET_INODE_MODE_LOAD_OLD, PROC_GET_INODE_MODE_FORCE_REG):
        raise SystemExit(
            f"{path}: proc_get_inode mode load at 0x{PROC_GET_INODE_MODE_LOAD_ADDR:08x} "
            f"has {current.hex()}, expected {PROC_GET_INODE_MODE_LOAD_OLD.hex()}"
        )
    patch_code_bytes(
        path, {PROC_GET_INODE_MODE_LOAD_ADDR: PROC_GET_INODE_MODE_FORCE_REG}
    )


def patch_proc_lookup_ref_const(path: Path) -> None:
    """Replace the proc_lookup_de refcount AMO with a constant-store encoding."""
    current = read_code_bytes(
        path, PROC_LOOKUP_REF_AMO_ADDR, len(PROC_LOOKUP_REF_AMO_OLD)
    )
    if current not in (PROC_LOOKUP_REF_AMO_OLD, PROC_LOOKUP_REF_AMO_CONST):
        raise SystemExit(
            f"{path}: proc_lookup_de refcount AMO at 0x{PROC_LOOKUP_REF_AMO_ADDR:08x} "
            f"has {current.hex()}, expected {PROC_LOOKUP_REF_AMO_OLD.hex()}"
        )
    patch_code_bytes(path, {PROC_LOOKUP_REF_AMO_ADDR: PROC_LOOKUP_REF_AMO_CONST})


def patch_proc_lookup_de_adjust(path: Path) -> None:
    """Patch the proc_lookup_de returned-de pointer-adjustment instruction."""
    current = read_code_bytes(
        path, PROC_LOOKUP_DE_ADJUST_ADDR, len(PROC_LOOKUP_DE_ADJUST_OLD)
    )
    if current not in (PROC_LOOKUP_DE_ADJUST_OLD, PROC_LOOKUP_DE_ADJUST_NEW):
        raise SystemExit(
            f"{path}: proc_lookup_de returned-de adjust at "
            f"0x{PROC_LOOKUP_DE_ADJUST_ADDR:08x} has {current.hex()}, expected "
            f"{PROC_LOOKUP_DE_ADJUST_OLD.hex()}"
        )
    patch_code_bytes(path, {PROC_LOOKUP_DE_ADJUST_ADDR: PROC_LOOKUP_DE_ADJUST_NEW})


def words_to_bytes(words: list[str]) -> bytes:
    """Pack a list of little-endian 8-hex-digit word strings into bytes."""
    return b"".join(struct.pack("<I", int(word, 16)) for word in words)


def bytes_to_words(data: bytes) -> list[str]:
    """Unpack bytes into a list of little-endian 8-hex-digit word strings."""
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)
    return [
        f"{struct.unpack_from('<I', data, i)[0]:08x}" for i in range(0, len(data), 4)
    ]


def fdt_total_size(data: bytes) -> int:
    """Return the total_size field from a FDT blob after validating the magic."""
    if len(data) < 8:
        raise SystemExit("DTB slot is too small to contain an FDT header")
    magic, total_size = struct.unpack_from(">II", data, 0)
    if magic != FDT_MAGIC:
        raise SystemExit(
            f"DTB magic mismatch: got 0x{magic:08x}, expected 0x{FDT_MAGIC:08x}"
        )
    if total_size > len(data):
        raise SystemExit(
            f"DTB total size {total_size} exceeds extracted slot {len(data)}"
        )
    return total_size


def padded_dtb_slot(words: list[str]) -> bytes:
    """Extract and zero-pad a DTB from a word list to its declared total_size."""
    data = words_to_bytes(words)
    if len(data) < 8:
        raise SystemExit("DTB slot is too small to contain an FDT header")
    magic, total_size = struct.unpack_from(">II", data, 0)
    if magic != FDT_MAGIC:
        raise SystemExit(
            f"DTB magic mismatch: got 0x{magic:08x}, expected 0x{FDT_MAGIC:08x}"
        )
    if total_size > len(data):
        data += b"\x00" * (total_size - len(data))
    return data


def fdt_tool(name: str) -> str:
    """Locate an FDT command-line tool on PATH or raise SystemExit if absent."""
    tool = shutil.which(name)
    if not tool:
        raise SystemExit(f"{name} is required in PATH")
    return tool


def run_fdtget_u32(dtb_path: Path, prop: str) -> int:
    """Read a single hex /chosen property from a DTB file using fdtget."""
    result = subprocess.run(
        [fdt_tool("fdtget"), "-t", "x", str(dtb_path), "/chosen", prop],
        check=True,
        capture_output=True,
        text=True,
    )
    words = result.stdout.split()
    if len(words) != 1:
        raise SystemExit(f"{dtb_path}: expected one {prop} cell, got {result.stdout!r}")
    return int(words[0], 16)


def rewrite_dtb(dtb_slot: bytes, bootargs: str | None, initrd_end: int | None) -> bytes:
    """Rewrite bootargs and linux,initrd-end in a DTB blob using fdtput."""
    fdtput = shutil.which("fdtput")
    if not fdtput:
        raise SystemExit("DTB rewriting requires fdtput in PATH")

    total_size = fdt_total_size(dtb_slot)
    old_dtb = dtb_slot[:total_size]
    with tempfile.TemporaryDirectory(prefix="frost_dtb_") as tmp:
        dtb_path = Path(tmp) / "frost.dtb"
        dtb_path.write_bytes(old_dtb)
        if bootargs is not None:
            subprocess.run(
                [fdtput, "-t", "s", str(dtb_path), "/chosen", "bootargs", bootargs],
                check=True,
            )
        if initrd_end is not None:
            subprocess.run(
                [
                    fdtput,
                    "-t",
                    "x",
                    str(dtb_path),
                    "/chosen",
                    "linux,initrd-end",
                    f"0x{initrd_end:08x}",
                ],
                check=True,
            )
        serial_irq_mode = os.environ.get("FROST_LINUX_SERIAL_IRQ_MODE", "poll")
        if serial_irq_mode == "poll":
            subprocess.run(
                [
                    fdtput,
                    "-d",
                    str(dtb_path),
                    "/soc/serial@40001000",
                    "interrupts-extended",
                ],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        elif serial_irq_mode == "cpu-local-meip":
            subprocess.run(
                [
                    fdtput,
                    "-t",
                    "x",
                    str(dtb_path),
                    "/soc/serial@40001000",
                    "interrupts-extended",
                    "0x00000001",
                    "0x0000000b",
                ],
                check=True,
            )
        else:
            raise SystemExit(f"unknown FROST_LINUX_SERIAL_IRQ_MODE={serial_irq_mode!r}")
        new_dtb = dtb_path.read_bytes()

    if len(new_dtb) > (INITRD_WORD - DTB_WORD) * 4:
        raise SystemExit(
            f"patched DTB is {len(new_dtb)} bytes; only "
            f"{(INITRD_WORD - DTB_WORD) * 4} bytes available before initrd"
        )
    return new_dtb


def get_initrd_bounds(dtb_slot: bytes) -> tuple[int, int]:
    """Read the initrd start and end byte addresses from a DTB blob using fdtget."""
    total_size = fdt_total_size(dtb_slot)
    with tempfile.TemporaryDirectory(prefix="frost_dtb_") as tmp:
        dtb_path = Path(tmp) / "frost.dtb"
        dtb_path.write_bytes(dtb_slot[:total_size])
        start = run_fdtget_u32(dtb_path, "linux,initrd-start")
        end = run_fdtget_u32(dtb_path, "linux,initrd-end")
    if end < start:
        raise SystemExit(f"invalid initrd bounds: start=0x{start:08x}, end=0x{end:08x}")
    if start < KERNEL_ENTRY or (start - KERNEL_ENTRY) % 4:
        raise SystemExit(f"unsupported initrd start: 0x{start:08x}")
    return start, end


def newc_pad(n: int) -> int:
    """Return the number of padding bytes to reach the next 4-byte CPIO alignment boundary."""
    return (-n) & 3


def parse_newc_entry(data: bytes, offset: int) -> tuple[str, list[int], int, int, int]:
    """Parse one CPIO newc entry, returning name, fields, body_start, next_offset, and file_size."""
    if offset + 110 > len(data) or data[offset : offset + 6] != CPIO_NEWC_MAGIC:
        raise SystemExit(f"initramfs is not a valid newc archive at byte {offset}")
    fields = [
        int(data[offset + 6 + idx * 8 : offset + 14 + idx * 8], 16) for idx in range(13)
    ]
    file_size = fields[6]
    name_size = fields[11]
    name_start = offset + 110
    name_end = name_start + name_size
    if name_end > len(data):
        raise SystemExit(f"initramfs newc entry at byte {offset} has truncated name")
    name = data[name_start : name_end - 1].decode("utf-8")
    body_start = name_end + newc_pad(name_end)
    next_offset = body_start + file_size + newc_pad(body_start + file_size)
    if next_offset > len(data):
        raise SystemExit(f"initramfs newc entry {name!r} at byte {offset} is truncated")
    return name, fields, body_start, next_offset, file_size


def find_newc_trailer(data: bytes) -> tuple[int, set[str]]:
    """Scan a CPIO newc archive for the TRAILER entry and return its offset and all filenames seen."""
    offset = 0
    names: set[str] = set()
    while offset < len(data):
        name, _fields, _body_start, next_offset, _file_size = parse_newc_entry(
            data, offset
        )
        names.add(name)
        if name == CPIO_TRAILER:
            return offset, names
        offset = next_offset
    raise SystemExit("initramfs newc archive has no TRAILER!!! entry")


def make_newc_entry(
    name: str,
    mode: int,
    rdev_major: int,
    rdev_minor: int,
    ino: int,
    data: bytes = b"",
    uid: int = 0,
    gid: int = 0,
    nlink: int = 1,
    mtime: int = 0,
    dev_major: int = 0,
    dev_minor: int = 0,
) -> bytes:
    """Build a complete CPIO newc archive entry from name, mode, device numbers, and data."""
    encoded_name = name.encode("utf-8") + b"\x00"
    fields = [
        ino,
        mode,
        uid,
        gid,
        nlink,
        mtime,
        len(data),
        dev_major,
        dev_minor,
        rdev_major,
        rdev_minor,
        len(encoded_name),
        0,  # check
    ]
    header = CPIO_NEWC_MAGIC + b"".join(
        f"{field:08x}".encode("ascii") for field in fields
    )
    name_block = (
        header + encoded_name + (b"\x00" * newc_pad(len(header) + len(encoded_name)))
    )
    return name_block + data + (b"\x00" * newc_pad(len(name_block) + len(data)))


def make_newc_replacement_entry(name: str, fields: list[int], data: bytes) -> bytes:
    """Rebuild a CPIO newc entry preserving the original metadata with new data."""
    return make_newc_entry(
        name,
        fields[1],
        fields[9],
        fields[10],
        fields[0],
        data=data,
        uid=fields[2],
        gid=fields[3],
        nlink=fields[4],
        mtime=fields[5],
        dev_major=fields[7],
        dev_minor=fields[8],
    )


def patch_initramfs(
    initrd_gz: bytes,
    replacements: dict[str, bytes],
    additions: dict[str, tuple[int, bytes]],
    deletions: set[str],
) -> tuple[bytes, list[str], list[str], list[str], list[str]]:
    """Patch, add, and delete entries in a gzip-compressed CPIO initramfs."""
    conflicts = (set(replacements) | set(additions)) & deletions
    if conflicts:
        raise SystemExit(
            "initramfs paths cannot be both patched/added and deleted: "
            + " ".join(sorted(conflicts))
        )

    initrd = gzip.decompress(initrd_gz)
    trailer_offset, names = find_newc_trailer(initrd)
    missing = [name for name in INITRD_DEVICES if name not in names]
    existing_additions = set(additions) & names

    if not missing and not replacements and not additions and not deletions:
        return initrd_gz, [], [], [], []

    patched_entries: list[bytes] = []
    replaced: list[str] = []
    deleted: list[str] = []
    offset = 0
    while offset < trailer_offset:
        name, fields, body_start, next_offset, file_size = parse_newc_entry(
            initrd, offset
        )
        if name in deletions:
            deleted.append(name)
        elif name in replacements:
            patched_entries.append(
                make_newc_replacement_entry(name, fields, replacements[name])
            )
            replaced.append(name)
        elif name in existing_additions:
            _mode, data = additions[name]
            patched_entries.append(make_newc_replacement_entry(name, fields, data))
            replaced.append(name)
        else:
            patched_entries.append(initrd[offset:next_offset])
        offset = next_offset

    for idx, name in enumerate(missing, start=0xF005700):
        mode, major, minor = INITRD_DEVICES[name]
        patched_entries.append(make_newc_entry(name, mode, major, minor, idx))
    added_files: list[str] = []
    for idx, (name, (mode, data)) in enumerate(additions.items(), start=0xF006700):
        if name in names:
            continue
        patched_entries.append(make_newc_entry(name, mode, 0, 0, idx, data=data))
        added_files.append(name)
    trailer = make_newc_entry(CPIO_TRAILER, 0, 0, 0, 0)
    patched = b"".join(patched_entries) + trailer

    missing_replacements = sorted(set(replacements) - set(replaced))
    if missing_replacements:
        raise SystemExit(
            "initramfs replacement target(s) not found: "
            + " ".join(missing_replacements)
        )
    missing_deletions = sorted(deletions - set(deleted))
    if missing_deletions:
        raise SystemExit(
            "initramfs deletion target(s) not found: " + " ".join(missing_deletions)
        )
    return gzip.compress(patched, mtime=0), missing, replaced, added_files, deleted


def get_initramfs_replacements() -> dict[str, bytes]:
    """Build the initramfs file-replacement map from FROST_LINUX_* environment variables."""
    replacements = {
        "etc/init.d/S01seedrng": SEEDRNG_NOOP.encode("utf-8"),
    }
    busybox_replacement = os.environ.get("FROST_LINUX_BUSYBOX")
    if busybox_replacement:
        replacements["bin/busybox"] = Path(busybox_replacement).read_bytes()
    preset = os.environ.get("FROST_LINUX_INITTAB_PRESET")
    raw_inittab = os.environ.get("FROST_LINUX_INITTAB")
    if raw_inittab and preset:
        raise SystemExit(
            "set either FROST_LINUX_INITTAB or FROST_LINUX_INITTAB_PRESET, not both"
        )
    if preset == "diag-shell":
        replacements["etc/inittab"] = DIAG_SHELL_INITTAB.encode("utf-8")
        return replacements
    if preset:
        raise SystemExit(f"unknown FROST_LINUX_INITTAB_PRESET={preset!r}")
    if raw_inittab:
        replacements["etc/inittab"] = raw_inittab.replace("\\n", "\n").encode("utf-8")
    return replacements


def get_initramfs_additions() -> dict[str, tuple[int, bytes]]:
    """Build the initramfs file-addition map from FROST_LINUX_* environment variables."""
    additions: dict[str, tuple[int, bytes]] = {}
    diag_init = os.environ.get("FROST_LINUX_DIAG_INIT")
    if diag_init:
        additions["frost_diag_init"] = (
            stat.S_IFREG | 0o755,
            Path(diag_init).read_bytes(),
        )
    return additions


def get_initramfs_deletions() -> set[str]:
    """Build the set of initramfs paths to delete from FROST_LINUX_* environment variables."""
    deletions = set(
        split_env_names(os.environ.get("FROST_LINUX_DELETE_INITRAMFS_NAMES", ""))
    )
    if os.environ.get("FROST_LINUX_DELETE_INITTAB") == "1":
        deletions.add("etc/inittab")
    return deletions


def patch_dense_image(
    path: Path,
    bootargs: str | None,
    initramfs_replacements: dict[str, bytes],
    initramfs_additions: dict[str, tuple[int, bytes]],
    initramfs_deletions: set[str],
) -> tuple[list[str], list[str], list[str], list[str]]:
    """Patch DTB and initramfs embedded in a dense Linux DDR hex image."""
    words = [
        line.strip().lower() for line in path.read_text().splitlines() if line.strip()
    ]
    if len(words) < INITRD_WORD:
        raise SystemExit(f"{path}: dense DDR image is too short for DTB/initrd slots")

    dtb_slot_words = words[DTB_WORD:INITRD_WORD]
    dtb_slot = words_to_bytes(dtb_slot_words)
    initrd_start, initrd_end = get_initrd_bounds(dtb_slot)
    initrd_word = (initrd_start - KERNEL_ENTRY) // 4
    if initrd_word != INITRD_WORD:
        raise SystemExit(f"{path}: unexpected initrd word offset 0x{initrd_word:x}")
    initrd_size = initrd_end - initrd_start
    initrd_word_count = (initrd_size + 3) // 4
    initrd_gz = words_to_bytes(words[INITRD_WORD : INITRD_WORD + initrd_word_count])[
        :initrd_size
    ]
    new_initrd_gz, added_devices, replaced_files, added_files, deleted_files = (
        patch_initramfs(
            initrd_gz, initramfs_replacements, initramfs_additions, initramfs_deletions
        )
    )
    new_initrd_end = initrd_start + len(new_initrd_gz)

    new_dtb_words = bytes_to_words(rewrite_dtb(dtb_slot, bootargs, new_initrd_end))
    if DTB_WORD + len(new_dtb_words) > INITRD_WORD:
        raise SystemExit(f"{path}: patched DTB overlaps initrd")
    new_initrd_words = bytes_to_words(new_initrd_gz)

    words[DTB_WORD : DTB_WORD + len(new_dtb_words)] = new_dtb_words
    for i in range(DTB_WORD + len(new_dtb_words), INITRD_WORD):
        words[i] = "00000000"
    words[INITRD_WORD:] = new_initrd_words
    path.write_text("\n".join(words) + "\n")
    return added_devices, replaced_files, added_files, deleted_files


def patch_sparse_image(
    path: Path,
    bootargs: str | None,
    initramfs_replacements: dict[str, bytes],
    initramfs_additions: dict[str, tuple[int, bytes]],
    initramfs_deletions: set[str],
) -> tuple[list[str], list[str], list[str], list[str]]:
    """Patch DTB and initramfs embedded in a sparse Linux DDR hex image."""

    def is_gzip_first_word(word: str) -> bool:
        try:
            return (int(word, 16) & 0x00FF_FFFF) == 0x0008_8B1F
        except ValueError:
            return False

    lines = path.read_text().splitlines()
    dtb_directive = f"@{DTB_WORD:08x}"
    initrd_directive = f"@{INITRD_WORD:08x}"
    try:
        dtb_line = next(
            i for i, line in enumerate(lines) if line.strip().lower() == dtb_directive
        )
    except StopIteration as exc:
        raise SystemExit(f"{path}: missing DTB address directive") from exc
    initrd_line = next(
        (i for i, line in enumerate(lines) if line.strip().lower() == initrd_directive),
        None,
    )
    if initrd_line is not None and initrd_line <= dtb_line:
        raise SystemExit(f"{path}: initrd directive appears before DTB directive")

    dtb_slot_words = INITRD_WORD - DTB_WORD
    sparse_payload_initrd_word = dtb_slot_words
    if initrd_line is None:
        payload_words = [
            line.strip().lower() for line in lines[dtb_line + 1 :] if line.strip()
        ]
        if len(payload_words) > dtb_slot_words and is_gzip_first_word(
            payload_words[dtb_slot_words]
        ):
            sparse_payload_initrd_word = dtb_slot_words
            dtb_words = payload_words[:dtb_slot_words]
        else:
            gzip_word = next(
                (
                    idx
                    for idx, word in enumerate(payload_words)
                    if is_gzip_first_word(word)
                ),
                None,
            )
            if gzip_word is None:
                raise SystemExit(
                    f"{path}: missing initrd directive and gzip initrd header"
                )
            sparse_payload_initrd_word = gzip_word
            dtb_words = payload_words[:gzip_word]
        initrd_words = payload_words[sparse_payload_initrd_word:]
    else:
        dtb_words = [
            line.strip().lower()
            for line in lines[dtb_line + 1 : initrd_line]
            if line.strip()
        ]
        initrd_words = [
            line.strip().lower() for line in lines[initrd_line + 1 :] if line.strip()
        ]
    dtb_slot = padded_dtb_slot(dtb_words)
    initrd_start, initrd_end = get_initrd_bounds(dtb_slot)
    initrd_word = (initrd_start - KERNEL_ENTRY) // 4
    if initrd_word != INITRD_WORD:
        raise SystemExit(f"{path}: unexpected initrd word offset 0x{initrd_word:x}")
    initrd_size = initrd_end - initrd_start
    initrd_gz = words_to_bytes(initrd_words)[:initrd_size]
    new_initrd_gz, added_devices, replaced_files, added_files, deleted_files = (
        patch_initramfs(
            initrd_gz, initramfs_replacements, initramfs_additions, initramfs_deletions
        )
    )
    new_initrd_end = initrd_start + len(new_initrd_gz)

    new_dtb_words = bytes_to_words(rewrite_dtb(dtb_slot, bootargs, new_initrd_end))
    if DTB_WORD + len(new_dtb_words) > INITRD_WORD:
        raise SystemExit(f"{path}: patched DTB overlaps initrd")
    new_initrd_words = bytes_to_words(new_initrd_gz)

    lines[dtb_line + 1 :] = new_dtb_words + [initrd_directive] + new_initrd_words
    path.write_text("\n".join(lines) + "\n")
    return added_devices, replaced_files, added_files, deleted_files


def patch_linux_image(
    path: Path,
    bootargs: str | None,
    initramfs_replacements: dict[str, bytes],
    initramfs_additions: dict[str, tuple[int, bytes]],
    initramfs_deletions: set[str],
) -> tuple[list[str], list[str], list[str], list[str]]:
    """Patch a Linux DDR image, dispatching to dense or sparse handler by format."""
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("@"):
            return patch_sparse_image(
                path,
                bootargs,
                initramfs_replacements,
                initramfs_additions,
                initramfs_deletions,
            )
        return patch_dense_image(
            path,
            bootargs,
            initramfs_replacements,
            initramfs_additions,
            initramfs_deletions,
        )
    raise SystemExit(f"{path}: empty Linux DDR image")


def main() -> None:
    """Entry point: patches the Linux DDR image with all FROST boot patches."""
    parser = argparse.ArgumentParser()
    parser.add_argument("sw_ddr_mem", type=Path)
    parser.add_argument("sw_ddr_txt", type=Path)
    args = parser.parse_args()

    patch_ret_restore_window(args.sw_ddr_mem)
    patch_ret_restore_window(args.sw_ddr_txt)
    print(f"Patched Linux ret_from_exception restore window: {OLD_WORD}->{NEW_WORD}")

    noop_initcall_names = split_env_names(
        os.environ.get("FROST_LINUX_NOOP_INITCALLS", "")
    )
    noop_function_names = split_env_names(
        os.environ.get("FROST_LINUX_NOOP_FUNCTIONS", "")
    )
    system_map = Path(
        os.environ.get("FROST_LINUX_SYSTEM_MAP", DEFAULT_SYSTEM_MAP)
    ).expanduser()
    noop_initcall_symbols = resolve_system_map_symbols(system_map, noop_initcall_names)
    patch_noop_return_zero(args.sw_ddr_mem, noop_initcall_symbols)
    patch_noop_return_zero(args.sw_ddr_txt, noop_initcall_symbols)
    if noop_initcall_symbols:
        patched = " ".join(
            f"{name}@0x{noop_initcall_symbols[name]:08x}"
            for name in noop_initcall_names
        )
        print(f"Patched Linux initcalls to return 0: {patched}")

    noop_function_symbols = resolve_system_map_symbols(system_map, noop_function_names)
    patch_noop_return_zero(args.sw_ddr_mem, noop_function_symbols)
    patch_noop_return_zero(args.sw_ddr_txt, noop_function_symbols)
    if noop_function_symbols:
        patched = " ".join(
            f"{name}@0x{noop_function_symbols[name]:08x}"
            for name in noop_function_names
        )
        print(f"Patched Linux functions to return 0: {patched}")

    if os.environ.get("FROST_LINUX_NOP_CPU_RELAX_DIV") == "1":
        delay_addr = resolve_system_map_symbols(system_map, [CPU_RELAX_DIV_SYMBOL])[
            CPU_RELAX_DIV_SYMBOL
        ]
        patch_cpu_relax_div(args.sw_ddr_mem, delay_addr)
        patch_cpu_relax_div(args.sw_ddr_txt, delay_addr)
        print(
            f"Patched Linux {CPU_RELAX_DIV_SYMBOL} cpu_relax DIV-by-zero to NOP: "
            f"{CPU_RELAX_DIV_SYMBOL}+0x{CPU_RELAX_DIV_OFFSET:x}@"
            f"0x{delay_addr + CPU_RELAX_DIV_OFFSET:08x}"
        )

    if os.environ.get("FROST_LINUX_NOP_CPU_RELAX_PAUSE") == "1":
        delay_addr = resolve_system_map_symbols(system_map, [CPU_RELAX_DIV_SYMBOL])[
            CPU_RELAX_DIV_SYMBOL
        ]
        patch_cpu_relax_pause(args.sw_ddr_mem, delay_addr)
        patch_cpu_relax_pause(args.sw_ddr_txt, delay_addr)
        print(
            f"Patched Linux {CPU_RELAX_DIV_SYMBOL} cpu_relax PAUSE to NOP: "
            f"{CPU_RELAX_DIV_SYMBOL}+0x{CPU_RELAX_PAUSE_OFFSET:x}@"
            f"0x{delay_addr + CPU_RELAX_PAUSE_OFFSET:08x}"
        )

    if os.environ.get("FROST_LINUX_PATCH_PROC_GET_INODE_MODE_RELOAD") == "1":
        patch_proc_get_inode_mode_reload(args.sw_ddr_mem)
        patch_proc_get_inode_mode_reload(args.sw_ddr_txt)
        print(
            "Patched Linux proc_get_inode mode reload: "
            f"{','.join(f'0x{addr:08x}' for addr in PROC_GET_INODE_MODE_RELOAD_ADDRS)} "
            f"{PROC_GET_INODE_MODE_RELOAD_OLD.hex()}->"
            f"{PROC_GET_INODE_MODE_RELOAD_NEW.hex()}"
        )

    if os.environ.get("FROST_LINUX_FORCE_PROC_GET_INODE_MODE_REG") == "1":
        patch_proc_get_inode_force_mode_reg(args.sw_ddr_mem)
        patch_proc_get_inode_force_mode_reg(args.sw_ddr_txt)
        print(
            "Patched Linux proc_get_inode mode load to S_IFREG: "
            f"0x{PROC_GET_INODE_MODE_LOAD_ADDR:08x} "
            f"{PROC_GET_INODE_MODE_LOAD_OLD.hex()}->"
            f"{PROC_GET_INODE_MODE_FORCE_REG.hex()}"
        )

    if os.environ.get("FROST_LINUX_PATCH_PROC_LOOKUP_REF_CONST") == "1":
        patch_proc_lookup_ref_const(args.sw_ddr_mem)
        patch_proc_lookup_ref_const(args.sw_ddr_txt)
        print(
            "Patched Linux proc_lookup_de refcount AMO result to 1: "
            f"0x{PROC_LOOKUP_REF_AMO_ADDR:08x} "
            f"{PROC_LOOKUP_REF_AMO_OLD.hex()}->"
            f"{PROC_LOOKUP_REF_AMO_CONST.hex()}"
        )

    if os.environ.get("FROST_LINUX_PATCH_PROC_LOOKUP_DE_ADJUST") == "1":
        patch_proc_lookup_de_adjust(args.sw_ddr_mem)
        patch_proc_lookup_de_adjust(args.sw_ddr_txt)
        print(
            "Patched Linux proc_lookup_de returned pointer adjust: "
            f"0x{PROC_LOOKUP_DE_ADJUST_ADDR:08x} "
            f"{PROC_LOOKUP_DE_ADJUST_OLD.hex()}->"
            f"{PROC_LOOKUP_DE_ADJUST_NEW.hex()}"
        )

    bootargs = os.environ.get("FROST_LINUX_BOOTARGS")
    initramfs_replacements = get_initramfs_replacements()
    initramfs_additions = get_initramfs_additions()
    initramfs_deletions = get_initramfs_deletions()
    sparse_devices, sparse_replaced, sparse_added, sparse_deleted = patch_linux_image(
        args.sw_ddr_mem,
        bootargs,
        initramfs_replacements,
        initramfs_additions,
        initramfs_deletions,
    )
    dense_devices, dense_replaced, dense_added, dense_deleted = patch_linux_image(
        args.sw_ddr_txt,
        bootargs,
        initramfs_replacements,
        initramfs_additions,
        initramfs_deletions,
    )
    if bootargs:
        print(f"Patched Linux DTB bootargs: {bootargs}")
    added_devices = sorted(set(sparse_devices) | set(dense_devices))
    if added_devices:
        print(f"Patched Linux initramfs device nodes: {' '.join(added_devices)}")
    replaced_files = sorted(set(sparse_replaced) | set(dense_replaced))
    if replaced_files:
        print(f"Patched Linux initramfs files: {' '.join(replaced_files)}")
    added_files = sorted(set(sparse_added) | set(dense_added))
    if added_files:
        print(f"Patched Linux initramfs added files: {' '.join(added_files)}")
    deleted_files = sorted(set(sparse_deleted) | set(dense_deleted))
    if deleted_files:
        print(f"Patched Linux initramfs deleted files: {' '.join(deleted_files)}")


if __name__ == "__main__":
    main()
