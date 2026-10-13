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

"""RVFI-DII wire format, as TestRIG's QuickCheckVEngine and Sail speak it.

A verification engine (the client) sends 8-byte instruction packets; an
implementation (the server) answers with one execution-trace packet per
instruction, and a halt packet for each end-of-trace command. The formats are
TestRIG's RVFI-DII.md and the version-2 trace of sail-riscv's
model/core/rvfi_dii*.sail. Every field is little-endian.

Version negotiation: the engine sends an end-of-trace command whose
instruction word is 'VERS'. A server that supports version-2 traces answers
with a version-1 halt packet whose halt field is 3, the engine sends a 'v'
command with the requested version, and the server acknowledges with
"version=" and a 64-bit version number.
"""

import socket
import struct
from dataclasses import dataclass

# DII commands (instruction packet byte 6).
CMD_END_OF_TRACE = 0
CMD_INSTRUCTION = 1
CMD_SET_VERSION = ord("v")

# 'VERS' in an end-of-trace command asks for the supported trace version.
VERSION_QUERY_WORD = 0x56455253

DII_PACKET_BYTES = 8
V1_PACKET_BYTES = 88
V2_HEADER_BYTES = 64
V2_INT_DATA_BYTES = 40
V2_MEM_DATA_BYTES = 88

# Privilege encodings of the rvfi_mode field.
MODE_USER = 0
MODE_SUPERVISOR = 1
MODE_MACHINE = 3
# rvfi_ixl: 2 means XLEN 64.
IXL_64 = 2


@dataclass(frozen=True)
class DiiPacket:
    """One instruction-trace packet."""

    insn: int
    time: int
    cmd: int

    @classmethod
    def decode(cls, data: bytes) -> "DiiPacket":
        """Decode 8 bytes: insn (u32), time (u16), cmd (u8), padding (u8)."""
        insn, time, cmd, _padding = struct.unpack("<IHBB", data)
        return cls(insn=insn, time=time, cmd=cmd)

    def encode(self) -> bytes:
        """Encode to the 8-byte wire form."""
        return struct.pack("<IHBB", self.insn & 0xFFFF_FFFF, self.time, self.cmd, 0)

    @property
    def is_version_query(self) -> bool:
        """Whether this is the end-of-trace command that asks for the version."""
        return self.cmd == CMD_END_OF_TRACE and self.insn == VERSION_QUERY_WORD


@dataclass
class RvfiRecord:
    """One retired or trapped instruction, or a halt token (halt=1)."""

    order: int = 0
    insn: int = 0
    trap: int = 0
    halt: int = 0
    intr: int = 0
    mode: int = MODE_MACHINE
    ixl: int = IXL_64
    pc_rdata: int = 0
    pc_wdata: int = 0
    rd_addr: int = 0
    rd_wdata: int = 0
    rs1_addr: int = 0
    rs1_rdata: int = 0
    rs2_addr: int = 0
    rs2_rdata: int = 0
    mem_addr: int = 0
    mem_rmask: int = 0
    mem_wmask: int = 0
    mem_rdata: int = 0
    mem_wdata: int = 0

    @classmethod
    def halt_token(cls) -> "RvfiRecord":
        """Return the packet that answers an end-of-trace command."""
        return cls(halt=1, mode=0, ixl=0)

    def encode_v2(self) -> bytes:
        """Encode as a version-2 trace: header, int-data and mem-data blocks.

        Like Sail, a halt token carries only the header. The int-data block is
        present for every instruction (rd_addr 0 when nothing is written), and
        the mem-data block whenever a mask or address is set.
        """
        features = 0
        extensions = b""
        if not self.halt:
            features |= 1
            extensions += b"int-data" + struct.pack(
                "<QQQBBB5x",
                self.rd_wdata & _MASK64,
                self.rs1_rdata & _MASK64,
                self.rs2_rdata & _MASK64,
                self.rd_addr,
                self.rs1_addr,
                self.rs2_addr,
            )
            if self.mem_rmask or self.mem_wmask or self.mem_addr:
                features |= 2
                extensions += b"mem-data" + struct.pack(
                    "<4Q4QIIQ",
                    self.mem_rdata & _MASK64,
                    0,
                    0,
                    0,
                    self.mem_wdata & _MASK64,
                    0,
                    0,
                    0,
                    self.mem_rmask,
                    self.mem_wmask,
                    self.mem_addr & _MASK64,
                )
        header = b"trace-v2" + struct.pack(
            "<QQQ6B2xQQQ",
            V2_HEADER_BYTES + len(extensions),
            self.order & _MASK64,
            self.insn & _MASK64,
            self.trap,
            self.halt,
            self.intr,
            self.mode,
            self.ixl,
            0 if self.halt else 1,
            self.pc_rdata & _MASK64,
            self.pc_wdata & _MASK64,
            features,
        )
        return header + extensions

    def encode_v1(self) -> bytes:
        """Encode as an 88-byte version-1 packet."""
        return struct.pack(
            "<10Q8B",
            self.order & _MASK64,
            self.pc_rdata & _MASK64,
            self.pc_wdata & _MASK64,
            self.insn & _MASK64,
            self.rs1_rdata & _MASK64,
            self.rs2_rdata & _MASK64,
            self.rd_wdata & _MASK64,
            self.mem_addr & _MASK64,
            self.mem_rdata & _MASK64,
            self.mem_wdata & _MASK64,
            self.mem_rmask & 0xFF,
            self.mem_wmask & 0xFF,
            self.rs1_addr,
            self.rs2_addr,
            self.rd_addr,
            self.trap,
            self.halt,
            self.intr,
        )


_MASK64 = (1 << 64) - 1


def version_query_response() -> bytes:
    """Return the version-1 halt packet that advertises version-2 traces."""
    return RvfiRecord(halt=3, mode=0, ixl=0).encode_v1()


def version_ack(version: int) -> bytes:
    """Return the acknowledgement of a set-version command."""
    return b"version=" + struct.pack("<Q", version)


def decode_v2(stream: "PacketReader") -> RvfiRecord:
    """Read one version-2 trace packet (header plus its extension blocks)."""
    header = stream.read(V2_HEADER_BYTES)
    if header[:8] != b"trace-v2":
        raise ValueError(f"bad trace-v2 magic {header[:8]!r}")
    (
        size,
        order,
        insn,
        trap,
        halt,
        intr,
        mode,
        ixl,
        _valid,
        pc_rdata,
        pc_wdata,
        features,
    ) = struct.unpack("<QQQ6B2xQQQ", header[8:])
    record = RvfiRecord(
        order=order,
        insn=insn,
        trap=trap,
        halt=halt,
        intr=intr,
        mode=mode,
        ixl=ixl,
        pc_rdata=pc_rdata,
        pc_wdata=pc_wdata,
    )
    consumed = V2_HEADER_BYTES
    if features & 1:
        block = stream.read(V2_INT_DATA_BYTES)
        if block[:8] != b"int-data":
            raise ValueError(f"bad int-data magic {block[:8]!r}")
        (
            record.rd_wdata,
            record.rs1_rdata,
            record.rs2_rdata,
            record.rd_addr,
            record.rs1_addr,
            record.rs2_addr,
        ) = struct.unpack("<QQQBBB5x", block[8:])
        consumed += V2_INT_DATA_BYTES
    if features & 2:
        block = stream.read(V2_MEM_DATA_BYTES)
        if block[:8] != b"mem-data":
            raise ValueError(f"bad mem-data magic {block[:8]!r}")
        fields = struct.unpack("<4Q4QIIQ", block[8:])
        record.mem_rdata = fields[0]
        record.mem_wdata = fields[4]
        record.mem_rmask = fields[8]
        record.mem_wmask = fields[9]
        record.mem_addr = fields[10]
        consumed += V2_MEM_DATA_BYTES
    if features & ~3:
        raise ValueError(f"unsupported trace-v2 feature bits {features:#x}")
    if consumed != size:
        raise ValueError(f"trace-v2 size {size} but {consumed} bytes decoded")
    return record


class PacketReader:
    """Blocking reads of exact byte counts from a socket."""

    def __init__(self, sock: socket.socket) -> None:
        """Wrap a connected socket."""
        self._sock = sock

    def read(self, count: int) -> bytes:
        """Return exactly count bytes, or raise EOFError when the peer closes."""
        data = bytearray()
        while len(data) < count:
            chunk = self._sock.recv(count - len(data))
            if not chunk:
                raise EOFError("RVFI-DII peer closed the connection")
            data += chunk
        return bytes(data)
