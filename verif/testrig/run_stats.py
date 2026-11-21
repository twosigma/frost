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

"""Forward and count RVFI replies and normalize selected Sail replies."""

import queue
import socket
import struct
import threading
import time
from dataclasses import dataclass
from io import BytesIO

from testrig.rvfi_dii import (
    CMD_END_OF_TRACE,
    CMD_INSTRUCTION,
    CMD_SET_VERSION,
    DII_PACKET_BYTES,
    MODE_MACHINE,
    MODE_SUPERVISOR,
    MODE_USER,
    V1_PACKET_BYTES,
    V2_HEADER_BYTES,
    V2_INT_DATA_BYTES,
    V2_MEM_DATA_BYTES,
    WFI_INSN,
    DiiPacket,
    PacketReader,
    RvfiRecord,
    decode_v2,
    version_ack,
)


@dataclass(frozen=True)
class TraceCounts:
    """Instruction counts for one completed request and its execution trace."""

    requested: int
    received: int


def _read_v2(reader: PacketReader) -> bytes:
    """Read a bounded version-2 reply and preserve its wire representation."""
    raw = reader.read(V2_HEADER_BYTES)
    size = struct.unpack_from("<Q", raw, 8)[0]
    if raw[:8] != b"trace-v2" or not 64 <= size <= 192:
        raise ValueError("invalid trace-v2 header")
    return raw + reader.read(size - V2_HEADER_BYTES)


class TraceMonitor:
    """Forward one RVFI-DII connection and count its completed traces.

    Version negotiation and halt tokens do not count as instructions. The
    two forwarding threads allow a long request and its replies to progress
    independently, with socket backpressure bounding the buffered data.
    """

    def __init__(self, name: str, backend_port: int, timeout: float) -> None:
        """Reserve an engine-facing port and start forwarding when it connects."""
        self.name = name
        self.backend_port = backend_port
        self.timeout = timeout
        self.clear_vector_stores = False
        self.traces: list[TraceCounts] = []
        self.errors: list[str] = []
        self._stopping = threading.Event()
        self._requests: queue.Queue[tuple[str, int] | None] = queue.Queue()
        self._listener = socket.create_server(("127.0.0.1", 0))
        self._listener.settimeout(0.1)
        self.port = self._listener.getsockname()[1]
        self._sockets = [self._listener]
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _error(self, error: Exception) -> None:
        if not self._stopping.is_set() and not self.errors:
            self.errors.append(f"{self.name}: {error}")
        for sock in self._sockets:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def _connect(self) -> socket.socket:
        deadline = time.monotonic() + self.timeout
        while not self._stopping.is_set():
            try:
                backend = socket.create_connection(
                    ("127.0.0.1", self.backend_port), timeout=0.5
                )
                backend.settimeout(None)
                return backend
            except OSError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("implementation did not listen") from None
                self._stopping.wait(0.05)
        raise OSError("monitor stopped")

    def _serve(self) -> None:
        try:
            while not self._stopping.is_set():
                try:
                    engine, _ = self._listener.accept()
                    break
                except TimeoutError:
                    continue
            else:
                return
            self._sockets.append(engine)
            backend = self._connect()
            self._sockets.append(backend)
            for sock in (engine, backend):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self._forward(engine, backend)
        except (EOFError, OSError, ValueError, struct.error) as error:
            self._error(error)
        finally:
            for sock in self._sockets:
                sock.close()

    def _forward(self, engine: socket.socket, backend: socket.socket) -> None:
        replies = threading.Thread(
            target=self._forward_replies, args=(backend, engine), daemon=True
        )
        replies.start()
        try:
            reader = PacketReader(engine)
            instructions = 0
            while not self._stopping.is_set():
                try:
                    raw = reader.read(DII_PACKET_BYTES)
                except EOFError:
                    if instructions:
                        raise ValueError("instructions without an end-of-trace command")
                    break
                packet = DiiPacket.decode(raw)
                if packet.is_version_query:
                    self._requests.put(("query", 0))
                elif packet.cmd == CMD_SET_VERSION:
                    self._requests.put(("version", packet.insn))
                elif packet.cmd == CMD_INSTRUCTION:
                    instructions += 1
                elif packet.cmd == CMD_END_OF_TRACE:
                    self._requests.put(("trace", instructions))
                    instructions = 0
                else:
                    raise ValueError(f"unknown DII command {packet.cmd:#x}")
                backend.sendall(raw)
        except (OSError, ValueError) as error:
            self._error(error)
        finally:
            self._requests.put(None)
            replies.join()

    def _forward_replies(self, backend: socket.socket, engine: socket.socket) -> None:
        try:
            reader = PacketReader(backend)
            version = 1
            while (request := self._requests.get()) is not None:
                kind, instructions = request
                if kind == "query":
                    engine.sendall(reader.read(V1_PACKET_BYTES))
                elif kind == "version":
                    raw = reader.read(16)
                    version = struct.unpack("<Q", raw[8:])[0]
                    if raw[:8] != b"version=" or version not in (1, 2):
                        raise ValueError("invalid trace version acknowledgement")
                    engine.sendall(raw)
                else:
                    received = 0
                    while True:
                        if version == 1:
                            raw = reader.read(V1_PACKET_BYTES)
                            halt = raw[86]
                        else:
                            raw = _read_v2(reader)
                            halt = raw[33]
                        if halt:
                            self.traces.append(TraceCounts(instructions, received))
                        else:
                            # A transported execution packet counts even when
                            # its valid byte is clear, as in Sail's v2 replies.
                            received += 1
                            if version == 2 and self.clear_vector_stores:
                                raw = clear_vector_store_fields(raw)
                        engine.sendall(raw)
                        if halt:
                            break
        except (EOFError, OSError, ValueError) as error:
            self._error(error)

    def close(self) -> None:
        """Stop forwarding, release sockets, and wait for the counters to settle."""
        self._stopping.set()
        self._requests.put(None)
        for sock in self._sockets:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self._listener.close()
        self._thread.join(timeout=2)
        if self._thread.is_alive() and not self.errors:
            self.errors.append(f"{self.name}: monitor did not stop")


def is_vector_store(insn: int) -> bool:
    """Recognize STORE-FP encodings with a vector element width."""
    return (insn & 0x7F) == 0x27 and ((insn >> 12) & 0x7) in (0, 5, 6, 7)


def clear_vector_store_fields(raw: bytes) -> bytes:
    """Zero the mem-data payload of a retired vector store's v2 reply.

    Sail supplies the last element's store fields. FROST records store-queue
    writes, and the vector unit writes through the hart line client. Scalar
    readbacks compare each element the vector instruction stored.
    """
    insn = struct.unpack_from("<Q", raw, 24)[0]
    features = struct.unpack_from("<Q", raw, 56)[0]
    if raw[32] or not features & 2 or not is_vector_store(insn):
        return raw
    offset = V2_HEADER_BYTES + (V2_INT_DATA_BYTES if features & 1 else 0)
    if len(raw) < offset + V2_MEM_DATA_BYTES or raw[offset : offset + 8] != b"mem-data":
        raise ValueError("invalid trace-v2 mem-data block")
    return (
        raw[: offset + 8]
        + bytes(V2_MEM_DATA_BYTES - 8)
        + raw[offset + V2_MEM_DATA_BYTES :]
    )


def _wfi_wait_reply(raw: bytes, reply: RvfiRecord) -> bool:
    """Recognise a wait entry or the immediate U-mode illegal-instruction trap."""
    waits = reply.trap == 0 and reply.mode in (MODE_MACHINE, MODE_SUPERVISOR)
    user_trap = reply.trap == 1 and reply.mode == MODE_USER
    if (
        not (waits or user_trap)
        or raw[37:40] != b"\0\0\0"
        or len(raw) != V2_HEADER_BYTES
        or reply.pc_rdata & 1
        or reply.pc_wdata & 1
        or reply
        != RvfiRecord(
            order=reply.order,
            insn=WFI_INSN,
            mode=reply.mode,
            trap=reply.trap,
            pc_rdata=reply.pc_rdata,
            pc_wdata=0 if waits else reply.pc_wdata,
        )
    ):
        raise ValueError("unexpected Sail WFI reply")
    return waits


def _finish_wfi(first: bytes, raw: bytes) -> bytes:
    """Fold Sail's single synthetic wake or TW trap into the WFI reply."""
    start = decode_v2(BytesIO(first))
    end = decode_v2(BytesIO(raw))
    falls_through = end.trap == 0 and end.pc_wdata == (start.pc_rdata + 4) % (1 << 64)
    tw_trap = end.trap == 1 and start.mode == MODE_SUPERVISOR and end.pc_wdata % 2 == 0
    if (
        not (falls_through or tw_trap)
        or raw[37:40] != b"\0\0\0"
        or len(raw) != V2_HEADER_BYTES
        or end != RvfiRecord(mode=0, ixl=0, pc_wdata=end.pc_wdata, trap=end.trap)
    ):
        raise ValueError("unexpected Sail WFI completion reply")
    # Replace only trap and pc_wdata. Keep the original header and valid bit.
    return first[:32] + raw[32:33] + first[33:48] + raw[48:56] + first[56:]


class WfiTraceMonitor(TraceMonitor):
    """Normalise Sail 0.16's version-2 WFI replies with max_time_to_wait=0.

    Sail consumes one instruction packet to finish the wait. Forward that
    packet a second time so it executes after WFI. At most one WFI reply
    is held back, and the synthetic reply is excluded from trace counts.
    """

    def _forward(self, engine: socket.socket, backend: socket.socket) -> None:
        backend.settimeout(self.timeout)
        requests, replies = PacketReader(engine), PacketReader(backend)
        version_set = False
        requested = received = 0
        waiting = None
        while not self._stopping.is_set():
            try:
                raw = requests.read(DII_PACKET_BYTES)
            except EOFError:
                if requested:
                    raise ValueError(
                        "instructions without an end-of-trace command"
                    ) from None
                return
            packet = DiiPacket.decode(raw)
            if packet.is_version_query and not version_set:
                backend.sendall(raw)
                reply = replies.read(V1_PACKET_BYTES)
                if reply[86] != 3:
                    raise ValueError("WFI normalisation requires RVFI-DII version 2")
                engine.sendall(reply)
                continue
            if packet.cmd == CMD_SET_VERSION and not version_set and packet.insn == 2:
                backend.sendall(raw)
                reply = replies.read(16)
                if reply != version_ack(2):
                    raise ValueError("invalid version 2 acknowledgement")
                engine.sendall(reply)
                version_set = True
                continue
            if not version_set:
                raise ValueError("WFI normalisation requires RVFI-DII version 2")
            if packet.cmd == CMD_END_OF_TRACE and not packet.is_version_query:
                if waiting is not None:
                    raise ValueError("a waiting WFI must be followed by an instruction")
                backend.sendall(raw)
                reply = _read_v2(replies)
                if reply != RvfiRecord.halt_token().encode_v2():
                    raise ValueError("expected Sail halt token at end of WFI trace")
                self.traces.append(TraceCounts(requested, received))
                requested = received = 0
                engine.sendall(reply)
                continue
            if packet.cmd != CMD_INSTRUCTION:
                raise ValueError(f"unexpected DII command {packet.cmd:#x} in WFI mode")

            requested += 1
            backend.sendall(raw)
            reply = _read_v2(replies)
            if waiting is not None:
                engine.sendall(_finish_wfi(waiting, reply))
                received += 1
                waiting = None
                backend.sendall(raw)
                reply = _read_v2(replies)
            record = decode_v2(BytesIO(reply))
            if record.halt or record.insn != packet.insn:
                raise ValueError("unexpected Sail instruction reply in WFI mode")
            if packet.insn == WFI_INSN and _wfi_wait_reply(reply, record):
                waiting = reply
            else:
                engine.sendall(reply)
                received += 1
