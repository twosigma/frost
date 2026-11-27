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

"""Shared VCU118 bitstream metadata and FDT vector-ISA verification helpers."""

from __future__ import annotations

from collections.abc import Mapping
import hashlib
import json
from pathlib import Path
import re
import struct
from typing import Any

VCU118_VECTOR_VLENS = (128, 256, 512)
VCU118_DEFAULT_VECTOR_VLEN = 256
VCU118_NETLIST_CONFIG_NAME = "vcu118_netlist_config.json"
VCU118_PROGRAMMED_METADATA_NAME = "programmed_bitstream.json"
VCU118_BITSTREAM_SCHEMA = "vcu118_bitstream_v1"
VCU118_BITSTREAM_UNKNOWN_SCHEMA = "vcu118_bitstream_unknown_v1"
VCU118_NETLIST_SCHEMA = "vcu118_netlist_config_v1"

_ZVL_EXT_RE = re.compile(r"^zvl(\d+)b$")
_SHA256_HEX_RE = re.compile(r"^[0-9a-f]{64}$")
_FDT_MAGIC = 0xD00DFEED


def file_sha256(path: Path) -> str:
    """Return the lowercase SHA-256 hex digest of ``path``."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def bitstream_metadata_path(bitstream: Path) -> Path:
    """Return the JSON metadata sidecar path next to ``bitstream``."""
    return bitstream.parent / f"{bitstream.name}.json"


def validate_vcu118_metadata(
    data: object, *, expected_schemas: tuple[str, ...]
) -> dict[str, Any]:
    """Validate and normalize a VCU118 netlist or bitstream metadata record."""
    if not isinstance(data, Mapping):
        raise ValueError("VCU118 metadata must be a JSON object")
    schema = data.get("schema")
    if schema not in expected_schemas:
        raise ValueError(
            f"unexpected VCU118 metadata schema {schema!r}; expected {expected_schemas}"
        )
    if data.get("board") != "vcu118":
        raise ValueError(f"VCU118 metadata has wrong board {data.get('board')!r}")
    if schema in (VCU118_BITSTREAM_SCHEMA, VCU118_BITSTREAM_UNKNOWN_SCHEMA):
        sha = data.get("bitstream_sha256")
        if not isinstance(sha, str) or _SHA256_HEX_RE.fullmatch(sha) is None:
            raise ValueError(
                f"VCU118 bitstream metadata requires a 64-hex bitstream_sha256, got {sha!r}"
            )
    if schema == VCU118_BITSTREAM_UNKNOWN_SCHEMA:
        return dict(data)
    vector = data.get("vector")
    if not isinstance(vector, bool):
        raise ValueError(f"VCU118 metadata has non-boolean vector {vector!r}")
    vlen = data.get("vlen")
    if not isinstance(vlen, int) or isinstance(vlen, bool):
        raise ValueError(f"VCU118 metadata has non-integer vlen {vlen!r}")
    if vector:
        if vlen not in VCU118_VECTOR_VLENS:
            raise ValueError(
                f"VCU118 vector metadata must have vlen in {VCU118_VECTOR_VLENS}, got {vlen}"
            )
    elif vlen != 0:
        raise ValueError(f"VCU118 scalar metadata must have vlen=0, got {vlen}")
    return dict(data)


def read_vcu118_netlist_config(work_dir: Path) -> dict[str, Any] | None:
    """Read ``vcu118_netlist_config.json`` from ``work_dir``, or return None."""
    path = work_dir / VCU118_NETLIST_CONFIG_NAME
    if not path.is_file():
        return None
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ValueError(f"invalid VCU118 netlist config {path}: {exc}") from exc
    return validate_vcu118_metadata(raw, expected_schemas=(VCU118_NETLIST_SCHEMA,))


def write_vcu118_netlist_config(
    work_dir: Path,
    *,
    vector: bool,
    vlen: int,
    cpu_clock_hz: int,
    misaligned_hw: bool,
) -> Path:
    """Persist VCU118 synthesis-time vector and clock settings in ``work_dir``."""
    work_dir.mkdir(parents=True, exist_ok=True)
    record = validate_vcu118_metadata(
        {
            "schema": VCU118_NETLIST_SCHEMA,
            "board": "vcu118",
            "vector": vector,
            "vlen": vlen if vector else 0,
            "cpu_clock_hz": cpu_clock_hz,
            "misaligned_hw": misaligned_hw,
        },
        expected_schemas=(VCU118_NETLIST_SCHEMA,),
    )
    path = work_dir / VCU118_NETLIST_CONFIG_NAME
    path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return path


def write_vcu118_bitstream_metadata(
    bitstream: Path,
    *,
    vector: bool,
    vlen: int,
    cpu_clock_hz: int,
) -> Path:
    """Write ``<bitstream>.json`` beside a generated VCU118 bitstream."""
    digest = file_sha256(bitstream)
    record = validate_vcu118_metadata(
        {
            "schema": VCU118_BITSTREAM_SCHEMA,
            "board": "vcu118",
            "bitstream": bitstream.name,
            "bitstream_sha256": digest,
            "vector": vector,
            "vlen": vlen if vector else 0,
            "cpu_clock_hz": cpu_clock_hz,
        },
        expected_schemas=(VCU118_BITSTREAM_SCHEMA,),
    )
    sidecar = bitstream_metadata_path(bitstream)
    sidecar.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return sidecar


def read_bitstream_sidecar(bitstream: Path) -> dict[str, Any] | None:
    """Read and verify ``<bitstream>.json`` (tied to ``bitstream`` SHA-256), or None."""
    sidecar = bitstream_metadata_path(bitstream)
    if not sidecar.is_file():
        return None
    try:
        raw = json.loads(sidecar.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ValueError(f"invalid bitstream metadata {sidecar}: {exc}") from exc
    record = validate_vcu118_metadata(raw, expected_schemas=(VCU118_BITSTREAM_SCHEMA,))
    expected_digest = record["bitstream_sha256"]
    if not bitstream.is_file():
        raise ValueError(
            f"bitstream metadata {sidecar} has no matching bitstream {bitstream}"
        )
    actual_digest = file_sha256(bitstream)
    if actual_digest != expected_digest:
        raise ValueError(
            f"bitstream {bitstream} SHA-256 ({actual_digest[:12]}) does not "
            f"match its metadata {sidecar} ({expected_digest[:12]})"
        )
    return record


def _record_board_bitstream_state(state_path: Path, bitstream: Path) -> Path:
    """Persist metadata for ``bitstream`` (or an unknown-metadata marker) at ``state_path``."""
    actual_sha = file_sha256(bitstream)
    metadata = read_bitstream_sidecar(bitstream)
    if metadata is None:
        record = validate_vcu118_metadata(
            {
                "schema": VCU118_BITSTREAM_UNKNOWN_SCHEMA,
                "board": "vcu118",
                "bitstream": bitstream.name,
                "bitstream_path": str(bitstream.resolve()),
                "bitstream_sha256": actual_sha,
            },
            expected_schemas=(VCU118_BITSTREAM_UNKNOWN_SCHEMA,),
        )
    else:
        record = validate_vcu118_metadata(
            {
                "schema": VCU118_BITSTREAM_SCHEMA,
                "board": "vcu118",
                "bitstream": bitstream.name,
                "bitstream_path": str(bitstream.resolve()),
                "bitstream_sha256": actual_sha,
                "vector": metadata["vector"],
                "vlen": metadata["vlen"],
                "cpu_clock_hz": metadata.get("cpu_clock_hz"),
            },
            expected_schemas=(VCU118_BITSTREAM_SCHEMA,),
        )
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return state_path


def _read_board_bitstream_state(
    state_path: Path, *, work_bit: Path | None = None
) -> dict[str, Any] | None:
    """Read ``state_path`` (tied by SHA-256), falling back only to ``work_bit``'s verified sidecar."""
    if state_path.is_file():
        try:
            raw = json.loads(state_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise ValueError(
                f"invalid programmed bitstream metadata {state_path}: {exc}"
            ) from exc
        record = validate_vcu118_metadata(
            raw,
            expected_schemas=(
                VCU118_BITSTREAM_SCHEMA,
                VCU118_BITSTREAM_UNKNOWN_SCHEMA,
            ),
        )
        if record["schema"] == VCU118_BITSTREAM_UNKNOWN_SCHEMA:
            return None
        return record

    if work_bit is not None and work_bit.is_file():
        return read_bitstream_sidecar(work_bit)

    return None


def record_programmed_vcu118_bitstream(
    project_root: Path, bitstream: Path
) -> Path | None:
    """Record the programmed VCU118 bitstream's metadata under default work dir."""
    work_dir = project_root / "fpga" / "build" / "vcu118" / "work"
    return _record_board_bitstream_state(
        work_dir / VCU118_PROGRAMMED_METADATA_NAME, bitstream
    )


def read_vcu118_bitstream_metadata(project_root: Path) -> dict[str, Any] | None:
    """Return active VCU118 bitstream metadata in ``project_root``, or None."""
    work_dir = project_root / "fpga" / "build" / "vcu118" / "work"
    return _read_board_bitstream_state(
        work_dir / VCU118_PROGRAMMED_METADATA_NAME,
        work_bit=work_dir / "vcu118_frost.bit",
    )


def _split_riscv_isa_string(isa: str) -> list[str]:
    """Split a ``riscv,isa`` string into lowercase extension tokens."""
    text = isa.strip().lower()
    if not text:
        return []
    head, *multi = text.split("_")
    single: list[str] = []
    for prefix in ("rv64", "rv32", "rv128"):
        if head.startswith(prefix):
            single = list(head[len(prefix) :])
            break
    return [*single, *(tok for tok in multi if tok)]


def fdt_cpu_isa_info(blob: bytes) -> dict[str, Any]:
    """Parse ``/cpus/cpu*`` ISA properties from a compiled FDT blob."""
    if len(blob) < 40:
        raise ValueError("DTB is shorter than the 40-byte FDT header")
    (
        magic,
        totalsize,
        off_struct,
        off_strings,
        _off_mem_rsvmap,
        _version,
        _last_comp_version,
        _boot_cpuid_phys,
        size_strings,
        size_struct,
    ) = struct.unpack_from(">10I", blob, 0)
    if magic != _FDT_MAGIC:
        raise ValueError(f"invalid DTB magic 0x{magic:08x}")
    if totalsize != len(blob):
        raise ValueError(
            f"DTB totalsize {totalsize} does not match payload size {len(blob)}"
        )
    if off_struct + size_struct > totalsize or off_strings + size_strings > totalsize:
        raise ValueError("DTB section extends past totalsize")

    pos = off_struct
    end = off_struct + size_struct
    stack: list[str] = []
    isa_tokens: list[str] | None = None
    ext_tokens: list[str] | None = None
    while pos + 4 <= end:
        (tag,) = struct.unpack_from(">I", blob, pos)
        pos += 4
        if tag == 1:  # FDT_BEGIN_NODE
            nul = blob.find(b"\x00", pos, end)
            if nul < 0:
                raise ValueError("unterminated FDT node name")
            stack.append(blob[pos:nul].decode("ascii", errors="ignore"))
            pos = (nul + 4) & ~3
        elif tag == 2:  # FDT_END_NODE
            if stack:
                stack.pop()
        elif tag == 3:  # FDT_PROP
            if pos + 8 > end:
                raise ValueError("truncated FDT property")
            prop_len, nameoff = struct.unpack_from(">2I", blob, pos)
            pos += 8
            if pos + prop_len > end:
                raise ValueError("FDT property extends past struct block")
            val = blob[pos : pos + prop_len]
            pos = (pos + prop_len + 3) & ~3
            if len(stack) == 3 and stack[1] == "cpus" and stack[2].startswith("cpu"):
                str_end = blob.find(
                    b"\x00", off_strings + nameoff, off_strings + size_strings
                )
                if str_end < 0:
                    raise ValueError("unterminated FDT property name")
                pname = blob[off_strings + nameoff : str_end].decode(
                    "ascii", errors="ignore"
                )
                if pname == "riscv,isa":
                    isa_str = val.split(b"\x00", 1)[0].decode("ascii", errors="ignore")
                    isa_tokens = _split_riscv_isa_string(isa_str)
                elif pname == "riscv,isa-extensions":
                    ext_tokens = [
                        part.decode("ascii", errors="ignore").strip().lower()
                        for part in val.split(b"\x00")
                        if part
                    ]
        elif tag == 4:  # FDT_NOP
            continue
        elif tag == 9:  # FDT_END
            break
        else:
            raise ValueError(f"unknown FDT token 0x{tag:08x}")

    return {
        "has_cpu_isa": isa_tokens is not None or ext_tokens is not None,
        "isa_tokens": isa_tokens,
        "ext_tokens": ext_tokens,
    }


def _summarize_zvl_and_v(tokens: list[str]) -> tuple[bool, int | None]:
    """Return ``(has_v, max_zvl_bits)`` from a list of lowercase ISA tokens."""
    has_v = "v" in tokens
    zvl_bits: list[int] = []
    for tok in tokens:
        match = _ZVL_EXT_RE.fullmatch(tok)
        if match is not None:
            zvl_bits.append(int(match.group(1)))
    return has_v, (max(zvl_bits) if zvl_bits else None)


def verify_dtb_vector_config(
    blob: bytes,
    *,
    expected_vector: bool,
    expected_vlen: int,
    source: str,
    require_cpu_isa: bool = True,
) -> None:
    """Verify that a compiled DTB's V and Zvl*b match ``(expected_vector, expected_vlen)``."""
    try:
        info = fdt_cpu_isa_info(blob)
    except ValueError:
        if require_cpu_isa:
            raise
        return
    if not info["has_cpu_isa"]:
        if require_cpu_isa:
            raise ValueError(
                f"{source}: DTB /cpus/cpu@0 lacks riscv,isa and riscv,isa-extensions"
            )
        return

    token_sets = [
        (label, tokens)
        for label, tokens in (
            ("riscv,isa", info["isa_tokens"]),
            ("riscv,isa-extensions", info["ext_tokens"]),
        )
        if tokens is not None
    ]
    for label, tokens in token_sets:
        has_v, max_zvl = _summarize_zvl_and_v(tokens)
        if not expected_vector:
            if has_v or max_zvl is not None:
                raise ValueError(
                    f"{source}: scalar target cannot use a DTB advertising vector "
                    f"({label} has v={has_v}, max Zvl={max_zvl})"
                )
        else:
            if not has_v:
                raise ValueError(
                    f"{source}: vector target (VLEN {expected_vlen}) requires 'v' in {label}"
                )
            if max_zvl != expected_vlen:
                raise ValueError(
                    f"{source}: DTB {label} advertises VLEN {max_zvl}, "
                    f"expected VLEN {expected_vlen}"
                )


def _unpack_fdt_from_le_words(
    words: list[int], start_idx: int, source: Path, *, strict_truncated: bool = True
) -> bytes | None:
    """Unpack an FDT blob starting at little-endian word index ``start_idx``."""
    if start_idx + 10 > len(words):
        return None
    header = struct.pack("<2I", words[start_idx], words[start_idx + 1])
    magic, totalsize = struct.unpack(">2I", header)
    if magic != _FDT_MAGIC or totalsize < 40:
        return None
    word_count = (totalsize + 3) // 4
    if start_idx + word_count > len(words):
        if strict_truncated:
            raise ValueError(f"{source}: truncated packed DTB region")
        return None
    return b"".join(
        struct.pack("<I", w) for w in words[start_idx : start_idx + word_count]
    )[:totalsize]


def extract_dtb_from_sw_ddr_mem(mem_path: Path) -> bytes:
    """Extract the packed compiled DTB from a ``sw_ddr.mem`` Verilog hex image."""
    regions: list[list[int]] = []
    current: list[int] | None = None
    for raw_line in mem_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("@"):
            current = []
            regions.append(current)
            continue
        if current is None:
            raise ValueError(f"{mem_path}: data word before @address header")
        for token in line.split():
            current.append(int(token, 16))
    for words in regions:
        blob = _unpack_fdt_from_le_words(words, 0, mem_path)
        if blob is not None:
            return blob
    raise ValueError(f"{mem_path}: no packed FDT device tree found")


def extract_dtb_from_sw_ddr_txt(txt_path: Path) -> bytes:
    """Extract the packed compiled DTB from a flat ``sw_ddr.txt`` DDR word image."""
    raw_lines = [
        line.strip()
        for line in txt_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    # Check PMD boundaries (2 MiB = 0x80000 32-bit words) first, then full scan.
    pmd_words = 0x80000
    pmd_indices = [
        idx
        for idx in range(pmd_words, len(raw_lines), pmd_words)
        if raw_lines[idx].lower() == "edfe0dd0"
    ]
    scan_indices = pmd_indices or [
        idx for idx, tok in enumerate(raw_lines) if tok.lower() == "edfe0dd0"
    ]
    for idx in scan_indices:
        if idx + 10 > len(raw_lines):
            continue
        header_words = [int(raw_lines[idx], 16), int(raw_lines[idx + 1], 16)]
        magic, totalsize = struct.unpack(">2I", struct.pack("<2I", *header_words))
        if magic != _FDT_MAGIC or totalsize < 40:
            continue
        word_count = (totalsize + 3) // 4
        if idx + word_count > len(raw_lines):
            if idx in pmd_indices:
                raise ValueError(f"{txt_path}: truncated packed DTB region")
            continue
        words = [int(tok, 16) for tok in raw_lines[idx : idx + word_count]]
        blob = b"".join(struct.pack("<I", w) for w in words)[:totalsize]
        try:
            fdt_cpu_isa_info(blob)
        except ValueError:
            if idx in pmd_indices:
                raise
            continue
        return blob
    raise ValueError(f"{txt_path}: no packed FDT device tree found")


def extract_dtb_from_flash_image(flash_image: Path) -> bytes:
    """Extract the packed DTB payload from a 4 MiB VCU118 flash boot image."""
    data = flash_image.read_bytes()
    dtb_partition_offset = 0x200000
    header_size = 32
    if len(data) < dtb_partition_offset + header_size:
        raise ValueError(f"{flash_image}: too small for DTB flash partition")
    magic, version, _load, payload_len, _crc, _entry, _, _ = struct.unpack_from(
        "<8I", data, dtb_partition_offset
    )
    if magic != 0x54535246 or version != 1:
        raise ValueError(f"{flash_image}: invalid FRST header on DTB partition")
    start = dtb_partition_offset + header_size
    end = start + payload_len
    if payload_len < 40 or end > len(data):
        raise ValueError(f"{flash_image}: invalid DTB payload length {payload_len}")
    return data[start:end]
