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

"""Count injected instructions and RVFI replies without altering their bytes."""

import queue
import socket
import struct
import threading
import time
from dataclasses import dataclass

from testrig.rvfi_dii import (
    CMD_END_OF_TRACE,
    CMD_INSTRUCTION,
    CMD_SET_VERSION,
    DII_PACKET_BYTES,
    V1_PACKET_BYTES,
    V2_HEADER_BYTES,
    DiiPacket,
    PacketReader,
)


@dataclass(frozen=True)
class TraceCounts:
    """Instruction counts for one completed request and its execution trace."""

    requested: int
    received: int


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
        replies = None
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
            replies = threading.Thread(
                target=self._forward_replies, args=(backend, engine), daemon=True
            )
            replies.start()
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
            if replies is not None:
                replies.join()
            for sock in self._sockets:
                sock.close()

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
                            valid = True
                        else:
                            raw = reader.read(V2_HEADER_BYTES)
                            size = struct.unpack("<Q", raw[8:16])[0]
                            if raw[:8] != b"trace-v2" or not 64 <= size <= 192:
                                raise ValueError("invalid trace-v2 header")
                            halt = raw[33]
                            valid = bool(raw[37] or raw[32])
                            raw += reader.read(size - V2_HEADER_BYTES)
                        if halt:
                            self.traces.append(TraceCounts(instructions, received))
                        elif valid:
                            received += 1
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
